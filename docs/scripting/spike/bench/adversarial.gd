extends Node
# B4 spike: adversarial scripts vs. guard rails. One test per process (so crashes/hangs are attributable).
#   -- adversarial <test> <mode>     mode: g1 (host-owned yield watchdog + sandbox env) | naive (Lua-function error hook on main thread, full libs)
const COUNT := 1000                   # hook granularity (VM instructions)
const BUDGET_INSTR := 20_000_000      # per callback
const MEM_CAP := 64 * 1024 * 1024
const WALL_MS := 300
const NAIVE_BUDGET := 2_000_000

const TESTS := {
	"spin": [[], "while true do end"],
	"pcall_swallow": [[], "while true do pcall(function() while true do end end) end"],
	"error_loop": [[], "while true do pcall(error, 'x') end"],
	"close_handler_spin": [[], "local ok = pcall(function() local x <close> = setmetatable({}, {__close = function() while true do end end}); error('boom') end)"],
	"sethook_nil": [["debug"], "debug.sethook(); while true do end"],
	"sethook_own": [["debug"], "debug.sethook(function() end, '', 1); while true do end"],
	"sethook_via_package_loaded": [["package"], "package.loaded.debug.sethook(); while true do end"],
	"load_bypass": [[], "local d = load('return debug')(); if d then d.sethook() end; while true do end"],
	"coroutine_spin": [[], "local co = coroutine.wrap(function() while true do end end); co()"],
	"coroutine_resume_loop": [[], "local co = coroutine.create(function() while true do end end); while true do coroutine.resume(co) end"],
	"c_boundary_sort": [[], "while true do pcall(table.sort, {3, 2, 1}, function(a, b) while true do end end) end"],
	"memory_bomb_table": [[], "local t = {}; while true do t[#t + 1] = ('x'):rep(1000) end"],
	"gc_stop_bomb": [[], "collectgarbage('stop'); local t = {}; for i = 1, 1e9 do t[i] = {} end"],
	"string_rep_bomb": [[], "local s = ('x'):rep(2^28); print(#s)"],
	"string_rep_via_debug_upvalue": [["debug"], "local f = string.rep; local i = 1; while true do local n, v = debug.getupvalue(f, i); if not n then break end; if n == 'rs' then print(#v.rep('x', 2^28)) end; i = i + 1 end"],
	"recursion_lua": [[], "local function f() return 1 + f() end; f()"],
	"recursion_c_index": [[], "local t = setmetatable({}, {__index = function(t, k) return t[k] end}); return t.x"],
	"recursion_pcall": [[], "local function f() pcall(f) end; f()"],
	"pattern_bomb": [[], "local r = ('a'):rep(20000):match('.-b')"],
	"pattern_at_limit": [[], "local r = ('a'):rep(1024):match('.-b')"],
	"pattern_bomb_via_debug": [["debug"], "local f = string.match; local i = 1; while true do local n, v = debug.getupvalue(f, i); if not n then break end; if n == 'f' then v(('a'):rep(24000), '.-b') end; i = i + 1 end"],
	"memory_big_chunks": [[], "local t = {}; for i = 1, 100 do t[i] = ('x'):rep(1024 * 1024) end; return #t"],
	"gc_finalizer_spin": [[], "local t = setmetatable({}, {__gc = function() while true do end end}); t = nil; collectgarbage(); collectgarbage()"],
	"gc_finalizer_via_debug": [["debug"], "local mt = {}; local t = debug.setmetatable({}, {__gc = function() while true do end end}); t = nil; collectgarbage(); collectgarbage()"],
	"xpcall_handler_spin": [[], "while true do xpcall(function() error('x') end, function(m) while true do end end) end"],
	"xpcall_handler_error_loop": [[], "while true do xpcall(error, error, 'x') end"],
	"load_binary_chunk": [[], "local f = load(string.dump(function() return 1 end), 'x', 'b'); return f"],
	"dump_loadfile_dofile_absent": [[], "return tostring(string.dump) .. tostring(dofile) .. tostring(loadfile) .. tostring(_G.io) .. tostring(_G.os) .. tostring(_G.debug) .. tostring(_G.package) .. tostring(_G.require)"],
	"debug_upvalue_tamper": [["debug"], "local f = os and os.exit; print(tostring(debug.getupvalue) .. ' ' .. tostring(debug.setupvalue) .. ' ' .. tostring(debug.getregistry) .. ' ' .. tostring(debug.sethook == nil)); local ok, e = pcall(debug.getupvalue, string.rep, 1); print(tostring(ok) .. ' ' .. tostring(e))"],
	"debug_getlocal_wrapper_leak": [["debug"], "local seen = {}; local r = ('abc'):gsub('b', function() for lvl = 1, 6 do local i = 1; while true do local ok, n, v = pcall(debug.getlocal, lvl, i); if not ok or not n then break end; if type(v) == 'function' or type(v) == 'table' and n ~= 'seen' then seen[#seen + 1] = lvl .. ':' .. n .. ':' .. type(v) end; i = i + 1 end end return 'x' end); print(table.concat(seen, ','))"],
	"cap_matrix_none": [[], "print(tostring(io) .. ' os.time=' .. tostring(os.time ~= nil) .. ' os.execute=' .. tostring(os.execute) .. ' ' .. tostring(debug) .. tostring(package) .. tostring(require) .. tostring(coroutine ~= nil))"],
	"cap_matrix_io": [["io"], "print('io.open=' .. tostring(io.open ~= nil) .. ' io.popen=' .. tostring(io.popen) .. ' os.execute=' .. tostring(os.execute))"],
	"cap_matrix_os": [["os"], "print('os.execute=' .. tostring(os.execute ~= nil) .. ' os.getenv=' .. tostring(os.getenv ~= nil) .. ' io.popen=' .. tostring(io and io.popen ~= nil) .. ' io.open=' .. tostring(io and io.open))"],
	"cap_matrix_package": [["package"], "print('require=' .. tostring(require ~= nil) .. ' loadlib=' .. tostring(package.loadlib) .. ' searchers=' .. #package.searchers .. ' debug_in_loaded=' .. tostring(package.loaded.debug) .. ' io_in_loaded=' .. tostring(package.loaded.io))"],
	"cap_matrix_native": [["native"], "print('loadlib=' .. tostring(package.loadlib ~= nil) .. ' searchers=' .. #package.searchers)"],
	"xpcall_boundary_handler": [[], "while true do xpcall(table.sort, function(m) while true do end end, {3, 2, 1}, function(a, b) while true do end end) end"],
	"load_reader_function": [[], "load(function() while true do end end)"],
	"xpcall_semantics": [[], "local ok, e = xpcall(function() error('boom', 0) end, function(m) return 'handled:' .. m end); print(tostring(ok) .. ' ' .. tostring(e)); print(select('#', xpcall(function(a, b) return a + b, 7 end, print, 1, 2)) .. ' ' .. tostring(select(2, xpcall(function(a, b) return a + b end, print, 1, 2))))"],
	"os_exit": [["os"], "os.exit(0)"],
	"os_exit_in_coroutine": [["os"], "coroutine.wrap(function() os.exit(1) end)(); print('after')"],
	"facade_rawset": [[], "rawset(_G, 'spawn', nil); _G.set_player_hp = function() error('x') end; spawn = 5; rawset(_G, 'print', nil); return 1"],
	"facade_bad_values": [[], "spawn(0/0, math.huge, -math.huge, 1e308, 0/0); spawn('a', {}, nil, 1, 1); set_player_hp(0/0); set_player_hp(math.huge); return 1"],
}

