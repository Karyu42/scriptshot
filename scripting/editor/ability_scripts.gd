class_name AbilityScripts
extends Node
## Owns the Dash slot's ability (LuaDashAbility) and the `abilities/` file
## it runs, the way ShotScripts owns the weapon and `shots/`. A child of Main.
##
## * start(): seeds abilities/dash.lua on a fresh save and loads the
##   equipped file. If it loads, the player's dash hook gets the ability
##   (Player.set_dash_ability). If it is missing or does not load, the
##   player keeps the engine's built-in dash and one line is printed; the
##   first good load later hands the ability over.
## * save(): the editor's save. Writes the file and loads it at the next
##   frame boundary. A save that does not load keeps the last good version.
## * PC: the equipped file is polled every WATCH_SEC (real time) and a change
##   reloads it, like ShotScripts. Other abilities/ files are not watched.
##
## The player holds the ability while it is equipped (a freed ability fails
## closed: no dash at all), so this node keeps it alive and hands the player
## back the built-in dash (set_dash_ability(null)) when it leaves the tree.

signal ability_saved(file_name: String, origin: StringName)
## The Dash slot now runs `file_name`.
signal ability_swapped(file_name: String, origin: StringName)
## `file_name` did not load; the previous version (or the engine dash) stays.
signal load_failed(file_name: String, problem: ScriptProblem, origin: StringName)

const WATCH_SEC := 0.5

var ability := LuaDashAbility.new()
var player: Object
## The file the Dash slot runs, "" while on the engine dash.
var equipped := ""
## The file the player chose (it can differ from `equipped` after a failed load).
var selected := AbilityLibrary.DEFAULT_DASH_FILE
var problem: ScriptProblem = null
var warnings: Array[ScriptProblem] = []
var watch_files := OS.has_feature("pc")

var _known_hash := 0
var _pending: Dictionary[String, StringName] = {}
var _flush_queued := false
var _next_watch_msec := 0


func _init() -> void:
	name = "AbilityScripts"
	process_mode = Node.PROCESS_MODE_ALWAYS
	# A yielded on_dash resumes on game ticks, after the player's tick.
	process_physics_priority = 10


func _exit_tree() -> void:
	if equipped != "" and player_has_hook() and player.get("_dash_ability") == ability:
		player.call("set_dash_ability", null)
	equipped = ""


func setup(target_player: Object) -> void:
	player = target_player
	ability.bind_player(target_player)
	# A yielded on_dash does not outlive the life it started in.
	for sig: String in ["died", "respawned"]:
		if player != null and player.has_signal(sig):
			var cb := Callable(self, "_on_player_life_changed")
			if not player.is_connected(sig, cb):
				player.connect(sig, cb)


func _on_player_life_changed(_at: Variant = null) -> void:
	ability.cancel_running()


## True when the player has the dash hook (Player.set_dash_ability).
func player_has_hook() -> bool:
	return player != null and is_instance_valid(player) and player.has_method("set_dash_ability")


## True while the Dash slot runs a file (not the engine dash).
func has_script() -> bool:
	return equipped != "" and ability.has_script()


func start() -> bool:
	AbilityLibrary.seed_default()
	selected = AbilityLibrary.equipped_dash()
	var ok := load_now(selected, ShotScripts.ORIGIN_START)
	_known_hash = AbilityLibrary.read(selected).hash()
	if not ok:
		var shown := AbilityLibrary.display_path(selected)
		var why := "%s is missing." % shown if not AbilityLibrary.exists(selected) else "%s: %s" % [shown, problem.text() if problem != null else "did not load."]
		print("AbilityScripts: %s Using the built-in dash." % why)
	return ok


## Writes `text` to abilities/`file_name` and loads it at the next frame
## boundary. Saving a file equips it in the Dash slot (once it loads).
func save(file_name: String, text: String, origin: StringName = ShotScripts.ORIGIN_EDITOR) -> bool:
	if not AbilityLibrary.write(file_name, text):
		return false
	selected = file_name
	_known_hash = text.hash()
	ability_saved.emit(file_name, origin)
	request_load(file_name, origin)
	return true


func request_load(file_name: String, origin: StringName) -> void:
	_pending[file_name] = origin
	if not _flush_queued:
		_flush_queued = true
		flush_pending.call_deferred()


func has_pending_load() -> bool:
	return not _pending.is_empty()


func flush_pending() -> void:
	_flush_queued = false
	var pending := _pending.duplicate()
	_pending.clear()
	for f: String in pending:
		var origin: StringName = pending[f]
		load_now(f, origin)


## Loads `file_name` into the ability now (outside the physics step).
func load_now(file_name: String, origin: StringName) -> bool:
	if not AbilityLibrary.exists(file_name):
		problem = ScriptProblem.new()
		problem.kind = ScriptProblem.Kind.COMPILE
		problem.message = "%s was not found." % AbilityLibrary.display_path(file_name)
		problem.details = "missing file"
		warnings.clear()
		load_failed.emit(file_name, problem, origin)
		return false
	ability.chunk_name = file_name
	var result := ability.apply(AbilityLibrary.read(file_name))
	if not result.ok:
		problem = ScriptProblem.from_result(result, file_name)
		warnings.clear()
		load_failed.emit(file_name, problem, origin)
		return false
	problem = null
	warnings.clear()
	for w in result.warnings:
		warnings.append(ScriptProblem.from_warning(LuaDashAbility.STATE_WARNING_KEY, w, 1))
	var first := equipped == ""
	equipped = file_name
	selected = file_name
	AbilityLibrary.set_equipped_dash(file_name)
	if first and player_has_hook():
		player.call("set_dash_ability", ability)
	ability_swapped.emit(file_name, origin)
	return true


func _physics_process(_delta: float) -> void:
	# PROCESS_MODE_ALWAYS is for the file watcher; a running on_dash pauses
	# with the game.
	if is_inside_tree() and get_tree().paused:
		return
	ability.tick()


func _process(_delta: float) -> void:
	if not watch_files:
		return
	var now := Time.get_ticks_msec()
	if now < _next_watch_msec:
		return
	_next_watch_msec = now + int(WATCH_SEC * 1000.0)
	poll_files()


## Reloads the equipped file (or the selected one while on the engine dash)
## when it changed on disk. True when a reload was queued.
func poll_files() -> bool:
	var watched := equipped if equipped != "" else selected
	if not AbilityLibrary.exists(watched):
		return false
	var h := AbilityLibrary.read(watched).hash()
	if h == _known_hash:
		return false
	_known_hash = h
	ability_saved.emit(watched, ShotScripts.ORIGIN_FILE)
	request_load(watched, ShotScripts.ORIGIN_FILE)
	return true
