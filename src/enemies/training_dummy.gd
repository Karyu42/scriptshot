class_name TrainingDummy
extends Node2D
## Stationary target for testing shots: takes damage, flashes, and respawns.

signal destroyed

@export var max_health := 40.0
@export var body_radius := 22.0
@export var respawn_delay := 1.0

var health := 0.0

var _flash := 0.0
var _respawn_timer := 0.0

@onready var _hurtbox: Hurtbox = $Hurtbox


func _ready() -> void:
	health = max_health
	_hurtbox.radius = body_radius
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.hit.connect(_on_hit)


func _process(delta: float) -> void:
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			health = max_health
			_hurtbox.active = true
			show()
	_flash = maxf(_flash - delta * 8.0, 0.0)
	queue_redraw()


func _on_hit(damage: float, _hit_position: Vector2, _bullet_velocity: Vector2) -> void:
	if health <= 0.0:
		return
	health -= damage
	_flash = 1.0
	if health <= 0.0:
		_hurtbox.active = false
		hide()
		_respawn_timer = respawn_delay
		destroyed.emit()


func _draw() -> void:
	var fill := Color("ef476f").lerp(Color.WHITE, _flash)
	draw_circle(Vector2.ZERO, body_radius, fill)
	var frac := clampf(health / max_health, 0.0, 1.0)
	draw_arc(Vector2.ZERO, body_radius - 6.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color("14161c"), 4.0, true)
