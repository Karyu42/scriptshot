# Scriptshot shot scripting API (draft v0.1)

Status: **draft for review**. Nothing here is implemented yet. Points that depend on the
bullet system being built by the Gameplay Engineer are marked **[OI-n]** (open interface
question) and collected at the end.

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
4. **Safe by default, not restrictive.** The Lua environment has no file/OS access, but
   there is no whitelist of what a shot may *do* in the game world. Limits are on
   resources (instructions, bullets), not on creativity.
5. **Mistakes are survivable.** A bug in your script never crashes the game or freezes it.
   You get a readable error with file and line.

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

`ctx` (read-only table):

| Field | Meaning |
|---|---|
| `ctx.pos` | muzzle position (`vec2`) |
| `ctx.aim` | aim angle in radians (0 = +x, counter-clockwise positive; see [OI-1]) |
| `ctx.aim_dir` | aim as unit `vec2` |
| `ctx.owner` | the player entity handle (see *World*) |
| `ctx.charge` | seconds the fire button was held before release (0 for plain fire) |
| `ctx.n` | how many times this weapon has fired this run (handy for alternating patterns) |

`on_fire` may run as a **coroutine** (it always does): you can call `wait(seconds)`
inside it to create bursts and sequences. It is fine for a single trigger pull to take
several seconds to finish.

Optional weapon-level fields: `name`, `cooldown`, `ammo`, `on_fire`, `on_equip`,
`on_unequip`.

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
| `team` | owner's team | `"player"`, `"enemy"`, or any custom tag; hits opposite team. **[OI-3]** |
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
| `on_wall(b, wall)` | on contact with a wall/obstacle (called *before* `bounce` is applied) |
| `on_expire(b)` | lifetime ran out |
| `on_death(b, why)` | always called once when the shot is removed. `why` is `"hit"`, `"expire"`, `"wall"`, `"killed"`, `"limit"`, `"cleanup"` |
| `on_tick(b, dt)` | every physics tick. **Metered.** Use sparingly. |
| `on_near(b, other)` | enemy or shot entered `near_radius` (set `near_radius`) **[OI-6]** |

Spawning from inside another shot: `b:spawn{...}` is the same as `spawn{...}` but with
`pos`, `angle`, `team`, `owner`, `damage` and `parent` defaulted from `b` and
`generation = b.generation + 1`.

## The shot handle (`b`)

Handles are lightweight references. If the shot has died, a handle is *dead*; every
call on a dead handle is a safe no-op and `b:alive()` returns `false`.

Readable and writable (changes apply immediately to the native shot):

`b.pos`, `b.x`, `b.y`, `b.vel`, `b.speed`, `b.angle`, `b.spin`, `b.accel`, `b.damage`,
`b.radius`, `b.lifetime` (remaining), `b.pierce`, `b.bounce`, `b.color`, `b.scale`, `b.homing`

Read-only: `b.age`, `b.team`, `b.owner`, `b.parent`, `b.generation`, `b.id`, `b.tags`

Methods:

| Method | Does |
|---|---|
| `b:alive()` | is it still in play |
| `b:kill(why)` | remove it now (runs `on_death` with `"killed"`) |
| `b:spawn{...}` | spawn a child (see above) |
| `b:split(n, opts)` | spawn `n` children fanned out; see *Splitting* |
| `b:every(dt, fn)` | call `fn(b)` every `dt` seconds; returns a timer; stops if the shot dies |
| `b:after(dt, fn)` | call `fn(b)` once after `dt` seconds |
| `b:run(fn)` | run `fn(b)` as a coroutine that may `wait(seconds)`; ends with the shot |
| `b:cancel(timer)` | stop a timer or coroutine |
| `b:has_tag(tag)` | |
| `b:steer_toward(pos_or_entity, rate)` | one-off turn of heading toward a target, `rate` rad/s |

Timers run on *game time*: they pause with the game and are stable across frame rate.

## Per-shot state

Each shot owns a private table `b.state`, initialised from the `state` spawn field
(deep-copied per shot). Use it for counters, lists of already-hit enemies, phase etc.

```lua
spawn { state = { hits = 0 }, on_hit = function(b, hit) b.state.hits = b.state.hits + 1 end }
```

