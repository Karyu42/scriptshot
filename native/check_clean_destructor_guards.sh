#!/usr/bin/env bash
# Clean first template_debug build must emit builtin destructor guards.
# Usage: from repo root or native/, ./native/check_clean_destructor_guards.sh
set -euo pipefail
native="$(cd "$(dirname "$0")" && pwd)"
cd "$native"
if [ ! -d godot-cpp/.git ] && [ ! -f godot-cpp/.git ]; then
	echo "check_clean_destructor_guards.sh: godot-cpp submodule is missing" >&2
	exit 1
fi
# gen/ is gitignored; git clean -x plus rm so a leftover empty tree cannot
# be mistaken for a previous generation.
if [ -e godot-cpp/gen ]; then
	echo "check_clean_destructor_guards.sh: git clean -fdx -- gen"
	git -C godot-cpp clean -fdx -- gen || true
	rm -rf godot-cpp/gen
fi
if [ -e godot-cpp/gen ]; then
	echo "check_clean_destructor_guards.sh: gen/ still present after git clean" >&2
	exit 1
fi
if ! command -v scons >/dev/null 2>&1; then
	echo "check_clean_destructor_guards.sh: scons is not on PATH" >&2
	exit 1
fi
jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "check_clean_destructor_guards.sh: scons platform=linux target=template_debug -j${jobs}"
scons platform=linux target=template_debug -j"$jobs"
python3 "$native/scriptshot_binding_hooks.py"
