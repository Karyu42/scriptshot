extends GutTest
## What a hook writes into a bullet that is NOT its own (the packed arrays are public).
##
## The first block (X1-X6) is QA's repro from the PR #11 review: cross-slot writes, a huge
## finite position, garbage behaviour ids, a child poked after spawn_child. The rest pins
## the design that closes the gap: BulletPool.sweep_cross_writes() after the hooks of a
## tick (position, previous position, rotation, velocity), the guards in advance() (NaN
## age/lifetime/position) and the sanitize at hit time (damage, radius and the rest).
const DT := 1.0 / 60.0
var m: BulletManager

func before_each() -> void:
	ScriptWarnings.reset()
	m = BulletManager.new()
	m.capacity = 64
	m.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)

class Noop:
	extends BulletBehavior

## Writes `value` into vel.x of slot `target` (another bullet) once.
class CrossWriter:
	extends BulletBehavior
	var target := -1
	var value := NAN
	var done := false
	func on_update(pool: BulletPool, _i: int, _d: float) -> void:
		if not done:
			done = true
			pool.vel[target] = Vector2(value, 0)

func _req(at: Vector2, beh := 0) -> ShotRequest:
	var r := ShotRequest.with_velocity(at, Vector2(10, 0))
	r.lifetime = 5.0
	r.behavior_id = beh
	return r

func _finite_all() -> bool:
	for i in m.pool.count:
		if m.pool.dead_reason[i] == 0 and not m.pool.vel[i].is_finite():
			return false
	return true

# X1: writer (slot 0) -> later hooked bullet (slot 1).
func test_x1_cross_write_to_a_later_hooked_bullet_is_checked_after_its_own_hook() -> void:
	var w := CrossWriter.new()
	w.target = 1
	var wid := m.register_behavior(w)
	var nid := m.register_behavior(Noop.new())
	m.emitter.request_shot_id(_req(Vector2(0, 0), wid))
	m.emitter.request_shot_id(_req(Vector2(100, 0), nid))
	m.step(DT)
	assert_true(_finite_all(), "non-finite velocity survived in the later hooked bullet")

# X2: writer -> plain (un-hooked) bullet.
func test_x2_cross_write_to_a_plain_bullet() -> void:
	var w := CrossWriter.new()
	w.target = 1
	var wid := m.register_behavior(w)
	m.emitter.request_shot_id(_req(Vector2(0, 0), wid))
	m.emitter.request_shot_id(_req(Vector2(100, 0)))
	m.step(DT)
	m.step(DT)
	assert_true(_finite_all(), "non-finite velocity survived in a plain bullet")

# X3: writer (slot 1) -> EARLIER hooked bullet (slot 0), already checked this tick.
func test_x3_cross_write_to_an_earlier_hooked_bullet() -> void:
	var nid := m.register_behavior(Noop.new())
	var w := CrossWriter.new()
	w.target = 0
	var wid := m.register_behavior(w)
	m.emitter.request_shot_id(_req(Vector2(100, 0), nid))
	m.emitter.request_shot_id(_req(Vector2(0, 0), wid))
	m.step(DT)
	m.step(DT)
	assert_true(_finite_all(), "non-finite velocity survived in an earlier hooked bullet")

# X4: huge finite position written by a hook (no hang, bullet culled).
class PosWriter:
	extends BulletBehavior
	var v := 1.0e30
	func on_update(pool: BulletPool, i: int, _d: float) -> void:
		pool.pos[i] = Vector2(v, 0)

func test_x4_huge_finite_position_from_a_hook_does_not_hang_and_is_culled() -> void:
	var pid := m.register_behavior(PosWriter.new())
	m.emitter.request_shot_id(_req(Vector2(0, 0), pid))
	var t0 := Time.get_ticks_msec()
	m.step(DT)
	m.step(DT)
	var dt := Time.get_ticks_msec() - t0
	gut.p("huge pos: 2 steps took %d ms, bullets left %d" % [dt, m.pool.count])
	assert_lt(dt, 2000, "hang")
	assert_eq(m.pool.count, 0, "bullet far outside the world should be culled")

