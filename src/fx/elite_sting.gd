class_name EliteSting
extends Node
## Common-elite wake sting: a triangle wave rising a fifth, 440 Hz → 660 Hz,
## over 0.4 s (spawning §8.1). Played through AudioStreamGenerator.
##
## Q24 fallbacks for this tier:
## - On web the buffer starts only after the first pressed input, so autoplay
##   policy does not drop the sting. Desktop plays on wake.
## - If the generator playback is missing, or the playback reports a buffer
##   underrun (`get_skips() > 0`, the generator missed its budget), the same
##   phrase is played once from the pre-rendered ogg. It is not looped.
## The 0.3 s ring brighten does not wait on either path.

const DURATION := 0.4
const HZ_START := 440.0
const HZ_END := 660.0
const AMPLITUDE := 0.25
const SAMPLE_RATE := 22050
const FALLBACK_PATH := "res://assets/audio/common_elite_sting.ogg"

## Set on web until a real press. Tests can force it.
static var gesture_required := false
static var gesture_seen := false

## When true, skip the speaker (the brighten still runs). Tests use this.
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

static var _cached: PackedVector2Array = PackedVector2Array()


static func reset_session() -> void:
	gesture_required = false
	gesture_seen = false
	_cached = PackedVector2Array()


static func frequency_at(t: float) -> float:
	var k := clampf(t / DURATION, 0.0, 1.0)
	return lerpf(HZ_START, HZ_END, k)


## Triangle in [-1, 1]. Phase 0 → -1, 0.25 → 0, 0.5 → 1.
static func triangle(phase: float) -> float:
	var p := fposmod(phase, 1.0)
	if p < 0.5:
		return 4.0 * p - 1.0
	return 3.0 - 4.0 * p


static func render_frames() -> PackedVector2Array:
	if not _cached.is_empty():
		return _cached
	var n := int(round(DURATION * float(SAMPLE_RATE)))
	var out := PackedVector2Array()
	out.resize(n)
	var phase := 0.0
	var rate := float(SAMPLE_RATE)
	for i in n:
		var t := float(i) / rate
		var sample := triangle(phase) * AMPLITUDE
		out[i] = Vector2(sample, sample)
		phase = fposmod(phase + frequency_at(t) / rate, 1.0)
	_cached = out
	return out


## Sum of per-sample frequency/rate. A linear 440→660 sweep over 0.4 s is 220 cycles.
static func integrated_cycles() -> float:
	var n := int(round(DURATION * float(SAMPLE_RATE)))
	var cycles := 0.0
	var rate := float(SAMPLE_RATE)
	for i in n:
		cycles += frequency_at(float(i) / rate) / rate
	return cycles


static func fallback_stream() -> AudioStream:
	var loaded: Resource = load(FALLBACK_PATH)
	return loaded as AudioStream


func _ready() -> void:
	if OS.has_feature("web") and not gesture_seen:
		gesture_required = true
	_player = AudioStreamPlayer.new()
	_player.name = "StingPlayer"
	add_child(_player)


func _input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo():
		return
	gesture_seen = true
	if _queued:
		_queued = false
		_start()


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
	if _player == null:
		failed = true
		return
	if force_fallback:
		_play_ogg()
		return
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = SAMPLE_RATE
	gen.buffer_length = DURATION + 0.15
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


func _process(_delta: float) -> void:
	if not _running or _playback == null:
		return
	if _underrun():
		_play_ogg()
		return
	_fill()
	if _cursor >= render_frames().size():
		_running = false


func _underrun() -> bool:
	if simulate_underrun:
		return true
	if _playback == null or frames_pushed <= 0:
		return false
	return _playback.get_skips() > 0


func _fill() -> void:
	if _playback == null:
		return
	var frames := render_frames()
	var available := _playback.get_frames_available()
	while available > 0 and _cursor < frames.size():
		_playback.push_frame(frames[_cursor])
		_cursor += 1
		frames_pushed += 1
		available -= 1


func _play_ogg() -> void:
	_running = false
	_playback = null
	var stream := fallback_stream()
	if stream == null or _player == null:
		failed = true
		return
	_player.stop()
	_player.stream = stream
	_player.play()
	used_fallback = true
