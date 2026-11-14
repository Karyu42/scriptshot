class_name SummonAdd
extends RegularEnemy
## One Summoner add (issue #81). Common and rare: a Swarmer body (radius 8,
## `kind` swarmer) with the HP the affix gives it (1: one BasicShot hit).
## Legendary (Hydra): a Drifter body (radius 16, `kind` drifter, 90 px/s) with
## 105 HP that chases like any Drifter (`holds_flank` false). A flank add
## spawns on a flank of the summoner-to-player line, jittered across the
## 60° arc, then drifts in to a contact hold around the player: its side
## (±90° off the player-to-elite line) plus its hashed arc offset, at
## player radius + add radius + CONTACT_GAP (20 px of clear air outside
## the player's edge). Adds stay spread and out of the firing lane. Overlap
## of up to about half a radius is fine; there is no separation steering.
## With no live summoner the hold keeps the same contact distance along
## the last lane. No erratic jitter, no drops, no cue, no shard. Contact
## damage and the safe-disk rules are RegularEnemy's.

## Drift speed toward the hold. Slower than a chunk Swarmer (140).
const DRIFT_SPEED := 120.0
## Clear air between the player's edge and the add's edge at the contact
## hold, in px. Centre-to-centre distance is player radius + add radius
## plus this gap.
const CONTACT_GAP := 20.0

## The elite that spawned this add. Null or freed: hold off the player
## along the last lane, if any.
var summoner: Node2D
## +1 or -1: which side of the summoner-to-player line this add keeps.
var side := 1.0
var summon_hp := 1.0
## True: drift to this add's own contact hold and stay off the lane. False:
## RegularEnemy movement for its archetype (the Hydra's Drifter adds).
var holds_flank := true
## Per-serial hashed flank-arc offset, in radians, copied at spawn so the
## hold uses the same angle as the spawn.
var flank_jitter := 0.0


func _apply_stats() -> void:
	super._apply_stats()
	health.max_hp = summon_hp
	health.hp = summon_hp


func _move_speed() -> float:
	if not holds_flank:
		return super._move_speed()
	return DRIFT_SPEED


## Centre-to-centre contact hold: 20 px outside the player's edge, so
## the add's circle sits CONTACT_GAP past the player's circle.
func contact_offset() -> float:
	return RegularEnemy.PLAYER_RADIUS + body_radius + CONTACT_GAP


func _chase(delta: float, to_player: Vector2) -> void:
	if not holds_flank:
		super._chase(delta, to_player)
		return
	if player == null:
		return
	var to_target := flank_point() - global_position
	if to_target.length_squared() > 0.000001:
		_heading = to_target.normalized()
	var step := _heading * _move_speed() * delta
	if step.length_squared() > to_target.length_squared():
		step = to_target
	global_position = _keep_off_walls(_slide_outside_disk(global_position, step, player.global_position))


## Unit direction from the player to this add's hold: the add's side
## (±90° off the player-to-elite / elite-to-player line) plus its hashed
## arc offset. Zero when there is no summoner geometry to hang a lane on.
func _hold_dir() -> Vector2:
	var elite := summoner as EliteEnemy
	if elite != null and is_instance_valid(elite):
		return elite.summon_flank_dir(side, flank_jitter)
	return Vector2.ZERO


## Contact hold around the player at `offset` (defaults to contact_offset)
## along _hold_dir. If the lane is gone, the point is the player.
func flank_point(offset: float = -1.0) -> Vector2:
	if offset < 0.0:
		offset = contact_offset()
	if player == null:
		return global_position
	var dir := _hold_dir()
	if dir == Vector2.ZERO:
		return player.global_position
	return player.global_position + dir * offset


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
