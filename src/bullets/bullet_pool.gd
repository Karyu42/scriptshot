class_name BulletPool
extends RefCounted
## Data-oriented bullet storage: struct-of-arrays, fixed capacity, no per-bullet
## objects. Alive bullets always occupy the dense range [0, count); despawning
## swaps the last bullet into the freed slot, so slots are recycled without
## any allocation and iteration never touches dead data.
##
## The pool owns kinematics (advance) and slot management only. Rendering,
## collision and hooks live in BulletManager / HurtboxGrid / BulletRenderer so
## each can be tested and optimised on its own.
##
## Stable handles: slots move when bullets despawn, so every bullet also gets
## an *id* that stays valid for exactly its lifetime. An id packs
## (generation << 32) | handle, where `handle` indexes an indirection table
## (handle -> current slot) and `generation` is bumped each time a handle is
## released. Stale ids (bullet gone, handle possibly reused) are detected by
## slot_of() / is_alive(). Ids are always > 0; -1 means "no bullet".
##
## Performance note: the hot loop writes to the pool's own member arrays. Do
## not cache them in a local variable before writing (GDScript copies a packed
## array on the first write when another reference exists). Reading through a
## local alias is fine.

## Why a bullet was removed (passed to BulletBehavior.on_despawn). New reasons are
## only ever appended, so existing values stay stable.
##
## INVALID: the bullet was killed because a script wrote a non-finite value (NaN or
## infinity) into its state; the Lua batch API uses it so such kills can be told
## apart from a deliberate MANUAL despawn.
enum DespawnReason { LIFETIME, BOUNDS, HIT, MANUAL, CLEARED, WALL, INVALID }

## Which limit refused a shot (see "Saturation model"). Used to index
## `dropped_by_limit`.
enum DropLimit {
	## The pool already holds `logical_cap` bullets.
	LOGICAL_CAP,
	## The pool still has room, but the remaining slots are the enemy reserve and
	## the shooter is not an enemy.
	ENEMY_RESERVE,
}

## Owner slots of the per-owner counters (see owner_slot()).
const OWNER_NONE := 0
const OWNER_PLAYER := 1
const OWNER_ENEMY := 2
const OWNER_SLOTS := 3

# Local copies of the BulletLimits bounds (the hot paths below compare against them).
const MAX_SPEED_SQ := BulletLimits.MAX_SPEED_SQ
const MAX_RADIUS := BulletLimits.MAX_RADIUS
const MAX_LIFETIME := BulletLimits.MAX_LIFETIME
const MAX_ACCELERATION := BulletLimits.MAX_ACCELERATION
const MAX_TURN_RATE := BulletLimits.MAX_TURN_RATE
const MAX_DAMAGE := BulletLimits.MAX_DAMAGE
## advance() accepts a bullet whose time left (lifetime - age) is in (0, MAX_LIFETIME):
## the same 600 s that spawn clamps a lifetime to. LIFE_LEFT_HALF is the middle of that band.
const LIFE_LEFT_HALF := MAX_LIFETIME * 0.5

## Flagged-bullet sweeps list up to this many hits per tick so that a vetoed hit
## does not hide the next target on the path (see can_hit_veto).
const VETO_MAX_HITS := 4
## How many recent hurtboxes a piercing bullet remembers so it does not hit them
## again on later ticks (see hit_mem). 8 covers a clump of overlapping targets;
## an older one can be hit again once it falls out of the ring.
const HIT_MEMORY := 8

# --- saturation model ---------------------------------------------------------
# PROVISIONAL (not decided by Karyu): the pool refuses a shot when
#   * the pool already holds `logical_cap` bullets, whoever shoots, or
#   * the shooter is not an enemy/boss and the pool already holds
#     `logical_cap - enemy_reserve` bullets.
# So the last `enemy_reserve` slots of the logical cap can only ever be taken by
# enemy and boss bullets (owner_layer with Layers.ENEMY): player scripts cannot
# starve enemy attacks however many bullets they spawn. The cap is independent
# of the physical `capacity` (it can only be lower). BulletManager configures
# both; a bare BulletPool defaults to cap = capacity, reserve = 0 (no reserve).
# Use set_limits(); do not write these two directly.
var logical_cap := 0
var enemy_reserve := 0
## Highest total a non-enemy shooter may bring the pool to (logical_cap - reserve).
var _other_limit := 0
## Bullets living in the other backend. Added to `count` for the admission check
## so the two stores share one cap. 0 when native is off, which keeps this
## pool's own test unchanged. BulletManager keeps it current.
var external_count := 0


## Maximum number of simultaneously alive bullets the *memory* holds. Fixed at
## construction. The number of bullets the game allows is `logical_cap` (see
## "Saturation model" below), which can be lower.
var capacity := 0
## Number of alive bullets. Valid slots are [0, count).
var count := 0
## Largest radius ever spawned; HurtboxGrid uses it to size target margins.
var max_radius := 0.0
## Lifetime statistics.
var spawned_total := 0
var dropped_total := 0
## Shots rejected at spawn plus bullets killed (INVALID) because a script wrote a
## NaN or inf. Not part of `dropped_total` (that one is about capacity).
var invalid_total := 0
## Bullets occupying a slot per owner (OWNER_NONE / OWNER_PLAYER / OWNER_ENEMY),
## including ones marked dead but not yet flushed (they still hold their slot).
## Kept in step by spawn, despawn, swap-remove, reflect() (an owner change moves
## the count) and clear(). Read through owner_count(). Changing `owner_layer[i]`
## directly bypasses the counters; use reflect(), or call recount_owners().
var owner_counts := PackedInt32Array([0, 0, 0])
## Shots refused since creation, by the shooter's owner slot and by the limit
## that refused them (DropLimit). Both sum to `dropped_total`.
var dropped_by_owner := PackedInt32Array([0, 0, 0])
var dropped_by_limit := PackedInt32Array([0, 0])
## Bullets removed, by DespawnReason. Not reset by clear() (statistics, like
## spawned_total). An immediate despawn() of a live slot has no reason and is
## not counted. The native sim keeps the same array for reasons 0..5.
var despawn_counts := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
## When set, advance() clears these and _remove_at appends each removal in
## flush order (reason, lifetime). Tests compare the two backends. Off in play
## so the hot path does not touch them.
var log_despawns := false
var despawn_log_reason := PackedInt32Array()
var despawn_log_life := PackedFloat32Array()
## Unified slot index shared with NativeBulletSim. BulletManager sets it when
## the native backend is on, so a mixed tick can deliver hits in all-GD order.
## Unused while the callback is unset (GDScript-only managers).
var seq := PackedInt32Array()
## Called with the new slot after a successful spawn. Manager assigns `seq`.
var alloc_order: Callable
## Called with the slot about to be removed, before its fields are overwritten.
var retire_order: Callable
## Called after clear() drops every slot without a per-bullet retire.
var store_cleared: Callable
## How many alive bullets carry the can_hit_veto flag (lets the collision loop
## skip the per-bullet check entirely while there are none).
var veto_count := 0
## owner_layer of the bullet whose hook is running right now, -1 outside any hook.
## BulletManager sets it around every hook call. While it is set, every spawn
## (spawn() and spawn_simple(), also when a hook calls the pool directly) takes
## this owner, never the one the request names: only reflect() changes an owner.
var hook_owner := -1
## Slot of the bullet whose hook is running right now, -1 outside any hook (set
## together with `hook_owner`). A hook that reflects its own bullet hands the rest of
## the hook the new owner: see reflect().
var hook_slot := -1
## How many times sweep_cross_writes() has run (diagnostics and tests: a tick in which
## nothing flagged the pool must not add to it).
var sweeps_run := 0
## True once any hook (on_spawn, on_update, can_hit, on_hit, on_despawn) ran since the
## last sweep_cross_writes(): BulletManager sets it after every hook it calls (a hook the
## behaviour does not override is not called, see BulletBehavior.hook_mask; run_update_hooks()
## does it for on_update) and only sweep_cross_writes() clears it. See there for the soundness
## argument that lets advance() skip the clock checks.
var hook_ran := false

