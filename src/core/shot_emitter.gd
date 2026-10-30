class_name ShotEmitter
extends RefCounted
## The boundary between "something that wants to shoot" and the bullet system.
## Shot scripts (GDScript now, Lua later) only ever see this interface.
## Concrete implementation: BulletShotEmitter. See docs/architecture.md.


## Spawns one bullet and returns its stable id (> 0), or -1 if the bullet pool
## is full (the shot is dropped, never queued). The id stays valid for exactly
## the bullet's lifetime; see is_bullet_alive().
func request_shot_id(_request: ShotRequest) -> int:
	push_error("ShotEmitter.request_shot_id() is abstract")
	return -1


## Same as request_shot_id() for callers that only care whether the shot was
## accepted.
func request_shot(request: ShotRequest) -> bool:
	return request_shot_id(request) >= 0


## True while the bullet with this id exists and has not been marked for
## removal. False for stale or invalid ids.
func is_bullet_alive(_id: int) -> bool:
	return false


## Convenience for patterns: submits every ShotRequest in `requests`.
## Returns how many were accepted.
func request_shots(requests: Array) -> int:
	var accepted := 0
	for request: ShotRequest in requests:
		if request_shot(request):
			accepted += 1
	return accepted


## Registers per-bullet behaviour hooks and returns the id to put in
## ShotRequest.behavior_id. Ids are stable for the life of the emitter.
func register_behavior(_behavior: BulletBehavior) -> int:
	push_error("ShotEmitter.register_behavior() is abstract")
	return 0


## Number of bullets currently alive.
func get_bullet_count() -> int:
	return 0


## Maximum number of simultaneously alive bullets.
func get_capacity() -> int:
	return 0
