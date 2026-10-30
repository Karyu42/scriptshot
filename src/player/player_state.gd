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


## Invulnerability: a number of seconds, or true (until cleared) / false (clear).
## Seconds only extend the current invulnerability; 0 clears it. While
## invulnerable, bullets pass through the player. See Health.set_invulnerable().
func set_invulnerable(value: Variant) -> void:
	if _ok():
		_player.health.set_invulnerable(value)


## True during hit i-frames, a dash, or script-set invulnerability.
func is_invulnerable() -> bool:
	return _ok() and _player.health.is_invulnerable()


## Seconds of invulnerability left (INF when set to true).
func get_invulnerable_time() -> float:
	return _player.health.invulnerable_left if _ok() else 0.0


func is_dead() -> bool:
	return _ok() and _player.is_dead()


## True while hp is regenerating (below max and 5 s past the last damage).
func is_regenerating() -> bool:
	return _ok() and _player.health.is_regenerating()


## Seconds since the player last took damage.
func get_time_since_damage() -> float:
	return _player.health.time_since_damage if _ok() else 0.0


# --- movement ----------------------------------------------------------------

func get_position() -> Vector2:
	return _player.global_position if _ok() else Vector2.ZERO


## Teleports the player (no interpolated smear). Non-finite vectors are ignored;
## coordinates are clamped to +-MAX_COORD. Returns the resulting position.
func set_position(value: Vector2) -> Vector2:
	if not _ok():
		return Vector2.ZERO
	if not value.is_finite():
		push_warning("PlayerState.set_position(): non-finite position ignored")
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
		push_warning("PlayerState.set_velocity(): non-finite velocity ignored")
		return _player.velocity
	_player.velocity = value.limit_length(MAX_SPEED)
	return _player.velocity


## Unit vector the player is aiming along.
func get_aim_direction() -> Vector2:
	return _player.aim_direction if _ok() else Vector2.RIGHT


# --- dash (read-only) --------------------------------------------------------

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