# X5: behaviour id garbage written to a later bullet.
class IdWriter:
	extends BulletBehavior
	var target := 1
	var value := 9999
	func on_update(pool: BulletPool, _i: int, _d: float) -> void:
		pool.behavior[target] = value

func test_x5_garbage_behavior_id_of_a_later_bullet() -> void:
	for val: int in [9999, -3]:
		var w := IdWriter.new()
		w.value = val
		var wid := m.register_behavior(w)
		var nid := m.register_behavior(Noop.new())
		m.clear_bullets()
		m.emitter.request_shot_id(_req(Vector2(0, 0), wid))
		m.emitter.request_shot_id(_req(Vector2(100, 0), nid))
		m.step(DT)
		m.step(DT)
		assert_eq(m.pool.hook_owner, -1)
		assert_eq(m.pool.hook_slot, -1)
	assert_true(true)

# X6: hook spawns a child (spawn_child / spawn with NaN request) then pokes the child's slot.
class ChildPoker:
	extends BulletBehavior
	var mgr: BulletManager
	var done := false
	var child := -2
	func on_update(pool: BulletPool, i: int, _d: float) -> void:
		if done:
			return
		done = true
		var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(NAN, 0))
		r.lifetime = 5.0
		child = mgr.spawn(r)   # NaN request: must be refused
		var r2 := ShotRequest.with_velocity(Vector2(0, 0), Vector2(5, 0))
		r2.lifetime = 5.0
		child = mgr.spawn_child(pool.id_of(i), r2)
		if child >= 0:
			pool.pos[child] = Vector2(NAN, 0)

func test_x6_hook_pokes_nan_into_a_child_it_just_spawned() -> void:
	var c := ChildPoker.new()
	c.mgr = m
	var cid := m.register_behavior(c)
	m.emitter.request_shot_id(_req(Vector2(0, 0), cid))
	m.step(DT)
	m.step(DT)
	var ok := true
	for i in m.pool.count:
		if m.pool.dead_reason[i] == 0 and not m.pool.pos[i].is_finite():
			ok = false
	assert_true(ok, "non-finite position survived in a spawned child")


# --- the design -----------------------------------------------------------------------

## Pokes `field` of slot `target` once, from the first hooked bullet's hook.
class Poker:
	extends BulletBehavior
	var target := 1
	var field := "vel"
	var value := NAN
	var done := false
	func on_update(pool: BulletPool, _i: int, _d: float) -> void:
		if done:
			return
		done = true
		match field:
			"vel": pool.vel[target] = Vector2(value, 0.0)
			"rot": pool.rot[target] = Vector2(value, 0.0)
			"pos": pool.pos[target] = Vector2(value, value)
			"prev_pos": pool.prev_pos[target] = Vector2(value, value)
			"radius": pool.radius[target] = value
			"damage": pool.damage[target] = value
			"lifetime": pool.lifetime[target] = value
			"age": pool.age[target] = value
			"accel": pool.accel[target] = value
			"turn_rate": pool.turn_rate[target] = value


func _poke(field: String, value: float) -> void:
	var w := Poker.new()
	w.field = field
	w.value = value
	var wid := m.register_behavior(w)
	m.emitter.request_shot_id(_req(Vector2(0, 0), wid))
	m.emitter.request_shot_id(_req(Vector2(100, 0)))


func test_every_non_finite_pos_prev_pos_vel_or_rot_is_gone_in_the_same_tick() -> void:
	for field: String in ["pos", "prev_pos", "vel", "rot"]:
		for v: float in [NAN, INF, -INF]:
			m.clear_bullets()
			ScriptWarnings.reset()
			var before := m.pool.invalid_total
			_poke(field, v)
			m.step(DT)
			# The poisoned bullet is gone this very tick (killed INVALID, then flushed);
			# only the writer is left, and nothing non-finite is in the pool.
			assert_eq(m.pool.count, 1, "%s=%s: the bullet is removed" % [field, v])
			assert_eq(m.pool.invalid_total, before + 1, "%s=%s: counted once" % [field, v])
			assert_eq(m.pool.dead_reason[0], 0, "the writer itself is untouched")
			assert_true(m.pool.pos[0].is_finite() and m.pool.vel[0].is_finite())
			if field != "vel":  # the velocity keeps its own older warning key
				assert_string_contains(ScriptWarnings.last_message("BulletPool.hook_write"), "written to %s," % field, "the warning names the field")


