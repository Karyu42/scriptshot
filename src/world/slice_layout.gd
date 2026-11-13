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
## the wall grid mid-sweep. Closing a gate flushes the bullet walls in the
## same call, so a shot on this frame already meets the shut gate. A body
## standing in the doorway is pushed to the side it came from, or the
## nearest open side, so it is not trapped in the new wall.
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
## Where the Herald goes when its point would land in a walled room (§2, §10
## row 6): room C, beside the Drifter pack.
const HERALD_REDIRECT := Vector2(4700, 180)

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
## as they were). Set before the node enters the tree and do not toggle it
## later: EliteEnemy snapshots collide_walls from this flag in `_ready`.
@export var enabled := true

var _flags: Dictionary[StringName, bool] = {}
var _gate_bodies: Dictionary[StringName, StaticBody2D] = {}
var _walls_body: StaticBody2D
var _bullets: BulletManager
var _bullet_walls_queued := false
var _built := false
var _walls_cached: Array[Rect2] = []


func _init() -> void:
	for id in GATE_IDS:
		_flags[id] = false


func _ready() -> void:
	if not enabled:
		visible = false
		return
	# Elites look this group up so they skip the world-layer query when the
	# ribbon is off (no walls to stay out of).
	add_to_group(&"slice_layouts")
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


## Closes a gate and, if a BulletManager is bound, flushes bullet walls in
## this same call so a shot this tick already meets the shut gate.
##
## Lesson gates (row 5) only open; SliceProgress never calls this, and nothing
## in the slice closes a gate from inside `walls.sweep_bullets`. If a future
## closer ever runs mid-sweep, defer the flush to the end of
## `BulletManager.step()` in the same frame instead of calling it here.
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


# --- Herald redirect (§2 "Herald clamp", §10 row 6) ------------------------------

## The Herald's spawn point for `p` (a body of `radius`).
##
## While G0 is shut (before the Warden; the GD ruling on #81: the slice's
## Herald spawns in walled room C), only a point in open C is kept. Every other
## point redirects to HERALD_REDIRECT: outside the footprint, the open ground
## between rooms, S, A, B, D, E, the alcove, a corridor, or a body touching a
## slice wall or shut gate.
##
## Once G0 is open (is_gate_open, so the debug force counts too), a point in
## open C or outside the rooms (outside the footprint, or the open ground
## between rooms) is kept, and only walled rooms, corridors and wall contact
## redirect.
func redirect_herald(p: Vector2, radius: float) -> Vector2:
	if not p.is_finite():
		return HERALD_REDIRECT
	if touches_wall(p, radius):
		return HERALD_REDIRECT
	var room := room_at(p)
	if room == ROOM_C:
		return p
	if not is_gate_open(GATE_G0):
		return HERALD_REDIRECT
	if room == &"":
		return p
	return HERALD_REDIRECT


## True when a circle at `p` of `radius` overlaps a fixed wall or a shut gate.
func touches_wall(p: Vector2, radius: float) -> bool:
	if not FOOTPRINT.grow(radius).has_point(p):
		return false
	for r in _wall_cache():
		if _circle_hits(p, radius, r):
			return true
	for id in GATE_IDS:
		if not is_gate_open(id) and _circle_hits(p, radius, gate_rect(id)):
			return true
	return false


static func _circle_hits(p: Vector2, radius: float, r: Rect2) -> bool:
	var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
	return q.distance_squared_to(p) < radius * radius


func _wall_cache() -> Array[Rect2]:
	if _walls_cached.is_empty():
		_walls_cached = wall_rects()
	return _walls_cached


# --- bullets -------------------------------------------------------------------------

## Makes `manager` collide bullets with the ribbon: re-collects its walls now
## and again whenever a gate changes.
func bind_bullets(manager: BulletManager) -> void:
	_bullets = manager
	flush_bullet_walls()


## Rebuilds the bound manager's walls from the `world_walls` group right away.
## A close calls it in the same frame; an open defers it so a hook mid-step
## never edits the grid during the sweep. Tests may call it to skip the frame.
## Safe here because lesson / debug closes happen outside `walls.sweep_bullets`.
## A close issued mid-sweep must instead flush at the end of `BulletManager.step()`.
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
	var any_closed := false
	for id in GATE_IDS:
		var now := is_gate_open(id)
		if now != before[id]:
			changed.append(id)
			_apply_gate(id, now)
			if not now:
				any_closed = true
				_eject_from_gate(id)
	if changed.is_empty():
		return
	queue_redraw()
	if _bullets != null:
		if any_closed:
			# Same frame: a shot this tick must already meet the shut gate.
			flush_bullet_walls()
		elif not _bullet_walls_queued:
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


