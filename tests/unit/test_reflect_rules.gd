extends GutTest
## What a reflection does to a bullet (QA B1/B2): damage, un-scripting, the
## one-reflection guard on every path, plus the hit details a hurtbox receives.

const DT := 1.0 / 60.0

var m: BulletManager
var rec := Recorder.new()
var behavior_id := 0


class Recorder:
	extends BulletBehavior
	var log: Array[String] = []

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		log.append("update")

	func on_despawn(_pool: BulletPool, _index: int, _reason: int) -> void:
		log.append("despawn")


## Reflects another bullet (by stable id) from inside its own on_update hook.
class Reflecting:
	extends BulletBehavior
	var victim := 0
	var did := false

	func on_update(_pool: BulletPool, _index: int, _delta: float) -> void:
		if not did:
			did = true
			emitter.reflect_bullet(victim, Layers.PLAYER)


class Probe:
	extends Hurtbox
	var hits := 0
	var ids: Array[int] = []
	var flags: Array[int] = []
	var damages: Array[float] = []
	var deactivate_on_hit := false

	func _ready() -> void:
		hit.connect(_on_probe_hit)

	func _on_probe_hit(damage: float, _p: Vector2, _v: Vector2) -> void:
		hits += 1
		ids.append(last_hit_bullet_id)
		flags.append(last_hit_flags)
		damages.append(damage)
		if deactivate_on_hit:
			active = false


func before_each() -> void:
	m = BulletManager.new()
	m.auto_step = false
	m.render_enabled = false
	add_child_autofree(m)
	rec = Recorder.new()
	behavior_id = m.register_behavior(rec)


func _enemy_shot(damage := 3.0, scripted := true) -> ShotRequest:
	var r := ShotRequest.polar(Vector2(0, 0), 0.0, 100.0)
	r.owner_layer = Layers.ENEMY
	r.hit_mask = Layers.PLAYER
	r.damage = damage
	r.lifetime = 5.0
	if scripted:
		r.behavior_id = behavior_id
		r.param_a = 7.0
		r.param_b = 8.0
		r.pierces_script_invuln = true
	return r


func _probe(pos: Vector2, layer: int) -> Probe:
	var p := Probe.new()
	p.layer = layer
	p.radius = 12.0
	add_child_autofree(p)
	p.global_position = pos
	return p


# --- B1: damage --------------------------------------------------------------

func test_a_reflected_bullet_deals_one_damage_by_default() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot(3.0))
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER))
	assert_eq(m.pool.damage[m.pool.slot_of(id)], 1.0, "pillars 5.4: script damage is ignored")
	assert_eq(BulletPool.REFLECTED_DAMAGE, 1.0)


func test_reflect_damage_is_parameterised() -> void:
	var a := m.emitter.request_shot_id(_enemy_shot(3.0))
	m.emitter.reflect_bullet(a, Layers.PLAYER, false, 2.5)
	assert_eq(m.pool.damage[m.pool.slot_of(a)], 2.5)
	var b := m.emitter.request_shot_id(_enemy_shot(3.0))
	m.emitter.reflect_bullet(b, Layers.PLAYER, false, BulletPool.KEEP_DAMAGE)
	assert_eq(m.pool.damage[m.pool.slot_of(b)], 3.0, "KEEP_DAMAGE keeps the script's value")


func test_a_refused_reflect_leaves_the_damage_alone() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot(3.0))
	assert_false(m.emitter.reflect_bullet(id, 0))
	assert_eq(m.pool.damage[m.pool.slot_of(id)], 3.0)


func test_the_reflected_bullet_hits_for_one_in_the_real_pipeline() -> void:
	var enemy := _probe(Vector2(60, 0), Layers.ENEMY)
	var id := m.emitter.request_shot_id(_enemy_shot(5.0, false))
	m.emitter.reflect_bullet(id, Layers.PLAYER)
	for i in 60:
		m.step(DT)
	assert_eq(enemy.hits, 1)
	assert_eq(enemy.damages[0], 1.0, "reflected: 1 damage, not the script's 5")


