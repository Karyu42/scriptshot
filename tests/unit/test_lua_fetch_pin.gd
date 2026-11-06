extends GutTest
## The M1 binding is the stock 0.8.2 zip, pinned by SHA256. The cold-import
## workaround (issue #7) is pre-seeding extension_list.cfg from the same script.


func test_fetch_script_pins_stock_lua_gdextension_082() -> void:
	var text := FileAccess.get_file_as_string("res://tools/ci/fetch_native_libs.sh")
	assert_true(text.contains("0.8.2"))
	assert_true(text.contains("51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443"))
	assert_true(text.contains("https://github.com/gilzoide/lua-gdextension/releases/download/"))
	assert_false(text.contains("godot-cpp"), "M1 does not build the godot-cpp fork")


func test_fetch_script_pre_seeds_extension_list_for_issue_7() -> void:
	var text := FileAccess.get_file_as_string("res://tools/ci/fetch_native_libs.sh")
	assert_true(text.contains("extension_list.cfg"))
	assert_true(text.contains("res://addons/lua-gdextension/luagdextension.gdextension"))
	assert_true(text.contains("issues/7"))
