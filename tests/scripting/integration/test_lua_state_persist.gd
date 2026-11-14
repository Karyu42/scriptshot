extends GutTest
## The weapon's `state` table (api.md "Weapon state"): every save starts from
## fresh top-level globals, and only `state` carries over, as a copy of the
## running version's plain data, idle or busy, in place or on another host.
## `state = {}` at the top level resets it. A copy keeps shared references,
## cuts cycles and drops functions with a warning, and is capped (depth,
## entries, bytes). A failed save leaves the running `state` alone; shots of
## older versions keep their own; respawn keeps it. Both backends.

const DT := 1.0 / 60.0
const BACKENDS: Array[String] = ["gdscript", "native"]
## A version that counts saves in a global and in state, and reports both.
const COUNTER := "count = (count or 0) + 1\nstate.n = (state.n or 0) + 1\nreturn { name = count .. ',' .. state.n, speed = 30, lifetime = %s, on_hit = function(b, h) end }"

var _mgrs: Array[BulletManager] = []
var _shots: Array[LuaShot] = []


func before_each() -> void:
	ScriptWarnings.reset()


func after_each() -> void:
	_handle_state_warnings()
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	_shots.clear()


func _skip(preference: String) -> bool:
	if preference == "native" and not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return true
	return false


func _mgr(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 512
	manager.logical_cap = 512
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-4000, -4000, 8000, 8000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	_mgrs.append(manager)
	return manager


func _shot(manager: BulletManager) -> LuaShot:
	var shot := LuaShot.new(manager)
	_shots.append(shot)
	return shot


func _ctx() -> ShotContext:
	var ctx := ShotContext.new()
	ctx.muzzle_position = Vector2.ZERO
	ctx.aim_direction = Vector2.RIGHT
	ctx.aim_angle = 0.0
	ctx.target_mask = Layers.ENEMY
	return ctx


func _fire(manager: BulletManager, shot: LuaShot, n: int = 1) -> void:
	for i in n:
		shot.fire(_ctx(), manager.emitter)


func _steps(manager: BulletManager, n: int) -> void:
	for i in n:
		manager.step(DT)


func _drain_all(manager: BulletManager) -> void:
	for i in 600:
		if manager.alive_count() == 0:
			return
		manager.step(DT)


func _apply(shot: LuaShot, code: String) -> ScriptHost.RunResult:
	var r := shot.apply(code)
	assert_true(r.ok, r.error)
	return r


## The copy notes are also printed (ScriptWarnings, push_warning). They are
## what these tests expect, so GUT should not count them as unexpected.
func _handle_state_warnings() -> void:
	var tracker: Object = gut.error_tracker
	for e: Object in tracker.call("get_errors_for_test"):
		if str(e.get("code")).begins_with("LuaShot: "):
			e.set("handled", true)


func _joined(r: ScriptHost.RunResult) -> String:
	return "\n".join(r.warnings)


func test_an_idle_save_resets_top_level_globals_but_keeps_state() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var r := _apply(shot, COUNTER % "0.2")
		assert_eq(shot.title, "1,1", pref)
		var host := shot.behavior().host
		for i in 3:
			r = _apply(shot, COUNTER % "0.2")
			assert_eq(r.warnings.size(), 0, _joined(r))
		assert_eq(shot.behavior().host, host, "%s: idle saves reload in place" % pref)
		assert_eq(shot.generation_switches, 0)
		assert_eq(shot.title, "1,4", "%s: the global starts fresh every save; state.n carries" % pref)


## The same with shots in flight: new generations on other hosts, and with
## every slot busy the oldest host's fresh env.
func test_a_busy_save_carries_state() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var hosts: Array[ScriptHost] = []
		for i in 5:
			_apply(shot, COUNTER % "9")
			hosts.append(shot.behavior().host)
			_fire(manager, shot)
			_steps(manager, 1)
			assert_eq(shot.title, "1,%d" % (i + 1), "%s: save %d" % [pref, i])
		assert_ne(hosts[1], hosts[0], "%s: save 2 went to another host" % pref)
		assert_eq(shot.evicted_count, 2, "%s: saves 4 and 5 found every slot busy" % pref)
		assert_eq(shot.generation_count(), LuaShot.MAX_GENERATIONS)


func test_assigning_state_at_the_top_level_resets_it() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "state.n = 5\nstate.keep = 'x'\nreturn { speed = 30 }")
		_apply(shot, "state = {}\nstate.m = 1\nreturn { name = tostring(state.n) .. ',' .. tostring(state.keep), speed = 30 }")
		assert_eq(shot.title, "nil,nil", pref)
		_apply(shot, "return { name = tostring(state.n) .. ',' .. tostring(state.m), speed = 30 }")
		assert_eq(shot.title, "nil,1", "%s: the reset table is what carries on" % pref)
		# The documented idiom keeps a value and starts it once.
		_apply(shot, "state.hits = state.hits or 0\nstate.hits = state.hits + 1\nreturn { name = tostring(state.hits), speed = 30 }")
		_apply(shot, "state.hits = state.hits or 0\nstate.hits = state.hits + 1\nreturn { name = tostring(state.hits), speed = 30 }")
		assert_eq(shot.title, "2", pref)


