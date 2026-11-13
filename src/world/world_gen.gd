class_name WorldGen
extends RefCounted
## Pure world rolls for the first-playable slice. No node, no scene, no RNG:
## every value is a function of the seed and the coordinates.
##
## hash_u is the only roll. It is NOT GDScript hash() (that is not stable across
## engine versions) and not the Python cadence sim. Layout is the slice default
## in docs/design/first-playable-elites.md §5: FNV-1a 64 of the payload, then
## the splitmix64 avalanche with no added gamma, then the top 53 bits as a unit
## interval. Pinned vectors live in tests/unit/test_world_gen.gd.

const CHUNK_PX := 2048
const TIER_PX := 16384
const SAFE_RADIUS := 512.0
const WAKE_RADIUS := 700.0
const ANCHOR_INSET := 256.0
const ANCHOR_SALTS := 8
const BUDGET_BASE := 6
const BUDGET_PER_TIER := 4
const RING_RADIUS := 1
## T0 splits the budget into this many encounters, 3 points each.
const T0_ENCOUNTERS := 2
const POINTS_PER_ENCOUNTER := 3
## Per encounter, on chunk load. T0 rarity is not rolled: rare and legendary are 0.
const ELITE_CHANCE := 0.04
const RARITY_COMMON := 0
## One escort Drifter sits this far from the anchor (first-playable §5).
const ESCORT_DISTANCE := 48.0
## Herald countdown: 58 + 20·u seconds, u = hash_u(seed, "herald"), so [58, 78).
const HERALD_DELAY_BASE := 58.0
const HERALD_DELAY_SPAN := 20.0
## Spawn this far along the player's heading, then clamp (first-playable §5).
const HERALD_AHEAD := 1200.0
## Keep the clamped point this far inside the tier-0 square (16384 - 64).
const HERALD_EDGE_MARGIN := 64.0
## Heading uses velocity only when it is at least this fast; otherwise aim.
const HERALD_MIN_HEADING_SPEED := 20.0
## No encounter anchor (pack or natural elite) within this many px of a Herald
## spawn point, so the Herald reads as its own encounter (issue #81, GD rule).
const HERALD_PACK_CLEARANCE := 800.0
## Herald point search: the heading first, then turned by this step either way
## (+step, -step, +2·step, ...) up to 180°, all at HERALD_AHEAD; then the same
## turns at the other HERALD_RINGS distances.
const HERALD_TURN_STEP_DEG := 15.0
const HERALD_RINGS: Array[float] = [1200.0, 1000.0, 1400.0, 1600.0, 1800.0]

# FNV-1a 64 offset basis 14695981039346656037 (0xCBF29CE484222325) and prime.
# The offset's high bit is set; GDScript has no unsigned literal, so this is
# the same bits as a signed int.
const FNV_OFFSET := -3750763034362895579
const FNV_PRIME := 1099511628211
# splitmix64 avalanche multipliers (no gamma added):
# 0xBF58476D1CE4E5B9 and 0x94D049BB133111EB.
const SPLIT_1 := -4658895280553007687
const SPLIT_2 := -7723592293110705685
const _UNIT_SCALE := 9007199254740992.0 # 2^53
const _MANTISSA_MASK := 0x1FFFFFFFFFFFFF


## u in [0, 1). Parts after the seed are strings (UTF-8) or ints (int64, two's
## complement). Each part is preceded by a 0x1F separator. Omitted arguments
## stop the payload; do not pass null in the middle.
static func hash_u(
	seed: int,
	p0: Variant = null,
	p1: Variant = null,
	p2: Variant = null,
	p3: Variant = null,
	p4: Variant = null,
	p5: Variant = null,
	p6: Variant = null,
	p7: Variant = null,
) -> float:
	var h := FNV_OFFSET
	h = _mix_i64(h, seed)
	for part: Variant in [p0, p1, p2, p3, p4, p5, p6, p7]:
		if part == null:
			break
		h = _mix_byte(h, 0x1F)
		h = _mix_part(h, part)
	return _to_unit(_splitmix(h))


