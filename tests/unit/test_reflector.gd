extends GutTest
## Reflector zones: owner/colour/velocity change, guard, arcs, modes, efficiency.

const DT := 1.0 / 60.0

var m: BulletManager


## A hurtbox that counts hits.
class Counter:
	extends Hurtbox
	var hits := 0
	var last_damage := 0.0

	func _ready() -> void:
		hit.connect(func(d: float, _p: Vector2, _v: Vector2) -> void:
			hits += 1
			last_damage = d)


func before_each() -> void:
	m = BulletManager.new()
	m.auto_step = false
	m.render_enabled = false
	add_child_autofree(m)


func _reflector(at: Vector2, radius: float = 40.0) -> Reflector:
	var r := Reflector.new()
	r.radius = radius
	add_child_autofree(r)
	r.global_position = at
	return r


func _counter(at: Vector2, layer: int, radius: float = 14.0) -> Counter:
	var c := Counter.new()
	c.layer = layer
	c.radius = radius
	add_child_autofree(c)
	c.global_position = at
	return c


## A bullet of `owner_layer` at `from` flying along `vel`.
func _bullet(from: Vector2, vel: Vector2, owner_layer: int = Layers.PLAYER, dmg: float = 1.0) -> int:
	var r := ShotRequest.new()
	r.position = from
	r.velocity = vel
	r.owner_layer = owner_layer
	r.hit_mask = Layers.hostile_to(owner_layer)
	r.color = Layers.bullet_color(owner_layer)
	r.damage = dmg
	r.lifetime = 10.0
	r.collide_world = false
	return m.emitter.request_shot_id(r)


func _slot(id: int) -> int:
	return m.pool.slot_of(id)


func _run(ticks: int) -> void:
	for i in ticks:
		m.step(DT)


func test_a_player_bullet_hitting_a_mirror_becomes_enemy_owned_and_recoloured() -> void:
	_reflector(Vector2(200, 0))
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(40)
	assert_true(m.emitter.is_bullet_alive(id))
	var s := _slot(id)
	assert_eq(m.pool.owner_layer[s], Layers.ENEMY)
	assert_eq(m.pool.hit_mask[s], Layers.PLAYER)
	assert_eq(m.pool.color[s], Layers.bullet_color(Layers.ENEMY))
	assert_lt(m.pool.vel[s].x, 0.0, "heading back")


func test_the_reflected_bullet_damages_the_player_and_never_the_mirror() -> void:
	var mirror_body := _counter(Vector2(200, 0), Layers.ENEMY, 22.0)
	var player_box := _counter(Vector2(0, 0), Layers.PLAYER, 14.0)
	_reflector(Vector2(200, 0), 40.0)
	var id := _bullet(Vector2(30, 0), Vector2(300, 0), Layers.PLAYER, 2.0)
	_run(120)
	assert_eq(mirror_body.hits, 0, "the mirror's own body is never hit by what it reflected")
	assert_eq(player_box.hits, 1, "it came back and hurt the player")
	assert_eq(player_box.last_damage, 1.0, "1 damage: the script's 2 is ignored (pillars 5.4)")
	assert_false(m.emitter.is_bullet_alive(id))


func test_reflected_damage_is_a_property_of_the_zone() -> void:
	var player_box := _counter(Vector2(0, 0), Layers.PLAYER, 14.0)
	var r := _reflector(Vector2(200, 0), 40.0)
	r.reflected_damage = 3.0
	_bullet(Vector2(30, 0), Vector2(300, 0), Layers.PLAYER, 2.0)
	_run(120)
	assert_eq(player_box.last_damage, 3.0)


func test_a_negative_reflected_damage_keeps_the_bullets_own() -> void:
	var player_box := _counter(Vector2(0, 0), Layers.PLAYER, 14.0)
	var r := _reflector(Vector2(200, 0), 40.0)
	r.reflected_damage = -1.0
	_bullet(Vector2(30, 0), Vector2(300, 0), Layers.PLAYER, 2.0)
	_run(120)
	assert_eq(player_box.last_damage, 2.0)


func _scripted_bullet_through_zone(keep: bool) -> int:
	var zone := _reflector(Vector2(200, 0))
	zone.keep_script = keep
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	m.pool.param_a[_slot(id)] = 5.0
	m.pool.user[_slot(id)] = "u"
	_run(40)
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY, "reflected")
	return _slot(id)


func test_a_zone_reflection_unscripts_the_bullet() -> void:
	var s := _scripted_bullet_through_zone(false)
	assert_eq(m.pool.param_a[s], 0.0)
	assert_true(m.pool.user[s] == null, "user cleared")