## Plain values keep their type: integers stay integers, floats (and inf,
## nan, -0.0) stay floats, strings keep every byte, booleans and nested
## tables come through; a table referenced twice is still one table, also
## when the next version lives in another Lua state.
func test_plain_data_and_shared_references_survive_the_copy() -> void:
	var setup := "local t = { v = 1 }\nstate.a = t\nstate.b = { inner = t }\nstate.i = 7\nstate.f = 7.5\nstate.big = math.maxinteger\nstate.inf = math.huge\nstate.nan = 0/0\nstate.nz = -0.0\nstate.s = 'a%b\\0c\\255\\n\"'\nstate.yes = true\nstate.no = false\nstate[1] = 'one'\nstate[2.5] = 'half'\nstate[true] = 'flag'\n"
	var probe := "local ok = rawequal(state.a, state.b.inner) and state.a.v == 1 and math.type(state.i) == 'integer' and math.type(state.f) == 'float' and state.f == 7.5 and state.big == math.maxinteger and state.inf == math.huge and state.nan ~= state.nan and 1/state.nz < 0 and state.s == 'a%b\\0c\\255\\n\"' and state.yes == true and state.no == false and state[1] == 'one' and state[2.5] == 'half' and state[true] == 'flag'\nstate.a.v = 2\nreturn { name = tostring(ok) .. ',' .. state.b.inner.v, speed = 30, lifetime = %s, on_hit = function(b, h) end }".replace("lifetime = %s", "lifetime = 9")
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var r := _apply(shot, setup + "return { speed = 30, lifetime = 9, on_hit = function(b, h) end }")
		var first_host := shot.behavior().host
		# Idle (same host, in place).
		r = _apply(shot, probe)
		assert_eq(shot.title, "true,2", "%s: in place" % pref)
		assert_eq(r.warnings.size(), 0, _joined(r))
		# Busy: the next version is on another host (another Lua state).
		_fire(manager, shot)
		_steps(manager, 1)
		_apply(shot, setup + "return { speed = 30, lifetime = 9, on_hit = function(b, h) end }")
		_fire(manager, shot)
		_steps(manager, 1)
		r = _apply(shot, probe)
		assert_ne(shot.behavior().host, first_host)
		assert_eq(shot.title, "true,2", "%s: across Lua states" % pref)
		assert_eq(r.warnings.size(), 0, _joined(r))


func test_a_cycle_is_cut_with_a_warning() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		ScriptWarnings.reset()
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "state.self = state\nstate.x = { y = {} }\nstate.x.y.up = state.x\nstate.x.y.k = 3\nreturn { speed = 30 }")
		var r := _apply(shot, "return { name = tostring(state.self) .. ',' .. tostring(state.x.y.up) .. ',' .. state.x.y.k, speed = 30 }")
		assert_eq(shot.title, "nil,nil,3", "%s: back-references are cut, the rest is copied" % pref)
		assert_eq(r.warnings.size(), 1, _joined(r))
		assert_string_contains(_joined(r), "points back to a table that contains it; the loop was cut there (2 places)")
		assert_true(_joined(r).begins_with("state.self ") or _joined(r).begins_with("state.x.y.up "), "the first place is named: %s" % _joined(r))
		assert_eq(ScriptWarnings.count(LuaShot.STATE_WARNING_KEY), 1, "%s: also on ScriptWarnings" % pref)


func test_functions_and_other_non_plain_values_are_dropped_with_a_warning() -> void:
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		_apply(shot, "state.fn = function() end\nstate.co = coroutine.create(function() end)\nstate.list = { 1, print, 3 }\nstate[{}] = 'table key'\nstate.k = 1\nsetmetatable(state, { __index = function() return 'meta' end })\nreturn { speed = 30 }")
		var r := _apply(shot, "return { name = tostring(rawget(state, 'fn')) .. ',' .. tostring(rawget(state, 'co')) .. ',' .. tostring(state.list[3]) .. ',' .. tostring(state.list[2]) .. ',' .. state.k .. ',' .. tostring(getmetatable(state)), speed = 30 }")
		assert_eq(shot.title, "nil,nil,3,nil,1,nil", "%s: plain data only, no metatable" % pref)
		var text := _joined(r)
		assert_string_contains(text, "is a function; state keeps only plain data")
		assert_string_contains(text, "is a thread")
		assert_string_contains(text, "has a key that is not a string, number or boolean")
		assert_string_contains(text, "(2 places)", "fn and list[2]")