## T = floor(max(|x|, |y|) / 16384). The tier of a chunk is this function at the
## chunk centre, so tier 0 is the 16×16 chunks with cx, cy in [-8, 7] (spawning
## §2). The boundary line |x| or |y| = 16384 itself is tier 1.
static func tier_at(x: float, y: float) -> int:
	return floori(maxf(absf(x), absf(y)) / float(TIER_PX))


static func chunk_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / float(CHUNK_PX)), floori(pos.y / float(CHUNK_PX)))


static func chunk_origin(cx: int, cy: int) -> Vector2:
	return Vector2(float(cx * CHUNK_PX), float(cy * CHUNK_PX))


static func chunk_tier(cx: int, cy: int) -> int:
	var centre := chunk_origin(cx, cy) + Vector2(float(CHUNK_PX), float(CHUNK_PX)) * 0.5
	return tier_at(centre.x, centre.y)


static func chunk_in_ring(player_chunk: Vector2i, cx: int, cy: int, radius: int = RING_RADIUS) -> bool:
	return maxi(absi(cx - player_chunk.x), absi(cy - player_chunk.y)) <= radius


static func budget_for_tier(tier: int) -> int:
	return BUDGET_BASE + BUDGET_PER_TIER * maxi(tier, 0)


## The inset rectangle anchors are drawn from. Half-open on the far edge except
## for the fallback corner, which sits on that edge.
static func inset_rect(cx: int, cy: int) -> Rect2:
	var origin := chunk_origin(cx, cy)
	var inset := Vector2(ANCHOR_INSET, ANCHOR_INSET)
	var span := float(CHUNK_PX) - 2.0 * ANCHOR_INSET
	return Rect2(origin + inset, Vector2(span, span))


## Encounter anchor. `rolls` are unit-square samples (salt 0, then 1, ...). A
## sample whose distance to the origin is < 512 is rejected. After 8 rejects,
## the inset corner farthest from the origin is used.
static func pick_anchor(cx: int, cy: int, rolls: Array[Vector2]) -> Vector2:
	var rect := inset_rect(cx, cy)
	var limit := mini(rolls.size(), ANCHOR_SALTS)
	for i in limit:
		var roll := rolls[i]
		var point := rect.position + Vector2(roll.x * rect.size.x, roll.y * rect.size.y)
		if point.length() >= SAFE_RADIUS:
			return point
	return farthest_inset_point(cx, cy)


static func farthest_inset_point(cx: int, cy: int) -> Vector2:
	var rect := inset_rect(cx, cy)
	var max_corner := rect.position + rect.size
	var corners: Array[Vector2] = [
		rect.position,
		Vector2(rect.position.x, max_corner.y),
		Vector2(max_corner.x, rect.position.y),
		max_corner,
	]
	var best := corners[0]
	var best_d := best.length_squared()
	for i in range(1, corners.size()):
		var d := corners[i].length_squared()
		if d > best_d:
			best = corners[i]
			best_d = d
	return best


static func encounter_anchor(seed: int, cx: int, cy: int, index: int) -> Vector2:
	var rolls: Array[Vector2] = []
	for salt in ANCHOR_SALTS:
		rolls.append(Vector2(
			hash_u(seed, cx, cy, index, "enc", "x", salt),
			hash_u(seed, cx, cy, index, "enc", "y", salt),
		))
	return pick_anchor(cx, cy, rolls)


