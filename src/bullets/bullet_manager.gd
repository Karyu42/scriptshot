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
## Managers currently in a tree. Reflector enter/exit notifies each of them.
## Node2D, not BulletManager: a static Array of this class cannot be parsed
## while the class is still being compiled.
static var _managers: Array[Node2D] = []

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
## The open world recentres this same rectangle on the camera (see
## bounds_center); it does not grow. Tests and the benchmark leave
## bounds_center null and keep whatever rect they set.
@export var world_bounds := Rect2(-1312, -752, 2624, 1504)
## When set, step() recentres world_bounds on this node without changing its
## size. A Camera2D contributes its screen centre (look-ahead and shake
## included). Null keeps the rect where it is.
var bounds_center: Node2D
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
## "native" when the C++ NativeBulletSim simulates hook-free bullets, otherwise
## "gdscript" (everything in `pool`). Chosen in _ready(); see backend_preference.
var backend := "gdscript"
## Which backend to use. "gdscript" (the default) keeps every bullet in the pool,
## including when the project setting or SCRIPTSHOT_BULLET_BACKEND says native:
## tests and a scene that did not opt in do not move because the library loaded.
## "native" sends hook-free bullets to NativeBulletSim when the extension is
## loaded, and falls back to GDScript (one warning) when it is not. "auto"
## follows, in order, `--bullet-backend=`, SCRIPTSHOT_BULLET_BACKEND, then the
## project setting `scriptshot/bullets/backend`. Unset stays on GDScript.
## Set before _ready. The main scene and the benchmark use "auto".
@export_enum("auto", "gdscript", "native") var backend_preference := "gdscript"
var native: NativeBackend

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
var _native_renderer: NativeBulletRenderer
# Hurtbox snapshot handed to the native sim each tick.
var _nt_pos := PackedVector2Array()
var _nt_radius := PackedFloat32Array()
var _nt_layer := PackedInt32Array()
var _nt_ids := PackedInt64Array()
var _behaviors: Array[BulletBehavior] = [null]
# Per behaviour id: the hooks its script overrides (BulletBehavior.HOOK_*) and the script that
# answer was worked out for. A behaviour whose script changes is re-detected on its next
# dispatch (see _hooks_of), so a cached mask cannot go stale.
var _hook_cache := PackedInt32Array([0])
var _hook_scripts: Array[Script] = [null]
var _declared_checked := PackedInt32Array([-2])
var _declared_scripts: Array[Script] = [null]
## 1 when that behaviour's script overrides on_update. Refreshed with the event
## mask. on_update is not a hook_mask bit; an override still keeps the bullet
## on the GDScript pool.
var _update_override := PackedByteArray([0])
## Behavior ids that are batch-only (no per-bullet hook). Rebuilt when hooks change.
var _batch_only_ids: Array[int] = []
var _batch_ids_dirty := true
## > 0 while a batch hook runs. Spawns in that window stay on the pool, the same
## rule as a spawn from on_update: the native step would otherwise move a child
## born this tick.
var _batch_depth := 0
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
## Reflectors currently registered. Hook-free bullets stay in the native sim
## and reflect there. The count still updates immediately, including from a hit
## callback: a zone that appears during delivery is not in this tick's sweep.
var _reflector_count := 0
## Delta of the step in progress. Return legs fly for the unused fraction of it.
var _step_delta := 0.0
## True from the start of step() until the native move has been applied. Script
## reflect_bullet() on a native id in that window is queued and run after the
## move, before collision. Outside the window it applies immediately.
var _defer_native_reflect := false
var _native_reflect_queue: Array[Dictionary] = []
## Accepted script reflects not yet written, per native id. The next call in
## the same tick sees them, the way BulletPool.reflect sees its own count.
var _native_reflect_pending := {}
## Active zones this tick, same order as the native zone sweep and the pool grid.
var _native_zones: Array[Reflector] = []
var _nz_pos := PackedVector2Array()
var _nz_radius := PackedFloat32Array()
var _nz_owner := PackedInt32Array()
## Bullets reflected this tick, pool and native, in the order they turned.
## Walked once after every bullet's old path has been resolved.
var _ret_native := PackedByteArray()
var _ret_slot := PackedInt32Array()
var _ret_t := PackedFloat32Array()
var _ret_count := 0
## Next unified slot index. Seqs of live bullets are {0 .. _order_count - 1}.
var _order_count := 0

# The owner_layer of the bullet whose hook is running lives in `pool.hook_owner` (-1
# outside any hook). A spawn made while it is set is a child spawn and inherits it
# (see spawn()); the pool enforces the same rule for hooks that call it directly.


func _init() -> void:
	process_physics_priority = PHYSICS_PRIORITY


func _enter_tree() -> void:
	if not _managers.has(self):
		_managers.append(self)
	# Reflectors that entered earlier already updated the registry. Later ones
	# notify. Snapshot so neither is missed and neither is counted twice.
	_reflector_count = Reflector.registry.size()


func _exit_tree() -> void:
	_managers.erase(self)


static func notify_reflectors(delta: int) -> void:
	for node in _managers:
		var manager := node as BulletManager
		if manager != null:
			manager._reflectors_changed(delta)


func _reflectors_changed(delta: int) -> void:
	_reflector_count = maxi(_reflector_count + delta, 0)


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
	if native != null:
		native.set_limits(pool.logical_cap, pool.enemy_reserve)


