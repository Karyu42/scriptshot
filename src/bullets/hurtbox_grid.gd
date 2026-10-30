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
## A bullet can hit several targets in one tick: a piercing bullet (pierce = n)
## is re-swept from each impact point for the rest of its path, skipping the
## targets it already hit, up to n + 1 hits per tick. Bullets that were
## flagged as leaving the world bounds this tick (BulletPool.DespawnReason.BOUNDS)
## still test their final segment, clipped to the grid.
##
## Everything is stored in preallocated arrays that only ever grow (by doubling),
## so a steady-state tick allocates nothing.

## Most zones listed per bullet when collide_bullets() matches on owner.
const MAX_ZONE_HITS := 4

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

# Targets the bullet being swept has already hit this tick (ids, in hit order).
var _excl := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0])
var _excl_count := 0
# Out-parameter of _sweep_once(): hit fraction of the target it returned.
var _sweep_t := 0.0


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


## The bullet-radius margin the current tick's targets were bucketed with.
func get_margin() -> float:
	return _margin


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
## hit_targets / hit_t and returns the hit count. A bullet has at most one hit
## per call, except a piercing bullet (pierce = n), which can have up to n + 1,
## listed in the order along its path (increasing hit_t, each target once).
## Bullets that are already marked dead (other than for leaving the world bounds,
## which still test their last segment), have hit_mask 0, or are piercing through
## the target they hit last are skipped.
##
## With `match_owner` the target layer is matched against each bullet's
## `owner_layer` instead of its `hit_mask`: the same swept test answers "which
## bullets of faction X touch this zone", which is how Reflectors find bullets.
func collide_bullets(pool: BulletPool, match_owner: bool = false) -> int:
	hit_count = 0
	if target_count == 0:
		return 0
	if hit_bullets.size() < pool.capacity:
		_resize_hits(pool.capacity)
	var n := pool.count
	var bpos := pool.pos
	var bprev := pool.prev_pos
	var brad := pool.radius
	var bmask := pool.owner_layer if match_owner else pool.hit_mask
	var bdead := pool.dead_reason
	var blast := pool.last_hit
	var bpierce := pool.pierce
	var bounds_dead := BulletPool.DespawnReason.BOUNDS + 1
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
		var dead := bdead[i]
		if mask == 0 or (dead != 0 and dead != bounds_dead):
			continue
		var p := bpos[i]
		var br := brad[i]
		var d := p - bprev[i]
		var reach := min_reach + br
		var pierce := bpierce[i]
		if match_owner:
			# Reflector zones: always sweep, and list every zone on the path (up to
			# MAX_ZONE_HITS), so a zone that declines the bullet (arc, guard) does
			# not hide the next one behind it.
			_sweep_bullet(i, bprev[i], d, br, mask, blast[i], mini(target_count, MAX_ZONE_HITS))
			continue
		if pierce > 0 or d.length_squared() > reach * reach:
			# Piercing bullets always sweep: only the sweep can list several hits.
			_sweep_bullet(i, bprev[i], d, br, mask, blast[i], pierce + 1)
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


## Sweeps one extra path segment of `bullet` (start -> start + d, radius `radius`)
## against the targets matching `mask`, and appends its hits (up to `max_hits`, in
## path order) to hit_bullets / hit_targets / hit_t after those of the last
## collide_bullets() call. hit_t is the fraction of *this* segment. Returns how
## many hits were added. BulletManager uses it for the part of a tick that a
## reflected bullet flies after the mirror.
func sweep_segment(bullet: int, start: Vector2, d: Vector2, radius: float, mask: int, last_target: int, max_hits: int) -> int:
	var first := hit_count
	if target_count > 0 and mask != 0 and max_hits > 0:
		_sweep_bullet(bullet, start, d, radius, mask, last_target, max_hits)
	return hit_count - first


func get_target_instance_id(target: int) -> int:
	return _target_id[target]


