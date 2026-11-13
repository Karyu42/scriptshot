extends GutTest
## LuaShot hot-reload generations on both backends: a generation whose last
## hooked shot is gone is released (BulletManager.release_behavior) and its
## host is reused, so 50 reloads keep the Lua state count and Lua heap
## bounded; shots in flight finish on the code they were fired with; with
## every slot busy a save still goes through and the oldest generation's shots
## fly on as plain bullets; a reused host starts from fresh globals; and a
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


func _reload_many(preference: String, template: String, life: String) -> void:
	var manager := _mgr(preference)
	var shot := _shot(manager)
	var hosts_before := ScriptHost._process_hosts.size()
	# A reload every 0.1 s with shots in flight. 0.25 s shots: old generations
	# drain and are released. 9 s shots: every slot stays busy and each reload
	# strips the oldest.
	var prefix := "G" if template == HOOKED else "B"
	var warm := 6
	for i in warm:
		_apply(shot, template % [i, life])
		_fire(manager, shot, 2)
		_steps(manager, 6)
	_collect(shot)
	var mem_before := shot.lua_memory()
	var released_before := shot.released_count
	var evicted_before := shot.evicted_count
	var in_native := 0
	for i in RELOADS:
		var r := shot.apply(template % [warm + i, life])
		assert_true(r.ok, "%s: reload %d: %s" % [preference, i, r.error])
		assert_eq(shot.title, "%s%d" % [prefix, warm + i], "the new version runs")
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
	assert_gt(shot.released_count - released_before, RELOADS / 2, "old generations are released")
	if life == "9":
		assert_gt(shot.evicted_count - evicted_before, RELOADS / 2, "busy slots are stripped")
	else:
		assert_eq(shot.evicted_count, evicted_before, "a slot always drains between reloads here")
	assert_eq(shot.in_place_with_live_shots, 0)
	if preference == "native" and template == BATCH:
		assert_gt(in_native, 0, "batch-only shots live in the native sim")
	# One sandbox state is about 100 KiB. A state per reload would add MiBs.
	assert_lt(mem_after - mem_before, 16 * 1024, "%s: Lua heap %d -> %d bytes over %d reloads" % [preference, mem_before, mem_after, RELOADS])
	gut.p("%s %s life %s: %d reloads, Lua states %d, hosts %d, Lua heap %.1f -> %.1f KiB, released %d, stripped %d" % [preference, prefix, life, RELOADS, shot.lua_state_count(), shot.host_count(), mem_before / 1024.0, mem_after / 1024.0, shot.released_count - released_before, shot.evicted_count - evicted_before])
	_drain_all(manager)
	assert_eq(shot.generation_count(), 1, "only the current generation is left once everything drained")


func test_fifty_reloads_keep_lua_states_and_memory_bounded() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_reload_many(pref, HOOKED, "0.25")


func test_fifty_busy_reloads_keep_lua_states_and_memory_bounded() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_reload_many(pref, HOOKED, "9")


func test_fifty_reloads_of_a_batch_weapon_stay_bounded() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_reload_many(pref, BATCH, "0.25")
		_reload_many(pref, BATCH, "9")


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
		_drain_all(manager)
		for i in versions.size():
			var b := versions[i]
			assert_eq(b.dispatches("on_despawn"), 2, "%s: version %d" % [pref, i])
			assert_eq(b.last_result.output, PackedStringArray([["A", "B", "C"][i]]), "%s: shots finish on their own chunk" % pref)
		assert_eq(shot.in_place_with_live_shots, 0)
		assert_eq(shot.generation_count(), 1)


class _Snap:
	extends RefCounted
	var id := 0
	var vel := Vector2.ZERO
	var damage := 0.0
	var lifetime := 0.0
	var radius := 0.0
	var color := Color()


func _snap_pool(manager: BulletManager, owner_id: int) -> Array[_Snap]:
	var out: Array[_Snap] = []
	var pool := manager.pool
	for i in pool.count:
		if pool.behavior[i] == owner_id and pool.dead_reason[i] == 0:
			var s := _Snap.new()
			s.id = pool.id_of(i)
			s.vel = pool.vel[i]
			s.damage = pool.damage[i]
			s.lifetime = pool.lifetime[i]
			s.radius = pool.radius[i]
			s.color = pool.color[i]
			out.append(s)
	return out


