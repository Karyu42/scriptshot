class_name BulletStressTest
extends Node
## Debug emitter that keeps roughly `target_count` bullets alive using rotating
## spiral emitters, all through the public ShotEmitter interface. Toggle with
## the `toggle_stress` action, cycle the target count with `cycle_stress`.

signal state_changed(enabled: bool, target_count: int)

const LEVELS: Array[int] = [2000, 5000, 10000]

@export var enabled := false
@export var level := 1
@export var bullet_lifetime := 4.0
@export var arms := 6
@export var bullet_speed := 170.0
@export var bullet_radius := 3.0
## World-space centres of the spiral emitters.
@export var origins: PackedVector2Array = [Vector2(-500, -280), Vector2(500, -280), Vector2(-500, 280), Vector2(500, 280)]

var emitter: ShotEmitter

var _angle := 0.0
var _carry := 0.0
var _request := ShotRequest.new()


func get_target_count() -> int:
	return LEVELS[level]


func set_enabled(value: bool) -> void:
	enabled = value
	state_changed.emit(enabled, get_target_count())


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_stress"):
		set_enabled(not enabled)
	elif event.is_action_pressed("cycle_stress"):
		level = (level + 1) % LEVELS.size()
		state_changed.emit(enabled, get_target_count())


func _physics_process(delta: float) -> void:
	if not enabled or emitter == null:
		return
	# Steady-state: spawn rate = alive count / lifetime. Top up if below target.
	var deficit := get_target_count() - emitter.get_bullet_count()
	var want := float(get_target_count()) / bullet_lifetime * delta + _carry
	var spawn_count := mini(int(want), maxi(deficit, 0))
	_carry = want - int(want)
	_request.reset()
	_request.lifetime = bullet_lifetime
	_request.radius = bullet_radius
	_request.hit_mask = Layers.ENEMY
	_request.color = Color("7bdff2")
	for k in spawn_count:
		var origin := origins[k % origins.size()]
		var heading := _angle + TAU * float((k / origins.size()) % arms) / float(arms)
		_request.position = origin
		_request.velocity = Vector2.from_angle(heading) * bullet_speed
		_request.angle = NAN
		emitter.request_shot(_request)
		_angle += 0.071
