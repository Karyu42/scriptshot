extends GutTest
## Issue #81: the Summoner Herald soaked a straight stream. Design targets:
## at most 2 summons alive per common Summoner (rare column configurable, 8
## for room D), each summon dies to one hit, summons spawn at ±90° from the
## elite-to-player line and drift toward the player off the firing lane, and
## the wave cooldown is at least 4 s. Acceptance: the Straight starter
## (0.25 s, 480 px/s, 1 damage) at ~220 px while strafing kills the Herald in
## ≤ 25 s, and a spread kills it in ≤ 15 s.

const DT := 1.0 / 60.0
const FAR := Vector2(4000, 4000)
const STANDOFF := 220.0
const STRAFE_SPEED := 150.0
const STRAFE_FLIP := 1.5
const PLAYER_SPEED := 300.0
const MUZZLE := 20.0


## Mirrors scripting/starters/straight.lua (#79): one shot along the aim.
class StraightStarter extends ShotPattern:
	var _r := ShotRequest.new()

	func _init() -> void:
		fire_interval = 0.25

	func fire(c: ShotContext, e: ShotEmitter) -> void:
		_r.reset()
		_r.position = c.muzzle_position
		_r.velocity = c.aim_direction * 480.0
		_r.angle = c.aim_angle
		_r.lifetime = 2.0
		_r.radius = 4.0
		_r.damage = 1.0
		_r.color = Color.WHITE
		_r.owner_layer = Layers.PLAYER
		_r.hit_mask = c.target_mask
		e.request_shot(_r)


## Mirrors scripting/starters/spread.lua (#79): five shots, 0.16 rad apart.
class SpreadStarter extends ShotPattern:
	var _r := ShotRequest.new()

	func _init() -> void:
		fire_interval = 0.30

	func fire(c: ShotContext, e: ShotEmitter) -> void:
		for i in range(-2, 3):
			var a := c.aim_angle + float(i) * 0.16
			_r.reset()
			_r.position = c.muzzle_position
			_r.velocity = Vector2.from_angle(a) * 460.0
			_r.angle = a
			_r.lifetime = 2.0
			_r.radius = 4.0
			_r.damage = 2.0
			_r.color = Color.WHITE
			_r.owner_layer = Layers.PLAYER
			_r.hit_mask = c.target_mask
			e.request_shot(_r)


class SimResult:
	var kill_time := -1.0
	var summons_spawned := 0
	var max_alive := 0
	var summon_lane_frames := 0


func before_each() -> void:
	EliteCue.reset_budget()


func after_each() -> void:
	EliteCue.reset_budget()


func test_common_cap_is_two_and_rare_cap_comes_from_the_rare_column() -> void:
	var def := AffixCatalog.get_affix(AffixCatalog.SUMMONER)
	assert_eq(def.summon_cap(AffixDef.RARITY_COMMON), 2)
	assert_eq(def.summon_cap(AffixDef.RARITY_LEGENDARY), 6, "the Hydra keeps max 6 (vertical-slice §4)")
	assert_eq(def.summon_cap(AffixDef.RARITY_RARE), def.rare_max_alive)
	assert_eq(def.rare_max_alive, 8)
	var player := _node_player(FAR + Vector2(0, 300))
	var common := _elite(FAR, player)
	assert_eq(common.summon_cap(), 2)
	for _wave in 10:
		common._physics_process(common.summon_interval())
		assert_lte(common.summon_alive(), 2)
	assert_eq(common.summon_alive(), 2)
	var far_player := _node_player(-FAR + Vector2(0, 300))
	var rare := _elite(-FAR, far_player, AffixDef.RARITY_RARE)
	assert_eq(rare.summon_cap(), 8)
	assert_almost_eq(rare.summon_interval(), 4.0, 0.0001)
	for _wave in 10:
		rare._physics_process(rare.summon_interval())
		assert_lte(rare.summon_alive(), 8)
	assert_eq(rare.summon_alive(), 8)


