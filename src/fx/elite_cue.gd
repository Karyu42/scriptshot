class_name EliteCue
extends RefCounted
## Common-elite cue (spawning §8.1, first-playable L2, issue #24).
##
## Drawn by the enemy's own `_draw()`: one ring at 1.35× body radius, 3 px
## wide, #F2F2F2, and one orbiting glyph (circle = Spawn, square = Defensive,
## triangle = Offensive). The body outline is 3 px; the fill stays the
## archetype hue. On wake the ring brightens for 0.3 s (width 3 → 5 px and a
## lerp toward white). That brighten is the visual equivalent of the sting and
## does not depend on audio.
##
## Q24 fallbacks that apply to this tier:
## - Rings, glyphs and outlines are `_draw()` primitives. No shader, no
##   post-process, no additive halo (that halo is rare/legendary and is not
##   drawn here).
## - The brighten is a `_process` width/colour pulse. Set `pulse_enabled` false
##   and the ring stays the static 3 px stroke (spawning §8.4).
## - At most 12 elites draw the full cue. Later arrivals keep the 3 px outline
##   only, until they leave the tree and a new one takes the slot. The check
##   is once, when the elite starts drawing.

const RING_RADIUS_MUL := 1.35
const RING_WIDTH := 3.0
const RING_COLOR := Color("F2F2F2")
const OUTLINE_WIDTH := 3.0
const GLYPH_RADIUS := 6.0
const GLYPH_ORBIT_MUL := 1.6
const GLYPH_SPIN_DEG := 90.0
const ARC_POINTS := 32
const BRIGHTEN_SECONDS := 0.3
## Reversible default: the 0.3 s pulse peaks at this stroke width.
const BRIGHTEN_WIDTH := 5.0
const CUE_CAP := 12

const GLYPH_CIRCLE := 0
const GLYPH_SQUARE := 1
const GLYPH_TRIANGLE := 2

## Master switch for the 0.3 s brighten. False = static ring (Q24 pulse fallback).
static var pulse_enabled := true

static var _slots := 0

var angle := 0.0
var brighten_left := 0.0
var drawing_full := false
var glyph := GLYPH_CIRCLE


static func reset_budget() -> void:
	_slots = 0


static func glyph_kind(group: StringName) -> int:
	if group == AffixDef.GROUP_DEFENSIVE:
		return GLYPH_SQUARE
	if group == AffixDef.GROUP_OFFENSIVE:
		return GLYPH_TRIANGLE
	return GLYPH_CIRCLE


static func ring_radius(body_radius: float) -> float:
	return body_radius * RING_RADIUS_MUL


func try_acquire() -> bool:
	if drawing_full:
		return true
	if _slots >= CUE_CAP:
		drawing_full = false
		return false
	_slots += 1
	drawing_full = true
	return true


func release() -> void:
	if not drawing_full:
		return
	drawing_full = false
	_slots = maxi(_slots - 1, 0)


func start_brighten() -> void:
	brighten_left = BRIGHTEN_SECONDS


func advance(delta: float) -> void:
	angle = wrapf(angle + deg_to_rad(GLYPH_SPIN_DEG) * delta, 0.0, TAU)
	if delta > 0.0:
		brighten_left = maxf(brighten_left - delta, 0.0)


func draws_ring() -> bool:
	return drawing_full


func visual_ring_width() -> float:
	if not pulse_enabled or brighten_left <= 0.0:
		return RING_WIDTH
	var k := clampf(brighten_left / BRIGHTEN_SECONDS, 0.0, 1.0)
	return lerpf(RING_WIDTH, BRIGHTEN_WIDTH, k)


func visual_ring_color() -> Color:
	if not pulse_enabled or brighten_left <= 0.0:
		return RING_COLOR
	var k := clampf(brighten_left / BRIGHTEN_SECONDS, 0.0, 1.0)
	return RING_COLOR.lerp(Color.WHITE, k)


func glyph_offset(body_radius: float) -> Vector2:
	return Vector2.from_angle(angle) * body_radius * GLYPH_ORBIT_MUL


## Called from the enemy's `_draw()` only.
func draw_on(canvas: CanvasItem, body_radius: float) -> void:
	if not drawing_full:
		return
	var color := visual_ring_color()
	canvas.draw_arc(
		Vector2.ZERO,
		ring_radius(body_radius),
		0.0,
		TAU,
		ARC_POINTS,
		color,
		visual_ring_width(),
		true
	)
	var at := glyph_offset(body_radius)
	if glyph == GLYPH_SQUARE:
		var r := GLYPH_RADIUS
		canvas.draw_rect(Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), color, true)
	elif glyph == GLYPH_TRIANGLE:
		canvas.draw_colored_polygon(_triangle_points(at, GLYPH_RADIUS), color)
	else:
		canvas.draw_circle(at, GLYPH_RADIUS, color)


static func _triangle_points(centre: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(3)
	for i in 3:
		var a := -PI / 2.0 + TAU * float(i) / 3.0
		pts[i] = centre + Vector2.from_angle(a) * radius
	return pts
