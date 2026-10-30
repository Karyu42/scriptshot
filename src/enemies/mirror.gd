class_name Mirror
extends TrainingDummy
## Test enemy that reflects the player's bullets. A Reflector arc turns to face
## `target` (the player) at `turn_speed`, so shots aimed at it from the front come
## back owned by the enemy and can hurt the player, while shots from behind (or
## from the side of the arc) hit the body normally. It never shoots itself.

## How fast the mirror turns to face the target, radians per second.
@export var turn_speed := 2.5
## Width of the reflecting arc in degrees.
@export_range(10.0, 360.0, 1.0) var arc_degrees := 150.0
## How far the reflecting arc sits outside the body.
@export var shield_gap := 18.0

## Injected by Main.
var target: Node2D

@onready var reflector: Reflector = $Reflector


func _ready() -> void:
	super._ready()
	reflector.radius = body_radius + shield_gap
	reflector.arc_degrees = arc_degrees
	reflector.reflects_owners = Layers.PLAYER
	reflector.mode = Reflector.Mode.MIRROR
	reflector.target = target


func _physics_process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	reflector.target = target
	var wanted := (target.global_position - global_position).angle()
	reflector.global_rotation = rotate_toward(reflector.global_rotation, wanted, turn_speed * delta)


func _draw() -> void:
	var fill := Color("8fa3b8").lerp(Color.WHITE, _flash)
	draw_circle(Vector2.ZERO, body_radius, fill)
	draw_circle(Vector2.ZERO, body_radius - 7.0, Color("d9e6f2"))
	var frac := clampf(health / max_health, 0.0, 1.0)
	draw_arc(Vector2.ZERO, body_radius - 3.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color("14161c"), 3.0, true)
