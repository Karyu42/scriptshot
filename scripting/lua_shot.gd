class_name LuaShot
extends ShotPattern
## The player's scripted weapon. A script with `on_fire(ctx)` spawns what it
## asks for with spawn{...}; without one, each fire() spawns one shot along
## the aim. The weapon table's `cooldown`, `speed`, `lifetime`, `damage` and
## `radius` are the defaults, and the table's bullet callbacks (`on_hit`,
## `on_batch`, ...) ride on every shot through a LuaBulletBehavior. Until a
## script applies cleanly it fires the same shot as BasicShot.
##
## apply() is the hot reload. Call it at a frame boundary, outside the bullet
## step (the editor uses call_deferred). In-flight shots keep the version they
## were fired with:
##   * when the current version has no live shots, the new code replaces it in
##     place (nothing in flight can see the swap);
##   * otherwise the new code goes into another generation (a second
##     LuaBulletBehavior with its own ScriptHost) that has no live shots, or a
##     new one while there are fewer than MAX_GENERATIONS; old shots finish on
##     their own generation's chunk;
##   * with every generation busy, the current one is reloaded in place: live
##     shots of that version then call the new callbacks by name on their next
##     dispatch (the documented `reload = "migrate"` behaviour).
## TODO(hot-reload): when BulletManager grows hooked_count_for_owner /
## strip_hooks_for_owner (Gameplay Engineer), replace the in-place fallback
## with stripping the oldest generation's hooks so the cap is never exceeded.
## A failed apply never replaces the running version.

## Lua states are never freed (lua-gdextension #240), so generations are capped.
const MAX_GENERATIONS := 3
const DEFAULT_COOLDOWN := 0.11
const DEFAULT_SPEED := 760.0
const DEFAULT_LIFETIME := 1.3
const DEFAULT_DAMAGE := 1.0
const DEFAULT_RADIUS := 4.0
## RunResult.error of a load that ran but did not return a weapon table.
const NO_TABLE_ERROR := "the script did not return a table"

var manager: BulletManager
var chunk_name := "weapon.lua"
## Settings of the running version (from its weapon table).
var title := "Basic"
var speed := DEFAULT_SPEED
var bullet_lifetime := DEFAULT_LIFETIME
var bullet_damage := DEFAULT_DAMAGE
var bullet_radius := DEFAULT_RADIUS
var bullet_color := Layers.bullet_color(Layers.PLAYER)
## Source of the running version, "" before the first clean apply.
var source := ""
## Clean applies so far, and how many of them went into another generation.
var applied_count := 0
var generation_switches := 0
var in_place_with_live_shots := 0

var _gens: Array[LuaBulletBehavior] = []
var _gen_ids: Array[int] = []
var _current := -1
var _request := ShotRequest.new()


func _init(bullet_manager: BulletManager = null) -> void:
	manager = bullet_manager
	fire_interval = DEFAULT_COOLDOWN


## The behaviour of the running version, or null before the first clean apply.
func behavior() -> LuaBulletBehavior:
	return _gens[_current] if _current >= 0 else null


func behavior_id() -> int:
	return _gen_ids[_current] if _current >= 0 else 0


func generation_count() -> int:
	return _gens.size()


func has_script() -> bool:
	return _current >= 0


## Compiles and runs `code` as the new weapon. On success the next fire uses
## it. On failure (compile error, error or stop while loading, or no table
## returned) the running version is kept and the result carries the error.
func apply(code: String) -> ScriptHost.RunResult:
	if manager == null:
		var no_manager := ScriptHost.RunResult.new()
		no_manager.error = "no bullet manager"
		return no_manager
	var target := _pick_target()
	if target < 0:
		target = _add_generation()
	var behavior_ref := _gens[target]
	var result := behavior_ref.load_source(code, chunk_name, manager, _gen_ids[target])
	var adopted := result.ok and result.value is LuaTable and behavior_ref.host.has_weapon()
	# Do not keep Lua wrappers on a result the editor may hold.
	result.value = null
	if result.ok and not adopted:
		result.ok = false
		result.error = NO_TABLE_ERROR
		return result
	if not result.ok:
		return result
	if target != _current and _current >= 0:
		generation_switches += 1
	elif target == _current and _live_shots(_current) > 0:
		in_place_with_live_shots += 1
	_current = target
	source = code
	applied_count += 1
	_read_settings(behavior_ref.host)
	return result


