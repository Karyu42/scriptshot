extends GutTest
## TriggerState edges and hold time, and how they reach ShotContext.

const DT := 1.0 / 60.0

var t: TriggerState


func before_each() -> void:
	t = TriggerState.new()


func test_idle_state() -> void:
	t.update(false, DT)
	assert_false(t.pressed)
	assert_false(t.just_pressed)
	assert_false(t.just_released)
	assert_eq(t.held_time, 0.0)


func test_press_edge_happens_exactly_once() -> void:
	t.update(true, DT)
	assert_true(t.just_pressed)
	assert_true(t.pressed)
	t.update(true, DT)
	assert_false(t.just_pressed)
	assert_true(t.pressed)


func test_held_time_accumulates_including_the_press_tick() -> void:
	t.update(true, DT)
	assert_almost_eq(t.held_time, DT, 0.00001)
	for i in 29:
		t.update(true, DT)
	assert_almost_eq(t.held_time, 30.0 * DT, 0.0001)


func test_release_edge_keeps_hold_duration_for_that_tick_only() -> void:
	for i in 30:
		t.update(true, DT)
	t.update(false, DT)
	assert_true(t.just_released)
	assert_false(t.pressed)
	assert_almost_eq(t.held_time, 30.0 * DT, 0.0001, "charge weapons read the hold length here")
	t.update(false, DT)
	assert_false(t.just_released)
	assert_eq(t.held_time, 0.0)


func test_single_tick_tap() -> void:
	t.update(true, DT)
	t.update(false, DT)
	assert_true(t.just_released)
	assert_almost_eq(t.held_time, DT, 0.00001)


func test_hold_restarts_after_release() -> void:
	for i in 10:
		t.update(true, DT)
	t.update(false, DT)
	t.update(false, DT)
	t.update(true, DT)
	assert_true(t.just_pressed)
	assert_almost_eq(t.held_time, DT, 0.00001)


func test_apply_to_copies_everything_into_context() -> void:
	t.update(true, DT)
	t.update(true, DT)
	var c := ShotContext.new()
	t.apply_to(c)
	assert_true(c.trigger_pressed)
	assert_false(c.trigger_just_pressed)
	assert_false(c.trigger_just_released)
	assert_almost_eq(c.trigger_held_time, 2.0 * DT, 0.00001)


func test_context_defaults_to_trigger_up() -> void:
	var c := ShotContext.new()
	assert_false(c.trigger_pressed)
	assert_eq(c.trigger_held_time, 0.0)
