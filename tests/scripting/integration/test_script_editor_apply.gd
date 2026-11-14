extends GutTest
## LuaShot hot reload and the starters, on the GDScript pool and (when the
## extension is built) the native sim: a bad apply keeps the last good
## version, shots in flight finish on the version they were fired with, and
## every starter compiles and runs a few ticks.

const DT := 1.0 / 60.0
const BACKENDS: Array[String] = ["gdscript", "native"]

var _mgrs: Array[BulletManager] = []
var _shots: Array[LuaShot] = []


func before_each() -> void:
	ScriptWarnings.reset()
	SenseBook.reset()
	WorldQuery.reset()


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	_shots.clear()
	SenseBook.reset()
	WorldQuery.reset()


func _skip(preference: String) -> bool:
	if preference == "native" and not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return true
	return false


func _mgr(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 512
	manager.logical_cap = 512
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


func test_settings_come_from_the_weapon_table() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "return { name = 'Slow', cooldown = 0.5, speed = 100, lifetime = 2, damage = 3, radius = 6 }")
		assert_eq(shot.title, "Slow")
		assert_almost_eq(shot.fire_interval, 0.5, 1e-6)
		assert_almost_eq(shot.speed, 100.0, 1e-6)
		_fire(manager, shot)
		assert_eq(manager.alive_count(), 1, pref)
		_apply(shot, "return { speed = 1e9, cooldown = -1, lifetime = 0/0 }")
		assert_eq(shot.speed, BulletLimits.MAX_SPEED, "speed is clamped")
		assert_almost_eq(shot.fire_interval, 0.03, 1e-6, "cooldown is clamped")
		assert_almost_eq(shot.bullet_lifetime, LuaShot.DEFAULT_LIFETIME, 1e-6, "NaN falls back to the default")


func test_a_bad_apply_keeps_the_last_good_script() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "return { name = 'Good', speed = 300, on_spawn = function(b) b:set_velocity(0, 50) end }")
		var good_id := shot.behavior_id()
		var good_source := shot.source
		var bads: Array[String] = [
			"return { name = 'Broken', on_spawn = function(b) b:set_velocity(1 2) end }",
			"error('nope')",
			"while true do end",
			"return 42",
		]
		for bad in bads:
			var r := shot.apply(bad)
			assert_false(r.ok, bad)
			assert_eq(shot.title, "Good", "%s: %s" % [pref, bad])
			assert_eq(shot.behavior_id(), good_id, bad)
			assert_eq(shot.source, good_source, bad)
			assert_almost_eq(shot.speed, 300.0, 1e-6, bad)
		_fire(manager, shot)
		_steps(manager, 2)
		assert_eq(shot.behavior().dispatches("on_spawn"), 1, "the good on_spawn still runs (%s)" % pref)
		assert_eq(manager.alive_count(), 1)


func test_shots_in_flight_finish_on_the_version_they_were_fired_with() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "return { name = 'A', speed = 10, lifetime = 5, on_hit = function(b, hit) end }")
		var old_behavior := shot.behavior()
		var old_id := shot.behavior_id()
		_fire(manager, shot, 3)
		_steps(manager, 1)
		assert_eq(shot.live_shots_of_current(), 3, pref)
		_apply(shot, "return { name = 'B', speed = 10, lifetime = 5, on_spawn = function(b) end }")
		assert_ne(shot.behavior_id(), old_id, "live hooked shots: the new code goes into another generation")
		assert_eq(shot.generation_count(), 2)
		assert_true(old_behavior.host.has_callback("on_hit"), "the old generation keeps its chunk")
		assert_false(old_behavior.host.has_callback("on_spawn"))
		_fire(manager, shot)
		_steps(manager, 1)
		assert_eq(shot.behavior().dispatches("on_spawn"), 1, "new shots use the new code")
		assert_eq(old_behavior.dispatches("on_spawn"), 0, "old shots never see the new callbacks")