func test_keep_script_on_the_zone_keeps_the_scripts_data() -> void:
	var s := _scripted_bullet_through_zone(true)
	assert_eq(m.pool.param_a[s], 5.0)
	var kept: bool = str(m.pool.user[s]) == "u"
	assert_true(kept, "user kept")


func test_a_player_bullet_that_stays_player_owned_would_have_hit_the_mirror() -> void:
	# Control: without the reflector the same shot damages the mirror's body.
	var mirror_body := _counter(Vector2(200, 0), Layers.ENEMY, 22.0)
	_bullet(Vector2(30, 0), Vector2(300, 0))
	_run(60)
	assert_eq(mirror_body.hits, 1)


func test_non_matching_owners_pass_through() -> void:
	_reflector(Vector2(200, 0))
	var id := _bullet(Vector2(0, 0), Vector2(300, 0), Layers.ENEMY)
	_run(60)
	var s := _slot(id)
	assert_eq(m.pool.owner_layer[s], Layers.ENEMY)
	assert_gt(m.pool.pos[s].x, 260.0, "flew straight through the zone")
	assert_eq(m.pool.vel[s], Vector2(300, 0))
	assert_eq(m.pool.color[s], Layers.bullet_color(Layers.ENEMY))
	assert_eq(m.last_reflect_count, 0)


func test_reflects_owners_can_be_widened_or_switched() -> void:
	var r := _reflector(Vector2(200, 0))
	r.reflects_owners = Layers.PLAYER | Layers.ENEMY
	var enemy_bullet := _bullet(Vector2(0, 0), Vector2(300, 0), Layers.ENEMY)
	_run(40)
	assert_eq(m.pool.owner_layer[_slot(enemy_bullet)], Layers.PLAYER, "enemy bullets become player-owned")
	assert_eq(m.pool.color[_slot(enemy_bullet)], Layers.bullet_color(Layers.PLAYER))


func test_unowned_bullets_are_ignored() -> void:
	_reflector(Vector2(200, 0))
	var slot := m.pool.spawn_simple(Vector2(0, 0), Vector2(300, 0), 5.0, 4.0, Color.WHITE, Layers.PLAYER)
	var id := m.pool.id_of(slot)
	_run(60)
	assert_gt(m.pool.pos[_slot(id)].x, 260.0)


# --- modes ----------------------------------------------------------------------------

func test_reverse_mode_sends_the_bullet_straight_back() -> void:
	var r := _reflector(Vector2(200, 0))
	r.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(0, 40), Vector2(300, -20))
	_run(40)
	var v := m.pool.vel[_slot(id)]
	assert_almost_eq(v.x, -300.0, 0.01)
	assert_almost_eq(v.y, 20.0, 0.01)


func test_mirror_mode_reflects_across_the_surface_normal() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.mode = Reflector.Mode.MIRROR
	# Heading right along y = 28: it touches the circle below its centre line, where
	# the normal points down-left, so it bounces down-left, not straight back.
	var id := _bullet(Vector2(100, 28), Vector2(300, 0))
	_run(30)
	var v := m.pool.vel[_slot(id)]
	assert_almost_eq(v.length(), 300.0, 0.01, "speed preserved")
	assert_lt(v.x, 0.0)
	assert_gt(v.y, 0.0, "deflected sideways (down-left)")
	assert_ne(snappedf(v.y, 0.1), 0.0)


func test_mirror_mode_head_on_is_a_straight_bounce() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.mode = Reflector.Mode.MIRROR
	var id := _bullet(Vector2(100, 0), Vector2(300, 0))
	_run(30)
	var v := m.pool.vel[_slot(id)]
	assert_almost_eq(v.x, -300.0, 0.5)
	assert_almost_eq(v.y, 0.0, 0.5)


func test_aim_at_target_mode_homes_on_the_target() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.mode = Reflector.Mode.AIM_AT_TARGET
	var target := Node2D.new()
	add_child_autofree(target)
	target.global_position = Vector2(100, 400)
	r.target = target
	var id := _bullet(Vector2(100, 0), Vector2(300, 0))
	_run(30)
	var v := m.pool.vel[_slot(id)]
	assert_almost_eq(v.length(), 300.0, 0.5)
	assert_gt(v.y, 150.0, "heads down toward the target")
	assert_lt(v.x, 0.0)
	var to_target := (target.global_position - m.pool.pos[_slot(id)]).normalized()
	assert_gt(v.normalized().dot(to_target), 0.95)


func test_aim_at_target_without_a_target_falls_back_to_reverse() -> void:
	var r := _reflector(Vector2(200, 0))
	r.mode = Reflector.Mode.AIM_AT_TARGET
	var id := _bullet(Vector2(100, 0), Vector2(300, 0))
	_run(30)
	assert_almost_eq(m.pool.vel[_slot(id)].x, -300.0, 0.5)


