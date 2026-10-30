extends GutTest
## FireCooldown: fire rate that carries the remainder between shots.

const DT := 1.0 / 60.0


func _shots_in(seconds: float, interval: float) -> int:
	var cd := FireCooldown.new()
	var shots := 0
	for tick in roundi(seconds / DT):
		shots += cd.update(DT, true, interval)
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
		if cd.update(DT, true, 0.11) > 0:
			gaps.append(since)
			since = 0
	gaps.pop_front()  # first shot is immediate
	for g in gaps:
		assert_between(g, 6, 7, "0.11 s is 6.6 ticks")
	assert_true(gaps.has(6) and gaps.has(7), "the remainder is carried, not dropped")


func test_first_pull_fires_immediately_then_waits() -> void:
	var cd := FireCooldown.new()
	assert_eq(cd.update(DT, true, 0.11), 1)
	for tick in 5:
		assert_eq(cd.update(DT, true, 0.11), 0)


func test_released_trigger_never_fires() -> void:
	var cd := FireCooldown.new()
	for tick in 100:
		assert_eq(cd.update(DT, false, 0.11), 0)


func test_idle_time_is_not_banked_into_a_burst() -> void:
	var cd := FireCooldown.new()
	for tick in 600:
		cd.update(DT, false, 0.11)
	var shots := 0
	for tick in 6:
		shots += cd.update(DT, true, 0.11)
	assert_eq(shots, 1, "one shot after a long pause, not a burst")


func test_interval_shorter_than_a_tick_fires_several_shots_per_tick() -> void:
	# 0.005 s = 200 shots/s: 3.33 shots per 60 Hz tick, carried exactly.
	assert_between(_shots_in(1.0, 0.005), 199, 201)
	var cd := FireCooldown.new()
	var counts: Array[int] = []
	for tick in 30:
		counts.append(cd.update(DT, true, 0.005))
	for c in counts:
		assert_between(c, 3, 4, "3.33 shots a tick: 3 or 4")
	assert_true(counts.has(3) and counts.has(4))


func test_shots_per_tick_are_capped() -> void:
	var cd := FireCooldown.new()
	assert_eq(cd.update(DT, true, 0.0001), FireCooldown.MAX_SHOTS_PER_TICK)
	# The debt beyond the cap is dropped, not paid back as a later burst.
	assert_eq(cd.update(DT, false, 0.0001), 0)
	assert_eq(cd.update(DT, true, 0.0001), FireCooldown.MAX_SHOTS_PER_TICK)
	assert_eq(_shots_in(1.0, 0.0001), 60 * FireCooldown.MAX_SHOTS_PER_TICK)


func test_interval_of_zero_means_once_per_tick() -> void:
	assert_eq(_shots_in(1.0, 0.0), 60)
	assert_eq(_shots_in(1.0, -1.0), 60)


func test_reset_makes_the_weapon_ready() -> void:
	var cd := FireCooldown.new()
	cd.update(DT, true, 1.0)
	cd.reset()
	assert_eq(cd.update(DT, true, 1.0), 1)
