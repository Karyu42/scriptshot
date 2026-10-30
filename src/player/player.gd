class_name Player
extends CharacterBody2D
## Twin-stick player: left stick / WASD moves with acceleration and friction,
## right stick / mouse aims, fire input drives a ShotPattern through a
## ShotEmitter. The player knows nothing about how bullets are simulated.

signal damaged(amount: float)

@export_group("Movement")
@export var max_speed := 300.0
## px/s^2 while input is held. 300 / 2400 = full speed in 0.125 s.
@export var acceleration := 2400.0
## px/s^2 braking with no input. 300 / 2000 = stop in 0.15 s.
@export var friction := 2000.0
## Extra acceleration multiplier when pushing against the current velocity.
@export var reverse_boost := 1.6

@export_group("Aiming")
@export var muzzle_offset := 20.0

## Injected by the scene (Main): where shots go, and what to fire.
var emitter: ShotEmitter
var weapon: ShotPattern = BasicShot.new()

## Unit vector the player is aiming along, and the world point being aimed at.
var aim_direction := Vector2.RIGHT
var aim_point := Vector2.ZERO

var _prev_position := Vector2.ZERO
var _cooldown := FireCooldown.new()
var _time := 0.0
var _shot_index := 0
var _flash := 0.0
var _context := ShotContext.new()

@onready var _hurtbox: Hurtbox = $Hurtbox


func _ready() -> void:
	_hurtbox.hit.connect(_on_hit)
	aim_point = global_position + aim_direction * 100.0
	_prev_position = global_position


func _physics_process(delta: float) -> void:
	_time += delta
	_prev_position = global_position
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = MovementMath.step_velocity(
		velocity, move_input, max_speed, acceleration, friction, reverse_boost, delta
	)
	move_and_slide()

	_update_aim()
	if _cooldown.update(delta, Input.is_action_pressed("fire"), weapon.fire_interval if weapon != null else 0.0):
		_fire()

	_flash = maxf(_flash - delta * 6.0, 0.0)
	queue_redraw()


## Where the player is *drawn* this frame (2D has no get_global_transform_interpolated,
## so we interpolate between the last two physics positions ourselves). Use it
## for cameras and UI that must track the visible body; gameplay uses
## global_position.
func get_render_position() -> Vector2:
	return _prev_position.lerp(global_position, Engine.get_physics_interpolation_fraction())


## Spawn position, aim and context for a shot are computed here, then handed to
## the weapon; the weapon decides what bullets that means.
func _fire() -> void:
	if emitter == null or weapon == null:
		return
	_context.muzzle_position = AimMath.muzzle(global_position, aim_direction, muzzle_offset)
	_context.aim_direction = aim_direction
	_context.aim_angle = aim_direction.angle()
	_context.shooter_velocity = velocity
	_context.target_mask = Layers.ENEMY
	_context.time = _time
	_context.shot_index = _shot_index
	_shot_index += 1
	weapon.fire(_context, emitter)


func _update_aim() -> void:
	if InputDevice.is_gamepad():
		# The deadzone is applied exactly once, by Input.get_vector() using the
		# `aim_*` actions' deadzones from the input map (it also rescales the
		# result so it starts at 0 outside the deadzone).
		var stick := Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down")
		aim_direction = AimMath.direction_from_stick(stick, aim_direction)
		aim_point = global_position + aim_direction * 220.0
	else:
		var viewport := get_viewport()
		update_mouse_aim(viewport.get_mouse_position(), viewport.get_canvas_transform() * get_render_position())


## Mouse aiming from the cursor's offset to the ship *on screen*: both points are
## in viewport pixels, `body_screen` being where the ship is currently drawn.
## Using the screen-space offset keeps the camera out of the loop, so the camera's
## aim look-ahead (which leans toward the aim direction) cannot feed back into
## the aim, whatever the camera's position, smoothing lag or shake is.
func update_mouse_aim(mouse_screen: Vector2, body_screen: Vector2) -> void:
	var offset := mouse_screen - body_screen
	# The canvas transform only translates and scales uniformly (no camera
	# rotation), so this offset is the world offset up to the zoom factor.
	var zoom := get_viewport().get_canvas_transform().get_scale().x
	aim_direction = AimMath.direction_from_screen_offset(offset, aim_direction)
	aim_point = global_position + offset / maxf(zoom, 0.0001)


func _on_hit(damage: float, _hit_position: Vector2, _bullet_velocity: Vector2) -> void:
	_flash = 1.0
	damaged.emit(damage)


func _draw() -> void:
	var body := Color("e8e8f0").lerp(Color.WHITE, _flash)
	draw_circle(Vector2.ZERO, 14.0, body)
	draw_circle(Vector2.ZERO, 7.0, Color("4cc9f0"))
	# Barrel pointing along the aim direction (the node itself never rotates).
	var tip := aim_direction * 20.0
	draw_line(aim_direction * 8.0, tip, Color("4cc9f0"), 5.0)
