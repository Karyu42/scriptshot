# scripting/

Lua player scripting. The Godot core never depends on this folder. Shots reach
the game through `ShotRequest`, `ShotEmitter` and `BulletBehavior`.

## M1 slice

Stock [lua-gdextension 0.8.2](https://github.com/gilzoide/lua-gdextension/releases/tag/0.8.2)
(Lua 5.4). `tools/ci/fetch_native_libs.sh` downloads the release zip and checks
SHA256 `51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443`.
The binaries stay gitignored. The same script pre-seeds
`.godot/extension_list.cfg` before the first import, which is the cold-import
workaround tracked in [issue #7](https://github.com/Karyu42/scriptshot/issues/7).

`ScriptHost` loads a Lua string or file and runs it in a host-owned coroutine.
The count hook returns `HOOK_YIELD` when the instruction budget (100,000), the
50 ms wall clock, or the soft 64 MB memory cap trips. A yield is not an error,
so `pcall` cannot swallow it. A script error comes back on the result; the
previous weapon stays loaded and the game keeps running.

`LuaBulletBehavior` overrides the four event hooks so it can forward them. It
sets `hook_mask` with `BulletBehavior.mask_from_names()` from the functions
that script defines, and `hook_mask_exact = true`. A script with no event
callback and no `on_batch` keeps mask 0, and `apply_to_request()` leaves
`behavior_id` at 0 so the bullet stays declarative. `on_batch` sets
`update_mode` to `BATCH`.

`on_batch(v, dt)` is one call per tick with every live bullet of that script.
The columns are packed copies. These six are current behaviour and may be
extended later (the player-facing writeup is `docs/scripting/api.md`, *Current
behaviour*):

1. Every tick, every live bullet. No `update_interval` or `update_slice`.
2. No reflect command on `v`. Use `reflect_bullet()`.
3. `v:spawn_child(i, x, y, vx, vy, life)` only. The child is declarative.
4. `px`, `py`, `age`, `id` and `owner` are read-only. Writing one raises. Move with `v:teleport`.
5. Overriding `on_update` keeps the bullet per-bullet on the pool, unless
   `update_mode` is `BATCH`.
6. A bullet spawned inside a hook stays on the pool for its whole life.

A script error in `on_batch` commits nothing. Zero-copy is off; see
`docs/native.md`.

Per call the engine keeps the first 4096 commands and the first 256
`spawn_child` calls (`BatchView.CMD_CAP`, `BatchView.SPAWN_CAP`). The rest are
dropped and one warning is logged. The `on_batch` instruction budget is
100,000 plus 128 per row, capped at 2,000,000. The 50 ms wall clock and the
64 MB memory cap still apply. These limits are provisional and may change.
A hot reload that adds `on_batch` does not affect bullets already spawned
with `behavior_id` 0.

Velocity commits through `BulletPool.set_velocity` (clamped to
`BulletLimits.MAX_SPEED`, 4,000). A non-finite velocity kills the bullet with
`DespawnReason.INVALID` and counts in `invalid_total`. Child spawns commit
through `ShotEmitter.request_child_shot_id` after the callback returns, and
only when the callback returned. Those children are plain bullets.

```lua
return {
  on_spawn = function(b)
    b:set_velocity(120, 0)
    b:spawn_child(b.x + 8, b.y, 40, 0, 1.5)  -- x, y, vx, vy, lifetime
  end,
  on_hit = function(b, hit) end,    -- hit.damage, hit.x, hit.y
  can_hit = function(b, hit) return true end,
  on_death = function(b, why) end,  -- also on_expire, on_wall, on_despawn
}
```

`b.id`, `b.x` and `b.y` are a snapshot taken when the callback starts. `why` is
`lifetime`, `bounds`, `hit`, `manual`, `cleared`, `wall` or `invalid`.

## Hook cost

The CI hooked tier is `./tools/run_benchmark.sh --bullets=5000,10000 --hooked=1.0`.
Every bullet uses `NoopHook` in `tests/benchmark/bullet_benchmark.gd`, a GDScript
`on_update` that returns immediately. The gate is work p95 at 5,000 bullets,
hard-fail at 22 ms (`--hooked-target-ms` in the `perf` job). PR #20 did not edit
`BulletPool.run_update_hooks` or `BulletManager.step`. The job now loads stock
lua-gdextension because `run_benchmark.sh` fetches it; that process still runs
the same GDScript hook.

Each row is one Actions run, taken from that run's `perf-reports` artifact
(`bench.json` and `bench-hooked.json`). Work p95 is the 5,000-bullet `FLOOR`
line. hooks+walls is the phase-mean line for that same count. The ratio is
hooked p95 divided by plain p95. A `pull_request` run and the later push of
the same PR to `main` are different machines. These are observations of those
runs. The 22 ms hard gate is unchanged. Samples here have printed under 22 and over it (22.65 ms on run
42272553748, 22.56 ms on run 42273854230, 22.77 ms on run 42274284985).

| run | event | plain 5k p95 | hooked 5k p95 | ratio | hooks+walls mean, plain → hooked |
| --- | --- | ---: | ---: | ---: | --- |
| [41917411499](https://github.com/Karyu42/scriptshot/actions/runs/41917411499) | #15 pull_request | 12.42 ms | 19.57 ms | 1.58× | 3.09 → 10.02 ms |
| [41922925381](https://github.com/Karyu42/scriptshot/actions/runs/41922925381) | #15 push `main` | 9.10 ms | 14.65 ms | 1.61× | 2.20 → 7.37 ms |
| [42264181982](https://github.com/Karyu42/scriptshot/actions/runs/42264181982) | #16 pull_request | 8.92 ms | 14.47 ms | 1.62× | 2.19 → 7.06 ms |
| [42264668172](https://github.com/Karyu42/scriptshot/actions/runs/42264668172) | #16 push `main` | 8.80 ms | 13.90 ms | 1.58× | 2.19 → 6.86 ms |
| [42264708047](https://github.com/Karyu42/scriptshot/actions/runs/42264708047) | #17 pull_request | 12.58 ms | 19.27 ms | 1.53× | 3.19 → 9.79 ms |
| [42265409035](https://github.com/Karyu42/scriptshot/actions/runs/42265409035) | #17 pull_request | 6.29 ms | 9.93 ms | 1.58× | 1.57 → 5.01 ms |
| [42265856711](https://github.com/Karyu42/scriptshot/actions/runs/42265856711) | #17 push `main` | 13.01 ms | 20.83 ms | 1.60× | 3.37 → 10.63 ms |
| [42269500507](https://github.com/Karyu42/scriptshot/actions/runs/42269500507) | #18 pull_request | 10.09 ms | 15.21 ms | 1.51× | 2.28 → 7.14 ms |
| [42270340021](https://github.com/Karyu42/scriptshot/actions/runs/42270340021) | #18 push `main` | 10.51 ms | 16.34 ms | 1.55× | 2.19 → 7.36 ms |
| [42266273686](https://github.com/Karyu42/scriptshot/actions/runs/42266273686) | #19 pull_request | 12.34 ms | 19.29 ms | 1.56× | 3.06 → 9.45 ms |
| [42267787371](https://github.com/Karyu42/scriptshot/actions/runs/42267787371) | #19 push `main` | 12.00 ms | 19.39 ms | 1.62× | 2.85 → 9.70 ms |
| [42270990021](https://github.com/Karyu42/scriptshot/actions/runs/42270990021) | #20 pull_request | 13.63 ms | 20.64 ms | 1.51× | 2.91 → 9.20 ms |
| [42271561141](https://github.com/Karyu42/scriptshot/actions/runs/42271561141) | #20 push `main` | 13.33 ms | 20.13 ms | 1.51× | 2.95 → 9.18 ms |
| [42272553748](https://github.com/Karyu42/scriptshot/actions/runs/42272553748) | #22 pull_request | 14.90 ms | 22.65 ms | 1.52× | 3.49 → 10.62 ms |
| [42273854230](https://github.com/Karyu42/scriptshot/actions/runs/42273854230) | #22 pull_request | 14.93 ms | 22.56 ms | 1.51× | 3.46 → 10.39 ms |
| [42274284985](https://github.com/Karyu42/scriptshot/actions/runs/42274284985) | #22 pull_request | 14.90 ms | 22.77 ms | 1.53× | 3.11 → 10.33 ms |

Run 42270990021 also printed 10,000 bullets: plain work p95 27.14 ms, hooked
41.42 ms, hooks+walls 5.80 → 18.41 ms. On the samples in this table the
hooked/plain ratio was 1.51× to 1.62×. Runs 42272553748 (`82fb776`),
42273854230 (`8f14bfd`) and 42274284985 (`4619271`) are this branch:
documentation and one GUT test. The perf job still runs `NoopHook`. Those
samples printed hooked 5k p95 22.65 ms, 22.56 ms and 22.77 ms. On each one the
p50 was also over 22 ms (22.23, 22.16, 22.33). Plain 5k p95 was 14.90 ms,
14.93 ms and 14.90 ms, and the ratios were 1.52×, 1.51× and 1.53×. The diff
does not edit `BulletPool.run_update_hooks`, `BulletManager.step`, or the
benchmark scene. Each of those three samples is a separate runner.

The 20 ms figure is a soft bar. `check_perf.py` does not enforce it. The 22 ms
figure is the hard gate on this job.

**Same-runner baseline (pull requests).** The samples above show the runner, not
the code, moving the numbers: plain 5k p95 from 6.29 to 14.93 ms on the same
code, and a docs-only branch over 22 ms. On #35 (no sim change) slow hosts printed
hooked 5k 22.2-23.5 ms while fast hosts printed 11.5 ms for the same sha. So on a
`pull_request` the `perf` job also checks out main (the test-merge commit's first
parent) and benchmarks it in the same job on the same runner, alternating
base, head, head, base (`tools/ci/perf_ab.sh`, 2 rounds merged by
`tools/ci/merge_bench.py`). `check_perf.py` then applies, at 5,000 bullets
(hard) and 10,000 (warning only):

- a relative check, always: head p95 <= base p95 x 1.10, plain and hooked, with
  no millisecond slack (`--rel-tolerance-pct 10`);
- the bars (plain 16.6 ms, hooked 22 ms) on the head's raw p95 (`mode=raw`).
  Only when main's own p95 in the same job also misses a bar (the runner is
  provably slow) does that tier switch to `mode=slow-runner`: the head bar
  becomes bar x min(F, 1.5), where F = base plain 5k p95 / 7.5 ms, clamped to
  >= 1.0, so at most 24.9 ms plain and 33.0 ms hooked
  (`REFERENCE_PLAIN_FLOOR_P95_MS` in `check_perf.py`, main on a fast
  ubuntu-24.04 runner; `--slow-runner-cap 1.5`). A runner on which main meets
  the bar never gets a looser bar.

A push to `main`, a `workflow_dispatch` run, or a PR whose base run failed or
printed NaN has no usable base: `mode=raw` and the 16.6 / 22 ms bars only, as
before. The log prints `perf mode: <tier> <count>: mode=...` for every tier, and
the step summary starts with a table of base p95, head p95, delta %, the
relative limit and verdict, the mode, the head bar and the bar check per tier
and count.

A short headless run on the follow-up machine (Godot 4.7.2, 20 warmup + 100
measured frames) printed, at 5,000 bullets, plain work p95 7.93 ms with
hooks+walls 1.74 ms, and hooked work p95 11.71 ms with hooks+walls 5.45 ms
(ratio 1.48×). Hurtboxes and the render fill stayed put on that sample. The
added time was the hook phase.

On the PR #20 runner the 5,000-bullet split is: `advance` lists every
`behavior_id != 0` (2.01 → 2.45 ms) and `run_update_hooks` calls `on_update`,
runs the inlined field check, then one `sweep_cross_writes` (hooks+walls
2.91 → 9.20 ms, about 1.3 µs per bullet). `LuaBulletBehavior` does not override
`on_update` and does not call `ScriptHost.call_hook` from the tick, so the G1
`HOOK_YIELD` hook, the coroutine and the bullet table are outside this number.
A script with no event callback keeps mask 0 and `behavior_id` 0 and stays off
the list (`test_a_script_with_no_event_hook_stays_a_plain_bullet`).

An event-only script (`on_spawn`, `on_hit`, `can_hit`, `on_death` and the other
despawn names) still has `behavior_id != 0`. `HOOK_*` covers those four event
hooks only. `BulletPool.advance` puts the bullet on the hooked list and
`run_update_hooks` calls the empty base `on_update` every tick. There is no
flag on `BulletBehavior` that skips that call. Leaving event-only bullets off
the per-tick path, while a behaviour that overrides `on_update` still pays it,
is a Gameplay Engineer change. This adapter keeps `mask_from_names` and
`hook_mask_exact`, and does not set `HOOK_ALL`.

## Deferred

The rest of the shot API (`spawn {}`, `wait`, the player proxy, the capability
prompt, the batch view, hot reload) and the 47 adversarial cases. The 64 MB
cap is soft on this binary: the hook samples it every 1,000 instructions. A
hard cap needs the source-built binding, which is behind the godot-cpp fork
and is not part of M1.

`ScriptHost` keeps every Lua state alive until the process exits. Freeing one
state after another state that called into Godot has already been freed
crashes stock lua-gdextension, and freeing a host after a callback was stopped
by the instruction hook crashes the same binary (lua-gdextension #240). A
session that loads a handful of weapons stays inside that budget. `can_hit`
returns its boolean directly; the host is not freed during the session, which
is what keeps a `false` return from hitting the same free crash. Process exit
can still abort after a green suite. That is the shutdown `run_tests.sh`
accepts below.

## Tests

`./tools/run_tests.sh` fetches the addon if needed, pre-seeds the extension
list, then runs GUT. The budget tests and the bullet-hook tests run in
separate processes: shutting down both in one process aborts inside the stock
extension. A green suite can still abort while Godot releases the Lua states;
`run_tests.sh` treats that exit as success when the summary is green and the
log has no in-suite crash. A green summary is `All tests passed`, or
`N pending/risky tests` when the only leftovers are pending native stubs.
