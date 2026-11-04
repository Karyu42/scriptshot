extends GutTest
## BulletPool.run_update_hooks(): the on_update loop of every scripted bullet.
##
## It replaced the manager's per-bullet "wrap in hook_owner, call, sanitize()" loop with
## one that (a) writes hook_owner only when the owner changes and (b) accepts a bullet
## without calling sanitize() when a hook left it alone. Safety must be exactly what
## it was: every bad write is caught right after its own hook, nothing else changes.
## The differential test below compares it with the old loop, field by field.

const DT := 1.0 / 60.0
const BIG := Rect2(-1.0e6, -1.0e6, 2.0e6, 2.0e6)

## Writes per-slot values into the pool: plan[slot] = [field, value]. Also records
## the hook_owner each hook saw and how often it ran.
class Writer:
	extends BulletBehavior
	var plan := {}
	var seen_owner: Array[int] = []
	var calls := 0
	var on_call: Callable = Callable()

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		calls += 1
		seen_owner.append(pool.hook_owner)
		if on_call.is_valid():
			on_call.call(pool, index)
		if not plan.has(index):
			return
		var step: Array = plan[index]
		var field: String = step[0]
		var value: float = step[1]
		match field:
			"pos":
				pool.pos[index] = Vector2(value, 1.0)
			"vel":
				pool.vel[index] = Vector2(value, 0.0)
			"rot":
				pool.rot[index] = Vector2(value, 0.0)
			"radius":
				pool.radius[index] = value
			"age":
				pool.age[index] = value
			"lifetime":
				pool.lifetime[index] = value
			"accel":
				pool.accel[index] = value
			"turn_rate":
				pool.turn_rate[index] = value
			"damage":
				pool.damage[index] = value
			"param_a":
				pool.param_a[index] = value
			"param_b":
				pool.param_b[index] = value


func before_each() -> void:
	ScriptWarnings.reset()


func _pool(n: int, owners: Array[int] = [Layers.PLAYER]) -> BulletPool:
	var pool := BulletPool.new(512)
	for k in n:
		var r := ShotRequest.with_velocity(Vector2(k, -k), Vector2(100.0 + k, 30.0))
		r.lifetime = 50.0
		r.radius = 3.0
		r.behavior_id = 1
		r.owner_layer = owners[k % owners.size()]
		r.hit_mask = Layers.hostile_to(r.owner_layer)
		pool.spawn(r)
	pool.advance(DT, BIG)
	return pool


func _table(w: BulletBehavior) -> Array[BulletBehavior]:
	var t: Array[BulletBehavior] = [null, w]
	return t


## The loop this one replaced: wrap, call, restore, sanitize(), bullet by bullet.
func _reference_loop(pool: BulletPool, w: BulletBehavior) -> void:
	for k in pool.hooked_count:
		var i := pool.hooked[k]
		if pool.dead_reason[i] == 0 and pool.behavior[i] != 0:
			var outer := pool.hook_owner
			var outer_slot := pool.hook_slot
			pool.hook_owner = pool.owner_layer[i]
			pool.hook_slot = i
			w.on_update(pool, i, DT)
			pool.hook_owner = outer
			pool.hook_slot = outer_slot
			pool.sanitize(i)


func _dump(pool: BulletPool) -> Array:
	var out: Array = []
	for arr: Variant in [
		pool.pos, pool.prev_pos, pool.vel, pool.rot, pool.radius, pool.age, pool.lifetime, pool.accel, pool.turn_rate,
		pool.damage, pool.param_a, pool.param_b, pool.hit_mask, pool.owner_layer, pool.behavior, pool.dead_reason
	]:
		out.append(str(arr))
	out.append([pool.count, pool.invalid_total, pool.max_radius, pool.pending_count, pool.hook_owner, pool.hook_slot])
	return out


# --- safety: identical to the per-bullet sanitize() loop --------------------------------

