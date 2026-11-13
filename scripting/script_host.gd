class_name ScriptHost
extends RefCounted
## Facade over stock lua-gdextension 0.8.2 (Lua 5.4). The rest of the game talks
## to Lua only through this class.
##
## Every chunk and every callback runs in a host-owned coroutine. A count hook
## returns LuaThread.HOOK_YIELD when the instruction budget, the wall clock or
## the soft memory cap trips. A yield is not an error, so pcall / xpcall cannot
## swallow it. After the verdict the hook is re-armed at count 1, so the first
## instruction outside a native call yields too.
##
## The 64 MB cap is soft on the stock binary: it is sampled every HOOK_STRIDE
## instructions. A hard allocator cap needs the source-built binding (deferred).

const INSTRUCTION_BUDGET := 100_000
## Extra instructions per batch row. Provisional; may change.
const BATCH_ROW_BUDGET := 128
## Ceiling for one on_batch call. Provisional; may change.
const BATCH_BUDGET_CEILING := 2_000_000
const HOOK_STRIDE := 1_000
const WALL_MSEC := 50
## Stop-only watchdog during shutdown. Short on purpose: a to-be-closed loop
## must die quickly, and our own cleanup chunk finishes well inside it.
const SHUTDOWN_WALL_MSEC := 10
## -1 is LuaThread.HOOK_YIELD. The hook stays installed through GC and lua_close.
## It never calls back into Godot. Past the wall it yields, which stops a
## to-be-closed loop. __gc runs with hooks disabled, so those are stripped first.
const _STOP_HOOK := """
local t0 = os.clock()
local limit = %d / 1000.0
return function()
	if os.clock() - t0 >= limit then
		return -1
	end
	return 0
end
"""
## The walk below uses only values stored at state creation. It does not call
## the live global table.
## Not walked: userdata user values, anything reachable only through a weak
## table, and coroutine stacks. coroutine.status cannot be retained from
## state creation either, and reading a stopped thread's stack is unsafe.
## If the walk does not finish, objects it never visited keep their Lua
## finalizers. Process exit still runs those inside lua_close. A count hook
## cannot stop that: the collector sets allowhook to 0 before calling one.
## Stock 0.8.2 has no call that clears the rest without visiting them.
## The player sandbox rejects __gc, so a play-time script cannot install one.
## The leftover case is trusted code that plants a Lua finalizer this walk
## does not reach.
## The walk is an explicit queue, never recursive. A node budget stops it.
## os.clock cannot be retained from state creation: doing so aborts a later
## coroutine create. The wall limit is the stop-only hook built at shutdown.
## shutdown() pins the state either way.
const _STRIP_NODE_BUDGET := 4096
const _STRIP_FINALIZERS := """
return function(cap, env, weapon, limit_s)
	if cap == nil then
		return false
	end
	local type = cap.type
	local pcall = cap.pcall
	local error = cap.error
	local next = cap.next
	local rawget = cap.rawget
	local rawset = cap.rawset
	local getmetatable = cap.getmetatable
	local getinfo = cap.getinfo
	local dbg_getmetatable = cap.dbg_getmetatable
	local getupvalue = cap.getupvalue
	local getlocal = cap.getlocal
	local getregistry = cap.getregistry
	local _G = cap._G
	local NODE_BUDGET = %d
	if type(cap) ~= "table" or type(limit_s) ~= "number" or limit_s <= 0 then
		return false
	end
	if type(getinfo) ~= "function" or type(dbg_getmetatable) ~= "function"
		or type(getupvalue) ~= "function" or type(getlocal) ~= "function"
		or type(getregistry) ~= "function" or type(next) ~= "function"
		or type(rawget) ~= "function" or type(rawset) ~= "function"
		or type(getmetatable) ~= "function" or type(type) ~= "function"
		or type(pcall) ~= "function" or type(error) ~= "function"
		or type(_G) ~= "table" then
		return false
	end
	local nodes = 0
	local function stop()
		return nodes >= NODE_BUDGET
	end
	local function is_lua_fin(fin)
		if type(fin) ~= "function" then
			return false
		end
		local ok, info = pcall(getinfo, fin, "S")
		return ok and type(info) == "table" and info.what ~= "C"
	end
	local function disarm_mt(mt)
		if type(mt) ~= "table" then
			return
		end
		local fin = rawget(mt, "__gc")
		if is_lua_fin(fin) then
			pcall(rawset, mt, "__gc", nil)
		end
	end
	local function weak_table(obj)
		local ok, mt = pcall(dbg_getmetatable, obj)
		if not ok or type(mt) ~= "table" then
			return false
		end
		local mode = rawget(mt, "__mode")
		return type(mode) == "string" and mode ~= ""
	end
	local seen = {}
	local queue = {}
	local qh, qt = 1, 0
	local incomplete = false
	local function note(obj)
		if stop() then
			return true
		end
		if obj == nil then
			return false
		end
		local ty = type(obj)
		if (ty == "table" or ty == "function" or ty == "thread") and not seen[obj] then
			nodes = nodes + 1
			if nodes > NODE_BUDGET then
				return true
			end
			seen[obj] = true
			qt = qt + 1
			queue[qt] = obj
		end
		local ok, mt = pcall(dbg_getmetatable, obj)
		if ok and type(mt) == "table" then
			disarm_mt(mt)
			if not seen[mt] then
				nodes = nodes + 1
				if nodes > NODE_BUDGET then
					return true
				end
				seen[mt] = true
				qt = qt + 1
				queue[qt] = mt
			end
		end
		return false
	end
	local function walk_function(fn)
		local i = 1
		while i <= 256 do
			if stop() then
				return true
			end
			local ok, name, val = pcall(getupvalue, fn, i)
			if not ok or name == nil then
				return false
			end
			if note(val) then
				return true
			end
			i = i + 1
		end
		incomplete = true
		return false
	end
	local function walk_thread(_th)
		-- Stacks stay unread. Inspecting a stopped thread is unsafe, and
		-- retaining coroutine.status from state creation aborts a later
		-- coroutine create on this binding.
		return false
	end
	if note(_G) or note(env) or note(weapon) then
		return false
	end
	local phase = 1
	while true do
		if qh > qt then
			if phase ~= 1 or stop() then
				break
			end
			phase = 2
			local reg_ok, reg = pcall(getregistry)
			if not reg_ok or not note(reg) then
				if qh > qt then
					break
				end
			else
				return false
			end
		end
		if stop() then
			return false
		end
		local obj = queue[qh]
		queue[qh] = nil
		qh = qh + 1
		local ty = type(obj)
		if ty == "table" then
			if rawget(obj, "__strip_error") == true then
				error("strip")
			end
			if not weak_table(obj) then
			local k = nil
			while true do
				if stop() then
					return false
				end
				local nk, v = next(obj, k)
				if nk == nil then
					break
				end
				if note(nk) or note(v) then
					return false
				end
				k = nk
			end
			end
		elseif ty == "function" then
			if walk_function(obj) then
				return false
			end
		elseif ty == "thread" then
			if walk_thread(obj) then
				return false
			end
		end
	end
	if incomplete or stop() then
		return false
	end
	return true
end
"""
const _WIPE_TABLE := """
return function(t)
	if type(t) ~= "table" then
		return
	end
	for _, k in ipairs({
		"_lock", "reg_thread", "dead", "_nums", "make_bullet", "make_batch",
		"_output", "_vel", "_kids", "_packed", "_batch_tally", "_expired", "_spawns", "make_ctx",
	}) do
		rawset(t, k, nil)
	end
end
"""
const MEMORY_CAP := 64 * 1024 * 1024
const MAX_WEAPON_KEYS := 256
## A script that yields on purpose (wait) is not in this slice. A few resumes
## cover a yield the hook did not ask for; past that we stop instead of looping.
const MAX_EXTRA_RESUMES := 4