func test_legendary_column_is_six_drifters_at_105_hp() -> void:
	# vertical-slice §4 and §10 row 12: every 6 s, 2 bodies, max 6 alive, each a
	# half-HP Drifter (105 HP, 90 px/s, radius 16), kind drifter.
	var def := AffixCatalog.get_affix(AffixCatalog.SUMMONER)
	assert_eq(def.summon_cap(AffixDef.RARITY_LEGENDARY), 6)
	assert_eq(def.summon_count(AffixDef.RARITY_LEGENDARY), 2)
	assert_almost_eq(def.summon_interval(AffixDef.RARITY_LEGENDARY), 6.0, 0.0001)
	assert_almost_eq(def.summon_hp_for(AffixDef.RARITY_LEGENDARY), 105.0, 0.0001)
	assert_eq(def.summon_kind(AffixDef.RARITY_LEGENDARY), RegularEnemy.ARCH_DRIFTER)
	assert_eq(def.summon_kind(AffixDef.RARITY_COMMON), RegularEnemy.ARCH_SWARMER)
	assert_eq(def.summon_kind(AffixDef.RARITY_RARE), RegularEnemy.ARCH_SWARMER)
	var player := _node_player(FAR + Vector2(0, 3000))
	var hydra := _elite(FAR, player, AffixDef.RARITY_LEGENDARY)
	assert_eq(hydra.summon_cap(), 6)
	assert_almost_eq(hydra.summon_interval(), 6.0, 0.0001)
	hydra._physics_process(5.9)
	assert_eq(hydra.summon_alive(), 0)
	hydra._physics_process(0.1)
	assert_eq(hydra.summon_alive(), 2, "2 per wave")
	for _wave in 6:
		hydra._physics_process(6.0)
		assert_lte(hydra.summon_alive(), 6)
	assert_eq(hydra.summon_alive(), 6)
	var adds := _adds(hydra.get_parent())
	assert_eq(adds.size(), 6)
	for add: SummonAdd in adds:
		assert_eq(add.archetype, RegularEnemy.ARCH_DRIFTER, "kind drifter")
		assert_almost_eq(add.health.max_hp, 105.0, 0.0001)
		assert_almost_eq(add.health.hp, 105.0, 0.0001)
		assert_almost_eq(add.body_radius, RegularEnemy.DRIFTER_RADIUS, 0.0001)
		assert_almost_eq(add._hurtbox.radius, RegularEnemy.DRIFTER_RADIUS, 0.0001)
		assert_almost_eq(add._move_speed(), RegularEnemy.DRIFTER_SPEED, 0.0001)
		assert_false(add.holds_flank)
		assert_false(add.is_in_group(EliteEnemy.GROUP_ELITE))
	# A woken Hydra add chases straight at the player like a Drifter.
	var add := adds[0]
	add.woken = true
	player.global_position = add.global_position + Vector2(500, 0)
	var x0 := add.global_position.x
	add._physics_process(1.0)
	assert_almost_eq(add.global_position.x - x0, RegularEnemy.DRIFTER_SPEED, 0.5)
	assert_almost_eq(add.global_position.y, player.global_position.y, 0.5)
	# 105 HP: a 1-damage stream needs 105 hits. Later waves jitter off the
	# first flank points, but still clear the other adds out of the line first.
	for other: SummonAdd in adds:
		if other != add:
			other.health.damage(other.health.max_hp)
	var manager := _manager()
	assert_eq(_shots_to_kill_up_to(manager, add, BasicShot.new(), 200), 105)


func test_rare_column_is_configurable() -> void:
	var def := AffixDef.new()
	def.interval = 6.0
	def.count = 2
	def.max_alive = 2
	assert_eq(def.summon_cap(AffixDef.RARITY_RARE), 2, "an empty rare column falls back to common")
	def.rare_max_alive = 5
	def.rare_interval = 4.5
	def.rare_count = 3
	assert_eq(def.summon_cap(AffixDef.RARITY_RARE), 5)
	assert_eq(def.summon_count(AffixDef.RARITY_RARE), 3)
	assert_almost_eq(def.summon_interval(AffixDef.RARITY_RARE), 4.5, 0.0001)
	assert_eq(def.summon_cap(AffixDef.RARITY_COMMON), 2)


