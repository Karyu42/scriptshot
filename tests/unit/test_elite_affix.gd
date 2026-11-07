extends GutTest
## Splitting and Summoner on the Herald body. Both die to an unmodified BasicShot.
## Halves and summons are not elites, drop nothing, and stay outside the safe disk.

const DT := 1.0 / 60.0
const FAR := Vector2(4000, 4000)


func before_each() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	Input.action_release("move_up")
	Input.action_release("move_down")
	Input.action_release("fire")
	EliteCue.reset_budget()


func after_each() -> void:
	EliteCue.reset_budget()
	EliteCue.pulse_enabled = true


func test_affix_resources_match_the_common_row() -> void:
	var splitting := AffixCatalog.get_affix(AffixCatalog.SPLITTING)
	assert_eq(splitting.id, &"splitting")
	assert_eq(splitting.group, AffixDef.GROUP_SPAWN)
	assert_eq(splitting.min_tier, 0)
	assert_eq(splitting.halves, 2)
	assert_almost_eq(splitting.hp_fraction, 0.4, 0.0001)
	assert_almost_eq(splitting.speed_mul, 1.3, 0.0001)
	assert_false(splitting.resplit)
	var summoner := AffixCatalog.get_affix(AffixCatalog.SUMMONER)
	assert_eq(summoner.id, &"summoner")
	assert_eq(summoner.group, AffixDef.GROUP_SPAWN)
	assert_almost_eq(summoner.interval, 6.0, 0.0001)
	assert_eq(summoner.count, 2)
	assert_eq(summoner.max_alive, 6)
	assert_false(summoner.drop)
	assert_false(AffixCatalog.allows_pair(AffixCatalog.SPLITTING, AffixCatalog.SUMMONER))
	assert_false(AffixCatalog.allows_pair(AffixCatalog.SUMMONER, AffixCatalog.SPLITTING))
	assert_true(AffixCatalog.allows_pair(AffixCatalog.SPLITTING, &"bulwark"))
	assert_almost_eq(EliteEnemy.ELITE_HP, RegularEnemy.DRIFTER_HP * 1.0 * 2.5, 0.001)
	assert_almost_eq(EliteEnemy.ELITE_HP, 75.0, 0.001)


