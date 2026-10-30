extends GutTest
## HurtboxGrid: spatial hash bucketing and bullet collision.

var grid: HurtboxGrid
var pool: BulletPool


func before_each() -> void:
	grid = HurtboxGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	pool = BulletPool.new(64)


func _bullet(p: Vector2, mask: int = Layers.ENEMY, r: float = 4.0) -> int:
	return pool.spawn_simple(p, Vector2.ZERO, 10.0, r, Color.WHITE, mask)


func test_grid_dimensions_cover_bounds() -> void:
	assert_eq(grid.cols, 16)
	assert_eq(grid.rows, 16)


func test_query_circle_finds_overlapping_target() -> void:
	var t := grid.add_circle(Vector2(100, 100), 20.0, Layers.ENEMY)
	assert_eq(grid.query_circle(Vector2(110, 100), 4.0, Layers.ENEMY), t)
	assert_eq(grid.query_circle(Vector2(100, 100), 1.0, Layers.ENEMY), t)


func test_query_circle_misses_outside_combined_radius() -> void:
	grid.add_circle(Vector2(100, 100), 20.0, Layers.ENEMY)
	assert_eq(grid.query_circle(Vector2(125, 100), 4.0, Layers.ENEMY), -1, "25 > 20 + 4")
	assert_ne(grid.query_circle(Vector2(123, 100), 4.0, Layers.ENEMY), -1, "23 <= 24")


func test_query_respects_layer_mask() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.PLAYER)
	assert_eq(grid.query_circle(Vector2(0, 0), 4.0, Layers.ENEMY), -1)
	assert_eq(grid.query_circle(Vector2(0, 0), 4.0, Layers.ENEMY | Layers.PLAYER), 0)


func test_large_target_spans_many_cells() -> void:
	var t := grid.add_circle(Vector2(0, 0), 150.0, Layers.ENEMY)
	for p: Vector2 in [Vector2(-140, 0), Vector2(140, 0), Vector2(0, -140), Vector2(0, 140), Vector2(100, 100)]:
		assert_eq(grid.query_circle(p, 1.0, Layers.ENEMY), t, str(p))


func test_target_on_cell_border_is_found_from_both_sides() -> void:
	# x = 64 is a cell border (origin -512, cell 64).
	var t := grid.add_circle(Vector2(64, 0), 10.0, Layers.ENEMY)
	assert_eq(grid.query_circle(Vector2(60, 0), 1.0, Layers.ENEMY), t)
	assert_eq(grid.query_circle(Vector2(68, 0), 1.0, Layers.ENEMY), t)


func test_margin_lets_bullet_in_neighbouring_cell_hit() -> void:
	# Target ends 2 px before the cell border; a radius-8 bullet centred just across it still overlaps.
	grid.begin(8.0)
	var t := grid.add_circle(Vector2(54, 0), 8.0, Layers.ENEMY)
	assert_eq(grid.query_circle(Vector2(66, 0), 8.0, Layers.ENEMY), t)


func test_query_outside_grid_is_a_miss() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	assert_eq(grid.query_circle(Vector2(5000, 0), 4.0, Layers.ENEMY), -1)
	assert_eq(grid.query_circle(Vector2(-5000, 0), 4.0, Layers.ENEMY), -1)


func test_clear_removes_all_targets() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	grid.clear()
	assert_eq(grid.target_count, 0)
	assert_eq(grid.query_circle(Vector2(0, 0), 4.0, Layers.ENEMY), -1)
	var t := grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	assert_eq(t, 0, "ids restart after clear")
	assert_eq(grid.query_circle(Vector2(0, 0), 4.0, Layers.ENEMY), 0)


# --- bullets ------------------------------------------------------------------

