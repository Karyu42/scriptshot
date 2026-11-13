extends GutTest
## WorldQuery: nearest_enemy / enemies_in_radius over a per-tick snapshot, the
## exclude round-trip, the registry (enemies add and remove themselves), the
## boss-state provider and the wall raycast. Plain data only (#50).

const WorldQueryScript := preload("res://src/core/world_query.gd")
const DT := 1.0 / 60.0

var wq: WorldQueryScript


func before_each() -> void:
	wq = WorldQueryScript.new()
	# Driven by hand: refresh() is the tick.
	wq.set_physics_process(false)
	add_child_autofree(wq)


func _body(at: Vector2) -> Node2D:
	var n := Node2D.new()
	n.position = at
	add_child_autofree(n)
	return n


func _health(hp: float, max_hp: float) -> Health:
	var h := Health.new()
	h.max_hp = max_hp
	h.hp = hp
	h.regen_enabled = false
	autofree(h)
	return h


func _add(at: Vector2, kind: StringName = EnemyKinds.DRIFTER) -> Node2D:
	var n := _body(at)
	wq.register_enemy(n, kind, EnemyKinds.RARITY_NONE, 0, 16.0)
	return n


func _id(d: Dictionary) -> int:
	var id: int = d.get("id", 0)
	return id


func _pos(d: Dictionary) -> Vector2:
	var p: Vector2 = d.get("pos", Vector2.INF)
	return p


func _v2(d: Dictionary, key: String) -> Vector2:
	var v: Vector2 = d[key]
	return v


func _f(d: Dictionary, key: String) -> float:
	var v: float = d[key]
	return v


func _i(d: Dictionary, key: String) -> int:
	var v: int = d[key]
	return v


func _sn(d: Dictionary, key: String) -> StringName:
	var v: StringName = d.get(key, &"")
	return v


func _b(d: Dictionary, key: String) -> bool:
	var v: bool = d[key]
	return v


func _type(d: Dictionary, key: String) -> int:
	return typeof(d[key])


# --- nearest_enemy -------------------------------------------------------------

func test_nearest_returns_empty_without_enemies() -> void:
	wq.refresh(DT)
	assert_eq(wq.nearest_enemy(Vector2.ZERO, 1000.0), {})


func test_nearest_picks_the_closest_within_range_with_the_full_shape() -> void:
	var near := _body(Vector2(100, 0))
	wq.register_enemy(near, EnemyKinds.DRIFTER, EnemyKinds.RARITY_COMMON, 2, 16.0, _health(30, 120))
	_add(Vector2(300, 0))
	wq.refresh(DT)
	var r := wq.nearest_enemy(Vector2.ZERO, 500.0)
	assert_eq(r.keys().size(), 9)
	assert_eq(_f(r, "radius"), 16.0)
	assert_eq(_id(r), near.get_instance_id())
	assert_eq(_type(r, "id"), TYPE_INT)
	assert_eq(_v2(r, "pos"), Vector2(100, 0))
	assert_eq(_v2(r, "vel"), Vector2.ZERO, "first snapshot has no velocity yet")
	assert_almost_eq(_f(r, "hp_frac"), 0.25, 0.0001)
	assert_eq(_sn(r, "kind"), EnemyKinds.DRIFTER)
	assert_eq(_type(r, "kind"), TYPE_STRING_NAME)
	assert_eq(_i(r, "rarity"), EnemyKinds.RARITY_COMMON)
	assert_eq(_i(r, "tier"), 2)
	assert_eq(_b(r, "is_boss"), false)


func test_nearest_respects_range_inclusively() -> void:
	_add(Vector2(200, 0))
	wq.refresh(DT)
	assert_eq(wq.nearest_enemy(Vector2.ZERO, 199.0), {})
	assert_false(wq.nearest_enemy(Vector2.ZERO, 200.0).is_empty())
	assert_eq(wq.nearest_enemy(Vector2.ZERO, -1.0), {})
	assert_eq(wq.nearest_enemy(Vector2.ZERO, NAN), {})
	assert_false(wq.nearest_enemy(Vector2.ZERO, INF).is_empty())


