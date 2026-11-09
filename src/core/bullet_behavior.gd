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

## How this behaviour wants its per-tick update. AUTO follows the script:
## an `on_update_batch` override with no per-bullet hook is a batch behavior,
## and an `on_update` override stays per-bullet. BATCH forces the batch
## callback even when the script also has per-bullet hooks; those bullets stay
## on the pool (per-bullet storage wins) and the batch callback still runs
## over them. PER_BULLET never calls `on_update_batch`.
enum UpdateMode { AUTO, PER_BULLET, BATCH }
var update_mode := UpdateMode.AUTO

## Normally leave this alone: the manager detects which hooks the script overrides (when the
## behaviour is registered, again by `BulletManager.refresh_behavior()`, and by itself
## whenever it sees `set_script()` has given the object a different script). Set an
## explicit mask (e.g. `HOOK_ALL`) only for a behaviour whose hooks are not plain method
## overrides, such as an adapter that forwards to a runtime-assigned Callable or an
## interpreter; hooks outside an explicit mask are not called. It is read on every
## dispatch, so changing it at any time takes effect at once. In debug builds an
## explicit mask that leaves out a hook the script does override is an assertion failure.
var hook_mask: int = HOOK_AUTO

## An adapter that forwards every hook to an interpreter overrides all four methods, whatever
## the interpreted script defines, so an explicit mask narrower than its overrides is
## intentional there. Set this to true next to `hook_mask` to say so: the debug check that
## an explicit mask does not leave out an overridden hook is then skipped for this
## behaviour. Leave it false for ordinary GDScript behaviours.
var hook_mask_exact := false

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


## Once per physics tick, after integration and before collision, with every
## bullet of this behaviour that is on the batch path. Writes on `batch` are
## copies; the sim applies them when this returns. See BatchView.
## A behavior that also overrides `on_update` is not called here unless
## `update_mode` is BATCH (both would steer). Per-bullet hooks keep the
## bullet on the GDScript pool either way.
func on_update_batch(_batch: BatchView) -> void:
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


## The hooks `b`'s script overrides, as HOOK_* bits. See detect_script_hooks().
static func detect_hooks(b: BulletBehavior) -> int:
	var s: Script = b.get_script()
	return detect_script_hooks(s)


## True when `b`'s script overrides `on_update`. The event mask does not cover
## on_update: a bullet with behavior_id != 0 still receives the base call unless
## the script never replaced it. A script that cannot be inspected (null, C#, a
## GDExtension language) is treated as overriding it, same as detect_script_hooks
## returning every event bit: missing a real hook would be wrong.
static func overrides_on_update(b: BulletBehavior) -> bool:
	var s: Script = b.get_script()
	return script_overrides_on_update(s)


static func script_overrides_on_update(s: Script) -> bool:
	if s == null or not s is GDScript:
		return true
	return _method_overridden(s, "on_update")


## True when `b`'s script overrides `on_update_batch`. Same rule as
## overrides_on_update: a script that cannot be inspected counts as overriding,
## so a real batch hook is not missed. The manager still requires the absence
## of per-bullet hooks before it stores those bullets natively.
static func overrides_on_update_batch(b: BulletBehavior) -> bool:
	var s: Script = b.get_script()
	return script_overrides_on_update_batch(s)


static func script_overrides_on_update_batch(s: Script) -> bool:
	if s == null or not s is GDScript:
		return true
	return _method_overridden(s, "on_update_batch")


static func _method_overridden(s: Script, method: String) -> bool:
	var count := 0
	for d: Dictionary in s.get_script_method_list():
		if str(d["name"]) == method:
			count += 1
	return count > 1


## The hooks overridden by `s`, as HOOK_* bits. This relies on GDScript's per-class method
## listing (an inherited method is listed once per class that defines it, so a hook listed
## twice is an override). A script that cannot be inspected that way (null, C#, a GDExtension
## language, anything that is not a GDScript) gets every bit: calling and flagging a no-op is
## only slow, missing a hook would be wrong.
static func detect_script_hooks(s: Script) -> int:
	if s == null or not s is GDScript:
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


## HOOK_* bits for the callbacks a script defines, for an adapter that forwards the four
## event hooks to an interpreter (Lua): pass the names of the functions the script has.
## Engine names and the script-side spellings both count: `on_spawn`; `on_hit`; `can_hit`;
## `on_despawn`, `on_death`, `on_expire`, `on_wall` (all end in on_despawn). Anything else
## (`on_tick`, `on_batch`, `state`, ...) is not an event hook and is ignored. Typical use:
## `behavior.hook_mask = BulletBehavior.mask_from_names(lua_function_names)`, again (and
## `manager.refresh_behavior(id)`) after the script was reloaded.
##
## TODO: `on_wall` maps to HOOK_ON_DESPAWN only while a wall hit kills the bullet
## (it is delivered as on_despawn / on_death with why "wall"). If a wall bounce
## becomes a non-fatal event (OI-17), `on_wall` needs its own bit, or a mapping
## to whichever hook actually delivers it.
static func mask_from_names(names: PackedStringArray) -> int:
	var mask := 0
	for n in names:
		match n:
			"on_spawn":
				mask |= HOOK_ON_SPAWN
			"on_hit":
				mask |= HOOK_ON_HIT
			"can_hit":
				mask |= HOOK_CAN_HIT
			"on_despawn", "on_death", "on_expire", "on_wall":
				mask |= HOOK_ON_DESPAWN
	return mask
