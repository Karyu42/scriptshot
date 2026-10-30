class_name AimReticle
extends Node2D
## Minimalist crosshair drawn at the player's aim point. Updated every rendered
## frame (not on the physics tick) so the mouse reticle never lags the cursor.

@export var player: Player

var _color := Color("ffd166")


func _ready() -> void:
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	z_index = 100


func _process(_delta: float) -> void:
	if player == null:
		return
	if InputDevice.is_gamepad():
		global_position = player.get_render_position() + player.aim_direction * 220.0
	else:
		global_position = get_global_mouse_position()
	queue_redraw()


func _draw() -> void:
	draw_arc(Vector2.ZERO, 9.0, 0.0, TAU, 24, _color, 2.0, true)
	for dir: Vector2 in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		draw_line(dir * 13.0, dir * 19.0, _color, 2.0)
