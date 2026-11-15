extends GutTest
## LuaDashAbility under the guard (host process: these tests stop chunks
## with the instruction hook, so they stay out of the process that runs
## Godot callables from Lua; see tools/run_tests.sh). A runaway or memory-hog
## on_dash is stopped every time and counts as no dash; a load that is
## stopped keeps the running version.


class FakePlayer:
	extends RefCounted
	var global_position := Vector2.ZERO
	var aim_direction := Vector2.RIGHT
	var dash_cooldown := 1.5


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


func test_a_runaway_on_dash_is_stopped_every_time_and_the_host_recovers() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) while true do end end }")
	for i in 5:
		var t0 := Time.get_ticks_msec()
		assert_false(_a.on_dash(_p, Vector2.RIGHT))
		assert_lt(Time.get_ticks_msec() - t0, 1000, "stopped by the guard")
		assert_ne(_a.last_error.stopped, "", "a guard stop")
	assert_eq(_a.error_attempts, 5)
	assert_eq(_a.error_total, 1, "the same stop is reported once")
	var p := ScriptProblem.from_result(_a.last_error, _a.chunk_name, LuaDashAbility.HOOK)
	assert_eq(p.kind, ScriptProblem.Kind.GUARD)
	_apply_ok("return { on_dash = function(ctx, dir) return dir.x > 0 end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "a good file runs after the stops")


func test_a_memory_hog_is_stopped() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) local t = {} for i = 1, 1e9 do t[i] = string.rep('x', 1024) .. i end end }")
	assert_false(_a.on_dash(_p, Vector2.RIGHT))
	assert_ne(_a.last_error.stopped, "")


func test_a_stopped_load_keeps_the_running_version() -> void:
	_apply_ok("return { name = 'One', on_dash = function() return false end }")
	var r := _a.apply("while true do end")
	assert_false(r.ok)
	assert_ne(r.stopped, "")
	assert_eq(_a.title, "One")
	assert_false(_a.on_dash(_p, Vector2.RIGHT), "still the old on_dash")
	assert_eq(_a.error_total, 0)


func test_each_resumed_slice_has_its_own_budget_and_a_runaway_slice_is_stopped() -> void:
	_apply_ok("return { on_dash = function(ctx, dir) for i = 1, 3 do for j = 1, 30000 do end coroutine.yield() end while true do end end }")
	assert_true(_a.on_dash(_p, Vector2.RIGHT))
	for i in 2:
		_a.tick()
	assert_eq(_a.error_total, 0, "three slices of 30k steps each are fine")
	assert_true(_a.is_running())
	_a.tick()
	assert_eq(_a.error_total, 1)
	assert_ne(_a.last_error.stopped, "")
	assert_false(_a.is_running())
	# Stopped slices park coroutines; after enough of them the state
	# rotates, and the file keeps working.
	for i in 4:
		assert_true(_a.on_dash(_p, Vector2.RIGHT))
		for j in 3:
			_a.tick()
		assert_false(_a.is_running())
	assert_eq(_a.error_attempts, 5)
	assert_eq(_a.error_total, 1, "the same stop is reported once")
	assert_true(_a.on_dash(_p, Vector2.RIGHT), "still yields and resumes")
	assert_true(_a.is_running())

