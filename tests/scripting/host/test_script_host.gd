extends GutTest
## ScriptHost: load, G1 budget, error isolation, mask_from_names.
## The wall clock is widened so a short loop stops on the instruction budget
## and not on however fast the runner is.


func _is_int(v: Variant, n: int) -> bool:
	return v == n


func _host() -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	assert_true(host.is_ready(), "sandbox did not build")
	return host


func _mask(host: ScriptHost, code: String) -> int:
	var result := host.load_string(code, "mask.lua")
	assert_true(result.ok, "%s :: %s" % [result.error, code])
	assert_eq(host.hook_mask(), BulletBehavior.mask_from_names(host.defined_names()), code)
	return host.hook_mask()


func test_load_string_returns_the_chunk_value() -> void:
	var host := _host()
	var result := host.load_string("return 1 + 1", "add.lua")
	assert_true(result.ok, result.error)
	assert_true(_is_int(result.value, 2), str(result.value))
	assert_false(host.has_weapon(), "a chunk that returns a number is not a weapon")


func test_syntax_error_names_the_chunk_and_the_next_chunk_still_runs() -> void:
	var host := _host()
	var bad := host.load_string("return {", "broken.lua")
	assert_false(bad.ok)
	assert_true("broken.lua" in bad.error, bad.error)
	var good := host.load_string("return 2 + 2", "good.lua")
	assert_true(good.ok, good.error)
	assert_true(_is_int(good.value, 4), str(good.value))


func test_runtime_error_keeps_the_previous_weapon_and_the_host_keeps_running() -> void:
	var host := _host()
	var loaded := host.load_string("return { on_spawn = function(b) end }", "weapon.lua")
	assert_true(loaded.ok, loaded.error)
	assert_true(host.has_callback("on_spawn"))
	var boom := host.load_string("error('boom')", "boom.lua")
	assert_false(boom.ok)
	assert_true("boom" in boom.error, boom.error)
	assert_true(host.has_callback("on_spawn"), "a failed chunk leaves the loaded weapon")
	var again := host.load_string("return 6 * 7", "again.lua")
	assert_true(again.ok, again.error)
	assert_true(_is_int(again.value, 42), str(again.value))


func test_instruction_budget_stops_a_loop() -> void:
	var host := _host()
	var started := Time.get_ticks_msec()
	var result := host.load_string("while true do end", "spin.lua")
	var elapsed := Time.get_ticks_msec() - started
	assert_false(result.ok)
	assert_eq(result.stopped, "instruction budget")
	assert_true("script timeout" in result.error, result.error)
	assert_true(elapsed < 2000, "stopped in %d ms" % elapsed)
	var again := host.load_string("return 3", "after.lua")
	assert_true(again.ok, again.error)
	assert_true(_is_int(again.value, 3), str(again.value))


func test_pcall_cannot_swallow_the_instruction_budget() -> void:
	var host := _host()
	var started := Time.get_ticks_msec()
	var result := host.load_string("while true do pcall(function() while true do end end) end", "pcall.lua")
	var elapsed := Time.get_ticks_msec() - started
	assert_false(result.ok)
	assert_eq(result.stopped, "instruction budget")
	assert_true(elapsed < 2000, "stopped in %d ms" % elapsed)
	var again := host.load_string("return 1", "after.lua")
	assert_true(again.ok, again.error)


func test_faster_pcall_thread_registration() -> void:
	# Each pcall runs in a thread the host registers once. Registration is a
	# set lookup, so thousands of pcalls in one call stay cheap, and every
	# registered thread is still stopped with the rest.
	var host := _host()
	host.instruction_budget = 2_000_000
	host.wall_msec = 10_000
	var started := Time.get_ticks_msec()
	var result := host.load_string(
		"local f = function() end\nfor i = 1, 10000 do pcall(f) end\nreturn 1",
		"many_pcalls.lua"
	)
	var elapsed := Time.get_ticks_msec() - started
	assert_true(result.ok, result.error)
	assert_eq(host._threads.size(), host._thread_set.size())
	assert_gt(host._threads.size(), 10000)
	assert_true(elapsed < 1500, "10000 pcalls in %d ms" % elapsed)
	var stopped := host.load_string("local f = function() end\nwhile true do pcall(f) end", "spin_pcalls.lua")
	assert_false(stopped.ok)
	assert_eq(stopped.stopped, "instruction budget")
	assert_eq(host._threads.size(), host._thread_set.size())
	var again := host.load_string("return 2", "after.lua")
	assert_true(again.ok, again.error)


