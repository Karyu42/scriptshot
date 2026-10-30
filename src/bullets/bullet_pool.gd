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

## Flagged-bullet sweeps list up to this many hits per tick so that a vetoed hit
## does not hide the next target on the path (see can_hit_veto).
const VETO_MAX_HITS := 4

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
## How many alive bullets carry the can_hit_veto flag (lets the collision loop
## skip the per-bullet check entirely while there are none).
var veto_count := 0

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
## Instance id of the last hurtbox a piercing bullet hit (avoids re-hitting
## the same target every tick while overlapping).
var last_hit := PackedInt64Array()
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
var hooked := PackedInt32Array()
var hooked_count := 0


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
	last_hit.resize(capacity)
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
	var owner_slot_i := OWNER_NONE
	if (request.owner_layer & Layers.PLAYER) != 0:
		owner_slot_i = OWNER_PLAYER
	elif (request.owner_layer & Layers.ENEMY) != 0:
		owner_slot_i = OWNER_ENEMY
	if count >= (logical_cap if owner_slot_i == OWNER_ENEMY else _other_limit):
		_record_drop(owner_slot_i)
		return -1
	owner_counts[owner_slot_i] += 1
	var i := count
	count += 1
	spawned_total += 1
	_assign_handle(i)
	user[i] = request.user
	pos[i] = request.position
	prev_pos[i] = request.position
	vel[i] = request.velocity
	if is_nan(request.angle):
		var speed := request.velocity.length()
		rot[i] = request.velocity / speed if speed > 0.0 else Vector2.RIGHT
	else:
		rot[i] = Vector2.from_angle(request.angle)
	radius[i] = request.radius
	age[i] = 0.0
	lifetime[i] = request.lifetime
	accel[i] = request.acceleration
	turn_rate[i] = request.turn_rate
	damage[i] = request.damage
	param_a[i] = request.param_a
	param_b[i] = request.param_b
	color[i] = request.color
	owner_layer[i] = request.owner_layer
	reflect_count[i] = 0
	pierces_script_invuln[i] = 1 if request.pierces_script_invuln else 0
	if request.can_hit_veto:
		can_hit_veto[i] = 1
		veto_count += 1
	else:
		can_hit_veto[i] = 0
	hit_mask[i] = request.hit_mask & ~request.owner_layer
	behavior[i] = request.behavior_id
	pierce[i] = request.pierce
	collide_world[i] = 1 if request.collide_world else 0
	last_hit[i] = 0
	dead_reason[i] = 0
	if request.radius > max_radius:
		max_radius = request.radius
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
	if count >= _other_limit:
		_record_drop(OWNER_NONE)
		return -1
	owner_counts[OWNER_NONE] += 1
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
	owner_layer[i] = 0
	reflect_count[i] = 0
	pierces_script_invuln[i] = 0
	can_hit_veto[i] = 0
	hit_mask[i] = mask
	behavior[i] = 0
	pierce[i] = 0
	collide_world[i] = 1
	last_hit[i] = 0
	dead_reason[i] = 0
	if bullet_radius > max_radius:
		max_radius = bullet_radius
	return i


## Integrates every alive bullet by `delta` seconds and marks bullets whose
## lifetime ran out or that left `bounds` as dead (they are removed by
## flush_dead(), which lets the manager run hooks first). Also rebuilds the
## `hooked` list.
func advance(delta: float, bounds: Rect2) -> void:
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
		if a >= lifetime[i]:
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
					v *= maxf(speed + acc * delta, 0.0) / speed
			vel[i] = v
		var p := pos[i] + v * delta
		pos[i] = p
		if p.x < min_x or p.x > max_x or p.y < min_y or p.y > max_y:
			mark_dead(i, DespawnReason.BOUNDS)
			continue
		if behavior[i] != 0:
			hooked[hooked_count] = i
			hooked_count += 1


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


func _record_drop(owner_slot_i: int) -> void:
	dropped_total += 1
	dropped_by_owner[owner_slot_i] += 1
	dropped_by_limit[DropLimit.LOGICAL_CAP if count >= logical_cap else DropLimit.ENEMY_RESERVE] += 1


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
##   - has its piercing memory (`last_hit`) cleared and `reflect_count` raised;
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
	if reflect_count[slot] < 255:
		reflect_count[slot] += 1
	hit_mask[slot] = Layers.hostile_to(new_owner_layer)
	color[slot] = Layers.bullet_color(new_owner_layer)
	last_hit[slot] = 0
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


func _remove_at(i: int) -> void:
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
		last_hit[i] = last_hit[last]
	dead_reason[i] = dead_reason[last] if i != last else 0
	dead_reason[last] = 0
	user[last] = null
	count = last
