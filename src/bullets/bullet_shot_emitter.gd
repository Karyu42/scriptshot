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


func reflect_bullet(id: int, new_owner_layer: int, reverse: bool = false) -> bool:
	return _manager.reflect(id, new_owner_layer, reverse)


func register_behavior(behavior: BulletBehavior) -> int:
	return _manager.register_behavior(behavior)


func get_dropped_count() -> int:
	return _manager.pool.dropped_total


func is_saturated() -> bool:
	return _manager.pool.is_full()


func get_bullet_count() -> int:
	return _manager.pool.count


func get_capacity() -> int:
	return _manager.pool.capacity
