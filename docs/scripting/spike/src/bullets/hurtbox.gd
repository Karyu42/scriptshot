class_name Hurtbox
extends Node2D
## Circular damage receiver for the bullet system. Add as a child of anything
## that can be shot; the bullet manager finds it through the group below and
## tests it against bullets with a spatial hash (no per-bullet physics nodes).

## Emitted when a bullet connects. `hit_position` is the bullet's position and
## `bullet_velocity` its velocity at impact (for knockback / hit effects).
signal hit(damage: float, hit_position: Vector2, bullet_velocity: Vector2)

const GROUP := &"bullet_targets"

## Hit circle radius in pixels.
@export var radius := 16.0
## One of the Layers constants: which faction this hurtbox belongs to. Bullets
## only hit hurtboxes whose layer is in the bullet's hit_mask.
@export_flags_2d_physics var layer := Layers.ENEMY
## Turn off to make the owner temporarily untouchable (i-frames).
@export var active := true


func _enter_tree() -> void:
	add_to_group(GROUP)


## Called by the bullet manager.
func receive_hit(damage: float, hit_position: Vector2, bullet_velocity: Vector2) -> void:
	hit.emit(damage, hit_position, bullet_velocity)
