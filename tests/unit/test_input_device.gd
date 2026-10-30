extends GutTest
## InputDevice autoload logic: automatic switching between gamepad and mouse+keyboard.

const InputDeviceScript := preload("res://src/core/input_device.gd")

var device: Node


func before_each() -> void:
	device = InputDeviceScript.new()
	add_child_autofree(device)
	watch_signals(device)


func _axis(value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = JOY_AXIS_LEFT_X
	e.axis_value = value
	return e


func _mouse_move(rel: Vector2) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.relative = rel
	return e


func _key(pressed: bool = true, echo: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = KEY_W
	e.pressed = pressed
	e.echo = echo
	return e


func test_defaults_to_keyboard_mouse() -> void:
	assert_false(device.is_gamepad())


func test_gamepad_stick_switches_to_gamepad() -> void:
	device.process_event(_axis(0.9))
	assert_true(device.is_gamepad())
	assert_signal_emit_count(device, "device_changed", 1)
	assert_signal_emitted_with_parameters(device, "device_changed", [InputDeviceScript.Kind.GAMEPAD])


func test_stick_drift_does_not_switch_device() -> void:
	device.process_event(_axis(0.2))
	assert_false(device.is_gamepad())
	assert_signal_not_emitted(device, "device_changed")


func test_gamepad_button_press_switches_but_release_does_not() -> void:
	var b := InputEventJoypadButton.new()
	b.button_index = JOY_BUTTON_A
	b.pressed = false
	device.process_event(b)
	assert_false(device.is_gamepad())
	b.pressed = true
	device.process_event(b)
	assert_true(device.is_gamepad())


func test_mouse_motion_switches_back() -> void:
	device.process_event(_axis(1.0))
	device.process_event(_mouse_move(Vector2(12, 4)))
	assert_false(device.is_gamepad())
	assert_signal_emit_count(device, "device_changed", 2)


func test_tiny_mouse_jitter_is_ignored_while_on_gamepad() -> void:
	device.process_event(_axis(1.0))
	device.process_event(_mouse_move(Vector2(1, 1)))
	assert_true(device.is_gamepad())


func test_key_press_switches_to_keyboard_but_echo_and_release_do_not() -> void:
	device.process_event(_axis(1.0))
	device.process_event(_key(false))
	device.process_event(_key(true, true))
	assert_true(device.is_gamepad())
	device.process_event(_key())
	assert_false(device.is_gamepad())


func test_mouse_click_switches_to_keyboard_mouse() -> void:
	device.process_event(_axis(1.0))
	var c := InputEventMouseButton.new()
	c.button_index = MOUSE_BUTTON_LEFT
	c.pressed = true
	device.process_event(c)
	assert_false(device.is_gamepad())


func test_same_device_does_not_reemit() -> void:
	device.process_event(_axis(1.0))
	device.process_event(_axis(-1.0))
	assert_signal_emit_count(device, "device_changed", 1)


func test_input_map_has_all_actions_for_both_devices() -> void:
	var expect := {
		"move_left": [InputEventKey, InputEventJoypadMotion],
		"move_right": [InputEventKey, InputEventJoypadMotion],
		"move_up": [InputEventKey, InputEventJoypadMotion],
		"move_down": [InputEventKey, InputEventJoypadMotion],
		"aim_left": [InputEventJoypadMotion],
		"aim_right": [InputEventJoypadMotion],
		"aim_up": [InputEventJoypadMotion],
		"aim_down": [InputEventJoypadMotion],
		"fire": [InputEventMouseButton, InputEventJoypadMotion],
	}
	for action in expect:
		assert_true(InputMap.has_action(action), action)
		var events := InputMap.action_get_events(action)
		for kind in expect[action]:
			var found := false
			for e in events:
				if is_instance_of(e, kind):
					found = true
			assert_true(found, "%s has a %s binding" % [action, "required event kind"])


func test_fire_is_bound_to_right_trigger_and_left_mouse() -> void:
	var trigger := false
	var lmb := false
	for e in InputMap.action_get_events("fire"):
		if e is InputEventJoypadMotion and e.axis == JOY_AXIS_TRIGGER_RIGHT:
			trigger = true
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
			lmb = true
	assert_true(trigger, "RT")
	assert_true(lmb, "LMB")
