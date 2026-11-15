extends GutTest
## Lua player.size and world.time_* (ScriptWorld over PlayerState.set_size and
## TimeControl, #128): clamps, the one-engine-call-per-tick size throttle,
## writes from bullet callbacks held for a later tick, time stop rejection
## and retry_in, weapon and ability files alike, the bundled time-stop dash
## starter, and a time-stop dash freezing an enemy shot while the player's
## shot keeps moving.

const DT := 1.0 / 60.0

var _player: Player
var _hosts: Array[ScriptHost] = []


func before_each() -> void:
	ScriptWarnings.reset()
	ScriptWorld.reset()
	TimeControl.cancel()
	TimeControl.set_process(false)
	Engine.time_scale = 1.0
	_player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(_player)
	_player.set_physics_process(false)
	_player.global_position = Vector2.ZERO
	ScriptWorld.bind_player(_player)


func after_each() -> void:
	TimeControl.cancel()
	TimeControl.set_process(true)
	ScriptWorld.reset()
	for h: ScriptHost in _hosts:
		h.shutdown()
	_hosts.clear()


## Runs `body` as a weapon's on_fire and returns the result.
func _fire(body: String) -> ScriptHost.RunResult:
	var host := ScriptHost.new()
	_hosts.append(host)
	var r := host.load_string("return { on_fire = function(ctx)\n%s\nend }" % body, "w.lua")
	assert_true(r.ok, r.error)
	return host.call_fire(ShotContext.new())


## Runs `body` in on_fire and returns what it put in `name` (via error-free
## tostring), so a test can read Lua values back.
func _eval(expr: String) -> String:
	var host := ScriptHost.new()
	_hosts.append(host)
	var r := host.load_string("return { name = tostring(%s) }" % expr, "e.lua")
	assert_true(r.ok, r.error)
	return host.weapon_string("name", "")


func _num(expr: String) -> float:
	return _eval(expr).to_float()


# ---------------------------------------------------------------- size


func test_size_reads_and_writes_through_player_state() -> void:
	assert_almost_eq(_num("player.size"), 1.0, 0.0001)
	var seen: Array = []
	_player.state.script_wrote.connect(func(f: StringName, o: Variant, n: Variant) -> void: seen.append([f, o, n]))
	assert_true(_fire("player.size = 0.4").ok)
	assert_almost_eq(_player.get_size(), 0.4, 0.0001)
	ScriptWorld.debug_next_tick()
	assert_almost_eq(_num("player.size"), 0.4, 0.0001, "the applied value reads back")
	assert_eq(seen.size(), 1, "script_wrote(size) from PlayerState")


func test_size_clamps_to_the_range_and_infinities_clamp() -> void:
	var cases: Dictionary[String, float] = {"0.1": 0.25, "10": 4.0, "math.huge": 4.0, "-math.huge": 0.25, "-3": 0.25, "2.5": 2.5}
	for expr: String in cases:
		ScriptWorld.debug_next_tick()
		assert_true(_fire("player.size = %s" % expr).ok, expr)
		assert_almost_eq(_player.get_size(), cases[expr], 0.0001, expr)


func test_nan_is_ignored_with_a_warning_and_wrong_types_raise() -> void:
	assert_true(_fire("player.size = 0/0").ok, "NaN is not a Lua error")
	assert_almost_eq(_player.get_size(), 1.0, 0.0001)
	assert_eq(ScriptWarnings.count(ScriptWorld.SIZE_NAN_KEY), 1)
	var r := _fire("player.size = 'big'")
	assert_false(r.ok)
	assert_string_contains(r.error, "player.size: expected a number")
	r = _fire("player.hp = 3")
	assert_false(r.ok)
	assert_string_contains(r.error, "cannot be set in this version")
	r = _fire("rawset(player, 'size', 2)")
	assert_false(r.ok, "the proxy is protected")


func test_one_engine_call_per_tick_and_the_last_held_write_wins() -> void:
	assert_true(_fire("player.size = 2\nplayer.size = 0.5\nplayer.size = 3\nstate.read = player.size").ok)
	assert_eq(ScriptWorld.size_engine_calls, 1, "one engine call this tick")
	assert_almost_eq(_player.get_size(), 2.0, 0.0001, "the first write went through")
	assert_true(ScriptWorld.has_held_size())
	ScriptWorld.flush()
	assert_eq(ScriptWorld.size_engine_calls, 1, "still the same tick")
	ScriptWorld.debug_next_tick()
	ScriptWorld.flush()
	assert_eq(ScriptWorld.size_engine_calls, 2)
	assert_almost_eq(_player.get_size(), 3.0, 0.0001, "last write wins")
	assert_false(ScriptWorld.has_held_size())


func test_a_read_on_a_later_tick_applies_a_held_write() -> void:
	assert_true(_fire("player.size = 2\nplayer.size = 0.5").ok)
	ScriptWorld.debug_next_tick()
	assert_almost_eq(_num("player.size"), 0.5, 0.0001)


