extends GutTest
## The Sense-unlock UX in the editor (vertical-slice §6.3): one toast, the
## Codex page (shown once, inside the editor, with a runnable snippet), the
## autocomplete highlight until a saved script uses the name, and nothing of
## that for a Sense a save restores.

var _mgr: BulletManager
var _player: Player
var _scripts: ShotScripts
var _panel: ScriptEditorPanel


func before_each() -> void:
	ScriptWarnings.reset()
	SenseBook.reset()
	Engine.time_scale = 1.0
	_clear_shots_dir()
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
	_scripts = ShotScripts.new()
	_scripts.watch_files = false
	add_child_autofree(_scripts)
	_scripts.setup(_mgr, _player)
	_scripts.start()
	_panel = ScriptEditorPanel.new()
	add_child_autofree(_panel)
	_panel.bind(_scripts)


func after_each() -> void:
	if is_instance_valid(_panel):
		_panel.close()
	Engine.time_scale = 1.0
	SenseBook.reset()
	if is_instance_valid(_mgr):
		_mgr._behaviors.clear()
	_clear_shots_dir()


static func _clear_shots_dir() -> void:
	var dir := DirAccess.open(ScriptLibrary.root_dir())
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)


func _row(display: String) -> Array:
	for row: Array in _panel.completion_entries():
		if row[0] == display:
			return row
	return []


func _index(display: String) -> int:
	var rows := _panel.completion_entries()
	for i in rows.size():
		var row: Array = rows[i]
		if row[0] == display:
			return i
	return -1


func test_an_unlock_toasts_marks_the_name_and_queues_its_codex_page() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	assert_eq(_panel.toast_text(), "sense.nearest_enemy")
	assert_eq(_panel.fresh_names(), PackedStringArray(["nearest_enemy"]))
	assert_eq(_panel.codex_unread(), PackedStringArray(["nearest_enemy"]))
	assert_false(_panel.codex_visible(), "no modal over the arena")
	assert_false(_panel.starter_locked("homing"), "homing unlocks in the palette")


func test_the_codex_page_opens_once_inside_the_editor() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	_panel.open()
	assert_true(_panel.codex_visible())
	assert_eq(_panel.codex_page(), "nearest_enemy")
	assert_eq(_panel.codex_text(), ScriptEditorPanel.codex_source("nearest_enemy"))
	assert_eq(_panel.codex_unread().size(), 0)
	_panel.close_codex()
	_panel.close()
	_panel.open()
	assert_false(_panel.codex_visible(), "once: the next open shows the code")
	assert_eq(_panel.codex_pages(), PackedStringArray(["nearest_enemy"]), "still listed in the Codex")


func test_an_unlock_while_the_editor_is_open_shows_the_page_now() -> void:
	_panel.open()
	SenseBook.grant(&"enemies_in", 1)
	assert_true(_panel.codex_visible())
	assert_eq(_panel.codex_page(), "enemies_in")
	assert_eq(_panel.toast_text(), "sense.enemies_in")


func test_the_codex_snippet_inserts_and_runs() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	_panel.open()
	assert_true(_panel.insert_codex_snippet())
	assert_false(_panel.codex_visible())
	assert_eq(_panel.text(), ScriptEditorPanel.codex_source("nearest_enemy"))
	assert_true(_panel.request_save())
	await wait_process_frames(3)
	assert_eq(_scripts.weapon.title, "Homing")
	assert_eq(_panel.fresh_names().size(), 0, "a saved script that uses the name ends the highlight")


func test_every_codex_page_is_a_weapon_that_loads() -> void:
	for id: String in ["nearest_enemy", "enemies_in"]:
		var src := ScriptEditorPanel.codex_source(id)
		assert_ne(src, "", id)
		assert_lt(src.split("\n").size(), 45, "about one screen: " + id)
		var host := ScriptHost.new()
		var r := host.load_string(src, id + ".lua")
		assert_true(r.ok, "%s: %s" % [id, r.error])
		assert_true(host.has_callback("on_fire") and host.has_callback("on_batch"), id)


func test_a_quiet_restore_shows_nothing() -> void:
	SenseBook.grant(&"nearest_enemy", 1, true)
	assert_eq(_panel.toast_text(), "")
	assert_eq(_panel.fresh_names().size(), 0)
	assert_eq(_panel.codex_unread().size(), 0)
	_panel.open()
	assert_false(_panel.starter_locked("homing"), "the palette reads the book when the editor opens")
	assert_false(_panel.codex_visible())
	assert_eq(_panel.codex_pages(), PackedStringArray(["nearest_enemy"]))


func test_a_higher_level_does_not_repeat_the_unlock() -> void:
	SenseBook.grant(&"enemies_in", 1)
	_panel.open()
	_panel.close_codex()
	_panel.close()
	_panel.show_toast("")
	SenseBook.grant(&"enemies_in", 2)
	assert_eq(_panel.toast_text(), "")
	assert_eq(_panel.codex_unread().size(), 0)


func test_autocomplete_greys_locked_senses_with_how_they_are_found() -> void:
	var near := _row("nearest_enemy  (3 kills)")
	assert_eq(near, ["nearest_enemy  (3 kills)", "nearest_enemy", ScriptEditorPanel.COLOR_DIM])
	var enemies_in: Array = _row("enemies_in  (found at: ???)")
	var color: Color = enemies_in[2]
	assert_eq(color, ScriptEditorPanel.COLOR_DIM)
	for n: String in ["enemy_bullets", "terrain", "boss", "world"]:
		var row: Array = _row("%s  (found at: ???)" % n)
		var insert: String = row[1]
		assert_eq(insert, n)
	assert_eq(_row("nearest_enemy"), [], "no plain row while locked")


func test_autocomplete_puts_a_fresh_sense_first_until_it_is_used() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var first: Array = _panel.completion_entries()[0]
	assert_eq(first, ["nearest_enemy", "nearest_enemy", ScriptEditorPanel.COLOR_FRESH])
	assert_eq(_row("nearest_enemy  (3 kills)"), [])
	_panel.set_text("return { on_fire = function(ctx) spawn { angle = ctx.aim } end }")
	_panel.request_save()
	assert_eq(_panel.fresh_names().size(), 1, "a save that does not use it keeps the highlight")
	_panel.set_text("local f = sense.nearest_enemy\nreturn { on_fire = function(ctx) spawn { angle = ctx.aim } end }")
	_panel.request_save()
	assert_eq(_panel.fresh_names().size(), 0)
	first = _panel.completion_entries()[0]
	assert_eq(first, ["nearest_enemy", "nearest_enemy", ScriptEditorPanel.COLOR_API], "normal colour, still at the top")
	assert_lt(_index("nearest_enemy"), _index("spawn_child"))
