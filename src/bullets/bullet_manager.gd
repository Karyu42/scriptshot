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

## Physical size of the bullet pool: the memory that is allocated up front. The
## number of bullets the game actually allows is `logical_cap` (never more than this).
@export var capacity := 16384
## Saturation model, PROVISIONAL defaults (not decided by Karyu; configurable):
## the most bullets that may be alive at once, whoever owns them. A shot that
## would exceed it is dropped (observably, see ShotEmitter.get_dropped_count()).
## Clamped to `capacity`. Matches the 10,000-bullet performance target.
@export var logical_cap := 10000
## Slots of `logical_cap` that only enemy and boss bullets (owner_layer with
## Layers.ENEMY) may take, so player scripts can never starve enemy attacks.
## -1 (default) = 30% of the cap (3,000 with the default cap, so the player's share is at
## most 7,000, the pillars doc's B2 split). Player and
## unowned bullets can fill at most `logical_cap - enemy_reserve` slots in total.
@export var enemy_reserve := -1
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
## Hits that a can_hit() veto turned down in the last step.
var last_veto_count := 0
## Microseconds spent in each phase of the last step(), indexed by Phase.
var last_phase_usec := PackedInt32Array([0, 0, 0, 0, 0])

enum Phase { TARGETS_AND_ADVANCE, HOOKS_AND_WALLS, HURTBOXES, DESPAWN, RENDER }
## How many saturation warnings have been pushed (rate-limited; for tests/HUD).
var saturation_warnings_emitted := 0

var _renderer: BulletRenderer
var _behaviors: Array[BulletBehavior] = [null]
# Per behaviour id: the hooks its script overrides (BulletBehavior.HOOK_*) and the script that
# answer was worked out for. A behaviour whose script changes is re-detected on its next
# dispatch (see _hooks_of), so a cached mask cannot go stale.
var _hook_cache := PackedInt32Array([0])
var _hook_scripts: Array[Script] = [null]
var _declared_checked := PackedInt32Array([-2])
var _declared_scripts: Array[Script] = [null]
## How many times an explicit hook_mask was looked at against its script (tests).
var _declared_checks := 0
var _sim_time := 0.0
var _dropped_reported := 0
var _dropped_by_limit_reported := PackedInt32Array([0, 0])
var _dropped_by_owner_reported := PackedInt32Array([0, 0, 0])
var _last_warning_time := -INF
## Bullets reflected by a zone this tick (slots, and the fraction of the *whole
## tick* at which the reflection happened), plus a per-slot flag. They fly on after the mirror, see
## _continue_reflected(), and the wall hit of their old path no longer counts.
var _reflected_slots := PackedInt32Array()
var _reflected_t := PackedFloat32Array()
var _reflected_flag := PackedByteArray()
var _reflected_count := 0
## Per slot: the fraction of the tick's path a wall left to the bullet (1.0 = not
## clipped). Zone and hurtbox hit times are fractions of this clipped path;
## _try_reflect() needs them as fractions of the whole tick. Only slots that hit a
## wall this tick are non-1.0, and they are put back at the end of step().
var _wall_clip := PackedFloat32Array()
## Wall normal of a wall that stopped a reflected bullet's *return leg* this tick
## (see _continue_reflected()), per slot; Vector2.ZERO = none. wall_normal_of()
## reports it, as it does for the walls of walls.hit_*. Reset after the despawn hooks.
var _return_wall_normal := PackedVector2Array()
var _return_wall_hit := PackedByteArray()

## Per-slot index+1 into walls.hit_wall for bullets that hit a wall this tick
## (0 = none). Set after the wall sweep and cleared before removal; see
## wall_normal_of().
var _wall_hit_index := PackedInt32Array()

# The owner_layer of the bullet whose hook is running lives in `pool.hook_owner` (-1
# outside any hook). A spawn made while it is set is a child spawn and inherits it
# (see spawn()); the pool enforces the same rule for hooks that call it directly.


func _init() -> void:
	process_physics_priority = PHYSICS_PRIORITY


func _ready() -> void:
	pool = BulletPool.new(capacity)
	_reflected_slots.resize(capacity)
	_reflected_t.resize(capacity)
	_reflected_flag.resize(capacity)
	_wall_clip.resize(capacity)
	_wall_clip.fill(1.0)
	_return_wall_normal.resize(capacity)
	_return_wall_hit.resize(capacity)
	_wall_hit_index.resize(capacity)
	set_bullet_limits(logical_cap, enemy_reserve)
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


