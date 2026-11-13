extends GutTest
## Hurtbox.Response.ABSORB (vertical slice row 3, first-playable L4): contacts
## inside the arc despawn the bullet as ABSORBED with no damage; contacts outside
## are normal hits. Runs on the GDScript pool, and on NativeBulletSim when the
## GDExtension is built (those cases pend without it).

const DT := 1.0 / 60.0
const SPEED := 1200.0
const CENTRE := Vector2(200, 0)
const R := 22.0
const SHOT_R := 4.0

var _managers: Array[BulletManager] = []


class Shot:
	var hits := 0
	var absorbs := 0
	var hp := 0.0
	var alive := 0
	var counts := PackedInt32Array()
	var point := Vector2.INF

	func same_as(o: Shot) -> bool:
		return hits == o.hits and absorbs == o.absorbs and hp == o.hp and alive == o.alive and counts == o.counts

	func _to_string() -> String:
		return "hits %d absorbs %d hp %s alive %d counts %s" % [hits, absorbs, hp, alive, counts]


class HitLog:
	extends BulletBehavior
	var hits := 0
	var reasons: Array[int] = []

	func on_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
		hits += 1

	func on_despawn(_pool: BulletPool, _index: int, reason: int) -> void:
		reasons.append(reason)


## Stand-in for a shootable body: a Hurtbox wired to a Health the way enemies are
## (hit -> Health.damage with the bullet's source flags), plus counters.
class Dummy:
	extends Node2D
	var hurtbox := Hurtbox.new()
	var health := Health.new()
	var hits := 0
	var absorbs := 0
	var absorb_points: Array[Vector2] = []
	var absorb_flags: Array[int] = []

	func _init(hp: float, r: float) -> void:
		health.max_hp = hp
		health.invulnerability_time = 0.0
		health.regen_enabled = false
		hurtbox.radius = r
		add_child(health)
		add_child(hurtbox)
		hurtbox.hit.connect(_on_hit)
		hurtbox.absorbed.connect(_on_absorbed)

	func _on_hit(damage: float, _p: Vector2, _v: Vector2) -> void:
		hits += 1
		health.damage(damage, hurtbox.last_hit_flags)

	func _on_absorbed(p: Vector2, _v: Vector2) -> void:
		absorbs += 1
		absorb_points.append(p)
		absorb_flags.append(hurtbox.last_hit_flags)


func after_each() -> void:
	_managers.clear()
	NativeBackend.force_unavailable = false


func _manager(backend: String, bounds: Rect2 = Rect2(-500, -500, 1000, 1000)) -> BulletManager:
	var m := BulletManager.new()
	m.backend_preference = backend
	m.capacity = 256
	m.world_bounds = bounds
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	_managers.append(m)
	return m


func _need_native() -> bool:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return false
	return true


## Both backends when the native one is available, else just the GD pool.
func _backends() -> PackedStringArray:
	return PackedStringArray(["gdscript", "native"]) if NativeBackend.is_available() else PackedStringArray(["gdscript"])


func _dummy(at: Vector2, facing: float, arc: float = 120.0, hp: float = 40.0, r: float = R) -> Dummy:
	var d := Dummy.new(hp, r)
	d.position = at
	d.hurtbox.response = Hurtbox.Response.ABSORB
	d.hurtbox.facing = facing
	d.hurtbox.arc_deg = arc
	add_child_autofree(d)
	return d


## A straight shot aimed at `target` from `dist` px away along world angle `from_angle`.
func _shot_from(target: Vector2, from_angle: float, dist: float = 300.0) -> ShotRequest:
	var origin := target + Vector2.from_angle(from_angle) * dist
	var req := ShotRequest.with_velocity(origin, (target - origin).normalized() * SPEED)
	req.radius = SHOT_R
	req.lifetime = 10.0
	req.hit_mask = Layers.ENEMY
	return req


func _run(m: BulletManager, ticks: int = 40) -> void:
	for i in ticks:
		m.step(DT)


func _counts(m: BulletManager) -> PackedInt32Array:
	var c := m.pool.despawn_counts.duplicate()
	if m.native != null:
		var n := m.native.despawn_counts()
		for k in mini(c.size(), n.size()):
			c[k] += n[k]
	return c


