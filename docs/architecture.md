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
| `src/core/` | Cross-cutting types: `Layers`, the shot interface (`ShotRequest`, `ShotEmitter`, `ShotContext`, `ShotPattern`, `BulletBehavior`), `InputDevice` autoload, `Main` sandbox scene script |
| `src/player/` | `Player`, `MovementMath`, `AimMath`, `FireCooldown`, `AimReticle`, `BasicShot` (default weapon) |
| `src/bullets/` | `BulletPool`, `BulletManager`, `BulletRenderer`, `HurtboxGrid`, `WallGrid`, `Hurtbox`, `BulletShotEmitter`, `BulletStressTest` |
| `src/enemies/` | Enemies (currently only `TrainingDummy`) |
| `src/world/` | Arena drawing / world pieces |
| `src/camera/` | `FollowCamera`, `CameraMath` |
| `src/fx/` | Reserved for effects (hit flashes, particles, shake sources) |
| `scenes/` | `main.tscn` (playable sandbox), `player.tscn`, `training_dummy.tscn` |
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
| `hit_mask` | `int` | `Layers.ENEMY` | Layers it can hit; `0` = decorative, hits nothing |
| `color` | `Color` | warm yellow | Flat draw colour |
| `behavior_id` | `int` | `0` | Id from `register_behavior()`; `0` = plain bullet (fast path, no hooks) |
| `acceleration` | `float` | `0.0` | px/s^2 along the heading (negative brakes, never reverses) |
| `turn_rate` | `float` | `0.0` | Heading change in rad/s (curving shots) |
| `pierce` | `int` | `0` | Extra targets to pass through before despawning |
| `collide_world` | `bool` | `true` | Stop at `world` walls (despawn reason `WALL`). `false` = fly through walls |
| `param_a`, `param_b` | `float` | `0.0` | Free scratch values for behaviour hooks |

Helpers: `ShotRequest.polar(position, heading_radians, speed)` and
`ShotRequest.with_velocity(position, velocity)`.

Straight-line, accelerating and constant-curve bullets are handled by the
vectorised core loop with **no script call per bullet**. Use hooks only when a
bullet needs logic the built-in kinematics cannot express.

### `ShotEmitter` -- where requests go

Abstract base (`src/core/shot_emitter.gd`); the game provides
`BulletShotEmitter`. Shooters never see `BulletManager` or `BulletPool`.

```gdscript
func request_shot(request: ShotRequest) -> bool       # false = pool full, shot dropped
func request_shots(requests: Array) -> int            # returns number accepted
func register_behavior(behavior: BulletBehavior) -> int   # id for ShotRequest.behavior_id
func get_bullet_count() -> int
func get_capacity() -> int
```

Spawning is immediate and synchronous: the bullet exists when the call returns,
`on_spawn` has run, and it is first simulated on the next physics tick. Spawning
from inside a hook is allowed.

### `ShotContext` + `ShotPattern` -- the weapon / script entry point

`ShotPattern.fire(context, emitter)` is called by the player each time the
trigger may fire. `ShotPattern.fire_interval` (seconds) is the cooldown the
player applies between calls while the trigger is held. A Lua binding provides a
`ShotPattern` subclass that forwards `fire()` to a Lua function.

`ShotContext` (read-only for patterns):

| Field | Meaning |
| --- | --- |
| `muzzle_position` | World-space spawn point (shooter origin + muzzle offset along aim) |
| `aim_direction`, `aim_angle` | Unit vector / radians |
| `shooter_velocity` | Shooter's current velocity, px/s |
| `target_mask` | Layers the shot should be able to hit (set `ShotRequest.hit_mask` from it) |
| `time` | Seconds since the shooter was created |
| `shot_index` | Trigger pull counter |

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
`pool.param_a[index]`, `pool.pierce[index]`, ...

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
  new shots and counts them in `pool.dropped_total`; it never allocates.
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
  despawns at once.* Hook calls are the expensive path: every hooked bullet costs at least one
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
  (LMB / right trigger), `toggle_stress` (F1 / Back), `cycle_stress` (F2 / Y).
* **Camera**: `FollowCamera` follows with frame-rate independent exponential
  smoothing, leans toward the aim direction, and has trauma-based shake
  (`add_trauma(0..1)`) ready for hit/explosion effects. Project-wide physics
  interpolation is on, so the player, camera and bullets render smoothly above
  60 Hz. The camera snaps to its target on start (no slide-in from the origin).

## Open design questions

1. **Non-rectangular level geometry.** Bullet-vs-wall collision supports
   axis-aligned rectangles only. Polygons or tile maps would need another
   broad phase (or `PhysicsServer2D` queries for hooked bullets only).
2. **Interpolation quality.** Bullet interpolation uses the engine's linear
   ("fast") lerp, which is exact for straight bullets and approximate for
   strongly curving ones within a single 1/60 s tick.
3. **Overflow policy.** A full pool drops new shots. Alternative: recycle the
   oldest bullet. Drop is predictable for scripts; recycle never loses the
   newest shot.
4. **Lua hook granularity.** Per-bullet `on_update` callbacks from Lua will be the
   dominant cost beyond a few hundred hooked bullets. Prefer declarative
   kinematics (`acceleration`, `turn_rate`, params) plus occasional hooks, or add
   a batch hook (`on_update_batch(pool, indices)`)? Needs input from the
   Scripting Engineer.
5. **Weapon timing ownership.** `ShotPattern.fire_interval` is a fixed cooldown
   owned by the pattern. Scripts that need channelled / charged / burst weapons
   will want a per-tick `update(context, emitter, delta)` entry point.
6. **Player damage and death.** The player has a hurtbox and emits `damaged`, but
   no health, death or i-frames. Friendly-fire rules (`ENEMY_BULLET` vs `PLAYER`
   only?) also need to be fixed before enemies shoot.
7. **Renderer and scaling.** The project uses GL Compatibility (widest
   hardware, web-exportable, headless friendly; no 2D MSAA) with
   `canvas_items` stretch, aspect `keep`. Forward+/Mobile and integer
   pixel-perfect scaling are open if the art direction needs them.
