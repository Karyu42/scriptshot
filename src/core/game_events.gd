extends Node
## Autoload `GameEvents`: game-wide events, signals only. Nothing here keeps
## state, so listeners (Senses unlocks, HUD, save code) can come and go freely.
##
## Every argument is plain data (StringName, int, Vector2, bool): no Node is
## ever passed, so a listener can forward the values to Lua as they are.
##
## Emitters today:
##   enemy_killed  RegularEnemy death (regulars, elites, halves, adds), once per body.
##   player_died   Player death, once per death (a respawn can die again).
##   run_started   Main, when the game scene is ready.
## Reserved for the boss / run-flow PRs: boss_defeated, run_ended.

## An enemy died. `kind` is an EnemyKinds constant, `rarity` an
## EnemyKinds.RARITY_* value (RARITY_NONE for non-elites), `tier` the world tier
## of the chunk it belonged to, `position` where it died (world space).
signal enemy_killed(kind: StringName, rarity: int, tier: int, position: Vector2)
## A boss died. `boss_kind` is an EnemyKinds constant such as EnemyKinds.WARDEN.
## A boss emits this instead of enemy_killed.
signal boss_defeated(boss_kind: StringName, rarity: int, tier: int, position: Vector2)
signal run_started
signal run_ended(victory: bool)
signal player_died
