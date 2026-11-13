extends GutTest
## LuaShot hot-reload generations on both backends: a generation whose last
## hooked shot is gone is released (BulletManager.release_behavior) and its
## host is reused, so 50 reloads keep the Lua state count and Lua heap
## bounded; shots in flight finish on the code they were fired with; and a
## drain that arrives during a reload, inside the emit loop, or after the slot
## was released does nothing harmful.

const DT := 1.0 / 60.0
const BACKENDS: Array[String] = ["gdscript", "native"]
const RELOADS := 50
## Per-bullet hooks (pool) and a batch-only weapon (native sim when native).
const HOOKED := "return { name = 'G%d', speed = 1, lifetime = %s, on_hit = function(b, h) end, on_spawn = function(b) local t = {} for i = 1, 64 do t[i] = i end end }"
const BATCH := "return { name = 'B%d', speed = 1, lifetime = %s, on_batch = function(v, dt) end }"

var _mgrs: Array[BulletManager] = []
var _shots: Array[LuaShot] = []


func before_each() -> void:
	ScriptWarnings.reset()


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	_shots.clear()


func _skip(preference: String) -> bool:
	if preference == "native" and not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return true
	return false


func _mgr(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 2048
	manager.logical_cap = 2048
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-4000, -4000, 8000, 8000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	_mgrs.append(manager)
	return manager


func _shot(manager: BulletManager) -> LuaShot:
	var shot := LuaShot.new(manager)
	_shots.append(shot)
	return shot


func _ctx() -> ShotContext:
	var ctx := ShotContext.new()
	ctx.muzzle_position = Vector2.ZERO
	ctx.aim_direction = Vector2.RIGHT
	ctx.aim_angle = 0.0
	ctx.target_mask = Layers.ENEMY
	return ctx


func _fire(manager: BulletManager, shot: LuaShot, n: int = 1) -> void:
	for i in n:
		shot.fire(_ctx(), manager.emitter)


func _steps(manager: BulletManager, n: int) -> void:
	for i in n:
		manager.step(DT)


func _apply(shot: LuaShot, code: String) -> void:
	var r := shot.apply(code)
	assert_true(r.ok, r.error)
	if r.ok:
		shot.behavior().host.wall_msec = 5000


## Steps until no bullet is left (bounded).
func _drain_all(manager: BulletManager) -> void:
	for i in 600:
		if manager.alive_count() == 0:
			return
		manager.step(DT)


func _collect(shot: LuaShot) -> void:
	for h in shot._hosts:
		if h._state != null:
			h._state.collect_garbage()


func _reload_many(preference: String, template: String) -> void:
	var manager := _mgr(preference)
	var shot := _shot(manager)
	var hosts_before := ScriptHost._process_hosts.size()
	# 0.25 s shots, a reload every 0.1 s: most reloads start a new generation
	# while the previous ones are still in flight, and those drain later.
	var warm := 6
	for i in warm:
		_apply(shot, template % [i, "0.25"])
		_fire(manager, shot, 2)
		_steps(manager, 6)
	_collect(shot)
	var mem_before := shot.lua_memory()
	var released_before := shot.released_count
	var refused := 0
	var in_native := 0
	for i in RELOADS:
		var r := shot.apply(template % [warm + i, "0.25"])
		if not r.ok:
			assert_eq(r.error, LuaShot.SLOTS_BUSY_ERROR, r.error)
			refused += 1
		_fire(manager, shot, 2)
		if manager.native != null:
			in_native += manager.native.count_with_behavior(shot.behavior_id())
		_steps(manager, 6)
		assert_lte(shot.host_count(), LuaShot.MAX_GENERATIONS, "%s: reload %d" % [preference, i])
		assert_lte(shot.generation_count(), LuaShot.MAX_GENERATIONS)
	_collect(shot)
	var mem_after := shot.lua_memory()
	assert_lte(shot.lua_state_count(), LuaShot.MAX_GENERATIONS, preference)
	assert_lte(ScriptHost._process_hosts.size() - hosts_before, LuaShot.MAX_GENERATIONS, "no host per reload")
	assert_gt(shot.released_count - released_before, RELOADS / 2, "drained generations are released")
	assert_eq(refused, 0, "a slot always drains between reloads here")
	assert_eq(shot.in_place_with_live_shots, 0)
	if preference == "native" and template == BATCH:
		assert_gt(in_native, 0, "batch-only shots live in the native sim")
	# One sandbox state is about 100 KiB. A state per reload would add MiBs.
	assert_lt(mem_after - mem_before, 16 * 1024, "%s: Lua heap %d -> %d bytes over %d reloads" % [preference, mem_before, mem_after, RELOADS])
	gut.p("%s: %d reloads, Lua states %d, Lua heap %.1f -> %.1f KiB, released %d" % [preference, RELOADS, shot.lua_state_count(), mem_before / 1024.0, mem_after / 1024.0, shot.released_count - released_before])
	_drain_all(manager)
	assert_eq(shot.generation_count(), 1, "only the current generation is left once everything drained")


func test_fifty_reloads_keep_lua_states_and_memory_bounded() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_reload_many(pref, HOOKED)


func test_fifty_reloads_of_a_batch_weapon_stay_bounded() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_reload_many(pref, BATCH)


func test_a_drained_generation_is_released_and_its_host_reused() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, HOOKED % [1, "0.2"])
		var old_id := shot.behavior_id()
		var old_ref: WeakRef = weakref(shot.behavior())
		var old_host := shot.behavior().host
		_fire(manager, shot, 3)
		_steps(manager, 1)
		_apply(shot, HOOKED % [2, "5"])
		var new_id := shot.behavior_id()
		assert_ne(new_id, old_id, "shots in flight: a new generation, a new owner id")
		assert_eq(shot.generation_count(), 2)
		assert_eq(shot.released_count, 0)
		_fire(manager, shot)
		_steps(manager, 30)
		assert_eq(manager.hooked_count_for_owner(old_id), 0, pref)
		assert_eq(shot.released_count, 1, "%s: released on hooked_owner_drained" % pref)
		assert_eq(shot.generation_count(), 1)
		assert_true(old_ref.get_ref() == null, "%s: the old LuaBulletBehavior is freed" % pref)
		assert_false(manager._behaviors[old_id] is LuaBulletBehavior, "the manager holds an inert entry")
		assert_false(old_host.has_weapon(), "the slot's host dropped the old weapon table")
		assert_eq(shot.host_count(), 2)
		# The current generation still has a shot in flight, so the next reload
		# starts a new generation on the released slot's host.
		_apply(shot, HOOKED % [3, "5"])
		assert_eq(shot.host_count(), 2, "the released host is reused")
		assert_eq(shot.behavior().host, old_host)
		assert_ne(shot.behavior_id(), old_id, "a released id is never reused")
		assert_ne(shot.behavior_id(), new_id)


