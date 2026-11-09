extends GutTest
## Lua on_batch over the packed-copy view. A script error commits nothing.
## on_tick is still not a per-bullet hook.

const DT := 1.0 / 60.0

var manager: BulletManager
var _open: Array[LuaBulletBehavior] = []


func before_each() -> void:
	ScriptWarnings.reset()
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


func _arm(behavior: LuaBulletBehavior, velocity: Vector2) -> int:
	var id := manager.register_behavior(behavior)
	var request := ShotRequest.with_velocity(Vector2.ZERO, velocity)
	request.lifetime = 5.0
	behavior.apply_to_request(request, id)
	var spawned := manager.spawn(request)
	assert_gte(spawned, 0)
	return spawned


func test_on_batch_steers_without_a_per_bullet_hook() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				local vx = v.vx
				for i = 0, v.n - 1 do
					vx[i] = vx[i] + 10
				end
			end,
		}
	""".dedent())
	assert_eq(behavior.hook_mask, 0)
	assert_eq(behavior.update_mode, BulletBehavior.UpdateMode.BATCH)
	var spawned := _arm(behavior, Vector2(30.0, 0.0))
	assert_eq(behavior.hook_mask, 0)
	manager.step(DT)
	assert_eq(behavior.dispatches("on_batch"), 1)
	assert_eq(manager.pool.hooked_count, 0)
	assert_eq(manager.pool.vel[spawned], Vector2(40.0, 0.0))
	assert_almost_eq(manager.pool.pos[spawned].x, 0.5, 0.001)
	assert_eq(manager.pool.owner_layer[spawned], Layers.PLAYER)


func test_a_script_error_commits_nothing() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				v.vx[0] = 80
				error("batch broke")
			end,
		}
	""".dedent())
	var spawned := _arm(behavior, Vector2(30.0, 0.0))
	manager.step(DT)
	assert_false(behavior.last_result.ok)
	assert_true("batch broke" in behavior.last_result.error, behavior.last_result.error)
	assert_eq(manager.pool.vel[spawned], Vector2(30.0, 0.0))
	assert_eq(manager.pool.dead_reason[spawned], 0)
	assert_eq(manager.pool.count, 1)
	manager.step(DT)
	assert_eq(behavior.dispatches("on_batch"), 2, "the next tick still runs")


func test_empty_batch_does_not_enter_lua() -> void:
	var behavior := _behavior("return { on_batch = function(v, dt) print(v.n) end }")
	manager.register_behavior(behavior)
	manager.step(DT)
	assert_eq(behavior.dispatches("on_batch"), 0)
	assert_eq(manager.alive_count(), 0)


