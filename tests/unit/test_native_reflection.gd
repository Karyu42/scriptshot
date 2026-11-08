extends GutTest
## Native reflection and wall normals against the GDScript pool.
## Pending when NativeBulletSim is not built.

const DT := 1.0 / 60.0
const POS_EPS := 0.05
const VEL_EPS := 0.05


func _ready_native() -> bool:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return false
	return true


func _manager(preference: String) -> BulletManager:
	var created := BulletManager.new()
	created.backend_preference = preference
	created.capacity = 64
	created.logical_cap = 64
	created.enemy_reserve = 0
	created.world_bounds = Rect2(-800, -800, 1600, 1600)
	created.render_enabled = false
	created.auto_step = false
	add_child(created)
	return created


func _close(created: BulletManager) -> void:
	remove_child(created)
	created.free()


func _shot(at: Vector2, velocity: Vector2, pierce: int = 0) -> ShotRequest:
	var req := ShotRequest.with_velocity(at, velocity)
	req.radius = 2.0
	req.lifetime = 4.0
	req.hit_mask = Layers.ENEMY
	req.pierce = pierce
	req.owner_layer = Layers.PLAYER
	req.damage = 5.0
	req.collide_world = true
	return req


func _rows(created: BulletManager) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if created.native != null and created.native.count() > 0:
		var snap := created.native.snapshot()
		var pos: PackedVector2Array = snap["pos"]
		var vel: PackedVector2Array = snap["vel"]
		var owners: PackedInt32Array = snap["owner"]
		var pierce: PackedInt32Array = snap["pierce"]
		var reflects: PackedInt32Array = snap["reflect_count"]
		var masks: PackedInt32Array = snap["hit_mask"]
		var seqs: PackedInt32Array = snap["seq"]
		for i in pos.size():
			rows.append({
				"seq": seqs[i], "pos": pos[i], "vel": vel[i], "owner": owners[i],
				"pierce": pierce[i], "reflects": reflects[i], "mask": masks[i],
			})
	for i in created.pool.count:
		if created.pool.dead_reason[i] != 0:
			continue
		rows.append({
			"seq": created.pool.seq[i], "pos": created.pool.pos[i], "vel": created.pool.vel[i],
			"owner": created.pool.owner_layer[i], "pierce": created.pool.pierce[i],
			"reflects": created.pool.reflect_count[i], "mask": created.pool.hit_mask[i],
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa: int = a["seq"]
		var sb: int = b["seq"]
		return sa < sb)
	return rows


func _assert_rows(native_rows: Array[Dictionary], gd_rows: Array[Dictionary], where: String) -> void:
	assert_eq(native_rows.size(), gd_rows.size(), "%s alive" % where)
	for i in gd_rows.size():
		var a: Dictionary = gd_rows[i]
		var b: Dictionary = native_rows[i]
		var pa: Vector2 = a["pos"]
		var pb: Vector2 = b["pos"]
		var va: Vector2 = a["vel"]
		var vb: Vector2 = b["vel"]
		assert_lt(pa.distance_to(pb), POS_EPS, "%s bullet %d pos %s vs %s" % [where, i, pa, pb])
		assert_lt(va.distance_to(vb), VEL_EPS, "%s bullet %d vel %s vs %s" % [where, i, va, vb])
		var ao: int = a["owner"]
		var bo: int = b["owner"]
		var ap: int = a["pierce"]
		var bp: int = b["pierce"]
		var ar: int = a["reflects"]
		var br: int = b["reflects"]
		var am: int = a["mask"]
		var bm: int = b["mask"]
		assert_eq(bo, ao, "%s owner" % where)
		assert_eq(bp, ap, "%s pierce" % where)
		assert_eq(br, ar, "%s reflect count" % where)
		assert_eq(bm, am, "%s hit mask" % where)


func _mirror(at: Vector2, radius: float, mode: Reflector.Mode = Reflector.Mode.REVERSE) -> Reflector:
	var zone := Reflector.new()
	zone.position = at
	zone.radius = radius
	zone.mode = mode
	add_child(zone)
	return zone


# --- wall normals, the same rules as WallGrid.box_normal -------------------------

func test_wall_normals_match_wall_grid() -> void:
	if not _ready_native():
		return
	var created := _manager("native")
	var grid := WallGrid.new(created.world_bounds, created.cell_size)
	created.add_wall(Rect2(100, -50, 100, 100))
	grid.add_wall(Rect2(100, -50, 100, 100))
	var cases: Array[Dictionary] = [
		{"s": Vector2(-200, 0), "d": Vector2(400, 0), "r": 0.0, "n": Vector2.LEFT},
		{"s": Vector2(400, 0), "d": Vector2(-400, 0), "r": 0.0, "n": Vector2.RIGHT},
		{"s": Vector2(150, -200), "d": Vector2(0, 400), "r": 0.0, "n": Vector2.UP},
		{"s": Vector2(150, 200), "d": Vector2(0, -400), "r": 0.0, "n": Vector2.DOWN},
		{"s": Vector2(0, -20), "d": Vector2(200, 30), "r": 0.0, "n": Vector2.LEFT},
		{"s": Vector2(80, -250), "d": Vector2(60, 400), "r": 0.0, "n": Vector2.UP},
		{"s": Vector2(0, -3), "d": Vector2(200, 0), "r": 4.0, "n": Vector2.LEFT},
		{"s": Vector2(150, -100), "d": Vector2(0, 200), "r": 4.0, "n": Vector2.UP},
	]
	for c: Dictionary in cases:
		var start: Vector2 = c["s"]
		var delta: Vector2 = c["d"]
		var radius: float = c["r"]
		var expect: Vector2 = c["n"]
		grid.first_hit(start, delta, radius)
		assert_eq(grid.last_normal, expect)
		assert_eq(created.native.query_wall_normal(start, delta, radius), grid.last_normal)
	# Clear path leaves a zero normal.
	assert_eq(created.native.query_wall_normal(Vector2(0, 200), Vector2(300, 0), 0.0), Vector2.ZERO)
	_close(created)


func test_corner_and_tie_normals_match_wall_grid() -> void:
	if not _ready_native():
		return
	var created := _manager("native")
	var grid := WallGrid.new(created.world_bounds, created.cell_size)
	created.add_wall(Rect2(100, 100, 50, 50))
	grid.add_wall(Rect2(100, 100, 50, 50))
	grid.first_hit(Vector2.ZERO, Vector2(200, 200), 0.0)
	assert_eq(grid.last_normal, Vector2.LEFT, "exact 45 degree corner prefers x")
	assert_eq(created.native.query_wall_normal(Vector2.ZERO, Vector2(200, 200), 0.0), Vector2.LEFT)
	grid.first_hit(Vector2.ZERO, Vector2(100, 200), 0.0)
	# That segment misses this wall. A taller approach uses a different rect.
	created.add_wall(Rect2(50, 100, 100, 100))
	var tall := WallGrid.new(created.world_bounds, created.cell_size)
	tall.add_wall(Rect2(100, 100, 50, 50))
	tall.add_wall(Rect2(50, 100, 100, 100))
	# The first wall is the 45-degree case above. The second is not this query.
	var corner := WallGrid.new(created.world_bounds, created.cell_size)
	corner.add_wall(Rect2(50, 100, 100, 100))
	corner.first_hit(Vector2.ZERO, Vector2(100, 200), 0.0)
	assert_eq(corner.last_normal, Vector2.UP, "faster axis is y")
	var only := _manager("native")
	only.add_wall(Rect2(50, 100, 100, 100))
	assert_eq(only.native.query_wall_normal(Vector2.ZERO, Vector2(100, 200), 0.0), Vector2.UP)
	# Two walls reached together: the lower index wins.
	var tie_gd := WallGrid.new(created.world_bounds, created.cell_size)
	tie_gd.add_wall(Rect2(100, 0, 50, 50))
	tie_gd.add_wall(Rect2(50, 50, 50, 50))
	tie_gd.first_hit(Vector2.ZERO, Vector2(200, 100), 0.0)
	var tie := _manager("native")
	tie.add_wall(Rect2(100, 0, 50, 50))
	tie.add_wall(Rect2(50, 50, 50, 50))
	assert_eq(tie.native.query_wall_normal(Vector2.ZERO, Vector2(200, 100), 0.0), tie_gd.last_normal)
	# Starts inside: nearest face, ties go left, right, up, down.
	var box := _manager("native")
	box.add_wall(Rect2(-50, -50, 100, 100))
	var inside := WallGrid.new(box.world_bounds, box.cell_size)
	inside.add_wall(Rect2(-50, -50, 100, 100))
	var inside_starts: Array[Vector2] = [Vector2(40, 0), Vector2(-40, 0), Vector2(0, -45), Vector2(0, 45), Vector2.ZERO, Vector2(20, 10)]
	for start in inside_starts:
		var delta := Vector2(5, 0)
		if start == Vector2(0, -45) or start == Vector2(0, 45):
			delta = Vector2(0, 5)
		if start == Vector2.ZERO or start == Vector2(20, 10):
			delta = Vector2.ZERO
		inside.first_hit(start, delta, 0.0)
		assert_eq(box.native.query_wall_normal(start, delta, 0.0), inside.last_normal, "inside %s" % start)
	_close(created)
	_close(only)
	_close(tie)
	_close(box)


class _NormalHook:
	extends BulletBehavior
	var mgr: BulletManager
	var normal := Vector2(9, 9)
	var reason := -1

	func on_despawn(_pool: BulletPool, index: int, reason_: int) -> void:
		reason = reason_
		normal = mgr.wall_normal_of(index)


func test_a_plain_native_wall_death_reports_the_same_normal() -> void:
	if not _ready_native():
		return
	var gd := _manager("gdscript")
	var nat := _manager("native")
	gd.add_wall(Rect2(100, -40, 20, 80))
	nat.add_wall(Rect2(100, -40, 20, 80))
	var hook := _NormalHook.new()
	hook.mgr = gd
	var req := _shot(Vector2(80, 0), Vector2(2400, 0))
	req.behavior_id = gd.register_behavior(hook)
	gd.spawn(req)
	var plain := _shot(Vector2(80, 0), Vector2(2400, 0))
	nat.spawn(plain)
	nat.native.set_record_events(true)
	nat.step(DT)
	gd.step(DT)
	assert_eq(hook.reason, BulletPool.DespawnReason.WALL)
	assert_eq(hook.normal, Vector2.LEFT)
	var logged: Array = nat.native.last_despawns()
	assert_eq(logged.size(), 1)
	var row: Dictionary = logged[0]
	var reason: int = row["reason"]
	var normal: Vector2 = row["normal"]
	assert_eq(reason, BulletPool.DespawnReason.WALL)
	assert_eq(normal, Vector2.LEFT)
	_close(gd)
	_close(nat)


# --- reflection parity ----------------------------------------------------------

func _reflect_pair(cap: int, mode: Reflector.Mode, speed: Vector2, at: Vector2, zone_at: Vector2, ticks: int) -> void:
	var gd := _manager("gdscript")
	var nat := _manager("native")
	gd.pool.max_reflections = cap
	nat.pool.max_reflections = cap
	var pair: Array[BulletManager] = [gd, nat]
	for created in pair:
		_mirror_on(created, zone_at, 40.0, mode)
		created.spawn(_shot(at, speed))
	for tick in ticks:
		gd.step(DT)
		nat.step(DT)
		_assert_rows(_rows(nat), _rows(gd), "tick %d" % tick)
		assert_eq(nat.last_reflect_count, gd.last_reflect_count, "tick %d reflects" % tick)
	_close(gd)
	_close(nat)


func _mirror_on(created: BulletManager, at: Vector2, radius: float, mode: Reflector.Mode) -> Reflector:
	var zone := Reflector.new()
	zone.position = at
	zone.radius = radius
	zone.mode = mode
	created.add_child(zone)
	return zone


func test_reverse_reflection_matches_for_several_ticks() -> void:
	if not _ready_native():
		return
	_reflect_pair(1, Reflector.Mode.REVERSE, Vector2(1800, 0), Vector2(0, 0), Vector2(80, 0), 6)


func test_mirror_reflection_off_grazing_angle_matches() -> void:
	if not _ready_native():
		return
	# Path y=18 through a circle at (80, 0) r=40: a shallow hit, not a head-on reverse.
	_reflect_pair(1, Reflector.Mode.MIRROR, Vector2(1600, 40), Vector2(0, 18), Vector2(80, 0), 4)


func test_tangent_pass_is_not_a_reflection() -> void:
	if not _ready_native():
		return
	var gd := _manager("gdscript")
	var nat := _manager("native")
	var pair: Array[BulletManager] = [gd, nat]
	for created in pair:
		_mirror_on(created, Vector2.ZERO, 40.0, Reflector.Mode.MIRROR)
		# Combined radius is 42. y=48 clears it by a few pixels: a near miss, not a bounce.
		created.spawn(_shot(Vector2(-160, 48), Vector2(2000, 0)))
		created.step(0.12)
	assert_eq(gd.last_reflect_count, 0, "a tangent does not reflect")
	assert_eq(nat.last_reflect_count, 0)
	_assert_rows(_rows(nat), _rows(gd), "tangent")
	_close(gd)
	_close(nat)


func test_speed_is_preserved_and_a_multiplier_scales_it() -> void:
	if not _ready_native():
		return
	var multipliers: Array[float] = [1.0, 2.0]
	for mult in multipliers:
		var gd := _manager("gdscript")
		var nat := _manager("native")
		var pair: Array[BulletManager] = [gd, nat]
		for created in pair:
			var zone := _mirror_on(created, Vector2(60, 0), 30.0, Reflector.Mode.REVERSE)
			zone.speed_multiplier = mult
			created.spawn(_shot(Vector2(0, 0), Vector2(800, 0)))
			created.step(0.1)
		var g := _rows(gd)[0]
		var n := _rows(nat)[0]
		var gv: Vector2 = g["vel"]
		var nv: Vector2 = n["vel"]
		assert_almost_eq(gv.length(), 800.0 * mult, 0.05, "gd speed x%s" % mult)
		assert_almost_eq(nv.length(), gv.length(), 0.05, "native speed x%s" % mult)
		assert_lt(gv.x, 0.0, "it came back")
		_close(gd)
		_close(nat)


func test_max_reflections_boundaries_including_zero() -> void:
	if not _ready_native():
		return
	# Cap 1: the second zone does not turn the bullet again.
	var once_gd := _two_zones("gdscript", 1)
	var once_nat := _two_zones("native", 1)
	assert_eq(once_nat, once_gd)
	assert_eq(once_gd[0], 0, "the second zone is refused")
	assert_eq(once_gd[1], 1, "reflect count stays 1")
	# Cap 0: unlimited. The second zone reflects too.
	var free_gd := _two_zones("gdscript", 0)
	var free_nat := _two_zones("native", 0)
	assert_eq(free_nat, free_gd)
	assert_eq(free_gd[0], 1, "second zone reflected")
	assert_eq(free_gd[1], 2, "reflect count is 2")


func _two_zones(preference: String, cap: int) -> PackedInt32Array:
	var created := _manager(preference)
	created.pool.max_reflections = cap
	_mirror_on(created, Vector2(200, 0), 30.0, Reflector.Mode.REVERSE)
	var second := _mirror_on(created, Vector2(-80, 0), 30.0, Reflector.Mode.REVERSE)
	# The bullet comes back as an enemy bullet. The second zone has to accept that owner.
	second.reflects_owners = Layers.ENEMY
	created.spawn(_shot(Vector2(100, 0), Vector2(2500, 0)))
	created.step(0.08)
	assert_eq(created.last_reflect_count, 1, "the first zone reflected")
	created.step(0.12)
	var rows := _rows(created)
	var out := PackedInt32Array()
	out.append(created.last_reflect_count)
	var reflects := -1
	var owner := -1
	if rows.size() == 1:
		reflects = rows[0]["reflects"]
		owner = rows[0]["owner"]
	out.append(reflects)
	out.append(owner)
	var vel: Vector2 = rows[0]["vel"] if rows.size() == 1 else Vector2.ZERO
	out.append(-1 if vel.x < 0.0 else (1 if vel.x > 0.0 else 0))
	# Keep the second zone alive until the manager is freed with it.
	second.position = second.position
	_close(created)
	return out


func test_a_zone_limit_above_the_pool_and_an_arc_that_declines() -> void:
	if not _ready_native():
		return
	var gd := _manager("gdscript")
	var nat := _manager("native")
	var arc_pair: Array[BulletManager] = [gd, nat]
	for created in arc_pair:
		var zone := _mirror_on(created, Vector2(80, 0), 30.0, Reflector.Mode.REVERSE)
		zone.max_reflections = 2
		zone.arc_degrees = 90.0
		# Facing +x. A bullet from the left hits the back of the arc and passes.
		created.spawn(_shot(Vector2(0, 0), Vector2(1600, 0)))
		created.step(0.05)
	assert_eq(gd.last_reflect_count, 0)
	assert_eq(nat.last_reflect_count, 0)
	_assert_rows(_rows(nat), _rows(gd), "arc decline")
	_close(gd)
	_close(nat)
	# The facing side does reflect, and aim-at-target sends the bullet at the node.
	var gd2 := _manager("gdscript")
	var nat2 := _manager("native")
	var aim_pair: Array[BulletManager] = [gd2, nat2]
	for created in aim_pair:
		var aim := _mirror_on(created, Vector2(0, 0), 30.0, Reflector.Mode.AIM_AT_TARGET)
		var mark := Node2D.new()
		mark.position = Vector2(0, 200)
		created.add_child(mark)
		aim.target = mark
		created.spawn(_shot(Vector2(80, 0), Vector2(-1600, 0)))
		created.step(0.05)
	assert_eq(gd2.last_reflect_count, 1)
	_assert_rows(_rows(nat2), _rows(gd2), "aim")
	var vel: Vector2 = _rows(gd2)[0]["vel"]
	assert_gt(vel.y, 0.0, "aimed downward")
	_close(gd2)
	_close(nat2)


func test_pierce_then_reflect_does_not_reach_the_body_behind() -> void:
	if not _ready_native():
		return
	var gd := _pierce_scene("gdscript")
	var nat := _pierce_scene("native")
	assert_eq(nat, gd)
	assert_eq(gd[0], 1, "the target in front was hit")
	assert_eq(gd[1], 0, "the body behind the mirror was not")
	assert_eq(gd[2], 1, "the shot reflected")
	assert_eq(gd[3], 2, "one pierce spent, of 3")


func _pierce_scene(preference: String) -> PackedInt32Array:
	var created := _manager(preference)
	var front := Hurtbox.new()
	front.position = Vector2(140, 0)
	front.radius = 10.0
	front.layer = Layers.ENEMY
	created.add_child(front)
	var front_hits: Array[int] = [0]
	front.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: front_hits[0] += 1)
	_mirror_on(created, Vector2(200, 0), 40.0, Reflector.Mode.REVERSE)
	var behind := Hurtbox.new()
	behind.position = Vector2(250, 0)
	behind.radius = 10.0
	behind.layer = Layers.ENEMY
	created.add_child(behind)
	var behind_hits: Array[int] = [0]
	behind.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: behind_hits[0] += 1)
	created.spawn(_shot(Vector2(100, 0), Vector2(4000, 0), 3))
	created.step(0.05)
	var rows := _rows(created)
	var left := -1
	if rows.size() == 1:
		left = rows[0]["pierce"]
	var out := PackedInt32Array()
	out.append(front_hits[0])
	out.append(behind_hits[0])
	out.append(created.last_reflect_count)
	out.append(left)
	_close(created)
	return out


