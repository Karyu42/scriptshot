extends GutTest
## BulletRenderer: bucketed live-only MultiMesh, interpolation buffers.

const STRIDE := BulletRenderer.FLOATS_PER_INSTANCE

var pool: BulletPool
var renderer: BulletRenderer


func before_each() -> void:
	pool = BulletPool.new(2048)
	renderer = BulletRenderer.new()
	add_child_autofree(renderer)
	renderer.setup(2048, Rect2(-1000, -1000, 2000, 2000))


func _spawn(count: int) -> void:
	for i in count:
		pool.spawn_simple(Vector2(float(i), 0.0), Vector2(60.0, 0.0), 10.0)


func test_starts_with_the_smallest_bucket_and_nothing_visible() -> void:
	assert_eq(renderer.allocated, BulletRenderer.MIN_INSTANCES)
	assert_eq(renderer.multimesh.instance_count, BulletRenderer.MIN_INSTANCES)
	assert_eq(renderer.multimesh.visible_instance_count, 0)
	assert_true(renderer.multimesh.use_colors)


func test_only_the_live_bullets_are_visible_and_buffers_match_the_bucket() -> void:
	_spawn(10)
	renderer.update_from(pool)
	assert_eq(renderer.multimesh.visible_instance_count, 10)
	assert_eq(renderer.allocated, BulletRenderer.MIN_INSTANCES, "10 bullets do not need a bigger bucket")
	assert_eq(renderer.get_current_buffer().size(), renderer.allocated * STRIDE)
	assert_eq(renderer.get_previous_buffer().size(), renderer.allocated * STRIDE)


func test_bucket_grows_with_headroom_and_never_exceeds_capacity() -> void:
	_spawn(300)
	renderer.update_from(pool)
	assert_eq(renderer.allocated, BulletRenderer.bucket_for(300, 2048))
	assert_between(renderer.allocated, 300, 600, "a bucket is within ~2x of the live count, not the pool capacity")
	assert_eq(renderer.multimesh.visible_instance_count, 300)
	_spawn(1700)
	renderer.update_from(pool)
	assert_eq(renderer.allocated, 2048)


func test_bucket_math() -> void:
	assert_eq(BulletRenderer.bucket_for(0, 2048), BulletRenderer.MIN_INSTANCES)
	assert_eq(BulletRenderer.bucket_for(1000, 16384), 1280)
	assert_eq(BulletRenderer.bucket_for(100000, 16384), 16384)
	assert_eq(BulletRenderer.bucket_for(5, 100), 100, "never above the pool capacity")


func test_bucket_shrinks_lazily() -> void:
	_spawn(1000)
	renderer.update_from(pool)
	var big := renderer.allocated
	assert_gte(big, 1000)
	pool.clear()
	_spawn(big * 6 / 10)
	renderer.update_from(pool)
	assert_eq(renderer.allocated, big, "above half the bucket: keep it")
	pool.clear()
	_spawn(100)
	renderer.update_from(pool)
	assert_lt(renderer.allocated, big, "below half the bucket: shrink")
	assert_gte(renderer.allocated, 100)


func test_steady_state_does_not_reallocate() -> void:
	_spawn(700)
	renderer.update_from(pool)
	var reallocations := renderer.reallocations
	for tick in 30:
		pool.advance(1.0 / 60.0, Rect2(-1000, -1000, 2000, 2000))
		renderer.update_from(pool)
	assert_eq(renderer.reallocations, reallocations)


func test_multimesh_has_fixed_bounds_covering_the_world() -> void:
	var aabb := renderer.multimesh.custom_aabb
	assert_lte(aabb.position.x, -1000.0)
	assert_gte(aabb.end.x, 1000.0)
	assert_lte(aabb.position.y, -1000.0)
	assert_gte(aabb.end.y, 1000.0)


func test_physics_interpolation_is_active_for_the_renderer() -> void:
	assert_true(renderer.is_physics_interpolated_and_enabled(), "project setting on and node not opted out")


func test_current_and_previous_buffers_hold_end_and_start_of_tick_positions() -> void:
	var req := ShotRequest.polar(Vector2(10, 20), 0.0, 600.0)
	req.radius = 5.0
	req.color = Color(0.25, 0.5, 0.75, 1.0)
	pool.spawn(req)
	pool.advance(1.0 / 60.0, Rect2(-1000, -1000, 2000, 2000))
	renderer.update_from(pool)
	var cur := renderer.get_current_buffer()
	var prev := renderer.get_previous_buffer()
	assert_almost_eq(cur[3], 20.0, 0.001, "x at end of tick")
	assert_almost_eq(cur[7], 20.0, 0.001)
	assert_almost_eq(prev[3], 10.0, 0.001, "x at start of tick")
	assert_almost_eq(prev[7], 20.0, 0.001)
	for k: int in [0, 1, 4, 5, 8, 9, 10, 11]:
		assert_eq(prev[k], cur[k], "orientation and colour are not interpolated (float %d)" % k)
	assert_almost_eq(cur[0], 10.0, 0.001, "heading +x, radius 5 -> 10 px long")
	assert_almost_eq(cur[5], 10.0, 0.001)
	assert_almost_eq(cur[8], 0.25, 0.0001)
	assert_almost_eq(cur[10], 0.75, 0.0001)


