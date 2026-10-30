class_name BulletShotEmitter
extends ShotEmitter
## ShotEmitter backed by a BulletManager. Created by the manager; shooters get
## it injected and only ever use the ShotEmitter interface.

var _manager: BulletManager


func _init(manager: BulletManager) -> void:
	_manager = manager


func request_shot_id(request: ShotRequest) -> int:
	var slot := _manager.spawn(request)
	return _manager.pool.id_of(slot) if slot >= 0 else -1


func is_bullet_alive(id: int) -> bool:
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
	return _manager.pool.dropped_total


func get_dropped_count_by_owner(owner_layer: int) -> int:
	return _manager.pool.dropped_for(owner_layer)


func get_dropped_count_by_limit(limit: int) -> int:
	return _manager.pool.dropped_by_limit[limit] if limit >= 0 and limit < _manager.pool.dropped_by_limit.size() else 0


func is_saturated(owner_layer: int = Layers.PLAYER) -> bool:
	return not _manager.pool.can_spawn(owner_layer)


func get_headroom(owner_layer: int = Layers.PLAYER) -> int:
	return _manager.pool.headroom(owner_layer)


func get_bullet_count() -> int:
	return _manager.pool.count


func get_owner_count(owner_layer: int) -> int:
	return _manager.pool.owner_count(owner_layer)


func get_capacity() -> int:
	return _manager.pool.capacity


func get_logical_cap() -> int:
	return _manager.pool.logical_cap


func get_enemy_reserve() -> int:
	return _manager.pool.enemy_reserve


func get_wall_normal(id: int) -> Vector2:
	var slot := _manager.pool.slot_of(id)
	return _manager.wall_normal_of(slot) if slot >= 0 else Vector2.ZERO