func test_a_cross_written_speed_over_the_ceiling_is_clamped_in_a_plain_bullet() -> void:
	_poke("vel", 1.0e6)
	m.step(DT)
	assert_eq(m.pool.dead_reason[1], 0, "alive")
	assert_almost_eq(m.pool.vel[1].length(), BulletLimits.MAX_SPEED, 0.01)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.speed"), 1, "and said so")


func test_a_huge_finite_position_in_a_plain_bullet_is_culled_by_the_next_advance_without_a_hang() -> void:
	m.add_wall(Rect2(100, -50, 20, 100))
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(60, 50)
	_poke("pos", 1.0e30)
	var t0 := Time.get_ticks_msec()
	m.step(DT)
	m.step(DT)
	assert_lt(Time.get_ticks_msec() - t0, 2000, "no hang in the sweeps")
	assert_eq(m.pool.count, 1, "the bounds cull of advance() ended it")
	assert_eq(m.pool.invalid_total, 0, "an absurd but finite position is a plain bounds cull")


func test_the_sweep_leaves_clean_bullets_alone_and_costs_no_warning() -> void:
	_poke("vel", 50.0)
	m.step(DT)
	assert_eq(m.pool.dead_reason[1], 0)
	assert_eq(m.pool.vel[1], Vector2(50, 0))
	assert_eq(m.pool.invalid_total, 0)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.speed"), 0)


func test_the_sweep_only_runs_after_a_hook_ran() -> void:
	var quiet := BulletPool.new(16)
	quiet.spawn(ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0)))
	quiet.advance(DT, Rect2(-1000, -1000, 2000, 2000))
	quiet.radius[0] = 1.0e9
	quiet.run_update_hooks([null] as Array[BulletBehavior], DT)
	assert_eq(quiet.radius[0], 1.0e9, "no hook ran, so no sweep: a tick without hooked bullets pays nothing")


func test_advance_kills_a_bullet_whose_motion_a_hook_poisoned_after_the_sweep() -> void:
	# A NaN velocity, acceleration or turn rate makes a NaN position: advance() is the net.
	for field: String in ["vel", "accel", "turn_rate"]:
		var pool := BulletPool.new(16)
		pool.spawn(ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0)))
		match field:
			"vel": pool.vel[0] = Vector2(NAN, 0.0)
			"accel": pool.accel[0] = NAN
			"turn_rate": pool.turn_rate[0] = NAN
		pool.advance(DT, Rect2(-1000, -1000, 2000, 2000))
		assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.INVALID + 1, "%s=NaN is killed by advance()" % field)
		assert_eq(pool.invalid_total, 1)
		assert_true(pool.pos[0].is_finite(), "%s: and leaves a finite position behind" % field)


## The clock is checked by the sweeps, not by advance(); `not a < life` is only the cheap
## NaN-safe net: a NaN age or lifetime that was never swept ends the bullet, it does not keep it.
func test_advance_ends_a_bullet_with_a_nan_clock_instead_of_keeping_it() -> void:
	for field: String in ["age", "lifetime"]:
		var pool := BulletPool.new(16)
		pool.spawn(ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0)))
		if field == "age":
			pool.age[0] = NAN
		else:
			pool.lifetime[0] = NAN
		pool.advance(DT, Rect2(-1000, -1000, 2000, 2000))
		assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.LIFETIME + 1, "%s=NaN: expired" % field)


func test_the_full_sweep_kills_a_non_finite_clock_as_invalid() -> void:
	for field: String in ["age", "lifetime"]:
		for v: float in [NAN, INF, -INF]:
			var pool := BulletPool.new(16)
			pool.spawn(ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0)))
			if field == "age":
				pool.age[0] = v
			else:
				pool.lifetime[0] = v
			pool.sweep_cross_writes()
			assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.INVALID + 1, "%s=%s" % [field, v])
			assert_eq(pool.invalid_total, 1)


