extends Node
## QA autoplay for the first-playable path (docs/design/first-playable-elites.md)
## and, when present, the first-run rooms in docs/design/vertical-slice.md.
##
## Only the "Web (playtest)" export preset ships this file. That preset sets the
## custom feature `playtest`, and project.godot's
## `application/run/main_scene.playtest` override then makes this scene the
## main scene. Every shipping preset excludes src/qa/* (tools/ci/
## check_export_preset.py enforces it), so normal builds neither contain nor
## run it. Release web templates refuse a scene path on the command line, which
## is why the override is a feature tag and not an argument. Linux CI and a
## local editor run this scene directly: `godot --headless --path .
## res://src/qa/playtest_autoplay.tscn`.
##
## It instantiates the real main scene and drives it with scripted input:
## leave the 512 px safe disk, fire at the three origin dummies, fire a Lua
## shot through ScriptHost, jump the Herald clock and fight that body and a
## T0 regular if one is in the stream, take damage, die, and respawn. It
## asserts damage applied, enemies die, the save updates, no Lua errors, and
## bullets return to the pool.
##
## The vertical-slice ribbon (rooms S–E, gates, lessons, the Warden) is a
## content spec and is not on main yet. If `SliceLayout` (or a Warden) is in
## the tree, this run notes it and does not fail for its absence. Arena
## placement is provisional (vertical-slice.md Q26): this script never
## hard-asserts the arena centre, chunk, aggro line, or post-kill respawn
## point. Origin dummies stay plain; the shielded dummy belongs in room A
## when that room exists, and is not required here. `shots/default.lua` is
## not the equipped weapon on main (still BasicShot); the Lua check goes
## through ScriptHost the same way the web smoke does.
##
## Markers: PLAYTEST_DONE ok (or fail), plus one PLAYTEST_*_OK line per beat.
## The harness greps those, or fails on PLAYTEST_FAIL / a timeout / a script
## error. User args (for example `--bullet-backend=native`) reach BulletManager
## as usual.

const MAIN_SCENE := "res://scenes/main.tscn"
const SHOT_PATH := "res://src/qa/playtest_shot.lua"
const SAVE_PATH := "user://playtest_autoplay.cfg"
const SEED := 1
const TIMEOUT_S := 180.0
const LUA_SHOTS := 4
const LUA_TICKS := 8
const SAFE_RADIUS := 512.0
## Origin dummy positions from both design docs (first-playable L0; vertical-slice §2).
const DUMMY_POSITIONS: Array[Vector2] = [Vector2(300, 0), Vector2(-150, 260), Vector2(-150, -260)]

var _finished := false
var _main: Main
var _player: Player
var _manager: BulletManager
var _arm: HeraldArm
var _director: HeraldDirector
var _save: SaveGame


func _ready() -> void:
	print("PLAYTEST_START platform=%s feature=%s args=%s" % [
		OS.get_name(), OS.has_feature("playtest"), " ".join(OS.get_cmdline_user_args())
	])
	get_tree().create_timer(TIMEOUT_S).timeout.connect(_on_timeout)
	_run.call_deferred()


func _on_timeout() -> void:
	if _finished:
		return
	_fail_now("timeout after %.0fs" % TIMEOUT_S)


