extends GutTest
## PlayerState.set_size: clamps, scales hurtbox / body / muzzle / pickup together,
## leaves dash and speed alone, emits script_wrote, and shrinks to fit if a grow
## has no free spot within 64 px.


func before_each() -> void:
	ScriptWarnings.reset()
	TimeControl.cancel()


func after_each() -> void:
	TimeControl.cancel()
	Engine.time_scale = 1.0


func _player_at(at: Vector2) -> Player:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.global_position = at
	player.aim_direction = Vector2.RIGHT
	return player


func test_default_is_one_and_clamps() -> void:
	var player := _player_at(Vector2(400, 400))
	await wait_physics_frames(1)
	var st := player.state
	assert_almost_eq(st.get_size(), 1.0, 0.0001)
	assert_eq(st.set_size(0.1), Player.MIN_SIZE)
	assert_eq(st.get_size(), Player.MIN_SIZE)
	assert_eq(st.set_size(9.0), Player.MAX_SIZE)
	assert_eq(st.get_size(), Player.MAX_SIZE)
	var current := st.get_size()
	assert_eq(st.set_size(NAN), current)
	assert_gte(ScriptWarnings.count("PlayerState.set_size"), 1)


func test_hurtbox_body_muzzle_and_pickup_scale_together() -> void:
	var player := _player_at(Vector2(400, 400))
	await wait_physics_frames(1)
	var hurtbox: Hurtbox = player.get_node("Hurtbox")
	var body_shape: CollisionShape2D = player.get_node("CollisionShape2D")
	var base_hurt := hurtbox.radius
	var base_body := (body_shape.shape as CircleShape2D).radius
	var base_muzzle := player.muzzle_offset
	var base_pickup := player.pickup_radius
	var applied := player.state.set_size(2.0)
	assert_eq(applied, 2.0)
	assert_almost_eq(hurtbox.radius, base_hurt * 2.0, 0.0001)
	assert_almost_eq((body_shape.shape as CircleShape2D).radius, base_body * 2.0, 0.0001)
	assert_almost_eq(player.muzzle_offset, base_muzzle * 2.0, 0.0001)
	assert_almost_eq(player.pickup_radius, base_pickup + (base_body * 2.0 - base_body), 0.0001)
	assert_eq(player.max_speed, 300.0)
	assert_eq(player.dash_distance, 160.0)
	player.state.set_size(0.5)
	assert_almost_eq(player.pickup_radius, base_pickup + (base_body * 0.5 - base_body), 0.0001)
	assert_almost_eq(player.muzzle_offset, base_muzzle * 0.5, 0.0001)


func test_script_wrote_emits_old_and_new() -> void:
	var player := _player_at(Vector2(400, 400))
	await wait_physics_frames(1)
	watch_signals(player.state)
	player.state.set_size(2.0)
	assert_signal_emitted_with_parameters(player.state, "script_wrote", [&"size", 1.0, 2.0])
	player.state.set_size(2.0)
	assert_signal_emit_count(player.state, "script_wrote", 1)


func test_grow_into_a_corridor_is_limited_to_what_fits() -> void:
	var player := _player_at(Vector2(400, 400))
	# 40 px cell: walls occupy 360-380 / 420-440 on X and Y.
	_wall(Vector2(20, 800), Vector2(370, 400))
	_wall(Vector2(20, 800), Vector2(430, 400))
	_wall(Vector2(800, 20), Vector2(400, 370))
	_wall(Vector2(800, 20), Vector2(400, 430))
	await wait_physics_frames(2)
	var applied := player.state.set_size(4.0)
	assert_lt(applied, 4.0, "cannot grow to 4x in a tight cell")
	assert_gt(applied, 1.0 - 0.0001)
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_lt(body.radius, 20.0)
	assert_almost_eq(player.global_position.x, 400.0, 0.05)
	assert_almost_eq(player.global_position.y, 400.0, 0.05)


