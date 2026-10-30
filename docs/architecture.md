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
| `velocity` | `Vector2` | `(0,0)` | Initial velocity, px/s |
| `angle` | `float` | `NAN` | Visual orientation, radians. `NAN` = face along `velocity` |
| `lifetime` | `float` | `2.0` | Seconds until the bullet despawns by itself |
| `radius` | `float` | `4.0` | Collision and draw radius, px |
| `damage` | `float` | `1.0` | Passed to `Hurtbox.hit` on impact |
| `owner_layer` | `int` | `Layers.PLAYER` | Faction that fires the bullet (`PLAYER` or `ENEMY`). Its own layer is always removed from `hit_mask` on spawn, so **a bullet can never hurt whoever fired it**. `0` = unowned, nothing stripped |
| `hit_mask` | `int` | `Layers.ENEMY` | Layers it can hit; `0` = decorative, hits nothing |
| `color` | `Color` | warm yellow | Flat draw colour |
| `behavior_id` | `int` | `0` | Id from `register_behavior()`; `0` = plain bullet (fast path, no hooks) |
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
func request_shot(request: ShotRequest) -> bool       # same, bool: false = pool full, shot dropped
func request_shots(requests: Array) -> int            # returns number accepted
func is_bullet_alive(id: int) -> bool                 # false for stale / invalid ids
func get_dropped_count() -> int                       # shots dropped because the pool was full (cumulative)
func is_saturated() -> bool                           # pool is full right now
signal pool_saturated(dropped_now: int, dropped_total: int)
func register_behavior(behavior: BulletBehavior) -> int   # id for ShotRequest.behavior_id
func get_bullet_count() -> int
func get_capacity() -> int
```

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
| `on_hit(pool, index, hurtbox)` | Contact with a hurtbox, after the hurtbox's own `hit` signal and before the bullet is despawned (or its `pierce` decremented). Not called for a bullet that is already dead |
| `on_despawn(pool, index, reason)` | Just before removal, exactly once per bullet (also for bullets another hook marked dead; not for ones already removed). `reason` is a `BulletPool.DespawnReason`: `LIFETIME`, `BOUNDS`, `HIT`, `MANUAL`, `CLEARED`, `WALL` |

`behavior.emitter` is set at registration so hooks can spawn child bullets
(splitting, trails). To remove a bullet from a hook call `pool.mark_dead(index)`.

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
* Capacity is fixed (`BulletManager.capacity`, default 16384). A full pool drops
  new shots; it never allocates. Drops are observable: `get_dropped_count()`,
  `is_saturated()`, the `pool_saturated` signal (at most once per tick, with the
  number dropped that tick and the total) and a `push_warning` rate-limited by
  `BulletManager.saturation_warning_interval` (simulated seconds, default 2).
* Bullets leave the simulation when they exit `BulletManager.world_bounds`.
* Collision is **swept**: a bullet is the segment from where it was at the start
  of the tick (`pool.prev_pos`) to where it is now, so fast bullets do not
  tunnel through thin hurtboxes or walls. Impact positions passed to
  `Hurtbox.hit` are the actual contact points.
* Bullets collide with `world` walls by default and despawn there with reason
  `WALL`; `on_despawn` still fires. Opt out per bullet with
  `ShotRequest.collide_world = false`. Walls are axis-aligned rectangles:
  `BulletManager.add_wall(Rect2)` / `clear_walls()`, plus every
  `CollisionShape2D` with a `RectangleShape2D` under a node in the
  `world_walls` group (the main scene's `Walls` body; collected at `_ready`).
  Piercing bullets are still stopped by walls. A bullet spawned inside a wall
  despawns at once.
* Hook calls are the expensive path: every hooked bullet costs at least one
  script call per tick (plus whatever the hook does), whereas bullets with
  `behavior_id == 0` never call script code. The 5k/10k benchmark numbers are
  for plain bullets.
* Nothing is allocated in the per-tick hot path (scratch arrays are preallocated
  and grow only when capacity does; hurtboxes register in `Hurtbox.registry`
  instead of a group query), and a hook may spawn/kill bullets freely.
* Performance target: **10,000 bullets at p95 <= 16.6 ms** of CPU work per
  frame with walls and hurtboxes present (5,000 is the minimum), measured by
  `./tools/run_benchmark.sh` (the verdict is on 10k, 5k is reported alongside).

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
  rest. Two current-state buffers alternate so the engine's reference to the last
  upload never forces a copy-on-write.
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
  bank a burst.
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
| Pool-full behaviour | drop the new shot, observable (see above) | `BulletPool.spawn`, `BulletManager._report_saturation()` |
| Saturation warning rate limit | one per 2 simulated seconds | `BulletManager.saturation_warning_interval` (0 = every saturated tick) |
| Weapon cooldown | `ShotPattern.fire_interval`, 0.11 s for `BasicShot` | `ShotPattern` / `BasicShot` |
| Autofire | on (`ShotPattern.auto_fire = true`) | `ShotPattern.auto_fire` |
| Max hp, i-frames, regeneration, dash, respawn | **decided** 2026-10-30, see "Combat rules" below (still exports, so tunable) | `Health`, `Player`, `Main` exports |
| Friendly fire | none, enforced: a bullet's `owner_layer` is stripped from its `hit_mask` | `BulletPool.spawn`, `Layers.hostile_to` |
| Turret sandbox enemy | 1.1 s interval, 260 px/s, range 700 px, 1 damage | `Turret` exports |

## Combat rules (decided 2026-10-30)

Decided by Karyu on 2026-10-30. Every number is an `@export` so it can be tuned
in the editor or from a script without code changes.

| Rule | Value | Where |
| --- | --- | --- |
| Max hp | 5 | `Health.max_hp` |
| i-frames after a (non-lethal) hit | 0.75 s | `Health.invulnerability_time` |
| Regeneration | first hp 5 s after the last hit, then 1 hp every 3 s, up to max | `Health.regen_delay`, `regen_interval`, `regen_amount` |
| Dash input | action `dash`: Space or Shift; gamepad B or right bumper | `project.godot` input map |
| Dash direction | move direction, or the aim direction when not moving | `Player.try_dash()` |
| Dash distance / burst length | 170 px in 0.18 s | `Player.dash_distance`, `dash_duration` |
| Dash speed curve | hard launch decaying into running speed (`dash_curve_power` 2) | `DashMath` |
| Dash invulnerability | 0.2 s from the start of the dash | `Player.dash_invulnerability` |
| Dash cooldown | 1.5 s, measured from the start of the dash | `Player.dash_cooldown` |
| Dash input buffer | 0.1 s: a press while dashing / cooling down fires as soon as the dash is available. The dash never touches the weapon | `Player.dash_buffer_time`, `Player.request_dash()` |
| Own bullets | never hurt the player (nor enemies their own side) | `ShotRequest.owner_layer` |
| Reflecting | player side: scripts only (`reflect_bullet`). Enemy / boss side: `Reflector` zones, e.g. mirrors reflect PLAYER bullets, which become enemy-owned | `ShotEmitter.reflect_bullet`, `Reflector` |
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
  hp goes to `max_hp`, i-frames, the dash cooldown and any buffered dash are
  cleared.

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

`Health` (`src/core/health.gd`): `hp`, `max_hp`, `damage(amount) -> bool`,
`heal()`, `reset()`, `tick(delta)`, validated setters `set_hp()`, `set_max_hp()`,
`set_invulnerable(seconds_or_bool)`, readers `is_dead()`, `is_invulnerable()`,
`is_regenerating()`, `time_since_damage`, and signals `damaged(amount, hp)`,
`healed(amount, hp)`, `died`, `invulnerability_changed(active)`. Invulnerability
from any source (a hit, a dash, a script) shares one timer: a new source can only
extend it. While invulnerable the player's `Hurtbox` is switched off, so bullets
pass through instead of being consumed. `Player` forwards `damaged` and `died`
and emits `dashed(direction)`.

### The dash

`DashMath` is the closed-form speed curve; `DashState` the cooldown / burst state
machine; `Player` wires them to input and `move_and_slide()`. The curve is

    speed(t) = max_speed + (peak - max_speed) * (1 - t/duration)^power

so the dash launches at `peak` (about 2230 px/s with the defaults) and decays
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
(`Layers.bullet_color`), the piercing `last_hit` memory is cleared, the bullet's
`reflect_count` goes up, and with `reverse` the velocity and heading flip. It
returns `false` (changing nothing) for a stale id, a bullet already marked dead,
or an owner that is not `PLAYER` / `ENEMY`. Velocity is otherwise untouched.
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
| `enabled` | true | also inactive while hidden |

Plus `target: Node2D` (set by whoever wires the scene), the `bullet_reflected(bullet_id, new_owner)` signal and `reflected_total`.

How it runs: inside `BulletManager.step()`, between the wall sweep and the
hurtbox pass. Active reflectors are bucketed into a second `HurtboxGrid`
(`BulletManager.reflector_grid`) whose `collide_bullets(pool, true)` matches the
zone's layer against each bullet's `owner_layer` (instead of `hit_mask`), using
the same swept, grid-walking test, so fast bullets cannot tunnel through a zone.
That is one pass over the bullets however many reflectors exist, nothing when
there are none, and no per-bullet nodes. Rules applied to each candidate hit:
guard, "must be moving toward the centre", arc test at the impact point. A
reflected bullet is moved to the zone edge, so it never ends a tick inside the
zone, and acts before hurtboxes, so it never reaches the reflector's body that
tick. `BulletManager.last_reflect_count` reports reflections in the last step.

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
| `set_invulnerable(x)` | seconds (extends only; `0` or negative clears), or `true` (until cleared) / `false` (clear) |
| `is_invulnerable()`, `get_invulnerable_time()` | any source (hit, dash, script) |
| `get_position()`, `set_position(v)` | `set_position` teleports: resets physics interpolation (no smear), clamps to +-100000 |
| `get_velocity()`, `set_velocity(v)` | speed clamped to 5000 px/s |
| `is_dashing()`, `can_dash()` | read-only dash state |
| `get_dash_cooldown_left()`, `get_dash_cooldown()` | seconds left / total |
| `get_dash_direction()`, `get_aim_direction()` | unit vectors |
| `is_dead()`, `is_regenerating()`, `get_time_since_damage()` | read-only |

Bullet-side calls for scripts: `ShotEmitter.reflect_bullet()`, plus everything in
"The shot interface" above. Also for scripts: `player.request_dash()` (a buffered dash press) and `player.has_buffered_dash()`; the respawn service is the `RespawnPoints` autoload.

## Open design questions

1. **Non-rectangular level geometry.** Bullet-vs-wall collision supports
   axis-aligned rectangles only. Polygons or tile maps would need another
   broad phase (or `PhysicsServer2D` queries for hooked bullets only).
2. **Interpolation quality.** Bullet interpolation uses the engine's linear
   ("fast") lerp, which is exact for straight bullets and approximate for
   strongly curving ones within a single 1/60 s tick.
3. **Overflow policy.** A full pool still drops new shots, now observably (see
   above). Alternative: recycle the oldest bullet. Drop is predictable for
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
