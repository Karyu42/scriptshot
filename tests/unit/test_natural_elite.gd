extends GutTest
## L3 natural common elites. Each test is one checklist row from
## docs/design/first-playable-elites.md, plus the Herald interaction that row
## depends on: a death before the arm, with no wake, still allows the Herald;
## a wake that happened before the arm cancels it.
##
## Seeds used below are fixed so the assertions name a chunk:
## - seed 15, chunk (0, -1), encounter 0: splitting elite, anchor ~867 px out
##   (outside the 700 px wake, inside the origin bullet window). Encounter 1
##   is three Drifters. Chunk (-1, 0) encounter 0 is a summoner elite.
## - seed 61, chunk (0, -1), encounter 1: summoner elite ~668 px from the origin,
##   so it wakes while the player is still inside the safe disk.
## - seed 2, origin ring: exactly one elite, chunk (-1, 0) encounter 1, splitting.

const DT := 1.0 / 60.0

var _mains: Array[Main] = []
var _held: Array[Node] = []
var _slot_existed := false


func before_all() -> void:
	_slot_existed = FileAccess.file_exists(SaveGame.DEFAULT_PATH)


func after_all() -> void:
	_free_all()
	assert_eq(FileAccess.file_exists(SaveGame.DEFAULT_PATH), _slot_existed)


func before_each() -> void:
	EliteCue.pulse_enabled = true
	EliteCue.reset_budget()
	EliteSting.reset_session()


func after_each() -> void:
	_free_all()
	EliteCue.pulse_enabled = true
	EliteCue.reset_budget()
	EliteSting.reset_session()


func test_pinned_vector_and_elite_iff_the_roll() -> void:
	var pinned := WorldGen.hash_u(1, 0, 0, 0, "elite")
	assert_almost_eq(pinned, 0.2137598812, 1e-10)
	assert_gte(pinned, WorldGen.ELITE_CHANCE)
	assert_false(WorldGen.roll_is_elite(pinned))
	assert_false(WorldGen.chunk_encounters(1, 0, 0)[0].is_elite)
	assert_eq(WorldGen.ELITE_CHANCE, 0.04)
	var seeds: Array[int] = [1, 2, 42]
	var elites := 0
	var rows_n := 0
	for seed_value in seeds:
		for cy in range(-2, 3):
			for cx in range(-2, 3):
				var specs := WorldGen.chunk_encounters(seed_value, cx, cy)
				assert_eq(specs.size(), 2, "T0 keeps encounters 0 and 1; bit 2 stays unused")
				for spec: EncounterSpec in specs:
					rows_n += 1
					var roll := WorldGen.elite_roll(seed_value, cx, cy, spec.index)
					assert_eq(spec.is_elite, roll < WorldGen.ELITE_CHANCE)
					assert_eq(spec.is_elite, WorldGen.roll_is_elite(roll))
					assert_eq(spec.rarity, WorldGen.RARITY_COMMON)
					assert_eq(spec.rarity, 0)
					assert_lt(spec.index, 2)
					if spec.is_elite:
						elites += 1
						assert_eq(spec.base, &"drifter")
						assert_eq(spec.affix_ids.size(), 1)
						var affix := spec.affix_ids[0]
						assert_true(affix == &"splitting" or affix == &"summoner")
						assert_eq(affix, WorldGen.elite_affix(seed_value, cx, cy, spec.index))
						var affix_u := WorldGen.hash_u(seed_value, cx, cy, spec.index, "eaff", 0)
						var expect: StringName = &"summoner" if affix_u >= 0.5 else &"splitting"
						assert_eq(affix, expect)
						assert_eq(spec.members.size(), 1)
						assert_eq(spec.archetype_of(0), &"drifter", "a Swarmer group cannot escort")
						assert_eq(spec.count_of(0), 1)
						assert_eq(spec.points_spent, 1)
						var escort := WorldGen.escort_position(spec.anchor)
						assert_almost_eq(escort.distance_to(spec.anchor), WorldGen.ESCORT_DISTANCE, 0.001)
						assert_gt(escort.length(), spec.anchor.length() - 0.001)
					else:
						assert_eq(spec.base, StringName())
						assert_eq(spec.affix_ids.size(), 0)
						assert_eq(spec.points_spent, 3)
						assert_eq(spec.rarity, 0)
	assert_eq(rows_n, 150)
	assert_gt(elites, 0, "seeds 1, 2 and 42 do produce a natural elite inside the scan")
	assert_eq(WorldGen.chunk_encounters(1, 8, 0).size(), 0)


