extends GutTest
## BulletPool: spawn, despawn, recycling, lifetime expiry, capacity, kinematics.

const BOUNDS := Rect2(-1000, -1000, 2000, 2000)
const DT := 1.0 / 60.0

var pool: BulletPool


func before_each() -> void:
	pool = BulletPool.new(8)


func _spawn_at_x(x: float, life: float = 10.0) -> int:
	return pool.spawn_simple(Vector2(x, 0), Vector2.ZERO, life)


## True if the user slot holds `expected`. (Variants are compared here rather
## than passed to assert_*, which the project's unsafe-call warnings reject.)
func _user_is(slot: int, expected: Variant) -> bool:
	return pool.user[slot] == expected


func _xs() -> Array:
	var out := []
	for i in pool.count:
		out.append(pool.pos[i].x)
	out.sort()
	return out


# --- spawn ------------------------------------------------------------------

func test_new_pool_is_empty_with_fixed_capacity() -> void:
	assert_eq(pool.count, 0)
	assert_eq(pool.capacity, 8)
	assert_eq(pool.pos.size(), 8)
	assert_eq(pool.color.size(), 8)
	assert_false(pool.is_full())


func test_spawn_copies_every_request_field() -> void:
	var r := ShotRequest.new()
	r.position = Vector2(10, 20)
	r.velocity = Vector2(0, 300)
	r.angle = 1.0
	r.lifetime = 3.5
	r.radius = 6.0
	r.damage = 2.5
	r.hit_mask = Layers.PLAYER
	r.color = Color.RED
	r.behavior_id = 7
	r.acceleration = 12.0
	r.turn_rate = 0.5
	r.pierce = 2
	r.param_a = 1.5
	r.param_b = -2.0
	var i := pool.spawn(r)
	assert_eq(i, 0)
	assert_eq(pool.count, 1)
	assert_eq(pool.pos[0], Vector2(10, 20))
	assert_eq(pool.vel[0], Vector2(0, 300))
	assert_almost_eq(pool.rot[0].angle(), 1.0, 0.0001)
	assert_eq(pool.lifetime[0], 3.5)
	assert_eq(pool.radius[0], 6.0)
	assert_eq(pool.damage[0], 2.5)
	assert_eq(pool.hit_mask[0], Layers.PLAYER)
	assert_eq(pool.color[0], Color.RED)
	assert_eq(pool.behavior[0], 7)
	assert_eq(pool.accel[0], 12.0)
	assert_eq(pool.turn_rate[0], 0.5)
	assert_eq(pool.pierce[0], 2)
	assert_eq(pool.param_a[0], 1.5)
	assert_eq(pool.param_b[0], -2.0)
	assert_eq(pool.age[0], 0.0)


func test_spawn_without_angle_faces_velocity() -> void:
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(0, -50))
	pool.spawn(r)
	assert_almost_eq(pool.rot[0].x, 0.0, 0.0001)
	assert_almost_eq(pool.rot[0].y, -1.0, 0.0001)


func test_spawn_with_zero_velocity_and_no_angle_is_safe() -> void:
	pool.spawn(ShotRequest.new())
	assert_eq(pool.rot[0], Vector2.RIGHT)


func test_spawn_simple_defaults() -> void:
	var i := pool.spawn_simple(Vector2(1, 2), Vector2(3, 4), 2.0)
	assert_eq(i, 0)
	assert_eq(pool.pos[0], Vector2(1, 2))
	assert_eq(pool.hit_mask[0], 0)
	assert_eq(pool.behavior[0], 0)


func test_max_radius_tracks_largest_spawn() -> void:
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0, 3.0)
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0, 9.0)
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0, 5.0)
	assert_eq(pool.max_radius, 9.0)


# --- capacity -----------------------------------------------------------------

func test_spawn_at_capacity_is_rejected() -> void:
	for i in 8:
		assert_eq(_spawn_at_x(i), i)
	assert_true(pool.is_full())
	assert_eq(_spawn_at_x(99), -1)
	assert_eq(pool.count, 8)
	assert_eq(pool.dropped_total, 1)
	assert_eq(pool.spawned_total, 8)
	assert_false(_xs().has(99.0), "rejected bullet must not appear in the pool")


