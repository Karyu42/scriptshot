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
	assert_eq(def.summon_cap(AffixDef.RARITY_LEGENDARY), 2, "legendary uses the common numbers")
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
			assert_almost_eq(absf(angle), 90.0, 0.5, "summon at %.1f° from the elite-to-player line" % angle)
			sides.append(signf(angle))
			assert_eq(add.summoner, elite)
		assert_ne(sides[0], sides[1], "one summon on each flank")


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


func test_summons_drift_to_the_player_and_stay_out_of_the_lane() -> void:
	var player := _node_player(FAR + Vector2(STANDOFF, 0))
	var elite := _elite(FAR, player)
	elite.woken = true
	elite.set_physics_process(false)
	elite._physics_process(elite.summon_interval())
	var adds := _adds(elite.get_parent())
	assert_eq(adds.size(), 2)
	var start: Array[float] = []
	for add: SummonAdd in adds:
		add.set_physics_process(false)
		start.append(add.global_position.distance_to(player.global_position))
	for frame in 300:
		for add: SummonAdd in adds:
			add._physics_process(DT)
			var muzzle := player.global_position + (elite.global_position - player.global_position).normalized() * MUZZLE
			var lane := _segment_distance(add.global_position, muzzle, elite.global_position)
			assert_gt(lane, add.body_radius + 4.0, "frame %d: %s is in the firing lane" % [frame, add.name])
	for i in adds.size():
		var d := adds[i].global_position.distance_to(player.global_position)
		assert_lt(d, start[i], "%s drifted toward the player" % adds[i].name)
		assert_lte(d, RegularEnemy.PLAYER_RADIUS + adds[i].body_radius, "%s reached contact range" % adds[i].name)


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
	var ctx := ShotContext.new()
	ctx.aim_direction = Vector2.RIGHT
	ctx.aim_angle = 0.0
	ctx.shooter_velocity = Vector2.ZERO
	ctx.target_mask = Layers.ENEMY
	var n := 0
	while enemy.is_alive() and n < 20:
		ctx.muzzle_position = enemy.global_position + Vector2(-6.0, 0.0)
		shot.fire(ctx, manager.emitter)
		manager.step(DT)
		n += 1
	return n
