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
