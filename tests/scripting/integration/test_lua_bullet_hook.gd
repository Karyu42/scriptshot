extends GutTest
## One real bullet path: LuaBulletBehavior, the PR #15 mask, BulletPool.set_velocity,
## ShotEmitter.request_child_shot_id. Declarative scripts stay plain bullets.

const DT := 1.0 / 60.0

var manager: BulletManager
var _open: Array[LuaBulletBehavior] = []


func before_each() -> void:
	ScriptWarnings.reset()
	manager = BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 64
	manager.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func after_each() -> void:
	# Drop the behaviour before the manager node is freed. The Lua state stays
	# pinned until ScriptHost.shutdown(); freeing it from this node's destructor
	# is what aborts on the way out.
	manager._behaviors.clear()
	_open.clear()


func _behavior(code: String) -> LuaBulletBehavior:
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source(code, "weapon.lua")
	assert_true(loaded.ok, loaded.error)
	assert_true(behavior.hook_mask_exact)
	assert_eq(behavior.hook_mask, BulletBehavior.mask_from_names(behavior.host.defined_names()))
	return behavior


func _arm(behavior: LuaBulletBehavior, velocity: Vector2) -> ShotRequest:
	var id := manager.register_behavior(behavior)
	var request := ShotRequest.with_velocity(Vector2.ZERO, velocity)
	request.lifetime = 5.0
	behavior.apply_to_request(request, id)
	return request


func test_a_script_with_no_event_hook_stays_a_plain_bullet() -> void:
	var behavior := _behavior("return { name = 'plain', on_tick = function() end }")
	assert_eq(behavior.hook_mask, 0)
	assert_ne(behavior.hook_mask, BulletBehavior.HOOK_ALL)
	var request := _arm(behavior, Vector2(30, 0))
	assert_eq(request.behavior_id, 0, "no event callback: behavior_id stays 0")
	var slot := manager.spawn(request)
	assert_eq(slot, 0)
	assert_false(manager.pool.hook_ran)
	assert_eq(behavior.dispatches("on_spawn"), 0)
	assert_eq(manager.pool.vel[slot], Vector2(30, 0))
	assert_eq(manager.pool.behavior[slot], 0)


## behavior_id != 0 is listed every tick. on_update is intentionally unmasked, and
## this adapter does not override it, so the tick is the empty base method: no
## ScriptHost.call_hook, no G1 coroutine. Masking that call is an engine change.
func test_an_event_only_bullet_is_listed_every_tick_without_entering_lua() -> void:
	var behavior := _behavior("return { on_hit = function(b, hit) end }")
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_ON_HIT)
	assert_false(behavior.host.has_callback("on_update"))
	var request := _arm(behavior, Vector2(40, 0))
	assert_gt(request.behavior_id, 0)
	var slot := manager.spawn(request)
	assert_eq(manager.pool.behavior[slot], request.behavior_id)
	assert_eq(behavior.dispatches("on_spawn"), 0, "on_spawn is outside the mask")
	manager.step(DT)
	assert_eq(manager.pool.hooked_count, 1, "behavior_id != 0 stays on the per-tick list")
	assert_eq(behavior.dispatches("on_hit"), 0, "the tick does not enter Lua")
	assert_eq(behavior.dispatches("on_spawn"), 0)
	assert_eq(behavior.dispatches("on_despawn"), 0)
	assert_eq(behavior.dispatches("can_hit"), 0)
	var listings := 0
	var script: Script = behavior.get_script()
	for d: Dictionary in script.get_script_method_list():
		if str(d["name"]) == "on_update":
			listings += 1
	assert_eq(listings, 1, "on_update is the inherited empty method, not an override")


func test_on_spawn_commits_velocity_through_the_pool() -> void:
	var behavior := _behavior("""
		return {
			on_spawn = function(b)
				b:set_velocity(100, -20)
			end,
		}
	""".dedent())
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_ON_SPAWN)
	assert_ne(behavior.hook_mask, BulletBehavior.HOOK_ALL)
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_true(manager.pool.hook_ran)
	assert_eq(behavior.dispatches("on_spawn"), 1)
	assert_eq(manager.pool.vel[slot], Vector2(100, -20))
	assert_eq(manager.pool.dead_reason[slot], 0)


func test_a_velocity_over_the_ceiling_is_clamped_by_set_velocity() -> void:
	var behavior := _behavior("return { on_spawn = function(b) b:set_velocity(10000, 0) end }")
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(manager.pool.vel[slot], Vector2(BulletLimits.MAX_SPEED, 0))
	assert_eq(manager.pool.dead_reason[slot], 0)


func test_a_non_finite_velocity_kills_the_bullet_as_invalid() -> void:
	var behavior := _behavior("return { on_spawn = function(b) b:set_velocity(0/0, 0) end }")
	var before := manager.pool.invalid_total
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(manager.pool.dead_reason[slot], BulletPool.DespawnReason.INVALID + 1)
	assert_gt(manager.pool.invalid_total, before)
	assert_false(manager.pool.is_alive(manager.pool.id_of(slot)))
	assert_true(manager.pool.vel[slot].is_finite(), "a NaN velocity is not left in the slot")


