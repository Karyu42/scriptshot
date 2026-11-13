extends GutTest
## HurtboxGrid.query_radius(): every target on the mask whose circle overlaps
## the query circle, across every cell the circle covers (query_circle only
## looks at the cell under the point).

var grid: HurtboxGrid
var _refs: Array[RefCounted] = []


func before_each() -> void:
	grid = HurtboxGrid.new(Rect2(-512, -512, 1024, 1024), 64.0)
	grid.begin(0.0)
	_refs.clear()


func _add(at: Vector2, r: float, layer: int = Layers.ENEMY) -> RefCounted:
	var ref := RefCounted.new()
	_refs.append(ref)
	grid.add_circle(at, r, layer, ref)
	return ref


func _is(got: Array, i: int, ref: Object) -> bool:
	var o: Object = got[i]
	return o == ref


func test_finds_targets_in_cells_other_than_the_centre_cell() -> void:
	var far := _add(Vector2(200, 0), 10.0)
	assert_eq(grid.query_circle(Vector2.ZERO, 200.0, Layers.ENEMY), -1, "query_circle misses it")
	var got := grid.query_radius(Vector2.ZERO, 200.0, Layers.ENEMY)
	assert_eq(got.size(), 1)
	assert_true(_is(got, 0, far))


func test_overlap_is_circle_against_circle_and_touching_counts() -> void:
	var touch := _add(Vector2(150, 0), 50.0)
	_add(Vector2(151, 0), 50.0 - 1.5)
	var got := grid.query_radius(Vector2.ZERO, 100.0, Layers.ENEMY)
	assert_eq(got.size(), 1)
	assert_true(_is(got, 0, touch))
	# Diagonal: inside the bounding square of the query, outside its circle.
	_add(Vector2(90, 90), 1.0)
	assert_eq(grid.query_radius(Vector2.ZERO, 100.0, Layers.ENEMY).size(), 1)


func test_each_target_once_in_add_order_and_masked_by_layer() -> void:
	var big := _add(Vector2(0, 0), 150.0)  # spans many cells
	var small := _add(Vector2(-40, 30), 5.0)
	_add(Vector2(10, 10), 5.0, Layers.PLAYER)
	var got := grid.query_radius(Vector2(0, 0), 120.0, Layers.ENEMY)
	assert_eq(got.size(), 2)
	assert_true(_is(got, 0, big))
	assert_true(_is(got, 1, small))
	assert_eq(grid.query_radius(Vector2(0, 0), 120.0, Layers.PLAYER).size(), 1)
	assert_eq(grid.query_radius(Vector2(0, 0), 120.0, Layers.PLAYER | Layers.ENEMY).size(), 3)


func test_a_huge_radius_covers_the_whole_window_and_bad_input_is_empty() -> void:
	_add(Vector2(-500, -500), 4.0)
	_add(Vector2(500, 500), 4.0)
	assert_eq(grid.query_radius(Vector2.ZERO, INF, Layers.ENEMY).size(), 2)
	assert_eq(grid.query_radius(Vector2.ZERO, -1.0, Layers.ENEMY).size(), 0)
	assert_eq(grid.query_radius(Vector2.ZERO, NAN, Layers.ENEMY).size(), 0)
	assert_eq(grid.query_radius(Vector2(NAN, 0), 10.0, Layers.ENEMY).size(), 0)


func test_empty_grid_and_refless_targets() -> void:
	assert_eq(grid.query_radius(Vector2.ZERO, 100.0, Layers.ENEMY).size(), 0)
	grid.add_circle(Vector2(5, 0), 4.0, Layers.ENEMY, null)
	assert_eq(grid.query_radius(Vector2.ZERO, 100.0, Layers.ENEMY).size(), 0, "no ref, nothing to hand back")


func test_a_new_tick_empties_it() -> void:
	_add(Vector2(5, 0), 4.0)
	grid.begin(0.0)
	assert_eq(grid.query_radius(Vector2.ZERO, 100.0, Layers.ENEMY).size(), 0)


func test_manager_grid_sees_live_hurtboxes() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 16
	manager.render_enabled = false
	manager.auto_step = false
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	add_child_autofree(manager)
	var hb := Hurtbox.new()
	hb.radius = 12.0
	hb.layer = Layers.ENEMY
	hb.position = Vector2(300, 0)
	add_child_autofree(hb)
	manager.step(1.0 / 60.0)
	var got := manager.grid.query_radius(Vector2.ZERO, 290.0, Layers.ENEMY)
	assert_eq(got.size(), 1)
	assert_true(_is(got, 0, hb))
