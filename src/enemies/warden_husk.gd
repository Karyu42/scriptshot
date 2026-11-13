class_name WardenHusk
extends Node2D
## Orbiting Warden add (docs/design/vertical-slice.md §5). Kind "husk", 40 HP,
## radius 16, contact 1, no shot, no rarity cue. The core drives orbit and
## respawn.

const RADIUS := 16.0
const MAX_HP := 40.0
const COLOR_FILL := Color("9BB6E0")
const COLOR_OUTLINE := Color("E7E9EE")
const OUTLINE_WIDTH := 2.0
const HIT_FLASH := 0.12

var health: Health
var _hurtbox: Hurtbox
var _core: Warden
var _slot := 0
var _alive := true
var _flash_left := 0.0
var _fade_left := 0.0
var _fade_total := 0.0
## Current angle on the orbit circle, driven by the core.
var orbit_angle := 0.0
## Phase-2 Phasing affix: absorb hits unless the pulse is open.
var phasing := false
var phase_open := false
## True only for this body's first death this fight. Respawned husks stay false.
var _first_death := true


func setup(core: Warden, slot: int, first_death: bool = true) -> void:
	_core = core
	_slot = slot
	_first_death = first_death
	z_index = 3


func _ready() -> void:
	health = Health.new()
	health.name = "Health"
	health.set_max_hp(MAX_HP)
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	health.reset()
	health.died.connect(_on_died)
	health.damaged.connect(_on_damaged)
	add_child(health)
	_hurtbox = Hurtbox.new()
	_hurtbox.name = "Hurtbox"
	_hurtbox.radius = RADIUS
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.active = true
	_hurtbox.hit.connect(_on_hit)
	add_child(_hurtbox)
	WorldQuery.register_enemy(
		self, EnemyKinds.HUSK, EnemyKinds.RARITY_NONE, 0, RADIUS, health
	)
	queue_redraw()


func _exit_tree() -> void:
	WorldQuery.unregister_enemy(self)


func _physics_process(delta: float) -> void:
	if _fade_left > 0.0:
		_fade_left = maxf(_fade_left - delta, 0.0)
		modulate.a = _fade_left / _fade_total if _fade_total > 0.0 else 0.0
		queue_redraw()
		if _fade_left <= 0.0:
			queue_free()
		return
	if _flash_left > 0.0:
		_flash_left = maxf(_flash_left - delta, 0.0)
		queue_redraw()


func is_alive() -> bool:
	return _alive


func slot() -> int:
	return _slot


func despawn() -> void:
	_alive = false
	if _hurtbox != null:
		_hurtbox.active = false
	WorldQuery.unregister_enemy(self)
	queue_free()


## Phase-change despawn (GD #97): 0.3 s fade, no white flash, no tithe, no
## heal line. Combat ends immediately; the node frees when the fade finishes.
func fade_out(duration: float) -> void:
	_alive = false
	_flash_left = 0.0
	set_phasing(false, false)
	if _hurtbox != null:
		_hurtbox.active = false
	WorldQuery.unregister_enemy(self)
	# Do not notify the core: no tithe, no "It feeds." line.
	if duration <= 0.0:
		queue_free()
		return
	_fade_total = duration
	_fade_left = duration
	modulate.a = 1.0
	queue_redraw()


func is_fading() -> bool:
	return _fade_left > 0.0


func set_phasing(active: bool, open: bool) -> void:
	var changed := phasing != active or phase_open != open
	phasing = active
	phase_open = open
	if changed:
		queue_redraw()


func _on_hit(damage: float, _hit_position: Vector2, _vel: Vector2) -> void:
	if not _alive or health == null:
		return
	# Absorb except during the 0.4 s pulse.
	if phasing and not phase_open:
		return
	health.try_damage(damage, _hurtbox.last_hit_flags if _hurtbox != null else 0)


func _on_damaged(_amount: float, _hp: float) -> void:
	_flash_left = HIT_FLASH
	queue_redraw()


func _on_died() -> void:
	if not _alive:
		return
	_alive = false
	if _hurtbox != null:
		_hurtbox.active = false
	WorldQuery.unregister_enemy(self)
	var pos := global_position
	GameEvents.enemy_killed.emit(
		EnemyKinds.HUSK, EnemyKinds.RARITY_NONE, 0, pos, _first_death
	)
	_first_death = false
	if _core != null and is_instance_valid(_core):
		_core.notify_husk_died(_slot, pos)
	queue_free()


func _draw() -> void:
	var fill := Color.WHITE if _flash_left > 0.0 else COLOR_FILL
	draw_circle(Vector2.ZERO, RADIUS, fill)
	var outline := Color.WHITE if phasing and phase_open else COLOR_OUTLINE
	var width := OUTLINE_WIDTH + (1.5 if phasing and phase_open else 0.0)
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 32, outline, width, true)
