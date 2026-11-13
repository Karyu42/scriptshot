extends GutTest
## SenseBook (vertical-slice §6.1): first-death counting, the Warden grant,
## grants deferred to the frame boundary, and the save fields.

const _SAVE := "user://gut_sense_book.cfg"

var _granted: Array = []


func before_each() -> void:
	SenseBook.reset()
	SenseBook.listen()
	_granted.clear()
	SenseBook.events.granted.connect(_on_granted)
	_discard()


func after_each() -> void:
	if SenseBook.events.granted.is_connected(_on_granted):
		SenseBook.events.granted.disconnect(_on_granted)
	SenseBook.unlisten()
	SenseBook.reset()
	_discard()


func _on_granted(id: StringName, level: int) -> void:
	_granted.append([String(id), level])


func _discard() -> void:
	if FileAccess.file_exists(_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_SAVE))


func _kill(first_death: bool, kind: StringName = EnemyKinds.DUMMY) -> void:
	GameEvents.enemy_killed.emit(kind, EnemyKinds.RARITY_NONE, 0, Vector2.ZERO, first_death)


func test_three_first_deaths_grant_nearest_enemy_level_one() -> void:
	_kill(true)
	_kill(true)
	SenseBook.flush_pending()
	assert_false(SenseBook.unlocked(&"nearest_enemy"), "two kills are not enough")
	_kill(true, EnemyKinds.DRIFTER)
	SenseBook.flush_pending()
	assert_eq(SenseBook.level(&"nearest_enemy"), 1)
	assert_eq(_granted, [["nearest_enemy", 1]])
	assert_false(SenseBook.unlocked(&"enemies_in"))


func test_a_respawned_dummy_does_not_count() -> void:
	_kill(true)
	_kill(false)
	_kill(false)
	_kill(false)
	SenseBook.flush_pending()
	assert_eq(SenseBook.kill_count(), 1)
	assert_false(SenseBook.unlocked(&"nearest_enemy"))


func test_more_kills_do_not_grant_again() -> void:
	for i in 6:
		_kill(true)
	SenseBook.flush_pending()
	for i in 3:
		_kill(true)
	SenseBook.flush_pending()
	assert_eq(_granted.size(), 1)
	assert_eq(SenseBook.level(&"nearest_enemy"), 1, "never above Level I in the slice")


func test_the_grant_waits_for_the_frame_boundary() -> void:
	for i in 3:
		_kill(true)
	assert_false(SenseBook.unlocked(&"nearest_enemy"), "not applied mid-step")
	assert_eq(SenseBook.pending_count(), 1)
	assert_eq(_granted.size(), 0)
	await wait_process_frames(2)
	assert_true(SenseBook.unlocked(&"nearest_enemy"), "applied at the next frame")
	assert_eq(SenseBook.pending_count(), 0)
	assert_eq(_granted, [["nearest_enemy", 1]])


func test_the_warden_grants_enemies_in_level_one() -> void:
	# The boss emits enemy_killed first, then boss_defeated (GameEvents doc).
	_kill(true, EnemyKinds.WARDEN)
	GameEvents.boss_defeated.emit(EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, Vector2(9664, 0))
	assert_false(SenseBook.unlocked(&"enemies_in"), "deferred like every grant")
	SenseBook.flush_pending()
	assert_eq(SenseBook.level(&"enemies_in"), 1)
	assert_false(SenseBook.unlocked(&"nearest_enemy"), "one kill does not grant nearest_enemy")
	assert_eq(SenseBook.kill_count(), 1, "the Warden's own kill counted once")


func test_a_rare_warden_still_grants_level_one_only() -> void:
	GameEvents.boss_defeated.emit(EnemyKinds.WARDEN, EnemyKinds.RARITY_RARE, 1, Vector2.ZERO)
	SenseBook.flush_pending()
	assert_eq(SenseBook.level(&"enemies_in"), 1)


func test_another_boss_grants_nothing() -> void:
	GameEvents.boss_defeated.emit(&"sower", EnemyKinds.RARITY_COMMON, 0, Vector2.ZERO)
	SenseBook.flush_pending()
	assert_eq(SenseBook.unlocked_names(), PackedStringArray())


func test_both_in_one_frame_apply_nearest_first() -> void:
	_kill(true)
	_kill(true)
	_kill(true, EnemyKinds.WARDEN)
	GameEvents.boss_defeated.emit(EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, Vector2.ZERO)
	SenseBook.flush_pending()
	assert_eq(_granted, [["nearest_enemy", 1], ["enemies_in", 1]])


func test_not_listening_counts_nothing() -> void:
	SenseBook.unlisten()
	for i in 3:
		_kill(true)
	SenseBook.flush_pending()
	assert_eq(SenseBook.kill_count(), 0)
	SenseBook.listen()
	SenseBook.listen()
	_kill(true)
	assert_eq(SenseBook.kill_count(), 1, "listen() is idempotent")


func test_revision_moves_on_every_level_change() -> void:
	var r0 := SenseBook.revision()
	SenseBook.grant(&"nearest_enemy", 1)
	var r1 := SenseBook.revision()
	assert_gt(r1, r0)
	SenseBook.grant(&"nearest_enemy", 1)
	assert_eq(SenseBook.revision(), r1, "no change, same revision")
	SenseBook.reset()
	assert_gt(SenseBook.revision(), r1)


func test_grants_are_written_to_the_bound_save() -> void:
	var save := SaveGame.load_from(_SAVE)
	SenseBook.bind_save(save)
	for i in 3:
		_kill(true)
	SenseBook.flush_pending()
	var reread := SaveGame.load_from(_SAVE)
	assert_true(reread.sense_nearest)
	assert_eq(reread.sense_enemies_in, 0)
	GameEvents.boss_defeated.emit(EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, 0, Vector2.ZERO)
	SenseBook.flush_pending()
	reread = SaveGame.load_from(_SAVE)
	assert_eq(reread.sense_enemies_in, 1)
	assert_eq(reread.world_seed, save.world_seed, "the rest of the slot is kept")


func test_a_reload_restores_quietly_and_does_not_grant_again() -> void:
	var save := SaveGame.load_from(_SAVE)
	save.sense_nearest = true
	save.sense_enemies_in = 1
	save.save()
	SenseBook.reset()
	SenseBook.bind_save(SaveGame.load_from(_SAVE))
	assert_true(SenseBook.unlocked(&"nearest_enemy"))
	assert_eq(SenseBook.level(&"enemies_in"), 1)
	assert_eq(_granted.size(), 0, "a restore is not an unlock: no toast, no Codex page")
	for i in 3:
		_kill(true)
	SenseBook.flush_pending()
	assert_eq(_granted.size(), 0, "already held")


func test_a_save_without_the_fields_reads_as_nothing_earned() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("world", "world_seed", 7)
	cfg.save(_SAVE)
	var save := SaveGame.load_from(_SAVE)
	assert_false(save.sense_nearest)
	assert_eq(save.sense_enemies_in, 0)
	SenseBook.bind_save(save)
	assert_eq(SenseBook.unlocked_names(), PackedStringArray())