func test_advance_still_ends_normal_lifetimes_and_bounds_with_the_old_reasons() -> void:
	var pool := BulletPool.new(16)
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0))
	r.lifetime = 0.001
	pool.spawn(r)
	pool.spawn(ShotRequest.with_velocity(Vector2(999, 0), Vector2(1000, 0)))
	pool.advance(DT, Rect2(-1000, -1000, 1000, 2000))
	assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.LIFETIME + 1)
	assert_eq(pool.dead_reason[1], BulletPool.DespawnReason.BOUNDS + 1)
	assert_eq(pool.invalid_total, 0)


## Hits: damage written into a plain bullet never reaches Health.
func test_a_nan_damage_written_into_a_plain_bullet_never_reaches_the_hurtbox() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(110, 0)
	var seen: Array[float] = []
	hb.hit.connect(func(d: float, _p: Vector2, _v: Vector2) -> void: seen.append(d))
	_poke("damage", NAN)
	# slot 1 is the poked plain bullet (hit_mask default hits the enemy layer too)
	m.pool.hit_mask[1] = Layers.ENEMY
	m.pool.pos[1] = Vector2(100, 0)
	m.pool.prev_pos[1] = Vector2(100, 0)
	m.step(DT)
	for k in 6:
		m.step(DT)
	for d in seen:
		assert_true(is_finite(d), "the hurtbox only ever sees finite damage")
	assert_eq(m.pool.invalid_total, 1, "the poisoned bullet was removed instead of landing a hit")


func test_an_out_of_range_damage_is_clamped_when_the_hit_lands() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(110, 0)
	var seen: Array[float] = []
	hb.hit.connect(func(d: float, _p: Vector2, _v: Vector2) -> void: seen.append(d))
	_poke("damage", 1.0e9)
	m.pool.hit_mask[1] = Layers.ENEMY
	m.pool.pos[1] = Vector2(100, 0)
	m.pool.prev_pos[1] = Vector2(100, 0)
	for k in 7:
		m.step(DT)
	assert_eq(seen.size(), 1)
	assert_lte(seen[0], BulletLimits.MAX_DAMAGE)


func test_a_hit_still_lands_with_normal_values_after_the_sanitize_was_added() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(110, 0)
	var seen: Array[float] = []
	hb.hit.connect(func(d: float, _p: Vector2, _v: Vector2) -> void: seen.append(d))
	var r := ShotRequest.with_velocity(Vector2(100, 0), Vector2(10, 0))
	r.lifetime = 5.0
	r.damage = 3.0
	r.hit_mask = Layers.ENEMY
	m.emitter.request_shot_id(r)
	for k in 3:
		m.step(DT)
	assert_eq(seen, [3.0] as Array[float])
	assert_eq(m.pool.invalid_total, 0)


## A child gets poked after spawn_child() returned: the sweep catches it (spawn-time
## sanitize only sees what on_spawn wrote).
func test_children_are_swept_whether_they_were_spawned_this_tick_or_not() -> void:
	var c := ChildPoker.new()
	c.mgr = m
	var cid := m.register_behavior(c)
	m.emitter.request_shot_id(_req(Vector2(0, 0), cid))
	m.step(DT)
	assert_ne(c.child, -2, "the hook ran")
	for i in m.pool.count:
		if m.pool.dead_reason[i] == 0:
			assert_true(m.pool.pos[i].is_finite())
	assert_gt(m.pool.invalid_total, 0, "the poked child was removed")


## The unknown-id guard of run_update_hooks() has two sides (`>= table size` and `< 0`).
func test_a_negative_or_too_big_behavior_id_written_by_a_hook_drops_the_script() -> void:
	for bad: int in [-1, -3, 9999]:
		ScriptWarnings.reset()
		var w := IdWriter.new()
		w.value = bad
		var wid := m.register_behavior(w)
		var nid := m.register_behavior(Noop.new())
		m.clear_bullets()
		m.emitter.request_shot_id(_req(Vector2(0, 0), wid))
		m.emitter.request_shot_id(_req(Vector2(100, 0), nid))
		m.step(DT)
		assert_eq(m.pool.behavior[1], 0, "%d: the script is dropped" % bad)
		assert_eq(m.pool.dead_reason[1], 0, "%d: the bullet lives on as a plain bullet" % bad)
		assert_eq(ScriptWarnings.count("BulletPool.behavior"), 1, "%d: and it was reported" % bad)
		assert_eq(m.pool.hook_owner, -1)
		assert_eq(m.pool.hook_slot, -1)


