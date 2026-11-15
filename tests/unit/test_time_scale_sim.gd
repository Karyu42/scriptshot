extends GutTest
## Time stop applied to bullets (GD and native) and to enemy / Herald timers.
## Player movement, regen and player shots stay unscaled.

const DT := 1.0 / 60.0


func before_each() -> void:
	TimeControl.cancel()
	TimeControl.set_process(false)
	Engine.time_scale = 1.0


func after_each() -> void:
	TimeControl.cancel()
	TimeControl.set_process(true)
	Engine.time_scale = 1.0


func _manager(preference: String) -> BulletManager:
	var mgr := BulletManager.new()
	mgr.backend_preference = preference
	mgr.capacity = 64
	mgr.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	mgr.render_enabled = false
	mgr.auto_step = false
	add_child_autofree(mgr)
	return mgr


func _fire(mgr: BulletManager, owner: int, pos: Vector2, vel: Vector2, pierce_invuln: bool = false) -> int:
	var req := ShotRequest.new()
	req.reset()
	req.position = pos
	req.velocity = vel
	req.lifetime = 5.0
	req.radius = 4.0
	req.owner_layer = owner
	req.hit_mask = Layers.hostile_to(owner)
	req.pierces_script_invuln = pierce_invuln
	return mgr.spawn(req)


func test_gdscript_backend_scales_enemy_and_null_but_not_player_shots() -> void:
	_assert_bullet_scales("gdscript")


func test_native_backend_matches_gdscript_bullet_scales() -> void:
	var probe := _manager("native")
	if probe.backend != "native":
		pending("native backend is not available in this tree")
		return
	_assert_bullet_scales("native")


func _assert_bullet_scales(preference: String) -> void:
	var mgr := _manager(preference)
	_fire(mgr, Layers.PLAYER, Vector2(0, 0), Vector2(600, 0))
	_fire(mgr, Layers.ENEMY, Vector2(0, 40), Vector2(600, 0))
	_fire(mgr, Layers.ENEMY, Vector2(0, 80), Vector2(600, 0), true)
	TimeControl.request(0.0, 2.0)
	for _i in 10:
		mgr.step(DT)
	# Player: full 10 * 600 / 60 = 100 px. Enemy: frozen. Null: 0.5 * 100 = 50.
	# Plain native bullets live in the sim, not the GDScript pool; snapshot
	# lists native shots first, in spawn order.
	@warning_ignore_start("unsafe_cast")
	var positions: PackedVector2Array = mgr.snapshot()["pos"]
	@warning_ignore_restore("unsafe_cast")
	assert_eq(positions.size(), 3, "%s three live shots" % preference)
	assert_almost_eq(positions[0].x, 100.0, 0.05, "%s player shot unscaled" % preference)
	assert_almost_eq(positions[1].x, 0.0, 0.05, "%s enemy shot frozen at scale 0" % preference)
	assert_almost_eq(positions[2].x, 50.0, 0.05, "%s Null shot at max(0, 0.5)" % preference)


func test_enemy_movement_freezes_while_the_player_still_moves() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	# Outside WorldGen.SAFE_RADIUS so a zero-length chase step is not pushed
	# out of the spawn disk (that push does not use delta).
	player.global_position = Vector2(2000, 0)
	player.aim_direction = Vector2.RIGHT
	player.set_physics_process(false)
	var enemy: RegularEnemy = (load("res://scenes/regular_enemy.tscn") as PackedScene).instantiate()
	add_child_autofree(enemy)
	enemy.player = player
	enemy.global_position = Vector2(2400, 0)
	enemy.woken = true
	enemy.set_physics_process(false)
	TimeControl.request(0.0, 2.0)
	var enemy_start := enemy.global_position
	var player_start := player.global_position
	assert_true(player.try_dash(Vector2.RIGHT))
	for _i in 10:
		player._physics_process(DT)
		enemy._physics_process(DT)
	assert_gt(player.global_position.x - player_start.x, 50.0, "player dash still moves")
	assert_almost_eq(enemy.global_position.x, enemy_start.x, 0.05, "enemy frozen")


func test_player_regen_is_not_scaled() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	player.health.hp = 1.0
	player.health.regen_delay = 0.0
	player.health.regen_interval = 0.2
	player.health.regen_amount = 1.0
	TimeControl.request(0.0, 2.0)
	player.health.tick(0.25)
	assert_gt(player.health.hp, 1.0)


