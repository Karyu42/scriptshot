class_name SummonAdd
extends RegularEnemy
## One Summoner add (issue #81). Common and rare: a Swarmer body (radius 8,
## `kind` swarmer) with the HP the affix gives it (1: one BasicShot hit).
## Legendary (Hydra): a Drifter body (radius 16, `kind` drifter, 90 px/s) with
## 105 HP that chases like any Drifter (`holds_flank` false). A flank add
## spawns on a flank of the summoner-to-player line, jittered across the
## 40° arc, and holds at that same offset relative to the elite: the
## per-serial hashed angle and the wall-slide radius. The hold tracks the
## elite's facing (the current elite-to-player line) the same way
## `summon_spawn_point` does, so adds on one side stay spread and never
## park in the player's firing lane. With no live summoner the add falls
## back to a point FLANK_STANDOFF px off the player, closing to
## CONTACT_HOLD once near. No erratic jitter, no drops, no cue, no shard.
## Contact damage and the safe-disk rules are RegularEnemy's.

## Drift speed toward the hold. Slower than a chunk Swarmer (140).
const DRIFT_SPEED := 120.0
## Fallback hold, used when the summoner is gone: how far off the lane
## (player-to-summoner line, or the last heading) the add stands.
## 8 px body + 4 px bullet + margin.
const FLANK_STANDOFF := 40.0
## Closer than FLANK_STANDOFF + CLOSE_IN to the player, the no-summoner
## fallback heads for the contact point instead.
const CLOSE_IN := 12.0
## Contact point offset: under player radius 14 + add radius 8, so contact
## damage connects, and 20 px off a shot fired along the lane.
const CONTACT_HOLD := 20.0

## The elite that spawned this add. Null or freed: fallback hold at the player.
var summoner: Node2D
## +1 or -1: which side of the summoner-to-player line this add keeps.
var side := 1.0
var summon_hp := 1.0
## True: drift to this add's own flank hold and stay off the lane. False:
## RegularEnemy movement for its archetype (the Hydra's Drifter adds).
var holds_flank := true
## Per-serial hashed flank-arc offset, in radians, copied at spawn so the
## hold uses the same angle as the spawn.
var flank_jitter := 0.0
## Distance from the elite used at spawn after the wall slide, in px.
var flank_hold_radius := 48.0


func _apply_stats() -> void:
	super._apply_stats()
	health.max_hp = summon_hp
	health.hp = summon_hp


func _move_speed() -> float:
	if not holds_flank:
		return super._move_speed()
	return DRIFT_SPEED


func _chase(delta: float, to_player: Vector2) -> void:
	if not holds_flank:
		super._chase(delta, to_player)
		return
	if player == null:
		return
	var hold := FLANK_STANDOFF
	if not _has_live_elite() and to_player.length() <= FLANK_STANDOFF + CLOSE_IN:
		hold = CONTACT_HOLD
	var to_target := flank_point(hold) - global_position
	if to_target.length_squared() > 0.000001:
		_heading = to_target.normalized()
	var step := _heading * _move_speed() * delta
	if step.length_squared() > to_target.length_squared():
		step = to_target
	global_position = _slide_outside_disk(global_position, step, player.global_position)


func _has_live_elite() -> bool:
	var elite := summoner as EliteEnemy
	return elite != null and is_instance_valid(elite) and elite.is_alive()


## With a live elite: this add's spawn offset relative to the elite, with
## the direction recomputed from the current elite-to-player facing so the
## hold tracks as `flank_point` did (and as `summon_spawn_point` does).
## `offset` is unused on that path; the stored wall-slide radius is used.
## With no live summoner: `offset` px off the player, perpendicular to the
## last lane, on this add's side. If the lane is gone, the point is the player.
func flank_point(offset: float = FLANK_STANDOFF) -> Vector2:
	var elite := summoner as EliteEnemy
	if elite != null and is_instance_valid(elite) and elite.is_alive():
		var dir := elite.summon_flank_dir(side, flank_jitter)
		return elite.global_position + dir * flank_hold_radius
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
