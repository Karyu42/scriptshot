#!/usr/bin/env python3
"""Fail CI if the bullet benchmark blows the frame-time budget.

Consumes the JSON written by `tools/run_benchmark.sh --json=PATH`
(tests/benchmark/bullet_benchmark.gd):

    {"godot": "...", "target": "...",
     "results": [{"bullets": 5000, "work_p50_ms": .., "work_p95_ms": .., "work_p99_ms": ..,
                  "work_max_ms": .., "wall_*": .., "alive_at_end": ..}, ...]}

"work" is CPU time of one game tick of bullet work (headless, dummy renderer); "wall" is the
engine frame interval and is paced by headless mode, so it is ignored here.
"""
import argparse
import json
import sys


def load(path):
    with open(path) as f:
        data = json.load(f)
    return {r["bullets"]: r for r in data["results"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--target-bullets", type=int, required=True)
    ap.add_argument("--p95-ms", type=float, default=16.6)
    ap.add_argument("--baseline", help="earlier bench.json to compare against")
    ap.add_argument("--regression-pct", type=float, default=25.0)
    a = ap.parse_args()

    cur = load(a.report)
    print("| bullets | work p50 ms | work p95 ms | work p99 ms |")
    print("|---:|---:|---:|---:|")
    for n, r in sorted(cur.items()):
        print(f"| {n} | {r['work_p50_ms']:.2f} | {r['work_p95_ms']:.2f} | {r['work_p99_ms']:.2f} |")
    if a.target_bullets not in cur:
        print(f"::error::no result for target bullet count {a.target_bullets}")
        return 1

    ok = True
    p95 = cur[a.target_bullets]["work_p95_ms"]
    if p95 > a.p95_ms:
        print(f"::error::p95 {p95:.2f} ms > budget {a.p95_ms} ms at {a.target_bullets} bullets")
        ok = False
    if a.baseline:
        base = load(a.baseline).get(a.target_bullets)
        if base and p95 > base["work_p95_ms"] * (1 + a.regression_pct / 100):
            print(f"::error::p95 regressed >{a.regression_pct}% vs baseline "
                  f"({base['work_p95_ms']:.2f} -> {p95:.2f} ms)")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