## Registers a behaviour and returns the id for ShotRequest.behavior_id.
func register_behavior(behavior: BulletBehavior) -> int:
	behavior.emitter = emitter
	_behaviors.append(behavior)
	_hook_cache.append(0)
	_hook_scripts.append(null)
	_declared_checked.append(-2)
	_declared_scripts.append(null)
	_update_override.append(0)
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
	_update_override[id] = 1 if BulletBehavior.overrides_on_update(b) else 0
	_sync_batch_routing(id)


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
			add_wall(shape_node.global_transform * Rect2(-rect_shape.size * 0.5, rect_shape.size))
			added += 1
	return added


## Spawns a bullet from a request and runs its on_spawn hook. Returns the pool
## slot, or a native id, or -1 when the shot is refused (full, or invalid; see
## BulletPool.spawn).
##
## Called from inside a bullet hook (on_spawn / on_update / on_hit / on_despawn
## of a BulletBehavior), the new bullet is a child of the bullet whose hook runs
## and takes that bullet's `owner_layer`, whatever the request says: see
## spawn_child(). Those spawns, and spawn_child(), stay in the GDScript pool.
## The native step runs later in the same tick, so a child born during a hook
## would move a tick early if it were handed to the sim. Owner inheritance
## already lives on the pool. Design call, reversible once native grows a
## "born this tick" bit.
##
## A hook-free bullet spawned outside a hook goes to NativeBulletSim when native
## is selected: behavior_id 0, or a behaviour whose mask calls nothing and whose
## script does not override on_update (declarative kinematics, including a
## batch-only behaviour). Any unmasked event hook, or an on_update override,
## stays in the pool. spawn() then returns that bullet's stable native id
## (bit 62 set), not a pool slot. Only >= 0 means the spawn succeeded.
func spawn(request: ShotRequest) -> int:
	if pool.hook_owner >= 0:
		return _spawn_inheriting(pool.hook_owner, request, "BulletManager.spawn", "a hook")
	# A batch hook is not one bullet, so there is no single owner to inherit.
	# The spawn still stays on the pool: native integrate has already run, and
	# a child handed to the sim would be swept this tick. spawn_child(row)
	# inherits that row's owner; a direct spawn() keeps the request's owner.
	if _batch_depth > 0:
		return _spawn_checked(request)
	if _wants_native(request):
		return _spawn_native(request)
	return _spawn_checked(request)


## True when this request should be simulated in C++. Hook context is handled
## by spawn() before this is asked.
func _wants_native(request: ShotRequest) -> bool:
	# Reflectors do not pull hook-free bullets back. The sim reflects them.
	# A per-bullet hook, including can_hit, still stays on the pool.
	return native != null and not _has_per_bullet_hooks(request.behavior_id)


## True when the behaviour would actually run a per-bullet hook. An unknown id
## is a plain bullet (the same warning the pool path raises).
func _has_per_bullet_hooks(behavior_id: int) -> bool:
	if behavior_id == 0:
		return false
	var b := _get_behavior(behavior_id)
	if b == null:
		push_warning("BulletManager: unknown behavior_id %d, spawning a plain bullet" % behavior_id)
		return false
	if _hooks_of(behavior_id, b) != 0:
		return true
	if b.get_script() != _hook_scripts[behavior_id]:
		_refresh_hooks(behavior_id, b)
	return _update_override[behavior_id] != 0


## True when this behaviour's only scripted update is the batch hook.
## Those bullets live in the native sim when native is selected. A per-bullet
## hook (event mask or on_update) keeps them on the pool instead.
func _is_batch_only(behavior_id: int) -> bool:
	var b := _get_behavior(behavior_id)
	if b == null or b.update_mode == BulletBehavior.UpdateMode.PER_BULLET:
		return false
	if _has_per_bullet_hooks(behavior_id):
		return false
	return _wants_batch_callback(b)


## True when the batch callback should run for this behaviour.
## AUTO does not run it on top of on_update (that would steer twice).
## An explicit BATCH does, over whichever store holds the bullets.
func _wants_batch_callback(b: BulletBehavior) -> bool:
	if b.update_mode == BulletBehavior.UpdateMode.PER_BULLET:
		return false
	if b.update_mode == BulletBehavior.UpdateMode.BATCH:
		return true
	return BulletBehavior.overrides_on_update_batch(b)


func _sync_batch_routing(id: int) -> void:
	if pool != null:
		pool.set_batch_only(id, _is_batch_only(id))
	_batch_ids_dirty = true


func _ensure_batch_ids() -> void:
	if not _batch_ids_dirty:
		return
	_batch_only_ids.clear()
	for id in range(1, _behaviors.size()):
		if _is_batch_only(id):
			_batch_only_ids.append(id)
	_batch_ids_dirty = false


func _has_live_native_batch() -> bool:
	if native == null:
		return false
	_ensure_batch_ids()
	for id in _batch_only_ids:
		if native.count_with_behavior(id) > 0:
			return true
	return false


func _spawn_native(request: ShotRequest) -> int:
	var seq := _alloc_order()
	native.set_external_count(pool.count)
	var id := native.spawn(request, seq)
	if id < 0:
		_rollback_order(seq)
	else:
		_sync_pool_external()
	return id


func _sync_pool_external() -> void:
	pool.external_count = native.count() if native != null else 0


