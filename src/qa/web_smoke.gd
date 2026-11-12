extends Node
## Browser smoke for the Web export (tools/ci/web_smoke.sh, issue #40).
##
## Only the "Web (smoke)" export preset ships this file. That preset sets the
## custom feature `web_smoke`, and project.godot's
## `application/run/main_scene.web_smoke` override then makes this scene the
## main scene. Every shipping preset excludes src/qa/* (tools/ci/
## check_export_preset.py enforces it), so normal builds neither contain nor
## run it. Release web templates refuse a scene path on the command line, which
## is why the override is a feature tag and not an argument.
##
## It instantiates the real main scene, loads a Lua shot through ScriptHost
## (LuaBulletBehavior.load_file), spawns bullets from it on the main scene's
## BulletManager and prints one marker line per check. The harness greps for
## SMOKE_LUA_OK and SMOKE_DONE, or fails on SMOKE_FAIL / a timeout. User args
## (for example `--bullet-backend=native`) reach BulletManager as usual.

const MAIN_SCENE := "res://scenes/main.tscn"
const SHOT_PATH := "res://src/qa/web_smoke_shot.lua"
const SHOTS := 8
## Physics ticks to run after spawning, so the shots move and stay alive.
const TICKS := 10


func _ready() -> void:
	print("SMOKE_START platform=%s feature=%s args=%s" % [OS.get_name(), OS.has_feature("web_smoke"), " ".join(OS.get_cmdline_user_args())])
	_run.call_deferred()


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		_fail("cannot load %s" % MAIN_SCENE)
		return
	var main := packed.instantiate() as Main
	if main == null:
		_fail("%s is not a Main scene" % MAIN_SCENE)
		return
	add_child(main)
	await get_tree().process_frame
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
	# wanted_backend is gdscript on web unless native was named explicitly.
	# opted_backend() still says native for the built-in default, which is not what this run asked the sim to do.
	print("SMOKE_BACKEND backend=%s requested=%s fallback_warnings=%d" % [manager.backend, NativeBackend.wanted_backend(manager.backend_preference), NativeBackend.missing_warnings])
	print("SMOKE_DONE ok")


func _fail(reason: String) -> void:
	printerr("SMOKE_FAIL %s" % reason)
	print("SMOKE_DONE fail")
