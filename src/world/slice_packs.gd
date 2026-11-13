class_name SlicePacks
extends Node2D
## Vertical-slice row 2: the four scripted packs in room C (§3 / §10).
## Not chunk encounters. Each empty pack records an absent-since timestamp
## and returns after 300 s outside C, the same rule as ChunkStream regulars.
## G4 is opened via SliceProgress.notify_pack_cleared and stays open.

const PACK_DRIFTERS := 0
const PACK_SWARMERS := 1
const PACK_SHIELD := 2
const PACK_SNIPER := 3
const PACK_COUNT := 4
const GROUP := &"slice_packs"

const ANCHORS: Array[Vector2] = [
	Vector2(4700, 0),
	Vector2(5400, -200),
	Vector2(5600, 320),
	Vector2(6200, -400),
]
const COUNTS: Array[int] = [3, 10, 1, 1]
const KEYS: Array[StringName] = [
	SaveGame.FIELD_DRIFTERS,
	SaveGame.FIELD_SWARMERS,
	SaveGame.FIELD_SHIELD,
	SaveGame.FIELD_SNIPER,
]

@export var regular_scene: PackedScene
@export var shield_scene: PackedScene
@export var sniper_scene: PackedScene

var player: Node2D
var progress: SliceProgress
var bullets: BulletManager
## Save world seed, used for idle headings. 0 if unset.
var world_seed := 0
## When >= 0, this unix time is used instead of the system clock. Tests pin it.
var pinned_time := -1.0

var _alive: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var _roots: Array[Node2D] = []
var _player_in_c := false
var _bound := false


func _ready() -> void:
	# After bullets, so a kill this tick is seen before the leave-C stamp.
	process_physics_priority = BulletManager.PHYSICS_PRIORITY + 10
	if _roots.is_empty():
		_init_roots()


func _init_roots() -> void:
	_roots.clear()
	for i in PACK_COUNT:
		var root := Node2D.new()
		root.name = "Pack%d" % i
		add_child(root)
		_roots.append(root)


func bind(p_player: Node2D, p_progress: SliceProgress, p_bullets: BulletManager = null, p_seed: int = 0) -> void:
	player = p_player
	progress = p_progress
	bullets = p_bullets
	world_seed = p_seed
	if _roots.is_empty():
		_init_roots()
	_player_in_c = _in_room_c()
	for i in PACK_COUNT:
		if _is_due(i):
			_spawn_pack(i)
	_bound = true


func pack_alive(pack: int) -> int:
	if pack < 0 or pack >= PACK_COUNT:
		return 0
	return int(_alive[pack])


func pack_anchor(pack: int) -> Vector2:
	if pack < 0 or pack >= PACK_COUNT:
		return Vector2.ZERO
	return ANCHORS[pack]


func _physics_process(_delta: float) -> void:
	if not _bound or player == null or not is_instance_valid(player):
		return
	var now_in := _in_room_c()
	if _player_in_c and not now_in:
		_on_left_c()
	_player_in_c = now_in
	if not now_in:
		_try_return_packs()


func _in_room_c() -> bool:
	if player == null or not is_instance_valid(player):
		return false
	return SliceLayout.room_at(player.global_position) == SliceLayout.ROOM_C


func _now() -> float:
	if pinned_time >= 0.0:
		return pinned_time
	return Time.get_unix_time_from_system()


## Present (since <= 0) always respawns. Mid-absence only returns after 300 s
## *outside* C; staying in C never brings a wiped pack back.
func _is_due(pack: int) -> bool:
	if pack_alive(pack) > 0:
		return false
	var since := 0.0
	if progress != null:
		since = progress.field_absent_since(KEYS[pack])
	if since <= 0.0:
		return true
	if _in_room_c():
		return false
	if progress != null:
		return progress.field_pack_is_present(KEYS[pack], _now())
	return true


func _on_left_c() -> void:
	# Restart the out-streak for every empty pack, same as a chunk unload.
	for i in PACK_COUNT:
		if pack_alive(i) == 0:
			_stamp(i)


func _try_return_packs() -> void:
	for i in PACK_COUNT:
		if _is_due(i):
			_clear_stamp(i)
			_spawn_pack(i)


func _stamp(pack: int) -> void:
	if progress == null:
		return
	progress.set_field_absent_since(KEYS[pack], _now())


func _clear_stamp(pack: int) -> void:
	if progress == null:
		return
	progress.set_field_absent_since(KEYS[pack], 0.0)


func _spawn_pack(pack: int) -> void:
	if pack < 0 or pack >= PACK_COUNT:
		return
	_despawn_pack(pack)
	var root := _roots[pack]
	var anchor := ANCHORS[pack]
	var count := int(COUNTS[pack])
	var chunk := WorldGen.chunk_of(anchor)
	match pack:
		PACK_SHIELD:
			_add_member(pack, root, _packed(shield_scene, "res://scenes/shieldbearer.tscn"), RegularEnemy.ARCH_DRIFTER, anchor, anchor, chunk, 0)
		PACK_SNIPER:
			_add_member(pack, root, _packed(sniper_scene, "res://scenes/sniper.tscn"), RegularEnemy.ARCH_DRIFTER, anchor, anchor, chunk, 0)
		PACK_DRIFTERS:
			_add_regulars(pack, root, RegularEnemy.ARCH_DRIFTER, anchor, count, chunk)
		PACK_SWARMERS:
			_add_regulars(pack, root, RegularEnemy.ARCH_SWARMER, anchor, count, chunk)
	_alive[pack] = root.get_child_count()


func _add_regulars(pack: int, root: Node2D, archetype: StringName, anchor: Vector2, count: int, chunk: Vector2i) -> void:
	var packed := _packed(regular_scene, "res://scenes/regular_enemy.tscn")
	for i in count:
		var spawn := RegularEnemy.spawn_position(anchor, archetype, i, count)
		_add_member(pack, root, packed, archetype, anchor, spawn, chunk, i)


func _packed(override: PackedScene, path: String) -> PackedScene:
	if override != null:
		return override
	return load(path) as PackedScene


func _add_member(pack: int, root: Node2D, packed: PackedScene, archetype: StringName, anchor: Vector2, spawn: Vector2, chunk: Vector2i, member: int) -> void:
	if packed == null:
		return
	var body := packed.instantiate() as RegularEnemy
	if body == null:
		return
	body.position = spawn
	root.add_child(body)
	body.configure(archetype, anchor, spawn, world_seed, chunk, pack, member, player)
	body.add_to_group(GROUP)
	if body is Sniper:
		(body as Sniper).bullets = bullets
	if not body.died.is_connected(_on_member_died):
		body.died.connect(_on_member_died.bind(pack))


func _despawn_pack(pack: int) -> void:
	if pack < 0 or pack >= _roots.size():
		return
	var root := _roots[pack]
	if root == null:
		return
	for child: Node in root.get_children():
		root.remove_child(child)
		child.free()
	_alive[pack] = 0


func _on_member_died(pack: int) -> void:
	if pack < 0 or pack >= PACK_COUNT:
		return
	_alive[pack] = maxi(int(_alive[pack]) - 1, 0)
	if int(_alive[pack]) > 0:
		return
	if progress != null:
		progress.notify_pack_cleared(pack)
	_stamp(pack)
