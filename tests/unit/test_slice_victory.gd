extends GutTest
## Vertical-slice row 10: the §5.6 victory sequence after the Warden's core
## hits 0. G0, the arena respawn, shards +5, SenseBook.grant, and the card.

const DT := 1.0 / 60.0
const ARENA := SliceLayout.ARENA_CENTRE
const _SAVE := "user://gut_slice_victory.cfg"


var _granted: Array[String] = []


func before_each() -> void:
	_discard()
	_granted.clear()
	SenseBook.reset()
	RespawnPoints.reset()
	Engine.time_scale = 1.0
	if not SenseBook.events.granted.is_connected(_on_granted):
		SenseBook.events.granted.connect(_on_granted)


func after_each() -> void:
	if SenseBook.events.granted.is_connected(_on_granted):
		SenseBook.events.granted.disconnect(_on_granted)
	SenseBook.reset()
	SenseBook.unlisten()
	RespawnPoints.reset()
	Engine.time_scale = 1.0
	_discard()


func _on_granted(id: StringName, level_value: int) -> void:
	_granted.append("%s:%d" % [String(id), level_value])


func test_kill_order_stays_enemy_killed_then_boss_defeated() -> void:
	var warden := _warden()
	var order: Array[String] = []
	var killed := func(
		kind: StringName, _r: int, _t: int, _p: Vector2, _first: bool
	) -> void:
		order.append("killed:%s" % String(kind))
	var boss := func(kind: StringName, _r: int, _t: int, _p: Vector2) -> void:
		order.append("boss:%s" % String(kind))
	GameEvents.enemy_killed.connect(killed)
	GameEvents.boss_defeated.connect(boss)
	warden.health.set_hp(0.0)
	GameEvents.enemy_killed.disconnect(killed)
	GameEvents.boss_defeated.disconnect(boss)
	assert_eq(order, ["killed:warden", "boss:warden"])


func test_grant_is_quiet_at_the_kill_and_the_save_int_is_1() -> void:
	SenseBook.listen()
	var save := _save()
	SenseBook.bind_save(save)
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	assert_eq(SenseBook.level(SenseBook.ENEMIES_IN), 0)
	assert_eq(save.sense_enemies_in, 0)
	warden.health.set_hp(0.0)
	assert_eq(SenseBook.level(SenseBook.ENEMIES_IN), 1)
	assert_eq(save.sense_enemies_in, 1)
	assert_eq(_granted, [], "toast / Codex wait for the card")
	assert_false(save.enemies_in_announced)
	SenseBook.flush_pending()
	assert_eq(_granted, [])
	assert_eq(SenseBook.level(SenseBook.ENEMIES_IN), 1, "Level II is not granted")


func test_g0_bit_and_flags_are_saved_at_the_kill_but_the_wall_waits() -> void:
	var save := _save()
	var progress := _progress(save)
	var layout := _layout_of(progress)
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	warden.health.set_hp(0.0)
	assert_eq(RespawnPoints.get_respawn_position(), ARENA)
	assert_true(save.warden_dead)
	assert_true(save.starter_consumed)
	assert_eq(save.shards, 5)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G0), "G0 bit is saved at the kill")
	assert_false(layout.gate_flag(SliceLayout.GATE_G0), "the wall still waits")
	assert_eq(_granted, [])
	assert_almost_eq(warden.death_ring_scale(), 1.0, 0.001)
	warden._physics_process(0.6)
	assert_almost_eq(warden.death_ring_scale(), 0.5, 0.02)
	assert_false(layout.gate_flag(SliceLayout.GATE_G0))
	warden._physics_process(0.6)
	assert_almost_eq(warden.death_ring_scale(), 0.0, 0.001)
	assert_true(layout.gate_flag(SliceLayout.GATE_G0), "no card: the wall lifts after the shrink")
	assert_eq(_granted, ["enemies_in:1"])
	assert_true(save.enemies_in_announced)
	var reloaded := SaveGame.load_from(_SAVE)
	assert_true(reloaded.warden_dead)
	assert_true(reloaded.starter_consumed)
	assert_eq(reloaded.shards, 5)
	assert_eq(reloaded.sense_enemies_in, 1)
	assert_true((reloaded.slice_gates & 1) != 0)


func test_card_is_presentation_only_and_the_wall_lifts_on_dismiss() -> void:
	var save := _save()
	var progress := _progress(save)
	var layout := _layout_of(progress)
	var hud := _hud()
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	warden.health.set_hp(0.0)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G0))
	assert_false(layout.gate_flag(SliceLayout.GATE_G0))
	assert_eq(Engine.time_scale, 1.0)
	warden.debug_finish_death_anim()
	assert_true(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 0.0)
	assert_eq(hud.victory_lines(), PackedStringArray([
		"The Warden is down.",
		"sense.enemies_in",
	]))
	assert_eq(hud.victory_line_separation(), 8)
	assert_false(layout.gate_flag(SliceLayout.GATE_G0), "wall still shut during the card")
	assert_eq(_granted, [])
	assert_false(save.enemies_in_announced)
	hud.debug_unlock_victory_input()
	_press(hud, "fire")
	assert_false(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 1.0)
	assert_true(layout.gate_flag(SliceLayout.GATE_G0))
	assert_eq(_granted, ["enemies_in:1"])
	assert_true(save.enemies_in_announced)


