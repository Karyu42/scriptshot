extends GutTest
## RespawnPoints autoload: origin fallback, last cleared arena wins, validation.


func before_each() -> void:
	RespawnPoints.reset()
	watch_signals(RespawnPoints)


func after_each() -> void:
	RespawnPoints.reset()


func test_autoload_is_registered() -> void:
	assert_not_null(get_tree().root.get_node_or_null("RespawnPoints"))


func test_falls_back_to_the_origin_when_nothing_was_cleared() -> void:
	assert_eq(RespawnPoints.get_respawn_position(), Vector2.ZERO)
	assert_false(RespawnPoints.has_checkpoint())
	assert_eq(RespawnPoints.get_arenas_cleared(), 0)


func test_a_cleared_arena_becomes_the_respawn_point() -> void:
	assert_true(RespawnPoints.register_arena_cleared(Vector2(640, -320)))
	assert_eq(RespawnPoints.get_respawn_position(), Vector2(640, -320))
	assert_true(RespawnPoints.has_checkpoint())
	assert_eq(RespawnPoints.get_arenas_cleared(), 1)
	assert_signal_emitted_with_parameters(RespawnPoints, "respawn_position_changed", [Vector2(640, -320)])


func test_the_last_cleared_arena_wins() -> void:
	RespawnPoints.register_arena_cleared(Vector2(1, 1))
	RespawnPoints.register_arena_cleared(Vector2(2, 2))
	RespawnPoints.register_arena_cleared(Vector2(3, 3))
	assert_eq(RespawnPoints.get_respawn_position(), Vector2(3, 3))
	assert_eq(RespawnPoints.get_arenas_cleared(), 3)


func test_an_arena_at_the_origin_still_counts_as_a_checkpoint() -> void:
	RespawnPoints.register_arena_cleared(Vector2.ZERO)
	assert_true(RespawnPoints.has_checkpoint())


func test_set_checkpoint_moves_the_respawn_without_counting_an_arena() -> void:
	assert_true(RespawnPoints.set_checkpoint(Vector2(50, 60)))
	assert_eq(RespawnPoints.get_respawn_position(), Vector2(50, 60))
	assert_eq(RespawnPoints.get_arenas_cleared(), 0)


func test_reset_returns_to_the_origin_and_clears_the_count() -> void:
	RespawnPoints.register_arena_cleared(Vector2(9, 9))
	RespawnPoints.reset()
	assert_eq(RespawnPoints.get_respawn_position(), Vector2.ZERO)
	assert_false(RespawnPoints.has_checkpoint())
	assert_eq(RespawnPoints.get_arenas_cleared(), 0)
	assert_signal_emitted_with_parameters(RespawnPoints, "respawn_position_changed", [Vector2.ZERO])


func test_reset_without_a_checkpoint_is_silent() -> void:
	RespawnPoints.reset()
	assert_signal_not_emitted(RespawnPoints, "respawn_position_changed")


func test_non_finite_positions_are_ignored() -> void:
	RespawnPoints.register_arena_cleared(Vector2(7, 7))
	assert_false(RespawnPoints.register_arena_cleared(Vector2(NAN, 0)))
	assert_false(RespawnPoints.set_checkpoint(Vector2(0, INF)))
	assert_eq(RespawnPoints.get_respawn_position(), Vector2(7, 7))
	assert_eq(RespawnPoints.get_arenas_cleared(), 1)
