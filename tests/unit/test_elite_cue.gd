extends GutTest
## Common-elite cue: ring, glyph, 0.3 s brighten, sting, and the Q24 fallbacks
## that apply to this tier (static ring, ogg fallback, web gesture).


func before_each() -> void:
	EliteCue.pulse_enabled = true
	EliteCue.reset_budget()
	EliteSting.reset_session()


func after_each() -> void:
	EliteCue.pulse_enabled = true
	EliteCue.reset_budget()
	EliteSting.reset_session()


func test_ring_glyph_and_outline_parameters() -> void:
	assert_almost_eq(EliteCue.ring_radius(RegularEnemy.DRIFTER_RADIUS), 16.0 * 1.35, 1e-6)
	assert_eq(EliteCue.RING_RADIUS_MUL, 1.35)
	assert_eq(EliteCue.RING_WIDTH, 3.0)
	assert_eq(EliteCue.OUTLINE_WIDTH, 3.0)
	assert_eq(RegularEnemy.OUTLINE_WIDTH, 2.0)
	assert_almost_eq(EliteCue.RING_COLOR.r, 242.0 / 255.0, 0.001)
	assert_eq(EliteCue.RING_COLOR.r, EliteCue.RING_COLOR.g)
	assert_eq(EliteCue.RING_COLOR.g, EliteCue.RING_COLOR.b)
	assert_eq(EliteCue.GLYPH_RADIUS, 6.0)
	assert_almost_eq(EliteCue.GLYPH_ORBIT_MUL, 1.6, 1e-6)
	assert_eq(EliteCue.GLYPH_SPIN_DEG, 90.0)
	assert_eq(EliteCue.ARC_POINTS, 32)
	assert_almost_eq(EliteCue.BRIGHTEN_SECONDS, 0.3, 1e-6)
	assert_eq(EliteCue.CUE_CAP, 12)
	assert_eq(EliteCue.glyph_kind(AffixDef.GROUP_SPAWN), EliteCue.GLYPH_CIRCLE)
	assert_eq(EliteCue.glyph_kind(AffixDef.GROUP_DEFENSIVE), EliteCue.GLYPH_SQUARE)
	assert_eq(EliteCue.glyph_kind(AffixDef.GROUP_OFFENSIVE), EliteCue.GLYPH_TRIANGLE)
	# Grayscale: the ring is neutral and the Drifter fill is not.
	var fill := RegularEnemy.DRIFTER_FILL
	assert_gt(absf(fill.b - fill.r), 0.2)
	var cue := EliteCue.new()
	cue.advance(1.0)
	assert_almost_eq(cue.angle, PI / 2.0, 0.001)
	var offset := cue.glyph_offset(16.0)
	assert_almost_eq(offset.length(), 16.0 * 1.6, 0.001)
	assert_almost_eq(offset.x, 0.0, 0.02)
	assert_gt(offset.y, 0.0)


func test_brighten_is_a_pulse_and_falls_back_to_a_static_ring() -> void:
	var cue := EliteCue.new()
	EliteCue.pulse_enabled = true
	cue.start_brighten()
	assert_almost_eq(cue.brighten_left, 0.3, 0.0001)
	assert_almost_eq(cue.visual_ring_width(), EliteCue.BRIGHTEN_WIDTH, 0.001)
	assert_gt(cue.visual_ring_color().r, EliteCue.RING_COLOR.r - 0.0001)
	cue.advance(0.3)
	assert_almost_eq(cue.brighten_left, 0.0, 0.0001)
	assert_almost_eq(cue.visual_ring_width(), EliteCue.RING_WIDTH, 0.001)
	assert_eq(cue.visual_ring_color(), EliteCue.RING_COLOR)
	# Q24: if the pulse cannot run, the ring stays the static 3 px stroke.
	EliteCue.pulse_enabled = false
	cue.start_brighten()
	assert_gt(cue.brighten_left, 0.0)
	assert_almost_eq(cue.visual_ring_width(), EliteCue.RING_WIDTH, 0.001)
	assert_eq(cue.visual_ring_color(), EliteCue.RING_COLOR)


func test_cue_cap_keeps_the_thirteenth_outline_only() -> void:
	var held: Array[EliteCue] = []
	for _i in EliteCue.CUE_CAP:
		var cue := EliteCue.new()
		assert_true(cue.try_acquire())
		assert_true(cue.draws_ring())
		held.append(cue)
	var extra := EliteCue.new()
	assert_false(extra.try_acquire())
	assert_false(extra.draws_ring())
	held[0].release()
	assert_true(extra.try_acquire())
	assert_true(extra.draws_ring())
	for cue: EliteCue in held:
		cue.release()
	extra.release()