func test_exclude_round_trips_the_returned_ids_in_every_accepted_shape() -> void:
	var a := _add(Vector2(50, 0))
	var b := _add(Vector2(80, 0))
	var c := _add(Vector2(120, 0))
	wq.refresh(DT)
	var first := wq.nearest_enemy(Vector2.ZERO, 1000.0)
	assert_eq(_id(first), a.get_instance_id())
	# Feed the id back exactly as it came out.
	var as_packed := PackedInt64Array([_id(first)])
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0, as_packed)), b.get_instance_id())
	var as_array: Array = [first.get("id")]
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0, as_array)), b.get_instance_id())
	# A Lua number can arrive as a float; an integer-valued one still matches.
	var as_float: Array = [float(_id(first))]
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0, as_float)), b.get_instance_id())
	# Chaining: exclude everything found so far.
	var seen := PackedInt64Array()
	var order: Array[int] = []
	for _i in 4:
		var r := wq.nearest_enemy(Vector2.ZERO, 1000.0, seen)
		if r.is_empty():
			break
		seen.append(_id(r))
		order.append(_id(r))
	assert_eq(order, [a.get_instance_id(), b.get_instance_id(), c.get_instance_id()] as Array[int])
	# Garbage in exclude is ignored, not an error.
	var junk: Array = ["x", 1.5, null]
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0, junk)), a.get_instance_id())


func test_equal_distances_break_ties_by_lower_id() -> void:
	var a := _add(Vector2(100, 0))
	var b := _add(Vector2(-100, 0))
	wq.refresh(DT)
	var low := mini(a.get_instance_id(), b.get_instance_id())
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 500.0)), low)


# --- enemies_in_radius -----------------------------------------------------------

func test_radius_is_sorted_by_distance_and_filtered() -> void:
	var far := _add(Vector2(0, 90))
	var mid := _add(Vector2(-60, 0))
	var near := _add(Vector2(30, 0))
	_add(Vector2(500, 0))
	wq.refresh(DT)
	var got := wq.enemies_in_radius(Vector2.ZERO, 100.0, 10)
	var ids: Array[int] = []
	for d in got:
		ids.append(_id(d))
	assert_eq(ids, [near.get_instance_id(), mid.get_instance_id(), far.get_instance_id()] as Array[int])
	assert_eq(got[0].size(), 9, "same shape as nearest_enemy")


func test_radius_cap_is_clamped_to_1_through_256() -> void:
	for i in 300:
		_add(Vector2(float(i), 0))
	wq.refresh(DT)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, 5).size(), 5)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, 0).size(), 1)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, -3).size(), 1)
	assert_eq(WorldQueryScript.MAX_RESULTS, 256)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, 1000).size(), 256)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, 256).size(), 256)
	var capped := wq.enemies_in_radius(Vector2.ZERO, 1000.0, 3)
	assert_eq(_pos(capped[0]), Vector2(0, 0))
	assert_eq(_pos(capped[2]), Vector2(2, 0), "the cap keeps the nearest ones")
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, -1.0, 5).size(), 0)


# --- snapshot ----------------------------------------------------------------------

func test_snapshot_stays_consistent_until_the_next_refresh() -> void:
	var a := _add(Vector2(100, 0))
	wq.refresh(DT)
	a.position = Vector2(400, 0)
	assert_eq(_pos(wq.nearest_enemy(Vector2.ZERO, 1000.0)), Vector2(100, 0), "moved after the snapshot")
	# A body added mid-tick is not in this tick's answers.
	_add(Vector2(10, 0))
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, 64).size(), 1)
	# A body that dies (unregisters) after the snapshot is skipped at once:
	# answers are living candidates only.
	wq.unregister_enemy(a)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, 1000.0, 64).size(), 0)
	assert_eq(wq.nearest_enemy(Vector2.ZERO, 1000.0), {})
	wq.refresh(DT)
	var after := wq.enemies_in_radius(Vector2.ZERO, 1000.0, 64)
	assert_eq(after.size(), 1)
	assert_eq(_pos(after[0]), Vector2(10, 0))


