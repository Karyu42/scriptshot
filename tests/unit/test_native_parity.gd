extends GutTest
## Seeded parity: the same scenario through the GDScript and the native backend
## must give the same bullets (positions, velocities, ages) tick by tick and the
## same hits. Plain bullets only (hooked bullets are GDScript in both backends).
##
## Known, documented difference: a bullet that is already overlapping a target at
## the end of a short path is hit at its end position by the GDScript point test
## but at the exact contact point by the native sweep, so impact positions are
## compared within one tick of travel; survivors must match tightly.

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


func _run(preference: String) -> RunResult:
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
	rng.seed = 424242
	var serial := 0
	for tick in TICKS:
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
				req.collide_world = rng.randf() > 0.2
				if rng.randf() < 0.3:
					req.acceleration = rng.randf_range(-100.0, 200.0)
					req.turn_rate = rng.randf_range(-2.0, 2.0)
				if rng.randf() < 0.25:
					req.pierce = rng.randi_range(1, 2)
				serial += 1
				mgr.spawn(req)
		mgr.step(DT)
		var snap := mgr.snapshot()
		var pos: PackedVector2Array = snap["pos"]
		var vel: PackedVector2Array = snap["vel"]
		var age: PackedFloat32Array = snap["age"]
		var life: PackedFloat32Array = snap["lifetime"]
		var radius: PackedFloat32Array = snap["radius"]
		var pierce: PackedInt32Array = snap["pierce"]
		var state := {}
		for i in pos.size():
			state[life[i]] = [pos[i], vel[i], age[i], radius[i], pierce[i]]
		result.states.append(state)
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
	assert_eq(gd.backend, "gdscript")
	assert_eq(nat.backend, "native")
	var mismatched_ticks := 0
	var first_bad := ""
	for tick in TICKS:
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
				if pa.distance_to(pb) > POS_EPS or va.distance_to(vb) > 0.05:
					ok = false
					detail = "tick %d: lifetime %f pos %s vs %s vel %s vs %s" % [tick, key, pa, pb, va, vb]
					break
		if not ok:
			mismatched_ticks += 1
			if first_bad == "":
				first_bad = detail
	assert_eq(mismatched_ticks, 0, "first mismatch: %s" % first_bad)

	assert_gt(gd.hits.size(), 20, "the scenario must produce hits")
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
