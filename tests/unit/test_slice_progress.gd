extends GutTest
## Vertical-slice row 5: lesson flags, gate opens, origin checkers, stubs for
## unbuilt content, and the run-loop numbers (vertical-slice.md §1, §2, §7, §10).

const DT := 1.0 / 60.0
const _SAVE := "user://gut_slice_progress.cfg"

var progress: SliceProgress
var layout: SliceLayout
var player: Player
var dummies: Node2D
var east: TrainingDummy
var north: TrainingDummy
var south: TrainingDummy
var save: SaveGame


func before_each() -> void:
	RespawnPoints.reset()
	_discard(_SAVE)
	progress = SliceProgress.new()
	add_child_autofree(progress)
	layout = SliceLayout.new()
	add_child_autofree(layout)
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.set_physics_process(false)
	player.health.set_physics_process(false)
	dummies = Node2D.new()
	add_child_autofree(dummies)
	east = _make_dummy(SliceProgress.EAST_DUMMY)
	north = _make_dummy(SliceProgress.NORTH_DUMMY)
	south = _make_dummy(SliceProgress.SOUTH_DUMMY)
	save = SaveGame.new()
	save.path = _SAVE
	save.world_seed = 1
	await wait_physics_frames(2)
	progress.bind(player, dummies, layout, save)
	watch_signals(progress)
	watch_signals(player)


func after_each() -> void:
	RespawnPoints.reset()
	_discard(_SAVE)


func _make_dummy(at: Vector2) -> TrainingDummy:
	var dummy := (load("res://scenes/training_dummy.tscn") as PackedScene).instantiate() as TrainingDummy
	dummy.position = at
	dummy.set_process(false)
	dummies.add_child(dummy)
	return dummy


func _discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _tick_health(seconds: float) -> void:
	for _i in ceili(seconds / DT):
		player.health.tick(DT)
		progress.tick(DT)


# --- spec numbers (already on main; pinned here so row 5 owns the contract) ------

func test_player_combat_numbers_match_the_spec() -> void:
	assert_eq(player.health.max_hp, 5.0)
	assert_eq(player.health.hp, 5.0)
	assert_eq(player.health.invulnerability_time, 0.75)
	assert_eq(player.health.regen_delay, 5.0)
	assert_eq(player.health.regen_interval, 3.0)
	assert_eq(player.health.regen_amount, 1.0)
	assert_eq(player.dash_distance, 160.0)
	assert_eq(player.dash_duration, 0.2)
	assert_eq(player.dash_invulnerability, 0.2)
	assert_eq(player.dash_cooldown, 1.5)
	var dash := DashState.new()
	assert_eq(dash.distance, 160.0)
	assert_eq(dash.duration, 0.2)
	assert_eq(dash.invulnerable_time, 0.2)
	assert_eq(dash.cooldown, 1.5)
	assert_eq(RegularEnemy.CONTACT_DAMAGE, 1.0, "every hit costs 1")
	var turret := Turret.new()
	assert_eq(turret.shot_damage, 1.0)
	turret.free()
	var main := Main.new()
	assert_eq(main.respawn_delay, 1.5)
	main.free()


func test_a_hit_costs_one_and_starts_iframes() -> void:
	assert_true(player.health.damage(1.0))
	assert_eq(player.health.hp, 4.0)
	assert_almost_eq(player.health.engine_invulnerable_left, 0.75, 0.0001)
	assert_false(player.health.damage(1.0), "i-frames block the next hit")
	assert_eq(player.health.hp, 4.0)
	_tick_health(0.75)
	assert_false(player.health.is_invulnerable())
	assert_true(player.health.damage(1.0))
	assert_eq(player.health.hp, 3.0)


func test_regen_is_plus_one_every_three_seconds_after_five() -> void:
	assert_true(player.health.damage(3.0))
	_tick_health(4.99)
	assert_eq(player.health.hp, 2.0)
	_tick_health(0.02)
	assert_eq(player.health.hp, 3.0, "first point at 5 s")
	_tick_health(3.0)
	assert_eq(player.health.hp, 4.0)
	_tick_health(3.0)
	assert_eq(player.health.hp, 5.0)


