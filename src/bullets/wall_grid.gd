class_name WallGrid
extends RefCounted
## Static axis-aligned wall rectangles (the `world` layer) for bullet collision.
##
## Walls change rarely, so they are bucketed once into a uniform grid (rebuild()
## after add_wall()/clear_walls()). Each tick sweep_bullets() tests only the walls
## in the cells a bullet's path touches, so bullets far from any wall cost one
## array lookup.
##
## A bullet is the segment prev_pos -> pos of a circle of its radius; that is
## tested as a segment against the wall inflated by the radius (a rectangle with
## square corners, which is conservative by at most ~0.41 * radius at a corner).
## A bullet that starts a tick inside a wall (spawned inside one) counts as
## hitting it at t = 0.
##
## Walls are bucketed into every cell within (largest bullet radius + SHORT_PATH)
## of them, which lets a bullet that moved less than SHORT_PATH this tick be
## checked with one cell lookup at its end position; only the rare faster bullets
## walk the cells under their whole path.
##
## Every hit can also report the wall's **surface normal** at the impact (a unit
## vector pointing out of the wall, towards where the bullet came from): the
## face of the radius-inflated wall the path entered through. It is deterministic
## at corners: when the path enters two faces at the same instant (a perfectly
## diagonal approach), the face on the axis the bullet moves faster along wins,
## and the x face wins an exact tie. A bullet that starts inside a wall gets the
## face it is closest to (ties: left, right, top, bottom).

## Paths shorter than this (pixels per tick) use the single-cell fast path.
const SHORT_PATH := 24.0

var bounds := Rect2()
var cell_size := 64.0
var cols := 0
var rows := 0
var wall_count := 0
var walls: Array[Rect2] = []
## The same walls as corner arrays for the hot loop.
var _lo := PackedVector2Array()
var _hi := PackedVector2Array()

var _inv_cell := 1.0
var _origin := Vector2.ZERO
var _max_radius := 0.0
var _heads := PackedInt32Array()
var _entry_next := PackedInt32Array()
var _entry_wall := PackedInt32Array()
var _dirty := true
## Wall index (and its corners) of the best hit of the last _best_hit() call.
var _best_wall := -1
var _best_lo := Vector2.ZERO
var _best_hi := Vector2.ZERO

# Results of the last sweep_bullets() call (parallel arrays, valid up to
# hit_count). hit_t is the fraction of the bullet's path (prev_pos -> pos) at
# which it touched the wall; BulletManager moves the bullet to that point.
var hit_count := 0
var hit_bullets := PackedInt32Array()
var hit_t := PackedFloat32Array()
## Which wall each hit touched, and the bullet's path delta (pos - prev_pos before
## BulletManager clips it). The surface normal is derived from these on demand by
## normal_of_hit(): computing it for every hit would cost more than the sweep
## itself saves, and most hits never ask for it.
var hit_wall := PackedInt32Array()
var hit_d := PackedVector2Array()
## Normal of the last hit found by first_hit() (Vector2.ZERO if it found none).
var last_normal := Vector2.ZERO


func _init(p_bounds: Rect2 = Rect2(-2048, -2048, 4096, 4096), p_cell_size: float = 64.0) -> void:
	assert(p_cell_size > 0.0 and p_bounds.has_area())
	bounds = p_bounds
	cell_size = p_cell_size
	_inv_cell = 1.0 / cell_size
	_origin = bounds.position
	cols = maxi(ceili(bounds.size.x * _inv_cell), 1)
	rows = maxi(ceili(bounds.size.y * _inv_cell), 1)
	_heads.resize(cols * rows)
	_heads.fill(-1)


## Why a collision shape cannot be used exactly as a bullet wall, or "" if it
## can. Walls are axis-aligned rectangles: other shapes are ignored, and a
## rotated (or skewed) rectangle is approximated by its axis-aligned bounding
## box. BulletManager.collect_walls() warns with this text.
static func shape_issue(shape: Shape2D, xform: Transform2D) -> String:
	if not shape is RectangleShape2D:
		return "is a %s; only RectangleShape2D walls are supported, so it is ignored by bullets" % shape.get_class() if shape != null else "has no shape"
	if absf(xform.x.y) > 1e-4 or absf(xform.y.x) > 1e-4:
		return "is a rotated rectangle; bullets use its axis-aligned bounding box instead"
	return ""


## Adds a wall. Call rebuild() (BulletManager does it) before the next sweep.
func add_wall(rect: Rect2) -> void:
	var r := rect.abs()
	walls.append(r)
	_lo.append(r.position)
	_hi.append(r.end)
	wall_count = walls.size()
	_dirty = true


func clear_walls() -> void:
	walls.clear()
	_lo.clear()
	_hi.clear()
	wall_count = 0
	_dirty = true


