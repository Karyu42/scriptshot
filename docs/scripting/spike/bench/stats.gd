class_name Stats
static func median(a: Array) -> float:
	var b := a.duplicate(); b.sort()
	var n := b.size()
	return b[n/2] if n % 2 == 1 else (b[n/2-1] + b[n/2]) / 2.0
static func p95(a: Array) -> float:
	var b := a.duplicate(); b.sort()
	return b[min(b.size()-1, int(ceil(0.95 * b.size())) - 1)]
static func fmt(x: float) -> String:
	return "%.1f" % x
