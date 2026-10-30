extends GutTest
## FireCooldown: fire rate that carries the remainder between shots.

const DT := 1.0 / 60.0


func _shots_in(seconds: float, interval: float) -> int:
	var cd := FireCooldown.new()
	var shots := 0
	for tick in roundi(seconds / DT):
		if cd.update(DT, true, interval):
			shots += 1
	return shots


func test_long_run_rate_is_exactly_one_over_interval() -> void:
	# 10 s at one shot per 0.11 s = 90.9 shots. Resetting the timer to 0.11 on
	# every shot would round each gap up to 7 ticks and give only 85.
	assert_between(_shots_in(10.0, 0.11), 90, 91)
	assert_between(_shots_in(60.0, 0.11), 545, 546)


func test_gaps_alternate_between_the_two_neighbouring_tick_counts() -> void:
	var cd := FireCooldown.new()
	var gaps: Array[int] = []
	var since := 0
	for tick in 200:
		since += 1
		if cd.update(DT, true, 0.11):
			gaps.append(since)
			since = 0
	gaps.pop_front()  # first shot is immediate
	for g in gaps:
		assert_between(g, 6, 7, "0.11 s is 6.6 ticks")
	assert_true(gaps.has(6) and gaps.has(7), "the remainder is carried, not dropped")


func test_first_pull_fires_immediately_then_waits() -> void:
	var cd := FireCooldown.new()
	assert_true(cd.update(DT, true, 0.11))
	for tick in 5:
		assert_false(cd.update(DT, true, 0.11))


func test_released_trigger_never_fires() -> void:
	var cd := FireCooldown.new()
	for tick in 100:
		assert_false(cd.update(DT, false, 0.11))


func test_idle_time_is_not_banked_into_a_burst() -> void:
	var cd := FireCooldown.new()
	for tick in 600:
		cd.update(DT, false, 0.11)
	var shots := 0
	for tick in 6:
		if cd.update(DT, true, 0.11):
			shots += 1
	assert_eq(shots, 1, "one shot after a long pause, not a burst")


func test_interval_shorter_than_a_tick_fires_once_per_tick_at_most() -> void:
	assert_eq(_shots_in(1.0, 0.001), 60)
	assert_eq(_shots_in(1.0, 0.0), 60)


func test_reset_makes_the_weapon_ready() -> void:
	var cd := FireCooldown.new()
	cd.update(DT, true, 1.0)
	cd.reset()
	assert_true(cd.update(DT, true, 1.0))
