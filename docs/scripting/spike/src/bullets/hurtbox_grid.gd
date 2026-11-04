class_name HurtboxGrid
extends RefCounted
## Uniform spatial hash of circular targets used for bullet collision.
##
## Targets (a handful to a few hundred) are inserted into every cell their
## circle overlaps; each bullet then only looks at the single cell it is in.
## That makes collision cost O(bullets) with a very small constant, instead of
## O(bullets x targets) or one physics body per bullet. Rebuilt every tick:
## clear(), add_circle() for each target, then collide_bullets().
##
## A bullet is tested as a circle against target circles. Bullets larger than
## the `margin` passed to begin() may miss targets whose cell they only touch;
## BulletManager passes BulletPool.max_radius so this cannot happen there.

var bounds := Rect2()
var cell_size := 64.0
var cols := 0
var rows := 0

var _inv_cell := 1.0
var _origin := Vector2.ZERO
var _heads := PackedInt32Array()
var _occupied := PackedByteArray()
var _touched := PackedInt32Array()
var _entry_next := PackedInt32Array()
var _entry_target := PackedInt32Array()

# Target data, indexed by the id add_circle() returns.
var target_count := 0
var target_pos := PackedVector2Array()
var target_radius := PackedFloat32Array()
var target_layer := PackedInt32Array()
var target_ref: Array[Object] = []
var _target_id := PackedInt64Array()

var _margin := 0.0

# Results of the last collide_bullets() call (parallel arrays).
var hit_bullets := PackedInt32Array()
var hit_targets := PackedInt32Array()


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
	clear()


## Empties the grid for a new tick. `margin` should be the largest bullet radius
## (targets are inflated by it when bucketed).
func begin(margin: float = 0.0) -> void:
	clear()
	_margin = margin


func clear() -> void:
	for cell in _touched:
		_heads[cell] = -1
		_occupied[cell] = 0
	_touched.clear()
	_entry_next.clear()
	_entry_target.clear()
	target_pos.clear()
	target_radius.clear()
	target_layer.clear()
	_target_id.clear()
	target_ref.clear()
	target_count = 0
	hit_bullets.clear()
	hit_targets.clear()


## Adds a circular target. `layer` is one Layers constant. `ref` is returned in
## target_ref[id] so callers can map hits back to objects. Returns the id.
func add_circle(center: Vector2, target_r: float, layer: int, ref: Object = null) -> int:
	var id := target_count
	target_count += 1
	target_pos.append(center)
	target_radius.append(target_r)
	target_layer.append(layer)
	target_ref.append(ref)
	_target_id.append(ref.get_instance_id() if ref != null else -1)
	var reach := target_r + _margin
	var x0 := clampi(floori((center.x - reach - _origin.x) * _inv_cell), 0, cols - 1)
	var x1 := clampi(floori((center.x + reach - _origin.x) * _inv_cell), 0, cols - 1)
	var y0 := clampi(floori((center.y - reach - _origin.y) * _inv_cell), 0, rows - 1)
	var y1 := clampi(floori((center.y + reach - _origin.y) * _inv_cell), 0, rows - 1)
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			var cell := cy * cols + cx
			var entry := _entry_target.size()
			_entry_target.append(id)
			_entry_next.append(_heads[cell])
			if _occupied[cell] == 0:
				_occupied[cell] = 1
				_touched.append(cell)
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
## hit_targets (at most one hit per bullet per call) and returns the hit count.
## Bullets that are already marked dead, have hit_mask 0, or are piercing
## through the target they hit last are skipped.
func collide_bullets(pool: BulletPool) -> int:
	hit_bullets.clear()
	hit_targets.clear()
	if target_count == 0:
		return 0
	var n := pool.count
	var bpos := pool.pos
	var brad := pool.radius
	var bmask := pool.hit_mask
	var bdead := pool.dead_reason
	var blast := pool.last_hit
	var ox := _origin.x
	var oy := _origin.y
	var inv := _inv_cell
	var ncols := cols
	var nrows := rows
	for i in n:
		var mask := bmask[i]
		if mask == 0 or bdead[i] != 0:
			continue
		var p := bpos[i]
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
		var br := brad[i]
		var e := _heads[cell]
		while e != -1:
			var t := _entry_target[e]
			if (target_layer[t] & mask) != 0:
				var rr := target_radius[t] + br
				if (target_pos[t] - p).length_squared() <= rr * rr and _target_id[t] != blast[i]:
					hit_bullets.append(i)
					hit_targets.append(t)
					break
			e = _entry_next[e]
	return hit_bullets.size()


func get_target_instance_id(target: int) -> int:
	return _target_id[target]