## Fires one straight shot at the dummy from `from_angle` and reports what happened.
func _fire(backend: String, facing: float, from_angle: float, arc: float = 120.0) -> Shot:
	var m := _manager(backend)
	var d := _dummy(CENTRE, facing, arc)
	m.spawn(_shot_from(CENTRE, from_angle))
	_run(m)
	var out := Shot.new()
	out.hits = d.hits
	out.absorbs = d.absorbs
	out.hp = d.health.hp
	out.alive = m.alive_count()
	out.counts = _counts(m)
	if d.absorb_points.size() > 0:
		out.point = d.absorb_points[0]
	m.queue_free()
	d.queue_free()
	return out


# --- Hurtbox API ---------------------------------------------------------------

func test_defaults_are_normal_and_cost_free() -> void:
	var hb := Hurtbox.new()
	autofree(hb)
	assert_eq(hb.response, Hurtbox.Response.NORMAL)
	assert_false(hb.absorbs(Vector2(10, 0)), "a NORMAL hurtbox never absorbs")
	hb.response = Hurtbox.Response.REFLECT
	assert_false(hb.absorbs(Vector2(10, 0)), "REFLECT is reserved; not shipped, behaves like NORMAL")
	assert_eq(BulletPool.DespawnReason.ABSORBED, 7, "appended after INVALID")
	assert_eq(BulletPool.DespawnReason.INVALID, 6, "existing values stay put")


func test_arc_edges_are_inside_and_just_past_them_is_outside() -> void:
	var hb := Hurtbox.new()
	add_child_autofree(hb)
	hb.response = Hurtbox.Response.ABSORB
	hb.facing = PI
	hb.arc_deg = 120.0
	var west := Vector2.LEFT * 20.0
	assert_true(hb.absorbs(west), "dead centre of the arc")
	for edge: float in [60.0, -60.0]:
		assert_true(hb.absorbs(west.rotated(deg_to_rad(edge))), "edge %s is inside" % edge)
		assert_true(hb.absorbs(west.rotated(deg_to_rad(edge * 0.99))), "just inside %s" % edge)
		assert_false(hb.absorbs(west.rotated(deg_to_rad(edge * 1.01))), "just past %s" % edge)
	assert_false(hb.absorbs(Vector2.UP * 20.0), "side")
	assert_false(hb.absorbs(Vector2.RIGHT * 20.0), "back")
	assert_false(hb.absorbs(Vector2.ZERO), "the centre has no direction")
	hb.arc_deg = 360.0
	assert_true(hb.absorbs(Vector2.RIGHT * 20.0), "a full arc absorbs the back too")
	hb.arc_deg = 0.0
	assert_false(hb.absorbs(west), "a closed arc absorbs nothing")
	hb.arc_deg = 270.0
	assert_true(hb.absorbs(Vector2.UP * 20.0), "arcs over 180 degrees reach the sides")
	assert_false(hb.absorbs(Vector2.RIGHT * 20.0))


func test_arc_follows_the_hurtbox_position() -> void:
	var hb := Hurtbox.new()
	add_child_autofree(hb)
	hb.position = Vector2(1000, 500)
	hb.response = Hurtbox.Response.ABSORB
	hb.facing = 0.0
	assert_true(hb.absorbs(Vector2(1020, 500)))
	assert_false(hb.absorbs(Vector2(980, 500)))


func test_turn_helper_caps_the_rate_and_takes_the_short_way() -> void:
	assert_almost_eq(Hurtbox.turned(0.0, PI / 2.0, 45.0, 1.0), PI / 4.0, 1e-5, "45 deg/s for 1 s")
	assert_almost_eq(Hurtbox.turned(0.0, PI / 2.0, 45.0, 0.5), PI / 8.0, 1e-5)
	assert_almost_eq(Hurtbox.turned(0.0, PI / 2.0, 0.0, 0.016), PI / 2.0, 1e-5, "0 = no cap, snaps")
	assert_almost_eq(Hurtbox.turned(0.0, 0.1, 45.0, 1.0), 0.1, 1e-5, "does not overshoot")
	# 170 deg -> -170 deg is 20 degrees through 180, not 340 back through 0.
	var a := Hurtbox.turned(deg_to_rad(170.0), deg_to_rad(-170.0), 45.0, 1.0 / 9.0)
	assert_almost_eq(absf(rad_to_deg(a)), 175.0, 1e-3, "turned the short way")
	var hb := Hurtbox.new()
	add_child_autofree(hb)
	hb.response = Hurtbox.Response.ABSORB
	hb.face(Vector2(0, 100))
	assert_almost_eq(hb.facing, PI / 2.0, 1e-5, "face() with no cap points at the target")
	assert_true(hb.absorbs(Vector2(0, 20)), "and the arc moved with it")
	hb.face(Vector2(100, 0), 45.0, 1.0)
	assert_almost_eq(hb.facing, PI / 4.0, 1e-5, "capped turn via face()")
	# Bulwark rare: 150 degrees at 45 deg/s. A 90 degree swing takes 2 s.
	hb.arc_deg = 150.0
	hb.facing = 0.0
	for i in 60:
		hb.face(Vector2(0, 100), 45.0, DT)
	assert_almost_eq(rad_to_deg(hb.facing), 45.0, 0.01, "one second at 45 deg/s")