func test_a_script_error_commits_nothing_and_the_bullet_stays() -> void:
	var behavior := _behavior("""
		return {
			on_spawn = function(b)
				b:set_velocity(50, 0)
				error('nope')
			end,
		}
	""".dedent())
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(manager.pool.vel[slot], Vector2(10, 0))
	assert_eq(manager.pool.dead_reason[slot], 0)
	assert_false(behavior.last_result.ok)
	assert_true("nope" in behavior.last_result.error, behavior.last_result.error)
	assert_eq(manager.pool.count, 1)


func test_spawn_child_goes_through_the_emitter_and_stays_declarative() -> void:
	var behavior := _behavior("""
		return {
			on_spawn = function(b)
				b:spawn_child(b.x + 10, b.y, 25, 0, 2)
			end,
		}
	""".dedent())
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(manager.pool.count, 2)
	assert_eq(manager.pool.pos[1], Vector2(10, 0))
	assert_eq(manager.pool.vel[1], Vector2(25, 0))
	assert_eq(manager.pool.behavior[1], 0, "the child is a plain bullet")
	assert_eq(manager.pool.owner_layer[slot], Layers.PLAYER)
	assert_eq(manager.pool.owner_layer[1], Layers.PLAYER)
	assert_almost_eq(manager.pool.lifetime[1], 2.0, 0.001)


func test_a_non_finite_child_is_rejected_and_the_parent_stays() -> void:
	var behavior := _behavior("return { on_spawn = function(b) b:spawn_child(0, 0, 0/0, 1, 1) end }")
	var before := manager.pool.invalid_total
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(manager.pool.count, 1)
	assert_eq(manager.pool.dead_reason[slot], 0)
	assert_gt(manager.pool.invalid_total, before)


func test_on_spawn_only_does_not_receive_on_despawn() -> void:
	var behavior := _behavior("return { on_spawn = function(b) b:set_velocity(3, 0) end }")
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(behavior.dispatches("on_spawn"), 1)
	manager.pool.mark_dead(slot, BulletPool.DespawnReason.MANUAL)
	manager.step(DT)
	assert_eq(behavior.dispatches("on_despawn"), 0)
	assert_eq(behavior.dispatches("on_hit"), 0)


func test_on_death_receives_the_despawn_reason() -> void:
	var behavior := _behavior("""
		return {
			on_death = function(b, why)
				print(why)
			end,
		}
	""".dedent())
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_ON_DESPAWN)
	var slot := manager.spawn(_arm(behavior, Vector2(10, 0)))
	assert_eq(behavior.dispatches("on_spawn"), 0)
	assert_false(manager.pool.hook_ran, "on_death is not an on_spawn")
	manager.pool.mark_dead(slot, BulletPool.DespawnReason.MANUAL)
	manager.step(DT)
	assert_eq(behavior.dispatches("on_despawn"), 1)
	assert_eq(behavior.last_result.output.size(), 1)
	assert_eq(behavior.last_result.output[0], "manual")


func test_can_hit_false_vetoes_before_damage() -> void:
	var behavior := _behavior("return { can_hit = function(b, hit) return false end }")
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_CAN_HIT)
	var request := _arm(behavior, Vector2(BulletLimits.MAX_SPEED, 0))
	assert_true(request.can_hit_veto)
	var hurtbox := Hurtbox.new()
	hurtbox.radius = 30.0
	hurtbox.position = Vector2(20, 0)
	add_child_autofree(hurtbox)
	watch_signals(hurtbox)
	manager.spawn(request)
	manager.step(DT)
	assert_eq(behavior.dispatches("can_hit"), 1)
	assert_eq(behavior.dispatches("on_hit"), 0)
	assert_signal_not_emitted(hurtbox, "hit")
	assert_eq(manager.pool.count, 1)


func test_on_hit_runs_after_the_hurtbox_is_told() -> void:
	var behavior := _behavior("""
		return {
			on_hit = function(b, hit)
				print(hit.damage)
			end,
		}
	""".dedent())
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_ON_HIT)
	var request := _arm(behavior, Vector2(BulletLimits.MAX_SPEED, 0))
	request.damage = 3.0
	var hurtbox := Hurtbox.new()
	hurtbox.radius = 30.0
	hurtbox.position = Vector2(20, 0)
	add_child_autofree(hurtbox)
	watch_signals(hurtbox)
	manager.spawn(request)
	manager.step(DT)
	assert_signal_emit_count(hurtbox, "hit", 1)
	assert_eq(behavior.dispatches("on_hit"), 1)
	assert_eq(behavior.dispatches("can_hit"), 0)
	assert_true(str(behavior.last_result.output[0]).contains("3"), str(behavior.last_result.output))


func test_reloading_a_callback_updates_the_mask() -> void:
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	var first := behavior.load_source("return { name = 'plain' }", "weapon.lua")
	assert_true(first.ok, first.error)
	assert_eq(behavior.hook_mask, 0)
	var id := manager.register_behavior(behavior)
	var second := behavior.load_source(
		"return { on_spawn = function(b) b:set_velocity(8, 0) end }",
		"weapon.lua",
		manager,
		id
	)
	assert_true(second.ok, second.error)
	assert_eq(behavior.hook_mask, BulletBehavior.HOOK_ON_SPAWN)
	var request := ShotRequest.with_velocity(Vector2.ZERO, Vector2(1, 0))
	request.lifetime = 5.0
	behavior.apply_to_request(request, id)
	var slot := manager.spawn(request)
	assert_eq(manager.pool.vel[slot], Vector2(8, 0))
	assert_true(manager.pool.hook_ran)