const SANDBOX_PATH := "res://scripting/sandbox.lua"
const LIBS := (
	LuaState.LUA_BASE
	| LuaState.LUA_COROUTINE
	| LuaState.LUA_STRING
	| LuaState.LUA_OS
	| LuaState.LUA_MATH
	| LuaState.LUA_TABLE
	| LuaState.LUA_UTF8
	# Opened so the host can pass packed columns into the trusted view builder.
	# Scripts never receive those values: the view handed to on_batch is a Lua
	# table. The script environment has no engine API.
	| LuaState.GODOT_VARIANT
)

const _NAMES_OF := """
return function(t)
	if type(t) ~= "table" then return {} end
	local out = {}
	local k = nil
	local n = 0
	while true do
		local v
		k, v = next(t, k)
		if k == nil then break end
		n = n + 1
		if n > %d then error("weapon table has too many keys", 0) end
		if type(k) == "string" and type(v) == "function" then
			out[#out + 1] = k
		end
	end
	return out
end
""" % MAX_WEAPON_KEYS

## Per-run tunable copies of the defaults. Tests tighten the budget; the game
## leaves them at the values above.
var instruction_budget: int = INSTRUCTION_BUDGET
var wall_msec: int = WALL_MSEC

## Hosts stay pinned for the session. Freeing a LuaState while a Godot Variant
## or Callable it holds is still live aborts stock lua-gdextension, including
## a state whose coroutines have all finished (lua-gdextension #240).
## shutdown() disarms Lua finalizers, drops host-table Callables, arms a
## stop-only hook, restarts GC, and pins every state. It frees no wrappers.
static var _process_hosts: Array[ScriptHost] = []
static var _shutdown_all_busy := false
## Every Lua wrapper shutdown decided to keep. Nothing in here is freed.
static var _pinned: Array = []
var _state: LuaState
var _debug_fns: LuaTable
var _strip_fn: LuaFunction
var _env: LuaTable
var _host: LuaTable
var _make_bullet: LuaFunction
## Sandbox entry point for script code (sandbox.lua host.call). See _run_script.
var _call: LuaFunction
var _names_of: LuaFunction
var _ready := false
var _init_error := ""

var _weapon: LuaTable
var _names := PackedStringArray()
var _callbacks: Dictionary = {}

var _threads: Array[LuaThread] = []
## Coroutines the budget stopped. shutdown() does not resume them and does not
## free them (lua-gdextension #240).
var _parked: Array[LuaThread] = []
## Set when shutdown pinned this host's Lua state. shutdown() always does.
var _keeps_lua_state := false
## True only when every state reported a finished walk. A bool false does not.
var _strip_ok := false
## States retired after three watchdog stops, oldest first. Each one still has
## its sandbox, so player code there still cannot install __gc.
var _retired: Array[RetiredState] = []
## Coroutines a kept wrapper may still be bound to. See _run.
var _value_threads: Array[LuaThread] = []
var _source := ""
var _chunk_name := "script.lua"
## Chunk name of the load_string call in progress, for stop lines at load time.
var _loading_chunk := ""
var _closed := false
var _stop_only := false
## True while resumev has not returned. shutdown() waits; freeing the state
## from inside that call is the crash #33 avoids.
var _in_lua := false
var _shutdown_after := false
var _host_calls := 0
var _instr := 0
var _killed := false
var _kill_reason := ""
## Where the watchdog stopped the script: the line in the player's chunk, or 0.
var _kill_line := 0
var _t0 := 0
var _mem_peak := 0
var _output := PackedStringArray()

## Records from the last clean on_fire: one Dictionary per spawn{} call, with
## only the fields the script set (angle, speed, damage, lifetime, radius,
## spin, accel, x, y).
var _pending_spawns: Array[Dictionary] = []
var _spawns_dropped := 0
var _pending_velocity_set := false
var _pending_velocity := Vector2.ZERO
var _pending_children: Array[ShotRequest] = []
var _number := 0.0
## The BatchView whose Lua callback is running, or null.
var _batch: BatchView
## Token of the view that is allowed to issue commands. -1 when none is.
var _batch_token := -1
var _batch_serial := 0
var _row_value := -1
## Watchdog samples (steps of HOOK_STRIDE) from the most recent on_batch call.
var batch_instructions := 0
var _cmd_nums := PackedFloat32Array()


class RunResult:
	extends RefCounted
	var ok := false
	## "instruction budget", "wall clock", "memory cap", or "" when the hook did not stop it.
	var stopped := ""
	## Lua error text, or the timeout line. Empty on success.
	var error := ""
	var value: Variant = null
	var chunk_name := ""
	var output := PackedStringArray()
	## Line in the player's chunk where a watchdog stop landed, or 0 when the
	## stop was outside it (inside a library wrapper) or there was no stop.
	var stop_line := 0


## One Lua state that has already stopped three times, plus the tables and
## threads that still point into it. shutdown() pins these; it does not free them.
class RetiredState:
	extends RefCounted
	var state: LuaState
	var host_table: LuaTable
	var env_table: LuaTable
	var weapon: LuaTable
	var debug_fns: LuaTable
	var strip_fn: LuaFunction
	var threads: Array[LuaThread] = []


func _init() -> void:
	_pin()
	_open_state()