func test_differential_against_the_per_bullet_sanitize_loop() -> void:
	var fields := ["pos", "vel", "rot", "radius", "age", "lifetime", "accel", "turn_rate", "damage", "param_a", "param_b"]
	var values := [NAN, INF, -INF, 1.0e9, -1.0e9, -5.0, 0.0, 3.0, 255.0, 257.0, 599.0, 601.0, 999.0, 1001.0, 1.0e6, 1.0e6 + 1.0, 1000.0, 1001.0, 1.0e35, 4000.0, 4001.0]
	var rng := RandomNumberGenerator.new()
	for seed_value in 6:
		rng.seed = 1000 + seed_value
		var n := 120
		var a := _pool(n, [Layers.PLAYER, Layers.ENEMY, Layers.PLAYER])
		var b := _pool(n, [Layers.PLAYER, Layers.ENEMY, Layers.PLAYER])
		var wa := Writer.new()
		var wb := Writer.new()
		for slot in n:
			if rng.randf() < 0.55:
				var step := [fields[rng.randi() % fields.size()], values[rng.randi() % values.size()]]
				wa.plan[slot] = step
				wb.plan[slot] = step
		a.run_update_hooks(_table(wa), DT)
		_reference_loop(b, wb)
		assert_eq(_dump(a), _dump(b), "seed %d: same state as the per-bullet sanitize() loop" % seed_value)
		assert_eq(wa.calls, wb.calls, "seed %d: same hooks ran" % seed_value)
		assert_eq(wa.seen_owner, wb.seen_owner, "seed %d: every hook saw the same owner context" % seed_value)
		assert_gt(a.invalid_total, 0, "seed %d: the plan did kill something" % seed_value)


func _single(field: String, value: float) -> BulletPool:
	var pool := _pool(1)
	var w := Writer.new()
	w.plan[0] = [field, value]
	pool.run_update_hooks(_table(w), DT)
	return pool


func test_every_non_finite_write_kills_the_bullet_right_after_its_hook() -> void:
	for field: String in ["pos", "vel", "rot", "radius", "age", "lifetime", "accel", "turn_rate", "damage", "param_a", "param_b"]:
		for value: float in [NAN, INF, -INF]:
			var pool := _single(field, value)
			var label := "%s = %s" % [field, value]
			assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.INVALID + 1, "%s kills it as INVALID" % label)
			assert_eq(pool.invalid_total, 1, "%s is counted" % label)
			assert_eq(pool.pending_count, 1, label)


func test_every_out_of_range_write_is_clamped_right_after_its_hook() -> void:
	# [field, written, expected after]
	var cases := [
		["radius", 1.0e9, BulletLimits.MAX_RADIUS],
		["radius", 257.0, BulletLimits.MAX_RADIUS],
		["radius", -1.0, 0.0],
		["lifetime", 601.0, BulletLimits.MAX_LIFETIME],
		["lifetime", -1.0, 0.0],
		["accel", 1.0e7, BulletLimits.MAX_ACCELERATION],
		["accel", -1.0e7, -BulletLimits.MAX_ACCELERATION],
		["turn_rate", 1001.0, BulletLimits.MAX_TURN_RATE],
		["turn_rate", -1001.0, -BulletLimits.MAX_TURN_RATE],
		["damage", 1001.0, BulletLimits.MAX_DAMAGE],
		["damage", -3.0, 0.0],
	]
	for c: Array in cases:
		var field: String = c[0]
		var written: float = c[1]
		var expected: float = c[2]
		var pool := _single(field, written)
		var label := "%s = %s" % [field, written]
		assert_eq(pool.dead_reason[0], 0, "%s: finite, so the bullet lives" % label)
		var got: float = pool.get(field)[0]
		assert_eq(got, expected, "%s is clamped" % label)
	var fast := _single("vel", 1.0e9)
	assert_almost_eq(fast.vel[0].length(), BulletLimits.MAX_SPEED, 0.01, "speed over the ceiling is cut")
	assert_eq(fast.dead_reason[0], 0)
	assert_eq(fast.vel[0].y, 0.0, "direction kept")


