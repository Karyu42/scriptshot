#!/usr/bin/env bash
# Build the Android phone-test APKs (arm64-v8a only). TEST HARNESS, not a release.
#   tools/android_test/build_apk.sh [outdir]      # default build/android
# Needs: Godot 4.7.2 + its Android export templates, Android SDK (build-tools 35.0.1) and JDK 17 configured in
# the editor settings (export/android/*), and a debug keystore configured there too
# (export/android/debug_keystore). Never commit a keystore. For the release-template APK the same debug keystore
# is passed through the GODOT_ANDROID_KEYSTORE_RELEASE_* environment variables.
set -euo pipefail
cd "$(dirname "$0")/../.."
GODOT="${GODOT:-godot}"
OUT="${1:-build/android}"
KS="${DEBUG_KEYSTORE:?set DEBUG_KEYSTORE to the debug keystore path}"
mkdir -p "$OUT"
tools/android_test/fetch_lua.sh "${LUA_ZIP:-}"
"$GODOT" --headless --path . --import || "$GODOT" --headless --path . --import   # cold import may abort once (lua-gdextension)
"$GODOT" --headless --path . --export-debug Android "$OUT/scriptshot-android-test-arm64.apk"

# Release export template (closer to shipped performance); separate package id so both can be installed.
cp export_presets.cfg "$OUT/.presets.bak"
trap 'cp "$OUT/.presets.bak" export_presets.cfg; rm -f "$OUT/.presets.bak"' EXIT
sed -i 's|^package/unique_name=.*|package/unique_name="io.github.karyu42.scriptshot.phonetest.rel"|;
        s|^package/name=.*|package/name="Scriptshot TEST (release tpl)"|;
        s|^version/name=.*|version/name="0.1.0-phonetest-reltpl"|' export_presets.cfg
GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KS" GODOT_ANDROID_KEYSTORE_RELEASE_USER="${KS_USER:-androiddebugkey}" \
GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="${KS_PASS:-android}" \
	"$GODOT" --headless --path . --export-release Android "$OUT/scriptshot-android-test-arm64-release-template.apk"
