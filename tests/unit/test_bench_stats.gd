extends GutTest
## BenchStats percentile maths used by the benchmark report.


func test_percentile_nearest_rank() -> void:
	var s := PackedFloat64Array()
	for i in range(1, 101):
		s.append(float(i))
	assert_eq(BenchStats.percentile(s, 50.0), 50.0)
	assert_eq(BenchStats.percentile(s, 95.0), 95.0)
	assert_eq(BenchStats.percentile(s, 99.0), 99.0)
	assert_eq(BenchStats.percentile(s, 100.0), 100.0)
	assert_eq(BenchStats.percentile(s, 0.0), 1.0)


func test_percentile_does_not_depend_on_input_order() -> void:
	var s := PackedFloat64Array([5.0, 1.0, 4.0, 2.0, 3.0])
	assert_eq(BenchStats.percentile(s, 50.0), 3.0)
	assert_eq(s[0], 5.0, "input is not mutated")


func test_percentile_edge_cases() -> void:
	assert_eq(BenchStats.percentile(PackedFloat64Array(), 95.0), 0.0)
	assert_eq(BenchStats.percentile(PackedFloat64Array([7.0]), 95.0), 7.0)


func test_mean() -> void:
	assert_eq(BenchStats.mean(PackedFloat64Array([1.0, 2.0, 3.0])), 2.0)
	assert_eq(BenchStats.mean(PackedFloat64Array()), 0.0)


# --- --hooked fraction parsing --------------------------------------------------

func test_parse_fraction_accepts_the_range() -> void:
	for text in ["0", "0.0", "0.3", "1", "1.0", " 0.5 ", ".25"]:
		var r := BenchStats.parse_fraction(text)
		assert_true(r.ok, "'%s' is valid" % text)
		assert_eq(r.error, "")
	assert_eq(BenchStats.parse_fraction("0.3").value, 0.3)
	assert_eq(BenchStats.parse_fraction("1").value, 1.0)
	assert_eq(BenchStats.parse_fraction("0").value, 0.0)


func test_parse_fraction_refuses_bad_values_with_a_message() -> void:
	for text in ["", "abc", "nan", "inf", "-inf", "-0.1", "1.0001", "1.5", "30%", "0,3", "--"]:
		var r := BenchStats.parse_fraction(text)
		assert_false(r.ok, "'%s' is refused" % text)
		assert_string_contains(r.error, "--hooked", "the message names the option")
		assert_string_contains(r.error, "0 and 1", "and the valid range")