func test_each_summon_dies_to_one_hit() -> void:
	var player := _node_player(FAR + Vector2(0, 300))
	var elite := _elite(FAR, player)
	elite._physics_process(elite.summon_interval())
	var adds := _adds(elite.get_parent())
	assert_eq(adds.size(), 2)
	var manager := _manager()
	for shot: ShotPattern in [BasicShot.new(), StraightStarter.new()]:
		elite._physics_process(elite.summon_interval())
		for add: SummonAdd in _adds(elite.get_parent()):
			assert_almost_eq(add.health.max_hp, 1.0, 0.0001)
			assert_eq(_shots_to_kill(manager, add, shot), 1, "one hit kills a summon")


func test_summons_spawn_on_both_flanks_at_ninety_degrees() -> void:
	var player := _node_player(FAR + Vector2(300, 0))
	var elite := _elite(FAR, player)
	var half_arc := rad_to_deg(EliteEnemy.SUMMON_FLANK_ARC) * 0.5
	for dir: Vector2 in [Vector2.RIGHT, Vector2(0.6, 0.8), Vector2.LEFT, Vector2(-0.28, -0.96)]:
		player.global_position = elite.global_position + dir * 300.0
		_kill_all(elite.get_parent())
		elite._physics_process(elite.summon_interval())
		var adds := _adds(elite.get_parent())
		assert_eq(adds.size(), 2)
		var sides: Array[float] = []
		for add: SummonAdd in adds:
			var off := add.global_position - elite.global_position
			assert_almost_eq(off.length(), EliteEnemy.SUMMON_OFFSET, 0.01)
			var angle := rad_to_deg(dir.angle_to(off))
			assert_gte(absf(angle), 90.0 - half_arc - 0.01, "summon at %.1f° from the elite-to-player line" % angle)
			assert_lte(absf(angle), 90.0 + half_arc + 0.01, "summon at %.1f° from the elite-to-player line" % angle)
			sides.append(signf(angle))
			assert_eq(add.summoner, elite)
		assert_ne(sides[0], sides[1], "one summon on each flank")


## vertical-slice §4 / §10 row 12: a wave jitters across the flank arc, and
## the roll is WorldGen.hash_u so a test can recompute it from the seed.
func test_summon_wave_jitter_stays_within_the_flank_arc() -> void:
	var player := _node_player(FAR + Vector2(3000, 0))
	var hydra := _elite(FAR, player, AffixDef.RARITY_LEGENDARY)
	hydra.set_physics_process(false)
	var dir := Vector2.RIGHT
	player.global_position = hydra.global_position + dir * 3000.0
	# Tick the summoner only, so idle drift does not walk the body off the spawn.
	for _wave in 3:
		hydra._summon_wait = 0.0
		hydra._tick_summon(0.0)
	var adds := _adds(hydra.get_parent())
	assert_eq(adds.size(), 6)
	var half := EliteEnemy.SUMMON_FLANK_ARC * 0.5
	for i in adds.size():
		var add: SummonAdd = hydra._summons[i]
		var expected_jitter := EliteEnemy.summon_flank_jitter_for(
			hydra.world_seed, hydra.chunk, hydra.encounter_index, add.member_index
		)
		assert_eq(add.member_index, i)
		assert_almost_eq(hydra.summon_flank_jitter(i), expected_jitter, 0.0000001)
		assert_gte(expected_jitter, -half)
		assert_lte(expected_jitter, half)
		var expected := hydra.summon_spawn_point(
			1.0 if i % 2 == 0 else -1.0, expected_jitter
		)
		assert_almost_eq(add.global_position.x, expected.x, 0.01)
		assert_almost_eq(add.global_position.y, expected.y, 0.01)
		var angle := dir.angle_to(add.global_position - hydra.global_position)
		assert_gte(absf(angle), PI * 0.5 - half - 0.001)
		assert_lte(absf(angle), PI * 0.5 + half + 0.001)
		assert_almost_eq(
			(add.global_position - hydra.global_position).length(),
			EliteEnemy.SUMMON_OFFSET,
			0.01
		)