func test_spawn_request_at_capacity_is_rejected() -> void:
	for i in 8:
		_spawn_at_x(i)
	assert_eq(pool.spawn(ShotRequest.new()), -1)
	assert_eq(pool.dropped_total, 1)


# --- despawn + recycling ------------------------------------------------------

func test_despawn_swaps_last_bullet_into_freed_slot() -> void:
	_spawn_at_x(0.0)
	_spawn_at_x(1.0)
	_spawn_at_x(2.0)
	pool.despawn(0)
	assert_eq(pool.count, 2)
	assert_eq(pool.pos[0].x, 2.0, "last bullet moved into slot 0")
	assert_eq(pool.pos[1].x, 1.0)


func test_despawn_last_slot() -> void:
	_spawn_at_x(0.0)
	_spawn_at_x(1.0)
	pool.despawn(1)
	assert_eq(pool.count, 1)
	assert_eq(pool.pos[0].x, 0.0)


func test_despawn_moves_all_fields_together() -> void:
	pool.spawn_simple(Vector2(0, 0), Vector2.ZERO, 5.0, 1.0, Color.RED)
	pool.spawn_simple(Vector2(9, 0), Vector2(1, 0), 7.0, 2.0, Color.BLUE, Layers.ENEMY)
	pool.despawn(0)
	assert_eq(pool.pos[0].x, 9.0)
	assert_eq(pool.vel[0], Vector2(1, 0))
	assert_eq(pool.lifetime[0], 7.0)
	assert_eq(pool.radius[0], 2.0)
	assert_eq(pool.color[0], Color.BLUE)
	assert_eq(pool.hit_mask[0], Layers.ENEMY)


func test_slots_are_recycled_without_growing_storage() -> void:
	for round_index in 5:
		for i in 8:
			assert_ne(_spawn_at_x(i), -1, "round %d slot %d" % [round_index, i])
		assert_true(pool.is_full())
		pool.clear()
		assert_eq(pool.count, 0)
	assert_eq(pool.pos.size(), 8, "arrays never reallocate")
	assert_eq(pool.spawned_total, 40)
	assert_eq(pool.dropped_total, 0)


func test_spawn_after_partial_despawn_reuses_freed_capacity() -> void:
	for i in 8:
		_spawn_at_x(i)
	pool.despawn(3)
	pool.despawn(0)
	assert_false(pool.is_full())
	assert_ne(_spawn_at_x(100), -1)
	assert_ne(_spawn_at_x(101), -1)
	assert_eq(_spawn_at_x(102), -1)
	assert_eq(pool.count, 8)


func test_respawned_slot_does_not_inherit_old_state() -> void:
	var r := ShotRequest.new()
	r.pierce = 3
	r.turn_rate = 2.0
	r.behavior_id = 4
	pool.spawn(r)
	pool.mark_dead(0)
	pool.flush_dead()
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0)
	assert_eq(pool.pierce[0], 0)
	assert_eq(pool.turn_rate[0], 0.0)
	assert_eq(pool.behavior[0], 0)
	assert_eq(pool.dead_reason[0], 0)


# --- mark_dead / flush_dead ---------------------------------------------------

func test_flush_dead_removes_exactly_the_marked_bullets() -> void:
	for i in 8:
		_spawn_at_x(float(i))
	for i: int in [0, 3, 5, 7]:
		pool.mark_dead(i)
	assert_eq(pool.count, 8, "marking alone removes nothing")
	assert_eq(pool.flush_dead(), 4)
	assert_eq(pool.count, 4)
	assert_eq(_xs(), [1.0, 2.0, 4.0, 6.0])
	assert_eq(pool.pending_count, 0)
	for i in pool.count:
		assert_eq(pool.dead_reason[i], 0, "survivors are not flagged dead")


func test_flush_dead_handles_all_bullets_marked() -> void:
	for i in 8:
		_spawn_at_x(float(i))
	for i in 8:
		pool.mark_dead(i)
	assert_eq(pool.flush_dead(), 8)
	assert_eq(pool.count, 0)


func test_flush_dead_handles_marks_in_any_order() -> void:
	for i in 8:
		_spawn_at_x(float(i))
	for i: int in [6, 1, 7, 2]:
		pool.mark_dead(i)
	pool.flush_dead()
	assert_eq(_xs(), [0.0, 3.0, 4.0, 5.0])


