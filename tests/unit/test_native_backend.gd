extends GutTest
## Behaviour of the C++ NativeBulletSim through BulletManager (plain bullets).
## Skipped when the GDExtension is not built. If SCRIPTSHOT_BULLET_BACKEND=native
## is set the first test fails instead of skipping, so CI cannot silently run the
## GDScript backend twice.

const DT := 1.0 / 60.0

var manager: BulletManager


func before_each() -> void:
	manager = BulletManager.new()
	manager.backend_preference = "native" if NativeBackend.is_available() else "gdscript"
	manager.capacity = 256
	manager.world_bounds = Rect2(-500, -500, 1000, 1000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _need_native() -> bool:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return false
	return true


func _hurtbox(at: Vector2, r: float, counter: Array[int] = []) -> Hurtbox:
	var hb := Hurtbox.new()
	hb.radius = r
	hb.position = at
	add_child_autofree(hb)
	if counter.size() > 0:
		hb.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: counter[0] += 1)
	return hb


func _shot(from: Vector2, vel: Vector2, r: float = 2.0) -> ShotRequest:
	var req := ShotRequest.with_velocity(from, vel)
	req.radius = r
	req.lifetime = 10.0
	req.hit_mask = Layers.ENEMY
	return req


func test_requested_backend_is_used() -> void:
	var wanted := NativeBackend.requested_backend()
	if wanted == "native":
		assert_true(NativeBackend.is_available(), "SCRIPTSHOT_BULLET_BACKEND=native but the extension did not load")
	if not NativeBackend.is_available():
		assert_eq(manager.backend, "gdscript")
		return
	assert_eq(manager.backend, "native")


func test_plain_bullets_are_simulated_natively_and_hooked_ones_stay_in_the_pool() -> void:
	if not _need_native():
		return
	assert_gte(manager.spawn(_shot(Vector2.ZERO, Vector2(60, 0))), 0)
	manager.step(DT)
	assert_eq(manager.alive_count(), 1)
	assert_eq(manager.pool.count, 0, "plain bullets are not in the GDScript pool")
	var positions: PackedVector2Array = manager.snapshot()["pos"]
	assert_almost_eq(positions[0].x, 1.0, 0.001)


func test_ids_are_stable_and_stale_ids_die() -> void:
	if not _need_native():
		return
	var a := manager.spawn(_shot(Vector2(-400, 0), Vector2(0, 0)))
	var b := manager.spawn(_shot(Vector2(0, 0), Vector2(0, 0)))
	assert_true(manager.is_native_bullet_alive(a))
	assert_true(manager.is_native_bullet_alive(b))
	manager.native.kill(a)
	assert_false(manager.is_native_bullet_alive(a), "marked dead")
	manager.step(DT)
	assert_false(manager.is_native_bullet_alive(a))
	assert_true(manager.is_native_bullet_alive(b), "b moved into a's slot but kept its id")
	var c := manager.spawn(_shot(Vector2(10, 0), Vector2(0, 0)))
	assert_ne(c, a, "a reused handle carries a new generation")
	assert_false(manager.is_native_bullet_alive(a))


func test_lifetime_bounds_and_capacity() -> void:
	if not _need_native():
		return
	var short := _shot(Vector2.ZERO, Vector2.ZERO)
	short.lifetime = 0.05
	manager.spawn(short)
	manager.spawn(_shot(Vector2(499, 0), Vector2(600, 0)))
	manager.step(DT)
	assert_eq(manager.alive_count(), 1, "the bullet leaving the world is gone")
	manager.step(DT)
	manager.step(DT)
	manager.step(DT)
	assert_eq(manager.alive_count(), 0)
	var counts := manager.native.despawn_counts()
	assert_eq(counts[BulletPool.DespawnReason.LIFETIME], 1)
	assert_eq(counts[BulletPool.DespawnReason.BOUNDS], 1)
	for i in 300:
		manager.spawn(_shot(Vector2.ZERO, Vector2.ZERO))
	assert_eq(manager.alive_count(), 256)
	assert_eq(manager.native.dropped_total(), 44)


func test_accel_and_turn_rate_match_the_pool_math() -> void:
	if not _need_native():
		return
	var req := _shot(Vector2.ZERO, Vector2(100, 0))
	req.acceleration = 60.0
	req.turn_rate = 1.0
	manager.spawn(req)
	manager.step(DT)
	var snap := manager.snapshot()
	var vel: Vector2 = snap["vel"][0]
	assert_almost_eq(vel.length(), 101.0, 0.01)
	assert_almost_eq(vel.angle(), 1.0 * DT, 0.0001)


