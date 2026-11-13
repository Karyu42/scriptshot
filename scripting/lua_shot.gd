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
##   * when the current version has no hooked shots in flight, the new code
##     replaces it in place (nothing in flight can see the swap);
##   * otherwise the new code starts a new generation: a fresh
##     LuaBulletBehavior registered under its own owner id, on a free slot's
##     ScriptHost. Old shots finish on their own generation's chunk;
##   * a generation that is no longer current is released when its last hooked
##     shot is gone (BulletManager.hooked_owner_drained): release_behavior()
##     drops the behaviour, and its host drops the weapon table so the old
##     chunk is collected. The host goes back to its slot for a later generation;
##   * with every slot busy (MAX_GENERATIONS versions with shots in flight), a
##     save is never refused: once the new code compiles, the oldest old
##     generation is stripped (strip_hooks_for_owner, then release_behavior).
##     Its shots fly on as plain bullets with the same speed, damage, lifetime
##     and look, and run no hooks. Silent by design (slice spec, #93).
## Shots never switch to another version's callbacks. A released slot's host
## also gets its sandbox globals reset, so a new version does not inherit
## globals an older one set.
## Lua states are never freed (lua-gdextension #240), so a weapon keeps at most
## MAX_GENERATIONS ScriptHosts (one per slot) for its whole life, however often
## it is reloaded. A failed apply never replaces the running version.

## Slots, and so Lua states, per weapon.
const MAX_GENERATIONS := 3
const DEFAULT_COOLDOWN := 0.11
const DEFAULT_SPEED := 760.0
const DEFAULT_LIFETIME := 1.3
const DEFAULT_DAMAGE := 1.0
const DEFAULT_RADIUS := 4.0
## RunResult.error of a load that ran but did not return a weapon table.
const NO_TABLE_ERROR := "the script did not return a table"
## RunResult.error of apply() called from a listener while apply() runs.
const NESTED_APPLY_ERROR := "apply() called while a reload is running"

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
## Reloads that swapped code under shots in flight. Stays 0: a version with
## hooked shots in flight is never reloaded in place.
var in_place_with_live_shots := 0
## Old generations released after their last hooked shot was gone, and old
## generations stripped early because every slot was busy.
var released_count := 0
var evicted_count := 0

## One entry per slot. A slot's host lives as long as the weapon; the
## generation on it (behaviour, owner id) is null / 0 while free.
var _hosts: Array[ScriptHost] = []
var _gens: Array[LuaBulletBehavior] = []
var _gen_ids: Array[int] = []
## Start order of each slot's generation (0 while free); the smallest is oldest.
var _gen_serial: Array[int] = []
var _serial := 0
var _current := -1
## True inside apply(); drains that arrive meanwhile wait in _drained_later.
var _applying := false
var _drained_later: Array[int] = []
var _request := ShotRequest.new()


func _init(bullet_manager: BulletManager = null) -> void:
	manager = bullet_manager
	fire_interval = DEFAULT_COOLDOWN
	if manager != null:
		manager.hooked_owner_drained.connect(_on_owner_drained)


## The behaviour of the running version, or null before the first clean apply.
func behavior() -> LuaBulletBehavior:
	return _gens[_current] if _current >= 0 else null


func behavior_id() -> int:
	return _gen_ids[_current] if _current >= 0 else 0


## Generations alive: the current one plus old ones with shots in flight.
func generation_count() -> int:
	var n := 0
	for b in _gens:
		if b != null:
			n += 1
	return n


## ScriptHosts (slots) this weapon holds. Never more than MAX_GENERATIONS.
func host_count() -> int:
	return _hosts.size()


## Lua states held by this weapon's hosts, retired ones included.
func lua_state_count() -> int:
	var n := 0
	for h in _hosts:
		n += h.lua_state_count()
	return n


## Lua heap of this weapon's hosts in bytes, retired states included.
func lua_memory() -> int:
	var n := 0
	for h in _hosts:
		n += h.lua_memory()
	return n


func has_script() -> bool:
	return _current >= 0


## Compiles and runs `code` as the new weapon. On success the next fire uses
## it. On failure (compile error, error or stop while loading, or no table
## returned) the running version is kept and the result carries the error.
func apply(code: String) -> ScriptHost.RunResult:
	if not _has_manager():
		var no_manager := ScriptHost.RunResult.new()
		no_manager.error = "no bullet manager"
		return no_manager
	if _applying:
		# Only a hooked_owner_drained listener can get here (apply strips a
		# slot). ShotScripts always loads at a frame boundary instead.
		var nested := ScriptHost.RunResult.new()
		nested.chunk_name = chunk_name
		nested.error = NESTED_APPLY_ERROR
		return nested
	_applying = true
	_release_idle_old()
	var result := _apply(code)
	_applying = false
	_flush_drained()
	return result


