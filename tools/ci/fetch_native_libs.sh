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

# GitHub's /releases/download URL has been answering GET with HTTP 504 while a
# HEAD still redirects to a signed release-assets URL that serves the zip.
# Resolve that redirect and download the target. Fall back to the original URL.
download_release_zip() {
	local url="$1" dest="$2" attempt loc
	for attempt in 1 2 3 4 5; do
		loc=$(curl -sI --max-time 30 "$url" | tr -d '\r' | awk 'tolower($1)=="location:" {print $2; exit}')
		if [ -n "$loc" ] && curl -fL --retry 3 --retry-delay 2 --retry-all-errors --max-time 180 -o "$dest" "$loc"; then
			return 0
		fi
		echo "fetch_native_libs.sh: download attempt ${attempt} failed" >&2
		sleep $((attempt * 2))
	done
	curl -fL --retry 5 --retry-delay 2 --retry-all-errors --max-time 180 -o "$dest" "$url"
}

echo "fetch_native_libs.sh: downloading lua-gdextension ${VERSION} (${platform})"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
download_release_zip "$URL" "$tmp/lua.zip"
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
