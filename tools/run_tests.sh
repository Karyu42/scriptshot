#!/usr/bin/env bash
# Runs the whole GUT unit test suite headlessly. Exit code is non-zero on any
# failure, error or script parse problem.
#
#   ./tools/run_tests.sh                      # everything
#   ./tools/run_tests.sh -gselect=bullet_pool # only scripts matching a name
#
# Uses $GODOT if set, otherwise `godot` from PATH (Godot 4.7.2).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

# First run / fresh clone: build the .godot cache (class_name registry, imports).
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

exec "$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit "$@"