func test_same_seed_same_encounters_in_any_chunk_order() -> void:
	var seeds: Array[int] = [1, 2, 42]
	for seed_value in seeds:
		var coords: Array[Vector2i] = []
		for cy in range(-2, 3):
			for cx in range(-2, 3):
				coords.append(Vector2i(cx, cy))
		var forward: Dictionary[Vector2i, String] = {}
		for coord: Vector2i in coords:
			forward[coord] = _stamp(WorldGen.chunk_encounters(seed_value, coord.x, coord.y))
		for i in range(coords.size() - 1, -1, -1):
			var coord := coords[i]
			var again := _stamp(WorldGen.chunk_encounters(seed_value, coord.x, coord.y))
			assert_eq(again, forward[coord], "chunk %s seed %d" % [coord, seed_value])


func test_kill_mask_persists_and_the_regular_still_uses_the_five_minute_rule() -> void:
	var path := "user://gut_l3_mask.cfg"
	_discard(path)
	var player := Node2D.new()
	player.position = Vector2(100, 100)
	_hold(player)
	var stream := _stream(15, player, 1000000.0)
	stream.update_streaming()
	var spec := WorldGen.chunk_encounters(15, 0, -1)
	assert_true(spec[0].is_elite)
	assert_eq(spec[0].affix_ids[0], &"splitting")
	assert_false(spec[1].is_elite)
	assert_eq(spec[1].count_of(0), 3)
	var elite := _elite_body(stream, 0, -1, 0)
	assert_not_null(elite)
	assert_false(elite.is_herald)
	assert_false(elite.woken)
	assert_gt(elite.global_position.distance_to(player.position), WorldGen.WAKE_RADIUS)
	assert_almost_eq(elite.health.max_hp, 75.0, 0.01)
	assert_eq(stream.alive_in(0, -1, 0), 2, "elite plus one escort")
	var escort := _escort(stream, 0, -1, 0)
	assert_not_null(escort)
	assert_eq(escort.archetype, RegularEnemy.ARCH_DRIFTER)
	assert_false(escort is EliteEnemy)
	assert_almost_eq(escort.global_position.distance_to(spec[0].anchor), WorldGen.ESCORT_DISTANCE, 0.05)
	_assert_disk(stream)
	elite.health.try_damage(10000.0)
	assert_false(elite.is_alive())
	assert_true(stream.elite_killed(0, -1, 0))
	assert_eq(stream.elite_bits_at(0, -1), 1, "bit 0, not the reserved bit 2")
	assert_eq(stream.elite_bits_at(0, -1) & 0x4, 0)
	assert_gt(stream.alive_in(0, -1, 0), 0, "halves and the escort are still up")
	assert_false(stream.is_absent(0, -1, 0))
	assert_eq(_halves(stream, 0, -1, 0).size(), 2)
	# The escort dying does not clear or set anything new. The bit is already set.
	escort.health.try_damage(10000.0)
	assert_true(stream.elite_killed(0, -1, 0))
	assert_eq(stream.elite_bits_at(0, -1), 1)
	_kill_regulars(stream, 0, -1, 1)
	assert_eq(stream.alive_in(0, -1, 1), 0)
	player.position = Vector2(6 * 2048, 6 * 2048)
	stream.update_streaming()
	assert_false(stream.is_loaded(0, -1))
	assert_false(stream.is_absent(0, -1, 0), "elite encounters do not use the 5-minute list")
	assert_true(stream.is_absent(0, -1, 1))
	var save := SaveGame.new()
	save.path = path
	save.world_seed = 15
	save.elite_kills = stream.elite_kill_records()
	save.regular_absent = stream.absent_records()
	save.save()
	stream.free()
	var loaded := SaveGame.load_from(path)
	assert_eq(loaded.world_seed, 15)
	assert_eq(loaded.elite_bits_at(0, -1), 1)
	assert_eq(loaded.elite_bits_at(0, -1) & (1 << 0), 1)
	assert_false(loaded.herald_done)
	var again := _stream(15, player, 1000000.0)
	again.load_elite_kills(loaded.elite_kills)
	again.load_absent(loaded.regular_absent)
	player.position = Vector2(100, 100)
	again.update_streaming()
	assert_eq(again.alive_in(0, -1, 0), 0, "the killed elite and its escort stay gone")
	assert_eq(again.alive_in(0, -1, 1), 0, "back before 5 min: the regular stays empty")
	assert_false(again.elite_killed(0, -1, 1))
	player.position = Vector2(6 * 2048, 6 * 2048)
	again.update_streaming()
	again.pinned_time = 1000000.0 + ChunkStream.OUT_SECONDS
	player.position = Vector2(100, 100)
	again.update_streaming()
	assert_eq(again.alive_in(0, -1, 0), 0, "five minutes does not bring an elite back")
	assert_eq(again.alive_in(0, -1, 1), 3, "the same regular pack is back")
	_assert_disk(again)
	_discard(path)


