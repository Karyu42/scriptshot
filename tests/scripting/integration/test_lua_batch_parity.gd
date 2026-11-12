extends GutTest
## Lua on_batch on the GDScript pool and the native sim, fixed 1/60 steps.
## Compares bullet state and ScriptWarnings. Row order is not part of the
## contract (sim rows come before pool rows). Pending without NativeBulletSim.

const DT := 1.0 / 60.0

var _open: Array[LuaBulletBehavior] = []
var _mgrs: Array[BulletManager] = []


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	_open.clear()


func _need_native() -> bool:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return false
	return true


func _mgr(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 64
	manager.logical_cap = 64
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	_mgrs.append(manager)
	return manager


func _load(manager: BulletManager, code: String) -> _Weapon:
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source(code, "weapon.lua", manager, -1)
	assert_true(loaded.ok, loaded.error)
	var weapon := _Weapon.new()
	weapon.behavior = behavior
	weapon.id = manager.register_behavior(behavior)
	return weapon


func _spawn(manager: BulletManager, weapon: _Weapon, n: int) -> void:
	for i in n:
		var req := ShotRequest.with_velocity(Vector2(i, 0), Vector2(30.0 + i, 0.0))
		req.lifetime = 5.0
		req.param_a = float(i)
		weapon.behavior.apply_to_request(req, weapon.id)
		assert_gte(manager.spawn(req), 0)


func _rows(manager: BulletManager, id: int) -> Array:
	var view := manager.gather_batch(id, DT)
	var rows: Array[String] = []
	for i in view.n:
		rows.append("%.3f|%.3f|%.3f|%.3f|%.3f|%.3f|%d" % [
			snappedf(view.px[i], 0.001), snappedf(view.py[i], 0.001),
			snappedf(view.vx[i], 0.001), snappedf(view.vy[i], 0.001),
			snappedf(view.pa[i], 0.001), snappedf(view.pb[i], 0.001), view.owner[i],
		])
	rows.sort()
	var out: Array = []
	for row in rows:
		out.append(row)
	return out


func _warn_text() -> String:
	var keys: Array[String] = []
	for key: String in ScriptWarnings._counts:
		keys.append(key)
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for key: String in keys:
		parts.append("%s=%d" % [key, ScriptWarnings._counts[key]])
	return "|".join(parts)


func _run(preference: String, code: String, n: int, ticks: int) -> _Run:
	ScriptWarnings.reset()
	var manager := _mgr(preference)
	var weapon := _load(manager, code)
	_spawn(manager, weapon, n)
	for _tick in ticks:
		manager.step(DT)
	assert_eq(manager.backend, preference)
	var result := _Run.new()
	result.alive = manager.alive_count()
	result.rows = _rows(manager, weapon.id)
	result.invalid = manager.pool.invalid_total + (manager.native.invalid_total() if manager.native != null else 0)
	result.disp = weapon.behavior.dispatches("on_batch")
	result.warn = _warn_text()
	if weapon.behavior.last_result != null:
		result.ok = weapon.behavior.last_result.ok
		result.err = weapon.behavior.last_result.error
	return result


func _expect_same(label: String, code: String, n: int = 3, ticks: int = 2) -> void:
	var gd := _run("gdscript", code, n, ticks)
	var nat := _run("native", code, n, ticks)
	assert_eq(nat.alive, gd.alive, label)
	assert_eq(nat.rows, gd.rows, label)
	assert_eq(nat.invalid, gd.invalid, label)
	assert_eq(nat.ok, gd.ok, label)
	assert_eq(nat.disp, gd.disp, label)
	assert_eq(nat.warn, gd.warn, "%s warnings" % label)
	if gd.ok:
		assert_eq(nat.err, gd.err, label)


func test_native_batch_parity_lua_steer() -> void:
	if not _need_native():
		return
	_expect_same("steer", """
		return {
			on_batch = function(v, dt)
				for i = 0, v.n - 1 do
					v.vx[i] = v.vx[i] + 10
					v.vy[i] = -5
					v.pa[i] = v.pa[i] * 2
					v.pb[i] = i
				end
			end
		}
	""".dedent())


func test_native_batch_parity_lua_non_finite_and_huge() -> void:
	if not _need_native():
		return
	_expect_same("nan_vx", "return { on_batch = function(v, dt) v.vx[0] = 0/0 end }")
	_expect_same("inf_vy", "return { on_batch = function(v, dt) v.vy[1] = 1/0 end }")
	_expect_same("nan_pa", "return { on_batch = function(v, dt) v.pa[2] = 0/0 end }")
	_expect_same("huge_speed", "return { on_batch = function(v, dt) v.vx[0] = 3e38; v.vy[0] = 3e38 end }")
	_expect_same("big_speed", "return { on_batch = function(v, dt) v.vx[0] = 1e6 end }")
	_expect_same("tp_nan", "return { on_batch = function(v, dt) v:teleport(0, 0/0, 1) end }")
	_expect_same("tp_huge", "return { on_batch = function(v, dt) v:teleport(0, 1e300, -1e300) end }")


func test_native_batch_parity_lua_commands() -> void:
	if not _need_native():
		return
	_expect_same("kill_spawn", """
		return {
			on_batch = function(v, dt)
				if v.n == 3 then
					v:kill(0)
					v:spawn_child(0, 0, 0, 7, 0, 1)
					v:spawn_child(1, 1, 1, 8, 0, 1)
					v:kill(1)
					v:teleport(2, 5, 5)
					v.vx[2] = 1
				end
			end
		}
	""".dedent())


func test_native_batch_parity_lua_reload_to_per_bullet() -> void:
	if not _need_native():
		return
	var gd := _reload("gdscript")
	var nat := _reload("native")
	assert_eq(nat.rows, gd.rows)
	assert_eq(nat.alive, gd.alive)
	assert_eq(nat.warn, gd.warn)


func _reload(preference: String) -> _Run:
	ScriptWarnings.reset()
	var manager := _mgr(preference)
	var weapon := _load(manager, """
		return {
			on_batch = function(v, dt)
				for i = 0, v.n - 1 do
					v.vx[i] = v.vx[i] + 1
				end
			end
		}
	""".dedent())
	_spawn(manager, weapon, 3)
	manager.step(DT)
	var reloaded := weapon.behavior.load_source("""
		return {
			on_batch = function(v, dt)
				for i = 0, v.n - 1 do
					v.vx[i] = v.vx[i] + 100
				end
			end,
			on_despawn = function(b, why) end
		}
	""".dedent(), "weapon.lua", manager, weapon.id)
	assert_true(reloaded.ok, reloaded.error)
	_spawn(manager, weapon, 2)
	manager.step(DT)
	assert_eq(manager.backend, preference)
	var result := _Run.new()
	result.alive = manager.alive_count()
	result.rows = _rows(manager, weapon.id)
	result.warn = _warn_text()
	return result


## pa and pb share BulletPool.hook_write. More than LIMIT of that key, mixed
## with a non-finite velocity and a speed clamp, so the printed subset and the
## last message follow row order. Native stays pending without the library.
func test_native_batch_parity_mixed_kill_warning_order() -> void:
	if not _need_native():
		return
	var code := """
		return {
			on_batch = function(v, dt)
				local kind = { "pa", "pb", "pa", "pb", "vx", "pa", "clamp", "pb", "pa", "pa" }
				for i = 0, v.n - 1 do
					local k = kind[i + 1]
					if k == "pa" then
						v.pa[i] = 0/0
					elseif k == "pb" then
						v.pb[i] = 0/0
					elseif k == "vx" then
						v.vx[i] = 0/0
					else
						v.vx[i] = 1e6
						v.vy[i] = -2e6
					end
				end
			end
		}
	""".dedent()
	var before := _tracked_warning_lines().size()
	var gd := _run("gdscript", code, 10, 1)
	var gd_printed := _warning_slice(before)
	var gd_last := _last_warnings()
	var gd_hook := ScriptWarnings.count("BulletPool.hook_write")
	var gd_hook_printed := ScriptWarnings.printed_count("BulletPool.hook_write")
	var mid := _tracked_warning_lines().size()
	var nat := _run("native", code, 10, 1)
	var nat_printed := _warning_slice(mid)
	assert_gt(gd_hook, ScriptWarnings.LIMIT, "past the print cap, the subset depends on order")
	assert_eq(gd_hook_printed, ScriptWarnings.LIMIT)
	assert_eq(nat.alive, gd.alive, "mixed kills")
	assert_eq(nat.invalid, gd.invalid, "mixed kills")
	assert_eq(nat.warn, gd.warn, "mixed kill counts")
	assert_eq(ScriptWarnings.count("BulletPool.hook_write"), gd_hook)
	assert_eq(ScriptWarnings.printed_count("BulletPool.hook_write"), gd_hook_printed)
	assert_eq(_last_warnings(), gd_last, "last message per key, including warnings past the cap")
	assert_eq(nat_printed, gd_printed, "printed warning order and subset")
	assert_string_contains(gd_printed[0], "param_a")
	assert_string_contains(gd_printed[1], "param_b")
	var saw_pa := false
	var saw_pb := false
	var hook_lines := 0
	for line in gd_printed:
		if not line.begins_with("BulletPool.hook_write:"):
			continue
		hook_lines += 1
		if "param_a" in line:
			saw_pa = true
		if "param_b" in line:
			saw_pb = true
	assert_eq(hook_lines, ScriptWarnings.LIMIT, "only the first LIMIT hook_write lines are printed")
	assert_true(saw_pa and saw_pb, "the printed subset includes both param fields")


## An older library sends totals and no warn_row / warn_code. That must not
## raise, and it still emits from the totals.
func test_batch_warnings_without_warn_keys_use_totals() -> void:
	ScriptWarnings.reset()
	var manager := _mgr("gdscript")
	var before := _tracked_warning_lines().size()
	manager._emit_native_batch_warnings({
		"vel_nonfinite": 1,
		"pa_nonfinite": 2,
		"pb_nonfinite": 2,
		"clamp_vx": PackedFloat32Array([5000.0]),
		"clamp_vy": PackedFloat32Array([0.0]),
	})
	var lines := _warning_slice(before)
	assert_eq(ScriptWarnings.count("BulletPool.set_velocity"), 1)
	assert_eq(ScriptWarnings.count("BulletPool.hook_write"), 4)
	assert_eq(ScriptWarnings.count("BulletPool.set_velocity.clamp.speed"), 1)
	assert_eq(lines.size(), 5)
	assert_string_contains(lines[0], "non-finite velocity")
	assert_string_contains(lines[1], "speed")
	assert_string_contains(lines[2], "param_a")
	assert_string_contains(lines[3], "param_a")
	assert_string_contains(lines[4], "param_b")
	assert_string_contains(ScriptWarnings.last_message("BulletPool.hook_write"), "param_b")


## A consistent row list is the pool order. Totals of the same counts would
## print every param_a before param_b.
func test_consistent_warn_rows_keep_pool_order() -> void:
	ScriptWarnings.reset()
	var manager := _mgr("gdscript")
	var before := _tracked_warning_lines().size()
	manager._emit_native_batch_warnings({
		"warn_row": PackedInt32Array([0, 1, 2]),
		"warn_code": PackedInt32Array([
			BulletManager.BATCH_WARN_PA,
			BulletManager.BATCH_WARN_PB,
			BulletManager.BATCH_WARN_PA,
		]),
		"vel_nonfinite": 0,
		"pa_nonfinite": 2,
		"pb_nonfinite": 1,
		"clamp_vx": PackedFloat32Array(),
		"clamp_vy": PackedFloat32Array(),
	})
	var lines := _warning_slice(before)
	assert_eq(lines.size(), ScriptWarnings.LIMIT)
	assert_string_contains(lines[0], "param_a")
	assert_string_contains(lines[1], "param_b")
	assert_string_contains(lines[2], "param_a")
	assert_string_contains(ScriptWarnings.last_message("BulletPool.hook_write"), "param_a")


## Each broken row list falls back to the totals. A negative row is one of
## those breaks; it is not skipped in place.
func test_inconsistent_warn_rows_fall_back_to_totals() -> void:
	var totals_only := {
		"vel_nonfinite": 1,
		"pa_nonfinite": 2,
		"pb_nonfinite": 1,
		"clamp_vx": PackedFloat32Array([5000.0]),
		"clamp_vy": PackedFloat32Array([0.0]),
	}
	var full_codes := PackedInt32Array([
		BulletManager.BATCH_WARN_VELOCITY,
		BulletManager.BATCH_WARN_SPEED,
		BulletManager.BATCH_WARN_PA,
		BulletManager.BATCH_WARN_PA,
		BulletManager.BATCH_WARN_PB,
	])
	var full_rows := PackedInt32Array([0, 1, 2, 3, 4])
	var expected := _warning_snapshot(totals_only)
	var missing_rows := totals_only.duplicate()
	missing_rows["warn_code"] = full_codes
	var short_rows := totals_only.duplicate()
	short_rows["warn_code"] = full_codes
	short_rows["warn_row"] = PackedInt32Array([0, 1])
	var negative_row := totals_only.duplicate()
	negative_row["warn_code"] = full_codes
	negative_row["warn_row"] = PackedInt32Array([0, 1, 2, -1, 4])
	var unknown_code := totals_only.duplicate()
	unknown_code["warn_code"] = PackedInt32Array([
		BulletManager.BATCH_WARN_VELOCITY,
		BulletManager.BATCH_WARN_SPEED,
		9,
		BulletManager.BATCH_WARN_PA,
		BulletManager.BATCH_WARN_PB,
	])
	unknown_code["warn_row"] = full_rows
	var extra_speeds := {
		"vel_nonfinite": 0,
		"pa_nonfinite": 0,
		"pb_nonfinite": 0,
		"clamp_vx": PackedFloat32Array([5000.0]),
		"clamp_vy": PackedFloat32Array([0.0]),
		"warn_code": PackedInt32Array([BulletManager.BATCH_WARN_SPEED, BulletManager.BATCH_WARN_SPEED]),
		"warn_row": PackedInt32Array([0, 1]),
	}
	var tally := {
		"vel_nonfinite": 0,
		"pa_nonfinite": 2,
		"pb_nonfinite": 0,
		"clamp_vx": PackedFloat32Array(),
		"clamp_vy": PackedFloat32Array(),
		"warn_code": PackedInt32Array([BulletManager.BATCH_WARN_PA]),
		"warn_row": PackedInt32Array([0]),
	}
	var cases: Array[Dictionary] = [missing_rows, short_rows, negative_row, unknown_code, extra_speeds, tally]
	for report in cases:
		assert_eq(_warning_snapshot(report), _warning_snapshot(_totals_only(report)))
	assert_eq(_warning_snapshot(missing_rows), expected)


func test_native_spawn_clamp_warnings_stop_when_the_store_is_full() -> void:
	if not _need_native():
		return
	var gd := _capped_clamp_warnings("gdscript")
	var nat := _capped_clamp_warnings("native")
	assert_eq(nat, gd, "refused over-cap shots are not clamp warnings")


func test_native_spawn_clamp_matches_the_pool() -> void:
	if not _need_native():
		return
	var gd := _spawn_clamp_warnings("gdscript")
	var nat := _spawn_clamp_warnings("native")
	assert_eq(nat, gd, "spawn-time clamp warnings")


func _spawn_clamp_warnings(preference: String) -> Dictionary:
	ScriptWarnings.reset()
	var manager := _mgr(preference)
	var plain := ShotRequest.with_velocity(Vector2(4, 0), Vector2(40, 0))
	plain.lifetime = 5.0
	assert_gte(manager.spawn(plain), 0)
	var plain_warns := _warn_text()
	var over := ShotRequest.with_velocity(Vector2(10, 0), Vector2(9000, 0))
	over.lifetime = 1000.0
	over.radius = 1.0e9
	over.param_a = 1.0e31
	assert_gte(manager.spawn(over), 0)
	var speed := ScriptWarnings.count("BulletPool.spawn.clamp.speed")
	var radius := ScriptWarnings.count("BulletPool.spawn.clamp.radius")
	var life := ScriptWarnings.count("BulletPool.spawn.clamp.lifetime")
	var pa := ScriptWarnings.count("BulletPool.spawn.clamp.param_a")
	assert_eq(plain_warns, "", "an in-range spawn stays silent")
	assert_gt(speed, 0)
	assert_gt(radius, 0)
	assert_gt(life, 0)
	assert_gt(pa, 0)
	return {
		"speed": speed,
		"radius": radius,
		"life": life,
		"pa": pa,
		"speed_msg": ScriptWarnings.last_message("BulletPool.spawn.clamp.speed"),
		"radius_msg": ScriptWarnings.last_message("BulletPool.spawn.clamp.radius"),
		"life_msg": ScriptWarnings.last_message("BulletPool.spawn.clamp.lifetime"),
		"pa_msg": ScriptWarnings.last_message("BulletPool.spawn.clamp.param_a"),
	}


func _capped_clamp_warnings(preference: String) -> Dictionary:
	ScriptWarnings.reset()
	var manager := _mgr(preference)
	manager.set_bullet_limits(4, 0)
	var speeds: Array[float] = [5000.0, 6000.0, 7000.0, 8000.0, 9000.0, 11000.0, 13000.0, 15000.0]
	var spawned := 0
	for i in speeds.size():
		var req := ShotRequest.with_velocity(Vector2(float(i), 0.0), Vector2(speeds[i], 0.0))
		req.lifetime = 5.0
		if manager.spawn(req) >= 0:
			spawned += 1
	var count := ScriptWarnings.count("BulletPool.spawn.clamp.speed")
	var last := ScriptWarnings.last_message("BulletPool.spawn.clamp.speed")
	assert_eq(spawned, 4)
	assert_eq(manager.alive_count(), 4)
	assert_eq(count, 4)
	assert_string_contains(last, "8000")
	return {
		"spawned": spawned,
		"alive": manager.alive_count(),
		"count": count,
		"last": last,
	}


func _totals_only(report: Dictionary) -> Dictionary:
	var copy := report.duplicate()
	copy.erase("warn_row")
	copy.erase("warn_code")
	return copy


func _warning_snapshot(report: Dictionary) -> Dictionary:
	ScriptWarnings.reset()
	var manager := _mgr("gdscript")
	manager._emit_native_batch_warnings(report)
	return {
		"vel": ScriptWarnings.count("BulletPool.set_velocity"),
		"hook": ScriptWarnings.count("BulletPool.hook_write"),
		"speed": ScriptWarnings.count("BulletPool.set_velocity.clamp.speed"),
		"vel_msg": ScriptWarnings.last_message("BulletPool.set_velocity"),
		"hook_msg": ScriptWarnings.last_message("BulletPool.hook_write"),
		"speed_msg": ScriptWarnings.last_message("BulletPool.set_velocity.clamp.speed"),
	}


func _tracked_warning_lines() -> Array[String]:
	var tracker: Object = gut.error_tracker
	var out: Array[String] = []
	for e: Object in tracker.call("get_errors_for_test"):
		var text := str(e.get("code"))
		if text.begins_with("BulletPool.hook_write:") or text.begins_with("BulletPool.set_velocity"):
			out.append(text)
	return out


func _warning_slice(from_index: int) -> Array[String]:
	var lines := _tracked_warning_lines()
	var out: Array[String] = []
	for i in range(from_index, lines.size()):
		out.append(lines[i])
	return out


func _last_warnings() -> Dictionary:
	return {
		"BulletPool.hook_write": ScriptWarnings.last_message("BulletPool.hook_write"),
		"BulletPool.set_velocity": ScriptWarnings.last_message("BulletPool.set_velocity"),
		"BulletPool.set_velocity.clamp.speed": ScriptWarnings.last_message("BulletPool.set_velocity.clamp.speed"),
	}


class _Weapon:
	var behavior: LuaBulletBehavior
	var id := 0


class _Run:
	var alive := 0
	var rows: Array = []
	var invalid := 0
	var ok := true
	var err := ""
	var disp := 0
	var warn := ""