Closures work too, but `state` is cheaper and survives hot reload (see below).
Weapon-level persistent state: the table `weapon.state` (shared across all fires).
Run-wide state: `run.state`. **[OI-7]** (whether state survives death/respawn)

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

Native homing (no Lua per frame):

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
local t = world.nearest_enemy(b.pos, 400, { exclude = b.state.seen })
if t then b:steer_toward(t, 6) end
```

## Hits, splitting and chaining

`on_hit(b, hit)` where `hit` is a read-only table:

| Field | Meaning |
|---|---|
| `hit.target` | entity handle of what was hit |
| `hit.pos` | contact point |
| `hit.normal` | surface normal at contact |
| `hit.damage` | damage actually dealt (after armour etc.) |
| `hit.killed` | `true` if the hit killed the target |

Returning `false` from `on_hit` cancels the engine's default consequences for this shot
for this hit (it will not be consumed, e.g. does not lose `pierce`). Returning nothing is
the default behaviour. **[OI-4]** (is that cancellation compatible with the damage pipeline?)

### Splitting

```lua
b:split(5, { spread = rad(60), speed = "x0.8", damage = "x0.5", lifetime = 1.2 })
```

`b:split(n, opts)` spawns `n` children centred on the shot's current heading, evenly across
`spread`. In `opts`, the values `speed`, `damage`, `lifetime`, `radius` and `scale` are
either absolute numbers or multipliers of the parent's current value, written explicitly:

- `speed = "x0.8"` (multiplier) or `speed = 200` (absolute)
- same for `damage`, `lifetime`, `radius`, `scale`

Any other `spawn` field (including callbacks) is accepted and forwarded. Children inherit
`team`, `owner`, `color`, `tags`; they do **not** inherit callbacks unless `inherit = true`.

### Chaining

Chaining is the same tools composed: pick a new target, steer or respawn.

```lua
on_hit = function(b, hit)
  b.state.seen[hit.target] = true
  local nxt = world.nearest_enemy(hit.pos, 250, { exclude = b.state.seen })
  if nxt and b.state.jumps > 0 then
    b.state.jumps = b.state.jumps - 1
    b:spawn { pos = hit.pos, angle = (nxt.pos - hit.pos):angle(),
             state = b.state, on_hit = b.on_hit_fn }  -- or define the callback as a local function and reuse it
  end
