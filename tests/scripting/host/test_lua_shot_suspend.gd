extends GutTest
## Three guard stops suspend the script until the next load (slice §7.5).
## Lives with the host guards: it trips the watchdog. The weapon has no bullet
## callbacks, only on_fire.

var _mgr: BulletManager


func before_each() -> void:
	ScriptWarnings.reset()
	_mgr = BulletManager.new()
	_mgr.backend_preference = "gdscript"
	_mgr.capacity = 64
	_mgr.logical_cap = 64
	_mgr.enemy_reserve = 0
	_mgr.render_enabled = false
	_mgr.auto_step = false
	add_child_autofree(_mgr)


func after_each() -> void:
	if is_instance_valid(_mgr):
		_mgr._behaviors.clear()


func _ctx() -> ShotContext:
	var c := ShotContext.new()
	c.target_mask = Layers.ENEMY
	return c


func test_three_timeouts_suspend_on_fire_until_the_next_load() -> void:
	var shot := LuaShot.new(_mgr)
	var code := "return { on_fire = function(ctx)\n  spawn { angle = ctx.aim }\n  while true do end\nend }"
	var r := shot.apply(code)
	assert_true(r.ok, r.error)
	for i in 3:
		shot.fire(_ctx(), _mgr.emitter)
	var b := shot.behavior()
	assert_eq(b.error_count("on_fire"), 3)
	assert_eq(_mgr.alive_count(), 0, "a stopped on_fire spawns nothing")
	assert_true(b.suspended())
	var p := ScriptProblem.from_result(b.last_error("on_fire"), shot.chunk_name, "on_fire")
	assert_eq(p.kind, ScriptProblem.Kind.GUARD)
	assert_eq(p.headline(), "line 3: script timeout. Still running the last good script.")
	shot.fire(_ctx(), _mgr.emitter)
	assert_eq(b.error_count("on_fire"), 3, "suspended: on_fire is not called again")
	assert_eq(_mgr.alive_count(), 1, "the weapon falls back to its plain shot so the game keeps going")
	assert_true(shot.apply(code).ok)
	assert_false(shot.behavior().suspended(), "a new load lifts it")
