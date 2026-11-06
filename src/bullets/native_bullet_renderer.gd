class_name NativeBulletRenderer
extends MultiMeshInstance2D
## Draws the bullets simulated by NativeBackend with one MultiMesh. The C++ side
## fills and uploads the (interpolated) instance buffers; this node only owns
## the MultiMesh, its bucketed instance_count and visible_instance_count. Same
## look as BulletRenderer (bullet.gdshader).

const FLOATS_PER_INSTANCE := 12
const MIN_INSTANCES := 256
const GROW_HEADROOM := 1.25
const BUCKET_STEP := 256
const SHRINK_BELOW := 0.5

@export var stretch := 1.0

var allocated := 0
var max_instances := 0


func setup(capacity: int, world_bounds: Rect2) -> void:
	max_instances = capacity
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = quad
	mm.physics_interpolation_quality = MultiMesh.INTERP_QUALITY_FAST
	multimesh = mm
	allocated = 0
	_allocate(mini(MIN_INSTANCES, capacity))
	mm.visible_instance_count = 0
	var pad := 64.0
	mm.custom_aabb = AABB(
		Vector3(world_bounds.position.x - pad, world_bounds.position.y - pad, -1.0),
		Vector3(world_bounds.size.x + pad * 2.0, world_bounds.size.y + pad * 2.0, 2.0)
	)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://src/bullets/bullet.gdshader")
	material = mat


func update_from(backend: NativeBackend) -> void:
	var live := backend.count()
	if live > allocated or (float(live) < float(allocated) * SHRINK_BELOW and allocated > MIN_INSTANCES):
		_allocate(bucket_for(live, max_instances))
	var shown := backend.upload(multimesh.get_rid(), allocated, is_physics_interpolated_and_enabled(), stretch)
	multimesh.visible_instance_count = shown


static func bucket_for(live: int, capacity: int) -> int:
	var wanted := ceili(float(live) * GROW_HEADROOM / BUCKET_STEP) * BUCKET_STEP
	return clampi(maxi(wanted, MIN_INSTANCES), 1, capacity)


func _allocate(instances: int) -> void:
	if instances == allocated:
		return
	allocated = instances
	multimesh.instance_count = instances
