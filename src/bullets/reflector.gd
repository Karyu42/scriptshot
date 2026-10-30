class_name Reflector
extends Node2D
## A zone that turns bullets around: attach it to any enemy or boss to make a
## mirror, a parry shield or a counter-attack. Bullets of the listed owner
## layers that enter the zone change sides: they become owned by the other
## faction (so a reflected PLAYER bullet can hurt the player and can no longer
## hurt the thing that reflected it), take that faction's colour, and get a new
## velocity according to `mode`.
##
## Cost: reflectors are registered like hurtboxes and bucketed into a spatial hash
## (a HurtboxGrid matched on bullet owner) once per bullet tick, so the work is a
## single swept pass over the bullets however many reflectors exist, and nothing
## at all when there are none. There are no per-bullet nodes. The player's side
## stays script-only (ShotEmitter.reflect_bullet); this is the enemy-side path.
##
## A bullet is reflected when its path crosses the zone while it is moving
## *toward* the reflector (bullets that are leaving, or at rest, pass), and, for
## an arc, through the part of the circle that faces `facing()`.

## What happens to the velocity of a reflected bullet.
enum Mode {
	## Straight back where it came from.
	REVERSE,
	## Bounces off the zone like light off a mirror: reflected across the surface
	## normal at the point of impact (the line from the centre to the impact).
	MIRROR,
	## Sent at `target` from the impact point (falls back to REVERSE while there
	## is no valid target).
	AIM_AT_TARGET,
}

## Emitted for every bullet this reflector reflected. `new_owner` is the layer
## that now owns the bullet.
signal bullet_reflected(bullet_id: int, new_owner: int)

const GROUP := &"reflectors"
## Largest speed multiplier accepted.
const MAX_SPEED_MULTIPLIER := 20.0

## Radius of the zone in pixels. Put it a little outside the body's hurtbox so the
## zone catches bullets before they touch the body.
@export var radius := 40.0
## Size of the reflecting arc in degrees, centred on `facing()` (this node's
## global rotation). 360 (or more) = the whole circle.
@export_range(1.0, 360.0, 1.0) var arc_degrees := 360.0
## Owner layers (Layers.PLAYER / Layers.ENEMY flags) whose bullets are reflected;
## everything else passes through. Default: the player's bullets.
@export_flags_2d_physics var reflects_owners := Layers.PLAYER
@export var mode := Mode.MIRROR
## Speed of the bullet after reflection relative to before (1 = same speed).
## Clamped to [0, MAX_SPEED_MULTIPLIER].
@export var speed_multiplier := 1.0
## Reflect-once guard: a bullet that has already changed owner this many times
## (by any reflector or by a script's reflect_bullet) is not reflected again, so
## two reflectors, or a reflector and a script, cannot ping-pong a bullet
## forever. 1 = once (default, the pillars' rule); 0 = no limit. This zone's own
## limit; scripts calling reflect_bullet() are held to BulletPool.max_reflections.
@export var max_reflections := 1
## Damage a reflected bullet deals: **1** by default, whatever the shooter's script
## gave it (design pillars 5.4; provisional). A negative value keeps the bullet's
## own damage.
@export var reflected_damage := 1.0
## Opt-in: keep the reflected bullet scripted (behaviour hooks, `user` data,
## params and the script-invulnerability flag survive). Off by default: a
## reflected bullet is a plain enemy bullet and its script no longer owns it.
@export var keep_script := false
@export var enabled := true

## Where AIM_AT_TARGET sends bullets. Set by whoever wires the scene.
var target: Node2D
## Total bullets this reflector has reflected.
var reflected_total := 0

## Every reflector currently in a scene tree (plain array: walked every tick by
## the bullet manager without allocating).
static var registry: Array[Reflector] = []


func _enter_tree() -> void:
	add_to_group(GROUP)
	registry.append(self)


func _exit_tree() -> void:
	registry.erase(self)


## Unit vector the arc is centred on.
func facing() -> Vector2:
	return Vector2.RIGHT.rotated(global_rotation)


## True if the reflector takes part in collision right now.
func is_active() -> bool:
	return enabled and reflects_owners != 0 and radius > 0.0 and is_visible_in_tree()


## Called by the bullet manager when bullet `slot` of `pool` touched the zone at
## `impact`. Applies every rule (guard, direction, arc) and, if they pass,
## changes owner / colour / velocity. Returns true if the bullet was reflected.
func reflect_bullet(pool: BulletPool, slot: int, impact: Vector2) -> bool:
	if not is_active() or slot < 0 or slot >= pool.count or pool.dead_reason[slot] != 0:
		return false
	if max_reflections > 0 and pool.reflect_count[slot] >= max_reflections:
		return false
	var from_center := impact - global_position
	var velocity := pool.vel[slot]
	# Only bullets coming in are reflected: leaving or stationary ones pass.
	if velocity.dot(from_center) >= 0.0:
		return false
	if arc_degrees < 360.0 and absf(facing().angle_to(from_center)) > deg_to_rad(arc_degrees) * 0.5:
		return false
	var old_owner := pool.owner_layer[slot]
	var new_owner := Layers.hostile_to(old_owner)
	if new_owner == 0 or not pool.reflect(slot, new_owner, false, reflected_damage, keep_script, max_reflections):
		return false
	var speed := velocity.length() * _safe_multiplier()
	var heading := _new_heading(velocity, from_center, impact)
	pool.vel[slot] = heading * speed
	if speed > 0.0:
		pool.rot[slot] = heading
	# A discontinuous move: pos and prev_pos both at the impact, so the bullet is
	# not swept from its old position (no phantom hits) nor interpolated across.
	pool.teleport(slot, impact)
	reflected_total += 1
	bullet_reflected.emit(pool.id_of(slot), new_owner)
	return true


func _safe_multiplier() -> float:
	if is_nan(speed_multiplier):
		return 1.0
	return clampf(speed_multiplier, 0.0, MAX_SPEED_MULTIPLIER)


## Unit direction of the reflected bullet.
func _new_heading(velocity: Vector2, from_center: Vector2, impact: Vector2) -> Vector2:
	var incoming := velocity.normalized()
	match mode:
		Mode.MIRROR:
			return incoming.bounce(from_center.normalized()).normalized()
		Mode.AIM_AT_TARGET:
			if is_instance_valid(target):
				var to_target := target.global_position - impact
				if to_target.length_squared() > 0.0001:
					return to_target.normalized()
	return -incoming


func _draw() -> void:
	# Debug-friendly shimmer so the zone is visible in the sandbox.
	var colour := Color(0.55, 0.85, 1.0, 0.8)
	if arc_degrees >= 360.0:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 48, colour, 2.0, true)
	else:
		var half := deg_to_rad(arc_degrees) * 0.5
		draw_arc(Vector2.ZERO, radius, -half, half, 32, colour, 3.0, true)
