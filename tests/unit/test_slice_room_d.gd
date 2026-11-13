extends GutTest
## Vertical-slice row 7: room-D rare elite, Bulwark + Summoner, escort, G5,
## slice_rare_dead, and shards +3.

const DT := 1.0 / 60.0
const _SAVE := "user://gut_slice_room_d.cfg"
const SPEED := 1200.0

var room: SliceRoomD
var progress: SliceProgress
var layout: SliceLayout
var player: Player
var save: SaveGame
var bullets: BulletManager


func before_each() -> void:
	_discard(_SAVE)
	EliteCue.reset_budget()
	layout = SliceLayout.new()
	layout.enabled = true
	add_child_autofree(layout)
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector2.ZERO
	add_child_autofree(player)
	player.set_physics_process(false)
	player.health.set_physics_process(false)
	save = SaveGame.new()
	save.path = _SAVE
	save.world_seed = 1
	save.save()
	progress = SliceProgress.new()
	add_child_autofree(progress)
	progress.bind(player, null, layout, save)
	bullets = BulletManager.new()
	bullets.backend_preference = "gdscript"
	bullets.capacity = 128
	bullets.world_bounds = Rect2(-2000, -2000, 14000, 8000)
	bullets.render_enabled = false
	bullets.auto_step = false
	add_child_autofree(bullets)
	room = SliceRoomD.new()
	add_child_autofree(room)
	room.bind(player, progress, save, save.world_seed)
	_freeze(room)
	await wait_physics_frames(1)


func after_each() -> void:
	EliteCue.reset_budget()
	_discard(_SAVE)


func test_the_rare_elite_spawns_in_room_d_with_an_escort() -> void:
	assert_true(room.elite_alive())
	var elite := room.elite
	assert_almost_eq(elite.global_position.x, SliceRoomD.ANCHOR.x, 0.1)
	assert_almost_eq(elite.global_position.y, SliceRoomD.ANCHOR.y, 0.1)
	assert_eq(SliceLayout.room_at(elite.global_position), SliceLayout.ROOM_D)
	assert_eq(elite.rarity, EnemyKinds.RARITY_RARE)
	assert_true(elite.has_affix(AffixCatalog.BULWARK))
	assert_true(elite.has_affix(AffixCatalog.SUMMONER))
	assert_almost_eq(elite.health.max_hp, EliteEnemy.RARE_HP, 0.001)
	assert_almost_eq(elite.health.max_hp, 120.0, 0.001)
	assert_almost_eq(elite.health.hp, 120.0, 0.001)
	assert_not_null(elite.cue)
	assert_eq(elite.cue.tier, RarityCue.TIER_ELITE_RARE)
	assert_eq(elite._hurtbox.response, Hurtbox.Response.ABSORB)
	assert_almost_eq(elite._hurtbox.arc_deg, EliteEnemy.BULWARK_RARE_ARC, 0.001)
	assert_true(room.escort_alive())
	var escort := room.escort
	assert_false(escort is EliteEnemy)
	assert_eq(escort.archetype, RegularEnemy.ARCH_DRIFTER)
	assert_almost_eq(escort.global_position.distance_to(SliceRoomD.ANCHOR), WorldGen.ESCORT_DISTANCE, 0.05)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G5))
	assert_false(save.slice_rare_dead)
	assert_eq(save.shards, 0)
	assert_false(elite.grants_shard)


func test_the_room_d_body_does_not_emit_shard_dropped() -> void:
	var elite := room.elite
	assert_false(elite.grants_shard)
	var dropped := [0]
	elite.shard_dropped.connect(func() -> void: dropped[0] += 1)
	elite.health.try_damage(10000.0)
	assert_eq(dropped[0], 0, "Room D must not emit shard_dropped; SliceRoomD adds +3")
	assert_eq(save.shards, 3)




func test_the_bulwark_arc_turns_at_45_degrees_per_second() -> void:
	var elite := room.elite
	assert_almost_eq(elite._hurtbox.facing, PI, 0.001)
	# South of the body: the short turn from west is clockwise toward +Y.
	player.global_position = elite.global_position + Vector2(0, 200)
	elite._physics_process(DT)
	var stepped := PI - deg_to_rad(EliteEnemy.BULWARK_RARE_TURN) * DT
	assert_almost_eq(elite._hurtbox.facing, wrapf(stepped, -PI, PI), 0.002)
	# The remainder of one second from the first tick.
	elite._physics_process(1.0 - DT)
	var expected := PI - deg_to_rad(EliteEnemy.BULWARK_RARE_TURN)
	assert_almost_eq(elite._hurtbox.facing, wrapf(expected, -PI, PI), 0.02)
	assert_ne(elite._hurtbox.facing, (player.global_position - elite.global_position).angle())


func test_a_front_shot_is_absorbed_and_a_rear_shot_damages() -> void:
	var elite := room.elite
	# Stand west so the 45°/s arc stays on the entrance side.
	player.global_position = elite.global_position + Vector2(-200, 0)
	elite._physics_process(DT)
	# The escort sits 48 px east of the body; a rear shot would hit it first.
	var escort_box := room.escort.get_node_or_null("Hurtbox") as Hurtbox
	if escort_box != null:
		escort_box.active = false
	var hp := elite.health.hp
	_fire_at(elite.global_position, PI)
	assert_eq(bullets.alive_count(), 0)
	assert_almost_eq(elite.health.hp, hp, 0.001)
	_fire_at(elite.global_position, 0.0)
	assert_lt(elite.health.hp, hp)