## T0: two encounters. 0 = one Swarmer group (3 points), 1 = three Drifters.
## A chunk whose centre is tier 1 or higher spawns nothing in this slice.
## An elite roll replaces that pack. It does not add a third encounter, and it
## does not roll "erar": every T0 elite is common.
static func chunk_encounters(seed: int, cx: int, cy: int) -> Array[EncounterSpec]:
	var result: Array[EncounterSpec] = []
	if chunk_tier(cx, cy) != 0:
		return result
	for index in T0_ENCOUNTERS:
		if roll_is_elite(elite_roll(seed, cx, cy, index)):
			result.append(_elite_pack(seed, cx, cy, index))
		elif index == 0:
			var swarmer_n := 8 + floori(hash_u(seed, cx, cy, index, "enc", "n") * 7.0)
			result.append(_pack(seed, cx, cy, index, &"swarmer", swarmer_n))
		else:
			result.append(_pack(seed, cx, cy, index, &"drifter", 3))
	return result


## hash_u(seed, cx, cy, encounter, "elite"). Compared with `< ELITE_CHANCE`.
static func elite_roll(seed: int, cx: int, cy: int, index: int) -> float:
	return hash_u(seed, cx, cy, index, "elite")


static func roll_is_elite(u: float) -> bool:
	return u < ELITE_CHANCE


## One affix, same uniform rule as the Herald, over the sorted T0 set.
## The trailing 0 is the affix slot (spawning §3.4's n). There is no second slot
## while rarity is hardcoded common.
static func elite_affix(seed: int, cx: int, cy: int, index: int) -> StringName:
	return pick_uniform_affix(hash_u(seed, cx, cy, index, "eaff", 0), AffixCatalog.HERALD_AFFIXES)


## 48 px from the anchor, further from the origin. The slice pins the distance
## and not the direction; radial outward keeps an anchor that is already outside
## the disk from pulling the escort back toward it.
static func escort_position(anchor: Vector2) -> Vector2:
	var away := Vector2.RIGHT
	if anchor.length_squared() > 0.000001:
		away = anchor.normalized()
	return anchor + away * ESCORT_DISTANCE


## Seconds from the Herald arm until the spawn check. [58, 78).
static func herald_delay(seed: int) -> float:
	return HERALD_DELAY_BASE + HERALD_DELAY_SPAN * hash_u(seed, "herald")


## One affix, uniform over the sorted ids. floor(u * n), so u >= 0.5 is the
## second id when there are two (summoner, after splitting).
static func herald_affix(seed: int) -> StringName:
	return pick_uniform_affix(hash_u(seed, "herald", "eaff"), AffixCatalog.HERALD_AFFIXES)


static func pick_uniform_affix(u: float, ids: Array[StringName]) -> StringName:
	var names: Array[String] = []
	for id: StringName in ids:
		names.append(String(id))
	names.sort()
	var n := names.size()
	if n <= 0:
		return StringName()
	var index := floori(u * float(n))
	if index < 0:
		index = 0
	if index >= n:
		index = n - 1
	return StringName(names[index])


## Velocity if it is at least 20 px/s, otherwise the aim direction, otherwise +X.
static func herald_heading(velocity: Vector2, aim: Vector2) -> Vector2:
	if velocity.length() >= HERALD_MIN_HEADING_SPEED:
		return velocity.normalized()
	if aim.length_squared() > 0.000001:
		return aim.normalized()
	return Vector2.RIGHT


## Point `ahead` (default 1,200) px along `heading`. Outside the tier-0 square (half-extent
## 16384 - 64) it is scaled toward the origin onto that square. Inside the
## 512 px disk it is pushed back out along its own radius to 512. The body
## radius is not applied here: the spawner then keeps the whole circle outside
## the disk, the same rule as every other hostile.
static func clamp_herald_point(player_pos: Vector2, heading: Vector2, ahead: float = HERALD_AHEAD) -> Vector2:
	var dir := heading
	if dir.length_squared() <= 0.000001:
		dir = Vector2.RIGHT
	else:
		dir = dir.normalized()
	var point := player_pos + dir * ahead
	var limit := float(TIER_PX) - HERALD_EDGE_MARGIN
	var chebyshev := maxf(absf(point.x), absf(point.y))
	if chebyshev > limit and chebyshev > 0.0:
		point *= limit / chebyshev
	if point.length() < SAFE_RADIUS:
		var radial := point
		if radial.length_squared() <= 0.000001:
			radial = dir
		point = radial.normalized() * SAFE_RADIUS
	return point


