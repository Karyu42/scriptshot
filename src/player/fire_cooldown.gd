class_name FireCooldown
extends RefCounted
## Fire-rate limiter that carries the remainder between shots.
##
## The weapon can only fire on physics ticks, so a 0.11 s interval on a 60 Hz tick
## is 6.6 ticks. Resetting the timer to the interval after each shot would round
## that up to 7 ticks (about 5% too slow); instead the interval is *added* to
## whatever time was left over, so the long-run rate is exactly 1 / interval.
## Idle time is not banked beyond one tick, so holding the trigger after a pause
## fires one shot, not a burst.

## Seconds until the next shot is allowed; <= 0 means ready. Between 0 and
## -delta after an idle stretch.
var remaining := 0.0


## Advances the timer by one tick. Returns true if a shot is fired this tick
## (only when `trigger` is held); the caller then spawns the shot.
func update(delta: float, trigger: bool, interval: float) -> bool:
	remaining = maxf(remaining - delta, -delta)
	if trigger and remaining <= 0.0:
		remaining += maxf(interval, 0.0)
		return true
	return false


func reset() -> void:
	remaining = 0.0
