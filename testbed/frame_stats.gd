class_name FrameStats
extends RefCounted
## Rolling window of float samples (ms) with nearest-rank percentiles.

var _buf := PackedFloat32Array()
var _next := 0
var count := 0


func _init(window: int = 300) -> void:
	_buf.resize(window)


func push(value: float) -> void:
	_buf[_next] = value
	_next = (_next + 1) % _buf.size()
	count = mini(count + 1, _buf.size())


func clear() -> void:
	_next = 0
	count = 0


func sorted_samples() -> PackedFloat32Array:
	var s := _buf.slice(0, count) if count < _buf.size() else _buf.duplicate()
	s.sort()
	return s


func sum() -> float:
	var t := 0.0
	for k in count:
		t += _buf[k]
	return t


## Nearest-rank percentile of an already sorted array.
static func percentile(sorted: PackedFloat32Array, p: float) -> float:
	if sorted.is_empty():
		return 0.0
	var rank := clampi(ceili(p / 100.0 * sorted.size()) - 1, 0, sorted.size() - 1)
	return sorted[rank]
