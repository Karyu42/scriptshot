extends GutTest
## BulletManager integration: hooks, hurtbox collision, emitter interface.
## Runs the manager with auto_step off and rendering off so ticks are explicit.

const DT := 1.0 / 60.0

var manager: BulletManager


class RecordingBehavior:
	extends BulletBehavior
	var log: Array[String] = []
	var despawn_reasons: Array[int] = []

	func on_spawn(_pool: BulletPool, _index: int) -> void:
		log.append("spawn")

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		log.append("update")
		pool.param_a[index] += 1.0

	func on_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
		log.append("hit")

	func on_despawn(_pool: BulletPool, _index: int, reason: int) -> void:
		log.append("despawn")
		despawn_reasons.append(reason)


func before_each() -> void:
	manager = BulletManager.new()
	manager.capacity = 256
	manager.world_bounds = Rect2(-500, -500, 1000, 1000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _hurtbox(at: Vector2, layer: int = Layers.ENEMY, r: float = 20.0) -> Hurtbox:
	var hb := Hurtbox.new()
	hb.radius = r
	hb.layer = layer
	hb.position = at
	add_child_autofree(hb)
	return hb


func test_emitter_interface_spawns_bullets() -> void:
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 100.0)
	assert_true(manager.emitter.request_shot(req))
	assert_eq(manager.emitter.get_bullet_count(), 1)
	assert_eq(manager.emitter.get_capacity(), 256)


func test_request_shots_counts_accepted() -> void:
	manager.capacity = 3
	manager.pool = BulletPool.new(3)
	var reqs: Array = []
	for i in 5:
		reqs.append(ShotRequest.polar(Vector2.ZERO, 0.0, 10.0))
	assert_eq(manager.emitter.request_shots(reqs), 3)
	assert_eq(manager.pool.dropped_total, 2)


func test_request_object_can_be_reused_without_aliasing() -> void:
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 100.0)
	manager.emitter.request_shot(req)
	req.position = Vector2(50, 50)
	req.velocity = Vector2(0, 100)
	manager.emitter.request_shot(req)
	assert_eq(manager.pool.pos[0], Vector2.ZERO)
	assert_eq(manager.pool.vel[0], Vector2(100, 0))
	assert_eq(manager.pool.pos[1], Vector2(50, 50))


func test_step_moves_bullets_and_expires_them() -> void:
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 60.0)
	req.lifetime = 0.5
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_almost_eq(manager.pool.pos[0].x, 1.0, 0.001)
	for i in 40:
		manager.step(DT)
	assert_eq(manager.pool.count, 0)


func test_bullet_hits_hurtbox_once_and_despawns() -> void:
	var hb := _hurtbox(Vector2(100, 0))
	watch_signals(hb)
	var req := ShotRequest.polar(Vector2(90, 0), 0.0, 0.0)
	req.damage = 3.0
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_signal_emit_count(hb, "hit", 1)
	assert_signal_emitted_with_parameters(hb, "hit", [3.0, Vector2(90, 0), Vector2.ZERO])
	assert_eq(manager.pool.count, 0)


func test_bullet_ignores_hurtbox_on_other_layer() -> void:
	var hb := _hurtbox(Vector2(100, 0), Layers.PLAYER)
	watch_signals(hb)
	var req := ShotRequest.polar(Vector2(100, 0), 0.0, 0.0)
	req.hit_mask = Layers.ENEMY
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_signal_not_emitted(hb, "hit")
	assert_eq(manager.pool.count, 1)


func test_inactive_hurtbox_is_not_hit() -> void:
	var hb := _hurtbox(Vector2(0, 0))
	hb.active = false
	watch_signals(hb)
	manager.emitter.request_shot(ShotRequest.polar(Vector2.ZERO, 0.0, 0.0))
	manager.step(DT)
	assert_signal_not_emitted(hb, "hit")


