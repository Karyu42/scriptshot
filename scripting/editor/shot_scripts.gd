class_name ShotScripts
extends Node
## Owns the player's scripted weapon and the `shots/` files it comes from
## (vertical-slice §7, SE rows 1 and 3). A child of Main, so the editor and
## the weapon are the same in every room.
##
## * start(): equips the saved file (shots/default.lua on a fresh save). A
##   missing or broken file leaves the player on BasicShot and prints one
##   line; the first good load later swaps the LuaShot in.
## * save(): the editor's save. Writes the file, emits `script_saved`, and
##   loads it at the next frame boundary (call_deferred, never inside the
##   bullet step), so it is live before the next on_fire.
## * PC: the equipped file is polled every WATCH_SEC (real time, so the
##   editor's slow motion does not slow it). A change emits `script_saved`
##   with origin &"file" and reloads. A write that does not load keeps the
##   last good weapon, like a bad save in the editor. A change to another
##   file in shots/ is not loaded; `unequipped_file_saved` lets the editor
##   say so ("shots/foo.lua saved (not equipped)"), rate-limited per file.
##
## Lesson checkers listen to the two signals and never parse Lua.

## The equipped file was written: by the editor's save (&"editor") or on disk
## (&"file", PC). Only ever the equipped file, the one the weapon loads from,
## so a lesson checker can count it as "the player saved their weapon".
## A save that does not load still fires this; `weapon_swapped` or
## `load_failed` follows. Other shots/ files never fire it.
signal script_saved(file_name: String, origin: StringName)
## The weapon now runs `file_name` (&"start", &"editor" or &"file").
signal weapon_swapped(file_name: String, origin: StringName)
## `file_name` did not load; the previous weapon keeps firing.
signal load_failed(file_name: String, problem: ScriptProblem, origin: StringName)
## A shots/ file that is NOT equipped was changed on disk (PC). It is not
## loaded and `script_saved` does not fire. This is a UI notice for the
## editor's toast, rate-limited to once per TOAST_COOLDOWN_MSEC per file;
## lesson checkers should not use it.
signal unequipped_file_saved(file_name: String)

const ORIGIN_START := &"start"
const ORIGIN_EDITOR := &"editor"
const ORIGIN_FILE := &"file"
const WATCH_SEC := 0.5
## Quiet time per file between two "saved (not equipped)" notices.
const TOAST_COOLDOWN_MSEC := 3000

var weapon: LuaShot
var player: Player
## The file the weapon runs, "" while on BasicShot.
var equipped := ""
## The file the player chose (the editor's current file). start() sets this
## to the saved equipped file; save() sets it before the load. It can differ
## from `equipped` after a failed load.
var selected := ScriptLibrary.DEFAULT_FILE
## Why the selected file last failed to load, null when it is running.
var problem: ScriptProblem = null
## Non-fatal notes from the last load that went through (Kind.WARNING): what
## the `state` copy dropped or cut. Empty after a failed load.
var warnings: Array[ScriptProblem] = []
## Watch the equipped file for outside edits (PC builds; tests turn it on).
var watch_files := OS.has_feature("pc")

var _known_hash: Dictionary[String, int] = {}
var _toast_msec: Dictionary[String, int] = {}
## False until the first scan: files already there at start are not news.
var _baselined := false
var _pending: Dictionary[String, StringName] = {}
var _flush_queued := false
var _next_watch_msec := 0


func _init() -> void:
	name = "ShotScripts"
	process_mode = Node.PROCESS_MODE_ALWAYS


## Builds the weapon for `manager`. Call start() after.
func setup(manager: BulletManager, target_player: Player) -> void:
	weapon = LuaShot.new(manager)
	player = target_player


## Seeds default.lua on the first run and equips the saved file.
func start() -> bool:
	ScriptLibrary.seed_default()
	selected = ScriptLibrary.equipped_file()
	var ok := load_now(selected, ORIGIN_START)
	_baseline()
	if not ok:
		var shown := ScriptLibrary.display_path(selected)
		var why := "%s is missing." % shown if not ScriptLibrary.exists(selected) else "%s: %s" % [shown, problem.text() if problem != null else "did not load."]
		print("ShotScripts: %s Using the basic shot." % why)
	return ok


func has_script() -> bool:
	return equipped != "" and weapon != null and weapon.has_script()


## The editor's save: writes `text` to shots/`file_name`, emits
## script_saved, and loads it at the next frame boundary.
func save(file_name: String, text: String, origin: StringName = ORIGIN_EDITOR) -> bool:
	if not ScriptLibrary.write(file_name, text):
		return false
	_known_hash[file_name] = text.hash()
	selected = file_name
	script_saved.emit(file_name, origin)
	request_load(file_name, origin)
	return true


