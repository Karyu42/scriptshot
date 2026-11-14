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
#
# Portable to macOS's /bin/bash 3.2 and to Git Bash on Windows (the GUT (macos, native) and
# GUT (windows, native) CI jobs): no EPOCHREALTIME, mapfile, associative arrays, ${var,,} or
# `tail --pid`, and empty arrays are expanded with ${a[@]+"${a[@]}"} (bash < 4.4 treats
# "${a[@]}" of an empty array as unbound under set -u). tools/ci/test_run_tests_guard.py runs
# the guard cases under any bash (RUN_TESTS_BASH=/bin/bash on macOS).
set -uo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"

# Lines that mean "a script or resource did not load". Anything matching these
# in the import or test output is a hard failure.
ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|Failed to instantiate|Failed to load GDExtension'

# Lines lua-gdextension prints when the editor (here: --import) ran a res://*.lua
# chunk and it raised. The binding runs any .lua that ends in `return { ... }` while
# scanning, outside the sandbox, so a weapon script saved as .lua would error on its
# first top-level sandbox global (state, spawn, TAU, sense). Bundled weapon scripts
# are .lua.txt for that reason (ScriptLibrary.BUNDLED_EXT). Checked only in the
# import log (tests print Lua errors on purpose) and by content, never by exit code.
IMPORT_LUA_PATTERN='LuaScript\.cpp|^ERROR: \[string "res://[^"]*"\]'

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
if grep -a -E "$IMPORT_LUA_PATTERN" "$LOG_DIR/import.log" >"$LOG_DIR/matches.txt"; then
	echo "::error:: godot --import ran a res:// Lua file and it raised (save weapon scripts as .lua.txt):" >&2
	cat "$LOG_DIR/matches.txt" >&2
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
	# handle_crash: the Linux/macOS crash handler. CrashHandlerException: the Windows one.
	if grep -a -E -q -e 'handle_crash' -e 'CrashHandlerException' -- "$log"; then
		return 1
	fi
	if grep -a -E -q -e 'Failing Tests' -e '[0-9]+ failing tests' -e 'assert\(s\) in before_all/after_all' -- "$log"; then
		return 1
	fi
	grep -a -E -q -e '---- All tests passed! ----' -e '---- [0-9]+ pending/risky tests\. ----' -- "$log"
}

# junit_is_green <file>: the GUT junit XML exists, is non-empty, parses, and its testsuites/testsuite
# failures= + errors= sum to 0 (tools/ci/junit_green.py). The console summary alone is not enough to
# accept an abnormal exit: the banner prints before the junit file is written (gut.gd _end_run).
junit_is_green() {
	python3 tools/ci/junit_green.py "$1"
}

# Exit statuses that mean "aborted while releasing Lua at exit". POSIX: 134 (SIGABRT). Windows
# (Git Bash): ABORT_CODES_WINDOWS below, measured in the GUT (windows, native) job. Any of them
# is accepted only with a green console summary AND a green junit XML.
ABORT_CODES="134"
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) ABORT_CODES="134 ${ABORT_CODES_WINDOWS:-3}" ;;
esac

is_abort_code() {
	local c
	for c in $ABORT_CODES; do
		[ "$1" -eq "$c" ] && return 0
	done
	return 1
}

tolerate_lua_shutdown() {
	local status="$1" log="$2" junit="$3"
	if [ "$status" -ne 0 ] && is_abort_code "$status" && suite_is_green "$log" && junit_is_green "$junit"; then
		echo "run_tests.sh: godot aborted (exit $status) while releasing Lua at exit after a green suite (console and junit)"
		return 0
	fi
	return "$status"
}

# Exit-after-results guard (issue #41). The same Lua-state release at exit sometimes hangs instead of
# aborting (about 1 run in 20, on main too), so the job sat until its timeout with every test green.
# Once GUT has printed its end-of-run summary ("---- ... ----" grand total) or "Results saved to", godot gets
# GUT_EXIT_GRACE_S seconds (default 60, measured in milliseconds by now_ms, so not rounded down to whole seconds)
# to exit. After that it is killed (TERM, then KILL after 5 s):
#   green console summary AND green junit XML -> success, with a ::warning:: annotation pointing at #41
#   anything else (red summary, junit missing, malformed, failures or errors) -> failure
# A hang before any results is not killed here; the CI job timeout still applies.
results_written() {
	grep -a -E -q -e '^Results saved to ' -e '---- (All tests passed!|[0-9]+ pending/risky tests\.|[0-9]+ failing tests|[0-9]+ assert\(s\) in before_all/after_all methods failed) ----' -- "$1"
}

