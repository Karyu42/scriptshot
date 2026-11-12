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
##
## An elite encounter does not use that timer. The bit is set when the elite
## body dies (not a half, summon, or escort) and is never cleared. Escorts of
## that encounter stay gone with it. Halves and summons despawn with the chunk
## and are not written to the save.

signal chunk_loaded(cx: int, cy: int)
signal chunk_unloaded(cx: int, cy: int)
signal absent_changed
signal elite_kills_changed
## One natural elite body died. Halves, summons, escorts, and regulars do not emit.
signal shard_gained

const OUT_SECONDS := 300.0

@export var enemy_scene: PackedScene
@export var elite_scene: PackedScene

var seed := 0
var player: Node2D
## When >= 0, this unix time is used instead of the system clock. Tests pin it.
var pinned_time := -1.0
## Encounters whose anchor lies inside this rect are not spawned and not
## tracked (the vertical-slice footprint; Main sets it to SliceLayout.FOOTPRINT
## when the scene has the ribbon). Rect2.has_point: left/top edges count as
## inside. Empty (the default) drops nothing. Other encounters of the same
## chunk keep their index, so chunk bits and absent records are unchanged.
var footprint := Rect2()

class _EncounterLive:
	extends RefCounted
	var index := 0
	var root: Node2D
	var is_elite := false


class _ChunkLive:
	extends RefCounted
	var root: Node2D
	var encounters: Array[_EncounterLive] = []


var _active: Dictionary[Vector2i, _ChunkLive] = {}
## Vector3i(cx, cy, encounter index) -> unix time the empty encounter unloaded.
var _absent: Dictionary[Vector3i, float] = {}
## (cx, cy) -> bitmask. Bit i is set when elite encounter i's body has died.
var _elite_bits: Dictionary[Vector2i, int] = {}
var _center := Vector2i.ZERO
var _has_center := false


func _init() -> void:
	# After BulletManager (priority 100). A kill landed by this tick's bullets
	# has to count when the same tick also unloads the chunk; running earlier
	# records the body as still alive and the encounter respawns on the way back.
	process_physics_priority = BulletManager.PHYSICS_PRIORITY + 10


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


## True when an encounter anchored at `anchor` is dropped by `footprint`.
func drops_anchor(anchor: Vector2) -> bool:
	return footprint.has_area() and footprint.has_point(anchor)


func loaded_coords() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for key: Vector2i in _active:
		out.append(key)
	return out


func is_loaded(cx: int, cy: int) -> bool:
	return _active.has(Vector2i(cx, cy))


func is_absent(cx: int, cy: int, index: int) -> bool:
	return _absent.has(Vector3i(cx, cy, index))


func elite_killed(cx: int, cy: int, index: int) -> bool:
	if index < 0 or index > 2:
		return false
	return (_bits_at(cx, cy) & (1 << index)) != 0


func elite_bits_at(cx: int, cy: int) -> int:
	return _bits_at(cx, cy)


func elite_kill_records() -> Array:
	var out: Array = []
	for key: Vector2i in _elite_bits:
		var bits := _elite_bits[key] & 0x7
		if bits == 0:
			continue
		out.append({"cx": key.x, "cy": key.y, "bits": bits})
	return out


