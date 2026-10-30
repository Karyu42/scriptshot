class_name HurtboxGrid
extends RefCounted
## Uniform spatial hash of circular targets used for bullet collision.
##
## Targets (a handful to a few hundred) are inserted into every cell their
## circle overlaps; each bullet then only looks at the cells its path touches.
## That makes collision cost O(bullets) with a very small constant, instead of
## O(bullets x targets) or one physics body per bullet. Rebuilt every tick:
## begin(), add_circle() for each target, then collide_bullets().
##
## Collision is swept: a bullet is the segment prev_pos -> pos (a capsule of
## the bullet's radius), so fast bullets cannot tunnel through a target. Bullets
## that moved less than the smallest possible tunnelling distance take a cheaper
## point test at their end position.
##
## Everything is stored in preallocated arrays that only ever grow (by doubling),
## so a steady-state tick allocates nothing.

var bounds := Rect2()
var cell_size := 64.0
var cols := 0
var rows := 0
var _inv_cell := 1.0
var _origin := Vector2.ZERO

var _heads := PackedInt32Array()
var _occupied := PackedByteArray()
## Cells that received at least one entry this tick (to reset them cheaply).
var _touched := PackedInt32Array()
var _touched_count := 0
## Linked list entries: which target, and the next entry in the same cell.
var _entry_next := PackedInt32Array()
var _entry_target := PackedInt32Array()
var _entry_count := 0

# Target data, indexed by the id add_circle() returns. Only [0, target_count)
# is valid.
var target_count := 0
var target_pos := PackedVector2Array()
var target_radius := PackedFloat32Array()
var target_layer := PackedInt32Array()
var target_ref: Array[Object] = []
var _target_id := PackedInt64Array()
var _target_capacity := 0
var _margin := 0.0
var _min_target_radius := INF

# Results of the last collide_bullets() call (parallel arrays, valid up to
# hit_count). hit_t is the fraction of the bullet's path (0 = start of the tick,
# 1 = end) at which it first touched the target.
var hit_count := 0
var hit_bullets := PackedInt32Array()
var hit_targets := PackedInt32Array()
var hit_t := PackedFloat32Array()


func _init(p_bounds: Rect2 = Rect2(-2048, -2048, 4096, 4096), p_cell_size: float = 64.0) -> void:
	setup(p_bounds, p_cell_size)


func setup(p_bounds: Rect2, p_cell_size: float) -> void:
	assert(p_cell_size > 0.0 and p_bounds.has_area())
	bounds = p_bounds
	cell_size = p_cell_size
	_inv_cell = 1.0 / cell_size
	_origin = bounds.position
	cols = maxi(ceili(bounds.size.x * _inv_cell), 1)
	rows = maxi(ceili(bounds.size.y * _inv_cell), 1)
	_heads.resize(cols * rows)
	_heads.fill(-1)
	_occupied.resize(cols * rows)
	_occupied.fill(0)
	_touched.resize(maxi(_touched.size(), 64))
	_touched_count = 0
	begin()


## Empties the grid for a new tick. `margin` should be the largest bullet radius
## (targets are inflated by it when bucketed).
func begin(margin: float = 0.0) -> void:
	for k in _touched_count:
		var cell := _touched[k]
		_heads[cell] = -1
		_occupied[cell] = 0
	_touched_count = 0
	_entry_count = 0
	target_count = 0
	hit_count = 0
	_margin = margin
	_min_target_radius = INF


## Alias of begin() kept for callers that clear the grid explicitly.
func clear() -> void:
	begin(_margin)


