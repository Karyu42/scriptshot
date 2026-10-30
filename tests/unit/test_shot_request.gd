extends GutTest
## ShotRequest data contract.


func test_polar_builds_velocity_from_heading_and_speed() -> void:
	var r := ShotRequest.polar(Vector2(5, 6), PI / 2.0, 200.0)
	assert_eq(r.position, Vector2(5, 6))
	assert_almost_eq(r.velocity.x, 0.0, 0.001)
	assert_almost_eq(r.velocity.y, 200.0, 0.001)


func test_with_velocity() -> void:
	var r := ShotRequest.with_velocity(Vector2(1, 2), Vector2(3, 4))
	assert_eq(r.velocity, Vector2(3, 4))


func test_defaults() -> void:
	var r := ShotRequest.new()
	assert_true(is_nan(r.angle), "angle defaults to 'face velocity'")
	assert_eq(r.behavior_id, 0)
	assert_eq(r.hit_mask, Layers.ENEMY)
	assert_gt(r.lifetime, 0.0)


func test_reset_restores_defaults_for_reuse() -> void:
	var r := ShotRequest.new()
	r.position = Vector2(9, 9)
	r.velocity = Vector2(1, 1)
	r.angle = 1.0
	r.lifetime = 9.0
	r.radius = 9.0
	r.damage = 9.0
	r.hit_mask = 0
	r.behavior_id = 3
	r.acceleration = 1.0
	r.turn_rate = 1.0
	r.pierce = 1
	r.param_a = 1.0
	r.param_b = 1.0
	r.user = {"a": 1}
	r.reset()
	var fresh := ShotRequest.new()
	for prop: String in ["position", "velocity", "lifetime", "radius", "damage", "hit_mask", "color", "behavior_id", "acceleration", "turn_rate", "pierce", "param_a", "param_b", "user"]:
		var got: Variant = r.get(prop)
		var want: Variant = fresh.get(prop)
		var same: bool = got == want
		assert_true(same, "%s was not reset to its default" % prop)
	assert_true(is_nan(r.angle))


func test_layers_are_distinct_bits_matching_project_layer_order() -> void:
	var all: Array[int] = [Layers.PLAYER, Layers.ENEMY, Layers.PLAYER_BULLET, Layers.ENEMY_BULLET, Layers.WORLD]
	var seen := 0
	for bit: int in all:
		assert_eq(seen & bit, 0, "overlapping layer bit")
		seen |= bit
	assert_eq(Layers.PLAYER, 1)
	assert_eq(Layers.WORLD, 16)
	for i in all.size():
		var layer_name: String = ProjectSettings.get_setting("layer_names/2d_physics/layer_%d" % (i + 1))
		var expected_names: Array[String] = ["player", "enemy", "player_bullet", "enemy_bullet", "world"]
		assert_eq(layer_name, expected_names[i])
