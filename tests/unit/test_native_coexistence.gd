extends GutTest
## Mixed-store hit order, the native pierce exclusion list, and the reflector
## routing guard. Each case runs on GDScript and, when the extension is built,
## on native, and the outcomes must match. Pending when NativeBulletSim is absent.

const DT := 1.0 / 60.0


class _Hook:
	extends BulletBehavior

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		pass


class _WallRec:
	extends BulletBehavior
	var mgr: BulletManager
	var reason := -99
	var normal := Vector2(9, 9)

	func on_despawn(_pool: BulletPool, index: int, reason_: int) -> void:
		reason = reason_
		normal = mgr.wall_normal_of(index)


func _ready_native() -> bool:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return false
	return true


func _manager(preference: String) -> BulletManager:
	var created := BulletManager.new()
	created.backend_preference = preference
	created.capacity = 256
	created.logical_cap = 256
	created.enemy_reserve = 0
	created.world_bounds = Rect2(-800, -800, 1600, 1600)
	created.render_enabled = false
	created.auto_step = false
	add_child(created)
	return created


func _close(created: BulletManager) -> void:
	remove_child(created)
	created.free()


func _stable(created: BulletManager, spawned: int) -> int:
	if spawned < 0:
		return -1
	if created.is_native_id(spawned):
		return spawned
	return created.pool.id_of(spawned)


func _shot(at: Vector2, speed: float, pierce: int) -> ShotRequest:
	var req := ShotRequest.with_velocity(at, Vector2(speed, 0))
	req.radius = 2.0
	req.lifetime = 2.0
	req.hit_mask = Layers.ENEMY
	req.pierce = pierce
	req.owner_layer = Layers.PLAYER
	return req


func _pierce_of(created: BulletManager, id: int) -> int:
	if created.is_native_id(id):
		var snap := created.native.snapshot()
		var ids: PackedInt64Array = snap["id"]
		var pierce: PackedInt32Array = snap["pierce"]
		for i in ids.size():
			if ids[i] == id:
				return pierce[i]
		return -1
	var slot := created.pool.slot_of(id)
	if slot < 0:
		return -1
	return created.pool.pierce[slot]


func _order_outcome(preference: String, plain_first: bool, pierce: int) -> PackedInt32Array:
	var created := _manager(preference)
	var box := Hurtbox.new()
	box.position = Vector2(70, 0)
	box.radius = 14.0
	box.layer = Layers.ENEMY
	created.add_child(box)
	var hit_ids: Array[int] = []
	box.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void:
		hit_ids.append(box.last_hit_bullet_id)
		box.active = false)
	var hook_id := created.register_behavior(_Hook.new())
	var plain := _shot(Vector2(0, 0), 4000.0, pierce)
	var hooked := _shot(Vector2(0, 3), 4000.0, pierce)
	hooked.behavior_id = hook_id
	var first: int
	var second: int
	if plain_first:
		first = _stable(created, created.spawn(plain))
		second = _stable(created, created.spawn(hooked))
	else:
		first = _stable(created, created.spawn(hooked))
		second = _stable(created, created.spawn(plain))
	created.step(DT)
	var out := PackedInt32Array()
	out.append(hit_ids.size())
	out.append(1 if hit_ids.size() > 0 and hit_ids[0] == first else 0)
	out.append(1 if created.emitter.is_bullet_alive(first) else 0)
	out.append(1 if created.emitter.is_bullet_alive(second) else 0)
	out.append(_pierce_of(created, first))
	out.append(_pierce_of(created, second))
	_close(created)
	return out


func test_plain_then_hooked_iframes_match_gdscript() -> void:
	if not _ready_native():
		return
	assert_eq(_order_outcome("native", true, 0), _order_outcome("gdscript", true, 0))


func test_hooked_then_plain_iframes_match_gdscript() -> void:
	if not _ready_native():
		return
	assert_eq(_order_outcome("native", false, 0), _order_outcome("gdscript", false, 0))


