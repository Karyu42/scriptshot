# Native bullet core

Hybrid C++ migration. A small GDExtension (`NativeBulletSim`, `native/`)
advances **hook-free** bullets: plain shots, declarative ones (kinematics
only, no per-bullet hook), and **batch-hook** bullets. Bullets with a
per-bullet hook stay in the GDScript `BulletPool`, and that pool remains the
default and the fallback.

**Status: opt-in, Linux x86_64.** Not wired into CI. The game does not move
bullets unless native is opted in and the library loaded. Hooked bullets never
move to C++.

## What this PR does

- GDExtension build wiring (`native/SConstruct`, `scriptshot_native.gdextension`,
  `tools/build_native.sh`, `tools/check_extension_api.sh`).
- `NativeBulletSim`: struct-of-arrays store, stable ids (generation-checked,
  bit 62 set so they are not pool slots), integrate, wall sweep, swept hurtbox
  tests, pierce, swap-remove, and the interpolated MultiMesh upload.
- `BulletManager` routes a hook-free bullet to that sim only when native is
  selected **and** the spawn is not inside a hook. A bullet is hook-free when
  `behavior_id` is 0, or its behaviour's mask calls no event hook (`on_spawn`,
  `on_hit`, `can_hit`, `on_despawn`) and the script does not override
  `on_update`. A **batch-only** behaviour (an `on_update_batch` override, or
  `update_mode = BATCH`, and no per-bullet hook) is hook-free: its bullets
  live in the sim. Any unmasked event hook, or an `on_update` override, stays
  in the pool. `spawn_child()` and spawns made while a hook is running stay in
  the pool too, including a spawn from `on_update_batch`: native integrate has
  already run, so a child handed to the sim would be swept a tick early, and
  owner inheritance already lives on the pool. The next batch still includes
  a pool bullet of that behaviour. That split is a reversible default.