func test_mark_dead_is_idempotent_and_first_reason_wins() -> void:
	_spawn_at_x(0.0)
	_spawn_at_x(1.0)
	pool.mark_dead(0, BulletPool.DespawnReason.HIT)
	pool.mark_dead(0, BulletPool.DespawnReason.LIFETIME)
	assert_eq(pool.pending_count, 1)
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.HIT + 1)
	assert_eq(pool.flush_dead(), 1)
	assert_eq(pool.count, 1)


func test_flush_with_nothing_pending_is_a_noop() -> void:
	_spawn_at_x(0.0)
	assert_eq(pool.flush_dead(), 0)
	assert_eq(pool.count, 1)


# --- lifetime + bounds expiry -------------------------------------------------

func test_bullet_expires_when_age_reaches_lifetime() -> void:
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 0.5)
	for i in 29:
		pool.advance(DT, BOUNDS)
	assert_eq(pool.pending_count, 0, "alive just before 0.5 s")
	for i in 2:
		pool.advance(DT, BOUNDS)
	assert_eq(pool.pending_count, 1)
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.LIFETIME + 1)
	pool.flush_dead()
	assert_eq(pool.count, 0)


func test_only_expired_bullets_are_removed() -> void:
	pool.spawn_simple(Vector2(0, 0), Vector2.ZERO, 0.05)
	pool.spawn_simple(Vector2(1, 0), Vector2.ZERO, 5.0)
	pool.spawn_simple(Vector2(2, 0), Vector2.ZERO, 0.05)
	for i in 4:
		pool.advance(DT, BOUNDS)
	pool.flush_dead()
	assert_eq(pool.count, 1)
	assert_eq(pool.pos[0].x, 1.0)


func test_bullet_leaving_bounds_is_marked_for_removal() -> void:
	# Moves 5 px per tick: 994 -> 999 (inside) -> 1004 (outside, bounds end at 1000).
	pool.spawn_simple(Vector2(994, 0), Vector2(300, 0), 10.0)
	pool.advance(DT, BOUNDS)
	assert_eq(pool.pending_count, 0, "still inside after the first tick")
	pool.advance(DT, BOUNDS)
	assert_eq(pool.pending_count, 1)
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.BOUNDS + 1)


func test_bullet_just_inside_bounds_survives() -> void:
	pool.spawn_simple(Vector2(0, 0), Vector2(60, 0), 10.0)
	pool.advance(DT, BOUNDS)
	assert_eq(pool.pending_count, 0)


# --- kinematics -----------------------------------------------------------------

func test_advance_integrates_position_and_age() -> void:
	pool.spawn_simple(Vector2(0, 0), Vector2(60, -120), 10.0)
	for i in 60:
		pool.advance(DT, BOUNDS)
	assert_almost_eq(pool.pos[0].x, 60.0, 0.01)
	assert_almost_eq(pool.pos[0].y, -120.0, 0.01)
	assert_almost_eq(pool.age[0], 1.0, 0.001)


func test_acceleration_changes_speed_along_heading() -> void:
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(100, 0))
	r.acceleration = 60.0
	r.lifetime = 10.0
	pool.spawn(r)
	for i in 60:
		pool.advance(DT, BOUNDS)
	assert_almost_eq(pool.vel[0].x, 160.0, 0.01)
	assert_almost_eq(pool.vel[0].y, 0.0, 0.001)


func test_braking_never_reverses_the_bullet() -> void:
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0))
	r.acceleration = -1000.0
	r.lifetime = 10.0
	pool.spawn(r)
	for i in 10:
		pool.advance(DT, BOUNDS)
	assert_eq(pool.vel[0], Vector2.ZERO)


func test_turn_rate_rotates_velocity_and_orientation_together() -> void:
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(100, 0))
	r.turn_rate = PI / 2.0
	r.lifetime = 10.0
	pool.spawn(r)
	for i in 60:
		pool.advance(DT, BOUNDS)
	assert_almost_eq(pool.vel[0].x, 0.0, 0.01)
	assert_almost_eq(pool.vel[0].y, 100.0, 0.01)
	assert_almost_eq(pool.rot[0].angle(), PI / 2.0, 0.001)
	assert_almost_eq(pool.vel[0].length(), 100.0, 0.01)


