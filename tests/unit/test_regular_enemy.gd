extends GutTest
## Wake threshold, contact damage, i-frames, and bullet death for T0 regulars.

const DT := 1.0 / 60.0
const FAR := Vector2(3000, 3000)


func before_each() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	Input.action_release("move_up")
	Input.action_release("move_down")
	Input.action_release("fire")


func test_idle_at_701_and_chase_at_699() -> void:
	var player := _player(FAR + Vector2(701, 0))
	var drifter := _enemy(FAR, RegularEnemy.ARCH_DRIFTER, player)
	await wait_physics_frames(1)
	assert_false(drifter.woken)
	var idle_step := drifter.global_position - FAR
	assert_lt(idle_step.length(), 1.2, "one tick of idle drift, not a chase")
	player.global_position = drifter.global_position + Vector2(699, 0)
	var before := drifter.global_position
	await wait_physics_frames(30)
	assert_true(drifter.woken)
	# The player is still and stands to the right. 30 ticks at 90 px/s is about 45 px;
	# idle drift at 40 px/s would be about 20.
	var gained := drifter.global_position.x - before.x
	assert_gt(gained, 28.0)

	var player2 := _player(FAR + Vector2(0, 2500))
	var swarmer := _enemy(FAR + Vector2(0, 1800), RegularEnemy.ARCH_SWARMER, player2)
	# 701 px above the swarmer.
	player2.global_position = swarmer.global_position + Vector2(0, -701)
	await wait_physics_frames(1)
	assert_false(swarmer.woken)
	player2.global_position = swarmer.global_position + Vector2(0, -699)
	var sy := swarmer.global_position.y
	await wait_physics_frames(30)
	assert_true(swarmer.woken)
	assert_lt(swarmer.global_position.y, sy - 20.0, "erratic chase still closes on the player")


func test_contact_deals_1_then_nothing_during_iframes() -> void:
	var player := _player(FAR)
	var enemy := _enemy(FAR + Vector2(20, 0), RegularEnemy.ARCH_DRIFTER, player)
	var blocked: Array[int] = []
	player.health.damage_blocked.connect(func(_amount: float, result: int) -> void:
		blocked.append(result)
	)
	await wait_physics_frames(1)
	assert_eq(player.health.hp, 4.0)
	assert_almost_eq(player.health.engine_invulnerable_left, 0.75, 0.05)
	await wait_physics_frames(10)
	assert_eq(player.health.hp, 4.0, "i-frames block the rest of the overlap")
	assert_gt(blocked.size(), 0)
	assert_eq(blocked[0], Health.DamageResult.BLOCKED_ENGINE)


func test_script_invulnerability_blocks_contact() -> void:
	var player := _player(FAR)
	player.health.set_invulnerable(true)
	var blocked: Array[int] = []
	player.health.damage_blocked.connect(func(_amount: float, result: int) -> void:
		blocked.append(result)
	)
	_enemy(FAR + Vector2(10, 0), RegularEnemy.ARCH_SWARMER, player)
	await wait_physics_frames(3)
	assert_eq(player.health.hp, 5.0)
	assert_gt(blocked.size(), 0)
	assert_eq(blocked[0], Health.DamageResult.BLOCKED_SCRIPT)
	assert_false(player.health.is_engine_invulnerable())


func test_bullets_damage_and_kill_through_health() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.world_bounds = Rect2(-5000, -5000, 10000, 10000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var player := _player(FAR)
	var enemy := _enemy(FAR, RegularEnemy.ARCH_DRIFTER, player)
	assert_eq(enemy.health.hp, RegularEnemy.DRIFTER_HP)
	assert_eq(enemy.body_radius, RegularEnemy.DRIFTER_RADIUS)
	_shot(manager, enemy.global_position, 1.0)
	manager.step(DT)
	assert_eq(enemy.health.hp, RegularEnemy.DRIFTER_HP - 1.0)
	assert_true(enemy.is_alive())
	_shot(manager, enemy.global_position, 100.0)
	manager.step(DT)
	assert_false(enemy.is_alive())

	var swarmer := _enemy(FAR + Vector2(400, 0), RegularEnemy.ARCH_SWARMER, player)
	assert_eq(swarmer.health.hp, RegularEnemy.SWARMER_HP)
	assert_eq(swarmer.body_radius, RegularEnemy.SWARMER_RADIUS)
	_shot(manager, swarmer.global_position, RegularEnemy.SWARMER_HP)
	manager.step(DT)
	assert_false(swarmer.is_alive())


func test_bodies_do_not_overlap_the_safe_disk() -> void:
	var drifter := RegularEnemy.spawn_position(Vector2(512, 0), RegularEnemy.ARCH_DRIFTER, 0, 1)
	assert_almost_eq(drifter.x, WorldGen.SAFE_RADIUS + RegularEnemy.DRIFTER_RADIUS, 0.01)
	assert_gte(drifter.length() - RegularEnemy.DRIFTER_RADIUS, WorldGen.SAFE_RADIUS - 0.01)
	var swarmer := RegularEnemy.spawn_position(Vector2(512, 0), RegularEnemy.ARCH_SWARMER, 0, 1)
	assert_almost_eq(swarmer.x, WorldGen.SAFE_RADIUS + RegularEnemy.SWARMER_RADIUS, 0.01)
	# The old rim (centre on 512) overlaps the disk. With the player inside,
	# chase holds the body tangent to it and deals no contact damage.
	var player := _player(Vector2(500, 0))
	var enemy := _enemy(Vector2(512, 0), RegularEnemy.ARCH_DRIFTER, player)
	await wait_physics_frames(5)
	assert_gte(enemy.global_position.length() - enemy.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	assert_eq(player.health.hp, player.health.max_hp)


func test_no_contact_damage_with_the_player_on_the_safe_rim() -> void:
	var player := _player(Vector2(WorldGen.SAFE_RADIUS, 0.0))
	_enemy(Vector2(WorldGen.SAFE_RADIUS + RegularEnemy.DRIFTER_RADIUS, 0.0), RegularEnemy.ARCH_DRIFTER, player)
	await wait_physics_frames(5)
	assert_eq(player.global_position.length(), WorldGen.SAFE_RADIUS)
	assert_eq(player.health.hp, player.health.max_hp)
	assert_false(player.health.is_engine_invulnerable())


func test_contact_damage_just_outside_the_safe_disk() -> void:
	var player := _player(Vector2(512.5, 0.0))
	_enemy(Vector2(512.5 + RegularEnemy.DRIFTER_RADIUS, 0.0), RegularEnemy.ARCH_DRIFTER, player)
	await wait_physics_frames(2)
	assert_gt(player.global_position.length(), WorldGen.SAFE_RADIUS)
	assert_eq(player.health.hp, player.health.max_hp - 1.0)
	assert_true(player.health.is_engine_invulnerable())


func _player(at: Vector2) -> Player:
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = at
	add_child_autofree(player)
	return player


func _enemy(at: Vector2, archetype: StringName, player: Node2D) -> RegularEnemy:
	var enemy := (preload("res://scenes/regular_enemy.tscn") as PackedScene).instantiate() as RegularEnemy
	enemy.configure(archetype, at, at, 1, Vector2i(2, 2), 0, 0, player)
	add_child_autofree(enemy)
	return enemy


func _shot(manager: BulletManager, at: Vector2, damage: float) -> void:
	var req := ShotRequest.polar(at, 0.0, 0.0)
	req.damage = damage
	req.owner_layer = Layers.PLAYER
	req.hit_mask = Layers.ENEMY
	req.lifetime = 5.0
	manager.emitter.request_shot(req)