func test_collide_reports_bullet_target_pairs() -> void:
	var t0 := grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	var t1 := grid.add_circle(Vector2(200, 0), 20.0, Layers.ENEMY)
	var b_miss := _bullet(Vector2(100, 100))
	var b0 := _bullet(Vector2(10, 0))
	var b1 := _bullet(Vector2(195, 5))
	assert_eq(grid.collide_bullets(pool), 2)
	assert_eq(grid.hit_count, 2)
	assert_eq(Array(grid.hit_bullets.slice(0, grid.hit_count)), [b0, b1])
	assert_eq(Array(grid.hit_targets.slice(0, grid.hit_count)), [t0, t1])
	assert_false(Array(grid.hit_bullets.slice(0, grid.hit_count)).has(b_miss))


func test_bullet_radius_counts_toward_overlap() -> void:
	grid.begin(10.0)
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	_bullet(Vector2(28, 0), Layers.ENEMY, 10.0)
	_bullet(Vector2(-31, 0), Layers.ENEMY, 10.0)
	assert_eq(grid.collide_bullets(pool), 1)


func test_collide_ignores_bullets_that_cannot_hit_that_layer() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.PLAYER)
	_bullet(Vector2(0, 0), Layers.ENEMY)
	_bullet(Vector2(0, 0), 0)
	assert_eq(grid.collide_bullets(pool), 0)
	_bullet(Vector2(0, 0), Layers.PLAYER)
	assert_eq(grid.collide_bullets(pool), 1)


func test_collide_skips_bullets_already_marked_dead() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	var b := _bullet(Vector2(0, 0))
	pool.mark_dead(b)
	assert_eq(grid.collide_bullets(pool), 0)


func test_one_hit_per_bullet_even_when_overlapping_two_targets() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	grid.add_circle(Vector2(5, 0), 20.0, Layers.ENEMY)
	_bullet(Vector2(2, 0))
	assert_eq(grid.collide_bullets(pool), 1)


func test_piercing_bullet_is_not_rehit_on_same_target() -> void:
	var node := Node2D.new()
	autofree(node)
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY, node)
	var b := _bullet(Vector2(0, 0))
	pool.last_hit[b] = node.get_instance_id()
	assert_eq(grid.collide_bullets(pool), 0)
	pool.last_hit[b] = 0
	assert_eq(grid.collide_bullets(pool), 1)


func test_bullets_outside_grid_are_ignored() -> void:
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	_bullet(Vector2(-9999, 0))
	_bullet(Vector2(0, 9999))
	_bullet(Vector2(9999, -9999))
	assert_eq(grid.collide_bullets(pool), 0)


func test_no_targets_means_no_work() -> void:
	_bullet(Vector2(0, 0))
	assert_eq(grid.collide_bullets(pool), 0)


func test_collide_is_correct_for_many_bullets() -> void:
	pool = BulletPool.new(4000)
	grid.add_circle(Vector2(0, 0), 30.0, Layers.ENEMY)
	var expected := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 3000:
		var p := Vector2(rng.randf_range(-400, 400), rng.randf_range(-400, 400))
		_bullet(p)
		if p.length() <= 34.0:
			expected += 1
	assert_eq(grid.collide_bullets(pool), expected)


# --- swept collision (anti-tunnelling) ----------------------------------------

## A bullet whose tick moved it from `from` to `to`.
func _moving_bullet(from: Vector2, to: Vector2, mask: int = Layers.ENEMY, r: float = 4.0) -> int:
	var i := _bullet(from, mask, r)
	pool.pos[i] = to
	return i


func test_fast_bullet_does_not_tunnel_through_a_target() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 12.0, Layers.ENEMY)
	# Both endpoints are 200 px away from the target; the path goes straight through it.
	var b := _moving_bullet(Vector2(-200, 0), Vector2(200, 0))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_bullets[0], b)
	# Entry point is at x = -(12 + 4) = -16 -> 184 of 400 px along the path.
	assert_almost_eq(grid.hit_t[0], 184.0 / 400.0, 0.001)


func test_fast_bullet_passing_beside_a_target_misses() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 12.0, Layers.ENEMY)
	_moving_bullet(Vector2(-200, 30), Vector2(200, 30))
	assert_eq(grid.collide_bullets(pool), 0)


func test_fast_bullet_stopping_short_of_the_target_misses() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(100, 0), 12.0, Layers.ENEMY)
	_moving_bullet(Vector2(-200, 0), Vector2(50, 0))
	assert_eq(grid.collide_bullets(pool), 0)


