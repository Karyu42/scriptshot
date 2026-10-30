extends GutTest
## Wall normals: WallGrid reports the face a bullet entered through, and the
## manager / emitter hand it to hooks.

const DT := 1.0 / 60.0

var walls: WallGrid
var pool: BulletPool


func before_each() -> void:
	walls = WallGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	pool = BulletPool.new(64)


func _normal(start: Vector2, d: Vector2, r: float = 0.0) -> Vector2:
	assert_gte(walls.first_hit(start, d, r), 0.0, "expected a hit")
	return walls.last_normal


func _bullet(from: Vector2, to: Vector2, r: float = 0.0) -> int:
	var req := ShotRequest.with_velocity(from, Vector2.ZERO)
	req.radius = r
	var i := pool.spawn(req)
	pool.pos[i] = to
	return i


# --- the four faces --------------------------------------------------------------

func test_each_face_reports_its_outward_normal() -> void:
	walls.add_wall(Rect2(-50, -50, 100, 100))
	assert_eq(_normal(Vector2(-200, 0), Vector2(400, 0)), Vector2.LEFT, "entering the left face")
	assert_eq(_normal(Vector2(200, 0), Vector2(-400, 0)), Vector2.RIGHT, "entering the right face")
	assert_eq(_normal(Vector2(0, -200), Vector2(0, 400)), Vector2.UP, "entering the top face")
	assert_eq(_normal(Vector2(0, 200), Vector2(0, -400)), Vector2.DOWN, "entering the bottom face")


func test_oblique_hit_uses_the_face_actually_crossed_first() -> void:
	walls.add_wall(Rect2(100, -50, 100, 100))
	# Shallow angle from the left: crosses x = 100 well before y = -50.
	assert_eq(_normal(Vector2(0, -20), Vector2(200, 30)), Vector2.LEFT)
	# Steep angle from above-left: reaches y = -50 first.
	assert_eq(_normal(Vector2(80, -250), Vector2(60, 400)), Vector2.UP)


func test_normal_accounts_for_the_bullet_radius() -> void:
	walls.add_wall(Rect2(100, 0, 100, 100))
	# Centre line passes 3 px above the wall; with radius 4 it grazes the top face.
	assert_eq(_normal(Vector2(0, -3), Vector2(200, 0), 4.0), Vector2.LEFT, "enters the inflated left face first")
	assert_eq(_normal(Vector2(150, -100), Vector2(0, 200), 4.0), Vector2.UP)


func test_normal_is_a_unit_vector() -> void:
	walls.add_wall(Rect2(100, -50, 100, 100))
	assert_almost_eq(_normal(Vector2(0, -20), Vector2(200, 30)).length(), 1.0, 1e-6)


func test_clear_path_gives_a_zero_normal() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	assert_eq(walls.first_hit(Vector2(0, 100), Vector2(300, 0), 4.0), -1.0)
	assert_eq(walls.last_normal, Vector2.ZERO)
	# A later clear query must not leave the previous normal behind.
	walls.first_hit(Vector2(0, 0), Vector2(300, 0), 0.0)
	assert_eq(walls.last_normal, Vector2.LEFT)
	walls.first_hit(Vector2(0, 100), Vector2(300, 0), 0.0)
	assert_eq(walls.last_normal, Vector2.ZERO)


func test_the_nearest_wall_decides() -> void:
	walls.add_wall(Rect2(300, -50, 20, 100))
	walls.add_wall(Rect2(100, -50, 20, 100))
	walls.add_wall(Rect2(-100, -300, 20, 600))  # behind the start, never touched
	assert_eq(_normal(Vector2(0, 0), Vector2(500, 0)), Vector2.LEFT)
	var left_of_start := WallGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	left_of_start.add_wall(Rect2(-100, -50, 20, 100))
	left_of_start.first_hit(Vector2(0, 0), Vector2(-500, 0), 0.0)
	assert_eq(left_of_start.last_normal, Vector2.RIGHT, "a wall to the left is entered through its right face")


# --- corners ----------------------------------------------------------------------

func test_diagonal_corner_hit_prefers_the_axis_moving_faster() -> void:
	walls.add_wall(Rect2(100, 50, 100, 100))
	# Reaches x = 100 and y = 50 at exactly t = 0.5: a corner. dx > dy -> x face.
	assert_eq(_normal(Vector2.ZERO, Vector2(200, 100)), Vector2.LEFT)
	var tall := WallGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	tall.add_wall(Rect2(50, 100, 100, 100))
	tall.first_hit(Vector2.ZERO, Vector2(100, 200), 0.0)
	assert_eq(tall.last_normal, Vector2.UP, "dy > dx -> y face")


