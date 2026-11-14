extends GutTest
## Bundled weapon scripts are never run by the Lua binding in the editor.
##
## lua-gdextension 0.8.2 claims every res://*.lua as a LuaScript. While the
## editor scans or imports (global class names), it loads each one and, in its
## default "Automatic" mode, runs the whole chunk in its own unsandboxed state
## when the file ends in `return { ... }` or `return Name`, which is exactly the
## shape of a weapon script. A top level that reads a sandbox global (`state`,
## `spawn`, `TAU`, `sense`) then raises in the import log. So weapon-shaped
## files in res:// are `.lua.txt` (ScriptLibrary.BUNDLED_EXT), docs examples
## sit behind a .gdignore, and only host files that return a function stay `.lua`.
## tools/run_tests.sh also fails on a Lua error in the import log.

## Matches the binding's test (LuaScript::get_looks_like_godot_script): the
## chunk's trailing return is a table constructor or a bare name.
const _GODOT_SCRIPT_SHAPE := "^return\\s*(\\{|[A-Za-z_][A-Za-z0-9_]*\\s*$)"


func test_no_res_lua_file_has_the_shape_the_binding_runs() -> void:
	var files := _lua_files("res://")
	assert_gt(files.size(), 0, "found the host .lua files (sandbox, state codec)")
	assert_has(files, "res://scripting/sandbox.lua")
	assert_has(files, "res://scripting/state_codec.lua")
	var shape := RegEx.create_from_string(_GODOT_SCRIPT_SHAPE)
	for path in files:
		var last := _last_top_level_return(FileAccess.get_file_as_string(path))
		assert_false(
			shape.search(last) != null,
			"%s ends in `%s`: the Lua binding runs it in the editor. Save weapon scripts as %s." % [path, last, ScriptLibrary.BUNDLED_EXT]
		)


func test_the_shape_check_catches_a_weapon_script() -> void:
	var shape := RegEx.create_from_string(_GODOT_SCRIPT_SHAPE)
	var spiral := FileAccess.get_file_as_string(ScriptLibrary.STARTER_DIR.path_join("spiral" + ScriptLibrary.BUNDLED_EXT))
	assert_string_contains(spiral, "state.t = state.t or 0", "the spiral keeps the documented idiom at top level")
	assert_not_null(shape.search(_last_top_level_return(spiral)), "a starter has the shape, so it must not be .lua")
	assert_not_null(shape.search(_last_top_level_return("local Foo = {}\nreturn Foo\n")))
	assert_null(shape.search(_last_top_level_return("return function(host)\n  return {}\nend\n")))


func test_every_starter_and_codex_page_ships_as_text() -> void:
	for id in ScriptLibrary.STARTERS:
		var path := ScriptLibrary.STARTER_DIR.path_join(id + ScriptLibrary.BUNDLED_EXT)
		assert_true(FileAccess.file_exists(path), path)
		assert_false(FileAccess.file_exists(ScriptLibrary.STARTER_DIR.path_join(id + ".lua")), "%s.lua is gone" % id)
		assert_not_null(ScriptLibrary.starter(id), id)
	for id: String in ["nearest_enemy", "enemies_in"]:
		var path := ScriptEditorPanel.CODEX_DIR.path_join(id + ScriptLibrary.BUNDLED_EXT)
		assert_true(FileAccess.file_exists(path), path)
		assert_ne(ScriptEditorPanel.codex_source(id), "", id)
	assert_true(FileAccess.file_exists("res://docs/scripting/examples/.gdignore"), "docs examples stay .lua for readers, unscanned")


## res://**/*.lua the editor would scan: skips dot folders, addons/ (the
## binding's own and GUT), and folders the editor skips (.gdignore, a nested
## project.godot).
func _lua_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var da := DirAccess.open(dir)
	if da == null:
		return out
	for f in da.get_files():
		if f.get_extension() == "lua":
			out.append(dir.path_join(f))
	for d in da.get_directories():
		var sub := dir.path_join(d)
		if d.begins_with(".") or sub == "res://addons":
			continue
		if FileAccess.file_exists(sub.path_join(".gdignore")) or FileAccess.file_exists(sub.path_join("project.godot")):
			continue
		out.append_array(_lua_files(sub))
	return out


## The last line that starts a top-level `return`, with comments removed.
func _last_top_level_return(src: String) -> String:
	var text := RegEx.create_from_string("--\\[(=*)\\[[\\s\\S]*?\\]\\1\\]").sub(src, "", true)
	var last := ""
	for line in text.split("\n"):
		var code := line
		var at := code.find("--")
		if at >= 0:
			code = code.substr(0, at)
		if code.begins_with("return"):
			last = code.strip_edges()
	return last