func test_kill_and_spawn_child_from_lua() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				v:kill(0)
				v:spawn_child(0, v.px[0] + 4, v.py[0], 12, 0, 2)
			end,
		}
	""".dedent())
	_arm(behavior, Vector2(60.0, 0.0))
	manager.step(DT)
	assert_eq(manager.alive_count(), 1, "the parent was killed and the child remains")
	var child_slot := -1
	for i in manager.pool.count:
		if manager.pool.dead_reason[i] == 0:
			child_slot = i
	assert_ne(child_slot, -1)
	assert_eq(manager.pool.vel[child_slot], Vector2(12.0, 0.0))
	assert_eq(manager.pool.owner_layer[child_slot], Layers.PLAYER)
	assert_eq(manager.pool.behavior[child_slot], 0)
	assert_almost_eq(manager.pool.lifetime[child_slot], 2.0, 0.001)
	assert_false(manager.is_native_id(child_slot))


func test_on_tick_is_still_not_a_batch_or_a_per_bullet_hook() -> void:
	var behavior := _behavior("return { on_tick = function() end }")
	assert_eq(behavior.update_mode, BulletBehavior.UpdateMode.PER_BULLET)
	assert_eq(behavior.hook_mask, 0)
	var id := manager.register_behavior(behavior)
	var request := ShotRequest.with_velocity(Vector2.ZERO, Vector2(10.0, 0.0))
	behavior.apply_to_request(request, id)
	assert_eq(request.behavior_id, 0)
	var slot := manager.spawn(request)
	manager.step(DT)
	assert_eq(manager.pool.behavior[slot], 0)
	assert_eq(behavior.dispatches("on_batch"), 0)


func test_on_batch_beside_on_hit_stays_on_the_pool() -> void:
	var behavior := _behavior("""
		return {
			on_hit = function(b, hit) end,
			on_batch = function(v, dt)
				v.vx[0] = 15
			end,
		}
	""".dedent())
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_ON_HIT)
	assert_eq(behavior.update_mode, BulletBehavior.UpdateMode.BATCH)
	var spawned := _arm(behavior, Vector2(20.0, 0.0))
	assert_false(manager.is_native_id(spawned))
	manager.step(DT)
	assert_eq(manager.pool.vel[spawned], Vector2(15.0, 0.0))
	assert_eq(manager.pool.hooked_count, 1, "the event hook still lists the bullet")
	assert_eq(behavior.dispatches("on_batch"), 1)


func _expect_error(code: String) -> String:
	var behavior := _behavior(code)
	_arm(behavior, Vector2(30.0, 0.0))
	manager.step(DT)
	assert_false(behavior.last_result.ok, "the callback should fail")
	return behavior.last_result.error


func test_batch_columns_are_opaque_proxies() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				assert(type(v.vx) == "table")
				local mt = getmetatable(v.vx)
				if mt ~= false and mt ~= nil then
					error("metatable reachable")
				end
				if v.vx.resize ~= nil or v.pa.duplicate ~= nil then
					error("userdata method reachable")
				end
				v.vx[0] = v.vx[0] + 1
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(30.0, 0.0))
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot].x, 31.0)


func test_protected_view_rejects_rawset_and_setmetatable() -> void:
	var err := _expect_error("""
		return {
			on_batch = function(v, dt)
				rawset(v, "n", 0)
			end,
		}
	""".dedent())
	assert_true("cannot modify" in err or "protected" in err, err)
	err = _expect_error("""
		return {
			on_batch = function(v, dt)
				setmetatable(v, {})
			end,
		}
	""".dedent())
	assert_true("protected" in err or "metatable" in err, err)


func test_gc_finalizer_is_refused_and_does_not_hang() -> void:
	var err := _expect_error("""
		return {
			on_batch = function(v, dt)
				setmetatable({}, { __gc = function() while true do end end })
				collectgarbage("collect")
			end,
		}
	""".dedent())
	assert_true("__gc" in err, err)


func test_column_userdata_methods_are_unreachable() -> void:
	var err := _expect_error("""
		return {
			on_batch = function(v, dt)
				v.pa:resize(100)
			end,
		}
	""".dedent())
	assert_true("row must be an integer" in err or "nil" in err or "attempt to call" in err, err)


func test_readonly_columns_raise_and_do_not_redirect() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				local ok, err = pcall(function() v.id[0] = 1 end)
				if ok then error("id write was accepted") end
				ok, err = pcall(function() v.owner[0] = 2 end)
				if ok then error("owner write was accepted") end
				ok, err = pcall(function() v.px[0] = 9 end)
				if ok then error("px write was accepted") end
				ok, err = pcall(function() v.age[0] = 9 end)
				if ok then error("age write was accepted") end
				v.vx[0] = 44
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(10.0, 0.0))
	var other := manager.spawn(ShotRequest.with_velocity(Vector2(50, 50), Vector2(1, 0)))
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot], Vector2(44.0, 0.0))
	assert_eq(manager.pool.vel[other], Vector2(1.0, 0.0))
	assert_eq(manager.pool.owner_layer[slot], Layers.PLAYER)


func test_stale_view_raises_view_expired() -> void:
	var behavior := _behavior("""
		local saved
		return {
			on_batch = function(v, dt)
				if saved == nil then
					saved = v
					v.vx[0] = 12
				else
					local ok, err = pcall(function() return saved.vx[0] end)
					if ok then error("stale column was readable") end
					print(tostring(err))
					ok, err = pcall(function() saved:kill(0) end)
					if ok then error("stale command was accepted") end
					print(tostring(err))
				end
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(5.0, 0.0))
	manager.step(DT)
	assert_eq(manager.pool.vel[slot].x, 12.0)
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	var joined := " ".join(behavior.last_result.output)
	assert_true("view expired" in joined, joined)
	assert_eq(manager.alive_count(), 1, "the stale kill did not land")


