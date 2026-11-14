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


## Releases its owner from on_update, then writes that packed id onto a later
## bullet in the same pass (set_behavior or a raw array write).
class StaleRewriter:
	extends BulletBehavior
	var ticks := 0
	var manager: BulletManager
	var owner_id := 0
	var via_set_behavior := true
	var wrote := false

	func _init() -> void:
		hook_mask = BulletBehavior.HOOK_ON_DESPAWN

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		ticks += 1
		if wrote:
			return
		var later := -1
		for k in pool.hooked_count:
			var i: int = pool.hooked[k]
			if i != index:
				later = i
				break
		manager.release_behavior(owner_id)
		if later < 0:
			return
		wrote = true
		if via_set_behavior:
			pool.set_behavior(later, owner_id)
		else:
			pool.behavior[later] = owner_id


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
	# A late shot naming the released id is rejected: it becomes a plain bullet.
	# The slot may be reused, but the packed id is not, so a later script never
	# sees that stale handle.
	var late := manager.spawn(_shot(owner))
	assert_gte(late, 0)
	assert_eq(manager.pool.behavior[late], 0, "a stale id is rejected")
	manager.step(DT)
	assert_eq(manager.pool.hooked_count, 0, "the late shot is plain")
	var fresh_steer := Steer.new()
	var fresh := manager.register_behavior(fresh_steer)
	assert_ne(fresh, owner, "a released packed id is not reused")
	var late2 := manager.spawn(_shot(owner))
	assert_gte(late2, 0)
	manager.step(DT)
	assert_eq(fresh_steer.ticks, 0, "a stale id never runs the new script")
	assert_eq(manager.hooked_count_for_owner(owner), 0)
	assert_eq(manager.hooked_count_for_owner(fresh), 0)


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
	var want_cd: Array[int] = [c, d]
	want_cd.sort()
	assert_eq(_drained, want_cd, "each reused owner exactly once")


# --- a second drain inside the same emit loop (SE re-review #76, blocker) ---------

enum Drain { STRIP, RELEASE, CLEAR }


## A drains; on that drain a listener spawns for A again, then (in the same
## handler, or in a later listener) A drains again via `how`. Returns how often
## A was announced. `sim_native` marks the respawn in the native watch the way
## a native spawn of a batch-only owner does, so the GD run walks that path.
func _drain_twice(m: BulletManager, batch: bool, how: Drain, same_handler: bool, sim_native: bool) -> int:
	var behavior: BulletBehavior = Batch.new() if batch else Steer.new()
	var a := m.register_behavior(behavior)
	var seen: Array[int] = []
	var state := {"respawned": false, "drained_again": false}
	var drain_again := func(id: int) -> void:
		if id != a or state["drained_again"] or not state["respawned"]:
			return
		state["drained_again"] = true
		match how:
			Drain.STRIP:
				assert_eq(m.strip_hooks_for_owner(a), 1)
			Drain.RELEASE:
				m.release_behavior(a)
			Drain.CLEAR:
				m.clear_bullets()
	m.hooked_owner_drained.connect(func(id: int) -> void:
		if id != a:
			return
		seen.append(id)
		if state["respawned"]:
			return
		state["respawned"] = true
		m.spawn(_shot(a, Vector2(10, 0), 5.0))
		if sim_native:
			m._native_owner_watch[a] = true
		assert_eq(m.hooked_count_for_owner(a), 1, "alive again after the respawn")
		if same_handler:
			drain_again.call(id)
	)
	if not same_handler:
		m.hooked_owner_drained.connect(drain_again)
	m.spawn(_shot(a, Vector2(10, 0), 0.5 * DT))
	if sim_native:
		m._native_owner_watch[a] = true
	m.step(DT)
	assert_eq(m.hooked_count_for_owner(a), 0, "A is really empty again")
	m.step(DT)
	m.step(DT)
	return seen.size()


func _drain_twice_matrix(make: Callable, sims: Array[bool]) -> void:
	for batch: bool in [false, true]:
		for how: Drain in [Drain.STRIP, Drain.RELEASE, Drain.CLEAR]:
			for same: bool in [true, false]:
				for sim: bool in sims:
					var m: BulletManager = make.call()
					var n := _drain_twice(m, batch, how, same, sim)
					assert_eq(n, 2, "A announced again: batch=%s how=%s same_handler=%s sim_native=%s"
						% [batch, Drain.keys()[how], same, sim])
					m.queue_free()


