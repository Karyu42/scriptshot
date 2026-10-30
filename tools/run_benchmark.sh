#!/usr/bin/env bash
# Headless bullet benchmark: p50/p95 frame work at 5k and 10k bullets (with walls
# and fast bullets present). Two checks against a 16.6 ms p95 budget:
#   FLOOR  --floor-bullets=5000   hard fail (exit 1) on a miss, or if the count
#                                 was not actually reached
#   TARGET --target-bullets=10000 prints a WARN line on a miss, exit code stays 0
# Exit code is also 1 if the project failed to import/compile.
#
#   ./tools/run_benchmark.sh
#   ./tools/run_benchmark.sh --bullets=2000,5000,10000,20000 --frames=1200
#   ./tools/run_benchmark.sh --floor-bullets=5000 --target-bullets=10000
#   ./tools/run_benchmark.sh --json=/tmp/bench.json
#
# Uses $GODOT if set, otherwise `godot` from PATH (Godot 4.7.2).
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|Failed to instantiate'

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# First run / fresh clone: build the .godot cache. Keep the output so import
# problems are reported instead of silently swallowed.
if ! "$GODOT" --headless --path . --import >"$LOG" 2>&1 || grep -a -q -E "$ERROR_PATTERN" "$LOG"; then
	cat "$LOG" >&2
	echo "run_benchmark.sh: project import failed" >&2
	exit 1
fi

"$GODOT" --headless --path . res://tests/benchmark/bullet_benchmark.tscn -- "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
if grep -a -q -E "$ERROR_PATTERN" "$LOG"; then
	echo "run_benchmark.sh: script errors during the run" >&2
	exit 1
fi
exit "$status"
