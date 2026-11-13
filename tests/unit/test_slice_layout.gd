extends GutTest
## Vertical-slice ribbon (vertical-slice.md §2, §10 row 1): room rects, walls,
## gates as removable wall segments, the debug force-open flag, bullets on the
## same walls, and the headless walk from the origin to the arena centre.

const DT := 1.0 / 60.0
## Walk step. Well under the 4 px gate plus the player's 13 px radius.
const STEP := 6.0

var layout: SliceLayout
var walker: Player


func before_each() -> void:
	layout = SliceLayout.new()
	add_child_autofree(layout)
	walker = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	walker.set_physics_process(false)
	add_child_autofree(walker)
	# Let the bodies enter the physics space.
	await wait_physics_frames(2)


## Moves the walker in a straight line from `from` toward `to` with
## move_and_collide and returns where it stopped (at `to` when nothing blocked).
func _walk(from: Vector2, to: Vector2) -> Vector2:
	walker.global_position = from
	var guard := 0
	while walker.global_position.distance_to(to) > 0.01 and guard < 10000:
		guard += 1
		var left := to - walker.global_position
		var col := walker.move_and_collide(left.limit_length(STEP))
		if col != null:
			return walker.global_position
	return walker.global_position


func _reaches(from: Vector2, to: Vector2) -> bool:
	return _walk(from, to).distance_to(to) < 0.5


# --- geometry -------------------------------------------------------------------

func test_room_rects_match_the_spec() -> void:
	assert_eq(SliceLayout.room_rect(&"S"), Rect2(-768, -576, 1536, 1152))
	assert_eq(SliceLayout.room_rect(&"A"), Rect2(1024, -512, 1280, 1024))
	assert_eq(SliceLayout.room_rect(&"B"), Rect2(2560, -512, 1280, 1024))
	assert_eq(SliceLayout.room_rect(&"C"), Rect2(4096, -1024, 2560, 2048))
	assert_eq(SliceLayout.room_rect(&"D"), Rect2(6912, -640, 1536, 1280))
	assert_eq(SliceLayout.room_rect(&"E"), Rect2(8704, -704, 1920, 1408), "arena option A")
	assert_eq(SliceLayout.room_rect(&"E").get_center(), Vector2(9664, 0))
	assert_eq(SliceLayout.room_rect(&"alcove"), Rect2(7104, 640, 1024, 1024))
	assert_eq(SliceLayout.room_rect(&"nope"), Rect2())
	for id: StringName in [&"G1", &"G2", &"G3", &"G4", &"G5"]:
		assert_eq(SliceLayout.corridor_rect(id).size, Vector2(256, 128), String(id))
	assert_eq(SliceLayout.corridor_rect(&"G1"), Rect2(768, -64, 256, 128))
	assert_eq(SliceLayout.corridor_rect(&"G0"), Rect2(), "G0 has no corridor")


func test_room_at_and_the_footprint() -> void:
	assert_eq(SliceLayout.room_at(Vector2.ZERO), &"S")
	assert_eq(SliceLayout.room_at(Vector2(1664, 0)), &"A")
	assert_eq(SliceLayout.room_at(Vector2(896, 0)), &"G1")
	assert_eq(SliceLayout.room_at(Vector2(4700, 180)), &"C")
	assert_eq(SliceLayout.room_at(Vector2(7616, 1152)), &"alcove")
	assert_eq(SliceLayout.room_at(Vector2(9664, 0)), &"E")
	assert_eq(SliceLayout.room_at(Vector2(896, 300)), &"", "between rooms")
	var union := SliceLayout.room_rect(&"S")
	for id in SliceLayout.ROOM_IDS:
		union = union.merge(SliceLayout.room_rect(id))
	assert_eq(union, SliceLayout.FOOTPRINT, "the footprint is the rooms' bounding box")
	assert_true(SliceLayout.in_footprint(Vector2(-768, -1024)), "left/top edge is inside")
	assert_false(SliceLayout.in_footprint(Vector2(-768.5, 0)))
	assert_false(SliceLayout.in_footprint(Vector2(0, 1664)), "bottom edge is outside")


