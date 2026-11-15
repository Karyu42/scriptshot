extends GutTest
## Time stop applied to bullets (GD and native) and to enemy / Herald timers.
## Player movement, regen and player shots stay unscaled.

const DT := 1.0 / 60.0


func before_each() -> void:
	TimeControl.cancel()
	TimeControl.set_process(false)
	Engine.time_scale = 1.0


func after_each() -> void:
	TimeControl.cancel()
	TimeControl.set_process(true)
	Engine.time_scale = 1.0


func _manager(preference: String) -> BulletManager:
	var mgr := BulletManager.new()
	mgr.backend_preference = preference
	mgr.capacity = 64
	mgr.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	mgr.render_enabled = false
	mgr.auto_step = false
	add_child_autofree(mgr)
	return mgr


func _fire(mgr: BulletManager, owner: int, pos: Vector2, vel: Vector2, pierce_invuln: bool = false) -> int:
	var req := ShotRequest.new()
	req.reset()
	req.position = pos
	req.velocity = vel
	req.lifetime = 5.0
	req.radius = 4.0
	req.owner_layer = owner
	req.hit_mask = Layers.hostile_to(owner)
	req.pierces_script_invuln = pierce_invuln
	return mgr.spawn(req)


func test_gdscript_backend_scales_enemy_and_null_but_not_player_shots() -> void:
	_assert_bullet_scales("gdscript")


func test_native_backend_matches_gdscript_bullet_scales() -> void:
	var probe := _manager("native")
	if probe.backend != "native":
		pending("native backend is not available in this tree")
		return
	_assert_bullet_scales("native")


func _assert_bullet_scales(preference: String) -> void:
	var mgr := _manager(preference)
	_fire(mgr, Layers.PLAYER, Vector2(0, 0), Vector2(600, 0))
	_fire(mgr, Layers.ENEMY, Vector2(0, 40), Vector2(600, 0))
	_fire(mgr, Layers.ENEMY, Vector2(0, 80), Vector2(600, 0), true)
	TimeControl.request(0.0, 2.0)
	for _i in 10:
		mgr.step(DT)
	# Player: full 10 * 600 / 60 = 100 px. Enemy: frozen. Null: 0.5 * 100 = 50.
	# Plain native bullets live in the sim, not the GDScript pool; snapshot
	# lists native shots first, in spawn order.
	@warning_ignore_start("unsafe_cast")
	var positions: PackedVector2Array = mgr.snapshot()["pos"]
	@warning_ignore_restore("unsafe_cast")
	assert_eq(positions.size(), 3, "%s three live shots" % preference)
	assert_almost_eq(positions[0].x, 100.0, 0.05, "%s player shot unscaled" % preference)
	assert_almost_eq(positions[1].x, 0.0, 0.05, "%s enemy shot frozen at scale 0" % preference)
	assert_almost_eq(positions[2].x, 50.0, 0.05, "%s Null shot at max(0, 0.5)" % preference)


func test_enemy_movement_freezes_while_the_player_still_moves() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	# Outside WorldGen.SAFE_RADIUS so a zero-length chase step is not pushed
	# out of the spawn disk (that push does not use delta).
	player.global_position = Vector2(2000, 0)
	player.aim_direction = Vector2.RIGHT
	player.set_physics_process(false)
	var enemy: RegularEnemy = (load("res://scenes/regular_enemy.tscn") as PackedScene).instantiate()
	add_child_autofree(enemy)
	enemy.player = player
	enemy.global_position = Vector2(2400, 0)
	enemy.woken = true
	enemy.set_physics_process(false)
	TimeControl.request(0.0, 2.0)
	var enemy_start := enemy.global_position
	var player_start := player.global_position
	assert_true(player.try_dash(Vector2.RIGHT))
	for _i in 10:
		player._physics_process(DT)
		enemy._physics_process(DT)
	assert_gt(player.global_position.x - player_start.x, 50.0, "player dash still moves")
	assert_almost_eq(enemy.global_position.x, enemy_start.x, 0.05, "enemy frozen")


func test_player_regen_is_not_scaled() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	player.health.hp = 1.0
	player.health.regen_delay = 0.0
	player.health.regen_interval = 0.2
	player.health.regen_amount = 1.0
	TimeControl.request(0.0, 2.0)
	player.health.tick(0.25)
	assert_gt(player.health.hp, 1.0)


func test_herald_timer_is_scaled() -> void:
	var director := HeraldDirector.new()
	add_child_autofree(director)
	director.set_physics_process(false)
	director.delay = 1.0
	director.counting = true
	TimeControl.request(0.0, 2.0)
	director._physics_process(1.0)
	assert_eq(director.elapsed, 0.0, "Herald clock frozen at scale 0")
	TimeControl.cancel()
	director._physics_process(1.0)
	assert_almost_eq(director.elapsed, 1.0, 0.0001)


func test_null_telegraph_uses_the_floor_while_the_caster_freezes() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	player.global_position = Vector2(100, 0)
	player.set_physics_process(false)
	var sniper: Sniper = (load("res://scenes/sniper.tscn") as PackedScene).instantiate()
	add_child_autofree(sniper)
	sniper.player = player
	sniper.global_position = Vector2.ZERO
	sniper.woken = true
	sniper.telegraph_time_scale_floor = TimeControl.NULL_TIME_SCALE_FLOOR
	sniper.time_scale_floor = 0.0
	sniper.set_physics_process(false)
	sniper._lock = player.global_position
	sniper._windup = sniper.WINDUP
	TimeControl.request(0.0, 2.0)
	var start := sniper.global_position
	for _i in 24:
		sniper._physics_process(DT)
	assert_almost_eq(sniper.global_position.x, start.x, 0.05)
	assert_almost_eq(sniper._windup, sniper.WINDUP - 0.4 * 0.5, 0.02)
