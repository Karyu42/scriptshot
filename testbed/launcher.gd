extends Control
## Scene picker for the phone test build: big touch buttons, one per test scene.

const ORDER := ["lua_batch", "lua_each", "plain_5k", "plain_10k"]


func _ready() -> void:
	# Fill tall phone screens instead of letterboxing (set at runtime so project.godot stays as on main).
	get_window().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	var args := _user_args()
	var scene_arg: String = args.get("scene", "")
	if TestbedState.SCENES.has(scene_arg):
		TestbedState.current = scene_arg
		var seconds_arg: String = args.get("seconds", "0")
		TestbedState.auto_seconds = float(seconds_arg)
		TestbedState.shot_path = args.get("shot", "")
		get_tree().change_scene_to_file.call_deferred("res://testbed/field.tscn")
		return
	_build()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		get_tree().quit()


func _build() -> void:
	var bg := ColorRect.new()
	bg.color = Color("101319")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 60
	box.offset_right = -60
	box.offset_top = 20
	box.offset_bottom = -20
	box.add_theme_constant_override("separation", 14)
	add_child(box)

	var title := Label.new()
	title.text = "Scriptshot: Android test build (not a release)"
	title.add_theme_font_size_override("font_size", 42)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var lua_ok := TestbedLuaDriver.is_available()
	var info := Label.new()
	info.text = "Godot %s | %s | %s | lua-gdextension: %s" % [
		Engine.get_version_info().string,
		RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name(),
		"loaded" if lua_ok else "NOT LOADED"]
	info.add_theme_font_size_override("font_size", 26)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)

	for id: String in ORDER:
		var cfg: Dictionary = TestbedState.SCENES[id]
		var b := Button.new()
		b.text = cfg.title
		b.custom_minimum_size = Vector2(0, 100)
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", 34)
		b.disabled = cfg.lua != "" and not lua_ok
		b.pressed.connect(_start.bind(id))
		box.add_child(b)

	var hint := Label.new()
	hint.text = "Read from the overlay: FPS and frame-time p50 / p95 (ms, last 300 frames). 60 Hz target: p95 <= 16.6 ms."
	hint.add_theme_font_size_override("font_size", 24)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)


func _start(id: String) -> void:
	TestbedState.current = id
	TestbedState.auto_seconds = 0.0
	get_tree().change_scene_to_file("res://testbed/field.tscn")


func _user_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and "=" in arg:
			var kv := arg.trim_prefix("--").split("=", true, 1)
			out[kv[0]] = kv[1]
	return out