## Sets the saturation limits at runtime (see `logical_cap` / `enemy_reserve`;
## reserve -1 = 30% of the cap). The cap is clamped to the physical capacity and
## the reserve to the cap. Bullets already alive are never removed by this.
func set_bullet_limits(cap: int, reserve: int = -1) -> void:
	var effective_cap := clampi(cap, 0, pool.capacity)
	logical_cap = cap
	enemy_reserve = reserve
	@warning_ignore("integer_division")
	var auto_reserve := effective_cap * 3 / 10
	pool.set_limits(effective_cap, auto_reserve if reserve < 0 else reserve)


## Registers a behaviour and returns the id for ShotRequest.behavior_id.
func register_behavior(behavior: BulletBehavior) -> int:
	behavior.emitter = emitter
	_behaviors.append(behavior)
	_hook_cache.append(0)
	_hook_scripts.append(null)
	_declared_checked.append(-2)
	_declared_scripts.append(null)
	var id := _behaviors.size() - 1
	_refresh_hooks(id, behavior)
	return id


## Works out again which hooks behaviour `id` implements. Needed only after something
## changed the behaviour's methods in place without changing its script object (a script
## hot-reload); `set_script()` and a changed `hook_mask` are noticed on their own.
func refresh_behavior(id: int) -> void:
	var b := _get_behavior(id)
	if b == null:
		return
	_refresh_hooks(id, b)
	_declared_checked[id] = -2


func _refresh_hooks(id: int, b: BulletBehavior) -> void:
	_hook_scripts[id] = b.get_script()
	_hook_cache[id] = BulletBehavior.detect_hooks(b)


## The hooks of behaviour `id` that exist (BulletBehavior.HOOK_* bits). An explicit
## `hook_mask` wins; otherwise the detected mask, redone when the object's script is not
## the one it was detected for.
func _hooks_of(id: int, b: BulletBehavior) -> int:
	var declared := b.hook_mask
	if declared >= 0:
		declared &= BulletBehavior.HOOK_ALL
		# The debug check is keyed on the mask and the script: set_script() with the same
		# explicit mask must look at the new script's overrides too.
		var script: Script = b.get_script()
		if _declared_checked[id] != declared or _declared_scripts[id] != script:
			_declared_checked[id] = declared
			_declared_scripts[id] = script
			_declared_checks += 1
			if OS.is_debug_build() and not b.hook_mask_exact:
				var found := BulletBehavior.detect_hooks(b)
				assert(
					found & declared == found,
					"BulletBehavior.hook_mask %d leaves out an overridden hook (the script overrides %d)" % [declared, found]
				)
		return declared
	if b.get_script() != _hook_scripts[id]:
		_refresh_hooks(id, b)
	return _hook_cache[id]


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
## or -1 when the pool is full (or the request is invalid, see BulletPool.spawn).
##
## Called from inside a bullet hook (on_spawn / on_update / on_hit / on_despawn
## of a BulletBehavior), the new bullet is a child of the bullet whose hook runs
## and takes that bullet's `owner_layer`, whatever the request says: see
## spawn_child().
func spawn(request: ShotRequest) -> int:
	if pool.hook_owner >= 0:
		return _spawn_inheriting(pool.hook_owner, request, "BulletManager.spawn", "a hook")
	return _spawn_checked(request)


## Spawns a child of the live bullet with stable id `parent_id`, for spawn paths
## that run after the parent's hook returned (the batch/Lua commit resolves its
## `row` to the parent's id and calls this). The child inherits `owner_layer`
## from the parent; it never comes from the request, the behavior record or a
## script-passed field. If the request names another owner or team it is ignored
## and one capped warning is raised through ScriptWarnings. Returns the slot, or
## -1 if the parent is gone (a child without a parent has no owner to inherit,
## so it is refused) or the pool refused it.
func spawn_child(parent_id: int, request: ShotRequest) -> int:
	var parent := pool.slot_of(parent_id)
	if parent < 0:
		ScriptWarnings.warn(
			"BulletManager.spawn_child.parent", "BulletManager.spawn_child: the parent bullet is gone, child not spawned"
		)
		return -1
	return _spawn_inheriting(pool.owner_layer[parent], request, "BulletManager.spawn_child", "a child spawn")


