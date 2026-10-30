extends GutTest
## Guards against files that no other test happens to load. A script with a
## parse error or a scene with a broken reference is otherwise only reported
## as log noise, while `godot --import` and the GUT run still exit 0.

const SCAN_ROOTS: Array[String] = ["res://src", "res://scenes", "res://tests"]


func _collect(dir_path: String, extension: String, out: Array[String]) -> void:
	for file_name in DirAccess.get_files_at(dir_path):
		if file_name.get_extension() == extension:
			out.append(dir_path.path_join(file_name))
	for sub in DirAccess.get_directories_at(dir_path):
		_collect(dir_path.path_join(sub), extension, out)


func test_every_script_loads_and_compiles() -> void:
	var paths: Array[String] = []
	for root in SCAN_ROOTS:
		_collect(root, "gd", paths)
	assert_gt(paths.size(), 0, "found no scripts to check")
	for path in paths:
		var script := load(path) as GDScript
		assert_not_null(script, "failed to load %s" % path)
		if script != null:
			assert_true(script.can_instantiate() or script.is_abstract(), "%s did not compile" % path)


func test_every_scene_loads_and_instantiates() -> void:
	var paths: Array[String] = []
	for root in SCAN_ROOTS:
		_collect(root, "tscn", paths)
	assert_gt(paths.size(), 0, "found no scenes to check")
	for path in paths:
		var scene := load(path) as PackedScene
		assert_not_null(scene, "failed to load %s" % path)
		if scene != null:
			var node := scene.instantiate()
			assert_not_null(node, "failed to instantiate %s" % path)
			if node != null:
				node.free()
