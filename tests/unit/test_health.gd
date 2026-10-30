extends GutTest
## Placeholder Health component.

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
