#!/usr/bin/env bash
# Headless bullet benchmark: p50/p95 frame work at 5k and 10k bullets, with a
# pass/fail verdict against the 5000-bullet / 16.7 ms p95 target (exit code 1
# on FAIL).
#
#   ./tools/run_benchmark.sh
#   ./tools/run_benchmark.sh --bullets=2000,5000,10000,20000 --frames=1200
#   ./tools/run_benchmark.sh --json=/tmp/bench.json
#
# Uses $GODOT if set, otherwise `godot` from PATH (Godot 4.7.2).
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

"$GODOT" --headless --path . --import >/dev/null 2>&1 || true

exec "$GODOT" --headless --path . res://tests/benchmark/bullet_benchmark.tscn -- "$@"
