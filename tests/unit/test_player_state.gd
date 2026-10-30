extends GutTest
## PlayerState: the validated script-facing facade.

var player: Player
var st: PlayerState


func before_each() -> void:
	player = (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	add_child_autofree(player)
	player.set_physics_process(false)
	st = player.state


func test_hp_getters_and_setters() -> void:
	assert_eq(st.get_hp(), 5.0)
	assert_eq(st.get_max_hp(), 5.0)
	assert_eq(st.set_hp(2.5), 2.5)
	assert_eq(player.health.hp, 2.5)
	assert_eq(st.set_hp(99.0), 5.0, "clamped to max")
	assert_eq(st.set_hp(NAN), 5.0, "NaN ignored")


func test_max_hp_setter() -> void:
	assert_eq(st.set_max_hp(8.0), 8.0)
	assert_eq(st.get_hp(), 5.0, "raising does not heal")
	assert_eq(st.set_max_hp(3.0), 3.0)
	assert_eq(st.get_hp(), 3.0, "hp pulled down")
	assert_eq(st.set_max_hp(NAN), 3.0)
	assert_eq(st.set_max_hp(0.0), 1.0)


func test_set_hp_zero_runs_the_normal_death() -> void:
	watch_signals(player)
	st.set_hp(0.0)
	assert_signal_emit_count(player, "died", 1)
	assert_true(st.is_dead())
	assert_false(player.visible)
	assert_eq(st.get_hp(), 0.0)


func test_invulnerability_seconds_and_bool() -> void:
	assert_false(st.is_invulnerable())
	st.set_invulnerable(2.0)
	assert_true(st.is_invulnerable())
	assert_eq(st.get_invulnerable_time(), 2.0)
	st.set_invulnerable(false)
	assert_false(st.is_invulnerable())
	st.set_invulnerable(true)
	assert_true(st.is_invulnerable())
	assert_eq(st.get_invulnerable_time(), INF)
	st.set_invulnerable(0.0)
	assert_false(st.is_invulnerable())


func test_script_invulnerability_keeps_the_hurtbox_so_piercing_hits_can_land() -> void:
	var hurtbox: Hurtbox = player.get_node("Hurtbox")
	st.set_invulnerable(true)
	assert_true(hurtbox.active, "the script layer doesn't switch the hurtbox off")
	assert_false(player.health.damage(1.0), "normal attacks are blocked at the health")
	assert_true(player.health.damage(1.0, Health.SOURCE_PIERCES_SCRIPT_INVULN))
	assert_false(hurtbox.active, "the hit's i-frames (engine layer) do switch it off")
	st.set_invulnerable(false)
	assert_false(hurtbox.active, "false doesn't cancel the engine i-frames")


func test_position_teleports_and_resets_interpolation() -> void:
	player.global_position = Vector2(10, 10)
	player._prev_position = Vector2(0, 0)
	assert_eq(st.set_position(Vector2(400, -300)), Vector2(400, -300))
	assert_eq(st.get_position(), Vector2(400, -300))
	assert_eq(player.get_render_position(), Vector2(400, -300), "no smear from the old place")
	assert_eq(player._prev_position, Vector2(400, -300))


func test_position_validation() -> void:
	st.set_position(Vector2(5, 5))
	assert_eq(st.set_position(Vector2(NAN, 0)), Vector2(5, 5), "NaN ignored")
	assert_eq(st.set_position(Vector2(INF, 0)), Vector2(5, 5), "INF ignored")
	assert_eq(st.set_position(Vector2(1.0e12, -1.0e12)), Vector2(PlayerState.MAX_COORD, -PlayerState.MAX_COORD))


func test_velocity_set_get_and_validation() -> void:
	assert_eq(st.set_velocity(Vector2(100, 0)), Vector2(100, 0))
	assert_eq(st.get_velocity(), Vector2(100, 0))
	assert_eq(st.set_velocity(Vector2(NAN, 1)), Vector2(100, 0), "NaN ignored")
	var fast := st.set_velocity(Vector2(1.0e9, 0))
	assert_almost_eq(fast.length(), PlayerState.MAX_SPEED, 0.01)


func test_dash_reads() -> void:
	assert_false(st.is_dashing())
	assert_true(st.can_dash())
	assert_eq(st.get_dash_cooldown(), 1.5)
	assert_eq(st.get_dash_cooldown_left(), 0.0)
	player.try_dash(Vector2.UP)
	assert_true(st.is_dashing())
	assert_false(st.can_dash())
	assert_eq(st.get_dash_direction(), Vector2.UP)
	assert_almost_eq(st.get_dash_cooldown_left(), 1.5, 0.001)
	assert_true(st.is_invulnerable())


func test_regen_reads() -> void:
	player.health.damage(2.0)
	assert_false(st.is_regenerating())
	player.health.tick(5.5)
	assert_true(st.is_regenerating())
	assert_almost_eq(st.get_time_since_damage(), 5.5, 0.001)


func test_aim_direction_read() -> void:
	player.aim_direction = Vector2.UP
	assert_eq(st.get_aim_direction(), Vector2.UP)


func test_a_freed_player_makes_every_call_a_harmless_no_op() -> void:
	var orphan := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	var facade := orphan.state
	orphan.free()
	assert_eq(facade.get_hp(), 0.0)
	assert_eq(facade.set_hp(3.0), 0.0)
	assert_eq(facade.set_max_hp(3.0), 0.0)
	facade.set_invulnerable(true)
	assert_false(facade.is_invulnerable())
	assert_eq(facade.set_position(Vector2.ONE), Vector2.ZERO)
	assert_eq(facade.get_position(), Vector2.ZERO)
	assert_eq(facade.set_velocity(Vector2.ONE), Vector2.ZERO)
	assert_false(facade.can_dash())
	assert_false(facade.is_dashing())
	assert_false(facade.is_dead())


func test_respawn_keeps_max_hp_and_resets_hp() -> void:
	st.set_max_hp(7.0)
	st.set_hp(0.0)
	player.respawn(Vector2(50, 50))
	assert_eq(st.get_max_hp(), 7.0)
	assert_eq(st.get_hp(), 7.0)
	assert_false(st.is_dead())
	assert_eq(st.get_position(), Vector2(50, 50))


# --- layers, speed, regeneration, dash (QA should-fix) -----------------------

func test_script_false_never_cancels_engine_iframes_through_the_facade() -> void:
	assert_true(player.try_dash(Vector2.RIGHT))
	assert_true(st.is_engine_invulnerable())
	st.set_invulnerable(false)
	assert_true(st.is_engine_invulnerable())
	assert_true(st.is_invulnerable())
	assert_false(st.is_script_invulnerable())
	assert_almost_eq(st.get_engine_invulnerable_time(), 0.2, 0.001)
	assert_eq(st.get_script_invulnerable_time(), 0.0)


func test_layer_getters_and_time_report_the_longer_layer() -> void:
	st.set_invulnerable(5.0)
	player.health.add_engine_invulnerability(0.5)
	assert_true(st.is_script_invulnerable())
	assert_true(st.is_engine_invulnerable())
	assert_eq(st.get_invulnerable_time(), 5.0)
	assert_eq(st.get_script_invulnerable_time(), 5.0)
	assert_eq(st.get_engine_invulnerable_time(), 0.5)


func test_speed_setter_clamps_and_drives_the_player() -> void:
	assert_eq(st.get_speed(), 300.0)
	assert_eq(st.set_speed(450.0), 450.0)
	assert_eq(player.max_speed, 450.0)
	assert_eq(st.set_speed(-5.0), 0.0)
	assert_eq(st.set_speed(1.0e9), PlayerState.MAX_SPEED)
	assert_eq(st.set_speed(NAN), PlayerState.MAX_SPEED, "NaN ignored")
	assert_eq(st.set_speed(INF), PlayerState.MAX_SPEED)


func test_regen_setters_clamp_and_validate() -> void:
	assert_eq(st.get_regen_delay(), 5.0)
	assert_eq(st.get_regen_interval(), 3.0)
	assert_eq(st.get_regen_amount(), 1.0)
	assert_eq(st.set_regen_delay(2.0), 2.0)
	assert_eq(st.set_regen_interval(1.5), 1.5)
	assert_eq(st.set_regen_amount(2.0), 2.0)
	assert_eq(player.health.regen_delay, 2.0)
	assert_eq(st.set_regen_delay(-1.0), 0.0)
	assert_eq(st.set_regen_interval(0.0), 0.05, "an interval of 0 would heal every tick")
	assert_eq(st.set_regen_amount(-3.0), 0.0, "0 turns regeneration off")
	assert_eq(st.set_regen_amount(99.0), 5.0, "at most max_hp")
	assert_eq(st.set_regen_delay(NAN), 0.0, "NaN keeps the current value")
	assert_eq(st.set_regen_interval(NAN), 0.05)
	assert_eq(st.set_regen_amount(NAN), 5.0)
	assert_eq(st.set_regen_delay(1.0e9), PlayerState.MAX_REGEN_SECONDS)


func test_regen_setters_change_how_the_player_heals() -> void:
	st.set_regen_delay(0.5)
	st.set_regen_interval(0.25)
	st.set_regen_amount(2.0)
	player.health.damage(4.0)
	assert_eq(player.health.hp, 1.0)
	player.health.tick(0.6)
	assert_eq(player.health.hp, 3.0, "first step after 0.5 s")


func test_dash_by_angle_is_the_dash_button_action() -> void:
	assert_true(st.dash(0.0))
	assert_true(player.is_dashing())
	assert_almost_eq(player.get_dash_direction().x, 1.0, 0.0001)
	assert_false(st.dash(0.0), "obeys the cooldown")


func test_dash_by_angle_direction_and_bad_angles() -> void:
	assert_false(st.dash(NAN))
	assert_false(st.dash(INF))
	assert_false(player.is_dashing())
	assert_true(st.dash(-PI / 2.0))
	assert_almost_eq(player.get_dash_direction().y, -1.0, 0.0001, "angle -90 deg is up")


func test_dash_by_angle_is_refused_while_dead() -> void:
	st.set_hp(0.0)
	assert_false(st.dash(0.0))
