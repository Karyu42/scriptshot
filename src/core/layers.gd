class_name Layers
extends RefCounted
## Physics / collision layer bit values. Names match the layer names in
## project.godot ([layer_names] 2d_physics) so the same masks can be used for
## PhysicsServer2D queries, CollisionObject2D nodes and the bullet system.

const PLAYER := 1 << 0
const ENEMY := 1 << 1
const PLAYER_BULLET := 1 << 2
const ENEMY_BULLET := 1 << 3
const WORLD := 1 << 4

## Everything that can be damaged by bullets.
const DAMAGEABLE := PLAYER | ENEMY


## The hurtbox layers a shooter on `shooter_layer` is allowed to damage: the
## other side only, so there is no friendly fire (PLAYER <-> ENEMY).
static func hostile_to(shooter_layer: int) -> int:
	if shooter_layer & PLAYER:
		return ENEMY
	if shooter_layer & ENEMY:
		return PLAYER
	return 0