func test_piercing_bullet_passes_through_and_hits_target_once() -> void:
	var hb := _hurtbox(Vector2(0, 0), Layers.ENEMY, 20.0)
	watch_signals(hb)
	var req := ShotRequest.polar(Vector2(-30, 0), 0.0, 300.0)
	req.pierce = 1
	manager.emitter.request_shot(req)
	for i in 20:
		manager.step(DT)
	assert_signal_emit_count(hb, "hit", 1, "one hit while overlapping for several ticks")
	assert_eq(manager.pool.count, 1, "bullet survived (pierce)")
	assert_eq(manager.pool.pierce[0], 0)


func test_hooks_run_in_order_and_receive_despawn_reason() -> void:
	var b := RecordingBehavior.new()
	var id := manager.emitter.register_behavior(b)
	assert_eq(id, 1)
	assert_eq(b.emitter, manager.emitter, "behaviour gets the emitter to spawn children")
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	req.behavior_id = id
	req.lifetime = 3.5 * DT
	manager.emitter.request_shot(req)
	for i in 4:
		manager.step(DT)
	assert_eq(b.log, ["spawn", "update", "update", "update", "despawn"])
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.LIFETIME])
	assert_eq(manager.pool.count, 0)


func test_hit_hook_runs_before_despawn_hook_with_hit_reason() -> void:
	_hurtbox(Vector2(0, 0))
	var b := RecordingBehavior.new()
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	req.behavior_id = manager.emitter.register_behavior(b)
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_eq(b.log, ["spawn", "update", "hit", "despawn"])
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.HIT])


func test_behaviour_can_mutate_bullet_state() -> void:
	var b := RecordingBehavior.new()
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	req.behavior_id = manager.emitter.register_behavior(b)
	manager.emitter.request_shot(req)
	manager.step(DT)
	manager.step(DT)
	assert_eq(manager.pool.param_a[0], 2.0)


func test_behaviour_can_spawn_child_bullets_on_despawn() -> void:
	var splitter := SplitOnDespawn.new()
	var req := ShotRequest.polar(Vector2(10, 10), 0.0, 0.0)
	req.lifetime = DT * 0.5
	req.behavior_id = manager.emitter.register_behavior(splitter)
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_eq(manager.pool.count, 3, "parent removed, three children spawned")
	assert_eq(manager.pool.pos[0], Vector2(10, 10))


class SplitOnDespawn:
	extends BulletBehavior
	func on_despawn(pool: BulletPool, index: int, _reason: int) -> void:
		for k in 3:
			emitter.request_shot(ShotRequest.polar(pool.pos[index], k, 10.0))


func test_unknown_behavior_id_falls_back_to_plain_bullet() -> void:
	var req := ShotRequest.polar(Vector2.ZERO, 0.0, 10.0)
	req.behavior_id = 42
	manager.emitter.request_shot(req)
	assert_eq(manager.pool.behavior[0], 0)
	manager.step(DT)
	assert_eq(manager.pool.count, 1)


func test_clear_bullets_empties_pool() -> void:
	for i in 10:
		manager.emitter.request_shot(ShotRequest.polar(Vector2.ZERO, 0.0, 10.0))
	manager.clear_bullets()
	assert_eq(manager.pool.count, 0)


# --- walls (world layer) ------------------------------------------------------

class SnapshotBehavior:
	extends BulletBehavior
	var despawn_positions: Array[Vector2] = []
	var despawn_reasons: Array[int] = []
	var hits := 0

	func on_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
		hits += 1

	func on_despawn(pool: BulletPool, index: int, reason: int) -> void:
		despawn_positions.append(pool.pos[index])
		despawn_reasons.append(reason)


## A bullet that moves `step_px` per tick along +x from `from`.
func _shot(from: Vector2, step_px: float, behavior_id: int = 0) -> ShotRequest:
	var req := ShotRequest.polar(from, 0.0, step_px / DT)
	req.radius = 4.0
	req.behavior_id = behavior_id
	return req