func _open_state() -> void:
	_ready = false
	_state = LuaState.new()
	_state.open_libraries(LIBS)
	_capture_debug()
	var src := FileAccess.get_file_as_string(SANDBOX_PATH)
	if src.is_empty():
		_init_error = "sandbox missing: %s" % SANDBOX_PATH
		return
	var built: Variant = _state.do_string(src, "@scripting/sandbox.lua")
	if built is LuaError:
		_init_error = "sandbox: %s" % _lua_error_message(built)
		return
	if not built is LuaFunction:
		_init_error = "sandbox did not return a builder"
		return
	_host = _state.create_table()
	# Present so the trusted builder can lock the shared Variant metatable.
	# Scripts never receive this value.
	_host.set("_lock", Callable(self, "_lua_print"))
	_host.set("reg_thread", Callable(self, "_lua_reg_thread"))
	_host.set("dead", Callable(self, "_lua_dead"))
	_host.set("batch_token", -1)
	var buf := _state.create_table()
	buf.set("n", 0)
	_host.set("_output", buf)
	var env_v: Variant = _as_function(built).invoke(_host)
	if env_v is LuaError:
		_init_error = "sandbox env: %s" % _lua_error_message(env_v)
		return
	if not env_v is LuaTable:
		_init_error = "sandbox env is not a table"
		return
	_env = _as_table(env_v)
	var maker: Variant = _host.get("make_bullet")
	if not maker is LuaFunction:
		_init_error = "sandbox did not install make_bullet"
		return
	_make_bullet = _as_function(maker)
	var call_v: Variant = _host.get("call")
	if not call_v is LuaFunction:
		_init_error = "sandbox did not install call"
		return
	_call = _as_function(call_v)
	var names_src: Variant = _state.do_string(_NAMES_OF, "@scripting/names.lua")
	if not names_src is LuaFunction:
		_init_error = _lua_error_message(names_src) if names_src is LuaError else "names extractor failed"
		return
	_names_of = _as_function(names_src)
	_ready = true


## Opens the debug library and keeps a small loader. The walk chunk is loaded
## from that loader later. The debug global stays; clearing it while a closure
## still holds the library's C functions makes a later coroutine create abort.
func _capture_debug() -> void:
	_debug_fns = null
	_strip_fn = null
	_state.open_libraries(LuaState.LUA_DEBUG)
	# Stash the originals in the registry and drop the Godot wrapper.
	# Holding them in a long-lived LuaFunction makes a later coroutine create abort.
	_state.do_string("""
		debug.getregistry()["__scriptshot_cap"] = {
			next = next,
			rawget = rawget,
			rawset = rawset,
			getmetatable = getmetatable,
			type = type,
			pcall = pcall,
			error = error,
			getinfo = debug.getinfo,
			dbg_getmetatable = debug.getmetatable,
			getupvalue = debug.getupvalue,
			getlocal = debug.getlocal,
			getregistry = debug.getregistry,
			_G = _G,
		}
		return 1
	""".dedent(), "@capture-debug.lua")


## After three stopped coroutines the state cannot host another one. The old
## state stays alive (see shutdown) and a fresh sandbox is opened.
func _rotate_state_if_needed() -> void:
	if _closed or _parked.size() < 3 or _source.is_empty():
		return
	var retired := RetiredState.new()
	retired.state = _state
	retired.host_table = _host
	retired.env_table = _env
	retired.weapon = _weapon
	retired.debug_fns = _debug_fns
	retired.strip_fn = _strip_fn
	retired.threads.assign(_parked)
	retired.threads.append_array(_value_threads)
	_retired.append(retired)
	_parked = []
	_value_threads = []
	_callbacks = {}
	_weapon = null
	_debug_fns = null
	_strip_fn = null
	_host = null
	_env = null
	_make_bullet = null
	_call = null
	_names_of = null
	var source := _source
	var chunk := _chunk_name
	_open_state()
	if _ready:
		load_string(source, chunk)


func _pin() -> void:
	if _closed:
		return
	if not _process_hosts.has(self):
		_process_hosts.append(self)


func _unpin() -> void:
	_process_hosts.erase(self)


func is_ready() -> bool:
	return _ready and not _closed


func is_shutdown() -> bool:
	return _closed


## True when shutdown pinned this host's Lua state for the process.
## shutdown() does that for every state. It does not free the wrappers.
func keeps_lua_state() -> bool:
	return _keeps_lua_state


## How many Lua wrappers shutdown has retained for the process.
static func lifetime_pin_count() -> int:
	return _pinned.size()


func host_call_count() -> int:
	return _host_calls


## Pins every state this process still has. Idempotent.
## Oldest host first, and each host handles retired states before its current one.
static func shutdown_all() -> void:
	if _shutdown_all_busy:
		return
	_shutdown_all_busy = true
	var hosts: Array[ScriptHost] = []
	hosts.assign(_process_hosts)
	for i in hosts.size():
		hosts[i].shutdown()
	_shutdown_all_busy = false


## Disarms finalizers, drops host-table Callables, arms a stop-only hook,
## restarts GC, and pins every state for the process. It frees no wrappers.
## A coroutine that is suspended inside resumev is left alone until that call
## returns; it is never resumed from here.
func shutdown() -> void:
	if _closed:
		return
	if _in_lua:
		_shutdown_after = true
		_stop_only = true
		_expire_views()
		return
	_closed = true
	_stop_only = true
	_ready = false
	_strip_ok = true
	_expire_views()
	for i in _retired.size():
		_release_retired(_retired[i])
	_release_current()
	_retired.clear()
	_unpin()


func _expire_views() -> void:
	_batch_token = -1
	if _batch != null:
		_batch.discard = true
		_batch = null
	_mark_expired(_host)
	for i in _retired.size():
		_mark_expired(_retired[i].host_table)


func _mark_expired(host_table: LuaTable) -> void:
	if host_table == null:
		return
	var flag_v: Variant = host_table.get("_expired")
	if flag_v is LuaTable:
		_as_table(flag_v).set(1, true)


func _release_retired(retired: RetiredState) -> void:
	var threads: Array[LuaThread] = []
	threads.assign(retired.threads)
	_release_state(
		retired.state,
		retired.host_table,
		retired.env_table,
		retired.weapon,
		retired.debug_fns,
		retired.strip_fn,
		threads
	)
	retired.host_table = null
	retired.env_table = null
	retired.weapon = null
	retired.debug_fns = null
	retired.strip_fn = null
	retired.threads.clear()
	retired.state = null


func _release_current() -> void:
	var threads: Array[LuaThread] = []
	threads.assign(_parked)
	for i in _threads.size():
		var th: LuaThread = _threads[i]
		if th != null and not threads.has(th):
			threads.append(th)
	for i in _value_threads.size():
		var vt: LuaThread = _value_threads[i]
		if vt != null and not threads.has(vt):
			threads.append(vt)
	_release_state(_state, _host, _env, _weapon, _debug_fns, _strip_fn, threads)
	var names: Array = _callbacks.keys()
	for i in names.size():
		_retain(_callbacks[names[i]])
	_retain(_make_bullet)
	_retain(_call)
	_retain(_names_of)
	_callbacks.clear()
	_make_bullet = null
	_call = null
	_names_of = null
	_host = null
	_env = null
	_weapon = null
	_debug_fns = null
	_strip_fn = null
	_parked.clear()
	_threads.clear()
	_value_threads.clear()
	_state = null


