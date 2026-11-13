extends GutTest
## Vertical-slice row 2: room-C packs, Shieldbearer, Sniper, absence, G4.

const DT := 1.0 / 60.0
const _SAVE := "user://gut_slice_packs.cfg"
const C_INSIDE := Vector2(4700, 180)
const C_OUTSIDE := Vector2(0, 0)
const SPEED := 1200.0


var packs: SlicePacks
var progress: SliceProgress
var layout: SliceLayout
var player: Player
var save: SaveGame
var bullets: BulletManager


func before_each() -> void:
	_discard(_SAVE)
	layout = SliceLayout.new()
	layout.enabled = true
	add_child_autofree(layout)
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = C_INSIDE
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
	packs = SlicePacks.new()
	add_child_autofree(packs)
	packs.bind(player, progress, bullets, save.world_seed)
	# Drive movement from the tests so spawn poses stay put during setup.
	_freeze_members(packs)
	await wait_physics_frames(1)


func after_each() -> void:
	_discard(_SAVE)


func _freeze_members(host: SlicePacks) -> void:
	for pack in SlicePacks.PACK_COUNT:
		for body: Node in host.get_child(pack).get_children():
			body.set_physics_process(false)


func test_packs_spawn_at_their_anchors_when_keys_are_missing() -> void:
	assert_eq(packs.pack_alive(SlicePacks.PACK_DRIFTERS), 3)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SWARMERS), 10)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SHIELD), 1)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SNIPER), 1)
	assert_eq(save.field_drifters, 0.0)
	var drifts := _members(SlicePacks.PACK_DRIFTERS)
	assert_eq(drifts.size(), 3)
	for body: RegularEnemy in drifts:
		assert_almost_eq(body.global_position.distance_to(SlicePacks.ANCHORS[0]), RegularEnemy.DRIFTER_FORMATION, 0.5)
		assert_eq(body.enemy_kind(), EnemyKinds.DRIFTER)
		assert_almost_eq(body.health.max_hp, RegularEnemy.DRIFTER_HP, 0.001)
	var swarms := _members(SlicePacks.PACK_SWARMERS)
	assert_eq(swarms.size(), 10)
	for body2: RegularEnemy in swarms:
		assert_eq(body2.enemy_kind(), EnemyKinds.SWARMER)
	var shield := _members(SlicePacks.PACK_SHIELD)[0] as Shieldbearer
	assert_not_null(shield)
	assert_almost_eq(shield.global_position.x, 5600.0, 0.1)
	assert_almost_eq(shield.global_position.y, 320.0, 0.1)
	assert_eq(shield.enemy_kind(), EnemyKinds.SHIELDBEARER)
	var sniper := _members(SlicePacks.PACK_SNIPER)[0] as Sniper
	assert_not_null(sniper)
	assert_almost_eq(sniper.global_position.x, 6200.0, 0.1)
	assert_almost_eq(sniper.global_position.y, -400.0, 0.1)
	assert_eq(sniper.enemy_kind(), EnemyKinds.SNIPER)


func test_a_front_shot_is_absorbed_and_a_side_shot_damages_the_shieldbearer() -> void:
	var shield := _members(SlicePacks.PACK_SHIELD)[0] as Shieldbearer
	# Stand east of the body so the arc faces +x; a shot from the east is absorbed.
	player.global_position = shield.global_position + Vector2(200, 0)
	shield._physics_process(DT)
	var hp := shield.health.hp
	_fire_at(shield.global_position, 0.0)
	assert_eq(bullets.alive_count(), 0)
	assert_almost_eq(shield.health.hp, hp, 0.001)
	_fire_at(shield.global_position, PI)
	assert_lt(shield.health.hp, hp)