func test_return_leg_wall_matches_including_the_normal() -> void:
	if not _ready_native():
		return
	var gd := _manager("gdscript")
	var nat := _manager("native")
	gd.add_wall(Rect2(60, -50, 20, 100))
	nat.add_wall(Rect2(60, -50, 20, 100))
	var gd_zone := _mirror_on(gd, Vector2(200, 0), 40.0, Reflector.Mode.REVERSE)
	# The GD bullet keeps its despawn hook so it can read the normal. That does
	# not change the bounce. The native bullet stays hook-free.
	gd_zone.keep_script = true
	var hook := _NormalHook.new()
	hook.mgr = gd
	var hooked := _shot(Vector2(130, 0), Vector2(4000, 0))
	hooked.behavior_id = gd.register_behavior(hook)
	gd.spawn(hooked)
	# Zones share one registry. Finish the GD run before the native zone exists,
	# or the two mirrors sit on top of each other and one steals the bounce.
	gd.step(0.125)
	var gd_reason := hook.reason
	var gd_normal := hook.normal
	_close(gd)
	_mirror_on(nat, Vector2(200, 0), 40.0, Reflector.Mode.REVERSE)
	nat.spawn(_shot(Vector2(130, 0), Vector2(4000, 0)))
	nat.native.set_record_events(true)
	nat.step(0.125)
	assert_eq(gd_reason, BulletPool.DespawnReason.WALL)
	assert_eq(gd_normal, Vector2.RIGHT)
	var logged: Array = nat.native.last_despawns()
	assert_gte(logged.size(), 1)
	var found := false
	for item: Dictionary in logged:
		var reason: int = item["reason"]
		var normal: Vector2 = item["normal"]
		if reason == BulletPool.DespawnReason.WALL:
			assert_eq(normal, Vector2.RIGHT)
			found = true
	assert_true(found, "native logged the return-leg wall")
	_close(nat)


