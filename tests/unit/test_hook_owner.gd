extends GutTest
## Bullets spawned from a hook take owner_layer from the bullet (or emitter)
## whose hook spawned them, never from the request, the behavior record or a
## script-passed field. Reflect stays the only way to change an owner.

const DT := 1.0 / 60.0

var manager: BulletManager


## Spawns one child from on_spawn / on_update / on_hit / on_despawn, using the
## request it is given (so a test can try to ask for any owner).
class Spawner:
	extends BulletBehavior
	var child_request: ShotRequest
	var on_update_children := 0
	var on_spawn_child := false
	var on_despawn_child := false
	var child_ids: Array[int] = []

	func on_spawn(_pool: BulletPool, _index: int) -> void:
		if on_spawn_child:
			_spawn()

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		if on_update_children > 0:
			on_update_children -= 1
			_spawn()

	func on_despawn(_pool: BulletPool, _index: int, _reason: int) -> void:
		if on_despawn_child:
			_spawn()

	func _spawn() -> void:
		child_ids.append(emitter.request_shot_id(child_request))


func before_each() -> void:
	ScriptWarnings.reset()
	manager = BulletManager.new()
	manager.capacity = 64
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _child_request(owner_layer: int, mask: int = -1) -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2(50, 50), Vector2(0, 100))
	r.lifetime = 5.0
	r.owner_layer = owner_layer
	if mask >= 0:
		r.hit_mask = mask
	return r


## A parent bullet of `owner_layer` whose hooks run `spawner`.
func _parent(spawner: Spawner, owner_layer: int) -> int:
	var r := ShotRequest.with_velocity(Vector2.ZERO, Vector2(10, 0))
	r.lifetime = 5.0
	r.owner_layer = owner_layer
	r.hit_mask = Layers.hostile_to(owner_layer)
	r.behavior_id = manager.register_behavior(spawner)
	return manager.emitter.request_shot_id(r)


func _owner_of(id: int) -> int:
	return manager.pool.owner_layer[manager.pool.slot_of(id)]


func _mask_of(id: int) -> int:
	return manager.pool.hit_mask[manager.pool.slot_of(id)]


# --- the three required cases ------------------------------------------------------

func test_an_enemy_owned_parent_spawns_enemy_owned_children() -> void:
	var s := Spawner.new()
	s.on_update_children = 1
	s.child_request = _child_request(Layers.ENEMY, Layers.PLAYER)
	_parent(s, Layers.ENEMY)
	manager.step(DT)
	assert_eq(s.child_ids.size(), 1)
	assert_eq(_owner_of(s.child_ids[0]), Layers.ENEMY)
	assert_eq(_mask_of(s.child_ids[0]), Layers.PLAYER, "and it can hurt the player")
	assert_eq(ScriptWarnings.count("BulletManager.spawn.owner"), 0, "no warning when nothing differs")


func test_an_enemy_parent_whose_request_leaves_the_default_owner_still_makes_enemy_children() -> void:
	var s := Spawner.new()
	s.on_update_children = 1
	s.child_request = ShotRequest.with_velocity(Vector2(50, 50), Vector2(0, 100))
	s.child_request.lifetime = 5.0
	assert_eq(s.child_request.owner_layer, Layers.PLAYER, "the request default")
	_parent(s, Layers.ENEMY)
	manager.step(DT)
	assert_eq(_owner_of(s.child_ids[0]), Layers.ENEMY)
	assert_eq(_mask_of(s.child_ids[0]), Layers.PLAYER, "mask follows the inherited owner, not the default one")


func test_a_player_parent_cannot_mint_enemy_owned_children() -> void:
	var s := Spawner.new()
	s.on_update_children = 1
	s.child_request = _child_request(Layers.ENEMY, Layers.PLAYER)
	_parent(s, Layers.PLAYER)
	manager.step(DT)
	assert_eq(s.child_ids.size(), 1, "the child is still spawned")
	var child := s.child_ids[0]
	assert_eq(_owner_of(child), Layers.PLAYER)
	assert_eq(_mask_of(child), Layers.ENEMY, "it cannot hit the player it was never allowed to hurt")
	assert_eq(manager.pool.owner_counts[BulletPool.OWNER_ENEMY], 0, "no enemy-owned bullet exists")
	assert_eq(manager.pool.owner_counts[BulletPool.OWNER_PLAYER], 2)