func test_dash_applies_invuln_and_starts_the_1_5s_cooldown() -> void:
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_true(player.health.is_engine_invulnerable())
	assert_almost_eq(player.health.engine_invulnerable_left, 0.2, 0.0001)
	assert_almost_eq(player.get_dash_cooldown_left(), 1.5, 0.0001)
	assert_false(player.try_dash(Vector2.RIGHT), "cooldown from the start of the dash")
	assert_true(player.is_dashing())


# --- flags and gates -------------------------------------------------------------

func test_g1_opens_only_after_lessons_1_and_2() -> void:
	assert_false(layout.gate_flag(SliceLayout.GATE_G1))
	assert_true(progress.complete_lesson(1))
	assert_false(layout.gate_flag(SliceLayout.GATE_G1))
	assert_true(progress.complete_lesson(2))
	assert_true(layout.gate_flag(SliceLayout.GATE_G1))
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G1))
	assert_signal_emitted(progress, "lesson_completed")
	assert_signal_emitted(progress, "gate_opened")


func test_g1_through_g4_open_in_order_via_hooks() -> void:
	progress.complete_lesson(1)
	progress.complete_lesson(2)
	assert_true(layout.gate_flag(SliceLayout.GATE_G1))
	assert_false(layout.gate_flag(SliceLayout.GATE_G2))
	progress.complete_lesson(3)
	assert_true(layout.gate_flag(SliceLayout.GATE_G2), "G2 is stubbed on lesson 3")
	progress.complete_lesson(4)
	assert_false(layout.gate_flag(SliceLayout.GATE_G3), "G3 needs lessons 4 and 5")
	progress.complete_lesson(5)
	assert_true(layout.gate_flag(SliceLayout.GATE_G3))
	for i in range(3):
		progress.notify_pack_cleared(i)
	assert_false(layout.gate_flag(SliceLayout.GATE_G4), "G4 needs all four packs")
	progress.notify_pack_cleared(3)
	assert_true(layout.gate_flag(SliceLayout.GATE_G4))
	assert_false(layout.gate_flag(SliceLayout.GATE_G5))
	progress.notify_room_d_elite_died()
	assert_true(layout.gate_flag(SliceLayout.GATE_G5))
	assert_false(layout.gate_flag(SliceLayout.GATE_G0))
	progress.notify_warden_defeated()
	assert_true(layout.gate_flag(SliceLayout.GATE_G0))
	assert_eq(RespawnPoints.get_respawn_position(), SliceLayout.ARENA_CENTRE)


func test_complete_lesson_is_idempotent() -> void:
	assert_true(progress.complete_lesson(3))
	assert_false(progress.complete_lesson(3))
	assert_signal_emit_count(progress, "lesson_completed", 1)


# --- origin checkers (lessons 1 and 2 are real) ----------------------------------

func test_lesson_1_passes_when_the_east_dummy_dies_within_four_seconds_of_fire() -> void:
	progress.debug_set_fire(true, 2.0)
	progress.notify_dummy_died(&"east", true)
	assert_true(progress.is_lesson_done(1))
	assert_false(progress.is_lesson_done(2))
	assert_false(layout.gate_flag(SliceLayout.GATE_G1))


func test_lesson_1_fails_if_the_hold_is_longer_than_four_seconds() -> void:
	progress.debug_set_fire(true, 4.1)
	progress.notify_dummy_died(&"east", true)
	assert_false(progress.is_lesson_done(1))
	# A later hold can still pass (the dummy respawns).
	progress.debug_set_fire(true, 1.0)
	progress.notify_dummy_died(&"east", false)
	assert_true(progress.is_lesson_done(1))


func test_lesson_1_via_a_real_dummy_hit() -> void:
	progress.debug_set_fire(true, 0.5)
	east._on_hit(east.health, Vector2.ZERO, Vector2.ZERO)
	assert_true(progress.is_lesson_done(1))


func test_lesson_2_needs_the_fan_window_and_three_first_deaths() -> void:
	player.aim_direction = Vector2.RIGHT
	progress.notify_dummy_damaged(&"north", 1.0)
	progress.notify_dummy_damaged(&"south", 1.0)
	assert_false(progress.is_lesson_done(2), "window passed but first deaths are missing")
	progress.notify_dummy_died(&"east", true)
	progress.notify_dummy_died(&"north", true)
	progress.notify_dummy_died(&"south", true)
	assert_true(progress.is_lesson_done(2))
	assert_false(layout.gate_flag(SliceLayout.GATE_G1), "G1 also needs lesson 1")


