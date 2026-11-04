extends GutTest
## Follow-ups to the hook mask (PR #14 review): the explicit-mask check is keyed on
## (mask, script), detection gives every bit to a script it cannot inspect, and
## BulletBehavior.mask_from_names() is the way for an interpreter adapter to build a mask.
var m: BulletManager


func before_each() -> void:
	ScriptWarnings.reset()
	m = BulletManager.new()
	m.capacity = 64
	m.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)


class SpawnOnly:
	extends BulletBehavior
	func on_spawn(_p: BulletPool, _i: int) -> void:
		pass


class DespawnOnly:
	extends BulletBehavior
	func on_despawn(_p: BulletPool, _i: int, _r: int) -> void:
		pass


class UpdateOnly:
	extends BulletBehavior
	func on_update(_p: BulletPool, _i: int, _d: float) -> void:
		pass


func _req(beh: int) -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2(10, 0), Vector2(10, 0))
	r.lifetime = 5.0
	r.behavior_id = beh
	return r


# --- (1) the explicit-mask check is keyed on (mask, script) ---------------------------------

func test_an_explicit_mask_is_checked_again_when_the_script_changes() -> void:
	var b := UpdateOnly.new()
	b.hook_mask = BulletBehavior.HOOK_ON_SPAWN  # covers nothing the script overrides: fine
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 1)
	m.spawn(_req(bid))
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 1, "same mask, same script: checked once")
	# set_script() re-initialises the object's properties (hook_mask goes back to AUTO), so the
	# new script's owner sets the same explicit mask value again.
	b.set_script(SpawnOnly)
	b.hook_mask = BulletBehavior.HOOK_ON_SPAWN
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 2, "same mask, other script: checked again")
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 2)
	b.set_script(UpdateOnly)
	b.hook_mask = BulletBehavior.HOOK_ON_SPAWN
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 3, "and again when it swaps back")
	b.hook_mask = BulletBehavior.HOOK_ON_SPAWN | BulletBehavior.HOOK_ON_HIT
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 4, "another mask, same script: checked")


func test_set_script_resets_an_explicit_mask_to_auto_so_the_new_script_is_detected() -> void:
	var b := UpdateOnly.new()
	b.hook_mask = 0
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran)
	b.set_script(SpawnOnly)
	assert_eq(b.hook_mask, BulletBehavior.HOOK_AUTO, "properties are re-initialised by set_script")
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran, "so the new on_spawn is seen")


func test_refresh_behavior_makes_the_explicit_mask_be_checked_again() -> void:
	var b := SpawnOnly.new()
	b.hook_mask = BulletBehavior.HOOK_ALL
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 1)
	m.refresh_behavior(bid)
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 2)


# --- (2) a script that is not a GDScript gets every hook ------------------------------------

func test_a_script_that_is_not_a_gdscript_is_assumed_to_have_every_hook() -> void:
	var s: Script = ScriptExtension.new()  # a Script that is not a GDScript (empty method list)
	assert_false(s is GDScript)
	assert_eq(BulletBehavior.detect_script_hooks(s), BulletBehavior.HOOK_ALL)


func test_a_missing_script_gets_every_hook_and_gdscripts_are_still_counted() -> void:
	assert_eq(BulletBehavior.detect_script_hooks(null), BulletBehavior.HOOK_ALL)
	assert_eq(BulletBehavior.detect_script_hooks(SpawnOnly), BulletBehavior.HOOK_ON_SPAWN)
	assert_eq(BulletBehavior.detect_script_hooks(DespawnOnly), BulletBehavior.HOOK_ON_DESPAWN)
	assert_eq(BulletBehavior.detect_script_hooks(UpdateOnly), 0)
	assert_eq(BulletBehavior.detect_script_hooks(BulletBehavior), 0, "the base class itself")
	assert_eq(BulletBehavior.detect_hooks(SpawnOnly.new()), BulletBehavior.HOOK_ON_SPAWN)


# --- (3) mask_from_names for an interpreter adapter -----------------------------------------

func test_mask_from_names_maps_script_callbacks_to_hook_bits() -> void:
	var S := BulletBehavior.HOOK_ON_SPAWN
	var H := BulletBehavior.HOOK_ON_HIT
	var C := BulletBehavior.HOOK_CAN_HIT
	var D := BulletBehavior.HOOK_ON_DESPAWN
	assert_eq(BulletBehavior.mask_from_names(PackedStringArray()), 0)
	assert_eq(BulletBehavior.mask_from_names(PackedStringArray(["on_spawn"])), S)
	assert_eq(BulletBehavior.mask_from_names(PackedStringArray(["on_hit"])), H)
	assert_eq(BulletBehavior.mask_from_names(PackedStringArray(["can_hit"])), C)
	assert_eq(BulletBehavior.mask_from_names(PackedStringArray(["on_despawn"])), D)
	for n: String in ["on_death", "on_expire", "on_wall"]:
		assert_eq(BulletBehavior.mask_from_names(PackedStringArray([n])), D, n)
	assert_eq(BulletBehavior.mask_from_names(PackedStringArray(["on_spawn", "on_hit", "can_hit", "on_death"])), BulletBehavior.HOOK_ALL)
	assert_eq(
		BulletBehavior.mask_from_names(PackedStringArray(["on_tick", "on_batch", "on_near", "state", "on_spawn", "on_spawn"])),
		S,
		"not event hooks: ignored; duplicates are fine"
	)


## What a Lua adapter does: overrides every hook (to forward them), sets the mask from the
## script's functions and says it is exact.
class FakeAdapter:
	extends BulletBehavior
	var calls: Array[String] = []
	func on_spawn(_p: BulletPool, _i: int) -> void:
		calls.append("on_spawn")
	func on_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> void:
		calls.append("on_hit")
	func can_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> bool:
		calls.append("can_hit")
		return true
	func on_despawn(_p: BulletPool, _i: int, _r: int) -> void:
		calls.append("on_despawn")


func test_an_adapter_with_a_narrow_mask_only_gets_the_hooks_its_script_defines() -> void:
	var a := FakeAdapter.new()
	a.hook_mask = BulletBehavior.mask_from_names(PackedStringArray(["on_death"]))
	a.hook_mask_exact = true
	var bid := m.register_behavior(a)
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran, "the script has no on_spawn: nothing was called, nothing flagged")
	assert_eq(a.calls.size(), 0)
	# The Lua script is reloaded and now defines on_spawn too.
	a.hook_mask = BulletBehavior.mask_from_names(PackedStringArray(["on_death", "on_spawn"]))
	m.refresh_behavior(bid)
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran)
	assert_eq(a.calls, ["on_spawn"] as Array[String])


func test_exact_masks_skip_the_debug_check_and_others_do_not() -> void:
	var a := FakeAdapter.new()
	a.hook_mask = 0  # narrower than its overrides: only legal because it says it is exact
	a.hook_mask_exact = true
	var bid := m.register_behavior(a)
	m.spawn(_req(bid))
	assert_eq(m._declared_checks, 1, "the mask was looked at (and, being exact, accepted)")
	assert_eq(a.calls.size(), 0)
