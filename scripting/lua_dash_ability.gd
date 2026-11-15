class_name LuaDashAbility
extends RefCounted
## The Dash slot's ability (ability-scripting.md A1-A3): runs an ability
## file's `on_dash(ctx, dir)` through a ScriptHost under the same guard and
## budget as on_fire. This is the object the player's dash hook calls
## (Player.set_dash_ability, Gameplay Engineer):
##
##   * on_dash(player, direction) -> bool: called when a dash press fires and
##     the dash is off cooldown. true counts as a dash (the player starts its
##     cooldown and emits `dashed`), false means nothing happened and the
##     press stays buffered. Lua returning nil counts as true; false is false;
##     an error or a guard stop is false and is reported (ERROR_KEY,
##     last_error). After an error the hook rests for error_backoff_msec, so a
##     buffered press does not rerun a broken file every tick.
##   * get_cooldown() -> float: the file's `cooldown` field (clamped), else
##     the engine's dash_cooldown. The player reads it when the ability is
##     set and on refresh_dash_ability(), which apply() calls.
##
## A hook that yields (coroutine.yield() in on_dash itself) has started: on_dash
## returns true, and tick() resumes it once per physics tick with a fresh
## budget until it returns, errors, is stopped, or runs MAX_PENDING_TICKS
## (then it is dropped with a warning). While it is running, on_dash returns
## false, so the next dash waits for it. The player only ever gets a bool.
##
## Lua sees no engine object: no Player node, try_dash or request_dash. Its
## only way to the player is `player:dash(angle)`.
##
## Lua `player:dash(angle)` is the engine dash: perform_builtin_dash(dir)
## (0.2 s engine i-frames, gated by the engine dash cooldown, returns false
## while gated). Scripts cannot grant or extend engine i-frames any other way
## (A3). A file without on_dash dashes like the engine.
##
## apply() is the hot reload: the new file loads into a fresh env on the
## same host with a copy of the running version's `state` (the weapon rules,
## api.md *Weapon state*); a load that fails keeps the running version. An
## ability's spawn{} shots are plain bullets (no callbacks) from the player's
## bullet share, so nothing in flight ever points at an old version and the
## host never needs a second generation.
##
## Before the first clean apply there is no script and on_dash is the engine
## dash.

const MIN_COOLDOWN := 0.05
const MAX_COOLDOWN := 30.0
## Engine dash cooldown when no player is bound (Player.dash_cooldown default).
const ENGINE_COOLDOWN := 1.5
const HOOK := "on_dash"
## RunResult.error of apply() called from inside on_dash.
const NESTED_APPLY_ERROR := "apply() called while on_dash runs"
## ScriptWarnings keys: runtime errors and stops in on_dash, `state` copy
## notes, spawn{} past the cap.
const ERROR_KEY := "LuaDashAbility.error.on_dash"
const STATE_WARNING_KEY := "LuaDashAbility.state_copy"
const SPAWN_CAP_KEY := "LuaDashAbility.spawn_cap"
const PENDING_CAP_KEY := "LuaDashAbility.pending_cap"
## Most ticks one yielded on_dash keeps running (10 s at 60 Hz).
const MAX_PENDING_TICKS := 600

var chunk_name := "dash.lua"
## Settings of the running version.
var title := "Dash"
var source := ""
var applied_count := 0
## on_dash runs that errored or were stopped, and the last such result.
var error_total := 0
var last_error: ScriptHost.RunResult = null
## Clean on_dash runs, and engine dashes started through this ability.
var dash_calls := 0
var builtin_dashes := 0
## Real-time rest after a failed on_dash (0 in tests that want every call).
var error_backoff_msec := 250
## Where spawn{} shots go; the player's emitter when null.
var emitter: ShotEmitter

var _host: ScriptHost
var _has_script := false
var _calling := false
var _player: Object
var _rest_until_msec := 0
var _pending_ticks := 0
var _context := ShotContext.new()
var _request := ShotRequest.new()


func has_script() -> bool:
	return _has_script


func host() -> ScriptHost:
	return _host


## Binds the player whose engine dash and dash_cooldown this ability uses.
## on_dash() also binds the player it is called with.
func bind_player(player: Object) -> void:
	_player = player


