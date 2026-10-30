extends GutTest
## Opt-in per-bullet hit veto (ShotRequest.can_hit_veto -> BulletBehavior.can_hit).

const DT := 1.0 / 60.0

var manager: BulletManager


class Vetoer:
	extends BulletBehavior
	## Hurtbox instance ids that are refused; everything else is allowed.
	var refuse: Array[int] = []
	var refuse_all := false
	var asked := 0
	var hits := 0
	var update_calls := 0

	func can_hit(_pool: BulletPool, _index: int, hurtbox: Hurtbox) -> bool:
		asked += 1
		return not (refuse_all or refuse.has(hurtbox.get_instance_id()))

	func on_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
		hits += 1

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		update_calls += 1


class Plain:
	extends BulletBehavior
	var can_hit_called := 0

	func can_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> bool:
		can_hit_called += 1
		return false


func before_each() -> void:
	_tick = DT
	manager = BulletManager.new()
	manager.capacity = 64
	manager.world_bounds = Rect2(-500, -500, 1000, 1000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _target(at: Vector2) -> Hurtbox:
	var hb := Hurtbox.new()
	hb.radius = 20.0
	hb.position = at
	add_child_autofree(hb)
	watch_signals(hb)
	return hb


## `speed` is what the bullet would do in 1/60 s ticks; speeds are capped at
## BulletLimits.MAX_SPEED, so a faster shot gets a longer tick (`_tick`, which
## the tests pass to manager.step) that covers the same distance.
var _tick := DT


func _shot(behavior: BulletBehavior, veto: bool, speed: float = 300.0, from: Vector2 = Vector2.ZERO) -> ShotRequest:
	var r := _polar(from, speed)
	r.behavior_id = manager.register_behavior(behavior)
	r.can_hit_veto = veto
	r.lifetime = 5.0
	return r


func _polar(from: Vector2, speed: float) -> ShotRequest:
	_tick = maxf(_tick, speed * DT / BulletLimits.MAX_SPEED)
	return ShotRequest.polar(from, 0.0, speed * DT / _tick)


func test_request_defaults_off_and_reset_restores_it() -> void:
	var r := ShotRequest.new()
	assert_false(r.can_hit_veto)
	r.can_hit_veto = true
	r.reset()
	assert_false(r.can_hit_veto)


func test_allowed_hit_lands_normally() -> void:
	var hb := _target(Vector2(100, 0))
	var v := Vetoer.new()
	manager.spawn(_shot(v, true, 6000.0))
	manager.step(_tick)
	assert_eq(v.asked, 1)
	assert_signal_emit_count(hb, "hit", 1)
	assert_eq(v.hits, 1)
	assert_eq(manager.pool.count, 0, "consumed")


func test_vetoed_hit_does_no_damage_no_on_hit_and_keeps_the_bullet() -> void:
	var hb := _target(Vector2(100, 0))
	var v := Vetoer.new()
	v.refuse_all = true
	manager.spawn(_shot(v, true, 9000.0))
	manager.step(_tick)
	assert_eq(v.asked, 1)
	assert_signal_not_emitted(hb, "hit")
	assert_eq(v.hits, 0, "on_hit must not run for a vetoed hit")
	assert_eq(manager.pool.count, 1, "the bullet is not consumed")
	assert_eq(manager.last_veto_count, 1)
	assert_almost_eq(manager.pool.pos[0].x, 150.0, 0.01, "flies on, not clipped to the impact point")


func test_vetoed_hit_does_not_spend_a_pierce_or_set_the_rehit_guard() -> void:
	var hb := _target(Vector2(100, 0))
	var v := Vetoer.new()
	v.refuse_all = true
	var r := _shot(v, true, 6000.0)
	r.pierce = 2
	manager.spawn(r)
	manager.step(_tick)
	assert_eq(manager.pool.pierce[0], 2)
	assert_eq(manager.pool.last_hit[0], 0)
	assert_signal_not_emitted(hb, "hit")


func test_veto_is_asked_again_while_the_bullet_still_overlaps() -> void:
	var hb := _target(Vector2(30, 0))
	var v := Vetoer.new()
	v.refuse_all = true
	manager.spawn(_shot(v, true, 60.0, Vector2(20, 0)))
	for k in 3:
		manager.step(_tick)
	assert_eq(v.asked, 3)
	v.refuse_all = false
	manager.step(_tick)
	assert_signal_emit_count(hb, "hit", 1)
	assert_eq(manager.pool.count, 0)


func test_vetoed_target_does_not_hide_the_next_target_on_the_path() -> void:
	var near := _target(Vector2(100, 0))
	var far := _target(Vector2(200, 0))
	var v := Vetoer.new()
	v.refuse = [near.get_instance_id()] as Array[int]
	manager.spawn(_shot(v, true, 30000.0))
	manager.step(_tick)  # 500 px in one tick, past both
	assert_signal_not_emitted(near, "hit")
	assert_signal_emit_count(far, "hit", 1)
	assert_eq(manager.pool.count, 0)


func test_vetoed_target_does_not_hide_an_overlapping_target_for_a_slow_bullet() -> void:
	# A slow bullet normally takes the cheap point test and finds one target; a
	# flagged bullet sweeps so that whichever target is vetoed, the other still lands.
	var a := _target(Vector2(30, 0))
	var b := _target(Vector2(32, 0))
	var v := Vetoer.new()
	v.refuse = [a.get_instance_id()] as Array[int]
	manager.spawn(_shot(v, true, 60.0, Vector2(25, 0)))
	manager.step(_tick)
	assert_signal_not_emitted(a, "hit")
	assert_signal_emit_count(b, "hit", 1)
	# And the other way round, in a fresh manager.
	manager.clear_bullets()
	v.refuse = [b.get_instance_id()] as Array[int]
	var req := ShotRequest.polar(Vector2(25, 0), 0.0, 60.0)
	req.behavior_id = manager.register_behavior(v)
	req.can_hit_veto = true
	manager.spawn(req)
	manager.step(_tick)
	assert_signal_emit_count(a, "hit", 1)
	assert_signal_emit_count(b, "hit", 1)


func test_without_the_flag_the_first_target_wins() -> void:
	var near := _target(Vector2(100, 0))
	var far := _target(Vector2(200, 0))
	var v := Vetoer.new()
	v.refuse = [near.get_instance_id()] as Array[int]
	manager.spawn(_shot(v, false, 30000.0))
	manager.step(_tick)
	assert_signal_emit_count(near, "hit", 1)
	assert_signal_not_emitted(far, "hit")
	assert_eq(v.asked, 0, "the hook is never called for an unflagged bullet")


func test_unflagged_bullets_never_call_can_hit() -> void:
	_target(Vector2(100, 0))
	var p := Plain.new()
	manager.spawn(_shot(p, false, 6000.0))
	manager.step(_tick)
	assert_eq(p.can_hit_called, 0)
	assert_eq(manager.pool.count, 0, "the hit landed")
	assert_eq(manager.pool.veto_count, 0)


func test_flag_without_a_behavior_is_harmless() -> void:
	var hb := _target(Vector2(100, 0))
	var r := _polar(Vector2.ZERO, 6000.0)
	r.can_hit_veto = true
	manager.spawn(r)
	manager.step(_tick)
	assert_signal_emit_count(hb, "hit", 1)


func test_piercing_flagged_bullet_pierces_only_through_allowed_targets() -> void:
	var a := _target(Vector2(100, 0))
	var b := _target(Vector2(200, 0))
	var c := _target(Vector2(300, 0))
	var v := Vetoer.new()
	v.refuse = [b.get_instance_id()] as Array[int]
	var r := _shot(v, true, 30000.0)
	r.pierce = 1
	manager.spawn(r)
	manager.step(_tick)
	assert_signal_emit_count(a, "hit", 1)
	assert_signal_not_emitted(b, "hit")
	assert_signal_emit_count(c, "hit", 1)
	assert_eq(manager.pool.count, 0, "pierce 1 allows two hits; b did not count")


func test_veto_runs_before_damage_even_for_invulnerable_style_targets() -> void:
	# The veto sits ahead of Hurtbox.receive_hit, so a script can let a bullet pass
	# through a target without the target ever seeing the bullet.
	var hb := _target(Vector2(100, 0))
	var v := Vetoer.new()
	v.refuse_all = true
	manager.spawn(_shot(v, true, 6000.0))
	manager.step(_tick)
	assert_eq(hb.last_hit_bullet_id, 0)


# --- storage: the flag follows its bullet --------------------------------------------

func test_flag_is_stored_per_bullet_and_follows_swap_remove() -> void:
	var v := Vetoer.new()
	var plain := Plain.new()
	manager.spawn(_shot(plain, false))  # slot 0
	manager.spawn(_shot(v, true))       # slot 1
	manager.spawn(_shot(plain, false))  # slot 2
	assert_eq(manager.pool.can_hit_veto[1], 1)
	assert_eq(manager.pool.veto_count, 1)
	manager.pool.despawn(0)  # slot 2 moves to 0, nothing flagged moves
	assert_eq(manager.pool.can_hit_veto[0], 0)
	assert_eq(manager.pool.can_hit_veto[1], 1)
	manager.pool.despawn(0)  # the flagged bullet (last) moves into slot 0
	assert_eq(manager.pool.can_hit_veto[0], 1)
	assert_eq(manager.pool.veto_count, 1)
	assert_true(manager.pool.counters_consistent())
	manager.pool.despawn(0)
	assert_eq(manager.pool.veto_count, 0)
	assert_true(manager.pool.counters_consistent())


func test_clear_and_recycled_slots_reset_the_flag() -> void:
	var v := Vetoer.new()
	manager.spawn(_shot(v, true))
	manager.clear_bullets()
	assert_eq(manager.pool.veto_count, 0)
	manager.pool.spawn_simple(Vector2.ZERO, Vector2.ZERO, 1.0)
	assert_eq(manager.pool.can_hit_veto[0], 0, "a recycled slot is not flagged")
	manager.pool.despawn(0)
	manager.pool.spawn(ShotRequest.new())
	assert_eq(manager.pool.can_hit_veto[0], 0)
	assert_eq(manager.pool.veto_count, 0)


func test_reflect_drops_the_flag_with_the_script_unless_kept() -> void:
	var v := Vetoer.new()
	var r := _shot(v, true)
	r.owner_layer = Layers.ENEMY
	manager.spawn(r)
	assert_true(manager.pool.reflect(0, Layers.PLAYER))
	assert_eq(manager.pool.can_hit_veto[0], 0)
	assert_eq(manager.pool.veto_count, 0)
	var kept := _shot(v, true)
	kept.owner_layer = Layers.ENEMY
	manager.spawn(kept)
	assert_true(manager.pool.reflect(1, Layers.PLAYER, false, 1.0, true))
	assert_eq(manager.pool.can_hit_veto[1], 1)
	assert_eq(manager.pool.veto_count, 1)
	assert_true(manager.pool.counters_consistent())


func test_flag_is_lost_with_the_bullet_when_it_dies() -> void:
	var v := Vetoer.new()
	var r := _shot(v, true)
	r.lifetime = 0.01
	manager.spawn(r)
	manager.step(_tick)
	assert_eq(manager.pool.count, 0)
	assert_eq(manager.pool.veto_count, 0)