func test_plain_then_hooked_pierce_debits_the_earlier_bullet() -> void:
	if not _ready_native():
		return
	var gd := _order_outcome("gdscript", true, 3)
	var nat := _order_outcome("native", true, 3)
	assert_eq(nat, gd)
	# The baseline: one hit, the first bullet spent a pierce, the second did not.
	assert_eq(gd[0], 1)
	assert_eq(gd[1], 1)
	assert_eq(gd[4], 2)
	assert_eq(gd[5], 3)


func test_hooked_then_plain_pierce_matches() -> void:
	if not _ready_native():
		return
	assert_eq(_order_outcome("native", false, 3), _order_outcome("gdscript", false, 3))


func _burst(preference: String, pierce: int) -> PackedInt32Array:
	var created := _manager(preference)
	var seen: Array[int] = []
	for i in 80:
		var box := Hurtbox.new()
		box.position = Vector2.ZERO
		box.radius = 6.0
		box.layer = Layers.ENEMY
		created.add_child(box)
		var mark := i
		box.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: seen.append(mark))
	var req := _shot(Vector2.ZERO, 0.0, pierce)
	created.spawn(req)
	created.step(DT)
	var unique := 0
	for i in seen.size():
		var dup := false
		for j in i:
			if seen[j] == seen[i]:
				dup = true
				break
		if not dup:
			unique += 1
	var out := PackedInt32Array()
	out.append(seen.size())
	out.append(unique)
	_close(created)
	return out


func test_pierce_65_against_80_targets_matches_gdscript() -> void:
	if not _ready_native():
		return
	var gd := _burst("gdscript", 65)
	var nat := _burst("native", 65)
	assert_eq(nat, gd)
	assert_eq(gd[0], 66)
	assert_eq(gd[1], 66)


func test_pierce_70_against_80_targets_matches_gdscript() -> void:
	if not _ready_native():
		return
	var gd := _burst("gdscript", 70)
	var nat := _burst("native", 70)
	assert_eq(nat, gd)
	assert_eq(gd[0], 71)
	assert_eq(gd[1], 71)


func _mirror_body(preference: String, pierce: int) -> PackedInt32Array:
	var created := _manager(preference)
	var zone := Reflector.new()
	zone.radius = 40.0
	zone.mode = Reflector.Mode.REVERSE
	zone.position = Vector2(200, 0)
	add_child(zone)
	var body := Hurtbox.new()
	body.position = Vector2(230, 0)
	body.radius = 10.0
	body.layer = Layers.ENEMY
	add_child(body)
	var hits := 0
	body.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits += 1)
	var req := _shot(Vector2(100, 0), 4000.0, pierce)
	var id := _stable(created, created.spawn(req))
	created.step(0.05)
	var slot := created.pool.slot_of(id)
	var vx_sign := 0
	var owner := -1
	if slot >= 0:
		var vx := created.pool.vel[slot].x
		vx_sign = -1 if vx < 0.0 else (1 if vx > 0.0 else 0)
		owner = created.pool.owner_layer[slot]
	var out := PackedInt32Array()
	out.append(hits)
	out.append(created.last_reflect_count)
	out.append(1 if created.emitter.is_bullet_alive(id) else 0)
	out.append(vx_sign)
	out.append(owner)
	out.append(created.pool.count)
	remove_child(zone)
	zone.free()
	remove_child(body)
	body.free()
	_close(created)
	return out


func test_mirror_blocks_a_plain_shot_the_same_on_both_backends() -> void:
	if not _ready_native():
		return
	var gd := _mirror_body("gdscript", 0)
	var nat := _mirror_body("native", 0)
	assert_eq(nat, gd)
	assert_eq(gd[0], 0, "the body behind the mirror is not hit")
	assert_eq(gd[1], 1, "the mirror reflected the shot")
	assert_eq(gd[3], -1, "velocity reversed")
	assert_eq(gd[4], Layers.ENEMY)


func test_mirror_pierce_shot_matches_gdscript() -> void:
	if not _ready_native():
		return
	assert_eq(_mirror_body("native", 3), _mirror_body("gdscript", 3))