# --- B2: un-scripting ---------------------------------------------------------

func test_reflect_clears_behavior_user_params_and_the_piercing_flag() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot())
	var slot := m.pool.slot_of(id)
	m.pool.user[slot] = {"secret": 1}
	assert_eq(m.pool.behavior[slot], behavior_id)
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER))
	assert_eq(m.pool.behavior[slot], 0, "no longer scripted")
	assert_true(m.pool.user[slot] == null, "user cleared")
	assert_eq(m.pool.param_a[slot], 0.0)
	assert_eq(m.pool.param_b[slot], 0.0)
	assert_eq(m.pool.pierces_script_invuln[slot], 0)


func test_keep_script_is_the_opt_in_to_keep_everything() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot())
	var slot := m.pool.slot_of(id)
	m.pool.user[slot] = "keep me"
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER, false, 1.0, true))
	assert_eq(m.pool.behavior[slot], behavior_id)
	var kept: bool = str(m.pool.user[slot]) == "keep me"
	assert_true(kept, "user kept")
	assert_eq(m.pool.param_a[slot], 7.0)
	assert_eq(m.pool.param_b[slot], 8.0)
	assert_eq(m.pool.pierces_script_invuln[slot], 1)


func test_the_old_script_gets_no_more_hooks_after_a_reflection() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot())
	m.step(DT)
	assert_eq(rec.log, ["update"] as Array[String])
	m.emitter.reflect_bullet(id, Layers.PLAYER)
	m.step(DT)
	m.step(DT)
	assert_eq(rec.log, ["update"] as Array[String], "no update after the reflection")
	m.pool.mark_dead(m.pool.slot_of(id), BulletPool.DespawnReason.LIFETIME)
	m.step(DT)
	assert_does_not_have(rec.log, "despawn", "the old script is not told about the end of a bullet it no longer owns")


func test_keep_script_keeps_the_hooks_running() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot())
	m.emitter.reflect_bullet(id, Layers.PLAYER, false, 1.0, true)
	m.step(DT)
	assert_eq(rec.log, ["update"] as Array[String])


func test_a_hook_can_reflect_a_later_bullet_in_the_hooked_list() -> void:
	var reflecting := Reflecting.new()
	var rid := m.register_behavior(reflecting)
	var first := ShotRequest.polar(Vector2(0, 0), 0.0, 10.0)
	first.behavior_id = rid
	first.lifetime = 5.0
	m.emitter.request_shot_id(first)
	var victim := m.emitter.request_shot_id(_enemy_shot())
	reflecting.victim = victim
	m.step(DT)
	assert_true(reflecting.did)
	assert_eq(m.pool.behavior[m.pool.slot_of(victim)], 0)
	assert_does_not_have(rec.log, "update", "un-scripted before its own hook ran")
	m.step(DT)
	assert_eq(m.pool.count, 2, "nothing crashed or vanished")


# --- B2: the guard, on every path ---------------------------------------------

func test_reflect_bullet_refuses_a_second_reflection() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot(3.0, false))
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER))
	var slot := m.pool.slot_of(id)
	assert_false(m.emitter.reflect_bullet(id, Layers.ENEMY), "a bullet is reflected once")
	assert_eq(m.pool.owner_layer[slot], Layers.PLAYER, "still the first reflection's owner")
	assert_eq(m.pool.hit_mask[slot], Layers.ENEMY)
	assert_eq(m.pool.color[slot], Layers.bullet_color(Layers.PLAYER))
	assert_eq(m.pool.reflect_count[slot], 1)


func test_the_guard_does_not_depend_on_the_bullet_being_reversed() -> void:
	var id := m.emitter.request_shot_id(_enemy_shot(3.0, false))
	m.emitter.reflect_bullet(id, Layers.PLAYER, true)
	var v := m.pool.vel[m.pool.slot_of(id)]
	assert_false(m.emitter.reflect_bullet(id, Layers.ENEMY, true))
	assert_eq(m.pool.vel[m.pool.slot_of(id)], v, "a refused reflect does not flip velocity")