# --- struct-of-arrays bullet data (all sized to capacity) -------------------
var pos := PackedVector2Array()
## Position at the start of the current tick (where the bullet was before
## advance() moved it). The segment prev_pos -> pos is what swept collision
## tests, and what the renderer interpolates between.
var prev_pos := PackedVector2Array()
var vel := PackedVector2Array()
## Unit vector for visual orientation.
var rot := PackedVector2Array()
var radius := PackedFloat32Array()
var age := PackedFloat32Array()
var lifetime := PackedFloat32Array()
var accel := PackedFloat32Array()
var turn_rate := PackedFloat32Array()
var damage := PackedFloat32Array()
var param_a := PackedFloat32Array()
var param_b := PackedFloat32Array()
var color := PackedColorArray()
var hit_mask := PackedInt32Array()
## Faction that fired the bullet (Layers.PLAYER or Layers.ENEMY; 0 = unowned,
## e.g. spawn_simple). A bullet never hits its own faction: spawn() strips the
## owner's layer from hit_mask, and reflect() re-derives hit_mask for the new
## owner. See ShotRequest.owner_layer.
var owner_layer := PackedInt32Array()
## How many times the bullet has changed owner through reflect() (saturates at
## 255). Reflectors use it as their reflect-once guard against ping-pong.
var reflect_count := PackedByteArray()
## 1 = the bullet ignores the player's *script* invulnerability (not engine
## i-frames); see ShotRequest.pierces_script_invuln and Health.try_damage().
var pierces_script_invuln := PackedByteArray()
## 1 = the bullet's behaviour is asked BulletBehavior.can_hit() before each hit
## lands (see ShotRequest.can_hit_veto). Ignored for bullets without a behaviour.
var can_hit_veto := PackedByteArray()
var behavior := PackedInt32Array()
var pierce := PackedInt32Array()
## 1 = collides with the `world` layer (walls), 0 = flies through walls.
var collide_world := PackedByteArray()
## Recent hurtbox instance ids a bullet has actually pierced, HIT_MEMORY per
## slot laid out flat (`slot * HIT_MEMORY + 0 .. hit_mem_count[slot] - 1`, and
## the whole window once the ring is full). Replaces the old one-slot last_hit:
## a bullet overlapping several targets must not spend a pierce on each of them
## every tick. Count 0 means "nothing remembered" — plain bullets stay there and
## the collision loop does not read the window. Written only when a pierce hit
## lands (`pierce` was still > 0): a veto, an inactive target, or the hit that
## despawns a bullet with no pierce left does not record anything.
var hit_mem := PackedInt64Array()
## How many entries in this slot's window are live (0 .. HIT_MEMORY).
var hit_mem_count := PackedByteArray()
## Next slot to overwrite once the ring is full. Unused while count < HIT_MEMORY
## (those entries are the packed prefix [0, count)).
var hit_mem_head := PackedByteArray()
## 0 = alive; otherwise DespawnReason + 1 (pending removal in flush_dead()).
var dead_reason := PackedByteArray()
## Free-form per-bullet script state (ShotRequest.user), parallel to the other
## arrays: moved on swap-remove, reset to null when the bullet despawns.
var user: Array = []

# --- handle indirection ------------------------------------------------------
const HANDLE_BITS := 32
const HANDLE_MASK := (1 << HANDLE_BITS) - 1
const GENERATION_MASK := 0x7FFFFFFF
## handle -> current slot (-1 while the handle is free).
var _slot_of_handle := PackedInt32Array()
## handle -> generation of the bullet that currently owns it / will own it next.
var _generation := PackedInt32Array()
## slot -> handle, parallel to the bullet arrays.
var _handle_of_slot := PackedInt32Array()
## Stack of free handles; _free_count entries are valid.
var _free_handles := PackedInt32Array()
var _free_count := 0

# --- per-tick work lists ----------------------------------------------------
## Slots marked dead this tick, in marking order (see flush_dead()).
var pending := PackedInt32Array()
var pending_count := 0
## Slots of alive bullets with behavior != 0, filled by advance().
## Batch-only behaviors are left out: they are one callback, not one call per bullet.
var hooked := PackedInt32Array()
var hooked_count := 0
## 1 at a behavior id whose bullets skip the per-bullet on_update list.
var batch_only := PackedByteArray()
## False when no behavior is batch-only, so advance() does not touch batch_only.
var any_batch_only := false


## Marks behavior `id` as batch-only (its bullets are not listed for on_update).
func set_batch_only(id: int, on: bool) -> void:
	if id < 0:
		return
	if batch_only.size() <= id:
		batch_only.resize(id + 1)
	batch_only[id] = 1 if on else 0
	any_batch_only = false
	for flag in batch_only:
		if flag != 0:
			any_batch_only = true
			return


func _init(p_capacity: int = 16384) -> void:
	assert(p_capacity > 0, "BulletPool capacity must be positive")
	capacity = p_capacity
	logical_cap = capacity
	_other_limit = capacity
	pos.resize(capacity)
	prev_pos.resize(capacity)
	vel.resize(capacity)
	rot.resize(capacity)
	radius.resize(capacity)
	age.resize(capacity)
	lifetime.resize(capacity)
	accel.resize(capacity)
	turn_rate.resize(capacity)
	damage.resize(capacity)
	param_a.resize(capacity)
	param_b.resize(capacity)
	color.resize(capacity)
	hit_mask.resize(capacity)
	owner_layer.resize(capacity)
	reflect_count.resize(capacity)
	pierces_script_invuln.resize(capacity)
	can_hit_veto.resize(capacity)
	behavior.resize(capacity)
	pierce.resize(capacity)
	collide_world.resize(capacity)
	hit_mem.resize(capacity * HIT_MEMORY)
	hit_mem_count.resize(capacity)
	hit_mem_head.resize(capacity)
	seq.resize(capacity)
	dead_reason.resize(capacity)
	pending.resize(capacity)
	hooked.resize(capacity)
	user.resize(capacity)
	_slot_of_handle.resize(capacity)
	_generation.resize(capacity)
	_handle_of_slot.resize(capacity)
	_free_handles.resize(capacity)
	_reset_handles()


## Spawns a bullet from a ShotRequest. Returns its slot, or -1 if the pool is
## full. The slot is only stable until the next despawn.
func spawn(request: ShotRequest) -> int:
	var bad := _bad_request_field(request)
	if bad != "":
		_reject_invalid("BulletPool.spawn", "a shot with a non-finite %s" % bad)
		return -1
	var shot_owner := request.owner_layer
	var shot_mask := request.hit_mask
	if hook_owner >= 0 and shot_owner != hook_owner:
		# Backstop for a hook that calls the pool directly (BulletManager.spawn
		# already corrects its requests before they get here).
		if shot_owner != Layers.PLAYER:
			ScriptWarnings.warn(
				"BulletPool.spawn.owner",
				(
					"BulletPool.spawn: a shot with owner_layer %d was spawned while the hook of a bullet owned by %d was"
					+ " running (the request itself, or the parent named in spawn_child(), asked for %d); a bullet spawned"
					+ " during a hook takes the owner of the bullet whose hook runs, so it was spawned as %d."
					+ " Only reflect() changes an owner."
				) % [shot_owner, hook_owner, shot_owner, hook_owner]
			)
		shot_owner = hook_owner
		if shot_owner != 0:
			shot_mask = Layers.hostile_to(shot_owner)
	var owner_slot_i := owner_slot(shot_owner)
	if not _admit(owner_slot_i):
		return -1
	owner_counts[owner_slot_i] += 1
	var i := count
	count += 1
	spawned_total += 1
	_assign_handle(i)
	user[i] = request.user
	pos[i] = request.position
	prev_pos[i] = request.position
	# Every field is read from the request once: the clamped value is stored, and
	# compared with what was asked to tell whether anything had to be clamped.
	var asked_velocity := request.velocity
	var velocity := BulletLimits.clamp_velocity(asked_velocity)
	vel[i] = velocity
	if is_nan(request.angle):
		var speed := velocity.length()
		rot[i] = velocity / speed if speed > 0.0 else Vector2.RIGHT
	else:
		rot[i] = Vector2.from_angle(request.angle)
	var asked_r := request.radius
	var r := clampf(asked_r, 0.0, BulletLimits.MAX_RADIUS)
	radius[i] = r
	age[i] = 0.0
	var asked_life := request.lifetime
	var life := clampf(asked_life, 0.0, BulletLimits.MAX_LIFETIME)
	lifetime[i] = life
	var asked_acc := request.acceleration
	var acc := clampf(asked_acc, -BulletLimits.MAX_ACCELERATION, BulletLimits.MAX_ACCELERATION)
	accel[i] = acc
	var asked_turn := request.turn_rate
	var turn := clampf(asked_turn, -BulletLimits.MAX_TURN_RATE, BulletLimits.MAX_TURN_RATE)
	turn_rate[i] = turn
	var asked_dmg := request.damage
	var dmg := clampf(asked_dmg, 0.0, BulletLimits.MAX_DAMAGE)
	damage[i] = dmg
	var asked_pa := request.param_a
	var pa := clampf(asked_pa, -BulletLimits.MAX_PARAM, BulletLimits.MAX_PARAM)
	param_a[i] = pa
	var asked_pb := request.param_b
	var pb := clampf(asked_pb, -BulletLimits.MAX_PARAM, BulletLimits.MAX_PARAM)
	param_b[i] = pb
	# Nothing clamped (the normal case) costs eight compares. Otherwise say so, once
	# per field and rate-limited (a clamp used to be silent).
	if (
		velocity != asked_velocity
		or r != asked_r
		or life != asked_life
		or acc != asked_acc
		or turn != asked_turn
		or dmg != asked_dmg
		or pa != asked_pa
		or pb != asked_pb
	):
		_warn_clamped_request("BulletPool.spawn", request)
	color[i] = request.color
	owner_layer[i] = shot_owner
	reflect_count[i] = 0
	pierces_script_invuln[i] = 1 if request.pierces_script_invuln else 0
	if request.can_hit_veto:
		can_hit_veto[i] = 1
		veto_count += 1
	else:
		can_hit_veto[i] = 0
	hit_mask[i] = shot_mask & ~shot_owner
	behavior[i] = request.behavior_id
	pierce[i] = request.pierce
	collide_world[i] = 1 if request.collide_world else 0
	clear_hit_memory(i)
	dead_reason[i] = 0
	if r > max_radius:
		max_radius = r
	_stamp_seq(i)
	return i