func test_grow_against_a_thin_wall_does_not_cross_it() -> void:
	# 28 px alcove: back wall 366-386, thin 4 px wall 414-418, player at 400
	# (radius 13 just fits). Size 2 (radius 26) cannot fit here, but a free
	# centre exists past the thin wall within 64 px. Push-out must not take it.
	var player := _player_at(Vector2(400, 400))
	_wall(Vector2(20, 800), Vector2(376, 400))
	_wall(Vector2(4, 800), Vector2(416, 400))
	await wait_physics_frames(2)
	var start := player.global_position
	var applied := player.state.set_size(2.0)
	assert_lt(applied, 2.0, "no reachable free centre at size 2")
	assert_gt(applied, 1.0 - 0.0001)
	assert_lt(player.global_position.x, 414.0, "must stay on this side of the thin wall")
	assert_almost_eq(player.global_position.x, start.x, 0.05)
	assert_almost_eq(player.global_position.y, start.y, 0.05)
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_lt(body.radius, 14.0 + 0.05)


func test_grow_at_a_closed_gate_does_not_cross_it() -> void:
	# Corridor with a closed 4 px gate (SliceLayout.GATE_PX) and a back wall,
	# open space past the gate. Same reachability rule as the thin-wall case.
	var player := _player_at(Vector2(400, 400))
	_wall(Vector2(20, 800), Vector2(376, 400))
	# Corridor ceiling / floor so the only opening is the gate slot.
	_wall(Vector2(800, 20), Vector2(400, 370))
	_wall(Vector2(800, 20), Vector2(400, 430))
	_wall(Vector2(SliceLayout.GATE_PX, 40), Vector2(400.0 + 14.0 + SliceLayout.GATE_PX * 0.5, 400))
	await wait_physics_frames(2)
	var start := player.global_position
	var applied := player.state.set_size(2.0)
	assert_lt(applied, 2.0, "closed gate is not a reachable push-out")
	assert_gt(applied, 1.0 - 0.0001)
	assert_lt(player.global_position.x, start.x + 14.0, "must stay on this side of the gate")
	assert_almost_eq(player.global_position.x, start.x, 0.05)
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_lt(body.radius, 14.0 + 0.05)


func test_grow_against_a_thick_wall_pushes_to_a_reachable_spot() -> void:
	# Wall occupies x 360-380. The size-1 body at 400 is clear. Size 4
	# (radius 52) overlaps the wall; open space to the right is reachable,
	# so the write keeps size 4 and moves the centre just clear of the wall.
	var player := _player_at(Vector2(400, 400))
	_wall(Vector2(20, 800), Vector2(370, 400))
	await wait_physics_frames(2)
	var start := player.global_position
	var applied := player.state.set_size(4.0)
	assert_eq(applied, 4.0)
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_almost_eq(body.radius, 52.0, 0.05)
	assert_gte(player.global_position.x, 380.0 + 52.0 - 0.05)
	assert_lt(player.global_position.x, start.x + Player.SIZE_RESOLVE_RADIUS + 0.05)
	assert_almost_eq(player.global_position.y, start.y, 0.05)


func test_restored_size_runs_the_fit_check() -> void:
	var player := _player_at(Vector2(400, 400))
	_wall(Vector2(20, 800), Vector2(370, 400))
	_wall(Vector2(20, 800), Vector2(430, 400))
	_wall(Vector2(800, 20), Vector2(400, 370))
	_wall(Vector2(800, 20), Vector2(400, 430))
	await wait_physics_frames(2)
	watch_signals(player.state)
	var applied := player.apply_size(4.0)
	assert_lt(applied, 4.0, "restore goes through the same fit check as set_size")
	assert_gt(applied, 1.0 - 0.0001)
	assert_signal_emit_count(player.state, "script_wrote", 0)