func test_swept_hit_picks_the_first_target_along_the_path() -> void:
	grid.begin(4.0)
	var far := grid.add_circle(Vector2(150, 0), 12.0, Layers.ENEMY)
	var near := grid.add_circle(Vector2(-50, 0), 12.0, Layers.ENEMY)
	_moving_bullet(Vector2(-200, 0), Vector2(300, 0))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], near)
	assert_ne(grid.hit_targets[0], far)


func test_swept_path_works_in_every_direction_and_across_many_cells() -> void:
	grid.begin(4.0)
	var t := grid.add_circle(Vector2(37, -21), 10.0, Layers.ENEMY)
	var dirs: Array[Vector2] = [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(1, 1).normalized(), Vector2(-1, 1).normalized(), Vector2(1, -2).normalized(), Vector2(-3, -1).normalized()]
	for dir in dirs:
		pool.clear()
		# Start 300 px before the target and end 300 px after it, along `dir`.
		var centre := Vector2(37, -21)
		_moving_bullet(centre - dir * 300.0, centre + dir * 300.0)
		assert_eq(grid.collide_bullets(pool), 1, "direction %s" % dir)
		assert_eq(grid.hit_targets[0], t)
		assert_almost_eq(grid.hit_t[0], (300.0 - 14.0) / 600.0, 0.002)


func test_swept_bullet_respects_layer_mask_and_pierce_skip() -> void:
	grid.begin(4.0)
	var node := Node2D.new()
	autofree(node)
	grid.add_circle(Vector2(0, 0), 12.0, Layers.PLAYER, node)
	var b := _moving_bullet(Vector2(-200, 0), Vector2(200, 0), Layers.ENEMY)
	assert_eq(grid.collide_bullets(pool), 0, "wrong layer")
	pool.hit_mask[b] = Layers.PLAYER
	pool.last_hit[b] = node.get_instance_id()
	assert_eq(grid.collide_bullets(pool), 0, "already pierced this target")
	pool.last_hit[b] = 0
	assert_eq(grid.collide_bullets(pool), 1)


func test_swept_bullet_that_starts_inside_the_target_hits_at_zero() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 12.0, Layers.ENEMY)
	_moving_bullet(Vector2(5, 0), Vector2(300, 0))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_t[0], 0.0)


func test_slow_bullets_still_use_the_cheap_end_point_test() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 12.0, Layers.ENEMY)
	# Moves 5 px per tick and ends 14 px from the centre: overlapping (12 + 4 = 16).
	_moving_bullet(Vector2(19, 0), Vector2(14, 0))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_t[0], 1.0)


func test_swept_bullet_starting_outside_the_grid_falls_back_without_error() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 12.0, Layers.ENEMY)
	_moving_bullet(Vector2(-5000, 0), Vector2(0, 0))
	assert_eq(grid.collide_bullets(pool), 1, "end point overlaps, so the point test hits")


func test_grid_buffers_are_reused_between_ticks() -> void:
	grid.begin(4.0)
	for k in 10:
		grid.add_circle(Vector2(k * 40.0 - 200.0, 0), 12.0, Layers.ENEMY)
	_moving_bullet(Vector2(-300, 0), Vector2(300, 0))
	grid.collide_bullets(pool)
	var hit_size := grid.hit_bullets.size()
	var targets_size := grid.target_pos.size()
	for tick in 5:
		grid.begin(4.0)
		for k in 10:
			grid.add_circle(Vector2(k * 40.0 - 200.0, 0), 12.0, Layers.ENEMY)
		grid.collide_bullets(pool)
		assert_eq(grid.hit_bullets.size(), hit_size, "hit list is a fixed scratch buffer")
		assert_eq(grid.target_pos.size(), targets_size, "target storage is not rebuilt per tick")


# --- nearest hit across cells (QA B1) -----------------------------------------

