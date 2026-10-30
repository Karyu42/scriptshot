extends GutTest
## CameraMath: smoothing and shake curves.


func test_smoothing_factor_is_between_zero_and_one() -> void:
	assert_eq(CameraMath.smoothing_factor(8.0, 0.0), 0.0)
	var f := CameraMath.smoothing_factor(8.0, 1.0 / 60.0)
	assert_between(f, 0.0, 1.0)
	assert_between(CameraMath.smoothing_factor(8.0, 100.0), 0.999, 1.0)


func test_follow_is_frame_rate_independent() -> void:
	var a := Vector2.ZERO
	for i in 60:
		a = CameraMath.follow(a, Vector2(100, 0), 8.0, 1.0 / 60.0)
	var b := Vector2.ZERO
	for i in 30:
		b = CameraMath.follow(b, Vector2(100, 0), 8.0, 1.0 / 30.0)
	assert_almost_eq(a.x, b.x, 0.01)


func test_follow_converges_without_overshoot() -> void:
	var p := Vector2.ZERO
	for i in 300:
		p = CameraMath.follow(p, Vector2(100, 50), 8.0, 1.0 / 60.0)
		assert_true(p.x <= 100.0 and p.y <= 50.0)
	assert_almost_eq(p.x, 100.0, 0.01)


func test_shake_strength_is_quadratic_and_clamped() -> void:
	assert_eq(CameraMath.shake_strength(0.0), 0.0)
	assert_almost_eq(CameraMath.shake_strength(0.5), 0.25, 0.0001)
	assert_eq(CameraMath.shake_strength(1.0), 1.0)
	assert_eq(CameraMath.shake_strength(3.0), 1.0)
	assert_eq(CameraMath.shake_strength(-1.0), 0.0)
