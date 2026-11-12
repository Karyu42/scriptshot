class_name LuaBulletBehavior
extends BulletBehavior
## Forwards the four event hooks to a Lua weapon held by ScriptHost.
##
## The class overrides every hook, so auto-detection would report HOOK_ALL and
## every Lua bullet would pay the event sweeps. The mask is therefore built
## with BulletBehavior.mask_from_names() from the functions the script defines,
## and hook_mask_exact stays true. A script that defines none of them keeps
## mask 0; apply_to_request() then leaves behavior_id at 0 so the bullet stays
## on the declarative path (no per-tick on_update).
##
## Velocity commits through BulletPool.set_velocity. Child spawns commit through
## ShotEmitter.request_child_shot_id after the callback returns. A callback that
## errors or is stopped by the budget commits nothing.

const REASON_NAMES: PackedStringArray = ["lifetime", "bounds", "hit", "manual", "cleared", "wall", "invalid", "absorbed"]

var host: ScriptHost
var last_result: ScriptHost.RunResult
var _dispatches: Dictionary = {}


func _init() -> void:
	# HOOK_AUTO would see these four overrides and call all of them.
	hook_mask = 0
	hook_mask_exact = true
	# This class overrides on_update_batch so it can forward on_batch. AUTO would
	# treat that override as a batch behavior for every Lua weapon. PER_BULLET
	# until the script actually defines on_batch.
	update_mode = UpdateMode.PER_BULLET
	host = ScriptHost.new()


func dispatches(name: String) -> int:
	return _count_of(name)


func _count_of(name: String) -> int:
	var n: Variant = _dispatches.get(name, 0)
	if n is int:
		@warning_ignore("unsafe_cast")
		return n as int
	return 0


## Loads a weapon. On success the mask matches the functions in the table.
## A failed load keeps the previous mask and the previous weapon. Pass the
## manager and this behavior's id after a reload so the debug check runs again
## (the mask itself is read on every dispatch either way).
func load_source(
	code: String,
	chunk_name: String = "weapon.lua",
	manager: BulletManager = null,
	behavior_id: int = -1
) -> ScriptHost.RunResult:
	var result := host.load_string(code, chunk_name)
	_apply_mask(result, manager, behavior_id)
	return result


func load_file(path: String, manager: BulletManager = null, behavior_id: int = -1) -> ScriptHost.RunResult:
	var result := host.load_file(path)
	_apply_mask(result, manager, behavior_id)
	return result


## Puts `behavior_id` on `request` when the script defines an event hook or
## `on_batch`. Defines `can_hit` turns on ShotRequest.can_hit_veto, which is
## what makes the manager ask. A declarative script is left as a plain bullet.
func apply_to_request(request: ShotRequest, behavior_id: int) -> void:
	var batch := update_mode == UpdateMode.BATCH
	if hook_mask == 0 and not batch:
		request.behavior_id = 0
		return
	request.behavior_id = behavior_id
	if host.has_callback("can_hit"):
		request.can_hit_veto = true


func on_update_batch(batch: BatchView) -> void:
	if not host.has_callback("on_batch"):
		return
	_dispatches["on_batch"] = _count_of("on_batch") + 1
	var result := host.call_batch(batch)
	last_result = result
	if not result.ok:
		batch.discard = true
		ScriptWarnings.warn(
			"LuaBulletBehavior.error.on_batch",
			"LuaBulletBehavior: %s: %s" % [result.chunk_name, result.error]
		)


func on_spawn(pool: BulletPool, index: int) -> void:
	_dispatch("on_spawn", "on_spawn", pool, index, null, false)


func on_hit(pool: BulletPool, index: int, _hurtbox: Hurtbox) -> void:
	var p := pool.pos[index]
	_dispatch("on_hit", "on_hit", pool, index, host.make_hit(pool.damage[index], p.x, p.y), true)


func can_hit(pool: BulletPool, index: int, _hurtbox: Hurtbox) -> bool:
	if not host.has_callback("can_hit"):
		return true
	var p := pool.pos[index]
	var result := _dispatch("can_hit", "can_hit", pool, index, host.make_hit(pool.damage[index], p.x, p.y), true)
	if not result.ok:
		return true
	# Only a boolean false vetoes. A missing return allows the hit.
	return result.value != false


func on_despawn(pool: BulletPool, index: int, reason: int) -> void:
	var why := REASON_NAMES[reason] if reason >= 0 and reason < REASON_NAMES.size() else "unknown"
	# on_expire / on_wall are the narrow names; on_death / on_despawn cover every reason.
	var lua_name := ""
	if reason == BulletPool.DespawnReason.LIFETIME and host.has_callback("on_expire"):
		lua_name = "on_expire"
	elif reason == BulletPool.DespawnReason.WALL and host.has_callback("on_wall"):
		lua_name = "on_wall"
	elif host.has_callback("on_death"):
		lua_name = "on_death"
	elif host.has_callback("on_despawn"):
		lua_name = "on_despawn"
	_dispatch("on_despawn", lua_name, pool, index, why, true)


func _apply_mask(result: ScriptHost.RunResult, manager: BulletManager, behavior_id: int) -> void:
	if not result.ok or not host.has_weapon():
		return
	hook_mask = BulletBehavior.mask_from_names(host.defined_names())
	hook_mask_exact = true
	update_mode = UpdateMode.BATCH if host.has_callback("on_batch") else UpdateMode.PER_BULLET
	if manager != null and behavior_id >= 0:
		manager.refresh_behavior(behavior_id)


func _dispatch(
	count_name: String,
	lua_name: String,
	pool: BulletPool,
	index: int,
	arg: Variant,
	pass_arg: bool
) -> ScriptHost.RunResult:
	_dispatches[count_name] = _count_of(count_name) + 1
	if lua_name == "" or not host.has_callback(lua_name):
		var skipped := ScriptHost.RunResult.new()
		skipped.ok = true
		skipped.chunk_name = count_name
		last_result = skipped
		return skipped
	var result := host.call_hook(lua_name, pool.id_of(index), pool.pos[index].x, pool.pos[index].y, arg, pass_arg)
	last_result = result
	if not result.ok:
		ScriptWarnings.warn(
			"LuaBulletBehavior.error.%s" % lua_name,
			"LuaBulletBehavior: %s: %s" % [result.chunk_name, result.error]
		)
		return result
	_commit(pool, index)
	return result


func _commit(pool: BulletPool, index: int) -> void:
	if host.has_pending_velocity():
		# Non-finite velocities come back false and the bullet is INVALID.
		pool.set_velocity(index, host.take_pending_velocity())
	if pool.dead_reason[index] != 0:
		host.take_pending_children()
		return
	var parent_id := pool.id_of(index)
	var children := host.take_pending_children()
	if emitter == null:
		return
	for i in children.size():
		var req: ShotRequest = children[i]
		emitter.request_child_shot_id(parent_id, req)
