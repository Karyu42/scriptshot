extends GutTest
## L0 Herald trigger: leaving the disk, or 60 s after all three targets are cleared.


func test_leaving_the_disk_arms_once_and_reentry_does_not_reset() -> void:
	_rig()
	var arm := _arm
	var player := _body
	watch_signals(arm)
	player.position = Vector2(512, 0)
	arm.advance(0.0)
	assert_false(arm.armed, "the rim is still inside")
	player.position = Vector2(512.1, 0)
	arm.advance(0.0)
	assert_true(arm.armed)
	assert_true(arm.left_safe_zone)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)
	assert_eq(arm.clear_seconds_left, -1.0)
	player.position = Vector2.ZERO
	arm.advance(30.0)
	arm.advance(60.0)
	assert_signal_emit_count(arm, "herald_armed", 1)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)


func test_clearing_the_targets_arms_a_60s_clock_unless_the_player_already_left() -> void:
	_rig()
	var arm := _arm
	var dummies := _dummies
	_kill(dummies[0])
	_kill(dummies[1])
	arm.advance(1.0)
	assert_false(arm.tutorial_cleared)
	assert_eq(arm.clear_seconds_left, -1.0)
	_kill(dummies[2])
	assert_true(arm.tutorial_cleared)
	assert_false(arm.armed)
	assert_almost_eq(arm.clear_seconds_left, HeraldArm.CLEAR_DELAY, 0.001)
	arm.advance(59.0)
	assert_false(arm.armed)
	assert_almost_eq(arm.clear_seconds_left, 1.0, 0.001)
	arm.advance(1.0)
	assert_true(arm.armed)
	assert_eq(arm.arm_reason, HeraldArm.REASON_TUTORIAL)


func test_leaving_during_the_clear_clock_wins() -> void:
	_rig()
	var arm := _arm
	var player := _body
	var dummies := _dummies
	for dummy in dummies:
		_kill(dummy)
	arm.advance(10.0)
	assert_false(arm.armed)
	player.position = Vector2(0, 600)
	arm.advance(0.0)
	assert_true(arm.armed)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)
	assert_eq(arm.clear_seconds_left, -1.0)
	arm.advance(100.0)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)


func test_respawn_does_not_unclear_and_a_prior_exit_still_wins() -> void:
	_rig()
	var arm := _arm
	var player := _body
	var dummies := _dummies
	player.position = Vector2(700, 0)
	arm.advance(0.0)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)
	for dummy in dummies:
		_kill(dummy)
	assert_true(arm.tutorial_cleared)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)
	var first: TrainingDummy = dummies[0]
	first._process(first.respawn_delay + 0.1)
	assert_eq(first.health, first.max_health, "the dummy respawned")
	assert_true(arm.tutorial_cleared)
	assert_eq(arm.clear_seconds_left, -1.0)
	_kill(first)
	arm.advance(60.0)
	assert_eq(arm.arm_reason, HeraldArm.REASON_LEFT)


var _arm: HeraldArm
var _body: Node2D
var _dummies: Array[TrainingDummy] = []


func _rig() -> void:
	_body = Node2D.new()
	add_child_autofree(_body)
	var holder := Node2D.new()
	add_child_autofree(holder)
	var scene := preload("res://scenes/training_dummy.tscn")
	_dummies.clear()
	for _i in 3:
		var dummy := scene.instantiate() as TrainingDummy
		holder.add_child(dummy)
		_dummies.append(dummy)
	_arm = HeraldArm.new()
	add_child_autofree(_arm)
	_arm.bind(_body, holder)


func _kill(dummy: TrainingDummy) -> void:
	(dummy.get_node("Hurtbox") as Hurtbox).receive_hit(dummy.max_health, Vector2.ZERO, Vector2.ZERO)
