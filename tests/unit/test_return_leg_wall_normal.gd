extends GutTest
## wall_normal_of() on the return leg of a reflected bullet (QA's reading of #10):
## a bullet that a hurtbox consumed on the way back never reached the wall behind it,
## so its hooks must not be told about that wall. Only a bullet that actually ends at
## the wall reports the normal.

var m: BulletManager
var rec: Rec


class Rec:
	extends BulletBehavior
	var mgr: BulletManager
	var reason := -99
	var despawn_normal := Vector2(9, 9)
	var hit_normal := Vector2(9, 9)

	func on_hit(_pool: BulletPool, index: int, _hurtbox: Hurtbox) -> void:
		hit_normal = mgr.wall_normal_of(index)

	func on_despawn(_pool: BulletPool, index: int, reason_: int) -> void:
		reason = reason_
		despawn_normal = mgr.wall_normal_of(index)


func before_each() -> void:
	m = BulletManager.new()
	m.auto_step = false
	m.render_enabled = false
	add_child_autofree(m)


## A bullet at x=130 flying +x at 4000 px/s into a REVERSE mirror at (200, 0), a wall
## on its way back (x 60..80), and (optionally) a player hurtbox between them.
func _setup(hurtbox_x: float) -> int:
	m.add_wall(Rect2(60, -50, 20, 100))
	var z := Reflector.new()
	z.radius = 40.0
	z.mode = Reflector.Mode.REVERSE
	z.keep_script = true
	add_child_autofree(z)
	z.global_position = Vector2(200, 0)
	if not is_nan(hurtbox_x):
		var hb := Hurtbox.new()
		hb.layer = Layers.PLAYER
		hb.radius = 8.0
		add_child_autofree(hb)
		hb.global_position = Vector2(hurtbox_x, 0)
	rec = Rec.new()
	rec.mgr = m
	var r := ShotRequest.new()
	r.position = Vector2(130, 0)
	r.velocity = Vector2(4000, 0)
	r.owner_layer = Layers.PLAYER
	r.hit_mask = Layers.ENEMY
	r.lifetime = 10.0
	r.collide_world = true
	r.behavior_id = m.register_behavior(rec)
	return m.emitter.request_shot_id(r)


func test_a_return_leg_bullet_consumed_by_a_hurtbox_before_the_wall_reports_no_wall_normal() -> void:
	_setup(120.0)
	m.step(0.125)
	assert_eq(rec.reason, BulletPool.DespawnReason.HIT, "the hurtbox on the way back got it first")
	assert_eq(rec.hit_normal, Vector2.ZERO, "on_hit: it has not reached the wall")
	assert_eq(rec.despawn_normal, Vector2.ZERO, "on_despawn(HIT): and still has not")


func test_a_return_leg_bullet_that_reaches_the_wall_still_reports_it() -> void:
	_setup(NAN)
	m.step(0.125)
	assert_eq(rec.reason, BulletPool.DespawnReason.WALL)
	assert_eq(rec.despawn_normal, Vector2.RIGHT)


func test_a_hurtbox_behind_the_wall_does_not_hide_the_wall() -> void:
	_setup(20.0)  # beyond the wall (x < 60): the leg is clipped at the wall first
	m.step(0.125)
	assert_eq(rec.reason, BulletPool.DespawnReason.WALL)
	assert_eq(rec.despawn_normal, Vector2.RIGHT)


func test_a_piercing_return_leg_bullet_passes_the_hurtbox_and_still_dies_at_the_wall() -> void:
	_setup(120.0)
	m.pool.pierce[0] = 1
	m.step(0.125)
	assert_eq(rec.reason, BulletPool.DespawnReason.WALL)
	assert_eq(rec.despawn_normal, Vector2.RIGHT)
	assert_eq(rec.hit_normal, Vector2.RIGHT, "it was on its way to the wall when it passed the target")
