class_name BulletManager
extends Node2D
## Owns the bullet pool and runs the whole bullet simulation once per physics
## tick: hooks -> kinematics -> collision -> hit/despawn hooks -> removal ->
## render upload. No node, physics body or Object per bullet.

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

var pool: BulletPool
var grid: HurtboxGrid
var emitter: ShotEmitter

## Duration of the last step() call in microseconds, and how many bullets were
## alive afterwards. Used by the HUD and the benchmark.
var last_step_usec := 0
var last_hit_count := 0

var _renderer: BulletRenderer
var _behaviors: Array[BulletBehavior] = [null]


func _ready() -> void:
	pool = BulletPool.new(capacity)
	grid = HurtboxGrid.new(world_bounds, cell_size)
	emitter = BulletShotEmitter.new(self)
	if render_enabled:
		_renderer = BulletRenderer.new()
		_renderer.name = "Renderer"
		_renderer.stretch = bullet_stretch
		# Bullets are simulated on the fixed tick and drawn as-is.
		_renderer.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		add_child(_renderer)
		_renderer.setup(capacity)


func _physics_process(delta: float) -> void:
	if auto_step:
		step(delta)


## Registers a behaviour and returns the id for ShotRequest.behavior_id.
func register_behavior(behavior: BulletBehavior) -> int:
	behavior.emitter = emitter
	_behaviors.append(behavior)
	return _behaviors.size() - 1


## Spawns a bullet from a request and runs its on_spawn hook. Returns the slot
## or -1 when the pool is full.
func spawn(request: ShotRequest) -> int:
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
	pool.advance(delta, world_bounds)

	# Script hooks: only bullets that asked for them.
	for k in pool.hooked_count:
		var i := pool.hooked[k]
		_get_behavior(pool.behavior[i]).on_update(pool, i, delta)

	# Collision against hurtboxes.
	last_hit_count = grid.collide_bullets(pool)
	for k in last_hit_count:
		_apply_hit(grid.hit_bullets[k], grid.hit_targets[k])

	# Despawn hooks, then actually remove the dead.
	for k in pool.pending_count:
		var i := pool.pending[k]
		var id := pool.behavior[i]
		if id != 0:
			_get_behavior(id).on_despawn(pool, i, pool.dead_reason[i] - 1)
	pool.flush_dead()

	if _renderer != null:
		_renderer.update_from(pool)
	last_step_usec = Time.get_ticks_usec() - t0


## Removes all bullets (no hooks are called).
func clear_bullets() -> void:
	pool.clear()
	if _renderer != null:
		_renderer.update_from(pool)


func _collect_targets() -> void:
	grid.begin(pool.max_radius)
	for node in get_tree().get_nodes_in_group(Hurtbox.GROUP):
		var hb := node as Hurtbox
		if hb != null and hb.active and hb.is_visible_in_tree():
			grid.add_circle(hb.global_position, hb.radius, hb.layer, hb)


func _apply_hit(bullet: int, target: int) -> void:
	var hurtbox := grid.target_ref[target] as Hurtbox
	if hurtbox == null or not is_instance_valid(hurtbox):
		return
	hurtbox.receive_hit(pool.damage[bullet], pool.pos[bullet], pool.vel[bullet])
	var id := pool.behavior[bullet]
	if id != 0:
		_get_behavior(id).on_hit(pool, bullet, hurtbox)
	if pool.pierce[bullet] > 0:
		pool.pierce[bullet] -= 1
		pool.last_hit[bullet] = hurtbox.get_instance_id()
	else:
		pool.mark_dead(bullet, BulletPool.DespawnReason.HIT)


func _get_behavior(id: int) -> BulletBehavior:
	return _behaviors[id] if id > 0 and id < _behaviors.size() else null
