class_name RarityCue
extends RefCounted
## Tier-driven rarity cue (spawning §8, pillars §8.1 rendering note, issue #24).
##
## Entity code calls setup(tier) and draw_on() from its own `_draw()`. Tiers that
## gameplay does not spawn yet (rare/legendary elites, bosses) are fully
## described here and exercised by tests and RarityPreview. This does not roll
## or spawn those tiers.
##
## The additive halo is legendary-only (spawning §8.4, Chief of Staff
## 2026-11-08). Rare keeps the double ring, three ticks, and 4 px outline.
## `force_halo` is a debug preview only; play never sets it. Bosses draw the
## glow fallback disc (pillars §8.1): a larger low-alpha disc, no bloom.


const TIER_ELITE_COMMON := 0
const TIER_ELITE_RARE := 1
const TIER_ELITE_LEGENDARY := 2
const TIER_BOSS_COMMON := 3
const TIER_BOSS_RARE := 4
const TIER_BOSS_LEGENDARY := 5
const TIER_COUNT := 6

const RING_RADIUS_MUL := 1.35
const RARE_OUTER_MUL := 1.58
const RING_WIDTH := 3.0
const RING_COLOR := Color("F2F2F2")
const RARE_COLOR := Color("4DE1FF")
const LEGENDARY_COLOR := Color("FFB347")
const OUTLINE_WIDTH := 3.0
const OUTLINE_COLOR := Color("E7E9EE")
const GLYPH_RADIUS := 6.0
const GLYPH_ORBIT_MUL := 1.6
const GLYPH_SPIN_DEG := 90.0
const ARC_POINTS := 32
const BRIGHTEN_SECONDS := 0.3
const BRIGHTEN_WIDTH := 5.0
const CUE_CAP := 12
const TICK_SIZE := 9.0
const PULSE_PERIOD := 1.5
const PULSE_WIDTH_MIN := 3.0
const PULSE_WIDTH_MAX := 5.0
const NAME_SECONDS := 2.0
const RARE_TELEGRAPH_MUL := 1.2
const BOSS_TELEGRAPH_LIFT := 0.35
const EXTRA_OUTLINE_GAP := 5.0
const LEGENDARY_HALO_MUL := 2.05
const LEGENDARY_HALO_ALPHA := 0.18
const BOSS_GLOW_MUL := 2.85
const BOSS_GLOW_ALPHA := 0.12
const FALLBACK_OUTLINE_BONUS := 1.0
const FALLBACK_OUTLINE_LIFT := 0.55

const HALO_NONE := 0
const HALO_LEGENDARY := 1
const HALO_BOSS_GLOW := 2

const GLYPH_CIRCLE := 0
const GLYPH_SQUARE := 1
const GLYPH_TRIANGLE := 2
const GLYPH_DIAMOND := 3

## Master switch for the 0.3 s brighten and the 1.5 s legendary pulse.
static var pulse_enabled := true
## Master switch for BLEND_MODE_ADD. False = normal alpha disc + brighter outline.
static var halo_add_enabled := true

static var _slots := 0

var tier := TIER_ELITE_COMMON
var angle := 0.0
var brighten_left := 0.0
var name_left := 0.0
var drawing_full := false
var glyph := GLYPH_CIRCLE
var glyphs: Array[int] = []
var signature_name := ""
var boss_hue := Color("F28FD0")
## Debug-only. Off in play. Does not give rare elites a halo.
var force_halo := false
var body_radius := 16.0

var _spec: Spec
var _pulse_t := 0.0
var _holds_slot := false
var _host: Node2D
var _halo: HaloDisc
var _material: CanvasItemMaterial


class Spec:
	extends RefCounted
	var rings := 1
	var ring_muls := PackedFloat32Array()
	var ring_width := 3.0
	var ticks := 0
	var outline := 3.0
	var extra_outline := false
	var accent := Color("F2F2F2")
	var glyph_count := 1
	var signature := false
	var pulse_period := 0.0
	var pulse_outline := false
	var halo := 0
	var name_seconds := 0.0


	static func make() -> Spec:
		return Spec.new()


