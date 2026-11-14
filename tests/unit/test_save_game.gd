extends GutTest
## SaveGame keeps both the Sense keys (#92) and the slice/pack keys (#91)
## through a write and a load, including the type guards in _read().

const _SAVE := "user://gut_save_game_both_sets.cfg"


func before_each() -> void:
	_discard()


func after_each() -> void:
	_discard()


func test_save_round_trips_senses_and_slice_pack_keys() -> void:
	var save := SaveGame.new()
	save.path = _SAVE
	save.world_seed = 4242
	save.sense_nearest = true
	save.sense_enemies_in = 1
	save.slice_lessons = 7
	save.slice_gates = 3
	save.slice_packs = 1
	save.slice_rare_dead = true
	save.field_drifters = 1_710_000_000.5
	save.field_swarmers = 12.0
	save.field_shield = 99.25
	save.field_sniper = 3.0
	save.warden_dead = true
	save.starter_consumed = true
	save.save()

	var loaded := SaveGame.load_from(_SAVE)
	assert_true(loaded.existed)
	assert_eq(loaded.world_seed, 4242)
	assert_true(loaded.sense_nearest)
	assert_eq(loaded.sense_enemies_in, 1)
	assert_eq(loaded.slice_lessons, 7)
	assert_eq(loaded.slice_gates, 3)
	assert_eq(loaded.slice_packs, 1)
	assert_true(loaded.slice_rare_dead)
	assert_eq(loaded.field_drifters, 1_710_000_000.5)
	assert_eq(loaded.field_swarmers, 12.0)
	assert_eq(loaded.field_shield, 99.25)
	assert_eq(loaded.field_sniper, 3.0)
	assert_true(loaded.warden_dead)
	assert_true(loaded.starter_consumed)
	assert_false(loaded.field_pack_is_present(SaveGame.FIELD_DRIFTERS, 1_710_000_010.0))
	assert_true(loaded.field_pack_is_present(SaveGame.FIELD_DRIFTERS, 1_710_000_000.5 + SaveGame.FIELD_PACK_RETURN))


func test_type_guards_on_senses_and_slice_pack_keys() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", 11)
	# Coerce and clamp: a truthy int, a negative level, ints for the bitmasks,
	# an int for a pack timestamp, and a non-array for an existing Array field.
	cfg.set_value("senses", "sense_nearest", 1)
	cfg.set_value("senses", "sense_enemies_in", -4)
	cfg.set_value("world", "slice_lessons", 5.9)
	cfg.set_value("world", "slice_gates", 2)
	cfg.set_value("world", "slice_packs", 1)
	cfg.set_value("world", "slice_rare_dead", 1)
	cfg.set_value("world", "field_drifters", 42)
	cfg.set_value("world", "field_swarmers", 0)
	cfg.set_value("world", "field_shield", 0)
	cfg.set_value("world", "field_sniper", 0)
	cfg.set_value("world", "elite_kills", "not-an-array")
	cfg.set_value("world", "regular_absent", 0)
	cfg.save(_SAVE)

	var loaded := SaveGame.load_from(_SAVE)
	assert_false(loaded.sense_nearest, "a non-bool stays false (_read_bool)")
	assert_eq(loaded.sense_enemies_in, 0, "a negative level clamps to 0")
	assert_eq(loaded.slice_lessons, 5, "int() truncates a float")
	assert_eq(loaded.slice_gates, 2)
	assert_eq(loaded.slice_packs, 1)
	assert_false(loaded.slice_rare_dead, "a non-bool stays false (_read_bool)")
	assert_eq(loaded.field_drifters, 42.0, "float() accepts an int")
	assert_eq(loaded.field_swarmers, 0.0)
	assert_eq(loaded.elite_kills, [])
	assert_eq(loaded.regular_absent, [])

	# A slot with only world_seed keeps both new key sets at their defaults.
	_discard()
	cfg = ConfigFile.new()
	cfg.set_value("world", "world_seed", 11)
	cfg.save(_SAVE)
	loaded = SaveGame.load_from(_SAVE)
	assert_false(loaded.sense_nearest)
	assert_eq(loaded.sense_enemies_in, 0)
	assert_eq(loaded.slice_lessons, 0)
	assert_eq(loaded.slice_gates, 0)
	assert_eq(loaded.slice_packs, 0)
	assert_false(loaded.slice_rare_dead)
	assert_eq(loaded.field_drifters, 0.0)
	assert_eq(loaded.field_swarmers, 0.0)
	assert_eq(loaded.field_shield, 0.0)
	assert_eq(loaded.field_sniper, 0.0)
	assert_false(loaded.warden_dead)
	assert_false(loaded.starter_consumed)
	assert_true(loaded.field_pack_is_present(SaveGame.FIELD_DRIFTERS))


func test_warden_dead_and_starter_consumed_reject_non_bools() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", 11)
	cfg.set_value("world", "warden_dead", 1)
	cfg.set_value("world", "starter_consumed", "yes")
	cfg.save(_SAVE)
	var loaded := SaveGame.load_from(_SAVE)
	assert_false(loaded.warden_dead, "a truthy int must not set warden_dead")
	assert_false(loaded.starter_consumed, "a string must not set starter_consumed")

	_discard()
	cfg = ConfigFile.new()
	cfg.set_value("world", "world_seed", 11)
	cfg.set_value("world", "warden_dead", true)
	cfg.set_value("world", "starter_consumed", true)
	cfg.save(_SAVE)
	loaded = SaveGame.load_from(_SAVE)
	assert_true(loaded.warden_dead)
	assert_true(loaded.starter_consumed)


func _discard() -> void:
	if FileAccess.file_exists(_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_SAVE))
