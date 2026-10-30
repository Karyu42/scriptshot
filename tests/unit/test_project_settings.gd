extends GutTest
## Project-level settings the bullet renderer and gameplay rely on.

const WARNING_PREFIX := "debug/gdscript/warnings/"


func test_fixed_60_hz_simulation_with_render_interpolation() -> void:
	var ticks: int = ProjectSettings.get_setting("physics/common/physics_ticks_per_second")
	var interpolation: bool = ProjectSettings.get_setting("physics/common/physics_interpolation")
	var jitter_fix: float = ProjectSettings.get_setting("physics/common/physics_jitter_fix")
	assert_eq(ticks, 60)
	assert_true(interpolation, "bullets and camera interpolate on high-refresh displays")
	assert_eq(jitter_fix, 0.0, "jitter fix fights interpolation")


func test_compatibility_renderer_and_canvas_items_stretch() -> void:
	var method: String = ProjectSettings.get_setting("rendering/renderer/rendering_method")
	var stretch: String = ProjectSettings.get_setting("display/window/stretch/mode")
	assert_eq(method, "gl_compatibility")
	assert_eq(stretch, "canvas_items")


func test_untyped_and_unsafe_gdscript_warnings_are_errors() -> void:
	var names: Array[String] = ["untyped_declaration", "unsafe_property_access", "unsafe_method_access", "unsafe_cast", "unsafe_call_argument"]
	for warning_name: String in names:
		var level: int = ProjectSettings.get_setting(WARNING_PREFIX + warning_name, 0)
		assert_eq(level, 2, "%s must be an error" % warning_name)


func test_vendored_addons_are_excluded_from_the_warning_rules() -> void:
	var rules: Dictionary = ProjectSettings.get_setting(WARNING_PREFIX + "directory_rules", {})
	var addons: int = rules.get("res://addons", -1)
	assert_eq(addons, 0, "0 = exclude: vendored GUT is not held to the project rules")
