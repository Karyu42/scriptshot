extends Node
# Bench (a): raw call cost between GDScript/Godot and Lua, ns per call.
const N := 200000
const RUNS := 15

class Sink:
	extends RefCounted
	var n := 0
	var prop := 1.0
	func noop(): n += 1
	func one(_a): n += 1

var rows := []

func record(name: String, samples_ns: Array):
	print("%-44s median=%9.1f  p95=%9.1f ns/call" % [name, Stats.median(samples_ns), Stats.p95(samples_ns)])
	rows.append([name, Stats.median(samples_ns), Stats.p95(samples_ns)])

# time a Callable that performs N operations; returns ns per op
func timeit(f: Callable, n: int) -> float:
	var t0 := Time.get_ticks_usec()
	f.call()
	return float(Time.get_ticks_usec() - t0) * 1000.0 / n

func runs(name: String, f: Callable, n: int, base := 0.0) -> float:
	f.call()  # warm
	var s := []
	for i in RUNS:
		s.append(max(0.0, timeit(f, n) - base))
	record(name, s)
	return Stats.median(s)

func _ready():
	print("Godot ", Engine.get_version_info().string, "  Lua ", LuaState.get_lua_version_string(), " runtime=", LuaState.get_lua_runtime())
	print("N=", N, " RUNS=", RUNS, "  (loop overhead subtracted where noted)")
	var s := LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS | LuaState.GODOT_CLASSES)
	var sink := Sink.new()
	var vec := Vector2(3, 4)
	var dict := {"a": 1.0, "b": 2.0, "c": 3.0, "d": 4.0}
	var arr := [1.0, 2.0, 3.0, 4.0]
	var packed := PackedFloat32Array(); packed.resize(4096)
	s.globals["sink"] = sink
	s.globals["cb_noop"] = Callable(sink, "noop")
	s.globals["cb_one"] = Callable(sink, "one")
	s.globals["g_vec"] = vec
	s.globals["g_dict"] = dict
	s.globals["g_arr"] = arr
	s.globals["g_packed"] = packed
	var L = s.do_string("""
	local M = {}
	function M.empty_fn() end
	function M.f1(a) end
	function M.f4(a, b, c, d) end
	function M.loop_empty(n) for i = 1, n do end end
	function M.loop_lua_call(n) local f = M.empty_fn; for i = 1, n do f() end end
	function M.l2g_noop(n) local f = cb_noop; for i = 1, n do f() end end
	function M.l2g_float(n) local f = cb_one; for i = 1, n do f(1.5) end end
	function M.l2g_vec2(n) local f = cb_one; local v = g_vec; for i = 1, n do f(v) end end
	function M.l2g_vec2_new(n) local f = cb_one; for i = 1, n do f(Vector2(1, 2)) end end
	function M.l2g_dict(n) local f = cb_one; local d = g_dict; for i = 1, n do f(d) end end
	function M.l2g_arr(n) local f = cb_one; local a = g_arr; for i = 1, n do f(a) end end
	function M.l2g_luatable(n) local f = cb_one; for i = 1, n do f({x = 1, y = 2}) end end
	function M.l2g_packed(n) local f = cb_one; local p = g_packed; for i = 1, n do f(p) end end
	function M.l2g_obj_method(n) local o = sink; for i = 1, n do o:noop() end end
	function M.l2g_obj_native(n) local o = sink; for i = 1, n do o:get_reference_count() end end
	function M.read_vec2_x(n) local v = g_vec; local x; for i = 1, n do x = v.x end end
	function M.read_packed_idx(n) local p = g_packed; local x; for i = 1, n do x = p[i % 4096] end end
	function M.write_packed_idx(n) local p = g_packed; for i = 1, n do p[i % 4096] = 1.0 end end
	function M.read_obj_prop(n) local o = sink; local x; for i = 1, n do x = o.prop end end
	function M.write_obj_prop(n) local o = sink; for i = 1, n do o.prop = 2.0 end end
	function M.read_dict_key(n) local d = g_dict; local x; for i = 1, n do x = d.a end end
	return M
	""")
	var empty_fn = L.get("empty_fn"); var f1 = L.get("f1"); var f4 = L.get("f4")

	print("\n== Godot -> Lua (GDScript calls a Lua function), ns/call incl. GDScript loop+call overhead")
	var base_loop := func(n):
		for i in n: pass
	var bl = runs("gd empty loop (baseline)", func(): for i in N: pass, N)
	var cb := Callable(sink, "noop")
	runs("gd->gd Callable.call() noop (baseline)", func(): for i in N: cb.call(), N)
	runs("gd->gd method sink.noop() (baseline)", func(): for i in N: sink.noop(), N)
	runs("g2l invoke() no args", func(): for i in N: empty_fn.invoke(), N)
	runs("g2l invoke(float)", func(): for i in N: f1.invoke(1.5), N)
	runs("g2l invoke(Vector2)", func(): for i in N: f1.invoke(vec), N)
	runs("g2l invoke(Dictionary 4 keys)", func(): for i in N: f1.invoke(dict), N)
	runs("g2l invoke(Array 4 floats)", func(): for i in N: f1.invoke(arr), N)
	runs("g2l invoke(PackedFloat32Array 4096)", func(): for i in N: f1.invoke(packed), N)
	runs("g2l invoke(4 floats)", func(): for i in N: f4.invoke(1.0, 2.0, 3.0, 4.0), N)
	var lcb: Callable = empty_fn.to_callable()
	runs("g2l to_callable().call() no args", func(): for i in N: lcb.call(), N)

	print("\n== Lua -> Godot and in-Lua baselines (ns per op, Lua loop overhead subtracted)")
	var lb = runs("lua empty loop (per iteration, raw)", func(): L.get("loop_empty").invoke(N), N)
	runs("lua->lua function call", func(): L.get("loop_lua_call").invoke(N), N, lb)
	for nm in ["l2g_noop", "l2g_float", "l2g_vec2", "l2g_vec2_new", "l2g_dict", "l2g_arr", "l2g_luatable", "l2g_packed", "l2g_obj_method", "l2g_obj_native"]:
		var fn = L.get(nm)
		runs("lua->godot " + nm.substr(4), func(): fn.invoke(N), N, lb)
	print("\n== Property / element access from Lua (ns per op, loop subtracted)")
	for nm in ["read_vec2_x", "read_packed_idx", "write_packed_idx", "read_obj_prop", "write_obj_prop", "read_dict_key"]:
		var fn = L.get(nm)
		runs("lua " + nm, func(): fn.invoke(N), N, lb)
	print("sink.n=", sink.n)
	get_tree().quit()