func test_velocity_is_estimated_from_consecutive_snapshots() -> void:
	var a := _add(Vector2(100, 0))
	wq.refresh(DT)
	a.position = Vector2(103, -1.5)
	wq.refresh(DT)
	var r := wq.nearest_enemy(Vector2.ZERO, 1000.0)
	var v := _v2(r, "vel")
	assert_almost_eq(v.x, 180.0, 0.01)
	assert_almost_eq(v.y, -90.0, 0.01)


func test_results_are_plain_data_and_outlive_the_body() -> void:
	var a := _add(Vector2(100, 0))
	wq.refresh(DT)
	var r := wq.nearest_enemy(Vector2.ZERO, 1000.0)
	for key: String in r:
		assert_ne(_type(r, key), TYPE_OBJECT, "no Object in the result (%s)" % key)
	a.free()
	assert_eq(_pos(r), Vector2(100, 0), "the dictionary is a copy")
	wq.refresh(DT)
	assert_eq(wq.nearest_enemy(Vector2.ZERO, 1000.0), {}, "a freed body drops out on the next snapshot")
	assert_eq(wq.registered_count(), 0)


func test_the_autoload_snapshots_between_enemies_and_bullets() -> void:
	assert_gt(WorldQueryScript.PHYSICS_PRIORITY, 0)
	assert_lt(WorldQueryScript.PHYSICS_PRIORITY, BulletManager.PHYSICS_PRIORITY)
	assert_eq(WorldQuery.process_physics_priority, WorldQueryScript.PHYSICS_PRIORITY)
	var before := WorldQuery.snapshot_count()
	await wait_physics_frames(2)
	assert_gt(WorldQuery.snapshot_count(), before, "refreshes on its own every physics tick")


# --- registry with real enemies ------------------------------------------------------

func _regular(archetype: StringName, at: Vector2) -> RegularEnemy:
	var body := (load("res://scenes/regular_enemy.tscn") as PackedScene).instantiate() as RegularEnemy
	body.configure(archetype, at, at, 1, WorldGen.chunk_of(at), 0, 0, null)
	return body


func test_enemies_register_on_ready_and_unregister_on_free() -> void:
	var body := _regular(RegularEnemy.ARCH_SWARMER, Vector2(900, 0))
	assert_false(WorldQuery.is_registered(body))
	add_child(body)
	assert_true(WorldQuery.is_registered(body))
	WorldQuery.refresh(DT)
	var found := false
	for d in WorldQuery.enemies_in_radius(Vector2(900, 0), 1.0, 64):
		if _id(d) == body.get_instance_id():
			found = true
			assert_eq(_sn(d, "kind"), EnemyKinds.SWARMER)
			assert_eq(_f(d, "radius"), RegularEnemy.SWARMER_RADIUS)
			assert_eq(_i(d, "rarity"), EnemyKinds.RARITY_NONE)
			assert_eq(_i(d, "tier"), 0)
			assert_almost_eq(_f(d, "hp_frac"), 1.0, 0.0001)
	assert_true(found)
	var id := body.get_instance_id()
	body.free()
	assert_false(WorldQuery.has_id(id))


func test_a_dead_enemy_unregisters_at_once() -> void:
	var body := _regular(RegularEnemy.ARCH_DRIFTER, Vector2(900, 0))
	add_child_autoqfree(body)
	body.health.damage(body.health.max_hp * 0.5)
	WorldQuery.refresh(DT)
	var hp_seen := -1.0
	for d in WorldQuery.enemies_in_radius(Vector2(900, 0), 1.0, 64):
		if _id(d) == body.get_instance_id():
			hp_seen = _f(d, "hp_frac")
	assert_almost_eq(hp_seen, 0.5, 0.0001)
	body.health.damage(body.health.max_hp)
	assert_false(WorldQuery.is_registered(body), "gone before queue_free runs")