func test_summon_wave_jitter_differs_between_waves_and_is_seedable() -> void:
	var player := _node_player(FAR + Vector2(3000, 0))
	var hydra := _elite(FAR, player, AffixDef.RARITY_LEGENDARY)
	hydra.set_physics_process(false)
	player.global_position = hydra.global_position + Vector2.RIGHT * 3000.0
	for _wave in 3:
		hydra._summon_wait = 0.0
		hydra._tick_summon(0.0)
	assert_eq(hydra.summon_alive(), 6)
	# Same flank, later wave: not the same point.
	for side_index in 2:
		var a: Vector2 = hydra._summons[side_index].global_position
		var b: Vector2 = hydra._summons[side_index + 2].global_position
		var c: Vector2 = hydra._summons[side_index + 4].global_position
		assert_gt(a.distance_to(b), 0.01, "wave 1 and 2 share a flank point")
		assert_gt(a.distance_to(c), 0.01, "wave 1 and 3 share a flank point")
		assert_gt(b.distance_to(c), 0.01, "wave 2 and 3 share a flank point")
	# Same seed, chunk, encounter, and serial: same offset.
	var again := EliteEnemy.summon_flank_jitter_for(
		hydra.world_seed, hydra.chunk, hydra.encounter_index, 0
	)
	assert_almost_eq(again, hydra.summon_flank_jitter(0), 0.0000001)
	# A second Hydra with the same seed lands on the same points.
	# Same spawn point so chunk_of matches (encounter_index is -1, so chunk is from spawn).
	var twin := _elite(FAR, player, AffixDef.RARITY_LEGENDARY)
	twin.set_physics_process(false)
	player.global_position = twin.global_position + Vector2.RIGHT * 3000.0
	twin._summon_wait = 0.0
	twin._tick_summon(0.0)
	for i in 2:
		var first: Vector2 = hydra._summons[i].global_position - hydra.global_position
		var copy: Vector2 = twin._summons[i].global_position - twin.global_position
		assert_almost_eq(first.x, copy.x, 0.01)
		assert_almost_eq(first.y, copy.y, 0.01)
	# A different seed must be able to move the first spawn (hash_u is not
	# constant across seeds).
	var other := EliteEnemy.summon_flank_jitter_for(2, Vector2i.ZERO, -1, 0)
	assert_true(
		other != hydra.summon_flank_jitter(0)
		or EliteEnemy.summon_flank_jitter_for(3, Vector2i.ZERO, -1, 0)
		!= hydra.summon_flank_jitter(0)
	)


func test_the_same_seed_gives_identical_summon_angles_across_two_runs() -> void:
	# The jitter is WorldGen.hash_u(world_seed, chunk, encounter, serial),
	# not the runtime RNG, so two independent runs with the same seed match.
	var seed := 1
	var chunk := Vector2i(3, -2)
	var encounter := 4
	var player := _node_player(FAR + Vector2(3000, 0))
	var first := _summon_angles_for_seed(seed, chunk, encounter, player)
	var second := _summon_angles_for_seed(seed, chunk, encounter, player)
	assert_eq(first.size(), 6)
	assert_eq(second.size(), 6)
	for i in first.size():
		assert_almost_eq(first[i], second[i], 0.0000001, "serial %d angle" % i)