func test_an_idle_version_is_reloaded_in_place_and_generations_are_capped() -> void:
	var manager := _mgr("gdscript")
	var shot := _shot(manager)
	_apply(shot, "return { name = 'A' }")
	var first := shot.behavior_id()
	_apply(shot, "return { name = 'B' }")
	assert_eq(shot.behavior_id(), first, "no live shots: reloaded in place")
	assert_eq(shot.generation_count(), 1)
	for i in LuaShot.MAX_GENERATIONS:
		_apply(shot, "return { name = 'G%d', lifetime = 9, speed = 1, on_hit = function() end }" % i)
		_fire(manager, shot)
		_steps(manager, 1)
	_apply(shot, "return { name = 'Fourth', lifetime = 9, speed = 1, on_hit = function() end }")
	assert_eq(shot.title, "Fourth", "a save is never refused")
	assert_eq(shot.evicted_count, 1, "the oldest busy generation was stripped")
	assert_lte(shot.generation_count(), LuaShot.MAX_GENERATIONS)
	assert_lte(shot.host_count(), LuaShot.MAX_GENERATIONS)
	assert_eq(shot.in_place_with_live_shots, 0, "shots in flight never switch to new code")


func test_a_failing_bullet_callback_is_skipped_until_the_next_load() -> void:
	var manager := _mgr("gdscript")
	var shot := _shot(manager)
	var code := "return {\n  lifetime = 5,\n  on_spawn = function(b)\n    local t = nil\n    t.x = 1\n  end,\n}"
	_apply(shot, code)
	_fire(manager, shot, 20)
	_steps(manager, 1)
	var b := shot.behavior()
	assert_eq(b.error_count("on_spawn"), 1, "one error, then on_spawn is skipped (api.md, slice §7.5)")
	assert_true(b.is_skipped("on_spawn"))
	assert_eq(ScriptWarnings.count("LuaBulletBehavior.error.on_spawn"), 1, "Lua ran once")
	var p := ScriptProblem.from_result(b.last_error("on_spawn"), shot.chunk_name, "on_spawn")
	assert_eq(p.headline(), "line 5: 't' is nil, so it has no fields. Is it defined? Still running the last good script.")
	assert_eq(manager.alive_count(), 20, "the shots keep flying")
	_apply(shot, code)
	assert_eq(shot.behavior().error_total, 0, "a clean load clears the counts")
	assert_false(shot.behavior().is_skipped("on_spawn"), "and runs the callback again")
	_fire(manager, shot)
	_steps(manager, 1)
	assert_eq(shot.behavior().error_count("on_spawn"), 1)


func test_on_fire_errors_are_counted_and_rate_limited() -> void:
	var manager := _mgr("gdscript")
	var shot := _shot(manager)
	_apply(shot, "return {\n  on_fire = function(ctx)\n    spawn { angle = ctx.aim }\n    error('jammed')\n  end,\n}")
	_fire(manager, shot, 20)
	var b := shot.behavior()
	assert_eq(b.error_count("on_fire"), 20, "on_fire is still called every pull")
	assert_lte(ScriptWarnings.printed_count("LuaBulletBehavior.error.on_fire"), ScriptWarnings.LIMIT, "the log is rate-limited")
	assert_eq(manager.alive_count(), 0, "a failed on_fire spawns nothing")
	var p := ScriptProblem.from_result(b.last_error("on_fire"), shot.chunk_name, "on_fire")
	p.count = b.error_count("on_fire")
	assert_eq(p.text(), "line 4: jammed.  ×20")


func test_on_fire_spawns_with_the_scripts_numbers() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var dummy := _target(manager, Vector2(100, 0))
		var shot := _shot(manager)
		_apply(shot, ScriptLibrary.starter("straight").source)
		assert_almost_eq(shot.fire_interval, 0.25, 1e-6)
		_fire(manager, shot)
		var vel: PackedVector2Array = manager.snapshot()["vel"]
		assert_eq(vel.size(), 1, pref)
		if vel.size() == 1:
			assert_almost_eq(vel[0].length(), 480.0, 0.01, "Straight fires 480 px/s (%s)" % pref)
		_steps(manager, 30)
		assert_eq(_damage[dummy], 1.0, "damage 1 (%s)" % pref)
		# The lesson-1 edit: a bigger damage number affects the next shot.
		_apply(shot, ScriptLibrary.starter("straight").source.replace("damage = 1", "damage = 4"))
		_fire(manager, shot)
		_steps(manager, 30)
		assert_eq(_damage[dummy], 5.0, "the next shot deals 4 (%s)" % pref)


