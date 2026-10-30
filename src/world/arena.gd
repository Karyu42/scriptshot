class_name Arena
extends Node2D
## Draws the play field: flat background, faint grid, a border and the wall
## blocks. The matching colliders (layer `world`) are the RectangleShape2D
## children of the StaticBody2D nodes in the `world_walls` group; the same
## rectangles are what bullets collide with (BulletManager.collect_walls()).

@export var rect := Rect2(-1280, -720, 2560, 1440)
@export var grid_step := 80.0
@export var floor_color := Color("171a21")
@export var grid_color := Color("1f232c")
@export var border_color := Color("3a4152")
@export var wall_color := Color("2b3140")
@export var wall_edge_color := Color("4a536a")
@export var walls_group := &"world_walls"


func _ready() -> void:
	# Walls are siblings that are ready after (or before) this node; draw once the
	# whole scene is up.
	queue_redraw.call_deferred()


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
	_draw_walls()


func _draw_walls() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group(walls_group):
		var body := node as CollisionObject2D
		if body == null:
			continue
		for child in body.get_children():
			var shape_node := child as CollisionShape2D
			if shape_node == null or shape_node.disabled:
				continue
			var rect_shape := shape_node.shape as RectangleShape2D
			if rect_shape == null:
				continue
			var box: Rect2 = get_global_transform().affine_inverse() * (shape_node.global_transform * Rect2(-rect_shape.size * 0.5, rect_shape.size))
			draw_rect(box, wall_color)
			draw_rect(box, wall_edge_color, false, 2.0)
