extends GutTest
## ShotScripts and the shots/ folder (slice §7, SE rows 1 and 3): equip
## shots/default.lua at start with a BasicShot fallback, save and load
## round-trips, the save / swap signals lesson checkers use, and the PC file
## watcher (a good write reloads, a broken write does not).

var _mgr: BulletManager
var _player: Player
var _scripts: ShotScripts
var _saved: Array[String] = []
var _swapped: Array[String] = []
var _failed: Array[String] = []


func before_each() -> void:
	ScriptWarnings.reset()
	_clear_shots_dir()
	_saved.clear()
	_swapped.clear()
	_failed.clear()
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
	_scripts = _make()


func after_each() -> void:
	if is_instance_valid(_mgr):
		_mgr._behaviors.clear()
	_clear_shots_dir()


func _make() -> ShotScripts:
	var s := ShotScripts.new()
	s.watch_files = false
	add_child_autofree(s)
	s.setup(_mgr, _player)
	s.script_saved.connect(func(f: String, o: StringName) -> void: _saved.append("%s:%s" % [f, o]))
	s.weapon_swapped.connect(func(f: String, o: StringName) -> void: _swapped.append("%s:%s" % [f, o]))
	s.load_failed.connect(func(f: String, _p: ScriptProblem, o: StringName) -> void: _failed.append("%s:%s" % [f, o]))
	return s


static func _clear_shots_dir() -> void:
	var root := ScriptLibrary.root_dir()
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)


