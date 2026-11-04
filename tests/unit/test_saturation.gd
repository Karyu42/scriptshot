extends GutTest
## Item: observable pool saturation (dropped count, is_saturated, signal, rate-limited warning).

const DT := 1.0 / 60.0

var manager: BulletManager


func before_each() -> void:
	manager = BulletManager.new()
	manager.capacity = 4
	manager.enemy_reserve = 0  # the default 30% reserve would also refuse the player's shots here
	manager.world_bounds = Rect2(-500, -500, 1000, 1000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _shot() -> ShotRequest:
	var r := ShotRequest.polar(Vector2.ZERO, 0.0, 0.0)
	r.lifetime = 100.0
	return r


func _fill() -> void:
	for i in 4:
		manager.emitter.request_shot(_shot())


func test_not_saturated_until_pool_is_full() -> void:
	assert_false(manager.emitter.is_saturated())
	for i in 3:
		manager.emitter.request_shot(_shot())
	assert_false(manager.emitter.is_saturated())
	manager.emitter.request_shot(_shot())
	assert_true(manager.emitter.is_saturated())
	assert_eq(manager.emitter.get_dropped_count(), 0, "full is not the same as dropping")


func test_dropped_count_counts_rejected_shots_cumulatively() -> void:
	_fill()
	for i in 3:
		assert_false(manager.emitter.request_shot(_shot()))
	assert_eq(manager.emitter.get_dropped_count(), 3)
	assert_eq(manager.emitter.request_shot_id(_shot()), -1)
	assert_eq(manager.emitter.get_dropped_count(), 4)


func test_is_saturated_clears_when_bullets_despawn() -> void:
	_fill()
	assert_true(manager.emitter.is_saturated())
	manager.pool.despawn(0)
	assert_false(manager.emitter.is_saturated())
	assert_true(manager.emitter.request_shot(_shot()))


func test_signal_fires_once_per_tick_with_batch_counts() -> void:
	watch_signals(manager.emitter)
	_fill()
	manager.step(DT)
	assert_signal_not_emitted(manager.emitter, "pool_saturated")
	for i in 5:
		manager.emitter.request_shot(_shot())
	manager.step(DT)
	assert_signal_emit_count(manager.emitter, "pool_saturated", 1)
	assert_signal_emitted_with_parameters(manager.emitter, "pool_saturated", [5, 5])
	manager.step(DT)
	assert_signal_emit_count(manager.emitter, "pool_saturated", 1, "no new drops, no new signal")
	manager.emitter.request_shot(_shot())
	manager.step(DT)
	assert_signal_emit_count(manager.emitter, "pool_saturated", 2)
	assert_signal_emitted_with_parameters(manager.emitter, "pool_saturated", [1, 6], 1)


func test_warning_is_rate_limited_but_signal_is_not() -> void:
	manager.saturation_warning_interval = 1.0
	watch_signals(manager.emitter)
	_fill()
	for tick in 120:  # 2 simulated seconds of constant overflow
		manager.emitter.request_shot(_shot())
		manager.step(DT)
	assert_signal_emit_count(manager.emitter, "pool_saturated", 120)
	assert_between(manager.saturation_warnings_emitted, 2, 3)


func test_zero_interval_warns_every_saturated_tick() -> void:
	manager.saturation_warning_interval = 0.0
	_fill()
	for tick in 5:
		manager.emitter.request_shot(_shot())
		manager.step(DT)
	assert_eq(manager.saturation_warnings_emitted, 5)


func test_no_warning_without_drops() -> void:
	_fill()
	for tick in 30:
		manager.step(DT)
	assert_eq(manager.saturation_warnings_emitted, 0)
