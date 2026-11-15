class_name Player
extends CharacterBody2D
## Twin-stick player: left stick / WASD moves with acceleration and friction,
## right stick / mouse aims, fire input drives a ShotPattern through a
## ShotEmitter. The player knows nothing about how bullets are simulated.

## Length of one blink step during i-frames (pillars 5.4: 62 ms).
const BLINK_STEP := 0.062

## Forwarded from the Health component.
signal damaged(amount: float)
signal died
## Emitted at the end of respawn(), after hp and dash have been reset.
signal respawned(at: Vector2)

@export_group("Movement")
@export var max_speed := 300.0
## px/s^2 while input is held. 300 / 2400 = full speed in 0.125 s.
@export var acceleration := 2400.0
## px/s^2 braking with no input. 300 / 2000 = stop in 0.15 s.
@export var friction := 2000.0
## Extra acceleration multiplier when pushing against the current velocity.
@export var reverse_boost := 1.6

@export_group("Dash")
## Distance covered by one dash, in pixels. A dash is never slower than running:
## if max_speed * dash_duration is larger (max_speed above 800 px/s with the
## defaults) the dash covers that distance instead, see DashMath.
@export var dash_distance := 160.0
## Burst length in seconds.
@export var dash_duration := 0.2
## Speed curve: 0 = constant speed, 1 = linear ramp down, 2 = hard launch with a
## long tail (default), higher = sharper launch. See DashMath.
@export var dash_curve_power := 2.0
## Seconds of invulnerability from the start of a dash.
@export var dash_invulnerability := 0.2
## Seconds from the start of a dash until the next one may start.
@export var dash_cooldown := 1.5
## Input buffer: a dash pressed while dashing or on cooldown is remembered for this
## many seconds and fires the moment it becomes available. 0 = no buffering.
@export var dash_buffer_time := 0.1

@export_group("Aiming")
@export var muzzle_offset := 20.0

## Injected by the scene (Main): where shots go, and what to fire.
var emitter: ShotEmitter
var weapon: ShotPattern = BasicShot.new()
## True while a UI owns the keyboard (the script editor): no move, dash, aim
## or fire input is read. The world keeps running.
var input_blocked := false

## Validated read/write access for scripts (hp, invulnerability, position,
## velocity, dash state). See PlayerState.
var state := PlayerState.new(self)

## Emitted when a dash starts, with its unit direction.
signal dashed(direction: Vector2)
## Emitted on the physics tick the dash burst ends, after that tick's movement.
signal dash_finished
## Emitted when the player is moved discontinuously (teleport, respawn): the
## camera snaps to it instead of gliding.
signal teleported(position: Vector2)

## Unit vector the player is aiming along, and the world point being aimed at.
var aim_direction := Vector2.RIGHT
var aim_point := Vector2.ZERO

var _prev_position := Vector2.ZERO
var _trigger := TriggerState.new()
var _dead := false
var _dash := DashState.new()
## A dash press waiting for the dash to become available, and how long it keeps.
var _dash_wanted := false
var _dash_buffer_left := 0.0
var _cooldown := FireCooldown.new()
## Optional scripted dash (null = built-in). See set_dash_ability().
## A separate flag is required because a freed Object compares equal to null.
var _dash_ability: Object = null
var _has_dash_ability := false
## Slot cooldown duration from ability.get_cooldown(), or dash_cooldown.
var _ability_cooldown := 0.0
var _ability_cooldown_left := 0.0
## Set when perform_builtin_dash emits `dashed` during a try_dash ability call,
## so a true return does not emit the signal a second time.
var _dashed_this_try := false
## True while ability.on_dash is on the stack. Nested slot calls return false;
## perform_builtin_dash is still allowed.
var _in_on_dash := false
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
	health.engine_invulnerability_changed.connect(_on_engine_invulnerability_changed)
	aim_point = global_position + aim_direction * 100.0
	_prev_position = global_position