func test_bullet_despawns_at_a_wall_with_reason_wall_and_hooks_fire() -> void:
	manager.add_wall(Rect2(100, -50, 20, 100))
	var b := SnapshotBehavior.new()
	manager.emitter.request_shot(_shot(Vector2(90, 0), 14.0, manager.emitter.register_behavior(b)))
	manager.step(DT)
	assert_eq(manager.pool.count, 0)
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.WALL])
	assert_almost_eq(b.despawn_positions[0].x, 96.0, 0.01, "on_despawn sees the impact point")
	assert_eq(manager.last_wall_hit_count, 1)


func test_wall_opt_out_flies_through() -> void:
	manager.add_wall(Rect2(100, -50, 20, 100))
	var req := _shot(Vector2(90, 0), 14.0)
	req.collide_world = false
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_eq(manager.pool.count, 1)
	assert_almost_eq(manager.pool.pos[0].x, 104.0, 0.01)


func test_fast_bullet_does_not_tunnel_through_a_thin_wall() -> void:
	manager.add_wall(Rect2(0, -100, 2, 200))
	var b := SnapshotBehavior.new()
	manager.emitter.request_shot(_shot(Vector2(-300, 0), 600.0, manager.emitter.register_behavior(b)))
	manager.step(DT)
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.WALL])
	assert_almost_eq(b.despawn_positions[0].x, -4.0, 0.01)


func test_fast_bullet_does_not_tunnel_through_a_hurtbox() -> void:
	var hb := _hurtbox(Vector2(0, 0), Layers.ENEMY, 12.0)
	watch_signals(hb)
	manager.emitter.request_shot(_shot(Vector2(-300, 0), 600.0))
	manager.step(DT)
	assert_signal_emit_count(hb, "hit", 1)
	assert_eq(manager.pool.count, 0)
	var args: Array = get_signal_parameters(hb, "hit")
	var hit_position: Vector2 = args[1]
	assert_almost_eq(hit_position.x, -16.0, 0.01, "hit position is where the bullet touched the target")


func test_hurtbox_in_front_of_a_wall_is_hit_and_wall_is_not_reached() -> void:
	manager.add_wall(Rect2(200, -50, 20, 100))
	var hb := _hurtbox(Vector2(100, 0), Layers.ENEMY, 12.0)
	watch_signals(hb)
	var b := SnapshotBehavior.new()
	manager.emitter.request_shot(_shot(Vector2(0, 0), 300.0, manager.emitter.register_behavior(b)))
	manager.step(DT)
	assert_signal_emit_count(hb, "hit", 1)
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.HIT], "first reason wins")


func test_wall_in_front_of_a_hurtbox_shields_it() -> void:
	manager.add_wall(Rect2(50, -50, 20, 100))
	var hb := _hurtbox(Vector2(100, 0), Layers.ENEMY, 12.0)
	watch_signals(hb)
	var b := SnapshotBehavior.new()
	manager.emitter.request_shot(_shot(Vector2(0, 0), 300.0, manager.emitter.register_behavior(b)))
	manager.step(DT)
	assert_signal_not_emitted(hb, "hit")
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.WALL])


func test_piercing_bullet_still_stops_at_a_wall() -> void:
	manager.add_wall(Rect2(200, -50, 20, 100))
	var hb := _hurtbox(Vector2(100, 0), Layers.ENEMY, 12.0)
	watch_signals(hb)
	var b := SnapshotBehavior.new()
	var req := _shot(Vector2(0, 0), 300.0, manager.emitter.register_behavior(b))
	req.pierce = 1
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_signal_emit_count(hb, "hit", 1)
	assert_eq(b.hits, 1)
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.WALL])


