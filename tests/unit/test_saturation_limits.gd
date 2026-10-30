extends GutTest
## Saturation model: logical cap, enemy reserve, per-owner counters, per-owner and
## per-limit drop counts, DespawnReason.INVALID.

const DT := 1.0 / 60.0

var pool: BulletPool


func before_each() -> void:
	pool = BulletPool.new(64)


func _req(owner_layer: int = Layers.PLAYER) -> ShotRequest:
	var r := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	r.owner_layer = owner_layer
	r.lifetime = 100.0
	return r


func _fill(n: int, owner_layer: int) -> int:
	var accepted := 0
	for i in n:
		if pool.spawn(_req(owner_layer)) >= 0:
			accepted += 1
	return accepted


# --- defaults ----------------------------------------------------------------

func test_bare_pool_has_no_extra_limits() -> void:
	assert_eq(pool.logical_cap, 64)
	assert_eq(pool.enemy_reserve, 0)
	assert_eq(_fill(64, Layers.PLAYER), 64)
	assert_eq(pool.spawn(_req(Layers.PLAYER)), -1)
	assert_true(pool.is_full())


func test_manager_defaults_are_10k_cap_and_20_percent_reserve() -> void:
	var m := BulletManager.new()
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	assert_eq(m.pool.capacity, 16384)
	assert_eq(m.emitter.get_logical_cap(), 10000)
	assert_eq(m.emitter.get_enemy_reserve(), 2000)


func test_logical_cap_is_clamped_to_the_physical_capacity() -> void:
	var m := BulletManager.new()
	m.capacity = 100
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	assert_eq(m.emitter.get_logical_cap(), 100, "default 10000 cannot exceed the 100 slots of memory")
	assert_eq(m.emitter.get_enemy_reserve(), 20)
	m.set_bullet_limits(500, 5)
	assert_eq(m.emitter.get_logical_cap(), 100)
	assert_eq(m.emitter.get_enemy_reserve(), 5)
	m.set_bullet_limits(40, 1000)
	assert_eq(m.emitter.get_logical_cap(), 40)
	assert_eq(m.emitter.get_enemy_reserve(), 40, "the reserve cannot exceed the cap")
	m.set_bullet_limits(-5, -5)
	assert_eq(m.emitter.get_logical_cap(), 0)


# --- logical cap ---------------------------------------------------------------

func test_logical_cap_limits_the_total_below_the_physical_capacity() -> void:
	pool.set_limits(10, 0)
	assert_eq(_fill(20, Layers.ENEMY), 10)
	assert_eq(pool.count, 10)
	assert_true(pool.is_full())
	assert_eq(pool.dropped_total, 10)
	assert_eq(pool.dropped_by_limit[BulletPool.DropLimit.LOGICAL_CAP], 10)
	assert_eq(pool.dropped_by_limit[BulletPool.DropLimit.ENEMY_RESERVE], 0)


func test_lowering_the_cap_never_removes_bullets_but_refuses_new_ones() -> void:
	_fill(30, Layers.PLAYER)
	pool.set_limits(10, 0)
	assert_eq(pool.count, 30)
	assert_eq(pool.spawn(_req(Layers.PLAYER)), -1)
	assert_eq(pool.spawn(_req(Layers.ENEMY)), -1)
	assert_eq(pool.headroom(Layers.PLAYER), 0)
	for k in 21:
		pool.despawn(0)
	assert_eq(pool.count, 9)
	assert_true(pool.spawn(_req(Layers.PLAYER)) >= 0)


# --- enemy reserve -------------------------------------------------------------

func test_player_bullets_cannot_use_the_enemy_reserve() -> void:
	pool.set_limits(20, 5)
	assert_eq(_fill(50, Layers.PLAYER), 15, "cap 20 minus reserve 5")
	assert_true(pool.can_spawn(Layers.ENEMY))
	assert_false(pool.can_spawn(Layers.PLAYER))
	assert_eq(pool.headroom(Layers.PLAYER), 0)
	assert_eq(pool.headroom(Layers.ENEMY), 5)


