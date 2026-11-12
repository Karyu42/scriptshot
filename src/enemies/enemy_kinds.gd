class_name EnemyKinds
extends RefCounted
## Stable kind names and rarity values for enemies, shared by GameEvents,
## WorldQuery and scripts. These StringNames are save- and script-facing: never
## rename one, only add new ones.

## T0 regular Drifter (RegularEnemy.ARCH_DRIFTER).
const DRIFTER := &"drifter"
## T0 regular Swarmer, also the adds a Summoner elite brings in.
const SWARMER := &"swarmer"
## Natural common elite (an EliteEnemy that is not the Herald).
const ELITE_DRIFTER := &"elite_drifter"
## The guaranteed Herald elite (EliteEnemy with is_herald).
const HERALD := &"herald"
## One half of a Splitting elite. Not an elite itself: no cue, no shard.
const SPLIT_HALF := &"split_half"
## Reserved for the vertical-slice boss (comes in a later PR).
const WARDEN := &"warden"

## Rarity of an enemy that is not an elite or a boss (regulars, halves, adds).
const RARITY_NONE := -1
## Elite / boss rarities. Same order as the rarity cue (common, rare, legendary).
const RARITY_COMMON := 0
const RARITY_RARE := 1
const RARITY_LEGENDARY := 2