func test_mixed_store_hit_order_after_reflection() -> void:
	if not _ready_native():
		return
	var gd := _order_scene("gdscript")
	var nat := _order_scene("native")
	assert_eq(nat, gd)
	assert_eq(gd[0], 1, "one hit")
	assert_eq(gd[1], 1, "the later hooked bullet got the target, not the return leg")
	assert_eq(gd[2], 1, "the plain bullet still reflected")


func _order_scene(preference: String) -> PackedInt32Array:
	var created := _manager(preference)
	var target := Hurtbox.new()
	target.position = Vector2(90, 0)
	target.radius = 12.0
	target.layer = Layers.ENEMY
	created.add_child(target)
	var hit_was_second: Array[int] = [0]
	var hits: Array[int] = [0]
	_mirror_on(created, Vector2(220, 0), 40.0, Reflector.Mode.REVERSE)
	var hook_id := created.register_behavior(_UpdateNop.new())
	var plain := _shot(Vector2(140, 0), Vector2(4000, 0))
	var hooked := _shot(Vector2(40, 0), Vector2(3000, 0))
	hooked.behavior_id = hook_id
	var first := created.spawn(plain)
	var second := created.spawn(hooked)
	var first_id := first if created.is_native_id(first) else created.pool.id_of(first)
	var second_id := second if created.is_native_id(second) else created.pool.id_of(second)
	target.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void:
		hits[0] += 1
		if target.last_hit_bullet_id == second_id:
			hit_was_second[0] = 1
		target.active = false)
	created.step(0.05)
	var out := PackedInt32Array()
	out.append(hits[0])
	out.append(hit_was_second[0])
	out.append(created.last_reflect_count)
	out.append(1 if created.emitter.is_bullet_alive(first_id) else 0)
	_close(created)
	return out