func test_lesson_2_and_1_together_open_g1() -> void:
	player.aim_direction = Vector2.RIGHT
	progress.debug_set_fire(true, 1.0)
	progress.notify_dummy_died(&"east", true)
	progress.notify_dummy_died(&"north", true)
	progress.notify_dummy_died(&"south", true)
	assert_true(progress.is_lesson_done(1))
	progress.notify_dummy_damaged(&"north", 1.0)
	progress.notify_dummy_damaged(&"south", 1.0)
	assert_true(progress.is_lesson_done(2))
	assert_true(layout.gate_flag(SliceLayout.GATE_G1))


func test_lesson_2_fails_if_aim_wanders_more_than_0_4_rad() -> void:
	player.aim_direction = Vector2.RIGHT
	progress.notify_dummy_died(&"east", true)
	progress.notify_dummy_died(&"north", true)
	progress.notify_dummy_died(&"south", true)
	progress.notify_dummy_damaged(&"north", 1.0)
	player.aim_direction = Vector2.RIGHT.rotated(0.5)
	progress.tick(DT)
	progress.notify_dummy_damaged(&"south", 1.0)
	assert_false(progress.is_lesson_done(2), "broken aim cancels the window")
	# Expire the leftover window that the second hit opened, then retry stable.
	progress.tick(SliceProgress.LESSON_2_WINDOW + DT)
	player.aim_direction = Vector2.RIGHT
	progress.notify_dummy_damaged(&"north", 1.0)
	progress.notify_dummy_damaged(&"south", 1.0)
	assert_true(progress.is_lesson_done(2))


func test_lesson_2_fails_if_the_second_hit_arrives_after_three_seconds() -> void:
	player.aim_direction = Vector2.RIGHT
	progress.notify_dummy_died(&"east", true)
	progress.notify_dummy_died(&"north", true)
	progress.notify_dummy_died(&"south", true)
	progress.notify_dummy_damaged(&"north", 1.0)
	progress.tick(3.1)
	progress.notify_dummy_damaged(&"south", 1.0)
	assert_false(progress.is_lesson_done(2), "south starts a new window; north is not in it")
	progress.notify_dummy_damaged(&"north", 1.0)
	assert_true(progress.is_lesson_done(2))


# --- stubs, debug, persistence, death -------------------------------------------

func test_debug_lessons_open_the_matching_gates_on_bind() -> void:
	var other := SliceProgress.new()
	other.debug_lessons = (1 << 0) | (1 << 1) | (1 << 2)  # lessons 1, 2, 3
	add_child_autofree(other)
	var gates := SliceLayout.new()
	add_child_autofree(gates)
	await wait_physics_frames(1)
	other.bind(player, dummies, gates, null)
	assert_true(other.is_lesson_done(1))
	assert_true(other.is_lesson_done(3))
	assert_true(gates.gate_flag(SliceLayout.GATE_G1))
	assert_true(gates.gate_flag(SliceLayout.GATE_G2))
	assert_false(gates.gate_flag(SliceLayout.GATE_G3))


func test_save_round_trip_restores_flags_and_gates() -> void:
	progress.complete_lesson(1)
	progress.complete_lesson(2)
	progress.complete_lesson(3)
	progress.notify_pack_cleared(0)
	var reloaded := SaveGame.load_from(_SAVE)
	assert_eq(reloaded.slice_lessons, progress.lessons_mask())
	assert_eq(reloaded.slice_gates, progress.gates_mask())
	assert_eq(reloaded.slice_packs, 1)
	assert_eq(reloaded.slice_lesson_at.size(), 5)
	@warning_ignore("unsafe_call_argument")
	var first_at := int(reloaded.slice_lesson_at[0])
	assert_gt(first_at, 0)
	var fresh := SliceProgress.new()
	add_child_autofree(fresh)
	var gates := SliceLayout.new()
	add_child_autofree(gates)
	await wait_physics_frames(1)
	fresh.bind(null, null, gates, reloaded)
	assert_true(fresh.is_lesson_done(1))
	assert_true(fresh.is_lesson_done(3))
	assert_true(gates.gate_flag(SliceLayout.GATE_G1))
	assert_true(gates.gate_flag(SliceLayout.GATE_G2))
	assert_false(gates.gate_flag(SliceLayout.GATE_G3))


