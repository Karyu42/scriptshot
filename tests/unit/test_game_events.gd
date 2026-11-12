extends GutTest
## GameEvents: enemy and player deaths emit plain-data signals, once per death.

const DT := 1.0 / 60.0

var _kinds: Array[StringName] = []
var _rarities: Array[int] = []
var _tiers: Array[int] = []
var _positions: Array[Vector2] = []
var _firsts: Array[bool] = []
var _player_deaths := 0


func before_each() -> void:
	_kinds.clear()
	_rarities.clear()
	_tiers.clear()
	_positions.clear()
	_firsts.clear()
	_player_deaths = 0
	GameEvents.enemy_killed.connect(_on_kill)
	GameEvents.player_died.connect(_on_player_died)


func after_each() -> void:
	GameEvents.enemy_killed.disconnect(_on_kill)
	GameEvents.player_died.disconnect(_on_player_died)


func _on_kill(kind: StringName, rarity: int, tier: int, position: Vector2, first_death: bool) -> void:
	_firsts.append(first_death)
	_kinds.append(kind)
	_rarities.append(rarity)
	_tiers.append(tier)
	_positions.append(position)


func _on_player_died() -> void:
	_player_deaths += 1


func _regular(archetype: StringName, at: Vector2) -> RegularEnemy:
	var body := (load("res://scenes/regular_enemy.tscn") as PackedScene).instantiate() as RegularEnemy
	body.configure(archetype, at, at, 1, WorldGen.chunk_of(at), 0, 0, null)
	return body


