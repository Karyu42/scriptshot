extends GutTest
## Spawn records and hook writes: a NaN or inf in any numeric field is invalid (the
## shot is rejected / the bullet is killed as INVALID, counted in invalid_total, one
## capped warning); a finite value outside the BulletLimits range is clamped.
## QA's S1: INF radius blinded every hurtbox, NaN acceleration / turn rate made
## pos and vel NaN, NaN lifetime made an immortal bullet.

const DT := 1.0 / 60.0

var pool: BulletPool
var manager: BulletManager


## Writes `value` into one numeric field of the bullet whose hook runs.
class Writer:
	extends BulletBehavior
	var hook := "update"  # "spawn", "update", "hit" or "can_hit"
	var field := ""
	var value := 0.0
	var reasons: Array[int] = []

	func on_spawn(pool: BulletPool, index: int) -> void:
		if hook == "spawn":
			_write(pool, index)

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		if hook == "update":
			_write(pool, index)

	func can_hit(pool: BulletPool, index: int, _hurtbox: Hurtbox) -> bool:
		if hook == "can_hit":
			_write(pool, index)
		return true

	func on_hit(pool: BulletPool, index: int, _hurtbox: Hurtbox) -> void:
		if hook == "hit":
			_write(pool, index)

	func on_despawn(_pool: BulletPool, _index: int, reason: int) -> void:
		reasons.append(reason)

	func _write(pool: BulletPool, i: int) -> void:
		match field:
			"radius":
				pool.radius[i] = value
			"accel":
				pool.accel[i] = value
			"turn_rate":
				pool.turn_rate[i] = value
			"lifetime":
				pool.lifetime[i] = value
			"damage":
				pool.damage[i] = value
			"age":
				pool.age[i] = value
			"param_a":
				pool.param_a[i] = value
			"param_b":
				pool.param_b[i] = value
			"pos":
				pool.pos[i] = Vector2(value, 0)
			"rot":
				pool.rot[i] = Vector2(value, 0)


func before_each() -> void:
	ScriptWarnings.reset()
	_target_hits = 0
	pool = BulletPool.new(64)
	manager = BulletManager.new()
	manager.capacity = 64
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _req() -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2(10, 10), Vector2(60, 0))
	r.lifetime = 5.0
	return r


## Spawning `r` must be refused and counted, and leave nothing behind.
func _assert_rejected(r: ShotRequest, what: String) -> void:
	var before := pool.invalid_total
	assert_eq(pool.spawn(r), -1, "%s is rejected" % what)
	assert_eq(pool.invalid_total, before + 1, "%s is counted in invalid_total" % what)
	assert_eq(pool.count, 0, "%s leaves no bullet" % what)
	assert_eq(pool.dropped_total, 0, "%s is not a capacity drop" % what)
	assert_true(pool.counters_consistent(), "%s leaves the counters alone" % what)


# --- rejected at spawn: one test per field -----------------------------------------

func test_spawn_rejects_nan_radius() -> void:
	var r := _req()
	r.radius = NAN
	_assert_rejected(r, "NaN radius")


func test_spawn_rejects_inf_radius_and_it_cannot_blind_the_hurtboxes() -> void:
	var r := _req()
	r.radius = INF
	_assert_rejected(r, "INF radius")
	assert_eq(pool.max_radius, 0.0, "max_radius, which sizes the hurtbox grid margin, stays finite")


func test_spawn_rejects_nan_acceleration() -> void:
	var r := _req()
	r.acceleration = NAN
	_assert_rejected(r, "NaN acceleration")


func test_spawn_rejects_inf_acceleration() -> void:
	var r := _req()
	r.acceleration = -INF
	_assert_rejected(r, "-INF acceleration")


func test_spawn_rejects_nan_turn_rate() -> void:
	var r := _req()
	r.turn_rate = NAN
	_assert_rejected(r, "NaN turn_rate")


func test_spawn_rejects_inf_turn_rate() -> void:
	var r := _req()
	r.turn_rate = INF
	_assert_rejected(r, "INF turn_rate")


func test_spawn_rejects_nan_lifetime() -> void:
	var r := _req()
	r.lifetime = NAN
	_assert_rejected(r, "NaN lifetime")


func test_spawn_rejects_inf_lifetime() -> void:
	var r := _req()
	r.lifetime = INF
	_assert_rejected(r, "INF lifetime (an immortal bullet)")


func test_spawn_rejects_nan_damage() -> void:
	var r := _req()
	r.damage = NAN
	_assert_rejected(r, "NaN damage")


func test_spawn_rejects_inf_damage() -> void:
	var r := _req()
	r.damage = INF
	_assert_rejected(r, "INF damage")


func test_spawn_rejects_nan_param_a() -> void:
	var r := _req()
	r.param_a = NAN
	_assert_rejected(r, "NaN param_a")


