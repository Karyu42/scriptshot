extends Node
# Bench (b): realistic bullet shapes. Native-side struct-of-arrays pool in GDScript;
# Lua invoked only for events. Reports Lua-phase ms per "frame" (median / p95 over pooled frames).
const WARM := 30
const FRAMES := 100
const REPEATS := 5
const DT := 1.0 / 60.0

var s: LuaState
var L
var N := 0
# native pool
var px := PackedFloat32Array(); var py := PackedFloat32Array()
var pvx := PackedFloat32Array(); var pvy := PackedFloat32Array()
# command sinks
var spawn_count := 0
var kill_count := 0
var spawn_buf := PackedFloat32Array()

func cmd_vel(id: int, a: float, b: float) -> void:
	pvx[id] = a; pvy[id] = b
func cmd_spawn(x: float, y: float, ang: float, spd: float) -> void:
	spawn_buf[spawn_count * 4] = x; spawn_buf[spawn_count * 4 + 1] = y
	spawn_buf[spawn_count * 4 + 2] = ang; spawn_buf[spawn_count * 4 + 3] = spd
	spawn_count += 1
func cmd_kill(_id: int) -> void:
	kill_count += 1

const LUA_SRC := """
local S = {}
local dt = 1/60
local cos, sin = math.cos, math.sin
local M = {}
function M.init(n) for i = 0, n - 1 do S[i] = { age = 0, phase = (i % 100) * 0.01, hits = 0 } end end
function M.collect() collectgarbage('collect') end
-- floor: crossing only
function M.tick_empty(id) end
-- per-bullet callback: read per-shot state, compute, emit command via Callable
function M.tick_cmd(id, x, y, vx, vy)
  local st = S[id]; st.age = st.age + dt
  local a = 0.02 * (1 + st.phase)
  local c, s = cos(a), sin(a)
  cmd_vel(id, vx * c - vy * s, vx * s + vy * c)
end
-- batched callback: receives packed arrays, writes packed outputs, returns them
function M.tick_batch(ids, count, vxs, vys, out_vx, out_vy)
  for k = 0, count - 1 do
    local id = ids[k]
    local st = S[id]; st.age = st.age + dt
    local a = 0.02 * (1 + st.phase)
    local c, s = cos(a), sin(a)
    local vx, vy = vxs[id], vys[id]
    out_vx[k] = vx * c - vy * s
    out_vy[k] = vx * s + vy * c
  end
  return out_vx, out_vy
end
-- per-event hit: split into 3 children via Callable commands, kill parent
function M.hit_cmd(id, target, x, y)
  local st = S[id]; st.hits = st.hits + 1
  local p = st.phase
  cmd_spawn(x, y, p, 200); cmd_spawn(x, y, p + 2.094, 200); cmd_spawn(x, y, p + 4.188, 200)
  cmd_kill(id)
end
-- batched hits: arrays in, packed spawn buffer out
function M.hit_batch(ids, targets, xs, ys, count, out)
  local n = 0
  for k = 0, count - 1 do
    local id = ids[k]
    local st = S[id]; st.hits = st.hits + 1
    local p = st.phase
    local x, y = xs[k], ys[k]
    for j = 0, 2 do
      local o = n * 4
      out[o] = x; out[o+1] = y; out[o+2] = p + j * 2.094; out[o+3] = 200
      n = n + 1
    end
  end
  return out, n
end
return M
"""

func setup(n: int):
	N = n
	px.resize(n); py.resize(n); pvx.resize(n); pvy.resize(n)
	for i in n:
		px[i] = randf() * 1000; py[i] = randf() * 1000
		pvx[i] = 100.0; pvy[i] = 50.0
	spawn_buf.resize(4 * 3 * 2000)
	s = LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS)
	s.globals["cmd_vel"] = Callable(self, "cmd_vel")
	s.globals["cmd_spawn"] = Callable(self, "cmd_spawn")
	s.globals["cmd_kill"] = Callable(self, "cmd_kill")
	L = s.do_string(LUA_SRC)
	L.get("init").invoke(n)
	L.get("collect").invoke()

