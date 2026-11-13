class_name EliteEnemy
extends RegularEnemy
## Elite Drifter. The Herald (L2) and a natural T0 elite (L3) are the common
## body: 75 HP, speed 90, wake 700, contact 1, 3 px outline, common cue.
## Room D (vertical-slice row 7) is the rare body: 120 HP, Bulwark + Summoner,
## rare cue, wake also when the player crosses G4.
## Splitting and Summoner come from AffixDef. Halves are not elites: 40% HP,
## ×1.3 speed, radius 12, already awake, no cue, no shard, no further split.
## Summoner adds are SummonAdd bodies, spawned on the flanks of the
## elite-to-player line (issue #81). Per-tier columns on AffixDef: common 2
## one-hit Swarmers, rare 8, legendary (Hydra) 6 Drifters at 105 HP.
## Nothing here fires a bullet. Adds are bodies. Plain shots stay plain.

signal shard_dropped

const GROUP_ELITE := &"elites"
## T0 common: 30 × 1.0 × 2.5.
const ELITE_HP := RegularEnemy.DRIFTER_HP * 1.0 * 2.5
## T0 rare: 30 × 1.0 × 4 (room D).
const RARE_HP := RegularEnemy.DRIFTER_HP * 1.0 * 4.0
const COMMON_SPEED_MUL := 1.0
## Rare Bulwark (spawning §3.4 / vertical-slice §4). Common intensity is 120°
## with no turn cap; this slice only places the rare intensity.
const BULWARK_RARE_ARC := 150.0
const BULWARK_RARE_TURN := 45.0
const BULWARK_ARC_PAD := 8.0
const BULWARK_ARC_ALPHA := 0.4
const HALF_RADIUS := 12.0
## Centre gap so two radius-12 halves do not sit on top of each other.
const HALF_SEPARATION := 32.0
## Same spacing the slice uses for a 1-point escort, so adds clear the body.
## Summons spawn this far out on a flank: ±90° from the elite-to-player line.
const SUMMON_OFFSET := 48.0

var affix := StringName()
## Additional affixes after `affix` (room D is Bulwark + Summoner). Empty for
## the Herald and a natural T0 elite. has_affix() sees both.
var affixes: Array[StringName] = []
## EnemyKinds.RARITY_* (same numbers as AffixDef.RARITY_*). From the
## EncounterSpec for a natural elite (ChunkStream sets it before the body
## enters the tree); configure_elite can also pass it. The Herald is common.
## Halves report RARITY_NONE: they are not elites. Summoner uses the same
## value to pick its per-tier column.
var rarity := EnemyKinds.RARITY_COMMON
var is_herald := false
var is_half := false
var grants_shard := false
## When finite, also wake once the player's x is at or past this line.
## Room D sets it to the G4 gate so the body wakes as the player crosses G4,
## which is farther than WAKE_RADIUS from the room centre.
var wake_x := INF
## When true, the Summoner timer starts on wake and does not tick while
## asleep. Room D sets this so the body does not summon from room S. The
## Herald and natural elites keep the existing (timer-from-spawn) behaviour.
var summon_after_wake := false
var cue: EliteCue
var sting: EliteSting

var _affix_def: AffixDef
var _speed := RegularEnemy.DRIFTER_SPEED
var _death_handled := false
var _summon_wait := 6.0
var _summon_interval := 6.0
var _summon_batch := 2
var _summon_cap := 2
var _summon_hp := 1.0
var _summon_kind := ARCH_SWARMER
var _summon_serial := 0
var _summons: Array[RegularEnemy] = []
var _glyph := EliteCue.GLYPH_CIRCLE


func configure_elite(
	p_affix: StringName,
	p_anchor: Vector2,
	p_spawn: Vector2,
	p_seed: int,
	p_player: Node2D,
	p_herald: bool,
	p_half: bool = false,
	p_chunk: Vector2i = Vector2i.ZERO,
	p_encounter: int = -1,
	p_rarity: int = AffixDef.RARITY_COMMON,
	p_extra_affixes: Array[StringName] = [],
) -> void:
	rarity = p_rarity
	is_herald = p_herald
	is_half = p_half
	# The Herald and a natural elite both drop one shard. A half does not.
	# Encounter index -1 is the Herald (and halves): no chunk bit. L3 passes
	# the real chunk and index so the kill mask can name the encounter.
	# Room D sets grants_shard = false after configure: SliceRoomD adds 3,
	# and must not also emit shard_dropped.
	grants_shard = not p_half
	# Halves keep the def (HP fraction, speed) but not the affix, so they cannot split.
	affixes = []
	if not p_half:
		if p_affix != StringName():
			affixes.append(p_affix)
		for extra in p_extra_affixes:
			if extra != StringName() and not affixes.has(extra):
				affixes.append(extra)
	affix = affixes[0] if not affixes.is_empty() else StringName()
	_affix_def = null
	for id in affixes:
		var def := _load_affix(id)
		if def == null:
			continue
		# Prefer Summoner / Splitting for the column and half stats.
		if _affix_def == null or id == AffixCatalog.SUMMONER or id == AffixCatalog.SPLITTING:
			_affix_def = def
	if has_affix(AffixCatalog.BULWARK):
		_glyph = EliteCue.glyph_kind(AffixDef.GROUP_DEFENSIVE)
	elif _affix_def != null:
		_glyph = EliteCue.glyph_kind(_affix_def.group)
	var chunk_pos := WorldGen.chunk_of(p_spawn)
	if p_encounter >= 0:
		chunk_pos = p_chunk
	configure(
		ARCH_DRIFTER,
		p_anchor,
		p_spawn,
		p_seed,
		chunk_pos,
		p_encounter,
		0,
		p_player,
	)