func test_speed_multiplier_scales_the_reflected_speed() -> void:
	var r := _reflector(Vector2(200, 0))
	r.mode = Reflector.Mode.REVERSE
	r.speed_multiplier = 1.5
	var id := _bullet(Vector2(100, 0), Vector2(300, 0))
	_run(30)
	assert_almost_eq(m.pool.vel[_slot(id)].x, -450.0, 0.5)


func test_speed_multiplier_is_clamped_and_nan_safe() -> void:
	var r := _reflector(Vector2(200, 0))
	r.mode = Reflector.Mode.REVERSE
	r.speed_multiplier = NAN
	var id := _bullet(Vector2(100, 0), Vector2(300, 0))
	_run(30)
	assert_almost_eq(m.pool.vel[_slot(id)].x, -300.0, 0.5, "NaN means 1")
	r.speed_multiplier = 1.0e9
	var id2 := _bullet(Vector2(100, 0), Vector2(100, 0))
	_run(60)
	assert_almost_eq(m.pool.vel[_slot(id2)].length(), 100.0 * Reflector.MAX_SPEED_MULTIPLIER, 1.0)
	r.speed_multiplier = -3.0
	var id3 := _bullet(Vector2(100, 100), Vector2(100, 0))
	r.global_position = Vector2(200, 100)
	_run(60)
	assert_eq(m.pool.vel[_slot(id3)].length(), 0.0, "never negative")


func test_the_bullets_heading_follows_its_new_velocity() -> void:
	var r := _reflector(Vector2(200, 0))
	r.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(100, 0), Vector2(300, 0))
	_run(30)
	assert_almost_eq(m.pool.rot[_slot(id)].x, -1.0, 0.001)


# --- guard ------------------------------------------------------------------------------

func test_a_bullet_is_reflected_only_once_by_default() -> void:
	var a := _reflector(Vector2(200, 0))
	var b := _reflector(Vector2(-100, 0))
	b.reflects_owners = Layers.PLAYER | Layers.ENEMY
	a.reflects_owners = Layers.PLAYER | Layers.ENEMY
	var id := _bullet(Vector2(50, 0), Vector2(300, 0))
	_run(200)
	var s := _slot(id)
	assert_eq(m.pool.reflect_count[s], 1, "no ping-pong between two mirrors")
	assert_eq(m.pool.owner_layer[s], Layers.ENEMY)
	assert_lt(m.pool.pos[s].x, -150.0, "after bouncing off a it flew through b")


func test_a_script_reflection_counts_toward_the_guard() -> void:
	_reflector(Vector2(200, 0))
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	assert_true(m.emitter.reflect_bullet(id, Layers.ENEMY))
	assert_false(m.emitter.reflect_bullet(id, Layers.PLAYER), "the script's own second reflection is refused too")
	_run(60)
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY, "enemy-owned, so the player-only mirror ignored it")
	assert_gt(m.pool.pos[_slot(id)].x, 260.0)


func test_an_unlimited_zone_still_cannot_loop_in_place() -> void:
	m.pool.max_reflections = 0  # scripts too: the explicit global switch
	var r := _reflector(Vector2(200, 0))
	r.max_reflections = -1
	r.reflects_owners = Layers.PLAYER | Layers.ENEMY
	r.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(40)
	assert_eq(m.pool.reflect_count[_slot(id)], 1, "leaving the zone, it is not reflected every tick")
	# A script sends it back at the mirror: unlimited mode reflects it again.
	m.pool.vel[_slot(id)] = Vector2(300, 0)
	m.emitter.reflect_bullet(id, Layers.PLAYER)
	_run(60)
	assert_gte(m.pool.reflect_count[_slot(id)], 3)


func test_max_reflections_two_allows_a_second_bounce() -> void:
	var r := _reflector(Vector2(200, 0))
	r.max_reflections = 2
	r.reflects_owners = Layers.PLAYER | Layers.ENEMY
	r.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(40)
	m.pool.vel[_slot(id)] = Vector2(300, 0)
	_run(40)
	assert_eq(m.pool.reflect_count[_slot(id)], 2)
	m.pool.vel[_slot(id)] = Vector2(300, 0)
	_run(40)
	assert_eq(m.pool.reflect_count[_slot(id)], 2, "capped")


# --- geometry -----------------------------------------------------------------------------

func test_bullets_leaving_or_at_rest_pass() -> void:
	_reflector(Vector2(0, 0), 40.0)
	var leaving := _bullet(Vector2(10, 0), Vector2(300, 0))
	var still := _bullet(Vector2(0, 10), Vector2.ZERO)
	_run(20)
	assert_eq(m.pool.owner_layer[_slot(leaving)], Layers.PLAYER)
	assert_eq(m.pool.owner_layer[_slot(still)], Layers.PLAYER)


