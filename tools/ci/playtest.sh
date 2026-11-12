#!/usr/bin/env bash
# Headless first-playable autoplay (src/qa/playtest_autoplay.tscn).
# Drives the real main scene through the built L0–L2 path in
# docs/design/first-playable-elites.md and, when present, notes the
# rooms in docs/design/vertical-slice.md without asserting provisional
# Q26 arena coordinates.
#
#   ./tools/ci/playtest.sh              # Linux headless editor
#   ./tools/ci/playtest.sh --web        # also export "Web (playtest)" and run it in Chromium
#
# Env:
#   GODOT             Godot 4.7.2 editor binary (default: godot on PATH)
#   PYTHON            python with playwright installed (default: python3); web only
#   CHROME_PATH       Chrome/Chromium binary (default: Playwright's bundled one)
#   PLAYTEST_TIMEOUT  seconds (default: 180 Linux, 240 web)
#   PLAYTEST_OUT      artifact dir (default: reports/playtest)
# Exit code is non-zero on a failed beat, a script error, or a timeout.
set -euo pipefail
cd "$(dirname "$0")/../.."

GODOT="${GODOT:-godot}"
PYTHON="${PYTHON:-python3}"
OUT="${PLAYTEST_OUT:-reports/playtest}"
TIMEOUT="${PLAYTEST_TIMEOUT:-180}"
ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|Failed to instantiate|Failed to load GDExtension'
RUN_WEB=0
for arg in "$@"; do
	case "$arg" in
		--web) RUN_WEB=1 ;;
		*) echo "playtest.sh: unknown argument $arg" >&2; exit 2 ;;
	esac
done

ver="$("$GODOT" --version | head -n1)"
case "$ver" in
	4.7.2.stable*) ;;
	*) echo "playtest.sh: need Godot 4.7.2-stable, got '$ver'" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
if [ ! -d .godot/imported ]; then
	timeout 600 "$GODOT" --headless --path . --import >/dev/null 2>&1 || true
fi

run_linux() {
	local log="$OUT/linux.log"
	echo "::group::Playtest autoplay (Linux headless)"
	set +e
	timeout "$TIMEOUT" "$GODOT" --headless --path . res://src/qa/playtest_autoplay.tscn >"$log" 2>&1
	local rc=$?
	set -e
	if [ "$rc" -eq 124 ]; then
		echo "playtest.sh: Linux run timed out after ${TIMEOUT}s" >&2
		tail -n 80 "$log"
		echo "::endgroup::"
		return 1
	fi
	if grep -a -E "$ERROR_PATTERN" "$log" >/dev/null; then
		echo "playtest.sh: engine/script error in Linux run" >&2
		grep -a -E "$ERROR_PATTERN" "$log" | head -n 20
		echo "::endgroup::"
		return 1
	fi
	if ! grep -a -q 'PLAYTEST_DONE ok' "$log"; then
		echo "playtest.sh: Linux run did not print PLAYTEST_DONE ok (exit $rc)" >&2
		tail -n 80 "$log"
		echo "::endgroup::"
		return 1
	fi
	grep -a -E 'PLAYTEST_' "$log" || true
	echo "::endgroup::"
	return 0
}

run_web() {
	local web_timeout="${PLAYTEST_TIMEOUT:-240}"
	local dest="build/web-playtest-export"
	local tpl_dir="${GODOT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/4.7.2.stable}"
	local tpl="$tpl_dir/web_dlink_nothreads_release.zip"
	[ -s "$tpl" ] || { echo "playtest.sh: missing export template $tpl" >&2; return 1; }
	if [ -x ./tools/ci/fetch_native_libs.sh ]; then
		./tools/ci/fetch_native_libs.sh web.wasm32
	fi
	mkdir -p build && touch build/.gdignore
	rm -rf "$dest" && mkdir -p "$dest"
	echo "::group::Web (playtest) release export -> $dest"
	if ! timeout 600 "$GODOT" --headless --path . --export-release "Web (playtest)" "$dest/index.html" >"$OUT/web-export.log" 2>&1; then
		echo "playtest.sh: Web (playtest) export failed" >&2
		tail -n 40 "$OUT/web-export.log"
		echo "::endgroup::"
		return 1
	fi
	echo "::endgroup::"
	echo "::group::Playtest autoplay (headless Chromium)"
	if ! "$PYTHON" tools/ci/playtest_web.py "$dest" "$OUT" --timeout "$web_timeout"; then
		echo "playtest.sh: web playtest failed (artifacts in $OUT)" >&2
		echo "::endgroup::"
		return 1
	fi
	echo "::endgroup::"
	return 0
}

rc=0
run_linux || rc=1
if [ "$RUN_WEB" -eq 1 ]; then
	run_web || rc=1
fi
exit $rc