func test_walls_stay_in_the_footprint_and_outside_the_safe_disk() -> void:
	var walls := SliceLayout.wall_rects()
	assert_gt(walls.size(), 20)
	for r in walls:
		assert_true(r.has_area(), str(r))
		assert_true(SliceLayout.FOOTPRINT.encloses(r), "%s inside the footprint" % r)
		var nearest := Vector2(clampf(0.0, r.position.x, r.end.x), clampf(0.0, r.position.y, r.end.y))
		assert_gt(nearest.length(), WorldGen.SAFE_RADIUS, "%s outside the 512 px disk" % r)
	for id in SliceLayout.GATE_IDS:
		var g := SliceLayout.gate_rect(id)
		assert_true(SliceLayout.FOOTPRINT.encloses(g), String(id))
		for r in walls:
			assert_false(r.intersects(g), "gate %s is not under a fixed wall %s" % [id, r])
	assert_eq(SliceLayout.gate_rect(&"G1"), Rect2(894, -64, 4, 128), "4 px across the corridor middle")
	assert_eq(SliceLayout.gate_rect(&"G0"), Rect2(5200, -1024, 256, SliceLayout.WALL_PX))


func test_the_scene_builds_one_body_per_gate_on_the_world_layer() -> void:
	var walls := get_tree().get_nodes_in_group(&"world_walls")
	assert_eq(walls.size(), 1 + SliceLayout.GATE_IDS.size())
	for id in SliceLayout.GATE_IDS:
		var body := layout.gate_body(id)
		assert_not_null(body)
		assert_eq(body.collision_layer, Layers.WORLD)
		assert_false(layout.is_gate_open(id), "%s starts shut" % id)


# --- gates ------------------------------------------------------------------------

func test_gate_flags_drive_the_bodies_and_signals() -> void:
	watch_signals(layout)
	layout.open_gate(&"G2")
	assert_true(layout.is_gate_open(&"G2"))
	assert_eq(layout.gate_body(&"G2").collision_layer, 0)
	assert_false(layout.gate_body(&"G2").is_in_group(&"world_walls"))
	assert_signal_emitted_with_parameters(layout, "gate_changed", [&"G2", true])
	assert_signal_emitted_with_parameters(layout, "gate_opened", [&"G2"])
	layout.open_gate(&"G2")
	assert_signal_emit_count(layout, "gate_changed", 1, "no change, no signal")
	layout.close_gate(&"G2")
	assert_false(layout.is_gate_open(&"G2"))
	assert_eq(layout.gate_body(&"G2").collision_layer, Layers.WORLD)
	assert_true(layout.gate_body(&"G2").is_in_group(&"world_walls"))
	assert_signal_emitted_with_parameters(layout, "gate_closed", [&"G2"])
	assert_signal_emit_count(layout, "gate_changed", 2)


func test_force_gates_open_overrides_and_keeps_the_flags() -> void:
	layout.open_gate(&"G1")
	watch_signals(layout)
	layout.force_gates_open = true
	for id in SliceLayout.GATE_IDS:
		assert_true(layout.is_gate_open(id), String(id))
	assert_signal_emit_count(layout, "gate_opened", SliceLayout.GATE_IDS.size() - 1, "G1 was already open")
	layout.close_gate(&"G1")
	assert_true(layout.is_gate_open(&"G1"), "still forced")
	layout.open_gate(&"G1")
	layout.force_gates_open = false
	assert_true(layout.is_gate_open(&"G1"), "its own flag")
	assert_false(layout.is_gate_open(&"G3"))
	assert_true(layout.gate_flag(&"G1"))
	assert_false(layout.gate_flag(&"G3"))


func test_unknown_gate_is_ignored() -> void:
	layout.open_gate(&"G9")
	assert_false(layout.is_gate_open(&"G9"))


# --- the walk (§10 row 1 acceptance) ----------------------------------------------

