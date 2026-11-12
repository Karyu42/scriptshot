extends GutTest
## Script owners for hot reload: hooked_count_for_owner(), hooked_owner_drained
## and strip_hooks_for_owner() / release_behavior(). The owner id is the
## behavior id from register_behavior(). GDScript pool; the native part runs
## when the extension is built.

const DT := 1.0 / 60.0

var manager: BulletManager
var _drained: Array[int] = []


## Per-bullet hook: counts its ticks and keeps a bit of user state.
class Steer:
	extends BulletBehavior
	var ticks := 0
	var despawns := 0

	func _init() -> void:
		hook_mask = BulletBehavior.HOOK_ON_DESPAWN | BulletBehavior.HOOK_CAN_HIT

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		ticks += 1

	func can_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> bool:
		return true

	func on_despawn(_pool: BulletPool, _index: int, _reason: int) -> void:
		despawns += 1


## Batch-only: lives in the native sim when the extension is built.
class Batch:
	extends BulletBehavior
	var calls := 0

	func _init() -> void:
		update_mode = BulletBehavior.UpdateMode.BATCH
		hook_mask = 0
		hook_mask_exact = true

	func on_update_batch(_batch: BatchView) -> void:
		calls += 1


func before_each() -> void:
	ScriptWarnings.reset()
	_drained.clear()
	manager = _make_manager("gdscript")


func _make_manager(pref: String) -> BulletManager:
	var m := BulletManager.new()
	m.backend_preference = pref
	m.capacity = 128
	m.world_bounds = Rect2(-4000, -4000, 8000, 8000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	m.hooked_owner_drained.connect(func(id: int) -> void: _drained.append(id))
	return m


func _shot(owner_id: int, velocity: Vector2 = Vector2(100, 0), life: float = 5.0) -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2.ZERO, velocity)
	r.lifetime = life
	r.behavior_id = owner_id
	r.can_hit_veto = owner_id > 0
	r.owner_layer = Layers.PLAYER
	r.hit_mask = Layers.ENEMY
	return r


func _spawn(owner_id: int, velocity: Vector2 = Vector2(100, 0), life: float = 5.0) -> int:
	var slot := manager.spawn(_shot(owner_id, velocity, life))
	assert_gte(slot, 0)
	return manager.pool.id_of(slot)


func test_count_goes_up_on_spawn_and_down_on_despawn() -> void:
	var owner := manager.register_behavior(Steer.new())
	assert_eq(manager.hooked_count_for_owner(owner), 0)
	_spawn(owner, Vector2(100, 0), 5.0)
	_spawn(owner, Vector2(100, 0), 5.0)
	_spawn(owner, Vector2(100, 0), 2.5 * DT)
	assert_eq(manager.hooked_count_for_owner(owner), 3)
	manager.step(DT)
	manager.step(DT)
	manager.step(DT)
	assert_eq(manager.hooked_count_for_owner(owner), 2, "the short-lived one expired")
	assert_true(manager.pool.behavior_counts_consistent())
	assert_eq(_drained, [] as Array[int])


func test_plain_bullets_and_unknown_ids_are_not_counted() -> void:
	_spawn(0)
	assert_eq(manager.hooked_count_for_owner(0), 0)
	assert_eq(manager.pool.behavior_live.size(), 0)
	manager.spawn(_shot(99))
	assert_push_warning("unknown behavior_id 99")
	assert_eq(manager.hooked_count_for_owner(99), 0)
	manager.step(DT)
	assert_eq(_drained, [] as Array[int], "an unknown id never had bullets")


func test_drained_fires_once_when_the_count_reaches_zero() -> void:
	var owner := manager.register_behavior(Steer.new())
	_spawn(owner, Vector2(10, 0), 1.5 * DT)
	_spawn(owner, Vector2(10, 0), 2.5 * DT)
	manager.step(DT)
	manager.step(DT)
	assert_eq(_drained, [] as Array[int], "one still alive")
	manager.step(DT)
	assert_eq(manager.hooked_count_for_owner(owner), 0)
	assert_eq(_drained, [owner] as Array[int])
	manager.step(DT)
	manager.step(DT)
	assert_eq(_drained, [owner] as Array[int], "fires once, not every tick at 0")
	# A new bullet re-arms it.
	_spawn(owner, Vector2(10, 0), 0.5 * DT)
	manager.step(DT)
	assert_eq(_drained, [owner, owner] as Array[int])


