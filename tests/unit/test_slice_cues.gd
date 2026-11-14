extends GutTest
## Vertical-slice §10 row 13 / §8.3 GE gate: room D shows the rare elite row,
## the alcove shows the legendary row with signature name Hydra, the Warden
## shows the common-boss row (edge tick and GridWarpFallback), and a forced
## halo_add_enabled = false still reads. Existing RarityCue tests stay in
## test_rarity_cue.gd.

const DT := 1.0 / 60.0
const ROOM_D := Vector2(7680, 0)
const ALCOVE := Vector2(7616, 1152)


func before_each() -> void:
	RarityCue.halo_add_enabled = true
	RarityCue.pulse_enabled = true
	EliteCue.reset_budget()
	EliteSting.reset_session()
	GridWarpFallback.reset()


func after_each() -> void:
	RarityCue.halo_add_enabled = true
	RarityCue.pulse_enabled = true
	EliteCue.reset_budget()
	EliteSting.reset_session()
	GridWarpFallback.reset()


func test_room_d_elite_uses_the_rare_cue_row() -> void:
	var elite := _elite(ROOM_D, AffixDef.RARITY_RARE, AffixCatalog.SUMMONER)
	assert_eq(elite.cue.tier, RarityCue.TIER_ELITE_RARE)
	assert_eq(elite.cue.ring_count(), 2)
	assert_almost_eq(elite.cue.ring_mul(1), RarityCue.RARE_OUTER_MUL, 0.0001)
	assert_eq(elite.cue.tick_count(), 3)
	assert_eq(elite.cue.outline_base(), 4.0)
	assert_eq(elite.cue.accent(), RarityCue.RARE_COLOR)
	assert_false(elite.cue.draws_halo(), "rare has no disc")
	assert_eq(elite.sting.tier, RarityCue.TIER_ELITE_RARE)
	assert_eq(elite.global_position, ROOM_D)
	# Single-affix helper below; the authored room D rare is two glyphs.


func test_the_room_d_rare_shows_two_glyphs() -> void:
	var elite := _elite(
		ROOM_D,
		AffixDef.RARITY_RARE,
		AffixCatalog.BULWARK,
		"",
		[AffixCatalog.SUMMONER] as Array[StringName],
	)
	assert_eq(elite.cue.glyph_slot_count(), 2)
	var kinds: Array[int] = elite.cue.glyphs
	assert_eq(kinds.size(), 2)
	var first := 0
	var second := 0
	if kinds.size() >= 1:
		first = kinds[0]
	if kinds.size() >= 2:
		second = kinds[1]
	assert_eq(first, RarityCue.GLYPH_SQUARE)
	assert_eq(second, RarityCue.GLYPH_CIRCLE)


func test_alcove_hydra_uses_the_legendary_cue_row_with_its_name() -> void:
	var elite := _elite(ALCOVE, AffixDef.RARITY_LEGENDARY, AffixCatalog.SUMMONER, "Hydra")
	assert_eq(elite.cue.tier, RarityCue.TIER_ELITE_LEGENDARY)
	assert_eq(elite.cue.tick_count(), 4)
	assert_eq(elite.cue.outline_base(), 5.0)
	assert_eq(elite.cue.accent(), RarityCue.LEGENDARY_COLOR)
	assert_true(elite.cue.draws_signature())
	assert_eq(elite.cue.signature_name, "Hydra")
	assert_true(elite.cue.draws_halo())
	assert_eq(elite.cue.halo_kind(), RarityCue.HALO_LEGENDARY)
	assert_eq(elite.sting.tier, RarityCue.TIER_ELITE_LEGENDARY)
	assert_true(SliceLayout.room_rect(SliceLayout.ROOM_ALCOVE).has_point(elite.global_position))
	elite.cue.start_brighten()
	assert_almost_eq(elite.cue.name_left, RarityCue.NAME_SECONDS, 0.001)