func test_herald_timer_is_scaled() -> void:
	var director := HeraldDirector.new()
	add_child_autofree(director)
	director.set_physics_process(false)
	director.delay = 1.0
	director.counting = true
	TimeControl.request(0.0, 2.0)
	director._physics_process(1.0)
	assert_eq(director.elapsed, 0.0, "Herald clock frozen at scale 0")
	TimeControl.cancel()
	director._physics_process(1.0)
	assert_almost_eq(director.elapsed, 1.0, 0.0001)


func test_null_telegraph_uses_the_floor_while_the_caster_freezes() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	player.global_position = Vector2(100, 0)
	player.set_physics_process(false)
	var sniper: Sniper = (load("res://scenes/sniper.tscn") as PackedScene).instantiate()
	add_child_autofree(sniper)
	sniper.player = player
	sniper.global_position = Vector2.ZERO
	sniper.woken = true
	NullAttacks.configure_caster(sniper)
	sniper.time_scale_floor = 0.0
	sniper.set_physics_process(false)
	sniper._lock = player.global_position
	sniper._windup = sniper.WINDUP
	TimeControl.request(0.0, 2.0)
	var start := sniper.global_position
	for _i in 24:
		sniper._physics_process(DT)
	assert_almost_eq(sniper.global_position.x, start.x, 0.05)
	assert_almost_eq(sniper._windup, sniper.WINDUP - 0.4 * 0.5, 0.02)
	assert_eq(sniper.telegraph_time_scale_floor, TimeControl.NULL_TIME_SCALE_FLOOR)


class _DtProbe:
	extends BulletBehavior
	var last_dt := -1.0

	func on_update(_pool: BulletPool, _i: int, d: float) -> void:
		last_dt = d


class _BatchDtProbe:
	extends BulletBehavior
	var last_dt := -1.0
	var dts: Array[float] = []

	func _init() -> void:
		update_mode = UpdateMode.BATCH

	func on_update_batch(batch: BatchView) -> void:
		last_dt = batch.dt
		dts.append(batch.dt)


func test_gdscript_hooks_scale_enemy_and_null_but_not_player_dt() -> void:
	_assert_hook_dts("gdscript")


func test_native_hooks_scale_enemy_and_null_but_not_player_dt() -> void:
	var probe := _manager("native")
	if probe.backend != "native":
		pending("native backend is not available in this tree")
		return
	_assert_hook_dts("native")


func _assert_hook_dts(preference: String) -> void:
	var mgr := _manager(preference)
	var player_hook := _DtProbe.new()
	var enemy_hook := _DtProbe.new()
	var null_hook := _DtProbe.new()
	var player_id := mgr.register_behavior(player_hook)
	var enemy_id := mgr.register_behavior(enemy_hook)
	var null_id := mgr.register_behavior(null_hook)
	_fire_hooked(mgr, player_id, Layers.PLAYER, Vector2(0, 0), Vector2(60, 0), false)
	_fire_hooked(mgr, enemy_id, Layers.ENEMY, Vector2(0, 40), Vector2(60, 0), false)
	_fire_hooked(mgr, null_id, Layers.ENEMY, Vector2(0, 80), Vector2(60, 0), true)
	TimeControl.request(0.0, 2.0)
	mgr.step(DT)
	assert_almost_eq(player_hook.last_dt, DT, 0.0001, "%s player hook dt unscaled" % preference)
	assert_almost_eq(enemy_hook.last_dt, 0.0, 0.0001, "%s enemy hook dt frozen" % preference)
	assert_almost_eq(null_hook.last_dt, DT * 0.5, 0.0001, "%s Null hook dt at the 0.5 floor" % preference)
	TimeControl.cancel()
	mgr.step(DT)
	assert_almost_eq(player_hook.last_dt, DT, 0.0001, "%s inactive player hook dt" % preference)
	assert_almost_eq(enemy_hook.last_dt, DT, 0.0001, "%s inactive enemy hook dt" % preference)
	assert_almost_eq(null_hook.last_dt, DT, 0.0001, "%s inactive Null hook dt" % preference)


func test_gdscript_batch_hooks_scale_enemy_and_null_but_not_player_dt() -> void:
	_assert_batch_dts("gdscript")


func test_native_batch_hooks_scale_enemy_and_null_but_not_player_dt() -> void:
	var probe := _manager("native")
	if probe.backend != "native":
		pending("native backend is not available in this tree")
		return
	_assert_batch_dts("native")


