extends GutTest
## Player aiming: gamepad deadzone applied once, mouse aim from the screen-space
## offset so camera look-ahead cannot feed back into it.

var player: Player


func before_each() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)


func after_each() -> void:
	Input.action_release("aim_right")
	Input.action_release("aim_left")
	InputDevice.current = InputDevice.Kind.KEYBOARD_MOUSE


func test_a_stick_just_past_the_input_map_deadzone_steers_the_aim() -> void:
	# aim_* deadzone is 0.25; Input.get_vector() rescales 0.3 to ~0.07. A second
	# 0.25 deadzone in Player would throw that away.
	InputDevice.current = InputDevice.Kind.GAMEPAD
	player.aim_direction = Vector2.UP
	Input.action_press("aim_right", 0.3)
	player._update_aim()
	assert_eq(player.aim_direction, Vector2.RIGHT)


func test_a_stick_inside_the_input_map_deadzone_keeps_the_aim() -> void:
	InputDevice.current = InputDevice.Kind.GAMEPAD
	player.aim_direction = Vector2.UP
	Input.action_press("aim_right", 0.2)
	player._update_aim()
	assert_eq(player.aim_direction, Vector2.UP)


func test_mouse_aim_uses_the_screen_space_offset() -> void:
	player.global_position = Vector2(1000, 1000)
	player.update_mouse_aim(Vector2(600, 300), Vector2(500, 300))
	assert_eq(player.aim_direction, Vector2.RIGHT)
	player.update_mouse_aim(Vector2(500, 100), Vector2(500, 300))
	assert_eq(player.aim_direction, Vector2.UP)
	assert_eq(player.aim_point, Vector2(1000, 800), "world aim point = player + screen offset at zoom 1")


func test_mouse_aim_ignores_where_the_camera_is() -> void:
	var viewport := player.get_viewport()
	var saved := viewport.canvas_transform
	var mouse := Vector2(900, 200)
	var results: Array[Vector2] = []
	for cam_offset: Vector2 in [Vector2.ZERO, Vector2(70, 0), Vector2(-300, 120), Vector2(1234, -987)]:
		viewport.canvas_transform = Transform2D(0.0, -cam_offset)
		# Same ship, same cursor *on screen*: the ship is drawn at the same
		# viewport pixel in every case, whatever the camera did to get there.
		player.update_mouse_aim(mouse, Vector2(400, 300))
		results.append(player.aim_direction)
	viewport.canvas_transform = saved
	for r in results:
		assert_eq(r, results[0])


func test_look_ahead_does_not_feed_back_into_mouse_aim() -> void:
	# Camera + player + a fixed cursor for 90 physics ticks. The camera leans
	# toward the aim; the aim must settle instead of chasing its own look-ahead.
	var camera := FollowCamera.new()
	add_child_autofree(camera)
	camera.target = player
	camera.make_current()
	var viewport := player.get_viewport()
	var mouse := Vector2(900, 300)
	var history: Array[Vector2] = []
	for tick in 90:
		await get_tree().physics_frame
		player.update_mouse_aim(mouse, viewport.get_canvas_transform() * player.get_render_position())
		history.append(player.aim_direction)
	var last := history[history.size() - 1]
	for k in range(history.size() - 10, history.size()):
		assert_lt(history[k].distance_to(last), 0.01, "aim has settled (tick %d)" % k)
	assert_gt(last.x, 0.8, "still pointing at the cursor on the right")