func test_an_arc_reflects_in_front_and_lets_the_back_through() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.arc_degrees = 90.0
	r.global_rotation = PI # facing left, toward the shooter
	var front := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(40)
	assert_eq(m.pool.owner_layer[_slot(front)], Layers.ENEMY, "hit the front of the arc")
	m.clear_bullets()
	var back := _bullet(Vector2(400, 0), Vector2(-300, 0))
	_run(70)
	assert_eq(m.pool.owner_layer[_slot(back)], Layers.PLAYER, "from behind it passes through")
	assert_lt(m.pool.pos[_slot(back)].x, 150.0)


func test_arc_edges_use_the_impact_point() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.arc_degrees = 60.0
	r.global_rotation = PI
	var side := _bullet(Vector2(0, 38), Vector2(300, 0))
	_run(40)
	assert_eq(m.pool.owner_layer[_slot(side)], Layers.PLAYER, "grazed the circle outside the 60 degree arc")


func test_a_full_circle_reflects_from_every_side() -> void:
	_reflector(Vector2.ZERO, 40.0)
	var ids: Array[int] = []
	for dir: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
		ids.append(_bullet(dir * -200.0, dir * 300.0))
	_run(45)
	for id: int in ids:
		assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)


func test_fast_bullets_cannot_tunnel_through_the_zone() -> void:
	_reflector(Vector2(200, 0), 20.0)
	var id := _bullet(Vector2(0, 0), Vector2(12000, 0))
	_run(3)
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)
	assert_lt(m.pool.vel[_slot(id)].x, 0.0)


func test_the_bullet_is_placed_at_the_zone_edge_not_inside_it() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(0, 0), Vector2(600, 0))
	_run(30)
	var s := _slot(id)
	assert_lt(m.pool.pos[s].x, 200.0 - 40.0 + 1.0, "never inside the zone after reflecting")


# --- consistency with the multi-hit sweep and teleport() ---------------------------

func test_a_reflected_bullet_flies_on_from_the_edge_without_a_phantom_sweep() -> void:
	var r := _reflector(Vector2(200, 0), 40.0)
	r.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(100, 0), Vector2(600, 0))
	var reflected := false
	for t in 20:
		m.step(DT)
		if m.last_reflect_count > 0:
			reflected = true
			break
	assert_true(reflected)
	var s := _slot(id)
	# The tick's leg before the mirror ends at the edge (156 = 200 - 40 + 4, the
	# bullet's radius counts); prev_pos is that impact point, not where the tick
	# began (150), so the renderer draws only the new leg, with no streak across
	# the mirror. pos is the end of the rest of the tick along the new heading.
	assert_almost_eq(m.pool.prev_pos[s].x, 156.0, 0.01)
	assert_almost_eq(m.pool.pos[s].x, 152.0, 0.01, "0.4 of a 10 px tick, flying back")
	assert_lt(m.pool.pos[s].x, m.pool.prev_pos[s].x)


func test_a_reflected_bullet_does_not_sweep_into_a_hurtbox_past_the_impact() -> void:
	# A player-side hurtbox lies on the old path *past* the reflection point; the
	# reflected (enemy-owned) bullet must not be swept through it.
	var past := _counter(Vector2(236, 0), Layers.PLAYER, 3.0)
	var r := _reflector(Vector2(250, 0), 40.0)
	r.mode = Reflector.Mode.REVERSE
	_bullet(Vector2(150, 0), Vector2(900, 0))
	_run(3)
	assert_eq(past.hits, 0, "the part of the old path past the impact is not swept")


func test_a_zone_that_declines_a_bullet_does_not_hide_the_zone_behind_it() -> void:
	# The nearer zone's arc faces away, so it declines; the farther one is a full circle.
	var near_zone := _reflector(Vector2(150, 0), 30.0)
	near_zone.arc_degrees = 40.0
	near_zone.global_rotation = 0.0 # facing away from the shooter
	var far_zone := _reflector(Vector2(300, 0), 30.0)
	var id := _bullet(Vector2(0, 0), Vector2(600, 0))
	_run(40)
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY, "reflected by the second zone")
	assert_eq(near_zone.reflected_total, 0)
	assert_eq(far_zone.reflected_total, 1)


func test_overlapping_zones_reflect_a_bullet_once_per_tick_even_when_unlimited() -> void:
	var a := _reflector(Vector2(200, 0), 40.0)
	var b := _reflector(Vector2(200, 0), 40.0)
	a.max_reflections = -1
	b.max_reflections = -1
	var id := _bullet(Vector2(100, 0), Vector2(600, 0))
	for t in 20:
		m.step(DT)
		if m.last_reflect_count > 0:
			break
	assert_eq(m.pool.reflect_count[_slot(id)], 1, "the second zone's hit was stale after the first reflected it")
	assert_eq(a.reflected_total + b.reflected_total, 1)


