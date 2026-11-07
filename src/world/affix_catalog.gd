class_name AffixCatalog
extends RefCounted
## Affix resources and the exclusions this slice has to encode even though a
## T0 roll never pairs them. Splitting × Summoner is the spawn-overload
## exclusion (spawning §3.4). Drifter has no base exclusion.

const SPLITTING := &"splitting"
const SUMMONER := &"summoner"
const HERALD_AFFIXES: Array[StringName] = [SPLITTING, SUMMONER]


static func get_affix(id: StringName) -> AffixDef:
	var loaded: Resource = load("res://resources/affixes/%s.tres" % String(id))
	var def := loaded as AffixDef
	if def == null:
		push_error("AffixCatalog: missing affix %s" % String(id))
	return def


## False for Splitting × Summoner, either order. A pair of the same id is not
## a second affix; callers that roll one id do not ask.
static func allows_pair(a: StringName, b: StringName) -> bool:
	if a == SPLITTING and b == SUMMONER:
		return false
	if a == SUMMONER and b == SPLITTING:
		return false
	return true
