# Scripting testability plan

Status: **plan (v0.2)**. Nothing here is implemented in the game repo yet; the spike code that every item below is based on is
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
  seeded `RandomNumberGenerator`. It implements exactly the `(index, generation)` stable-id rules of PR #2, so id-reuse
  tests do not need the engine.

```gdscript
class_name ScriptWorld extends RefCounted
func now() -> float: return 0.0
func rng() -> RandomNumberGenerator: return null
func spawn(req: ShotRequest) -> int: return -1                # stable id or -1
func kill(id: int, reason: int) -> bool: return false
func teleport(id: int, p: Vector2) -> bool: return false
func reflect(id: int, new_owner_layer: int, reverse: bool) -> bool: return false
func view(ids: PackedInt64Array, out: BulletViews) -> void: pass   # batch read (pos, vel, age, params)
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
| Teleport | a Lua position jump maps to `BulletPool.teleport`, **no swept hit** through a hurtbox between old and new position (regression for raw `pos` writes) |
| Reflect | `reflect(id, layer, reverse)` flips `owner_layer` and, with `reverse`, the velocity; `owner_layer` is stripped from `hit_mask` |
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
binaries). When the shared native pipeline builds lua-gdextension from source (spike-results.md section 12), the script
becomes "download the pipeline artifact for this commit" and keeps the SHA256 check; the interface stays the same.

CI job order: `fetch_native_libs.sh` -> **import twice** (below) -> `tools/run_tests.sh` -> `tools/run_benchmark.sh`.
GUT runs headless exactly as today (`-s res://addons/gut/gut_cmdln.gd -gexit`).

### 2.2 Cold-import abort (found in the spike)

With the extension present, `godot --headless --import` on a project **without a `.godot/` cache exits 134 (SIGABRT) after the
import finished**; the second run exits 0 (spike-results.md section 3). `tools/run_tests.sh` currently treats a non-zero
import as failure, so it must change to:

```bash
"$GODOT" --headless --path . --import >"$LOG_DIR/import1.log" 2>&1 || true     # warms .godot/; known SIGABRT on first run with the addon
"$GODOT" --headless --path . --import >"$LOG_DIR/import.log"  2>&1; import_status=$?   # the gate
```

and keep scanning both logs for `ERROR_PATTERN`. A test (`test_ci_import_twice.sh`-style check in the workflow) fails if the
**second** import is non-zero. When the extension is absent (a pure-GDScript job) behaviour is unchanged.

### 2.3 Matrix

| Job | Content | Gate |
|---|---|---|
| `unit` (every push) | `tests/unit` + `tests/scripting/{unit,host}` | all pass, no `SCRIPT ERROR`, no timeouts |
| `integration` (every push) | `tests/scripting/integration` | all pass |
| `adversarial` (every push) | section 3, one process per case | all pass, zero hangs |
| `bench-scripted` (every push, Linux x86_64) | section 6 | 5k hard gate; 10k warning |
| `export-smoke` (nightly) | release export per platform, run the spike scene, grep `SPIKE_RESULT` | web both flavours, Linux; Android APK build only until a KVM runner exists |

## 3. The adversarial spike cases as permanent tests

The 42 cases in [`spike/bench/adversarial.gd`](spike/bench/adversarial.gd) become `tests/scripting/adversarial/`. Rules that
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
  exist only with `native`.
- **Known-residual cases** (pattern at the 1,024 limit, 83 MB memory overshoot, `string.rep` at 1 MiB) are tests with an
  **upper bound** (`ms <= 50`, `peak_mb <= 100`) so a regression to the unbounded behaviour fails, and they carry a comment
  linking the P1/P2 patches (spike-results.md section 12) that would turn them into hard errors.
- **Tests that must be added with the permanent versions:** `coroutine.wrap` inside an `on_fire` coroutine that calls `spawn`
  after `wait()` (the #240 shape); error inside a coroutine resumed by `update()`; `os.exit` inside a granted `os` script
  stops only the script; metatable `__gc` refused; `load` text-only; `string.dump` absent; binary chunk rejected;
  `dofile`/`loadfile` absent; the xpcall handler cases.

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
- `spawner.lua`: handles `spawn` returning `nil` (cap) without splitting on a missing id;
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