func test_a_differing_team_gives_a_capped_warning_and_is_ignored() -> void:
	var s := Spawner.new()
	s.on_update_children = 10
	s.child_request = _child_request(Layers.ENEMY)
	_parent(s, Layers.PLAYER)
	for i in 10:
		manager.step(DT)
	assert_eq(s.child_ids.size(), 10)
	for id in s.child_ids:
		assert_eq(_owner_of(id), Layers.PLAYER)
	assert_eq(ScriptWarnings.count("BulletManager.spawn.owner"), 10, "every attempt is counted")
	assert_eq(
		ScriptWarnings.printed_count("BulletManager.spawn.owner"), ScriptWarnings.LIMIT, "but only LIMIT are printed"
	)


# --- details ----------------------------------------------------------------------

func test_the_callers_request_is_handed_back_unchanged() -> void:
	var s := Spawner.new()
	s.on_update_children = 1
	s.child_request = _child_request(Layers.ENEMY, Layers.PLAYER)
	_parent(s, Layers.PLAYER)
	manager.step(DT)
	assert_eq(s.child_request.owner_layer, Layers.ENEMY)
	assert_eq(s.child_request.hit_mask, Layers.PLAYER)


func test_a_matching_owner_keeps_the_requests_own_mask() -> void:
	var s := Spawner.new()
	s.on_update_children = 1
	s.child_request = _child_request(Layers.ENEMY, Layers.PLAYER | Layers.ENEMY)
	_parent(s, Layers.ENEMY)
	manager.step(DT)
	# The pool strips the owner's own layer, as for every spawn.
	assert_eq(_mask_of(s.child_ids[0]), Layers.PLAYER)


func test_on_spawn_and_on_despawn_hooks_inherit_too() -> void:
	var s := Spawner.new()
	s.on_spawn_child = true
	s.on_despawn_child = true
	s.child_request = _child_request(Layers.PLAYER)
	var id := _parent(s, Layers.ENEMY)
	assert_eq(s.child_ids.size(), 1, "from on_spawn")
	assert_eq(_owner_of(s.child_ids[0]), Layers.ENEMY)
	manager.pool.mark_dead(manager.pool.slot_of(id))
	manager.step(DT)
	assert_eq(s.child_ids.size(), 2, "from on_despawn")
	assert_eq(_owner_of(s.child_ids[1]), Layers.ENEMY)


func test_children_of_children_keep_the_original_owner() -> void:
	var inner := Spawner.new()
	inner.on_spawn_child = true
	inner.child_request = _child_request(Layers.PLAYER)
	var outer := Spawner.new()
	outer.on_update_children = 1
	outer.child_request = _child_request(Layers.PLAYER)
	outer.child_request.behavior_id = manager.register_behavior(inner)
	_parent(outer, Layers.ENEMY)
	manager.step(DT)
	assert_eq(outer.child_ids.size(), 1)
	assert_eq(inner.child_ids.size(), 1, "the child's own on_spawn spawned a grandchild")
	assert_eq(_owner_of(outer.child_ids[0]), Layers.ENEMY)
	assert_eq(_owner_of(inner.child_ids[0]), Layers.ENEMY)


func test_spawns_outside_any_hook_use_the_requests_owner_as_before() -> void:
	var s := Spawner.new()
	s.child_request = _child_request(Layers.ENEMY)
	_parent(s, Layers.PLAYER)
	manager.step(DT)
	var id := manager.emitter.request_shot_id(_child_request(Layers.ENEMY))
	assert_eq(_owner_of(id), Layers.ENEMY, "a turret or a boss emitter names its own team")
	assert_eq(ScriptWarnings.count("BulletManager.spawn.owner"), 0)
	# And after a hook ran, the context is gone again.
	s.on_update_children = 1
	manager.step(DT)
	var id2 := manager.emitter.request_shot_id(_child_request(Layers.ENEMY))
	assert_eq(_owner_of(id2), Layers.ENEMY)


