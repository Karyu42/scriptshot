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
        └──► HurtboxGrid (spatial hash) ──► Hurtbox.hit signal
```

## Folder layout

| Path | Contents |
| --- | --- |
| `src/core/` | Cross-cutting types: `Layers`, the shot interface (`ShotRequest`, `ShotEmitter`, `ShotContext`, `ShotPattern`, `BulletBehavior`), `InputDevice` autoload, `Main` sandbox scene script |
| `src/player/` | `Player`, `MovementMath`, `AimMath`, `AimReticle`, `BasicShot` (default weapon) |
| `src/bullets/` | `BulletPool`, `BulletManager`, `BulletRenderer`, `HurtboxGrid`, `Hurtbox`, `BulletShotEmitter`, `BulletStressTest` |
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
| 5 | `Layers.WORLD` = 16 | `world` | static walls (the player collides with these) |

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
| `on_update(pool, index, delta)` | Every physics tick after integration, while alive. Velocity/heading changes apply from the next tick |
| `on_hit(pool, index, hurtbox)` | Overlap with a hurtbox, after the hurtbox's own `hit` signal and before the bullet is despawned (or its `pierce` decremented) |
| `on_despawn(pool, index, reason)` | Just before removal. `reason` is a `BulletPool.DespawnReason`: `LIFETIME`, `BOUNDS`, `HIT`, `MANUAL`, `CLEARED` |

`behavior.emitter` is set at registration so hooks can spawn child bullets
(splitting, trails). To remove a bullet from a hook call `pool.mark_dead(index)`.

### Guarantees and limits

* Simulation runs on the fixed 60 Hz physics tick, in a fixed order:
  collect hurtboxes -> integrate (lifetime, bounds) -> `on_update` ->
  collision -> `on_hit` / hurtbox signals -> `on_despawn` -> removal -> render
  upload. Given the same requests, hurtbox positions and tick count the result is
  deterministic.
* Capacity is fixed (`BulletManager.capacity`, default 16384). A full pool drops
  new shots and counts them in `pool.dropped_total`; it never allocates.
* Bullets leave the simulation when they exit `BulletManager.world_bounds`.
* Bullets do **not** collide with `world` geometry yet (see open questions).
* Hook calls are the expensive path: every hooked bullet costs at least one
  script call per tick (plus whatever the hook does), whereas bullets with
  `behavior_id == 0` never call script code. The 5k/10k benchmark numbers are
  for plain bullets.

## Bullet system design

* **`BulletPool`** (`src/bullets/bullet_pool.gd`): struct-of-arrays in packed
  arrays (`PackedVector2Array pos/vel/rot`, `PackedFloat32Array
  radius/age/lifetime/...`, `PackedColorArray color`, `PackedInt32Array
  hit_mask/behavior/pierce`). Alive bullets are always the dense range
  `[0, count)`; despawn is a swap-remove, so slots are recycled with zero
  allocation and iteration never touches dead data. Removal is deferred
  (`mark_dead` / `flush_dead`) so hooks and collision can run on a stable set.
* **`BulletRenderer`**: one `MultiMeshInstance2D`, one quad mesh, one shader
  (`bullet.gdshader` draws an anti-aliased disc). The transform + colour buffer
  is filled from the pool each tick and uploaded with a single
  `RenderingServer.multimesh_set_buffer` call. One draw call regardless of count.
* **`HurtboxGrid`**: uniform spatial hash (64 px cells) of *targets*, not
  bullets. Targets are few; bullets are many, so each bullet does one cell lookup
  and only tests the handful of targets in its cell. `Hurtbox` nodes (children of
  the player, enemies...) register themselves through a group; the manager
  rebuilds the grid every tick.
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
* **Aiming**: right stick (with deadzone and "keep last aim") or the mouse
  position **in world space** (`get_global_mouse_position()`, so camera movement
  is accounted for).
* **Device switching**: the `InputDevice` autoload watches input events and
  flips between gamepad and mouse+keyboard on deliberate input (stick past 0.5,
  button press, mouse movement > 3 px, key press). Stick drift and mouse jitter
  are ignored. The OS cursor is hidden; `AimReticle` draws the crosshair.
* **Input map**: `move_*` (WASD / left stick), `aim_*` (right stick), `fire`
  (LMB / right trigger), `toggle_stress` (F1 / Back), `cycle_stress` (F2 / Y).
* **Camera**: `FollowCamera` follows with frame-rate independent exponential
  smoothing, leans toward the aim direction, and has trauma-based shake
  (`add_trauma(0..1)`) ready for hit/explosion effects. Project-wide physics
  interpolation is on, so the player and camera render smoothly above 60 Hz.

## Open design questions

1. **Bullet vs. world collision.** Bullets currently ignore `world` geometry and
   only die at `world_bounds`. Options: a second spatial hash of wall rects
   (cheap, fits rectangular arenas), or batched `PhysicsServer2D` point/shape
   queries for hooked bullets only. Needs a decision on level geometry.
2. **Rendering at high refresh rates.** Bullets are simulated and drawn on the
   60 Hz tick while the player and camera are interpolated. A 144 Hz display
   shows bullets updating at 60 Hz. Fix is cheap (extrapolate by velocity in the
   shader with a global uniform) but is a visual-policy call.
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
