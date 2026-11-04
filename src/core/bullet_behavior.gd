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

## Which of the four event hooks a behaviour implements (on_update is not part of this: it
## is called for every hooked bullet every tick). BulletManager calls only the hooks in
## the mask, and only those set `BulletPool.hook_ran` (so the clock/motion sweep runs after
## them). An inherited no-op hook can write nothing and costs nothing.
const HOOK_ON_SPAWN := 1
const HOOK_ON_HIT := 2
const HOOK_CAN_HIT := 4
const HOOK_ON_DESPAWN := 8
const HOOK_ALL := 15
## Value of `hook_mask` that means "work it out from the script".
const HOOK_AUTO := -1

## Normally leave this alone: the manager detects which hooks the script overrides (when the
## behaviour is registered, again by `BulletManager.refresh_behavior()`, and by itself
## whenever it sees `set_script()` has given the object a different script). Set an
## explicit mask (e.g. `HOOK_ALL`) only for a behaviour whose hooks are not plain method
## overrides, such as an adapter that forwards to a runtime-assigned Callable or an
## interpreter; hooks outside an explicit mask are not called. It is read on every
## dispatch, so changing it at any time takes effect at once. In debug builds an
## explicit mask that leaves out a hook the script does override is an assertion failure.
var hook_mask: int = HOOK_AUTO

## Set by the emitter on registration; use it to spawn child bullets. A child
## spawned from inside a hook takes the `owner_layer` of the bullet whose hook
## spawned it, whatever its ShotRequest says (a differing owner is ignored with a
## capped warning); only reflect() changes an owner. Velocities written to
## pool.vel[index] in a hook are held to BulletLimits.MAX_SPEED (4,000 px/s), a
## NaN or inf kills the bullet as DespawnReason.INVALID.
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


## The hooks `b`'s script overrides, as HOOK_* bits. A behaviour whose script cannot be
## inspected gets every bit (calling and flagging a no-op is only slow, missing a hook
## would be wrong). Inherited GDScript methods are listed once per class in the chain that
## defines them, so a hook defined more than once is an override.
static func detect_hooks(b: BulletBehavior) -> int:
	var s: Script = b.get_script()
	if s == null:
		return HOOK_ALL
	var names := ["on_spawn", "on_hit", "can_hit", "on_despawn"]
	var counts := [0, 0, 0, 0]
	for d: Dictionary in s.get_script_method_list():
		var k: int = names.find(str(d["name"]))
		if k >= 0:
			counts[k] += 1
	var mask := 0
	for k in 4:
		if counts[k] > 1:
			mask |= 1 << k
	return mask