func test_bad_rows_raise_for_columns_and_commands() -> void:
	var err := _expect_error("""
		return {
			on_batch = function(v, dt)
				v.vx[99] = 1
			end,
		}
	""".dedent())
	assert_true("row must be an integer" in err, err)
	err = _expect_error("return { on_batch = function(v, dt) v.vx[-1] = 1 end }")
	assert_true("row must be an integer" in err, err)
	err = _expect_error("return { on_batch = function(v, dt) v.vx[0.5] = 1 end }")
	assert_true("row must be an integer" in err, err)
	err = _expect_error("return { on_batch = function(v, dt) v.vx[0/0] = 1 end }")
	assert_true("row must be an integer" in err, err)
	err = _expect_error("return { on_batch = function(v, dt) v:kill(-5) end }")
	assert_true("row must be an integer" in err, err)
	err = _expect_error("return { on_batch = function(v, dt) v:spawn_child(-1, 0, 0, 1, 0, 1) end }")
	assert_true("row must be an integer" in err, err)
	err = _expect_error("return { on_batch = function(v, dt) v:kill('x') end }")
	assert_true("row must be an integer" in err, err)


func test_non_finite_lua_write_kills_as_invalid() -> void:
	var behavior := _behavior("""
		return { on_batch = function(v, dt) v.vx[0] = 0/0 end }
	""")
	var before := manager.pool.invalid_total
	_arm(behavior, Vector2(10.0, 0.0))
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_gt(manager.pool.invalid_total, before)
	assert_eq(manager.alive_count(), 0)
	behavior = _behavior("""
		return { on_batch = function(v, dt) v.pa[0] = 0/0 end }
	""")
	before = manager.pool.invalid_total
	_arm(behavior, Vector2(10.0, 0.0))
	manager.step(DT)
	assert_gt(manager.pool.invalid_total, before)
	assert_eq(manager.alive_count(), 0)


func test_spawn_cap_keeps_the_first_calls_and_stays_fast() -> void:
	var big := BulletManager.new()
	big.capacity = 20000
	big.logical_cap = 20000
	big.enemy_reserve = 0
	big.world_bounds = Rect2(-20000, -20000, 40000, 40000)
	big.render_enabled = false
	big.auto_step = false
	add_child_autofree(big)
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source("""
		return {
			on_batch = function(v, dt)
				local spawn = v.spawn_child
				for i = 1, 5000 do
					spawn(v, 0, 0, 0, 1, 0, 1)
				end
			end,
		}
	""".dedent(), "weapon.lua")
	assert_true(loaded.ok, loaded.error)
	var id := big.register_behavior(behavior)
	# One row's budget is the 100_000 base. 5000 host calls need the per-row
	# allowance, so the batch is wide enough for that allowance to cover them.
	var parents := 8000
	for i in parents:
		var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(1, 0))
		req.lifetime = 5.0
		behavior.apply_to_request(req, id)
		assert_gte(big.spawn(req), 0)
	big.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(big.alive_count(), parents + BatchView.SPAWN_CAP)
	# The step also integrates every parent, so its wall time is not the cost of
	# the calls. The host-side timing is test_over_cap_calls_keep_the_first_and_stay_fast.


func test_steering_loops_stay_inside_the_batch_budget() -> void:
	var counts: Array[int] = [5000, 10000]
	for count in counts:
		var big := BulletManager.new()
		big.capacity = count + 10
		big.logical_cap = count + 10
		big.enemy_reserve = 0
		big.world_bounds = Rect2(-200000, -200000, 400000, 400000)
		big.render_enabled = false
		big.auto_step = false
		add_child_autofree(big)
		var behavior := LuaBulletBehavior.new()
		_open.append(behavior)
		behavior.host.wall_msec = 50
		var loaded := behavior.load_source("""
			return {
				on_batch = function(v, dt)
					local vx, age = v.vx, v.age
					for i = 0, v.n - 1 do
						vx[i] = vx[i] + math.cos(age[i] * 6) * 40 * dt
					end
				end,
			}
		""".dedent(), "weapon.lua")
		assert_true(loaded.ok, loaded.error)
		var id := big.register_behavior(behavior)
		for i in count:
			var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(30, 0))
			req.lifetime = 5.0
			behavior.apply_to_request(req, id)
			assert_gte(big.spawn(req), 0)
		big.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
		assert_eq(big.alive_count(), count)
		assert_gt(big.pool.vel[0].x, 30.0)


