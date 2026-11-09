# Native bullet core

Hybrid C++ migration. A small GDExtension (`NativeBulletSim`, `native/`)
advances **hook-free** bullets: plain shots, declarative ones (kinematics
only, no per-bullet hook), and **batch-hook** bullets. Bullets with a
per-bullet hook stay in the GDScript `BulletPool`, and that pool remains the
default and the fallback.

**Status: opt-in.** The library can be built for Linux x86_64, Windows x86_64,
macOS universal, web wasm32 (no threads, matching the export preset), and
Android arm64. CI builds Linux, Windows (MSVC), macOS universal and web on
every PR and runs the full GUT suite with the library loaded on Linux, Windows
and macOS (see [CI](#ci)); Android is not built in CI yet. The game does not move bullets unless
native is opted in and that platform's library loaded. Hooked bullets never
move to C++. A missing or failed library logs one warning and stays on the
GDScript pool.

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
     Writing one raises. A position change goes through `teleport`.
  5. **`on_update` stays per-bullet.** Overriding `on_update` keeps the bullet
     on the pool and does not also run the batch hook, unless `update_mode`
     is `BATCH`. Explicit `BATCH` plus `on_update` still lives on the pool,
     and both run.
  6. **Hook spawns stay on the pool for life.** A bullet spawned inside a hook,
     including `on_update_batch`, is born on the GDScript pool and is not
     migrated into the sim later.
  **Zero-copy stays off.** The columns are packed copies through stock
  lua-gdextension. There is no lua-gdextension fork and no zero-copy view.
  Packed copies are the backing that was measured. Native batch work p95 on the
  machines sampled so far is about **1.5–2.3 ms at 5,000** and about **4 ms at
  10,000** (single runs have reported 1.51 ms and 2.25 ms at 5,000; the table
  below is one of those machines). That is inside the budget, so the copy is
  not the thing to remove next. These samples are provisional and may change. A later
  zero-copy column could replace the arrays inside `BatchView` without a
  script change. That decision is not this slice. Scripts receive Lua tables,
  not the packed arrays. Per call, `BatchView.CMD_CAP` (4096) commands and
  `BatchView.SPAWN_CAP` (256) spawns are kept; the rest are dropped and one
  warning is logged. The `on_batch` instruction budget is 100,000 plus 128 per
  row, capped at 2,000,000 (`ScriptHost.BATCH_BUDGET_CEILING`). The 50 ms wall
  clock and the 64 MB memory cap are unchanged. Those limits are provisional
  and may change. A hot reload that adds `on_batch` does not move bullets that
  already have `behavior_id` 0 into the batch.
  **Default backend cost (provisional).** With the default GDScript backend,
  `on_batch` bullets stay on the GD pool. That path is about 21–25 ms p95 at
  5,000 and about 41–47 ms at 10,000 on the machines sampled so far (single
  runs have reported 20.7 / 40.9 ms and 24.8 / 47.0 ms), over the 16.6 ms frame
  budget at 5,000. Routing them to native by default belongs to the
  default-backend decision, tracked in
  [#34](https://github.com/Karyu42/scriptshot/issues/34).
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

`bin/` is gitignored. `scriptshot_native.gdextension` lists debug, editor, and
release for each release target. Editor and debug both point at the
`template_debug` binary, because the editor binary has both feature tags and
Godot keeps the first equally-specific match. Without the library Godot logs
that the GDExtension binary is missing and the game keeps using GDScript.
Native tests report as pending; the rest of the suite still runs.

## Platforms

Output layout matches `docs/qa/release-builds.md` section 8. Debug and release
are both `./tools/build_native.sh <platform>` (the default target word is
`both`). `release` or `debug` builds one.

| Platform | Library | How to build | Built / ran / fallback |
|---|---|---|---|
| Linux x86_64 | `bin/linux.x86_64/libscriptshot_native.linux.template_{debug,release}.x86_64.so` | `./tools/build_native.sh linux` | Debug and release built. GUT ran on the debug library (the editor binary loads it). Fallback covered by the unregistered-class test. |
| Windows x86_64 | `bin/windows.x86_64/libscriptshot_native.windows.template_{debug,release}.x86_64.dll` | Linux: MinGW cross. The script prefers `x86_64-w64-mingw32-g++-posix` (the win32 thread model has no `std::thread`). Windows: MSVC if installed, otherwise MinGW. `use_static_cpp=yes`. The `lib` prefix is forced so both compilers write the same filename. | Debug and release cross-built (MinGW posix, static libgcc/libstdc++). DLL exports `scriptshot_native_init` and links `KERNEL32.dll` and `msvcrt.dll`. Not run on Windows. |
| macOS universal | `bin/macos.universal/libscriptshot_native.macos.template_{debug,release}.universal.dylib` | `./tools/build_native.sh macos` on macOS. `arch=universal`, deployment target 10.13 (Godot 4.7.2's x86_64 floor; arm64 Godot is 11.0 and loads that dylib). Unsigned. The exporter ad-hoc signs it with the app. | Not built (no Apple SDK in this environment). Not run. |
| Web, no threads | `bin/web.wasm32/libscriptshot_native.web.template_{debug,release}.wasm32.nothreads.wasm` | Emscripten **4.0.20**, `threads=no`. `./tools/build_native.sh web` | Debug and release built (`dylink` side modules, no pthread import). Not loaded in a browser. |
| Web, threads | `bin/web.wasm32/libscriptshot_native.web.template_{debug,release}.wasm32.wasm` | `scons platform=web arch=wasm32 threads=yes` | Not built. The `.threads.` gdextension keys exist so a threads export does not load the no-threads wasm. A missing file fails the load and the pool is used. |
| Android arm64 | `bin/android.arm64/libscriptshot_native.android.template_{debug,release}.arm64.so` | `./tools/build_native.sh android` with NDK **29.0.14206865** (`ndk_version=29.0.14206865`, API 24). godot-cpp's own default NDK is r28b; this script passes r29. | Not built. Device runs stay deferred. |

The shipping Web preset is `variant/thread_support=false` and
`variant/extensions_support=true` (the `web_dlink_nothreads` template, needed
for the Lua GDExtension). The no-threads wasm matches that thread mode, but the
preset's `exclude_filter` keeps this library out of web exports for now (see
[Web export](#web-export)). Selecting native (or `auto` that resolves to
native) on web logs one warning and runs the GDScript pool.

Fallback is the same on every platform: `NativeBulletSim` is not registered,
so `BulletManager` logs one warning per process and spawns into the pool.
That includes a wasm side module that fails to load. Script invulnerability
(`pierces_script_invuln` / `SOURCE_PIERCES_SCRIPT_INVULN`) stays the pool's
flag. The default preference remains `gdscript`.

The libraries in the table were built with `SCRIPTSHOT_NATIVE_LTO=none`
(godot-cpp's `lto=auto` is full on Linux, MinGW, and web). GUT on this
machine is two processes. Unbuilt: host guards 10 passing, unit and
integration 1014 passing and 74 pending. Built, on the Linux debug library:
host guards 10 passing, unit and integration 1088 passing and 0 pending.

## Build pins

| Thing | Pin |
|---|---|
| godot-cpp | `10.0.0-stable` (`507ed9d`), submodule `native/godot-cpp`, `api_version=4.7` |
| Godot | 4.7.2 |
| SCons | 4.10.1 |
| Emscripten | **4.0.20**, the build-container pin for the official 4.7.2 web export templates. The engine workflow's `EM_VERSION` 4.0.11 is the CI file only. |
| Android NDK | r29 (`29.0.14206865`), matching Godot 4.7.2. Not r28b. |
| macOS min | 10.13 universal dylib |

```
pip install scons==4.10.1
./tools/build_native.sh                 # linux debug + release
./tools/build_native.sh linux release   # -> bin/linux.x86_64/libscriptshot_native.linux.template_release.x86_64.so
./tools/build_native.sh windows         # MinGW cross on Linux, or MSVC on Windows
./tools/build_native.sh macos           # macOS host, universal
source /path/to/emsdk/emsdk_env.sh      # Emscripten 4.0.20
./tools/build_native.sh web             # wasm32, threads=no
./tools/build_native.sh android         # NDK r29, arm64
./tools/check_extension_api.sh          # godot-cpp API json == this Godot binary's dump
```

`SCRIPTSHOT_NATIVE_LTO` overrides godot-cpp's `lto=auto` (full on Linux, MinGW,
and web). `SCRIPTSHOT_NATIVE_JOBS` overrides the job count.

## Tests

- `tests/unit/test_native_backend.gd`: load/switch, the project setting and the
  CLI flag, one warning when the library is missing, declarative vs hooked
  routing, hook spawns staying in the pool, the shared cap and enemy reserve,
  walls, swept hits, speed clamp, despawn, snapshot. Pending when the extension
  is not built (the missing-library warning test runs either way).
  `test_unregistered_class_falls_back_once_and_keeps_pool_semantics` also runs
  either way: it forces the class to look unregistered, checks native and auto
  share one warning, checks an explicit gdscript preference and an auto that
  resolves to gdscript do not warn, and checks the bullet stays in the pool
  with `pierces_script_invuln` set.
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
| 5,000 | one hook | 24.77 ms | 2.25 ms |
| 10,000 | one hook | 47.02 ms | 4.25 ms |

That table is one machine. Across the machines sampled so far the same native
batch is about 1.5–2.3 ms at 5,000, and the GD pool path is about 21–25 ms at
5,000 and about 41–47 ms at 10,000. Provisional; may change.

`--mirrors=N` adds reflector zones (both factions, pool cap lifted so bullets
keep bouncing) on top of that workload. With 8 mirrors at 5k plain bullets the
same machine measured work p50/p95 of 13.97/14.20 ms on GDScript and 0.95/1.04 ms
native, with every bullet still in the sim (pool count 0).

## Web export

The library is **not shipped on web** for now (CoS ruling on #36, which tracks
native-on-web). The Web preset turns on `variant/extensions_support` (dlink
no-threads template) because lua-gdextension is a GDExtension, and lists
`scriptshot_native.gdextension, bin/*` in its `exclude_filter`. Note that in
Godot 4.7.2 `extensions_support=false` does **not** keep a GDExtension out of a
web export: every exported `.gdextension` wasm is copied and listed in
`GODOT_CONFIG.gdextensionLibs`, and the no-dlink template then refuses to boot
(issue #40). The exclude filter is what keeps this library out. With it, the
`.gdextension` file, its wasm and its `extension_list.cfg` line are all left out
of the export, whether or not the file has `web.*` keys. The web build runs the
GDScript pool; `--bullet-backend=native` logs the single fallback warning.
`tools/ci/web_smoke.sh` checks both (docs/qa/release-builds.md section 4.1).
Shipping native on web means removing that filter entry and passing the #36
smoke (side module loads, backend resolves to native).

## CI

`.github/workflows/ci.yml` (issue #38) runs four jobs on every PR, push to main
and `workflow_dispatch`. None is a required check yet.

| Job | Runner | Does |
|---|---|---|
| `Native libs (linux)` | ubuntu-24.04 | `./tools/build_native.sh linux`, then `./tools/run_tests.sh` with the library loaded |
| `Native libs (web)` | ubuntu-24.04 | `./tools/build_native.sh web` with Emscripten 4.0.20. **Artifact only, not shipped**: the Web presets keep `scriptshot_native.gdextension, bin/*` excluded (#36) and the job fails if that changes |
| `GUT (windows, native)` | windows-latest | MSVC build, then `run_tests.sh` under Git Bash with the DLL loaded |
| `GUT (macos, native)` | macos-latest | universal (arm64 + x86_64, checked with `lipo`) build, then `run_tests.sh` under macOS's `/bin/bash` 3.2 with the dylib loaded |

Every GUT job then runs `tools/ci/gut_counts.py --expect-native`, which fails
unless both GUT processes printed their totals, nothing failed and nothing is
pending. The native tests are pending when `NativeBulletSim` is not registered,
so 0 pending proves the library loaded (Linux: 10 host + 1088 unit, 0 pending;
unbuilt it is 1014 passing and 74 pending).

Artifacts: `native-libs-linux.x86_64`, `native-libs-windows.x86_64` (DLLs only),
`native-libs-macos.universal`, `native-libs-web.wasm32` (not shipped). The
manual export job restores them from the same run: every cell gets the Linux
libraries (the headless editor host loads the extension), Windows and macOS
also get their own. The Linux and Windows cells need their library uploaded
(an export without it fails); the macOS cell also needs `GUT (macos, native)`
green, because macOS ships native, unsigned, only once that job passes. Android exports without the
library (deferred, #39).

Caches: SCons `CacheDir` (`$SCONS_CACHE`, honoured by godot-cpp's SConstruct)
keyed by the godot-cpp commit, SCons version, platform, targets and threads;
emsdk through `setup-emsdk`'s `actions-cache-folder`. `bin/` is never cached.

`tools/run_tests.sh` and `tools/ci/fetch_native_libs.sh` run under bash 3.2
(macOS `/bin/bash`) and Git Bash: the exit-after-results guard measures time
with `EPOCHREALTIME` on bash 5 and perl's `Time::HiRes` otherwise, output is
streamed without `tail --pid`, and empty arrays are expanded with
`${a[@]+"${a[@]}"}`. `tools/ci/test_run_tests_guard.py` runs the guard cases
against a fake godot under any bash (`RUN_TESTS_BASH=/bin/bash`).

## Out of scope

Left for later PRs, on purpose:

- Moving per-bullet hooks (`on_update`, `on_hit`, `can_hit`, `on_despawn`)
  into C++. Those bullets stay on the GDScript pool.
- Zero-copy stays off. Packed copies measured about 1.5–2.3 ms at 5k and about
  4 ms at 10k native batch on the machines sampled so far, which is inside the
  budget. A later column could
  replace the copies without a script change. This tree does not fork Lua.
- The six batch defaults above, if a later slice extends one of them:
  `update_interval` / `update_slice`, a reflect command on the view, a
  `spawn{}` form, writable position columns, batch-calling an `on_update`
  bullet without `update_mode = BATCH`, or moving a hook-spawned bullet into
  the sim. Current behaviour is the list in the batch-hook bullet.
- Shipping the library on web (#36: drop the Web preset's exclude entry once
  the browser smoke passes with it), the Android arm64 CI build and a device
  run (#39), and a real-machine Windows play test (#39).
- The threaded web side module. The preset is no-threads; the `.threads.`
  gdextension keys are present so that export does not load the no-threads wasm.
- `can_hit` vetoes inside the C++ sim. A bullet whose mask includes `can_hit`
  stays on the GDScript pool, and so does every other per-bullet hook.
- Clamp warnings. The pool warns when it clamps a shot; the native facade
  clamps silently to the same limits.
- A shared id space. Native ids use bit 62.
