class_name RegularEnemy
extends Node2D
## T0 regular: a Drifter or one body of a Swarmer group.
## Drawn as a filled circle with a 2 px outline. No shot, no drops.
## Contact with the player's drawn body (radius 14) calls Health.try_damage(1)
## with no pierce flag, so engine i-frames and script invulnerability both block it.
## No contact while the player's centre is inside or on the 512 px disk. The
## whole body stays outside that disk at all times: every step (chase, idle,
## swarmer jitter) slides along the tangent instead of crossing it. There is
## no knockback.

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
## Position delta from the previous physics tick. Zero when the body has not
## moved (or has not ticked yet). SliceLayout eject uses this, not `_heading`,
## because `_heading` stays a unit vector while the enemy is idle.
var last_displacement := Vector2.ZERO
var _prev_position := Vector2.ZERO
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


## Closest a circle of `radius` may sit to the origin without entering the disk.
static func push_centre_outside(pos: Vector2, radius: float) -> Vector2:
	var limit := WorldGen.SAFE_RADIUS + radius
	if pos.length() >= limit:
		return pos
	var dir := Vector2.RIGHT if pos.length_squared() < 0.000001 else pos.normalized()
	return dir * limit


static func push_outside_safe_zone(pos: Vector2, p_archetype: StringName) -> Vector2:
	return push_centre_outside(pos, radius_of(p_archetype))


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
		_prev_position = global_position
		last_displacement = Vector2.ZERO


func is_alive() -> bool:
	return _alive


## Stable kind for GameEvents and WorldQuery (an EnemyKinds constant). Elites,
## the Herald and halves are drifter bodies too; rarity tells them apart.
func enemy_kind() -> StringName:
	return EnemyKinds.SWARMER if archetype == ARCH_SWARMER else EnemyKinds.DRIFTER


## EnemyKinds.RARITY_*. Regulars are not elites: RARITY_NONE.
func enemy_rarity() -> int:
	return EnemyKinds.RARITY_NONE


## World tier of the chunk this body belongs to (WorldGen.chunk_tier).
func enemy_tier() -> int:
	return WorldGen.chunk_tier(chunk.x, chunk.y)


func _ready() -> void:
	# Row 2: regulars and Summoner adds stay out of SliceLayout walls when
	# the ribbon is on, same rule as elites. Off (or no layout): skip the
	# world-layer query.
	collide_walls = _ribbon_has_walls()
	health = get_node("Health") as Health
	_hurtbox = get_node("Hurtbox") as Hurtbox
	_apply_stats()
	_heading = _idle_heading()
	_prev_position = global_position
	last_displacement = Vector2.ZERO
	_hurtbox.hit.connect(_on_hit)
	health.died.connect(_on_died)
	add_to_group(GROUP)
	_ready_done = true
	_register_world()


func _enter_tree() -> void:
	# _ready() registers the first time; this covers a body moved to another parent.
	if _ready_done:
		_register_world()


func _exit_tree() -> void:
	WorldQuery.unregister_enemy(self)


func _register_world() -> void:
	if not _alive:
		return
	WorldQuery.register_enemy(self, enemy_kind(), enemy_rarity(), enemy_tier(), body_radius, health)


func _physics_process(delta: float) -> void:
	if _alive and player != null:
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
	last_displacement = global_position - _prev_position
	_prev_position = global_position


## Drifter 90, Swarmer 140. Elites override this (halves run at 117).
func _move_speed() -> float:
	if archetype == ARCH_SWARMER:
		return SWARMER_SPEED
	return DRIFTER_SPEED


func _chase(delta: float, to_player: Vector2) -> void:
	var step := Vector2.ZERO
	if archetype == ARCH_DRIFTER:
		if to_player.length_squared() > 0.000001:
			_heading = to_player.normalized()
		step = _heading * _move_speed() * delta
	else:
		_erratic_left -= delta
		if _erratic_left <= 0.0:
			_roll_erratic(to_player)
		step = _heading * _move_speed() * delta
	var aim := global_position + _heading
	if player != null:
		aim = player.global_position
	global_position = _keep_off_walls(_slide_outside_disk(global_position, step, aim))


