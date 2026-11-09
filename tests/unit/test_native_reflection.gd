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


## GDScript reflect_bullet timing, measured on the pool (see docs/native.md):
## advance() has already moved the bullet, the call mutates immediately, and
## this tick's sweeps then see the new owner, mask and damage. The next tick
## is what travels on the new velocity.
func test_gd_on_update_reflect_applies_after_advance_and_before_collision() -> void:
	var created := _manager("gdscript")
	var id := created.emitter.request_shot_id(_shot(Vector2(10, 20), Vector2(600, 0)))
	var hook := _ScriptReflect.new()
	hook.record = true
	_arm(created, id, hook)
	created.step(DT)
	assert_eq(hook.returns.size(), 1)
	assert_true(hook.returns[0])
	assert_lt(hook.pos.distance_to(Vector2(20, 20)), 0.02, "advance already ran")
	assert_lt(hook.vel.distance_to(Vector2(-600, 0)), 0.02, "the flip is visible inside the call")
	assert_eq(hook.owner_seen, Layers.ENEMY)
	assert_eq(hook.reflects, 1)
	var end := _row_near(_rows(created), 20.0)
	_assert_reflect_row(end, Vector2(20, 20), Vector2(-600, 0), Layers.ENEMY, 1, Layers.PLAYER)
	hook.returns.clear()
	created.step(DT)
	assert_eq(hook.returns.size(), 1)
	assert_false(hook.returns[0], "the cap was spent by the first tick")
	var nxt := _row_near(_rows(created), 20.0)
	_assert_reflect_row(nxt, Vector2(10, 20), Vector2(-600, 0), Layers.ENEMY, 1, Layers.PLAYER)
	_close(created)


## Same tick's position is the pre-reflect travel. Velocity and owner are the
## reflected ones once step() returns, and the id is still the native id.
func _b(d: Dictionary, key: String) -> bool:
	var v: bool = d[key]
	return v


func _i(d: Dictionary, key: String) -> int:
	var v: int = d[key]
	return v


func _a(d: Dictionary, key: String) -> Array:
	var v: Array = d[key]
	return v


