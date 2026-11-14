class_name SliceHydraAlcove
extends Node2D
## Vertical-slice row 12 / §4: the authored legendary Hydra in the alcove
## off room D's south door. `hydra_dead` and +10 shards watch the original
## body only (its first split). Halves and summons grant no shard, do not
## write the flag, and do not return on load. G5 is not this fight's gate.

const GROUP := &"slice_hydra_alcove"
## Alcove centre (vertical-slice §2).
const ANCHOR := Vector2(7616, 1152)
const SHARDS := 10
const SIGNATURE := "Hydra"

@export var elite_scene: PackedScene

var player: Node2D
var save: SaveGame
var world_seed := 0

var hydra: EliteEnemy

var _bound := false


func bind(
	p_player: Node2D,
	p_save: SaveGame = null,
	p_seed: int = 0,
) -> void:
	player = p_player
	save = p_save
	world_seed = p_seed
	if save != null and save.hydra_dead:
		_bound = true
		return
	# A reload before the kill spawns a fresh body, so the fight resets
	# to full HP. Same rule as SliceRoomD.
	_spawn()
	_bound = true


func hydra_alive() -> bool:
	return hydra != null and is_instance_valid(hydra) and hydra.is_alive()


func _spawn() -> void:
	_clear()
	var packed := _packed(elite_scene, "res://scenes/elite_enemy.tscn")
	if packed == null:
		return
	var body := packed.instantiate() as EliteEnemy
	if body == null:
		return
	body.name = "AlcoveHydra"
	# signature_name and rarity must be set before add_child: _ready copies
	# them onto the legendary cue (row 13 / #110).
	body.signature_name = SIGNATURE
	body.configure_elite(
		AffixCatalog.SPLITTING,
		ANCHOR,
		ANCHOR,
		world_seed,
		player,
		false,
		false,
		WorldGen.chunk_of(ANCHOR),
		-1,
		AffixDef.RARITY_LEGENDARY,
		[AffixCatalog.SUMMONER] as Array[StringName],
	)
	body.wake_rect = SliceLayout.room_rect(SliceLayout.ROOM_ALCOVE)
	body.summon_after_wake = true
	body.halves_resplit = true
	# The alcove grants the +10 shards itself. The body must not also
	# emit shard_dropped (a 1-shard natural-elite drop).
	body.grants_shard = false
	body.add_to_group(GROUP)
	add_child(body)
	body.died.connect(_on_hydra_died)
	hydra = body


func _on_hydra_died() -> void:
	# One persist: hydra_dead and the +10 shards land together on the tick
	# the original body dies (its first split). Halves and summons do not
	# write again. G5 is unchanged.
	if save != null and not save.hydra_dead:
		save.hydra_dead = true
		save.shards += SHARDS
		save.save()


func _clear() -> void:
	if hydra != null and is_instance_valid(hydra):
		if hydra.died.is_connected(_on_hydra_died):
			hydra.died.disconnect(_on_hydra_died)
	for child in get_children():
		remove_child(child)
		child.free()
	hydra = null


func _packed(override: PackedScene, path: String) -> PackedScene:
	if override != null:
		return override
	return load(path) as PackedScene
