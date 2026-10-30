extends GutTest
## The decided combat rules end to end on the Main scene: damage, i-frames, regen,
## death + respawn that keeps everything, own bullets harmless, reflect.

const DT := 1.0 / 60.0

var main: Main
var player: Player
var bullets: BulletManager


func before_each() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	add_child_autofree(main)
	for turret: Turret in main.get_node("Turrets").get_children():
		turret.emitter = null
	player = main.get_node("Player")
	bullets = main.get_node("BulletManager")
	main.respawn_delay = 0.2
	RespawnPoints.reset()
	await wait_physics_frames(2)


func after_each() -> void:
	RespawnPoints.reset()


func _enemy_bullet(at: Vector2, dmg: float = 1.0) -> int:
	var r := ShotRequest.polar(at, 0.0, 0.0)
	r.owner_layer = Layers.ENEMY
	r.hit_mask = Layers.PLAYER
	r.damage = dmg
	r.lifetime = 30.0
	return bullets.emitter.request_shot_id(r)


func test_player_uses_the_decided_numbers() -> void:
	assert_eq(player.health.max_hp, 5.0)
	assert_eq(player.health.invulnerability_time, 0.75)
	assert_eq(player.health.regen_delay, 5.0)
	assert_eq(player.health.regen_interval, 3.0)
	assert_eq(player.health.regen_amount, 1.0)


func test_a_hit_gives_three_quarters_of_a_second_of_iframes() -> void:
	_enemy_bullet(player.global_position)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, 4.0)
	assert_almost_eq(player.health.engine_invulnerable_left, 0.75, 0.05)


func test_regeneration_ticks_on_the_live_player() -> void:
	player.health.regen_delay = 0.2
	player.health.regen_interval = 0.1
	player.health.invulnerability_time = 0.0
	_enemy_bullet(player.global_position, 3.0)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, 2.0)
	await wait_physics_frames(30)
	assert_gt(player.health.hp, 2.0, "regenerating")
	await wait_physics_frames(40)
	assert_eq(player.health.hp, 5.0)


func test_own_bullets_never_hurt_the_player_even_overlapping() -> void:
	var r := ShotRequest.polar(player.global_position, 0.0, 0.0)
	r.hit_mask = Layers.PLAYER | Layers.ENEMY
	r.lifetime = 5.0
	bullets.emitter.request_shot_id(r)
	await wait_physics_frames(3)
	assert_eq(player.health.hp, 5.0)


func test_firing_while_standing_still_never_hurts() -> void:
	Input.action_press("fire")
	await wait_physics_frames(40)
	Input.action_release("fire")
	assert_gt(bullets.pool.spawned_total, 3)
	assert_eq(player.health.hp, 5.0)


func test_a_reflected_enemy_bullet_no_longer_hurts_the_player() -> void:
	var id := _enemy_bullet(player.global_position)
	bullets.emitter.reflect_bullet(id, Layers.PLAYER)
	await wait_physics_frames(3)
	assert_eq(player.health.hp, 5.0)
	assert_true(bullets.emitter.is_bullet_alive(id))


func test_death_then_respawn_keeps_everything_and_resets_hp() -> void:
	var dummy: TrainingDummy = main.get_node("Dummies/Dummy1")
	dummy.health = 12.0
	var dummy_hp := dummy.health
	var survivor := _enemy_bullet(Vector2(600, 300))
	player.state.set_max_hp(8.0)
	player.state.set_hp(8.0)
	player.weapon.fire_interval = 0.25
	var weapon := player.weapon
	_enemy_bullet(player.global_position, 100.0)
	await wait_physics_frames(2)
	assert_true(player.state.is_dead())
	await wait_physics_frames(20)
	assert_false(player.state.is_dead(), "respawned after the delay")
	assert_true(player.visible)
	assert_eq(player.state.get_hp(), 8.0, "hp back at max_hp (the script-set one)")
	assert_eq(player.state.get_max_hp(), 8.0)
	assert_eq(dummy.health, dummy_hp, "enemies keep their state")
	assert_true(bullets.emitter.is_bullet_alive(survivor), "bullets keep flying")
	assert_eq(player.weapon, weapon, "weapon kept")
	assert_eq(player.weapon.fire_interval, 0.25)
	assert_eq(player.global_position, Vector2.ZERO, "no arena cleared: the origin")


func test_death_respawns_at_the_last_cleared_arena() -> void:
	RespawnPoints.register_arena_cleared(Vector2(-400, 250))
	RespawnPoints.register_arena_cleared(Vector2(120, -80))
	player.state.set_hp(0.0)
	await wait_physics_frames(5)
	assert_true(player.state.is_dead(), "still dead before the 1.5 s are up")
	await wait_physics_frames(20)
	assert_eq(player.global_position, Vector2(120, -80))
	assert_false(player.state.is_dead())


func test_death_without_a_cleared_arena_respawns_at_the_origin() -> void:
	player.global_position = Vector2(300, 300)
	player.state.set_hp(0.0)
	await wait_physics_frames(20)
	assert_eq(player.global_position, Vector2.ZERO)


func test_default_respawn_delay_is_one_and_a_half_seconds() -> void:
	var fresh: Main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	autofree(fresh)
	assert_eq(fresh.respawn_delay, 1.5)


func test_dashing_through_a_bullet_takes_no_damage() -> void:
	player.try_dash(Vector2.RIGHT)
	_enemy_bullet(player.global_position + Vector2(40, 0))
	await wait_physics_frames(6)
	assert_eq(player.health.hp, 5.0)
