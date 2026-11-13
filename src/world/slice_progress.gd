class_name SliceProgress
extends Node
## Vertical-slice lesson flags and the gates they open (vertical-slice.md §2, §7,
## §10 row 5). Checkers read the world (HP, hits, aim, fire held); they do not
## parse Lua. Death does not clear flags or close gates.
##
## Real checkers run for lessons 1 and 2 (the three origin TrainingDummies).
## Lessons 3–5, the four room-C packs, the room-D rare elite, and the Warden
## are not built in this row: later rows call the hooks below, and tests or a
## session can use the debug overrides.
##
##   - complete_lesson(3) opens G2 (room A shielded dummy, row 4).
##   - complete_lesson(4) and complete_lesson(5) together open G3 (pad / plate, row 4).
##   - notify_pack_cleared(0..3) opens G4 once all four packs are marked (row 2).
##   - notify_room_d_elite_died() opens G5 (row 7).
##   - notify_warden_defeated() opens G0 and sets the arena respawn (row 8 / 10).
##
## HUD row 11 can bind to the signals on this node.

## Lesson id (1–5) that just flipped from incomplete to complete.
signal lesson_completed(id: int)
## Gate that this node just opened on the bound SliceLayout (G0–G5).
signal gate_opened(id: StringName)
## Forwarded from the bound player's Health whenever hp changes.
signal hp_changed(hp: float, max_hp: float)
## Forwarded from the bound player, once per death.
signal died
## Forwarded after the bound player respawns, with the respawn position.
signal respawned(at: Vector2)

const LESSON_COUNT := 5
const PACK_COUNT := 4
## Seconds the east dummy must die within, counted from the current fire hold.
const LESSON_1_WINDOW := 4.0
## Seconds in which the north and south dummies must each take damage.
const LESSON_2_WINDOW := 3.0
## Max |angle_difference| between ctx.aim at window start and during the window.
const LESSON_2_AIM_TOLERANCE := 0.4

const EAST_DUMMY := Vector2(300, 0)
const NORTH_DUMMY := Vector2(-150, 260)
const SOUTH_DUMMY := Vector2(-150, -260)
const DUMMY_MATCH_PX := 8.0

## Bit 0 = lesson 1. Applied in bind() (OR'd into the loaded flags).
@export var debug_lessons := 0
## Bit 0 = G0, bit 1 = G1, … bit 5 = G5. Applied in bind().
@export var debug_gates := 0

var _lessons := 0
var _gates := 0
var _packs := 0
var _player: Player
var _layout: SliceLayout
var _save: SaveGame
var _dummies: Node

var _fire_override := false
var _fire_held := false
var _fire_held_time := 0.0

var _l2_active := false
var _l2_time := 0.0
var _l2_aim := 0.0
var _l2_north_hit := false
var _l2_south_hit := false
var _l2_window_passed := false
## Bits: 0 = east, 1 = north, 2 = south, set on that dummy's first_death.
var _first_deaths := 0

var _regen_suppressed := false
var _bound := false
var _health_connected := false


func _physics_process(delta: float) -> void:
	tick(delta)


## Deterministic step for tests. Updates the fire hold, the lesson 2 aim window,
## room-B regen suppression, and retries a delayed lesson 2 grant.
func tick(delta: float) -> void:
	if not is_finite(delta) or delta < 0.0:
		return
	_update_fire(delta)
	_tick_lesson_2(delta)
	_update_room_b_regen()
	_try_pass_lesson_2()


## Wires the player, the origin dummy group, the ribbon, and an optional save.
## Safe to call more than once; previous signal connections are dropped first.
func bind(player: Player, dummies: Node, layout: SliceLayout, save: SaveGame = null) -> void:
	_unbind()
	_player = player
	_dummies = dummies
	_layout = layout
	_save = save
	_bound = true
	_load_from_save()
	if debug_lessons != 0:
		_lessons |= debug_lessons & _lesson_mask_all()
	if debug_gates != 0:
		_gates |= debug_gates & _gate_mask_all()
	_connect_player()
	_connect_dummies()
	_sync_layout_gates()
	_restore_warden_respawn()
	_try_open_gates()
	_persist()
	if _player != null and _player.health != null:
		hp_changed.emit(_player.health.hp, _player.health.max_hp)


func lessons_mask() -> int:
	return _lessons


func gates_mask() -> int:
	return _gates


func packs_mask() -> int:
	return _packs


func is_lesson_done(id: int) -> bool:
	var bit := _lesson_bit(id)
	return bit >= 0 and (_lessons & (1 << bit)) != 0


func is_gate_unlocked(id: StringName) -> bool:
	var bit := _gate_bit(id)
	return bit >= 0 and (_gates & (1 << bit)) != 0


