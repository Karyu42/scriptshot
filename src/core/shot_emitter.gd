class_name ShotEmitter
extends RefCounted
## The boundary between "something that wants to shoot" and the bullet system.
## Shot scripts (GDScript now, Lua later) only ever see this interface.
## Concrete implementation: BulletShotEmitter. See docs/architecture.md.


## Emitted at most once per bullet-system tick when shots were dropped because
## the pool hit a limit (the logical cap, or the enemy reserve for a non-enemy
## shooter). `dropped_now` = shots dropped since the last emission, `dropped_total`
## = lifetime total (same as get_dropped_count()). Which limit and whose shots:
## get_dropped_count_by_limit() / get_dropped_count_by_owner().
signal pool_saturated(dropped_now: int, dropped_total: int)


## Spawns one bullet and returns its stable id (> 0), or -1 if the bullet pool
## is full (the shot is dropped, never queued). The id stays valid for exactly
## the bullet's lifetime; see is_bullet_alive().
func request_shot_id(_request: ShotRequest) -> int:
	push_error("ShotEmitter.request_shot_id() is abstract")
	return -1


## Spawns a child of the live bullet `parent_id` and returns its stable id, or -1
## (parent gone, pool full, invalid request). The child's `owner_layer` is the
## parent's, never the request's: a differing owner in the request is ignored
## with a capped warning. This is the spawn path for code that runs after the
## parent's hook returned (batch/Lua commit). Spawns made from inside a hook
## through request_shot_id() inherit the same way. Only reflect changes owners.
func request_child_shot_id(_parent_id: int, _request: ShotRequest) -> int:
	push_error("ShotEmitter.request_child_shot_id() is abstract")
	return -1


## Same as request_shot_id() for callers that only care whether the shot was
## accepted.
func request_shot(request: ShotRequest) -> bool:
	return request_shot_id(request) >= 0


## True while the bullet with this id exists and has not been marked for
## removal. False for stale or invalid ids.
func is_bullet_alive(_id: int) -> bool:
	return false


## Hands a live bullet to another faction (a parry / reflect): `new_owner_layer`
## is Layers.PLAYER or Layers.ENEMY. The bullet then only hits what is hostile
## to the new owner (never the new owner itself), takes that faction's colour,
## deals `new_damage` (default 1, BulletPool.KEEP_DAMAGE keeps its own) and stops
## being scripted: its behaviour hooks, `user` data and params are cleared unless
## `keep_script` is true. With `reverse` its velocity is flipped too.
## A bullet can be reflected at most `BulletPool.max_reflections` times (default
## once, so reflections cannot ping-pong): further calls return false, as do a
## stale id or an invalid owner. See BulletPool.reflect().
func reflect_bullet(
	_id: int,
	_new_owner_layer: int,
	_reverse: bool = false,
	_new_damage: float = 1.0,
	_keep_script: bool = false
) -> bool:
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


## Total number of shots dropped (refused) since creation, whatever the reason:
## the logical cap or the enemy reserve (see get_dropped_count_by_limit()).
func get_dropped_count() -> int:
	return 0


## Shots dropped since creation that were fired by `owner_layer`'s side:
## Layers.PLAYER, Layers.ENEMY (enemies and bosses), or 0 for unowned shots.
func get_dropped_count_by_owner(_owner_layer: int) -> int:
	return 0


## Shots dropped since creation because of one limit: BulletPool.DropLimit.LOGICAL_CAP
## (the pool held the maximum number of bullets) or BulletPool.DropLimit.ENEMY_RESERVE
## (the pool still had room, but only for enemy and boss bullets).
func get_dropped_count_by_limit(_limit: int) -> int:
	return 0


## True while a shot from `owner_layer` (default Layers.PLAYER, what scripts fire)
## would be dropped right now. A player shot is already refused once the pool
## holds `logical_cap - enemy_reserve` bullets; an enemy shot only at `logical_cap`.
func is_saturated(_owner_layer: int = Layers.PLAYER) -> bool:
	return false


## How many more shots from `owner_layer` would be accepted right now before one
## is dropped (0 = saturated). Use it to throttle a script's output.
func get_headroom(_owner_layer: int = Layers.PLAYER) -> int:
	return 0


## Number of bullets currently alive (including ones marked dead this tick that
## still hold their slot).
func get_bullet_count() -> int:
	return 0


## Live bullets owned by `owner_layer`'s side: Layers.PLAYER, Layers.ENEMY (enemies
## and bosses), or 0 for unowned bullets. Reflected bullets move to their new
## owner. Constant time.
func get_owner_count(_owner_layer: int) -> int:
	return 0


## Physical size of the bullet pool (memory); the logical cap can only be lower.
func get_capacity() -> int:
	return 0


## Most bullets that may be alive at once, whoever owns them (PROVISIONAL default
## 10,000).
func get_logical_cap() -> int:
	return 0


## Slots of the logical cap that only enemy and boss bullets may take.
func get_enemy_reserve() -> int:
	return 0


## Surface normal (unit vector pointing out of the wall) of the wall that bullet
## `id` hit this tick, or Vector2.ZERO if it did not hit one. Only meaningful
## inside this tick's hooks for that bullet (e.g. on_despawn with
## BulletPool.DespawnReason.WALL).
func get_wall_normal(_id: int) -> Vector2:
	return Vector2.ZERO
