class_name Warden
extends Node2D
## Vertical-slice row 8: Warden phase 1 (docs/design/vertical-slice.md §5).
##
## Phases 2–3 (Fan, Broken ring, habituation, fourth husk) are row 9 and are
## stubbed here: the phase index still clamps forward at the HP thresholds so
## the HUD and tests can bind, but the attack set stays at phase 1.
##
## #85's Hurtbox ABSORB is not on main. ARMOR_ABSORBS is an easy local switch:
## false (default, per §5 / row 8 acceptance) applies ×0.1 to the body; true
## makes body hits vanish. The 70° gap is the armor *ring* (tracks facing, never
## shrinks with HP) and is independent of the HUD boss bar.

signal phase_changed(phase: int)
signal defeated
signal aggroed

const GROUP := &"wardens"
const MAX_HP := 900.0
const BODY_RADIUS := 48.0
const GAP_DEGREES := 70.0
const GAP_HURT_RADIUS := 16.0
const GAP_OFFSET := 40.0
const ARMOR_RING_RADIUS := 52.0
const BODY_DAMAGE_SCALE := 0.1
## When true, shots into the body (outside the gap tick) deal 0 instead of
## ×0.1. Flip this if #85 lands and design wants armor to swallow hits.
const ARMOR_ABSORBS := false
const PHASE_2_HP := 630.0
const PHASE_3_HP := 360.0
const PHASE_COUNT := 3
const GAP_TURN_12 := deg_to_rad(120.0)
const GAP_TURN_3 := deg_to_rad(240.0)
const AGGRO_X := 8736.0
const HUSK_COUNT := 3
const HUSK_ORBIT := 150.0
const HUSK_TURN := deg_to_rad(90.0)
const HUSK_RESPAWN := 8.0
const TITHE_HP := 50.0
const TITHE_FLASH := 0.35
const FEEDS_SECONDS := 1.5
const LANCE_PERIOD := 2.4
const LANCE_WINDUP := 0.6
## First Lance windup after aggro (GD #96): shorter than the steady period.
const LANCE_FIRST_WAIT := 1.0
const LANCE_SPEED := 320.0
const LANCE_RADIUS := 6.0
const LANCE_LIFETIME := 3.0
const LANCE_DAMAGE := 1.0
const LANCE_COLOR := Color("FF5A4D")
const COLOR_FILL := Color("3D7EFF")
const COLOR_OUTLINE := Color("E7E9EE")
const COLOR_TICK := Color(1, 1, 1)
const OUTLINE_WIDTH := 3.0
const HIT_FLASH := 0.12
## Player's drawn / collision body (scenes/player.tscn CircleShape2D 13 px).
const PLAYER_RADIUS := 13.0
## Trauma that caps FollowCamera shake at 3 px on the default 18 px x-axis.
const PHASE_TRAUMA := 0.40824829
const TIER := RarityCue.TIER_BOSS_COMMON


var player: Player
var _bullets: BulletManager
var _camera: FollowCamera
var health: Health
var _body_hurt: Hurtbox
var _gap_hurt: Hurtbox
var cue := RarityCue.new()

var _phase := 1
var _alive := true
var _aggro := false
var _gap_angle := 0.0
var _husk_lock_angle := 0.0
var _husk_lock_slot := -1
var _husks: Array[WardenHusk] = []
var _respawn_left: PackedFloat32Array = PackedFloat32Array()
var _lance_wait := 0.0
var _lance_windup := 0.0
var _lance_aim := Vector2.ZERO
var _lance_winding := false
var _flash_left := 0.0
var _tithe_left := 0.0
var _tithe_from := Vector2.ZERO
var _feeds_left := 0.0
## Set when "It feeds." has been shown or the save already has seen_it_feeds.
## Survives death resets; only the save flag is the long-term source.
var _feeds_recorded := false
var _warp_id := 0
var _death_emitted := false
var _bound := false
## Last Lance request, for tests. Null until the first shot. Only set when
## spawn() returns a live id (>= 0).
var last_lance: ShotRequest
var save: SaveGame
## Per-slot: this husk body has died at least once this fight (respawns emit
## first_death=false). Cleared on reset_fight.
var _husk_had_death: Array[bool] = []
## Bullet ids that already applied core damage this frame (one ×1 per bullet).
var _core_hit_ids: PackedInt64Array = PackedInt64Array()
var _drawn_gap_q := INF
var _drawn_hp := -1.0
var _drawn_phase := -1
var _drawn_lance := false


