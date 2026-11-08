class_name GridWarpFallback
extends RefCounted
## Compatibility fallback for the boss-chunk grid warp (pillars §8.1, §6.4).
##
## Lines are drawn by the floor's `_draw()` with a CPU vertex offset of at most
## 3 px. There is no post-process, no screen texture, and no shader. If the
## offset path is switched off, the same lines keep their positions and only
## brighten (the "too costly" alternative in the rendering note).
##
## An empty chunk list is the idle state: callers draw the ordinary grid and
## this type is not on the bullet path.


const MAX_OFFSET_PX := 3.0
const MODE_OFFSET := 0
const MODE_PULSE := 1
const PULSE_LIFT := 0.35

static var mode := MODE_OFFSET
static var pulse_phase := 0.0
static var chunks: Array[Rect2] = []


static func reset() -> void:
	chunks.clear()
	mode = MODE_OFFSET
	pulse_phase = 0.0


static func is_idle() -> bool:
	return chunks.is_empty()


static func add_chunk(rect: Rect2) -> void:
	chunks.append(rect)


static func advance(delta: float) -> void:
	pulse_phase = wrapf(pulse_phase + delta * TAU / 1.5, 0.0, TAU)


static func offset_at(point: Vector2) -> Vector2:
	if mode != MODE_OFFSET or chunks.is_empty():
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for chunk in chunks:
		sum += _chunk_offset(point, chunk)
	if sum.length() > MAX_OFFSET_PX:
		return sum.normalized() * MAX_OFFSET_PX
	return sum


static func color_at(point: Vector2, base: Color) -> Color:
	if mode != MODE_PULSE or chunks.is_empty():
		return base
	var lift := 0.0
	for chunk in chunks:
		lift = maxf(lift, _chunk_lift(point, chunk))
	if lift <= 0.0:
		return base
	var wave := 0.5 + 0.5 * sin(pulse_phase)
	return base.lerp(Color.WHITE, lift * wave)


static func draw_grid(canvas: CanvasItem, view: Rect2, base: Color, step: float) -> void:
	if step <= 1.0:
		return
	var x := floorf(view.position.x / step) * step
	while x <= view.end.x:
		_line(canvas, Vector2(x, view.position.y), Vector2(x, view.end.y), base)
		x += step
	var y := floorf(view.position.y / step) * step
	while y <= view.end.y:
		_line(canvas, Vector2(view.position.x, y), Vector2(view.end.x, y), base)
		y += step


static func _line(canvas: CanvasItem, a: Vector2, b: Vector2, base: Color) -> void:
	var oa := offset_at(a)
	var ob := offset_at(b)
	var mid := (a + b) * 0.5
	canvas.draw_line(a + oa, b + ob, color_at(mid, base), 1.0)


static func _chunk_offset(point: Vector2, chunk: Rect2) -> Vector2:
	var centre := chunk.get_center()
	var d := point - centre
	var dist := d.length()
	var reach := maxf(chunk.size.length() * 0.5, 1.0)
	if dist < 0.001 or dist > reach:
		return Vector2.ZERO
	var k := 1.0 - dist / reach
	# sin(pi * k) peaks at 1 halfway out and is 0 at the centre and the rim,
	# so the displacement never exceeds MAX_OFFSET_PX.
	var mag := MAX_OFFSET_PX * sin(PI * k)
	return Vector2(-d.y, d.x) / dist * mag


static func _chunk_lift(point: Vector2, chunk: Rect2) -> float:
	var centre := chunk.get_center()
	var reach := maxf(chunk.size.length() * 0.5, 1.0)
	var dist := point.distance_to(centre)
	if dist > reach:
		return 0.0
	return PULSE_LIFT * (1.0 - dist / reach)