end
```

`world.nearest_enemy` and friends are fast spatial queries, not full scans.

## Reading game state

All read-only snapshots; reading is cheap.

| API | Returns |
|---|---|
| `world.time` | game time (s) |
| `world.dt` | the fixed tick length |
| `world.player` | the player entity; `.pos`, `.vel`, `.hp`, `.hp_max`, `.aim` |
| `world.cursor` | aim cursor position (`vec2`) |
| `world.bounds` | arena rectangle: `x, y, w, h` |
| `world.nearest_enemy(pos, range?, opts?)` | entity or `nil`; `opts.exclude` is a set (table keyed by entity), `opts.filter(e)` optional |
| `world.enemies_in(pos, range, opts?)` | array of entities (capped, see limits) |
| `world.shots_in(pos, range, opts?)` | array of shot handles (own team by default) |
| `world.count_shots()` | live shots owned by the player |
| `world.raycast(from, to)` | first wall hit: `{ pos, normal }` or `nil` |
| `run.wave`, `run.score`, `run.seed` | run info **[OI-9]** |

Entity (enemy) fields: `e.pos`, `e.vel`, `e.hp`, `e.hp_max`, `e.radius`, `e.kind`, `e.tags`,
`e:alive()`. Players cannot modify enemies directly; shots affect them through hits.
**[OI-4]**

## Utilities

- `print(...)` / `log(...)` → the in-game console, tagged with the file and line
- `assert`, `error`, `pcall`, `xpcall` behave normally
- `require("name")` loads another script from the player's script folder (no outside paths).
  Modules are cached per script load.
- `sound(name, opts?)`, `shake(amount)`, `flash(color)` cosmetic effects **[OI-5]**

## Limits, errors and runaway protection

Limits exist to keep the game running; they are shown in the in-game script panel so you
can see how close you are.

| Limit | Default (tunable) | What happens when exceeded |
|---|---|---|
| Live shots per player | 4000 | `spawn` returns `nil`; a counter on screen blinks; **oldest-first culling is *off* by default** |
| Spawns per tick | 500 | the surplus returns `nil` |
| Child generation depth | 16 | `spawn` returns `nil` with a one-time message |
| Instructions per callback | 100,000 | callback aborted with `"callback used too many instructions"` |
| Lua time per frame (all callbacks) | 3 ms | remaining queued callbacks are **deferred** to the next tick (never dropped silently); if the queue stays over for 2 s, you get a warning |
| Single `wait`-less loop (`while true do end`) | falls under the instruction limit | callback aborted |
| Script memory | 64 MB | script is stopped (see below) |
| `enemies_in` / `shots_in` result size | 256 | truncated, nearest first |

Instruction counts are approximate and may vary between platforms **[OI-10]**.

### What happens when a script errors

- **Error inside a shot callback** (`on_hit`, timer, ...): the error is printed in the
  console with `file:line` and a traceback. That callback is disabled *for that shot*
  only; the shot itself keeps flying with its native motion and is removed normally.
  Other shots are unaffected. If a callback errors on more than 10 different shots, the
  callback is disabled globally until the script is reloaded (to avoid error floods).
- **Error in `on_fire`**: the fire is aborted, shots already spawned remain. The weapon
  stays usable; the cooldown still applies.
- **Runaway callback** (instruction limit hit): treated as an error, same handling.
- **Syntax / load error**: the previous good version of the script keeps running.
  Console shows the error. A new shot never starts from a broken file.
- **Out of memory or three runaway aborts in one second**: the weapon is paused;
  shots in flight keep their native motion; press `R` or edit-and-save to resume.

The game never freezes and never crashes from player script errors; that is a hard
requirement for the implementation.

### Sandbox

Available: `base` (minus `dofile`, `loadfile`, `load` of binary chunks), `string`,
`table`, `math`, `coroutine`, `utf8`, plus the APIs above.
Not available: `io`, `os`, `package` (except the restricted `require`), `debug`, FFI,
raw access to the Godot object API. **[OI-11]** (decide whether power users can opt in to
engine-object access in a "no leaderboard" mode)

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

For the **Gameplay Engineer** (bullet system):

- **[OI-1]** Coordinate conventions: angles in radians, y-down (Godot screen) so positive
  rotation is clockwise on screen? The doc currently says "counter-clockwise positive";
  should match whatever the bullet system uses.
- **[OI-3]** Teams/collision layers: is "team" a physics layer pair, or an enum?
  Can the player's shots hit other shots (shot-vs-shot)?
- **[OI-4]** Hit pipeline: where does damage get applied, can a callback modify it
  (`return false` / change `hit.damage`)? Knockback and status effects: engine-side?
- **[OI-6]** Spatial queries: is there a spatial hash / `PhysicsServer2D` area query for
  "nearest enemy" and "near" events? Which cost per query?
- **[OI-13]** Is the bullet pool a single pool with struct-of-arrays data, a `MultiMesh`,
  or `Node2D`s? Can the scripting layer own handles of the form `(index, generation)`?
- **[OI-12]** Are bullets simulated in `_physics_process` at a fixed rate (assumed 60 Hz)?
  Is the native motion model above (accel, spin, drag, homing, bounce, pierce) acceptable
  to implement natively, and which of those already exist?
- **[OI-5]** Rendering: sprite names, colours, trails, and feedback effects, and who owns them.

For **Karyu**:

- **[OI-2]** Should runs be deterministic / seedable (affects RNG and timers)?
- **[OI-7]** Persistence: is script state per-run or persistent (unlocks, upgrades)?
- **[OI-9]** What run information (waves, score) should scripts see? Are there upgrades
  or mutators that scripts should be able to read or interact with?
- **[OI-10]** Is cross-platform exact behaviour (instruction counts, web vs desktop) required?
- **[OI-11]** Sandbox policy: strict for everyone, or an opt-in power mode?
- Limits: are 4000 live shots / 3 ms per frame the right headline targets?
- Is sharing scripts (workshop, import from clipboard) in scope? It changes how strict the
  sandbox must be.
