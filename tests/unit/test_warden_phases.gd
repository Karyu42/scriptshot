extends GutTest
## Row 9: Fan, Broken ring, phasing husks, habituation, husk counts, and
## kill order across phase transitions (SE #76 nit 4).

const DT := 1.0 / 60.0
const ARENA := SliceLayout.ARENA_CENTRE
const SIG := Vector2(760, 0)  # default player-shot speed, due east


func after_each() -> void:
	WorldQuery.reset()


func test_husk_count_is_3_then_4_then_2() -> void:
	var warden := _ready_fight()
	assert_eq(warden._living_husk_count(), 3)
	assert_eq(warden.husk_cap(), 3)
	warden.health.set_hp(Warden.PHASE_2_HP)
	assert_eq(warden.current_phase(), 2)
	assert_eq(warden.husk_cap(), 4)
	assert_eq(warden._living_husk_count(), 4)
	warden.health.set_hp(Warden.PHASE_3_HP)
	assert_eq(warden.current_phase(), 3)
	assert_eq(warden.husk_cap(), 2)
	assert_eq(warden._living_husk_count(), 2)


func test_lance_stops_and_fan_starts_on_phase_2() -> void:
	var warden := _ready_fight()
	warden._physics_process(Warden.LANCE_FIRST_WAIT)
	assert_true(warden._lance_winding)
	warden.health.set_hp(Warden.PHASE_2_HP)
	warden.last_lance = null
	warden.last_fan.clear()
	warden._physics_process(Warden.LANCE_WINDUP)
	assert_null(warden.last_lance)
	assert_false(warden._lance_winding)
	warden._physics_process(Warden.FAN_FIRST_WAIT)
	assert_true(warden._fan_winding)
	assert_almost_eq(warden._fan_windup, Warden.FAN_WINDUP, 0.001)
	warden._physics_process(Warden.FAN_WINDUP)
	assert_eq(warden.last_fan.size(), Warden.FAN_COUNT)
	for req in warden.last_fan:
		assert_eq(req.damage, 1.0)
		assert_eq(req.pierces_script_invuln, false)
		assert_eq(req.behavior_id, 0)
		assert_almost_eq(req.velocity.length(), Warden.FAN_SPEED, 0.001)
	var first: float = warden.last_fan[0].velocity.angle()
	var last: float = warden.last_fan[Warden.FAN_COUNT - 1].velocity.angle()
	assert_almost_eq(absf(angle_difference(first, last)), Warden.FAN_ARC, 0.02)


func test_fan_stops_and_ring_starts_on_phase_3() -> void:
	var warden := _ready_fight()
	warden.health.set_hp(Warden.PHASE_2_HP)
	warden._physics_process(Warden.FAN_FIRST_WAIT)
	assert_true(warden._fan_winding)
	warden.last_fan.clear()
	warden.health.set_hp(Warden.PHASE_3_HP)
	warden._physics_process(Warden.FAN_WINDUP)
	assert_eq(warden.last_fan.size(), 0)
	assert_false(warden._fan_winding)
	warden._physics_process(Warden.RING_FIRST_WAIT)
	assert_true(warden._ring_winding)
	assert_false(warden._ring_locked)
	warden._physics_process(Warden.RING_TRACK)
	assert_true(warden._ring_locked)
	warden._physics_process(Warden.RING_WINDUP - Warden.RING_TRACK)
	assert_gt(warden.last_ring.size(), 0)
	assert_eq(warden.last_ring[0].damage, 1.0)
	assert_eq(warden.last_ring[0].behavior_id, 0)
	assert_almost_eq(warden.last_ring[0].velocity.length(), Warden.RING_SPEED, 0.001)
	var gap_hits := 0
	for req in warden.last_ring:
		var ang := (req.position - warden.global_position).angle()
		if absf(angle_difference(ang, warden._ring_gap)) <= Warden.RING_GAP * 0.5:
			gap_hits += 1
		assert_eq(req.damage, 1.0)
		assert_eq(req.pierces_script_invuln, false)
	assert_eq(gap_hits, 0, "the locked 50° gap is empty")
	assert_eq(warden.last_ring.size() + 3, Warden.RING_DOTS)


