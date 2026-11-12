extends GutTest
## Vertical-slice Herald redirect (§2 "Herald clamp", §10 row 6) and elite wall
## collision: while G0 is shut every point outside open C goes to (4700, 180);
## once G0 is open a point in open C or outside the rooms is kept and only
## walled rooms, corridors and walls redirect. herald_done still blocks
## a second Herald, and a disabled ribbon changes nothing. Elites (and so the
## Herald) do not walk through the ribbon's walls or a shut gate.

const DT := 1.0 / 60.0

var _root: Node2D
var _player: Player
var _arm: HeraldArm
var _director: HeraldDirector
var _slice: SliceLayout
var _save: SaveGame


func after_each() -> void:
	if _root != null and is_instance_valid(_root):
		_root.free()
	_root = null
	if _save != null and FileAccess.file_exists(_save.path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_save.path))
	EliteCue.reset_budget()


func _rig(with_slice: bool, done: bool = false, slice_enabled: bool = true, world_seed: int = 1) -> void:
	if _root != null and is_instance_valid(_root):
		_root.free()
	_save = SaveGame.new()
	_save.path = "user://gut_slice_herald.cfg"
	_save.world_seed = world_seed
	_save.herald_done = done
	_root = Node2D.new()
	add_child(_root)
	_slice = null
	if with_slice:
		_slice = SliceLayout.new()
		_slice.enabled = slice_enabled
		_root.add_child(_slice)
	_player = (preload("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	_root.add_child(_player)
	_player.set_physics_process(false)
	var dummies := Node2D.new()
	_root.add_child(dummies)
	_arm = HeraldArm.new()
	_root.add_child(_arm)
	_arm.bind(_player, dummies)
	_director = HeraldDirector.new()
	_root.add_child(_director)
	_director.bind(_arm, _player, _save)
	_director.natural_elites_cancel = false
	_director.slice = _slice


## Arms outside the disk at `at` moving along `dir`, runs the countdown out and
## returns where the Herald spawned (Vector2.INF if it did not).
func _spawn_from(at: Vector2, dir: Vector2) -> Vector2:
	_player.teleport(at)
	_player.velocity = dir.normalized() * 120.0
	_player.aim_direction = dir.normalized()
	_arm.advance(0.0)
	_director.advance(WorldGen.herald_delay(_save.world_seed) + 0.1)
	if _director.herald == null:
		return Vector2.INF
	return _director.herald.global_position


## Where the director puts the Herald with no ribbon (whatever WorldGen's
## placement does for that seed), so these tests only pin the redirect.
func _open_world_point(world_seed: int, at: Vector2, dir: Vector2) -> Vector2:
	_rig(false, false, true, world_seed)
	return _spawn_from(at, dir)


## First seed whose open-world point for this heading satisfies `want`.
func _seed_where(at: Vector2, dir: Vector2, want: Callable) -> int:
	for world_seed in range(1, 200):
		var p := _open_world_point(world_seed, at, dir)
		var ok: bool = want.call(p)
		if p.is_finite() and ok:
			return world_seed
	return -1


func test_headings_into_walled_rooms_redirect_to_c() -> void:
	var probe := SliceLayout.new()
	add_child_autofree(probe)
	var r := RegularEnemy.DRIFTER_RADIUS
	var cases := {
		"S": [Vector2(-1300, 0), Vector2.RIGHT],
		"A": [Vector2(600, 0), Vector2.RIGHT],
		"B": [Vector2(2000, 0), Vector2.RIGHT],
		"D": [Vector2(6480, 0), Vector2.RIGHT],
		"E": [Vector2(8464, 0), Vector2.RIGHT],
		"alcove": [Vector2(7616, -48), Vector2.DOWN],
		"G3": [Vector2(2768, 0), Vector2.RIGHT],
		"C wall": [Vector2(5000, 176), Vector2.UP],
	}
	for key: String in cases:
		var row: Array = cases[key]
		var at: Vector2 = row[0]
		var dir: Vector2 = row[1]
		var room := StringName(key)
		var lands := func(p: Vector2) -> bool:
			if key == "C wall":
				return probe.touches_wall(p, r)
			return SliceLayout.room_at(p) == room
		var world_seed := _seed_where(at, dir, lands)
		assert_gt(world_seed, 0, "%s: some seed's heading lands there" % key)
		if world_seed < 0:
			continue
		_rig(true, false, true, world_seed)
		assert_eq(_spawn_from(at, dir), SliceLayout.HERALD_REDIRECT, "%s redirects into C (seed %d)" % [key, world_seed])
		assert_true(_save.herald_done)
		assert_eq(SliceLayout.room_at(_director.herald.global_position), &"C")


func test_a_heading_into_open_c_keeps_its_point() -> void:
	var at := Vector2(4176, 300)
	var world_seed := _seed_where(at, Vector2.RIGHT, func(p: Vector2) -> bool: return SliceLayout.room_at(p) == &"C")
	assert_gt(world_seed, 0)
	var expected := _open_world_point(world_seed, at, Vector2.RIGHT)
	_rig(true, false, true, world_seed)
	assert_eq(_spawn_from(at, Vector2.RIGHT), expected)


func _outside(p: Vector2) -> bool:
	return not SliceLayout.in_footprint(p)


func _between_rooms(p: Vector2) -> bool:
	return SliceLayout.in_footprint(p) and SliceLayout.room_at(p) == &""


## Heading from `at` whose open-world point satisfies `where`: redirected
## while G0 is shut, kept once G0 is open.
func _shut_redirects_open_keeps(at: Vector2, where: Callable, label: String) -> void:
	var world_seed := _seed_where(at, Vector2.RIGHT, where)
	assert_gt(world_seed, 0, "%s: some seed lands there" % label)
	if world_seed < 0:
		return
	var expected := _open_world_point(world_seed, at, Vector2.RIGHT)
	_rig(true, false, true, world_seed)
	assert_false(_slice.is_gate_open(&"G0"))
	assert_eq(_spawn_from(at, Vector2.RIGHT), SliceLayout.HERALD_REDIRECT, "%s, G0 shut: into C" % label)
	_rig(true, false, true, world_seed)
	_slice.open_gate(&"G0")
	assert_eq(_spawn_from(at, Vector2.RIGHT), expected, "%s, G0 open: kept" % label)


func test_a_heading_outside_the_footprint_redirects_until_g0_opens() -> void:
	_shut_redirects_open_keeps(Vector2(2000, -1700), _outside, "outside the footprint")


func test_a_heading_between_rooms_redirects_until_g0_opens() -> void:
	_shut_redirects_open_keeps(Vector2(-400, 400), _between_rooms, "between rooms")


func test_walled_rooms_still_redirect_once_g0_is_open() -> void:
	var world_seed := _seed_where(Vector2(600, 0), Vector2.RIGHT, func(p: Vector2) -> bool: return SliceLayout.room_at(p) == &"A")
	assert_gt(world_seed, 0)
	_rig(true, false, true, world_seed)
	_slice.open_gate(&"G0")
	assert_eq(_spawn_from(Vector2(600, 0), Vector2.RIGHT), SliceLayout.HERALD_REDIRECT, "room A")


func test_herald_done_still_blocks_a_second_herald() -> void:
	_rig(true)
	assert_true(_spawn_from(Vector2(600, 0), Vector2.RIGHT).is_finite())
	assert_true(_save.herald_done)
	_rig(true, true)
	assert_true(_director.resolved)
	assert_eq(_spawn_from(Vector2(600, 0), Vector2.RIGHT), Vector2.INF, "no second Herald")


func test_a_disabled_or_missing_ribbon_does_not_redirect() -> void:
	var at := Vector2(600, 0)
	var natural := _open_world_point(1, at, Vector2.RIGHT)
	_rig(true, false, false)
	assert_eq(_spawn_from(at, Vector2.RIGHT), natural, "disabled")
	_rig(false)
	assert_eq(_spawn_from(at, Vector2.RIGHT), natural, "no ribbon")


func test_redirect_rules_on_points() -> void:
	_rig(true)
	var r := RegularEnemy.DRIFTER_RADIUS
	assert_eq(_slice.redirect_herald(Vector2(5400, 600), r), Vector2(5400, 600), "open C")
	assert_eq(_slice.redirect_herald(Vector2(4100, 300), r), SliceLayout.HERALD_REDIRECT, "on C's west wall")
	assert_eq(_slice.redirect_herald(Vector2(-775, 300), r), SliceLayout.HERALD_REDIRECT, "outside, but touching S's wall")
	assert_eq(_slice.redirect_herald(Vector2(896, 0), r), SliceLayout.HERALD_REDIRECT, "G1 corridor")
	# G0 shut: only open C is kept.
	assert_eq(_slice.redirect_herald(Vector2(-800, 300), r), SliceLayout.HERALD_REDIRECT, "outside, G0 shut")
	assert_eq(_slice.redirect_herald(Vector2(0, -3000), r), SliceLayout.HERALD_REDIRECT, "far outside, G0 shut")
	assert_eq(_slice.redirect_herald(Vector2(896, 300), r), SliceLayout.HERALD_REDIRECT, "between rooms, G0 shut")
	# G0 open (after the Warden): outside the rooms is kept again.
	_slice.open_gate(&"G0")
	assert_eq(_slice.redirect_herald(Vector2(-800, 300), r), Vector2(-800, 300), "outside, G0 open")
	assert_eq(_slice.redirect_herald(Vector2(896, 300), r), Vector2(896, 300), "between rooms, G0 open")
	assert_eq(_slice.redirect_herald(Vector2(5400, 600), r), Vector2(5400, 600), "open C, G0 open")
	assert_eq(_slice.redirect_herald(Vector2(1664, 0), r), SliceLayout.HERALD_REDIRECT, "room A, G0 open")
	assert_eq(_slice.redirect_herald(Vector2(896, 0), r), SliceLayout.HERALD_REDIRECT, "G1 corridor, G0 open")
	assert_eq(_slice.redirect_herald(Vector2(-775, 300), r), SliceLayout.HERALD_REDIRECT, "touching S's wall, G0 open")
	_slice.close_gate(&"G0")
	assert_false(_slice.touches_wall(SliceLayout.HERALD_REDIRECT, r), "the target itself is clear")
	assert_eq(SliceLayout.room_at(SliceLayout.HERALD_REDIRECT), &"C")


# --- elite wall collision --------------------------------------------------------

func _elite_at(at: Vector2) -> EliteEnemy:
	var elite := (preload("res://scenes/elite_enemy.tscn") as PackedScene).instantiate() as EliteEnemy
	elite.configure_elite(AffixCatalog.SPLITTING, at, at, 1, _player, false, false)
	_root.add_child(elite)
	return elite


func test_an_elite_chasing_into_b_stops_at_the_wall_and_the_shut_gate() -> void:
	_rig(true)
	var wall_elite := _elite_at(Vector2(4180, 300))
	var gate_elite := _elite_at(Vector2(4180, 0))
	_player.global_position = Vector2(3700, 300)
	await wait_physics_frames(2)
	for _i in 240:
		wall_elite._physics_process(DT)
		gate_elite._physics_process(DT)
	assert_true(wall_elite.woken)
	var c := SliceLayout.room_rect(&"C")
	assert_gte(wall_elite.global_position.x, c.position.x + SliceLayout.WALL_PX + wall_elite.body_radius - 0.5,
		"held by C's west wall (%s)" % wall_elite.global_position)
	var gate := SliceLayout.gate_rect(&"G3")
	assert_gte(gate_elite.global_position.x, gate.end.x + gate_elite.body_radius - 0.5,
		"held by shut G3 (%s)" % gate_elite.global_position)
	assert_lt(gate_elite.global_position.x, 4096.0, "it did walk into the corridor up to the gate")
	_slice.open_gate(&"G3")
	for _i in 120:
		gate_elite._physics_process(DT)
	assert_lt(gate_elite.global_position.x, gate.position.x, "open G3: it follows into B")


func test_the_herald_spawned_in_c_stays_in_c() -> void:
	_rig(true)
	_spawn_from(Vector2(600, 0), Vector2.RIGHT)
	var herald := _director.herald
	assert_not_null(herald)
	assert_true(herald.collide_walls)
	# Wake it from B, through C's west wall.
	_player.global_position = Vector2(4000, 180)
	await wait_physics_frames(2)
	for _i in 600:
		herald._physics_process(DT)
	assert_true(herald.woken)
	assert_eq(SliceLayout.room_at(herald.global_position), &"C", "still in C at %s" % herald.global_position)


func test_regulars_do_not_collide_yet() -> void:
	var body := (preload("res://scenes/regular_enemy.tscn") as PackedScene).instantiate() as RegularEnemy
	assert_false(body.collide_walls, "row 2 decides the regular wall rule")
	body.free()


func test_main_scene_redirects_the_herald_into_c() -> void:
	var path := "user://gut_slice_herald_main.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var seeded := SaveGame.new()
	seeded.path = path
	seeded.world_seed = 1
	seeded.save()
	# Same director and seed without a ribbon: the open-world point. On main
	# today that is (1800, 0), in room A.
	var natural := _open_world_point(1, Vector2(600, 0), Vector2.RIGHT)
	_root.free()
	_root = null
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate() as Main
	main.save_path = path
	add_child(main)
	var main_expected := (main.get_node("SliceLayout") as SliceLayout).redirect_herald(natural, RegularEnemy.DRIFTER_RADIUS)
	var player := main.get_node("Player") as Player
	player.set_physics_process(false)
	var arm := main.get_node("HeraldArm") as HeraldArm
	var director := main.get_node("HeraldDirector") as HeraldDirector
	assert_eq(director.slice, main.get_node("SliceLayout"))
	player.teleport(Vector2(600, 0))
	player.velocity = Vector2(100, 0)
	arm.advance(0.0)
	director.advance(WorldGen.herald_delay(1) + 0.1)
	var herald := director.herald
	assert_not_null(herald)
	assert_eq(herald.global_position, main_expected, "the open-world point %s, through the redirect" % natural)
	assert_ne(SliceLayout.room_at(herald.global_position), &"A", "never in a walled room")
	assert_true(SaveGame.load_from(path).herald_done)
	var bullets := main.get_node("BulletManager") as BulletManager
	bullets.bounds_center = null
	bullets.recenter_world_bounds(herald.global_position)
	var hp := herald.health.hp
	var r := ShotRequest.with_velocity(herald.global_position + Vector2(-6, 0), Vector2(400, 0))
	r.damage = 1.0
	assert_gte(bullets.spawn(r), 0)
	bullets.step(DT)
	assert_almost_eq(herald.health.hp, hp - 1.0, 0.01, "fightable where it landed")
	bullets.clear_bullets()
	main.free()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
