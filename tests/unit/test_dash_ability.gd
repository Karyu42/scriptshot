extends GutTest
## Scripted dash slot: set_dash_ability, on_dash, perform_builtin_dash, and the
## split between the file cooldown (gates on_dash) and the engine cooldown
## (gates i-frames).

const DT := 1.0 / 60.0

var player: Player


func before_each() -> void:
	ScriptWarnings.reset()
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.set_physics_process(false)
	player.global_position = Vector2(500, 500)
	player.aim_direction = Vector2.RIGHT


func after_each() -> void:
	Input.action_release("dash")
	Input.action_release("move_up")
	Input.action_release("move_left")


func _tick(ticks: int) -> void:
	for i in ticks:
		player._physics_process(DT)
		player.health.tick(DT)


class TrueAbility extends RefCounted:
	var calls := 0
	var last_player: Object = null
	var last_dir := Vector2.ZERO

	func on_dash(p: Object, d: Vector2) -> bool:
		calls += 1
		last_player = p
		last_dir = d
		return true


class FalseAbility extends RefCounted:
	var calls := 0

	func on_dash(_p: Object, _d: Vector2) -> bool:
		calls += 1
		return false


class ParityAbility extends RefCounted:
	var calls := 0

	func on_dash(p: Object, d: Vector2) -> bool:
		calls += 1
		var host := p as Player
		if host == null:
			return false
		return host.perform_builtin_dash(d)


class ShortFileCooldown extends RefCounted:
	var calls := 0

	func get_cooldown() -> float:
		return 0.1

	func on_dash(p: Object, d: Vector2) -> bool:
		calls += 1
		var host := p as Player
		if host == null:
			return false
		return host.perform_builtin_dash(d)


class BlinkAbility extends RefCounted:
	func get_cooldown() -> float:
		return 0.2

	func on_dash(p: Object, d: Vector2) -> bool:
		var host := p as Player
		if host == null:
			return false
		var step := d
		if not step.is_finite() or step.length_squared() <= 0.0001:
			step = Vector2.RIGHT
		host.global_position += step.normalized() * 40.0
		return true


class InvalidReturnAbility extends RefCounted:
	func on_dash(_p: Object, _d: Vector2) -> String:
		return "nope"


class ThrowingAbility extends RefCounted:
	# A scripted hook that errors is expected to come back as a failed call
	# result (SE's Lua host catches runtime errors). No return value is a
	# non-bool, which the player treats as false without a SCRIPT ERROR.
	func on_dash(_p: Object, _d: Vector2) -> void:
		push_error("dash ability threw")


class NodeAbility extends Node:
	func on_dash(_p: Object, _d: Vector2) -> bool:
		return true


class BadCooldownAbility extends RefCounted:
	var raw: Variant = NAN

	func get_cooldown() -> Variant:
		return raw

	func on_dash(_p: Object, _d: Vector2) -> bool:
		return true


func test_null_ability_keeps_builtin_parity() -> void:
	player.set_dash_ability(null)
	watch_signals(player)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_true(player.is_dashing())
	assert_true(player.health.is_engine_invulnerable())
	assert_signal_emitted_with_parameters(player, "dashed", [Vector2.RIGHT])
	# Movement is asserted in test_player_dash (move_and_slide needs a real
	# physics step). This checks the hook leaves the built-in path in place.
	assert_gt(player.get_dash_cooldown_left(), 0.0)
	assert_false(player.try_dash(Vector2.RIGHT), "engine cooldown still applies")


func test_ability_true_counts_as_a_dash_without_engine_iframes() -> void:
	var ability := TrueAbility.new()
	player.set_dash_ability(ability)
	watch_signals(player)
	var start := player.global_position
	assert_true(player.try_dash(Vector2.UP))
	assert_eq(ability.calls, 1)
	assert_eq(ability.last_player, player)
	assert_eq(ability.last_dir, Vector2.UP)
	assert_signal_emitted_with_parameters(player, "dashed", [Vector2.UP])
	assert_false(player.is_dashing(), "true without perform_builtin_dash is not the engine burst")
	assert_false(player.health.is_engine_invulnerable())
	assert_eq(player.global_position, start)
	assert_eq(player.get_dash_cooldown_left(), 0.0, "engine cooldown is not started")
	assert_almost_eq(player.get_ability_cooldown_left(), player.dash_cooldown, 0.0001)
	assert_false(player.try_dash(Vector2.UP), "slot cooldown gates the next on_dash")
	assert_eq(ability.calls, 1)


