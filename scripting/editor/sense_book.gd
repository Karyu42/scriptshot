class_name SenseBook
extends RefCounted
## Which Senses the player has earned, and at what level (vertical-slice §6.1).
##
## Counting: listen() subscribes to GameEvents. Every `enemy_killed` with
## `first_death` true adds one kill (dummies included; a respawned dummy's
## later deaths report false and do not count). At NEAREST_KILLS kills the book
## grants `nearest_enemy` Level I. A `boss_defeated` for the Warden grants
## `enemies_in` Level I (the boss emits enemy_killed first, then
## boss_defeated). This slice never grants above Level I.
##
## Kill events fire in the middle of a physics step (a bullet hit), so a grant
## they earn is queued and applied at the next frame boundary
## (SceneTree.process_frame), never inside the step: no `sense` field appears
## halfway through a bullet pass. flush_pending() applies the queue now
## (tests, tools).
##
## Persistence: bind_save() restores `sense_nearest` / `sense_enemies_in` from
## a SaveGame quietly (no toast, no Codex page) and writes them back on each
## grant. ScriptHost reads the book through revision() and level() before
## every Lua call, so the env is built from the book before the first on_fire
## after a load.
##
## The editor listens on `SenseBook.events.granted(id, level)` for the
## one-time unlock UX (toast, Codex page, autocomplete highlight).

## First deaths needed for `nearest_enemy` (§6.1).
const NEAREST_KILLS := 3
const NEAREST := &"nearest_enemy"
const ENEMIES_IN := &"enemies_in"
## The Senses the Lua `sense` table can hold in this build (sandbox.lua).
const LUA_SENSES: Array[StringName] = [NEAREST, ENEMIES_IN]
## Highest level this build knows. A saved level is clamped to 0..MAX_LEVEL.
const MAX_LEVEL := 1


class Events:
	extends RefCounted
	## Emitted when a Sense goes from a lower level to `level` (first unlock
	## is level 1). Not emitted when a save restores an already-held level.
	signal granted(id: StringName, level: int)

	func _on_enemy_killed(_kind: StringName, _rarity: int, _tier: int, _position: Vector2, first_death: bool) -> void:
		SenseBook.count_kill(first_death)

	func _on_boss_defeated(boss_kind: StringName, rarity: int, _tier: int, _position: Vector2) -> void:
		SenseBook.boss_down(boss_kind, rarity)

	func _on_frame() -> void:
		SenseBook.flush_pending()


static var events := Events.new()
static var _levels: Dictionary[StringName, int] = {}
static var _kills := 0
## Grants waiting for the frame boundary: id -> level.
static var _pending: Dictionary[StringName, int] = {}
static var _revision := 0
static var _save: SaveGame


## Raises `id` to `level` (never lowers it). Emits `granted` when it rose,
## unless `quiet` (a save being restored). Writes the bound save on a rise.
## Applies at once: game code that runs mid-step should go through queue_grant().
static func grant(id: StringName, level_value: int = 1, quiet: bool = false) -> void:
	var key := _key(id)
	var was := level(key)
	if level_value <= was:
		return
	_levels[key] = level_value
	_revision += 1
	_write_save()
	if not quiet:
		events.granted.emit(key, level_value)


## Queues a grant for the next frame boundary (see the class comment).
static func queue_grant(id: StringName, level_value: int = 1) -> void:
	var key := _key(id)
	var queued: int = _pending.get(key, 0)
	if level_value <= maxi(level(key), queued):
		return
	_pending[key] = level_value
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.process_frame.is_connected(events._on_frame):
		tree.process_frame.connect(events._on_frame, CONNECT_ONE_SHOT)


## Applies queued grants now, in a fixed order (nearest_enemy first).
static func flush_pending() -> void:
	if _pending.is_empty():
		return
	var keys: Array[StringName] = []
	keys.assign(_pending.keys())
	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) > String(b))
	var queued: Dictionary[StringName, int] = _pending.duplicate()
	_pending.clear()
	for k in keys:
		grant(k, queued[k])


static func pending_count() -> int:
	return _pending.size()


