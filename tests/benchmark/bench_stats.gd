class_name BenchStats
extends RefCounted
## Tiny statistics helpers for the benchmark (kept separate so they are unit tested).


## Nearest-rank percentile (p in 0..100) of `samples`. Returns 0.0 when empty.
static func percentile(samples: PackedFloat64Array, p: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	var rank := ceili(clampf(p, 0.0, 100.0) / 100.0 * sorted.size())
	return sorted[clampi(rank - 1, 0, sorted.size() - 1)]


static func mean(samples: PackedFloat64Array) -> float:
	if samples.is_empty():
		return 0.0
	var total := 0.0
	for s in samples:
		total += s
	return total / samples.size()
