extends GutTest
## on_fire results: whatever on_fire hands back, the host keeps running.
## Unusual values are ignored and the spawn{} calls made before the return
## are kept; unusual error values are reported as a script error and spawn
## nothing. Same cases as test_lua_callback_returns.gd, for the on_fire entry.
## Runs on the GDScript pool and, when the library is built, the native sim.

const CHUNK := "fire.lua"

## Unusual return lists. Each one is a Lua expression list.
const UNUSUAL := [
	"coroutine.create(function() end), {}",
	"coroutine.create(function() end), 1",
	"coroutine.create(function() end), nil",
	"coroutine.create(print), 'x', true",
	"1, coroutine.create(function() end), {}",
	"{}, coroutine.create(function() end), {}",
	"coroutine.create(function() end)",
	"coroutine.running(), {}",
	"print, coroutine.create(print), print",
]

## Unusual error values, plus a few plain ones.
const UNUSUAL_ERRORS := [
	"error(setmetatable({}, { __tostring = function() error('inner') end }))",
	"error(setmetatable({}, { __tostring = function() while true do end end }))",
	"error(setmetatable({}, { __tostring = function() return {} end }))",
	"error(setmetatable({}, { __tostring = function() coroutine.yield() return 'y' end }))",
	"assert(false, setmetatable({}, { __tostring = function() error('inner') end }))",
	"error(coroutine.create(function() end))",
	"error({})",
	"error()",
]

var _mgrs: Array[BulletManager] = []


func before_each() -> void:
	ScriptWarnings.reset()


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()


func _host() -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	assert_true(host.is_ready(), "sandbox did not build")
	return host


func _ctx() -> ShotContext:
	var c := ShotContext.new()
	c.muzzle_position = Vector2(3, 4)
	c.aim_angle = 0.25
	c.target_mask = Layers.ENEMY
	return c


func test_on_fire_ignores_unusual_return_values() -> void:
	var host := _host()
	for values: String in UNUSUAL:
		var loaded := host.load_string("return { on_fire = function(ctx) spawn { angle = ctx.aim } return %s end }" % values, CHUNK)
		assert_true(loaded.ok, loaded.error)
		for _i in 2:
			var result := host.call_fire(_ctx())
			assert_true(result.ok, "%s -> %s" % [values, result.error])
			assert_true(result.value == null, "no value is kept (%s)" % values)
			assert_eq(host.take_pending_spawns().size(), 1, "the spawn before the return is kept (%s)" % values)


func test_unusual_values_from_a_suspended_on_fire_are_ignored() -> void:
	var host := _host()
	for values: String in UNUSUAL:
		var loaded := host.load_string(
			"return { on_fire = function(ctx) spawn { angle = 1 } coroutine.yield(%s) spawn { angle = 2 } end }" % values, CHUNK
		)
		assert_true(loaded.ok, loaded.error)
		var result := host.call_fire(_ctx())
		assert_true(result.ok, "%s -> %s" % [values, result.error])
		assert_eq(host.take_pending_spawns().size(), 2, values)


func test_unusual_error_values_from_on_fire_are_reported() -> void:
	var host := _host()
	for body: String in UNUSUAL_ERRORS:
		var loaded := host.load_string("return { on_fire = function(ctx) spawn { angle = 0 } %s end }" % body, CHUNK)
		assert_true(loaded.ok, loaded.error)
		for _i in 2:
			var result := host.call_fire(_ctx())
			assert_false(result.ok, body)
			assert_true(result.stopped == "", "%s: reported as an error, not a stop" % body)
			assert_eq(host.take_pending_spawns().size(), 0, "%s: nothing spawned" % body)
	var after := host.load_string("return { on_fire = function(ctx) spawn { angle = 0 } end }", CHUNK)
	assert_true(after.ok, after.error)
	assert_true(host.call_fire(_ctx()).ok)
	assert_eq(host.take_pending_spawns().size(), 1)


func test_library_edits_do_not_change_the_fire_context() -> void:
	var host := _host()
	var loaded := host.load_string("""
		math.cos = function() while true do end end
		math.sin = function() return coroutine.create(print), {} end
		return { on_fire = function(ctx) spawn { angle = ctx.aim, pos = { x = ctx.aim_dir.x, y = ctx.aim_dir.y } } end }
	""".dedent(), CHUNK)
	assert_true(loaded.ok, loaded.error)
	var started := Time.get_ticks_msec()
	var result := host.call_fire(_ctx())
	assert_true(result.ok, result.error)
	assert_true(Time.get_ticks_msec() - started < 2000, "the fire call returned promptly")
	var spawns := host.take_pending_spawns()
	assert_eq(spawns.size(), 1)
	if spawns.size() == 1:
		var xv: Variant = spawns[0].get("x", null)
		var yv: Variant = spawns[0].get("y", null)
		var x: float = xv if xv is float else NAN
		var y: float = yv if yv is float else NAN
		assert_almost_eq(x, cos(0.25), 1e-6, "aim_dir.x is unchanged by the script's math table")
		assert_almost_eq(y, sin(0.25), 1e-6, "aim_dir.y is unchanged by the script's math table")


# ---- LuaShot on a BulletManager, both backends ----------------------------------

func _mgr(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 256
	manager.logical_cap = 256
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-4000, -4000, 8000, 8000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	_mgrs.append(manager)
	return manager


func _run_backend(preference: String) -> void:
	for values: String in UNUSUAL:
		var manager := _mgr(preference)
		var shot := LuaShot.new(manager)
		var applied := shot.apply("return { on_fire = function(ctx) for i = 1, 3 do spawn { angle = ctx.aim + i } end return %s end, on_hit = function(b, hit) return %s end }" % [values, values])
		assert_true(applied.ok, applied.error)
		for _i in 2:
			shot.fire(_ctx(), manager.emitter)
		manager.step(1.0 / 60.0)
		assert_eq(manager.backend, preference, values)
		assert_eq(manager.alive_count(), 6, "%s: every shot spawned" % values)
		assert_eq(shot.behavior().error_total, 0, values)


func test_on_fire_unusual_return_values_gdscript_backend() -> void:
	_run_backend("gdscript")


func test_on_fire_unusual_return_values_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_run_backend("native")
