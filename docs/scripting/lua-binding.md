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
| Godot 4 | Yes. Minimum **4.5** (`compatibility_minimum = "4.5"`); 0.8.x is built against godot-cpp with `api_version=4.6`. **Loads and runs on Godot 4.7.2** (editor build, official release export template, headless, Linux native, Web threads and no-threads in headless Chromium with software GL only, Android APK built, not run) *(measured)*. Issue #260 (4.5.2 refuses the 4.6-built binary) is irrelevant on 4.7.2. **#255** (LuaTable `bind_method`) is **4.8-dev only**. **#257** (editor SIGSEGV on Linux with 4.7.2/4.8-dev, Arch + Wayland) was **not reproduced** on X11/Mesa llvmpipe in 3 GUI runs, but a related **cold headless import abort (SIGABRT after import, second run clean)** reproduces every time with the addon present; CI must import twice (testing.md section 2.2). *(measured)* | Last build docs target Godot **4.1**; last release v2.1-beta11 (2024-01-24). Not tested by me on any current version. | godot-luau-script: README badge says Godot 4.4; **archived** 2025-11-07. GodotLuau (Pimpoli): 6 stars, pushed 2026-09-26, no releases checked. | **Godot 3 only** (README: "does not work with Godot 4", points to lua-gdextension). | Matches whatever Godot version we build against. |
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

**Use `gilzoide/lua-gdextension` 0.8.2 (the Lua 5.4 build, not LuaJIT) for M1 and the prototype, as the stock release binaries pinned by SHA256, behind our own thin facade (`ScriptHost`), with the spike's host-owned watchdog ("G1").** A source build is **not** free: 0.8.2 pins godot-cpp `58d1de7` (10.0.0-rc1, 4.6 API) and **does not build unmodified against godot-cpp 10.0.0-stable (`507ed9d`)** *(measured, confirms QA's finding)*; building from source, and with it the patch series (P1 allocator cap, P2 native string limits, P3 async interrupt, and P4 native batch view when the C++ pool lands), means **porting lua-gdextension to godot-cpp 10 in a fork** (see *Source build and the fork* below). That work is **crash-safety and performance hardening on the roadmap, at lower priority than M1 integration, and is not gated on in-game sharing/import (deferred by Karyu).** The zero-copy native view (P4) depends on the fork, so the accessor is designed for packed copies on stock 0.8.2 first (spike-results.md section 8). The own-GDExtension option stays the documented fallback.

The spike (Godot 4.7.2) answered the questions this section used to list as risks:

| Risk in the first draft | Result |
|---|---|
| Does it work on 4.7.2? | **Yes** on Linux native, Web threads and no-threads (**headless Chromium with software GL only; Safari and Firefox untested**), Android APK built (not run); one CI hazard (cold-import abort on a blank project, below) |
| Hook semantics: can a hook abort a callback, do coroutines inherit hooks, cost? | A hook that **raises** is defeated by `pcall`; Lua-created coroutines have **no** hook; message handlers and finalizers run with hooks off. **A host-owned coroutine whose count hook returns `HOOK_YIELD` solves it** (uncatchable); 47 adversarial scripts, 0 hangs; cost ~13% on realistic callbacks at count=1,000 |
| Variant boundary cost | Dominant, ~130 ns per packed-array element: declarative > batch+slice > per-bullet. 4,000 bullets fit ~3 ms with batch slicing |
| Coroutine churn / #240 | Not reproduced in about 303,000 coroutine creates (200,000 Lua-created, 100,000 host-created, 3,000 freed while suspended; output committed as `spike/results/hook_editor.txt`); stays a regression test |
| Memory cap | **Soft on stock** (hard only with the P1 patch on a source build): overshoot 64 -> 83 MB with 1 MiB chunks; a single native allocation is unbounded without the `string.rep` wrapper |
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
   documented; the patch series (P1-P3) closes them later, as crash-safety hardening, not as a gate for shipping M1. The patches need
   the fork described below, so they are lower priority than M1 integration.