## Loads `file_name` at the next frame boundary (repeats coalesce).
func request_load(file_name: String, origin: StringName) -> void:
	_pending[file_name] = origin
	if not _flush_queued:
		_flush_queued = true
		flush_pending.call_deferred()


func has_pending_load() -> bool:
	return not _pending.is_empty()


## Runs the queued loads now (the deferred call does this at the frame
## boundary; tests call it directly).
func flush_pending() -> void:
	_flush_queued = false
	var pending := _pending.duplicate()
	_pending.clear()
	for f: String in pending:
		var origin: StringName = pending[f]
		load_now(f, origin)


## Loads `file_name` into the weapon right away. Callers must be outside the
## bullet step (save() and the watcher go through request_load()).
func load_now(file_name: String, origin: StringName) -> bool:
	if weapon == null:
		return false
	var text := ScriptLibrary.read(file_name)
	_known_hash[file_name] = text.hash()
	if not ScriptLibrary.exists(file_name):
		problem = ScriptProblem.new()
		problem.kind = ScriptProblem.Kind.COMPILE
		problem.message = "%s was not found." % ScriptLibrary.display_path(file_name)
		problem.details = "missing file"
		load_failed.emit(file_name, problem, origin)
		return false
	weapon.chunk_name = file_name
	var result := weapon.apply(text)
	if not result.ok:
		problem = ScriptProblem.from_result(result, file_name)
		warnings.clear()
		load_failed.emit(file_name, problem, origin)
		return false
	problem = null
	warnings.clear()
	for w in result.warnings:
		warnings.append(ScriptProblem.from_warning(LuaShot.STATE_WARNING_KEY, w, 1))
	equipped = file_name
	selected = file_name
	ScriptLibrary.set_equipped_file(file_name)
	if player != null and player.weapon != weapon:
		player.weapon = weapon
	weapon_swapped.emit(file_name, origin)
	return true


func _process(_delta: float) -> void:
	if not watch_files:
		return
	var now := Time.get_ticks_msec()
	if now < _next_watch_msec:
		return
	_next_watch_msec = now + int(WATCH_SEC * 1000.0)
	poll_files()


## The file hot reload and `script_saved` follow: the one the weapon runs,
## or `selected` when BasicShot is running (equipped is empty). start()
## seeds `selected`; a later failed load of a different file updates it,
## so a fix of that file can still load. Does not re-read editor.cfg.
func watched_file() -> String:
	return equipped if not equipped.is_empty() else selected


## Checks shots/ for outside changes now (the watcher calls this every
## WATCH_SEC). The equipped file reloads; a change to any other file only
## raises `unequipped_file_saved` (rate-limited per file) so the player sees
## it was saved and is not running. When a load failed and BasicShot is
## running, the intended equipped file is still watched so a later fix can
## load. True when the equipped file changed and a reload was queued.
## `now_msec` is for tests.
func poll_files(now_msec: int = -1) -> bool:
	var now := now_msec if now_msec >= 0 else Time.get_ticks_msec()
	var reloaded := false
	var present: Dictionary[String, bool] = {}
	var watched := watched_file()
	for f in ScriptLibrary.list_files():
		present[f] = true
		var h := ScriptLibrary.read(f).hash()
		if not _known_hash.has(f):
			_known_hash[f] = h
			if not _baselined:
				continue
		elif _known_hash[f] == h:
			continue
		_known_hash[f] = h
		if f == watched:
			script_saved.emit(f, ORIGIN_FILE)
			request_load(f, ORIGIN_FILE)
			reloaded = true
		else:
			_note_unequipped(f, now)
	# Forget deleted files, so a file written again later is news.
	for f: String in _known_hash.keys():
		if not present.has(f):
			_known_hash.erase(f)
	_baselined = true
	return reloaded


## Remembers every file in shots/ as it is now, so only later changes count.
func _baseline() -> void:
	for f in ScriptLibrary.list_files():
		_known_hash[f] = ScriptLibrary.read(f).hash()
	_baselined = true


## "shots/foo.lua saved (not equipped)".
static func unequipped_text(file_name: String) -> String:
	return "%s saved (not equipped)" % ScriptLibrary.display_path(file_name)


func _note_unequipped(file_name: String, now: int) -> void:
	var last: int = _toast_msec.get(file_name, -TOAST_COOLDOWN_MSEC)
	if now - last < TOAST_COOLDOWN_MSEC:
		return
	_toast_msec[file_name] = now
	unequipped_file_saved.emit(file_name)
