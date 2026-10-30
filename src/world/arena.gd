class_name Arena
extends Node2D
## Draws the play field: flat background, faint grid and a border. The matching
## wall colliders (layer `world`) are StaticBody2D children in the scene.

@export var rect := Rect2(-1280, -720, 2560, 1440)
@export var grid_step := 80.0
@export var floor_color := Color("171a21")
@export var grid_color := Color("1f232c")
@export var border_color := Color("3a4152")


func _draw() -> void:
	draw_rect(rect, floor_color)
	var x := rect.position.x
	while x <= rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), grid_color, 1.0)
		x += grid_step
	var y := rect.position.y
	while y <= rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), grid_color, 1.0)
		y += grid_step
	draw_rect(rect, border_color, false, 4.0)
