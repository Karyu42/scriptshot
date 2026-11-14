extends GutTest
## A host whose Lua state is rotated after three guard stops reloads the
## running file on the new state with its `state` carried over (as on a save),
## and gets fresh envs again when it had them. Host-guard process: this stops
## chunks with the instruction hook (see tools/run_tests.sh).


func test_a_rotated_state_keeps_the_weapon_state_and_fresh_envs() -> void:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	host.instruction_budget = 2000
	assert_true(host.is_ready(), "sandbox did not build")
	host.snapshot_globals()
	var code := "state.n = state.n or 5\nstate.t = state.t or { 'kept' }\nreturn { name = 'R', on_spawn = function(b) state.n = state.n + 1 end, on_hit = function(b, h) while true do end end }"
	var r := host.load_string(code, "rot.lua", true)
	assert_true(r.ok, r.error)
	assert_true(host.call_hook("on_spawn", 1, 0.0, 0.0).ok)
	var old_state := host._state
	for i in 3:
		var spun := host.call_hook("on_hit", 1, 0.0, 0.0, null, true)
		assert_eq(spun.stopped, "instruction budget")
	assert_true(host.call_hook("on_spawn", 1, 0.0, 0.0).ok)
	assert_eq(host._retired.size(), 1, "three stops rotated the state")
	assert_ne(host._state, old_state)
	assert_true(host.has_callback("on_spawn"), "the file was reloaded on the new state")
	assert_eq(host._fresh_env_state, host._instance_id(host._state), "fresh envs again on the new state")
	var probe := host.load_string("return { name = state.n .. ',' .. state.t[1] .. ',' .. tostring(rawget(_G, 'leftover')) }", "probe.lua", true, host.export_state())
	assert_true(probe.ok, probe.error)
	assert_eq(host.weapon_string("name", ""), "7,kept,nil", "state carried through the rotation")
	host.shutdown()