func test_a_despawn_and_respawn_in_the_same_tick_does_not_fire() -> void:
	var owner := manager.register_behavior(Steer.new())
	var id := _spawn(owner)
	manager.pool.mark_dead(manager.pool.slot_of(id))
	manager.pool.flush_dead()
	_spawn(owner)
	manager.step(DT)
	assert_eq(manager.hooked_count_for_owner(owner), 1)
	assert_eq(_drained, [] as Array[int])


func test_clear_bullets_drains_every_owner() -> void:
	var a := manager.register_behavior(Steer.new())
	var b := manager.register_behavior(Steer.new())
	_spawn(a)
	_spawn(b)
	manager.clear_bullets()
	assert_eq(manager.hooked_count_for_owner(a), 0)
	_drained.sort()
	assert_eq(_drained, [a, b] as Array[int])


func test_reflect_that_drops_the_script_leaves_the_owner() -> void:
	var owner := manager.register_behavior(Steer.new())
	var id := _spawn(owner)
	var kept := _spawn(owner)
	assert_true(manager.reflect(id, Layers.ENEMY))
	assert_eq(manager.hooked_count_for_owner(owner), 1)
	assert_true(manager.reflect(kept, Layers.ENEMY, false, -1.0, true))
	assert_eq(manager.hooked_count_for_owner(owner), 1, "keep_script keeps the owner")
	assert_true(manager.pool.behavior_counts_consistent())


func test_strip_keeps_bullets_flying_plain_with_the_same_velocity() -> void:
	var steer := Steer.new()
	var owner := manager.register_behavior(steer)
	var ids: Array[int] = []
	for i in 3:
		ids.append(_spawn(owner, Vector2(50.0 + 10.0 * i, -20.0)))
	var pool := manager.pool
	pool.user[pool.slot_of(ids[0])] = {"state": 1}
	manager.step(DT)
	var ticks_before := steer.ticks
	var vel_before: Array[Vector2] = []
	var pos_before: Array[Vector2] = []
	for id in ids:
		vel_before.append(pool.vel[pool.slot_of(id)])
		pos_before.append(pool.pos[pool.slot_of(id)])
	assert_gt(pool.veto_count, 0)
	var n := manager.strip_hooks_for_owner(owner)
	assert_eq(n, 3)
	assert_eq(manager.hooked_count_for_owner(owner), 0)
	assert_eq(_drained, [owner] as Array[int], "a strip drains the owner")
	assert_eq(pool.veto_count, 0, "the can_hit veto went with the hook")
	for k in ids.size():
		var slot := pool.slot_of(ids[k])
		assert_gte(slot, 0, "still alive, same id")
		assert_eq(pool.behavior[slot], 0)
		assert_true(pool.user[slot] == null)
		assert_eq(pool.vel[slot], vel_before[k])
	manager.step(DT)
	assert_eq(steer.ticks, ticks_before, "no hook runs after the strip")
	for k in ids.size():
		var slot := pool.slot_of(ids[k])
		assert_eq(pool.vel[slot], vel_before[k])
		assert_almost_eq(pool.pos[slot].x, pos_before[k].x + vel_before[k].x * DT, 0.001)
	pool.mark_dead(pool.slot_of(ids[0]))
	manager.step(DT)
	assert_eq(steer.despawns, 0, "a stripped bullet's despawn does not call the old hook")
	assert_eq(_drained, [owner] as Array[int])
	assert_true(pool.behavior_counts_consistent())


