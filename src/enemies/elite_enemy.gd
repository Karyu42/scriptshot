class_name EliteEnemy
extends RegularEnemy
## Common elite Drifter. The Herald (L2) and a natural T0 elite (L3) are this
## body. 75 HP, speed 90, wake 700, contact 1, 3 px outline, common cue.
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
const COMMON_SPEED_MUL := 1.0
const HALF_RADIUS := 12.0
## Centre gap so two radius-12 halves do not sit on top of each other.
const HALF_SEPARATION := 32.0
## Same spacing the slice uses for a 1-point escort, so adds clear the body.
## Summons spawn this far out on a flank: ±90° from the elite-to-player line,
## jittered across SUMMON_FLANK_ARC so a later wave does not stack on the
## same two points (vertical-slice §4 / §10 row 12).
const SUMMON_OFFSET := 48.0
## Total width of the flank arc, centred on ±90°. Each spawn is a deterministic
## hash_u roll in ± half of this, so tests can recompute the offset from the
## elite's world_seed, chunk, encounter_index, and summon serial.
const SUMMON_FLANK_ARC := deg_to_rad(40.0)

var affix := StringName()
## EnemyKinds.RARITY_* (same numbers as AffixDef.RARITY_*). From the
## EncounterSpec for a natural elite (ChunkStream sets it before the body
## enters the tree); configure_elite can also pass it. The Herald is common.
## Halves report RARITY_NONE: they are not elites. Summoner uses the same
## value to pick its per-tier column.
var rarity := EnemyKinds.RARITY_COMMON
var is_herald := false
var is_half := false
var grants_shard := false
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
) -> void:
	rarity = p_rarity
	is_herald = p_herald
	is_half = p_half
	# The Herald and a natural elite both drop one shard. A half does not.
	# Encounter index -1 is the Herald (and halves): no chunk bit. L3 passes
	# the real chunk and index so the kill mask can name the encounter.
	grants_shard = not p_half
	# Halves keep the def (HP fraction, speed) but not the affix, so they cannot split.
	affix = StringName() if p_half else p_affix
	if p_affix != StringName():
		_affix_def = AffixCatalog.get_affix(p_affix)
	if _affix_def != null:
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


func enemy_rarity() -> int:
	return EnemyKinds.RARITY_NONE if is_half else rarity


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
	super._physics_process(delta)
	if not _alive:
		return
	if cue != null:
		cue.advance(delta)
	if woken and not was_woken:
		_on_woke()
	if not is_half and affix == AffixCatalog.SUMMONER:
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
	health.max_hp = ELITE_HP
	health.hp = health.max_hp
	health.invulnerability_time = 0.0
	health.regen_enabled = false
	_hurtbox.radius = body_radius
	_hurtbox.layer = Layers.ENEMY
	_hurtbox.active = true
	if _affix_def != null and affix == AffixCatalog.SUMMONER:
		_summon_interval = _affix_def.summon_interval(rarity)
		_summon_batch = _affix_def.summon_count(rarity)
		_summon_cap = _affix_def.summon_cap(rarity)
		_summon_hp = _affix_def.summon_hp_for(rarity)
		_summon_kind = _affix_def.summon_kind(rarity)
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
	if not is_half and affix == AffixCatalog.SPLITTING:
		_spawn_halves()
	if grants_shard:
		shard_dropped.emit()
	super._on_died()


func _on_woke() -> void:
	if is_half:
		return
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
	var jitter := summon_flank_jitter(_summon_serial)
	var slid := summon_spawn_point(side, jitter)
	var pos := RegularEnemy.push_centre_outside(
		slid,
		RegularEnemy.radius_of(_summon_kind)
	)
	body.name = "HeraldSummon%d" % _summon_serial
	body.summoner = self
	body.side = side
	body.summon_hp = _summon_hp
	# Hold at this add's own spawn offset (hashed angle + wall-slide radius).
	body.flank_jitter = jitter
	body.flank_hold_radius = slid.distance_to(global_position)
	# Swarmer adds hold their flank; legendary (Hydra) Drifter adds chase as
	# plain Drifters (vertical-slice §4).
	body.holds_flank = _summon_kind == ARCH_SWARMER
	body.configure(_summon_kind, pos, pos, world_seed, chunk, -1, _summon_serial, player)
	body.woken = woken
	_summon_serial += 1
	parent.add_child(body)
	_summons.append(body)