func has_affix(id: StringName) -> bool:
	return affix == id or affixes.has(id)


func enemy_rarity() -> int:
	return EnemyKinds.RARITY_NONE if is_half else rarity


func _load_affix(id: StringName) -> AffixDef:
	if id == StringName() or id == AffixCatalog.BULWARK:
		return null
	return AffixCatalog.get_affix(id)


func body_hp() -> float:
	if rarity == EnemyKinds.RARITY_RARE:
		return RARE_HP
	return ELITE_HP


func summon_alive() -> int:
	var kept: Array[RegularEnemy] = []
	for body: RegularEnemy in _summons:
		if is_instance_valid(body) and body.is_alive():
			kept.append(body)
	_summons = kept
	return kept.size()


func _ready() -> void:
	# RegularEnemy._ready sets collide_walls from the shared helper when an
	# enabled ribbon is in the tree.
	super._ready()
	if is_half:
		woken = true
		return
	add_to_group(GROUP_ELITE)
	cue = EliteCue.new()
	if rarity == EnemyKinds.RARITY_RARE:
		cue.setup(RarityCue.TIER_ELITE_RARE)
	elif rarity == EnemyKinds.RARITY_LEGENDARY:
		cue.setup(RarityCue.TIER_ELITE_LEGENDARY)
	cue.glyph = _glyph
	cue.try_acquire()
	cue.attach(self)
	sting = EliteSting.new()
	sting.name = "EliteSting"
	add_child(sting)


func _exit_tree() -> void:
	super._exit_tree()
	if cue != null:
		cue.release()
		cue = null


func _physics_process(delta: float) -> void:
	var was_woken := woken
	if _alive and player != null and is_instance_valid(player) and not woken:
		if is_finite(wake_x) and player.global_position.x >= wake_x:
			woken = true
	if _alive and player != null and is_instance_valid(player) and has_affix(AffixCatalog.BULWARK) and _hurtbox != null:
		var turn := BULWARK_RARE_TURN if rarity == EnemyKinds.RARITY_RARE else 0.0
		_hurtbox.face(player.global_position, turn, delta)
	super._physics_process(delta)
	if not _alive:
		return
	if cue != null:
		cue.advance(delta)
	if woken and not was_woken:
		_on_woke()
	var can_summon := not is_half and has_affix(AffixCatalog.SUMMONER)
	if can_summon and (woken or not summon_after_wake):
		_tick_summon(delta)
	queue_redraw()


func _move_speed() -> float:
	return _speed


func _apply_stats() -> void:
	super._apply_stats()
	if is_half:
		var fraction := 0.4
		var mul := 1.3
		if _affix_def != null:
			fraction = _affix_def.hp_fraction
			mul = _affix_def.speed_mul
		body_radius = HALF_RADIUS
		_speed = RegularEnemy.DRIFTER_SPEED * mul
		_fill = DRIFTER_FILL
		health.max_hp = ELITE_HP * fraction
		health.hp = health.max_hp
		health.invulnerability_time = 0.0
		health.regen_enabled = false
		_hurtbox.radius = body_radius
		_hurtbox.layer = Layers.ENEMY
		_hurtbox.active = true
		return
	_speed = RegularEnemy.DRIFTER_SPEED * COMMON_SPEED_MUL
	health.max_hp = body_hp()
	health.hp = health.max_hp
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	_hurtbox.radius = body_radius
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.active = true
	if has_affix(AffixCatalog.BULWARK):
		_hurtbox.response = Hurtbox.Response.ABSORB
		_hurtbox.arc_deg = BULWARK_RARE_ARC if rarity == EnemyKinds.RARITY_RARE else 120.0
		# Face the room-D entrance (west) until the player arrives.
		_hurtbox.facing = PI
	if has_affix(AffixCatalog.SUMMONER):
		var def := _affix_def if _affix_def != null else AffixCatalog.get_affix(AffixCatalog.SUMMONER)
		if def != null:
			_summon_interval = def.summon_interval(rarity)
			_summon_batch = def.summon_count(rarity)
			_summon_cap = def.summon_cap(rarity)
			_summon_hp = def.summon_hp_for(rarity)
			_summon_kind = def.summon_kind(rarity)
			_summon_wait = _summon_interval


