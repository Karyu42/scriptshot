#!/usr/bin/env bash
# Same-runner A/B bullet benchmark for the CI perf gate (tools/ci/check_perf.py).
#
#   tools/ci/perf_ab.sh --out=reports [--base=PATH_TO_BASE_CHECKOUT] [--rounds=2]
#
# Runs the plain tier (--bullets=2000,5000,10000) and the hooked tier (--hooked=1.0, --bullets=5000,10000)
# of ./tools/run_benchmark.sh. With --base (a checkout of the PR base, e.g. a git worktree of main), the base
# and the head are run alternately on this same runner, ABBA order per round so slow drift cancels out:
#   round 1: base, head    round 2: head, base    round 3: base, head ...
# Each tree runs its own tools/run_benchmark.sh and its own benchmark scene. Rounds are merged per count with
# tools/ci/merge_bench.py (median of the p95s; 2 rounds = the mean). Without --base, the head runs --rounds times
# alone (CI uses 1 round there, same as before).
#
# Writes to --out: bench.json, bench-hooked.json (head) and, with a usable base, base-bench.json and
# base-bench-hooked.json, plus raw/<tree>-<tier>-r<N>.json and logs/<tree>-<tier>-r<N>.log.
# Exit 1 if a HEAD run hit an import/script error or left no JSON. A failing BASE run only prints a
# ::warning:: and drops the base files: check_perf.py then uses the absolute budgets (never looser).
# A benchmark's own non-zero exit (its built-in 16.6 ms floor check) is ignored here: check_perf.py is the gate.
set -uo pipefail
HEAD_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="" BASE="" ROUNDS=2
for arg in "$@"; do
	case "$arg" in
		--out=*) OUT="${arg#--out=}" ;;
		--base=*) BASE="${arg#--base=}" ;;
		--rounds=*) ROUNDS="${arg#--rounds=}" ;;
		*) echo "perf_ab.sh: unknown argument $arg" >&2; exit 2 ;;
	esac
done
[ -n "$OUT" ] || { echo "perf_ab.sh: --out=DIR is required" >&2; exit 2; }
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || { echo "perf_ab.sh: --rounds must be a positive integer" >&2; exit 2; }
if [ -n "$BASE" ]; then
	BASE="$(cd "$BASE" && pwd)" || { echo "perf_ab.sh: base dir not found" >&2; exit 2; }
	[ -x "$BASE/tools/run_benchmark.sh" ] || { echo "::warning::base has no tools/run_benchmark.sh; absolute gates only"; BASE=""; }
fi
mkdir -p "$OUT/raw" "$OUT/logs"
OUT="$(cd "$OUT" && pwd)"

# shellcheck disable=SC2054  # the commas are inside --bullets=, not array separators
PLAIN_ARGS=(--bullets=2000,5000,10000 --floor-bullets=5000 --target-bullets=10000 --target-ms=16.6)
# shellcheck disable=SC2054
HOOKED_ARGS=(--bullets=5000,10000 --hooked=1.0 --floor-bullets=5000 --target-bullets=10000 --target-ms=16.6)
base_ok=1

# bench <tree:head|base> <tier:plain|hooked> <round>. Returns 1 if the run is unusable.
bench() {
	local tree="$1" tier="$2" round="$3" dir args json log rc
	if [ "$tree" = base ]; then dir="$BASE"; else dir="$HEAD_DIR"; fi
	if [ "$tier" = plain ]; then args=("${PLAIN_ARGS[@]}"); else args=("${HOOKED_ARGS[@]}"); fi
	json="$OUT/raw/$tree-$tier-r$round.json"
	log="$OUT/logs/$tree-$tier-r$round.log"
	echo "::group::perf_ab.sh: $tree $tier, round $round ($(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?'))"
	rm -f "$json"
	"$dir/tools/run_benchmark.sh" "${args[@]}" --json="$json" 2>&1 | tee "$log"
	rc=${PIPESTATUS[0]}
	echo "::endgroup::"
	if grep -q '^run_benchmark.sh:' "$log"; then
		echo "perf_ab.sh: $tree $tier round $round failed on import/script errors (exit $rc)" >&2
		return 1
	fi
	if [ ! -s "$json" ]; then
		echo "perf_ab.sh: $tree $tier round $round produced no JSON (exit $rc)" >&2
		return 1
	fi
	return 0
}

run_tree() {  # run_tree <tree> <round>
	local tree="$1" round="$2" tier
	for tier in plain hooked; do
		if [ "$tree" = base ]; then
			[ "$base_ok" -eq 1 ] || return 0
			bench base "$tier" "$round" || { echo "::warning::base (main) benchmark failed ($tier, round $round); falling back to the absolute budgets"; base_ok=0; }
		else
			bench head "$tier" "$round" || { echo "::error::$tier benchmark of the PR head failed (round $round, see the log above)"; exit 1; }
		fi
	done
}

for ((r = 1; r <= ROUNDS; r++)); do
	if [ -z "$BASE" ]; then
		run_tree head "$r"
	elif ((r % 2 == 1)); then
		run_tree base "$r"; run_tree head "$r"
	else
		run_tree head "$r"; run_tree base "$r"
	fi
done

merge() {  # merge <out> <tree> <tier>
	local files=() r
	for ((r = 1; r <= ROUNDS; r++)); do files+=("$OUT/raw/$2-$3-r$r.json"); done
	python3 "$HEAD_DIR/tools/ci/merge_bench.py" "$1" "${files[@]}"
}
merge "$OUT/bench.json" head plain || exit 1
merge "$OUT/bench-hooked.json" head hooked || exit 1
rm -f "$OUT/base-bench.json" "$OUT/base-bench-hooked.json"
if [ -n "$BASE" ] && [ "$base_ok" -eq 1 ]; then
	merge "$OUT/base-bench.json" base plain || rm -f "$OUT/base-bench.json"
	merge "$OUT/base-bench-hooked.json" base hooked || rm -f "$OUT/base-bench-hooked.json"
fi
exit 0