func test_elites_register_their_kind_and_rarity() -> void:
	var at := Vector2(1200, 0)
	var elite := (load("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.configure_elite(AffixCatalog.SUMMONER, at, at, 1, null, false, false, WorldGen.chunk_of(at), 0)
	elite.rarity = EnemyKinds.RARITY_RARE
	add_child_autofree(elite)
	WorldQuery.refresh(DT)
	var hit := {}
	for d in WorldQuery.enemies_in_radius(at, 1.0, 64):
		if _id(d) == elite.get_instance_id():
			hit = d
	assert_eq(_sn(hit, "kind"), EnemyKinds.DRIFTER, "an elite is a drifter body")
	assert_eq(_f(hit, "radius"), elite.body_radius)
	assert_eq(_i(hit, "rarity"), EnemyKinds.RARITY_RARE)


# --- boss_state ------------------------------------------------------------------------

func test_a_freed_body_is_skipped_before_the_next_snapshot() -> void:
	var a := _add(Vector2(50, 0))
	var b := _add(Vector2(80, 0))
	wq.refresh(DT)
	a.free()
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0)), b.get_instance_id())
	var got := wq.enemies_in_radius(Vector2.ZERO, 1000.0, 64)
	assert_eq(got.size(), 1)
	assert_eq(_pos(got[0]), Vector2(80, 0), "positions of the rest stay frozen")


func test_a_real_enemy_killed_after_the_snapshot_is_not_returned() -> void:
	var body := _regular(RegularEnemy.ARCH_DRIFTER, Vector2(900, 0))
	add_child_autoqfree(body)
	WorldQuery.refresh(DT)
	var me := body.get_instance_id()
	assert_true(_has_id(WorldQuery.enemies_in_radius(Vector2(900, 0), 1.0, 256), me),
		"alive in the snapshot before it dies")
	body.health.damage(1000.0)
	assert_false(_has_id(WorldQuery.enemies_in_radius(Vector2(900, 0), 1.0, 256), me),
		"the dead body is gone from this tick's answers")


func test_nearest_falls_back_when_the_winners_died_after_the_snapshot() -> void:
	var a := _add(Vector2(10, 0))
	var b := _add(Vector2(20, 0))
	var c := _add(Vector2(30, 0))
	var d := _add(Vector2(40, 0))
	wq.refresh(DT)
	wq.unregister_enemy(a)
	b.free()
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0)), c.get_instance_id(), "next best alive")
	var skip_c := PackedInt64Array([c.get_instance_id()])
	assert_eq(_id(wq.nearest_enemy(Vector2.ZERO, 1000.0, skip_c)), d.get_instance_id())
	wq.unregister_enemy(c)
	wq.unregister_enemy(d)
	assert_true(wq.nearest_enemy(Vector2.ZERO, 1000.0).is_empty(), "all dead: none")


func test_radius_backfills_dead_rows_and_keeps_the_cap() -> void:
	var bodies: Array[Node2D] = []
	for i in 6:
		bodies.append(_add(Vector2(10 * (i + 1), 0)))
	wq.refresh(DT)
	wq.unregister_enemy(bodies[0])
	bodies[2].free()
	var got := wq.enemies_in_radius(Vector2.ZERO, 1000.0, 3)
	assert_eq(got.size(), 3, "cap still filled from the remaining candidates")
	var want: Array[int] = [bodies[1].get_instance_id(), bodies[3].get_instance_id(), bodies[4].get_instance_id()]
	var ids: Array[int] = []
	for e: Dictionary in got:
		ids.append(_id(e))
	assert_eq(ids, want, "nearest first, dead rows skipped")


