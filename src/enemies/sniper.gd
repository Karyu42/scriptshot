class_name Sniper
extends RegularEnemy
## Room-C Sniper (vertical-slice §3): 20 HP, still, no contact. Every 2.4 s
## (start to start), if the player is within 600 px, a 0.8 s telegraph locks
## a line to the player's position at windup start; the bullet then travels
## that line at 600 px/s for 1 pip. It does not home.

const SNIPER_HP := 20.0
const SNIPER_RADIUS := 14.0
const SNIPER_FILL := Color("FFD166")
const RANGE := 600.0
const PERIOD := 2.4
const WINDUP := 0.8
const SHOT_SPEED := 600.0
const SHOT_DAMAGE := 1.0
const SHOT_RADIUS := 5.0
const SHOT_LIFETIME := 1.2
const SHOT_COLOR := Color("FF5A4D")
const TELEGRAPH_COLOR := Color("FFD166")
const TELEGRAPH_WIDTH := 2.0

## Injected by SlicePacks / tests.
var bullets: BulletManager
## Most recent fire request (for tests), or null if none has fired yet.
var last_shot: ShotRequest
var last_shot_id := -1

var _windup := -1.0
var _cooldown := 0.0
var _lock := Vector2.ZERO


func enemy_kind() -> StringName:
	return EnemyKinds.SNIPER


func is_winding() -> bool:
	return _windup >= 0.0


func lock_point() -> Vector2:
	return _lock


func _apply_stats() -> void:
	body_radius = SNIPER_RADIUS
	_fill = SNIPER_FILL
	health.max_hp = SNIPER_HP
	health.hp = SNIPER_HP
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	_hurtbox.radius = SNIPER_RADIUS
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.active = true
	_hurtbox.response = Hurtbox.Response.NORMAL


func _idle(_delta: float) -> void:
	pass


func _chase(_delta: float, _to_player: Vector2) -> void:
	pass


func _contact(_dist: float) -> void:
	pass


func _physics_process(delta: float) -> void:
	if _alive and player != null and is_instance_valid(player):
		_step_shot(delta)
		_flash = maxf(_flash - delta * 8.0, 0.0)
		queue_redraw()
	last_displacement = global_position - _prev_position
	_prev_position = global_position


func _step_shot(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	if _windup >= 0.0:
		_windup = maxf(_windup - delta, 0.0)
		if _windup <= 0.0:
			_windup = -1.0
			_cooldown = PERIOD - WINDUP
			_fire()
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if _cooldown > 0.0:
		return
	if player.global_position.distance_to(global_position) <= RANGE:
		_lock = player.global_position
		_windup = WINDUP
		queue_redraw()


func _fire() -> void:
	var dir := _lock - global_position
	if dir.length_squared() <= 0.000001:
		dir = Vector2.RIGHT
	else:
		dir = dir.normalized()
	var req := ShotRequest.new()
	req.reset()
	req.position = global_position + dir * (SNIPER_RADIUS + SHOT_RADIUS)
	req.velocity = dir * SHOT_SPEED
	req.lifetime = SHOT_LIFETIME
	req.radius = SHOT_RADIUS
	req.damage = SHOT_DAMAGE
	req.owner_layer = Layers.ENEMY
	req.hit_mask = Layers.hostile_to(Layers.ENEMY)
	req.color = SHOT_COLOR
	req.collide_world = true
	last_shot = req
	last_shot_id = -1
	if bullets != null and is_instance_valid(bullets):
		last_shot_id = bullets.spawn(req)


func _draw() -> void:
	super._draw()
	if _windup < 0.0:
		return
	draw_line(Vector2.ZERO, to_local(_lock), TELEGRAPH_COLOR, TELEGRAPH_WIDTH, true)
