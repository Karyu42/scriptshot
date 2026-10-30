class_name ShotEmitter
extends RefCounted
## The boundary between "something that wants to shoot" and the bullet system.
## Shot scripts (GDScript now, Lua later) only ever see this interface.
## Concrete implementation: BulletShotEmitter. See docs/architecture.md.


## Queues one bullet. Returns true if it was accepted, false if the bullet pool
## is full (the shot is dropped, never queued).
func request_shot(_request: ShotRequest) -> bool:
	push_error("ShotEmitter.request_shot() is abstract")
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
