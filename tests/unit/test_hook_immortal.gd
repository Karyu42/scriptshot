extends GutTest
## QA's repro from the PR #13 review (plus the finite and normal cases around it): a cross-written lifetime=+inf or age=-inf in a plain bullet that is never hit.
## advance() only tests `not a < lifetime`, so +inf lifetime / -inf age never reach the
## finite check: the bullet is immortal (a stationary one never even leaves the bounds).
const DT := 1.0 / 60.0


func before_each() -> void:
	ScriptWarnings.reset()

class Poke:
	extends BulletBehavior
	var field := ""
	var done := false
	func on_update(pool: BulletPool, _i: int, _d: float) -> void:
		if done: return
		done = true
		if field == "lifetime": pool.lifetime[1] = INF
		elif field == "age": pool.age[1] = -INF
		elif field == "lifetime_big": pool.lifetime[1] = 1.0e9   # finite but > MAX_LIFETIME (600 s)
		elif field == "lifetime_1e39": pool.lifetime[1] = 1.0e39  # inf once stored as float32

func _run(field: String) -> Array[int]:
	ScriptWarnings.reset()
	var m := BulletManager.new()
	m.backend_preference = "gdscript"
	m.capacity = 16
	m.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	var p := Poke.new(); p.field = field
	var r := ShotRequest.with_velocity(Vector2(0, 0), Vector2(0, 0))
	r.lifetime = 1.0
	r.behavior_id = m.register_behavior(p)
	m.emitter.request_shot_id(r)
	var rv := ShotRequest.with_velocity(Vector2(500, 500), Vector2(0, 0))  # stationary, plain, hit by nothing
	rv.lifetime = 1.0
	m.emitter.request_shot_id(rv)
	# run 3 simulated seconds (the victim's own lifetime was 1 s)
	for t in 180:
		m.step(DT)
	var out: Array[int] = [m.pool.count, m.pool.invalid_total]
	return out

func test_lifetime_inf() -> void:
	var r := _run("lifetime")
	var c: int = r[0]
	assert_eq(c, 0, "victim must be gone (killed INVALID or clamped to MAX_LIFETIME and expired) - count=%d invalid=%d" % [r[0], r[1]])
func test_age_neg_inf() -> void:
	var r := _run("age")
	var c: int = r[0]
	assert_eq(c, 0, "victim must be gone - count=%d invalid=%d" % [r[0], r[1]])

func test_lifetime_1e39_is_inf_in_float32() -> void:
	var r := _run("lifetime_1e39")
	var c: int = r[0]
	assert_eq(c, 0, "victim must be gone - count=%d invalid=%d" % [r[0], r[1]])


func test_inf_lifetime_and_neg_inf_age_are_killed_as_invalid() -> void:
	for f: String in ["lifetime", "age", "lifetime_1e39"]:
		var r := _run(f)
		var inv: int = r[1]
		assert_eq(inv, 1, "%s: removed as INVALID, not left to expire" % f)


## Direct pool tests of the advance() clock test.
func _one_bullet(life: float, age: float) -> BulletPool:
	var pool := BulletPool.new(4)
	var rq := ShotRequest.with_velocity(Vector2.ZERO, Vector2.ZERO)
	rq.lifetime = 1.0
	pool.spawn(rq)
	pool.lifetime[0] = life
	pool.age[0] = age
	pool.sweep_cross_writes()  # the clock is the sweeps' business (a hook wrote it), then the tick
	pool.advance(DT, Rect2(-100, -100, 200, 200))
	return pool


func test_a_finite_lifetime_over_the_limit_is_clamped_and_the_bullet_lives_on() -> void:
	var pool := _one_bullet(1.0e9, 0.0)
	assert_eq(pool.dead_reason[0], 0)
	assert_eq(pool.lifetime[0], BulletLimits.MAX_LIFETIME)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.lifetime"), 1)


func test_an_age_far_below_zero_is_reset_and_a_small_negative_age_is_left_alone() -> void:
	var far := _one_bullet(5.0, -1.0e9)
	assert_eq(far.dead_reason[0], 0)
	assert_almost_eq(far.age[0], DT, 0.0001, "reset to 0, then this tick's delta")
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 1)
	ScriptWarnings.reset()
	var small := _one_bullet(5.0, -3.0)
	assert_eq(small.dead_reason[0], 0)
	assert_almost_eq(small.age[0], -3.0 + DT, 0.0001, "a delayed start (age < 0) is not touched")
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 0)