func test_phasing_husks_only_take_damage_inside_the_pulse() -> void:
	var warden := _ready_fight()
	warden.health.set_hp(Warden.PHASE_2_HP)
	var side := _a_phasing_husk(warden)
	assert_not_null(side)
	assert_true(side.phasing)
	assert_false(side.phase_open)
	var hp := side.health.hp
	side._on_hit(10.0, side.global_position, Vector2.ZERO)
	assert_eq(side.health.hp, hp, "absorb while closed")
	warden._physics_process(Warden.PHASE_PULSE_PERIOD - Warden.PHASE_PULSE_OPEN)
	assert_true(warden.is_phasing_pulse_open())
	assert_true(side.phase_open)
	side._on_hit(10.0, side.global_position, Vector2.ZERO)
	assert_almost_eq(side.health.hp, hp - 10.0, 0.001)


func test_habituation_drops_same_signature_and_flag_off_does_not() -> void:
	var habit := WardenHabituation.new()
	# Keep the same signature dominant for long enough to reach the floor.
	for _i in 6:
		habit.record_hit(SIG)
		habit.advance(WardenHabituation.CADENCE)
	assert_almost_eq(habit.multiplier, WardenHabituation.FLOOR_MUL, 0.001)
	# Once the 10 s window has no hits, the multiplier recovers 0.2 per 5 s.
	habit.advance(WardenHabituation.WINDOW)
	assert_almost_eq(
		habit.multiplier,
		WardenHabituation.FLOOR_MUL + 2.0 * WardenHabituation.RECOVER,
		0.001
	)

	var off := WardenHabituation.new()
	off.enabled = false
	off.record_hit(SIG)
	off.advance(WardenHabituation.CADENCE)
	assert_eq(off.multiplier, 1.0)

	var warden := _ready_fight()
	warden.boss_habituation = true
	warden.habituation.reset()
	warden.habituation.enabled = true
	warden.apply_debug_hit(warden.gap_point(), 1.0, 0, SIG)
	warden._physics_process(WardenHabituation.CADENCE)
	var before := warden.health.hp
	warden.apply_debug_hit(warden.gap_point(), 100.0, 0, SIG)
	assert_almost_eq(warden.health.hp, before - 90.0, 0.05)

	var plain := _ready_fight(ARENA + Vector2(0, 500))
	plain.boss_habituation = false
	plain.habituation.reset()
	plain.habituation.enabled = false
	plain.apply_debug_hit(plain.gap_point(), 1.0, 0, SIG)
	plain._physics_process(WardenHabituation.CADENCE)
	before = plain.health.hp
	plain.apply_debug_hit(plain.gap_point(), 100.0, 0, SIG)
	assert_almost_eq(plain.health.hp, before - 100.0, 0.001)


func test_previous_phase_attack_never_fires_after_the_change() -> void:
	var warden := _ready_fight()
	warden._physics_process(Warden.LANCE_FIRST_WAIT)
	assert_true(warden._lance_winding)
	warden.last_lance = null
	warden.health.set_hp(Warden.PHASE_2_HP)
	# Mid-telegraph windup is cancelled with no bullets.
	assert_false(warden._lance_winding)
	# A near-full first wait must not start the Fan; the first windup is at 1.0 s.
	warden._physics_process(0.99)
	assert_false(warden._fan_winding)
	assert_null(warden.last_lance)
	warden._physics_process(0.02)
	assert_true(warden._fan_winding)
	# Phase 3 cancels that mid-telegraph Fan with no bullets; neither prior
	# attack fires again even after a full cadence of each.
	warden.last_fan.clear()
	warden.health.set_hp(Warden.PHASE_3_HP)
	assert_false(warden._fan_winding)
	warden._physics_process(Warden.LANCE_PERIOD)
	assert_null(warden.last_lance)
	warden._physics_process(Warden.FAN_PERIOD)
	assert_eq(warden.last_fan.size(), 0)
	assert_false(warden._fan_winding)
	# The 5.5 s already passed the 1.0 s first wait, so the ring may already
	# have fired; start a fresh fight to pin the first-wait itself.
	var ring := _ready_fight(ARENA + Vector2(0, 800))
	ring.health.set_hp(Warden.PHASE_3_HP)
	ring.last_ring.clear()
	ring._physics_process(0.99)
	assert_false(ring._ring_winding)
	assert_eq(ring.last_ring.size(), 0)
	ring._physics_process(0.02)
	assert_true(ring._ring_winding)
	assert_eq(ring.last_ring.size(), 0)


