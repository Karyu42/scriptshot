extends SceneTree
func _init():
	var bad := 0
	for f in OS.get_environment("LUAFILES").split(":"):
		var code := FileAccess.get_file_as_string(f)
		var L := LuaState.new()
		L.open_libraries(1|2|4|8|16|32|64|128|256|8192)
		var r = L.load_string("return function() end; " if false else code, f)
		var ok = not (r is LuaError)
		# compile-only: load_string executes? it returns a function/chunk; fine either way for syntax
		print("SYN ", f, " ", "OK" if ok else str(r))
		if not ok: bad += 1
	print("SYNDONE bad=", bad)
	quit(bad)
