#!/usr/bin/env bash
# Fetches stock lua-gdextension 0.8.2 (Lua 5.4, not LuaJIT) into addons/lua-gdextension/.
# The release zip holds every platform library. The optional platform argument
# (linux.x86_64, windows.x86_64, web.wasm32, ...) is accepted so CI can name a
# target; it is not used to filter the zip. Binaries are never committed.
#
# SHA256 of the 0.8.2 release zip:
#   51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443
#
# Cold-import SIGSEGV workaround (https://github.com/Karyu42/scriptshot/issues/7):
# pre-seed .godot/extension_list.cfg before the first editor import. Do not file
# this against lua-gdextension or godotengine/godot.
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=0.8.2
URL="https://github.com/gilzoide/lua-gdextension/releases/download/${VERSION}/lua-gdextension.zip"
SHA256="51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443"
DEST=addons/lua-gdextension
EXT_LINE='res://addons/lua-gdextension/luagdextension.gdextension'
platform="${1:-all}"

seed_extension_list() {
	mkdir -p .godot
	local f=.godot/extension_list.cfg
	if [ -f "$f" ] && grep -qxF "$EXT_LINE" "$f"; then
		return 0
	fi
	if [ -f "$f" ]; then
		printf '%s\n' "$EXT_LINE" >> "$f"
	else
		printf '%s\n' "$EXT_LINE" > "$f"
	fi
}

if [ -f "$DEST/.pinned-$VERSION" ]; then
	seed_extension_list
	exit 0
fi

echo "fetch_native_libs.sh: downloading lua-gdextension ${VERSION} (${platform})"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 "$URL" -o "$tmp/lua.zip"
echo "$SHA256  $tmp/lua.zip" | sha256sum -c -
unzip -q "$tmp/lua.zip" -d "$tmp/x"
if [ ! -f "$tmp/x/addons/lua-gdextension/luagdextension.gdextension" ]; then
	echo "fetch_native_libs.sh: zip is missing addons/lua-gdextension/luagdextension.gdextension" >&2
	exit 1
fi
mkdir -p "$DEST"
find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "$tmp/x/addons/lua-gdextension/." "$DEST/"
touch "$DEST/.pinned-$VERSION"
seed_extension_list
echo "fetch_native_libs.sh: installed ${DEST} (pinned ${VERSION})"
