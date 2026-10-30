class_name TestbedField
extends Node2D
## Phone / perf test harness field. Same world and spawner as tests/benchmark/bullet_benchmark.gd
## (arena, 28 walls, 32 hurtboxes, steady-state top-up, 10 % fast bullets), but running the real
## game path: BulletManager steps in _physics_process (60 Hz) with MultiMesh physics interpolation,
## and the whole thing is rendered every frame. Test harness only: not game code.

const ARENA := Rect2(-1280, -720, 2560, 1440)
const TARGET_COUNT := 32
const WALL_THICKNESS := 64.0
const FAST_FRACTION := 0.1

var cfg: Dictionary
var manager: BulletManager
var overlay: TestbedOverlay
var driver: TestbedLuaDriver
var camera: Camera2D

var _rng := RandomNumberGenerator.new()
var _request := ShotRequest.new()
var _walls: Array[Rect2] = []
var _pre_usec := 0
var _have_prev := false
var _target := 0
var _scripted := false
var _started_msec := 0
var _shot_done := false
var _hurtbox_pos: Array[Vector2] = []


func _ready() -> void:
	cfg = TestbedState.SCENES[TestbedState.current]
	_target = cfg.bullets
	_rng.seed = 20260101
	manager = BulletManager.new()
	manager.capacity = 32768
	manager.world_bounds = ARENA.grow(32.0)
	manager.cell_size = 64.0
	add_child(manager)
	_build_walls()
	for i in TARGET_COUNT:
		var hb := Hurtbox.new()
		hb.radius = 24.0
		hb.layer = Layers.ENEMY
		hb.position = Vector2(_rng.randf_range(ARENA.position.x, ARENA.end.x), _rng.randf_range(ARENA.position.y, ARENA.end.y))
		_hurtbox_pos.append(hb.position)
		add_child(hb)
	camera = Camera2D.new()
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	add_child(camera)
	camera.make_current()

	overlay = TestbedOverlay.new()
	overlay.scene_id = TestbedState.current
	overlay.title = cfg.title
	add_child(overlay)
	overlay.back_pressed.connect(_back_to_menu)

	var lua_mode: String = cfg.lua
	if lua_mode != "":
		if not TestbedLuaDriver.is_available():
			overlay.title = "LUA UNAVAILABLE: lua-gdextension did not load (%s)" % cfg.title
			print("SPIKE_ERROR lua-gdextension not loaded (ClassDB has no LuaState)")
		else:
			driver = TestbedLuaDriver.new()
			if driver.setup(manager, lua_mode):
				_scripted = true
				overlay.has_lua = true
				overlay.extra = {"lua_version": driver.version_string(), "lua_mode": lua_mode}
			else:
				overlay.title = "LUA ERROR: %s" % driver.last_error
				print("SPIKE_ERROR ", driver.last_error)
				driver = null
	print("SPIKE_INFO scene=%s godot=%s os=%s model=%s renderer=%s/%s/%s lua=%s" % [
		TestbedState.current, Engine.get_version_info().string, OS.get_name(), OS.get_model_name(),
		RenderingServer.get_current_rendering_method(), RenderingServer.get_current_rendering_driver_name(),
		RenderingServer.get_video_adapter_name(), overlay.extra])
	_started_msec = Time.get_ticks_msec()
	_fit_camera()
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_back_to_menu()
	elif what == NOTIFICATION_WM_SIZE_CHANGED:
		_fit_camera()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_back_to_menu()


func _back_to_menu() -> void:
	get_tree().change_scene_to_file("res://testbed/launcher.tscn")


func _fit_camera() -> void:
	if camera == null:
		return
	var vp := get_viewport_rect().size
	var area := ARENA.grow(WALL_THICKNESS + 16.0).size
	var z := minf(vp.x / area.x, vp.y / area.y)
	camera.zoom = Vector2(z, z)
	camera.position = ARENA.get_center()


