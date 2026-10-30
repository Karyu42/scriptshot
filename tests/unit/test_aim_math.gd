extends GutTest
## AimMath: stick and mouse aiming.


func test_stick_beyond_deadzone_gives_normalized_direction() -> void:
	var d := AimMath.direction_from_stick(Vector2(0, -0.8), Vector2.RIGHT)
	assert_eq(d, Vector2.UP)


func test_released_stick_keeps_previous_aim() -> void:
	var prev := Vector2(0, 1)
	assert_eq(AimMath.direction_from_stick(Vector2.ZERO, prev), prev)


func test_stick_input_is_not_run_through_a_second_deadzone() -> void:
	# Input.get_vector() already removed the deadzone (and rescaled), so a small
	# remaining deflection is real input and must steer the aim.
	var d := AimMath.direction_from_stick(Vector2(0.05, 0.0), Vector2.UP)
	assert_eq(d, Vector2.RIGHT)


func test_explicit_deadzone_for_raw_stick_values_still_works() -> void:
	var prev := Vector2(0, 1)
	assert_eq(AimMath.direction_from_stick(Vector2(0.1, 0.05), prev, 0.25), prev)
	assert_eq(AimMath.direction_from_stick(Vector2(0.3, 0.0), prev, 0.25), Vector2.RIGHT)


func test_screen_offset_aim_normalises_and_keeps_previous_on_top_of_ship() -> void:
	assert_eq(AimMath.direction_from_screen_offset(Vector2(0, 250), Vector2.RIGHT), Vector2.DOWN)
	assert_eq(AimMath.direction_from_screen_offset(Vector2(0.2, 0.3), Vector2.LEFT), Vector2.LEFT)


func test_stick_diagonal_is_unit_length() -> void:
	var d := AimMath.direction_from_stick(Vector2(0.6, 0.6), Vector2.RIGHT)
	assert_almost_eq(d.length(), 1.0, 0.0001)


func test_direction_to_point_in_world_space() -> void:
	var d := AimMath.direction_to_point(Vector2(100, 100), Vector2(100, 400), Vector2.RIGHT)
	assert_eq(d, Vector2.DOWN)
	d = AimMath.direction_to_point(Vector2(-50, 0), Vector2(150, 0), Vector2.UP)
	assert_eq(d, Vector2.RIGHT)


func test_direction_to_point_on_origin_keeps_previous() -> void:
	var prev := Vector2.LEFT
	assert_eq(AimMath.direction_to_point(Vector2(5, 5), Vector2(5.2, 5.1), prev), prev)


func test_muzzle_is_offset_along_aim() -> void:
	assert_eq(AimMath.muzzle(Vector2(10, 10), Vector2.RIGHT, 20.0), Vector2(30, 10))
