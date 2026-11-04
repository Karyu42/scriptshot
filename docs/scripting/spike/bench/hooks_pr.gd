extends Node
# Hook-granularity spike, modelled on PR #2's interface (BulletPool / BulletBehavior / ShotEmitter).
const ARENA := Rect2(-1280, -720, 2560, 1440)
const DT := 1.0 / 60.0
const WARM := 40
const FRAMES := 150
const REPEATS := 3

const LUA := """
local M = {}
local S = {}
local dt = 1/60
local sin, cos, atan = math.sin, math.cos, math.atan
-- shared steering law (scripted, per-frame): sinusoidal weave of the heading
local function steer(vx, vy, age, pa)
  local a = 1.5 * sin(age * 4 + pa) * dt
  local c, s = cos(a), sin(a)
  return vx * c - vy * s, vx * s + vy * c
end
-- Option A: per bullet
function M.on_update(i, x, y, vx, vy, age, pa)
  local nvx, nvy = steer(vx, vy, age, pa)
  set_vel(i, nvx, nvy)
  if i % 16 == 0 and age % 0.5 < dt then defer_spawn(x, y, atan(nvy, nvx) + 3.14159, 40) end   -- 1/16 of bullets drop a trail bullet every 0.5 s
end
-- Option B: one call per behavior per tick; packed in, packed out
function M.on_update_batch(ids, pos, vel, age, pa, n, delta, out_vel, cmds)
  local nc = 0
  for k = 0, n - 1 do
    local vx, vy = vel[2 * k], vel[2 * k + 1]
    local nvx, nvy = steer(vx, vy, age[k], pa[k])
    out_vel[2 * k] = nvx; out_vel[2 * k + 1] = nvy
    if ids[k] % 16 == 0 and age[k] % 0.5 < dt then
      local o = 4 * nc
      cmds[o] = pos[2 * k]; cmds[o + 1] = pos[2 * k + 1]; cmds[o + 2] = atan(nvy, nvx) + 3.14159; cmds[o + 3] = 40
      nc = nc + 1
    end
  end
  return out_vel, cmds, nc
end
-- Events. kind: 0 spawn, 1 hit, 2 despawn, 3 summary(count, sum_dmg, cx, cy)
function M.on_event(kind, i, dmg, x, y)
  local st = S[i]; if not st then st = { hits = 0, phase = (i % 100) * 0.01 }; S[i] = st end
  if kind == 0 then st.hits = 0; return end
  st.hits = st.hits + 1
  local p = st.phase
  defer_spawn(x, y, p, 200); defer_spawn(x, y, p + 2.094, 200); defer_spawn(x, y, p + 4.188, 200)
end
function M.on_events(ev, n, out)
  local m = 0
  for k = 0, n - 1 do
    local o = 5 * k
    local kind, i, a, x, y = ev[o], ev[o + 1], ev[o + 2], ev[o + 3], ev[o + 4]
    local st = S[i]; if not st then st = { hits = 0, phase = (i % 100) * 0.01 }; S[i] = st end
    if kind == 0 then st.hits = 0
    elseif kind == 3 then
      local q = 4 * m
      out[q] = x; out[q + 1] = y; out[q + 2] = 0; out[q + 3] = 100 + a; m = m + 1
    else
      st.hits = st.hits + 1
      local p = st.phase
      local q = 4 * m
      out[q] = x; out[q + 1] = y; out[q + 2] = p; out[q + 3] = 200
      out[q + 4] = x; out[q + 5] = y; out[q + 6] = p + 2.094; out[q + 7] = 200
      out[q + 8] = x; out[q + 9] = y; out[q + 10] = p + 4.188; out[q + 11] = 200
      m = m + 3
    end
  end
  return out, m
end
-- fire(): three ways to spawn n bullets from Lua
function M.fire_fields(req, emitter, n)
  for k = 0, n - 1 do
    local a = k * 0.3
    req:reset()
    req.position = Vector2(0, 0)
    req.velocity = Vector2(cos(a) * 300, sin(a) * 300)
    req.lifetime = 3
    emitter:request_shot(req)
  end
end
function M.fire_polar(api, n)
  for k = 0, n - 1 do api:polar(0, 0, k * 0.3, 300, 3) end
end
function M.fire_batch(api, buf, n)
  for k = 0, n - 1 do
    local o = 5 * k
    buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = k * 0.3; buf[o + 3] = 300; buf[o + 4] = 3
  end
  api:batch(buf, n)
end
return M
"""

