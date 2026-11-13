extends GutTest
## Real Lua messages through ScriptHost, turned into ScriptProblems: compile
## errors, load-time runtime errors and guard stops (with the line the stop
## landed on). Lives with the host guards: it trips the watchdog.


func _host() -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	assert_true(host.is_ready(), "sandbox did not build")
	return host


func test_a_real_compile_error() -> void:
	var host := _host()
	var r := host.load_string("return {\n  on_spawn = function(b)\n    b:set_velocity(1 2)\n  end,\n}", "weapon.lua")
	assert_false(r.ok)
	var p := ScriptProblem.from_result(r, "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.COMPILE)
	assert_eq(p.line, 3)
	assert_eq(p.message, "Expected ')' before '2'.")
	assert_eq(p.headline(), "line 3: expected ')' before '2'. Still running the last good script.")


func test_a_missing_end() -> void:
	var host := _host()
	var r := host.load_string("return {\n  on_spawn = function(b)\n", "weapon.lua")
	var p := ScriptProblem.from_result(r, "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.COMPILE)
	assert_eq(p.message, "Missing 'end' for the 'function' that starts on line 2.")


func test_a_real_runtime_error_at_load() -> void:
	var host := _host()
	var r := host.load_string("local cfg = nil\nlocal s = cfg.speed\nreturn {}", "weapon.lua")
	var p := ScriptProblem.from_result(r, "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.RUNTIME)
	assert_eq(p.line, 2)
	assert_eq(p.message, "'cfg' is nil, so it has no fields. Is it defined?")
	assert_false(p.details.contains("weapon.lua"), p.details)


func test_an_error_call_keeps_the_players_text() -> void:
	var host := _host()
	var r := host.load_string("\n\nerror('speed must be positive')", "weapon.lua")
	var p := ScriptProblem.from_result(r, "weapon.lua")
	assert_eq(p.line, 3)
	assert_eq(p.message, "Speed must be positive.")


func test_an_instruction_budget_stop_names_the_line_of_the_loop() -> void:
	var host := _host()
	var r := host.load_string("local n = 0\nwhile true do\n  n = n + 1\nend\nreturn {}", "weapon.lua")
	assert_false(r.ok)
	assert_eq(r.stopped, "instruction budget")
	var p := ScriptProblem.from_result(r, "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.GUARD)
	assert_between(p.line, 2, 4, "the stop lands inside the loop")
	assert_eq(p.message, "script timeout.")
	assert_eq(p.headline(), "line %d: script timeout. Still running the last good script." % p.line)
	var again := host.load_string("return { name = 'ok' }", "weapon.lua")
	assert_true(again.ok, "the host keeps working after a stop: %s" % again.error)


func test_a_stop_inside_a_library_wrapper_has_no_line_in_the_players_script() -> void:
	var host := _host()
	# Each call spends most of its steps inside the sandbox's string wrappers.
	var r := host.load_string("while true do local _ = ('x'):rep(8) end", "weapon.lua")
	assert_eq(r.stopped, "instruction budget")
	assert_true(r.stop_line == 0 or r.stop_line == 1, "line %d" % r.stop_line)
