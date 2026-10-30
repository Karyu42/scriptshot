extends GutTest
## Enemy bullets hurt the player; nobody hurts their own side (a bullet's owner
## layer is removed from its hit mask).

const DT := 1.0 / 60.0

var main: Node2D
var player: Player
var bullets: BulletManager


func before_each() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child_autofree(main)
	for turret: Turret in main.get_node("Turrets").get_children():
		turret.emitter = null
	player = main.get_node("Player")
	bullets = main.get_node("BulletManager")
	await wait_physics_frames(2)


## An enemy-owned bullet by default (the ones that can hurt the player).
func _bullet_at(pos: Vector2, mask: int, dmg: float = 1.0, owner_layer: int = Layers.ENEMY) -> int:
	var r := ShotRequest.polar(pos, 0.0, 0.0)
	r.owner_layer = owner_layer
	r.hit_mask = mask
	r.damage = dmg
	r.lifetime = 5.0
	return bullets.emitter.request_shot_id(r)


func test_enemy_bullet_damages_player_and_is_consumed() -> void:
	var id := _bullet_at(player.global_position, Layers.hostile_to(Layers.ENEMY), 2.0)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 2.0)
	assert_false(bullets.emitter.is_bullet_alive(id))


func test_player_bullet_does_not_hurt_player() -> void:
	var id := _bullet_at(player.global_position, Layers.hostile_to(Layers.PLAYER), 1.0, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp, "no friendly fire")
	assert_true(bullets.emitter.is_bullet_alive(id), "and the bullet is not consumed by its own side")


func test_player_owned_bullet_cannot_hurt_player_even_if_asked_to() -> void:
	# A script that sets hit_mask to PLAYER anyway: the owner's layer is stripped.
	var id := _bullet_at(player.global_position, Layers.PLAYER | Layers.ENEMY, 1.0, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp, "own bullets never hurt the player")
	assert_true(bullets.emitter.is_bullet_alive(id))
	assert_eq(bullets.pool.hit_mask[bullets.pool.slot_of(id)], Layers.ENEMY)


func test_default_request_is_player_owned_and_harmless_to_player() -> void:
	var r := ShotRequest.polar(player.global_position, 0.0, 0.0)
	r.hit_mask = Layers.PLAYER
	r.lifetime = 5.0
	var id := bullets.emitter.request_shot_id(r)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp)
	assert_true(bullets.emitter.is_bullet_alive(id))


func test_enemy_bullet_does_not_hurt_enemies() -> void:
	var dummy: TrainingDummy = main.get_node("Dummies/Dummy1")
	var id := _bullet_at(dummy.global_position, Layers.hostile_to(Layers.ENEMY))
	await wait_physics_frames(2)
	assert_eq(dummy.health, dummy.max_health, "no friendly fire among enemies")
	assert_true(bullets.emitter.is_bullet_alive(id))