func test_a_piercing_bullet_is_reflected_and_keeps_its_remaining_pierce() -> void:
	_reflector(Vector2(200, 0), 40.0)
	var r := ShotRequest.new()
	r.position = Vector2(100, 0)
	r.velocity = Vector2(600, 0)
	r.pierce = 3
	r.lifetime = 10.0
	r.collide_world = false
	var id := m.emitter.request_shot_id(r)
	_run(20)
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)
	assert_eq(m.pool.pierce[_slot(id)], 3)


func test_a_bullet_that_left_the_world_bounds_is_not_reflected() -> void:
	var edge := m.world_bounds.end.x
	_reflector(Vector2(edge + 25.0, 0.0), 40.0)
	var id := _bullet(Vector2(edge - 12.0, 0), Vector2(1200, 0))
	m.step(DT)
	assert_false(m.emitter.is_bullet_alive(id), "despawned at the bounds, dead bullets are not reflected")
	assert_eq(m.last_reflect_count, 0)


# --- activation ---------------------------------------------------------------------------

func test_a_disabled_or_hidden_reflector_does_nothing() -> void:
	var r := _reflector(Vector2(200, 0))
	r.enabled = false
	var a := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(60)
	assert_eq(m.pool.owner_layer[_slot(a)], Layers.PLAYER)
	m.clear_bullets()
	r.enabled = true
	r.hide()
	var b := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(60)
	assert_eq(m.pool.owner_layer[_slot(b)], Layers.PLAYER)


func test_a_reflector_that_leaves_the_tree_is_forgotten() -> void:
	var before := Reflector.registry.size()
	var r := Reflector.new()
	add_child(r)
	assert_eq(Reflector.registry.size(), before + 1)
	r.free()
	assert_eq(Reflector.registry.size(), before)


func test_signal_and_counters() -> void:
	var r := _reflector(Vector2(200, 0))
	watch_signals(r)
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(40)
	assert_signal_emit_count(r, "bullet_reflected", 1)
	assert_signal_emitted_with_parameters(r, "bullet_reflected", [id, Layers.ENEMY])
	assert_eq(r.reflected_total, 1)


func test_last_reflect_count_reports_the_step() -> void:
	_reflector(Vector2(200, 0))
	_bullet(Vector2(158, 0), Vector2(300, 0))
	_bullet(Vector2(158, 5), Vector2(300, 0))
	m.step(DT)
	assert_eq(m.last_reflect_count, 2)
	m.step(DT)
	assert_eq(m.last_reflect_count, 0)


func test_many_reflectors_and_many_bullets_in_one_pass() -> void:
	for k in 8:
		_reflector(Vector2(200 + k * 150, 0), 30.0)
	var ids: Array[int] = []
	for k in 8:
		ids.append(_bullet(Vector2(200 + k * 150 - 100, 0), Vector2(300, 0)))
	_run(60)
	var reflected := 0
	for id: int in ids:
		if m.pool.owner_layer[_slot(id)] == Layers.ENEMY:
			reflected += 1
	assert_eq(reflected, 8)


func test_no_reflectors_costs_nothing_in_the_step() -> void:
	assert_eq(Reflector.registry.size(), 0)
	_bullet(Vector2.ZERO, Vector2(100, 0))
	m.step(DT)
	assert_eq(m.last_reflect_count, 0)


# --- multi-hit pierce + reflect (#2 semantics) -----------------------------------

func _piercing_player_bullet(from: Vector2, speed: float, pierce: int) -> int:
	var r := ShotRequest.new()
	r.position = from
	r.velocity = Vector2(speed, 0)
	r.owner_layer = Layers.PLAYER
	r.hit_mask = Layers.ENEMY
	r.pierce = pierce
	r.lifetime = 10.0
	r.collide_world = false
	return m.emitter.request_shot_id(r)


func test_a_piercing_bullet_hits_before_the_zone_and_is_then_reflected() -> void:
	var before := _counter(Vector2(50, 0), Layers.ENEMY, 10.0)
	var after := _counter(Vector2(300, 0), Layers.ENEMY, 10.0)
	var zone := _reflector(Vector2(150, 0), 30.0)
	zone.mode = Reflector.Mode.REVERSE
	var id := _piercing_player_bullet(Vector2(0, 0), 600.0, 2)
	_run(60)
	assert_eq(before.hits, 1, "pierced the target in front of the mirror")
	assert_eq(after.hits, 0, "reflected before it could reach the one behind")
	assert_true(m.emitter.is_bullet_alive(id))
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)
	assert_lt(m.pool.vel[_slot(id)].x, 0.0)


