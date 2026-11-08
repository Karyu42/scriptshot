extends GutTest
## Rarity cues for every tier (issue #24, spawning §8, pillars §8.1).
## Rare and legendary elites and bosses are not spawned here. The component
## is called with a tier, the same way an entity will once those rolls exist.


const _FORBIDDEN: PackedStringArray = [
	"WorldEnvironment",
	"CompositorEffect",
	"BackBufferCopy",
	"hint_screen_texture",
	"SCREEN_TEXTURE",
	"glow_enabled",
	"ShaderMaterial",
	".gdshader",
	"RenderingServer",
]


func before_each() -> void:
	RarityCue.pulse_enabled = true
	RarityCue.halo_add_enabled = true
	RarityCue.reset_budget()
	RaritySting.reset_session()
	GridWarpFallback.reset()


func after_each() -> void:
	RarityCue.pulse_enabled = true
	RarityCue.halo_add_enabled = true
	RarityCue.reset_budget()
	RaritySting.reset_session()
	GridWarpFallback.reset()
	_remove_test_buses()


func test_shape_params_per_tier() -> void:
	var common := _cue(RarityCue.TIER_ELITE_COMMON)
	assert_eq(common.ring_count(), 1)
	assert_almost_eq(common.ring_mul(0), 1.35, 1e-6)
	assert_eq(common.visual_ring_width(), 3.0)
	assert_eq(common.tick_count(), 0)
	assert_eq(common.outline_base(), 3.0)
	assert_eq(common.accent(), RarityCue.RING_COLOR)
	assert_eq(common.glyph_slot_count(), 1)
	assert_eq(common.pulse_period(), 0.0)
	assert_eq(common.halo_kind(), RarityCue.HALO_NONE)
	assert_eq(common.beacon_tick_count(), 0)
	# The common elite already in the game is this same tier.
	var elite := EliteCue.new()
	assert_eq(elite.tier, RarityCue.TIER_ELITE_COMMON)
	assert_eq(elite.ring_count(), 1)
	assert_eq(EliteCue.RING_WIDTH, RarityCue.RING_WIDTH)
	assert_eq(EliteCue.OUTLINE_WIDTH, 3.0)
	assert_eq(EliteCue.CUE_CAP, 12)

	var rare := _cue(RarityCue.TIER_ELITE_RARE)
	assert_eq(rare.ring_count(), 2)
	assert_almost_eq(rare.ring_mul(0), 1.35, 1e-6)
	assert_gt(rare.ring_mul(1), rare.ring_mul(0))
	assert_eq(rare.visual_ring_width(), 4.0)
	assert_eq(rare.tick_count(), 3)
	assert_eq(rare.outline_base(), 4.0)
	assert_eq(rare.accent(), Color("4DE1FF"))
	assert_eq(rare.glyph_slot_count(), 2)
	assert_false(rare.has_extra_outline())
	assert_almost_eq(rare.telegraph_color(Color(0.5, 0.5, 0.5)).r, 0.6, 0.001)

	var legendary := _cue(RarityCue.TIER_ELITE_LEGENDARY)
	assert_eq(legendary.ring_count(), 1)
	assert_eq(legendary.tick_count(), 4)
	assert_eq(legendary.outline_base(), 5.0)
	assert_eq(legendary.accent(), Color("FFB347"))
	assert_true(legendary.draws_signature())
	assert_almost_eq(legendary.pulse_period(), 1.5, 1e-6)
	assert_eq(legendary.halo_kind(), RarityCue.HALO_LEGENDARY)
	# t = 0 is the thin end of the 1.5 s crown pulse (3 → 5).
	assert_almost_eq(legendary.visual_ring_width(), 3.0, 0.05)
	legendary.advance(0.75)
	assert_almost_eq(legendary.visual_ring_width(), 5.0, 0.05)
	legendary.signature_name = "Hydra"
	legendary.start_brighten()
	assert_almost_eq(legendary.name_left, 2.0, 1e-6)
	# Grayscale: tick count and outline weight differ with the colour ignored.
	assert_ne(common.tick_count(), rare.tick_count())
	assert_ne(rare.tick_count(), legendary.tick_count())
	assert_ne(common.outline_base(), rare.outline_base())
	assert_ne(rare.outline_base(), legendary.outline_base())

	var boss_common := _cue(RarityCue.TIER_BOSS_COMMON)
	assert_eq(boss_common.ring_count(), 0)
	assert_eq(boss_common.outline_base(), 3.0)
	assert_eq(boss_common.beacon_tick_count(), 1)
	assert_eq(boss_common.halo_kind(), RarityCue.HALO_BOSS_GLOW)
	assert_gt(boss_common.halo_radius(48.0), legendary.halo_radius(48.0))

	var boss_rare := _cue(RarityCue.TIER_BOSS_RARE)
	assert_eq(boss_rare.ring_count(), 1)
	assert_true(boss_rare.has_extra_outline())
	assert_eq(boss_rare.accent(), Color("4DE1FF"))
	assert_eq(boss_rare.beacon_tick_count(), 2)
	assert_eq(boss_rare.outline_base(), 3.0)

	var boss_leg := _cue(RarityCue.TIER_BOSS_LEGENDARY)
	assert_eq(boss_leg.tick_count(), 4)
	assert_eq(boss_leg.accent(), Color("FFB347"))
	assert_almost_eq(boss_leg.pulse_period(), 1.5, 1e-6)
	assert_eq(boss_leg.beacon_tick_count(), 1)
	assert_almost_eq(boss_leg.current_outline_width(), 3.0, 0.02)
	boss_leg.advance(0.75)
	assert_almost_eq(boss_leg.current_outline_width(), 5.0, 0.05)
	RarityCue.pulse_enabled = false
	assert_almost_eq(boss_leg.current_outline_width(), 3.0, 0.02)
	RarityCue.pulse_enabled = true