func _run() -> void:
	_wipe_save()
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		await _fail("cannot load %s" % MAIN_SCENE)
		return
	_main = packed.instantiate() as Main
	if _main == null:
		await _fail("%s is not a Main scene" % MAIN_SCENE)
		return
	_main.save_path = SAVE_PATH
	add_child(_main)
	await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame

	_player = _main.get_node_or_null("Player") as Player
	_manager = _main.get_node_or_null("BulletManager") as BulletManager
	_arm = _main.get_node_or_null("HeraldArm") as HeraldArm
	_director = _main.get_node_or_null("HeraldDirector") as HeraldDirector
	if _player == null or _manager == null or _arm == null or _director == null:
		await _fail("main scene is missing Player, BulletManager, HeraldArm or HeraldDirector")
		return
	_save = _read_save()
	if _save == null or _save.world_seed != SEED:
		await _fail("save did not pin world_seed=%d (got %s)" % [SEED, "null" if _save == null else str(_save.world_seed)])
		return
	print("PLAYTEST_MAIN_OK scene=%s seed=%d backend=%s" % [_main.scene_file_path, _save.world_seed, _manager.backend])

	if not _assert_safe_start():
		await _fail("cold start has a hostile inside the 512 px safe disk, or the origin dummies are wrong")
		return
	print("PLAYTEST_SAFE_OK dummies=%d hostiles_in_disk=0" % _dummy_count())
	_observe_slice()

	if not await _fire_lua_shot():
		return
	if not await _shoot_origin_dummies():
		return
	if not await _leave_safe_zone():
		return
	if not await _fight_herald():
		return
	if not await _fight_t0_regular():
		return
	if not await _damage_die_respawn():
		return
	if not await _assert_bullets_released():
		return

	_release_all_input()
	print("PLAYTEST_DONE ok")
	_finished = true
	await get_tree().process_frame
	get_tree().quit(0)


func _wipe_save() -> void:
	var abs_path := ProjectSettings.globalize_path(SAVE_PATH)
	if FileAccess.file_exists(abs_path):
		DirAccess.remove_absolute(abs_path)
	var save := SaveGame.new()
	save.path = SAVE_PATH
	save.world_seed = SEED
	save.save()


func _read_save() -> SaveGame:
	# Re-read the slot from disk. Main writes through SaveGame.save() on every
	# change this run cares about (herald_done, shards, regular_absent).
	return SaveGame.load_from(SAVE_PATH)


func _assert_safe_start() -> bool:
	if _player.global_position.length() > 1.0:
		printerr("PLAYTEST_FAIL player did not start at the origin (pos=%s)" % _player.global_position)
		return false
	var dummies := _origin_dummies()
	if dummies.size() != 3:
		printerr("PLAYTEST_FAIL expected 3 origin dummies, got %d" % dummies.size())
		return false
	for want: Vector2 in DUMMY_POSITIONS:
		var found := false
		for dummy: TrainingDummy in dummies:
			if dummy.global_position.distance_to(want) <= 1.0:
				found = true
				break
		if not found:
			printerr("PLAYTEST_FAIL missing origin dummy at %s" % want)
			return false
	for node: Node in get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var body := node as Node2D
		if body == null:
			continue
		if body.global_position.length() <= SAFE_RADIUS:
			printerr("PLAYTEST_FAIL hostile %s inside the safe disk at %s" % [body.name, body.global_position])
			return false
	return true


func _origin_dummies() -> Array[TrainingDummy]:
	var out: Array[TrainingDummy] = []
	var holder := _main.get_node_or_null("Dummies")
	if holder == null:
		return out
	for child: Node in holder.get_children():
		var dummy := child as TrainingDummy
		if dummy != null:
			out.append(dummy)
	return out


func _dummy_count() -> int:
	return _origin_dummies().size()


func _observe_slice() -> void:
	# Vertical-slice.md rooms are not on main yet. Note presence; never assert
	# Q26 arena coordinates (centre, chunk, aggro line, post-kill respawn).
	var layout := _main.get_node_or_null("SliceLayout")
	var warden := _main.find_child("Warden", true, false)
	if layout == null and warden == null:
		print("PLAYTEST_SLICE_LAYOUT absent (expected until the ribbon lands; arena placement is provisional Q26)")
		return
	print("PLAYTEST_SLICE_LAYOUT present layout=%s warden=%s (Q26 arena coordinates are not asserted)" % [
		layout != null, warden != null
	])


