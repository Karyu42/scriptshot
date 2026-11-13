class_name SliceRoomD
extends Node2D
## Vertical-slice row 7: the authored rare elite in room D, at the room
## centre, plus one escort Drifter 48 px further from the origin. G5 and
## `slice_rare_dead` watch the elite body only. The escort and summons
## grant no shard and do not open the gate. Reload does not respawn either.

const GROUP := &"slice_room_d"
## Room D centre (vertical-slice §2). The spec names the room, not a point.
const ANCHOR := Vector2(7680, 0)
const SHARDS := 3

@export var elite_scene: PackedScene
@export var escort_scene: PackedScene

var player: Node2D
var progress: SliceProgress
var save: SaveGame
var world_seed := 0

var elite: EliteEnemy
var escort: RegularEnemy

var _bound := false


func bind(
	p_player: Node2D,
	p_progress: SliceProgress,
	p_save: SaveGame = null,
	p_seed: int = 0,
) -> void:
	player = p_player
	progress = p_progress
	save = p_save
	world_seed = p_seed
	if save != null and save.slice_rare_dead:
		_bound = true
		return
	_spawn()
	_bound = true


func elite_alive() -> bool:
	return elite != null and is_instance_valid(elite) and elite.is_alive()


func escort_alive() -> bool:
	return escort != null and is_instance_valid(escort) and escort.is_alive()


func _spawn() -> void:
	_clear()
	var packed_elite := _packed(elite_scene, "res://scenes/elite_enemy.tscn")
	if packed_elite == null:
		return
	var body := packed_elite.instantiate() as EliteEnemy
	if body == null:
		return
	body.name = "RoomDElite"
	body.configure_elite(
		AffixCatalog.BULWARK,
		ANCHOR,
		ANCHOR,
		world_seed,
		player,
		false,
		false,
		WorldGen.chunk_of(ANCHOR),
		-1,
		AffixDef.RARITY_RARE,
		[AffixCatalog.SUMMONER] as Array[StringName],
	)
	body.wake_x = SliceLayout.gate_rect(SliceLayout.GATE_G4).position.x
	body.summon_after_wake = true
	body.add_to_group(GROUP)
	add_child(body)
	body.died.connect(_on_elite_died)
	elite = body
	_spawn_escort()


func _spawn_escort() -> void:
	var packed := _packed(escort_scene, "res://scenes/regular_enemy.tscn")
	if packed == null:
		return
	var pos := RegularEnemy.push_centre_outside(
		WorldGen.escort_position(ANCHOR),
		RegularEnemy.radius_of(RegularEnemy.ARCH_DRIFTER),
	)
	var body := packed.instantiate() as RegularEnemy
	if body == null:
		return
	body.name = "RoomDEscort"
	body.configure(
		RegularEnemy.ARCH_DRIFTER,
		ANCHOR,
		pos,
		world_seed,
		WorldGen.chunk_of(ANCHOR),
		-1,
		0,
		player,
	)
	body.add_to_group(GROUP)
	add_child(body)
	escort = body


func _on_elite_died() -> void:
	# Set the slot first so notify_room_d_elite_died()'s persist writes the
	# flag, the +3 shards, and the G5 bit together.
	if save != null and not save.slice_rare_dead:
		save.slice_rare_dead = true
		save.shards += SHARDS
	if progress != null:
		progress.notify_room_d_elite_died()
	elif save != null:
		save.save()


func _clear() -> void:
	if elite != null and is_instance_valid(elite):
		if elite.died.is_connected(_on_elite_died):
			elite.died.disconnect(_on_elite_died)
	for child in get_children():
		remove_child(child)
		child.free()
	elite = null
	escort = null


func _packed(override: PackedScene, path: String) -> PackedScene:
	if override != null:
		return override
	return load(path) as PackedScene