func _alloc_order() -> int:
	var assigned := _order_count
	_order_count += 1
	return assigned


func _rollback_order(assigned: int) -> void:
	if assigned == _order_count - 1:
		_order_count -= 1


func _assign_pool_seq(i: int) -> void:
	pool.seq[i] = _alloc_order()


func _retire_pool_bullet(i: int) -> void:
	# Hooked runs keep every bullet in the pool. The tail is the last slot, so
	# the rewrite is one write; the scan is only for a mixed store.
	if native == null or native.count() == 0:
		_retire_local(pool.seq[i], pool.count - 1, false, i)
		return
	_retire_seq(pool.seq[i])


func _retire_native_seq(removed: int) -> void:
	if pool.count == 0:
		_retire_local(removed, native.count() - 1, true, -1)
		return
	_retire_seq(removed)


## Single-store swap-remove. `removed` is that bullet's seq. The tail is the
## last slot; stamping it here lets the store's copy land the tail in the hole.
func _retire_local(removed: int, last: int, native_tail: bool, pool_slot: int) -> void:
	if _order_count <= 1:
		_order_count = 0
		return
	var tail := _order_count - 1
	_order_count -= 1
	if removed == tail or last < 0:
		return
	if native_tail:
		native.set_seq_at(last, removed)
	elif pool_slot != last:
		pool.seq[last] = removed


## Unified swap-remove: the bullet that holds the highest seq takes the seq of
## the one that just left, matching BulletPool's move-last-into-the-hole.
func _retire_seq(removed: int) -> void:
	if _order_count <= 1:
		_order_count = 0
		return
	var tail := _order_count - 1
	_order_count -= 1
	if removed == tail:
		return
	if native != null:
		var slot := native.find_seq(tail)
		if slot >= 0:
			native.set_seq_at(slot, removed)
			return
	for i in pool.count:
		if pool.seq[i] == removed:
			continue
		if pool.seq[i] == tail:
			pool.seq[i] = removed
			return


func _on_pool_cleared() -> void:
	if native == null or native.count() == 0:
		_order_count = 0


## Pool hits and native hits, in ascending seq, ties broken by the order the
## candidates were recorded (path order within one bullet).
func _apply_hits_by_seq(pool_hits: int) -> void:
	var native_seqs := native.pending_hit_seqs()
	var total := pool_hits + native_seqs.size()
	var seqs := PackedInt32Array()
	var kind := PackedByteArray()
	var index := PackedInt32Array()
	seqs.resize(total)
	kind.resize(total)
	index.resize(total)
	for k in pool_hits:
		seqs[k] = pool.seq[grid.hit_bullets[k]]
		kind[k] = 0
		index[k] = k
	for k in native_seqs.size():
		var at := pool_hits + k
		seqs[at] = native_seqs[k]
		kind[at] = 1
		index[at] = k
	var order := _argsort_stable(seqs)
	for n in order.size():
		var at: int = order[n]
		if kind[at] == 0:
			var k: int = index[at]
			_apply_hit(grid.hit_bullets[k], grid.hit_targets[k], grid.hit_t[k])
		else:
			native.commit_pending_hit(index[at])


func _argsort_stable(keys: PackedInt32Array) -> PackedInt32Array:
	var order := PackedInt32Array()
	order.resize(keys.size())
	for i in keys.size():
		order[i] = i
	for i in range(1, order.size()):
		var key := order[i]
		var j := i - 1
		while j >= 0:
			var earlier: int = order[j]
			var out_of_order := keys[earlier] > keys[key] or (keys[earlier] == keys[key] and earlier > key)
			if not out_of_order:
				break
			order[j + 1] = earlier
			j -= 1
		order[j + 1] = key
	return order


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
	_sync_pool_external()
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
##
## On a native id during step(), before that sim has moved, the call is queued
## and applied after the move (before collision) so this tick's travel stays on
## the pre-reflect velocity. The bool is the one BulletPool.reflect would return
## at this moment on the GDScript pool. Outside that window the change is immediate.
func reflect(
	id: int,
	new_owner_layer: int,
	reverse: bool = false,
	new_damage: float = BulletPool.REFLECTED_DAMAGE,
	keep_script: bool = false
) -> bool:
	if is_native_id(id):
		return _reflect_native(id, new_owner_layer, reverse, new_damage, keep_script)
	if not pool.is_alive(id):
		return false
	return pool.reflect(pool.slot_of(id), new_owner_layer, reverse, new_damage, keep_script)


func _reflect_native(
	id: int,
	new_owner_layer: int,
	reverse: bool,
	new_damage: float,
	keep_script: bool
) -> bool:
	if native == null or not native.is_alive(id):
		return false
	if new_owner_layer != Layers.PLAYER and new_owner_layer != Layers.ENEMY:
		return false
	var limit := pool.max_reflections
	if _defer_native_reflect:
		# advance() has already killed a GD bullet that expires or leaves the
		# world this tick, and on_update sees that. The sim has not moved yet.
		if native.integrate_would_die(id, _step_delta):
			return false
		var already: int = _native_reflect_pending.get(id, 0)
		var count := native.reflect_count_of(id)
		if limit > 0 and count + already >= limit:
			return false
		_native_reflect_queue.append({
			"id": id,
			"owner": new_owner_layer,
			"reverse": reverse,
			"damage": new_damage,
			"keep": keep_script,
			"limit": limit,
		})
		_native_reflect_pending[id] = already + 1
		return true
	return native.apply_script_reflect(
		id, new_owner_layer, Layers.hostile_to(new_owner_layer), Layers.bullet_color(new_owner_layer),
		new_damage, keep_script, reverse, limit
	)