## Swept test of one bullet's path (start + d * t, t in [0, 1]) against the
## targets in every cell the path crosses. Records up to `max_hits` hits in path
## order: after each one the bullet is swept again from the impact point for the
## remaining path, ignoring targets it already hit (this is what lets a piercing
## bullet hit several targets in one tick). The path is clipped to the grid, so
## a bullet that starts or ends outside it still tests the part inside.
func _sweep_bullet(i: int, start: Vector2, d: Vector2, br: float, mask: int, last_target: int, max_hits: int) -> void:
	var fx0 := (start.x - _origin.x) * _inv_cell
	var fy0 := (start.y - _origin.y) * _inv_cell
	var dfx := d.x * _inv_cell
	var dfy := d.y * _inv_cell
	# Liang-Barsky clip of the path to the grid rectangle [0, cols] x [0, rows].
	var tc0 := 0.0
	var tc1 := 1.0
	if dfx == 0.0:
		if fx0 < 0.0 or fx0 >= cols:
			return
	else:
		var ta := -fx0 / dfx
		var tb := (float(cols) - fx0) / dfx
		tc0 = maxf(tc0, minf(ta, tb))
		tc1 = minf(tc1, maxf(ta, tb))
	if dfy == 0.0:
		if fy0 < 0.0 or fy0 >= rows:
			return
	else:
		var tya := -fy0 / dfy
		var tyb := (float(rows) - fy0) / dfy
		tc0 = maxf(tc0, minf(tya, tyb))
		tc1 = minf(tc1, maxf(tya, tyb))
	if tc0 > tc1:
		return
	_excl_count = 0
	var t_min := 0.0
	for _hit in max_hits:
		var target := _sweep_once(start, d, br, mask, last_target, t_min, tc0, tc1, fx0, fy0, dfx, dfy)
		if target == -1:
			return
		_record_hit(i, target, _sweep_t)
		if _excl_count >= _excl.size():
			_excl.resize(_excl.size() * 2)
		_excl[_excl_count] = target
		_excl_count += 1
		t_min = _sweep_t
		if t_min >= 1.0:
			return


## One grid traversal for _sweep_bullet(): the earliest target (not in _excl,
## not `last_target`) that the bullet touches at some t >= t_min, or -1. Its hit
## fraction is left in _sweep_t. [tc0, tc1] is the part of the path inside the
## grid; (fx0, fy0, dfx, dfy) is the path in cell units.
func _sweep_once(
	start: Vector2, d: Vector2, br: float, mask: int, last_target: int, t_min: float,
	tc0: float, tc1: float, fx0: float, fy0: float, dfx: float, dfy: float
) -> int:
	var t_begin := maxf(tc0, t_min)
	if t_begin > tc1:
		return -1
	var px := fx0 + dfx * t_begin
	var py := fy0 + dfy * t_begin
	var cx := clampi(int(px), 0, cols - 1)
	var cy := clampi(int(py), 0, rows - 1)
	var ex := clampi(int(fx0 + dfx * tc1), 0, cols - 1)
	var ey := clampi(int(fy0 + dfy * tc1), 0, rows - 1)
	var step_x := 1 if d.x > 0.0 else -1
	var step_y := 1 if d.y > 0.0 else -1
	# t_max_*: path fraction at which the traversal leaves the current cell along
	# that axis; t_delta_*: path fraction per whole cell.
	var t_max_x := INF
	var t_max_y := INF
	var t_delta_x := INF
	var t_delta_y := INF
	if dfx != 0.0:
		t_delta_x = absf(1.0 / dfx)
		t_max_x = t_begin + (float(cx + (1 if step_x > 0 else 0)) - px) / dfx
	if dfy != 0.0:
		t_delta_y = absf(1.0 / dfy)
		t_max_y = t_begin + (float(cy + (1 if step_y > 0 else 0)) - py) / dfy
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
				if (target_layer[t] & mask) != 0 and _target_id[t] != last_target and not _is_excluded(t):
					var rr := target_radius[t] + br
					var f := start - target_pos[t]
					var c := f.length_squared() - rr * rr
					var hit := -1.0
					if a > 0.0:
						var b := f.dot(d)
						var disc := b * b - a * c
						if disc >= 0.0:
							var root := sqrt(disc)
							# Contact interval [(-b - root) / a, (-b + root) / a]; the
							# bullet touches the target at the first t >= t_min inside it.
							if (-b + root) / a >= t_min:
								hit = maxf((-b - root) / a, t_min)
					elif c <= 0.0:
						hit = 0.0
					if hit >= 0.0 and hit <= 1.0 and hit < best_t:
						best_t = hit
						best_target = t
				e = _entry_next[e]
		# The next cell starts when this one is left. If that is not before the
		# best hit so far, nothing further along can be nearer: stop. (Stopping at
		# the first cell that has any candidate would miss a nearer target that
		# is only registered in a later cell.)
		if best_target != -1 and minf(t_max_x, t_max_y) >= best_t:
			break
		# Advance along the axis whose next cell border comes first, never past
		# the end cell (guards against float drift on near-diagonal paths).
		if cx == ex or (cy != ey and t_max_y < t_max_x):
			cy += step_y
			t_max_y += t_delta_y
		else:
			cx += step_x
			t_max_x += t_delta_x
	_sweep_t = best_t
	return best_target


func _is_excluded(target: int) -> bool:
	for k in _excl_count:
		if _excl[k] == target:
			return true
	return false


func _record_hit(bullet: int, target: int, t: float) -> void:
	if hit_count >= hit_bullets.size():
		_resize_hits(maxi(hit_bullets.size() * 2, 64))
	hit_bullets[hit_count] = bullet
	hit_targets[hit_count] = target
	hit_t[hit_count] = t
	hit_count += 1


func _resize_hits(new_size: int) -> void:
	hit_bullets.resize(new_size)
	hit_targets.resize(new_size)
	hit_t.resize(new_size)


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
