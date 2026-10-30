class_name AimMath
extends RefCounted
## Pure aiming helpers shared by gamepad and mouse aiming.


## Aim direction from a right-stick vector. Inside the deadzone the previous
## direction is kept, so releasing the stick does not snap the aim anywhere.
static func direction_from_stick(stick: Vector2, previous: Vector2, deadzone: float = 0.25) -> Vector2:
	if stick.length() >= deadzone:
		return stick.normalized()
	return previous


## Aim direction from `origin` toward a world-space point (the mouse cursor).
## Keeps `previous` when the point is on top of the origin.
static func direction_to_point(origin: Vector2, point: Vector2, previous: Vector2) -> Vector2:
	var d := point - origin
	if d.length_squared() < 1.0:
		return previous
	return d.normalized()


## Muzzle position: `offset` pixels from `origin` along `direction`.
static func muzzle(origin: Vector2, direction: Vector2, offset: float) -> Vector2:
	return origin + direction * offset