func _flush_native_reflects() -> void:
	if _native_reflect_queue.is_empty() or native == null:
		_native_reflect_queue.clear()
		_native_reflect_pending.clear()
		return
	var queued: Array[Dictionary] = []
	queued.assign(_native_reflect_queue)
	_native_reflect_queue.clear()
	_native_reflect_pending.clear()
	for op: Dictionary in queued:
		var owner: int = op["owner"]
		var bullet_id: int = op["id"]
		var damage: float = op["damage"]
		var keep: bool = op["keep"]
		var reverse: bool = op["reverse"]
		var limit: int = op["limit"]
		# Stale generation, or a bullet that died in the move, is a no-op.
		native.apply_script_reflect(
			bullet_id, owner, Layers.hostile_to(owner), Layers.bullet_color(owner),
			damage, keep, reverse, limit
		)


## Packed copy of one behaviour's live bullets. Batch-only behaviours are read
## from the native sim when it is selected, and from the pool otherwise
## (including every batch bullet on the GDScript backend).
func gather_batch(behavior_id: int, delta: float) -> BatchView:
	var view := BatchView.new()
	view.dt = delta
	# Batch-only bullets spawned outside a hook are native. Ones spawned from a
	# hook stayed on the pool; they are appended so the callback still sees them.
	if _is_batch_only(behavior_id) and native != null:
		_fill_native_batch(view, behavior_id)
		view.native_rows = view.n
	_append_pool_batch(view, behavior_id)
	view.native = view.native_rows > 0 and view.native_rows == view.n
	return view


## Applies a view from gather_batch. Column writes first, then commands in the
## order the callback recorded them. A stale id is skipped.
func commit_batch(view: BatchView) -> void:
	if view == null or view.discard or view.n == 0 and view.command_count() == 0:
		return
	if view.native_rows > 0 and native != null:
		native.apply_batch(view.id, view.vx, view.vy, view.pa, view.pb)
	if view.n > view.native_rows:
		_commit_pool_columns(view)
	_commit_batch_commands(view)


func _append_pool_batch(view: BatchView, behavior_id: int) -> void:
	var extra := 0
	for i in pool.count:
		if pool.dead_reason[i] == 0 and pool.behavior[i] == behavior_id:
			extra += 1
	if extra == 0:
		return
	var base := view.n
	var n := base + extra
	view.id.resize(n)
	view.px.resize(n)
	view.py.resize(n)
	view.vx.resize(n)
	view.vy.resize(n)
	view.age.resize(n)
	view.pa.resize(n)
	view.pb.resize(n)
	view.owner.resize(n)
	var w := base
	for i in pool.count:
		if pool.dead_reason[i] != 0 or pool.behavior[i] != behavior_id:
			continue
		view.id[w] = pool.id_of(i)
		var p := pool.pos[i]
		var v := pool.vel[i]
		view.px[w] = p.x
		view.py[w] = p.y
		view.vx[w] = v.x
		view.vy[w] = v.y
		view.age[w] = pool.age[i]
		view.pa[w] = pool.param_a[i]
		view.pb[w] = pool.param_b[i]
		view.owner[w] = pool.owner_layer[i]
		w += 1
	view.n = n


func _fill_native_batch(view: BatchView, behavior_id: int) -> void:
	var d := native.gather_batch(behavior_id)
	var count: int = d["n"]
	view.n = count
	view.id = d["id"]
	view.px = d["px"]
	view.py = d["py"]
	view.vx = d["vx"]
	view.vy = d["vy"]
	view.age = d["age"]
	view.pa = d["pa"]
	view.pb = d["pb"]
	view.owner = d["owner"]


func _commit_pool_columns(view: BatchView) -> void:
	var rows := mini(view.n, view.id.size())
	for i in rows:
		var bullet_id := view.id[i]
		var slot := pool.slot_of(bullet_id)
		if slot < 0 or pool.dead_reason[slot] != 0 or pool.id_of(slot) != bullet_id:
			continue
		if i >= view.vx.size() or i >= view.vy.size():
			break
		# set_velocity clamps, and a non-finite value kills as INVALID.
		if not pool.set_velocity(slot, Vector2(view.vx[i], view.vy[i])):
			continue
		if i >= view.pa.size() or i >= view.pb.size():
			continue
		pool.param_a[slot] = view.pa[i]
		pool.param_b[slot] = view.pb[i]
		pool.sanitize(slot)


func _commit_batch_commands(view: BatchView) -> void:
	var killed := PackedByteArray()
	killed.resize(view.n)
	for c in view.command_count():
		var row := view.command_row(c)
		var op := view.command_op(c)
		if op != BatchView.CMD_SPAWN and row >= 0 and row < killed.size() and killed[row] != 0:
			continue
		var bullet_id := -1
		if row >= 0 and row < view.id.size():
			bullet_id = view.id[row]
		match op:
			BatchView.CMD_KILL:
				if _batch_kill(view, bullet_id) and row >= 0 and row < killed.size():
					killed[row] = 1
			BatchView.CMD_TELEPORT:
				_batch_teleport(view, bullet_id, view.command_x(c), view.command_y(c))
			BatchView.CMD_SPAWN:
				# A kill earlier in this callback does not drop the child. The
				# owner was copied at gather. A reused id does.
				if row >= 0 and (row >= view.n or not _batch_id_current(bullet_id)):
					continue
				var request := view.spawn_request(c)
				if request == null:
					continue
				_batch_spawn(view, row, request)