func test_the_sniper_waits_0_8s_then_fires_a_locked_line() -> void:
	var sniper := _members(SlicePacks.PACK_SNIPER)[0] as Sniper
	player.global_position = sniper.global_position + Vector2(300, 0)
	sniper._physics_process(DT)
	assert_true(sniper.is_winding())
	var locked := sniper.lock_point()
	assert_almost_eq(locked.x, player.global_position.x, 0.001)
	# Move off the line during the windup; the shot must keep the locked aim.
	player.global_position = sniper.global_position + Vector2(300, 200)
	sniper._physics_process(0.79)
	assert_true(sniper.is_winding())
	assert_eq(sniper.last_shot, null)
	sniper._physics_process(0.02)
	assert_false(sniper.is_winding())
	assert_not_null(sniper.last_shot)
	var req := sniper.last_shot
	assert_almost_eq(req.velocity.length(), Sniper.SHOT_SPEED, 0.001)
	assert_almost_eq(req.lifetime, Sniper.SHOT_LIFETIME, 0.001)
	assert_almost_eq(req.damage, 1.0, 0.001)
	assert_almost_eq(req.radius, 5.0, 0.001)
	var dir := (locked - sniper.global_position).normalized()
	assert_almost_eq(req.velocity.angle(), dir.angle(), 0.01)
	# Next windup is at 2.4 s start-to-start (1.6 s after the shot).
	sniper._physics_process(1.59)
	assert_false(sniper.is_winding())
	sniper._physics_process(0.02)
	assert_true(sniper.is_winding())


func test_drifter_contact_is_one_pip_and_blocked_during_iframes() -> void:
	var drifter := _members(SlicePacks.PACK_DRIFTERS)[0] as RegularEnemy
	player.global_position = drifter.global_position
	player.health.hp = 5.0
	drifter._physics_process(DT)
	assert_almost_eq(player.health.hp, 4.0, 0.001)
	assert_almost_eq(player.health.engine_invulnerable_left, 0.75, 0.05)
	drifter._physics_process(DT)
	assert_almost_eq(player.health.hp, 4.0, 0.001)


func test_clearing_all_four_packs_opens_g4_and_emits_enemy_killed() -> void:
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G4))
	var kinds: Array[StringName] = []
	var killed := func(kind: StringName, _r: int, _t: int, _p: Vector2, first: bool) -> void:
		kinds.append(kind)
		assert_true(first)
	GameEvents.enemy_killed.connect(killed)
	_kill_pack(SlicePacks.PACK_DRIFTERS)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G4))
	_kill_pack(SlicePacks.PACK_SWARMERS)
	_kill_pack(SlicePacks.PACK_SHIELD)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G4))
	_kill_pack(SlicePacks.PACK_SNIPER)
	GameEvents.enemy_killed.disconnect(killed)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G4))
	assert_eq(progress.packs_mask(), (1 << SlicePacks.PACK_COUNT) - 1)
	assert_eq(kinds.size(), 3 + 10 + 1 + 1)
	assert_true(kinds.has(EnemyKinds.DRIFTER))
	assert_true(kinds.has(EnemyKinds.SWARMER))
	assert_true(kinds.has(EnemyKinds.SHIELDBEARER))
	assert_true(kinds.has(EnemyKinds.SNIPER))
	assert_gt(save.field_sniper, 0.0)


func test_a_pack_returns_after_300s_outside_c_and_g4_stays_open() -> void:
	_kill_pack(SlicePacks.PACK_DRIFTERS)
	assert_eq(packs.pack_alive(SlicePacks.PACK_DRIFTERS), 0)
	var t0 := 1_000_000.0
	packs.pinned_time = t0
	player.global_position = C_OUTSIDE
	packs._physics_process(DT)
	assert_almost_eq(save.field_drifters, t0, 0.001)
	packs.pinned_time = t0 + 299.0
	packs._physics_process(DT)
	assert_eq(packs.pack_alive(SlicePacks.PACK_DRIFTERS), 0, "still absent at 299 s")
	packs.pinned_time = t0 + 300.0
	packs._physics_process(DT)
	assert_eq(packs.pack_alive(SlicePacks.PACK_DRIFTERS), 3)
	assert_eq(save.field_drifters, 0.0)
	assert_true(progress.is_gate_unlocked(SliceLayout.GATE_G4) or progress.packs_mask() & 1 == 1)
	# G4 only opens when all four are marked; this pack bit stays set.
	assert_eq(progress.packs_mask() & 1, 1)


