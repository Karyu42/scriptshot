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
## Minimum simulated seconds between two "pool saturated" warnings in the log.
## The pool_saturated signal itself fires on every tick that dropped shots.
## PROVISIONAL default: 2 s.
@export var saturation_warning_interval := 2.0

var pool: BulletPool
var grid: HurtboxGrid
## Reflector zones, bucketed like hurtboxes but matched on bullet owner.
var reflector_grid: HurtboxGrid
var walls: WallGrid
var emitter: ShotEmitter

## Duration of the last step() call in microseconds.
var last_step_usec := 0
## Bullet-vs-hurtbox and bullet-vs-wall hits found by the last step().
var last_hit_count := 0
## Bullets reflected by Reflector zones in the last step.
var last_reflect_count := 0
var last_wall_hit_count := 0
## Microseconds spent in each phase of the last step(), indexed by Phase.
var last_phase_usec := PackedInt32Array([0, 0, 0, 0, 0])

enum Phase { TARGETS_AND_ADVANCE, HOOKS_AND_WALLS, HURTBOXES, DESPAWN, RENDER }
## How many saturation warnings have been pushed (rate-limited; for tests/HUD).
var saturation_warnings_emitted := 0

var _renderer: BulletRenderer
var _behaviors: Array[BulletBehavior] = [null]
var _sim_time := 0.0
var _dropped_reported := 0
var _last_warning_time := -INF
## Bullets reflected by a zone this tick (slots, and the path fraction of the
## reflection), plus a per-slot flag. They fly on after the mirror, see
## _continue_reflected(), and the wall hit of their old path no longer counts.
var _reflected_slots := PackedInt32Array()
var _reflected_t := PackedFloat32Array()
var _reflected_flag := PackedByteArray()
var _reflected_count := 0


func _init() -> void:
	process_physics_priority = PHYSICS_PRIORITY


func _ready() -> void:
	pool = BulletPool.new(capacity)
	_reflected_slots.resize(capacity)
	_reflected_t.resize(capacity)
	_reflected_flag.resize(capacity)
	grid = HurtboxGrid.new(world_bounds, cell_size)
	reflector_grid = HurtboxGrid.new(world_bounds, cell_size)
	walls = WallGrid.new(world_bounds, cell_size)
	emitter = BulletShotEmitter.new(self)
	collect_walls()
	if render_enabled:
		_renderer = BulletRenderer.new()
		_renderer.name = "Renderer"
		_renderer.stretch = bullet_stretch
		add_child(_renderer)
		_renderer.setup(capacity, world_bounds)


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


func clear_walls() -> void:
	walls.clear_walls()


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
	var i := pool.spawn(request)
	if i >= 0 and request.behavior_id != 0:
		var b := _get_behavior(request.behavior_id)
		if b == null:
			push_warning("BulletManager: unknown behavior_id %d, spawning a plain bullet" % request.behavior_id)
			pool.behavior[i] = 0
		else:
			b.on_spawn(pool, i)
	return i


## Hands the live bullet with stable id `id` to `new_owner_layer` (Layers.PLAYER
## or Layers.ENEMY): it now hits only what is hostile to the new owner, takes its
## faction colour, deals `new_damage` and (unless `keep_script`) stops being
## scripted. See BulletPool.reflect(). Returns false for a stale id, an invalid
## owner, or a bullet that has used up its reflections.
func reflect(
	id: int,
	new_owner_layer: int,
	reverse: bool = false,
	new_damage: float = BulletPool.REFLECTED_DAMAGE,
	keep_script: bool = false
) -> bool:
	if not pool.is_alive(id):
		return false
	return pool.reflect(pool.slot_of(id), new_owner_layer, reverse, new_damage, keep_script)


