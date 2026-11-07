extends GutTest
## Chunk ring, T0 bodies, the safe zone, and the 5-minute regular respawn rule.

class Clock:
	extends RefCounted
	var t := 1000000.0
	func now() -> float:
		return t


var _player: Node2D
var _stream: ChunkStream
var _clock: Clock


func before_each() -> void:
	_clock = Clock.new()
	_player = Node2D.new()
	_player.position = Vector2(10, 10)
	add_child_autofree(_player)
	_stream = ChunkStream.new()
	_stream.seed = 7
	_stream.enemy_scene = preload("res://scenes/regular_enemy.tscn")
	_stream.pinned_time = _clock.t
	_stream.player = _player
	add_child_autofree(_stream)


func test_origin_loads_the_3_by_3_and_unloads_the_rest() -> void:
	_sync()
	assert_eq(_stream.loaded_coords().size(), 9)
	assert_true(_stream.is_loaded(0, 0))
	assert_true(_stream.is_loaded(-1, -1))
	assert_true(_stream.is_loaded(1, 1))
	assert_false(_stream.is_loaded(2, 0))
	_player.position = Vector2(3 * 2048 + 20, 20)
	_sync()
	assert_eq(_stream.loaded_coords().size(), 9)
	assert_false(_stream.is_loaded(0, 0))
	assert_false(_stream.is_loaded(-1, 0))
	assert_true(_stream.is_loaded(2, -1))
	assert_true(_stream.is_loaded(3, 0))
	assert_true(_stream.is_loaded(4, 1))
	assert_false(_stream.is_loaded(5, 0))


func test_t1_chunk_in_the_ring_spawns_nothing() -> void:
	_player.position = Vector2(8 * 2048 + 100, 100)
	_sync()
	assert_true(_stream.is_loaded(8, 0))
	assert_eq(_stream.get_node("Chunk_8_0").get_child_count(), 0)
	assert_eq(_stream.alive_in(8, 0, 0), 0)
	assert_true(_stream.is_loaded(7, 0))
	assert_gt(_stream.alive_in(7, 0, 0), 0)
	assert_eq(_stream.alive_in(7, 0, 1), 3)


func test_cold_load_has_no_body_inside_the_safe_zone() -> void:
	_sync()
	var bodies := 0
	for coord in _stream.loaded_coords():
		var chunk := _stream.get_node("Chunk_%d_%d" % [coord.x, coord.y]) as Node
		for enc: Node in chunk.get_children():
			for child: Node in enc.get_children():
				var enemy := child as RegularEnemy
				assert_not_null(enemy)
				bodies += 1
				assert_gte(enemy.global_position.length(), WorldGen.SAFE_RADIUS - 0.05)
				assert_true(enemy.archetype == RegularEnemy.ARCH_DRIFTER or enemy.archetype == RegularEnemy.ARCH_SWARMER)
	assert_gt(bodies, 0)
	var spec := WorldGen.chunk_encounters(7, 0, 0)
	assert_eq(_stream.alive_in(0, 0, 0), spec[0].count_of(0))
	assert_eq(_stream.alive_in(0, 0, 1), 3)


func test_empty_encounter_stays_gone_until_five_minutes_outside() -> void:
	_player.position = Vector2(3000, 3000)
	_sync()
	var spec := WorldGen.chunk_encounters(7, 1, 1)
	var swarmers := spec[0].count_of(0)
	assert_eq(_stream.alive_in(1, 1, 0), swarmers)
	assert_eq(_stream.alive_in(1, 1, 1), 3)
	_kill_encounter(1, 1, 0)
	assert_eq(_stream.alive_in(1, 1, 0), 0)
	_player.position = Vector2(6 * 2048 + 100, 6 * 2048 + 100)
	_sync()
	assert_false(_stream.is_loaded(1, 1))
	_clock.t += 299.0
	_player.position = Vector2(3000, 3000)
	_sync()
	assert_eq(_stream.alive_in(1, 1, 0), 0, "back before 5 min: still empty")
	assert_eq(_stream.alive_in(1, 1, 1), 3, "the encounter that was not empty respawns")
	_player.position = Vector2(6 * 2048 + 100, 6 * 2048 + 100)
	_sync()
	_clock.t += 299.0
	_player.position = Vector2(3000, 3000)
	_sync()
	assert_eq(_stream.alive_in(1, 1, 0), 0, "two short trips do not add up")
	_player.position = Vector2(6 * 2048 + 100, 6 * 2048 + 100)
	_sync()
	_clock.t += ChunkStream.OUT_SECONDS
	_player.position = Vector2(3000, 3000)
	_sync()
	assert_eq(_stream.alive_in(1, 1, 0), swarmers, "after 5 continuous minutes the same pack is back")
	assert_eq(_stream.alive_in(1, 1, 1), 3)


func test_absent_rows_round_trip_through_the_save() -> void:
	var path := "user://l0l1_absent_roundtrip.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_player.position = Vector2(3000, 3000)
	_sync()
	_kill_encounter(1, 1, 1)
	_player.position = Vector2(6 * 2048 + 50, 50)
	_sync()
	var save := SaveGame.new()
	save.path = path
	save.world_seed = 7
	save.regular_absent = _stream.absent_records()
	save.save()
	var loaded := SaveGame.load_from(path)
	assert_eq(loaded.world_seed, 7)
	assert_false(loaded.herald_done)
	assert_eq(loaded.shards, 0)
	assert_eq(loaded.elite_kills.size(), 0)
	assert_eq(loaded.regular_absent.size(), 1)
	assert_eq(loaded.absent_key(0), Vector3i(1, 1, 1))
	var again := ChunkStream.new()
	again.seed = 7
	again.enemy_scene = _stream.enemy_scene
	again.pinned_time = _clock.t
	again.player = _player
	again.load_absent(loaded.regular_absent)
	add_child_autofree(again)
	_player.position = Vector2(3000, 3000)
	again.pinned_time = _clock.t
	again.update_streaming()
	assert_eq(again.alive_in(1, 1, 1), 0)
	assert_gt(again.alive_in(1, 1, 0), 0)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _sync() -> void:
	_stream.pinned_time = _clock.t
	_stream.update_streaming()


func _kill_encounter(cx: int, cy: int, index: int) -> void:
	var root := _stream.get_node("Chunk_%d_%d/Encounter%d" % [cx, cy, index]) as Node
	for child: Node in root.get_children():
		var enemy := child as RegularEnemy
		if enemy != null and enemy.is_alive():
			enemy.health.try_damage(10000.0)
