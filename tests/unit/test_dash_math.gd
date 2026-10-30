extends GutTest
## DashMath: the closed-form speed curve of the dash.

const DIST := 160.0
const DUR := 0.2
const EXIT := 300.0


func _d(t: float, power: float = 2.0) -> float:
	return DashMath.distance_at(t, DIST, DUR, EXIT, power)


func _v(t: float, power: float = 2.0) -> float:
	return DashMath.speed_at(t, DIST, DUR, EXIT, power)


func test_distance_is_exactly_the_tuned_distance_at_the_end() -> void:
	for power: float in [0.0, 1.0, 2.0, 3.5, 6.0]:
		assert_almost_eq(_d(DUR, power), DIST, 0.001, "power %s" % power)


func test_distance_starts_at_zero_and_is_clamped_outside_the_burst() -> void:
	assert_eq(_d(0.0), 0.0)
	assert_eq(_d(-1.0), 0.0)
	assert_almost_eq(_d(5.0), DIST, 0.001)


func test_distance_is_monotonic() -> void:
	var last := -1.0
	for i in 19:
		var d := _d(DUR * i / 18.0)
		assert_gt(d, last)
		last = d


func test_speed_decelerates_from_a_burst_into_running_speed() -> void:
	var peak := _v(0.0)
	assert_gt(peak, EXIT * 4.0, "launches well above running speed")
	assert_almost_eq(_v(DUR), EXIT, 0.001, "blends into max_speed at the end")
	var last := INF
	for i in 19:
		var v := _v(DUR * i / 18.0)
		assert_lte(v, last + 0.001)
		last = v


func test_speed_matches_numeric_derivative_of_distance() -> void:
	for t: float in [0.01, 0.05, 0.1, 0.17]:
		var numeric := (_d(t + 0.0001) - _d(t - 0.0001)) / 0.0002
		assert_almost_eq(numeric, _v(t), 1.0)


func test_power_zero_is_constant_speed() -> void:
	assert_almost_eq(_v(0.0, 0.0), DIST / DUR, 0.001)
	assert_almost_eq(_v(DUR / 2.0, 0.0), DIST / DUR, 0.001)


func test_higher_power_launches_harder_for_the_same_distance() -> void:
	assert_gt(_v(0.0, 4.0), _v(0.0, 2.0))
	assert_gt(_v(0.0, 2.0), _v(0.0, 1.0))
	assert_gt(_d(0.05, 4.0), _d(0.05, 1.0), "front-loaded")


func test_peak_never_negative() -> void:
	assert_gte(DashMath.peak_speed(0.0, 0.2, 300.0, 2.0), 0.0)


func test_default_dash_peaks_at_1800_px_per_second() -> void:
	# pillars 5.4 dash (160 px over 0.2 s), 300 px/s running speed, power 2.
	assert_almost_eq(DashMath.peak_speed(160.0, 0.2, 300.0, 2.0), 1800.0, 0.01)
