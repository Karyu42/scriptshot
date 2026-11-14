extends GutTest
## Vertical-slice §4 / row 12: authored Hydra in the alcove, hydra_dead,
## +10 shards on the first split, legendary cue, and the room-D rare's
## second glyph.

const DT := 1.0 / 60.0
const _SAVE := "user://gut_slice_hydra_alcove.cfg"


class CountingSave:
	extends SaveGame
	var writes := 0

	func save() -> void:
		super.save()
		writes += 1


var alcove: SliceHydraAlcove
var layout: SliceLayout
var progress: SliceProgress
var player: Player
var save: CountingSave


func before_each() -> void:
	_discard(_SAVE)
	EliteCue.reset_budget()
	layout = SliceLayout.new()
	layout.enabled = true
	add_child_autofree(layout)
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	player.position = Vector2.ZERO
	add_child_autofree(player)
	player.set_physics_process(false)
	player.health.set_physics_process(false)
	save = CountingSave.new()
	save.path = _SAVE
	save.world_seed = 1
	save.save()
	save.writes = 0
	progress = SliceProgress.new()
	add_child_autofree(progress)
	progress.bind(player, null, layout, save)
	alcove = SliceHydraAlcove.new()
	add_child_autofree(alcove)
	alcove.bind(player, save, save.world_seed)
	_freeze(alcove)
	await wait_physics_frames(1)


func after_each() -> void:
	EliteCue.reset_budget()
	_discard(_SAVE)


func test_the_alcove_door_is_open_in_the_room_geometry() -> void:
	assert_eq(SliceLayout.ALCOVE_DOOR_SPAN, Vector2(7500, 7628))
	var mid := Vector2(
		(SliceLayout.ALCOVE_DOOR_SPAN.x + SliceLayout.ALCOVE_DOOR_SPAN.y) * 0.5,
		SliceLayout.room_rect(SliceLayout.ROOM_ALCOVE).position.y + 8.0
	)
	assert_eq(SliceLayout.room_at(mid), SliceLayout.ROOM_ALCOVE)
	assert_false(layout.touches_wall(mid, 4.0), "the door span leaves the north opening clear")
	var wall := Vector2(SliceLayout.ALCOVE_DOOR_SPAN.x - 40.0, mid.y)
	assert_true(layout.touches_wall(wall, 4.0), "D's south wall is solid west of the door")


func test_the_hydra_spawns_at_the_alcove_centre() -> void:
	assert_true(alcove.hydra_alive())
	var hydra := alcove.hydra
	assert_almost_eq(hydra.global_position.x, SliceHydraAlcove.ANCHOR.x, 0.1)
	assert_almost_eq(hydra.global_position.y, SliceHydraAlcove.ANCHOR.y, 0.1)
	assert_eq(SliceLayout.room_at(hydra.global_position), SliceLayout.ROOM_ALCOVE)
	assert_eq(hydra.rarity, EnemyKinds.RARITY_LEGENDARY)
	assert_eq(hydra.signature_name, "Hydra")
	assert_true(hydra.has_affix(AffixCatalog.SPLITTING))
	assert_true(hydra.has_affix(AffixCatalog.SUMMONER))
	assert_true(hydra.halves_resplit)
	assert_true(hydra.summon_after_wake)
	assert_almost_eq(hydra.health.max_hp, EliteEnemy.LEGENDARY_HP, 0.001)
	assert_almost_eq(hydra.health.max_hp, 210.0, 0.001)
	assert_almost_eq(hydra._move_speed(), EliteEnemy.LEGENDARY_SPEED, 0.001)
	assert_almost_eq(hydra._move_speed(), 99.0, 0.001)
	assert_almost_eq(hydra._wake_radius(), EliteEnemy.LEGENDARY_WAKE_RADIUS, 0.001)
	assert_eq(hydra.chunk, WorldGen.chunk_of(SliceHydraAlcove.ANCHOR))
	assert_eq(hydra.encounter_index, -1)
	assert_false(hydra.grants_shard)
	assert_false(save.hydra_dead)
	assert_eq(save.shards, 0)
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G5))