func test_previous_positions_follow_their_bullet_through_swap_removal() -> void:
	for i in 3:
		pool.spawn_simple(Vector2(100.0 * float(i), 0.0), Vector2(60.0, 0.0), 10.0)
	pool.advance(1.0 / 60.0, Rect2(-1000, -1000, 2000, 2000))
	pool.despawn(0)  # the last bullet (x = 200 -> 201, was 200) moves into slot 0
	renderer.update_from(pool)
	var cur := renderer.get_current_buffer()
	var prev := renderer.get_previous_buffer()
	assert_almost_eq(cur[3], 201.0, 0.001)
	assert_almost_eq(prev[3], 200.0, 0.001, "slot 0 keeps the moved bullet's own history, not the removed one's")
	assert_almost_eq(cur[STRIDE + 3], 101.0, 0.001)
	assert_almost_eq(prev[STRIDE + 3], 100.0, 0.001)


func test_consecutive_updates_write_alternating_buffer_sets() -> void:
	_spawn(5)
	renderer.update_from(pool)
	var first := renderer.get_current_buffer()
	var first_x := first[3]
	pool.advance(0.5, Rect2(-1000, -1000, 2000, 2000))
	renderer.update_from(pool)
	assert_eq(first[3], first_x, "the buffer handed to the engine last tick is not written again")
	assert_ne(renderer.get_current_buffer()[3], first_x)


func test_cleared_pool_hides_everything() -> void:
	_spawn(50)
	renderer.update_from(pool)
	pool.clear()
	renderer.update_from(pool)
	assert_eq(renderer.multimesh.visible_instance_count, 0)


# --- no per-tick allocation (double-buffered current + previous) ---------------

func test_renderer_source_never_duplicates_buffers() -> void:
	var source := (load("res://src/bullets/bullet_renderer.gd") as GDScript).source_code
	assert_false(source.contains(".duplicate("), "update_from() must write into preallocated buffers (no per-tick copy)")


func test_previous_buffer_stays_correct_across_many_alternating_ticks() -> void:
	pool.spawn(ShotRequest.polar(Vector2(0, 0), 0.0, 600.0))
	pool.spawn(ShotRequest.polar(Vector2(0, 100), 0.0, 300.0))
	for tick in 9:
		pool.advance(1.0 / 60.0, Rect2(-1000, -1000, 2000, 2000))
		renderer.update_from(pool)
		var cur := renderer.get_current_buffer()
		var prev := renderer.get_previous_buffer()
		assert_almost_eq(cur[3], 10.0 * float(tick + 1), 0.001, "tick %d end" % tick)
		assert_almost_eq(prev[3], 10.0 * float(tick), 0.001, "tick %d start" % tick)
		assert_almost_eq(cur[STRIDE + 3], 5.0 * float(tick + 1), 0.001)
		assert_almost_eq(prev[STRIDE + 3], 5.0 * float(tick), 0.001)
		assert_almost_eq(prev[STRIDE + 7], 100.0, 0.001)
		for k: int in [0, 1, 4, 5, 8, 9, 10, 11]:
			assert_eq(prev[k], cur[k], "tick %d float %d" % [tick, k])


func test_buffers_handed_to_the_engine_are_not_rewritten_next_tick() -> void:
	_spawn(5)
	renderer.update_from(pool)
	var prev_a := renderer.get_previous_buffer()
	var held_x := prev_a[3]
	pool.advance(0.5, Rect2(-1000, -1000, 2000, 2000))
	renderer.update_from(pool)
	assert_eq(prev_a[3], held_x, "the previous-tick buffer given to the engine last tick is left alone")


func test_update_from_with_a_steady_pool_is_allocation_stable() -> void:
	_spawn(1500)
	renderer.update_from(pool)
	var reallocations := renderer.reallocations
	var size_before := renderer.get_current_buffer().size()
	for tick in 20:
		pool.advance(1.0 / 60.0, Rect2(-1000, -1000, 2000, 2000))
		renderer.update_from(pool)
	assert_eq(renderer.reallocations, reallocations)
	assert_eq(renderer.get_current_buffer().size(), size_before)
	assert_eq(renderer.get_previous_buffer().size(), size_before)
