class_name PlayerState
extends RefCounted
## The script-facing view of the player: a small facade of validated getters and
## setters, reachable as `player.state`. This is the surface shot scripts (and
## the future Lua binding) use to read and change player state, so the rules live
## here and not in each binding:
##
##   - Numbers must be finite. NaN is ignored (the call changes nothing and
##     returns the current value) and logs a warning; infinities are clamped.
##   - Values are clamped to sane ranges instead of rejected: hp to
##     [0, max_hp], max_hp to [1, Health.MAX_HP_LIMIT], speed to MAX_SPEED,
##     position to +-MAX_COORD.
##   - A freed player turns every call into a harmless no-op / default.
##
## Names are snake_case and take/return plain values (float, bool, Vector2) so
## they map one-to-one onto Lua functions.

## Largest speed (px/s) set_velocity() accepts; longer vectors are shortened.
const MAX_SPEED := 5000.0
## Largest absolute coordinate set_position() accepts.
const MAX_COORD := 100000.0
## Largest regeneration delay / interval (seconds) the setters accept.
const MAX_REGEN_SECONDS := 3600.0

var _player: Player


func _init(player: Player) -> void:
	_player = player


# --- health ------------------------------------------------------------------

func get_hp() -> float:
	return _player.health.hp if _ok() else 0.0


## Sets hp, clamped to [0, max_hp]. 0 kills the player (normal death + respawn
## flow). NaN is ignored. Returns the resulting hp.
func set_hp(value: float) -> float:
	return _player.health.set_hp(value) if _ok() else 0.0


func get_max_hp() -> float:
	return _player.health.max_hp if _ok() else 0.0


## Sets max_hp, clamped to [1, Health.MAX_HP_LIMIT]; hp is clamped down if needed,
## but raising max_hp does not heal. NaN is ignored. Returns the resulting max_hp.
func set_max_hp(value: float) -> float:
	return _player.health.set_max_hp(value) if _ok() else 0.0


## Script invulnerability: a number of seconds, or true (until cleared, no cap) /
## false (clear). It is **its own layer**, separate from the engine's i-frames
## (hit i-frames, the dash): false clears only what scripts set, and never cancels
## engine i-frames. Seconds replace the previous script value; 0 or less clears.
## Attacks marked as piercing ignore this layer. See Health.set_invulnerable().
func set_invulnerable(value: Variant) -> void:
	if _ok():
		_player.health.set_invulnerable(value)


## True if either layer (script or engine) is on.
func is_invulnerable() -> bool:
	return _ok() and _player.health.is_invulnerable()


## True while the script layer is on (see set_invulnerable()).
func is_script_invulnerable() -> bool:
	return _ok() and _player.health.is_script_invulnerable()


## True during hit i-frames or a dash (engine layer; scripts can't write it).
func is_engine_invulnerable() -> bool:
	return _ok() and _player.health.is_engine_invulnerable()


## Seconds of invulnerability left in either layer (INF while the script flag is
## set to true).
func get_invulnerable_time() -> float:
	if not _ok():
		return 0.0
	return maxf(_player.health.engine_invulnerable_left, _player.health.script_invulnerable_left)


## Seconds of script invulnerability left (INF when set to true).
func get_script_invulnerable_time() -> float:
	return _player.health.script_invulnerable_left if _ok() else 0.0


## Seconds of engine i-frames left (hit i-frames, dash).
func get_engine_invulnerable_time() -> float:
	return _player.health.engine_invulnerable_left if _ok() else 0.0


func is_dead() -> bool:
	return _ok() and _player.is_dead()


## True while hp is regenerating (below max and 5 s past the last damage).
func is_regenerating() -> bool:
	return _ok() and _player.health.is_regenerating()


## Seconds since the player last took damage.
func get_time_since_damage() -> float:
	return _player.health.time_since_damage if _ok() else 0.0


# --- regeneration ------------------------------------------------------------

func get_regen_delay() -> float:
	return _player.health.regen_delay if _ok() else 0.0


## Seconds without damage before the first regeneration step, clamped to
## [0, 3600]; NaN is ignored. Returns the resulting value.
func set_regen_delay(seconds: float) -> float:
	if not _ok():
		return 0.0
	if is_nan(seconds):
		ScriptWarnings.warn("PlayerState.set_regen_delay", "PlayerState.set_regen_delay(): NaN ignored")
		return _player.health.regen_delay
	_player.health.regen_delay = clampf(seconds, 0.0, MAX_REGEN_SECONDS)
	return _player.health.regen_delay


func get_regen_interval() -> float:
	return _player.health.regen_interval if _ok() else 0.0


