class_name Shieldbearer
extends RegularEnemy
## Room-C Shieldbearer (vertical-slice §3): 60 HP, 70 px/s, wake at 700 px.
## A 120° front arc absorbs (bullet gone, 0 damage) and faces the player
## each frame with no turn cap. Contact is still 1 pip. No idle drift.

const SHIELD_HP := 60.0
const SHIELD_SPEED := 70.0
const SHIELD_RADIUS := 20.0
const SHIELD_FILL := Color("C9A7FF")
const ARC_RADIUS_PAD := 8.0
const ARC_DEG := 120.0
const ARC_ALPHA := 0.4


func enemy_kind() -> StringName:
	return EnemyKinds.SHIELDBEARER


func _apply_stats() -> void:
	body_radius = SHIELD_RADIUS
	_fill = SHIELD_FILL
	health.max_hp = SHIELD_HP
	health.hp = SHIELD_HP
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	_hurtbox.radius = SHIELD_RADIUS
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.active = true
	_hurtbox.response = Hurtbox.Response.ABSORB
	_hurtbox.arc_deg = ARC_DEG


func _move_speed() -> float:
	return SHIELD_SPEED


func _idle(_delta: float) -> void:
	pass


func _physics_process(delta: float) -> void:
	if _alive and player != null and is_instance_valid(player) and _hurtbox != null:
		# No turn cap: snap to the player every frame.
		_hurtbox.face(player.global_position)
	super._physics_process(delta)


func _draw() -> void:
	super._draw()
	if _hurtbox == null:
		return
	var half := deg_to_rad(ARC_DEG * 0.5)
	var from := _hurtbox.facing - half
	var to_ang := _hurtbox.facing + half
	var col := Color(SHIELD_FILL, ARC_ALPHA)
	draw_arc(Vector2.ZERO, SHIELD_RADIUS + ARC_RADIUS_PAD, from, to_ang, 24, col, 3.0, true)
