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
##
## An interval shorter than a tick fires several shots in one tick (the carried
## remainder pays for each), up to MAX_SHOTS_PER_TICK as a safety cap; shots of
## the same tick are all spawned at the same position. An interval of 0 or less
## means "once per tick".

## Upper bound on shots per tick (480 shots/s at 60 Hz).
const MAX_SHOTS_PER_TICK := 8

## Seconds until the next shot is allowed; <= 0 means ready. Between 0 and
## -delta after an idle stretch.
var remaining := 0.0


## Advances the timer by one tick and returns how many shots fire this tick (0
## unless `trigger` is held); the caller then spawns that many shots.
func update(delta: float, trigger: bool, interval: float) -> int:
	remaining = maxf(remaining - delta, -delta)
	if not trigger or remaining > 0.0:
		return 0
	if interval <= 0.0:
		return 1
	var shots := 0
	while remaining <= 0.0 and shots < MAX_SHOTS_PER_TICK:
		remaining += interval
		shots += 1
	return shots


func reset() -> void:
	remaining = 0.0
