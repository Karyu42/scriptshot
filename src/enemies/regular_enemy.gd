class_name RegularEnemy
extends Node2D
## T0 regular: a Drifter or one body of a Swarmer group.
## Drawn as a filled circle with a 2 px outline. No shot, no drops.
## Contact with the player's drawn body (radius 14) calls Health.try_damage(1)
## with no pierce flag, so engine i-frames and script invulnerability both block it.
## No contact while the player's centre is inside or on the 512 px disk. A body
## never overlaps that disk while the player is still inside: its centre stays
## at least 512 px plus its own radius out.

signal died

const GROUP := &"hostiles"
const ARCH_DRIFTER := &"drifter"
const ARCH_SWARMER := &"swarmer"

const DRIFTER_HP := 30.0
const SWARMER_HP := 6.0
const DRIFTER_SPEED := 90.0
const SWARMER_SPEED := 140.0
const DRIFTER_RADIUS := 16.0
const SWARMER_RADIUS := 8.0
const IDLE_SPEED := 40.0
const IDLE_RADIUS := 96.0
const ERRATIC_INTERVAL := 0.4
const ERRATIC_SPREAD_DEG := 60.0
const PLAYER_RADIUS := 14.0
const CONTACT_DAMAGE := 1.0
const DRIFTER_FORMATION := 22.0
const SWARMER_FORMATION := 36.0
const OUTLINE_WIDTH := 2.0
const OUTLINE_COLOR := Color("E7E9EE")
const DRIFTER_FILL := Color("7DA2FF")
const SWARMER_FILL := Color("7DE0C3")
const ARC_POINTS := 32

var archetype := ARCH_DRIFTER
var anchor := Vector2.ZERO
var world_seed := 0
var chunk := Vector2i.ZERO
var encounter_index := 0
var member_index := 0
var player: Node2D
var woken := false

var health: Health
var body_radius := DRIFTER_RADIUS

var _hurtbox: Hurtbox
var _fill := DRIFTER_FILL
var _heading := Vector2.RIGHT
var _erratic_left := 0.0
var _erratic_step := 0
var _alive := true
var _flash := 0.0
var _ready_done := false


static func radius_of(p_archetype: StringName) -> float:
	return SWARMER_RADIUS if p_archetype == ARCH_SWARMER else DRIFTER_RADIUS


## Closest a body's centre may sit to the origin without the circle crossing
## into the 512 px disk.
static func safe_centre_limit(p_archetype: StringName) -> float:
	return WorldGen.SAFE_RADIUS + radius_of(p_archetype)


static func spawn_position(p_anchor: Vector2, p_archetype: StringName, index: int, count: int) -> Vector2:
	var pos := p_anchor + formation_offset(p_archetype, index, count)
	return push_outside_safe_zone(pos, p_archetype)


static func formation_offset(p_archetype: StringName, index: int, count: int) -> Vector2:
	if count <= 1:
		return Vector2.ZERO
	var ring := SWARMER_FORMATION if p_archetype == ARCH_SWARMER else DRIFTER_FORMATION
	return Vector2.from_angle(TAU * float(index) / float(count)) * ring


static func push_outside_safe_zone(pos: Vector2, p_archetype: StringName) -> Vector2:
	var limit := safe_centre_limit(p_archetype)
	if pos.length() >= limit:
		return pos
	var dir := Vector2.RIGHT if pos.length_squared() < 0.000001 else pos.normalized()
	return dir * limit


func configure(
	p_archetype: StringName,
	p_anchor: Vector2,
	p_spawn: Vector2,
	p_seed: int,
	p_chunk: Vector2i,
	p_encounter: int,
	p_member: int,
	p_player: Node2D,
) -> void:
	archetype = p_archetype
	anchor = p_anchor
	position = p_spawn
	world_seed = p_seed
	chunk = p_chunk
	encounter_index = p_encounter
	member_index = p_member
	player = p_player
	if _ready_done:
		_apply_stats()
		_heading = _idle_heading()


func is_alive() -> bool:
	return _alive


func _ready() -> void:
	health = get_node("Health") as Health
	_hurtbox = get_node("Hurtbox") as Hurtbox
	_apply_stats()
	_heading = _idle_heading()
	_hurtbox.hit.connect(_on_hit)
	health.died.connect(_on_died)
	add_to_group(GROUP)
	_ready_done = true


