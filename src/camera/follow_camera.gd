class_name FollowCamera
extends Camera2D
## Smooth follow camera with aim look-ahead and trauma-based screen shake.
## Runs on the physics tick; Camera2D's built-in physics interpolation then
## renders it smoothly at any refresh rate (project setting
## physics/common/physics_interpolation).

@export var target: Node2D
## Smoothing speed (1/s). Higher = tighter. ~8 trails the player by ~1/8 s.
@export var follow_rate := 8.0
## How far the camera leans toward the aim direction, in pixels.
@export var look_ahead := 70.0
@export_group("Shake")
@export var max_shake_offset := Vector2(18.0, 14.0)
## Trauma lost per second.
@export var trauma_decay := 1.6

var trauma := 0.0

var _focus := Vector2.ZERO
var _noise := FastNoiseLite.new()
var _clock := 0.0


func _ready() -> void:
	process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	_noise.frequency = 1.0
	_noise.seed = 1337
	if target != null:
		_focus = _target_position()
		global_position = _focus


## Adds screen-shake trauma (0..1, clamped). Call from hit / explosion effects.
func add_trauma(amount: float) -> void:
	trauma = clampf(trauma + amount, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	if target == null:
		return
	_focus = CameraMath.follow(_focus, _target_position(), follow_rate, delta)
	global_position = _focus

	_clock += delta
	trauma = maxf(trauma - trauma_decay * delta, 0.0)
	var strength := CameraMath.shake_strength(trauma)
	if strength > 0.0:
		offset = Vector2(
			_noise.get_noise_2d(_clock * 45.0, 0.0) * max_shake_offset.x,
			_noise.get_noise_2d(0.0, _clock * 45.0 + 100.0) * max_shake_offset.y
		) * strength
	else:
		offset = Vector2.ZERO


func _target_position() -> Vector2:
	var pos := target.global_position
	if "aim_direction" in target:
		pos += (target.aim_direction as Vector2) * look_ahead
	return pos
