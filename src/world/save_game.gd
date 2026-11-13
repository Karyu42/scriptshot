class_name SaveGame
extends RefCounted
## One slot at user://save.cfg. L0/L1 write world_seed and regular_absent.
## L2 sets herald_done when the Herald spawns or is cancelled, and adds 1 to
## shards when that body dies. L3 adds 1 shard per natural elite body and sets
## a bit in elite_kills for that chunk encounter. Halves, summons, and escorts
## do not. The countdown remainder and the Herald's position are not stored.
## SenseBook writes the earned Senses (vertical-slice §6.1): `sense_nearest`
## and `sense_enemies_in` (the level, 1 in this slice), section [senses].

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
## Once-per-save flag for the Warden tithe line "It feeds." Missing or a
## non-bool value means false (old slots, type-guarded).
var seen_it_feeds := false
## Senses earned in this slot (SenseBook.bind_save). Permanent for the slot.
var sense_nearest := false
var sense_enemies_in := 0
## Vertical-slice lesson bits (bit 0 = lesson 1) and gate bits (bit 0 = G0).
## Absent keys in an older slot default to 0.
var slice_lessons := 0
var slice_gates := 0
var slice_packs := 0
## Room-C scripted packs: unix "absent since" times. 0 (or a missing key) means
## the pack is present. Each pack returns after FIELD_PACK_RETURN seconds
## outside C. Row 2 wires the packs themselves; this slot only stores the keys.
const FIELD_PACK_RETURN := 300.0
const FIELD_DRIFTERS := &"field_drifters"
const FIELD_SWARMERS := &"field_swarmers"
const FIELD_SHIELD := &"field_shield"
const FIELD_SNIPER := &"field_sniper"
const FIELD_KEYS: Array[StringName] = [
	FIELD_DRIFTERS, FIELD_SWARMERS, FIELD_SHIELD, FIELD_SNIPER,
]
var field_drifters := 0.0
var field_swarmers := 0.0
var field_shield := 0.0
var field_sniper := 0.0
## Once the Warden's core hits 0 this slot is cleared: the body does not
## respawn. The common Warden also counts as the save's starter boss (Q25),
## so starter_consumed is set with it and a later region-boss pass will not
## place a second starter. Missing or a non-bool value means false.
var warden_dead := false
var starter_consumed := false
## Set when the enemies_in toast and Codex page have actually been shown.
## Missing or a non-bool means false, so a mid-card quit still announces on
## the next load.
var enemies_in_announced := false
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
	cfg.set_value("world", "seen_it_feeds", seen_it_feeds)
	cfg.set_value("senses", "sense_nearest", sense_nearest)
	cfg.set_value("senses", "sense_enemies_in", sense_enemies_in)
	cfg.set_value("world", "slice_lessons", slice_lessons)
	cfg.set_value("world", "slice_gates", slice_gates)
	cfg.set_value("world", "slice_packs", slice_packs)
	cfg.set_value("world", "field_drifters", field_drifters)
	cfg.set_value("world", "field_swarmers", field_swarmers)
	cfg.set_value("world", "field_shield", field_shield)
	cfg.set_value("world", "field_sniper", field_sniper)
	cfg.set_value("world", "warden_dead", warden_dead)
	cfg.set_value("world", "starter_consumed", starter_consumed)
	cfg.set_value("senses", "enemies_in_announced", enemies_in_announced)
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
	# Missing or a non-bool (e.g. an int) stays false.
	var feeds: Variant = cfg.get_value("world", "seen_it_feeds", false)
	seen_it_feeds = feeds is bool and bool(feeds)
	sense_nearest = bool(cfg.get_value("senses", "sense_nearest", false))
	sense_enemies_in = maxi(int(cfg.get_value("senses", "sense_enemies_in", 0)), 0)
	slice_lessons = int(cfg.get_value("world", "slice_lessons", 0))
	slice_gates = int(cfg.get_value("world", "slice_gates", 0))
	slice_packs = int(cfg.get_value("world", "slice_packs", 0))
	field_drifters = float(cfg.get_value("world", "field_drifters", 0))
	field_swarmers = float(cfg.get_value("world", "field_swarmers", 0))
	field_shield = float(cfg.get_value("world", "field_shield", 0))
	field_sniper = float(cfg.get_value("world", "field_sniper", 0))
	# Missing or a non-bool (e.g. an int) stays false.
	var dead: Variant = cfg.get_value("world", "warden_dead", false)
	warden_dead = dead is bool and bool(dead)
	var consumed: Variant = cfg.get_value("world", "starter_consumed", false)
	starter_consumed = consumed is bool and bool(consumed)
	var announced: Variant = cfg.get_value("senses", "enemies_in_announced", false)
	enemies_in_announced = announced is bool and bool(announced)
	@warning_ignore_restore("unsafe_call_argument", "unsafe_cast")


## Unix "absent since" for a room-C pack key, or 0 if the pack is present /
## the key is unknown. A missing save key loads as 0.
func field_absent_since(key: StringName) -> float:
	match key:
		FIELD_DRIFTERS:
			return field_drifters
		FIELD_SWARMERS:
			return field_swarmers
		FIELD_SHIELD:
			return field_shield
		FIELD_SNIPER:
			return field_sniper
		_:
			push_warning("SaveGame.field_absent_since(): unknown key %s" % key)
			return 0.0


## Records when a room-C pack became absent (unix seconds). 0 marks it present.
## Does not write the file; call save() when the slot should hit disk.
func set_field_absent_since(key: StringName, unix: float) -> void:
	var value := 0.0 if is_nan(unix) else maxf(unix, 0.0)
	match key:
		FIELD_DRIFTERS:
			field_drifters = value
		FIELD_SWARMERS:
			field_swarmers = value
		FIELD_SHIELD:
			field_shield = value
		FIELD_SNIPER:
			field_sniper = value
		_:
			push_warning("SaveGame.set_field_absent_since(): unknown key %s" % key)


## True when the pack should be in C: never marked absent, or at least
## FIELD_PACK_RETURN seconds have passed since `unix`. `now_unix` defaults to
## the current unix time.
func field_pack_is_present(key: StringName, now_unix: float = -1.0) -> bool:
	var since := field_absent_since(key)
	if since <= 0.0:
		return true
	if now_unix < 0.0:
		now_unix = Time.get_unix_time_from_system()
	return now_unix - since >= FIELD_PACK_RETURN


## Bits for one chunk, OR of every saved row for that coordinate. 0 when none.
## The low two bits are T0 encounters 0 and 1. Bit 2 is reserved and kept.
func elite_bits_at(cx: int, cy: int) -> int:
	var bits := 0
	@warning_ignore_start("unsafe_call_argument", "unsafe_cast")
	for entry: Variant in elite_kills:
		if entry is Dictionary:
			var d: Dictionary = entry
			if int(d.get("cx", 0)) == cx and int(d.get("cy", 0)) == cy:
				bits |= int(d.get("bits", 0))
	@warning_ignore_restore("unsafe_call_argument", "unsafe_cast")
	return bits & 0x7


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