func test_in_range_writes_are_left_alone_and_a_grown_radius_widens_max_radius() -> void:
	for c: Array in [["radius", 200.0], ["lifetime", 599.0], ["accel", 5.0e5], ["turn_rate", -999.0], ["damage", 1000.0], ["param_a", 12345.0]]:
		var field: String = c[0]
		var written: float = c[1]
		var pool := _single(field, written)
		assert_eq(pool.dead_reason[0], 0, "%s in range keeps the bullet" % field)
		var got: float = pool.get(field)[0]
		assert_eq(got, written, "%s in range is not touched" % field)
	var grown := _single("radius", 200.0)
	assert_eq(grown.max_radius, 200.0, "the hurtbox grid margin follows a hook-grown radius")


func test_a_hook_that_kills_its_own_bullet_is_not_checked_or_double_counted() -> void:
	var pool := _pool(2)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		if i == 0:
			p.mark_dead(0, BulletPool.DespawnReason.MANUAL)
			p.radius[0] = NAN  # a dead bullet's leftovers are not sanitized
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.MANUAL + 1, "first reason wins")
	assert_eq(pool.invalid_total, 0)
	assert_eq(w.calls, 2)


func test_a_dead_bullets_leftovers_do_not_widen_max_radius() -> void:
	var pool := _pool(1)
	var before := pool.max_radius
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		p.mark_dead(i, BulletPool.DespawnReason.MANUAL)
		p.radius[i] = 200.0
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.max_radius, before, "a bullet that is already gone does not resize the hurtbox grid margin")


func test_a_bullet_a_hook_marked_out_of_bounds_is_still_checked() -> void:
	# A bullet that only left the world this tick still delivers its last segment's hits
	# (see sanitize()), so a NaN written by its hook must still be caught, not skipped.
	var pool := _pool(1)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		p.mark_dead(i, BulletPool.DespawnReason.BOUNDS)
		p.vel[i] = Vector2(NAN, 0.0)
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.invalid_total, 1, "counted")
	assert_true(pool.vel[0].is_finite(), "no NaN is left in the slot")
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.BOUNDS + 1, "the first reason stays")
	var clamped := _pool(1)
	var w2 := Writer.new()
	w2.on_call = func(p: BulletPool, i: int) -> void:
		p.mark_dead(i, BulletPool.DespawnReason.BOUNDS)
		p.radius[i] = 9999.0
	clamped.run_update_hooks(_table(w2), DT)
	assert_eq(clamped.radius[0], BulletLimits.MAX_RADIUS, "and an out-of-range value is clamped too")


func test_only_the_hooked_list_is_updated_and_a_plain_bullet_gets_the_cross_write_sweep() -> void:
	var pool := _pool(4)
	pool.behavior[1] = 0  # plain: not on the hooked list after the next advance
	pool.behavior[3] = 0
	pool.advance(DT, BIG)
	assert_eq(pool.hooked_count, 2)
	pool.vel[1] = Vector2(1.0e9, 0.0)  # a direct write to a plain bullet is outside the per-hook check
	pool.damage[3] = 1.0e9  # a field the sweep does not look at (it is checked when a hit lands)
	pool.radius[3] = 1.0e9  # neither is radius
	var w := Writer.new()
	pool.run_update_hooks(_table(w), DT)
	assert_eq(w.calls, 2, "only scripted bullets are updated")
	assert_almost_eq(pool.vel[1].length(), BulletLimits.MAX_SPEED, 0.01, "but the sweep after the hooks cuts it to the ceiling")
	assert_eq(pool.damage[3], 1.0e9, "and leaves a bullet it finds clean alone, whatever else is in it")
	assert_eq(pool.radius[3], 1.0e9)


func test_a_bullet_hook_writing_its_own_prev_pos_is_caught_before_the_next_hook_runs() -> void:
	# Right after its own hook, not only by the sweep at the end of the loop: the next
	# bullet's hook must not see the poisoned slot as alive.
	var pool := _pool(3)
	var seen_dead: Array[int] = [-1]
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		if i == 0:
			p.prev_pos[0] = Vector2(NAN, 0.0)
		elif i == 1:
			seen_dead[0] = p.dead_reason[0]
	pool.run_update_hooks(_table(w), DT)
	var dead_seen: int = seen_dead[0]
	assert_eq(dead_seen, BulletPool.DespawnReason.INVALID + 1, "dead before bullet 1's hook ran")
	assert_eq(pool.invalid_total, 1)


