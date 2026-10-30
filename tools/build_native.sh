#!/usr/bin/env bash
# Builds the native bullet core (GDExtension) with SCons into bin/<platform>/.
# PROTOTYPE: only linux x86_64 is wired up and tested. See docs/native.md.
#
#   ./tools/build_native.sh                      # template_release
#   ./tools/build_native.sh template_debug       # debug build
set -euo pipefail
cd "$(dirname "$0")/../native"
git submodule update --init --depth 1 godot-cpp 2>/dev/null || git submodule update --init godot-cpp
target="${1:-template_release}"
exec scons platform=linux arch=x86_64 target="$target" -j"$(nproc)"
