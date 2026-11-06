class_name BulletLimits
extends RefCounted
## Engine-wide guard values for bullets. The pool clamps and rejects against
## these directly. NativeBackend passes MAX_SPEED into NativeBulletSim and
## applies the same clamps before a plain bullet is handed to C++. Do not copy
## the numbers into the extension.

## Bullet speed ceiling in px/s. A crash guard for absurd values (1e9, huge
## script writes), not a design limit: collision is swept, so even a bullet at
## the ceiling cannot tunnel. Every velocity write is clamped to it.
const MAX_SPEED := 4000.0
const MAX_SPEED_SQ := MAX_SPEED * MAX_SPEED

# Range guards for the other numeric fields of a bullet (crash guards like the
# speed ceiling, not design limits). A finite value outside its range is clamped
# to it; a NaN or inf is invalid and the shot is rejected (a live bullet that
# gets one from a hook is killed as DespawnReason.INVALID). The pool stores
# these as float32, so a "finite" double beyond ~3.4e38 would silently become inf:
# every bound here is far inside that.
## Collision/draw radius, px. The hurtbox grid's cell margin follows the largest
## live radius, so an unbounded radius would blind every other bullet.
const MAX_RADIUS := 256.0
## Seconds a bullet may live. Immortal bullets hold a slot of the cap forever.
const MAX_LIFETIME := 600.0
## |acceleration| in px/s^2 (the speed ceiling still applies on top).
const MAX_ACCELERATION := 1000000.0
## |turn_rate| in radians/s.
const MAX_TURN_RATE := 1000.0
## Damage per hit, 0..MAX_DAMAGE (a negative value would heal).
const MAX_DAMAGE := 1000.0
## |param_a|, |param_b|: script scratch values, only kept inside float32 range.
const MAX_PARAM := 1.0e30


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