## Allocation-free spawn for plain bullets (no hooks, acceleration or pierce).
func spawn_simple(
	position: Vector2,
	velocity: Vector2,
	life: float,
	bullet_radius: float = 4.0,
	bullet_color: Color = Color(1.0, 0.82, 0.4),
	mask: int = 0
) -> int:
	if not (position.is_finite() and velocity.is_finite() and is_finite(life) and is_finite(bullet_radius)):
		_reject_invalid("BulletPool.spawn_simple", "a shot with a non-finite position, velocity, life or radius")
		return -1
	var asked_velocity := velocity
	var asked_life := life
	var asked_radius := bullet_radius
	life = clampf(life, 0.0, BulletLimits.MAX_LIFETIME)
	bullet_radius = clampf(bullet_radius, 0.0, BulletLimits.MAX_RADIUS)
	velocity = BulletLimits.clamp_velocity(velocity)
	if velocity != asked_velocity or life != asked_life or bullet_radius != asked_radius:
		_warn_clamped_fields("BulletPool.spawn_simple", asked_velocity, asked_radius, asked_life)
	# A plain bullet is unowned, except when a hook spawns it: then it belongs to
	# the bullet whose hook runs, like every other bullet spawned from a hook.
	var shot_owner := hook_owner if hook_owner > 0 else 0
	var owner_slot_i := owner_slot(shot_owner)
	if not _admit(owner_slot_i):
		return -1
	owner_counts[owner_slot_i] += 1
	var i := count
	count += 1
	spawned_total += 1
	_assign_handle(i)
	user[i] = null
	pos[i] = position
	prev_pos[i] = position
	vel[i] = velocity
	var speed := velocity.length()
	rot[i] = velocity / speed if speed > 0.0 else Vector2.RIGHT
	radius[i] = bullet_radius
	age[i] = 0.0
	lifetime[i] = life
	accel[i] = 0.0
	turn_rate[i] = 0.0
	damage[i] = 1.0
	param_a[i] = 0.0
	param_b[i] = 0.0
	color[i] = bullet_color
	owner_layer[i] = shot_owner
	reflect_count[i] = 0
	pierces_script_invuln[i] = 0
	can_hit_veto[i] = 0
	hit_mask[i] = mask & ~shot_owner
	behavior[i] = 0
	pierce[i] = 0
	collide_world[i] = 1
	clear_hit_memory(i)
	dead_reason[i] = 0
	if bullet_radius > max_radius:
		max_radius = bullet_radius
	_stamp_seq(i)
	return i


## Integrates every alive bullet by `delta` seconds and marks bullets whose
## lifetime ran out or that left `bounds` as dead (they are removed by
## flush_dead(), which lets the manager run hooks first). Also rebuilds the
## `hooked` list.
func advance(delta: float, bounds: Rect2) -> void:
	if log_despawns:
		despawn_log_reason.clear()
		despawn_log_life.clear()
	var min_x := bounds.position.x
	var min_y := bounds.position.y
	var max_x := bounds.end.x
	var max_y := bounds.end.y
	var n := count
	hooked_count = 0
	for i in n:
		if dead_reason[i] != 0:
			continue
		prev_pos[i] = pos[i]
		var a := age[i] + delta
		age[i] = a
		# `not a < life` rather than `a >= life`: the same cost, but a NaN age or lifetime
		# (which a hook can only write between two sweeps, see sweep_cross_writes()) ends
		# the bullet instead of keeping it for ever. The rest of the clock (+/-inf, a
		# lifetime over MAX_LIFETIME, an age far below zero) is checked by the sweeps, not here:
		# a plain bullet's tick pays nothing for it.
		if not a < lifetime[i]:
			mark_dead(i, DespawnReason.LIFETIME)
			continue
		var v := vel[i]
		var turn := turn_rate[i]
		var acc := accel[i]
		if turn != 0.0 or acc != 0.0:
			if turn != 0.0:
				v = v.rotated(turn * delta)
				rot[i] = rot[i].rotated(turn * delta)
			if acc != 0.0:
				var speed := v.length()
				if speed > 0.0:
					v *= clampf(speed + acc * delta, 0.0, BulletLimits.MAX_SPEED) / speed
			vel[i] = v
		var p := pos[i] + v * delta
		pos[i] = p
		# Written so that a NaN position (from a NaN velocity, acceleration or turn rate
		# a hook put into a bullet it does not own) fails the test too, no extra work.
		if not (p.x >= min_x and p.x <= max_x and p.y >= min_y and p.y <= max_y):
			if p.is_finite():
				mark_dead(i, DespawnReason.BOUNDS)
			else:
				_kill_invalid(i, "BulletPool.hook_write", "a non-finite value written to pos, vel, accel or turn_rate")
			continue
		var bid := behavior[i]
		if bid != 0 and (not any_batch_only or bid >= batch_only.size() or batch_only[bid] == 0):
			hooked[hooked_count] = i
			hooked_count += 1


## One bullet's integrate, the body of advance() for a single slot. Used when a
## mirror registered in on_update pulls native bullets into the pool after
## advance() has already walked the old count: those bullets still need this
## tick's step, and only this one. Does not touch the hooked list (a migrated
## bullet is hook-free; the list was built for the bullets that already advanced).
func advance_one(i: int, delta: float, bounds: Rect2) -> void:
	if i < 0 or i >= count or dead_reason[i] != 0:
		return
	var min_x := bounds.position.x
	var min_y := bounds.position.y
	var max_x := bounds.end.x
	var max_y := bounds.end.y
	prev_pos[i] = pos[i]
	var a := age[i] + delta
	age[i] = a
	if not a < lifetime[i]:
		mark_dead(i, DespawnReason.LIFETIME)
		return
	var v := vel[i]
	var turn := turn_rate[i]
	var acc := accel[i]
	if turn != 0.0 or acc != 0.0:
		if turn != 0.0:
			v = v.rotated(turn * delta)
			rot[i] = rot[i].rotated(turn * delta)
		if acc != 0.0:
			var speed := v.length()
			if speed > 0.0:
				v *= clampf(speed + acc * delta, 0.0, BulletLimits.MAX_SPEED) / speed
		vel[i] = v
	var p := pos[i] + v * delta
	pos[i] = p
	if not (p.x >= min_x and p.x <= max_x and p.y >= min_y and p.y <= max_y):
		if p.is_finite():
			mark_dead(i, DespawnReason.BOUNDS)
		else:
			_kill_invalid(i, "BulletPool.hook_write", "a non-finite value written to pos, vel, accel or turn_rate")