func _batch_id_current(bullet_id: int) -> bool:
	if bullet_id <= 0:
		return false
	if native != null and (bullet_id & NativeBackend.ID_FLAG) != 0:
		return native.has_id(bullet_id)
	var slot := pool.slot_of(bullet_id)
	return slot >= 0 and pool.id_of(slot) == bullet_id


func _batch_kill(view: BatchView, bullet_id: int) -> bool:
	if native != null and (bullet_id & NativeBackend.ID_FLAG) != 0:
		return native.kill(bullet_id)
	var slot := pool.slot_of(bullet_id)
	if slot < 0 or pool.dead_reason[slot] != 0 or pool.id_of(slot) != bullet_id:
		return false
	pool.mark_dead(slot, BulletPool.DespawnReason.MANUAL)
	return true


func _batch_teleport(view: BatchView, bullet_id: int, x: float, y: float) -> void:
	if native != null and (bullet_id & NativeBackend.ID_FLAG) != 0:
		native.teleport_id(bullet_id, x, y)
		return
	var slot := pool.slot_of(bullet_id)
	if slot < 0 or pool.dead_reason[slot] != 0 or pool.id_of(slot) != bullet_id:
		return
	if not is_finite(x + y):
		pool.invalid_total += 1
		ScriptWarnings.warn("BatchView.teleport", "BatchView.teleport: a non-finite position, the bullet was removed (DespawnReason.INVALID)")
		pool.vel[slot] = Vector2.ZERO
		pool.mark_dead(slot, BulletPool.DespawnReason.INVALID)
		return
	pool.teleport(slot, Vector2(x, y))


func _batch_spawn(view: BatchView, row: int, request: ShotRequest) -> void:
	if row >= 0 and row < view.owner.size():
		var owner: int = view.owner[row]
		var outer := pool.hook_owner
		pool.hook_owner = owner
		_spawn_inheriting(owner, request, "BatchView.spawn_child", "a batch hook")
		pool.hook_owner = outer
		return
	_spawn_checked(request)


func _run_batch_hooks(delta: float) -> void:
	_batch_depth += 1
	for id in range(1, _behaviors.size()):
		var b := _behaviors[id]
		if b == null or not _wants_batch_callback(b):
			continue
		# AUTO batch on a per-bullet behaviour is not invoked (see _wants_batch_callback).
		if b.update_mode != BulletBehavior.UpdateMode.BATCH and _has_per_bullet_hooks(id):
			continue
		var view := gather_batch(id, delta)
		if view.n == 0:
			continue
		if view.native_rows < view.n:
			pool.hook_ran = true
		b.on_update_batch(view)
		if not view.discard:
			commit_batch(view)
	_batch_depth -= 1


## Advances the whole bullet simulation by `delta` seconds.
func step(delta: float) -> void:
	# Hook-free bullets stay in the native sim when reflectors are registered.
	# A zone that appears in on_update is in this tick's sweep (zones are
	# collected after the hooks). One that appears during hit delivery is not.
	_step_delta = delta
	_defer_native_reflect = native != null
	_follow_bounds()
	var t0 := Time.get_ticks_usec()

	_collect_targets()
	# A hook that ran between two ticks (an on_spawn from the emitter) may have written into
	# any bullet: sweep before advance() moves them, so a speed over the ceiling does not
	# travel a tick first.
	if pool.hook_ran:
		pool.sweep_cross_writes()
	pool.advance(delta, world_bounds)
	# on_update runs after the pool integrate and before native movement, matching
	# the all-GD order (BulletPool.advance, then hooks, then collision). A mirror
	# registered here is visible to the zone sweep below; native bullets take
	# their integrate in the sim, not as a second pool step.
	var t1 := Time.get_ticks_usec()

	# Script hooks: only bullets that asked for them. A hook may have killed a
	# later bullet in the list already; dead bullets get no more updates.
	pool.run_update_hooks(_behaviors, delta)

	# Batch-only native bullets integrate here, before the batch callback and
	# before pool collision, so the callback sees the post-move position and a
	# child it spawns is still in this tick's pool sweep. The write itself is
	# applied before native.collide(), which is the same window as a deferred
	# script reflect: after the move, before the sweeps. No live batch bullet
	# keeps the single native.step() pass below.
	var native_batch := _has_live_native_batch()
	if native_batch:
		native.integrate(delta)
		_flush_native_reflects()
		_defer_native_reflect = false
	_run_batch_hooks(delta)

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
	# Integrate native bullets before any hit is delivered, so both stores'
	# candidates exist and can be applied in one seq order. With no native
	# bullets this is the all-GD path below, unchanged.
	var native_queued := 0
	var stepped_native := false
	var native_zone_hits := 0
	if native != null and native.count() > 0:
		# No queued script reflect and no batch integrate: one pass, same as before.
		# A queued reflect is applied after the move and before the sweeps, which
		# is where on_update sits on the GDScript pool. A batch integrate already
		# happened above; collide() is the rest of that tick.
		if native_batch:
			native_queued = native.collide()
		elif _native_reflect_queue.is_empty():
			native_queued = native.step(delta)
		else:
			native.integrate(delta)
			_flush_native_reflects()
			native_queued = native.collide()
		stepped_native = true
		native_zone_hits = native.zone_hit_count()
	else:
		_flush_native_reflects()
	_defer_native_reflect = false
	if zone_hits == 0 and native_zone_hits == 0:
		# stepped_native: both stores may hold bullets, so pool slot order is not
		# the all-GD order. Seq is that order. No native bullets: the old loop.
		if stepped_native:
			_apply_hits_by_seq(last_hit_count)
		else:
			for k in last_hit_count:
				_apply_hit(grid.hit_bullets[k], grid.hit_targets[k], grid.hit_t[k])
	elif stepped_native:
		_resolve_mixed(zone_hits, delta)
		native_queued += native.return_hit_count()
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

	# Native walls and compaction. Hits were committed above, in seq order with
	# the pool, so a callback spawn is still not swept until next tick.
	var native_wall_hits := 0
	if stepped_native:
		native.finish_delivery()
		native_wall_hits = native.last_wall_hit_count()
		_sync_pool_external()
	last_hit_count += native_queued
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
	# Wall normals were readable through the despawn hooks above. Drop them
	# before the step returns, same window as the pool's wall_hit index.
	if native != null:
		native.clear_wall_normals()
	var t4 := Time.get_ticks_usec()

	_sim_time += delta
	_report_saturation()

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