func _ready() -> void:
	add_to_group(GROUP)
	z_index = 4
	_ensure_health()
	_ensure_hurtboxes()
	health.died.connect(_on_core_died)
	health.damaged.connect(_on_core_damaged)
	health.hp_changed.connect(_on_hp_changed)
	cue.boss_hue = COLOR_FILL
	cue.setup(TIER)
	cue.try_acquire()
	cue.attach(self)
	_set_hurtboxes_active(false)
	_add_warp()
	if not _bound:
		_register_query()
	queue_redraw()


func _exit_tree() -> void:
	cue.release()
	WorldQuery.unregister_enemy(self)
	_remove_warp()


func _ensure_health() -> void:
	health = get_node_or_null("Health") as Health
	if health == null:
		health = Health.new()
		health.name = "Health"
		add_child(health)
	health.set_max_hp(MAX_HP)
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	health.reset()


func _ensure_hurtboxes() -> void:
	_body_hurt = _make_hurtbox("BodyHurtbox", BODY_RADIUS)
	_body_hurt.hit.connect(_on_body_hit)
	_gap_hurt = _make_hurtbox("GapHurtbox", GAP_HURT_RADIUS)
	_gap_hurt.position = Vector2.from_angle(_gap_angle) * GAP_OFFSET
	_gap_hurt.hit.connect(_on_gap_hit)


func _make_hurtbox(node_name: String, radius: float) -> Hurtbox:
	var existing := get_node_or_null(node_name) as Hurtbox
	var box := existing if existing != null else Hurtbox.new()
	box.name = node_name
	box.radius = radius
	box.layer = Layers.ENEMY
	box.active = false
	if existing == null:
		add_child(box)
	return box


## Player, bullets, optional camera, and the slot used for seen_it_feeds.
## Safe to call more than once.
func bind(
	p_player: Player,
	bullets: BulletManager,
	camera: FollowCamera = null,
	p_save: SaveGame = null
) -> void:
	player = p_player
	_bullets = bullets
	_camera = camera
	if p_save != null:
		save = p_save
	if save != null and save.seen_it_feeds:
		_feeds_recorded = true
	_bound = true
	if is_inside_tree():
		_register_query()


## Puts the fight in the pre-aggro waiting state (living core at 900 HP).
func reset_fight() -> void:
	if not _alive and _death_emitted:
		return
	_despawn_husks()
	_phase = 1
	_alive = true
	_aggro = false
	_death_emitted = false
	_lance_winding = false
	_lance_wait = 0.0
	_lance_windup = 0.0
	_feeds_left = 0.0
	_tithe_left = 0.0
	_husk_lock_slot = -1
	_flash_left = 0.0
	_husk_had_death.clear()
	_core_hit_ids = PackedInt64Array()
	_clear_own_shots()
	if health != null:
		health.reset()
	_set_hurtboxes_active(false)
	_add_warp()
	_register_query()
	queue_redraw()


## Player death resets aggro on a living boss (spec §5). A dead core stays dead.
func on_player_died() -> void:
	if _alive:
		reset_fight()


func debug_force_aggro() -> void:
	if _alive and not _aggro:
		_enter_aggro()


## Instantiates the packed scene at the arena centre (or `at`) and aggros.
static func spawn_for_debug(parent: Node, at: Vector2 = SliceLayout.ARENA_CENTRE) -> Warden:
	var warden := (preload("res://scenes/warden.tscn") as PackedScene).instantiate() as Warden
	warden.position = at
	parent.add_child(warden)
	warden.debug_force_aggro()
	return warden


func is_alive() -> bool:
	return _alive


func is_aggroed() -> bool:
	return _aggro


func current_phase() -> int:
	return _phase


func gap_degrees() -> float:
	return GAP_DEGREES


func gap_angle() -> float:
	return _gap_angle


func gap_point() -> Vector2:
	return global_position + Vector2.from_angle(_gap_angle) * GAP_OFFSET


func husks() -> Array[WardenHusk]:
	return _husks


