# Native bullet core (PR1, prototype)

First slice of the hybrid C++ migration. A small GDExtension (`NativeBulletSim`,
`native/`) advances **plain** bullets. Bullets with a per-bullet hook stay in
the GDScript `BulletPool`, and that pool remains the default.

**Status: prototype scaffold.** Linux x86_64 release build only. Not wired into
CI. The C++ sim is good enough to review and to parity-test; it is not the
final hot loop, and it has not been re-benchmarked on current `main`.

## What this PR does

- GDExtension build wiring (`native/SConstruct`, `scriptshot_native.gdextension`,
  `tools/build_native.sh`, `tools/check_extension_api.sh`).
- `NativeBulletSim`: struct-of-arrays store, stable ids (generation-checked,
  bit 62 set so they are not pool slots), integrate, wall sweep, swept hurtbox
  tests, pierce, swap-remove, and the interpolated MultiMesh upload.
- `BulletManager` routes a plain bullet (`behavior_id == 0`) to that sim only
  when the native backend is selected **and** the spawn is not inside a hook.
  `spawn_child()` and hook spawns stay on the GDScript pool, so owner
  inheritance, hook masks, `sweep_cross_writes()`, and the saturation limits
  are unchanged for them.
- Spawn limits match `BulletLimits`: `NativeBackend` clamps with those
  constants and passes `MAX_SPEED` into `configure`. The extension does not
  hard-code a second ceiling. A non-finite shot is refused.
- GDScript is the fallback and the default. `backend_preference` defaults to
  `"gdscript"`, so loading the library does not move bullets, and
  `SCRIPTSHOT_BULLET_BACKEND` does nothing until a manager is set to `"auto"`.
  `"native"` uses the extension or, if it is missing, logs an error and stays
  on GDScript.

`spawn()` returns a pool slot for GDScript bullets and a native id for plain
native bullets. `ShotEmitter.request_shot_id()` / `is_bullet_alive()` understand
both. `alive_count()`, `spawned_total()`, and `snapshot()` cover both stores.

## Backend selection

`BulletManager.backend_preference`:

| value | result |
|---|---|
| `"gdscript"` (export default) | pool only. Ignores `SCRIPTSHOT_BULLET_BACKEND`. |
| `"native"` | plain bullets in `NativeBulletSim` if the extension loaded, otherwise GDScript plus an error |
| `"auto"` | `SCRIPTSHOT_BULLET_BACKEND=native` or `=gdscript`; unset stays GDScript |

`spawn()` on the native backend returns a native id, not a pool slot. The
unit tests that index the pool are written for GDScript and leave the
preference at the default, so do not point the whole suite at native with the
environment variable. The native tests set `"native"` themselves.

```
./tools/build_native.sh
./tools/run_tests.sh                         # GDScript path, native tests included
./tools/run_tests.sh -gselect=native         # the opt-in tests only
./tools/run_benchmark.sh --backend=gdscript
./tools/run_benchmark.sh --backend=native
```

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

- `tests/unit/test_native_backend.gd`: load/switch, ids, plain vs hooked
  routing, hook spawns staying in the pool, walls, swept hits, speed clamp,
  despawn, snapshot. Pending when the extension is not built.
- `tests/unit/test_native_parity.gd`: one seeded plain-bullet scenario on both
  backends. Positions within 0.01, velocities within 0.05, same hit signatures
  over 150 ticks.
- `tests/unit/test_bullet_manager.gd` forces `"gdscript"` and still inspects
  the pool. Hook masks, `sweep_cross_writes()`, and the speed clamp on that
  path are untouched.

**Known difference, checked loosely:** a slow non-piercing bullet that is
already overlapping a target is reported at its end position by the GDScript
point test and at the contact point by the native sweep. The parity test
allows one tick of travel on impact points. Survivors must match tightly.

A hurtbox turned off earlier in the same tick is skipped by the pool at
delivery (`active`). The prototype still delivers a native hit that was queued
against the snapshot. Mixed pool-and-native ticks can disagree there.

The old ~10x numbers in the previous draft of this file were measured on
`9573539` (before the hook-mask and plain-advance work). They are not a result
for this branch. Re-benchmark after this lands (`--backend=native` vs
`--backend=gdscript`).

## Out of scope

Left for later PRs, on purpose:

- Batch-hook API refactor, and moving per-bullet hooks into C++. Hooks stay
  GDScript.
- The narrow zero-copy Lua view. M1, when it happens, uses packed copies
  through stock lua-gdextension. This PR does not fork Lua.
- Full platform matrix (Windows, macOS, Android, web) and CI build wiring.
- Saturation model for native bullets. The prototype store is sized to the
  physical `capacity` and does not apply `logical_cap`, the enemy reserve, or
  `owner_counts`. Do not point a gameplay scene at `"native"` until that
  exists. The GDScript path still enforces the model.
- Reflector zones, wall normals, and `can_hit` vetoes for native bullets.
  Plain native bullets are not reflected and do not report a wall normal.
- Clamp warnings. The pool warns when it clamps a shot; the native facade
  clamps silently to the same limits.
- A shared id space. Native ids use bit 62. `reflect_bullet()` on a native id
  returns false.
