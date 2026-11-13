extends GutTest
## Row 8 Warden phase 1: HP / phases, weak-point damage, kill order, boss-bar
## signals, arena containment, tithe, and Lance flags.

const DT := 1.0 / 60.0
const ARENA := SliceLayout.ARENA_CENTRE


func after_each() -> void:
	WorldQuery.reset()


func test_starts_at_900_in_phase_1_inside_the_arena() -> void:
	var warden := _warden()
	assert_eq(warden.health.max_hp, Warden.MAX_HP)
	assert_eq(warden.health.hp, Warden.MAX_HP)
	assert_eq(warden.current_phase(), 1)
	assert_false(warden.is_aggroed())
	var arena := SliceLayout.room_rect(SliceLayout.ROOM_E)
	assert_true(arena.has_point(ARENA), "arena rect contains the centre")
	assert_true(arena.has_point(warden.global_position))
	assert_eq(warden.gap_degrees(), 70.0)


func test_scene_warden_sits_at_the_arena_centre() -> void:
	var warden := (preload("res://scenes/warden.tscn") as PackedScene).instantiate() as Warden
	warden.position = ARENA
	add_child_autofree(warden)
	assert_eq(warden.position, ARENA)
	assert_true(SliceLayout.room_rect(SliceLayout.ROOM_E).has_point(warden.position))
	var health := warden.get_node("Health") as Health
	assert_not_null(health)
	assert_eq(health.name, "Health")


func test_phase_thresholds_clamp_forward_and_do_not_go_back() -> void:
	var warden := _warden()
	var seen: Array[int] = []
	warden.phase_changed.connect(func(phase: int) -> void: seen.append(phase))
	warden.health.set_hp(631.0)
	assert_eq(warden.current_phase(), 1)
	assert_eq(seen, [])
	warden.health.set_hp(630.0)
	assert_eq(warden.current_phase(), 2)
	assert_eq(seen, [2])
	warden.health.heal(200.0)
	assert_eq(warden.health.hp, 830.0)
	assert_eq(warden.current_phase(), 2, "heal does not step the phase back")
	warden.health.set_hp(360.0)
	assert_eq(warden.current_phase(), 3)
	assert_eq(seen, [2, 3])
	warden.health.set_hp(1.0)
	assert_eq(warden.current_phase(), 3)
	assert_eq(seen, [2, 3])


func test_a_single_hit_crossing_both_thresholds_walks_2_then_3() -> void:
	var warden := _warden()
	var seen: Array[int] = []
	warden.phase_changed.connect(func(phase: int) -> void: seen.append(phase))
	warden.health.set_hp(300.0)
	assert_eq(warden.current_phase(), 3)
	assert_eq(seen, [2, 3])


func test_pre_aggro_shots_deal_zero() -> void:
	var warden := _warden()
	assert_false(warden.is_aggroed())
	warden.apply_debug_hit(warden.global_position, 100.0)
	warden.apply_debug_hit(warden.gap_point(), 100.0)
	assert_eq(warden.health.hp, Warden.MAX_HP)
	assert_eq(warden.husks().size(), 0)


func test_body_centre_is_tenth_damage_and_gap_tick_is_full() -> void:
	var warden := _warden()
	warden.debug_force_aggro()
	assert_eq(Warden.ARMOR_ABSORBS, false, "spec default is ×0.1, not vanish")
	warden.apply_debug_hit(warden.global_position, 100.0)
	assert_almost_eq(warden.health.hp, Warden.MAX_HP - 10.0, 0.001)
	var after_body := warden.health.hp
	warden.apply_debug_hit(warden.gap_point(), 100.0)
	assert_almost_eq(warden.health.hp, after_body - 100.0, 0.001)


func test_armor_ring_gap_does_not_shrink_with_hp() -> void:
	var warden := _warden()
	warden.debug_force_aggro()
	var at_full := warden.gap_degrees()
	warden.health.set_hp(10.0)
	assert_eq(warden.gap_degrees(), at_full)
	assert_eq(warden.gap_degrees(), 70.0)


