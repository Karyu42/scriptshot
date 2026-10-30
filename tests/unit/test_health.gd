extends GutTest
## Health component: damage, i-frames, regeneration, validated setters (the
## combat rules decided 2026-10-30).

const DT := 1.0 / 60.0

var h: Health


func before_each() -> void:
	h = Health.new()
	h.max_hp = 5.0
	h.invulnerability_time = 0.5
	add_child_autofree(h)
	watch_signals(h)


func _tick(seconds: float) -> void:
	for i in ceili(seconds / DT):
		h._physics_process(DT)


func test_starts_at_max_hp() -> void:
	assert_eq(h.hp, 5.0)
	assert_false(h.is_dead())
	assert_false(h.is_invulnerable())


func test_damage_reduces_hp_and_emits() -> void:
	assert_true(h.damage(2.0))
	assert_eq(h.hp, 3.0)
	assert_signal_emitted_with_parameters(h, "damaged", [2.0, 3.0])


func test_non_positive_damage_is_ignored() -> void:
	assert_false(h.damage(0.0))
	assert_false(h.damage(-3.0))
	assert_eq(h.hp, 5.0)
	assert_signal_not_emitted(h, "damaged")


func test_hit_starts_iframes_that_block_further_damage() -> void:
	h.damage(1.0)
	assert_true(h.is_invulnerable())
	assert_signal_emitted_with_parameters(h, "invulnerability_changed", [true])
	assert_false(h.damage(1.0))
	assert_eq(h.hp, 4.0)


func test_iframes_expire() -> void:
	h.damage(1.0)
	_tick(0.4)
	assert_true(h.is_invulnerable())
	_tick(0.2)
	assert_false(h.is_invulnerable())
	assert_signal_emitted_with_parameters(h, "invulnerability_changed", [false])
	assert_true(h.damage(1.0))
	assert_eq(h.hp, 3.0)


func test_lethal_damage_emits_died_once_and_clamps_at_zero() -> void:
	h.damage(1.0)
	_tick(0.6)
	assert_true(h.damage(100.0))
	assert_eq(h.hp, 0.0)
	assert_true(h.is_dead())
	assert_signal_emit_count(h, "died", 1)
	assert_false(h.damage(1.0), "dead stays dead")
	assert_signal_emit_count(h, "died", 1)


func test_lethal_hit_does_not_start_iframes() -> void:
	h.damage(5.0)
	assert_false(h.is_invulnerable())


func test_heal_is_clamped_and_ignored_when_dead() -> void:
	h.damage(2.0)
	h.heal(10.0)
	assert_eq(h.hp, 5.0)
	_tick(0.6)
	h.damage(5.0)
	h.heal(3.0)
	assert_eq(h.hp, 0.0)


func test_reset_restores_hp_and_clears_iframes() -> void:
	h.damage(2.0)
	h.reset()
	assert_eq(h.hp, 5.0)
	assert_false(h.is_invulnerable())
	assert_signal_emitted_with_parameters(h, "invulnerability_changed", [false])


func test_zero_invulnerability_time_allows_back_to_back_hits() -> void:
	h.invulnerability_time = 0.0
	assert_true(h.damage(1.0))
	assert_true(h.damage(1.0))
	assert_eq(h.hp, 3.0)


func test_layers_hostile_to_is_the_other_side_only() -> void:
	assert_eq(Layers.hostile_to(Layers.PLAYER), Layers.ENEMY)
	assert_eq(Layers.hostile_to(Layers.ENEMY), Layers.PLAYER)
	assert_eq(Layers.hostile_to(Layers.WORLD), 0)


# --- decided defaults ----------------------------------------------------------

func test_decided_defaults() -> void:
	var fresh := Health.new()
	autofree(fresh)
	assert_eq(fresh.max_hp, 5.0)
	assert_eq(fresh.invulnerability_time, 0.75)
	assert_eq(fresh.regen_delay, 5.0)
	assert_eq(fresh.regen_interval, 3.0)
	assert_eq(fresh.regen_amount, 1.0)
	assert_true(fresh.regen_enabled)


