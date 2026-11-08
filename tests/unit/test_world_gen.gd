extends GutTest
## WorldGen: pinned hash vectors, tier math, anchors, and T0 encounter composition.
## Numbers are the slice contract in docs/design/first-playable-elites.md.


func test_pinned_hash_vectors() -> void:
	assert_almost_eq(WorldGen.hash_u(1, "herald"), 0.3877327727, 1e-10)
	assert_almost_eq(WorldGen.hash_u(42, "herald"), 0.8668172005, 1e-10)
	assert_almost_eq(WorldGen.hash_u(1, "herald", "eaff"), 0.8750332294, 1e-10)
	assert_almost_eq(WorldGen.hash_u(1, 0, 0, 0, "elite"), 0.2137598812, 1e-10)
	assert_false(WorldGen.roll_is_elite(0.2137598812))
	assert_false(WorldGen.chunk_encounters(1, 0, 0)[0].is_elite)


func test_hash_u_is_stable_and_in_the_unit_interval() -> void:
	var first := WorldGen.hash_u(1, "herald", "eaff")
	var again := WorldGen.hash_u(1, &"herald", &"eaff")
	assert_eq(first, again, "String and StringName are the same payload")
	assert_gte(first, 0.0)
	assert_lt(first, 1.0)
	var elite := WorldGen.hash_u(1, 0, 0, 0, "elite")
	assert_gte(elite, 0.04, "the pinned elite vector is not an elite")


func test_tier_at_uses_chebyshev_pixels() -> void:
	assert_eq(WorldGen.tier_at(0.0, 0.0), 0)
	assert_eq(WorldGen.tier_at(16383.9, -100.0), 0)
	assert_eq(WorldGen.tier_at(16384.0, 0.0), 1)
	assert_eq(WorldGen.tier_at(-16384.0, 0.0), 1)
	assert_eq(WorldGen.tier_at(0.0, -32768.0), 2)
	assert_eq(WorldGen.tier_at(16384.0 * 2.0 - 0.1, 0.0), 1)
	assert_eq(WorldGen.tier_at(16384.0 * 2.0, 0.0), 2)


func test_chunk_tier_is_the_16_by_16_square() -> void:
	assert_eq(WorldGen.chunk_tier(0, 0), 0)
	assert_eq(WorldGen.chunk_tier(7, 7), 0)
	assert_eq(WorldGen.chunk_tier(-8, -8), 0)
	assert_eq(WorldGen.chunk_tier(7, -8), 0)
	assert_eq(WorldGen.chunk_tier(-8, 7), 0)
	assert_eq(WorldGen.chunk_tier(8, 0), 1)
	assert_eq(WorldGen.chunk_tier(-9, 0), 1)
	assert_eq(WorldGen.chunk_tier(0, -9), 1)
	assert_eq(WorldGen.chunk_of(Vector2(0, 0)), Vector2i(0, 0))
	assert_eq(WorldGen.chunk_of(Vector2(-0.1, 10)), Vector2i(-1, 0))
	assert_eq(WorldGen.chunk_of(Vector2(-2048, -2048)), Vector2i(-1, -1))
	assert_eq(WorldGen.budget_for_tier(0), 6)


func test_ring_is_chebyshev_3_by_3() -> void:
	var center := Vector2i(2, -1)
	assert_true(WorldGen.chunk_in_ring(center, 2, -1))
	assert_true(WorldGen.chunk_in_ring(center, 1, -2))
	assert_true(WorldGen.chunk_in_ring(center, 3, 0))
	assert_false(WorldGen.chunk_in_ring(center, 4, -1))
	assert_false(WorldGen.chunk_in_ring(center, 2, 1))


func test_anchor_rejects_the_safe_disk_and_falls_back_to_the_far_corner() -> void:
	var inside: Array[Vector2] = []
	for _i in WorldGen.ANCHOR_SALTS:
		inside.append(Vector2(0.01, 0.01))
	assert_eq(WorldGen.pick_anchor(0, 0, inside), Vector2(1792, 1792))
	# Chunk (-1, -1)'s near-origin corner is the far end of the inset, so the
	# samples that fall inside the disk sit at the high end of the unit square.
	var inside_neg: Array[Vector2] = []
	for _j in WorldGen.ANCHOR_SALTS:
		inside_neg.append(Vector2(0.99, 0.99))
	var far := WorldGen.pick_anchor(-1, -1, inside_neg)
	assert_eq(far, Vector2(-1792, -1792))
	assert_gte(far.length(), WorldGen.SAFE_RADIUS)
	var ok: Array[Vector2] = [Vector2(0.9, 0.8)]
	var point := WorldGen.pick_anchor(0, 0, ok)
	assert_almost_eq(point.x, 256.0 + 0.9 * 1536.0, 0.001)
	assert_almost_eq(point.y, 256.0 + 0.8 * 1536.0, 0.001)
	assert_gte(point.length(), WorldGen.SAFE_RADIUS)


