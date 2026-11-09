extends GutTest
## Batch hooks on the GDScript pool and, when the extension is built, the native
## sim. Reads happen after integrate. Writes land before collision and do not
## move the bullet again this tick. A stale id never writes a replacement.

const DT := 1.0 / 60.0
const POS_EPS := 0.01
const VEL_EPS := 0.05


class Steer:
	extends BulletBehavior
	var owners: Array[int] = []
	var positions: Array[Vector2] = []
	var calls := 0

	func on_update_batch(batch: BatchView) -> void:
		calls += 1
		owners.clear()
		positions.clear()
		for i in batch.n:
			owners.append(batch.owner[i])
			positions.append(Vector2(batch.px[i], batch.py[i]))
			batch.vx[i] = batch.vx[i] + cos(batch.age[i] * 6.0) * 40.0 * batch.dt
			batch.pa[i] = batch.age[i]


class Counter:
	extends BulletBehavior
	var calls := 0

	func on_update_batch(_batch: BatchView) -> void:
		calls += 1


class Killer:
	extends BulletBehavior
	func on_update_batch(batch: BatchView) -> void:
		if batch.n < 2:
			return
		batch.kill(0)
		var req := ShotRequest.with_velocity(Vector2(batch.px[1] + 10.0, batch.py[1]), Vector2(8.0, 0.0))
		req.lifetime = 3.0
		req.owner_layer = Layers.ENEMY
		batch.spawn_child(1, req)


class PerBullet:
	extends BulletBehavior
	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		pool.vel[index] = Vector2(30.0, 0.0)


class BatchFixed:
	extends BulletBehavior
	func on_update_batch(batch: BatchView) -> void:
		for i in batch.n:
			batch.vx[i] = 60.0
			batch.vy[i] = 0.0


class NaNWrite:
	extends BulletBehavior
	func on_update_batch(batch: BatchView) -> void:
		if batch.n > 0:
			batch.vx[0] = NAN


class ClampWrite:
	extends BulletBehavior
	func on_update_batch(batch: BatchView) -> void:
		if batch.n > 0:
			batch.vx[0] = 10000.0
			batch.vy[0] = 0.0


class TeleportWrite:
	extends BulletBehavior
	func on_update_batch(batch: BatchView) -> void:
		if batch.n > 0:
			batch.teleport(0, 50.0, -20.0)


func _manager(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 64
	manager.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	return manager


func _shot(behavior_id: int, vel: Vector2, owner: int = Layers.PLAYER) -> ShotRequest:
	var req := ShotRequest.with_velocity(Vector2.ZERO, vel)
	req.lifetime = 5.0
	req.behavior_id = behavior_id
	req.owner_layer = owner
	req.hit_mask = Layers.hostile_to(owner) if owner != 0 else 0
	req.param_a = 1.5
	return req


func _run_steer(preference: String) -> Dictionary:
	var manager := _manager(preference)
	var steer := Steer.new()
	var id := manager.register_behavior(steer)
	manager.spawn(_shot(id, Vector2(60.0, 0.0), Layers.PLAYER))
	manager.spawn(_shot(id, Vector2(0.0, 120.0), Layers.ENEMY))
	var rows: Array[Dictionary] = []
	for _tick in 3:
		manager.step(DT)
		var snap := _rows(manager)
		rows.append({"rows": snap, "owners": steer.owners.duplicate(), "positions": steer.positions.duplicate(), "calls": steer.calls})
	return {"backend": manager.backend, "native": manager.native.count() if manager.native != null else 0, "pool": manager.pool.count, "hooked": manager.pool.hooked_count, "ticks": rows}


func _rows(manager: BulletManager) -> Array:
	var out: Array = []
	if manager.native != null:
		var snap := manager.native.snapshot()
		var pos: PackedVector2Array = snap["pos"]
		var vel: PackedVector2Array = snap["vel"]
		var owner: PackedInt32Array = snap["owner"]
		for i in pos.size():
			out.append({"pos": pos[i], "vel": vel[i], "owner": owner[i]})
	for i in manager.pool.count:
		if manager.pool.dead_reason[i] != 0:
			continue
		out.append({"pos": manager.pool.pos[i], "vel": manager.pool.vel[i], "owner": manager.pool.owner_layer[i], "pa": manager.pool.param_a[i]})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector2 = a["pos"]
		var pb: Vector2 = b["pos"]
		if absf(pa.y - pb.y) > 0.001:
			return pa.y < pb.y
		return pa.x < pb.x
	)
	return out


