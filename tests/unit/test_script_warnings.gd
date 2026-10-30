extends GutTest
## ScriptWarnings: LIMIT prints per window, then silent, then reported again.

const KEY := "test.key"


func before_each() -> void:
	ScriptWarnings.reset()
	ScriptWarnings.clock_override_msec = 1000


func after_each() -> void:
	ScriptWarnings.reset()


func test_prints_at_most_limit_per_window() -> void:
	for i in 20:
		ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.count(KEY), 20)
	assert_eq(ScriptWarnings.printed_count(KEY), ScriptWarnings.LIMIT)


func test_warns_again_after_the_window_has_passed() -> void:
	for i in 10:
		ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 3)
	ScriptWarnings.clock_override_msec = 1000 + ScriptWarnings.WINDOW_MSEC - 1
	ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 3, "still the same window")
	ScriptWarnings.clock_override_msec = 1000 + ScriptWarnings.WINDOW_MSEC
	ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 4, "a new window reports again")
	for i in 5:
		ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 6, "and has its own budget of LIMIT")
	assert_eq(ScriptWarnings.count(KEY), 10 + 1 + 1 + 5)


func test_kinds_have_independent_windows() -> void:
	for i in 10:
		ScriptWarnings.warn("a", "bad")
	ScriptWarnings.clock_override_msec = 5000
	ScriptWarnings.warn("b", "bad")
	assert_eq(ScriptWarnings.printed_count("a"), 3)
	assert_eq(ScriptWarnings.printed_count("b"), 1)


func test_a_quiet_kind_is_never_silenced_for_good() -> void:
	# The old counter never reset: after 3 NaNs a kind stayed silent for the whole
	# session. A burst now and another one a minute later must both be reported.
	for i in 3:
		ScriptWarnings.warn(KEY, "bad")
	ScriptWarnings.clock_override_msec = 61000
	for i in 3:
		ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 6)


func test_reset_clears_everything_including_the_clock() -> void:
	ScriptWarnings.warn(KEY, "bad")
	ScriptWarnings.reset()
	assert_eq(ScriptWarnings.count(KEY), 0)
	assert_eq(ScriptWarnings.printed_count(KEY), 0)
	assert_eq(ScriptWarnings.clock_override_msec, -1)


func test_real_clock_is_used_without_an_override() -> void:
	ScriptWarnings.clock_override_msec = -1
	for i in 6:
		ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 3)
