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
# Runs under macOS /bin/bash 3.2 and Git Bash too (see tools/run_tests.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."

VERSION=0.8.2
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

# The browser download URL (github.com/.../releases/download) has been answering
# CI runners with HTTP 504. The release API asset endpoint still serves the zip.
download_release_zip() {
	local dest="$1" attempt asset
	local -a auth
	auth=()
	if [ -n "${GITHUB_TOKEN:-}" ]; then
		auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	fi
	for attempt in 1 2 3 4 5; do
		asset=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 60 ${auth[@]+"${auth[@]}"} \
			"https://api.github.com/repos/gilzoide/lua-gdextension/releases/tags/${VERSION}" \
			| python3 -c 'import json,sys
d=json.load(sys.stdin)
for a in d.get("assets", []):
    if a.get("name") == "lua-gdextension.zip":
        print(a["url"])
        break') || asset=""
		if [ -n "$asset" ] && curl -fL --retry 3 --retry-delay 2 --retry-all-errors --max-time 180 \
			-H "Accept: application/octet-stream" ${auth[@]+"${auth[@]}"} -o "$dest" "$asset"; then
			return 0
		fi
		echo "fetch_native_libs.sh: download attempt ${attempt} failed" >&2
		sleep $((attempt * 2))
	done
	return 1
}

echo "fetch_native_libs.sh: downloading lua-gdextension ${VERSION} (${platform})"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
download_release_zip "$tmp/lua.zip"
# sha256sum (Linux, Git Bash) or shasum -a 256 (macOS has no sha256sum before 14 / without coreutils).
if command -v sha256sum >/dev/null 2>&1; then
	echo "$SHA256  $tmp/lua.zip" | sha256sum -c -
else
	echo "$SHA256  $tmp/lua.zip" | shasum -a 256 -c -
fi
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
