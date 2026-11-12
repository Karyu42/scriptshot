class_name SliceLayout
extends Node2D
## The vertical-slice ribbon (docs/design/vertical-slice.md §2): rooms S, A, B,
## C, D, the E arena and the Hydra alcove, joined by the G1–G5 corridors, plus
## the G0 gate in C's north wall. A child of Main, not streamed by ChunkStream,
## so unloading a chunk never deletes a room.
##
## Geometry. A room rect is the room's outer edge; its walls are WALL_PX thick
## and sit inside it, so every wall stays inside FOOTPRINT and room S's walls
## stay outside the 512 px safe disk. A corridor rect is the clear 128 px
## passage; its side walls sit just outside it (above and below). Doors are
## the corridor's y span cut out of both rooms' walls. A shut gate is a
## GATE_PX (4 px) wall across the middle of its corridor, colour
## Arena.BORDER_COLOR (#3a4152). G0 has no corridor: it is the
## [5200, 5456] segment of C's north wall, WALL_PX thick. The alcove door
## (x [7500, 7628]) is a plain opening in D's south wall and the alcove's north
## wall, always open.
##
## Walls are StaticBody2D rects on the `world` layer in the `world_walls`
## group (what the player collides with), and the same rects are BulletManager
## walls (bind_bullets()). Opening a gate takes its body off the layer and out
## of the group and re-collects the bullet walls on the next idle frame, so a
## gate opened from inside a bullet hook (an elite dying in step()) never edits
## the wall grid mid-sweep.
##
## Hooks for later rows (SliceProgress, Herald redirect, Warden): gate state
## by id (set_gate_open / open_gate / close_gate / is_gate_open + signals),
## room_rect / corridor_rect / room_at by id, and the footprint query
## (in_footprint, FOOTPRINT). This node does not decide when a gate opens.

## Effective state of a gate changed (flag, or force_gates_open).
signal gate_changed(id: StringName, open: bool)
signal gate_opened(id: StringName)
signal gate_closed(id: StringName)

const CELL := 64.0
const WALL_PX := 16.0
const GATE_PX := 4.0
## Debug: `-- --slice-gates-open` on the command line (debug builds) forces
## every gate open, same as force_gates_open.
const CMDLINE_GATES_OPEN := "--slice-gates-open"

const ROOM_S := &"S"
const ROOM_A := &"A"
const ROOM_B := &"B"
const ROOM_C := &"C"
const ROOM_D := &"D"
const ROOM_E := &"E"
const ROOM_ALCOVE := &"alcove"

const GATE_G0 := &"G0"
const GATE_G1 := &"G1"
const GATE_G2 := &"G2"
const GATE_G3 := &"G3"
const GATE_G4 := &"G4"
const GATE_G5 := &"G5"

## Procedural encounter anchors inside this rect are dropped (ChunkStream.footprint).
const FOOTPRINT := Rect2(-768, -1024, 11392, 2688)
const ARENA_CENTRE := Vector2(9664, 0)

const ROOMS: Dictionary[StringName, Rect2] = {
	&"S": Rect2(-768, -576, 1536, 1152),
	&"A": Rect2(1024, -512, 1280, 1024),
	&"B": Rect2(2560, -512, 1280, 1024),
	&"C": Rect2(4096, -1024, 2560, 2048),
	&"D": Rect2(6912, -640, 1536, 1280),
	&"E": Rect2(8704, -704, 1920, 1408),
	&"alcove": Rect2(7104, 640, 1024, 1024),
}

## Corridor id is its gate id. Each joins the rooms either side of it.
const CORRIDORS: Dictionary[StringName, Rect2] = {
	&"G1": Rect2(768, -64, 256, 128),
	&"G2": Rect2(2304, -64, 256, 128),
	&"G3": Rect2(3840, -64, 256, 128),
	&"G4": Rect2(6656, -64, 256, 128),
	&"G5": Rect2(8448, -64, 256, 128),
}

## G0: x span on C's north wall (y = -1024).
const G0_SPAN := Vector2(5200, 5456)
## Alcove door: x span on D's south wall / the alcove's north wall.
const ALCOVE_DOOR_SPAN := Vector2(7500, 7628)

const GATE_IDS: Array[StringName] = [&"G0", &"G1", &"G2", &"G3", &"G4", &"G5"]
const ROOM_IDS: Array[StringName] = [&"S", &"A", &"B", &"C", &"D", &"E", &"alcove"]

const GATE_COLOR := Arena.BORDER_COLOR

## Forces every gate open while true (debug). The per-gate flags are kept, so
## turning it off restores them.
@export var force_gates_open := false:
	set(value):
		if value == force_gates_open:
			return
		var before := _effective_states()
		force_gates_open = value
		_apply_changes(before)
@export var draw_grid := true
## Off: the node builds no walls and Main applies no footprint, so the scene
## is the pre-slice open world (tests and QA rigs that need the origin chunks
## as they were). Set before the node enters the tree.
@export var enabled := true

