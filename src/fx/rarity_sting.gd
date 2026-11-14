class_name RaritySting
extends Node
## Tier-driven AudioStreamWAV sting (spawning §8.1–§8.4).
##
## The phrase is rendered up front (RarityPhrases) into a 16-bit PCM
## AudioStreamWAV at the same mix rate, length, and envelope as the old
## procedural buffer, then played through a plain AudioStreamPlayer.
## Web holds it until the first pressed input. If the WAV cannot be built,
## the same tier's pre-rendered ogg plays once. It is not looped: the
## phrases have a fixed length (0.4 s, 0.8 s, 2 s).
##
## INCOMPLETE / deferred: the legendary 3 dB ambient duck does not run. It
## waits until a music or world bus exists. Boss-tier playback is the 2 s
## preview one-shot from RarityPhrases, not the proximity hum.
## The player uses the World bus when that bus exists, otherwise Master, and
## does not change that bus's volume.


const DUCK_DB := -3.0
const DUCK_SECONDS := 2.0
const DUCK_BUS_NAMES: PackedStringArray = ["Ambient", "Music", "World"]
## INCOMPLETE / deferred. False until music/world buses and the mix exist.
const DUCK_ACTIVE := false

const FALLBACK_PATHS: PackedStringArray = [
	"res://assets/audio/common_elite_sting.ogg",
	"res://assets/audio/rare_elite_sting.ogg",
	"res://assets/audio/legendary_elite_sting.ogg",
	"res://assets/audio/boss_common_hum.ogg",
	"res://assets/audio/boss_rare_hum.ogg",
	"res://assets/audio/boss_legendary_hum.ogg",
]

## Set on web until a real press. Tests can force it.
static var gesture_required := false
static var gesture_seen := false

static var _duck_depth := 0
static var _duck_bus := -1
static var _duck_original_db := 0.0
## Tests only. When not -2, duck_bus_index() returns this and skips AudioServer.
static var stub_duck_bus := -2
## Tests only. When non-empty, duck volume get/set uses this map, not AudioServer.
static var stub_bus_volumes: Dictionary[int, float] = {}

var tier := RarityCue.TIER_ELITE_COMMON
## When true, skip the speaker. The visual brighten does not wait on this.
var suppress := false
## Tests: skip the baked WAV and play the ogg immediately.
var simulate_underrun := false
## Skip the baked WAV and play the ogg immediately.
var force_fallback := false

var requested := false
var used_wav := false
var used_fallback := false
var failed := false
var frames_pushed := 0

var _player: AudioStreamPlayer
var _running := false
var _queued := false
var _started := false
var _shut := false
var _holding_duck := false
var _duck_left := 0.0


static func reset_session() -> void:
	gesture_required = false
	gesture_seen = false
	stub_duck_bus = -2
	stub_bus_volumes = {}
	_end_duck_static()
	RarityPhrases.clear()


static func fallback_path(p_tier: int) -> String:
	if p_tier < 0 or p_tier >= FALLBACK_PATHS.size():
		return ""
	return FALLBACK_PATHS[p_tier]


static func load_fallback(p_tier: int) -> AudioStream:
	var path := fallback_path(p_tier)
	if path == "":
		return null
	var loaded: Resource = load(path)
	return loaded as AudioStream


static func output_bus() -> StringName:
	if AudioServer.get_bus_index("World") >= 0:
		return &"World"
	return &"Master"


static func duck_bus_index() -> int:
	if stub_duck_bus != -2:
		return stub_duck_bus
	for bus_name in DUCK_BUS_NAMES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx >= 0:
			return idx
	return -1


static func _bus_volume_db(idx: int) -> float:
	if not stub_bus_volumes.is_empty():
		return stub_bus_volumes.get(idx, 0.0)
	return AudioServer.get_bus_volume_db(idx)


static func _set_bus_volume_db(idx: int, db: float) -> void:
	if not stub_bus_volumes.is_empty():
		stub_bus_volumes[idx] = db
		return
	AudioServer.set_bus_volume_db(idx, db)


static func _end_duck_static() -> void:
	if _duck_bus >= 0:
		_set_bus_volume_db(_duck_bus, _duck_original_db)
	_duck_bus = -1
	_duck_depth = 0
	_duck_original_db = 0.0


func _ready() -> void:
	if OS.has_feature("web") and not gesture_seen:
		gesture_required = true
	_player = AudioStreamPlayer.new()
	_player.name = "StingPlayer"
	_player.bus = output_bus()
	add_child(_player)


func _input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	gesture_seen = true
	if _queued:
		_queued = false
		_start()


func _exit_tree() -> void:
	shutdown()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		shutdown()


func player_node() -> AudioStreamPlayer:
	return _player


func ducking() -> bool:
	return _holding_duck


func shutdown() -> void:
	if _shut:
		return
	_shut = true
	_running = false
	_release_duck()
	# Stop before dropping the stream so the audio server is not left
	# mixing a sting that is about to be freed.
	if _player != null and is_instance_valid(_player):
		_player.stop()
	if _player != null and is_instance_valid(_player):
		_player.stream = null
		var node := _player
		_player = null
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.free()
	_player = null


func play_sting() -> void:
	if requested:
		return
	requested = true
	if suppress:
		return
	if gesture_required and not gesture_seen:
		_queued = true
		set_process_input(true)
		return
	_start()


func _start() -> void:
	if _started:
		return
	_started = true
	_begin_duck()
	if _player == null:
		failed = true
		return
	if force_fallback or simulate_underrun:
		_play_ogg()
		return
	var stream := RarityPhrases.wav_for(tier)
	if stream == null:
		_play_ogg()
		return
	_player.stream = stream
	_player.play()
	used_wav = true
	frames_pushed = RarityPhrases.render(tier).size()
	_running = true


func _process(delta: float) -> void:
	if _holding_duck:
		_duck_left -= delta
		if _duck_left <= 0.0:
			_release_duck()


func _play_ogg() -> void:
	_running = false
	_begin_duck()
	var stream := load_fallback(tier)
	if stream == null or _player == null:
		failed = true
		return
	_player.stop()
	_player.stream = stream
	_player.play()
	used_fallback = true
	used_wav = false
	frames_pushed = 0


func _begin_duck() -> void:
	if not DUCK_ACTIVE:
		return
	if tier != RarityCue.TIER_ELITE_LEGENDARY or _holding_duck:
		return
	var bus := duck_bus_index()
	if bus < 0:
		return
	if _duck_depth == 0:
		_duck_bus = bus
		_duck_original_db = _bus_volume_db(bus)
		_set_bus_volume_db(bus, _duck_original_db + DUCK_DB)
	_duck_depth += 1
	_holding_duck = true
	_duck_left = DUCK_SECONDS


func _release_duck() -> void:
	if not _holding_duck:
		return
	_holding_duck = false
	_duck_depth = maxi(_duck_depth - 1, 0)
	if _duck_depth == 0:
		_end_duck_static()
