class_name AffixDef
extends Resource
## One affix, common intensity (first-playable §3, spawning §3.4).
## L2 reads the Spawn columns. Bulwark, Phasing and Null-shot are L4 and have
## no resource yet; their fields are not on this type until that layer.

const GROUP_SPAWN := &"spawn"
const GROUP_DEFENSIVE := &"defensive"
const GROUP_OFFENSIVE := &"offensive"

@export var id := StringName()
@export var group := StringName()
@export var min_tier := 0
## Splitting.
@export var halves := 0
@export var hp_fraction := 0.0
@export var speed_mul := 1.0
@export var resplit := false
## Summoner.
@export var interval := 0.0
@export var count := 0
@export var max_alive := 0
@export var drop := false
