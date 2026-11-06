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
ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|Failed to instantiate|Failed to load GDExtension'

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

# Stock lua-gdextension 0.8.2 (SHA256-pinned). Idempotent. Also pre-seeds
# .godot/extension_list.cfg, the issue #7 cold-import workaround.
bash tools/ci/fetch_native_libs.sh
if [ "$?" -ne 0 ]; then
	echo "run_tests.sh: fetch_native_libs.sh failed" >&2
	exit 1
fi

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
#
# Stock lua-gdextension crashes at shutdown if one process both stopped a Lua
# chunk with the instruction hook and ran a bullet callback (a Godot Callable
# inside Lua). The default suite is two processes. A -gdir / -gselect /
# -gunit_test_name run stays one process so a focused command is unchanged.
split=1
for arg in "$@"; do
	case "$arg" in
		-gdir*|-gselect*|-gunit_test_name*) split=0 ;;
	esac
done

# Godot aborts while releasing Lua states at process exit even when the suite
# is green (lua-gdextension #240). A 134 with a green summary and no in-suite
# crash is that shutdown, not a failed test. A crash during a test prints
# handle_crash and still fails.
#
# GUT prints "All tests passed" only when nothing is pending or risky. Pending
# native stubs (the extension is not built) omit that banner and print
# "N pending/risky tests." instead. That summary is still green: it is only
# used when there are no failing tests and no failing before/after asserts.
suite_is_green() {
	local log="$1"
	if grep -a -q 'handle_crash' "$log"; then
		return 1
	fi
	if grep -a -E -q -e 'Failing Tests' -e '[0-9]+ failing tests' -e 'assert\(s\) in before_all/after_all' -- "$log"; then
		return 1
	fi
	grep -a -E -q -e '---- All tests passed! ----' -e '---- [0-9]+ pending/risky tests\. ----' -- "$log"
}

tolerate_lua_shutdown() {
	local status="$1" log="$2"
	if [ "$status" -eq 134 ] && suite_is_green "$log"; then
		echo "run_tests.sh: godot aborted while releasing Lua at exit after a green suite"
		return 0
	fi
	return "$status"
}

run_gut() {
	"$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit "$@" 2>&1 | tee "$LOG_DIR/gut.log"
	tolerate_lua_shutdown "${PIPESTATUS[0]}" "$LOG_DIR/gut.log"
}

if [ "$split" -eq 1 ]; then
	echo "run_tests.sh: Lua host guards"
	run_gut -gdir=res://tests/scripting/host -ginclude_subdirs "$@"
	gut_status=$?
	if scan_log "test run (Lua host guards)" "$LOG_DIR/gut.log"; then
		failed=1
	fi
	if [ "$gut_status" -ne 0 ]; then
		failed=1
	fi
	echo "run_tests.sh: unit + bullet hooks"
	run_gut -gdir=res://tests/unit -gdir=res://tests/scripting/integration -ginclude_subdirs "$@"
	gut_status=$?
	if scan_log "test run (unit + bullet hooks)" "$LOG_DIR/gut.log"; then
		failed=1
	fi
	if [ "$gut_status" -ne 0 ]; then
		failed=1
	fi
else
	run_gut "$@"
	gut_status=$?
	if scan_log "test run" "$LOG_DIR/gut.log"; then
		failed=1
	fi
	if [ "$gut_status" -ne 0 ]; then
		failed=1
	fi
fi

if [ "$failed" -ne 0 ]; then
	echo "run_tests.sh: FAILED (gut exit status $gut_status, see messages above)" >&2
	exit 1
fi