## Where the player should come back: the arena centre if the Warden is already
## dead (G0 open), otherwise RespawnPoints. Chosen at respawn time so a trade
## kill during the 1.5 s window still lands in the arena.
func respawn_position() -> Vector2:
	if is_gate_unlocked(SliceLayout.GATE_G0):
		return SliceLayout.ARENA_CENTRE
	return RespawnPoints.get_respawn_position()


## Room-C pack absent-since, forwarded to the bound save. 0 if there is no save
## or the pack is present. Row 2 wires the packs; this is just the slot API.
func field_absent_since(key: StringName) -> float:
	return _save.field_absent_since(key) if _save != null else 0.0


func set_field_absent_since(key: StringName, unix: float) -> void:
	if _save == null:
		return
	_save.set_field_absent_since(key, unix)
	_save.save()


func field_pack_is_present(key: StringName, now_unix: float = -1.0) -> bool:
	if _save == null:
		return true
	return _save.field_pack_is_present(key, now_unix)


## Marks lesson `id` (1–5) complete. Idempotent. Opens any gate whose
## requirements are now met. This is the hook later rows call for lessons 3–5.
func complete_lesson(id: int) -> bool:
	if not _set_lesson(id):
		return false
	_try_open_gates()
	_persist()
	return true


## Marks scripted pack `pack_index` (0–3) cleared. G4 opens when all four are.
## Hook for row 2; the packs themselves are not spawned here.
func notify_pack_cleared(pack_index: int) -> void:
	if pack_index < 0 or pack_index >= PACK_COUNT:
		push_warning("SliceProgress.notify_pack_cleared(): pack %d out of range" % pack_index)
		return
	var bit := 1 << pack_index
	if (_packs & bit) != 0:
		return
	_packs |= bit
	_try_open_gates()
	_persist()


## Hook for row 7: the room D rare elite's body died (not its summons).
func notify_room_d_elite_died() -> void:
	_unlock_gate(SliceLayout.GATE_G5)


## Hook for row 8 / 10: the Warden died. Opens G0 and records the arena as
## the respawn point. Main chooses the point when the respawn timer fires, so
## a trade kill during the 1.5 s window still comes back at the arena centre.
func notify_warden_defeated() -> void:
	var already := is_gate_unlocked(SliceLayout.GATE_G0)
	_unlock_gate(SliceLayout.GATE_G0)
	if not already:
		RespawnPoints.register_arena_cleared(SliceLayout.ARENA_CENTRE)


## Test / debug: treat the fire button as held for `held_time` seconds (or not
## held). Stops reading Input until bind() is called again.
func debug_set_fire(held: bool, held_time: float = 0.0) -> void:
	_fire_override = true
	_fire_held = held
	_fire_held_time = maxf(held_time, 0.0)


## Test / debug: complete lesson `id` (same as complete_lesson).
func debug_complete_lesson(id: int) -> bool:
	return complete_lesson(id)


## Test / debug: force a gate open and persist it, skipping its lesson / pack
## requirements. Unknown ids are ignored.
func debug_open_gate(id: StringName) -> void:
	_unlock_gate(id)


func _exit_tree() -> void:
	_unbind()


func _unbind() -> void:
	if _player != null and is_instance_valid(_player):
		if _player.died.is_connected(_on_player_died):
			_player.died.disconnect(_on_player_died)
		if _player.respawned.is_connected(_on_player_respawned):
			_player.respawned.disconnect(_on_player_respawned)
		if _health_connected and _player.health != null:
			if _player.health.hp_changed.is_connected(_on_hp_changed):
				_player.health.hp_changed.disconnect(_on_hp_changed)
	if _dummies != null and is_instance_valid(_dummies):
		for child in _dummies.get_children():
			var dummy := child as TrainingDummy
			if dummy == null:
				continue
			var box := dummy.get_node_or_null("Hurtbox") as Hurtbox
			if box != null:
				_disconnect_owned(box.hit)
			_disconnect_owned(dummy.destroyed)
	if GameEvents.enemy_killed.is_connected(_on_enemy_killed):
		GameEvents.enemy_killed.disconnect(_on_enemy_killed)
	if _regen_suppressed and _player != null and is_instance_valid(_player) and _player.health != null:
		_player.health.regen_enabled = true
	_regen_suppressed = false
	_health_connected = false
	_bound = false
	_player = null
	_dummies = null
	_layout = null
	_save = null


func _connect_player() -> void:
	if _player == null:
		return
	if not _player.died.is_connected(_on_player_died):
		_player.died.connect(_on_player_died)
	if not _player.respawned.is_connected(_on_player_respawned):
		_player.respawned.connect(_on_player_respawned)
	if _player.health != null and not _player.health.hp_changed.is_connected(_on_hp_changed):
		_player.health.hp_changed.connect(_on_hp_changed)
		_health_connected = true


