extends GutTest
## ScriptHost.call_fire: on_fire(ctx) and spawn{...}. Records are kept only
## when on_fire returns cleanly. Lives with the host guards: one case trips
## the watchdog.


func _host(code: String) -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	assert_true(host.is_ready(), "sandbox did not build")
	var r := host.load_string(code, "default.lua")
	assert_true(r.ok, "load: %s" % r.error)
	return host


func _f(v: Variant) -> float:
	return v if v is float else NAN


func _ctx(aim: float = 0.5) -> ShotContext:
	var c := ShotContext.new()
	c.muzzle_position = Vector2(10, 20)
	c.aim_angle = aim
	c.aim_direction = Vector2.from_angle(aim)
	c.time = 3.0
	c.shot_index = 7
	c.trigger_pressed = true
	c.trigger_held_time = 0.4
	return c


func test_spawn_records_carry_only_what_the_script_set() -> void:
	var host := _host("return { on_fire = function(ctx)\n  spawn { angle = ctx.aim + 1, speed = 480, damage = 2 }\n  spawn { pos = { x = ctx.pos.x + 5, y = ctx.y }, spin = 2.2, accel = -10, lifetime = 1, radius = 6 }\nend }")
	var r := host.call_fire(_ctx(0.5))
	assert_true(r.ok, r.error)
	var spawns := host.take_pending_spawns()
	assert_eq(spawns.size(), 2)
	assert_almost_eq(_f(spawns[0]["angle"]), 1.5, 1e-6)
	assert_eq(_f(spawns[0]["speed"]), 480.0)
	assert_eq(_f(spawns[0]["damage"]), 2.0)
	assert_false(spawns[0].has("lifetime"), "unset fields fall back to the weapon's")
	assert_eq(_f(spawns[1]["x"]), 15.0)
	assert_eq(_f(spawns[1]["y"]), 20.0)
	assert_eq(_f(spawns[1]["spin"]), 2.2)
	assert_eq(_f(spawns[1]["accel"]), -10.0)
	assert_eq(host.take_pending_spawns().size(), 0, "taking clears them")


func test_ctx_fields() -> void:
	var host := _host("return { on_fire = function(ctx)\n  assert(ctx.time == 3 and ctx.n == 7 and ctx.shot_count == 7)\n  assert(ctx.pressed == true and ctx.held_time > 0.39)\n  assert(math.abs(ctx.aim_dir.x - math.cos(ctx.aim)) < 1e-9)\n  assert(math.abs(TAU - 2 * PI) < 1e-12 and math.abs(rad(180) - PI) < 1e-12)\n  spawn { angle = ctx.aim }\nend }")
	var r := host.call_fire(_ctx())
	assert_true(r.ok, r.error)
	assert_eq(host.take_pending_spawns().size(), 1)


func test_an_error_spawns_nothing() -> void:
	var host := _host("return { on_fire = function(ctx)\n  spawn { angle = 0 }\n  local x = nil\n  return x.y\nend }")
	var r := host.call_fire(_ctx())
	assert_false(r.ok)
	assert_string_contains(r.error, "default.lua:4:")
	assert_eq(host.take_pending_spawns().size(), 0)


func test_bad_spawn_fields_are_errors_with_the_players_line() -> void:
	var host := _host("return { on_fire = function(ctx)\n  spawn { angle = 'up' }\nend }")
	var r := host.call_fire(_ctx())
	assert_false(r.ok)
	var p := ScriptProblem.from_result(r, "default.lua", "on_fire")
	assert_eq(p.line, 2)
	assert_string_contains(p.message, "angle")


func test_spawn_outside_on_fire_is_an_error() -> void:
	var host := ScriptHost.new()
	var r := host.load_string("spawn { angle = 0 }\nreturn {}", "default.lua")
	assert_false(r.ok)
	assert_string_contains(r.error, "only works inside on_fire")


func test_spawns_past_the_cap_are_dropped_and_counted() -> void:
	var host := _host("return { on_fire = function(ctx)\n  for i = 1, 300 do spawn { angle = i } end\nend }")
	var r := host.call_fire(_ctx())
	assert_true(r.ok, r.error)
	assert_eq(host.take_pending_spawns().size(), ScriptHost.FIRE_SPAWN_CAP)
	assert_eq(host.spawns_dropped(), 300 - ScriptHost.FIRE_SPAWN_CAP)


func test_a_stopped_on_fire_spawns_nothing_and_the_next_call_works() -> void:
	var host := _host("local calls = 0\nreturn { on_fire = function(ctx)\n  calls = calls + 1\n  spawn { angle = 0 }\n  if calls == 1 then while true do end end\nend }")
	var r := host.call_fire(_ctx())
	assert_false(r.ok)
	assert_eq(r.stopped, "instruction budget")
	assert_eq(host.take_pending_spawns().size(), 0)
	var again := host.call_fire(_ctx())
	assert_true(again.ok, again.error)
	assert_eq(host.take_pending_spawns().size(), 1)


func test_sense_is_an_empty_table_until_granted() -> void:
	var host := _host("return { on_fire = function(ctx)\n  assert(type(sense) == 'table' and sense.nearest_enemy == nil)\nend }")
	assert_true(host.call_fire(_ctx()).ok)


func test_without_on_fire_call_fire_is_a_no_op() -> void:
	var host := _host("return { speed = 300 }")
	var r := host.call_fire(_ctx())
	assert_true(r.ok)
	assert_eq(host.take_pending_spawns().size(), 0)
