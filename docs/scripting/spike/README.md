# Spike material

Throwaway benchmark code and raw output behind [../spike-results.md](../spike-results.md). **Not part of the game.** The
folder has a `.gdignore`, so Godot does not import it.

- `bench/` GDScript benchmark nodes (`adversarial.gd` = the B4 suite, `hooks_pr.gd` = the A/B/C hook matrix, `calls.gd`,
  `bullets.gd`, `hook.gd`, ...). They were run in a separate Godot 4.7.2 project with lua-gdextension 0.8.2 and (for
  `hooks_pr.gd`) a copy of PR #2's `BulletManager`/`BulletPool`; to rerun, copy them into such a project.
- `sandbox/sandbox.lua` the G1 environment builder (capabilities, wrappers, trimmed `debug`); `sandbox/steer.lua` the export-proof script.
- `run_adv.sh <naive|g1> [timeout]` one process per adversarial case, with heartbeat and timeout.
- `results/` raw output (`adv_*.txt`, `hooks_pr_*.txt`, `web_*.txt`, ...), release-template numbers unless the name says `editor`.