func _physics_process(delta: float) -> void:
	if _dead:
		return
	_time += delta
	_prev_position = global_position
	var move_input := Vector2.ZERO if input_blocked else Input.get_vector("move_left", "move_right", "move_up", "move_down")
	# Cooldown first, so a dash that becomes available this tick can start now.
	_dash.tick_cooldown(delta)
	_tick_ability_cooldown(delta)
	if not input_blocked and Input.is_action_just_pressed("dash"):
		request_dash()
	if _dash_wanted:
		_update_dash_buffer(move_input, delta)
	if _dash.active:
		velocity = _dash.advance(delta)
	else:
		_dash.advance(delta)
		velocity = MovementMath.step_velocity(
			velocity, move_input, max_speed, acceleration, friction, reverse_boost, delta
		)
	move_and_slide()
	if _dash.just_finished:
		# Hand over to normal movement at running speed, not at the burst's speed.
		velocity = velocity.limit_length(max_speed)
		dash_finished.emit()

	if not input_blocked:
		_update_aim()
	_trigger.update(not input_blocked and Input.is_action_pressed("fire"), delta)
	_update_weapon(delta)
	var autofire := _trigger.pressed and weapon != null and weapon.auto_fire
	var shots := _cooldown.update(delta, autofire, weapon.fire_interval if weapon != null else 0.0)
	for _shot in shots:
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
##
## When a dash ability is set, this is the input/buffer entry point: the slot
## cooldown (ability.get_cooldown(), or dash_cooldown) gates the call to
## `ability.on_dash(player, direction) -> bool`. True counts as a dash (slot
## cooldown starts, `dashed` emitted with the direction used). False, a
## non-bool return, a thrown error, or a freed ability leaves the buffer
## waiting. Engine motion and i-frames come only from perform_builtin_dash().
##
## on_dash must return a bool synchronously. Do not await: a coroutine
## (GDScriptFunctionState) or any non-bool is treated as false and warns once.
## A nested try_dash / slot call from inside on_dash returns false;
## perform_builtin_dash is still allowed. The false path may run on every
## physics tick while a press is buffered; keep it free of side effects.
func try_dash(direction: Vector2 = Vector2.ZERO) -> bool:
	if _dead:
		return false
	var dir := _resolve_dash_direction(direction)
	if _has_dash_ability:
		if _in_on_dash:
			return false
		return _try_ability_dash(dir)
	return perform_builtin_dash(dir)


## The current built-in dash motion (burst, engine cooldown, engine i-frames,
## `dashed` signal). A scripted ability calls this for the engine dash without
## going back through try_dash. Returns false while dead, mid-burst, or while
## the engine dash_cooldown is active: a shorter file cooldown cannot chain
## i-frames faster than dash_cooldown.
func perform_builtin_dash(direction: Vector2 = Vector2.ZERO) -> bool:
	if _dead:
		return false
	var dir := _resolve_dash_direction(direction)
	_dash.duration = maxf(dash_duration, 0.01)
	_dash.distance = maxf(dash_distance, 0.0)
	_dash.curve_power = maxf(dash_curve_power, 0.0)
	_dash.exit_speed = max_speed
	_dash.invulnerable_time = maxf(dash_invulnerability, 0.0)
	_dash.cooldown = maxf(dash_cooldown, 0.0)
	if not _dash.start(dir):
		return false
	health.add_engine_invulnerability(_dash.invulnerable_time)
	dashed.emit(_dash.direction)
	_dashed_this_try = true
	return true


## Equips a scripted dash, or null to restore the built-in dash. Reads an
## optional ability.get_cooldown() -> float (finite, clamped to >= 0; otherwise
## dash_cooldown). Input, the buffer, death, and cooldown gating stay here.
func set_dash_ability(ability: Object) -> void:
	# Explicit null restores the built-in dash. The engine rejects a freed
	# Object at the call site (typed argument), so this path does not see one.
	# A reference that is later freed is still treated as "ability set" via
	# _has_dash_ability; try_dash then fails closed.
	if ability == null:
		_dash_ability = null
		_has_dash_ability = false
	else:
		_dash_ability = ability
		_has_dash_ability = true
	refresh_dash_ability()