## Spawn with `owner` forced onto the request. The ShotRequest is the caller's
## object and is handed back exactly as it was passed in.
##
## A request that still carries the default owner (Layers.PLAYER) cannot be told
## apart from "owner not set", so a mismatch there is corrected without a
## warning; any other differing owner is an explicit attempt and is warned.
## `where` and `who` only word the warning: a spawn from inside a hook says "a
## hook"; spawn_child() (the batch/Lua commit, which runs after the parent's hook
## returned) says "a child spawn" and names the parent, not a hook.
func _spawn_inheriting(owner: int, request: ShotRequest, where: String = "BulletManager.spawn", who: String = "a hook") -> int:
	var asked := request.owner_layer
	if asked == owner:
		return _spawn_checked(request)
	if asked != Layers.PLAYER:
		ScriptWarnings.warn(
			"BulletManager.spawn.owner",
			(
				"%s: %s asked for owner_layer %d but a bullet spawned from another bullet inherits that"
				+ " bullet's owner (%d); the request was ignored. Only reflect() changes an owner."
			) % [where, who, asked, owner]
		)
	var asked_mask := request.hit_mask
	request.owner_layer = owner
	# The default mask belongs to the requested team: use the standard "hostile to
	# the owner" mask of the inherited one (an unowned parent keeps the request's).
	if owner != 0:
		request.hit_mask = Layers.hostile_to(owner)
	var slot := _spawn_checked(request)
	request.owner_layer = asked
	request.hit_mask = asked_mask
	return slot


func _spawn_checked(request: ShotRequest) -> int:
	var i := pool.spawn(request)
	if i >= 0 and request.behavior_id != 0:
		var b := _get_behavior(request.behavior_id)
		if b == null:
			push_warning("BulletManager: unknown behavior_id %d, spawning a plain bullet" % request.behavior_id)
			pool.behavior[i] = 0
		else:
			var outer := pool.hook_owner
			var outer_slot := pool.hook_slot
			pool.hook_owner = pool.owner_layer[i]
			pool.hook_slot = i
			if _hooks_of(request.behavior_id, b) & BulletBehavior.HOOK_ON_SPAWN:
				b.on_spawn(pool, i)
				pool.hook_ran = true
			pool.hook_owner = outer
			pool.hook_slot = outer_slot
			pool.sanitize(i)
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
	# A hook that ran between two ticks (an on_spawn from the emitter) may have written into
	# any bullet: sweep before advance() moves them, so a speed over the ceiling does not
	# travel a tick first.
	if pool.hook_ran:
		pool.sweep_cross_writes()
	pool.advance(delta, world_bounds)
	var t1 := Time.get_ticks_usec()

	# Script hooks: only bullets that asked for them. A hook may have killed a
	# later bullet in the list already; dead bullets get no more updates.
	pool.run_update_hooks(_behaviors, delta)

	# A hook may have spawned a bullet bigger than any the targets were bucketed
	# for; re-bucket with the new margin so it does not miss targets by a hair.
	if pool.max_radius > grid.get_margin():
		_collect_targets()

	# Walls first: a bullet that hits one is clipped to the impact point, so the
	# hurtbox test below only sees the part of its path before the wall.
	last_veto_count = 0
	last_wall_hit_count = walls.sweep_bullets(pool)
	for k in last_wall_hit_count:
		var i := walls.hit_bullets[k]
		pool.pos[i] = pool.prev_pos[i].lerp(pool.pos[i], walls.hit_t[k])
		_wall_clip[i] = walls.hit_t[k]
		_wall_hit_index[i] = k + 1

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
	for k in last_wall_hit_count:
		_wall_clip[walls.hit_bullets[k]] = 1.0

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
			var outer := pool.hook_owner
			var outer_slot := pool.hook_slot
			pool.hook_owner = pool.owner_layer[slot]
			pool.hook_slot = slot
			var db := _get_behavior(id)
			if db != null and _hooks_of(id, db) & BulletBehavior.HOOK_ON_DESPAWN:
				db.on_despawn(pool, slot, pool.dead_reason[slot] - 1)
				pool.hook_ran = true
			pool.hook_owner = outer
			pool.hook_slot = outer_slot
	for k in last_wall_hit_count:
		_wall_hit_index[walls.hit_bullets[k]] = 0
	# The return-leg walls of this tick go with the despawn hooks (the reflected
	# list is kept until here for that).
	for r in _reflected_count:
		_return_wall_hit[_reflected_slots[r]] = 0
		_return_wall_normal[_reflected_slots[r]] = Vector2.ZERO
	_reflected_count = 0
	pool.flush_dead()
	# Hooks that ran after the sweep of this tick (on_spawn, can_hit, on_hit, on_despawn,
	# or an on_spawn between ticks) may have written into any bullet: sweep once more, now,
	# so nothing bad reaches the renderer below or the next tick. Skipped if nothing ran.
	if pool.hook_ran:
		pool.sweep_cross_writes()
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


