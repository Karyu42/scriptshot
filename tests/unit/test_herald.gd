extends GutTest
## L2 Herald: delay, cancel, placement, wake, persistence. The scene test is
## scenes/main.tscn. The rig is the same director with no chunk stream, so a
## loop over seeds stays cheap. Natural elites are not rolled into chunks in
## this layer; the cancel tests add one body the way L3 will.

const DT := 1.0 / 60.0

var _root: Node2D
var _player: Player
var _arm: HeraldArm
var _director: HeraldDirector
var _save: SaveGame
var _path := ""
var _slot_existed := false
var _mains: Array[Main] = []


func before_all() -> void:
	_slot_existed = FileAccess.file_exists(SaveGame.DEFAULT_PATH)


func after_all() -> void:
	_drop()
	_free_mains()
	assert_eq(FileAccess.file_exists(SaveGame.DEFAULT_PATH), _slot_existed)


func after_each() -> void:
	_drop()
	_free_mains()
	EliteCue.reset_budget()


func test_rolls_off_every_seed_spawns_inside_the_window() -> void:
	var seeds: Array[int] = []
	for seed_value in range(0, 24):
		seeds.append(seed_value)
	seeds.append(42)
	seeds.append(99)
	for seed_value in seeds:
		_rig(seed_value, "user://gut_l2_roll_%d.cfg" % seed_value)
		# Forced off: a woken elite in the tree must not cancel the Herald.
		_director.natural_elites_cancel = false
		var decoy := _natural(Vector2(5000, 5000), AffixCatalog.SUMMONER)
		decoy.woken = true
		_arm_at(Vector2(600, 0), Vector2(120, 0))
		var delay := WorldGen.herald_delay(seed_value)
		assert_gte(delay, 58.0)
		assert_lt(delay, 78.0)
		_director.advance(delay - 0.05)
		assert_null(_director.herald, "seed %d spawned early" % seed_value)
		_director.advance(0.05)
		assert_not_null(_director.herald, "seed %d did not spawn" % seed_value)
		assert_true(_director.herald.is_herald)
		assert_eq(_director.herald.affix, WorldGen.herald_affix(seed_value))
		assert_true(_save.herald_done)
		assert_almost_eq(_director.herald.global_position.x, 1800.0, 1.0)
		_drop()


func test_a_woken_or_dead_natural_elite_cancels_and_an_asleep_one_does_not() -> void:
	_rig(1, "user://gut_l2_wake.cfg")
	var elite := _natural(Vector2(4500, 1200), AffixCatalog.SUMMONER)
	elite.woken = true
	_arm_at(Vector2(600, 0), Vector2(80, 0))
	assert_true(_save.herald_done)
	assert_null(_director.herald)
	_director.advance(100.0)
	assert_null(_director.herald)
	_drop()

	_rig(1, "user://gut_l2_kill.cfg")
	var victim := _natural(Vector2(5000, -2000), AffixCatalog.SUMMONER)
	_arm_at(Vector2(600, 0), Vector2(80, 0))
	assert_true(_director.counting)
	assert_false(_save.herald_done)
	victim.health.damage(victim.health.max_hp)
	assert_false(victim.is_alive())
	assert_true(_save.herald_done)
	assert_null(_director.herald)
	_director.advance(80.0)
	assert_null(_director.herald)
	_drop()

	_rig(42, "user://gut_l2_asleep.cfg")
	var asleep := _natural(Vector2(7000, 7000), AffixCatalog.SUMMONER)
	assert_false(asleep.woken)
	_arm_at(Vector2(600, 0), Vector2(80, 0))
	var delay := WorldGen.herald_delay(42)
	assert_lt(delay, 78.0)
	_director.advance(delay - 0.05)
	assert_null(_director.herald)
	assert_false(_save.herald_done)
	_director.advance(0.05)
	assert_not_null(_director.herald)
	assert_true(_save.herald_done)
	assert_lt(delay, 78.0)


