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
