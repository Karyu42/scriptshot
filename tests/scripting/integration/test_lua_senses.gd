extends GutTest
## The Lua side of the Senses (vertical-slice §6.2): `sense.nearest_enemy` and
## `sense.enemies_in` over the WorldQuery snapshot. Locked fields, return
## shape, read-only results, the Level I clamp and filter, the 256 cap, parity
## with WorldQuery, and the homing starter on both bullet backends.

const DT := 1.0 / 60.0

var _bodies: Array[Node2D] = []
var _mgrs: Array[BulletManager] = []


func before_each() -> void:
	SenseBook.reset()
	WorldQuery.reset()
	ScriptWarnings.reset()


func after_each() -> void:
	for m in _mgrs:
		if is_instance_valid(m):
			m._behaviors.clear()
	_mgrs.clear()
	for b in _bodies:
		if is_instance_valid(b):
			WorldQuery.unregister_enemy(b)
	_bodies.clear()
	WorldQuery.reset()
	SenseBook.reset()


func _body(pos: Vector2, kind: StringName = EnemyKinds.DRIFTER, radius: float = 16.0, rarity: int = EnemyKinds.RARITY_NONE) -> Node2D:
	var b := Node2D.new()
	add_child_autofree(b)
	b.global_position = pos
	WorldQuery.register_enemy(b, kind, rarity, 0, radius)
	_bodies.append(b)
	return b


func _host(code: String) -> ScriptHost:
	var host := ScriptHost.new()
	host.wall_msec = 5000
	var r := host.load_string(code, "senses.lua")
	assert_true(r.ok, "load: %s" % r.error)
	return host


## Runs `body` as on_fire and returns what it printed (one string per print).
func _fire(host: ScriptHost) -> ScriptHost.RunResult:
	var c := ShotContext.new()
	c.muzzle_position = Vector2.ZERO
	return host.call_fire(c)


func _run(body: String) -> ScriptHost.RunResult:
	var host := _host("return { on_fire = function(ctx)\n%s\nend }" % body)
	return _fire(host)


func _out(r: ScriptHost.RunResult) -> String:
	assert_true(r.ok, r.error)
	return "\n".join(r.output)


# --- locked ------------------------------------------------------------------

func test_unearned_senses_are_nil_and_sense_is_a_table() -> void:
	_body(Vector2(50, 0))
	WorldQuery.refresh()
	var out := _out(_run("print(type(sense), sense.nearest_enemy, sense.enemies_in, sense.enemy_bullets, sense.terrain, sense.boss, sense.world)"))
	assert_eq(out, "table\tnil\tnil\tnil\tnil\tnil\tnil")


func test_the_guarded_call_is_safe_while_locked() -> void:
	var out := _out(_run("local e = sense.nearest_enemy and sense.nearest_enemy({ x = 0, y = 0 })\nprint(e)"))
	assert_eq(out, "nil")


func test_scripts_cannot_write_the_sense_table() -> void:
	var r := _run("sense.nearest_enemy = function() return { pos = { x = 1, y = 2 } } end")
	assert_false(r.ok)
	assert_string_contains(r.error, "sense is read-only")
	var r2 := _run("rawset(sense, 'nearest_enemy', print)")
	assert_false(r2.ok)
	assert_string_contains(r2.error, "protected table")
	var out := _out(_run("print(getmetatable(sense))"))
	assert_eq(out, "false")


func test_a_grant_reaches_a_host_that_is_already_running() -> void:
	_body(Vector2(30, 40), EnemyKinds.DUMMY, 22.0)
	WorldQuery.refresh()
	var host := _host("return { on_fire = function(ctx)\nlocal f = sense.nearest_enemy\nprint(f and f({ x = 0, y = 0 }).kind or 'locked')\nend }")
	assert_eq(_out(_fire(host)), "locked")
	SenseBook.grant(&"nearest_enemy", 1)
	assert_eq(_out(_fire(host)), "dummy")


func test_a_load_after_the_grant_sees_the_sense_at_top_level() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var host := _host("local ok = sense.nearest_enemy ~= nil\nreturn { on_fire = function(ctx) print(ok) end }")
	assert_eq(_out(_fire(host)), "true")


# --- shape -------------------------------------------------------------------