func test_placement_affix_and_safe_disk_including_the_tier_edge() -> void:
	_rig(1, "user://gut_l2_place.cfg")
	_arm_at(Vector2(600, 0), Vector2(90, 0))
	_director.advance(WorldGen.herald_delay(1))
	var herald := _director.herald
	assert_eq(herald.affix, &"summoner")
	assert_almost_eq(herald.health.max_hp, 75.0, 0.01)
	assert_almost_eq(herald.health.hp, 75.0, 0.01)
	assert_eq(herald.archetype, RegularEnemy.ARCH_DRIFTER)
	assert_almost_eq(herald.body_radius, RegularEnemy.DRIFTER_RADIUS, 0.01)
	assert_almost_eq(herald._move_speed(), RegularEnemy.DRIFTER_SPEED, 0.01)
	assert_eq(herald.outline_width(), 3.0)
	assert_true(herald.cue.draws_ring())
	assert_eq(herald.cue.glyph, EliteCue.GLYPH_CIRCLE)
	assert_eq(herald.get_parent().name, "Bodies")
	assert_gte(herald.global_position.length() - herald.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	assert_eq(WorldGen.tier_at(herald.global_position.x, herald.global_position.y), 0)
	_drop()

	# Heading back into the disk: the spec point sits on 512, the body is pushed
	# out by its radius so the circle does not enter the disk.
	_rig(2, "user://gut_l2_inner.cfg")
	_arm_at(Vector2(700, 0), Vector2(-100, 0))
	_director.advance(WorldGen.herald_delay(2))
	herald = _director.herald
	assert_eq(herald.affix, &"splitting")
	assert_almost_eq(herald.global_position.x, -(WorldGen.SAFE_RADIUS + RegularEnemy.DRIFTER_RADIUS), 0.05)
	assert_almost_eq(herald.global_position.y, 0.0, 0.05)
	assert_gte(herald.global_position.length() - herald.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	_drop()

	_rig(1, "user://gut_l2_edge.cfg")
	_arm_at(Vector2(16200, 40), Vector2(150, 0))
	_director.advance(WorldGen.herald_delay(1))
	herald = _director.herald
	assert_almost_eq(herald.global_position.x, float(WorldGen.TIER_PX) - WorldGen.HERALD_EDGE_MARGIN, 0.5)
	assert_eq(WorldGen.tier_at(herald.global_position.x, herald.global_position.y), 0)
	var extent := maxf(absf(herald.global_position.x), absf(herald.global_position.y)) + herald.body_radius
	assert_lt(extent, float(WorldGen.TIER_PX))
	assert_gte(herald.global_position.length() - herald.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	_drop()

	# Slow velocity defers to aim. +Y is down the world axis (Godot UP is -Y).
	_rig(1, "user://gut_l2_aim.cfg")
	_arm_at(Vector2(600, 0), Vector2(5, 0))
	_player.aim_direction = Vector2(0, 1)
	_director.advance(WorldGen.herald_delay(1))
	assert_almost_eq(_director.herald.global_position.x, 600.0, 1.0)
	assert_almost_eq(_director.herald.global_position.y, 1200.0, 1.0)
	_drop()


func test_walking_toward_it_wakes_it_inside_80s_and_the_cue_starts() -> void:
	_rig(1, "user://gut_l2_walk.cfg")
	_arm_at(Vector2(600, 0), Vector2(100, 0))
	var delay := WorldGen.herald_delay(1)
	_director.advance(delay)
	var herald := _director.herald
	var gap := herald.global_position.distance_to(_player.global_position)
	assert_almost_eq(gap, WorldGen.HERALD_AHEAD, 1.0)
	assert_false(herald.woken)
	var walked := 0.0
	var speed := 300.0
	while not herald.woken and walked < 3.0:
		var to := herald.global_position - _player.global_position
		_player.global_position += to.normalized() * speed * DT
		walked += DT
		herald._physics_process(DT)
	assert_true(herald.woken)
	var dist := _player.global_position.distance_to(herald.global_position)
	assert_lte(dist, WorldGen.WAKE_RADIUS + 0.1)
	assert_gt(walked, 1.2)
	assert_lt(walked, 2.3)
	assert_lt(delay + walked, 80.0)
	assert_gt(herald.cue.brighten_left, 0.0)
	assert_true(herald.sting.requested)
	assert_eq(herald.outline_width(), 3.0)


func test_reload_after_spawn_or_cancel_does_not_spawn_again() -> void:
	_rig(1, "user://gut_l2_reload_spawn.cfg")
	_arm_at(Vector2(600, 0), Vector2(80, 0))
	_director.advance(WorldGen.herald_delay(1))
	assert_not_null(_director.herald)
	assert_true(_save.herald_done)
	var path := _path
	_root.free()
	_root = null
	var again := SaveGame.load_from(path)
	assert_true(again.herald_done)
	assert_eq(again.shards, 0)
	_rig_from(again)
	_arm_at(Vector2(800, 0), Vector2(80, 0))
	_director.advance(90.0)
	assert_null(_director.herald)
	assert_true(_director.resolved)
	_drop()

	_rig(2, "user://gut_l2_reload_cancel.cfg")
	var elite := _natural(Vector2(6000, 0), AffixCatalog.SUMMONER)
	elite.woken = true
	_arm_at(Vector2(600, 0), Vector2(80, 0))
	assert_true(_save.herald_done)
	path = _path
	_root.free()
	_root = null
	again = SaveGame.load_from(path)
	assert_true(again.herald_done)
	_rig_from(again)
	_arm_at(Vector2(900, 0), Vector2(40, 0))
	_director.advance(90.0)
	assert_null(_director.herald)


func test_reload_during_the_countdown_restarts_it_and_stores_no_remainder() -> void:
	var path := "user://gut_l2_mid.cfg"
	_rig(1, path)
	_arm_at(Vector2(640, 0), Vector2(70, 0))
	_director.advance(10.0)
	assert_true(_director.counting)
	assert_null(_director.herald)
	assert_false(_save.herald_done)
	_save.save()
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(path), OK)
	assert_true(cfg.has_section_key("world", "herald_done"))
	@warning_ignore("unsafe_call_argument")
	var flag := bool(cfg.get_value("world", "herald_done", false))
	assert_false(flag)
	assert_false(cfg.has_section_key("world", "herald_timer"))
	assert_false(cfg.has_section_key("world", "herald_position"))
	assert_false(cfg.has_section_key("world", "herald_hp"))
	_root.free()
	_root = null
	var loaded := SaveGame.load_from(path)
	assert_false(loaded.herald_done)
	_rig_from(loaded)
	assert_false(_arm.armed)
	assert_false(_director.counting)
	_arm_at(Vector2(640, 0), Vector2(70, 0))
	var delay := WorldGen.herald_delay(1)
	assert_almost_eq(_director.seconds_left(), delay, 0.001)
	assert_almost_eq(_director.elapsed, 0.0, 0.001)
	_director.advance(delay - 0.05)
	assert_null(_director.herald, "a restarted countdown must not keep the old remainder")
	_director.advance(0.05)
	assert_not_null(_director.herald)


func test_shards_for_the_herald_body_only_and_no_chunk_bit() -> void:
	_rig(2, "user://gut_l2_shard.cfg")
	_arm_at(Vector2(600, 0), Vector2(100, 0))
	_director.advance(WorldGen.herald_delay(2))
	var herald := _director.herald
	assert_eq(herald.affix, &"splitting")
	var manager := _bullets()
	assert_eq(_save.shards, 0)
	assert_eq(_save.elite_kills.size(), 0)
	_kill(manager, herald)
	assert_eq(_save.shards, 1)
	assert_eq(_save.elite_kills.size(), 0)
	var halves := _living_halves(_director.get_node("Bodies"))
	assert_eq(halves.size(), 2)
	for half: EliteEnemy in halves:
		_kill(manager, half)
	assert_eq(_save.shards, 1)
	var disk := SaveGame.load_from(_path)
	assert_eq(disk.shards, 1)
	assert_true(disk.herald_done)
	assert_eq(disk.elite_kills.size(), 0)
	_drop()

	_rig(1, "user://gut_l2_summon_shard.cfg")
	_arm_at(Vector2(2400, 2400), Vector2(100, 0))
	_director.advance(WorldGen.herald_delay(1))
	herald = _director.herald
	assert_eq(herald.affix, &"summoner")
	herald._physics_process(6.0)
	var adds := _swarmers(herald.get_parent())
	assert_eq(adds.size(), 2)
	manager = _bullets()
	_kill(manager, adds[0])
	assert_eq(_save.shards, 0)
	_kill(manager, herald)
	assert_eq(_save.shards, 1)
	_kill(manager, adds[1])
	assert_eq(_save.shards, 1)
	assert_eq(_save.elite_kills.size(), 0)


func test_main_scene_spawns_a_fightable_herald_and_a_reload_does_not() -> void:
	var path := "user://gut_l2_main.cfg"
	_discard(path)
	_write_save(path, 1, false)
	var main := _open_main(path)
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	var arm := main.get_node("HeraldArm") as HeraldArm
	var director := main.get_node("HeraldDirector") as HeraldDirector
	var chunks := main.get_node("ChunkStream") as ChunkStream
	var absent_before := chunks.absent_records().size()
	player.teleport(Vector2(600, 0))
	player.velocity = Vector2(100, 0)
	arm.advance(0.0)
	assert_true(arm.armed)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)
	var delay := WorldGen.herald_delay(1)
	director.advance(delay - 0.05)
	assert_null(director.herald)
	director.advance(0.05)
	var herald := director.herald
	assert_not_null(herald)
	assert_eq(herald.name, "Herald")
	assert_eq(herald.get_parent().name, "Bodies")
	assert_ne(herald.get_parent().get_parent(), chunks)
	assert_eq(herald.affix, &"summoner")
	assert_almost_eq(herald.health.hp, 75.0, 0.01)
	assert_true(herald.cue.draws_ring())
	assert_eq(herald.cue.glyph, EliteCue.GLYPH_CIRCLE)
	assert_almost_eq(herald.global_position.x, 1800.0, 1.5)
	assert_gte(herald.global_position.length() - herald.body_radius, WorldGen.SAFE_RADIUS - 0.05)
	assert_eq(WorldGen.tier_at(herald.global_position.x, herald.global_position.y), 0)
	var bullets := main.get_node("BulletManager") as BulletManager
	var hp := herald.health.hp
	_one_shot(bullets, herald)
	assert_almost_eq(herald.health.hp, hp - 1.0, 0.01)
	assert_true(SaveGame.load_from(path).herald_done)
	assert_eq(chunks.absent_records().size(), absent_before)
	# Wake the cue without waiting out the walk: step the body once inside 700 px.
	player.global_position = herald.global_position + Vector2(-690, 0)
	herald._physics_process(DT)
	assert_true(herald.woken)
	assert_gt(herald.cue.brighten_left, 0.0)
	assert_true(herald.sting.requested)
	herald.queue_redraw()
	await wait_process_frames(1)
	assert_true(herald.sting.used_generator or herald.sting.used_fallback)
	main.free()
	_mains.clear()
	var reloaded := _open_main(path)
	var player2 := reloaded.get_node("Player") as Player
	player2.set_physics_process(false)
	var arm2 := reloaded.get_node("HeraldArm") as HeraldArm
	var director2 := reloaded.get_node("HeraldDirector") as HeraldDirector
	player2.teleport(Vector2(700, 0))
	player2.velocity = Vector2(80, 0)
	arm2.advance(0.0)
	director2.advance(90.0)
	assert_null(director2.herald)
	assert_true(director2.resolved)
	reloaded.free()
	_mains.clear()
	_discard(path)


func test_load_outside_the_disk_arms_immediately_unless_the_flag_is_set() -> void:
	var path := "user://gut_l2_outside.cfg"
	_discard(path)
	_write_save(path, 7, false)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = path
	var player := main.get_node("Player") as Player
	player.position = Vector2(900, 0)
	_mains.append(main)
	add_child(main)
	await wait_physics_frames(1)
	var arm := main.get_node("HeraldArm") as HeraldArm
	var director := main.get_node("HeraldDirector") as HeraldDirector
	assert_true(arm.armed)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)
	assert_true(director.counting)
	assert_false(director.resolved)
	assert_null(director.herald)
	assert_lt(director.elapsed, 0.1)
	main.free()
	_mains.clear()

	_write_save(path, 7, true)
	var done := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	done.save_path = path
	var player_done := done.get_node("Player") as Player
	player_done.position = Vector2(900, 0)
	_mains.append(done)
	add_child(done)
	await wait_physics_frames(1)
	var director_done := done.get_node("HeraldDirector") as HeraldDirector
	director_done.advance(90.0)
	assert_null(director_done.herald)
	assert_true(director_done.resolved)
	assert_false(director_done.counting)
	done.free()
	_mains.clear()
	_discard(path)


