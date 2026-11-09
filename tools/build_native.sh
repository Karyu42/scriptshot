#!/usr/bin/env bash
# Builds the native bullet core (GDExtension) with SCons into bin/<platform>.<arch>/.
# See docs/native.md. Binaries are gitignored.
#
#   ./tools/build_native.sh                         # linux x86_64, debug and release
#   ./tools/build_native.sh linux release           # one target
#   ./tools/build_native.sh windows                # x86_64; MinGW cross on Linux, MSVC on Windows
#   ./tools/build_native.sh macos                  # universal arm64+x86_64; run on macOS
#   ./tools/build_native.sh web                    # wasm32, threads off (the export preset)
#   ./tools/build_native.sh android                # arm64, NDK 29.0.14206865
#   ./tools/build_native.sh all
#
# The second argument is debug, release, or both (default both).
# SCRIPTSHOT_NATIVE_LTO overrides godot-cpp's lto=auto (full on linux, MinGW, and web).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/native"
git submodule update --init --depth 1 godot-cpp 2>/dev/null || git submodule update --init godot-cpp

platform="${1:-linux}"
target_word="${2:-both}"
jobs="${SCRIPTSHOT_NATIVE_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

if ! command -v scons >/dev/null 2>&1; then
	echo "build_native.sh: scons is not on PATH (pip install scons==4.10.1)" >&2
	exit 1
fi

targets=()
case "$target_word" in
	debug) targets=(template_debug) ;;
	release) targets=(template_release) ;;
	both) targets=(template_debug template_release) ;;
	template_debug|template_release)
		targets=("$target_word")
		;;
	*)
		echo "build_native.sh: target must be debug, release, or both (got ${target_word})" >&2
		exit 1
		;;
esac

# Extra scons arguments for one platform. Printed by the caller.
platform_args() {
	case "$1" in
		linux)
			printf '%s\n' arch=x86_64
			;;
		windows)
			printf '%s\n' arch=x86_64 use_static_cpp=yes
			# Linux cross uses MinGW. A Windows host leaves the compiler to
			# godot-cpp: MSVC when it is installed, MinGW otherwise.
			# Ubuntu's default MinGW is the win32 thread model, which has no
			# std::thread. Prefer the posix compiler when it is installed.
			if [[ "$(uname -s)" == "Linux" ]]; then
				printf '%s\n' use_mingw=yes
				if [[ -x /usr/bin/x86_64-w64-mingw32-g++-posix ]]; then
					local mingw_bin
					mingw_bin="$(mktemp -d)"
					ln -s /usr/bin/x86_64-w64-mingw32-g++-posix "$mingw_bin/x86_64-w64-mingw32-g++"
					ln -s /usr/bin/x86_64-w64-mingw32-gcc-posix "$mingw_bin/x86_64-w64-mingw32-gcc"
					if [[ -x /usr/bin/x86_64-w64-mingw32-gcc-ar ]]; then
						ln -s /usr/bin/x86_64-w64-mingw32-gcc-ar "$mingw_bin/x86_64-w64-mingw32-gcc-ar"
					fi
					if [[ -x /usr/bin/x86_64-w64-mingw32-ranlib ]]; then
						ln -s /usr/bin/x86_64-w64-mingw32-ranlib "$mingw_bin/x86_64-w64-mingw32-ranlib"
					fi
					export PATH="$mingw_bin:$PATH"
				fi
			fi
			;;
		macos)
			if [[ "$(uname -s)" != "Darwin" ]]; then
				echo "build_native.sh: macOS universal is an Apple clang -arch x86_64 -arch arm64 build. Run it on macOS." >&2
				return 1
			fi
			# x86_64 slice matches Godot 4.7.2's own floor (platform/macos/detect.py).
			# arm64 Godot requires 11.0; a 10.13 min still loads there.
			printf '%s\n' arch=universal macos_deployment_target=10.13
			;;
		web)
			if ! command -v emcc >/dev/null 2>&1; then
				echo "build_native.sh: emcc is not on PATH. Activate Emscripten 4.0.20 (the official 4.7.2 web export template) and retry." >&2
				return 1
			fi
			# export_presets.cfg Web preset: variant/thread_support=false.
			# threads=yes would emit the .wasm32.wasm (no .nothreads) side module.
			printf '%s\n' arch=wasm32 threads=no
			;;
		android)
			printf '%s\n' arch=arm64 ndk_version=29.0.14206865 android_api_level=24
			;;
		*)
			echo "build_native.sh: unknown platform ${1} (linux, windows, macos, web, android, all)" >&2
			return 1
			;;
	esac
}

build_platform() {
	local name="$1"
	local -a args=()
	local line args_file
	args_file="$(mktemp)"
	if ! platform_args "$name" >"$args_file"; then
		rm -f "$args_file"
		exit 1
	fi
	while IFS= read -r line; do
		[[ -n "$line" ]] && args+=("$line")
	done <"$args_file"
	rm -f "$args_file"
	if [[ -n "${SCRIPTSHOT_NATIVE_LTO:-}" ]]; then
		args+=(lto="$SCRIPTSHOT_NATIVE_LTO")
	fi
	local target
	for target in "${targets[@]}"; do
		echo "build_native.sh: scons platform=${name} target=${target} ${args[*]}"
		scons platform="$name" target="$target" "${args[@]}" -j"$jobs"
	done
}

if [[ "$platform" == "all" ]]; then
	for name in linux windows macos web android; do
		build_platform "$name"
	done
else
	build_platform "$platform"
fi
