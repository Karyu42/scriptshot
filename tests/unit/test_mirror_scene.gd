extends GutTest
## The Mirror test enemy in the main scene, end to end.

const DT := 1.0 / 60.0

var main: Main
var player: Player
var bullets: BulletManager
var mirror: Mirror


func before_each() -> void:
	main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	add_child_autofree(main)
	for turret: Turret in main.get_node("Turrets").get_children():
		turret.emitter = null
	player = main.get_node("Player")
	bullets = main.get_node("BulletManager")
	mirror = main.get_node("Mirrors/Mirror1")
	RespawnPoints.reset()
	await wait_physics_frames(2)


func after_each() -> void:
	RespawnPoints.reset()
	Input.action_release("fire")


func test_the_mirror_is_in_the_main_scene_and_wired_to_the_player() -> void:
	assert_not_null(mirror)
	assert_eq(mirror.target, player)
	assert_true(mirror is TrainingDummy)
	assert_eq(mirror.reflector.reflects_owners, Layers.PLAYER)
	assert_gt(mirror.reflector.radius, mirror.body_radius, "the zone sits outside the body")


func test_the_arc_turns_to_face_the_player() -> void:
	player.global_position = mirror.global_position + Vector2(0, 300)
	await wait_physics_frames(90)
	var to_player := (player.global_position - mirror.global_position).normalized()
	assert_gt(mirror.reflector.facing().dot(to_player), 0.98)


func test_a_bullet_the_player_shoots_at_the_mirror_comes_back_and_hurts_the_player() -> void:
	player.global_position = mirror.global_position + Vector2(260, 0)
	player.aim_direction = Vector2.LEFT
	await wait_physics_frames(60)
	var r := ShotRequest.polar(player.global_position + Vector2(-20, 0), PI, 500.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 5.0
	var id := bullets.emitter.request_shot_id(r)
	await wait_physics_frames(36)
	assert_eq(mirror.health, mirror.max_health, "the mirror took no damage")
	assert_eq(bullets.pool.owner_layer[bullets.pool.slot_of(id)], Layers.ENEMY)
	await wait_physics_frames(60)
	assert_eq(mirror.health, mirror.max_health)
	assert_lt(player.health.hp, player.health.max_hp, "the player was hit by the reflected bullet")


func test_a_shot_from_behind_the_arc_hurts_the_mirror() -> void:
	# Freeze the arc facing away from the shooter.
	mirror.set_physics_process(false)
	mirror.reflector.global_rotation = 0.0
	mirror.reflector.arc_degrees = 60.0
	var from := mirror.global_position + Vector2(-250, 0)
	var r := ShotRequest.polar(from, 0.0, 500.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 5.0
	r.collide_world = false
	bullets.emitter.request_shot_id(r)
	await wait_physics_frames(30)
	assert_lt(mirror.health, mirror.max_health, "hit the back of the mirror")


func test_a_destroyed_mirror_stops_reflecting() -> void:
	mirror.health = 0.5
	var r := ShotRequest.polar(mirror.global_position, 0.0, 0.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 5.0
	r.collide_world = false
	bullets.emitter.request_shot_id(r)
	await wait_physics_frames(5)
	assert_lte(mirror.health, 0.0, "destroyed")
	assert_false(mirror.reflector.is_active())
