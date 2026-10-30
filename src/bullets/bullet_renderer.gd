class_name BulletRenderer
extends MultiMeshInstance2D
## Draws every alive bullet of a BulletPool with a single MultiMesh (one draw
## call, zero nodes per bullet). Bullets are flat coloured discs/ellipses
## produced by bullet.gdshader.
##
## Smooth on any refresh rate: the simulation runs at the fixed physics tick,
## and each tick this uploads two instance buffers, the bullets at the end of the
## tick and at the start of it (BulletPool.prev_pos, so a bullet keeps its own
## history through swap-removals). The engine's MultiMesh physics interpolation
## blends them with Engine.get_physics_interpolation_fraction() every rendered
## frame (RenderingServer.multimesh_set_buffer_interpolated). This needs the
## project setting physics/common/physics_interpolation; without it the renderer
## falls back to plain per-tick uploads.
##
## Only the live part is written and uploaded: the MultiMesh is allocated in
## buckets just above the live bullet count (grow immediately, shrink lazily) and
## visible_instance_count hides the unused tail, instead of always processing a
## buffer sized for the pool capacity. Godot requires the uploaded buffer to be
## exactly instance_count * stride long, so bucket resizing is the only way to
## shrink the upload.

const FLOATS_PER_INSTANCE := 12  # 2x4 transform + RGBA colour
const MIN_INSTANCES := 256
## A bucket is sized to live count * GROW_HEADROOM (rounded up to BUCKET_STEP).
const GROW_HEADROOM := 1.25
const BUCKET_STEP := 256
## Shrink only once the live count falls below this fraction of the bucket.
const SHRINK_BELOW := 0.5

## Visual length multiplier along the direction of travel (1 = round).
@export var stretch := 1.0

## Instances currently allocated in the MultiMesh (the bucket size).
var allocated := 0
## Pool capacity this renderer was set up for (upper bound for `allocated`).
var max_instances := 0
## How many times the MultiMesh was reallocated (for tests / diagnostics).
var reallocations := 0

# Two buffer pairs used alternately (current + previous tick). The RenderingServer
# keeps a reference to the buffers it was last given, so writing into the pair it
# does not hold never triggers a copy-on-write; both pairs are allocated once (in
# _allocate) and nothing is allocated per tick.
var _cur_a := PackedFloat32Array()
var _cur_b := PackedFloat32Array()
var _prev_a := PackedFloat32Array()
var _prev_b := PackedFloat32Array()
var _use_b := false


func setup(capacity: int, world_bounds: Rect2 = Rect2(-4096, -4096, 8192, 8192)) -> void:
	max_instances = capacity
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = quad
	mm.physics_interpolation_quality = MultiMesh.INTERP_QUALITY_FAST
	multimesh = mm
	_allocate(mini(MIN_INSTANCES, capacity))
	mm.visible_instance_count = 0
	# Fixed bounds: no per-frame AABB recomputation or culling surprises.
	var pad := 64.0
	mm.custom_aabb = AABB(
		Vector3(world_bounds.position.x - pad, world_bounds.position.y - pad, -1.0),
		Vector3(world_bounds.size.x + pad * 2.0, world_bounds.size.y + pad * 2.0, 2.0)
	)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://src/bullets/bullet.gdshader")
	material = mat