## (alive and still scripted when its turn comes), and re-checks each one right after
## its hook returned (sanitize()). `behaviors` is BulletManager's behaviour table,
## indexed by behavior id.
##
## This is the hot loop of every scripted bullet, so it lives in the pool: member
## reads and the sanitize call are cheaper from inside the class than through
## `pool.` from the manager, and `hook_owner` is only written when the owner
## changes from one bullet to the next instead of being saved, set and restored
## around every hook. The value on entry is restored on exit; during a hook it is
## always the owner_layer of the bullet whose hook runs (a hook that overwrote
## `hook_owner` itself is corrected before the next bullet's hook). Nested spawns
## from a hook save and restore it around their own on_spawn, so nesting and
## re-entrancy see exactly what they saw with a per-hook wrap.
func run_update_hooks(behaviors: Array[BulletBehavior], delta: float) -> void:
	var outer := hook_owner
	var outer_slot := hook_slot
	var table_size := behaviors.size()
	var ran := false
	for k in hooked_count:
		var i := hooked[k]
		# A hook may have killed a later bullet in the list already, or reflected
		# (and so un-scripted) it: neither gets an update.
		if dead_reason[i] != 0:
			continue
		var id := behavior[i]
		if id == 0:
			continue
		if id >= table_size or id < 0:
			# Only a hook writing garbage into `behavior` gets here: spawning an unknown id
			# already yields a plain bullet. Drop the script rather than index out of range.
			behavior[i] = 0
			ScriptWarnings.warn("BulletPool.behavior", "BulletPool: a bullet had the unknown behavior id %d, it is now a plain bullet" % id)
			continue
		var o := owner_layer[i]
		if hook_owner != o:
			hook_owner = o
		hook_slot = i  # reflect() of this very bullet hands the rest of the hook its new owner
		behaviors[id].on_update(self, i, delta)
		ran = true
		# Same check as sanitize(), inlined for the common case that the hook wrote
		# nothing wrong (a call costs more than the check itself). Anything it cannot
		# wave through goes to sanitize(), the one place that decides what is repaired
		# or killed, so the two cannot disagree: this accepts a bullet only if
		# sanitize() would have changed nothing about it.
		var dead := dead_reason[i]
		if dead != 0 and dead != DespawnReason.BOUNDS + 1:
			continue  # dead before the hook ended (sanitize() would only return false)
		var p := pos[i]
		var pp := prev_pos[i]
		var v := vel[i]
		var rt := rot[i]
		var r := radius[i]
		var life := lifetime[i]
		var acc := accel[i]
		var turn := turn_rate[i]
		var dmg := damage[i]
		if (
			is_finite(p.x + p.y + pp.x + pp.y + v.x + v.y + rt.x + rt.y + r + age[i] + life + acc + turn + dmg + param_a[i] + param_b[i])
			and not (
				v.length_squared() > MAX_SPEED_SQ
				or r < 0.0
				or r > MAX_RADIUS
				or life < 0.0
				or life > MAX_LIFETIME
				or absf(acc) > MAX_ACCELERATION
				or absf(turn) > MAX_TURN_RATE
				or dmg < 0.0
				or dmg > MAX_DAMAGE
			)
		):
			if r > max_radius:
				max_radius = r
		else:
			sanitize(i)
	hook_owner = outer
	hook_slot = outer_slot
	if ran:
		# Position, velocity, rotation and the clock are checked now, before walls and
		# hurtboxes use them. This clears `hook_ran`; any later hook sets it again.
		sweep_cross_writes()


## Backstop for what a hook wrote into a bullet that is not its own. The per-bullet
## check in run_update_hooks() only sees the bullet whose hook just returned, but the
## arrays are public: a hook can poke `vel`, `pos`, `age` ... of any other slot, also of a
## plain bullet that has no hook (and so is never checked) or of a child it just
## spawned (checked once, right after on_spawn, not after later writes).
##
## Dirty tracking cannot catch that (the writes go straight into the packed arrays), so
## there is one pass over every alive slot, only when a hook ran: position, previous
## position, rotation, velocity and the clock (age, lifetime). It clears `hook_ran`. It runs
## right after the on_update hooks (before walls, hurtboxes and zones look at anything), at
## the start of BulletManager.step() (a hook that ran between ticks, such as an on_spawn
## from an emitter) and at the end of step() (on_spawn, can_hit, on_hit, on_despawn), before
## the renderer reads the bullets.
##
## Whoever writes a bad clock is a hook, every hook leaves `hook_ran` set (or sweeps), and a
## sweep runs between any hook and the next advance(): so advance() never meets a bad clock
## and keeps its plain expiry test (`not a < life`, which also ends a NaN).
## A write by something that is not a hook (test code poking the arrays) is not covered.
##
## Anything out of order goes through sanitize() (motion) or _fix_clock() (clock). Fields
## left out: damage, radius and the rest, guarded when the bullet hits something
## (BulletManager._apply_hit sanitizes it before the damage is read). A bad radius of a
## bullet that never hits only reaches the renderer: an invisible or oversized quad.
func sweep_cross_writes() -> void:
	hook_ran = false
	sweeps_run += 1
	var p_arr := pos
	var pp_arr := prev_pos
	var v_arr := vel
	var r_arr := rot
	var age_arr := age
	var life_arr := lifetime
	for i in count:
		if not ((p_arr[i] + pp_arr[i] + r_arr[i]).is_finite() and v_arr[i].length_squared() <= MAX_SPEED_SQ):
			sanitize(i)
		# The time left, lifetime - age, must lie in (0, MAX_LIFETIME): `absf(left - half) <
		# half` is false for NaN, +/-inf, a finished bullet (advance() ends it), a lifetime
		# above MAX_LIFETIME and an age below zero by more than that leaves.
		if not absf(life_arr[i] - age_arr[i] - LIFE_LEFT_HALF) < LIFE_LEFT_HALF:
			_fix_clock(i)


## The slow half of the clock test. Non-finite age or lifetime kills the bullet (INVALID);
## a finite lifetime over MAX_LIFETIME is clamped to it, a negative age is reset to 0 (with a
## warning each). A bullet that is merely finished (age >= lifetime) is left to advance().
func _fix_clock(i: int) -> void:
	var dead := dead_reason[i]
	if dead != 0:
		return
	var a := age[i]
	var life := lifetime[i]
	if not is_finite(a + life):
		_kill_invalid(i, "BulletPool.hook_write", "a non-finite value written to age or lifetime")
		return
	if life > MAX_LIFETIME:
		_note_clamp("BulletPool.hook_write", "lifetime", life, MAX_LIFETIME, "MAX_LIFETIME")
		lifetime[i] = MAX_LIFETIME
	if a < 0.0:
		ScriptWarnings.warn(
			"BulletPool.hook_write.clamp.age",
			"BulletPool.hook_write: age %s is far below zero and was reset to 0" % _fmt_number(a)
		)
		age[i] = 0.0


## The one way to write a bullet's velocity from outside the pool (hooks, the
## batch/Lua commit): a velocity above BulletLimits.MAX_SPEED keeps its direction
## and is cut to the ceiling. A NaN or inf kills the bullet with
## DespawnReason.INVALID (counted in `invalid_total`, reported through
## ScriptWarnings), its stored velocity is zeroed (no NaN is ever kept) and it
## returns false.
func set_velocity(i: int, v: Vector2) -> bool:
	if i < 0 or i >= count or dead_reason[i] != 0:
		return false
	if not v.is_finite():
		_kill_invalid(i, "BulletPool.set_velocity", "a non-finite velocity")
		return false
	var clamped := BulletLimits.clamp_velocity(v)
	if clamped != v:
		_warn_speed_clamped("BulletPool.set_velocity", v)
	vel[i] = clamped
	return true


## Re-checks the velocity of slot `i` after a hook may have written `vel[i]`
## directly (the arrays are public): over the ceiling is clamped, NaN/inf kills
## the bullet as INVALID. Returns false if it was killed. Does nothing for a
## dead slot.
func sanitize_velocity(i: int) -> bool:
	if dead_reason[i] != 0:
		return false
	var v := vel[i]
	if not v.is_finite():
		_kill_invalid(i, "BulletPool.velocity", "a non-finite velocity")
		return false
	if BulletLimits.exceeds(v):
		_warn_speed_clamped("BulletPool.velocity", v)
		vel[i] = BulletLimits.clamp_velocity(v)
	return true


