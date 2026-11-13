extends GutTest
## Vertical-slice row 4: room-A shielded dummy, room-B pad and plate,
## lesson 3–5 checkers, and SaveGame._read guards.

const DT := 1.0 / 60.0
const _SAVE := "user://gut_slice_rooms_ab.cfg"

var progress: SliceProgress
var layout: SliceLayout
var player: Player
var dummies: Node2D
var east: TrainingDummy
var north: TrainingDummy
var south: TrainingDummy
var shield: TrainingDummy
var hp_dummy: TrainingDummy
var pad: LessonPad
var plate: LessonPlate
var save: SaveGame
var bullets: BulletManager


func before_each() -> void:
	RespawnPoints.reset()
	_discard(_SAVE)
	progress = SliceProgress.new()
	add_child_autofree(progress)
	layout = SliceLayout.new()
	add_child_autofree(layout)
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector2(-400, 0)
	add_child_autofree(player)
	player.set_physics_process(false)
	player.health.set_physics_process(false)
	dummies = Node2D.new()
	add_child_autofree(dummies)
	east = _make_dummy(SliceProgress.EAST_DUMMY)
	north = _make_dummy(SliceProgress.NORTH_DUMMY)
	south = _make_dummy(SliceProgress.SOUTH_DUMMY)
	shield = _make_dummy(SliceProgress.SHIELD_DUMMY)
	shield.absorb = true
	shield.absorb_facing = PI
	shield.absorb_arc_deg = 120.0
	hp_dummy = _make_dummy(SliceProgress.PAD_DUMMY)
	hp_dummy.hurtbox_hp_cap = 4.0
	pad = LessonPad.new()
	pad.position = Vector2(2780, 0)
	add_child_autofree(pad)
	plate = LessonPlate.new()
	plate.position = Vector2(3500, 0)
	add_child_autofree(plate)
	bullets = BulletManager.new()
	bullets.auto_step = false
	bullets.render_enabled = false
	bullets.world_bounds = Rect2(-2000, -2000, 8000, 4000)
	add_child_autofree(bullets)
	save = SaveGame.new()
	save.path = _SAVE
	save.world_seed = 1
	await wait_physics_frames(2)
	# Re-apply absorb / cap after _ready (exports set before add_child are
	# kept; the shield dummy was configured before add in _make_dummy... 
	# _make_dummy adds immediately, so set absorb after and re-run the
	# hurtbox fields).
	_apply_shield()
	hp_dummy.hurtbox_hp_cap = 4.0
	progress.bind(player, dummies, layout, save, null, bullets)
	watch_signals(progress)


func after_each() -> void:
	RespawnPoints.reset()
	_discard(_SAVE)
	WorldQuery.reset()


func _apply_shield() -> void:
	shield.absorb = true
	shield.absorb_facing = PI
	shield.absorb_arc_deg = 120.0
	var box := shield.get_node_or_null("Hurtbox") as Hurtbox
	if box != null:
		box.response = Hurtbox.Response.ABSORB
		box.facing = PI
		box.arc_deg = 120.0


func _make_dummy(at: Vector2) -> TrainingDummy:
	var dummy := (load("res://scenes/training_dummy.tscn") as PackedScene).instantiate() as TrainingDummy
	dummy.position = at
	dummy.set_process(false)
	dummies.add_child(dummy)
	return dummy


func _discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _spawn_player_bullet(at: Vector2, velocity: Vector2, radius: float = 4.0) -> int:
	var req := ShotRequest.new()
	req.position = at
	req.velocity = velocity
	req.radius = radius
	req.lifetime = 4.0
	req.damage = 40.0
	req.owner_layer = Layers.PLAYER
	req.hit_mask = Layers.ENEMY
	return bullets.spawn(req)


# --- lesson 3: shielded dummy ------------------------------------------------

func test_straight_shots_into_the_west_arc_deal_zero() -> void:
	var box := shield.get_node("Hurtbox") as Hurtbox
	assert_eq(box.response, Hurtbox.Response.ABSORB)
	assert_true(box.absorbs(shield.global_position + Vector2(-22, 0)), "west contact is inside the arc")
	assert_false(box.absorbs(shield.global_position + Vector2(22, 0)), "east contact is the open side")
	var hp := shield.health
	# A real westward shot into the face: absorbed, no hit, dummy lives.
	_spawn_player_bullet(shield.global_position + Vector2(-30, 0), Vector2(800, 0))
	bullets.step(DT)
	assert_eq(shield.health, hp)
	assert_eq(shield.deaths, 0)
	assert_false(progress.is_lesson_done(3))
	assert_false(layout.gate_flag(SliceLayout.GATE_G2))