func _assert_batch_dts(preference: String) -> void:
	var mgr := _manager(preference)
	var player_b := _BatchDtProbe.new()
	var enemy_b := _BatchDtProbe.new()
	var null_b := _BatchDtProbe.new()
	var player_id := mgr.register_behavior(player_b)
	var enemy_id := mgr.register_behavior(enemy_b)
	var null_id := mgr.register_behavior(null_b)
	_fire_hooked(mgr, player_id, Layers.PLAYER, Vector2(0, 0), Vector2(60, 0), false)
	_fire_hooked(mgr, enemy_id, Layers.ENEMY, Vector2(0, 40), Vector2(60, 0), false)
	_fire_hooked(mgr, null_id, Layers.ENEMY, Vector2(0, 80), Vector2(60, 0), true)
	TimeControl.request(0.0, 2.0)
	mgr.step(DT)
	assert_almost_eq(player_b.last_dt, DT, 0.0001, "%s player batch dt unscaled" % preference)
	assert_almost_eq(enemy_b.last_dt, 0.0, 0.0001, "%s enemy batch dt frozen" % preference)
	assert_almost_eq(null_b.last_dt, DT * 0.5, 0.0001, "%s Null batch dt at the 0.5 floor" % preference)


func test_mixed_owner_batch_is_split_by_dt() -> void:
	var mgr := _manager("gdscript")
	var probe := _BatchDtProbe.new()
	var id := mgr.register_behavior(probe)
	_fire_hooked(mgr, id, Layers.PLAYER, Vector2(0, 0), Vector2(60, 0), false)
	_fire_hooked(mgr, id, Layers.ENEMY, Vector2(0, 40), Vector2(60, 0), false)
	TimeControl.request(0.0, 2.0)
	mgr.step(DT)
	assert_eq(probe.dts.size(), 2, "mixed player/enemy batch is invoked once per dt")
	probe.dts.sort()
	assert_almost_eq(probe.dts[0], 0.0, 0.0001)
	assert_almost_eq(probe.dts[1], DT, 0.0001)


func _fire_hooked(
	mgr: BulletManager,
	behavior_id: int,
	owner: int,
	pos: Vector2,
	vel: Vector2,
	pierce_invuln: bool,
) -> int:
	var req := ShotRequest.new()
	req.reset()
	req.position = pos
	req.velocity = vel
	req.lifetime = 5.0
	req.radius = 4.0
	req.owner_layer = owner
	req.hit_mask = Layers.hostile_to(owner)
	req.pierces_script_invuln = pierce_invuln
	req.behavior_id = behavior_id
	return mgr.spawn(req)


func test_lesson_pad_windup_is_scaled() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	await wait_physics_frames(1)
	player.global_position = LessonPad.WORLD_RECT.position + Vector2(80, 80)
	assert_almost_eq(player.health.hp, 5.0, 0.0001)
	var pad := LessonPad.new()
	pad.player = player
	add_child_autofree(pad)
	pad.tick(0.0)
	assert_true(pad.is_winding())
	TimeControl.request(0.0, 2.0)
	pad.tick(LessonPad.WINDUP)
	assert_true(pad.is_winding(), "lesson-pad windup freezes at scale 0")
	assert_almost_eq(player.health.hp, 5.0, 0.0001)
	TimeControl.cancel()
	pad.tick(LessonPad.WINDUP)
	assert_false(pad.is_winding())
	assert_almost_eq(player.health.hp, 4.0, 0.0001)


func test_null_shot_affix_uses_the_floor_and_stamps_the_shot() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	player.global_position = Vector2(2200, 0)
	player.set_physics_process(false)
	var mgr := _manager("gdscript")
	var elite: EliteEnemy = (load("res://scenes/elite_enemy.tscn") as PackedScene).instantiate()
	add_child_autofree(elite)
	elite.configure_elite(
		AffixCatalog.NULL_SHOT,
		Vector2(2000, 0),
		Vector2(2000, 0),
		1,
		player,
		false,
	)
	elite.bullets = mgr
	elite.woken = true
	elite.set_physics_process(false)
	elite.start_null_shot_telegraph()
	TimeControl.request(0.0, 3.0)
	var start := elite.global_position
	for _i in 24:
		elite._physics_process(DT)
	assert_almost_eq(elite.global_position.x, start.x, 0.05, "Null-shot body stays frozen")
	assert_almost_eq(elite._null_windup, NullAttacks.SHOT_TELEGRAPH - 0.4 * 0.5, 0.02)
	assert_eq(_live_shot_count(mgr), 0)
	var guard := 0
	while elite._null_windup >= 0.0 and guard < 200:
		elite._physics_process(DT)
		guard += 1
	assert_eq(elite._null_windup, -1.0)
	assert_eq(_live_shot_count(mgr), 1, "Null-shot affix fires through NullAttacks")
	assert_true(_shot_is_null(mgr, _first_live_id(mgr)))