## Routes a debug / unit-test shot the same way a bullet sweep would: the gap
## tick hurtbox has priority over the body.
func apply_debug_hit(
	world_pos: Vector2,
	damage: float = 1.0,
	flags: int = 0,
	bullet_id: int = 0
) -> void:
	if not _alive or not _aggro:
		return
	if _in_gap_tick(world_pos):
		_apply_core_damage(damage, flags, bullet_id)
		return
	if _in_body(world_pos):
		_hit_body(world_pos, damage, flags, bullet_id)


func _physics_process(delta: float) -> void:
	if not _alive:
		return
	_core_hit_ids = PackedInt64Array()
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - delta, 0.0)
		queue_redraw()
	if _tithe_left > 0.0:
		_tithe_left = maxf(_tithe_left - delta, 0.0)
		queue_redraw()
	if _feeds_left > 0.0:
		_feeds_left = maxf(_feeds_left - delta, 0.0)
		queue_redraw()
	cue.advance(delta)
	if not _aggro:
		_try_aggro()
		return
	_steer_gap(delta)
	_step_husks(delta)
	_step_lance(delta)
	_push_and_contact()
	_redraw_if_pose_changed()


func _try_aggro() -> void:
	if player == null or not is_instance_valid(player):
		return
	# A corpse past AGGRO_X must not re-aggro after reset_fight (QA #96).
	if player.is_dead():
		return
	if player.health != null and player.health.is_dead():
		return
	if player.global_position.x >= AGGRO_X:
		_enter_aggro()


func _enter_aggro() -> void:
	_aggro = true
	_set_hurtboxes_active(true)
	_spawn_husks()
	_lance_wait = LANCE_FIRST_WAIT
	_lance_winding = false
	aggroed.emit()
	_register_query()
	queue_redraw()


func _set_hurtboxes_active(on: bool) -> void:
	if _body_hurt != null:
		_body_hurt.active = on
	if _gap_hurt != null:
		_gap_hurt.active = on


func _steer_gap(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	# Far-side bearing: from the player through the core.
	var away: Vector2 = global_position - player.global_position
	if away.length_squared() < 0.0001:
		return
	var desired := away.angle()
	var cap := GAP_TURN_3 if _phase >= 3 else GAP_TURN_12
	var diff := angle_difference(_gap_angle, desired)
	_gap_angle += clampf(diff, -cap * delta, cap * delta)
	if _gap_hurt != null:
		_gap_hurt.position = Vector2.from_angle(_gap_angle) * GAP_OFFSET


func _spawn_husks() -> void:
	_despawn_husks()
	_husks.resize(HUSK_COUNT)
	_respawn_left = PackedFloat32Array()
	_respawn_left.resize(HUSK_COUNT)
	var bearing := _player_bearing()
	if is_finite(bearing):
		_husk_lock_angle = bearing
	for i in HUSK_COUNT:
		_spawn_husk_at(i, _husk_lock_angle + TAU * float(i) / float(HUSK_COUNT))
		_respawn_left[i] = 0.0
	_husk_lock_slot = 0 if HUSK_COUNT > 0 else -1


func husk_cap() -> int:
	return HUSK_COUNT


func _spawn_husk_at(slot: int, angle: float) -> void:
	var husk := WardenHusk.new()
	var first_death := true
	if slot >= 0 and slot < _husk_had_death.size() and _husk_had_death[slot]:
		first_death = false
	husk.setup(self, slot, first_death)
	husk.orbit_angle = angle
	husk.position = Vector2.from_angle(angle) * HUSK_ORBIT
	add_child(husk)
	_husks[slot] = husk
	# A respawned husk takes the lock only when no other husk is alive.
	# Then it appears on the far side and turns toward the player at 90°/s.
	if _living_husk_count() == 1:
		_husk_lock_slot = slot
		_husk_lock_angle = angle


func _despawn_husks() -> void:
	for husk in _husks:
		if husk != null and is_instance_valid(husk):
			husk.despawn()
	_husks.clear()
	_respawn_left = PackedFloat32Array()
	_husk_lock_slot = -1
	_husk_had_death.clear()


func _step_husks(delta: float) -> void:
	_steer_lock(delta)
	_steer_husk_spacing(delta)
	_apply_husk_positions()
	_step_husk_respawns(delta)


func _steer_lock(delta: float) -> void:
	var husk := lock_husk()
	if husk == null:
		return
	var desired := _player_bearing()
	if is_finite(desired):
		var diff := angle_difference(_husk_lock_angle, desired)
		_husk_lock_angle += clampf(diff, -HUSK_TURN * delta, HUSK_TURN * delta)
	husk.orbit_angle = _husk_lock_angle


func _steer_husk_spacing(delta: float) -> void:
	var lock := lock_husk()
	var others: Array[WardenHusk] = []
	for husk in _husks:
		if husk != null and is_instance_valid(husk) and husk.is_alive() and husk != lock:
			others.append(husk)
	var living := others.size() + (1 if lock != null else 0)
	if living <= 1 or others.is_empty():
		return
	var origin := _husk_lock_angle if lock != null else others[0].orbit_angle
	var targets: Array[float] = []
	for i in range(1, living):
		targets.append(origin + TAU * float(i) / float(living))
	var assigned := _assign_orbit_targets(others, targets)
	for i in others.size():
		var husk := others[i]
		var diff := angle_difference(husk.orbit_angle, assigned[i])
		husk.orbit_angle += clampf(diff, -HUSK_TURN * delta, HUSK_TURN * delta)


func _assign_orbit_targets(husks: Array[WardenHusk], targets: Array[float]) -> Array[float]:
	var pairs: Array[Vector3] = []
	for hi in husks.size():
		for ti in targets.size():
			var dist := absf(angle_difference(husks[hi].orbit_angle, targets[ti]))
			pairs.append(Vector3(dist, float(hi), float(ti)))
	pairs.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.x < b.x)
	var husk_used: Array[bool] = []
	var target_used: Array[bool] = []
	husk_used.resize(husks.size())
	target_used.resize(targets.size())
	var out: Array[float] = []
	out.resize(husks.size())
	for pair in pairs:
		var hi := int(pair.y)
		var ti := int(pair.z)
		if husk_used[hi] or target_used[ti]:
			continue
		husk_used[hi] = true
		target_used[ti] = true
		out[hi] = targets[ti]
	return out


