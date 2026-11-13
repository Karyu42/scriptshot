class_name HeraldDirector
extends Node
## L2 Herald. HeraldArm only decides when the countdown starts. This node waits
## `WorldGen.herald_delay(seed)` seconds and then either spawns one common
## Drifter elite or cancels.
##
## Cancel when a natural elite (any EliteEnemy that is not this Herald and not
## a Splitting half) is woken, or dies after the countdown has started. A woken
## elite counts even if the wake happened before the arm: spawning §3.6 spawns
## the Herald only if no elite has woken by the time the timer fires. A natural
## elite that died before the arm without waking does not cancel: "killed since
## arming" is a death during the countdown, and this node does not read the
## chunk kill mask. The flag is written as soon as a cancel is known, so a quit
## does not lose it (the remaining time is not saved).
##
## The Herald is not a chunk encounter. Its death does not set a chunk bit.
## Only `herald_done` and, on that body's death, `shards` are persisted.
##
## Placement: WorldGen.herald_point, 1,200 px along the heading unless an
## encounter anchor is within 800 px; then the first clear turned or re-ranged
## candidate (issue #81). Packs are never moved, hidden or held asleep.

signal herald_spawned(body: EliteEnemy)
signal herald_cancelled(reason: StringName)

const REASON_DONE := &"already_done"
const REASON_ELITE := &"elite"
const REASON_SPAWNED := &"spawned"

var seed := 0
var player: Node2D
var save: SaveGame
var herald: EliteEnemy
## False in tests that force natural elite rolls off, so a decoy elite in the
## tree does not cancel the spawn. The chunk stream's own rolls stay on.
var natural_elites_cancel := true
## The vertical-slice ribbon, when the scene has one (Main sets it). A spawn
## point that lands in a walled room is redirected into room C
## (SliceLayout.redirect_herald). Null or disabled: no redirect.
var slice: SliceLayout
var counting := false
var resolved := false
var elapsed := 0.0
var delay := 0.0

var _holder: Node2D
var _seen: Dictionary[int, bool] = {}


func _init() -> void:
	# After HeraldArm (10) and after enemies (0), so a wake or a kill on this
	# tick is visible before the countdown decides.
	process_physics_priority = 20


func _ready() -> void:
	_ensure_holder()


func bind(arm: HeraldArm, p_player: Node2D, p_save: SaveGame) -> void:
	player = p_player
	save = p_save
	seed = p_save.world_seed
	if p_save.herald_done:
		resolved = true
	if not arm.herald_armed.is_connected(_on_armed):
		arm.herald_armed.connect(_on_armed)
	if arm.armed and not resolved and not counting:
		_begin()


func seconds_left() -> float:
	return maxf(delay - elapsed, 0.0)


func advance(delta: float) -> void:
	if resolved or not counting:
		return
	_watch_elites()
	if resolved or not counting:
		return
	if delta > 0.0:
		elapsed += delta
	if elapsed >= delay:
		_fire()


func _physics_process(delta: float) -> void:
	advance(delta)


func _on_armed(_reason: StringName) -> void:
	if resolved or counting:
		return
	if save != null and save.herald_done:
		resolved = true
		return
	_begin()


func _begin() -> void:
	counting = true
	resolved = false
	elapsed = 0.0
	delay = WorldGen.herald_delay(seed)
	_seen.clear()
	_watch_elites()


func _fire() -> void:
	if resolved:
		return
	counting = false
	if save != null and save.herald_done:
		resolved = true
		herald_cancelled.emit(REASON_DONE)
		return
	_spawn()
	_mark_done()
	if herald != null:
		herald_spawned.emit(herald)


func _watch_elites() -> void:
	if not natural_elites_cancel or not counting or resolved:
		return
	var tree := get_tree()
	if tree == null:
		return
	for node: Node in tree.get_nodes_in_group(EliteEnemy.GROUP_ELITE):
		var elite := node as EliteEnemy
		if elite == null or elite.is_herald or elite.is_half:
			continue
		var id := elite.get_instance_id()
		if not _seen.has(id):
			_seen[id] = true
			if not elite.died.is_connected(_on_natural_died):
				elite.died.connect(_on_natural_died)
		if elite.woken:
			_cancel(REASON_ELITE)
			return


func _on_natural_died() -> void:
	if not natural_elites_cancel or resolved or not counting:
		return
	_cancel(REASON_ELITE)


func _cancel(reason: StringName) -> void:
	if resolved:
		return
	counting = false
	_mark_done()
	herald_cancelled.emit(reason)


func _spawn() -> void:
	if player == null:
		return
	_ensure_holder()
	var heading := _heading_of(player)
	# No pack or natural-elite anchor within 800 px (WorldGen.herald_point).
	var point := WorldGen.herald_point(seed, player.global_position, heading, RegularEnemy.DRIFTER_RADIUS)
	var centre := RegularEnemy.push_centre_outside(point, RegularEnemy.DRIFTER_RADIUS)
	centre = _slice_redirect(centre)
	var affix := WorldGen.herald_affix(seed)
	var packed := load("res://scenes/elite_enemy.tscn") as PackedScene
	if packed == null or _holder == null:
		return
	var body := packed.instantiate() as EliteEnemy
	if body == null:
		return
	body.name = "Herald"
	body.configure_elite(affix, centre, centre, seed, player, true, false)
	_holder.add_child(body)
	herald = body
	if not body.shard_dropped.is_connected(_on_shard):
		body.shard_dropped.connect(_on_shard)


## Final placement step: the ribbon's redirect, after every other clamp.
func _slice_redirect(p: Vector2) -> Vector2:
	if slice == null or not is_instance_valid(slice) or not slice.enabled:
		return p
	return slice.redirect_herald(p, RegularEnemy.DRIFTER_RADIUS)


func _on_shard() -> void:
	if save == null:
		return
	save.shards += 1
	save.save()


func _mark_done() -> void:
	resolved = true
	counting = false
	if save == null:
		return
	save.herald_done = true
	save.save()


func _ensure_holder() -> void:
	if _holder != null:
		return
	_holder = Node2D.new()
	_holder.name = "Bodies"
	add_child(_holder)


func _heading_of(body: Node2D) -> Vector2:
	var velocity := Vector2.ZERO
	var aim := Vector2.RIGHT
	var as_player := body as Player
	if as_player != null:
		velocity = as_player.velocity
		aim = as_player.aim_direction
	return WorldGen.herald_heading(velocity, aim)
