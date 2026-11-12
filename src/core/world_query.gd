extends Node
## Autoload `WorldQuery`: read-only questions about the world for scripts
## (Senses) and game code, plus the enemy registry they are answered from.
##
## Lifetime rules (#50): every result is plain data, Dictionaries and Arrays of
## ints, floats, bools, StringNames and Vector2s. No Node, Object or Callable
## is ever returned, so a script may keep a result as long as it likes. Ids are
## the body's instance id as an int; feed them back through `exclude` as they are.
##
## Consistency: answers come from a snapshot taken once per physics tick, at
## PHYSICS_PRIORITY, which is after enemies and the player move (priority 0) and
## before BulletManager steps the bullets and runs their hooks (priority 100).
## Every query in a tick sees the same positions, even if bodies move later in
## that tick. A body registered mid-tick shows up in the next snapshot. A body
## that died (unregistered) or was freed after the snapshot is skipped at query
## time, so the answer is always a living candidate (§6.2); the positions of the
## others stay frozen. Code that runs before PHYSICS_PRIORITY (the player's
## weapon at 0) sees the previous tick's positions. All positions are world space.
##
## Registry: an enemy calls register_enemy() when it enters the tree and
## unregister_enemy() when it dies or leaves. A boss registers with
## is_boss = true and a boss-state provider; see register_enemy().
##
## Range limit: while a BulletManager is bound (Main binds its own), only bodies
## inside its world_bounds (the live hurtbox-grid window around the camera) are
## in the snapshot, the same bodies HurtboxGrid.query_radius() can see. That
## window is the only range limit; there is no gameplay cap on calls. The window
## is the one BulletManager used last tick: it recentres on the camera in its own
## step() (priority 100, after this snapshot), so it lags camera motion by one
## physics frame.

## After enemies (0), before BulletManager (BulletManager.PHYSICS_PRIORITY = 100).
const PHYSICS_PRIORITY := 90
## enemies_in_radius() returns at most this many entries (api.md limits).
const MAX_RESULTS := 256


## One registered body. Holds the node for the snapshot only; never handed out.
class Entry:
	extends RefCounted
	var id := 0
	var body: Node2D
	var health: Health
	var kind := StringName()
	var rarity := EnemyKinds.RARITY_NONE
	var tier := 0
	var radius := 0.0
	## Used when `health` is null (a body that keeps hp itself, e.g. TrainingDummy).
	var hp_frac := 1.0
	var is_boss := false
	var boss_state: Callable


var _entries: Dictionary[int, Entry] = {}
## Snapshot columns, parallel, one row per registered body.
var _ids := PackedInt64Array()
var _pos := PackedVector2Array()
var _vel := PackedVector2Array()
var _hp := PackedFloat32Array()
var _radius := PackedFloat32Array()
var _kind: Array[StringName] = []
var _rarity := PackedInt32Array()
var _tier := PackedInt32Array()
var _boss := PackedByteArray()
## Row of the first registered boss in the snapshot, -1 when there is none.
var _boss_row := -1
## Last snapshot position per id, for the velocity estimate.
var _last_pos: Dictionary[int, Vector2] = {}
var _snapshots := 0
var _bullets: BulletManager


func _init() -> void:
	process_physics_priority = PHYSICS_PRIORITY


func _physics_process(delta: float) -> void:
	refresh(delta)


# --- registry ------------------------------------------------------------------