## The dash button's cooldown for this file: its `cooldown` field clamped to
## [MIN_COOLDOWN, MAX_COOLDOWN], or the engine's dash_cooldown.
func get_cooldown() -> float:
	var fallback := _engine_cooldown()
	if not _has_script or _host == null:
		return fallback
	return clampf(_host.weapon_number("cooldown", fallback), MIN_COOLDOWN, MAX_COOLDOWN)


func _engine_cooldown() -> float:
	if _player != null and is_instance_valid(_player):
		var v: Variant = _player.get("dash_cooldown")
		if v is float:
			return v
	return ENGINE_COOLDOWN


## Compiles and runs `code` as the new ability. On failure (compile error,
## error or stop while loading, no table returned) the running version, its
## globals and its `state` are kept and the result carries the error.
func apply(code: String) -> ScriptHost.RunResult:
	if _calling:
		var nested := ScriptHost.RunResult.new()
		nested.chunk_name = chunk_name
		nested.error = NESTED_APPLY_ERROR
		return nested
	if _host == null:
		_host = ScriptHost.new()
		_host.player_cooldown_left = _cooldown_left
		_host.snapshot_globals()
	var carried := _host.export_state() if _has_script else ""
	var result := _host.load_string(code, chunk_name, true, carried)
	var adopted := result.ok and result.value is LuaTable and _host.has_weapon()
	result.value = null
	if result.ok and not adopted:
		result.ok = false
		result.error = LuaShot.NO_TABLE_ERROR
	if not result.ok:
		return result
	for w in result.warnings:
		ScriptWarnings.warn(STATE_WARNING_KEY, "LuaDashAbility: %s" % w)
	# The new version replaces a hook still running from the old one.
	_host.cancel_ability()
	_pending_ticks = 0
	_has_script = true
	source = code
	applied_count += 1
	title = _host.weapon_string("name", "Untitled").substr(0, 40)
	last_error = null
	_rest_until_msec = 0
	_refresh_player()
	return result


## Tells the player to re-read get_cooldown() (a no-op before the player
## has the dash hook).
func _refresh_player() -> void:
	if _player != null and is_instance_valid(_player) and _player.has_method("refresh_dash_ability"):
		_player.call("refresh_dash_ability")


## The player's dash hook. See the class comment.
func on_dash(player: Object, direction: Vector2) -> bool:
	if player != null and is_instance_valid(player):
		_player = player
	if _calling:
		return false
	if not direction.is_finite() or direction.length_squared() < 0.000001:
		var aim: Variant = _player.get("aim_direction") if _player != null and is_instance_valid(_player) else null
		direction = aim if aim is Vector2 else Vector2.RIGHT
	direction = direction.normalized()
	if not _has_script or _host == null or not _host.has_callback(HOOK):
		return _builtin_dash(direction)
	if _rest_until_msec > 0 and Time.get_ticks_msec() < _rest_until_msec:
		return false
	if _host.ability_pending():
		return false
	_fill_context(direction)
	_calling = true
	var result := _host.call_ability(HOOK, _context, direction, _lua_dash)
	_calling = false
	if not result.ok:
		_note_failure(result)
		return false
	dash_calls += 1
	_spawn_pending()
	if result.suspended:
		_pending_ticks = 0
		return true
	# nil counts as a dash; only an explicit false does not.
	return not (result.value is bool and result.value == false)


## True while a yielded on_dash is still running (see tick()).
func is_running() -> bool:
	return _host != null and _host.ability_pending()


## Resumes a yielded on_dash for one tick. AbilityScripts calls it every
## physics tick; a no-op when nothing is running.
func tick() -> void:
	if _calling or _host == null or not _host.ability_pending():
		return
	_pending_ticks += 1
	if _pending_ticks > MAX_PENDING_TICKS:
		_host.cancel_ability()
		ScriptWarnings.warn(PENDING_CAP_KEY, "LuaDashAbility: on_dash ran for %d ticks and was stopped" % MAX_PENDING_TICKS)
		return
	_calling = true
	var result := _host.resume_ability(HOOK, _lua_dash)
	_calling = false
	if not result.ok:
		_note_failure(result)
		return
	_spawn_pending()


func _note_failure(result: ScriptHost.RunResult) -> void:
	error_total += 1
	last_error = result
	if error_backoff_msec > 0:
		_rest_until_msec = Time.get_ticks_msec() + error_backoff_msec
	ScriptWarnings.warn(ERROR_KEY, "LuaDashAbility: on_dash: %s" % result.error)