func test_quit_mid_card_then_load_opens_g0() -> void:
	var save := _save()
	var progress := _progress(save)
	var hud := _hud()
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	warden.health.set_hp(0.0)
	warden.debug_finish_death_anim()
	assert_true(hud.is_victory_card_up())
	assert_true(save.warden_dead)
	assert_false(save.enemies_in_announced)
	assert_false(_layout_of(progress).gate_flag(SliceLayout.GATE_G0))

	# Quit: the card is never dismissed. A new load restores the slot.
	Engine.time_scale = 1.0
	SenseBook.reset()
	_granted.clear()
	var loaded := SaveGame.load_from(_SAVE)
	assert_true(loaded.warden_dead)
	assert_false(loaded.enemies_in_announced)
	SenseBook.bind_save(loaded)
	assert_eq(_granted, [], "restore is quiet")
	var progress2 := _progress(loaded)
	assert_true(progress2.is_gate_unlocked(SliceLayout.GATE_G0))
	assert_true(_layout_of(progress2).gate_flag(SliceLayout.GATE_G0), "on load, warden_dead means G0 is open")
	assert_eq(RespawnPoints.get_respawn_position(), ARENA)


func test_quit_before_dismiss_fires_toast_and_codex_on_the_next_load() -> void:
	var save := _save()
	var warden := _warden()
	var hud := _hud()
	warden.bind(_player(), null, null, save)
	warden.health.set_hp(0.0)
	warden.debug_finish_death_anim()
	assert_true(hud.is_victory_card_up())
	assert_false(save.enemies_in_announced)

	Engine.time_scale = 1.0
	SenseBook.reset()
	_granted.clear()
	var loaded := SaveGame.load_from(_SAVE)
	SenseBook.bind_save(loaded)
	var editor := ScriptEditorPanel.new()
	add_child_autofree(editor)
	assert_eq(editor.toast_text(), "")
	assert_true(SliceHud.announce_pending_grant(loaded))
	assert_eq(_granted, ["enemies_in:1"])
	assert_true(loaded.enemies_in_announced)
	assert_eq(editor.toast_text(), "sense.enemies_in")
	assert_true("enemies_in" in editor.codex_unread())

	# The Codex-once flag is now set: a later load does not announce again.
	SenseBook.reset()
	_granted.clear()
	var again := SaveGame.load_from(_SAVE)
	SenseBook.bind_save(again)
	assert_false(SliceHud.announce_pending_grant(again))
	assert_eq(_granted, [])


func test_holding_fire_through_the_kill_does_not_dismiss_the_card() -> void:
	var hud := _hud()
	hud.present_victory_card()
	assert_eq(hud.victory_line_separation(), 8)
	# The 0.4 s lockout swallows a press that arrives with the card.
	_press(hud, "fire")
	assert_true(hud.is_victory_card_up())
	hud.debug_unlock_victory_input()
	# A hold that started before the card still does not dismiss it.
	hud.debug_set_victory_held(true, false)
	_press(hud, "fire")
	assert_true(hud.is_victory_card_up())
	_release(hud, "fire")
	_press(hud, "fire")
	assert_false(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 1.0)


func test_e_dismisses_with_a_fresh_press_after_the_lockout() -> void:
	var hud := _hud()
	var editor := ScriptEditorPanel.new()
	add_child_autofree(editor)
	hud.present_victory_card()
	_press(hud, "script_editor")
	assert_true(hud.is_victory_card_up(), "lockout ignores E")
	assert_false(editor.is_open())
	hud.debug_unlock_victory_input()
	_press(hud, "script_editor")
	assert_false(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 1.0)
	assert_false(editor.is_open())


func test_present_victory_card_closes_the_open_editor_and_keeps_time_frozen() -> void:
	# Order 1: the editor is already open when the card appears.
	var hud := _hud()
	var editor := ScriptEditorPanel.new()
	add_child_autofree(editor)
	var progress := SliceProgress.new()
	add_child_autofree(progress)
	hud.bind(_player(), progress, editor)
	editor.open()
	assert_true(editor.is_open())
	assert_almost_eq(Engine.time_scale, ScriptEditorPanel.OPEN_TIME_SCALE, 1e-6)
	hud.present_victory_card()
	assert_false(editor.is_open())
	assert_true(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 0.0)