# now_ms: wall clock in milliseconds. bash 5 has EPOCHREALTIME; bash 3.2 (macOS /bin/bash) does not, so use
# perl's Time::HiRes (macOS, Linux runners and Git for Windows all ship perl), else python3.
if [ -n "${EPOCHREALTIME:-}" ]; then
	now_ms() {
		local t="${EPOCHREALTIME//[.,]/}"
		echo $((10#$t / 1000))
	}
elif command -v perl >/dev/null 2>&1; then
	now_ms() { perl -MTime::HiRes=time -e 'printf("%d\n", time() * 1000)'; }
else
	now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
fi

# stream_new <file>: print what was appended to <file> since the last call (byte offset in STREAMED).
# Replaces `tail -f --pid`, which BSD tail (macOS) does not have.
STREAMED=0
stream_new() {
	local size
	size=$(wc -c <"$1" | tr -d ' ')
	if [ "$size" -gt "$STREAMED" ]; then
		tail -c +$((STREAMED + 1)) -- "$1" | head -c $((size - STREAMED))
		STREAMED=$size
	fi
}

# junit_path <gut args...>: the file GUT will write, from -gjunit_xml_file=PATH (res:// -> project dir).
# Empty if there is none, so run_gut asks for one in LOG_DIR. -gjunit_xml_timestamp renames the file at
# write time; it cannot be predicted, so it is reported as unusable ("-") and an abnormal exit stays red.
junit_path() {
	local arg path=""
	for arg in "$@"; do
		case "$arg" in
			-gjunit_xml_timestamp*) echo "-"; return ;;
			-gjunit_xml_file=*) path="${arg#-gjunit_xml_file=}" ;;
		esac
	done
	case "$path" in
		res://*) path="$PWD/${path#res://}" ;;
	esac
	echo "$path"
}

run_gut() {
	local log="$LOG_DIR/gut.log" grace="${GUT_EXIT_GRACE_S:-60}" pid status
	local results_seen=0 seen_at=0 hung=0 i junit
	local -a extra
	extra=()
	junit="$(junit_path "$@")"
	if [ -z "$junit" ]; then
		junit="$LOG_DIR/gut-junit.xml"
		extra=(-gjunit_xml_file="$junit")
	fi
	# A file left by an earlier process (the split suite writes the same path twice) must not count.
	[ "$junit" = "-" ] || rm -f "$junit"
	: >"$log"
	"$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit "$@" ${extra[@]+"${extra[@]}"} >"$log" 2>&1 &
	pid=$!
	# Stream the output (about once a second; the CI step tees this script's stdout into reports/gut.log).
	STREAMED=0
	while kill -0 "$pid" 2>/dev/null; do
		stream_new "$log"
		if [ "$results_seen" -eq 0 ] && results_written "$log"; then
			results_seen=1
			seen_at=$(now_ms)
		fi
		if [ "$results_seen" -eq 1 ] && [ $(($(now_ms) - seen_at)) -ge $((grace * 1000)) ]; then
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
	stream_new "$log"
	# Always logged: the Windows abort status is platform-specific (ABORT_CODES above).
	echo "run_tests.sh: godot exited with status $status$([ "$hung" -eq 1 ] && echo ' (killed by the exit-after-results guard)')"
	if [ "$hung" -eq 1 ]; then
		if suite_is_green "$log" && junit_is_green "$junit"; then
			echo "::warning::godot did not exit after results (teardown hang, see #41); killed after ${grace}s, suite and junit were green"
			return 0
		fi
		echo "run_tests.sh: godot did not exit ${grace}s after results and the suite or its junit XML was not green; killed" >&2
		return 1
	fi
	tolerate_lua_shutdown "$status" "$log" "$junit"
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