class _UpdateNop:
	extends BulletBehavior

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		pass


func test_script_invulnerability_flag_is_cleared_unless_keep_script() -> void:
	if not _ready_native():
		return
	var cleared_gd := _invuln("gdscript", false)
	var cleared_nat := _invuln("native", false)
	assert_eq(cleared_nat, cleared_gd)
	assert_eq(cleared_gd, 0, "a reflected bullet no longer pierces script invulnerability")
	var kept_gd := _invuln("gdscript", true)
	var kept_nat := _invuln("native", true)
	assert_eq(kept_nat, kept_gd)
	assert_eq(kept_gd, Health.SOURCE_PIERCES_SCRIPT_INVULN)


func _invuln(preference: String, keep: bool) -> int:
	var created := _manager(preference)
	var zone := _mirror_on(created, Vector2(200, 0), 40.0, Reflector.Mode.REVERSE)
	zone.keep_script = keep
	var body := Hurtbox.new()
	body.position = Vector2(80, 0)
	body.radius = 12.0
	body.layer = Layers.PLAYER
	created.add_child(body)
	var flags: Array[int] = [-1]
	body.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: flags[0] = body.last_hit_flags)
	var req := _shot(Vector2(120, 0), Vector2(4000, 0))
	req.pierces_script_invuln = true
	created.spawn(req)
	created.step(0.05)
	_close(created)
	return flags[0]


