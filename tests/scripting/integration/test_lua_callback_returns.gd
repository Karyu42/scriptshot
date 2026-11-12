extends GutTest
## Host-to-Lua callback results: whatever a script hands back from a host
## call, the host keeps running. Unusual values are ignored (the
## first plain value is still the result) or reported as a script error.
## Runs on the GDScript pool and, when the library is built, the native sim.

const DT := 1.0 / 60.0
const CHUNK := "cb.lua"

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

const HOOKS := ["on_spawn", "on_hit", "can_hit", "on_death", "on_despawn", "on_expire", "on_wall", "on_tick"]

var _open: Array[LuaBulletBehavior] = []
var _mgrs: Array[BulletManager] = []


func before_each() -> void:
	ScriptWarnings.reset()


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	_open.clear()


## assert_eq for Variant results.
func _eq(got: Variant, want: Variant, label: String = "") -> void:
	@warning_ignore("unsafe_call_argument")
	assert_eq(got, want, label)


func _host() -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	assert_true(host.is_ready(), "sandbox did not build")
	return host


func _call(host: ScriptHost, hook: String) -> ScriptHost.RunResult:
	if hook == "on_hit" or hook == "can_hit":
		return host.call_hook(hook, 7, 1.0, 2.0, host.make_hit(1.0, 1.0, 2.0), true)
	if hook.begins_with("on_") and hook != "on_spawn" and hook != "on_tick":
		return host.call_hook(hook, 7, 1.0, 2.0, "lifetime", true)
	return host.call_hook(hook, 7, 1.0, 2.0)


func _batch(n: int) -> BatchView:
	var bv := BatchView.new()
	bv.n = n
	bv.dt = DT
	bv.id.resize(n)
	bv.px.resize(n)
	bv.py.resize(n)
	bv.vx.resize(n)
	bv.vy.resize(n)
	bv.age.resize(n)
	bv.pa.resize(n)
	bv.pb.resize(n)
	bv.owner.resize(n)
	return bv


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


func _weapon(manager: BulletManager, code: String, n: int) -> LuaBulletBehavior:
	var behavior := LuaBulletBehavior.new()
	_open.append(behavior)
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source(code, "weapon.lua", manager, -1)
	assert_true(loaded.ok, loaded.error)
	var id := manager.register_behavior(behavior)
	for i in n:
		var req := ShotRequest.with_velocity(Vector2(i, 0), Vector2(30.0 + i, 0.0))
		req.lifetime = 5.0
		behavior.apply_to_request(req, id)
		assert_gte(manager.spawn(req), 0)
	return behavior


# ---- ScriptHost -----------------------------------------------------------------

func test_chunk_with_unusual_return_values_loads() -> void:
	var host := _host()
	for values: String in UNUSUAL:
		var result := host.load_string("return %s" % values, CHUNK)
		assert_true(result.ok, "%s -> %s" % [values, result.error])
	var plain := host.load_string("return 6 * 7, coroutine.create(print), {}", CHUNK)
	assert_true(plain.ok, plain.error)
	_eq(plain.value, 42, "the first value is still the chunk result")
	var weapon := host.load_string(
		"return { on_spawn = function(b) end }, coroutine.create(print), {}", CHUNK
	)
	assert_true(weapon.ok, weapon.error)
	assert_true(host.has_callback("on_spawn"), "a weapon table returned first is still adopted")


func test_hooks_ignore_unusual_return_values() -> void:
	var host := _host()
	for values: String in UNUSUAL:
		var parts: PackedStringArray = []
		for hook: String in HOOKS:
			parts.append("%s = function(b, arg) return %s end" % [hook, values])
		var loaded := host.load_string("return { %s }" % ", ".join(parts), CHUNK)
		assert_true(loaded.ok, loaded.error)
		for hook: String in HOOKS:
			for _i in 2:
				var result := _call(host, hook)
				assert_true(result.ok, "%s returning %s -> %s" % [hook, values, result.error])
	var again := host.load_string("return { on_spawn = function(b) return 5 end }", CHUNK)
	assert_true(again.ok, again.error)
	_eq(_call(host, "on_spawn").value, 5, "a plain return value still comes through")