static func level(id: StringName) -> int:
	return _levels.get(_key(id), 0)


static func unlocked(id: StringName) -> bool:
	return level(id) > 0


## True when every name in `needs` is unlocked ("sense.nearest_enemy" or
## "nearest_enemy" both work).
static func all_unlocked(needs: PackedStringArray) -> bool:
	for n in needs:
		if not unlocked(StringName(n)):
			return false
	return true


## Every Sense the player has, sorted.
static func unlocked_names() -> PackedStringArray:
	var out := PackedStringArray()
	for k: StringName in _levels:
		if _levels[k] > 0:
			out.append(String(k))
	out.sort()
	return out


## Bumped on every level change; ScriptHost rebuilds `sense` when it moves.
static func revision() -> int:
	return _revision


## First deaths counted since the last reset() (this session).
static func kill_count() -> int:
	return _kills


# --- counting ------------------------------------------------------------------

## Subscribes to GameEvents. Idempotent. Main calls it in _ready.
static func listen() -> void:
	if not is_instance_valid(GameEvents):
		return
	var killed := GameEvents.enemy_killed
	var boss := GameEvents.boss_defeated
	if not killed.is_connected(events._on_enemy_killed):
		killed.connect(events._on_enemy_killed)
	if not boss.is_connected(events._on_boss_defeated):
		boss.connect(events._on_boss_defeated)


static func unlisten() -> void:
	if not is_instance_valid(GameEvents):
		return
	var killed := GameEvents.enemy_killed
	var boss := GameEvents.boss_defeated
	if killed.is_connected(events._on_enemy_killed):
		killed.disconnect(events._on_enemy_killed)
	if boss.is_connected(events._on_boss_defeated):
		boss.disconnect(events._on_boss_defeated)


static func is_listening() -> bool:
	if not is_instance_valid(GameEvents):
		return false
	return GameEvents.enemy_killed.is_connected(events._on_enemy_killed)


## One `enemy_killed`. Only first deaths count (§6.1).
static func count_kill(first_death: bool) -> void:
	if not first_death:
		return
	_kills += 1
	if _kills >= NEAREST_KILLS:
		queue_grant(NEAREST, 1)


## One `boss_defeated`. The Warden grants enemies_in Level I whatever its
## rarity: this slice's Warden is always common, and Level II is not built.
static func boss_down(boss_kind: StringName, _rarity: int) -> void:
	if boss_kind == EnemyKinds.WARDEN:
		queue_grant(ENEMIES_IN, 1)


# --- save ----------------------------------------------------------------------

## Restores the held Senses from `save` (quiet: no unlock UX) and writes later
## grants to it. null unbinds.
static func bind_save(save: SaveGame) -> void:
	# Restore first, then bind: a restore must not write a half-read slot back.
	_save = null
	if save == null:
		return
	# The slot is player-editable: never trust a level this build cannot grant.
	if save.sense_nearest:
		grant(NEAREST, 1, true)
	var enemies_in := clampi(save.sense_enemies_in, 0, MAX_LEVEL)
	if enemies_in > 0:
		grant(ENEMIES_IN, enemies_in, true)
	_save = save
	# Senses earned before the bind (this session) are written to the slot.
	_write_save()


static func _write_save() -> void:
	if _save == null:
		return
	var nearest := level(NEAREST) > 0
	var enemies_in := level(ENEMIES_IN)
	if _save.sense_nearest == nearest and _save.sense_enemies_in == enemies_in:
		return
	_save.sense_nearest = nearest
	_save.sense_enemies_in = enemies_in
	_save.save()


## Forgets every Sense, the kill count and the queue, and unbinds the save
## (tests, a new save slot).
static func reset() -> void:
	_levels.clear()
	_pending.clear()
	# The one-shot queue_grant() connected would otherwise still fire.
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.process_frame.is_connected(events._on_frame):
		tree.process_frame.disconnect(events._on_frame)
	_kills = 0
	_save = null
	_revision += 1


static func _key(id: StringName) -> StringName:
	return StringName(String(id).trim_prefix("sense."))

