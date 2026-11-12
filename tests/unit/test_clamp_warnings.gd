extends GutTest
## A finite value outside its BulletLimits range is clamped (always was) and now says
## so: one rate-limited ScriptWarnings key per path and field. QA's PR #8 note: a
## script asking for radius = 1e9 got 256 with no feedback.
## Also the reworded owner-inheritance warnings (spawn from a hook vs spawn_child).

const DT := 1.0 / 60.0

var pool: BulletPool
var manager: BulletManager


## Writes one field of the bullet whose update hook runs.
class Writer:
	extends BulletBehavior
	var field := ""
	var value := 0.0

	func on_update(pool: BulletPool, index: int, _delta: float) -> void:
		match field:
			"radius":
				pool.radius[index] = value
			"lifetime":
				pool.lifetime[index] = value
			"accel":
				pool.accel[index] = value
			"turn_rate":
				pool.turn_rate[index] = value
			"damage":
				pool.damage[index] = value
			"vel":
				pool.vel[index] = Vector2(value, 0.0)


func before_each() -> void:
	ScriptWarnings.reset()
	pool = BulletPool.new(64)
	manager = BulletManager.new()
	manager.backend_preference = "gdscript"
	manager.capacity = 64
	manager.world_bounds = Rect2(-1000, -1000, 2000, 2000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)


func _req() -> ShotRequest:
	var r := ShotRequest.with_velocity(Vector2(10, 10), Vector2(60, 0))
	r.lifetime = 5.0
	return r


## (request field, written value, warning field, BulletLimits name)
func _spawn_cases() -> Array:
	return [
		["radius", 1.0e9, "radius", "MAX_RADIUS"],
		["radius", -2.0, "radius", "MAX_RADIUS"],
		["lifetime", 1000.0, "lifetime", "MAX_LIFETIME"],
		["lifetime", -1.0, "lifetime", "MAX_LIFETIME"],
		["acceleration", 5.0e6, "acceleration", "MAX_ACCELERATION"],
		["acceleration", -5.0e6, "acceleration", "MAX_ACCELERATION"],
		["turn_rate", 5000.0, "turn_rate", "MAX_TURN_RATE"],
		["turn_rate", -5000.0, "turn_rate", "MAX_TURN_RATE"],
		["damage", 5000.0, "damage", "MAX_DAMAGE"],
		["damage", -1.0, "damage", "MAX_DAMAGE"],
		["param_a", 1.0e31, "param_a", "MAX_PARAM"],
		["param_b", -1.0e31, "param_b", "MAX_PARAM"],
	]


func _all_clamp_keys() -> Array[String]:
	var keys: Array[String] = []
	for where: String in ["BulletPool.spawn", "BulletPool.spawn_simple", "BulletPool.set_velocity", "BulletPool.velocity", "BulletPool.hook_write"]:
		for field: String in ["speed", "radius", "lifetime", "acceleration", "turn_rate", "damage", "param_a", "param_b"]:
			keys.append("%s.clamp.%s" % [where, field])
	return keys


func _total_clamp_warnings() -> int:
	var n := 0
	for key: String in _all_clamp_keys():
		n += ScriptWarnings.count(key)
	return n


# --- spawn ------------------------------------------------------------------------------

func test_spawn_warns_once_per_clamped_field_and_still_clamps() -> void:
	for c: Array in _spawn_cases():
		ScriptWarnings.reset()
		var request := _req()
		var field: String = c[0]
		request.set(field, c[1])
		var slot := pool.spawn(request)
		assert_gte(slot, 0, "%s: still spawned" % field)
		var key := "BulletPool.spawn.clamp.%s" % c[2]
		assert_eq(ScriptWarnings.count(key), 1, "%s = %s warns once under %s" % [field, c[1], key])
		assert_eq(_total_clamp_warnings(), 1, "%s = %s warns about that field only" % [field, c[1]])
		var msg := ScriptWarnings.last_message(key)
		assert_string_contains(msg, str(c[2]), "the message names the field")
		assert_string_contains(msg, "BulletLimits.%s" % c[3], "and the limit")
		assert_string_contains(msg, "clamped", "and says what happened")
		pool.clear()