func test_inherited_children_count_against_the_parents_faction_limits() -> void:
	manager.set_bullet_limits(10, 4)
	var s := Spawner.new()
	s.on_update_children = 100
	s.child_request = _child_request(Layers.ENEMY)
	_parent(s, Layers.PLAYER)
	for i in 20:
		manager.step(DT)
	assert_eq(manager.pool.count, 6, "a player bullet's children are capped at cap - reserve (10 - 4)")
	assert_eq(manager.pool.owner_counts[BulletPool.OWNER_ENEMY], 0)
	assert_true(manager.pool.dropped_total > 0)


func test_a_reflected_parent_hands_its_new_owner_to_later_children() -> void:
	var s := Spawner.new()
	s.on_update_children = 2
	s.child_request = _child_request(Layers.PLAYER)
	var id := _parent(s, Layers.PLAYER)
	manager.step(DT)
	assert_true(manager.reflect(id, Layers.ENEMY, false, 1.0, true), "the only way to change an owner (keeping the script)")
	manager.step(DT)
	assert_eq(_owner_of(s.child_ids[0]), Layers.PLAYER)
	assert_eq(_owner_of(s.child_ids[1]), Layers.ENEMY)


# --- spawn_child: the path the batch/Lua commit takes after the hook returned ------

func test_spawn_child_inherits_from_the_parent_id() -> void:
	var s := Spawner.new()
	var parent := _parent(s, Layers.ENEMY)
	var child_slot := manager.spawn_child(parent, _child_request(Layers.PLAYER))
	assert_true(child_slot >= 0)
	assert_eq(manager.pool.owner_layer[child_slot], Layers.ENEMY)
	assert_eq(manager.pool.hit_mask[child_slot], Layers.PLAYER)
	assert_eq(ScriptWarnings.count("BulletManager.spawn.owner"), 0, "the default owner is not an explicit ask")


func test_spawn_child_ignores_an_explicit_other_team_with_a_warning() -> void:
	var s := Spawner.new()
	var parent := _parent(s, Layers.PLAYER)
	var child_slot := manager.spawn_child(parent, _child_request(Layers.ENEMY))
	assert_eq(manager.pool.owner_layer[child_slot], Layers.PLAYER)
	assert_eq(ScriptWarnings.count("BulletManager.spawn.owner"), 1)


func test_spawn_child_through_the_emitter() -> void:
	var s := Spawner.new()
	var parent := _parent(s, Layers.ENEMY)
	var id := manager.emitter.request_child_shot_id(parent, _child_request(Layers.PLAYER))
	assert_true(id > 0)
	assert_eq(_owner_of(id), Layers.ENEMY)


func test_spawn_child_of_a_dead_parent_is_refused() -> void:
	var s := Spawner.new()
	var parent := _parent(s, Layers.ENEMY)
	manager.pool.mark_dead(manager.pool.slot_of(parent))
	manager.pool.flush_dead()
	assert_eq(manager.spawn_child(parent, _child_request(Layers.ENEMY)), -1)
	assert_eq(manager.emitter.request_child_shot_id(parent, _child_request(Layers.ENEMY)), -1)
	assert_eq(manager.pool.count, 0)
	assert_eq(ScriptWarnings.count("BulletManager.spawn_child.parent"), 2)


func test_a_parent_killed_this_tick_can_still_have_its_children_spawned() -> void:
	var s := Spawner.new()
	var parent := _parent(s, Layers.ENEMY)
	manager.pool.mark_dead(manager.pool.slot_of(parent))
	var slot := manager.spawn_child(parent, _child_request(Layers.ENEMY))
	assert_true(slot >= 0, "marked dead is not yet removed: a commit after the hook still finds it")
	assert_eq(manager.pool.owner_layer[slot], Layers.ENEMY)
