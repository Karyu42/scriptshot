class_name SummonAdd
extends RegularEnemy
## One Summoner add (issue #81). A Swarmer body (radius 8, `kind` swarmer) with
## the HP the affix gives it (1 at common: one BasicShot hit). It spawns on a
## flank of the summoner-to-player line and drifts toward the player on that
## side, so it never parks in the player's firing lane: it aims at a point
## FLANK_STANDOFF px off the player on its own side, perpendicular to that
## line, and once it is near closes to CONTACT_HOLD px on the same side, which
## is inside contact range (player 14 + add 8) but off the bullet path. No erratic jitter, no drops, no
## cue, no shard. Contact damage and the safe-disk rules are RegularEnemy's.

## Drift speed toward the player. Slower than a chunk Swarmer (140).
const DRIFT_SPEED := 120.0
## How far off the lane (player-to-summoner line) the add holds while it
## approaches. 8 px body + 4 px bullet + margin.
const FLANK_STANDOFF := 40.0
## Closer than FLANK_STANDOFF + CLOSE_IN to the player, the add heads for the
## contact point instead.
const CLOSE_IN := 12.0
## Contact point offset: under player radius 14 + add radius 8, so contact
## damage connects, and 20 px off a shot fired along the lane.
const CONTACT_HOLD := 20.0

## The elite that spawned this add. Null or freed: plain drift at the player.
var summoner: Node2D
## +1 or -1: which side of the summoner-to-player line this add keeps.
var side := 1.0
var summon_hp := 1.0


func _apply_stats() -> void:
	super._apply_stats()
	health.max_hp = summon_hp
	health.hp = summon_hp


func _move_speed() -> float:
	return DRIFT_SPEED


func _chase(delta: float, to_player: Vector2) -> void:
	if player == null:
		return
	var hold := FLANK_STANDOFF
	if to_player.length() <= FLANK_STANDOFF + CLOSE_IN:
		hold = CONTACT_HOLD
	var to_target := flank_point(hold) - global_position
	if to_target.length_squared() > 0.000001:
		_heading = to_target.normalized()
	var step := _heading * _move_speed() * delta
	if step.length_squared() > to_target.length_squared():
		step = to_target
	global_position = _slide_outside_disk(global_position, step, player.global_position)


## `offset` px off the player, perpendicular to the summoner-to-player line,
## on this add's side. With no live summoner the lane is gone and the point is
## the player.
func flank_point(offset: float = FLANK_STANDOFF) -> Vector2:
	if player == null:
		return global_position
	var normal := lane_normal()
	if normal == Vector2.ZERO:
		return player.global_position
	return player.global_position + normal * side * offset


## Unit normal of the summoner-to-player line (left of the direction to the
## player), or zero when there is no live summoner or the two coincide.
func lane_normal() -> Vector2:
	if player == null or summoner == null or not is_instance_valid(summoner):
		return Vector2.ZERO
	var alive := summoner as RegularEnemy
	if alive != null and not alive.is_alive():
		return Vector2.ZERO
	var lane := player.global_position - summoner.global_position
	if lane.length_squared() <= 0.000001:
		return Vector2.ZERO
	lane = lane.normalized()
	return Vector2(-lane.y, lane.x)