func test_splitting_dies_to_basic_shot_and_leaves_two_halves() -> void:
	var manager := _manager()
	var player := _node_player(FAR + Vector2(0, 2500))
	var elite := _elite(AffixCatalog.SPLITTING, FAR, player)
	assert_almost_eq(elite.health.hp, 75.0, 0.01)
	assert_eq(elite.outline_width(), EliteCue.OUTLINE_WIDTH)
	assert_eq(_shots_to_kill(manager, elite), 75)
	assert_false(elite.is_alive())
	var halves := _halves(elite.get_parent())
	assert_eq(halves.size(), 2)
	for half: EliteEnemy in halves:
		assert_true(half.is_half)
		assert_false(half.is_herald)
		assert_false(half.grants_shard)
		assert_null(half.cue)
		assert_null(half.sting)
		assert_true(half.woken)
		assert_false(half.is_in_group(EliteEnemy.GROUP_ELITE))
		assert_true(half.is_in_group(RegularEnemy.GROUP))
		assert_eq(half.outline_width(), RegularEnemy.OUTLINE_WIDTH)
		assert_almost_eq(half.body_radius, EliteEnemy.HALF_RADIUS, 0.001)
		assert_almost_eq(half.health.hp, 30.0, 0.01)
		assert_almost_eq(half._move_speed(), RegularEnemy.DRIFTER_SPEED * 1.3, 0.01)
		assert_almost_eq(half._move_speed(), 117.0, 0.01)
		assert_gte(half.global_position.length() - half.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	var first := halves[0]
	var second := halves[1]
	player.global_position = first.global_position + Vector2(800, 0)
	var x0 := first.global_position.x
	first._physics_process(1.0)
	assert_almost_eq(first.global_position.x - x0, 117.0, 1.5)
	assert_eq(_shots_to_kill(manager, first), 30)
	assert_eq(_living_halves(elite.get_parent()).size(), 1, "a half does not split")
	assert_eq(_shots_to_kill(manager, second), 30)
	assert_eq(_living_halves(elite.get_parent()).size(), 0)


func test_summoner_never_exceeds_six_and_dies_to_basic_shot() -> void:
	var player := _node_player(FAR + Vector2(0, 4000))
	var elite := _elite(AffixCatalog.SUMMONER, FAR, player)
	assert_false(elite.woken)
	assert_eq(elite.summon_alive(), 0)
	elite._physics_process(5.9)
	assert_eq(elite.summon_alive(), 0, "no wave before 6 s")
	elite._physics_process(0.1)
	assert_eq(elite.summon_alive(), 2, "the first wave is at 6 s")
	for _wave in 6:
		elite._physics_process(6.0)
		assert_lte(elite.summon_alive(), 6)
		for body: RegularEnemy in _children_of(elite.get_parent()):
			if body == elite or not body.is_alive():
				continue
			assert_eq(body.archetype, RegularEnemy.ARCH_SWARMER)
			assert_false(body.is_in_group(EliteEnemy.GROUP_ELITE))
			assert_gte(body.global_position.length() - body.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	assert_eq(elite.summon_alive(), 6)
	var living := _swarmers(elite.get_parent())
	assert_eq(living.size(), 6)
	living[0].health.damage(living[0].health.max_hp)
	living[1].health.damage(living[1].health.max_hp)
	assert_eq(elite.summon_alive(), 4)
	elite._physics_process(6.0)
	assert_eq(elite.summon_alive(), 6)
	elite._physics_process(6.0)
	assert_eq(elite.summon_alive(), 6)
	var manager := _manager()
	assert_eq(_shots_to_kill(manager, elite), 75)
	assert_false(elite.is_alive())
	# Summons are not cleared by the elite's death, and they still cap at 6
	# because the elite is the only summoner.
	assert_eq(_swarmers(elite.get_parent()).size(), 6)


func test_bodies_slide_on_the_safe_disk_and_do_not_hit_inside_it() -> void:
	var player := _player(Vector2(500, 0))
	var elite := _elite(AffixCatalog.SPLITTING, Vector2(528, 0), player)
	await wait_physics_frames(3)
	assert_gte(elite.global_position.length() - elite.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	assert_eq(player.health.hp, player.health.max_hp)
	player.global_position = Vector2(512.0, 0.0)
	elite.global_position = Vector2(512.0 + elite.body_radius, 0.0)
	await wait_physics_frames(3)
	assert_eq(player.health.hp, player.health.max_hp, "no contact while the player is on the disk")
	# Just outside, overlap connects for 1, then i-frames block the rest.
	player.global_position = Vector2(520.0, 0.0)
	player.health.reset()
	elite.global_position = Vector2(520.0 + 10.0, 0.0)
	await wait_physics_frames(2)
	assert_gt(player.global_position.length(), WorldGen.SAFE_RADIUS)
	assert_eq(player.health.hp, player.health.max_hp - 1.0)
	# Chase across the origin stays on the rim.
	player.global_position = Vector2(-900, 0)
	player.health.reset()
	elite.global_position = Vector2(640, 0)
	elite.woken = true
	var limit := WorldGen.SAFE_RADIUS + elite.body_radius
	for _frame in 40:
		await wait_physics_frames(1)
		assert_gte(elite.global_position.length(), limit - 0.05)
		assert_gte(elite.global_position.length() - elite.body_radius, WorldGen.SAFE_RADIUS - 0.05)


func test_halves_and_summons_spawned_on_the_rim_stay_outside() -> void:
	var player := _node_player(Vector2(3000, 0))
	var splitting := _elite(AffixCatalog.SPLITTING, Vector2(528, 0), player)
	splitting.health.damage(splitting.health.max_hp)
	var halves := _halves(splitting.get_parent())
	assert_eq(halves.size(), 2)
	for half: EliteEnemy in halves:
		assert_gte(half.global_position.length() - half.body_radius, WorldGen.SAFE_RADIUS - 0.05)
		half._physics_process(0.5)
		assert_gte(half.global_position.length() - half.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	var summoner := _elite(AffixCatalog.SUMMONER, Vector2(540, 0), player)
	summoner._physics_process(6.0)
	var adds := _swarmers(summoner.get_parent())
	assert_eq(adds.size(), 2)
	for body: RegularEnemy in adds:
		assert_gte(body.global_position.length() - body.body_radius, WorldGen.SAFE_RADIUS - 0.05)


func _manager() -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.world_bounds = Rect2(-8000, -8000, 16000, 16000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	return manager


func _player(at: Vector2) -> Player:
	var player := (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = at
	add_child_autofree(player)
	return player


func _node_player(at: Vector2) -> Node2D:
	var player := Node2D.new()
	player.position = at
	add_child_autofree(player)
	return player


func _elite(affix: StringName, at: Vector2, player: Node2D) -> EliteEnemy:
	# Halves and summons are parented beside the elite. A holder keeps them
	# with it so a later test does not inherit the previous wave.
	var holder := Node2D.new()
	add_child_autofree(holder)
	var elite := (preload("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.configure_elite(affix, at, at, 2, player, true, false)
	holder.add_child(elite)
	return elite


func _shots_to_kill(manager: BulletManager, enemy: RegularEnemy) -> int:
	var shot := BasicShot.new()
	assert_almost_eq(shot.bullet_damage, 1.0, 0.001)
	assert_almost_eq(shot.fire_interval, 0.11, 0.001)
	var ctx := ShotContext.new()
	ctx.aim_direction = Vector2.RIGHT
	ctx.aim_angle = 0.0
	ctx.shooter_velocity = Vector2.ZERO
	ctx.target_mask = Layers.ENEMY
	var n := 0
	while enemy.is_alive() and n < 200:
		ctx.muzzle_position = enemy.global_position + Vector2(-6.0, 0.0)
		shot.fire(ctx, manager.emitter)
		manager.step(DT)
		n += 1
	assert_false(enemy.is_alive(), "BasicShot did not kill the body")
	return n


func _halves(parent: Node) -> Array[EliteEnemy]:
	var out: Array[EliteEnemy] = []
	for child: Node in parent.get_children():
		var elite := child as EliteEnemy
		if elite != null and elite.is_half:
			out.append(elite)
	return out


func _living_halves(parent: Node) -> Array[EliteEnemy]:
	var out: Array[EliteEnemy] = []
	for half: EliteEnemy in _halves(parent):
		if half.is_alive():
			out.append(half)
	return out


func _swarmers(parent: Node) -> Array[RegularEnemy]:
	var out: Array[RegularEnemy] = []
	for child: Node in parent.get_children():
		var body := child as RegularEnemy
		if body == null or not body.is_alive():
			continue
		if body is EliteEnemy:
			continue
		if body.archetype == RegularEnemy.ARCH_SWARMER:
			out.append(body)
	return out


func _children_of(parent: Node) -> Array[RegularEnemy]:
	var out: Array[RegularEnemy] = []
	for child: Node in parent.get_children():
		var body := child as RegularEnemy
		if body != null:
			out.append(body)
	return out
