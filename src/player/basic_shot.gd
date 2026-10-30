class_name BasicShot
extends ShotPattern
## The default player weapon: one fast bullet straight along the aim direction.
## Doubles as the smallest possible example of a shot script.

var speed := 760.0
var bullet_lifetime := 1.3
var bullet_radius := 4.0
var bullet_damage := 1.0
var bullet_color := Color("ffd166")

var _request := ShotRequest.new()


func _init() -> void:
	fire_interval = 0.11


func fire(context: ShotContext, emitter: ShotEmitter) -> void:
	_request.reset()
	_request.position = context.muzzle_position
	_request.velocity = context.aim_direction * speed + context.shooter_velocity * 0.15
	_request.angle = context.aim_angle
	_request.lifetime = bullet_lifetime
	_request.radius = bullet_radius
	_request.damage = bullet_damage
	_request.color = bullet_color
	_request.hit_mask = context.target_mask
	emitter.request_shot(_request)