func test_every_starter_compiles_and_runs_a_few_ticks() -> void:
	var starters := ScriptLibrary.starters()
	assert_eq(starters.size(), ScriptLibrary.STARTERS.size())
	for pref in BACKENDS:
		if _skip(pref):
			continue
		for s in starters:
			ScriptWarnings.reset()
			var manager := _mgr(pref)
			_target(manager, Vector2(120, 0))
			var shot := _shot(manager)
			_apply(shot, s.source)
			assert_eq(shot.title, s.title)
			assert_lte(s.source.strip_edges().split("\n").size(), 22, "%s stays short" % s.id)
			if s.id != "homing":
				assert_lte(s.source.strip_edges().split("\n").size(), 16, "%s: minute-1 starters are about 15 lines" % s.id)
			assert_true(s.source.contains("tweak me"), "%s has one obvious number to tweak" % s.id)
			for t in 30:
				if t % 6 == 0:
					_fire(manager, shot)
				manager.step(DT)
			var b := shot.behavior()
			assert_eq(b.error_total, 0, "%s on %s: %s" % [s.id, pref, _first_error(b)])
			assert_gt(manager.spawned_total(), 0, "%s fired" % s.id)
			assert_eq(ScriptWarnings.keys().size(), 0, "%s on %s warned: %s" % [s.id, pref, ScriptWarnings.keys()])


func test_spread_fires_five() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, ScriptLibrary.starter("spread").source)
		_fire(manager, shot)
		_steps(manager, 2)
		assert_eq(manager.alive_count(), 5, "spread: five shots in a fan (%s)" % pref)


## The spiral keeps its angle in `state.t`, so saving it again (or a tweak)
## carries on turning from where it was instead of snapping back to 0.
func test_the_spiral_angle_survives_a_save() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var src := ScriptLibrary.starter("spiral").source
		assert_string_contains(src, "state.t = state.t or 0")
		_apply(shot, src)
		_fire(manager, shot, 3)
		_apply(shot, src)
		manager.clear_bullets()
		_fire(manager, shot)
		_steps(manager, 1)
		var vel: PackedVector2Array = manager.snapshot()["vel"]
		assert_eq(vel.size(), 3, "three arms (%s)" % pref)
		for v in vel:
			# Every arm sits at state.t plus a multiple of TAU / 3.
			assert_almost_eq(fposmod(v.angle(), TAU / 3.0), 0.22 * 4, 0.001, "the fourth shot turns on from the third, not from 0 (%s)" % pref)


func test_split_pieces_spawn_at_the_hit_point_and_fly_back_out() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var dummy := _target(manager, Vector2(60, 0))
		var hit_at: Array[Vector2] = []
		dummy.hit.connect(func(_dmg: float, p: Vector2, _v: Vector2) -> void: hit_at.append(p))
		var split := _shot(manager)
		_apply(split, ScriptLibrary.starter("split_on_hit").source)
		_fire(manager, split)
		var ticks := 0
		while hit_at.is_empty() and ticks < 30:
			manager.step(DT)
			ticks += 1
		assert_eq(hit_at.size(), 1, "the shot hit (%s)" % pref)
		if hit_at.is_empty():
			continue
		# The tick that hit: the parent is gone and the pieces are born, not yet moved.
		var snap := manager.snapshot()
		var pos: PackedVector2Array = snap["pos"]
		var vel: PackedVector2Array = snap["vel"]
		assert_eq(pos.size(), 3, "three pieces (the tweak number) (%s)" % pref)
		for i in pos.size():
			assert_almost_eq(pos[i].distance_to(hit_at[0]), 0.0, 0.01, "piece %d spawns at the hit point (%s)" % [i, pref])
			assert_lt(vel[i].x, 0.0, "piece %d flies back the way the shot came (%s)" % [i, pref])
		for t in 20:
			manager.step(DT)
		assert_eq(split.behavior().dispatches("on_hit"), 1, pref)
		assert_eq(_hits[dummy], 1, "the pieces fly away and do not hit the target again (%s)" % pref)