## Re-reads ability.get_cooldown() (hot reload). The remaining slot cooldown
## is left as-is; the new duration applies to the next successful on_dash.
func refresh_dash_ability() -> void:
	_ability_cooldown = maxf(dash_cooldown, 0.0)
	if _dash_ability == null:
		return
	if not is_instance_valid(_dash_ability):
		ScriptWarnings.warn(
			"Player.dash_ability",
			"Player.refresh_dash_ability(): dash ability is no longer valid; using dash_cooldown"
		)
		return
	if not _dash_ability.has_method("get_cooldown"):
		return
	var raw: Variant = _dash_ability.call("get_cooldown")
	var parsed := _parse_ability_cooldown(raw)
	if parsed < 0.0:
		ScriptWarnings.warn(
			"Player.dash_ability",
			"Player.refresh_dash_ability(): get_cooldown() must return a finite number; using dash_cooldown"
		)
		return
	_ability_cooldown = parsed


func _parse_ability_cooldown(raw: Variant) -> float:
	# < 0 means "invalid / use default". 0 is a legal cooldown (no slot wait).
	var value := 0.0
	var ok := false
	@warning_ignore_start("unsafe_call_argument", "unsafe_cast")
	if typeof(raw) == TYPE_INT or typeof(raw) == TYPE_FLOAT:
		value = float(raw)
		ok = true
	@warning_ignore_restore("unsafe_call_argument", "unsafe_cast")
	if not ok or not is_finite(value):
		return -1.0
	return maxf(value, 0.0)


func _resolve_dash_direction(direction: Vector2) -> Vector2:
	if direction.is_finite() and direction.length_squared() > 0.0001:
		return direction
	return aim_direction


func _tick_ability_cooldown(delta: float) -> void:
	if is_finite(delta) and delta > 0.0:
		_ability_cooldown_left = maxf(_ability_cooldown_left - delta, 0.0)
		if _ability_cooldown_left < DashState.EPSILON:
			_ability_cooldown_left = 0.0


func _try_ability_dash(dir: Vector2) -> bool:
	if _in_on_dash:
		return false
	if _ability_cooldown_left > 0.0:
		return false
	# Capture before on_dash: a swap inside the hook must not change this dash's wait.
	var slot_cooldown := _ability_cooldown
	_dashed_this_try = false
	_in_on_dash = true
	var accepted := _call_dash_ability(dir)
	_in_on_dash = false
	if _dead:
		return false
	# A successful perform_builtin_dash consumes the press even if on_dash
	# then returns false or errors, so the buffer is not retried next tick.
	if not accepted and not _dashed_this_try:
		return false
	_ability_cooldown_left = slot_cooldown
	if accepted and not _dashed_this_try:
		var used := dir
		if not used.is_finite() or used.length_squared() <= 0.0001:
			used = aim_direction
		if used.is_finite() and used.length_squared() > 0.0001:
			dashed.emit(used.normalized())
		else:
			dashed.emit(Vector2.RIGHT)
	return true


func _call_dash_ability(dir: Vector2) -> bool:
	if _dash_ability == null or not is_instance_valid(_dash_ability):
		ScriptWarnings.warn(
			"Player.dash_ability",
			"Player.try_dash(): dash ability is no longer valid"
		)
		return false
	if not _dash_ability.has_method("on_dash"):
		ScriptWarnings.warn(
			"Player.dash_ability",
			"Player.try_dash(): dash ability has no on_dash() method"
		)
		return false
	# call() so a runtime error in the ability does not abort the player;
	# a failed or non-bool result is treated as false (buffer keeps waiting).
	var raw: Variant = _dash_ability.call("on_dash", self, dir)
	if typeof(raw) != TYPE_BOOL:
		var message := "Player.try_dash(): on_dash() must return a bool"
		if _is_coroutine_state(raw):
			message = "Player.try_dash(): on_dash() must return synchronously; an await is treated as false"
		ScriptWarnings.warn("Player.dash_ability", message)
		return false
	@warning_ignore_start("unsafe_cast")
	var accepted: bool = raw
	@warning_ignore_restore("unsafe_cast")
	return accepted



static func _is_coroutine_state(raw: Variant) -> bool:
	# GDScriptFunctionState exists at runtime but is not a named type in scope.
	if typeof(raw) != TYPE_OBJECT:
		return false
	@warning_ignore_start("unsafe_cast")
	var obj: Object = raw
	@warning_ignore_restore("unsafe_cast")
	return obj != null and obj.is_class("GDScriptFunctionState")