## Slides world_bounds so it is centred on `center`, keeping the current size.
## Rebuilds the hurtbox, reflector and wall grids (GDScript and, when selected,
## the native sim) to match, and moves the renderer AABBs. Bullets are not
## moved; the next step despawns whatever is now outside the window.
func recenter_world_bounds(center: Vector2) -> void:
	if pool == null or grid == null or walls == null or reflector_grid == null:
		return
	var size := world_bounds.size
	var next := Rect2(center - size * 0.5, size)
	if next.is_equal_approx(world_bounds):
		return
	world_bounds = next
	grid.setup(world_bounds, cell_size)
	reflector_grid.setup(world_bounds, cell_size)
	walls.set_bounds(world_bounds)
	if _renderer != null:
		_renderer.set_world_bounds(world_bounds)
	if _native_renderer != null:
		_native_renderer.set_world_bounds(world_bounds)
	if native != null:
		native.set_bounds(world_bounds)


func _follow_bounds() -> void:
	if bounds_center == null:
		return
	var center := bounds_center.global_position
	if bounds_center is Camera2D:
		center = (bounds_center as Camera2D).get_screen_center_position()
	recenter_world_bounds(center)


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
	_native_reflect_queue.clear()
	_native_reflect_pending.clear()
	pool.clear()
	if _renderer != null:
		_renderer.update_from(pool)
	if native != null:
		native.clear()
		_sync_pool_external()
		if _native_renderer != null:
			_native_renderer.update_from(native)
	_order_count = 0


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
		wanted = NativeBackend.opted_backend()
	# Explicit "gdscript", or "auto" that resolved to it: the pool only.
	if wanted != "native":
		backend = "gdscript"
		return
	if not NativeBackend.is_available():
		NativeBackend.warn_missing()
		backend = "gdscript"
		return
	native = NativeBackend.new(capacity, world_bounds, cell_size)
	native.set_limits(pool.logical_cap, pool.enemy_reserve)
	pool.alloc_order = _assign_pool_seq
	pool.retire_order = _retire_pool_bullet
	pool.store_cleared = _on_pool_cleared
	native.set_retire_callback(_retire_native_seq)
	backend = "native"


## Live bullets in both stores. The saturation cap is on this total.
func _live_total() -> int:
	return pool.count + (native.count() if native != null else 0)


func _room_for(layer: int) -> bool:
	return _live_total() < pool.limit_for(layer)


func _at_logical_cap() -> bool:
	return _live_total() >= pool.logical_cap


func dropped_total_all() -> int:
	return pool.dropped_total + (native.dropped_total() if native != null else 0)


func dropped_by_owner_all(layer: int) -> int:
	var n := pool.dropped_for(layer)
	if native != null:
		n += native.dropped_for(layer)
	return n


func dropped_by_limit_all(limit: int) -> int:
	var n := pool.dropped_by_limit[limit] if limit >= 0 and limit < pool.dropped_by_limit.size() else 0
	if native != null:
		n += native.dropped_by_limit(limit)
	return n


func owner_count_all(layer: int) -> int:
	var n := pool.owner_count(layer)
	if native != null:
		n += native.owner_count(layer)
	return n


func is_saturated_for(layer: int) -> bool:
	return not _room_for(layer)


func headroom_for(layer: int) -> int:
	return maxi(pool.limit_for(layer) - _live_total(), 0)


## True for an id minted by NativeBulletSim (not a pool slot or pool id).
func is_native_id(id: int) -> bool:
	return native != null and id > 0 and (id & NativeBackend.ID_FLAG) != 0


