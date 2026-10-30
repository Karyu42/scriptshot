class_name Player
extends CharacterBody2D
## Twin-stick player: left stick / WASD moves with acceleration and friction,
## right stick / mouse aims, fire input drives a ShotPattern through a
## ShotEmitter. The player knows nothing about how bullets are simulated.

## Forwarded from the Health component.
signal damaged(amount: float)
signal died

@export_group("Movement")
@export var max_speed := 300.0
## px/s^2 while input is held. 300 / 2400 = full speed in 0.125 s.
@export var acceleration := 2400.0
## px/s^2 braking with no input. 300 / 2000 = stop in 0.15 s.
@export var friction := 2000.0
## Extra acceleration multiplier when pushing against the current velocity.
@export var reverse_boost := 1.6

@export_group("Dash")
## Distance covered by one dash, in pixels (must be at least max_speed *
## dash_duration, see DashMath).
@export var dash_distance := 170.0
## Burst length in seconds.
@export var dash_duration := 0.18
## Speed curve: 0 = constant speed, 1 = linear ramp down, 2 = hard launch with a
## long tail (default), higher = sharper launch. See DashMath.
@export var dash_curve_power := 2.0
## Seconds of invulnerability from the start of a dash.
@export var dash_invulnerability := 0.2
## Seconds from the start of a dash until the next one may start.
@export var dash_cooldown := 1.5

@export_group("Aiming")
@export var muzzle_offset := 20.0

## Injected by the scene (Main): where shots go, and what to fire.
var emitter: ShotEmitter
var weapon: ShotPattern = BasicShot.new()

## Validated read/write access for scripts (hp, invulnerability, position,
## velocity, dash state). See PlayerState.
var state := PlayerState.new(self)

## Emitted when a dash starts, with its unit direction.
signal dashed(direction: Vector2)

## Unit vector the player is aiming along, and the world point being aimed at.
var aim_direction := Vector2.RIGHT
var aim_point := Vector2.ZERO

var _prev_position := Vector2.ZERO
var _trigger := TriggerState.new()
var _dead := false
var _dash := DashState.new()
var _cooldown := FireCooldown.new()
var _time := 0.0
var _shot_index := 0
var _flash := 0.0
var _context := ShotContext.new()

@onready var _hurtbox: Hurtbox = $Hurtbox
## Hit points, i-frames and regeneration (Health).
@onready var health: Health = $Health


func _ready() -> void:
	_hurtbox.hit.connect(_on_hit)
	health.damaged.connect(_on_health_damaged)
	health.died.connect(_on_died)
	health.invulnerability_changed.connect(_on_invulnerability_changed)
	aim_point = global_position + aim_direction * 100.0
	_prev_position = global_position


func _physics_process(delta: float) -> void:
	if _dead:
		return
	_time += delta
	_prev_position = global_position
	var move_input := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	if Input.is_action_just_pressed("dash"):
		try_dash(move_input)
	if _dash.active:
		velocity = _dash.step(delta)
	else:
		_dash.step(delta)
		velocity = MovementMath.step_velocity(
			velocity, move_input, max_speed, acceleration, friction, reverse_boost, delta
		)
	move_and_slide()
	if _dash.just_finished:
		# Hand over to normal movement at running speed, not at the burst's speed.
		velocity = velocity.limit_length(max_speed)

	_update_aim()
	_trigger.update(Input.is_action_pressed("fire"), delta)
	_update_weapon(delta)
	var autofire := _trigger.pressed and weapon != null and weapon.auto_fire
	if _cooldown.update(delta, autofire, weapon.fire_interval if weapon != null else 0.0):
		_fire()

	_flash = maxf(_flash - delta * 6.0, 0.0)
	queue_redraw()


## Where the player is *drawn* this frame (2D has no get_global_transform_interpolated,
## so we interpolate between the last two physics positions ourselves). Use it
## for cameras and UI that must track the visible body; gameplay uses
## global_position.
func get_render_position() -> Vector2:
	return _prev_position.lerp(global_position, Engine.get_physics_interpolation_fraction())