func test_a_write_into_a_later_hooked_bullet_is_caught_at_that_bullets_turn() -> void:
	var pool := _pool(3)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		if i == 0:
			p.vel[2] = Vector2(NAN, 0.0)
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.dead_reason[2], BulletPool.DespawnReason.INVALID + 1, "killed after its own hook ran")
	assert_eq(pool.dead_reason[1], 0)
	assert_eq(w.calls, 3, "it still got its own on_update first")


func test_a_bullet_killed_or_unscripted_by_an_earlier_hook_gets_no_update() -> void:
	var pool := _pool(4)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		if i == 0:
			p.mark_dead(1)
			p.behavior[2] = 0  # what reflect() does
			p.vel[2] = Vector2(1.0e9, 0.0)  # outside the per-hook guard, caught by the sweep
	pool.run_update_hooks(_table(w), DT)
	assert_eq(w.calls, 2, "slots 0 and 3 only")
	assert_almost_eq(pool.vel[2].length(), BulletLimits.MAX_SPEED, 0.01, "the un-scripted bullet got no update, only the sweep")


func test_an_unknown_behavior_id_written_by_a_hook_makes_a_plain_bullet_and_the_loop_goes_on() -> void:
	var pool := _pool(3)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		if i == 0:
			p.behavior[1] = 99
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.behavior[1], 0, "the script is dropped")
	assert_eq(pool.dead_reason[1], 0, "the bullet survives")
	assert_eq(w.calls, 2, "slots 0 and 2 ran")
	assert_eq(ScriptWarnings.count("BulletPool.behavior"), 1)


# --- the owner context ---------------------------------------------------------------------

func test_every_hook_sees_the_owner_of_its_own_bullet_in_any_interleaving() -> void:
	var owners: Array[int] = [Layers.PLAYER, Layers.ENEMY, Layers.ENEMY, Layers.PLAYER, Layers.PLAYER, Layers.PLAYER, Layers.ENEMY, Layers.PLAYER]
	var pool := _pool(owners.size(), owners)
	var w := Writer.new()
	pool.run_update_hooks(_table(w), DT)
	assert_eq(w.seen_owner, owners, "the context follows the bullet, not the previous bullet")


func test_hook_owner_is_restored_to_its_value_on_entry() -> void:
	var pool := _pool(3, [Layers.ENEMY])
	var w := Writer.new()
	assert_eq(pool.hook_owner, -1)
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.hook_owner, -1, "outside any hook it is -1 again")
	assert_eq(pool.hook_slot, -1, "and so is the running slot")
	pool.hook_owner = Layers.PLAYER  # called from inside another bullet's hook (re-entrancy)
	pool.hook_slot = 7
	pool.run_update_hooks(_table(w), DT)
	assert_eq(pool.hook_owner, Layers.PLAYER, "the outer hook's context comes back")
	assert_eq(pool.hook_slot, 7, "with its slot")


func test_every_hook_sees_its_own_slot_and_a_reflect_of_it_updates_the_context() -> void:
	var owners: Array[int] = [Layers.PLAYER, Layers.PLAYER, Layers.ENEMY]
	var pool := _pool(3, owners)
	var w := Writer.new()
	var slots: Array[int] = []
	var owners_after_reflect: Array[int] = []
	w.on_call = func(p: BulletPool, i: int) -> void:
		slots.append(p.hook_slot)
		if i == 0:
			assert_true(p.reflect(0, Layers.ENEMY))
			owners_after_reflect.append(p.hook_owner)
	pool.run_update_hooks(_table(w), DT)
	assert_eq(slots, [0, 1, 2], "hook_slot follows the bullet")
	assert_eq(owners_after_reflect, [Layers.ENEMY], "a hook that reflects its own bullet hands the rest of the hook the new owner")
	assert_eq(w.seen_owner, [Layers.PLAYER, Layers.PLAYER, Layers.ENEMY], "and the next bullet's hook is back on its own owner")
	assert_eq(pool.hook_slot, -1)


