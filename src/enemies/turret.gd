class_name Turret
extends TrainingDummy
## Stationary enemy that shoots aimed bullets at a target in range. Its bullets
## only hit the player (hit_mask = Layers.hostile_to(ENEMY)), never other
## enemies: no friendly fire. Uses the ShotEmitter interface like any shooter.

@export var fire_interval := 1.1
@export var shot_speed := 260.0
@export var shot_range := 700.0
@export var shot_damage := 1.0

## Injected by Main.
var emitter: ShotEmitter
var target: Node2D

var _timer := 0.0
var _request := ShotRequest.new()


func _physics_process(delta: float) -> void:
	if health <= 0.0 or emitter == null or target == null:
		return
	_timer -= delta
	var to_target := target.global_position - global_position
	if _timer > 0.0 or to_target.length() > shot_range:
		return
	_timer = fire_interval
	_request.reset()
	_request.position = global_position + to_target.normalized() * (body_radius + 6.0)
	_request.velocity = to_target.normalized() * shot_speed
	_request.lifetime = 4.0
	_request.radius = 5.0
	_request.damage = shot_damage
	_request.hit_mask = Layers.hostile_to(Layers.ENEMY)
	_request.color = Color("ff6b8b")
	emitter.request_shot(_request)