func test_kill_emits_enemy_killed_then_boss_defeated_with_id_warden() -> void:
	var warden := _warden()
	warden.debug_force_aggro()
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
	assert_false(warden.is_alive())
	assert_eq(warden.health.hp, 0.0)


func test_boss_bar_signals_report_hp_and_max_and_phase_changes() -> void:
	var warden := _warden()
	var ticks: Array[Vector2] = []
	warden.health.hp_changed.connect(
		func(hp: float, max_hp: float) -> void: ticks.append(Vector2(hp, max_hp))
	)
	var phases: Array[int] = []
	warden.phase_changed.connect(func(phase: int) -> void: phases.append(phase))
	warden.debug_force_aggro()
	warden.apply_debug_hit(warden.gap_point(), 270.0)
	assert_gt(ticks.size(), 0)
	var last: Vector2 = ticks[ticks.size() - 1]
	assert_eq(last.y, Warden.MAX_HP)
	assert_almost_eq(last.x, Warden.MAX_HP - 270.0, 0.001)
	assert_eq(phases, [2])


func test_husk_death_tithes_50_unless_the_core_is_already_dead() -> void:
	var warden := _warden()
	warden.debug_force_aggro()
	assert_eq(warden.husks().size(), 3)
	warden.health.set_hp(800.0)
	var husk := warden.husks()[1]
	assert_not_null(husk)
	husk.health.set_hp(0.0)
	assert_almost_eq(warden.health.hp, 850.0, 0.001)
	# Same-tick / already-dead core is not healed.
	var other := _warden(ARENA + Vector2(0, 400))
	other.debug_force_aggro()
	other.health.set_hp(0.0)
	assert_false(other.is_alive())
	other.notify_husk_died(0, other.global_position)
	assert_eq(other.health.hp, 0.0)
	assert_false(other.is_alive())


func test_nearest_enemy_from_outside_the_near_husk_is_that_husk() -> void:
	var player := _player(ARENA + Vector2(-400, 0))
	var warden := _warden()
	warden.bind(player, null)
	warden.debug_force_aggro()
	# One physics tick so the lock husk sits on the player bearing (west).
	warden._physics_process(DT)
	var husk := warden.husks()[0]
	assert_not_null(husk)
	player.global_position = husk.global_position + Vector2(-WardenHusk.RADIUS - Warden.PLAYER_RADIUS, 0.0)
	WorldQuery.refresh(DT)
	var row := WorldQuery.nearest_enemy(player.global_position, 400.0)
	assert_false(row.is_empty())
	var kind: StringName = row["kind"]
	var eid: int = row["id"]
	assert_eq(kind, EnemyKinds.HUSK)
	assert_eq(eid, husk.get_instance_id())