func _write_outside(file_name: String, text: String) -> void:
	var f := FileAccess.open(ScriptLibrary.path_of(file_name), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func test_a_fresh_save_equips_default_lua_the_straight_starter() -> void:
	assert_true(_scripts.start())
	assert_eq(ScriptLibrary.read("default.lua"), ScriptLibrary.starter("straight").source)
	assert_eq(_scripts.equipped, "default.lua")
	assert_eq(_player.weapon, _scripts.weapon, "the LuaShot replaces BasicShot")
	assert_eq(_scripts.weapon.title, "Straight")
	assert_eq(_swapped, ["default.lua:start"] as Array[String])
	assert_almost_eq(_player.weapon.fire_interval, 0.25, 1e-6)


func test_a_missing_default_falls_back_to_basic_shot() -> void:
	assert_true(_scripts.start())
	DirAccess.remove_absolute(ScriptLibrary.path_of("default.lua"))
	_player.weapon = BasicShot.new()
	var again := _make()
	assert_false(again.start(), "seeded once: a deleted default.lua is not rewritten")
	assert_true(_player.weapon is BasicShot)
	assert_eq(again.equipped, "")
	assert_false(again.has_script())
	assert_string_contains(again.problem.message, "shots/default.lua was not found")


func test_a_broken_default_falls_back_then_a_good_save_equips() -> void:
	ScriptLibrary.seed_default()
	ScriptLibrary.write("default.lua", "return { on_fire = function(ctx) spawn { angle = 1 2 } end }")
	assert_false(_scripts.start())
	assert_true(_player.weapon is BasicShot)
	assert_eq(_scripts.problem.headline(_scripts.has_script()), "line 1: expected '}' before '2'. Still running the basic shot.")
	assert_true(_scripts.save("default.lua", ScriptLibrary.starter("spread").source))
	assert_eq(_swapped.size(), 0, "the load waits for the frame boundary")
	assert_true(_scripts.has_pending_load())
	_scripts.flush_pending()
	assert_eq(_player.weapon, _scripts.weapon)
	assert_eq(_scripts.weapon.title, "Spread")
	assert_eq(_saved, ["default.lua:editor"] as Array[String])
	assert_eq(_swapped, ["default.lua:editor"] as Array[String])


func test_a_save_is_loaded_at_the_next_frame_boundary() -> void:
	_scripts.start()
	_scripts.save("default.lua", ScriptLibrary.starter("spiral").source)
	assert_eq(_scripts.weapon.title, "Straight", "not mid-frame")
	await wait_process_frames(2)
	assert_eq(_scripts.weapon.title, "Spiral")


func test_a_bad_save_keeps_the_last_good_weapon_and_the_text() -> void:
	_scripts.start()
	var bad := "return {\n  name = 'Oops',\n  on_fire = function(ctx)\n    spawn { angle = ctx.aim speed = 2 }\n  end,\n}"
	_scripts.save("default.lua", bad)
	_scripts.flush_pending()
	assert_eq(_scripts.weapon.title, "Straight")
	assert_eq(_failed, ["default.lua:editor"] as Array[String])
	assert_eq(_scripts.problem.line, 4)
	assert_string_ends_with(_scripts.problem.headline(_scripts.has_script()), "Still running the last good script.")
	assert_eq(ScriptLibrary.read("default.lua"), bad, "the broken text is saved, so no work is lost")


func test_save_and_load_round_trip_and_the_equipped_file_is_remembered() -> void:
	_scripts.start()
	var text := "-- mine\nreturn { name = 'Mine', cooldown = 0.5 }\n"
	_scripts.save("mine.lua", text)
	_scripts.flush_pending()
	assert_eq(ScriptLibrary.read("mine.lua"), text)
	assert_eq(ScriptLibrary.equipped_file(), "mine.lua")
	assert_eq(ScriptLibrary.list_files(), PackedStringArray(["default.lua", "mine.lua"]))
	var next := _make()
	assert_true(next.start())
	assert_eq(next.equipped, "mine.lua", "a restart equips the file saved last")
	assert_eq(next.weapon.title, "Mine")


func test_file_names_stay_inside_shots() -> void:
	for bad: String in ["../x.lua", "a/b.lua", "x.txt", ".lua", "x.y.lua", ""]:
		assert_false(ScriptLibrary.valid_name(bad), bad)
		assert_false(ScriptLibrary.write(bad, "x"), bad)
	assert_true(ScriptLibrary.valid_name("my_shot-2.lua"))
	assert_eq(ScriptLibrary.next_free_name(), "shot_2.lua")


func test_the_watcher_reloads_a_good_write_and_ignores_its_own() -> void:
	_scripts.start()
	assert_false(_scripts.poll_files(), "nothing changed")
	_scripts.save("default.lua", ScriptLibrary.starter("spread").source)
	_scripts.flush_pending()
	assert_false(_scripts.poll_files(), "the editor's own write is not an outside change")
	_saved.clear()
	_swapped.clear()
	_write_outside("default.lua", ScriptLibrary.starter("straight").source.replace("speed = 480", "speed = 700"))
	assert_true(_scripts.poll_files())
	_scripts.flush_pending()
	assert_eq(_saved, ["default.lua:file"] as Array[String], "a PC file change counts as a save")
	assert_eq(_swapped, ["default.lua:file"] as Array[String])
	assert_eq(_scripts.weapon.title, "Straight")


func test_a_broken_write_does_not_reload() -> void:
	_scripts.start()
	_write_outside("default.lua", "return { name = 'Half', on_fire = function(ctx)")
	assert_true(_scripts.poll_files())
	_scripts.flush_pending()
	assert_eq(_scripts.weapon.title, "Straight", "the last good weapon keeps firing")
	assert_eq(_failed, ["default.lua:file"] as Array[String])
	_write_outside("default.lua", ScriptLibrary.starter("spiral").source)
	assert_true(_scripts.poll_files())
	_scripts.flush_pending()
	assert_eq(_scripts.weapon.title, "Spiral", "the finished write loads")


func test_the_watcher_runs_on_its_own_in_real_time() -> void:
	_scripts.start()
	_scripts.watch_files = true
	_write_outside("default.lua", ScriptLibrary.starter("spiral").source)
	await wait_seconds(ShotScripts.WATCH_SEC * 2.5)
	assert_eq(_scripts.weapon.title, "Spiral")


func test_a_change_to_a_file_that_is_not_equipped_is_announced_not_loaded() -> void:
	ScriptLibrary.write("other.lua", "return { name = 'Other' }")
	_scripts.start()
	var notices: Array[String] = []
	_scripts.unequipped_file_saved.connect(func(f: String) -> void: notices.append(f))
	assert_false(_scripts.poll_files(1000), "files already there at start are not news")
	assert_eq(notices.size(), 0)
	_write_outside("other.lua", "return { name = 'Other 2' }")
	assert_false(_scripts.poll_files(2000), "only the equipped file reloads")
	_scripts.flush_pending()
	assert_eq(notices, ["other.lua"] as Array[String])
	assert_eq(ShotScripts.unequipped_text("other.lua"), "shots/other.lua saved (not equipped)")
	assert_eq(_scripts.weapon.title, "Straight", "the weapon is unchanged")
	assert_eq(_failed.size(), 0, "and it is not a failed reload")
	assert_eq(_saved.size(), 0, "script_saved is only for the equipped file")
	# Repeated writes inside the cooldown do not repeat the notice.
	for i in 5:
		_write_outside("other.lua", "return { name = 'Other %d' }" % (i + 3))
		_scripts.poll_files(2500 + i * 100)
	assert_eq(notices.size(), 1, "rate-limited per file")
	_write_outside("other.lua", "return { name = 'Later' }")
	_scripts.poll_files(2000 + ShotScripts.TOAST_COOLDOWN_MSEC + 1)
	assert_eq(notices.size(), 2, "after the cooldown it is announced again")
	# A new file dropped into shots/ is news too; another file has its own cooldown.
	_write_outside("fresh.lua", "return {}")
	_scripts.poll_files(2000 + ShotScripts.TOAST_COOLDOWN_MSEC + 2)
	assert_eq(notices, ["other.lua", "other.lua", "fresh.lua"] as Array[String])
	# A broken file that is not equipped is announced the same way and never loaded.
	_write_outside("fresh.lua", "return {")
	_scripts.poll_files(2000 + 2 * ShotScripts.TOAST_COOLDOWN_MSEC + 10)
	_scripts.flush_pending()
	assert_eq(notices.size(), 4)
	assert_eq(_failed.size(), 0)


func test_script_saved_is_only_for_the_equipped_file() -> void:
	ScriptLibrary.write("other.lua", "return { name = 'Other' }")
	_scripts.start()
	# Not equipped: written on disk, nothing for checkers.
	_write_outside("other.lua", "return { name = 'Fast', speed = 900 }")
	_scripts.poll_files(1000)
	_scripts.flush_pending()
	assert_eq(_saved.size(), 0)
	# Equipped: written on disk and saved in the editor both fire it.
	_write_outside("default.lua", ScriptLibrary.starter("spread").source)
	_scripts.poll_files(2000)
	_scripts.flush_pending()
	assert_eq(_saved, ["default.lua:file"] as Array[String])
	_scripts.save("default.lua", ScriptLibrary.starter("straight").source)
	_scripts.flush_pending()
	assert_eq(_saved, ["default.lua:file", "default.lua:editor"] as Array[String])
	# Saving another file in the editor equips it, so it fires for that file.
	_scripts.save("other.lua", "return { name = 'Other' }")
	_scripts.flush_pending()
	assert_eq(_saved[-1], "other.lua:editor")
	assert_eq(_scripts.equipped, "other.lua")
	# And now default.lua is the one that is not equipped.
	_write_outside("default.lua", ScriptLibrary.starter("spiral").source)
	_scripts.poll_files(9000)
	_scripts.flush_pending()
	assert_eq(_saved.size(), 3, "a change to the old file does not count")
	assert_eq(_scripts.weapon.title, "Other")


func test_the_watcher_follows_the_equipped_file_after_a_failed_load() -> void:
	# default.lua is running. Saving a broken other.lua leaves selected on
	# the new file, but the weapon is still default.lua.
	_scripts.start()
	_scripts.save("other.lua", "return { name = 'Broken', on_fire = function(ctx)")
	_scripts.flush_pending()
	assert_eq(_scripts.selected, "other.lua")
	assert_eq(_scripts.equipped, "default.lua")
	assert_ne(_scripts.selected, _scripts.equipped)
	assert_eq(_scripts.watched_file(), "default.lua")
	assert_eq(_scripts.weapon.title, "Straight")
	_saved.clear()
	_swapped.clear()
	_failed.clear()
	var notices: Array[String] = []
	_scripts.unequipped_file_saved.connect(func(f: String) -> void: notices.append(f))
	# A disk change to the file that is still running should reload it.
	_write_outside("default.lua", ScriptLibrary.starter("spread").source)
	assert_true(_scripts.poll_files(1000))
	_scripts.flush_pending()
	assert_eq(_saved, ["default.lua:file"] as Array[String])
	assert_eq(_swapped, ["default.lua:file"] as Array[String])
	assert_eq(_scripts.weapon.title, "Spread")
	assert_eq(notices.size(), 0)
	# The successful reload of default.lua set selected = equipped. Re-break
	# other.lua so the second half really has selected != equipped.
	_scripts.save("other.lua", "return { name = 'Broken', on_fire = function(ctx)")
	_scripts.flush_pending()
	assert_eq(_scripts.selected, "other.lua")
	assert_eq(_scripts.equipped, "default.lua")
	assert_ne(_scripts.selected, _scripts.equipped)
	assert_eq(_scripts.watched_file(), "default.lua")
	_saved.clear()
	_failed.clear()
	# A disk change to the selected-but-not-equipped file is only a notice.
	_write_outside("other.lua", "return { name = 'Other' }")
	assert_false(_scripts.poll_files(2000), "selected is not the watch target")
	_scripts.flush_pending()
	assert_eq(notices, ["other.lua"] as Array[String])
	assert_eq(_saved.size(), 0, "script_saved stays on the equipped file")
	assert_eq(_scripts.weapon.title, "Spread")
	assert_eq(_failed.size(), 0)
	assert_eq(_scripts.equipped, "default.lua")


func test_the_watcher_still_reloads_when_basic_shot_is_running() -> void:
	# A failed start leaves the player on BasicShot (equipped == "") but
	# still watches the intended equipped file so a later fix can load.
	ScriptLibrary.seed_default()
	ScriptLibrary.write("default.lua", "return { on_fire = function(ctx) spawn { angle = 1 2 } end }")
	assert_false(_scripts.start())
	assert_true(_player.weapon is BasicShot)
	assert_eq(_scripts.equipped, "")
	assert_eq(_scripts.selected, "default.lua")
	assert_ne(_scripts.selected, _scripts.equipped)
	assert_eq(_scripts.watched_file(), "default.lua")
	_write_outside("default.lua", ScriptLibrary.starter("spiral").source)
	assert_true(_scripts.poll_files(1000), "the intended equipped file is still watched")
	_scripts.flush_pending()
	assert_eq(_player.weapon, _scripts.weapon)
	assert_eq(_scripts.equipped, "default.lua")
	assert_eq(_scripts.weapon.title, "Spiral")
	assert_eq(_saved, ["default.lua:file"] as Array[String])


func test_the_watcher_follows_selected_when_basic_shot_is_running() -> void:
	# start() failed, so the player is on BasicShot (equipped == "") and
	# ScriptLibrary.equipped_file() is still default.lua. Saving a broken
	# other.lua updates selected but not the saved equipped file. The
	# watcher must follow selected so a later fix of other.lua can load.
	ScriptLibrary.seed_default()
	ScriptLibrary.write("default.lua", "return { on_fire = function(ctx) spawn { angle = 1 2 } end }")
	assert_false(_scripts.start())
	assert_true(_player.weapon is BasicShot)
	assert_eq(_scripts.equipped, "")
	assert_eq(_scripts.selected, "default.lua")
	assert_eq(ScriptLibrary.equipped_file(), "default.lua")
	_scripts.save("other.lua", "return { name = 'Broken', on_fire = function(ctx)")
	_scripts.flush_pending()
	assert_eq(_scripts.selected, "other.lua")
	assert_eq(_scripts.equipped, "")
	assert_eq(ScriptLibrary.equipped_file(), "default.lua", "a failed load does not update the saved equipped file")
	assert_eq(_scripts.watched_file(), "other.lua")
	_saved.clear()
	_failed.clear()
	var notices: Array[String] = []
	_scripts.unequipped_file_saved.connect(func(f: String) -> void: notices.append(f))
	# A disk change to the last saved equipped file is only a notice.
	_write_outside("default.lua", ScriptLibrary.starter("spread").source)
	assert_false(_scripts.poll_files(1000), "the saved equipped file is not the watch target")
	_scripts.flush_pending()
	assert_eq(notices, ["default.lua"] as Array[String])
	assert_eq(_saved.size(), 0)
	assert_true(_player.weapon is BasicShot)
	# A fix of the selected file still loads.
	_write_outside("other.lua", "return { name = 'Other' }")
	assert_true(_scripts.poll_files(2000), "the selected file is still watched")
	_scripts.flush_pending()
	assert_eq(_saved, ["other.lua:file"] as Array[String])
	assert_eq(_player.weapon, _scripts.weapon)
	assert_eq(_scripts.equipped, "other.lua")
	assert_eq(_scripts.weapon.title, "Other")
	assert_eq(_failed.size(), 0)
