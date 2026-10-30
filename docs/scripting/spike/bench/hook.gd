extends Node
# Bench (c) + (d): runaway-protection hook overhead/behaviour, error isolation, coroutine churn.
const RUNS := 9
var s: LuaState
var L

const SRC := """
local M = {}
local used, limit, step = 0, 0, 0
function M.arm(limit_, step_) used = 0; limit = limit_; step = step_ end
function M.used() return used end
function M.hook(ar)
  used = used + step
  if used > limit then error(BUDGET or 'instruction budget exceeded', 0) end
end
function M.loop(n) local x = 0; for i = 1, n do x = x + i * 2 end; return x end
function M.forever() while true do end end
function M.forever_pcall(n) local swallowed = 0; for i = 1, n do local ok = pcall(function() while true do end end); if not ok then swallowed = swallowed + 1 end end; return 'swallowed ' .. swallowed .. ' budget errors, script kept running' end
function M.install_safe_pcall()
  local old = pcall
  pcall = function(f, ...)
    local r = table.pack(old(f, ...))
    if not r[1] and r[2] == BUDGET then error(BUDGET, 0) end
    return table.unpack(r, 1, r.n)
  end
end
BUDGET = setmetatable({}, { __tostring = function() return 'instruction budget exceeded' end })
function M.ok() return 'ok' end
function M.coro_forever() local co = coroutine.wrap(function() while true do end end); co() end
function M.coro_finite(n) local co = coroutine.wrap(function() local x = 0; for i = 1, n do x = x + 1 end; return x end); return co() end
function M.slow_match(n) local t = os and os.clock and os.clock() or 0; local r = ('a'):rep(n):match('.-b'); return r end
function M.alloc_loop() local t = {}; for i = 1, 1e9 do t[i] = i end end
function M.big_string(n) local s = ('x'):rep(n); return #s end
function M.err_plain() error('boom') end
function M.err_table() error({code = 7}) end
function M.err_nil() local x = nil; return x.y end
function M.err_in_pcall() local ok, e = pcall(error, 'inner'); return tostring(ok) .. ':' .. tostring(e) end
function M.err_in_coro() local co = coroutine.create(function() error('in coro') end); local ok, e = coroutine.resume(co); return tostring(ok) .. ':' .. tostring(e) end
function M.call_bad_godot() return sink:no_such_method() end
function M.call_bad_args() return cb_one() end
function M.stack_overflow() local function f() return 1 + f() end; return f() end
function M.churn(n) for i = 1, n do local co = coroutine.create(function(a) coroutine.yield(a); return a end); coroutine.resume(co, i); if i % 2 == 0 then coroutine.resume(co) end end end
function M.noop() end
return M
"""

class Sink:
	extends RefCounted
	var n := 0
	func one(a, b = 0): n += 1

func hook_gd(_ar):  # GDScript Callable hook, no-op
	return 0

func mk_state() -> void:
	s = LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS | LuaState.GODOT_CLASSES)
	var sink := Sink.new()
	s.globals["sink"] = sink
	s.globals["cb_one"] = Callable(sink, "one")
	L = s.do_string(SRC)

func time_ms(f: Callable) -> float:
	var t0 := Time.get_ticks_usec()
	f.call()
	return (Time.get_ticks_usec() - t0) / 1000.0

func show(label: String, r) -> void:
	var t := "LuaError(%s) status=%d" % [r.message, r.status] if r is LuaError else str(r)
	print("  %-46s -> %s" % [label, t])

func sweep(label: String, f: Callable, setup: Callable) -> void:
	var xs := []
	for i in RUNS:
		setup.call()
		xs.append(time_ms(f))
	print("| %s | %.2f | %.2f |" % [label, Stats.median(xs), Stats.p95(xs)])