func test_phasing_clock_starts_closed_and_respawn_joins_it() -> void:
	var warden := _ready_fight()
	warden.health.set_hp(Warden.PHASE_2_HP)
	assert_almost_eq(warden._pulse_t, 0.0, 0.001)
	assert_false(warden.is_phasing_pulse_open())
	warden._physics_process(2.0)
	assert_almost_eq(warden._pulse_t, 2.0, 0.001)
	assert_false(warden.is_phasing_pulse_open())
	# Kill a far-side (non-phasing) husk and force a same-tick respawn; the
	# shared clock must not reset.
	warden._step_phasing_husks(0.0)
	var victim: WardenHusk = null
	for husk in warden.husks():
		if husk != null and husk.is_alive() and not husk.phasing:
			victim = husk
			break
	assert_not_null(victim)
	var slot := victim.slot()
	victim.health.set_hp(0.0)
	assert_almost_eq(warden._pulse_t, 2.0, 0.001)
	warden._respawn_left[slot] = 0.01
	warden._physics_process(0.01)
	assert_almost_eq(warden._pulse_t, 2.01, 0.001)
	assert_false(warden.is_phasing_pulse_open())
	assert_not_null(warden.husks()[slot])
	assert_true(warden.husks()[slot].is_alive())
	# First open is still 2.1 s from the original phase-2 tick.
	warden._physics_process(0.1)
	assert_true(warden.is_phasing_pulse_open())
	# The two player-side husks share that one clock.
	warden._step_phasing_husks(0.0)
	var open_sides := 0
	for husk in warden.husks():
		if husk != null and husk.is_alive() and husk.phasing:
			assert_true(husk.phase_open)
			open_sides += 1
	assert_eq(open_sides, 2)
	# Window closes at 2.5 s and stays closed until 4.6 s (next 2.1 of the period).
	warden._physics_process(0.4)
	assert_false(warden.is_phasing_pulse_open())


func test_phase_3_keeps_lock_and_closest_to_bearing_and_fades_the_rest() -> void:
	var warden := _ready_fight()
	warden.health.set_hp(Warden.PHASE_2_HP)
	assert_eq(warden._living_husk_count(), 4)
	# Lock due east (away from the player); closest-to-bearing among the rest is west.
	var lock := warden.lock_husk()
	assert_not_null(lock)
	lock.orbit_angle = 0.0
	var west_slot := -1
	var extras: Array[WardenHusk] = []
	for husk in warden.husks():
		if husk == null or not husk.is_alive() or husk == lock:
			continue
		if west_slot < 0:
			husk.orbit_angle = PI
			west_slot = husk.slot()
		else:
			husk.orbit_angle = PI * 0.5 if extras.is_empty() else -PI * 0.5
			extras.append(husk)
	assert_eq(west_slot >= 0, true)
	assert_eq(extras.size(), 2)
	var hp_before := warden.health.hp
	warden.health.set_hp(Warden.PHASE_3_HP)
	assert_eq(warden._living_husk_count(), 2)
	assert_eq(warden.husk_cap(), 2)
	assert_eq(warden.lock_husk(), lock)
	assert_true(lock.is_alive())
	assert_true(warden.husks()[west_slot].is_alive())
	assert_false(lock.phasing)
	assert_false(warden.husks()[west_slot].phasing)
	# No tithe from the surplus despawn.
	assert_eq(warden.health.hp, Warden.PHASE_3_HP)
	assert_eq(warden.health.hp, hp_before if hp_before == Warden.PHASE_3_HP else Warden.PHASE_3_HP)
	var fading: Array[WardenHusk] = []
	for husk in extras:
		assert_false(husk.is_alive())
		assert_true(husk.is_fading())
		assert_eq(husk._flash_left, 0.0)
		assert_false(husk.phasing)
		fading.append(husk)
	assert_eq(fading.size(), 2)
	for husk in fading:
		husk._physics_process(0.15)
		assert_true(husk.is_fading())
		assert_gt(husk.modulate.a, 0.0)
		assert_lt(husk.modulate.a, 1.0)
	for husk in fading:
		husk._physics_process(0.15)
		assert_true(husk.is_queued_for_deletion())
	# Respawn cap stays at 2 alive: no third body or pending slot after the cull.
	assert_eq(warden._living_husk_count() + warden._pending_husk_count(), 2)