func test_advance_builds_hooked_list_from_alive_behaviour_bullets_only() -> void:
	pool.spawn_simple(Vector2(0, 0), Vector2.ZERO, 10.0)
	var r := ShotRequest.new()
	r.behavior_id = 2
	r.lifetime = 10.0
	pool.spawn(r)
	var short := ShotRequest.new()
	short.behavior_id = 2
	short.lifetime = 0.001
	pool.spawn(short)
	pool.advance(DT, BOUNDS)
	assert_eq(pool.hooked_count, 1)
	assert_eq(pool.hooked[0], 1)


func test_advance_skips_bullets_already_marked_dead() -> void:
	pool.spawn_simple(Vector2.ZERO, Vector2(60, 0), 10.0)
	pool.mark_dead(0, BulletPool.DespawnReason.HIT)
	pool.advance(DT, BOUNDS)
	assert_eq(pool.pos[0], Vector2.ZERO)
	assert_eq(pool.pending_count, 1)


# --- sweep support, world flag, allocation-free flush -------------------------

func test_spawn_starts_with_prev_pos_at_spawn_point_and_collides_with_world() -> void:
	var i := pool.spawn(ShotRequest.polar(Vector2(5, 6), 0.0, 100.0))
	assert_eq(pool.prev_pos[i], Vector2(5, 6))
	assert_eq(pool.collide_world[i], 1)
	var r := ShotRequest.polar(Vector2.ZERO, 0.0, 10.0)
	r.collide_world = false
	var j := pool.spawn(r)
	assert_eq(pool.collide_world[j], 0)
	var k := pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0)
	assert_eq(pool.collide_world[k], 1)


func test_advance_records_the_previous_position() -> void:
	pool.spawn(ShotRequest.polar(Vector2(0, 0), 0.0, 60.0))
	pool.advance(DT, BOUNDS)
	assert_eq(pool.prev_pos[0], Vector2(0, 0))
	assert_almost_eq(pool.pos[0].x, 1.0, 0.0001)
	pool.advance(DT, BOUNDS)
	assert_almost_eq(pool.prev_pos[0].x, 1.0, 0.0001)
	assert_almost_eq(pool.pos[0].x, 2.0, 0.0001)


func test_swap_removal_moves_prev_pos_and_world_flag_with_the_bullet() -> void:
	var a := ShotRequest.polar(Vector2(0, 0), 0.0, 60.0)
	var b := ShotRequest.polar(Vector2(100, 0), 0.0, 60.0)
	b.collide_world = false
	pool.spawn(a)
	pool.spawn(b)
	pool.advance(DT, BOUNDS)
	pool.despawn(0)
	assert_eq(pool.count, 1)
	assert_almost_eq(pool.pos[0].x, 101.0, 0.0001)
	assert_almost_eq(pool.prev_pos[0].x, 100.0, 0.0001)
	assert_eq(pool.collide_world[0], 0)


func test_wall_is_a_despawn_reason_and_old_values_are_unchanged() -> void:
	assert_eq(BulletPool.DespawnReason.LIFETIME, 0)
	assert_eq(BulletPool.DespawnReason.BOUNDS, 1)
	assert_eq(BulletPool.DespawnReason.HIT, 2)
	assert_eq(BulletPool.DespawnReason.MANUAL, 3)
	assert_eq(BulletPool.DespawnReason.CLEARED, 4)
	assert_eq(BulletPool.DespawnReason.WALL, 5)


func test_flush_dead_matches_a_reference_for_random_mark_sets() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var big := BulletPool.new(64)
	for round_index in 200:
		big.clear()
		var n := rng.randi_range(1, 64)
		for i in n:
			big.spawn_simple(Vector2(float(i), 0.0), Vector2.ZERO, 10.0)
		var doomed := {}
		var marks: Array[int] = []
		for i in n:
			if rng.randf() < 0.5:
				marks.append(i)
		marks.shuffle()
		for i in marks:
			doomed[float(i)] = true
			big.mark_dead(i)
		var expected: Array[float] = []
		for i in n:
			if not doomed.has(float(i)):
				expected.append(float(i))
		assert_eq(big.flush_dead(), marks.size())
		var survivors: Array[float] = []
		for i in big.count:
			survivors.append(big.pos[i].x)
			assert_eq(big.dead_reason[i], 0, "survivor flagged dead (round %d)" % round_index)
		survivors.sort()
		assert_eq(survivors, expected, "round %d" % round_index)
		if survivors != expected:
			break


