extends GutTest
## The bullet window keeps its size and recentres on the camera.

const DT := 1.0 / 60.0
## Fixed physics ticks after the teleport. Enough that the camera is still
## easing (a settled camera would make a stale sample look correct) and few
## enough that one follow step is still several pixels.
const FOLLOW_STEPS := 8

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


## Interpolation refreshes Camera2D.get_screen_center_position() on idle, at a
## wall-clock fraction. The window is copied on the physics tick, so it has to
## follow the pose FollowCamera just wrote (position + shake offset), not that
## getter. A teleport cuts the camera, then an aim swing makes the next ticks
## ease. The centre after FOLLOW_STEPS ticks is compared to that pose.
func test_window_matches_the_physics_camera_centre_after_a_teleport() -> void:
	var interpolation: bool = ProjectSettings.get_setting("physics/common/physics_interpolation")
	assert_true(interpolation, "physics interpolation is on")
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector2.ZERO
	player.aim_direction = Vector2.RIGHT
	add_child_autofree(player)
	# Headless mouse aim would move the look-ahead every tick. Hold the pose.
	player.set_physics_process(false)
	var cam := FollowCamera.new()
	# Idle is what physics interpolation overrides, and that override is an error
	# in this project. The class sets physics mode in _init; set it here too.
	cam.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	add_child_autofree(cam)
	cam.make_current()
	cam.target = player
	assert_true(cam.is_physics_interpolated(), "the camera interpolates in this project")
	manager.bounds_center = cam
	manager.auto_step = true
	var far := Vector2(4000.0, -1200.0)
	player.teleport(far)
	var snapped := cam.global_position
	assert_eq(snapped, far + Vector2.RIGHT * cam.look_ahead, "teleport cuts the camera")
	# Not another teleport: the camera eases toward the new look-ahead.
	# Trauma makes the shake offset nonzero, so a centre that drops it fails.
	player.aim_direction = Vector2.DOWN
	cam.add_trauma(1.0)
	var goal := far + Vector2.DOWN * cam.look_ahead
	await wait_physics_frames(FOLLOW_STEPS)
	var physics_centre := cam.global_position + cam.offset
	assert_gt(cam.offset.length(), 0.5, "shake offset is part of the physics pose")
	assert_gt(physics_centre.distance_to(snapped), 1.0, "follow moved the camera off the cut")
	assert_gt(physics_centre.distance_to(goal), 1.0, "still easing, so the sample is not a settled pose")
	assert_eq(manager.world_bounds.size, Vector2(2624, 1504), "the cull margin is the window size")
	var centre := manager.world_bounds.get_center()
	assert_almost_eq(centre.x, physics_centre.x, 0.001)
	assert_almost_eq(centre.y, physics_centre.y, 0.001)


func test_recenter_keeps_walls_and_they_still_stop_bullets() -> void:
	manager.walls.add_wall(Rect2(4988, 4988, 24, 24))
	manager.recenter_world_bounds(Vector2(5000, 5000))
	assert_eq(manager.walls.wall_count, 1)
	var req := ShotRequest.polar(Vector2(4976, 5000), 0.0, 900.0)
	req.lifetime = 2.0
	manager.emitter.request_shot(req)
	manager.step(DT)
	assert_eq(manager.pool.count, 0, "the wall is still in the recentred grid")
