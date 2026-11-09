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
const BATCH_ROW_BUDGET := 64
## Ceiling for one on_batch call. Provisional; may change.
const BATCH_BUDGET_CEILING := 2_000_000
const HOOK_STRIDE := 1_000
const WALL_MSEC := 50
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

## Stock lua-gdextension crashes if a second LuaState that has hosted a Godot
## Callable is freed after another state was already freed. Hosts live until
## process exit. One state per weapon for a session is the M1 budget.
static var _process_hosts: Array[ScriptHost] = []
var _state: LuaState
var _env: LuaTable
var _host: LuaTable
var _make_bullet: LuaFunction
var _names_of: LuaFunction
var _ready := false
var _init_error := ""

var _weapon: LuaTable
var _names := PackedStringArray()
var _callbacks: Dictionary = {}

var _threads: Array[LuaThread] = []
## Coroutines the budget stopped, kept so they are not freed while suspended
## (lua-gdextension #240). The host itself is pinned for the process; see
## _process_hosts.
var _parked: Array[LuaThread] = []
var _instr := 0
var _killed := false
var _kill_reason := ""
var _t0 := 0
var _mem_peak := 0
var _output := PackedStringArray()

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


func _init() -> void:
	_pin()
	_state = LuaState.new()
	_state.open_libraries(LIBS)
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
	_host.set("print", Callable(self, "_lua_print"))
	_host.set("reg_thread", Callable(self, "_lua_reg_thread"))
	_host.set("dead", Callable(self, "_lua_dead"))
	_host.set("set_velocity", Callable(self, "_lua_set_velocity"))
	_host.set("spawn_child", Callable(self, "_lua_spawn_child"))
	_host.set("batch_kill", Callable(self, "_lua_batch_kill"))
	_host.set("batch_teleport", Callable(self, "_lua_batch_teleport"))
	_host.set("batch_spawn", Callable(self, "_lua_batch_spawn"))
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
	var names_src: Variant = _state.do_string(_NAMES_OF, "@scripting/names.lua")
	if not names_src is LuaFunction:
		_init_error = _lua_error_message(names_src) if names_src is LuaError else "names extractor failed"
		return
	_names_of = _as_function(names_src)
	_ready = true


## Pins this host for the process. See `_process_hosts`.
func _pin() -> void:
	if not _process_hosts.has(self):
		_process_hosts.append(self)


func is_ready() -> bool:
	return _ready


## Highest Lua heap seen by the count hook. The memory cap is soft: a script
## that allocates and returns between two samples can pass it.
func memory_peak() -> int:
	return _mem_peak


func has_weapon() -> bool:
	return _weapon != null


func has_callback(name: String) -> bool:
	return _callbacks.has(name)


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
	if not _ready:
		return _fail(_init_error, chunk_name)
	var loaded: Variant = _state.load_string(code, "@" + chunk_name, _env)
	if loaded is LuaError:
		return _fail(_lua_error_message(loaded), chunk_name)
	if not loaded is LuaFunction:
		return _fail("load did not return a function", chunk_name)
	var result := _run(_as_function(loaded), [])
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
	return result


func load_file(path: String) -> RunResult:
	if not FileAccess.file_exists(path):
		return _fail("file not found: %s" % path, path)
	var code := FileAccess.get_file_as_string(path)
	var name := path.trim_prefix("res://")
	return load_string(code, name)


## Calls a weapon function under the budget. `arg` is the second Lua argument
## (a hit table, a despawn reason) when `pass_arg` is true. On failure the
## pending velocity and child spawns are dropped.
func call_hook(
	name: String,
	id: int,
	x: float,
	y: float,
	arg: Variant = null,
	pass_arg: bool = false
) -> RunResult:
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
	var bullet_v: Variant = _make_bullet.invoke(id, x, y)
	if bullet_v is LuaError:
		return _fail(_lua_error_message(bullet_v), name)
	if not bullet_v is LuaTable:
		return _fail("make_bullet did not return a table", name)
	var args: Array = [bullet_v]
	if pass_arg:
		args.append(arg)
	var result := _run(_as_function(fn), args)
	result.chunk_name = name
	if not result.ok:
		_clear_pending()
	return result


## Calls `on_batch(v, dt)`. `v`'s columns are the view's packed copies, so a
## later zero-copy column object can replace them without a script change.
## On failure the view is marked `discard` and the caller commits nothing.
func call_batch(batch: BatchView) -> RunResult:
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
	var view_v: Variant = _as_function(maker).invoke(
		_batch_token, batch.n, batch.id, batch.px, batch.py, batch.vx, batch.vy, batch.age, batch.pa, batch.pb, batch.owner, batch.dt
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
	var result := _run(_as_function(fn), [view_v, batch.dt])
	instruction_budget = saved_budget
	result.chunk_name = "on_batch"
	_end_batch()
	if not result.ok:
		batch.discard = true
	return result


func _end_batch() -> void:
	if _host != null:
		var expire: Variant = _host.get("expire_batch")
		if expire is LuaFunction:
			_as_function(expire).invoke()
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
	var extracted := _run(_names_of, [weapon])
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


func _run(fn: LuaFunction, args: Array) -> RunResult:
	var result := RunResult.new()
	_reset_watchdog()
	var co := LuaCoroutine.create(fn)
	_arm(co)
	var resumed: Variant = co.resumev(args)
	var extra := 0
	while co.status == LuaThread.STATUS_YIELD and not _killed and extra < MAX_EXTRA_RESUMES:
		resumed = co.resumev([])
		extra += 1
	if co.status == LuaThread.STATUS_YIELD:
		_parked.append(co)
	result.output = _output.duplicate()
	if _killed:
		result.stopped = _kill_reason
		result.error = "script timeout (%s)" % _kill_reason
		return result
	if co.status == LuaThread.STATUS_YIELD:
		result.error = "script yielded (wait() is not in this slice)"
		return result
	if resumed is LuaError:
		result.error = _lua_error_message(resumed)
		return result
	result.ok = true
	result.value = resumed
	return result


func _reset_watchdog() -> void:
	_instr = 0
	_killed = false
	_kill_reason = ""
	_t0 = Time.get_ticks_msec()
	_threads.clear()
	_output = PackedStringArray()


func _arm(co: LuaThread) -> void:
	_threads.append(co)
	co.set_hook(Callable(self, "_hook"), LuaThread.HOOK_MASK_COUNT, HOOK_STRIDE)


func _hook(_debug: Variant) -> int:
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
			for i in _threads.size():
				var th: LuaThread = _threads[i]
				th.set_hook(Callable(self, "_hook"), LuaThread.HOOK_MASK_COUNT, 1)
		return int(LuaThread.HOOK_YIELD)
	return int(LuaThread.HOOK_OK)


func _clear_pending() -> void:
	_pending_velocity_set = false
	_pending_velocity = Vector2.ZERO
	_pending_children.clear()


func _fail(message: String, chunk_name: String) -> RunResult:
	var result := RunResult.new()
	result.error = message
	result.chunk_name = chunk_name
	return result


func _lua_print(text: Variant = null) -> void:
	_output.append(str(text))


func _lua_dead() -> bool:
	return _killed


func _lua_reg_thread(co: Variant) -> void:
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
	var gate := _batch_gate(token)
	if gate != "":
		return gate
	var err := _read_row("kill", i)
	if err != "":
		return err
	_batch.kill(_row_value)
	return null


func _lua_batch_teleport(token: Variant, i: Variant, x: Variant, y: Variant) -> Variant:
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
