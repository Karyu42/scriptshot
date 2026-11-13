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


func test_reset_clears_the_last_message_and_the_window_counters() -> void:
	ScriptWarnings.warn(KEY, "first")
	assert_eq(ScriptWarnings.last_message(KEY), "first")
	ScriptWarnings.reset()
	assert_eq(ScriptWarnings.last_message(KEY), "", "nothing is left of the old message")
	# A fresh key state: the next warning starts a new window and is printed in full.
	ScriptWarnings.warn(KEY, "second")
	assert_eq(ScriptWarnings.last_message(KEY), "second")
	assert_eq(ScriptWarnings.printed_count(KEY), 1)
	# Reset on a key that never warned is fine too.
	ScriptWarnings.reset()
	assert_eq(ScriptWarnings.last_message("never.warned"), "")
	assert_eq(ScriptWarnings.last_message(KEY), "")


func test_real_clock_is_used_without_an_override() -> void:
	ScriptWarnings.clock_override_msec = -1
	for i in 6:
		ScriptWarnings.warn(KEY, "bad")
	assert_eq(ScriptWarnings.printed_count(KEY), 3)


# --- the text of the printed warnings (push_warning is tracked by GUT) -----------------------

## The texts of the warnings pushed during this test, as tracked by GUT.
func _printed_texts() -> Array[String]:
	var tracker: Object = gut.error_tracker
	var out: Array[String] = []
	for e: Object in tracker.call("get_errors_for_test"):
		out.append(str(e.get("code")))
	return out


func test_a_suppressed_warning_still_updates_the_last_message() -> void:
	for i in ScriptWarnings.LIMIT:
		assert_true(ScriptWarnings.begin(KEY))
		ScriptWarnings.finish(KEY, ScriptWarnings.removed_message(KEY, "first"))
	assert_false(ScriptWarnings.begin(KEY))
	ScriptWarnings.keep_removed(KEY, "second")
	assert_eq(ScriptWarnings.printed_count(KEY), ScriptWarnings.LIMIT)
	assert_eq(ScriptWarnings.count(KEY), ScriptWarnings.LIMIT + 1)
	assert_eq(ScriptWarnings.last_message(KEY), ScriptWarnings.removed_message(KEY, "second"))


func test_the_last_warning_of_a_window_says_the_rest_are_suppressed() -> void:
	for i in 5:
		ScriptWarnings.warn(KEY, "bad value")
	assert_eq(_printed_texts(), [
		"bad value",
		"bad value",
		"bad value (further warnings of this kind are suppressed for 10 s)",
	] as Array[String], "only LIMIT are printed; the last one announces the silence")


func test_the_first_warning_of_a_new_window_says_how_many_were_suppressed() -> void:
	for i in 7:  # 3 printed, 4 suppressed
		ScriptWarnings.warn(KEY, "bad value")
	ScriptWarnings.clock_override_msec = 1000 + ScriptWarnings.WINDOW_MSEC
	ScriptWarnings.warn(KEY, "bad value")
	var texts := _printed_texts()
	assert_eq(texts.size(), 4)
	assert_eq(texts[3], "bad value (4 earlier warnings of this kind were suppressed)")


func test_a_new_window_without_suppressed_warnings_has_no_earlier_notice() -> void:
	for i in 2:  # nothing suppressed
		ScriptWarnings.warn(KEY, "bad value")
	ScriptWarnings.clock_override_msec = 1000 + ScriptWarnings.WINDOW_MSEC
	ScriptWarnings.warn(KEY, "bad value")
	assert_eq(_printed_texts(), ["bad value", "bad value", "bad value"] as Array[String])


func test_the_suppressed_count_is_per_kind_and_restarts_in_every_window() -> void:
	for i in 5:  # 2 suppressed
		ScriptWarnings.warn(KEY, "bad value")
	for i in 5:  # another kind: 2 suppressed, must not leak into KEY's count
		ScriptWarnings.warn("other", "other value")
	ScriptWarnings.clock_override_msec = 1000 + ScriptWarnings.WINDOW_MSEC
	for i in 4:  # 3 printed (the first with the notice), 1 suppressed
		ScriptWarnings.warn(KEY, "bad value")
	ScriptWarnings.clock_override_msec = 1000 + 2 * ScriptWarnings.WINDOW_MSEC
	ScriptWarnings.warn(KEY, "bad value")
	var mine: Array[String] = []
	for text in _printed_texts():
		if text.begins_with("bad value"):
			mine.append(text)
	assert_eq(mine.size(), 7)
	assert_eq(mine[3], "bad value (2 earlier warnings of this kind were suppressed)")
	assert_eq(mine[6], "bad value (1 earlier warnings of this kind were suppressed)")
