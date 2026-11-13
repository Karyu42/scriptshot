extends GutTest
## Vertical-slice HUD (row 11): pips, dash arc, Sense marks, lesson hints,
## Sense toast, death overlay, and a generic boss-bar stub.

const DT := 1.0 / 60.0
const _SAVE := "user://gut_slice_hud.cfg"

var hud: SliceHud
var progress: SliceProgress
var player: Player
var layout: SliceLayout


func before_each() -> void:
	RespawnPoints.reset()
	SenseBook.reset()
	hud = SliceHud.new()
	add_child_autofree(hud)
	progress = SliceProgress.new()
	add_child_autofree(progress)
	layout = SliceLayout.new()
	add_child_autofree(layout)
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.set_physics_process(false)
	player.health.set_physics_process(false)
	await wait_physics_frames(2)
	progress.bind(player, null, layout, null)
	hud.bind(player, progress)
	watch_signals(hud)


func after_each() -> void:
	RespawnPoints.reset()
	SenseBook.reset()
	if FileAccess.file_exists(_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_SAVE))


func _tick(seconds: float) -> void:
	for _i in ceili(seconds / DT):
		player.health.tick(DT)
		progress.tick(DT)
		hud._process(DT)


# --- pips, dash, senses ------------------------------------------------------

func test_five_pips_track_health() -> void:
	assert_eq(hud.overheal_pips(), 0)
	for i in range(5):
		assert_true(hud.pip_filled(i), "full at start, pip %d" % i)
	assert_true(player.health.damage(2.0))
	assert_true(hud.pip_filled(0))
	assert_true(hud.pip_filled(1))
	assert_true(hud.pip_filled(2))
	assert_false(hud.pip_filled(3))
	assert_false(hud.pip_filled(4))


func test_overheal_pips_use_the_violet_count() -> void:
	player.health.set_hp(5.0)
	# set_hp will not raise above max; write through the field after max bump.
	player.health.max_hp = 5.0
	player.health.hp = 7.0
	hud._on_hp_changed(7.0, 5.0)
	assert_eq(hud.overheal_pips(), 2)
	for i in range(5):
		assert_true(hud.pip_filled(i))


func test_dash_arc_matches_cooldown_and_hides_when_ready() -> void:
	assert_false(hud.dash_visible())
	assert_eq(hud.dash_fraction(), 1.0)
	assert_true(player.try_dash(Vector2.RIGHT))
	hud._process(0.0)
	assert_true(hud.dash_visible())
	assert_almost_eq(hud.dash_fraction(), 0.0, 0.001)
	# Advance the dash cooldown without the player's _physics_process.
	player._dash.tick_cooldown(0.75)
	hud._process(0.0)
	assert_true(hud.dash_visible())
	assert_almost_eq(hud.dash_fraction(), 0.5, 0.02)
	player._dash.tick_cooldown(0.75)
	hud._process(0.0)
	assert_false(hud.dash_visible())
	assert_eq(hud.dash_fraction(), 1.0)


func test_sense_marks_fill_only_when_the_book_grants() -> void:
	assert_false(hud.sense_filled(&"nearest_enemy"))
	assert_false(hud.sense_filled(&"enemies_in"))
	SenseBook.grant(&"nearest_enemy", 1)
	assert_true(hud.sense_filled(&"nearest_enemy"))
	assert_false(hud.sense_filled(&"enemies_in"))
	assert_eq(hud.toast_text(), "sense.nearest_enemy")
	assert_signal_emitted(hud, "toast_shown")
	SenseBook.grant(&"enemies_in", 1)
	assert_true(hud.sense_filled(&"enemies_in"))
	assert_eq(hud.toast_text(), "sense.enemies_in")
	# The toast lasts 2.5 s, then clears.
	_tick(2.6)
	assert_eq(hud.toast_text(), "")


func test_a_quiet_sense_restore_does_not_toast() -> void:
	SenseBook.grant(&"nearest_enemy", 1, true)
	var fresh := SliceHud.new()
	add_child_autofree(fresh)
	fresh.bind(player, progress)
	assert_true(fresh.sense_filled(&"nearest_enemy"))
	assert_eq(fresh.toast_text(), "")


# --- hints, death, prompt ----------------------------------------------------

