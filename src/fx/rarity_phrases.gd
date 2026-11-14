class_name RarityPhrases
extends RefCounted
## Procedural rarity stings (spawning §8.1–§8.2). One buffer per tier.
##
## Every buffer is multiplied by a raised-cosine edge envelope so the first and
## last samples are ~0 and note joins do not click. The common phrase is still
## the specified triangle sweep, 440 Hz → 660 Hz over 0.4 s; the envelope only
## silences the edges.
##
## Chief of Staff (2026-11-08): A minor pentatonic rooted at 440 Hz is the
## reversible starting choice for every phrase except the common sting, which
## stays the pinned triangle sweep, 440 Hz → 660 Hz over 0.4 s. The other
## tables are written in spawning §8.1 and may be replaced.
##
## Boss tiers here are a 2 s preview one-shot for the F9 gallery. They are not
## the boss proximity hum. That hum is INCOMPLETE / deferred until boss
## integration exists.


const SAMPLE_RATE := 22050
const EDGE_FADE := 0.012
const NOTE_FADE := 0.008

const COMMON_DURATION := 0.4
const COMMON_HZ_START := 440.0
const COMMON_HZ_END := 660.0
const COMMON_AMPLITUDE := 0.25

const RARE_DURATION := 0.8
## A4, C5, E5. 3-note pentatonic arpeggio, then a quiet shimmer tail.
const RARE_NOTE_LEN := 0.15
const RARE_NOTE_AMP := 0.2
const RARE_SHIMMER_HZ := 880.0
const RARE_SHIMMER_AMP := 0.045

const LEGENDARY_DURATION := 2.0
const DRONE_HZ := 110.0
const DRONE_AMP := 0.12
const LEGENDARY_NOTE_LEN := 0.28
const LEGENDARY_NOTE_AMP := 0.16
const LEGENDARY_MOTIF_AT := 0.55

## Preview one-shot length. Not the proximity-hum duration (that hum is deferred).
const BOSS_DURATION := 2.0
const BOSS_HUM_AMP := 0.16
## Reversible: a few hertz of beating in the preview, not a pinned detune.
const BOSS_DETUNE_HZ := 3.0
const BOSS_DETUNE_AMP := 0.1
const BOSS_FIFTH_HZ := 165.0
const BOSS_FIFTH_AMP := 0.1

static var _cache: Array[PackedVector2Array] = []
## 16-bit stereo PCM for each tier. PackedByteArray is not a Resource, so
## this can live in a static until reset_session / clear at exit.
static var _pcm_cache: Array[PackedByteArray] = []


static func clear() -> void:
	_cache.clear()
	_pcm_cache.clear()


static func render(tier: int) -> PackedVector2Array:
	if _cache.is_empty():
		_cache.resize(RarityCue.TIER_COUNT)
		for i in RarityCue.TIER_COUNT:
			_cache[i] = PackedVector2Array()
	if tier < 0 or tier >= _cache.size():
		return PackedVector2Array()
	if not _cache[tier].is_empty():
		return _cache[tier]
	var frames := _render_tier(tier)
	_cache[tier] = frames
	return frames


static func duration_of(tier: int) -> float:
	match tier:
		RarityCue.TIER_ELITE_COMMON:
			return COMMON_DURATION
		RarityCue.TIER_ELITE_RARE:
			return RARE_DURATION
		RarityCue.TIER_ELITE_LEGENDARY:
			return LEGENDARY_DURATION
		_:
			return BOSS_DURATION


## Little-endian 16-bit stereo PCM of the rendered phrase.
static func encode_pcm16(frames: PackedVector2Array) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(frames.size() * 4)
	var o := 0
	for sample in frames:
		var left := _s16(sample.x)
		var right := _s16(sample.y)
		data[o] = left & 0xFF
		data[o + 1] = (left >> 8) & 0xFF
		data[o + 2] = right & 0xFF
		data[o + 3] = (right >> 8) & 0xFF
		o += 4
	return data


static func _s16(x: float) -> int:
	return clampi(roundi(clampf(x, -1.0, 1.0) * 32767.0), -32768, 32767)


static func pcm16_of(tier: int) -> PackedByteArray:
	if _pcm_cache.is_empty():
		_pcm_cache.resize(RarityCue.TIER_COUNT)
		for i in RarityCue.TIER_COUNT:
			_pcm_cache[i] = PackedByteArray()
	if tier < 0 or tier >= _pcm_cache.size():
		return PackedByteArray()
	if _pcm_cache[tier].is_empty():
		_pcm_cache[tier] = encode_pcm16(render(tier))
	return _pcm_cache[tier]


