extends GutTest
## A1 parity (Game Designer call): the bundled default Dash file reproduces
## the engine dash. Two players run the same 10 s scripted input trace in
## lockstep, one on the built-in dash and one with the default file in its
## Dash slot; their positions stay within 0.5 px on every tick, and they dash
## and get engine i-frames on the same ticks.

const DT := 1.0 / 60.0
const TICKS := 600
const TOLERANCE := 0.5

var _engine: Player
var _scripted: Player
var _ability: LuaDashAbility


func before_each() -> void:
	ScriptWarnings.reset()
	_engine = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	_scripted = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	for p: Player in [_engine, _scripted]:
		add_child_autofree(p)
		p.set_physics_process(false)
		p.global_position = Vector2.ZERO
	_ability = LuaDashAbility.new()
	_ability.bind_player(_scripted)
	var r := _ability.apply(AbilityLibrary.default_dash_source())
	assert_true(r.ok, r.error)
	_scripted.set_dash_ability(_ability)


const ACTIONS: Array[String] = ["move_left", "move_right", "move_up", "move_down"]
## Ticks where the held movement changes, and what is held from then on
## (bits: 1 left, 2 right, 4 up, 8 down).
const MOVE_TICKS: Array[int] = [0, 50, 130, 170, 260, 330, 420, 470, 560]
const MOVE_HELD: Array[int] = [2, 2 | 8, 0, 4, 1 | 4, 1, 0, 8 | 2, 4]
## Dash presses: some while moving, some standing still (aim direction),
## some during the burst or the cooldown (buffered or forgotten).
const PRESSES: Array[int] = [10, 60, 95, 100, 140, 200, 205, 290, 300, 380, 430, 431, 480, 500, 575]


func after_each() -> void:
	_hold(0)


func _hold(bits: int) -> void:
	for i in ACTIONS.size():
		var action := StringName(ACTIONS[i])
		if bits & (1 << i):
			Input.action_press(action)
		else:
			Input.action_release(action)


func test_default_file_matches_the_engine_dash_over_10_seconds() -> void:
	var worst := 0.0
	var engine_dashes: Array[int] = [0]
	var scripted_dashes: Array[int] = [0]
	_engine.dashed.connect(func(_d: Vector2) -> void: engine_dashes[0] += 1)
	_scripted.dashed.connect(func(_d: Vector2) -> void: scripted_dashes[0] += 1)
	var mismatched_iframes := 0
	var mismatched_dashing := 0
	for tick in TICKS:
		var m := MOVE_TICKS.find(tick)
		if m >= 0:
			_hold(MOVE_HELD[m])
		if PRESSES.has(tick):
			_engine.request_dash()
			_scripted.request_dash()
		_engine._physics_process(DT)
		_scripted._physics_process(DT)
		worst = maxf(worst, _engine.global_position.distance_to(_scripted.global_position))
		if _engine.health.is_engine_invulnerable() != _scripted.health.is_engine_invulnerable():
			mismatched_iframes += 1
		if _engine.is_dashing() != _scripted.is_dashing():
			mismatched_dashing += 1
	var n_engine: int = engine_dashes[0]
	var n_scripted: int = scripted_dashes[0]
	assert_lt(worst, TOLERANCE, "worst gap %.6f px" % worst)
	assert_gt(n_engine, 4, "the trace dashes several times")
	assert_eq(n_scripted, n_engine, "same number of dashes")
	assert_eq(mismatched_dashing, 0, "dashing on the same ticks")
	assert_eq(mismatched_iframes, 0, "engine i-frames on the same ticks")
	assert_gt(_engine.global_position.length(), 100.0, "the trace moved")
	assert_eq(_ability.error_total, 0)
	assert_eq(_ability.builtin_dashes, n_scripted, "every scripted dash is the engine dash")


func test_engine_iframes_only_come_from_player_dash() -> void:
	var r := _ability.apply("return { cooldown = 0.05, on_dash = function(ctx, dir) end }")
	assert_true(r.ok, r.error)
	_scripted.request_dash()
	_scripted._physics_process(DT)
	assert_false(_scripted.health.is_engine_invulnerable(), "a dash without player:dash() grants no i-frames")
	assert_false(_scripted.is_dashing())


func test_a_fast_file_cooldown_still_gets_iframes_only_at_the_engine_cooldown() -> void:
	var r := _ability.apply("return { cooldown = 0.1, on_dash = function(ctx, dir) player:dash(0) end }")
	assert_true(r.ok, r.error)
	var iframe_starts := 0
	var was := false
	for tick in 120:
		_scripted.request_dash()
		_scripted._physics_process(DT)
		var now := _scripted.health.is_engine_invulnerable()
		if now and not was:
			iframe_starts += 1
		was = now
	# 2 s at the engine's 1.5 s dash cooldown: two engine dashes at most.
	assert_lte(iframe_starts, 2)
	assert_gt(_ability.dash_calls, 10, "the file's own cooldown ran on_dash far more often")