func test_a_negative_behavior_id_straight_in_the_pool_loop() -> void:
	var pool := BulletPool.new(8)
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0))
	r.lifetime = 5.0
	r.behavior_id = 1
	pool.spawn(r)
	pool.advance(DT, Rect2(-1000, -1000, 2000, 2000))
	pool.behavior[0] = -7  # on the hooked list, but now garbage
	var t: Array[BulletBehavior] = [null, Noop.new()]
	pool.run_update_hooks(t, DT)
	assert_eq(pool.behavior[0], 0)
	assert_eq(pool.dead_reason[0], 0)
	assert_eq(ScriptWarnings.count("BulletPool.behavior"), 1)
	assert_string_contains(ScriptWarnings.last_message("BulletPool.behavior"), "-7")


## Radius is checked when the bullet hits (the sweep leaves it alone: a bad radius only
## matters for what the bullet touches).
func _radius_hit_run(value: float) -> Array[float]:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 10.0
	add_child_autofree(hb)
	hb.global_position = Vector2(110, 0)
	var seen: Array[float] = []
	hb.hit.connect(func(d: float, _p: Vector2, _v: Vector2) -> void: seen.append(d))
	_poke("radius", value)
	m.pool.hit_mask[1] = Layers.ENEMY
	m.pool.pos[1] = Vector2(100, 0)
	m.pool.prev_pos[1] = Vector2(100, 0)
	for k in 7:
		m.step(DT)
	return seen


func test_a_non_finite_radius_in_a_plain_bullet_lands_no_hit() -> void:
	for v: float in [NAN, INF, -INF]:
		m.clear_bullets()
		var before := m.pool.invalid_total
		var seen := _radius_hit_run(v)
		assert_eq(seen.size(), 0, "%s: no hit is delivered" % v)
		if is_nan(v):
			# A NaN radius never overlaps anything (every comparison is false): no hit to
			# check, the bullet is inert until its lifetime ends.
			assert_eq(m.pool.invalid_total, before, "nan: no hit, so nothing to remove it for")
		else:
			assert_eq(m.pool.invalid_total, before + 1, "%s: the bullet was removed as INVALID when it hit" % v)


func test_an_out_of_range_radius_is_clamped_when_the_bullet_hits() -> void:
	var seen := _radius_hit_run(99999.0)
	assert_eq(seen.size(), 1, "the hit still lands")
	assert_eq(m.pool.max_radius, maxf(m.pool.max_radius, BulletLimits.MAX_RADIUS), "and the grid margin was widened to the clamped radius")


## A plain bullet in slot 0, the writer later: nothing may skip the first slot.
func test_the_sweep_covers_slot_zero() -> void:
	for field: String in ["vel", "pos", "prev_pos", "rot"]:
		m.clear_bullets()
		var before := m.pool.invalid_total
		var w := Poker.new()
		w.target = 0
		w.field = field
		w.value = NAN
		var wid := m.register_behavior(w)
		m.emitter.request_shot_id(_req(Vector2(100, 0)))  # slot 0, plain
		m.emitter.request_shot_id(_req(Vector2(0, 0), wid))  # slot 1, the writer
		m.step(DT)
		assert_eq(m.pool.count, 1, "%s: the plain bullet in slot 0 is gone" % field)
		assert_eq(m.pool.invalid_total, before + 1)


