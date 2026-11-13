extends GutTest
## Senses under the G1 guard: a script that loops inside an opts.filter, or
## that asks for huge lists in a loop, is stopped by the watchdog like any
## other script. The game keeps running and the next call works.


func before_each() -> void:
	SenseBook.reset()
	WorldQuery.reset()


func after_each() -> void:
	WorldQuery.reset()
	SenseBook.reset()


func _ctx() -> ShotContext:
	var c := ShotContext.new()
	c.muzzle_position = Vector2.ZERO
	return c


func test_a_filter_that_never_returns_is_stopped() -> void:
	SenseBook.grant(&"nearest_enemy", 1)
	var b := Node2D.new()
	add_child_autofree(b)
	WorldQuery.register_enemy(b, EnemyKinds.DUMMY, EnemyKinds.RARITY_NONE, 0, 22.0)
	WorldQuery.refresh()
	var host := ScriptHost.new()
	host.wall_msec = 5000
	var r := host.load_string("""
		local stuck = true
		return { on_fire = function(ctx)
			local e = sense.nearest_enemy({ x = 0, y = 0 }, 600, {
				filter = function(e) while stuck do end return true end,
			})
			stuck = false
			print(e and e.kind)
		end }
	""".dedent(), "stuck.lua")
	assert_true(r.ok, r.error)
	var first := host.call_fire(_ctx())
	assert_false(first.ok)
	assert_eq(first.stopped, "instruction budget")
	WorldQuery.unregister_enemy(b)


func test_queries_in_a_tight_loop_hit_the_budget_not_the_frame() -> void:
	SenseBook.grant(&"enemies_in", 1)
	var nodes: Array[Node2D] = []
	for i in 64:
		var b := Node2D.new()
		add_child_autofree(b)
		b.global_position = Vector2(i * 4.0, 0.0)
		WorldQuery.register_enemy(b, EnemyKinds.DRIFTER, EnemyKinds.RARITY_NONE, 0, 16.0)
		nodes.append(b)
	WorldQuery.refresh()
	var host := ScriptHost.new()
	host.wall_msec = 5000
	var r := host.load_string("return { on_fire = function(ctx)\nwhile true do sense.enemies_in({ x = 0, y = 0 }, 600) end\nend }", "loop.lua")
	assert_true(r.ok, r.error)
	var t0 := Time.get_ticks_msec()
	var res := host.call_fire(_ctx())
	assert_false(res.ok)
	assert_eq(res.stopped, "instruction budget")
	assert_lt(Time.get_ticks_msec() - t0, 1000, "stopped by the instruction budget, quickly")
	for b in nodes:
		WorldQuery.unregister_enemy(b)
