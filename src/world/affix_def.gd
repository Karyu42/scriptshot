class_name AffixDef
extends Resource
## One affix, common intensity (first-playable §3, spawning §3.4).
## L2 reads the Spawn columns. Bulwark, Phasing and Null-shot are L4 and have
## no resource yet; their fields are not on this type until that layer.

const GROUP_SPAWN := &"spawn"
const GROUP_DEFENSIVE := &"defensive"
const GROUP_OFFENSIVE := &"offensive"
## Elite rarity, as the affix reads it. Only Summoner has a rare column so far.
## Legendary signatures use the common numbers (vertical-slice §4, Hydra).
const RARITY_COMMON := 0
const RARITY_RARE := 1
const RARITY_LEGENDARY := 2

@export var id := StringName()
@export var group := StringName()
@export var min_tier := 0
## Splitting.
@export var halves := 0
@export var hp_fraction := 0.0
@export var speed_mul := 1.0
@export var resplit := false
## Summoner, common intensity. `interval` is the cooldown between two waves
## (design floor 4 s), `count` the bodies per wave, `max_alive` the cap on
## living summons per Summoner, `summon_hp` each body's HP. 1 HP means one
## BasicShot or Straight hit kills a summon (issue #81).
@export var interval := 0.0
@export var count := 0
@export var max_alive := 0
@export var summon_hp := 1.0
@export var drop := false
## Summoner, rare intensity (vertical-slice §4, room D): read when the elite's
## rarity is RARITY_RARE. A value <= 0 falls back to the common column.
@export var rare_interval := 0.0
@export var rare_count := 0
@export var rare_max_alive := 0


func summon_interval(rarity: int) -> float:
	if rarity == RARITY_RARE and rare_interval > 0.0:
		return rare_interval
	return interval


func summon_count(rarity: int) -> int:
	if rarity == RARITY_RARE and rare_count > 0:
		return rare_count
	return count


func summon_cap(rarity: int) -> int:
	if rarity == RARITY_RARE and rare_max_alive > 0:
		return rare_max_alive
	return max_alive