func test_ability_false_does_nothing_and_the_buffer_keeps_waiting() -> void:
	var ability := FalseAbility.new()
	player.set_dash_ability(ability)
	player.dash_buffer_time = 0.2
	watch_signals(player)
	player.request_dash()
	assert_true(player.has_buffered_dash())
	_tick(1)
	assert_eq(ability.calls, 1)
	assert_false(player.is_dashing())
	assert_eq(player.get_ability_cooldown_left(), 0.0)
	assert_true(player.has_buffered_dash(), "false leaves the buffer waiting")
	assert_signal_not_emitted(player, "dashed")
	# Still inside the window: the slot retries on_dash each tick.
	_tick(5)
	assert_gt(ability.calls, 1)
	assert_true(player.has_buffered_dash())
	# After the window expires the press is forgotten.
	_tick(20)
	assert_false(player.has_buffered_dash())
	assert_eq(player.get_ability_cooldown_left(), 0.0)


func test_invalid_on_dash_return_is_treated_as_false() -> void:
	player.set_dash_ability(InvalidReturnAbility.new())
	watch_signals(player)
	assert_false(player.try_dash(Vector2.RIGHT))
	assert_false(player.is_dashing())
	assert_signal_not_emitted(player, "dashed")
	assert_eq(player.get_ability_cooldown_left(), 0.0)
	assert_gte(ScriptWarnings.count("Player.dash_ability"), 1)


func test_throwing_on_dash_is_treated_as_false() -> void:
	player.set_dash_ability(ThrowingAbility.new())
	watch_signals(player)
	assert_false(player.try_dash(Vector2.RIGHT))
	assert_push_error("dash ability threw")
	assert_false(player.is_dashing())
	assert_signal_not_emitted(player, "dashed")
	assert_eq(player.get_ability_cooldown_left(), 0.0)
	assert_gte(ScriptWarnings.count("Player.dash_ability"), 1)


func test_a_freed_ability_is_treated_as_false() -> void:
	var ability := NodeAbility.new()
	add_child(ability)
	player.set_dash_ability(ability)
	ability.free()
	watch_signals(player)
	assert_false(player.try_dash(Vector2.RIGHT))
	assert_false(player.is_dashing())
	assert_signal_not_emitted(player, "dashed")
	assert_gte(ScriptWarnings.count("Player.dash_ability"), 1)


func test_parity_ability_does_not_double_dashed_or_engine_cooldown() -> void:
	var ability := ParityAbility.new()
	player.set_dash_ability(ability)
	watch_signals(player)
	assert_true(player.try_dash(Vector2.LEFT))
	assert_eq(ability.calls, 1)
	assert_true(player.is_dashing())
	assert_true(player.health.is_engine_invulnerable())
	assert_signal_emit_count(player, "dashed", 1)
	assert_signal_emitted_with_parameters(player, "dashed", [Vector2.LEFT])
	assert_almost_eq(player.get_dash_cooldown_left(), player.dash_cooldown, 0.0001)
	assert_almost_eq(player.get_ability_cooldown_left(), player.dash_cooldown, 0.0001)
	assert_false(player.try_dash(Vector2.LEFT))
	assert_eq(ability.calls, 1, "slot cooldown started once")
	assert_signal_emit_count(player, "dashed", 1)


