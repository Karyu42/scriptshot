class_name SenseBook
extends RefCounted
## Which Senses the player has earned, and at what level (vertical-slice §6.1).
##
## This is the hook point only: nothing in this build calls grant(). The
## Senses PR adds the kill counting, the save fields (`sense_nearest`,
## `sense_enemies_in`) and the Lua side; it fills the `sense` table from the
## book before the first on_fire after a load. Until then every Sense is nil
## in scripts and the homing starter row stays locked.
##
## The editor listens on `SenseBook.events.granted(id, level)` for the
## one-time unlock UX (toast, Codex page, autocomplete highlight), which is
## also left for that PR.

class Events:
	extends RefCounted
	## Emitted when a Sense goes from a lower level to `level` (first unlock
	## is level 1). Not emitted when a save restores an already-held level.
	signal granted(id: StringName, level: int)

static var events := Events.new()
static var _levels: Dictionary[StringName, int] = {}


## Raises `id` to `level` (never lowers it). Emits `granted` when it rose,
## unless `quiet` (a save being restored).
static func grant(id: StringName, level_value: int = 1, quiet: bool = false) -> void:
	var key := _key(id)
	var was := level(key)
	if level_value <= was:
		return
	_levels[key] = level_value
	if not quiet:
		events.granted.emit(key, level_value)


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


## Forgets every Sense (tests, a new save slot).
static func reset() -> void:
	_levels.clear()


static func _key(id: StringName) -> StringName:
	return StringName(String(id).trim_prefix("sense."))
