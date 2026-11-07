class_name SaveGame
extends RefCounted
## One slot at user://save.cfg. L0/L1 write world_seed and regular_absent.
## L2 sets herald_done when the Herald spawns or is cancelled, and adds 1 to
## shards when that elite body dies. elite_kills stays empty until L3.
## The countdown remainder and the Herald's position are not stored.

const DEFAULT_PATH := "user://save.cfg"
## When non-empty, resolved_path() returns this instead of DEFAULT_PATH.
## The GUT pre-run hook sets it to a throwaway file so a test that leaves
## Main.save_path unset cannot create or rewrite the player's slot.
static var slot_override := ""

var path := DEFAULT_PATH
var world_seed := 0
var herald_done := false
var elite_kills: Array = []
var regular_absent: Array = []
var shards := 0
var existed := false


static func resolved_path() -> String:
	if not slot_override.is_empty():
		return slot_override
	return DEFAULT_PATH


static func load_from(path: String = "") -> SaveGame:
	var use := path
	if use.is_empty() or use == DEFAULT_PATH:
		use = resolved_path()
	var save := SaveGame.new()
	save.path = use
	var cfg := ConfigFile.new()
	if cfg.load(use) == OK and cfg.has_section_key("world", "world_seed"):
		save._read(cfg)
		save.existed = true
	else:
		save.world_seed = randi()
		save.save()
	return save


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", world_seed)
	cfg.set_value("world", "herald_done", herald_done)
	cfg.set_value("world", "elite_kills", elite_kills)
	cfg.set_value("world", "regular_absent", regular_absent)
	cfg.set_value("world", "shards", shards)
	cfg.save(path)


## ConfigFile hands every value back as a Variant.
func _read(cfg: ConfigFile) -> void:
	@warning_ignore_start("unsafe_call_argument", "unsafe_cast")
	world_seed = int(cfg.get_value("world", "world_seed", 0))
	herald_done = bool(cfg.get_value("world", "herald_done", false))
	shards = int(cfg.get_value("world", "shards", 0))
	var kills: Variant = cfg.get_value("world", "elite_kills", [])
	elite_kills = kills if kills is Array else []
	var absent: Variant = cfg.get_value("world", "regular_absent", [])
	regular_absent = absent if absent is Array else []
	@warning_ignore_restore("unsafe_call_argument", "unsafe_cast")


## One saved absence row, or Vector3i.ZERO when the index is out of range.
func absent_key(i: int) -> Vector3i:
	var result := Vector3i.ZERO
	@warning_ignore_start("unsafe_call_argument", "unsafe_cast")
	if i >= 0 and i < regular_absent.size():
		var entry: Variant = regular_absent[i]
		if entry is Dictionary:
			var d: Dictionary = entry
			result = Vector3i(int(d.get("cx", 0)), int(d.get("cy", 0)), int(d.get("index", 0)))
	@warning_ignore_restore("unsafe_call_argument", "unsafe_cast")
	return result
