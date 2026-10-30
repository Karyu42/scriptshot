#!/usr/bin/env python3
"""Fail CI if the bullet stress test blows the frame-time budget.

Input JSON: {"steps": [{"bullets": 5000, "p50_ms": 3.1, "p95_ms": 7.9, "p99_ms": 11.2}, ...]}
"""
import argparse, json, sys


def by_bullets(path):
    with open(path) as f:
        return {s["bullets"]: s for s in json.load(f)["steps"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--target-bullets", type=int, required=True)
    ap.add_argument("--p95-ms", type=float, default=16.6)
    ap.add_argument("--baseline", help="previous perf.json to compare against")
    ap.add_argument("--regression-pct", type=float, default=15.0)
    a = ap.parse_args()

    cur = by_bullets(a.report)
    for n, s in sorted(cur.items()):
        print(f"{n:>6} bullets  p50={s['p50_ms']:.2f}  p95={s['p95_ms']:.2f}  p99={s['p99_ms']:.2f} ms")
    if a.target_bullets not in cur:
        print(f"::error::no step for target bullet count {a.target_bullets}")
        return 1
    ok = True
    p95 = cur[a.target_bullets]["p95_ms"]
    if p95 > a.p95_ms:
        print(f"::error::p95 {p95:.2f} ms > budget {a.p95_ms} ms at {a.target_bullets} bullets")
        ok = False
    if a.baseline:
        base = by_bullets(a.baseline).get(a.target_bullets)
        if base and p95 > base["p95_ms"] * (1 + a.regression_pct / 100):
            print(f"::error::p95 regressed >{a.regression_pct}% vs baseline ({base['p95_ms']:.2f} -> {p95:.2f} ms)")
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
