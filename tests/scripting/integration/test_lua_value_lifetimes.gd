extends GutTest
## Player scripts on the normal path (LuaBulletBehavior, sandbox, manager step)
## keep working across Lua collector cycles, and bad input raises an ordinary
## Lua error that commits nothing.

const DT := 1.0 / 60.0

var manager: BulletManager
var _open: Array[LuaBulletBehavior] = []


func before_each() -> void:
	ScriptWarnings.reset()
	_new_manager()


func _new_manager() -> void:
	manager = BulletManager.new()
	manager.capacity = 64
	manager.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func after_each() -> void:
	manager._behaviors.clear()
	_open.clear()


func _behavior(code: String) -> LuaBulletBehavior:
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source(code, "weapon.lua", manager, -1)
	assert_true(loaded.ok, loaded.error)
	return behavior


func _arm(behavior: LuaBulletBehavior, velocity: Vector2, lifetime: float = 50.0) -> int:
	var id := manager.register_behavior(behavior)
	var request := ShotRequest.with_velocity(Vector2.ZERO, velocity)
	request.lifetime = lifetime
	behavior.apply_to_request(request, id)
	var spawned := manager.spawn(request)
	assert_gte(spawned, 0)
	return spawned


func _steps(n: int) -> void:
	for i in n:
		manager.step(DT)


func test_on_batch_survives_a_full_collect_every_tick() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				collectgarbage("collect")
				collectgarbage("collect")
				v.vx[0] = v.vx[0] + 1
			end,
		}
	""".dedent())
	_arm(behavior, Vector2(10.0, 0.0))
	for i in 30:
		manager.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(behavior.dispatches("on_batch"), 30)


func test_on_batch_survives_incremental_collect_steps() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				for i = 1, 50 do collectgarbage("step") end
			end,
		}
	""".dedent())
	_arm(behavior, Vector2(10.0, 0.0))
	for i in 30:
		manager.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)


func test_allocation_churn_without_explicit_collect() -> void:
	var behavior := _behavior("""
		local keep = {}
		return {
			on_batch = function(v, dt)
				for i = 1, 400 do
					keep[i % 16] = { tostring(i) .. "x", { i } }
				end
			end,
		}
	""".dedent())
	_arm(behavior, Vector2(10.0, 0.0))
	for i in 60:
		manager.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)


func test_event_hooks_survive_a_collect_between_calls() -> void:
	var behavior := _behavior("""
		return {
			on_spawn = function(b)
				collectgarbage("collect")
				b:set_velocity(7, 0)
			end,
			on_death = function(b, reason)
				collectgarbage("collect")
			end,
		}
	""".dedent())
	for i in 20:
		var slot := _arm(behavior, Vector2(1.0, 0.0), 0.05)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
		assert_eq(manager.pool.vel[slot], Vector2(7.0, 0.0))
		_steps(5)
	assert_eq(behavior.dispatches("on_spawn"), 20)


func test_bad_rows_after_a_collect_raise_lua_errors() -> void:
	var cases := {
		"v.vx[99] = 1": "row must be an integer",
		"v.vx[-1] = 1": "row must be an integer",
		"v.vx[0.5] = 1": "row must be an integer",
		"v.vx[0/0] = 1": "row must be an integer",
		"local _ = v.px[1e300]": "row must be an integer",
		"v.id[0] = 1": "read-only",
		"v:kill(-5)": "row must be an integer",
		"v:kill('x')": "row must be an integer",
		"v:kill({})": "row must be an integer",
		"v:kill(nil)": "row must be an integer",
		"v:teleport('x', 0, 0)": "row must be an integer",
		"v:teleport(0, 'a', 0)": "expected (row, x, y)",
		"v:spawn_child(-1, 0, 0, 1, 0, 1)": "row must be an integer",
		"v:spawn_child(0, 0, 0, 1, 0, 'x')": "expected (row, x, y, vx, vy, lifetime)",
		"v.n = 3": "read-only",
		"v.kill(nil, 'x')": "row must be an integer",
	}
	for body: String in cases:
		var code := "return { on_batch = function(v, dt) collectgarbage('collect') %s end }" % body
		var behavior := _behavior(code)
		_arm(behavior, Vector2(5.0, 0.0))
		for i in 3:
			manager.step(DT)
			assert_false(behavior.last_result.ok, body)
			var expected: String = cases[body]
			assert_true(expected in behavior.last_result.error, "%s -> %s" % [body, behavior.last_result.error])
		manager._behaviors.clear()
		_new_manager()


func test_errors_inside_pcall_and_coroutines_after_a_collect() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				local ok, err = pcall(function() v:kill("x") end)
				assert(not ok and string.find(err, "row must be an integer", 1, true), err)
				local co = coroutine.create(function() collectgarbage("collect"); v.vx[42] = 0 end)
				local ok2, err2 = coroutine.resume(co)
				assert(not ok2 and string.find(err2, "row must be an integer", 1, true), err2)
				local w = coroutine.wrap(function() coroutine.yield(1); return 2 end)
				w(); w()
				collectgarbage("collect")
				v.vx[0] = 3
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(5.0, 0.0))
	for i in 20:
		manager.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot].x, 3.0)


func test_reload_after_a_collect_keeps_the_new_callbacks() -> void:
	var behavior := _behavior("return { on_batch = function(v, dt) collectgarbage('collect'); v.vx[0] = 1 end }")
	var slot := _arm(behavior, Vector2(5.0, 0.0))
	_steps(3)
	var reloaded := behavior.load_source(
		"return { on_batch = function(v, dt) collectgarbage('collect'); v.vx[0] = 2 end }", "weapon.lua"
	)
	assert_true(reloaded.ok, reloaded.error)
	for i in 10:
		manager.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot].x, 2.0)


func test_non_number_column_writes_raise_a_lua_error() -> void:
	for value: String in ["'abc'", "'12'", "{}", "nil", "true", "print", "coroutine.create(print)", "v", "v.vx"]:
		var code := "return { on_batch = function(v, dt) collectgarbage('collect'); v.vx[0] = %s end }" % value
		var behavior := _behavior(code)
		var slot := _arm(behavior, Vector2(5.0, 0.0))
		for i in 2:
			manager.step(DT)
			assert_false(behavior.last_result.ok, value)
			assert_true(
				"weapon.lua:1: column 'vx': value must be a number" in behavior.last_result.error,
				"%s -> %s" % [value, behavior.last_result.error]
			)
		assert_eq(manager.pool.vel[slot], Vector2(5.0, 0.0), "nothing committed for %s" % value)
		manager._behaviors.clear()
		_new_manager()