## Surface normal (unit vector pointing out of the wall) of the wall that bullet
## `slot` hit this tick, or Vector2.ZERO if it did not hit one. Valid during this
## tick's despawn hooks (BulletBehavior.on_despawn with DespawnReason.WALL, also
## on_hit of a bullet that hit a wall in the same tick), not after removal.
## Slots are stable there unless a hook despawns bullets itself. See WallGrid.
func wall_normal_of(slot: int) -> Vector2:
	if slot < 0 or slot >= pool.count:
		return Vector2.ZERO
	var k := _wall_hit_index[slot]
	if k > 0:
		return walls.normal_of_hit(k - 1, pool)
	return _return_wall_normal[slot] if _return_wall_hit[slot] != 0 else Vector2.ZERO


## Removes all bullets (no hooks are called).
func clear_bullets() -> void:
	pool.clear()
	if _renderer != null:
		_renderer.update_from(pool)


## Emits ShotEmitter.pool_saturated if shots were dropped since the last tick,
## and pushes a warning at most once per saturation_warning_interval. The warning
## says which limit refused the shots and whose they were.
func _report_saturation() -> void:
	var dropped_now := pool.dropped_total - _dropped_reported
	if dropped_now <= 0:
		return
	_dropped_reported = pool.dropped_total
	var by_cap := pool.dropped_by_limit[BulletPool.DropLimit.LOGICAL_CAP] - _dropped_by_limit_reported[BulletPool.DropLimit.LOGICAL_CAP]
	var by_reserve := pool.dropped_by_limit[BulletPool.DropLimit.ENEMY_RESERVE] - _dropped_by_limit_reported[BulletPool.DropLimit.ENEMY_RESERVE]
	var by_player := pool.dropped_by_owner[BulletPool.OWNER_PLAYER] - _dropped_by_owner_reported[BulletPool.OWNER_PLAYER]
	var by_enemy := pool.dropped_by_owner[BulletPool.OWNER_ENEMY] - _dropped_by_owner_reported[BulletPool.OWNER_ENEMY]
	_dropped_by_limit_reported = pool.dropped_by_limit.duplicate()
	_dropped_by_owner_reported = pool.dropped_by_owner.duplicate()
	emitter.pool_saturated.emit(dropped_now, pool.dropped_total)
	if _sim_time - _last_warning_time >= saturation_warning_interval:
		_last_warning_time = _sim_time
		saturation_warnings_emitted += 1
		push_warning("BulletManager: bullet pool saturated (logical cap %d, enemy reserve %d, physical capacity %d); dropped %d shot(s) this tick: %d at the cap, %d by the enemy reserve; player %d, enemy %d, unowned %d. %d dropped in total. Fire fewer bullets, or raise BulletManager.logical_cap / capacity."
			% [pool.logical_cap, pool.enemy_reserve, pool.capacity, dropped_now, by_cap, by_reserve,
				by_player, by_enemy, dropped_now - by_player - by_enemy, pool.dropped_total])


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
	_reflected_t[_reflected_count] = t * _wall_clip[bullet]  # of the whole tick, not of the clipped path
	_reflected_count += 1
	_reflected_flag[bullet] = 1
	# The wall hit of the old path is cancelled: the bullet never got there, so no
	# hook may be told it hit that wall (wall_normal_of). A wall on the return leg
	# is recorded by _continue_reflected().
	_wall_hit_index[bullet] = 0
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
				_return_wall_normal[slot] = walls.last_normal
				_return_wall_hit[slot] = 1
		pool.prev_pos[slot] = start
		pool.pos[slot] = start + d
		var first := grid.hit_count
		# Like HurtboxGrid.collide_bullets(): a bullet whose hits can be vetoed lists
		# spare hits, so a vetoed target does not hide the next one on the return leg.
		var max_hits: int = pool.pierce[slot] + 1
		if pool.can_hit_veto[slot] != 0:
			max_hits += BulletPool.VETO_MAX_HITS - 1
		var added := grid.sweep_segment(
			pool, slot, start, d, pool.radius[slot], pool.hit_mask[slot], max_hits
		)
		last_hit_count += added
		for k in range(first, first + added):
			_apply_hit(slot, grid.hit_targets[k], grid.hit_t[k])
		if wall_t >= 0.0:
			if pool.dead_reason[slot] != 0:
				# A hurtbox (or a guard) ended the bullet before the wall: it never got
				# there, so no hook is told it hit that wall.
				_return_wall_hit[slot] = 0
				_return_wall_normal[slot] = Vector2.ZERO
			else:
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
	# Opt-in veto (ShotRequest.can_hit_veto): asked before any damage or pierce
	# bookkeeping. Unflagged bullets only pay for this one byte read per hit.
	var checked := false
	if pool.can_hit_veto[bullet] != 0:
		var veto_id := pool.behavior[bullet]
		if veto_id != 0:
			# A hook like the others: whatever it spawns inherits this bullet's owner.
			var outer := pool.hook_owner
			var outer_slot := pool.hook_slot
			pool.hook_owner = pool.owner_layer[bullet]
			pool.hook_slot = bullet
			var allowed := true
			var vb := _get_behavior(veto_id)
			if vb != null and _hooks_of(veto_id, vb) & BulletBehavior.HOOK_CAN_HIT:
				allowed = vb.can_hit(pool, bullet, hurtbox)
				pool.hook_ran = true
			pool.hook_owner = outer
			pool.hook_slot = outer_slot
			# can_hit has the pool in its hands too: hold the same guards as for the
			# other hooks. A bullet it wrote a NaN into is gone, and lands no hit.
			if not pool.sanitize(bullet):
				return
			checked = true
			if not allowed:
				last_veto_count += 1
				return
	# Every other bullet is checked once here, before its damage or velocity is read:
	# a hook may have written into this bullet's fields from another bullet's hook
	# (BulletPool.sweep_cross_writes covers position, previous position, velocity and
	# rotation, not radius or damage), and a NaN damage would reach Health.
	if not checked and not pool.sanitize(bullet):
		return
	var impact: Vector2 = pool.prev_pos[bullet].lerp(pool.pos[bullet], t)
	var piercing := pool.pierce[bullet] > 0
	if not piercing:
		# The bullet stops where it touched the target.
		pool.pos[bullet] = impact
		# A reflected bullet that this hit consumes does not reach the wall at the end
		# of its return leg (on_hit already must not report it).
		_return_wall_hit[bullet] = 0
	var flags := Health.SOURCE_PIERCES_SCRIPT_INVULN if pool.pierces_script_invuln[bullet] != 0 else 0
	hurtbox.receive_hit(pool.damage[bullet], impact, pool.vel[bullet], pool.id_of(bullet), flags)
	var id := pool.behavior[bullet]
	if id != 0:
		var outer := pool.hook_owner
		var outer_slot := pool.hook_slot
		pool.hook_owner = pool.owner_layer[bullet]
		pool.hook_slot = bullet
		var hb := _get_behavior(id)
		if hb != null and _hooks_of(id, hb) & BulletBehavior.HOOK_ON_HIT:
			hb.on_hit(pool, bullet, hurtbox)
			pool.hook_ran = true
		pool.hook_owner = outer
		pool.hook_slot = outer_slot
		pool.sanitize(bullet)
	if piercing:
		# Recorded here, not during the sweep: a veto or an inactive target returns
		# before this, and a bullet with no pierce left is despawned instead.
		# The same tick's other hits are already excluded by HurtboxGrid._excl;
		# this is what the next tick seeds that list from.
		pool.remember_target(bullet, hurtbox.get_instance_id())
		pool.pierce[bullet] -= 1
	else:
		pool.mark_dead(bullet, BulletPool.DespawnReason.HIT)
		pool.claim_from_bounds(bullet, BulletPool.DespawnReason.HIT)


func _get_behavior(id: int) -> BulletBehavior:
	return _behaviors[id] if id > 0 and id < _behaviors.size() else null