static func reset_budget() -> void:
	_slots = 0


static func slot_count() -> int:
	return _slots


static func glyph_kind(group: StringName) -> int:
	if group == AffixDef.GROUP_DEFENSIVE:
		return GLYPH_SQUARE
	if group == AffixDef.GROUP_OFFENSIVE:
		return GLYPH_TRIANGLE
	return GLYPH_CIRCLE


static func ring_radius(p_body_radius: float) -> float:
	return p_body_radius * RING_RADIUS_MUL


static func _spec_for(p_tier: int) -> Spec:
	var spec := Spec.make()
	spec.ring_muls = PackedFloat32Array([RING_RADIUS_MUL])
	match p_tier:
		TIER_ELITE_COMMON:
			spec.rings = 1
			spec.ring_width = RING_WIDTH
			spec.ticks = 0
			spec.outline = OUTLINE_WIDTH
			spec.accent = RING_COLOR
			spec.glyph_count = 1
		TIER_ELITE_RARE:
			spec.rings = 2
			spec.ring_muls = PackedFloat32Array([RING_RADIUS_MUL, RARE_OUTER_MUL])
			spec.ring_width = 4.0
			spec.ticks = 3
			spec.outline = 4.0
			spec.accent = RARE_COLOR
			spec.glyph_count = 2
		TIER_ELITE_LEGENDARY:
			spec.rings = 1
			spec.ring_width = 5.0
			spec.ticks = 4
			spec.outline = 5.0
			spec.accent = LEGENDARY_COLOR
			spec.glyph_count = 1
			spec.signature = true
			spec.pulse_period = PULSE_PERIOD
			spec.halo = HALO_LEGENDARY
			spec.name_seconds = NAME_SECONDS
		TIER_BOSS_COMMON:
			spec.rings = 0
			spec.ring_muls = PackedFloat32Array()
			spec.ticks = 0
			spec.outline = OUTLINE_WIDTH
			spec.glyph_count = 0
			spec.halo = HALO_BOSS_GLOW
		TIER_BOSS_RARE:
			spec.rings = 1
			spec.ring_width = 4.0
			spec.ticks = 0
			spec.outline = OUTLINE_WIDTH
			spec.extra_outline = true
			spec.accent = RARE_COLOR
			spec.glyph_count = 0
			spec.halo = HALO_BOSS_GLOW
		_:
			spec.rings = 1
			spec.ring_width = 5.0
			spec.ticks = 4
			spec.outline = PULSE_WIDTH_MIN
			spec.accent = LEGENDARY_COLOR
			spec.glyph_count = 0
			spec.pulse_period = PULSE_PERIOD
			spec.pulse_outline = true
			spec.halo = HALO_BOSS_GLOW
	return spec


func _init() -> void:
	setup(TIER_ELITE_COMMON)


func setup(p_tier: int) -> void:
	tier = clampi(p_tier, 0, TIER_COUNT - 1)
	_spec = _spec_for(tier)


## Draw the full cue without taking one of the 12 gameplay slots.
## The debug gallery uses this so a preview cannot starve a real elite.
func present() -> void:
	if _spec == null:
		setup(tier)
	drawing_full = true
	_holds_slot = false


func try_acquire() -> bool:
	if _spec == null:
		setup(tier)
	if drawing_full:
		return true
	if tier >= TIER_BOSS_COMMON:
		drawing_full = true
		_holds_slot = false
		return true
	if _slots >= CUE_CAP:
		drawing_full = false
		return false
	_slots += 1
	_holds_slot = true
	drawing_full = true
	return true


func release() -> void:
	if _holds_slot:
		_slots = maxi(_slots - 1, 0)
		_holds_slot = false
	drawing_full = false
	detach()


func attach(host: Node2D) -> void:
	_host = host
	_ensure_halo()


