extends GutTest
## LuaDashAbility (ability-scripting.md A1-A3): on_dash through ScriptHost
## under the guard, player:dash() as the engine dash, nil/false returns, the
## file cooldown, errors and stops, hot reload with `state`, spawn{}.

const DEFAULT_PATH := "res://scripting/abilities/default_dash.lua.txt"


## Stands in for the player's dash hook side: the engine dash and the
## dash_cooldown it falls back to.
class FakePlayer:
	extends RefCounted
	var global_position := Vector2(10, 20)
	var aim_direction := Vector2.UP
	var velocity := Vector2.ZERO
	var dash_cooldown := 1.5
	var emitter: ShotEmitter
	var gate_open := true
	var dashes: Array[Vector2] = []
	var refreshes := 0
	var on_builtin := Callable()
	var slot_left := 0.0

	func get_ability_cooldown_left() -> float:
		return slot_left

	func perform_builtin_dash(dir: Vector2) -> bool:
		if on_builtin.is_valid():
			on_builtin.call()
		if not gate_open:
			return false
		dashes.append(dir)
		return true

	func refresh_dash_ability() -> void:
		refreshes += 1


class RecordingEmitter:
	extends ShotEmitter
	var positions: Array[Vector2] = []
	var angles: Array[float] = []
	var owners: Array[int] = []
	var speeds: Array[float] = []

	func request_shot_id(r: ShotRequest) -> int:
		positions.append(r.position)
		angles.append(r.angle)
		owners.append(r.owner_layer)
		speeds.append(r.velocity.length())
		return positions.size()


var _p: FakePlayer
var _a: LuaDashAbility


func before_each() -> void:
	ScriptWarnings.reset()
	_p = FakePlayer.new()
	_a = LuaDashAbility.new()
	_a.bind_player(_p)
	_a.error_backoff_msec = 0


func _apply_ok(code: String) -> void:
	var r := _a.apply(code)
	assert_true(r.ok, "applied: %s" % r.error)


func test_no_script_is_the_engine_dash() -> void:
	assert_false(_a.has_script())
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(_p.dashes, [Vector2.RIGHT] as Array[Vector2])
	assert_almost_eq(_a.get_cooldown(), 1.5, 0.0001, "engine cooldown")


func test_default_file_calls_the_engine_dash_along_dir() -> void:
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	assert_eq(_a.title, "Dash")
	var dir := Vector2(3, -4).normalized()
	assert_true(_a.on_dash(_p, dir))
	assert_eq(_p.dashes.size(), 1)
	assert_almost_eq(_p.dashes[0].x, dir.x, 0.000001)
	assert_almost_eq(_p.dashes[0].y, dir.y, 0.000001)
	assert_eq(_a.builtin_dashes, 1)


func test_default_file_returns_false_while_the_engine_dash_is_gated() -> void:
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	_p.gate_open = false
	assert_false(_a.on_dash(_p, Vector2.RIGHT), "player:dash() false -> no dash")
	assert_eq(_a.error_total, 0)


func test_default_file_has_no_cooldown_field_so_the_engine_cooldown_applies() -> void:
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	_p.dash_cooldown = 0.5
	assert_almost_eq(_a.get_cooldown(), 0.5, 0.0001)


func test_zero_direction_uses_the_aim() -> void:
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	assert_true(_a.on_dash(_p, Vector2.ZERO))
	assert_almost_eq(_p.dashes[0].y, -1.0, 0.000001)


func test_cooldown_field_is_read_and_clamped_and_refreshes_the_player() -> void:
	_apply_ok("return { cooldown = 0.6, on_dash = function(ctx, dir) end }")
	assert_almost_eq(_a.get_cooldown(), 0.6, 0.0001)
	assert_eq(_p.refreshes, 1, "apply() calls refresh_dash_ability")
	_apply_ok("return { cooldown = 0, on_dash = function(ctx, dir) end }")
	assert_almost_eq(_a.get_cooldown(), LuaDashAbility.MIN_COOLDOWN, 0.0001)
	_apply_ok("return { cooldown = 1e9, on_dash = function(ctx, dir) end }")
	assert_almost_eq(_a.get_cooldown(), LuaDashAbility.MAX_COOLDOWN, 0.0001)
	_apply_ok("return { cooldown = 0/0, on_dash = function(ctx, dir) end }")
	assert_almost_eq(_a.get_cooldown(), 1.5, 0.0001, "NaN falls back to the engine cooldown")
	assert_eq(_p.refreshes, 4)


