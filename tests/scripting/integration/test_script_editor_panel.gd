extends GutTest
## ScriptEditorPanel: the palette (homing locked until nearest_enemy), slow
## time while open, the one-line error with its marker and details, saving
## through ShotScripts, and the read-only shard footer.

var _mgr: BulletManager
var _player: Player
var _scripts: ShotScripts
var _panel: ScriptEditorPanel
var _shards := 0


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
	_panel.shards_source = func() -> int: return _shards
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


func test_the_palette_has_five_rows_and_homing_is_locked() -> void:
	var labels := _panel.starter_labels()
	assert_eq(labels.size(), 5)
	assert_eq(labels[0], "Straight")
	assert_eq(labels[4], "Homing  (locked: needs nearest_enemy)")
	assert_true(_panel.starter_locked("homing"))
	assert_false(_panel.starter_locked("spread"))
	var before := _panel.text()
	assert_false(_panel.load_starter("homing"), "a locked row does not insert")
	assert_eq(_panel.text(), before)
	assert_true(_panel.load_starter("spread"))
	assert_eq(_panel.text(), ScriptLibrary.starter("spread").source)


func test_granting_nearest_enemy_unlocks_the_homing_row() -> void:
	var seen: Array[String] = []
	var cb := func(id: StringName, level: int) -> void: seen.append("%s:%d" % [id, level])
	SenseBook.events.granted.connect(cb)
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.events.granted.disconnect(cb)
	assert_eq(seen, ["nearest_enemy:1"] as Array[String], "granted fires once per rise")
	assert_true(SenseBook.unlocked(&"sense.nearest_enemy"))
	assert_false(_panel.starter_locked("homing"))
	assert_eq(_panel.starter_labels()[4], "Homing")
	assert_true(_panel.load_starter("homing"))


func test_opening_slows_time_and_blocks_player_input_closing_restores_it() -> void:
	_panel.open()
	assert_true(_panel.is_open())
	assert_almost_eq(Engine.time_scale, ScriptEditorPanel.OPEN_TIME_SCALE, 1e-6)
	assert_almost_eq(Engine.time_scale, 0.15, 1e-6)
	assert_true(_player.input_blocked)
	assert_false(get_tree().paused, "the world keeps moving")
	_panel.close()
	assert_eq(Engine.time_scale, 1.0, "time scale is 1 when the editor is shut")
	assert_false(_player.input_blocked)


func test_the_e_key_opens_it() -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	ev.pressed = true
	assert_true(ev.is_action_pressed("script_editor"), "E is the editor key")
	_panel._unhandled_input(ev)
	assert_true(_panel.is_open())
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_X
	pad.pressed = true
	assert_true(pad.is_action_pressed("script_editor"), "gamepad X (the edit face button)")


func test_a_bad_save_shows_one_line_a_marker_and_details_on_request() -> void:
	_panel.set_text("return {\n  name = 'Bad',\n  on_fire = function(ctx)\n    spawn { angle = ctx.aim speed = 1 }\n  end,\n}")
	assert_true(_panel.request_save())
	_scripts.flush_pending()
	assert_eq(_panel.status_text(), "line 4: expected '}' before 'speed'. Still running the last good script.")
	assert_eq(_panel.marked_lines(), PackedInt32Array([4]))
	assert_eq(_scripts.weapon.title, "Straight")
	assert_false(_panel.details_visible(), "no stack or raw text by default")
	_panel.set_show_details(true)
	assert_true(_panel.details_visible())
	_panel.jump_to_line(4)
	assert_eq(_panel._code.get_caret_line(), 3)
	_panel.set_text(ScriptLibrary.starter("spiral").source)
	_panel.request_save()
	_scripts.flush_pending()
	assert_string_starts_with(_panel.status_text(), "Saved. Running Spiral.")
	assert_eq(_panel.marked_lines().size(), 0)


