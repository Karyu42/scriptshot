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
  * Optional --base-report / --base-hooked-report: the same benchmarks run on the PR base (main) IN THE SAME CI JOB,
    on the same runner (tools/ci/perf_ab.sh). Per tier (plain bar --p95-ms, hooked bar --hooked-target-ms) and per
    count (FLOOR hard, TARGET warning):
      - RELATIVE check, always: head p95 > base p95 * (1 + --rel-tolerance-pct/100) fails. No absolute slack.
      - BAR, one of two modes:
          mode=raw (default): head raw p95 <= bar.
          mode=slow-runner: ONLY when the base's own raw p95 for that tier and count ALSO misses the bar (proof that
            the runner is slow). The head bar becomes bar * min(F, --slow-runner-cap), with
            F = base plain FLOOR p95 / --reference-ms, clamped to >= 1.0. Cap 1.5: at most 24.9 ms plain, 33.0 ms hooked.
    No usable base (no file, unreadable, or a missing / NaN / short base plain FLOOR row) = mode=raw everywhere and no
    relative check, with a ::warning:: when a base was passed. The mode of every tier and count is printed in the
    log and in the comparison table (base, head, delta %, relative limit, mode, bar, verdict) in --summary.

"work" is the CPU time of one tick of bullet work on the headless dummy renderer. It is not a GPU
or rendering measurement (see docs/qa/stress-test-plan.md). The full results table and verdict
lines are appended to --summary (pass "$GITHUB_STEP_SUMMARY"); annotations go to stdout.
"""
import argparse
import json
import math
import sys

# Reference machine for the slow-runner speed factor F: main's plain 5,000-bullet work p95 on a "fast" GitHub-hosted
# ubuntu-24.04 runner, where the absolute budgets were calibrated. Recent samples of main / PR #35 on fast hosts:
# 7.47 and 7.44 ms (PR #35 notes, 2026-11-09); the slow hosts of the same day printed 14-16 ms. Revisit when
# main's plain cost really moves (a perf PR), otherwise every runner looks "slow" or "fast" by the wrong amount.
REFERENCE_PLAIN_FLOOR_P95_MS = 7.5


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


def table(results, floor, target, budget, title="Bullet benchmark", modes=None):
    modes = modes or {}
    extra = ""
    if any(m[0] != budget for m in modes.values()):
        extra = "; slow-runner bars: " + ", ".join(f"{n}: {m[0]:.1f} ms" for n, m in sorted(modes.items())
                                                    if m[0] != budget)
    lines = [
        f"### {title} (headless CPU work per tick, budget p95 <= {budget} ms{extra})",
        "",
        "| bullets | role | work p50 ms | work p95 ms | work p99 ms | verdict |",
        "|---:|---|---:|---:|---:|---|",
    ]
    for n, r in sorted(results.items()):
        role = "floor" if n == floor else "target" if n == target else ""
        if role:
            bar = modes.get(n, (budget,))[0]
            ok = not bad_timings(r) and r["work_p95_ms"] <= bar and r.get("reached") is not False
            verdict = "pass" if ok else ("**FAIL**" if role == "floor" else "over budget / shortfall (warning)")
        else:
            verdict = "info"
        lines.append(f"| {n} | {role} | {fmt(r, 'work_p50_ms')} | {fmt(r, 'work_p95_ms')} | "
                     f"{fmt(r, 'work_p99_ms')} | {verdict} |")
    return lines


def check(results, floor, target, budget, baseline=None, regression_pct=25.0,
          title="Bullet benchmark", label="", modes=None):
    """Returns (exit_code, annotations, summary_lines).

    A row with a missing / NaN / infinite / negative timing is reported instead of compared
    (NaN > budget is False, so a NaN p95 would otherwise pass). label is prefixed to messages.
    A shortfall does not also earn a "within budget" note.
    modes: {count: (bar, mode_text)} from bar_modes() when a same-run base exists; the bar replaces budget for that
    count and mode_text is appended to the messages. None = budget for every count (mode=raw, old messages).
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
        bar, mode = (modes or {}).get(n, (budget, None))
        shown_bar = f"{budget}" if mode is None else f"{bar:.2f}"
        tail = "" if mode is None else f", {mode}"
        if p95 > bar:
            sink.append(f"{label}p95 {p95:.2f} ms > budget {shown_bar} ms at {n} bullets ({role}){tail}")
        elif not shortfall:
            notes.append(f"{label}{n} bullets ({role}): p50 {r['work_p50_ms']:.2f} / p95 {p95:.2f} / "
                         f"p99 {r['work_p99_ms']:.2f} ms, within {shown_bar} ms{tail}")
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
    summary = table(results, floor, target, budget, title, modes) + [""]
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


