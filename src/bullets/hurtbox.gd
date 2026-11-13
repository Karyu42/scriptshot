class_name Hurtbox
extends Node2D
## Circular damage receiver for the bullet system. Add as a child of anything
## that can be shot; the bullet manager reads every Hurtbox that is in the tree
## and tests it against bullets with a spatial hash (no per-bullet physics nodes).

## Emitted when a bullet connects. `hit_position` is where the bullet touched the
## hurtbox and `bullet_velocity` its velocity at impact (for knockback / hit
## effects).
signal hit(damage: float, hit_position: Vector2, bullet_velocity: Vector2)
## Emitted instead of `hit` when an ABSORB hurtbox swallows a bullet inside its
## arc: no damage, and the bullet despawns as BulletPool.DespawnReason.ABSORBED at
## `hit_position` (even a piercing one). The cue for the absorb tick sound. While
## it is emitted, `last_hit_bullet_id` / `last_hit_flags` describe the bullet.
signal absorbed(hit_position: Vector2, bullet_velocity: Vector2)

## How this hurtbox treats a bullet that touches it.
enum Response {
	## Every contact is a hit. The default, and the only one that costs nothing
	## extra per hit.
	NORMAL,
	## Contacts inside the arc (`facing`, `arc_deg`) are absorbed: no damage, the
	## bullet stops and despawns as ABSORBED. Contacts outside it are normal hits.
	ABSORB,
	## Reserved for the Mirrored affix. Not implemented yet: behaves like NORMAL.
	REFLECT,
}

const GROUP := &"bullet_targets"

## Hit circle radius in pixels.
@export var radius := 16.0
## One of the Layers constants: which faction this hurtbox belongs to. Bullets
## only hit hurtboxes whose layer is in the bullet's hit_mask.
@export_flags_2d_physics var layer := Layers.ENEMY
## Turn off to make the owner temporarily untouchable (i-frames).
@export var active := true

@export_group("Response")
## NORMAL hurtboxes skip the arc test entirely. See Response.
@export var response := Response.NORMAL
## World-space direction the arc is centred on, in radians (0 = +x, east; PI =
## west). Not tied to the node's rotation; turn it with turn_toward() / face().
@export_range(-180.0, 180.0, 0.1, "radians_as_degrees") var facing := 0.0:
	set(value):
		facing = value
		_facing_dir = Vector2.from_angle(value)
## Full opening of the arc in degrees, centred on `facing`. 0 absorbs nothing,
## 360 absorbs every contact. The edges count as inside.
@export_range(0.0, 360.0, 0.1) var arc_deg := 120.0:
	set(value):
		arc_deg = clampf(value, 0.0, 360.0)
		_cos_half_arc = cos(deg_to_rad(arc_deg * 0.5))
@export_group("")

# Cached by the setters so the per-hit test is a dot product and a compare.
var _facing_dir := Vector2.RIGHT
var _cos_half_arc := cos(deg_to_rad(60.0))

## Every hurtbox currently in a scene tree. Kept as a plain array so the bullet
## manager can walk it every tick without allocating (get_nodes_in_group() builds
## a new Array each call).
static var registry: Array[Hurtbox] = []


func _enter_tree() -> void:
	add_to_group(GROUP)
	registry.append(self)


func _exit_tree() -> void:
	registry.erase(self)


## Details of the hit being delivered, valid while the `hit` signal is emitted
## (handlers read them; the signal itself keeps its three arguments):
## the stable id of the bullet (ShotEmitter.is_bullet_alive() takes it) and its
## Health.SOURCE_* flags (e.g. SOURCE_PIERCES_SCRIPT_INVULN), to hand to
## Health.damage(amount, flags).
var last_hit_bullet_id := 0
var last_hit_flags := 0


## True if a bullet touching this hurtbox at `contact` (world space) is absorbed:
## `response` is ABSORB and the direction from the centre to the contact point is
## within arc_deg / 2 of `facing` (edges included). Both bullet backends ask this
## same method, so the GD pool and NativeBulletSim decide identically. They only
## ask when `response` is not NORMAL.
func absorbs(contact: Vector2) -> bool:
	if response != Response.ABSORB:
		return false
	if arc_deg >= 360.0:
		return true
	if arc_deg <= 0.0:
		return false
	var d := contact - global_position
	var dist := d.length()
	if dist <= 0.0:
		# A contact at the centre has no direction; only a full arc covers it.
		return false
	# Small slack so a contact exactly on an edge counts as inside despite rounding.
	return d.dot(_facing_dir) >= (_cos_half_arc - 1e-6) * dist


## Turns `facing` toward the world angle `target` by at most `max_deg_per_s` *
## `delta` degrees along the shorter way, and returns the new facing.
## `max_deg_per_s` <= 0 means no cap: it snaps straight to `target`.
## (Bulwark: common 120 degrees with no cap, rare 150 degrees at 45 degrees/s.)
func turn_toward(target: float, max_deg_per_s: float, delta: float) -> float:
	facing = Hurtbox.turned(facing, target, max_deg_per_s, delta)
	return facing


## turn_toward() aimed at a world point (e.g. the player). A point on the centre
## leaves the facing as it is.
func face(world_point: Vector2, max_deg_per_s: float = 0.0, delta: float = 0.0) -> float:
	var d := world_point - global_position
	if d == Vector2.ZERO:
		return facing
	return turn_toward(d.angle(), max_deg_per_s, delta)


## The turn-rate step on its own: `from` moved toward `to` (radians) by at most
## `max_deg_per_s` * `delta` degrees, the shorter way, wrapped to [-PI, PI].
static func turned(from: float, to: float, max_deg_per_s: float, delta: float) -> float:
	var diff := wrapf(to - from, -PI, PI)
	if max_deg_per_s > 0.0:
		var step := deg_to_rad(max_deg_per_s) * maxf(delta, 0.0)
		diff = clampf(diff, -step, step)
	return wrapf(from + diff, -PI, PI)


## Called by the bullet manager (both backends) for an absorbed bullet.
func receive_absorb(hit_position: Vector2, bullet_velocity: Vector2, bullet_id: int = 0, source_flags: int = 0) -> void:
	last_hit_bullet_id = bullet_id
	last_hit_flags = source_flags
	absorbed.emit(hit_position, bullet_velocity)


## Called by the bullet manager.
func receive_hit(
	damage: float,
	hit_position: Vector2,
	bullet_velocity: Vector2,
	bullet_id: int = 0,
	source_flags: int = 0
) -> void:
	last_hit_bullet_id = bullet_id
	last_hit_flags = source_flags
	hit.emit(damage, hit_position, bullet_velocity)