func test_nearest_enemy_level_one_shape() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var near := _body(Vector2(30, 40), EnemyKinds.HUSK, 16.0)
	_body(Vector2(300, 0), EnemyKinds.WARDEN, 48.0, EnemyKinds.RARITY_COMMON)
	WorldQuery.refresh()
	var out := _out(_run("""
		local e = sense.nearest_enemy({ x = 0, y = 0 })
		print(e.id, e.pos.x, e.pos.y, e.radius, e.kind, type(e.kind), e:alive())
		print(e.vel, e.hp, e.hp_max, e.speed, e.tier, e.is_boss, e.hp_frac)
		print("[" .. e.rarity .. "]", type(e.rarity))
	""".dedent()))
	var lines := out.split("\n")
	assert_eq(lines[0], "%d\t30.0\t40.0\t16.0\thusk\tstring\ttrue" % near.get_instance_id())
	assert_eq(lines[1], "nil\tnil\tnil\tnil\tnil\tnil\tnil", "Level I: positions only, no velocity, no hp, no speed")
	assert_eq(lines[2], "[]\tstring", "a husk has no rarity: the empty string")


func test_rarity_is_a_string_for_every_enemy_kinds_value() -> void:
	SenseBook.grant(&"enemies_in", 1)
	var cases := {
		EnemyKinds.RARITY_NONE: "",
		EnemyKinds.RARITY_COMMON: "common",
		EnemyKinds.RARITY_RARE: "rare",
		EnemyKinds.RARITY_LEGENDARY: "legendary",
		# Not an EnemyKinds value today; a future tier must not reach Lua as nil.
		9: "",
	}
	var want := PackedStringArray()
	var x := 10.0
	for rarity: int in cases:
		_body(Vector2(x, 0), EnemyKinds.DRIFTER, 4.0, rarity)
		want.append("%s:%s" % [str(x), cases[rarity]])
		x += 10.0
	# The slice's non-elites register as RARITY_NONE (regulars, husks, dummies).
	_body(Vector2(x, 0), EnemyKinds.DUMMY, 4.0, EnemyKinds.RARITY_NONE)
	want.append("%s:" % str(x))
	WorldQuery.refresh()
	var out := _out(_run("""
		for _, e in ipairs(sense.enemies_in({ x = 0, y = 0 }, 600)) do
			print(e.pos.x .. ":" .. e.rarity)
		end
	""".dedent()))
	assert_eq(out, "\n".join(want))


func test_range_is_inclusive_and_defaults_to_600() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	_body(Vector2(600, 0))
	WorldQuery.refresh()
	var out := _out(_run("""
		print(sense.nearest_enemy({ x = 0, y = 0 }) ~= nil)
		print(sense.nearest_enemy({ x = -0.5, y = 0 }) ~= nil)
		print(sense.nearest_enemy({ x = 0, y = 0 }, 599) ~= nil)
		print(sense.nearest_enemy({ x = 0, y = 0 }, 600) ~= nil)
		print(sense.nearest_enemy({ x = 0, y = 0 }, -1), sense.nearest_enemy({ x = 0, y = 0 }, 0 / 0))
		print(sense.nearest_enemy({ x = 1 / 0, y = 0 }))
	""".dedent()))
	assert_eq(out, "true\nfalse\nfalse\ntrue\nnil\tnil\nnil")


func test_nearest_enemy_level_one_clamps_range_to_600() -> void:
	# Both Level I Senses share the 600 px reach (GD, #92).
	SenseBook.grant(&"nearest_enemy", 1)
	_body(Vector2(650, 0))
	WorldQuery.refresh()
	var out := _out(_run("""
		print(sense.nearest_enemy({ x = 0, y = 0 }, 1000))
		print(sense.nearest_enemy({ x = 0, y = 0 }, 1 / 0))
		print(sense.nearest_enemy({ x = 50, y = 0 }, 1000) ~= nil)
		print(sense.nearest_enemy({ x = 49, y = 0 }, 1000))
	""".dedent()))
	assert_eq(out, "nil\nnil\ntrue\nnil", "the clamp is 600 px, inclusive, and no error")


func test_nearest_enemy_level_two_would_lift_the_clamp() -> void:
	# The API keeps the level. Nothing in the slice grants above Level I.
	SenseBook.grant(&"nearest_enemy", 2)
	_body(Vector2(650, 0))
	WorldQuery.refresh()
	assert_eq(_out(_run("print(sense.nearest_enemy({ x = 0, y = 0 }, 1000) ~= nil)")), "true")