func test_enemies_can_still_shoot_when_the_player_flooded_the_pool() -> void:
	pool.set_limits(20, 5)
	_fill(100, Layers.PLAYER)
	assert_eq(_fill(100, Layers.ENEMY), 5, "exactly the reserve is left for enemies")
	assert_eq(pool.count, 20)
	assert_eq(pool.owner_count(Layers.PLAYER), 15)
	assert_eq(pool.owner_count(Layers.ENEMY), 5)
	assert_eq(pool.spawn(_req(Layers.ENEMY)), -1, "the cap still holds for enemies")


func test_unowned_bullets_do_not_get_the_reserve_either() -> void:
	pool.set_limits(10, 4)
	assert_eq(_fill(20, 0), 6)
	assert_eq(pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0), -1)
	assert_eq(pool.dropped_by_owner[BulletPool.OWNER_NONE], 15)


func test_enemies_that_filled_the_pool_leave_the_player_no_room() -> void:
	pool.set_limits(20, 5)
	_fill(18, Layers.ENEMY)
	assert_false(pool.can_spawn(Layers.PLAYER), "the player's share is capped by the total, not by its own count")
	assert_true(pool.can_spawn(Layers.ENEMY))


func test_boss_and_enemy_bullets_share_the_enemy_slot() -> void:
	pool.set_limits(10, 10)
	# Bosses fire as Layers.ENEMY; an owner mask with extra bits still counts as enemy.
	assert_true(pool.spawn(_req(Layers.ENEMY | Layers.ENEMY_BULLET)) >= 0)
	assert_eq(pool.owner_counts[BulletPool.OWNER_ENEMY], 1)
	assert_eq(pool.spawn(_req(Layers.PLAYER)), -1, "reserve == cap leaves players nothing")


func test_reserve_is_released_as_soon_as_headroom_returns() -> void:
	pool.set_limits(10, 3)
	_fill(10, Layers.PLAYER)
	assert_eq(pool.count, 7)
	pool.despawn(0)
	assert_true(pool.can_spawn(Layers.PLAYER))


# --- drop accounting -----------------------------------------------------------

func test_drops_are_counted_per_owner_and_per_limit() -> void:
	pool.set_limits(10, 4)
	_fill(6, Layers.PLAYER)  # fills the player's share (10 - 4)
	_fill(3, Layers.PLAYER)  # 3 reserve drops
	_fill(4, Layers.ENEMY)   # fills the reserve
	_fill(2, Layers.ENEMY)   # 2 cap drops
	_fill(1, Layers.PLAYER)  # now the cap is hit: a cap drop, not a reserve drop
	assert_eq(pool.dropped_total, 6)
	assert_eq(pool.dropped_by_owner[BulletPool.OWNER_PLAYER], 4)
	assert_eq(pool.dropped_by_owner[BulletPool.OWNER_ENEMY], 2)
	assert_eq(pool.dropped_by_limit[BulletPool.DropLimit.ENEMY_RESERVE], 3)
	assert_eq(pool.dropped_by_limit[BulletPool.DropLimit.LOGICAL_CAP], 3)
	assert_eq(pool.dropped_for(Layers.PLAYER), 4)
	assert_eq(pool.dropped_for(Layers.ENEMY), 2)
	assert_eq(pool.dropped_for(0), 0)


func test_drop_breakdowns_always_sum_to_the_total() -> void:
	pool.set_limits(12, 5)
	for k in 200:
		pool.spawn(_req(Layers.PLAYER if k % 3 != 0 else Layers.ENEMY))
		if k % 7 == 0 and pool.count > 0:
			pool.despawn(pool.count / 2)
	var by_owner := pool.dropped_by_owner[0] + pool.dropped_by_owner[1] + pool.dropped_by_owner[2]
	var by_limit := pool.dropped_by_limit[0] + pool.dropped_by_limit[1]
	assert_gt(pool.dropped_total, 0)
	assert_eq(by_owner, pool.dropped_total)
	assert_eq(by_limit, pool.dropped_total)