func test_a_listener_that_spawns_again_keeps_the_owner_alive_then_strips() -> void:
	# The case SE asked for: respawn, then strip in the same handler.
	var n := _drain_twice(manager, false, Drain.STRIP, true, false)
	assert_eq(n, 2)


func test_a_second_drain_in_the_same_loop_is_announced_gd() -> void:
	_drain_twice_matrix(func() -> BulletManager: return _make_manager("gdscript"), [false, true] as Array[bool])


func test_a_second_drain_in_the_same_loop_is_announced_native() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_drain_twice_matrix(func() -> BulletManager: return _make_manager("native"), [false] as Array[bool])


func test_a_listener_that_respawns_and_drains_forever_is_bounded() -> void:
	var a := manager.register_behavior(Steer.new())
	var seen: Array[int] = []
	manager.hooked_owner_drained.connect(func(id: int) -> void:
		seen.append(id)
		manager.spawn(_shot(id, Vector2(10, 0), 5.0))
		manager.strip_hooks_for_owner(id)
	)
	_spawn(a, Vector2(10, 0), 0.5 * DT)
	manager.step(DT)
	assert_eq(seen.size(), BulletManager.DRAIN_EMITS_PER_OWNER, "capped within one call")
	assert_eq(manager._drain_queue, [a] as Array[int], "the rest is deferred")
	manager.step(DT)
	assert_eq(seen.size(), 2 * BulletManager.DRAIN_EMITS_PER_OWNER, "picked up on the next tick")


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

func test_ten_thousand_releases_stay_bounded_and_reject_stale_ids() -> void:
	const N := 10000
	var first_id := 0
	var mid_id := 0
	var refs: Array[WeakRef] = []
	var mem_after_warmup := 0
	for i in N:
		var steer := Steer.new()
		var id := manager.register_behavior(steer)
		if i == 0:
			first_id = id
		elif i == N / 2:
			mid_id = id
		if i == 200:
			mem_after_warmup = OS.get_static_memory_usage()
		if i % 1000 == 0:
			refs.append(weakref(steer))
		assert_eq(manager.release_behavior(id), 0)
		steer = null
	assert_lte(manager._behaviors.size(), 2, "slots are reused: only slot 0 plus one recycled slot")
	assert_eq(manager._owner_free.size(), 1)
	assert_eq(manager._get_behavior(first_id), null, "the first id is stale")
	assert_eq(manager._get_behavior(mid_id), null, "the mid-run id is stale")
	var late := manager.spawn(_shot(first_id))
	assert_gte(late, 0)
	assert_eq(manager.hooked_count_for_owner(first_id), 0)
	if manager.is_native_id(late):
		assert_eq(manager.native.count_with_behavior(first_id), 0, "a stale id is not tagged on the sim")
	else:
		assert_eq(manager.pool.behavior[late], 0, "a stale id becomes a plain bullet")
	var fresh := Steer.new()
	var fresh_id := manager.register_behavior(fresh)
	assert_ne(fresh_id, first_id)
	assert_ne(fresh_id, mid_id)
	assert_eq(manager._behaviors.size(), 2, "the new register reused the free slot")
	manager.spawn(_shot(first_id))
	manager.step(DT)
	assert_eq(fresh.ticks, 0, "a stale id never runs the new script")
	manager.spawn(_shot(fresh_id))
	manager.step(DT)
	assert_eq(fresh.ticks, 1, "the live id still runs")
	for r: WeakRef in refs:
		assert_true(r.get_ref() == null, "released behaviours are freed")
	var mem := OS.get_static_memory_usage()
	# 10k inert ~2.4 KiB objects would be ~24 MiB. A few MiB of allocator noise is fine.
	assert_lt(mem, mem_after_warmup + 8 * 1024 * 1024, "memory stays bounded across 10k releases")


func test_ten_thousand_releases_stay_bounded_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	manager = _make_manager("native")
	test_ten_thousand_releases_stay_bounded_and_reject_stale_ids()


