extends GutTest
## AbilityScripts and abilities/: dash.lua seeded and equipped at start, the
## hand-over to the player's dash hook, the engine-dash fallback for a missing
## or broken file, save round trips, and the PC file watcher.


var _player: Player
var _s: AbilityScripts
var _swapped: Array[String] = []
var _failed: Array[String] = []


func before_each() -> void:
	ScriptWarnings.reset()
	_clear_dir()
	_swapped.clear()
	_failed.clear()
	_player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(_player)
	_player.set_physics_process(false)
	_s = _make()


func after_each() -> void:
	_clear_dir()


func _make() -> AbilityScripts:
	var s := AbilityScripts.new()
	s.watch_files = false
	add_child_autofree(s)
	s.setup(_player)
	s.ability.error_backoff_msec = 0
	s.ability_swapped.connect(func(f: String, o: StringName) -> void: _swapped.append("%s:%s" % [f, o]))
	s.load_failed.connect(func(f: String, _p: ScriptProblem, o: StringName) -> void: _failed.append("%s:%s" % [f, o]))
	return s


static func _clear_dir() -> void:
	var dir := DirAccess.open(AbilityLibrary.root_dir())
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)


func _hooked_ability() -> Object:
	return _player._dash_ability


func test_bundled_default_is_text_not_lua() -> void:
	assert_true(FileAccess.file_exists("res://scripting/abilities/default_dash.lua.txt"))
	assert_false(FileAccess.file_exists("res://scripting/abilities/default_dash.lua"))
	assert_string_contains(AbilityLibrary.default_dash_source(), "player:dash(")


func test_start_seeds_and_equips_dash_lua() -> void:
	assert_true(_s.start())
	assert_true(AbilityLibrary.exists(AbilityLibrary.DEFAULT_DASH_FILE))
	assert_eq(_s.equipped, "dash.lua")
	assert_true(_s.has_script())
	assert_eq(_swapped, ["dash.lua:start"] as Array[String])
	assert_eq(_hooked_ability(), _s.ability, "handed to the dash hook")


func test_seed_happens_once() -> void:
	assert_true(AbilityLibrary.seed_default())
	DirAccess.remove_absolute(AbilityLibrary.path_of("dash.lua"))
	assert_false(AbilityLibrary.seed_default(), "a deleted dash.lua is not re-seeded")


func test_missing_file_keeps_the_engine_dash() -> void:
	AbilityLibrary.seed_default()
	DirAccess.remove_absolute(AbilityLibrary.path_of("dash.lua"))
	assert_false(_s.start())
	assert_eq(_s.equipped, "")
	assert_false(_s.has_script())
	assert_null(_hooked_ability(), "the player keeps the built-in dash")
	assert_eq(_failed, ["dash.lua:start"] as Array[String])


func test_broken_file_keeps_the_engine_dash_until_a_good_save() -> void:
	AbilityLibrary.seed_default()
	AbilityLibrary.write("dash.lua", "return { on_dash = function( end }")
	assert_false(_s.start())
	assert_not_null(_s.problem)
	assert_eq(_s.problem.kind, ScriptProblem.Kind.COMPILE)
	assert_null(_hooked_ability())
	assert_true(_s.save("dash.lua", AbilityLibrary.default_dash_source()))
	assert_true(_s.has_pending_load())
	_s.flush_pending()
	assert_true(_s.has_script())
	assert_null(_s.problem)
	assert_eq(_hooked_ability(), _s.ability)


func test_bad_save_keeps_the_last_good_version() -> void:
	assert_true(_s.start())
	_s.save("dash.lua", "return { name = 'Blinky', cooldown = 0.6, on_dash = function() end }")
	_s.flush_pending()
	assert_eq(_s.ability.title, "Blinky")
	assert_almost_eq(_s.ability.get_cooldown(), 0.6, 0.0001)
	_s.save("dash.lua", "return { on_dash = function( end }")
	_s.flush_pending()
	assert_eq(_s.ability.title, "Blinky")
	assert_not_null(_s.problem)
	assert_eq(_failed, ["dash.lua:editor"] as Array[String])
	assert_eq(AbilityLibrary.read("dash.lua"), "return { on_dash = function( end }", "the text is saved anyway")


