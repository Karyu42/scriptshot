class_name ShotRequest
extends RefCounted
## A single bullet to be spawned. This is the data contract between anything
## that wants to fire (the player's weapon today, Lua shot scripts later) and
## the bullet system. See docs/architecture.md.
##
## A request is plain data: it can be created, mutated and re-submitted any
## number of times; the bullet system copies out of it on spawn and never
## keeps a reference.

## World-space spawn position (pixels).
var position := Vector2.ZERO
## Initial velocity in pixels/second.
var velocity := Vector2.ZERO
## Visual orientation in radians. NAN (default) means "face along velocity".
var angle := NAN
## Seconds until the bullet despawns by itself.
var lifetime := 2.0
## Collision + draw radius in pixels.
var radius := 4.0
## Damage passed to Hurtbox.hit when the bullet connects.
var damage := 1.0
## Layers (see Layers) the bullet can hit. 0 = hits nothing (decorative).
var hit_mask := Layers.ENEMY
## Faction that fires the bullet: Layers.PLAYER (default; what scripts shoot
## for) or Layers.ENEMY. The owner's own layer is always removed from hit_mask
## when the bullet spawns, so a bullet can never hurt whoever fired it, whatever
## hit_mask says. 0 = unowned (no stripping).
var owner_layer := Layers.PLAYER
## Flat draw colour.
var color := Color(1.0, 0.82, 0.4)
## Id returned by ShotEmitter.register_behavior(); 0 = plain bullet, no hooks.
var behavior_id := 0
## Acceleration along the current heading in px/s^2 (negative = brake).
var acceleration := 0.0
## Heading change in radians/second (curving bullets). Rotates velocity and
## visual orientation together.
var turn_rate := 0.0
## How many extra targets the bullet passes through before despawning.
var pierce := 0
## Whether the bullet collides with the `world` layer (static walls). On by
## default; turn it off for bullets that should fly through walls. A bullet that
## hits a wall despawns with BulletPool.DespawnReason.WALL.
var collide_world := true
## Free scratch values handed to behaviour hooks (e.g. wave amplitude/phase).
var param_a := 0.0
var param_b := 0.0
## Arbitrary per-bullet script state (any Variant). Stored in the pool's `user`
## array; hooks read and write it as pool.user[index]. The reference is copied,
## not the contents: share or duplicate mutable values yourself. Cleared to null
## when the bullet despawns.
var user: Variant = null


## Request travelling along `heading` (radians) at `speed` (px/s).
static func polar(from: Vector2, heading: float, speed: float) -> ShotRequest:
	var r := ShotRequest.new()
	r.position = from
	r.velocity = Vector2.from_angle(heading) * speed
	return r


## Request with an explicit velocity vector.
static func with_velocity(from: Vector2, vel: Vector2) -> ShotRequest:
	var r := ShotRequest.new()
	r.position = from
	r.velocity = vel
	return r


## Restores every field to its default so one instance can be reused for many
## shots without allocating.
func reset() -> void:
	position = Vector2.ZERO
	velocity = Vector2.ZERO
	angle = NAN
	lifetime = 2.0
	radius = 4.0
	damage = 1.0
	hit_mask = Layers.ENEMY
	owner_layer = Layers.PLAYER
	color = Color(1.0, 0.82, 0.4)
	behavior_id = 0
	acceleration = 0.0
	turn_rate = 0.0
	pierce = 0
	collide_world = true
	param_a = 0.0
	param_b = 0.0
	user = null
