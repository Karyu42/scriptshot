extends GutTest
## Bullet speed ceiling (BulletLimits.MAX_SPEED = 4,000 px/s): every velocity
## write is clamped, direction kept; NaN / inf fall through to INVALID handling.

const DT := 1.0 / 60.0
const MAX := BulletLimits.MAX_SPEED

var manager: BulletManager


class Writer:
	extends BulletBehavior
	## What on_spawn / on_update / on_hit write into pool.vel.
	var on_spawn_vel := Vector2.ZERO
	var on_update_vel := Vector2.ZERO
	var write_spawn := false
	var write_update := false
	var reasons: Array[int] = []

	func on_spawn(pool: BulletPool, index: int) -> void:
		if write_spawn:
			pool.vel[index] = on_spawn_vel

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		if write_update:
			pool.vel[index] = on_update_vel

	func on_despawn(_pool: BulletPool, _index: int, reason: int) -> void:
		reasons.append(reason)


func before_each() -> void:
	ScriptWarnings.reset()
	manager = BulletManager.new()
	manager.capacity = 64
	manager.world_bounds = Rect2(-100000, -100000, 200000, 200000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _writer() -> Writer:
	return Writer.new()


func _request(velocity: Vector2, behavior: BulletBehavior = null) -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2.ZERO, velocity)
	r.lifetime = 10.0
	if behavior != null:
		r.behavior_id = manager.register_behavior(behavior)
	return r


# --- the constant and the helper ----------------------------------------------

func test_the_ceiling_is_4000_and_defined_once() -> void:
	assert_eq(BulletLimits.MAX_SPEED, 4000.0)
	assert_eq(BulletLimits.MAX_SPEED_SQ, 16000000.0)


func test_clamp_velocity_keeps_direction_and_leaves_legal_values_alone() -> void:
	assert_eq(BulletLimits.clamp_velocity(Vector2(300, -400)), Vector2(300, -400))
	assert_eq(BulletLimits.clamp_velocity(Vector2(4000, 0)), Vector2(4000, 0), "exactly at the ceiling")
	var c := BulletLimits.clamp_velocity(Vector2(3e4, 4e4))
	assert_almost_eq(c.length(), MAX, 0.01)
	assert_almost_eq(c.angle(), Vector2(3, 4).angle(), 1e-5)
	assert_eq(BulletLimits.clamp_velocity(Vector2.ZERO), Vector2.ZERO)


func test_clamp_velocity_survives_values_that_overflow_the_squared_length() -> void:
	var c := BulletLimits.clamp_velocity(Vector2(-1e30, 1e30))
	assert_true(c.is_finite())
	assert_almost_eq(c.length(), MAX, 0.01)
	assert_true(c.x < 0.0 and c.y > 0.0, "direction kept")
	var one_axis := BulletLimits.clamp_velocity(Vector2(0, -1e9))
	assert_eq(one_axis, Vector2(0, -MAX))


# --- spawn -----------------------------------------------------------------------

func test_spawn_clamps_a_too_fast_request_and_keeps_the_direction() -> void:
	var slot := manager.spawn(_request(Vector2(0, -1e9)))
	assert_eq(manager.pool.vel[slot], Vector2(0, -MAX))
	assert_eq(manager.pool.rot[slot], Vector2(0, -1), "heading follows the direction, not the old speed")


func test_spawn_leaves_a_legal_speed_alone() -> void:
	var slot := manager.spawn(_request(Vector2(1200, 900)))
	assert_eq(manager.pool.vel[slot], Vector2(1200, 900))


func test_spawn_simple_is_clamped_too() -> void:
	var pool := manager.pool
	var slot := pool.spawn_simple(Vector2.ZERO, Vector2(8000, 6000), 5.0)
	assert_almost_eq(pool.vel[slot].length(), MAX, 0.01)
	assert_almost_eq(pool.vel[slot].angle(), Vector2(8, 6).angle(), 1e-5)


func test_polar_requests_at_absurd_speeds_are_clamped_at_spawn() -> void:
	var slot := manager.spawn(ShotRequest.polar(Vector2.ZERO, PI * 0.25, 1e9))
	assert_almost_eq(manager.pool.vel[slot].length(), MAX, 0.01)


func test_a_non_finite_velocity_or_position_is_rejected_and_counted_not_clamped() -> void:
	var pool := manager.pool
	for v: Vector2 in [Vector2(NAN, 0), Vector2(0, INF), Vector2(-INF, NAN)]:
		assert_eq(manager.spawn(_request(v)), -1)
	var r := _request(Vector2(100, 0))
	r.position = Vector2(NAN, 0)
	assert_eq(manager.spawn(r), -1)
	assert_eq(pool.spawn_simple(Vector2.ZERO, Vector2(NAN, 1), 1.0), -1)
	assert_eq(pool.count, 0)
	assert_eq(pool.invalid_total, 5)
	assert_eq(pool.dropped_total, 0, "not a capacity drop")
	assert_eq(ScriptWarnings.printed_count("BulletPool.spawn"), 3, "warning is capped")
	assert_eq(ScriptWarnings.count("BulletPool.spawn"), 4)


# --- set_velocity / sanitize ---------------------------------------------------

func test_set_velocity_clamps_and_keeps_the_direction() -> void:
	var pool := manager.pool
	var slot := manager.spawn(_request(Vector2(100, 0)))
	assert_true(pool.set_velocity(slot, Vector2(-5e5, 0)))
	assert_eq(pool.vel[slot], Vector2(-MAX, 0))
	assert_true(pool.set_velocity(slot, Vector2(10, 20)))
	assert_eq(pool.vel[slot], Vector2(10, 20))