## With all three slots busy, a fourth save goes through. The oldest version's
## shots fly on as plain bullets: same speed, damage, lifetime and look, no
## hooks. Versions 2 and 3 still run their own code.
func test_a_fourth_save_with_every_slot_busy_strips_the_oldest() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var versions: Array[LuaBulletBehavior] = []
		var ids: Array[int] = []
		for v: String in ["A", "B", "C"]:
			_apply(shot, "return { speed = 30, damage = 3, radius = 6, lifetime = 9, on_hit = function(b, h) end, on_despawn = function(b, why) print('%s') end }" % v)
			versions.append(shot.behavior())
			ids.append(shot.behavior_id())
			_fire(manager, shot, 2)
			_steps(manager, 1)
		assert_eq(shot.generation_count(), 3, pref)
		var before := _snap_pool(manager, ids[0])
		assert_eq(before.size(), 2, "%s: version A has two shots in flight" % pref)
		var a_ref: WeakRef = weakref(versions[0])
		var a_host := versions[0].host
		var warnings := ScriptWarnings.revision
		var r := shot.apply("return { name = 'D', speed = 30, lifetime = 9, on_despawn = function(b, why) print('D') end }")
		assert_true(r.ok, "%s: a save is never refused: %s" % [pref, r.error])
		assert_eq(shot.title, "D")
		assert_eq(shot.evicted_count, 1)
		assert_eq(shot.released_count, 1, "%s: stripped once, released once" % pref)
		assert_eq(shot.host_count(), LuaShot.MAX_GENERATIONS)
		assert_eq(shot.behavior().host, a_host, "the stripped slot's host runs the new version")
		assert_eq(manager.hooked_count_for_owner(ids[0]), 0)
		assert_false(manager._behaviors[ids[0]] is LuaBulletBehavior, "the manager no longer holds version A")
		versions[0] = null
		assert_true(a_ref.get_ref() == null, "version A's behaviour is freed")
		assert_eq(ScriptWarnings.revision, warnings, "silent: no warning")
		for snap in before:
			var slot := manager.pool.slot_of(snap.id)
			assert_gte(slot, 0, "%s: A's shot keeps flying" % pref)
			if slot < 0:
				continue
			assert_eq(manager.pool.behavior[slot], 0, "plain bullet")
			assert_eq(manager.pool.vel[slot], snap.vel, "same speed")
			assert_eq(manager.pool.damage[slot], snap.damage, "same damage")
			assert_eq(manager.pool.lifetime[slot], snap.lifetime, "same lifetime")
			assert_eq(manager.pool.radius[slot], snap.radius, "same radius")
			assert_eq(manager.pool.color[slot], snap.color, "same colour")
		_fire(manager, shot)
		_drain_all(manager)
		assert_eq(manager.alive_count(), 0)
		assert_eq(versions[1].last_result.output, PackedStringArray(["B"]), "%s: B still runs its own code" % pref)
		assert_eq(versions[2].last_result.output, PackedStringArray(["C"]), "%s: C still runs its own code" % pref)
		assert_eq(versions[1].dispatches("on_despawn"), 2)
		assert_eq(versions[2].dispatches("on_despawn"), 2)
		assert_eq(shot.behavior().dispatches("on_despawn"), 1, "D's shot runs D's code")
		assert_eq(shot.behavior().last_result.output, PackedStringArray(["D"]))
		assert_eq(shot.in_place_with_live_shots, 0)


## Batch steering (on_batch) on the oldest version stops; its shots keep their
## velocity. On native these shots live in the sim and move to the pool.
func test_a_stripped_batch_version_stops_steering() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var ids: Array[int] = []
		var versions: Array[LuaBulletBehavior] = []
		for v in 3:
			_apply(shot, "return { speed = 30, lifetime = 9, on_batch = function(v, dt) for i = 0, v.n - 1 do v.vy[i] = v.vy[i] + 60 * dt end end }")
			ids.append(shot.behavior_id())
			versions.append(shot.behavior())
			_fire(manager, shot)
			_steps(manager, 2)
		var alive := manager.alive_count()
		assert_eq(alive, 3, pref)
		_apply(shot, "return { name = 'D', speed = 30, lifetime = 9, on_batch = function(v, dt) end }")
		assert_eq(shot.evicted_count, 1, pref)
		assert_eq(manager.hooked_count_for_owner(ids[0]), 0)
		assert_eq(manager.alive_count(), alive, "%s: no shot was dropped" % pref)
		var plain := _snap_pool(manager, 0)
		assert_eq(plain.size(), 1, "%s: A's shot is a plain pool bullet now" % pref)
		var b_calls := versions[1].dispatches("on_batch")
		_steps(manager, 10)
		if plain.size() == 1:
			var slot := manager.pool.slot_of(plain[0].id)
			assert_gte(slot, 0)
			if slot >= 0:
				assert_eq(manager.pool.vel[slot], plain[0].vel, "%s: no more steering" % pref)
		assert_gt(versions[1].dispatches("on_batch"), b_calls, "%s: B still steers" % pref)


