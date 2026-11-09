#!/usr/bin/env bash
# Linux/macOS: platform=windows fails closed unless --dev-mingw (dev-only, not for release).
# Does not compile. Stubs git and scons so the opt-in path can be checked offline.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/tools/build_native.sh"
host="$(uname -s)"
case "$host" in
	Linux|Darwin) ;;
	*)
		echo "test_build_native_windows.sh: this check runs on Linux or macOS (got ${host})." >&2
		exit 1
		;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/invocations"
: >"$log"

cat >"$tmp/git" <<'EOF'
#!/bin/sh
printf 'git %s\n' "$*" >>"$STUB_LOG"
exit 0
EOF
cat >"$tmp/scons" <<'EOF'
#!/bin/sh
printf 'scons %s\n' "$*" >>"$STUB_LOG"
exit 0
EOF
chmod +x "$tmp/git" "$tmp/scons"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_refuses() {
	local label="$1"
	shift
	local out err rc
	out="$tmp/out"
	err="$tmp/err"
	: >"$log"
	set +e
	env STUB_LOG="$log" PATH="$tmp:$PATH" "$build" "$@" >"$out" 2>"$err"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "$label: expected non-zero exit, got 0"
	grep -q "the shipped Windows lib is MSVC-built on Windows" "$err" \
		|| fail "$label: missing shipped-lib message: $(cat "$err")"
	[[ ! -s "$log" ]] || fail "$label: should exit before git or scons: $(cat "$log")"
	[[ ! -s "$out" ]] || fail "$label: unexpected stdout: $(cat "$out")"
}

assert_dev_mingw() {
	local label="$1"
	local target="$2"
	shift 2
	local out err rc
	out="$tmp/out"
	err="$tmp/err"
	: >"$log"
	set +e
	env STUB_LOG="$log" PATH="$tmp:$PATH" "$build" "$@" >"$out" 2>"$err"
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || fail "$label: exit $rc stderr=$(cat "$err") stdout=$(cat "$out")"
	grep -q "dev-only" "$err" || fail "$label: stderr missing dev-only: $(cat "$err")"
	grep -q "not for release" "$err" || fail "$label: stderr missing not-for-release: $(cat "$err")"
	if grep -q "the shipped Windows lib is MSVC-built on Windows" "$err"; then
		fail "$label: dev flag still printed the refusal: $(cat "$err")"
	fi
	grep -q "platform=windows target=${target} arch=x86_64 use_static_cpp=yes use_mingw=yes" "$out" \
		|| fail "$label: stdout missing MSVC-shaped args plus use_mingw: $(cat "$out")"
	grep -q -E "^scons platform=windows target=${target} arch=x86_64 use_static_cpp=yes use_mingw=yes -j[0-9]+$" "$log" \
		|| fail "$label: scons was not invoked with those args: $(cat "$log")"
}

# Stubs are on PATH so a regression that reaches git or scons is recorded, not built.
assert_refuses "windows" windows
assert_refuses "windows both" windows both
assert_refuses "windows debug" windows debug
assert_refuses "all" all

assert_dev_mingw "flag after platform" template_debug windows debug --dev-mingw
assert_dev_mingw "flag before platform" template_release --dev-mingw windows release
assert_dev_mingw "flag between" template_debug windows --dev-mingw debug

# Both targets, flag first.
: >"$log"
set +e
env STUB_LOG="$log" PATH="$tmp:$PATH" "$build" --dev-mingw windows >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "both targets: exit $rc $(cat "$tmp/err")"
grep -q "target=template_debug arch=x86_64 use_static_cpp=yes use_mingw=yes" "$tmp/out" \
	|| fail "both targets: missing debug line: $(cat "$tmp/out")"
grep -q "target=template_release arch=x86_64 use_static_cpp=yes use_mingw=yes" "$tmp/out" \
	|| fail "both targets: missing release line: $(cat "$tmp/out")"
grep -c '^scons ' "$log" | grep -q '^2$' || fail "both targets: expected 2 scons calls: $(cat "$log")"

# Linux is unchanged: arch=x86_64, no use_mingw.
: >"$log"
set +e
env STUB_LOG="$log" PATH="$tmp:$PATH" "$build" linux debug >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "linux: exit $rc $(cat "$tmp/err")"
grep -q "platform=linux target=template_debug arch=x86_64" "$tmp/out" || fail "linux stdout: $(cat "$tmp/out")"
if grep -q 'use_mingw' "$tmp/out" "$log"; then
	fail "linux build passed use_mingw: $(cat "$tmp/out") $(cat "$log")"
fi

# The flag is not a MinGW switch for other platforms.
set +e
env STUB_LOG="$log" PATH="$tmp:$PATH" "$build" --dev-mingw linux >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "--dev-mingw linux should fail"
grep -q "dev-only" "$tmp/err" || fail "--dev-mingw linux stderr: $(cat "$tmp/err")"
grep -q "not for release" "$tmp/err" || fail "--dev-mingw linux missing not-for-release: $(cat "$tmp/err")"

echo "test_build_native_windows.sh: ok"
