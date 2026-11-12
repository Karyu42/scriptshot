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
##   last good weapon, like a bad save in the editor.
##
## Lesson checkers listen to the two signals and never parse Lua.

## A shots/ file was written: by the editor (&"editor") or on disk (&"file").
signal script_saved(file_name: String, origin: StringName)
## The weapon now runs `file_name` (&"start", &"editor" or &"file").
signal weapon_swapped(file_name: String, origin: StringName)
## `file_name` did not load; the previous weapon keeps firing.
signal load_failed(file_name: String, problem: ScriptProblem, origin: StringName)

const ORIGIN_START := &"start"
const ORIGIN_EDITOR := &"editor"
const ORIGIN_FILE := &"file"
const WATCH_SEC := 0.5

var weapon: LuaShot
var player: Player
## The file the weapon runs, "" while on BasicShot.
var equipped := ""
## The file the player chose (what start() and the watcher load).
var selected := ScriptLibrary.DEFAULT_FILE
## Why the selected file last failed to load, null when it is running.
var problem: ScriptProblem = null
## Watch the selected file for outside edits (PC builds; tests turn it on).
var watch_files := OS.has_feature("pc")

var _known_hash: Dictionary[String, int] = {}
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
		load_failed.emit(file_name, problem, origin)
		return false
	problem = null
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


## Checks the selected file for an outside change now (the watcher calls this
## every WATCH_SEC). True when it changed and a reload was queued.
func poll_files() -> bool:
	var f := selected
	if not ScriptLibrary.exists(f):
		return false
	var text := ScriptLibrary.read(f)
	var h := text.hash()
	if _known_hash.get(f, 0) == h:
		return false
	_known_hash[f] = h
	script_saved.emit(f, ORIGIN_FILE)
	request_load(f, ORIGIN_FILE)
	return true