## Seconds per regeneration step ("regen rate" is 1 hp per this many seconds),
## clamped to [0.05, 3600]; NaN is ignored. Returns the resulting value.
func set_regen_interval(seconds: float) -> float:
	if not _ok():
		return 0.0
	if is_nan(seconds):
		ScriptWarnings.warn("PlayerState.set_regen_interval", "PlayerState.set_regen_interval(): NaN ignored")
		return _player.health.regen_interval
	_player.health.regen_interval = clampf(seconds, 0.05, MAX_REGEN_SECONDS)
	return _player.health.regen_interval


func get_regen_amount() -> float:
	return _player.health.regen_amount if _ok() else 0.0


## Hit points per regeneration step, clamped to [0, max_hp]; NaN is ignored.
## 0 turns regeneration off. Returns the resulting value.
func set_regen_amount(amount: float) -> float:
	if not _ok():
		return 0.0
	if is_nan(amount):
		ScriptWarnings.warn("PlayerState.set_regen_amount", "PlayerState.set_regen_amount(): NaN ignored")
		return _player.health.regen_amount
	_player.health.regen_amount = clampf(amount, 0.0, _player.health.max_hp)
	return _player.health.regen_amount


# --- movement ----------------------------------------------------------------

func get_speed() -> float:
	return _player.max_speed if _ok() else 0.0


## Top running speed in px/s, clamped to [0, MAX_SPEED]; NaN is ignored. Returns
## the resulting speed.
func set_speed(value: float) -> float:
	if not _ok():
		return 0.0
	if is_nan(value):
		ScriptWarnings.warn("PlayerState.set_speed", "PlayerState.set_speed(): NaN ignored")
		return _player.max_speed
	_player.max_speed = clampf(value, 0.0, MAX_SPEED)
	return _player.max_speed


func get_position() -> Vector2:
	return _player.global_position if _ok() else Vector2.ZERO


## Teleports the player (no interpolated smear). Non-finite vectors are ignored;
## coordinates are clamped to +-MAX_COORD. Returns the resulting position.
func set_position(value: Vector2) -> Vector2:
	if not _ok():
		return Vector2.ZERO
	if not value.is_finite():
		ScriptWarnings.warn("PlayerState.set_position", "PlayerState.set_position(): non-finite position ignored")
		return _player.global_position
	_player.teleport(value.clamp(Vector2(-MAX_COORD, -MAX_COORD), Vector2(MAX_COORD, MAX_COORD)))
	return _player.global_position


func get_velocity() -> Vector2:
	return _player.velocity if _ok() else Vector2.ZERO


## Sets the velocity in px/s; vectors longer than MAX_SPEED are shortened,
## non-finite ones ignored. Returns the resulting velocity.
func set_velocity(value: Vector2) -> Vector2:
	if not _ok():
		return Vector2.ZERO
	if not value.is_finite():
		ScriptWarnings.warn("PlayerState.set_velocity", "PlayerState.set_velocity(): non-finite velocity ignored")
		return _player.velocity
	_player.velocity = value.limit_length(MAX_SPEED)
	return _player.velocity


## Unit vector the player is aiming along.
func get_aim_direction() -> Vector2:
	return _player.aim_direction if _ok() else Vector2.RIGHT


# --- dash --------------------------------------------------------------------

## The same action as the dash button, along `angle` (radians, 0 = right): starts a
## dash and returns true, or returns false while dashing, on cooldown or dead. It
## obeys the button's rules (cooldown, invulnerability) and is not buffered; a
## script dashing is not a state write. NaN angle: false.
func dash(angle: float) -> bool:
	if not _ok() or not is_finite(angle):
		return false
	return _player.try_dash(Vector2.from_angle(angle))


func is_dashing() -> bool:
	return _ok() and _player.is_dashing()


## True when a dash would start right now (alive, not dashing, cooldown over).
func can_dash() -> bool:
	return _ok() and not _player.is_dead() and not _player.is_dashing() and _player.get_dash_cooldown_left() <= 0.0


## Seconds until the next dash may start (0 = ready).
func get_dash_cooldown_left() -> float:
	return _player.get_dash_cooldown_left() if _ok() else 0.0


## Total dash cooldown in seconds (the tuning value).
func get_dash_cooldown() -> float:
	return _player.dash_cooldown if _ok() else 0.0


## Unit direction of the current (or most recent) dash.
func get_dash_direction() -> Vector2:
	return _player.get_dash_direction() if _ok() else Vector2.ZERO


func _ok() -> bool:
	return is_instance_valid(_player)
