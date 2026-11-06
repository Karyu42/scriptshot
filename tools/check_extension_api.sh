#!/usr/bin/env bash
# Verifies that the pinned godot-cpp (native/godot-cpp) was generated from the
# same extension API as the Godot binary we target, by dumping the API from the
# binary and diffing it (ignoring the version header) against godot-cpp's
# gdextension/extension_api-4-7.json. CI can run the same script.
#
#   ./tools/check_extension_api.sh          # uses $GODOT or `godot` from PATH
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
API_FILE="${API_FILE:-native/godot-cpp/gdextension/extension_api-4-7.json}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && "$GODOT" --headless --dump-extension-api >/dev/null 2>&1)
python3 - "$tmp/extension_api.json" "$API_FILE" <<'PY'
import json, sys
dumped = json.load(open(sys.argv[1]))
pinned = json.load(open(sys.argv[2]))
dv, pv = dumped.pop("header"), pinned.pop("header")
print("godot binary :", dv["version_full_name"])
print("godot-cpp api:", pv["version_full_name"])
if dumped == pinned:
    print("OK: extension APIs are identical (apart from the version header)")
    sys.exit(0)
for key in dumped:
    if dumped[key] != pinned.get(key):
        print("DIFFERS:", key)
sys.exit(1)
PY