func test_emitter_reports_drops_by_owner_and_limit() -> void:
	var m := _manager(40, 10, 5)
	for k in 12:
		m.emitter.request_shot(_req(Layers.PLAYER))
	for k in 5:
		m.emitter.request_shot(_req(Layers.ENEMY))
	for k in 2:
		m.emitter.request_shot(_req(Layers.ENEMY))
	assert_eq(m.emitter.get_dropped_count(), 7 + 2)
	assert_eq(m.emitter.get_dropped_count_by_owner(Layers.PLAYER), 7)
	assert_eq(m.emitter.get_dropped_count_by_owner(Layers.ENEMY), 2)
	assert_eq(m.emitter.get_dropped_count_by_limit(BulletPool.DropLimit.ENEMY_RESERVE), 7)
	assert_eq(m.emitter.get_dropped_count_by_limit(BulletPool.DropLimit.LOGICAL_CAP), 2)
	assert_eq(m.emitter.get_dropped_count_by_limit(99), 0)


func _manager(capacity: int, cap: int, reserve: int) -> BulletManager:
	var m := BulletManager.new()
	m.capacity = capacity
	m.logical_cap = cap
	m.enemy_reserve = reserve
	m.world_bounds = Rect2(-500, -500, 1000, 1000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	return m


func test_is_saturated_depends_on_who_asks() -> void:
	var m := _manager(40, 10, 4)
	for k in 6:
		m.emitter.request_shot(_req(Layers.PLAYER))
	assert_true(m.emitter.is_saturated(), "default asker is the player: its share is full")
	assert_true(m.emitter.is_saturated(Layers.PLAYER))
	assert_false(m.emitter.is_saturated(Layers.ENEMY), "the reserve is still free for enemies")
	assert_eq(m.emitter.get_headroom(), 0)
	assert_eq(m.emitter.get_headroom(Layers.ENEMY), 4)
	assert_eq(m.emitter.get_dropped_count(), 0, "full is not the same as dropping")


func test_pool_saturated_signal_and_warning_report_the_limit() -> void:
	var m := _manager(40, 10, 4)
	watch_signals(m.emitter)
	for k in 8:
		m.emitter.request_shot(_req(Layers.PLAYER))
	m.step(DT)
	assert_signal_emit_count(m.emitter, "pool_saturated", 1)
	assert_signal_emitted_with_parameters(m.emitter, "pool_saturated", [2, 2])
	assert_eq(m.saturation_warnings_emitted, 1)
	# Enemies are not blocked by the player's drops.
	assert_true(m.emitter.request_shot(_req(Layers.ENEMY)))
	m.step(DT)
	assert_signal_emit_count(m.emitter, "pool_saturated", 1, "no new drops, no new signal")


func test_a_player_flood_cannot_starve_enemy_attacks_over_many_ticks() -> void:
	var m := _manager(200, 100, 30)
	var enemy_accepted := 0
	var enemy_asked := 0
	for tick in 120:
		for k in 40:
			m.emitter.request_shot(_req(Layers.PLAYER))
		for k in 3:
			enemy_asked += 1
			var shot := _req(Layers.ENEMY)
			shot.lifetime = 0.1  # ~6 ticks: 3 per tick stays far below the reserve
			if m.emitter.request_shot(shot):
				enemy_accepted += 1
		m.step(DT)
	assert_eq(enemy_accepted, enemy_asked, "every enemy shot was accepted while players flooded")
	assert_lte(m.pool.count, 100)
	assert_lte(m.emitter.get_owner_count(Layers.PLAYER), 70)


# --- per-owner counters ---------------------------------------------------------

func test_counters_follow_spawn_and_despawn() -> void:
	_fill(5, Layers.PLAYER)
	_fill(3, Layers.ENEMY)
	pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0)
	assert_eq(pool.owner_count(Layers.PLAYER), 5)
	assert_eq(pool.owner_count(Layers.ENEMY), 3)
	assert_eq(pool.owner_count(0), 1)
	pool.despawn(0)
	assert_eq(pool.owner_count(Layers.PLAYER), 4)
	assert_true(pool.counters_consistent())


