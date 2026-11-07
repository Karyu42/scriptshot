class_name OpenGround
extends Node2D
## Open-world floor: a world-aligned grid that follows the camera, and the
## 512 px safe disk drawn around the origin. No walls. The old boxed arena
## stays in scenes/sandbox.tscn for the combat fixtures.

const FLOOR := Color("171a21")
const SAFE_TINT := Color("1c2430")
const GRID := Color("1f232c")
const RING := Color("4c5a73")
const GRID_STEP := 128.0

var camera: Camera2D


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var center := Vector2.ZERO
	if camera != null:
		center = camera.get_screen_center_position()
	var half := Vector2(960.0, 640.0)
	var view := Rect2(center - half, half * 2.0)
	draw_rect(view, FLOOR)
	draw_circle(Vector2.ZERO, WorldGen.SAFE_RADIUS, SAFE_TINT)
	var x := floorf(view.position.x / GRID_STEP) * GRID_STEP
	while x <= view.end.x:
		draw_line(Vector2(x, view.position.y), Vector2(x, view.end.y), GRID, 1.0)
		x += GRID_STEP
	var y := floorf(view.position.y / GRID_STEP) * GRID_STEP
	while y <= view.end.y:
		draw_line(Vector2(view.position.x, y), Vector2(view.end.x, y), GRID, 1.0)
		y += GRID_STEP
	draw_arc(Vector2.ZERO, WorldGen.SAFE_RADIUS, 0.0, TAU, 96, RING, 2.0, true)