func test_spawn_rejects_inf_param_b() -> void:
	var r := _req()
	r.param_b = INF
	_assert_rejected(r, "INF param_b")


func test_spawn_rejects_an_infinite_angle_but_nan_still_means_unset() -> void:
	var r := _req()
	r.angle = INF
	_assert_rejected(r, "INF angle")
	var ok := _req()
	assert_true(is_nan(ok.angle), "the default")
	var slot := pool.spawn(ok)
	assert_true(slot >= 0, "NaN angle = face along velocity")
	assert_eq(pool.rot[slot], Vector2.RIGHT)


func test_spawn_still_rejects_a_non_finite_position_or_velocity() -> void:
	var r := _req()
	r.position = Vector2(NAN, 0)
	_assert_rejected(r, "NaN position")
	var r2 := _req()
	r2.velocity = Vector2(0, INF)
	_assert_rejected(r2, "INF velocity")


func test_the_warning_names_the_field_and_is_capped() -> void:
	for i in 20:
		var r := _req()
		r.radius = INF
		pool.spawn(r)
	assert_eq(pool.invalid_total, 20)
	assert_eq(ScriptWarnings.count("BulletPool.spawn"), 20)
	assert_eq(ScriptWarnings.printed_count("BulletPool.spawn"), ScriptWarnings.LIMIT)
	assert_eq(pool._bad_request_field(_req()), "")
	var bad := _req()
	bad.turn_rate = NAN
	assert_eq(pool._bad_request_field(bad), "turn_rate")


func test_a_rejected_shot_through_the_manager_spawns_nothing_and_no_on_spawn_runs() -> void:
	var w := Writer.new()
	var r := _req()
	r.behavior_id = manager.register_behavior(w)
	r.radius = NAN
	assert_eq(manager.spawn(r), -1)
	assert_eq(manager.pool.invalid_total, 1)
	assert_eq(manager.pool.count, 0)
	assert_eq(w.reasons.size(), 0)


# --- finite but out of range: clamped ------------------------------------------------

func test_spawn_clamps_a_huge_radius_and_keeps_max_radius_bounded() -> void:
	var r := _req()
	r.radius = 1e9
	var slot := pool.spawn(r)
	assert_eq(pool.radius[slot], BulletLimits.MAX_RADIUS)
	assert_eq(pool.max_radius, BulletLimits.MAX_RADIUS)
	assert_eq(pool.invalid_total, 0, "clamped, not invalid")


func test_spawn_clamps_a_negative_radius_to_zero() -> void:
	var r := _req()
	r.radius = -5.0
	assert_eq(pool.radius[pool.spawn(r)], 0.0)


func test_spawn_clamps_lifetime_into_range() -> void:
	var r := _req()
	r.lifetime = 1e9
	assert_eq(pool.lifetime[pool.spawn(r)], BulletLimits.MAX_LIFETIME, "no bullet lives forever")
	var neg := _req()
	neg.lifetime = -3.0
	assert_eq(pool.lifetime[pool.spawn(neg)], 0.0)


func test_spawn_clamps_acceleration_and_turn_rate() -> void:
	var r := _req()
	r.acceleration = 1e30
	r.turn_rate = -1e30
	var slot := pool.spawn(r)
	assert_eq(pool.accel[slot], BulletLimits.MAX_ACCELERATION)
	assert_eq(pool.turn_rate[slot], -BulletLimits.MAX_TURN_RATE)


func test_spawn_clamps_damage_into_range() -> void:
	var r := _req()
	r.damage = 1e12
	assert_eq(pool.damage[pool.spawn(r)], BulletLimits.MAX_DAMAGE)
	var neg := _req()
	neg.damage = -4.0
	assert_eq(pool.damage[pool.spawn(neg)], 0.0, "a bullet cannot heal through a negative damage")


func test_spawn_keeps_params_finite_even_beyond_float32() -> void:
	var r := _req()
	r.param_a = 1e39
	r.param_b = -1e300
	var slot := pool.spawn(r)
	assert_true(is_finite(pool.param_a[slot]) and is_finite(pool.param_b[slot]), "no inf from the float32 conversion")
	# (float32 storage: the bound is only exact to ~7 digits)
	assert_almost_eq(pool.param_a[slot], BulletLimits.MAX_PARAM, BulletLimits.MAX_PARAM * 1e-6)
	assert_almost_eq(pool.param_b[slot], -BulletLimits.MAX_PARAM, BulletLimits.MAX_PARAM * 1e-6)