4. **#257** (editor crash on some Linux setups) is not reproduced here and not closed. The separate **cold-import abort (exit 134)**
   reproduces **only on a blank project plus the addon** (3/3 on a pristine project, also with a source-built library); QA's runs
   of the real Scriptshot `main` with GUT pass 4/4 cold imports. It is a **SIGSEGV null dereference (`si_addr=0x28`) inside the
   stripped Godot editor binary after `loading_editor_layout`**, with no frame in `libluagdextension`; `reloadable = false` does not help;
   **pre-seeding `.godot/extension_list.cfg` with `res://addons/lua-gdextension/luagdextension.gdextension` avoids it (3/3)**.
   CI is unchanged for now; see spike-results.md section 3 and testing.md for the fallbacks. The exported game does not run the editor GUI.
5. **Variant boundary cost** drives the architecture (declarative first, then batch, then per-bullet).
6. **Unverified runtime:** Android APK was built but not run (no KVM), iOS/Windows/macOS not run here.

### Source build and the fork (later, behind M1)

**Pins (from the Godot 4.7.2-stable tree, verified by QA).** Android NDK **29.0.14206865** (clang 21; not r28b), API level >= 24,
Android build-tools **36.1.0**, JDK 17, SCons **4.10.1**, C++20 with exceptions. Web: **Emscripten 4.0.20** for the official
4.7.2 template (4.0.11 is only the engine's own CI `EM_VERSION`; the stock 0.8.2 wasm, built upstream by a godot-cpp action whose
default is 4.0.11, loaded and ran on the 4.0.20 template in the spike, but our own builds pin 4.0.20). godot-cpp **`507ed9d`
(10.0.0-stable, 2026-09-15)**, with `api_version=4.7` for Scriptshot's own extension (its `extension_api-4-7.json` matches
the dump of the 4.7.2 editor). **`58d1de7` is godot-cpp 10.0.0-rc1 with the 4.6 API; it is never "godot-cpp 4.7.2"**.

**Two godot-cpp submodules, kept separate.** Scriptshot's own native extension (the C++ bullet pool) pins godot-cpp `507ed9d` with
`api_version=4.7`. lua-gdextension carries its own `lib/godot-cpp`; stock 0.8.2 pins `58d1de7`. A fork would either keep that
private submodule (a second godot-cpp in the tree, separately SCons-built, its own `api_version`) or be ported to `507ed9d`. They
must not be merged into one submodule without that port, because the two extensions are separate shared libraries anyway.

**Result of building 0.8.2 against `507ed9d` on Linux x86_64 (measured; web not attempted: no emcc on the box).**

| Step | Result |
|---|---|
| Unmodified (`scons ... lua_runtime=lua`) | **Fails.** godot-cpp 10 requires an explicit `api_version`; the code generators read `extension_api.json`, which no longer exists (godot-cpp 10 ships `extension_api-4-X.json`); and 8 headers use `Ref<>` without including `ref.hpp` (godot-cpp 10 no longer pulls it in from `ref_counted.hpp`: "field has incomplete type `Ref<...>`", 49 error sites). |
| With the patch set below, `api_version=4.6` | **Builds** (Linux x86_64 release and debug), **loads and passes** the spike's smoke test and the full adversarial suite on Godot 4.7.2 with outcomes **identical to the stock 0.8.2 binary**. |
| `api_version=4.7` | **Fails** to compile: with `api_version >= 4.7` godot-cpp's `memnew` of a `RefCounted` type returns `Ref<T>` rather than `T*` (error in `memory.hpp`, first hit `LuaCoroutine`). |

