extends GutTest
## BulletBehavior.hook_mask / BulletManager._hooks_of: only the event hooks a behaviour really
## has are called and raise BulletPool.hook_ran (so the sweeps run), and the answer cannot go
## stale when the behaviour's script changes.
const DT := 1.0 / 60.0
var m: BulletManager


func before_each() -> void:
	ScriptWarnings.reset()
	m = BulletManager.new()
	m.backend_preference = "gdscript"
	m.capacity = 64
	m.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)


## Pokes a speed over the ceiling into slot 0 (a plain bullet) from `on_update`.
class UpdateOnly:
	extends BulletBehavior
	func on_update(_p: BulletPool, _i: int, _d: float) -> void:
		pass


class SpawnOnly:
	extends BulletBehavior
	var calls := 0
	func on_spawn(_p: BulletPool, _i: int) -> void:
		calls += 1


class HitOnly:
	extends BulletBehavior
	var calls := 0
	func on_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> void:
		calls += 1


class CanHitOnly:
	extends BulletBehavior
	var calls := 0
	func can_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> bool:
		calls += 1
		return true


class DespawnOnly:
	extends BulletBehavior
	var calls := 0
	func on_despawn(_p: BulletPool, _i: int, _r: int) -> void:
		calls += 1


class Mid:
	extends BulletBehavior
	func on_spawn(_p: BulletPool, _i: int) -> void:
		pass


## Overrides on_hit only, one level below a class that overrides on_spawn only.
class Leaf:
	extends Mid
	func on_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> void:
		pass


class AllHooks:
	extends BulletBehavior
	func on_spawn(_p: BulletPool, _i: int) -> void:
		pass
	func on_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> void:
		pass
	func can_hit(_p: BulletPool, _i: int, _h: Hurtbox) -> bool:
		return true
	func on_despawn(_p: BulletPool, _i: int, _r: int) -> void:
		pass


const S := BulletBehavior.HOOK_ON_SPAWN
const H := BulletBehavior.HOOK_ON_HIT
const C := BulletBehavior.HOOK_CAN_HIT
const D := BulletBehavior.HOOK_ON_DESPAWN


func test_detection_finds_exactly_the_overridden_hooks() -> void:
	assert_eq(BulletBehavior.detect_hooks(BulletBehavior.new()), 0, "the base: nothing")
	assert_eq(BulletBehavior.detect_hooks(UpdateOnly.new()), 0, "on_update is not an event hook")
	assert_eq(BulletBehavior.detect_hooks(SpawnOnly.new()), S)
	assert_eq(BulletBehavior.detect_hooks(HitOnly.new()), H)
	assert_eq(BulletBehavior.detect_hooks(CanHitOnly.new()), C)
	assert_eq(BulletBehavior.detect_hooks(DespawnOnly.new()), D)
	assert_eq(BulletBehavior.detect_hooks(Mid.new()), S)
	assert_eq(BulletBehavior.detect_hooks(Leaf.new()), S | H, "an override two levels up still counts")
	assert_eq(BulletBehavior.detect_hooks(AllHooks.new()), BulletBehavior.HOOK_ALL)


func _req(beh: int, at := Vector2(300, 0), life := 5.0) -> ShotRequest:
	var r := ShotRequest.with_velocity(at, Vector2(10, 0))
	r.lifetime = life
	r.behavior_id = beh
	r.hit_mask = Layers.ENEMY
	return r


## One tick in which the behaviour's bullet (slot 0) is spawned, hit once by a hurtbox
## (with the veto asked) and despawned by that hit. Returns the sweeps that tick ran.
func _site_sweeps(beh: BulletBehavior) -> int:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 12.0
	add_child_autofree(hb)
	hb.global_position = Vector2(300, 0)
	var bid := m.register_behavior(beh)
	var r := _req(bid)
	r.can_hit_veto = true
	m.emitter.request_shot_id(r)
	m.pool.hook_ran = false
	var before := m.pool.sweeps_run
	m.step(DT)
	return m.pool.sweeps_run - before


func test_base_behavior_hooks_set_no_flag_and_cost_no_sweep_beyond_the_update_one() -> void:
	var bid := m.register_behavior(BulletBehavior.new())
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran, "the base on_spawn is a no-op: no flag")
	# One tick with hit, veto and despawn: only the post-on_update sweep (the update loop
	# does run for any hooked bullet).
	var base_sweeps := _site_sweeps(BulletBehavior.new())
	assert_eq(base_sweeps, 1, "no start sweep, no end sweep")


func test_a_plain_bullet_hit_and_despawned_runs_no_sweep_at_all() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 12.0
	add_child_autofree(hb)
	hb.global_position = Vector2(300, 0)
	m.emitter.request_shot_id(_req(0))
	var before := m.pool.sweeps_run
	m.step(DT)
	assert_eq(m.pool.sweeps_run, before)