## Advances the whole bullet simulation by `delta` seconds.
func step(delta: float) -> void:
	var t0 := Time.get_ticks_usec()

	_collect_targets()
	pool.advance(delta, world_bounds)
	var t1 := Time.get_ticks_usec()

	# Script hooks: only bullets that asked for them. A hook may have killed a
	# later bullet in the list already; dead bullets get no more updates.
	for k in pool.hooked_count:
		var i := pool.hooked[k]
		# A hook may have reflected (and so un-scripted) a later bullet in the list.
		if pool.dead_reason[i] == 0 and pool.behavior[i] != 0:
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
	# Zones and hurtboxes are swept on the same (wall-clipped) path, then their hits
	# are delivered per bullet in order of time along the path: a target in front of
	# a mirror is hit before the mirror turns the bullet around, a mirror in front
	# of a target turns it before it can reach the target. A reflected bullet then
	# flies on for the rest of the tick along its new heading.
	var zone_hits := _collect_zone_hits()
	last_hit_count = grid.collide_bullets(pool)
	if zone_hits == 0:
		for k in last_hit_count:
			_apply_hit(grid.hit_bullets[k], grid.hit_targets[k], grid.hit_t[k])
	else:
		_resolve_hits_in_time_order(zone_hits)
		_continue_reflected(delta)

	# A bullet that reached a wall despawns there (unless a hurtbox already
	# claimed it earlier on its path: first reason wins). A bullet that a mirror
	# turned around before the wall is not at that wall any more.
	for k in last_wall_hit_count:
		var wall_bullet := walls.hit_bullets[k]
		if _reflected_flag[wall_bullet] != 0:
			continue
		pool.mark_dead(wall_bullet, BulletPool.DespawnReason.WALL)
		pool.claim_from_bounds(wall_bullet, BulletPool.DespawnReason.WALL)
	for r in _reflected_count:
		_reflected_flag[_reflected_slots[r]] = 0
	_reflected_count = 0

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

	_sim_time += delta
	_report_saturation()

	if _renderer != null:
		_renderer.update_from(pool)
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


## Emits ShotEmitter.pool_saturated if shots were dropped since the last tick,
## and pushes a warning at most once per saturation_warning_interval.
func _report_saturation() -> void:
	var dropped_now := pool.dropped_total - _dropped_reported
	if dropped_now <= 0:
		return
	_dropped_reported = pool.dropped_total
	emitter.pool_saturated.emit(dropped_now, pool.dropped_total)
	if _sim_time - _last_warning_time >= saturation_warning_interval:
		_last_warning_time = _sim_time
		saturation_warnings_emitted += 1
		push_warning("BulletManager: bullet pool saturated (capacity %d); dropped %d shot(s) this tick, %d in total. Raise BulletManager.capacity or fire fewer bullets."
			% [pool.capacity, dropped_now, pool.dropped_total])


## One swept pass over the bullets against every active Reflector zone. Fills
## reflector_grid's hit list (per bullet, in path order, up to
## HurtboxGrid.MAX_ZONE_HITS zones) and returns its length; nothing is reflected
## yet (see _resolve_hits_in_time_order()). Costs nothing while no zone exists.
func _collect_zone_hits() -> int:
	last_reflect_count = 0
	_reflected_count = 0
	var zones := Reflector.registry
	if zones.is_empty():
		return 0
	reflector_grid.begin(pool.max_radius)
	for k in zones.size():
		var zone := zones[k]
		if zone.is_active():
			reflector_grid.add_circle(zone.global_position, zone.radius, zone.reflects_owners, zone)
	return reflector_grid.collide_bullets(pool, true)


## Delivers one tick's hurtbox hits (grid) and zone crossings (reflector_grid),
## bullet by bullet, in order of time along the bullet's path (hit_t); a zone wins
## a tie. Both lists are grouped per bullet in ascending slot order and ordered
## by time within a bullet, so this is a merge.
##
##  * A hurtbox hit is delivered as usual (_apply_hit); a bullet it consumed takes
##    no further part.
##  * A zone crossing is offered to the zone (guard, direction, arc). A zone that
##    declines lets the next event on the path happen. A zone that reflects ends
##    the old path: every later event of that bullet in either list was computed
##    for a path the bullet no longer follows, so it is dropped (at most one
##    reflection per bullet per tick), and the bullet is queued for
##    _continue_reflected().
func _resolve_hits_in_time_order(zone_hits: int) -> void:
	var kh := 0
	var kz := 0
	var hurt_hits := last_hit_count
	while kh < hurt_hits or kz < zone_hits:
		var hurt_bullet := grid.hit_bullets[kh] if kh < hurt_hits else pool.capacity
		var zone_bullet := reflector_grid.hit_bullets[kz] if kz < zone_hits else pool.capacity
		var bullet := mini(hurt_bullet, zone_bullet)
		var reflected := false
		while true:
			var has_hurt := kh < hurt_hits and grid.hit_bullets[kh] == bullet
			var has_zone := kz < zone_hits and reflector_grid.hit_bullets[kz] == bullet
			if not has_hurt and not has_zone:
				break
			if reflected:
				# The old path is over: skip what is left of it.
				if has_hurt:
					kh += 1
				if has_zone:
					kz += 1
				continue
			if has_zone and (not has_hurt or reflector_grid.hit_t[kz] <= grid.hit_t[kh]):
				if _try_reflect(bullet, kz):
					reflected = true
				kz += 1
			else:
				_apply_hit(bullet, grid.hit_targets[kh], grid.hit_t[kh])
				kh += 1


