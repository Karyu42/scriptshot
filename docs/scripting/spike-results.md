# lua-gdextension spike results (Godot 4.7.2)

Status: **measured, local, throwaway project** (`/workspace/scriptshot-spike`, not in this repo; the raw output
files and the sources of every benchmark are in [`spike/`](spike/)). Nothing here touches the game repo.
Written by the Scripting Engineer for PR #3. Numbers are **medians (p95 where stated)** over repeated runs;
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
| Problems / crashes | No crashes in error isolation, coroutine churn (#240 not reproduced), or 42 adversarial scripts. Found and fixed in the guard design: pcall swallows budget errors; coroutines created in Lua have no hook; **xpcall message handlers and `__gc` finalizers run with hooks off** (hang); native pattern matching and big allocations are not interruptible; **cold headless import aborts (SIGABRT) with the addon present**. |
| Binding choice | **Unchanged for the prototype** (stock lua-gdextension 0.8.2 behind `ScriptHost`); **revised for the long run**: build it from source in the shared native pipeline with a small patch set (allocator cap, native string limits, async interrupt), section 12. |

## 2. Environment

| | |
|---|---|
| Godot | `4.7.2.stable.official.ed1daf0bf`, Linux x86_64, headless; also its official **release export template** (`linux_release.x86_64`) for all "release" numbers |
| Addon | `gilzoide/lua-gdextension` **0.8.2**, Lua **5.4.8** runtime (changelog: "Updated Lua to 5.4.8"), MIT, `lua_runtime=lua` (not LuaJIT) |
| Web | Google Chrome 156.0.8078.47 headless via Playwright 1.64.1, SwiftShader (software GL), `crossOriginIsolated = true`, Godot 4.7.2 `web_dlink_*` templates |
| Android | SDK build-tools 35.0.1, platform android-35, JDK 17.0.21, debug keystore, prebuilt `android_debug.apk` template |
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
- **New finding, same class (cold import):** `godot --headless --path <project> --import` (also `--editor --quit`) on a project
  that **contains the addon and has no `.godot/` cache aborts with SIGABRT (exit 134)** at shutdown, after the import has
  finished (log ends at `EditorSettings: Save OK!`). Reproduced on every cold run (more than five) on a blank project + addon (plugin enabled
  or not); the identical project **without** the addon exits 0; **the second (warm) run exits 0**. It does not depend on the
  doc cache. No backtrace (no gdb on the box; Godot's handler printed none). **CI consequence:** run the import twice and
  tolerate the first exit code (`godot --headless --import || true; godot --headless --import`), and treat the *second*
  run as the gate. Reported upstream-worthy; I did not file an issue (no posting without approval).

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

Harness: the pool, `BulletManager.step` order and `BulletBehavior` shapes from PR #2 (head `2026abe`), render off, 32
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
   0.1-0.2 us per bullet (not measured), i.e. 10,000 batch updates in 1-2 ms. That needs the own/source-built binding (section 12).

### Proposed interface diff (what changes in `architecture.md`'s `BulletBehavior` and the pool)

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
var id: PackedInt64Array              # stable-id column (or computed id_of)
func behavior_range(behavior_id: int) -> Vector2i        # needs bucketing/sorting by behavior_id (the GE already plans it)
func gather_vec2(indices: PackedInt32Array, src: PackedVector2Array) -> PackedFloat32Array   # bulk read
func apply_vel(indices: PackedInt32Array, v: PackedFloat32Array) -> void                    # bulk write
func teleport(index: int, position: Vector2) -> void     # PR #2 (coming): sets pos AND prev_pos

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
Callable and a freed Node object; the main loop kept ticking. Churn: 200,000 Lua-side coroutine creates, 100,000 GDScript-side
`LuaCoroutine` create/drop, 3,000 per-frame hooked coroutines freed while suspended, 200 state re-creations: no crash, memory back
to baseline (0.1-0.3 MB). **Issue #240 was not reproduced** with these patterns (it stays a regression test).

## 10. Export proof (platforms: Windows, macOS, Linux, web, mobile)

Each build runs a 1,000-bullet scene with Lua steering (rendering on) in four phases (C, A, B, B + the guard hook) and prints
the Lua time. `frame_ms` is capped by vsync at ~16.7 ms; the **Lua ms** is the meaningful column.

| Target | Run | C step | A: Lua ms (hooked) | B: Lua ms | B + guard hook: Lua ms | fps |
|---|---|---|---|---|---|---|
| **Linux** native, release template | exported binary | 0.57 ms | 1.70 | 1.15 | 1.46 | 145 |
| **Web, threads** (`web_dlink_threads`, `extensions_support=true`) in headless Chrome 156, `crossOriginIsolated = true` | Playwright | 1.32 ms | 4.32 | 1.61 | 1.91 | 58-60 |
| **Web, no threads** (`web_dlink_nothreads`) | Playwright | 1.01 ms | 2.76 | 1.48 | 1.92 | 60 |
| **Android** (arm64-v8a + x86_64, non-gradle, signed APK 67.6 MB) | built, **not run** (no emulator) | | | | | |

- Web: both extension builds load on 4.7.2 and run the same script; WebAssembly costs about **1.3-2.5x** the native Lua time in
  this run (software GL on the same CPU; the numbers include noise from a shared box). The extension wasm is 2.65 MB; the
  Godot side `index.side.wasm` is 44 MB. The lib file must sit next to `index.html`.
- **Android:** the APK builds and signs (v2/v3) with `lib/arm64-v8a/libluagdextension.android.template_debug.arm64.so` (5.4 MB),
  the x86_64 variant, `libgodot_android.so`, the `.gdextension` and `scripts/steer.lua` inside. **Emulator: not possible
  here.** `/dev/kvm` is `crw-rw---- root:pulse-access` and the box user is not in that group; `emulator -accel-check`
  reports no access. A `-no-accel` boot of the x86_64 android-34 image is possible but would take many minutes per boot,
  and it would only prove that the `.so` loads, not performance; I did not run it. **On a real device** (or a KVM-enabled
  CI runner) the proof is: `adb install spike.apk`, `adb logcat -s godot | grep SPIKE_`, which prints the same
  `SPIKE_RESULT` lines. This is the one export claim that stays **unverified at runtime**.
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
| 28 | `dofile`, `loadfile`, `string.dump` are nil | not run | completes, 0 ms |
| 29 | `debug.getupvalue/setupvalue/getregistry/getlocal` with `debug` granted | not run | completes: `getupvalue`, `setupvalue`, `getregistry` are `nil`; `sethook` is a no-op stub |
| 30 | `debug.getlocal` on a wrapper frame | not run | completes: no `getlocal`, nothing leaked |
| 31 | capabilities: none | not run | completes: `io`/`debug`/`package`/`require` nil, `os.time`/`os.clock` present, `os.execute` nil |
| 32 | capabilities: `io` | not run | `io.open` yes, **`io.popen` nil**, `os.execute` nil |
| 33 | capabilities: `os` | not run | `os.execute`, `os.getenv`, **`io.popen`** yes; `io.open` nil |
| 34 | capabilities: `package` | not run | `require` yes, `loadlib` nil, 2 searchers, `debug`/`io` not in `package.loaded` |
| 35 | capabilities: `native` | not run | `loadlib` yes, 4 searchers |
| 36 | `xpcall(table.sort, spinning_handler, t, spinning_comparator)` loop | not run | stopped: instruction budget, 126 ms |
| 37 | `load(function() while true do end end)` (reader function) | not run | error: load: only string chunks are supported, 0 ms |
| 38 | `xpcall` return values preserved | not run | completes: `false handled:boom`, `3 3` |
| 39 | `os.exit(0)` (with `os` granted) | **HUNG** (killed at 25 s) | stopped: os.exit requested, 0 ms |
| 40 | `os.exit` from inside a coroutine | **HUNG** (killed at 25 s) | stopped: os.exit requested, 0 ms |
| 41 | `rawset(_G, "spawn", nil)`, overwrite `_G.set_player_hp`, remove `print` | n/a (no guard / no facade in the naive harness) | completes, 0 ms |
| 42 | `spawn(NaN, inf, -inf, 1e308, ...)`, `spawn("a", {}, nil)`, `set_player_hp(NaN / inf)` | n/a (no guard / no facade in the naive harness) | completes; facade clamps to `[0, 1e7, -1e7, 1e7, 0]`, rejects strings/tables, ignores NaN, clamps hp |

**Totals:** naive design, 23 cases run: **10 hang or kill the game** (cases 2, 5-11, 39, 40), 13 survive, none of them with the attack stopped by anything but the engine's own limits; **G1: 0 hangs, 0 crashes, 0 host failures in 42 cases** (`host_ok=true heartbeat=ok` after each; a fresh `LuaState` works). "Naive" = Lua-function count hook on the main thread, full libraries, no wrappers; tests added later were not run against it (shown as "not run").

(Raw lines: `spike/results/adv_g1.txt` and `adv_naive.txt`.) Found-and-fixed by running this suite against earlier versions of G1: **`debug.getupvalue` reaching the real `string.rep`/`string.match` (cases 15 and 21; 256 MB / 819 ms and 2.1 s)**, **`xpcall` message handlers running with hooks off (case 25: hang)**, **`__gc` finalizers running with hooks off (cases 23-24)**, and the `table.sort` boundary re-arm (case 11).

### What G1 proves, and what stock lua-gdextension cannot do

Proven on 4.7.2: a **host-owned yield watchdog** survives `pcall`, `xpcall`, `__close`, error handlers, `table.sort` comparators,
child coroutines, `load`, `debug.sethook`, and `os.exit`; the facade is native; capabilities map to concrete library sets; the
granted `debug` cannot reach the guards. Cost of the guard: ~13% on realistic callbacks (section 9), one `LuaCoroutine` per
callback (pooled).

**Residual holes, i.e. what the stock binary cannot close** (need the source-built binding, section 12):

1. **Single huge native allocation or a native call that never returns to the VM** (pattern matching, `table.concat`,
   `string.rep` family, `table.sort` on a huge table): the hook only runs between VM instructions. Mitigated by per-call limits
   (1 MiB `rep`, 1,024-char pattern subjects), which are Lua wrappers.
2. **No hard memory cap**: the check runs every 1,000 instructions; measured overshoot 64 -> 83 MB with 1 MiB allocations, larger if
   limits are raised. A `lua_Alloc` that returns `NULL` past the cap is the fix; the binding creates states with the default
   allocator (`sol::state`) and exposes no hook for it.
3. **No cross-thread watchdog**: `LuaThread.set_hook` writes the Lua registry and is not safe from another Godot thread, so
   nothing can interrupt a native call from outside. (`lua_sethook` itself may be called from another thread; the binding's
   registry write is the problem.)
4. **The guards that are Lua wrappers are reachable by `debug`** unless `debug` is trimmed (done in G1); native limits cannot be
   reached.

**Does B4 change the binding choice?** For the **prototype / M1: no.** Stock 0.8.2 + G1 stops every attack above except the
residual native-call and allocation cases, and those are bounded to ~4 ms and ~100 MB. For **imported/shared scripts being
hard-sandboxed** (PR #1 section 7) **yes**: items 1-3 are real, and PR #1 explicitly promises "allocation beyond the cap raises
a Lua error inside the script". That needs the Lua C library under our control: see the next section.

## 12. Build from source in the shared native pipeline? Versions and flags

The Gameplay Engineer is moving the bullet hot loop to a C++ GDExtension on **godot-cpp 4.7.2** and QA is building one shared
native pipeline. Everything lua-gdextension needs is the same toolchain (SCons + godot-cpp), so the question is only what to
pin and whether to patch.

**Toolchain lua-gdextension 0.8.2 is built with** (read from its `build.yml` and from the godot-cpp submodule it pins, `godot-cpp@58d1de7`; I did **not** run a source build on this box):

| | Value |
|---|---|
| Build tool | SCons **4.10.1** (`SCONS_VERSION` in its CI); godot-cpp's own default is 4.4.0 |
| **Emscripten (web)** | **4.0.11** (godot-cpp `setup-godot-cpp` action default `em-version: 4.0.11`). **Must match the Emscripten the engine's `web_dlink_*` template was built with** (check Godot's 4.7 web-export docs on every engine bump; the side module and the main module need a compatible Emscripten ABI) |
| **Android NDK** | **r28b (28.1.13356709)** (godot-cpp action default `ndk-version: r28b`; Godot 4.7 docs: "NDK version r28b (28.1.13356709)", build-tools 35.0.1, platform 35, CMake 3.10.2.4988404, JDK 17). Minimum Android API level **24** (godot-cpp forces `android_api_level >= 24`) |
| Windows | MSVC (upstream CI: Visual Studio 18 Enterprise `vcvarsall.bat`); x86_64, x86_32, arm64; godot-cpp's default is MinGW 12.2.0 |
| Linux | Ubuntu 22.04 runners (glibc floor), `g++-multilib` for x86_32, `ubuntu-24.04-arm` for arm64 |
| macOS | `macos-latest`, `universal` arch; iOS `universal` |
| C++ | **C++20**, **exceptions enabled** (`-fno-exceptions` removed), `-s` (strip) removed so `luagdextension_entrypoint` stays exported |

**Command lines** (upstream CI):

```
scons platform=linux   arch=x86_64 target=template_release lua_runtime=lua
scons platform=windows arch=x86_64 target=template_release lua_runtime=lua    # vcvarsall_path=... for MSVC
scons platform=macos   arch=universal target=template_release lua_runtime=lua
scons platform=android arch=arm64  target=template_release lua_runtime=lua    # ANDROID_HOME/NDK r28b; also arm32 x86_32 x86_64
scons platform=web     arch=wasm32 target=template_release threads=true  lua_runtime=lua
scons platform=web     arch=wasm32 target=template_release threads=false lua_runtime=lua
```

**Flags the web build gets from godot-cpp** (`tools/web.py`): `-sSIDE_MODULE=1`, `-sUSE_PTHREADS=1` (threads only), `-sWASM_BIGINT`,
`-sSUPPORT_LONGJMP='wasm'`, LTO `full`; defines `WEB_ENABLED UNIX_ENABLED`; `emcc/em++/emar/emranlib`. **Android** (`tools/android.py`):
`--target=<abi><api>` (`armv7a-linux-androideabi`, `aarch64-linux-android`, `i686-linux-android`, `x86_64-linux-android`),
`-march=...`, `-fPIC`, `-mfpu=neon` (arm32), `-mstackrealign` (x86_32). **Lua** itself is built from the `lua` submodule
(`6e22fed`, 5.4.8) with `sol2` (`ab874eb`) as the C++ glue and `tree-sitter` (`0bb43f7`) for the editor's parser. Godot-side
export requires `variant/extensions_support=true` on web and the **dlink** templates (threads true or false);

### Recommendation: yes, build it from source in the shared pipeline, pinned, with a small patch series

Because the pipeline already builds godot-cpp 4.7.2 for six platforms, adding lua-gdextension as a **pinned git submodule at the
0.8.2 commit** costs one more SCons target per platform and removes (a) dependence on one maintainer's release cadence (0.8.2 was published 2026-07-12), (b) the "ship binaries from a zip" step, (c) the Godot-version coupling (#260-type refusals: rebuild against our
godot-cpp). The patches that our watchdog and PR #1's promises need:

| Patch | What | Size (estimate, not measured) |
|---|---|---|
| **P1 allocator cap** | create states with `lua_newstate(alloc, ud)`; `alloc` returns `NULL` past the cap and counts bytes (`LuaState.set_memory_limit(bytes)`, `get_memory_limit()`); the cap becomes a real Lua "not enough memory" error inside the script | ~60-100 lines in `LuaState.cpp/.hpp` + test |
| **P2 native string limits** | `string.rep` result limit and a pattern-matching step/deadline counter in `lstrlib.c` (`MAXCCALLS`-style `ms->matchdepth` plus a step budget), configured per state | ~80 lines of Lua source patch, kept as a `.patch` file |
| **P3 async interrupt** | `LuaState.interrupt()` that calls `lua_sethook(L, flag_hook, LUA_MASKCOUNT, 1)` from any thread (documented as safe to call asynchronously) without touching the registry; makes a wall-clock watchdog thread possible for the instruction-level cases and, with P2, for native loops | ~40 lines |
| **P4 hook-safe finalizers** (optional) | run `__gc` with the hook enabled, or drop it | small; the sandbox already refuses `__gc` |

With P1-P2 the "Known limits that stock lua-gdextension cannot close" in api.md disappear and `debug` can be offered whole
(the guards no longer live in Lua). **Effort (labelled estimate, not measured):** submodule + SCons target per platform into the
shared pipeline ~0.5-1 day; patches P1-P3 with tests ~2-3 days; ongoing cost one rebase per upstream release.

### Fallback: our own thin GDExtension (if lua-gdextension must be dropped)

Triggers: an upstream break we cannot patch (e.g. #257 turns out to hit the exported game), the Variant boundary proves too
slow even with batching, or PR #1's hard sandbox needs more than P1-P3. Shape: godot-cpp 4.7.2 + Lua 5.4.8 compiled statically
(plain C, no sol2, no tree-sitter), `ScriptHost` native class owning states, the watchdog, the allocator cap and a **native bullet
facade** (light-userdata bullet views: no Variant on the hot path: estimated 0.1-0.2 us per bullet-update), `LuaFunction`-style
helpers only where we need them. **Estimate (not measured):** ~4-6 weeks for one engineer to parity with what the game uses
(states, load with env, call, coroutines, hooks, packed-array views, errors, GUT tests), plus per-platform build work already
covered by the shared pipeline (the six platform builds are the same SCons/CMake matrix the engine side already needs; extra
work is mostly web/threads and Android ABI checks, ~2-3 days), plus signing/notarisation which is already needed for the game.
Costs we would own: the Variant glue (`Vector2`, packed arrays, Callables), editor syntax highlighting (not needed), upstream
bug-fixes.

## 13. What this means for the API design (summary; details in api.md)

- **Per-frame logic** is three grades (C / B `on_batch` / A `on_tick`), A and B throttle natively; 3 ms Lua = ~3,000 batch updates
  or ~1,900 per-bullet calls per tick; 5,000 bullets need slicing or 10-50% scripted per tick; 10,000 need slicing.
- **Events** are queued, capped per tick for dispatch, deferred, coalesced only above a hard bound, never silently dropped.
- **`fire()`**: provide `request_polar`/`request_batch`; building a `ShotRequest` from Lua is 3x slower than GDScript.
- **Sandbox**: capabilities select library sets (`needs`); guards are host-owned (yield watchdog), not Lua-visible; `debug` is
  trimmed in the stock binding and whole in the source-built one; `xpcall`, `__gc`, `load`, `string.dump` are specially handled;
  `os.exit` never exits.
- **Memory cap** (64 MB) is adopted as a requirement; soft with stock, hard with P1.
- **Export:** stock 0.8.2 covers Windows/macOS/Linux/web (threads and no-threads)/Android binaries; web and Linux were run; Android
  was built but not run; iOS is shipped but unbuilt/untested here.

## 14. Open questions

1. Run the GUI editor on a real Wayland Linux and on Windows/macOS with the addon (#257 is not reproduced here).
2. Run the APK on a device or a KVM-enabled runner; run Windows and macOS exports (not run here).
3. Decide: stock 0.8.2 for M1 with G1, source-built (P1-P3) before importing/sharing scripts ships.
4. Does the Gameplay Engineer's C++ hot loop expose bullet views to Lua directly (custom binding), or keep GDScript pools? That
   decides whether B stays at ~1.0-1.3 us or drops by ~10x.
5. Karyu: determinism/seeding (OI-2); limited-mode shape.