## Heading = direction to the player plus a uniform ±60° from hash_u, re-rolled
## every 0.4 s. The step counter keeps the roll a pure function of the seed.
func _roll_erratic(to_player: Vector2) -> void:
	var u := WorldGen.hash_u(world_seed, chunk.x, chunk.y, encounter_index, member_index, _erratic_step, "err")
	_erratic_step += 1
	_erratic_left = ERRATIC_INTERVAL
	var base := to_player.normalized() if to_player.length_squared() > 0.000001 else _heading
	_heading = base.rotated(deg_to_rad((u * 2.0 - 1.0) * ERRATIC_SPREAD_DEG))


func _idle(delta: float) -> void:
	var step := _heading * IDLE_SPEED * delta
	var proposed := global_position + step
	var from_anchor := proposed - anchor
	if from_anchor.length() > IDLE_RADIUS:
		var outward := from_anchor.normalized()
		_heading = _heading.bounce(outward)
		proposed = anchor + from_anchor.limit_length(IDLE_RADIUS)
		step = proposed - global_position
	global_position = _keep_off_walls(_slide_outside_disk(global_position, step, global_position + _heading))


## When true, after each step the body is pushed out of any `world`-layer
## wall it overlaps (SliceLayout rooms), which also slides it along that wall.
## A step is at most a few px, well under the 4 px gate plus the body radius,
## so it cannot tunnel. `_ready` turns this on when an enabled ribbon is in
## the tree (elites and Summoner adds inherit this).
var collide_walls := false
var _wall_query: PhysicsShapeQueryParameters2D


func _ribbon_has_walls() -> bool:
	if not is_inside_tree():
		return false
	for node: Node in get_tree().get_nodes_in_group(&"slice_layouts"):
		var slice := node as SliceLayout
		if slice != null and slice.enabled:
			return true
	return false


func _keep_off_walls(p: Vector2) -> Vector2:
	if not collide_walls or not is_inside_tree():
		return p
	var space := get_world_2d().direct_space_state
	if space == null:
		return p
	if _wall_query == null or not is_equal_approx((_wall_query.shape as CircleShape2D).radius, body_radius):
		var circle := CircleShape2D.new()
		circle.radius = body_radius
		_wall_query = PhysicsShapeQueryParameters2D.new()
		_wall_query.shape = circle
		_wall_query.collision_mask = Layers.WORLD
		_wall_query.collide_with_areas = false
	var out := p
	for _i in 4:
		_wall_query.transform = Transform2D(0.0, out)
		var info := space.get_rest_info(_wall_query)
		if info.is_empty():
			break
		var contact: Vector2 = info["point"]
		var normal: Vector2 = info["normal"]
		if normal.length_squared() <= 0.000001:
			break
		var depth := body_radius - (out - contact).dot(normal)
		if depth <= 0.0:
			break
		out += normal * (depth + 0.01)
	return out


## One step that is not allowed to enter the disk of radius 512 + body radius.
## A step that would enter keeps its length and turns onto the tangent, so a
## chase routes around the rim instead of stopping or cutting through. The
## side is the one the step already leans toward; a head-on step uses `aim`
## and then a stable counterclockwise tie-break.
func _slide_outside_disk(current: Vector2, step: Vector2, aim: Vector2) -> Vector2:
	var limit := WorldGen.SAFE_RADIUS + body_radius
	if step.length_squared() <= 0.0000001:
		if current.length() >= limit:
			return current
		if current.length_squared() <= 0.000001:
			return Vector2(limit, 0.0)
		return current.normalized() * limit
	var dest := current + step
	if not _segment_enters_disk(current, dest, limit):
		return dest
	var radial := current
	if radial.length_squared() <= 0.000001:
		radial = Vector2.RIGHT
	radial = radial.normalized()
	var tangent := Vector2(-radial.y, radial.x)
	var side := radial.cross(step)
	if absf(side) <= 0.000001:
		side = radial.cross(aim - current)
	if absf(side) <= 0.000001:
		side = 1.0
	if side < 0.0:
		tangent = -tangent
	var slid := current + tangent * step.length()
	if slid.length() < limit:
		slid = slid.normalized() * limit
	return slid


func _segment_enters_disk(a: Vector2, b: Vector2, limit: float) -> bool:
	if a.length() < limit or b.length() < limit:
		return true
	var ab := b - a
	var denom := ab.length_squared()
	if denom <= 0.0000001:
		return false
	var t := clampf(-a.dot(ab) / denom, 0.0, 1.0)
	return (a + ab * t).length() < limit


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
	WorldQuery.unregister_enemy(self)
	GameEvents.enemy_killed.emit(enemy_kind(), enemy_rarity(), enemy_tier(), global_position, true)
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