func test_respawn_at_a_tight_spot_does_not_overlap_walls() -> void:
	var player := _player_at(Vector2(800, 400))
	await wait_physics_frames(1)
	assert_eq(player.state.set_size(4.0), 4.0)
	# 40 px cell at (400, 400), same as the corridor test.
	_wall(Vector2(20, 800), Vector2(370, 400))
	_wall(Vector2(20, 800), Vector2(430, 400))
	_wall(Vector2(800, 20), Vector2(400, 370))
	_wall(Vector2(800, 20), Vector2(400, 430))
	await wait_physics_frames(2)
	player.respawn(Vector2(400, 400))
	assert_lt(player.get_size(), 4.0, "large body cannot stay at 4x inside the cell")
	assert_gt(player.get_size(), Player.MIN_SIZE - 0.0001)
	assert_lt(player.global_position.x, 420.0)
	assert_gt(player.global_position.x, 380.0)
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_lt(body.radius, 20.0)


func test_main_restores_and_persists_player_size() -> void:
	const SAVE := "user://gut_player_size_main.cfg"
	_rm_save(SAVE)
	var save := SaveGame.new()
	save.path = SAVE
	save.world_seed = 7
	save.player_size = 2.0
	save.save()
	var main := _main_with_save(SAVE)
	add_child_autofree(main)
	await wait_physics_frames(2)
	var player := main.get_node("Player") as Player
	assert_almost_eq(player.get_size(), 2.0, 0.0001)
	player.state.set_size(3.0)
	assert_almost_eq(main._save.player_size, 3.0, 0.0001, "in-memory size updates immediately")
	var pending := SaveGame.load_from(SAVE)
	assert_almost_eq(pending.player_size, 2.0, 0.0001, "debounce has not written the file yet")
	main._write_save()
	var reloaded := SaveGame.load_from(SAVE)
	assert_almost_eq(reloaded.player_size, 3.0, 0.0001)
	_rm_save(SAVE)


func test_sixty_size_changes_write_once_after_debounce() -> void:
	const SAVE := "user://gut_player_size_debounce.cfg"
	_rm_save(SAVE)
	var save := SaveGame.new()
	save.path = SAVE
	save.world_seed = 7
	save.player_size = 1.0
	save.save()
	var main := _main_with_save(SAVE)
	add_child_autofree(main)
	await wait_physics_frames(3)
	var player := main.get_node("Player") as Player
	var writes := main._save.write_count
	for i in 60:
		player.state.set_size(2.0 if (i % 2) == 0 else 3.0)
	assert_eq(main._save.write_count, writes, "no disk write during the pulse")
	assert_almost_eq(main._save.player_size, 3.0, 0.0001)
	var pending := SaveGame.load_from(SAVE)
	assert_almost_eq(pending.player_size, 1.0, 0.0001)
	# Real-time debounce, not Engine.time_scale or TimeControl.
	Engine.time_scale = 0.25
	await get_tree().create_timer(Main.SIZE_SAVE_DEBOUNCE + 0.25, true, true).timeout
	Engine.time_scale = 1.0
	assert_eq(main._save.write_count, writes + 1, "exactly one write after debounce")
	var reloaded := SaveGame.load_from(SAVE)
	assert_almost_eq(reloaded.player_size, 3.0, 0.0001)
	_rm_save(SAVE)


func test_exit_tree_flushes_a_pending_size_save() -> void:
	const SAVE := "user://gut_player_size_exit.cfg"
	_rm_save(SAVE)
	var save := SaveGame.new()
	save.path = SAVE
	save.world_seed = 7
	save.player_size = 1.0
	save.save()
	var main := _main_with_save(SAVE)
	add_child(main)
	await wait_physics_frames(3)
	var player := main.get_node("Player") as Player
	var writes := main._save.write_count
	player.state.set_size(2.5)
	assert_eq(main._save.write_count, writes, "still pending")
	var pending := SaveGame.load_from(SAVE)
	assert_almost_eq(pending.player_size, 1.0, 0.0001)
	remove_child(main)
	main.free()
	var reloaded := SaveGame.load_from(SAVE)
	assert_almost_eq(reloaded.player_size, 2.5, 0.0001, "exit_tree flushes the pending size")
	_rm_save(SAVE)