func _retain(v: Variant) -> void:
	if v == null:
		return
	_keeps_lua_state = true
	_pinned.append(v)


## A non-bool strip result must not raise. Anything that is not `true` is a
## failed strip, and the state stays pinned.
func _is_true(v: Variant) -> bool:
	return typeof(v) == TYPE_BOOL and v


## lua-gdextension 0.8.2 has no close(). Dropping the last wrapper runs
## lua_close inside ~LuaTable / ~LuaFunction and that segfaults, quiet state
## included. This pins every wrapper instead. `threads` is not passed to
## set_hook; a hook on a stopped coroutine crashes.
func _release_state(
	state: LuaState,
	host_table: LuaTable,
	env_table: LuaTable,
	weapon: LuaTable,
	debug_fns: LuaTable,
	strip_fn: LuaFunction,
	threads: Array[LuaThread]
) -> void:
	if state == null:
		return
	var hold: Array = []
	_disarm(state, host_table, env_table, weapon, hold)
	_retain(state)
	_retain(host_table)
	_retain(env_table)
	_retain(weapon)
	_retain(debug_fns)
	_retain(strip_fn)
	for i in threads.size():
		_retain(threads[i])
	for i in hold.size():
		_retain(hold[i])


## Stop GC, strip, wipe host Callables, arm the stop-only hook, then restart
## GC. Every path that stopped GC restarts it. Hooks do not run during
## finalizers. Nothing here is freed.
func _disarm(
	state: LuaState,
	host_table: LuaTable,
	env_table: LuaTable,
	weapon: LuaTable,
	hold: Array
) -> void:
	state.stop_gc()
	var hook_src := _STOP_HOOK % SHUTDOWN_WALL_MSEC
	var hook_v: Variant = state.do_string(hook_src, "@shutdown-hook.lua")
	if hook_v is LuaFunction:
		var hook := _as_function(hook_v)
		hold.append(hook)
		var finished := false
		var cap: Variant = null
		var reg := state.get_registry()
		if reg != null:
			hold.append(reg)
			cap = reg.get("__scriptshot_cap")
		var strip_v: Variant = state.do_string(
			_STRIP_FINALIZERS % _STRIP_NODE_BUDGET, "@shutdown-strip.lua"
		)
		if strip_v is LuaFunction and cap is LuaTable:
			var strip := _as_function(strip_v)
			hold.append(strip)
			hold.append(cap)
			var co: LuaCoroutine = LuaCoroutine.create(strip)
			if co != null:
				hold.append(co)
				# Count stride, not every instruction: the chunk also checks the wall.
				# The hook is the backstop and is what stops a to-be-closed loop later.
				co.set_hook(hook, LuaThread.HOOK_MASK_COUNT, HOOK_STRIDE)
				var limit := float(SHUTDOWN_WALL_MSEC) / 1000.0
				var resumed: Variant = co.resumev([cap, env_table, weapon, limit])
				# Strict true only. A bool false stopped early and is not success.
				if co.status != LuaThread.STATUS_YIELD and _is_true(resumed):
					finished = true
		if not finished:
			_strip_ok = false
		if finished:
			var wipe_v: Variant = state.do_string(_WIPE_TABLE, "@shutdown-wipe.lua")
			if wipe_v is LuaFunction:
				var wipe := _as_function(wipe_v)
				hold.append(wipe)
				if host_table != null:
					wipe.invoke(host_table)
			var main := state.get_main_thread()
			if main != null:
				main.set_hook(hook, LuaThread.HOOK_MASK_COUNT, 1)
				hold.append(main)
	state.restart_gc()


func _note_host_call() -> void:
	_host_calls += 1


## Highest Lua heap seen by the count hook. The memory cap is soft: a script
## that allocates and returns between two samples can pass it.
func memory_peak() -> int:
	return _mem_peak


## Lua heap in bytes: the current state plus the retired ones.
func lua_memory() -> int:
	var n := int(_state.get_memory_used()) if _state != null else 0
	for r in _retired:
		if r.state != null:
			n += int(r.state.get_memory_used())
	return n


## Lua states this host holds: the current one plus the retired ones.
func lua_state_count() -> int:
	return (1 if _state != null else 0) + _retired.size()


## Drops the weapon table and its callbacks so the chunk that built them can
## be collected, then runs a full collection. The state and its sandbox stay
## (states are never freed, see shutdown()); a later load_string reuses them.
## LuaShot calls this when a generation is released. No-op inside a call.
func release_weapon() -> void:
	if _closed or _in_lua or _state == null:
		return
	_callbacks.clear()
	_weapon = null
	_names = PackedStringArray()
	_source = ""
	# _value_threads and _parked stay: a wrapper elsewhere may still be tied
	# to one of those coroutines (see _run).
	_clear_pending()
	_state.collect_garbage()


func has_weapon() -> bool:
	return _weapon != null


func has_callback(name: String) -> bool:
	return _callbacks.has(name)


## A number field of the loaded weapon table, read with rawget (no
## metamethods, no Lua code runs), or `fallback` when it is missing, not a
## number or not finite.
func weapon_number(key: String, fallback: float) -> float:
	if _weapon == null or _closed:
		return fallback
	var v: Variant = _weapon.rawget(key)
	if not _read_number(v) or not is_finite(_number):
		return fallback
	return _number


## A string field of the loaded weapon table (rawget), or `fallback`.
func weapon_string(key: String, fallback: String) -> String:
	if _weapon == null or _closed:
		return fallback
	var v: Variant = _weapon.rawget(key)
	if v is String:
		return str(v)
	return fallback


func defined_names() -> PackedStringArray:
	return _names.duplicate()


## Hook bits for the functions in the loaded weapon table. Zero when the script
## defines no event callback (the bullet stays declarative).
func hook_mask() -> int:
	return BulletBehavior.mask_from_names(_names)