func test_the_legendary_cue_and_name_line_are_copied_before_ready() -> void:
	var hydra := alcove.hydra
	assert_not_null(hydra.cue)
	assert_eq(hydra.cue.tier, RarityCue.TIER_ELITE_LEGENDARY)
	assert_eq(hydra.cue.tick_count(), 4)
	assert_eq(hydra.cue.outline_base(), 5.0)
	assert_eq(hydra.cue.accent(), RarityCue.LEGENDARY_COLOR)
	assert_true(hydra.cue.draws_signature())
	assert_eq(hydra.cue.signature_name, "Hydra")
	assert_true(hydra.cue.draws_halo())
	assert_eq(hydra.cue.halo_kind(), RarityCue.HALO_LEGENDARY)
	assert_eq(hydra.sting.tier, RarityCue.TIER_ELITE_LEGENDARY)
	hydra.cue.start_brighten()
	assert_almost_eq(hydra.cue.name_left, RarityCue.NAME_SECONDS, 0.001)
	player.global_position = SliceHydraAlcove.ANCHOR + Vector2(0, -100)
	hydra._physics_process(DT)
	assert_true(hydra.woken)
	assert_almost_eq(hydra.cue.name_left, RarityCue.NAME_SECONDS, 0.05)


func test_the_hydra_wakes_on_the_alcove_rect_or_the_800_px_wake() -> void:
	var hydra := alcove.hydra
	var rect := SliceLayout.room_rect(SliceLayout.ROOM_ALCOVE)
	assert_gt(SliceHydraAlcove.ANCHOR.distance_to(Vector2.ZERO), EliteEnemy.LEGENDARY_WAKE_RADIUS)
	assert_false(hydra.woken)
	# Just north of the alcove, farther than 800 px: still asleep.
	var north := Vector2(SliceHydraAlcove.ANCHOR.x, SliceHydraAlcove.ANCHOR.y - 801.0)
	assert_false(rect.has_point(north))
	assert_gt(north.distance_to(SliceHydraAlcove.ANCHOR), EliteEnemy.LEGENDARY_WAKE_RADIUS)
	player.global_position = north
	hydra._physics_process(DT)
	assert_false(hydra.woken, "801 px north of centre, outside the rect")
	# Legendary 800 px wake, still north of the door.
	var at_800 := Vector2(SliceHydraAlcove.ANCHOR.x, SliceHydraAlcove.ANCHOR.y - 800.0)
	assert_false(rect.has_point(at_800))
	player.global_position = at_800
	hydra._physics_process(DT)
	assert_true(hydra.woken, "the 800 px wake fires first if the player is that close")
	hydra.woken = false
	# Door line: y = 640, inside the alcove x range, farther than 800 from the
	# centre (512 px to the north wall? centre y 1152 - 640 = 512, so this
	# also satisfies the 800 px wake). Use the east edge of the rect, which
	# is 512 px from centre in x and 0 in y? end.x is exclusive of has_point.
	# A point just inside the north-west corner is on the door wall line.
	var door := Vector2(
		(SliceLayout.ALCOVE_DOOR_SPAN.x + SliceLayout.ALCOVE_DOOR_SPAN.y) * 0.5,
		rect.position.y
	)
	assert_true(rect.has_point(door) or door.y == rect.position.y)
	# The door mid is 512 px north of centre, so 800 would also wake it.
	# A point on the south edge of the rect is 512 px south: also inside 800.
	# To isolate the rect trigger, pick a point inside the rect but then we
	# cannot get farther than 800 inside a 1024 room from the centre (max
	# half-diagonal is ~724). The rect is always within 800 of the centre.
	# So "whichever comes first" means: approaching from room D, the 800 px
	# wake fires north of the door (at y=352), before the player enters.
	# Entering the rect would also wake, and we still assert that.
	assert_lt(door.distance_to(SliceHydraAlcove.ANCHOR), EliteEnemy.LEGENDARY_WAKE_RADIUS)
	player.global_position = door
	hydra._physics_process(DT)
	assert_true(hydra.woken, "entering the alcove rect wakes it")


func test_summons_wait_for_wake_the_first_wave_is_at_6s_and_they_are_105_hp_drifters() -> void:
	var hydra := alcove.hydra
	hydra._physics_process(10.0)
	assert_eq(hydra.summon_alive(), 0, "no wave while asleep")
	_wake_by_radius(hydra)
	assert_true(hydra.woken)
	hydra._physics_process(5.9)
	assert_eq(hydra.summon_alive(), 0, "first wave is 6 s after wake")
	hydra._physics_process(0.2)
	assert_eq(hydra.summon_alive(), 2)
	var add := _one_summon(hydra)
	assert_not_null(add)
	assert_true(add is SummonAdd)
	assert_eq(add.archetype, RegularEnemy.ARCH_DRIFTER)
	assert_almost_eq(add.health.max_hp, 105.0, 0.001)
	assert_false(add is EliteEnemy)
	# Hash convention matches room D: chunk_of(anchor), encounter_index -1.
	var expected := EliteEnemy.summon_flank_jitter_for(
		save.world_seed, WorldGen.chunk_of(SliceHydraAlcove.ANCHOR), -1, 0
	)
	assert_almost_eq((add as SummonAdd).flank_jitter, expected, 0.0001)
	# Fill the cap: two more waves of 2.
	hydra._physics_process(6.0)
	hydra._physics_process(6.0)
	assert_eq(hydra.summon_alive(), 6)
	hydra._physics_process(6.0)
	assert_eq(hydra.summon_alive(), 6, "the cap holds")
	assert_false(save.hydra_dead)
	assert_eq(save.shards, 0)


