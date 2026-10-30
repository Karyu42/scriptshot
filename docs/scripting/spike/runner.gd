extends Node
func _ready():
	var which := "calls"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0: which = args[0]
	elif OS.has_feature("web") or OS.has_feature("mobile"): which = "export_bench"
	var scr = load("res://bench/%s.gd" % which)
	if scr == null or not scr.can_instantiate():
		push_error("cannot load bench " + which)
		get_tree().quit(1)
		return
	add_child(scr.new())
