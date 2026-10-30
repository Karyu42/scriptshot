extends GutTest
## Respawn is a clean slate for the fire button, the fire cooldown and the weapon's
## own state (QA B3), and keeps script invulnerability (B4).

var main: Node2D
var player: Player
var bullets: BulletManager


## Fires on the release edge with the hold time; `reset()` is counted.
class ChargeShot:
	extends ShotPattern
	var released: Array[float] = []
	var charge := 0.0
	var resets := 0

	func _init() -> void:
		auto_fire = false

	func update(context: ShotContext, emitter: ShotEmitter, delta: float) -> void:
		if context.trigger_pressed:
			charge += delta
		if context.trigger_just_released:
			released.append(context.trigger_held_time)
			emitter.request_shot(ShotRequest.polar(context.muzzle_position, context.aim_angle, 300.0))

	func reset() -> void:
		resets += 1
		charge = 0.0


class SlowGun:
	extends ShotPattern
	var fires := 0

	func _init() -> void:
		fire_interval = 10.0

	func fire(context: ShotContext, emitter: ShotEmitter) -> void:
		fires += 1
		emitter.request_shot(ShotRequest.polar(context.muzzle_position, context.aim_angle, 300.0))


class FastGun:
	extends ShotPattern
	var fires := 0
	var indices: Array[int] = []

	func _init() -> void:
		fire_interval = 0.005

	func fire(context: ShotContext, _emitter: ShotEmitter) -> void:
		fires += 1
		indices.append(context.shot_index)


func before_each() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child_autofree(main)
	for turret: Turret in main.get_node("Turrets").get_children():
		turret.emitter = null
	player = main.get_node("Player")
	bullets = main.get_node("BulletManager")
	await wait_physics_frames(2)


func after_each() -> void:
	Input.action_release("fire")


func _kill() -> void:
	player.state.set_hp(0.0)
	await wait_physics_frames(2)


func test_a_button_released_while_dead_does_not_fire_a_stale_charged_shot() -> void:
	var w := ChargeShot.new()
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(30)
	await _kill()
	Input.action_release("fire")
	await wait_physics_frames(2)
	player.respawn(Vector2(100, 100))
	await wait_physics_frames(4)
	assert_eq(w.released.size(), 0, "no release edge survives the death")
	assert_eq(bullets.pool.spawned_total, 0)


func test_a_normal_release_after_the_respawn_still_fires() -> void:
	var w := ChargeShot.new()
	player.weapon = w
	await _kill()
	player.respawn(Vector2(100, 100))
	Input.action_press("fire")
	await wait_physics_frames(10)
	Input.action_release("fire")
	await wait_physics_frames(3)
	assert_eq(w.released.size(), 1)
	assert_lt(w.released[0], 0.5, "hold time counts from after the respawn")


func test_respawn_resets_the_weapons_own_charge() -> void:
	var w := ChargeShot.new()
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(30)
	assert_gt(w.charge, 0.3)
	await _kill()
	player.respawn(Vector2.ZERO)
	assert_eq(w.resets, 1)
	assert_eq(w.charge, 0.0)


func test_respawn_resets_the_fire_cooldown() -> void:
	var w := SlowGun.new()
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(5)
	assert_eq(w.fires, 1, "one shot, then a 10 s cooldown")
	await _kill()
	player.respawn(Vector2.ZERO)
	await wait_physics_frames(5)
	assert_eq(w.fires, 2, "the cooldown did not carry over the death")


func test_respawn_with_no_weapon_is_fine() -> void:
	player.weapon = null
	await _kill()
	player.respawn(Vector2.ZERO)
	assert_false(player.state.is_dead())


func test_script_invulnerability_persists_across_the_respawn() -> void:
	player.state.set_invulnerable(true)
	player.health.add_engine_invulnerability(0.5)
	player.state.set_hp(0.0)
	player.respawn(Vector2.ZERO)
	assert_true(player.state.is_script_invulnerable(), "scripts own it; they clear it")
	assert_false(player.state.is_engine_invulnerable(), "engine i-frames end with the respawn")
	assert_true((player.get_node("Hurtbox") as Hurtbox).active, "the hurtbox is on: piercing attacks can land")


# --- #2 semantics: several shots per tick ---------------------------------------

func test_a_fast_weapon_fires_every_shot_it_is_owed_each_tick() -> void:
	var w := FastGun.new()
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(30)
	# 0.005 s interval = 3.33 shots per 1/60 s tick: ~100 shots in 30 ticks, not 30.
	assert_between(w.fires, 85, 115)
	for k in w.indices.size():
		assert_eq(w.indices[k], k, "shot_index counts every shot")