func test_walls_are_collected_from_world_layer_bodies_in_the_group() -> void:
	var wall := StaticBody2D.new()
	wall.collision_layer = Layers.WORLD
	wall.position = Vector2(200, 100)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(20, 100)
	shape.shape = rect
	wall.add_child(shape)
	wall.add_to_group(manager.walls_group)
	add_child_autofree(wall)
	var not_world := StaticBody2D.new()
	not_world.collision_layer = Layers.PLAYER
	var other := CollisionShape2D.new()
	other.shape = rect
	not_world.add_child(other)
	not_world.add_to_group(manager.walls_group)
	add_child_autofree(not_world)
	assert_eq(manager.collect_walls(), 1, "only the body on the world layer counts")
	assert_eq(manager.walls.wall_count, 1)
	assert_eq(manager.walls.walls[0], Rect2(190, 50, 20, 100))
	manager.emitter.request_shot(_shot(Vector2(170, 100), 24.0))
	manager.step(DT)
	assert_eq(manager.pool.count, 0, "the collected wall stops bullets")


func test_world_walls_in_the_main_scene_stop_bullets() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child_autofree(main)
	var bullets := main.get_node("BulletManager") as BulletManager
	assert_gt(bullets.walls.wall_count, 4, "border walls plus some obstacles")
	for k in bullets.walls.wall_count:
		assert_true(bullets.world_bounds.intersects(bullets.walls.walls[k]), "wall %d is inside the bullet area" % k)


# --- hook guarantees ----------------------------------------------------------

class Counting:
	extends BulletBehavior
	var updates: Dictionary = {}
	var hit_calls := 0
	var despawn_calls := 0
	var despawn_reasons: Array[int] = []
	## Slot to kill from inside the first on_update call.
	var kill_from_update := -1
	var kill_from_hit := -1
	var kill_from_despawn := -1

	func updates_of(slot: int) -> int:
		var n: int = updates.get(slot, 0)
		return n

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		var seen: int = updates.get(index, 0)
		updates[index] = seen + 1
		if kill_from_update >= 0 and index == 0:
			pool.mark_dead(kill_from_update)

	func on_hit(pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
		hit_calls += 1
		if kill_from_hit >= 0:
			pool.mark_dead(kill_from_hit)

	func on_despawn(pool: BulletPool, index: int, reason: int) -> void:
		despawn_calls += 1
		despawn_reasons.append(reason)
		if kill_from_despawn >= 0 and index == 0:
			pool.mark_dead(kill_from_despawn)


func test_a_bullet_killed_by_a_hook_gets_no_update_and_one_despawn_call() -> void:
	var b := Counting.new()
	b.kill_from_update = 1
	var id := manager.emitter.register_behavior(b)
	for k in 3:
		manager.emitter.request_shot(_shot(Vector2(float(k) * 50.0, 0), 1.0, id))
	manager.step(DT)
	assert_eq(b.updates_of(0), 1)
	assert_eq(b.updates_of(1), 0, "slot 1 died before its update ran")
	assert_eq(b.updates_of(2), 1)
	assert_eq(b.despawn_calls, 1)
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.MANUAL])
	assert_eq(manager.pool.count, 2)


func test_hit_hook_killing_another_bullet_prevents_its_hit() -> void:
	var hb := _hurtbox(Vector2(0, 0))
	watch_signals(hb)
	var b := Counting.new()
	b.kill_from_hit = 1
	var id := manager.emitter.register_behavior(b)
	manager.emitter.request_shot(_shot(Vector2(0, 0), 0.0, id))
	manager.emitter.request_shot(_shot(Vector2(2, 0), 0.0, id))
	manager.step(DT)
	assert_eq(b.hit_calls, 1, "the bullet killed by the first hit's hook does not hit")
	assert_signal_emit_count(hb, "hit", 1)
	assert_eq(b.despawn_calls, 2, "both bullets despawn exactly once")