func test_an_on_spawn_only_subclass_flags_the_pool() -> void:
	var b := SpawnOnly.new()
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran)
	assert_eq(b.calls, 1)


func test_each_other_hook_alone_is_called_and_gets_its_end_of_step_sweep() -> void:
	# The spawn call of UpdateOnly-like classes raises nothing; the sweep count tells which
	# hooks flagged: post-update (1) plus the end-of-step sweep (1) when a hook ran.
	var hit := HitOnly.new()
	assert_eq(_site_sweeps(hit), 2, "on_hit alone: the end sweep ran")
	assert_eq(hit.calls, 1)
	var can := CanHitOnly.new()
	assert_eq(_site_sweeps(can), 2, "can_hit alone: the end sweep ran")
	assert_eq(can.calls, 1)
	var des := DespawnOnly.new()
	assert_eq(_site_sweeps(des), 2, "on_despawn alone: the end sweep ran")
	assert_eq(des.calls, 1)


## The flag is what makes the sweep catch a bad write: a behaviour that overrides only
## on_despawn and pokes a plain bullet must get it cleaned.
class DespawnPoker:
	extends BulletBehavior
	func on_despawn(pool: BulletPool, _i: int, _r: int) -> void:
		pool.vel[0] = Vector2(1.0e9, 0.0)
		pool.lifetime[0] = INF


func test_an_on_despawn_only_poker_still_gets_its_write_swept() -> void:
	m.emitter.request_shot_id(_req(0, Vector2(-900, -900)))  # slot 0: plain victim
	var bid := m.register_behavior(DespawnPoker.new())
	var r := _req(bid, Vector2(0, 0), 0.01)
	r.hit_mask = 0
	m.emitter.request_shot_id(r)
	m.pool.hook_ran = false
	for k in 3:
		m.step(DT)
	assert_eq(m.pool.invalid_total, 1, "the victim's infinite lifetime was caught by the end sweep")


class UpdateOnlyAgain:
	extends BulletBehavior
	func on_update(_p: BulletPool, _i: int, _d: float) -> void:
		pass


func test_a_behavior_whose_script_is_swapped_after_registration_is_redetected() -> void:
	var b := UpdateOnlyAgain.new()
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran, "registered with no event hook")
	b.set_script(SpawnOnly)
	m.pool.hook_ran = false
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran, "the new script's on_spawn was noticed on its first dispatch")
	b.set_script(UpdateOnlyAgain)
	m.pool.hook_ran = false
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran, "and swapping back is noticed too")


func test_a_swap_to_an_on_despawn_hook_is_noticed_at_despawn_time() -> void:
	var b := UpdateOnlyAgain.new()
	var bid := m.register_behavior(b)
	var r := _req(bid, Vector2(0, 0), 0.01)
	r.hit_mask = 0
	m.emitter.request_shot_id(r)
	b.set_script(DespawnOnly)
	assert_eq(m._hook_cache[bid], 0, "the cache still holds the old answer until the next dispatch")
	m.pool.hook_ran = false
	var before := m.pool.sweeps_run
	m.step(DT)  # the bullet expires in advance(): no update sweep, only the end sweep of its on_despawn
	assert_eq(m.pool.sweeps_run - before, 1, "the swapped-in on_despawn flagged the pool")


func test_refresh_behavior_redoes_a_cached_mask() -> void:
	var bid := m.register_behavior(SpawnOnly.new())
	m._hook_cache[bid] = 0  # a stale cache, as after an in-place script reload
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran)
	m.refresh_behavior(bid)
	assert_eq(m._hook_cache[bid], S)
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran)


func test_an_explicit_mask_covers_hooks_that_are_not_method_overrides() -> void:
	var b := BulletBehavior.new()
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran)
	b.hook_mask = BulletBehavior.HOOK_ALL  # e.g. an adapter that forwards to a runtime Callable
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran, "read at every dispatch: takes effect at once")
	b.hook_mask = BulletBehavior.HOOK_AUTO
	m.pool.hook_ran = false
	m.spawn(_req(bid))
	assert_false(m.pool.hook_ran, "back to auto")


func test_an_explicit_mask_that_covers_the_overrides_is_accepted() -> void:
	var b := SpawnOnly.new()
	b.hook_mask = S | D
	var bid := m.register_behavior(b)
	m.spawn(_req(bid))
	assert_true(m.pool.hook_ran)
	assert_eq(b.calls, 1)


func test_an_unknown_behavior_id_is_still_a_plain_bullet() -> void:
	m.spawn(_req(9))
	assert_false(m.pool.hook_ran)
	assert_eq(m.pool.behavior[0], 0)
