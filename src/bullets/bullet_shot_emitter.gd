class_name BulletShotEmitter
extends ShotEmitter
## ShotEmitter backed by a BulletManager. Created by the manager; shooters get
## it injected and only ever use the ShotEmitter interface.

var _manager: BulletManager


func _init(manager: BulletManager) -> void:
	_manager = manager


func request_shot_id(request: ShotRequest) -> int:
	var spawned := _manager.spawn(request)
	if spawned < 0:
		return -1
	# Plain bullets on the native backend already come back as a stable id.
	if _manager.is_native_id(spawned):
		return spawned
	return _manager.pool.id_of(spawned)


func request_child_shot_id(parent_id: int, request: ShotRequest) -> int:
	var slot := _manager.spawn_child(parent_id, request)
	return _manager.pool.id_of(slot) if slot >= 0 else -1


func is_bullet_alive(id: int) -> bool:
	if _manager.is_native_id(id):
		return _manager.is_native_bullet_alive(id)
	return _manager.pool.is_alive(id)


func reflect_bullet(
	id: int,
	new_owner_layer: int,
	reverse: bool = false,
	new_damage: float = BulletPool.REFLECTED_DAMAGE,
	keep_script: bool = false
) -> bool:
	return _manager.reflect(id, new_owner_layer, reverse, new_damage, keep_script)


func register_behavior(behavior: BulletBehavior) -> int:
	return _manager.register_behavior(behavior)


func get_dropped_count() -> int:
	return _manager.dropped_total_all()


func get_dropped_count_by_owner(owner_layer: int) -> int:
	return _manager.dropped_by_owner_all(owner_layer)


func get_dropped_count_by_limit(limit: int) -> int:
	return _manager.dropped_by_limit_all(limit)


func is_saturated(owner_layer: int = Layers.PLAYER) -> bool:
	return _manager.is_saturated_for(owner_layer)


func get_headroom(owner_layer: int = Layers.PLAYER) -> int:
	return _manager.headroom_for(owner_layer)


func get_bullet_count() -> int:
	return _manager.alive_count()


func get_owner_count(owner_layer: int) -> int:
	return _manager.owner_count_all(owner_layer)


func get_capacity() -> int:
	return _manager.pool.capacity


func get_logical_cap() -> int:
	return _manager.pool.logical_cap


func get_enemy_reserve() -> int:
	return _manager.pool.enemy_reserve


func get_wall_normal(id: int) -> Vector2:
	if _manager.is_native_id(id):
		return _manager.native.wall_normal(id) if _manager.native != null else Vector2.ZERO
	var slot := _manager.pool.slot_of(id)
	return _manager.wall_normal_of(slot) if slot >= 0 else Vector2.ZERO