func test_ties_go_to_the_lower_id_like_world_query() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var a := _body(Vector2(100, 0))
	var b := _body(Vector2(-100, 0))
	WorldQuery.refresh()
	var want: int = WorldQuery.nearest_enemy(Vector2.ZERO, 600.0)["id"]
	assert_eq(want, mini(a.get_instance_id(), b.get_instance_id()))
	assert_eq(_out(_run("print(sense.nearest_enemy({ x = 0, y = 0 }).id)")), str(want))


func test_bad_arguments_are_plain_errors() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	var cases := {
		"sense.nearest_enemy(5)": "sense.nearest_enemy: pos must be a table with x and y numbers",
		"sense.nearest_enemy({ x = 1 })": "sense.nearest_enemy: pos must be a table with x and y numbers",
		"sense.nearest_enemy({ x = 1, y = 2 }, 'far')": "sense.nearest_enemy: range must be a number",
		"sense.nearest_enemy({ x = 1, y = 2 }, 10, 3)": "sense.nearest_enemy: opts must be a table",
		"sense.enemies_in({ x = 1, y = 2 }, 10, { exclude = 1 })": "sense.enemies_in: opts.exclude must be a table",
		"sense.enemies_in({ x = 1, y = 2 }, 10, { filter = 1 })": "sense.enemies_in: opts.filter must be a function",
	}
	for code: String in cases:
		var r := _run(code)
		var want: String = cases[code]
		assert_false(r.ok, code)
		assert_string_contains(r.error, want, code)
		assert_string_contains(r.error, "senses.lua:2:", "the error points at the player's line: " + code)


# --- read-only ---------------------------------------------------------------

func test_results_are_read_only_snapshots() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	_body(Vector2(10, 0))
	WorldQuery.refresh()
	var writes := [
		"local e = sense.nearest_enemy({ x = 0, y = 0 })\ne.hp = 1",
		"local e = sense.nearest_enemy({ x = 0, y = 0 })\ne.pos.x = 1",
		"local e = sense.nearest_enemy({ x = 0, y = 0 })\ne.pos = { x = 0, y = 0 }",
		"local e = sense.enemies_in({ x = 0, y = 0 }, 50)[1]\ne.kind = 'warden'",
	]
	for code: String in writes:
		var r := _run(code)
		assert_false(r.ok, code)
		assert_string_contains(r.error, "sense results are read-only", code)
	var r2 := _run("local e = sense.nearest_enemy({ x = 0, y = 0 })\nrawset(e, 'kind', 'warden')")
	assert_false(r2.ok)
	assert_string_contains(r2.error, "protected table")
	var out := _out(_run("""
		local e = sense.nearest_enemy({ x = 0, y = 0 })
		print(getmetatable(e), getmetatable(e.pos))
		local keys = {}
		for k in pairs(e) do keys[#keys + 1] = k end
		table.sort(keys)
		print(table.concat(keys, ","))
		local list = sense.enemies_in({ x = 0, y = 0 }, 50)
		list[1] = nil  -- the list itself is the script's own table
		print(#list, sense.nearest_enemy({ x = 0, y = 0 }).kind)
	""".dedent()))
	assert_eq(out, "false\tfalse\nalive,id,kind,pos,radius,rarity\n0\tdrifter")