func test_hit_stops_bullet_at_the_contact_point_and_signals_the_hurtbox() -> void:
	if not _need_native():
		return
	var hits: Array[int] = [0]
	# 4000 px/s is the ceiling (~66.7 px/tick). Contact is at x = 40 - 8 - 4 = 28.
	_hurtbox(Vector2(40, 0), 8.0, hits)
	manager.spawn(_shot(Vector2(0, 0), Vector2(BulletLimits.MAX_SPEED, 0), 4.0))
	manager.step(DT)
	assert_eq(hits[0], 1)
	assert_eq(manager.alive_count(), 0)
	assert_eq(manager.last_hit_count, 1)
	assert_eq(manager.native.despawn_counts()[BulletPool.DespawnReason.HIT], 1)


func test_nearest_target_wins_even_when_a_bigger_one_is_scanned_first() -> void:
	# B1, scaled so one tick at the speed ceiling still reaches B and would reach A.
	# A (40, 0) r16 vs B (30, 12.8) r1.6, bullet along y=12.8. B's entry is nearer.
	if not _need_native():
		return
	var a_hits: Array[int] = [0]
	var b_hits: Array[int] = [0]
	_hurtbox(Vector2(40, 0), 16.0, a_hits)
	_hurtbox(Vector2(30, 12.8), 1.6, b_hits)
	manager.spawn(_shot(Vector2(0, 12.8), Vector2(3600, 0), 0.8))
	manager.step(DT)
	assert_eq(b_hits[0], 1, "B is nearer along the path")
	assert_eq(a_hits[0], 0, "the bullet died on B")


func test_piercing_bullet_hits_several_targets_in_one_tick() -> void:
	# B2: pierce + 1 hits per tick, impacts in path order, none twice.
	if not _need_native():
		return
	var per_target: Array[Array] = [[], [], []]
	# Packed so pierce 2 still reaches the third target in one tick under MAX_SPEED.
	var t1 := _hurtbox(Vector2(15, 0), 3.0)
	var t2 := _hurtbox(Vector2(30, 0), 3.0)
	var t3 := _hurtbox(Vector2(45, 0), 3.0)
	t1.hit.connect(func(_d: float, p: Vector2, _v: Vector2) -> void: per_target[0].append(p.x))
	t2.hit.connect(func(_d: float, p: Vector2, _v: Vector2) -> void: per_target[1].append(p.x))
	t3.hit.connect(func(_d: float, p: Vector2, _v: Vector2) -> void: per_target[2].append(p.x))
	var req := _shot(Vector2(0, 0), Vector2(3600, 0), 0.6)  # 60 px per tick
	req.pierce = 2
	manager.spawn(req)
	manager.step(DT)
	assert_eq(per_target[0].size(), 1)
	assert_eq(per_target[1].size(), 1)
	assert_eq(per_target[2].size(), 1, "third hit kills the bullet (pierce 2 = 3 hits)")
	assert_eq(manager.alive_count(), 0)
	var x1: float = per_target[0][0]
	var x2: float = per_target[1][0]
	var x3: float = per_target[2][0]
	assert_true(x1 < x2 and x2 < x3, "impacts come in path order")


func test_walls_stop_bullets_unless_opted_out() -> void:
	if not _need_native():
		return
	# Contact at x = 90 - 3 = 87. One tick at the ceiling covers ~66.7 px, so the
	# wall is the second tick, not the first.
	manager.add_wall(Rect2(90, -50, 20, 100))
	manager.spawn(_shot(Vector2(0, 0), Vector2(BulletLimits.MAX_SPEED, 0), 3.0))
	var ghost := _shot(Vector2(0, 10), Vector2(BulletLimits.MAX_SPEED, 0), 3.0)
	ghost.collide_world = false
	manager.spawn(ghost)
	manager.step(DT)
	manager.step(DT)
	assert_eq(manager.alive_count(), 1, "only the world-ignoring bullet survives")
	assert_eq(manager.native.despawn_counts()[BulletPool.DespawnReason.WALL], 1)
	assert_eq(manager.last_wall_hit_count, 1, "counted on the tick it happened (the second one)")


