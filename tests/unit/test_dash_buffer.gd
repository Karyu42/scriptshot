extends GutTest
## Dash input buffering (~100 ms, configurable), and the dash never touching the
## weapon: a charging weapon keeps its trigger state and charge through a dash.

const DT := 1.0 / 60.0

var player: Player


func before_each() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.set_physics_process(false)
	player.dash_cooldown = 0.5


func after_each() -> void:
	Input.action_release("fire")
	Input.action_release("dash")


## Runs `ticks` physics ticks by hand (logic only; movement is irrelevant here).
func _tick(ticks: int) -> void:
	for i in ticks:
		player._physics_process(DT)


func _start_first_dash() -> void:
	assert_true(player.try_dash(Vector2.RIGHT))


func test_default_buffer_is_about_a_tenth_of_a_second() -> void:
	assert_almost_eq(player.dash_buffer_time, 0.1, 0.0001)


func test_a_press_in_the_last_100ms_of_the_cooldown_fires_when_it_ends() -> void:
	_start_first_dash()
	_tick(26)
	assert_between(player.get_dash_cooldown_left(), 0.05, 0.09, "0.5 s cooldown, 0.43 s in")
	player.request_dash()
	assert_true(player.has_buffered_dash())
	assert_false(player.is_dashing())
	_tick(6)
	assert_true(player.is_dashing(), "fired as soon as the cooldown ended")
	assert_false(player.has_buffered_dash())


func test_the_dash_starts_within_one_tick_of_becoming_available() -> void:
	_start_first_dash()
	_tick(26)
	player.request_dash()
	var left := player.get_dash_cooldown_left()
	var ticks := 0
	while not player.is_dashing() and ticks < 20:
		_tick(1)
		ticks += 1
	assert_lte(ticks, ceili(left / DT) + 1, "within a tick of the cooldown ending")
	assert_gte(ticks, floori(left / DT))


func test_a_press_earlier_than_the_window_is_forgotten() -> void:
	_start_first_dash()
	_tick(6)
	player.request_dash()
	_tick(12)
	assert_false(player.has_buffered_dash(), "window of 0.1 s is over")
	_tick(30)
	assert_false(player.is_dashing(), "the old press must not fire a dash later")


func test_a_press_during_the_burst_fires_when_the_cooldown_allows() -> void:
	player.dash_cooldown = 0.1
	player.dash_buffer_time = 0.15
	_start_first_dash()
	_tick(3)
	assert_true(player.is_dashing())
	player.request_dash()
	_tick(10)
	assert_true(player.is_dashing(), "second dash started right after the first one's cooldown")
	assert_false(player.has_buffered_dash())


func test_a_press_while_ready_dashes_immediately_and_buffers_nothing() -> void:
	player.request_dash()
	_tick(1)
	assert_true(player.is_dashing())
	assert_false(player.has_buffered_dash())


func test_the_buffered_dash_uses_the_direction_at_the_moment_it_fires() -> void:
	_start_first_dash()
	_tick(26)
	player.request_dash()
	Input.action_press("move_up")
	_tick(8)
	Input.action_release("move_up")
	assert_true(player.is_dashing())
	assert_eq(player.get_dash_direction(), Vector2.UP)


func test_buffer_time_is_configurable_and_zero_disables_it() -> void:
	player.dash_buffer_time = 0.0
	_start_first_dash()
	_tick(26)
	player.request_dash()
	_tick(1)
	assert_false(player.has_buffered_dash(), "no buffering")
	_tick(5)
	assert_false(player.is_dashing(), "the early press was dropped")
	_tick(5)
	player.dash_buffer_time = 0.5
	_start_first_dash()
	_tick(20)
	assert_false(player.is_dashing())
	player.request_dash()
	assert_true(player.has_buffered_dash())
	_tick(12)
	assert_true(player.is_dashing(), "a long window waits for the cooldown")