## Adds a circular target. `layer` is one Layers constant. `ref` is returned in
## target_ref[id] so callers can map hits back to objects. Returns the id.
func add_circle(center: Vector2, target_r: float, layer: int, ref: Object = null) -> int:
	var id := target_count
	if id >= _target_capacity:
		_grow_targets()
	target_count = id + 1
	target_pos[id] = center
	target_radius[id] = target_r
	target_layer[id] = layer
	target_ref[id] = ref
	_target_id[id] = ref.get_instance_id() if ref != null else -1
	if target_r < _min_target_radius:
		_min_target_radius = target_r
	var reach := target_r + _margin
	var x0 := clampi(floori((center.x - reach - _origin.x) * _inv_cell), 0, cols - 1)
	var x1 := clampi(floori((center.x + reach - _origin.x) * _inv_cell), 0, cols - 1)
	var y0 := clampi(floori((center.y - reach - _origin.y) * _inv_cell), 0, rows - 1)
	var y1 := clampi(floori((center.y + reach - _origin.y) * _inv_cell), 0, rows - 1)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var cell := cy * cols + cx
			if _entry_count >= _entry_target.size():
				_grow_entries()
			var entry := _entry_count
			_entry_count += 1
			_entry_target[entry] = id
			_entry_next[entry] = _heads[cell]
			if _occupied[cell] == 0:
				_occupied[cell] = 1
				if _touched_count >= _touched.size():
					_touched.resize(_touched.size() * 2)
				_touched[_touched_count] = cell
				_touched_count += 1
			_heads[cell] = entry
	return id


## Returns the id of the first target in `layer_mask` overlapping the given
## circle, or -1. Handy for one-off queries and tests.
func query_circle(center: Vector2, query_r: float, layer_mask: int) -> int:
	var cx := floori((center.x - _origin.x) * _inv_cell)
	var cy := floori((center.y - _origin.y) * _inv_cell)
	if cx < 0 or cx >= cols or cy < 0 or cy >= rows:
		return -1
	var cell := cy * cols + cx
	if _occupied[cell] == 0:
		return -1
	var e := _heads[cell]
	while e != -1:
		var t := _entry_target[e]
		if (target_layer[t] & layer_mask) != 0:
			var rr := target_radius[t] + query_r
			if (target_pos[t] - center).length_squared() <= rr * rr:
				return t
		e = _entry_next[e]
	return -1


## Tests every alive bullet in `pool` against the targets. Fills hit_bullets /
## hit_targets / hit_t (at most one hit per bullet per call) and returns the hit
## count. Bullets that are already marked dead, have hit_mask 0, or are piercing
## through the target they hit last are skipped.
func collide_bullets(pool: BulletPool) -> int:
	hit_count = 0
	if target_count == 0:
		return 0
	if hit_bullets.size() < pool.capacity:
		hit_bullets.resize(pool.capacity)
		hit_targets.resize(pool.capacity)
		hit_t.resize(pool.capacity)
	var n := pool.count
	var bpos := pool.pos
	var bprev := pool.prev_pos
	var brad := pool.radius
	var bmask := pool.hit_mask
	var bdead := pool.dead_reason
	var blast := pool.last_hit
	var ox := _origin.x
	var oy := _origin.y
	var inv := _inv_cell
	var ncols := cols
	var nrows := rows
	# A path shorter than this cannot pass fully through the smallest target
	# without an endpoint overlapping it (grazing misses aside).
	var min_reach := _min_target_radius
	for i in n:
		var mask := bmask[i]
		if mask == 0 or bdead[i] != 0:
			continue
		var p := bpos[i]
		var br := brad[i]
		var d := p - bprev[i]
		var reach := min_reach + br
		if d.length_squared() > reach * reach:
			if _sweep_bullet(i, bprev[i], d, br, mask, blast[i]):
				continue
		var fx := (p.x - ox) * inv
		var fy := (p.y - oy) * inv
		if fx < 0.0 or fy < 0.0:
			continue
		var cx := int(fx)
		var cy := int(fy)
		if cx >= ncols or cy >= nrows:
			continue
		var cell := cy * ncols + cx
		if _occupied[cell] == 0:
			continue
		var e := _heads[cell]
		while e != -1:
			var t := _entry_target[e]
			if (target_layer[t] & mask) != 0:
				var rr := target_radius[t] + br
				if (target_pos[t] - p).length_squared() <= rr * rr and _target_id[t] != blast[i]:
					_record_hit(i, t, 1.0)
					break
			e = _entry_next[e]
	return hit_count