func test_halo_material_is_add_and_falls_back_to_mix() -> void:
	var host := Node2D.new()
	add_child_autofree(host)
	var legendary := _cue(RarityCue.TIER_ELITE_LEGENDARY)
	legendary.try_acquire()
	legendary.attach(host)
	var mat := legendary.halo_material() as CanvasItemMaterial
	assert_not_null(mat)
	assert_false(legendary.halo_material() is ShaderMaterial)
	assert_eq(mat.blend_mode, CanvasItemMaterial.BLEND_MODE_ADD)
	assert_eq(legendary.blend_mode(), CanvasItemMaterial.BLEND_MODE_ADD)
	var halo := legendary.halo_node()
	assert_not_null(halo)
	assert_true(halo.show_behind_parent)
	# §8.4: the ADD disc is the legendary halo. Rare keeps rings and ticks only.
	var rare := _cue(RarityCue.TIER_ELITE_RARE)
	rare.try_acquire()
	rare.attach(host)
	assert_null(rare.halo_node(), "rare elite has no halo; force_halo is debug-only")
	rare.force_halo = true
	rare.attach(host)
	var rare_mat := rare.halo_material() as CanvasItemMaterial
	assert_not_null(rare_mat)
	assert_eq(rare_mat.blend_mode, CanvasItemMaterial.BLEND_MODE_ADD)
	# Boss glow is the larger ADD disc, including a common boss.
	var boss := _cue(RarityCue.TIER_BOSS_COMMON)
	boss.present()
	boss.attach(host)
	var boss_mat := boss.halo_material() as CanvasItemMaterial
	assert_not_null(boss_mat)
	assert_eq(boss_mat.blend_mode, CanvasItemMaterial.BLEND_MODE_ADD)
	assert_gt(boss.halo_radius(40.0), legendary.halo_radius(40.0))
	# Fallback: same disc, normal alpha, brighter outline.
	RarityCue.halo_add_enabled = false
	legendary.attach(host)
	var mix := legendary.halo_material() as CanvasItemMaterial
	assert_not_null(mix)
	assert_eq(mix.blend_mode, CanvasItemMaterial.BLEND_MODE_MIX)
	assert_almost_eq(legendary.halo_node().disc_color.a, RarityCue.LEGENDARY_HALO_ALPHA, 0.001)
	assert_gt(legendary.current_outline_width(), legendary.outline_base())
	assert_gt(legendary.outline_color().r, RarityCue.OUTLINE_COLOR.r)
	legendary.release()
	rare.release()
	boss.release()


func test_sting_buffers_have_no_discontinuities_and_sit_near_zero() -> void:
	assert_eq(EliteSting.DURATION, RarityPhrases.COMMON_DURATION)
	assert_eq(EliteSting.HZ_START, RarityPhrases.COMMON_HZ_START)
	assert_eq(EliteSting.HZ_END, RarityPhrases.COMMON_HZ_END)
	assert_almost_eq(RarityPhrases.peak(EliteSting.render_frames()), EliteSting.AMPLITUDE, 0.02)
	for tier in RarityCue.TIER_COUNT:
		var frames := RarityPhrases.render(tier)
		var n := roundi(RarityPhrases.duration_of(tier) * float(RarityPhrases.SAMPLE_RATE))
		assert_eq(frames.size(), n, "tier %d length" % tier)
		assert_gt(frames.size(), 8)
		assert_almost_eq(frames[0].x, 0.0, 1e-4, "tier %d starts at 0" % tier)
		assert_almost_eq(frames[0].y, 0.0, 1e-4, "tier %d starts at 0" % tier)
		assert_almost_eq(frames[frames.size() - 1].x, 0.0, 1e-3, "tier %d ends near 0" % tier)
		assert_almost_eq(frames[frames.size() - 1].y, frames[frames.size() - 1].x, 1e-6)
		assert_lt(RarityPhrases.max_step(frames), 0.05, "tier %d has a click" % tier)
		assert_lt(RarityPhrases.peak(frames), 1.0, "tier %d clips" % tier)
		assert_gt(RarityPhrases.peak(frames), 0.05, "tier %d is silent" % tier)
		var stream := RaritySting.load_fallback(tier)
		assert_not_null(stream, "ogg fallback for tier %d" % tier)
		assert_almost_eq(stream.get_length(), RarityPhrases.duration_of(tier), 0.08)