func test_a_bullet_on_the_unload_tick_still_sets_the_bit() -> void:
	var player := Node2D.new()
	player.position = Vector2(100, 100)
	_hold(player)
	var stream := _stream(15, player, 2000000.0)
	stream.update_streaming()
	var elite := _elite_body(stream, 0, -1, 0)
	assert_not_null(elite)
	var bullets := BulletManager.new()
	bullets.backend_preference = "gdscript"
	bullets.world_bounds = Rect2(-20000, -20000, 40000, 40000)
	bullets.render_enabled = false
	bullets.auto_step = true
	_hold(bullets)
	var shot := ShotRequest.polar(elite.global_position, 0.0, 0.0)
	shot.damage = 200.0
	shot.radius = 32.0
	shot.owner_layer = Layers.PLAYER
	shot.hit_mask = Layers.ENEMY
	shot.lifetime = 2.0
	shot.behavior_id = 0
	assert_eq(shot.behavior_id, 0)
	assert_true(bullets.emitter.request_shot(shot))
	player.position = Vector2(6 * 2048, 6 * 2048)
	await wait_physics_frames(1)
	assert_false(stream.is_loaded(0, -1))
	assert_true(stream.elite_killed(0, -1, 0), "the kill on the unload tick is remembered")
	assert_eq(bullets.pool.owner_counts[BulletPool.OWNER_ENEMY], 0)
	player.position = Vector2(100, 100)
	stream.update_streaming()
	assert_eq(stream.alive_in(0, -1, 0), 0)
	assert_eq(stream.alive_in(0, -1, 1), 3)