func test_sense_results_iteration_returns_the_read_only_view() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	var b := _body(Vector2(10, 0))
	WorldQuery.refresh()
	var host := _host("""
		return { on_fire = function(ctx)
			local e = sense.nearest_enemy({ x = 0, y = 0 })
			local _, s1 = pairs(e)
			local _, s2 = pairs(e.pos)
			local _, s3 = pairs(sense)
			print(rawequal(s1, e), rawequal(s2, e.pos), rawequal(s3, sense))
			local got = {}
			for k, v in pairs(e) do got[#got + 1] = k .. "=" .. type(v) end
			table.sort(got)
			print(table.concat(got, ","))
			local xs = {}
			for k, v in pairs(e.pos) do xs[#xs + 1] = k .. "=" .. tostring(v) end
			table.sort(xs)
			print(table.concat(xs, ","))
			local names = {}
			for k, v in pairs(sense) do names[#names + 1] = k .. "=" .. type(v) end
			table.sort(names)
			print(table.concat(names, ","))
			-- The iterator ignores what it is called with.
			local f = pairs(e)
			local k1 = f({}, nil)
			local k2 = f({}, nil)
			print(k1 ~= nil, k2 ~= nil, k1 ~= k2)
		end }
	""".dedent())
	assert_eq(_out(_fire(host)), "true\ttrue\ttrue\n"
		+ "alive=function,id=number,kind=string,pos=table,radius=number,rarity=string\n"
		+ "x=10.0,y=0.0\n"
		+ "enemies_in=function,nearest_enemy=function\n"
		+ "true\ttrue\ttrue")
	var writes := [
		"local e = sense.nearest_enemy({ x = 0, y = 0 })\nlocal _, t = pairs(e)\nt.id = 1",
		"local e = sense.nearest_enemy({ x = 0, y = 0 })\nlocal _, t = pairs(e.pos)\nt.x = 1",
	]
	for code: String in writes:
		var r := _run(code)
		assert_false(r.ok, code)
		assert_string_contains(r.error, "sense results are read-only", code)
	var r2 := _run("local _, t = pairs(sense)\nt.nearest_enemy = print")
	assert_false(r2.ok)
	assert_string_contains(r2.error, "sense is read-only")
	var r3 := _run("local _, t = pairs(sense.nearest_enemy({ x = 0, y = 0 }))\nrawset(t, 'id', 1)")
	assert_false(r3.ok)
	assert_string_contains(r3.error, "protected table")
	# Nothing above reached the cached results or the sense table.
	var out := _out(_run("""
		local e = sense.nearest_enemy({ x = 0, y = 0 })
		print(e.id, e.pos.x, sense.nearest_enemy == print, sense.enemies_in ~= nil)
	""".dedent()))
	assert_eq(out, "%d\t10.0\tfalse\ttrue" % b.get_instance_id())


func test_moving_enemies_resync_positions_and_a_changed_body_resyncs_everything() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var a := _body(Vector2(10, 0))
	var b := _body(Vector2(100, 0))
	WorldQuery.refresh()
	var host := _host("""
		return { on_fire = function(ctx)
			local e = sense.nearest_enemy({ x = 0, y = 0 })
			print(e.id, e.pos.x, e.pos.y, e.kind, "[" .. e.rarity .. "]", e.radius, e:alive())
		end }
	""".dedent())
	assert_eq(_out(_fire(host)), "%d\t10.0\t0.0\tdrifter\t[]\t16.0\ttrue" % a.get_instance_id())
	a.global_position = Vector2(300, 5)
	b.global_position = Vector2(50, 7)
	WorldQuery.refresh()
	assert_eq(_out(_fire(host)), "%d\t50.0\t7.0\tdrifter\t[]\t16.0\ttrue" % b.get_instance_id(), "same bodies, new positions")
	WorldQuery.register_enemy(b, EnemyKinds.HUSK, EnemyKinds.RARITY_RARE, 0, 20.0)
	WorldQuery.refresh()
	assert_eq(_out(_fire(host)), "%d\t50.0\t7.0\thusk\t[rare]\t20.0\ttrue" % b.get_instance_id(), "a re-registered body")
	WorldQuery.unregister_enemy(b)
	b.global_position = Vector2(51, 7)
	WorldQuery.refresh()
	assert_eq(_out(_fire(host)), "%d\t300.0\t5.0\tdrifter\t[]\t16.0\ttrue" % a.get_instance_id(), "a body left the set")


func test_the_same_body_is_the_same_table_within_a_snapshot() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	_body(Vector2(10, 0))
	WorldQuery.refresh()
	var host := _host("""
		local last = nil
		return { on_fire = function(ctx)
			local a = sense.nearest_enemy({ x = 0, y = 0 })
			local b = sense.nearest_enemy({ x = 5, y = 5 })
			local c = sense.enemies_in({ x = 0, y = 0 }, 100)[1]
			print(rawequal(a, b), rawequal(a, c), rawequal(a, last))
			last = a
		end }
	""".dedent())
	assert_eq(_out(_fire(host)), "true\ttrue\tfalse")
	assert_eq(_out(_fire(host)), "true\ttrue\ttrue", "no new snapshot: same table")
	WorldQuery.refresh()
	assert_eq(_out(_fire(host)), "true\ttrue\ttrue", "a snapshot where nothing moved: same table")
	_bodies[0].global_position = Vector2(12, 0)
	WorldQuery.refresh()
	assert_eq(_out(_fire(host)), "true\ttrue\tfalse", "a new snapshot builds new tables")


