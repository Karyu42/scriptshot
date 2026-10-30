extends Node
# Export proof: 1000 scripted bullets driven by Lua inside an exported build (web / android / desktop).
# Logs machine-readable lines "SPIKE_RESULT ..." to stdout (browser console / logcat).
const ARENA := Rect2(-1280, -720, 2560, 1440)
const DT := 1.0 / 60.0
const WARM := 60
const FRAMES := 300
const N := 1000

var mgr: SpikeManager
var s: LuaState
var L
var rng := RandomNumberGenerator.new()
var phases := [["C", false], ["A", false], ["B", false], ["B", true]]
var phase := -1
var frame := 0
var lua_ms := []
var step_ms := []
var frame_ms := []
var last_t := 0
var holder: Node
var _req := ShotRequest.new()
var hook_lua
var tag := ""

func _ready() -> void:
	var os_name := OS.get_name()
	print("SPIKE_INFO godot=%s os=%s web=%s threads=%s mobile=%s renderer=%s cpu=%s" % [Engine.get_version_info().string, os_name, OS.has_feature("web"), OS.has_feature("threads"), OS.has_feature("mobile"), RenderingServer.get_video_adapter_name(), OS.get_processor_name()])
	print("SPIKE_INFO lua runtime=%s version=%s" % [LuaState.get_lua_runtime(), LuaState.get_lua_version_string()])
	_next_phase()

func _next_phase() -> void:
	phase += 1
	if phase >= phases.size():
		print("SPIKE_DONE")
		get_tree().quit()
		return
	if holder != null: holder.queue_free()
	holder = Node.new(); add_child(holder)
	rng.seed = 99
	mgr = SpikeManager.new()
	mgr.capacity = 4096
	mgr.world_bounds = ARENA.grow(32.0)
	mgr.auto_step = false
	mgr.render_enabled = true
	holder.add_child(mgr)
	for i in 8:
		var hb := Hurtbox.new()
		hb.radius = 24.0; hb.layer = Layers.ENEMY
		hb.position = Vector2(rng.randf_range(ARENA.position.x, ARENA.end.x), rng.randf_range(ARENA.position.y, ARENA.end.y))
		holder.add_child(hb)
	s = LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS)
	s.globals["set_vel"] = Callable(mgr, "set_vel")
	s.globals["defer_spawn"] = Callable(mgr, "defer_spawn")
	var src := FileAccess.get_file_as_string("res://scripts/steer.lua")
	if src == "":
		print("SPIKE_ERROR cannot read res://scripts/steer.lua")
		get_tree().quit(1); return
	L = s.load_string(src, "steer.lua").invoke()
	if L is LuaError:
		print("SPIKE_ERROR ", L.message); get_tree().quit(1); return
	var mode: String = phases[phase][0]
	mgr.mode = "B_slice" if mode == "B" else mode
	var beh_id := 0
	if mode == "A":
		var b := LuaBehaviorA.new(); b.fn = L.get("on_update"); beh_id = mgr.register_behavior(b)
	elif mode == "B":
		beh_id = mgr.register_behavior(BulletBehavior.new())
		mgr.lua_batch = L.get("on_update_batch")
	if phases[phase][1]:
		hook_lua = s.do_string("""
		local used, step = 0, 1000
		local BUDGET = setmetatable({}, {__tostring = function() return 'instruction budget exceeded' end})
		return { arm = function() used = 0 end, hook = function() used = used + step; if used > 5000000 then error(BUDGET, 0) end end }
		""")
		s.main_thread.set_hook(hook_lua.get("hook"), LuaThread.HOOK_MASK_COUNT, 1000)
	for i in N:
		_req.reset()
		_req.position = Vector2(rng.randf_range(-500, 500), rng.randf_range(-300, 300))
		_req.velocity = Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(30.0, 90.0)
		_req.lifetime = 1000.0
		_req.radius = 3.0
		_req.hit_mask = 0
		_req.behavior_id = beh_id
		_req.param_a = rng.randf() * TAU
		if mode == "C": _req.turn_rate = 0.5
		mgr.spawn(_req)
	frame = 0
	lua_ms.clear(); step_ms.clear(); frame_ms.clear()
	last_t = Time.get_ticks_usec()

func _process(_d: float) -> void:
	if phase >= phases.size(): return
	var now := Time.get_ticks_usec()
	var wall := (now - last_t) / 1000.0
	last_t = now
	if phases[phase][1]: hook_lua.get("arm").invoke()
	var t0 := Time.get_ticks_usec()
	mgr.step(DT)
	var st := (Time.get_ticks_usec() - t0) / 1000.0
	frame += 1
	if frame > WARM:
		step_ms.append(st); frame_ms.append(wall)
		lua_ms.append((mgr.t_hooks) / 1000.0)
	if frame >= WARM + FRAMES:
		var name: String = phases[phase][0] + ("+hook" if phases[phase][1] else "")
		print("SPIKE_RESULT mode=%s n=%d alive=%d hooked=%d lua_ms_med=%.3f lua_ms_p95=%.3f step_ms_med=%.3f step_ms_p95=%.3f frame_ms_med=%.2f frame_ms_p95=%.2f fps=%.1f lua_mem_kb=%d" % [
			name, N, mgr.pool.count, mgr.pool.hooked_count, Stats.median(lua_ms), Stats.p95(lua_ms), Stats.median(step_ms), Stats.p95(step_ms),
			Stats.median(frame_ms), Stats.p95(frame_ms), Engine.get_frames_per_second(), s.get_memory_used() / 1024])
		if phases[phase][1]: s.main_thread.set_hook(null, 0, 0)
		_next_phase()
