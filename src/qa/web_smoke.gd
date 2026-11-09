extends Node
## Browser smoke for the Web export (tools/ci/web_smoke.sh, issue #40). Autoload
## that is inert in normal play: unless the user argument `--web-smoke` is
## present it frees itself in _ready() and does nothing else. On the web the only
## way to pass that argument is GODOT_CONFIG.args in index.html, which the
## shipped page leaves empty. (Release web templates refuse a scene path on the
## command line, so a separate smoke scene cannot be used.)
##
## With the flag it waits for the real main scene, loads a Lua shot through
## ScriptHost (LuaBulletBehavior.load_file), spawns bullets from it on the main
## scene's BulletManager and prints one marker line per check. The harness
## greps for SMOKE_LUA_OK and SMOKE_DONE, or fails on SMOKE_FAIL / a timeout.

const FLAG := "--web-smoke"
const SHOT_PATH := "res://src/qa/web_smoke_shot.lua"
const SHOTS := 8
## Physics ticks to run after spawning, so the shots move and stay alive.
const TICKS := 10
## Frames to wait for the main scene before giving up.
const WAIT_FRAMES := 600


func _ready() -> void:
	if not FLAG in OS.get_cmdline_user_args():
		queue_free()
		return
	print("SMOKE_START platform=%s args=%s" % [OS.get_name(), " ".join(OS.get_cmdline_user_args())])
	_run.call_deferred()


func _run() -> void:
	var main: Main = null
	for i in WAIT_FRAMES:
		main = get_tree().current_scene as Main
		if main != null and main.is_node_ready():
			break
		await get_tree().process_frame
	if main == null:
		_fail("the main scene (Main) did not start")
		return
	await get_tree().process_frame
	var manager := main.get_node_or_null("BulletManager") as BulletManager
	if manager == null:
		_fail("main scene has no BulletManager")
		return
	print("SMOKE_MAIN_OK scene=%s backend=%s native_class=%s" % [main.scene_file_path, manager.backend, ClassDB.class_exists(NativeBackend.CLASS_NAME)])

	var behavior := LuaBulletBehavior.new()
	var id := manager.register_behavior(behavior)
	var loaded := behavior.load_file(SHOT_PATH, manager, id)
	if not loaded.ok:
		_fail("Lua load failed: %s" % loaded.error)
		return
	var before := manager.alive_count()
	for i in SHOTS:
		var request := ShotRequest.with_velocity(Vector2(0, 40.0 * i), Vector2(60, 0))
		request.lifetime = 5.0
		behavior.apply_to_request(request, id)
		if manager.spawn(request) < 0:
			_fail("spawn %d was rejected" % i)
			return
	for t in TICKS:
		await get_tree().physics_frame
	var spawned := manager.alive_count() - before
	var hooks := behavior.dispatches("on_spawn")
	if hooks != SHOTS:
		_fail("on_spawn ran %d times, expected %d (last error: %s)" % [hooks, SHOTS, behavior.last_result.error])
		return
	# Each shot spawns one child from Lua.
	if spawned < SHOTS * 2:
		_fail("expected at least %d live bullets from Lua, got %d" % [SHOTS * 2, spawned])
		return
	if manager.backend != "gdscript":
		_fail("bullet backend is %s, expected gdscript" % manager.backend)
		return
	print("SMOKE_LUA_OK bullets=%d backend=%s on_spawn=%d chunk=%s" % [spawned, manager.backend, hooks, loaded.chunk_name])
	print("SMOKE_BACKEND backend=%s requested=%s fallback_warnings=%d" % [manager.backend, NativeBackend.opted_backend(), NativeBackend.missing_warnings])
	print("SMOKE_DONE ok")


func _fail(reason: String) -> void:
	printerr("SMOKE_FAIL %s" % reason)
	print("SMOKE_DONE fail")