func test_nil_counts_as_a_dash_and_false_does_not() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "nil -> true")
	assert_eq(_p.dashes.size(), 0, "no engine dash unless player:dash() is called")
	_apply_ok("return { on_dash = function(ctx, dir) return false end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	_apply_ok("return { on_dash = function(ctx, dir) return 0 end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "any other value -> true")
	_apply_ok("return { on_dash = function(ctx, dir) return {} end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "a table is dropped -> true")


func test_ctx_and_dir_reach_the_hook() -> void:
	_apply_ok("""
return { on_dash = function(ctx, dir)
	if ctx.pos.x ~= 10 or ctx.pos.y ~= 20 then error("pos") end
	if math.abs(dir.x - 0.6) > 1e-6 or math.abs(dir.y - 0.8) > 1e-6 then error("dir") end
	if math.abs(ctx.aim_dir.y + 1) > 1e-6 then error("aim") end
	return true
end }""")
	assert_true(_a.on_dash(_p, Vector2(0.6, 0.8)))
	assert_eq(_a.error_total, 0, str(_a.last_error.error if _a.last_error else ""))


func test_file_without_on_dash_dashes_like_the_engine() -> void:
	_apply_ok("return { name = 'Tuned', cooldown = 0.8 }")
	assert_true(_a.on_dash(_p, Vector2.LEFT))
	assert_eq(_p.dashes, [Vector2.LEFT] as Array[Vector2])
	assert_almost_eq(_a.get_cooldown(), 0.8, 0.0001)


func test_player_dash_outside_on_dash_is_an_error() -> void:
	var r := _a.apply("player:dash(0) return { on_dash = function() end }")
	assert_false(r.ok)
	assert_string_contains(r.error, "only works inside an ability's on_dash")
	assert_eq(_p.dashes.size(), 0)


func test_player_dash_with_a_dot_or_a_bad_angle_errors_and_nan_is_false() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) player.dash(1) end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_string_contains(_a.last_error.error, "colon")
	_apply_ok("return { on_dash = function(ctx, dir) player:dash('x') end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_string_contains(_a.last_error.error, "angle")
	_apply_ok("return { on_dash = function(ctx, dir) if player:dash(0/0) then error('nan dashed') end return false end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(_p.dashes.size(), 0)


func test_weapons_cannot_call_player_dash() -> void:
	var host := ScriptHost.new()
	var r := host.load_string("return { on_fire = function(ctx) player:dash(0) end }", "w.lua")
	assert_true(r.ok)
	var fire := host.call_fire(ShotContext.new())
	assert_false(fire.ok)
	assert_string_contains(fire.error, "only works inside an ability's on_dash")


func test_an_error_is_false_reported_and_rests() -> void:
	_a.error_backoff_msec = 60000
	_apply_ok("return { on_dash = function(ctx, dir)\n  error('boom')\nend }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(_a.error_total, 1)
	assert_string_contains(_a.last_error.error, "boom")
	assert_eq(ScriptWarnings.count(LuaDashAbility.ERROR_KEY), 1)
	var p := ScriptProblem.from_result(_a.last_error, _a.chunk_name, LuaDashAbility.HOOK)
	assert_eq(p.line, 2, "the editor gets the line")
	assert_false(_a.on_dash(_p, Vector2.RIGHT), "resting")
	assert_eq(_a.error_total, 1, "a buffered press does not rerun it while resting")
	_apply_ok("return { on_dash = function(ctx, dir) end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "a good save ends the rest")


func test_an_error_after_player_dash_keeps_the_engine_dash_but_counts_false() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) player:dash(0) error('after') end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(_p.dashes.size(), 1, "player:dash() takes effect right away, like PlayerState setters")


func test_a_failed_load_keeps_the_running_version() -> void:
	_apply_ok("return { name = 'One', cooldown = 0.7, on_dash = function() return false end }")
	var r := _a.apply("return { on_dash = function( end }")
	assert_false(r.ok)
	assert_eq(_a.title, "One")
	assert_almost_eq(_a.get_cooldown(), 0.7, 0.0001)
	assert_false(_a.on_dash(_p, Vector2.RIGHT), "still the old on_dash")
	r = _a.apply("x = 1")
	assert_false(r.ok)
	assert_eq(r.error, LuaShot.NO_TABLE_ERROR)


func test_state_carries_over_hot_reload_and_globals_do_not() -> void:
	var code := """
g = (g or 0) + 1
state.n = state.n or 0
return { on_dash = function(ctx, dir)
	state.n = state.n + 1
	return state.n == %d and g == 1
end }"""
	_apply_ok(code % 1)
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "n == 1")
	_apply_ok(code % 2)
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "state.n carried, g fresh")
	assert_false(_a.apply("state.n = 100 return { on_dash = function( end }").ok)
	_apply_ok(code % 3)
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "a failed load left state alone")


func test_state_copy_warnings_are_reported() -> void:
	_apply_ok("state.f = function() end return { on_dash = function() end }")
	var r := _a.apply("return { on_dash = function() end }")
	assert_true(r.ok)
	assert_gt(r.warnings.size(), 0)
	assert_gt(ScriptWarnings.count(LuaDashAbility.STATE_WARNING_KEY), 0)


func test_spawn_sends_plain_player_shots() -> void:
	var em := RecordingEmitter.new()
	_p.emitter = em
	_apply_ok("return { speed = 500, on_dash = function(ctx, dir) spawn { angle = 1 } spawn { pos = { x = 1, y = 2 } } end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(em.positions.size(), 2)
	assert_almost_eq(em.angles[0], 1.0, 0.0001)
	assert_eq(em.positions[0], Vector2(10, 20), "from the player")
	assert_almost_eq(em.speeds[0], 500.0, 0.01)
	assert_eq(em.positions[1], Vector2(1, 2))
	assert_eq(em.owners[0], Layers.PLAYER)


func test_an_erroring_on_dash_spawns_nothing() -> void:
	var em := RecordingEmitter.new()
	_p.emitter = em
	_apply_ok("return { on_dash = function(ctx, dir) spawn { angle = 1 } error('x') end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(em.positions.size(), 0)


func test_apply_from_inside_on_dash_is_refused() -> void:
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	var nested: Array = []
	_p.on_builtin = func() -> void: nested.append(_a.apply("return {}"))
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	assert_eq(nested.size(), 1)
	@warning_ignore("unsafe_cast")
	var r := nested[0] as ScriptHost.RunResult
	assert_false(r.ok)
	assert_eq(r.error, LuaDashAbility.NESTED_APPLY_ERROR)
	assert_eq(_a.title, "Dash")


func test_a_freed_player_is_harmless() -> void:
	var node := Node2D.new()
	_a.bind_player(node)
	node.free()
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	assert_false(_a.on_dash(null, Vector2.RIGHT))


func test_a_yielding_on_dash_counts_as_a_dash_and_resumes_next_tick() -> void:
	var em := RecordingEmitter.new()
	_p.emitter = em
	_apply_ok("""
state.k = 0
return { on_dash = function(ctx, dir)
	state.k = 1
	coroutine.yield()
	state.k = 2
	spawn { angle = 0 }
	player:dash(0)
end }""")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "a yield is a dash that has started")
	assert_true(_a.is_running())
	assert_eq(_p.dashes.size(), 0, "nothing after the yield ran yet")
	assert_false(_a.on_dash(_p, Vector2.RIGHT), "busy while it runs")
	_a.tick()
	assert_false(_a.is_running())
	assert_eq(_p.dashes.size(), 1, "player:dash() works in a resumed slice")
	assert_eq(em.positions.size(), 1, "spawn{} works in a resumed slice")
	assert_eq(_a.error_total, 0)
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "free again")


func test_a_yield_inside_pcall_stays_inside_it() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) local ok = pcall(function() coroutine.yield() end) return false end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_false(_a.is_running())