func test_hot_reload_refreshes_the_player_cooldown() -> void:
	assert_true(_s.start())
	assert_almost_eq(_player._ability_cooldown, _player.dash_cooldown, 0.0001)
	_s.save("dash.lua", "return { cooldown = 0.4, on_dash = function() end }")
	_s.flush_pending()
	assert_almost_eq(_player._ability_cooldown, 0.4, 0.0001)


func test_saving_another_file_equips_it() -> void:
	assert_true(_s.start())
	_s.save("blink.lua", "return { name = 'Blink', on_dash = function() end }")
	_s.flush_pending()
	assert_eq(_s.equipped, "blink.lua")
	assert_eq(AbilityLibrary.equipped_dash(), "blink.lua")
	var again := _make()
	assert_true(again.start())
	assert_eq(again.equipped, "blink.lua", "the equipped file is remembered")


func test_the_watcher_reloads_an_outside_edit() -> void:
	assert_true(_s.start())
	assert_false(_s.poll_files(), "nothing changed")
	var f := FileAccess.open(AbilityLibrary.path_of("dash.lua"), FileAccess.WRITE)
	f.store_string("return { name = 'Outside', on_dash = function() end }")
	f.close()
	assert_true(_s.poll_files())
	_s.flush_pending()
	assert_eq(_s.ability.title, "Outside")
	assert_true(_swapped.has("dash.lua:file"))


func test_dash_button_runs_the_file_through_the_hook() -> void:
	assert_true(_s.start())
	_s.save("dash.lua", "state.n = state.n or 0\nreturn { on_dash = function(ctx, dir) state.n = state.n + 1 return player:dash(math.atan(dir.y, dir.x)) end }")
	_s.flush_pending()
	_player.request_dash()
	_player._physics_process(1.0 / 60.0)
	assert_true(_player.is_dashing())
	assert_true(_player.health.is_engine_invulnerable())
	assert_eq(_s.ability.dash_calls, 1)


func test_an_erroring_file_never_dashes_and_reports() -> void:
	assert_true(_s.start())
	_s.save("dash.lua", "return { on_dash = function() error('nope') end }")
	_s.flush_pending()
	for i in 10:
		_player.request_dash()
		_player._physics_process(1.0 / 60.0)
	assert_false(_player.is_dashing())
	assert_gt(_s.ability.error_total, 0)
	assert_gt(ScriptWarnings.count(LuaDashAbility.ERROR_KEY), 0)


func test_leaving_the_tree_restores_the_built_in_dash() -> void:
	assert_true(_s.start())
	assert_eq(_hooked_ability(), _s.ability)
	remove_child(_s)
	assert_null(_hooked_ability())
	assert_false(_player._has_dash_ability)


const LONG_HOOK := "return { cooldown = 0.5, on_dash = function(ctx, dir)\n  player:dash(math.atan(dir.y, dir.x))\n  for i = 1, 300 do coroutine.yield() end\n  state.finished = true\nend }"


func _press() -> void:
	_player.request_dash()
	_player._physics_process(1.0 / 60.0)


func test_the_file_cooldown_starts_at_the_press_not_when_a_yielded_run_ends() -> void:
	assert_true(_s.start())
	_s.save("dash.lua", LONG_HOOK)
	_s.flush_pending()
	_press()
	assert_true(_s.ability.is_running())
	assert_almost_eq(_player.get_ability_cooldown_left(), 0.5, 0.02, "counting from the press")
	for i in 40:
		_player._physics_process(1.0 / 60.0)
		_s.ability.tick()
	assert_true(_s.ability.is_running(), "the run goes on")
	assert_eq(_player.get_ability_cooldown_left(), 0.0, "the cooldown ran down meanwhile")
	assert_false(_s.ability.on_dash(_player, Vector2.RIGHT), "but a new press is refused while it runs")


func test_death_drops_a_running_hook() -> void:
	assert_true(_s.start())
	_s.save("dash.lua", LONG_HOOK)
	_s.flush_pending()
	_press()
	assert_true(_s.ability.is_running())
	_player.health.set_hp(0.0)
	assert_true(_player.is_dead())
	assert_false(_s.ability.is_running(), "dropped on death")


func test_respawn_drops_a_running_hook() -> void:
	assert_true(_s.start())
	_s.save("dash.lua", LONG_HOOK)
	_s.flush_pending()
	_press()
	assert_true(_s.ability.is_running())
	_player.respawn(Vector2(50, 50))
	assert_false(_s.ability.is_running(), "dropped on respawn")