func test_runaway_batch_is_stopped_and_commits_nothing() -> void:
	var behavior := _behavior("""
		return { on_batch = function(v, dt) while true do end end }
	""")
	var slot := _arm(behavior, Vector2(9.0, 0.0))
	manager.step(DT)
	assert_false(behavior.last_result.ok)
	assert_true("timeout" in behavior.last_result.error, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot], Vector2(9.0, 0.0))


func test_child_owner_follows_the_parent_after_reflect() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				v:spawn_child(0, v.px[0], v.py[0], 4, 0, 1)
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(10.0, 0.0))
	assert_true(manager.reflect(
		manager.pool.id_of(slot), Layers.ENEMY, false, BulletPool.REFLECTED_DAMAGE, true
	))
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	var child := -1
	for i in manager.pool.count:
		if manager.pool.vel[i] == Vector2(4.0, 0.0):
			child = i
	assert_ne(child, -1)
	assert_eq(manager.pool.owner_layer[child], Layers.ENEMY)
	assert_eq(manager.pool.owner_layer[slot], Layers.ENEMY)


func test_os_stays_unavailable_without_an_opt_in() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				local ex = os and os.execute
				local ge = os and os.getenv
				print(type(os.execute), type(ex), type(ge))
				local mt = getmetatable(v.vx)
				if type(mt) == "table" then
					error("metatable reachable")
				end
			end,
		}
	""".dedent())
	_arm(behavior, Vector2(3.0, 0.0))
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	var line := " ".join(behavior.last_result.output)
	assert_true("nil" in line, line)
	assert_false("function" in line, line)


func test_a_failed_tamper_does_not_disable_the_watchdog() -> void:
	var behavior := _behavior("""
		local n = 0
		return {
			on_batch = function(v, dt)
				n = n + 1
				if n == 1 then
					local mt = getmetatable(v.vx)
					if type(mt) == "table" then
						error("metatable reachable")
					end
					error("tamper failed closed")
				end
				while true do end
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(8.0, 0.0))
	manager.step(DT)
	assert_false(behavior.last_result.ok)
	manager.step(DT)
	assert_false(behavior.last_result.ok)
	assert_true("timeout" in behavior.last_result.error, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot], Vector2(8.0, 0.0))


func test_hot_reload_on_batch_does_not_adopt_plain_bullets() -> void:
	var behavior := _behavior("return { name = 'plain' }")
	var id := manager.register_behavior(behavior)
	var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(15.0, 0.0))
	req.lifetime = 5.0
	behavior.apply_to_request(req, id)
	assert_eq(req.behavior_id, 0)
	var slot := manager.spawn(req)
	var loaded := behavior.load_source("""
		return { on_batch = function(v, dt) v.vx[0] = 99 end }
	""".dedent(), "weapon.lua", manager, id)
	assert_true(loaded.ok, loaded.error)
	manager.step(DT)
	assert_eq(manager.pool.behavior[slot], 0)
	assert_eq(manager.pool.vel[slot].x, 15.0)
	var again := ShotRequest.with_velocity(Vector2.ZERO, Vector2(15.0, 0.0))
	again.lifetime = 5.0
	behavior.apply_to_request(again, id)
	assert_gt(again.behavior_id, 0)
	var newbie := manager.spawn(again)
	manager.step(DT)
	assert_eq(manager.pool.vel[newbie], Vector2(99.0, 0.0))
	assert_eq(manager.pool.vel[slot].x, 15.0)


func _budget_script(call: String, times: int) -> String:
	return """
		local n = 0
		return {
			on_batch = function(v, dt)
				n = n + 1
				if n == 1 then
					for k = 1, %d do
						%s
					end
				else
					v.vx[0] = 44
				end
			end,
		}
	""" % [times, call]


func _run_budget_case(call: String, times: int) -> void:
	for trial in 3:
		var behavior := _behavior(_budget_script(call, times))
		var slot := _arm(behavior, Vector2(30.0, 0.0))
		var extra := ShotRequest.with_velocity(Vector2(4, 4), Vector2(30.0, 0.0))
		extra.lifetime = 5.0
		var other := manager.spawn(extra)
		var before := manager.alive_count()
		var origin := manager.pool.pos[slot]
		manager.step(DT)
		assert_false(behavior.last_result.ok)
		assert_eq(behavior.last_result.stopped, "instruction budget")
		assert_true("script timeout (instruction budget)" in behavior.last_result.error, behavior.last_result.error)
		assert_eq(manager.pool.vel[slot], Vector2(30.0, 0.0))
		assert_eq(manager.alive_count(), before)
		assert_lt(manager.pool.pos[slot].distance_to(origin + Vector2(30.0, 0.0) * DT), 0.25)
		manager.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
		assert_eq(manager.pool.vel[slot], Vector2(44.0, 0.0))
		assert_eq(manager.pool.vel[other], Vector2(30.0, 0.0))
		manager.queue_free()
		manager = BulletManager.new()
		manager.capacity = 64
		manager.world_bounds = Rect2(-2000, -2000, 4000, 4000)
		manager.render_enabled = false
		manager.auto_step = false
		add_child_autofree(manager)


