extends GutTest
## Smoke test for the playable sandbox: the scene loads, input moves the player,
## holding fire spawns bullets through the emitter, and the stress toggle works.

var main: Node2D


func before_each() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child_autofree(main)
	await wait_physics_frames(2)


func after_each() -> void:
	Input.action_release("move_right")
	Input.action_release("fire")
	Input.action_release("move_left")


func test_scene_wires_player_to_bullet_emitter() -> void:
	var player: Player = main.get_node("Player")
	var bullets: BulletManager = main.get_node("BulletManager")
	assert_not_null(player.emitter)
	assert_eq(player.emitter, bullets.emitter)


func test_move_input_accelerates_player() -> void:
	var player: Player = main.get_node("Player")
	var start := player.global_position
	Input.action_press("move_right")
	await wait_physics_frames(10)
	assert_gt(player.global_position.x, start.x + 5.0)
	assert_gt(player.velocity.x, 0.0)
	assert_lte(player.velocity.length(), player.max_speed + 0.01)


func test_holding_fire_spawns_bullets_at_weapon_rate() -> void:
	var bullets: BulletManager = main.get_node("BulletManager")
	assert_eq(bullets.pool.count, 0)
	Input.action_press("fire")
	await wait_physics_frames(30)
	# 30 ticks = 0.5 s at 0.11 s interval -> ~5 shots.
	assert_between(bullets.pool.spawned_total, 4, 6)


func test_player_bullets_only_target_enemies() -> void:
	var bullets: BulletManager = main.get_node("BulletManager")
	Input.action_press("fire")
	await wait_physics_frames(5)
	assert_gt(bullets.pool.count, 0)
	assert_eq(bullets.pool.hit_mask[0], Layers.ENEMY)


func test_stress_toggle_fills_pool_toward_target() -> void:
	var stress: BulletStressTest = main.get_node("StressTest")
	var bullets: BulletManager = main.get_node("BulletManager")
	stress.level = 0
	stress.set_enabled(true)
	await wait_physics_frames(60 * 5)
	assert_between(bullets.pool.count, 1500, 2600)
	stress.set_enabled(false)