func test_strip_leaves_other_owners_alone() -> void:
	var a_hooks := Steer.new()
	var b_hooks := Steer.new()
	var a := manager.register_behavior(a_hooks)
	var b := manager.register_behavior(b_hooks)
	_spawn(a)
	_spawn(a)
	var b_id := _spawn(b)
	_spawn(0)
	assert_eq(manager.strip_hooks_for_owner(a), 2)
	assert_eq(manager.hooked_count_for_owner(b), 1)
	assert_eq(manager.pool.behavior[manager.pool.slot_of(b_id)], b)
	assert_eq(_drained, [a] as Array[int])
	var b_ticks := b_hooks.ticks
	manager.step(DT)
	assert_eq(b_hooks.ticks, b_ticks + 1, "b still runs its hook")
	assert_eq(manager.strip_hooks_for_owner(a), 0, "nothing left to strip")
	assert_eq(_drained, [a] as Array[int], "an empty strip does not fire again")


func test_release_behavior_lets_the_behavior_go() -> void:
	var steer := Steer.new()
	var ref: WeakRef = weakref(steer)
	var owner := manager.register_behavior(steer)
	_spawn(owner)
	steer = null
	assert_true(ref.get_ref() != null, "the manager holds it")
	assert_eq(manager.release_behavior(owner), 1)
	assert_true(ref.get_ref() == null, "nothing holds the old generation any more")
	assert_eq(_drained, [owner] as Array[int])
	# The id is not reused and a late shot naming it is plain.
	var late := manager.spawn(_shot(owner))
	assert_gte(late, 0)
	manager.step(DT)
	assert_eq(manager.pool.hooked_count, 1, "still listed (behavior id kept), but the inert hook does nothing")
	var fresh := manager.register_behavior(Steer.new())
	assert_ne(fresh, owner)


func test_native_batch_owner_counts_drains_and_strips() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var m := _make_manager("native")
	var batch := Batch.new()
	var owner := m.register_behavior(batch)
	var r := _shot(owner, Vector2(40, 0), 5.0)
	for _i in 3:
		assert_true(m.is_native_id(m.spawn(r)))
	assert_eq(m.hooked_count_for_owner(owner), 3)
	m.step(DT)
	assert_gt(batch.calls, 0)
	var vel_before := m.native.velocity_of(m.native.id_of_slot(0))
	assert_eq(m.strip_hooks_for_owner(owner), 3)
	assert_eq(m.hooked_count_for_owner(owner), 0)
	assert_eq(_drained, [owner] as Array[int])
	assert_eq(m.alive_count(), 3, "moved to the pool as plain bullets, still alive")
	assert_eq(m.pool.vel[0], vel_before)
	var calls := batch.calls
	m.step(DT)
	assert_eq(batch.calls, calls, "on_batch no longer runs for them")
	# A native drain without a strip.
	var short := _shot(owner, Vector2(40, 0), 0.5 * DT)
	assert_true(m.is_native_id(m.spawn(short)))
	_drained.clear()
	m.step(DT)
	m.step(DT)
	assert_eq(_drained, [owner] as Array[int])


# --- re-entrant drain listeners (SE review #76, blocker) ---------------------------

## The hot-reload listener: release the generation that just drained.
func _release_on_drain(m: BulletManager) -> void:
	m.hooked_owner_drained.connect(func(id: int) -> void: m.release_behavior(id))


func test_a_listener_that_releases_does_not_double_fire_gd() -> void:
	# GD stand-in for the native case: owner b sits in the native watch with no
	# native store, the state a batch-only owner is in once its sim rows are gone.
	_release_on_drain(manager)
	var a := manager.register_behavior(Steer.new())
	var b := manager.register_behavior(Batch.new())
	_spawn(a, Vector2(10, 0), 0.5 * DT)
	manager._native_owner_watch[b] = true
	manager.step(DT)
	_drained.sort()
	assert_eq(_drained, [a, b] as Array[int], "each owner exactly once")
	manager.step(DT)
	assert_eq(_drained.size(), 2)


func test_listeners_calling_strip_and_clear_do_not_double_fire() -> void:
	var a := manager.register_behavior(Steer.new())
	var b := manager.register_behavior(Steer.new())
	var c := manager.register_behavior(Steer.new())
	manager.hooked_owner_drained.connect(func(id: int) -> void:
		manager.strip_hooks_for_owner(id)
		manager.strip_hooks_for_owner(c)
		manager.clear_bullets()
	)
	_spawn(a, Vector2(10, 0), 0.5 * DT)
	_spawn(b, Vector2(10, 0), 0.5 * DT)
	_spawn(c, Vector2(10, 0), 5.0)
	manager._native_owner_watch[b] = true
	manager.step(DT)
	var counts: Dictionary[int, int] = {}
	for id in _drained:
		var n: int = counts.get(id, 0)
		counts[id] = n + 1
	assert_eq(counts, {a: 1, b: 1, c: 1} as Dictionary[int, int])