## Offers zone hit `k` of reflector_grid to its zone. True if the bullet was reflected.
func _try_reflect(bullet: int, k: int) -> bool:
	var zone := reflector_grid.target_ref[reflector_grid.hit_targets[k]] as Reflector
	if zone == null or not is_instance_valid(zone):
		return false
	var t := reflector_grid.hit_t[k]
	var impact := pool.prev_pos[bullet].lerp(pool.pos[bullet], t)
	if not zone.reflect_bullet(pool, bullet, impact):
		return false
	last_reflect_count += 1
	_reflected_slots[_reflected_count] = bullet
	_reflected_t[_reflected_count] = t
	_reflected_count += 1
	_reflected_flag[bullet] = 1
	return true


## Lets every bullet reflected this tick fly on from its impact point along its new
## velocity for the rest of the tick (the part after the reflection, `(1 - t) *
## delta`), against walls and against the hurtboxes of its *new* side, in time
## order like any other bullet. `prev_pos` is the impact point and `pos` the end of
## that part (clipped at a wall), so the renderer interpolates the new leg only.
## A bullet is reflected at most once per tick, so zones are not consulted again.
func _continue_reflected(delta: float) -> void:
	for r in _reflected_count:
		var slot := _reflected_slots[r]
		if pool.dead_reason[slot] != 0:
			continue
		var start := pool.pos[slot]  # the impact point (BulletPool.teleport)
		var d := pool.vel[slot] * (1.0 - _reflected_t[r]) * delta
		var wall_t := -1.0
		if pool.collide_world[slot] != 0 and d != Vector2.ZERO:
			wall_t = walls.first_hit(start, d, pool.radius[slot])
			if wall_t >= 0.0:
				d *= wall_t
		pool.prev_pos[slot] = start
		pool.pos[slot] = start + d
		var first := grid.hit_count
		var added := grid.sweep_segment(
			slot, start, d, pool.radius[slot], pool.hit_mask[slot], pool.last_hit[slot], pool.pierce[slot] + 1
		)
		last_hit_count += added
		for k in range(first, first + added):
			_apply_hit(slot, grid.hit_targets[k], grid.hit_t[k])
		if wall_t >= 0.0:
			pool.mark_dead(slot, BulletPool.DespawnReason.WALL)


func _collect_targets() -> void:
	grid.begin(pool.max_radius)
	var targets := Hurtbox.registry
	for k in targets.size():
		var hb := targets[k]
		if hb.active and hb.is_visible_in_tree():
			grid.add_circle(hb.global_position, hb.radius, hb.layer, hb)


func _apply_hit(bullet: int, target: int, t: float) -> void:
	# An earlier hit's hook may have killed this bullet in the meantime. (A bullet
	# that only left the world bounds this tick still counts its last segment.)
	var dead := pool.dead_reason[bullet]
	if dead != 0 and dead != BulletPool.DespawnReason.BOUNDS + 1:
		return
	var hurtbox := grid.target_ref[target] as Hurtbox
	if hurtbox == null or not is_instance_valid(hurtbox):
		return
	# The grid was built before this tick's hits were delivered: an earlier hit may
	# have switched the target off (i-frames, death). Such a bullet passes through
	# untouched instead of being consumed by an untouchable target.
	if not hurtbox.active:
		return
	var impact: Vector2 = pool.prev_pos[bullet].lerp(pool.pos[bullet], t)
	var piercing := pool.pierce[bullet] > 0
	if not piercing:
		# The bullet stops where it touched the target.
		pool.pos[bullet] = impact
	var flags := Health.SOURCE_PIERCES_SCRIPT_INVULN if pool.pierces_script_invuln[bullet] != 0 else 0
	hurtbox.receive_hit(pool.damage[bullet], impact, pool.vel[bullet], pool.id_of(bullet), flags)
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