## `if ran:` is what makes a tick without hooks free: a bad value written by hand into a
## plain bullet of a pool whose hooks never ran is left for advance() / the hit test.
func test_a_pool_without_a_hook_call_is_not_swept() -> void:
	var pool := BulletPool.new(16)
	pool.spawn(ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0)))
	pool.advance(DT, Rect2(-1000, -1000, 2000, 2000))
	pool.vel[0] = Vector2(1.0e9, 0.0)
	pool.run_update_hooks([null] as Array[BulletBehavior], DT)
	assert_eq(pool.vel[0].x, 1.0e9, "nothing ran, nothing swept")
	var n := Noop.new()
	var rq := ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0))
	rq.behavior_id = 1
	rq.lifetime = 5.0
	var pool2 := BulletPool.new(16)
	pool2.spawn(rq)
	pool2.spawn(ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0)))
	pool2.advance(DT, Rect2(-1000, -1000, 2000, 2000))
	pool2.vel[1] = Vector2(1.0e9, 0.0)
	pool2.run_update_hooks([null, n] as Array[BulletBehavior], DT)
	assert_almost_eq(pool2.vel[1].length(), BulletLimits.MAX_SPEED, 0.01, "a hook ran: swept")


## _kill_invalid leaves nothing non-finite in a slot that stays readable this tick.
func test_a_killed_bullet_keeps_no_non_finite_position_behind() -> void:
	var pool := BulletPool.new(8)
	for k in 3:
		pool.spawn(ShotRequest.with_velocity(Vector2(5, 5), Vector2(10, 0)))
	pool.pos[0] = Vector2(NAN, 1.0)
	pool.prev_pos[0] = Vector2(INF, 1.0)
	pool.rot[0] = Vector2(NAN, NAN)
	pool.prev_pos[1] = Vector2(NAN, 0.0)  # only the previous position is bad
	pool.vel[2] = Vector2(NAN, 0.0)
	for k in 3:
		assert_false(pool.sanitize(k))
	assert_eq(pool.pos[0], Vector2.ZERO, "pos falls back to the cleaned prev_pos (zero)")
	assert_eq(pool.prev_pos[0], Vector2.ZERO)
	assert_eq(pool.rot[0], Vector2.RIGHT)
	assert_eq(pool.prev_pos[1], Vector2.ZERO)
	assert_true(pool.pos[1].is_finite())
	assert_true(pool.pos[2].is_finite() and pool.prev_pos[2].is_finite())
	assert_eq(pool.vel[2], Vector2.ZERO)


## A bad velocity poked by an on_hit hook into a bullet a Reflector turns in the same
## tick must not reach normalized() (an engine error): reflect_bullet sanitizes first.
func test_reflect_bullet_with_a_poisoned_velocity_is_refused_without_engine_errors() -> void:
	var z := Reflector.new()
	z.radius = 30.0
	z.mode = Reflector.Mode.MIRROR
	add_child_autofree(z)
	z.global_position = Vector2(110, 50)
	for bad: float in [NAN, INF, -INF]:
		var pool := BulletPool.new(8)
		var rq := ShotRequest.with_velocity(Vector2(100, 50), Vector2(600, 0))
		rq.lifetime = 5.0
		pool.spawn(rq)
		pool.vel[0] = Vector2(bad, 0.0)
		assert_false(z.reflect_bullet(pool, 0, Vector2(100, 50)), "%s: refused" % bad)
		assert_eq(pool.invalid_total, 1)
		assert_eq(pool.dead_reason[0], BulletPool.DespawnReason.INVALID + 1)
		assert_eq(pool.owner_layer[0], Layers.PLAYER, "still the shooter's: never reflected")


class HitPoker:
	extends BulletBehavior
	var victim := 1
	var value := NAN
	func on_hit(pool: BulletPool, _i: int, _t: Hurtbox) -> void:
		pool.vel[victim] = Vector2(value, 0.0)


