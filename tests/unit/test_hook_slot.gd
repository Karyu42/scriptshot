extends GutTest
## QA scratch: BulletPool.hook_slot leak / nesting / re-entrancy / sanitize.
const DT := 1.0 / 60.0
var manager: BulletManager

func before_each() -> void:
	ScriptWarnings.reset()
	manager = BulletManager.new()
	manager.capacity = 64
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)

func _req(owner_layer: int, v := Vector2(10, 0)) -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2(50, 50), v)
	r.lifetime = 5.0
	r.owner_layer = owner_layer
	r.hit_mask = Layers.hostile_to(owner_layer)
	return r

## Child C: on_spawn reflects itself to ENEMY and spawns a grandchild.
class SelfReflectSpawner:
	extends BulletBehavior
	var grand_id := -1
	func on_spawn(pool: BulletPool, index: int) -> void:
		pool.reflect(index, Layers.ENEMY, false, 1.0, true)
		var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r.lifetime = 5.0
		r.owner_layer = Layers.PLAYER
		grand_id = emitter.request_shot_id(r)

## Parent A: spawns child C (nested hook), then another child D.
class Parent:
	extends BulletBehavior
	var c_beh: int
	var c_id := -1
	var d_id := -1
	var done := false
	func on_update(_pool: BulletPool, _i: int, _d: float) -> void:
		if done:
			return
		done = true
		var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r.lifetime = 5.0
		r.owner_layer = Layers.PLAYER
		r.behavior_id = c_beh
		c_id = emitter.request_shot_id(r)
		var r2 := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r2.lifetime = 5.0
		r2.owner_layer = Layers.PLAYER
		d_id = emitter.request_shot_id(r2)

func test_h1_nested_self_reflect_in_on_spawn_does_not_leak_into_the_parents_hook() -> void:
	var c := SelfReflectSpawner.new()
	var p := Parent.new()
	p.c_beh = manager.register_behavior(c)
	var r := _req(Layers.PLAYER)
	r.behavior_id = manager.register_behavior(p)
	manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_eq(pool.owner_layer[pool.slot_of(p.c_id)], Layers.ENEMY, "C reflected itself")
	assert_eq(pool.owner_layer[pool.slot_of(c.grand_id)], Layers.ENEMY, "grandchild follows C's post-reflect owner")
	assert_eq(pool.owner_layer[pool.slot_of(p.d_id)], Layers.PLAYER, "A's later child is still A's (context restored)")
	assert_eq(pool.hook_owner, -1)
	assert_eq(pool.hook_slot, -1)
	assert_true(pool.counters_consistent())

## Two bullets: the first reflects itself in on_update; the second just spawns.
class First:
	extends BulletBehavior
	var done := false
	func on_update(pool: BulletPool, i: int, _d: float) -> void:
		if not done:
			done = true
			pool.reflect(i, Layers.ENEMY, false, 1.0, true)
class Second:
	extends BulletBehavior
	var kid := -1
	func on_update(_pool: BulletPool, _i: int, _d: float) -> void:
		if kid < 0:
			var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
			r.lifetime = 5.0
			r.owner_layer = Layers.ENEMY
			kid = emitter.request_shot_id(r)

func test_h2_self_reflect_does_not_leak_to_the_next_bullets_hook() -> void:
	var f := First.new()
	var s := Second.new()
	var rf := _req(Layers.PLAYER)
	rf.behavior_id = manager.register_behavior(f)
	manager.emitter.request_shot_id(rf)
	var rs := _req(Layers.PLAYER)
	rs.behavior_id = manager.register_behavior(s)
	manager.emitter.request_shot_id(rs)
	manager.step(DT)
	var pool := manager.pool
	assert_eq(pool.owner_layer[pool.slot_of(s.kid)], Layers.PLAYER, "second bullet's child is the second bullet's owner")
	assert_eq(pool.hook_owner, -1)
	assert_eq(pool.hook_slot, -1)

## Hook reflects itself, then writes NaN into vel -> sanitize kills it (INVALID).
class Poison:
	extends BulletBehavior
	func on_update(pool: BulletPool, i: int, _d: float) -> void:
		pool.reflect(i, Layers.ENEMY, false, 1.0, true)
		pool.vel[i] = Vector2(NAN, 0)

func test_h3_self_reflect_then_nan_keeps_counters_and_context_consistent() -> void:
	var r := _req(Layers.PLAYER)
	r.behavior_id = manager.register_behavior(Poison.new())
	manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_eq(pool.count, 0, "killed INVALID and removed")
	assert_true(pool.counters_consistent())
	assert_eq(pool.hook_owner, -1)
	assert_eq(pool.hook_slot, -1)

