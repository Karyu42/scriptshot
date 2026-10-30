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

# Results of the last sweep_bullets() call (parallel arrays, valid up to
# hit_count). hit_t is the fraction of the bullet's path (prev_pos -> pos) at
# which it touched the wall; BulletManager moves the bullet to that point.
var hit_count := 0
var hit_bullets := PackedInt32Array()
var hit_t := PackedFloat32Array()


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
	if wall_count == 0:
		return -1.0
	if _dirty or radius > _max_radius:
		rebuild(maxf(radius, _max_radius))
	var best := _best_hit(start, d, radius)
	return best if best <= 1.0 else -1.0


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
				if t >= 0.0 and t < best:
					best = t
		else:
			best = _best_hit(q, d, brad[i])
		if best <= 1.0:
			hit_bullets[hit_count] = i
			hit_t[hit_count] = best
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
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var e := _heads[cy * cols + cx]
			while e != -1:
				var w := _entry_wall[e]
				var t := _segment_vs_box(start, d, _lo[w] - rv, _hi[w] + rv)
				if t >= 0.0 and t < best:
					best = t
				e = _entry_next[e]
	return best


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