func test_an_on_hit_poke_into_a_bullet_the_reflector_turns_leaves_no_engine_error() -> void:
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 14.0
	add_child_autofree(hb)
	hb.global_position = Vector2(70, 50)
	var z := Reflector.new()
	z.radius = 30.0
	z.mode = Reflector.Mode.REVERSE
	add_child_autofree(z)
	z.global_position = Vector2(110, 50)
	var hp := HitPoker.new()
	var hid := m.register_behavior(hp)
	var writer := ShotRequest.with_velocity(Vector2(50, 50), Vector2(600, 0))
	writer.hit_mask = Layers.ENEMY
	writer.lifetime = 5.0
	writer.pierce = 5
	writer.behavior_id = hid
	var victim := ShotRequest.with_velocity(Vector2(52, 52), Vector2(2400, 0))
	victim.hit_mask = 0
	victim.lifetime = 5.0
	m.emitter.request_shot_id(writer)
	m.emitter.request_shot_id(victim)
	m.step(0.05)
	for t in 3:
		m.step(DT)
	for i in m.pool.count:
		if m.pool.dead_reason[i] == 0:
			assert_true(m.pool.pos[i].is_finite() and m.pool.vel[i].is_finite())


# --- every hook site, not only on_update (what the sweep after the hooks cannot see) ----------

## Pokes `rot` of slot `victim` (a plain bullet) once, from the hook named by `site`.
class SitePoker:
	extends BulletBehavior
	var site := ""
	var victim := 0
	var value := NAN
	var field := "rot"
	var fired := false

	func _poke(pool: BulletPool, where: String) -> void:
		if where == site and not fired:
			fired = true
			match field:
				"lifetime": pool.lifetime[victim] = value
				"age": pool.age[victim] = value
				"vel": pool.vel[victim] = Vector2(value, 0.0)
				_: pool.rot[victim] = Vector2(value, 0.0)

	func on_spawn(pool: BulletPool, _i: int) -> void:
		_poke(pool, "on_spawn")

	func on_update(pool: BulletPool, _i: int, _d: float) -> void:
		_poke(pool, "on_update")

	func can_hit(pool: BulletPool, _i: int, _t: Hurtbox) -> bool:
		_poke(pool, "can_hit")
		# Veto when this is the site under test: no hit, so no on_hit that would flag the pool too.
		return site != "can_hit"

	func on_hit(pool: BulletPool, _i: int, _t: Hurtbox) -> void:
		_poke(pool, "on_hit")

	func on_despawn(pool: BulletPool, _i: int, _reason: int) -> void:
		_poke(pool, "on_despawn")


func _site_run(site: String, value: float, field := "rot") -> SitePoker:
	m.clear_bullets()
	ScriptWarnings.reset()
	var hb := Hurtbox.new()
	hb.layer = Layers.ENEMY
	hb.radius = 12.0
	add_child_autofree(hb)
	hb.global_position = Vector2(300, 0)
	var beh := SitePoker.new()
	beh.site = site
	beh.value = value
	beh.field = field
	var bid := m.register_behavior(beh)
	# slot 0: the plain victim, far from everything and never hit.
	var victim := ShotRequest.with_velocity(Vector2(-800, -800), Vector2.ZERO)
	victim.lifetime = 5.0
	victim.hit_mask = 0
	m.emitter.request_shot_id(victim)
	var w := ShotRequest.with_velocity(Vector2(300, 0), Vector2(10, 0))
	w.hit_mask = Layers.ENEMY
	w.behavior_id = bid
	w.lifetime = 0.01 if site == "on_despawn" else 5.0
	w.can_hit_veto = site == "can_hit"
	# The writer must outlive the hit, else its own on_despawn would raise the flag and
	# hide a hook site that forgot to.
	w.pierce = 5
	m.emitter.request_shot_id(w)
	if site != "on_spawn":
		m.pool.hook_ran = false  # the spawns above flagged it; only the site under test may
	m.step(DT)
	return beh


func test_rot_poked_from_any_hook_site_is_cleaned_before_the_tick_ends() -> void:
	for site: String in ["on_spawn", "on_hit", "can_hit", "on_despawn"]:
		for v: float in [NAN, INF, -INF, 1.0e39]:
			var before := m.pool.invalid_total
			var beh := _site_run(site, v)
			assert_true(beh.fired, "%s: the hook ran" % site)
			for i in m.pool.count:
				if m.pool.dead_reason[i] == 0:
					assert_true(m.pool.rot[i].is_finite(), "%s=%s: rot of slot %d is finite after the step" % [site, v, i])
			assert_eq(m.pool.invalid_total, before + 1, "%s=%s: the victim was removed as INVALID" % [site, v])
			assert_false(m.pool.hook_ran, "%s=%s: and the flag was consumed" % [site, v])


