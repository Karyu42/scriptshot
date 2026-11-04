class_name DashMath
extends RefCounted
## Pure maths of the dash's speed curve, kept free of nodes so it can be tested
## and tuned in isolation.
##
## The dash is a short burst that decelerates smoothly into normal running speed:
##
##   speed(t) = exit_speed + (peak - exit_speed) * (1 - t/duration)^power
##
## `power` shapes the burst: 0 = constant speed, 1 = linear ramp down, 2
## (default) = hard launch with a long tail, higher = sharper launch. The peak is
## solved so the integral of speed over `duration` is exactly `distance`:
##
##   peak = exit_speed + (distance - exit_speed * duration) * (power + 1) / duration
##
## which needs distance >= exit_speed * duration to launch above running speed
## (the defaults do: 160 px vs 60 px). Because the distance is known in closed
## form (distance_at), per-tick displacement is exact for any tick length.
##
## A dash can never be slower than running. If the running speed is so high that
## exit_speed * duration exceeds `distance` (800 px/s with the defaults, e.g. a
## script calling PlayerState.set_speed(1000)), the burst degenerates into a
## constant-speed dash at running speed that covers exit_speed * duration, i.e.
## more than `distance` (see effective_distance()) instead of the curve dipping
## below running speed or collapsing to a standstill.


## The distance the burst really covers: `distance`, or exit_speed * duration when
## running is faster than the tuned dash.
static func effective_distance(distance: float, duration: float, exit_speed: float) -> float:
	return maxf(distance, exit_speed * duration)


static func peak_speed(distance: float, duration: float, exit_speed: float, power: float) -> float:
	var covered := effective_distance(distance, duration, exit_speed)
	return maxf(exit_speed + (covered - exit_speed * duration) * (power + 1.0) / duration, 0.0)


## Speed (px/s) `t` seconds into the dash. Past the end it is exit_speed.
static func speed_at(t: float, distance: float, duration: float, exit_speed: float, power: float) -> float:
	if t >= duration:
		return exit_speed
	var peak := peak_speed(distance, duration, exit_speed, power)
	var remaining := 1.0 - maxf(t, 0.0) / duration
	return exit_speed + (peak - exit_speed) * pow(remaining, power)


## Distance (px) covered between the start and `t` seconds in. Reaches exactly
## effective_distance() (= `distance` unless running is faster) at t = duration.
static func distance_at(t: float, distance: float, duration: float, exit_speed: float, power: float) -> float:
	var clamped := clampf(t, 0.0, duration)
	var peak := peak_speed(distance, duration, exit_speed, power)
	var remaining := 1.0 - clamped / duration
	return (
		exit_speed * clamped
		+ (peak - exit_speed) * duration / (power + 1.0) * (1.0 - pow(remaining, power + 1.0))
	)