func test_values_inside_the_ranges_are_stored_untouched() -> void:
	var r := _req()
	r.radius = 120.0
	r.lifetime = 90.0
	r.acceleration = -300.0
	r.turn_rate = 6.0
	r.damage = 3.0
	r.param_a = 12345.5
	var slot := pool.spawn(r)
	assert_eq(pool.radius[slot], 120.0)
	assert_eq(pool.lifetime[slot], 90.0)
	assert_eq(pool.accel[slot], -300.0)
	assert_eq(pool.turn_rate[slot], 6.0)
	assert_eq(pool.damage[slot], 3.0)
	assert_eq(pool.param_a[slot], 12345.5)


# --- the failure modes QA found, end to end ------------------------------------------

func test_an_inf_radius_shot_no_longer_stops_every_other_bullet_from_hitting() -> void:
	var hb := Hurtbox.new()
	hb.radius = 20.0
	hb.position = Vector2(100, 0)
	add_child_autofree(hb)
	watch_signals(hb)
	var bad := _req()
	bad.position = Vector2(0, 400)
	bad.radius = INF
	assert_eq(manager.spawn(bad), -1)
	var ok := ShotRequest.with_velocity(Vector2.ZERO, Vector2(6000, 0))
	ok.lifetime = 5.0
	ok.velocity = Vector2(3000, 0)
	manager.spawn(ok)
	manager.step(DT * 2.0)
	assert_signal_emit_count(hb, "hit", 1)


func test_nan_acceleration_cannot_turn_a_bullet_into_nan() -> void:
	var r := _req()
	r.acceleration = NAN
	assert_eq(manager.spawn(r), -1)
	manager.step(DT)
	assert_eq(manager.pool.count, 0)


func test_a_nan_lifetime_no_longer_makes_an_immortal_bullet() -> void:
	var r := _req()
	r.velocity = Vector2.ZERO
	r.lifetime = NAN
	assert_eq(manager.spawn(r), -1)
	for i in 5:
		manager.step(DT)
	assert_eq(manager.pool.count, 0)


# --- spawn_simple -------------------------------------------------------------------

func test_spawn_simple_rejects_a_non_finite_life_or_radius() -> void:
	assert_eq(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), NAN), -1)
	assert_eq(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), 1.0, INF), -1)
	assert_eq(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), INF), -1)
	assert_eq(pool.invalid_total, 3)
	assert_eq(pool.count, 0)
	assert_true(pool.counters_consistent())


func test_spawn_simple_clamps_life_and_radius() -> void:
	var slot := pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), 1e9, 1e9)
	assert_eq(pool.lifetime[slot], BulletLimits.MAX_LIFETIME)
	assert_eq(pool.radius[slot], BulletLimits.MAX_RADIUS)
	assert_eq(pool.max_radius, BulletLimits.MAX_RADIUS)


# --- hooks that change the fields after the spawn -----------------------------------

func _hooked(hook: String, field: String, value: float) -> Writer:
	var w := Writer.new()
	w.hook = hook
	w.field = field
	w.value = value
	return w


func _spawn_hooked(w: Writer) -> int:
	var r := _req()
	r.behavior_id = manager.register_behavior(w)
	r.hit_mask = Layers.ENEMY
	return manager.spawn(r)


var _target: Hurtbox
var _target_hits := 0


func _on_target_hit(_damage: float, _position: Vector2, _velocity: Vector2) -> void:
	_target_hits += 1


func _hit_target() -> Hurtbox:
	var hb := Hurtbox.new()
	hb.radius = 30.0
	_target = hb
	hb.hit.connect(_on_target_hit)
	hb.position = Vector2(20, 10)
	add_child_autofree(hb)
	return hb


## A non-finite write of `field` from `hook` kills the bullet as INVALID.
func _assert_hook_write_kills(hook: String, field: String, value: float) -> void:
	var w := _hooked(hook, field, value)
	var before := manager.pool.invalid_total
	if hook == "hit" or hook == "can_hit":
		_hit_target()
		var r := _req()
		r.behavior_id = manager.register_behavior(w)
		r.can_hit_veto = hook == "can_hit"
		r.velocity = Vector2(300, 0)
		manager.spawn(r)
	else:
		_spawn_hooked(w)
	manager.step(DT)
	manager.step(DT)
	var label := "%s writing %s = %s" % [hook, field, value]
	assert_eq(manager.pool.invalid_total, before + 1, "%s is counted once" % label)
	assert_eq(manager.pool.count, 0, "%s: the bullet is gone" % label)
	assert_true(w.reasons.has(BulletPool.DespawnReason.INVALID), "%s reaches on_despawn as INVALID" % label)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write"), 1, "%s warns once" % label)
	if hook == "can_hit":
		assert_eq(_target_hits, 0, "%s: the hit does not land (no damage, no signal)" % label)


func test_on_update_writing_nan_radius_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "radius", NAN)


func test_on_update_writing_inf_radius_kills_the_bullet_and_max_radius_stays_finite() -> void:
	_assert_hook_write_kills("update", "radius", INF)
	assert_true(is_finite(manager.pool.max_radius))


