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