func test_query_timing_at_256_and_1000_bodies() -> void:
	# Printed micro-bench (SE re-review #76): liveness is checked on the winner
	# only, so a call costs about one pass over the snapshot. Loose bound only.
	for n: int in [256, 1000]:
		wq.reset()
		var holder := Node2D.new()
		add_child_autofree(holder)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in n:
			var body := Node2D.new()
			body.position = Vector2(rng.randf_range(-500, 500), rng.randf_range(-500, 500))
			holder.add_child(body)
			wq.register_enemy(body, EnemyKinds.DRIFTER, EnemyKinds.RARITY_NONE, 0, 10.0)
		wq.refresh(DT)
		var reps := 200
		var t0 := Time.get_ticks_usec()
		for k in reps:
			wq.nearest_enemy(Vector2(k % 50, 0), 10000.0)
		var t1 := Time.get_ticks_usec()
		for k in reps:
			wq.enemies_in_radius(Vector2(k % 50, 0), 10000.0, 16)
		var t2 := Time.get_ticks_usec()
		var near_us := float(t1 - t0) / reps
		var radius_us := float(t2 - t1) / reps
		gut.p("WorldQuery %d bodies: nearest_enemy %.1f us, enemies_in_radius(cap 16) %.1f us" % [n, near_us, radius_us])
		assert_lt(near_us, 5000.0, "nearest_enemy stays a single cheap pass")
		holder.free()


func _has_id(rows: Array[Dictionary], id: int) -> bool:
	for d: Dictionary in rows:
		if _id(d) == id:
			return true
	return false


func test_boss_weak_points_are_rebuilt_as_plain_data() -> void:
	var boss := _body(Vector2(0, -300))
	var node := Node2D.new()
	autofree(node)
	var provider := func() -> Dictionary:
		return {
			"phase": 1.0,
			"phase_count": 0,
			"node": node,
			"weak_points": [
				{"pos": Vector2(5, -300), "radius": 12, "open": false, "node": node},
				{"pos": Vector2(-5, -300)},
				node,
				{"pos": "not a vector"},
				{"pos": Vector2(INF, 0)},
			],
		}
	wq.register_enemy(boss, EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, 40.0, null, true, provider)
	wq.refresh(DT)
	var s := wq.boss_state()
	assert_false(s.has("node"), "only the documented keys")
	assert_eq(s.size(), 7)
	assert_eq(_type(s, "phase"), TYPE_INT)
	assert_eq(_i(s, "phase"), 1)
	assert_eq(_i(s, "phase_count"), 1, "clamped to at least 1")
	var weak: Array = s["weak_points"]
	assert_eq(weak.size(), 2)
	var first: Dictionary = weak[0]
	var second: Dictionary = weak[1]
	assert_eq(first, {"pos": Vector2(5, -300), "radius": 12.0, "open": false})
	assert_eq(second, {"pos": Vector2(-5, -300), "radius": 0.0, "open": true})
	for item: Variant in weak:
		var d: Dictionary = item
		for key: String in d:
			assert_ne(_type(d, key), TYPE_OBJECT)


func test_a_boss_that_died_after_the_snapshot_has_no_state() -> void:
	var boss := _body(Vector2(0, 0))
	wq.register_enemy(boss, EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, 40.0, null, true)
	wq.refresh(DT)
	assert_false(wq.boss_state().is_empty())
	wq.unregister_enemy(boss)
	assert_eq(wq.boss_state(), {})


func test_sandbox_turrets_and_mirrors_are_not_enemies() -> void:
	for path: String in ["res://scenes/turret.tscn", "res://scenes/mirror.tscn"]:
		var body := (load(path) as PackedScene).instantiate() as TrainingDummy
		add_child_autofree(body)
		assert_false(body.reports_as_enemy())
		assert_false(WorldQuery.is_registered(body), path)


func test_boss_state_is_empty_without_a_boss() -> void:
	_add(Vector2(10, 0))
	wq.refresh(DT)
	assert_eq(wq.boss_state(), {})


func test_a_boss_registers_with_a_state_provider() -> void:
	var boss := _body(Vector2(0, -300))
	var provider := func() -> Dictionary:
		return {"phase": 2, "phase_count": 3, "weak_points": [{"pos": Vector2(10, -300), "hp_frac": 0.5}]}
	wq.register_enemy(boss, EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, 40.0, _health(50, 200), true, provider)
	wq.refresh(DT)
	var s := wq.boss_state()
	assert_eq(_i(s, "id"), boss.get_instance_id())
	assert_eq(_sn(s, "kind"), &"warden")
	assert_eq(_i(s, "phase"), 2)
	assert_eq(_i(s, "phase_count"), 3)
	assert_almost_eq(_f(s, "hp_frac"), 0.25, 0.0001)
	assert_eq(_v2(s, "pos"), Vector2(0, -300))
	var weak: Array = s["weak_points"]
	assert_eq(weak.size(), 1)
	assert_true(_b(wq.nearest_enemy(Vector2(0, -300), 1.0), "is_boss"))