func test_on_update_writing_nan_acceleration_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "accel", NAN)


func test_on_update_writing_nan_turn_rate_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "turn_rate", NAN)


func test_on_update_writing_nan_lifetime_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "lifetime", NAN)


func test_on_update_writing_nan_damage_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "damage", NAN)


func test_on_update_writing_nan_age_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "age", NAN)


func test_on_update_writing_nan_pos_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "pos", NAN)


func test_on_update_writing_nan_rot_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "rot", NAN)


func test_on_update_writing_nan_param_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "param_a", NAN)
	assert_eq(manager.pool.invalid_total, 1)


func test_on_update_writing_nan_param_b_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "param_b", NAN)


func test_on_update_writing_inf_param_a_kills_the_bullet() -> void:
	_assert_hook_write_kills("update", "param_a", INF)


func test_on_spawn_writing_nan_turn_rate_kills_the_bullet() -> void:
	_assert_hook_write_kills("spawn", "turn_rate", NAN)


func test_on_hit_writing_nan_lifetime_kills_the_bullet() -> void:
	_assert_hook_write_kills("hit", "lifetime", NAN)


func test_can_hit_writing_nan_accel_kills_the_bullet_and_lands_no_hit() -> void:
	_assert_hook_write_kills("can_hit", "accel", NAN)


func test_a_killed_bullet_leaves_no_non_finite_value_behind() -> void:
	var w := _hooked("update", "pos", INF)
	var slot := _spawn_hooked(w)
	manager.step(DT)
	# It was flushed; check the dead bullet's repair on a bare pool as well.
	assert_eq(manager.pool.count, 0)
	var s := pool.spawn(_req())
	pool.pos[s] = Vector2(NAN, NAN)
	assert_false(pool.sanitize(s))
	assert_true(pool.pos[s].is_finite())
	assert_true(pool.vel[s].is_finite())
	assert_eq(pool.dead_reason[s], BulletPool.DespawnReason.INVALID + 1)
	assert_true(slot >= 0)


func test_hook_writes_outside_the_range_are_clamped_not_killed() -> void:
	var w := _hooked("update", "radius", 1e9)
	var slot := _spawn_hooked(w)
	manager.step(DT)
	assert_eq(manager.pool.radius[slot], BulletLimits.MAX_RADIUS)
	assert_eq(manager.pool.max_radius, BulletLimits.MAX_RADIUS, "a hook-grown radius widens the grid margin")
	assert_eq(manager.pool.invalid_total, 0)
	assert_eq(manager.pool.count, 1)


func test_an_in_range_hook_grown_radius_widens_max_radius() -> void:
	var w := _hooked("update", "radius", 120.0)
	var slot := _spawn_hooked(w)
	manager.step(DT)
	assert_eq(manager.pool.radius[slot], 120.0, "inside the range: kept as written")
	assert_eq(manager.pool.max_radius, 120.0, "the hurtbox grid margin follows it")
	assert_eq(manager.pool.invalid_total, 0)


func test_hook_written_lifetime_accel_turn_rate_damage_are_clamped() -> void:
	var life := _hooked("update", "lifetime", 1e9)
	var slot := _spawn_hooked(life)
	manager.step(DT)
	assert_eq(manager.pool.lifetime[slot], BulletLimits.MAX_LIFETIME, "no immortal bullet through a hook either")
	manager.pool.accel[slot] = 1e12
	manager.pool.turn_rate[slot] = 1e12
	manager.pool.damage[slot] = 1e12
	life.field = ""
	manager.step(DT)
	assert_eq(manager.pool.accel[slot], BulletLimits.MAX_ACCELERATION)
	assert_eq(manager.pool.turn_rate[slot], BulletLimits.MAX_TURN_RATE)
	assert_eq(manager.pool.damage[slot], BulletLimits.MAX_DAMAGE)
	assert_eq(manager.pool.invalid_total, 0)


func test_a_negative_hook_written_lifetime_ends_the_bullet_next_tick() -> void:
	var w := _hooked("update", "lifetime", -50.0)
	_spawn_hooked(w)
	manager.step(DT)
	manager.step(DT)
	assert_eq(manager.pool.count, 0)
	assert_eq(manager.pool.invalid_total, 0)
	assert_true(w.reasons.has(BulletPool.DespawnReason.LIFETIME))


func test_a_flood_of_bad_hook_writes_prints_at_most_the_warning_limit() -> void:
	var w := _hooked("update", "turn_rate", NAN)
	for i in 20:
		_spawn_hooked(w)
	manager.step(DT)
	assert_eq(manager.pool.invalid_total, 20)
	assert_eq(ScriptWarnings.printed_count("BulletPool.hook_write"), ScriptWarnings.LIMIT)
