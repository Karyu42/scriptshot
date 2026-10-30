# Scripting testability plan

Status: **plan (v0.3)**. Nothing here is implemented in the game repo yet; the spike code that every item below is based on is
in [`spike/`](spike/) (see [spike-results.md](spike-results.md)). Written for QA and the Gameplay Engineer; the Scripting
Engineer owns the `ScriptHost` side.

Goals, in order: (1) a runaway or hostile script can **never** hang or crash CI or the game; (2) scripts behave
**deterministically** under a seed; (3) every shipped example loads and runs; (4) the cost of scripted bullets is **gated** like
the rest of the bullet benchmark; (5) the whole thing runs headless in CI on Linux with the same `tools/*.sh` entry points
that exist today.

## 1. Layers

```
                         +-----------------------------+
 tests/scripting/unit    |  pure GDScript, no Lua      |  ShotContext mapping, capability sets, metadata parsing,
                         +-----------------------------+  command-buffer decode, event-queue rules
                         +-----------------------------+
 tests/scripting/host    |  ScriptHost + FakeBullets   |  Lua semantics, sandbox, watchdog, errors, determinism,
                         |  (no BulletManager)         |  examples, coroutines (#240), limits
                         +-----------------------------+
                         +-----------------------------+
 tests/scripting/integr. |  ScriptHost + real          |  spawn/kill/teleport/reflect through the real pool,
                         |  BulletManager + WallGrid   |  hit order, swept collision, caps, budgets
                         +-----------------------------+
                         +-----------------------------+
 tests/benchmark         |  scripted_bullet_benchmark  |  QA's JSON format; 5k hard gate, 10k warning
                         +-----------------------------+
```

### 1.1 `ScriptHost` facade with a fake bullet side

`ScriptHost` is the only class that touches Lua. Everything it needs from the game goes through one narrow interface,
`ScriptWorld` (GDScript, `RefCounted`), with two implementations:

- `RealScriptWorld(manager: BulletManager, emitter: ShotEmitter, player: Player, walls: WallGrid)`: production.
- `FakeScriptWorld`: an in-memory bullet table (`ids`, `pos`, `vel`, `age`, `alive`, a generation counter), a recorded list of
  `spawn / kill / teleport / reflect / set_player_hp` calls, scripted `hits()` and `walls()` event feeds, a fake clock and a
  seeded `RandomNumberGenerator`. It implements the **packed stable-id scheme of PR #4 (1d2fe2c)**: `id = (generation << 32) | handle`, `handle` indexing an
  indirection table of slots, `generation` bumped when a handle is released, `-1` for none (not the old `(index, generation)` pair; stable ids are not on `main` yet), so id-reuse
  tests do not need the engine.

```gdscript
class_name ScriptWorld extends RefCounted
func now() -> float: return 0.0
func rng() -> RandomNumberGenerator: return null
func spawn(req: ShotRequest) -> int: return -1                # stable id or -1
func kill(id: int, reason: int) -> bool: return false
func teleport(id: int, p: Vector2) -> bool: return false
func reflect(id: int, new_owner_layer: int, reverse: bool, new_damage: float = 1.0, keep_script: bool = false) -> bool: return false   # [PR #4]
func view(ids: PackedInt64Array, out: BulletViews) -> void: pass   # batch read (pos, vel, age, params); fills the packed-copy backing of the batch view
func player_state() -> PlayerState: return null
```

Because `ScriptHost` never sees `BulletManager` directly, **all Lua-semantics tests run without the manager** and fail
with Lua line numbers, not engine internals. The integration layer exists to prove the fake and the real side agree.

### 1.2 Integration tests against the real `BulletManager`

A small set (30-40 tests) of GUT scripts that build `BulletManager` + `ShotEmitter` + `HurtboxGrid` + `WallGrid`
(as in `tests/unit/test_bullet_manager.gd`) and drive a script through `ScriptHost`:

| Area | Cases |
|---|---|
| Spawn | `spawn` in `on_fire` is synchronous (ids returned, bullets in the pool before `fire` returns); `spawn` in `on_tick` / `on_hit` is deferred to the next tick; deferred cap (8,192/tick) counts the surplus |
| Kill / ids | `b:kill()` -> `mark_dead(MANUAL)`; stale id after swap-remove or slot reuse is a no-op (generation mismatch); `DespawnReason` values LIFETIME, BOUNDS, HIT, MANUAL, CLEARED, WALL reach `on_despawn` |
| Hit order | `receive_hit` -> `on_hit` -> pierce-- or `mark_dead(HIT)`; the `can_hit` filter vetoes before `receive_hit` |
| Teleport **[main]** | a Lua position jump maps to `BulletPool.teleport`, **no swept hit** through a hurtbox between old and new position (regression for raw `pos` writes) |
| Reflect **[PR #4]** | `reflect(id, layer, reverse, new_damage, keep_script)` flips `owner_layer`, with `reverse` the velocity, sets damage to `new_damage` (default 1), clears behaviour and `user` unless `keep_script`; the second reflection returns `false` (`max_reflections = 1`, `0` = unlimited); `owner_layer` is stripped from `hit_mask` |
| Batch view | the **same script** runs on the packed-copy backing and (later) the native backing and produces identical command logs; bounds, read-only and expiry rules as in api.md *The batch view* (the diverging error reports are asserted per backing) |
| Player writes | `PlayerState` setters apply immediately in the engine; the Lua `player` proxy commits the write set at the end of the callback and commits nothing on error or watchdog stop; `player.invulnerable` writes only the script layer (`pierces_script_invuln` shots ignore it, engine i-frames are never cancelled) |
| Capability grants | prompt appears for any script requesting `os`/`io`/`debug`/`package`/`native`; grants keyed by content hash; in-game-editor edits carry the grant; external saves use per-session "Trust this file while I edit it" (cleared on restart); an edit adding a capability prompts for just that one; hot reload re-checks grants |
| Caps | player share 7,000 / 3,500 under the 10k total with a 5k floor; `spawn` over the share returns `nil` and counts |
| Budgets | per-frame script budget: slices round-robin when exhausted; 3 consecutive timeouts suspend the weapon |
| Walls | `on_wall` gets `t` (and the normal once the engine provides it; today the test asserts the documented fallback) |

## 2. CI: GUT headless, and the native library

### 2.1 Where the extension binary comes from

Binary artifacts are **never committed** (repo hygiene test + size). A pinned fetch script supplies them:

`tools/ci/fetch_native_libs.sh` (new):

```bash
#!/usr/bin/env bash
# Fetches the pinned lua-gdextension release into addons/lua-gdextension/ (Linux x86_64 + the addon files).
# Idempotent; verifies SHA256; never run by the game, only by CI and developers.
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=0.8.2
URL="https://github.com/gilzoide/lua-gdextension/releases/download/${VERSION}/lua-gdextension.zip"
SHA256="51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443"   # of the 0.8.2 release zip
DEST=addons/lua-gdextension
if [ -f "$DEST/.pinned-$VERSION" ]; then exit 0; fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$URL" -o "$tmp/lua.zip"
echo "$SHA256  $tmp/lua.zip" | sha256sum -c -
unzip -q "$tmp/lua.zip" -d "$tmp/x"
mkdir -p "$DEST"; cp -r "$tmp/x/addons/lua-gdextension/." "$DEST/"
touch "$DEST/.pinned-$VERSION"
```

`.gitignore` gains `/addons/lua-gdextension/` and `test_repo_hygiene.gd` asserts it (so a drive-by commit cannot add the
binaries). **M1 uses the stock 0.8.2 release binaries, pinned by this SHA256.** A source build exists only after the lua-gdextension fork is ported to godot-cpp 10
(0.8.2 does not build unmodified against godot-cpp `507ed9d`; spike-results.md section 12); then the script becomes "download the pipeline artifact for this commit" and keeps the SHA256 check.

Toolchain pins for any native or export job (Godot 4.7.2-stable tree, as verified by QA): Android NDK **29.0.14206865** (clang 21), build-tools **36.1.0**, platform API min 24, JDK 17,
SCons 4.10.1; **Emscripten 4.0.20** for the official web template (4.0.11 is only the engine's own CI `EM_VERSION`); godot-cpp **`507ed9d`** (10.0.0-stable, `api_version=4.7`) for Scriptshot's own extension.
`58d1de7` is godot-cpp 10.0.0-rc1 (4.6 API), the submodule of lua-gdextension 0.8.2; it is **not** "godot-cpp 4.7.2".

CI job order: `fetch_native_libs.sh` -> **import** (section 2.2) -> `tools/run_tests.sh` -> `tools/run_benchmark.sh`.
GUT runs headless exactly as today (`-s res://addons/gut/gut_cmdln.gd -gexit`).

### 2.2 Cold-import abort (found in the spike; corrected after QA's reproduction)

**What is known.** With the addon present, `godot --headless --path <project> --import` on a **blank project without a `.godot/` cache** exits **134** after the import finished; the second run exits 0
(spike-results.md section 3). It is a **SIGSEGV null dereference (`si_addr=0x28`) inside the stripped Godot editor binary after `loading_editor_layout`**, with no frame in `libluagdextension`;
`reloadable = false` does not help. **It does not reproduce on the real Scriptshot `main` with GUT: 4/4 cold imports pass (QA).** QA's artifacts are in `/workspace/pr3-review-artifacts/` (not committed).

**What CI does now: nothing changes.** `tools/run_tests.sh` keeps its current import gate. No CI mitigation is claimed, and "run twice and ignore the first exit code" is **not** adopted as a blanket rule.

**Fallbacks, if the real repo ever shows the abort** (apply in this order):

```bash
# (a) pre-seed the extension list (avoids it: 3/3 on the blank project)
mkdir -p .godot
echo 'res://addons/lua-gdextension/luagdextension.gdextension' > .godot/extension_list.cfg
"$GODOT" --headless --path . --import >"$LOG_DIR/import.log" 2>&1; import_status=$?

# (b) only if (a) is not enough: tolerate exit 134 solely when the log proves the import completed cleanly
if [ "$import_status" -eq 134 ] && grep -q '\[ DONE \] reimport' "$LOG_DIR/import.log" \
   && ! grep -qE 'ERROR|Failed to load' "$LOG_DIR/import.log"; then import_status=0; fi
```

(c) any other non-zero status, or a 134 without `[ DONE ] reimport`, or any `ERROR` / `Failed to load`, stays a failure. (d) When the extension is absent (a pure-GDScript job) behaviour is unchanged.

**Proposals (nothing was filed or posted):** an upstream godotengine/godot issue with the blank-project repro and the backtrace, and a Scriptshot tracking issue linking it and the fallbacks above.

### 2.3 Matrix

| Job | Content | Gate |
|---|---|---|
| `unit` (every push) | `tests/unit` + `tests/scripting/{unit,host}` | all pass, no `SCRIPT ERROR`, no timeouts |
| `integration` (every push) | `tests/scripting/integration` | all pass |
| `adversarial` (every push) | section 3, one process per case | all pass, zero hangs |
| `bench-scripted` (every push, Linux x86_64) | section 6 | 5k hard gate; 10k warning |
| `export-smoke` (nightly) | release export per platform, run the spike scene, grep `SPIKE_RESULT` | web both flavours (verified only in headless Chromium with software GL; no Safari/Firefox), Linux; Android per section 2.4 |

### 2.4 Android headless run (APK with both ABIs, x86_64 emulator)

**Preset and project.** `spike/export_presets.cfg` has a preset named `Android`: non-gradle export, `architectures/arm64-v8a=true` and `architectures/x86_64=true`, package `org.scriptshot.spike`,
`variant/extensions_support`, signing with the **debug keystore** (set in Godot's editor settings, nothing secret in the file). The spike project is self-contained (`spike/project.godot`, `spike/main.tscn`,
`spike/runner.gd`, `spike/bench/`, `spike/scripts/`, `spike/sandbox/`); on mobile it starts `res://bench/export_bench.gd` automatically (`runner.gd`). The addon is fetched with `tools/ci/fetch_native_libs.sh`
(the **0.8.2 zip ships an Android x86_64 `.so`**, so no NDK build; zip SHA256 `51f012dd...2443`), and is git-ignored. **The APK is never committed.**

```bash
# prerequisites: Godot 4.7.2 + its export templates (android_debug.apk), JDK 17, Android SDK (build-tools 36.1.0, platform-tools), debug keystore in the editor settings
cp -r docs/scripting/spike /tmp/spike && cd /tmp/spike
mkdir -p addons/lua-gdextension && <fetch the pinned 0.8.2 addon into addons/lua-gdextension>
mkdir -p .godot && echo 'res://addons/lua-gdextension/luagdextension.gdextension' > .godot/extension_list.cfg
godot --headless --path . --import
godot --headless --path . --export-debug "Android" out_android/spike.apk
# ABI check, must list BOTH libraries:
unzip -l out_android/spike.apk | grep -E 'lib/(arm64-v8a|x86_64)/libluagdextension'
# expected: lib/arm64-v8a/libluagdextension.android.template_debug.arm64.so and lib/x86_64/libluagdextension.android.template_debug.x86_64.so
aapt2 dump badging out_android/spike.apk | grep native-code      # native-code: 'arm64-v8a' 'x86_64'
```

**Emulator run (QA, GitHub Actions with KVM; not run by the Scripting Engineer: no KVM on the authoring box).**

```bash
adb install -r out_android/spike.apk
adb logcat -c
adb shell monkey -p org.scriptshot.spike -c android.intent.category.LAUNCHER 1
timeout 180 sh -c 'adb logcat -s godot:I | tee run.log | grep -m1 SPIKE_DONE'
grep 'SPIKE_RESULT' run.log
```

**Expected log (logcat tag `godot`, stdout of `print`): four result lines, one per phase, then `SPIKE_DONE`:**

```
SPIKE_INFO godot=4.7.2-stable (official) os=Android web=false threads=true mobile=true renderer=... cpu=...
SPIKE_RESULT {"alive":1000,"arch":"x86_64","fps":...,"frame_ms_med":...,"frame_ms_p95":...,"godot":"4.7.2-stable (official)","hooked":0,"lua":"Lua 5.4","lua_mem_kb":...,"lua_ms_med":...,"lua_ms_p95":...,"mode":"C","n":1000,"os":"Android","step_ms_med":...,"step_ms_p95":...}
... "mode":"A" ... "mode":"B" ... "mode":"B+hook" ...
SPIKE_DONE
```

Fields: `mode` in `C`, `A`, `B`, `B+hook`; `n` = 1,000 bullets; `lua_ms_med`/`lua_ms_p95` = Lua milliseconds per frame; `os` = `Android`, `arch` = `x86_64`. **Gate (loose, tune on the runner):** exactly four `SPIKE_RESULT` lines before `SPIKE_DONE`;
`os=Android` and `arch=x86_64`; `alive >= 990` for A, B, B+hook; `lua_ms_p95 <= 10` for `B` (the Linux reference is 1.15-1.35 ms per frame; an emulator without a host GPU is slower, so the first run sets the baseline). A failure to load the extension shows as `SCRIPT ERROR`
or no `SPIKE_INFO` line. A sample of the same lines from the scene on Linux (editor build) is in `spike/results/export_bench_headless_editor.txt`.

## 3. The adversarial spike cases as permanent tests

The **47 cases** in [`spike/bench/adversarial.gd`](spike/bench/adversarial.gd) (spike-results.md section 11; 0 hangs, 47/47 `host_ok=true`; `spike/run_adv.sh g1` runs them all) become `tests/scripting/adversarial/`. Rules that
made the spike trustworthy are kept:

- **One case per process** (`godot --headless ... -- adversarial <case>`), wrapped by `timeout`. A hang is then attributable and
  cannot take the whole suite with it. The GUT script is a thin driver that launches the child process via `OS.execute` (with
  `read_stderr`), parses the `ADV test=... outcome=...` line and asserts. It lives in `tests/scripting/adversarial/test_guard_rails.gd`.
- **Heartbeat.** Each case runs a `Timer`-driven main-loop heartbeat that prints `heartbeat=ok` after the script was stopped
  (and a fresh `LuaState` must run `return 1 + 1`). A missing heartbeat or a child killed by the timeout fails the test with
  the case name. Default per-case timeout 25 s (the spike's longest legitimate stop is ~1.4 s); the overall job timeout 5 min.
- **Expected outcome per case** is a table in the test file, not "anything but a hang": `STOPPED(instruction budget | wall clock |
  memory cap | os.exit requested)`, `ERROR(<substring>)`, or `COMPLETED(<printed lines>)`. The table is the executable form
  of the table in spike-results.md section 11.
- **Capability matrix** cases (none / `io` / `os` / `package` / `native`) assert the exact library set per grant, including that
  `io.popen` appears only with `os`, `package.loaded` never exposes `debug`/`io` unless granted, and Lua C searchers 3 and 4
  exist only with `native`; `require` exists with no capability but loads only own-folder-subtree text modules (cases `require_own_folder`, `require_escape`), and `dofile`/`loadfile` exist
  only with `io` and refuse binary chunks (cases `loadfile_text_with_io`, `loadfile_binary_refused`, `loadfile_absent_without_io`).
- **Known-residual cases** (pattern at the 1,024 limit, the **soft** 64 MB cap's 83 MB overshoot on stock, `string.rep` at 1 MiB) are tests with an
  **upper bound** (`ms <= 50`, `peak_mb <= 100`) so a regression to the unbounded behaviour fails, and they carry a comment
  linking the P1/P2 patches (spike-results.md section 12) that would turn them into hard errors.
- **Tests that must be added with the permanent versions:** `coroutine.wrap` inside an `on_fire` coroutine that calls `spawn`
  after `wait()` (the #240 shape); error inside a coroutine resumed by `update()`; `os.exit` inside a granted `os` script
  stops only the script; metatable `__gc` refused; `load` text-only; `string.dump` absent; binary chunk rejected in `load`, `loadfile` and `dofile`;
  `dofile`/`loadfile` absent **without `io`** and text-only with it; confined `require` (own subtree, no `..`, no absolute path) and `package`-unlocked `require`; the xpcall handler cases.

The adversarial job is the only one that spawns subprocesses and is excluded from the default `tools/run_tests.sh` run on
developer machines unless `RUN_ADVERSARIAL=1` (it is slow, ~15 s total in the spike).

## 4. Determinism

PR #1's open question (determinism) is still undecided; the tests pin down what we can promise **today**:

1. **Seeded replay:** a script that uses `math.random`, `spawn` fans and `update()` timing, driven by `FakeScriptWorld` with a
   fixed `RandomNumberGenerator.seed`, a fixed `dt = 1/60` and 600 ticks, must produce the **same spawn/kill/teleport call log**
   twice in one process, and equal to a checked-in golden file (`tests/scripting/golden/<example>.log`). The Lua `math.random`
   is seeded from the host RNG (never from `os.time`); `os.time`/`os.clock` are the only clock functions in scripts without `os`.
2. **Host-independent order:** events are delivered oldest first, in a fixed phase order (spawn, hit, wall, despawn); the golden log includes the
   event order.
3. **Budget independence:** the same replay with a 10x larger instruction budget gives the same log (the watchdog never changes
   semantics unless it fires).
4. **Cross-platform:** the golden files are compared on Linux CI; the web job re-runs a short replay and compares a hash. Floating
   point differences are tolerated by comparing with `1e-4`; any divergence is a decision for the determinism OI, not a flaky test.

## 5. Examples load and run

`tests/scripting/host/test_examples.gd` iterates `docs/scripting/examples/*.lua` (or the future `res://scripts/examples/`):

- loads each with the capabilities its `needs` metadata declares (and **fails** if it uses a function outside them);
- runs 300 ticks against `FakeScriptWorld` with a scripted hit/wall feed;
- asserts no error, at least one `spawn`, no instruction-budget stop, and that the live count stays below the weapon cap;
- `split_on_hit.lua`: every child spawn lies **outside** the hit target's hurtbox (or the target is excluded), checked against the
  `FakeScriptWorld` hurtbox list; this is the regression test for the re-hit bug found in review.
- `spawner.lua`: the example does **not** branch on `spawn`/`split` results (children are best-effort). The test runs it against a `FakeScriptWorld` that refuses spawns at a tiny cap and asserts that the mother's `b:every` and the `on_death` split
  raise no error, that `b:split` returns the accepted count (`0 .. 8`, a truncated fan at the cap: api.md *Splitting*) and that the live count never exceeds the cap;
- `homing.lua`: documents the engine status of `turn_rate` and runs both with and without it.

## 6. Error-policy tests

One test per row of api.md "Errors":

| Case | Expected |
|---|---|
| Syntax error at load | weapon is not equipped; error carries `chunkname:line`; the game continues |
| Runtime error in a callback | callback aborted; counted; shot/bullet state intact; error logged once per 5 s per site |
| 3 consecutive timeouts | weapon suspended; unsuspended on re-equip |
| Error in `on_hit` for bullet X | X is still resolved per the hit order (no double-hit, no leak) |
| Error in a coroutine resumed by `update()` | coroutine removed; other coroutines unaffected |
| Missing optional hooks | no error |
| Wrong return types, NaN/inf values | the facade rejects or clamps (spike case `facade_bad_values`), never reaches the pool |
| 64 live coroutines per weapon exceeded | `fire` returns an error value; the 65th is not created |
| Own script frees the player (`on_hurt`) while writing player state | writes are no-ops (PR #4) |

## 7. Scripted-bullet benchmark (QA's JSON format)

`tests/benchmark/scripted_bullet_benchmark.gd` reuses `BenchStats` and the structure of `bullet_benchmark.gd`, and writes the
**same JSON** so QA's tooling needs no change: `{"godot", "target", "target_bullets", "target_ms", "results": [...]}` where each
element keeps the existing keys (`bullets`, `frames`, `alive_at_end`, `min_alive_before_step`, `reached`, `work_p50_ms`,
`work_p95_ms`, `work_p99_ms`, `work_max_ms`, `work_mean_ms`, `phase_mean_ms`, `wall_*`) and adds:

```json
{ "scripted_fraction": 0.1, "mode": "batch",
  "lua_p50_ms": 0.0, "lua_p95_ms": 0.0, "lua_budget_ms": 3.0,
  "phase_mean_ms": { "...": 0, "lua_update": 0, "lua_events": 0, "lua_apply": 0 } }
```

Scenarios (all in one run, each its own `results[]` entry): `declarative` (C, 100%), `batch` slice 1/4 (100% scripted),
`per_bullet` (A, 10% scripted), and `events` (200 hits/frame). Counts: 1,000, 5,000, 10,000.

**Gates** (from the spike, release export or editor build as for the existing benchmark; the reference machine's numbers in
spike-results.md are the starting thresholds and QA tunes them to the CI runner):

| Gate | Condition | Result |
|---|---|---|
| **Hard, 5,000 bullets** | `work_p95_ms` (declarative, batch-slice-1/4, per-bullet 10%) <= 16.6 **and** `lua_p95_ms` <= `lua_budget_ms` | fails CI |
| **Warning, 10,000 bullets** | same conditions | `::warning::` annotation, job stays green; becomes a hard gate once the native hot loop lands |
| Reached | `min_alive_before_step >= bullets` | fails CI when not reached (as today) |
| Regression | `work_p95_ms` more than 25% over the stored baseline for the same scenario | warning (hard after two consecutive runs) |

`tools/run_benchmark.sh --scripted --json=...` wraps it with the same import and error-pattern handling (and the two-pass import
from section 2.2).

## 8. What is not covered (yet)

- Real-device Android and iOS runs; Windows and macOS runs of the extension; the GUI editor on Wayland (#257): manual,
  tracked in spike-results.md section 14.
- Determinism across platforms beyond the tolerance check (open question).
- Fuzzing the Lua parser (we rely on Lua's own tests); a later fuzz job could feed random chunks to `load` under the
  watchdog.