func test_warden_uses_the_common_boss_row_and_warps_the_arena() -> void:
	var warden := _warden()
	assert_eq(warden.cue.tier, RarityCue.TIER_BOSS_COMMON)
	assert_eq(warden.cue.ring_count(), 0)
	assert_eq(warden.cue.tick_count(), 0)
	assert_eq(warden.cue.outline_base(), 3.0)
	assert_eq(warden.cue.halo_kind(), RarityCue.HALO_BOSS_GLOW)
	assert_eq(warden.cue.beacon_tick_count(), 1)
	assert_eq(warden.cue.boss_hue, warden.COLOR_FILL)
	assert_false(GridWarpFallback.is_idle())
	assert_eq(GridWarpFallback.chunks.size(), 1)
	assert_eq(GridWarpFallback.chunks[0], SliceLayout.room_rect(SliceLayout.ROOM_E))


func test_forced_mix_halo_still_reads_on_the_legendary_and_the_warden() -> void:
	RarityCue.halo_add_enabled = false
	var hydra := _elite(ALCOVE, AffixDef.RARITY_LEGENDARY, AffixCatalog.SUMMONER, "Hydra")
	assert_eq(hydra.cue.blend_mode(), CanvasItemMaterial.BLEND_MODE_MIX)
	assert_true(hydra.cue.draws_halo())
	assert_gt(hydra.cue.current_outline_width(), hydra.cue.outline_base())
	assert_true(hydra.cue.outline_color().v > RarityCue.OUTLINE_COLOR.v)
	var warden := _warden()
	assert_eq(warden.cue.blend_mode(), CanvasItemMaterial.BLEND_MODE_MIX)
	assert_true(warden.cue.draws_halo())
	assert_gt(warden.cue.current_outline_width(), warden.cue.outline_base())
	assert_true(warden.cue.outline_color().v > RarityCue.OUTLINE_COLOR.v)


func test_the_warden_edge_tick_shows_in_the_ribbon_and_hides_when_it_should() -> void:
	var setup := await _setup_beacon()
	var hud: SliceHud = setup.hud
	var player: Player = setup.player
	var warden: Warden = setup.warden
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_true(SliceLayout.in_footprint(player.global_position))
	assert_true(hud.is_boss_beacon_visible(), "the slice Warden qualifies in the ribbon")
	assert_almost_eq(hud.boss_beacon_alpha(), 1.0, 0.001)
	var at := hud.boss_beacon_origin()
	assert_ne(at, Vector2.INF)
	var vp := hud.get_viewport()
	assert_not_null(vp)
	var size := vp.get_visible_rect().size
	assert_gt(at.x, size.x * 0.5, "the tick sits on the arena side of the screen")
	assert_lt(at.x, size.x)
	assert_gte(at.x, size.x - SliceHud.BEACON_INSET - 1.0)
	player.global_position = Vector2(-20000, 0)
	assert_false(SliceLayout.in_footprint(player.global_position))
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_false(hud.is_boss_beacon_visible(), "outside the ribbon and farther than 5 chunks")
	assert_almost_eq(hud.boss_beacon_alpha(), 0.0, 0.001)
	player.global_position = Vector2.ZERO
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_true(hud.is_boss_beacon_visible())
	assert_almost_eq(hud.boss_beacon_alpha(), 1.0, 0.001)
	warden.health.set_hp(0.0)
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_false(hud.is_boss_beacon_visible(), "no tick after the Warden dies")
	assert_almost_eq(hud.boss_beacon_alpha(), 0.0, 0.001)


func test_the_edge_tick_hides_while_the_core_body_intersects_the_view() -> void:
	var setup := await _setup_beacon()
	var hud: SliceHud = setup.hud
	var warden: Warden = setup.warden
	var rect := hud.get_viewport().get_visible_rect()
	_set_warden_canvas_pos(hud, warden, Vector2(rect.end.x - 10.0, rect.get_center().y))
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_false(hud.is_boss_beacon_visible(), "partially visible body means hidden")
	assert_almost_eq(hud.boss_beacon_alpha(), 0.0, 0.001)


