class_name EliteCue
extends RarityCue
## Common-elite cue. Drawing, the 12-cue cap, and the 0.3 s brighten are
## RarityCue at TIER_ELITE_COMMON, so the tier the game already spawns stays
## on the same component as rare, legendary, and boss cues.


func _init() -> void:
	super._init()