func _fire_lua_shot() -> bool:
	var behavior := LuaBulletBehavior.new()
	var id := _manager.register_behavior(behavior)
	var loaded := behavior.load_file(SHOT_PATH, _manager, id)
	if not loaded.ok:
		await _fail("Lua load failed through ScriptHost: %s" % loaded.error)
		return false
	var before := _manager.alive_count()
	for i in LUA_SHOTS:
		var request := ShotRequest.with_velocity(Vector2(0, 40.0 * i), Vector2(60, 0))
		request.lifetime = 1.0
		behavior.apply_to_request(request, id)
		if _manager.spawn(request) < 0:
			await _fail("Lua spawn %d was rejected" % i)
			return false
	for _t in LUA_TICKS:
		await get_tree().physics_frame
	var spawned := _manager.alive_count() - before
	var hooks := behavior.dispatches("on_spawn")
	if hooks != LUA_SHOTS:
		await _fail("Lua on_spawn ran %d times, expected %d (last error: %s)" % [hooks, LUA_SHOTS, behavior.last_result.error])
		return false
	if spawned < LUA_SHOTS * 2:
		await _fail("expected at least %d live Lua bullets, got %d" % [LUA_SHOTS * 2, spawned])
		return false
	if not behavior.last_result.error.is_empty():
		await _fail("Lua script error: %s" % behavior.last_result.error)
		return false
	print("PLAYTEST_LUA_OK bullets=%d on_spawn=%d chunk=%s" % [spawned, hooks, loaded.chunk_name])
	if not await _wait_alive_down(before, 3.0):
		await _fail("Lua bullets were not released (alive=%d, baseline=%d)" % [_manager.alive_count(), before])
		return false
	return true


func _shoot_origin_dummies() -> bool:
	_protect_player(true)
	var killed := 0
	for dummy: TrainingDummy in _origin_dummies():
		var start_hp := dummy.health
		if not await _fire_until(dummy, func() -> bool: return not is_instance_valid(dummy) or dummy.health <= 0.0, 20.0):
			await _fail("could not destroy origin dummy %s at %s (hp=%s)" % [dummy.name, dummy.global_position, dummy.health])
			return false
		if dummy.health >= start_hp and start_hp > 0.0:
			await _fail("dummy %s took no damage" % dummy.name)
			return false
		killed += 1
		await get_tree().process_frame
	print("PLAYTEST_DUMMY_OK killed=%d (origin dummies stay plain; room-A shield is not required)" % killed)
	return true


func _leave_safe_zone() -> bool:
	_release_aim_and_fire()
	Input.action_press("move_right", 1.0)
	var t := 0.0
	while t < 8.0 and _player.global_position.length() <= SAFE_RADIUS:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	Input.action_release("move_right")
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _player.global_position.length() <= SAFE_RADIUS:
		await _fail("player did not leave the safe disk (pos=%s)" % _player.global_position)
		return false
	if not _arm.left_safe_zone or not _arm.armed or _arm.arm_reason != HeraldArm.REASON_LEFT:
		await _fail("HeraldArm did not arm on leaving the disk (armed=%s reason=%s left=%s)" % [
			_arm.armed, _arm.arm_reason, _arm.left_safe_zone
		])
		return false
	print("PLAYTEST_LEFT_SAFE pos=%s reason=%s" % [_player.global_position, _arm.arm_reason])
	return true