## Herald spawn point (issue #81 rule): the first candidate in
## herald_candidates() order with no encounter anchor within
## HERALD_PACK_CLEARANCE. The heading's own point wins whenever it is clear,
## so most spawns are unchanged. Pure function of the seed, the player's
## position and heading: anchors are WorldGen rolls, not live bodies, so the
## answer does not depend on what is streamed in or cleared, and no pack is
## moved, hidden or held asleep.
static func herald_point(seed: int, player_pos: Vector2, heading: Vector2, body_radius: float = 0.0) -> Vector2:
	return pick_herald_point(seed, herald_candidates(player_pos, heading, body_radius))


## Candidate points in preference order, each through clamp_herald_point() and
## pushed out of the safe disk by `body_radius`. See HERALD_TURN_STEP_DEG.
static func herald_candidates(player_pos: Vector2, heading: Vector2, body_radius: float = 0.0) -> Array[Vector2]:
	var dir := heading
	if dir.length_squared() <= 0.000001:
		dir = Vector2.RIGHT
	dir = dir.normalized()
	var turns: Array[float] = [0.0]
	var steps := roundi(180.0 / HERALD_TURN_STEP_DEG)
	for k in range(1, steps + 1):
		turns.append(HERALD_TURN_STEP_DEG * float(k))
		if k < steps:
			turns.append(-HERALD_TURN_STEP_DEG * float(k))
	var out: Array[Vector2] = []
	for ring: float in HERALD_RINGS:
		for turn: float in turns:
			var d := dir.rotated(deg_to_rad(turn))
			var point := clamp_herald_point(player_pos, d, ring)
			var limit := SAFE_RADIUS + body_radius
			if point.length() < limit:
				point = point.normalized() * limit
			out.append(point)
	return out


## First candidate with no anchor within HERALD_PACK_CLEARANCE. Reusable by any
## placement that brings its own candidates (the vertical-slice room C
## redirect, row 6, can pass its point or list). When none is clear, the
## candidate whose nearest anchor is farthest; ties keep the earlier one.
static func pick_herald_point(seed: int, candidates: Array[Vector2]) -> Vector2:
	if candidates.is_empty():
		return Vector2.ZERO
	var cache: Dictionary[Vector2i, PackedVector2Array] = {}
	var best := candidates[0]
	var best_gap := -1.0
	for point: Vector2 in candidates:
		var gap := nearest_anchor_distance(seed, point, HERALD_PACK_CLEARANCE, cache)
		if gap >= HERALD_PACK_CLEARANCE:
			return point
		if gap > best_gap:
			best = point
			best_gap = gap
	return best


## True when no encounter anchor is within `clearance` px of `point`.
static func herald_point_is_clear(seed: int, point: Vector2, clearance: float = HERALD_PACK_CLEARANCE) -> bool:
	return nearest_anchor_distance(seed, point, clearance) >= clearance


## Distance from `point` to the nearest encounter anchor (regular pack or
## natural elite, from chunk_encounters) closer than `radius`, else `radius`.
## `cache` holds per-chunk anchors across calls.
static func nearest_anchor_distance(
	seed: int,
	point: Vector2,
	radius: float,
	cache: Dictionary[Vector2i, PackedVector2Array] = {},
) -> float:
	var best := radius
	var lo := chunk_of(point - Vector2(radius, radius))
	var hi := chunk_of(point + Vector2(radius, radius))
	for cy in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var key := Vector2i(cx, cy)
			if not cache.has(key):
				cache[key] = chunk_anchors(seed, cx, cy)
			for anchor: Vector2 in cache[key]:
				var d := anchor.distance_to(point)
				if d < best:
					best = d
	return best