func test_absent_slice_fields_on_an_old_save_default_to_zero() -> void:
	_discard(_SAVE)
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", 42)
	cfg.save(_SAVE)
	var loaded := SaveGame.load_from(_SAVE)
	assert_eq(loaded.slice_lessons, 0)
	assert_eq(loaded.slice_gates, 0)
	assert_eq(loaded.slice_packs, 0)
	assert_eq(loaded.slice_lesson_at, [])


func test_dying_in_room_c_respawns_at_the_origin_and_keeps_open_gates() -> void:
	progress.complete_lesson(1)
	progress.complete_lesson(2)
	progress.complete_lesson(3)
	progress.complete_lesson(4)
	progress.complete_lesson(5)
	assert_true(layout.gate_flag(SliceLayout.GATE_G1))
	assert_true(layout.gate_flag(SliceLayout.GATE_G2))
	assert_true(layout.gate_flag(SliceLayout.GATE_G3))
	player.global_position = Vector2(4700, 180)
	assert_eq(SliceLayout.room_at(player.global_position), SliceLayout.ROOM_C)
	# Five hits of 1, clearing i-frames between them.
	for _i in range(5):
		assert_true(player.health.damage(1.0))
		if not player.health.is_dead():
			_tick_health(player.health.invulnerability_time)
	assert_true(player.health.is_dead())
	assert_signal_emitted(player, "died")
	assert_signal_emitted(progress, "died")
	assert_eq(RespawnPoints.get_respawn_position(), Vector2.ZERO)
	player.respawn(RespawnPoints.get_respawn_position())
	assert_eq(player.global_position, Vector2.ZERO)
	assert_eq(player.health.hp, 5.0)
	assert_false(player.health.is_engine_invulnerable())
	assert_signal_emitted(player, "respawned")
	assert_signal_emitted(progress, "respawned")
	assert_true(progress.is_lesson_done(1))
	assert_true(progress.is_lesson_done(5))
	assert_true(layout.gate_flag(SliceLayout.GATE_G1))
	assert_true(layout.gate_flag(SliceLayout.GATE_G2))
	assert_true(layout.gate_flag(SliceLayout.GATE_G3))


func test_regen_is_disabled_while_the_player_centre_is_in_room_b() -> void:
	assert_true(player.health.damage(2.0))
	assert_eq(player.health.hp, 3.0)
	player.global_position = SliceLayout.room_rect(SliceLayout.ROOM_B).get_center()
	progress.tick(DT)
	assert_false(player.health.regen_enabled)
	_tick_health(5.0)
	assert_eq(player.health.hp, 3.0, "no regen inside B")
	player.global_position = Vector2.ZERO
	progress.tick(DT)
	assert_true(player.health.regen_enabled)
	# The delay has already elapsed, so the first point is owed on the next tick.
	_tick_health(DT)
	assert_eq(player.health.hp, 4.0)


func test_hud_signals_fire_for_hp_death_respawn_lessons_and_gates() -> void:
	assert_true(player.health.damage(1.0))
	assert_signal_emitted(progress, "hp_changed")
	progress.complete_lesson(1)
	progress.complete_lesson(2)
	assert_signal_emitted(progress, "lesson_completed")
	assert_signal_emitted(progress, "gate_opened")
	player.health.reset()
	for _i in range(5):
		player.health.clear_engine_invulnerability()
		player.health.damage(1.0)
	assert_true(player.health.is_dead())
	assert_signal_emitted(progress, "died")
	player.respawn(Vector2(10, 0))
	assert_signal_emitted(progress, "respawned")
	assert_signal_emitted(progress, "hp_changed")


func test_main_scene_has_a_slice_progress_node() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	var state := packed.get_state()
	var found := false
	for i in range(state.get_node_count()):
		if state.get_node_name(i) == "SliceProgress":
			found = true
			break
	assert_true(found, "main.tscn should instance SliceProgress")
