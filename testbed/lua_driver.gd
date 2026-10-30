@warning_ignore_start("unsafe_method_access", "unsafe_property_access", "untyped_declaration", "inferred_declaration", "unsafe_call_argument", "unsafe_cast")
class_name TestbedLuaDriver
extends RefCounted
## Drives scripted bullets from testbed/steer.lua (the Scripting Engineer's spike script, PR #3)
## through stock lua-gdextension 0.8.2. Two ways to call Lua, both from the spike:
##   "batch": one call per physics tick, packed arrays in and out ("option B, gathered inputs")
##   "each":  one call per scripted bullet per tick, from BulletBehavior.on_update ("option A")
## Trail bullets requested by the script (`defer_spawn`) are spawned at the start of the next tick.

const SCRIPT_PATH := "res://testbed/steer.lua"
const MAX_SCRIPTED := 4096
const MAX_COMMANDS := 1024

var mode := "batch"
var behavior_id := 0
var last_error := ""
## Wall time of the last pre_step() Lua phase (gather + call + apply), microseconds.
var last_lua_usec := 0
var lua_mem_kb := 0

var _mgr: BulletManager
var _state: LuaState
var _fn_batch: LuaFunction
var _fn_each: LuaFunction
var _ids := PackedInt32Array()
var _pos := PackedFloat32Array()
var _vel := PackedFloat32Array()
var _age := PackedFloat32Array()
var _pa := PackedFloat32Array()
var _out_vel := PackedFloat32Array()
var _cmds := PackedFloat32Array()
var _deferred := PackedFloat32Array()
var _deferred_count := 0
var _req := ShotRequest.new()
var _noop := BulletBehavior.new()
var _each: TestbedLuaEach


static func is_available() -> bool:
	return ClassDB.class_exists("LuaState")


func setup(mgr: BulletManager, p_mode: String) -> bool:
	_mgr = mgr
	mode = p_mode
	_state = LuaState.new()
	_state.open_libraries(LuaState.LUA_BASE | LuaState.LUA_MATH | LuaState.LUA_STRING | LuaState.LUA_TABLE | LuaState.LUA_COROUTINE | LuaState.GODOT_VARIANT | LuaState.GODOT_UTILITY_FUNCTIONS)
	_state.globals["set_vel"] = Callable(self, "_set_vel")
	_state.globals["defer_spawn"] = Callable(self, "_defer_spawn")
	var src := FileAccess.get_file_as_string(SCRIPT_PATH)
	if src == "":
		last_error = "cannot read " + SCRIPT_PATH
		return false
	var loaded = _state.load_string(src, "steer.lua").invoke()
	if loaded is LuaError:
		last_error = "steer.lua: " + str(loaded.message)
		return false
	_fn_batch = loaded.get("on_update_batch")
	_fn_each = loaded.get("on_update")
	_deferred.resize(4 * 8192)
	if mode == "each":
		_each = TestbedLuaEach.new()
		_each.fn = _fn_each
		behavior_id = mgr.register_behavior(_each)
	else:
		_ids.resize(MAX_SCRIPTED)
		_pos.resize(2 * MAX_SCRIPTED)
		_vel.resize(2 * MAX_SCRIPTED)
		_age.resize(MAX_SCRIPTED)
		_pa.resize(MAX_SCRIPTED)
		_out_vel.resize(2 * MAX_SCRIPTED)
		_cmds.resize(4 * MAX_COMMANDS)
		# The batch is called from pre_step(); the per-bullet hook itself does nothing.
		behavior_id = mgr.register_behavior(_noop)
	return true


func version_string() -> String:
	return str(LuaState.get_lua_version_string())


func scripted_count() -> int:
	var pool := _mgr.pool
	var c := 0
	var id := behavior_id
	for i in pool.count:
		if pool.behavior[i] == id:
			c += 1
	return c


## Call once per physics tick before BulletManager.step().
func pre_step(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_apply_deferred()
	if mode == "batch":
		_batch(delta)
	if mode == "batch":
		last_lua_usec = Time.get_ticks_usec() - t0
	else:
		# Per-bullet calls run inside BulletManager.step(); report last tick's total.
		last_lua_usec = _each.usec
		_each.usec = 0
	lua_mem_kb = _state.get_memory_used() / 1024


func _batch(delta: float) -> void:
	var pool := _mgr.pool
	var n := 0
	var id := behavior_id
	for i in pool.count:
		if pool.behavior[i] != id or n >= MAX_SCRIPTED:
			continue
		_ids[n] = i
		var p := pool.pos[i]
		var v := pool.vel[i]
		_pos[2 * n] = p.x
		_pos[2 * n + 1] = p.y
		_vel[2 * n] = v.x
		_vel[2 * n + 1] = v.y
		_age[n] = pool.age[i]
		_pa[n] = pool.param_a[i]
		n += 1
	if n == 0:
		return
	var r = _fn_batch.invoke(_ids, _pos, _vel, _age, _pa, n, delta, _out_vel, _cmds)
	if r is LuaError:
		last_error = str(r.message)
		return
	var ov: PackedFloat32Array = r[0]
	var oc: PackedFloat32Array = r[1]
	var nc: int = r[2]
	for k in n:
		pool.vel[_ids[k]] = Vector2(ov[2 * k], ov[2 * k + 1])
	for k in mini(nc, MAX_COMMANDS):
		_defer_spawn(oc[4 * k], oc[4 * k + 1], oc[4 * k + 2], oc[4 * k + 3])


func _set_vel(i: int, vx: float, vy: float) -> void:
	_mgr.pool.vel[i] = Vector2(vx, vy)


func _defer_spawn(x: float, y: float, ang: float, spd: float) -> void:
	if _deferred_count >= 8192:
		return
	var o := _deferred_count * 4
	_deferred[o] = x
	_deferred[o + 1] = y
	_deferred[o + 2] = ang
	_deferred[o + 3] = spd
	_deferred_count += 1


func _apply_deferred() -> void:
	var n := _deferred_count
	_deferred_count = 0
	for k in n:
		var o := k * 4
		_req.reset()
		_req.position = Vector2(_deferred[o], _deferred[o + 1])
		_req.velocity = Vector2.from_angle(_deferred[o + 2]) * _deferred[o + 3]
		_req.lifetime = 0.25
		_req.radius = 2.0
		_req.hit_mask = 0
		_req.color = Color("f2a65a")
		_mgr.spawn(_req)


## Option A: one Lua call per hooked bullet per tick.
class TestbedLuaEach:
	extends BulletBehavior
	var fn: LuaFunction
	var usec := 0

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		var p := pool.pos[index]
		var v := pool.vel[index]
		var t0 := Time.get_ticks_usec()
		fn.invoke(index, p.x, p.y, v.x, v.y, pool.age[index], pool.param_a[index])
		usec += Time.get_ticks_usec() - t0