## Compiles and runs `code`. A returned table becomes the weapon, replacing the
## previous one. A compile error, a runtime error or a budget stop leaves the
## previous weapon in place. The chunk name is what Lua prints in errors.
func load_string(code: String, chunk_name: String = "script.lua") -> RunResult:
	if _closed:
		return _fail("script host shut down", chunk_name)
	if not _ready:
		return _fail(_init_error, chunk_name)
	var loaded: Variant = _state.load_string(code, "@" + chunk_name, _env)
	if loaded is LuaError:
		return _fail(_lua_error_message(loaded), chunk_name)
	if not loaded is LuaFunction:
		return _fail("load did not return a function", chunk_name)
	_loading_chunk = chunk_name
	var result := _run_script(_as_function(loaded), [], true)
	_loading_chunk = ""
	result.chunk_name = chunk_name
	if not result.ok:
		return result
	if result.value is LuaTable:
		var adopted := _adopt_weapon(_as_table(result.value))
		adopted.chunk_name = chunk_name
		adopted.output = result.output
		if not adopted.ok:
			return adopted
		adopted.value = result.value
		_source = code
		_chunk_name = chunk_name
	return result


func load_file(path: String) -> RunResult:
	if not FileAccess.file_exists(path):
		return _fail("file not found: %s" % path, path)
	var code := FileAccess.get_file_as_string(path)
	var name := path.trim_prefix("res://")
	return load_string(code, name)


## Calls a weapon function under the budget. `arg` is the second Lua argument
## (a hit table, a despawn reason) when `pass_arg` is true. `vx`, `vy` are the
## bullet's velocity snapshot (`b.vx`, `b.vy`). On failure the pending velocity
## and child spawns are dropped.
func call_hook(
	name: String,
	id: int,
	x: float,
	y: float,
	arg: Variant = null,
	pass_arg: bool = false,
	vx: float = 0.0,
	vy: float = 0.0
) -> RunResult:
	if _closed:
		return _fail("script host shut down", name)
	_rotate_state_if_needed()
	_clear_pending()
	if not _ready:
		return _fail(_init_error, name)
	if not _callbacks.has(name):
		var missing := RunResult.new()
		missing.ok = true
		missing.chunk_name = name
		return missing
	var fn: Variant = _callbacks[name]
	if not fn is LuaFunction:
		return _fail("callback '%s' is not a function" % name, name)
	var bullet_v: Variant = _make_bullet.invoke(id, x, y, vx, vy)
	if bullet_v is LuaError:
		return _fail(_lua_error_message(bullet_v), name)
	if not bullet_v is LuaTable:
		return _fail("make_bullet did not return a table", name)
	var args: Array = [fn, bullet_v]
	if pass_arg:
		args.append(arg)
	var result := _run(_call, args)
	result.chunk_name = name
	if result.ok:
		var pending_err := _take_lua_bullet_pending()
		if pending_err != "":
			result.ok = false
			result.error = pending_err
			_clear_pending()
	else:
		_clear_pending()
	return result


## Calls `on_batch(v, dt)`. `v`'s columns are the view's packed copies, so a
## later zero-copy column object can replace them without a script change.
## On failure the view is marked `discard` and the caller commits nothing.
func call_batch(batch: BatchView) -> RunResult:
	if _closed:
		batch.discard = true
		return _fail("script host shut down", "on_batch")
	_rotate_state_if_needed()
	_clear_pending()
	if not _ready:
		batch.discard = true
		return _fail(_init_error, "on_batch")
	if not _callbacks.has("on_batch"):
		var missing := RunResult.new()
		missing.ok = true
		missing.chunk_name = "on_batch"
		return missing
	var fn: Variant = _callbacks["on_batch"]
	if not fn is LuaFunction:
		batch.discard = true
		return _fail("callback 'on_batch' is not a function", "on_batch")
	var maker: Variant = _host.get("make_batch")
	if not maker is LuaFunction:
		batch.discard = true
		return _fail("sandbox did not install make_batch", "on_batch")
	_batch_serial += 1
	_batch_token = _batch_serial
	_batch = batch
	if _cmd_nums.size() < BatchView.CMD_CAP * 5:
		_cmd_nums.resize(BatchView.CMD_CAP * 5)
	_host.set("_nums", _cmd_nums)
	var view_v: Variant = _as_function(maker).invoke(
		_batch_token, batch.n, batch.id, batch.px, batch.py, batch.vx, batch.vy, batch.age, batch.pa, batch.pb, batch.owner, batch.dt,
		BatchView.CMD_CAP, BatchView.SPAWN_CAP
	)
	if view_v is LuaError:
		_end_batch()
		batch.discard = true
		return _fail(_lua_error_message(view_v), "on_batch")
	# v.dt and the second argument are the same tick delta.
	var saved_budget := instruction_budget
	var batch_budget := INSTRUCTION_BUDGET + batch.n * BATCH_ROW_BUDGET
	if batch_budget > BATCH_BUDGET_CEILING:
		batch_budget = BATCH_BUDGET_CEILING
	instruction_budget = batch_budget
	var result := _run(_call, [fn, view_v, batch.dt])
	batch_instructions = _instr
	instruction_budget = saved_budget
	result.chunk_name = "on_batch"
	# A stop or a Lua error commits nothing, and does not re-enter Lua.
	if result.ok:
		var flush_err := _flush_lua_commands()
		if flush_err != "":
			result.ok = false
			result.error = flush_err
	_end_batch()
	if not result.ok:
		batch.discard = true
	return result


## Most spawn{} calls one on_fire keeps; the rest return false and are counted.
const FIRE_SPAWN_CAP := 256
const _SPAWN_KEYS: PackedStringArray = ["angle", "speed", "damage", "lifetime", "radius", "spin", "accel", "x", "y"]


## Calls `on_fire(ctx)` under the budget with a snapshot of `context`. On a
## clean return the spawn{} records are on take_pending_spawns(); on an error
## or a stop nothing is spawned.
func call_fire(context: ShotContext, dt: float = 1.0 / 60.0) -> RunResult:
	if _closed:
		return _fail("script host shut down", "on_fire")
	_rotate_state_if_needed()
	_clear_pending()
	if not _ready:
		return _fail(_init_error, "on_fire")
	if not _callbacks.has("on_fire"):
		var missing := RunResult.new()
		missing.ok = true
		missing.chunk_name = "on_fire"
		return missing
	var fn: Variant = _callbacks["on_fire"]
	var maker: Variant = _host.get("make_ctx")
	if not fn is LuaFunction or not maker is LuaFunction:
		return _fail("on_fire is not a function", "on_fire")
	var p := context.muzzle_position
	var ctx_v: Variant = _as_function(maker).invoke(
		p.x, p.y, context.aim_angle, context.time, context.shot_index,
		context.trigger_pressed, context.trigger_just_pressed, context.trigger_just_released,
		context.trigger_held_time, dt, FIRE_SPAWN_CAP
	)
	if not ctx_v is LuaTable:
		return _fail(_lua_error_message(ctx_v) if ctx_v is LuaError else "make_ctx did not return a table", "on_fire")
	var result := _run(_call, [fn, ctx_v])
	ctx_v = null
	result.chunk_name = "on_fire"
	var spawns_v: Variant = _host.get("_spawns")
	if spawns_v is LuaTable:
		_as_table(spawns_v).set("open", false)
		if result.ok:
			_take_spawns(_as_table(spawns_v))
	if not result.ok:
		_clear_pending()
	result.value = null
	return result


