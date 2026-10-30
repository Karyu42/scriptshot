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
