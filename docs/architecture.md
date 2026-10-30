# Scriptshot architecture (Godot core)

Scriptshot is a top-down twin-stick shooter where the player writes their own
shots in Lua. This document describes the Godot core and, in particular, the
**shot interface**: the boundary the Lua shot scripts drive. The Lua binding
itself lives in `scripting/` and is not part of the core.

```
 input ──► Player ──► ShotPattern.fire(ShotContext, ShotEmitter)
                            │                        (Lua script plugs in here)
                            ▼
                 ShotEmitter.request_shot(ShotRequest)
                            │
                            ▼
   BulletManager ── BulletPool (struct-of-arrays) ──► BulletRenderer (1 MultiMesh)
        │   ▲              ▲
        │   └ hooks ───────┘  BulletBehavior.on_spawn/on_update/on_hit/on_despawn
        ├──► WallGrid (static rects, swept) ──► bullet despawns with reason WALL
        └──► HurtboxGrid (spatial hash, swept) ──► Hurtbox.hit signal
```

## Folder layout

| Path | Contents |
| --- | --- |
| `src/core/` | Cross-cutting types: `Layers`, the shot interface (`ShotRequest`, `ShotEmitter`, `ShotContext`, `ShotPattern`, `BulletBehavior`), `Health`, `InputDevice` and `RespawnPoints` autoloads, `Main` sandbox scene script |
| `src/player/` | `Player`, `MovementMath`, `AimMath`, `FireCooldown`, `TriggerState`, `AimReticle`, `BasicShot` (default weapon), `DashMath` / `DashState` (dash), `PlayerState` (script-facing facade) |
| `src/bullets/` | `BulletPool`, `BulletManager`, `BulletRenderer`, `HurtboxGrid`, `WallGrid`, `Hurtbox`, `Reflector`, `BulletShotEmitter`, `BulletStressTest` |
| `src/enemies/` | Enemies: `TrainingDummy`, `Turret` (aims at and shoots the player), `Mirror` (reflects the player's bullets) |
| `src/world/` | Arena drawing / world pieces |
| `src/camera/` | `FollowCamera`, `CameraMath` |
| `src/fx/` | Reserved for effects (hit flashes, particles, shake sources) |
| `scenes/` | `main.tscn` (playable sandbox), `player.tscn`, `training_dummy.tscn`, `turret.tscn`, `mirror.tscn` |
| `tests/unit/` | GUT unit and smoke tests |
| `tests/benchmark/` | Headless bullet benchmark |
| `scripting/` | Reserved for the Lua side. The core never depends on it |
| `addons/gut/` | Vendored GUT 9.7.1 |

## Physics layers

Named in `project.godot` and mirrored as bit constants in `Layers`
(`src/core/layers.gd`):

| Layer | Bit | Name | Used for |
| --- | --- | --- | --- |
| 1 | `Layers.PLAYER` = 1 | `player` | player body and its hurtbox |
| 2 | `Layers.ENEMY` = 2 | `enemy` | enemies and their hurtboxes |
| 3 | `Layers.PLAYER_BULLET` = 4 | `player_bullet` | reserved (bullets are not physics objects) |
| 4 | `Layers.ENEMY_BULLET` = 8 | `enemy_bullet` | reserved |
| 5 | `Layers.WORLD` = 16 | `world` | static walls (the player collides with these; bullets are stopped by them, see `WallGrid`) |

A bullet's `hit_mask` is a combination of these bits: the factions it can damage.

## The shot interface (boundary for Lua)

Anything that fires shots -- the player's weapon today, Lua scripts tomorrow --
uses only these types. All of them are plain `RefCounted` classes with typed
fields, so a binding can create, fill and pass them without touching engine
internals.

### `ShotRequest` -- one bullet to spawn

Plain data (`src/core/shot_request.gd`). A request is copied on spawn and never
retained, so one instance can be mutated and re-submitted any number of times.
`reset()` restores defaults.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `position` | `Vector2` | `(0,0)` | World-space spawn position, pixels |
| `velocity` | `Vector2` | `(0,0)` | Initial velocity, px/s. Held to `BulletLimits.MAX_SPEED` (4,000 px/s), direction kept; NaN/inf rejects the shot |
| `angle` | `float` | `NAN` | Visual orientation, radians. `NAN` = face along `velocity` |
| `lifetime` | `float` | `2.0` | Seconds until the bullet despawns by itself |
| `radius` | `float` | `4.0` | Collision and draw radius, px |
| `damage` | `float` | `1.0` | Passed to `Hurtbox.hit` on impact. A reflected bullet deals 1 instead (see "reflecting bullets") |
| `owner_layer` | `int` | `Layers.PLAYER` | Faction that fires the bullet (`PLAYER` or `ENEMY`). Its own layer is always removed from `hit_mask` on spawn, so **a bullet can never hurt whoever fired it**. `0` = unowned, nothing stripped |
| `hit_mask` | `int` | `Layers.ENEMY` | Layers it can hit; `0` = decorative, hits nothing |
| `color` | `Color` | warm yellow | Flat draw colour |
| `behavior_id` | `int` | `0` | Id from `register_behavior()`; `0` = plain bullet (fast path, no hooks). A reflection resets it to `0` |
| `can_hit_veto` | `bool` | `false` | Opt in to `BulletBehavior.can_hit()` before each hit lands (see "Hit veto"). Needs `behavior_id != 0` |
| `pierces_script_invuln` | `bool` | `false` | A "piercing" attack: ignores the player's *script* invulnerability (never the engine i-frames), see "Health" |
| `acceleration` | `float` | `0.0` | px/s^2 along the heading (negative brakes, never reverses) |
| `turn_rate` | `float` | `0.0` | Heading change in rad/s (curving shots) |
| `pierce` | `int` | `0` | Extra targets to pass through before despawning |
| `collide_world` | `bool` | `true` | Stop at `world` walls (despawn reason `WALL`). `false` = fly through walls |
| `param_a`, `param_b` | `float` | `0.0` | Free scratch values for behaviour hooks |
| `user` | `Variant` | `null` | Arbitrary per-bullet script state; hooks see it as `pool.user[index]`. The reference is copied, not the contents. Reset to `null` when the bullet despawns |

Helpers: `ShotRequest.polar(position, heading_radians, speed)` and
`ShotRequest.with_velocity(position, velocity)`.

Straight-line, accelerating and constant-curve bullets are handled by the
vectorised core loop with **no script call per bullet**. Use hooks only when a
bullet needs logic the built-in kinematics cannot express.

### `ShotEmitter` -- where requests go

Abstract base (`src/core/shot_emitter.gd`); the game provides
`BulletShotEmitter`. Shooters never see `BulletManager` or `BulletPool`.

```gdscript
func request_shot_id(request: ShotRequest) -> int     # stable bullet id (> 0), or -1 if pool full
func request_child_shot_id(parent_id, request) -> int  # spawn a child of a live bullet: owner comes from the parent, see "Speed ceiling and owner inheritance"
func request_shot(request: ShotRequest) -> bool       # same, bool: false = pool full, shot dropped
func request_shots(requests: Array) -> int            # returns number accepted
func is_bullet_alive(id: int) -> bool                 # false for stale / invalid ids
func get_dropped_count() -> int                       # shots dropped, any reason (cumulative)
func get_dropped_count_by_owner(owner_layer) -> int   # ... by who fired them (PLAYER / ENEMY / 0 = unowned)
func get_dropped_count_by_limit(limit) -> int         # ... by BulletPool.DropLimit.LOGICAL_CAP / ENEMY_RESERVE
func is_saturated(owner_layer := Layers.PLAYER) -> bool   # a shot from this side would be dropped right now
func get_headroom(owner_layer := Layers.PLAYER) -> int    # how many more shots from this side fit right now
signal pool_saturated(dropped_now: int, dropped_total: int)
func register_behavior(behavior: BulletBehavior) -> int   # id for ShotRequest.behavior_id
func reflect_bullet(id, new_owner_layer, reverse := false, new_damage := 1.0, keep_script := false) -> bool  # see "reflecting bullets"
func get_bullet_count() -> int                        # all live bullets
func get_owner_count(owner_layer) -> int              # live bullets of PLAYER / ENEMY (incl. bosses) / 0 = unowned
func get_capacity() -> int                            # physical pool size (memory)
func get_logical_cap() -> int                         # max live bullets allowed (default 10,000)
func get_enemy_reserve() -> int                       # slots only enemies / bosses may use (default 3,000)
func get_wall_normal(id: int) -> Vector2              # normal of the wall this bullet hit this tick, else ZERO
```

See "Saturation model" below for the cap, the reserve and the counters.

Spawning is immediate and synchronous: the bullet exists when the call returns,
`on_spawn` has run, and it is first simulated on the next physics tick. Spawning
from inside a hook is allowed.

### Stable bullet ids

Pool slots move: despawning swaps the last bullet into the freed slot. To refer
to a bullet across ticks, keep its **id** instead of its slot.

* `ShotEmitter.request_shot_id()` returns the new bullet's id; inside hooks use
  `pool.id_of(index)`.
* An id packs `(generation << 32) | handle`. `handle` indexes an indirection table
  (`handle -> current slot`); `generation` is bumped whenever a handle is released,
  so an id whose bullet is gone is detected even after its handle was reused by a
  newer bullet. Ids are always `> 0`; `-1` means "no bullet".
* `pool.slot_of(id) -> int` returns the current slot or `-1` if stale/invalid
  (a bullet marked dead but not yet flushed still has a slot);
  `pool.is_alive(id) -> bool` is false once a bullet is marked dead or removed.
  Resolve an id to a slot, use it, and drop the slot before the next despawn.
* Per-bullet script state goes in `ShotRequest.user` / `pool.user[index]`: it moves
  with the bullet on swap-remove and is reset to `null` on despawn.

### `ShotContext` + `ShotPattern` -- the weapon / script entry point

Two entry points, both optional:

* `ShotPattern.update(context, emitter, delta)` runs **every physics tick while the
  pattern is equipped**, before `fire()`. It sees the aim, the muzzle and the
  trigger state, so charge, channel and burst weapons can emit shots themselves.
* `ShotPattern.fire(context, emitter)` is called by the player whenever the trigger
  is held and `fire_interval` seconds have passed since the last call. This is the
  simple "hold to autofire" path and works exactly as before.

`ShotPattern.auto_fire` (default `true`) controls the second path: set it to
`false` for patterns that drive everything from `update()`; the player then never
calls `fire()` and `fire_interval` is ignored.

A Lua binding provides a `ShotPattern` subclass that forwards `update()` / `fire()`
to Lua functions.

`ShotContext` (read-only for patterns):

| Field | Meaning |
| --- | --- |
| `muzzle_position` | World-space spawn point (shooter origin + muzzle offset along aim) |
| `aim_direction`, `aim_angle` | Unit vector / radians |
| `shooter_velocity` | Shooter's current velocity, px/s |
| `target_mask` | Layers the shot should be able to hit (set `ShotRequest.hit_mask` from it) |
| `time` | Seconds since the shooter was created |
| `shot_index` | Number of `fire()` calls so far |
| `trigger_pressed` | Fire button is down this tick |
| `trigger_just_pressed` / `trigger_just_released` | Edge flags, true for exactly one tick |
| `trigger_held_time` | Seconds held continuously, counting this tick. On the release tick it still holds the length of the hold that just ended (that is when a charge weapon reads it); `0` on later ticks |

Charge weapon sketch (see `tests/unit/test_weapon_update.gd`):

```gdscript
class_name ChargeShot extends ShotPattern
func _init() -> void:
    auto_fire = false
func update(ctx: ShotContext, emitter: ShotEmitter, _delta: float) -> void:
    if ctx.trigger_just_released:
        var r := ShotRequest.polar(ctx.muzzle_position, ctx.aim_angle, 400.0)
        r.damage = ctx.trigger_held_time * 4.0
        emitter.request_shot(r)
```

Minimal example (`src/player/basic_shot.gd`):

```gdscript
func fire(context: ShotContext, emitter: ShotEmitter) -> void:
    var r := ShotRequest.polar(context.muzzle_position, context.aim_angle, 760.0)
    r.hit_mask = context.target_mask
    emitter.request_shot(r)
```

### `BulletBehavior` -- per-bullet hooks

Subclass, override what you need, register once, reference by id
(`src/core/bullet_behavior.gd`). `index` is the bullet's slot in the pool and is
**only valid during the call** (slots are swapped when other bullets despawn).
Read and write the pool's arrays directly: `pool.pos[index]`, `pool.vel[index]`,
`pool.rot[index]`, `pool.age[index]`, `pool.lifetime[index]`, `pool.color[index]`,
`pool.param_a[index]`, `pool.pierce[index]`, `pool.user[index]`, ...

| Hook | When |
| --- | --- |
| `on_spawn(pool, index)` | Right after the bullet is created |
| `on_update(pool, index, delta)` | Every physics tick after integration, while alive (never for a bullet that already died this tick). Velocity/heading changes apply from the next tick |
| `can_hit(pool, index, hurtbox) -> bool` | Only for bullets spawned with `can_hit_veto = true`: asked just before a hit lands. `false` vetoes it, see "Hit veto" |
| `on_hit(pool, index, hurtbox)` | Contact with a hurtbox, after the hurtbox's own `hit` signal and before the bullet is despawned (or its `pierce` decremented). Not called for a bullet that is already dead |
| `on_despawn(pool, index, reason)` | Just before removal, exactly once per bullet (also for bullets another hook marked dead; not for ones already removed). `reason` is a `BulletPool.DespawnReason`: `LIFETIME`, `BOUNDS`, `HIT`, `MANUAL`, `CLEARED`, `WALL`, `INVALID` (values are append-only; `INVALID` = killed for a non-finite NaN/inf write by the batch API) |

`behavior.emitter` is set at registration so hooks can spawn child bullets
(splitting, trails). A child spawned from a hook **inherits the owner of the
bullet whose hook spawned it**, whatever `ShotRequest.owner_layer` says. A
velocity written to `pool.vel[index]` is held to the speed ceiling (NaN / inf kills
the bullet as `INVALID`). Both are described in "Speed ceiling and owner
inheritance". To remove a bullet from a hook call `pool.mark_dead(index)`.

### Guarantees and limits

* Simulation runs on the fixed 60 Hz physics tick, in a fixed order:
  collect hurtboxes -> integrate (lifetime, bounds) -> `on_update` ->
  wall sweep (bullets are clipped to the wall) -> hurtbox sweep ->
  `on_hit` / hurtbox signals -> mark `WALL` -> `on_despawn` -> removal -> render
  upload. The first despawn reason of a bullet wins (a hurtbox in front of a
  wall is hit; the wall is not reached). Given the same requests, hurtbox
  positions and tick count the result is deterministic.
* `BulletManager` runs at `process_physics_priority = 100`
  (`BulletManager.PHYSICS_PRIORITY`), after the default-priority nodes (player,
  enemies). A bullet spawned by the player this tick is integrated and rendered
  this tick; it is not a tick late.
* Capacity is fixed (`BulletManager.capacity`, default 16384) and the game allows
  fewer live bullets than that (`logical_cap`, default 10,000, plus an enemy
  reserve: see "Saturation model"). A pool at its limit drops new shots; it
  never allocates. Drops are observable: `get_dropped_count()` (and the per-owner
  / per-limit variants), `is_saturated()`, the `pool_saturated` signal (at most
  once per tick, with the number dropped that tick and the total) and a
  `push_warning` rate-limited by `BulletManager.saturation_warning_interval`
  (simulated seconds, default 2) that says which limit was hit and whose shots
  were dropped.
* Bullets leave the simulation when they exit `BulletManager.world_bounds`.
* Collision is **swept**: a bullet is the segment from where it was at the start
  of the tick (`pool.prev_pos`) to where it is now, so fast bullets do not
  tunnel through thin hurtboxes or walls. Impact positions passed to
  `Hurtbox.hit` are the actual contact points.
* Bullets collide with `world` walls by default and despawn there with reason
  `WALL`; `on_despawn` still fires, and can read the wall's **surface normal**
  with `BulletManager.wall_normal_of(slot)` / `ShotEmitter.get_wall_normal(id)`
  (see "Wall normals"). Opt out per bullet with
  `ShotRequest.collide_world = false`. Walls are axis-aligned rectangles:
  `BulletManager.add_wall(Rect2)` / `clear_walls()`, plus every
  `CollisionShape2D` with a `RectangleShape2D` under a node in the
  `world_walls` group (the main scene's `Walls` body; collected at `_ready`).
  Piercing bullets are still stopped by walls. A bullet spawned inside a wall
  despawns at once. Other shapes under a wall body are **ignored** and rotated
  rectangles are approximated by their axis-aligned bounding box;
  `collect_walls()` pushes a warning naming the node for either case.
* A bullet hits **every** target on its path that its `pierce` allows in one
  tick: `pierce = n` can hit up to `n + 1` targets per tick, in path order, each
  at most once. After a piercing hit the bullet is re-swept from the impact
  point, ignoring targets already hit. Of several targets on the path the
  **nearest** one wins, regardless of which grid cell it is registered in. (A
  piercing bullet only remembers the last target it hit across ticks, so it can
  hit a target it is still overlapping again if it overlaps two at once.)
* A bullet that leaves `world_bounds` this tick is flagged `BOUNDS` before
  collision, but still tests the part of its path inside the bounds; if it hits a
  wall or hurtbox on the way, that is its despawn reason instead.
* Targets are bucketed with the largest bullet radius known at the start of the
  tick. If a hook spawns a bullet with a bigger radius than that, the targets are
  re-bucketed before collision, so the new bullet does not miss.
* **Moving a bullet from a hook.** A bullet is the segment `prev_pos -> pos`,
  both for collision and for render interpolation. Steering through `vel` (or
  `acceleration` / `turn_rate`) needs nothing special. To move a bullet
  *discontinuously* (teleport, warp, portal, respawn at a new place), call
  `pool.teleport(index, position)`: it sets `pos` and `prev_pos` together, so the
  jump is neither swept (no phantom hits or wall hits along it) nor interpolated
  (no streak). Writing `pool.pos[index]` directly leaves `prev_pos` at the old
  place and the bullet counts as having flown there this tick.
* The bullet is drawn interpolated, i.e. up to one tick behind the simulation,
  and a bullet that is removed on a tick (hit, wall, lifetime) is not drawn on
  that tick at all. So a shot vanishes up to one 60 Hz tick (about 17 ms, ~13 px
  at 760 px/s) before it visually reaches the impact point. Known and accepted:
  drawing the impact would need a one-tick ghost list in the renderer for a
  difference that is hard to see.
* Hook calls are the expensive path: every hooked bullet costs at least one
  script call per tick (plus whatever the hook does), whereas bullets with
  `behavior_id == 0` never call script code. The 5k/10k benchmark numbers are
  for plain bullets.
* Nothing is allocated in the per-tick hot path (scratch arrays are preallocated
  and grow only when capacity does; hurtboxes register in `Hurtbox.registry`
  instead of a group query), and a hook may spawn/kill bullets freely.
* Performance target: **10,000 bullets at p95 <= 16.6 ms** of CPU work per
  frame with walls and hurtboxes present, measured by
  `./tools/run_benchmark.sh`. Policy: the **5,000-bullet floor** (`--floor-bullets`)
  is a hard gate (non-zero exit if it misses the budget or is not reached); the
  **10,000-bullet target** (`--target-bullets`) only prints a `WARN` line and the
  run still exits 0, because 10k p95 depends on how busy the machine is.

## Saturation model (PROVISIONAL, not decided by Karyu)

Chief of Staff's decision: a logical cap of 10,000 live bullets plus a reserve
that only enemy and boss shots can use, independent of the physical pool size.
The numbers below are **provisional defaults, configurable, and not decided by
Karyu**.

| Setting | Default | Where |
| --- | --- | --- |
| Physical pool (memory) | 16,384 | `BulletManager.capacity` (unchanged) |
| Logical cap: most live bullets, whoever owns them | **10,000** (clamped to `capacity`) | `BulletManager.logical_cap`, `set_bullet_limits()` |
| Enemy reserve: slots only enemy/boss bullets may take | **3,000** (`-1` = 30% of the cap; the player's share is at most 7,000, the pillars doc's B2 split) | `BulletManager.enemy_reserve`, `set_bullet_limits()` |

Rules (`BulletPool.spawn` / `spawn_simple`, O(1), no allocation):

* A shot from an **enemy or boss** (`owner_layer` has `Layers.ENEMY`) is accepted
  while `count < logical_cap`.
* A shot from **anyone else** (player, unowned) is accepted while
  `count < logical_cap - enemy_reserve`.

So player scripts can fill the pool up to `cap - reserve` and no further: the
last `reserve` slots are always there for enemy attacks, however many bullets a
script spawns. The reverse is not true: a screen full of enemy bullets (up to
the cap) leaves the player no room, because the player's limit is a *total*, not
a share. Boss bullets use `Layers.ENEMY` too (there is no separate boss layer);
a bullet owned by both bits counts as the player's, like `Layers.hostile_to()`.

Lowering the cap at runtime (`set_bullet_limits`) never removes bullets; it only
refuses new ones until enough have despawned. A reflected bullet keeps its slot,
so a reflection is never refused. The benchmark lifts both limits
(`logical_cap = capacity`, `enemy_reserve = 0`) so it can measure any count.

**Per-owner live counters.** `pool.owner_counts[]` (indexed `OWNER_NONE` /
`OWNER_PLAYER` / `OWNER_ENEMY`) is updated in O(1) by spawn, removal (swap-remove
included), `reflect()` (an owner change moves the count) and `clear()`. A bullet
marked dead but not yet flushed still holds its slot and still counts. Read it
with `pool.owner_count(layer)` or `ShotEmitter.get_owner_count(layer)`. Code
that writes `pool.owner_layer[i]` directly bypasses the counters; use
`reflect()`, or call `pool.recount_owners()` afterwards (`counters_consistent()`
checks it in tests). The debug HUD shows `bullets N / cap (player P, enemy E, dropped D)`.
Counters are per owner side only: there is no per-emitter-id counter, because
requests carry no emitter id today (it would cost an extra array moved on every
swap-remove); a script can count its own shots through `request_shot_id`.

**Drops stay observable.** `get_dropped_count()` is the total;
`get_dropped_count_by_owner(layer)` splits it by who fired, and
`get_dropped_count_by_limit(BulletPool.DropLimit.X)` by which limit refused the
shot: `LOGICAL_CAP` (the pool held the maximum) or `ENEMY_RESERVE` (there was
room, but only for enemies). Both splits sum to the total. `is_saturated(layer)`
and `get_headroom(layer)` answer "would my next shot be dropped" and "how many
more fit" for a given side (default: the player, which is what scripts fire as).
The `pool_saturated(dropped_now, dropped_total)` signal and the rate-limited
warning are unchanged in shape; the warning text now names the limit and the
owners.

## Wall normals

Every wall hit also carries the wall's surface normal: a unit vector pointing out
of the wall, the face of the (radius-inflated) wall the bullet's path entered
through. `WallGrid.normal_of_hit(k, pool)` returns it for hit `k` (parallel to
`hit_bullets[k]` / `hit_t[k]`) and `WallGrid.last_normal` belongs to `first_hit()`. Scripts get it during the
tick the bullet hit: `BulletManager.wall_normal_of(slot)` or
`ShotEmitter.get_wall_normal(bullet_id)` inside `on_despawn` with reason `WALL`
(`Vector2.ZERO` if the bullet did not hit a wall this tick, and after removal).
It is computed on demand from the stored wall index and path (a bullet that hit
a wall stores two values; the normal itself is only worked out when a script asks),
so the sweep pays nothing for it.

Corner rules, so results are deterministic: a path that enters two faces at the
same instant (a perfectly diagonal approach into a corner) takes the face on the
axis it moves faster along, and the x face on an exact tie; two walls reached at
the same instant: the one added first; a bullet that starts inside a wall is
pushed out through the nearest face (ties: left, right, top, bottom).

## Hit veto (`can_hit`)

A bullet spawned with `ShotRequest.can_hit_veto = true` and a `behavior_id`
asks its behaviour `can_hit(pool, index, hurtbox)` right before a hit lands,
before any damage, `on_hit` or pierce bookkeeping. Returning `false` makes the
bullet ignore that target: no damage, no `hit` signal, no `on_hit`, `pierce` is
not used, and the bullet is not consumed. It is asked again next tick while it
still overlaps (the piercing "last hit" memory is only set by hits that landed).

Cost: bullets without the flag are never asked. The manager reads one flag byte
per *hit* (not per bullet per tick); the collision loop reads the flag only while
at least one flagged bullet is alive (`pool.veto_count`). Flagged bullets sweep
their path and list up to `BulletPool.VETO_MAX_HITS` (4) hits, so a vetoed
target does not hide the next one behind it; a fifth consecutive veto would.
Reflection clears the flag together with the rest of the script state
(`keep_script` keeps it).

## Speed ceiling and owner inheritance

Two guards on everything scripts can write. Neither is a design limit.

### Bullet speed ceiling: 4,000 px/s

`main` did **not** enforce a ceiling before this change (swept collision removed
the old need for one, nothing replaced it). The value lives in one place,
`BulletLimits.MAX_SPEED` (`src/core/bullet_limits.gd`); the native backend mirrors
that constant instead of defining its own. A velocity above it keeps its
direction and is cut to the ceiling at every write the engine can see:

| Write path | What happens |
| --- | --- |
| `BulletPool.spawn` / `spawn_simple` (so `ShotRequest.velocity`, `polar`, `with_velocity`) | clamped; `rot` follows the clamped direction |
| `BulletPool.set_velocity(slot, v)` (the one call for batch/Lua commits and hooks) | clamped; returns false for a dead slot |
| `Reflector` (`speed_multiplier` up to 20x) | the new speed is capped, direction is the mirror's |
| `BulletPool.reflect(..., reverse)` | only flips the sign, speed unchanged |
| `acceleration` | speed stops growing at the ceiling |
| a hook writing `pool.vel[index]` in `on_spawn` / `on_update` / `on_hit` | the manager re-checks that bullet right after the hook returns (hooked bullets only, so plain bullets pay nothing): clamped before the bullet moves |

A non-finite value is not clamped, it is **invalid**: a shot with a NaN/inf
position or velocity is rejected at spawn (returns -1, counted in
`BulletPool.invalid_total`, not in the capacity drop counters); a live bullet
whose velocity became NaN/inf is killed with `DespawnReason.INVALID`
(its `on_despawn` runs, no damage) and counted too. Both raise a capped warning
(`ScriptWarnings`). Direct writes to `pool.vel[]` of a bullet *without* a hook
cannot be seen; scripts must use `set_velocity` (the batch API does). Swept
collision means a bullet at the ceiling (66.7 px per tick) cannot tunnel.

### Owner inheritance for hook-spawned bullets

A bullet spawned from a hook (`on_spawn`, `on_update`, `on_hit`, `on_despawn` of a
`BulletBehavior`, through `emitter.request_shot_id()`) takes `owner_layer` from the
**bullet whose hook spawned it**. It never comes from the behavior record or from
a field the script passes: the only way to change an owner is `reflect`, which is
guarded by `max_reflections`; if a script could choose the owner of what it
spawns it could mint enemy-owned bullets around that guard.

* The child's `hit_mask` is the standard "hostile to the owner" mask when the
  owner was replaced; when the request already names the parent's owner its own
  mask is honoured (the pool strips the owner's layer, as always).
* If the request names another owner, it is ignored and one warning per key is
  raised through `ScriptWarnings` (printed at most `ScriptWarnings.LIMIT` times).
  A request that still carries the default owner (`Layers.PLAYER`) cannot be told
  from "not set", so for an enemy parent it is corrected silently.
* Children of children follow the same rule; children count against the
  *parent's* faction limits (see "Saturation model"), so a player bullet cannot
  spawn into the enemy reserve.
* Spawns outside any hook (a turret, a boss emitter, the player's weapon) are
  unchanged: the request's owner is used.
* `ShotEmitter.request_child_shot_id(parent_id, request)` /
  `BulletManager.spawn_child()` is the path for spawns that run **after** the hook
  returned (the batch/Lua commit resolves its `row` to the parent's stable id and
  calls it). A parent that is marked dead but not yet removed still works; a gone
  parent (stale id) refuses the spawn and warns, because there is no owner to
  inherit.

## Bullet system design

* **`BulletPool`** (`src/bullets/bullet_pool.gd`): struct-of-arrays in packed
  arrays (`PackedVector2Array pos/vel/rot`, `PackedFloat32Array
  radius/age/lifetime/...`, `PackedColorArray color`, `PackedInt32Array
  hit_mask/behavior/pierce`, `prev_pos` = position at the start of the tick,
  `collide_world`). Alive bullets are always the dense range
  `[0, count)`; despawn is a swap-remove, so slots are recycled with zero
  allocation and iteration never touches dead data. Removal is deferred
  (`mark_dead` / `flush_dead`) so hooks and collision can run on a stable set.
* **`BulletRenderer`**: one `MultiMeshInstance2D`, one quad mesh, one shader
  (`bullet.gdshader` draws an anti-aliased disc). One draw call regardless of
  count. The simulation runs at 60 Hz; each tick the renderer uploads two
  instance buffers (bullets now and at the start of the tick) through
  `RenderingServer.multimesh_set_buffer_interpolated`, and the engine blends
  them every *rendered* frame with the physics interpolation fraction, so
  bullets are smooth at 120/144 Hz. This relies on the project settings
  `physics/common/physics_interpolation=true` and `physics_jitter_fix=0`
  (without interpolation it falls back to a plain per-tick upload). Only the
  live part is written and uploaded: the MultiMesh is allocated in buckets just
  above the live count (grow at once, shrink below 50 %; Godot needs the buffer
  to be exactly `instance_count * stride`) and `visible_instance_count` hides the
  rest. Two pairs of buffers (current + previous tick) alternate so the engine's
  reference to the last upload never forces a copy-on-write, and the previous-tick
  buffer is written in the same pass as the current one: nothing is allocated per
  tick (no `duplicate()`; a test guards this).
* **`HurtboxGrid`**: uniform spatial hash (64 px cells) of *targets*, not
  bullets. Targets are few; bullets are many, so each bullet does one cell lookup
  and only tests the handful of targets in its cell. Bullets that moved further
  in one tick than they could overlap the smallest target walk the cells under
  their path (grid traversal) and test the path against each circle exactly.
  `Hurtbox` nodes register themselves in `Hurtbox.registry` (static array); the
  manager rebuilds the grid every tick.
* **`WallGrid`**: the same idea for static wall rectangles. Walls are bucketed
  once; each tick every bullet's path is tested against the walls around it
  (slab test against the wall grown by the bullet radius, which is conservative
  by at most 0.41 radius at a corner). Bullets far from any wall cost one array
  lookup. The grid only reports hit fractions; `BulletManager` clips the bullet
  to the impact point before the hurtbox test.
* **`BulletManager`**: owns the above and runs `step(delta)` from
  `_physics_process`. Tests and the benchmark call `step()` directly with
  `auto_step = false`.

No node, physics body or `Object` exists per bullet.

## Player, camera, input

* **Movement** (`MovementMath.step_velocity`): `move_toward` the target velocity
  with acceleration 2400 px/s^2 (full speed 300 px/s in 0.125 s), friction 2000
  px/s^2 (stops in 0.15 s) and a 1.6x boost when reversing. Pure function, unit
  tested; `Player` applies it and calls `move_and_slide()` against the `world`
  layer.
* **Aiming**: right stick (deadzone applied once, by the input map's per-action
  deadzone; "keep last aim" when released) or the mouse. The mouse aim is the
  *screen-space* offset from the ship's rendered position to the cursor
  (`AimMath.direction_from_screen_offset`), so it is correct even while the
  camera is smoothing or leaning and never uses a stale camera position.
* **Fire rate**: `FireCooldown` carries the remainder of the interval across
  ticks (`cooldown += interval`), so the rate is exact (e.g. 9.09 shots/s with the
  0.11 s interval of `BasicShot`) rather than rounded up to the next tick; idle time does not
  bank a burst. An interval shorter than a tick fires several shots in that tick
  (`while remaining <= 0: fire; remaining += interval`), capped at
  `FireCooldown.MAX_SHOTS_PER_TICK` (8, i.e. 480 shots/s); shots of one tick spawn
  together at the same muzzle position.
* **Aim timing**: in `_physics_process` the ship's rendered position uses the
  interpolation fraction of the last drawn frame, which is up to one frame stale.
  That is a few pixels at full speed and negligible for aim, so it is left as is.
* **Device switching**: the `InputDevice` autoload watches input events and
  flips between gamepad and mouse+keyboard on deliberate input (stick past 0.5,
  button press, mouse movement > 3 px, key press). Stick drift and mouse jitter
  are ignored. The OS cursor is hidden; `AimReticle` draws the crosshair.
* **Input map**: `move_*` (WASD / left stick), `aim_*` (right stick), `fire`
  (LMB / right trigger), `dash` (Space or Shift / gamepad B or right bumper), `toggle_stress` (F1 / Back), `cycle_stress` (F2 / Y).
* **Camera**: `FollowCamera` follows with frame-rate independent exponential
  smoothing, leans toward the aim direction, and has trauma-based shake
  (`add_trauma(0..1)`) ready for hit/explosion effects. Project-wide physics
  interpolation is on, so the player, camera and bullets render smoothly above
  60 Hz. The camera snaps to its target on start (no slide-in from the origin).

## Provisional defaults

These are placeholders chosen to make the sandbox playable. Each is a single
variable or export, listed here so they are easy to find and change. (The combat
numbers are no longer provisional: they are the decided rules below, and only
remain exports so they can be tuned.)

| Default | Value | Where |
| --- | --- | --- |
| Pool capacity | 16384 bullets | `BulletManager.capacity` |
| Logical bullet cap | **10,000** live bullets (provisional) | `BulletManager.logical_cap` |
| Enemy reserve | **3,000** of the cap, enemy/boss shots only (provisional) | `BulletManager.enemy_reserve` |
| Pool-full behaviour | drop the new shot, observable (see above) | `BulletPool.spawn`, `BulletManager._report_saturation()` |
| Saturation warning rate limit | one per 2 simulated seconds | `BulletManager.saturation_warning_interval` (0 = every saturated tick) |
| Weapon cooldown | `ShotPattern.fire_interval`, 0.11 s for `BasicShot` | `ShotPattern` / `BasicShot` |
| Autofire | on (`ShotPattern.auto_fire = true`) | `ShotPattern.auto_fire` |
| Max hp, i-frames, regeneration, dash, respawn | **decided** 2026-10-30, see "Combat rules" below (still exports, so tunable) | `Health`, `Player`, `Main` exports |
| Friendly fire | none, enforced: a bullet's `owner_layer` is stripped from its `hit_mask` | `BulletPool.spawn`, `Layers.hostile_to` |
| Turret sandbox enemy | 1.1 s interval, 260 px/s, range 700 px, 1 damage | `Turret` exports |

## Combat rules (decided 2026-10-30)

Decided by Karyu on 2026-10-30, except the dash distance and burst length, which
come from the design pillars doc (`docs/design/pillars.md` 5.4 on the design
branch) and are marked below. Every number is an `@export` so it can be tuned in
the editor or from a script without code changes.

| Rule | Value | Where |
| --- | --- | --- |
| Max hp | 5 | `Health.max_hp` |
| i-frames after a (non-lethal) hit | 0.75 s | `Health.invulnerability_time` |
| Regeneration | first hp 5 s after the last hit, then 1 hp every 3 s, up to max | `Health.regen_delay`, `regen_interval`, `regen_amount` |
| Dash input | action `dash`: Space or Shift; gamepad B or right bumper | `project.godot` input map |
| Dash direction | move direction, or the aim direction when not moving | `Player.try_dash()` |
| Dash distance / burst length | 160 px in 0.2 s (**from the pillars doc**, not decided by Karyu) | `Player.dash_distance`, `dash_duration` |
| Dash speed curve | hard launch decaying into running speed (`dash_curve_power` 2) | `DashMath` |
| Dash invulnerability | 0.2 s from the start of the dash (decided by Karyu; engine i-frames, scripts cannot cancel them) | `Player.dash_invulnerability` |
| Dash cooldown | 1.5 s, measured from the start of the dash (decided by Karyu) | `Player.dash_cooldown` |
| Dash input buffer | 0.1 s: a press while dashing / cooling down fires as soon as the dash is available. The dash never touches the weapon | `Player.dash_buffer_time`, `Player.request_dash()` |
| Own bullets | never hurt the player (nor enemies their own side) | `ShotRequest.owner_layer` |
| Reflecting | player side: scripts only (`reflect_bullet`). Enemy / boss side: `Reflector` zones, e.g. mirrors reflect PLAYER bullets, which become enemy-owned, deal 1 damage (pillars 5.4), lose their script, and are reflected at most once | `ShotEmitter.reflect_bullet`, `Reflector` |
| Death | respawn after 1.5 s at the last cleared boss arena, else the origin; keeps everything; hp resets to max | `RespawnPoints`, `Player.respawn()`, `Main` |

Clarifications (all confirmed by Karyu on 2026-10-30):

* **Regeneration timing.** The first hp comes 5 s after the last hit, then 1 hp
  every 3 s (5 s, 8 s, 11 s, ...). Taking damage restarts the 5 s; healing and
  script writes to hp do not.
* **Dash cooldown** counts from the dash start, so 1.5 s between dash *starts*.
* **Dash buffering.** A press that cannot dash yet (mid-burst or cooling down) is
  remembered for `dash_buffer_time` (0.1 s; 0 turns it off) and the dash starts
  on the first tick it is available, along the move direction of that moment
  (aim direction if standing still). Pressing several times still buffers one
  dash. The dash never cancels a charging weapon: the trigger state and the
  weapon's `update()` calls carry on unchanged, so a charge held through a dash
  releases with its full hold time.
* **Respawn** happens `Main.respawn_delay` (1.5 s) after death at
  `RespawnPoints.get_respawn_position()`: the last cleared boss arena, or the
  origin if none has been cleared. Enemies, bullets, weapon and max hp are kept;
  hp goes to `max_hp`; the engine i-frames, the dash cooldown, any buffered dash,
  the fire button state (so a release that happened while dead is not a stale
  release edge), the fire cooldown and the weapon's own state
  (`ShotPattern.reset()`: a charge, a burst) are cleared. **Script invulnerability
  persists** across a respawn: scripts own that layer, and clear it themselves.

### Respawn points (`RespawnPoints` autoload)

`src/core/respawn_points.gd`, registered as the `RespawnPoints` autoload. Bosses
don't exist yet; boss code will call `register_arena_cleared()` when its arena is
won, and `Main` reads `get_respawn_position()` when the player dies.

| Function | Notes |
| --- | --- |
| `register_arena_cleared(position) -> bool` | the cleared arena becomes the respawn point (the last one wins) and is counted. Non-finite positions are ignored |
| `set_checkpoint(position) -> bool` | same, without counting an arena (future checkpoint pickups) |
| `get_respawn_position() -> Vector2` | last arena / checkpoint, else `Vector2.ZERO` |
| `has_checkpoint()`, `get_arenas_cleared()` | reads |
| `reset()` | forget everything (new run; tests, since the autoload is shared) |

Signal: `respawn_position_changed(position)`.

### Health

`Health` (`src/core/health.gd`): `hp`, `max_hp`, `damage(amount, source_flags := 0) -> bool`,
`try_damage(amount, source_flags) -> DamageResult`, `heal()`, `reset()`,
`tick(delta)`, validated setters `set_hp()`, `set_max_hp()` (whole numbers),
`set_invulnerable(seconds_or_bool)`, engine-side `add_engine_invulnerability(seconds)`,
readers `is_dead()`, `is_invulnerable()`, `is_engine_invulnerable()`,
`is_script_invulnerable()`, `is_regenerating()`, `time_since_damage`, and signals
`damaged(amount, hp)`, `healed(amount, hp)`, `died`, `damage_blocked(amount, result)`,
`invulnerability_changed(active)` (either layer),
`engine_invulnerability_changed(active)`, `script_invulnerability_changed(active)`.

**Two invulnerability layers** (pillars 5.4 / 12.2):

| Layer | Written by | Cleared by | Pierced by |
| --- | --- | --- | --- |
| *Engine i-frames*: hit i-frames (0.75 s) and the dash (0.2 s) | the engine (`add_engine_invulnerability`, extend-only: the longer one wins) | time, or `Health.reset()` (respawn) | nothing |
| *Script invulnerability* | `set_invulnerable(seconds \| true \| false)` | `false`, `0` or less, time | attacks with `Health.SOURCE_PIERCES_SCRIPT_INVULN` (`ShotRequest.pierces_script_invuln`) |

`set_invulnerable` only ever touches the script layer: `false` never cancels a dash
or hit i-frames, `true` holds until cleared (no cap), seconds replace the script's
previous value (INF allowed). `is_invulnerable()` is true if either layer is on.
`try_damage()` says *why* a hit did not land: `APPLIED`, `BLOCKED_ENGINE`,
`BLOCKED_SCRIPT` (the same attack with the piercing flag would have landed),
`IGNORED` (not a positive number, or already dead), and `damage_blocked` carries it.

The player's `Hurtbox` follows the **engine** layer only: bullets pass through the
player during hit i-frames and dashes instead of being consumed. During script
invulnerability the hurtbox stays on, so non-piercing bullets reach it and are
consumed and blocked (`BLOCKED_SCRIPT`), while piercing ones land. The hurtbox
tells the handler which bullet it was: `Hurtbox.last_hit_bullet_id` (stable id)
and `last_hit_flags` are valid while `hit` is emitted; `Player._on_hit` passes the
flags to `damage()`. A hurtbox that was switched off by an earlier hit in the same
tick (i-frames, death) is skipped by the later bullets, which pass through.
`Player` forwards `damaged` and `died`, and emits `dashed(direction)`,
`dash_finished` and `teleported(position)` (the camera cuts to the player on it).

NaN to a setter is ignored with a rate-limited warning (`ScriptWarnings`: the first
3 of each kind are printed, then silence).

### The dash

`DashMath` is the closed-form speed curve; `DashState` the cooldown / burst state
machine; `Player` wires them to input and `move_and_slide()`. The curve is

    speed(t) = max_speed + (peak - max_speed) * (1 - t/duration)^power

so the dash launches at `peak` (1800 px/s with the defaults: 160 px in 0.2 s, running speed 300, power 2) and decays
smoothly into running speed, with `peak` solved so the burst covers exactly
`dash_distance`. Per-tick displacement comes from the exact integral, so the
distance is the same at any tick rate. Dashing collides with walls like normal
movement (it stops at them, it never tunnels). Tuning: `dash_distance` (needs
`>= max_speed * dash_duration`), `dash_duration`, `dash_curve_power` (0 = constant
speed, higher = sharper launch), `dash_invulnerability`, `dash_cooldown`.

### No friendly fire, and reflecting bullets

Bullets only hit hurtboxes whose layer is in their `hit_mask`, and the pool
removes the bullet's `owner_layer` from that mask when it spawns, so own-faction
bullets are harmless whatever a script asks for. Player shots are
`owner_layer = PLAYER` (the default), enemy shots `ENEMY`.

`ShotEmitter.reflect_bullet(id, new_owner_layer, reverse := false) -> bool`
(`BulletManager.reflect`, `BulletPool.reflect(slot, ...)`) hands a live bullet to
the other faction: `owner_layer` becomes `new_owner_layer`, `hit_mask` becomes
`Layers.hostile_to(new_owner_layer)`, the colour becomes that faction's
(`Layers.bullet_color`: player yellow, enemy `#FF5A4D`), the piercing `last_hit`
memory is cleared, the bullet's `reflect_count` goes up, and with `reverse` the
velocity and heading flip. Also:

* **Damage is 1** (`BulletPool.REFLECTED_DAMAGE`; pillars 5.4: a reflected bullet
  "can hit the player for 1 damage, its script `damage` value is ignored").
  Parameterised: `reflect_bullet(id, owner, reverse, new_damage)`, and
  `Reflector.reflected_damage`; `BulletPool.KEEP_DAMAGE` (or a negative zone value)
  keeps the bullet's own damage.
* **The bullet stops being scripted**: `behavior` becomes 0 (no more `on_update`,
  `on_hit` or `on_despawn` hooks), `user` and `param_a/b` are cleared and
  `pierces_script_invuln` is dropped. Opt in to keep all of it with
  `reflect_bullet(..., keep_script = true)` / `Reflector.keep_script`.
* **At most `BulletPool.max_reflections` reflections per bullet (default 1, pillars:
  no ping-pong), on every path**: `reflect_bullet` returns `false` for a bullet
  that used them up. 0 means unlimited. Zones apply their own `max_reflections`.

It returns `false` (changing nothing) for a stale id, a bullet already marked dead,
an owner that is not `PLAYER` / `ENEMY`, or a bullet past its reflection limit.
Velocity is otherwise untouched.
**The player side is scripts-only**: there is no built-in parry input.

### Reflector -- mirrors and shields for enemies and bosses

`Reflector` (`src/bullets/reflector.gd`) is the enemy-side path: a `Node2D` zone
you attach to any enemy or boss. Bullets of `reflects_owners` (default: PLAYER)
that cross the zone while moving toward it change sides: they become owned by the
other faction, take its colour, and can hurt the player but never the reflector's
owner (an ENEMY-owned bullet has `hit_mask = PLAYER`). Other owners pass through.

| Export | Default | Meaning |
| --- | --- | --- |
| `radius` | 40 | zone radius; put it a little outside the body's hurtbox |
| `arc_degrees` | 360 | arc centred on `facing()` (the node's global rotation); 360 = full circle. Bullets crossing the circle outside the arc pass |
| `reflects_owners` | `Layers.PLAYER` | owner layers reflected (flags) |
| `mode` | `MIRROR` | `REVERSE` straight back; `MIRROR` reflect across the surface normal at the impact; `AIM_AT_TARGET` send it at `target` (falls back to reverse) |
| `speed_multiplier` | 1 | reflected speed / incoming speed, clamped to [0, 20], NaN = 1 |
| `max_reflections` | 1 | reflect-once guard: a bullet that has changed owner this many times (by any reflector *or* a script) is not reflected again; 0 = unlimited |
| `reflected_damage` | 1 | damage of a reflected bullet (pillars 5.4); negative keeps the bullet's own |
| `keep_script` | `false` | keep the bullet's behaviour, `user` data and params after reflecting |
| `enabled` | true | also inactive while hidden |

Plus `target: Node2D` (set by whoever wires the scene), the `bullet_reflected(bullet_id, new_owner)` signal and `reflected_total`.

How it runs: inside `BulletManager.step()`, between the wall sweep and the
hurtbox pass. Active reflectors are bucketed into a second `HurtboxGrid`
(`BulletManager.reflector_grid`) whose `collide_bullets(pool, true)` matches the
zone's layer against each bullet's `owner_layer` (instead of `hit_mask`), using
the same swept, grid-walking test, so fast bullets cannot tunnel through a zone.
That is one pass over the bullets however many reflectors exist, nothing when
there are none, and no per-bullet nodes. Like the piercing sweep it lists
several hits per bullet in path order (up to `HurtboxGrid.MAX_ZONE_HITS` = 4 zones),
so a zone that declines a bullet (arc facing away, guard, bullet moving away) does
not hide the zone behind it. Rules applied to each candidate hit: guard, "must be
moving toward the centre", arc test at the impact point. Once a zone reflects a
bullet the rest of that bullet's hit list is stale and dropped, so a bullet is
reflected at most once per tick. The reflected bullet is placed at the impact
point with `pool.teleport()` (`pos` and `prev_pos` together: no phantom sweep of
the old path, no interpolated streak), so it never ends a tick inside the zone.
Reflection acts before hurtboxes, so the bullet never reaches the reflector's body
that tick. (Consequence, pinned by a test: a bullet that crosses a target *and* a
mirror within one tick, i.e. moves faster than ~200 px per tick, is reflected first
and does not deliver the earlier hit of that tick. A piercing bullet that meets the
target on an earlier tick keeps that hit.) A bullet that left the world bounds this tick is already dead and is
not reflected. `BulletManager.last_reflect_count` reports reflections in the last step.

`Mirror` (`src/enemies/mirror.gd`, `scenes/mirror.tscn`, one in the main scene) is
the test enemy: a dummy whose 150 degree arc turns toward the player at 2.5 rad/s.
Shots from the front come back at the player; shots from behind damage the body.

### Script-facing player state (`PlayerState`)

`player.state` is a `PlayerState`: the single, validated surface a script (and
the future Lua binding) uses to read and change the player. Names are snake_case
and use plain types. NaN is ignored (with a warning), infinities are clamped, and
every call on a freed player is a harmless no-op.

| Function | Notes |
| --- | --- |
| `get_hp()`, `set_hp(v)` | clamped to `[0, max_hp]`; `set_hp(0)` kills (normal death and respawn). No i-frames, does not restart regen |
| `get_max_hp()`, `set_max_hp(v)` | clamped to `[1, 1000]`; hp is pulled down if needed, raising does not heal |
| `set_invulnerable(x)` | the **script layer** only: seconds (replaces the previous script value; `0` or negative clears), or `true` (until cleared, no cap) / `false` (clear). Never cancels dash or hit i-frames |
| `is_invulnerable()`, `get_invulnerable_time()` | either layer |
| `is_script_invulnerable()`, `get_script_invulnerable_time()`, `is_engine_invulnerable()`, `get_engine_invulnerable_time()` | one layer each (engine = hit i-frames and dash) |
| `get_regen_delay()` / `set_regen_delay(s)`, `get_regen_interval()` / `set_regen_interval(s)`, `get_regen_amount()` / `set_regen_amount(v)` | regeneration tuning, clamped (delay `[0, 3600]`, interval `[0.05, 3600]`, amount `[0, max_hp]`), NaN ignored; each returns the resulting value |
| `get_speed()`, `set_speed(v)` | top running speed, clamped to `[0, 5000]` px/s |
| `dash(angle)` | starts a dash along `angle` (radians); the dash button's action and rules (cooldown, i-frames), not buffered; returns whether it started |
| `get_position()`, `set_position(v)` | `set_position` teleports (`Player.teleport()`): resets physics interpolation (no smear), the camera cuts to the new place, clamps to +-100000 |
| `get_velocity()`, `set_velocity(v)` | speed clamped to 5000 px/s |
| `is_dashing()`, `can_dash()` | read-only dash state |
| `get_dash_cooldown_left()`, `get_dash_cooldown()` | seconds left / total |
| `get_dash_direction()`, `get_aim_direction()` | unit vectors |
| `is_dead()`, `is_regenerating()`, `get_time_since_damage()` | read-only |

**Timing of writes.** Every `PlayerState` write takes effect immediately, in the
caller's context. The Lua binding is expected to apply a callback's writes at the
end of the callback if it wants transactional behaviour; that buffering is the
binding's job, not the state facade's (deliberately not built here).

Bullet-side calls for scripts: `ShotEmitter.reflect_bullet()`, plus everything in
"The shot interface" above. Also for scripts: `player.request_dash()` (a buffered dash press) and `player.has_buffered_dash()`; the respawn service is the `RespawnPoints` autoload.

## Known gaps and deliberate non-goals

* **Saturation model (pillars 3.3)**: implemented, with provisional defaults (see
  "Saturation model"). Not done: a per-emitter-id counter, a separate boss owner,
  and a guaranteed *player* share when enemies fill the pool.
* **Overheal** (hp above `max_hp`): not implemented. `set_hp` clamps to
  `[0, max_hp]` as specified; pillars 12 leaves overheal as a design call.
* **Bullet id reuse**: an id packs a handle and a 31-bit generation that is bumped
  every time that handle is released (wrapping, skipping 0). A stale id could
  match a new bullet only after 2^31 reuses of *one* handle: at 10k spawns per
  second over 16384 handles that is over a century of play. Accepted, not guarded.
* **Same-tick multi-hit order**: when several bullets reach one hurtbox in the
  same tick, they are delivered in bullet-slot order. The first lands; if its hit
  starts i-frames the hurtbox is off for the rest of the tick and the others pass
  through (they are not consumed). Which bullet lands therefore depends on slot
  order, which swap-remove makes arbitrary; the *amount* of damage taken per tick
  does not (one hit, then i-frames). Left as is; making it deterministic by damage
  or age would cost a sort per tick.
* **End-of-callback writes**: see "Timing of writes" above (the binding's job).
* **Same-tick fast bullets across target and mirror**: see the Reflector notes.

## Open design questions

1. **Non-rectangular level geometry.** Bullet-vs-wall collision supports
   axis-aligned rectangles only. Polygons or tile maps would need another
   broad phase (or `PhysicsServer2D` queries for hooked bullets only).
2. **Interpolation quality.** Bullet interpolation uses the engine's linear
   ("fast") lerp, which is exact for straight bullets and approximate for
   strongly curving ones within a single 1/60 s tick.
3. **Overflow policy.** A pool at its limit still drops new shots, observably (see
   "Saturation model"). Alternative: recycle the oldest bullet. Drop is predictable for
   scripts; recycle never loses the newest shot.
4. **Lua hook granularity.** Per-bullet `on_update` callbacks from Lua will be the
   dominant cost beyond a few hundred hooked bullets. Prefer declarative
   kinematics (`acceleration`, `turn_rate`, params) plus occasional hooks, or add
   a batch hook (`on_update_batch(pool, indices)`)? Needs input from the
   Scripting Engineer.
5. **Weapon timing ownership.** `ShotPattern.update()` now exists, so scripts can
   run charge / channel / burst weapons. Open: should cooldown ownership move
   entirely into scripts (drop `fire_interval`), and should `update()` also be
   called while the player is dead or the weapon is holstered?
6. **Combat beyond the decided rules.** Hp, i-frames, regeneration, dash
   (incl. buffering), respawn and enemy-side reflection are decided (see "Combat
   rules"). Still open: shields, enemy health model, damage types, whether the
   dash may cancel a weapon (today it never does), whether reflected bullets
   should refresh their lifetime, and the player-side parry (scripts-only for
   now: no input is bound to `reflect_bullet`).
7. **Renderer and scaling.** The project uses GL Compatibility (widest
   hardware, web-exportable, headless friendly; no 2D MSAA) with
   `canvas_items` stretch, aspect `keep`. Forward+/Mobile and integer
   pixel-perfect scaling are open if the art direction needs them.
