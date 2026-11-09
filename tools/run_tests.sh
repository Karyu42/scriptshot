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

# Exit-after-results guard (issue #41). The same Lua-state release at exit sometimes hangs instead of
# aborting (about 1 run in 20, on main too), so the job sat until its timeout with every test green.
# Once GUT has printed its end-of-run summary ("---- ... ----" grand total) or "Results saved to", godot gets
# GUT_EXIT_GRACE_S seconds (default 60) to exit. After that it is killed (TERM, then KILL after 5 s):
#   green summary -> success, with a ::warning:: annotation pointing at #41
#   anything else -> failure
results_written() {
	grep -a -E -q -e '^Results saved to ' -e '---- (All tests passed!|[0-9]+ pending/risky tests\.|[0-9]+ failing tests|[0-9]+ assert\(s\) in before_all/after_all methods failed) ----' -- "$1"
}

run_gut() {
	local log="$LOG_DIR/gut.log" grace="${GUT_EXIT_GRACE_S:-60}" pid tail_pid status seen=0 hung=0 i
	: >"$log"
	"$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit "$@" >"$log" 2>&1 &
	pid=$!
	# Stream the output live (the CI step tees this script's stdout into reports/gut.log).
	tail -n +1 -f --pid="$pid" "$log" &
	tail_pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [ "$seen" -eq 0 ] && results_written "$log"; then
			seen=$SECONDS
		fi
		if [ "$seen" -ne 0 ] && [ $((SECONDS - seen)) -ge "$grace" ]; then
			hung=1
			kill -TERM "$pid" 2>/dev/null
			for ((i = 0; i < 5; i++)); do
				kill -0 "$pid" 2>/dev/null || break
				sleep 1
			done
			kill -KILL "$pid" 2>/dev/null
			break
		fi
		sleep 1
	done
	wait "$pid"
	status=$?
	wait "$tail_pid" 2>/dev/null
	if [ "$hung" -eq 1 ]; then
		if suite_is_green "$log"; then
			echo "::warning::godot did not exit after results (teardown hang, see #41); killed after ${grace}s, suite was green"
			return 0
		fi
		echo "run_tests.sh: godot did not exit ${grace}s after results and the suite was not green; killed" >&2
		return 1
	fi
	tolerate_lua_shutdown "$status" "$log"
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
