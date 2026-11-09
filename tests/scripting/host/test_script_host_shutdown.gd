extends GutTest
## ScriptHost.shutdown() closes the current state and any retired one.
## A stopped batch coroutine is not resumed. A looping finalizer must not hang.


func _is_int(v: Variant, n: int) -> bool:
	return v == n


func _present(v: Variant) -> bool:
	return v != null


func _host() -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	host.instruction_budget = 2000
	assert_true(host.is_ready(), "sandbox did not build")
	return host


func _as_fn(v: Variant) -> LuaFunction:
	@warning_ignore("unsafe_cast")
	return v as LuaFunction


func _view() -> BatchView:
	var view := BatchView.new()
	view.n = 1
	view.dt = 1.0 / 60.0
	view.id = PackedInt64Array([1])
	view.px = PackedFloat32Array([0.0])
	view.py = PackedFloat32Array([0.0])
	view.vx = PackedFloat32Array([1.0])
	view.vy = PackedFloat32Array([0.0])
	view.age = PackedFloat32Array([0.0])
	view.pa = PackedFloat32Array([0.0])
	view.pb = PackedFloat32Array([0.0])
	view.owner = PackedInt32Array([1])
	return view


func _plant_looping_finalizer(state: LuaState) -> void:
	var planted: Variant = state.do_string(
		"_G.__scriptshot_pin = setmetatable({}, {__gc = function() while true do end end}); return 1",
		"@pin.lua"
	)
	assert_true(_is_int(planted, 1), str(planted))


## Stores a looping finalizer only in `table`, using the real setmetatable.
## The sandbox env refuses __gc, so this chunk runs in the trusted global env.
func _plant_finalizer_in(state: LuaState, table: LuaTable) -> void:
	assert_not_null(table)
	var built: Variant = state.do_string("""
		return function(t)
			rawset(t, "__gc_holder", setmetatable({}, {__gc = function() while true do end end}))
			return 1
		end
	""".dedent(), "@plant.lua")
	assert_true(built is LuaFunction, str(built))
	var planted: Variant = _as_fn(built).invoke(table)
	assert_true(_is_int(planted, 1), str(planted))
	assert_true(_present(table.get("__gc_holder")), "finalizer was not stored")


func test_shutdown_releases_retired_state_stopped_batch_and_looping_finalizer() -> void:
	var host := _host()
	var loaded := host.load_string("""
		return {
			on_spawn = function(b)
				while true do end
			end,
			on_batch = function(v, dt)
				local held = v
				while true do end
			end,
		}
	""".dedent(), "shutdown.lua")
	assert_true(loaded.ok, loaded.error)
	for i in 4:
		var spun := host.call_hook("on_spawn", i, 0.0, 0.0)
		assert_false(spun.ok)
		assert_eq(spun.stopped, "instruction budget")
	assert_false(host._retired.is_empty(), "three stops should retire a state")
	var retired: ScriptHost.RetiredState = host._retired[0]
	assert_gt(retired.threads.size(), 0)
	# Not pcall: a stopped host makes the sandbox pcall spin on purpose.
	var refused: Variant = retired.state.do_string(
		"setmetatable({}, {__gc = function() end}); return 1",
		"@retired.lua",
		retired.env_table
	)
	assert_true(refused is LuaError, str(refused))
	assert_true("__gc" in str(refused), str(refused))
	var batch := host.call_batch(_view())
	assert_false(batch.ok)
	assert_eq(batch.stopped, "instruction budget")
	assert_gt(host._parked.size(), 0)
	_plant_looping_finalizer(host._state)
	_plant_looping_finalizer(retired.state)
	# A finalizer that lives only in the env or the weapon table. Shutdown
	# must walk both, or collectgarbage runs the loop.
	_plant_finalizer_in(host._state, host._env)
	_plant_finalizer_in(host._state, host._weapon)
	_plant_finalizer_in(retired.state, retired.env_table)
	_plant_finalizer_in(retired.state, retired.weapon)
	var calls := host.host_call_count()
	var started := Time.get_ticks_msec()
	host.shutdown()
	var elapsed := Time.get_ticks_msec() - started
	assert_lt(elapsed, 1000, "shutdown took %d ms" % elapsed)
	assert_true(host.is_shutdown())
	assert_null(host._state)
	assert_eq(host._retired.size(), 0)
	assert_eq(host._parked.size(), 0)
	assert_eq(host.host_call_count(), calls, "shutdown called back into the host")
	var after := host.call_hook("on_spawn", 1, 0.0, 0.0)
	assert_false(after.ok)
	assert_true("shut down" in after.error, after.error)
	assert_eq(host.host_call_count(), calls)
	host.shutdown()
	assert_eq(host.host_call_count(), calls)


func test_another_host_runs_after_shutdown() -> void:
	var first := _host()
	var loaded := first.load_string("return { on_spawn = function(b) end }", "first.lua")
	assert_true(loaded.ok, loaded.error)
	first.shutdown()
	var second := _host()
	var again := second.load_string("return 2 + 2", "second.lua")
	assert_true(again.ok, again.error)
	assert_true(_is_int(again.value, 4), str(again.value))
	var calls := second.host_call_count()
	second.shutdown()
	assert_true(second.is_shutdown())
	assert_eq(second.host_call_count(), calls)