func test_set_velocity_with_nan_or_inf_kills_the_bullet_as_invalid() -> void:
	var pool := manager.pool
	for bad: Vector2 in [Vector2(NAN, 0), Vector2(0, INF)]:
		var slot := manager.spawn(_request(Vector2(100, 0)))
		assert_false(pool.set_velocity(slot, bad))
		assert_eq(pool.dead_reason[slot], BulletPool.DespawnReason.INVALID + 1)
		assert_true(pool.vel[slot].is_finite(), "no NaN is ever stored")
	assert_eq(pool.invalid_total, 2)
	assert_eq(pool.flush_dead(), 2)


func test_set_velocity_ignores_dead_and_out_of_range_slots() -> void:
	var pool := manager.pool
	var slot := manager.spawn(_request(Vector2(100, 0)))
	pool.mark_dead(slot)
	assert_false(pool.set_velocity(slot, Vector2(1, 1)))
	assert_false(pool.set_velocity(-1, Vector2(1, 1)))
	assert_false(pool.set_velocity(99, Vector2(1, 1)))


# --- hooks writing pool.vel directly -----------------------------------------------

func test_an_on_update_write_above_the_ceiling_is_clamped_before_the_bullet_moves() -> void:
	var w := _writer()
	w.write_update = true
	w.on_update_vel = Vector2(0, 1e9)
	var slot := manager.spawn(_request(Vector2(100, 0), w))
	manager.step(DT)
	assert_eq(manager.pool.vel[slot], Vector2(0, MAX))
	manager.step(DT)
	assert_almost_eq(manager.pool.pos[slot].y, MAX * DT, 0.01, "moved at the ceiling, not at 1e9")


func test_an_on_spawn_write_is_clamped() -> void:
	var w := _writer()
	w.write_spawn = true
	w.on_spawn_vel = Vector2(-9e9, 0)
	var slot := manager.spawn(_request(Vector2(100, 0), w))
	assert_eq(manager.pool.vel[slot], Vector2(-MAX, 0))


func test_a_nan_written_by_on_update_kills_the_bullet_as_invalid_and_reaches_on_despawn() -> void:
	var w := _writer()
	w.write_update = true
	w.on_update_vel = Vector2(NAN, 5)
	manager.spawn(_request(Vector2(100, 0), w))
	manager.step(DT)
	assert_eq(manager.pool.count, 0)
	assert_eq(w.reasons, [BulletPool.DespawnReason.INVALID] as Array[int])
	assert_eq(manager.pool.invalid_total, 1)
	assert_eq(ScriptWarnings.count("BulletPool.velocity"), 1)


func test_a_nan_written_by_on_spawn_kills_the_bullet() -> void:
	var w := _writer()
	w.write_spawn = true
	w.on_spawn_vel = Vector2(INF, 0)
	manager.spawn(_request(Vector2(100, 0), w))
	manager.step(DT)
	assert_eq(manager.pool.count, 0)
	assert_eq(w.reasons, [BulletPool.DespawnReason.INVALID] as Array[int])


func test_a_flood_of_bad_writes_prints_at_most_the_warning_limit() -> void:
	var w := _writer()
	w.write_update = true
	w.on_update_vel = Vector2(NAN, NAN)
	for i in 20:
		manager.spawn(_request(Vector2(100, 0), w))
	manager.step(DT)
	assert_eq(manager.pool.invalid_total, 20)
	assert_eq(ScriptWarnings.printed_count("BulletPool.velocity"), ScriptWarnings.LIMIT)


# --- acceleration cannot creep past the ceiling ----------------------------------

func test_acceleration_stops_at_the_ceiling() -> void:
	var r := _request(Vector2(3900, 0))
	r.acceleration = 5000.0
	var slot := manager.spawn(r)
	for i in 30:
		manager.step(DT)
	assert_almost_eq(manager.pool.vel[slot].length(), MAX, 0.01)
	assert_eq(manager.pool.vel[slot].normalized(), Vector2.RIGHT)


func test_a_swept_bullet_at_the_ceiling_still_cannot_tunnel() -> void:
	var hb := Hurtbox.new()
	hb.radius = 5.0
	hb.position = Vector2(60, 0)
	add_child_autofree(hb)
	watch_signals(hb)
	manager.spawn(_request(Vector2(1e9, 0)))
	manager.step(DT)
	assert_signal_emit_count(hb, "hit", 1)


# --- reflect -------------------------------------------------------------------

func test_reflector_speed_multiplier_cannot_push_a_bullet_over_the_ceiling() -> void:
	var zone := Reflector.new()
	zone.radius = 40.0
	zone.speed_multiplier = 20.0
	add_child_autofree(zone)
	zone.global_position = Vector2(200, 0)
	var r := _request(Vector2(3000, 0))
	r.position = Vector2(100, 0)
	r.owner_layer = Layers.PLAYER
	r.hit_mask = Layers.ENEMY
	r.collide_world = false
	var slot := manager.spawn(r)
	for i in 3:
		manager.step(DT)
	slot = manager.pool.slot_of(manager.pool.id_of(slot)) if slot < manager.pool.count else slot
	assert_eq(manager.pool.owner_layer[0], Layers.ENEMY, "reflected")
	assert_almost_eq(manager.pool.vel[0].length(), MAX, 0.01, "3000 x 20 clamped to 4000")
	assert_true(manager.pool.vel[0].x < 0.0, "heading kept: it flies back")


func test_pool_reflect_with_reverse_keeps_the_speed() -> void:
	var pool := manager.pool
	var slot := manager.spawn(_request(Vector2(MAX, 0)))
	assert_true(pool.reflect(slot, Layers.ENEMY, true))
	assert_eq(pool.vel[slot], Vector2(-MAX, 0))
