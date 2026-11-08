class_name NativeBackend
extends RefCounted
## Typed GDScript facade over the optional C++ `NativeBulletSim` (GDExtension,
## see docs/native.md). When native is opted in, hook-free bullets spawned
## outside a hook come here. Bullets with a per-bullet hook, and anything
## spawned from inside a hook, stay in the GDScript BulletPool. The game default
## is GDScript even if this library is loaded.
##
## All access to the native object goes through this class so the dynamic calls
## (and the matching `unsafe_*` warning exemptions) live in one place.

const CLASS_NAME := &"NativeBulletSim"
## Environment variable consulted when BulletManager's preference is "auto".
## `gdscript` or `native`. Unset stays on the project setting (itself defaulting
## to GDScript). A CLI `--bullet-backend=` wins over this variable.
const ENV_VAR := "SCRIPTSHOT_BULLET_BACKEND"
## Project setting consulted by "auto" when the CLI flag and the env var are
## unset. `gdscript` (default) or `native`.
const SETTING := "scriptshot/bullets/backend"
const CLI_PREFIX := "--bullet-backend="
## One process-wide warning when native was asked for and the extension is not
## loaded. Tests reset the latch to observe it.
static var missing_warned := false
static var missing_warnings := 0
## Bit 62 of a native bullet id, so it is not a BulletPool slot or pool id.
## Pool generations would have to reuse one handle 2^30 times before a pool id
## could set this bit.
const ID_FLAG := 1 << 62

var sim: Object


## True if the GDExtension is loaded in this process.
static func is_available() -> bool:
	return ClassDB.class_exists(CLASS_NAME)


## Backend named by the environment only: "gdscript", "native", or "auto" when
## the variable is unset or unrecognised. Does not read the CLI or the project
## setting. Prefer opted_backend() for the real "auto" resolution.
static func requested_backend() -> String:
	var value := OS.get_environment(ENV_VAR).strip_edges().to_lower()
	return value if value in ["gdscript", "native"] else "auto"


## `--bullet-backend=gdscript|native` from `args`, or "" when the flag is absent
## or the value is not one of those two.
static func cli_backend(args: PackedStringArray) -> String:
	for arg in args:
		if not arg.begins_with(CLI_PREFIX):
			continue
		var value := arg.trim_prefix(CLI_PREFIX).strip_edges().to_lower()
		if value in ["gdscript", "native"]:
			return value
	return ""


static func project_backend() -> String:
	var value := str(ProjectSettings.get_setting(SETTING, "gdscript")).strip_edges().to_lower()
	return value if value in ["gdscript", "native"] else "gdscript"


## What "auto" selects. CLI flag, then the environment variable, then the
## project setting, then GDScript. Off unless one of those says native.
static func opted_backend() -> String:
	var cli := cli_backend(OS.get_cmdline_user_args())
	if cli != "":
		return cli
	var env := OS.get_environment(ENV_VAR).strip_edges().to_lower()
	if env in ["gdscript", "native"]:
		return env
	return project_backend()


## Logs the fallback once per process. The extension missing is not a script
## error: the game keeps running on the GDScript pool.
static func warn_missing() -> void:
	if missing_warned:
		return
	missing_warned = true
	missing_warnings += 1
	push_warning(
		(
			"BulletManager: native bullets were requested but NativeBulletSim is not available;"
			+ " staying on the GDScript backend. Build it with ./tools/build_native.sh."
		)
	)


@warning_ignore_start("unsafe_method_access")


func _init(capacity: int, bounds: Rect2, cell_size: float) -> void:
	sim = ClassDB.instantiate(CLASS_NAME)
	# The speed ceiling lives in BulletLimits. The sim clamps acceleration to it.
	sim.configure(capacity, bounds, cell_size, BulletLimits.MAX_SPEED)


func add_wall(rect: Rect2) -> void:
	sim.add_wall(rect)


func clear_walls() -> void:
	sim.clear_walls()


func set_limits(cap: int, reserve: int) -> void:
	sim.set_limits(cap, reserve)


func set_bounds(rect: Rect2) -> void:
	sim.set_bounds(rect)


## Live bullets in the GDScript pool, counted against the shared cap.
func set_external_count(n: int) -> void:
	sim.set_external_count(n)


func owner_count(layer: int) -> int:
	var n: int = sim.get_owner_count(layer)
	return n