def check_hooked_report(a, modes=None):
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
        label=label, modes=modes)
    if frac != 1.0:
        # Without this a run whose --hooked was dropped would pass as a cheap plain run.
        msg = f"{label}the report is not a fully hooked run (hooked_fraction = {frac!r}, expected 1.0)"
        annotations.insert(0, f"::error::{msg}")
        summary.insert(len(summary) - 1, f"- :x: **FAIL** {msg}")
        code = 1
    return code, annotations, summary, results


def _base_p95(base, n):
    """The base's valid p95 at n bullets (finite, >= 0, all timings valid, no shortfall), else None."""
    r = (base or {}).get(n)
    if not isinstance(r, dict) or bad_timings(r) or r.get("reached") is False:
        return None
    return float(r["work_p95_ms"])


def speed_factor(base_plain, floor, reference_ms):
    """(F, base plain FLOOR p95). F = base plain FLOOR p95 / reference_ms, clamped to >= 1.0.
    (None, None) when there is no usable base FLOOR row or the reference is not a positive number."""
    b = _base_p95(base_plain, floor)
    if b is None or not (isinstance(reference_ms, (int, float)) and math.isfinite(reference_ms) and reference_ms > 0):
        return None, None
    return max(b / reference_ms, 1.0), b


def bar_modes(base, counts, bar, factor, cap):
    """{count: (head_bar, mode_text)} for one tier. mode=slow-runner only when the base's own p95 at that count is
    over the bar (the runner is provably slow); then head_bar = bar * min(factor, cap). Otherwise mode=raw, bar."""
    out = {}
    for n in counts:
        bp = _base_p95(base, n)
        if factor is not None and bp is not None and bp > bar:
            eff = bar * min(factor, cap)
            out[n] = (eff, f"mode=slow-runner (base {bp:.1f} > {bar:.1f}, F={factor:.2f}, cap {cap:g}, bar {eff:.1f})")
        elif bp is None:
            out[n] = (bar, "mode=raw (no valid base at this count)")
        else:
            out[n] = (bar, "mode=raw")
    return out


def relative(head, base, floor, target, tol_pct, label=""):
    """Same-runner regression check: head p95 <= base p95 * (1 + tol_pct/100), no absolute slack.
    Returns (errors, warnings, rows); FLOOR misses are errors, TARGET misses warnings.
    rows: [{"bullets", "role", "base", "head", "delta_pct", "limit", "ok"}] (None where not computable)."""
    errors, warnings, rows = [], [], []
    for n, role, sink in ((floor, "hard floor", errors), (target, "target", warnings)):
        hp, bp = _p95(head, n), _base_p95(base, n)
        hr = (head or {}).get(n)
        if isinstance(hr, dict) and hr.get("reached") is False:
            hp = None
        row = {"bullets": n, "role": role, "base": bp, "head": hp, "delta_pct": None, "limit": None, "ok": None}
        if bp is None:
            sink.append(f"{label}no valid base (main) result at {n} bullets ({role}), so the same-runner "
                        f"regression check could not run")
        elif hp is not None:  # an invalid head row is already reported by check()
            limit = bp * (1 + tol_pct / 100)
            row.update(delta_pct=(hp - bp) / bp * 100 if bp > 0 else None, limit=limit, ok=hp <= limit)
            if hp > limit:
                sink.append(f"{label}p95 regressed vs main on the same runner at {n} bullets ({role}): "
                            f"{bp:.2f} -> {hp:.2f} ms, limit {limit:.2f} ms (+{tol_pct:g}%)")
        rows.append(row)
    return errors, warnings, rows