## A new AudioStreamWAV each call, filled from the cached PCM. Do not store
## the Resource in a GDScript static — callers own it for the player's life.
static func wav_for(tier: int) -> AudioStreamWAV:
	var pcm := pcm16_of(tier)
	if pcm.is_empty():
		return null
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = true
	stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
	stream.data = pcm
	return stream


static func common_frequency_at(t: float) -> float:
	var k := clampf(t / COMMON_DURATION, 0.0, 1.0)
	return lerpf(COMMON_HZ_START, COMMON_HZ_END, k)


## Triangle in [-1, 1]. Phase 0 → -1, 0.25 → 0, 0.5 → 1.
static func triangle(phase: float) -> float:
	var p := fposmod(phase, 1.0)
	if p < 0.5:
		return 4.0 * p - 1.0
	return 3.0 - 4.0 * p


static func common_cycles() -> float:
	var n := roundi(COMMON_DURATION * float(SAMPLE_RATE))
	var cycles := 0.0
	var rate := float(SAMPLE_RATE)
	for i in n:
		cycles += common_frequency_at(float(i) / rate) / rate
	return cycles


static func max_step(frames: PackedVector2Array) -> float:
	var worst := 0.0
	if frames.is_empty():
		return 0.0
	for i in range(1, frames.size()):
		worst = maxf(worst, absf(frames[i].x - frames[i - 1].x))
		worst = maxf(worst, absf(frames[i].y - frames[i - 1].y))
		worst = maxf(worst, absf(frames[i].x - frames[i].y))
	return worst


static func peak(frames: PackedVector2Array) -> float:
	var m := 0.0
	for sample in frames:
		m = maxf(m, absf(sample.x))
	return m


static func edge_env(t: float, duration: float) -> float:
	if t <= 0.0 or t >= duration:
		return 0.0
	if t < EDGE_FADE:
		return 0.5 - 0.5 * cos(PI * t / EDGE_FADE)
	var tail := duration - t
	if tail < EDGE_FADE:
		return 0.5 - 0.5 * cos(PI * tail / EDGE_FADE)
	return 1.0


static func _render_tier(tier: int) -> PackedVector2Array:
	match tier:
		RarityCue.TIER_ELITE_COMMON:
			return _common()
		RarityCue.TIER_ELITE_RARE:
			return _rare()
		RarityCue.TIER_ELITE_LEGENDARY:
			return _legendary()
		RarityCue.TIER_BOSS_COMMON:
			return _boss_common()
		RarityCue.TIER_BOSS_RARE:
			return _boss_rare()
		_:
			return _boss_legendary()


static func _allocate(duration: float) -> PackedVector2Array:
	var n := roundi(duration * float(SAMPLE_RATE))
	var out := PackedVector2Array()
	out.resize(n)
	return out


static func _common() -> PackedVector2Array:
	var out := _allocate(COMMON_DURATION)
	var phase := 0.0
	var rate := float(SAMPLE_RATE)
	for i in out.size():
		var t := float(i) / rate
		var sample := triangle(phase) * COMMON_AMPLITUDE * edge_env(t, COMMON_DURATION)
		out[i] = Vector2(sample, sample)
		phase = fposmod(phase + common_frequency_at(t) / rate, 1.0)
	return out


static func _rare() -> PackedVector2Array:
	var out := _allocate(RARE_DURATION)
	# A4, C5, E5.
	var notes := PackedFloat32Array([440.0, 523.251, 659.255])
	var gap := 0.02
	for n in notes.size():
		var t0 := gap + float(n) * (RARE_NOTE_LEN + 0.02)
		_add_tone(out, notes[n], RARE_NOTE_AMP, t0, t0 + RARE_NOTE_LEN, false, RARE_DURATION)
	# Quiet shimmer tail for the rest of the 0.8 s.
	_add_tone(out, RARE_SHIMMER_HZ, RARE_SHIMMER_AMP, 0.52, RARE_DURATION, true, RARE_DURATION)
	return out