func test_spawn_warns_about_speed() -> void:
	var request := _req()
	request.velocity = Vector2(0, -9000)
	assert_gte(pool.spawn(request), 0)
	assert_eq(ScriptWarnings.count("BulletPool.spawn.clamp.speed"), 1)
	assert_string_contains(ScriptWarnings.last_message("BulletPool.spawn.clamp.speed"), "9000", "the asked speed")
	assert_string_contains(ScriptWarnings.last_message("BulletPool.spawn.clamp.speed"), "4000", "and the ceiling")
	assert_eq(_total_clamp_warnings(), 1)


func test_several_clamped_fields_each_get_their_own_warning() -> void:
	var request := _req()
	request.radius = 1.0e6
	request.damage = 1.0e6
	request.lifetime = 1.0e6
	request.velocity = Vector2(1.0e5, 0)
	pool.spawn(request)
	for field: String in ["radius", "damage", "lifetime", "speed"]:
		assert_eq(ScriptWarnings.count("BulletPool.spawn.clamp.%s" % field), 1, field)
	assert_eq(_total_clamp_warnings(), 4)


func test_spawn_values_inside_their_ranges_stay_silent_including_the_edges() -> void:
	var edge := _req()
	edge.radius = BulletLimits.MAX_RADIUS
	edge.lifetime = BulletLimits.MAX_LIFETIME
	edge.acceleration = -BulletLimits.MAX_ACCELERATION
	edge.turn_rate = BulletLimits.MAX_TURN_RATE
	edge.damage = BulletLimits.MAX_DAMAGE
	edge.param_a = BulletLimits.MAX_PARAM
	edge.param_b = -BulletLimits.MAX_PARAM
	edge.velocity = Vector2(BulletLimits.MAX_SPEED, 0)
	assert_gte(pool.spawn(edge), 0)
	var zero := _req()
	zero.radius = 0.0
	zero.lifetime = 0.0
	zero.damage = 0.0
	assert_gte(pool.spawn(zero), 0)
	assert_gte(pool.spawn(_req()), 0)
	assert_eq(_total_clamp_warnings(), 0)


func test_spawn_simple_warns_about_speed_radius_and_lifetime() -> void:
	assert_gte(pool.spawn_simple(Vector2.ZERO, Vector2(0, 1.0e5), 5.0, 3.0), 0)
	assert_eq(ScriptWarnings.count("BulletPool.spawn_simple.clamp.speed"), 1)
	assert_gte(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), 5.0, 1.0e5), 0)
	assert_eq(ScriptWarnings.count("BulletPool.spawn_simple.clamp.radius"), 1)
	assert_gte(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), 1.0e5, 3.0), 0)
	assert_eq(ScriptWarnings.count("BulletPool.spawn_simple.clamp.lifetime"), 1)
	assert_gte(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), -3.0, 3.0), 0)
	assert_eq(ScriptWarnings.count("BulletPool.spawn_simple.clamp.lifetime"), 2, "a negative lifetime is clamped too")
	assert_eq(_total_clamp_warnings(), 4)
	var before := _total_clamp_warnings()
	assert_gte(pool.spawn_simple(Vector2.ZERO, Vector2(10, 0), 5.0, 3.0), 0)
	assert_eq(_total_clamp_warnings(), before, "an ordinary plain bullet is silent")


# --- set_velocity / sanitize_velocity / hook writes ----------------------------------------

func test_set_velocity_over_the_ceiling_warns_and_in_range_does_not() -> void:
	var slot := pool.spawn(_req())
	assert_true(pool.set_velocity(slot, Vector2(0, 5000)))
	assert_eq(ScriptWarnings.count("BulletPool.set_velocity.clamp.speed"), 1)
	assert_true(pool.set_velocity(slot, Vector2(0, 100)))
	assert_true(pool.set_velocity(slot, Vector2(0, BulletLimits.MAX_SPEED)))
	assert_eq(_total_clamp_warnings(), 1)
	assert_true(pool.set_velocity(slot, Vector2(1.0e30, 1.0e30)), "an overflowing square still reports a finite speed")
	assert_string_contains(ScriptWarnings.last_message("BulletPool.set_velocity.clamp.speed"), "1.414e30", "length without overflow")


func test_sanitize_velocity_warns() -> void:
	var slot := pool.spawn(_req())
	pool.vel[slot] = Vector2(0, 7000)
	assert_true(pool.sanitize_velocity(slot))
	assert_eq(ScriptWarnings.count("BulletPool.velocity.clamp.speed"), 1)
	assert_true(pool.sanitize_velocity(slot), "now inside the ceiling")
	assert_eq(_total_clamp_warnings(), 1)


