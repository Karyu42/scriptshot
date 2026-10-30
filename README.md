# Scriptshot

A top-down 2D twin-stick shooter built in Godot 4 where you **script your own
shots in Lua**. MIT licensed.

> Status: early foundation. The Godot core (player, bullet system, camera,
> tests) is in place; the Lua binding is developed separately in `scripting/`.

## Requirements

* **Godot 4.7.2 stable** (standard build, not .NET). Download from
  <https://github.com/godotengine/godot/releases/tag/4.7.2-stable>.
* Put the editor binary on your `PATH` as `godot`, or point `$GODOT` at it
  (`export GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64`). The scripts in
  `tools/` use `$GODOT` if set and `godot` otherwise.

## Run

```sh
godot --path .            # runs scenes/main.tscn
# or open project.godot in the Godot editor and press F5
```

| Action | Mouse + keyboard | Gamepad |
| --- | --- | --- |
| Move | `W` `A` `S` `D` | Left stick |
| Aim | Mouse (relative to the ship on screen) | Right stick |
| Fire | Left mouse button | Right trigger |
| Dash (0.2 s invulnerable, 1.5 s cooldown; toward the move direction, or the aim direction when standing still) | `Space` or `Shift` | `B` / Right bumper |
| Bullet stress test on/off | `F1` | Back / Select |
| Cycle stress target (2k / 5k / 10k) | `F2` | `Y` / Triangle |

The input device switches automatically on the last thing you touched. The HUD
shows FPS, live bullet count and the bullet simulation cost per tick.

## Test

Unit and smoke tests use [GUT](https://github.com/bitwes/Gut) 9.7.1 (vendored in
`addons/gut`). One command, headless, non-zero exit code on failure:

```sh
./tools/run_tests.sh
```

It imports the project (first run only needs a few seconds) and runs
`tests/unit/`. Import, parse and compile errors fail the run (GDScript untyped
and unsafe-access warnings are project-level errors; `tests/unit/test_project_integrity.gd`
loads every script). Run a subset with `./tools/run_tests.sh -gselect=bullet_pool`.
The raw command is:

```sh
godot --headless --path . --import          # once per fresh clone
godot --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit
```

## Benchmark

Headless bullet benchmark: keeps N bullets alive, runs the full simulation tick
(kinematics, swept collision against 32 hurtboxes and 28 walls, despawn/respawn
churn, interpolated render buffer fill) and reports p50/p95/p99/max per-frame
cost at 5000 and 10000 bullets against a budget of **p95 <= 16.6 ms** (60 fps).
Two checks, with different consequences:

* **Floor, 5,000 bullets** (`--floor-bullets`): a hard gate. A miss, or a run that
  never actually had 5,000 bullets alive, prints a `FLOOR  FAIL` line and exits 1.
* **Target, 10,000 bullets** (`--target-bullets`): a goal. A miss prints
  `TARGET WARN` plus a `WARN` line and still exits 0, since 10k p95 depends on how
  busy the machine is.

```sh
./tools/run_benchmark.sh                                     # 5000 (floor) and 10000 (target)
./tools/run_benchmark.sh --bullets=2000,5000,10000,20000 --frames=1200
./tools/run_benchmark.sh --floor-bullets=5000 --target-bullets=10000
./tools/run_benchmark.sh --json=/tmp/bench.json
```

Exit code 1 means the floor was missed or never reached, or the project failed
to compile; a missed 10k target alone exits 0 (with a WARN). Headless mode uses a dummy renderer, so
the numbers cover CPU-side simulation and buffer preparation, not GPU time.
To include a real renderer run it windowed:
`godot --path . res://tests/benchmark/bullet_benchmark.tscn -- --bullets=5000,10000`.

## Exports

`export_presets.cfg` is committed (it holds no credentials; `export_credentials.cfg`
stays ignored) with the presets `Windows Desktop`, `macOS`, `Linux` and `Web`, all
exporting into the git-ignored `build/` directory, e.g.
`godot --headless --path . --export-release Linux build/linux/Scriptshot.x86_64`.
macOS is unsigned and not notarized; the Web preset uses the no-threads template.

## Project layout

```
src/{core,player,bullets,enemies,world,camera,fx}/   game code (GDScript)
scenes/                                               main.tscn, player.tscn, ...
tests/{unit,benchmark}/                               GUT tests, benchmark
scripting/                                            reserved for the Lua side
docs/architecture.md                                  design + the shot interface
tools/                                                test / benchmark runners
addons/gut/                                           vendored GUT 9.7.1
```

How shots are fired (and what Lua scripts will drive) is documented in
[`docs/architecture.md`](docs/architecture.md). Contributor notes are in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

MIT, see [LICENSE](LICENSE). Vendored GUT is MIT (`addons/gut/LICENSE.md`).