func test_multiple_presses_make_a_single_dash() -> void:
	_start_first_dash()
	_tick(26)
	player.request_dash()
	player.request_dash()
	player.request_dash()
	_tick(10)
	assert_true(player.is_dashing())
	_tick(20)
	assert_false(player.is_dashing(), "one press = one dash")
	assert_false(player.has_buffered_dash())


func test_respawn_drops_a_buffered_dash() -> void:
	_start_first_dash()
	player.request_dash()
	player.respawn(Vector2.ZERO)
	assert_false(player.has_buffered_dash())


func test_a_real_input_press_is_buffered_too() -> void:
	player.set_physics_process(true)
	_start_first_dash()
	await wait_physics_frames(24)
	Input.action_press("dash")
	await wait_physics_frames(1)
	Input.action_release("dash")
	assert_true(player.has_buffered_dash() or player.is_dashing())
	await wait_physics_frames(14)
	assert_true(player.is_dashing() or player.get_dash_cooldown_left() > 0.2, "it fired at the end of the cooldown")


# --- the dash leaves the weapon alone ---------------------------------------------

## Charge weapon: counts ticks while held; on release fires one bullet.
class ChargeShot:
	extends ShotPattern
	var charge_ticks := 0
	var held_seen: Array[float] = []
	var released_with := -1.0
	var updates := 0

	func _init() -> void:
		auto_fire = false

	func update(context: ShotContext, _emitter: ShotEmitter, _delta: float) -> void:
		updates += 1
		if context.trigger_pressed:
			charge_ticks += 1
			held_seen.append(context.trigger_held_time)
		if context.trigger_just_released:
			released_with = context.trigger_held_time


func _with_charge_weapon() -> ChargeShot:
	var bullets := BulletManager.new()
	bullets.render_enabled = false
	add_child_autofree(bullets)
	player.emitter = bullets.emitter
	var weapon := ChargeShot.new()
	player.weapon = weapon
	player.set_physics_process(true)
	return weapon


func test_dashing_does_not_cancel_a_charging_weapon() -> void:
	var weapon := _with_charge_weapon()
	Input.action_press("fire")
	await wait_physics_frames(10)
	var charge_before := weapon.charge_ticks
	assert_gt(charge_before, 5, "charging")
	assert_true(player.try_dash(Vector2.RIGHT))
	await wait_physics_frames(15)
	assert_true(player.is_dashing() or player.get_dash_cooldown_left() > 0.0)
	assert_gte(weapon.charge_ticks, charge_before + 14, "charge kept counting through the dash")
	Input.action_release("fire")
	await wait_physics_frames(2)
	assert_gt(weapon.released_with, 25.0 * DT, "the release reports the whole hold, dash included")


func test_trigger_held_time_is_monotonic_across_a_dash() -> void:
	var weapon := _with_charge_weapon()
	Input.action_press("fire")
	await wait_physics_frames(6)
	player.try_dash(Vector2.UP)
	await wait_physics_frames(14)
	Input.action_release("fire")
	await wait_physics_frames(1)
	for i in range(1, weapon.held_seen.size()):
		assert_gt(weapon.held_seen[i], weapon.held_seen[i - 1], "held time never resets (tick %d)" % i)


func test_a_buffered_dash_firing_mid_charge_does_not_release_the_weapon() -> void:
	var weapon := _with_charge_weapon()
	player.dash_cooldown = 0.2
	Input.action_press("fire")
	await wait_physics_frames(4)
	player.try_dash(Vector2.LEFT)
	player.request_dash()
	await wait_physics_frames(24)
	assert_true(player._trigger.pressed, "trigger still down")
	assert_eq(weapon.released_with, -1.0, "never released")
	assert_gt(weapon.charge_ticks, 20)
	Input.action_release("fire")


func test_dash_leaves_the_weapon_and_cooldown_objects_untouched() -> void:
	var weapon := _with_charge_weapon()
	player.try_dash(Vector2.RIGHT)
	assert_eq(player.weapon, weapon)
	assert_true(player.weapon.auto_fire == false)