func _rig(seed_value: int, path: String) -> void:
	_drop()
	_discard(path)
	var save := SaveGame.new()
	save.path = path
	save.world_seed = seed_value
	save.herald_done = false
	save.shards = 0
	_rig_from(save)


func _rig_from(save: SaveGame) -> void:
	_drop()
	_save = save
	_path = save.path
	assert_ne(_path, SaveGame.DEFAULT_PATH)
	_root = Node2D.new()
	add_child(_root)
	_player = (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	_root.add_child(_player)
	_player.set_physics_process(false)
	var dummies := Node2D.new()
	_root.add_child(dummies)
	_arm = HeraldArm.new()
	_root.add_child(_arm)
	_arm.bind(_player, dummies)
	_director = HeraldDirector.new()
	_root.add_child(_director)
	_director.bind(_arm, _player, _save)


func _arm_at(at: Vector2, velocity: Vector2) -> void:
	_player.teleport(at)
	_player.velocity = velocity
	_player.aim_direction = Vector2.RIGHT
	_arm.advance(0.0)


func _natural(at: Vector2, affix: StringName) -> EliteEnemy:
	var elite := (preload("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.name = "Natural"
	elite.configure_elite(affix, at, at, _save.world_seed, _player, false, false)
	_root.add_child(elite)
	return elite


func _bullets() -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.world_bounds = Rect2(-20000, -20000, 40000, 40000)
	manager.render_enabled = false
	manager.auto_step = false
	_root.add_child(manager)
	return manager


func _kill(manager: BulletManager, enemy: RegularEnemy) -> void:
	var shot := BasicShot.new()
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
	assert_false(enemy.is_alive())


func _one_shot(manager: BulletManager, enemy: RegularEnemy) -> void:
	var shot := BasicShot.new()
	var ctx := ShotContext.new()
	ctx.aim_direction = Vector2.RIGHT
	ctx.aim_angle = 0.0
	ctx.shooter_velocity = Vector2.ZERO
	ctx.target_mask = Layers.ENEMY
	ctx.muzzle_position = enemy.global_position + Vector2(-6.0, 0.0)
	shot.fire(ctx, manager.emitter)
	manager.step(DT)


func _living_halves(parent: Node) -> Array[EliteEnemy]:
	var out: Array[EliteEnemy] = []
	for child: Node in parent.get_children():
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


func _open_main(path: String) -> Main:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = path
	_mains.append(main)
	add_child(main)
	return main


func _write_save(path: String, seed_value: int, done: bool) -> void:
	var save := SaveGame.new()
	save.path = path
	save.world_seed = seed_value
	save.herald_done = done
	save.shards = 0
	save.save()


func _drop() -> void:
	if _root != null and is_instance_valid(_root):
		_root.free()
	_root = null
	_player = null
	_arm = null
	_director = null
	_save = null
	if not _path.is_empty():
		_discard(_path)
		_path = ""


func _free_mains() -> void:
	for main: Main in _mains:
		if is_instance_valid(main):
			main.free()
	_mains.clear()


func _discard(path: String) -> void:
	if path.is_empty() or path == SaveGame.DEFAULT_PATH:
		return
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
