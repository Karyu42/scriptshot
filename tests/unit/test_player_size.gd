extends GutTest
## PlayerState.set_size: clamps, scales hurtbox / body / muzzle / pickup together,
## leaves dash and speed alone, emits script_wrote, and shrinks to fit if a grow
## has no free spot within 64 px.


func before_each() -> void:
	ScriptWarnings.reset()
	TimeControl.cancel()


func after_each() -> void:
	TimeControl.cancel()


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