## on_hit hook that reflects its own bullet then spawns; later hooks must be unaffected.
class HitReflect:
	extends BulletBehavior
	var kid := -1
	func on_hit(pool: BulletPool, i: int, _h: Hurtbox) -> void:
		pool.reflect(i, Layers.ENEMY, false, 1.0, true)
		var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r.lifetime = 5.0
		r.owner_layer = Layers.PLAYER
		kid = emitter.request_shot_id(r)
	func can_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> bool:
		return true

func test_h4_on_hit_and_can_hit_contexts_restore() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(60, 50)
	var beh := HitReflect.new()
	var r := ShotRequest.with_velocity(Vector2(50, 50), Vector2(600, 0))
	r.lifetime = 5.0
	r.owner_layer = Layers.PLAYER
	r.hit_mask = Layers.ENEMY
	r.pierce = 1
	r.can_hit_veto = true
	r.behavior_id = manager.register_behavior(beh)
	manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_gte(beh.kid, 0)
	assert_eq(pool.owner_layer[pool.slot_of(beh.kid)], Layers.ENEMY, "child follows the new owner")
	assert_eq(pool.hook_owner, -1)
	assert_eq(pool.hook_slot, -1)
	assert_true(pool.counters_consistent())


## h6: parent hook spawns a behaviour child (nested hook, restores context), THEN reflects itself and spawns.
class NoopChild:
	extends BulletBehavior
	func on_spawn(_p: BulletPool, _i: int) -> void:
		pass
class ParentLate:
	extends BulletBehavior
	var child_beh := 0
	var late_kid := -1
	var done := false
	func on_update(pool: BulletPool, i: int, _d: float) -> void:
		if done:
			return
		done = true
		var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r.lifetime = 5.0
		r.owner_layer = Layers.PLAYER
		r.behavior_id = child_beh
		emitter.request_shot_id(r)
		pool.reflect(i, Layers.ENEMY, false, 1.0, true)
		var r2 := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r2.lifetime = 5.0
		r2.owner_layer = Layers.PLAYER
		late_kid = emitter.request_shot_id(r2)

func test_h6_nested_hook_restores_hook_slot_so_a_later_self_reflect_still_updates_the_owner() -> void:
	var p := ParentLate.new()
	p.child_beh = manager.register_behavior(NoopChild.new())
	var r := _req(Layers.PLAYER)
	r.behavior_id = manager.register_behavior(p)
	manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_eq(pool.owner_layer[pool.slot_of(p.late_kid)], Layers.ENEMY)

## h7: can_hit reflects its own bullet then spawns.
class VetoReflect:
	extends BulletBehavior
	var kid := -1
	func can_hit(pool: BulletPool, i: int, _h: Hurtbox) -> bool:
		if kid < 0:
			pool.reflect(i, Layers.ENEMY, false, 1.0, true)
			var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
			r.lifetime = 5.0
			r.owner_layer = Layers.PLAYER
			kid = emitter.request_shot_id(r)
		return false

func test_h7_can_hit_self_reflect_then_spawn_gives_the_new_owner() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(60, 50)
	var beh := VetoReflect.new()
	var r := ShotRequest.with_velocity(Vector2(50, 50), Vector2(600, 0))
	r.lifetime = 5.0
	r.owner_layer = Layers.PLAYER
	r.hit_mask = Layers.ENEMY
	r.can_hit_veto = true
	r.behavior_id = manager.register_behavior(beh)
	manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_gte(beh.kid, 0, "can_hit ran")
	assert_eq(pool.owner_layer[pool.slot_of(beh.kid)], Layers.ENEMY)

## h8: on_despawn reflects (a dying bullet) then spawns.
class DespawnReflect:
	extends BulletBehavior
	var kid := -1
	func on_despawn(pool: BulletPool, i: int, _reason: int) -> void:
		pool.reflect(i, Layers.ENEMY, false, 1.0, true)
		var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r.lifetime = 5.0
		r.owner_layer = Layers.PLAYER
		kid = emitter.request_shot_id(r)

func test_h8_on_despawn_reflect_is_refused_and_context_restored() -> void:
	var beh := DespawnReflect.new()
	var r := _req(Layers.PLAYER)
	r.lifetime = 0.01
	r.behavior_id = manager.register_behavior(beh)
	manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_gte(beh.kid, 0)
	# reflect() refuses a bullet that is already dead, so the child keeps the owner of the dying bullet.
	assert_eq(pool.owner_layer[pool.slot_of(beh.kid)], Layers.PLAYER)
	assert_eq(pool.hook_slot, -1)
