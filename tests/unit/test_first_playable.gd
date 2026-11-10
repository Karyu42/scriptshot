extends GutTest
## L0/L1 on scenes/main.tscn: safe zone, three targets, hostiles you can kill.

const _SAVE := "user://gut_first_playable.cfg"
## Fixed physics step. The probe must not depend on the live frame clock.
const _STEP := 1.0 / 60.0
## First regular already overlaps a later body (a swarmer 6 px away). A pierce-0
## bullet at that point hits the neighbour and this body stays at 6 hp.
const _OVERLAP_SEED := 1053


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
	# Teleport snaps the follow camera, then each physics tick eases it toward
	# aim look-ahead (rate 8). The bullet window copies get_screen_center_position()
	# on that tick, but the getter is the physics-interpolated centre and the
	# fraction is wall-clock, so after wait_physics_frames(2) the rect and the
	# getter can sit a fraction of one follow step apart. macOS missed by 1.33 px.
	# Publish the snapped centre and copy it with one fixed step instead.
	cam.force_update_scroll()
	bullets.step(_STEP)
	assert_eq(bullets.world_bounds.size, Vector2(2624, 1504))
	var centre := bullets.world_bounds.get_center()
	var screen := cam.get_screen_center_position()
	assert_almost_eq(centre.x, screen.x, 1.0)
	assert_almost_eq(centre.y, screen.y, 1.0)


func test_a_regular_dies_to_the_bullet_manager() -> void:
	# A fresh save rolls world_seed with randi(). On some seeds the first regular
	# already overlaps a later body, and a pierce-0 bullet is consumed by
	# whichever hurtbox the spatial hash visits first. Seed 1053 is one of
	# those: the probe hits the neighbour and this swarmer stays at 6. Other
	# hurtboxes are turned off, and the manager is stepped with a fixed delta
	# instead of the live physics clock or the camera window.
	var main := _open_seeded_main(_OVERLAP_SEED)
	add_child_autofree(main)
	var bullets := main.get_node("BulletManager") as BulletManager
	bullets.auto_step = false
	bullets.bounds_center = null
	var enemy := _first_regular(main)
	assert_not_null(enemy, "a regular body is in the ring")
	_silence_other_hurtboxes(enemy)
	bullets.recenter_world_bounds(enemy.global_position)
	var hp := enemy.health.hp
	assert_true(bullets.emitter.request_shot(_still_shot(enemy.global_position, 1.0)))
	bullets.step(_STEP)
	assert_true(is_instance_valid(enemy))
	assert_almost_eq(enemy.health.hp, hp - 1.0, 0.01)
	assert_true(bullets.emitter.request_shot(_still_shot(enemy.global_position, 30.0)))
	bullets.step(_STEP)
	assert_false(is_instance_valid(enemy) and enemy.is_alive())
	# The killing hit queue_frees the body from inside step(). This test does
	# not await, so that free is still pending when GUT free()s the scene.
	# On the Windows native run that dangling delete-queue id survives until
	# process exit and segfaults (exit 139) after the suite has already passed.
	# Empty the pool, queue the scene, and let the frame flush both.
	bullets.clear_bullets()
	main.queue_free()
	await wait_physics_frames(1)


func _open_main() -> Main:
	# The previous test's scene frees after after_each and writes this path.
	_discard_save(_SAVE)
	return _main_with_save(_SAVE)


func _open_seeded_main(world_seed: int) -> Main:
	_discard_save(_SAVE)
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", world_seed)
	var err := cfg.save(_SAVE)
	assert_eq(err, OK, "overlap seed could not be written")
	return _main_with_save(_SAVE)


func _main_with_save(path: String) -> Main:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = path
	return main


func _first_regular(main: Main) -> RegularEnemy:
	for node: Node in main.get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var body := node as RegularEnemy
		if body == null or not body.is_alive() or body is EliteEnemy:
			continue
		body.set_physics_process(false)
		return body
	return null


## One stationary bullet. Pierce stays 0: the body under test is the only live target.
func _still_shot(at: Vector2, damage: float) -> ShotRequest:
	var req := ShotRequest.polar(at, 0.0, 0.0)
	req.damage = damage
	req.owner_layer = Layers.PLAYER
	req.hit_mask = Layers.ENEMY
	req.lifetime = 2.0
	return req


func _silence_other_hurtboxes(keep: RegularEnemy) -> void:
	for node: Node in keep.get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var body := node as RegularEnemy
		if body == null:
			continue
		body.set_physics_process(false)
		if body == keep:
			continue
		var hurtbox := body.get_node_or_null("Hurtbox") as Hurtbox
		if hurtbox != null:
			hurtbox.active = false


func _discard_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