func test_an_open_side_hit_kills_the_shielded_dummy_and_opens_g2() -> void:
	var box := shield.get_node("Hurtbox") as Hurtbox
	assert_false(box.absorbs(shield.global_position + Vector2(22, 0)))
	_spawn_player_bullet(shield.global_position + Vector2(30, 0), Vector2(-800, 0))
	bullets.step(DT)
	assert_eq(shield.deaths, 1)
	assert_true(progress.is_lesson_done(3))
	assert_true(layout.gate_flag(SliceLayout.GATE_G2))
	assert_signal_emitted(progress, "lesson_completed")
	assert_signal_emitted(progress, "gate_opened")


func test_a_respawned_dummy_death_emits_first_death_false() -> void:
	var kinds: Array[StringName] = []
	var firsts: Array[bool] = []
	var killed := func(
		kind: StringName, _r: int, _t: int, _p: Vector2, first: bool
	) -> void:
		kinds.append(kind)
		firsts.append(first)
	GameEvents.enemy_killed.connect(killed)
	shield._on_hit(40.0, shield.global_position, Vector2.RIGHT)
	assert_eq(kinds, [EnemyKinds.DUMMY])
	assert_eq(firsts, [true])
	shield._process(shield.respawn_delay)
	shield._on_hit(40.0, shield.global_position, Vector2.RIGHT)
	GameEvents.enemy_killed.disconnect(killed)
	assert_eq(kinds.size(), 2)
	assert_eq(kinds[1], EnemyKinds.DUMMY)
	assert_eq(firsts[1], false)


# --- lesson 4: pad + hurtbox gate -------------------------------------------

func test_pad_deals_one_pip_after_0_6s_only_when_hp_is_5() -> void:
	assert_eq(player.health.hp, 5.0)
	player.global_position = Vector2(2780, 0)
	progress.tick(DT)
	assert_true(pad.is_winding())
	assert_eq(player.health.hp, 5.0)
	progress.tick(LessonPad.WINDUP - DT)
	assert_almost_eq(player.health.hp, 4.0, 0.001)
	assert_false(pad.is_winding())

	# Re-entry at hp 4 does nothing.
	player.global_position = Vector2(0, 0)
	progress.tick(DT)
	player.global_position = Vector2(2780, 0)
	progress.tick(LessonPad.WINDUP + DT)
	assert_almost_eq(player.health.hp, 4.0, 0.001)
	assert_false(pad.is_winding())


func test_pad_dummy_hurtbox_is_off_while_hp_is_above_4() -> void:
	var box := hp_dummy.get_node("Hurtbox") as Hurtbox
	assert_eq(player.health.hp, 5.0)
	progress.tick(DT)
	assert_false(box.active)
	player.health.set_hp(4.0)
	progress.tick(DT)
	assert_true(box.active)
	# Setting hp back to 5 (the script "cheat") turns it off again.
	player.health.set_hp(5.0)
	progress.tick(DT)
	assert_false(box.active)


func test_lesson_4_passes_only_when_the_killing_blow_lands_at_hp_4_or_less() -> void:
	# A forced kill while still at 5 does not pass.
	hp_dummy._on_hit(40.0, hp_dummy.global_position, Vector2.RIGHT)
	assert_eq(hp_dummy.deaths, 1)
	assert_false(progress.is_lesson_done(4))
	hp_dummy._process(hp_dummy.respawn_delay)
	player.health.set_hp(4.0)
	progress.tick(DT)
	hp_dummy._on_hit(40.0, hp_dummy.global_position, Vector2.RIGHT)
	assert_true(progress.is_lesson_done(4))
	assert_false(layout.gate_flag(SliceLayout.GATE_G3), "G3 also needs lesson 5")


func test_lessons_3_and_4_pass_when_dummies_live_under_lesson_props() -> void:
	# Shipping layout: the three origin targets stay under Dummies; the room
	# A/B dummies, pad and plate sit under LessonProps, a sibling of Dummies.
	var props := Node2D.new()
	props.name = "LessonProps"
	add_child_autofree(props)
	for node: Node in [shield, hp_dummy, pad, plate]:
		node.get_parent().remove_child(node)
		props.add_child(node)
	progress.bind(player, dummies, layout, save, null, bullets)
	assert_eq(shield.get_parent().name, "LessonProps")
	assert_eq(hp_dummy.get_parent().name, "LessonProps")
	# Lesson 3: an open-side kill on the shield dummy must complete.
	_spawn_player_bullet(shield.global_position + Vector2(30, 0), Vector2(-800, 0))
	bullets.step(DT)
	assert_eq(shield.deaths, 1)
	assert_true(progress.is_lesson_done(3), "destroyed must be connected off LessonProps")
	# Lesson 4: a killing blow at 4 HP or less.
	player.health.set_hp(4.0)
	progress.tick(DT)
	hp_dummy._on_hit(40.0, hp_dummy.global_position, Vector2.RIGHT)
	assert_true(progress.is_lesson_done(4))