func _pick_target() -> int:
	if _current >= 0 and _live_shots(_current) == 0:
		return _current
	for i in _gens.size():
		if i != _current and _live_shots(i) == 0:
			return i
	if _gens.size() < MAX_GENERATIONS:
		return -1
	return _current


func _add_generation() -> int:
	var b := LuaBulletBehavior.new()
	b.skip_failed_callbacks = true
	_gens.append(b)
	_gen_ids.append(manager.register_behavior(b))
	return _gens.size() - 1


## Live shots of generation `index`, on the pool and in the native sim.
func _live_shots(index: int) -> int:
	if index < 0 or index >= _gens.size() or manager == null:
		return 0
	var id := _gen_ids[index]
	var n := 0
	var pool := manager.pool
	if pool != null:
		for i in pool.count:
			if pool.behavior[i] == id and pool.dead_reason[i] == 0:
				n += 1
	if manager.native != null:
		n += manager.native.count_with_behavior(id)
	return n


func live_shots_of_current() -> int:
	return _live_shots(_current)


func _read_settings(host: ScriptHost) -> void:
	title = host.weapon_string("name", "Untitled").substr(0, 40)
	fire_interval = clampf(host.weapon_number("cooldown", DEFAULT_COOLDOWN), 0.03, 5.0)
	speed = clampf(host.weapon_number("speed", DEFAULT_SPEED), 0.0, BulletLimits.MAX_SPEED)
	bullet_lifetime = clampf(host.weapon_number("lifetime", DEFAULT_LIFETIME), 0.05, 10.0)
	bullet_damage = clampf(host.weapon_number("damage", DEFAULT_DAMAGE), 0.0, 100.0)
	bullet_radius = clampf(host.weapon_number("radius", DEFAULT_RADIUS), 1.0, 32.0)


func fire(context: ShotContext, emitter: ShotEmitter) -> void:
	if _current >= 0 and _gens[_current].host.has_callback("on_fire") and not _gens[_current].suspended():
		_fire_script(context, emitter)
		return
	_fire_default(context, emitter)


## Runs on_fire(ctx) and spawns what it asked for. An error or a stop spawns
## nothing this pull (rate-limited warning); the next pull calls it again.
func _fire_script(context: ShotContext, emitter: ShotEmitter) -> void:
	var b := _gens[_current]
	var result := b.host.call_fire(context)
	if not result.ok:
		b._note_error("on_fire", result, false)
		ScriptWarnings.warn("LuaBulletBehavior.error.on_fire", "LuaBulletBehavior: on_fire: %s" % result.error)
		return
	var dropped := b.host.spawns_dropped()
	if dropped > 0:
		ScriptWarnings.warn("LuaShot.spawn_cap", "LuaShot: spawn %d calls past the %d-per-fire limit were dropped" % [dropped, ScriptHost.FIRE_SPAWN_CAP])
	var records := b.host.take_pending_spawns()
	var id := _gen_ids[_current]
	for rec in records:
		_request.reset()
		var at := Vector2(_num(rec, "x", context.muzzle_position.x), _num(rec, "y", context.muzzle_position.y))
		var angle := _num(rec, "angle", context.aim_angle)
		var spd := _num(rec, "speed", speed)
		_request.position = at
		_request.velocity = Vector2.from_angle(angle) * spd + context.shooter_velocity * 0.15
		_request.angle = angle
		_request.lifetime = _num(rec, "lifetime", bullet_lifetime)
		_request.radius = _num(rec, "radius", bullet_radius)
		_request.damage = _num(rec, "damage", bullet_damage)
		_request.turn_rate = _num(rec, "spin", 0.0)
		_request.acceleration = _num(rec, "accel", 0.0)
		_request.color = bullet_color
		_request.owner_layer = Layers.PLAYER
		_request.hit_mask = context.target_mask
		b.apply_to_request(_request, id)
		emitter.request_shot(_request)


static func _num(rec: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = rec.get(key, null)
	if v is float:
		return v
	return fallback


func _fire_default(context: ShotContext, emitter: ShotEmitter) -> void:
	_request.reset()
	_request.position = context.muzzle_position
	_request.velocity = context.aim_direction * speed + context.shooter_velocity * 0.15
	_request.angle = context.aim_angle
	_request.lifetime = bullet_lifetime
	_request.radius = bullet_radius
	_request.damage = bullet_damage
	_request.color = bullet_color
	_request.owner_layer = Layers.PLAYER
	_request.hit_mask = context.target_mask
	if _current >= 0:
		_gens[_current].apply_to_request(_request, _gen_ids[_current])
	emitter.request_shot(_request)
