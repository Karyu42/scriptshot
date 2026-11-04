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


## Parses the --hooked option: a fraction in [0, 1] of the benchmark's bullets that
## carry a no-op on_update hook. Returns {"ok": bool, "value": float, "error": String}.
## Anything that is not a plain finite number in range (empty, "abc", "nan", "inf",
## "-0.1", "1.5") is refused with a message that says what was wrong.
static func parse_fraction(text: String, option: String = "--hooked") -> Dictionary:
	var t := text.strip_edges()
	if t == "" or not t.is_valid_float():
		return {"ok": false, "value": 0.0, "error": "%s needs a number between 0 and 1, got '%s'" % [option, text]}
	var value := t.to_float()
	if not (value >= 0.0 and value <= 1.0):  # also false for NaN
		return {"ok": false, "value": 0.0, "error": "%s must be between 0 and 1 (0.3 = 30%% of the bullets), got '%s'" % [option, text]}
	return {"ok": true, "value": value, "error": ""}
