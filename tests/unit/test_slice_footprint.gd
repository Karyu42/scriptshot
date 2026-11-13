extends GutTest
## Slice footprint (vertical-slice.md §2, §10 row 1): procedural encounter
## anchors inside SliceLayout.FOOTPRINT are dropped by ChunkStream, an anchor
## just outside still spawns, and main.tscn keeps its cold-start conditions
## with the ribbon in place.

const _SAVE := "user://gut_slice_footprint.cfg"

var _player: Node2D


func before_each() -> void:
	_player = Node2D.new()
	add_child_autofree(_player)


func after_each() -> void:
	_discard_save(_SAVE)


func after_all() -> void:
	_discard_save(_SAVE)


func _stream(world_seed: int, at: Vector2, footprint: Rect2) -> ChunkStream:
	_player.position = at
	var s := ChunkStream.new()
	s.seed = world_seed
	s.enemy_scene = preload("res://scenes/regular_enemy.tscn")
	s.elite_scene = preload("res://scenes/elite_enemy.tscn")
	s.pinned_time = 1000000.0
	s.player = _player
	s.footprint = footprint
	add_child_autofree(s)
	s.update_streaming()
	return s


func _has_encounter(s: ChunkStream, c: Vector2i, index: int) -> bool:
	var chunk := s.get_node_or_null("Chunk_%d_%d" % [c.x, c.y])
	return chunk != null and chunk.get_node_or_null("Encounter%d" % index) != null


func _chunk_centre(c: Vector2i) -> Vector2:
	return (Vector2(c) + Vector2(0.5, 0.5)) * float(WorldGen.CHUNK_PX)


func test_a_rect_drops_the_anchor_inside_and_keeps_one_just_outside() -> void:
	var c := Vector2i(0, 0)
	var specs := WorldGen.chunk_encounters(7, c.x, c.y)
	assert_eq(specs.size(), 2)
	var a := specs[0].anchor
	var b := specs[1].anchor
	# A tight rect around anchor 0 only.
	var tight := Rect2(a - Vector2(1, 1), Vector2(2, 2))
	assert_false(tight.has_point(b))
	var s := _stream(7, Vector2(10, 10), tight)
	assert_true(s.drops_anchor(a))
	assert_false(_has_encounter(s, c, specs[0].index), "inside: dropped")
	assert_eq(s.alive_in(c.x, c.y, specs[0].index), 0)
	assert_true(_has_encounter(s, c, specs[1].index), "the other encounter keeps its index")
	assert_gt(s.alive_in(c.x, c.y, specs[1].index), 0)
	s.free()
	# The same rect moved so the anchor is 0.5 px outside its left edge.
	var beside := Rect2(Vector2(a.x + 0.5, a.y - 1), Vector2(2, 2))
	var s2 := _stream(7, Vector2(10, 10), beside)
	assert_false(s2.drops_anchor(a))
	assert_true(_has_encounter(s2, c, specs[0].index), "just outside: spawns")
	assert_gt(s2.alive_in(c.x, c.y, specs[0].index), 0)


func test_no_footprint_drops_nothing() -> void:
	var s := _stream(7, Vector2(10, 10), Rect2())
	assert_false(s.drops_anchor(Vector2.ZERO))
	for spec in WorldGen.chunk_encounters(7, 0, 0):
		assert_true(_has_encounter(s, Vector2i.ZERO, spec.index))


## Seeds whose chunk-`c` encounters put one anchor inside the real footprint
## and one outside it within `near` px of its edge.
func _find_split(c: Vector2i, near: float) -> int:
	var grown := SliceLayout.FOOTPRINT.grow(near)
	for world_seed in range(1, 4000):
		var inside := false
		var close := false
		for spec in WorldGen.chunk_encounters(world_seed, c.x, c.y):
			if SliceLayout.in_footprint(spec.anchor):
				inside = true
			elif grown.has_point(spec.anchor):
				close = true
		if inside and close:
			return world_seed
	return -1


func test_the_slice_footprint_drops_inside_and_keeps_just_outside() -> void:
	# Chunks the ribbon only partly covers: the origin's row and the one below.
	var checked := 0
	for c: Vector2i in [Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(2, 0)]:
		var world_seed := _find_split(c, 200.0)
		if world_seed < 0:
			continue
		checked += 1
		var s := _stream(world_seed, _chunk_centre(c), SliceLayout.FOOTPRINT)
		for spec in WorldGen.chunk_encounters(world_seed, c.x, c.y):
			var inside := SliceLayout.in_footprint(spec.anchor)
			assert_eq(_has_encounter(s, c, spec.index), not inside,
				"seed %d chunk %s anchor %s inside=%s" % [world_seed, c, spec.anchor, inside])
			if not inside:
				assert_gt(s.alive_in(c.x, c.y, spec.index), 0, "outside the footprint it has bodies")
		s.free()
	assert_gt(checked, 0, "found a seed with an anchor on each side of the edge")


func test_chunks_outside_the_footprint_are_unchanged() -> void:
	var c := Vector2i(1, 2)
	assert_false(Rect2(Vector2(c) * WorldGen.CHUNK_PX, Vector2.ONE * WorldGen.CHUNK_PX).intersects(SliceLayout.FOOTPRINT))
	var s := _stream(7, _chunk_centre(c), SliceLayout.FOOTPRINT)
	for spec in WorldGen.chunk_encounters(7, c.x, c.y):
		assert_true(_has_encounter(s, c, spec.index))


# --- main.tscn ------------------------------------------------------------------

func _open_main() -> Main:
	_discard_save(_SAVE)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = _SAVE
	return main


