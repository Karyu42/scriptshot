class_name ChunkStream
extends Node
## Loads the 3×3 Chebyshev ring of 2048 px chunks around the player and unloads
## the rest. Only tier-0 chunks spawn, via WorldGen.chunk_encounters.
##
## A regular encounter that is empty when its chunk unloads stays gone until
## that chunk has been continuously outside the ring for OUT_SECONDS (5 min).
## Coming back earlier leaves it empty and the out-streak restarts on the next
## unload. An encounter that still has a living body is generated fresh on the
## next load (partial clears are not saved).

signal chunk_loaded(cx: int, cy: int)
signal chunk_unloaded(cx: int, cy: int)
signal absent_changed

const OUT_SECONDS := 300.0

@export var enemy_scene: PackedScene

var seed := 0
var player: Node2D
## When >= 0, this unix time is used instead of the system clock. Tests pin it.
var pinned_time := -1.0

class _EncounterLive:
	extends RefCounted
	var index := 0
	var root: Node2D


class _ChunkLive:
	extends RefCounted
	var root: Node2D
	var encounters: Array[_EncounterLive] = []


var _active: Dictionary[Vector2i, _ChunkLive] = {}
## Vector3i(cx, cy, encounter index) -> unix time the empty encounter unloaded.
var _absent: Dictionary[Vector3i, float] = {}
var _center := Vector2i.ZERO
var _has_center := false


func _init() -> void:
	process_physics_priority = 10


func _physics_process(_delta: float) -> void:
	update_streaming()


func update_streaming() -> void:
	if player == null:
		return
	var center := WorldGen.chunk_of(player.global_position)
	if _has_center and center == _center:
		return
	_center = center
	_has_center = true
	_apply_ring(center)


func loaded_coords() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for key: Vector2i in _active:
		out.append(key)
	return out


func is_loaded(cx: int, cy: int) -> bool:
	return _active.has(Vector2i(cx, cy))


func alive_in(cx: int, cy: int, index: int) -> int:
	var key := Vector2i(cx, cy)
	if not _active.has(key):
		return 0
	var rec := _active[key]
	for enc: _EncounterLive in rec.encounters:
		if enc.index == index:
			return _living(enc.root)
	return 0


func absent_records() -> Array:
	var out: Array = []
	for key: Vector3i in _absent:
		out.append({
			"cx": key.x,
			"cy": key.y,
			"index": key.z,
			"since_unix": _absent[key],
		})
	return out


## Rows come from the save file, so each field arrives as a Variant.
func load_absent(rows: Array) -> void:
	_absent.clear()
	@warning_ignore_start("unsafe_cast", "unsafe_call_argument")
	for row: Variant in rows:
		if row is Dictionary:
			var d: Dictionary = row
			var key := Vector3i(int(d.get("cx", 0)), int(d.get("cy", 0)), int(d.get("index", 0)))
			_absent[key] = float(d.get("since_unix", 0.0))
	@warning_ignore_restore("unsafe_cast", "unsafe_call_argument")


func _apply_ring(center: Vector2i) -> void:
	var want: Dictionary[Vector2i, bool] = {}
	for y in range(center.y - WorldGen.RING_RADIUS, center.y + WorldGen.RING_RADIUS + 1):
		for x in range(center.x - WorldGen.RING_RADIUS, center.x + WorldGen.RING_RADIUS + 1):
			var coord := Vector2i(x, y)
			want[coord] = true
			if not _active.has(coord):
				_load(coord)
	var stale: Array[Vector2i] = []
	for coord: Vector2i in _active:
		if not want.has(coord):
			stale.append(coord)
	for coord: Vector2i in stale:
		_unload(coord)


func _load(c: Vector2i) -> void:
	var root := Node2D.new()
	root.name = "Chunk_%d_%d" % [c.x, c.y]
	add_child(root)
	var specs := WorldGen.chunk_encounters(seed, c.x, c.y)
	var live := _ChunkLive.new()
	live.root = root
	var now := _now()
	for spec: EncounterSpec in specs:
		var enc_root := Node2D.new()
		enc_root.name = "Encounter%d" % spec.index
		root.add_child(enc_root)
		var key := Vector3i(c.x, c.y, spec.index)
		var spawn := true
		if _absent.has(key):
			var since := _absent[key]
			if now - since >= OUT_SECONDS:
				_absent.erase(key)
				absent_changed.emit()
			else:
				spawn = false
		if spawn and enemy_scene != null:
			_spawn_members(enc_root, spec)
		var enc := _EncounterLive.new()
		enc.index = spec.index
		enc.root = enc_root
		live.encounters.append(enc)
	_active[c] = live
	chunk_loaded.emit(c.x, c.y)


func _unload(c: Vector2i) -> void:
	var rec := _active[c]
	var now := _now()
	var changed := false
	for enc: _EncounterLive in rec.encounters:
		var key := Vector3i(c.x, c.y, enc.index)
		if _living(enc.root) == 0:
			_absent[key] = now
			changed = true
		elif _absent.has(key):
			_absent.erase(key)
			changed = true
	rec.root.queue_free()
	_active.erase(c)
	chunk_unloaded.emit(c.x, c.y)
	if changed:
		absent_changed.emit()


func _spawn_members(root: Node2D, spec: EncounterSpec) -> void:
	for m in spec.members.size():
		var archetype := spec.archetype_of(m)
		var count := spec.count_of(m)
		for i in count:
			var enemy := enemy_scene.instantiate() as RegularEnemy
			var spawn := RegularEnemy.spawn_position(spec.anchor, archetype, i, count)
			enemy.configure(archetype, spec.anchor, spawn, seed, spec.chunk, spec.index, i, player)
			root.add_child(enemy)


func _living(root: Node) -> int:
	var n := 0
	for child: Node in root.get_children():
		var enemy := child as RegularEnemy
		if enemy != null and enemy.is_alive():
			n += 1
	return n


func _now() -> float:
	if pinned_time >= 0.0:
		return pinned_time
	return Time.get_unix_time_from_system()
