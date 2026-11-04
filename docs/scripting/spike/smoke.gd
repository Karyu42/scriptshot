extends SceneTree
func _init():
	var s := LuaState.new()
	s.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE)
	var r = s.do_string("return _VERSION .. ' ' .. (jit and jit.version or 'nojit')")
	print("LUA: ", r, " runtime=", LuaState.get_lua_runtime(), " ver=", LuaState.get_lua_version_string())
	quit()