## Living summons this elite may have at once (its tier's column).
func summon_cap() -> int:
	return _summon_cap


## Seconds between two summon waves (its tier's column).
func summon_interval() -> float:
	return _summon_interval


func _on_died() -> void:
	if _death_handled:
		return
	_death_handled = true
	if not is_half and has_affix(AffixCatalog.SPLITTING):
		_spawn_halves()
	if grants_shard:
		shard_dropped.emit()
	super._on_died()


func _on_woke() -> void:
	if is_half:
		return
	if summon_after_wake and has_affix(AffixCatalog.SUMMONER):
		_summon_wait = _summon_interval
	if cue != null:
		cue.start_brighten()
	if sting != null:
		sting.play_sting()


func outline_width() -> float:
	if is_half or cue == null:
		return OUTLINE_WIDTH if is_half else EliteCue.OUTLINE_WIDTH
	return cue.current_outline_width()


func _draw() -> void:
	draw_circle(Vector2.ZERO, body_radius, _fill.lerp(Color.WHITE, _flash))
	var ocolor := OUTLINE_COLOR
	if cue != null:
		ocolor = cue.outline_color()
	draw_arc(Vector2.ZERO, body_radius, 0.0, TAU, ARC_POINTS, ocolor, outline_width(), true)
	if cue != null:
		cue.draw_on(self, body_radius)
	if has_affix(AffixCatalog.BULWARK) and _hurtbox != null:
		var half := deg_to_rad(_hurtbox.arc_deg * 0.5)
		var col := Color(_fill, BULWARK_ARC_ALPHA)
		draw_arc(Vector2.ZERO, body_radius + BULWARK_ARC_PAD, _hurtbox.facing - half, _hurtbox.facing + half, 32, col, 3.0, true)


func _tick_summon(delta: float) -> void:
	if delta > 0.0:
		_summon_wait -= delta
	if _summon_wait > 0.0:
		return
	# One batch per tick. A huge delta does not dump several waves at once.
	_summon_wait = _summon_interval
	var room := _summon_cap - summon_alive()
	var n := mini(_summon_batch, maxi(room, 0))
	for _i in n:
		_spawn_one_summon()


func _spawn_one_summon() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var packed := load("res://scenes/summon_add.tscn") as PackedScene
	if packed == null:
		return
	var body := packed.instantiate() as SummonAdd
	if body == null:
		return
	# Alternate flanks: even serials left of the elite-to-player line, odd right.
	var side := 1.0 if _summon_serial % 2 == 0 else -1.0
	var pos := RegularEnemy.push_centre_outside(
		summon_spawn_point(side), RegularEnemy.radius_of(_summon_kind)
	)
	body.name = "HeraldSummon%d" % _summon_serial
	body.summoner = self
	body.side = side
	body.summon_hp = _summon_hp
	# Swarmer adds hold their flank; legendary (Hydra) Drifter adds chase as
	# plain Drifters (vertical-slice §4).
	body.holds_flank = _summon_kind == ARCH_SWARMER
	body.configure(_summon_kind, pos, pos, world_seed, chunk, -1, _summon_serial, player)
	body.woken = woken
	_summon_serial += 1
	parent.add_child(body)
	_summons.append(body)


## Where a summon on `side` (+1 left, -1 right of the elite-to-player line)
## appears: SUMMON_OFFSET px out at ±90°, never between the elite and the
## player. With no player the heading stands in for the line.
func summon_spawn_point(side: float) -> Vector2:
	var lane := _heading
	if player != null:
		var to_player := player.global_position - global_position
		if to_player.length_squared() > 0.000001:
			lane = to_player
	if lane.length_squared() <= 0.000001:
		lane = Vector2.RIGHT
	lane = lane.normalized()
	var normal := Vector2(-lane.y, lane.x)
	return global_position + normal * side * SUMMON_OFFSET


func _spawn_halves() -> void:
	if is_half:
		return
	var n := 2
	if _affix_def != null:
		n = maxi(_affix_def.halves, 0)
	var parent := get_parent()
	if parent == null or n <= 0:
		return
	var packed := load("res://scenes/elite_enemy.tscn") as PackedScene
	if packed == null:
		return
	var perp := Vector2(-_heading.y, _heading.x)
	if perp.length_squared() <= 0.000001:
		perp = Vector2.UP
	else:
		perp = perp.normalized()
	for i in n:
		var side := -1.0 if i % 2 == 0 else 1.0
		var along := float(i / 2)
		var offset := perp * side * HALF_SEPARATION + _heading * along * 18.0
		var pos := RegularEnemy.push_centre_outside(global_position + offset, HALF_RADIUS)
		var half := packed.instantiate() as EliteEnemy
		if half == null:
			continue
		half.name = "HeraldHalf%d" % i
		half.configure_elite(AffixCatalog.SPLITTING, pos, pos, world_seed, player, false, true)
		half.woken = true
		parent.add_child(half)
