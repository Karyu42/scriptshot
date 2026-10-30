class_name BulletLimits
extends RefCounted
## Engine-wide guard values for bullets, in one place so the GDScript pool and
## the native backend share a single definition (the native side mirrors
## MAX_SPEED from here; there is no second number to keep in sync by hand).

## Bullet speed ceiling in px/s. A crash guard for absurd values (1e9, huge
## script writes), not a design limit: collision is swept, so even a bullet at
## the ceiling cannot tunnel. Every velocity write is clamped to it.
const MAX_SPEED := 4000.0
const MAX_SPEED_SQ := MAX_SPEED * MAX_SPEED


## `v` with its length limited to MAX_SPEED, direction kept. A vector already
## within the ceiling is returned unchanged. Non-finite input is the caller's
## business (check `v.is_finite()` first): this function does not repair it.
static func clamp_velocity(v: Vector2) -> Vector2:
	if v.length_squared() <= MAX_SPEED_SQ:
		return v
	# Scale by the largest component first so that components near 1e30 cannot
	# overflow the squared length (float32) and turn the direction into NaN.
	var m := maxf(absf(v.x), absf(v.y))
	return (v / m).normalized() * MAX_SPEED


## True if `v` was changed by clamp_velocity (it is over the ceiling).
static func exceeds(v: Vector2) -> bool:
	return not (v.length_squared() <= MAX_SPEED_SQ)