## Emits ShotEmitter.pool_saturated if shots were dropped since the last tick,
## and pushes a warning at most once per saturation_warning_interval. The warning
## says which limit refused the shots and whose they were.
func _report_saturation() -> void:
	var total := dropped_total_all()
	var dropped_now := total - _dropped_reported
	if dropped_now <= 0:
		return
	_dropped_reported = total
	var cap_now := dropped_by_limit_all(BulletPool.DropLimit.LOGICAL_CAP)
	var reserve_now := dropped_by_limit_all(BulletPool.DropLimit.ENEMY_RESERVE)
	var player_now := dropped_by_owner_all(Layers.PLAYER)
	var enemy_now := dropped_by_owner_all(Layers.ENEMY)
	var by_cap := cap_now - _dropped_by_limit_reported[BulletPool.DropLimit.LOGICAL_CAP]
	var by_reserve := reserve_now - _dropped_by_limit_reported[BulletPool.DropLimit.ENEMY_RESERVE]
	var by_player := player_now - _dropped_by_owner_reported[BulletPool.OWNER_PLAYER]
	var by_enemy := enemy_now - _dropped_by_owner_reported[BulletPool.OWNER_ENEMY]
	_dropped_by_limit_reported[BulletPool.DropLimit.LOGICAL_CAP] = cap_now
	_dropped_by_limit_reported[BulletPool.DropLimit.ENEMY_RESERVE] = reserve_now
	_dropped_by_owner_reported[BulletPool.OWNER_PLAYER] = player_now
	_dropped_by_owner_reported[BulletPool.OWNER_ENEMY] = enemy_now
	emitter.pool_saturated.emit(dropped_now, total)
	if _sim_time - _last_warning_time >= saturation_warning_interval:
		_last_warning_time = _sim_time
		saturation_warnings_emitted += 1
		push_warning("BulletManager: bullet pool saturated (logical cap %d, enemy reserve %d, physical capacity %d); dropped %d shot(s) this tick: %d at the cap, %d by the enemy reserve; player %d, enemy %d, unowned %d. %d dropped in total. Fire fewer bullets, or raise BulletManager.logical_cap / capacity."
			% [pool.logical_cap, pool.enemy_reserve, pool.capacity, dropped_now, by_cap, by_reserve,
				by_player, by_enemy, dropped_now - by_player - by_enemy, total])


## One swept pass over the bullets against every active Reflector zone. Fills
## reflector_grid's hit list (per bullet, in path order, up to
## HurtboxGrid.MAX_ZONE_HITS zones) and returns its length; nothing is reflected
## yet (see _resolve_hits_in_time_order()). Costs nothing while no zone exists.
func _collect_zone_hits() -> int:
	last_reflect_count = 0
	_reflected_count = 0
	_ret_count = 0
	_native_zones.clear()
	for zone in Reflector.registry:
		if zone.is_active():
			_native_zones.append(zone)
	if native != null:
		var n := _native_zones.size()
		if _nz_pos.size() < n:
			_nz_pos.resize(n)
			_nz_radius.resize(n)
			_nz_owner.resize(n)
		for i in n:
			var zone := _native_zones[i]
			_nz_pos[i] = zone.global_position
			_nz_radius[i] = zone.radius
			_nz_owner[i] = zone.reflects_owners
		native.set_zones(_nz_pos, _nz_radius, _nz_owner, n)
	if _native_zones.is_empty():
		return 0
	reflector_grid.begin(pool.max_radius)
	for zone in _native_zones:
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


## Pool and native hits, including reflector crossings, in shared seq order.
## Within one bullet, time along the clipped path; a zone wins a tie. A reflection
## ends that bullet's old path. Return legs then run in the order the bullets turned.
func _resolve_mixed(zone_hits: int, delta: float) -> void:
	var nseq := native.pending_hit_seqs()
	var nt := native.pending_hit_t()
	var zseq := native.zone_hit_seqs()
	var zt := native.zone_hit_t()
	var zslot := native.zone_hit_slots()
	var zzone := native.zone_hit_zones()
	var total := last_hit_count + zone_hits + nseq.size() + zseq.size()
	var seqs := PackedInt32Array()
	var ts := PackedFloat32Array()
	var kind := PackedByteArray()
	var store := PackedByteArray()
	var index := PackedInt32Array()
	seqs.resize(total)
	ts.resize(total)
	kind.resize(total)
	store.resize(total)
	index.resize(total)
	var at := 0
	for k in last_hit_count:
		seqs[at] = pool.seq[grid.hit_bullets[k]]
		ts[at] = grid.hit_t[k]
		kind[at] = 1
		store[at] = 0
		index[at] = k
		at += 1
	for k in zone_hits:
		seqs[at] = pool.seq[reflector_grid.hit_bullets[k]]
		ts[at] = reflector_grid.hit_t[k]
		kind[at] = 0
		store[at] = 0
		index[at] = k
		at += 1
	for k in nseq.size():
		seqs[at] = nseq[k]
		ts[at] = nt[k]
		kind[at] = 1
		store[at] = 1
		index[at] = k
		at += 1
	for k in zseq.size():
		seqs[at] = zseq[k]
		ts[at] = zt[k]
		kind[at] = 0
		store[at] = 1
		index[at] = k
		at += 1
	var order := PackedInt32Array()
	order.resize(total)
	for i in total:
		order[i] = i
	for i in range(1, total):
		var key := order[i]
		var j := i - 1
		while j >= 0:
			var earlier: int = order[j]
			var later := false
			if seqs[earlier] != seqs[key]:
				later = seqs[earlier] > seqs[key]
			elif ts[earlier] != ts[key]:
				later = ts[earlier] > ts[key]
			elif kind[earlier] != kind[key]:
				later = kind[earlier] > kind[key]
			else:
				later = earlier > key
			if not later:
				break
			order[j + 1] = earlier
			j -= 1
		order[j + 1] = key
	var skip := false
	var skip_seq := 0
	for n in order.size():
		var ev: int = order[n]
		var seq: int = seqs[ev]
		if skip and seq == skip_seq:
			continue
		skip = false
		var reflected := false
		if kind[ev] == 0:
			if store[ev] == 0:
				var bullet: int = reflector_grid.hit_bullets[index[ev]]
				reflected = _try_reflect(bullet, index[ev])
				if reflected:
					_note_return(0, bullet, _reflected_t[_reflected_count - 1])
			else:
				reflected = _try_reflect_native(zslot[index[ev]], zzone[index[ev]], zt[index[ev]])
		elif store[ev] == 0:
			var k: int = index[ev]
			_apply_hit(grid.hit_bullets[k], grid.hit_targets[k], grid.hit_t[k])
		else:
			native.commit_pending_hit(index[ev])
		if reflected:
			skip = true
			skip_seq = seq
	for r in _ret_count:
		if _ret_native[r] != 0:
			var slot := _ret_slot[r]
			var first := native.return_hit_count()
			native.begin_return(slot, delta, _ret_t[r])
			var last := native.return_hit_count()
			for h in range(first, last):
				native.commit_return_hit(h)
			native.finish_return(slot)
		else:
			_continue_one(_ret_slot[r], _ret_t[r], delta)