# --- Bullets, both backends ------------------------------------------------------

func test_front_shot_is_absorbed_with_no_damage() -> void:
	for backend in _backends():
		var r := _fire(backend, PI, PI)
		assert_eq(r.absorbs, 1, backend)
		assert_eq(r.hits, 0, backend)
		assert_eq(r.hp, 40.0, "%s: no damage" % backend)
		assert_eq(r.alive, 0, "%s: the bullet is gone" % backend)
		var counts := r.counts
		assert_eq(counts[BulletPool.DespawnReason.ABSORBED], 1, backend)
		assert_eq(counts[BulletPool.DespawnReason.HIT], 0, backend)
		var p := r.point
		# Where the hit sweep places the contact (its hit t), on the arc side.
		assert_lte(p.distance_to(CENTRE), R + SHOT_R + 0.05, "%s: stopped at the contact" % backend)
		assert_lt(p.x, CENTRE.x, "%s: on the west face" % backend)


func test_side_and_back_shots_damage() -> void:
	for backend in _backends():
		for from_deg: float in [90.0, -90.0, 0.0, 45.0, -45.0]:
			# Facing west (180): 90/-90 are the sides, 0 is the back.
			var r := _fire(backend, PI, deg_to_rad(from_deg))
			var label := "%s from %s deg" % [backend, from_deg]
			assert_eq(r.hits, 1, label)
			assert_eq(r.absorbs, 0, label)
			assert_eq(r.hp, 39.0, label)
			var counts := r.counts
			assert_eq(counts[BulletPool.DespawnReason.HIT], 1, label)
			assert_eq(counts[BulletPool.DespawnReason.ABSORBED], 0, label)


func test_arc_edge_angles_with_bullets() -> void:
	for backend in _backends():
		for off: float in [0.0, 30.0, -30.0, 59.0, -59.0]:
			var r := _fire(backend, PI, PI + deg_to_rad(off))
			assert_eq(r.absorbs, 1, "%s %s deg off centre is inside" % [backend, off])
		for off: float in [61.0, -61.0, 75.0, 120.0]:
			var r := _fire(backend, PI, PI + deg_to_rad(off))
			assert_eq(r.hits, 1, "%s %s deg off centre is outside" % [backend, off])
			assert_eq(r.absorbs, 0, "%s %s deg" % [backend, off])


func test_piercing_shot_is_absorbed_and_stops() -> void:
	for backend in _backends():
		var m := _manager(backend)
		var shield := _dummy(CENTRE, PI)
		var behind := Dummy.new(40.0, R)
		behind.position = CENTRE + Vector2(80, 0)
		add_child_autofree(behind)
		var req := _shot_from(CENTRE, PI)
		req.pierce = 3
		m.spawn(req)
		_run(m)
		assert_eq(shield.absorbs, 1, backend)
		assert_eq(shield.hits, 0, backend)
		assert_eq(behind.hits, 0, "%s: the absorbed shot does not pierce on" % backend)
		assert_eq(m.alive_count(), 0, backend)
		assert_eq(_counts(m)[BulletPool.DespawnReason.ABSORBED], 1, backend)
		# From the side the same piercing shot hits and flies on, as before.
		var side := _shot_from(CENTRE, PI / 2.0)
		side.pierce = 3
		m.spawn(side)
		_run(m, 16)
		assert_eq(shield.hits, 1, "%s: side pierce hits" % backend)
		assert_eq(m.alive_count(), 1, "%s: and keeps going" % backend)


func test_pierce_through_a_normal_target_into_the_arc() -> void:
	for backend in _backends():
		var m := _manager(backend)
		var shield := _dummy(CENTRE, PI)
		var front := Dummy.new(40.0, 10.0)
		front.position = CENTRE + Vector2(-80, 0)
		add_child_autofree(front)
		var req := _shot_from(CENTRE, PI)
		req.pierce = 3
		m.spawn(req)
		_run(m)
		assert_eq(front.hits, 1, "%s: pierced the plain target" % backend)
		assert_eq(shield.absorbs, 1, "%s: then the arc took it" % backend)
		assert_eq(shield.hits, 0, backend)
		assert_eq(m.alive_count(), 0, backend)