func test_can_hit_reads_the_first_boolean() -> void:
	var host := _host()
	var cases := {
		"false": false,
		"true": true,
		"false, {}": false,
		"false, coroutine.create(print), {}": false,
		"true, coroutine.create(print), 1": true,
		"nil, false": null,
	}
	for values: String in cases:
		var loaded := host.load_string("return { can_hit = function(b, t) return %s end }" % values, CHUNK)
		assert_true(loaded.ok, loaded.error)
		var result := _call(host, "can_hit")
		assert_true(result.ok, result.error)
		_eq(result.value, cases[values], values)


func test_on_batch_ignores_unusual_return_values() -> void:
	var host := _host()
	for values: String in UNUSUAL:
		var loaded := host.load_string("return { on_batch = function(v, dt) v.vx[0] = 9 return %s end }" % values, CHUNK)
		assert_true(loaded.ok, loaded.error)
		var bv := _batch(2)
		var result := host.call_batch(bv)
		assert_true(result.ok, "%s -> %s" % [values, result.error])
		assert_false(bv.discard, values)
		_eq(bv.vx[0], 9.0, "the write before the return is kept (%s)" % values)


func test_unusual_values_from_a_suspended_host_call_are_ignored() -> void:
	var host := _host()
	for values: String in UNUSUAL:
		var loaded := host.load_string("""
			return {
				on_spawn = function(b) coroutine.yield(%s) return 3 end,
				on_batch = function(v, dt) coroutine.yield(%s) end,
			}
		""".dedent() % [values, values], CHUNK)
		assert_true(loaded.ok, loaded.error)
		var hooked := _call(host, "on_spawn")
		assert_true(hooked.ok, "%s -> %s" % [values, hooked.error])
		_eq(hooked.value, 3, values)
		var batched := host.call_batch(_batch(1))
		assert_true(batched.ok, "%s -> %s" % [values, batched.error])
	var chunk := host.load_string("coroutine.yield(coroutine.create(print), {}) return 4", CHUNK)
	assert_true(chunk.ok, chunk.error)
	_eq(chunk.value, 4)


func test_script_coroutines_behave_as_before() -> void:
	var host := _host()
	var loaded := host.load_string("""
		return {
			on_spawn = function(b)
				local co = coroutine.create(function(a)
					local x = coroutine.yield(a + 1, coroutine.running(), {})
					return x * 2
				end)
				local ok1, y, th, t = coroutine.resume(co, 1)
				local ok2, z = coroutine.resume(co, 10)
				local gen = coroutine.wrap(function() coroutine.yield(1, 2) return 3 end)
				local g1, g2 = gen()
				local ok3, p1, p2 = pcall(function() return coroutine.running(), 8 end)
				if ok1 and y == 2 and type(th) == "thread" and type(t) == "table"
					and ok2 and z == 20 and g1 == 1 and g2 == 2 and gen() == 3
					and ok3 and type(p1) == "thread" and p2 == 8 then
					return "ok"
				end
				return "bad"
			end,
		}
	""".dedent(), CHUNK)
	assert_true(loaded.ok, loaded.error)
	var result := _call(host, "on_spawn")
	assert_true(result.ok, result.error)
	_eq(result.value, "ok")


func test_unusual_error_values_are_reported() -> void:
	var host := _host()
	for body: String in UNUSUAL_ERRORS:
		var loaded := host.load_string("return { on_spawn = function(b) %s end, on_batch = function(v, dt) %s end }" % [body, body], CHUNK)
		assert_true(loaded.ok, loaded.error)
		for _i in 2:
			var hooked := _call(host, "on_spawn")
			assert_false(hooked.ok, body)
			assert_true(hooked.stopped == "", "%s: reported as an error, not a stop" % body)
			var bv := _batch(1)
			var batched := host.call_batch(bv)
			assert_false(batched.ok, body)
			assert_true(bv.discard, body)
		var chunk := host.load_string(body, CHUNK)
		assert_false(chunk.ok, body)
	var named := host.load_string("error({})", CHUNK)
	assert_true("error value (table)" in named.error, named.error)
	var after := host.load_string("return 1", CHUNK)
	assert_true(after.ok, after.error)