func test_nearer_target_registered_only_in_a_later_cell_wins() -> void:
	# QA's repro. Along y = 32 the bullet (r 4) enters A (centre (100, 0), r 40)
	# at x ~ 69.8, but B (centre (75, 32), r 4) at x = 67, which is nearer. A is
	# registered in the cell column the path enters first (x 56..64 -> col 8), B
	# only in the next one (col 9): a traversal that stops at the first cell with
	# any candidate would report A.
	grid.begin(4.0)
	var a := grid.add_circle(Vector2(100, 0), 40.0, Layers.ENEMY)
	var b := grid.add_circle(Vector2(75, 32), 4.0, Layers.ENEMY)
	_moving_bullet(Vector2(-200, 32), Vector2(300, 32))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], b, "B (entry x = 67) is nearer than A (entry x = 69.8)")
	assert_ne(grid.hit_targets[0], a)
	assert_almost_eq(grid.hit_t[0], (67.0 + 200.0) / 500.0, 0.001)


func test_nearest_target_wins_whatever_order_targets_were_added_in() -> void:
	grid.begin(4.0)
	var b := grid.add_circle(Vector2(75, 32), 4.0, Layers.ENEMY)
	grid.add_circle(Vector2(100, 0), 40.0, Layers.ENEMY)
	_moving_bullet(Vector2(-200, 32), Vector2(300, 32))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], b)


func test_nearest_target_is_found_on_a_diagonal_path() -> void:
	grid.begin(4.0)
	var near := grid.add_circle(Vector2(130, 130), 6.0, Layers.ENEMY)
	grid.add_circle(Vector2(200, 200), 40.0, Layers.ENEMY)
	_moving_bullet(Vector2(-300, -300), Vector2(400, 400))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], near)


# --- piercing: several hits per tick (QA B2) ----------------------------------

func _pierce_bullet(from: Vector2, to: Vector2, pierce: int, r: float = 4.0) -> int:
	var req := ShotRequest.with_velocity(from, Vector2.ZERO)
	req.radius = r
	req.hit_mask = Layers.ENEMY
	req.pierce = pierce
	var i := pool.spawn(req)
	pool.pos[i] = to
	return i


func test_pierce_three_hits_three_targets_in_one_tick_in_path_order() -> void:
	grid.begin(4.0)
	# Added out of path order on purpose.
	var t2 := grid.add_circle(Vector2(100, 0), 10.0, Layers.ENEMY)
	var t0 := grid.add_circle(Vector2(-100, 0), 10.0, Layers.ENEMY)
	var t1 := grid.add_circle(Vector2(0, 0), 10.0, Layers.ENEMY)
	var b := _pierce_bullet(Vector2(-300, 0), Vector2(300, 0), 3)
	assert_eq(grid.collide_bullets(pool), 3)
	assert_eq(Array(grid.hit_bullets.slice(0, 3)), [b, b, b])
	assert_eq(Array(grid.hit_targets.slice(0, 3)), [t0, t1, t2])
	assert_lt(grid.hit_t[0], grid.hit_t[1])
	assert_lt(grid.hit_t[1], grid.hit_t[2])
	assert_almost_eq(grid.hit_t[0], (300.0 - 100.0 - 14.0) / 600.0, 0.001)


func test_hits_per_tick_are_capped_at_pierce_plus_one() -> void:
	grid.begin(4.0)
	for k in 5:
		grid.add_circle(Vector2(-200.0 + 100.0 * float(k), 0), 10.0, Layers.ENEMY)
	_pierce_bullet(Vector2(-300, 0), Vector2(300, 0), 1)
	assert_eq(grid.collide_bullets(pool), 2, "pierce 1: pass one target, stop at the second")
	pool.clear()
	_pierce_bullet(Vector2(-300, 0), Vector2(300, 0), 0)
	assert_eq(grid.collide_bullets(pool), 1, "no pierce: one hit")


func test_overlapping_targets_are_each_hit_once_by_a_piercing_bullet() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	grid.add_circle(Vector2(5, 0), 20.0, Layers.ENEMY)
	_pierce_bullet(Vector2(-100, 0), Vector2(100, 0), 3)
	assert_eq(grid.collide_bullets(pool), 2, "both targets, neither twice")
	assert_ne(grid.hit_targets[0], grid.hit_targets[1])