## Pushes a player or enemy overlapping shut gate `id` out of it: the side
## they were moving from, or the nearest clear side when they were at rest
## (QA #84: force_gates_open, stand at (896, 0), then set it false).
func _eject_from_gate(id: StringName) -> void:
	var gate := gate_rect(id)
	if not gate.has_area():
		return
	var parent := get_parent()
	if parent != null:
		for child: Node in parent.get_children():
			var player := child as Player
			if player != null:
				_eject_node(player, _player_radius(player), player.velocity, gate)
	if not is_inside_tree():
		return
	for node: Node in get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var body := node as RegularEnemy
		if body == null or not is_instance_valid(body) or not body.is_alive():
			continue
		_eject_node(body, body.body_radius, body.last_displacement, gate)


func _player_radius(player: Player) -> float:
	var node := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if node != null and node.shape is CircleShape2D:
		return (node.shape as CircleShape2D).radius
	return 13.0


func _eject_node(node: Node2D, radius: float, motion: Vector2, gate: Rect2) -> void:
	var pos := node.global_position
	if not _circle_hits(pos, radius, gate):
		return
	node.global_position = _eject_point(pos, radius, motion, gate)


## Just clear of `gate` along its through-axis (X for G1–G5, Y for G0).
## Prefers the side the body came from, or the nearest side when motion is
## ~zero. If that landing overlaps a solid, tries the other side; if both
## are blocked, leaves `pos` unchanged. Never pushes a body into a solid.
func _eject_point(pos: Vector2, radius: float, motion: Vector2, gate: Rect2) -> Vector2:
	var along_x := gate.size.y >= gate.size.x
	var lo := gate.position.x if along_x else gate.position.y
	var hi := gate.end.x if along_x else gate.end.y
	var at := pos.x if along_x else pos.y
	var move := motion.x if along_x else motion.y
	var clear_lo := lo - radius - 0.01
	var clear_hi := hi + radius + 0.01
	var pick_lo: bool
	if absf(move) > 0.001:
		# Moving toward + came from the low side; send them back.
		pick_lo = move > 0.0
	else:
		pick_lo = absf(at - clear_lo) <= absf(at - clear_hi)
	var cand_lo := pos
	var cand_hi := pos
	if along_x:
		cand_lo.x = clear_lo
		cand_hi.x = clear_hi
	else:
		cand_lo.y = clear_lo
		cand_hi.y = clear_hi
	var preferred := cand_lo if pick_lo else cand_hi
	var other := cand_hi if pick_lo else cand_lo
	if not _eject_blocked(preferred, radius, gate):
		return preferred
	if not _eject_blocked(other, radius, gate):
		return other
	return pos


## True when a circle at `pos` overlaps a ribbon wall, another shut gate, or
## an extra `world_walls` body. The closing `skip_gate` itself is ignored
## (the body is already in it and we are trying to leave).
func _eject_blocked(pos: Vector2, radius: float, skip_gate: Rect2) -> bool:
	for r in _solid_rects_for_eject(skip_gate):
		if _circle_hits(pos, radius, r):
			return true
	return false


func _solid_rects_for_eject(skip_gate: Rect2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r in _wall_cache():
		out.append(r)
	for id: StringName in GATE_IDS:
		if is_gate_open(id):
			continue
		var g := gate_rect(id)
		if _same_rect(g, skip_gate):
			continue
		out.append(g)
	if not is_inside_tree():
		return out
	for node: Node in get_tree().get_nodes_in_group(&"world_walls"):
		if node == _walls_body or _is_own_gate_body(node):
			continue
		for child: Node in node.get_children():
			var cs := child as CollisionShape2D
			if cs == null or cs.disabled or not (cs.shape is RectangleShape2D):
				continue
			var size := (cs.shape as RectangleShape2D).size
			var centre := cs.global_position
			out.append(Rect2(centre - size * 0.5, size))
	return out


func _is_own_gate_body(node: Node) -> bool:
	for id: StringName in GATE_IDS:
		if _gate_bodies.get(id) == node:
			return true
	return false


static func _same_rect(a: Rect2, b: Rect2) -> bool:
	return a.position.is_equal_approx(b.position) and a.size.is_equal_approx(b.size)


func _draw() -> void:
	for id in ROOM_IDS:
		_draw_floor(ROOMS[id])
	for id: StringName in CORRIDORS:
		_draw_floor(CORRIDORS[id])
	for r in _wall_cache():
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