## Name of the first non-finite numeric field of `request` ("" if all are finite).
## `angle` may be NaN (that means "face along velocity"), only inf is invalid there.
## The fast path is one finite test over the sum of the fields; only when that
## fails (a real NaN/inf, or a sum of absurd finite doubles overflowing) does it
## look at the fields one by one.
func _bad_request_field(r: ShotRequest) -> String:
	var p := r.position
	var v := r.velocity
	if (
		is_finite(
			p.x + p.y + v.x + v.y + r.radius + r.lifetime + r.acceleration + r.turn_rate + r.damage + r.param_a + r.param_b
		)
		and not is_inf(r.angle)
	):
		return ""
	if not p.is_finite():
		return "position"
	if not v.is_finite():
		return "velocity"
	if is_inf(r.angle):
		return "angle"
	if not is_finite(r.radius):
		return "radius"
	if not is_finite(r.lifetime):
		return "lifetime"
	if not is_finite(r.acceleration):
		return "acceleration"
	if not is_finite(r.turn_rate):
		return "turn_rate"
	if not is_finite(r.damage):
		return "damage"
	if not is_finite(r.param_a):
		return "param_a"
	if not is_finite(r.param_b):
		return "param_b"
	return ""


## Everything a hook may have written into slot `i` is checked after the hook
## returns (BulletManager calls this for hooked bullets only; plain bullets pay
## nothing): a NaN or inf in any numeric field kills the bullet as INVALID (no
## NaN is ever integrated or collided), a finite value outside the BulletLimits
## range is clamped back into it, and a radius bigger than every radius seen so
## far widens `max_radius` (the hurtbox grid margin follows it). A velocity over
## the speed ceiling is cut to it. Returns false if the bullet was killed or was
## already dead. (A bullet that only left the world bounds this tick is still
## checked: it is still delivering its last segment's hits.)
func sanitize(i: int) -> bool:
	var dead := dead_reason[i]
	if dead != 0 and dead != DespawnReason.BOUNDS + 1:
		return false
	var p := pos[i]
	var pp := prev_pos[i]
	var v := vel[i]
	var rt := rot[i]
	var r := radius[i]
	var life := lifetime[i]
	var acc := accel[i]
	var turn := turn_rate[i]
	var dmg := damage[i]
	if not is_finite(p.x + p.y + pp.x + pp.y + v.x + v.y + rt.x + rt.y + r + age[i] + life + acc + turn + dmg + param_a[i] + param_b[i]):
		var field := _non_finite_field(i)
		# The velocity keeps its own warning key (it predates the other fields).
		if field == "vel":
			_kill_invalid(i, "BulletPool.velocity", "a non-finite velocity")
		else:
			_kill_invalid(i, "BulletPool.hook_write", "a non-finite value written to %s" % field)
		return false
	# Everything is finite: only out-of-range values need any more work. One
	# combined test keeps the common case (nothing to fix) cheap.
	if (
		v.length_squared() > MAX_SPEED_SQ
		or r < 0.0
		or r > MAX_RADIUS
		or life < 0.0
		or life > MAX_LIFETIME
		or absf(acc) > MAX_ACCELERATION
		or absf(turn) > MAX_TURN_RATE
		or dmg < 0.0
		or dmg > MAX_DAMAGE
	):
		_clamp_into_range(i)
	elif r > max_radius:
		max_radius = r
	return true


## The slow half of sanitize(): puts every out-of-range (finite) value of slot `i`
## back into its BulletLimits range, and says so (rate-limited, see _note_clamp).
func _clamp_into_range(i: int) -> void:
	var v := vel[i]
	if BulletLimits.exceeds(v):
		_warn_speed_clamped("BulletPool.hook_write", v)
		vel[i] = BulletLimits.clamp_velocity(v)
	var r := radius[i]
	var clamped_r := clampf(r, 0.0, MAX_RADIUS)
	if clamped_r != r:
		_note_clamp("BulletPool.hook_write", "radius", r, clamped_r, "MAX_RADIUS")
	radius[i] = clamped_r
	if clamped_r > max_radius:
		max_radius = clamped_r
	var life := lifetime[i]
	var clamped_life := clampf(life, 0.0, MAX_LIFETIME)
	if clamped_life != life:
		_note_clamp("BulletPool.hook_write", "lifetime", life, clamped_life, "MAX_LIFETIME")
	lifetime[i] = clamped_life
	var acc := accel[i]
	var clamped_acc := clampf(acc, -MAX_ACCELERATION, MAX_ACCELERATION)
	if clamped_acc != acc:
		_note_clamp("BulletPool.hook_write", "acceleration", acc, clamped_acc, "MAX_ACCELERATION")
	accel[i] = clamped_acc
	var turn := turn_rate[i]
	var clamped_turn := clampf(turn, -MAX_TURN_RATE, MAX_TURN_RATE)
	if clamped_turn != turn:
		_note_clamp("BulletPool.hook_write", "turn_rate", turn, clamped_turn, "MAX_TURN_RATE")
	turn_rate[i] = clamped_turn
	var dmg := damage[i]
	var clamped_dmg := clampf(dmg, 0.0, MAX_DAMAGE)
	if clamped_dmg != dmg:
		_note_clamp("BulletPool.hook_write", "damage", dmg, clamped_dmg, "MAX_DAMAGE")
	damage[i] = clamped_dmg


## A finite value was outside its BulletLimits range and was clamped. One warning
## key per field (`<where>.clamp.<field>`), so a script that clamps every tick cannot
## flood the log: ScriptWarnings prints each key LIMIT times and then goes quiet.
## `where` is the code path ("BulletPool.spawn", "BulletPool.hook_write", ...).
static func _note_clamp(where: String, field: String, asked: float, kept: float, limit_name: String) -> void:
	var key := "%s.clamp.%s" % [where, field]
	if ScriptWarnings.begin(key):
		ScriptWarnings.finish(key, ScriptWarnings.clamp_message(where, field, asked, kept, limit_name))
	else:
		ScriptWarnings.keep_clamp(key, where, field, asked, kept, limit_name)


## Number for a warning: plain up to 1e7, scientific beyond (1e30 would be 31 digits).
static func _fmt_number(x: float) -> String:
	if absf(x) < 1.0e7:
		return String.num(x, 3)
	var e := floori(log(absf(x)) / log(10.0))
	return "%.3fe%d" % [x / pow(10.0, e), e]


## Speed over BulletLimits.MAX_SPEED. The length is taken in a way that cannot
## overflow (a velocity component near 1e30 would square to inf).
static func _warn_speed_clamped(where: String, v: Vector2) -> void:
	report_speed_clamp(where, v)


## Same text as a pool set_velocity / hook_write removal. Native batch commits
## call this so both backings share one message.
static func report_removed(key: String, what: String) -> void:
	if ScriptWarnings.begin(key):
		ScriptWarnings.finish(key, ScriptWarnings.removed_message(key, what))
	else:
		ScriptWarnings.keep_removed(key, what)


## Same text as `_note_clamp` for a speed ceiling. `where` is the code path
## ("BulletPool.set_velocity", "BulletPool.hook_write", ...).
static func report_speed_clamp(where: String, v: Vector2) -> void:
	var key := "%s.clamp.speed" % where
	if ScriptWarnings.begin(key):
		ScriptWarnings.finish(key, ScriptWarnings.speed_message(where, v))
	else:
		ScriptWarnings.keep_speed(key, v)


## spawn_simple(): the clamped fields are velocity, lifetime and radius.
static func _warn_clamped_fields(where: String, v: Vector2, r: float, life: float) -> void:
	if BulletLimits.exceeds(v):
		_warn_speed_clamped(where, v)
	if r < 0.0 or r > MAX_RADIUS:
		_note_clamp(where, "radius", r, clampf(r, 0.0, MAX_RADIUS), "MAX_RADIUS")
	if life < 0.0 or life > MAX_LIFETIME:
		_note_clamp(where, "lifetime", life, clampf(life, 0.0, MAX_LIFETIME), "MAX_LIFETIME")