## Re-buckets the walls. `max_bullet_radius` is the largest bullet radius that
## will be swept; walls are inflated by it when assigned to cells.
func rebuild(max_bullet_radius: float) -> void:
	_max_radius = max_bullet_radius
	_heads.fill(-1)
	var entries := 0
	_entry_wall.resize(0)
	_entry_next.resize(0)
	for w in wall_count:
		var r := walls[w].grow(max_bullet_radius + SHORT_PATH)
		var x0 := clampi(floori((r.position.x - _origin.x) * _inv_cell), 0, cols - 1)
		var x1 := clampi(floori((r.end.x - _origin.x) * _inv_cell), 0, cols - 1)
		var y0 := clampi(floori((r.position.y - _origin.y) * _inv_cell), 0, rows - 1)
		var y1 := clampi(floori((r.end.y - _origin.y) * _inv_cell), 0, rows - 1)
		for cy in range(y0, y1 + 1):
			for cx in range(x0, x1 + 1):
				var cell := cy * cols + cx
				_entry_wall.append(w)
				_entry_next.append(_heads[cell])
				_heads[cell] = entries
				entries += 1
	_dirty = false


## True if rebuild() is needed (walls changed, or a larger bullet showed up).
func needs_rebuild(max_bullet_radius: float) -> bool:
	return _dirty or max_bullet_radius > _max_radius


## Earliest wall hit of the path start -> start + d for a circle of radius
## `radius`, as a fraction t in [0, 1], or -1.0 if the path is clear.
func first_hit(start: Vector2, d: Vector2, radius: float) -> float:
	last_normal = Vector2.ZERO
	if wall_count == 0:
		return -1.0
	if _dirty or radius > _max_radius:
		rebuild(maxf(radius, _max_radius))
	var best := _best_hit(start, d, radius)
	if best > 1.0:
		return -1.0
	last_normal = box_normal(start, d, _best_lo - Vector2(radius, radius), _best_hi + Vector2(radius, radius))
	return best


## Sweeps every alive bullet of `pool` that has collide_world set and lists the
## ones that hit a wall in hit_bullets / hit_t. Nothing in the pool is modified:
## the manager clips the bullet's path to the impact point, tests hurtboxes along
## the shortened path, and then despawns it. Returns the hit count.
func sweep_bullets(pool: BulletPool) -> int:
	hit_count = 0
	if wall_count == 0:
		return 0
	if _dirty or pool.max_radius > _max_radius:
		rebuild(pool.max_radius)
	if hit_bullets.size() < pool.capacity:
		hit_bullets.resize(pool.capacity)
		hit_t.resize(pool.capacity)
		hit_wall.resize(pool.capacity)
		hit_d.resize(pool.capacity)
	var n := pool.count
	var bpos := pool.pos
	var bprev := pool.prev_pos
	var brad := pool.radius
	var bflag := pool.collide_world
	var bdead := pool.dead_reason
	var inv := _inv_cell
	var ox := _origin.x
	var oy := _origin.y
	var ncols := cols
	var nrows := rows
	var short_sq := SHORT_PATH * SHORT_PATH
	var bounds_dead := BulletPool.DespawnReason.BOUNDS + 1
	for i in n:
		# A bullet flagged for leaving the world bounds this tick still tests the
		# part of its path inside them.
		if bflag[i] == 0 or (bdead[i] != 0 and bdead[i] != bounds_dead):
			continue
		var p := bpos[i]
		var q := bprev[i]
		var d := p - q
		var best := 2.0
		var best_w := -1
		if bdead[i] == 0 and d.length_squared() <= short_sq:
			# Fast path: the walls near the end position are all in its cell.
			var fx := (p.x - ox) * inv
			var fy := (p.y - oy) * inv
			if fx < 0.0 or fy < 0.0:
				continue
			var cx := int(fx)
			var cy := int(fy)
			if cx >= ncols or cy >= nrows:
				continue
			var e := _heads[cy * ncols + cx]
			if e == -1:
				continue
			var r := brad[i]
			# Bounding box of this tick's path: most walls in the cell are
			# nowhere near it, and four compares are much cheaper than a slab test.
			var x_lo := (p.x if p.x < q.x else q.x) - r
			var x_hi := (p.x if p.x > q.x else q.x) + r
			var y_lo := (p.y if p.y < q.y else q.y) - r
			var y_hi := (p.y if p.y > q.y else q.y) + r
			while e != -1:
				var w := _entry_wall[e]
				e = _entry_next[e]
				var lo := _lo[w]
				var hi := _hi[w]
				if x_hi < lo.x or x_lo > hi.x or y_hi < lo.y or y_lo > hi.y:
					continue
				var t := _segment_vs_box(q, d, lo - Vector2(r, r), hi + Vector2(r, r))
				if t >= 0.0 and (t < best or (t == best and w < best_w)):
					best = t
					best_w = w
		else:
			best = _best_hit(q, d, brad[i])
			best_w = _best_wall
		if best <= 1.0:
			hit_bullets[hit_count] = i
			hit_t[hit_count] = best
			hit_wall[hit_count] = best_w
			hit_d[hit_count] = d
			hit_count += 1
	return hit_count