func test_unchanged_size_does_not_write() -> void:
	const SAVE := "user://gut_player_size_unchanged.cfg"
	_rm_save(SAVE)
	var save := SaveGame.new()
	save.path = SAVE
	save.world_seed = 7
	save.player_size = 1.0
	save.save()
	var main := _main_with_save(SAVE)
	add_child_autofree(main)
	await wait_physics_frames(3)
	var player := main.get_node("Player") as Player
	var writes := main._save.write_count
	assert_almost_eq(player.get_size(), 1.0, 0.0001)
	player.state.set_size(1.0)
	main._persist_player_size()
	assert_eq(main._save.write_count, writes, "no write when the size is unchanged")
	await wait_physics_frames(2)
	assert_eq(main._save.write_count, writes)
	_rm_save(SAVE)


func test_saved_size_four_next_to_a_wall_reloads_without_getting_stuck() -> void:
	# Persist 4.0, then apply it at a position next to a wall, the same way
	# Main._restore_player_size does (apply_size: reachable push-out, or the
	# largest size that fits). The ship must not load stuck in the wall.
	const SAVE := "user://gut_player_size_reload_wall.cfg"
	_rm_save(SAVE)
	var save := SaveGame.new()
	save.path = SAVE
	save.world_seed = 7
	save.player_size = 4.0
	save.save()
	var loaded := SaveGame.load_from(SAVE)
	assert_almost_eq(loaded.player_size, 4.0, 0.0001)
	var player := _player_at(Vector2(400, 400))
	_wall(Vector2(20, 800), Vector2(370, 400))
	await wait_physics_frames(2)
	var start := player.global_position
	var applied := player.apply_size(loaded.player_size)
	if not is_equal_approx(applied, loaded.player_size):
		loaded.player_size = applied
		loaded.save()
	assert_eq(applied, 4.0, "a free reachable spot keeps the saved size")
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_almost_eq(body.radius, 52.0, 0.05)
	assert_gte(player.global_position.x, 380.0 + 52.0 - 0.05)
	assert_gt(player.global_position.x - body.radius, 380.0 - 0.05, "not overlapping the wall")
	assert_lt(player.global_position.x, start.x + Player.SIZE_RESOLVE_RADIUS + 0.05)
	assert_almost_eq(player.global_position.y, start.y, 0.05)
	_rm_save(SAVE)


func test_saved_size_four_in_a_narrow_spot_reloads_to_what_fits() -> void:
	const SAVE := "user://gut_player_size_reload_narrow.cfg"
	_rm_save(SAVE)
	var save := SaveGame.new()
	save.path = SAVE
	save.world_seed = 7
	save.player_size = 4.0
	save.save()
	var loaded := SaveGame.load_from(SAVE)
	var player := _player_at(Vector2(400, 400))
	_wall(Vector2(20, 800), Vector2(370, 400))
	_wall(Vector2(20, 800), Vector2(430, 400))
	_wall(Vector2(800, 20), Vector2(400, 370))
	_wall(Vector2(800, 20), Vector2(400, 430))
	await wait_physics_frames(2)
	var applied := player.apply_size(loaded.player_size)
	if not is_equal_approx(applied, loaded.player_size):
		loaded.player_size = applied
		loaded.save()
	assert_lt(applied, 4.0, "largest size that fits, not the saved 4.0")
	assert_gt(applied, 1.0 - 0.0001)
	assert_almost_eq(player.global_position.x, 400.0, 0.05)
	assert_almost_eq(player.global_position.y, 400.0, 0.05)
	var body := (player.get_node("CollisionShape2D") as CollisionShape2D).shape as CircleShape2D
	assert_lt(body.radius, 20.0)
	var rel := SaveGame.load_from(SAVE)
	assert_almost_eq(rel.player_size, applied, 0.0001, "fitted size is what later loads use")
	_rm_save(SAVE)


func _main_with_save(path: String) -> Main:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = path
	(main.get_node("BulletManager") as BulletManager).backend_preference = "gdscript"
	return main


func _rm_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _wall(size: Vector2, at: Vector2) -> void:
	var wall := StaticBody2D.new()
	wall.collision_layer = Layers.WORLD
	wall.collision_mask = 0
	var shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = size
	shape.shape = box
	wall.add_child(shape)
	add_child_autofree(wall)
	wall.global_position = at
