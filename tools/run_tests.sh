#!/usr/bin/env bash
# Runs the whole GUT unit test suite headlessly. Exit code is non-zero on any
# test failure or error, and also when the project import or the test run
# prints a script parse / load error (Godot itself exits 0 in that case, even
# for scripts nothing references).
#
#   ./tools/run_tests.sh                      # everything
#   ./tools/run_tests.sh -gselect=bullet_pool # only scripts matching a name
#
# Uses $GODOT if set, otherwise `godot` from PATH (Godot 4.7.2).
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

# Lines that mean "a script or resource did not load". Anything matching these
# in the import or test output is a hard failure.
ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|Failed to instantiate'

LOG_DIR="$(mktemp -d)"
trap 'rm -rf "$LOG_DIR"' EXIT

# scan_log <label> <file>: print offending lines, return 0 if any were found.
scan_log() {
	local label="$1" file="$2"
	if grep -a -E "$ERROR_PATTERN" "$file" >"$LOG_DIR/matches.txt"; then
		echo "::error:: $label reported script/resource errors:" >&2
		cat "$LOG_DIR/matches.txt" >&2
		return 0
	fi
	return 1
}

failed=0

# 1. First run / fresh clone: build the .godot cache (class_name registry,
#    imports). The output is kept and checked instead of being discarded.
"$GODOT" --headless --path . --import >"$LOG_DIR/import.log" 2>&1
import_status=$?
if [ "$import_status" -ne 0 ]; then
	echo "godot --import exited with status $import_status" >&2
	cat "$LOG_DIR/import.log" >&2
	failed=1
fi
if scan_log "godot --import" "$LOG_DIR/import.log"; then
	failed=1
fi

# 2. The test run. Output is streamed live and also scanned afterwards.
"$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit "$@" 2>&1 | tee "$LOG_DIR/gut.log"
gut_status=${PIPESTATUS[0]}
if scan_log "test run" "$LOG_DIR/gut.log"; then
	failed=1
fi
if [ "$gut_status" -ne 0 ]; then
	failed=1
fi

if [ "$failed" -ne 0 ]; then
	echo "run_tests.sh: FAILED (gut exit status $gut_status, see messages above)" >&2
	exit 1
fi