func test_the_elite_wakes_when_the_player_crosses_g4() -> void:
	var elite := room.elite
	var gate_x := SliceLayout.gate_rect(SliceLayout.GATE_G4).position.x
	assert_gt(elite.global_position.x - gate_x, WorldGen.WAKE_RADIUS, "G4 is past the 700 px wake")
	player.global_position = Vector2(gate_x - 1.0, 0.0)
	elite._physics_process(DT)
	assert_false(elite.woken, "still west of the G4 line")
	player.global_position = Vector2(gate_x, 0.0)
	elite._physics_process(DT)
	assert_true(elite.woken, "the first tick on the gate line wakes it")


func test_summons_wait_for_wake_cap_at_8_and_do_not_open_g5() -> void:
	var elite := room.elite
	elite._physics_process(5.0)
	assert_eq(elite.summon_alive(), 0, "no wave while asleep")
	player.global_position = Vector2(elite.wake_x, 0.0)
	elite._physics_process(DT)
	assert_true(elite.woken)
	elite._physics_process(3.9)
	assert_eq(elite.summon_alive(), 0, "first wave is 4 s after wake")
	elite._physics_process(0.2)
	assert_eq(elite.summon_alive(), 2)
	# Three more waves fill the cap.
	for _i in 3:
		elite._physics_process(4.0)
	assert_eq(elite.summon_alive(), 8)
	elite._physics_process(4.0)
	assert_eq(elite.summon_alive(), 8, "the cap holds")
	var add := _one_summon(elite)
	assert_not_null(add)
	assert_almost_eq(add.health.max_hp, 1.0, 0.001)
	add.health.try_damage(10000.0)
	assert_eq(elite.summon_alive(), 7)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G5))
	assert_false(save.slice_rare_dead)
	assert_eq(save.shards, 0)
	# Refill only up to the cap.
	elite._physics_process(4.0)
	assert_eq(elite.summon_alive(), 8)


func test_killing_the_body_opens_g5_adds_three_shards_and_does_not_respawn() -> void:
	var elite := room.elite
	elite.health.try_damage(10000.0)
	assert_false(room.elite_alive())
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G5))
	assert_true(layout.is_gate_open(SliceLayout.GATE_G5))
	assert_true(save.slice_rare_dead)
	assert_eq(save.shards, 3)
	# The escort can still be up; it is not a shard and not the gate.
	assert_true(room.escort_alive())
	var loaded := SaveGame.load_from(_SAVE)
	assert_true(loaded.slice_rare_dead)
	assert_eq(loaded.shards, 3)
	assert_true((loaded.slice_gates & (1 << 5)) != 0)
	# A fresh bind on the saved slot must not respawn the body or escort.
	var again := SliceRoomD.new()
	add_child_autofree(again)
	var fresh := SliceProgress.new()
	add_child_autofree(fresh)
	fresh.bind(player, null, layout, loaded)
	again.bind(player, fresh, loaded, loaded.world_seed)
	assert_false(again.elite_alive())
	assert_false(again.escort_alive())
	assert_true(fresh.is_gate_unlocked(SliceLayout.GATE_G5))


func test_killing_the_escort_does_not_open_g5_or_add_shards() -> void:
	room.escort.health.try_damage(10000.0)
	assert_false(room.escort_alive())
	assert_true(room.elite_alive())
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G5))
	assert_false(save.slice_rare_dead)
	assert_eq(save.shards, 0)


func test_a_saved_dead_flag_does_not_spawn_on_load() -> void:
	_discard(_SAVE)
	var slot := SaveGame.new()
	slot.path = _SAVE
	slot.world_seed = 1
	slot.slice_rare_dead = true
	slot.save()
	var host := SliceRoomD.new()
	add_child_autofree(host)
	host.bind(player, progress, slot, slot.world_seed)
	assert_false(host.elite_alive())
	assert_false(host.escort_alive())


func test_main_scene_has_the_room_d_node() -> void:
	_discard(_SAVE)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = _SAVE
	add_child_autofree(main)
	var host := main.get_node("SliceRoomD") as SliceRoomD
	assert_not_null(host)
	assert_true(host.elite_alive())
	assert_true(host.escort_alive())
	assert_almost_eq(host.elite.global_position.x, SliceRoomD.ANCHOR.x, 0.1)
	assert_eq(host.elite.rarity, EnemyKinds.RARITY_RARE)
	assert_eq(host.elite.cue.tier, RarityCue.TIER_ELITE_RARE)
	assert_false((main.get_node("SliceProgress") as SliceProgress).is_gate_unlocked(SliceLayout.GATE_G5))


func _fire_at(target: Vector2, from_angle: float) -> void:
	var origin := target + Vector2.from_angle(from_angle) * 200.0
	var req := ShotRequest.with_velocity(origin, (target - origin).normalized() * SPEED)
	req.radius = 4.0
	req.lifetime = 2.0
	req.owner_layer = Layers.PLAYER
	req.hit_mask = Layers.ENEMY
	bullets.spawn(req)
	for _i in 20:
		bullets.step(DT)


func _one_summon(elite: EliteEnemy) -> RegularEnemy:
	for body: RegularEnemy in elite.get_parent().get_children():
		if body != null and body != elite and body != room.escort and body.is_alive() and body is SummonAdd:
			return body
	return null


func _freeze(host: SliceRoomD) -> void:
	for child: Node in host.get_children():
		child.set_physics_process(false)


func _discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
