class_name AbilityLibrary
extends RefCounted
## The player's `abilities/` folder (ability-scripting.md A1), next to
## `shots/` (same save directory, so tests use their throwaway one) and with
## the same file name rules (ScriptLibrary.valid_name). The Dash slot equips
## one file from it; `dash.lua` is equipped on a fresh save, seeded once from
## the bundled default (res://scripting/abilities/default_dash.lua.txt, which
## is `.lua.txt` for the reason in ScriptLibrary.BUNDLED_EXT).

const BUNDLED_DIR := "res://scripting/abilities"
const DEFAULT_DASH_ID := "default_dash"
const DEFAULT_DASH_FILE := "dash.lua"
const SLOT_DASH := "dash"
const _STATE_FILE := "abilities.cfg"


## The `abilities/` folder.
static func root_dir() -> String:
	return SaveGame.resolved_path().get_base_dir().path_join("abilities")


static func path_of(file_name: String) -> String:
	if not ScriptLibrary.valid_name(file_name):
		return ""
	return root_dir().path_join(file_name)


## "abilities/dash.lua", for messages.
static func display_path(file_name: String) -> String:
	return "abilities/" + file_name


static func exists(file_name: String) -> bool:
	var path := path_of(file_name)
	return path != "" and FileAccess.file_exists(path)


## The .lua files in abilities/, by name.
static func list_files() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(root_dir())
	if dir == null:
		return out
	for f in dir.get_files():
		if ScriptLibrary.valid_name(f):
			out.append(f)
	out.sort()
	if out.size() > ScriptLibrary.MAX_FILES:
		out.resize(ScriptLibrary.MAX_FILES)
	return out


## The file's text, "" when it is missing.
static func read(file_name: String) -> String:
	var path := path_of(file_name)
	if path == "" or not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


## Writes `text` to abilities/`file_name`, even when it does not compile.
static func write(file_name: String, text: String) -> bool:
	var path := path_of(file_name)
	if path == "" or not _ensure_dir():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


## The bundled default Dash file's text ("" if it is missing from the build).
static func default_dash_source() -> String:
	var path := BUNDLED_DIR.path_join(DEFAULT_DASH_ID + ScriptLibrary.BUNDLED_EXT)
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


## First run only: writes dash.lua from the bundled default. A player who
## deletes it later gets the engine dash, not a fresh copy. True when written.
static func seed_default() -> bool:
	var cfg := _state()
	if cfg.get_value(SLOT_DASH, "seeded", false):
		return false
	var wrote := false
	if not exists(DEFAULT_DASH_FILE):
		var src := default_dash_source()
		wrote = src != "" and write(DEFAULT_DASH_FILE, src)
	cfg.set_value(SLOT_DASH, "seeded", true)
	_save_state(cfg)
	return wrote


## The file the Dash slot equipped last (dash.lua when none was saved).
static func equipped_dash() -> String:
	var v: Variant = _state().get_value(SLOT_DASH, "equipped", DEFAULT_DASH_FILE)
	var n: String = v if v is String else DEFAULT_DASH_FILE
	return n if ScriptLibrary.valid_name(n) else DEFAULT_DASH_FILE


static func set_equipped_dash(file_name: String) -> void:
	if not ScriptLibrary.valid_name(file_name):
		return
	var cfg := _state()
	cfg.set_value(SLOT_DASH, "equipped", file_name)
	_save_state(cfg)


static func _state() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(root_dir().path_join(_STATE_FILE))
	return cfg


static func _save_state(cfg: ConfigFile) -> void:
	if _ensure_dir():
		cfg.save(root_dir().path_join(_STATE_FILE))


static func _ensure_dir() -> bool:
	var dir := root_dir()
	if DirAccess.dir_exists_absolute(dir):
		return true
	return DirAccess.make_dir_recursive_absolute(dir) == OK
