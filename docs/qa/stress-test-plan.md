# Bullet stress test plan

Goal: prove Scriptshot holds a **16.6 ms (60 FPS) p95 frame time** at **10,000 bullets (target)**, with **5,000 bullets as the hard floor**, and catch regressions in CI.
These are the agreed numbers: budget 16.6 ms (not 16.7), floor 5k, target 10k.
Status: the headless part exists on `main` (core scaffold, PR #2): `tests/benchmark/bullet_benchmark.tscn`, run via
`./tools/run_benchmark.sh --json=PATH`. The scene has the same policy built in: `--floor-bullets=5000` is a hard fail (exit 1 on a p95 miss, on a
count that was not benchmarked, or on a shortfall, i.e. fewer bullets alive than requested) and `--target-bullets=10000` only prints a WARN (exit 0),
both against `--target-ms=16.6`. CI runs it as the `perf` job with those flags, and `tools/ci/check_perf.py` stays the gate: it applies the same
floor/target policy to the JSON (`results[].work_p50_ms / work_p95_ms / work_p99_ms / reached / min_alive_before_step`), writes the step summary and
does the optional baseline check. Still missing: the windowed run,
dense-collision mode, and the Lua variants below (blocked on the Lua binding decision).

Gaps in the current benchmark (planned follow-ups):
- Bullets are scattered randomly (32 hurtboxes, 28 walls, a tenth of the bullets fast enough for the swept path), so there are few hits and no clustered collisions.
- No bullets with behaviour hooks (`behavior_id != 0`), which is the path Lua will use.
- The `RenderingServer` is the dummy one, so the MultiMesh upload cost is not measured.
- (Fixed in PR #2) A target count that is not benchmarked used to pass silently. It now fails, and `check_perf.py` also treats a missing count or `reached: false` as a floor failure or a 10k warning.

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
- Pass criterion: **p95 <= 16.6 ms**. At **5,000 bullets (floor)** a miss, or a missing result, **fails CI**. At **10,000 bullets (target)** a miss or missing result only emits a `::warning::` and a step-summary line. p99 is reported only.

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
- `perf` job in `.github/workflows/ci.yml` runs on every PR and push to main (about 15 s). 5k is a hard gate and 10k is warn-only (`tools/ci/check_perf.py`, unit-tested in `tools/ci/test_check_perf.py` and run in the same job).
  On a shared, loaded box 5k measured p95 4.5-8.6 ms and 10k 7.7-13.7 ms, so 5k has about 2x headroom and 10k is close to the budget, which is why it only warns. Add a nightly schedule when the Lua modes exist.
- `tools/ci/check_perf.py` enforces `--p95-ms 16.6 --floor-bullets 5000 --target-bullets 10000` and the optional `--baseline` regression check
  (5k regression fails, 10k regression warns). It appends the full table to `$GITHUB_STEP_SUMMARY`, and `bench.json` is uploaded as an artifact.
- **Hooked tier** (same `perf` job): a second run, `run_benchmark.sh --bullets=5000,10000 --hooked=1.0`, where every bullet carries a no-op `on_update` hook, so the per-bullet cost of `BulletPool.run_update_hooks` and its sanitize check is gated too (`reports/bench-hooked.json`, `check_perf.py --hooked-report`). **Hooked 5k p95 <= 22.0 ms fails CI, hooked 10k only warns** (`--hooked-target-ms 22.0`; 10k is judged against the same 22 ms). 22.0 ms is the hard gate. It is wider than the 16.6 ms real-device target because GitHub-hosted runners vary. Observed hooked 5k p95 values, each tied to a run id, are listed in `scripting/README.md`. Those samples include values under 22 ms and 22.65 ms on run 42272553748, which fails the gate. The numbers describe the runs that produced them. The phase split and the Gameplay Engineer follow-up (event-only bullets still pay the empty `on_update`) are in that same note. **16.6 ms stays the real-device target** (plain tiers keep it); revisit with a dedicated runner. The hooked check is strict: the report must have `hooked_fraction` 1.0, and a missing row or a missing / NaN / infinite / negative timing fails (5k) or warns (10k). The hooked/plain p95 ratio at 5k and 10k from the same run is logged, never gated (stdout, step summary, `reports/hooked-ratio.json` in the `perf-reports` artifact; `n/a` when a value is missing or zero).
- **Same-runner baseline (PRs).** GitHub-hosted runners differ by about 2x (plain 5k p95 7.4 ms on a fast host, 14-16 ms on a slow one, same sha; see `scripting/README.md`), so a fixed ms budget alone failed PRs that did not touch the sim (#35). On `pull_request` the `perf` job adds a git worktree of the base (the test-merge commit's first parent) and runs `tools/ci/perf_ab.sh`: plain and hooked tiers for base and head, alternating base, head, head, base (2 rounds, merged per count by `tools/ci/merge_bench.py`, median of the p95s). `check_perf.py --base-report/--base-hooked-report` then, per tier (plain bar 16.6 ms, hooked bar 22.0 ms) and count (5k hard, 10k warning): always applies a **relative check, head p95 <= base p95 x 1.10** with no millisecond slack (`--rel-tolerance-pct`); and checks the head's **raw p95 against the bar (`mode=raw`)**. Only when main's own raw p95 in the same job also misses that bar (the runner is provably slow) does that tier use **`mode=slow-runner`: head bar = bar x min(F, 1.5)**, with **F = base plain 5k p95 / 7.5 ms** (`REFERENCE_PLAIN_FLOOR_P95_MS`, main on a fast runner) clamped to >= 1.0, so at most 24.9 ms plain and 33.0 ms hooked (`--slow-runner-cap`). Push to `main`, `workflow_dispatch`, and a PR whose base run failed or printed NaN use `mode=raw` only (with a warning on a PR). The mode of every tier is printed in the log (`perf mode: ...`) and in the step-summary table (base, head, delta %, relative limit and verdict, mode, head bar, bar check, verdict). This replaces the "median-of-3 / retry" follow-up for PRs; the stored `vars.PERF_BASELINE` check is unchanged. The job budget is 30 min (4 benchmark pairs).
- **Native on_batch tier** (job `perf-native`, "Bullet benchmark (native on_batch, p95 gate)", after "Native libs (linux)"): `tools/ci/perf_ab.sh --tiers=onbatch,auto` runs `run_benchmark.sh --backend=native --batch=1 --bullets=5000,10000` with this run's `native-libs-linux.x86_64` artifact, for the same-run base (main on a PR, the parent commit on a push; the base reuses the head library when `native/`, `scriptshot_native.gdextension` and `tools/build_native.sh` are identical, else it is built from the base's sources) and the head, ABBA, 8 rounds at 600 frames (median per count). Both trees are benchmarked from equal-length paths ($RUNNER_TEMP/perf-head, $RUNNER_TEMP/perf-base): with the job's checkout as the head, A/A runs showed a steady per-tree offset (head/base 0.86 at 5k). On identical code the 5k p95 still varies 2.5-15% between rounds (processes) on the runner, with 600 or 2400 frames alike, so the per-round spread is not under 5%; the strict +10% check applies to the medians. The cold import gets one retry, only on a signal exit (128 < rc < 160), with a ::warning:: and the full crashed log (`tools/ci/cold_import.sh`, issue #69); nothing else retries. `check_perf.py` gates it with the same #42 rules on its own bars: **raw 6.0 ms at 5k (hard), 10.0 ms at 10k (warning)**; `mode=slow-runner` only when the base also misses, bar x min(F, 1.5) with **F = base on_batch 5k p95 / 2.0 ms** (`REFERENCE_NATIVE_ON_BATCH_FLOOR_P95_MS`); relative check head <= base x 1.10 always. The report must say `backend: native`, `batch: 1` (`--expect-backend/--expect-batch`), so a run whose library did not load fails instead of passing as GDScript. 6.0 x 1.5 = 9.0 ms < 10 ms, so a 10 ms 5k on_batch p95 (the regressed #63 head 1322ebcc) fails in every mode. The same job runs an informational `--backend=auto` row (plain bullets, 16.6 ms, warnings only; it fails only if auto did not resolve to native). The plain 16.6 / hooked 22.0 ms GDScript rows are unchanged. Calibration (PR #64, CI run 43200042914): main native on_batch 5k p95 1.79-2.00 ms, 10k 3.14-3.37 ms on ubuntu-24.04; bars about 3x that, reference = the observed 5k p95.
- **Exit-after-results guard** (`tools/run_tests.sh`, issue #41): once GUT has printed its grand-total line or "Results saved to", godot gets `GUT_EXIT_GRACE_S` (default 60) seconds to exit, then is killed. The kill (and the existing exit-134 allowance for the Lua shutdown abort) only counts as green when the console summary is green **and** the GUT junit XML exists, is non-empty, parses, and its `testsuites`/`testsuite` `failures` + `errors` sum to zero (`tools/ci/junit_green.py`). The run then passes with `::warning::godot did not exit after results (teardown hang, see #41)`; a missing, malformed or red junit fails. Without `-gjunit_xml_file`, `run_tests.sh` asks GUT for one in its temp dir; a stale file from an earlier process is deleted before each run. A hang before any results is not killed early (the job timeout still applies).

## 6. Deliverables and order
1. Spawner and stats collector (GDScript), JSON writer, `check_perf.py` (done).
2. Headless run in CI with the GDScript bullet mode. Record the first baseline.
3. Lua modes (spawn, per-bullet callback, sandbox abuse).
4. Windowed run on real hardware, documented in the release checklist.
5. Tighten the thresholds after 10+ CI runs show how noisy the runner is.

## 7. Real-hardware GPU measurement

Headless CI cannot see the GPU, and GitHub-hosted runners have none (only software rendering), so GPU cost needs real devices.
This section is the plan. Nothing here is implemented yet, and the GPU-timing API behaviour in the Compatibility renderer is unverified (see step 0).

### 7.1 What to run and where
- **Build:** a **release export** (release template, not the editor and not a debug build) of a dedicated `Benchmark` export preset.
  The preset must include `res://tests/benchmark/*`, or the benchmark scene is missing from the exported `.pck`.
  The scene is started with `./scriptshot res://tests/benchmark/bullet_benchmark.tscn -- --bullets=2000,5000,10000 ...`.
- **Window:** a real window, 1280x720, **vsync off** (`--disable-vsync`, or `DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)`),
  so frame time shows the true cost instead of being snapped to the refresh interval. Also run once with vsync on to check for missed frames.
- **Reference matrix** (proposal, to be confirmed against the devices Karyu actually has):

| Slot | Example hardware | Build | Expectation (proposed) |
|---|---|---|---|
| Low-end iGPU | Intel Iris Xe / UHD laptop, or AMD Vega-class iGPU | Win or Linux release | 5k floor must pass. 10k is informational until baselined. |
| Mid dGPU | e.g. GTX 1660 / RTX 3050 / RX 6600 class | Win or Linux release | 5k floor and 10k target both expected to pass. |
| Steam Deck-class | Steam Deck (LCD or OLED), SteamOS, native Linux build | Linux release | 5k floor must pass. 10k is the target. |
| Web | Chrome and Firefox (desktop, mid dGPU) on the Web export | Web release | 5k floor must pass. Run the same export preset that ships (threads or no threads), since it changes CPU cost. |

### 7.2 What to measure per frame
Collect per-frame series (after a warm-up), then compute p50/p95/p99/max for each:
- **Frame time (wall):** the interval between consecutive frames, with vsync off.
- **CPU render time and GPU render time:** call `RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)`, then read
  `RenderingServer.viewport_get_measured_render_time_cpu(rid)` and `RenderingServer.viewport_get_measured_render_time_gpu(rid)` (both in ms).
  Note: there is no `get_viewport_render_time_gpu` in the 4.7 API. The real names are the two above.
  The values describe the previous frame, so sample them in `RenderingServer.frame_post_draw`. Also read `RenderingServer.get_frame_setup_time_cpu()`.
- **Sim work (existing):** `BulletManager.step()` time, kept as `work_*`.
- **Performance monitors:** `Performance.TIME_FPS`, `RENDER_TOTAL_DRAW_CALLS_IN_FRAME`, `RENDER_TOTAL_PRIMITIVES_IN_FRAME`, `RENDER_VIDEO_MEM_USED`, `MEMORY_STATIC`.
- **Budget check:** p95 of frame time <= 16.6 ms (vsync off), and report p95 GPU separately, because a frame can be CPU- or GPU-bound.
- **Step 0 (spike, before anything else):** the project uses the **GL Compatibility** renderer. Confirm on each reference GPU that
  `viewport_get_measured_render_time_gpu` returns non-zero values there. If it returns 0, record `gpu_supported: false` and use frame time with vsync off
  as the GPU proxy, plus an external profiler (RenderDoc, vendor tools, `MANGOHUD`/`GALLIUM_HUD` on the Deck) for spot checks.

### 7.3 What the benchmark script needs added (`tests/benchmark/bullet_benchmark.gd`)
1. **A visible scene when windowed:** a `Camera2D` framing the 2560x1440 arena (or a 1280x720 view), so the MultiMesh is actually drawn. Today it is a bare node tree.
2. **Real frame loop:** a `--windowed` mode (auto-detect via `DisplayServer.get_name() != "headless"`) that steps with the engine delta in `_physics_process`
   and samples render times in `RenderingServer.frame_post_draw`, instead of calling `step(FIXED_DELTA)` from `_process`.
3. **New args:** `--vsync=on|off`, `--label=<device id>`, `--commit=<sha>`, `--seconds=N` (alternative to `--frames`), `--bullets=...` (exists).
4. **Output `perf.json` schema v2**, keeping the existing `results[].work_*` keys so `check_perf.py` keeps working:
   - `schema: 2`, `label`, `commit`, `timestamp_utc`, `build` (`release`/`debug`, from `OS.has_feature("template_release")`), `mode` (`headless`/`windowed`).
   - `env`: `godot` (`Engine.get_version_info()`), `os` (`OS.get_name()`, `OS.get_version()`), `cpu` (`OS.get_processor_name()`, `OS.get_processor_count()`),
     `renderer` (`RenderingServer.get_current_rendering_method()`, `get_current_rendering_driver_name()`),
     `gpu` (`get_video_adapter_name/vendor/type/api_version()`), `screen` (size, `DisplayServer.screen_get_refresh_rate()`), `window`, `vsync`.
   - per count: `frame_p50/p95/p99/max_ms`, `gpu_p50/p95/p99_ms`, `render_cpu_p50/p95/p99_ms`, `gpu_supported`, `draw_calls`, `alive_at_end`.
5. **Verdicts:** keep the headless `work_p95` check, and add a windowed check on `frame_p95` against 16.6 ms. Exit code 1 on a floor miss only.
6. **Web variant:** read args from the URL query string (`JavaScriptBridge.eval("window.location.search")`) and hand the JSON to the tester with
   `JavaScriptBridge.download_buffer(...)`, because there is no command line or filesystem.
7. **Unit tests (GUT):** percentile/series helpers for the new metrics, and a schema test that checks every required key is present in the JSON.

### 7.4 How results are collected
- **Manual run (default):** a script `tools/run_gpu_bench.sh` exports the `Benchmark` preset, runs the three counts, and writes
  `reports/gpu/<label>.json`. A person runs it on each device and attaches the JSON to the PR, or commits it under `docs/qa/results/`.
- **Optional `workflow_dispatch` workflow** (`gpu-bench.yml`) on a **self-hosted runner** with labels like `[self-hosted, linux, gpu, mid-dgpu]`,
  which runs the same script and uploads `reports/gpu/*.json` as an artifact. Sketch of the trigger and guard:
  ```yaml
  on: { workflow_dispatch: { inputs: { label: { required: true, type: string } } } }
  jobs:
    gpu-bench:
      runs-on: [self-hosted, gpu]
      environment: gpu-bench   # protected environment: required reviewer
      steps: [checkout, download pinned Godot + templates, tools/run_gpu_bench.sh, upload-artifact]
  ```
  Security: a self-hosted runner on a public repo must **never** run fork PR code. Keep it `workflow_dispatch`-only, on a protected environment,
  and never trigger it from `pull_request`.
- **Baselines per device:** `docs/qa/baselines/<label>.json`, where `<label>` is a stable slug such as `win11-rtx3050-compat` or `steamdeck-oled-sos`.
  Only change a baseline deliberately, in a PR that says why.
- **Comparison:** extend `check_perf.py` with `--metric frame_p95_ms|gpu_p95_ms` and `--baseline docs/qa/baselines/<label>.json`.
  Fail on the floor miss, warn on a regression above 15% (hardware is steadier than shared runners, but Deck thermals and laptop power modes still add noise).
  Record the power mode and charger state in the run notes. Run each count 3 times and take the median of the p95 values.

### 7.5 Order of work
1. Step 0 spike: does the GPU timing return real values under Compatibility on the mid dGPU and the Deck?
2. Windowed mode, camera and schema v2 in the benchmark, plus its GUT tests.
3. `Benchmark` export preset (needs `export_presets.cfg` committed) and `tools/run_gpu_bench.sh`.
4. First baselines on the four reference slots. Then set which slots gate and which only inform.
5. Optional self-hosted workflow, once one stable always-on GPU machine exists.

## Open questions
- Which bullet implementation (Node2D, `Area2D`, or `PhysicsServer2D`/`RenderingServer` direct)? It decides whether 10k is realistic.
- Which Lua binding (GDExtension such as godot-lua or LuaAPI, or custom)? It decides how per-bullet callbacks are measured.
