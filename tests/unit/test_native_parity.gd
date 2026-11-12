extends GutTest
## Seeded parity: the same scenario through the GDScript and the native backend
## must give the same bullets (positions, velocities, ages, lifetimes) tick by
## tick and the same hits. Plain bullets, and one on_batch script at a fixed
## seed and fixed 1/60 steps. Per-bullet hooks stay on GDScript in both backends.
##
## Short paths use the same endpoint test as the pool (impact at the end
## position). Swept hits are the contact point on both sides. Survivor positions
## must match tightly; the seeded scenario still allows one tick of travel on
## impact points so a float-drift contact does not fail the whole run.

const DT := 1.0 / 60.0
const TICKS := 150
const POS_EPS := 0.01

class HitRecord:
	extends RefCounted
	var tick := 0
	var target := 0
	var damage := 0.0
	var position := Vector2.ZERO
	var speed := 0.0


class RunResult:
	extends RefCounted
	## Per tick: lifetime (unique key) -> [pos, vel, age]
	var states: Array[Dictionary] = []
	var hits: Array[HitRecord] = []
	var backend := ""
	var max_pool := 0


func _run(preference: String, batch: bool = false, seed_value: int = 424242, ticks: int = TICKS) -> RunResult:
	var result := RunResult.new()
	var root := Node2D.new()
	add_child(root)
	var mgr := BulletManager.new()
	mgr.backend_preference = preference
	mgr.capacity = 2048
	mgr.world_bounds = Rect2(-640, -400, 1280, 800)
	mgr.render_enabled = false
	mgr.auto_step = false
	root.add_child(mgr)
	result.backend = mgr.backend

	var tick_ref: Array[int] = [0]
	var centres: Array[Vector2] = [Vector2(-300, -120), Vector2(260, 160), Vector2(0, 220), Vector2(-120, 140), Vector2(380, -150)]
	var radii: Array[float] = [24.0, 16.0, 40.0, 12.0, 30.0]
	for k in centres.size():
		var hb := Hurtbox.new()
		hb.radius = radii[k]
		hb.position = centres[k]
		root.add_child(hb)
		var idx := k
		hb.hit.connect(func(damage: float, hit_position: Vector2, vel: Vector2) -> void:
			var rec := HitRecord.new()
			rec.tick = tick_ref[0]
			rec.target = idx
			rec.damage = damage
			rec.position = hit_position
			rec.speed = vel.length()
			result.hits.append(rec))
	mgr.add_wall(Rect2(100, -250, 30, 220))
	mgr.add_wall(Rect2(-450, 20, 220, 24))

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var behavior_id := 0
	if batch:
		behavior_id = mgr.register_behavior(_BatchSteer.new())
	var serial := 0
	var max_pool := 0
	for tick in ticks:
		tick_ref[0] = tick
		if tick < 100:
			for _k in 6:
				var req := ShotRequest.new()
				req.position = Vector2(rng.randf_range(-560, 560), rng.randf_range(-330, 330))
				var speed := rng.randf_range(2000.0, 2600.0) if rng.randf() < 0.15 else rng.randf_range(80.0, 700.0)
				req.velocity = Vector2.from_angle(rng.randf() * TAU) * speed
				req.lifetime = 0.5 + float(serial) * 1e-4 + float(serial % 7) * 0.1
				req.radius = rng.randf_range(2.0, 5.0)
				req.damage = rng.randf_range(1.0, 3.0)
				req.hit_mask = Layers.ENEMY
				req.behavior_id = behavior_id
				req.collide_world = rng.randf() > 0.2
				if rng.randf() < 0.3:
					req.acceleration = rng.randf_range(-100.0, 200.0)
					req.turn_rate = rng.randf_range(-2.0, 2.0)
				if rng.randf() < 0.25:
					req.pierce = rng.randi_range(1, 2)
				serial += 1
				mgr.spawn(req)
		mgr.step(DT)
		max_pool = maxi(max_pool, mgr.pool.count)
		var snap := mgr.snapshot()
		var pos: PackedVector2Array = snap["pos"]
		var vel: PackedVector2Array = snap["vel"]
		var age: PackedFloat32Array = snap["age"]
		var life: PackedFloat32Array = snap["lifetime"]
		var radius: PackedFloat32Array = snap["radius"]
		var pierce: PackedInt32Array = snap["pierce"]
		var state := {}
		for i in pos.size():
			state[life[i]] = [pos[i], vel[i], age[i], radius[i], pierce[i], life[i]]
		result.states.append(state)
	result.max_pool = max_pool
	# Hurtboxes register in a static list: remove this run's before the next one.
	remove_child(root)
	root.free()
	return result