func test_script_invuln_semantics_hold() -> void:
	for backend in _backends():
		var m := _manager(backend)
		var d := _dummy(CENTRE, PI)
		d.health.set_invulnerable(true)
		# Side, flagged: goes through the script layer, as before.
		var flagged := _shot_from(CENTRE, PI / 2.0)
		flagged.pierces_script_invuln = true
		m.spawn(flagged)
		_run(m)
		assert_eq(d.health.hp, 39.0, "%s: flagged side shot pierces script invuln" % backend)
		# Side, unflagged: blocked by the script layer.
		m.spawn(_shot_from(CENTRE, -PI / 2.0))
		_run(m)
		assert_eq(d.health.hp, 39.0, "%s: unflagged side shot is blocked" % backend)
		assert_eq(d.hits, 2, backend)
		# Front, flagged: the arc still absorbs it (the flag is not an absorb bypass),
		# and the flag is reported with the absorb.
		var front := _shot_from(CENTRE, PI)
		front.pierces_script_invuln = true
		m.spawn(front)
		_run(m)
		assert_eq(d.absorbs, 1, backend)
		assert_eq(d.health.hp, 39.0, "%s: absorbed, 0 damage" % backend)
		assert_eq(d.absorb_flags, [Health.SOURCE_PIERCES_SCRIPT_INVULN] as Array[int], backend)
		# With the arc off the same flagged front shot damages through script invuln.
		d.hurtbox.response = Hurtbox.Response.NORMAL
		var again := _shot_from(CENTRE, PI)
		again.pierces_script_invuln = true
		m.spawn(again)
		_run(m)
		assert_eq(d.health.hp, 38.0, "%s: NORMAL again" % backend)


func test_absorbed_hooked_bullet_runs_no_on_hit_and_despawns_absorbed() -> void:
	for backend in _backends():
		var m := _manager(backend)
		var d := _dummy(CENTRE, PI)
		var log := HitLog.new()
		var req := _shot_from(CENTRE, PI)
		req.behavior_id = m.register_behavior(log)
		m.spawn(req)
		_run(m)
		assert_eq(d.absorbs, 1, backend)
		assert_eq(log.hits, 0, "%s: no on_hit for an absorbed bullet" % backend)
		assert_eq(log.reasons, [BulletPool.DespawnReason.ABSORBED] as Array[int], backend)
		var side := _shot_from(CENTRE, PI / 2.0)
		side.behavior_id = req.behavior_id
		m.spawn(side)
		_run(m)
		assert_eq(log.hits, 1, "%s: a side hit still runs on_hit" % backend)


func test_inactive_absorber_lets_shots_pass() -> void:
	for backend in _backends():
		var m := _manager(backend)
		var d := _dummy(CENTRE, PI)
		d.hurtbox.active = false
		m.spawn(_shot_from(CENTRE, PI))
		_run(m, 10)
		assert_eq(d.absorbs, 0, backend)
		assert_eq(d.hits, 0, backend)
		assert_eq(m.alive_count(), 1, "%s: i-frames still mean untouched" % backend)


# --- Acceptance ------------------------------------------------------------------

## first-playable-elites.md L4: "Forced Bulwark Drifter: the 120 degree arc
## absorbs; the open side does not." Bulwark common: 120 degrees, ABSORB, facing
## the player each frame with no turn cap. Stand-in body (Bulwark itself is row 7).
func test_l4_bulwark_arc_absorbs_and_the_open_side_does_not() -> void:
	for backend in _backends():
		var m := _manager(backend)
		var bulwark := _dummy(CENTRE, 0.0, 120.0, 75.0, 18.0)
		var player := CENTRE + Vector2(-250, 120)
		# Facing toward the player each frame, no cap (turn_deg_per_s = 0).
		bulwark.hurtbox.face(player, 0.0, DT)
		# A straight shot from the player despawns and deals 0.
		for i in 5:
			var req := ShotRequest.with_velocity(player, (CENTRE - player).normalized() * SPEED)
			req.radius = SHOT_R
			req.hit_mask = Layers.ENEMY
			m.spawn(req)
			_run(m, 30)
		assert_eq(bulwark.absorbs, 5, backend)
		assert_eq(bulwark.health.hp, 75.0, "%s: straight shots deal 0" % backend)
		assert_eq(_counts(m)[BulletPool.DespawnReason.ABSORBED], 5, backend)
		# The player moves around it; the arc follows (no cap), still 0.
		player = CENTRE + Vector2(0, -260)
		bulwark.hurtbox.face(player, 0.0, DT)
		var top := ShotRequest.with_velocity(player, Vector2(0, SPEED))
		top.radius = SHOT_R
		top.hit_mask = Layers.ENEMY
		m.spawn(top)
		_run(m, 30)
		assert_eq(bulwark.absorbs, 6, "%s: arc tracked the player" % backend)
		# A shot that reaches the open side (spawned off to the side) deals damage.
		m.spawn(_shot_from(CENTRE, PI / 2.0 + 0.6))
		m.spawn(_shot_from(CENTRE, 0.0))
		_run(m)
		assert_eq(bulwark.hits, 2, backend)
		assert_eq(bulwark.health.hp, 73.0, "%s: the open side takes damage" % backend)


