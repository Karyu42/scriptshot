# Playtest autoplay

QA-only autoplay for the first-playable combat path. It is not a shipping
scene: every release preset excludes `src/qa/*`, the same way `web_smoke.tscn`
is kept out of player builds.

## What it covers

The script (`src/qa/playtest_autoplay.gd`) instances the real `scenes/main.tscn`
and drives it with scripted input. Checks come from
[`docs/design/first-playable-elites.md`](../design/first-playable-elites.md)
(L0–L2, the path that is on `main`) and, when those nodes exist, from
[`docs/design/vertical-slice.md`](../design/vertical-slice.md):

* Cold start at the origin, no hostile inside the 512 px safe disk.
* The three origin dummies at `(300, 0)`, `(-150, 260)`, `(-150, -260)` are
  plain 40 HP targets (the shielded dummy belongs in room A of the vertical
  slice, and is not required here).
* A Lua shot fires through ScriptHost (`LuaBulletBehavior.load_file`). On
  `main` the equipped weapon is still `BasicShot`; `shots/default.lua` is
  not wired yet.
* Leaving the disk arms the Herald. The public `HeraldDirector.advance`
  API jumps the `[58, 78)` clock. The Herald dies, `herald_done` is set,
  and `shards` increases by 1.
* A T0 regular (not an elite) in the stream dies, and `regular_absent` updates.
* `Health.try_damage` applies a hit, engine i-frames block the next, a lethal
  hit kills the player, and they respawn after `Main.respawn_delay` (1.5 s)
  with full HP. Until a Warden kill exists, that respawn is the origin.
* Live bullets return to the pool. A script error fails the run.

## What it does not assert

The vertical-slice ribbon (rooms S–E, lesson gates, field packs, the rare
elite, the Warden) is a content spec and is not on `main` yet. If
`SliceLayout` or a Warden is in the tree, the run prints
`PLAYTEST_SLICE_LAYOUT present` and continues. **Arena placement is
provisional (vertical-slice.md Q26).** This autoplay never hard-asserts the
arena centre, chunk, aggro line, or post-kill respawn point.

The Herald redirect into room C at `(4700, 180)` is also not asserted: that
clamp lands with the ribbon.

## How to run it

Linux, headless editor:

```
./tools/ci/playtest.sh
```

Web, after a `Web (playtest)` export, in headless Chromium:

```
./tools/ci/playtest.sh --web
```

CI runs the Linux job as **Playtest autoplay (headless Linux)**. It is not a
required check. The `playtest` feature override
(`application/run/main_scene.playtest`) is what lets the release web template
boot this scene; a scene path on the command line is refused.
