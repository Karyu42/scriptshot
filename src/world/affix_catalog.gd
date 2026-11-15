class_name AffixCatalog
extends RefCounted
## Affix resources and the exclusions this slice has to encode even though a
## T0 roll never pairs them. Splitting × Summoner is the spawn-overload
## exclusion (spawning §3.4). Drifter has no base exclusion.

const SPLITTING := &"splitting"
const SUMMONER := &"summoner"
const BULWARK := &"bulwark"
## Offensive L4 stamp: Null telegraphs and shots. Not rolled onto Herald or
## natural T0 elites in this slice; tests and later content opt in.
const NULL_SHOT := &"null_shot"
const HERALD_AFFIXES: Array[StringName] = [SPLITTING, SUMMONER]

static var _null_shot_def: AffixDef


static func get_affix(id: StringName) -> AffixDef:
	if id == NULL_SHOT:
		return _null_shot()
	var loaded: Resource = load("res://resources/affixes/%s.tres" % String(id))
	var def := loaded as AffixDef
	if def == null:
		push_error("AffixCatalog: missing affix %s" % String(id))
	return def


static func _null_shot() -> AffixDef:
	if _null_shot_def == null:
		var def := AffixDef.new()
		def.id = NULL_SHOT
		def.group = AffixDef.GROUP_OFFENSIVE
		_null_shot_def = def
	return _null_shot_def


## False for Splitting × Summoner, either order. A pair of the same id is not
## a second affix; callers that roll one id do not ask.
static func allows_pair(a: StringName, b: StringName) -> bool:
	if a == SPLITTING and b == SUMMONER:
		return false
	if a == SUMMONER and b == SPLITTING:
		return false
	return true