## spawn(): names each field of `request` that had to be clamped.
static func _warn_clamped_request(where: String, request: ShotRequest) -> void:
	_warn_clamped_fields(where, request.velocity, request.radius, request.lifetime)
	var acc := request.acceleration
	if absf(acc) > MAX_ACCELERATION:
		_note_clamp(where, "acceleration", acc, clampf(acc, -MAX_ACCELERATION, MAX_ACCELERATION), "MAX_ACCELERATION")
	var turn := request.turn_rate
	if absf(turn) > MAX_TURN_RATE:
		_note_clamp(where, "turn_rate", turn, clampf(turn, -MAX_TURN_RATE, MAX_TURN_RATE), "MAX_TURN_RATE")
	var dmg := request.damage
	if dmg < 0.0 or dmg > MAX_DAMAGE:
		_note_clamp(where, "damage", dmg, clampf(dmg, 0.0, MAX_DAMAGE), "MAX_DAMAGE")
	var pa := request.param_a
	if absf(pa) > BulletLimits.MAX_PARAM:
		_note_clamp(where, "param_a", pa, clampf(pa, -BulletLimits.MAX_PARAM, BulletLimits.MAX_PARAM), "MAX_PARAM")
	var pb := request.param_b
	if absf(pb) > BulletLimits.MAX_PARAM:
		_note_clamp(where, "param_b", pb, clampf(pb, -BulletLimits.MAX_PARAM, BulletLimits.MAX_PARAM), "MAX_PARAM")


func _non_finite_field(i: int) -> String:
	if not pos[i].is_finite():
		return "pos"
	if not prev_pos[i].is_finite():
		return "prev_pos"
	if not vel[i].is_finite():
		return "vel"
	if not rot[i].is_finite():
		return "rot"
	if not is_finite(radius[i]):
		return "radius"
	if not is_finite(age[i]):
		return "age"
	if not is_finite(lifetime[i]):
		return "lifetime"
	if not is_finite(accel[i]):
		return "accel"
	if not is_finite(turn_rate[i]):
		return "turn_rate"
	if not is_finite(damage[i]):
		return "damage"
	if not is_finite(param_a[i]):
		return "param_a"
	return "param_b"


func _kill_invalid(i: int, key: String, what: String) -> void:
	invalid_total += 1
	report_removed(key, what)
	vel[i] = Vector2.ZERO
	# Nothing non-finite stays in a slot that is still readable this tick (the
	# on_despawn hook, the renderer).
	if not prev_pos[i].is_finite():
		prev_pos[i] = Vector2.ZERO
	if not pos[i].is_finite():
		pos[i] = prev_pos[i]
	if not rot[i].is_finite():
		rot[i] = Vector2.RIGHT
	if not is_finite(radius[i]):
		radius[i] = 0.0
	mark_dead(i, DespawnReason.INVALID)


func _reject_invalid(key: String, what: String) -> void:
	invalid_total += 1
	ScriptWarnings.warn(key, "%s: rejected %s" % [key, what])


## Moves bullet `i` to `p` discontinuously, e.g. a teleport or a script that
## places a bullet somewhere new. Sets both pos and prev_pos, so the move is not
## swept (no phantom hits or wall hits along the jump) and not interpolated (no
## streak across the screen). Hooks must use this instead of writing `pos[i]`
## when the bullet should not travel there: a plain `pos[i] = p` leaves
## prev_pos stale, so the bullet is treated as having flown from its old
## position this tick. (Ordinary steering via `vel` needs nothing special.)
func teleport(i: int, p: Vector2) -> void:
	pos[i] = p
	prev_pos[i] = p


## Marks slot `i` for removal at the next flush_dead(). Safe to call from
## hooks while iterating; a bullet can only be marked once (first reason wins).
func mark_dead(i: int, reason: int = DespawnReason.MANUAL) -> void:
	if dead_reason[i] != 0:
		return
	dead_reason[i] = reason + 1
	pending[pending_count] = i
	pending_count += 1


## A bullet that left the world bounds is marked dead (BOUNDS) before collision
## runs, but it still gets to hit things on the part of its path inside the
## bounds. If it did, that hit (or wall) is the real reason it ended: this
## relabels such a bullet and does nothing for any other state.
func claim_from_bounds(i: int, reason: int) -> void:
	if dead_reason[i] == DespawnReason.BOUNDS + 1:
		dead_reason[i] = reason + 1


## Removes every bullet marked dead. Returns how many were removed.
##
## Allocation-free and order-independent: marked slots are visited in marking
## order; removing slot `s` moves the current last bullet into it, and if that
## bullet is itself dead (it carries its dead flag along) the same slot is
## removed again. A marked slot that has already been truncated away
## (s >= count) was the last bullet and is gone by then.
func flush_dead() -> int:
	var removed := pending_count
	for k in removed:
		var s := pending[k]
		while s < count and dead_reason[s] != 0:
			_remove_at(s)
	pending_count = 0
	return removed


## Immediately removes slot `i` (swap-remove). Do not call while iterating over
## slots; use mark_dead() + flush_dead() instead.
func despawn(i: int) -> void:
	assert(i >= 0 and i < count, "despawn: slot out of range")
	_remove_at(i)


## Removes every bullet. Statistics are kept.
func clear() -> void:
	# Invalidate every outstanding id, then rebuild the free list.
	for slot in count:
		var h := _handle_of_slot[slot]
		_generation[h] = (_generation[h] + 1) & GENERATION_MASK
		if _generation[h] == 0:
			_generation[h] = 1
	_slot_of_handle.fill(-1)
	_rebuild_free_list()
	user.fill(null)
	owner_counts.fill(0)
	veto_count = 0
	count = 0
	pending_count = 0
	hooked_count = 0
	dead_reason.fill(0)
	if store_cleared.is_valid():
		store_cleared.call()


## True when the pool holds `logical_cap` bullets, i.e. every further shot is
## refused whoever fires it. (A non-enemy shooter is refused earlier, see
## can_spawn() / headroom().)
func is_full() -> bool:
	return count >= logical_cap


# --- saturation model: limits and counters --------------------------------------

## Sets the logical cap (clamped to [0, capacity]) and the enemy reserve (clamped
## to [0, cap]). Lowering the cap below the current count never removes bullets:
## it only refuses new shots until enough have despawned.
func set_limits(cap: int, reserve: int) -> void:
	logical_cap = clampi(cap, 0, capacity)
	enemy_reserve = clampi(reserve, 0, logical_cap)
	_other_limit = logical_cap - enemy_reserve


## Owner slot (OWNER_NONE / OWNER_PLAYER / OWNER_ENEMY) of an `owner_layer` value.
## Player wins when both bits are set, like Layers.hostile_to(). Enemy and boss
## bullets share OWNER_ENEMY.
static func owner_slot(layer: int) -> int:
	if (layer & Layers.PLAYER) != 0:
		return OWNER_PLAYER
	if (layer & Layers.ENEMY) != 0:
		return OWNER_ENEMY
	return OWNER_NONE


## Bullets currently occupying a slot that belong to `layer`'s owner slot.
func owner_count(layer: int) -> int:
	return owner_counts[owner_slot(layer)]


## Highest total number of bullets a shooter of `layer` can bring the pool to.
func limit_for(layer: int) -> int:
	return logical_cap if owner_slot(layer) == OWNER_ENEMY else _other_limit


## How many more bullets a shooter of `layer` could spawn right now.
func headroom(layer: int) -> int:
	return maxi(limit_for(layer) - count, 0)


## True if a shot from `layer` would be accepted right now.
func can_spawn(layer: int) -> bool:
	return count < limit_for(layer)


## Shots refused so far for `layer`'s owner slot.
func dropped_for(layer: int) -> int:
	return dropped_by_owner[owner_slot(layer)]


## Rebuilds `owner_counts` and `veto_count` from the arrays (repair after code
## wrote `owner_layer[i]` directly).
func recount_owners() -> void:
	owner_counts.fill(0)
	veto_count = 0
	for i in count:
		owner_counts[owner_slot(owner_layer[i])] += 1
		if can_hit_veto[i] != 0:
			veto_count += 1


## True if the counters match the arrays (debug / tests).
func counters_consistent() -> bool:
	var seen := PackedInt32Array([0, 0, 0])
	var vetoes := 0
	for i in count:
		seen[owner_slot(owner_layer[i])] += 1
		if can_hit_veto[i] != 0:
			vetoes += 1
	return seen == owner_counts and vetoes == veto_count and count == owner_counts[0] + owner_counts[1] + owner_counts[2]


