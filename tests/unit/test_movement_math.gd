extends GutTest
## MovementMath: acceleration / friction feel numbers.

const MAX_SPEED := 300.0
const ACCEL := 2400.0
const FRICTION := 2000.0
const BOOST := 1.6
const DT := 1.0 / 60.0


func _step(vel: Vector2, input: Vector2, dt: float = DT) -> Vector2:
	return MovementMath.step_velocity(vel, input, MAX_SPEED, ACCEL, FRICTION, BOOST, dt)


func test_accelerates_toward_input_direction() -> void:
	var v := _step(Vector2.ZERO, Vector2.RIGHT)
	assert_almost_eq(v.x, ACCEL * DT, 0.001)
	assert_eq(v.y, 0.0)


func test_reaches_max_speed_in_expected_time_and_never_exceeds_it() -> void:
	var v := Vector2.ZERO
	var frames := 0
	while v.length() < MAX_SPEED - 0.001 and frames < 600:
		v = _step(v, Vector2.RIGHT)
		frames += 1
		assert_true(v.length() <= MAX_SPEED + 0.001)
	# 300 / 2400 s = 7.5 ticks -> 8.
	assert_eq(frames, 8)
	assert_almost_eq(MovementMath.time_to_max_speed(MAX_SPEED, ACCEL), 0.125, 0.0001)
	for i in 30:
		v = _step(v, Vector2.RIGHT)
	assert_almost_eq(v.length(), MAX_SPEED, 0.001)


func test_diagonal_input_is_not_faster_than_cardinal() -> void:
	var v := Vector2.ZERO
	for i in 60:
		v = _step(v, Vector2(1, 1))
	assert_almost_eq(v.length(), MAX_SPEED, 0.01)


func test_partial_stick_deflection_scales_top_speed() -> void:
	var v := Vector2.ZERO
	for i in 60:
		v = _step(v, Vector2(0.5, 0))
	assert_almost_eq(v.x, MAX_SPEED * 0.5, 0.01)


func test_friction_brakes_to_a_full_stop() -> void:
	var v := Vector2(MAX_SPEED, 0)
	var frames := 0
	while v != Vector2.ZERO and frames < 600:
		v = _step(v, Vector2.ZERO)
		frames += 1
	assert_eq(v, Vector2.ZERO)
	# 300 / 2000 s = 9 ticks; allow one tick of float rounding.
	assert_between(frames, 9, 10)


func test_friction_does_not_overshoot_or_change_direction() -> void:
	var v := _step(Vector2(1, 1), Vector2.ZERO)
	assert_eq(v, Vector2.ZERO)
	v = _step(Vector2(100, 0), Vector2.ZERO)
	assert_true(v.x > 0.0 and v.x < 100.0)


func test_reversing_is_boosted() -> void:
	var normal := _step(Vector2(MAX_SPEED, 0), Vector2.UP)
	var reversed := _step(Vector2(MAX_SPEED, 0), Vector2.LEFT)
	# Same starting speed; reversing sheds speed faster than a perpendicular turn.
	assert_true(reversed.x < normal.x)
	assert_almost_eq(MAX_SPEED - reversed.x, ACCEL * BOOST * DT, 0.001)


func test_overspeed_decays_toward_max_instead_of_snapping() -> void:
	var v := _step(Vector2(600, 0), Vector2.RIGHT)
	assert_almost_eq(v.x, 600.0 - ACCEL * DT, 0.001)
	assert_true(v.x > MAX_SPEED)


func test_result_is_frame_rate_independent_for_full_acceleration() -> void:
	var a := Vector2.ZERO
	for i in 6:
		a = _step(a, Vector2.RIGHT, 1.0 / 60.0)
	var b := Vector2.ZERO
	for i in 3:
		b = _step(b, Vector2.RIGHT, 1.0 / 30.0)
	assert_almost_eq(a.x, b.x, 0.001)


func test_feel_numbers_are_snappy_but_not_instant() -> void:
	assert_between(MovementMath.time_to_max_speed(MAX_SPEED, ACCEL), 0.08, 0.2)
	assert_between(MovementMath.time_to_stop(MAX_SPEED, FRICTION), 0.08, 0.25)