func test_shots_in_flight_keep_the_old_code() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var versions: Array[LuaBulletBehavior] = []
		for v: String in ["A", "B", "C"]:
			_apply(shot, "return { speed = 1, lifetime = 0.5, on_despawn = function(b, why) print('%s') end }" % v)
			versions.append(shot.behavior())
			_fire(manager, shot, 2)
			_steps(manager, 1)
		assert_eq(shot.generation_count(), 3, pref)
		var busy := shot.apply("return { speed = 1, lifetime = 0.5, on_despawn = function(b, why) print('D') end }")
		assert_false(busy.ok, "every slot has shots in flight")
		assert_eq(busy.error, LuaShot.SLOTS_BUSY_ERROR)
		assert_eq(shot.behavior(), versions[2], "the running version is kept")
		var problem := ScriptProblem.from_result(busy, "default.lua")
		assert_eq(problem.message, LuaShot.SLOTS_BUSY_ERROR, "one plain line for the editor")
		_drain_all(manager)
		for i in versions.size():
			var b := versions[i]
			assert_eq(b.dispatches("on_despawn"), 2, "%s: version %d" % [pref, i])
			assert_eq(b.last_result.output, PackedStringArray([["A", "B", "C"][i]]), "%s: shots finish on their own chunk" % pref)
		assert_eq(shot.in_place_with_live_shots, 0)
		assert_eq(shot.generation_count(), 1)
		_apply(shot, "return { speed = 1, lifetime = 0.5, on_despawn = function(b, why) print('D') end }")
		_fire(manager, shot)
		_drain_all(manager)
		assert_eq(shot.behavior().last_result.output, PackedStringArray(["D"]))


func test_drains_during_reload_emit_loop_and_after_release_are_safe() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, HOOKED % [1, "5"])
		var a_id := shot.behavior_id()
		_fire(manager, shot, 2)
		_steps(manager, 1)
		_apply(shot, HOOKED % [2, "5"])
		var b_id := shot.behavior_id()
		_fire(manager, shot, 2)
		_steps(manager, 1)
		# A listener that reloads from inside the drain emit loop, and a
		# drain for the current id: the current generation is never released.
		var reloads: Array[int] = []
		manager.hooked_owner_drained.connect(func(id: int) -> void:
			if id == a_id and reloads.is_empty():
				reloads.append(id)
				var r := shot.apply(HOOKED % [3, "5"])
				assert_true(r.ok, r.error)
		)
		manager.hooked_owner_drained.emit(b_id)
		assert_eq(shot.behavior_id(), b_id, "a drain for the running id is ignored")
		assert_eq(shot.released_count, 0, "an early drain with shots in flight releases nothing")
		# clear_bullets drains every owner: A and B are released (B is no
		# longer current once the listener reloaded), from inside the loop.
		manager.clear_bullets()
		assert_eq(reloads.size(), 1, pref)
		assert_eq(shot.generation_count(), 1, pref)
		assert_gte(shot.released_count, 1)
		var current := shot.behavior_id()
		assert_ne(current, a_id)
		# Late and repeated drains for released ids, and for unknown ids.
		var released := shot.released_count
		manager.hooked_owner_drained.emit(a_id)
		manager.hooked_owner_drained.emit(b_id)
		manager.hooked_owner_drained.emit(9999)
		manager.hooked_owner_drained.emit(0)
		assert_eq(shot.released_count, released, "drains for released slots do nothing")
		assert_eq(shot.behavior_id(), current)
		# A drain queued while apply() runs is handled when apply() returns.
		_fire(manager, shot)
		_steps(manager, 1)
		_apply(shot, HOOKED % [4, "5"])
		var old := current
		shot._applying = true
		shot._on_owner_drained(old)
		assert_eq(shot._drained_later, [old] as Array[int])
		shot._applying = false
		shot._flush_drained()
		assert_true(shot._drained_later.is_empty())
		_fire(manager, shot)
		_steps(manager, 2)
		assert_ne(shot.behavior_id(), 0)


func test_a_weapon_outliving_its_manager_does_not_crash() -> void:
	var manager := _mgr("gdscript")
	var shot := _shot(manager)
	_apply(shot, HOOKED % [1, "5"])
	_fire(manager, shot)
	_steps(manager, 1)
	_mgrs.clear()
	manager._behaviors.clear()
	manager.free()
	var r := shot.apply(HOOKED % [2, "5"])
	assert_false(r.ok)
	assert_eq(r.error, "no bullet manager")
	assert_eq(shot._live_shots(0), 0)
