class_name SpikeManager
extends BulletManager
## Copy of BulletManager.step() (PR #2) with the hook phase switchable between
## granularity options. Everything else (pool, grid, collision) is the PR's code.
##   mode "C"        : no hook phase (declarative kinematics only)
##   mode "A"        : per-bullet BulletBehavior.on_update (the PR's current path)
##   mode "B_gather" : one batch call; inputs gathered per bullet from `hooked`
##   mode "B_slice"  : one batch call; inputs are bulk packed-array slices (what a
##                     behavior-bucketed contiguous pool would allow)

var mode := "C"
var tick := 0
var throttle := 1
var lua_batch: LuaFunction
var id_arr := PackedInt32Array()   # stand-in for the stable-id column (id == slot here)
# deferred spawns (applied at the start of next tick)
var deferred := PackedFloat32Array()
var deferred_count := 0
var defer_life := 0.25
var _req := ShotRequest.new()
# per-phase timing of the last step (usec)
var t_defer := 0
var t_hooks := 0
var t_copy_in := 0
var t_lua := 0
var t_apply := 0
var t_total := 0

func _ready() -> void:
	super._ready()
	deferred.resize(4 * 8192)
	id_arr.resize(capacity)
	for i in capacity: id_arr[i] = i

# --- command sinks used by Lua (Callables) and by batch apply -------------------------
func set_vel(i: int, vx: float, vy: float) -> void:
	pool.vel[i] = Vector2(vx, vy)

func defer_spawn(x: float, y: float, ang: float, spd: float) -> void:
	if deferred_count >= 8192: return
	var o := deferred_count * 4
	deferred[o] = x; deferred[o + 1] = y; deferred[o + 2] = ang; deferred[o + 3] = spd
	deferred_count += 1

func _apply_deferred() -> void:
	var n := deferred_count
	deferred_count = 0
	for k in n:
		var o := k * 4
		_req.reset()
		_req.position = Vector2(deferred[o], deferred[o + 1])
		_req.velocity = Vector2.from_angle(deferred[o + 2]) * deferred[o + 3]
		_req.lifetime = defer_life
		_req.radius = 2.0
		_req.hit_mask = 0
		spawn(_req)

func step(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_apply_deferred()
	t_defer = Time.get_ticks_usec() - t0
	_collect_targets()
	pool.advance(delta, world_bounds)

	var h0 := Time.get_ticks_usec()
	t_copy_in = 0; t_lua = 0; t_apply = 0
	match mode:
		"A":
			for k in pool.hooked_count:
				var i := pool.hooked[k]
				_get_behavior(pool.behavior[i]).on_update(pool, i, delta)
		"B_gather", "B_slice":
			_batch_update(delta)
	t_hooks = Time.get_ticks_usec() - h0

	last_hit_count = grid.collide_bullets(pool)
	for k in last_hit_count:
		_apply_hit(grid.hit_bullets[k], grid.hit_targets[k])
	for k in pool.pending_count:
		var i := pool.pending[k]
		var id := pool.behavior[i]
		if id != 0:
			_get_behavior(id).on_despawn(pool, i, pool.dead_reason[i] - 1)
	pool.flush_dead()
	if _renderer != null:
		_renderer.update_from(pool)
	tick += 1
	t_total = Time.get_ticks_usec() - t0
	last_step_usec = t_total

func _batch_update(delta: float) -> void:
	var n := pool.hooked_count
	if n == 0: return
	var c0 := Time.get_ticks_usec()
	var ids: PackedInt32Array
	var vel_f: PackedFloat32Array
	var age: PackedFloat32Array
	var pa: PackedFloat32Array
	var pos_f: PackedFloat32Array
	if mode == "B_slice":
		var sn := n / throttle if throttle > 1 else n
		var st := (tick % throttle) * sn if throttle > 1 else 0
		n = sn
		ids = id_arr.slice(st, st + n)
		vel_f = pool.vel.slice(st, st + n).to_byte_array().to_float32_array()
		pos_f = pool.pos.slice(st, st + n).to_byte_array().to_float32_array()
		age = pool.age.slice(st, st + n)
		pa = pool.param_a.slice(st, st + n)
	else:
		ids.resize(n); age.resize(n); pa.resize(n)
		vel_f.resize(2 * n); pos_f.resize(2 * n)
		for k in n:
			var i := pool.hooked[k]
			ids[k] = i
			var v := pool.vel[i]
			vel_f[2 * k] = v.x; vel_f[2 * k + 1] = v.y
			var p := pool.pos[i]
			pos_f[2 * k] = p.x; pos_f[2 * k + 1] = p.y
			age[k] = pool.age[i]
			pa[k] = pool.param_a[i]
	var out_vel := PackedFloat32Array(); out_vel.resize(2 * n)
	var cmds := PackedFloat32Array(); cmds.resize(4 * (n / 8 + 16))
	var c1 := Time.get_ticks_usec()
	t_copy_in = c1 - c0
	var r = lua_batch.invoke(ids, pos_f, vel_f, age, pa, n, delta, out_vel, cmds)
	var c2 := Time.get_ticks_usec()
	t_lua = c2 - c1
	var ov: PackedFloat32Array = r[0]
	var oc: PackedFloat32Array = r[1]
	var ncmd: int = r[2]
	if mode == "B_slice":
		var st2 := (tick % throttle) * n if throttle > 1 else 0
		for k in n:   # contiguous write-back (a native pool would memcpy this)
			pool.vel[st2 + k] = Vector2(ov[2 * k], ov[2 * k + 1])
	else:
		for k in n:
			pool.vel[ids[k]] = Vector2(ov[2 * k], ov[2 * k + 1])
	for k in ncmd:
		defer_spawn(oc[4 * k], oc[4 * k + 1], oc[4 * k + 2], oc[4 * k + 3])
	t_apply = Time.get_ticks_usec() - c2