## The real sense.nearest_enemy, earned, with only the enemies at `at` in
## the WorldQuery snapshot (none for an empty list).
func _sense_enemies(at: Array[Vector2]) -> void:
	WorldQuery.reset()
	SenseBook.grant(&"nearest_enemy", 1, true)
	for p in at:
		var b := Node2D.new()
		add_child_autofree(b)
		b.global_position = p
		WorldQuery.register_enemy(b, EnemyKinds.DUMMY, EnemyKinds.RARITY_NONE, 0, 22.0)
	WorldQuery.refresh()


## Fires one homing shot along +x from the origin, steps 20 ticks, and
## returns its velocity.
func _homing_velocity(pref: String) -> Vector2:
	var manager := _mgr(pref)
	var shot := _shot(manager)
	_apply(shot, ScriptLibrary.starter("homing").source)
	_fire(manager, shot)
	_steps(manager, 20)
	assert_eq(shot.behavior().error_total, 0, "%s: %s" % [pref, _first_error(shot.behavior())])
	return _only_velocity(manager)


func test_homing_is_locked_until_nearest_enemy() -> void:
	var homing := ScriptLibrary.starter("homing")
	assert_eq(homing.needs, PackedStringArray(["sense.nearest_enemy"]))
	assert_false(homing.unlocked())
	assert_lte(homing.source.strip_edges().split("\n").size(), 22)


func test_homing_flies_straight_while_the_sense_is_nil() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var vel := _homing_velocity(pref)
		assert_almost_eq(vel.y, 0.0, 1e-3, "locked: sense.nearest_enemy is nil, the shot flies straight (%s)" % pref)
		assert_almost_eq(vel.x, 280.0, 0.01, pref)


func test_homing_flies_straight_when_the_sense_finds_nothing() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_sense_enemies([])
		var none := _homing_velocity(pref)
		assert_almost_eq(none.y, 0.0, 1e-3, "nearest_enemy returns nil: straight (%s)" % pref)
		_sense_enemies([Vector2(100, 2000)])
		var far := _homing_velocity(pref)
		assert_almost_eq(far.y, 0.0, 1e-3, "an enemy past the starter's 400 px is not chased (%s)" % pref)


func test_homing_curves_toward_an_enemy_in_range() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		_sense_enemies([Vector2(120, 150)])
		var down := _homing_velocity(pref)
		assert_gt(down.y, 50.0, "turns toward an enemy below the line (%s)" % pref)
		_sense_enemies([Vector2(120, -150)])
		var up := _homing_velocity(pref)
		assert_lt(up.y, -50.0, "and toward one above it (%s)" % pref)


func _only_velocity(manager: BulletManager) -> Vector2:
	var vel: PackedVector2Array = manager.snapshot()["vel"]
	assert_eq(vel.size(), 1, "one shot in flight")
	return vel[0] if vel.size() > 0 else Vector2(INF, INF)


func _first_error(b: LuaBulletBehavior) -> String:
	for cb in b.failed_callbacks():
		return "%s: %s" % [cb, b.last_error(cb).error]
	return ""


var _hits: Dictionary[Hurtbox, int] = {}
var _damage: Dictionary[Hurtbox, float] = {}


func _target(manager: BulletManager, at: Vector2) -> Hurtbox:
	var d := Hurtbox.new()
	d.radius = 14.0
	d.layer = Layers.ENEMY
	d.position = at
	_hits[d] = 0
	_damage[d] = 0.0
	d.hit.connect(func(dmg: float, _p: Vector2, _v: Vector2) -> void:
		_hits[d] += 1
		_damage[d] += dmg
	)
	manager.add_child(d)
	return d
