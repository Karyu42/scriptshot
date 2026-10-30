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