func test_reflect_bullet_on_a_native_id_returns_false() -> void:
	if not _ready_native():
		return
	var created := _manager("native")
	var id := created.spawn(_shot(Vector2(10, 20), Vector2(100, 0)))
	assert_true(created.is_native_id(id))
	var before := _rows(created)[0]
	assert_false(created.emitter.reflect_bullet(id, Layers.ENEMY, true))
	var after := _rows(created)[0]
	var before_owner: int = before["owner"]
	var after_owner: int = after["owner"]
	var before_reflects: int = before["reflects"]
	var after_reflects: int = after["reflects"]
	assert_eq(after_owner, before_owner)
	var bv: Vector2 = before["vel"]
	var av: Vector2 = after["vel"]
	assert_eq(av, bv)
	assert_eq(after_reflects, 0)
	assert_eq(before_reflects, 0)
	_close(created)


func test_dynamic_reflectors_match_including_one_added_mid_reflection() -> void:
	if not _ready_native():
		return
	# Register in on_update: both bullets reflect this tick, the plain one stays native.
	var gd := _dynamic("gdscript", false)
	var nat := _dynamic("native", false)
	var gd_hits: int = gd["hits"]
	var nat_hits: int = nat["hits"]
	var gd_reflects: int = gd["reflects"]
	var nat_reflects: int = nat["reflects"]
	var gd_rows: Array[Dictionary] = gd["rows"]
	var nat_rows: Array[Dictionary] = nat["rows"]
	var native_alive: int = nat["native_alive"]
	assert_eq(nat_hits, gd_hits)
	assert_eq(nat_reflects, gd_reflects)
	_assert_rows(nat_rows, gd_rows, "on_update register")
	assert_gt(native_alive, 0, "the plain bullet stayed native")
	# A second zone appears after the bullet has already reflected once.
	var again_gd := _dynamic("gdscript", true)
	var again_nat := _dynamic("native", true)
	var gd_second: int = again_gd["second"]
	var nat_second: int = again_nat["second"]
	var gd_rows2: Array[Dictionary] = again_gd["rows2"]
	var nat_rows2: Array[Dictionary] = again_nat["rows2"]
	assert_eq(nat_second, gd_second)
	assert_eq(gd_second, 0, "cap 1 refuses the zone added while it is already reflecting")
	_assert_rows(nat_rows2, gd_rows2, "second zone")