var _flags: Dictionary[StringName, bool] = {}
var _gate_bodies: Dictionary[StringName, StaticBody2D] = {}
var _walls_body: StaticBody2D
var _bullets: BulletManager
var _bullet_walls_queued := false
var _built := false


func _init() -> void:
	for id in GATE_IDS:
		_flags[id] = false


func _ready() -> void:
	if not enabled:
		visible = false
		return
	if OS.is_debug_build() and OS.get_cmdline_user_args().has(CMDLINE_GATES_OPEN):
		force_gates_open = true
	_build()
	queue_redraw()


# --- static lookups ---------------------------------------------------------------

## Outer rect of room `id` (ROOM_IDS), or an empty Rect2 for an unknown id.
static func room_rect(id: StringName) -> Rect2:
	return ROOMS[id] if ROOMS.has(id) else Rect2()


## Clear passage of the corridor behind gate `id` (G1–G5), or an empty Rect2.
static func corridor_rect(id: StringName) -> Rect2:
	return CORRIDORS[id] if CORRIDORS.has(id) else Rect2()


## Room containing `p` (ROOM_IDS), else the corridor id containing it, else &"".
static func room_at(p: Vector2) -> StringName:
	for id in ROOM_IDS:
		if ROOMS[id].has_point(p):
			return id
	for id: StringName in CORRIDORS:
		if CORRIDORS[id].has_point(p):
			return id
	return &""


## True when `p` lies in the slice footprint (Rect2.has_point: left/top edges
## in, right/bottom edges out).
static func in_footprint(p: Vector2) -> bool:
	return FOOTPRINT.has_point(p)


## The wall rect gate `id` occupies while shut, or an empty Rect2.
static func gate_rect(id: StringName) -> Rect2:
	if id == GATE_G0:
		var c := ROOMS[ROOM_C]
		return Rect2(G0_SPAN.x, c.position.y, G0_SPAN.y - G0_SPAN.x, WALL_PX)
	if not CORRIDORS.has(id):
		return Rect2()
	var r := CORRIDORS[id]
	return Rect2(r.get_center().x - GATE_PX * 0.5, r.position.y, GATE_PX, r.size.y)


## Every fixed wall rect (no gates): room walls with their doors cut out, and
## the corridor side walls. Deterministic, so tests and tools can read it.
static func wall_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for id in ROOM_IDS:
		_room_walls(id, out)
	for id: StringName in CORRIDORS:
		var r := CORRIDORS[id]
		out.append(Rect2(r.position.x, r.position.y - WALL_PX, r.size.x, WALL_PX))
		out.append(Rect2(r.position.x, r.end.y, r.size.x, WALL_PX))
	return out


static func _room_walls(id: StringName, out: Array[Rect2]) -> void:
	var r := ROOMS[id]
	var t := WALL_PX
	# Openings along each side, as spans on that side's axis.
	var north: Array[Vector2] = []
	var south: Array[Vector2] = []
	var west: Array[Vector2] = []
	var east: Array[Vector2] = []
	for cid: StringName in CORRIDORS:
		var c := CORRIDORS[cid]
		var span := Vector2(c.position.y, c.end.y)
		if is_equal_approx(c.end.x, r.position.x):
			west.append(span)
		elif is_equal_approx(c.position.x, r.end.x):
			east.append(span)
	if id == ROOM_C:
		north.append(G0_SPAN)
	if id == ROOM_D:
		south.append(ALCOVE_DOOR_SPAN)
	if id == ROOM_ALCOVE:
		north.append(ALCOVE_DOOR_SPAN)
	for s in _spans(r.position.x, r.end.x, north):
		out.append(Rect2(s.x, r.position.y, s.y - s.x, t))
	for s in _spans(r.position.x, r.end.x, south):
		out.append(Rect2(s.x, r.end.y - t, s.y - s.x, t))
	# Side walls run between the north and south walls.
	for s in _spans(r.position.y + t, r.end.y - t, west):
		out.append(Rect2(r.position.x, s.x, t, s.y - s.x))
	for s in _spans(r.position.y + t, r.end.y - t, east):
		out.append(Rect2(r.end.x - t, s.x, t, s.y - s.x))


## [lo, hi] minus `holes` (each Vector2(a, b)), as solid spans.
static func _spans(lo: float, hi: float, holes: Array[Vector2]) -> Array[Vector2]:
	var sorted: Array[Vector2] = holes.duplicate()
	sorted.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var out: Array[Vector2] = []
	var at := lo
	for h: Vector2 in sorted:
		var a := clampf(h.x, lo, hi)
		var b := clampf(h.y, lo, hi)
		if a > at:
			out.append(Vector2(at, a))
		at = maxf(at, b)
	if hi > at:
		out.append(Vector2(at, hi))
	return out


# --- gates --------------------------------------------------------------------------

