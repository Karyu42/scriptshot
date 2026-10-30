# Contributing

## Tooling

* **Godot 4.7.2 (stable), exactly.** `project.godot` targets 4.7 and the vendored
  test framework is GUT 9.7.1; other Godot versions are not supported.
* **Installing:** download the matching Linux/macOS/Windows build from
  <https://github.com/godotengine/godot/releases/tag/4.7.2-stable>. Either put it
  on your `PATH` as `godot`, or point `$GODOT` at the binary:

  ```sh
  export GODOT=/path/to/Godot_v4.7.2-stable_linux.x86_64
  ```

  `tools/run_tests.sh` and `tools/run_benchmark.sh` use `$GODOT` if set and
  `godot` from `PATH` otherwise.

## Workflow

* Never push to `main`. Branch from `main` (`feat/...`, `fix/...`) and open a PR.
* Run `./tools/run_tests.sh` before pushing; it must pass. Add tests for new
  logic, especially anything in the bullet system or movement math.
* If you touch the bullet loop, run `./tools/run_benchmark.sh` and include the
  p50/p95 numbers in the PR. Floor (hard gate): 5,000 bullets at p95 <= 16.6 ms; target (warning only): 10,000 bullets, with walls present.
* Commit the `.uid` files Godot generates next to scripts and `.import` files
  next to assets; do not commit `.godot/`.
* GDScript style: static typing everywhere. `untyped_declaration` and the
  `unsafe_*` warnings are errors in `project.godot` (vendored `addons/` are
  exempt); a script that does not compile fails `./tools/run_tests.sh`. In tests
  use typed locals (GUT assertions take `Variant`) and typed `for` variables.
* Naming and docs: `snake_case` files, `class_name` for
  anything shared, tabs for indentation, doc comments (`##`) on public API.
* Keep the Lua side out of `src/`. The core talks to scripts only through the
  interface in [`docs/architecture.md`](docs/architecture.md).
