class_name EnemyKinds
extends RefCounted
## Stable kind names and rarity values for enemies, shared by GameEvents,
## WorldQuery and scripts. These StringNames are save- and script-facing: never
## rename one, only add new ones.

## The kinds of this slice (docs/design/vertical-slice.md §6.2). A kind is
## the body, not its role: elite drifters, the Herald, Splitting halves and
## Hydra summons are all DRIFTER; Summoner adds are SWARMER. Rarity (below)
## is what tells an elite from a regular.
const DRIFTER := &"drifter"
const SWARMER := &"swarmer"
const SHIELDBEARER := &"shieldbearer"
const SNIPER := &"sniper"
const HUSK := &"husk"
## The vertical-slice boss (Warden, row 8).
const WARDEN := &"warden"
## Tutorial training dummy (TrainingDummy).
const DUMMY := &"dummy"
## Every kind above, in the spec's order.
const ALL: Array[StringName] = [DRIFTER, SWARMER, SHIELDBEARER, SNIPER, HUSK, WARDEN, DUMMY]

## Rarity of an enemy that is not an elite or a boss (regulars, halves, adds).
const RARITY_NONE := -1
## Elite / boss rarities. Same order as the rarity cue (common, rare, legendary).
const RARITY_COMMON := 0
const RARITY_RARE := 1
const RARITY_LEGENDARY := 2
