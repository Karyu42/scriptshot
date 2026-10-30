class_name ShotContext
extends RefCounted
## Everything a ShotPattern needs to know about the moment of firing.

## World-space muzzle position (already offset from the shooter's origin).
var muzzle_position := Vector2.ZERO
## Aim direction as a unit vector, and the same as an angle in radians.
var aim_direction := Vector2.RIGHT
var aim_angle := 0.0
## Shooter's current velocity (px/s), for patterns that inherit momentum.
var shooter_velocity := Vector2.ZERO
## Layers (see Layers) the fired bullets should be able to hit.
var target_mask := Layers.ENEMY
## Seconds since the weapon was equipped / the scene started.
var time := 0.0
## Counts up by one for every trigger pull handled by the pattern.
var shot_index := 0