func test_fallbacks_never_use_unsupported_features() -> void:
	var files: PackedStringArray = [
		"res://src/fx/rarity_cue.gd",
		"res://src/fx/rarity_sting.gd",
		"res://src/fx/rarity_phrases.gd",
		"res://src/fx/rarity_preview.gd",
		"res://src/fx/halo_disc.gd",
		"res://src/fx/grid_warp.gd",
		"res://src/fx/elite_cue.gd",
		"res://src/fx/elite_sting.gd",
	]
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		assert_false(text == "", path)
		for token in _FORBIDDEN:
			assert_false(text.contains(token), "%s mentions %s" % [path, token])
	var host := Node2D.new()
	add_child_autofree(host)
	var cue := _cue(RarityCue.TIER_BOSS_LEGENDARY)
	cue.present()
	cue.attach(host)
	assert_true(cue.halo_material() is CanvasItemMaterial)
	assert_false(cue.halo_material() is ShaderMaterial)
	var chunk := Rect2(-1024, -1024, 2048, 2048)
	GridWarpFallback.add_chunk(chunk)
	for i in 9:
		for j in 9:
			var p := Vector2(-1200.0 + float(i) * 300.0, -1200.0 + float(j) * 300.0)
			assert_lte(GridWarpFallback.offset_at(p).length(), GridWarpFallback.MAX_OFFSET_PX + 0.001)
	assert_lte(GridWarpFallback.MAX_OFFSET_PX, 3.0)
	GridWarpFallback.mode = GridWarpFallback.MODE_PULSE
	var centre := chunk.get_center()
	assert_eq(GridWarpFallback.offset_at(centre + Vector2(200, 0)), Vector2.ZERO)
	var base := Color("1f232c")
	GridWarpFallback.pulse_phase = PI * 0.5
	var lifted := GridWarpFallback.color_at(centre + Vector2(40, 0), base)
	assert_gt(lifted.r, base.r)
	var far := GridWarpFallback.color_at(Vector2(8000, 8000), base)
	assert_eq(far, base)
	GridWarpFallback.mode = GridWarpFallback.MODE_OFFSET
	var canvas := _GridDraw.new()
	add_child_autofree(canvas)
	canvas.queue_redraw()
	await wait_process_frames(1)
	cue.release()


class _GridDraw:
	extends Node2D

	func _draw() -> void:
		GridWarpFallback.draw_grid(self, Rect2(-64, -64, 128, 128), Color.WHITE, 64.0)


func test_cue_lifecycle_frees_halo_and_player() -> void:
	var host := Node2D.new()
	add_child_autofree(host)
	var cue := _cue(RarityCue.TIER_ELITE_LEGENDARY)
	assert_true(cue.try_acquire())
	assert_eq(RarityCue.slot_count(), 1)
	cue.attach(host)
	var halo := cue.halo_node()
	var mat_id := cue.halo_material().get_instance_id()
	var sting := RaritySting.new()
	sting.tier = RarityCue.TIER_ELITE_LEGENDARY
	sting.suppress = true
	host.add_child(sting)
	var player_id := sting.player_node().get_instance_id()
	assert_true(is_instance_id_valid(player_id))
	cue.release()
	assert_eq(RarityCue.slot_count(), 0)
	assert_null(cue.halo_material())
	assert_false(is_instance_id_valid(mat_id))
	assert_false(is_instance_valid(halo))
	sting.shutdown()
	assert_null(sting.player_node())
	assert_false(is_instance_id_valid(player_id))


func test_legendary_duck_is_deferred_and_does_not_change_a_bus() -> void:
	# INCOMPLETE / deferred until a music or world bus is part of the mix.
	assert_false(RaritySting.DUCK_ACTIVE)
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Music")
	AudioServer.set_bus_volume_db(idx, -2.0)
	var sting := RaritySting.new()
	sting.tier = RarityCue.TIER_ELITE_LEGENDARY
	add_child_autofree(sting)
	sting.play_sting()
	sting._process(RaritySting.DUCK_SECONDS)
	assert_false(sting.ducking())
	assert_almost_eq(AudioServer.get_bus_volume_db(idx), -2.0, 0.01)