func test_gd_batch_write_is_visible_and_does_not_move_this_tick() -> void:
	var ran := _run_steer("gdscript")
	var backend: String = ran["backend"]
	var pool_n: int = ran["pool"]
	var hooked_n: int = ran["hooked"]
	assert_eq(backend, "gdscript")
	assert_eq(pool_n, 2)
	assert_eq(hooked_n, 0, "a batch-only bullet is not a per-bullet hook")
	var first: Dictionary = ran["ticks"][0]
	var calls: int = first["calls"]
	assert_eq(calls, 1)
	var positions: Array = first["positions"]
	var rows: Array = first["rows"]
	assert_eq(positions.size(), 2)
	assert_eq(rows.size(), 2)
	# Slot order: player (60, 0) then enemy (0, 120). Integrate used the spawn
	# velocity. The hook's new velocity is stored, not travelled.
	var read0: Vector2 = positions[0]
	var read1: Vector2 = positions[1]
	assert_almost_eq(read0.x, 1.0, POS_EPS)
	assert_almost_eq(read1.y, 2.0, POS_EPS)
	var moved: Dictionary = rows[0]
	var moved_pos: Vector2 = moved["pos"]
	var moved_vel: Vector2 = moved["vel"]
	assert_almost_eq(moved_pos.x, 1.0, POS_EPS)
	assert_gt(absf(moved_vel.x - 60.0), 0.01)


class PublicColumnForge:
	extends BulletBehavior

	func on_update_batch(batch: BatchView) -> void:
		if batch.n < 2:
			return
		batch.id[0] = batch.id[1]
		batch.vx[0] = 77.0
		batch.vy[0] = 0.0
		batch.vx[1] = 3.0
		batch.vy[1] = 0.0
		batch.owner[0] = Layers.ENEMY
		var req := ShotRequest.with_velocity(Vector2(8, 8), Vector2(4, 0))
		req.lifetime = 2.0
		req.owner_layer = Layers.ENEMY
		batch.spawn_child(0, req)


func test_public_columns_cannot_redirect_a_commit() -> void:
	var manager := _manager("gdscript")
	var id := manager.register_behavior(PublicColumnForge.new())
	var a := manager.spawn(_shot(id, Vector2(10.0, 0.0), Layers.PLAYER))
	var b := manager.spawn(_shot(id, Vector2(20.0, 0.0), Layers.PLAYER))
	manager.step(DT)
	assert_eq(manager.pool.vel[a], Vector2(77.0, 0.0))
	assert_eq(manager.pool.vel[b], Vector2(3.0, 0.0))
	assert_eq(manager.pool.owner_layer[a], Layers.PLAYER)
	var child := -1
	for i in manager.pool.count:
		if manager.pool.vel[i] == Vector2(4.0, 0.0):
			child = i
	assert_ne(child, -1)
	assert_eq(manager.pool.owner_layer[child], Layers.PLAYER, "spawn uses the captured owner, not the column")


class SpawnFlood:
	extends BulletBehavior

	var msec := 0.0
	var dropped_spawns := 0
	var dropped_commands := 0

	func on_update_batch(batch: BatchView) -> void:
		var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(2.0, 0.0))
		req.lifetime = 2.0
		var t0 := Time.get_ticks_usec()
		for i in 5000:
			batch.spawn_child(0, req)
		for i in 5000:
			batch.kill(0)
		msec = float(Time.get_ticks_usec() - t0) / 1000.0
		dropped_spawns = batch.dropped_spawns
		dropped_commands = batch.dropped_commands