func _apply_husk_positions() -> void:
	for husk in _husks:
		if husk != null and is_instance_valid(husk) and husk.is_alive():
			husk.position = Vector2.from_angle(husk.orbit_angle) * HUSK_ORBIT


func _step_husk_respawns(delta: float) -> void:
	var cap := husk_cap()
	for i in _husks.size():
		var husk := _husks[i]
		if husk != null and is_instance_valid(husk) and husk.is_alive():
			continue
		if _respawn_left.size() <= i or _respawn_left[i] <= 0.0:
			continue
		if _living_husk_count() >= cap:
			_respawn_left[i] = 0.0
			continue
		_respawn_left[i] = maxf(_respawn_left[i] - delta, 0.0)
		if _respawn_left[i] <= 0.0:
			if _living_husk_count() >= cap:
				_respawn_left[i] = 0.0
				continue
			# Far side of the circle (opposite the player). Takes the lock
			# only if it is the only living husk (handled in _spawn_husk_at).
			var far := _player_bearing()
			if is_finite(far):
				far += PI
			else:
				far = _husk_lock_angle + PI
			_spawn_husk_at(i, far)


func _player_bearing() -> float:
	if player == null or not is_instance_valid(player):
		return NAN
	var to_player: Vector2 = player.global_position - global_position
	if to_player.length_squared() <= 0.0001:
		return NAN
	return to_player.angle()


func _living_husk_count() -> int:
	var n := 0
	for husk in _husks:
		if husk != null and is_instance_valid(husk) and husk.is_alive():
			n += 1
	return n


func lock_angle() -> float:
	return _husk_lock_angle


func lock_slot() -> int:
	return _husk_lock_slot


func lock_husk() -> WardenHusk:
	if _husk_lock_slot < 0 or _husk_lock_slot >= _husks.size():
		return null
	var husk := _husks[_husk_lock_slot]
	if husk == null or not is_instance_valid(husk) or not husk.is_alive():
		return null
	return husk


func feeds_line_visible() -> bool:
	return _feeds_left > 0.0


