extends GutTest
## The dash on the real player scene: direction rules, invulnerability, cooldown,
## distance, collisions, and respawn. Runs on real physics frames (move_and_slide
## only uses the physics delta inside the physics step).

const DT := 1.0 / 60.0

var player: Player


func before_each() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.global_position = Vector2(500, 500)
	player.aim_direction = Vector2.RIGHT
	player.dash_finished.connect(_record_dash_end)


func after_each() -> void:
	Input.action_release("dash")
	Input.action_release("move_up")
	Input.action_release("move_left")
	InputDevice.current = InputDevice.Kind.KEYBOARD_MOUSE


func _step(seconds: float) -> void:
	await wait_physics_frames(roundi(seconds / DT))


## Waits for the burst to end (one frame at a time) so the position can be read
## at the exact end of the dash, before the player coasts.
func _finish_dash() -> void:
	for i in 40:
		if not player.is_dashing():
			return
		await wait_physics_frames(1)


## Position of the player on the physics tick its dash ended (a rendered frame can
## contain several physics ticks, so reading the position after a frame may include
## a tick of running on top of the burst).
var _end_position := Vector2.ZERO


func _record_dash_end() -> void:
	_end_position = player.global_position


func test_dash_action_is_bound_to_keyboard_and_gamepad() -> void:
	assert_true(InputMap.has_action("dash"))
	var space := false
	var shift := false
	var button_b := false
	var bumper := false
	for e: InputEvent in InputMap.action_get_events("dash"):
		var key := e as InputEventKey
		if key != null and key.physical_keycode == KEY_SPACE:
			space = true
		if key != null and key.physical_keycode == KEY_SHIFT:
			shift = true
		var button := e as InputEventJoypadButton
		if button != null and button.button_index == JOY_BUTTON_B:
			button_b = true
		if button != null and button.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			bumper = true
	assert_true(space, "Space")
	assert_true(shift, "Shift")
	assert_true(button_b, "gamepad B")
	assert_true(bumper, "gamepad right bumper")


func test_default_tuning() -> void:
	# 1.5 s cooldown and 0.2 s invulnerability were decided by Karyu; 160 px over
	# 0.2 s is the design pillars' (5.4) figure.
	assert_eq(player.dash_cooldown, 1.5)
	assert_eq(player.dash_invulnerability, 0.2)
	assert_eq(player.dash_distance, 160.0)
	assert_eq(player.dash_duration, 0.2)


func test_dash_moves_the_tuned_distance_along_the_given_direction() -> void:
	var start := player.global_position
	assert_true(player.try_dash(Vector2(0, -2)))
	await _finish_dash()
	var moved := _end_position - start
	assert_almost_eq(moved.y, -player.dash_distance, 0.5)
	assert_almost_eq(moved.x, 0.0, 0.001)
	assert_false(player.is_dashing())


func test_standing_still_dashes_toward_the_aim_direction() -> void:
	player.aim_direction = Vector2.LEFT
	var start := player.global_position
	assert_true(player.try_dash())
	await _finish_dash()
	assert_almost_eq((_end_position - start).x, -player.dash_distance, 0.5)


func test_move_input_wins_over_aim_when_the_dash_input_fires() -> void:
	player.aim_direction = Vector2.RIGHT
	Input.action_press("move_up")
	Input.action_press("dash")
	var start := player.global_position
	await wait_physics_frames(1)
	assert_true(player.is_dashing())
	await _step(0.3)
	var moved := player.global_position - start
	assert_lt(moved.y, -100.0, "dashed up")
	assert_almost_eq(moved.x, 0.0, 0.5)


func test_dash_makes_the_player_invulnerable_for_exactly_the_decided_time() -> void:
	player.try_dash(Vector2.RIGHT)
	assert_true(player.health.is_invulnerable())
	assert_false(player.health.damage(1.0), "no damage while dashing")
	await _step(0.18)
	assert_true(player.health.is_invulnerable(), "still invulnerable 0.18 s in")
	await _step(0.05)
	assert_false(player.health.is_invulnerable())
	assert_true(player.health.damage(1.0))


func test_hurtbox_is_off_while_dashing_and_back_after() -> void:
	var hurtbox: Hurtbox = player.get_node("Hurtbox")
	player.try_dash(Vector2.RIGHT)
	assert_false(hurtbox.active)
	await _step(0.3)
	assert_true(hurtbox.active)


func test_dash_does_not_cut_a_longer_invulnerability_short() -> void:
	player.state.set_invulnerable(5.0)
	player.try_dash(Vector2.RIGHT)
	await _step(0.3)
	assert_true(player.health.is_invulnerable())


func test_cooldown_blocks_a_second_dash_until_one_and_a_half_seconds_after_the_first() -> void:
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_false(player.try_dash(Vector2.RIGHT), "not while dashing")
	await _step(1.0)
	assert_false(player.try_dash(Vector2.RIGHT), "still cooling down")
	assert_gt(player.get_dash_cooldown_left(), 0.0)
	await _step(0.55)
	assert_eq(player.get_dash_cooldown_left(), 0.0)
	assert_true(player.try_dash(Vector2.RIGHT))


func test_dash_blended_into_running_speed_at_the_end() -> void:
	player.try_dash(Vector2.RIGHT)
	await _step(0.2)
	assert_lte(player.velocity.length(), player.max_speed + 0.01, "no leftover burst speed")


func test_dash_stops_at_a_wall() -> void:
	var wall := StaticBody2D.new()
	wall.collision_layer = Layers.WORLD
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(20, 200)
	shape.shape = rect
	wall.add_child(shape)
	add_child_autofree(wall)
	wall.global_position = Vector2(600, 500)
	await wait_physics_frames(1)
	var start := player.global_position
	player.try_dash(Vector2.RIGHT)
	await _step(0.3)
	assert_lt(player.global_position.x, 600.0 - 10.0, "did not tunnel through")
	assert_lt(player.global_position.x - start.x, player.dash_distance)


func test_dash_signal_carries_the_direction() -> void:
	watch_signals(player)
	player.try_dash(Vector2(0, 7))
	assert_signal_emitted_with_parameters(player, "dashed", [Vector2.DOWN])


func test_a_dead_player_cannot_dash() -> void:
	player.state.set_hp(0.0)
	assert_false(player.try_dash(Vector2.RIGHT))


func test_respawn_resets_the_dash() -> void:
	player.try_dash(Vector2.RIGHT)
	player.state.set_hp(0.0)
	player.respawn(Vector2(10, 10))
	assert_false(player.is_dashing())
	assert_eq(player.get_dash_cooldown_left(), 0.0)
	assert_false(player.health.is_invulnerable())
	assert_true(player.try_dash(Vector2.RIGHT))


func test_tuning_exports_change_the_next_dash() -> void:
	player.dash_distance = 300.0
	player.dash_cooldown = 0.5
	var start := player.global_position
	player.try_dash(Vector2.RIGHT)
	await _finish_dash()
	assert_almost_eq((_end_position - start).x, 300.0, 0.5)
	await _step(0.4)
	assert_true(player.try_dash(Vector2.RIGHT), "0.5 s cooldown")


func test_degenerate_tuning_cannot_break_the_dash() -> void:
	player.dash_duration = 0.0
	player.dash_distance = -5.0
	player.dash_curve_power = -3.0
	assert_true(player.try_dash(Vector2.RIGHT))
	await _step(0.1)
	assert_true(player.global_position.is_finite())
	assert_false(player.is_dashing())
