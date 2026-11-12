extends GutTest
## Vertical-slice Herald redirect (§2 "Herald clamp", §10 row 6) and elite wall
## collision: a point that lands in a walled room goes to (4700, 180) in C, a
## point in open C or outside the footprint is kept, herald_done still blocks
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


func _rig(with_slice: bool, done: bool = false, slice_enabled: bool = true) -> void:
	_save = SaveGame.new()
	_save.path = "user://gut_slice_herald.cfg"
	_save.world_seed = 1
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


func test_headings_into_walled_rooms_redirect_to_c() -> void:
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
		var natural := WorldGen.clamp_herald_point(at, dir)
		if key != "C wall":
			assert_eq(SliceLayout.room_at(natural), StringName(key), "%s: the heading lands in it" % key)
		_rig(true)
		assert_eq(_spawn_from(at, dir), SliceLayout.HERALD_REDIRECT, "%s redirects into C" % key)
		assert_true(_save.herald_done)
		assert_eq(SliceLayout.room_at(_director.herald.global_position), &"C")
		_root.free()


func test_a_heading_into_open_c_keeps_its_point() -> void:
	_rig(true)
	var at := Vector2(4176, 300)
	var expected := WorldGen.clamp_herald_point(at, Vector2.RIGHT)
	assert_eq(SliceLayout.room_at(expected), &"C")
	assert_eq(_spawn_from(at, Vector2.RIGHT), expected)


func test_a_heading_outside_the_footprint_keeps_its_point() -> void:
	_rig(true)
	var at := Vector2(2000, -1700)
	var expected := WorldGen.clamp_herald_point(at, Vector2.RIGHT)
	assert_false(SliceLayout.in_footprint(expected))
	assert_eq(_spawn_from(at, Vector2.RIGHT), expected)


func test_herald_done_still_blocks_a_second_herald() -> void:
	_rig(true)
	assert_eq(_spawn_from(Vector2(600, 0), Vector2.RIGHT), SliceLayout.HERALD_REDIRECT)
	assert_true(_save.herald_done)
	var saved := _save
	_root.free()
	_rig(true, true)
	assert_true(_director.resolved)
	assert_eq(_spawn_from(Vector2(600, 0), Vector2.RIGHT), Vector2.INF, "no second Herald")
	assert_true(saved.herald_done)


func test_a_disabled_or_missing_ribbon_does_not_redirect() -> void:
	var at := Vector2(600, 0)
	var natural := WorldGen.clamp_herald_point(at, Vector2.RIGHT)
	_rig(true, false, false)
	assert_eq(_spawn_from(at, Vector2.RIGHT), natural, "disabled")
	_root.free()
	_rig(false)
	assert_eq(_spawn_from(at, Vector2.RIGHT), natural, "no ribbon")


func test_redirect_rules_on_points() -> void:
	_rig(true)
	var r := RegularEnemy.DRIFTER_RADIUS
	assert_eq(_slice.redirect_herald(Vector2(5400, 600), r), Vector2(5400, 600), "open C")
	assert_eq(_slice.redirect_herald(Vector2(4100, 300), r), SliceLayout.HERALD_REDIRECT, "on C's west wall")
	assert_eq(_slice.redirect_herald(Vector2(-775, 300), r), SliceLayout.HERALD_REDIRECT, "outside, but touching S's wall")
	assert_eq(_slice.redirect_herald(Vector2(-800, 300), r), Vector2(-800, 300), "outside and clear")
	assert_eq(_slice.redirect_herald(Vector2(896, 300), r), Vector2(896, 300), "open ground between rooms")
	assert_eq(_slice.redirect_herald(Vector2(896, 0), r), SliceLayout.HERALD_REDIRECT, "G1 corridor")
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