func dropped_for(layer: int) -> int:
	var counts: PackedInt32Array = sim.get_dropped_by_owner()
	var slot := BulletPool.owner_slot(layer)
	return counts[slot] if slot >= 0 and slot < counts.size() else 0


func dropped_by_limit(limit: int) -> int:
	var counts: PackedInt32Array = sim.get_dropped_by_limit()
	return counts[limit] if limit >= 0 and limit < counts.size() else 0


func set_record_events(on: bool) -> void:
	sim.set_record_events(on)


func set_retire_callback(callback: Callable) -> void:
	sim.set_retire_callback(callback)


func pending_hit_count() -> int:
	var n: int = sim.get_pending_hit_count()
	return n


func pending_hit_seqs() -> PackedInt32Array:
	var seqs: PackedInt32Array = sim.get_pending_hit_seqs()
	return seqs


func commit_pending_hit(index: int) -> void:
	sim.commit_pending_hit(index)


func finish_delivery() -> void:
	sim.finish_delivery()


func find_seq(wanted: int) -> int:
	var slot: int = sim.find_seq(wanted)
	return slot


func set_seq_at(slot: int, wanted: int) -> void:
	sim.set_seq_at(slot, wanted)


func export_states() -> Array:
	var rows: Array = sim.export_states()
	return rows


func last_despawns() -> Array:
	var logged: Array = sim.get_last_despawns()
	return logged


## Spawns a plain bullet from a request. Returns a stable id (> 0), or -1 if the
## store is full or the request is non-finite. Finite values outside BulletLimits
## are clamped the same way BulletPool.spawn clamps them (the pool also warns;
## this prototype clamp is silent). The owner's own layer is stripped from
## hit_mask, matching the pool.
func spawn(r: ShotRequest, seq: int) -> int:
	var bad := _non_finite_field(r)
	if bad != "":
		ScriptWarnings.warn("NativeBackend.spawn", "NativeBackend.spawn: rejected a shot with a non-finite %s" % bad)
		return -1
	var velocity := BulletLimits.clamp_velocity(r.velocity)
	var radius := clampf(r.radius, 0.0, BulletLimits.MAX_RADIUS)
	var life := clampf(r.lifetime, 0.0, BulletLimits.MAX_LIFETIME)
	var acc := clampf(r.acceleration, -BulletLimits.MAX_ACCELERATION, BulletLimits.MAX_ACCELERATION)
	var turn := clampf(r.turn_rate, -BulletLimits.MAX_TURN_RATE, BulletLimits.MAX_TURN_RATE)
	var dmg := clampf(r.damage, 0.0, BulletLimits.MAX_DAMAGE)
	var mask := r.hit_mask
	if r.owner_layer != 0:
		mask &= ~r.owner_layer
	var flags := Health.SOURCE_PIERCES_SCRIPT_INVULN if r.pierces_script_invuln else 0
	var id: int = sim.spawn(r.position, velocity, r.angle, life, radius, dmg, mask, r.color, acc, turn, r.pierce,
		r.collide_world, r.owner_layer, flags, seq)
	return id


func _non_finite_field(r: ShotRequest) -> String:
	var p := r.position
	var v := r.velocity
	if is_finite(p.x + p.y + v.x + v.y + r.radius + r.lifetime + r.acceleration + r.turn_rate + r.damage) and not is_inf(r.angle):
		return ""
	if not p.is_finite():
		return "position"
	if not v.is_finite():
		return "velocity"
	if is_inf(r.angle):
		return "angle"
	if not is_finite(r.radius):
		return "radius"
	if not is_finite(r.lifetime):
		return "lifetime"
	if not is_finite(r.acceleration):
		return "acceleration"
	if not is_finite(r.turn_rate):
		return "turn_rate"
	return "damage"


func set_targets(pos: PackedVector2Array, radius: PackedFloat32Array, layer: PackedInt32Array, ids: PackedInt64Array, count: int) -> void:
	sim.set_targets(pos, radius, layer, ids, count)


## One tick: integrate, sweep, compact. Hits stay queued until deliver_hits().
## Returns the number of hurtbox hits.
func step(delta: float) -> int:
	var hits: int = sim.step(delta)
	return hits


## Delivers the hits queued by the last step() (Hurtbox.receive_hit, including
## the native bullet id). Call once after the GDScript collision pass.
func deliver_hits() -> void:
	sim.deliver_hits()


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