func _disconnect_owned(sig: Signal) -> void:
	for sc: Dictionary in sig.get_connections():
		var cb: Callable = sc.callable
		if cb.get_object() == self:
			sig.disconnect(cb)


func _connect_dummies() -> void:
	if _dummies == null:
		return
	for child in _dummies.get_children():
		var dummy := child as TrainingDummy
		if dummy == null or _role_of(dummy) == &"":
			continue
		var box := dummy.get_node_or_null("Hurtbox") as Hurtbox
		if box != null:
			_disconnect_owned(box.hit)
			box.hit.connect(_on_hurtbox_hit.bind(dummy))
		_disconnect_owned(dummy.destroyed)
		dummy.destroyed.connect(_on_dummy_destroyed.bind(dummy))
	if not GameEvents.enemy_killed.is_connected(_on_enemy_killed):
		GameEvents.enemy_killed.connect(_on_enemy_killed)


func _update_fire(delta: float) -> void:
	if _fire_override:
		return
	var held := false
	if _player != null and is_instance_valid(_player) and not _player.input_blocked:
		held = Input.is_action_pressed("fire")
	if held:
		if _fire_held:
			_fire_held_time += delta
		else:
			_fire_held = true
			_fire_held_time = 0.0
	else:
		_fire_held = false
		_fire_held_time = 0.0


func _tick_lesson_2(delta: float) -> void:
	if not _l2_active or _l2_window_passed:
		return
	if _aim_broke():
		_reset_l2_window()
		return
	_l2_time += delta
	if _l2_north_hit and _l2_south_hit:
		_l2_window_passed = true
		_l2_active = false
		return
	if _l2_time > LESSON_2_WINDOW:
		_reset_l2_window()


func _aim_broke() -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	return absf(angle_difference(_player.aim_direction.angle(), _l2_aim)) > LESSON_2_AIM_TOLERANCE


func _reset_l2_window() -> void:
	_l2_active = false
	_l2_time = 0.0
	_l2_north_hit = false
	_l2_south_hit = false


func _on_hurtbox_hit(amount: float, _hit_position: Vector2, _bullet_velocity: Vector2, dummy: TrainingDummy = null) -> void:
	var role := _role_of(dummy) if dummy != null else &""
	if role == &"":
		role = _nearest_role(_hit_position)
	_on_dummy_damaged(role, amount)


func _on_dummy_destroyed(dummy: TrainingDummy) -> void:
	if dummy == null:
		return
	var role := _role_of(dummy)
	if role == &"":
		return
	_on_dummy_died(role, dummy.deaths == 1)


func _on_enemy_killed(kind: StringName, _rarity: int, _tier: int, pos: Vector2, first_death: bool) -> void:
	if kind != EnemyKinds.DUMMY:
		return
	var role := _role_at(pos)
	if role == &"":
		return
	if first_death:
		_mark_first_death(role)
	if role == &"east":
		_try_pass_lesson_1()
	_try_pass_lesson_2()


func _on_dummy_damaged(role: StringName, amount: float) -> void:
	if role == &"" or amount <= 0.0 or is_lesson_done(2):
		return
	if role != &"north" and role != &"south":
		return
	if not _l2_window_passed:
		if not _l2_active:
			_l2_active = true
			_l2_time = 0.0
			_l2_aim = _player.aim_direction.angle() if _player != null and is_instance_valid(_player) else 0.0
			_l2_north_hit = false
			_l2_south_hit = false
		if _aim_broke():
			_reset_l2_window()
			return
		if role == &"north":
			_l2_north_hit = true
		else:
			_l2_south_hit = true
		if _l2_north_hit and _l2_south_hit:
			_l2_window_passed = true
			_l2_active = false
	_try_pass_lesson_2()


func _on_dummy_died(role: StringName, first_death: bool) -> void:
	if first_death:
		_mark_first_death(role)
	if role == &"east":
		_try_pass_lesson_1()
	_try_pass_lesson_2()


## Public so tests can drive the checkers without a bullet hit.
func notify_dummy_damaged(role: StringName, amount: float) -> void:
	_on_dummy_damaged(role, amount)


func notify_dummy_died(role: StringName, first_death: bool) -> void:
	_on_dummy_died(role, first_death)


func _try_pass_lesson_1() -> void:
	if is_lesson_done(1):
		return
	if not _fire_held or _fire_held_time > LESSON_1_WINDOW:
		return
	complete_lesson(1)


func _try_pass_lesson_2() -> void:
	if is_lesson_done(2):
		return
	if not _l2_window_passed:
		return
	if _first_deaths != 0b111:
		return
	complete_lesson(2)