func test_a_wall_on_the_flank_slides_the_summon_inward_without_rerolling_the_angle() -> void:
	# Alcove east wall inner face is at x = 8128 - 16 = 8112. Stand 48 px
	# west of that face so the unobstructed east spawn sits in the wall.
	var layout := SliceLayout.new()
	add_child_autofree(layout)
	var at := Vector2(8112.0 - EliteEnemy.SUMMON_OFFSET, 1152.0)
	var player := _node_player(at + Vector2(0, 3000))
	var hydra := _elite(at, player, AffixDef.RARITY_LEGENDARY)
	hydra.set_physics_process(false)
	player.global_position = hydra.global_position + Vector2(0, 3000)
	var add_radius := RegularEnemy.radius_of(RegularEnemy.ARCH_DRIFTER)
	# Odd serial is the right/east flank, which hits the wall. Even stays clear.
	var east_jitter := hydra.summon_flank_jitter(1)
	var dir := hydra.summon_flank_dir(-1.0, east_jitter)
	var unobstructed := hydra.global_position + dir * EliteEnemy.SUMMON_OFFSET
	assert_true(
		layout.touches_wall(unobstructed, add_radius),
		"the 48 px flank point overlaps the wall"
	)
	var slid := hydra.summon_spawn_point(-1.0, east_jitter)
	var off := slid - hydra.global_position
	assert_almost_eq(off.angle(), dir.angle(), 0.0001, "the angle is not re-rolled")
	assert_gt(unobstructed.distance_to(slid), 0.01, "the spawn slid inward")
	assert_lt(off.length(), EliteEnemy.SUMMON_OFFSET - 0.01)
	assert_gte(off.length(), hydra.body_radius - 0.01, "not closer than the elite edge")
	assert_false(layout.touches_wall(slid, add_radius), "the slid point is clear")
	var west := hydra.summon_spawn_point(1.0, hydra.summon_flank_jitter(0))
	assert_almost_eq(
		(west - hydra.global_position).length(),
		EliteEnemy.SUMMON_OFFSET,
		0.01,
		"a clear flank stays at 48 px"
	)
	# A live spawn must land on the slid point (the alcove is far from the
	# safe disk, so push_centre_outside does not move it). Spawn one add
	# so the legendary batch of 2 does not also drop the clear flank.
	hydra._summon_serial = 1
	hydra._spawn_one_summon()
	assert_eq(hydra.summon_alive(), 1)
	var add: SummonAdd = hydra._summons[0]
	assert_almost_eq(add.global_position.x, slid.x, 0.01)
	assert_almost_eq(add.global_position.y, slid.y, 0.01)


func test_a_thin_wall_on_the_ray_does_not_leave_the_summon_on_the_far_side() -> void:
	# QA probe: elite at (8104, 1152). The alcove east wall is 16 px thick
	# (inner face 8112, outer 8128). The unslid east 48 px point (8152,
	# 1152) is clear — a r=16 circle starts at 8136, past the wall — but
	# the ray crosses the wall. The spawn must stay on the near side, at
	# the same angle, and must not accept the far-side point. The elite
	# edge itself sits in the wall, so the near-side result is the edge.
	var layout := SliceLayout.new()
	add_child_autofree(layout)
	var at := Vector2(8104.0, 1152.0)
	var player := _node_player(at + Vector2(0, 3000))
	var hydra := _elite(at, player, AffixDef.RARITY_LEGENDARY)
	hydra.set_physics_process(false)
	player.global_position = hydra.global_position + Vector2(0, 3000)
	var add_radius := RegularEnemy.radius_of(RegularEnemy.ARCH_DRIFTER)
	var dir := Vector2.RIGHT
	var unobstructed := hydra.global_position + dir * EliteEnemy.SUMMON_OFFSET
	assert_almost_eq(unobstructed.x, 8152.0, 0.01)
	assert_almost_eq(unobstructed.y, 1152.0, 0.01)
	assert_false(
		layout.touches_wall(unobstructed, add_radius),
		"the far-side 48 px point is clear of the wall"
	)
	assert_true(
		layout.touches_wall(hydra.global_position + dir * 24.0, add_radius),
		"the ray itself crosses the wall"
	)
	var slid := hydra._slide_summon_inward(unobstructed, dir)
	var off := slid - hydra.global_position
	assert_almost_eq(off.angle(), dir.angle(), 0.0001, "the angle is not re-rolled")
	assert_gt(unobstructed.distance_to(slid), 0.01, "the spawn did not stay on the far side")
	assert_lte(slid.x, 8128.0, "the spawn did not tunnel past the east wall")
	assert_gte(off.length(), hydra.body_radius - 0.01, "not closer than the elite edge")
	# The elite edge (8104+16=8120) is inside the wall, so the near side
	# has no clear point: return the edge rather than the far side.
	assert_almost_eq(off.length(), hydra.body_radius, 0.01)
	assert_almost_eq(slid.x, 8120.0, 0.01)
	assert_almost_eq(slid.y, 1152.0, 0.01)