func _rd(d: Dictionary, key: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = d[key]
	return rows


func _native_of(created: BulletManager, id: int) -> Dictionary:
	var snap := created.native.snapshot()
	var ids: PackedInt64Array = snap["id"]
	var pos: PackedVector2Array = snap["pos"]
	var vel: PackedVector2Array = snap["vel"]
	var owners: PackedInt32Array = snap["owner"]
	var reflects: PackedInt32Array = snap["reflect_count"]
	for i in ids.size():
		if ids[i] == id:
			return {"pos": pos[i], "vel": vel[i], "owner": owners[i], "reflects": reflects[i]}
	return {"pos": Vector2.INF, "vel": Vector2.INF, "owner": -1, "reflects": -1}


func test_reflect_same_tick_position_velocity_and_owner_match() -> void:
	if not _ready_native():
		return
	var gd := _hooked_reflect("gdscript", 1, true, Layers.ENEMY)
	var nat := _hooked_reflect("native", 1, true, Layers.ENEMY)
	var nat_ok := _a(nat, "ok")
	var first: bool = nat_ok[0]
	assert_true(first)
	assert_eq(_a(nat, "ok"), _a(gd, "ok"))
	_assert_rows(_rd(nat, "rows"), _rd(gd, "rows"), "same tick")
	assert_true(_b(nat, "native_alive"))
	assert_true(_b(nat, "still_native"), "the id is not retired")
	assert_eq(_i(nat, "enemy"), _i(gd, "enemy"))
	assert_eq(_i(gd, "enemy"), 1)
	var again_gd := _hooked_reflect("gdscript", 1, true, Layers.ENEMY, 2)
	var again_nat := _hooked_reflect("native", 1, true, Layers.ENEMY, 2)
	assert_eq(_a(again_nat, "second_ok"), _a(again_gd, "second_ok"))
	var second := _a(again_gd, "second_ok")
	var second_ok: bool = second[0]
	assert_false(second_ok)
	_assert_rows(_rd(again_nat, "second_rows"), _rd(again_gd, "second_rows"), "next tick")


func test_repeated_reflects_match_within_a_tick_and_across_ticks() -> void:
	if not _ready_native():
		return
	var gd := _hooked_reflect("gdscript", 2, true, Layers.ENEMY)
	var nat := _hooked_reflect("native", 2, true, Layers.ENEMY)
	assert_eq(_a(gd, "ok"), [true, false])
	assert_eq(_a(nat, "ok"), _a(gd, "ok"))
	_assert_rows(_rd(nat, "rows"), _rd(gd, "rows"), "two calls, cap 1")
	var across_gd := _hooked_reflect("gdscript", 1, true, Layers.ENEMY, 2)
	var across_nat := _hooked_reflect("native", 1, true, Layers.ENEMY, 2)
	assert_eq(_a(across_gd, "ok"), [true])
	assert_eq(_a(across_gd, "second_ok"), [false])
	assert_eq(_a(across_nat, "ok"), _a(across_gd, "ok"))
	assert_eq(_a(across_nat, "second_ok"), _a(across_gd, "second_ok"))
	_assert_rows(_rd(across_nat, "second_rows"), _rd(across_gd, "second_rows"), "across ticks")
	var owners: Array[int] = [Layers.ENEMY, Layers.PLAYER]
	var open_gd := _hooked_reflect("gdscript", 2, true, Layers.ENEMY, 1, 0, owners)
	var open_nat := _hooked_reflect("native", 2, true, Layers.ENEMY, 1, 0, owners)
	assert_eq(_a(open_gd, "ok"), [true, true])
	assert_eq(_a(open_nat, "ok"), _a(open_gd, "ok"))
	_assert_rows(_rd(open_nat, "rows"), _rd(open_gd, "rows"), "unlimited, two reverses")
	_assert_reflect_row(_row_near(_rd(open_gd, "rows"), 20.0), Vector2(20, 20), Vector2(600, 0), Layers.PLAYER, 2, Layers.ENEMY)


## The call returns true (the bullet is alive), then a despawn lands before the
## queued op. The op is dropped. The bullet is simply gone.
func test_reflect_is_dropped_when_the_bullet_despawns_before_it_runs() -> void:
	if not _ready_native():
		return
	var none: Array[int] = []
	var gd := _hooked_reflect("gdscript", 1, true, Layers.ENEMY, 1, 1, none, true)
	var nat := _hooked_reflect("native", 1, true, Layers.ENEMY, 1, 1, none, true)
	assert_eq(_a(gd, "ok"), [true])
	assert_eq(_a(nat, "ok"), _a(gd, "ok"))
	assert_false(_b(gd, "alive"))
	assert_false(_b(nat, "alive"))
	assert_eq(_rd(nat, "rows").size(), _rd(gd, "rows").size())


## Kill, compact, and spawn a new native bullet on the same handle before the
## queued op runs. The replacement keeps its own owner and velocity.
func test_deferred_reflect_does_not_affect_a_reused_slot() -> void:
	if not _ready_native():
		return
	var created := _manager("native")
	var id := created.emitter.request_shot_id(_shot(Vector2(0, 0), Vector2(300, 0)))
	var handle := id & 0xFFFFFFFF
	var hook := _ReuseReflect.new()
	hook.host = created
	hook.target_id = id
	hook.replacement_at = Vector2(80, 10)
	hook.replacement_vel = Vector2(120, 40)
	var req := _shot(Vector2(0, 400), Vector2.ZERO)
	req.hit_mask = 0
	req.behavior_id = created.register_behavior(hook)
	created.spawn(req)
	created.step(DT)
	assert_eq(hook.returns.size(), 1)
	assert_true(hook.returns[0], "the original bullet accepted the reflect")
	assert_false(created.is_native_bullet_alive(id))
	assert_ne(hook.replacement_id, id)
	assert_eq(hook.replacement_id & 0xFFFFFFFF, handle, "the handle index was reused")
	assert_true(created.is_native_bullet_alive(hook.replacement_id))
	var row: Dictionary = _native_of(created, hook.replacement_id)
	var pos: Vector2 = row["pos"]
	var vel: Vector2 = row["vel"]
	var owner: int = row["owner"]
	var reflects: int = row["reflects"]
	assert_eq(owner, Layers.PLAYER)
	assert_eq(reflects, 0)
	assert_lt(vel.distance_to(hook.replacement_vel), VEL_EPS)
	assert_lt(pos.distance_to(hook.replacement_at + hook.replacement_vel * DT), POS_EPS)
	_close(created)


## Before the first step, between steps, and from on_despawn: the call applies
## immediately. The next integrate uses the new velocity.
func test_reflect_outside_on_update_matches() -> void:
	if not _ready_native():
		return
	var before_gd := _reflect_then_step("gdscript")
	var before_nat := _reflect_then_step("native")
	assert_true(_b(before_gd, "ok"))
	assert_eq(_b(before_nat, "ok"), _b(before_gd, "ok"))
	assert_true(_b(before_nat, "still_native"))
	_assert_rows(_rd(before_nat, "before"), _rd(before_gd, "before"), "before any step")
	_assert_rows(_rd(before_nat, "after"), _rd(before_gd, "after"), "first step uses the new velocity")
	var between_gd := _reflect_between("gdscript")
	var between_nat := _reflect_between("native")
	assert_true(_b(between_gd, "ok"))
	assert_eq(_b(between_nat, "ok"), _b(between_gd, "ok"))
	_assert_rows(_rd(between_nat, "at_call"), _rd(between_gd, "at_call"), "between steps, immediate")
	_assert_rows(_rd(between_nat, "after"), _rd(between_gd, "after"), "the following step")
	var despawn_gd := _reflect_on_despawn("gdscript")
	var despawn_nat := _reflect_on_despawn("native")
	assert_eq(_a(despawn_gd, "ok"), [true])
	assert_eq(_a(despawn_nat, "ok"), _a(despawn_gd, "ok"))
	_assert_rows(_rd(despawn_nat, "rows"), _rd(despawn_gd, "rows"), "on_despawn same tick")
	_assert_rows(_rd(despawn_nat, "next"), _rd(despawn_gd, "next"), "on_despawn next tick")


func test_reflect_return_value_matches() -> void:
	if not _ready_native():
		return
	for preference: String in ["gdscript", "native"]:
		var created := _manager(preference)
		var id := created.emitter.request_shot_id(_shot(Vector2(10, 20), Vector2(600, 0)))
		assert_false(created.emitter.reflect_bullet(id, 0, true), "%s bad owner" % preference)
		assert_false(created.emitter.reflect_bullet(id, Layers.WORLD), "%s world owner" % preference)
		var untouched := _row_near(_rows(created), 20.0)
		_assert_reflect_row(untouched, Vector2(10, 20), Vector2(600, 0), Layers.PLAYER, 0, Layers.ENEMY)
		assert_true(created.emitter.reflect_bullet(id, Layers.ENEMY, true))
		assert_false(created.emitter.reflect_bullet(id, Layers.PLAYER, true), "%s second call" % preference)
		if preference == "native":
			assert_true(created.is_native_id(id))
			assert_true(created.is_native_bullet_alive(id))
		_close(created)
	var life_gd := _death_return("gdscript", "lifetime")
	var life_nat := _death_return("native", "lifetime")
	assert_eq(_a(life_gd, "ok"), [false])
	assert_eq(_a(life_nat, "ok"), _a(life_gd, "ok"))
	assert_false(_b(life_gd, "alive"))
	assert_false(_b(life_nat, "alive"))
	var bounds_gd := _death_return("gdscript", "bounds")
	var bounds_nat := _death_return("native", "bounds")
	assert_eq(_a(bounds_gd, "ok"), [false])
	assert_eq(_a(bounds_nat, "ok"), _a(bounds_gd, "ok"))
	assert_false(_b(bounds_nat, "alive"))
	var wall_gd := _death_return("gdscript", "wall")
	var wall_nat := _death_return("native", "wall")
	assert_eq(_a(wall_gd, "ok"), [true])
	assert_eq(_a(wall_nat, "ok"), _a(wall_gd, "ok"))
	assert_false(_b(wall_gd, "alive"))
	assert_false(_b(wall_nat, "alive"))
	var stale_gd := _stale_return("gdscript")
	var stale_nat := _stale_return("native")
	assert_false(stale_gd)
	assert_false(stale_nat)


## A reflect in on_update changes who this tick's zone and hurtbox see.
## Damage is the reflected 1, not the shot's 5.
func test_script_reflect_is_visible_to_same_tick_zones_and_hurtboxes() -> void:
	if not _ready_native():
		return
	var gd_zone := _zone_case("gdscript")
	var nat_zone := _zone_case("native")
	assert_eq(_a(nat_zone, "returns"), _a(gd_zone, "returns"))
	assert_eq(_a(gd_zone, "returns"), [true])
	assert_eq(_i(nat_zone, "zone"), _i(gd_zone, "zone"))
	assert_eq(_i(gd_zone, "zone"), 0, "the new owner is not the zone's faction")
	_assert_rows(_rd(nat_zone, "rows"), _rd(gd_zone, "rows"), "zone")
	_assert_reflect_row(_row_near(_rd(gd_zone, "rows"), 0.0), Vector2(80, 0), Vector2(2400, 0), Layers.ENEMY, 1, Layers.PLAYER)
	var gd_hit := _hurt_case("gdscript", false)
	var nat_hit := _hurt_case("native", false)
	assert_eq(_i(nat_hit, "enemy"), _i(gd_hit, "enemy"))
	assert_eq(_i(nat_hit, "player"), _i(gd_hit, "player"))
	assert_eq(_i(gd_hit, "enemy"), 0)
	assert_eq(_i(gd_hit, "player"), 1)
	assert_eq(_i(nat_hit, "damage"), _i(gd_hit, "damage"))
	assert_almost_eq(float(_i(gd_hit, "damage")), 1.0, 0.001)
	var gv: Vector2 = gd_hit["vel"]
	var nv: Vector2 = nat_hit["vel"]
	assert_lt(nv.distance_to(gv), VEL_EPS)
	assert_lt(gv.distance_to(Vector2(2400, 0)), VEL_EPS)
	var gd_flip := _hurt_case("gdscript", true)
	var nat_flip := _hurt_case("native", true)
	var gfv: Vector2 = gd_flip["vel"]
	var nfv: Vector2 = nat_flip["vel"]
	assert_eq(_i(nat_flip, "player"), _i(gd_flip, "player"))
	assert_eq(_i(gd_flip, "player"), 1)
	assert_lt(nfv.distance_to(gfv), VEL_EPS)
	assert_lt(gfv.distance_to(Vector2(-2400, 0)), VEL_EPS)


func test_script_reflect_clears_invulnerability_unless_kept() -> void:
	if not _ready_native():
		return
	var cleared_gd := _script_invuln("gdscript", false)
	var cleared_nat := _script_invuln("native", false)
	assert_eq(cleared_nat, cleared_gd)
	assert_eq(cleared_gd, 0)
	var kept_gd := _script_invuln("gdscript", true)
	var kept_nat := _script_invuln("native", true)
	assert_eq(kept_nat, kept_gd)
	assert_eq(kept_gd, Health.SOURCE_PIERCES_SCRIPT_INVULN)


func _assert_reflect_row(row: Dictionary, pos: Vector2, vel: Vector2, owner: int, reflects: int, mask: int) -> void:
	assert_false(row.is_empty())
	var rp: Vector2 = row["pos"]
	var rv: Vector2 = row["vel"]
	var ro: int = row["owner"]
	var rr: int = row["reflects"]
	var rm: int = row["mask"]
	assert_lt(rp.distance_to(pos), POS_EPS)
	assert_lt(rv.distance_to(vel), VEL_EPS)
	assert_eq(ro, owner)
	assert_eq(rr, reflects)
	assert_eq(rm, mask)


func _row_near(rows: Array[Dictionary], y: float) -> Dictionary:
	for row: Dictionary in rows:
		var p: Vector2 = row["pos"]
		if absf(p.y - y) < 1.0:
			return row
	return {}


func _arm(created: BulletManager, target: int, hook: _ScriptReflect, life: float = 4.0) -> void:
	hook.host = created
	hook.target_id = target
	var req := _shot(Vector2(0, 400), Vector2.ZERO)
	req.hit_mask = 0
	req.lifetime = life
	req.behavior_id = created.register_behavior(hook)
	created.spawn(req)


func _hooked_reflect(
	preference: String,
	times: int,
	reverse: bool,
	owner: int,
	steps: int = 1,
	limit: int = 1,
	owners: Array[int] = [],
	kill_after: bool = false
) -> Dictionary:
	var created := _manager(preference)
	created.pool.max_reflections = limit
	var id := created.emitter.request_shot_id(_shot(Vector2(10, 20), Vector2(600, 0)))
	var hook := _ScriptReflect.new()
	hook.times = times
	hook.reverse = reverse
	hook.owner = owner
	hook.owners = owners
	hook.kill_after = kill_after
	_arm(created, id, hook)
	created.step(DT)
	var first: Array[bool] = []
	first.assign(hook.returns)
	var rows := _rows(created)
	var alive := created.emitter.is_bullet_alive(id)
	var enemy := created.owner_count_all(Layers.ENEMY)
	var native_alive := created.is_native_bullet_alive(id)
	var still_native := created.is_native_id(id) and native_alive
	hook.returns.clear()
	if steps > 1:
		created.step(DT)
	var second: Array[bool] = []
	second.assign(hook.returns)
	var second_rows := _rows(created)
	_close(created)
	return {
		"ok": first,
		"rows": rows,
		"alive": alive,
		"enemy": enemy,
		"native_alive": native_alive,
		"still_native": still_native,
		"second_ok": second,
		"second_rows": second_rows,
	}


func _reflect_then_step(preference: String) -> Dictionary:
	var created := _manager(preference)
	var id := created.emitter.request_shot_id(_shot(Vector2(10, 20), Vector2(600, 0)))
	var ok := created.emitter.reflect_bullet(id, Layers.ENEMY, true)
	var before := _rows(created)
	created.step(DT)
	var after := _rows(created)
	var still := created.is_native_id(id) and created.is_native_bullet_alive(id)
	_close(created)
	return {"ok": ok, "before": before, "after": after, "still_native": still}


func _reflect_between(preference: String) -> Dictionary:
	var created := _manager(preference)
	var id := created.emitter.request_shot_id(_shot(Vector2(10, 20), Vector2(600, 0)))
	created.step(DT)
	var ok := created.emitter.reflect_bullet(id, Layers.ENEMY, true)
	var at_call := _rows(created)
	created.step(DT)
	var after := _rows(created)
	_close(created)
	return {"ok": ok, "at_call": at_call, "after": after}


func _reflect_on_despawn(preference: String) -> Dictionary:
	var created := _manager(preference)
	var id := created.emitter.request_shot_id(_shot(Vector2(10, 20), Vector2(600, 0)))
	var hook := _DespawnReflect.new()
	hook.host = created
	hook.target_id = id
	var req := _shot(Vector2(0, 400), Vector2.ZERO)
	req.hit_mask = 0
	req.lifetime = 0.01
	req.behavior_id = created.register_behavior(hook)
	created.spawn(req)
	created.step(DT)
	var returns: Array[bool] = []
	returns.assign(hook.returns)
	var rows := _rows(created)
	created.step(DT)
	var nxt := _rows(created)
	_close(created)
	return {"ok": returns, "rows": rows, "next": nxt}


func _death_return(preference: String, kind: String) -> Dictionary:
	var created := _manager(preference)
	var req := _shot(Vector2(10, 20), Vector2(600, 0))
	if kind == "lifetime":
		req.lifetime = 0.01
	elif kind == "bounds":
		req.position = Vector2(790, 0)
		req.velocity = Vector2(1000, 0)
	elif kind == "wall":
		created.add_wall(Rect2(30, -20, 40, 40))
		req.position = Vector2(0, 0)
		req.velocity = Vector2(2400, 0)
	var id := created.emitter.request_shot_id(req)
	var hook := _ScriptReflect.new()
	_arm(created, id, hook)
	created.step(DT)
	var returns: Array[bool] = []
	returns.assign(hook.returns)
	var alive := created.emitter.is_bullet_alive(id)
	_close(created)
	return {"ok": returns, "alive": alive}


func _stale_return(preference: String) -> bool:
	var created := _manager(preference)
	var req := _shot(Vector2.ZERO, Vector2.ZERO)
	req.lifetime = 0.01
	var id := created.emitter.request_shot_id(req)
	created.step(DT)
	var ok := created.emitter.reflect_bullet(id, Layers.ENEMY, true)
	_close(created)
	return ok


func _zone_case(preference: String) -> Dictionary:
	var created := _manager(preference)
	var zone := Reflector.new()
	zone.position = Vector2(80, 0)
	zone.radius = 30.0
	zone.mode = Reflector.Mode.REVERSE
	zone.reflects_owners = Layers.PLAYER
	add_child(zone)
	var id := created.emitter.request_shot_id(_shot(Vector2(40, 0), Vector2(2400, 0)))
	var hook := _ScriptReflect.new()
	hook.reverse = false
	_arm(created, id, hook)
	created.step(DT)
	var returns: Array[bool] = []
	returns.assign(hook.returns)
	var rows := _rows(created)
	var total := zone.reflected_total
	_close(created)
	zone.free()
	return {"returns": returns, "rows": rows, "zone": total}


func _hurt_case(preference: String, reverse: bool) -> Dictionary:
	var created := _manager(preference)
	var enemy := _HitSink.new()
	enemy.position = Vector2(15, 0)
	enemy.radius = 8.0
	enemy.layer = Layers.ENEMY
	var player := _HitSink.new()
	player.position = Vector2(30, 0)
	player.radius = 8.0
	player.layer = Layers.PLAYER
	created.add_child(enemy)
	created.add_child(player)
	var id := created.emitter.request_shot_id(_shot(Vector2(0, 0), Vector2(2400, 0)))
	var hook := _ScriptReflect.new()
	hook.reverse = reverse
	_arm(created, id, hook)
	created.step(DT)
	var result := {
		"enemy": enemy.hits,
		"player": player.hits,
		"damage": player.damage,
		"vel": player.velocity,
	}
	_close(created)
	return result


func _script_invuln(preference: String, keep: bool) -> int:
	var created := _manager(preference)
	var player := _HitSink.new()
	player.position = Vector2(30, 0)
	player.radius = 8.0
	player.layer = Layers.PLAYER
	created.add_child(player)
	var req := _shot(Vector2(0, 0), Vector2(2400, 0))
	req.pierces_script_invuln = true
	var id := created.emitter.request_shot_id(req)
	var hook := _ScriptReflect.new()
	hook.reverse = false
	hook.keep = keep
	_arm(created, id, hook)
	created.step(DT)
	var flags := player.flags
	_close(created)
	return flags


class _ScriptReflect:
	extends BulletBehavior
	var host: BulletManager
	var target_id := -1
	var times := 1
	var reverse := true
	var owner := Layers.ENEMY
	var owners: Array[int] = []
	var damage := BulletPool.REFLECTED_DAMAGE
	var keep := false
	var kill_after := false
	var record := false
	var returns: Array[bool] = []
	var pos := Vector2.INF
	var vel := Vector2.INF
	var owner_seen := -2
	var reflects := -2

	func on_update(pool: BulletPool, _index: int, _delta: float) -> void:
		for i in times:
			var who := owner
			if i < owners.size():
				who = owners[i]
			returns.append(host.emitter.reflect_bullet(target_id, who, reverse, damage, keep))
		if record:
			var slot := pool.slot_of(target_id)
			if slot >= 0:
				pos = pool.pos[slot]
				vel = pool.vel[slot]
				owner_seen = pool.owner_layer[slot]
				reflects = pool.reflect_count[slot]
		if kill_after:
			if host.is_native_id(target_id):
				host.native.kill(target_id)
			else:
				var slot := pool.slot_of(target_id)
				if slot >= 0:
					pool.mark_dead(slot, BulletPool.DespawnReason.MANUAL)


class _DespawnReflect:
	extends BulletBehavior
	var host: BulletManager
	var target_id := -1
	var returns: Array[bool] = []

	func on_despawn(_pool: BulletPool, _index: int, _reason: int) -> void:
		returns.append(host.emitter.reflect_bullet(target_id, Layers.ENEMY, true))


class _ReuseReflect:
	extends BulletBehavior
	var host: BulletManager
	var target_id := -1
	var replacement_at := Vector2.ZERO
	var replacement_vel := Vector2.ZERO
	var replacement_id := -1
	var returns: Array[bool] = []

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		returns.append(host.emitter.reflect_bullet(target_id, Layers.ENEMY, true))
		host.native.kill(target_id)
		host.native.finish_delivery()
		var req := ShotRequest.with_velocity(replacement_at, replacement_vel)
		req.radius = 2.0
		req.lifetime = 4.0
		req.hit_mask = Layers.ENEMY
		req.owner_layer = Layers.PLAYER
		req.damage = 5.0
		req.collide_world = true
		replacement_id = host.native.spawn(req, 50)


class _HitSink:
	extends Hurtbox
	var hits := 0
	var damage := -1.0
	var velocity := Vector2.INF
	var flags := -1

	func _ready() -> void:
		hit.connect(func(d: float, _p: Vector2, v: Vector2) -> void:
			hits += 1
			damage = d
			velocity = v
			flags = last_hit_flags
		)

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