## A huge or deep `state` is capped, warned about, and copied quickly; the
## save goes through.
func test_an_oversized_or_deep_state_is_capped_without_hanging() -> void:
	var cases: Dictionary[String, String] = {
		"entries": "state.list = {}\nfor i = 1, 12000 do state.list[i] = i end\n",
		"depth": "local t = state\nfor i = 1, 100 do t.c = {} t = t.c end\n",
		"bytes": "for i = 1, 4 do state['s' .. i] = string.rep('x', 100 * 1024) end\n",
		"cycle_wide": "for i = 1, 3000 do state[i] = state end\n",
	}
	for pref in BACKENDS:
		if _skip(pref):
			continue
		for kind: String in cases:
			var manager := _mgr(pref)
			var shot := _shot(manager)
			_apply(shot, cases[kind] + "return { speed = 30, lifetime = 9, on_hit = function(b, h) end }")
			_fire(manager, shot)
			_steps(manager, 1)
			var probe := "local d, t = 1, state\nwhile type(rawget(t, 'c')) == 'table' do d = d + 1 t = t.c end\nlocal n, bytes = 0, 0\nfor k, v in pairs(state.list or {}) do n = n + 1 end\nfor k, v in pairs(state) do if type(v) == 'string' then bytes = bytes + #v end end\nreturn { name = d .. ',' .. n .. ',' .. bytes, speed = 30 }"
			var t0 := Time.get_ticks_usec()
			var r := _apply(shot, probe)
			var us := Time.get_ticks_usec() - t0
			assert_lt(us, 250_000, "%s/%s: the copy is bounded (%d us)" % [pref, kind, us])
			var parts := shot.title.split(",")
			var text := _joined(r)
			match kind:
				"entries":
					assert_string_contains(text, "state has more than %d entries" % ScriptHost.STATE_MAX_ENTRIES)
					assert_lt(parts[1].to_int(), 12000, pref)
					assert_gt(parts[1].to_int(), ScriptHost.STATE_MAX_ENTRIES - 10, pref)
				"depth":
					assert_string_contains(text, "is nested more than %d tables deep" % ScriptHost.STATE_MAX_DEPTH)
					assert_eq(parts[0].to_int(), ScriptHost.STATE_MAX_DEPTH, "%s: state plus nested tables up to the cap" % pref)
				"bytes":
					assert_string_contains(text, "state is larger than %d KiB" % (ScriptHost.STATE_MAX_BYTES / 1024))
					assert_lte(parts[2].to_int(), ScriptHost.STATE_MAX_BYTES, pref)
					assert_gt(parts[2].to_int(), 0, pref)
				"cycle_wide":
					assert_string_contains(text, "points back to a table that contains it; the loop was cut there (3000 places)")
			gut.p("%s %s: copy and load %.1f ms; %s" % [pref, kind, us / 1000.0, text])


## A save that fails (compile error, top-level error, bad return, a weapon
## table the host rejects) leaves the running version's `state` as it was,
## idle or with every slot busy, and the next good save still carries it.
func test_a_failed_save_leaves_the_running_state_intact() -> void:
	var bad: Array[String] = [
		"state.n = 999\nstate = { broken = true }\nreturn { speed = 1",
		"state.n = 999\nstate = { broken = true }\nerror('boom')",
		"state.n = 999\nstate.broken = true\nreturn 5",
		"state.n = 999\nstate.broken = true\nlocal w = { speed = 1 }\nfor i = 1, 300 do w['k' .. i] = i end\nreturn w",
	]
	var counting := "state.n = state.n or 0\nreturn { name = 'V' .. state.n, speed = 30, lifetime = %s, on_hit = function(b, h) end, on_fire = function(ctx) state.n = state.n + 1 spawn{} end }"
	var probe := "return { name = tostring(state.n) .. ',' .. tostring(state.broken), speed = 30, lifetime = 9, on_hit = function(b, h) end }"
	for pref in BACKENDS:
		if _skip(pref):
			continue
		for busy: bool in [false, true]:
			var manager := _mgr(pref)
			var shot := _shot(manager)
			var life := "9" if busy else "0.05"
			for i in 3:
				_apply(shot, counting % life)
				_fire(manager, shot, 2)
				_steps(manager, 1 if busy else 10)
			var where := "%s/%s" % [pref, "busy" if busy else "idle"]
			assert_eq(shot.title, "V4", where)
			for code in bad:
				var r := shot.apply(code)
				assert_false(r.ok, "%s: %s" % [where, code])
				assert_eq(shot.title, "V4", where)
			assert_eq(shot.evicted_count, 0, where)
			# The running version still counts with its own state.
			_fire(manager, shot, 1)
			_steps(manager, 1 if busy else 10)
			_apply(shot, probe)
			assert_eq(shot.title, "7,nil", "%s: the running state was untouched and the good save carried it" % where)