## Anchors of every encounter chunk_encounters() plans for the chunk.
static func chunk_anchors(seed: int, cx: int, cy: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for spec: EncounterSpec in chunk_encounters(seed, cx, cy):
		out.append(spec.anchor)
	return out


static func _elite_pack(seed: int, cx: int, cy: int, index: int) -> EncounterSpec:
	var spec := EncounterSpec.new()
	spec.chunk = Vector2i(cx, cy)
	spec.index = index
	spec.anchor = encounter_anchor(seed, cx, cy, index)
	spec.is_elite = true
	spec.rarity = RARITY_COMMON
	spec.base = &"drifter"
	var affixes: Array[StringName] = []
	affixes.append(elite_affix(seed, cx, cy, index))
	spec.affix_ids = affixes
	# One Drifter escort (1 point). A Swarmer group costs 3 and cannot escort.
	# The other 2 points of the replaced pack are dropped, so they are not spent.
	var members: Array[Dictionary] = []
	members.append({"archetype": &"drifter", "count": 1})
	spec.members = members
	spec.points_spent = 1
	return spec


static func _pack(seed: int, cx: int, cy: int, index: int, archetype: StringName, count: int) -> EncounterSpec:
	var spec := EncounterSpec.new()
	spec.chunk = Vector2i(cx, cy)
	spec.index = index
	spec.anchor = encounter_anchor(seed, cx, cy, index)
	spec.is_elite = false
	spec.rarity = 0
	spec.base = StringName()
	spec.affix_ids = []
	var members: Array[Dictionary] = []
	members.append({"archetype": archetype, "count": count})
	spec.members = members
	spec.points_spent = POINTS_PER_ENCOUNTER
	return spec


static func _mix_part(h: int, part: Variant) -> int:
	# The public hash takes mixed parts, so each one arrives as a Variant.
	@warning_ignore_start("unsafe_cast")
	var mixed := h
	if part is String:
		var text := part as String
		var bytes := text.to_utf8_buffer()
		for i in bytes.size():
			mixed = _mix_byte(mixed, bytes[i])
	elif part is StringName:
		var name := part as StringName
		var named := String(name).to_utf8_buffer()
		for i in named.size():
			mixed = _mix_byte(mixed, named[i])
	elif part is int:
		mixed = _mix_i64(h, part as int)
	else:
		push_error("WorldGen.hash_u: each part must be a string or an int")
	@warning_ignore_restore("unsafe_cast")
	return mixed


static func _mix_i64(h: int, n: int) -> int:
	var v := n
	for _byte_index in 8:
		h = _mix_byte(h, v & 0xFF)
		v = _lshr(v, 8)
	return h


static func _mix_byte(h: int, byte: int) -> int:
	return _mul64(h ^ (byte & 0xFF), FNV_PRIME)


## Product modulo 2^64. GDScript ints are signed and wrap on overflow, which is
## the two's-complement product the FNV and splitmix steps specify.
static func _mul64(a: int, b: int) -> int:
	return a * b


## Logical right shift. GDScript `>>` sign-fills; the low (64-n) bits match,
## so masking them off is the logical result.
static func _lshr(value: int, n: int) -> int:
	if n <= 0:
		return value
	if n >= 64:
		return 0
	var shifted := value >> n
	var keep := 64 - n
	var mask := (1 << keep) - 1
	return shifted & mask


static func _splitmix(z: int) -> int:
	z = _mul64(z ^ _lshr(z, 30), SPLIT_1)
	z = _mul64(z ^ _lshr(z, 27), SPLIT_2)
	return z ^ _lshr(z, 31)


static func _to_unit(h: int) -> float:
	var mant := _lshr(h, 11) & _MANTISSA_MASK
	return float(mant) / _UNIT_SCALE