func test_despawn_hook_marking_another_bullet_announces_it_exactly_once() -> void:
	var b := Counting.new()
	b.kill_from_despawn = 1
	var id := manager.emitter.register_behavior(b)
	var first := _shot(Vector2(0, 0), 0.0, id)
	first.lifetime = DT * 0.5
	manager.emitter.request_shot(first)
	manager.emitter.request_shot(_shot(Vector2(50, 0), 0.0, id))
	manager.emitter.request_shot(_shot(Vector2(100, 0), 0.0, id))
	manager.step(DT)
	assert_eq(b.despawn_calls, 2, "slot 0 expired; its hook killed slot 1, which is announced once")
	assert_eq(b.despawn_reasons, [BulletPool.DespawnReason.LIFETIME, BulletPool.DespawnReason.MANUAL])
	assert_eq(manager.pool.count, 1)


func test_bullets_marked_dead_before_step_are_not_announced_twice() -> void:
	var b := Counting.new()
	var id := manager.emitter.register_behavior(b)
	manager.emitter.request_shot(_shot(Vector2(0, 0), 0.0, id))
	manager.pool.mark_dead(0)
	manager.step(DT)
	manager.step(DT)
	assert_eq(b.despawn_calls, 1)
	assert_eq(manager.pool.count, 0)


# --- scheduling ----------------------------------------------------------------

class Spawner:
	extends Node
	var manager: BulletManager
	var spawned := false

	func _physics_process(_delta: float) -> void:
		if not spawned:
			spawned = true
			manager.emitter.request_shot(ShotRequest.polar(Vector2.ZERO, 0.0, 600.0))


class Probe:
	extends Node
	var manager: BulletManager
	var seen := false
	var age_seen := -1.0

	func _init() -> void:
		process_physics_priority = 1000

	func _physics_process(_delta: float) -> void:
		if not seen and manager.pool.count > 0:
			seen = true
			age_seen = manager.pool.age[0]


func _run_spawn_order_scenario(manager_priority: int) -> Probe:
	var live := BulletManager.new()
	live.capacity = 16
	live.render_enabled = false
	live.process_physics_priority = manager_priority
	add_child_autofree(live)
	var spawner := Spawner.new()
	spawner.manager = live
	add_child_autofree(spawner)  # after the manager in tree order
	var probe := Probe.new()
	probe.manager = live
	add_child_autofree(probe)
	for k in 4:
		await get_tree().physics_frame
	return probe


func test_manager_defaults_to_a_late_physics_priority() -> void:
	assert_eq(manager.process_physics_priority, BulletManager.PHYSICS_PRIORITY)
	assert_gt(BulletManager.PHYSICS_PRIORITY, 0, "later than default-priority nodes")


func test_bullets_spawned_earlier_in_the_tick_move_on_that_same_tick() -> void:
	var probe := await _run_spawn_order_scenario(BulletManager.PHYSICS_PRIORITY)
	assert_true(probe.seen)
	assert_almost_eq(probe.age_seen, 1.0 / 60.0, 0.00001, "integrated once on the tick it was spawned")


func test_without_the_priority_a_bullet_would_wait_a_tick() -> void:
	var probe := await _run_spawn_order_scenario(0)
	assert_true(probe.seen)
	assert_eq(probe.age_seen, 0.0, "control: manager ran before the spawner on the spawn tick")


# --- no per-tick allocations ----------------------------------------------------