func test_a_write_from_a_bullet_callback_is_held_for_a_later_tick() -> void:
	var host := ScriptHost.new()
	_hosts.append(host)
	assert_true(host.load_string("return { on_hit = function(b, h) player.size = 0.5 end }", "h.lua").ok)
	ScriptWorld.debug_next_tick()
	var r := host.call_hook("on_hit", 1, 0.0, 0.0, null, true)
	assert_true(r.ok, r.error)
	assert_almost_eq(_player.get_size(), 1.0, 0.0001, "not mid step")
	assert_eq(ScriptWorld.size_engine_calls, 0)
	ScriptWorld.debug_next_tick()
	ScriptWorld.flush()
	assert_almost_eq(_player.get_size(), 0.5, 0.0001)


func test_no_player_reads_one_and_ignores_writes() -> void:
	ScriptWorld.bind_player(null)
	assert_almost_eq(_num("player.size"), 1.0, 0.0001)
	assert_true(_fire("player.size = 3").ok)
	assert_almost_eq(_player.get_size(), 1.0, 0.0001)


# ---------------------------------------------------------------- time


func test_time_stop_starts_and_a_second_call_is_refused_with_retry_in() -> void:
	assert_eq(_eval("world.time_stop(1)"), "true")
	assert_true(TimeControl.is_active())
	assert_almost_eq(TimeControl.world_scale(), 0.0, 0.0001)
	assert_almost_eq(_num("world.time_scale_now()"), 0.0, 0.0001)
	assert_eq(_eval("select(2, world.time_stop(1))"), "active")
	# 1 s left plus max(1, 1.5 * 1) cooldown.
	assert_almost_eq(_num("select(3, world.time_stop(1))"), 2.5, 0.01)
	assert_almost_eq(_num("world.time_retry_in()"), 2.5, 0.01)
	assert_eq(_eval("world.time_stop(1)"), "false", "never extends or stacks")
	TimeControl.debug_advance(0.4)
	assert_almost_eq(_num("world.time_retry_in()"), 2.1, 0.01)
	TimeControl.debug_advance(0.6)
	assert_false(TimeControl.is_active())
	assert_eq(_eval("select(2, world.time_scale(0.5, 1))"), "cooldown")
	assert_almost_eq(_num("select(3, world.time_scale(0.5, 1))"), 1.5, 0.01)
	TimeControl.debug_advance(1.5)
	assert_eq(_eval("world.time_scale(0.5, 1)"), "true", "free after the cooldown")
	assert_almost_eq(_num("world.time_scale_now()"), 0.5, 0.0001)


func test_short_stops_rest_at_least_one_second() -> void:
	assert_eq(_eval("world.time_stop(0.2)"), "true")
	assert_almost_eq(_num("world.time_retry_in()"), 1.2, 0.01, "0.2 s left + the 1 s minimum")


func test_durations_and_scales_clamp() -> void:
	var got: Array[float] = []
	TimeControl.script_time_scaled.connect(func(sc: float, d: float) -> void: got.append_array([sc, d]))
	assert_eq(_eval("world.time_scale(5, math.huge)"), "true")
	assert_eq(got.size(), 2)
	assert_almost_eq(got[0], 1.0, 0.0001, "no speed-up")
	assert_almost_eq(got[1], 3.0, 0.0001, "INF clamps to 3 s")
	TimeControl.cancel()
	assert_eq(_eval("world.time_scale(-1, 60)"), "true")
	assert_almost_eq(got[2], 0.0, 0.0001)
	assert_almost_eq(got[3], 3.0, 0.0001, "long durations clamp to 3 s")
	# 3 s used -> 4.5 s cooldown.
	assert_almost_eq(_num("world.time_retry_in()"), 7.5, 0.01)


func test_invalid_requests() -> void:
	for call: String in ["world.time_stop(0)", "world.time_stop(-1)", "world.time_stop(0/0)", "world.time_scale(0/0, 1)"]:
		assert_eq(_eval("select(2, %s)" % call), "invalid", call)
		assert_false(TimeControl.is_active(), call)
	var r := _fire("world.time_stop('long')")
	assert_false(r.ok)
	assert_string_contains(r.error, "world.time_stop: expected a duration in seconds")
	r = _fire("world.time_scale(nil, 1)")
	assert_false(r.ok)
	assert_string_contains(r.error, "expected a scale")


func test_world_is_read_only_and_has_no_cancel() -> void:
	assert_eq(_eval("world.cancel"), "nil")
	assert_eq(_eval("world.time_cancel"), "nil")
	var r := _fire("world.time_stop = nil")
	assert_false(r.ok)
	assert_string_contains(r.error, "world is read-only")


func test_time_calls_are_safe_from_a_bullet_callback() -> void:
	var host := ScriptHost.new()
	_hosts.append(host)
	assert_true(host.load_string("return { on_hit = function(b, h) state.ok = world.time_stop(1) end }", "h.lua").ok)
	var r := host.call_hook("on_hit", 1, 0.0, 0.0, null, true)
	assert_true(r.ok, r.error)
	assert_true(TimeControl.is_active())