class FireAPI:
	extends RefCounted
	var mgr: BulletManager
	var req := ShotRequest.new()
	func polar(x: float, y: float, ang: float, spd: float, life: float) -> void:
		req.reset()
		req.position = Vector2(x, y); req.velocity = Vector2.from_angle(ang) * spd; req.lifetime = life
		mgr.spawn(req)
	func batch(buf: PackedFloat32Array, n: int) -> void:
		for k in n:
			var o := k * 5
			req.reset()
			req.position = Vector2(buf[o], buf[o + 1]); req.velocity = Vector2.from_angle(buf[o + 2]) * buf[o + 3]; req.lifetime = buf[o + 4]
			mgr.spawn(req)

var rng := RandomNumberGenerator.new()
var mgr: SpikeManager
var s: LuaState
var L
var holder: Node

func make_state() -> void:
	s = LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS | LuaState.GODOT_CLASSES)

func make_world(mode: String, n_target: int, pct: int, throttle := 1) -> Dictionary:
	if holder != null:
		holder.free()
	holder = Node.new(); add_child(holder)
	mgr = SpikeManager.new()
	mgr.capacity = 32768
	mgr.world_bounds = ARENA.grow(32.0)
	mgr.auto_step = false
	mgr.render_enabled = false
	holder.add_child(mgr)
	for i in 32:
		var hb := Hurtbox.new()
		hb.radius = 24.0; hb.layer = Layers.ENEMY
		hb.position = Vector2(rng.randf_range(ARENA.position.x, ARENA.end.x), rng.randf_range(ARENA.position.y, ARENA.end.y))
		holder.add_child(hb)
	make_state()
	s.globals["set_vel"] = Callable(mgr, "set_vel")
	s.globals["defer_spawn"] = Callable(mgr, "defer_spawn")
	L = s.do_string(LUA)
	mgr.mode = mode
	mgr.throttle = throttle
	mgr.defer_life = 0.25
	var beh_id := 0
	var beh: LuaBehaviorA = null
	if mode == "A":
		beh = LuaBehaviorA.new(); beh.fn = L.get("on_update"); beh.throttle = throttle
		beh_id = mgr.register_behavior(beh)
	elif mode.begins_with("B"):
		beh_id = mgr.register_behavior(BulletBehavior.new())
		mgr.lua_batch = L.get("on_update_batch")
	return {"beh_id": beh_id, "beh": beh, "pct": pct, "mode": mode}

var _req := ShotRequest.new()
func top_up(w: Dictionary, n: int) -> void:
	var pool := mgr.pool
	while pool.count < n:
		_req.reset()
		_req.position = Vector2(rng.randf_range(ARENA.position.x, ARENA.end.x), rng.randf_range(ARENA.position.y, ARENA.end.y))
		_req.velocity = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(80.0, 320.0)
		_req.lifetime = rng.randf_range(2.0, 6.0)
		_req.radius = 3.0
		_req.hit_mask = Layers.ENEMY
		if rng.randi() % 100 < w.pct and w.beh_id != 0:
			_req.behavior_id = w.beh_id
			_req.param_a = rng.randf() * TAU
		else:
			_req.turn_rate = 0.5 if w.mode == "C" else 0.0   # declarative equivalent for option C
		if mgr.spawn(_req) < 0: break

func run_tick_config(mode: String, n: int, pct: int, throttle := 1) -> Dictionary:
	rng.seed = 12345
	var w := make_world(mode, n, pct, throttle)
	var hook := []; var total := []; var copyin := []; var lua := []; var apply := []; var work := []
	for rep in REPEATS:
		for f in (WARM + FRAMES):
			if w.beh != null: w.beh.tick = mgr.tick
			var t0 := Time.get_ticks_usec()
			top_up(w, n)
			mgr.step(DT)
			var wk := (Time.get_ticks_usec() - t0) / 1000.0
			if f >= WARM:
				work.append(wk); hook.append(mgr.t_hooks / 1000.0); total.append(mgr.t_total / 1000.0)
				copyin.append(mgr.t_copy_in / 1000.0); lua.append(mgr.t_lua / 1000.0); apply.append(mgr.t_apply / 1000.0)
	return {"hook_med": Stats.median(hook), "hook_p95": Stats.p95(hook), "step_med": Stats.median(total), "step_p95": Stats.p95(total),
		"copy": Stats.median(copyin), "lua": Stats.median(lua), "apply": Stats.median(apply), "hooked": mgr.pool.hooked_count, "mem": s.get_memory_used(), "alive": mgr.pool.count}