func test_exact_45_degree_corner_hit_goes_to_the_x_face() -> void:
	walls.add_wall(Rect2(100, 100, 50, 50))
	assert_eq(_normal(Vector2.ZERO, Vector2(200, 200)), Vector2.LEFT)
	var other := WallGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	other.add_wall(Rect2(-150, -150, 50, 50))
	other.first_hit(Vector2.ZERO, Vector2(-200, -200), 0.0)
	assert_eq(other.last_normal, Vector2.RIGHT, "same rule from the other side")


func test_corner_normal_is_repeatable() -> void:
	walls.add_wall(Rect2(100, 100, 50, 50))
	var first := _normal(Vector2.ZERO, Vector2(200, 200))
	for k in 20:
		assert_eq(_normal(Vector2.ZERO, Vector2(200, 200)), first)


func test_two_walls_reached_at_the_same_instant_use_the_lower_wall_index() -> void:
	# Wall A's left face and wall B's top face are both reached at t = 0.5.
	var a := Rect2(100, 0, 50, 50)
	var b := Rect2(50, 50, 50, 50)
	walls.add_wall(a)
	walls.add_wall(b)
	assert_eq(_normal(Vector2.ZERO, Vector2(200, 100)), Vector2.LEFT, "A was added first")
	var swapped := WallGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	swapped.add_wall(b)
	swapped.add_wall(a)
	swapped.first_hit(Vector2.ZERO, Vector2(200, 100), 0.0)
	assert_eq(swapped.last_normal, Vector2.UP, "B was added first")


# --- starting inside ------------------------------------------------------------------

func test_a_bullet_that_starts_inside_is_pushed_out_through_the_nearest_face() -> void:
	walls.add_wall(Rect2(-50, -50, 100, 100))
	assert_eq(_normal(Vector2(40, 0), Vector2(5, 0)), Vector2.RIGHT)
	assert_eq(_normal(Vector2(-40, 0), Vector2(5, 0)), Vector2.LEFT)
	assert_eq(_normal(Vector2(0, -45), Vector2(0, 5)), Vector2.UP)
	assert_eq(_normal(Vector2(0, 45), Vector2(0, 5)), Vector2.DOWN)
	assert_eq(_normal(Vector2(0, 0), Vector2.ZERO), Vector2.LEFT, "dead centre: the tie goes left, deterministically")
	assert_eq(_normal(Vector2(20, 10), Vector2.ZERO), Vector2.RIGHT, "a stationary bullet has a normal too")


# --- sweep_bullets: fast path, long path, pool arrays ------------------------------------

func test_sweep_reports_a_normal_per_hit_on_the_short_path() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	var from_left := _bullet(Vector2(90, 0), Vector2(104, 0))
	walls.sweep_bullets(pool)
	assert_eq(walls.hit_count, 1)
	assert_eq(walls.hit_bullets[0], from_left)
	assert_eq(walls.normal_of_hit(0, pool), Vector2.LEFT)


func test_sweep_reports_a_normal_per_hit_on_the_long_path() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	var from_right := _bullet(Vector2(400, 0), Vector2(-300, 0))
	walls.sweep_bullets(pool)
	assert_eq(walls.hit_bullets[0], from_right)
	assert_eq(walls.normal_of_hit(0, pool), Vector2.RIGHT)


func test_sweep_normals_stay_parallel_to_the_hit_list() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	walls.add_wall(Rect2(-300, 200, 100, 20))
	_bullet(Vector2(0, 0), Vector2(5, 0))  # no hit
	var b := _bullet(Vector2(90, 0), Vector2(104, 0))
	_bullet(Vector2(0, 50), Vector2(5, 50))  # no hit
	var c := _bullet(Vector2(-250, 150), Vector2(-250, 205))
	walls.sweep_bullets(pool)
	assert_eq(walls.hit_count, 2)
	for k in 2:
		if walls.hit_bullets[k] == b:
			assert_eq(walls.normal_of_hit(k, pool), Vector2.LEFT)
		else:
			assert_eq(walls.hit_bullets[k], c)
			assert_eq(walls.normal_of_hit(k, pool), Vector2.UP)


func test_short_and_long_path_agree_on_a_corner() -> void:
	walls.add_wall(Rect2(10, 5, 5, 5))
	walls.add_wall(Rect2(5, 5, 5, 5))  # tie partner, see test above
	var near := _bullet(Vector2.ZERO, Vector2(20, 10))
	walls.sweep_bullets(pool)
	var short_normal := walls.normal_of_hit(0, pool)
	assert_eq(walls.hit_bullets[0], near)
	walls.clear_walls()
	walls.add_wall(Rect2(100, 50, 50, 50))
	walls.add_wall(Rect2(50, 50, 50, 50))
	pool.clear()
	_bullet(Vector2.ZERO, Vector2(200, 100))
	walls.sweep_bullets(pool)
	assert_eq(walls.normal_of_hit(0, pool), short_normal, "the same geometry scaled 10x gives the same face")