func _ready():
	print("Godot ", Engine.get_version_info().string, " Lua ", LuaState.get_lua_version_string())
	mk_state()
	var loopf = L.get("loop"); var arm = L.get("arm"); var hookf = L.get("hook")
	var N := 5000000
	print("\n### (c1) Count-hook overhead on a pure Lua arithmetic loop (%d iterations, ~%d VM instructions)" % [N, N * 4])
	print("| hook | median ms | p95 ms |")
	var main = s.main_thread
	var off := func(): main.set_hook(null, 0, 0)
	sweep("off", func(): loopf.invoke(N), off)
	for cnt in [100, 1000, 10000, 100000]:
		sweep("on, Lua-function hook, count=%d" % cnt, func(): loopf.invoke(N), func(): arm.invoke(1e18, cnt); main.set_hook(hookf, LuaThread.HOOK_MASK_COUNT, cnt))
	for cnt in [1000, 10000]:
		sweep("on, GDScript Callable hook, count=%d" % cnt, func(): loopf.invoke(N), func(): main.set_hook(Callable(self, "hook_gd"), LuaThread.HOOK_MASK_COUNT, cnt))
	main.set_hook(null, 0, 0)
	print("(hook calls for Lua hook count=1000 over this loop: ~", N * 4 / 1000, ")")

	print("\n### (c2) Hook overhead on realistic bullet callbacks (4000 per-bullet tick_cmd-style calls / frame)")
	var bsrc: String = load("res://bench/bullets.gd").LUA_SRC
	var ids := PackedInt32Array(); ids.resize(4000)
	for i in 4000: ids[i] = i
	var pvx := PackedFloat32Array(); pvx.resize(4000)
	var Bsink := BulletSink.new()
	s.globals["cmd_vel"] = Callable(Bsink, "cmd_vel"); s.globals["cmd_spawn"] = Callable(Bsink, "cmd_vel"); s.globals["cmd_kill"] = Callable(Bsink, "cmd_vel")
	var B = s.do_string(bsrc)
	B.get("init").invoke(4000)
	var tickf = B.get("tick_cmd")
	var frame_fn := func():
		for id in 4000: tickf.invoke(id, 1.0, 2.0, 3.0, 4.0)
	print("| hook | median ms/frame | p95 ms/frame |")
	sweep("off", frame_fn, off)
	for cnt in [100, 1000, 10000]:
		sweep("on, Lua-function hook, count=%d" % cnt, frame_fn, func(): arm.invoke(1e18, cnt); main.set_hook(hookf, LuaThread.HOOK_MASK_COUNT, cnt))
	main.set_hook(null, 0, 0)

	print("\n### (c3) Does the hook interrupt runaway code? (state stays usable afterwards)")
	arm.invoke(2_000_000, 1000); main.set_hook(hookf, LuaThread.HOOK_MASK_COUNT, 1000)
	var t0 := Time.get_ticks_usec()
	var r = L.get("forever").invoke()
	show("while true do end  (budget 2M instr)", r)
	print("    aborted after %.1f ms; hook-counted instructions: %s" % [(Time.get_ticks_usec() - t0) / 1000.0, L.get("used").invoke()])
	arm.invoke(2_000_000, 1000)
	show("next call L.ok() on same state", L.get("ok").invoke())
	arm.invoke(50_000_000, 1000)
	t0 = Time.get_ticks_usec()
	r = L.get("forever_pcall").invoke(2000)
	show("for 2000: pcall(function() while true do end end)  [raw pcall]", r)
	print("    took %.1f ms: a raw pcall SWALLOWS the budget error (an unbounded `while true do pcall(...) end` never terminates; observed hang in a first run)" % [(Time.get_ticks_usec() - t0) / 1000.0])
	L.get("install_safe_pcall").invoke()
	arm.invoke(50_000_000, 1000)
	t0 = Time.get_ticks_usec()
	r = L.get("forever_pcall").invoke(2000)
	show("same, with sandbox pcall that re-raises the budget sentinel", r)
	print("    aborted after %.1f ms" % [(Time.get_ticks_usec() - t0) / 1000.0])
	arm.invoke(2_000_000, 1000)
	r = L.get("alloc_loop").invoke()
	show("unbounded table growth (budget 2M instr)", r)
	print("    Lua memory after abort: %.1f MB" % [s.get_memory_used() / 1048576.0])
	s.collect_garbage()
	print("    Lua memory after collect_garbage: %.1f MB" % [s.get_memory_used() / 1048576.0])
	# A hook is NOT consulted inside native library calls
	for n in [2000, 8000, 16000]:
		arm.invoke(2_000_000, 1000)
		t0 = Time.get_ticks_usec()
		r = L.get("slow_match").invoke(n)
		print("  pathological ('a'):rep(%d):match('.-b') -> %s after %.1f ms (budget NOT triggered: only a few VM instructions)" % [n, "LuaError" if r is LuaError else str(r), (Time.get_ticks_usec() - t0) / 1000.0])
	arm.invoke(2_000_000, 1000)
	var before := s.get_memory_used()
	t0 = Time.get_ticks_usec()
	r = L.get("big_string").invoke(1 << 27)
	print("  ('x'):rep(2^27) -> %s, took %.1f ms, Lua mem now %.1f MB (no memory cap in binding)" % [str(r), (Time.get_ticks_usec() - t0) / 1000.0, s.get_memory_used() / 1048576.0])
	s.collect_garbage()
	main.set_hook(null, 0, 0)

	print("\n### (c4) Hook inheritance for coroutines (finite loops, 30M iterations; budget 2M instr)")
	main.set_hook(hookf, LuaThread.HOOK_MASK_COUNT, 1000); arm.invoke(2_000_000, 1000)
	t0 = Time.get_ticks_usec()
	r = L.get("coro_finite").invoke(30_000_000)
	show("Lua-created coroutine.wrap loop (hook set on main thread)", r)
	print("    took %.1f ms (an aborted run would be ~ms; a full run ~hundreds of ms)" % [(Time.get_ticks_usec() - t0) / 1000.0])
	main.set_hook(null, 0, 0)
	# GDScript-created LuaCoroutine with HOOK_YIELD time slicing
	var co: LuaCoroutine = LuaCoroutine.create(L.get("loop"))
	var slices := [0]
	var yielder := func(_ar):
		slices[0] += 1
		return LuaThread.HOOK_YIELD
	co.set_hook(yielder, LuaThread.HOOK_MASK_COUNT, 100000)
	var res = co.resume(3000000)
	var guard := 0
	while co.status == LuaThread.STATUS_YIELD and guard < 10000:
		res = co.resume()
		guard += 1
	print("  LuaCoroutine + HOOK_YIELD every 100k instr: finished after %d yields (status=%d, result=%s)" % [slices[0], co.status, str(res)])
	# infinite loop in coroutine that the host kills after N slices
	var co2: LuaCoroutine = LuaCoroutine.create(L.get("forever"))
	var sl2 := [0]
	co2.set_hook(func(_ar): sl2[0] += 1; return LuaThread.HOOK_YIELD, LuaThread.HOOK_MASK_COUNT, 100000)
	co2.resume()
	var k := 0
	while co2.status == LuaThread.STATUS_YIELD and k < 20:
		co2.resume(); k += 1
	print("  infinite loop in LuaCoroutine: host stopped resuming after %d slices; status=%d (yield-based budget; discarding the coroutine kills it)" % [k + 1, co2.status])
	co2 = null

	print("\n### (d1) Error isolation: errors must come back as values, never crash")
	mk_state(); L = L
	for name in ["err_plain", "err_table", "err_nil", "err_in_pcall", "err_in_coro", "call_bad_godot", "call_bad_args", "stack_overflow"]:
		show(name, L.get(name).invoke())
	show("L.ok() still works afterwards", L.get("ok").invoke())
	show("syntax error load_string", s.load_string("function(", "bad"))
	show("do_string runtime error", s.do_string("error('x')"))
	var freed := RefCounted.new()
	s.globals["cb_dead"] = Callable(freed, "get_reference_count")
	freed = null
	show("calling Callable of freed RefCounted", s.do_string("return cb_dead()"))
	var nd := Node.new(); s.globals["nd"] = nd; nd.free()
	show("method on freed Node object from Lua", s.do_string("return nd:get_name()"))
	await get_tree().process_frame
	await get_tree().process_frame
	print("  engine main loop still ticking after errors: yes (2 frames processed)")

	print("\n### (d2) Coroutine churn (issue #240 style: create/finish/drop many coroutines)")
	mk_state()
	var cm := Time.get_ticks_usec()
	L.get("churn").invoke(200000)
	print("  Lua-side: 200k coroutine.create (half finished, half dropped suspended): %.1f ms; mem %.1f MB" % [(Time.get_ticks_usec() - cm) / 1000.0, s.get_memory_used() / 1048576.0])
	s.collect_garbage()
	print("  after collect_garbage: %.1f MB" % [s.get_memory_used() / 1048576.0])
	var fn = L.get("noop")
	cm = Time.get_ticks_usec()
	var created := 0
	for i in 100000:
		var c: LuaCoroutine = LuaCoroutine.create(fn)
		if i % 3 == 0: c.resume()   # finished
		elif i % 3 == 1:
			c.set_hook(func(_a): return LuaThread.HOOK_YIELD, LuaThread.HOOK_MASK_COUNT, 100)  # hooked, never resumed
		created += 1
		# otherwise dropped unstarted
		c = null
	print("  GDScript-side: 100k LuaCoroutine.create/drop (1/3 run, 1/3 hooked, 1/3 untouched): %.1f ms; created=%d; mem %.1f MB" % [(Time.get_ticks_usec() - cm) / 1000.0, created, s.get_memory_used() / 1048576.0])
	# issue #240 pattern: one new coroutine per frame, hook set, freed while suspended or after completion
	for frame in 3000:
		var c2: LuaCoroutine = LuaCoroutine.create(L.get("loop"))
		c2.set_hook(func(_a): return LuaThread.HOOK_YIELD, LuaThread.HOOK_MASK_COUNT, 50)
		c2.resume(1000)
		if frame % 2 == 0:
			while c2.status == LuaThread.STATUS_YIELD: c2.resume()
		c2 = null
		if frame % 500 == 0: await get_tree().process_frame
	s.collect_garbage()
	print("  3000 per-frame hooked coroutines (half finished, half dropped suspended) across frames: no crash; mem %.1f MB" % [s.get_memory_used() / 1048576.0])
	print("  state freed / recreated x200 ...")
	for i in 200:
		mk_state()
		L.get("churn").invoke(500)
	s = null; L = null
	print("DONE (process still alive)")
	get_tree().quit()

class BulletSink:
	extends RefCounted
	func cmd_vel(a = 0, b = 0, c = 0, d = 0): pass