Patch set (`spike/patches/lua-gdextension-0.8.2-godot-cpp-507ed9d.patch`, 144 lines, reverse-applies cleanly to the 0.8.2 tag; the
`lib/godot-cpp` pointer is a local symlink to `507ed9d`, not part of the patch): 3 path edits to `extension_api-4-6.json` in
`tools/code_generation/generate_cpp_code.py`, `generate_lua_godot_api.py` and `tools/code_generator.py`; `#include <godot_cpp/classes/ref.hpp>` in
`LuaError.hpp`, `LuaDebug.hpp`, `LuaASTNode.hpp`, `LuaASTQuery.hpp`, `LuaAST.hpp`, `LuaState.hpp`, `LuaParser.hpp`, `LuaObject.hpp`; and `PYTHON_BIN=python3` in the
environment (the build hard-codes `python`). Build line: `PYTHON_BIN=python3 scons platform=linux arch=x86_64 target=template_release lua_runtime=lua api_version=4.6 -j7`.

**Effort to turn that into a maintained fork (estimates, not measured).** The **4.6-API build above took about a day** and is
verified on Linux. A clean `api_version=4.7` port needs the generator path edits and the headers above plus handling the
**`memnew` of `RefCounted` types**: about **30 `memnew` sites in `src/`, of which roughly 15-20 create `RefCounted` types** (`LuaCoroutine`,
`LuaTable`, `LuaFunction`, `LuaError`, `LuaDebug`, `LuaAST*`, `LuaScript`) and need `Ref<T>`-returning handling; I estimate **2-3 days** including
regenerating the bindings and re-running the spike's smoke and adversarial tests on Linux, then **web, Android and the
desktop platforms in the shared pipeline another 2-3 days** (the pipeline mostly covers it), and **about half a day per
upstream release** to rebase. P1-P3 and P4 come on top of that (P1-P3 are small C patches; P4 is the new binding, spike-results.md
section 8.3). Total to a patched, six-platform fork: **about 2 engineer-weeks**, to be confirmed when it is scheduled.

**What this means for the roadmap.**

- **M1 uses the stock 0.8.2 release binaries, pinned by SHA256** (`tools/ci/fetch_native_libs.sh`), with the G1 watchdog and the
  sandbox wrappers. This works today on every target we tried.
- **A source build (P1-P3, any P4) requires the port to godot-cpp 10 in a fork first.** The patch series is therefore behind the
  fork in the roadmap and, as scoped, behind M1 integration (and no longer gated on in-game sharing/import).
- **The zero-copy native view (P4) depends on the fork**, so the Lua-facing batch view is designed and shipped for **packed copies on
  stock 0.8.2 first** (spike-results.md section 8); the native backing swaps in later without changing scripts.
- Upstream hardening: lua-gdextension `main` may move to godot-cpp 10 on its own (the godot-cpp merge of `v10-not-beta-anymore` is in
  `507ed9d`); check before starting the port.

### Option B (fallback): own GDExtension around upstream Lua 5.4