func test_flush_dead_does_not_reallocate_its_work_list() -> void:
	for i in 8:
		_spawn_at_x(float(i))
	var size_before := pool.pending.size()
	pool.mark_dead(1)
	pool.mark_dead(2)
	pool.flush_dead()
	assert_eq(pool.pending.size(), size_before, "pending stays a fixed-size scratch array")


# --- stable handles -------------------------------------------------------------

func test_spawn_ids_are_positive_and_unique() -> void:
	var ids := {}
	for i in 8:
		var slot := _spawn_at_x(float(i))
		var id := pool.id_of(slot)
		assert_gt(id, 0)
		assert_false(ids.has(id), "duplicate id")
		ids[id] = true
		assert_eq(pool.slot_of(id), slot)
		assert_true(pool.is_alive(id))


func test_id_follows_bullet_when_swap_remove_moves_it() -> void:
	var a := pool.id_of(_spawn_at_x(0.0))
	var b := pool.id_of(_spawn_at_x(1.0))
	var c := pool.id_of(_spawn_at_x(2.0))
	assert_eq(pool.slot_of(c), 2)
	pool.despawn(0)
	assert_eq(pool.slot_of(c), 0, "c was swapped into slot 0")
	assert_eq(pool.pos[pool.slot_of(c)].x, 2.0)
	assert_eq(pool.slot_of(b), 1)
	assert_eq(pool.pos[pool.slot_of(b)].x, 1.0)
	assert_eq(pool.slot_of(a), -1)
	assert_eq(pool.id_of(pool.slot_of(c)), c)


func test_despawned_id_is_stale() -> void:
	var id := pool.id_of(_spawn_at_x(0.0))
	pool.despawn(0)
	assert_eq(pool.slot_of(id), -1)
	assert_false(pool.is_alive(id))


func test_handle_is_reused_but_stale_id_stays_stale_after_recycle() -> void:
	var old_id := pool.id_of(_spawn_at_x(0.0))
	pool.despawn(0)
	var new_id := pool.id_of(_spawn_at_x(5.0))
	# The free handle is reused (same low bits) with a bumped generation.
	assert_eq(old_id & BulletPool.HANDLE_MASK, new_id & BulletPool.HANDLE_MASK, "handle reused")
	assert_ne(old_id, new_id)
	assert_gt(new_id >> BulletPool.HANDLE_BITS, old_id >> BulletPool.HANDLE_BITS)
	assert_eq(pool.slot_of(old_id), -1, "stale id must not resolve to the new bullet")
	assert_false(pool.is_alive(old_id))
	assert_eq(pool.slot_of(new_id), 0)
	assert_eq(pool.pos[0].x, 5.0)


func test_stale_ids_stay_stale_through_many_recycles() -> void:
	var stale: Array[int] = []
	for round_index in 50:
		var id := pool.id_of(_spawn_at_x(float(round_index)))
		stale.append(id)
		pool.despawn(0)
	var live := pool.id_of(_spawn_at_x(-1.0))
	for id in stale:
		assert_eq(pool.slot_of(id), -1)
	assert_true(pool.is_alive(live))
	assert_eq(stale.size(), 50)
	# All 50 ids are distinct even though only one handle was ever in play.
	var distinct := {}
	for id in stale:
		distinct[id] = true
	assert_eq(distinct.size(), 50)


func test_flush_dead_invalidates_exactly_the_removed_ids() -> void:
	var ids: Array[int] = []
	for i in 8:
		ids.append(pool.id_of(_spawn_at_x(float(i))))
	for i: int in [1, 4, 6]:
		pool.mark_dead(i)
	assert_false(pool.is_alive(ids[1]), "marked dead is no longer alive")
	assert_eq(pool.slot_of(ids[1]), 1, "but it still has a slot until flushed")
	pool.flush_dead()
	for i in 8:
		var removed: bool = i in [1, 4, 6]
		assert_eq(pool.is_alive(ids[i]), not removed, "id %d" % i)
		if not removed:
			assert_eq(pool.pos[pool.slot_of(ids[i])].x, float(i), "id %d still points at its own bullet" % i)