# --- regeneration ----------------------------------------------------------------

func _fresh_decided() -> Health:
	var fresh := Health.new()
	add_child_autofree(fresh)
	return fresh


func test_no_regen_before_the_delay_has_passed() -> void:
	var r := _fresh_decided()
	r.damage(2.0)
	r.tick(4.9)
	assert_eq(r.hp, 3.0)
	assert_false(r.is_regenerating())


func test_first_hp_comes_five_seconds_after_the_hit_then_one_every_three() -> void:
	var r := _fresh_decided()
	r.damage(3.0)
	r.tick(4.9)
	assert_eq(r.hp, 2.0, "nothing before 5 s")
	r.tick(0.2)
	assert_true(r.is_regenerating())
	assert_eq(r.hp, 3.0, "first hp at 5 s")
	r.tick(2.8)
	assert_eq(r.hp, 3.0, "7.9 s: next one is due at 8 s")
	r.tick(0.2)
	assert_eq(r.hp, 4.0, "second hp at 8 s")
	r.tick(3.0)
	assert_eq(r.hp, 5.0, "third at 11 s")
	r.tick(30.0)
	assert_eq(r.hp, 5.0, "never above max")
	assert_false(r.is_regenerating())


func test_regen_timeline_at_60hz() -> void:
	var r := _fresh_decided()
	r.damage(3.0)
	var gained_at: Array[float] = []
	var last := r.hp
	for i in 60 * 12:
		r.tick(DT)
		if r.hp > last:
			gained_at.append(snappedf(r.time_since_damage, 0.05))
			last = r.hp
	assert_eq(gained_at, [5.0, 8.0, 11.0] as Array[float])


func test_regen_is_independent_of_tick_size() -> void:
	var coarse := _fresh_decided()
	var fine := _fresh_decided()
	coarse.damage(3.0)
	fine.damage(3.0)
	coarse.tick(100.0)
	for i in 6000:
		fine.tick(DT)
	assert_eq(coarse.hp, 5.0)
	assert_eq(fine.hp, 5.0)


func test_taking_damage_restarts_the_regen_delay() -> void:
	var r := _fresh_decided()
	r.damage(2.0)
	r.tick(5.5)
	assert_eq(r.hp, 4.0, "regenerating")
	r.tick(0.75)
	r.damage(1.0)
	assert_eq(r.hp, 3.0)
	r.tick(4.9)
	assert_eq(r.hp, 3.0, "delay restarted by the hit")
	r.tick(0.2)
	assert_eq(r.hp, 4.0, "first hp 5 s after the new hit")
	r.tick(3.0)
	assert_eq(r.hp, 5.0)


func test_blocked_damage_does_not_restart_regen() -> void:
	var r := _fresh_decided()
	r.damage(1.0)
	r.tick(0.5)
	assert_false(r.damage(1.0), "i-frames block it")
	r.tick(4.6)
	assert_true(r.time_since_damage >= 5.0, "timer kept running")


func test_regen_can_be_disabled_and_tuned() -> void:
	var r := _fresh_decided()
	r.regen_enabled = false
	r.damage(2.0)
	r.tick(60.0)
	assert_eq(r.hp, 3.0)
	r.regen_enabled = true
	r.regen_delay = 1.0
	r.regen_interval = 0.5
	r.regen_amount = 2.0
	r.tick(1.0)
	assert_eq(r.hp, 5.0, "+2 at 1 s (60 s of disabled time already counted), clamped to max")


func test_dead_does_not_regenerate_and_healed_signal_reports_the_gain() -> void:
	var r := _fresh_decided()
	watch_signals(r)
	r.damage(2.0)
	r.tick(5.5)
	assert_signal_emitted_with_parameters(r, "healed", [1.0, 4.0])
	r.tick(0.01)
	r.damage(100.0)
	r.tick(100.0)
	assert_eq(r.hp, 0.0)


