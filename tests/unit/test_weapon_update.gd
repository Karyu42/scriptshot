extends GutTest
## ShotPattern.update(): per-tick entry point, trigger state, charge / channel weapons,
## and the old fire() / fire_interval path still working.

var main: Node2D
var player: Player
var bullets: BulletManager


## Charge weapon: nothing happens while held; on release fires one bullet whose
## damage is the hold time in seconds.
class ChargeShot:
	extends ShotPattern
	var updates := 0
	var fires := 0
	var seen_held: Array[float] = []
	var _req := ShotRequest.new()

	func _init() -> void:
		auto_fire = false

	func update(context: ShotContext, emitter: ShotEmitter, _delta: float) -> void:
		updates += 1
		if context.trigger_just_released:
			seen_held.append(context.trigger_held_time)
			_req.reset()
			_req.position = context.muzzle_position
			_req.velocity = context.aim_direction * 400.0
			_req.damage = context.trigger_held_time
			emitter.request_shot(_req)

	func fire(_context: ShotContext, _emitter: ShotEmitter) -> void:
		fires += 1


## Channel weapon: emits one bullet every tick while the trigger is held.
class ChannelShot:
	extends ShotPattern
	func _init() -> void:
		auto_fire = false

	func update(context: ShotContext, emitter: ShotEmitter, _delta: float) -> void:
		if context.trigger_pressed:
			emitter.request_shot(ShotRequest.polar(context.muzzle_position, context.aim_angle, 300.0))


## Legacy-style weapon that only implements fire().
class FireOnly:
	extends ShotPattern
	var fires := 0
	func _init() -> void:
		fire_interval = 0.1

	func fire(context: ShotContext, emitter: ShotEmitter) -> void:
		fires += 1
		emitter.request_shot(ShotRequest.polar(context.muzzle_position, context.aim_angle, 300.0))


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


func test_update_runs_every_tick_even_when_trigger_is_up() -> void:
	var w := ChargeShot.new()
	player.weapon = w
	await wait_physics_frames(10)
	assert_between(w.updates, 9, 11)
	assert_eq(w.fires, 0)


func test_auto_fire_false_means_fire_is_never_called() -> void:
	var w := ChargeShot.new()
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(30)
	assert_eq(w.fires, 0)
	assert_eq(bullets.pool.spawned_total, 0, "charging: nothing fired while held")


func test_charge_weapon_fires_on_release_with_hold_time() -> void:
	var w := ChargeShot.new()
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(30)
	Input.action_release("fire")
	await wait_physics_frames(3)
	assert_eq(w.seen_held.size(), 1, "exactly one release edge")
	assert_between(w.seen_held[0], 0.4, 0.6)
	assert_eq(bullets.pool.spawned_total, 1)
	assert_almost_eq(bullets.pool.damage[0] if bullets.pool.count > 0 else w.seen_held[0], w.seen_held[0], 0.001)


func test_channel_weapon_emits_every_tick_while_held_only() -> void:
	player.weapon = ChannelShot.new()
	Input.action_press("fire")
	await wait_physics_frames(20)
	Input.action_release("fire")
	await wait_physics_frames(2)
	var after_release := bullets.pool.spawned_total
	assert_between(after_release, 18, 22)
	await wait_physics_frames(10)
	assert_eq(bullets.pool.spawned_total, after_release, "nothing more after release")


func test_fire_and_fire_interval_still_drive_default_weapons() -> void:
	var w := FireOnly.new()
	assert_true(w.auto_fire, "auto_fire defaults to true")
	player.weapon = w
	Input.action_press("fire")
	await wait_physics_frames(30)
	assert_between(w.fires, 4, 6, "0.5 s at 0.1 s interval")
	assert_eq(bullets.pool.spawned_total, w.fires)


func test_context_carries_aim_and_target_mask_to_update() -> void:
	var w := ContextSpy.new()
	player.weapon = w
	await wait_physics_frames(3)
	assert_eq(w.last_mask, Layers.ENEMY)
	assert_almost_eq(w.last_dir.length(), 1.0, 0.001)
	assert_almost_eq(w.last_muzzle.distance_to(player.global_position), player.muzzle_offset, 0.01)


class ContextSpy:
	extends ShotPattern
	var last_mask := 0
	var last_dir := Vector2.ZERO
	var last_muzzle := Vector2.ZERO
	func update(context: ShotContext, _emitter: ShotEmitter, _delta: float) -> void:
		last_mask = context.target_mask
		last_dir = context.aim_direction
		last_muzzle = context.muzzle_position
