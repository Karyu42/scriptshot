#!/usr/bin/env python3
"""Merge several bench.json files from repeated runs of the same benchmark into one.

    python3 tools/ci/merge_bench.py OUT.json IN1.json [IN2.json ...]

Used by tools/ci/perf_ab.sh, which runs base (main) and head alternately in rounds on the same runner
(base, head, then head, base, ...) so slow drift during the job cancels out. Per bullet count:
  * work_p50/p95/p99_ms: the median over the rounds (2 rounds = the mean). If any round has a missing,
    non-numeric, NaN, infinite or negative value for a key, the merged value is null, so check_perf.py
    reports it as an invalid timing instead of hiding it behind a good round.
  * reached: false if any round fell short; min_alive_before_step: the minimum over the rounds.
  * A count missing from any round is left out (check_perf.py then reports "no result").
  * work_p95_samples_ms: every round's p95, for the summary/artifact.
Top-level keys come from the first file, plus "rounds". hooked_fraction must be identical in every file,
otherwise it is set to null (check_perf.py then fails the hooked tier). Exit 1 on an unreadable input.
"""
import json
import math
import statistics
import sys

TIMING_KEYS = ("work_p50_ms", "work_p95_ms", "work_p99_ms")


def _ok(v):
    return not isinstance(v, bool) and isinstance(v, (int, float)) and math.isfinite(v) and v >= 0


def merge(docs):
    out = {k: v for k, v in docs[0].items() if k != "results"}
    out["rounds"] = len(docs)
    fracs = [d.get("hooked_fraction") for d in docs]
    if "hooked_fraction" in docs[0] or any(f is not None for f in fracs):
        out["hooked_fraction"] = fracs[0] if all(f == fracs[0] and type(f) is type(fracs[0]) for f in fracs) else None
    per = [{int(r["bullets"]): r for r in d["results"]} for d in docs]
    counts = sorted(set(per[0]).intersection(*per[1:]))
    results = []
    for n in counts:
        rows = [p[n] for p in per]
        m = dict(rows[0])
        for k in TIMING_KEYS:
            vals = [r.get(k) for r in rows]
            m[k] = float(statistics.median(vals)) if all(_ok(v) for v in vals) else None
        m["work_p95_samples_ms"] = [r.get("work_p95_ms") if _ok(r.get("work_p95_ms")) else None for r in rows]
        m["reached"] = all(r.get("reached") is not False for r in rows)
        alive = [r.get("min_alive_before_step") for r in rows if isinstance(r.get("min_alive_before_step"), int)]
        if alive:
            m["min_alive_before_step"] = min(alive)
        results.append(m)
    out["results"] = results
    return out


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) < 2:
        print("usage: merge_bench.py OUT.json IN.json [IN.json ...]", file=sys.stderr)
        return 2
    docs = []
    for p in argv[1:]:
        try:
            with open(p) as f:
                d = json.load(f)
            if not isinstance(d, dict) or not isinstance(d.get("results"), list):
                raise ValueError("no results list")
            for r in d["results"]:
                int(r["bullets"])
            docs.append(d)
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"::error::merge_bench.py: cannot read {p}: {e}")
            return 1
    with open(argv[0], "w") as f:
        json.dump(merge(docs), f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