func test_anchors_stay_in_the_inset_and_outside_the_safe_zone() -> void:
	var seeds: Array[int] = [1, 2, 42]
	for seed in seeds:
		for cx in range(-1, 3):
			for cy in range(-1, 3):
				for index in 2:
					var anchor := WorldGen.encounter_anchor(seed, cx, cy, index)
					assert_gte(anchor.length(), WorldGen.SAFE_RADIUS)
					var rect := WorldGen.inset_rect(cx, cy)
					var end := rect.position + rect.size
					assert_gte(anchor.x, rect.position.x - 0.001)
					assert_lte(anchor.x, end.x + 0.001)
					assert_gte(anchor.y, rect.position.y - 0.001)
					assert_lte(anchor.y, end.y + 0.001)


func test_t0_composition_is_a_pure_function_of_the_seed() -> void:
	var other := WorldGen.chunk_encounters(42, -4, 1)
	var first := WorldGen.chunk_encounters(42, 3, -2)
	var again := WorldGen.chunk_encounters(42, 3, -2)
	assert_eq(other.size(), 2)
	assert_eq(first.size(), 2)
	assert_eq(first[0].index, 0)
	assert_eq(first[1].index, 1)
	assert_eq(first[0].archetype_of(0), &"swarmer")
	assert_eq(first[1].archetype_of(0), &"drifter")
	var count := 8 + floori(WorldGen.hash_u(42, 3, -2, 0, "enc", "n") * 7.0)
	assert_eq(first[0].count_of(0), count)
	assert_eq(again[0].count_of(0), count)
	assert_almost_eq(again[0].anchor.x, first[0].anchor.x, 0.0001)
	assert_almost_eq(again[1].anchor.y, first[1].anchor.y, 0.0001)
	assert_eq(first[1].count_of(0), 3)
	assert_eq(first[0].points_spent, 3)
	assert_eq(first[1].points_spent, 3)
	assert_false(first[0].is_elite)
	assert_false(first[1].is_elite)
	assert_eq(first[0].rarity, 0)
	assert_eq(first[0].affix_ids.size(), 0)
	assert_eq(first[0].chunk, Vector2i(3, -2))
	var seeds: Array[int] = [1, 2, 42, 99]
	for seed in seeds:
		for cx in range(-2, 3):
			for cy in range(-2, 3):
				var rows := WorldGen.chunk_encounters(seed, cx, cy)
				assert_eq(rows.size(), 2)
				for row_index in rows.size():
					var row := rows[row_index]
					var roll := WorldGen.elite_roll(seed, cx, cy, row.index)
					if WorldGen.roll_is_elite(roll):
						assert_true(row.is_elite)
						assert_eq(row.archetype_of(0), &"drifter")
						assert_eq(row.count_of(0), 1)
					elif row.index == 0:
						assert_false(row.is_elite)
						assert_eq(row.archetype_of(0), &"swarmer")
						assert_between(row.count_of(0), 8, 14)
					else:
						assert_false(row.is_elite)
						assert_eq(row.archetype_of(0), &"drifter")
						assert_eq(row.count_of(0), 3)


func test_tier_1_chunks_spawn_nothing() -> void:
	assert_eq(WorldGen.chunk_encounters(1, 8, 0).size(), 0)
	assert_eq(WorldGen.chunk_encounters(42, -9, 4).size(), 0)
	assert_eq(WorldGen.chunk_encounters(1, 0, 8).size(), 0)
	assert_eq(WorldGen.chunk_encounters(1, 7, -8).size(), 2)