func _note_return(is_native: int, slot: int, reflected_t: float) -> void:
	if _ret_count >= _ret_slot.size():
		var n := maxi(_ret_count * 2, 8)
		_ret_native.resize(n)
		_ret_slot.resize(n)
		_ret_t.resize(n)
	_ret_native[_ret_count] = is_native
	_ret_slot[_ret_count] = slot
	_ret_t[_ret_count] = reflected_t
	_ret_count += 1


func _try_reflect_native(slot: int, zone_index: int, t: float) -> bool:
	if zone_index < 0 or zone_index >= _native_zones.size() or not native.is_slot_alive(slot):
		return false
	var zone := _native_zones[zone_index]
	if zone == null or not is_instance_valid(zone):
		return false
	var impact := native.previous_at(slot).lerp(native.position_at(slot), t)
	var cap := zone.effective_limit(pool)
	var decision := zone.evaluate(native.owner_at(slot), native.velocity_at(slot), native.reflect_count_at(slot), impact, cap)
	if not decision.ok:
		return false
	var new_owner: int = decision.new_owner
	var heading: Vector2 = decision.heading
	var speed: float = decision.speed
	var new_damage: float = decision.damage
	var keep: bool = decision.keep_script
	if not native.apply_reflect(slot, new_owner, Layers.hostile_to(new_owner), Layers.bullet_color(new_owner), new_damage, keep, cap, heading, speed, impact):
		return false
	native.cancel_outbound_wall(slot)
	_note_return(1, slot, t * native.wall_clip_at(slot))
	last_reflect_count += 1
	zone.reflected_total += 1
	zone.bullet_reflected.emit(native.id_of_slot(slot), new_owner)
	return true


## Lets every bullet reflected this tick fly on from its impact point along its new
## velocity for the rest of the tick (the part after the reflection, `(1 - t) *
## delta`), against walls and against the hurtboxes of its *new* side, in time
## order like any other bullet. `prev_pos` is the impact point and `pos` the end of
## that part (clipped at a wall), so the renderer interpolates the new leg only.
## A bullet is reflected at most once per tick, so zones are not consulted again.
func _continue_reflected(delta: float) -> void:
	for r in _reflected_count:
		_continue_one(_reflected_slots[r], _reflected_t[r], delta)


func _continue_one(slot: int, reflected_t: float, delta: float) -> void:
	if slot < 0 or slot >= pool.count or pool.dead_reason[slot] != 0:
		return
	var start := pool.pos[slot]  # the impact point (BulletPool.teleport)
	var d := pool.vel[slot] * (1.0 - reflected_t) * delta
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
	var use_native := native != null
	var n := 0
	if use_native and _nt_pos.size() < targets.size():
		_nt_pos.resize(targets.size())
		_nt_radius.resize(targets.size())
		_nt_layer.resize(targets.size())
		_nt_ids.resize(targets.size())
	for k in targets.size():
		var hb := targets[k]
		if hb.active and hb.is_visible_in_tree():
			var center := hb.global_position
			grid.add_circle(center, hb.radius, hb.layer, hb)
			if use_native:
				_nt_pos[n] = center
				_nt_radius[n] = hb.radius
				_nt_layer[n] = hb.layer
				_nt_ids[n] = hb.get_instance_id()
				n += 1
	if use_native:
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
		# later ticks skip these ids when a candidate actually touches the path.
		pool.remember_target(bullet, hurtbox.get_instance_id())
		pool.pierce[bullet] -= 1
	else:
		pool.mark_dead(bullet, BulletPool.DespawnReason.HIT)
		pool.claim_from_bounds(bullet, BulletPool.DespawnReason.HIT)


func _get_behavior(id: int) -> BulletBehavior:
	return _behaviors[id] if id > 0 and id < _behaviors.size() else null