## Shots in flight from an older version run against that version's own
## `state`; only the new version gets the copy.
func test_older_in_flight_shots_keep_their_own_state() -> void:
	var tpl := "state.tag = '%s'\nstate.seen = (state.seen or '') .. '%s'\nreturn { speed = 1, lifetime = 0.5, on_hit = function(b, h) end, on_despawn = function(b, why) state.hits = (state.hits or 0) + 1 print(state.tag .. ':' .. state.seen .. ':' .. state.hits) end }"
	for pref in BACKENDS:
		if _skip(pref):
			continue
		var manager := _mgr(pref)
		var shot := _shot(manager)
		var versions: Array[LuaBulletBehavior] = []
		for v: String in ["A", "B", "C"]:
			_apply(shot, tpl % [v, v])
			versions.append(shot.behavior())
			_fire(manager, shot, 2)
			_steps(manager, 1)
		assert_eq(shot.generation_count(), 3, pref)
		_drain_all(manager)
		var expect: Array[String] = ["A:A:2", "B:AB:2", "C:ABC:2"]
		for i in versions.size():
			assert_eq(versions[i].last_result.output, PackedStringArray([expect[i]]), "%s: version %d" % [pref, i])
		# The current version's hits carried on; older ones did not leak in.
		_apply(shot, "return { name = tostring(state.hits) .. ',' .. state.seen, speed = 1 }")
		assert_eq(shot.title, "2,ABC", pref)


## Death and respawn keep the weapon and its `state` (spec §2): the running
## version keeps counting, and the next save still carries the count.
func test_state_survives_respawn() -> void:
	const SAVE := "user://gut_state_persist_respawn.cfg"
	if FileAccess.file_exists(SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = SAVE
	(main.get_node("BulletManager") as BulletManager).backend_preference = "gdscript"
	add_child_autofree(main)
	var turrets := main.get_node_or_null("Turrets")
	if turrets != null:
		for turret: Turret in turrets.get_children():
			turret.emitter = null
	await wait_physics_frames(2)
	var player: Player = main.get_node("Player")
	var weapon := main.weapon
	var r := weapon.apply("state.n = state.n or 0\nreturn { name = 'C', on_fire = function(ctx) state.n = state.n + 1 spawn{} end }")
	assert_true(r.ok, r.error)
	player.weapon = weapon
	var emitter := (main.get_node("BulletManager") as BulletManager).emitter
	for i in 3:
		weapon.fire(_ctx(), emitter)
	player.state.set_hp(0.0)
	await wait_physics_frames(2)
	assert_true(player.state.is_dead())
	player.respawn(Vector2(50, 50))
	await wait_physics_frames(2)
	assert_false(player.state.is_dead())
	assert_true(player.weapon == weapon, "respawn keeps the weapon")
	for i in 2:
		weapon.fire(_ctx(), emitter)
	r = weapon.apply("return { name = tostring(state.n) }")
	assert_true(r.ok, r.error)
	assert_eq(weapon.title, "5", "state kept counting through the death")
	if FileAccess.file_exists(SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))


## The copy is host work on plain data: whatever the script put in `state`,
## the host code runs no script code (no metamethods) while copying.
func test_the_copy_runs_no_script_code() -> void:
	var manager := _mgr("gdscript")
	var shot := _shot(manager)
	_apply(shot, "calls = 0\nlocal mt = { __index = function() calls = calls + 1 end, __pairs = function() error('pairs ran') end, __len = function() error('len ran') end }\nstate.t = setmetatable({ 1, 2 }, mt)\nsetmetatable(state, mt)\nreturn { speed = 30 }")
	var r := _apply(shot, "return { name = #state.t .. ',' .. tostring(getmetatable(state.t)), speed = 30 }")
	assert_eq(shot.title, "2,nil")
	assert_eq(r.warnings.size(), 0, _joined(r))