Small C++ extension using godot-cpp `507ed9d` (10.0.0-stable, `api_version=4.7`), compiling Lua 5.4.8 statically (plain C, no sol2/tree-sitter). Pros: no Variant boundary
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
  environment built from the script's **capabilities** (next section): every script gets full Lua, with an opt-in `needs` list for `io`/`os`/`debug`/
  `package`/`native` (a script pasted in from elsewhere is treated as the player's own, same list, same prompt). Binary chunks and
  `string.dump` are refused/removed in every mode (`load` and `loadfile` use mode `'t'`); `dofile`/`loadfile` exist only with `io`;
  `require` always exists but is confined to the script's own folder subtree unless `package` is granted.
- `spawn{...}` from Lua builds a *spawn command* (numbers and callback references). It is executed
  natively; the bullet gets a compact **behavior record**: native motion params (speed, accel,
  spin, homing config, bounce, pierce, lifetime) and a **script slot**.
- A script slot is `(weapon_id, callbacks_mask, state_ref, timer_list)`. Callbacks are not copied
  per bullet; bullets of the same `spawn` definition share one callbacks table. Bullets with no
  callbacks have script slot = 0 and **never touch Lua after spawn**.
- Handles given to Lua wrap the engine's **packed stable id** `(generation << 32) | handle` (**PR #4**: an indirection table maps `handle` to the current slot), so stale handles are detected without
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
- **Pooling**: bullet slots are recycled (swap-remove: slots are valid only inside one hook call; Lua holds PR #4 stable ids `(generation << 32) | handle`); Lua-side per-shot `state` tables come from a free list
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
- **Memory**: the 64 MB cap is **adopted, soft on stock**. With the stock binding it is checked every 1,000 instructions (measured overshoot
  64 -> 83 MB with 1 MiB chunks); with the P1 allocator cap it is a hard Lua "not enough memory" error inside the script.
- Never trust player Lua with engine objects; only ids and plain data cross the boundary.

### Sandbox and capabilities

Capability -> libraries, most dangerous first (api.md has the player-facing labels; the import UX is deferred, see api.md *Deferred: in-game sharing/import*):

| Capability | Adds | Notes |
|---|---|---|
| (always) | base (minus `dofile`, `loadfile`, `string.dump`), `table`, `string` (bounded), `math`, `utf8`, `coroutine` (wrapped), `os.time`, `os.clock`, `GODOT_VARIANT`, the facade, and a **confined `require`** (own-folder-subtree `.lua` modules, read-only, text-only, same sandbox and guards) | `load` is text-only (mode `'t'`); `os.exit` never exists in this set |
| `native` | `package.loadlib`, `package.cpath`, C searchers 3 and 4 | "Load native code. Can do anything to your computer." |
| `os` | `os.execute`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, `os.exit` (replaced: stops the script, never the game), **`io.popen`** | "Run programs and change your system." |
| `io` | `io.*` except `io.popen`, plus **`dofile` and `loadfile`** (text mode only) | "Read and write files." |
| `debug` | trimmed `debug` (see above) | "Inspect and change Lua internals." |
| `package` | `require` from **arbitrary paths**, `package.path`, `package.loaded`, `package.searchers`, Lua searchers 1 and 2 | "Load Lua modules from disk." |
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
  verifies its SHA256 (binaries are never committed; testing.md section 2.1). CI is unchanged for now; the cold-import fallbacks
  (pre-seed `extension_list.cfg`, then tolerate exit 134 only with "[ DONE ] reimport" and no ERROR) are in testing.md.
- Web export: Lua 5.4 addon, "Extensions Support" on, the `web_dlink_*` templates; **both threaded and non-threaded web builds were
  exported and run on 4.7.2, only in headless Chromium with software GL (no Safari, no Firefox)** *(measured)*. Android: the arm64 and x86_64 `.so` files ship in the debug APK (`unzip -l` checked; built, not run: no KVM on the box; QA runs it on an emulator).

## Open questions

Answered since the first draft: **Godot version** = 4.7.2 (decided); **spike** = done (spike-results.md); **web** = a release target and works;
**in-game sharing/import** = deferred (Karyu); pasted scripts are treated as own scripts with the same opt-in `needs`; a hard memory cap / strict sandbox is therefore crash-safety hardening, not a launch gate (capability model in `api.md`).

Still open:

- Stock 0.8.2 + wrappers for M1; the fork port to godot-cpp 10 and then P1-P3 afterwards at lower priority than M1 integration (no longer gated on import): agreed? (Chief of Staff)
- **Answered (Karyu, relayed): hybrid C++ is approved**, with a **narrow zero-copy Lua view of the native pool memory for plain bullets only**; hooked
  and scripted bullets stay on GDScript packed copies, and one accessor design serves both backends (spike-results.md section 8). The view needs the
  fork (lua-gdextension cannot register foreign userdata or hand out a `lua_State*` today): P4 patch preferred, a C ABI shim as the fallback.
- Run the GUI editor on real Wayland Linux, Windows and macOS (#257), and the APK on a device or a KVM CI runner.
- Determinism and seeding (api.md OI-2); the limited mode (deferred with sharing).
- Engine interface additions (api.md OI-14..19; spike-results.md section 8): batch API, stable id column, `teleport`, wall normal, `can_hit`.