func test_over_cap_calls_keep_the_first_and_stay_fast() -> void:
	var manager := BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 8000
	manager.logical_cap = 8000
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-20000, -20000, 40000, 40000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	var flood := SpawnFlood.new()
	var id := manager.register_behavior(flood)
	var slot := manager.spawn(_shot(id, Vector2(1.0, 0.0)))
	var parent_id := manager.pool.id_of(slot)
	manager.step(DT)
	assert_eq(flood.dropped_spawns, 5000 - BatchView.SPAWN_CAP)
	# The 256 kept spawns take command slots, so the kill loop fills the rest.
	var kill_room := BatchView.CMD_CAP - BatchView.SPAWN_CAP
	assert_eq(flood.dropped_commands, 5000 - kill_room)
	assert_lt(flood.msec, 16.6, "5000 calls took %.2f ms" % flood.msec)
	assert_false(manager.pool.is_alive(parent_id), "the first kill is inside the command cap")
	assert_eq(manager.alive_count(), BatchView.SPAWN_CAP)


func test_gd_owner_is_read_and_unchanged() -> void:
	var ran := _run_steer("gdscript")
	var first: Dictionary = ran["ticks"][0]
	var owners: Array = first["owners"]
	var owner0: int = owners[0]
	var owner1: int = owners[1]
	assert_eq(owner0, Layers.PLAYER)
	assert_eq(owner1, Layers.ENEMY)
	var rows: Array = first["rows"]
	var row0: Dictionary = rows[0]
	var row1: Dictionary = rows[1]
	var own0: int = row0["owner"]
	var own1: int = row1["owner"]
	assert_eq(own0, Layers.PLAYER)
	assert_eq(own1, Layers.ENEMY)


func test_empty_batch_is_not_dispatched() -> void:
	var manager := _manager("gdscript")
	var counter := Counter.new()
	manager.register_behavior(counter)
	manager.step(DT)
	assert_eq(counter.calls, 0)
	assert_eq(manager.alive_count(), 0)


func test_gd_kill_and_spawn_from_the_batch_hook() -> void:
	var manager := _manager("gdscript")
	var id := manager.register_behavior(Killer.new())
	manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	var parent := manager.spawn(_shot(id, Vector2(0.0, 0.0)))
	manager.step(DT)
	assert_eq(manager.pool.count, 2, "one killed, one spawned, the parent remains")
	assert_eq(manager.pool.owner_layer[parent], Layers.PLAYER)
	var child := 1 if parent == 0 else 0
	# The killed slot was flushed; the survivor and the child remain.
	var child_slot := -1
	for i in manager.pool.count:
		if manager.pool.vel[i] == Vector2(8.0, 0.0):
			child_slot = i
	assert_ne(child_slot, -1)
	assert_eq(manager.pool.owner_layer[child_slot], Layers.PLAYER, "the child inherits the parent, not the request")
	assert_almost_eq(manager.pool.pos[child_slot].x, manager.pool.pos[parent].x + 10.0, POS_EPS)
	assert_eq(manager.pool.behavior[child_slot], 0, "spawn_child leaves the request's behavior")
	assert_false(manager.is_native_id(child))


func test_gd_stale_id_does_not_write_the_replacement() -> void:
	var manager := _manager("gdscript")
	var steer := Steer.new()
	var id := manager.register_behavior(steer)
	var slot := manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	var old := manager.pool.id_of(slot)
	var view := manager.gather_batch(id, DT)
	assert_eq(view.id[0], old)
	manager.pool.mark_dead(slot, BulletPool.DespawnReason.MANUAL)
	manager.pool.flush_dead()
	var req := _shot(id, Vector2(5.0, 6.0))
	req.position = Vector2(3.0, 4.0)
	var replaced := manager.spawn(req)
	assert_ne(manager.pool.id_of(replaced), old)
	view.vx[0] = 999.0
	view.vy[0] = 998.0
	manager.commit_batch(view)
	assert_eq(manager.pool.vel[replaced], Vector2(5.0, 6.0))
	assert_eq(manager.pool.pos[replaced], Vector2(3.0, 4.0))
	assert_false(manager.pool.is_alive(old))


