#!/usr/bin/env python3
"""Gate CI on the headless bullet benchmark.

Input: the JSON from `tools/run_benchmark.sh --json=PATH` (tests/benchmark/bullet_benchmark.gd):

    {"godot": "...", "target": "...",
     "target_bullets": .., "target_ms": ..,
     "results": [{"bullets": 5000, "work_p50_ms": .., "work_p95_ms": .., "work_p99_ms": ..,
                  "reached": true, "min_alive_before_step": 4966, ...}, ...]}

Policy (agreed targets):
  * FLOOR   (default 5,000 bullets):  p95 > budget, no result, a bad timing, or a shortfall -> HARD FAIL (exit 1)
  * TARGET  (default 10,000 bullets): p95 > budget, no result, a bad timing, or a shortfall -> ::warning:: + summary line, exit 0
    A "shortfall" is the benchmark's own `"reached": false` (fewer bullets alive than requested on some
    measured frame), which would otherwise let a run that simulates less than it claims look fast.
    A shortfall is not also described as "within budget".
  * Timings, plain and hooked: a missing, non-numeric, NaN, infinite or negative work_p50/p95/p99 fails at
    FLOOR and warns at TARGET. `nan > budget` is false, so a NaN p95 must not pass silently.
  * Optional --baseline: p95 regression > --regression-pct at FLOOR fails, at TARGET warns.
    A missing or unreadable baseline file prints ::error:: and exits 1. It does not raise a traceback.
  * Optional --hooked-report: a second JSON from `run_benchmark.sh --hooked=1.0` (every bullet carries a no-op
    script hook). Same FLOOR/TARGET counts and the same policy (FLOOR hard fail, TARGET warning), but with its own
    budget, --hooked-target-ms (default: --p95-ms), because CI runs on GitHub-hosted runners that are much slower
    than a real device. The report must really be a hooked run (top-level "hooked_fraction" == 1.0).
  * The hooked/plain p95 ratio at the FLOOR and TARGET counts is always logged (stdout, summary, and --ratio-json),
    never gated; a missing, zero or non-finite value on either side shows as "n/a".

"work" is the CPU time of one tick of bullet work on the headless dummy renderer. It is not a GPU
or rendering measurement (see docs/qa/stress-test-plan.md). The full results table and verdict
lines are appended to --summary (pass "$GITHUB_STEP_SUMMARY"); annotations go to stdout.
"""
import argparse
import json
import math
import sys


def load(path):
    with open(path) as f:
        data = json.load(f)
    return {int(r["bullets"]): r for r in data["results"]}


def load_hooked(path):
    """Like load(), plus the run's top-level "hooked_fraction" (None if absent / not a number)."""
    with open(path) as f:
        data = json.load(f)
    frac = data.get("hooked_fraction")
    if isinstance(frac, bool) or not isinstance(frac, (int, float)):
        frac = None
    return {int(r["bullets"]): r for r in data["results"]}, frac


TIMING_KEYS = ("work_p50_ms", "work_p95_ms", "work_p99_ms")


def bad_timings(r):
    """Names of the timing fields that are missing, not numbers, NaN, infinite or negative."""
    bad = []
    for k in TIMING_KEYS:
        v = r.get(k)
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
            bad.append(k)
    return bad


def fmt(r, key):
    v = r.get(key)
    return f"{v:.2f}" if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else "n/a"


def table(results, floor, target, budget, title="Bullet benchmark"):
    lines = [
        f"### {title} (headless CPU work per tick, budget p95 <= {budget} ms)",
        "",
        "| bullets | role | work p50 ms | work p95 ms | work p99 ms | verdict |",
        "|---:|---|---:|---:|---:|---|",
    ]
    for n, r in sorted(results.items()):
        role = "floor" if n == floor else "target" if n == target else ""
        if role:
            ok = not bad_timings(r) and r["work_p95_ms"] <= budget and r.get("reached") is not False
            verdict = "pass" if ok else ("**FAIL**" if role == "floor" else "over budget / shortfall (warning)")
        else:
            verdict = "info"
        lines.append(f"| {n} | {role} | {fmt(r, 'work_p50_ms')} | {fmt(r, 'work_p95_ms')} | "
                     f"{fmt(r, 'work_p99_ms')} | {verdict} |")
    return lines