func test_normal_buffer_grows_with_the_pool() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	var big := BulletPool.new(300)
	for k in 200:
		var req := ShotRequest.with_velocity(Vector2(90, 0), Vector2.ZERO)
		var i := big.spawn(req)
		big.pos[i] = Vector2(104, 0)
	walls.sweep_bullets(big)
	assert_eq(walls.hit_count, 200)
	assert_eq(walls.normal_of_hit(199, big), Vector2.LEFT)


# --- manager / emitter ----------------------------------------------------------------

class NormalLog:
	extends BulletBehavior
	var normals: Array[Vector2] = []
	var reasons: Array[int] = []
	var emitter_normals: Array[Vector2] = []
	var manager: BulletManager

	func on_despawn(pool: BulletPool, index: int, reason: int) -> void:
		reasons.append(reason)
		normals.append(manager.wall_normal_of(index))
		emitter_normals.append(emitter.get_wall_normal(pool.id_of(index)))


func _manager() -> BulletManager:
	var m := BulletManager.new()
	m.capacity = 64
	m.world_bounds = Rect2(-500, -500, 1000, 1000)
	m.render_enabled = false
	m.auto_step = false
	add_child_autofree(m)
	return m


func test_on_despawn_can_read_the_wall_normal() -> void:
	var m := _manager()
	m.add_wall(Rect2(100, -50, 20, 100))
	var log := NormalLog.new()
	log.manager = m
	var r := ShotRequest.polar(Vector2(80, 0), 0.0, 1200.0)
	r.behavior_id = m.register_behavior(log)
	m.spawn(r)
	m.step(DT)
	assert_eq(log.reasons, [BulletPool.DespawnReason.WALL] as Array[int])
	assert_eq(log.normals, [Vector2.LEFT] as Array[Vector2])
	assert_eq(log.emitter_normals, [Vector2.LEFT] as Array[Vector2])


func test_no_normal_for_bullets_that_died_another_way() -> void:
	var m := _manager()
	m.add_wall(Rect2(100, -50, 20, 100))
	var log := NormalLog.new()
	log.manager = m
	var r := ShotRequest.polar(Vector2(0, 200), 0.0, 10.0)
	r.lifetime = 0.01
	r.behavior_id = m.register_behavior(log)
	m.spawn(r)
	m.step(DT)
	assert_eq(log.reasons, [BulletPool.DespawnReason.LIFETIME] as Array[int])
	assert_eq(log.normals, [Vector2.ZERO] as Array[Vector2])


func test_wall_normal_is_cleared_after_the_tick() -> void:
	var m := _manager()
	m.add_wall(Rect2(100, -50, 20, 100))
	m.spawn(ShotRequest.polar(Vector2(80, 0), 0.0, 1200.0))
	m.spawn(ShotRequest.polar(Vector2(0, 200), 0.0, 10.0))
	m.step(DT)
	for slot in 4:
		assert_eq(m.wall_normal_of(slot), Vector2.ZERO)
	assert_eq(m.wall_normal_of(-1), Vector2.ZERO)
	assert_eq(m.emitter.get_wall_normal(-1), Vector2.ZERO)
	assert_eq(m.emitter.get_wall_normal(123456789), Vector2.ZERO, "stale id")


func test_a_reused_slot_does_not_inherit_a_stale_normal() -> void:
	var m := _manager()
	m.add_wall(Rect2(100, -50, 20, 100))
	m.spawn(ShotRequest.polar(Vector2(80, 0), 0.0, 1200.0))
	m.step(DT)
	m.spawn(ShotRequest.polar(Vector2(0, 200), 0.0, 10.0))
	assert_eq(m.wall_normal_of(0), Vector2.ZERO)


func test_each_bullet_gets_its_own_wall_normal_in_one_tick() -> void:
	var m := _manager()
	m.add_wall(Rect2(100, -50, 20, 100))
	var log := NormalLog.new()
	log.manager = m
	var id := m.register_behavior(log)
	var from_left := ShotRequest.polar(Vector2(80, 0), 0.0, 1200.0)
	from_left.behavior_id = id
	var from_right := ShotRequest.polar(Vector2(140, 0), PI, 1200.0)
	from_right.behavior_id = id
	m.spawn(from_left)
	m.spawn(from_right)
	m.step(DT)
	assert_eq(log.normals.size(), 2)
	assert_true(log.normals.has(Vector2.LEFT))
	assert_true(log.normals.has(Vector2.RIGHT))