- **Hook-free bullets stay native when reflectors are registered.** The sim
  sweeps the same active `Reflector` circles the pool does (registry order,
  after `on_update`) and asks `Reflector.evaluate()` for the guard, the arc
  and the new heading, so REVERSE, MIRROR, AIM_AT_TARGET, partial arcs,
  `max_reflections` (including 0 = unlimited and a zone's own limit) and the
  reflected damage cannot drift. It then applies the same owner change,
  colour, hit mask, hit-memory clear, reflect count and speed clamp, and
  clears `SOURCE_PIERCES_SCRIPT_INVULN` unless `keep_script`. The bullet is
  teleported to the impact and flies the rest of the tick; a wall on that
  leg uses `WallGrid.box_normal` (corner, tangent and inside-face rules, lower
  wall index on a time tie). A zone that appears in `on_update` is in this
  tick's sweep. One that appears during hit delivery is not, same as the
  pool, and the bullets are not migrated. Per-bullet hooks, including
  `can_hit`, stay on the pool.
- **Script `reflect_bullet()` on a native id is deferred until after the move.**
  Measured on the GDScript pool: `BulletPool.reflect` runs inside the call.
  `advance()` has already moved the bullet, so this tick's position is the
  pre-reflect travel, while velocity, owner, mask, colour, damage and
  `reflect_count` change immediately. The same tick's wall, zone and hurtbox
  sweeps then see that new state (a hurtbox hit reports the reflected damage
  and velocity). A second call in the same tick sees the updated count, so the
  default cap of 1 makes it return false and change nothing; with
  `max_reflections == 0` both calls apply, in order. A call outside
  `on_update` — before any step, between steps, or from `on_despawn` — also
  applies immediately, and the next `advance` is what travels on the new
  velocity. A bullet `advance` already killed this tick (lifetime, or it left
  the world) returns false. A wall or hurtbox death happens later, so the call
  still returns true and the bullet then dies.
  Native `on_update` runs before `NativeBulletSim` moves. Applying there would
  integrate the new velocity in the same tick. The call is queued instead. The
  bool is decided at the call (the same checks, plus reflects already queued
  this tick, plus whether this tick's integrate will kill it for lifetime or
  bounds). The mutation runs after that move and before the sweeps, and it
  does not change position. The bullet stays in the sim and its id does not
  change. If it dies in the move, or the slot is reused (the queued id's
  generation no longer matches), the op is dropped. Calls after the move, and
  calls outside `step()`, apply immediately. A read of the native bullet still
  inside that `on_update` sees the pre-move fields; the pool would already
  show the post-advance, post-reflect bullet. After `step()` returns, position,
  velocity and owner match. No queued reflect means the single `step()` pass,
  unchanged.
- **Batch hook.** `BulletBehavior.on_update_batch(batch)` runs once per tick
  for a behaviour, after that store's integrate and before collision — the
  same window as a deferred script reflect. The argument is a `BatchView`:
  packed copies of `id`, `px`, `py`, `vx`, `vy`, `age`, `pa`, `pb`, `owner`
  (0-based, `n` rows). Writable columns are `vx`, `vy`, `pa`, `pb`. `kill`,
  `teleport` and `spawn_child` are commands. All of it is applied when the
  callback returns, and only if the stable id still names that bullet. A
  despawn, or a slot reused under a new generation, drops the write. A script
  error sets `discard` and commits nothing. An empty behaviour (no live
  bullets) does not enter the callback. With the GDScript backend the same
  view is filled from the pool and the semantics match. Lua `on_batch(v, dt)`
  is that object. The six defaults below are current behaviour. Each may be
  extended later; none of them is a zero-copy change.
  1. **Every-tick cadence.** Every live bullet of the behaviour is in the view
     every tick. No `update_interval` and no `update_slice`.
  2. **No view reflect.** The view has no reflect command. Call
     `reflect_bullet()`. After the sim has moved, that call applies immediately.
  3. **`spawn_child` only.** It creates a declarative child (`behavior_id` 0).
     There is no `spawn{}` / `spawn_polar` on the view.
  4. **Read-only columns.** `px`, `py`, `age`, `id` and `owner` are read-only.
     A position change goes through `teleport`.
  5. **`on_update` stays per-bullet.** Overriding `on_update` keeps the bullet
     on the pool and does not also run the batch hook, unless `update_mode`
     is `BATCH`. Explicit `BATCH` plus `on_update` still lives on the pool,
     and both run.
  6. **Hook spawns stay on the pool for life.** A bullet spawned inside a hook,
     including `on_update_batch`, is born on the GDScript pool and is not
     migrated into the sim later.
  **Zero-copy stays off.** The columns are packed copies through stock
  lua-gdextension. There is no lua-gdextension fork and no zero-copy view.
  Packed copies are the backing that was measured: native batch work p95 was
  **1.80 ms at 5,000** and **3.23 ms at 10,000** (table below), which is
  inside the budget, so the copy is not the thing to remove next. A later
  zero-copy column could replace the arrays inside `BatchView` without a
  script change. That decision is not this slice.
- Hits from both stores in one tick are delivered in shared seq order, the
  order a single pool would walk. A hurtbox turned off by an earlier bullet
  is skipped for the later one, on both backends.
- Both stores share one saturation model (logical cap, enemy reserve, owner
  counters, drop reasons, the rate-limited warning and `pool_saturated`).
  Dead-but-not-flushed bullets still hold a slot.
- Spawn limits match `BulletLimits`: `NativeBackend` clamps with those
  constants and passes `MAX_SPEED` into `configure`. The extension does not
  hard-code a second ceiling. A non-finite shot is refused.
- GDScript is the fallback and the default. `backend_preference` defaults to
  `"gdscript"`, so loading the library does not move bullets on a manager that
  did not opt in. `"native"` uses the extension or, if it is missing, logs
  **one** warning and stays on GDScript. `"auto"` (the main scene and the
  benchmark) resolves `--bullet-backend=`, then `SCRIPTSHOT_BULLET_BACKEND`,
  then the project setting `scriptshot/bullets/backend` (default `gdscript`).

`spawn()` returns a pool slot for GDScript bullets and a native id for plain
native bullets. `ShotEmitter.request_shot_id()` / `is_bullet_alive()` understand
both. `alive_count()`, `spawned_total()`, and `snapshot()` cover both stores.

## Backend selection

`BulletManager.backend_preference`:

| value | result |
|---|---|
| `"gdscript"` (export default) | pool only. Ignores the CLI, the env var and the project setting. |
| `"native"` | hook-free bullets in `NativeBulletSim` if the extension loaded, otherwise GDScript plus one warning |
| `"auto"` | `--bullet-backend=`, else `SCRIPTSHOT_BULLET_BACKEND`, else `scriptshot/bullets/backend`, else GDScript |

`spawn()` on the native backend returns a native id, not a pool slot. The
unit tests that index the pool are written for GDScript and leave the
preference at the default, so do not point the whole suite at native with the
environment variable. The native tests set `"native"` themselves.

```
./tools/build_native.sh
./tools/run_tests.sh                         # extension missing: native tests pending
./tools/run_tests.sh                         # extension built: the same tests run
./tools/run_tests.sh -gselect=native         # the opt-in tests only

# Benchmark. Hooked bullets stay on GDScript either way. Do not change the
# 22 ms hooked gate; these flags only select the pool under measurement.
./tools/run_benchmark.sh --backend=gdscript --hooked=0
./tools/run_benchmark.sh --backend=gdscript --hooked=1
./tools/run_benchmark.sh --backend=native --hooked=0
./tools/run_benchmark.sh --backend=native --hooked=1
# One batch hook steering every bullet (GD pool vs native sim). Not the hooked gate.
./tools/run_benchmark.sh --backend=gdscript --batch=1 --bullets=5000,10000
./tools/run_benchmark.sh --backend=native --batch=1 --bullets=5000,10000
# Same opt-in as the game, because the benchmark's default preference is auto:
./tools/run_benchmark.sh --bullet-backend=native
# Reflection workload (default --mirrors=0 is the original bench):
./tools/run_benchmark.sh --backend=native --mirrors=8 --bullets=5000
```

The shipped scenes (`scenes/main.tscn`, `scenes/sandbox.tscn`) set
`backend_preference` to `auto`. With the project setting left at `gdscript`
and no flag, they stay on the pool. To try native locally: build the library,
then either set `scriptshot/bullets/backend` to `native` or launch with
`--bullet-backend=native`.

`bin/` is gitignored. `scriptshot_native.gdextension` lists only the Linux
x86_64 release library (editor and debug point at it too). Without that
library Godot logs that the GDExtension binary is missing and the game keeps
using GDScript. Native tests report as pending; the rest of the suite still runs.

## Build pins

| Thing | Pin |
|---|---|
| godot-cpp | `10.0.0-stable` (`507ed9d`), submodule `native/godot-cpp`, `api_version=4.7` |
| Godot | 4.7.2 |
| SCons | 4.10.1 |
| Emscripten (web, not built here) | 4.0.11 |
| Android NDK (not built here) | r29 (`29.0.14206865`), matching Godot 4.7.2 |

```
pip install scons==4.10.1
./tools/build_native.sh            # -> bin/linux/libscriptshot_native.linux.template_release.x86_64.so
./tools/check_extension_api.sh     # godot-cpp API json == this Godot binary's dump
```

## Tests

- `tests/unit/test_native_backend.gd`: load/switch, the project setting and the
  CLI flag, one warning when the library is missing, declarative vs hooked
  routing, hook spawns staying in the pool, the shared cap and enemy reserve,
  walls, swept hits, speed clamp, despawn, snapshot. Pending when the extension
  is not built (the missing-library warning test runs either way).
- `tests/unit/test_native_reflection.gd`: wall normals (faces, corners, grazing,
  inside, index ties), per-tick reflection parity, `max_reflections` including
  0, pierce plus reflect, mixed-store hit order, dynamic zones, script
  invulnerability flags, and script `reflect_bullet()` on a native id (same-tick
  position / velocity / owner, repeated calls, a despawn or a reused slot
  before the deferred op, calls outside `on_update`, return values). The
  GDScript timing test runs either way. The native half is pending when the
  extension is not built.
- `tests/unit/test_native_parity.gd`: the same scenarios on both backends.
  Seeded positions within 0.01 and velocities within 0.05, hit signatures,
  kinematics after 90 ticks, slow-overlap impact, pierce hit-memory, wall and
  despawn order, the camera window, saturation counts, damage flags. Pending
  when the extension is not built.
- `tests/unit/test_bullet_manager.gd` forces `"gdscript"` and still inspects
  the pool. Hook masks, `sweep_cross_writes()`, and the speed clamp on that
  path are untouched.
- `tests/unit/test_batch_hook.gd`: GD batch reads and writes, owner, empty
  batches, kill and spawn, stale-id reuse, non-finite writes, the speed clamp,
  teleport, and mixed per-bullet plus batch scripts. The native cases (same
  pos/vel/owner, stale ids, hook spawns staying on the pool, mixed routing)
  are pending when the extension is not built.
- `tests/scripting/integration/test_lua_batch_hook.gd`: Lua `on_batch` over the
  packed columns, a script error that commits nothing, an empty batch, kill
  and `spawn_child`, `on_tick` still not a hook, and `on_batch` next to
  `on_hit` staying on the pool.

Short non-piercing paths use the pool's endpoint test, so a bullet that is
already overlapping a target is reported at its end position on both sides.
A hurtbox turned off earlier in the same tick is skipped at delivery on both
sides and does not consume pierce. The pierce ring is `BulletPool.HIT_MEMORY`
(8): only a pierce hit that lands is recorded, and the oldest id falls out.
The camera window recentres the native grids with the GDScript ones; bullets
outside the new rect despawn on the next step.

The seeded parity case still allows one tick of travel on swept impact points,
so a contact that drifts by a fraction of a pixel does not fail the run.
Survivors are compared within 0.01 px.

Work p95 on this VM (Godot 4.7.2 headless, 120 warmup + 600 frames, the
benchmark's 32 hurtboxes and 28 walls). Hooked rows are `on_update` on every
bullet, so they stay in the GDScript pool even when native is selected.

| bullets | hooks | gdscript | native |
| ---: | --- | ---: | ---: |
| 5,000 | plain | 7.41 ms | 0.85 ms |
| 10,000 | plain | 14.65 ms | 1.50 ms |
| 5,000 | hooked | 11.45 ms | 11.44 ms |
| 10,000 | hooked | 22.55 ms | 22.91 ms |

Plain native bullets were entirely in `NativeBulletSim` (pool count 0). Hooked
runs were entirely in the pool (native count 0). The default-backend hooked 5k
sample is under the 20 ms soft bar and the 22 ms hard gate. 10k hooked only
warns. These are one machine, not a CI gate.

Batch rows are one `on_update_batch` doing `vx += cos(age * 6) * 40 * dt` for
every bullet (120 warmup + 600 frames, same scene). GDScript keeps them in the
pool. Native keeps them in the sim (pool count 0). This is not the hooked gate.
A separate hooked-5k run on this machine after the change was 13.03 ms p95,
still under the 20 ms soft bar and the 22 ms hard gate, and still entirely in
the pool.

| bullets | batch | gdscript | native |
| ---: | --- | ---: | ---: |
| 5,000 | one hook | 24.37 ms | 1.80 ms |
| 10,000 | one hook | 53.66 ms | 3.23 ms |

`--mirrors=N` adds reflector zones (both factions, pool cap lifted so bullets
keep bouncing) on top of that workload. With 8 mirrors at 5k plain bullets the
same machine measured work p50/p95 of 13.97/14.20 ms on GDScript and 0.95/1.04 ms
native, with every bullet still in the sim (pool count 0).

## Out of scope

Left for later PRs, on purpose:

- Moving per-bullet hooks (`on_update`, `on_hit`, `can_hit`, `on_despawn`)
  into C++. Those bullets stay on the GDScript pool.
- Zero-copy stays off. Packed copies measured 1.80 ms / 3.23 ms work p95 at
  5k / 10k native batch, which is inside the budget. A later column could
  replace the copies without a script change. This tree does not fork Lua.
- The six batch defaults above, if a later slice extends one of them:
  `update_interval` / `update_slice`, a reflect command on the view, a
  `spawn{}` form, writable position columns, batch-calling an `on_update`
  bullet without `update_mode = BATCH`, or moving a hook-spawned bullet into
  the sim. Current behaviour is the list in the batch-hook bullet.
- Full platform matrix (Windows, macOS, Android, web) and CI build wiring.
- `can_hit` vetoes inside the C++ sim. A bullet whose mask includes `can_hit`
  stays on the GDScript pool, and so does every other per-bullet hook.
- Clamp warnings. The pool warns when it clamps a shot; the native facade
  clamps silently to the same limits.
- A shared id space. Native ids use bit 62.