func _return_leg(preference: String) -> PackedInt32Array:
	var created := _manager(preference)
	created.add_wall(Rect2(60, -50, 20, 100))
	var zone := Reflector.new()
	zone.radius = 40.0
	zone.mode = Reflector.Mode.REVERSE
	zone.keep_script = true
	zone.position = Vector2(200, 0)
	add_child(zone)
	var rec := _WallRec.new()
	rec.mgr = created
	var req := _shot(Vector2(130, 0), 4000.0, 0)
	req.behavior_id = created.register_behavior(rec)
	req.collide_world = true
	created.spawn(req)
	created.step(0.125)
	var out := PackedInt32Array()
	out.append(rec.reason)
	out.append(roundi(rec.normal.x * 1000.0))
	out.append(roundi(rec.normal.y * 1000.0))
	out.append(created.last_reflect_count)
	remove_child(zone)
	zone.free()
	_close(created)
	return out


func test_mirror_return_leg_wall_normal_matches_gdscript() -> void:
	if not _ready_native():
		return
	var gd := _return_leg("gdscript")
	var nat := _return_leg("native")
	assert_eq(nat, gd)
	assert_eq(gd[0], BulletPool.DespawnReason.WALL)
	assert_eq(gd[1], 1000)
	assert_eq(gd[2], 0)


func test_reflector_routes_to_the_pool_and_migrates_live_native_bullets() -> void:
	if not _ready_native():
		return
	var created := _manager("native")
	var id := _stable(created, created.spawn(_shot(Vector2(0, 40), 0.0, 0)))
	assert_true(created.is_native_id(id))
	created.step(DT)
	var snap := created.native.snapshot()
	var positions: PackedVector2Array = snap["pos"]
	var before := positions[0]
	var zone := Reflector.new()
	zone.radius = 30.0
	zone.position = Vector2(400, 40)
	add_child(zone)
	assert_eq(created.native.count(), 0, "live native bullets moved into the pool")
	assert_eq(created.pool.count, 1)
	assert_almost_eq(created.pool.pos[0].x, before.x, 0.001)
	assert_almost_eq(created.pool.pos[0].y, before.y, 0.001)
	assert_eq(created.pool.seq[0], 0)
	var during := created.spawn(_shot(Vector2(0, 80), 0.0, 0))
	assert_false(created.is_native_id(during), "a reflector keeps new spawns on the pool")
	assert_gte(created.pool.slot_of(_stable(created, during)), 0)
	remove_child(zone)
	zone.free()
	var again := created.spawn(_shot(Vector2(0, 120), 0.0, 0))
	assert_true(created.is_native_id(again), "no reflectors: hook-free spawns are native again")
	assert_eq(created.pool.count, 2, "bullets already in the pool stay there")
	_close(created)


## Registers a reflector from a hit callback. `where` is "hit", "can_hit",
## "despawn", "net_zero", or "spawn".
class _CallbackHook:
	extends BulletBehavior
	var host: Node
	var zone: Reflector
	var where := "hit"
	func _register() -> void:
		if zone != null and not zone.is_inside_tree():
			host.add_child(zone)

	func _unregister() -> void:
		if zone != null and zone.is_inside_tree():
			zone.get_parent().remove_child(zone)

	func on_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> void:
		if where == "hit":
			_register()
		elif where == "net_zero":
			_register()
			_unregister()

	func on_despawn(_pool: BulletPool, _index: int, _reason: int) -> void:
		if where == "despawn":
			_register()

	func can_hit(_pool: BulletPool, _index: int, _hurtbox: Hurtbox) -> bool:
		if where == "can_hit":
			_register()
		return true