func take_pending_spawns() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.assign(_pending_spawns)
	_pending_spawns.clear()
	return out


## spawn{} calls the last on_fire made past FIRE_SPAWN_CAP.
func spawns_dropped() -> int:
	return _spawns_dropped


func _take_spawns(spawns: LuaTable) -> void:
	_spawns_dropped = _nonneg_int(spawns.get("dropped", 0))
	var n := mini(_nonneg_int(spawns.get("n", 0)), FIRE_SPAWN_CAP)
	for i in n:
		var rec_v: Variant = spawns.get(i + 1, null)
		if not rec_v is LuaTable:
			continue
		var rec := _as_table(rec_v)
		var out: Dictionary = {}
		for k in _SPAWN_KEYS:
			if _read_number(rec.get(k, null)):
				out[k] = _number
		_pending_spawns.append(out)


func _end_batch() -> void:
	# Field write on a Lua table the closures already hold. Not a Lua call.
	if _host != null:
		var flag_v: Variant = _host.get("_expired")
		if flag_v is LuaTable:
			_as_table(flag_v).set(1, true)
	_batch = null
	_batch_token = -1


func has_pending_velocity() -> bool:
	return _pending_velocity_set


func take_pending_velocity() -> Vector2:
	_pending_velocity_set = false
	return _pending_velocity


func take_pending_children() -> Array[ShotRequest]:
	var out: Array[ShotRequest] = []
	out.assign(_pending_children)
	_pending_children.clear()
	return out


## Small table handed to on_hit / can_hit. Plain numbers, never the Hurtbox.
func make_hit(damage: float, x: float, y: float) -> LuaTable:
	var t := _state.create_table()
	t.set("damage", damage)
	t.set("x", x)
	t.set("y", y)
	return t


func _adopt_weapon(weapon: LuaTable) -> RunResult:
	var extracted := _run(_names_of, [weapon], true)
	if not extracted.ok:
		return extracted
	var names := _strings_from(extracted.value)
	names.sort()
	var callbacks: Dictionary = {}
	for n in names:
		var fn: Variant = weapon.get(n)
		if fn is LuaFunction:
			callbacks[n] = fn
	_weapon = weapon
	_names = names
	_callbacks = callbacks
	var ok := RunResult.new()
	ok.ok = true
	return ok


func _strings_from(value: Variant) -> PackedStringArray:
	var names := PackedStringArray()
	if value is LuaTable:
		var t := _as_table(value)
		for i in MAX_WEAPON_KEYS:
			var item: Variant = t.get(i + 1, null)
			if item == null:
				break
			names.append(str(item))
	elif value is Array:
		var items := _as_array(value)
		for i in items.size():
			names.append(str(items[i]))
	return names


## Runs script code through the sandbox entry point (host.call), which hands
## back at most one plain value. Unexpected return values are ignored there and
## never reach the binding. Callbacks build their argument array with `fn`
## first and call _run(_call, ...) directly.
func _run_script(fn: LuaFunction, args: Array, keep_value: bool = false) -> RunResult:
	var full: Array = [fn]
	full.append_array(args)
	return _run(_call, full, keep_value)


## `keep_value` is true only for runs whose returned table the host keeps (the
## weapon and the names list). Other runs drop a returned table or function.
## Script code runs through _call (see _run_script); _names_of is host code.
func _run(fn: LuaFunction, args: Array, keep_value: bool = false) -> RunResult:
	if _closed:
		return _fail("script host shut down", "")
	var result := RunResult.new()
	_reset_watchdog()
	_reset_print_buffer()
	var co: LuaCoroutine = LuaCoroutine.create(fn)
	_arm(co)
	_in_lua = true
	var resumed: Variant = co.resumev(args)
	var extra := 0
	while co.status == LuaThread.STATUS_YIELD and not _killed and not _shutdown_after and extra < MAX_EXTRA_RESUMES:
		resumed = co.resumev([])
		extra += 1
	var yielded := co.status == LuaThread.STATUS_YIELD
	if yielded:
		_parked.append(co)
	_in_lua = false
	# lua-gdextension 0.8.2 ties each LuaTable / LuaFunction wrapper to the Lua
	# thread it was read from. A value the host keeps is re-read through `_host`
	# so its wrapper is tied to the main thread. The binding reuses a live
	# wrapper for the same value, so the old one is released first; if something
	# else still holds it, `co` is kept with the state instead (once per load).
	# Any other returned table or function is dropped here, while `co` is alive.
	if resumed is LuaObject:
		if keep_value and _host != null:
			# `resumed` is the only holder of the old wrapper here.
			var old_id := _instance_id(resumed)
			_host.rawset("_rebind", resumed)
			resumed = null
			resumed = _host.rawget("_rebind")
			_host.rawset("_rebind", null)
			if _instance_id(resumed) == old_id and not _value_threads.has(co):
				_value_threads.append(co)
		else:
			resumed = null
	_drain_print_buffer()
	result.output = _output.duplicate()
	if _killed:
		result.stopped = _kill_reason
		result.stop_line = _kill_line
		result.error = "script timeout (%s)" % _kill_reason
	elif yielded:
		result.error = "script yielded (wait() is not in this slice)"
	elif resumed is LuaError:
		result.error = _lua_error_message(resumed)
	else:
		result.ok = true
		result.value = resumed
	if _shutdown_after:
		_shutdown_after = false
		shutdown()
	return result


func _reset_watchdog() -> void:
	_instr = 0
	_killed = false
	_kill_reason = ""
	_kill_line = 0
	_t0 = Time.get_ticks_msec()
	_threads.clear()
	_output = PackedStringArray()


func _arm(co: LuaThread) -> void:
	_threads.append(co)
	co.set_hook(Callable(self, "_hook"), LuaThread.HOOK_MASK_COUNT, HOOK_STRIDE)


func _hook(_debug: Variant) -> int:
	_note_host_call()
	if _stop_only or _closed:
		return int(LuaThread.HOOK_YIELD)
	_instr += HOOK_STRIDE
	var mem := int(_state.get_memory_used())
	if mem > _mem_peak:
		_mem_peak = mem
	if _instr > instruction_budget:
		_kill_reason = "instruction budget"
	elif mem > MEMORY_CAP:
		_kill_reason = "memory cap"
	elif Time.get_ticks_msec() - _t0 > wall_msec:
		_kill_reason = "wall clock"
	if _kill_reason != "":
		if not _killed:
			_killed = true
			_kill_line = _stop_line_of(_debug)
			for i in _threads.size():
				var th: LuaThread = _threads[i]
				th.set_hook(Callable(self, "_hook"), LuaThread.HOOK_MASK_COUNT, 1)
		return int(LuaThread.HOOK_YIELD)
	return int(LuaThread.HOOK_OK)