func test_native_matches_gdscript_tick_by_tick() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var gd := _run("gdscript")
	var nat := _run("native")
	_assert_same_run(gd, nat, 20)


## on_batch over the same seeded scene, fixed 1/60 steps. Positions, velocities,
## lifetimes and hits must match, and the native run keeps those bullets in the sim.
func test_batch_hook_matches_gdscript_for_a_fixed_seed() -> void:
	if not _available():
		return
	var gd := _run("gdscript", true, 340034, 90)
	var nat := _run("native", true, 340034, 90)
	assert_gt(gd.max_pool, 0, "the GDScript run keeps the batch bullets in the pool")
	assert_eq(nat.max_pool, 0, "the native run keeps the batch bullets in the sim")
	_assert_same_run(gd, nat, 1)


func _assert_same_run(gd: RunResult, nat: RunResult, min_hits: int) -> void:
	assert_eq(gd.backend, "gdscript")
	assert_eq(nat.backend, "native")
	var mismatched_ticks := 0
	var first_bad := ""
	for tick in gd.states.size():
		var a: Dictionary = gd.states[tick]
		var b: Dictionary = nat.states[tick]
		var ok := a.size() == b.size()
		var detail := "tick %d: %d vs %d alive%s" % [tick, a.size(), b.size(), _only_in_one(a, b, tick, gd, nat)]
		if ok:
			for key: float in a:
				if not b.has(key):
					ok = false
					detail = "tick %d: bullet with lifetime %f missing natively" % [tick, key]
					break
				var sa: Array = a[key]
				var sb: Array = b[key]
				var pa: Vector2 = sa[0]
				var pb: Vector2 = sb[0]
				var va: Vector2 = sa[1]
				var vb: Vector2 = sb[1]
				var age_a: float = sa[2]
				var age_b: float = sb[2]
				var life_a: float = sa[5]
				var life_b: float = sb[5]
				if pa.distance_to(pb) > POS_EPS or va.distance_to(vb) > 0.05 or absf(age_a - age_b) > 0.0001 or absf(life_a - life_b) > 0.0001:
					ok = false
					detail = "tick %d: lifetime %f vs %f pos %s vs %s vel %s vs %s age %f vs %f" % [tick, life_a, life_b, pa, pb, va, vb, age_a, age_b]
					break
		if not ok:
			mismatched_ticks += 1
			if first_bad == "":
				first_bad = detail
	assert_eq(mismatched_ticks, 0, "first mismatch: %s" % first_bad)

	assert_gt(gd.hits.size(), min_hits, "the scenario must produce hits")
	assert_eq(nat.hits.size(), gd.hits.size(), "same number of hits")
	var per_tick_gd := _hits_by_tick_and_target(gd.hits)
	var per_tick_nat := _hits_by_tick_and_target(nat.hits)
	assert_eq(per_tick_nat, per_tick_gd, "same hits on the same ticks")
	assert_eq(_hit_signatures(nat.hits), _hit_signatures(gd.hits), "same (tick, target, damage) triples")
	# Impact points: exact for swept hits; the GDScript short-path point test
	# reports the end position, so allow one tick of travel.
	var worst_gap := 0.0
	var by_sig := {}
	for rec in gd.hits:
		by_sig["%d:%d:%.4f" % [rec.tick, rec.target, rec.damage]] = rec
	for rec in nat.hits:
		var other: HitRecord = by_sig["%d:%d:%.4f" % [rec.tick, rec.target, rec.damage]]
		worst_gap = maxf(worst_gap, rec.position.distance_to(other.position) - rec.speed * DT)
	assert_lt(worst_gap, 0.1, "impact points within one tick of travel")


func _hit_signatures(hits: Array[HitRecord]) -> Array[String]:
	var out: Array[String] = []
	for rec in hits:
		out.append("%d:%d:%.4f" % [rec.tick, rec.target, rec.damage])
	out.sort()
	return out


