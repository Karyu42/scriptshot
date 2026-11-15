extends GutTest
## The in-game editor opens and saves the equipped Dash file (abilities/):
## the picker entry, save -> reload of the Dash slot, a bad save keeping the
## last good dash, and an on_dash error in the Problems list with its line.

var _mgr: BulletManager
var _player: Player
var _scripts: ShotScripts
var _abilities: AbilityScripts
var _panel: ScriptEditorPanel


func before_each() -> void:
	ScriptWarnings.reset()
	SenseBook.reset()
	Engine.time_scale = 1.0
	_clear(ScriptLibrary.root_dir())
	_clear(AbilityLibrary.root_dir())
	_mgr = BulletManager.new()
	_mgr.backend_preference = "gdscript"
	_mgr.capacity = 128
	_mgr.logical_cap = 128
	_mgr.enemy_reserve = 0
	_mgr.render_enabled = false
	_mgr.auto_step = false
	add_child_autofree(_mgr)
	_player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(_player)
	_player.set_physics_process(false)
	_scripts = ShotScripts.new()
	_scripts.watch_files = false
	add_child_autofree(_scripts)
	_scripts.setup(_mgr, _player)
	_scripts.start()
	_abilities = AbilityScripts.new()
	_abilities.watch_files = false
	add_child_autofree(_abilities)
	_abilities.setup(_player)
	_abilities.ability.error_backoff_msec = 0
	_abilities.start()
	_panel = ScriptEditorPanel.new()
	add_child_autofree(_panel)
	_panel.bind(_scripts)
	_panel.bind_abilities(_abilities)


func after_each() -> void:
	if is_instance_valid(_panel):
		_panel.close()
	Engine.time_scale = 1.0
	SenseBook.reset()
	if is_instance_valid(_mgr):
		_mgr._behaviors.clear()
	_clear(ScriptLibrary.root_dir())
	_clear(AbilityLibrary.root_dir())


static func _clear(root: String) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)


func test_open_dash_shows_the_equipped_file() -> void:
	assert_false(_panel.editing_dash)
	assert_true(_panel.open_dash())
	assert_true(_panel.editing_dash)
	assert_eq(_panel.file_name, "dash.lua")
	assert_eq(_panel.text(), AbilityLibrary.read("dash.lua"))
	assert_false(_panel.is_dirty())
	assert_false(_panel.file_labels().has("dash.lua"), "the weapon list is unchanged")


func test_save_writes_abilities_and_reloads_the_dash() -> void:
	_panel.open_dash()
	_panel.set_text("return { name = 'Blink', cooldown = 0.6, on_dash = function() end }")
	assert_true(_panel.request_save())
	assert_eq(AbilityLibrary.read("dash.lua"), _panel.text())
	assert_eq(ScriptLibrary.read("dash.lua"), "", "nothing written to shots/")
	_abilities.flush_pending()
	assert_eq(_abilities.ability.title, "Blink")
	assert_string_contains(_panel.status_text(), "Dash runs Blink")
	assert_almost_eq(_player._ability_cooldown, 0.6, 0.0001, "the player re-read the cooldown")


func test_a_bad_save_keeps_the_last_good_dash() -> void:
	_panel.open_dash()
	_panel.set_text("return { on_dash = function(\n end }")
	_panel.request_save()
	_abilities.flush_pending()
	assert_eq(_abilities.ability.title, "Dash")
	assert_string_contains(_panel.status_text(), "Still running the last good dash.")
	assert_eq(_panel.problems().size(), 1)
	assert_eq(_panel.problems()[0].kind, ScriptProblem.Kind.COMPILE)


func test_an_on_dash_error_shows_in_problems_with_its_line() -> void:
	_panel.open_dash()
	_panel.set_text("return {\n  on_dash = function(ctx, dir)\n    error('oops')\n  end,\n}")
	_panel.request_save()
	_abilities.flush_pending()
	_player.request_dash()
	_player._physics_process(1.0 / 60.0)
	_panel.poll_now()
	var probs := _panel.problems()
	assert_eq(probs.size(), 1, str(probs.map(func(p: ScriptProblem) -> String: return p.text())))
	assert_eq(probs[0].kind, ScriptProblem.Kind.RUNTIME)
	assert_eq(probs[0].line, 3)
	assert_eq(probs[0].callback, "on_dash")


func test_switching_back_to_a_weapon_file_saves_to_shots() -> void:
	_panel.open_dash()
	_panel.open_file(ScriptLibrary.DEFAULT_FILE)
	assert_false(_panel.editing_dash)
	_panel.set_text("return { name = 'W' }")
	assert_true(_panel.request_save())
	assert_eq(ScriptLibrary.read(ScriptLibrary.DEFAULT_FILE), "return { name = 'W' }")
	assert_ne(AbilityLibrary.read("dash.lua"), "return { name = 'W' }")


func test_the_starter_menu_offers_the_dash_starters_and_saving_one_equips_it() -> void:
	_panel.open()
	var labels := _panel.starter_labels()
	assert_true(labels.has("Dash: Time-stop dash"), str(labels))
	assert_true(labels.has("Dash: Dash (built-in)"))
	assert_true(_panel.load_starter("dash:time_stop_dash"))
	assert_true(_panel.editing_dash, "the Dash file is opened first")
	assert_string_contains(_panel.text(), "world.time_stop(")
	_panel.request_save()
	_abilities.flush_pending()
	assert_eq(_abilities.ability.title, "Time-stop dash")
	assert_string_contains(AbilityLibrary.read("dash.lua"), "world.time_stop(")
	assert_false(_panel.load_starter("dash:nope"))
