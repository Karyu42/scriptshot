class_name BulletBehavior
extends RefCounted
## Per-bullet hooks. Subclass, override what you need, register with
## ShotEmitter.register_behavior() and put the returned id in
## ShotRequest.behavior_id. Bullets with behavior_id == 0 never call into
## script code, which keeps the hot path fast.
##
## `index` is the bullet's slot in `pool`; it is only valid for the duration of
## the call (slots are reused when other bullets despawn). Read and write the
## pool's arrays directly, e.g. pool.vel[index] = ..., pool.param_a[index].

## Set by the emitter on registration; use it to spawn child bullets.
var emitter: ShotEmitter


## Right after the bullet was spawned.
func on_spawn(_pool: BulletPool, _index: int) -> void:
	pass


## Once per physics tick after integration, while the bullet is alive.
## Changes to velocity / heading take effect on the next tick.
func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
	pass


## Veto for a hit that is about to land; only asked for bullets spawned with
## ShotRequest.can_hit_veto. Return false to let the bullet ignore `hurtbox`:
## no damage, no on_hit, no pierce used, the bullet is not consumed and flies on
## (it is asked again next tick while it still overlaps the target). Runs before
## any damage or pierce bookkeeping; keep it cheap and do not despawn or spawn
## from it (use on_hit / on_update for that).
func can_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> bool:
	return true


## When the bullet overlaps a hurtbox, before the bullet is despawned
## (pierce > 0 keeps it alive). The hurtbox's own `hit` signal fires first.
func on_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
	pass


## Just before the bullet is removed. `reason` is a BulletPool.DespawnReason.
func on_despawn(_pool: BulletPool, _index: int, _reason: int) -> void:
	pass