func test_a_lifetime_between_the_limit_and_twice_the_limit_is_clamped_like_a_spawn() -> void:
	for life: float in [601.0, 700.0, 1199.0, 1200.0, 1201.0]:
		ScriptWarnings.reset()
		var pool := _one_bullet(life, 0.0)
		assert_eq(pool.dead_reason[0], 0, "%s: alive" % life)
		assert_eq(pool.lifetime[0], BulletLimits.MAX_LIFETIME, "%s: clamped to the same 600 s as a spawn" % life)
		assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.lifetime"), 1)


## The fast-path window is (0, MAX_LIFETIME) of time left; its edges.
func test_the_edges_of_the_clock_window() -> void:
	var m := BulletLimits.MAX_LIFETIME
	# just inside the top edge (left just under 600 s after this tick): untouched, silent.
	var inside := _one_bullet(m - 1.0, 0.0)
	assert_eq(inside.lifetime[0], m - 1.0)
	assert_eq(inside.dead_reason[0], 0)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.lifetime") + ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 0)
	# exactly the maximum lifetime at age 0: fine, nothing to say.
	var top := _one_bullet(m, 0.0)
	assert_eq(top.dead_reason[0], 0)
	assert_eq(top.lifetime[0], m)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.lifetime"), 0)
	# time left over the limit through a negative age: age is reset, the lifetime is not changed.
	var over := _one_bullet(m, -10.0)
	assert_eq(over.lifetime[0], m)
	assert_almost_eq(over.age[0], DT, 0.0001)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 1)
	ScriptWarnings.reset()
	# bottom edge: a bullet whose age reaches its lifetime exactly expires on that tick (as
	# `age >= lifetime` did), one a hair short of it does not.
	for life: float in [0.25, 1.0, 100.0]:
		var done := BulletPool.new(2)
		var rq := ShotRequest.with_velocity(Vector2.ZERO, Vector2.ZERO)
		rq.lifetime = life
		done.spawn(rq)
		done.advance(life, Rect2(-10, -10, 20, 20))
		assert_eq(done.dead_reason[0], BulletPool.DespawnReason.LIFETIME + 1, "age == lifetime (%s) expires this tick" % life)
		assert_eq(done.invalid_total, 0)
		var short := BulletPool.new(2)
		short.spawn(rq)
		short.advance(life * 0.999, Rect2(-10, -10, 20, 20))
		assert_eq(short.dead_reason[0], 0, "a hair short of %s lives" % life)


func test_normal_clocks_end_where_they_used_to() -> void:
	var done := _one_bullet(DT * 0.5, 0.0)
	assert_eq(done.dead_reason[0], BulletPool.DespawnReason.LIFETIME + 1)
	var alive := _one_bullet(5.0, 0.0)
	assert_eq(alive.dead_reason[0], 0)
	var neg_life := _one_bullet(-1.0, 0.0)
	assert_eq(neg_life.dead_reason[0], BulletPool.DespawnReason.LIFETIME + 1, "a negative lifetime is simply over")
	assert_eq(done.invalid_total + alive.invalid_total + neg_life.invalid_total, 0)


## The window is (0, MAX_LIFETIME) of time left, but a bullet inside the *limits* must never
## be touched: lifetime 400 with age -1 (time left 401) lives, silently. (A window that
## were only 300 s wide would send it down the slow path, which resets a negative age.)
func test_a_lifetime_of_400_with_age_minus_1_is_left_alone() -> void:
	var pool := _one_bullet(400.0, -1.0)
	assert_eq(pool.dead_reason[0], 0)
	assert_eq(pool.lifetime[0], 400.0)
	assert_almost_eq(pool.age[0], -1.0 + DT, 0.0001, "age untouched, only this tick's delta added")
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 0, "no warning")
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.lifetime"), 0)
	var pool2 := _one_bullet(598.0, -1.0)  # time left 599: still inside, still silent
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 0)
	assert_eq(pool2.dead_reason[0], 0)
	# The window is open at both ends: a time left of exactly MAX_LIFETIME (599 + 1) is out.
	var pool3 := _one_bullet(599.0, -1.0)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write.clamp.age"), 1, "time left == MAX_LIFETIME: reset, warned")
	assert_almost_eq(pool3.age[0], DT, 0.0001, "reset to 0, then this tick's delta")
