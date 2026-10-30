extends Node
## Autoload `RespawnPoints`: where the player comes back after dying.
##
## Decided 2026-10-30: the player respawns at the last cleared boss arena, or at
## the origin if no arena has been cleared yet. Bosses don't exist yet; boss code
## will call register_arena_cleared() when its arena is won, and anything else
## that wants a save point (a future checkpoint pickup) can call set_checkpoint().
## `Main` asks get_respawn_position() when the player dies.
##
## It only stores a position, so it is trivial to test and to drive from scripts.
## Call reset() when a run starts over (and in tests, which share the autoload).

## Emitted whenever the respawn position changes (also by reset()).
signal respawn_position_changed(position: Vector2)

## Used while nothing has been cleared / set.
const FALLBACK_POSITION := Vector2.ZERO

var _checkpoint := FALLBACK_POSITION
var _has_checkpoint := false
var _arenas_cleared := 0


## Records that the boss arena at `arena_position` was cleared: it becomes the
## respawn point (replacing any earlier one: the *last* cleared arena wins).
## Non-finite positions are ignored with a warning. Returns true if recorded.
func register_arena_cleared(arena_position: Vector2) -> bool:
	if not _store(arena_position, "register_arena_cleared"):
		return false
	_arenas_cleared += 1
	return true


## Sets the respawn point without counting it as a cleared arena.
func set_checkpoint(checkpoint_position: Vector2) -> bool:
	return _store(checkpoint_position, "set_checkpoint")


## Where the player respawns: the last cleared arena / checkpoint, or the origin.
func get_respawn_position() -> Vector2:
	return _checkpoint if _has_checkpoint else FALLBACK_POSITION


## True once register_arena_cleared() or set_checkpoint() has been called since
## the last reset().
func has_checkpoint() -> bool:
	return _has_checkpoint


## Number of register_arena_cleared() calls since the last reset().
func get_arenas_cleared() -> int:
	return _arenas_cleared


## Forgets every arena and checkpoint: respawn falls back to the origin.
func reset() -> void:
	var changed := _has_checkpoint
	_checkpoint = FALLBACK_POSITION
	_has_checkpoint = false
	_arenas_cleared = 0
	if changed:
		respawn_position_changed.emit(FALLBACK_POSITION)


func _store(value: Vector2, caller: String) -> bool:
	if not value.is_finite():
		push_warning("RespawnPoints.%s(): non-finite position ignored" % caller)
		return false
	_checkpoint = value
	_has_checkpoint = true
	respawn_position_changed.emit(value)
	return true