def check(results, floor, target, budget, baseline=None, regression_pct=25.0,
          title="Bullet benchmark", label=""):
    """Returns (exit_code, annotations, summary_lines).

    A row with a missing / NaN / infinite / negative timing is reported instead of compared
    (NaN > budget is False, so a NaN p95 would otherwise pass). label is prefixed to messages.
    A shortfall does not also earn a "within budget" note.
    """
    errors, warnings, notes = [], [], []

    def judge(n, role, sink):
        r = results.get(n)
        if r is None:
            sink.append(f"{label}no result for {role} count of {n} bullets (was it passed to --bullets?)")
            return
        bad = bad_timings(r)
        if bad:
            sink.append(f"{label}invalid timing at {n} bullets ({role}): {', '.join(bad)} "
                        f"missing, NaN, infinite or negative, so the run proves nothing")
            return
        shortfall = r.get("reached") is False
        if shortfall:
            sink.append(f"{label}shortfall at {n} bullets ({role}): only {r.get('min_alive_before_step', '?')} were alive "
                        f"on the slowest-filled frame, so the timing is not valid")
        p95 = r["work_p95_ms"]
        if p95 > budget:
            sink.append(f"{label}p95 {p95:.2f} ms > budget {budget} ms at {n} bullets ({role})")
        elif not shortfall:
            notes.append(f"{label}{n} bullets ({role}): p50 {r['work_p50_ms']:.2f} / p95 {p95:.2f} / "
                         f"p99 {r['work_p99_ms']:.2f} ms, within {budget} ms")
        if baseline is not None and n in baseline:
            b = baseline[n].get("work_p95_ms") if isinstance(baseline[n], dict) else None
            if isinstance(b, bool) or not isinstance(b, (int, float)) or not math.isfinite(b):
                sink.append(f"{label}baseline p95 at {n} bullets ({role}) is missing or not a finite number")
                return
            if p95 > b * (1 + regression_pct / 100):
                sink.append(f"{label}p95 regressed more than {regression_pct:g}% vs baseline at {n} bullets "
                            f"({b:.2f} -> {p95:.2f} ms, {role})")

    judge(floor, "hard floor", errors)
    judge(target, "target", warnings)

    annotations = [f"::error::{m}" for m in errors] + [f"::warning::{m}" for m in warnings]
    summary = table(results, floor, target, budget, title) + [""]
    summary += [f"- :x: **FAIL** {m}" for m in errors]
    summary += [f"- :warning: **WARNING** {m}" for m in warnings]
    summary += [f"- :white_check_mark: {m}" for m in notes]
    summary += ["", "_Headless dummy renderer: CPU simulation cost only, not GPU time._"]
    return (1 if errors else 0), annotations, summary


def _p95(results, n):
    """The finite, positive-or-zero p95 of the n-bullet row, else None."""
    r = (results or {}).get(n)
    v = r.get("work_p95_ms") if isinstance(r, dict) else None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
        return None
    return float(v)


def ratios(plain, hooked, counts):
    """Hooked/plain p95 per count, from the same CI run. Informational only: it never fails the job.
    Returns [{"bullets", "plain_p95_ms", "hooked_p95_ms", "ratio"}], ratio None if either side is missing,
    invalid, or the plain p95 is zero."""
    out = []
    for n in counts:
        pp, hp = _p95(plain, n), _p95(hooked, n)
        ratio = hp / pp if pp is not None and hp is not None and pp > 0 else None
        out.append({"bullets": n, "plain_p95_ms": pp, "hooked_p95_ms": hp, "ratio": ratio})
    return out


