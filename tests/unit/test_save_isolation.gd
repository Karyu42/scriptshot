extends GutTest
## Open-world scenes must not rewrite the player's user://save.cfg.


const _REAL := "user://save.cfg"
const _THROWAWAY := "user://gut_save_isolation.cfg"


func after_all() -> void:
	_remove(_THROWAWAY)


func test_open_world_flows_leave_the_real_save_byte_identical() -> void:
	var had_real := FileAccess.file_exists(_REAL)
	var prior := PackedByteArray()
	if had_real:
		prior = FileAccess.get_file_as_bytes(_REAL)
	var sentinel := SaveGame.new()
	sentinel.path = _REAL
	sentinel.world_seed = 8675309
	sentinel.herald_done = true
	sentinel.shards = 4
	sentinel.elite_kills = []
	sentinel.regular_absent = [{"cx": 4, "cy": -2, "index": 1, "since_unix": 1710000000.5}]
	sentinel.save()
	var before := FileAccess.get_file_as_bytes(_REAL)
	assert_gt(before.size(), 0)
	assert_true(before.get_string_from_utf8().contains("regular_absent"))

	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = _THROWAWAY
	add_child(main)
	var player := main.get_node("Player") as Player
	await wait_physics_frames(2)
	player.teleport(Vector2(4000, -1200))
	await wait_physics_frames(3)
	player.teleport(Vector2.ZERO)
	await wait_physics_frames(2)
	var second := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	second.save_path = _THROWAWAY
	add_child(second)
	await wait_physics_frames(2)
	second.free()
	main.free()

	var after := FileAccess.get_file_as_bytes(_REAL)
	assert_eq(after, before, "open-world flows rewrote user://save.cfg")

	if had_real:
		var restored := FileAccess.open(_REAL, FileAccess.WRITE)
		restored.store_buffer(prior)
		restored.close()
	else:
		_remove(_REAL)
	_remove(_THROWAWAY)


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