func _reassign_lock() -> void:
	var bearing := _player_bearing()
	var best := -1
	var best_diff := INF
	for i in _husks.size():
		var husk := _husks[i]
		if husk == null or not is_instance_valid(husk) or not husk.is_alive():
			continue
		var diff := 0.0
		if is_finite(bearing):
			diff = absf(angle_difference(husk.orbit_angle, bearing))
		if diff < best_diff or (is_equal_approx(diff, best_diff) and (best < 0 or i < best)):
			best_diff = diff
			best = i
	_husk_lock_slot = best
	if best >= 0:
		_husk_lock_angle = _husks[best].orbit_angle


func notify_husk_died(slot: int, at: Vector2) -> void:
	if slot < 0 or slot >= _husks.size():
		return
	if _husk_had_death.size() <= slot:
		_husk_had_death.resize(slot + 1)
	_husk_had_death[slot] = true
	_husks[slot] = null
	if _respawn_left.size() == _husks.size():
		_respawn_left[slot] = HUSK_RESPAWN
	if slot == _husk_lock_slot:
		_reassign_lock()
	# Same-tick core kill is not healed: if the core already hit 0, skip.
	if _alive and health != null and health.hp > 0.0 and not health.is_dead():
		health.heal(TITHE_HP)
		_tithe_from = at
		_tithe_left = TITHE_FLASH
		_maybe_show_feeds()
		queue_redraw()


func _maybe_show_feeds() -> void:
	# Once per save, not per fight and not after a death reset (GD #96).
	if _feeds_recorded:
		return
	if save != null and save.seen_it_feeds:
		_feeds_recorded = true
		return
	_feeds_recorded = true
	_feeds_left = FEEDS_SECONDS
	if save != null:
		save.seen_it_feeds = true
		save.save()


func _step_lance(delta: float) -> void:
	if _lance_winding:
		_lance_windup -= delta
		if _lance_windup <= 0.0:
			_lance_winding = false
			_fire_lance()
			# Period is start-to-start (2.4 s), so the next windup waits the
			# remainder after this 0.6 s telegraph.
			_lance_wait = maxf(LANCE_PERIOD - LANCE_WINDUP, 0.0)
		queue_redraw()
		return
	_lance_wait -= delta
	if _lance_wait <= 0.0:
		_begin_lance_windup()


func _begin_lance_windup() -> void:
	_lance_winding = true
	_lance_windup = LANCE_WINDUP
	if player != null and is_instance_valid(player):
		_lance_aim = player.global_position
	else:
		_lance_aim = global_position + Vector2.LEFT * 200.0
	queue_redraw()


func _fire_lance() -> void:
	if _bullets == null or not is_instance_valid(_bullets):
		return
	var heading := (_lance_aim - global_position).angle()
	var req := ShotRequest.polar(global_position, heading, LANCE_SPEED)
	req.radius = LANCE_RADIUS
	req.lifetime = LANCE_LIFETIME
	req.damage = LANCE_DAMAGE
	req.hit_mask = Layers.PLAYER
	req.owner_layer = Layers.ENEMY
	req.color = LANCE_COLOR
	req.pierces_script_invuln = false
	req.collide_world = true
	var id := _bullets.spawn(req)
	if id >= 0:
		last_lance = req


func _push_and_contact() -> void:
	if player == null or not is_instance_valid(player):
		return
	var dashing := player.is_dashing()
	_push_circle(global_position, BODY_RADIUS, dashing)
	for husk in _husks:
		if husk != null and is_instance_valid(husk) and husk.is_alive():
			_push_circle(husk.global_position, WardenHusk.RADIUS, dashing)
	if dashing:
		return
	_try_contact(global_position, BODY_RADIUS)
	for husk in _husks:
		if husk != null and is_instance_valid(husk) and husk.is_alive():
			_try_contact(husk.global_position, WardenHusk.RADIUS)


func _push_circle(centre: Vector2, radius: float, dashing: bool) -> void:
	if dashing or player == null:
		return
	var min_d := radius + PLAYER_RADIUS
	var delta: Vector2 = player.global_position - centre
	var d := delta.length()
	if d >= min_d:
		return
	if d <= 0.0001:
		player.global_position = centre + Vector2.RIGHT * min_d
		return
	player.global_position = centre + delta * (min_d / d)


