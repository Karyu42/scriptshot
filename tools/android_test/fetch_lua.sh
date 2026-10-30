#!/usr/bin/env bash
# Fetch lua-gdextension 0.8.2 (stock release, Lua 5.4) into addons/lua-gdextension/ (git-ignored).
# Test harness only. Usage: tools/android_test/fetch_lua.sh [path/to/lua-gdextension.zip]
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=0.8.2
SHA256=51f012dd8f53b2c8e44c6910a5d675614e3151f85f61055d24a9dce9eb0f2443
ZIP="${1:-}"
if [ -z "$ZIP" ]; then
	ZIP="$(mktemp -d)/lua-gdextension.zip"
	curl -fsSL -o "$ZIP" "https://github.com/gilzoide/lua-gdextension/releases/download/$VERSION/lua-gdextension.zip"
fi
echo "$SHA256  $ZIP" | sha256sum -c -
rm -rf addons/lua-gdextension
unzip -q -o "$ZIP" 'addons/lua-gdextension/*' -d .
ls addons/lua-gdextension/build | grep -c android || true