func test_gd_non_finite_write_kills_as_invalid() -> void:
	var manager := _manager("gdscript")
	var id := manager.register_behavior(NaNWrite.new())
	var before := manager.pool.invalid_total
	manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	manager.step(DT)
	assert_gt(manager.pool.invalid_total, before)
	assert_eq(manager.alive_count(), 0, "INVALID is flushed with the rest of the dead")


func test_gd_speed_is_clamped() -> void:
	var manager := _manager("gdscript")
	var id := manager.register_behavior(ClampWrite.new())
	manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	manager.step(DT)
	assert_eq(manager.pool.vel[0], Vector2(BulletLimits.MAX_SPEED, 0.0))
	assert_eq(manager.pool.dead_reason[0], 0)


func test_gd_teleport_is_the_position_after_the_step() -> void:
	var manager := _manager("gdscript")
	var id := manager.register_behavior(TeleportWrite.new())
	manager.spawn(_shot(id, Vector2(60.0, 0.0)))
	manager.step(DT)
	assert_eq(manager.pool.pos[0], Vector2(50.0, -20.0))
	assert_eq(manager.pool.prev_pos[0], Vector2(50.0, -20.0))


func test_mixed_scripts_keep_per_bullet_hooks_on_the_pool() -> void:
	var manager := _manager("gdscript")
	var per_id := manager.register_behavior(PerBullet.new())
	var batch_id := manager.register_behavior(BatchFixed.new())
	manager.spawn(_shot(per_id, Vector2(10.0, 0.0)))
	manager.spawn(_shot(batch_id, Vector2(10.0, 0.0)))
	manager.step(DT)
	assert_eq(manager.pool.hooked_count, 1)
	assert_eq(manager.pool.count, 2)
	var saw_per := false
	var saw_batch := false
	for i in manager.pool.count:
		if manager.pool.vel[i] == Vector2(30.0, 0.0):
			saw_per = true
			assert_almost_eq(manager.pool.pos[i].x, 10.0 * DT, POS_EPS)
		if manager.pool.vel[i] == Vector2(60.0, 0.0):
			saw_batch = true
			assert_almost_eq(manager.pool.pos[i].x, 10.0 * DT, POS_EPS)
	assert_true(saw_per)
	assert_true(saw_batch)


func test_native_matches_gd_pos_vel_and_owner() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var gd := _run_steer("gdscript")
	var nat := _run_steer("native")
	var backend: String = nat["backend"]
	var native_n: int = nat["native"]
	var pool_n: int = nat["pool"]
	var hooked_n: int = nat["hooked"]
	assert_eq(backend, "native")
	assert_eq(native_n, 2)
	assert_eq(pool_n, 0)
	assert_eq(hooked_n, 0)
	for tick in 3:
		var a: Dictionary = gd["ticks"][tick]
		var b: Dictionary = nat["ticks"][tick]
		var calls_a: int = a["calls"]
		var calls_b: int = b["calls"]
		assert_eq(calls_b, calls_a)
		var ao: Array = a["owners"]
		var bo: Array = b["owners"]
		assert_eq(bo.size(), ao.size())
		for i in ao.size():
			var xa: int = ao[i]
			var xb: int = bo[i]
			assert_eq(xb, xa)
		var ap: Array = a["positions"]
		var bp: Array = b["positions"]
		for i in ap.size():
			var pa: Vector2 = ap[i]
			var pb: Vector2 = bp[i]
			assert_lt(pa.distance_to(pb), POS_EPS, "tick %d read pos" % tick)
		var ar: Array = a["rows"]
		var br: Array = b["rows"]
		assert_eq(br.size(), ar.size())
		for i in ar.size():
			var ra: Dictionary = ar[i]
			var rb: Dictionary = br[i]
			var rpa: Vector2 = ra["pos"]
			var rpb: Vector2 = rb["pos"]
			var rva: Vector2 = ra["vel"]
			var rvb: Vector2 = rb["vel"]
			assert_lt(rpa.distance_to(rpb), POS_EPS, "tick %d pos" % tick)
			assert_lt(rva.distance_to(rvb), VEL_EPS, "tick %d vel" % tick)
			var oa: int = ra["owner"]
			var ob: int = rb["owner"]
			assert_eq(ob, oa)


