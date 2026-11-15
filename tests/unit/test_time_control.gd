extends GutTest
## TimeControl request / reject / cooldown / cancel / pause (ability-scripting.md).


class Req:
	extends RefCounted
	var ok := false
	var err := ""
	var cooldown_left := 0.0


func before_each() -> void:
	TimeControl.cancel()
	TimeControl.set_process(false)
	Engine.time_scale = 1.0
	get_tree().paused = false


func after_each() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	TimeControl.cancel()
	TimeControl.set_process(true)


func _request(scale: float, seconds: float) -> Req:
	var raw: Dictionary = TimeControl.request(scale, seconds)
	var out := Req.new()
	@warning_ignore_start("unsafe_cast")
	out.ok = raw["ok"]
	out.err = raw["err"]
	out.cooldown_left = raw["cooldown_left"]
	@warning_ignore_restore("unsafe_cast")
	return out


func test_request_clamps_and_rejects_invalid() -> void:
	var bad := _request(NAN, 1.0)
	assert_false(bad.ok)
	assert_eq(bad.err, "invalid")
	bad = _request(0.5, 0.0)
	assert_false(bad.ok)
	assert_eq(bad.err, "invalid")
	var accepted := _request(1.5, 10.0)
	assert_true(accepted.ok)
	assert_eq(accepted.err, "")
	assert_almost_eq(TimeControl.world_scale(), 1.0, 0.0001, "scale clamped to 1")
	assert_true(TimeControl.is_active())
	TimeControl.debug_advance(TimeControl.MAX_STOP_SECONDS + 0.01)
	assert_false(TimeControl.is_active())
	assert_almost_eq(
		TimeControl.cooldown_left(),
		TimeControl.COOLDOWN_DURATION_MUL * TimeControl.MAX_STOP_SECONDS,
		0.0001
	)


func test_no_stacking_while_active_or_on_cooldown() -> void:
	watch_signals(TimeControl)
	var first := _request(0.25, 2.0)
	assert_true(first.ok)
	assert_signal_emitted_with_parameters(TimeControl, "script_time_scaled", [0.25, 2.0])
	var again := _request(0.0, 1.0)
	assert_false(again.ok)
	assert_eq(again.err, "active")
	assert_gt(again.cooldown_left, 1.5)
	TimeControl.debug_advance(2.0)
	assert_false(TimeControl.is_active())
	assert_almost_eq(TimeControl.cooldown_left(), 3.0, 0.0001, "max(1, 1.5 * 2)")
	var during_cd := _request(0.5, 1.0)
	assert_false(during_cd.ok)
	assert_eq(during_cd.err, "cooldown")
	assert_almost_eq(during_cd.cooldown_left, 3.0, 0.0001)
	TimeControl.debug_advance(3.0)
	assert_eq(TimeControl.cooldown_left(), 0.0)
	assert_true(_request(0.5, 1.0).ok)


func test_short_stop_has_a_one_second_minimum_cooldown() -> void:
	_request(0.0, 0.4)
	TimeControl.debug_advance(0.4)
	assert_false(TimeControl.is_active())
	assert_almost_eq(TimeControl.cooldown_left(), TimeControl.COOLDOWN_MIN_SECONDS, 0.0001)


func test_cancel_ends_with_no_cooldown() -> void:
	_request(0.0, 3.0)
	TimeControl.debug_advance(1.0)
	TimeControl.cancel()
	assert_false(TimeControl.is_active())
	assert_eq(TimeControl.world_scale(), 1.0)
	assert_eq(TimeControl.cooldown_left(), 0.0)
	assert_true(_request(0.5, 1.0).ok, "usable immediately after cancel")


func test_player_death_and_boss_kill_cancel_without_cooldown() -> void:
	_request(0.0, 3.0)
	GameEvents.player_died.emit()
	assert_false(TimeControl.is_active())
	assert_eq(TimeControl.cooldown_left(), 0.0)
	_request(0.0, 3.0)
	GameEvents.boss_defeated.emit(&"warden", 0, 0, Vector2.ZERO)
	assert_false(TimeControl.is_active())
	assert_eq(TimeControl.cooldown_left(), 0.0)
	assert_true(_request(0.0, 1.0).ok)


func test_respawn_cancels_without_cooldown() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	_request(0.0, 3.0)
	player.respawn(Vector2(80, 80))
	assert_false(TimeControl.is_active())
	assert_eq(TimeControl.cooldown_left(), 0.0)
	assert_true(_request(0.5, 1.0).ok)


func test_countdown_pauses_when_the_tree_is_paused_or_victory_freezes_time() -> void:
	_request(0.5, 2.0)
	get_tree().paused = true
	TimeControl.debug_advance(1.0)
	assert_true(TimeControl.is_active())
	var mid := _request(0.0, 1.0)
	assert_eq(mid.err, "active")
	assert_almost_eq(mid.cooldown_left, 2.0, 0.0001)
	get_tree().paused = false
	Engine.time_scale = 0.0
	TimeControl.debug_advance(1.0)
	mid = _request(0.0, 1.0)
	assert_eq(mid.err, "active")
	assert_almost_eq(mid.cooldown_left, 2.0, 0.0001, "victory time_scale 0 pauses the clock")
	Engine.time_scale = 1.0
	TimeControl.debug_advance(0.5)
	mid = _request(0.0, 1.0)
	assert_almost_eq(mid.cooldown_left, 1.5, 0.0001)


func test_world_scale_zero_does_not_write_engine_time_scale() -> void:
	Engine.time_scale = 1.0
	_request(0.0, 1.0)
	assert_eq(Engine.time_scale, 1.0)
	assert_eq(TimeControl.world_scale(), 0.0)
	Engine.time_scale = 0.15
	TimeControl.debug_advance(1.0)
	assert_false(TimeControl.is_active())
	assert_eq(Engine.time_scale, 0.15)
	Engine.time_scale = 1.0


func test_scaled_delta_and_bullet_delta() -> void:
	assert_eq(TimeControl.scaled_delta(0.1, 0.0), 0.1)
	_request(0.0, 2.0)
	assert_eq(TimeControl.scaled_delta(0.1, 0.0), 0.0)
	assert_almost_eq(TimeControl.scaled_delta(0.1, TimeControl.NULL_TIME_SCALE_FLOOR), 0.05, 0.0001)
	assert_eq(TimeControl.bullet_delta(0.1, true, false), 0.1)
	assert_eq(TimeControl.bullet_delta(0.1, false, false), 0.0)
	assert_almost_eq(TimeControl.bullet_delta(0.1, false, true), 0.05, 0.0001)