func _apply(code: String) -> ScriptHost.RunResult:
	if _current >= 0 and _live_shots(_current) == 0:
		return _load_into(_current, code)
	var slot := _free_slot()
	if slot < 0 and _hosts.size() < MAX_GENERATIONS:
		slot = _add_slot()
	if slot < 0:
		slot = _oldest_old()
		if slot < 0:
			# Only with MAX_GENERATIONS < 2: nothing old to strip.
			return _load_into(_current, code)
		# The new version runs in a fresh env on that slot's host; the oldest
		# generation is stripped only once it loaded (see _load_into).
		return _load_into(slot, code, true)
	return _load_into(slot, code)


## Loads `code` into `slot`: in place when it holds the current generation,
## otherwise as a new generation that becomes current on success. With
## `replacing`, `slot` holds an old generation with shots in flight: the code
## loads into a fresh env on its host, and only when that load gives a weapon
## is the old generation stripped and released. A load that fails (compile,
## top-level error, budget stop, no table) leaves its weapon, callbacks and
## globals as they were, so its shots keep running their own code.
func _load_into(slot: int, code: String, replacing: bool = false) -> ScriptHost.RunResult:
	var in_place := _gens[slot] != null and not replacing
	var behavior_ref := _gens[slot]
	if not in_place:
		behavior_ref = LuaBulletBehavior.new(_hosts[slot])
		behavior_ref.skip_failed_callbacks = true
	var result: ScriptHost.RunResult
	if in_place:
		result = behavior_ref.load_source(code, chunk_name, manager, _gen_ids[slot])
	else:
		result = behavior_ref.load_source(code, chunk_name, null, -1, true)
	var adopted := result.ok and result.value is LuaTable and behavior_ref.host.has_weapon()
	# Do not keep Lua wrappers on a result the editor may hold.
	result.value = null
	if result.ok and not adopted:
		result.ok = false
		result.error = NO_TABLE_ERROR
	if not result.ok:
		return result
	if replacing:
		_release_slot(slot, false)
		evicted_count += 1
	if not in_place:
		_gens[slot] = behavior_ref
		_gen_ids[slot] = manager.register_behavior(behavior_ref)
		_serial += 1
		_gen_serial[slot] = _serial
		if _current >= 0:
			generation_switches += 1
	_current = slot
	source = code
	applied_count += 1
	_read_settings(behavior_ref.host)
	return result


func _free_slot() -> int:
	for i in _gens.size():
		if _gens[i] == null:
			return i
	return -1


func _add_slot() -> int:
	var host := ScriptHost.new()
	host.snapshot_globals()
	_hosts.append(host)
	_gens.append(null)
	_gen_ids.append(0)
	_gen_serial.append(0)
	return _hosts.size() - 1


## The non-current generation started first, or -1.
func _oldest_old() -> int:
	var best := -1
	for i in _gens.size():
		if i == _current or _gens[i] == null:
			continue
		if best < 0 or _gen_serial[i] < _gen_serial[best]:
			best = i
	return best


## BulletManager.hooked_owner_drained. Emitted at the end of step(), from
## clear_bullets() and from strip / release (also from inside our own
## release_behavior call). Unknown, already released and current ids are
## ignored; during apply() the id waits until apply() is done.
func _on_owner_drained(owner_id: int) -> void:
	if owner_id <= 0:
		return
	if _applying:
		if not _drained_later.has(owner_id):
			_drained_later.append(owner_id)
		return
	var slot := _gen_ids.find(owner_id)
	if slot < 0 or slot == _current or _gens[slot] == null:
		return
	if _live_shots(slot) > 0:
		return
	_release_slot(slot)


func _flush_drained() -> void:
	var ids := _drained_later.duplicate()
	_drained_later.clear()
	for id: int in ids:
		_on_owner_drained(id)


## Old generations that have nothing in flight (a drain the weapon missed, or
## one that never had a hooked shot).
func _release_idle_old() -> void:
	for i in _gens.size():
		if i != _current and _gens[i] != null and _live_shots(i) == 0:
			_release_slot(i)


## Frees slot `slot` for a later generation: strips any shots still in flight
## (they fly on as plain bullets), then releases the behaviour. The slot is
## cleared before the manager is told, so the drains strip / release emit find
## nothing to release again. `drop_weapon` false keeps the host's weapon (the
## new version has just loaded there).
func _release_slot(slot: int, drop_weapon: bool = true) -> void:
	var id := _gen_ids[slot]
	_gens[slot] = null
	_gen_ids[slot] = 0
	_gen_serial[slot] = 0
	if slot == _current:
		_current = -1
	if id > 0 and _has_manager():
		manager.strip_hooks_for_owner(id)
		manager.release_behavior(id)
	if drop_weapon:
		_hosts[slot].release_weapon()
	released_count += 1


func _has_manager() -> bool:
	return manager != null and is_instance_valid(manager)


## Hooked shots of slot `index` in flight, in the pool and in the native sim.
func _live_shots(index: int) -> int:
	if index < 0 or index >= _gen_ids.size() or not _has_manager():
		return 0
	return manager.hooked_count_for_owner(_gen_ids[index])


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