func test_kill_budget_loop_stops_cleanly() -> void:
	_run_budget_case("v:kill(0)", 6000)
	_run_budget_case("pcall(function() v:kill(0) end)", 6000)


func test_spawn_budget_loop_stops_cleanly() -> void:
	_run_budget_case("v:spawn_child(0, 0, 0, 1, 0, 1)", 6000)
	_run_budget_case("pcall(function() v:spawn_child(0, 0, 0, 1, 0, 1) end)", 6000)


func test_teleport_budget_loop_stops_cleanly() -> void:
	_run_budget_case("v:teleport(0, 9, 9)", 5000)
	_run_budget_case("pcall(function() v:teleport(0, 9, 9) end)", 5000)


func test_batch_timeout_is_reported_and_rate_limited() -> void:
	var behavior := _behavior("return { on_batch = function(v, dt) while true do end end }")
	var slot := _arm(behavior, Vector2(9.0, 0.0))
	for _i in 6:
		manager.step(DT)
		assert_false(behavior.last_result.ok)
		assert_eq(behavior.last_result.stopped, "instruction budget")
		assert_true("script timeout (instruction budget)" in behavior.last_result.error)
	var key := "LuaBulletBehavior.error.on_batch"
	var message := ScriptWarnings.last_message(key)
	assert_true("script timeout (instruction budget)" in message, message)
	assert_eq(ScriptWarnings.count(key), 6)
	assert_eq(ScriptWarnings.printed_count(key), ScriptWarnings.LIMIT)
	assert_eq(manager.pool.vel[slot], Vector2(9.0, 0.0))


func test_sqrt_homing_loop_stays_inside_the_batch_budget() -> void:
	var counts: Array[int] = [5000, 10000]
	for count in counts:
		var big := BulletManager.new()
		big.capacity = count + 8
		big.logical_cap = count + 8
		big.enemy_reserve = 0
		big.world_bounds = Rect2(-200000, -200000, 400000, 400000)
		big.render_enabled = false
		big.auto_step = false
		add_child_autofree(big)
		var behavior := LuaBulletBehavior.new()
		_open.append(behavior)
		behavior.host.wall_msec = 50
		var loaded := behavior.load_source("""
			return {
				on_batch = function(v, dt)
					local vx, vy, px, py = v.vx, v.vy, v.px, v.py
					for i = 0, v.n - 1 do
						local dx, dy = 100 - px[i], 100 - py[i]
						local d = math.sqrt(dx * dx + dy * dy)
						if d > 0 then
							vx[i] = dx / d * 200
							vy[i] = dy / d * 200
						end
					end
				end,
			}
		""".dedent(), "weapon.lua", big, -1)
		assert_true(loaded.ok, loaded.error)
		var id := big.register_behavior(behavior)
		for _i in count:
			var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(30, 0))
			req.lifetime = 5.0
			behavior.apply_to_request(req, id)
			assert_gte(big.spawn(req), 0)
		big.step(DT)
		assert_true(behavior.last_result.ok, behavior.last_result.error)
		var budget := ScriptHost.INSTRUCTION_BUDGET + count * ScriptHost.BATCH_ROW_BUDGET
		assert_lte(behavior.host.batch_instructions, budget)
		assert_gt(big.pool.vel[0].x, 100.0)
		assert_gt(big.pool.vel[0].y, 100.0)
		print("SQRT_HOMING count=%d instructions=%d budget=%d" % [count, behavior.host.batch_instructions, budget])