func get_target_instance_id(target: int) -> int:
	return _target_id[target]


## Swept test of one bullet's path (start + d * t, t in [0, 1]) against the
## targets in every cell the path crosses (grid traversal). Records the earliest
## hit and returns true if there was one. Returns false for a miss, and also when
## an endpoint is outside the grid (the caller then falls back to the point test).
func _sweep_bullet(i: int, start: Vector2, d: Vector2, br: float, mask: int, last_target: int) -> bool:
	var fx0 := (start.x - _origin.x) * _inv_cell
	var fy0 := (start.y - _origin.y) * _inv_cell
	var fx1 := fx0 + d.x * _inv_cell
	var fy1 := fy0 + d.y * _inv_cell
	if fx0 < 0.0 or fy0 < 0.0 or fx1 < 0.0 or fy1 < 0.0:
		return false
	var cx := int(fx0)
	var cy := int(fy0)
	var ex := int(fx1)
	var ey := int(fy1)
	if cx >= cols or cy >= rows or ex >= cols or ey >= rows:
		return false
	var step_x := 1 if d.x > 0.0 else -1
	var step_y := 1 if d.y > 0.0 else -1
	var dfx := fx1 - fx0
	var dfy := fy1 - fy0
	var t_max_x := INF
	var t_max_y := INF
	var t_delta_x := INF
	var t_delta_y := INF
	if dfx != 0.0:
		t_delta_x = absf(1.0 / dfx)
		t_max_x = (float(cx + (1 if step_x > 0 else 0)) - fx0) / dfx
	if dfy != 0.0:
		t_delta_y = absf(1.0 / dfy)
		t_max_y = (float(cy + (1 if step_y > 0 else 0)) - fy0) / dfy
	var steps := absi(ex - cx) + absi(ey - cy) + 1
	var a := d.length_squared()
	var best_t := 2.0
	var best_target := -1
	for _step in steps:
		var cell := cy * cols + cx
		if _occupied[cell] != 0:
			var e := _heads[cell]
			while e != -1:
				var t := _entry_target[e]
				if (target_layer[t] & mask) != 0 and _target_id[t] != last_target:
					var rr := target_radius[t] + br
					var f := start - target_pos[t]
					var c := f.length_squared() - rr * rr
					var hit := -1.0
					if c <= 0.0:
						hit = 0.0
					elif a > 0.0:
						var b := f.dot(d)
						var disc := b * b - a * c
						if disc >= 0.0 and b < 0.0:
							hit = (-b - sqrt(disc)) / a
					if hit >= 0.0 and hit <= 1.0 and hit < best_t:
						best_t = hit
						best_target = t
				e = _entry_next[e]
			if best_target != -1:
				break
		# Advance along the axis whose next cell border comes first, never past
		# the end cell (guards against float drift on near-diagonal paths).
		if cx == ex or (cy != ey and t_max_y < t_max_x):
			cy += step_y
			t_max_y += t_delta_y
		else:
			cx += step_x
			t_max_x += t_delta_x
	if best_target == -1:
		# Missed along the whole path. Only the swept result counts: the point
		# test at the end position can never hit when the sweep did not.
		return true
	_record_hit(i, best_target, best_t)
	return true


func _record_hit(bullet: int, target: int, t: float) -> void:
	hit_bullets[hit_count] = bullet
	hit_targets[hit_count] = target
	hit_t[hit_count] = t
	hit_count += 1


func _grow_targets() -> void:
	_target_capacity = maxi(_target_capacity * 2, 64)
	target_pos.resize(_target_capacity)
	target_radius.resize(_target_capacity)
	target_layer.resize(_target_capacity)
	_target_id.resize(_target_capacity)
	target_ref.resize(_target_capacity)


func _grow_entries() -> void:
	var new_size := maxi(_entry_target.size() * 2, 256)
	_entry_target.resize(new_size)
	_entry_next.resize(new_size)
