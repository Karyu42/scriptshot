class_name BulletShotEmitter
extends ShotEmitter
## ShotEmitter backed by a BulletManager. Created by the manager; shooters get
## it injected and only ever use the ShotEmitter interface.

var _manager: BulletManager


func _init(manager: BulletManager) -> void:
	_manager = manager


func request_shot(request: ShotRequest) -> bool:
	return _manager.spawn(request) >= 0


func register_behavior(behavior: BulletBehavior) -> int:
	return _manager.register_behavior(behavior)


func get_bullet_count() -> int:
	return _manager.pool.count


func get_capacity() -> int:
	return _manager.pool.capacity