func _fight_herald() -> bool:
	_director.natural_elites_cancel = false
	var wait_arm := 0.0
	while wait_arm < 2.0 and not _director.counting and not _director.resolved:
		await get_tree().physics_frame
		wait_arm += get_physics_process_delta_time()
	if not _director.counting and not _director.resolved:
		await _fail("HeraldDirector did not start counting after the arm")
		return false
	# Public test API: jump the [58, 78) delay. Do not assert the slice redirect
	# at (4700, 180); that clamp is not on main and Q26 rooms are provisional.
	_director.advance(_director.delay + 1.0)
	await get_tree().process_frame
	await get_tree().physics_frame
	_save = _read_save()
	if _save == null or not _save.herald_done:
		await _fail("save.herald_done was not set after the Herald resolved")
		return false
	var herald := _director.herald
	if herald == null or not is_instance_valid(herald) or not herald.is_alive():
		await _fail("Herald body did not spawn (resolved=%s counting=%s)" % [_director.resolved, _director.counting])
		return false
	if herald.global_position.length() <= SAFE_RADIUS:
		await _fail("Herald spawned inside the safe disk at %s" % herald.global_position)
		return false
	var shards_before := _save.shards
	print("PLAYTEST_HERALD_SPAWN pos=%s hp=%s" % [herald.global_position, herald.health.hp if herald.health != null else -1])
	# Summoner Herald (seed 1) parks adds in the lane; stand off and the body
	# barely takes damage. Close in and keep following the body while firing.
	if not await _fire_until(herald, func() -> bool: return not is_instance_valid(herald) or not herald.is_alive(), 60.0, 140.0):
		var hp: Variant = -1
		if is_instance_valid(herald) and herald.health != null:
			hp = herald.health.hp
		await _fail("could not kill the Herald (alive=%s hp=%s player=%s target=%s)" % [
			is_instance_valid(herald) and herald.is_alive(),
			hp,
			_player.global_position,
			herald.global_position if is_instance_valid(herald) else Vector2.ZERO
		])
		return false
	# shard_dropped is written in the death handler; give the save a tick.
	await get_tree().process_frame
	await get_tree().process_frame
	_save = _read_save()
	if _save == null or _save.shards < shards_before + 1:
		await _fail("Herald death did not add a shard (before=%d after=%s)" % [
			shards_before, "null" if _save == null else str(_save.shards)
		])
		return false
	print("PLAYTEST_HERALD_OK shards=%d herald_done=%s" % [_save.shards, _save.herald_done])
	return true


