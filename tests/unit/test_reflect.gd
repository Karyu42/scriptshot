extends GutTest
## Reflecting bullets: ownership, hit mask and colour swap, through the pool,
## the manager and the ShotEmitter interface.

const DT := 1.0 / 60.0

var pool: BulletPool


func before_each() -> void:
	pool = BulletPool.new(64)


func _enemy_bullet() -> int:
	var r := ShotRequest.polar(Vector2(100, 100), 0.0, 200.0)
	r.owner_layer = Layers.ENEMY
	r.hit_mask = Layers.PLAYER
	r.color = Layers.bullet_color(Layers.ENEMY)
	return pool.spawn(r)


func test_spawn_strips_the_owners_own_layer_from_the_hit_mask() -> void:
	var r := ShotRequest.new()
	r.hit_mask = Layers.PLAYER | Layers.ENEMY
	r.owner_layer = Layers.PLAYER
	var i := pool.spawn(r)
	assert_eq(pool.hit_mask[i], Layers.ENEMY)
	r.owner_layer = Layers.ENEMY
	i = pool.spawn(r)
	assert_eq(pool.hit_mask[i], Layers.PLAYER)
	r.owner_layer = 0
	i = pool.spawn(r)
	assert_eq(pool.hit_mask[i], Layers.PLAYER | Layers.ENEMY, "unowned bullets are not stripped")


func test_requests_default_to_player_owned_and_reset_restores_it() -> void:
	var r := ShotRequest.new()
	assert_eq(r.owner_layer, Layers.PLAYER)
	r.owner_layer = Layers.ENEMY
	r.reset()
	assert_eq(r.owner_layer, Layers.PLAYER)


func test_a_player_owned_bullet_cannot_be_made_to_hit_the_player() -> void:
	var r := ShotRequest.new()
	r.hit_mask = Layers.PLAYER
	var i := pool.spawn(r)
	assert_eq(pool.hit_mask[i], 0)


func test_reflect_swaps_owner_mask_and_colour() -> void:
	var i := _enemy_bullet()
	assert_true(pool.reflect(i, Layers.PLAYER))
	assert_eq(pool.owner_layer[i], Layers.PLAYER)
	assert_eq(pool.hit_mask[i], Layers.hostile_to(Layers.PLAYER))
	assert_eq(pool.hit_mask[i], Layers.ENEMY)
	assert_eq(pool.color[i], Layers.bullet_color(Layers.PLAYER))


func test_reflect_back_and_forth_when_the_limit_is_lifted() -> void:
	pool.max_reflections = 0
	var i := _enemy_bullet()
	pool.reflect(i, Layers.PLAYER)
	pool.reflect(i, Layers.ENEMY)
	assert_eq(pool.hit_mask[i], Layers.PLAYER)
	assert_eq(pool.color[i], Layers.bullet_color(Layers.ENEMY))


func test_reflect_never_lets_a_bullet_hit_its_new_owner() -> void:
	pool.max_reflections = 0
	var i := _enemy_bullet()
	for owner_layer: int in [Layers.PLAYER, Layers.ENEMY, Layers.PLAYER]:
		pool.reflect(i, owner_layer)
		assert_eq(pool.hit_mask[i] & owner_layer, 0)


func test_reflect_with_reverse_flips_velocity_and_heading() -> void:
	var i := _enemy_bullet()
	pool.reflect(i, Layers.PLAYER, true)
	assert_eq(pool.vel[i], Vector2(-200, 0))
	assert_eq(pool.rot[i], Vector2.LEFT)


func test_reflect_without_reverse_keeps_velocity() -> void:
	var i := _enemy_bullet()
	pool.reflect(i, Layers.PLAYER)
	assert_eq(pool.vel[i], Vector2(200, 0))


func test_reflect_clears_the_piercing_last_hit() -> void:
	var i := _enemy_bullet()
	pool.last_hit[i] = 1234
	pool.reflect(i, Layers.PLAYER)
	assert_eq(pool.last_hit[i], 0)


func test_reflect_rejects_bad_owner_and_dead_or_out_of_range_slots() -> void:
	var i := _enemy_bullet()
	assert_false(pool.reflect(i, 0))
	assert_false(pool.reflect(i, Layers.WORLD))
	assert_false(pool.reflect(i, Layers.PLAYER | Layers.ENEMY))
	assert_eq(pool.owner_layer[i], Layers.ENEMY, "untouched")
	assert_false(pool.reflect(-1, Layers.PLAYER))
	assert_false(pool.reflect(pool.count, Layers.PLAYER))
	pool.mark_dead(i, BulletPool.DespawnReason.LIFETIME)
	assert_false(pool.reflect(i, Layers.PLAYER), "bullets about to be removed can't be reflected")


func test_owner_follows_the_bullet_through_swap_remove() -> void:
	var a := _enemy_bullet()
	var b_req := ShotRequest.new()
	b_req.position = Vector2(5, 5)
	var b := pool.spawn(b_req)
	pool.mark_dead(a, BulletPool.DespawnReason.LIFETIME)
	pool.flush_dead()
	assert_eq(pool.count, 1)
	assert_eq(pool.owner_layer[0], Layers.PLAYER, "the player-owned bullet moved into slot 0")
	assert_eq(b, 1)