func test_a_reflected_piercing_bullet_does_not_hit_the_target_it_pierced_again() -> void:
	var before := _counter(Vector2(50, 0), Layers.ENEMY, 10.0)
	var zone := _reflector(Vector2(150, 0), 30.0)
	zone.mode = Reflector.Mode.REVERSE
	_piercing_player_bullet(Vector2(0, 0), 600.0, 2)
	_run(120)
	assert_eq(before.hits, 1, "now enemy-owned: it can never hit the enemy side again")


func test_a_target_in_front_of_a_mirror_is_hit_first_even_within_one_tick() -> void:
	# QA's repro: a non-piercing 30000 px/s bullet crosses an enemy 100 px in front
	# of the mirror and the mirror itself in one 500 px tick. Time order: the enemy
	# is hit (and consumes the bullet) before the mirror is reached.
	var before := _counter(Vector2(50, 0), Layers.ENEMY, 10.0)
	var zone := _reflector(Vector2(150, 0), 30.0)
	zone.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(0, 0), Vector2(30000, 0))
	_run(1)
	assert_eq(before.hits, 1)
	assert_false(m.emitter.is_bullet_alive(id), "consumed by the target")
	assert_eq(zone.reflected_total, 0)
	assert_eq(m.last_reflect_count, 0)


func test_a_piercing_bullet_hits_the_target_then_is_reflected_in_the_same_tick() -> void:
	var before := _counter(Vector2(50, 0), Layers.ENEMY, 10.0)
	var zone := _reflector(Vector2(150, 0), 30.0)
	zone.mode = Reflector.Mode.REVERSE
	var id := _piercing_player_bullet(Vector2(0, 0), 30000.0, 2)
	_run(1)
	var s := _slot(id)
	assert_eq(before.hits, 1, "the nearer hit is no longer lost")
	assert_eq(m.pool.owner_layer[s], Layers.ENEMY, "and the mirror still turned it around")
	assert_eq(m.pool.pierce[s], 1, "one pierce spent on the target")
	assert_lt(m.pool.vel[s].x, 0.0)


func test_a_mirror_in_front_of_a_target_still_protects_it() -> void:
	var behind := _counter(Vector2(300, 0), Layers.ENEMY, 10.0)
	var zone := _reflector(Vector2(150, 0), 30.0)
	zone.mode = Reflector.Mode.REVERSE
	var id := _piercing_player_bullet(Vector2(0, 0), 30000.0, 2)
	_run(1)
	assert_eq(behind.hits, 0, "reflected before it could reach the target behind")
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)


func test_a_bullet_slower_than_200_px_per_tick_also_hits_a_target_close_in_front_of_the_mirror() -> void:
	# The old condition was "faster than ~200 px per tick"; the real one was the
	# distance between target and zone. 5000 px/s = 83 px per tick, target 20 px
	# in front of the zone edge.
	var before := _counter(Vector2(110, 0), Layers.ENEMY, 8.0)
	var zone := _reflector(Vector2(170, 0), 30.0)  # edge (plus bullet radius) at x = 144
	zone.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(80, 0), Vector2(5000, 0))
	_run(2)
	assert_eq(before.hits, 1)
	assert_false(m.emitter.is_bullet_alive(id))


func test_a_wall_behind_the_mirror_no_longer_kills_a_bullet_the_mirror_turned_around() -> void:
	m.add_wall(Rect2(300, -50, 20, 100))  # 70 px behind the zone's far edge
	var zone := _reflector(Vector2(200, 0), 40.0)
	zone.mode = Reflector.Mode.REVERSE
	var r := ShotRequest.polar(Vector2(0, 0), 0.0, 30000.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 10.0
	var id := m.emitter.request_shot_id(r)  # collides with walls
	_run(1)
	assert_true(m.emitter.is_bullet_alive(id), "the wall was behind the mirror: the bullet never reached it")
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)
	assert_lt(m.pool.vel[_slot(id)].x, 0.0)
	assert_lt(m.pool.pos[_slot(id)].x, 160.0, "flying back from the mirror's edge")