## A dash press: tried this tick, and if the dash is not available (cooling down
## or mid-dash) remembered for `dash_buffer_time` seconds so it fires the moment
## it becomes available. The input handler calls this on every `dash` press.
func request_dash() -> void:
	_dash_wanted = true
	_dash_buffer_left = maxf(dash_buffer_time, 0.0)


## Fires a pending dash press as soon as the dash is available, using the move
## direction of that moment; forgets it once the buffer window has passed.
func _update_dash_buffer(move_input: Vector2, delta: float) -> void:
	if try_dash(move_input):
		_dash_wanted = false
		return
	_dash_buffer_left -= delta
	if _dash_buffer_left < 0.0:
		_dash_wanted = false


## True while a dash press is waiting in the input buffer.
func has_buffered_dash() -> bool:
	return _dash_wanted


func is_dashing() -> bool:
	return _dash.active


func is_dead() -> bool:
	return _dead


## Seconds until the next engine dash may start (0 = ready). Independent of
## a scripted ability's slot cooldown.
func get_dash_cooldown_left() -> float:
	return _dash.cooldown_left


## Seconds until the dash slot may call on_dash again (0 = ready). With no
## ability set this is the engine cooldown.
func get_ability_cooldown_left() -> float:
	if _has_dash_ability:
		return _ability_cooldown_left
	return _dash.cooldown_left


func get_dash_direction() -> Vector2:
	return _dash.direction


## Moves the player to `at` instantly: no interpolated smear between the old and
## new place, and the camera sees the jump as a cut of the render position.
func teleport(at: Vector2) -> void:
	global_position = at
	_prev_position = at
	reset_physics_interpolation()
	teleported.emit(at)


## Back in the fight at `at` with everything kept (bullets, enemies, weapon) but
## hp reset to max_hp, dash ready, no engine i-frames. The fire button state, the
## fire cooldown and any weapon charge are reset, so a button released while dead
## cannot fire a stale (charged) shot. Script invulnerability persists (scripts own
## it).
func respawn(at: Vector2) -> void:
	_dead = false
	teleport(at)
	velocity = Vector2.ZERO
	_dash.reset()
	_dash_wanted = false
	_ability_cooldown_left = 0.0
	_trigger.reset()
	_cooldown.reset()
	if weapon != null:
		weapon.reset()
	health.reset()
	_hurtbox.active = true
	show()
	respawned.emit(at)


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
		# Note: get_render_position() uses the interpolation fraction of the last
		# rendered frame, which is slightly stale inside a physics tick (at most
		# one frame of the ship's motion, a few px at full speed). That is
		# negligible for aiming, and the camera is the other half of the
		# screen-space offset, so both stay consistent with what the player sees.
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
	# last_hit_flags says whether this bullet pierces the script invulnerability layer.
	health.damage(damage, _hurtbox.last_hit_flags)


func _on_health_damaged(amount: float, _hp: float) -> void:
	_flash = 1.0
	damaged.emit(amount)


## Bullets pass through the player during engine i-frames (hit, dash) instead of
## being wasted on it. Script invulnerability does not switch the hurtbox off:
## bullets that reach it are consumed and blocked there, which is what lets
## piercing attacks hit through that layer.
func _on_engine_invulnerability_changed(active: bool) -> void:
	_hurtbox.active = not active and not _dead


func _on_died() -> void:
	_dead = true
	_hurtbox.active = false
	hide()
	died.emit()
	GameEvents.player_died.emit()


func _draw() -> void:
	var body := Color("e8e8f0").lerp(Color.WHITE, _flash)
	# Blink during engine i-frames: 62 ms steps between full and 30% alpha.
	if health != null and health.is_engine_invulnerable() and int(_time / BLINK_STEP) % 2 == 0:
		body.a = 0.3
	if _dash.active:
		# Fading echoes behind the burst.
		for k in range(1, 4):
			draw_circle(-_dash.direction * (k * 15.0), 14.0 - k * 2.0, Color(0.3, 0.79, 0.94, 0.4 - k * 0.1))
	draw_circle(Vector2.ZERO, 14.0, body)
	draw_circle(Vector2.ZERO, 7.0, Color("4cc9f0"))
	# Barrel pointing along the aim direction (the node itself never rotates).
	var tip := aim_direction * 20.0
	draw_line(aim_direction * 8.0, tip, Color("4cc9f0"), 5.0)