func _dynamic(preference: String, add_second: bool) -> Dictionary:
	var created := _manager(preference)
	var zone := Reflector.new()
	zone.radius = 28.0
	zone.mode = Reflector.Mode.MIRROR
	zone.position = Vector2(50, 0)
	var hook := _PlaceZone.new()
	hook.host = created
	hook.zone = zone
	var hook_id := created.register_behavior(hook)
	var hooked := _shot(Vector2(0, 0), Vector2(2400, 0))
	hooked.behavior_id = hook_id
	var plain := _shot(Vector2(0, 12), Vector2(2400, 0))
	created.spawn(hooked)
	created.spawn(plain)
	created.step(DT)
	var native_alive := created.native.count() if created.native != null else 0
	var first_rows := _rows(created)
	var second := 0
	var rows2: Array[Dictionary] = first_rows
	if add_second:
		var extra := Reflector.new()
		extra.radius = 24.0
		extra.mode = Reflector.Mode.REVERSE
		extra.position = Vector2(-30, 6)
		created.add_child(extra)
		created.step(DT)
		second = created.last_reflect_count
		rows2 = _rows(created)
	if zone.is_inside_tree():
		zone.get_parent().remove_child(zone)
	zone.free()
	var result := {
		"hits": created.last_reflect_count if not add_second else 1,
		"reflects": created.last_reflect_count if not add_second else 1,
		"rows": first_rows,
		"rows2": rows2,
		"native_alive": native_alive,
		"second": second,
	}
	# The first tick's reflect count was overwritten if we stepped again. Stash it.
	if not add_second:
		result["reflects"] = created.last_reflect_count
	else:
		result["hits"] = 1
	_close(created)
	return result


class _PlaceZone:
	extends BulletBehavior
	var host: Node
	var zone: Reflector

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		if zone != null and not zone.is_inside_tree():
			host.add_child(zone)


func test_unregistering_a_reflector_mid_run_matches() -> void:
	if not _ready_native():
		return
	var gd := _unregister("gdscript")
	var nat := _unregister("native")
	assert_eq(nat, gd)
	assert_eq(gd[0], 1, "reflected while the zone existed")
	assert_eq(gd[1], 0, "gone on the next tick, so no second reflection")


func _unregister(preference: String) -> PackedInt32Array:
	var created := _manager(preference)
	created.pool.max_reflections = 0
	var zone := _mirror_on(created, Vector2(40, 0), 20.0, Reflector.Mode.REVERSE)
	created.spawn(_shot(Vector2(0, 0), Vector2(800, 0)))
	created.step(0.05)
	var first := created.last_reflect_count
	created.remove_child(zone)
	zone.free()
	created.step(DT)
	var out := PackedInt32Array()
	out.append(first)
	out.append(created.last_reflect_count)
	var rows := _rows(created)
	var reflects := -1
	if rows.size() == 1:
		reflects = rows[0]["reflects"]
	out.append(reflects)
	_close(created)
	return out