func _physics_process(delta: float) -> void:
	if not _alive or player == null:
		return
	var to_player := player.global_position - global_position
	var dist := to_player.length()
	if not woken and dist <= WorldGen.WAKE_RADIUS:
		woken = true
		_erratic_left = 0.0
	if woken:
		_chase(delta, to_player)
	else:
		_idle(delta)
	_contact(player.global_position.distance_to(global_position))
	_flash = maxf(_flash - delta * 8.0, 0.0)
	queue_redraw()


func _chase(delta: float, to_player: Vector2) -> void:
	if archetype == ARCH_DRIFTER:
		if to_player.length_squared() > 0.000001:
			_heading = to_player.normalized()
		global_position = _clamp_chase(global_position + _heading * DRIFTER_SPEED * delta)
	else:
		_erratic_left -= delta
		if _erratic_left <= 0.0:
			_roll_erratic(to_player)
		global_position = _clamp_chase(global_position + _heading * SWARMER_SPEED * delta)


## Heading = direction to the player plus a uniform ±60° from hash_u, re-rolled
## every 0.4 s. The step counter keeps the roll a pure function of the seed.
func _roll_erratic(to_player: Vector2) -> void:
	var u := WorldGen.hash_u(world_seed, chunk.x, chunk.y, encounter_index, member_index, _erratic_step, "err")
	_erratic_step += 1
	_erratic_left = ERRATIC_INTERVAL
	var base := to_player.normalized() if to_player.length_squared() > 0.000001 else _heading
	_heading = base.rotated(deg_to_rad((u * 2.0 - 1.0) * ERRATIC_SPREAD_DEG))


func _idle(delta: float) -> void:
	var next := global_position + _heading * IDLE_SPEED * delta
	var from_anchor := next - anchor
	if from_anchor.length() > IDLE_RADIUS:
		var outward := from_anchor.normalized()
		_heading = _heading.bounce(outward)
		next = anchor + from_anchor.limit_length(IDLE_RADIUS)
	next = _hold_outside_disk(next, true)
	global_position = next


## While the player's centre is still inside the safe disk, a chase stops where
## the body is tangent to the disk. Once the player is strictly outside, the
## chase may cross it.
func _clamp_chase(next: Vector2) -> Vector2:
	if player != null and player.global_position.length() > WorldGen.SAFE_RADIUS:
		return next
	return _hold_outside_disk(next, false)


func _hold_outside_disk(next: Vector2, reflect_heading: bool) -> Vector2:
	var limit := WorldGen.SAFE_RADIUS + body_radius
	if next.length() >= limit:
		return next
	var away := Vector2.RIGHT if next.length_squared() < 0.000001 else next.normalized()
	if reflect_heading:
		_heading = _heading.bounce(away)
	return away * limit


func _contact(dist: float) -> void:
	if player == null or player.global_position.length() <= WorldGen.SAFE_RADIUS:
		return
	if dist > PLAYER_RADIUS + body_radius:
		return
	var body := player as Player
	if body == null or body.health == null:
		return
	# No pierce flag: SOURCE_PIERCES_SCRIPT_INVULN is not set. Engine i-frames
	# and script invulnerability still apply once the player is outside.
	body.health.try_damage(CONTACT_DAMAGE)


func _on_hit(amount: float, _hit_position: Vector2, _bullet_velocity: Vector2) -> void:
	if not _alive or health == null:
		return
	health.damage(amount, _hurtbox.last_hit_flags)
	_flash = 1.0


func _on_died() -> void:
	if not _alive:
		return
	_alive = false
	_hurtbox.active = false
	died.emit()
	hide()
	queue_free()


func _apply_stats() -> void:
	var swarmer := archetype == ARCH_SWARMER
	body_radius = SWARMER_RADIUS if swarmer else DRIFTER_RADIUS
	_fill = SWARMER_FILL if swarmer else DRIFTER_FILL
	var hp := SWARMER_HP if swarmer else DRIFTER_HP
	health.max_hp = hp
	health.hp = hp
	# Player i-frames and regen stay on the player's Health. A regular has
	# neither: every bullet that connects deals its damage.
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	_hurtbox.radius = body_radius
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.active = true


func _idle_heading() -> Vector2:
	var u := WorldGen.hash_u(world_seed, chunk.x, chunk.y, encounter_index, member_index, "idle")
	return Vector2.from_angle(u * TAU)


func _draw() -> void:
	draw_circle(Vector2.ZERO, body_radius, _fill.lerp(Color.WHITE, _flash))
	draw_arc(Vector2.ZERO, body_radius, 0.0, TAU, ARC_POINTS, OUTLINE_COLOR, OUTLINE_WIDTH, true)