func test_native_stale_id_does_not_write_the_replacement() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var manager := _manager("native")
	var id := manager.register_behavior(Steer.new())
	var old := manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	assert_true(manager.is_native_id(old))
	var view := manager.gather_batch(id, DT)
	assert_eq(view.native_rows, 1)
	assert_true(manager.native.kill(old))
	manager.native.finish_delivery()
	var req := _shot(id, Vector2(5.0, 6.0))
	req.position = Vector2(3.0, 4.0)
	var replaced := manager.spawn(req)
	assert_ne(replaced, old)
	assert_true(manager.is_native_id(replaced))
	view.vx[0] = 999.0
	view.vy[0] = 998.0
	manager.commit_batch(view)
	var again := manager.gather_batch(id, DT)
	assert_eq(again.n, 1)
	assert_eq(again.id[0], replaced)
	assert_almost_eq(again.vx[0], 5.0, 0.001)
	assert_almost_eq(again.vy[0], 6.0, 0.001)
	assert_almost_eq(again.px[0], 3.0, 0.001)
	assert_false(manager.native.is_alive(old))


func test_native_spawn_from_the_hook_stays_on_the_pool() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var manager := _manager("native")
	var id := manager.register_behavior(Killer.new())
	manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	manager.spawn(_shot(id, Vector2(0.0, 0.0)))
	manager.step(DT)
	assert_eq(manager.native.count(), 1, "the killed native bullet is gone, the parent remains")
	assert_eq(manager.pool.count, 1, "the child stayed on the pool")
	assert_eq(manager.pool.vel[0], Vector2(8.0, 0.0))
	assert_eq(manager.pool.owner_layer[0], Layers.PLAYER)
	assert_eq(manager.pool.behavior[0], 0)
	assert_almost_eq(manager.pool.pos[0].y, 0.0, POS_EPS)


func test_native_mixed_with_a_per_bullet_hook() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var manager := _manager("native")
	var per_id := manager.register_behavior(PerBullet.new())
	var batch_id := manager.register_behavior(BatchFixed.new())
	var per := manager.spawn(_shot(per_id, Vector2(10.0, 0.0)))
	var batch := manager.spawn(_shot(batch_id, Vector2(10.0, 0.0)))
	assert_false(manager.is_native_id(per))
	assert_true(manager.is_native_id(batch))
	manager.step(DT)
	assert_eq(manager.pool.hooked_count, 1)
	assert_eq(manager.pool.vel[per], Vector2(30.0, 0.0))
	assert_almost_eq(manager.pool.pos[per].x, 10.0 * DT, POS_EPS)
	var view := manager.gather_batch(batch_id, DT)
	assert_eq(view.n, 1)
	assert_almost_eq(view.vx[0], 60.0, 0.001)
	assert_almost_eq(view.px[0], 10.0 * DT, POS_EPS)
	assert_eq(view.owner[0], Layers.PLAYER)


func test_native_empty_batch_and_invalid_write() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	var manager := _manager("native")
	var counter := Counter.new()
	manager.register_behavior(counter)
	manager.step(DT)
	assert_eq(counter.calls, 0)
	var id := manager.register_behavior(NaNWrite.new())
	var bullet := manager.spawn(_shot(id, Vector2(10.0, 0.0)))
	manager.step(DT)
	assert_false(manager.native.is_alive(bullet))
	assert_gt(manager.native.invalid_total(), 0)
	var clamped := _manager("native")
	var cid := clamped.register_behavior(ClampWrite.new())
	var live := clamped.spawn(_shot(cid, Vector2(10.0, 0.0)))
	clamped.step(DT)
	var view := clamped.gather_batch(cid, DT)
	assert_eq(view.id[0], live)
	assert_almost_eq(view.vx[0], BulletLimits.MAX_SPEED, 0.001)