func test_a_boss_without_a_provider_reads_phase_0_of_1() -> void:
	var boss := _body(Vector2(0, 0))
	wq.register_enemy(boss, EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, 40.0, null, true)
	wq.refresh(DT)
	var s := wq.boss_state()
	assert_eq(_i(s, "phase"), 0)
	assert_eq(_i(s, "phase_count"), 1)
	var none: Array = s["weak_points"]
	assert_eq(none.size(), 0)
	assert_eq(_f(s, "hp_frac"), 1.0)


# --- raycast_terrain ---------------------------------------------------------------------

func test_a_bound_manager_window_is_the_range_limit() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 16
	manager.render_enabled = false
	manager.auto_step = false
	manager.world_bounds = Rect2(-500, -500, 1000, 1000)
	add_child_autofree(manager)
	var inside := _add(Vector2(400, 0))
	_add(Vector2(900, 0))
	wq.refresh(DT)
	assert_eq(wq.enemies_in_radius(Vector2.ZERO, INF, 256).size(), 2, "unbound: every registered body")
	wq.bind_bullets(manager)
	wq.refresh(DT)
	var got := wq.enemies_in_radius(Vector2.ZERO, INF, 256)
	assert_eq(got.size(), 1)
	assert_eq(_id(got[0]), inside.get_instance_id())
	assert_eq(_id(wq.nearest_enemy(Vector2(800, 0), INF)), inside.get_instance_id())


func test_a_body_without_health_reports_set_hp_frac() -> void:
	var n := _add(Vector2(10, 0))
	wq.refresh(DT)
	assert_eq(_f(wq.nearest_enemy(Vector2.ZERO, 100.0), "hp_frac"), 1.0)
	wq.set_hp_frac(n, 0.25)
	wq.refresh(DT)
	assert_eq(_f(wq.nearest_enemy(Vector2.ZERO, 100.0), "hp_frac"), 0.25)


func test_training_dummies_register_and_leave_while_down() -> void:
	var dummy := (load("res://scenes/training_dummy.tscn") as PackedScene).instantiate() as TrainingDummy
	dummy.position = Vector2(300, 0)
	add_child_autofree(dummy)
	assert_true(WorldQuery.is_registered(dummy))
	(dummy.get_node("Hurtbox") as Hurtbox).receive_hit(10.0, Vector2.ZERO, Vector2.ZERO)
	WorldQuery.refresh(DT)
	var hit := {}
	for d in WorldQuery.enemies_in_radius(Vector2(300, 0), 1.0, 256):
		if _id(d) == dummy.get_instance_id():
			hit = d
	assert_eq(_sn(hit, "kind"), EnemyKinds.DUMMY)
	assert_almost_eq(_f(hit, "hp_frac"), 0.75, 0.0001)
	assert_eq(_f(hit, "radius"), dummy.body_radius)
	(dummy.get_node("Hurtbox") as Hurtbox).receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
	assert_false(WorldQuery.is_registered(dummy), "a downed dummy is not a target")
	dummy._process(dummy.respawn_delay + 0.01)
	assert_true(WorldQuery.is_registered(dummy), "back after it respawns")


func test_raycast_hits_the_first_wall_with_its_normal() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 16
	manager.render_enabled = false
	manager.auto_step = false
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	add_child_autofree(manager)
	manager.add_wall(Rect2(200, -50, 40, 100))
	manager.add_wall(Rect2(400, -50, 40, 100))
	assert_eq(wq.raycast_terrain(Vector2.ZERO, Vector2(500, 0)), {}, "nothing bound yet")
	wq.bind_bullets(manager)
	var hit := wq.raycast_terrain(Vector2.ZERO, Vector2(500, 0))
	assert_eq(hit.keys().size(), 3)
	assert_almost_eq(_v2(hit, "pos").x, 200.0, 0.01)
	assert_eq(_v2(hit, "normal"), Vector2.LEFT)
	assert_almost_eq(_f(hit, "distance"), 200.0, 0.01)
	assert_eq(wq.raycast_terrain(Vector2(0, 100), Vector2(500, 100)), {}, "a clear path")
	wq.unbind_bullets(null)
	assert_false(wq.raycast_terrain(Vector2.ZERO, Vector2(500, 0)).is_empty(), "only the bound manager unbinds")
	wq.unbind_bullets(manager)
	assert_eq(wq.raycast_terrain(Vector2.ZERO, Vector2(500, 0)), {})