func test_shards_only_for_the_elite_body() -> void:
	var path := "user://gut_l3_shards.cfg"
	_discard(path)
	_write_save(path, 15, false)
	var main := _open_main(path, Vector2(100, 100))
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	await wait_physics_frames(1)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	var bullets := main.get_node("BulletManager") as BulletManager
	var elite := _elite_body(chunks, 0, -1, 0)
	assert_not_null(elite)
	assert_eq(elite.affix, &"splitting")
	assert_false(elite.woken)
	var save := SaveGame.load_from(path)
	assert_eq(save.shards, 0)
	# A regular in the same chunk drops nothing.
	var regular_root := chunks.get_node("Chunk_0_-1/Encounter1") as Node
	var regular := regular_root.get_child(0) as RegularEnemy
	assert_not_null(regular)
	assert_false(regular is EliteEnemy)
	regular.health.try_damage(10000.0)
	assert_eq(SaveGame.load_from(path).shards, 0)
	var escort := _escort(chunks, 0, -1, 0)
	escort.health.try_damage(10000.0)
	assert_eq(SaveGame.load_from(path).shards, 0)
	var hp := elite.health.hp
	var chip := ShotRequest.polar(elite.global_position, 0.0, 0.0)
	chip.damage = 1.0
	chip.radius = 24.0
	chip.owner_layer = Layers.PLAYER
	chip.hit_mask = Layers.ENEMY
	chip.lifetime = 2.0
	chip.behavior_id = 0
	assert_eq(chip.behavior_id, 0)
	assert_true(bullets.emitter.request_shot(chip))
	await wait_physics_frames(2)
	assert_true(is_instance_valid(elite))
	assert_almost_eq(elite.health.hp, hp - 1.0, 0.01)
	var lethal := ShotRequest.polar(elite.global_position, 0.0, 0.0)
	lethal.damage = 200.0
	lethal.radius = 32.0
	lethal.owner_layer = Layers.PLAYER
	lethal.hit_mask = Layers.ENEMY
	lethal.lifetime = 2.0
	lethal.behavior_id = 0
	assert_true(bullets.emitter.request_shot(lethal))
	await wait_physics_frames(2)
	assert_false(is_instance_valid(elite) and elite.is_alive())
	assert_eq(SaveGame.load_from(path).shards, 1)
	assert_eq(SaveGame.load_from(path).elite_bits_at(0, -1), 1)
	var halves := _halves(chunks, 0, -1, 0)
	assert_eq(halves.size(), 2)
	for half: EliteEnemy in halves:
		assert_false(half.grants_shard)
		assert_true(half.is_half)
		half.health.try_damage(10000.0)
	assert_eq(SaveGame.load_from(path).shards, 1)
	var summoner := _elite_body(chunks, -1, 0, 0)
	assert_not_null(summoner)
	assert_eq(summoner.affix, &"summoner")
	assert_false(summoner.woken)
	summoner._physics_process(6.0)
	var adds := _swarmers(summoner.get_parent())
	assert_eq(adds.size(), 2)
	adds[0].health.try_damage(10000.0)
	assert_eq(SaveGame.load_from(path).shards, 1, "a summon drops nothing")
	summoner.health.try_damage(10000.0)
	assert_eq(SaveGame.load_from(path).shards, 2)
	assert_eq(SaveGame.load_from(path).elite_bits_at(-1, 0), 1)
	assert_eq(bullets.pool.owner_counts[BulletPool.OWNER_ENEMY], 0)
	_discard(path)


