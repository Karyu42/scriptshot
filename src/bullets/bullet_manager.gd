class_name BulletManager
extends Node2D
## Owns the bullet pool and runs the whole bullet simulation once per physics
## tick: kinematics -> hooks -> wall + hurtbox collision (swept) -> hit/despawn
## hooks -> removal -> render upload. No node, physics body or Object per bullet.
##
## Keep this node at the world origin (it is the parent of the bullet renderer,
## and bullet positions are world positions).

## Bullets spawned by other nodes earlier in the same physics tick (the player's
## weapon, stress tests, Lua shot scripts) must be integrated and drawn on that
## same tick. Godot runs _physics_process in ascending process_physics_priority
## (ties broken by tree order), so the manager runs after everything at the
## default priority of 0.
const PHYSICS_PRIORITY := 100

## Hard cap on simultaneously alive bullets (excess spawns are dropped).
@export var capacity := 16384
## Bullets are despawned when they leave this rectangle (world space).
@export var world_bounds := Rect2(-1312, -752, 2624, 1504)
## Spatial hash cell size for collision, in pixels.
@export var cell_size := 64.0
## Disable to run the simulation without drawing (benchmarks, dedicated tests).
@export var render_enabled := true
## Step automatically from _physics_process. Turn off to drive step() manually.
@export var auto_step := true
## Visual stretch of bullets along their heading (1 = round).
@export var bullet_stretch := 1.0
## On _ready, every CollisionObject2D in this group that is on the `world` layer
## contributes its (axis-aligned) RectangleShape2D shapes as bullet walls.
@export var walls_group := &"world_walls"

var pool: BulletPool
var grid: HurtboxGrid
var walls: WallGrid
var emitter: ShotEmitter
## "native" when the C++ NativeBulletSim simulates the plain bullets, otherwise
## "gdscript" (everything in `pool`). Chosen in _ready(); see backend_preference.
var backend := "gdscript"
## Which backend to use: "auto" (native if the extension is loaded), "gdscript"
## or "native" (error and fall back if the extension is missing). With "auto" the
## environment variable SCRIPTSHOT_BULLET_BACKEND (gdscript|native) picks the
## backend. Set before adding to the tree.
@export_enum("auto", "gdscript", "native") var backend_preference := "auto"
var native: NativeBackend

## Duration of the last step() call in microseconds.
var last_step_usec := 0
## Bullet-vs-hurtbox and bullet-vs-wall hits found by the last step().
var last_hit_count := 0
var last_wall_hit_count := 0
## Microseconds spent in each phase of the last step(), indexed by Phase.
var last_phase_usec := PackedInt32Array([0, 0, 0, 0, 0])

enum Phase { TARGETS_AND_ADVANCE, HOOKS_AND_WALLS, HURTBOXES, DESPAWN, RENDER }

var _renderer: BulletRenderer
var _native_renderer: NativeBulletRenderer
# Hurtbox snapshot handed to the native sim each tick.
var _nt_pos := PackedVector2Array()
var _nt_radius := PackedFloat32Array()
var _nt_layer := PackedInt32Array()
var _nt_ids := PackedInt64Array()
var _behaviors: Array[BulletBehavior] = [null]


func _init() -> void:
	process_physics_priority = PHYSICS_PRIORITY


func _ready() -> void:
	pool = BulletPool.new(capacity)
	grid = HurtboxGrid.new(world_bounds, cell_size)
	walls = WallGrid.new(world_bounds, cell_size)
	emitter = BulletShotEmitter.new(self)
	_select_backend()
	collect_walls()
	if render_enabled:
		_renderer = BulletRenderer.new()
		_renderer.name = "Renderer"
		_renderer.stretch = bullet_stretch
		add_child(_renderer)
		_renderer.setup(capacity, world_bounds)
		if native != null:
			_native_renderer = NativeBulletRenderer.new()
			_native_renderer.name = "NativeRenderer"
			_native_renderer.stretch = bullet_stretch
			add_child(_native_renderer)
			_native_renderer.setup(capacity, world_bounds)


func _physics_process(delta: float) -> void:
	if auto_step:
		step(delta)


## Registers a behaviour and returns the id for ShotRequest.behavior_id.
func register_behavior(behavior: BulletBehavior) -> int:
	behavior.emitter = emitter
	_behaviors.append(behavior)
	return _behaviors.size() - 1


## Adds a static wall rectangle (world space) that bullets collide with unless
## they were spawned with collide_world = false.
func add_wall(rect: Rect2) -> void:
	walls.add_wall(rect)
	if native != null:
		native.add_wall(rect)


func clear_walls() -> void:
	walls.clear_walls()
	if native != null:
		native.clear_walls()