var s: LuaState
var mode := "g1"
var killed := false
var kill_reason := ""
var exit_req := false
var instr := 0
var mem_max := 0
var t0 := 0
var log_lines := []
var native_calls := []

var hook_calls := 0
func hook(_ar):
	hook_calls += 1
	if OS.get_environment('ADV_DEBUG') != '' and (hook_calls < 6 or hook_calls % 200000 == 0 or (killed and hook_calls % 5000 == 0)): print('hook#', hook_calls, ' killed=', killed, ' instr=', instr)
	instr += COUNT
	var m := s.get_memory_used()
	if m > mem_max: mem_max = m
	if exit_req: kill_reason = "os.exit requested"
	elif instr > BUDGET_INSTR: kill_reason = "instruction budget"
	elif m > MEM_CAP: kill_reason = "memory cap"
	elif Time.get_ticks_msec() - t0 > WALL_MS: kill_reason = "wall clock"
	if kill_reason != "":
		if not killed:
			killed = true
			# C-boundary fix: after the verdict, fire on EVERY instruction so the first instruction outside a native call yields
			if fast_kill:
				for th in threads: th.set_hook(Callable(self, "hook"), LuaThread.HOOK_MASK_COUNT, 1)
		return LuaThread.HOOK_YIELD
	return 0

var threads := []
var fast_kill := true
func is_dead() -> bool:
	return killed or exit_req