func detach() -> void:
	_free_halo()
	_host = null


func halo_node() -> HaloDisc:
	return _halo


func halo_material() -> Material:
	return _material


func start_brighten() -> void:
	brighten_left = BRIGHTEN_SECONDS
	if _spec != null and _spec.name_seconds > 0.0 and signature_name != "":
		name_left = _spec.name_seconds


func advance(delta: float) -> void:
	angle = wrapf(angle + deg_to_rad(GLYPH_SPIN_DEG) * delta, 0.0, TAU)
	if delta > 0.0:
		brighten_left = maxf(brighten_left - delta, 0.0)
		name_left = maxf(name_left - delta, 0.0)
		if _spec != null and _spec.pulse_period > 0.0:
			_pulse_t = fposmod(_pulse_t + delta, _spec.pulse_period)
	_sync_halo()


func draws_ring() -> bool:
	return drawing_full


func ring_count() -> int:
	return 0 if _spec == null else _spec.rings


func ring_mul(index: int) -> float:
	if _spec == null or index < 0 or index >= _spec.ring_muls.size():
		return 0.0
	return _spec.ring_muls[index]


func tick_count() -> int:
	return 0 if _spec == null else _spec.ticks


func outline_base() -> float:
	return OUTLINE_WIDTH if _spec == null else _spec.outline


func accent() -> Color:
	return RING_COLOR if _spec == null else _spec.accent


func pulse_period() -> float:
	return 0.0 if _spec == null else _spec.pulse_period


func halo_kind() -> int:
	if force_halo and (_spec == null or _spec.halo == HALO_NONE):
		return HALO_LEGENDARY
	return HALO_NONE if _spec == null else _spec.halo


func glyph_slot_count() -> int:
	return 0 if _spec == null else _spec.glyph_count


func has_extra_outline() -> bool:
	return _spec != null and _spec.extra_outline


func draws_signature() -> bool:
	return _spec != null and _spec.signature


func draws_halo() -> bool:
	if not drawing_full:
		return false
	return force_halo or (_spec != null and _spec.halo != HALO_NONE)


func blend_mode() -> int:
	if halo_add_enabled:
		return CanvasItemMaterial.BLEND_MODE_ADD
	return CanvasItemMaterial.BLEND_MODE_MIX


func _pulse_01() -> float:
	if _spec == null or _spec.pulse_period <= 0.0:
		return 0.0
	return 0.5 - 0.5 * cos(TAU * _pulse_t / _spec.pulse_period)


func visual_ring_width() -> float:
	var base := RING_WIDTH if _spec == null else _spec.ring_width
	if pulse_enabled and brighten_left > 0.0:
		var k := clampf(brighten_left / BRIGHTEN_SECONDS, 0.0, 1.0)
		return lerpf(base, maxf(base, BRIGHTEN_WIDTH), k)
	if pulse_enabled and _spec != null and _spec.pulse_period > 0.0 and not _spec.pulse_outline:
		return lerpf(PULSE_WIDTH_MIN, PULSE_WIDTH_MAX, _pulse_01())
	return base


func visual_ring_color() -> Color:
	var base := accent()
	if not pulse_enabled or brighten_left <= 0.0:
		return base
	var k := clampf(brighten_left / BRIGHTEN_SECONDS, 0.0, 1.0)
	return base.lerp(Color.WHITE, k)


func current_outline_width() -> float:
	var w := outline_base()
	if pulse_enabled and _spec != null and _spec.pulse_outline:
		w = lerpf(PULSE_WIDTH_MIN, PULSE_WIDTH_MAX, _pulse_01())
	if not halo_add_enabled and draws_halo():
		w += FALLBACK_OUTLINE_BONUS
	return w


func outline_color() -> Color:
	if not halo_add_enabled and draws_halo():
		return OUTLINE_COLOR.lerp(Color.WHITE, FALLBACK_OUTLINE_LIFT)
	return OUTLINE_COLOR