## Lua player:dash_cooldown_left(): the player's Dash slot cooldown
## (Player.get_ability_cooldown_left, #126), 0 without a player.
func _cooldown_left() -> float:
	if _player == null or not is_instance_valid(_player) or not _player.has_method("get_ability_cooldown_left"):
		return 0.0
	var v: Variant = _player.call("get_ability_cooldown_left")
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	@warning_ignore("unsafe_cast")
	var left := v as float
	return left


## Lua player:dash(angle).
func _lua_dash(angle: float) -> bool:
	return _builtin_dash(Vector2.from_angle(angle))


## The engine dash: Player.perform_builtin_dash(dir), never try_dash (that
## would come back here).
func _builtin_dash(direction: Vector2) -> bool:
	if _player == null or not is_instance_valid(_player) or not _player.has_method("perform_builtin_dash"):
		return false
	var started: bool = _player.call("perform_builtin_dash", direction) == true
	if started:
		builtin_dashes += 1
	return started


func _fill_context(direction: Vector2) -> void:
	var at := Vector2.ZERO
	var aim := direction
	var p := _player
	if p != null and is_instance_valid(p):
		var pos: Variant = p.get("global_position")
		if pos is Vector2:
			at = pos
		var a: Variant = p.get("aim_direction")
		if a is Vector2:
			aim = a
	_context.muzzle_position = at
	_context.aim_direction = aim
	_context.aim_angle = aim.angle()
	_context.shooter_velocity = Vector2.ZERO
	var v: Variant = p.get("velocity") if p != null and is_instance_valid(p) else null
	if v is Vector2:
		_context.shooter_velocity = v
	_context.target_mask = Layers.hostile_to(Layers.PLAYER)
	_context.time = Time.get_ticks_msec() / 1000.0
	_context.shot_index = dash_calls
	_context.trigger_pressed = false
	_context.trigger_just_pressed = false
	_context.trigger_just_released = false
	_context.trigger_held_time = 0.0


## Plain bullets for this run's spawn{} records, through the player's
## emitter (and so the player's bullet share).
func _spawn_pending() -> void:
	var dropped := _host.spawns_dropped()
	if dropped > 0:
		ScriptWarnings.warn(SPAWN_CAP_KEY, "LuaDashAbility: spawn %d calls past the %d-per-dash limit were dropped" % [dropped, ScriptHost.FIRE_SPAWN_CAP])
	var records := _host.take_pending_spawns()
	if records.is_empty():
		return
	var out := emitter
	if out == null and _player != null and is_instance_valid(_player):
		var e: Variant = _player.get("emitter")
		if e is ShotEmitter:
			out = e
	if out == null:
		return
	var speed := clampf(_host.weapon_number("speed", LuaShot.DEFAULT_SPEED), 0.0, BulletLimits.MAX_SPEED)
	var lifetime := clampf(_host.weapon_number("lifetime", LuaShot.DEFAULT_LIFETIME), 0.05, 10.0)
	var damage := clampf(_host.weapon_number("damage", LuaShot.DEFAULT_DAMAGE), 0.0, 100.0)
	var radius := clampf(_host.weapon_number("radius", LuaShot.DEFAULT_RADIUS), 1.0, 32.0)
	for rec in records:
		_request.reset()
		var at := Vector2(LuaShot._num(rec, "x", _context.muzzle_position.x), LuaShot._num(rec, "y", _context.muzzle_position.y))
		var angle := LuaShot._num(rec, "angle", _context.aim_angle)
		_request.position = at
		_request.velocity = Vector2.from_angle(angle) * LuaShot._num(rec, "speed", speed)
		_request.angle = angle
		_request.lifetime = LuaShot._num(rec, "lifetime", lifetime)
		_request.radius = LuaShot._num(rec, "radius", radius)
		_request.damage = LuaShot._num(rec, "damage", damage)
		_request.turn_rate = LuaShot._num(rec, "spin", 0.0)
		_request.acceleration = LuaShot._num(rec, "accel", 0.0)
		_request.color = Layers.bullet_color(Layers.PLAYER)
		_request.owner_layer = Layers.PLAYER
		_request.hit_mask = _context.target_mask
		out.request_shot(_request)