## Records one refused shot. `at_cap` is true when the combined live count is
## already at `logical_cap` (or this store is physically full); otherwise the
## enemy reserve refused a non-enemy shooter. BulletManager uses this when the
## native store is holding part of the cap, so the reason is the shared total
## and not this pool's count alone.
func record_drop(layer: int, at_cap: bool) -> void:
	var owner_slot_i := owner_slot(layer)
	dropped_total += 1
	dropped_by_owner[owner_slot_i] += 1
	dropped_by_limit[DropLimit.LOGICAL_CAP if at_cap else DropLimit.ENEMY_RESERVE] += 1


## Shared-cap admission. `external_count` is the other backend. When it is 0 the
## test is `count >= limit`, the same one this pool has always used, and a full
## store is LOGICAL_CAP exactly when `count >= logical_cap`.
func _admit(owner_slot_i: int) -> bool:
	var total := count + external_count
	var limit := logical_cap if owner_slot_i == OWNER_ENEMY else _other_limit
	if total >= limit:
		var layer := 0
		if owner_slot_i == OWNER_PLAYER:
			layer = Layers.PLAYER
		elif owner_slot_i == OWNER_ENEMY:
			layer = Layers.ENEMY
		record_drop(layer, total >= logical_cap)
		return false
	return true


# --- stable handles ------------------------------------------------------------

## Stable id of the bullet currently in `slot` (valid until it despawns).
func id_of(slot: int) -> int:
	assert(slot >= 0 and slot < count, "id_of: slot out of range")
	var h := _handle_of_slot[slot]
	return (_generation[h] << HANDLE_BITS) | h


## Current slot of the bullet with this id, or -1 if the id is stale, invalid or
## its bullet has despawned. A bullet that is marked dead but not yet flushed
## still has a slot.
func slot_of(id: int) -> int:
	if id <= 0:
		return -1
	var h := id & HANDLE_MASK
	if h >= capacity or (id >> HANDLE_BITS) != _generation[h]:
		return -1
	return _slot_of_handle[h]


## True while the bullet exists and has not been marked for removal.
func is_alive(id: int) -> bool:
	var slot := slot_of(id)
	return slot >= 0 and dead_reason[slot] == 0


func _assign_handle(slot: int) -> void:
	_free_count -= 1
	var h := _free_handles[_free_count]
	_slot_of_handle[h] = slot
	_handle_of_slot[slot] = h


func _release_handle(h: int) -> void:
	var g := (_generation[h] + 1) & GENERATION_MASK
	_generation[h] = g if g != 0 else 1
	_slot_of_handle[h] = -1
	_free_handles[_free_count] = h
	_free_count += 1


func _reset_handles() -> void:
	_generation.fill(1)
	_slot_of_handle.fill(-1)
	_rebuild_free_list()


func _rebuild_free_list() -> void:
	for k in capacity:
		_free_handles[k] = capacity - 1 - k  # pop order: handle 0 first
	_free_count = capacity


## Forgets every target `slot` has pierced. Spawn and reflect() both start a
## bullet with a clean ring; count 0 is the whole reset (the window is not read
## while the count is 0, so plain bullets never pay to wipe it).
func clear_hit_memory(slot: int) -> void:
	hit_mem_count[slot] = 0
	hit_mem_head[slot] = 0


## Records that a piercing bullet in `slot` just hit the hurtbox `target_id`
## (an instance id). A repeat of an id already in the ring does not move the
## others along. Once HIT_MEMORY distinct targets are remembered, the oldest is
## dropped.
func remember_target(slot: int, target_id: int) -> void:
	var n := int(hit_mem_count[slot])
	var base := slot * HIT_MEMORY
	for k in n:
		if hit_mem[base + k] == target_id:
			return
	if n < HIT_MEMORY:
		hit_mem[base + n] = target_id
		hit_mem_count[slot] = n + 1
		return
	var head := int(hit_mem_head[slot])
	hit_mem[base + head] = target_id
	hit_mem_head[slot] = (head + 1) % HIT_MEMORY


## Moves slot `src`'s ring onto `dst`. A bullet that never pierced (count 0)
## only copies the count and head, not the window.
func _copy_hit_memory(src: int, dst: int) -> void:
	var n := hit_mem_count[src]
	hit_mem_count[dst] = n
	hit_mem_head[dst] = hit_mem_head[src]
	if n == 0:
		return
	var from := src * HIT_MEMORY
	var to := dst * HIT_MEMORY
	for k in HIT_MEMORY:
		hit_mem[to + k] = hit_mem[from + k]


## Damage a reflected bullet deals unless told otherwise: **1**, whatever the
## script gave the bullet (design pillars 5.4: "its script `damage` value is
## ignored when hitting you"). Provisional until balance says otherwise.
const REFLECTED_DAMAGE := 1.0
## Pass as `new_damage` to keep the bullet's own damage.
const KEEP_DAMAGE := -1.0
## How many times a bullet may change owner through reflect(): 1 = at most one
## reflection per bullet (pillars 5.4, prevents ping-pong); 0 = unlimited. Applies
## to every reflect() call (scripts through ShotEmitter.reflect_bullet, Reflector
## zones) unless the caller passes its own `limit`.
var max_reflections := 1


## Hands bullet `slot` to another faction (a reflection). The bullet:
##   - belongs to `new_owner_layer` (Layers.PLAYER or Layers.ENEMY), hits only what
##     is hostile to that faction (hit_mask = Layers.hostile_to(new owner), so it
##     can never hit its new owner), and takes that faction's colour
##     (Layers.bullet_color);
##   - deals `new_damage` (default REFLECTED_DAMAGE = 1; KEEP_DAMAGE keeps its own);
##   - is **no longer scripted**: behavior becomes 0 (a plain bullet; hooks stop,
##     including on_despawn), `user` and `param_a/b` are cleared and it stops
##     piercing script invulnerability. `keep_script` opts out of all of that for
##     the rare reflection that should stay scripted;
##   - has its piercing hit memory cleared and `reflect_count` raised;
##   - with `reverse`, flies back (velocity and heading flipped).
## Refuses, changing nothing and returning false, for a dead or invalid slot, an
## owner that is not PLAYER or ENEMY, or a bullet that was already reflected
## `limit` times (limit < 0 = use `max_reflections`; 0 = no limit). Prefer
## ShotEmitter.reflect_bullet(id, ...) from scripts: it takes stable ids.
func reflect(
	slot: int,
	new_owner_layer: int,
	reverse: bool = false,
	new_damage: float = REFLECTED_DAMAGE,
	keep_script: bool = false,
	limit: int = -1
) -> bool:
	if slot < 0 or slot >= count or dead_reason[slot] != 0:
		return false
	if new_owner_layer != Layers.PLAYER and new_owner_layer != Layers.ENEMY:
		return false
	var cap := max_reflections if limit < 0 else limit
	if cap > 0 and reflect_count[slot] >= cap:
		return false
	var old_slot := owner_slot(owner_layer[slot])
	var new_slot := owner_slot(new_owner_layer)
	if old_slot != new_slot:
		owner_counts[old_slot] -= 1
		owner_counts[new_slot] += 1
	owner_layer[slot] = new_owner_layer
	if slot == hook_slot and hook_owner >= 0:
		# The hook of this very bullet is running: what it spawns from here on
		# belongs to the new owner (a reflected bullet's children are the new side's).
		hook_owner = new_owner_layer
	if reflect_count[slot] < 255:
		reflect_count[slot] += 1
	hit_mask[slot] = Layers.hostile_to(new_owner_layer)
	color[slot] = Layers.bullet_color(new_owner_layer)
	clear_hit_memory(slot)
	if new_damage >= 0.0:
		damage[slot] = new_damage
	if not keep_script:
		behavior[slot] = 0
		user[slot] = null
		param_a[slot] = 0.0
		param_b[slot] = 0.0
		pierces_script_invuln[slot] = 0
		if can_hit_veto[slot] != 0:
			can_hit_veto[slot] = 0
			veto_count -= 1
	if reverse:
		vel[slot] = -vel[slot]
		rot[slot] = -rot[slot]
	return true


func _stamp_seq(i: int) -> void:
	if alloc_order.is_valid():
		alloc_order.call(i)
	else:
		seq[i] = i