## Line of the hooked frame when it belongs to the loaded player chunk. Read
## once, on the stop verdict, never on the normal stride path.
func _stop_line_of(debug: Variant) -> int:
	if not debug is LuaDebug:
		return 0
	@warning_ignore("unsafe_cast")
	var info := debug as LuaDebug
	if info.source != "@" + _chunk_name and info.source != "@" + _loading_chunk:
		return 0
	return maxi(info.current_line, 0)


func _instance_id(v: Variant) -> int:
	if v is Object:
		@warning_ignore("unsafe_cast")
		return (v as Object).get_instance_id()
	return 0


func _clear_pending() -> void:
	_pending_spawns.clear()
	_pending_velocity_set = false
	_pending_velocity = Vector2.ZERO
	_pending_children.clear()


func _fail(message: String, chunk_name: String) -> RunResult:
	var result := RunResult.new()
	result.error = message
	result.chunk_name = chunk_name
	return result


func _lua_print(text: Variant = null) -> void:
	_note_host_call()
	if _stop_only or _closed:
		return
	_output.append(str(text))


func _reset_print_buffer() -> void:
	if _host == null:
		return
	var buf_v: Variant = _host.get("_output")
	if buf_v is LuaTable:
		_as_table(buf_v).set("n", 0)


func _drain_print_buffer() -> void:
	if _host == null:
		return
	var buf_v: Variant = _host.get("_output")
	if not buf_v is LuaTable:
		return
	var buf := _as_table(buf_v)
	var n_v: Variant = buf.get("n", 0)
	if not _read_number(n_v) or not is_finite(_number) or _number < 0.0:
		return
	var n := int(_number)
	for i in n:
		_output.append(str(buf.get(i + 1, "")))


## Reads the Lua-side velocity and child list. Empty string means they were
## copied onto the pending fields. A bad record fails the hook and commits nothing.
func _take_lua_bullet_pending() -> String:
	if _host == null:
		return ""
	var vel_v: Variant = _host.get("_vel")
	if vel_v is LuaTable:
		var vel := _as_table(vel_v)
		var armed: Variant = vel.get(3, false)
		if armed == true:
			var x: Variant = vel.get(1, null)
			var y: Variant = vel.get(2, null)
			if not _read_number(x):
				return "set_velocity: expected two numbers"
			var vx := _number
			if not _read_number(y):
				return "set_velocity: expected two numbers"
			_pending_velocity_set = true
			_pending_velocity = Vector2(vx, _number)
	var kids_v: Variant = _host.get("_kids")
	if not kids_v is LuaTable:
		return ""
	var kids := _as_table(kids_v)
	var n_v: Variant = kids.get("n", 0)
	if not _read_number(n_v) or not is_finite(_number) or _number < 0.0:
		return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
	var n := int(_number)
	for i in n:
		var rec_v: Variant = kids.get(i + 1, null)
		if not rec_v is LuaTable:
			return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
		var rec := _as_table(rec_v)
		var built := _shot_from_record(rec)
		if built == null:
			return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
		_pending_children.append(built)
	return ""


func _shot_from_record(rec: LuaTable) -> ShotRequest:
	var x: Variant = rec.get(1, null)
	var y: Variant = rec.get(2, null)
	var vx: Variant = rec.get(3, null)
	var vy: Variant = rec.get(4, null)
	var life: Variant = rec.get(5, null)
	if not _read_number(x):
		return null
	var px := _number
	if not _read_number(y):
		return null
	var py := _number
	if not _read_number(vx):
		return null
	var pvx := _number
	if not _read_number(vy):
		return null
	var pvy := _number
	if not _read_number(life):
		return null
	var req := ShotRequest.with_velocity(Vector2(px, py), Vector2(pvx, pvy))
	req.lifetime = _number
	req.behavior_id = 0
	return req


## Applies the Lua command slots onto `_batch`. Empty string means they were
## accepted. A record that fails validation fails the callback, so nothing commits.
## Caps are applied again here: the table is not trusted.
func _flush_lua_commands() -> String:
	if _batch == null or _host == null:
		return "view expired"
	var tally_v: Variant = _host.get("_batch_tally")
	if not tally_v is LuaTable:
		return ""
	var tally := _as_table(tally_v)
	var packed_v: Variant = _host.get("_packed")
	if not packed_v is LuaTable:
		return "batch command was not a record"
	var packed := _as_table(packed_v)
	var extra_cmd := _nonneg_int(tally.get("cmd", 0))
	var extra_spawn := _nonneg_int(tally.get("spawn", 0))
	var n := _nonneg_int(tally.get("n", 0))
	if n > BatchView.CMD_CAP:
		extra_cmd += n - BatchView.CMD_CAP
		n = BatchView.CMD_CAP
	var seen_cmd := 0
	var seen_spawn := 0
	for i in n:
		if not _integral(packed.get(i + 1, null)):
			return "batch command was not a record"
		var code := int(_number)
		var op := code % 8
		var row := int(code / 8.0)
		if row < 0 or row >= _batch.n:
			return "batch command: row must be an integer in 0..%d" % (_batch.n - 1)
		if op == BatchView.CMD_SPAWN and seen_spawn >= BatchView.SPAWN_CAP:
			extra_spawn += 1
			continue
		if seen_cmd >= BatchView.CMD_CAP:
			extra_cmd += 1
			continue
		var base := i * 5
		if op == BatchView.CMD_KILL:
			_batch.kill(row)
		elif op == BatchView.CMD_TELEPORT:
			_batch.teleport(row, _cmd_nums[base], _cmd_nums[base + 1])
		elif op == BatchView.CMD_SPAWN:
			var req := ShotRequest.with_velocity(
				Vector2(_cmd_nums[base], _cmd_nums[base + 1]),
				Vector2(_cmd_nums[base + 2], _cmd_nums[base + 3])
			)
			req.lifetime = _cmd_nums[base + 4]
			req.behavior_id = 0
			_batch.spawn_child(row, req)
			seen_spawn += 1
		else:
			return "batch command was not a record"
		seen_cmd += 1
	_batch.note_dropped_commands(extra_cmd)
	_batch.note_dropped_spawns(extra_spawn)
	return ""