func test_regen_gives_back_the_hp_after_a_death_free_fight() -> void:
	var r := _fresh_decided()
	r.damage(4.0)
	r.tick(5.0 + 3.0 * 3.0 + 0.01)
	assert_eq(r.hp, 5.0, "1 + 4 steps: at 5, 8, 11 and 14 s")


# --- script setters ----------------------------------------------------------------

func test_set_hp_clamps_to_zero_and_max() -> void:
	assert_eq(h.set_hp(3.5), 3.5)
	assert_eq(h.set_hp(99.0), 5.0)
	assert_eq(h.set_hp(INF), 5.0)
	assert_eq(h.set_hp(-INF), 0.0)
	assert_true(h.is_dead())


func test_set_hp_ignores_nan() -> void:
	h.set_hp(2.0)
	assert_eq(h.set_hp(NAN), 2.0)
	assert_eq(h.hp, 2.0)


func test_set_hp_zero_kills_once_and_dead_cannot_be_revived_by_it() -> void:
	h.set_hp(0.0)
	assert_signal_emit_count(h, "died", 1)
	h.set_hp(5.0)
	assert_eq(h.hp, 0.0)
	assert_signal_emit_count(h, "died", 1)


func test_set_hp_up_emits_healed_and_never_starts_iframes_or_resets_the_regen_delay() -> void:
	h.damage(3.0)
	_tick(0.6)
	h.set_hp(4.0)
	assert_signal_emitted_with_parameters(h, "healed", [2.0, 4.0])
	assert_false(h.is_invulnerable())
	h.set_hp(1.0)
	assert_false(h.is_invulnerable(), "writing hp is not taking a hit")
	assert_true(h.time_since_damage > 0.5)


func test_set_max_hp_clamps_and_pulls_hp_down() -> void:
	assert_eq(h.set_max_hp(3.0), 3.0)
	assert_eq(h.hp, 3.0)
	assert_eq(h.set_max_hp(-4.0), 1.0, "at least 1")
	assert_eq(h.set_max_hp(1.0e9), Health.MAX_HP_LIMIT)
	assert_eq(h.hp, 1.0, "raising max does not heal")
	assert_eq(h.set_max_hp(NAN), Health.MAX_HP_LIMIT, "NaN ignored")
	assert_eq(h.set_max_hp(INF), Health.MAX_HP_LIMIT)


func test_set_invulnerable_seconds_sets_the_script_layer() -> void:
	h.set_invulnerable(1.0)
	assert_true(h.is_invulnerable())
	assert_true(h.is_script_invulnerable())
	assert_false(h.is_engine_invulnerable())
	assert_signal_emit_count(h, "invulnerability_changed", 1)
	assert_signal_emit_count(h, "script_invulnerability_changed", 1)
	assert_signal_not_emitted(h, "engine_invulnerability_changed")
	h.set_invulnerable(0.2)
	assert_eq(h.script_invulnerable_left, 0.2, "the script's latest value replaces its earlier one")
	h.set_invulnerable(2)
	assert_eq(h.script_invulnerable_left, 2.0, "ints are seconds too")
	assert_signal_emit_count(h, "invulnerability_changed", 1, "still one start edge")
	_tick(2.1)
	assert_false(h.is_invulnerable())
	assert_signal_emit_count(h, "invulnerability_changed", 2)


func test_set_invulnerable_bool_and_clear() -> void:
	h.set_invulnerable(true)
	_tick(100.0)
	assert_true(h.is_invulnerable(), "true lasts until cleared")
	assert_false(h.damage(1.0))
	h.set_invulnerable(false)
	assert_false(h.is_invulnerable())
	h.set_invulnerable(5.0)
	h.set_invulnerable(0.0)
	assert_false(h.is_invulnerable(), "0 clears")
	h.set_invulnerable(3.0)
	h.set_invulnerable(-1.0)
	assert_false(h.is_invulnerable(), "negative clears")


