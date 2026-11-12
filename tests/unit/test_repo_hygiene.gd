extends GutTest
## Guards repository hygiene rules that are easy to break with a drive-by edit.


func _gitignore_lines() -> PackedStringArray:
	var text := FileAccess.get_file_as_string("res://.gitignore")
	var lines := PackedStringArray()
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line != "" and not line.begins_with("#"):
			lines.append(line)
	return lines


func test_gitignore_covers_godot_cache() -> void:
	assert_has(_gitignore_lines(), ".godot/")


func test_gitignore_ignores_lua_gdextension_binaries() -> void:
	assert_has(_gitignore_lines(), "/addons/lua-gdextension/",
		"lua-gdextension binaries are fetched, never committed")


func test_export_presets_are_not_ignored() -> void:
	var lines := _gitignore_lines()
	assert_does_not_have(lines, "export_presets.cfg", "export presets must be committable")
	assert_does_not_have(lines, "/export_presets.cfg")
	assert_does_not_have(lines, "*.cfg", "a blanket *.cfg rule would swallow the presets")


func test_export_credentials_stay_ignored() -> void:
	assert_has(_gitignore_lines(), "export_credentials.cfg")


func test_build_output_directory_is_ignored() -> void:
	assert_has(_gitignore_lines(), "/build/", "export_presets.cfg writes into build/")


const REQUIRED_PRESETS: Array[String] = ["Windows Desktop", "macOS", "Linux", "Web", "Android"]
## Not release targets. "Web (smoke)" and "Web (playtest)" are QA exports. The release
## export matrix never lists them, and tools/ci/check_export_preset.py ties each to the Web preset.
const QA_PRESETS: Array[String] = ["Web (smoke)", "Web (playtest)"]


func _preset_names(cfg: ConfigFile) -> Array[String]:
	var names: Array[String] = []
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			names.append(str(cfg.get_value(section, "name", "")))
	return names


func test_export_presets_file_exists_with_the_five_ci_presets() -> void:
	assert_true(FileAccess.file_exists("res://export_presets.cfg"), "export_presets.cfg must be committed")
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://export_presets.cfg"), OK, "export_presets.cfg parses")
	var names := _preset_names(cfg)
	for required in REQUIRED_PRESETS:
		assert_has(names, required, "CI exports a preset named '%s'" % required)
	for qa in QA_PRESETS:
		assert_has(names, qa, "the web-smoke job exports a preset named '%s'" % qa)
	assert_eq(names.size(), REQUIRED_PRESETS.size() + QA_PRESETS.size(), "no unexpected extra presets (CI matrix is keyed on these names)")


func test_export_presets_write_into_build_and_hold_no_credentials() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://export_presets.cfg"), OK)
	for section in cfg.get_sections():
		if not section.begins_with("preset.") or section.ends_with(".options"):
			continue
		var path := str(cfg.get_value(section, "export_path", ""))
		assert_true(path.begins_with("build/"), "%s exports into build/ (got '%s')" % [section, path])
	var text := FileAccess.get_file_as_string("res://export_presets.cfg").to_lower()
	for line in text.split("\n"):
		for key: String in ["password", "keystore", "secret", "api_key", "apple_id", "notarization/apple_id"]:
			if line.contains(key) and line.contains("="):
				var value := line.get_slice("=", 1).strip_edges()
				assert_true(value in ['""', "", "0", "false"], "credential-looking value in export_presets.cfg: %s" % line)


func test_project_imports_etc2_astc_for_universal_macos_export() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://project.godot"), OK, "project.godot must parse")
	var enabled: bool = str(cfg.get_value("rendering", "textures/vram_compression/import_etc2_astc", false)) == "true"
	assert_true(enabled,
		"macOS universal export needs ETC2/ASTC VRAM compression enabled")


## A `.gd.uid` file without its script is a leftover of a deleted or renamed script
## (one sat at the repo root for a while). Godot never reads it again.
func _orphan_script_uids(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		if sub.begins_with(".") or sub == "addons" or sub == "build":
			continue
		_orphan_script_uids(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if f.ends_with(".gd.uid") and not FileAccess.file_exists(dir_path.path_join(f.trim_suffix(".uid"))):
			out.append(dir_path.path_join(f))


func test_no_script_uid_file_is_left_without_its_script() -> void:
	var orphans: Array[String] = []
	_orphan_script_uids("res://", orphans)
	assert_eq(orphans, [] as Array[String], "orphaned .gd.uid files: delete them")