## Adds `body` to the registry (or updates it if already there) and returns its
## id. `radius` is the body's radius in px. `health` may be null: hp_frac then
## reads what set_hp_frac() last stored (1.0 by default). A boss passes is_boss and a
## `boss_state` provider: a Callable taking no arguments that returns a plain
## Dictionary with at least `phase` (int), `phase_count` (int) and `weak_points`
## (Array of plain data, e.g. [{pos, hp_frac}]). WorldQuery adds id, kind,
## hp_frac and pos itself. The provider is called once per snapshot.
func register_enemy(
	body: Node2D,
	kind: StringName,
	rarity: int,
	tier: int,
	radius: float,
	health: Health = null,
	is_boss: bool = false,
	boss_state: Callable = Callable(),
) -> int:
	var id := body.get_instance_id()
	var e: Entry = _entries.get(id, null)
	if e == null:
		e = Entry.new()
		e.id = id
		_entries[id] = e
	e.body = body
	e.health = health
	e.kind = kind
	e.rarity = rarity
	e.tier = tier
	e.radius = radius
	e.is_boss = is_boss
	e.boss_state = boss_state
	return id


## hp fraction for a body registered without a Health (clamped to 0..1).
func set_hp_frac(body: Node2D, frac: float) -> void:
	var e: Entry = _entries.get(body.get_instance_id(), null)
	if e != null and not is_nan(frac):
		e.hp_frac = clampf(frac, 0.0, 1.0)


## Removes `body` from the registry. Safe to call twice or for a body that never
## registered. The current snapshot is not changed (see the class comment).
func unregister_enemy(body: Node2D) -> void:
	var id := body.get_instance_id()
	_entries.erase(id)
	_last_pos.erase(id)


func is_registered(body: Node2D) -> bool:
	return _entries.has(body.get_instance_id())


## True while the body with instance id `id` is registered (works after it was freed).
func has_id(id: int) -> bool:
	return _entries.has(id)


func registered_count() -> int:
	return _entries.size()


## Forgets every registered body and the snapshot (tests, a new run).
func reset() -> void:
	_entries.clear()
	_last_pos.clear()
	_clear_snapshot()


## Gives raycast_terrain() the walls of this manager. Main binds its manager.
func bind_bullets(manager: BulletManager) -> void:
	_bullets = manager


## Drops the binding, but only if `manager` is the bound one (a second scene
## leaving the tree does not unbind the first).
func unbind_bullets(manager: BulletManager) -> void:
	if _bullets == manager:
		_bullets = null


# --- snapshot ------------------------------------------------------------------

## Rebuilds the snapshot from the registry. Called every physics tick; tests and
## tools may call it directly. `delta` is used for the velocity estimate.
func refresh(delta: float = 1.0 / 60.0) -> void:
	_clear_snapshot()
	_snapshots += 1
	var gone: Array[int] = []
	var seen: Dictionary[int, Vector2] = {}
	var windowed := _bullets != null and is_instance_valid(_bullets)
	var window := _bullets.world_bounds if windowed else Rect2()
	for id: int in _entries:
		var e: Entry = _entries[id]
		if not is_instance_valid(e.body) or not e.body.is_inside_tree():
			gone.append(id)
			continue
		var p := e.body.global_position
		if windowed and not window.has_point(p):
			continue
		var v := Vector2.ZERO
		if delta > 0.0 and _last_pos.has(id):
			v = (p - _last_pos[id]) / delta
		seen[id] = p
		_ids.append(id)
		_pos.append(p)
		_vel.append(v)
		_hp.append(_hp_frac(e.health) if e.health != null else e.hp_frac)
		_radius.append(e.radius)
		_kind.append(e.kind)
		_rarity.append(e.rarity)
		_tier.append(e.tier)
		_boss.append(1 if e.is_boss else 0)
		if e.is_boss and _boss_row < 0:
			_boss_row = _ids.size() - 1
	for id in gone:
		_entries.erase(id)
	_last_pos = seen


## How many snapshots have been taken (tests).
func snapshot_count() -> int:
	return _snapshots


## Bodies in the current snapshot.
func snapshot_size() -> int:
	return _ids.size()


# --- queries -------------------------------------------------------------------

