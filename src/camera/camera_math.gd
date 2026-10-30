class_name CameraMath
extends RefCounted
## Pure camera helpers so smoothing and shake can be unit tested.


## Frame-rate independent exponential smoothing factor: the fraction of the
## remaining distance to cover this frame. rate is roughly "1 / time constant".
static func smoothing_factor(rate: float, delta: float) -> float:
	return 1.0 - exp(-rate * delta)


static func follow(current: Vector2, target: Vector2, rate: float, delta: float) -> Vector2:
	return current.lerp(target, smoothing_factor(rate, delta))


## Screen-shake strength for a trauma value in [0, 1]. Squared so small trauma
## is subtle and big trauma is violent.
static func shake_strength(trauma: float) -> float:
	var t := clampf(trauma, 0.0, 1.0)
	return t * t