func test_max_reflections_is_configurable_and_zero_is_unlimited() -> void:
	m.pool.max_reflections = 2
	var id := m.emitter.request_shot_id(_enemy_shot(3.0, false))
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER))
	assert_true(m.emitter.reflect_bullet(id, Layers.ENEMY))
	assert_false(m.emitter.reflect_bullet(id, Layers.PLAYER))
	m.pool.max_reflections = 0
	assert_true(m.emitter.reflect_bullet(id, Layers.PLAYER), "0 = no limit")


func test_a_script_reflection_and_a_zone_share_one_counter() -> void:
	# A zone reflected it already; the script's call must be refused.
	var id := m.emitter.request_shot_id(_enemy_shot(3.0, false))
	m.pool.reflect(m.pool.slot_of(id), Layers.PLAYER, false, 1.0, false, 1)
	assert_false(m.emitter.reflect_bullet(id, Layers.ENEMY))


# --- plumbing: flag follows swap-remove, defaults ------------------------------

func test_pierces_flag_follows_swap_remove_and_recycled_slots_are_clean() -> void:
	var a := m.emitter.request_shot_id(_enemy_shot(1.0, false))
	var b := m.emitter.request_shot_id(_enemy_shot(1.0, true))
	assert_eq(m.pool.pierces_script_invuln[m.pool.slot_of(b)], 1)
	m.pool.mark_dead(m.pool.slot_of(a), BulletPool.DespawnReason.LIFETIME)
	m.step(DT)
	assert_eq(m.pool.count, 1)
	assert_eq(m.pool.pierces_script_invuln[0], 1, "moved into slot 0 with its bullet")
	var c := m.emitter.request_shot_id(_enemy_shot(1.0, false))
	assert_eq(m.pool.pierces_script_invuln[m.pool.slot_of(c)], 0)


func test_shot_request_pierces_flag_defaults_off_and_resets() -> void:
	var r := ShotRequest.new()
	assert_false(r.pierces_script_invuln)
	r.pierces_script_invuln = true
	r.reset()
	assert_false(r.pierces_script_invuln)


# --- Hurtbox hit details ------------------------------------------------------

func test_the_hurtbox_sees_the_bullet_id_and_its_flags() -> void:
	var box := _probe(Vector2(40, 0), Layers.PLAYER)
	var piercing := _enemy_shot(2.0, false)
	piercing.pierces_script_invuln = true
	var id := m.emitter.request_shot_id(piercing)
	for i in 30:
		m.step(DT)
	assert_eq(box.hits, 1)
	assert_eq(box.ids[0], id, "stable id of the bullet")
	assert_eq(box.flags[0], Health.SOURCE_PIERCES_SCRIPT_INVULN)
	assert_eq(box.damages[0], 2.0)


func test_a_normal_bullet_carries_no_flags() -> void:
	var box := _probe(Vector2(40, 0), Layers.PLAYER)
	var plain := _enemy_shot(1.0, false)
	m.emitter.request_shot_id(plain)
	for i in 30:
		m.step(DT)
	assert_eq(box.flags[0], 0)


func test_a_target_switched_off_mid_tick_does_not_eat_the_next_bullet() -> void:
	var box := _probe(Vector2(40, 0), Layers.PLAYER)
	box.deactivate_on_hit = true
	var a := m.emitter.request_shot_id(_enemy_shot(1.0, false))
	var b := m.emitter.request_shot_id(_enemy_shot(1.0, false))
	for i in 30:
		m.step(DT)
	assert_eq(box.hits, 1, "only the first bullet reached the (now inactive) hurtbox")
	var survivors := int(m.emitter.is_bullet_alive(a)) + int(m.emitter.is_bullet_alive(b))
	assert_eq(survivors, 1, "the second bullet passed through instead of being consumed")
