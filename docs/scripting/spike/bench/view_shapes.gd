extends Node
# Overhead of a backend-agnostic batch view (Lua-side wrappers over packed arrays) vs raw packed access.
# Kernel per bullet: read pos(x,y) vel(x,y) age, compute, write out_vel(x,y). 0-based indices as in the batch API.
# Args after `--`: view_shapes [n] [reps]
const LUA := """
local M = {}
local sqrt = math.sqrt

-- the arithmetic every variant shares (kept identical so only the access path differs)
local function kernel(px, py, vx, vy, age)
  local dx, dy = 100.0 - px, 50.0 - py
  local d = sqrt(dx * dx + dy * dy) + 1.0
  local nx, ny = vx + dx / d * 0.5, vy + dy / d * 0.5
  if age > 1.0 then nx, ny = nx * 0.99, ny * 0.99 end
  return nx, ny
end

-- R: raw interleaved packed arrays (what batch B hands out today)
function M.raw(pos, vel, age, out_vel, n)
  local acc = 0.0
  for i = 0, n - 1 do
    local nx, ny = kernel(pos[2*i], pos[2*i+1], vel[2*i], vel[2*i+1], age[i])
    out_vel[2*i] = nx; out_vel[2*i+1] = ny
    acc = acc + nx
  end
  return acc
end

-- Shape 1: methods on the view, v:pos(i) -> x, y ; v:vel(i) -> x, y ; v:age(i) ; v:set_vel(i, x, y)
local function make_methods(pos, vel, age, out_vel, n)
  local v = { n = n }
  function v.pos(_, i) return pos[2*i], pos[2*i+1] end
  function v.vel(_, i) return vel[2*i], vel[2*i+1] end
  function v.age(_, i) return age[i] end
  function v.set_vel(_, i, x, y) out_vel[2*i] = x; out_vel[2*i+1] = y end
  return v
end
function M.make_methods(...) return make_methods(...) end
function M.methods(v)
  local acc = 0.0
  for i = 0, v.n - 1 do
    local px, py = v:pos(i); local vx, vy = v:vel(i)
    local nx, ny = kernel(px, py, vx, vy, v:age(i))
    v:set_vel(i, nx, ny)
    acc = acc + nx
  end
  return acc
end
-- Shape 1b: the same methods, fetched once into locals (hoisted); v.pos is still the same function
function M.methods_hoisted(v)
  local pos, vel, age, set_vel = v.pos, v.vel, v.age, v.set_vel
  local acc = 0.0
  for i = 0, v.n - 1 do
    local px, py = pos(v, i); local vx, vy = vel(v, i)
    local nx, ny = kernel(px, py, vx, vy, age(v, i))
    set_vel(v, i, nx, ny)
    acc = acc + nx
  end
  return acc
end

-- Shape 2: column proxies with __index/__newindex, v.px[i] ... v.out_vx[i] = ...
local function column(arr, stride, off)
  return setmetatable({}, {
    __index = function(_, i) return arr[stride * i + off] end,
    __newindex = function(_, i, x) arr[stride * i + off] = x end })
end
function M.make_columns(pos, vel, age, out_vel, n)
  return { n = n, px = column(pos, 2, 0), py = column(pos, 2, 1), vx = column(vel, 2, 0), vy = column(vel, 2, 1),
           age = column(age, 1, 0), out_vx = column(out_vel, 2, 0), out_vy = column(out_vel, 2, 1) }
end
function M.columns(v)
  local px, py, vx, vy, age, ox, oy = v.px, v.py, v.vx, v.vy, v.age, v.out_vx, v.out_vy
  local acc = 0.0
  for i = 0, v.n - 1 do
    local nx, ny = kernel(px[i], py[i], vx[i], vy[i], age[i])
    ox[i] = nx; oy[i] = ny
    acc = acc + nx
  end
  return acc
end

-- Shape 2r: the same v.px[i] shape, but the columns ARE separate packed arrays (GDScript backing after a de-interleave copy)
function M.columns_raw(v)
  local px, py, vx, vy, age, ox, oy = v.px, v.py, v.vx, v.vy, v.age, v.out_vx, v.out_vy
  local acc = 0.0
  for i = 0, v.n - 1 do
    local nx, ny = kernel(px[i], py[i], vx[i], vy[i], age[i])
    ox[i] = nx; oy[i] = ny
    acc = acc + nx
  end
  return acc
end
-- Shape 2u: same, but un-hoisted (v.px[i] spelled out every time, as a script author would write it)
function M.columns_raw_unhoisted(v)
  local acc = 0.0
  for i = 0, v.n - 1 do
    local nx, ny = kernel(v.px[i], v.py[i], v.vx[i], v.vy[i], v.age[i])
    v.out_vx[i] = nx; v.out_vy[i] = ny
    acc = acc + nx
  end
  return acc
end
function M.make_raw_columns(px, py, vx, vy, age, ox, oy, n)
  return { n = n, px = px, py = py, vx = vx, vy = vy, age = age, out_vx = ox, out_vy = oy }
end

-- Shape 3: Vector2 elements, v.pos[i].x (PackedVector2Array backing; writes create a Vector2)
function M.vec2(pos2, vel2, age, out2, n)
  local acc = 0.0
  for i = 0, n - 1 do
    local p, v = pos2[i], vel2[i]
    local nx, ny = kernel(p.x, p.y, v.x, v.y, age[i])
    out2[i] = Vector2(nx, ny)
    acc = acc + nx
  end
  return acc
end

-- Shape 4: method taking the whole vector, v:pos(i) -> Vector2 (same cost class as 3 + a call); skipped.
return M
"""

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var n := 4000
	var reps := 41
	if args.size() > 1: n = int(args[1])
	if args.size() > 2: reps = int(args[2])
	var s := LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS)
	var M = s.do_string(LUA)
	if M is LuaError:
		print("LUAERR ", M); get_tree().quit(1); return
	var pos := PackedFloat32Array(); pos.resize(2 * n)
	var vel := PackedFloat32Array(); vel.resize(2 * n)
	var age := PackedFloat32Array(); age.resize(n)
	var out := PackedFloat32Array(); out.resize(2 * n)
	var pos2 := PackedVector2Array(); pos2.resize(n)
	var vel2 := PackedVector2Array(); vel2.resize(n)
	var out2 := PackedVector2Array(); out2.resize(n)
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for i in n:
		pos[2 * i] = rng.randf_range(-500, 500); pos[2 * i + 1] = rng.randf_range(-500, 500)
		vel[2 * i] = rng.randf_range(-50, 50); vel[2 * i + 1] = rng.randf_range(-50, 50)
		age[i] = rng.randf() * 2.0
		pos2[i] = Vector2(pos[2 * i], pos[2 * i + 1]); vel2[i] = Vector2(vel[2 * i], vel[2 * i + 1])
	var v_methods = M.get("make_methods").invoke(pos, vel, age, out, n)
	var v_cols = M.get("make_columns").invoke(pos, vel, age, out, n)
	var px := PackedFloat32Array(); px.resize(n); var py := PackedFloat32Array(); py.resize(n)
	var vxa := PackedFloat32Array(); vxa.resize(n); var vya := PackedFloat32Array(); vya.resize(n)
	var ox := PackedFloat32Array(); ox.resize(n); var oy := PackedFloat32Array(); oy.resize(n)
	for i in n:
		px[i] = pos[2 * i]; py[i] = pos[2 * i + 1]; vxa[i] = vel[2 * i]; vya[i] = vel[2 * i + 1]
	var v_raw_cols = M.get("make_raw_columns").invoke(px, py, vxa, vya, age, ox, oy, n)
	var variants := [
		["R  raw interleaved  pos[2*i]", M.get("raw"), [pos, vel, age, out, n]],
		["S1 methods  v:pos(i)", M.get("methods"), [v_methods]],
		["S1h methods, hoisted  pos(v,i)", M.get("methods_hoisted"), [v_methods]],
		["S2 column proxies (Lua __index)  v.px[i]", M.get("columns"), [v_cols]],
		["S2r separate packed columns, hoisted  px[i]", M.get("columns_raw"), [v_raw_cols]],
		["S2u separate packed columns, un-hoisted  v.px[i]", M.get("columns_raw_unhoisted"), [v_raw_cols]],
		["S3 Vector2 elements  v.pos[i].x", M.get("vec2"), [pos2, vel2, age, out2, n]],
	]
	print("### view shapes: n=%d bullets, %d reps (median / p95 of ms per batch call; ns per bullet in brackets)" % [n, reps])
	print("| shape | median ms | p95 ms | ns/bullet | vs raw |")
	print("|---|---|---|---|---|")
	var base := 0.0
	var order := range(variants.size())
	for rep_round in 1:
		pass
	for vi in order:
		var v = variants[vi]
		var times := []
		var f: LuaFunction = v[1]
		for w in 5: f.invoke.callv(v[2])
		for r in reps:
			var t0 := Time.get_ticks_usec()
			f.invoke.callv(v[2])
			times.append((Time.get_ticks_usec() - t0) / 1000.0)
		var med: float = Stats.median(times)
		if vi == 0: base = med
		print("| %s | %.3f | %.3f | %.0f | %.2fx |" % [v[0], med, Stats.p95(times), med * 1e6 / n, med / base])
	# cost of the GDScript backing's copies: de-interleave 4 columns in, interleave 2 back out
	var gat := []
	for r in reps:
		var t0 := Time.get_ticks_usec()
		for i in n:
			var p := pos2[i]; var q := vel2[i]
			px[i] = p.x; py[i] = p.y; vxa[i] = q.x; vya[i] = q.y
		for i in n:
			out2[i] = Vector2(ox[i], oy[i])
		gat.append((Time.get_ticks_usec() - t0) / 1000.0)
	print("| GDScript de-interleave 4 cols + re-interleave 2 cols (per batch) | %.3f | %.3f | %.0f | |" % [Stats.median(gat), Stats.p95(gat), Stats.median(gat) * 1e6 / n])
	get_tree().quit()