func _remove_at(i: int) -> void:
	if retire_order.is_valid():
		retire_order.call(i)
	var reason := int(dead_reason[i]) - 1
	if reason >= 0 and reason < despawn_counts.size():
		despawn_counts[reason] += 1
		if log_despawns:
			despawn_log_reason.append(reason)
			despawn_log_life.append(lifetime[i])
	var last := count - 1
	owner_counts[owner_slot(owner_layer[i])] -= 1
	if can_hit_veto[i] != 0:
		veto_count -= 1
	_release_handle(_handle_of_slot[i])
	if i != last:
		var moved := _handle_of_slot[last]
		_handle_of_slot[i] = moved
		_slot_of_handle[moved] = i
		user[i] = user[last]
		pos[i] = pos[last]
		prev_pos[i] = prev_pos[last]
		vel[i] = vel[last]
		rot[i] = rot[last]
		radius[i] = radius[last]
		age[i] = age[last]
		lifetime[i] = lifetime[last]
		accel[i] = accel[last]
		turn_rate[i] = turn_rate[last]
		damage[i] = damage[last]
		param_a[i] = param_a[last]
		param_b[i] = param_b[last]
		color[i] = color[last]
		hit_mask[i] = hit_mask[last]
		owner_layer[i] = owner_layer[last]
		reflect_count[i] = reflect_count[last]
		pierces_script_invuln[i] = pierces_script_invuln[last]
		can_hit_veto[i] = can_hit_veto[last]
		behavior[i] = behavior[last]
		pierce[i] = pierce[last]
		collide_world[i] = collide_world[last]
		seq[i] = seq[last]
		_copy_hit_memory(last, i)
	dead_reason[i] = dead_reason[last] if i != last else 0
	dead_reason[last] = 0
	user[last] = null
	count = last


## Inserts a bullet that already lived in NativeBulletSim. Does not allocate a
## new seq or count another spawn: the caller passes the seq it already had.
## Returns the slot, or -1 if the pool has no physical room.
func adopt_native(row: Dictionary) -> int:
	if count >= capacity:
		return -1
	var owner: int = row["owner"]
	var owner_slot_i := owner_slot(owner)
	owner_counts[owner_slot_i] += 1
	var i := count
	count += 1
	_assign_handle(i)
	user[i] = null
	var pos_v: Vector2 = row["pos"]
	var prev_v: Vector2 = row["prev"]
	var vel_v: Vector2 = row["vel"]
	var rot_v: Vector2 = row["rot"]
	pos[i] = pos_v
	prev_pos[i] = prev_v
	vel[i] = vel_v
	rot[i] = rot_v
	var radius_v: float = row["radius"]
	var age_v: float = row["age"]
	var life_v: float = row["lifetime"]
	var accel_v: float = row["accel"]
	var turn_v: float = row["turn"]
	var damage_v: float = row["damage"]
	radius[i] = radius_v
	age[i] = age_v
	lifetime[i] = life_v
	accel[i] = accel_v
	turn_rate[i] = turn_v
	damage[i] = damage_v
	param_a[i] = 0.0
	param_b[i] = 0.0
	if row.has("param_a"):
		var pa_v: float = row["param_a"]
		param_a[i] = pa_v
	if row.has("param_b"):
		var pb_v: float = row["param_b"]
		param_b[i] = pb_v
	var color_v: Color = row["color"]
	color[i] = color_v
	var mask_v: int = row["hit_mask"]
	var pierce_v: int = row["pierce"]
	var seq_v: int = row["seq"]
	var flags_v: int = row["flags"]
	var head_v: int = row["hit_head"]
	hit_mask[i] = mask_v
	owner_layer[i] = owner
	var reflected: int = row.get("reflect_count", 0)
	reflect_count[i] = reflected
	pierces_script_invuln[i] = 1 if flags_v != 0 else 0
	can_hit_veto[i] = 0
	behavior[i] = 0
	if row.has("behavior"):
		var behavior_v: int = row["behavior"]
		behavior[i] = behavior_v
	pierce[i] = pierce_v
	var collides: bool = row["collide"]
	collide_world[i] = 1 if collides else 0
	seq[i] = seq_v
	clear_hit_memory(i)
	var mem: PackedInt64Array = row["hit_mem"]
	var base := i * HIT_MEMORY
	for k in mem.size():
		hit_mem[base + k] = mem[k]
	hit_mem_count[i] = mem.size()
	hit_mem_head[i] = head_v
	dead_reason[i] = 0
	if radius_v > max_radius:
		max_radius = radius_v
	return i


## Puts slots into increasing seq order. Stable ids (handles) move with the
## bullets. Used after native bullets are adopted so the pool's slot walk
## matches the all-GD order.
func sort_slots_by_seq() -> void:
	for i in count:
		var best := i
		for j in range(i + 1, count):
			if seq[j] < seq[best]:
				best = j
		if best != i:
			_swap_slots(i, best)


func _swap_slots(a: int, b: int) -> void:
	var ha := _handle_of_slot[a]
	var hb := _handle_of_slot[b]
	_handle_of_slot[a] = hb
	_handle_of_slot[b] = ha
	_slot_of_handle[ha] = b
	_slot_of_handle[hb] = a
	var pos_t := pos[a]
	pos[a] = pos[b]
	pos[b] = pos_t
	var prev_t := prev_pos[a]
	prev_pos[a] = prev_pos[b]
	prev_pos[b] = prev_t
	var vel_t := vel[a]
	vel[a] = vel[b]
	vel[b] = vel_t
	var rot_t := rot[a]
	rot[a] = rot[b]
	rot[b] = rot_t
	var radius_t := radius[a]
	radius[a] = radius[b]
	radius[b] = radius_t
	var age_t := age[a]
	age[a] = age[b]
	age[b] = age_t
	var life_t := lifetime[a]
	lifetime[a] = lifetime[b]
	lifetime[b] = life_t
	var accel_t := accel[a]
	accel[a] = accel[b]
	accel[b] = accel_t
	var turn_t := turn_rate[a]
	turn_rate[a] = turn_rate[b]
	turn_rate[b] = turn_t
	var damage_t := damage[a]
	damage[a] = damage[b]
	damage[b] = damage_t
	var pa_t := param_a[a]
	param_a[a] = param_a[b]
	param_a[b] = pa_t
	var pb_t := param_b[a]
	param_b[a] = param_b[b]
	param_b[b] = pb_t
	var color_t := color[a]
	color[a] = color[b]
	color[b] = color_t
	var mask_t := hit_mask[a]
	hit_mask[a] = hit_mask[b]
	hit_mask[b] = mask_t
	var owner_t := owner_layer[a]
	owner_layer[a] = owner_layer[b]
	owner_layer[b] = owner_t
	var reflect_t := reflect_count[a]
	reflect_count[a] = reflect_count[b]
	reflect_count[b] = reflect_t
	var pierce_flag_t := pierces_script_invuln[a]
	pierces_script_invuln[a] = pierces_script_invuln[b]
	pierces_script_invuln[b] = pierce_flag_t
	var veto_t := can_hit_veto[a]
	can_hit_veto[a] = can_hit_veto[b]
	can_hit_veto[b] = veto_t
	var behavior_t := behavior[a]
	behavior[a] = behavior[b]
	behavior[b] = behavior_t
	var pierce_t := pierce[a]
	pierce[a] = pierce[b]
	pierce[b] = pierce_t
	var collide_t := collide_world[a]
	collide_world[a] = collide_world[b]
	collide_world[b] = collide_t
	var seq_t := seq[a]
	seq[a] = seq[b]
	seq[b] = seq_t
	var dead_t := dead_reason[a]
	dead_reason[a] = dead_reason[b]
	dead_reason[b] = dead_t
	var user_t: Variant = user[a]
	user[a] = user[b]
	user[b] = user_t
	var mem_a := PackedInt64Array()
	var mem_b := PackedInt64Array()
	mem_a.resize(HIT_MEMORY)
	mem_b.resize(HIT_MEMORY)
	var base_a := a * HIT_MEMORY
	var base_b := b * HIT_MEMORY
	for k in HIT_MEMORY:
		mem_a[k] = hit_mem[base_a + k]
		mem_b[k] = hit_mem[base_b + k]
	for k in HIT_MEMORY:
		hit_mem[base_a + k] = mem_b[k]
		hit_mem[base_b + k] = mem_a[k]
	var count_t := hit_mem_count[a]
	hit_mem_count[a] = hit_mem_count[b]
	hit_mem_count[b] = count_t
	var head_t := hit_mem_head[a]
	hit_mem_head[a] = hit_mem_head[b]
	hit_mem_head[b] = head_t