## Rows come from the save file, so each field arrives as a Variant.
## A later row for the same chunk is OR'd in. Bits stay inside 0–7.
func load_elite_kills(rows: Array) -> void:
	_elite_bits.clear()
	@warning_ignore_start("unsafe_cast", "unsafe_call_argument")
	for row: Variant in rows:
		if row is Dictionary:
			var d: Dictionary = row
			var key := Vector2i(int(d.get("cx", 0)), int(d.get("cy", 0)))
			var bits := int(d.get("bits", 0)) & 0x7
			if bits == 0:
				continue
			var prior := 0
			if _elite_bits.has(key):
				prior = _elite_bits[key]
			_elite_bits[key] = (prior | bits) & 0x7
	@warning_ignore_restore("unsafe_cast", "unsafe_call_argument")


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
		if drops_anchor(spec.anchor):
			continue
		var enc_root := Node2D.new()
		enc_root.name = "Encounter%d" % spec.index
		root.add_child(enc_root)
		var key := Vector3i(c.x, c.y, spec.index)
		var spawn := true
		if spec.is_elite:
			# A set bit never spawns again, including the escort. The 5-minute
			# list is not consulted and not cleared by an elite load.
			if elite_killed(c.x, c.y, spec.index):
				spawn = false
		elif _absent.has(key):
			var since := _absent[key]
			if now - since >= OUT_SECONDS:
				_absent.erase(key)
				absent_changed.emit()
			else:
				spawn = false
		if spawn:
			if spec.is_elite:
				_spawn_elite(enc_root, spec)
			elif enemy_scene != null:
				_spawn_members(enc_root, spec)
		var enc := _EncounterLive.new()
		enc.index = spec.index
		enc.root = enc_root
		enc.is_elite = spec.is_elite
		live.encounters.append(enc)
	_active[c] = live
	chunk_loaded.emit(c.x, c.y)


func _unload(c: Vector2i) -> void:
	var rec := _active[c]
	var now := _now()
	var changed := false
	for enc: _EncounterLive in rec.encounters:
		var key := Vector3i(c.x, c.y, enc.index)
		if enc.is_elite:
			# Elite encounters never join the 5-minute list. The kill bit,
			# written when the body died, is what keeps them gone.
			if _absent.has(key):
				_absent.erase(key)
				changed = true
			continue
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


func _spawn_elite(root: Node2D, spec: EncounterSpec) -> void:
	var packed := _elite_packed()
	if packed == null or spec.affix_ids.is_empty():
		return
	var body := packed.instantiate() as EliteEnemy
	if body == null:
		return
	var centre := RegularEnemy.push_centre_outside(spec.anchor, RegularEnemy.DRIFTER_RADIUS)
	body.name = "Elite_%d_%d_%d" % [spec.chunk.x, spec.chunk.y, spec.index]
	body.configure_elite(
		spec.affix_ids[0],
		spec.anchor,
		centre,
		seed,
		player,
		false,
		false,
		spec.chunk,
		spec.index,
	)
	body.rarity = spec.rarity
	root.add_child(body)
	body.died.connect(_on_elite_died.bind(spec.chunk.x, spec.chunk.y, spec.index))
	body.shard_dropped.connect(_on_elite_shard)
	_spawn_escort(root, spec)


func _spawn_escort(root: Node2D, spec: EncounterSpec) -> void:
	if enemy_scene == null or spec.members.is_empty():
		return
	var archetype := spec.archetype_of(0)
	var count := spec.count_of(0)
	if count <= 0:
		return
	# One point, one body. The offset is from the anchor, not a formation ring
	# (a count of 1 would otherwise sit on the elite).
	var pos := RegularEnemy.push_centre_outside(
		WorldGen.escort_position(spec.anchor),
		RegularEnemy.radius_of(archetype),
	)
	var enemy := enemy_scene.instantiate() as RegularEnemy
	if enemy == null:
		return
	enemy.name = "Escort"
	enemy.configure(archetype, spec.anchor, pos, seed, spec.chunk, spec.index, 0, player)
	root.add_child(enemy)


func _elite_packed() -> PackedScene:
	if elite_scene != null:
		return elite_scene
	return load("res://scenes/elite_enemy.tscn") as PackedScene


func _on_elite_died(cx: int, cy: int, index: int) -> void:
	_set_elite_bit(cx, cy, index)


func _on_elite_shard() -> void:
	shard_gained.emit()


func _set_elite_bit(cx: int, cy: int, index: int) -> void:
	# T0 encounters are 0 and 1. Bit 2 stays reserved for the 3-encounter tiers.
	if index < 0 or index > 1:
		return
	var key := Vector2i(cx, cy)
	var bits := _bits_at(cx, cy)
	var next := (bits | (1 << index)) & 0x7
	if next == bits:
		return
	_elite_bits[key] = next
	elite_kills_changed.emit()


func _bits_at(cx: int, cy: int) -> int:
	var key := Vector2i(cx, cy)
	if not _elite_bits.has(key):
		return 0
	return _elite_bits[key] & 0x7


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