# --- SE review #106: 15-bit generation wrap and re-entrant release ---------------

func _preset_generation(m: BulletManager, slot: int, gen: int) -> void:
	m._owner_gen[slot] = gen


func _assert_generation_wraps(m: BulletManager) -> void:
	var first := m.register_behavior(Steer.new())
	var slot := first & BulletManager.OWNER_SLOT_MASK
	assert_eq(m.release_behavior(first), 0)
	# Last 15-bit generation. The next register packs this; the release after
	# that wraps (0 is skipped, so the new life is generation 1).
	_preset_generation(m, slot, BulletManager.OWNER_GEN_MASK)
	var steer := Steer.new()
	var owner := m.register_behavior(steer)
	assert_gt(owner, 0, "the packed id stays positive at generation 32767")
	assert_eq(owner >> BulletManager.OWNER_SLOT_BITS, BulletManager.OWNER_GEN_MASK)
	assert_eq(owner & BulletManager.OWNER_SLOT_MASK, slot)
	assert_gte(m.spawn(_shot(owner)), 0)
	m.step(DT)
	assert_eq(steer.ticks, 1, "hooks run at the last 15-bit generation")
	assert_eq(m.hooked_count_for_owner(owner), 1)
	assert_eq(m.release_behavior(owner), 1)
	assert_eq(m.hooked_count_for_owner(owner), 0, "counts drain across the wrap")
	var wrapped_gen: int = m._owner_gen[slot]
	assert_eq(wrapped_gen, 1, "generation wraps to 1, skipping 0")
	assert_eq(m._owner_free, [slot] as Array[int])
	var next_steer := Steer.new()
	var wrapped := m.register_behavior(next_steer)
	assert_gt(wrapped, 0, "the wrapped id stays positive")
	assert_ne(wrapped, owner)
	assert_eq(wrapped >> BulletManager.OWNER_SLOT_BITS, 1)
	assert_gte(m.spawn(_shot(wrapped)), 0)
	m.step(DT)
	assert_eq(next_steer.ticks, 1, "hooks run after the wrap")
	assert_eq(m.hooked_count_for_owner(wrapped), 1)


func test_generation_wraps_within_fifteen_bits_and_hooks_keep_running() -> void:
	_assert_generation_wraps(manager)


func test_generation_wraps_within_fifteen_bits_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_assert_generation_wraps(_make_manager("native"))


func _assert_reentrant_release_does_not_free_twice(m: BulletManager) -> void:
	# The outer release strips, which emits hooked_owner_drained, and the
	# listener releases the same id again. The second call must be a no-op.
	m.hooked_owner_drained.connect(func(id: int) -> void: m.release_behavior(id))
	var a := m.register_behavior(Steer.new())
	assert_gte(m.spawn(_shot(a)), 0)
	assert_eq(m.release_behavior(a), 1)
	assert_eq(m._owner_free.size(), 1, "the slot is on the free list once")
	var b := m.register_behavior(Steer.new())
	var c := m.register_behavior(Steer.new())
	assert_ne(b, c, "two registrations after a re-release get distinct ids")
	assert_ne(b, a)
	assert_ne(c, a)
	assert_gt(b, 0)
	assert_gt(c, 0)


func test_a_reentrant_release_is_a_noop_and_later_ids_are_distinct() -> void:
	_assert_reentrant_release_does_not_free_twice(manager)


func test_a_reentrant_release_is_a_noop_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_assert_reentrant_release_does_not_free_twice(_make_manager("native"))

