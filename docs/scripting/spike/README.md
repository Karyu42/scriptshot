# Spike material

Throwaway benchmark code, a self-contained Godot 4.7.2 project and raw output behind [../spike-results.md](../spike-results.md)
and [../testing.md](../testing.md). **Not part of the game.** This folder is its own Godot project (`project.godot`), so the parent
project does not import it. Binaries are never committed: `addons/`, `*.so`, `*.apk`, `*.wasm`, `out*/` are git-ignored.

To run it: copy this folder out of the repo, put the pinned lua-gdextension 0.8.2 addon (Lua 5.4 zip, SHA256
`51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443`) into `addons/lua-gdextension/`, then
`godot --headless --path . -- <bench>` where `<bench>` is a file name in `bench/` (default `calls`).

- `project.godot`, `main.tscn`, `runner.gd` (picks the bench from the first user argument; on web/mobile it starts `export_bench`),
  `smoke.gd`, `explore.gd`, `syn.gd` (syntax check of the example scripts: `godot --headless --path . -s syn.gd`).
- `bench/` GDScript benchmark nodes: `adversarial.gd` (the B4 suite, 47 cases), `hooks_pr.gd` (the A/B/C hook matrix),
  `view_shapes.gd` (batch-view wrapper overhead, spike-results.md 8.2), `export_bench.gd` (the 1,000-bullet scene that prints
  `SPIKE_RESULT {json}` lines; Android/web), `calls.gd`, `bullets.gd`, `hook.gd` (incl. the #240 churn, section d2), `spike_manager.gd`
  and `lua_behavior.gd` (hook harness), `stats.gd`.
- `src/` the bullet pool/manager/emitter **modelled on PR #2** (the code the hook matrix ran against; PR #2 is now on `main`, this copy was taken from its then head and not re-diffed).
- `sandbox/sandbox.lua` the G1 environment builder (capabilities, wrappers, confined `require`, trimmed `debug`); `scripts/` the export-proof
  script (`steer.lua`) and the `require` test modules (`mod_a.lua`, `sub/mod_b.lua`).
- `run_adv.sh <naive|g1> [timeout]` one process per adversarial case, with heartbeat and timeout (`GODOT=/path/to/godot`).
- `export_presets.cfg` presets for Linux, Web (threads, no-threads) and **Android (arm64-v8a + x86_64, non-gradle)**; no secrets, the debug keystore comes from the editor settings.
- `patches/lua-gdextension-0.8.2-godot-cpp-507ed9d.patch` the minimal patch that lets lua-gdextension 0.8.2 build against godot-cpp 10.0.0-stable with `api_version=4.6` (spike-results.md section 12).
- `results/` raw output: `adv_g1.txt` (47 cases, stock 0.8.2), `adv_g1_source_build_46api.txt` (same cases on the source build), `adv_naive.txt`,
  `hooks_pr_*.txt`, `hook_editor.txt` (contains the #240 churn, section d2), `view_shapes_*.txt`, `export_bench_headless_editor.txt`
  (the `SPIKE_RESULT` format), `web_*.txt`, ... Release-template numbers unless the name says `editor`.
