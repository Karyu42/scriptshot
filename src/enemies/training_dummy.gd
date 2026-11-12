class_name TrainingDummy
extends Node2D
## Stationary target for testing shots: takes damage, flashes, and respawns.

signal destroyed

@export var max_health := 40.0
@export var body_radius := 22.0
@export var respawn_delay := 1.0

var health := 0.0
## Times this instance has died. Its first death reports first_death = true
## to GameEvents.enemy_killed; deaths after a respawn report false.
var deaths := 0

var _flash := 0.0
var _respawn_timer := 0.0

@onready var _hurtbox: Hurtbox = $Hurtbox


func _ready() -> void:
	health = max_health
	_hurtbox.radius = body_radius
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.hit.connect(_on_hit)
	_register_world()


func _enter_tree() -> void:
	# _ready() registers the first time; this covers a dummy moved to another parent.
	if is_node_ready() and health > 0.0:
		_register_world()


func _exit_tree() -> void:
	WorldQuery.unregister_enemy(self)


## Whether this body is a WorldQuery enemy and emits GameEvents.enemy_killed.
## Sandbox subclasses (Turret, Mirror) are not slice enemies and opt out.
func reports_as_enemy() -> bool:
	return true


## Registered while standing (alive); unregistered while it waits to respawn.
func _register_world() -> void:
	if not reports_as_enemy():
		return
	WorldQuery.register_enemy(self, EnemyKinds.DUMMY, EnemyKinds.RARITY_NONE, _tier(), body_radius)
	WorldQuery.set_hp_frac(self, health / max_health if max_health > 0.0 else 1.0)


func _tier() -> int:
	return WorldGen.tier_at(global_position.x, global_position.y)


func _process(delta: float) -> void:
	if _respawn_timer > 0.0:
		_respawn_timer -= delta
		if _respawn_timer <= 0.0:
			health = max_health
			_hurtbox.active = true
			show()
			_register_world()
	_flash = maxf(_flash - delta * 8.0, 0.0)
	queue_redraw()


func _on_hit(damage: float, _hit_position: Vector2, _bullet_velocity: Vector2) -> void:
	if health <= 0.0:
		return
	health -= damage
	_flash = 1.0
	if reports_as_enemy():
		WorldQuery.set_hp_frac(self, health / max_health if max_health > 0.0 else 0.0)
	if health <= 0.0:
		_hurtbox.active = false
		hide()
		_respawn_timer = respawn_delay
		deaths += 1
		WorldQuery.unregister_enemy(self)
		if reports_as_enemy():
			GameEvents.enemy_killed.emit(EnemyKinds.DUMMY, EnemyKinds.RARITY_NONE, _tier(), global_position, deaths == 1)
		destroyed.emit()


func _draw() -> void:
	var fill := Color("ef476f").lerp(Color.WHITE, _flash)
	draw_circle(Vector2.ZERO, body_radius, fill)
	var frac := clampf(health / max_health, 0.0, 1.0)
	draw_arc(Vector2.ZERO, body_radius - 6.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color("14161c"), 4.0, true)