func test_closing_the_editor_does_not_restore_time_scale_while_the_card_is_up() -> void:
	# Order 2: the card is already up, then close() runs (Esc). The editor
	# is left unbound so present_victory_card does not close it first; it
	# still finds the HUD via the slice_hud group.
	var hud := _hud()
	var editor := ScriptEditorPanel.new()
	add_child_autofree(editor)
	editor.open()
	assert_almost_eq(Engine.time_scale, ScriptEditorPanel.OPEN_TIME_SCALE, 1e-6)
	hud.present_victory_card()
	assert_true(editor.is_open())
	assert_eq(Engine.time_scale, 0.0)
	editor.close()
	assert_false(editor.is_open())
	assert_true(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 0.0)


func test_the_edit_prompt_is_hidden_while_the_card_is_up() -> void:
	var hud := _hud()
	var progress := SliceProgress.new()
	add_child_autofree(progress)
	hud.bind(_player(), progress)
	assert_eq(hud.prompt_text(), "E edits.")
	hud.present_victory_card()
	assert_eq(hud.prompt_text(), "")
	hud._process(DT)
	assert_eq(hud.prompt_text(), "")
	assert_true(hud.is_victory_card_up())


func test_enemy_bullets_deal_no_damage_after_the_kill() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 64
	manager.world_bounds = Rect2(8000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var player := _player()
	player.health.reset()
	player.health.clear_engine_invulnerability()
	var before := player.health.hp
	var warden := _warden()
	warden.bind(player, manager)
	var req := ShotRequest.with_velocity(player.global_position, Vector2.ZERO)
	req.radius = 16.0
	req.damage = 1.0
	req.hit_mask = Layers.PLAYER
	req.owner_layer = Layers.ENEMY
	req.lifetime = 2.0
	manager.spawn(req)
	warden.health.set_hp(0.0)
	manager.step(DT)
	assert_eq(player.health.hp, before, "a shot overlapping the player deals no damage after the kill")
	var fade := warden.get_node_or_null("EnemyShotFade")
	assert_not_null(fade)
	var gds_radii := warden.debug_fade_radii()
	assert_eq(gds_radii.size(), 1)
	assert_almost_eq(gds_radii[0], 16.0, 0.0001, "the fade uses the shot's own radius")
	fade._physics_process(Warden.SHOT_FADE)
	assert_true(fade.is_queued_for_deletion())


func test_native_kill_fade_uses_each_shot_radius() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim is not built")
		return
	var manager := BulletManager.new()
	manager.backend_preference = "native"
	manager.capacity = 64
	manager.world_bounds = Rect2(8000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var player := _player()
	var warden := _warden()
	warden.bind(player, manager)
	var req := ShotRequest.with_velocity(player.global_position, Vector2.ZERO)
	req.radius = 16.0
	req.damage = 1.0
	req.hit_mask = Layers.PLAYER
	req.owner_layer = Layers.ENEMY
	req.lifetime = 2.0
	manager.spawn(req)
	warden.health.set_hp(0.0)
	assert_not_null(warden.get_node_or_null("EnemyShotFade"))
	var nat_radii := warden.debug_fade_radii()
	assert_eq(nat_radii.size(), 1)
	assert_almost_eq(nat_radii[0], 16.0, 0.0001, "native fade uses the shot's own radius, not LANCE_RADIUS")


func test_a_cleared_slot_does_not_place_the_warden() -> void:
	assert_true(Warden.appears_in_slot(null))
	var save := _save()
	assert_true(Warden.appears_in_slot(save))
	save.warden_dead = true
	assert_false(Warden.appears_in_slot(save))


func test_shard_award_is_idempotent_across_the_debug_finish() -> void:
	var save := _save()
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	warden.health.set_hp(0.0)
	assert_eq(save.shards, 5)
	warden.debug_finish_death_anim()
	warden.debug_finish_death_anim()
	assert_eq(save.shards, 5)


func _press(hud: SliceHud, action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	hud._input(ev)


func _release(hud: SliceHud, action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = false
	hud._input(ev)


func _layout_of(progress: SliceProgress) -> SliceLayout:
	var node: Variant = progress.get_meta("slice_layout")
	if node is SliceLayout:
		return node
	return null


func _progress(save: SaveGame) -> SliceProgress:
	var layout := SliceLayout.new()
	layout.name = "SliceLayout"
	add_child_autofree(layout)
	var progress := SliceProgress.new()
	progress.name = "SliceProgress"
	add_child_autofree(progress)
	progress.set_meta("slice_layout", layout)
	var player := _player()
	progress.bind(player, null, layout, save)
	return progress


func _hud() -> SliceHud:
	var hud := SliceHud.new()
	hud.name = "SliceHud"
	add_child_autofree(hud)
	return hud


func _warden() -> Warden:
	var warden := Warden.new()
	warden.position = ARENA
	add_child_autofree(warden)
	return warden


func _player() -> Player:
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = ARENA + Vector2(-200, 0)
	add_child_autofree(player)
	return player


func _save() -> SaveGame:
	var save := SaveGame.new()
	save.path = _SAVE
	save.world_seed = 1
	save.save()
	return save


func _discard() -> void:
	if FileAccess.file_exists(_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_SAVE))
