#!/usr/bin/env python3
"""Gate CI on the headless bullet benchmark.

Input: the JSON from `tools/run_benchmark.sh --json=PATH` (tests/benchmark/bullet_benchmark.gd):

    {"godot": "...", "target": "...",
     "target_bullets": .., "target_ms": ..,
     "results": [{"bullets": 5000, "work_p50_ms": .., "work_p95_ms": .., "work_p99_ms": ..,
                  "reached": true, "min_alive_before_step": 4966, ...}, ...]}

Policy (agreed targets):
  * FLOOR   (default 5,000 bullets):  p95 > budget, no result, or a shortfall -> HARD FAIL (exit 1)
  * TARGET  (default 10,000 bullets): p95 > budget, no result, or a shortfall -> ::warning:: + summary line, exit 0
    A "shortfall" is the benchmark's own `"reached": false` (fewer bullets alive than requested on some
    measured frame), which would otherwise let a run that simulates less than it claims look fast.
  * Optional --baseline: p95 regression > --regression-pct at FLOOR fails, at TARGET warns.

"work" is the CPU time of one tick of bullet work on the headless dummy renderer. It is not a GPU
or rendering measurement (see docs/qa/stress-test-plan.md). The full results table and verdict
lines are appended to --summary (pass "$GITHUB_STEP_SUMMARY"); annotations go to stdout.
"""
import argparse
import json
import sys


def load(path):
    with open(path) as f:
        data = json.load(f)
    return {int(r["bullets"]): r for r in data["results"]}


def fmt(r, key):
    return f"{r[key]:.2f}"


def table(results, floor, target, budget):
    lines = [
        f"### Bullet benchmark (headless CPU work per tick, budget p95 <= {budget} ms)",
        "",
        "| bullets | role | work p50 ms | work p95 ms | work p99 ms | verdict |",
        "|---:|---|---:|---:|---:|---|",
    ]
    for n, r in sorted(results.items()):
        role = "floor" if n == floor else "target" if n == target else ""
        if role:
            ok = r["work_p95_ms"] <= budget and r.get("reached") is not False
            verdict = "pass" if ok else ("**FAIL**" if role == "floor" else "over budget / shortfall (warning)")
        else:
            verdict = "info"
        lines.append(f"| {n} | {role} | {fmt(r, 'work_p50_ms')} | {fmt(r, 'work_p95_ms')} | "
                     f"{fmt(r, 'work_p99_ms')} | {verdict} |")
    return lines


def check(results, floor, target, budget, baseline=None, regression_pct=25.0):
    """Returns (exit_code, annotations, summary_lines)."""
    errors, warnings, notes = [], [], []

    def judge(n, role, sink):
        r = results.get(n)
        if r is None:
            sink.append(f"no result for {role} count of {n} bullets (was it passed to --bullets?)")
            return
        if r.get("reached") is False:
            sink.append(f"shortfall at {n} bullets ({role}): only {r.get('min_alive_before_step', '?')} were alive "
                        f"on the slowest-filled frame, so the timing is not valid")
        p95 = r["work_p95_ms"]
        if p95 > budget:
            sink.append(f"p95 {p95:.2f} ms > budget {budget} ms at {n} bullets ({role})")
        else:
            notes.append(f"{n} bullets ({role}): p50 {r['work_p50_ms']:.2f} / p95 {p95:.2f} / "
                         f"p99 {r['work_p99_ms']:.2f} ms, within {budget} ms")
        if baseline is not None and n in baseline:
            b = baseline[n]["work_p95_ms"]
            if p95 > b * (1 + regression_pct / 100):
                sink.append(f"p95 regressed more than {regression_pct:g}% vs baseline at {n} bullets "
                            f"({b:.2f} -> {p95:.2f} ms, {role})")

    judge(floor, "hard floor", errors)
    judge(target, "target", warnings)

    annotations = [f"::error::{m}" for m in errors] + [f"::warning::{m}" for m in warnings]
    summary = table(results, floor, target, budget) + [""]
    summary += [f"- :x: **FAIL** {m}" for m in errors]
    summary += [f"- :warning: **WARNING** {m}" for m in warnings]
    summary += [f"- :white_check_mark: {m}" for m in notes]
    summary += ["", "_Headless dummy renderer: CPU simulation cost only, not GPU time._"]
    return (1 if errors else 0), annotations, summary


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report")
    ap.add_argument("--p95-ms", type=float, default=16.6, help="p95 budget in ms (default 16.6)")
    ap.add_argument("--floor-bullets", type=int, default=5000, help="hard-fail count (default 5000)")
    ap.add_argument("--target-bullets", type=int, default=10000, help="warn-only count (default 10000)")
    ap.add_argument("--baseline", help="earlier bench.json to compare against")
    ap.add_argument("--regression-pct", type=float, default=25.0)
    ap.add_argument("--summary", help="append the markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    a = ap.parse_args(argv)

    try:
        results = load(a.report)
    except (OSError, ValueError, KeyError) as e:
        print(f"::error::cannot read benchmark results from {a.report}: {e}")
        return 1
    baseline = load(a.baseline) if a.baseline else None

    code, annotations, summary = check(results, a.floor_bullets, a.target_bullets, a.p95_ms,
                                       baseline, a.regression_pct)
    print("\n".join(summary))
    print("\n".join(annotations))
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("\n".join(summary) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