## The hook sites flag the pool, the sweep clears it, a tick without hooks leaves it alone.
func test_the_pool_is_flagged_by_every_hook_and_the_sweep_clears_it() -> void:
	assert_false(m.pool.hook_ran)
	m.emitter.request_shot_id(_req(Vector2(0, 0)))
	m.step(DT)
	assert_false(m.pool.hook_ran, "plain bullets never flag it")
	var beh := SitePoker.new()
	beh.site = "none"
	var bid := m.register_behavior(beh)
	m.spawn(_req(Vector2(50, 0), bid))
	assert_true(m.pool.hook_ran, "on_spawn flagged it")
	m.pool.sweep_cross_writes()
	assert_false(m.pool.hook_ran, "the sweep cleared it")


## A tick in which no hook of any kind ran sweeps nothing (so a plain-bullets game pays 0).
func test_a_tick_without_any_hook_does_not_sweep() -> void:
	m.emitter.request_shot_id(_req(Vector2(0, 0)))
	m.step(DT)
	m.pool.vel[0] = Vector2(5000.0, 0.0)  # over the 4,000 px/s ceiling, written by hand
	m.step(DT)
	assert_eq(m.pool.vel[0].x, 5000.0, "nothing ran, nothing swept: the ceiling is only applied on a hook tick")
	var beh := SitePoker.new()
	beh.site = "none"
	m.spawn(_req(Vector2(500, 500), m.register_behavior(beh)))
	m.step(DT)
	assert_almost_eq(m.pool.vel[0].x, BulletLimits.MAX_SPEED, 0.01, "a hooked bullet is alive: swept")


## The clock moved out of advance(): every hook site must still get a bad age/lifetime of a
## plain bullet cleaned before the bullet could outlive the next advance().
func test_a_bad_clock_poked_from_any_hook_site_never_makes_a_plain_bullet_immortal() -> void:
	for site: String in ["on_spawn", "on_update", "on_hit", "can_hit", "on_despawn"]:
		for fv: Array in [["lifetime", INF], ["lifetime", 1.0e39], ["lifetime", NAN], ["age", -INF], ["age", NAN]]:
			var field: String = fv[0]
			var v: float = fv[1]
			var before := m.pool.invalid_total
			var beh := _site_run(site, v, field)
			assert_true(beh.fired, "%s: hook ran" % site)
			for t in 3:
				m.step(DT)
			var alive_victim := false
			for i in m.pool.count:
				if m.pool.dead_reason[i] == 0 and m.pool.pos[i].is_equal_approx(Vector2(-800, -800)):
					alive_victim = true
			assert_false(alive_victim, "%s %s=%s: the victim is gone after 3 ticks" % [site, field, v])
			assert_eq(m.pool.invalid_total, before + 1, "%s %s=%s: removed as INVALID" % [site, field, v])


## An on_spawn between two ticks that writes a finite, over-the-ceiling speed into a plain bullet:
## the start-of-step sweep clamps it before advance() moves anything.
func test_a_speed_written_by_an_on_spawn_between_ticks_does_not_travel_a_tick_first() -> void:
	var beh := SitePoker.new()
	beh.site = "on_spawn"
	beh.field = "vel"
	beh.value = 1.0e5
	var bid := m.register_behavior(beh)
	var victim := ShotRequest.with_velocity(Vector2(0, 0), Vector2.ZERO)
	victim.lifetime = 5.0
	m.emitter.request_shot_id(victim)
	m.emitter.request_shot_id(_req(Vector2(500, 500), bid))
	assert_true(m.pool.hook_ran, "the spawn flagged the pool")
	m.step(DT)
	assert_true(beh.fired)
	assert_lte(m.pool.vel[0].length(), BulletLimits.MAX_SPEED + 0.01, "clamped")
	assert_lte(m.pool.pos[0].length(), BulletLimits.MAX_SPEED * DT + 0.01, "and it moved at most one tick at the ceiling, not at 1e5 px/s")