## vertical-slice.md §7 / row 4 room-A shielded dummy: (1800, 0), 40 HP, radius 22,
## 120 degree absorb arc facing west (toward the door), static. Straight shots deal
## 0; side hits damage. Test-scene dummy only, room A is not built here.
func test_room_a_shielded_dummy_straight_shots_deal_zero_side_hits_damage() -> void:
	for backend in _backends():
		var m := _manager(backend, Rect2(0, -1000, 3000, 2000))
		var at := Vector2(1800, 0)
		var d := _dummy(at, PI, 120.0, 40.0, 22.0)
		# Straight shots from the door side: anywhere west of the dummy, aimed at it.
		for y: float in [0.0, 40.0, -40.0, 120.0]:
			var from := Vector2(1450, y)
			var req := ShotRequest.with_velocity(from, (at - from).normalized() * SPEED)
			req.radius = SHOT_R
			req.hit_mask = Layers.ENEMY
			m.spawn(req)
		_run(m, 40)
		assert_eq(d.absorbs, 4, backend)
		assert_eq(d.health.hp, 40.0, "%s: straight shots deal 0" % backend)
		# Shots from the north and south sides.
		m.spawn(_shot_from(at, -PI / 2.0))
		m.spawn(_shot_from(at, PI / 2.0))
		_run(m, 40)
		assert_eq(d.hits, 2, backend)
		assert_eq(d.health.hp, 38.0, "%s: side hits damage" % backend)
		# 38 more side hits kill it.
		for i in 38:
			m.spawn(_shot_from(at, PI / 2.0 if i % 2 == 0 else -PI / 2.0))
			_run(m, 20)
		assert_true(d.health.is_dead(), backend)


# --- Native parity ---------------------------------------------------------------

func test_native_parity_over_a_sweep_of_angles() -> void:
	if not _need_native():
		return
	var mismatches := 0
	var deg := -180.0
	while deg < 180.0:
		var from_angle := PI + deg_to_rad(deg)
		var gd := _fire("gdscript", PI, from_angle)
		var nat := _fire("native", PI, from_angle)
		if not gd.same_as(nat):
			mismatches += 1
			gut.p("parity at %s deg: gd %s / native %s" % [deg, gd, nat])
		var gp := gd.point
		var np := nat.point
		if gp != Vector2.INF or np != Vector2.INF:
			assert_almost_eq(gp.distance_to(np), 0.0, 0.01, "absorb point at %s deg" % deg)
		deg += 7.5
	assert_eq(mismatches, 0, "GD pool and NativeBulletSim agree on every angle")


func test_native_reports_absorbed_in_its_own_counts() -> void:
	if not _need_native():
		return
	var m := _manager("native")
	_dummy(CENTRE, PI)
	m.spawn(_shot_from(CENTRE, PI))
	_run(m)
	assert_eq(m.backend, "native")
	assert_eq(m.pool.count, 0, "plain shot lived in the native sim")
	var n := m.native.despawn_counts()
	assert_eq(n.size(), 8, "the native count array covers ABSORBED")
	# Through ClassDB so this file still parses without the extension.
	assert_eq(ClassDB.class_get_integer_constant(&"NativeBulletSim", &"REASON_ABSORBED"), BulletPool.DespawnReason.ABSORBED, "same numbering")
	assert_eq(n[BulletPool.DespawnReason.ABSORBED], 1)
	assert_eq(n[BulletPool.DespawnReason.HIT], 0)