## Sets gate `id`'s flag. The gate is open while its flag or force_gates_open
## is set. Emits gate_changed (and gate_opened / gate_closed) when the
## effective state changes. Unknown ids are ignored (push_warning).
func set_gate_open(id: StringName, open: bool) -> void:
	if not _flags.has(id):
		push_warning("SliceLayout: unknown gate %s" % id)
		return
	if _flags[id] == open:
		return
	var before := _effective_states()
	_flags[id] = open
	_apply_changes(before)


func open_gate(id: StringName) -> void:
	set_gate_open(id, true)


func close_gate(id: StringName) -> void:
	set_gate_open(id, false)


## Effective state: the flag, or force_gates_open.
func is_gate_open(id: StringName) -> bool:
	return force_gates_open or (_flags.has(id) and _flags[id])


## The gate's own flag, ignoring force_gates_open.
func gate_flag(id: StringName) -> bool:
	return _flags.has(id) and _flags[id]


## The StaticBody2D of gate `id` (tests, tools), or null.
func gate_body(id: StringName) -> StaticBody2D:
	return _gate_bodies[id] if _gate_bodies.has(id) else null


# --- bullets -------------------------------------------------------------------------

## Makes `manager` collide bullets with the ribbon: re-collects its walls now
## and again whenever a gate changes.
func bind_bullets(manager: BulletManager) -> void:
	_bullets = manager
	flush_bullet_walls()


## Rebuilds the bound manager's walls from the `world_walls` group right away.
## Gate changes call it deferred; tests may call it to skip the frame.
func flush_bullet_walls() -> void:
	_bullet_walls_queued = false
	if _bullets == null or not is_instance_valid(_bullets) or not _bullets.is_inside_tree():
		return
	if _bullets.walls == null:
		return
	_bullets.clear_walls()
	_bullets.collect_walls()


# --- internals ---------------------------------------------------------------------

func _build() -> void:
	if _built:
		return
	_built = true
	_walls_body = _make_body("Walls")
	var i := 0
	for r in wall_rects():
		_add_shape(_walls_body, "Wall%d" % i, r)
		i += 1
	for id in GATE_IDS:
		var body := _make_body("Gate%s" % id)
		_add_shape(body, "Shape", gate_rect(id))
		_gate_bodies[id] = body
		_apply_gate(id, is_gate_open(id))


func _make_body(body_name: String) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = body_name
	body.collision_layer = Layers.WORLD
	body.collision_mask = 0
	body.add_to_group(&"world_walls")
	add_child(body)
	return body


func _add_shape(body: StaticBody2D, shape_name: String, r: Rect2) -> void:
	var shape := RectangleShape2D.new()
	shape.size = r.size
	var node := CollisionShape2D.new()
	node.name = shape_name
	node.shape = shape
	node.position = r.get_center()
	body.add_child(node)


func _effective_states() -> Dictionary[StringName, bool]:
	var out: Dictionary[StringName, bool] = {}
	for id in GATE_IDS:
		out[id] = is_gate_open(id)
	return out


func _apply_changes(before: Dictionary[StringName, bool]) -> void:
	var changed: Array[StringName] = []
	for id in GATE_IDS:
		var now := is_gate_open(id)
		if now != before[id]:
			changed.append(id)
			_apply_gate(id, now)
	if changed.is_empty():
		return
	queue_redraw()
	if _bullets != null and not _bullet_walls_queued:
		_bullet_walls_queued = true
		flush_bullet_walls.call_deferred()
	for id in changed:
		var now := is_gate_open(id)
		gate_changed.emit(id, now)
		if now:
			gate_opened.emit(id)
		else:
			gate_closed.emit(id)


func _apply_gate(id: StringName, open: bool) -> void:
	if not _gate_bodies.has(id):
		return
	var body := _gate_bodies[id]
	# The layer change takes effect at once for the player's motion queries;
	# leaving the group keeps it out of BulletManager.collect_walls().
	body.collision_layer = 0 if open else Layers.WORLD
	if open:
		body.remove_from_group(&"world_walls")
	elif not body.is_in_group(&"world_walls"):
		body.add_to_group(&"world_walls")


func _draw() -> void:
	for id in ROOM_IDS:
		_draw_floor(ROOMS[id])
	for id: StringName in CORRIDORS:
		_draw_floor(CORRIDORS[id])
	for r in wall_rects():
		draw_rect(r, Arena.WALL_COLOR)
		draw_rect(r, Arena.WALL_EDGE_COLOR, false, 2.0)
	for id in GATE_IDS:
		if not is_gate_open(id):
			draw_rect(gate_rect(id), GATE_COLOR)


func _draw_floor(r: Rect2) -> void:
	draw_rect(r, Arena.FLOOR_COLOR)
	if not draw_grid:
		return
	var x := r.position.x
	while x <= r.end.x:
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Arena.GRID_COLOR, 1.0)
		x += CELL
	var y := r.position.y
	while y <= r.end.y:
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), Arena.GRID_COLOR, 1.0)
		y += CELL
