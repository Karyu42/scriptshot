extends GutTest
## FollowCamera: starts on its target instead of easing in from the origin.

var camera: FollowCamera


func before_each() -> void:
	camera = FollowCamera.new()
	add_child_autofree(camera)


func _target_at(pos: Vector2) -> Node2D:
	var node := Node2D.new()
	node.position = pos
	add_child_autofree(node)
	return node


func test_assigning_a_target_snaps_immediately() -> void:
	assert_eq(camera.global_position, Vector2.ZERO)
	camera.target = _target_at(Vector2(800, -300))
	assert_eq(camera.global_position, Vector2(800, -300), "no easing in from the origin")


func test_a_target_set_before_entering_the_tree_snaps_on_ready() -> void:
	var late := FollowCamera.new()
	late.target = _target_at(Vector2(-640, 480))
	add_child_autofree(late)
	assert_eq(late.global_position, Vector2(-640, 480))


func test_player_targets_include_the_aim_look_ahead_from_the_first_frame() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector2(500, 200)
	add_child_autofree(player)
	player.aim_direction = Vector2.DOWN
	camera.target = player
	assert_eq(camera.global_position, Vector2(500, 200) + Vector2.DOWN * camera.look_ahead)


func test_after_the_snap_the_camera_still_eases_toward_a_moving_target() -> void:
	var target := _target_at(Vector2(100, 0))
	camera.target = target
	target.position = Vector2(400, 0)
	await wait_physics_frames(3)
	assert_gt(camera.global_position.x, 100.0)
	assert_lt(camera.global_position.x, 400.0, "smoothing is still in effect")


func test_snap_to_target_can_be_called_after_a_teleport() -> void:
	var target := _target_at(Vector2.ZERO)
	camera.target = target
	target.position = Vector2(3000, 3000)
	camera.snap_to_target()
	assert_eq(camera.global_position, Vector2(3000, 3000))


func test_clearing_the_target_is_safe() -> void:
	camera.target = _target_at(Vector2(10, 10))
	camera.target = null
	camera.snap_to_target()
	await wait_physics_frames(2)
	assert_eq(camera.global_position, Vector2(10, 10))


func test_main_scene_camera_starts_on_the_player() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	(main.get_node("Player") as Node2D).position = Vector2(600, 300)
	add_child_autofree(main)
	var cam := main.get_node("FollowCamera") as FollowCamera
	var player := main.get_node("Player") as Player
	assert_eq(cam.global_position, player.global_position + player.aim_direction * cam.look_ahead,
		"on the very first frame, before any physics tick")


func _player_at(pos: Vector2) -> Player:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = pos
	add_child_autofree(player)
	player.aim_direction = Vector2.RIGHT
	return player


func test_the_camera_cuts_to_the_player_on_teleport_and_respawn() -> void:
	var player := _player_at(Vector2(100, 100))
	camera.target = player
	player.teleport(Vector2(3000, -2000))
	assert_eq(
		camera.global_position,
		Vector2(3000, -2000) + Vector2.RIGHT * camera.look_ahead,
		"snapped on the same frame, no glide across the arena"
	)
	player.state.set_hp(0.0)
	player.respawn(Vector2(-800, 400))
	assert_eq(camera.global_position, Vector2(-800, 400) + Vector2.RIGHT * camera.look_ahead)


func test_the_script_set_position_also_cuts_the_camera() -> void:
	var player := _player_at(Vector2(0, 0))
	camera.target = player
	player.state.set_position(Vector2(1200, 700))
	assert_eq(camera.global_position, Vector2(1200, 700) + Vector2.RIGHT * camera.look_ahead)


func test_a_replaced_target_no_longer_moves_the_camera() -> void:
	var first := _player_at(Vector2(0, 0))
	camera.target = first
	var second := _player_at(Vector2(50, 50))
	camera.target = second
	first.teleport(Vector2(9000, 9000))
	assert_lt(camera.global_position.x, 1000.0, "the old target's teleports are ignored")