func test_main_has_the_ribbon_and_keeps_the_cold_start() -> void:
	var main := _open_main()
	add_child_autofree(main)
	var slice := main.get_node("SliceLayout") as SliceLayout
	assert_not_null(slice)
	for id in SliceLayout.GATE_IDS:
		assert_false(slice.is_gate_open(id), "%s shut on a fresh save" % id)
	var player := main.get_node("Player") as Player
	assert_eq(player.global_position, Vector2.ZERO)
	assert_eq(SliceLayout.room_at(player.global_position), &"S")
	var expected: Array[Vector2] = [Vector2(300, 0), Vector2(-150, 260), Vector2(-150, -260)]
	var dummies := main.get_node("Dummies").get_children()
	for i in 3:
		var dummy := dummies[i] as TrainingDummy
		assert_eq(dummy.global_position, expected[i])
		assert_eq(SliceLayout.room_at(dummy.global_position), &"S")
	var chunks := main.get_node("ChunkStream") as ChunkStream
	assert_eq(chunks.footprint, SliceLayout.FOOTPRINT)
	var packs := main.get_node("SlicePacks") as SlicePacks
	assert_not_null(packs)
	assert_eq(packs.pack_alive(SlicePacks.PACK_DRIFTERS), 3)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SWARMERS), 10)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SHIELD), 1)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SNIPER), 1)
	for node: Node in main.get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var body := node as RegularEnemy
		assert_gte(body.global_position.length() - body.body_radius, WorldGen.SAFE_RADIUS - 0.05, "no hostile in the disk")
		if body.is_in_group(SlicePacks.GROUP):
			assert_true(SliceLayout.in_footprint(body.anchor), "scripted packs sit in C (%s)" % body.anchor)
			continue
		assert_false(SliceLayout.in_footprint(body.anchor), "no streamed anchor inside the footprint (%s)" % body.anchor)
	var bullets := main.get_node("BulletManager") as BulletManager
	assert_eq(bullets.walls.wall_count, SliceLayout.wall_rects().size() + SliceLayout.GATE_IDS.size(),
		"ribbon walls are bullet walls")


func test_main_bullets_stop_at_g1() -> void:
	var main := _open_main()
	add_child_autofree(main)
	var bullets := main.get_node("BulletManager") as BulletManager
	bullets.auto_step = false
	bullets.bounds_center = null
	bullets.recenter_world_bounds(Vector2(900, 0))
	var r := ShotRequest.with_velocity(Vector2(850, 0), Vector2(600, 0))
	r.lifetime = 2.0
	r.hit_mask = 0
	var before := bullets.alive_count()
	assert_gte(bullets.spawn(r), 0)
	for _i in 20:
		bullets.step(1.0 / 60.0)
	assert_eq(bullets.alive_count(), before, "the shot ended on the shut gate")
	bullets.clear_bullets()


func test_a_disabled_ribbon_is_the_pre_slice_open_world() -> void:
	var main := _open_main()
	(main.get_node("SliceLayout") as SliceLayout).enabled = false
	add_child_autofree(main)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	assert_eq(chunks.footprint, Rect2(), "no footprint")
	var bullets := main.get_node("BulletManager") as BulletManager
	assert_eq(bullets.walls.wall_count, 0, "no ribbon walls")
	assert_eq(main.get_node("SliceLayout").get_child_count(), 0)


func _discard_save(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_walking_out_of_g0_still_finds_a_natural_elite() -> void:
	# Seed 18, chunk (3, -1) encounter 0: a splitting elite at about
	# (6529.85, -1396.14), just north of the footprint. Walking out of G0
	# to (5328, -1400) loads that chunk (RING_RADIUS 1).
	const SEED := 18
	const CX := 3
	const CY := -1
	var spec := WorldGen.chunk_encounters(SEED, CX, CY)[0]
	assert_true(spec.is_elite)
	assert_false(SliceLayout.in_footprint(spec.anchor), "the pin sits in the open world")
	var main := _open_main()
	# _open_main discards the slot; write the pinned seed after that, before ready.
	var save := SaveGame.new()
	save.path = _SAVE
	save.world_seed = SEED
	save.herald_done = true
	save.save()
	var player := main.get_node("Player") as Player
	player.position = Vector2(5328, 0)
	player.set_physics_process(false)
	add_child_autofree(main)
	await wait_physics_frames(2)
	var slice := main.get_node("SliceLayout") as SliceLayout
	assert_true(slice.enabled)
	slice.open_gate(&"G0")
	# Straight walk north through the open G0, same step the layout walk uses.
	var to := Vector2(5328, -1400)
	var guard := 0
	while player.global_position.distance_to(to) > 0.5 and guard < 10000:
		guard += 1
		var left := to - player.global_position
		var col := player.move_and_collide(left.limit_length(6.0))
		if col != null:
			break
	assert_lt(player.global_position.distance_to(to), 0.5, "G0 open: out of the footprint (stopped at %s)" % player.global_position)
	assert_false(SliceLayout.in_footprint(player.global_position))
	var chunks := main.get_node("ChunkStream") as ChunkStream
	chunks.update_streaming()
	await wait_physics_frames(1)
	var found: EliteEnemy = null
	for node: Node in main.get_tree().get_nodes_in_group(EliteEnemy.GROUP_ELITE):
		var elite := node as EliteEnemy
		if elite == null or elite.is_herald or elite.is_half or not elite.is_alive():
			continue
		if elite.chunk == Vector2i(CX, CY) and elite.encounter_index == spec.index:
			found = elite
			break
	assert_not_null(found, "a natural elite is streamed in the open world past G0")
	if found == null:
		return
	assert_false(SliceLayout.in_footprint(found.anchor))
	assert_eq(found.affix, &"splitting")