func test_set_invulnerable_ignores_nan_and_wrong_types() -> void:
	h.set_invulnerable(NAN)
	h.set_invulnerable("long")
	h.set_invulnerable(null)
	assert_false(h.is_invulnerable())


func test_invulnerability_blocks_damage_from_script_source() -> void:
	h.set_invulnerable(1.0)
	assert_false(h.damage(2.0))
	assert_eq(h.hp, 5.0)


func test_damage_nan_is_ignored() -> void:
	assert_false(h.damage(NAN))
	assert_eq(h.hp, 5.0)
	h.heal(NAN)
	assert_eq(h.hp, 5.0)


func test_reset_clears_regen_timers_and_keeps_max_hp() -> void:
	h.set_max_hp(8.0)
	h.set_hp(8.0)
	h.damage(3.0)
	h.reset()
	assert_eq(h.hp, 8.0)
	assert_eq(h.time_since_damage, 0.0)


# --- the two invulnerability layers (QA B4) ---------------------------------

func test_script_false_does_not_clear_hit_iframes() -> void:
	h.damage(1.0)
	assert_true(h.is_engine_invulnerable())
	h.set_invulnerable(false)
	assert_true(h.is_engine_invulnerable(), "hit i-frames survive a script clear")
	assert_true(h.is_invulnerable())
	assert_false(h.damage(1.0))
	assert_eq(h.hp, 4.0)


func test_script_false_does_not_clear_dash_iframes() -> void:
	h.add_engine_invulnerability(0.2)
	h.set_invulnerable(true)
	h.set_invulnerable(false)
	h.set_invulnerable(0.0)
	assert_true(h.is_engine_invulnerable())
	assert_eq(h.engine_invulnerable_left, 0.2)
	assert_eq(h.try_damage(1.0), Health.DamageResult.BLOCKED_ENGINE)


func test_script_invulnerability_does_not_change_engine_iframes() -> void:
	h.add_engine_invulnerability(0.3)
	h.set_invulnerable(10.0)
	assert_eq(h.engine_invulnerable_left, 0.3, "script layer never extends the engine one")
	_tick(0.4)
	assert_false(h.is_engine_invulnerable())
	assert_true(h.is_script_invulnerable())


func test_permanent_script_invulnerability_holds_over_a_long_time() -> void:
	h.set_invulnerable(true)
	_tick(600.0)
	assert_true(h.is_script_invulnerable(), "no cap: ten minutes later it still holds")
	assert_eq(h.script_invulnerable_left, INF)
	assert_false(h.damage(5.0))
	assert_eq(h.hp, 5.0)


func test_blocked_results_tell_the_layers_apart() -> void:
	h.set_invulnerable(true)
	assert_eq(h.try_damage(1.0), Health.DamageResult.BLOCKED_SCRIPT)
	assert_signal_emitted_with_parameters(h, "damage_blocked", [1.0, Health.DamageResult.BLOCKED_SCRIPT])
	h.add_engine_invulnerability(0.5)
	assert_eq(h.try_damage(1.0), Health.DamageResult.BLOCKED_ENGINE, "engine wins when both are on")
	assert_eq(h.try_damage(0.0), Health.DamageResult.IGNORED)
	assert_eq(h.hp, 5.0)


func test_a_piercing_attack_hits_through_the_script_layer_only() -> void:
	h.set_invulnerable(true)
	assert_true(h.damage(1.0, Health.SOURCE_PIERCES_SCRIPT_INVULN), "pierces the script layer")
	assert_eq(h.hp, 4.0)
	assert_true(h.is_engine_invulnerable(), "the hit gave normal i-frames")
	assert_eq(
		h.try_damage(1.0, Health.SOURCE_PIERCES_SCRIPT_INVULN),
		Health.DamageResult.BLOCKED_ENGINE,
		"engine i-frames still block a piercing attack"
	)
	assert_eq(h.hp, 4.0)
	assert_true(h.is_script_invulnerable(), "the script layer is untouched by a hit")