func _physics_process(delta: float) -> void:
	# Runs before BulletManager (priority 100), so everything spawned or steered here is
	# integrated and drawn on this same tick.
	if _have_prev:
		overlay.sim_ms.push((_pre_usec + manager.last_step_usec) / 1000.0)
		if driver != null:
			overlay.lua_ms.push(driver.last_lua_usec / 1000.0)
	var t0 := Time.get_ticks_usec()
	if driver != null:
		driver.pre_step(delta)
	var scripted := _top_up()
	_pre_usec = Time.get_ticks_usec() - t0
	_have_prev = true
	overlay.live = {"bullets": manager.pool.count, "scripted": scripted}
	if TestbedState.shot_path != "" and not _shot_done and (Time.get_ticks_msec() - _started_msec) > 3500:
		_shot_done = true
		get_viewport().get_texture().get_image().save_png(TestbedState.shot_path)
	if TestbedState.auto_seconds > 0.0 and (Time.get_ticks_msec() - _started_msec) / 1000.0 >= TestbedState.auto_seconds:
		print("SPIKE_DONE")
		get_tree().quit(0)


func _top_up() -> int:
	var pool := manager.pool
	var have := driver.scripted_count() if _scripted else pool.count
	# Scripted scenes keep `_target` scripted bullets alive (script trail bullets are extra);
	# plain scenes keep `_target` bullets alive, as the benchmark does.
	while have < _target:
		_request.reset()
		var spawn_at := Vector2.ZERO
		for _attempt in 8:
			spawn_at = Vector2(_rng.randf_range(ARENA.position.x, ARENA.end.x), _rng.randf_range(ARENA.position.y, ARENA.end.y))
			if not _inside_wall(spawn_at):
				break
		_request.position = spawn_at
		var speed := _rng.randf_range(1500.0, 2500.0) if _rng.randf() < FAST_FRACTION else _rng.randf_range(80.0, 320.0)
		_request.velocity = Vector2.from_angle(_rng.randf() * TAU) * speed
		_request.lifetime = _rng.randf_range(2.0, 6.0)
		_request.radius = 3.0
		_request.hit_mask = Layers.ENEMY
		if _scripted:
			_request.behavior_id = driver.behavior_id
			_request.param_a = _rng.randf() * TAU
			_request.color = Color("7bdff2")
		if not manager.emitter.request_shot(_request):
			break
		have += 1
	return have if _scripted else 0


func _build_walls() -> void:
	var t := WALL_THICKNESS
	_walls.append(Rect2(ARENA.position.x - t, ARENA.position.y - t, ARENA.size.x + 2.0 * t, t))
	_walls.append(Rect2(ARENA.position.x - t, ARENA.end.y, ARENA.size.x + 2.0 * t, t))
	_walls.append(Rect2(ARENA.position.x - t, ARENA.position.y, t, ARENA.size.y))
	_walls.append(Rect2(ARENA.end.x, ARENA.position.y, t, ARENA.size.y))
	for gx in 6:
		for gy in 4:
			var centre := Vector2(
				ARENA.position.x + ARENA.size.x * (float(gx) + 0.5) / 6.0,
				ARENA.position.y + ARENA.size.y * (float(gy) + 0.5) / 4.0)
			var size := Vector2(140.0, 36.0) if (gx + gy) % 2 == 0 else Vector2(36.0, 140.0)
			_walls.append(Rect2(centre - size * 0.5, size))
	for wall in _walls:
		manager.add_wall(wall)


func _inside_wall(p: Vector2) -> bool:
	for wall in _walls:
		if wall.grow(4.0).has_point(p):
			return true
	return false


func _draw() -> void:
	draw_rect(ARENA, Color("171a21"))
	draw_rect(ARENA, Color("3a4152"), false, 4.0)
	for wall in _walls:
		draw_rect(wall, Color("2b3140"))
		draw_rect(wall, Color("4a536a"), false, 2.0)
	for p in _hurtbox_pos:
		draw_circle(p, 24.0, Color("5a2a2a"))
