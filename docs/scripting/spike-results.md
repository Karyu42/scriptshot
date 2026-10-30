# lua-gdextension spike results (Godot 4.7.2)

Status: **measured, local, throwaway project** (`/workspace/scriptshot-spike`, not in this repo; the raw output
files and the sources of every benchmark are in [`spike/`](spike/)). Nothing here touches the game repo.
Written by the Scripting Engineer for PR #3. **Engine-state markers:** **[main]** = on `main` (39ff259), **[PR #4]** = only on PR #4 (head 1d2fe2c, not merged). Numbers are **medians (p95 where stated)** over repeated runs;
the box is a shared KVM guest and noisy, so treat single digits after the
decimal point as noise.

## 1. Verdict in one table

| Question | Answer |
|---|---|
| Does lua-gdextension 0.8.2 (Lua 5.4) load and run on **Godot 4.7.2**? | **Yes**: editor build, release export template, headless, Linux x86_64 desktop, **Web (threads and no-threads) in headless Chromium**, **Android APK built and signed**. One CI hazard found (section 3). |
| ~4,000 scripted bullets in ~3 ms of Lua per frame? | **Not every tick with per-bullet hooks** (A: 6.3 ms). **Batch with slicing: yes.** Batch every tick costs 4.1 ms at 4,000; batch with a quarter of the bullets per tick costs 1.0 ms. 3 ms buys ~3,000 batch bullet-updates, or ~1,900 per-bullet calls, per tick. |
| 5,000 (minimum target) | Whole `BulletManager.step` with all 5,000 bullets hooked: C 1.8 ms; A 9.7 ms; B slice every tick 6.7 ms; **B slice 1/4: 3.0 ms**; 10% scripted per tick: 2.1-2.4 ms (hook phase 0.5-0.8 ms). Fits the 16.6 ms frame in every case; fits the 3 ms **Lua** budget with slicing (1.2 ms) or 10% scripted (0.5-0.8 ms). |
| 10,000 (target) | C 3.6 ms; A 19.7 ms (**does not fit**); B slice every tick 13.6 ms (**does not fit** a 16.6 ms frame with render); **B slice 1/4: 5.7 ms, Lua 2.4 ms (fits)**; 10% scripted: 4.5-4.9 ms step, hook phase 1.1-1.7 ms. |
| Hook granularity hypothesis (C default, B for per-frame steering, A opt-in, events through a queue) | **Confirmed, with three corrections** (section 8): batch is ~25-40% cheaper than per-bullet, not 10x; the event queue buys determinism and caps, not speed; the manager must skip throttled bullets natively. |
| Problems / crashes | No crashes in error isolation, coroutine churn (#240 not reproduced), or 47 adversarial scripts. Found and fixed in the guard design: pcall swallows budget errors; coroutines created in Lua have no hook; **xpcall message handlers and `__gc` finalizers run with hooks off** (hang); native pattern matching and big allocations are not interruptible; **the cold headless import abort (exit 134, a SIGSEGV null dereference in the stripped editor binary) on a *blank project plus addon*** (not on the real Scriptshot repo with GUT; section 3). |
| Binding choice | **M1 uses the stock 0.8.2 release binaries, pinned by SHA256**, behind `ScriptHost` with G1. A source build (P1-P3 hardening, P4 native view) first needs **a port to godot-cpp 10.0.0-stable (`507ed9d`) in a fork**: 0.8.2 does not build unmodified against it (section 12); it builds with a small patch set at `api_version=4.6` (verified here), and a clean `api_version=4.7` port is an estimated 2-3 days. The patches are lower priority than M1 integration and no longer gated on in-game sharing/import (deferred by Karyu). |
| godot-cpp 10.0.0-stable build of lua-gdextension | **Unmodified: fails. Patched (3 generator paths, 8 `ref.hpp` includes, `api_version=4.6`): builds, loads and passes the smoke test and all 47 adversarial cases on Godot 4.7.2 with outcomes identical to the stock binary. Web not attempted (no emcc).** Section 12. |

## 2. Environment

| | |
|---|---|
| Godot | `4.7.2.stable.official.ed1daf0bf`, Linux x86_64, headless; also its official **release export template** (`linux_release.x86_64`) for all "release" numbers |
| Addon | `gilzoide/lua-gdextension` **0.8.2**, Lua **5.4.8** runtime (changelog: "Updated Lua to 5.4.8"), MIT, `lua_runtime=lua` (not LuaJIT) |
| Web | Google Chrome 156.0.8078.47 headless via Playwright 1.64.1, SwiftShader (software GL), `crossOriginIsolated = true`, Godot 4.7.2 `web_dlink_*` templates. **Web was tested only in headless Chromium with software GL; Safari and Firefox are untested** |
| Android | SDK build-tools 35.0.1 (what the box had; the Godot 4.7.2 pin is 36.1.0, section 12), platform android-35, JDK 17.0.21, debug keystore, prebuilt `android_debug.apk` template |
| godot-cpp (source-build attempt) | `507ed9d` = 10.0.0-stable (2026-09-15). **Not** `58d1de7`, which is 10.0.0-rc1 with the 4.6 API and what lua-gdextension 0.8.2 pins |
| CPU | `lscpu`: Intel(R) Xeon(R) Processor (model name as reported; KVM guest), 8 vCPU (8 cores x 1 thread), L2 16 MiB (8 instances), L3 320 MiB, AVX-512; 15 GiB RAM |
| Method | Release-template numbers unless a table says "editor build". Editor build is slower (debug bindings); never quote it as the player experience. Render off in the headless matrix; render on in the export proof |

Spike code: `spike/bench/*.gd` (benchmarks), `spike/sandbox/sandbox.lua` (guard-rail environment), the bullet
manager is a copy of PR #2's `BulletManager`/`BulletPool` (modelled, not modified), extended in the spike with the
hook options below.

## 3. Does it load on 4.7.2? (and the issues #260 / #255 / #257)

- Headless project import, `--editor --quit`, `--script`, the editor-build benchmarks and the **release export
  template** all load the extension. The only noise is a harmless warning
  (`Property not found: 'lua_gdextension/lua_script_language/script_import_map'`).
- **#260** (4.5.2 refuses the 4.6-built binary): irrelevant on 4.7.2.
- **#255** (LuaTable get/set `bind_method`): **4.8-dev only**; not a 4.7.2 problem (the earlier draft conflated it).
- **#242** (Lua syntax highlighting in 4.7): editor cosmetics; workaround Edit -> Syntax Highlighter -> Standard.
- **#257** ("Godot Editor Crash on Linux with Godot 4.8-dev[6,7] and 4.7.2-stable", open, Arch Linux, Wayland, blank project
  + addon enabled, SIGSEGV in the extension). **Reproduction attempt on 4.7.2 Linux (this box, X11 via Xvfb + Mesa
  llvmpipe, `--rendering-driver opengl3`):** GUI editor with the addon installed **and enabled**, blank scene, cold and warm:
  **no crash** in 3 runs of 40-60 s each. So #257 is **not reproduced** here; its reporter is on Wayland/Arch with a newer
  Mesa/glibc, which I cannot emulate. **Not a closed risk**: QA should run the real GUI editor on the target Linux distros
  (Wayland) before committing to the addon *in the editor*. The exported game and the headless CI path do not involve the
  editor GUI.
