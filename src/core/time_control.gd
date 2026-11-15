extends Node
## Autoload `TimeControl`: a script-requested world time scale that does not
## write Engine.time_scale (ability-scripting.md). The victory card and the
## script editor keep control of Engine.time_scale. Player movement, regen,
## i-frames and the player's own shots stay on the engine delta; enemies,
## enemy bullets, telegraphs, boss phase / spawn / Herald timers and
## habituation decay use scaled_delta().
##
## Numbers below are the Game Designer caps recorded in ability-scripting.md.

## Maximum duration of one request, in seconds.
const MAX_STOP_SECONDS := 3.0
## Scale is clamped to this inclusive range.
const MIN_SCALE := 0.0
const MAX_SCALE := 1.0
## Cooldown after a stop that ran to the end: max(COOLDOWN_MIN_SECONDS,
## COOLDOWN_DURATION_MUL * duration actually used).
const COOLDOWN_MIN_SECONDS := 1.0
const COOLDOWN_DURATION_MUL := 1.5
## Null attacks (bullets with pierces_script_invuln, their telegraphs, the
## Null-shot affix, legendary Null rings) use max(world_scale, this floor).
## Null bodies and casters still freeze at the world scale.
const NULL_TIME_SCALE_FLOOR := 0.5

## Emitted when a request starts, with the clamped scale and duration.
signal script_time_scaled(scale: float, seconds: float)

var _active := false
var _scale := 1.0
var _effect_left := 0.0
var _used := 0.0
var _cooldown_left := 0.0
var _last_usec := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if GameEvents != null:
		if not GameEvents.player_died.is_connected(cancel):
			GameEvents.player_died.connect(cancel)
		if not GameEvents.boss_defeated.is_connected(_on_boss_defeated):
			GameEvents.boss_defeated.connect(_on_boss_defeated)
		if not GameEvents.run_started.is_connected(cancel):
			GameEvents.run_started.connect(cancel)
		if not GameEvents.run_ended.is_connected(_on_run_ended):
			GameEvents.run_ended.connect(_on_run_ended)


func _on_boss_defeated(_boss_kind: StringName, _rarity: int, _tier: int, _position: Vector2) -> void:
	cancel()


func _on_run_ended(_victory: bool) -> void:
	cancel()


## Start a world time scale. Returns {ok, err, cooldown_left}.
## err is "" on success, "active" or "cooldown" when rejected, "invalid" for a
## non-finite scale, or a NaN / negative-infinite / non-positive duration.
## +INF duration is clamped to MAX_STOP_SECONDS, like other out-of-range values.
## When rejected as "active", cooldown_left is the remaining effect time, not
## the wait until a retry would succeed; use retry_in() for that.
## A call from inside the sim step (a bullet hook during advance) updates the
## control immediately but applies to the next integration step: class dts
## already computed for this tick stay unchanged, and nothing is re-simulated.
func request(scale: float, seconds: float) -> Dictionary:
	if not is_finite(scale):
		return _result(false, "invalid", cooldown_left())
	var dur := seconds
	if is_inf(dur) and dur > 0.0:
		dur = MAX_STOP_SECONDS
	elif not is_finite(dur) or dur <= 0.0:
		return _result(false, "invalid", cooldown_left())
	seconds = dur
	if _active:
		return _result(false, "active", _effect_left)
	if _cooldown_left > 0.0:
		return _result(false, "cooldown", _cooldown_left)
	_scale = clampf(scale, MIN_SCALE, MAX_SCALE)
	_effect_left = minf(seconds, MAX_STOP_SECONDS)
	_used = 0.0
	_active = true
	_last_usec = Time.get_ticks_usec()
	script_time_scaled.emit(_scale, _effect_left)
	return _result(true, "", 0.0)


func is_active() -> bool:
	return _active


## 1 when inactive, otherwise the clamped request scale (may be 0).
func world_scale() -> float:
	return _scale if _active else 1.0


## Seconds left on the post-effect cooldown, or 0. While a stop is still
## active this is 0 (the cooldown has not started); see retry_in().
func cooldown_left() -> float:
	return _cooldown_left


## Seconds until a new request would be accepted. While a stop is active this
## is the remaining effect time plus the cooldown that will start if it runs
## to the end: max(COOLDOWN_MIN_SECONDS, COOLDOWN_DURATION_MUL * expected used).
## Otherwise this is cooldown_left().
func retry_in() -> float:
	if _active:
		var expected := _used + _effect_left
		return _effect_left + maxf(COOLDOWN_MIN_SECONDS, COOLDOWN_DURATION_MUL * expected)
	return _cooldown_left


## End the effect immediately with no cooldown. Also clears an in-flight
## cooldown. Engine callers (death, respawn, a new run, Main leaving the tree)
## use this; it is not a bindable "end early" that should still apply the
## uptime cap.
func cancel() -> void:
	_active = false
	_scale = 1.0
	_effect_left = 0.0
	_used = 0.0
	_cooldown_left = 0.0


## Engine delta scaled for a world-side consumer. `floor_scale` is the
## per-source floor (0 for regular enemies, NULL_TIME_SCALE_FLOOR for Null
## attacks). A no-op when inactive, so the hot path is one bool check.
func scaled_delta(delta: float, floor_scale: float = 0.0) -> float:
	if not _active:
		return delta
	return delta * maxf(_scale, floor_scale)


## Integration delta for one bullet. Player shots are unscaled. Null attacks
## (pierces_script_invuln) use max(world_scale, NULL_TIME_SCALE_FLOOR).
func bullet_delta(delta: float, player_shot: bool, null_attack: bool) -> float:
	if not _active:
		return delta
	if player_shot:
		return delta
	if null_attack:
		return delta * maxf(_scale, NULL_TIME_SCALE_FLOOR)
	return delta * _scale


## Tests: advance the real-time clock by `dt` seconds (respects game pause).
func debug_advance(dt: float) -> void:
	if not is_finite(dt) or dt <= 0.0:
		return
	if _is_game_paused():
		return
	if _active:
		var step := minf(dt, _effect_left)
		_used += step
		_effect_left = maxf(_effect_left - dt, 0.0)
		if _effect_left <= 0.0:
			_finish_effect()
	elif _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - dt, 0.0)


func _process(_delta: float) -> void:
	if not _active and _cooldown_left <= 0.0:
		_last_usec = 0
		return
	var now := Time.get_ticks_usec()
	if _is_game_paused():
		_last_usec = now
		return
	if _last_usec <= 0:
		_last_usec = now
		return
	var dt := float(now - _last_usec) / 1000000.0
	_last_usec = now
	if dt <= 0.0:
		return
	if _active:
		var step := minf(dt, _effect_left)
		_used += step
		_effect_left = maxf(_effect_left - dt, 0.0)
		if _effect_left <= 0.0:
			_finish_effect()
	elif _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - dt, 0.0)


func _finish_effect() -> void:
	var used := _used
	_active = false
	_scale = 1.0
	_effect_left = 0.0
	_used = 0.0
	_cooldown_left = maxf(COOLDOWN_MIN_SECONDS, COOLDOWN_DURATION_MUL * used)


## Menus (SceneTree.paused) and the victory card (Engine.time_scale == 0).
## The script editor uses 0.15 and does not pause the countdown. A world_scale
## of 0 never writes Engine.time_scale, so it does not pause this clock.
func _is_game_paused() -> bool:
	var tree := get_tree()
	if tree != null and tree.paused:
		return true
	return Engine.time_scale == 0.0


func _result(ok: bool, err: String, left: float) -> Dictionary:
	return {"ok": ok, "err": err, "cooldown_left": left}