# ---------------------------------------------------------------- events
# mode: "per_bullet" | "batch" | "batch_cap" | "batch_coalesce"
func run_event_config(kind: int, h: int, mode: String, cap := 256) -> Dictionary:
	rng.seed = 777
	var w := make_world("C", 4000, 0)
	mgr.defer_life = 0.05
	var on_event = L.get("on_event"); var on_events = L.get("on_events")
	var times := []; var lua_only := []; var defers := []
	var ev := PackedFloat32Array(); ev.resize(5 * (h + 8))
	var out := PackedFloat32Array(); out.resize(12 * (h + 8) + 64)
	var dropped_total := 0
	for rep in REPEATS:
		for f in (WARM + FRAMES):
			top_up(w, 4000)
			mgr.step(DT)
			var pool := mgr.pool
			var t0 := Time.get_ticks_usec()
			var lua_us := 0
			var cnt := pool.count
			match mode:
				"per_bullet":
					for k in h:
						var i := rng.randi() % cnt
						var p := pool.pos[i]
						on_event.invoke(kind, i, pool.damage[i], p.x, p.y)
				_:
					var n := 0
					var agg_n := 0; var agg_d := 0.0; var agg_x := 0.0; var agg_y := 0.0
					var limit := cap if mode != "batch" else h
					for k in h:
						var i := rng.randi() % cnt
						var p := pool.pos[i]
						if n < limit:
							var o := 5 * n
							ev[o] = kind; ev[o + 1] = i; ev[o + 2] = pool.damage[i]; ev[o + 3] = p.x; ev[o + 4] = p.y
							n += 1
						elif mode == "batch_coalesce":
							agg_n += 1; agg_d += pool.damage[i]; agg_x += p.x; agg_y += p.y
						else:
							dropped_total += 1
					if agg_n > 0:
						var o := 5 * n
						ev[o] = 3; ev[o + 1] = 0; ev[o + 2] = agg_n; ev[o + 3] = agg_x / agg_n; ev[o + 4] = agg_y / agg_n
						n += 1
					var l0 := Time.get_ticks_usec()
					var r = on_events.invoke(ev, n, out)
					lua_us = Time.get_ticks_usec() - l0
					var oc: PackedFloat32Array = r[0]; var m: int = r[1]
					for k in m:
						mgr.defer_spawn(oc[4 * k], oc[4 * k + 1], oc[4 * k + 2], oc[4 * k + 3])
			var dt := Time.get_ticks_usec() - t0
			if f >= WARM:
				times.append(dt / 1000.0); lua_only.append(lua_us / 1000.0); defers.append(mgr.t_defer / 1000.0)
	return {"med": Stats.median(times), "p95": Stats.p95(times), "lua": Stats.median(lua_only), "defer": Stats.median(defers), "dropped": float(dropped_total) / (REPEATS * (WARM + FRAMES))}

# ---------------------------------------------------------------- fire()
func run_fire_config(variant: String, n: int) -> Dictionary:
	rng.seed = 5
	var w := make_world("C", n, 0)
	var api := FireAPI.new(); api.mgr = mgr
	var f_fields = L.get("fire_fields"); var f_polar = L.get("fire_polar"); var f_batch = L.get("fire_batch")
	var buf := PackedFloat32Array(); buf.resize(5 * n)
	var times := []
	var req := ShotRequest.new()
	for rep in 40:
		mgr.clear_bullets()
		var t0 := Time.get_ticks_usec()
		match variant:
			"gd_native_loop":
				for k in n:
					req.reset(); req.position = Vector2.ZERO; req.velocity = Vector2.from_angle(k * 0.3) * 300.0; req.lifetime = 3.0
					mgr.emitter.request_shot(req)
			"lua_fields": f_fields.invoke(req, mgr.emitter, n)
			"lua_polar": f_polar.invoke(api, n)
			"lua_batch": f_batch.invoke(api, buf, n)
		if rep >= 5: times.append((Time.get_ticks_usec() - t0) / 1000.0)
		assert(mgr.pool.count == n)
	return {"med": Stats.median(times), "p95": Stats.p95(times), "alive": mgr.pool.count}