func test_speed_band_edges_belong_to_the_upper_band() -> void:
	assert_eq(WardenHabituation.speed_band(0.0), 0)
	assert_eq(WardenHabituation.speed_band(399.0), 0)
	assert_eq(WardenHabituation.speed_band(400.0), 1, "400 is band 2")
	assert_eq(WardenHabituation.speed_band(699.0), 1)
	assert_eq(WardenHabituation.speed_band(700.0), 2, "700 is band 3")
	assert_eq(WardenHabituation.speed_band(999.0), 2)
	assert_eq(WardenHabituation.speed_band(1000.0), 3, "1000 is band 4")
	assert_eq(WardenHabituation.speed_band(2000.0), 3)


func test_habituation_counts_core_hurtboxes_only_with_impact_velocity_angle() -> void:
	var warden := _ready_fight()
	warden.boss_habituation = true
	warden.habituation.reset()
	warden.habituation.enabled = true
	# Body (×0.1) still counts; the signature uses the bullet's world velocity.
	var body_vel := Vector2(400, 0)
	warden.apply_debug_hit(warden.global_position, 1.0, 0, body_vel)
	assert_eq(warden.habituation.hit_count(), 1)
	assert_eq(warden.habituation.last_signature(), WardenHabituation.signature_id(body_vel))
	# Gap (×1) also counts, and a different impact angle is a different signature.
	var gap_vel := Vector2(0, 400)
	warden.apply_debug_hit(warden.gap_point(), 1.0, 0, gap_vel)
	assert_eq(warden.habituation.hit_count(), 2)
	assert_eq(warden.habituation.last_signature(), WardenHabituation.signature_id(gap_vel))
	assert_ne(WardenHabituation.signature_id(body_vel), WardenHabituation.signature_id(gap_vel))
	# A husk hit does not count.
	var husk: WardenHusk = warden.lock_husk()
	assert_not_null(husk)
	husk._on_hit(1.0, husk.global_position, Vector2(400, 0))
	assert_eq(warden.habituation.hit_count(), 2)


func test_kill_order_holds_across_phase_transitions_and_mid_transition() -> void:
	# Crossing both thresholds and dying in one write.
	var warden := _ready_fight()
	var order: Array[String] = []
	var killed := func(
		kind: StringName, _r: int, _t: int, _p: Vector2, _first: bool
	) -> void:
		order.append("killed:%s" % String(kind))
	var boss := func(kind: StringName, _r: int, _t: int, _p: Vector2) -> void:
		order.append("boss:%s" % String(kind))
	GameEvents.enemy_killed.connect(killed)
	GameEvents.boss_defeated.connect(boss)
	var phases: Array[int] = []
	warden.phase_changed.connect(func(phase: int) -> void: phases.append(phase))
	warden.health.set_hp(0.0)
	assert_eq(phases, [2, 3])
	assert_eq(order, ["killed:warden", "boss:warden"])

	# Mid-transition: the core dies from inside the phase-2 signal.
	var warden2 := _ready_fight(ARENA + Vector2(0, 500))
	order.clear()
	phases.clear()
	warden2.phase_changed.connect(
		func(phase: int) -> void:
			phases.append(phase)
			if phase == 2 and warden2.is_alive():
				warden2.health.set_hp(0.0)
	)
	warden2.health.set_hp(Warden.PHASE_2_HP)
	GameEvents.enemy_killed.disconnect(killed)
	GameEvents.boss_defeated.disconnect(boss)
	assert_true(phases.has(2))
	assert_true(phases.has(3))
	assert_eq(order, ["killed:warden", "boss:warden"])
	assert_false(warden2.is_alive())