func test_counters_survive_swap_remove_in_every_order() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var owners: Array[int] = [Layers.PLAYER, Layers.ENEMY, 0]
	for round in 20:
		pool.clear()
		for k in 40:
			pool.spawn(_req(owners[rng.randi() % 3]))
		while pool.count > 0:
			pool.despawn(rng.randi() % pool.count)
			assert_true(pool.counters_consistent(), "round %d, %d left" % [round, pool.count])
		assert_eq(pool.owner_counts, PackedInt32Array([0, 0, 0]))


func test_counters_survive_flush_dead() -> void:
	_fill(6, Layers.PLAYER)
	_fill(6, Layers.ENEMY)
	pool.mark_dead(0, BulletPool.DespawnReason.HIT)
	pool.mark_dead(7, BulletPool.DespawnReason.HIT)
	pool.mark_dead(11, BulletPool.DespawnReason.LIFETIME)
	assert_eq(pool.owner_count(Layers.ENEMY), 6, "marked dead bullets still hold their slot")
	pool.flush_dead()
	assert_eq(pool.owner_count(Layers.PLAYER), 5)
	assert_eq(pool.owner_count(Layers.ENEMY), 4)
	assert_true(pool.counters_consistent())


func test_reflect_moves_the_count_to_the_new_owner() -> void:
	var i := pool.spawn(_req(Layers.ENEMY))
	_fill(2, Layers.ENEMY)
	assert_true(pool.reflect(i, Layers.PLAYER))
	assert_eq(pool.owner_count(Layers.ENEMY), 2)
	assert_eq(pool.owner_count(Layers.PLAYER), 1)
	assert_true(pool.counters_consistent())


func test_refused_reflect_changes_no_counts() -> void:
	var i := pool.spawn(_req(Layers.ENEMY))
	assert_false(pool.reflect(i, Layers.ENEMY | Layers.WORLD | 1 << 9 | Layers.PLAYER_BULLET))
	assert_true(pool.reflect(i, Layers.PLAYER))
	assert_false(pool.reflect(i, Layers.ENEMY), "already reflected once")
	assert_eq(pool.owner_count(Layers.PLAYER), 1)
	assert_eq(pool.owner_count(Layers.ENEMY), 0)
	assert_true(pool.counters_consistent())


func test_reflecting_to_the_same_side_keeps_counts() -> void:
	var i := pool.spawn(_req(Layers.PLAYER))
	assert_true(pool.reflect(i, Layers.PLAYER))
	assert_eq(pool.owner_count(Layers.PLAYER), 1)
	assert_true(pool.counters_consistent())


func test_a_reflected_bullet_does_not_need_a_free_slot() -> void:
	pool.set_limits(10, 0)
	var i := pool.spawn(_req(Layers.ENEMY))
	_fill(9, Layers.PLAYER)
	assert_true(pool.is_full())
	assert_true(pool.reflect(i, Layers.PLAYER), "ownership changes in place")
	assert_eq(pool.count, 10)


func test_clear_resets_counters_but_keeps_drop_statistics() -> void:
	pool.set_limits(4, 0)
	_fill(10, Layers.PLAYER)
	pool.clear()
	assert_eq(pool.owner_counts, PackedInt32Array([0, 0, 0]))
	assert_eq(pool.dropped_total, 6)
	assert_eq(pool.dropped_by_owner[BulletPool.OWNER_PLAYER], 6)
	assert_true(pool.counters_consistent())


