# Native bullet core

Hybrid C++ migration. A small GDExtension (`NativeBulletSim`, `native/`)
advances **hook-free** bullets: plain shots and declarative ones (kinematics
only, no per-bullet hook). Bullets with a per-bullet hook stay in the GDScript
`BulletPool`, and that pool remains the default and the fallback.

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
  `on_update`. Any unmasked event hook, or an `on_update` override, stays in
  the pool. `spawn_child()` and spawns made while a hook is running stay in
  the pool too: the native step runs later in the same tick, so a child born
  during a hook would move a tick early, and owner inheritance already lives
  on the pool. That split is a reversible default.
- Both stores share one saturation model (logical cap, enemy reserve, owner
  counters, drop reasons, the rate-limited warning and `pool_saturated`).
  Dead-but-not-flushed bullets still hold a slot. A reflected bullet is not a
  native concern: reflectors and `reflect()` stay on the GDScript pool, and a
  native id still returns false from `reflect_bullet()`.
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
# Same opt-in as the game, because the benchmark's default preference is auto:
./tools/run_benchmark.sh --bullet-backend=native
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
- `tests/unit/test_native_parity.gd`: the same scenarios on both backends.
  Seeded positions within 0.01 and velocities within 0.05, hit signatures,
  kinematics after 90 ticks, slow-overlap impact, pierce hit-memory, wall and
  despawn order, the camera window, saturation counts, damage flags. Pending
  when the extension is not built.
- `tests/unit/test_bullet_manager.gd` forces `"gdscript"` and still inspects
  the pool. Hook masks, `sweep_cross_writes()`, and the speed clamp on that
  path are untouched.

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
| 5,000 | plain | 7.45 ms | 0.92 ms |
| 10,000 | plain | 14.56 ms | 1.78 ms |
| 5,000 | hooked | 11.21 ms | 11.56 ms |
| 10,000 | hooked | 22.92 ms | 25.09 ms |

Plain native bullets were entirely in `NativeBulletSim` (pool count 0). Hooked
runs were entirely in the pool (native count 0). The default-backend hooked 5k
sample is under the 20 ms soft bar and the 22 ms hard gate. 10k hooked only
warns. These are one machine, not a CI gate.

## Out of scope

Left for later PRs, on purpose:

- Batch-hook API refactor, and moving per-bullet hooks into C++. Hooks stay
  GDScript.
- The narrow zero-copy Lua view. M1, when it happens, uses packed copies
  through stock lua-gdextension. This PR does not fork Lua.
- Full platform matrix (Windows, macOS, Android, web) and CI build wiring.
- Reflector zones, wall normals, and `can_hit` vetoes for native bullets.
  Hook-free native bullets are not reflected and do not report a wall normal.
  A bullet whose mask includes `can_hit` stays on the GDScript pool.
- Clamp warnings. The pool warns when it clamps a shot; the native facade
  clamps silently to the same limits.
- A shared id space. Native ids use bit 62. `reflect_bullet()` on a native id
  returns false.
