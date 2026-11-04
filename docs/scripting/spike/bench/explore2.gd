extends Node
var s: LuaState
func reg(th):
	print("reg got: ", typeof(th), " ", th, " class=", th.get_class() if th is Object else "-")
	if th is LuaThread:
		th.set_hook(Callable(self, "hk"), LuaThread.HOOK_MASK_COUNT, 1000)
		print("  hook set on child")
func hk(ar):
	print("  child hook fired")
	return LuaThread.HOOK_YIELD
func _ready():
	s = LuaState.new()
	s.open_libraries(LuaState.ALL_LIBS)
	s.globals["reg"] = Callable(self, "reg")
	var r = s.do_string("""
	local co = coroutine.create(function() local x = 0; for i=1,5e6 do x = x + 1 end; return x end)
	reg(co)
	local ok, a = coroutine.resume(co)
	print('first resume:', ok, a, coroutine.status(co))
	return 1
	""")
	print("r=", r)
	# async-safety probe: can main thread call set_hook concurrently? (not run; documenting registry write)
	get_tree().quit()
