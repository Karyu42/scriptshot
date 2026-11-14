extends GutTest
## Senses in the game scene: the three origin dummies' first deaths grant
## nearest_enemy at the next frame, a respawned dummy does not count again,
## the slot keeps the Sense, and a reload restores it without the unlock UX.

const _SAVE := "user://gut_senses_main.cfg"


func before_each() -> void:
	_discard()
	SenseBook.reset()


func after_each() -> void:
	_discard()
	SenseBook.reset()


func _discard() -> void:
	if FileAccess.file_exists(_SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_SAVE))


func _main() -> Main:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = _SAVE
	(main.get_node("BulletManager") as BulletManager).backend_preference = "gdscript"
	add_child_autofree(main)
	var turrets := main.get_node_or_null("Turrets")
	if turrets != null:
		for turret: Turret in turrets.get_children():
			turret.emitter = null
	return main


func _kill(dummy: TrainingDummy) -> void:
	(dummy.get_node("Hurtbox") as Hurtbox).hit.emit(dummy.max_health + 1.0, dummy.global_position, Vector2.ZERO)


func test_the_origin_dummies_grant_nearest_enemy_and_the_slot_keeps_it() -> void:
	var main := _main()
	await wait_physics_frames(2)
	assert_true(SenseBook.is_listening())
	var d0 := main.get_node("Dummies/Target0") as TrainingDummy
	var d1 := main.get_node("Dummies/Target1") as TrainingDummy
	var d2 := main.get_node("Dummies/Target2") as TrainingDummy
	_kill(d0)
	_kill(d1)
	assert_eq(SenseBook.kill_count(), 2)
	# Respawn d0, kill it again: first_death is false, so it does not count.
	await wait_seconds(d0.respawn_delay + 0.2)
	assert_true(d0.visible, "respawned")
	_kill(d0)
	assert_eq(SenseBook.kill_count(), 2, "a respawned dummy does not count")
	assert_false(SenseBook.unlocked(&"nearest_enemy"))
	_kill(d2)
	assert_eq(SenseBook.kill_count(), 3)
	assert_false(SenseBook.unlocked(&"nearest_enemy"), "deferred to the frame boundary")
	await get_tree().process_frame
	assert_true(SenseBook.unlocked(&"nearest_enemy"))
	assert_eq(main.editor.toast_text(), "sense.nearest_enemy")
	assert_false(main.editor.starter_locked("homing"))
	assert_true(SaveGame.load_from(_SAVE).sense_nearest, "written to the slot")
	main.free()
	assert_false(SenseBook.is_listening(), "a freed scene stops counting")

	var again := _main()
	await wait_physics_frames(1)
	assert_true(SenseBook.unlocked(&"nearest_enemy"), "the reload keeps it")
	assert_eq(again.editor.toast_text(), "", "no second toast")
	assert_eq(again.editor.codex_unread().size(), 0, "no second Codex page")
	assert_false(again.editor.starter_locked("homing"))
