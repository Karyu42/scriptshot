# Contributing

## Tooling

* **Godot 4.7.2 (stable), exactly.** `project.godot` targets 4.7 and the vendored
  test framework is GUT 9.7.1; other Godot versions are not supported.
* **Shared dev box:** Godot 4.7.2 is installed at
  `~/.local/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64`
  (`/home/box/.local/godot/4.7.2/...`) and symlinked as `godot` at
  `~/.local/bin/godot` and `/usr/local/bin/godot`. `/usr/local/bin` is on the
  default `PATH`; `~/.local/bin` may not be, so use `$GODOT` if `godot` is not
  found:

  ```sh
  export GODOT=~/.local/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64
  ```

  `tools/run_tests.sh` and `tools/run_benchmark.sh` honour `$GODOT`.
* **Elsewhere:** download the matching Linux/macOS/Windows build from
  <https://github.com/godotengine/godot/releases/tag/4.7.2-stable>.

## Workflow

* Never push to `main`. Branch from `main` (`feat/...`, `fix/...`) and open a PR.
* Run `./tools/run_tests.sh` before pushing; it must pass. Add tests for new
  logic, especially anything in the bullet system or movement math.
* If you touch the bullet loop, run `./tools/run_benchmark.sh` and include the
  p50/p95 numbers in the PR. Target: 5000 bullets at p95 <= 16.7 ms.
* Commit the `.uid` files Godot generates next to scripts and `.import` files
  next to assets; do not commit `.godot/`.
* GDScript style: static typing everywhere, `snake_case` files, `class_name` for
  anything shared, tabs for indentation, doc comments (`##`) on public API.
* Keep the Lua side out of `src/`. The core talks to scripts only through the
  interface in [`docs/architecture.md`](docs/architecture.md).
