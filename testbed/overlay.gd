class_name TestbedOverlay
extends CanvasLayer
## Large on-screen readout, refreshed about once a second, plus the same numbers on
## stdout / logcat as `SPIKE_RESULT {json}`.
##
## Frame time is the full interval between two rendered frames (Time.get_ticks_usec in
## _process), so it includes simulation, rendering and the vsync wait. FPS is derived from
## the same window (frames / seconds). The window is the last WINDOW frames; the first
## WARMUP_FRAMES after a scene starts are not counted.

signal back_pressed

const WINDOW := 300
const WARMUP_FRAMES := 30
const REFRESH_SEC := 1.0

var scene_id := ""
var title := ""
## Set by the field each tick: {"bullets": int, "scripted": int}
var live := {"bullets": 0, "scripted": 0}

var frame_ms := FrameStats.new(WINDOW)
var sim_ms := FrameStats.new(WINDOW)
var lua_ms := FrameStats.new(WINDOW)
var has_lua := false
## Extra fields for the JSON line (e.g. Lua version, script mode).
var extra := {}

var _label: Label
var _last_usec := 0
var _frames_seen := 0
var _since_refresh := 0.0
var _started_msec := Time.get_ticks_msec()
var last_report := {}


func _ready() -> void:
	layer = 100
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.72)
	style.set_content_margin_all(14)
	style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(16, 16)
	add_child(panel)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 30)
	_label.add_theme_color_override("font_color", Color("e8ffe8"))
	_label.text = "starting..."
	panel.add_child(_label)

	var back := Button.new()
	back.text = "  MENU  "
	back.add_theme_font_size_override("font_size", 40)
	back.custom_minimum_size = Vector2(220, 110)
	back.anchor_left = 1.0
	back.anchor_right = 1.0
	back.offset_left = -240
	back.offset_right = -20
	back.offset_top = 20
	back.offset_bottom = 130
	back.pressed.connect(func() -> void: back_pressed.emit())
	add_child(back)
	_last_usec = Time.get_ticks_usec()


func _process(delta: float) -> void:
	var now := Time.get_ticks_usec()
	var dt_ms := (now - _last_usec) / 1000.0
	_last_usec = now
	_frames_seen += 1
	if _frames_seen > WARMUP_FRAMES:
		frame_ms.push(dt_ms)
	_since_refresh += delta
	if _since_refresh >= REFRESH_SEC:
		_since_refresh = 0.0
		_refresh()


func _refresh() -> void:
	var r := build_report()
	last_report = r
	var lua_line := ""
	if has_lua:
		lua_line = "\nLua   p50 %.2f   p95 %.2f ms/tick" % [r.lua_ms_p50, r.lua_ms_p95]
	_label.text = "%s\nFPS %.1f\nframe  p50 %.1f   p95 %.1f   max %.1f ms\nbullets %d%s\nsim   p50 %.2f   p95 %.2f ms/tick%s\n%s   (window %d/%d frames)" % [
		title,
		r.fps,
		r.frame_ms_p50, r.frame_ms_p95, r.frame_ms_max,
		r.bullets, (" (%d scripted)" % r.scripted) if has_lua else "",
		r.sim_ms_p50, r.sim_ms_p95, lua_line,
		r.renderer_summary, r.window_frames, WINDOW,
	]
	print("SPIKE_RESULT ", JSON.stringify(_json_report(r)))


func build_report() -> Dictionary:
	var fs := frame_ms.sorted_samples()
	var ss := sim_ms.sorted_samples()
	var ls := lua_ms.sorted_samples()
	var secs := frame_ms.sum() / 1000.0
	var method := RenderingServer.get_current_rendering_method()
	var driver := RenderingServer.get_current_rendering_driver_name()
	var adapter := RenderingServer.get_video_adapter_name()
	return {
		"scene": scene_id,
		"fps": (frame_ms.count / secs) if secs > 0.0 else 0.0,
		"frame_ms_p50": FrameStats.percentile(fs, 50.0),
		"frame_ms_p95": FrameStats.percentile(fs, 95.0),
		"frame_ms_p99": FrameStats.percentile(fs, 99.0),
		"frame_ms_max": FrameStats.percentile(fs, 100.0),
		"window_frames": frame_ms.count,
		"bullets": live.bullets,
		"scripted": live.scripted,
		"sim_ms_p50": FrameStats.percentile(ss, 50.0),
		"sim_ms_p95": FrameStats.percentile(ss, 95.0),
		"lua_ms_p50": FrameStats.percentile(ls, 50.0),
		"lua_ms_p95": FrameStats.percentile(ls, 95.0),
		"renderer_method": method,
		"renderer_driver": driver,
		"renderer_adapter": adapter,
		"renderer_summary": "%s | %s | %s" % [method, driver, adapter],
	}


func _json_report(r: Dictionary) -> Dictionary:
	var out := {}
	for k: String in r:
		var v: Variant = r[k]
		if v is float:
			var f: float = v
			out[k] = snappedf(f, 0.01)
		else:
			out[k] = v
	out["uptime_s"] = snappedf((Time.get_ticks_msec() - _started_msec) / 1000.0, 0.1)
	out["godot"] = Engine.get_version_info().string
	out["engine_fps"] = Engine.get_frames_per_second()
	out["os"] = OS.get_name()
	out["model"] = OS.get_model_name()
	out["arch"] = Engine.get_architecture_name()
	out.merge(extra)
	return out
