class_name BulletRenderer
extends MultiMeshInstance2D
## Draws every alive bullet of a BulletPool with a single MultiMesh (one draw
## call, one buffer upload per frame, zero nodes per bullet). Bullets are flat
## coloured discs/ellipses produced by bullet.gdshader.

const FLOATS_PER_INSTANCE := 12  # 2x4 transform + RGBA colour

## Visual length multiplier along the direction of travel (1 = round).
@export var stretch := 1.0

var _buffer := PackedFloat32Array()


func setup(capacity: int) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = capacity
	mm.visible_instance_count = 0
	multimesh = mm
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://src/bullets/bullet.gdshader")
	material = mat
	_buffer.resize(capacity * FLOATS_PER_INSTANCE)
	_buffer.fill(0.0)


## Copies the pool's current state into the MultiMesh.
func update_from(pool: BulletPool) -> void:
	var n := pool.count
	var bpos := pool.pos
	var brot := pool.rot
	var brad := pool.radius
	var bcol := pool.color
	# Take the buffer out of the member so we hold the only reference;
	# otherwise the first write would copy the whole array.
	var buf := _buffer
	_buffer = PackedFloat32Array()
	var length_scale := 2.0 * stretch
	for i in n:
		var o := i * FLOATS_PER_INSTANCE
		var r := brad[i]
		var d := brot[i]
		var p := bpos[i]
		var c := bcol[i]
		var sx := r * length_scale
		var sy := r * 2.0
		buf[o] = d.x * sx
		buf[o + 1] = -d.y * sy
		buf[o + 3] = p.x
		buf[o + 4] = d.y * sx
		buf[o + 5] = d.x * sy
		buf[o + 7] = p.y
		buf[o + 8] = c.r
		buf[o + 9] = c.g
		buf[o + 10] = c.b
		buf[o + 11] = c.a
	RenderingServer.multimesh_set_buffer(multimesh.get_rid(), buf)
	multimesh.visible_instance_count = n
	_buffer = buf
