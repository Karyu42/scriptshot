extends GutTest
## The bullet window keeps its size and recentres on the camera.

const DT := 1.0 / 60.0

var manager: BulletManager


func before_each() -> void:
	manager = BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 64
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func test_recenter_keeps_the_size_and_hits_still_land() -> void:
	var size := manager.world_bounds.size
	assert_eq(size, Vector2(2624, 1504))
	manager.recenter_world_bounds(Vector2(8000, -3000))
	assert_eq(manager.world_bounds.size, size)
	assert_almost_eq(manager.world_bounds.get_center().x, 8000.0, 0.01)
	assert_almost_eq(manager.world_bounds.get_center().y, -3000.0, 0.01)
	var box := Hurtbox.new()
	box.radius = 20.0
	box.layer = Layers.ENEMY
	box.position = Vector2(8000, -3000)
	add_child_autofree(box)
	var req := ShotRequest.polar(box.global_position, 0.0, 0.0)
	req.hit_mask = Layers.ENEMY
	req.lifetime = 2.0
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_eq(manager.last_hit_count, 1)
	# A null follow target does not drag the rect back.
	manager.step(DT)
	assert_almost_eq(manager.world_bounds.get_center().x, 8000.0, 0.01)


func test_follow_uses_the_camera_centre() -> void:
	var cam := Camera2D.new()
	# Physics interpolation forces this mode; setting it first avoids the override error.
	cam.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	cam.position = Vector2(4000, 1000)
	add_child_autofree(cam)
	manager.bounds_center = cam
	manager.step(DT)
	var centre := cam.get_screen_center_position()
	assert_eq(manager.world_bounds.size, Vector2(2624, 1504))
	assert_almost_eq(manager.world_bounds.get_center().x, centre.x, 0.5)
	assert_almost_eq(manager.world_bounds.get_center().y, centre.y, 0.5)


func test_recenter_keeps_walls_and_they_still_stop_bullets() -> void:
	manager.walls.add_wall(Rect2(4988, 4988, 24, 24))
	manager.recenter_world_bounds(Vector2(5000, 5000))
	assert_eq(manager.walls.wall_count, 1)
	var req := ShotRequest.polar(Vector2(4976, 5000), 0.0, 900.0)
	req.lifetime = 2.0
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_eq(manager.pool.count, 0, "the wall is still in the recentred grid")