# returns per-frame ms samples
func run_mode(mode: String, count: int) -> Array:
	var f_empty = L.get("tick_empty"); var f_cmd = L.get("tick_cmd"); var f_batch = L.get("tick_batch")
	var h_cmd = L.get("hit_cmd"); var h_batch = L.get("hit_batch")
	var ids := PackedInt32Array(); ids.resize(count)
	var hx := PackedFloat32Array(); hx.resize(count); var hy := PackedFloat32Array(); hy.resize(count)
	var tg := PackedInt32Array(); tg.resize(count)
	var out_vx := PackedFloat32Array(); out_vx.resize(count)
	var out_vy := PackedFloat32Array(); out_vy.resize(count)
	var spawn_out := PackedFloat32Array(); spawn_out.resize(4 * 3 * count)
	var samples := []
	for frame in (WARM + FRAMES):
		var off: int = (frame * 7919) % maxi(1, N - count + 1)
		for k in count:
			ids[k] = off + k
		spawn_count = 0; kill_count = 0
		var t0 := Time.get_ticks_usec()
		match mode:
			"gd_native_tick":
				for k in count:
					var id := ids[k]
					var a := 0.02
					var c := cos(a); var sn := sin(a)
					var vx := pvx[id]; var vy := pvy[id]
					pvx[id] = vx * c - vy * sn; pvy[id] = vx * sn + vy * c
			"tick_empty":
				for k in count: f_empty.invoke(ids[k])
			"tick_cmd":
				for k in count:
					var id := ids[k]
					f_cmd.invoke(id, px[id], py[id], pvx[id], pvy[id])
			"tick_batch":
				var r = f_batch.invoke(ids, count, pvx, pvy, out_vx, out_vy)
				var ovx: PackedFloat32Array = r[0]; var ovy: PackedFloat32Array = r[1]
				for k in count:
					var id := ids[k]
					pvx[id] = ovx[k]; pvy[id] = ovy[k]
			"hit_cmd":
				for k in count:
					var id := ids[k]
					h_cmd.invoke(id, 0, px[id], py[id])
			"hit_batch":
				for k in count:
					var id := ids[k]
					hx[k] = px[id]; hy[k] = py[id]
				var r = h_batch.invoke(ids, tg, hx, hy, count, spawn_out)
				spawn_count = r[1]
		var dtu := Time.get_ticks_usec() - t0
		if frame >= WARM:
			samples.append(dtu / 1000.0)
	return samples

func summarize(label: String, samples: Array, extra := "") -> String:
	var line := "| %s | %.3f | %.3f | %.3f |%s" % [label, Stats.median(samples), Stats.p95(samples), samples.max(), extra]
	print(line)
	return line

func _ready():
	randomize()
	print("Godot ", Engine.get_version_info().string, " Lua ", LuaState.get_lua_version_string())
	print("frames per config: ", FRAMES * REPEATS, " (", REPEATS, " repeats x ", FRAMES, ", ", WARM, " warmup each)")
	var args := OS.get_cmdline_user_args()
	var Ns := [1000, 4000, 10000]
	print("\n### on_tick (ms per frame spent in Lua phase incl. GDScript-side command handling)")
	print("| N | % ticking | mode | callbacks/frame | median ms | p95 ms | max ms |")
	for n in Ns:
		for pct in [1, 10, 100]:
			var count: int = n * pct / 100
			for mode in ["gd_native_tick", "tick_empty", "tick_cmd", "tick_batch"]:
				var all := []
				for rep in REPEATS:
					setup(n)
					all.append_array(run_mode(mode, count))
				var line := "| %d | %d%% | %s | %d | %.3f | %.3f | %.3f |" % [n, pct, mode, count, Stats.median(all), Stats.p95(all), all.max()]
				print(line)
	print("\n### on_hit events")
	print("| N | hits/frame | mode | median ms | p95 ms | max ms |")
	for n in [4000, 10000]:
		for h in [50, 200, 1000]:
			for mode in ["hit_cmd", "hit_batch"]:
				var all := []
				for rep in REPEATS:
					setup(n)
					all.append_array(run_mode(mode, h))
				print("| %d | %d | %s | %.3f | %.3f | %.3f |" % [n, h, mode, Stats.median(all), Stats.p95(all), all.max()])
	print("\n### combined frame (N=4000): 10% ticking + 200 hits")
	for variant in [["tick_cmd", "hit_cmd"], ["tick_batch", "hit_batch"]]:
		var all := []
		for rep in REPEATS:
			setup(4000)
			var a := run_mode(variant[0], 400)
			var b := run_mode(variant[1], 200)
			for i in a.size(): all.append(a[i] + b[i])
		print("| combined %s+%s | median %.3f | p95 %.3f | max %.3f |" % [variant[0], variant[1], Stats.median(all), Stats.p95(all), all.max()])
	print("lua memory (N=4000 state tables) bytes: ", s.get_memory_used())
	get_tree().quit()