func _mark_first_death(role: StringName) -> void:
	var bit := 0
	match role:
		&"east":
			bit = 1 << 0
		&"north":
			bit = 1 << 1
		&"south":
			bit = 1 << 2
		_:
			return
	_first_deaths |= bit


func _update_room_b_regen() -> void:
	if _player == null or not is_instance_valid(_player) or _player.health == null:
		return
	var in_b := SliceLayout.room_rect(SliceLayout.ROOM_B).has_point(_player.global_position)
	if in_b and not _regen_suppressed:
		_player.health.regen_enabled = false
		_regen_suppressed = true
	elif not in_b and _regen_suppressed:
		_player.health.regen_enabled = true
		_regen_suppressed = false


func _set_lesson(id: int) -> bool:
	var bit := _lesson_bit(id)
	if bit < 0:
		push_warning("SliceProgress.complete_lesson(): lesson %d out of range" % id)
		return false
	var mask := 1 << bit
	if (_lessons & mask) != 0:
		return false
	_lessons |= mask
	lesson_completed.emit(id)
	return true


func _try_open_gates() -> void:
	if is_lesson_done(1) and is_lesson_done(2):
		_unlock_gate(SliceLayout.GATE_G1)
	if is_lesson_done(3):
		_unlock_gate(SliceLayout.GATE_G2)
	if is_lesson_done(4) and is_lesson_done(5):
		_unlock_gate(SliceLayout.GATE_G3)
	if _packs == (1 << PACK_COUNT) - 1:
		_unlock_gate(SliceLayout.GATE_G4)


func _unlock_gate(id: StringName) -> void:
	var bit := _gate_bit(id)
	if bit < 0:
		push_warning("SliceProgress: unknown gate %s" % id)
		return
	var mask := 1 << bit
	var newly := (_gates & mask) == 0
	_gates |= mask
	if _layout != null and not _layout.gate_flag(id):
		_layout.open_gate(id)
	if newly:
		gate_opened.emit(id)
		_persist()


## A loaded slot that already has G0 open must respawn in the arena, even
## though notify_warden_defeated() will not run again this session.
func _restore_warden_respawn() -> void:
	if is_gate_unlocked(SliceLayout.GATE_G0):
		RespawnPoints.register_arena_cleared(SliceLayout.ARENA_CENTRE)


func _sync_layout_gates() -> void:
	if _layout == null:
		return
	for id: StringName in SliceLayout.GATE_IDS:
		if is_gate_unlocked(id):
			_layout.open_gate(id)


func _load_from_save() -> void:
	if _save == null:
		return
	_lessons = _save.slice_lessons & _lesson_mask_all()
	_gates = _save.slice_gates & _gate_mask_all()
	_packs = _save.slice_packs & ((1 << PACK_COUNT) - 1)


func _persist() -> void:
	if _save == null:
		return
	_save.slice_lessons = _lessons
	_save.slice_gates = _gates
	_save.slice_packs = _packs
	_save.save()


func _on_hp_changed(hp: float, max_hp: float) -> void:
	hp_changed.emit(hp, max_hp)


func _on_player_died() -> void:
	died.emit()


func _on_player_respawned(at: Vector2) -> void:
	respawned.emit(at)
	# Death must not clear flags; re-apply open gates in case a debug close happened.
	_sync_layout_gates()


func _role_of(dummy: TrainingDummy) -> StringName:
	return _role_at(dummy.global_position)


func _role_at(pos: Vector2) -> StringName:
	if pos.distance_to(EAST_DUMMY) <= DUMMY_MATCH_PX:
		return &"east"
	if pos.distance_to(NORTH_DUMMY) <= DUMMY_MATCH_PX:
		return &"north"
	if pos.distance_to(SOUTH_DUMMY) <= DUMMY_MATCH_PX:
		return &"south"
	return &""


func _nearest_role(pos: Vector2) -> StringName:
	var best := &""
	var best_d := DUMMY_MATCH_PX
	var anchors: Array[Vector2] = [EAST_DUMMY, NORTH_DUMMY, SOUTH_DUMMY]
	var roles: Array[StringName] = [&"east", &"north", &"south"]
	for i in range(anchors.size()):
		var d := pos.distance_to(anchors[i])
		if d <= best_d:
			best_d = d
			best = roles[i]
	return best


func _lesson_bit(id: int) -> int:
	if id < 1 or id > LESSON_COUNT:
		return -1
	return id - 1


func _gate_bit(id: StringName) -> int:
	return SliceLayout.GATE_IDS.find(id)


func _lesson_mask_all() -> int:
	return (1 << LESSON_COUNT) - 1


func _gate_mask_all() -> int:
	return (1 << SliceLayout.GATE_IDS.size()) - 1
