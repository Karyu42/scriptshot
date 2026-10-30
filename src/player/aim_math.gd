class_name AimMath
extends RefCounted
## Pure aiming helpers shared by gamepad and mouse aiming.


## Aim direction from a right-stick vector that already has its deadzone applied
## (Input.get_vector() does that using the action deadzones from the input map,
## so it must not be applied a second time here). A zero / near-zero vector
## keeps the previous direction, so releasing the stick does not snap the aim
## anywhere. Pass a `deadzone` only for raw, unprocessed stick values.
static func direction_from_stick(stick: Vector2, previous: Vector2, deadzone: float = 0.0) -> Vector2:
	if stick.length_squared() > 1e-8 and stick.length() >= deadzone:
		return stick.normalized()
	return previous


## Aim direction from `origin` toward a world-space point (the mouse cursor).
## Keeps `previous` when the point is on top of the origin.
static func direction_to_point(origin: Vector2, point: Vector2, previous: Vector2) -> Vector2:
	var d := point - origin
	if d.length_squared() < 1.0:
		return previous
	return d.normalized()


## Aim direction from the cursor-minus-ship offset in screen space. Keeps
## `previous` when the cursor is on top of the ship.
static func direction_from_screen_offset(offset: Vector2, previous: Vector2) -> Vector2:
	if offset.length_squared() < 1.0:
		return previous
	return offset.normalized()


## Muzzle position: `offset` pixels from `origin` along `direction`.
static func muzzle(origin: Vector2, direction: Vector2, offset: float) -> Vector2:
	return origin + direction * offset