func _hits_by_tick_and_target(hits: Array[HitRecord]) -> Dictionary:
	var out := {}
	for rec in hits:
		var key := "%d:%d" % [rec.tick, rec.target]
		var n: int = out.get(key, 0)
		out[key] = n + 1
	return out


## Describes the bullets that exist in one run's tick but not in the other's.
func _only_in_one(a: Dictionary, b: Dictionary, tick: int, gd: RunResult, nat: RunResult) -> String:
	var text := ""
	for key: float in a:
		if not b.has(key):
			var prev_state: Array = gd.states[tick - 1].get(key, []) if tick > 0 else []
			text += " [gdscript-only %f prev %s now %s]" % [key, prev_state, a[key]]
	for key: float in b:
		if not a.has(key):
			var prev_state: Array = nat.states[tick - 1].get(key, []) if tick > 0 else []
			text += " [native-only %f prev %s now %s]" % [key, prev_state, b[key]]
	return text


func test_kinematics_match_after_n_ticks() -> void:
	if not _available():
		return
	var gd := _kinematics("gdscript")
	var nat := _kinematics("native")
	assert_eq(nat.size(), gd.size())
	for i in gd.size():
		var a: Vector2 = gd[i]
		var b: Vector2 = nat[i]
		assert_lt(a.distance_to(b), POS_EPS, "bullet %d pos %s vs %s" % [i, a, b])


func test_slow_overlap_reports_the_end_position() -> void:
	if not _available():
		return
	var gd := _overlap_hit("gdscript")
	var nat := _overlap_hit("native")
	assert_eq(gd.size(), 1, "pool hit the overlapping target")
	assert_eq(nat.size(), 1, "native hit the overlapping target")
	assert_almost_eq(gd[0].x, 0.5, 0.001, "pool impact is the end of the short step")
	assert_almost_eq(nat[0].x, gd[0].x, 0.001)
	assert_almost_eq(nat[0].y, gd[0].y, 0.001)


func test_pierce_hit_memory_and_inactive_targets_match() -> void:
	if not _available():
		return
	var gd := _pierce_memory("gdscript")
	var nat := _pierce_memory("native")
	assert_eq(nat, gd)


func test_wall_hit_and_despawn_order_match() -> void:
	if not _available():
		return
	var gd := _despawn_script("gdscript")
	var nat := _despawn_script("native")
	assert_eq(nat, gd)


func test_camera_window_despawns_the_same_bullets() -> void:
	if not _available():
		return
	var gd := _window("gdscript")
	var nat := _window("native")
	assert_eq(nat, gd)


func test_saturation_counts_match() -> void:
	if not _available():
		return
	var gd := _saturation("gdscript")
	var nat := _saturation("native")
	assert_eq(nat, gd)


func test_damage_flags_match() -> void:
	if not _available():
		return
	var gd := _damage_flags("gdscript")
	var nat := _damage_flags("native")
	assert_eq(nat, gd)


func _available() -> bool:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return false
	return true


func _open(preference: String, cap: int = 64) -> BulletManager:
	var mgr := BulletManager.new()
	mgr.backend_preference = preference
	mgr.capacity = cap
	mgr.logical_cap = cap
	mgr.enemy_reserve = 0
	mgr.world_bounds = Rect2(-500, -500, 1000, 1000)
	mgr.render_enabled = false
	mgr.auto_step = false
	add_child(mgr)
	mgr.pool.log_despawns = true
	if mgr.native != null:
		mgr.native.set_record_events(true)
	return mgr


func _close(mgr: BulletManager) -> void:
	remove_child(mgr)
	mgr.free()


func _kinematics(preference: String) -> Array[Vector2]:
	var mgr := _open(preference)
	var positions: Array[Vector2] = [Vector2(-40, 10), Vector2.ZERO, Vector2(15, -20)]
	var velocities: Array[Vector2] = [Vector2(120, -30), Vector2(200, 0), Vector2(90, 40)]
	var accels: Array[float] = [0.0, 80.0, -40.0]
	var turns: Array[float] = [0.0, 0.6, -1.2]
	for i in positions.size():
		var req := ShotRequest.with_velocity(positions[i], velocities[i])
		req.acceleration = accels[i]
		req.turn_rate = turns[i]
		req.lifetime = 8.0
		req.hit_mask = 0
		req.collide_world = false
		mgr.spawn(req)
	for _tick in 90:
		mgr.step(DT)
	var pos: PackedVector2Array = mgr.snapshot()["pos"]
	var out: Array[Vector2] = []
	for p in pos:
		out.append(p)
	_close(mgr)
	return out


