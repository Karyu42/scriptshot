#!/usr/bin/env bash
# Web export browser smoke (issues #40, #36). Exports the "Web" preset with the
# official 4.7.2 web_dlink_nothreads templates, checks the exported files
# (lua-gdextension in, native bullet lib out), then loads the export in headless
# Chromium and runs the boot / lua / native scenarios of tools/ci/web_smoke.py.
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

rc=0
for mode in $MODES; do
	dir="build/web"
	[ "$mode" = release ] || dir="build/web-$mode"
	rm -rf "$dir" "$OUT/$mode" && mkdir -p "$dir" "$OUT/$mode"
	echo "::group::export Web ($mode) -> $dir"
	t0=$(date +%s)
	if ! timeout 600 "$GODOT" --headless --path . "--export-$mode" Web "$dir/index.html" >"$OUT/$mode/export.log" 2>&1; then
		echo "::endgroup::"
		echo "::error::Web $mode export failed (see $OUT/$mode/export.log)"
		tail -n 40 "$OUT/$mode/export.log"
		exit 1
	fi
	echo "export took $(( $(date +%s) - t0 ))s"
	echo "::endgroup::"
	if ! "$PYTHON" tools/ci/web_smoke.py check-export "$dir" | tee "$OUT/$mode/check-export.txt"; then
		echo "::error::Web $mode export check failed"
		rc=1
		continue
	fi
	if ! "$PYTHON" tools/ci/web_smoke.py run "$dir" "$OUT/$mode" --timeout "$TIMEOUT"; then
		echo "::error::Web $mode browser smoke failed (artifacts in $OUT/$mode)"
		rc=1
	fi
done
exit $rc