func _hook_write(field: String, value: float) -> void:
	var w := Writer.new()
	w.field = field
	w.value = value
	var r := _req()
	r.behavior_id = manager.register_behavior(w)
	manager.spawn(r)
	manager.step(DT)


func test_a_hook_write_out_of_range_warns_per_field() -> void:
	for c: Array in [
		["radius", 5000.0, "radius"],
		["radius", -1.0, "radius"],
		["lifetime", 9999.0, "lifetime"],
		["accel", 1.0e9, "acceleration"],
		["turn_rate", -1.0e5, "turn_rate"],
		["damage", 99999.0, "damage"],
		["vel", 9000.0, "speed"],
	]:
		ScriptWarnings.reset()
		manager.clear_bullets()
		var field: String = c[0]
		var written: float = c[1]
		_hook_write(field, written)
		var key := "BulletPool.hook_write.clamp.%s" % c[2]
		assert_eq(ScriptWarnings.count(key), 1, "%s = %s warns under %s" % [field, written, key])
		assert_eq(_total_clamp_warnings(), 1, "%s = %s: that one only" % [field, written])
		assert_string_contains(ScriptWarnings.last_message(key), "clamped")


func test_a_hook_writing_in_range_values_is_silent() -> void:
	_hook_write("radius", 200.0)
	_hook_write("damage", 2.0)
	_hook_write("vel", 3999.0)
	assert_eq(_total_clamp_warnings(), 0)


func test_clamp_warnings_are_rate_limited_per_key() -> void:
	for k in 50:
		var request := _req()
		request.radius = 1.0e9
		pool.spawn(request)
		pool.clear()
	var key := "BulletPool.spawn.clamp.radius"
	assert_eq(ScriptWarnings.count(key), 50, "every clamp is counted")
	assert_eq(ScriptWarnings.printed_count(key), ScriptWarnings.LIMIT, "but only LIMIT are printed")


# --- owner-inheritance warning wording ---------------------------------------------------------

class SpawnsEnemy:
	extends BulletBehavior
	var request: ShotRequest

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		emitter.request_shot_id(request)


func test_the_hook_spawn_warning_says_a_hook_and_names_the_inherited_owner() -> void:
	var s := SpawnsEnemy.new()
	s.request = _req()
	s.request.owner_layer = Layers.ENEMY
	var r := _req()
	r.behavior_id = manager.register_behavior(s)
	manager.spawn(r)
	manager.step(DT)
	var msg := ScriptWarnings.last_message("BulletManager.spawn.owner")
	assert_string_contains(msg, "BulletManager.spawn:")
	assert_string_contains(msg, "a hook")
	assert_string_contains(msg, "inherits")


func test_the_spawn_child_warning_does_not_blame_a_hook() -> void:
	var parent := manager.emitter.request_shot_id(_req())
	var asks := _req()
	asks.owner_layer = Layers.ENEMY
	assert_gte(manager.spawn_child(parent, asks), 0)
	var msg := ScriptWarnings.last_message("BulletManager.spawn.owner")
	assert_string_contains(msg, "BulletManager.spawn_child:")
	assert_string_contains(msg, "a child spawn")
	assert_false("a hook" in msg, "the parent's hook is not what asked")


func test_the_pool_backstop_warning_is_neutral_about_who_asked() -> void:
	# A child of an enemy parent requested from inside a player bullet's hook: the manager
	# picks ENEMY from the parent id, the pool backstop forces PLAYER and says why.
	var enemy_request := _req()
	enemy_request.owner_layer = Layers.ENEMY
	var enemy_parent := manager.emitter.request_shot_id(enemy_request)
	var spawner := SpawnsChildOf.new()
	spawner.parent_id = enemy_parent
	spawner.request = _req()
	var r := _req()
	r.behavior_id = manager.register_behavior(spawner)
	manager.spawn(r)
	manager.step(DT)
	var msg := ScriptWarnings.last_message("BulletPool.spawn.owner")
	assert_string_contains(msg, "a shot with owner_layer")
	assert_string_contains(msg, "while the hook of a bullet owned by")
	assert_false("a hook asked" in msg, "it was not necessarily a hook that asked")
	assert_string_contains(msg, "spawn_child()")
	assert_eq(manager.pool.owner_counts[BulletPool.OWNER_ENEMY], 1, "only the original enemy parent")


class SpawnsChildOf:
	extends BulletBehavior
	var parent_id := 0
	var request: ShotRequest

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		emitter.request_child_shot_id(parent_id, request)
