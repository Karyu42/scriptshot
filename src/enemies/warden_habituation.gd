class_name WardenHabituation
extends RefCounted
## Pattern-signature tracker for the Warden (pillars §5.3, vertical-slice §5.2).
##
## 24 angle buckets of 15°, 4 speed bands. If one signature is more than 70% of
## hits in the last 10 s, the damage multiplier falls 0.1 per 5 s (floor ×0.4)
## and recovers 0.2 per 5 s when the signature changes or dominance is lost.
## Speed bands are 0–400 / 400–700 / 700–1000 / 1000+ px/s. Edges belong to
## the upper band (400 is band 2, 700 is band 3, 1000 is band 4).

const WINDOW := 10.0
const DOMINANCE := 0.7
const CADENCE := 5.0
const DROP := 0.1
const RECOVER := 0.2
const FLOOR_MUL := 0.4
const ANGLE_BUCKETS := 24
## Upper edges of the first three speed bands; anything at or above the last
## edge is band 3. Units: px/s.
const SPEED_EDGES: Array[float] = [400.0, 700.0, 1000.0]

var enabled := true
var multiplier := 1.0
var _clock := 0.0
var _cadence := 0.0
var _decaying := false
## Packed as (time, signature_id). signature_id = angle_bucket * 4 + speed_band.
var _hit_time: PackedFloat32Array = PackedFloat32Array()
var _hit_sig: PackedInt32Array = PackedInt32Array()


func reset() -> void:
	multiplier = 1.0
	_clock = 0.0
	_cadence = 0.0
	_decaying = false
	_hit_time = PackedFloat32Array()
	_hit_sig = PackedInt32Array()


func advance(delta: float) -> void:
	if delta <= 0.0:
		return
	_clock += delta
	_trim()
	if not enabled:
		multiplier = 1.0
		_cadence = 0.0
		_decaying = false
		return
	var decaying := _is_dominated()
	if decaying != _decaying:
		_cadence = 0.0
		_decaying = decaying
	_cadence += delta
	while _cadence >= CADENCE:
		_cadence -= CADENCE
		if _decaying:
			multiplier = maxf(FLOOR_MUL, multiplier - DROP)
		else:
			multiplier = minf(1.0, multiplier + RECOVER)


func record_hit(velocity: Vector2) -> void:
	_trim()
	_hit_time.append(_clock)
	_hit_sig.append(signature_id(velocity))


func scale(amount: float) -> float:
	if not enabled:
		return amount
	return amount * multiplier


static func angle_bucket(angle: float) -> int:
	var step := TAU / float(ANGLE_BUCKETS)
	var wrapped := wrapf(angle, 0.0, TAU)
	var bucket := int(floorf(wrapped / step))
	return clampi(bucket, 0, ANGLE_BUCKETS - 1)


static func speed_band(speed: float) -> int:
	# Edges belong to the upper band: 400 is band 2 (index 1), not band 1.
	var s := maxf(speed, 0.0)
	for i in SPEED_EDGES.size():
		if s < SPEED_EDGES[i]:
			return i
	return SPEED_EDGES.size()


func hit_count() -> int:
	return _hit_sig.size()


func last_signature() -> int:
	if _hit_sig.is_empty():
		return -1
	return _hit_sig[_hit_sig.size() - 1]


static func signature_id(velocity: Vector2) -> int:
	return angle_bucket(velocity.angle()) * 4 + speed_band(velocity.length())


func _is_dominated() -> bool:
	var n := _hit_sig.size()
	if n <= 0:
		return false
	var counts := PackedInt32Array()
	counts.resize(ANGLE_BUCKETS * 4)
	var best := 0
	for i in n:
		var id := _hit_sig[i]
		if id < 0 or id >= counts.size():
			continue
		counts[id] += 1
		if counts[id] > best:
			best = counts[id]
	return float(best) / float(n) > DOMINANCE


func _trim() -> void:
	var cut := _clock - WINDOW
	var drop := 0
	while drop < _hit_time.size() and _hit_time[drop] < cut:
		drop += 1
	if drop <= 0:
		return
	var kept_t := PackedFloat32Array()
	var kept_s := PackedInt32Array()
	kept_t.resize(_hit_time.size() - drop)
	kept_s.resize(_hit_sig.size() - drop)
	for i in kept_t.size():
		kept_t[i] = _hit_time[drop + i]
		kept_s[i] = _hit_sig[drop + i]
	_hit_time = kept_t
	_hit_sig = kept_s