func test_the_edge_tick_shows_once_the_core_body_is_fully_outside() -> void:
	var setup := await _setup_beacon()
	var hud: SliceHud = setup.hud
	var warden: Warden = setup.warden
	var vp := hud.get_viewport()
	var rect := vp.get_visible_rect()
	var radius := vp.get_canvas_transform().basis_xform(Vector2(Warden.BODY_RADIUS, 0.0)).length()
	_set_warden_canvas_pos(hud, warden, Vector2(rect.end.x + radius + 4.0, rect.get_center().y))
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_true(hud.is_boss_beacon_visible(), "fully outside means shown")
	assert_almost_eq(hud.boss_beacon_alpha(), 1.0, 0.001)


func test_the_edge_tick_fades_in_and_out_in_point_one_five_seconds() -> void:
	var setup := await _setup_beacon()
	var hud: SliceHud = setup.hud
	var warden: Warden = setup.warden
	var vp := hud.get_viewport()
	var rect := vp.get_visible_rect()
	var mid := rect.get_center()
	var radius := vp.get_canvas_transform().basis_xform(Vector2(Warden.BODY_RADIUS, 0.0)).length()
	_set_warden_canvas_pos(hud, warden, Vector2(rect.end.x - 10.0, mid.y))
	hud._process(SliceHud.BEACON_FADE_SEC)
	assert_almost_eq(hud.boss_beacon_alpha(), 0.0, 0.001)
	_set_warden_canvas_pos(hud, warden, Vector2(rect.end.x + radius + 4.0, mid.y))
	var half := SliceHud.BEACON_FADE_SEC * 0.5
	hud._process(half)
	assert_almost_eq(hud.boss_beacon_alpha(), 0.5, 0.001)
	assert_true(hud.is_boss_beacon_visible())
	hud._process(half)
	assert_almost_eq(hud.boss_beacon_alpha(), 1.0, 0.001)
	_set_warden_canvas_pos(hud, warden, Vector2(rect.end.x - 10.0, mid.y))
	hud._process(half)
	assert_almost_eq(hud.boss_beacon_alpha(), 0.5, 0.001)
	assert_true(hud.is_boss_beacon_visible(), "still fading out")
	hud._process(half)
	assert_almost_eq(hud.boss_beacon_alpha(), 0.0, 0.001)
	assert_false(hud.is_boss_beacon_visible())


func _setup_beacon() -> Dictionary:
	var hud := SliceHud.new()
	add_child_autofree(hud)
	var progress := SliceProgress.new()
	add_child_autofree(progress)
	var layout := SliceLayout.new()
	add_child_autofree(layout)
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector2.ZERO
	add_child_autofree(player)
	player.set_physics_process(false)
	await wait_physics_frames(2)
	progress.bind(player, null, layout, null)
	hud.bind(player, progress)
	var warden := _warden()
	hud.bind_boss(warden, warden.health)
	return {hud = hud, player = player, warden = warden}


func _set_warden_canvas_pos(hud: SliceHud, warden: Warden, canvas: Vector2) -> void:
	var vp := hud.get_viewport()
	warden.global_position = vp.get_canvas_transform().affine_inverse() * canvas


func _elite(
	at: Vector2,
	rarity: int,
	affix: StringName,
	name := "",
	extra: Array[StringName] = [],
) -> EliteEnemy:
	var player := Node2D.new()
	player.position = at + Vector2(300, 0)
	add_child_autofree(player)
	var elite := (preload("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.signature_name = name
	elite.configure_elite(affix, at, at, 1, player, true, false, Vector2i.ZERO, -1, rarity, extra)
	elite.set_physics_process(false)
	add_child_autofree(elite)
	return elite


func _warden(at: Vector2 = SliceLayout.ARENA_CENTRE) -> Warden:
	var warden := Warden.new()
	warden.position = at
	warden.set_physics_process(false)
	add_child_autofree(warden)
	return warden
