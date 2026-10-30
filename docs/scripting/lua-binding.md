# Lua binding evaluation and recommendation

Date of research: 2026-10-30. Everything marked *(verified)* was read from the repo, its
release assets or its issue tracker on that date. Items marked *(not verified)* are inferences
or things that need a spike. Scriptshot's own Godot version is not decided yet (the repo has no
`project.godot`); see Open questions.

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
| Godot 4 | Yes. Minimum **4.5** (`compatibility_minimum = "4.5"`); 0.8.x is built against godot-cpp with `api_version=4.6`. **Caveat:** open issue #260 (2026-10-19) reports the 0.8.2 binary refusing to load on Godot 4.5.2 ("built for Godot 4.6.0"); other issues report editor crashes on 4.7.2/4.8-dev (#257, #255). Treat 4.6+ as the safe target. *(verified from repo/issues; #260 not reproduced)* | Last build docs target Godot **4.1**; last release v2.1-beta11 (2024-01-24). Not tested by me on any current version. | godot-luau-script: README badge says Godot 4.4; **archived** 2025-11-07. GodotLuau (Pimpoli): 6 stars, pushed 2026-09-26, no releases checked. | **Godot 3 only** (README: "does not work with Godot 4", points to lua-gdextension). | Matches whatever Godot version we build against. |
| Runtime | Lua **5.4.8** *or* **LuaJIT 2.1** as two separate addon zips. No Luau. | Lua 5.4 (and a LuaJIT build) | Luau (Roblox's typed Lua dialect) | LuaJIT FFI | Lua 5.4 (or LuaJIT) as we choose |
| Windows / macOS / Linux | **Yes** in 0.8.2: Windows x86_32/x86_64/arm64 DLLs, Linux x86_32/x86_64/arm64 .so, macOS universal dylib. *(verified by listing the 0.8.2 release zips)* | Releases include Windows/Linux/macOS editor + export templates (2024 and older); GDExtension zip for those platforms. | Not verified | n/a | Yes, but we must build and sign them ourselves |
| **Web** | **Yes, with Lua 5.4** (not LuaJIT): release zip contains `libluagdextension.web.template_{debug,release}.wasm32{,.nothreads}.wasm` (~2.7 MB release). LuaJIT has no wasm support. *(verified)* 0.8.2 changelog: "Yielding from coroutines now work in Web builds". | No web build in release assets. | Not verified | n/a | Possible, we compile Lua to wasm with godot-cpp's web target |
| Maintenance | MIT, 475 stars, 30 open issues, repo pushed 2026-09-28. Releases: 0.7.0 (2026-01-28), 0.8.0 (03-30), 0.8.1 (05-17), 0.8.2 (07-12): roughly every 2 months. No release in the ~3.5 months since; `main` has post-release changes (e.g. LuaJIT bump). Single main maintainer. | **Archived**; README: "I do not have the time. If interested in maintaining please start with a fork"; last commit 2024-12-29; 0 open issues because it is archived. | godot-luau-script archived; GodotLuau small and young. | Not archived, last push 2025-03-09; irrelevant (Godot 3). | We own it forever |
| License | **MIT** (LICENSE: "Copyright (C) 2026 Gil Barbosa Reis"). Bundles Lua (MIT) / LuaJIT (MIT). | LICENSE file present ("Copyright (c) 2021-present Trey Moller"), GitHub reports `NOASSERTION`; text was not fully read. | MIT (both) | MIT | MIT (Lua is MIT) |
| Runaway protection | `LuaThread.set_hook(hook, mask, count)` wraps `lua_sethook` and supports count/line/call/return masks (`src/LuaThread.cpp`, `doc_classes/LuaThread.xml`). **No built-in instruction budget or memory *limit*** found (there is `get_memory_used()` and GC control only). *(verified)* | Library selection per state; limited hook support not verified | Luau has `interrupt` callbacks natively (design feature of Luau; not verified in these wrappers) | n/a | Full control: `lua_sethook` + custom allocator with a hard memory cap |
| Sandboxing | `LuaState.open_libraries(mask)` lets you open only chosen libraries; `load_string(code, chunkname, env)` takes a custom environment table; per-state Godot-API exposure chosen by the embedder. *(verified)* | Designed for sandboxed modding (README) | Luau sandbox is a first-class feature of the VM | n/a | Entirely ours |
| Hot reload | Extension is `reloadable = true`; Lua scripts as Godot scripts have `_reload`. For our use, we control reload of our own `LuaState` (re-`load` the file). | not verified | not verified | n/a | Ours |
| Fit for "thousands of bullets" | Neutral: the cost is the **Variant boundary** crossing on every call (both directions). Fine for events/timers; not for per-bullet per-frame callbacks. Anecdotal only: issue #143 reports a `for` loop benchmark of 14 ms (Lua 5.4) vs 0.4 ms (LuaJIT) vs 70 ms (GDScript, debug). There is **no official performance suite** (maintainer says so in the same thread). | Same boundary cost | Same | n/a | Can avoid the Variant boundary entirely (pass packed arrays/ints) |

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
| Instruction hook | `lua_sethook` count hook reliable everywhere | JIT-compiled code **ignores hooks by default**; needs a custom build with `LUAJIT_ENABLE_CHECKHOOK` (unsupported, per LuaJIT's author) or `jit.off()`. The shipped addon uses stock LuaJIT. |
| Language | `<close>`, integers, goto | 5.1 + 5.2 extras; the addon bundles recent LuaJIT with some 3.0 syntax extensions (`+=`, `??`), not portable Lua |
| Behaviour parity across platforms | Identical on all targets including Web | Web differs from desktop |

**Conclusion: Lua 5.4 on every platform.** One language semantic everywhere, hook-based budgets
work, and the web build exists. Speed is recovered by keeping per-bullet logic native.

## Recommendation

**Use `gilzoide/lua-gdextension` (the Lua 5.4 build, not the LuaJIT build), pinned to an exact release, behind our own thin facade (`ScriptHost`), and run a 1-2 day spike before committing.**

Why:

- It is the only actively maintained Lua binding for Godot 4 that I found: releases through
  2026-07, commits through 2026-09-27, MIT, Windows/macOS/Linux/**Web** binaries in the
  release zip.
- It exposes what we need for embedding: independent `LuaState`s, library masks, environment
  tables for `load`, per-thread hooks, GC stats, coroutines.
- `godot_luaAPI` is archived and tied to Godot 4.1, Luau bindings are archived or immature,
  `godot-lua-pluginscript` is Godot 3.

Trade-offs and risks:

1. **Godot version coupling.** 0.8.x needs a recent editor (issue #260 suggests 4.6+ in practice).
   Pin Godot and the addon version together.
2. **Bus factor of one**, and ~3.5 months since the last release. Mitigation: all Lua access goes
   through our `ScriptHost` facade so the binding can be replaced by a bespoke extension
   (Option B below) without touching the game or player API.
3. **No memory cap or instruction budget out of the box.** The count hook is available; the memory
   cap is not. Scripts can still exhaust memory in a single call; at minimum we monitor
   `get_memory_used()` and kill the script state between callbacks. Hard cap would need a fork or
   Option B.
4. **Open crash reports** involving coroutine freeing (#240) and editor crashes on newest Godot
   versions (#255, #257). Our design limits coroutine churn (pooled, long-lived) and the spike must
   stress this.
5. **Hook semantics need verification.** `set_hook` takes a Callable/LuaFunction: we must confirm the
   hook can abort the running callback by raising a Lua error (the standard pattern), that the cost of
   a Callable round trip every N instructions is acceptable, and that coroutines created inside a
   hooked state inherit hooks.
6. **Variant boundary cost** is the main performance risk and drives the architecture below.

### Option B (fallback): own GDExtension around upstream Lua 5.4

Small C++ (or Rust) extension using godot-cpp, compiling Lua 5.4 statically. Pros: no Variant
boundary on the hot path (pass bullet IDs and packed arrays), hard memory cap through a custom
allocator, precise instruction budget, no dependency on one maintainer. Cons: we own builds for
Windows/macOS/Linux/Web, signing/notarisation, and godot-cpp version bumps. Choose this if the spike
shows the boundary cost or sandbox limits are unacceptable.

### Spike (proposed, before integration; waits for Karyu's go-ahead)

1. Install the 0.8.2 Lua 5.4 addon in a throwaway Godot 4.6 project (not this repo).
2. Benchmark: 5,000 native bullets with (a) no callbacks, (b) 5,000 `on_hit` calls per second,
   (c) 5,000 timer callbacks per second, (d) `on_tick` on all. Report ms per frame.
3. Hook test: `while true do end` and a pathological `string.rep/match`, abort with count hook;
   confirm editor and game continue and memory is reclaimed.
4. Web export test (single-threaded and threaded) running the same benchmarks.
5. Coroutine churn test (cf. issue #240): create/finish 10k coroutines.
6. Hot reload test: re-`load` a script into a live state.

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

- A weapon script is loaded into its own `LuaState` (not shared across weapons) with a restricted
  environment (`open_libraries(BASE|TABLE|STRING|MATH|COROUTINE|UTF8)`, then remove
  `dofile/loadfile/load` bytecode, and install the player API table and `require`).
- `spawn{...}` from Lua builds a *spawn command* (numbers and callback references). It is executed
  natively; the bullet gets a compact **behavior record**: native motion params (speed, accel,
  spin, homing config, bounce, pierce, lifetime) and a **script slot**.
- A script slot is `(weapon_id, callbacks_mask, state_ref, timer_list)`. Callbacks are not copied
  per bullet; bullets of the same `spawn` definition share one callbacks table. Bullets with no
  callbacks have script slot = 0 and **never touch Lua after spawn**.
- Handles given to Lua are `(index, generation)` pairs, so stale handles are detected without
  holding engine objects.

### 2. Batched, pooled bullets

- Native side keeps struct-of-arrays pools (position, velocity, age, flags, ...) and updates
  movement, homing and collision in tight loops. This is the Gameplay Engineer's domain; the
  scripting layer only needs: spawn/kill by ID, read/write a few fields, and event emission.
- **Lua is entered only for events and timers**: `on_spawn`, `on_hit`, `on_wall`, `on_expire`,
  `on_death`, `every`/`after`, and (rarely) `on_tick`. Timers live in a native min-heap keyed by
  game time; the heap pops due timers, grouped per weapon, and enqueues them.
- **Event queue, then one Lua pass per tick.** During physics the native side only appends events
  to a ring buffer (`bullet_id, event, target_id`). After physics, `ScriptHost` drains it:
  for each weapon state, runs callbacks in one batch with the budget applied. This avoids
  re-entrancy (spawning from inside collision).
- **Minimise boundary crossings**: pass a callback its context as a few numbers and ids (a reused
  context table), and collect effects as **commands appended to a Lua-side buffer** that native
  code applies after the callback (spawn, kill, set speed...). Reads (`b.pos`) come from the
  context snapshot or one native call. This keeps the Variant boundary cost to ~1 crossing per
  callback instead of per property access. *(Design intent; to be measured by the spike.)*
- **Pooling**: bullet slots are recycled; Lua-side per-shot `state` tables come from a free list
  and are cleared on death; callback tables are shared; coroutines for `run`/`wait` come from a
  pool (limits coroutine churn, relates to issue #240).
- **Caps**: live bullets, spawns per tick and generation depth are enforced in the native spawn
  path, so a runaway script cannot allocate unbounded pool memory.

### 3. Error isolation and runaway protection

- Every callback runs in `pcall`/`xpcall` with a traceback handler; the error is attributed to
  `file:line` and surfaced in the in-game console. Policy as in `api.md` (disable callback for that
  shot, keep native motion; global disable on error floods).
- **Instruction budget**: install a count hook (`LUA_MASKCOUNT`, count ~1,000) on the running
  thread; the hook compares an instruction counter and a wall-clock timestamp against the callback
  budget and the per-frame budget, and raises an error to abort. Never use line hooks (slow).
  Note native functions (e.g. `string.rep`, pattern matching) do not trigger the hook, so the
  sandbox should either replace expensive `string` functions with bounded versions or limit input
  sizes (e.g. cap pattern-matching string length).
- **Per-frame budget**: a Lua time slice (default 3 ms). When exhausted, remaining queued callbacks
  are deferred to the next tick (queue is bounded; over-full queue ⇒ oldest non-critical events
  such as `on_tick` dropped first, `on_death` preserved).
- **Memory**: monitor `get_memory_used()` per state after each batch; over the cap ⇒ pause the
  weapon and recreate its state. (Cap enforced only between callbacks with this binding; hard cap
  with Option B.)
- **Escalation**: repeated aborts ⇒ weapon paused; bullets in flight keep native motion; reload
  resumes.
- Never trust player Lua with engine objects; only ids and plain data cross the boundary.

### 4. Hot reload

- A file watcher (editor / `FileAccess.get_modified_time`) triggers load of the new chunk into a
  **fresh** `LuaState`; on success swap the weapon's active state, on failure keep the old one and
  show the error.
- In-flight bullets keep a reference to the **old state** and callbacks until they die (default);
  the old state is freed when its bullet count reaches zero. Optional `reload = "migrate"`:
  bullets switch to the new callbacks by name and keep `state` tables (copied into the new state).
- Weapon-level `state` is copied across by key when the new script declares it.

### 5. Build and distribution

- Vendor the addon in `addons/lua-gdextension/` of the Godot project at a pinned release; commit the
  `.gdextension` and binaries or fetch them in CI (decision for Karyu: repo size ~56 MB zip).
- Web export: use the Lua 5.4 addon, enable "Extensions Support" in the export preset and test both
  threaded and non-threaded web templates. *(not verified)*

## Open questions

- Which **Godot version** is Scriptshot targeting? The addon needs at least 4.5, practically 4.6+ today.
- Is a ~1-2 day **spike** acceptable before any integration code is written?
- Is **web** a real release target (it forces Lua 5.4 and constrains threading)?
- Is a hard memory cap/strict sandbox a launch requirement? If scripts will be **shared between
  players**, Option B (own extension) becomes more attractive.
- Gameplay Engineer: bullet pool layout, event emission API, spatial queries (see `api.md` OI list).
