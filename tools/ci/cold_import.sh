#!/usr/bin/env bash
# Cold `godot --import` for a CI perf tree, with exactly ONE retry, and only when Godot died on a signal.
#
#   GODOT=... tools/ci/cold_import.sh <project_dir> <name> <log_dir>
#
# Used by the perf-native job ("Bullet benchmark (native on_batch, p95 gate)") before the benchmarks, for the head
# and for the same-run base. Nothing else in that job retries: the benchmarks (perf_ab.sh / run_benchmark.sh), the
# unit tests and check_perf.py run once.
#   * exit 0                         -> ok.
#   * exit >= 128 (killed by a signal, e.g. 134 SIGABRT, 139 SIGSEGV) on the FIRST attempt -> a ::warning:: annotation
#     with the signal and a crash excerpt (the double-free / crash-handler / backtrace lines and the log tail), the
#     full log is kept as <log_dir>/import-<name>-1-crashed.log, and the import runs once more. Background: PR #64
#     run 43199386255, the head's cold import aborted with "double free or corruption (!prev)"; see issue #7.
#   * any other non-zero exit        -> a real import error: ::error::, exit 1, no retry.
#   * a second failure of any kind   -> ::error::, exit 1.
# The import's own script/resource errors are still caught by run_benchmark.sh's import check afterwards.
# Exit 0 = imported, 1 = failed, 2 = usage.
set -uo pipefail
[ "$#" -eq 3 ] || { echo "usage: cold_import.sh <project_dir> <name> <log_dir>" >&2; exit 2; }
dir="$1" name="$2" logdir="$3"
GODOT="${GODOT:-godot}"
mkdir -p "$logdir"

# One annotation; GitHub needs %, CR and LF escaped to keep a multi-line message.
annotate() {  # annotate <level> <title> <message>
	local msg="$3"
	msg="${msg//'%'/'%25'}"
	msg="${msg//$'\r'/'%0D'}"
	msg="${msg//$'\n'/'%0A'}"
	echo "::$1 title=$2::$msg"
}

excerpt() {  # excerpt <log>: crash lines first, then the last 25 lines, ANSI colours stripped
	sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -a -n -E 'double free|corruption|free\(\)|malloc|handle_crash|CrashHandler|Program crashed|signal [0-9]+|Backtrace|^\[[0-9]+\] |Aborted|Segmentation' | head -n 40
	echo "--- last 25 lines ---"
	sed 's/\x1b\[[0-9;]*m//g' "$1" | tail -n 25
}

for attempt in 1 2; do
	log="$logdir/import-$name-$attempt.log"
	"$GODOT" --headless --path "$dir" --import >"$log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then
		echo "cold_import.sh: $name: import ok (attempt $attempt)"
		exit 0
	fi
	if [ "$rc" -lt 128 ]; then
		annotate error "$name cold import failed" "$name: godot --import exited $rc (not a signal): a real import error, not retried.
$(excerpt "$log")"
		exit 1
	fi
	if [ "$attempt" -eq 1 ]; then
		mv "$log" "$logdir/import-$name-1-crashed.log"
		annotate warning "$name cold import crashed (retrying once)" "$name: godot --import died on signal $((rc - 128)) (exit $rc), attempt 1 of 2; retrying ONCE (issue #7). Full log: perf-native-reports artifact, import-logs/import-$name-1-crashed.log.
$(excerpt "$logdir/import-$name-1-crashed.log")"
	else
		annotate error "$name cold import crashed twice" "$name: godot --import died on signal $((rc - 128)) (exit $rc) again on the retry.
$(excerpt "$log")"
		exit 1
	fi
done