## Copies the pool's current state into the MultiMesh.
func update_from(pool: BulletPool) -> void:
	var n := pool.count
	_fit_allocation(n)
	var interpolate := is_physics_interpolated_and_enabled()

	# Take the target buffers out of their members so this function holds the only
	# reference; otherwise the first write would copy the whole array.
	var cur: PackedFloat32Array
	var prev: PackedFloat32Array
	if _use_b:
		cur = _cur_b
		prev = _prev_b
		_cur_b = PackedFloat32Array()
		_prev_b = PackedFloat32Array()
	else:
		cur = _cur_a
		prev = _prev_a
		_cur_a = PackedFloat32Array()
		_prev_a = PackedFloat32Array()

	var bpos := pool.pos
	var bold := pool.prev_pos
	var brot := pool.rot
	var brad := pool.radius
	var bcol := pool.color
	var length_scale := 2.0 * stretch
	if interpolate:
		# Both buffers are filled in one pass: the previous-tick instance is the
		# current one with its translation replaced by the tick-start position.
		for i in n:
			var o := i * FLOATS_PER_INSTANCE
			var r := brad[i]
			var d := brot[i]
			var p := bpos[i]
			var q := bold[i]
			var c := bcol[i]
			var sx := r * length_scale
			var sy := r * 2.0
			var m00 := d.x * sx
			var m01 := -d.y * sy
			var m10 := d.y * sx
			var m11 := d.x * sy
			cur[o] = m00
			cur[o + 1] = m01
			cur[o + 3] = p.x
			cur[o + 4] = m10
			cur[o + 5] = m11
			cur[o + 7] = p.y
			cur[o + 8] = c.r
			cur[o + 9] = c.g
			cur[o + 10] = c.b
			cur[o + 11] = c.a
			prev[o] = m00
			prev[o + 1] = m01
			prev[o + 3] = q.x
			prev[o + 4] = m10
			prev[o + 5] = m11
			prev[o + 7] = q.y
			prev[o + 8] = c.r
			prev[o + 9] = c.g
			prev[o + 10] = c.b
			prev[o + 11] = c.a
	else:
		for i in n:
			var o := i * FLOATS_PER_INSTANCE
			var r := brad[i]
			var d := brot[i]
			var p := bpos[i]
			var c := bcol[i]
			var sx := r * length_scale
			var sy := r * 2.0
			cur[o] = d.x * sx
			cur[o + 1] = -d.y * sy
			cur[o + 3] = p.x
			cur[o + 4] = d.y * sx
			cur[o + 5] = d.x * sy
			cur[o + 7] = p.y
			cur[o + 8] = c.r
			cur[o + 9] = c.g
			cur[o + 10] = c.b
			cur[o + 11] = c.a

	var rid := multimesh.get_rid()
	if interpolate:
		RenderingServer.multimesh_set_buffer_interpolated(rid, cur, prev)
	else:
		RenderingServer.multimesh_set_buffer(rid, cur)
	multimesh.visible_instance_count = n

	if _use_b:
		_cur_b = cur
		_prev_b = prev
	else:
		_cur_a = cur
		_prev_a = prev
	_use_b = not _use_b


## Current instance buffer (end of the last tick) for tests.
func get_current_buffer() -> PackedFloat32Array:
	return _cur_a if _use_b else _cur_b


## Previous-tick instance buffer (positions at the start of the last tick) for
## tests. Only filled while physics interpolation is on.
func get_previous_buffer() -> PackedFloat32Array:
	return _prev_a if _use_b else _prev_b


## Bucket size for `live` bullets.
static func bucket_for(live: int, capacity: int) -> int:
	var wanted := ceili(float(live) * GROW_HEADROOM / BUCKET_STEP) * BUCKET_STEP
	return clampi(maxi(wanted, MIN_INSTANCES), 1, capacity)


func _fit_allocation(live: int) -> void:
	if live > allocated or (float(live) < float(allocated) * SHRINK_BELOW and allocated > MIN_INSTANCES):
		_allocate(bucket_for(live, max_instances))


func _allocate(instances: int) -> void:
	if instances == allocated:
		return
	allocated = instances
	reallocations += 1
	multimesh.instance_count = instances
	var floats := instances * FLOATS_PER_INSTANCE
	_cur_a.resize(floats)
	_cur_b.resize(floats)
	_prev_a.resize(floats)
	_prev_b.resize(floats)
	_cur_a.fill(0.0)
	_cur_b.fill(0.0)
	_prev_a.fill(0.0)
	_prev_b.fill(0.0)
