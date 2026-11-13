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
		var ang := (req.position - ARENA).angle()
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


func _ready_fight(at: Vector2 = ARENA) -> Warden:
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = at + Vector2(-400, 0)
	add_child_autofree(player)
	var warden := Warden.new()
	warden.position = at
	add_child_autofree(warden)
	warden.bind(player, null)
	warden.debug_force_aggro()
	return warden


func _a_phasing_husk(warden: Warden) -> WardenHusk:
	# Refresh the side assignment without advancing the pulse clock.
	warden._step_phasing_husks(0.0)
	for husk in warden.husks():
		if husk != null and husk.is_alive() and husk.phasing:
			return husk
	return null