def ratio_lines(rows):
    lines = ["### Hooked / plain p95 ratio (same run, informational, not gated)", "",
             "| bullets | plain p95 ms | hooked p95 ms | hooked / plain |", "|---:|---:|---:|---:|"]
    for r in rows:
        def f(v, spec):
            return "n/a" if v is None else format(v, spec)
        ratio = "n/a" if r["ratio"] is None else f"{r['ratio']:.2f}x"
        lines.append(f"| {r['bullets']} | {f(r['plain_p95_ms'], '.2f')} | {f(r['hooked_p95_ms'], '.2f')} | {ratio} |")
    return lines


def check_hooked_report(a):
    """The --hooked-report tier. Returns (exit_code, annotations, summary_lines)."""
    label = "[hooked] "
    try:
        results, frac = load_hooked(a.hooked_report)
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
        msg = f"{label}cannot read hooked benchmark results from {a.hooked_report}: {e}"
        return 1, [f"::error::{msg}"], [f"- :x: **FAIL** {msg}"], None
    budget = a.hooked_target_ms if a.hooked_target_ms is not None else a.p95_ms
    code, annotations, summary = check(
        results, a.floor_bullets, a.target_bullets, budget, None, a.regression_pct,
        title="Hooked bullet benchmark, no-op on_update hook on every bullet",
        label=label)
    if frac != 1.0:
        # Without this a run whose --hooked was dropped would pass as a cheap plain run.
        msg = f"{label}the report is not a fully hooked run (hooked_fraction = {frac!r}, expected 1.0)"
        annotations.insert(0, f"::error::{msg}")
        summary.insert(len(summary) - 1, f"- :x: **FAIL** {msg}")
        code = 1
    return code, annotations, summary, results


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report")
    ap.add_argument("--p95-ms", type=float, default=16.6, help="p95 budget in ms (default 16.6)")
    ap.add_argument("--floor-bullets", type=int, default=5000, help="hard-fail count (default 5000)")
    ap.add_argument("--target-bullets", type=int, default=10000, help="warn-only count (default 10000)")
    ap.add_argument("--baseline", help="earlier bench.json to compare against")
    ap.add_argument("--hooked-report", help="bench.json from `run_benchmark.sh --hooked=1.0`, checked strictly "
                    "with the same counts (see above)")
    ap.add_argument("--hooked-target-ms", type=float, default=None,
                    help="hooked p95 budget in ms (default: --p95-ms). CI passes a runner-calibrated value")
    ap.add_argument("--ratio-json", help="write the hooked/plain p95 ratios (informational) to this JSON file")
    ap.add_argument("--regression-pct", type=float, default=25.0)
    ap.add_argument("--summary", help="append the markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    a = ap.parse_args(argv)

    try:
        results = load(a.report)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"::error::cannot read benchmark results from {a.report}: {e}")
        return 1
    baseline = None
    if a.baseline:
        try:
            baseline = load(a.baseline)
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"::error::cannot read baseline results from {a.baseline}: {e}")
            return 1

    code, annotations, summary = check(results, a.floor_bullets, a.target_bullets, a.p95_ms,
                                       baseline, a.regression_pct)
    if a.hooked_report:
        hcode, hann, hsum, hresults = check_hooked_report(a)
        code = max(code, hcode)
        annotations += hann
        summary += [""] + hsum
        rows = ratios(results, hresults, [a.floor_bullets, a.target_bullets])
        summary += [""] + ratio_lines(rows)
        if a.ratio_json:
            try:
                with open(a.ratio_json, "w") as f:
                    json.dump({"hooked_over_plain_p95": rows}, f, indent=2)
            except OSError as e:  # informational output must never fail the gate
                print(f"::warning::could not write {a.ratio_json}: {e}")
    print("\n".join(summary))
    print("\n".join(annotations))
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("\n".join(summary) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