func _summon_angles_for_seed(
	seed: int, chunk: Vector2i, encounter: int, player: Node2D
) -> Array[float]:
	var hydra := _elite(FAR, player, AffixDef.RARITY_LEGENDARY)
	hydra.world_seed = seed
	hydra.chunk = chunk
	hydra.encounter_index = encounter
	hydra.set_physics_process(false)
	player.global_position = hydra.global_position + Vector2.RIGHT * 3000.0
	for _wave in 3:
		hydra._summon_wait = 0.0
		hydra._tick_summon(0.0)
	var out: Array[float] = []
	var dir := Vector2.RIGHT
	for add: SummonAdd in hydra._summons:
		out.append(dir.angle_to(add.global_position - hydra.global_position))
	return out


func test_cooldown_is_at_least_four_seconds() -> void:
	var def := AffixCatalog.get_affix(AffixCatalog.SUMMONER)
	assert_gte(def.summon_interval(AffixDef.RARITY_COMMON), 4.0)
	assert_gte(def.summon_interval(AffixDef.RARITY_RARE), 4.0)
	for rarity: int in [AffixDef.RARITY_COMMON, AffixDef.RARITY_RARE]:
		var at := FAR if rarity == AffixDef.RARITY_COMMON else -FAR
		var player := _node_player(at + Vector2(0, 300))
		var elite := _elite(at, player, rarity)
		var waves: Array[float] = []
		var t := 0.0
		var spawned := 0
		while t < 40.0:
			elite._physics_process(DT)
			t += DT
			var serial := elite._summon_serial
			if serial > spawned:
				waves.append(t)
				spawned = serial
				# Kill the wave at once: room alone must not bring the next one early.
				_kill_all(elite.get_parent())
		assert_gte(waves.size(), 2)
		assert_gte(waves[0], 4.0 - 0.001, "no wave in the first 4 s")
		for i in range(1, waves.size()):
			assert_gte(waves[i] - waves[i - 1], 4.0 - 0.001, "waves %d and %d" % [i - 1, i])


func test_summons_hold_their_flank_offset_and_stay_out_of_the_lane() -> void:
	# Common Swarmers hold at their spawn offset relative to the elite
	# (per-serial hashed angle + wall-slide radius), tracking the
	# elite-to-player facing. They stay off the firing lane and do not
	# have to reach the player.
	var player := _node_player(FAR + Vector2(STANDOFF, 0))
	var elite := _elite(FAR, player)
	elite.woken = true
	elite.set_physics_process(false)
	elite._physics_process(elite.summon_interval())
	var adds := _adds(elite.get_parent())
	assert_eq(adds.size(), 2)
	for add: SummonAdd in adds:
		add.set_physics_process(false)
		assert_almost_eq(add.flank_jitter, elite.summon_flank_jitter(add.member_index), 0.0000001)
		assert_almost_eq(add.flank_hold_radius, EliteEnemy.SUMMON_OFFSET, 0.01)
	for frame in 300:
		for add: SummonAdd in adds:
			add._physics_process(DT)
			var muzzle := player.global_position + (elite.global_position - player.global_position).normalized() * MUZZLE
			var lane := _segment_distance(add.global_position, muzzle, elite.global_position)
			assert_gt(lane, add.body_radius + 4.0, "frame %d: %s is in the firing lane" % [frame, add.name])
	var holds: Array[Vector2] = []
	for add: SummonAdd in adds:
		var hold := add.flank_point()
		holds.append(hold)
		assert_lt(
			add.global_position.distance_to(hold),
			0.5,
			"%s left its own hold point" % add.name
		)
		# The hold equals the spawn offset, recomputed from current facing.
		var expected := elite.global_position + elite.summon_flank_dir(add.side, add.flank_jitter) * add.flank_hold_radius
		assert_almost_eq(hold.x, expected.x, 0.01)
		assert_almost_eq(hold.y, expected.y, 0.01)
	assert_gt(holds[0].distance_to(holds[1]), 0.01, "both adds share a hold point")