func test_sting_is_a_440_to_660_triangle_over_0_4s() -> void:
	assert_eq(EliteSting.DURATION, 0.4)
	assert_eq(EliteSting.HZ_START, 440.0)
	assert_eq(EliteSting.HZ_END, 660.0)
	assert_almost_eq(EliteSting.frequency_at(0.0), 440.0, 1e-6)
	assert_almost_eq(EliteSting.frequency_at(0.2), 550.0, 1e-6)
	assert_almost_eq(EliteSting.frequency_at(0.4), 660.0, 1e-6)
	assert_almost_eq(EliteSting.triangle(0.0), -1.0, 1e-6)
	assert_almost_eq(EliteSting.triangle(0.25), 0.0, 1e-6)
	assert_almost_eq(EliteSting.triangle(0.5), 1.0, 1e-6)
	assert_almost_eq(EliteSting.integrated_cycles(), 220.0, 1.0)
	var frames := EliteSting.render_frames()
	assert_eq(frames.size(), int(round(0.4 * float(EliteSting.SAMPLE_RATE))))
	# Raised-cosine edge so the buffer does not click. The sweep underneath is
	# still the 440 → 660 triangle (see frequency_at / integrated_cycles).
	assert_almost_eq(frames[0].x, 0.0, 1e-4)
	assert_almost_eq(frames[frames.size() - 1].x, 0.0, 1e-3)
	assert_almost_eq(frames[0].y, frames[0].x, 1e-6)
	var stream := EliteSting.fallback_stream()
	assert_not_null(stream)
	assert_almost_eq(stream.get_length(), EliteSting.DURATION, 0.05)


func test_brighten_plays_when_the_sting_is_silent() -> void:
	var elite := _elite(&"summoner", Vector2(3000, 3000))
	elite.sting.suppress = true
	var player := elite.player
	player.global_position = elite.global_position + Vector2(690, 0)
	elite._physics_process(1.0 / 60.0)
	assert_true(elite.woken)
	assert_true(elite.sting.requested)
	assert_false(elite.sting.used_wav)
	assert_false(elite.sting.used_fallback)
	assert_gt(elite.cue.brighten_left, 0.0)
	assert_almost_eq(elite.cue.visual_ring_width(), EliteCue.BRIGHTEN_WIDTH, 0.01)
	assert_eq(elite.outline_width(), 3.0)
	assert_eq(elite.cue.glyph, EliteCue.GLYPH_CIRCLE)
	assert_true(elite.cue.draws_ring())
	# The draw path itself (ring, glyph) has to run without a script error.
	elite.queue_redraw()
	await wait_process_frames(1)


func test_wav_or_ogg_plays_and_force_fallback_uses_the_ogg() -> void:
	var elite := _elite(&"splitting", Vector2(3200, 3200))
	var player := elite.player
	player.global_position = elite.global_position + Vector2(690, 0)
	elite._physics_process(1.0 / 60.0)
	await wait_process_frames(2)
	assert_true(elite.sting.requested)
	assert_true(
		elite.sting.used_wav or elite.sting.used_fallback,
		"wake sting uses the baked WAV or the ogg fallback"
	)
	if elite.sting.used_wav:
		assert_gt(elite.sting.frames_pushed, 0)
		assert_false(elite.sting.failed)
		var wav := elite.sting.player_node().stream as AudioStreamWAV
		assert_not_null(wav)
		assert_eq(wav.format, AudioStreamWAV.FORMAT_16_BITS)
		assert_eq(wav.mix_rate, EliteSting.SAMPLE_RATE)
		assert_eq(wav.data, RarityPhrases.encode_pcm16(EliteSting.render_frames()))
	var fallback := _elite(&"splitting", Vector2(4200, 3200))
	fallback.sting.force_fallback = true
	fallback.player.global_position = fallback.global_position + Vector2(690, 0)
	fallback._physics_process(1.0 / 60.0)
	assert_true(fallback.sting.used_fallback)
	assert_false(fallback.sting.used_wav)
	var player_node := fallback.sting.get_node("StingPlayer") as AudioStreamPlayer
	assert_true(player_node.playing)
	var missed := _elite(&"splitting", Vector2(5200, 3200))
	missed.sting.simulate_underrun = true
	missed.player.global_position = missed.global_position + Vector2(690, 0)
	missed._physics_process(1.0 / 60.0)
	assert_true(missed.sting.used_fallback)
	assert_false(missed.sting.used_wav)


func test_web_gesture_gate_holds_the_sting_until_a_press() -> void:
	EliteSting.gesture_required = true
	EliteSting.gesture_seen = false
	var elite := _elite(&"summoner", Vector2(3000, -3000))
	var body := elite.player
	body.global_position = elite.global_position + Vector2(690, 0)
	elite._physics_process(1.0 / 60.0)
	assert_true(elite.sting.requested)
	assert_false(elite.sting.used_wav)
	assert_false(elite.sting.used_fallback)
	# The ring still brightens while audio waits.
	assert_gt(elite.cue.brighten_left, 0.0)
	var press := InputEventKey.new()
	press.pressed = true
	press.keycode = KEY_SPACE
	elite.sting._input(press)
	assert_true(elite.sting.used_wav or elite.sting.used_fallback)


func _elite(affix: StringName, at: Vector2) -> EliteEnemy:
	var player := Node2D.new()
	player.position = at + Vector2(2000, 0)
	add_child_autofree(player)
	var elite := (preload("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.configure_elite(affix, at, at, 1, player, true, false)
	add_child_autofree(elite)
	return elite