func test_preview_is_not_a_spawn_and_releases_its_cues() -> void:
	var preview := RarityPreview.new()
	add_child_autofree(preview)
	preview.show_gallery()
	assert_eq(preview.get_child_count(), RarityCue.TIER_COUNT)
	assert_eq(RarityCue.slot_count(), 0, "the gallery does not consume elite cue slots")
	assert_false(GridWarpFallback.is_idle())
	for child in preview.get_children():
		assert_false(child.is_in_group(EliteEnemy.GROUP_ELITE))
	var warp := GridWarpFallback.offset_at(Vector2(100, 0))
	assert_lte(warp.length(), 3.0)
	preview.hide_gallery()
	await wait_process_frames(2)
	assert_eq(preview.get_child_count(), 0)
	assert_true(GridWarpFallback.is_idle())
	assert_eq(RarityCue.slot_count(), 0)


func test_gallery_hide_keeps_a_foreign_warp_registration() -> void:
	var foreign := Rect2(10, 20, 300, 200)
	var foreign_id := GridWarpFallback.add_chunk(foreign)
	var preview := RarityPreview.new()
	add_child_autofree(preview)
	preview.show_gallery()
	assert_eq(GridWarpFallback.chunks.size(), 2)
	preview.hide_gallery()
	assert_eq(GridWarpFallback.chunks.size(), 1)
	assert_eq(GridWarpFallback.chunks[0], foreign)
	assert_true(GridWarpFallback.remove_chunk(foreign_id))
	assert_eq(GridWarpFallback.chunks.size(), 0)
	assert_false(GridWarpFallback.remove_chunk(foreign_id))


func test_gallery_hide_keeps_a_foreign_rect_equal_to_its_own() -> void:
	var preview := RarityPreview.new()
	add_child_autofree(preview)
	preview.show_gallery()
	assert_eq(GridWarpFallback.chunks.size(), 1)
	var gallery_rect := GridWarpFallback.chunks[0]
	var foreign_id := GridWarpFallback.add_chunk(gallery_rect)
	assert_eq(GridWarpFallback.chunks.size(), 2)
	preview.hide_gallery()
	assert_eq(GridWarpFallback.chunks.size(), 1)
	assert_true(GridWarpFallback.remove_chunk(foreign_id))
	assert_eq(GridWarpFallback.chunks.size(), 0)


func test_gallery_show_hide_is_idempotent_around_foreign_warps() -> void:
	var foreign_id := GridWarpFallback.add_chunk(Rect2(10, 20, 300, 200))
	var preview := RarityPreview.new()
	add_child_autofree(preview)
	preview.show_gallery()
	preview.hide_gallery()
	preview.show_gallery()
	preview.hide_gallery()
	preview.hide_gallery()
	assert_eq(GridWarpFallback.chunks.size(), 1)
	assert_true(GridWarpFallback.remove_chunk(foreign_id))
	assert_eq(GridWarpFallback.chunks.size(), 0)


func test_gallery_tree_exit_removes_only_its_warp() -> void:
	var foreign_id := GridWarpFallback.add_chunk(Rect2(10, 20, 300, 200))
	var preview := RarityPreview.new()
	add_child(preview)
	preview.show_gallery()
	assert_eq(GridWarpFallback.chunks.size(), 2)
	preview.free()
	assert_false(is_instance_valid(preview))
	assert_eq(GridWarpFallback.chunks.size(), 1)
	assert_eq(GridWarpFallback.chunks[0], Rect2(10, 20, 300, 200))
	assert_true(GridWarpFallback.remove_chunk(foreign_id))
	assert_eq(GridWarpFallback.chunks.size(), 0)


func test_boss_telegraph_outline_is_brighter_without_a_glow_pass() -> void:
	var boss := _cue(RarityCue.TIER_BOSS_RARE)
	var base := Color("FF5A4D")
	var lit := boss.telegraph_color(base)
	assert_gt(lit.g, base.g)
	assert_gt(boss.telegraph_outline_width(2.0), 2.0)
	var elite := _cue(RarityCue.TIER_ELITE_COMMON)
	assert_eq(elite.telegraph_outline_width(2.0), 2.0)
	assert_almost_eq(elite.telegraph_color(base).r, base.r, 0.001)


func _cue(tier: int) -> RarityCue:
	var cue := RarityCue.new()
	cue.setup(tier)
	return cue


func _remove_test_buses() -> void:
	for i in range(AudioServer.bus_count - 1, 0, -1):
		var bus_name := AudioServer.get_bus_name(i)
		if bus_name == "Music" or bus_name == "Ambient" or bus_name == "World":
			if AudioServer.get_bus_volume_db(i) != 0.0:
				AudioServer.set_bus_volume_db(i, 0.0)
			AudioServer.remove_bus(i)