func test_legendary_null_ring_uses_the_floor() -> void:
	var player: Player = (load("res://scenes/player.tscn") as PackedScene).instantiate()
	add_child_autofree(player)
	player.global_position = Vector2(0, 0)
	player.set_physics_process(false)
	var mgr := _manager("gdscript")
	var warden := Warden.new()
	add_child_autofree(warden)
	warden.global_position = Vector2(400, 0)
	warden.set_physics_process(false)
	warden.bind(player, mgr)
	var ids := warden.fire_legendary_null_ring()
	assert_eq(ids.size(), NullAttacks.RING_DOTS)
	for i in ids.size():
		assert_true(_shot_is_null(mgr, ids[i]), "legendary ring shot %d is stamped Null" % i)
	@warning_ignore_start("unsafe_cast")
	var before: PackedVector2Array = mgr.snapshot()["pos"]
	@warning_ignore_restore("unsafe_cast")
	TimeControl.request(0.0, 2.0)
	for _i in 10:
		mgr.step(DT)
	@warning_ignore_start("unsafe_cast")
	var after: PackedVector2Array = mgr.snapshot()["pos"]
	@warning_ignore_restore("unsafe_cast")
	assert_eq(after.size(), before.size())
	var expected := NullAttacks.RING_SPEED * DT * 10.0 * 0.5
	assert_almost_eq(after[0].distance_to(before[0]), expected, 0.05)


func _live_shot_count(mgr: BulletManager) -> int:
	var n := 0
	for i in mgr.pool.count:
		if mgr.pool.dead_reason[i] == 0:
			n += 1
	if mgr.native != null:
		n += mgr.native.count()
	return n


func _shot_is_null(mgr: BulletManager, handle: int) -> bool:
	# BulletManager.spawn returns a pool slot on the GDScript backend and a
	# stable native id (bit 62 set) when the shot landed in the sim.
	if handle < 0:
		return false
	if handle < mgr.pool.count and mgr.pool.dead_reason[handle] == 0:
		return mgr.pool.pierces_script_invuln[handle] != 0
	var slot := mgr.pool.slot_of(handle)
	if slot >= 0:
		return mgr.pool.pierces_script_invuln[slot] != 0
	if mgr.native != null:
		return (mgr.native.source_flags_of(handle) & Health.SOURCE_PIERCES_SCRIPT_INVULN) != 0
	return false


func _first_live_id(mgr: BulletManager) -> int:
	for i in mgr.pool.count:
		if mgr.pool.dead_reason[i] == 0:
			return mgr.pool.id_of(i)
	if mgr.native != null and mgr.native.count() > 0:
		return mgr.native.id_of_slot(0)
	return -1


class _MidStepRequester:
	extends BulletBehavior
	var dts: Array[float] = []
	var requested := false

	func on_update(_pool: BulletPool, _i: int, d: float) -> void:
		dts.append(d)
		if not requested:
			requested = true
			TimeControl.request(0.0, 2.0)


class _MidStepObserver:
	extends BulletBehavior
	var dts: Array[float] = []

	func on_update(_pool: BulletPool, _i: int, d: float) -> void:
		dts.append(d)


class _MidStepBatchRequester:
	extends BulletBehavior
	var dts: Array[float] = []
	var requested := false

	func _init() -> void:
		update_mode = UpdateMode.BATCH

	func on_update_batch(batch: BatchView) -> void:
		dts.append(batch.dt)
		if not requested:
			requested = true
			TimeControl.request(0.0, 2.0)


class _MidStepBatchObserver:
	extends BulletBehavior
	var dts: Array[float] = []

	func _init() -> void:
		update_mode = UpdateMode.BATCH

	func on_update_batch(batch: BatchView) -> void:
		dts.append(batch.dt)


func test_gdscript_mid_step_request_in_hook_applies_next_tick() -> void:
	_assert_mid_step_hook("gdscript")


func test_native_mid_step_request_in_hook_applies_next_tick() -> void:
	var probe := _manager("native")
	if probe.backend != "native":
		pending("native backend is not available in this tree")
		return
	_assert_mid_step_hook("native")


