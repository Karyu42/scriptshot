class_name NullAttacks
extends RefCounted
## Shared stamp for Null telegraphs, the Null-shot affix, and legendary Null
## rings. Bodies stay at time_scale_floor 0; telegraphs and shots use
## TimeControl.NULL_TIME_SCALE_FLOOR and pierces_script_invuln.

const TIME_SCALE_FLOOR := TimeControl.NULL_TIME_SCALE_FLOOR
const SHOT_PERIOD := 5.0
const SHOT_TELEGRAPH := 0.8
const SHOT_SPEED := 420.0
const SHOT_RADIUS := 4.0
const SHOT_LIFETIME := 4.0
const SHOT_DAMAGE := 1.0
const RING_DOTS := 16
const RING_RADIUS := 48.0
const RING_SPEED := 180.0
const RING_LIFETIME := 4.0
const RING_BULLET_RADIUS := 5.0


## Marks a caster so its telegraph uses the Null floor and its shots pierce
## script invulnerability. Snipers get both; other nodes with a
## telegraph_time_scale_floor property get the floor.
static func configure_caster(caster: Node) -> void:
	if caster == null or not is_instance_valid(caster):
		return
	if caster is Sniper:
		var sniper := caster as Sniper
		sniper.telegraph_time_scale_floor = TIME_SCALE_FLOOR
		sniper.fires_null_attacks = true
		return
	if "telegraph_time_scale_floor" in caster:
		caster.set("telegraph_time_scale_floor", TIME_SCALE_FLOOR)


static func stamp_shot(req: ShotRequest) -> ShotRequest:
	req.pierces_script_invuln = true
	if req.owner_layer == 0:
		req.owner_layer = Layers.ENEMY
	return req


static func spawn_shot(bullets: BulletManager, origin: Vector2, velocity: Vector2) -> int:
	if bullets == null or not is_instance_valid(bullets):
		return -1
	var req := ShotRequest.new()
	req.reset()
	req.position = origin
	req.velocity = velocity
	req.lifetime = SHOT_LIFETIME
	req.radius = SHOT_RADIUS
	req.damage = SHOT_DAMAGE
	req.owner_layer = Layers.ENEMY
	req.hit_mask = Layers.hostile_to(Layers.ENEMY)
	req.collide_world = true
	stamp_shot(req)
	return bullets.spawn(req)


## Legendary Null / Writ ring. The common Warden fight does not call this.
static func spawn_ring(bullets: BulletManager, origin: Vector2, dots: int = RING_DOTS, speed: float = RING_SPEED) -> PackedInt64Array:
	var ids := PackedInt64Array()
	if bullets == null or not is_instance_valid(bullets) or dots <= 0:
		return ids
	for i in dots:
		var ang := TAU * float(i) / float(dots)
		var pos := origin + Vector2.from_angle(ang) * RING_RADIUS
		var id := spawn_shot(bullets, pos, Vector2.from_angle(ang) * speed)
		if id >= 0:
			ids.append(id)
	return ids