func reg_thread(co) -> void:
	if co is LuaThread:
		threads.append(co)
		co.set_hook(Callable(self, "hook"), LuaThread.HOOK_MASK_COUNT, COUNT)

func h_print(a = null, b = null, c = null) -> void:
	log_lines.append(str(a))
func h_exit(_a = null) -> void:
	exit_req = true
func h_spawn(x = null, y = null, ang = null, spd = null, life = null) -> bool:
	# native validation: only crash-prevention clamps, no gameplay restriction
	var v := [x, y, ang, spd, life]
	for i in 5:
		if typeof(v[i]) != TYPE_FLOAT and typeof(v[i]) != TYPE_INT: v[i] = 0.0
		if is_nan(float(v[i])): v[i] = 0.0
		v[i] = clampf(float(v[i]), -1.0e7, 1.0e7)
	native_calls.append("spawn(%s)" % str(v))
	return true
func h_hp(v = null) -> void:
	var f := 0.0
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		f = float(v)
		if is_nan(f): native_calls.append("set_player_hp(NaN) ignored"); return
		f = clampf(f, -1.0e9, 1.0e9)
	native_calls.append("set_player_hp(%s)" % str(f))

func _ready() -> void:
	var a := OS.get_cmdline_user_args()
	var test: String = a[1]
	mode = a[2] if a.size() > 2 else "g1"
	var caps: Array = TESTS[test][0]
	var src: String = TESTS[test][1]
	s = LuaState.new()
	s.open_libraries(LuaState.ALL_LIBS)
	if a.size() > 3 and a[3] == "nofast": fast_kill = false
	var res
	t0 = Time.get_ticks_msec()
	var outcome := ""
	if mode == "naive":
		var hk = s.do_string("local used = 0; return function() used = used + %d; if used > %d then error('instruction budget exceeded', 0) end end" % [COUNT, NAIVE_BUDGET])
		s.main_thread.set_hook(hk, LuaThread.HOOK_MASK_COUNT, COUNT)
		var fn = s.load_string(src, "user.lua")
		res = fn.invoke() if fn is LuaFunction else fn
		outcome = _classify(res)
	else:
		var build = s.do_string(FileAccess.get_file_as_string("res://sandbox/sandbox.lua"))
		var capt: LuaTable = s.create_table()
		for c in caps: capt.set(c, true)
		var host: LuaTable = s.create_table()
		host.set("print", Callable(self, "h_print")); host.set("reg_thread", Callable(self, "reg_thread")); host.set("exit", Callable(self, "h_exit"))
		host.set("dead", Callable(self, "is_dead")); host.set("spawn", Callable(self, "h_spawn")); host.set("set_player_hp", Callable(self, "h_hp"))
		var env = build.invoke(capt, host)
		if env is LuaError:
			print("ADV_ERROR sandbox build: ", env.message); get_tree().quit(1); return
		var fn = s.load_string(src, "user.lua", env)
		if fn is LuaError:
			outcome = "LOAD_ERROR " + fn.message
		else:
			t0 = Time.get_ticks_msec()
			var co := LuaCoroutine.create(fn)
			co.set_hook(Callable(self, "hook"), LuaThread.HOOK_MASK_COUNT, COUNT)
			threads.append(co)
			res = co.resume()
			var n := 0
			while co.status == LuaThread.STATUS_YIELD and not killed and n < 1000:
				res = co.resume(); n += 1
			outcome = ("STOPPED (%s)" % kill_reason) if killed else _classify(res)
			co = null
	var ms := Time.get_ticks_msec() - t0
	# host health check: a fresh state still works and the main loop still ticks
	threads.clear()
	var s2 := LuaState.new(); s2.open_libraries(LuaState.LUA_BASE)
	var ok = s2.do_string("return 1 + 1")
	await get_tree().process_frame
	await get_tree().process_frame
	var extra := ""
	if not native_calls.is_empty(): extra = " native=" + str(native_calls)
	if not log_lines.is_empty(): extra += " printed=" + str(log_lines)
	print("ADV test=%s mode=%s outcome=%s ms=%d peak_lua_mem_mb=%.1f host_ok=%s heartbeat=ok%s" % [test, mode, outcome, ms, max(mem_max, s.get_memory_used()) / 1048576.0, str(ok == 2), extra])
	get_tree().quit()

func _classify(res) -> String:
	if res is LuaError: return "ERROR: " + res.message.split("\n")[0].substr(0, 90)
	return "COMPLETED"