func test_a_body_that_dies_after_the_snapshot_is_skipped_and_reads_dead() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var near := _body(Vector2(10, 0))
	var far := _body(Vector2(200, 0))
	WorldQuery.refresh()
	var host := _host("""
		local kept = nil
		return { on_fire = function(ctx)
			local e = sense.nearest_enemy({ x = 0, y = 0 })
			if kept == nil then kept = e end
			print(e.id, kept:alive())
		end }
	""".dedent())
	assert_eq(_out(_fire(host)), "%d\ttrue" % near.get_instance_id())
	WorldQuery.unregister_enemy(near)
	assert_eq(_out(_fire(host)), "%d\tfalse" % far.get_instance_id(), "no new snapshot needed")


# --- enemies_in --------------------------------------------------------------

func test_enemies_in_is_nearest_first_and_clamps_r_to_600() -> void:
	SenseBook.grant(&"enemies_in", 1)
	var a := _body(Vector2(0, 590), EnemyKinds.WARDEN, 48.0)
	var b := _body(Vector2(100, 0), EnemyKinds.HUSK)
	_body(Vector2(650, 0), EnemyKinds.HUSK)
	WorldQuery.refresh()
	var out := _out(_run("""
		local function ids(list)
			local s = {}
			for i, e in ipairs(list) do s[i] = e.kind .. ":" .. e.id end
			return table.concat(s, ",")
		end
		print(ids(sense.enemies_in({ x = 0, y = 0 }, 1000)))
		print(ids(sense.enemies_in({ x = 0, y = 0 }, 600)))
		print(ids(sense.enemies_in({ x = 0, y = 0 }, 50)))
		print(#sense.enemies_in({ x = 0, y = 0 }))
		print(#sense.enemies_in({ x = 0 / 0, y = 0 }, 600), #sense.enemies_in({ x = 0, y = 0 }, -5))
	""".dedent()))
	var both := "husk:%d,warden:%d" % [b.get_instance_id(), a.get_instance_id()]
	assert_eq(out, "%s\n%s\n\n2\n0\t0" % [both, both])


func test_level_two_would_lift_the_clamp() -> void:
	# The API keeps the level. Nothing in the slice grants above Level I.
	SenseBook.grant(&"enemies_in", 2)
	_body(Vector2(650, 0))
	WorldQuery.refresh()
	assert_eq(_out(_run("print(#sense.enemies_in({ x = 0, y = 0 }, 1000))")), "1")


func test_exclude_by_id_or_by_entity_and_filter() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	var husk := _body(Vector2(50, 0), EnemyKinds.HUSK)
	var warden := _body(Vector2(150, 0), EnemyKinds.WARDEN, 48.0)
	var far := _body(Vector2(250, 0), EnemyKinds.DRIFTER)
	WorldQuery.refresh()
	var out := _out(_run("""
		local p = { x = 0, y = 0 }
		local first = sense.nearest_enemy(p)
		print(sense.nearest_enemy(p, 600, { exclude = { [first.id] = true } }).id)
		print(sense.nearest_enemy(p, 600, { exclude = { [first] = true } }).id)
		print(sense.nearest_enemy(p, 600, { filter = function(e) return e.kind == "drifter" end }).id)
		print(#sense.enemies_in(p, 600, { exclude = { [first] = true } }))
		local only = sense.enemies_in(p, 600, { filter = function(e) return e.kind ~= "husk" end })
		print(#only, only[1].id)
	""".dedent()))
	var w := warden.get_instance_id()
	assert_eq(out, "%d\n%d\n%d\n2\n2\t%d" % [w, w, far.get_instance_id(), w])
	assert_ne(husk.get_instance_id(), w)