func test_main_scene_spawns_natural_elites_at_the_roll() -> void:
	var path := "user://gut_l3_main.cfg"
	_discard(path)
	_write_save(path, 2, false)
	var main := _open_main(path, Vector2(80, 40))
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	assert_eq(chunks.seed, 2)
	var elites := _naturals(main.get_tree())
	assert_eq(elites.size(), 1, "seed 2's origin ring has one natural elite")
	var elite := elites[0]
	assert_eq(elite.chunk, Vector2i(-1, 0))
	assert_eq(elite.encounter_index, 1)
	assert_eq(elite.affix, &"splitting")
	assert_eq(elite.archetype, RegularEnemy.ARCH_DRIFTER)
	assert_almost_eq(elite.health.max_hp, 75.0, 0.01)
	assert_eq(elite.outline_width(), EliteCue.OUTLINE_WIDTH)
	assert_eq(elite.outline_width(), 3.0)
	assert_not_null(elite.cue)
	assert_true(elite.cue.draws_ring())
	assert_eq(elite.cue.glyph, EliteCue.GLYPH_CIRCLE)
	assert_eq(EliteCue.ARC_POINTS, 32)
	assert_false(elite.is_herald)
	assert_eq(elite.grants_shard, true)
	var spec := WorldGen.chunk_encounters(2, -1, 0)
	assert_true(spec[1].is_elite)
	assert_false(spec[0].is_elite)
	assert_eq(chunks.alive_in(-1, 0, 1), 2)
	assert_eq(chunks.alive_in(-1, 0, 0), spec[0].count_of(0))
	var escort := _escort(chunks, -1, 0, 1)
	assert_not_null(escort)
	assert_almost_eq(escort.global_position.distance_to(spec[1].anchor), WorldGen.ESCORT_DISTANCE, 0.05)
	for coord: Vector2i in chunks.loaded_coords():
		var rows := WorldGen.chunk_encounters(2, coord.x, coord.y)
		assert_eq(rows.size(), 2)
		for row: EncounterSpec in rows:
			if row.is_elite:
				assert_eq(chunks.alive_in(coord.x, coord.y, row.index), 2)
			else:
				assert_eq(chunks.alive_in(coord.x, coord.y, row.index), row.count_of(0))
	_assert_disk(chunks)
	# This anchor sits outside the origin bullet window. The shard test kills
	# one with a bullet; here the death path is the same Health call a hit uses.
	elite.health.try_damage(10000.0)
	assert_false(is_instance_valid(elite) and elite.is_alive())
	assert_eq(SaveGame.load_from(path).shards, 1)
	assert_eq(SaveGame.load_from(path).elite_bits_at(-1, 0), 2, "encounter 1 is bit 1")
	player.teleport(Vector2(8 * 2048, 8 * 2048))
	chunks.update_streaming()
	assert_false(chunks.is_loaded(-1, 0))
	main.free()
	_mains.clear()
	var reloaded := _open_main(path, Vector2(80, 40))
	var chunks2 := reloaded.get_node("ChunkStream") as ChunkStream
	assert_eq(chunks2.alive_in(-1, 0, 1), 0, "reload after unload: the elite encounter is absent")
	assert_gt(chunks2.alive_in(-1, 0, 0), 0, "the regular encounter in that chunk is still there")
	assert_eq(_naturals(reloaded.get_tree()).size(), 0)
	_discard(path)


func test_cue_on_wake() -> void:
	var path := "user://gut_l3_cue.cfg"
	_discard(path)
	_write_save(path, 61, false)
	var main := _open_main(path, Vector2.ZERO)
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	var close := _elite_body(chunks, 0, -1, 1)
	assert_not_null(close)
	assert_eq(close.affix, &"summoner")
	assert_false(close.woken)
	assert_lte(close.global_position.distance_to(player.global_position), WorldGen.WAKE_RADIUS)
	assert_lte(player.global_position.length(), WorldGen.SAFE_RADIUS)
	await wait_physics_frames(2)
	assert_true(close.woken)
	assert_gt(close.cue.brighten_left, 0.0)
	assert_true(close.cue.draws_ring())
	assert_eq(close.cue.glyph, EliteCue.GLYPH_CIRCLE)
	assert_eq(close.outline_width(), 3.0)
	assert_true(close.sting.requested)
	var far := _elite_body(chunks, 0, 0, 1)
	assert_not_null(far)
	assert_false(far.woken, "wake is 700 px, not the whole chunk")
	assert_almost_eq(far.cue.brighten_left, 0.0, 0.001)
	close.queue_redraw()
	await wait_process_frames(1)
	assert_true(close.sting.used_wav or close.sting.used_fallback)
	var arm := main.get_node("HeraldArm") as HeraldArm
	assert_false(arm.armed, "the player has not left the disk")
	_discard(path)