func test_rare_flank_adds_keep_distinct_hold_points_at_the_cap() -> void:
	# At a rare cap of 8, after 5 s, each Swarmer add still holds at its
	# own spawn offset rather than stacking on one flank_point per side.
	# Four r=8 Swarmers can still overlap on a 40° / 48 px arc (~33 px);
	# that is a Game Designer reading, not a reason to widen the arc.
	var player := _node_player(FAR + Vector2(3000, 0))
	var rare := _elite(FAR, player, AffixDef.RARITY_RARE)
	rare.woken = true
	rare.set_physics_process(false)
	player.global_position = rare.global_position + Vector2.RIGHT * 3000.0
	while rare.summon_alive() < rare.summon_cap():
		rare._summon_wait = 0.0
		rare._tick_summon(0.0)
	assert_eq(rare.summon_alive(), 8)
	var adds := _adds(rare.get_parent())
	assert_eq(adds.size(), 8)
	for add: SummonAdd in adds:
		add.set_physics_process(false)
		add.woken = true
	for _frame in 300:
		for add: SummonAdd in adds:
			add._physics_process(DT)
	var left: Array[Vector2] = []
	var right: Array[Vector2] = []
	for add: SummonAdd in adds:
		var hold := add.flank_point()
		assert_lt(
			add.global_position.distance_to(hold),
			0.5,
			"%s left its own hold point" % add.name
		)
		assert_almost_eq(add.flank_jitter, rare.summon_flank_jitter(add.member_index), 0.0000001)
		if add.side > 0.0:
			left.append(hold)
		else:
			right.append(hold)
	assert_eq(left.size(), 4)
	assert_eq(right.size(), 4)
	_assert_side_holds_are_spread(left, "left")
	_assert_side_holds_are_spread(right, "right")


func _assert_side_holds_are_spread(holds: Array[Vector2], label: String) -> void:
	var min_d := INF
	for i in holds.size():
		for j in range(i + 1, holds.size()):
			var d := holds[i].distance_to(holds[j])
			assert_gt(d, 0.01, "%s holds %d and %d stack (%.4f px)" % [label, i, j, d])
			min_d = minf(min_d, d)
	assert_gt(min_d, 0.01, "%s hold points are not distinct" % label)


func test_straight_starter_strafing_at_220_kills_the_herald_within_25_s() -> void:
	var result := _timed_kill(StraightStarter.new(), true, 40.0)
	gut.p("Straight 0.25 s @ 220 px, strafing: %.2f s, %d summons, max %d alive" % [
		result.kill_time, result.summons_spawned, result.max_alive
	])
	assert_gt(result.kill_time, 0.0, "the Herald died")
	assert_lte(result.kill_time, 25.0)
	assert_lte(result.max_alive, 2)
	assert_gt(result.summons_spawned, 0, "the Summoner did summon during the fight")


func test_straight_starter_standing_at_220_kills_the_herald_within_25_s() -> void:
	var result := _timed_kill(StraightStarter.new(), false, 40.0)
	gut.p("Straight 0.25 s @ 220 px, holding: %.2f s" % result.kill_time)
	assert_gt(result.kill_time, 0.0)
	assert_lte(result.kill_time, 25.0)


func test_spread_strafing_at_220_kills_the_herald_within_15_s() -> void:
	var result := _timed_kill(SpreadStarter.new(), true, 30.0)
	gut.p("Spread 0.30 s @ 220 px, strafing: %.2f s, %d summons" % [result.kill_time, result.summons_spawned])
	assert_gt(result.kill_time, 0.0)
	assert_lte(result.kill_time, 15.0)


func test_basic_shot_strafing_at_220_still_kills_quickly() -> void:
	var result := _timed_kill(BasicShot.new(), true, 30.0)
	gut.p("BasicShot 0.11 s @ 220 px, strafing: %.2f s" % result.kill_time)
	assert_gt(result.kill_time, 0.0)
	assert_lte(result.kill_time, 15.0)


