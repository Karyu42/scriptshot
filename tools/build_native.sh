#!/usr/bin/env bash
# Builds the native bullet core (GDExtension) with SCons into bin/<platform>.<arch>/.
# See docs/native.md. Binaries are gitignored.
#
#   ./tools/build_native.sh                         # linux x86_64, debug and release
#   ./tools/build_native.sh linux release           # one target
#   ./tools/build_native.sh windows                 # x86_64 MSVC on Windows (Git Bash). Shipped library.
#   ./tools/build_native.sh windows --dev-mingw     # dev-only MinGW cross-build, not for release
#   ./tools/build_native.sh macos                   # universal arm64+x86_64; run on macOS
#   ./tools/build_native.sh web                     # wasm32, threads off (the export preset)
#   ./tools/build_native.sh android                 # arm64, NDK 29.0.14206865
#   ./tools/build_native.sh all
#
# The target word is debug, release, or both (default both). --dev-mingw may appear
# before or after the platform and target. It applies only to windows (and all).
# SCRIPTSHOT_NATIVE_LTO overrides godot-cpp's lto=auto (full on linux, MinGW, and web).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# linux / macos / windows / other. Git Bash reports MINGW* or MSYS*.
host_os() {
	local u
	u="$(uname -s)"
	case "$u" in
		Linux) echo linux ;;
		Darwin) echo macos ;;
		MINGW*|MSYS*|CYGWIN*|Windows*) echo windows ;;
		*) echo other ;;
	esac
}

# GUT (windows, native) ships this library. The phrase is the refusal text.
shipped_windows_lib_message() {
	echo "build_native.sh: the shipped Windows lib is MSVC-built on Windows (GUT (windows, native) on windows-latest). Refusing platform=windows on this host. --dev-mingw is a dev-only MinGW cross-build and is not for release."
}

# godot-cpp tools/windows.py selects MSVC when use_mingw is unset and
# SCons msvc.exists(env) is true. msvc.exists() is msvc_exists() (SCons 4.10).
msvc_available() {
	local py
	for py in python3 python py; do
		if ! command -v "$py" >/dev/null 2>&1; then
			continue
		fi
		if ! "$py" -c 'from SCons.Tool.MSCommon import msvc_exists' >/dev/null 2>&1; then
			continue
		fi
		if "$py" -c 'from SCons.Tool.MSCommon import msvc_exists; raise SystemExit(0 if msvc_exists() else 1)'; then
			return 0
		fi
		echo "build_native.sh: MSVC was not found (SCons msvc_exists() is false). The shipped Windows lib is MSVC-built on Windows (GUT (windows, native) on windows-latest; godot-cpp selects MSVC when use_mingw is left unset). Install the Visual Studio C++ toolset and retry, or pass --dev-mingw for a dev-only MinGW build that is not for release." >&2
		return 1
	done
	echo "build_native.sh: scons is on PATH but Python could not import SCons to check for MSVC. The shipped Windows lib is MSVC-built on Windows." >&2
	return 1
}

dev_mingw=0
positionals=()
for arg in "$@"; do
	case "$arg" in
		--dev-mingw) dev_mingw=1 ;;
		-*)
			echo "build_native.sh: unknown option ${arg}. The only option is --dev-mingw (dev-only MinGW Windows build, not for release)." >&2
			exit 1
			;;
		*) positionals+=("$arg") ;;
	esac
done
if [[ "${#positionals[@]}" -gt 2 ]]; then
	echo "build_native.sh: too many arguments (platform and optional target; --dev-mingw is the only flag)." >&2
	exit 1
fi
platform=linux
target_word=both
if [[ "${#positionals[@]}" -ge 1 ]]; then
	platform="${positionals[0]}"
fi
if [[ "${#positionals[@]}" -ge 2 ]]; then
	target_word="${positionals[1]}"
fi

case "$target_word" in
	debug|release|both|template_debug|template_release) ;;
	*)
		echo "build_native.sh: target must be debug, release, or both (got ${target_word})" >&2
		exit 1
		;;
esac

if [[ "$dev_mingw" -eq 1 && "$platform" != "windows" && "$platform" != "all" ]]; then
	echo "build_native.sh: --dev-mingw applies only to platform windows (dev-only MinGW, not for release)." >&2
	exit 1
fi

# Fail before submodule init so a Linux/macOS windows request stays offline.
if [[ ( "$platform" == "windows" || "$platform" == "all" ) && "$dev_mingw" -eq 0 && "$(host_os)" != "windows" ]]; then
	shipped_windows_lib_message >&2
	exit 1
fi

cd "$root/native"
git submodule update --init --depth 1 godot-cpp 2>/dev/null || git submodule update --init godot-cpp

jobs="${SCRIPTSHOT_NATIVE_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"

if ! command -v scons >/dev/null 2>&1; then
	echo "build_native.sh: scons is not on PATH (pip install scons==4.10.1)" >&2
	exit 1
fi

if [[ ( "$platform" == "windows" || "$platform" == "all" ) && "$dev_mingw" -eq 0 && "$(host_os)" == "windows" ]]; then
	msvc_available || exit 1
fi

targets=()
case "$target_word" in
	debug) targets=(template_debug) ;;
	release) targets=(template_release) ;;
	both) targets=(template_debug template_release) ;;
	template_debug|template_release)
		targets=("$target_word")
		;;
esac

# Extra scons arguments for one platform. Printed by the caller.
platform_args() {
	case "$1" in
		linux)
			printf '%s\n' arch=x86_64
			;;
		windows)
			# CI's GUT (windows, native) job runs `./tools/build_native.sh windows`
			# on windows-latest and does not pass use_mingw. godot-cpp 10.0.0
			# (tools/windows.py) then selects MSVC when msvc.exists(env):
			#   scons platform=windows target=template_{debug,release} arch=x86_64 use_static_cpp=yes
			# use_static_cpp=yes is /MT. Default threads=yes (no .nothreads suffix).
			# Output: bin/windows.x86_64/libscriptshot_native.windows.template_<target>.x86_64.dll
			printf '%s\n' arch=x86_64 use_static_cpp=yes
			if [[ "$dev_mingw" -eq 1 ]]; then
				printf '%s\n' use_mingw=yes
				# Linux cross uses MinGW. Ubuntu's default MinGW is the win32
				# thread model, which has no std::thread. Prefer the posix
				# compiler when it is installed. Dev-only, not for release.
				if [[ "$(uname -s)" == "Linux" ]]; then
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
			elif [[ "$(host_os)" != "windows" ]]; then
				shipped_windows_lib_message >&2
				return 1
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
	if [[ "$name" == "windows" && "$dev_mingw" -eq 1 ]]; then
		echo "build_native.sh: --dev-mingw is dev-only and not for release." >&2
	fi
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
