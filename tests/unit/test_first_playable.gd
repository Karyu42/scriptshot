extends GutTest
## L0/L1 on scenes/main.tscn: safe zone, three targets, hostiles you can kill.

const _SAVE := "user://gut_first_playable.cfg"


func before_each() -> void:
	Input.action_release("fire")
	Input.action_release("move_right")


func after_each() -> void:
	_discard_save(_SAVE)


func after_all() -> void:
	_discard_save(_SAVE)


func test_cold_start_safe_zone_and_three_targets() -> void:
	var main := _open_main()
	add_child_autofree(main)
	var dummies := main.get_node("Dummies").get_children()
	assert_eq(dummies.size(), 3)
	var expected: Array[Vector2] = [Vector2(300, 0), Vector2(-150, 260), Vector2(-150, -260)]
	for i in 3:
		var dummy := dummies[i] as TrainingDummy
		assert_not_null(dummy)
		assert_almost_eq(dummy.global_position.x, expected[i].x, 0.1)
		assert_almost_eq(dummy.global_position.y, expected[i].y, 0.1)
		assert_almost_eq(dummy.global_position.length(), 300.0, 1.0)
		assert_eq(dummy.max_health, 40.0)
		assert_eq(dummy.body_radius, 22.0)
		assert_false(dummy.is_in_group(RegularEnemy.GROUP))
	var hostiles := main.get_tree().get_nodes_in_group(RegularEnemy.GROUP)
	assert_gt(hostiles.size(), 0, "T0 regulars spawned around the origin")
	for node: Node in hostiles:
		var body := node as RegularEnemy
		assert_not_null(body)
		assert_gte(body.global_position.length() - body.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	var herald := main.get_node("HeraldArm") as HeraldArm
	assert_false(herald.armed)
	var bullets := main.get_node("BulletManager") as BulletManager
	assert_eq(bullets.world_bounds.size, Vector2(2624, 1504))


func test_targets_die_respawn_and_never_deal_contact_damage() -> void:
	var main := _open_main()
	add_child_autofree(main)
	var player := main.get_node("Player") as Player
	var dummy := main.get_node("Dummies/Target0") as TrainingDummy
	player.global_position = dummy.global_position
	await wait_physics_frames(5)
	assert_eq(player.health.hp, player.health.max_hp, "tutorial targets are not hostile")
	(dummy.get_node("Hurtbox") as Hurtbox).receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
	assert_eq(dummy.health, 0.0)
	assert_false(dummy.visible)
	dummy._process(dummy.respawn_delay + 0.1)
	assert_eq(dummy.health, dummy.max_health)
	assert_true(dummy.visible)
	assert_eq(player.health.hp, player.health.max_hp)


func test_leaving_the_safe_zone_arms_the_herald_and_the_window_follows() -> void:
	var main := _open_main()
	add_child_autofree(main)
	var player := main.get_node("Player") as Player
	var herald := main.get_node("HeraldArm") as HeraldArm
	var bullets := main.get_node("BulletManager") as BulletManager
	var cam := main.get_node("FollowCamera") as Camera2D
	watch_signals(herald)
	player.teleport(Vector2(600, 0))
	await wait_physics_frames(2)
	assert_true(herald.armed)
	assert_eq(herald.arm_reason, HeraldArm.REASON_LEFT)
	assert_signal_emit_count(herald, "herald_armed", 1)
	player.teleport(Vector2.ZERO)
	await wait_physics_frames(2)
	assert_signal_emit_count(herald, "herald_armed", 1, "walking back does not arm again")
	player.teleport(Vector2(4000, -1200))
	await wait_physics_frames(2)
	assert_eq(bullets.world_bounds.size, Vector2(2624, 1504))
	var centre := bullets.world_bounds.get_center()
	var screen := cam.get_screen_center_position()
	assert_almost_eq(centre.x, screen.x, 1.0)
	assert_almost_eq(centre.y, screen.y, 1.0)


func test_a_regular_dies_to_the_bullet_manager() -> void:
	var main := _open_main()
	add_child_autofree(main)
	var player := main.get_node("Player") as Player
	var bullets := main.get_node("BulletManager") as BulletManager
	var hostiles := main.get_tree().get_nodes_in_group(RegularEnemy.GROUP)
	var enemy := hostiles[0] as RegularEnemy
	player.teleport(enemy.global_position + Vector2(-80, 0))
	await wait_physics_frames(2)
	var hp := enemy.health.hp
	var req := ShotRequest.polar(enemy.global_position, 0.0, 0.0)
	req.damage = 1.0
	req.owner_layer = Layers.PLAYER
	req.hit_mask = Layers.ENEMY
	req.lifetime = 2.0
	bullets.emitter.request_shot(req)
	await wait_physics_frames(2)
	assert_true(is_instance_valid(enemy))
	assert_almost_eq(enemy.health.hp, hp - 1.0, 0.01)
	# A woken pack stacks, so the killing shot pierces the bodies on that point.
	var lethal := ShotRequest.polar(enemy.global_position, 0.0, 0.0)
	lethal.damage = 30.0
	lethal.pierce = 16
	lethal.owner_layer = Layers.PLAYER
	lethal.hit_mask = Layers.ENEMY
	lethal.lifetime = 2.0
	assert_true(bullets.emitter.request_shot(lethal))
	await wait_physics_frames(2)
	assert_false(is_instance_valid(enemy) and enemy.is_alive())


func _open_main() -> Main:
	# The previous test's scene frees after after_each and writes this path.
	_discard_save(_SAVE)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = _SAVE
	return main


func _discard_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