func test_player_bullet_hurts_enemy() -> void:
	var dummy: TrainingDummy = main.get_node("Dummies/Dummy1")
	_bullet_at(dummy.global_position, Layers.hostile_to(Layers.PLAYER), 3.0, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_eq(dummy.health, dummy.max_health - 3.0)


func test_bullets_pass_through_player_during_iframes() -> void:
	_bullet_at(player.global_position, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_true(player.health.is_invulnerable())
	var second := _bullet_at(player.global_position, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 1.0, "second bullet did no damage")
	assert_true(bullets.emitter.is_bullet_alive(second), "and was not wasted on the player")


func test_damage_after_iframes_end() -> void:
	_bullet_at(player.global_position, Layers.PLAYER)
	await wait_physics_frames(2)
	await wait_physics_frames(ceili(player.health.invulnerability_time / DT) + 3)
	assert_false(player.health.is_invulnerable())
	_bullet_at(player.global_position, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 2.0)


func test_death_hides_player_and_respawn_restores_it() -> void:
	watch_signals(player)
	_bullet_at(player.global_position, Layers.PLAYER, 999.0)
	await wait_physics_frames(2)
	assert_signal_emit_count(player, "died", 1)
	assert_false(player.visible)
	assert_true(player.health.is_dead())
	# A dead player cannot be hit or fire.
	Input.action_press("fire")
	await wait_physics_frames(10)
	Input.action_release("fire")
	assert_eq(bullets.pool.spawned_total, 1, "only the killing bullet exists")
	player.respawn(Vector2(100, 50))
	assert_true(player.visible)
	assert_eq(player.global_position, Vector2(100, 50))
	assert_eq(player.health.hp, player.health.max_hp)
	_bullet_at(player.global_position, Layers.PLAYER)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 1.0)


func test_turret_in_range_shoots_player_not_other_enemies() -> void:
	var turret: Turret = main.get_node("Turrets/Turret1")
	turret.emitter = bullets.emitter
	turret.target = player
	player.global_position = turret.global_position + Vector2(300, 0)
	await wait_physics_frames(5)
	assert_gt(bullets.pool.count, 0, "turret fired")
	assert_eq(bullets.pool.hit_mask[0], Layers.PLAYER)
	await wait_physics_frames(60)
	assert_lt(player.health.hp, player.health.max_hp, "turret bullets reached the player")


func test_turret_out_of_range_holds_fire() -> void:
	var turret: Turret = main.get_node("Turrets/Turret1")
	turret.emitter = bullets.emitter
	turret.target = player
	player.global_position = turret.global_position + Vector2(turret.shot_range + 200.0, 0)
	await wait_physics_frames(30)
	assert_eq(bullets.pool.spawned_total, 0)


# --- script invulnerability vs piercing attacks (QA B4) ----------------------------

func _piercing_bullet_at(pos: Vector2) -> int:
	var r := ShotRequest.polar(pos, 0.0, 0.0)
	r.owner_layer = Layers.ENEMY
	r.hit_mask = Layers.PLAYER
	r.pierces_script_invuln = true
	r.lifetime = 5.0
	return bullets.emitter.request_shot_id(r)


func test_script_invulnerability_blocks_normal_bullets_but_consumes_them() -> void:
	player.state.set_invulnerable(true)
	var id := _bullet_at(player.global_position, Layers.hostile_to(Layers.ENEMY), 2.0)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp, "no damage")
	assert_false(bullets.emitter.is_bullet_alive(id), "the bullet hit the shielded player and is gone")
	assert_false(player.health.is_engine_invulnerable(), "a blocked hit gives no i-frames")


func test_a_piercing_bullet_hits_through_script_invulnerability() -> void:
	player.state.set_invulnerable(true)
	_piercing_bullet_at(player.global_position)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 1.0)
	assert_true(player.health.is_engine_invulnerable(), "the hit gave normal i-frames")
	assert_true(player.state.is_script_invulnerable(), "and left the script layer alone")


func test_a_piercing_bullet_cannot_hit_through_hit_iframes() -> void:
	player.state.set_invulnerable(true)
	_piercing_bullet_at(player.global_position)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 1.0)
	var second := _piercing_bullet_at(player.global_position)
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp - 1.0, "i-frames hold against piercing too")
	assert_true(bullets.emitter.is_bullet_alive(second), "and the bullet passes through the i-framed player")


func test_a_piercing_bullet_cannot_hit_during_a_dash() -> void:
	player.state.set_invulnerable(true)
	assert_true(player.try_dash(Vector2.UP))
	var id := _piercing_bullet_at(player.global_position + Vector2(0, -20))
	await wait_physics_frames(2)
	assert_eq(player.health.hp, player.health.max_hp)
	assert_true(bullets.emitter.is_bullet_alive(id))


func test_script_false_does_not_end_a_dash_or_hit_iframes_on_the_live_player() -> void:
	assert_true(player.try_dash(Vector2.RIGHT))
	player.state.set_invulnerable(false)
	assert_true((player.get_node("Hurtbox") as Hurtbox).active == false, "dash i-frames still switch the hurtbox off")
	assert_true(player.health.is_engine_invulnerable())
