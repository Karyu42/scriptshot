extends GutTest
## release_behavior() on a real LuaBulletBehavior: the manager stops holding the
## generation, its bullets fly on plain, and a fresh generation gets a new owner
## id (the hot-reload flow SE builds on, #76).

const DT := 1.0 / 60.0

var manager: BulletManager


func before_each() -> void:
	ScriptWarnings.reset()
	manager = BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 64
	manager.world_bounds = Rect2(-4000, -4000, 8000, 8000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func after_each() -> void:
	# Same as test_lua_bullet_hook.gd: drop behaviours before the node is freed.
	manager._behaviors.clear()


func _generation(code: String) -> LuaBulletBehavior:
	var b := LuaBulletBehavior.new()
	b.host.wall_msec = 5000
	var loaded := b.load_source(code, "weapon.lua")
	assert_true(loaded.ok, loaded.error)
	return b


func _fire(b: LuaBulletBehavior, owner_id: int) -> int:
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(50, 0))
	r.lifetime = 5.0
	b.apply_to_request(r, owner_id)
	assert_eq(r.behavior_id, owner_id)
	var slot := manager.spawn(r)
	assert_gte(slot, 0)
	return manager.pool.id_of(slot)


func test_release_frees_the_lua_generation_and_keeps_its_bullets_flying() -> void:
	var code := "return { on_hit = function(b, hit) end, on_despawn = function(b, why) end }"
	var old_gen := _generation(code)
	var old_ref: WeakRef = weakref(old_gen)
	var old_id := manager.register_behavior(old_gen)
	var bullet := _fire(old_gen, old_id)
	old_gen = null
	assert_true(old_ref.get_ref() != null, "the manager holds the live generation")
	var drained: Array[int] = []
	manager.hooked_owner_drained.connect(func(id: int) -> void: drained.append(id))

	# Hot reload: a new generation, a new owner id.
	var new_gen := _generation(code)
	var new_id := manager.register_behavior(new_gen)
	assert_ne(new_id, old_id)
	_fire(new_gen, new_id)

	assert_eq(manager.release_behavior(old_id), 1)
	assert_true(old_ref.get_ref() == null, "the old LuaBulletBehavior is freed")
	assert_eq(drained, [old_id] as Array[int])
	var slot := manager.pool.slot_of(bullet)
	assert_gte(slot, 0, "the old bullet is still alive")
	assert_eq(manager.pool.behavior[slot], 0, "and plain")
	assert_eq(manager.pool.vel[slot], Vector2(50, 0))
	assert_eq(manager.hooked_count_for_owner(new_id), 1, "the new generation is untouched")
	manager.step(DT)
	assert_eq(manager.pool.vel[manager.pool.slot_of(bullet)], Vector2(50, 0))
	assert_eq(new_gen.dispatches("on_despawn"), 0)