func test_a_prior_wake_cancels_the_herald() -> void:
	var path := "user://gut_l3_wake.cfg"
	_discard(path)
	_write_save(path, 61, false)
	var main := _open_main(path, Vector2.ZERO)
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	await wait_physics_frames(2)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	var close := _elite_body(chunks, 0, -1, 1)
	assert_true(close.woken)
	assert_false(close.is_herald)
	var arm := main.get_node("HeraldArm") as HeraldArm
	var director := main.get_node("HeraldDirector") as HeraldDirector
	assert_false(arm.armed)
	assert_false(SaveGame.load_from(path).herald_done)
	assert_eq(SaveGame.load_from(path).shards, 0)
	player.teleport(Vector2(600, 0))
	player.velocity = Vector2(80, 0)
	arm.advance(0.0)
	assert_true(arm.armed)
	assert_true(director.resolved)
	assert_null(director.herald)
	assert_true(SaveGame.load_from(path).herald_done)
	assert_eq(SaveGame.load_from(path).shards, 0)
	assert_false(chunks.elite_killed(0, -1, 1), "a wake is not a kill")
	director.advance(90.0)
	assert_null(director.herald)
	_discard(path)


func test_death_before_the_arm_without_a_wake_still_allows_the_herald() -> void:
	var path := "user://gut_l3_prekill.cfg"
	_discard(path)
	_write_save(path, 15, false)
	var main := _open_main(path, Vector2(100, 100))
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	await wait_physics_frames(1)
	var chunks := main.get_node("ChunkStream") as ChunkStream
	var elite := _elite_body(chunks, 0, -1, 0)
	assert_not_null(elite)
	assert_false(elite.woken)
	assert_gt(elite.global_position.distance_to(player.global_position), WorldGen.WAKE_RADIUS)
	var summoner := _elite_body(chunks, -1, 0, 0)
	assert_not_null(summoner)
	assert_false(summoner.woken)
	elite.health.try_damage(10000.0)
	assert_false(elite.is_alive())
	assert_eq(SaveGame.load_from(path).shards, 1)
	assert_eq(SaveGame.load_from(path).elite_bits_at(0, -1), 1)
	assert_false(SaveGame.load_from(path).herald_done, "a kill before the arm does not set the flag")
	var arm := main.get_node("HeraldArm") as HeraldArm
	var director := main.get_node("HeraldDirector") as HeraldDirector
	player.teleport(Vector2(600, 0))
	player.velocity = Vector2(100, 0)
	arm.advance(0.0)
	assert_true(arm.armed)
	assert_true(director.counting)
	assert_false(director.resolved)
	assert_false(summoner.woken)
	var delay := WorldGen.herald_delay(15)
	assert_gte(delay, 58.0)
	assert_lt(delay, 78.0)
	director.advance(delay - 0.05)
	assert_null(director.herald)
	assert_false(SaveGame.load_from(path).herald_done)
	director.advance(0.05)
	assert_not_null(director.herald)
	assert_true(director.herald.is_herald)
	assert_true(SaveGame.load_from(path).herald_done)
	assert_gte(director.herald.global_position.length() - director.herald.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	_discard(path)


func _stamp(rows: Array[EncounterSpec]) -> String:
	var text := ""
	for row: EncounterSpec in rows:
		var affix := ""
		if not row.affix_ids.is_empty():
			affix = String(row.affix_ids[0])
		var member := ""
		if not row.members.is_empty():
			member = "%s:%d" % [String(row.archetype_of(0)), row.count_of(0)]
		var elite_flag := "1" if row.is_elite else "0"
		text += "%d:%s:%d:%s:%s:%s:%.5f:%.5f:%d|" % [
			row.index,
			elite_flag,
			row.rarity,
			String(row.base),
			affix,
			member,
			row.anchor.x,
			row.anchor.y,
			row.points_spent,
		]
	return text


func _stream(seed_value: int, player: Node2D, t: float) -> ChunkStream:
	var stream := ChunkStream.new()
	stream.seed = seed_value
	stream.enemy_scene = preload("res://scenes/regular_enemy.tscn")
	stream.elite_scene = preload("res://scenes/elite_enemy.tscn")
	stream.pinned_time = t
	stream.player = player
	_hold(stream)
	return stream


func _elite_body(stream: ChunkStream, cx: int, cy: int, index: int) -> EliteEnemy:
	var root := stream.get_node_or_null("Chunk_%d_%d/Encounter%d" % [cx, cy, index]) as Node
	if root == null:
		return null
	for child: Node in root.get_children():
		var elite := child as EliteEnemy
		if elite != null and not elite.is_half and elite.is_alive():
			return elite
	return null


func _escort(stream: ChunkStream, cx: int, cy: int, index: int) -> RegularEnemy:
	var root := stream.get_node_or_null("Chunk_%d_%d/Encounter%d" % [cx, cy, index]) as Node
	if root == null:
		return null
	for child: Node in root.get_children():
		var body := child as RegularEnemy
		if body == null or not body.is_alive() or body is EliteEnemy:
			continue
		return body
	return null


func _halves(stream: ChunkStream, cx: int, cy: int, index: int) -> Array[EliteEnemy]:
	var out: Array[EliteEnemy] = []
	var root := stream.get_node_or_null("Chunk_%d_%d/Encounter%d" % [cx, cy, index]) as Node
	if root == null:
		return out
	for child: Node in root.get_children():
		var elite := child as EliteEnemy
		if elite != null and elite.is_half and elite.is_alive():
			out.append(elite)
	return out


func _swarmers(parent: Node) -> Array[RegularEnemy]:
	var out: Array[RegularEnemy] = []
	for child: Node in parent.get_children():
		var body := child as RegularEnemy
		if body == null or not body.is_alive() or body is EliteEnemy:
			continue
		if body.archetype == RegularEnemy.ARCH_SWARMER:
			out.append(body)
	return out


func _kill_regulars(stream: ChunkStream, cx: int, cy: int, index: int) -> void:
	var root := stream.get_node("Chunk_%d_%d/Encounter%d" % [cx, cy, index]) as Node
	for child: Node in root.get_children():
		var body := child as RegularEnemy
		if body != null and body.is_alive():
			body.health.try_damage(10000.0)


func _assert_disk(stream: ChunkStream) -> void:
	for coord: Vector2i in stream.loaded_coords():
		var chunk := stream.get_node("Chunk_%d_%d" % [coord.x, coord.y]) as Node
		for enc: Node in chunk.get_children():
			for child: Node in enc.get_children():
				var body := child as RegularEnemy
				if body == null or not body.is_alive():
					continue
				assert_gte(body.global_position.length() - body.body_radius, WorldGen.SAFE_RADIUS - 0.05)


func _naturals(tree: SceneTree) -> Array[EliteEnemy]:
	var out: Array[EliteEnemy] = []
	for node: Node in tree.get_nodes_in_group(EliteEnemy.GROUP_ELITE):
		var elite := node as EliteEnemy
		if elite == null or elite.is_herald or elite.is_half or not elite.is_alive():
			continue
		if elite.is_in_group(SliceRoomD.GROUP):
			continue
		out.append(elite)
	return out


func _open_main(path: String, at: Vector2) -> Main:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = path
	# These seeds pin natural elites in the origin's ring, which the
	# vertical-slice footprint now drops and walls off. Natural-elite rules
	# are footprint-independent; test_slice_footprint covers the drop.
	(main.get_node("SliceLayout") as SliceLayout).enabled = false
	var player := main.get_node("Player") as Player
	player.position = at
	_mains.append(main)
	add_child(main)
	return main


func _write_save(path: String, seed_value: int, done: bool) -> void:
	var save := SaveGame.new()
	save.path = path
	save.world_seed = seed_value
	save.herald_done = done
	save.shards = 0
	save.elite_kills = []
	save.save()


func _hold(node: Node) -> void:
	_held.append(node)
	add_child(node)


func _free_all() -> void:
	for node: Node in _held:
		if is_instance_valid(node):
			node.free()
	_held.clear()
	for main: Main in _mains:
		if is_instance_valid(main):
			main.free()
	_mains.clear()


func _discard(path: String) -> void:
	if path.is_empty() or path == SaveGame.DEFAULT_PATH:
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