func test_a_runtime_error_from_play_is_listed_with_its_line() -> void:
	_panel.set_text("return {\n  on_fire = function(ctx)\n    local t = nil\n    return t.x\n  end,\n}")
	_panel.request_save()
	_scripts.flush_pending()
	var ctx := ShotContext.new()
	for i in 3:
		_scripts.weapon.fire(ctx, _mgr.emitter)
	_panel.poll_now()
	var all := _panel.problems()
	assert_eq(all.size(), 1)
	assert_eq(all[0].text(), "line 4: 't' is nil, so it has no fields. Is it defined?  ×3")
	assert_eq(_panel.marked_lines(), PackedInt32Array([4]))
	assert_string_ends_with(_panel.status_text(), "Still running the last good script.")


## What a save's `state` copy dropped is listed as a warning; the save still
## goes through, and the next clean save clears it.
func test_a_state_copy_note_is_listed_as_a_warning() -> void:
	_panel.set_text("state.cb = function() end\nstate.n = 1\nreturn { name = 'A' }")
	_panel.request_save()
	_scripts.flush_pending()
	assert_eq(_panel.problems().size(), 0, "nothing to copy on the first save")
	_panel.set_text("return { name = 'B' .. state.n }")
	_panel.request_save()
	_scripts.flush_pending()
	assert_string_starts_with(_panel.status_text(), "Saved. Running B1.")
	var all := _panel.problems()
	assert_eq(all.size(), 1)
	if all.size() == 1:
		assert_eq(all[0].kind, ScriptProblem.Kind.WARNING)
		assert_string_starts_with(all[0].text(), "state.cb is a function; state keeps only plain data")
	assert_eq(_panel.marked_lines().size(), 0)
	_panel.set_text("return { name = 'C' }")
	_panel.request_save()
	_scripts.flush_pending()
	assert_eq(_panel.problems().size(), 0)
	var tracker: Object = gut.error_tracker
	for e: Object in tracker.call("get_errors_for_test"):
		if str(e.get("code")).begins_with("LuaShot: "):
			e.set("handled", true)


func test_the_footer_shows_shards_read_only() -> void:
	_shards = 3
	_panel.poll_now()
	assert_eq(_panel.footer_text(), "shards 3")


func test_files_picker_and_new_file() -> void:
	assert_eq(_panel.file_labels(), PackedStringArray(["default.lua"]))
	_panel.set_text("return { name = 'Two' }")
	var n := _panel.new_file()
	assert_eq(n, "shot_2.lua")
	_scripts.flush_pending()
	assert_eq(_scripts.equipped, "shot_2.lua")
	assert_eq(_panel.file_labels(), PackedStringArray(["default.lua", "shot_2.lua"]))
	_panel.open_file("default.lua")
	assert_eq(_panel.text(), ScriptLibrary.starter("straight").source)
	assert_eq(_scripts.equipped, "shot_2.lua", "opening a file does not equip it until it is saved")


func test_an_outside_change_to_another_file_shows_a_toast() -> void:
	assert_eq(_panel.toast_text(), "")
	var f := FileAccess.open(ScriptLibrary.path_of("foo.lua"), FileAccess.WRITE)
	f.store_string("return { name = 'Foo' }")
	f.close()
	_scripts.poll_files()
	assert_eq(_panel.toast_text(), "shots/foo.lua saved (not equipped)", "shown with the editor closed")
	assert_false(_panel.is_open())
	assert_eq(_scripts.weapon.title, "Straight")
	assert_false(_panel.status_text().contains("Still running"), "no error line: %s" % _panel.status_text())
	assert_eq(_panel.load_problems.size(), 0, "not shown as a failed reload")