# --- lesson 5: plate --------------------------------------------------------

func test_plate_reports_overlap_speed_and_passes_at_640_after_a_save() -> void:
	_spawn_player_bullet(plate.global_position, Vector2(800, 0), 8.0)
	# Not armed yet: reports the speed, does not complete.
	var speed := plate.scan(bullets)
	assert_almost_eq(speed, 800.0, 0.001)
	assert_almost_eq(progress.plate_last_speed(), 800.0, 0.001)
	assert_false(progress.is_lesson_done(5))

	progress.debug_arm_lesson_5()
	# Below the threshold: still reported, still not passed.
	bullets.clear_bullets()
	_spawn_player_bullet(plate.global_position, Vector2(639, 0), 8.0)
	speed = plate.scan(bullets)
	assert_almost_eq(speed, 639.0, 0.001)
	assert_false(progress.is_lesson_done(5))

	bullets.clear_bullets()
	_spawn_player_bullet(plate.global_position, Vector2(640, 0), 8.0)
	progress.tick(DT)
	assert_true(progress.is_lesson_done(5))
	assert_almost_eq(progress.plate_last_speed(), 640.0, 0.001)


func test_lesson_5_arms_on_equipped_editor_or_file_save_not_other_origins() -> void:
	progress._on_script_saved("shots/default.lua", ShotScripts.ORIGIN_START)
	assert_false(progress.is_lesson_5_armed())
	progress._on_script_saved("shots/default.lua", ShotScripts.ORIGIN_EDITOR)
	assert_true(progress.is_lesson_5_armed())
	# Re-bind clears the arm (fresh session hook); file origin also arms.
	progress.bind(player, dummies, layout, save, null, bullets)
	assert_false(progress.is_lesson_5_armed())
	progress._on_script_saved("shots/default.lua", ShotScripts.ORIGIN_FILE)
	assert_true(progress.is_lesson_5_armed())


func test_lessons_4_and_5_together_open_g3_in_either_order() -> void:
	player.health.set_hp(4.0)
	progress.tick(DT)
	hp_dummy._on_hit(40.0, hp_dummy.global_position, Vector2.RIGHT)
	assert_true(progress.is_lesson_done(4))
	assert_false(layout.gate_flag(SliceLayout.GATE_G3))
	progress.debug_arm_lesson_5()
	_spawn_player_bullet(plate.global_position, Vector2(700, 0), 8.0)
	progress.tick(DT)
	assert_true(progress.is_lesson_done(5))
	assert_true(layout.gate_flag(SliceLayout.GATE_G3))


# --- save guards ------------------------------------------------------------

func test_save_read_type_guards_every_key_and_sanitizes_field_times() -> void:
	var path := "user://gut_slice_rooms_ab_bad.cfg"
	_discard(path)
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", 42)
	cfg.set_value("world", "herald_done", true)
	cfg.set_value("world", "shards", "nope")
	cfg.set_value("world", "elite_kills", "not-an-array")
	cfg.set_value("world", "regular_absent", {"x": 1})
	cfg.set_value("world", "slice_lessons", "bad")
	cfg.set_value("world", "slice_gates", 3)
	cfg.set_value("world", "slice_packs", 1.0)
	cfg.set_value("world", "field_drifters", INF)
	cfg.set_value("world", "field_swarmers", -NAN)
	cfg.set_value("world", "field_shield", -10.0)
	cfg.set_value("world", "field_sniper", "later")
	cfg.save(path)
	var loaded := SaveGame.load_from(path)
	assert_eq(loaded.world_seed, 42, "a good key still loads after a bad one")
	assert_eq(loaded.herald_done, true)
	assert_eq(loaded.shards, 0)
	assert_eq(loaded.elite_kills, [])
	assert_eq(loaded.regular_absent, [])
	assert_eq(loaded.slice_lessons, 0)
	assert_eq(loaded.slice_gates, 3)
	assert_eq(loaded.slice_packs, 1)
	assert_eq(loaded.field_drifters, 0.0)
	assert_eq(loaded.field_swarmers, 0.0)
	assert_eq(loaded.field_shield, 0.0)
	assert_eq(loaded.field_sniper, 0.0)
	assert_true(loaded.field_pack_is_present(SaveGame.FIELD_DRIFTERS))
	_discard(path)


func test_main_scene_places_the_room_a_and_b_props() -> void:
	var scene := load("res://scenes/main.tscn") as PackedScene
	var state := scene.get_state()
	var names: Array[String] = []
	for i in state.get_node_count():
		names.append(String(state.get_node_name(i)))
	assert_true(names.has("ShieldDummy"))
	assert_true(names.has("HpDummy"))
	assert_true(names.has("LessonPad"))
	assert_true(names.has("LessonPlate"))
	assert_true(names.has("LessonProps"))