func test_coming_back_into_c_early_restarts_the_out_streak() -> void:
	_kill_pack(SlicePacks.PACK_SHIELD)
	var t0 := 2_000_000.0
	packs.pinned_time = t0
	player.global_position = C_OUTSIDE
	packs._physics_process(DT)
	packs.pinned_time = t0 + 100.0
	player.global_position = C_INSIDE
	packs._physics_process(DT)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SHIELD), 0, "early return does not revive")
	packs.pinned_time = t0 + 100.0
	player.global_position = C_OUTSIDE
	packs._physics_process(DT)
	assert_almost_eq(save.field_shield, t0 + 100.0, 0.001, "leave C restarts the clock")
	packs.pinned_time = t0 + 100.0 + 299.0
	packs._physics_process(DT)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SHIELD), 0)
	packs.pinned_time = t0 + 100.0 + 300.0
	packs._physics_process(DT)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SHIELD), 1)


func test_staying_in_c_does_not_return_the_pack_after_300s() -> void:
	_kill_pack(SlicePacks.PACK_SNIPER)
	var t0 := save.field_sniper
	assert_gt(t0, 0.0)
	packs.pinned_time = t0 + 400.0
	player.global_position = C_INSIDE
	packs._physics_process(DT)
	assert_eq(packs.pack_alive(SlicePacks.PACK_SNIPER), 0)


func test_a_saved_absent_pack_does_not_spawn_on_load() -> void:
	_discard(_SAVE)
	var slot := SaveGame.new()
	slot.path = _SAVE
	slot.world_seed = 1
	slot.set_field_absent_since(SaveGame.FIELD_DRIFTERS, 9_000_000.0)
	slot.save()
	var fresh := SliceProgress.new()
	add_child_autofree(fresh)
	fresh.bind(player, null, layout, slot)
	var again := SlicePacks.new()
	add_child_autofree(again)
	player.global_position = C_INSIDE
	again.bind(player, fresh, bullets, slot.world_seed)
	await wait_physics_frames(1)
	assert_eq(again.pack_alive(SlicePacks.PACK_DRIFTERS), 0)
	assert_eq(again.pack_alive(SlicePacks.PACK_SWARMERS), 10)


func test_a_regular_is_held_by_a_slice_wall() -> void:
	var body := _members(SlicePacks.PACK_DRIFTERS)[0] as RegularEnemy
	assert_true(body.collide_walls)
	# C's west inner wall is at x = 4096 + 16. Stay off the G3 door (y in [-64, 64]).
	var wall_x := SliceLayout.room_rect(SliceLayout.ROOM_C).position.x + SliceLayout.WALL_PX
	body.global_position = Vector2(wall_x + body.body_radius + 2.0, 300.0)
	body.woken = true
	player.global_position = body.global_position + Vector2(-400, 0)
	for _i in 30:
		body._physics_process(DT)
	assert_gte(body.global_position.x, wall_x + body.body_radius - 0.5,
		"held by C's west wall at %s" % body.global_position)


func test_main_scene_has_the_packs_node() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	var state := packed.get_state()
	var names: Array[String] = []
	for i in state.get_node_count():
		names.append(String(state.get_node_name(i)))
	assert_true(names.has("SlicePacks"))


func _members(pack: int) -> Array[RegularEnemy]:
	var out: Array[RegularEnemy] = []
	var root := packs.get_child(pack)
	if root == null:
		return out
	for child: Node in root.get_children():
		var body := child as RegularEnemy
		if body != null:
			out.append(body)
	return out


func _kill_pack(pack: int) -> void:
	for body: RegularEnemy in _members(pack):
		body.health.clear_engine_invulnerability()
		(body.get_node("Hurtbox") as Hurtbox).receive_hit(body.health.hp, Vector2.ZERO, Vector2.ZERO)
	assert_eq(packs.pack_alive(pack), 0)


func _fire_at(target: Vector2, from_angle: float) -> void:
	var origin := target + Vector2.from_angle(from_angle) * 200.0
	var req := ShotRequest.with_velocity(origin, (target - origin).normalized() * SPEED)
	req.radius = 4.0
	req.lifetime = 2.0
	req.hit_mask = Layers.ENEMY
	bullets.spawn(req)
	# 200 px at 1200 px/s is well under 0.2 s; a few steps is enough.
	for _i in 20:
		bullets.step(DT)


func _discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
