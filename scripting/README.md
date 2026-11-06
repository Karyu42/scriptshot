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

## Deferred

The rest of the shot API (`spawn {}`, `wait`, the player proxy, the capability
prompt, the batch view, hot reload) and the 47 adversarial cases. The 64 MB
cap is soft on this binary: the hook samples it every 1,000 instructions. A
hard cap needs the source-built binding, which is behind the godot-cpp fork
and is not part of M1.

A bullet whose script defines an event hook still has `behavior_id ~= 0`, so
the engine calls the empty `on_update` every tick and the bullet pays the
hooked-path cost. Skipping that for event-only scripts needs an engine change.

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