## Deterministic flank-arc offset in radians for summon `serial`, in
## ± SUMMON_FLANK_ARC / 2. Uses WorldGen.hash_u so the same seed, chunk,
## encounter, and serial always land on the same point (row 12).
func summon_flank_jitter(serial: int) -> float:
	return summon_flank_jitter_for(world_seed, chunk, encounter_index, serial)


static func summon_flank_jitter_for(
	p_seed: int, p_chunk: Vector2i, p_encounter: int, serial: int
) -> float:
	var u := WorldGen.hash_u(
		p_seed, p_chunk.x, p_chunk.y, p_encounter, serial, "summon", "arc"
	)
	return (u - 0.5) * SUMMON_FLANK_ARC


## Unit direction from this body to a summon on `side` (+1 left, -1 right
## of the elite-to-player line), at ±90° plus `flank_jitter`. With no player
## the heading stands in for the line. The angle is fixed: a wall never
## re-rolls it (row 12).
func summon_flank_dir(side: float, flank_jitter: float) -> Vector2:
	var lane := _heading
	if player != null:
		var to_player := player.global_position - global_position
		if to_player.length_squared() > 0.000001:
			lane = to_player
	if lane.length_squared() <= 0.000001:
		lane = Vector2.RIGHT
	lane = lane.normalized()
	var normal := Vector2(-lane.y, lane.x)
	var half := SUMMON_FLANK_ARC * 0.5
	var jitter := clampf(flank_jitter, -half, half)
	if absf(jitter) > 0.000001:
		normal = normal.rotated(jitter)
	return normal * side


## Where a summon on `side` appears: SUMMON_OFFSET px out along
## summon_flank_dir. If the add's circle along that ray overlaps a ribbon
## wall, the spawn slides inward along the same ray until the circle and
## the segment from this body's edge are clear, down to 0 px from the
## edge. A far-side clear point past a thin wall is not accepted: if the
## near side has no clear point, the elite-edge point is used. The angle
## is never re-rolled (row 12).
func summon_spawn_point(side: float, flank_jitter: float = 0.0) -> Vector2:
	var dir := summon_flank_dir(side, flank_jitter)
	return _slide_summon_inward(global_position + dir * SUMMON_OFFSET, dir)


func _slide_summon_inward(pos: Vector2, dir: Vector2) -> Vector2:
	var layout := _enabled_slice_layout()
	if layout == null:
		return pos
	var radius := RegularEnemy.radius_of(_summon_kind)
	var min_dist := body_radius
	var inner := global_position + dir * min_dist
	# Check the add's circle along the ray, not just the 48 px endpoint, so
	# a thin wall between the elite and a far-side clear point still slides.
	if not _summon_ray_blocked(layout, dir, min_dist, SUMMON_OFFSET, radius):
		return pos
	if layout.touches_wall(inner, radius):
		# Near side has no clear point down to the elite edge: stay there
		# rather than tunneling to the far side.
		return inner
	var lo := min_dist
	var hi := SUMMON_OFFSET
	for _i in 24:
		var mid := (lo + hi) * 0.5
		if _summon_ray_blocked(layout, dir, min_dist, mid, radius):
			hi = mid
		else:
			lo = mid
	return global_position + dir * lo


## True when the add's circle overlaps a wall at any sample on the ray
## segment from `d0` to `d1` (distances from this body, inclusive).
func _summon_ray_blocked(
	layout: SliceLayout, dir: Vector2, d0: float, d1: float, radius: float
) -> bool:
	var start := minf(d0, d1)
	var end := maxf(d0, d1)
	# Step small enough that a WALL_PX wall cannot be skipped between
	# samples of a circle of `radius`.
	var step := minf(maxf(radius, 1.0), SliceLayout.WALL_PX * 0.5)
	var d := start
	while d < end:
		if layout.touches_wall(global_position + dir * d, radius):
			return true
		d += step
	return layout.touches_wall(global_position + dir * end, radius)


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
