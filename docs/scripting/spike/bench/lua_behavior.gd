class_name LuaBehaviorA
extends BulletBehavior
## Option A: one Lua call per hooked bullet per tick (BulletBehavior.on_update -> Lua).
var fn: LuaFunction
var throttle := 1
var tick := 0
func on_update(pool: BulletPool, index: int, delta: float) -> void:
	if throttle > 1 and (index + tick) % throttle != 0:
		return
	var p := pool.pos[index]
	var v := pool.vel[index]
	fn.invoke(index, p.x, p.y, v.x, v.y, pool.age[index], pool.param_a[index])