func test_walk_to_the_arena_is_blocked_at_each_shut_gate_in_order() -> void:
	var goal := SliceLayout.ARENA_CENTRE
	var order: Array[StringName] = [&"G1", &"G2", &"G3", &"G4", &"G5"]
	for k in order.size():
		var shut := order[k]
		var stop := _walk(Vector2.ZERO, goal)
		var gate := SliceLayout.gate_rect(shut)
		assert_lt(stop.x, gate.position.x, "%s shut: stopped west of it (%s)" % [shut, stop])
		assert_gt(stop.x, gate.position.x - 20.0, "%s shut: stopped at the gate, not earlier (%s)" % [shut, stop])
		assert_eq(SliceLayout.room_at(stop), shut, "in %s's corridor" % shut)
		layout.open_gate(shut)
	assert_true(_reaches(Vector2.ZERO, goal), "every gate open: (0,0) -> (9664,0) is clear")


func test_each_gate_alone_blocks_and_its_forced_flag_clears_it() -> void:
	var goal := SliceLayout.ARENA_CENTRE
	layout.force_gates_open = true
	assert_true(_reaches(Vector2.ZERO, goal), "debug flag: everything open")
	layout.force_gates_open = false
	for id: StringName in [&"G1", &"G2", &"G3", &"G4", &"G5"]:
		for other: StringName in [&"G1", &"G2", &"G3", &"G4", &"G5"]:
			layout.set_gate_open(other, other != id)
		var stop := _walk(Vector2.ZERO, goal)
		assert_eq(SliceLayout.room_at(stop), id, "only %s shut blocks at %s" % [id, stop])
		layout.open_gate(id)
		assert_true(_reaches(Vector2.ZERO, goal), "%s forced open: clear" % id)


func test_g0_joins_c_to_the_open_world_and_the_alcove_door_is_open() -> void:
	var from := Vector2(5328, 0)
	var out := Vector2(5328, -1400)
	var stop := _walk(from, out)
	assert_almost_eq(stop.y, -1024.0 + SliceLayout.WALL_PX + 13.0, 1.0, "G0 shut")
	layout.open_gate(&"G0")
	assert_true(_reaches(from, out), "G0 open: out of the footprint")
	assert_false(SliceLayout.in_footprint(out))
	assert_true(_reaches(Vector2(7564, 0), Vector2(7564, 1152)), "D -> alcove, no gate")


func test_rooms_are_walled() -> void:
	layout.force_gates_open = true
	assert_almost_eq(_walk(Vector2.ZERO, Vector2(0, -900)).y, -576.0 + SliceLayout.WALL_PX + 13.0, 1.0)
	assert_almost_eq(_walk(Vector2.ZERO, Vector2(-900, 0)).x, -768.0 + SliceLayout.WALL_PX + 13.0, 1.0)
	assert_almost_eq(_walk(Vector2(9664, 0), Vector2(11000, 0)).x, 10624.0 - SliceLayout.WALL_PX - 13.0, 1.0, "E has no east exit")
	assert_almost_eq(_walk(Vector2(896, 0), Vector2(896, 300)).y, 64.0 - 13.0, 1.0, "corridor side wall")


# --- bullets ---------------------------------------------------------------------

func _manager() -> BulletManager:
	var m := BulletManager.new()
	m.backend_preference = "gdscript"
	m.capacity = 64
	m.world_bounds = Rect2(0, -600, 2400, 1200)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	return m


func _shot_east(m: BulletManager, from: Vector2) -> void:
	var r := ShotRequest.with_velocity(from, Vector2(600, 0))
	r.lifetime = 2.0
	assert_gte(m.spawn(r), 0)


