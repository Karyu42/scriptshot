class_name DashState
extends RefCounted
## The dash state machine: cooldown, active burst and its direction, no nodes.
## Player owns one and feeds it the tuning from its exports each time it starts
## a dash, so changing an export at runtime takes effect on the next dash.
##
## Timing is in physics-tick seconds. The cooldown is measured from the moment
## the dash *starts* (1.5 s total, so with the 0.2 s burst there is 1.3 s of
## running between dashes).

## Burst length in seconds and distance covered in pixels.
## Timers within this many seconds of expiring count as expired (float residue).
const EPSILON := 0.000001

var duration := 0.2
var distance := 160.0
## Curve shape (see DashMath) and the speed the burst blends back into.
var curve_power := 2.0
var exit_speed := 300.0
## Seconds the player is invulnerable from the start of a dash.
var invulnerable_time := 0.2
## Seconds from the start of one dash until the next may start.
var cooldown := 1.5

var active := false
var direction := Vector2.ZERO
## Seconds since the dash started.
var elapsed := 0.0
## Seconds until a new dash may start (0 = ready).
var cooldown_left := 0.0
## Set for the single step() in which the burst ended.
var just_finished := false


func is_ready() -> bool:
	return not active and cooldown_left <= 0.0


## Starts a dash along `dir` (any non-zero finite vector). Returns false, and
## does nothing, while dashing, on cooldown, or for a zero / non-finite `dir`.
func start(dir: Vector2) -> bool:
	if not is_ready() or not dir.is_finite() or dir.length_squared() < 0.000001:
		return false
	direction = dir.normalized()
	active = true
	elapsed = 0.0
	cooldown_left = cooldown
	just_finished = false
	return true


## Counts the cooldown down by `delta`.
func tick_cooldown(delta: float) -> void:
	if is_finite(delta) and delta > 0.0:
		cooldown_left = maxf(cooldown_left - delta, 0.0)
		if cooldown_left < EPSILON:
			cooldown_left = 0.0


## Advances the burst by `delta` and returns the velocity to move with this tick:
## the exact average velocity over the tick, so the displacement matches the
## curve whatever the tick length. Returns Vector2.ZERO when no dash is active.
## Does not touch the cooldown (see tick_cooldown()).
func advance(delta: float) -> Vector2:
	just_finished = false
	if not active or not is_finite(delta) or delta <= 0.0:
		return Vector2.ZERO
	var t0 := elapsed
	elapsed += delta
	var moved := (
		DashMath.distance_at(elapsed, distance, duration, exit_speed, curve_power)
		- DashMath.distance_at(t0, distance, duration, exit_speed, curve_power)
	)
	if elapsed >= duration - EPSILON:
		active = false
		just_finished = true
	return direction * (moved / delta)


## tick_cooldown() + advance(): one call per physics tick when nothing needs to
## happen in between.
func step(delta: float) -> Vector2:
	tick_cooldown(delta)
	return advance(delta)


## 0..1 progress of the burst, 1 when not dashing.
func progress() -> float:
	return clampf(elapsed / duration, 0.0, 1.0) if active else 1.0


## Back to idle and ready (respawn).
func reset() -> void:
	active = false
	elapsed = 0.0
	cooldown_left = 0.0
	just_finished = false