func test_reflect_count_tracks_owner_changes_and_resets_per_bullet() -> void:
	pool.max_reflections = 0
	var a := _enemy_bullet()
	assert_eq(pool.reflect_count[a], 0)
	pool.reflect(a, Layers.PLAYER)
	pool.reflect(a, Layers.ENEMY)
	assert_eq(pool.reflect_count[a], 2)
	assert_false(pool.reflect(a, 0))
	assert_eq(pool.reflect_count[a], 2, "a refused reflect does not count")
	var b := _enemy_bullet()
	assert_eq(pool.reflect_count[b], 0, "new bullets start at zero")


func test_reflect_count_saturates_and_follows_swap_remove() -> void:
	pool.max_reflections = 0
	var a := _enemy_bullet()
	var b := _enemy_bullet()
	for k in 300:
		pool.reflect(b, Layers.PLAYER if k % 2 == 0 else Layers.ENEMY)
	assert_eq(pool.reflect_count[b], 255)
	pool.mark_dead(a, BulletPool.DespawnReason.LIFETIME)
	pool.flush_dead()
	assert_eq(pool.reflect_count[0], 255, "moved into slot 0 with its bullet")
	var c := _enemy_bullet()
	assert_eq(pool.reflect_count[c], 0, "a recycled slot is clean")


func test_faction_colours_are_distinct() -> void:
	assert_ne(Layers.bullet_color(Layers.PLAYER), Layers.bullet_color(Layers.ENEMY))
	assert_eq(Layers.bullet_color(Layers.PLAYER), Color("ffd166"))
	assert_eq(Layers.bullet_color(Layers.ENEMY), Color("ff5a4d"), "pillars enemy red #FF5A4D")


# --- through the manager and the emitter interface ---------------------------------

func _manager() -> BulletManager:
	var m := BulletManager.new()
	m.auto_step = false
	m.render_enabled = false
	add_child_autofree(m)
	return m


func test_emitter_reflect_bullet_by_stable_id() -> void:
	var m := _manager()
	var r := ShotRequest.polar(Vector2.ZERO, 0.0, 100.0)
	r.owner_layer = Layers.ENEMY
	r.hit_mask = Layers.PLAYER
	var id := m.emitter.request_shot_id(r)
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER, true))
	var slot := m.pool.slot_of(id)
	assert_eq(m.pool.hit_mask[slot], Layers.ENEMY)
	assert_eq(m.pool.color[slot], Layers.bullet_color(Layers.PLAYER))
	assert_eq(m.pool.vel[slot], Vector2(-100, 0))


func test_emitter_reflect_rejects_stale_ids() -> void:
	var m := _manager()
	var r := ShotRequest.new()
	r.lifetime = 0.01
	var id := m.emitter.request_shot_id(r)
	m.step(0.1)
	assert_false(m.emitter.is_bullet_alive(id))
	assert_false(m.emitter.reflect_bullet(id, Layers.ENEMY))
	assert_false(m.emitter.reflect_bullet(-1, Layers.ENEMY))
	assert_false(ShotEmitter.new().reflect_bullet(1, Layers.ENEMY), "base interface does nothing")


func test_a_reflected_bullet_hurts_the_old_owner_and_spares_the_new_one() -> void:
	var m := _manager()
	var player_box := _hurtbox(Vector2(0, 0), Layers.PLAYER)
	var enemy_box := _hurtbox(Vector2(200, 0), Layers.ENEMY)
	# An enemy bullet sitting on the player is reflected before it can hit.
	var r := ShotRequest.polar(Vector2(0, 0), 0.0, 0.0)
	r.owner_layer = Layers.ENEMY
	r.hit_mask = Layers.PLAYER
	r.lifetime = 5.0
	var id := m.emitter.request_shot_id(r)
	m.emitter.reflect_bullet(id, Layers.PLAYER)
	m.step(DT)
	assert_eq(player_box.hits, 0, "reflected bullet ignores the player")
	assert_true(m.emitter.is_bullet_alive(id))
	# Now it flies at the enemy.
	var slot := m.pool.slot_of(id)
	m.pool.vel[slot] = Vector2(600, 0)
	for i in 60:
		m.step(DT)
	assert_eq(enemy_box.hits, 1, "and hits the enemy")
	assert_false(m.emitter.is_bullet_alive(id))


func _hurtbox(pos: Vector2, layer: int) -> ReflectTarget:
	var t := ReflectTarget.new()
	t.layer = layer
	t.radius = 12.0
	add_child_autofree(t)
	t.global_position = pos
	return t


## A hurtbox that counts hits.
class ReflectTarget:
	extends Hurtbox
	var hits := 0

	func _ready() -> void:
		hit.connect(func(_d: float, _p: Vector2, _v: Vector2) -> void: hits += 1)
