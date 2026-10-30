# Scriptshot shot scripting API (draft v0.2)

Status: **draft for review**. Nothing here is implemented yet. Points that depend on the
bullet system being built by the Gameplay Engineer are marked **[OI-n]** (open interface
question) and collected at the end. v0.2 aligns the draft with the design pillars (PR #1),
the core scaffold (PR #2, head 2026abe), the gameplay defaults and `PlayerState` (PR #4), the
measured spike results ([spike-results.md](spike-results.md)) and Karyu's sandbox decisions.
Engine names are quoted verbatim (`ShotContext.muzzle_position`, `BulletPool.DespawnReason`, ...)
so each Lua concept can be traced to code.

Players write shots in Lua. A script is a single `.lua` file that returns a *weapon*
table. The engine calls into it when you fire and on shot events. Everything else
(movement, collision, rendering) happens natively, so you can have thousands of
bullets on screen and only pay for Lua when you actually say something interesting.

## Design principles

1. **Declare motion, script decisions.** Simple motion (speed, acceleration, turning,
   spin, homing, bounce, pierce) is *data*. It is run natively and costs nothing in Lua.
   Callbacks (`on_hit`, `every`, `after`, ...) are for decisions.
2. **Callbacks, not per-frame polling.** `on_tick` exists, but it is the expensive path
   and is metered. Prefer timers and events.
3. **Shots can make shots.** Any shot may spawn children, which inherit owner/team and
   can have their own callbacks. This is the core of splitting, chaining and spawners.
4. **Full freedom for your own scripts, a warning for other people's.** A script you wrote
   gets full Lua; anything that touches your computer (files, programs, native code) is an
   explicit per-script opt-in, never on by default. Imported or shared scripts get a
   warning and every dangerous capability starts off (see *Capabilities and importing*).
   There is no whitelist of what a shot may *do* in the game world. Limits are on
   resources (instructions, memory, bullets), not on creativity.
5. **Mistakes are survivable.** A bug in your script never crashes the game or freezes it.
   You get a readable error with file and line.

## Conventions

Fixed by the bullet system (PR #2 / #4), repeated here so scripts and engine agree:

- **Coordinates: y points down** (Godot screen space). Positions are pixels in arena space.
- **Angles are radians, 0 = +x, increasing clockwise on screen** (a consequence of y-down).
  `vec2(1,0):rotated(a)` and `angle = a` follow the same rule. `angle = nil` (engine: `NAN`)
  means "face the velocity".
- **Simulation runs at a fixed 60 Hz** (`ctx.dt = 1/60`). Timers use game time.
- **Hits: the bullet system calls `hurtbox.receive_hit(damage, pos, vel)`; the *owner of the
  hurtbox applies the damage*.** Scripts never apply damage to enemies directly.
- **Own bullets never hurt their owner.** `ShotRequest.owner_layer` (default `Layers.PLAYER`) is
  stripped from `hit_mask` at spawn, whatever a script asks for. Reflecting changes the owner.
- **Slots are not handles.** Despawning swap-removes: the last bullet moves into the freed slot, so a
  pool *index* is only valid inside one hook call (`BulletBehavior`: "only valid for the duration of the
  call"). Anything that outlives the call (timers, `b` handles stored in `state`, coroutines) uses the
  **stable id**: `id = (generation << 32) | handle`, always `> 0`, `-1` = none (`pool.id_of(index)`,
  `pool.slot_of(id)` -> slot or `-1`, `pool.is_alive(id)`, `ShotEmitter.request_shot_id()`,
  `ShotEmitter.is_bullet_alive(id)`). A Lua `b` wraps the id and resolves it to a slot on each access.
- **Spawning is synchronous from weapon code and queued from bullet callbacks.** `spawn{}` inside
  `on_fire` / `update` calls `ShotEmitter.request_shot_id()`: the bullet exists on return and `spawn`
  returns its handle (or `nil` if the pool or the player's share is full). Inside bullet callbacks
  (`on_hit`, `on_death`, `on_tick`, `on_batch`) the engine is mid-step, so spawns go to a **command
  buffer applied at the start of the next tick** (counted, capped per tick); `spawn` returns `true` /
  `false` (accepted / dropped) and the child's own `on_spawn(b)` receives the handle.
- **Position writes are teleports.** Writing a shot's position is a discontinuous move; the engine
  collides swept segments (`prev_pos` -> `pos`), so a raw write would sweep a phantom hit across the
  jump. `b.pos = v`, `b.x`, `b.y` and the batch `TELEPORT` command therefore map to
  **`BulletPool.teleport(index, position)`** (coming in PR #2), never to `pool.pos[i] = ...`. Continuous
  motion is velocity / `accel` / `spin`. For the player, `player.pos = v` is `PlayerState.set_position`
  (teleport, resets interpolation).

## Script shape

```lua
-- my_weapon.lua
return {
  name     = "Spiral",
  cooldown = 0.25,                 -- seconds between trigger pulls

  on_fire = function(ctx)          -- called when the player fires
    spawn { angle = ctx.aim, speed = 400 }
  end,
}
```

`ctx` is a read-only **snapshot** of `ShotContext` taken when the callback starts (it does not change
while a coroutine is parked in `wait()`; read `player` or call `ctx:refresh()` for live values). Fields
match the engine one to one:

| Lua | `ShotContext` field | Notes |
|---|---|---|
| `ctx.pos` | `muzzle_position` | muzzle, world space (`vec2`) |
| `ctx.aim` | `aim_angle` | radians, 0 = +x, clockwise on screen |
| `ctx.aim_dir` | `aim_direction` | unit `vec2` |
| `ctx.vel` | `shooter_velocity` | px/s |
| `ctx.target_mask` | `target_mask` | layers the shot may hit (`Layers`); default for `hit_mask` |
| `ctx.time` | `time` | seconds since the shooter was created |
| `ctx.n` (`ctx.shot_count`) | `shot_index` | number of `fire()` calls so far |
| `ctx.pressed` | `trigger_pressed` | fire button down this tick |
| `ctx.just_pressed`, `ctx.just_released` | `trigger_just_pressed`, `trigger_just_released` | edge flags, one tick |
| `ctx.held_time` | `trigger_held_time` | seconds held continuously; **on the release tick it still holds the length of the hold that just ended** (charge weapons read it there) |
| `ctx.dt` | none (constant) | `1/60` |
| `ctx.device` | `InputDevice` autoload (new field) | `"kbm"`, `"pad"`, `"touch"` |
| `ctx.hp` | `PlayerState.get_hp()` (new field) | snapshot of `player.hp` |

There is **no `ctx.owner` and no `ctx.charge`** (the engine has neither): the player is the global
`player`, and a charge weapon reads `ctx.held_time` on `ctx.just_released` inside `update`.

### How `on_fire` runs (coroutines vs. the synchronous `ShotPattern.fire`)

The engine calls `ShotPattern.fire(context, emitter)` synchronously and expects it to return; it
also calls `ShotPattern.update(context, emitter, delta)` **every physics tick while the pattern is
equipped, before `fire()`** (`auto_fire = true` keeps the hold-to-fire path; `auto_fire = false`
makes `update` the only driver). The Lua binding provides one `ShotPattern` subclass that resolves
the conflict with the `wait()` coroutine model like this:

1. `fire()` starts `on_fire(ctx)` inside a **host-owned coroutine** (the same mechanism as the
   watchdog, see *Sandbox*). It runs synchronously until it returns **or calls `wait(t)`**.
   Shots spawned before the first `wait` exist when `fire()` returns.
2. A `wait(t)` parks the coroutine in a native timer list (game time). **`update()` is the
   scheduler**: every tick it resumes the coroutines whose timers are due, with the long-lived
   `emitter`, so later segments of a burst spawn in the tick they are due (before the bullet manager
   steps, priority 0 vs 100). A script with `update = function(ctx, dt)` is called there as well.
3. Several fires may overlap (each pull starts its own coroutine, at most 64 live per weapon,
   `reentrant = false` cancels the previous one). Unequipping, respawn and `R` cancel all parked
   coroutines (`on_unequip` runs first).
4. A weapon that defines `update` but no `on_fire` sets `auto_fire = false`. A weapon with `on_fire`
   maps `cooldown` to `fire_interval`.
5. Open (architecture question 5): `update()` is not called while the player is dead or the weapon
   holstered; the Lua side assumes that and parks coroutines meanwhile.

**Coroutine safety (issue #240).** lua-gdextension #240 reports crashes when coroutines are freed.
The binding keeps every `wait`-coroutine created Lua-side and owned by the host, never frees one
from GDScript while it is suspended inside a hook, and pools them. The spike did not reproduce #240
(200k Lua-side creates, 100k GDScript-side create/drop, 3,000 hooked coroutines freed while suspended,
200 state recreations; memory back to baseline); the same patterns are permanent regression tests
(see [testing.md](testing.md)).

Optional weapon-level fields: `name`, `cooldown`, `ammo`, `on_fire`, `on_equip`,
`on_unequip`, `update`, `needs`, `format`, `tick_every` (see below).

`update = function(ctx, dt)` is called **every tick before `on_fire` and auto-fire**
(engine: `ShotPattern.update(ctx, emitter, delta)`), including ticks where nothing fires.
Use it for charge weapons, toggles and anything that reads the trigger state. `on_fire`
is called when the engine decides a shot is due (cooldown elapsed and trigger down, or
auto-fire). Charge weapon: `update = function(ctx) if ctx.just_released then spawn{ damage = ctx.held_time * 4, angle = ctx.aim, pos = ctx.pos } end end`.

`needs = { "os", "io" }` declares the capabilities the script wants (see *Capabilities and
importing*). `format = 1` is the script-API version. **Unknown top-level keys in the weapon
table are ignored** (forward compatibility), and there is no profile/tier field.

Saturation feedback: `ctx.dropped` (`ShotEmitter.get_dropped_count()`, cumulative) and
`ctx.saturated` (`is_saturated()`) are readable; the engine emits `pool_saturated(dropped_now,
dropped_total)` at most once per tick and a rate-limited warning. Dropped shots are never silent.

### Names (this draft vs. the pillars doc)

PR #1 uses placeholder names; both spellings are accepted so players can follow either document.
Canonical here is the left column.

| This draft | Also accepted (PR #1) |
|---|---|
| `spawn{}` | `shoot{}` |
| `lifetime` | `life` |
| `on_tick(b, dt)` | `update(b, dt)` (per-bullet) |
| `on_death(b, why)` | `on_die(b, why)` |
| `sense.*` (gated queries) | same; replaces `world.nearest_enemy` etc. |
| `state` (persistent) | same |
| `player` (writable) | same; fields below |

## Math helpers

Provided globally: `vec2(x, y)` (supports `+ - * /`, `:len()`, `:norm()`, `:rotated(a)`,
`:angle()`, `:dot()`, `:dist(v)`), `math.*` (standard), `rand(a, b)`,
`rand_int(a, b)`, `rand_sign()`, `rand_angle()`, `lerp`, `clamp`, `PI`, `TAU`, `deg(rad)`, `rad(deg)`.

Randomness: `rand*` use a per-run seeded generator, so replays and daily-seed runs
are reproducible. `math.random` is aliased to the same generator. **[OI-2]**

## Spawning shots

```lua
local b = spawn { ...fields... }   -- returns a shot handle, or nil if over limits
```

### Spawn fields

All optional. Unspecified fields take engine defaults.

**Placement and motion (native, free)**

| Field | Default | Meaning |
|---|---|---|
| `pos` | muzzle / parent's pos | start position (`vec2`) |
| `angle` | `ctx.aim` / parent's heading | heading in radians |
| `speed` | `300` | initial speed (px/s) |
| `vel` | derived from angle+speed | explicit velocity `vec2` (overrides angle/speed) |
| `accel` | `0` | speed change along heading (px/s^2), may be negative |
| `max_speed`, `min_speed` | none | clamps for `accel` |
| `drag` | `0` | fraction of speed lost per second |
| `spin` | `0` | heading rotation rate (rad/s). Gives native curves/spirals. |
| `spin_accel` | `0` | change of `spin` per second |
| `gravity` | `nil` | `vec2` constant acceleration |
| `homing` | `nil` | see *Homing* |
| `lifetime` | `3` | seconds until `on_expire` then removal |
| `bounce` | `0` | wall bounces before the shot dies |
| `pierce` | `0` | enemies passed through before the shot dies |

**Combat**

| Field | Default | Meaning |
|---|---|---|
| `damage` | `1` | damage per hit |
| `radius` | `4` | collision radius (px) |
| `team` | `"player"` | `"player"` or `"enemy"` -> `ShotRequest.owner_layer`; `hit_mask` defaults to `Layers.hostile_to(owner)`. Own layer is always stripped from `hit_mask` (no self-hits). Custom tags go in `tags` |
| `hit_mask` | hostile layers | optional narrowing (layers); cannot include the owner's layer |
| `tags` | `{}` | free-form strings, e.g. `{"fire", "child"}`, readable by callbacks and enemies |
| `knockback` | `0` | impulse applied to what is hit **[OI-4]** |

**Look** **[OI-5]**

| Field | Default | Meaning |
|---|---|---|
| `color` | team default | `Color` or `"#rrggbb"` |
| `scale` | `1` | visual scale |
| `sprite` | `"round"` | name from the sprite sheet of built-in shapes |
| `trail` | `nil` | `{length=..., fade=...}` |

**State and callbacks**

| Field | Meaning |
|---|---|
| `state` | table copied into the shot's private state (see *Per-shot state*) |
| `on_spawn(b)` | right after creation (after fields are applied) |
| `on_hit(b, hit)` | on collision with a valid target |
| `on_wall(b, wall)` | see *Hits* (today this is `on_death` with `why == "wall"`; no normal yet) |
| `on_expire(b)` | sugar for `on_death` with `why == "lifetime"` |
| `on_death(b, why)` | once, just before the shot is removed (`BulletBehavior.on_despawn`). `why` is the engine's `BulletPool.DespawnReason` in lower case: `"lifetime"`, `"bounds"`, `"hit"`, `"manual"` (`b:kill()`), `"cleared"` (arena wipe), `"wall"` |
| `on_tick(b, dt)` | per-bullet tick (hook option A). **Metered, opt-in**; combine with `tick_every = n` (the engine skips natively, so skipped ticks cost ~0). ~1.6-2.1 us per bullet per call |
| `on_batch(bs, dt)` | whole-bucket update (hook option B), the recommended way to steer many bullets every tick; see *Per-frame logic: tick vs batch* |
| `on_near(b, other)` | enemy or shot entered `near_radius` (set `near_radius`) **[OI-6]** |

#### Spawn fields -> engine mapping

Where each field lands in `ShotRequest` (PR #2 head 2026abe). **Fields marked "none yet" have no engine
equivalent**: until the engine grows them the ScriptHost accepts the field, logs a one-time console
note and ignores it (never an error), or emulates it where a built-in behaviour is cheap (see
[spike-results.md](spike-results.md), interface diff).

| Lua field | `ShotRequest` / pool | Status |
|---|---|---|
| `pos` | `position` | exists |
| `angle` + `speed` | `velocity` via `ShotRequest.polar(position, heading, speed)`; visual `angle` (`NAN` = along velocity) | exists |
| `vel` | `velocity` | exists |
| `accel` | `acceleration` (px/s^2 along the heading, negative brakes) | exists |
| `spin` | `turn_rate` (rad/s, rotates velocity and heading together; clockwise positive) | exists |
| `lifetime` / `life` | `lifetime` | exists |
| `damage`, `radius`, `color` | `damage`, `radius`, `color` | exists |
| `pierce` | `pierce` (extra targets before despawn) | exists |
| `team` / `hit_mask` | `owner_layer` and `hit_mask` (owner layer stripped) | exists |
| `collide_world` (default `true`) | `collide_world`; a wall hit despawns with reason `WALL` | exists |
| `state` | `user` (`pool.user[i]`, moves with swap-remove, reset on despawn) | exists |
| `on_*` callbacks | `behavior_id` from `register_behavior()`, one per distinct callback set | exists |
| scratch numbers for batch/tick code | `param_a`, `param_b` | exists |
| `bounce` | none yet (`WallGrid` only despawns, reason `WALL`); needs a wall normal | **none yet** |
| `drag`, `gravity`, `max_speed`, `min_speed`, `spin_accel` | none yet | **none yet** |
| `homing` | none yet (needs a spatial query over `HurtboxGrid`) | **none yet** |
| `knockback` | none yet (owner-side, with `receive_hit`) | **none yet** |
| `scale`, `sprite`, `trail`, `near_radius`/`on_near`, `tags` | none yet (renderer / query work) | **none yet** |

Speed is clamped to 1,200 px/s until swept collision is on `main` (PR #1 B3); PR #2 implements swept
collision and the clamp lifts when it merges.

Spawning from inside another shot: `b:spawn{...}` is the same as `spawn{...}` but with
`pos`, `angle`, `team`, `owner`, `damage` and `parent` defaulted from `b` and
`generation = b.generation + 1`.

## The shot handle (`b`)

A handle wraps the **stable id** (`(generation<<32)|handle`); it is *not* a pool slot (slots swap
on despawn and are valid only inside one hook call). Every access resolves `slot_of(id)`; if the shot
is gone the handle is *dead*: reads return `nil`/`0`, writes and methods are safe no-ops, and
`b:alive()` is `false` (`BulletPool.is_alive(id)` is false from the moment a bullet is marked dead).
Handles may be stored in `state`, timers and coroutines; slots never reach Lua.

Readable and writable (applied natively; positions as teleports, see *Conventions*):

`b.pos`/`b.x`/`b.y` (teleport), `b.vel`, `b.speed`, `b.angle`, `b.accel`, `b.spin`, `b.damage`,
`b.radius`, `b.lifetime`, `b.pierce`, `b.color`. Not yet engine-backed: `b.bounce`, `b.scale`, `b.homing`.

Read-only: `b.age`, `b.team`, `b.generation`, `b.id`, `b.parent`. `b.team` is derived from
`owner_layer` (`"player"` / `"enemy"`) and changes only through `reflect`.

Methods:

| Method | Does | Engine |
|---|---|---|
| `b:alive()` | is it still in play | `is_alive(id)` |
| `b:kill()` | remove it now; `on_death` runs with `why == "manual"` | `BulletPool.mark_dead(slot, MANUAL)`; `on_death` is the `on_despawn` hook |
| `b:teleport(pos)` | discontinuous move (same as `b.pos = pos`) | `BulletPool.teleport(slot, pos)` (PR #2, coming) |
| `b:reflect(team, reverse)` | hand the shot to the other faction (parry / deflect); `reverse = true` flips velocity and heading | `ShotEmitter.reflect_bullet(id, owner_layer, reverse)` |
| `b:spawn{...}` | spawn a child (see above) | `request_shot_id` (queued from callbacks) |
| `b:split(n, opts)` | spawn `n` children fanned out; see *Splitting* | |
| `b:every(dt, fn)` | call `fn(b)` every `dt` seconds; stops if the shot dies | native timer heap |
| `b:after(dt, fn)` | call `fn(b)` once after `dt` seconds | |
| `b:run(fn)` | run `fn(b)` as a coroutine that may `wait(seconds)`; ends with the shot | |
| `b:cancel(timer)` | stop a timer or coroutine | |
| `b:has_tag(tag)` | (tags: none yet) | |
| `b:steer_toward(pos_or_entity, rate)` | one-off turn of heading toward a target, `rate` rad/s | writes velocity |

`b:reflect(team, reverse)` / global `reflect(b, team, reverse)` returns `false`, changing nothing, for
a dead or already-marked-dead shot or a team other than `"player"`/`"enemy"`. On success the shot's
`owner_layer` becomes the new team, `hit_mask` becomes `Layers.hostile_to(new_owner)` (it can never hit
its new owner), the colour becomes the faction colour (`Layers.bullet_color`), and a piercing
bullet's last-hit memory is cleared. **Velocity is otherwise untouched**; set `b.vel`/`b.angle` in the
same callback to aim a parried shot. Reflect is output-side and always available; getting a handle to
an *enemy* bullet needs `sense.enemy_bullets` (see *Reading game state*).

Timers run on *game time*: they pause with the game and are stable across frame rate.

## Per-shot state

Each shot owns a private table `b.state`, initialised from the `state` spawn field
(deep-copied per shot). Use it for counters, lists of already-hit enemies, phase etc.

```lua
spawn { state = { hits = 0 }, on_hit = function(b, hit) b.state.hits = b.state.hits + 1 end }
```

Closures work too, but `state` is cheaper and survives hot reload (see below).
Weapon-level persistent state: the table `weapon.state` (shared across all fires).
Run-wide and weapon-level state are the same persistent table, `state` (PR #1: always available, survives respawn, saved in the save file). **[OI-7] answered.**

## Timers and sequences

```lua
b:every(0.2, function(b) b:spawn{ speed = 100 } end)      -- drip
b:after(1.0, function(b) b.speed = b.speed * 2 end)       -- boost after 1 s
b:run(function(b)                                         -- scripted path
  wait(0.5); b.spin = 3
  wait(0.5); b.spin = -3
end)
```

`wait(t)` is only valid inside `on_fire`, `b:run`, and timer callbacks created by
`b:run`; elsewhere it is an error with a clear message. Global `after(t, fn)` and
`every(t, fn)` exist for weapon-level timers (not tied to any shot).

## Homing and targeting

Native homing (no Lua per frame). **No engine equivalent yet** (see the mapping table): the field is accepted and ignored until `HurtboxGrid` exposes a query; until then use `on_batch`/`on_tick` with `sense.nearest_enemy` and `b:steer_toward`:

```lua
spawn { speed = 250, homing = { range = 300, turn = 4.0, target = "nearest" } }
```

| Field | Meaning |
|---|---|
| `range` | acquisition radius (px) |
| `turn` | max turn rate (rad/s) |
| `target` | `"nearest"` (default), `"lowest_hp"`, `"highest_hp"`, `"cursor"`, `"player"`, `"random"`, or an entity handle |
| `cone` | optional half-angle (rad) limit for acquisition, relative to heading |
| `retarget` | seconds between target re-evaluations (default 0.25) |
| `lose_after` | seconds without a target before homing disables (default: never) |

Custom targeting (scripted, whenever you like):

```lua
local t = sense.nearest_enemy and sense.nearest_enemy(b.pos, 400, { exclude = b.state.seen })
if t then b:steer_toward(t, 6) end
```

## Hits, splitting and chaining

### What the engine does on a hit, and what `on_hit` can and cannot do

Order inside `BulletManager.step` for each swept hit (PR #2): **`hurtbox.receive_hit(damage, pos, vel)`
fires first (the owner applies the damage)** -> **`on_hit(pool, index, hurtbox)`** -> if the bullet
was piercing, `pierce -= 1` and the last-hit memory is set, otherwise `mark_dead(HIT)`. Consequences:

- **`on_hit` is a notification, not a veto.** It runs *after* the damage was dealt, so its return value
  (the draft's old `return false`) is **ignored**; it cannot cancel the hit or consume less.
- **The damage of this hit is final**: `hit.damage` is what was dealt. Changing `b.damage` affects
  later hits only. Scaling damage the *player* takes is the owner's job (`on_hurt`, see *Writing player
  state*).
- Whether the bullet survives is decided before the hook (`pierce > 0` at impact), so a script cannot
  rescue a non-piercing shot from inside `on_hit`.

How to get "pass through / ignore this target / only some targets" instead:

| Want | Use today | Engine ask |
|---|---|---|
| pass through N targets | `pierce = N` (native, with anti-rehit memory) | exists |
| never hit some layers | `hit_mask` | exists |
| decide per target, before damage | `can_hit = function(b, target) return ... end` | **OI-18a**: optional `BulletBehavior.can_hit(pool, index, hurtbox) -> bool` called before `receive_hit`; synchronous, hit-rate only, counted against the script budget |
| refund a pierce after the fact | `b.pierce = b.pierce + 1` inside `on_hit` | **OI-18b**: re-read `pierce` after the hook instead of caching `piercing` |

`on_hit(b, hit)` receives a read-only table:

| Field | Meaning |
|---|---|
| `hit.target` | opaque target (`hurtbox`): `.layer`, `.radius`, and entity fields when a sense grants them |
| `hit.pos` | impact point (`prev_pos`..`pos` at `t`) |
| `hit.vel` | the bullet's velocity at impact |
| `hit.damage` | damage dealt (already applied by the owner) |
| `hit.normal` | unit normal pointing out of the target: derived natively as `(impact - hurtbox centre):normalized()` (circles) |

There is **no `hit.killed`**: the owner applies damage asynchronously (its health model decides), so a
synchronous hook cannot know. A `killed` signal may come with the enemy health work.

### Walls (`on_wall`)

`WallGrid` reports only the **time of impact `t`** along the swept path, not a surface normal, and
today a wall hit just despawns the bullet with `DespawnReason.WALL` after clipping it to the impact
point. So: `on_wall(b, wall)` is delivered as `on_death(b, "wall")`; `wall.pos` is the clipped position and
**`wall.normal` is `nil`** until the engine exposes it. **OI-17:** ask the Gameplay Engineer for a
`hit_normal` array next to `hit_t` (axis-aligned rectangles make this a face lookup) and a per-bullet
bounce count; `bounce` stays "none yet" until then.

### Splitting

```lua
b:split(5, { spread = rad(60), speed = "x0.8", damage = "x0.5", lifetime = 1.2 })
```

`b:split(n, opts)` spawns `n` children centred on the shot's current heading, evenly across
`spread`. In `opts`, the values `speed`, `damage`, `lifetime`, `radius` and `scale` are
either absolute numbers or multipliers of the parent's current value, written explicitly:

- `speed = "x0.8"` (multiplier) or `speed = 200` (absolute)
- `center` (angle, default: the shot's heading) is the middle of the fan; `pos` is where the children start.
  **After a hit, children must not start inside the hurtbox** (they would be hit again on the next swept test
  because only piercing bullets remember their last target): start at `hit.pos + hit.normal * (radius + 4)` and
  centre the fan on `hit.normal:angle()`, as `examples/split_on_hit.lua` does.
- same for `damage`, `lifetime`, `radius`, `scale`

Any other `spawn` field (including callbacks) is accepted and forwarded. Children inherit
`team`, `owner`, `color`, `tags`; they do **not** inherit callbacks unless `inherit = true`.

### Chaining

Chaining is the same tools composed: pick a new target, steer or respawn.

```lua
on_hit = function(b, hit)
  b.state.seen[hit.target] = true
  local nxt = sense.nearest_enemy(hit.pos, 250, { exclude = b.state.seen })
  if nxt and b.state.jumps > 0 then
    b.state.jumps = b.state.jumps - 1
    b:spawn { pos = hit.pos, angle = (nxt.pos - hit.pos):angle(),
             state = b.state, on_hit = b.on_hit_fn }  -- or define the callback as a local function and reuse it
  end
end
```

`sense.*` queries are fast spatial queries (over `HurtboxGrid`), not full scans, and exist only once the matching Fragment is earned (see below).

## Reading game state

**Always available (never gated, PR #1):** `ctx` (snapshot, above), `player` (live; readable and writable,
see the next section), the persistent `state` table, `ctx.dt`/`ctx.time`, `world.bounds` (arena
rectangle `x, y, w, h`), and reads of your own shots (`b.*`, `shots_in(pos, range)` for own shots,
`count_shots()`).

**Gated behind Senses (`sense.*`, earned with Fragments, PR #1 section 4).** A Sense you have not earned is
`nil`; scripts must work when it is missing. Senses are tied to boss *types*, not to kill order:

| Sense | Unlocked by | Level I (any boss kill) | Level II (clean kill) |
|---|---|---|---|
| `sense.nearest_enemy(pos, range?, opts?)` | free after the first 3 kills | nearest enemy or `nil`; `opts.exclude` (set keyed by entity), `opts.filter(e)` | same |
| `sense.enemies_in(pos, r, opts?)` | Warden (pool A, tier 0-1) | positions within 600 px (capped, see limits) | positions, velocities and hp in any radius |
| `sense.enemy_bullets` | Sower (pool A, tier 0-1) | handles of enemy shots in range (for `reflect`, bullet-eating) | + velocity/damage |
| `sense.terrain` (`:raycast(from, to)` -> `{ pos, normal }` or `nil`) | Prism (pool A, tier 0-1) | walls near a point | full raycast |
| `sense.boss` | Lattice (pool B, tier 2-3) | phase, weak point | + telegraphs |
| `sense.world` (seed, chunk coords) | Archivist (pool C, tier 4+) | | |

Gating is a *data* gate in the facade (the entry is `nil` / the query is absent), enforced natively;
no script can read an ungranted sense. Entity (enemy) fields: `e.pos`, `e.radius`, `e.kind`, `e:alive()`;
`e.vel`, `e.hp`, `e.hp_max` at Level II. Players cannot modify enemies directly; shots affect them through
hits.

Reads see the state at the start of the tick (before this tick's player writes apply).
`run.wave` / `run.score` are not in PR #1's design and are dropped until the open world defines them
(**OI-9**).

## Utilities

- `print(...)` / `log(...)` → the in-game console, tagged with the file and line
- `assert`, `error`, `pcall`, `xpcall` behave normally (a watchdog stop is not catchable)
- `require("name")` (capability `package`) loads another script from the player's script
  folder (no outside paths). Modules are cached per script load.
- `sound(name, opts?)`, `shake(amount)`, `flash(color)` cosmetic effects **[OI-5]**

## Per-frame logic: tick vs batch

Measured in the spike on Godot 4.7.2 (release template, see spike-results.md): Lua per-bullet
work is dominated by Variant crossings and per-element packed-array reads (~124 ns each), not
by the Lua VM. So per-frame logic comes in three grades:

| Grade | How | Cost (release, 4000 scripted bullets/tick) | Use for |
|---|---|---|---|
| **C declarative** | spawn fields (`spin`, `accel`, `homing`, ...) | 0 Lua | everything that can be data |
| **B batch** | `on_batch(bs, dt)` once per bucket | ~4.0 ms (slice) / ~4.9 ms (gather), **~1.0-1.2 us/bullet** | steering many bullets every tick (sine waves, orbits, flocking) |
| **A per-bullet** | `on_tick(b, dt)` | ~6.2 ms, **~1.6-2.1 us/bullet** | rare, small counts, convenience |

Both A and B support throttling: `tick_every = 4` (or `batch_slice = 4`, process a quarter
of the bullets per tick) cuts cost linearly (B slice 1/4 at 10000 bullets: 2.5 ms).

```lua
spawn { speed = 200, bucket = "wave",
        on_batch = function(bs, dt)            -- bs = struct-of-arrays view, 0-based
          for i = 0, bs.n - 1 do
            local a = bs.age[i] * 6
            bs.vx[i] = bs.vx[i] + math.cos(a) * 40 * dt     -- direct packed writes (~66 ns)
          end
        end }
```

`bs` fields (all packed arrays, 0-based): `id`, `x`, `y`, `vx`, `vy`, `age`, `a`, `b`
(the `param_a/param_b` columns), plus `n`. Writing `vx/vy` takes effect when the callback
returns. Structural effects go through `bs:spawn{...}`, `bs:kill(i)`, `bs:set_param(i, ...)`,
which append to a **command buffer** (stride-6 records) applied natively after the call.
The final layout is **[OI-15]** (see spike-results.md, *Interface diff*).

Event callbacks (`on_hit`, `on_wall`, `on_death`) are delivered through a capped queue:
default **256 events per behavior per tick**; overflow is *coalesced* into one summary
(`count`, summed `damage`, centroid) or dropped, with a drop counter in the script panel.
Events are not faster batched (measured), the cap exists for determinism and to survive
~2000 hits per frame (cap: 0.9 ms vs 5.1 ms uncapped at 2000 hits).

## Writing player state

Shot scripts may change the player, not only read it (PR #1: `player` is live, readable **and**
writable). The Lua `player` table is a thin proxy over the engine's validated script surface,
**`PlayerState`** (`player.state` in PR #4: "the single, validated surface a script (and the future Lua
binding) uses to read and change the player"):

```lua
player.hp = player.hp + 1        -- PlayerState.set_hp (0 kills)
player.invulnerable = 0.5        -- set_invulnerable(0.5): seconds, or true/false
player.pos = vec2(0, 0)          -- set_position: a teleport that resets interpolation
player.vel = player.vel * 2      -- set_velocity (speed clamped to 5000 px/s)
player.max_hp = 8                -- set_max_hp ([1, 1000]); raising does not heal
```

| Lua | `PlayerState` | Notes |
|---|---|---|
| `player.hp` r/w | `get_hp()` / `set_hp(v)` | clamped to `[0, max_hp]`; `0` kills (normal death and respawn); no i-frames, does not restart regeneration |
| `player.max_hp` r/w | `get_max_hp()` / `set_max_hp(v)` | clamped `[1, 1000]`; hp pulled down if needed |
| `player.invulnerable` r/w | `is_invulnerable()` / `set_invulnerable(seconds\|bool)` | seconds extend only (`0`/negative clears); `true` until cleared |
| `player.iframes` r | `get_invulnerable_time()` | any source (hit, dash, script) shares one timer |
| `player.pos` r/w | `get_position()` / `set_position(v)` | teleport; clamped to +-100000 |
| `player.vel` r/w | `get_velocity()` / `set_velocity(v)` | speed clamped to 5000 px/s |
| `player.dashing`, `player.can_dash` r | `is_dashing()`, `can_dash()` | |
| `player.dash_cd` r, `player.dash_cooldown` r | `get_dash_cooldown_left()`, `get_dash_cooldown()` | seconds |
| `player.dash_dir`, `player.aim_dir` r | `get_dash_direction()`, `get_aim_direction()` | unit `vec2` |
| `player.dead`, `player.regenerating` r | `is_dead()`, `is_regenerating()` | |
| `player.since_damage` r | `get_time_since_damage()` | seconds |

- **Validation lives in the engine.** `PlayerState` ignores NaN (with a warning), clamps infinities and
  out-of-range values, and is a no-op on a freed player. The Lua layer adds **no gameplay restriction**;
  it only rejects wrong *types* (a Lua error). `player.hp = 1e300` is clamped to `max_hp`, not refused.
- **When writes apply.** Assignments inside a callback are recorded in a write set (a later read in the same
  callback sees the new value) and **committed when the callback returns** (PR #1: "writes apply at the end
  of the current callback"); a callback that errors or is aborted by the watchdog commits **nothing**.
  - From `on_fire` / `update` (they run in weapon code, before the bullet step) the commit calls
    `PlayerState` directly.
  - From bullet callbacks (`on_hit`, `on_death`, `on_tick`, `on_batch`: mid-`BulletManager.step`) the commit
    is queued and applied at one defined point: **after the despawn phase of that step, before the render
    upload**. The player's hurtbox state is never changed while collision is running.
  - Several writes to one field in a tick: last wins. `+=`-style updates read the in-callback value.
- **Interaction with owner-applies-damage.** Damage to the player still flows through
  `hurtbox.receive_hit(damage, pos, vel)` and **`Health` applies it** (5 max hp, 0.75 s i-frames, regeneration
  after 5 s). `set_hp` does *not* go through `Health.damage`: no i-frames, no `damaged` signal, regen timer
  untouched, and a heal in the same tick as a hit lands after it (apply point). Scripts never call
  `receive_hit` on the player.
- **Scaling incoming damage:** `on_hurt = function(ctx, dmg, src) return dmg end` (weapon-level, PR #1 3.1) is
  called by `Health` before damage is applied; the return value replaces the damage (`0` = ignore). It is
  synchronous and hit-rate only, so it runs under the same budget as other callbacks. **Engine ask OI-16.**
- **Provenance for the "modified" tag (PR #1 section 12):** the facade records which writes came from
  scripts. `PlayerState` has a single shared invulnerability timer today, so the source (script vs hit vs
  dash) is not distinguishable; **OI-16** asks for a source flag.
- **Interface still needed from the Gameplay Engineer (OI-16):** `Health` hook for `on_hurt`
  (e.g. a `damage_modifier: Callable`), `PlayerState` accessors for `max_speed` (`player.speed`) and
  `regen_delay` / `regen_interval` / `regen_amount`, a dash trigger `try_dash(angle)` on the facade
  (`player.dash(angle)`: same action as the button, returns `false` on cooldown, **not** a state write),
  a source flag on invulnerability, and a `player_changed` signal for the UI.

## Capabilities and importing

Scripts run in a per-script environment built from a **capability set**. The weapon table
declares what it wants:

```lua
return { name = "Logger", needs = { "io" }, on_fire = function(ctx) ... end }
```

Capabilities, **most dangerous first**, with the exact labels the game shows:

| Capability | Label | What it gives |
|---|---|---|
| `native` | **Load native code. Can do anything to your computer.** | `package.loadlib`, C searchers, `package.cpath` |
| `os` | **Run programs and change your system.** | `os.*` including `os.getenv`, `os.execute`, `os.remove`, `os.rename`, **`io.popen`** (the only `io` member `os` brings); `os.exit` is replaced (below). `os.time` and `os.clock` are always available |
| `io` | **Read and write files.** | `io.*` **without `io.popen`** (running programs belongs to `os`). With both `io` and `os`, `io.popen` is present |
| `debug` | **Inspect and change Lua internals.** | `debug.*` minus the watchdog hook (below) |
| `package` | **Load Lua modules from disk.** | `require`, `package.path`, `package.loaded` |
| `net` | *reserved* | not implemented; unknown capabilities are ignored with a warning |

Base Lua (`string`, `table`, `math`, `utf8`, `coroutine`, `pcall`, `load`, `os.time`, `os.clock`, ...)
is always available. **Platform availability (PR #1 section 10):** on web `native`, `os`, `io` and `package` are
unavailable (the switches show disabled with the reason; the libraries are `nil`); on mobile `native` is
unavailable and `io`/`package` are limited to the app data folder. Engine rules that hold **regardless of what is granted**:

- **`os.exit` never kills the game**, even with `os`. It is replaced by a function that
  ends *that script* (the callback is stopped and the weapon paused, the game continues).
  Measured, see spike-results.md (B4).
- **With `debug` granted a script still cannot remove or replace the watchdog hook.**
  `debug.sethook` / `gethook` become no-ops, `debug.getregistry` is removed, and the real
  watchdog lives in a host callback outside Lua.
- **`load` is text only** (and uses the script's environment unless given one). Lua 5.4 has
  only `load` for compiling strings.
- Native code (`native`) is the only capability that can escape the guard rails; it has the
  strongest warning for that reason.

**Your own scripts:** a simple opt-in list (a switch per requested capability, no scary
warning), remembered per script.

**Imported or shared scripts (clipboard, workshop, file drop):** the game opens an *import
warning* first ("Scripts from other people can do anything their permissions allow. Only
enable what you understand.") with:

- one **switch per requested capability**, in the order above (most dangerous first),
  **all off by default**, each with its label;
- a **View source** button;
- **no "allow all"** on first run;
- the grant is **remembered per script content hash**, so any edit (or an updated copy of an
  imported script) asks again.

A script that needs a capability it was not granted still loads; the calls fail with a clear
error ("`io` not granted").

A more limited mode (reduced API, no engine-object access, determinism) is **planned later**
and not specified here. Determinism and seeding are **still open** (OI-2).

### Library opening

Per-`LuaState` library opening plus a per-script capability flag: the host opens all Lua
libraries in a trusted state, then builds the script's globals table from the capability set
and loads the script with that table as its environment (`load_string(code, name, env)`).
Without `GODOT_*` libraries opened, scripts cannot reach Godot classes; the engine API is
a facade of validated native callables. The spike's reference implementation is
`sandbox.lua` (see spike-results.md).

## Limits, errors and runaway protection

Limits exist to keep the game running; they are shown in the in-game script panel so you
can see how close you are. Values are starting values, aligned with PR #1 section 3.2 / 3.3.

| Limit | Default (tunable) | What happens when exceeded |
|---|---|---|
| Live bullets, total (pool) | **PC: 10,000**, floor **5,000** (the cap auto-lowers on weak hardware, never below the floor); web/mobile have their own starting values (PR #1 section 10) | new `spawn` calls beyond the player's share return `nil` and the editor shows "bullet cap reached" |
| Player share of the cap | **7,000 at 10,000; 3,500 at the 5,000 floor** (30% reserved for enemy and boss bullets: 3,000 / 1,500) | player-owned bullets are hard-capped at the share; enemy/boss bullets may use the whole pool. Needs per-owner live counters in `BulletPool` (**OI-18c**) |
| Pool capacity | `BulletManager.capacity` 16,384 (the logical cap sits below it) | a full pool drops the shot, observably (`get_dropped_count`, `pool_saturated`) |
| Spawns per tick | 500 per script | surplus returns `nil`/`false`, counted |
| Child generation depth | 16 | `spawn` returns `nil` with a one-time message |
| Instructions per callback | 100,000 VM instructions | callback aborted with `script timeout` (an error, nothing it wrote is committed) |
| Consecutive timeouts | 3 | **the script is suspended until it is saved again** (PR #1; replaces the draft's "3 aborts in one second") |
| Wall clock per callback | 50 ms hard abort (spike: 300 ms) | callback aborted, same handling as a timeout |
| Lua time per frame (all callbacks) | 3 ms PC, 2 ms web/mobile | see *When the budget runs out* |
| Script memory | **64 MB (adopted)**, lower on web/mobile | see *Memory cap* below |
| Events per behavior per tick | 256 dispatched | remainder is **deferred**, never dropped (see *One rule for events*) |
| Deferred-spawn buffer per tick | 8192 | surplus returns `false`, counted |
| Pattern-matching subject length | 1,024 chars (stock binding) | `string.find/match/gmatch/gsub` raise an error above it; native pattern code cannot be interrupted (1,024 chars worst case = ~4 ms) |
| `string.rep` result | 1 MiB (stock binding) | error |
| `enemies_in` result size | 256 | truncated, nearest first |

Instruction counts are approximate and may vary between platforms **[OI-10]**.

### When the per-frame budget runs out

(PR #1 3.3, adopted.) Hooked bullets (`on_tick` / `on_batch`) are the expensive path; plain bullets cost no
script time. When 3 ms is spent:

- bullets whose hook did not run **keep their last velocity and continue on native kinematics**
  (`acceleration`, `turn_rate`, lifetime, collision), they just skip the hook this tick;
- skipped hooks are scheduled **round-robin** from where the previous frame stopped; the manager skips
  natively (`update_interval`/slice) so skipped bullets cost ~0;
- they draw with alpha x 0.7 and the editor shows `!` with the count ("412 hooks skipped");
- over budget for 2 s: a warning with the hottest script lines; no restriction is applied.

### One rule for events (no silent drops)

`on_hit`, `on_wall`/`on_death` and `on_spawn` are **events, and events are never silently dropped**
(PR #1 3.3: "queued and run next tick"). Hooks (`on_tick`, `on_batch`) are *not* events: skipping a hook is
allowed and visible (above). The queue works like this:

1. Collision/despawn phases append compact event records (**copying** id, position, velocity, damage,
   reason and the `user` reference, because the bullet slot is gone by dispatch time).
2. Each tick, up to **256 events per behavior** are dispatched; the rest **stay queued** and are
   dispatched on the following ticks, oldest first.
3. Only above a hard queue bound (default 16,384 records) are further events of the same kind
   **coalesced** into one counted summary (`count`, summed damage, centroid), delivered to the callback
   with `summary = true`; the editor shows `!` "events coalesced". Nothing is discarded without a counter.

Measured (spike): the per-tick dispatch cap bounds the cost of a 2,000-hits-per-frame spike to ~0.7-0.8 ms
per tick instead of 4.4-4.9 ms. The "drop the rest" rows in the spike measure the per-tick cost of the capped
dispatch; under this policy the remainder is not dropped but drains over the following ticks at the same
bounded cost. Dropping is **not** the policy.

### What happens when a script errors

- **Error inside a shot callback** (`on_hit`, timer, ...): printed in the console with `file:line` and a
  traceback. That callback is disabled *for that shot* only; the shot keeps flying with its native motion and
  is removed normally. If a callback errors on more than 10 different shots, it is disabled globally until
  the script is reloaded.
- **Error in `on_fire`**: the fire is aborted, shots already spawned remain, the weapon stays usable, the
  cooldown still applies.
- **Runaway callback** (instruction/wall-clock limit): an error as above, and **nothing the callback wrote to
  `player` is committed**. After **3 consecutive timeouts the script is suspended until saved again.**
- **Syntax / load error**: the previous good version keeps running; a new shot never starts from a broken file.
- **Out of memory**: the script is suspended and the editor shows the usage (see below).

The game never freezes and never crashes from player script errors; that is a hard requirement and
a permanent test suite ([testing.md](testing.md)).

### Memory cap (decision)

The 64 MB cap **is adopted** (PR #1: "allocation beyond the cap raises a Lua error inside the script; the
script is suspended"). It is only fully enforceable with a **custom `lua_Alloc`** that returns `NULL`
past the cap, which the stock lua-gdextension 0.8.2 binary does not expose. Plan:

- **Stock binary (prototype / M1):** a *soft* cap: the host hook checks `get_memory_used()` every 1,000
  instructions and stops the script. Measured overshoot: 64 MB cap -> 83 MB peak with 1 MiB allocations in a
  loop (up to ~1,000 instructions x the per-call allocation limit can happen between checks). The per-call
  limits above (1 MiB `string.rep`) bound it; they do not remove it.
- **Source-built binding (target, see lua-binding.md):** a hard allocator cap, so the error is raised inside
  the script exactly as PR #1 specifies, and the same build puts the string/pattern limits into the Lua
  C library where no script can reach them.

### Sandbox

Everything here is the default for a script **without** extra capabilities. See
*Capabilities and importing* for what a grant changes.

Available: `base` (`assert`, `error`, `ipairs`, `next`, `pairs`, `select`, `tonumber`, `tostring`, `type`,
`raw*`, `setmetatable`, `getmetatable`, `pcall`, `xpcall`, `load`, `collectgarbage` with only
`collect/count/step`), `string` (bounded `rep` and pattern functions), `table`, `math`, `coroutine`
(wrapped so child coroutines carry the watchdog), `utf8`, `os.time`, `os.clock`, plus the APIs above.
Not available by default: `io`, `os` (beyond `time`/`clock`), `package`/`require`, `debug`, FFI,
raw Godot objects.

**Removed in every mode, with or without capabilities:** binary chunks (`load` is text-only and takes
strings only, no reader functions; `string.dump` does not exist), `dofile`, `loadfile` and the
Lua 5.1 string compiler (Lua 5.4 has only `load`), and `__gc` finalizers (see below).

**Hardening rules (spike-verified on Godot 4.7.2, lua-gdextension 0.8.2; details in spike-results.md, B4):**

1. **The abort survives `pcall`, `xpcall`, `__close` and error handlers.** Each callback runs in a host-owned
   coroutine with a host count hook that **yields** when the budget is exceeded; a yield is not an error, so
   `pcall` cannot catch it. After the verdict the hook fires on *every* instruction, so the first instruction
   outside a native call yields (this defeats loops that hide inside `table.sort` comparators under
   `pcall`). Two places run script code where a yield is impossible and hooks are off, so they are closed
   off: **message handlers** (`xpcall(f, handler)`: Lua runs the handler non-yieldable with hooks disabled, so
   a spinning handler hangs the game; the sandbox `xpcall` runs only a trivial handler and calls the script's
   handler afterwards, from normal context) and **`__gc` finalizers** (also run with hooks off:
   `setmetatable` refuses a metatable with `__gc`).
2. **Child coroutines are hooked.** A hook set on the main thread does not cover coroutines (measured: a
   30-million-iteration loop in a script coroutine ran to the end). The sandbox `coroutine.create/wrap`
   register each new thread with the host hook.
3. **The watchdog cannot be reached.** The hook is a host callable whose state lives outside Lua. With
   `debug` granted, `debug.sethook`/`gethook` are no-ops, `getregistry` is removed.
4. **Guards are not reachable through `debug` or `package.loaded`.** In the stock binding the bounded
   `string` functions are Lua wrappers, so a granted `debug` library would reach the original functions
   through `debug.getupvalue` (measured: a 256 MB `string.rep`; a 2.1 s pattern bomb) or through
   `debug.getlocal` on a wrapper frame. Therefore the granted `debug` library has **no
   `getupvalue/setupvalue/upvalueid/upvaluejoin/getlocal/setlocal/getregistry`** (it keeps `getinfo`,
   `traceback`, metatable access and the rest); `package.loaded` is a fresh view containing only granted
   libraries. In the source-built binding the limits live in C (`lstrlib.c` / the allocator) and `debug` can be
   offered whole. Honest limit: `debug` still means "inspect and change Lua internals"; it cannot lift a guard.
5. **`os.exit` never kills the game.** With `os` granted it is replaced: it flags the script and spins until
   the host hook ends it (also when called from a child coroutine).
6. **`io.popen` needs `os`; package C searchers 3 and 4 and `package.loadlib` need `native`**; `package.path`
   is limited to the script folder (`res://scripts/?.lua`).
7. **The engine facade is native.** `spawn`, `player.*`, `reflect` call validated native callables; script
   tampering (`rawset(_G, "spawn", nil)`, replacing `player`) only breaks the script's own environment, the
   next callback starts from a freshly built environment.

Known limits that stock lua-gdextension cannot close (need the source-built binding): a **single huge
native allocation** or a library function that never returns to the VM (pattern matching is bounded by the
1,024-char limit, not interrupted), **no hard memory cap** (soft, see above), and **no cross-thread
watchdog** (`set_hook` writes the registry, so it is not safe from another thread; the hook only fires
between VM instructions).

## Hot reload

Save the file and the game reloads it, no restart needed.

- New fires use the new code immediately.
- Shots **already in flight** keep running their old callbacks until they die (default),
  because mixing versions mid-flight would be surprising. Option: `reload = "migrate"`
  at the top of the weapon table to make in-flight shots switch to the new callbacks,
  matched by callback name, keeping `state`.
- Timers and coroutines of old shots finish with the old code.
- Weapon-level `state` is preserved if the new table declares the same keys.
- Reload errors never discard the working version (see above).

## Open interface questions

Refreshed against PR #1, #2 (2026abe) and #4. **Answered** items are kept so the numbers stay stable.

**Answered**

- **[OI-1]** Coordinates: y down, radians, 0 = +x, clockwise, `NAN` angle faces velocity, 60 Hz.
- **[OI-7]** Persistence: `state` is persistent, always available, survives respawn, saved (PR #1).
- **[OI-11]** Sandbox policy: full Lua for own scripts, opt-in capabilities, import warning, limited mode later (PR #1 Q2).
- **[OI-12]** Fixed 60 Hz; the native motion subset is `acceleration`, `turn_rate`, `pierce`, `collide_world`, `param_a/b`
  (see the mapping table for what is missing).
- **[OI-13]** Pool layout and handles: dense SoA, swap-remove, stable ids `(generation<<32)|handle`, `pool.user`.

**For the Gameplay Engineer**

- **[OI-3]** Teams: `owner_layer` + `Layers.hostile_to`, no shot-vs-shot collisions, own layer stripped (answered by PR #4); open: custom factions?
- **[OI-4]** Hit pipeline: owner applies damage in `receive_hit`, `on_hit` runs after (answered; see *Hits*).
- **[OI-5]** Rendering: sprite names, trails, feedback effects, ownership.
- **[OI-6]** Spatial queries for `sense.*` / `near`: nearest/in-range query on `HurtboxGrid` with a cost bound.
- **[OI-8]** Enemy hit responses (absorb / reflect / armor, PR #1 5.1): are they decided in the hurtbox owner or in
  the bullet system, and how does a script learn the response (`hit.response`)? Also parry: PR #4 notes the
  `reflect_bullet` mechanism exists but no trigger decides which bullets get reflected.
- **[OI-14]** `pool.user` / `ShotRequest.user`: ref-counted copy, reset on despawn (answered); event records must hold the reference.
- **[OI-15]** Hook interface: `update_mode` (NONE/PER_BULLET/BATCH), `update_interval`, `event_mask`, `event_cap`,
  `on_update_batch`, `on_events`, command buffer, `ShotEmitter.request_polar` / `request_batch` (spike-results.md).
- **[OI-16]** Player: `Health` hook for `on_hurt`, `PlayerState` accessors for `max_speed` and regen parameters,
  `try_dash(angle)`, invulnerability source flag, `player_changed` signal.
- **[OI-17]** `WallGrid`: a `hit_normal` array next to `hit_t`; bounce count; `on_wall` event.
- **[OI-18]** (a) `BulletBehavior.can_hit(pool, index, hurtbox) -> bool` before `receive_hit`; (b) re-read `pierce`
  after `on_hit`; (c) per-owner live counters in `BulletPool` for the 70/30 player/enemy split.
- **[OI-19]** `BulletPool.teleport(index, position)` (coming in PR #2) and `reflect` exposure confirmed (PR #4); batch
  position writes use a `TELEPORT` command.

**For Karyu** (still open)

- **[OI-2]** Determinism and seeding (RNG, timers, cross-platform replay).
- **[OI-9]** Run information (waves, score) and upgrades scripts may see; `run.*` is dropped until defined.
- **[OI-10]** Is cross-platform exact behaviour (instruction counts, web vs desktop) required?
- Shape of the planned limited/Constrained mode (PR #1 Q10/Q11): reduced API, no engine access?
- Do capability labels and the import warning need localisation or a different tone?