func test_a_piercing_attack_cannot_hit_during_a_dash() -> void:
	h.add_engine_invulnerability(0.2)
	assert_false(h.damage(1.0, Health.SOURCE_PIERCES_SCRIPT_INVULN))
	_tick(0.25)
	assert_true(h.damage(1.0, Health.SOURCE_PIERCES_SCRIPT_INVULN))


func test_a_normal_attack_is_blocked_by_the_script_layer() -> void:
	h.set_invulnerable(1.0)
	assert_false(h.damage(1.0, 0))
	assert_false(h.damage(1.0, 2), "unknown flag bits don't pierce")


func test_reset_clears_engine_layer_but_script_layer_persists() -> void:
	h.damage(1.0)
	h.set_invulnerable(true)
	h.reset()
	assert_false(h.is_engine_invulnerable())
	assert_true(h.is_script_invulnerable(), "script invulnerability persists across respawn")
	assert_eq(h.hp, 5.0)


func test_layer_signals_fire_per_layer_and_for_any() -> void:
	h.set_invulnerable(true)
	assert_signal_emit_count(h, "script_invulnerability_changed", 1)
	assert_signal_emit_count(h, "invulnerability_changed", 1)
	h.add_engine_invulnerability(0.2)
	assert_signal_emit_count(h, "engine_invulnerability_changed", 1)
	assert_signal_emit_count(h, "invulnerability_changed", 1, "any-layer edge: already on")
	h.set_invulnerable(false)
	assert_signal_emit_count(h, "invulnerability_changed", 1, "engine still on")
	_tick(0.3)
	assert_signal_emit_count(h, "invulnerability_changed", 2)
	assert_signal_emitted_with_parameters(h, "engine_invulnerability_changed", [false])


# --- nits -------------------------------------------------------------------

func test_set_hp_clamps_to_zero_and_max_not_beyond() -> void:
	assert_eq(h.set_hp(99.0), 5.0, "above max clamps to max_hp, no overheal")
	assert_eq(h.hp, 5.0)
	assert_eq(h.set_hp(-3.0), 0.0, "below zero clamps to 0 (and kills)")
	assert_true(h.is_dead())
	assert_signal_emit_count(h, "died", 1)


func test_set_hp_clamp_is_enforced_for_infinities() -> void:
	assert_eq(h.set_hp(INF), 5.0)
	assert_eq(h.set_hp(-INF), 0.0)
	assert_true(h.is_dead())


func test_float_residue_does_not_cost_an_extra_tick() -> void:
	h.invulnerability_time = 0.75
	h.damage(1.0)
	for i in 45:
		h.tick(1.0 / 60.0)
	assert_false(h.is_invulnerable(), "0.75 s = exactly 45 ticks of 1/60")
	h.add_engine_invulnerability(0.2)
	for i in 12:
		h.tick(1.0 / 60.0)
	assert_false(h.is_engine_invulnerable(), "0.2 s = exactly 12 ticks")


func test_max_hp_is_a_whole_number() -> void:
	assert_eq(h.set_max_hp(3.4), 3.0)
	assert_eq(h.set_max_hp(3.6), 4.0)
	assert_eq(h.set_max_hp(0.2), 1.0)


func test_nan_warnings_are_rate_limited() -> void:
	ScriptWarnings.reset()
	for i in 20:
		h.set_hp(NAN)
	assert_eq(ScriptWarnings.count("Health.set_hp"), 20, "all counted")
	assert_eq(ScriptWarnings.printed_count("Health.set_hp"), ScriptWarnings.LIMIT, "but only LIMIT are printed")