- **New finding, same class (cold import abort), corrected after QA's reproduction (PR #3 comment 6525339004).**
  `godot --headless --path <project> --import` (also `--editor --quit`) on a project that **contains the addon and has no
  `.godot/` cache** exits **134 (SIGABRT)** after the import has finished (log ends at `EditorSettings: Save OK!`); the second
  (warm) run exits 0; the identical project without the addon exits 0.
  - **Scope:** it reproduces on a **blank project plus the addon** (3/3 here, and 3/3 for QA, also with a library built from source
    here). It does **not** reproduce on the real Scriptshot `main` with GUT: **4/4 cold imports pass** (QA).
  - **Cause (QA's backtraces; artifacts in `/workspace/pr3-review-artifacts/`, not committed):** a **SIGSEGV, null dereference
    (`si_addr=0x28`), inside the stripped Godot editor binary after `loading_editor_layout`**; the process
    then ends with exit 134 (SIGABRT) after the fault, which QA's logs show first. **No frame is in `libluagdextension`.** Setting `reloadable = false` in the `.gdextension` does not help.
    (This box has no gdb; the backtrace comes from QA's run.)
  - **What avoids it:** pre-seeding **`.godot/extension_list.cfg`** with the line
    `res://addons/lua-gdextension/luagdextension.gdextension` before the first import (3/3 clean exits).
  - **CI consequence:** **CI is unchanged for now** (the real repo passes), and no CI mitigation is claimed. Fallbacks if it ever bites,
    in order: (a) pre-seed `extension_list.cfg`; (b) if the abort still happens, accept exit 134 **only if** the log contains
    `[ DONE ] reimport` and contains no `ERROR` and no `Failed to load`; (c) never use "run twice and ignore the first exit
    code" as a blanket rule. (Details and the CI snippets: testing.md.)
  - **Proposed, not filed (nothing was posted):** an upstream **godotengine/godot** issue (minimal repro: blank project + any
    GDExtension addon, cold `--headless --import`, backtrace with `si_addr=0x28`) and a **Scriptshot tracking issue** for the
    fallbacks above. Drafts are in the hand-off message for the owner to approve.

## 4. Call-cost model (release template, ns per operation, loop overhead subtracted)

| Operation | ns |
|---|---|
| GDScript -> Lua call, no args | 96-125 |
| ... with a `float` / `Vector2` / `Dictionary` / `Array` argument | 140 / 268 / 263 / 264 |
| ... with a `PackedFloat32Array` (4096) | 234 (by reference) |
| Lua -> Lua call | **5.7** |
| Lua -> Godot Callable, no args / float / Vector2 / Dictionary / Array | 124 / 159 / 200 / 215 / 219 |
| Lua table -> Dictionary conversion | ~1,000 |
| `Vector2(x, y)` created in Lua | ~610 |
| Godot object method call from Lua (script / native) | 465 / 500 |
| Packed array element **read** / **write** from Lua | **130 / 67** |
| Object property read / write | 255 / 132 |
| Dictionary key read | 203 |

**Consequence for the design:** the cost is *per element crossing the Variant boundary* (about 130 ns per packed read), not
the Lua VM (Lua->Lua is 6 ns). A per-bullet callback that reads 4 fields and writes 2 costs ~0.8 us before any logic. Bulk
conversion on the GDScript side is cheap (`PackedVector2Array.to_byte_array().to_float32_array()`), so batches should
hand Lua flat float32 arrays and read each element once.

## 5. Hook granularity: the PR #2 harness (A / B / C)

Harness: the pool, `BulletManager.step` order and `BulletBehavior` shapes of PR #2, **taken from its then head and now merged to `main` (39ff259)**; the spike copy was not re-diffed against `main`. Render off, 32
hurtboxes, steady-state respawn churn (as `tests/benchmark`), 3 repeats x 150 frames after 40 warm-up frames.

- **C** declarative: no Lua after spawn (`acceleration`, `turn_rate`, `param_a/b`).
- **A** per-bullet: `BulletBehavior.on_update(pool, index, delta)` forwarded to a Lua function, every tick (or throttled by
  `(index + tick) % n`).
- **B** batch: one call per behavior bucket: `on_update_batch(ids, pos, vel, age, param_a, n, dt, out_vel, cmds)
  -> out_vel, cmds, ncmds`, inputs as flat float32 arrays ("gathered" = copied per bullet in GDScript; "bulk slice" =
  copied with array slices), velocity writes as a packed array applied in bulk, structural effects (spawn) as a
  stride-4 command buffer applied after the call. Optional **slicing** (a fraction of the bullets per tick).

Medians in ms; "hook" = the hook phase only, "step" = the whole `BulletManager.step`.


**100% of bullets hooked** (hook phase / whole `step`, ms median [p95]; B also shows copy-in / Lua / apply)

| N | option | hook med | hook p95 | step med | step p95 | copy in | Lua call | apply |
|---|---|---|---|---|---|---|---|---|
| 1000 | C (declarative) | 0.001 | 0.002 | 0.411 | 0.684 | 0.000 | 0.000 | 0.000 |
| 1000 | A per-bullet, every tick | 1.631 | 2.853 | 2.029 | 3.548 | 0.000 | 0.000 | 0.000 |
| 1000 | A, 1/4 of ticks | 0.737 | 0.811 | 1.118 | 1.228 | 0.000 | 0.000 | 0.000 |
| 1000 | B batch, gathered | 1.286 | 2.041 | 1.689 | 2.673 | 0.234 | 0.986 | 0.061 |
| 1000 | B batch, bulk slice | 1.034 | 1.161 | 1.413 | 1.585 | 0.012 | 0.959 | 0.059 |
| 1000 | B bulk slice, 1/4 of bullets/tick | 0.268 | 0.311 | 0.637 | 0.733 | 0.005 | 0.245 | 0.015 |
| 4000 | C (declarative) | 0.001 | 0.001 | 1.444 | 1.736 | 0.000 | 0.000 | 0.000 |
| 4000 | A per-bullet, every tick | 6.296 | 6.858 | 7.646 | 8.332 | 0.000 | 0.000 | 0.000 |
| 4000 | A, 1/4 of ticks | 2.851 | 3.931 | 4.188 | 5.665 | 0.000 | 0.000 | 0.000 |
| 4000 | B batch, gathered | 4.957 | 5.265 | 6.327 | 6.672 | 0.946 | 3.766 | 0.236 |
| 4000 | B batch, bulk slice | 4.139 | 4.423 | 5.498 | 5.848 | 0.031 | 3.857 | 0.234 |
| 4000 | B bulk slice, 1/4 of bullets/tick | 1.036 | 1.138 | 2.359 | 2.541 | 0.013 | 0.963 | 0.059 |
| 5000 | C (declarative) | 0.001 | 0.001 | 1.815 | 2.025 | 0.000 | 0.000 | 0.000 |
| 5000 | A per-bullet, every tick | 7.989 | 8.307 | 9.654 | 10.023 | 0.000 | 0.000 | 0.000 |
| 5000 | A, 1/4 of ticks | 3.532 | 3.760 | 5.171 | 5.454 | 0.000 | 0.000 | 0.000 |
| 5000 | B batch, gathered | 6.076 | 6.497 | 7.739 | 8.278 | 1.108 | 4.668 | 0.293 |
| 5000 | B batch, bulk slice | 5.042 | 5.953 | 6.713 | 7.921 | 0.065 | 4.672 | 0.289 |
| 5000 | B bulk slice, 1/4 of bullets/tick | 1.296 | 1.556 | 2.984 | 3.860 | 0.016 | 1.203 | 0.074 |
| 10000 | C (declarative) | 0.001 | 0.001 | 3.630 | 3.874 | 0.000 | 0.000 | 0.000 |
| 10000 | A per-bullet, every tick | 16.217 | 17.622 | 19.657 | 21.461 | 0.000 | 0.000 | 0.000 |
| 10000 | A, 1/4 of ticks | 7.271 | 8.841 | 10.594 | 12.860 | 0.000 | 0.000 | 0.000 |
| 10000 | B batch, gathered | 12.119 | 13.092 | 15.405 | 16.627 | 2.269 | 9.279 | 0.583 |
| 10000 | B batch, bulk slice | 10.199 | 11.690 | 13.553 | 15.377 | 0.145 | 9.418 | 0.590 |
| 10000 | B bulk slice, 1/4 of bullets/tick | 2.528 | 2.828 | 5.709 | 6.583 | 0.022 | 2.361 | 0.145 |

**10% of bullets hooked** (hook phase / whole `step`, ms median [p95]; B also shows copy-in / Lua / apply)

| N | option | hook med | hook p95 | step med | step p95 | copy in | Lua call | apply |
|---|---|---|---|---|---|---|---|---|
| 1000 | C (declarative) | 0.000 | 0.001 | 0.384 | 0.433 | 0.000 | 0.000 | 0.000 |
| 1000 | A per-bullet, every tick | 0.149 | 0.195 | 0.493 | 0.594 | 0.000 | 0.000 | 0.000 |
| 1000 | A, 1/4 of ticks | 0.070 | 0.111 | 0.420 | 0.673 | 0.000 | 0.000 | 0.000 |
| 1000 | B batch, gathered | 0.129 | 0.155 | 0.489 | 0.570 | 0.024 | 0.097 | 0.006 |
| 1000 | B batch, bulk slice | 0.107 | 0.122 | 0.465 | 0.525 | 0.003 | 0.096 | 0.006 |
| 1000 | B bulk slice, 1/4 of bullets/tick | 0.033 | 0.050 | 0.395 | 0.678 | 0.002 | 0.027 | 0.002 |
| 4000 | C (declarative) | 0.001 | 0.001 | 1.459 | 1.591 | 0.000 | 0.000 | 0.000 |
| 4000 | A per-bullet, every tick | 0.640 | 0.710 | 1.954 | 2.153 | 0.000 | 0.000 | 0.000 |
| 4000 | A, 1/4 of ticks | 0.280 | 0.322 | 1.569 | 1.728 | 0.000 | 0.000 | 0.000 |
| 4000 | B batch, gathered | 0.485 | 0.543 | 1.736 | 1.886 | 0.087 | 0.374 | 0.023 |
| 4000 | B batch, bulk slice | 0.413 | 0.467 | 1.712 | 1.877 | 0.008 | 0.380 | 0.024 |
| 4000 | B bulk slice, 1/4 of bullets/tick | 0.109 | 0.164 | 1.401 | 2.096 | 0.004 | 0.097 | 0.007 |
| 5000 | C (declarative) | 0.001 | 0.002 | 1.875 | 2.513 | 0.000 | 0.000 | 0.000 |
| 5000 | A per-bullet, every tick | 0.780 | 0.890 | 2.379 | 2.671 | 0.000 | 0.000 | 0.000 |
| 5000 | A, 1/4 of ticks | 0.348 | 0.408 | 1.954 | 2.236 | 0.000 | 0.000 | 0.000 |
| 5000 | B batch, gathered | 0.627 | 0.967 | 2.231 | 3.215 | 0.116 | 0.478 | 0.031 |
| 5000 | B batch, bulk slice | 0.514 | 0.639 | 2.144 | 2.608 | 0.010 | 0.473 | 0.030 |
| 5000 | B bulk slice, 1/4 of bullets/tick | 0.138 | 0.157 | 1.740 | 1.932 | 0.005 | 0.124 | 0.008 |
| 10000 | C (declarative) | 0.001 | 0.002 | 3.697 | 4.406 | 0.000 | 0.000 | 0.000 |
| 10000 | A per-bullet, every tick | 1.666 | 1.906 | 4.938 | 5.916 | 0.000 | 0.000 | 0.000 |
| 10000 | A, 1/4 of ticks | 0.725 | 0.814 | 3.972 | 4.298 | 0.000 | 0.000 | 0.000 |
| 10000 | B batch, gathered | 1.345 | 1.510 | 4.747 | 5.437 | 0.246 | 1.032 | 0.065 |
| 10000 | B batch, bulk slice | 1.093 | 1.203 | 4.488 | 4.874 | 0.013 | 1.015 | 0.063 |
| 10000 | B bulk slice, 1/4 of bullets/tick | 0.300 | 0.368 | 3.929 | 4.667 | 0.009 | 0.271 | 0.017 |

How to read it:

- Per-bullet cost: **A ~1.6-2.1 us**, **B ~1.0-1.3 us** (B's cost is dominated by Lua-side packed reads); C ~0.
- The **3 ms Lua budget** buys: B ~3,000 bullet-updates per tick, A ~1,900. With 1/4 slicing B covers **~12,000**
  bullet-updates per second-quarter, i.e. 10,000 bullets each updated at 15 Hz for 2.5 ms.
- B's breakdown at 4,000 / 100%: copy-in 0.9 ms (gathered) vs 0.03 ms (bulk slice); Lua 3.8 ms; apply 0.23 ms. So the
  bulk-slice input is mandatory, gathered inputs lose ~20%.
- **Throttling inside the behavior is not enough**: an A hook that returns early still pays ~0.35 us per bullet of GDScript
  dispatch; the manager has to skip natively (`update_interval`).
- **5,000 minimum:** C 1.8 ms, A 9.7 ms, B slice 6.7 ms, **B slice 1/4: 3.0 ms (Lua 1.2 ms)**; 10% hooked: A 2.4 ms, B 2.1 ms.
- **10,000 target:** C 3.6 ms, A 19.7 ms, B slice 13.6 ms, **B slice 1/4: 5.7 ms (Lua 2.4 ms)**; 10% hooked: A 4.9 ms, B 4.5 ms.
- The PR #2 benchmark itself (C only, render on) reports 5k p95 3.84 ms and 10k p95 6.40 ms; the Lua cost adds on top.
- Native homing/drag/gravity/max_speed in the engine (C) are therefore not a nicety: they are what keeps the bulk of the bullets
  at 0 us.

## 6. Events: per-bullet vs. batched, and hit spam

200 events per frame, N = 4,000, ms per frame including applying the deferred spawns the callback produced (3 children
per hit):

| Event | per-bullet call | batched (fill + Lua + return) | batch Lua only |
|---|---|---|---|
| `on_spawn` | 0.097 | 0.181 | 0.148 |
| `on_hit` | 0.383 | 0.479 | 0.349 |
| `on_despawn` | 0.402 | 0.495 | 0.362 |
| deferred-spawn apply (next tick) | 0.69 | 0.70 | |

**Batching events is not faster** (it is 25-90% slower, the fill and return copies cost more than the saved crossings).
Its value is determinism (one ordered stream), a place to cap, and one budget scope.

Hit spam (N = 4,000), dispatch ms per frame (median), Lua call only in brackets, deferred-spawn apply separate:

| hits / frame | per-bullet, unlimited | batch, unlimited | batch, cap 256 (harness drops the rest) | batch, cap 256 + coalesce |
|---|---|---|---|---|
| 200 | 0.43 | 0.49 | 0.49 | 0.48 |
| 1,000 | 2.04 (apply 3.3) | 2.34 (apply 3.3) | 0.65 (apply 0.84) | 0.69 (apply 0.83) |
| **2,000** | **4.38** (apply 6.8) | 4.86 (apply 6.7) | **0.71** (apply 0.83) | **0.83** (apply 0.84) |
| 5,000 | 10.7 (apply 9.3) | 11.9 (apply 9.1) | 0.98 (apply 0.88) | 1.24 (apply 0.88) |

2,000 hits per frame unbounded costs ~11 ms (dispatch + spawn apply): most of a frame. A per-behavior cap of **256 events per
tick** holds it to ~1.5 ms. **Policy chosen for the API (api.md, "One rule for events"):** the cap bounds the *dispatch per
tick*; the remainder is **deferred, not dropped** (PR #1: events are never silently dropped); only above a 16,384-record queue
bound is the surplus **coalesced** into a counted summary. A per-tick deferred-spawn cap (8,192 here) and counters complete it.

## 7. `fire()`: Lua spawning many bullets in one call

ms per `fire` call (release):

| bullets | GDScript baseline | Lua: `ShotRequest` fields + `request_shot` | Lua: `emitter:polar(floats)` | Lua: packed `request_batch` |
|---|---|---|---|---|
| 10 | 0.011 | 0.044 | 0.023 | 0.017 |
| 100 | 0.119 | 0.361 | 0.223 | 0.146 |
| 1,000 | 1.17 | 3.71 | 2.20 | 1.44 |

Building a `ShotRequest` object from Lua costs ~3x the GDScript baseline (every field assignment is a Variant crossing).
`ShotEmitter.request_polar(x, y, angle, speed, lifetime, behavior_id)` halves that and
`request_batch(PackedFloat32Array, count)` brings a 1,000-bullet burst within 25% of native GDScript.

## 8. Hook granularity recommendation

**The hypothesis** (parent, from PR #2 architecture question 4): declarative kinematics (C) by default, a batch hook (B) for
per-frame steering, per-bullet hooks (A) as an opt-in, events through a capped queue.

**Verdict: confirmed, with these corrections to the numbers and the interface.**

1. **C is the default and the only thing that scales** (0 Lua). Every field in the API table that can be data should be a
   `ShotRequest`/pool field (accel, turn_rate, drag, gravity, max/min speed, homing, bounce).
2. **B is 20-40% cheaper than A, not an order of magnitude**: ~1.0-1.3 us vs ~1.6-2.1 us per bullet. Its real advantages are
   one budget scope per bucket, **slicing** (1/4 of the bullets per tick costs 1/4), bulk writes and a command buffer.
3. **A stays for convenience** (`on_tick(b, dt)`), metered, with `tick_every = n` skipped *natively* by the manager.
4. **Events are not faster batched** (section 6). They go through a queue for determinism, caps and the no-silent-drop rule.
5. **Lua-side driver idea (cheap to try later):** because Lua->Lua is 6 ns, the *batch* can also be written as a Lua loop that
   calls the player's per-bullet function (`on_tick`) once per element: the boundary is crossed once per batch and the player
   still writes per-bullet code. Expected per-bullet cost is the B cost plus the Lua call (~0.1 us); not measured here.
6. **A native hot loop changes the constants, not the shape.** The Gameplay Engineer is moving the bullet hot loop to a C++
   GDExtension. Then the per-element Variant reads (130 ns) can become direct pointer reads: **estimated** B cost
   0.1-0.2 us per bullet (not measured), i.e. 10,000 batch updates in 1-2 ms. That needs the own/source-built binding (section 12). **With the accessor-object view of 8.2 on a native backing the estimate is higher, 0.25-0.45 us per bullet (estimate, not measured): section 8.3.**

### 8.1 Proposed interface diff (what changes in `architecture.md`'s `BulletBehavior` and the pool)

GDScript-facing (engine side; names are proposals for the Gameplay Engineer, **OI-15**):

```gdscript
# ---- BulletBehavior (additions; existing per-bullet hooks stay) ----
enum UpdateMode { NONE, PER_BULLET, BATCH }          # NONE = declarative only (fast path)
enum OverflowPolicy { DEFER, COALESCE }              # events are never dropped silently

var update_mode := UpdateMode.NONE
var update_interval := 1        # run every n-th tick; skipped bullets cost ~0 (manager skips natively: (index + tick) % n)
var update_slice := 1           # BATCH only: process 1/n of this behavior's bullets per tick (round-robin)
var event_mask := 0             # EV_SPAWN | EV_HIT | EV_WALL | EV_DESPAWN; unset bits cost nothing
var event_cap := 256            # events dispatched per tick; the rest stays queued
var event_queue_max := 16384    # above this, the surplus is coalesced into counted summaries

func on_update_batch(batch: UpdateBatch) -> void: pass   # BATCH mode: one call per bucket
func on_events(events: EventBatch) -> void: pass         # drained queue, oldest first
func can_hit(pool: BulletPool, index: int, hurtbox: Hurtbox) -> bool: return true   # optional, before receive_hit (OI-18a)

# ---- UpdateBatch / EventBatch (flat arrays, read once, written in bulk) ----
class UpdateBatch:
    var n: int; var dt: float
    var id: PackedInt64Array          # stable ids (generation << 32 | handle)
    var pos: PackedFloat32Array       # interleaved x,y (from PackedVector2Array.to_byte_array())
    var vel: PackedFloat32Array
    var age: PackedFloat32Array
    var param_a: PackedFloat32Array
    var param_b: PackedFloat32Array
    var out_vel: PackedFloat32Array   # Lua writes; applied after the call
    var cmds: PackedFloat32Array      # command buffer, stride 6: op, id, a, b, c, d
    var cmd_count: int

# ---- BulletPool (additions) ----
var id: PackedInt64Array              # stable-id column (or computed id_of); stable ids exist in [PR #4] (handle -> slot indirection table)
func behavior_range(behavior_id: int) -> Vector2i        # needs bucketing/sorting by behavior_id (the GE already plans it)
func gather_vec2(indices: PackedInt32Array, src: PackedVector2Array) -> PackedFloat32Array   # bulk read
func apply_vel(indices: PackedInt32Array, v: PackedFloat32Array) -> void                    # bulk write
func teleport(index: int, position: Vector2) -> void     # [main] (bullet_pool.gd:221): sets pos AND prev_pos

# ---- Command buffer / manager ----
# ops: 1 SPAWN(x,y,angle,speed,...), 2 KILL(id), 3 SET_PARAM(id,a,b), 4 TELEPORT(id,x,y), 5 REFLECT(id,layer,reverse)
var script_budget_ms := 3.0                      # BulletManager: per-frame script time; slices round-robin when exhausted
var max_deferred_spawns := 8192                  # per tick; surplus counted in get_deferred_dropped_count()
func get_script_stats() -> Dictionary            # hooks run/skipped, events queued/coalesced, ms by phase

# ---- ShotEmitter (additions) ----
func request_polar(x: float, y: float, angle: float, speed: float, lifetime: float, behavior_id: int) -> bool
func request_batch(buf: PackedFloat32Array, count: int) -> int   # stride 8: x, y, angle, speed, lifetime, radius, damage, behavior_id
```

Lua-facing (what `ScriptHost` hands the player; measured shapes):

```lua
-- per-bullet (A), opt-in
on_tick = function(b, dt) ... end                       -- tick_every = n skips natively

-- batch (B): the measured signature the harness used
function M.on_update_batch(ids, pos, vel, age, param_a, n, dt, out_vel, cmds)
  -- pos, vel: flat float32, 0-based, stride 2 (x, y); age/param_a: stride 1; out_vel: same layout as vel
  -- cmds: float32 command buffer, stride 6 records (op, id, a, b, c, d); returns the count
  return out_vel, cmds, ncmds
end

-- events: stride-8 records, oldest first
--   kind (0 spawn, 1 hit, 2 despawn, 3 wall, 4 summary), id (int64 array), other (target / reason),
--   x, y, vx, vy, damage (float32 array); a SUMMARY record carries count, sum damage, centroid x/y
on_events = function(ev, n) ... end
```

The player-facing API (`on_tick`, `on_batch(bs, dt)`, `on_hit`, ...) is a thin layer over these; see api.md
*Per-frame logic: tick vs batch*.


### 8.2 The batch view: shapes, overhead and the pick (backend-agnostic)

**Requirement (Gameplay Engineer, Karyu):** one Lua-facing batch accessor, **identical for scripts** over two backings: **packed copies** made by the
GDScript pool now, and **zero-copy userdata over native pool memory** later (C++ pool, plain bullets). Choose the cheapest shape that can
swap its backing without script changes, and measure the wrapper against raw access.

Kernel per bullet: read `pos(x,y)`, `vel(x,y)`, `age`, a `sqrt`-based steering step, write `out_vel(x,y)`; `n = 4,000`, 61 repetitions; **three runs** on the
editor build and **three** on the exported release template (`spike/bench/view_shapes.gd`; raw output `spike/results/view_shapes_editor.txt`, `view_shapes_release.txt`).
Median per bullet; "vs raw" is against raw interleaved packed arrays (`pos[2*i]`), which is what batch B used until now:

| Shape (Lua side) | ns per bullet (release, 3 runs) | vs raw (editor runs / release runs) | Verdict |
|---|---|---|---|
| **R** raw interleaved packed arrays `pos[2*i]` | 907-915 | 1.00x | baseline; leaks the memory layout (stride 2) into scripts |
| **S1** methods `v:pos(i)`, `v:set_vel(i, x, y)` | 1,019-1,040 | 1.12-1.25x / 1.12-1.14x | tuple returns; a method call per access; hoisted `pos(v,i)` 1.08-1.18x |
| **S2** column proxies, Lua `__index` tables | 1,054-1,103 | 1.19-1.21x / 1.15-1.22x | works on any backing but the slowest column form |
| **S2r/S2u columns = bare packed arrays**, `v.px[i]` | 858-928 | **0.91-1.06x** / **0.94-1.02x** (one 1.38x outlier on a noisy run) | **picked for the packed backing**: separate columns, no stride in scripts |
| **S3** `Vector2` elements `v.pos[i].x` | 1,798-1,916 | 1.98-2.09x / 1.97-2.09x | rejected: a Variant per element |
| GDScript copy: de-interleave 4 columns, re-interleave 2 | 67-69 per bullet (0.27 ms per 4,000) | | the **net cost of the packed backing**: about **0.07 us per bullet** |

**Decision: column accessor objects** (`v.n`, `v.id[i]`, `v.px[i]`, `v.py[i]`, `v.vx[i]`, `v.vy[i]`, `v.age[i]`, `v.pa[i]`, `v.pb[i]`, plus `v:teleport/kill/reflect/spawn...`
commands, **0-based**), spelled out in api.md *The batch view `v`*.
- On the **packed backing** a column is the packed float32 array itself: no wrapper at all, so the object costs **0.91-1.06x of raw** (hoisting the column
  into a local or not changes it by about 5%). Splitting interleaved `pos` into `px`/`py` costs the 0.07 us per bullet above, paid in GDScript.
- On the **native backing** the same `v.px` is a userdata whose `__index`/`__newindex` metamethods read the pool's memory (section 8.3). The script text does not change.
- Why not the others: methods (S1) need a call per element on both backings and hide nothing the columns do not; proxies (S2) cost 15-22% on the packed
  backing for nothing it needs; Vector2 elements (S3) are 2x; raw interleaved (R) bakes stride-2 into every script and cannot be swapped without rewriting scripts.
- **Divergences by design (measured, listed in api.md rules 3-5):** on the packed backing an out-of-range index reads `nil` (negative indices read from the end), an
  out-of-range write raises, a write to a read-only column changes only the throw-away copy, and an expired view cannot be detected; the native backing raises in all
  four cases. Both are memory-safe; scripts must follow the rules and then cannot tell the backings apart.

### 8.3 Native zero-copy backing: the C++ contract, and how it reaches Lua

**Scope (Karyu, relayed): narrow.** Only a **plain-bullet batch view** is native: the C++ pool hands Lua a read/write view of its own SoA columns for a bucket of plain bullets
(no per-bullet script callbacks). **Hooked and scripted bullets stay in the GDScript pool on packed copies**, and nothing else in core knows about Lua. One accessor, two backings (8.2).

**A. What lua-gdextension allows (read from the source and tested on 0.8.2 / the source build).**

| Question | Answer |
|---|---|
| Can a foreign extension register its own **userdata** type with a metatable? | **No.** Userdata is created only for Godot objects/Variants by lua-gdextension itself (`sol2` usertypes inside its library). There is no API to register an arbitrary C userdata or metatable. |
| Are Lua C API symbols (`lua_newuserdatauv`, `lua_pushcclosure`, ...) exported for us to call? | **No.** Lua is statically linked into `libluagdextension` and **no Lua symbol is exported** (`nm -D --defined-only` on the release `.so`: 0 `lua_*`/`luaL_*` symbols). |
| Is the `lua_State*` reachable? | **No.** `LuaState::get_lua_state()` is a C++-internal member returning a `sol::state_view`; it is **not registered with ClassDB and not an exported symbol**, and `LuaState`/`LuaThread` expose no pointer to GDScript or other extensions, so a second extension cannot obtain a `lua_State*`. |
| Can `LuaFunction.invoke` pass a custom native object cheaply? | A Godot `Object` argument becomes the generic object wrapper whose method calls cost **~465-500 ns** each (measured): far above the 130 ns of a packed element. Not usable per element. |

**B. Proposal: P4, a patch to lua-gdextension (preferred; needs the fork, section 12).** Add one small binding **inside** lua-gdextension, which already owns the Lua API:
a class `LuaColumnView` and a Variant-to-Lua conversion that turns it into a **userdata with a fixed metatable** (`__index` and `__newindex`), implemented in C against the
descriptor structs below. Our C++ pool only fills a plain C struct and passes its address as an integer (`LuaFunction.invoke(view_ptr_as_int)` or `LuaState.push_batch_view(ptr)`): no Lua headers, no `lua_State*`, no symbol linking. Size **estimate (not measured): 300-500 lines** + tests, plus the fork port itself.

**C. Fallback: a C ABI shim (wider).** A patched lua-gdextension exports a getter returning `lua_State*` plus a **function-pointer table** of the Lua C API we need; our extension builds the userdata
with its own code. This puts a Lua ABI contract (Lua 5.4.8 exactly) into our native code. Same fork needed, wider surface; **use only if P4 is rejected upstream or too slow to land.**

**D. The C++ contract (plain C, no Godot or Lua types; `ss_batch_view.h`).**

```c
typedef struct ss_column {          /* one logical column, any memory layout */
    void    *data;                  /* first element (float*, or int64_t* with SS_COL_I64); NULL only if n == 0 */
    uint32_t stride;                /* in floats between consecutive bullets (2 for interleaved pos/vel) */
    uint32_t offset;                /* float offset of this column inside a stride (0 = x, 1 = y) */
    uint32_t flags;                 /* SS_COL_WRITE (vx, vy, pa, pb only), SS_COL_I64 (id column: int64, stride in int64s) */
} ss_column;

typedef struct ss_batch_view {
    uint32_t       abi_version;     /* 1; mismatch -> refuse to bind */
    uint32_t       n;               /* bullets in this call (the slice) */
    uint64_t       epoch;           /* the pool's epoch when this view was filled */
    const uint64_t *live_epoch;     /* the pool's CURRENT epoch; compared on every access */
    ss_column id, px, py, vx, vy, age, pa, pb;
    float         *cmds;            /* command buffer, stride-6 records: op, id, a, b, c, d */
    uint32_t       cmd_cap;         /* records */
    uint32_t      *cmd_count;       /* records written so far */
} ss_batch_view;
```

1. **Userdata layout.** The userdata holds **a copy of one `ss_column` plus `{n, epoch, live_epoch, kind}`** (about 48 bytes), never a pointer into pool-owned structs, so a view that
   outlives the call cannot dangle onto freed descriptors; `v` itself is a table-like userdata whose `__index` returns the column userdata for `px`, `vx`, ... (hoisted once per call by scripts).
2. **Indexing.** `col[i]`: Lua integer or float with an integral value; **0-based**; `data[(offset + stride*i)]`. Anything else raises "bad column index".
3. **Bounds.** `i` is checked as unsigned `i < n` on **every** read and write (one compare); any other value raises "column index out of range (n)". `n` never exceeds the column capacity (pool invariant: the
   bucket range was validated when the view was filled). Negative indices are out of range (the packed backing's wrap-around is a documented difference, 8.2).
4. **Validity window.** The view is valid **from the hook-call entry until the hook returns**. Every access checks `view.epoch == *live_epoch`; the pool increments `live_epoch` **at the end of the hook call
   (after the command buffer has been applied)** and whenever it compacts, swap-removes, grows or reallocates its columns. Stale use raises "view expired" instead of reading freed memory. **While a hook runs, the pool must not move columns**: spawns and kills during
   the hook go through the command buffer (this already is the rule for batch B). Single-threaded: the hook runs on the main thread in the physics tick; no worker touches the columns meanwhile.
5. **Write semantics.** Writable columns (`vx`, `vy`, `pa`, `pb`) point at **scratch copies**, filled from the live columns when the view is created (`4 columns x 4,000 x 4 B = 64 KB`, estimated 5-10 us), so (a) later reads in the callback see earlier writes, (b) an error or a
   watchdog stop **commits nothing** (the pool discards the scratch, exactly as the packed backing and `player` writes), (c) the pool **sanitizes at commit** (NaN ignored, speed clamped) and copies back. Read-only columns point at the live memory; a write raises "column 'px' is read-only".
   Position changes are never writes: `v:teleport(i, x, y)` is a command (`BulletPool.teleport`).
6. **Commands.** `v:teleport/kill/reflect/spawn_polar/spawn` append stride-6 records to `cmds` (bounds-checked against `cmd_cap`; over the cap counts and drops, like the other caps); the pool applies them **after the callback returns, in order**.
7. **Getting the `lua_State` (the one hard question).** Our code never needs it under P4: the binding inside lua-gdextension owns the state; the pool passes the descriptor address through the extension's own call path. Under the C ABI shim the patched lua-gdextension returns the `lua_State*` of the state running the hook and the function-pointer table.
8. **ABI/version pin.** Descriptor `abi_version`, Lua 5.4.8, godot-cpp `507ed9d`/`api_version=4.7` for our extension, and the lua-gdextension fork commit are pinned together in the pipeline; any change to the struct bumps `abi_version`.

**Expected cost (estimate, not measured: it needs the fork).** A Lua `__index` on a C userdata is a C-function call without Variant conversion: roughly **30-60 ns per element** versus the 130 ns packed read, so a bullet with 5 reads and 2 writes costs about **0.25-0.45 us**
(against ~0.9 us on packed copies, and the earlier 0.1-0.2 us estimate for raw light-userdata pointers that scripts cannot use safely). That is **2-4x**, not 10x, for the accessor form; the full 10x needs scripts to hand whole columns to native helpers, which is out of scope (narrow view only).

**Sequencing.** Design and ship the accessor for **packed copies on stock 0.8.2 first** (section 8.2; works today); the native backing depends on the **fork (section 12)**, the P4 patch and the C++ pool, and is built by the Gameplay Engineer after the pool refactor against this contract.

## 9. Hooks, watchdog and error isolation (benchmarks c and d)

### Hook cost

Arming **any** count hook slows pure Lua about **2.5x** (Lua 5.4 trap path), almost independent of the count:
20 M VM instructions: off 33 ms; hook on count=100 354 ms; count=1,000 85 ms (Lua function) / 96 ms (GDScript
Callable); count=10,000 70 ms. On realistic bullet callbacks (4,000 per-bullet calls per frame): off 3.60 ms;
count=100 5.01; **count=1,000 4.05 (+13%)**; count=10,000 3.67. So the watchdog uses **count = 1,000**.

### Does the hook interrupt runaway code?

| Case | Result |
|---|---|
| `while true do end`, 2 M-instruction budget | aborted in 8.3 ms, state still usable |
| unbounded `pcall` loop with a raising hook | the **raw `pcall` swallows the error**: 2,000 budget errors in a row, script kept running; an unbounded `while true do pcall(...) end` never terminates |
| same with a sentinel-rethrowing `pcall` | aborted after 463 ms |
| unbounded table growth (2 M budget) | aborted; Lua memory 117 MB at abort, 36 MB after `collect_garbage()` |
| `('a'):rep(2000/8000/16000):match('.-b')` | 17 / 211 / 862 ms, **budget not triggered** (a native call: few VM instructions) |
| `('x'):rep(2^27)` | allowed, 128 MB, 587 ms; no memory cap in the binding |
| hook set on the main thread, loop inside a Lua-created coroutine | **not covered**: a 30 M-iteration loop ran to completion (the binding keeps hooks in a registry table keyed by thread) |
| `LuaCoroutine` + a host Callable hook returning `HOOK_YIELD` | works: a finite loop finished after 90 yields; an infinite loop was stopped by the host after 21 slices (status "yield", dropping the coroutine kills it); **uncatchable by `pcall`** |
| coroutine created *inside Lua*, passed to a GDScript Callable | arrives as `LuaCoroutine` (a `LuaThread`), `set_hook` works on it: the sandbox `coroutine.create/wrap` wrappers can register every child thread |

### Error isolation (d1) and churn (d2)

No crash and no host exception for: plain error, table error (message becomes "An unknown error has triggered the default error
handler"), nil index, error in `pcall` / in a coroutine, calling a nonexistent Godot method, stack overflow, syntax error, a freed
Callable and a freed Node object; the main loop kept ticking. Churn: **about 303,000 coroutine creates in total** (200,000 Lua-side `coroutine.create`, 100,000 GDScript-side
`LuaCoroutine` create/drop, 3,000 per-frame hooked coroutines freed while suspended), plus 200 state re-creations: no crash, memory back
to baseline (0.1-0.3 MB). The raw output of this run (editor build) is committed as `spike/results/hook_editor.txt`, section (d2). **Issue #240 was not reproduced** with these patterns (it stays a regression test).

## 10. Export proof (platforms: Windows, macOS, Linux, web, mobile)

Each build runs a 1,000-bullet scene with Lua steering (rendering on) in four phases (C, A, B, B + the guard hook) and prints
the Lua time. `frame_ms` is capped by vsync at ~16.7 ms; the **Lua ms** is the meaningful column.

| Target | Run | C step | A: Lua ms (hooked) | B: Lua ms | B + guard hook: Lua ms | fps |
|---|---|---|---|---|---|---|
| **Linux** native, release template | exported binary | 0.57 ms | 1.70 | 1.15 | 1.46 | 145 |
| **Web, threads** (`web_dlink_threads`, `extensions_support=true`) in headless Chrome 156, `crossOriginIsolated = true` | Playwright | 1.32 ms | 4.32 | 1.61 | 1.91 | 58-60 |
| **Web, no threads** (`web_dlink_nothreads`) | Playwright | 1.01 ms | 2.76 | 1.48 | 1.92 | 60 |
| **Android** (arm64-v8a + x86_64, non-gradle, debug-signed APK 67.6 MB) | built and ABI-checked, **not run** (no KVM here; QA runs it on an x86_64 emulator) | | | | | |

- Web: both extension builds load on 4.7.2 and run the same script; WebAssembly costs about **1.3-2.5x** the native Lua time in
  this run (software GL on the same CPU; the numbers include noise from a shared box). The extension wasm is 2.65 MB; the
  Godot side `index.side.wasm` is 44 MB. The lib file must sit next to `index.html`.
- **Android export and ABI check (done).** The preset is committed as `spike/export_presets.cfg` (preset `Android`, non-gradle,
  `architectures/arm64-v8a=true`, `architectures/x86_64=true`, `extensions_support`, debug keystore supplied by the runner, no secrets in the file).
  **The 0.8.2 release zip ships an Android x86_64 `.so`** (`unzip -l` of `lua-gdextension.zip`, SHA256 `51f012dd...2443`: `libluagdextension.android.template_debug.x86_64.so` 5,095,632 B,
  `..._release.x86_64.so` 4,674,496 B; also arm64, arm32 and x86_32 in both), so no NDK build is needed for the emulator. The debug APK was built with
  `godot --headless --export-debug "Android" out_android/spike.apk` and **`unzip -l spike.apk` shows both ABIs**:

  ```
  lib/arm64-v8a/libluagdextension.android.template_debug.arm64.so    5442360
  lib/x86_64/libluagdextension.android.template_debug.x86_64.so      5095632
  lib/arm64-v8a/libgodot_android.so                                  76181608
  lib/x86_64/libgodot_android.so                                     81186808
  assets/addons/lua-gdextension/luagdextension.gdextension          2664
  assets/scripts/steer.lua                                            1038
  ```

  The APK (67.6 MB) is **not committed**. **Emulator: not possible here**: `/dev/kvm` is not accessible to the box user (`emulator -accel-check`) and a `-no-accel` boot of the x86_64 image would take
  many minutes and prove only that the `.so` loads. **The run is QA's** (x86_64 emulator with KVM on GitHub Actions); the exact command and expected log are in testing.md *Android headless run*.
- **The result line (stable, greppable).** The 1,000-bullet scene (`bench/export_bench.gd`, started automatically on web and mobile) prints one JSON object per phase to stdout (**logcat tag `godot`**, browser console on web), then `SPIKE_DONE`:

  ```
  SPIKE_RESULT {"alive":1000,"arch":"x86_64","fps":145.0,"frame_ms_med":6.9,"frame_ms_p95":7.06,"godot":"4.7.2-stable (official)","hooked":0,"lua":"Lua 5.4","lua_mem_kb":82,"lua_ms_med":0.002,"lua_ms_p95":0.003,"mode":"C","n":1000,"os":"Linux","step_ms_med":0.665,"step_ms_p95":1.134}
  ```

  Fields: `mode` in `C`, `A`, `B`, `B+hook` (four lines), `n`, `alive`, `hooked`, `lua_ms_med`/`lua_ms_p95` (Lua time per frame), `step_ms_*`, `frame_ms_*`, `fps`, `lua_mem_kb`, and `os`/`arch`/`godot`/`lua`. On Android expect `"os":"Android"` and `"arch":"x86_64"`. (Sample above: the same scene run headless on Linux with the editor build; `spike/results/export_bench_headless_editor.txt`.)
- **Shipped binaries (0.8.2 release zip, listed):** Windows x86_32 / x86_64 / arm64 (`.dll`), Linux x86_32 / x86_64 / arm64
  (`.so`), macOS universal (`.dylib`), Android arm32 / arm64 / x86_32 / x86_64 (`.so`), iOS (`.xcframework`), Web wasm32 threads
  and no-threads, each in `template_debug` and `template_release`. **iOS cannot be built or tested here** (no macOS/Xcode);
  the library is shipped, nothing was run.
- Windows and macOS binaries are shipped but were **not run** on this Linux box (upstream CI builds them on `windows-latest` / `macos-latest`).

## 11. B4: adversarial guard-rail tests (QA item B4)

**Goal:** the strongest guard that keeps *full freedom for own scripts*, proven by scripts that try to defeat it. Each test is its
own process under `timeout` (so a hang or crash is attributable), on Godot 4.7.2 / lua-gdextension 0.8.2, comparing a **naive**
design (a Lua-function error hook on the main thread, full libraries, no wrappers) with the **G1** design:

> **G1 = host-owned coroutine per callback + a GDScript Callable count hook (count 1,000) that returns `HOOK_YIELD` on
> instruction / wall-clock / memory verdict (then re-arms to count 1) + a sandbox environment table built from the capability
> set** (`spike/sandbox/sandbox.lua`: wrapped `coroutine`, `pcall`/`xpcall`, bounded `string`, `os.exit` replacement, trimmed
> `debug`, sanitized `package.loaded`, text-only `load`, no `__gc`, native facade).

Budgets in the spike: 20 M instructions (~100 ms; deliberately far above the API default of 100,000 per callback so that tests are not decided by the budget), 300 ms wall clock, 64 MB memory; `string.rep` 1 MiB, pattern subject 1,024.

| # | Attack | Naive | G1 |
|---|---|---|---|
| 1 | `while true do end` | error: instruction budget exceeded, 9 ms | stopped: instruction budget, 188 ms |
| 2 | `while true do pcall(function() while true do end end) end` | **HUNG** (killed at 25 s) | stopped: instruction budget, 117 ms |
| 3 | `pcall(error)` loop | error: instruction budget exceeded, 1004 ms | stopped: wall clock, 301 ms |
| 4 | spin inside a `<close>` handler, under `pcall` | completes, 9 ms | stopped: instruction budget, 130 ms |
| 5 | `debug.sethook()` (clear the hook), then spin | **HUNG** (killed at 25 s) | stopped: instruction budget, 119 ms |
| 6 | `debug.sethook(function() end, "", 1)`, then spin | **HUNG** (killed at 25 s) | stopped: instruction budget, 125 ms |
| 7 | `package.loaded.debug.sethook()` | **HUNG** (killed at 25 s) | error: attempt to index a nil value (field 'debug'), 0 ms |
| 8 | `load("return debug")()` then `sethook`, then spin | **HUNG** (killed at 25 s) | stopped: instruction budget, 128 ms |
| 9 | spin inside a coroutine the script created | **HUNG** (killed at 25 s) | stopped: instruction budget, 116 ms |
| 10 | spin driven by a `coroutine.resume` loop | **HUNG** (killed at 25 s) | stopped: instruction budget, 128 ms |
| 11 | spin in a `table.sort` comparator inside a `pcall` loop | **HUNG** (killed at 25 s) | stopped: instruction budget, 122 ms |
| 12 | table memory bomb (1 KB strings) | error: instruction budget exceeded, 714 ms, 247.1 MB | stopped: memory cap, 269 ms, 64.0 MB |
| 13 | `collectgarbage("stop")` + allocate | error: instruction budget exceeded, 85 ms, 51.7 MB | stopped: memory cap, 158 ms, 64.0 MB |
| 14 | `("x"):rep(2^28)` | completes, 854 ms, 256.1 MB | error: string.rep: result too large (sandbox limit), 1 ms |
| 15 | `debug.getupvalue` to reach the real `string.rep` behind the guard (`debug` granted) | n/a (no guard / no facade in the naive harness) | error: attempt to call a nil value (field 'getupvalue'), 1 ms |
| 16 | `1 + f()` recursion | error: instruction budget exceeded, 358 ms, 30.6 MB | stopped: memory cap, 191 ms, 64.0 MB |
| 17 | `__index` recursion (C stack) | error: C stack overflow, 0 ms | error: C stack overflow, 0 ms |
| 18 | `local function f() pcall(f) end` | completes, 0 ms | completes, 0 ms |
| 19 | `("a"):rep(20000):match(".-b")` | completes, 1363 ms | error: string.match: subject too long for pattern matching (sandbox limit), 0 ms |
| 20 | the same pattern at the 1,024-char subject limit | not run | completes, 4 ms |
| 21 | pattern bomb through `debug.getupvalue` on the `match` wrapper (`debug` granted) | not run | error: attempt to call a nil value (field 'getupvalue'), 0 ms |
| 22 | 100 x 1 MiB `string.rep` allocations in a loop | not run | stopped: memory cap, 282 ms, 83.2 MB |
| 23 | `__gc` finalizer that spins, then `collectgarbage()` | not run | error: __gc finalizers are not available in scripts, 0 ms |
| 24 | `debug.setmetatable` with a spinning `__gc` | not run | error: __gc finalizers are not available in scripts, 0 ms |
| 25 | `xpcall(f, handler)` where the **handler spins** | not run | stopped: instruction budget, 119 ms |
| 26 | `xpcall(error, error, "x")` loop | not run | stopped: wall clock, 301 ms |
| 27 | `string.dump` then `load(bytes, "x", "b")` | not run | error: attempt to call a nil value (field 'dump'), 0 ms |
| 28 | `dofile`, `loadfile`, `string.dump` are nil (no `io` granted) | not run | completes, 0 ms |
| 29 | `debug.getupvalue/setupvalue/getregistry/getlocal` with `debug` granted | not run | completes: `getupvalue`, `setupvalue`, `getregistry` are `nil`; `sethook` is a no-op stub |
| 30 | `debug.getlocal` on a wrapper frame | not run | completes: no `getlocal`, nothing leaked |
| 31 | capabilities: none | not run | completes: `io`/`debug`/`package` nil, `os.time`/`os.clock` present, `os.execute` nil, **`require` present (confined to the script folder)** |
| 32 | capabilities: `io` | not run | `io.open` yes, **`io.popen` nil**, `os.execute` nil |
| 33 | capabilities: `os` | not run | `os.execute`, `os.getenv`, **`io.popen`** yes; `io.open` nil |
| 34 | capabilities: `package` | not run | `require` yes (arbitrary paths), `loadlib` nil, 2 searchers, `debug`/`io` not in `package.loaded` |
| 35 | capabilities: `native` | not run | `loadlib` yes, 4 searchers |
| 36 | `xpcall(table.sort, spinning_handler, t, spinning_comparator)` loop | not run | stopped: instruction budget, 126 ms |
| 37 | `load(function() while true do end end)` (reader function) | not run | error: load: only string chunks are supported, 0 ms |
| 38 | `xpcall` return values preserved | not run | completes: `false handled:boom`, `3 3` |
| 39 | `os.exit(0)` (with `os` granted) | **HUNG** (killed at 25 s) | stopped: os.exit requested, 0 ms |
| 40 | `os.exit` from inside a coroutine | **HUNG** (killed at 25 s) | stopped: os.exit requested, 0 ms |
| 41 | `rawset(_G, "spawn", nil)`, overwrite `_G.set_player_hp`, remove `print` | n/a (no guard / no facade in the naive harness) | completes, 0 ms |
| 42 | `spawn(NaN, inf, -inf, 1e308, ...)`, `spawn("a", {}, nil)`, `set_player_hp(NaN / inf)` | n/a (no guard / no facade in the naive harness) | completes; facade clamps to `[0, 1e7, -1e7, 1e7, 0]`, rejects strings/tables, ignores NaN, clamps hp |
| 43 | `require('mod_a')`, `require('sub.mod_b')`, cached second call, with no capability | not run | completes: own-folder modules load (`42 b cached=true`), `package` is `nil` |
| 44 | `require` escapes: `../project`, `/etc/passwd`, `sub/mod_b`, `mod_a.lua`, `..mod_a`, a missing module | not run | all six refused (`false,false,false,false,false,false`) |
| 45 | `dofile` / `loadfile` of a **text** file with `io` granted | not run | completes: `dofile=7 loadfile=function` |
| 46 | `loadfile` / `dofile` of a **binary** chunk, and `load(bytes, 'x', 'b')`, with `io` granted | not run | refused everywhere: "attempt to load a binary chunk (mode is 't')" |
| 47 | `dofile` / `loadfile` **without** `io` | not run | completes: both `nil` |

**Totals:** naive design, 23 cases run: **10 hang or kill the game** (cases 2, 5-11, 39, 40), 13 survive, none of them with the attack stopped by anything but the engine's own limits; **G1: 0 hangs, 0 crashes, 0 host failures in 47 cases (rerun at the end of this revision: 47/47 `host_ok=true`)** (`host_ok=true heartbeat=ok` after each; a fresh `LuaState` works). "Naive" = Lua-function count hook on the main thread, full libraries, no wrappers; tests added later were not run against it (shown as "not run").

(Raw lines: `spike/results/adv_g1.txt` (47) and `adv_naive.txt`; cases 43-47 are new in v0.3 for the confined `require` and the `dofile`/`loadfile` rules; the printed-output text of case 31 was tidied.) Found-and-fixed by running this suite against earlier versions of G1: **`debug.getupvalue` reaching the real `string.rep`/`string.match` (cases 15 and 21; 256 MB / 819 ms and 2.1 s)**, **`xpcall` message handlers running with hooks off (case 25: hang)**, **`__gc` finalizers running with hooks off (cases 23-24)**, and the `table.sort` boundary re-arm (case 11).

### What G1 proves, and what stock lua-gdextension cannot do

Proven on 4.7.2: a **host-owned yield watchdog** survives `pcall`, `xpcall`, `__close`, error handlers, `table.sort` comparators,
child coroutines, `load`, `debug.sethook`, and `os.exit`; the facade is native; capabilities map to concrete library sets; the
granted `debug` cannot reach the guards. Cost of the guard: ~13% on realistic callbacks (section 9), one `LuaCoroutine` per
callback (pooled).

**Residual holes, i.e. what the stock binary cannot close** (need the source-built binding, section 12):

1. **Single huge native allocation or a native call that never returns to the VM** (pattern matching, `table.concat`,
   `string.rep` family, `table.sort` on a huge table): the hook only runs between VM instructions. Mitigated by per-call limits
   (1 MiB `rep`, 1,024-char pattern subjects), which are Lua wrappers.
2. **Soft memory cap on stock (no hard cap)**: the 64 MB check runs every 1,000 instructions; measured overshoot 64 -> 83 MB with 1 MiB allocations, larger if
   limits are raised. A `lua_Alloc` that returns `NULL` past the cap is the fix; the binding creates states with the default
   allocator (`sol::state`) and exposes no hook for it.
3. **No cross-thread watchdog**: `LuaThread.set_hook` writes the Lua registry and is not safe from another Godot thread, so
   nothing can interrupt a native call from outside. (`lua_sethook` itself may be called from another thread; the binding's
   registry write is the problem.)
4. **The guards that are Lua wrappers are reachable by `debug`** unless `debug` is trimmed (done in G1); native limits cannot be
   reached.

**Does B4 change the binding choice?** For the **prototype / M1: no.** Stock 0.8.2 + G1 stops every attack above except the
residual native-call and allocation cases, and those are bounded to ~4 ms and ~100 MB. For **imported/shared scripts being
hard-sandboxed** (PR #1 section 7) **yes, eventually**: items 1-3 are real, and PR #1 explicitly promises "allocation beyond the cap raises
a Lua error inside the script". That needs the Lua C library under our control: see the next section.

## 12. Build from source: pins, the godot-cpp 10.0.0-stable result, and the fork

Scriptshot's own C++ bullet pool will be a GDExtension on **godot-cpp `507ed9d` (10.0.0-stable, 2026-09-15) with `api_version=4.7`** (its `extension_api-4-7.json` matches the dump of the Godot 4.7.2 editor), and QA is building
one shared native pipeline. **Never write "godot-cpp 4.7.2" for the other pin:** lua-gdextension 0.8.2 pins godot-cpp **`58d1de7` = 10.0.0-rc1 with the 4.6 API**.
**Verified / blocked:** the 0.8.2 source **does not build unmodified against `507ed9d`**; with the patch set below it **builds with `api_version=4.6` and passes the spike on Godot 4.7.2 (verified, Linux x86_64)**;
an `api_version=4.7` build is **blocked** on the `memnew`/`Ref<>` port; web, Android and the other desktop platforms were **not** attempted from source here.

### 12.1 Pins (from the Godot 4.7.2-stable tree, QA review of PR #3)

| | Value |
|---|---|
| Build tool | SCons **4.10.1**; godot-cpp's own default is 4.4.0 |
| **Emscripten (web)** | **4.0.20** for the official 4.7.2 web template. (**4.0.11** is only the engine's CI `EM_VERSION` and the `setup-godot-cpp` action default; our own builds pin 4.0.20.) The stock 0.8.2 wasm, built upstream, loaded and ran on the 4.0.20 official templates in section 10 |
| **Android NDK** | **29.0.14206865** (clang 21); not r28b (28.1.13356709). Minimum API level **24** (godot-cpp forces `android_api_level >= 24`) |
| Android build-tools / JDK | **36.1.0** / JDK **17** (this box built the spike APK with build-tools 35.0.1 because that is what was installed; pin 36.1.0 for the pipeline) |
| Windows | MSVC (upstream CI: Visual Studio 18 Enterprise `vcvarsall.bat`); x86_64, x86_32, arm64 |
| Linux | Ubuntu 22.04 runners (glibc floor), `g++-multilib` for x86_32, `ubuntu-24.04-arm` for arm64 |
| macOS | `macos-latest`, `universal` arch; iOS `universal` |
| C++ | **C++20**, **exceptions enabled** (`-fno-exceptions` removed), `-s` (strip) removed so `luagdextension_entrypoint` stays exported |
| godot-cpp | **`507ed9d`** (10.0.0-stable) for our own extension, `api_version=4.7`; lua-gdextension's own submodule stays on `58d1de7` until a port. **Keep the two godot-cpp submodules separate.** |

**Command lines** (upstream CI; add `api_version=4.6` for the 0.8.2 source with godot-cpp 10, and `PYTHON_BIN=python3` where there is no `python`):

```
scons platform=linux   arch=x86_64 target=template_release lua_runtime=lua
scons platform=windows arch=x86_64 target=template_release lua_runtime=lua    # vcvarsall_path=... for MSVC
scons platform=macos   arch=universal target=template_release lua_runtime=lua
scons platform=android arch=arm64  target=template_release lua_runtime=lua    # ANDROID_HOME and NDK 29.0.14206865; also arm32 x86_32 x86_64
scons platform=web     arch=wasm32 target=template_release threads=true  lua_runtime=lua
scons platform=web     arch=wasm32 target=template_release threads=false lua_runtime=lua
```

**Flags the web build gets from godot-cpp** (`tools/web.py`): `-sSIDE_MODULE=1`, `-sUSE_PTHREADS=1` (threads only), `-sWASM_BIGINT`,
`-sSUPPORT_LONGJMP='wasm'`, LTO `full`; defines `WEB_ENABLED UNIX_ENABLED`. **Android** (`tools/android.py`):
`--target=<abi><api>`, `-march=...`, `-fPIC`, `-mfpu=neon` (arm32), `-mstackrealign` (x86_32). **Lua** itself is built from the `lua` submodule
(`6e22fed`, 5.4.8) with `sol2` (`ab874eb`) as the C++ glue and `tree-sitter` (`0bb43f7`) for the editor's parser. Godot-side
export requires `variant/extensions_support=true` on web and the **dlink** templates (threads true or false).

### 12.2 The build attempt (Linux x86_64, this box; web not attempted: no emcc)

| Step | Result |
|---|---|
| Unmodified: `scons platform=linux arch=x86_64 target=template_release lua_runtime=lua` against `507ed9d` | **Fails.** (1) godot-cpp 10 requires an explicit `api_version`; (2) the three code generators read `extension_api.json`, which godot-cpp 10 replaced with `extension_api-4-X.json`; (3) eight headers use `Ref<>` without `#include <godot_cpp/classes/ref.hpp>`, which `ref_counted.hpp` no longer pulls in ("field has incomplete type `Ref<...>`", 49 error sites). This matches QA's finding. |
| With the patch set, `api_version=4.6`, release and debug | **Builds.** Output `libluagdextension.linux.template_{release,debug}.x86_64.so`. |
| That build, on Godot 4.7.2 (editor and release template) | **Loads; smoke test passes; the 47-case adversarial suite gives outcomes identical to the stock 0.8.2 binary** (0 hangs, 47/47 `host_ok=true`; raw output `spike/results/adv_g1_source_build_46api.txt`). |
| `api_version=4.7` | **Fails** at compile time: with `api_version >= 4.7`, `memnew(T)` of a `RefCounted` type returns **`Ref<T>`** instead of `T*` (`memory.hpp`; first hit `LuaCoroutine`). Blocked on the port below. |

**Patch set** = `spike/patches/lua-gdextension-0.8.2-godot-cpp-507ed9d.patch` (144 lines; reverse-applies cleanly to the 0.8.2 tag; the `lib/godot-cpp` pointer is a local symlink to `507ed9d`, not part of the patch):
- `tools/code_generation/generate_cpp_code.py`, `generate_lua_godot_api.py`, `tools/code_generator.py`: `extension_api.json` -> `extension_api-4-6.json`;
- `#include <godot_cpp/classes/ref.hpp>` in `src/LuaError.hpp`, `LuaDebug.hpp`, `LuaASTNode.hpp`, `LuaASTQuery.hpp`, `LuaAST.hpp`, `LuaState.hpp`, `LuaParser.hpp`, `LuaObject.hpp`;
- environment: `PYTHON_BIN=python3` (the build hard-codes `python`); `lua_runtime=lua`, `api_version=4.6`.

**Effort to turn this into a maintained fork (estimates, not measured).** The 4.6-API build above was about a day. A clean `api_version=4.7` port needs, besides the patch set,
the `memnew`-of-`RefCounted` handling: **about 30 `memnew` sites in `src/`, roughly 15-20 of them create `RefCounted` types** (`LuaCoroutine`, `LuaTable`, `LuaFunction`, `LuaError`, `LuaDebug`, `LuaAST*`, `LuaScript`),
**about 2-3 days** with regenerated bindings and the smoke and adversarial tests re-run; then web, Android and the other desktop targets in the shared pipeline, **2-3 days**; then about **half a day per upstream release** to rebase.
P1-P3 are ~3 days on top (below); P4 is the new binding (section 8.3). **About 2 engineer-weeks to a patched six-platform fork.** Check upstream `main` first: it may move to godot-cpp 10 on its own.

### 12.3 What this means for the roadmap

- **M1 uses the stock 0.8.2 release binaries, pinned by SHA256**, with G1 and the sandbox wrappers. It works on every target tried and needs no build.
- **A source build (P1-P3, any P4) requires the fork port first.** The patch series is therefore **lower priority than M1 integration** and, since in-game sharing/import is deferred by Karyu, **no longer gated on import**.
- **The zero-copy view (P4, section 8.3) depends on the fork**, so the batch view ships on **packed copies on stock 0.8.2 first** (section 8.2) and the native backing swaps in later with no script change.
- Fallback if the fork is too costly: our own thin GDExtension (below).

### 12.4 Patch series (after the fork exists)

| Patch | What | Size (estimate, not measured) |
|---|---|---|
| **P1 allocator cap** | create states with `lua_newstate(alloc, ud)`; `alloc` returns `NULL` past the cap and counts bytes (`LuaState.set_memory_limit(bytes)`, `get_memory_limit()`); the cap becomes a real Lua "not enough memory" error inside the script (**hard**; stock is soft) | ~60-100 lines in `LuaState.cpp/.hpp` + test |
| **P2 native string limits** | `string.rep` result limit and a pattern-matching step/deadline counter in `lstrlib.c` (`MAXCCALLS`-style `ms->matchdepth` plus a step budget), configured per state | ~80 lines of Lua source patch, kept as a `.patch` file |
| **P3 async interrupt** | `LuaState.interrupt()` that calls `lua_sethook(L, flag_hook, LUA_MASKCOUNT, 1)` from any thread without touching the registry; makes a wall-clock watchdog thread possible | ~40 lines |
| **P4 native column view** | the userdata binding of section 8.3 (preferred) or a C ABI shim with a `lua_State*` getter (fallback) | ~300-500 lines + tests, plus the C++ pool side |
| P5 hook-safe finalizers (optional) | run `__gc` with the hook enabled, or drop it | small; the sandbox already refuses `__gc` |

With P1-P2 the "Known limits that stock lua-gdextension cannot close" in api.md disappear and `debug` can be offered whole (the guards no longer live in Lua). **Effort:** P1-P3 with tests ~2-3 days; ongoing cost one rebase per upstream release.

### Fallback: our own thin GDExtension (if lua-gdextension must be dropped)

Triggers: an upstream break we cannot patch (e.g. #257 turns out to hit the exported game), the fork port proves too costly, the Variant boundary proves too
slow even with batching, or PR #1's hard sandbox needs more than P1-P3. Shape: godot-cpp `507ed9d` (`api_version=4.7`) + Lua 5.4.8 compiled statically
(plain C, no sol2, no tree-sitter), `ScriptHost` native class owning states, the watchdog, the allocator cap and a **native bullet
facade** (light-userdata bullet views: no Variant on the hot path: estimated 0.1-0.2 us per bullet-update). **Estimate (not measured):** ~4-6 weeks for one engineer to parity with what the game uses
(states, load with env, call, coroutines, hooks, packed-array views, errors, GUT tests), plus per-platform build work already
covered by the shared pipeline (~2-3 days for web/threads and Android ABI checks), plus signing/notarisation which is already needed for the game.

## 13. What this means for the API design (summary; details in api.md)

- **Per-frame logic** is three grades (C / B `on_batch` / A `on_tick`), A and B throttle natively; 3 ms Lua = ~3,000 batch updates
  or ~1,900 per-bullet calls per tick; 5,000 bullets need slicing or 10-50% scripted per tick; 10,000 need slicing.
- **Events** are queued, capped per tick for dispatch, deferred, coalesced only above a hard bound, never silently dropped.
- **`fire()`**: provide `request_polar`/`request_batch`; building a `ShotRequest` from Lua is 3x slower than GDScript.
- **Sandbox**: capabilities select library sets (`needs`); guards are host-owned (yield watchdog), not Lua-visible; `debug` is
  trimmed in the stock binding and whole in the source-built one; `xpcall`, `__gc`, `load`, `string.dump` are specially handled;
  `os.exit` never exits.
- **Memory cap** (64 MB) is adopted as a requirement; **soft on stock**, hard only with P1 on a source build.
- **Export:** stock 0.8.2 covers Windows/macOS/Linux/web (threads and no-threads)/Android binaries; web (headless Chromium with software GL only) and Linux were run; Android
  was built with both ABIs and not run; iOS is shipped but unbuilt/untested here.
- **Batch view:** column accessor objects, identical over packed copies (now, stock 0.8.2) and a future zero-copy native backing (needs the fork and P4); section 8.2-8.3.

## 14. Open questions

1. Run the GUI editor on a real Wayland Linux and on Windows/macOS with the addon (#257 is not reproduced here).
2. QA: run the APK on an x86_64 emulator with KVM (testing.md); run Windows and macOS exports (not run here).
3. Decided: stock 0.8.2 + G1 for M1; the fork port to godot-cpp 10 and then P1-P3 at lower priority than M1 integration, not gated on import (Karyu: sharing/import deferred). Open: when to schedule the port (estimated ~2 engineer-weeks).
4. Answered (Karyu, relayed): hybrid C++ is approved for **plain bullets, narrow zero-copy view**; the accessor design is section 8.2, the contract section 8.3. Open: P4 patch vs C ABI shim (P4 preferred), and who writes the C++ side (the Gameplay Engineer, after the pool refactor).
5. Karyu: determinism/seeding (OI-2); limited-mode shape.