func test_piercing_bullet_that_starts_inside_two_targets_hits_both_at_zero() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	grid.add_circle(Vector2(3, 0), 20.0, Layers.ENEMY)
	_pierce_bullet(Vector2(0, 0), Vector2(30, 0), 1)
	assert_eq(grid.collide_bullets(pool), 2)
	assert_eq(grid.hit_t[0], 0.0)
	assert_eq(grid.hit_t[1], 0.0)


func test_slow_piercing_bullet_still_hits_overlapping_targets_in_one_tick() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY)
	grid.add_circle(Vector2(5, 0), 20.0, Layers.ENEMY)
	var b := _pierce_bullet(Vector2(2, 0), Vector2(2, 0), 2)
	assert_eq(grid.collide_bullets(pool), 2)
	assert_eq(grid.hit_bullets[0], b)


func test_piercing_sweep_skips_the_target_it_last_hit() -> void:
	var node := Node2D.new()
	autofree(node)
	grid.begin(4.0)
	grid.add_circle(Vector2(0, 0), 20.0, Layers.ENEMY, node)
	var t1 := grid.add_circle(Vector2(100, 0), 10.0, Layers.ENEMY)
	var b := _pierce_bullet(Vector2(-10, 0), Vector2(200, 0), 2)
	pool.last_hit[b] = node.get_instance_id()
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], t1)


func test_hit_buffers_grow_when_piercing_bullets_exceed_the_pool_size() -> void:
	pool = BulletPool.new(4)
	grid.begin(4.0)
	for k in 6:
		grid.add_circle(Vector2(-250.0 + 100.0 * float(k), 0), 10.0, Layers.ENEMY)
	for k in 4:
		_pierce_bullet(Vector2(-300, float(k) * 2.0), Vector2(300, float(k) * 2.0), 6)
	assert_eq(grid.collide_bullets(pool), 24, "4 bullets x 6 targets, more hits than pool slots")
	assert_gte(grid.hit_bullets.size(), 24)


# --- bullets that left the world bounds still test their last segment ---------

func test_bullet_marked_for_leaving_the_bounds_tests_the_part_inside() -> void:
	# Grid covers -512..512. Target at 480; the bullet flew 450 -> 560 (outside).
	grid.begin(4.0)
	var t := grid.add_circle(Vector2(480, 0), 10.0, Layers.ENEMY)
	var b := _moving_bullet(Vector2(450, 0), Vector2(560, 0))
	pool.mark_dead(b, BulletPool.DespawnReason.BOUNDS)
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], t)
	assert_almost_eq(grid.hit_t[0], (480.0 - 14.0 - 450.0) / 110.0, 0.001)


func test_bullet_marked_dead_for_another_reason_is_still_skipped() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(480, 0), 10.0, Layers.ENEMY)
	var b := _moving_bullet(Vector2(450, 0), Vector2(500, 0))
	pool.mark_dead(b, BulletPool.DespawnReason.LIFETIME)
	assert_eq(grid.collide_bullets(pool), 0)


func test_bullet_entirely_outside_the_grid_hits_nothing() -> void:
	grid.begin(4.0)
	grid.add_circle(Vector2(500, 0), 10.0, Layers.ENEMY)
	var b := _moving_bullet(Vector2(600, 0), Vector2(800, 0))
	pool.mark_dead(b, BulletPool.DespawnReason.BOUNDS)
	assert_eq(grid.collide_bullets(pool), 0)


func test_bullet_entering_the_grid_from_outside_tests_the_part_inside() -> void:
	grid.begin(4.0)
	var t := grid.add_circle(Vector2(-480, 0), 10.0, Layers.ENEMY)
	_moving_bullet(Vector2(-700, 0), Vector2(-400, 0))
	assert_eq(grid.collide_bullets(pool), 1)
	assert_eq(grid.hit_targets[0], t)


func test_margin_getter_reports_the_bucketing_margin() -> void:
	grid.begin(12.5)
	assert_eq(grid.get_margin(), 12.5)