class BatchOverwrite:
	extends BulletBehavior
	var calls := 0
	var rows := 0

	func on_update_batch(batch: BatchView) -> void:
		calls += 1
		rows = batch.n
		for i in batch.n:
			batch.vx[i] = 250.0
			batch.vy[i] = 0.0


class ReflectBeforeBatch:
	extends BulletBehavior
	var target_id := -1
	var keep_script := false
	var reflected_ok := false

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		reflected_ok = emitter.reflect_bullet(target_id, Layers.ENEMY, true, BulletPool.REFLECTED_DAMAGE, keep_script)


func _reflect_before_batch(preference: String, keep_script: bool) -> Dictionary:
	var manager := _manager(preference)
	var batch_behavior := BatchOverwrite.new()
	var hook := ReflectBeforeBatch.new()
	hook.keep_script = keep_script
	var batch_id := manager.register_behavior(batch_behavior)
	var hook_id := manager.register_behavior(hook)
	var spawned := manager.spawn(_shot(batch_id, Vector2(300.0, 0.0)))
	var bullet_id := spawned if manager.is_native_id(spawned) else manager.pool.id_of(spawned)
	hook.target_id = bullet_id
	manager.spawn(_shot(hook_id, Vector2.ZERO))
	manager.step(DT)
	var vel := Vector2.ZERO
	var owner := -1
	if manager.is_native_id(bullet_id):
		var snap := manager.native.snapshot()
		var ids: PackedInt64Array = snap["id"]
		var vels: PackedVector2Array = snap["vel"]
		var owners: PackedInt32Array = snap["owner"]
		for i in ids.size():
			if ids[i] == bullet_id:
				vel = vels[i]
				owner = owners[i]
	else:
		var slot := manager.pool.slot_of(bullet_id)
		vel = manager.pool.vel[slot]
		owner = manager.pool.owner_layer[slot]
	var still := 0
	if manager.native != null and manager.is_native_id(bullet_id):
		still = manager.native.count_with_behavior(batch_id)
	elif not manager.is_native_id(bullet_id):
		still = 1 if manager.pool.behavior[manager.pool.slot_of(bullet_id)] == batch_id else 0
	return {
		"ok": hook.reflected_ok,
		"calls": batch_behavior.calls,
		"rows": batch_behavior.rows,
		"vel": vel,
		"owner": owner,
		"still": still,
	}


func _expect_reflect_before_batch(result: Dictionary, keep_script: bool) -> void:
	var ok: bool = result["ok"]
	var owner: int = result["owner"]
	var calls: int = result["calls"]
	var rows: int = result["rows"]
	var still: int = result["still"]
	var vel: Vector2 = result["vel"]
	assert_true(ok)
	assert_eq(owner, Layers.ENEMY)
	if keep_script:
		assert_eq(calls, 1)
		assert_eq(rows, 1)
		assert_eq(still, 1)
		assert_eq(vel, Vector2(250.0, 0.0))
	else:
		assert_eq(calls, 0, "the bullet left the behaviour before gather")
		assert_eq(still, 0)
		assert_eq(vel, Vector2(-300.0, 0.0))


func test_reflect_before_the_batch_hook_matches_on_both_stores() -> void:
	_expect_reflect_before_batch(_reflect_before_batch("gdscript", false), false)
	_expect_reflect_before_batch(_reflect_before_batch("gdscript", true), true)
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_expect_reflect_before_batch(_reflect_before_batch("native", false), false)
	_expect_reflect_before_batch(_reflect_before_batch("native", true), true)