func test_scripts_still_catch_their_own_error_values() -> void:
	var host := _host()
	var loaded := host.load_string("""
		return {
			on_spawn = function(b)
				local t = setmetatable({ code = 7 }, { __tostring = function() return "seven" end })
				local ok1, e1 = pcall(error, t)
				local ok2, e2 = pcall(function() assert(false, t) end)
				local co = coroutine.create(function() error(t) end)
				local ok3, e3 = coroutine.resume(co)
				local ok4, e4 = pcall(coroutine.wrap(function() error(t) end))
				local ok5, e5 = xpcall(function() error(t) end, function(e) return e end)
				local ok6, e6 = pcall(error, "plain")
				if not ok1 and e1 == t and not ok2 and e2 == t and not ok3 and e3 == t
					and not ok4 and e4 == t and not ok5 and e5 == t and tostring(e1) == "seven"
					and not ok6 and e6 == "plain" then
					return "ok"
				end
				return "bad"
			end,
		}
	""".dedent(), CHUNK)
	assert_true(loaded.ok, loaded.error)
	var result := _call(host, "on_spawn")
	assert_true(result.ok, result.error)
	_eq(result.value, "ok")


func test_error_messages_keep_their_positions() -> void:
	var host := _host()
	var cases := {
		"error('boom')": "cb.lua:1: boom",
		"error('boom', 0)": "boom",
		"error('boom', 2)": "boom",
		"local function f() error('deep', 2) end f()": "cb.lua:1: deep",
		"assert(false)": "cb.lua:1: assertion failed!",
		"assert(1 == 2, 'msg')": "cb.lua:1: msg",
		"assert(false, 5)": "5",
		"assert()": "cb.lua:1: bad argument #1 to 'assert' (value expected)",
	}
	for body: String in cases:
		var loaded := host.load_string("return { on_spawn = function(b) %s end }" % body, CHUNK)
		assert_true(loaded.ok, loaded.error)
		var result := _call(host, "on_spawn")
		assert_false(result.ok, body)
		_eq(result.error, cases[body], body)


func test_library_edits_do_not_change_host_helpers() -> void:
	var host := _host()
	var loaded := host.load_string("""
		math.tointeger = function() while true do end end
		math.type = function() return coroutine.create(print), {} end
		return { on_batch = function(v, dt) v.vx[0] = 4 end }
	""".dedent(), CHUNK)
	assert_true(loaded.ok, loaded.error)
	var started := Time.get_ticks_msec()
	var bv := _batch(2)
	var result := host.call_batch(bv)
	assert_true(result.ok, result.error)
	_eq(bv.vx[0], 4.0)
	assert_true(Time.get_ticks_msec() - started < 2000, "the batch call returned promptly")


# ---- BulletManager, both backends ---------------------------------------------

func _run_backend(preference: String) -> void:
	for values: String in UNUSUAL:
		var manager := _mgr(preference)
		var batch := _weapon(manager, "return { on_batch = function(v, dt) for i = 0, v.n - 1 do v.vx[i] = 50 end return %s end }" % values, 4)
		var hooked := _weapon(manager, "return { on_spawn = function(b) return %s end, can_hit = function(b, t) return false, %s end }" % [values, values], 2)
		for _t in 3:
			manager.step(DT)
		_eq(manager.backend, preference, values)
		_eq(manager.alive_count(), 6, "%s: every bullet still alive" % values)
		assert_true(batch.last_result != null and batch.last_result.ok, "%s on_batch: %s" % [values, batch.last_result.error if batch.last_result else "no run"])
		assert_true(hooked.last_result != null and hooked.last_result.ok, "%s on_spawn: %s" % [values, hooked.last_result.error if hooked.last_result else "no run"])
		var view := manager.gather_batch(manager._behaviors.find(batch), DT)
		for i in view.n:
			_eq(view.vx[i], 50.0, "%s: batch writes committed" % values)


func test_unusual_return_values_gdscript_backend() -> void:
	_run_backend("gdscript")


func test_unusual_return_values_native_backend() -> void:
	if not _need_native():
		return
	_run_backend("native")