func _elite(affix: StringName, at: Vector2, herald: bool) -> EliteEnemy:
	var body := (load("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	body.configure_elite(affix, at, at, 1, null, herald, false, WorldGen.chunk_of(at), -1 if herald else 0)
	return body


func test_kinds_are_the_spec_string_names() -> void:
	var want: Array[StringName] = [&"drifter", &"swarmer", &"shieldbearer", &"sniper", &"husk", &"warden", &"dummy"]
	assert_eq(EnemyKinds.ALL, want)
	assert_eq(EnemyKinds.WARDEN, &"warden")
	assert_eq(EnemyKinds.DUMMY, &"dummy")
	assert_eq(EnemyKinds.DRIFTER, RegularEnemy.ARCH_DRIFTER)
	assert_eq(EnemyKinds.SWARMER, RegularEnemy.ARCH_SWARMER)


func test_a_regular_kill_emits_enemy_killed_once() -> void:
	var at := Vector2(900, 40)
	var body := _regular(RegularEnemy.ARCH_SWARMER, at)
	add_child_autoqfree(body)
	body.health.damage(1000.0)
	body.health.damage(1000.0)
	assert_eq(_kinds.size(), 1)
	assert_eq(_kinds[0], &"swarmer")
	assert_eq(_rarities[0], EnemyKinds.RARITY_NONE)
	assert_eq(_tiers[0], 0)
	assert_eq(_positions[0], at)


func test_kill_reports_the_chunk_tier() -> void:
	# Tier 1 starts at |x| = 16384 (WorldGen.tier_at).
	var at := Vector2(16384.0 + 600.0, 0)
	var body := _regular(RegularEnemy.ARCH_DRIFTER, at)
	add_child_autoqfree(body)
	body.health.damage(1000.0)
	assert_eq(_kinds.size(), 1)
	assert_eq(_kinds[0], &"drifter")
	assert_eq(_tiers[0], WorldGen.chunk_tier(body.chunk.x, body.chunk.y))
	assert_eq(_tiers[0], 1)


func test_an_elite_kill_carries_its_rarity() -> void:
	var at := Vector2(1200, 0)
	var elite := _elite(AffixCatalog.SUMMONER, at, false)
	elite.rarity = EnemyKinds.RARITY_COMMON
	add_child_autoqfree(elite)
	elite.health.damage(1000.0)
	assert_eq(_kinds.size(), 1)
	assert_eq(_kinds[0], &"drifter")
	assert_eq(_rarities[0], EnemyKinds.RARITY_COMMON)
	assert_eq(_tiers[0], 0)
	assert_eq(_positions[0], at)


func test_the_herald_and_its_halves_report_their_own_kinds() -> void:
	var at := Vector2(1200, 0)
	var herald := _elite(AffixCatalog.SPLITTING, at, true)
	add_child_autoqfree(herald)
	herald.health.damage(1000.0)
	assert_eq(_kinds.size(), 1)
	assert_eq(_kinds[0], &"drifter", "the Herald is a drifter body")
	assert_eq(_rarities[0], EnemyKinds.RARITY_COMMON)
	var halves: Array[EliteEnemy] = []
	for child: Node in get_children():
		var half := child as EliteEnemy
		if half != null and half.is_half and half.is_alive():
			halves.append(half)
	assert_eq(halves.size(), 2, "splitting spawned two halves")
	for half in halves:
		half.health.damage(1000.0)
		half.queue_free()
	assert_eq(_kinds.size(), 3)
	assert_eq(_kinds[1], &"drifter", "halves are drifters")
	assert_eq(_rarities[1], EnemyKinds.RARITY_NONE, "halves are not elites")


func test_regular_kills_are_first_deaths() -> void:
	var body := _regular(RegularEnemy.ARCH_DRIFTER, Vector2(900, 0))
	add_child_autoqfree(body)
	body.health.damage(1000.0)
	assert_eq(_firsts, [true] as Array[bool])


func test_a_dummy_emits_dummy_kills_and_only_its_first_is_a_first_death() -> void:
	var dummy := (load("res://scenes/training_dummy.tscn") as PackedScene).instantiate() as TrainingDummy
	dummy.position = Vector2(300, 0)
	add_child_autofree(dummy)
	var hurtbox := dummy.get_node("Hurtbox") as Hurtbox
	hurtbox.receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
	hurtbox.receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
	assert_eq(_kinds.size(), 1, "a downed dummy does not die twice")
	assert_eq(_kinds[0], &"dummy")
	assert_eq(_rarities[0], EnemyKinds.RARITY_NONE)
	assert_eq(_tiers[0], 0)
	assert_eq(_positions[0], Vector2(300, 0))
	dummy._process(dummy.respawn_delay + 0.01)
	hurtbox.receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
	dummy._process(dummy.respawn_delay + 0.01)
	hurtbox.receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
	assert_eq(_firsts, [true, false, false] as Array[bool])
	# A new dummy instance starts over.
	var other := (load("res://scenes/training_dummy.tscn") as PackedScene).instantiate() as TrainingDummy
	add_child_autofree(other)
	(other.get_node("Hurtbox") as Hurtbox).receive_hit(other.max_health, Vector2.ZERO, Vector2.ZERO)
	assert_eq(_firsts[3], true)


func test_player_death_emits_player_died_each_death() -> void:
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.health.clear_engine_invulnerability()
	player.health.damage(1000.0)
	assert_eq(_player_deaths, 1)
	player.respawn(Vector2.ZERO)
	player.health.clear_engine_invulnerability()
	player.health.damage(1000.0)
	assert_eq(_player_deaths, 2)


func test_signals_carry_no_objects() -> void:
	var ours: Array[String] = ["enemy_killed", "boss_defeated", "run_started", "run_ended", "player_died"]
	var found := 0
	for sig: Dictionary in GameEvents.get_signal_list():
		var sig_name: String = sig["name"]
		if not ours.has(sig_name):
			continue
		found += 1
		var args: Array = sig["args"]
		for arg: Dictionary in args:
			var arg_type: int = arg["type"]
			assert_ne(arg_type, TYPE_OBJECT, "%s.%s" % [sig_name, arg["name"]])
	assert_eq(found, ours.size())


func test_main_emits_run_started_and_its_regulars_are_queryable() -> void:
	var save := "user://gut_game_events.cfg"
	_discard(save)
	var starts: Array[int] = [0]
	var on_start := func() -> void: starts[0] += 1
	GameEvents.run_started.connect(on_start)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = save
	add_child_autofree(main)
	GameEvents.run_started.disconnect(on_start)
	assert_eq(starts[0], 1)
	await wait_physics_frames(1)
	var hostiles := main.get_tree().get_nodes_in_group(RegularEnemy.GROUP)
	assert_gt(hostiles.size(), 0)
	for node: Node in hostiles:
		var body := node as RegularEnemy
		if body.is_alive():
			assert_true(WorldQuery.has_id(body.get_instance_id()))
	main.free()
	_discard(save)


func _discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