func test_short_file_cooldown_cannot_chain_engine_iframes() -> void:
	player.dash_cooldown = 1.0
	player.dash_invulnerability = 0.2
	var ability := ShortFileCooldown.new()
	player.set_dash_ability(ability)
	assert_almost_eq(player.get_ability_cooldown_left(), 0.0, 0.0001)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_true(player.health.is_engine_invulnerable())
	assert_eq(ability.calls, 1)
	# File cooldown is 0.1 s; engine cooldown is 1.0 s. After 0.116 s the
	# slot is ready again but engine i-frames are still running (~0.08 s).
	_tick(7)
	assert_eq(player.get_ability_cooldown_left(), 0.0, "file cooldown has elapsed")
	assert_gt(player.get_dash_cooldown_left(), 0.8, "engine cooldown has not")
	assert_gt(player.health.engine_invulnerable_left, 0.05)
	var iframes_left := player.health.engine_invulnerable_left
	assert_false(player.try_dash(Vector2.RIGHT), "perform_builtin_dash refused; on_dash was false")
	assert_eq(ability.calls, 2)
	assert_almost_eq(player.health.engine_invulnerable_left, iframes_left, 0.0001, "i-frames were not refreshed")
	assert_lt(player.health.engine_invulnerable_left, player.dash_invulnerability)
	assert_eq(player.get_ability_cooldown_left(), 0.0, "a failed perform does not start the slot cooldown")
	# After the engine cooldown, perform_builtin_dash works again.
	_tick(55)
	assert_eq(player.get_dash_cooldown_left(), 0.0)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_true(player.health.is_engine_invulnerable())
	assert_eq(ability.calls, 3)


func test_a_dead_player_does_not_call_on_dash() -> void:
	var ability := TrueAbility.new()
	player.set_dash_ability(ability)
	player.state.set_hp(0.0)
	assert_false(player.try_dash(Vector2.RIGHT))
	assert_eq(ability.calls, 0)
	assert_false(player.perform_builtin_dash(Vector2.RIGHT))


func test_refresh_dash_ability_rereads_get_cooldown() -> void:
	var ability := BadCooldownAbility.new()
	ability.raw = 0.4
	player.set_dash_ability(ability)
	player.dash_cooldown = 1.5
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_almost_eq(player.get_ability_cooldown_left(), 0.4, 0.0001)
	# Leave the remaining wait alone; a hot-reload changes the next duration.
	ability.raw = 0.8
	player.refresh_dash_ability()
	assert_almost_eq(player.get_ability_cooldown_left(), 0.4, 0.0001, "in-flight slot wait is kept")
	_tick(30)
	assert_eq(player.get_ability_cooldown_left(), 0.0)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_almost_eq(player.get_ability_cooldown_left(), 0.8, 0.0001)


func test_non_finite_get_cooldown_falls_back_to_dash_cooldown() -> void:
	var ability := BadCooldownAbility.new()
	ability.raw = NAN
	player.dash_cooldown = 1.5
	player.set_dash_ability(ability)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_almost_eq(player.get_ability_cooldown_left(), 1.5, 0.0001)
	assert_gte(ScriptWarnings.count("Player.dash_ability"), 1)


func test_negative_get_cooldown_is_clamped_to_zero() -> void:
	var ability := BadCooldownAbility.new()
	ability.raw = -2
	player.set_dash_ability(ability)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_eq(player.get_ability_cooldown_left(), 0.0)
	# Zero slot wait means a second press can fire immediately (no engine dash).
	assert_true(player.try_dash(Vector2.RIGHT))


func test_blink_ability_moves_without_touching_engine_cooldown() -> void:
	var ability := BlinkAbility.new()
	player.set_dash_ability(ability)
	var start := player.global_position
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_almost_eq((player.global_position - start).x, 40.0, 0.001)
	assert_false(player.is_dashing())
	assert_eq(player.get_dash_cooldown_left(), 0.0)
	assert_almost_eq(player.get_ability_cooldown_left(), 0.2, 0.0001)


func test_player_state_dash_is_the_engine_dash_not_the_slot() -> void:
	var ability := TrueAbility.new()
	player.set_dash_ability(ability)
	assert_true(player.state.dash(0.0))
	assert_eq(ability.calls, 0, "PlayerState.dash does not go through on_dash")
	assert_true(player.is_dashing())
	assert_true(player.health.is_engine_invulnerable())
	assert_false(player.state.dash(0.0), "engine cooldown still gates it")
	assert_eq(ability.calls, 0)


func test_respawn_clears_the_slot_cooldown() -> void:
	var ability := TrueAbility.new()
	player.set_dash_ability(ability)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_gt(player.get_ability_cooldown_left(), 0.0)
	player.state.set_hp(0.0)
	player.respawn(Vector2(10, 10))
	assert_eq(player.get_ability_cooldown_left(), 0.0)
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_eq(ability.calls, 2)