func test_a_wall_in_front_of_the_mirror_still_stops_the_bullet() -> void:
	m.add_wall(Rect2(100, -50, 20, 100))
	var zone := _reflector(Vector2(300, 0), 40.0)
	zone.mode = Reflector.Mode.REVERSE
	var r := ShotRequest.polar(Vector2(0, 0), 0.0, 30000.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 10.0
	var id := m.emitter.request_shot_id(r)
	_run(1)
	assert_false(m.emitter.is_bullet_alive(id))
	assert_eq(zone.reflected_total, 0)


func test_a_reflected_bullet_that_later_hits_a_wall_still_despawns_there() -> void:
	# The "reflected this tick" bookkeeping must not leak into later ticks.
	m.add_wall(Rect2(-80, -50, 20, 100))
	var zone := _reflector(Vector2(200, 0), 40.0)
	zone.mode = Reflector.Mode.REVERSE
	var r := ShotRequest.polar(Vector2(100, 0), 0.0, 600.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 10.0
	var id := m.emitter.request_shot_id(r)
	_run(10)
	assert_true(m.emitter.is_bullet_alive(id))
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)
	_run(60)
	assert_false(m.emitter.is_bullet_alive(id), "flew back across the arena into the wall")


# --- the rest of the tick after a reflection -----------------------------------------

func test_a_reflected_bullet_flies_the_remaining_fraction_of_the_tick_on_its_new_heading() -> void:
	var zone := _reflector(Vector2(200, 0), 40.0)
	zone.mode = Reflector.Mode.REVERSE
	zone.speed_multiplier = 2.0
	var id := _bullet(Vector2(100, 0), Vector2(6000, 0))  # 100 px per tick
	_run(1)
	var s := _slot(id)
	# Impact at x = 156 after 0.56 of the tick; the remaining 0.44 tick at 12000 px/s
	# going back is 88 px.
	assert_almost_eq(m.pool.prev_pos[s].x, 156.0, 0.01)
	assert_almost_eq(m.pool.pos[s].x, 156.0 - 88.0, 0.01)
	assert_almost_eq(m.pool.vel[s].x, -12000.0, 0.01)


func test_a_reflected_bullet_can_hit_its_new_targets_in_the_same_tick() -> void:
	# The player's hurtbox is 30 px behind the mirror's edge, on the way back.
	var player_box := _counter(Vector2(130, 0), Layers.PLAYER, 6.0)
	var zone := _reflector(Vector2(200, 0), 40.0)
	zone.mode = Reflector.Mode.REVERSE
	var id := _bullet(Vector2(100, 0), Vector2(30000, 0))
	_run(1)
	assert_eq(player_box.hits, 1, "hit on the return leg without waiting a tick")
	assert_false(m.emitter.is_bullet_alive(id))


func test_the_return_leg_is_clipped_at_a_wall() -> void:
	m.add_wall(Rect2(100, -50, 20, 100))  # between the zone and the start, on the way back
	var zone := _reflector(Vector2(300, 0), 40.0)
	zone.mode = Reflector.Mode.REVERSE
	var r := ShotRequest.polar(Vector2(130, 0), 0.0, 30000.0)
	r.hit_mask = Layers.ENEMY
	r.lifetime = 10.0
	var id := m.emitter.request_shot_id(r)
	_run(1)
	assert_false(m.emitter.is_bullet_alive(id), "turned around, then stopped by the wall on the way back")
	assert_eq(zone.reflected_total, 1)


func test_the_return_leg_never_reflects_a_second_time_in_the_same_tick() -> void:
	var a := _reflector(Vector2(300, 0), 40.0)
	var b := _reflector(Vector2(60, 0), 20.0)
	for zone: Reflector in [a, b]:
		zone.max_reflections = -1
		zone.mode = Reflector.Mode.REVERSE
		zone.reflects_owners = Layers.PLAYER | Layers.ENEMY
	var id := _bullet(Vector2(150, 0), Vector2(30000, 0))
	_run(1)
	var s := _slot(id)
	assert_eq(m.pool.reflect_count[s], 1, "b lies on the way back but is not consulted again this tick")
	assert_eq(b.reflected_total, 0)
	assert_lt(m.pool.pos[s].x, 40.0, "it flew right through b's zone")


# --- the multi-zone list on one fast path ----------------------------------------------

func test_a_fast_bullet_is_reflected_by_the_first_accepting_zone_and_the_stale_hits_are_dropped() -> void:
	# Three full-circle zones in a row on a 500 px/tick path. Without the "drop the
	# rest of the list once it was reflected" rule, the bullet would be reflected
	# again by the second and third zone from impact points of the *old* path (the
	# pool's own guard is lifted, so only the drop rule stops it).
	m.pool.max_reflections = 0
	var zones: Array[Reflector] = []
	for x: float in [200.0, 300.0, 400.0]:
		var z := _reflector(Vector2(x, 0), 30.0)
		z.mode = Reflector.Mode.REVERSE
		z.reflects_owners = Layers.PLAYER | Layers.ENEMY
		zones.append(z)
	var id := _bullet(Vector2(0, 0), Vector2(30000, 0))
	_run(1)
	var s := _slot(id)
	assert_eq(zones[0].reflected_total, 1)
	assert_eq(zones[1].reflected_total, 0, "stale: computed for the old path")
	assert_eq(zones[2].reflected_total, 0)
	assert_eq(m.pool.reflect_count[s], 1)
	assert_eq(m.pool.owner_layer[s], Layers.ENEMY)
	assert_eq(m.last_reflect_count, 1)
	# Impact at 200 - 30 - 4 = 166 after 0.332 of the tick; 0.668 * 500 = 334 px back.
	assert_almost_eq(m.pool.prev_pos[s].x, 166.0, 0.01)
	assert_almost_eq(m.pool.pos[s].x, 166.0 - 334.0, 0.1)


func test_a_declining_zone_does_not_hide_the_accepting_zone_behind_it_on_a_fast_path() -> void:
	# The first zone's arc faces away, so it declines; the second reflects. Both lie
	# on one 500 px tick, so both must be on the bullet's hit list (this fails if
	# HurtboxGrid.MAX_ZONE_HITS drops to 1).
	var decliner := _reflector(Vector2(150, 0), 30.0)
	decliner.arc_degrees = 40.0
	decliner.global_rotation = 0.0  # facing away from the shooter
	var accepter := _reflector(Vector2(300, 0), 30.0)
	var id := _bullet(Vector2(0, 0), Vector2(30000, 0))
	_run(1)
	assert_eq(decliner.reflected_total, 0)
	assert_eq(accepter.reflected_total, 1)
	assert_eq(m.pool.owner_layer[_slot(id)], Layers.ENEMY)


func test_at_most_max_zone_hits_zones_are_listed_per_bullet_and_tick() -> void:
	# Documented limit: MAX_ZONE_HITS (4) zones per bullet and tick. With four
	# declining zones in front, the accepting fifth is not on the list that tick.
	var x := 100.0
	for k in HurtboxGrid.MAX_ZONE_HITS:
		var z := _reflector(Vector2(x, 0), 10.0)
		z.arc_degrees = 40.0
		z.global_rotation = 0.0
		x += 40.0
	var accepter := _reflector(Vector2(x, 0), 10.0)
	_bullet(Vector2(0, 0), Vector2(30000, 0))
	_run(1)
	assert_eq(accepter.reflected_total, 0)


# --- the reflection guard: zone limit vs pool cap -----------------------------------------

func test_a_zone_left_at_zero_follows_the_pool_wide_cap() -> void:
	var r := _reflector(Vector2(200, 0))
	r.mode = Reflector.Mode.REVERSE
	r.reflects_owners = Layers.PLAYER | Layers.ENEMY
	assert_eq(r.max_reflections, 0, "default: follow the pool")
	assert_eq(r.effective_limit(m.pool), 1)
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	_run(40)
	assert_eq(m.pool.reflect_count[_slot(id)], 1)
	# Send it back at the mirror: the zone follows the cap of 1 and declines.
	m.pool.teleport(_slot(id), Vector2(0, 0))
	m.pool.vel[_slot(id)] = Vector2(300, 0)
	_run(40)
	assert_eq(m.pool.reflect_count[_slot(id)], 1, "the zone did not bypass the pool's cap of 1")
	assert_gt(m.pool.pos[_slot(id)].x, 200.0, "it flew on through the mirror")
	# Raise the pool-wide cap and try once more.
	m.pool.max_reflections = 2
	assert_eq(r.effective_limit(m.pool), 2)
	m.pool.teleport(_slot(id), Vector2(0, 0))
	m.pool.vel[_slot(id)] = Vector2(300, 0)
	_run(40)
	assert_eq(m.pool.reflect_count[_slot(id)], 2)


func test_a_positive_zone_limit_is_explicit_and_may_exceed_the_pool_cap() -> void:
	var r := _reflector(Vector2(200, 0))
	r.max_reflections = 3
	assert_eq(r.effective_limit(m.pool), 3)
	assert_eq(m.pool.max_reflections, 1)


func test_a_negative_zone_limit_means_unlimited_for_that_zone_only() -> void:
	var r := _reflector(Vector2(200, 0))
	r.max_reflections = -1
	assert_eq(r.effective_limit(m.pool), 0, "0 = unlimited in BulletPool.reflect() terms")
	assert_eq(m.pool.max_reflections, 1, "scripts are still held to the pool's cap")
	var id := _bullet(Vector2(0, 0), Vector2(300, 0))
	assert_true(m.emitter.reflect_bullet(id, Layers.ENEMY))
	assert_false(m.emitter.reflect_bullet(id, Layers.PLAYER))


func test_pool_cap_zero_is_the_explicit_global_unlimited_switch() -> void:
	m.pool.max_reflections = 0
	var r := _reflector(Vector2(200, 0))
	assert_eq(r.effective_limit(m.pool), 0)
