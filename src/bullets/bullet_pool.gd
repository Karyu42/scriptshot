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
## Performance note: the hot loop writes to the pool's own member arrays. Do
## not cache them in a local variable before writing (GDScript copies a packed
## array on the first write when another reference exists). Reading through a
## local alias is fine.

## Why a bullet was removed (passed to BulletBehavior.on_despawn). New reasons are
## only ever appended, so existing values stay stable.
enum DespawnReason { LIFETIME, BOUNDS, HIT, MANUAL, CLEARED, WALL }

## Maximum number of simultaneously alive bullets. Fixed at construction.
var capacity := 0
## Number of alive bullets. Valid slots are [0, count).
var count := 0
## Largest radius ever spawned; HurtboxGrid uses it to size target margins.
var max_radius := 0.0
## Lifetime statistics.
var spawned_total := 0
var dropped_total := 0

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
var behavior := PackedInt32Array()
var pierce := PackedInt32Array()
## 1 = collides with the `world` layer (walls), 0 = flies through walls.
var collide_world := PackedByteArray()
## Instance id of the last hurtbox a piercing bullet hit (avoids re-hitting
## the same target every tick while overlapping).
var last_hit := PackedInt64Array()
## 0 = alive; otherwise DespawnReason + 1 (pending removal in flush_dead()).
var dead_reason := PackedByteArray()

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
	behavior.resize(capacity)
	pierce.resize(capacity)
	collide_world.resize(capacity)
	last_hit.resize(capacity)
	dead_reason.resize(capacity)
	pending.resize(capacity)
	hooked.resize(capacity)


## Spawns a bullet from a ShotRequest. Returns its slot, or -1 if the pool is
## full. The slot is only stable until the next despawn.
func spawn(request: ShotRequest) -> int:
	if count >= capacity:
		dropped_total += 1
		return -1
	var i := count
	count += 1
	spawned_total += 1
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
	hit_mask[i] = request.hit_mask
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
	if count >= capacity:
		dropped_total += 1
		return -1
	var i := count
	count += 1
	spawned_total += 1
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


## Marks slot `i` for removal at the next flush_dead(). Safe to call from
## hooks while iterating; a bullet can only be marked once (first reason wins).
func mark_dead(i: int, reason: int = DespawnReason.MANUAL) -> void:
	if dead_reason[i] != 0:
		return
	dead_reason[i] = reason + 1
	pending[pending_count] = i
	pending_count += 1


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
	count = 0
	pending_count = 0
	hooked_count = 0
	dead_reason.fill(0)


func is_full() -> bool:
	return count >= capacity


func _remove_at(i: int) -> void:
	var last := count - 1
	if i != last:
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
		behavior[i] = behavior[last]
		pierce[i] = pierce[last]
		collide_world[i] = collide_world[last]
		last_hit[i] = last_hit[last]
	dead_reason[i] = dead_reason[last] if i != last else 0
	dead_reason[last] = 0
	count = last
