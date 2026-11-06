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
callback keeps mask 0, and `apply_to_request()` leaves `behavior_id` at 0 so
the bullet stays declarative.

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

PR #20 (run [42270990021](https://github.com/Karyu42/scriptshot/actions/runs/42270990021),
ubuntu-24.04):

| bullets | plain work p95 | hooked work p95 | ratio | hooks+walls mean, plain → hooked |
| ---: | ---: | ---: | ---: | --- |
| 5,000 | 13.63 ms | 20.64 ms | 1.51× | 2.91 → 9.20 ms |
| 10,000 | 27.14 ms | 41.42 ms | 1.53× | 5.80 → 18.41 ms |

20.64 ms is under the 22 ms gate. The same job on `main` before this host:

| merge | hooked 5k p95 | plain 5k p95 | ratio | hooks+walls delta at 5k |
| --- | ---: | ---: | ---: | ---: |
| #16 | 13.90 ms | 8.80 ms | 1.58× | 4.67 ms |
| #15 | 14.65 ms | 9.10 ms | 1.61× | 5.17 ms |
| #18 | 16.34 ms | 10.51 ms | 1.55× | 5.17 ms |
| #19 | 19.39 ms | 12.00 ms | 1.62× | 6.85 ms |
| #17 | 20.83 ms | 13.01 ms | 1.60× | 7.26 ms |
| #20 | 20.64 ms | 13.63 ms | 1.51× | 6.29 ms |

Plain 5k p95 moved with the runner (8.80–13.63 ms). The hooked/plain ratio stayed
about 1.5–1.6×. PR #17, with no Lua host, already printed 20.83 ms. A 20 ms
reading is runner noise around that ratio, and it is not a CI gate.

A short headless run on the follow-up machine (Godot 4.7.2, 20 warmup + 100
measured frames) has the same shape at 5,000 bullets: plain work p95 7.93 ms
with hooks+walls 1.74 ms, hooked work p95 11.71 ms with hooks+walls 5.45 ms
(ratio 1.48×). Hurtboxes and the render fill stayed put. The absolute p95 is
the machine; the added time is the hook phase.

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
