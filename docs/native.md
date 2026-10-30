# Native bullet core (prototype)

A small C++ GDExtension (`NativeBulletSim`, `native/`) that runs the bullet
integrate / collision / despawn hot loop. The GDScript `BulletPool` path is
unchanged and remains the fallback behind the same `BulletManager` interface.

**Status: prototype.** Linux x86_64 release build only. Not wired into CI.

## What it covers

- Struct-of-arrays bullet store, stable ids (generation-checked), swap-remove
  compaction.
- Fused per-bullet loop: integrate, wall sweep (clipped to the contact point),
  swept hurtbox DDA with the B1/B2 semantics from `feat/core-scaffold`
  (stop at the nearest entry `t_entry >= best_t`, pierce re-sweeps with an
  exclusion list, final-segment sweep for bullets that leave the bounds).
  Death reason precedence: HIT, then WALL, then BOUNDS.
- Hit events are queued and dispatched after compaction (`receive_hit` on the
  Hurtbox), so a callback can't mutate the store mid-loop.
- Render fill: two alternating buffers fed to
  `multimesh_set_buffer_interpolated`.
- `snapshot()` / `alive_count()` / `spawned_total()` for tests, HUD, benchmark.

**Hybrid by design:** plain bullets (`behavior_id == 0`) go native; bullets
with a behavior hook stay in the GDScript pool, so the hook API
(`pool.pos[index]`, ...) is unchanged. `spawn()` returns a native id (flag bit
62) for plain bullets and the pool slot for hooked ones.

### Backend selection

`BulletManager.backend_preference` = `"auto"` (default), `"gdscript"` or
`"native"`. In `"auto"` the env var `SCRIPTSHOT_BULLET_BACKEND=gdscript|native`
overrides; otherwise native is used when
`ClassDB.class_exists("NativeBulletSim")`. If the library is missing, Godot logs
a "GDExtension dynamic library not found" error and the game falls back to
GDScript (native tests report as pending, suite still passes).

## Build (Linux x86_64 release)

```
pip/uv install scons==4.10.1
./tools/build_native.sh            # -> bin/linux/libscriptshot_native.linux.template_release.x86_64.so
./tools/check_extension_api.sh     # godot-cpp API json == our Godot binary's dump
SCRIPTSHOT_BULLET_BACKEND=native   ./tools/run_tests.sh
SCRIPTSHOT_BULLET_BACKEND=gdscript ./tools/run_tests.sh
./tools/run_benchmark.sh --backend=native   # or gdscript
```

`bin/` is gitignored; libraries are build output (CI would produce them).
`scriptshot_native.gdextension` lists only the Linux x86_64 library (editor,
debug and release all point at the release build).

### Pins

| Thing | Pin |
|---|---|
| godot-cpp | `10.0.0-stable` (`507ed9d`), submodule `native/godot-cpp`, `api_version=4.7` |
| Godot | 4.7.2 (godot-cpp's `extension_api-4-7.json` matches our binary's dump) |
| SCons | 4.10.1 |
| Emscripten (web, not built) | 4.0.11 |
| Android NDK (not built) | 29.0.14206865, API level 24 |
| iOS | dropped as a target |

## Tests

- `tests/unit/test_native_backend.gd`: spawn/ids, plain vs hooked routing,
  walls, swept hits, despawn, snapshot.
- `tests/unit/test_native_parity.gd`: seeded scenario run through both
  backends; positions within 0.01, velocities within 0.05, identical hit
  signatures (`tick:target:damage`, sorted) over 150 ticks.
- Existing suite passes under both backends (248/248 each).

**Known semantic difference:** for slow, non-piercing bullets GDScript's short
path point test reports the *end position* as the impact point; native reports
the exact contact point. Parity check allows one tick of travel.

## Benchmark (box: 8 cores, shared; load avg ~2.7-3.2 throughout)

Scenario: 32 hurtboxes, 28 walls, 10% fast bullets, 600 measured frames after
120 warmup, headless (no renderer, so GPU/multimesh upload is not measured).
4 runs per backend, interleaved (gdscript, native, gdscript, ...), on
`feat/core-scaffold` @ `9573539` + this branch. "work" = sim step time.

| count | backend | p50 per run (ms) | p95 per run (ms) | median p50 | median p95 |
|---|---|---|---|---|---|
| 5k | gdscript | 6.86 / 6.83 / 7.23 / 7.09 | 9.13 / 9.03 / 10.42 / 8.68 | 6.98 | 9.08 |
| 5k | native | 0.73 / 0.69 / 0.71 / 0.76 | 1.00 / 0.96 / 0.95 / 1.06 | 0.72 | 0.98 |
| 10k | gdscript | 13.80 / 13.79 / 14.02 / 14.51 | 15.06 / 14.56 / 20.61 / 17.93 | 13.91 | 16.50 |
| 10k | native | 1.38 / 1.35 / 1.77 / 1.37 | 1.95 / 1.93 / 2.02 / 1.91 | 1.38 | 1.94 |

~10x at p50, ~8.5-9x at p95. GDScript at 10k is right at the 16.6 ms budget
(and over it at p95 in 2 of 4 runs); native uses ~12% of it.

Mean ms per phase (10k, typical run):

| phase | gdscript | native |
|---|---|---|
| advance | 2.5 | 0.9 (includes walls, hurtboxes, despawn: fused loop) |
| hooks+walls | 3.9 | ~0 |
| hurtboxes | 3.1 | ~0 |
| despawn | 0.1 | ~0 |
| render fill | 4.1 | 0.15 |

Native phases are not separable because the loop is fused; compare the sums.

## Not covered / full migration

Missing in the prototype:

1. Hooked bullets in native (hook API is index-into-pool-arrays; needs either
   accessor calls or a native behavior set). Biggest design question.
2. `user` slot / Variant user data, params, teleport/kill-by-id from outside,
   unifying native and pool id spaces (and the stable-id work on
   `feat/core-defaults`).
3. Visual check of interpolated render on a real GPU (only headless run here)
   and parity with the fixed `BulletRenderer`.
4. Platforms: Windows (MSVC), macOS (unsigned, universal), Android (arm64),
   web (dlink side module, threads/no-threads flavours; riskiest). Full
   `.gdextension` matrix.
5. CI: build matrix + artifact caching, parity runs under both backends, API
   check. The same pipeline could be shared with the Lua GDExtension addon.

**Estimate for a full migration (one engineer): ~3 weeks (12-18 working days):**
hooks/ids/user data 5-8 d; platform matrix + CI 4-6 d (web is the long pole);
parity hardening, GPU render verification and docs 3-4 d. Dropping hook
support in native (keep hybrid permanently) would cut roughly a week.
