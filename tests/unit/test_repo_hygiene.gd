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


func test_export_presets_are_not_ignored() -> void:
	var lines := _gitignore_lines()
	assert_does_not_have(lines, "export_presets.cfg", "export presets must be committable")
	assert_does_not_have(lines, "/export_presets.cfg")
	assert_does_not_have(lines, "*.cfg", "a blanket *.cfg rule would swallow the presets")


func test_export_credentials_stay_ignored() -> void:
	assert_has(_gitignore_lines(), "export_credentials.cfg")


func test_build_output_directory_is_ignored() -> void:
	assert_has(_gitignore_lines(), "/build/", "export_presets.cfg writes into build/")


const REQUIRED_PRESETS: Array[String] = ["Windows Desktop", "macOS", "Linux", "Web"]


func _preset_names(cfg: ConfigFile) -> Array[String]:
	var names: Array[String] = []
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			names.append(str(cfg.get_value(section, "name", "")))
	return names


func test_export_presets_file_exists_with_the_four_ci_presets() -> void:
	assert_true(FileAccess.file_exists("res://export_presets.cfg"), "export_presets.cfg must be committed")
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://export_presets.cfg"), OK, "export_presets.cfg parses")
	var names := _preset_names(cfg)
	for required in REQUIRED_PRESETS:
		assert_has(names, required, "CI exports a preset named '%s'" % required)
	assert_eq(names.size(), REQUIRED_PRESETS.size(), "no unexpected extra presets (CI matrix is keyed on these names)")


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