func telegraph_color(base: Color) -> Color:
	var mul := 1.0
	if tier == TIER_ELITE_RARE:
		mul = RARE_TELEGRAPH_MUL
	var c := Color(
		minf(base.r * mul, 1.0),
		minf(base.g * mul, 1.0),
		minf(base.b * mul, 1.0),
		base.a
	)
	if tier >= TIER_BOSS_COMMON:
		c = c.lerp(Color.WHITE, BOSS_TELEGRAPH_LIFT)
	return c


func telegraph_outline_width(base_width: float) -> float:
	if tier >= TIER_BOSS_COMMON:
		return base_width + 1.0
	return base_width


func beacon_tick_count() -> int:
	match tier:
		TIER_BOSS_COMMON, TIER_BOSS_LEGENDARY:
			return 1
		TIER_BOSS_RARE:
			return 2
		_:
			return 0


func beacon_color() -> Color:
	if tier == TIER_BOSS_LEGENDARY:
		var amber := LEGENDARY_COLOR
		if pulse_enabled:
			return amber.lerp(Color.WHITE, _pulse_01())
		return amber
	return boss_hue


func glyph_offset(p_body_radius: float) -> Vector2:
	return Vector2.from_angle(angle) * p_body_radius * GLYPH_ORBIT_MUL


func halo_radius(p_body_radius: float) -> float:
	var mul := BOSS_GLOW_MUL if halo_kind() == HALO_BOSS_GLOW else LEGENDARY_HALO_MUL
	return p_body_radius * mul


func halo_alpha() -> float:
	return BOSS_GLOW_ALPHA if halo_kind() == HALO_BOSS_GLOW else LEGENDARY_HALO_ALPHA


func halo_tint() -> Color:
	if halo_kind() == HALO_BOSS_GLOW:
		return boss_hue
	return accent()


## Called from the enemy's `_draw()` only. The halo disc is a child canvas item
## because Godot's blend mode is per item, not per draw call.
func draw_on(canvas: CanvasItem, p_body_radius: float) -> void:
	body_radius = p_body_radius
	_sync_halo()
	if not drawing_full or _spec == null:
		return
	var color := visual_ring_color()
	var width := visual_ring_width()
	for i in _spec.ring_muls.size():
		canvas.draw_arc(
			Vector2.ZERO,
			p_body_radius * _spec.ring_muls[i],
			0.0,
			TAU,
			ARC_POINTS,
			color,
			width,
			true
		)
	if _spec.ticks > 0:
		var outer_mul := RING_RADIUS_MUL
		if _spec.ring_muls.size() > 0:
			outer_mul = _spec.ring_muls[_spec.ring_muls.size() - 1]
		var outer := p_body_radius * outer_mul
		for i in _spec.ticks:
			var a := -PI / 2.0 + TAU * float(i) / float(_spec.ticks)
			canvas.draw_colored_polygon(_tick_points(Vector2.from_angle(a), outer, TICK_SIZE), color)
	if _spec.extra_outline:
		canvas.draw_arc(
			Vector2.ZERO,
			p_body_radius + EXTRA_OUTLINE_GAP,
			0.0,
			TAU,
			ARC_POINTS,
			outline_color(),
			current_outline_width(),
			true
		)
	var kinds := _glyph_list()
	for i in kinds.size():
		var at := _glyph_at(p_body_radius, i, kinds.size())
		_draw_glyph(canvas, kinds[i], at, color)
	if name_left > 0.0 and signature_name != "":
		_draw_name(canvas, p_body_radius, color)


func draw_beacon(canvas: CanvasItem, origin: Vector2, direction: Vector2) -> void:
	var n := beacon_tick_count()
	if n <= 0:
		return
	var dir := direction
	if dir.length_squared() < 0.000001:
		dir = Vector2.UP
	else:
		dir = dir.normalized()
	var ortho := Vector2(-dir.y, dir.x)
	var col := beacon_color()
	for i in n:
		var side := (float(i) - float(n - 1) * 0.5) * 6.0
		var from := origin + ortho * side
		canvas.draw_line(from, from + dir * 16.0, col, 2.0, true)


