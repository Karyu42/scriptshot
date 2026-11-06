#!/usr/bin/env bash
# Build the Lua spike Android debug APK (arm64-v8a + x86_64) for emulator smoke.
# See docs/scripting/testing.md section 2.4.
#
# Usage (from repo root, with $GODOT set and Android export templates + editor settings ready):
#   bash tools/ci/export_spike_android.sh [out.apk]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

OUT="${1:-$ROOT/build/android/spike-debug.apk}"
SPIKE_SRC="$ROOT/docs/scripting/spike"
WORK="${SPIKE_WORK_DIR:-$ROOT/build/spike-export}"
GODOT_BIN="${GODOT:?set GODOT to the headless editor binary}"

test -d "$SPIKE_SRC" || { echo "::error::missing $SPIKE_SRC"; exit 1; }
test -x "$GODOT_BIN" || { echo "::error::GODOT is not executable: $GODOT_BIN"; exit 1; }

echo "export_spike_android.sh: preparing spike workdir at $WORK"
rm -rf "$WORK"
mkdir -p "$WORK"
# Copy the self-contained spike project (no .godot from the source tree).
cp -a "$SPIKE_SRC"/. "$WORK"/
rm -rf "$WORK/.godot" "$WORK/out_android" "$WORK/addons/lua-gdextension"

# Stock 0.8.2 zip into repo addons/, then copy into the spike workdir.
bash "$ROOT/tools/ci/fetch_native_libs.sh" android.x86_64
mkdir -p "$WORK/addons"
cp -a "$ROOT/addons/lua-gdextension" "$WORK/addons/"
mkdir -p "$WORK/.godot"
printf '%s\n' 'res://addons/lua-gdextension/luagdextension.gdextension' > "$WORK/.godot/extension_list.cfg"

mkdir -p "$(dirname "$OUT")" "$WORK/out_android"

ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|Failed loading resource|Failed to instantiate'
import_log="$(mktemp)"
trap 'rm -f "$import_log"' EXIT
if ! "$GODOT_BIN" --headless --path "$WORK" --import >"$import_log" 2>&1 \
  || grep -a -q -E "$ERROR_PATTERN" "$import_log"; then
  cat "$import_log"
  echo "::error::spike project import failed before export"
  exit 1
fi

# Preset path is out_android/spike.apk inside the spike project; copy to the caller path after.
"$GODOT_BIN" --headless --path "$WORK" --export-debug "Android" "$WORK/out_android/spike.apk"
test -s "$WORK/out_android/spike.apk" || { echo "::error::spike APK missing after export"; exit 1; }
cp -f "$WORK/out_android/spike.apk" "$OUT"
# Godot may also write .idsig next to the APK; ignore if absent.
if [ -f "$WORK/out_android/spike.apk.idsig" ]; then
  cp -f "$WORK/out_android/spike.apk.idsig" "${OUT}.idsig"
fi

echo "export_spike_android.sh: verifying native libs inside APK"
listing="$(mktemp)"
unzip -l "$OUT" > "$listing"
grep -E 'lib/arm64-v8a/libluagdextension' "$listing" \
  || { echo "::error::APK missing arm64-v8a lua-gdextension"; exit 1; }
grep -E 'lib/x86_64/libluagdextension' "$listing" \
  || { echo "::error::APK missing x86_64 lua-gdextension (needed for the GH emulator)"; exit 1; }
rm -f "$listing"

ls -lh "$OUT"
echo "export_spike_android.sh: wrote $OUT"