func test_recount_repairs_counters_after_direct_writes() -> void:
	var i := pool.spawn(_req(Layers.PLAYER))
	pool.owner_layer[i] = Layers.ENEMY  # bypasses reflect(): counters now stale
	assert_false(pool.counters_consistent())
	pool.recount_owners()
	assert_true(pool.counters_consistent())
	assert_eq(pool.owner_count(Layers.ENEMY), 1)


func test_counters_through_the_manager_with_hits_lifetimes_and_bounds() -> void:
	var m := _manager(64, 64, 0)
	var hb := Hurtbox.new()
	hb.radius = 20.0
	hb.position = Vector2(100, 0)
	add_child_autofree(hb)
	for k in 5:
		var r := ShotRequest.polar(Vector2.ZERO, 0.0, 6000.0)
		r.hit_mask = Layers.ENEMY
		m.emitter.request_shot(r)  # hits the target
	for k in 4:
		var r := ShotRequest.polar(Vector2(0, 100), 0.0, 10.0)
		r.owner_layer = Layers.ENEMY
		r.lifetime = 0.05
		m.emitter.request_shot(r)  # lifetime
	for k in 3:
		var r := ShotRequest.polar(Vector2(0, -100), PI, 60000.0)
		r.owner_layer = Layers.ENEMY
		m.emitter.request_shot(r)  # leaves the world bounds
	assert_eq(m.emitter.get_owner_count(Layers.PLAYER), 5)
	assert_eq(m.emitter.get_owner_count(Layers.ENEMY), 7)
	m.step(DT)
	assert_eq(m.emitter.get_owner_count(Layers.PLAYER), 0)
	assert_eq(m.emitter.get_owner_count(Layers.ENEMY), 4)
	for k in 6:
		m.step(DT)
	assert_eq(m.emitter.get_owner_count(Layers.ENEMY), 0)
	assert_eq(m.emitter.get_bullet_count(), 0)
	assert_true(m.pool.counters_consistent())


func test_manager_reflect_updates_emitter_counts() -> void:
	var m := _manager(64, 64, 0)
	var r := _req(Layers.ENEMY)
	var id := m.emitter.request_shot_id(r)
	assert_eq(m.emitter.get_owner_count(Layers.ENEMY), 1)
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER))
	assert_eq(m.emitter.get_owner_count(Layers.ENEMY), 0)
	assert_eq(m.emitter.get_owner_count(Layers.PLAYER), 1)


# --- DespawnReason.INVALID ---------------------------------------------------------

class ReasonLog:
	extends BulletBehavior
	var reasons: Array[int] = []

	func on_despawn(_pool: BulletPool, _index: int, reason: int) -> void:
		reasons.append(reason)


func test_despawn_reason_values_are_stable_and_invalid_is_appended() -> void:
	assert_eq(BulletPool.DespawnReason.LIFETIME, 0)
	assert_eq(BulletPool.DespawnReason.BOUNDS, 1)
	assert_eq(BulletPool.DespawnReason.HIT, 2)
	assert_eq(BulletPool.DespawnReason.MANUAL, 3)
	assert_eq(BulletPool.DespawnReason.CLEARED, 4)
	assert_eq(BulletPool.DespawnReason.WALL, 5)
	assert_eq(BulletPool.DespawnReason.INVALID, 6)


func test_invalid_reason_reaches_on_despawn() -> void:
	var m := _manager(64, 64, 0)
	var log := ReasonLog.new()
	var r := _req()
	r.behavior_id = m.register_behavior(log)
	m.spawn(r)
	m.pool.mark_dead(0, BulletPool.DespawnReason.INVALID)
	m.step(DT)
	assert_eq(log.reasons, [BulletPool.DespawnReason.INVALID] as Array[int])
	assert_eq(m.pool.count, 0)


func test_first_reason_wins_over_invalid() -> void:
	pool.spawn(_req())
	pool.mark_dead(0, BulletPool.DespawnReason.HIT)
	pool.mark_dead(0, BulletPool.DespawnReason.INVALID)
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.HIT + 1)
