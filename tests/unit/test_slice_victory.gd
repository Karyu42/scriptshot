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
	# SE's queued boss_down grant must not emit on the next frame either.
	SenseBook.flush_pending()
	assert_eq(_granted, [])
	assert_eq(SenseBook.level(SenseBook.ENEMIES_IN), 1)
	assert_eq(SenseBook.level(SenseBook.ENEMIES_IN), 1, "Level II is not granted")


func test_rewards_and_g0_wait_for_the_shrink_when_there_is_no_card() -> void:
	var save := _save()
	var progress := _progress(save)
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	assert_eq(RespawnPoints.get_respawn_position(), Vector2.ZERO)
	warden.health.set_hp(0.0)
	assert_eq(RespawnPoints.get_respawn_position(), ARENA)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G0))
	assert_eq(save.shards, 0)
	assert_false(save.warden_dead)
	assert_false(save.starter_consumed)
	assert_eq(_granted, [])
	assert_almost_eq(warden.death_ring_scale(), 1.0, 0.001)
	warden._physics_process(0.6)
	assert_almost_eq(warden.death_ring_scale(), 0.5, 0.02)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G0))
	warden._physics_process(0.6)
	assert_almost_eq(warden.death_ring_scale(), 0.0, 0.001)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G0))
	assert_eq(save.shards, 5)
	assert_true(save.warden_dead)
	assert_true(save.starter_consumed)
	assert_eq(save.sense_enemies_in, 1)
	assert_eq(_granted, ["enemies_in:1"])
	var reloaded := SaveGame.load_from(_SAVE)
	assert_true(reloaded.warden_dead)
	assert_true(reloaded.starter_consumed)
	assert_eq(reloaded.shards, 5)
	assert_eq(reloaded.sense_enemies_in, 1)


func test_card_freezes_the_world_and_opens_g0_on_dismiss() -> void:
	var save := _save()
	var progress := _progress(save)
	var hud := _hud()
	var warden := _warden()
	warden.bind(_player(), null, null, save)
	warden.health.set_hp(0.0)
	assert_false(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 1.0)
	warden.debug_finish_death_anim()
	assert_true(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 0.0)
	assert_eq(hud.victory_lines(), PackedStringArray([
		"The Warden is down.",
		"sense.enemies_in",
	]))
	# Rewards are written when the card appears so a mid-card quit stays cleared.
	assert_eq(save.shards, 5)
	assert_true(save.warden_dead)
	assert_true(save.starter_consumed)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G0), "G0 unlocks under the freeze")
	assert_eq(_granted, [])
	var ev := InputEventAction.new()
	ev.action = "fire"
	ev.pressed = true
	hud._input(ev)
	assert_false(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 1.0)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G0))
	assert_eq(RespawnPoints.get_respawn_position(), ARENA)
	assert_eq(_granted, ["enemies_in:1"])


func test_e_dismisses_the_card_and_does_not_open_the_editor() -> void:
	var hud := _hud()
	var editor := ScriptEditorPanel.new()
	add_child_autofree(editor)
	hud.present_victory_card()
	assert_true(hud.is_victory_card_up())
	var ev := InputEventAction.new()
	ev.action = "script_editor"
	ev.pressed = true
	hud._input(ev)
	assert_false(hud.is_victory_card_up())
	assert_eq(Engine.time_scale, 1.0)
	assert_false(editor.is_open())


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
	warden.debug_finish_death_anim()
	warden.debug_finish_death_anim()
	assert_eq(save.shards, 5)


func _progress(save: SaveGame) -> SliceProgress:
	var layout := SliceLayout.new()
	layout.name = "SliceLayout"
	add_child_autofree(layout)
	var progress := SliceProgress.new()
	progress.name = "SliceProgress"
	add_child_autofree(progress)
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