func test_a_filter_error_skips_that_enemy_and_prints_one_line() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	_body(Vector2(50, 0), EnemyKinds.HUSK)
	_body(Vector2(60, 0), EnemyKinds.HUSK)
	var warden := _body(Vector2(150, 0), EnemyKinds.WARDEN, 48.0)
	WorldQuery.refresh()
	var r := _run("""
		local f = function(e)
			if e.kind == "husk" then error("no husks") end
			return true
		end
		print(sense.nearest_enemy({ x = 0, y = 0 }, 600, { filter = f }).id)
		print(#sense.enemies_in({ x = 0, y = 0 }, 600, { filter = f }))
	""".dedent())
	assert_true(r.ok, r.error)
	assert_eq(r.output.size(), 4)
	assert_string_contains(r.output[0], "sense.nearest_enemy: filter error:")
	assert_string_contains(r.output[0], "no husks")
	assert_eq(r.output[1], str(warden.get_instance_id()))
	assert_string_contains(r.output[2], "sense.enemies_in: filter error:")
	assert_eq(r.output[3], "1")


func test_enemies_in_keeps_the_nearest_256_and_notes_it_once() -> void:
	SenseBook.grant(&"enemies_in", 1)
	for i in 300:
		_body(Vector2(float(i), 0.0))
	WorldQuery.refresh()
	var host := _host("return { on_fire = function(ctx)\nlocal l = sense.enemies_in({ x = -1, y = 0 }, 600)\nprint(#l, l[1].pos.x, l[256].pos.x)\nend }")
	host.instruction_budget = 2_000_000
	var r := _fire(host)
	assert_eq(_out(r), "256\t0.0\t255.0")
	assert_eq(ScriptWarnings.count("ScriptHost.sense_list_truncated"), 1)
	assert_eq(ScriptWarnings.last_message("ScriptHost.sense_list_truncated"), "sense list truncated")


func test_lua_answers_match_world_query() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = 74
	for i in 48:
		var kind: StringName = EnemyKinds.ALL[i % EnemyKinds.ALL.size()]
		_body(Vector2(rng.randf_range(-900, 900), rng.randf_range(-900, 900)), kind, rng.randf_range(8, 48))
	WorldQuery.refresh()
	var points: Array[Vector2] = []
	for i in 24:
		# Whole-number points, so the Lua literals are exact.
		points.append(Vector2(rng.randi_range(-700, 700), rng.randi_range(-700, 700)))
	var radii := [150.0, 400.0, 600.0, 900.0]
	var lua := PackedStringArray()
	var want := PackedStringArray()
	for p in points:
		for r: float in radii:
			lua.append("q(%d, %d, %d)" % [int(p.x), int(p.y), int(r)])
			var n: Dictionary = WorldQuery.nearest_enemy(p, minf(r, 600.0))
			var ids := PackedStringArray()
			for e in WorldQuery.enemies_in_radius(p, minf(r, 600.0), 256):
				ids.append(str(e["id"]))
			want.append("%s|%s" % [str(n["id"]) if not n.is_empty() else "nil", ",".join(ids)])
	var code := """
		local function q(x, y, r)
			local n = sense.nearest_enemy({ x = x, y = y }, r)
			local ids = {}
			for i, e in ipairs(sense.enemies_in({ x = x, y = y }, r)) do ids[i] = tostring(e.id) end
			print((n and tostring(n.id) or "nil") .. "|" .. table.concat(ids, ","))
		end
	""".dedent() + "\n".join(lua)
	var host := _host("return { on_fire = function(ctx)\n%s\nend }" % code)
	host.instruction_budget = 5_000_000
	var r := _fire(host)
	assert_true(r.ok, r.error)
	assert_eq(r.output, want)


# --- homing starter, both backends -------------------------------------------

func _manager(preference: String) -> BulletManager:
	var manager := BulletManager.new()
	manager.backend_preference = preference
	manager.capacity = 64
	manager.logical_cap = 64
	manager.enemy_reserve = 0
	manager.world_bounds = Rect2(-2000, -2000, 4000, 4000)
	manager.render_enabled = false
	manager.auto_step = false
	add_child_autofree(manager)
	_mgrs.append(manager)
	return manager


## Fires the homing starter's bullet (its on_fire shape) at +x from the
## origin with a target at (240, 160), and returns where the bullet is after
## `ticks` steps of 1/60 s.
func _homing_flight(preference: String, ticks: int, src: String = "") -> Vector2:
	var manager := _manager(preference)
	var behavior := LuaBulletBehavior.new()
	behavior.host.wall_msec = 5000
	if src == "":
		src = ScriptLibrary.starter("homing").source
	var loaded := behavior.load_source(src, "homing.lua", manager, -1)
	assert_true(loaded.ok, loaded.error)
	var id := manager.register_behavior(behavior)
	var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(280.0, 0.0))
	req.lifetime = 2.5
	behavior.apply_to_request(req, id)
	assert_gte(manager.spawn(req), 0)
	for i in ticks:
		WorldQuery.refresh(DT)
		manager.step(DT)
	assert_eq(manager.backend, preference)
	assert_eq(behavior.error_total, 0, "no callback errors")
	var view := manager.gather_batch(id, DT)
	assert_eq(view.n, 1)
	return Vector2(view.px[0], view.py[0])


