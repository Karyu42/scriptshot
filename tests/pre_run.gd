extends GutHookScript
## Points the player save slot at a throwaway file before any test runs.
## Main leaves save_path empty and therefore cannot open the real slot.


func run() -> void:
	var stamp := str(Time.get_ticks_usec())
	var dir := "user://test_tmp/%s" % stamp
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	if err != OK:
		push_error("Could not create the isolated save directory (%s)" % err)
	SaveGame.slot_override = dir.path_join("save.cfg")
