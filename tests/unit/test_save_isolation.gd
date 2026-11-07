extends GutTest
## The player's save slot is never opened by tests. The GUT pre-run hook
## points SaveGame.resolved_path() at user://test_tmp/<run>/save.cfg, and a
## Main that leaves save_path unset follows that path.


func test_default_main_uses_the_isolated_slot_and_reads_its_sentinel() -> void:
	assert_false(SaveGame.slot_override.is_empty(), "the pre-run hook did not isolate the slot")
	var slot := SaveGame.resolved_path()
	assert_ne(slot, SaveGame.DEFAULT_PATH)
	assert_true(slot.begins_with("user://test_tmp/"))
	assert_true(slot.ends_with("save.cfg"))

	var sentinel := SaveGame.new()
	sentinel.path = slot
	sentinel.world_seed = 8675309
	sentinel.herald_done = true
	sentinel.shards = 4
	sentinel.regular_absent = [{"cx": 4, "cy": -2, "index": 1, "since_unix": 1710000000.5}]
	sentinel.save()

	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	assert_true(main.save_path.is_empty(), "the scene default must stay unset")
	add_child(main)
	await wait_physics_frames(2)
	assert_eq(main.current_save_path(), slot)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	assert_eq(chunks.seed, 8675309, "Main read the isolated sentinel, not another slot")
	assert_eq(chunks.is_absent(4, -2, 1), true)
	main.free()
	# The exit write stays on the isolated file.
	assert_eq(SaveGame.load_from(slot).world_seed, 8675309)


func test_only_save_game_names_the_player_slot() -> void:
	var needle := SaveGame.DEFAULT_PATH
	var hits: Array[String] = []
	_scan("res://src", needle, hits)
	_scan("res://tests", needle, hits)
	var allowed: Array[String] = ["res://src/world/save_game.gd"]
	assert_eq(hits, allowed)


func _scan(root: String, needle: String, hits: Array[String]) -> void:
	for file_name in DirAccess.get_files_at(root):
		if not file_name.ends_with(".gd"):
			continue
		var path := root.path_join(file_name)
		var text := FileAccess.get_file_as_string(path)
		if text.contains(needle):
			hits.append(path)
	for sub_name in DirAccess.get_directories_at(root):
		if sub_name.begins_with("."):
			continue
		_scan(root.path_join(sub_name), needle, hits)