func test_bullets_stop_at_a_shut_gate_and_pass_an_open_one() -> void:
	var m := _manager()
	layout.bind_bullets(m)
	assert_eq(m.walls.wall_count, SliceLayout.wall_rects().size() + SliceLayout.GATE_IDS.size())
	_shot_east(m, Vector2(850, 0))
	for _i in 20:
		m.step(DT)
	assert_eq(m.alive_count(), 0, "shut G1 takes the bullet (wall rule)")
	layout.open_gate(&"G1")
	assert_eq(m.walls.wall_count, SliceLayout.wall_rects().size() + SliceLayout.GATE_IDS.size(), "rebuilt on the next idle frame, not mid-call")
	await wait_process_frames(1)
	assert_eq(m.walls.wall_count, SliceLayout.wall_rects().size() + SliceLayout.GATE_IDS.size() - 1)
	_shot_east(m, Vector2(850, 0))
	for _i in 20:
		m.step(DT)
	assert_eq(m.alive_count(), 1)
	assert_gt(m.pool.pos[0].x, 1024.0, "through the corridor into A")
	layout.close_gate(&"G1")
	layout.flush_bullet_walls()
	assert_eq(m.walls.wall_count, SliceLayout.wall_rects().size() + SliceLayout.GATE_IDS.size())


func test_room_walls_stop_bullets() -> void:
	var m := _manager()
	layout.bind_bullets(m)
	var r := ShotRequest.with_velocity(Vector2(600, 0), Vector2(0, -600))
	r.lifetime = 2.0
	assert_gte(m.spawn(r), 0)
	for _i in 60:
		m.step(DT)
	assert_eq(m.alive_count(), 0, "S north wall")


func test_closing_a_gate_updates_bullet_walls_in_the_same_call() -> void:
	var m := _manager()
	layout.bind_bullets(m)
	layout.open_gate(&"G1")
	layout.flush_bullet_walls()
	var open_count := SliceLayout.wall_rects().size() + SliceLayout.GATE_IDS.size() - 1
	assert_eq(m.walls.wall_count, open_count)
	layout.close_gate(&"G1")
	# No flush_bullet_walls(), no idle frame: the shut gate is already a wall.
	assert_eq(m.walls.wall_count, open_count + 1)
	_shot_east(m, Vector2(850, 0))
	for _i in 20:
		m.step(DT)
	assert_eq(m.alive_count(), 0, "a shot this frame already meets the shut gate")


func test_closing_a_gate_pushes_a_body_out_of_the_doorway() -> void:
	# QA #84: force the gates open, stand at (896, 0), set it false, walk.
	layout.force_gates_open = true
	walker.global_position = Vector2(896, 0)
	await wait_physics_frames(1)
	assert_eq(SliceLayout.room_at(walker.global_position), &"G1")
	layout.force_gates_open = false
	var radius := 13.0
	assert_false(layout.touches_wall(walker.global_position, radius),
		"ejected from the new wall (at %s)" % walker.global_position)
	assert_eq(SliceLayout.room_at(walker.global_position), &"G1", "still in the corridor")
	# At rest in the exact doorway, the nearest clear side is west (S).
	assert_lt(walker.global_position.x, SliceLayout.gate_rect(&"G1").position.x)
	assert_true(_reaches(walker.global_position, Vector2(700, 0)), "can walk toward S")


func test_closing_a_gate_pushes_an_elite_out_of_the_doorway() -> void:
	layout.force_gates_open = true
	var elite := (load("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.configure_elite(&"", Vector2(896, 0), Vector2(896, 0), 1, walker, false)
	add_child_autofree(elite)
	await wait_physics_frames(1)
	assert_true(elite.collide_walls, "ribbon on: world-layer query stays")
	layout.force_gates_open = false
	assert_false(layout.touches_wall(elite.global_position, elite.body_radius),
		"elite ejected (at %s)" % elite.global_position)


func test_draw_reads_the_cached_walls() -> void:
	# _draw may only run under NOTIFICATION_DRAW; queue a real redraw.
	layout._walls_cached.clear()
	layout.queue_redraw()
	await wait_process_frames(2)
	assert_eq(layout._walls_cached.size(), SliceLayout.wall_rects().size())


func test_elites_skip_the_world_query_when_the_ribbon_is_off() -> void:
	layout.remove_from_group(&"slice_layouts")
	var elite := (load("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	add_child_autofree(elite)
	assert_false(elite.collide_walls, "no enabled ribbon in the tree")
