extends GutTest
## Issue #81 / GD rule: no encounter anchor (regular pack or natural elite)
## within WorldGen.HERALD_PACK_CLEARANCE (800 px) of a Herald spawn point. The
## point is chosen, packs are never moved: WorldGen.herald_point searches
## candidates in a fixed order and is a pure function of seed, position and
## heading.

const SEEDS := 120


func test_no_anchor_within_800_px_across_seeds() -> void:
	var kept := 0
	var cases := 0
	for seed_value in SEEDS:
		for k in 2:
			var pos := Vector2(600, 0)
			var heading := Vector2.RIGHT
			if k == 1:
				var u := WorldGen.hash_u(seed_value, "clear_test", "pos")
				var v := WorldGen.hash_u(seed_value, "clear_test", "dist")
				pos = Vector2.from_angle(u * TAU) * (600.0 + v * 12000.0)
				heading = Vector2.from_angle(WorldGen.hash_u(seed_value, "clear_test", "head") * TAU)
			cases += 1
			var point := WorldGen.herald_point(seed_value, pos, heading, RegularEnemy.DRIFTER_RADIUS)
			var nearest := WorldGen.nearest_anchor_distance(seed_value, point, 4000.0)
			assert_gte(nearest, WorldGen.HERALD_PACK_CLEARANCE, "seed %d case %d: anchor %.0f px from %s" % [seed_value, k, nearest, point])
			assert_gte(point.length(), WorldGen.SAFE_RADIUS + RegularEnemy.DRIFTER_RADIUS - 0.01)
			assert_eq(WorldGen.tier_at(point.x, point.y), 0)
			var first := WorldGen.herald_candidates(pos, heading, RegularEnemy.DRIFTER_RADIUS)[0]
			if WorldGen.herald_point_is_clear(seed_value, first):
				assert_eq(point, first, "a clear heading point is kept")
				kept += 1
	gut.p("%d cases, %d kept the heading point" % [cases, kept])


func test_deterministic_per_seed() -> void:
	for seed_value: int in [1, 7, 42]:
		var a := WorldGen.herald_point(seed_value, Vector2(600, 0), Vector2.RIGHT, 16.0)
		var b := WorldGen.herald_point(seed_value, Vector2(600, 0), Vector2.RIGHT, 16.0)
		assert_eq(a, b)


func test_seed_one_moves_off_the_chunk_0_m1_pack() -> void:
	var pack := WorldGen.chunk_encounters(1, 0, -1)[0]
	assert_false(pack.is_elite)
	assert_eq(pack.archetype_of(0), &"swarmer")
	assert_lt(pack.anchor.distance_to(Vector2(1800, 0)), 800.0)
	var point := WorldGen.herald_point(1, Vector2(600, 0), Vector2.RIGHT, 16.0)
	assert_gte(pack.anchor.distance_to(point), 800.0)
	assert_almost_eq(point.distance_to(Vector2(600, 0)), WorldGen.HERALD_AHEAD, 0.5, "same distance, turned heading")


func test_candidates_start_at_the_heading_point_and_stay_in_tier_zero() -> void:
	var c := WorldGen.herald_candidates(Vector2(600, 0), Vector2.RIGHT)
	assert_eq(c[0], WorldGen.clamp_herald_point(Vector2(600, 0), Vector2.RIGHT))
	assert_eq(c[0], Vector2(1800, 0))
	assert_almost_eq(c[1].distance_to(Vector2(600, 0)), 1200.0, 0.01)
	assert_almost_eq(rad_to_deg(Vector2.RIGHT.angle_to(c[1] - Vector2(600, 0))), WorldGen.HERALD_TURN_STEP_DEG, 0.01)
	for p: Vector2 in WorldGen.herald_candidates(Vector2(16200, 40), Vector2.RIGHT, 16.0):
		assert_lt(maxf(absf(p.x), absf(p.y)), float(WorldGen.TIER_PX))
		assert_gte(p.length(), WorldGen.SAFE_RADIUS + 16.0 - 0.01)


func test_pick_reuses_for_a_caller_supplied_point_list() -> void:
	# The vertical-slice redirect (row 6) brings its own point(s).
	var blocked := WorldGen.chunk_encounters(1, 0, -1)[0].anchor + Vector2(10, 0)
	var clear := WorldGen.herald_point(1, Vector2(600, 0), Vector2.RIGHT)
	assert_false(WorldGen.herald_point_is_clear(1, blocked))
	assert_true(WorldGen.herald_point_is_clear(1, clear))
	var list: Array[Vector2] = [blocked, clear]
	assert_eq(WorldGen.pick_herald_point(1, list), clear)
	# Nothing clear: the candidate whose nearest anchor is farthest.
	var near := WorldGen.chunk_encounters(1, 0, -1)[0].anchor + Vector2(5, 0)
	var less := WorldGen.chunk_encounters(1, 0, -1)[0].anchor + Vector2(300, 0)
	var none: Array[Vector2] = [near, less]
	var gap_near := WorldGen.nearest_anchor_distance(1, near, 800.0)
	var gap_less := WorldGen.nearest_anchor_distance(1, less, 800.0)
	assert_eq(WorldGen.pick_herald_point(1, none), less if gap_less > gap_near else near)