static func _legendary() -> PackedVector2Array:
	var out := _allocate(LEGENDARY_DURATION)
	_add_swell(out, DRONE_HZ, DRONE_AMP, 0.0, LEGENDARY_DURATION, 0.45, LEGENDARY_DURATION)
	# A4, C5, D5, E5.
	var notes := PackedFloat32Array([440.0, 523.251, 587.33, 659.255])
	for n in notes.size():
		var t0 := LEGENDARY_MOTIF_AT + float(n) * LEGENDARY_NOTE_LEN
		_add_tone(out, notes[n], LEGENDARY_NOTE_AMP, t0, t0 + LEGENDARY_NOTE_LEN * 0.92, false, LEGENDARY_DURATION)
	return out


static func _boss_common() -> PackedVector2Array:
	var out := _allocate(BOSS_DURATION)
	_add_tone(out, DRONE_HZ, BOSS_HUM_AMP, 0.0, BOSS_DURATION, true, BOSS_DURATION)
	return out


static func _boss_rare() -> PackedVector2Array:
	var out := _allocate(BOSS_DURATION)
	_add_tone(out, DRONE_HZ, BOSS_DETUNE_AMP, 0.0, BOSS_DURATION, true, BOSS_DURATION)
	_add_tone(out, DRONE_HZ + BOSS_DETUNE_HZ, BOSS_DETUNE_AMP, 0.0, BOSS_DURATION, true, BOSS_DURATION)
	return out


static func _boss_legendary() -> PackedVector2Array:
	var out := _allocate(BOSS_DURATION)
	_add_tone(out, DRONE_HZ, DRONE_AMP, 0.0, BOSS_DURATION, true, BOSS_DURATION)
	# Fifth above, amplitude grows across the phrase, still gated by the edge fade.
	var rate := float(SAMPLE_RATE)
	var phase := 0.0
	for i in out.size():
		var t := float(i) / rate
		var swell := clampf(t / BOSS_DURATION, 0.0, 1.0)
		var sample := sin(TAU * phase) * BOSS_FIFTH_AMP * swell * edge_env(t, BOSS_DURATION)
		var mixed := out[i].x + sample
		out[i] = Vector2(mixed, mixed)
		phase = fposmod(phase + BOSS_FIFTH_HZ / rate, 1.0)
	return out


static func _add_tone(
	out: PackedVector2Array,
	hz: float,
	amp: float,
	t0: float,
	t1: float,
	sine_wave: bool,
	duration: float,
) -> void:
	var rate := float(SAMPLE_RATE)
	var i0 := clampi(floori(t0 * rate), 0, out.size())
	var i1 := clampi(ceili(t1 * rate), 0, out.size())
	var note_len := maxf(t1 - t0, 0.0001)
	var phase := 0.0
	for i in range(i0, i1):
		var t := float(i) / rate
		var local := t - t0
		var wave := sin(TAU * phase) if sine_wave else triangle(phase)
		var sample := wave * amp * _note_env(local, note_len) * edge_env(t, duration)
		var mixed := out[i].x + sample
		out[i] = Vector2(mixed, mixed)
		phase = fposmod(phase + hz / rate, 1.0)


static func _add_swell(
	out: PackedVector2Array,
	hz: float,
	amp: float,
	t0: float,
	t1: float,
	swell_for: float,
	duration: float,
) -> void:
	var rate := float(SAMPLE_RATE)
	var i0 := clampi(floori(t0 * rate), 0, out.size())
	var i1 := clampi(ceili(t1 * rate), 0, out.size())
	var phase := 0.0
	for i in range(i0, i1):
		var t := float(i) / rate
		var swell := clampf((t - t0) / maxf(swell_for, 0.0001), 0.0, 1.0)
		# Raised start so the swell itself begins at 0 (the edge fade does too).
		var env := 0.5 - 0.5 * cos(PI * swell)
		var sample := sin(TAU * phase) * amp * env * edge_env(t, duration)
		var mixed := out[i].x + sample
		out[i] = Vector2(mixed, mixed)
		phase = fposmod(phase + hz / rate, 1.0)


static func _note_env(local_t: float, note_len: float) -> float:
	var fade := minf(NOTE_FADE, note_len * 0.25)
	if local_t <= 0.0 or local_t >= note_len:
		return 0.0
	if local_t < fade:
		return 0.5 - 0.5 * cos(PI * local_t / fade)
	var tail := note_len - local_t
	if tail < fade:
		return 0.5 - 0.5 * cos(PI * tail / fade)
	return 1.0