## Headless fight: the Herald (common Summoner, woken) chases a player that
## holds ~220 px, strafes tangentially at 150 px/s (flipping every 1.5 s) when
## `strafe`, aims at the Herald's centre and fires `shot` on its interval. The
## player is a plain Node2D, so contact does no damage and the player never dies.
func _timed_kill(shot: ShotPattern, strafe: bool, limit: float) -> SimResult:
	var result := SimResult.new()
	var manager := _manager()
	var at := FAR
	var player := _node_player(at + Vector2(-STANDOFF, 0))
	var elite := _elite(at, player)
	elite.woken = true
	var holder := elite.get_parent()
	var ctx := ShotContext.new()
	ctx.target_mask = Layers.ENEMY
	var t := 0.0
	var cooldown := 0.0
	var side := 1.0
	var flip := 0.0
	var seen: Dictionary[int, bool] = {}
	while t < limit:
		var gap := elite.global_position - player.global_position
		var dist := gap.length()
		var move := Vector2.ZERO
		if dist > 0.001:
			var radial := gap / dist
			if dist < STANDOFF - 10.0:
				move -= radial
			elif dist > STANDOFF + 10.0:
				move += radial
			if strafe:
				move += Vector2(-radial.y, radial.x) * side * (STRAFE_SPEED / PLAYER_SPEED)
		var velocity := move.limit_length(1.0) * PLAYER_SPEED
		player.global_position += velocity * DT
		flip += DT
		if flip >= STRAFE_FLIP:
			flip = 0.0
			side = -side
		elite._physics_process(DT)
		var alive := 0
		for child: Node in holder.get_children():
			var add := child as SummonAdd
			if add == null:
				continue
			if not seen.has(add.get_instance_id()):
				seen[add.get_instance_id()] = true
				result.summons_spawned += 1
			if add.is_alive():
				alive += 1
				add._physics_process(DT)
		result.max_alive = maxi(result.max_alive, alive)
		var aim := elite.global_position - player.global_position
		aim = Vector2.RIGHT if aim.length_squared() < 0.0001 else aim.normalized()
		cooldown -= DT
		if cooldown <= 0.0:
			ctx.muzzle_position = player.global_position + aim * MUZZLE
			ctx.aim_direction = aim
			ctx.aim_angle = aim.angle()
			ctx.shooter_velocity = velocity
			shot.fire(ctx, manager.emitter)
			cooldown += shot.fire_interval
		manager.step(DT)
		t += DT
		if not elite.is_alive():
			result.kill_time = t
			break
	return result


func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var u := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.000001), 0.0, 1.0)
	return (a + ab * u).distance_to(p)


func _manager() -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.world_bounds = Rect2(-8000, -8000, 16000, 16000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	return manager


func _node_player(at: Vector2) -> Node2D:
	var player := Node2D.new()
	player.position = at
	add_child_autofree(player)
	return player


func _elite(at: Vector2, player: Node2D, rarity: int = AffixDef.RARITY_COMMON) -> EliteEnemy:
	var holder := Node2D.new()
	add_child_autofree(holder)
	var elite := (preload("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.configure_elite(AffixCatalog.SUMMONER, at, at, 1, player, true, false, Vector2i.ZERO, -1, rarity)
	holder.add_child(elite)
	return elite


func _adds(parent: Node) -> Array[SummonAdd]:
	var out: Array[SummonAdd] = []
	for child: Node in parent.get_children():
		var add := child as SummonAdd
		if add != null and add.is_alive():
			out.append(add)
	return out


func _kill_all(parent: Node) -> void:
	for add: SummonAdd in _adds(parent):
		add.health.damage(add.health.max_hp)


func _shots_to_kill(manager: BulletManager, enemy: RegularEnemy, shot: ShotPattern) -> int:
	return _shots_to_kill_up_to(manager, enemy, shot, 20)


func _shots_to_kill_up_to(manager: BulletManager, enemy: RegularEnemy, shot: ShotPattern, limit: int) -> int:
	var ctx := ShotContext.new()
	ctx.aim_direction = Vector2.RIGHT
	ctx.aim_angle = 0.0
	ctx.shooter_velocity = Vector2.ZERO
	ctx.target_mask = Layers.ENEMY
	var n := 0
	while enemy.is_alive() and n < limit:
		ctx.muzzle_position = enemy.global_position + Vector2(-6.0, 0.0)
		shot.fire(ctx, manager.emitter)
		manager.step(DT)
		n += 1
	return n
