# Bullet stress test plan

Goal: prove Scriptshot holds a **16.6 ms (60 FPS) p95 frame time** at the target bullet count, and catch regressions in CI.
Status: the headless part exists in the core scaffold (PR #2): `tests/benchmark/bullet_benchmark.tscn`, run via
`./tools/run_benchmark.sh --json=PATH`. CI runs it as the `perf` job and `tools/ci/check_perf.py` gates on its JSON
(`results[].work_p50_ms / work_p95_ms / work_p99_ms`). Still missing: the windowed run, dense-collision mode,
and the Lua variants below (blocked on the Lua binding decision).

Gaps in the current benchmark (planned follow-ups):
- Only the 5k and 10k steps run by default, and bullets are scattered randomly, so there are few hits and no clustered collisions.
- No bullets with behaviour hooks (`behavior_id != 0`), which is the path Lua will use.
- The `RenderingServer` is the dummy one, so the MultiMesh upload cost is not measured.
- A target count that is not benchmarked passes silently (`n/a`, exit 0). CI passes `--target-bullets` and `check_perf.py` fails if it is missing.

## 1. Scenario (`tests/benchmark/bullet_benchmark.tscn`; target design below)
- A scene with a player, a fixed RNG seed, no input and no random spawns, so runs are comparable.
- A spawner ramps the **live bullet count** through steps: **1k -> 2k -> 5k -> 10k**.
  Each step runs 10 s, and the first 2 s are warm-up and not measured.
- Bullets use the production bullet code path (pooling, movement, collision, despawn). Run two modes:
  - **Moving**: bullets fly and despawn at screen edge, so the count is held steady by re-spawning.
  - **Dense field**: bullets overlap enemies and walls, so this is the collision worst case.
- CLI args after `--`: `--ramp=1000,2000,5000,10000 --seconds=10 --out=reports/perf.json --mode=gdscript|lua`.
- Output JSON today: `{"godot":..,"target":..,"results":[{"bullets":N,"frames":F,"work_p50_ms":..,"work_p95_ms":..,"work_p99_ms":..,"work_max_ms":..,"wall_*":..,"alive_at_end":..}]}`. Add a `mode` field when the Lua variants land.

## 2. What is measured
- Per-frame time from `Performance.get_monitor(Performance.TIME_PROCESS)` + `TIME_PHYSICS_PROCESS`
  (headless), or the delta between frames (windowed). Collect every frame, then compute **p50 / p95 / p99 / max**.
- Also record: `OBJECT_COUNT`, `OBJECT_NODE_COUNT`, static memory, and orphan nodes at the end (leak check).
- Pass criterion: **p95 <= 16.6 ms at the target count**. p99 is reported only, so it is not a gate yet.
- Target count: starts at **5,000 simultaneous bullets**, to be confirmed with Karyu and tightened once real numbers exist.

## 3. Where it runs
| Mode | How | What it tells us | Gate? |
|---|---|---|---|
| Headless | `godot --headless --path . res://tests/benchmark/bullet_benchmark.tscn -- ...` (CI, `ubuntu-24.04`) | CPU simulation cost: script, physics, Lua. Dummy renderer, so **no GPU cost**. | **Yes** (CI) |
| Windowed | Same scene on a real GPU machine, `--rendering-driver vulkan` | Full frame cost including draw calls and batching | No. Manual or self-hosted runner, results logged per release |

GitHub-hosted runners are noisy shared VMs, so thresholds need headroom:
- Run each step 3 times, take the median of the p95 values.
- Keep a stored baseline (`vars.PERF_BASELINE`, a `bench.json` from main) and also fail on a >25% p95 regression.
- Software rendering on xvfb is **not** a valid windowed benchmark, so do not gate on it.

## 4. Lua-scripted-shot variant (`--mode=lua`)
The Lua cost is the project's differentiator, so it gets its own run:
1. **Baseline**: bullets spawned by native GDScript patterns (the control).
2. **Lua spawn**: a Lua shot script runs once per fire event and emits N bullets (a typical user script).
3. **Lua per-bullet callback**: each bullet runs a Lua `update(bullet, dt)` every frame, which is the worst case.
4. **Sandbox limits**: a deliberate infinite-loop script and a memory-hog script, to check that the instruction or time limit trips and the game keeps running.

Report the Lua overhead as `p95(lua) - p95(gdscript)` at each step. Initial budget: the Lua per-bullet callback may
spend at most **~50% of the frame budget (8 ms)** at the target count. If it is much worse, the answer is batching
(one Lua call per volley) or a native pattern library, not a lower bullet count.

## 5. CI integration
- `perf` job in `.github/workflows/ci.yml` runs on every PR and push to main (about 15 s). It gates on p95 <= 16.6 ms at 5000 bullets.
  Measured headroom is about 3x (p95 ~5 ms), so shared-runner noise should not flake it. Add a nightly schedule when the Lua modes exist.
- `tools/ci/check_perf.py` enforces `--p95-ms 16.6 --target-bullets N` and the optional `--baseline` regression check.
  Its exit code fails the job, and `bench.json` is uploaded as an artifact.

## 6. Deliverables and order
1. Spawner and stats collector (GDScript), JSON writer, `check_perf.py` (done).
2. Headless run in CI with the GDScript bullet mode. Record the first baseline.
3. Lua modes (spawn, per-bullet callback, sandbox abuse).
4. Windowed run on real hardware, documented in the release checklist.
5. Tighten the thresholds after 10+ CI runs show how noisy the runner is.

## Open questions
- Which bullet implementation (Node2D, `Area2D`, or `PhysicsServer2D`/`RenderingServer` direct)? It decides whether 10k is realistic.
- Which Lua binding (GDExtension such as godot-lua or LuaAPI, or custom)? It decides how per-bullet callbacks are measured.