func test_a_forged_command_table_cannot_bypass_caps_or_validation() -> void:
	var behavior := _behavior("""
		return {
			on_batch = function(v, dt)
				local ok = pcall(function() rawset(v, "_batch_cmds", {}) end)
				if ok then error("command table was writable") end
				v.vx[0] = 15
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(8.0, 0.0))
	var id := manager.pool.behavior[slot]
	manager.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(manager.pool.vel[slot].x, 15.0)
	var host := behavior.host
	var view := manager.gather_batch(id, DT)
	host._batch = view
	var packed_v: Variant = host._host.get("_packed")
	assert_true(packed_v is LuaTable)
	var packed := host._as_table(packed_v)
	packed.set(1, BatchView.CMD_KILL + 99 * 8)
	var tally := host._state.create_table()
	tally.set("cmd", 0)
	tally.set("spawn", 0)
	tally.set("n", 1)
	host._host.set("_batch_tally", tally)
	var err := host._flush_lua_commands()
	assert_true("row" in err, err)
	view.discard = true
	manager.commit_batch(view)
	assert_eq(manager.pool.vel[slot].x, 15.0)
	for i in 300:
		packed.set(i + 1, BatchView.CMD_SPAWN)
		var base := i * 5
		host._cmd_nums[base] = 1.0
		host._cmd_nums[base + 1] = 2.0
		host._cmd_nums[base + 2] = 6.0
		host._cmd_nums[base + 3] = 0.0
		host._cmd_nums[base + 4] = 1.5
	var view2 := manager.gather_batch(id, DT)
	host._batch = view2
	tally.set("n", 300)
	host._host.set("_batch_tally", tally)
	assert_eq(host._flush_lua_commands(), "")
	assert_eq(view2.dropped_spawns, 300 - BatchView.SPAWN_CAP)
	manager.commit_batch(view2)
	assert_gt(manager.alive_count(), 1)
	var child_owner := Layers.PLAYER
	for i in manager.pool.count:
		if manager.pool.vel[i] == Vector2(6.0, 0.0):
			child_owner = manager.pool.owner_layer[i]
	assert_eq(child_owner, Layers.PLAYER)


func test_per_bullet_velocity_loop_stops_cleanly() -> void:
	var behavior := _behavior("""
		local n = 0
		return {
			on_spawn = function(b)
				n = n + 1
				if n == 1 then
					for k = 1, 20000 do
						pcall(function() b:set_velocity(1, 0) end)
					end
				else
					b:set_velocity(44, 0)
				end
			end,
		}
	""".dedent())
	var slot := _arm(behavior, Vector2(12.0, 0.0))
	assert_false(behavior.last_result.ok)
	assert_eq(behavior.last_result.stopped, "instruction budget")
	assert_eq(manager.pool.vel[slot], Vector2(12.0, 0.0))
	var again := ShotRequest.with_velocity(Vector2.ZERO, Vector2(12.0, 0.0))
	again.lifetime = 5.0
	behavior.apply_to_request(again, manager.pool.behavior[slot])
	var second := manager.spawn(again)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(manager.pool.vel[second], Vector2(44.0, 0.0))


func test_native_batch_commands_use_the_captured_bullet() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var big := BulletManager.new()
	big.backend_preference = "native"
	big.capacity = 64
	big.logical_cap = 64
	big.enemy_reserve = 0
	big.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	big.render_enabled = false
	big.auto_step = false
	add_child_autofree(big)
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source("""
		return {
			on_batch = function(v, dt)
				v.vx[1] = 70
				v:teleport(1, 12, -4)
				v:kill(0)
				v:spawn_child(1, 0, 0, 9, 0, 2)
			end,
		}
	""".dedent(), "weapon.lua", big, -1)
	assert_true(loaded.ok, loaded.error)
	var id := big.register_behavior(behavior)
	for _i in 2:
		var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(30, 0))
		req.lifetime = 5.0
		behavior.apply_to_request(req, id)
		assert_true(big.is_native_id(big.spawn(req)))
	big.step(DT)
	assert_true(behavior.last_result.ok, behavior.last_result.error)
	assert_eq(big.native.count(), 1)
	var view := big.gather_batch(id, DT)
	assert_eq(view.n, 1)
	assert_almost_eq(view.px[0], 12.0, 0.05)
	assert_almost_eq(view.py[0], -4.0, 0.05)
	assert_almost_eq(view.vx[0], 70.0, 0.05)
	assert_eq(big.pool.count, 1)
	assert_eq(big.pool.vel[0], Vector2(9.0, 0.0))
	assert_eq(big.pool.owner_layer[0], Layers.PLAYER)
	assert_eq(big.pool.behavior[0], 0)