func test_a_hook_that_overwrites_hook_owner_does_not_leak_it_into_the_next_hook() -> void:
	var owners: Array[int] = [Layers.PLAYER, Layers.PLAYER, Layers.ENEMY]
	var pool := _pool(3, owners)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, i: int) -> void:
		if i == 0:
			p.hook_owner = Layers.ENEMY  # tries to make the next player bullet spawn as an enemy
	pool.run_update_hooks(_table(w), DT)
	# The first hook saw PLAYER (recorded before it wrote); the rest see their own owner.
	assert_eq(w.seen_owner, owners)
	assert_eq(pool.hook_owner, -1)


func test_a_hook_that_leaves_hook_owner_at_minus_one_does_not_blank_the_next_hook() -> void:
	var owners: Array[int] = [Layers.ENEMY, Layers.ENEMY]
	var pool := _pool(2, owners)
	var w := Writer.new()
	w.on_call = func(p: BulletPool, _i: int) -> void:
		p.hook_owner = -1
	pool.run_update_hooks(_table(w), DT)
	assert_eq(w.seen_owner, owners, "the second ENEMY bullet still gets its context although the first hook cleared it")


# --- nesting and re-entrancy through the real manager ---------------------------------

class Spawner:
	extends BulletBehavior
	var plain_child: ShotRequest
	var hooked_child: ShotRequest = null
	var spawned: Array[int] = []

	## A parent's on_update: a child that has a hook of its own (whose on_spawn spawns
	## again, nested), then a second plain child after the nested spawn returned.
	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		spawned.append(emitter.request_shot_id(hooked_child))
		spawned.append(emitter.request_shot_id(plain_child))

	func on_spawn(_pool: BulletPool, _index: int) -> void:
		if hooked_child == null:
			spawned.append(emitter.request_shot_id(plain_child))


func test_children_spawned_after_a_nested_spawn_still_inherit_the_hook_owner() -> void:
	var manager := BulletManager.new()
	manager.capacity = 256
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var plain := ShotRequest.with_velocity(Vector2(5, 5), Vector2(0, 10))
	plain.lifetime = 5.0
	plain.owner_layer = Layers.ENEMY  # asks for the wrong owner on purpose
	var inner := Spawner.new()  # hooked_child stays null: its on_spawn spawns one plain child
	inner.plain_child = plain
	var hooked := ShotRequest.with_velocity(Vector2(6, 6), Vector2(0, 10))
	hooked.lifetime = 5.0
	hooked.owner_layer = Layers.ENEMY
	hooked.behavior_id = manager.register_behavior(inner)
	var outer := Spawner.new()
	outer.plain_child = plain
	outer.hooked_child = hooked
	var outer_id := manager.register_behavior(outer)
	for owner_layer: int in [Layers.PLAYER, Layers.ENEMY, Layers.PLAYER, Layers.ENEMY]:
		var r := ShotRequest.with_velocity(Vector2(owner_layer, 0), Vector2(0, 5))
		r.lifetime = 5.0
		r.owner_layer = owner_layer
		r.hit_mask = Layers.hostile_to(owner_layer)
		r.behavior_id = outer_id
		manager.emitter.request_shot_id(r)
	manager.step(DT)
	var pool := manager.pool
	assert_eq(pool.hook_owner, -1)
	assert_true(pool.counters_consistent())
	# 4 parents, each with a hooked child (whose on_spawn adds one more) and a plain child
	assert_eq(pool.count, 16)
	# Every child takes the owner of the parent whose hook spawned it, however deep and
	# whatever the requests ask for: 2 player parents and 2 enemy parents, 4 bullets each.
	assert_eq(pool.owner_counts[BulletPool.OWNER_PLAYER], 8)
	assert_eq(pool.owner_counts[BulletPool.OWNER_ENEMY], 8)
	assert_gt(ScriptWarnings.count("BulletManager.spawn.owner"), 0, "the wrong-owner asks were reported")