func _try_contact(centre: Vector2, radius: float) -> void:
	if player == null or player.health == null:
		return
	var min_d := radius + PLAYER_RADIUS
	if player.global_position.distance_to(centre) <= min_d + 0.5:
		player.health.try_damage(1.0)


func _on_body_hit(damage: float, hit_position: Vector2, _vel: Vector2) -> void:
	var bid := _body_hurt.last_hit_bullet_id if _body_hurt != null else 0
	_hit_body(hit_position, damage, _body_hurt.last_hit_flags if _body_hurt != null else 0, bid)


func _on_gap_hit(damage: float, _hit_position: Vector2, _vel: Vector2) -> void:
	if not _alive or not _aggro:
		return
	var flags := _gap_hurt.last_hit_flags if _gap_hurt != null else 0
	var bid := _gap_hurt.last_hit_bullet_id if _gap_hurt != null else 0
	_apply_core_damage(damage, flags, bid)


func _hit_body(hit_position: Vector2, damage: float, flags: int, bullet_id: int = 0) -> void:
	if not _alive or not _aggro:
		return
	# Gap tick has priority if a sweep somehow delivered the body first while
	# the point is inside the tick circle (should be rare; far-side shots hit
	# the tick first because its outer edge is at 56 vs the body's 48).
	if _in_gap_tick(hit_position):
		_apply_core_damage(damage, flags, bullet_id)
		return
	if ARMOR_ABSORBS:
		return
	_apply_core_damage(damage * BODY_DAMAGE_SCALE, flags, bullet_id)


func _apply_core_damage(amount: float, flags: int, bullet_id: int = 0) -> void:
	if health == null or not _alive:
		return
	# One bullet deals core damage at most once (a piercing shot through the
	# gap tick must not also apply a second ×1 on the body).
	if bullet_id != 0:
		for id in _core_hit_ids:
			if id == bullet_id:
				return
		_core_hit_ids.append(bullet_id)
	if health.try_damage(amount, flags) == Health.DamageResult.APPLIED:
		_register_query()


func _on_core_damaged(_amount: float, _hp: float) -> void:
	_flash_left = HIT_FLASH
	cue.start_brighten()
	queue_redraw()


func _on_hp_changed(_hp: float, _max_hp: float) -> void:
	if _alive:
		_sync_phase()


func _sync_phase() -> void:
	while _phase < PHASE_COUNT:
		var threshold := PHASE_3_HP if _phase + 1 >= 3 else PHASE_2_HP
		if health.hp > threshold:
			break
		_phase += 1
		phase_changed.emit(_phase)
		_shake()
		_notify_hud_phase()
		# Row 9 stub: keep three husks and the Lance; Fan / Broken ring /
		# habituation / a fourth husk land in the next PR.


func _shake() -> void:
	if _camera != null and is_instance_valid(_camera) and _camera.has_method("add_trauma"):
		_camera.add_trauma(PHASE_TRAUMA)


func _on_core_died() -> void:
	if _death_emitted:
		return
	_death_emitted = true
	_alive = false
	_aggro = false
	_lance_winding = false
	_set_hurtboxes_active(false)
	_despawn_husks()
	_clear_own_shots()
	_remove_warp()
	WorldQuery.unregister_enemy(self)
	var pos := global_position
	# SE #92: enemy_killed first, then boss_defeated with id exactly "warden".
	GameEvents.enemy_killed.emit(
		EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, TIER, pos, true
	)
	GameEvents.boss_defeated.emit(
		EnemyKinds.WARDEN, EnemyKinds.RARITY_COMMON, TIER, pos
	)
	_notify_progress()
	# ROW 10 (not this PR): SenseBook.grant, victory card, register_arena_cleared,
	# starter_consumed. Leave them for the ending beat.
	defeated.emit()
	queue_redraw()


func _notify_progress() -> void:
	# SliceProgress is not on main yet (PR #91). When it lands, call
	# notify_warden_defeated if the method exists. Marked hook:
	# SLICE_PROGRESS_HOOK
	var tree := get_tree()
	if tree == null:
		return
	var node := tree.root.find_child("SliceProgress", true, false)
	if node != null and node.has_method("notify_warden_defeated"):
		node.call("notify_warden_defeated")