## (Re)reads walls from `walls_group`: every CollisionObject2D on the `world`
## layer contributes its RectangleShape2D children, as their world-space bounding
## box (other shapes are ignored, rotated rectangles are approximated; both
## push a warning, see WallGrid.shape_issue). Returns the number of walls added.
## Existing walls are kept.
func collect_walls() -> int:
	var added := 0
	if not is_inside_tree():
		return added
	for node in get_tree().get_nodes_in_group(walls_group):
		var body := node as CollisionObject2D
		if body == null or (body.collision_layer & Layers.WORLD) == 0:
			continue
		for child in body.get_children():
			var shape_node := child as CollisionShape2D
			if shape_node == null or shape_node.disabled:
				continue
			var issue := WallGrid.shape_issue(shape_node.shape, shape_node.global_transform)
			if issue != "":
				push_warning("BulletManager: wall shape %s %s" % [shape_node.get_path(), issue])
			var rect_shape := shape_node.shape as RectangleShape2D
			if rect_shape == null:
				continue
			walls.add_wall(shape_node.global_transform * Rect2(-rect_shape.size * 0.5, rect_shape.size))
			added += 1
	return added


## Spawns a bullet from a request and runs its on_spawn hook. Returns the slot
## or -1 when the pool is full.
func spawn(request: ShotRequest) -> int:
	# Plain bullets go to the native sim; the return value is then its stable id
	# (> 0), for hooked bullets it is the pool slot as before. Only >= 0 means success.
	if native != null and request.behavior_id == 0:
		return native.spawn(request)
	var i := pool.spawn(request)
	if i >= 0 and request.behavior_id != 0:
		var b := _get_behavior(request.behavior_id)
		if b == null:
			push_warning("BulletManager: unknown behavior_id %d, spawning a plain bullet" % request.behavior_id)
			pool.behavior[i] = 0
		else:
			b.on_spawn(pool, i)
	return i


## Advances the whole bullet simulation by `delta` seconds.
func step(delta: float) -> void:
	var t0 := Time.get_ticks_usec()

	_collect_targets()
	var native_hits := 0
	var native_wall_hits := 0
	if native != null:
		# Plain bullets: integrate, sweep walls + hurtboxes, despawn, deliver hits.
		native_hits = native.step(delta)
		native_wall_hits = native.last_wall_hit_count()
	pool.advance(delta, world_bounds)
	var t1 := Time.get_ticks_usec()

	# Script hooks: only bullets that asked for them. A hook may have killed a
	# later bullet in the list already; dead bullets get no more updates.
	for k in pool.hooked_count:
		var i := pool.hooked[k]
		if pool.dead_reason[i] == 0:
			_get_behavior(pool.behavior[i]).on_update(pool, i, delta)

	# A hook may have spawned a bullet bigger than any the targets were bucketed
	# for; re-bucket with the new margin so it does not miss targets by a hair.
	if pool.max_radius > grid.get_margin():
		_collect_targets()

	# Walls first: a bullet that hits one is clipped to the impact point, so the
	# hurtbox test below only sees the part of its path before the wall.
	last_wall_hit_count = walls.sweep_bullets(pool)
	for k in last_wall_hit_count:
		var i := walls.hit_bullets[k]
		pool.pos[i] = pool.prev_pos[i].lerp(pool.pos[i], walls.hit_t[k])

	var t2 := Time.get_ticks_usec()
	last_hit_count = grid.collide_bullets(pool)
	for k in last_hit_count:
		_apply_hit(grid.hit_bullets[k], grid.hit_targets[k], grid.hit_t[k])

	# A bullet that reached a wall despawns there (unless a hurtbox already
	# claimed it earlier on its path: first reason wins).
	for k in last_wall_hit_count:
		var wall_bullet := walls.hit_bullets[k]
		pool.mark_dead(wall_bullet, BulletPool.DespawnReason.WALL)
		pool.claim_from_bounds(wall_bullet, BulletPool.DespawnReason.WALL)

	last_hit_count += native_hits
	last_wall_hit_count += native_wall_hits
	var t3 := Time.get_ticks_usec()
	# Despawn hooks, then actually remove the dead. Hooks may mark more bullets
	# dead (they are appended to the pending list and visited too); every bullet
	# is announced exactly once, and slots that no longer hold a dead bullet
	# (removed from inside a hook) are skipped.
	var p := 0
	while p < pool.pending_count:
		var slot := pool.pending[p]
		p += 1
		if slot >= pool.count or pool.dead_reason[slot] == 0:
			continue
		var id := pool.behavior[slot]
		if id != 0:
			_get_behavior(id).on_despawn(pool, slot, pool.dead_reason[slot] - 1)
	pool.flush_dead()
	var t4 := Time.get_ticks_usec()

	if _renderer != null:
		_renderer.update_from(pool)
	if _native_renderer != null:
		_native_renderer.update_from(native)
	var t5 := Time.get_ticks_usec()
	last_phase_usec[Phase.TARGETS_AND_ADVANCE] = t1 - t0
	last_phase_usec[Phase.HOOKS_AND_WALLS] = t2 - t1
	last_phase_usec[Phase.HURTBOXES] = t3 - t2
	last_phase_usec[Phase.DESPAWN] = t4 - t3
	last_phase_usec[Phase.RENDER] = t5 - t4
	last_step_usec = t5 - t0


## Removes all bullets (no hooks are called).
func clear_bullets() -> void:
	pool.clear()
	if _renderer != null:
		_renderer.update_from(pool)
	if native != null:
		native.clear()
		if _native_renderer != null:
			_native_renderer.update_from(native)