func _e_key(pressed: bool, echo := false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_E
	ev.keycode = KEY_E
	ev.pressed = pressed
	ev.echo = echo
	ev.unicode = "e".unicode_at(0) if pressed else 0
	return ev


func test_the_opening_key_does_not_type_into_the_buffer() -> void:
	var before := _panel.text()
	var press := _e_key(true)
	assert_true(press.is_action_pressed("script_editor"), "E is the editor key")
	_panel._unhandled_input(press)
	assert_true(_panel.is_open())
	# The same press and its repeats must not land in the buffer, even if
	# they also reach CodeEdit (the old path focused it on the opening frame).
	_panel._input(press)
	var echo := _e_key(true, true)
	_panel._input(echo)
	assert_eq(_panel.text(), before, "the opening E and its repeats do not type")
	assert_false(_panel._code.has_focus(), "focus waits for keyup")
	var rel := _e_key(false)
	_panel._input(rel)
	assert_true(_panel._code.has_focus(), "the code view takes focus once E is up")
	assert_eq(_panel.text(), before)


func test_gamepad_x_opens_without_changing_the_buffer() -> void:
	var before := _panel.text()
	var press := InputEventJoypadButton.new()
	press.button_index = JOY_BUTTON_X
	press.pressed = true
	assert_true(press.is_action_pressed("script_editor"))
	_panel._unhandled_input(press)
	assert_true(_panel.is_open())
	_panel._input(press)
	assert_eq(_panel.text(), before)
	assert_false(_panel._code.has_focus())
	var rel := InputEventJoypadButton.new()
	rel.button_index = JOY_BUTTON_X
	rel.pressed = false
	_panel._input(rel)
	assert_true(_panel._code.has_focus())
	assert_eq(_panel.text(), before)


func test_inserting_a_starter_clears_the_last_load_error() -> void:
	_panel.set_text("return {\n  name = 'Bad',\n  on_fire = function(ctx)\n    spawn { angle = ctx.aim speed = 1 }\n  end,\n}")
	assert_true(_panel.request_save())
	_scripts.flush_pending()
	assert_eq(_panel.marked_lines(), PackedInt32Array([4]))
	assert_eq(_panel.problems().size(), 1)
	_panel.set_show_details(true)
	assert_true(_panel.details_visible())
	assert_true(_panel.load_starter("spread"))
	assert_eq(_panel.load_problems.size(), 0)
	assert_eq(_panel.problems().size(), 0)
	assert_eq(_panel.marked_lines().size(), 0)
	assert_false(_panel.details_visible(), "details hide when there is no problem")
	assert_string_starts_with(_panel.status_text(), "Inserted Spread.")


func test_details_and_the_toast_do_not_crowd_the_footer() -> void:
	# Anchors keep the toast in the playfield at both shipping sizes.
	for width: float in [1280.0, 1920.0]:
		var toast_right: float = ScriptEditorPanel.EDITOR_ANCHOR_LEFT * width - 12.0
		var frame_left: float = ScriptEditorPanel.EDITOR_ANCHOR_LEFT * width
		assert_lt(toast_right, frame_left, "toast stays left of the editor at width %s" % width)
	_panel.open()
	_panel.set_text("return {\n  name = 'Bad',\n  on_fire = function(ctx)\n    spawn { angle = ctx.aim speed = 1 }\n  end,\n}")
	assert_true(_panel.request_save())
	_scripts.flush_pending()
	_panel.set_show_details(true)
	_panel.show_toast("shots/foo.lua saved (not equipped)")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(_panel.details_visible())
	var details_r: Rect2 = _panel._details.get_global_rect()
	var footer_r: Rect2 = _panel._footer.get_global_rect()
	var toast_r: Rect2 = _panel._toast.get_global_rect()
	var frame_r: Rect2 = _panel._frame.get_global_rect()
	assert_gt(details_r.size.y, 0.0, "details have height")
	assert_lt(details_r.end.y, footer_r.position.y, "details sit above the footer")
	assert_almost_eq(_panel._toast.anchor_right, ScriptEditorPanel.EDITOR_ANCHOR_LEFT, 0.001)
	assert_lt(toast_r.end.x, frame_r.position.x + 1.0, "toast stays left of the editor")
	assert_false(toast_r.intersects(details_r), "toast does not overlap details")
	assert_false(toast_r.intersects(footer_r), "toast does not overlap the footer")
	_panel.close()
	_panel.show_toast("shots/foo.lua saved (not equipped)")
	await get_tree().process_frame
	assert_almost_eq(_panel._toast.anchor_right, 1.0, 0.001, "full-width toast when the editor is shut")
