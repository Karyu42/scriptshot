class_name Hurtbox
extends Node2D
## Circular damage receiver for the bullet system. Add as a child of anything
## that can be shot; the bullet manager reads every Hurtbox that is in the tree
## and tests it against bullets with a spatial hash (no per-bullet physics nodes).

## Emitted when a bullet connects. `hit_position` is where the bullet touched the
## hurtbox and `bullet_velocity` its velocity at impact (for knockback / hit
## effects).
signal hit(damage: float, hit_position: Vector2, bullet_velocity: Vector2)

const GROUP := &"bullet_targets"

## Hit circle radius in pixels.
@export var radius := 16.0
## One of the Layers constants: which faction this hurtbox belongs to. Bullets
## only hit hurtboxes whose layer is in the bullet's hit_mask.
@export_flags_2d_physics var layer := Layers.ENEMY
## Turn off to make the owner temporarily untouchable (i-frames).
@export var active := true

## Every hurtbox currently in a scene tree. Kept as a plain array so the bullet
## manager can walk it every tick without allocating (get_nodes_in_group() builds
## a new Array each call).
static var registry: Array[Hurtbox] = []


func _enter_tree() -> void:
	add_to_group(GROUP)
	registry.append(self)


func _exit_tree() -> void:
	registry.erase(self)


## Called by the bullet manager.
func receive_hit(damage: float, hit_position: Vector2, bullet_velocity: Vector2) -> void:
	hit.emit(damage, hit_position, bullet_velocity)