func test_lance_flags_and_dash_blocks_the_pip() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 64
	manager.world_bounds = Rect2(8000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var player := _player(ARENA + Vector2(-200, 0))
	var warden := _warden()
	warden.bind(player, manager)
	warden.debug_force_aggro()
	# Fire immediately along the locked telegraph line (no 0.6 s wait).
	warden.last_lance = null
	warden.call("_begin_lance_windup")
	assert_true(warden._lance_winding)
	assert_almost_eq(warden._lance_windup, Warden.LANCE_WINDUP, 0.001)
	warden.call("_fire_lance")
	assert_not_null(warden.last_lance)
	assert_eq(warden.last_lance.pierces_script_invuln, false)
	assert_eq(warden.last_lance.damage, 1.0)
	assert_eq(warden.last_lance.radius, Warden.LANCE_RADIUS)
	assert_almost_eq(warden.last_lance.lifetime, Warden.LANCE_LIFETIME, 0.001)
	assert_almost_eq(warden.last_lance.velocity.length(), Warden.LANCE_SPEED, 0.001)
	assert_eq(warden.last_lance.color, Warden.LANCE_COLOR)
	# A second shot at the player while engine i-frames (a dash) are on deals 0.
	player.health.reset()
	player.health.add_engine_invulnerability(1.0)
	var before := player.health.hp
	var req := ShotRequest.with_velocity(player.global_position, Vector2.ZERO)
	req.radius = Warden.LANCE_RADIUS
	req.damage = Warden.LANCE_DAMAGE
	req.hit_mask = Layers.PLAYER
	req.owner_layer = Layers.ENEMY
	req.pierces_script_invuln = false
	req.lifetime = 1.0
	manager.spawn(req)
	manager.step(DT)
	assert_eq(player.health.hp, before)


func test_notify_warden_defeated_hook_runs_when_slice_progress_exists() -> void:
	var progress := _StubProgress.new()
	progress.name = "SliceProgress"
	add_child_autofree(progress)
	var warden := _warden()
	warden.health.set_hp(0.0)
	assert_eq(progress.calls, 1)


func test_player_death_resets_a_living_boss() -> void:
	var warden := _warden()
	warden.debug_force_aggro()
	warden.health.set_hp(500.0)
	assert_eq(warden.current_phase(), 2)
	assert_true(warden.is_aggroed())
	warden.on_player_died()
	assert_eq(warden.health.hp, Warden.MAX_HP)
	assert_eq(warden.current_phase(), 1)
	assert_false(warden.is_aggroed())
	assert_true(warden.is_alive())


func test_debug_spawn_places_and_aggros() -> void:
	var warden := Warden.spawn_for_debug(self, ARENA)
	autoqfree(warden)
	assert_eq(warden.position, ARENA)
	assert_true(warden.is_aggroed())
	assert_eq(warden.husks().size(), 3)


func test_lance_first_windup_is_1s_then_period_is_start_to_start() -> void:
	var warden := _warden()
	warden.debug_force_aggro()
	assert_almost_eq(warden._lance_wait, Warden.LANCE_FIRST_WAIT, 0.001)
	warden._physics_process(Warden.LANCE_FIRST_WAIT)
	assert_true(warden._lance_winding)
	assert_almost_eq(warden._lance_windup, Warden.LANCE_WINDUP, 0.001)
	warden._physics_process(Warden.LANCE_WINDUP)
	assert_false(warden._lance_winding)
	assert_almost_eq(warden._lance_wait, Warden.LANCE_PERIOD - Warden.LANCE_WINDUP, 0.001)


func test_lock_moves_to_the_nearest_living_husk_and_others_re_space() -> void:
	# Offset from due west so one of the two remaining husks is clearly closer.
	var player := _player(ARENA + Vector2(-400, -80))
	var warden := _warden()
	warden.bind(player, null)
	warden.debug_force_aggro()
	assert_eq(warden.lock_slot(), 0)
	var bearing := (player.global_position - warden.global_position).angle()
	var expected := -1
	var best := INF
	for i in warden.husks().size():
		if i == 0:
			continue
		var husk: WardenHusk = warden.husks()[i]
		var diff := absf(angle_difference(husk.orbit_angle, bearing))
		if diff < best:
			best = diff
			expected = i
	warden.lock_husk().health.set_hp(0.0)
	assert_eq(warden.lock_slot(), expected)
	var mover: WardenHusk = null
	for husk in warden.husks():
		if husk != null and husk.is_alive() and husk != warden.lock_husk():
			mover = husk
			break
	assert_not_null(mover)
	var before := mover.orbit_angle
	var target := warden.lock_angle() + PI
	var gap := absf(angle_difference(before, target))
	assert_gt(gap, deg_to_rad(40.0))
	var step := 0.2
	warden._physics_process(step)
	var moved := absf(angle_difference(before, mover.orbit_angle))
	assert_almost_eq(moved, Warden.HUSK_TURN * step, 0.01)
	assert_gt(absf(angle_difference(mover.orbit_angle, target)), deg_to_rad(20.0))


func test_respawned_husk_takes_the_lock_only_when_alone() -> void:
	var player := _player(ARENA + Vector2(-400, 0))
	var warden := _warden()
	warden.bind(player, null)
	warden.debug_force_aggro()
	var kept := warden.lock_slot()
	var other := 1 if kept != 1 else 2
	warden.husks()[other].health.set_hp(0.0)
	warden._physics_process(Warden.HUSK_RESPAWN)
	assert_eq(warden.lock_slot(), kept, "a respawn does not steal the lock")
	assert_not_null(warden.husks()[other])
	assert_true(warden.husks()[other].is_alive())

	var warden2 := _warden(ARENA + Vector2(0, 400))
	warden2.bind(player, null)
	warden2.debug_force_aggro()
	for husk in warden2.husks():
		if husk != null and husk.is_alive():
			husk.health.set_hp(0.0)
	assert_null(warden2.lock_husk())
	var far := (player.global_position - warden2.global_position).angle() + PI
	warden2._physics_process(Warden.HUSK_RESPAWN)
	assert_eq(warden2._living_husk_count(), 3)
	assert_eq(warden2.lock_slot(), 0, "first respawned husk takes the empty lock")
	assert_almost_eq(angle_difference(warden2.lock_angle(), far), 0.0, 0.001)


func test_it_feeds_once_per_save_not_after_a_death_reset() -> void:
	var save := _temp_save("feeds")
	assert_eq(save.seen_it_feeds, false)
	var warden := _warden()
	warden.bind(_player(ARENA + Vector2(-400, 0)), null, null, save)
	warden.debug_force_aggro()
	warden.health.set_hp(800.0)
	warden.husks()[1].health.set_hp(0.0)
	assert_true(warden.feeds_line_visible())
	assert_true(save.seen_it_feeds)
	assert_true(SaveGame.load_from(save.path).seen_it_feeds)
	warden.on_player_died()
	assert_false(warden.feeds_line_visible())
	warden.debug_force_aggro()
	warden.health.set_hp(800.0)
	warden.husks()[1].health.set_hp(0.0)
	assert_false(warden.feeds_line_visible())
	assert_almost_eq(warden.health.hp, 850.0, 0.001)


func test_seen_it_feeds_missing_or_non_bool_reads_as_false() -> void:
	var missing_path := "user://test_tmp/feeds_missing_%d.cfg" % Time.get_ticks_usec()
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", 1)
	cfg.save(missing_path)
	var missing := SaveGame.load_from(missing_path)
	assert_eq(missing.seen_it_feeds, false)

	var bad_path := "user://test_tmp/feeds_int_%d.cfg" % Time.get_ticks_usec()
	cfg = ConfigFile.new()
	cfg.set_value("world", "world_seed", 1)
	cfg.set_value("world", "seen_it_feeds", 1)
	cfg.save(bad_path)
	var bad := SaveGame.load_from(bad_path)
	assert_eq(bad.seen_it_feeds, false)

	var ok := _temp_save("feeds_true")
	ok.seen_it_feeds = true
	ok.save()
	assert_eq(SaveGame.load_from(ok.path).seen_it_feeds, true)


class _StubProgress:
	extends Node
	var calls := 0

	func notify_warden_defeated() -> void:
		calls += 1


func _warden(at: Vector2 = ARENA) -> Warden:
	var warden := Warden.new()
	warden.position = at
	add_child_autofree(warden)
	return warden


func _player(at: Vector2) -> Player:
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = at
	add_child_autofree(player)
	return player


func _temp_save(label: String) -> SaveGame:
	var save := SaveGame.new()
	save.path = "user://test_tmp/warden_%s_%d.cfg" % [label, Time.get_ticks_usec()]
	save.world_seed = 1
	save.save()
	return save