func _assert_stale_set_batch_only_is_a_noop(m: BulletManager) -> void:
	var stale := m.register_behavior(Batch.new())
	assert_eq(m.release_behavior(stale), 0)
	var steer := Steer.new()
	var fresh := m.register_behavior(steer)
	assert_eq(fresh & BulletManager.OWNER_SLOT_MASK, stale & BulletManager.OWNER_SLOT_MASK)
	assert_ne(fresh, stale)
	assert_gte(m.spawn(_shot(fresh)), 0)
	m.pool.set_batch_only(stale, true)
	m.step(DT)
	assert_eq(steer.ticks, 1, "a stale set_batch_only must not make the new occupant batch-only")
	# A stale clear must not drop a live batch occupant from the batch path.
	assert_eq(m.release_behavior(fresh), 1)
	var live := m.register_behavior(Batch.new())
	assert_eq(live & BulletManager.OWNER_SLOT_MASK, stale & BulletManager.OWNER_SLOT_MASK)
	assert_gte(m.spawn(_shot(live)), 0)
	m.pool.set_batch_only(fresh, false)
	var flag: int = m.pool.batch_only[live & BulletManager.OWNER_SLOT_MASK]
	assert_eq(flag, 1, "a stale clear must not drop the live batch-only flag")


func test_a_stale_set_batch_only_is_a_noop() -> void:
	_assert_stale_set_batch_only_is_a_noop(manager)


func test_a_stale_set_batch_only_is_a_noop_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_assert_stale_set_batch_only_is_a_noop(_make_manager("native"))

func _grow_owner_table_to_the_slot_limit(m: BulletManager) -> void:
	# Slot 0 is unused; the packed field can address 1..65535. After that
	# the next new slot would be 65536, which does not fit.
	var n := BulletManager.OWNER_SLOT_MASK + 1
	m._behaviors.resize(n)
	m._hook_cache.resize(n)
	m._hook_scripts.resize(n)
	m._declared_checked.resize(n)
	m._declared_scripts.resize(n)
	m._update_override.resize(n)
	m._owner_gen.resize(n)


func _assert_the_slot_cap_returns_zero_and_a_freed_slot_is_usable_again(m: BulletManager) -> void:
	var first := m.register_behavior(Steer.new())
	assert_gt(first, 0)
	_grow_owner_table_to_the_slot_limit(m)
	assert_eq(m._behaviors.size(), BulletManager.OWNER_SLOT_MASK + 1)
	assert_eq(m._owner_free.size(), 0)
	var capped := m.register_behavior(Steer.new())
	assert_eq(capped, 0, "the 65,536th slot does not fit in the packed id")
	assert_push_error("65,535 usable slots")
	assert_eq(m.release_behavior(first), 0)
	var again := m.register_behavior(Steer.new())
	assert_gt(again, 0, "a freed slot is usable after the cap is hit")
	assert_ne(again, 0)
	assert_eq(again & BulletManager.OWNER_SLOT_MASK, first & BulletManager.OWNER_SLOT_MASK)


func test_the_65536th_register_returns_zero_and_a_freed_slot_is_usable_again() -> void:
	_assert_the_slot_cap_returns_zero_and_a_freed_slot_is_usable_again(manager)


func test_the_65536th_register_returns_zero_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_assert_the_slot_cap_returns_zero_and_a_freed_slot_is_usable_again(_make_manager("native"))


func _assert_a_released_id_written_mid_pass_is_rejected(m: BulletManager, via_set_behavior: bool) -> void:
	ScriptWarnings.reset()
	var writer := StaleRewriter.new()
	writer.manager = m
	writer.via_set_behavior = via_set_behavior
	var owner := m.register_behavior(writer)
	writer.owner_id = owner
	var first := m.spawn(_shot(owner))
	var later := m.spawn(_shot(owner))
	assert_gte(first, 0)
	assert_gte(later, 0)
	assert_ne(first, later)
	m.step(DT)
	assert_eq(writer.ticks, 1, "the released behaviour must not run again on the later bullet")
	assert_eq(m.pool.behavior[later], 0, "the stale id is dropped")
	assert_eq(m.pool.behavior[first], 0)
	assert_push_warning("unknown behavior id %d" % owner)


func _assert_stale_id_written_after_release_is_rejected(m: BulletManager) -> void:
	_assert_a_released_id_written_mid_pass_is_rejected(m, true)
	_assert_a_released_id_written_mid_pass_is_rejected(m, false)


func test_a_hook_that_writes_a_just_released_id_is_rejected() -> void:
	_assert_stale_id_written_after_release_is_rejected(manager)


func test_a_hook_that_writes_a_just_released_id_is_rejected_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_assert_stale_id_written_after_release_is_rejected(_make_manager("native"))