func test_fan_and_ring_clear_on_player_death_and_warden_death() -> void:
	var warden := _ready_fight()
	var manager: BulletManager = warden._bullets
	warden.health.set_hp(Warden.PHASE_2_HP)
	warden.call("_fire_fan")
	assert_gt(warden.last_fan.size(), 0)
	assert_gt(manager.owner_count_all(Layers.ENEMY), 0)
	warden.on_player_died()
	assert_eq(manager.owner_count_all(Layers.ENEMY), 0)
	warden.debug_force_aggro()
	warden.health.set_hp(Warden.PHASE_3_HP)
	warden.call("_fire_ring")
	assert_gt(warden.last_ring.size(), 0)
	assert_gt(manager.owner_count_all(Layers.ENEMY), 0)
	warden.health.set_hp(0.0)
	assert_eq(manager.owner_count_all(Layers.ENEMY), 0)


func test_last_fan_and_ring_are_recorded_only_when_spawn_succeeds() -> void:
	var warden := _ready_fight()
	var manager: BulletManager = warden._bullets
	warden.health.set_hp(Warden.PHASE_2_HP)
	manager.set_bullet_limits(1, 0)
	# One slot: the first fan bullet may record, the rest must not, and a
	# follow-up fire with a full pool records nothing new.
	warden.call("_fire_fan")
	assert_lte(warden.last_fan.size(), 1)
	warden.last_fan.clear()
	warden.call("_fire_fan")
	assert_eq(warden.last_fan.size(), 0)
	manager.set_bullet_limits(64, 0)
	manager.clear_bullets()
	warden.health.set_hp(Warden.PHASE_3_HP)
	manager.set_bullet_limits(1, 0)
	warden.call("_fire_ring")
	assert_lte(warden.last_ring.size(), 1)
	warden.last_ring.clear()
	warden.call("_fire_ring")
	assert_eq(warden.last_ring.size(), 0)


func test_ring_centres_on_the_warden_not_the_arena() -> void:
	var at := ARENA + Vector2(0, 800)
	var warden := _ready_fight(at)
	warden.health.set_hp(Warden.PHASE_3_HP)
	warden._ring_gap = 0.0
	warden.call("_fire_ring")
	assert_gt(warden.last_ring.size(), 0)
	for req in warden.last_ring:
		var d := req.position.distance_to(warden.global_position)
		assert_almost_eq(d, Warden.RING_RADIUS, 0.05)
		assert_gt(req.position.distance_to(ARENA), Warden.RING_RADIUS * 0.5)


func test_swallowed_armor_hits_are_not_habituation_samples() -> void:
	var warden := _ready_fight()
	warden.boss_habituation = true
	warden.habituation.reset()
	warden.habituation.enabled = true
	warden.absorb_body_hits = true
	var before := warden.habituation.hit_count()
	var hp := warden.health.hp
	warden._hit_body(warden.global_position, 10.0, 0, Vector2(400, 0), 99)
	assert_eq(warden.habituation.hit_count(), before, "swallowed hits are not samples")
	assert_eq(warden.health.hp, hp, "swallowed hits deal no damage")
	# A gap tick still counts and still deals ×1.
	warden.apply_debug_hit(warden.gap_point(), 1.0, 0, Vector2(0, 400), 100)
	assert_eq(warden.habituation.hit_count(), before + 1)
	assert_almost_eq(warden.health.hp, hp - 1.0, 0.001)


func _ready_fight(at: Vector2 = ARENA) -> Warden:
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = at + Vector2(-400, 0)
	add_child_autofree(player)
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 128
	manager.world_bounds = Rect2(0, -2000, 20000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var warden := Warden.new()
	warden.position = at
	add_child_autofree(warden)
	warden.bind(player, manager)
	warden.debug_force_aggro()
	return warden


func _a_phasing_husk(warden: Warden) -> WardenHusk:
	# Refresh the side assignment without advancing the pulse clock.
	warden._step_phasing_husks(0.0)
	for husk in warden.husks():
		if husk != null and husk.is_alive() and husk.phasing:
			return husk
	return null
