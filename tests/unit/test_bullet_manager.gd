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
