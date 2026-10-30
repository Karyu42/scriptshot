extends GutTest
## AimMath: stick and mouse aiming.


func test_stick_beyond_deadzone_gives_normalized_direction() -> void:
	var d := AimMath.direction_from_stick(Vector2(0, -0.8), Vector2.RIGHT)
	assert_eq(d, Vector2.UP)


func test_stick_inside_deadzone_keeps_previous_aim() -> void:
	var prev := Vector2(0, 1)
	assert_eq(AimMath.direction_from_stick(Vector2(0.1, 0.05), prev), prev)
	assert_eq(AimMath.direction_from_stick(Vector2.ZERO, prev), prev)


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