func _homing_on(preference: String) -> void:
	var target := _body(Vector2(240, 160), EnemyKinds.DUMMY, 22.0)
	var locked := _homing_flight(preference, 30)
	assert_almost_eq(locked.y, 0.0, 0.001, "locked: the starter flies straight")
	SenseBook.grant(&"nearest_enemy", 1)
	var homing := _homing_flight(preference, 30)
	assert_gt(homing.y, 20.0, "it turns toward the dummy")
	assert_lt(homing.distance_to(target.global_position), locked.distance_to(target.global_position))


func test_homing_starter_steers_on_the_gdscript_backend() -> void:
	_homing_on("gdscript")


func test_homing_starter_steers_on_the_native_backend() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_homing_on("native")


func test_homing_on_both_backends_lands_in_the_same_place() -> void:
	if not NativeBackend.is_available():
		pending("NativeBulletSim extension not built (scons in native/)")
		return
	_body(Vector2(240, 160), EnemyKinds.DUMMY, 22.0)
	SenseBook.grant(&"nearest_enemy", 1)
	var gd := _homing_flight("gdscript", 40)
	var nat := _homing_flight("native", 40)
	assert_almost_eq(nat.x, gd.x, 0.05)
	assert_almost_eq(nat.y, gd.y, 0.05)


func test_the_enemies_in_codex_snippet_picks_the_warden_over_a_nearer_husk() -> void:
	# §11 row 6: a script that filters kind == "warden" steers at the core
	# while a husk is nearer.
	_body(Vector2(120, -40), EnemyKinds.HUSK, 16.0)
	_body(Vector2(320, 160), EnemyKinds.WARDEN, 48.0, EnemyKinds.RARITY_COMMON)
	SenseBook.grant(&"nearest_enemy", 1)
	SenseBook.grant(&"enemies_in", 1)
	var seeker := ScriptEditorPanel.codex_source("enemies_in")
	for pref: String in ["gdscript", "native"]:
		if pref == "native" and not NativeBackend.is_available():
			continue
		var nearest := _homing_flight(pref, 20)
		assert_lt(nearest.y, -5.0, "nearest_enemy follows the husk (%s)" % pref)
		var warden := _homing_flight(pref, 20, seeker)
		assert_gt(warden.y, 5.0, "enemies_in + kind picks the Warden (%s)" % pref)


func test_the_enemies_in_codex_snippet_stays_in_budget_with_a_full_room() -> void:
	# One query per batch: 64 shots near 40 husks and the Warden run without a
	# budget stop.
	var rng := RandomNumberGenerator.new()
	rng.seed = 6
	for i in 40:
		_body(Vector2(rng.randf_range(-300, 300), rng.randf_range(-300, 300)), EnemyKinds.HUSK, 16.0)
	_body(Vector2(320, 160), EnemyKinds.WARDEN, 48.0, EnemyKinds.RARITY_COMMON)
	SenseBook.grant(&"enemies_in", 1)
	WorldQuery.refresh(DT)
	var manager := _manager("gdscript")
	var behavior := LuaBulletBehavior.new()
	behavior.host.wall_msec = 5000
	var loaded := behavior.load_source(ScriptEditorPanel.codex_source("enemies_in"), "seeker.lua", manager, -1)
	assert_true(loaded.ok, loaded.error)
	var id := manager.register_behavior(behavior)
	for i in 64:
		var req := ShotRequest.with_velocity(Vector2.ZERO, Vector2(280.0, 0.0).rotated(TAU * i / 64.0))
		req.lifetime = 2.5
		behavior.apply_to_request(req, id)
		assert_gte(manager.spawn(req), 0)
	for i in 10:
		WorldQuery.refresh(DT)
		manager.step(DT)
	assert_eq(behavior.error_total, 0, "no budget stop or error")
	assert_eq(manager.gather_batch(id, DT).n, 64)