## Earliest hit fraction (> 1.0 when clear) over every wall in the cells under the
## path's bounding box.
func _best_hit(start: Vector2, d: Vector2, radius: float) -> float:
	var end := start + d
	var x0 := clampi(floori((minf(start.x, end.x) - radius - _origin.x) * _inv_cell), 0, cols - 1)
	var x1 := clampi(floori((maxf(start.x, end.x) + radius - _origin.x) * _inv_cell), 0, cols - 1)
	var y0 := clampi(floori((minf(start.y, end.y) - radius - _origin.y) * _inv_cell), 0, rows - 1)
	var y1 := clampi(floori((maxf(start.y, end.y) + radius - _origin.y) * _inv_cell), 0, rows - 1)
	var rv := Vector2(radius, radius)
	var best := 2.0
	_best_wall = -1
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var e := _heads[cy * cols + cx]
			while e != -1:
				var w := _entry_wall[e]
				var t := _segment_vs_box(start, d, _lo[w] - rv, _hi[w] + rv)
				# Strictly earlier wins; on an exact tie the lower wall index wins,
				# so the reported normal does not depend on the cell visit order.
				if t >= 0.0 and (t < best or (t == best and w < _best_wall)):
					best = t
					_best_wall = w
				e = _entry_next[e]
	_best_lo = _lo[_best_wall] if _best_wall >= 0 else Vector2.ZERO
	_best_hi = _hi[_best_wall] if _best_wall >= 0 else Vector2.ZERO
	return best


## Surface normal of hit `k` of the last sweep_bullets() call (unit vector pointing
## out of the wall, see the class comment). `pool` must still hold the swept bullet
## in the slot it had during the sweep, and its `prev_pos` / `radius` unchanged.
func normal_of_hit(k: int, pool: BulletPool) -> Vector2:
	if k < 0 or k >= hit_count:
		return Vector2.ZERO
	var i := hit_bullets[k]
	var r := pool.radius[i]
	var rv := Vector2(r, r)
	var w := hit_wall[k]
	return box_normal(pool.prev_pos[i], hit_d[k], _lo[w] - rv, _hi[w] + rv)


## Outward unit normal of the face of box lo..hi that the path start + d * t
## enters through (see the class comment for the corner and inside rules).
## `lo` / `hi` are the already-inflated box corners.
static func box_normal(start: Vector2, d: Vector2, lo: Vector2, hi: Vector2) -> Vector2:
	var tx := -INF
	var ty := -INF
	var nx := 0.0
	var ny := 0.0
	if absf(d.x) >= 1e-9:
		if d.x > 0.0:
			tx = (lo.x - start.x) / d.x
			nx = -1.0
		else:
			tx = (hi.x - start.x) / d.x
			nx = 1.0
	if absf(d.y) >= 1e-9:
		if d.y > 0.0:
			ty = (lo.y - start.y) / d.y
			ny = -1.0
		else:
			ty = (hi.y - start.y) / d.y
			ny = 1.0
	if tx <= 0.0 and ty <= 0.0:
		# The path starts inside the box (or exactly on its surface): push out
		# through the nearest face.
		var left := start.x - lo.x
		var right := hi.x - start.x
		var top := start.y - lo.y
		var bottom := hi.y - start.y
		var m := minf(minf(left, right), minf(top, bottom))
		if m == left:
			return Vector2.LEFT
		if m == right:
			return Vector2.RIGHT
		if m == top:
			return Vector2.UP
		return Vector2.DOWN
	if tx > ty:
		return Vector2(nx, 0.0)
	if ty > tx:
		return Vector2(0.0, ny)
	# Exactly simultaneous entry: a corner. Prefer the axis moving faster.
	if absf(d.x) >= absf(d.y):
		return Vector2(nx, 0.0)
	return Vector2(0.0, ny)


## Slab test: first t in [0, 1] at which start + d * t is inside the box lo..hi
## (0 if start is already inside), or -1.0 if the segment never enters it.
static func _segment_vs_box(start: Vector2, d: Vector2, lo: Vector2, hi: Vector2) -> float:
	var t_min := 0.0
	var t_max := 1.0
	if absf(d.x) < 1e-9:
		if start.x < lo.x or start.x > hi.x:
			return -1.0
	else:
		var inv := 1.0 / d.x
		var t1 := (lo.x - start.x) * inv
		var t2 := (hi.x - start.x) * inv
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return -1.0
	if absf(d.y) < 1e-9:
		if start.y < lo.y or start.y > hi.y:
			return -1.0
	else:
		var inv_y := 1.0 / d.y
		var t1y := (lo.y - start.y) * inv_y
		var t2y := (hi.y - start.y) * inv_y
		if t1y > t2y:
			var tmp_y := t1y
			t1y = t2y
			t2y = tmp_y
		t_min = maxf(t_min, t1y)
		t_max = minf(t_max, t2y)
		if t_min > t_max:
			return -1.0
	return t_min