func test_a_fourth_save_through_shot_scripts_fires_the_signals() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_clear_shots_dir()
		var manager := _mgr(pref)
		var scripts := ShotScripts.new()
		scripts.watch_files = false
		add_child_autofree(scripts)
		scripts.setup(manager, null)
		_shots.append(scripts.weapon)
		var saved: Array[String] = []
		var swapped: Array[String] = []
		var failed: Array[String] = []
		scripts.script_saved.connect(func(f: String, _o: StringName) -> void: saved.append(f))
		scripts.weapon_swapped.connect(func(f: String, _o: StringName) -> void: swapped.append(f))
		scripts.load_failed.connect(func(f: String, _p: ScriptProblem, _o: StringName) -> void: failed.append(f))
		for i in 4:
			saved.clear()
			swapped.clear()
			assert_true(scripts.save("default.lua", "return { name = 'V%d', speed = 30, lifetime = 9, on_hit = function(b, h) end }" % i))
			scripts.flush_pending()
			assert_eq(saved, ["default.lua"] as Array[String], "%s: save %d" % [pref, i])
			assert_eq(swapped, ["default.lua"] as Array[String], "%s: save %d" % [pref, i])
			assert_eq(scripts.weapon.title, "V%d" % i, "%s: the new code runs" % pref)
			scripts.weapon.fire(_ctx(), manager.emitter)
			_steps(manager, 1)
		assert_eq(failed, [] as Array[String])
		assert_null(scripts.problem)
		assert_eq(scripts.weapon.evicted_count, 1, pref)
		assert_eq(scripts.weapon.generation_count(), 3)
		_clear_shots_dir()


static func _clear_shots_dir() -> void:
	var dir := DirAccess.open(ScriptLibrary.root_dir())
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)


## A new version on a reused host does not see globals an older one set.
func test_a_reused_host_starts_from_fresh_globals() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "leftover = 41\nprint = nil\nreturn { speed = 1, lifetime = 0.2, on_hit = function(b, h) end }")
		var host := shot.behavior().host
		_fire(manager, shot)
		_steps(manager, 1)
		# Busy: B goes to a second slot, A drains and is released.
		_apply(shot, "return { speed = 1, lifetime = 9, on_hit = function(b, h) end }")
		_fire(manager, shot)
		_steps(manager, 30)
		assert_eq(shot.released_count, 1, pref)
		_apply(shot, "return { name = tostring(leftover) .. ',' .. type(print), speed = 1, lifetime = 9 }")
		assert_eq(shot.behavior().host, host, "%s: the released host is reused" % pref)
		assert_eq(shot.title, "nil,function", "%s: added globals are gone and replaced ones are back" % pref)
		# In-place reloads of an idle version keep globals (unchanged).
		var manager2 := _mgr(pref)
		var shot2 := _shot(manager2)
		_apply(shot2, "kept = 7\nreturn { speed = 1 }")
		_apply(shot2, "return { name = tostring(kept) }")
		assert_eq(shot2.title, "7")


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


## The drain that stripping emits arrives while apply() runs: it is queued,
## then ignored (the slot was already cleared), so nothing is released twice.
## A listener that reloads from inside that drain gets a plain error.
func test_a_strip_triggered_drain_does_not_double_release() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var ids: Array[int] = []
		for i in 3:
			_apply(shot, HOOKED % [i, "9"])
			ids.append(shot.behavior_id())
			_fire(manager, shot)
			_steps(manager, 1)
		var drained: Array[int] = []
		var nested: Array[String] = []
		manager.hooked_owner_drained.connect(func(id: int) -> void:
			drained.append(id)
			nested.append(shot.apply(HOOKED % [99, "9"]).error)
		)
		var r := shot.apply(HOOKED % [3, "9"])
		assert_true(r.ok, r.error)
		assert_has(drained, ids[0], "%s: stripping emitted the drain" % pref)
		for e in nested:
			assert_eq(e, LuaShot.NESTED_APPLY_ERROR)
		assert_eq(shot.released_count, 1, "%s: released once" % pref)
		assert_eq(shot.evicted_count, 1)
		assert_true(shot._drained_later.is_empty())
		assert_eq(shot.title, "G3")
		assert_eq(shot.generation_count(), 3)
		# Late drains for the stripped id do nothing.
		manager.hooked_owner_drained.emit(ids[0])
		assert_eq(shot.released_count, 1)
		_steps(manager, 2)


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
