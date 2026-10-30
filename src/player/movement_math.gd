class_name MovementMath
extends RefCounted
## Pure movement helpers (no scene tree) so the feel can be unit tested.


## One tick of acceleration-based top-down movement.
##
## `input` is the move vector with length <= 1 (stick deflection or WASD).
## With input, velocity moves toward input * max_speed at `accel` px/s^2, boosted
## by `reverse_boost` when the target opposes the current velocity (so changing
## direction snaps instead of sliding). Without input, friction brakes to a stop.
## Velocity above max_speed (knockback, dashes) decays naturally the same way.
static func step_velocity(
	velocity: Vector2,
	input: Vector2,
	max_speed: float,
	accel: float,
	friction: float,
	reverse_boost: float,
	delta: float
) -> Vector2:
	if input.length_squared() > 0.0001:
		var target := input.limit_length(1.0) * max_speed
		var a := accel
		if velocity.dot(target) < 0.0:
			a *= reverse_boost
		return velocity.move_toward(target, a * delta)
	return velocity.move_toward(Vector2.ZERO, friction * delta)


## Seconds to reach full speed from rest with the given acceleration.
static func time_to_max_speed(max_speed: float, accel: float) -> float:
	return max_speed / accel


## Seconds to stop from full speed with the given friction.
static func time_to_stop(max_speed: float, friction: float) -> float:
	return max_speed / friction
