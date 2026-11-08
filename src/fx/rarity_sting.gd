class_name RaritySting
extends Node
## Tier-driven AudioStreamGenerator sting (spawning §8.1–§8.4).
##
## The buffer is rendered up front (RarityPhrases) and pushed as soon as
## play() returns, into a short generator buffer, so the sting is not waiting
## on a long mix queue. Web holds it until the first pressed input.
## If the generator is missing or reports an underrun, the same tier's
## pre-rendered ogg plays once. It is not looped: the phrases have a fixed
## length (0.4 s, 0.8 s, 2 s).
##
## The legendary elite ducks the first existing Ambient, Music, or World bus
## by 3 dB for 2 s. With only Master present (this project today) the duck
## is a no-op. The player itself stays on World when that bus exists, else
## Master, and never changes that bus's volume setting.


const BUFFER_LENGTH := 0.08
const DUCK_DB := -3.0
const DUCK_SECONDS := 2.0
const DUCK_BUS_NAMES: PackedStringArray = ["Ambient", "Music", "World"]

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

var tier := RarityCue.TIER_ELITE_COMMON
## When true, skip the speaker. The visual brighten does not wait on this.
var suppress := false
## Treat the generator as having underrun, so the ogg path is taken.
var simulate_underrun := false
## Skip the generator and play the ogg immediately.
var force_fallback := false

var requested := false
var used_generator := false
var used_fallback := false
var failed := false
var frames_pushed := 0

var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _cursor := 0
var _running := false
var _queued := false
var _started := false
var _shut := false
var _holding_duck := false
var _duck_left := 0.0


static func reset_session() -> void:
	gesture_required = false
	gesture_seen = false
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
	for bus_name in DUCK_BUS_NAMES:
		var idx := AudioServer.get_bus_index(bus_name)
		if idx >= 0:
			return idx
	return -1


static func _end_duck_static() -> void:
	if _duck_bus >= 0:
		AudioServer.set_bus_volume_db(_duck_bus, _duck_original_db)
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
	_running = false
	_release_duck()
	_playback = null
	if _player != null and is_instance_valid(_player):
		_player.stream = null
	_player = null
	_shut = true


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
	_playback = null
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
	if force_fallback:
		_play_ogg()
		return
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RarityPhrases.SAMPLE_RATE
	gen.buffer_length = BUFFER_LENGTH
	_player.stream = gen
	_player.play()
	var playback := _player.get_stream_playback()
	_playback = playback as AudioStreamGeneratorPlayback
	if _playback == null or simulate_underrun:
		_play_ogg()
		return
	used_generator = true
	_running = true
	_fill()


func _process(delta: float) -> void:
	if _holding_duck:
		_duck_left -= delta
		if _duck_left <= 0.0:
			_release_duck()
	if not _running or _playback == null:
		return
	if _underrun():
		_play_ogg()
		return
	_fill()
	if _cursor >= _frames().size():
		# Leave the generator stream in place until shutdown. The last frames
		# are still in the short playback buffer; dropping the stream here cuts
		# the tail.
		_running = false


func _frames() -> PackedVector2Array:
	return RarityPhrases.render(tier)


func _underrun() -> bool:
	if simulate_underrun:
		return true
	if _playback == null or frames_pushed <= 0:
		return false
	return _playback.get_skips() > 0


func _fill() -> void:
	if _playback == null:
		return
	var frames := _frames()
	var available := _playback.get_frames_available()
	while available > 0 and _cursor < frames.size():
		_playback.push_frame(frames[_cursor])
		_cursor += 1
		frames_pushed += 1
		available -= 1


func _play_ogg() -> void:
	_running = false
	_playback = null
	_begin_duck()
	var stream := load_fallback(tier)
	if stream == null or _player == null:
		failed = true
		return
	_player.stop()
	_player.stream = stream
	_player.play()
	used_fallback = true
	used_generator = false


func _begin_duck() -> void:
	if tier != RarityCue.TIER_ELITE_LEGENDARY or _holding_duck:
		return
	var bus := duck_bus_index()
	if bus < 0:
		return
	if _duck_depth == 0:
		_duck_bus = bus
		_duck_original_db = AudioServer.get_bus_volume_db(bus)
		AudioServer.set_bus_volume_db(bus, _duck_original_db + DUCK_DB)
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