func test_scratch_buffers_keep_their_size_across_busy_ticks() -> void:
	manager.add_wall(Rect2(-200, -400, 20, 800))
	for k in 6:
		_hurtbox(Vector2(float(k) * 60.0 - 100.0, 40.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var b := Counting.new()
	var id := manager.emitter.register_behavior(b)
	var req := ShotRequest.new()
	for tick in 20:
		req.reset()
		req.position = Vector2(rng.randf_range(-150.0, 150.0), rng.randf_range(-100.0, 100.0))
		req.velocity = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(100.0, 3000.0)
		req.lifetime = 0.5
		req.behavior_id = id if (tick % 2) == 0 else 0
		for k in 10:
			manager.emitter.request_shot(req)
		manager.step(DT)
	var sizes: Array[int] = [manager.pool.pending.size(), manager.pool.hooked.size(), manager.grid.hit_bullets.size(),
		manager.grid.target_pos.size(), manager.walls.hit_bullets.size()]
	for tick in 60:
		req.reset()
		req.position = Vector2(rng.randf_range(-150.0, 150.0), rng.randf_range(-100.0, 100.0))
		req.velocity = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(100.0, 3000.0)
		req.lifetime = 0.5
		for k in 10:
			manager.emitter.request_shot(req)
		manager.step(DT)
		var now: Array[int] = [manager.pool.pending.size(), manager.pool.hooked.size(), manager.grid.hit_bullets.size(),
			manager.grid.target_pos.size(), manager.walls.hit_bullets.size()]
		assert_eq(now, sizes, "tick %d" % tick)
	assert_eq(sizes[0], manager.pool.capacity)
	assert_eq(sizes[1], manager.pool.capacity)


func test_hurtbox_registry_tracks_the_tree_without_group_lookups() -> void:
	var before := Hurtbox.registry.size()
	var hb := _hurtbox(Vector2.ZERO)
	assert_eq(Hurtbox.registry.size(), before + 1)
	assert_true(hb in Hurtbox.registry)
	hb.get_parent().remove_child(hb)
	assert_eq(Hurtbox.registry.size(), before)
	hb.free()


# --- stable ids + user slot through the emitter -----------------------------------

func test_request_shot_id_returns_stable_id_and_request_shot_stays_bool() -> void:
	var id := manager.emitter.request_shot_id(ShotRequest.polar(Vector2.ZERO, 0.0, 10.0))
	assert_gt(id, 0)
	assert_true(manager.emitter.is_bullet_alive(id))
	assert_true(manager.emitter.request_shot(ShotRequest.polar(Vector2.ZERO, 0.0, 10.0)))
	assert_eq(manager.pool.count, 2)


func test_request_shot_id_is_minus_one_when_full() -> void:
	manager.pool = BulletPool.new(1)
	assert_gt(manager.emitter.request_shot_id(ShotRequest.new()), 0)
	assert_eq(manager.emitter.request_shot_id(ShotRequest.new()), -1)
	assert_false(manager.emitter.request_shot(ShotRequest.new()))


func test_id_survives_other_bullets_despawning_and_dies_with_its_bullet() -> void:
	var short := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	short.lifetime = DT * 0.5
	var keeper := ShotRequest.polar(Vector2(7, 0), 0.0, 0.0)
	keeper.lifetime = 10.0
	manager.emitter.request_shot_id(short)
	var keep_id := manager.emitter.request_shot_id(keeper)
	var short_id := manager.emitter.request_shot_id(short)
	manager.step(DT)
	assert_true(manager.emitter.is_bullet_alive(keep_id))
	assert_false(manager.emitter.is_bullet_alive(short_id))
	assert_eq(manager.pool.pos[manager.pool.slot_of(keep_id)].x, 7.0)


func test_user_state_is_visible_to_hooks_and_travels_with_the_bullet() -> void:
	var b := UserCounter.new()
	var bid := manager.emitter.register_behavior(b)
	var dying := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	dying.lifetime = DT * 0.5
	manager.emitter.request_shot_id(dying)  # slot 0, dies first tick
	var req := ShotRequest.polar(Vector2(3, 0), 0.0, 0.0)
	req.behavior_id = bid
	req.lifetime = 10.0
	req.user = {"count": 0}
	var id := manager.emitter.request_shot_id(req)
	for i in 3:
		manager.step(DT)
	var slot := manager.pool.slot_of(id)
	assert_eq(slot, 0, "survivor moved into the freed slot")
	assert_eq(manager.pool.user[slot]["count"], 3)


class UserCounter:
	extends BulletBehavior
	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		pool.user[index]["count"] += 1