func test_clear_invalidates_all_ids_and_frees_all_handles() -> void:
	var ids: Array[int] = []
	for i in 8:
		ids.append(pool.id_of(_spawn_at_x(float(i))))
	pool.clear()
	for id in ids:
		assert_false(pool.is_alive(id))
	for i in 8:
		assert_ne(_spawn_at_x(float(i)), -1)
	for id in ids:
		assert_eq(pool.slot_of(id), -1, "pre-clear ids stay stale after refilling")


func test_invalid_ids_resolve_to_no_bullet() -> void:
	_spawn_at_x(0.0)
	assert_eq(pool.slot_of(-1), -1)
	assert_eq(pool.slot_of(0), -1)
	assert_eq(pool.slot_of(123456789), -1)
	assert_eq(pool.slot_of((1 << 32) | 9999), -1, "handle out of range")
	assert_false(pool.is_alive(-1))


func test_handle_table_survives_random_churn() -> void:
	pool = BulletPool.new(64)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var live := {}  # id -> x it was spawned with
	var dead: Array[int] = []
	for step in 2000:
		if pool.count < 64 and (pool.count == 0 or rng.randf() < 0.55):
			var x := float(step)
			var id := pool.id_of(_spawn_at_x(x))
			assert_false(live.has(id))
			live[id] = x
		else:
			var slot := rng.randi_range(0, pool.count - 1)
			var id := pool.id_of(slot)
			pool.despawn(slot)
			live.erase(id)
			dead.append(id)
	assert_eq(pool.count, live.size())
	for id: int in live:
		assert_true(pool.is_alive(id))
		var spawned_x: float = live[id]
		assert_eq(pool.pos[pool.slot_of(id)].x, spawned_x)
	for id in dead:
		if not live.has(id):
			assert_false(pool.is_alive(id))


# --- user slot -------------------------------------------------------------------

func test_user_defaults_to_null_and_comes_from_request() -> void:
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0)
	assert_true(_user_is(0, null))
	var r := ShotRequest.new()
	r.user = {"phase": 2.5, "tag": "wave"}
	pool.spawn(r)
	assert_true(_user_is(1, {"phase": 2.5, "tag": "wave"}))
	assert_eq(pool.user.size(), 8, "user array is parallel to the pool and never grows")


func test_user_moves_with_its_bullet_on_swap_remove() -> void:
	for i in 4:
		var r := ShotRequest.new()
		r.position = Vector2(float(i), 0)
		r.user = "state%d" % i
		pool.spawn(r)
	var id3 := pool.id_of(3)
	pool.despawn(0)
	var slot := pool.slot_of(id3)
	assert_eq(slot, 0)
	assert_true(_user_is(slot, "state3"), "user value travelled with its bullet")
	assert_true(_user_is(1, "state1"))
	assert_true(_user_is(2, "state2"))


func test_user_is_cleared_when_bullet_despawns() -> void:
	var r := ShotRequest.new()
	r.user = [1, 2, 3]
	pool.spawn(r)
	pool.spawn(r)
	pool.despawn(1)
	assert_true(_user_is(1, null), "vacated tail slot is null")
	pool.mark_dead(0)
	pool.flush_dead()
	assert_true(_user_is(0, null))
	assert_true(_user_is(1, null))


func test_respawned_slot_does_not_inherit_old_user_value() -> void:
	var r := ShotRequest.new()
	r.user = "old"
	pool.spawn(r)
	pool.despawn(0)
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0)
	assert_true(_user_is(0, null))


func test_clear_nulls_user_values() -> void:
	var r := ShotRequest.new()
	r.user = "x"
	for i in 3:
		pool.spawn(r)
	pool.clear()
	for i in 8:
		assert_true(_user_is(i, null))


func test_user_slot_swap_remove_with_flush_of_many() -> void:
	for i in 8:
		var r := ShotRequest.new()
		r.position = Vector2(float(i), 0)
		r.user = i
		pool.spawn(r)
	for i: int in [0, 2, 5, 7]:
		pool.mark_dead(i)
	pool.flush_dead()
	assert_eq(pool.count, 4)
	for i in pool.count:
		assert_true(_user_is(i, int(pool.pos[i].x)), "user value matches its bullet at slot %d" % i)
	for i in range(pool.count, 8):
		assert_true(_user_is(i, null))
