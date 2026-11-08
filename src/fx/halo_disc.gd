class_name HaloDisc
extends Node2D
## Low-alpha disc behind a rare-tier body. The blend mode lives on this
## canvas item's CanvasItemMaterial, never on the body, so the fill does not
## add. No shader, no post-process.


var disc_radius := 32.0
var disc_color := Color(1, 1, 1, 0.16)


func _draw() -> void:
	draw_circle(Vector2.ZERO, disc_radius, disc_color)