## Number of alive bullets in both backends (native plain bullets + pool).
func alive_count() -> int:
	return pool.count + (native.count() if native != null else 0)


## Bullets spawned since creation, across both backends.
func spawned_total() -> int:
	return pool.spawned_total + (native.spawned_total() if native != null else 0)


## Stable id of the bullet `spawn()` returned for plain native bullets, tests.
func is_native_bullet_alive(id: int) -> bool:
	return native != null and native.is_alive(id)


## Dense copy of every alive bullet: pos, prev_pos, vel, age, lifetime, radius,
## pierce, from whichever backend simulates them (plain native bullets first,
## then the pool). Meant for tests, parity checks and tools, not for hot paths.
func snapshot() -> Dictionary:
	var pos := PackedVector2Array()
	var prev_pos := PackedVector2Array()
	var vel := PackedVector2Array()
	var age := PackedFloat32Array()
	var lifetime := PackedFloat32Array()
	var radius := PackedFloat32Array()
	var pierce := PackedInt32Array()
	var hit_mask := PackedInt32Array()
	if native != null:
		var snap := native.snapshot()
		pos = snap["pos"]
		prev_pos = snap["prev_pos"]
		vel = snap["vel"]
		age = snap["age"]
		lifetime = snap["lifetime"]
		radius = snap["radius"]
		pierce = snap["pierce"]
		hit_mask = snap["hit_mask"]
	var n := pool.count
	pos.append_array(pool.pos.slice(0, n))
	prev_pos.append_array(pool.prev_pos.slice(0, n))
	vel.append_array(pool.vel.slice(0, n))
	age.append_array(pool.age.slice(0, n))
	lifetime.append_array(pool.lifetime.slice(0, n))
	radius.append_array(pool.radius.slice(0, n))
	pierce.append_array(pool.pierce.slice(0, n))
	hit_mask.append_array(pool.hit_mask.slice(0, n))
	return {
		"pos": pos, "prev_pos": prev_pos, "vel": vel, "age": age, "lifetime": lifetime, "radius": radius,
		"pierce": pierce, "hit_mask": hit_mask,
	}


func _select_backend() -> void:
	var wanted := backend_preference
	if wanted == "auto":
		wanted = NativeBackend.requested_backend()
	if wanted == "gdscript" or (wanted == "auto" and not NativeBackend.is_available()):
		return
	if not NativeBackend.is_available():
		push_error("BulletManager: native backend requested but the NativeBulletSim extension is not loaded (build it with scons in native/); using the GDScript backend")
		return
	native = NativeBackend.new(capacity, world_bounds, cell_size)
	backend = "native"


func _collect_targets() -> void:
	var need_grid := native == null or pool.count > 0
	if need_grid:
		grid.begin(pool.max_radius)
	var targets := Hurtbox.registry
	var n := 0
	if native != null:
		if _nt_pos.size() < targets.size():
			_nt_pos.resize(targets.size())
			_nt_radius.resize(targets.size())
			_nt_layer.resize(targets.size())
			_nt_ids.resize(targets.size())
	for k in targets.size():
		var hb := targets[k]
		if hb.active and hb.is_visible_in_tree():
			var center := hb.global_position
			if need_grid:
				grid.add_circle(center, hb.radius, hb.layer, hb)
			if native != null:
				_nt_pos[n] = center
				_nt_radius[n] = hb.radius
				_nt_layer[n] = hb.layer
				_nt_ids[n] = hb.get_instance_id()
				n += 1
	if native != null:
		native.set_targets(_nt_pos, _nt_radius, _nt_layer, _nt_ids, n)


func _apply_hit(bullet: int, target: int, t: float) -> void:
	# An earlier hit's hook may have killed this bullet in the meantime. (A bullet
	# that only left the world bounds this tick still counts its last segment.)
	var dead := pool.dead_reason[bullet]
	if dead != 0 and dead != BulletPool.DespawnReason.BOUNDS + 1:
		return
	var hurtbox := grid.target_ref[target] as Hurtbox
	if hurtbox == null or not is_instance_valid(hurtbox):
		return
	var impact: Vector2 = pool.prev_pos[bullet].lerp(pool.pos[bullet], t)
	var piercing := pool.pierce[bullet] > 0
	if not piercing:
		# The bullet stops where it touched the target.
		pool.pos[bullet] = impact
	hurtbox.receive_hit(pool.damage[bullet], impact, pool.vel[bullet])
	var id := pool.behavior[bullet]
	if id != 0:
		_get_behavior(id).on_hit(pool, bullet, hurtbox)
	if piercing:
		pool.pierce[bullet] -= 1
		pool.last_hit[bullet] = hurtbox.get_instance_id()
	else:
		pool.mark_dead(bullet, BulletPool.DespawnReason.HIT)
		pool.claim_from_bounds(bullet, BulletPool.DespawnReason.HIT)


func _get_behavior(id: int) -> BulletBehavior:
	return _behaviors[id] if id > 0 and id < _behaviors.size() else null
