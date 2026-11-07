class_name HeraldArm
extends Node
## L0 trigger for the Herald. Arms once. HeraldDirector (L2) owns the delay,
## the spawn, the cancel, and the save flag.
##
## The arm happens when the player first leaves the safe disk (distance > 512),
## or 60 s after all three tutorial targets have reached 0 HP, whichever is
## first. A respawn does not un-clear a target. Walking back inside does not
## restart either condition.

signal herald_armed(reason: StringName)

const CLEAR_DELAY := 60.0
const REASON_LEFT := &"left_safe_zone"
const REASON_TUTORIAL := &"tutorial_cleared"

var player: Node2D
var armed := false
var arm_reason := StringName()
var left_safe_zone := false
var tutorial_cleared := false
## Seconds left on the post-clear clock, or -1 when that clock is not running.
var clear_seconds_left := -1.0

var _watched := 0
var _cleared: Dictionary[int, bool] = {}


func _init() -> void:
	# After the player (priority 0) has moved this tick.
	process_physics_priority = 10


func bind(p_player: Node2D, dummies: Node) -> void:
	player = p_player
	_watched = 0
	_cleared.clear()
	for child: Node in dummies.get_children():
		var dummy := child as TrainingDummy
		if dummy == null:
			continue
		var id := dummy.get_instance_id()
		_cleared[id] = false
		_watched += 1
		if not dummy.destroyed.is_connected(_on_dummy_destroyed):
			dummy.destroyed.connect(_on_dummy_destroyed.bind(id))


func _physics_process(delta: float) -> void:
	advance(delta)


## Steps the trigger by `delta` seconds. Public so tests can jump the 60 s
## clock without waiting it out. A non-positive delta still polls the exit.
func advance(delta: float) -> void:
	_poll_exit()
	if armed or clear_seconds_left < 0.0:
		return
	if delta > 0.0:
		clear_seconds_left -= delta
	if clear_seconds_left <= 0.0:
		clear_seconds_left = -1.0
		_arm(REASON_TUTORIAL)


func _poll_exit() -> void:
	if player == null or left_safe_zone:
		return
	if player.global_position.length() > WorldGen.SAFE_RADIUS:
		left_safe_zone = true
		_arm(REASON_LEFT)


func _on_dummy_destroyed(id: int) -> void:
	if not _cleared.has(id):
		return
	_cleared[id] = true
	if tutorial_cleared:
		return
	var n := 0
	for key: int in _cleared:
		if _cleared[key]:
			n += 1
	if _watched > 0 and n >= _watched:
		tutorial_cleared = true
		if not armed:
			clear_seconds_left = CLEAR_DELAY


func _arm(reason: StringName) -> void:
	if armed:
		return
	armed = true
	arm_reason = reason
	clear_seconds_left = -1.0
	herald_armed.emit(reason)
