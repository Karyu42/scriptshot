# Lua binding evaluation and recommendation

Date of research: 2026-10-30 (revised for v0.2 after the spike). Everything marked *(verified)* was read from
the repo, its release assets or its issue tracker, or **measured in the spike** (see
[spike-results.md](spike-results.md)). Items marked *(not verified)* are inferences or things not yet tested.
**Godot 4.7.2 is decided** (the repo has `project.godot` and CI pins 4.7.2); the spike ran on exactly that version.

## Requirements that drive the choice

1. Godot 4 compatibility on current stable.
2. Fast with thousands of scripted bullets (Lua should only run on events/timers).
3. Exports for Windows, macOS, Linux **and Web**.
4. Healthy maintenance.
5. MIT-compatible license (the project is MIT).
6. Runaway-script protection (instruction-count hook, memory visibility) and library sandboxing.
7. Hot reload.

## Candidates

| | **gilzoide/lua-gdextension** | WeaselGames/godot_luaAPI | Luau bindings (Fumohouse/godot-luau-script, Pimpoli/GodotLuau) | gilzoide/godot-lua-pluginscript | Own thin GDExtension on upstream Lua 5.4 |
|---|---|---|---|---|---|
| Godot 4 | Yes. Minimum **4.5** (`compatibility_minimum = "4.5"`); 0.8.x is built against godot-cpp with `api_version=4.6`. **Loads and runs on Godot 4.7.2** (editor build, official release export template, headless, Linux native, Web threads and no-threads, Android APK built) *(measured)*. Issue #260 (4.5.2 refuses the 4.6-built binary) is irrelevant on 4.7.2. **#255** (LuaTable `bind_method`) is **4.8-dev only**. **#257** (editor SIGSEGV on Linux with 4.7.2/4.8-dev, Arch + Wayland) was **not reproduced** on X11/Mesa llvmpipe in 3 GUI runs, but a related **cold headless import abort (SIGABRT after import, second run clean)** reproduces every time with the addon present; CI must import twice (testing.md section 2.2). *(measured)* | Last build docs target Godot **4.1**; last release v2.1-beta11 (2024-01-24). Not tested by me on any current version. | godot-luau-script: README badge says Godot 4.4; **archived** 2025-11-07. GodotLuau (Pimpoli): 6 stars, pushed 2026-09-26, no releases checked. | **Godot 3 only** (README: "does not work with Godot 4", points to lua-gdextension). | Matches whatever Godot version we build against. |
| Runtime | Lua **5.4.8** *or* **LuaJIT 2.1** as two separate addon zips. No Luau. | Lua 5.4 (and a LuaJIT build) | Luau (Roblox's typed Lua dialect) | LuaJIT FFI | Lua 5.4 (or LuaJIT) as we choose |
| Windows / macOS / Linux | **Yes** in 0.8.2: Windows x86_32/x86_64/arm64 DLLs, Linux x86_32/x86_64/arm64 .so, macOS universal dylib. *(verified by listing the 0.8.2 release zips)* | Releases include Windows/Linux/macOS editor + export templates (2024 and older); GDExtension zip for those platforms. | Not verified | n/a | Yes, but we must build and sign them ourselves |
| **Web** | **Yes, with Lua 5.4** (not LuaJIT): release zip contains `libluagdextension.web.template_{debug,release}.wasm32{,.nothreads}.wasm` (2.65 MB release): **both the threads and no-threads builds shipped in 0.8.2, and the spike loaded and ran both on 4.7.2** in headless Chrome 156 (needs the `web_dlink_*` templates and `variant/extensions_support=true`). LuaJIT has no wasm support. 0.8.2 changelog: "Yielding from coroutines now work in Web builds" (our watchdog relies on yields; verified working on web). *(measured)* | No web build in release assets. | Not verified | n/a | Possible, we compile Lua to wasm with godot-cpp's web target |
| Maintenance | MIT, 475 stars, 30 open issues, repo pushed 2026-09-28. Releases: 0.7.0 (2026-01-28), 0.8.0 (03-30), 0.8.1 (05-17), 0.8.2 (07-12): roughly every 2 months. No release in the ~3.5 months since; `main` has post-release changes (e.g. LuaJIT bump). Single main maintainer. | **Archived**; README: "I do not have the time. If interested in maintaining please start with a fork"; last commit 2024-12-29; 0 open issues because it is archived. | godot-luau-script archived; GodotLuau small and young. | Not archived, last push 2025-03-09; irrelevant (Godot 3). | We own it forever |
| License | **MIT** (LICENSE: "Copyright (C) 2026 Gil Barbosa Reis"). Bundles Lua (MIT) / LuaJIT (MIT). | LICENSE file present ("Copyright (c) 2021-present Trey Moller"), GitHub reports `NOASSERTION`; text was not fully read. | MIT (both) | MIT | MIT (Lua is MIT) |
| Runaway protection | `LuaThread.set_hook(hook, mask, count)` wraps `lua_sethook` and supports count/line/call/return masks (`src/LuaThread.cpp`, `doc_classes/LuaThread.xml`). **No built-in instruction budget or memory *limit*** (there is `get_memory_used()` and GC control only). **Measured:** a raw count hook that raises an error is defeated by `pcall` (error swallowed), is absent on coroutines created inside Lua, and does not run in message handlers or `__gc`; the spike's **host-owned coroutine + yield-from-hook watchdog** closes these (spike-results.md section 11). *(measured)* | Library selection per state; limited hook support not verified | Luau has `interrupt` callbacks natively (design feature of Luau; not verified in these wrappers) | n/a | Full control: `lua_sethook` + custom allocator with a hard memory cap |
| Sandboxing | `LuaState.open_libraries(mask)` lets you open only chosen libraries; `load_string(code, chunkname, env)` takes a custom environment table; per-state Godot-API exposure chosen by the embedder. `GODOT_VARIANT` must be opened for Vector2/packed-array indexing. *(verified, measured)* Capability-to-library mapping: see "Sandbox and capabilities" below. | Designed for sandboxed modding (README) | Luau sandbox is a first-class feature of the VM | n/a | Entirely ours |
| Hot reload | Extension is `reloadable = true`; Lua scripts as Godot scripts have `_reload`. For our use, we control reload of our own `LuaState` (re-`load` the file). | not verified | not verified | n/a | Ours |
| Fit for "thousands of bullets" | **Measured on 4.7.2 (release template):** GDScript->Lua call ~100-125 ns, Lua->Lua 5.7 ns, a packed-array element read from Lua 130 ns / write 67 ns, `Vector2` argument +170 ns. Per-bullet hooks cost ~1.6-2.1 us per bullet, batch hooks ~1.0-1.3 us; 4,000 scripted bullets: A 6.3 ms, B slice 4.1 ms, B 1/4 slice 1.0 ms; 10,000: A 16.2 ms, B 1/4 slice 2.5 ms (spike-results.md sections 4-5). So: **declarative by default, batch with slicing for steering, per-bullet opt-in.** Issue #143's `for` loop numbers (14 ms Lua vs 0.4 ms LuaJIT) are not representative of the boundary-dominated workload. | Same boundary cost | Same | n/a | Can avoid the Variant boundary entirely (pass packed arrays/ints) |

### Sources

- lua-gdextension: <https://github.com/gilzoide/lua-gdextension>, releases <https://github.com/gilzoide/lua-gdextension/releases>, issue #260 <https://github.com/gilzoide/lua-gdextension/issues/260>, #257 <https://github.com/gilzoide/lua-gdextension/issues/257>, #255 <https://github.com/gilzoide/lua-gdextension/issues/255>, #143 (performance) <https://github.com/gilzoide/lua-gdextension/issues/143>, #240 (crash when freeing coroutines) <https://github.com/gilzoide/lua-gdextension/issues/240>, Asset Library <https://godotengine.org/asset-library/asset/4119>
- godot_luaAPI: <https://github.com/WeaselGames/godot_luaAPI> (archived)
- godot-luau-script: <https://github.com/Fumohouse/godot-luau-script> (archived); GodotLuau: <https://github.com/Pimpoli/GodotLuau>
- godot-lua-pluginscript: <https://github.com/gilzoide/godot-lua-pluginscript> (Godot 3)
- Godot 4.6 release notes (JSON GDExtension interface): <https://godotengine.org/releases/4.6/>
- LuaJIT hook behaviour: <https://luajit.org/faq.html>, <https://github.com/LuaJIT/LuaJIT/issues/779>

## Lua 5.4 vs LuaJIT

| | Lua 5.4.8 | LuaJIT 2.1 |
|---|---|---|
| Web | **Works** | **No** (no wasm port) |
| Raw speed | Interpreter | Much faster in hot loops (see #143), but our hot loops are native |
| Instruction hook | `lua_sethook` count hook reliable everywhere | JIT-compiled code **ignores hooks by default**; needs a custom build with `LUAJIT_ENABLE_CHECKHOOK` (unsupported, per LuaJIT's author) or `jit.off()`. The shipped LuaJIT addon is not documented to enable that flag *(not verified)*. |
| Language | `<close>`, integers, goto | 5.1 + 5.2 extras; the addon bundles recent LuaJIT with some 3.0 syntax extensions (`+=`, `??`), not portable Lua |
| Behaviour parity across platforms | Identical on all targets including Web | Web differs from desktop |

**Conclusion: Lua 5.4 on every platform.** One language semantic everywhere, hook-based budgets
work, and the web build exists. Speed is recovered by keeping per-bullet logic native.

## Recommendation

**Use `gilzoide/lua-gdextension` 0.8.2 (the Lua 5.4 build, not LuaJIT) for M1 and the prototype, pinned to the exact release, behind our own thin facade (`ScriptHost`), with the spike's host-owned watchdog ("G1"). Plan to build it from source in the shared native pipeline, with a small pinned patch series (allocator cap, native string limits, async interrupt), before imported/shared scripts ship.** The own-GDExtension option stays the documented fallback.

The spike (Godot 4.7.2) answered the questions this section used to list as risks:

| Risk in the first draft | Result |
|---|---|
| Does it work on 4.7.2? | **Yes** on Linux native, Web threads and no-threads (headless Chrome), Android APK built; one CI hazard (cold import abort) |
| Hook semantics: can a hook abort a callback, do coroutines inherit hooks, cost? | A hook that **raises** is defeated by `pcall`; Lua-created coroutines have **no** hook; message handlers and finalizers run with hooks off. **A host-owned coroutine whose count hook returns `HOOK_YIELD` solves it** (uncatchable); 42 adversarial scripts, 0 hangs; cost ~13% on realistic callbacks at count=1,000 |
| Variant boundary cost | Dominant, ~130 ns per packed-array element: declarative > batch+slice > per-bullet. 4,000 bullets fit ~3 ms with batch slicing |
| Coroutine churn / #240 | Not reproduced in 200,000 Lua-created, 100,000 host-created and 3,000 freed-while-suspended coroutines; stays a regression test |
| Memory cap | **Not enforceable** with the stock binding (overshoot 64 -> 83 MB with 1 MiB chunks; a single native allocation is unbounded without the `string.rep` wrapper) |
| Native-call interruption | Not possible from the hook: bounded by wrappers (rep 1 MiB, pattern subject 1,024: worst case ~4 ms) |

Why this binding:

- It is the only actively maintained Lua binding for Godot 4 that I found (0.8.2 published 2026-07-12, commits through
  2026-09-27), MIT, with binaries for Windows/macOS/Linux/Android/iOS/Web in the release zip.
- It exposes what embedding needs: independent `LuaState`s, library masks, environment tables for `load`, per-thread hooks,
  host-owned `LuaCoroutine`s, GC stats.
- `godot_luaAPI` is archived and tied to Godot 4.1, Luau bindings are archived or immature, `godot-lua-pluginscript` is Godot 3.

Trade-offs and remaining risks:

1. **Godot version coupling.** Pin Godot (4.7.2), the addon (0.8.2) and godot-cpp together; rebuild on every engine bump when built
   from source.
2. **Bus factor of one**, and 0.8.2 is ~3.5 months old. Mitigation: all Lua access goes through `ScriptHost`, so the binding can be
   replaced (Option B) without touching the game or player API; building from source (below) removes the release-cadence
   dependency.
3. **Limits the stock binary cannot close** (measured, spike-results.md section 11): hard memory cap, interruption of a single
   native call, reachability of Lua-wrapper guards through `debug`. The M1 policy: guards as wrappers, `debug` trimmed, hard limits
   documented; for imported scripts these need the patch series.
4. **#257** (editor crash on some Linux setups) is not reproduced here and not closed; the **cold-import SIGABRT** is real and handled in CI.
   The exported game does not run the editor GUI.
5. **Variant boundary cost** drives the architecture (declarative first, then batch, then per-bullet).
6. **Unverified runtime:** Android APK was built but not run (no KVM), iOS/Windows/macOS not run here.

### Build from source in the shared native pipeline (recommended)

The bullet hot loop is moving to a C++ GDExtension on godot-cpp 4.7.2 and QA is building a shared native pipeline. Adding
lua-gdextension as a **pinned submodule + `.patch` series** costs one SCons target per platform and:

- decouples us from the maintainer's release cadence and from godot-cpp `api_version` refusals (#260 class);
- lets us ship P1 allocator cap, P2 native `string.rep`/pattern limits, P3 async `interrupt()`, so hard limits stop being Lua wrappers and
  `debug` can be granted whole (spike-results.md section 12);
- needs the toolchain the rest of the pipeline already needs: **Emscripten 4.0.11** (must match the engine's web template),
  **Android NDK r28b (28.1.13356709), API level >= 24**, SCons 4.10.1, C++20 with exceptions. Web flags `-sSIDE_MODULE=1`,
  `-sUSE_PTHREADS=1` (threads flavour only), `-sWASM_BIGINT`, `-sSUPPORT_LONGJMP='wasm'`, LTO full; Android `--target=<abi>24`,
  `-fPIC`, `-mfpu=neon` (arm32). Full table: spike-results.md section 12.

Use the **stock 0.8.2 release zip** for the prototype and M1 (fetched by `tools/ci/fetch_native_libs.sh`, SHA256-pinned); switch
the script to the pipeline artifact when P1-P3 land.

### Option B (fallback): own GDExtension around upstream Lua 5.4

Small C++ extension using godot-cpp 4.7.2, compiling Lua 5.4.8 statically (plain C, no sol2/tree-sitter). Pros: no Variant boundary
on the hot path (bullet views as light userdata: **estimated** 0.1-0.2 us per bullet-update vs 1.0-1.3 us measured), hard
memory cap through a custom allocator, async interrupt, no dependency on one maintainer. Cons: we own builds for all
platforms, signing/notarisation, and godot-cpp bumps. **Estimate (not measured): ~4-6 engineer-weeks to parity**, plus 2-3 days
of per-platform build work that the shared pipeline mostly covers. Choose it if #257 turns out to hit the exported game, an
upstream break cannot be patched, or the Variant boundary proves too slow even with batching. `ScriptHost` is the only class
that changes.

### Spike (done)

Items 1-6 of the first draft's plan were executed on Godot 4.7.2: benchmarks, hook tests, web export (both flavours), coroutine
churn, and more (hook-granularity A/B/C at 1,000-10,000 bullets, events, hit-spam, `fire()`, Android APK, adversarial B4 suite).
Results, exact versions and raw output: [spike-results.md](spike-results.md) and [`spike/`](spike/). **Hot reload** (re-`load`
into a live state) was not benchmarked; it is covered by the design below and a test in testing.md.

## Proposed architecture (high level)

```
Player scripts (.lua)            Godot / native side
┌──────────────────┐   events   ┌─────────────────────────────────────────┐
│ weapon table     │◄───────────│ ScriptHost (our facade over the binding)│
│  on_fire         │            │  - one LuaState per weapon (sandboxed)  │
│  on_hit / timers │───commands►│  - callback queue + budgets + hooks     │
└──────────────────┘            └──────────────┬──────────────────────────┘
                                               │ ids, batched commands
                                ┌──────────────▼──────────────────────────┐
                                │ BulletSystem (Gameplay Engineer)        │
                                │  struct-of-arrays pool, native motion,  │
                                │  collision, rendering (MultiMesh)       │
                                └─────────────────────────────────────────┘
```

### 1. How scripts attach to shots

- A weapon script is loaded into its own `LuaState` (not shared across weapons) with a sandbox
  environment built from the script's **capabilities** (next section): own scripts get full Lua (opt-in `needs` for `io`/`os`/`debug`/
  `package`/`native`); imported scripts get none of those unless the player grants them. `dofile`, `loadfile`, binary chunks and
  `string.dump` are removed in every mode; `load` is text-only.
- `spawn{...}` from Lua builds a *spawn command* (numbers and callback references). It is executed
  natively; the bullet gets a compact **behavior record**: native motion params (speed, accel,
  spin, homing config, bounce, pierce, lifetime) and a **script slot**.
- A script slot is `(weapon_id, callbacks_mask, state_ref, timer_list)`. Callbacks are not copied
  per bullet; bullets of the same `spawn` definition share one callbacks table. Bullets with no
  callbacks have script slot = 0 and **never touch Lua after spawn**.
- Handles given to Lua are `(index, generation)` pairs (stable ids), so stale handles are detected without
  holding engine objects. Position jumps from Lua map to `BulletPool.teleport(i, p)`, never raw `pos` writes (swept
  collision would see a phantom hit).

### 2. Batched, pooled bullets

- Native side keeps struct-of-arrays pools (position, velocity, age, flags, ...) and updates
  movement, homing and collision in tight loops. This is the Gameplay Engineer's domain; the
  scripting layer only needs: spawn/kill by ID, read/write a few fields, and event emission.
- **Lua is entered only for events and timers**: `on_spawn`, `on_hit`, `on_wall`, `on_expire`,
  `on_death`, `every`/`after`, and (rarely) `on_tick`. Timers live in a native min-heap keyed by
  game time; the heap pops due timers, grouped per weapon, and enqueues them.
- **Event queue, then one Lua pass per tick.** During physics the native side only appends events
  to a ring buffer (`bullet_id, event, target_id`, stable ids). After physics, `ScriptHost` drains it
  oldest first, up to a per-behavior cap (256/tick), with the budget applied; the remainder is **deferred**,
  never silently dropped. This avoids re-entrancy (spawning from inside collision). Batched events are *not* faster than
  per-bullet event calls (measured, 25-90% slower); the queue is for determinism, caps and budgets.
  Hit order is fixed by the engine: `receive_hit` -> `on_hit` -> pierce-- or `mark_dead(HIT)`; `on_hit` is a notification, `can_hit` vetoes beforehand.
- **Boundary crossings are per element, not per call.** Measured: a call costs ~100 ns, but each packed-array element read from
  Lua costs ~130 ns (write ~67 ns) and a `ShotRequest` field write ~130 ns. Batching therefore does **not** reduce crossings by
  itself: reads must be bulk-copied to flat float32 arrays on the GDScript side and effects collected in a **command buffer**
  (stride 6) applied after the call; that makes B 25-40% cheaper than per-bullet hooks, not 10x. The real wins are **declarative
  fields (zero Lua), slicing, native throttling, and one budget scope per batch** (spike-results.md sections 5 and 8). Reads such
  as `b.pos` in per-bullet callbacks use a lazy proxy that reads once per field per tick.
- **Pooling**: bullet slots are recycled (swap-remove: slots are valid only inside one hook call; Lua holds stable ids `(generation << 32) | handle`); Lua-side per-shot `state` tables come from a free list
  and are cleared on death; callback tables are shared; coroutines for `run`/`wait` come from a
  pool (limits coroutine churn, relates to issue #240).
- **Caps**: live bullets, spawns per tick and generation depth are enforced in the native spawn
  path, so a runaway script cannot allocate unbounded pool memory.

### 3. Error isolation and runaway protection (as measured)

- **Every callback runs in a host-owned `LuaCoroutine`** (pooled), with a **GDScript Callable count hook** (count 1,000) that checks
  the instruction budget, the wall clock (300 ms in the spike), the memory estimate (64 MB) and the `os.exit` flag. On a verdict
  it returns `HOOK_YIELD`; the host sees the coroutine suspended with a reason and drops it. **A yield is not an error, so
  `pcall`, `xpcall`, `__close` and error handlers cannot swallow it.** The facade shows the script only validated, native Callables.
  Never line hooks.
- After a verdict the host **re-arms every registered thread with count = 1**, so the first instruction outside a C-call boundary
  (for example a `table.sort` comparator under `pcall`) yields. Without this a boundary case still hangs (verified).
- Hooks are not inherited by coroutines created inside Lua: the sandbox `coroutine.create/wrap/resume` wrappers **register
  every child thread** and propagate the dead flag.
- Lua runs **message handlers (`xpcall`) and `__gc` finalizers with hooks off**: the sandbox `xpcall` calls a trivial handler and then the
  script's handler in normal context; `setmetatable`/`debug.setmetatable` refuse `__gc`; `collectgarbage` allows only `collect`, `count`, `step`.
- `debug`, when granted, is a trimmed copy: `sethook`/`gethook` are no-ops; `getupvalue`, `setupvalue`, `upvalueid`, `upvaluejoin`,
  `getlocal`, `setlocal` and `getregistry` are removed so the Lua-wrapper guards cannot be reached; `package.loaded` is a fresh view.
  (With the source-built binding the limits live in C and `debug` can be offered whole.)
- **Native calls are not interruptible**: `string.rep` results are limited to 1 MiB and pattern-matching subjects to 1,024
  characters in the sandbox wrappers (worst case ~4 ms); the P2 patch moves that into C.
- **Policy** is the one in `api.md`: callback abort is counted; **3 consecutive timeouts suspend the weapon**; errors never
  crash the host. Per-frame budget: a Lua time slice (default 3 ms); when exhausted, remaining batch work is **sliced round-robin
  to the next tick** and queued events are **deferred** (bounded queue; coalesced into counted summaries only above the hard bound;
  never silently dropped).
- **Memory**: the 64 MB cap is **adopted**. With the stock binding it is checked every 1,000 instructions (measured overshoot
  64 -> 83 MB with 1 MiB chunks); with the P1 allocator cap it is a hard Lua "not enough memory" error inside the script.
- Never trust player Lua with engine objects; only ids and plain data cross the boundary.

### Sandbox and capabilities

Capability -> libraries, most dangerous first (api.md has the player-facing labels and the import UX):

| Capability | Adds | Notes |
|---|---|---|
| (always) | base (minus `dofile`, `loadfile`, `string.dump`), `table`, `string` (bounded), `math`, `utf8`, `coroutine` (wrapped), `os.time`, `os.clock`, `GODOT_VARIANT`, the facade | `load` is text-only; `os.exit` never exists in this set |
| `native` | `package.loadlib`, `package.cpath`, C searchers 3 and 4 | "Load native code. Can do anything to your computer." |
| `os` | `os.execute`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, `os.exit` (replaced: stops the script, never the game), **`io.popen`** | "Run programs and change your system." |
| `io` | `io.*` except `io.popen` | "Read and write files." |
| `debug` | trimmed `debug` (see above) | "Inspect and change Lua internals." |
| `package` | `require`, Lua searchers 1 and 2 | "Load Lua modules from disk." |
| `net` | reserved | |

Measured in the capability-matrix tests: `io.popen` is present only with `os`; `package.loaded` never exposes `debug` or `io` unless granted; searchers 3
and 4 exist only with `native`.

### 4. Hot reload

- A file watcher (editor / `FileAccess.get_modified_time`) triggers load of the new chunk into a
  **fresh** `LuaState`; on success swap the weapon's active state, on failure keep the old one and
  show the error.
- In-flight bullets keep a reference to the **old state** and callbacks until they die (default);
  the old state is freed when its bullet count reaches zero. Optional `reload = "migrate"`:
  bullets switch to the new callbacks by name and keep `state` tables (copied into the new state).
- Weapon-level `state` is copied across by key when the new script declares it.

### 5. Build and distribution

- The addon lives in `addons/lua-gdextension/`, **git-ignored**; `tools/ci/fetch_native_libs.sh` downloads the pinned release and
  verifies its SHA256 (binaries are never committed; testing.md section 2.1). CI imports the project twice (cold-import abort).
- Web export: Lua 5.4 addon, "Extensions Support" on, the `web_dlink_*` templates; **both threaded and non-threaded web builds were
  exported and run on 4.7.2** *(measured)*. Android: the arm64/x86_64 `.so` files ship in the APK *(built; not run)*.

## Open questions

Answered since the first draft: **Godot version** = 4.7.2 (decided); **spike** = done (spike-results.md); **web** = a release target and works;
**hard memory cap / strict sandbox** = required for imported scripts, not for own scripts (capability model in `api.md`).

Still open:

- Stock 0.8.2 + wrappers for M1, source-built P1-P3 before imported scripts ship: agreed? (Karyu / Chief of Staff)
- Gameplay Engineer: will the C++ hot loop expose bullet views to Lua directly (custom binding) or keep GDScript pools? That decides
  whether per-bullet cost stays ~1 us or drops ~10x (spike-results.md section 8).
- Run the GUI editor on real Wayland Linux, Windows and macOS (#257), and the APK on a device or a KVM CI runner.
- Determinism and seeding (api.md OI-2); the limited mode for imported scripts.
- Engine interface additions (api.md OI-14..19; spike-results.md section 8): batch API, stable id column, `teleport`, wall normal, `can_hit`.