func test_a_registered_thread_is_registered_once() -> void:
	var host := _host()
	var result := host.load_string(
		"local co = coroutine.create(function() coroutine.yield() end)\n"
		+ "for i = 1, 5 do coroutine.resume(co) end\nreturn 1",
		"once.lua"
	)
	assert_true(result.ok, result.error)
	var before := host._threads.size()
	host._lua_reg_thread(host._threads[before - 1])
	assert_eq(host._threads.size(), before, "a second registration is a no-op")
	assert_eq(host._thread_set.size(), before)


func test_a_child_coroutine_inherits_the_budget() -> void:
	var host := _host()
	var started := Time.get_ticks_msec()
	var result := host.load_string(
		"local co = coroutine.wrap(function() while true do end end); co()",
		"child.lua"
	)
	var elapsed := Time.get_ticks_msec() - started
	assert_false(result.ok)
	assert_eq(result.stopped, "instruction budget")
	assert_true(elapsed < 2000, "stopped in %d ms" % elapsed)


func test_xpcall_handler_spin_is_stopped() -> void:
	var host := _host()
	var started := Time.get_ticks_msec()
	var result := host.load_string(
		"while true do xpcall(function() error('x') end, function() while true do end end) end",
		"xpcall.lua"
	)
	var elapsed := Time.get_ticks_msec() - started
	assert_false(result.ok)
	assert_eq(result.stopped, "instruction budget")
	assert_true(elapsed < 2000, "stopped in %d ms" % elapsed)


func test_gc_finalizers_are_refused() -> void:
	var result := _host().load_string(
		"local ok, err = pcall(function() setmetatable({}, {__gc = function() end}) end); return err",
		"gc.lua"
	)
	assert_true(result.ok, result.error)
	assert_true("__gc" in str(result.value), str(result.value))


func test_mask_from_names_uses_only_the_event_callbacks_the_script_defines() -> void:
	var host := _host()
	assert_eq(_mask(host, "return {}"), 0)
	assert_eq(_mask(host, "return { on_spawn = function() end }"), BulletBehavior.HOOK_ON_SPAWN)
	assert_eq(_mask(host, "return { on_hit = function() end }"), BulletBehavior.HOOK_ON_HIT)
	assert_eq(_mask(host, "return { can_hit = function() end }"), BulletBehavior.HOOK_CAN_HIT)
	assert_eq(_mask(host, "return { on_death = function() end }"), BulletBehavior.HOOK_ON_DESPAWN)
	assert_eq(_mask(host, "return { on_expire = function() end }"), BulletBehavior.HOOK_ON_DESPAWN)
	assert_eq(_mask(host, "return { on_wall = function() end }"), BulletBehavior.HOOK_ON_DESPAWN)
	assert_eq(_mask(host, "return { on_despawn = function() end }"), BulletBehavior.HOOK_ON_DESPAWN)
	assert_eq(
		_mask(host, "return { on_tick = function() end, on_batch = function() end, name = 'plain' }"),
		0
	)
	assert_eq(
		_mask(host, "return { on_spawn = function() end, on_death = function() end }"),
		BulletBehavior.HOOK_ON_SPAWN | BulletBehavior.HOOK_ON_DESPAWN
	)
	# A script that really defines every event hook gets every bit. A script that
	# defines one must not: the adapter's own overrides are not the mask.
	assert_eq(
		_mask(host, "return { on_spawn = function() end, on_hit = function() end, can_hit = function() end, on_despawn = function() end }"),
		BulletBehavior.HOOK_ALL
	)
	assert_ne(_mask(host, "return { on_spawn = function() end }"), BulletBehavior.HOOK_ALL)


func test_load_file_reads_a_weapon_and_a_missing_file_is_an_error() -> void:
	var path := "user://m1_weapon.lua"
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(file)
	file.store_string("return { on_hit = function() end }\n")
	file.close()
	var host := _host()
	var loaded := host.load_file(path)
	assert_true(loaded.ok, loaded.error)
	assert_eq(host.hook_mask(), BulletBehavior.HOOK_ON_HIT)
	var missing := host.load_file("user://no_such_m1_weapon.lua")
	assert_false(missing.ok)
	assert_true(host.has_callback("on_hit"), "a missing file leaves the loaded weapon")
