extends GutTest
## ScriptProblem: Lua errors, guard stops and script warnings become short
## plain-language messages with a line, without internal chunk names or paths.
## Pure GDScript; the real Lua messages are covered in
## tests/scripting/host/test_script_editor_errors.gd.


func _result(error: String, stopped: String = "", stop_line: int = 0) -> ScriptHost.RunResult:
	var r := ScriptHost.RunResult.new()
	r.error = error
	r.stopped = stopped
	r.stop_line = stop_line
	return r


func test_compile_error_gets_its_line_and_a_plain_sentence() -> void:
	var p := ScriptProblem.from_result(_result("weapon.lua:3: ')' expected near '2'"), "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.COMPILE)
	assert_eq(p.line, 3)
	assert_eq(p.message, "Expected ')' before '2'.")
	assert_eq(p.text(), "line 3: expected ')' before '2'.")
	assert_eq(p.headline(), "line 3: expected ')' before '2'. Still running the last good script.")
	assert_eq(p.headline(false), "line 3: expected ')' before '2'. Still running the basic shot.")
	assert_false(p.text().contains("weapon.lua"))


func test_missing_end_names_the_opening_line() -> void:
	var p := ScriptProblem.from_result(_result("weapon.lua:9: 'end' expected (to close 'function' at line 2) near <eof>"), "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.COMPILE)
	assert_eq(p.line, 9)
	assert_eq(p.message, "Missing 'end' for the 'function' that starts on line 2.")


func test_unexpected_symbol_and_unfinished_string() -> void:
	assert_eq(ScriptProblem.plain_message("unexpected symbol near '+'"), "Unexpected '+' here.")
	assert_eq(ScriptProblem.plain_message("unfinished string near '\"abc'"), "A string is missing its closing quote.")
	assert_eq(ScriptProblem.plain_message("'=' expected near 'x'"), "Expected '=' before 'x'.")
	assert_eq(ScriptProblem.plain_message("'then' expected near <eof>"), "The script ends too early: expected 'then'.")


func test_runtime_error_in_a_callback() -> void:
	var p := ScriptProblem.from_result(_result("weapon.lua:5: attempt to index a nil value (local 'target')"), "weapon.lua", "on_hit")
	assert_eq(p.kind, ScriptProblem.Kind.RUNTIME)
	assert_eq(p.line, 5)
	assert_eq(p.callback, "on_hit")
	assert_eq(p.message, "'target' is nil, so it has no fields. Is it defined?")
	assert_eq(p.text(), "line 5: 'target' is nil, so it has no fields. Is it defined?")
	assert_false(p.headline().contains("on_hit"), "the callback is for details, not the line")
	assert_true(p.detail_text().contains("on_hit"), p.detail_text())


func test_common_runtime_messages() -> void:
	assert_eq(ScriptProblem.plain_message("attempt to call a nil value (global 'spwan')"), "'spwan' is not a function (it is nil). Check the spelling.")
	assert_eq(ScriptProblem.plain_message("attempt to call a nil value (method 'boom')"), "'boom' does not exist here, so it cannot be called.")
	assert_eq(ScriptProblem.plain_message("attempt to perform arithmetic on a nil value (field 'speed')"), "Can't do math with 'speed': it is nil.")
	assert_eq(ScriptProblem.plain_message("attempt to compare number with nil"), "Can't compare a number with nil.")
	assert_eq(ScriptProblem.plain_message("attempt to concatenate a table value (local 't')"), "Can't join 't' into text: it is a table.")
	assert_eq(ScriptProblem.plain_message("bad argument #1 to 'cos' (number expected, got nil)"), "cos(): argument 1 should be a number, got nil.")
	assert_eq(ScriptProblem.plain_message("set_velocity: expected two numbers"), "set_velocity() expected two numbers.")
	assert_eq(ScriptProblem.plain_message("boom"), "Boom.")
	assert_eq(ScriptProblem.plain_message("table: 0x40c39120"), "The script raised an error without a message.")


func test_a_message_from_another_chunk_has_no_line_and_no_path() -> void:
	var p := ScriptProblem.from_result(_result("@res://scripting/sandbox.lua:90: string.rep: result too large (sandbox limit)"), "weapon.lua")
	assert_eq(p.line, 0, "a line in an internal file is not a line in the player's script")
	assert_false(p.message.contains("res://"), p.message)
	assert_false(p.message.contains("sandbox.lua"), p.message)
	assert_false(p.details.contains("sandbox.lua"), p.details)
	assert_eq(p.message, "string.rep: result too large (sandbox limit)")


func test_strip_internals_removes_engine_prefixes_and_addresses() -> void:
	assert_eq(ScriptProblem.strip_internals("LuaBulletBehavior: on_hit: weapon.lua:4: boom"), "boom")
	assert_eq(ScriptProblem.strip_internals("BulletPool.spawn: rejected res://x/y.gd:12: it"), "rejected it")
	assert_eq(ScriptProblem.strip_internals("bad value table: 0xdeadbeef"), "bad value table: …")
	assert_eq(ScriptProblem.strip_internals("[string \"weapon\"]:7: oops"), "oops")


func test_guard_trips_say_which_limit_and_keep_the_line() -> void:
	var steps := ScriptProblem.from_result(_result("script timeout (instruction budget)", "instruction budget", 4), "weapon.lua", "on_batch")
	assert_eq(steps.kind, ScriptProblem.Kind.GUARD)
	assert_eq(steps.line, 4)
	assert_eq(steps.headline(), "line 4: script timeout. Still running the last good script.")
	assert_eq(steps.details, "ran more than 100,000 steps in one call. Look for a loop that never ends.")
	var clock := ScriptProblem.from_result(_result("script timeout (wall clock)", "wall clock"), "weapon.lua")
	assert_eq(clock.line, 0)
	assert_eq(clock.message, "script timeout.")
	assert_eq(clock.details, "took longer than 50 ms in one call. Look for a loop that never ends.")
	var mem := ScriptProblem.from_result(_result("script timeout (memory cap)", "memory cap"), "weapon.lua")
	assert_eq(mem.message, "script used too much memory.")
	assert_eq(mem.details, "used more than 64 MB of memory. Look for a table that keeps growing.")


func test_warnings_from_script_warnings() -> void:
	var speed := ScriptProblem.from_warning(
		"BulletPool.spawn.clamp.speed",
		ScriptWarnings.speed_message("BulletPool.spawn", Vector2(9000, 0)),
		7
	)
	assert_eq(speed.kind, ScriptProblem.Kind.WARNING)
	assert_eq(speed.count, 7)
	assert_eq(speed.message, "Speed 9000 is out of range; the game used 4000 instead.")
	assert_eq(speed.text(), "Speed 9000 is out of range; the game used 4000 instead.  ×7")
	assert_false(speed.text().contains("BulletPool"))
	var life := ScriptProblem.from_warning(
		"BulletPool.spawn.clamp.lifetime",
		ScriptWarnings.clamp_message("BulletPool.spawn", "lifetime", 900.0, 600.0, "MAX_LIFETIME"),
		1
	)
	assert_eq(life.message, "Lifetime 900 is out of range; the game used 600 instead.")
	var removed := ScriptProblem.from_warning("BulletPool.set_velocity", ScriptWarnings.removed_message("BulletPool.set_velocity", "velocity (nan, 0) is not finite"), 2)
	assert_eq(removed.message, "A shot was removed: velocity (nan, 0) is not finite.")
	var native := ScriptProblem.from_warning("NativeBackend.spawn", "NativeBackend.spawn: rejected a shot with a non-finite velocity", 1)
	assert_eq(native.message, "A shot was not fired: its velocity was not a finite number.")


func test_repeats_and_keys() -> void:
	var a := ScriptProblem.from_result(_result("weapon.lua:2: boom"), "weapon.lua", "on_hit")
	var b := ScriptProblem.from_result(_result("weapon.lua:2: boom"), "weapon.lua", "on_hit")
	assert_eq(a.key(), b.key())
	b.count = 12
	assert_eq(b.text(), "line 2: boom.  ×12")
	assert_eq(b.headline(), "line 2: boom. Still running the last good script.", "the status line has no count")


func test_a_load_without_a_table() -> void:
	var p := ScriptProblem.from_result(_result(LuaShot.NO_TABLE_ERROR), "weapon.lua")
	assert_eq(p.kind, ScriptProblem.Kind.COMPILE)
	assert_eq(p.line, 0)
	assert_true(p.message.contains("return {"), p.message)