func test_lesson_1_hint_appears_after_25s_in_room_s() -> void:
	player.global_position = Vector2.ZERO
	assert_eq(hud.hint_text(), "")
	_tick(24.9)
	assert_eq(hud.hint_text(), "")
	_tick(0.2)
	assert_eq(hud.hint_text(), "The damage number.")
	assert_signal_emitted(hud, "hint_shown")
	# Completing the lesson hides it; it does not show again without a save.
	progress.complete_lesson(1)
	assert_eq(hud.hint_text(), "")
	# Lesson 2 is also in S and starts its own 25 s wait after 1 is done.
	_tick(25.0)
	assert_eq(hud.hint_text(), "One aim, more than one target.")


func test_a_successful_save_rearms_the_lesson_hint() -> void:
	player.global_position = Vector2.ZERO
	_tick(25.1)
	assert_eq(hud.hint_text(), "The damage number.")
	hud._on_script_saved("straight.lua", &"editor")
	assert_eq(hud.hint_text(), "", "the hint hides and waits again after a save")
	_tick(24.9)
	assert_eq(hud.hint_text(), "")
	_tick(0.2)
	assert_eq(hud.hint_text(), "The damage number.")


func test_death_overlay_matches_the_respawn() -> void:
	assert_false(hud.death_overlay_visible())
	for _i in range(5):
		player.health.clear_engine_invulnerability()
		assert_true(player.health.damage(1.0))
	assert_true(player.health.is_dead())
	assert_true(hud.death_overlay_visible())
	player.respawn(Vector2.ZERO)
	assert_false(hud.death_overlay_visible())
	assert_true(hud.pip_filled(4), "pips refill on respawn")


func test_start_prompt_is_on_then_clears_after_8s() -> void:
	assert_eq(hud.prompt_text(), "E edits.")
	_tick(7.9)
	assert_ne(hud.prompt_text(), "")
	_tick(0.2)
	assert_eq(hud.prompt_text(), "")


func test_hints_stay_left_of_the_script_editor_when_it_is_open() -> void:
	var editor := ScriptEditorPanel.new()
	add_child_autofree(editor)
	hud.bind(player, progress, editor)
	# Closed: labels use the full width.
	assert_almost_eq(hud._prompt.anchor_right, 1.0, 0.001)
	editor.open()
	hud._process(DT)
	assert_almost_eq(hud._prompt.anchor_right, 0.42, 0.001)
	assert_almost_eq(hud._hint.anchor_right, 0.42, 0.001)
	assert_almost_eq(hud._toast.anchor_right, 0.42, 0.001)
	editor.close()
	hud._process(DT)
	assert_almost_eq(hud._prompt.anchor_right, 1.0, 0.001)


# --- boss bar stub -----------------------------------------------------------

func test_boss_bar_tracks_stub_health_and_hides_on_death() -> void:
	var body := Node2D.new()
	add_child_autofree(body)
	var health := Health.new()
	health.max_hp = 900.0
	body.add_child(health)
	await wait_physics_frames(1)
	hud.bind_boss(body, health)
	assert_true(hud.is_boss_bar_visible())
	assert_almost_eq(hud.boss_fraction(), 1.0, 0.001)
	health.damage(450.0)
	assert_almost_eq(hud.boss_fraction(), 0.5, 0.001)
	hud.notify_boss_phase_changed()
	assert_true(hud._boss.is_flashing())
	# Drive HP to 0 without i-frames in the way.
	health.clear_engine_invulnerability()
	health.damage(450.0)
	assert_false(hud.is_boss_bar_visible())
	assert_eq(hud.boss_fraction(), 0.0)


func test_boss_bar_can_be_driven_without_a_node() -> void:
	assert_false(hud.is_boss_bar_visible())
	hud.set_boss_health(900.0, 900.0)
	assert_true(hud.is_boss_bar_visible())
	assert_eq(hud.boss_fraction(), 1.0)
	hud.set_boss_health(0.0, 900.0)
	assert_false(hud.is_boss_bar_visible())


func test_main_scene_has_a_slice_hud_node() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	var state := packed.get_state()
	var found := false
	for i in range(state.get_node_count()):
		if state.get_node_name(i) == "SliceHud":
			found = true
			break
	assert_true(found, "main.tscn should instance SliceHud")