func _notify_hud_phase() -> void:
	# SliceHud is not on main yet (PR #94). Compatible either merge order:
	# find a node that implements notify_boss_phase_changed, if any.
	var tree := get_tree()
	if tree == null:
		return
	var node := tree.root.find_child("SliceHud", true, false)
	if node != null and node.has_method("notify_boss_phase_changed"):
		node.call("notify_boss_phase_changed")
	for n in tree.get_nodes_in_group(&"slice_hud"):
		if n.has_method("notify_boss_phase_changed"):
			n.call("notify_boss_phase_changed")


func _register_query() -> void:
	if not is_inside_tree() or not _alive:
		return
	WorldQuery.register_enemy(
		self,
		EnemyKinds.WARDEN,
		EnemyKinds.RARITY_COMMON,
		TIER,
		BODY_RADIUS,
		health,
		true,
		_boss_state
	)


func _boss_state() -> Dictionary:
	return {
		"phase": _phase,
		"phase_count": PHASE_COUNT,
		"weak_points": [{
			"pos": gap_point(),
			"radius": GAP_HURT_RADIUS,
			"open": _aggro and _alive,
		}],
	}


func _add_warp() -> void:
	_remove_warp()
	_warp_id = GridWarpFallback.add_chunk(SliceLayout.room_rect(SliceLayout.ROOM_E))


func _remove_warp() -> void:
	if _warp_id > 0:
		GridWarpFallback.remove_chunk(_warp_id)
		_warp_id = 0


func _clear_own_shots() -> void:
	if _bullets != null and is_instance_valid(_bullets):
		_bullets.despawn_owned(Layers.ENEMY)


func _redraw_if_pose_changed() -> void:
	var q := snappedf(_gap_angle, deg_to_rad(1.0))
	var hp := health.hp if health != null else 0.0
	if (
		q == _drawn_gap_q
		and hp == _drawn_hp
		and _phase == _drawn_phase
		and _lance_winding == _drawn_lance
	):
		return
	_drawn_gap_q = q
	_drawn_hp = hp
	_drawn_phase = _phase
	_drawn_lance = _lance_winding
	queue_redraw()


func _in_gap_tick(world_pos: Vector2) -> bool:
	return world_pos.distance_to(gap_point()) <= GAP_HURT_RADIUS


func _in_body(world_pos: Vector2) -> bool:
	return world_pos.distance_to(global_position) <= BODY_RADIUS


func _draw() -> void:
	var fill := Color.WHITE if _flash_left > 0.0 else COLOR_FILL
	if not _alive:
		fill = fill.darkened(0.45)
	draw_circle(Vector2.ZERO, BODY_RADIUS, fill)
	draw_arc(Vector2.ZERO, BODY_RADIUS, 0.0, TAU, 64, COLOR_OUTLINE, OUTLINE_WIDTH, true)
	# Armor ring: a 70° missing arc that tracks facing and never shrinks with HP.
	var half := deg_to_rad(GAP_DEGREES * 0.5)
	var start := _gap_angle + half
	var sweep_end := _gap_angle + TAU - half
	draw_arc(
		Vector2.ZERO, ARMOR_RING_RADIUS, start, sweep_end, 72, COLOR_OUTLINE, 2.5, true
	)
	var tick := Vector2.from_angle(_gap_angle) * GAP_OFFSET
	draw_circle(tick, 3.0, COLOR_TICK)
	if cue.drawing_full:
		cue.draw_on(self, BODY_RADIUS)
	if _lance_winding:
		draw_line(Vector2.ZERO, to_local(_lance_aim), Color(LANCE_COLOR, 0.85), 2.0, true)
	if _tithe_left > 0.0:
		draw_line(to_local(_tithe_from), Vector2.ZERO, Color(COLOR_FILL, 0.9), 2.0, true)
		draw_arc(Vector2.ZERO, BODY_RADIUS + 6.0, 0.0, TAU, 48, Color(COLOR_FILL, 0.7), 3.0, true)
	if _feeds_left > 0.0:
		var font := ThemeDB.fallback_font
		if font != null:
			var msg := "It feeds."
			var size := 14
			var width := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			draw_string(
				font,
				Vector2(-width * 0.5, -BODY_RADIUS - 18.0),
				msg,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				size,
				Color(1, 1, 1, 0.95)
			)
