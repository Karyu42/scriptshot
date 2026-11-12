class_name ScriptLibrary
extends RefCounted
## Starter scripts (res://scripting/starters, the editor's palette) and the
## player's `shots/` folder on disk.
##
## `shots/` sits next to the save file (SaveGame.resolved_path()), so the
## game uses user://shots/ and tests write into their throwaway directory,
## never the player's. On PC players can edit these files in any editor; the
## game watches the equipped one (ShotScripts). `default.lua` is the file
## equipped on a fresh save, seeded once from the straight starter.

const STARTER_DIR := "res://scripting/starters"
## Shown in this order. Listed here because exported builds cannot always list
## res:// folders.
const STARTERS: PackedStringArray = ["straight", "spread", "spiral", "split_on_hit", "homing"]
const DEFAULT_STARTER := "straight"
const DEFAULT_FILE := "default.lua"
const _STATE_FILE := "editor.cfg"
## Most files the folder picker lists.
const MAX_FILES := 64


class Starter:
	extends RefCounted
	var id := ""
	var title := ""
	var source := ""
	## Sense names the starter needs ("sense.nearest_enemy"); empty for none.
	var needs := PackedStringArray()

	func unlocked() -> bool:
		return SenseBook.all_unlocked(needs)

	## Hint shown in the picker while locked: "needs nearest_enemy".
	func lock_hint() -> String:
		var names := PackedStringArray()
		for n in needs:
			names.append(n.trim_prefix("sense."))
		return "needs " + ", ".join(names)


static func starter(id: String) -> Starter:
	var path := STARTER_DIR.path_join(id + ".lua")
	if not FileAccess.file_exists(path):
		return null
	var s := Starter.new()
	s.id = id
	s.source = FileAccess.get_file_as_string(path)
	s.title = _title_of(s.source, id)
	s.needs = _needs_of(s.source)
	return s


static func starters() -> Array[Starter]:
	var out: Array[Starter] = []
	for id in STARTERS:
		var s := starter(id)
		if s != null:
			out.append(s)
	return out


## `name = "..."` in the table, else the id.
static func _title_of(source: String, id: String) -> String:
	var m := RegEx.create_from_string("(?m)^\\s*name\\s*=\\s*\"([^\"]+)\"").search(source)
	if m != null:
		return m.get_string(1)
	return id.replace("_", " ").capitalize()


## `-- needs: sense.a, sense.b` header line.
static func _needs_of(source: String) -> PackedStringArray:
	var out := PackedStringArray()
	var m := RegEx.create_from_string("(?m)^--\\s*needs:\\s*(.+)$").search(source)
	if m == null:
		return out
	for part in m.get_string(1).split(","):
		var n := part.strip_edges()
		if n != "":
			out.append(n)
	return out


## The `shots/` folder.
static func root_dir() -> String:
	return SaveGame.resolved_path().get_base_dir().path_join("shots")


## Absolute path of `file_name` in shots/, "" for a name that is not a plain
## `name.lua` (no folders, no dots before the extension).
static func path_of(file_name: String) -> String:
	if not valid_name(file_name):
		return ""
	return root_dir().path_join(file_name)


static func valid_name(file_name: String) -> bool:
	return RegEx.create_from_string("^[A-Za-z0-9_-]{1,40}\\.lua$").search(file_name) != null


## "shots/default.lua", for messages.
static func display_path(file_name: String) -> String:
	return "shots/" + file_name


static func exists(file_name: String) -> bool:
	var path := path_of(file_name)
	return path != "" and FileAccess.file_exists(path)


## The .lua files in shots/, default.lua first, then by name.
static func list_files() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(root_dir())
	if dir == null:
		return out
	for f in dir.get_files():
		if valid_name(f) and f != DEFAULT_FILE:
			out.append(f)
	out.sort()
	if out.size() > MAX_FILES - 1:
		out.resize(MAX_FILES - 1)
	if dir.file_exists(DEFAULT_FILE):
		out.insert(0, DEFAULT_FILE)
	return out


## The file's text, "" when it is missing.
static func read(file_name: String) -> String:
	var path := path_of(file_name)
	if path == "" or not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


## Writes `text` to shots/`file_name`. Saved even when it does not compile,
## so no work is lost.
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


## A free "shot_N.lua" name for a new file.
static func next_free_name() -> String:
	for i in range(2, MAX_FILES + 2):
		var n := "shot_%d.lua" % i
		if not exists(n):
			return n
	return ""


## First run only: writes default.lua from the straight starter. A player who
## deletes it later gets the basic shot, not a fresh copy. True when written.
static func seed_default() -> bool:
	var cfg := _state()
	if cfg.get_value("shots", "seeded", false):
		return false
	var wrote := false
	if not exists(DEFAULT_FILE):
		var s := starter(DEFAULT_STARTER)
		wrote = s != null and write(DEFAULT_FILE, s.source)
	cfg.set_value("shots", "seeded", true)
	_save_state(cfg)
	return wrote


## The file the player equipped last (default.lua when none was saved).
static func equipped_file() -> String:
	var v: Variant = _state().get_value("shots", "equipped", DEFAULT_FILE)
	var n: String = v if v is String else DEFAULT_FILE
	return n if valid_name(n) else DEFAULT_FILE


static func set_equipped_file(file_name: String) -> void:
	if not valid_name(file_name):
		return
	var cfg := _state()
	cfg.set_value("shots", "equipped", file_name)
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