## Closest enemy to `pos` within `max_range` (inclusive), skipping ids in
## `exclude`, or {} when there is none. Returns {id, pos, vel, hp_frac, kind,
## radius, rarity, tier, is_boss}. `exclude` takes a PackedInt64Array, a
## PackedInt32Array or an Array of ints (the ids as returned; integer-valued
## floats are accepted too). Ties on distance go to the lower id.
func nearest_enemy(pos: Vector2, max_range: float, exclude: Variant = PackedInt64Array()) -> Dictionary:
	if not pos.is_finite() or is_nan(max_range) or max_range < 0.0:
		return {}
	var skip := _exclude_set(exclude)
	var limit := max_range * max_range
	var best := -1
	var best_d := INF
	for row in _ids.size():
		var d := pos.distance_squared_to(_pos[row])
		if d > limit:
			continue
		if not skip.is_empty() and skip.has(_ids[row]):
			continue
		if not _alive(row):
			continue
		if d < best_d or (d == best_d and _ids[row] < _ids[best]):
			best = row
			best_d = d
	if best < 0:
		return {}
	return _row_dict(best)


## Enemies within `r` of `pos` (inclusive), nearest first (ties: lower id
## first), at most `cap` of them; cap is clamped to 1..MAX_RESULTS. Each entry
## has the nearest_enemy() shape.
func enemies_in_radius(pos: Vector2, r: float, cap: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not pos.is_finite() or is_nan(r) or r < 0.0:
		return out
	var n := clampi(cap, 1, MAX_RESULTS)
	var limit := r * r
	var rows: Array[int] = []
	var dist := PackedFloat64Array()
	dist.resize(_ids.size())
	for row in _ids.size():
		var d := pos.distance_squared_to(_pos[row])
		dist[row] = d
		if d <= limit and _alive(row):
			rows.append(row)
	var ids := _ids
	rows.sort_custom(func(a: int, b: int) -> bool:
		if dist[a] != dist[b]:
			return dist[a] < dist[b]
		return ids[a] < ids[b]
	)
	for k in mini(n, rows.size()):
		out.append(_row_dict(rows[k]))
	return out


## The registered boss, or {} when there is none (or it died after the
## snapshot): {id, kind, phase, phase_count, hp_frac, pos, weak_points}.
## phase / phase_count / weak_points come from the boss's provider and are
## rebuilt as plain data: phase and phase_count as ints (phase_count >= 1),
## weak_points as an Array of {pos: Vector2, radius: float, open: bool}. A weak
## point that is not a Dictionary with a Vector2 `pos` is dropped; nothing the
## provider returns is passed through. A missing provider or a non-Dictionary
## answer reads as phase 0 of 1 with no weak points.
func boss_state() -> Dictionary:
	if _boss_row < 0 or not _alive(_boss_row):
		return {}
	var id := _ids[_boss_row]
	var state: Dictionary = {}
	var e: Entry = _entries.get(id, null)
	if e != null and e.boss_state.is_valid():
		var got: Variant = e.boss_state.call()
		if got is Dictionary:
			@warning_ignore("unsafe_cast")
			state = got as Dictionary
	var phase := _as_int(state.get("phase", 0), 0)
	var phase_count := maxi(_as_int(state.get("phase_count", 1), 1), 1)
	var weak: Array[Dictionary] = []
	var weak_v: Variant = state.get("weak_points", [])
	if weak_v is Array:
		@warning_ignore("unsafe_cast")
		for item: Variant in weak_v as Array:
			var wp := _weak_point(item)
			if not wp.is_empty():
				weak.append(wp)
	return {
		"id": id,
		"kind": _kind[_boss_row],
		"phase": phase,
		"phase_count": phase_count,
		"hp_frac": _hp[_boss_row],
		"pos": _pos[_boss_row],
		"weak_points": weak,
	}


## First wall the segment `from` -> `to` touches, or {}: {pos, normal,
## distance}. Uses the walls of the bound BulletManager (bullet walls, the same
## rectangles bullets stop at). {} when no manager is bound or it has no walls.
## A segment that starts inside a wall hits at `from` (distance 0).
func raycast_terrain(from: Vector2, to: Vector2) -> Dictionary:
	if _bullets == null or not is_instance_valid(_bullets) or _bullets.walls == null:
		return {}
	if not from.is_finite() or not to.is_finite():
		return {}
	var walls := _bullets.walls
	var d := to - from
	# first_hit() overwrites last_normal; keep the manager's value as it was.
	var kept := walls.last_normal
	var t := walls.first_hit(from, d, 0.0)
	var normal := walls.last_normal
	walls.last_normal = kept
	if t < 0.0:
		return {}
	return {"pos": from + d * t, "normal": normal, "distance": d.length() * t}


# --- internals -----------------------------------------------------------------

func _row_dict(row: int) -> Dictionary:
	return {
		"id": _ids[row],
		"pos": _pos[row],
		"vel": _vel[row],
		"radius": _radius[row],
		"hp_frac": _hp[row],
		"kind": _kind[row],
		"rarity": _rarity[row],
		"tier": _tier[row],
		"is_boss": _boss[row] != 0,
	}


## Snapshot row `row` still belongs to a registered, live body.
func _alive(row: int) -> bool:
	var e: Entry = _entries.get(_ids[row], null)
	return e != null and is_instance_valid(e.body)


static func _as_int(v: Variant, fallback: int) -> int:
	if v is int:
		@warning_ignore("unsafe_cast")
		return v as int
	if v is float:
		@warning_ignore("unsafe_cast")
		var f := v as float
		if is_finite(f):
			return int(f)
	return fallback


## {pos, radius, open} from one provider entry, or {} if it has no Vector2 pos.
static func _weak_point(item: Variant) -> Dictionary:
	if not item is Dictionary:
		return {}
	@warning_ignore("unsafe_cast")
	var d := item as Dictionary
	var p: Variant = d.get("pos")
	if not p is Vector2:
		return {}
	@warning_ignore("unsafe_cast")
	var pos := p as Vector2
	if not pos.is_finite():
		return {}
	var radius := 0.0
	var r: Variant = d.get("radius", 0.0)
	if r is float or r is int:
		@warning_ignore("unsafe_cast")
		radius = float(r as float) if r is float else float(r as int)
	if not is_finite(radius) or radius < 0.0:
		radius = 0.0
	var open := true
	var o: Variant = d.get("open", true)
	if o is bool:
		@warning_ignore("unsafe_cast")
		open = o as bool
	return {"pos": pos, "radius": radius, "open": open}


func _clear_snapshot() -> void:
	_ids.clear()
	_pos.clear()
	_vel.clear()
	_hp.clear()
	_radius.clear()
	_kind.clear()
	_rarity.clear()
	_tier.clear()
	_boss.clear()
	_boss_row = -1


static func _hp_frac(health: Health) -> float:
	if health == null or not is_instance_valid(health) or health.max_hp <= 0.0:
		return 1.0
	return clampf(health.hp / health.max_hp, 0.0, 1.0)


## Ids to skip, as a set. Accepts the shapes listed on nearest_enemy(); anything
## else (or a non-integer entry) is ignored.
static func _exclude_set(exclude: Variant) -> Dictionary[int, bool]:
	var out: Dictionary[int, bool] = {}
	if exclude is PackedInt64Array:
		@warning_ignore("unsafe_cast")
		for id: int in exclude as PackedInt64Array:
			out[id] = true
	elif exclude is PackedInt32Array:
		@warning_ignore("unsafe_cast")
		for id: int in exclude as PackedInt32Array:
			out[id] = true
	elif exclude is Array:
		@warning_ignore("unsafe_cast")
		for item: Variant in exclude as Array:
			if item is int:
				out[item] = true
			elif item is float:
				@warning_ignore("unsafe_cast")
				var f := item as float
				if is_finite(f) and f == floorf(f):
					out[int(f)] = true
	return out