func test_bullet_crossing_the_world_edge_still_hits_on_its_last_segment() -> void:
	if not _need_native():
		return
	var hits: Array[int] = [0]
	_hurtbox(Vector2(490, 0), 10.0, hits)
	# Ceiling speed from x=470 ends near 536.7, past the world edge at 500, and
	# the hurtbox (contact near 478) is still on that last segment.
	manager.spawn(_shot(Vector2(470, 0), Vector2(BulletLimits.MAX_SPEED, 0), 2.0))
	manager.step(DT)
	assert_eq(hits[0], 1)
	assert_eq(manager.native.despawn_counts()[BulletPool.DespawnReason.HIT], 1)


func test_over_speed_spawn_is_clamped_to_bullet_limits() -> void:
	if not _need_native():
		return
	manager.spawn(_shot(Vector2.ZERO, Vector2(8000, 0)))
	manager.step(DT)
	var vel: Vector2 = manager.snapshot()["vel"][0]
	assert_almost_eq(vel.length(), BulletLimits.MAX_SPEED, 0.05)
	var pos: Vector2 = manager.snapshot()["pos"][0]
	assert_almost_eq(pos.x, BulletLimits.MAX_SPEED * DT, 0.05)


func test_non_finite_spawn_is_refused() -> void:
	if not _need_native():
		return
	var req := _shot(Vector2.ZERO, Vector2(10, 0))
	req.velocity = Vector2(NAN, 0)
	assert_eq(manager.spawn(req), -1)
	assert_eq(manager.alive_count(), 0)
	assert_eq(manager.native.dropped_total(), 0, "a bad shot is not a capacity drop")


func test_unset_auto_stays_on_gdscript_and_gdscript_cannot_be_overridden() -> void:
	var auto := BulletManager.new()
	auto.backend_preference = "auto"
	auto.render_enabled = false
	auto.auto_step = false
	add_child_autofree(auto)
	if NativeBackend.requested_backend() == "native" and NativeBackend.is_available():
		assert_eq(auto.backend, "native")
	else:
		assert_eq(auto.backend, "gdscript")
	var forced := BulletManager.new()
	forced.backend_preference = "gdscript"
	forced.render_enabled = false
	forced.auto_step = false
	add_child_autofree(forced)
	assert_eq(forced.backend, "gdscript")


func test_emitter_id_tracks_a_plain_native_bullet_and_hook_spawns_stay_in_the_pool() -> void:
	if not _need_native():
		return
	var id := manager.emitter.request_shot_id(_shot(Vector2.ZERO, Vector2(60, 0)))
	assert_true(manager.is_native_id(id))
	assert_true(manager.emitter.is_bullet_alive(id))
	assert_eq(manager.pool.count, 0)
	var behavior := _SpawnPlain.new()
	var behavior_id := manager.register_behavior(behavior)
	var parent := _shot(Vector2(0, 20), Vector2.ZERO)
	parent.behavior_id = behavior_id
	assert_gte(manager.spawn(parent), 0)
	# The hooked parent and the plain bullet its on_spawn fired both stay in the pool.
	assert_eq(manager.pool.count, 2)
	assert_eq(manager.alive_count(), 3)
	assert_true(manager.emitter.is_bullet_alive(id))


class _SpawnPlain:
	extends BulletBehavior

	func on_spawn(_pool: BulletPool, _index: int) -> void:
		var req := ShotRequest.with_velocity(Vector2(4, 0), Vector2.ZERO)
		req.lifetime = 5.0
		emitter.request_shot(req)


func test_upload_fills_current_and_previous_buffers() -> void:
	if not _need_native():
		return
	manager.spawn(_shot(Vector2(10, 20), Vector2(60, 0), 5.0))
	manager.step(DT)
	var mm := RenderingServer.multimesh_create()
	RenderingServer.multimesh_allocate_data(mm, 256, RenderingServer.MULTIMESH_TRANSFORM_2D, true)
	var shown := manager.native.upload(mm, 256, false, 1.0)
	assert_eq(shown, 1)
	var buf := RenderingServer.multimesh_get_buffer(mm)
	assert_almost_eq(buf[3], 11.0, 0.001, "origin x")
	assert_almost_eq(buf[7], 20.0, 0.001, "origin y")
	assert_almost_eq(buf[0], 10.0, 0.001, "basis x scale = 2 * radius")
	RenderingServer.free_rid(mm)
