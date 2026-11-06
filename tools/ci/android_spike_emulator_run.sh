#!/usr/bin/env bash
# Install the spike APK on a booted emulator, scrape godot logcat for SPIKE_*.
# Intended to run inside reactivecircus/android-emulator-runner's `script:`.
#
# Logcat is filtered to tag godot at priority I and above (-s godot:I), matching
# docs/scripting/testing.md §2.4. Unfiltered logcat can false-red the gate when
# unrelated lines contain "SCRIPT ERROR". Capture starts BEFORE am start so
# early SPIKE_INFO / SPIKE_RESULT lines are not lost.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APK="${SPIKE_APK:-$ROOT/build/android/spike-debug.apk}"
PACKAGE="${SPIKE_PACKAGE:-org.scriptshot.spike}"
TIMEOUT_SEC="${SPIKE_TIMEOUT_SEC:-300}"
LOG="${SPIKE_LOG:-$ROOT/build/android/spike-emulator.logcat.txt}"

test -s "$APK" || { echo "::error::APK missing: $APK"; exit 1; }
mkdir -p "$(dirname "$LOG")"

echo "android_spike_emulator_run.sh: adb devices"
adb devices

echo "android_spike_emulator_run.sh: installing $APK"
adb install -r "$APK"

# Resolve the real MAIN/LAUNCHER component. Godot 4.7 APKs use
# com.godot.game.GodotAppLauncher (not GodotApp) as the launchable activity.
resolve_launcher() {
	local resolved=""
	# cmd package resolve-activity --brief prints "priority=N\npackage/activity"
	resolved="$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$PACKAGE" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
	if [[ "$resolved" == */* && "$resolved" != *"Error"* && "$resolved" != *"No activity"* ]]; then
		printf '%s\n' "$resolved"
		return 0
	fi
	# Prefer the launcher activity name present in current Godot Android templates.
	if adb shell pm dump "$PACKAGE" 2>/dev/null | tr -d '\r' | grep -q 'com.godot.game.GodotAppLauncher'; then
		printf '%s\n' "${PACKAGE}/com.godot.game.GodotAppLauncher"
		return 0
	fi
	printf '%s\n' "${PACKAGE}/com.godot.game.GodotApp"
}

echo "android_spike_emulator_run.sh: clearing logcat and starting godot:I capture before launch"
adb logcat -c
: > "$LOG"
# -s godot:I = tag godot, priority Info and higher (I/W/E/F). Godot print() and
# SCRIPT ERROR both show up on this tag; unrelated apps do not.
adb logcat -v time -s godot:I >> "$LOG" &
logcat_pid=$!
cleanup_logcat() {
	if kill -0 "$logcat_pid" 2>/dev/null; then
		kill "$logcat_pid" 2>/dev/null || true
		wait "$logcat_pid" 2>/dev/null || true
	fi
}
trap cleanup_logcat EXIT
# Let adb logcat attach before the process starts printing.
sleep 1

COMPONENT="$(resolve_launcher)"
echo "android_spike_emulator_run.sh: launching $PACKAGE via $COMPONENT"
set +e
adb shell am start -W -n "$COMPONENT" >/tmp/am-start.txt 2>&1
am_rc=$?
set -e
if [ "$am_rc" -ne 0 ]; then
	cat /tmp/am-start.txt || true
	echo "android_spike_emulator_run.sh: component start failed; trying MAIN/LAUNCHER intent"
	set +e
	adb shell am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p "$PACKAGE" >/tmp/am-start2.txt 2>&1
	am_rc=$?
	set -e
	if [ "$am_rc" -ne 0 ]; then
		cat /tmp/am-start2.txt || true
		echo "::error::am start failed for $PACKAGE (tried $COMPONENT and MAIN/LAUNCHER)"
		cleanup_logcat
		trap - EXIT
		exit 1
	fi
fi
# Do not fall back to monkey — it hid the wrong-activity bug on the baseline run.

echo "android_spike_emulator_run.sh: waiting up to ${TIMEOUT_SEC}s for SPIKE_DONE (or SPIKE_FAIL)"
set +e
timeout "${TIMEOUT_SEC}" sh -c "until grep -qE 'SPIKE_DONE|SPIKE_FAIL' \"$LOG\"; do sleep 0.25; done"
rc=$?
set -e
cleanup_logcat
trap - EXIT

if [ "$rc" -eq 124 ]; then
	echo "::error::timed out after ${TIMEOUT_SEC}s waiting for SPIKE_DONE"
	echo "---- last 200 log lines ----"
	tail -n 200 "$LOG" || true
	exit 1
fi
if [ "$rc" -ne 0 ]; then
	echo "::error::logcat scrape failed (exit $rc)"
	tail -n 200 "$LOG" || true
	exit 1
fi

if grep -q SPIKE_FAIL "$LOG"; then
	echo "::error::spike reported SPIKE_FAIL (see logcat)"
	grep SPIKE_FAIL "$LOG" || true
	python3 "$ROOT/tools/ci/check_spike_result.py" "$LOG" || true
	exit 1
fi

echo "android_spike_emulator_run.sh: gating SPIKE_RESULT lines"
python3 "$ROOT/tools/ci/check_spike_result.py" "$LOG"