# --- revision / live_rows (the Lua Senses mirror) --------------------------------

func test_revision_moves_on_refresh_unregister_and_reset_only() -> void:
	var a := _add(Vector2(10, 0))
	var r0 := wq.revision()
	wq.refresh(DT)
	var r1 := wq.revision()
	assert_gt(r1, r0)
	wq.nearest_enemy(Vector2.ZERO, 600.0)
	wq.enemies_in_radius(Vector2.ZERO, 600.0, 8)
	assert_eq(wq.revision(), r1, "queries do not move it")
	wq.unregister_enemy(a)
	var r2 := wq.revision()
	assert_gt(r2, r1, "a death after the snapshot moves it")
	wq.reset()
	assert_gt(wq.revision(), r2)


func test_live_rows_are_the_rows_queries_can_return() -> void:
	var a := _add(Vector2(10, 20), EnemyKinds.HUSK)
	var b := _add(Vector2(-30, 5), EnemyKinds.WARDEN)
	wq.refresh(DT)
	var rows := wq.live_rows()
	var ids: PackedInt64Array = rows["ids"]
	var kinds: PackedStringArray = rows["kind"]
	var xs: PackedFloat64Array = rows["x"]
	var radii: PackedFloat64Array = rows["radius"]
	assert_eq(ids.size(), 2)
	var ia := ids.find(a.get_instance_id())
	assert_gte(ia, 0)
	assert_eq(kinds[ia], "husk")
	assert_eq(xs[ia], 10.0)
	assert_eq(radii[ia], 16.0)
	var rarities: PackedInt32Array = rows["rarity"]
	assert_eq(rarities[ia], EnemyKinds.RARITY_NONE)
	assert_eq(wq.live_rows(), rows, "same rows until the revision moves")
	a.position = Vector2(500, 500)
	wq.unregister_enemy(a)
	var after := wq.live_rows()
	var after_ids: PackedInt64Array = after["ids"]
	assert_eq(after_ids, PackedInt64Array([b.get_instance_id()]), "the dead body is gone, the snapshot is not rebuilt")
	var bx: PackedFloat64Array = after["x"]
	assert_eq(bx[0], -30.0)


func test_live_rows_carries_the_rarity_column() -> void:
	var n := _body(Vector2(40, 0))
	wq.register_enemy(n, EnemyKinds.DRIFTER, EnemyKinds.RARITY_LEGENDARY, 0, 16.0)
	wq.refresh(DT)
	var rarities: PackedInt32Array = wq.live_rows()["rarity"]
	assert_eq(rarities, PackedInt32Array([EnemyKinds.RARITY_LEGENDARY]))


func test_writing_into_live_rows_does_not_reach_the_next_caller() -> void:
	var a := _add(Vector2(10, 20))
	wq.refresh(DT)
	var rows := wq.live_rows()
	# A careless caller: replace a column, add a key, write into a column.
	rows["x"] = PackedFloat64Array([999.0])
	rows["extra"] = true
	rows.erase("kind")
	var ids: PackedInt64Array = rows["ids"]
	ids[0] = 7
	var next := wq.live_rows()
	assert_false(next.has("extra"))
	assert_true(next.has("kind"))
	var xs: PackedFloat64Array = next["x"]
	assert_eq(xs, PackedFloat64Array([10.0]))
	var next_ids: PackedInt64Array = next["ids"]
	assert_eq(next_ids, PackedInt64Array([a.get_instance_id()]), "a write into a column does not reach the cache")
