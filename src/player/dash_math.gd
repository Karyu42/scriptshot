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
## (the defaults do: 170 px vs 54 px). Because the distance is known in closed
## form (distance_at), per-tick displacement is exact for any tick length.


static func peak_speed(distance: float, duration: float, exit_speed: float, power: float) -> float:
	return maxf(exit_speed + (distance - exit_speed * duration) * (power + 1.0) / duration, 0.0)


## Speed (px/s) `t` seconds into the dash. Past the end it is exit_speed.
static func speed_at(t: float, distance: float, duration: float, exit_speed: float, power: float) -> float:
	if t >= duration:
		return exit_speed
	var peak := peak_speed(distance, duration, exit_speed, power)
	var remaining := 1.0 - maxf(t, 0.0) / duration
	return exit_speed + (peak - exit_speed) * pow(remaining, power)


## Distance (px) covered between the start and `t` seconds in. Reaches exactly
## `distance` at t = duration (for a valid curve, see the header).
static func distance_at(t: float, distance: float, duration: float, exit_speed: float, power: float) -> float:
	var clamped := clampf(t, 0.0, duration)
	var peak := peak_speed(distance, duration, exit_speed, power)
	var remaining := 1.0 - clamped / duration
	return (
		exit_speed * clamped
		+ (peak - exit_speed) * duration / (power + 1.0) * (1.0 - pow(remaining, power + 1.0))
	)
