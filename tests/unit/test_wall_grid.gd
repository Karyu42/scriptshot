extends GutTest
## WallGrid: static wall rectangles and swept bullet-vs-wall tests.

var walls: WallGrid
var pool: BulletPool


func before_each() -> void:
	walls = WallGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	pool = BulletPool.new(64)


## A bullet that moved from `from` to `to` this tick.
func _bullet(from: Vector2, to: Vector2, r: float = 4.0, world := true) -> int:
	var req := ShotRequest.with_velocity(from, Vector2.ZERO)
	req.radius = r
	req.collide_world = world
	var i := pool.spawn(req)
	pool.pos[i] = to
	return i


func test_clear_path_has_no_hit() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	assert_eq(walls.first_hit(Vector2(0, 100), Vector2(300, 0), 4.0), -1.0, "passes below the wall")
	assert_eq(walls.first_hit(Vector2(0, 0), Vector2(50, 0), 4.0), -1.0, "stops before the wall")


func test_hit_fraction_accounts_for_bullet_radius() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	# Bullet centre reaches x = 96 (wall face 100 minus radius 4) after 96 of 200 px.
	assert_almost_eq(walls.first_hit(Vector2(0, 0), Vector2(200, 0), 4.0), 0.48, 0.0001)


func test_thin_wall_is_not_tunnelled_by_a_very_fast_bullet() -> void:
	walls.add_wall(Rect2(0, -100, 2, 200))
	assert_almost_eq(walls.first_hit(Vector2(-400, 0), Vector2(800, 0), 3.0), (400.0 - 3.0) / 800.0, 0.0001)


func test_bullet_starting_inside_a_wall_hits_at_zero() -> void:
	walls.add_wall(Rect2(-50, -50, 100, 100))
	assert_eq(walls.first_hit(Vector2(0, 0), Vector2(10, 0), 4.0), 0.0)
	assert_eq(walls.first_hit(Vector2(0, 0), Vector2.ZERO, 4.0), 0.0)


func test_first_of_several_walls_is_reported() -> void:
	walls.add_wall(Rect2(300, -50, 20, 100))
	walls.add_wall(Rect2(100, -50, 20, 100))
	assert_almost_eq(walls.first_hit(Vector2(0, 0), Vector2(450, 0), 0.0), 100.0 / 450.0, 0.0001)


func test_diagonal_path_across_many_cells_hits_a_wall() -> void:
	walls.add_wall(Rect2(200, 200, 40, 40))
	var t := walls.first_hit(Vector2(-300, -300), Vector2(700, 700), 2.0)
	assert_almost_eq(t, (500.0 - 2.0) / 700.0, 0.001)


func test_sweep_lists_only_bullets_that_hit_and_does_not_move_them() -> void:
	walls.add_wall(Rect2(100, -50, 20, 100))
	var hit := _bullet(Vector2(90, 0), Vector2(104, 0))
	var miss := _bullet(Vector2(0, 200), Vector2(14, 200))
	assert_eq(walls.sweep_bullets(pool), 1)
	assert_eq(walls.hit_bullets[0], hit)
	assert_ne(walls.hit_bullets[0], miss)
	assert_almost_eq(walls.hit_t[0], (96.0 - 90.0) / 14.0, 0.001)
	assert_eq(pool.pos[hit], Vector2(104, 0), "the manager, not the grid, clips the path")


func test_fast_bullets_take_the_long_path_and_still_hit() -> void:
	walls.add_wall(Rect2(0, -100, 10, 200))
	_bullet(Vector2(-300, 0), Vector2(300, 0))
	assert_eq(walls.sweep_bullets(pool), 1)


func test_world_opt_out_and_dead_bullets_are_ignored() -> void:
	walls.add_wall(Rect2(-50, -50, 100, 100))
	_bullet(Vector2(0, 0), Vector2(1, 0), 4.0, false)
	var dead := _bullet(Vector2(0, 0), Vector2(1, 0))
	pool.mark_dead(dead)
	assert_eq(walls.sweep_bullets(pool), 0)


func test_no_walls_means_no_hits() -> void:
	_bullet(Vector2(0, 0), Vector2(1, 0))
	assert_eq(walls.sweep_bullets(pool), 0)


func test_clear_walls_and_rebuild_after_adding() -> void:
	walls.add_wall(Rect2(-50, -50, 100, 100))
	_bullet(Vector2(0, 0), Vector2(1, 0))
	assert_eq(walls.sweep_bullets(pool), 1)
	walls.clear_walls()
	assert_eq(walls.sweep_bullets(pool), 0)
	walls.add_wall(Rect2(-10, -10, 20, 20))
	assert_eq(walls.sweep_bullets(pool), 1, "walls added after a sweep are picked up")


func test_bullets_outside_the_grid_do_not_error_and_walls_clamp_into_edge_cells() -> void:
	walls.add_wall(Rect2(-600, -20, 100, 40))  # partly outside the grid bounds
	_bullet(Vector2(-9000, 0), Vector2(-8990, 0))
	_bullet(Vector2(9000, 9000), Vector2(9010, 9010))
	assert_eq(walls.sweep_bullets(pool), 0)
	var edge := _bullet(Vector2(-505, 0), Vector2(-500, 0))
	assert_eq(walls.sweep_bullets(pool), 1)
	assert_eq(walls.hit_bullets[0], edge)


func test_a_bigger_bullet_than_expected_rebuilds_the_buckets() -> void:
	walls.add_wall(Rect2(200, 0, 20, 20))
	_bullet(Vector2(100, 10), Vector2(103, 10), 2.0)
	walls.sweep_bullets(pool)
	pool.clear()
	# Radius 100 bullet whose end position is ~2 cells away from the wall.
	_bullet(Vector2(100, 10), Vector2(106, 10), 100.0)
	assert_eq(walls.sweep_bullets(pool), 1, "wall is within the bullet's radius")


func test_sweep_scratch_buffers_are_reused() -> void:
	walls.add_wall(Rect2(-50, -50, 100, 100))
	_bullet(Vector2(0, 0), Vector2(1, 0))
	walls.sweep_bullets(pool)
	var size := walls.hit_bullets.size()
	for k in 5:
		walls.sweep_bullets(pool)
		assert_eq(walls.hit_bullets.size(), size)


# --- shape_issue: what collect_walls() warns about -----------------------------

func test_axis_aligned_rectangles_are_fine() -> void:
	var rect := RectangleShape2D.new()
	assert_eq(WallGrid.shape_issue(rect, Transform2D(0.0, Vector2(10, 10))), "")
	assert_eq(WallGrid.shape_issue(rect, Transform2D(0.0, Vector2(3, 2), 0.0, Vector2(10, 10))), "", "scaled but not rotated")


func test_rotated_rectangles_are_reported_as_approximated() -> void:
	var issue := WallGrid.shape_issue(RectangleShape2D.new(), Transform2D(0.3, Vector2.ZERO))
	assert_string_contains(issue, "rotated")
	assert_string_contains(issue, "bounding box")


func test_non_rectangle_shapes_are_reported_as_ignored() -> void:
	for shape: Shape2D in [CircleShape2D.new(), CapsuleShape2D.new(), ConvexPolygonShape2D.new()]:
		var issue := WallGrid.shape_issue(shape, Transform2D.IDENTITY)
		assert_string_contains(issue, "ignored", shape.get_class())
		assert_string_contains(issue, shape.get_class())
	assert_string_contains(WallGrid.shape_issue(null, Transform2D.IDENTITY), "no shape")