# ---------------------------------------------------------------- abilities


func _ability(code: String) -> LuaDashAbility:
	var a := LuaDashAbility.new()
	a.bind_player(_player)
	a.error_backoff_msec = 0
	var r := a.apply(code)
	assert_true(r.ok, r.error)
	return a


func test_ability_files_use_the_same_bindings() -> void:
	var a := _ability("return { on_dash = function(ctx, dir) player.size = 0.5 world.time_stop(1) end }")
	assert_true(a.on_dash(_player, Vector2.RIGHT))
	assert_eq(a.error_total, 0, str(a.last_error.error if a.last_error else ""))
	assert_almost_eq(_player.get_size(), 0.5, 0.0001)
	assert_true(TimeControl.is_active())


func test_the_time_stop_dash_starter_loads_and_dashes_with_iframes() -> void:
	var src := AbilityLibrary.starter_source("time_stop_dash")
	assert_string_contains(src, "world.time_stop(")
	assert_string_contains(src, "player:dash(")
	assert_true(FileAccess.file_exists("res://scripting/abilities/time_stop_dash.lua.txt"))
	var a := _ability(src)
	assert_eq(a.title, "Time-stop dash")
	_player.set_dash_ability(a)
	_player.request_dash()
	_player._physics_process(DT)
	assert_true(TimeControl.is_active(), "the world stopped")
	assert_true(_player.is_dashing(), "and the engine dash ran")
	assert_true(_player.health.is_engine_invulnerable(), "with its i-frames")
	# Still resting: the stop is refused, the dash still happens.
	TimeControl.debug_advance(1.0)
	for i in 120:
		_player._physics_process(DT)
	_player.request_dash()
	_player._physics_process(DT)
	assert_false(TimeControl.is_active(), "the stop is on its cooldown")
	assert_true(_player.is_dashing(), "the dash goes ahead either way")
	_player.set_dash_ability(null)


func test_a_time_stop_alone_grants_no_iframes() -> void:
	var a := _ability("return { on_dash = function(ctx, dir) world.time_stop(1) end }")
	_player.set_dash_ability(a)
	_player.request_dash()
	_player._physics_process(DT)
	assert_true(TimeControl.is_active())
	assert_false(_player.is_dashing())
	assert_false(_player.health.is_engine_invulnerable(), "no i-frames from a time stop")
	_player.set_dash_ability(null)


func test_a_time_stop_dash_freezes_an_enemy_shot_while_the_player_shot_moves() -> void:
	for pref: String in ["gdscript", "native"]:
		TimeControl.cancel()
		var mgr := BulletManager.new()
		mgr.backend_preference = pref
		mgr.capacity = 64
		mgr.world_bounds = Rect2(-4000, -4000, 8000, 8000)
		mgr.render_enabled = false
		mgr.auto_step = false
		add_child_autofree(mgr)
		if mgr.backend != pref:
			gut.p("%s backend not available" % pref)
			continue
		_shot(mgr, Layers.PLAYER, Vector2(0, -300), Vector2(600, 0))
		_shot(mgr, Layers.ENEMY, Vector2(0, 300), Vector2(600, 0))
		_shot(mgr, Layers.ENEMY, Vector2(0, 600), Vector2(600, 0), true)
		var a := _ability(AbilityLibrary.starter_source("time_stop_dash"))
		_player.set_dash_ability(a)
		_player.request_dash()
		_player._physics_process(DT)
		assert_true(TimeControl.is_active(), pref)
		for i in 30:
			mgr.step(DT)
		@warning_ignore_start("unsafe_cast")
		var positions: PackedVector2Array = mgr.snapshot()["pos"]
		@warning_ignore_restore("unsafe_cast")
		assert_eq(positions.size(), 3, pref)
		if positions.size() == 3:
			assert_almost_eq(positions[0].x, 300.0, 0.1, "%s: the player's shot keeps moving" % pref)
			assert_almost_eq(positions[1].x, 0.0, 0.1, "%s: the enemy shot is frozen" % pref)
			assert_almost_eq(positions[2].x, 150.0, 0.1, "%s: a Null shot moves at half speed" % pref)
		_player.set_dash_ability(null)
		# Next round: a fresh dash.
		TimeControl.cancel()
		_player.respawn(Vector2.ZERO)


func _shot(mgr: BulletManager, owner: int, pos: Vector2, vel: Vector2, null_attack: bool = false) -> int:
	var req := ShotRequest.new()
	req.reset()
	req.position = pos
	req.velocity = vel
	req.lifetime = 5.0
	req.radius = 4.0
	req.owner_layer = owner
	req.hit_mask = Layers.hostile_to(owner)
	req.pierces_script_invuln = null_attack
	return mgr.spawn(req)