func _fight_t0_regular() -> bool:
	_save = _read_save()
	var absent_before := 0
	if _save != null:
		absent_before = _save.regular_absent.size()
	# Leave the Herald's leftover summons (encounter_index -1) and look for a
	# streamed T0 pack. Chunk (1, 0) starts at x = 2048.
	await _walk_toward(Vector2(2200, 400), 80.0, 10.0)
	var enemy := await _find_t0_regular(8.0)
	if enemy == null:
		await _walk_toward(Vector2(2200, -400), 80.0, 8.0)
		enemy = await _find_t0_regular(6.0)
	if enemy == null:
		await _fail("no live T0 chunk RegularEnemy (non-elite, encounter_index >= 0) found in the stream")
		return false
	var hp_text := "?"
	if enemy.health != null:
		hp_text = str(enemy.health.hp)
	print("PLAYTEST_PACK_SPOT pos=%s name=%s arch=%s chunk=%s encounter=%d hp=%s" % [
		enemy.global_position, enemy.name, enemy.archetype, enemy.chunk, enemy.encounter_index, hp_text
	])
	var pack_chunk := enemy.chunk
	var pack_index := enemy.encounter_index
	var killed := 0
	var member: RegularEnemy = enemy
	while member != null:
		if not await _fire_until(member, func() -> bool: return not is_instance_valid(member) or not member.is_alive(), 30.0, 140.0):
			var left: Variant = -1
			if is_instance_valid(member) and member.health != null:
				left = member.health.hp
			await _fail("could not kill T0 pack member %s (hp=%s pos=%s)" % [
				member.name if is_instance_valid(member) else "?",
				left,
				member.global_position if is_instance_valid(member) else Vector2.ZERO
			])
			return false
		killed += 1
		member = _pack_member(pack_chunk, pack_index)
	# regular_absent is written when the empty encounter's chunk unloads
	# (3×3 Chebyshev ring). Walk two chunks away so that happens.
	var unload_at := Vector2((pack_chunk.x + 2) * 2048 + 200, pack_chunk.y * 2048 + 200)
	await _walk_toward(unload_at, 80.0, 20.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_save = _read_save()
	var absent_after := 0 if _save == null else _save.regular_absent.size()
	if absent_after <= absent_before:
		await _fail("cleared T0 encounter %s/%d and left the chunk, but regular_absent did not update (before=%d after=%d killed=%d)" % [
			pack_chunk, pack_index, absent_before, absent_after, killed
		])
		return false
	print("PLAYTEST_PACK_OK killed=%d regular_absent=%d" % [killed, absent_after])
	return true


func _find_t0_regular(timeout: float) -> RegularEnemy:
	var t := 0.0
	while t < timeout:
		var found := _nearest_t0_regular()
		if found != null:
			return found
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	return null


func _pack_member(pack_chunk: Vector2i, pack_index: int) -> RegularEnemy:
	for node: Node in get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var enemy := node as RegularEnemy
		if enemy == null or enemy is EliteEnemy:
			continue
		if enemy.chunk != pack_chunk or enemy.encounter_index != pack_index:
			continue
		if enemy.is_alive():
			return enemy
	return null


func _nearest_t0_regular() -> RegularEnemy:
	var best: RegularEnemy = null
	var best_d := INF
	for node: Node in get_tree().get_nodes_in_group(RegularEnemy.GROUP):
		var enemy := node as RegularEnemy
		if enemy == null or enemy is EliteEnemy:
			continue
		# Herald / elite summons use encounter_index -1 and do not write regular_absent.
		if enemy.encounter_index < 0:
			continue
		if not enemy.is_alive():
			continue
		var d := enemy.global_position.distance_to(_player.global_position)
		if d < best_d:
			best = enemy
			best_d = d
	return best


func _damage_die_respawn() -> bool:
	_release_all_input()
	_protect_player(false)
	# Engine i-frames from a mid-fight graze would block the first hit; wait them out.
	var wait_iframes := 0.0
	while wait_iframes < 1.0 and _player.health.is_engine_invulnerable():
		await get_tree().process_frame
		wait_iframes += get_process_delta_time()
	var max_hp := _player.health.max_hp
	var before := _player.health.hp
	var first := _player.health.try_damage(1.0)
	if first != Health.DamageResult.APPLIED:
		await _fail("try_damage(1) did not apply (result=%s hp=%s)" % [first, _player.health.hp])
		return false
	if _player.health.hp >= before or _player.health.hp >= max_hp:
		await _fail("damage was not applied (hp %s -> %s)" % [before, _player.health.hp])
		return false
	print("PLAYTEST_DAMAGE_OK hp=%s/%s" % [_player.health.hp, max_hp])
	# Engine i-frames are 0.75 s and cannot be pierced. Probe immediately,
	# then wait them out before the lethal hit.
	var blocked := _player.health.try_damage(1.0)
	if blocked != Health.DamageResult.BLOCKED_ENGINE:
		await _fail("engine i-frames did not block a follow-up hit (result=%s)" % blocked)
		return false
	await get_tree().create_timer(_player.health.invulnerability_time + 0.15).timeout
	var died := false
	_player.died.connect(func() -> void: died = true, CONNECT_ONE_SHOT)
	var lethal := _player.health.try_damage(max_hp + 1.0)
	if lethal != Health.DamageResult.APPLIED:
		await _fail("lethal try_damage did not apply (result=%s)" % lethal)
		return false
	await get_tree().process_frame
	if not died and not _player.is_dead():
		await _fail("player did not die after a lethal hit (hp=%s)" % _player.health.hp)
		return false
	var respawned := false
	var t := 0.0
	var budget := _main.respawn_delay + 1.0
	while t < budget:
		await get_tree().process_frame
		t += get_process_delta_time()
		if not _player.is_dead() and _player.health.hp >= max_hp:
			respawned = true
			break
	if not respawned:
		await _fail("player did not respawn with full hp after %.1fs (dead=%s hp=%s)" % [budget, _player.is_dead(), _player.health.hp])
		return false
	# Until a Warden kill exists, respawn is the origin (vertical-slice §1). Do
	# not assert a post-kill arena point: Q26 is provisional.
	print("PLAYTEST_RESPAWN_OK hp=%s pos=%s delay=%.1fs" % [_player.health.hp, _player.global_position, _main.respawn_delay])
	return true


func _assert_bullets_released() -> bool:
	_release_aim_and_fire()
	if not await _wait_alive_down(0, 6.0):
		await _fail("bullets were not released (alive=%d)" % _manager.alive_count())
		return false
	print("PLAYTEST_BULLETS_OK alive=%d" % _manager.alive_count())
	return true


func _wait_alive_down(target: int, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if _manager.alive_count() <= target:
			return true
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	return _manager.alive_count() <= target


func _callable_true(done: Callable) -> bool:
	var value: Variant = done.call()
	return value == true


func _fire_until(target: Node2D, done: Callable, timeout: float, close_range: float = 0.0) -> bool:
	var t := 0.0
	Input.action_press("fire")
	while t < timeout:
		if not is_instance_valid(target) or _callable_true(done):
			_release_aim_and_fire()
			_release_move()
			return true
		_aim_at(target.global_position)
		if close_range > 0.0:
			var gap := target.global_position - _player.global_position
			var dist := gap.length()
			# Keep a standoff. Standing inside the body (seen on web: player and
			# Herald at the same point) makes BasicShot barely land.
			if dist > close_range + 40.0:
				_set_move(gap)
			elif dist < maxf(close_range - 40.0, 40.0) and dist > 0.001:
				_set_move(-gap)
			else:
				_release_move()
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	_release_aim_and_fire()
	_release_move()
	return not is_instance_valid(target) or _callable_true(done)


func _walk_toward(world: Vector2, stop_dist: float, timeout: float) -> bool:
	var t := 0.0
	while t < timeout:
		if not is_instance_valid(_player):
			_release_move()
			return false
		var delta := world - _player.global_position
		if delta.length() <= stop_dist:
			_release_move()
			return true
		_set_move(delta)
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	_release_move()
	return is_instance_valid(_player) and _player.global_position.distance_to(world) <= stop_dist


func _aim_at(world: Vector2) -> void:
	# Headless has no real mouse. Tests already drive aim by forcing gamepad
	# mode and pressing aim_* (see tests/unit/test_player_input.gd).
	InputDevice.current = InputDevice.Kind.GAMEPAD
	var dir := world - _player.global_position
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	_release_aim()
	if dir.x > 0.01:
		Input.action_press("aim_right", clampf(dir.x, 0.0, 1.0))
	elif dir.x < -0.01:
		Input.action_press("aim_left", clampf(-dir.x, 0.0, 1.0))
	if dir.y > 0.01:
		Input.action_press("aim_down", clampf(dir.y, 0.0, 1.0))
	elif dir.y < -0.01:
		Input.action_press("aim_up", clampf(-dir.y, 0.0, 1.0))


func _set_move(delta: Vector2) -> void:
	_release_move()
	var dir := delta
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	if dir.x > 0.01:
		Input.action_press("move_right", clampf(dir.x, 0.0, 1.0))
	elif dir.x < -0.01:
		Input.action_press("move_left", clampf(-dir.x, 0.0, 1.0))
	if dir.y > 0.01:
		Input.action_press("move_down", clampf(dir.y, 0.0, 1.0))
	elif dir.y < -0.01:
		Input.action_press("move_up", clampf(-dir.y, 0.0, 1.0))


func _protect_player(on: bool) -> void:
	if _player == null or _player.health == null:
		return
	_player.health.set_invulnerable(on)


func _release_aim() -> void:
	Input.action_release("aim_left")
	Input.action_release("aim_right")
	Input.action_release("aim_up")
	Input.action_release("aim_down")


func _release_move() -> void:
	Input.action_release("move_left")
	Input.action_release("move_right")
	Input.action_release("move_up")
	Input.action_release("move_down")


func _release_aim_and_fire() -> void:
	_release_aim()
	Input.action_release("fire")


func _release_all_input() -> void:
	_release_aim_and_fire()
	_release_move()
	InputDevice.current = InputDevice.Kind.KEYBOARD_MOUSE


func _fail(reason: String) -> void:
	_fail_now(reason)
	await get_tree().process_frame


func _fail_now(reason: String) -> void:
	if _finished:
		return
	_finished = true
	_release_all_input()
	printerr("PLAYTEST_FAIL %s" % reason)
	print("PLAYTEST_DONE fail")
	get_tree().quit(1)