func _assert_mid_step_hook(preference: String) -> void:
	var mgr := _manager(preference)
	var requester := _MidStepRequester.new()
	var observer := _MidStepObserver.new()
	var req_id := mgr.register_behavior(requester)
	var obs_id := mgr.register_behavior(observer)
	_fire_hooked(mgr, req_id, Layers.ENEMY, Vector2(0, 0), Vector2(600, 0), false)
	_fire_hooked(mgr, obs_id, Layers.ENEMY, Vector2(0, 40), Vector2(600, 0), false)
	assert_false(TimeControl.is_active())
	mgr.step(DT)
	assert_true(TimeControl.is_active(), "%s request in the first hook took effect" % preference)
	assert_eq(requester.dts.size(), 1)
	assert_eq(observer.dts.size(), 1)
	assert_almost_eq(requester.dts[0], DT, 0.0001, "%s requesting hook still saw the precomputed dt" % preference)
	assert_almost_eq(observer.dts[0], DT, 0.0001, "%s later hook this tick kept the old dt" % preference)
	var xs := _snapshot_xs(mgr)
	assert_eq(xs.size(), 2, "%s two live shots after the request tick" % preference)
	assert_almost_eq(xs[0], 10.0, 0.05, "%s requester already integrated with the old dt" % preference)
	assert_almost_eq(xs[1], 10.0, 0.05, "%s observer already integrated with the old dt" % preference)
	mgr.step(DT)
	assert_eq(requester.dts.size(), 2)
	assert_eq(observer.dts.size(), 2)
	assert_almost_eq(requester.dts[1], 0.0, 0.0001, "%s next tick uses the new dt" % preference)
	assert_almost_eq(observer.dts[1], 0.0, 0.0001, "%s next tick observer uses the new dt" % preference)
	xs = _snapshot_xs(mgr)
	assert_almost_eq(xs[0], 10.0, 0.05, "%s no further move on the next tick" % preference)
	assert_almost_eq(xs[1], 10.0, 0.05, "%s observer frozen on the next tick" % preference)


func test_gdscript_mid_step_request_in_batch_hook_applies_next_tick() -> void:
	_assert_mid_step_batch("gdscript")


func test_native_mid_step_request_in_batch_hook_applies_next_tick() -> void:
	var probe := _manager("native")
	if probe.backend != "native":
		pending("native backend is not available in this tree")
		return
	_assert_mid_step_batch("native")


func _assert_mid_step_batch(preference: String) -> void:
	var mgr := _manager(preference)
	var requester := _MidStepBatchRequester.new()
	var observer := _MidStepBatchObserver.new()
	var req_id := mgr.register_behavior(requester)
	var obs_id := mgr.register_behavior(observer)
	_fire_hooked(mgr, req_id, Layers.ENEMY, Vector2(0, 0), Vector2(600, 0), false)
	_fire_hooked(mgr, obs_id, Layers.ENEMY, Vector2(0, 40), Vector2(600, 0), false)
	assert_false(TimeControl.is_active())
	mgr.step(DT)
	assert_true(TimeControl.is_active(), "%s request in the first batch hook took effect" % preference)
	assert_eq(requester.dts.size(), 1)
	assert_eq(observer.dts.size(), 1)
	assert_almost_eq(requester.dts[0], DT, 0.0001, "%s requesting batch still saw the precomputed dt" % preference)
	assert_almost_eq(observer.dts[0], DT, 0.0001, "%s later batch this tick kept the old dt" % preference)
	var xs := _snapshot_xs(mgr)
	assert_eq(xs.size(), 2, "%s two live shots after the request tick" % preference)
	assert_almost_eq(xs[0], 10.0, 0.05, "%s requester already integrated with the old dt" % preference)
	assert_almost_eq(xs[1], 10.0, 0.05, "%s observer already integrated with the old dt" % preference)
	mgr.step(DT)
	assert_eq(requester.dts.size(), 2)
	assert_eq(observer.dts.size(), 2)
	assert_almost_eq(requester.dts[1], 0.0, 0.0001, "%s next tick uses the new dt" % preference)
	assert_almost_eq(observer.dts[1], 0.0, 0.0001, "%s next tick observer uses the new dt" % preference)
	xs = _snapshot_xs(mgr)
	assert_almost_eq(xs[0], 10.0, 0.05, "%s no further move on the next tick" % preference)
	assert_almost_eq(xs[1], 10.0, 0.05, "%s observer frozen on the next tick" % preference)


func _snapshot_xs(mgr: BulletManager) -> PackedFloat32Array:
	@warning_ignore_start("unsafe_cast")
	var positions: PackedVector2Array = mgr.snapshot()["pos"]
	@warning_ignore_restore("unsafe_cast")
	var xs := PackedFloat32Array()
	xs.resize(positions.size())
	for i in positions.size():
		xs[i] = positions[i].x
	return xs

