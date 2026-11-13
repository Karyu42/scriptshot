class_name TrainingDummy
extends Node2D
## Stationary target for testing shots: takes damage, flashes, and respawns.

signal destroyed

@export var max_health := 40.0
@export var body_radius := 22.0
@export var respawn_delay := 1.0
## Room A: 120° absorb arc (west, toward the door). Off for the origin dummies.
@export var absorb := false
@export var absorb_facing := PI
@export var absorb_arc_deg := 120.0
## Room B: when >= 0, the hurtbox is only on while observed player HP is
## at most this (lesson 4: 4.0). -1 leaves the hurtbox under death/respawn.
@export var hurtbox_hp_cap := -1.0

var health := 0.0
## Times this instance has died. Its first death reports first_death = true
## to GameEvents.enemy_killed; deaths after a respawn report false.
var deaths := 0
var observed_player_hp := 5.0

var _flash := 0.0
var _respawn_timer := 0.0

@onready var _hurtbox: Hurtbox = $Hurtbox


func _ready() -> void:
	health = max_health
	_hurtbox.radius = body_radius
	_hurtbox.layer = Layers.ENEMY
	if absorb:
		_hurtbox.response = Hurtbox.Response.ABSORB
		_hurtbox.facing = absorb_facing
		_hurtbox.arc_deg = absorb_arc_deg
	_hurtbox.hit.connect(_on_hit)
	_register_world()
	_sync_hurtbox()


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
			show()
			_register_world()
			_sync_hurtbox()
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
		hide()
		_respawn_timer = respawn_delay
		_sync_hurtbox()
		deaths += 1
		WorldQuery.unregister_enemy(self)
		if reports_as_enemy():
			GameEvents.enemy_killed.emit(EnemyKinds.DUMMY, EnemyKinds.RARITY_NONE, _tier(), global_position, deaths == 1)
		destroyed.emit()


func set_observed_player_hp(hp: float) -> void:
	observed_player_hp = hp
	_sync_hurtbox()


func _sync_hurtbox() -> void:
	if _hurtbox == null:
		return
	if health <= 0.0:
		_hurtbox.active = false
		return
	if hurtbox_hp_cap >= 0.0:
		_hurtbox.active = observed_player_hp <= hurtbox_hp_cap
		return
	_hurtbox.active = _respawn_timer <= 0.0


func _draw() -> void:
	var fill := Color("ef476f").lerp(Color.WHITE, _flash)
	if hurtbox_hp_cap >= 0.0 and (health <= 0.0 or not _hurtbox.active):
		fill = Color("6b7280")
	draw_circle(Vector2.ZERO, body_radius, fill)
	var frac := clampf(health / max_health, 0.0, 1.0)
	draw_arc(Vector2.ZERO, body_radius - 6.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, Color("14161c"), 4.0, true)
	if absorb:
		# Open side cue: the absorbed west-facing wedge is a darker arc.
		var half := deg_to_rad(absorb_arc_deg * 0.5)
		var start := absorb_facing - half
		draw_arc(Vector2.ZERO, body_radius + 3.0, start, start + deg_to_rad(absorb_arc_deg), 24, Color("14161c"), 3.0, true)
