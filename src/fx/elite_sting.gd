class_name EliteSting
extends RaritySting
## Common-elite wake sting. The phrase, the baked WAV, and the ogg fallback
## are RaritySting / RarityPhrases at TIER_ELITE_COMMON. This node is what
## EliteEnemy adds, so existing call sites keep the same type.


const DURATION := 0.4
const HZ_START := 440.0
const HZ_END := 660.0
const AMPLITUDE := 0.25
const SAMPLE_RATE := 22050
const FALLBACK_PATH := "res://assets/audio/common_elite_sting.ogg"


static func frequency_at(t: float) -> float:
	return RarityPhrases.common_frequency_at(t)


static func triangle(phase: float) -> float:
	return RarityPhrases.triangle(phase)


static func render_frames() -> PackedVector2Array:
	return RarityPhrases.render(RarityCue.TIER_ELITE_COMMON)


static func integrated_cycles() -> float:
	return RarityPhrases.common_cycles()


static func fallback_stream() -> AudioStream:
	return RaritySting.load_fallback(RarityCue.TIER_ELITE_COMMON)


static func reset_session() -> void:
	RaritySting.reset_session()