func _callback_case(preference: String, where: String, bystander: bool) -> PackedInt32Array:
	var created := _manager(preference)
	var zone := Reflector.new()
	zone.radius = 20.0
	zone.position = Vector2(5000, 5000)
	var hook := _CallbackHook.new()
	hook.host = created
	hook.zone = zone
	hook.where = where
	var hook_id := created.register_behavior(hook)
	var box_a := Hurtbox.new()
	box_a.position = Vector2(0, 0)
	box_a.radius = 8.0
	box_a.layer = Layers.ENEMY
	created.add_child(box_a)
	var box_b := Hurtbox.new()
	box_b.position = Vector2(300, 0)
	box_b.radius = 8.0
	box_b.layer = Layers.ENEMY
	created.add_child(box_b)
	var hits_a: Array[int] = [0]
	var hits_b: Array[int] = [0]
	var spawned_is_native: Array[int] = [0]
	box_a.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void:
		hits_a[0] += 1
		# The hurtbox signal runs before the bullet hook, so hook_owner is still
		# clear. A plain spawn here is native unless the reflector count already moved.
		if where == "spawn":
			hook._register()
			var req := _shot(Vector2(0, 900), 0.0, 0)
			req.hit_mask = 0
			var id := created.spawn(req)
			if created.is_native_id(id):
				spawned_is_native[0] = 1)
	box_b.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits_b[0] += 1)
	var hooked := _shot(Vector2.ZERO, 0.0, 0)
	hooked.behavior_id = hook_id
	if where == "can_hit":
		hooked.can_hit_veto = true
	var plain := _shot(Vector2(300, 0), 0.0, 0)
	created.spawn(hooked)
	created.spawn(plain)
	var bystander_id := -1
	if bystander:
		bystander_id = created.spawn(_shot(Vector2(0, 700), 0.0, 0))
	created.step(DT)
	var native_left := 0
	if created.native != null:
		native_left = created.native.count()
	# A net-zero register leaves this bullet in the native store. A reflector
	# that sticks around has moved it into the pool by the end of the tick.
	var bystander_native := 0
	if bystander and created.is_native_bullet_alive(bystander_id):
		bystander_native = 1
	var out := PackedInt32Array()
	out.append(hits_a[0])
	out.append(hits_b[0])
	out.append(created.alive_count())
	out.append(native_left)
	out.append(created.pool.count)
	out.append(spawned_is_native[0])
	out.append(bystander_native)
	if zone.is_inside_tree():
		zone.get_parent().remove_child(zone)
	zone.free()
	_close(created)
	return out


func test_on_hit_reflector_does_not_drop_the_later_native_hit() -> void:
	if not _ready_native():
		return
	var gd := _callback_case("gdscript", "hit", false)
	var nat := _callback_case("native", "hit", false)
	assert_eq(nat, gd)
	assert_eq(gd[0], 1, "target A")
	assert_eq(gd[1], 1, "target B")
	assert_eq(nat[3], 0, "native store empty after the boundary")
	assert_eq(nat[4], nat[2], "every survivor is in the pool, none duplicated")


func test_can_hit_reflector_does_not_drop_the_later_native_hit() -> void:
	if not _ready_native():
		return
	var gd := _callback_case("gdscript", "can_hit", false)
	var nat := _callback_case("native", "can_hit", false)
	assert_eq(nat, gd)
	assert_eq(gd[0], 1, "target A")
	assert_eq(gd[1], 1, "target B")


func test_on_despawn_reflector_migrates_after_the_hits() -> void:
	if not _ready_native():
		return
	var gd := _callback_case("gdscript", "despawn", true)
	var nat := _callback_case("native", "despawn", true)
	assert_eq(gd[0], 1)
	assert_eq(gd[1], 1)
	assert_eq(nat, gd)
	assert_eq(nat[3], 0)
	assert_eq(nat[4], nat[2])


func test_callback_spawn_after_register_stays_on_the_pool() -> void:
	if not _ready_native():
		return
	var gd := _callback_case("gdscript", "spawn", false)
	var nat := _callback_case("native", "spawn", false)
	assert_eq(nat, gd)
	assert_eq(nat[0], 1)
	assert_eq(nat[1], 1)
	assert_eq(nat[5], 0, "the callback spawn was not a native id")
	assert_eq(nat[3], 0)
	assert_eq(nat[4], nat[2])


func test_register_then_unregister_in_one_callback_does_not_migrate() -> void:
	if not _ready_native():
		return
	var gd := _callback_case("gdscript", "net_zero", true)
	var nat := _callback_case("native", "net_zero", true)
	assert_eq(gd[0], 1)
	assert_eq(gd[1], 1)
	assert_eq(nat[0], gd[0])
	assert_eq(nat[1], gd[1])
	assert_eq(nat[6], 1, "the bystander stayed in the native store")