func _ready() -> void:
	var sections := OS.get_cmdline_user_args().slice(1)
	if sections.is_empty(): sections = ["ticks", "events", "spam", "fire"]
	print("Godot ", Engine.get_version_info().string, " | Lua ", LuaState.get_lua_version_string(), " | PR #2 pool/manager copied from feat/core-scaffold")
	print("per config: ", REPEATS, " x ", FRAMES, " frames after ", WARM, " warmup; render off, 32 hurtboxes, steady-state respawn churn (as tests/benchmark)")
	print("\n### Tick hooks: hook-phase ms per tick (median / p95); `step` = whole BulletManager.step; copy/lua/apply = breakdown medians for option B")
	print("| N | scripted | option | hook med | hook p95 | step med | step p95 | copy in | Lua call | apply | hooked bullets |")
	print("|---|---|---|---|---|---|---|---|---|---|---|")
	var combos := [["C", 1, "C declarative (no hooks)"], ["A", 1, "A per-bullet every tick"], ["A", 4, "A throttled 1/4 ticks"], ["A", 8, "A throttled 1/8 ticks"],
		["B_gather", 1, "B batch, gathered inputs"], ["B_slice", 1, "B batch, bulk-slice inputs"], ["B_slice", 4, "B batch bulk-slice, 1/4 of bullets per tick"]]
	for n in ([1000, 4000, 5000, 10000] if "ticks" in sections else []):
		for pct in [100, 10]:
			for c in combos:
				var r := run_tick_config(c[0], n, pct, c[1])
				print("| %d | %d%% | %s | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f | %d |" % [n, pct, c[2], r.hook_med, r.hook_p95, r.step_med, r.step_p95, r.copy, r.lua, r.apply, r.hooked])
	if "events" in sections: _events()
	if "spam" in sections: _spam()
	if "fire" in sections: _fire()
	get_tree().quit()

func _events() -> void:
	print("\n### Events at 200/frame (N=4000): per-bullet Lua call vs drained batch (ms per frame incl. applying the deferred spawns it produced; Lua-only in brackets for batch)")
	print("| event | per-bullet dispatch med | p95 | batch dispatch med (fill+Lua+return) | p95 | batch Lua-call only | deferred-spawn apply next tick (per-bullet / batch) |")
	print("|---|---|---|---|---|---|---|")
	for kind in [[0, "on_spawn"], [1, "on_hit"], [2, "on_despawn"]]:
		var a := run_event_config(kind[0], 200, "per_bullet")
		var b := run_event_config(kind[0], 200, "batch")
		print("| %s | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f / %.3f |" % [kind[1], a.med, a.p95, b.med, b.p95, b.lua, a.defer, b.defer])

func _spam() -> void:
	print("\n### Hit spam (N=4000): ms per frame for the on_hit dispatch")
	print("| hits/frame | policy | dispatch median | p95 | Lua-call only | deferred-spawn apply | events dropped per frame |")
	print("|---|---|---|---|---|---|---|")
	for h in [200, 1000, 2000, 5000]:
		for pol in [["per_bullet", "per-bullet call, unlimited"], ["batch", "batch, unlimited"], ["batch_cap", "batch, cap 256/tick, drop rest"], ["batch_coalesce", "batch, cap 256 + coalesce rest into 1 summary"]]:
			var r := run_event_config(1, h, pol[0], 256)
			print("| %d | %s | %.3f | %.3f | %.3f | %.3f | %.0f |" % [h, pol[1], r.med, r.p95, r.lua, r.defer, r.dropped])

func _fire() -> void:
	print("\n### fire(): Lua spawning n bullets in one call (ms per fire call)")
	print("| n bullets | GDScript baseline | Lua: ShotRequest fields + request_shot | Lua: emitter:polar(floats) | Lua: packed batch |")
	print("|---|---|---|---|---|")
	for n in [10, 100, 1000]:
		var g := run_fire_config("gd_native_loop", n); var f := run_fire_config("lua_fields", n); var p := run_fire_config("lua_polar", n); var b := run_fire_config("lua_batch", n)
		print("| %d | %.3f | %.3f | %.3f | %.3f |" % [n, g.med, f.med, p.med, b.med])