func test_herald_delay_matches_the_pinned_vectors() -> void:
	assert_eq(WorldGen.HERALD_DELAY_BASE, 58.0)
	assert_eq(WorldGen.HERALD_DELAY_SPAN, 20.0)
	assert_almost_eq(WorldGen.herald_delay(1), 65.7547, 1e-4)
	assert_almost_eq(WorldGen.herald_delay(1), 58.0 + 20.0 * 0.3877327727, 1e-9)
	assert_almost_eq(WorldGen.herald_delay(42), 75.3363, 1e-4)
	assert_almost_eq(WorldGen.herald_delay(42), 58.0 + 20.0 * 0.8668172005, 1e-9)
	# u = 0.8750332294 >= 0.5 → summoner. Seed 2 is the splitting side of the same rule.
	assert_eq(WorldGen.herald_affix(1), &"summoner")
	assert_eq(WorldGen.herald_affix(2), &"splitting")
	assert_eq(WorldGen.pick_uniform_affix(0.0, AffixCatalog.HERALD_AFFIXES), &"splitting")
	assert_eq(WorldGen.pick_uniform_affix(0.499999, AffixCatalog.HERALD_AFFIXES), &"splitting")
	assert_eq(WorldGen.pick_uniform_affix(0.5, AffixCatalog.HERALD_AFFIXES), &"summoner")
	var reversed: Array[StringName] = [&"summoner", &"splitting"]
	assert_eq(WorldGen.pick_uniform_affix(0.0, reversed), &"splitting")


func test_herald_delay_stays_inside_the_window_for_every_seed() -> void:
	for seed_value in range(0, 256):
		var u := WorldGen.hash_u(seed_value, "herald")
		var delay := WorldGen.herald_delay(seed_value)
		assert_gte(u, 0.0)
		assert_lt(u, 1.0)
		assert_almost_eq(delay, 58.0 + 20.0 * u, 1e-9)
		assert_gte(delay, 58.0)
		assert_lt(delay, 78.0)
		var affix := WorldGen.herald_affix(seed_value)
		var roll := WorldGen.hash_u(seed_value, "herald", "eaff")
		var expect: StringName = &"summoner" if roll >= 0.5 else &"splitting"
		assert_eq(affix, expect)
	# Closing 500 px at the player's 300 px/s still finishes inside 80 s of the arm.
	var close := (WorldGen.HERALD_AHEAD - WorldGen.WAKE_RADIUS) / 300.0
	assert_almost_eq(WorldGen.HERALD_AHEAD - WorldGen.WAKE_RADIUS, 500.0, 0.001)
	assert_almost_eq(close, 500.0 / 300.0, 0.001)
	assert_lt(close, 1.8)
	var samples: Array[int] = [1, 2, 42, 99, 255]
	for seed_value in samples:
		assert_lt(WorldGen.herald_delay(seed_value) + close, 80.0)


func test_herald_heading_and_clamp() -> void:
	var fast := WorldGen.herald_heading(Vector2(0, 40), Vector2.RIGHT)
	assert_almost_eq(fast.x, 0.0, 0.0001)
	assert_almost_eq(fast.y, 1.0, 0.0001)
	var slow := WorldGen.herald_heading(Vector2(19.9, 0), Vector2.UP)
	assert_almost_eq(slow.x, 0.0, 0.0001)
	assert_almost_eq(slow.y, -1.0, 0.0001)
	var exactly := WorldGen.herald_heading(Vector2(20, 0), Vector2.UP)
	assert_almost_eq(exactly.x, 1.0, 0.0001)
	assert_almost_eq(exactly.y, 0.0, 0.0001)
	assert_eq(WorldGen.herald_heading(Vector2.ZERO, Vector2.ZERO), Vector2.RIGHT)
	# Outward from the tier-0 edge lands on the inset square, still tier 0.
	var edge := WorldGen.clamp_herald_point(Vector2(17000, 0), Vector2.RIGHT)
	assert_almost_eq(edge.x, 16320.0, 0.01)
	assert_almost_eq(edge.y, 0.0, 0.01)
	assert_eq(WorldGen.tier_at(edge.x, edge.y), 0)
	# Heading back through the origin from just outside the disk is pushed to 512.
	var inner := WorldGen.clamp_herald_point(Vector2(700, 0), Vector2.LEFT)
	assert_almost_eq(inner.x, -512.0, 0.01)
	assert_almost_eq(inner.y, 0.0, 0.01)
	var ahead := WorldGen.clamp_herald_point(Vector2(600, 0), Vector2.RIGHT)
	assert_almost_eq(ahead.x, 1800.0, 0.01)
	assert_almost_eq(ahead.y, 0.0, 0.01)


func test_formation_slots_stay_outside_the_safe_zone() -> void:
	for i in 12:
		var pos := RegularEnemy.spawn_position(Vector2(520, 0), RegularEnemy.ARCH_SWARMER, i, 12)
		assert_gte(pos.length() - RegularEnemy.SWARMER_RADIUS, WorldGen.SAFE_RADIUS - 0.05)