func test_a_hook_that_yields_forever_is_dropped_after_the_cap() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) while true do coroutine.yield() end end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	for i in LuaDashAbility.MAX_PENDING_TICKS + 1:
		_a.tick()
	assert_false(_a.is_running())
	assert_eq(ScriptWarnings.count(LuaDashAbility.PENDING_CAP_KEY), 1)
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "the slot works again")


func test_an_error_after_a_yield_is_reported() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) coroutine.yield()\n error('late') end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	_a.tick()
	assert_eq(_a.error_total, 1)
	assert_string_contains(_a.last_error.error, "late")
	assert_false(_a.is_running())


func test_a_reload_drops_a_running_hook() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) coroutine.yield() player:dash(0) end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	_apply_ok("return { on_dash = function(ctx, dir) end }")
	assert_false(_a.is_running())
	_a.tick()
	assert_eq(_p.dashes.size(), 0, "the old hook never resumes")


func test_a_raw_move_input_reaches_the_hook_normalized() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) state.x, state.y = dir.x, dir.y end }")
	assert_true(_a.on_dash(_p, Vector2(0.3, 0.4)), "an analog stick half way")
	_apply_ok("return { name = string.format('%.4f,%.4f', state.x, state.y) }")
	assert_eq(_a.title, "0.6000,0.8000")


func test_a_tiny_or_broken_direction_uses_the_aim_like_the_engine() -> void:
	_apply_ok(FileAccess.get_file_as_string(DEFAULT_PATH))
	assert_true(_a.on_dash(_p, Vector2(0.0001, 0.0)))
	assert_true(_a.on_dash(_p, Vector2(NAN, 1.0)))
	assert_eq(_p.dashes.size(), 2)
	for d: Vector2 in _p.dashes:
		assert_almost_eq(d.y, -1.0, 0.000001, "aim is up")


func test_dash_cooldown_left_reads_the_slot_cooldown() -> void:
	_p.slot_left = 0.75
	_apply_ok("state.top = player:dash_cooldown_left() return { on_dash = function(ctx, dir) state.hook = player:dash_cooldown_left() end }")
	_p.slot_left = 0.0
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	_apply_ok("return { name = state.top .. ',' .. state.hook }")
	assert_eq(_a.title, "0.75,0.0")


func test_dash_cooldown_left_needs_a_colon_and_an_ability_file() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) player.dash_cooldown_left() end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_string_contains(_a.last_error.error, "colon")
	var host := ScriptHost.new()
	var r := host.load_string("return { on_fire = function(ctx) player:dash_cooldown_left() end }", "w.lua")
	assert_true(r.ok)
	var fire := host.call_fire(ShotContext.new())
	assert_false(fire.ok)
	assert_string_contains(fire.error, "only works in an ability file")