func test_a_listener_that_spawns_again_keeps_the_owner_alive() -> void:
	var a := manager.register_behavior(Steer.new())
	var respawned := [false]
	manager.hooked_owner_drained.connect(func(id: int) -> void:
		if not respawned[0]:
			respawned[0] = true
			manager.spawn(_shot(id))
	)
	_spawn(a, Vector2(10, 0), 0.5 * DT)
	manager.step(DT)
	assert_eq(_drained, [a] as Array[int])
	assert_eq(manager.hooked_count_for_owner(a), 1)


func test_native_two_owners_drain_in_one_tick_and_the_listener_releases() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var m := _make_manager("native")
	_release_on_drain(m)
	var a := m.register_behavior(Steer.new())
	var b := m.register_behavior(Batch.new())
	assert_false(m.is_native_id(m.spawn(_shot(a, Vector2(10, 0), 0.5 * DT))))
	assert_true(m.is_native_id(m.spawn(_shot(b, Vector2(10, 0), 0.5 * DT))))
	m.step(DT)
	_drained.sort()
	assert_eq(_drained, [a, b] as Array[int], "each owner exactly once")
	# And the other order: native first in the watch, pool second.
	_drained.clear()
	var c := m.register_behavior(Batch.new())
	var d := m.register_behavior(Steer.new())
	assert_true(m.is_native_id(m.spawn(_shot(c, Vector2(10, 0), 0.5 * DT))))
	m.spawn(_shot(d, Vector2(10, 0), 0.5 * DT))
	m.step(DT)
	_drained.sort()
	assert_eq(_drained, [c, d] as Array[int])


# --- native drains by hit and by wall -------------------------------------------------

func _native_or_pending() -> BulletManager:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return null
	return _make_manager("native")


func test_native_batch_owner_drains_by_hit() -> void:
	var m := _native_or_pending()
	if m == null:
		return
	var hb := Hurtbox.new()
	hb.radius = 16.0
	hb.layer = Layers.ENEMY
	hb.position = Vector2(30, 0)
	add_child_autofree(hb)
	var owner := m.register_behavior(Batch.new())
	assert_true(m.is_native_id(m.spawn(_shot(owner, Vector2(600, 0), 5.0))))
	for _i in 10:
		m.step(DT)
		if not _drained.is_empty():
			break
	assert_eq(_drained, [owner] as Array[int])
	assert_eq(m.hooked_count_for_owner(owner), 0)


func test_native_batch_owner_drains_by_wall() -> void:
	var m := _native_or_pending()
	if m == null:
		return
	m.add_wall(Rect2(60, -100, 40, 200))
	var owner := m.register_behavior(Batch.new())
	assert_true(m.is_native_id(m.spawn(_shot(owner, Vector2(600, 0), 5.0))))
	for _i in 10:
		m.step(DT)
		if not _drained.is_empty():
			break
	assert_eq(_drained, [owner] as Array[int])
	assert_eq(m.hooked_count_for_owner(owner), 0)


func test_gd_owner_drains_by_hit_and_by_wall() -> void:
	var hb := Hurtbox.new()
	hb.radius = 16.0
	hb.layer = Layers.ENEMY
	hb.position = Vector2(30, 0)
	add_child_autofree(hb)
	manager.add_wall(Rect2(60, 200, 40, 200))
	var by_hit := manager.register_behavior(Steer.new())
	var by_wall := manager.register_behavior(Steer.new())
	manager.spawn(_shot(by_hit, Vector2(600, 0), 5.0))
	var r := _shot(by_wall, Vector2(600, 0), 5.0)
	r.position = Vector2(0, 300)
	manager.spawn(r)
	for _i in 10:
		manager.step(DT)
	_drained.sort()
	var want: Array[int] = [by_hit, by_wall]
	want.sort()
	assert_eq(_drained, want)
