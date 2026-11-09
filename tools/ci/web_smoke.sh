#!/usr/bin/env bash
# Web export browser smoke (issues #40, #36). For each mode it exports the
# shipping "Web" preset and the "Web (smoke)" preset with the official 4.7.2
# web_dlink_nothreads templates, checks the exported files (lua-gdextension in,
# native bullet lib out, QA files only in the smoke export), then loads them in
# headless Chromium: "boot" on the shipping export, "lua" and "native" on the
# smoke export (tools/ci/web_smoke.py).
#
#   ./tools/ci/web_smoke.sh                 # release, then debug
#   WEB_SMOKE_MODES=release ./tools/ci/web_smoke.sh
#
# Env:
#   GODOT             Godot 4.7.2 editor binary (default: godot on PATH)
#   PYTHON            python with playwright installed (default: python3)
#   CHROME_PATH       Chrome/Chromium binary (default: Playwright's bundled one)
#   WEB_SMOKE_MODES   space-separated export modes (default: "release debug")
#   WEB_SMOKE_OUT     artifact dir (default: build/web-smoke)
#   WEB_SMOKE_TIMEOUT seconds per scenario (default: 90)
# Exit code is non-zero if any export, check or scenario fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

GODOT="${GODOT:-godot}"
PYTHON="${PYTHON:-python3}"
MODES="${WEB_SMOKE_MODES:-release debug}"
OUT="${WEB_SMOKE_OUT:-build/web-smoke}"
TIMEOUT="${WEB_SMOKE_TIMEOUT:-90}"

ver="$("$GODOT" --version | head -n1)"
case "$ver" in
	4.7.2.stable*) ;;
	*) echo "web_smoke.sh: need Godot 4.7.2-stable, got '$ver'" >&2; exit 1 ;;
esac
tpl_dir="${GODOT_TEMPLATES_DIR:-$HOME/.local/share/godot/export_templates/4.7.2.stable}"
for mode in $MODES; do
	f="$tpl_dir/web_dlink_nothreads_${mode}.zip"
	[ -s "$f" ] || { echo "web_smoke.sh: missing export template $f" >&2; exit 1; }
done

./tools/ci/fetch_native_libs.sh web.wasm32
# Keep the editor from importing exported files (index.png and friends).
mkdir -p build && touch build/.gdignore
if [ ! -d .godot/imported ]; then
	timeout 600 "$GODOT" --headless --path . --import >/dev/null 2>&1 || true
fi

export_web() { # preset mode dir log
	rm -rf "$3" && mkdir -p "$3"
	local t0
	t0=$(date +%s)
	if ! timeout 600 "$GODOT" --headless --path . "--export-$2" "$1" "$3/index.html" >"$4" 2>&1; then
		echo "::error::$1 $2 export failed (see $4)"
		tail -n 40 "$4"
		return 1
	fi
	echo "$1 $2 export took $(( $(date +%s) - t0 ))s"
}

rc=0
for mode in $MODES; do
	ship="build/web"
	smoke="build/web-smoke-export"
	if [ "$mode" != release ]; then
		ship="build/web-$mode"
		smoke="build/web-smoke-export-$mode"
	fi
	art="$OUT/$mode"
	rm -rf "$art" && mkdir -p "$art"

	# The shipping preset: what players get. Export check plus the boot scenario.
	echo "::group::Web ($mode): shipping preset -> $ship"
	export_web Web "$mode" "$ship" "$art/export-web.log" || exit 1
	echo "::endgroup::"
	if ! "$PYTHON" tools/ci/web_smoke.py check-export "$ship" | tee "$art/check-export-web.txt"; then
		echo "::error::Web $mode export check failed"
		rc=1
	elif ! "$PYTHON" tools/ci/web_smoke.py run "$ship" "$art" --timeout "$TIMEOUT" --scenarios boot; then
		echo "::error::Web $mode boot smoke failed (artifacts in $art)"
		rc=1
	fi

	# "Web (smoke)": same options plus src/qa/ and the web_smoke feature, which
	# makes src/qa/web_smoke.tscn the main scene. Lua and native-request scenarios.
	echo "::group::Web ($mode): smoke preset -> $smoke"
	export_web "Web (smoke)" "$mode" "$smoke" "$art/export-web-smoke.log" || exit 1
	echo "::endgroup::"
	if ! "$PYTHON" tools/ci/web_smoke.py check-export "$smoke" --smoke | tee "$art/check-export-web-smoke.txt"; then
		echo "::error::Web (smoke) $mode export check failed"
		rc=1
	elif ! "$PYTHON" tools/ci/web_smoke.py run "$smoke" "$art" --timeout "$TIMEOUT" --scenarios lua,native; then
		echo "::error::Web (smoke) $mode browser smoke failed (artifacts in $art)"
		rc=1
	fi
done
exit $rc