func _overlap_hit(preference: String) -> Array[Vector2]:
	var mgr := _open(preference)
	var hb := Hurtbox.new()
	hb.radius = 10.0
	hb.position = Vector2.ZERO
	mgr.add_child(hb)
	var hits: Array[Vector2] = []
	hb.hit.connect(func(_d: float, p: Vector2, _v: Vector2) -> void: hits.append(p))
	# 30 px/s is half a pixel per tick, already inside the hurtbox.
	var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(30, 0))
	req.radius = 4.0
	req.lifetime = 2.0
	req.hit_mask = Layers.ENEMY
	mgr.spawn(req)
	mgr.step(DT)
	_close(mgr)
	return hits


func _pierce_memory(preference: String) -> Array:
	var mgr := _open(preference)
	var boxes: Array[Hurtbox] = []
	var order: Array[int] = []
	for i in 9:
		var hb := Hurtbox.new()
		hb.radius = 6.0
		hb.position = Vector2.ZERO
		hb.active = i == 0
		mgr.add_child(hb)
		boxes.append(hb)
		var idx := i
		hb.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: order.append(idx))
	var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2.ZERO)
	req.radius = 2.0
	req.lifetime = 5.0
	req.pierce = 20
	req.hit_mask = Layers.ENEMY
	mgr.spawn(req)
	for i in 9:
		for b in boxes:
			b.active = false
		boxes[i].active = true
		mgr.step(DT)
	# The ring holds 8. The 9th hit (index 8) drops index 0, so it can land again.
	for b in boxes:
		b.active = false
	boxes[0].active = true
	mgr.step(DT)
	var alive := mgr.alive_count()
	var pierce: PackedInt32Array = mgr.snapshot()["pierce"]
	var left := int(pierce[0]) if pierce.size() == 1 else -1
	_close(mgr)
	return [order.duplicate(), alive, left]


func _despawn_script(preference: String) -> Array:
	var mgr := _open(preference)
	mgr.add_wall(Rect2(40, -10, 20, 20))
	var hb := Hurtbox.new()
	hb.radius = 6.0
	hb.position = Vector2(-40, 0)
	mgr.add_child(hb)
	# Unique lifetimes so the despawn log can be compared without ids.
	# One tick: lifetime, bounds, hurtbox, wall. Slots are spawn order.
	var positions: Array[Vector2] = [Vector2(0, 200), Vector2(490, -200), Vector2(20, 0), Vector2(-60, 0)]
	var velocities: Array[Vector2] = [Vector2.ZERO, Vector2(1200, 0), Vector2(2400, 0), Vector2(2400, 0)]
	var lives: Array[float] = [0.01, 4.0, 4.1, 4.2]
	var masks: Array[int] = [0, 0, 0, Layers.ENEMY]
	for i in positions.size():
		var req := ShotRequest.with_velocity(positions[i], velocities[i])
		req.lifetime = lives[i]
		req.radius = 2.0
		req.hit_mask = masks[i]
		mgr.spawn(req)
	mgr.step(DT)
	var reasons: Array[int] = []
	var logged_lives: Array[float] = []
	if preference == "native":
		var logged: Array = mgr.native.last_despawns()
		for i in logged.size():
			var row: Dictionary = logged[i]
			var reason: int = row["reason"]
			var life: float = row["lifetime"]
			reasons.append(reason)
			logged_lives.append(life)
	else:
		for i in mgr.pool.despawn_log_reason.size():
			reasons.append(mgr.pool.despawn_log_reason[i])
			logged_lives.append(mgr.pool.despawn_log_life[i])
	var alive := mgr.alive_count()
	var walls := mgr.last_wall_hit_count
	var hits := mgr.last_hit_count
	_close(mgr)
	return [reasons, logged_lives, alive, walls, hits]


