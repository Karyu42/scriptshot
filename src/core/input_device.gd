extends Node
## Autoload `InputDevice`: tracks whether the player is currently using a
## gamepad or mouse+keyboard, switching automatically on the latest meaningful
## input. Gameplay code asks `InputDevice.is_gamepad()` to decide how to aim,
## and which reticle / hints to show.

enum Kind { KEYBOARD_MOUSE, GAMEPAD }

signal device_changed(kind: Kind)

## Joypad axis deflection needed to count as "the player is using the pad"
## (keeps stick drift from stealing focus from the mouse).
const AXIS_THRESHOLD := 0.5
## Mouse movement in pixels needed to count as intent (ignores jitter).
const MOUSE_MOTION_THRESHOLD := 3.0

var current: Kind = Kind.KEYBOARD_MOUSE


func _ready() -> void:
	# Run before any other node so the device is up to date when gameplay reads it.
	process_priority = -1000
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply_cursor_mode()


func _input(event: InputEvent) -> void:
	process_event(event)


func is_gamepad() -> bool:
	return current == Kind.GAMEPAD


## Feeds one event through the detection logic. Public so tests can drive it.
func process_event(event: InputEvent) -> void:
	var kind := classify_event(event)
	if kind >= 0 and kind != current:
		current = kind as Kind
		_apply_cursor_mode()
		device_changed.emit(current)


## Returns the Kind an event indicates, or -1 if it is not a deliberate input.
static func classify_event(event: InputEvent) -> int:
	if event is InputEventJoypadButton:
		return Kind.GAMEPAD if (event as InputEventJoypadButton).pressed else -1
	if event is InputEventJoypadMotion:
		return Kind.GAMEPAD if absf((event as InputEventJoypadMotion).axis_value) >= AXIS_THRESHOLD else -1
	if event is InputEventMouseMotion:
		return Kind.KEYBOARD_MOUSE if (event as InputEventMouseMotion).relative.length() >= MOUSE_MOTION_THRESHOLD else -1
	if event is InputEventMouseButton:
		return Kind.KEYBOARD_MOUSE if (event as InputEventMouseButton).pressed else -1
	if event is InputEventKey:
		var key := event as InputEventKey
		return Kind.KEYBOARD_MOUSE if key.pressed and not key.echo else -1
	return -1


func _apply_cursor_mode() -> void:
	# The game draws its own reticle for both devices.
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