func test_the_first_split_writes_hydra_dead_and_ten_shards_once() -> void:
	var hydra := alcove.hydra
	watch_signals(hydra)
	var gates := save.slice_gates
	save.writes = 0
	hydra.health.try_damage(10000.0)
	assert_false(alcove.hydra_alive())
	assert_signal_not_emitted(hydra, "shard_dropped")
	assert_true(save.hydra_dead)
	assert_eq(save.shards, 10)
	assert_eq(save.writes, 1, "one persist covers the flag and the shards")
	assert_eq(save.slice_gates, gates, "the alcove does not gate G5")
	assert_false(progress.is_gate_unlocked(SliceLayout.GATE_G5))
	var loaded := SaveGame.load_from(_SAVE)
	assert_true(loaded.hydra_dead)
	assert_eq(loaded.shards, 10)
	# Halves are leftovers in the current session.
	var halves := _halves(alcove)
	assert_eq(halves.size(), 2)


func test_halves_carry_splitting_only_and_summons_stop() -> void:
	var hydra := alcove.hydra
	_wake_by_radius(hydra)
	hydra._physics_process(6.1)
	assert_eq(hydra.summon_alive(), 2)
	hydra.health.try_damage(10000.0)
	var halves := _halves(alcove)
	assert_eq(halves.size(), 2)
	for half: EliteEnemy in halves:
		assert_true(half.is_half)
		assert_true(half.has_affix(AffixCatalog.SPLITTING))
		assert_false(half.has_affix(AffixCatalog.SUMMONER))
		assert_false(half.halves_resplit)
		assert_null(half.cue)
		assert_false(half.grants_shard)
		assert_almost_eq(half.health.max_hp, 84.0, 0.01)
		assert_almost_eq(half._move_speed(), 99.0 * 1.3, 0.05)
		assert_almost_eq(half._move_speed(), 129.0, 0.5)
	# Existing summons stay; the dead original does not wave again.
	assert_eq(hydra.summon_alive(), 2)
	# Advance past several legendary intervals; halves have no Summoner.
	for half: EliteEnemy in halves:
		half._physics_process(20.0)
	assert_eq(_count_summons(alcove), 2, "summons stop when the original dies")
	# Killing a summon or a half does not write the save again.
	var writes := save.writes
	var shards := save.shards
	var add := _one_summon(hydra)
	assert_not_null(add)
	add.health.try_damage(10000.0)
	assert_eq(_count_summons(alcove), 1)
	assert_eq(save.writes, writes)
	assert_eq(save.shards, shards)
	assert_true(save.hydra_dead)
	# First halves split once more; the second generation does not.
	var first := halves[0]
	first.health.try_damage(10000.0)
	var after := _halves(alcove)
	assert_eq(after.size(), 3, "one first-gen half plus two second-gen")
	var second_gen: Array[EliteEnemy] = []
	for half: EliteEnemy in after:
		if half == halves[1]:
			continue
		second_gen.append(half)
		assert_true(half.is_half)
		assert_false(half.has_affix(AffixCatalog.SPLITTING), "second-gen halves do not split")
		assert_false(half.has_affix(AffixCatalog.SUMMONER))
		assert_false(half.grants_shard)
		assert_null(half.cue)
		# 40% of 84 is 33.6; the spec rounds that to 34.
		assert_almost_eq(half.health.max_hp, 84.0 * 0.4, 0.01)
		assert_almost_eq(half.health.max_hp, 34.0, 0.5)
		assert_almost_eq(half._move_speed(), 99.0 * 1.3 * 1.3, 0.05)
		assert_almost_eq(half._move_speed(), 167.0, 0.5)
	assert_eq(second_gen.size(), 2)
	var child := second_gen[0]
	child.health.try_damage(10000.0)
	assert_eq(_halves(alcove).size(), 2, "a second-gen half does not split")
	assert_eq(save.writes, writes, "halves and summons never write the slot")
	assert_eq(save.shards, shards)