func test_on_hit_reflector_is_met_on_the_next_tick() -> void:
	if not _ready_native():
		return
	var gd := _meet_next_tick("gdscript")
	var nat := _meet_next_tick("native")
	assert_eq(nat, gd)
	assert_eq(gd[0], 1, "the hooked bullet hit its target")
	assert_eq(gd[1], 0, "the plain bullet turned before the body")
	assert_eq(gd[2], 0, "native store empty after the first tick's boundary")
	assert_eq(gd[3], 1, "the mirror caught the bullet on the next tick")
	assert_eq(gd[4], 1, "the bullet is enemy-owned")
	assert_eq(gd[5], -1, "the bullet is travelling back")


func _meet_next_tick(preference: String) -> PackedInt32Array:
	var created := _manager(preference)
	var zone := Reflector.new()
	zone.radius = 40.0
	zone.mode = Reflector.Mode.REVERSE
	zone.position = Vector2(200, 0)
	var hook := _CallbackHook.new()
	hook.host = created
	hook.zone = zone
	hook.where = "hit"
	var hook_id := created.register_behavior(hook)
	var box_a := Hurtbox.new()
	box_a.position = Vector2(0, 400)
	box_a.radius = 8.0
	box_a.layer = Layers.ENEMY
	created.add_child(box_a)
	var body := Hurtbox.new()
	body.position = Vector2(260, 0)
	body.radius = 8.0
	body.layer = Layers.ENEMY
	created.add_child(body)
	var hits_a: Array[int] = [0]
	var hits_body: Array[int] = [0]
	box_a.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits_a[0] += 1)
	body.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits_body[0] += 1)
	var hooked := _shot(Vector2(0, 400), 0.0, 0)
	hooked.behavior_id = hook_id
	# 2000 px/s from x=100 travels ~33 px this tick, short of the mirror at 160.
	# The next 0.05 s covers the mirror and turns around before the body at 260.
	var plain := _shot(Vector2(100, 0), 2000.0, 0)
	created.spawn(hooked)
	created.spawn(plain)
	created.step(DT)
	var native_after := 0
	if created.native != null:
		native_after = created.native.count()
	created.step(0.05)
	var enemy_owned := 0
	var vx_sign := 0
	for i in created.pool.count:
		if created.pool.owner_layer[i] == Layers.ENEMY:
			enemy_owned += 1
			var vx := created.pool.vel[i].x
			vx_sign = -1 if vx < 0.0 else (1 if vx > 0.0 else 0)
	var out := PackedInt32Array()
	out.append(hits_a[0])
	out.append(hits_body[0])
	out.append(native_after)
	out.append(created.last_reflect_count)
	out.append(enemy_owned)
	out.append(vx_sign)
	if zone.is_inside_tree():
		zone.get_parent().remove_child(zone)
	zone.free()
	_close(created)
	return out


func test_mid_flight_mirror_matches_gdscript() -> void:
	if not _ready_native():
		return
	assert_eq(_mid_flight("native"), _mid_flight("gdscript"))


func _mid_flight(preference: String) -> PackedInt32Array:
	var created := _manager(preference)
	var hook_id := created.register_behavior(_Hook.new())
	var plain := _shot(Vector2(100, 0), 4000.0, 0)
	var hooked := _shot(Vector2(100, 6), 4000.0, 0)
	hooked.behavior_id = hook_id
	created.spawn(plain)
	created.spawn(hooked)
	created.step(DT)
	var zone := Reflector.new()
	zone.radius = 40.0
	zone.mode = Reflector.Mode.REVERSE
	zone.position = Vector2(220, 0)
	add_child(zone)
	var body := Hurtbox.new()
	body.position = Vector2(250, 0)
	body.radius = 8.0
	body.layer = Layers.ENEMY
	add_child(body)
	var hits := 0
	body.hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits += 1)
	created.step(0.04)
	var reflected := 0
	for i in created.pool.count:
		if created.pool.owner_layer[i] == Layers.ENEMY:
			reflected += 1
	var native_left := 0
	if created.native != null:
		native_left = created.native.count()
	var out := PackedInt32Array()
	out.append(hits)
	out.append(created.last_reflect_count)
	out.append(reflected)
	out.append(native_left)
	remove_child(zone)
	zone.free()
	remove_child(body)
	body.free()
	_close(created)
	return out
