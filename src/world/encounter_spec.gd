class_name EncounterSpec
extends RefCounted
## One encounter inside a chunk, as produced by WorldGen.chunk_encounters.
## Pure data: spawning code reads it and instances bodies. No node, no scene.

var chunk := Vector2i.ZERO
var index := 0
var anchor := Vector2.ZERO
var is_elite := false
## 0 = common. This slice never writes another rarity.
var rarity := 0
## &"drifter" when the encounter is an elite. Regular packs leave it empty and
## describe themselves through `members`.
var base := StringName()
var affix_ids: Array[StringName] = []
## Regulars or escorts: each entry is {archetype: StringName, count: int}.
var members: Array[Dictionary] = []
var points_spent := 0


func archetype_of(i: int) -> StringName:
	var entry: Dictionary = members[i]
	@warning_ignore("unsafe_cast")
	var value: StringName = entry.get("archetype", &"")
	return value


func count_of(i: int) -> int:
	var entry: Dictionary = members[i]
	@warning_ignore("unsafe_cast")
	var value: int = entry.get("count", 0)
	return value