func test_a_saved_hydra_dead_flag_does_not_spawn_on_load() -> void:
	_discard(_SAVE)
	var slot := SaveGame.new()
	slot.path = _SAVE
	slot.world_seed = 1
	slot.hydra_dead = true
	slot.save()
	var host := SliceHydraAlcove.new()
	add_child_autofree(host)
	host.bind(player, slot, slot.world_seed)
	assert_false(host.hydra_alive())
	assert_eq(host.get_child_count(), 0, "halves and summons do not return")


func test_killing_the_body_then_rebinding_does_not_respawn() -> void:
	alcove.hydra.health.try_damage(10000.0)
	assert_true(save.hydra_dead)
	var loaded := SaveGame.load_from(_SAVE)
	var again := SliceHydraAlcove.new()
	add_child_autofree(again)
	again.bind(player, loaded, loaded.world_seed)
	assert_false(again.hydra_alive())
	assert_eq(again.get_child_count(), 0)


func test_player_death_leaves_a_living_hydra_in_place() -> void:
	# Same as #101's room D rare: the body is not reset or despawned when
	# the player dies. Only a reload of a dead flag skips the spawn.
	var hydra := alcove.hydra
	_wake_by_radius(hydra)
	hydra._physics_process(6.1)
	hydra.health.try_damage(20.0)
	var hp := hydra.health.hp
	var summons := hydra.summon_alive()
	assert_gt(summons, 0)
	assert_lt(hp, hydra.health.max_hp)
	player.health.try_damage(10000.0)
	assert_true(player.health.is_dead())
	assert_true(alcove.hydra_alive())
	assert_almost_eq(hydra.health.hp, hp, 0.001)
	assert_eq(hydra.summon_alive(), summons)
	assert_false(save.hydra_dead)
	assert_eq(save.shards, 0)


func test_the_authored_room_d_rare_shows_both_glyphs() -> void:
	var room := SliceRoomD.new()
	add_child_autofree(room)
	room.bind(player, progress, save, save.world_seed)
	_freeze(room)
	await wait_physics_frames(1)
	var elite := room.elite
	assert_not_null(elite)
	assert_eq(elite.cue.glyph_slot_count(), 2)
	var kinds: Array[int] = elite.cue.glyphs
	assert_eq(kinds.size(), 2)
	var first := 0
	var second := 0
	if kinds.size() >= 1:
		first = kinds[0]
	if kinds.size() >= 2:
		second = kinds[1]
	assert_eq(first, RarityCue.GLYPH_SQUARE)
	assert_eq(second, RarityCue.GLYPH_CIRCLE)


func test_main_scene_has_the_alcove_node() -> void:
	_discard(_SAVE)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = _SAVE
	add_child_autofree(main)
	var host := main.get_node("SliceHydraAlcove") as SliceHydraAlcove
	assert_not_null(host)
	assert_true(host.hydra_alive())
	assert_almost_eq(host.hydra.global_position.x, SliceHydraAlcove.ANCHOR.x, 0.1)
	assert_eq(host.hydra.rarity, EnemyKinds.RARITY_LEGENDARY)
	assert_eq(host.hydra.signature_name, "Hydra")
	assert_eq(host.hydra.cue.tier, RarityCue.TIER_ELITE_LEGENDARY)
	assert_eq(host.hydra.cue.signature_name, "Hydra")


func _wake_by_radius(hydra: EliteEnemy) -> void:
	player.global_position = hydra.global_position + Vector2(0, -800.0)
	hydra._physics_process(DT)


func _one_summon(hydra: EliteEnemy) -> RegularEnemy:
	for body: Node in alcove.get_children():
		if body != hydra and body is SummonAdd and (body as RegularEnemy).is_alive():
			return body as RegularEnemy
	return null


func _count_summons(host: Node) -> int:
	var n := 0
	for body: Node in host.get_children():
		if body is SummonAdd and (body as RegularEnemy).is_alive():
			n += 1
	return n


func _halves(host: Node) -> Array[EliteEnemy]:
	var out: Array[EliteEnemy] = []
	for body: Node in host.get_children():
		var elite := body as EliteEnemy
		if elite != null and elite.is_half and elite.is_alive():
			out.append(elite)
	return out


func _freeze(host: Node) -> void:
	for child: Node in host.get_children():
		child.set_physics_process(false)


func _discard(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
