class_name ScriptWorld
extends RefCounted
## What the Lua `player.size` and `world.*` time bindings act on, shared by
## every ScriptHost (weapon and ability files alike): the player
## (PlayerState.set_size, #128) and the TimeControl autoload. Static, so one
## player has one write throttle whichever host writes.
##
## Size writes: at most one engine call per physics tick (a blocked grow costs
## many physics queries). A second write in the same tick, or any write from a
## bullet callback (mid BulletManager.step), is held and applied by flush() on
## a later tick; the last held write wins. NaN is ignored with a warning,
## infinities clamp to the size range (as PlayerState does for other fields).
##
## Time: request() clamps the duration to TimeControl.MAX_STOP_SECONDS (INF
## included) and the scale to 0..1, and answers {ok, err, retry_in}. cancel()
## is deliberately not bound: it would also clear the cooldown.

const SIZE_NAN_KEY := "ScriptWorld.size_nan"

static var _player_ref: WeakRef = null
static var _last_write_tick := -1
static var _has_held := false
static var _held := 1.0
## Engine size calls made through the binding (tests and the throttle check).
static var size_engine_calls := 0
## Added to the physics frame count (tests drive ticks by hand).
static var _tick_offset := 0
## Duration of the stop now running, from TimeControl.script_time_scaled
## (fallback for retry_in() when TimeControl has none).
static var _stop_seconds := 0.0
static var _time_signal_bound := false


static func bind_player(player: Object) -> void:
	_player_ref = weakref(player) if player != null else null
	_has_held = false
	_last_write_tick = -1


static func reset() -> void:
	bind_player(null)
	size_engine_calls = 0
	_tick_offset = 0


## Tests: the next physics tick, as far as the throttle is concerned.
static func debug_next_tick() -> void:
	_tick_offset += 1


static func _tick() -> int:
	return Engine.get_physics_frames() + _tick_offset


static func _state() -> PlayerState:
	if _player_ref == null:
		return null
	var p: Variant = _player_ref.get_ref()
	if p == null or not is_instance_valid(p):
		return null
	var o: Object = p
	var s: Variant = o.get("state")
	return s if s is PlayerState else null


# ---------------------------------------------------------------- size


## Current body size (1.0 without a player). A held write that is due is
## applied first, so a read on a later tick sees it.
static func get_size() -> float:
	flush()
	var s := _state()
	return s.get_size() if s != null else 1.0


## Lua `player.size = value`. Returns the size in effect afterwards: the
## applied size for a write that reached the engine now, the current size for
## a held one.
static func set_size(value: float, hold: bool = false) -> float:
	var s := _state()
	if s == null:
		return 1.0
	if is_nan(value):
		ScriptWarnings.warn(SIZE_NAN_KEY, "player.size: NaN ignored")
		return s.get_size()
	var want := clampf(value, Player.MIN_SIZE, Player.MAX_SIZE)
	if hold or _tick() == _last_write_tick:
		_held = want
		_has_held = true
		return s.get_size()
	_has_held = false
	return _apply(s, want)


static func has_held_size() -> bool:
	return _has_held


## Applies a held size write if this tick has no engine call yet. Called each
## physics tick (AbilityScripts) and before every size read or write.
static func flush() -> void:
	if not _has_held or _tick() == _last_write_tick:
		return
	var s := _state()
	_has_held = false
	if s != null:
		_apply(s, _held)


static func _apply(s: PlayerState, want: float) -> float:
	_last_write_tick = _tick()
	size_engine_calls += 1
	return s.set_size(want)


# ---------------------------------------------------------------- time


static func _time_control() -> Node:
	var loop := Engine.get_main_loop()
	if not loop is SceneTree:
		return null
	var tree: SceneTree = loop
	var tc := tree.root.get_node_or_null("TimeControl")
	if tc != null and not _time_signal_bound and tc.has_signal("script_time_scaled"):
		tc.connect("script_time_scaled", _on_time_scaled)
		_time_signal_bound = true
	return tc


static func _on_time_scaled(_scale: float, seconds: float) -> void:
	_stop_seconds = seconds


static func max_seconds() -> float:
	return TimeControl.MAX_STOP_SECONDS


## world.time_scale(scale, seconds). {ok: bool, err: String ("" | "active" |
## "cooldown" | "invalid"), retry_in: float}. NaN in either argument and a
## duration that is not positive are "invalid"; INF and long durations clamp
## to MAX_STOP_SECONDS, the scale to 0..1.
static func request_time(scale: float, seconds: float) -> Dictionary:
	var tc := _time_control()
	if tc == null:
		return {"ok": false, "err": "invalid", "retry_in": 0.0}
	if is_nan(scale) or is_nan(seconds) or seconds <= 0.0:
		return {"ok": false, "err": "invalid", "retry_in": retry_in()}
	var s := clampf(scale, TimeControl.MIN_SCALE, TimeControl.MAX_SCALE)
	var d := minf(seconds, TimeControl.MAX_STOP_SECONDS)
	var r: Variant = tc.call("request", s, d)
	var ok := false
	var err := "invalid"
	if r is Dictionary:
		var dict: Dictionary = r
		ok = dict.get("ok", false) == true
		var e: Variant = dict.get("err", "")
		err = e if e is String else "invalid"
	if ok:
		_stop_seconds = d
		return {"ok": true, "err": "", "retry_in": 0.0}
	return {"ok": false, "err": err, "retry_in": retry_in()}


## Seconds until a new request can start: 0 when free; the cooldown left; and
## while a stop runs, what is left of it plus the cooldown it will leave
## (max(COOLDOWN_MIN_SECONDS, COOLDOWN_DURATION_MUL * its duration)), assuming
## it runs to the end (death, respawn and boss kills end it with no cooldown).
static func retry_in() -> float:
	var tc := _time_control()
	if tc == null:
		return 0.0
	if tc.has_method("retry_in"):
		return _finite_nonneg(tc.call("retry_in"))
	if not _truthy(tc.call("is_active")):
		return _finite_nonneg(tc.call("cooldown_left"))
	# TimeControl has no public "effect left" yet (GE is adding retry_in()).
	var left := _finite_nonneg(tc.get("_effect_left"))
	var cooldown := maxf(TimeControl.COOLDOWN_MIN_SECONDS, TimeControl.COOLDOWN_DURATION_MUL * _stop_seconds)
	return left + cooldown


## The world time scale now (1 when no stop runs).
static func time_scale_now() -> float:
	var tc := _time_control()
	if tc == null:
		return 1.0
	return _finite_nonneg(tc.call("world_scale"))


static func _truthy(v: Variant) -> bool:
	return v is bool and v == true


static func _finite_nonneg(v: Variant) -> float:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	@warning_ignore("unsafe_cast")
	var f := v as float
	return f if is_finite(f) and f > 0.0 else 0.0