def comparison_lines(tiers, factor, base_p95, reference_ms, cap, tol_pct):
    """tiers: [(name, bar, rel_rows, head_results, modes)]. Markdown for the step summary."""
    def f(v, spec=".2f"):
        return "n/a" if v is None else format(v, spec)
    lines = ["### Same-runner comparison: PR head vs base (main), measured in this job", "",
             f"Runner speed factor F = base plain p95 {base_p95:.2f} ms / reference {reference_ms:g} ms, "
             f"clamped to >= 1.0: **F = {factor:.2f}**. It is used only in mode=slow-runner, which applies to a tier "
             f"and count only when the base's own raw p95 there is over the bar; the head bar is then "
             f"bar x min(F, {cap:g}). Everywhere else mode=raw: head raw p95 <= bar.",
             f"Relative check (always): head p95 <= base p95 x {1 + tol_pct / 100:.2f} "
             f"(hard at the floor count, warning at the target count).", "",
             "| tier | bullets | role | base p95 ms | head p95 ms | delta % | rel. limit ms | relative | "
             "mode | head bar ms | bar check | verdict |",
             "|---|---:|---|---:|---:|---:|---:|---|---|---:|---|---|"]
    for name, _bar, rows, head, modes in tiers:
        for r in rows:
            n = r["bullets"]
            hr = (head or {}).get(n)
            head_bar, mode = modes[n]
            short = isinstance(hr, dict) and hr.get("reached") is False
            bar_ok = r["head"] is not None and r["head"] <= head_bar and not short
            rel = "pass" if r["ok"] else ("**regression**" if r["ok"] is False else "n/a")
            bad = []
            if r["ok"] is False:
                bad.append("regression")
            elif r["ok"] is None:
                bad.append("no comparison")
            if not bar_ok:
                bad.append("over bar" if r["head"] is not None else "invalid head")
            if not bad:
                verdict = "pass"
            elif r["role"] == "hard floor":
                verdict = "**FAIL** (" + ", ".join(bad) + ")"
            else:
                verdict = "warning (" + ", ".join(bad) + ")"
            delta = "n/a" if r["delta_pct"] is None else f"{r['delta_pct']:+.1f}%"
            lines.append(f"| {name} | {n} | {'floor' if r['role'] == 'hard floor' else 'target'} | "
                         f"{f(r['base'])} | {f(r['head'])} | {delta} | {f(r['limit'])} | {rel} | {mode} | "
                         f"{head_bar:.2f} | {'pass' if bar_ok else 'over' if r['head'] is not None else 'n/a'} | "
                         f"{verdict} |")
    return lines


def _finite_float(text, minimum, inclusive, what):
    try:
        v = float(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"must be a number, got {text!r}") from None
    if not math.isfinite(v) or v < minimum or (v == minimum and not inclusive):
        raise argparse.ArgumentTypeError(f"must be a finite number {what}, got {text!r}")
    return v


def positive_ms(text):
    """A budget or reference time in ms: finite and > 0."""
    return _finite_float(text, 0.0, False, "> 0")


def percent(text):
    """A tolerance in %: finite and >= 0 (0 means no slack)."""
    return _finite_float(text, 0.0, True, ">= 0")