func _window(preference: String) -> Array:
	var mgr := _open(preference)
	var hb := Hurtbox.new()
	hb.radius = 8.0
	hb.position = Vector2(5000, 5000)
	mgr.add_child(hb)
	var hits := 0
	hb.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits += 1)
	mgr.recenter_world_bounds(Vector2(5000, 5000))
	var survivor := ShotRequest.with_velocity(Vector2(5000, 4960), Vector2.ZERO)
	survivor.lifetime = 2.0
	survivor.radius = 3.0
	survivor.hit_mask = 0
	var outside := ShotRequest.with_velocity(Vector2.ZERO, Vector2.ZERO)
	outside.lifetime = 2.0
	outside.hit_mask = 0
	var hitter := ShotRequest.with_velocity(Vector2(5000, 5000), Vector2.ZERO)
	hitter.lifetime = 2.0
	hitter.radius = 3.0
	hitter.hit_mask = Layers.ENEMY
	mgr.spawn(survivor)
	mgr.spawn(outside)
	mgr.spawn(hitter)
	mgr.step(DT)
	var alive := mgr.alive_count()
	var centre := mgr.world_bounds.get_center()
	_close(mgr)
	return [alive, hits, centre.x, centre.y]


func _saturation(preference: String) -> Array:
	var mgr := _open(preference, 32)
	mgr.set_bullet_limits(10, 3)
	var dropped_player := 0
	for i in 8:
		var req := ShotRequest.with_velocity(Vector2(i * 3, 0), Vector2.ZERO)
		req.lifetime = 5.0
		req.hit_mask = 0
		if mgr.spawn(req) < 0:
			dropped_player += 1
	var dropped_enemy := 0
	for i in 4:
		var req := ShotRequest.with_velocity(Vector2(i * 3, 12), Vector2.ZERO)
		req.lifetime = 5.0
		req.owner_layer = Layers.ENEMY
		req.hit_mask = Layers.PLAYER
		if mgr.spawn(req) < 0:
			dropped_enemy += 1
	var unowned := ShotRequest.with_velocity(Vector2(0, 24), Vector2.ZERO)
	unowned.owner_layer = 0
	unowned.hit_mask = 0
	unowned.lifetime = 5.0
	var unowned_refused := mgr.spawn(unowned) < 0
	mgr.step(DT)
	var out := [
		mgr.alive_count(),
		mgr.emitter.get_owner_count(Layers.PLAYER),
		mgr.emitter.get_owner_count(Layers.ENEMY),
		mgr.emitter.get_owner_count(0),
		mgr.emitter.get_dropped_count(),
		dropped_player,
		dropped_enemy,
		unowned_refused,
		mgr.emitter.get_dropped_count_by_limit(BulletPool.DropLimit.LOGICAL_CAP),
		mgr.emitter.get_dropped_count_by_limit(BulletPool.DropLimit.ENEMY_RESERVE),
		mgr.emitter.get_dropped_count_by_owner(Layers.PLAYER),
		mgr.emitter.get_dropped_count_by_owner(Layers.ENEMY),
		mgr.emitter.is_saturated(Layers.PLAYER),
		mgr.emitter.is_saturated(Layers.ENEMY),
		mgr.emitter.get_headroom(Layers.PLAYER),
		mgr.emitter.get_headroom(Layers.ENEMY),
		mgr.saturation_warnings_emitted,
	]
	_close(mgr)
	return out


func _damage_flags(preference: String) -> Array:
	var mgr := _open(preference)
	var hb := Hurtbox.new()
	hb.radius = 8.0
	hb.position = Vector2(10, 0)
	mgr.add_child(hb)
	var seen: Array = []
	hb.hit.connect(func(damage: float, _p: Vector2, _v: Vector2) -> void:
		seen.append([damage, hb.last_hit_flags]))
	var req := ShotRequest.with_velocity(Vector2(10, 0), Vector2.ZERO)
	req.radius = 2.0
	req.damage = 4.5
	req.lifetime = 2.0
	req.hit_mask = Layers.ENEMY
	req.pierces_script_invuln = true
	mgr.spawn(req)
	mgr.step(DT)
	_close(mgr)
	return seen


## Batch steering used by the seeded parity run. Writes depend only on that
## bullet's age and the tick, so row order cannot change the result.
class _BatchSteer:
	extends BulletBehavior

	func _init() -> void:
		update_mode = UpdateMode.BATCH

	func on_update_batch(batch: BatchView) -> void:
		var vx := batch.vx
		var vy := batch.vy
		var age := batch.age
		var dt := batch.dt
		for i in batch.n:
			vx[i] = vx[i] + cos(age[i] * 6.0) * 40.0 * dt
			vy[i] = vy[i] + sin(age[i] * 3.0) * 20.0 * dt
