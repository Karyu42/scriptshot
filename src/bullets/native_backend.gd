class_name NativeBackend
extends RefCounted
## Typed GDScript facade over the optional C++ `NativeBulletSim` (GDExtension,
## see docs/native.md). BulletManager sends every plain bullet (no
## BulletBehavior hook) here when the extension is loaded; bullets with hooks stay
## in the GDScript BulletPool.
##
## All access to the native object goes through this class so the dynamic calls
## (and the matching `unsafe_*` warning exemptions) live in one place.

const CLASS_NAME := &"NativeBulletSim"
## Environment variable that forces the bullet backend: `gdscript`, `native` or
## `auto` (default: native if the extension is loaded).
const ENV_VAR := "SCRIPTSHOT_BULLET_BACKEND"

var sim: Object


## True if the GDExtension is loaded in this process.
static func is_available() -> bool:
	return ClassDB.class_exists(CLASS_NAME)


## Backend requested by the environment: "auto", "gdscript" or "native".
static func requested_backend() -> String:
	var value := OS.get_environment(ENV_VAR).strip_edges().to_lower()
	return value if value in ["gdscript", "native"] else "auto"


@warning_ignore_start("unsafe_method_access")


func _init(capacity: int, bounds: Rect2, cell_size: float) -> void:
	sim = ClassDB.instantiate(CLASS_NAME)
	sim.configure(capacity, bounds, cell_size)


func add_wall(rect: Rect2) -> void:
	sim.add_wall(rect)


func clear_walls() -> void:
	sim.clear_walls()


## Spawns a plain bullet from a request. Returns a stable id (> 0) or -1 if full.
func spawn(r: ShotRequest) -> int:
	var id: int = sim.spawn(r.position, r.velocity, r.angle, r.lifetime, r.radius, r.damage, r.hit_mask, r.color,
		r.acceleration, r.turn_rate, r.pierce, r.collide_world)
	return id


func set_targets(pos: PackedVector2Array, radius: PackedFloat32Array, layer: PackedInt32Array, ids: PackedInt64Array, count: int) -> void:
	sim.set_targets(pos, radius, layer, ids, count)


## Runs one tick (integrate, sweep, compact) and delivers the hits to the
## hurtboxes. Returns the number of hurtbox hits.
func step(delta: float) -> int:
	var hits: int = sim.step(delta)
	return hits


func upload(multimesh: RID, allocated: int, interpolate: bool, stretch: float) -> int:
	var n: int = sim.upload(multimesh, allocated, interpolate, stretch)
	return n


func count() -> int:
	var n: int = sim.get_count()
	return n


func capacity() -> int:
	var n: int = sim.get_capacity()
	return n


func spawned_total() -> int:
	var n: int = sim.get_spawned_total()
	return n


func dropped_total() -> int:
	var n: int = sim.get_dropped_total()
	return n


func last_wall_hit_count() -> int:
	var n: int = sim.get_last_wall_hit_count()
	return n


func is_alive(id: int) -> bool:
	var alive: bool = sim.is_alive(id)
	return alive


func kill(id: int) -> bool:
	var killed: bool = sim.kill(id)
	return killed


func clear() -> void:
	sim.clear()


## Dense copy of the alive bullets: pos, prev_pos, vel, age, lifetime, radius,
## pierce, id (for tests and parity checks).
func snapshot() -> Dictionary:
	var d: Dictionary = sim.snapshot()
	return d


func despawn_counts() -> PackedInt32Array:
	var c: PackedInt32Array = sim.get_despawn_counts()
	return c