def cap_factor(text):
    """The slow-runner multiplier cap: finite and >= 1. Below 1 it would make the
    slow-runner bar stricter than the raw bar; 1 turns the allowance off."""
    return _finite_float(text, 1.0, True, ">= 1 (1 disables the slow-runner allowance)")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report")
    ap.add_argument("--p95-ms", type=positive_ms, default=16.6, help="p95 budget in ms (default 16.6)")
    ap.add_argument("--floor-bullets", type=int, default=5000, help="hard-fail count (default 5000)")
    ap.add_argument("--target-bullets", type=int, default=10000, help="warn-only count (default 10000)")
    ap.add_argument("--baseline", help="earlier bench.json to compare against")
    ap.add_argument("--hooked-report", help="bench.json from `run_benchmark.sh --hooked=1.0`, checked strictly "
                    "with the same counts (see above)")
    ap.add_argument("--hooked-target-ms", type=positive_ms, default=None,
                    help="hooked p95 budget in ms (default: --p95-ms). CI passes a runner-calibrated value")
    ap.add_argument("--ratio-json", help="write the hooked/plain p95 ratios (informational) to this JSON file")
    ap.add_argument("--regression-pct", type=percent, default=25.0)
    ap.add_argument("--summary", help="append the markdown summary here (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--base-report", help="plain bench.json of the PR base (main), measured in the same job on the "
                    "same runner. Enables the relative check and mode=slow-runner (see above)")
    ap.add_argument("--base-hooked-report", help="hooked bench.json of the PR base, same job (relative hooked gate)")
    ap.add_argument("--rel-tolerance-pct", type=percent, default=10.0,
                    help="relative check: allowed head-over-base p95 growth in %% (default 10, no absolute slack)")
    ap.add_argument("--reference-ms", type=positive_ms, default=REFERENCE_PLAIN_FLOOR_P95_MS,
                    help=f"reference machine's main plain floor p95 (default {REFERENCE_PLAIN_FLOOR_P95_MS})")
    ap.add_argument("--slow-runner-cap", type=cap_factor, default=1.5,
                    help="mode=slow-runner bar multiplier cap: bar * min(F, cap) (default 1.5)")
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

    # Same-run base (main). Unusable base -> mode=raw everywhere and no relative check (never looser).
    base_plain = base_hooked = None
    pre = []
    if a.base_report:
        try:
            base_plain = load(a.base_report)
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            pre.append(f"::warning::cannot read base (main) results from {a.base_report}: {e}; "
                       f"mode=raw (no usable base)")
    if a.base_hooked_report and base_plain is not None:
        try:
            base_hooked, bfrac = load_hooked(a.base_hooked_report)
            if bfrac != 1.0:
                raise ValueError(f"hooked_fraction = {bfrac!r}, expected 1.0")
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            base_hooked = None
            pre.append(f"::warning::cannot use base (main) hooked results from {a.base_hooked_report}: {e}; "
                       f"hooked tier: mode=raw and no relative check")
    factor, base_p95 = speed_factor(base_plain, a.floor_bullets, a.reference_ms)
    if base_plain is not None and factor is None:
        pre.append(f"::warning::the base (main) run has no valid plain {a.floor_bullets}-bullet p95; "
                   f"mode=raw (no usable base) and no relative check")
        base_plain = base_hooked = None
    counts = [a.floor_bullets, a.target_bullets]
    hooked_budget = a.hooked_target_ms if a.hooked_target_ms is not None else a.p95_ms
    plain_modes = hooked_modes = None
    if base_plain is not None:
        plain_modes = bar_modes(base_plain, counts, a.p95_ms, factor, a.slow_runner_cap)
        if base_hooked is not None:
            hooked_modes = bar_modes(base_hooked, counts, hooked_budget, factor, a.slow_runner_cap)
    mode_lines = []
    for name, modes in (("plain", plain_modes), ("hooked", hooked_modes if a.hooked_report else {})):
        if modes is None:
            mode_lines.append(f"perf mode: {name}: mode=raw (no usable same-run base)")
        for n, (_bar, m) in sorted((modes or {}).items()):
            mode_lines.append(f"perf mode: {name} {n}: {m}")

    code, annotations, summary = check(results, a.floor_bullets, a.target_bullets, a.p95_ms,
                                       baseline, a.regression_pct, modes=plain_modes)
    annotations = pre + annotations
    hresults = None
    if a.hooked_report:
        hcode, hann, hsum, hresults = check_hooked_report(a, hooked_modes)
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
    if base_plain is not None:
        errs, warns, rows = relative(results, base_plain, a.floor_bullets, a.target_bullets, a.rel_tolerance_pct)
        tiers = [("plain", a.p95_ms, rows, results, plain_modes)]
        if a.hooked_report:
            if base_hooked is not None:
                herrs, hwarns, hrows = relative(hresults, base_hooked, a.floor_bullets, a.target_bullets,
                                                a.rel_tolerance_pct, label="[hooked] ")
                errs += herrs
                warns += hwarns
                tiers.append(("hooked", hooked_budget, hrows, hresults, hooked_modes))
            else:
                warns.append("[hooked] no base (main) hooked report: hooked mode=raw, and the hooked same-runner "
                             "regression check did not run")
        annotations += [f"::error::{m}" for m in errs] + [f"::warning::{m}" for m in warns]
        if errs:
            code = 1
        cmp_lines = comparison_lines(tiers, factor, base_p95, a.reference_ms, a.slow_runner_cap,
                                     a.rel_tolerance_pct)
        cmp_lines += [""] + [f"- :x: **FAIL** {m}" for m in errs] + [f"- :warning: **WARNING** {m}" for m in warns]
        summary = cmp_lines + [""] + summary
    elif a.base_report is None:
        summary = ["_No same-run base (main) benchmark (push to main or workflow_dispatch): mode=raw, "
                   "absolute budgets only._", ""] + summary
    else:
        summary = ["_The base (main) benchmark of this job was unusable: mode=raw, absolute budgets only, "
                   "no relative check._", ""] + summary
    if a.base_report or a.base_hooked_report:
        print("\n".join(mode_lines))
    print("\n".join(summary))
    print("\n".join(annotations))
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("\n".join(summary) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