## Refreshes the ShotContext (muzzle, aim, trigger state) and gives the weapon its
## per-tick update(). Runs every physics tick, before any fire().
func _update_weapon(delta: float) -> void:
	if emitter == null or weapon == null:
		return
	_context.muzzle_position = AimMath.muzzle(global_position, aim_direction, muzzle_offset)
	_context.aim_direction = aim_direction
	_context.aim_angle = aim_direction.angle()
	_context.shooter_velocity = velocity
	_context.target_mask = Layers.hostile_to(Layers.PLAYER)
	_context.time = _time
	_trigger.apply_to(_context)
	weapon.update(_context, emitter, delta)


## Asks the weapon for a shot using the context from _update_weapon().
func _fire() -> void:
	if emitter == null or weapon == null:
		return
	_context.shot_index = _shot_index
	_shot_index += 1
	weapon.fire(_context, emitter)


## Starts a dash along `direction` (need not be normalised); a zero direction
## falls back to the aim direction, so standing still dashes toward where you
## aim. Returns false while dead, dashing or on cooldown. The dash makes the
## player invulnerable for `dash_invulnerability` seconds.
func try_dash(direction: Vector2 = Vector2.ZERO) -> bool:
	if _dead:
		return false
	var dir := direction if direction.is_finite() and direction.length_squared() > 0.0001 else aim_direction
	_dash.duration = maxf(dash_duration, 0.01)
	_dash.distance = maxf(dash_distance, 0.0)
	_dash.curve_power = maxf(dash_curve_power, 0.0)
	_dash.exit_speed = max_speed
	_dash.invulnerable_time = maxf(dash_invulnerability, 0.0)
	_dash.cooldown = maxf(dash_cooldown, 0.0)
	if not _dash.start(dir):
		return false
	health.set_invulnerable(_dash.invulnerable_time)
	dashed.emit(_dash.direction)
	return true


func is_dashing() -> bool:
	return _dash.active


func is_dead() -> bool:
	return _dead


## Seconds until the next dash may start (0 = ready).
func get_dash_cooldown_left() -> float:
	return _dash.cooldown_left


func get_dash_direction() -> Vector2:
	return _dash.direction


## Moves the player to `at` instantly: no interpolated smear between the old and
## new place, and the camera sees the jump as a cut of the render position.
func teleport(at: Vector2) -> void:
	global_position = at
	_prev_position = at
	reset_physics_interpolation()


## Back in the fight at `at` with everything kept (bullets, enemies, weapon) but
## hp reset to max_hp, dash ready, no i-frames.
func respawn(at: Vector2) -> void:
	_dead = false
	teleport(at)
	velocity = Vector2.ZERO
	_dash.reset()
	health.reset()
	_hurtbox.active = true
	show()


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
	health.damage(damage)


func _on_health_damaged(amount: float, _hp: float) -> void:
	_flash = 1.0
	damaged.emit(amount)


## Bullets pass through the player while it is invulnerable instead of being
## wasted on it.
func _on_invulnerability_changed(active: bool) -> void:
	_hurtbox.active = not active and not _dead


func _on_died() -> void:
	_dead = true
	_hurtbox.active = false
	hide()
	died.emit()


func _draw() -> void:
	var body := Color("e8e8f0").lerp(Color.WHITE, _flash)
	if health != null and health.is_invulnerable() and int(_time * 20.0) % 2 == 0:
		body.a = 0.45
	if _dash.active:
		# Fading echoes behind the burst.
		for k in range(1, 4):
			draw_circle(-_dash.direction * (k * 15.0), 14.0 - k * 2.0, Color(0.3, 0.79, 0.94, 0.4 - k * 0.1))
	draw_circle(Vector2.ZERO, 14.0, body)
	draw_circle(Vector2.ZERO, 7.0, Color("4cc9f0"))
	# Barrel pointing along the aim direction (the node itself never rotates).
	var tip := aim_direction * 20.0
	draw_line(aim_direction * 8.0, tip, Color("4cc9f0"), 5.0)
