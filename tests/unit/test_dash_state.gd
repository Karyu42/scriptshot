extends GutTest
## DashState: cooldown, direction and exact per-tick displacement.

const DT := 1.0 / 60.0

var d: DashState


func before_each() -> void:
	d = DashState.new()


## Runs the state for `seconds` in `dt` steps; returns the total displacement.
func _run(seconds: float, dt: float = DT) -> Vector2:
	var moved := Vector2.ZERO
	var steps := roundi(seconds / dt)
	for i in steps:
		moved += d.step(dt) * dt
	return moved


func test_defaults_are_the_decided_numbers() -> void:
	assert_eq(d.invulnerable_time, 0.2)
	assert_eq(d.cooldown, 1.5)
	assert_true(d.is_ready())


func test_start_sets_direction_cooldown_and_activity() -> void:
	assert_true(d.start(Vector2(0, -5)))
	assert_true(d.active)
	assert_eq(d.direction, Vector2.UP)
	assert_eq(d.cooldown_left, 1.5)
	assert_false(d.is_ready())


func test_cannot_start_with_zero_or_non_finite_direction() -> void:
	assert_false(d.start(Vector2.ZERO))
	assert_false(d.start(Vector2(NAN, 1.0)))
	assert_false(d.start(Vector2(INF, 0.0)))
	assert_false(d.active)
	assert_eq(d.cooldown_left, 0.0, "a refused dash costs nothing")


func test_cannot_start_while_active_or_on_cooldown() -> void:
	d.start(Vector2.RIGHT)
	assert_false(d.start(Vector2.LEFT))
	assert_eq(d.direction, Vector2.RIGHT)
	_run(0.5)
	assert_false(d.active)
	assert_false(d.start(Vector2.LEFT), "still on cooldown after the burst")


func test_total_displacement_is_the_tuned_distance_at_60hz() -> void:
	d.start(Vector2.RIGHT)
	var moved := _run(0.3)
	assert_almost_eq(moved.x, d.distance, 0.01)
	assert_almost_eq(moved.y, 0.0, 0.0001)


func test_displacement_is_independent_of_tick_rate() -> void:
	for dt: float in [1.0 / 30.0, 1.0 / 60.0, 1.0 / 144.0, 1.0 / 240.0]:
		var s := DashState.new()
		s.start(Vector2(3, 4))
		var moved := Vector2.ZERO
		for i in 200:
			moved += s.step(dt) * dt
		assert_almost_eq(moved.length(), s.distance, 0.01, "dt %s" % dt)
		assert_almost_eq(moved.normalized().x, 0.6, 0.0001)


func test_burst_ends_after_its_duration_and_flags_the_finishing_step() -> void:
	d.start(Vector2.RIGHT)
	var finished_steps := 0
	var active_steps := 0
	for i in 30:
		d.step(DT)
		if d.just_finished:
			finished_steps += 1
		if d.active:
			active_steps += 1
	assert_eq(finished_steps, 1)
	assert_between(active_steps, 9, 11, "0.18 s = about 10 ticks of 1/60")


func test_cooldown_is_measured_from_the_start_of_the_dash() -> void:
	d.start(Vector2.RIGHT)
	_run(1.45)
	assert_false(d.is_ready())
	_run(0.1)
	assert_true(d.is_ready())
	assert_true(d.start(Vector2.LEFT), "ready again after 1.5 s")


func test_step_without_dash_returns_zero_and_ticks_cooldown() -> void:
	assert_eq(d.step(DT), Vector2.ZERO)
	d.start(Vector2.RIGHT)
	_run(0.5)
	assert_eq(d.step(DT), Vector2.ZERO)
	assert_lt(d.cooldown_left, 1.5)


func test_bad_deltas_are_ignored() -> void:
	d.start(Vector2.RIGHT)
	assert_eq(d.step(NAN), Vector2.ZERO)
	assert_eq(d.step(-1.0), Vector2.ZERO)
	assert_eq(d.step(0.0), Vector2.ZERO)
	assert_eq(d.elapsed, 0.0)


func test_progress_and_reset() -> void:
	assert_eq(d.progress(), 1.0)
	d.start(Vector2.RIGHT)
	d.step(0.09)
	assert_almost_eq(d.progress(), 0.5, 0.001)
	d.reset()
	assert_true(d.is_ready())
	assert_false(d.active)