func _spawn_at(columns: Array[LuaTable], at: int) -> ShotRequest:
	if not _read_number(columns[2].get(at, null)):
		return null
	var px := _number
	if not _read_number(columns[3].get(at, null)):
		return null
	var py := _number
	if not _read_number(columns[4].get(at, null)):
		return null
	var pvx := _number
	if not _read_number(columns[5].get(at, null)):
		return null
	var pvy := _number
	if not _read_number(columns[6].get(at, null)):
		return null
	var req := ShotRequest.with_velocity(Vector2(px, py), Vector2(pvx, pvy))
	req.lifetime = _number
	req.behavior_id = 0
	return req


func _integral(v: Variant) -> bool:
	if not _read_number(v) or not is_finite(_number) or _number != floor(_number):
		return false
	return true


func _nonneg_int(v: Variant) -> int:
	if not _integral(v) or _number < 0.0:
		return 0
	return int(_number)


func _lua_dead() -> bool:
	_note_host_call()
	if _stop_only or _closed:
		return true
	return _killed


func _lua_reg_thread(co: Variant) -> void:
	_note_host_call()
	if _stop_only or _closed:
		return
	if not co is LuaThread:
		return
	var th := _as_thread(co)
	for i in _threads.size():
		if _threads[i] == th:
			return
	_threads.append(th)
	var stride := 1 if _killed else HOOK_STRIDE
	th.set_hook(Callable(self, "_hook"), LuaThread.HOOK_MASK_COUNT, stride)


func _read_number(v: Variant) -> bool:
	# NaN and inf count as numbers; the pool rejects them.
	if v is int:
		_number = float(_as_int(v))
		return true
	if v is float:
		_number = _as_float(v)
		return true
	return false


## Lua's binding returns Variant. The `is` check above is the guard; the cast
## is ignored because GUT reloads scripts with type narrowing turned off.
func _lua_error_message(v: Variant) -> String:
	@warning_ignore("unsafe_cast")
	return (v as LuaError).message


func _as_function(v: Variant) -> LuaFunction:
	@warning_ignore("unsafe_cast")
	return v as LuaFunction


func _as_table(v: Variant) -> LuaTable:
	@warning_ignore("unsafe_cast")
	return v as LuaTable


func _as_thread(v: Variant) -> LuaThread:
	@warning_ignore("unsafe_cast")
	return v as LuaThread


func _as_array(v: Variant) -> Array:
	@warning_ignore("unsafe_cast")
	return v as Array


func _as_int(v: Variant) -> int:
	@warning_ignore("unsafe_cast")
	return v as int


func _as_float(v: Variant) -> float:
	@warning_ignore("unsafe_cast")
	return v as float


func _lua_set_velocity(x: Variant, y: Variant) -> Variant:
	_note_host_call()
	if _stop_only or _closed:
		return "script host shut down"
	if not _read_number(x):
		return "set_velocity: expected two numbers"
	var vx := _number
	if not _read_number(y):
		return "set_velocity: expected two numbers"
	_pending_velocity_set = true
	_pending_velocity = Vector2(vx, _number)
	return null


func _token_matches(token: Variant) -> bool:
	if not _read_number(token) or not is_finite(_number) or _number != floor(_number):
		return false
	return int(_number) == _batch_token and _batch != null


func _batch_gate(token: Variant) -> String:
	if _batch == null or not _token_matches(token):
		return "view expired"
	return ""


## Empty string means `_row_value` is a legal row. Otherwise the message.
func _read_row(cmd: String, v: Variant) -> String:
	var msg := "%s: row must be an integer in 0..%d" % [cmd, _batch.n - 1]
	if v is String or v is bool:
		return msg
	if not _read_number(v) or not is_finite(_number) or _number != floor(_number):
		return msg
	var row := int(_number)
	if row < 0 or row >= _batch.n:
		return msg
	_row_value = row
	return ""


func _lua_batch_kill(token: Variant, i: Variant) -> Variant:
	_note_host_call()
	if _stop_only or _closed:
		return "view expired"
	var gate := _batch_gate(token)
	if gate != "":
		return gate
	var err := _read_row("kill", i)
	if err != "":
		return err
	_batch.kill(_row_value)
	return null


func _lua_batch_teleport(token: Variant, i: Variant, x: Variant, y: Variant) -> Variant:
	_note_host_call()
	if _stop_only or _closed:
		return "view expired"
	var gate := _batch_gate(token)
	if gate != "":
		return gate
	var err := _read_row("teleport", i)
	if err != "":
		return err
	var row := _row_value
	if not _read_number(x):
		return "teleport: expected (row, x, y)"
	var px := _number
	if not _read_number(y):
		return "teleport: expected (row, x, y)"
	_batch.teleport(row, px, _number)
	return null


func _lua_batch_spawn(token: Variant, i: Variant, x: Variant, y: Variant, vx: Variant, vy: Variant, life: Variant) -> Variant:
	_note_host_call()
	if _stop_only or _closed:
		return "view expired"
	var gate := _batch_gate(token)
	if gate != "":
		return gate
	var err := _read_row("spawn_child", i)
	if err != "":
		return err
	var row := _row_value
	if not _read_number(x):
		return "spawn_child: expected (row, x, y, vx, vy, lifetime)"
	var px := _number
	if not _read_number(y):
		return "spawn_child: expected (row, x, y, vx, vy, lifetime)"
	var py := _number
	if not _read_number(vx):
		return "spawn_child: expected (row, x, y, vx, vy, lifetime)"
	var pvx := _number
	if not _read_number(vy):
		return "spawn_child: expected (row, x, y, vx, vy, lifetime)"
	var pvy := _number
	if not _read_number(life):
		return "spawn_child: expected (row, x, y, vx, vy, lifetime)"
	var req := ShotRequest.with_velocity(Vector2(px, py), Vector2(pvx, pvy))
	req.lifetime = _number
	# The child is declarative, so it does not re-enter Lua from this callback.
	req.behavior_id = 0
	_batch.spawn_child(row, req)
	return null


func _lua_spawn_child(x: Variant, y: Variant, vx: Variant, vy: Variant, life: Variant) -> Variant:
	_note_host_call()
	if _stop_only or _closed:
		return "script host shut down"
	if not _read_number(x):
		return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
	var px := _number
	if not _read_number(y):
		return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
	var py := _number
	if not _read_number(vx):
		return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
	var pvx := _number
	if not _read_number(vy):
		return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
	var pvy := _number
	if not _read_number(life):
		return "spawn_child: expected numbers (x, y, vx, vy, lifetime)"
	var req := ShotRequest.with_velocity(Vector2(px, py), Vector2(pvx, pvy))
	req.lifetime = _number
	# Children of this slice are declarative. Giving them the same behavior
	# would re-enter Lua from inside the parent's hook.
	req.behavior_id = 0
	_pending_children.append(req)
	return null