func _glyph_list() -> Array[int]:
	var out: Array[int] = []
	if _spec == null:
		return out
	if _spec.signature:
		out.append(GLYPH_DIAMOND)
		return out
	if _spec.glyph_count <= 0:
		return out
	if _spec.glyph_count == 1:
		out.append(glyph)
		return out
	var first := glyph
	var second := glyph
	if glyphs.size() >= 1:
		first = glyphs[0]
	if glyphs.size() >= 2:
		second = glyphs[1]
	out.append(first)
	out.append(second)
	return out


func _glyph_at(p_body_radius: float, index: int, count: int) -> Vector2:
	var a := angle + TAU * float(index) / float(maxi(count, 1))
	return Vector2.from_angle(a) * p_body_radius * GLYPH_ORBIT_MUL


func _draw_glyph(canvas: CanvasItem, kind: int, at: Vector2, color: Color) -> void:
	if kind == GLYPH_SQUARE:
		var r := GLYPH_RADIUS
		canvas.draw_rect(Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), color, true)
	elif kind == GLYPH_TRIANGLE:
		canvas.draw_colored_polygon(_triangle_points(at, GLYPH_RADIUS), color)
	elif kind == GLYPH_DIAMOND:
		canvas.draw_colored_polygon(_diamond_points(at, GLYPH_RADIUS), color)
	else:
		canvas.draw_circle(at, GLYPH_RADIUS, color)


func _draw_name(canvas: CanvasItem, p_body_radius: float, color: Color) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	canvas.draw_string(
		font,
		Vector2(-80.0, p_body_radius + 18.0),
		signature_name,
		HORIZONTAL_ALIGNMENT_CENTER,
		160.0,
		ThemeDB.fallback_font_size,
		color
	)


func _ensure_halo() -> void:
	if not draws_halo() or _host == null:
		_free_halo()
		return
	if _halo != null and is_instance_valid(_halo):
		_apply_material()
		_sync_halo()
		return
	_material = CanvasItemMaterial.new()
	_halo = HaloDisc.new()
	_halo.name = "RarityHalo"
	_halo.show_behind_parent = true
	_halo.z_index = -1
	_apply_material()
	_host.add_child(_halo)
	_sync_halo()


func _apply_material() -> void:
	if _material == null or _halo == null:
		return
	_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD if halo_add_enabled else CanvasItemMaterial.BLEND_MODE_MIX
	_halo.material = _material


func _sync_halo() -> void:
	if _halo == null or not is_instance_valid(_halo):
		return
	if not draws_halo():
		_free_halo()
		return
	var tint := halo_tint()
	_halo.disc_radius = halo_radius(body_radius)
	_halo.disc_color = Color(tint.r, tint.g, tint.b, halo_alpha())
	_halo.queue_redraw()


func _free_halo() -> void:
	var node := _halo
	_halo = null
	_material = null
	if node != null and is_instance_valid(node):
		node.material = null
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		node.free()


static func _tick_points(direction: Vector2, ring_r: float, size: float) -> PackedVector2Array:
	var outward := direction.normalized()
	var side := Vector2(-outward.y, outward.x)
	var tip := outward * (ring_r + size)
	var base := outward * (ring_r - size * 0.15)
	var pts := PackedVector2Array()
	pts.resize(3)
	pts[0] = tip
	pts[1] = base + side * size * 0.55
	pts[2] = base - side * size * 0.55
	return pts


static func _triangle_points(centre: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(3)
	for i in 3:
		var a := -PI / 2.0 + TAU * float(i) / 3.0
		pts[i] = centre + Vector2.from_angle(a) * radius
	return pts


static func _diamond_points(centre: Vector2, radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(4)
	for i in 4:
		var a := -PI / 2.0 + TAU * float(i) / 4.0
		pts[i] = centre + Vector2.from_angle(a) * radius
	return pts
