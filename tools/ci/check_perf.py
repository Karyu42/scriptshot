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
  * --base-kind: what the same-run base is. "pr" (default): the PR base (main); every message is as before.
    "push-parent": a push to main, where the base is the parent commit (the previous main tip, CoS ruling of
    2026-11-10), benchmarked in the same job exactly like a PR base. The rules above apply unchanged; only the
    wording of the messages names the parent instead of main, and the log gets a "perf base: ..." line.
    --no-base-reason TEXT (push-parent, when the parent could not be checked out or benchmarked at all): logs
    "perf base: none (TEXT)" and the fallback, which is mode=raw everywhere with no relative check, i.e. only the
    raw bars. A fallback can never pass a run that the raw bars would fail.

  * Other tiers (perf_ab.sh --tiers=onbatch,auto; the "Bullet benchmark (native on_batch, p95 gate)" CI job): the same
    rules, run as a separate invocation with the tier's own report as REPORT and its own same-run base as
    --base-report. --tier-name / --title only change the wording ("plain" / "Bullet benchmark" by default, so the
    plain + hooked invocation prints exactly as before). --p95-target-ms gives the TARGET count its own bar (default
    --p95-ms). --reference-ms is then that tier's reference (F = the tier's base FLOOR p95 / --reference-ms).
    --expect-backend NAME / --expect-batch N: the head report's top-level "backend" / "batch" must match (hard fail),
    so a run whose native library did not load cannot pass as a GDScript run; a base report that does not match is
    unusable (mode=raw, no relative check, ::warning::).
    --informational: timings, bars and the relative check are reported as ::warning:: only and never fail the job
    (logged as "perf mode: informational"). The --expect-backend / --expect-batch checks still fail.

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

# Native on_batch tier ("Bullet benchmark (native on_batch, p95 gate)" job; .github/workflows/ci.yml passes these
# numbers explicitly and tools/ci/test_check_perf.py checks that they match). Calibrated in PR #64 from CI run
# 43200042914 (ubuntu-24.04): main 119c0925 native on_batch work p95 at 5k 1.79-2.00 ms (4 rounds, merged 1.96),
# at 10k 3.14-3.37 ms (merged 3.32). Locally 1.8-2.5 / 3.3-4.4 ms; the regressed #63 head 1322ebcc 11.0 / 19.2 ms.
#   * bars: about 3x main's runner p95 (plain has 16.6 / 7.5 = 2.2x; hosts differ by about 2x): 6.0 ms at 5k (hard),
#     10.0 ms at 10k (warning). Well below 16.6 ms, and 6.0 x the 1.5 slow-runner cap = 9.0 ms < 10 ms, so a 5k
#     on_batch p95 of 10 ms (1322ebcc) fails in every mode.
#   * reference: main's native on_batch 5k p95 on the runner, 2.0 ms (the role 7.5 ms plays for plain). Slow-runner
#     mode needs the base itself over 6.0 ms (F >= 3), so F is then always capped at 1.5. One runner sample so far:
#     revisit with more runs, or when main's native on_batch cost really moves.
NATIVE_ON_BATCH_FLOOR_MS = 6.0
NATIVE_ON_BATCH_TARGET_MS = 10.0
REFERENCE_NATIVE_ON_BATCH_FLOOR_P95_MS = 2.0

# Wording per --base-kind. "pr" is the original text, byte for byte (PR runs must not change).
BASE_NAMES = {
    "pr": {
        "base": "base (main)",
        "vs": "main",
        "cmp_title": "PR head vs base (main)",
        "none": "_No same-run base (main) benchmark (push to main or workflow_dispatch): mode=raw, "
                "absolute budgets only._",
        "unusable": "_The base (main) benchmark of this job was unusable: mode=raw, absolute budgets only, "
                    "no relative check._",
    },
    "push-parent": {
        "base": "base (parent)",
        "vs": "the parent commit",
        "cmp_title": "pushed head vs base (parent commit = previous main tip)",
        "none": "_FALLBACK: no same-run base (the parent commit could not be benchmarked{reason}): mode=raw, "
                "raw bars only (plain 5k and hooked 5k hard), no relative check._",
        "unusable": "_FALLBACK: the base (parent commit) benchmark of this job was unusable: mode=raw, raw bars only, "
                    "no relative check._",
    },
}


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


def table(results, floor, target, budget, title="Bullet benchmark", modes=None, budgets=None):
    modes = modes or {}
    budgets = budgets or {}
    extra = ""
    if any(m[0] != budgets.get(n, budget) for n, m in modes.items()):
        extra = "; slow-runner bars: " + ", ".join(f"{n}: {m[0]:.1f} ms" for n, m in sorted(modes.items())
                                                    if m[0] != budgets.get(n, budget))
    shown = f"{budget} ms"
    if any(v != budget for v in budgets.values()):
        shown = ", ".join(f"{budgets.get(n, budget)} ms at {n}" for n in (floor, target))
    lines = [
        f"### {title} (headless CPU work per tick, budget p95 <= {shown}{extra})",
        "",
        "| bullets | role | work p50 ms | work p95 ms | work p99 ms | verdict |",
        "|---:|---|---:|---:|---:|---|",
    ]
    for n, r in sorted(results.items()):
        role = "floor" if n == floor else "target" if n == target else ""
        if role:
            bar = modes.get(n, (budgets.get(n, budget),))[0]
            ok = not bad_timings(r) and r["work_p95_ms"] <= bar and r.get("reached") is not False
            verdict = "pass" if ok else ("**FAIL**" if role == "floor" else "over budget / shortfall (warning)")
        else:
            verdict = "info"
        lines.append(f"| {n} | {role} | {fmt(r, 'work_p50_ms')} | {fmt(r, 'work_p95_ms')} | "
                     f"{fmt(r, 'work_p99_ms')} | {verdict} |")
    return lines


def check(results, floor, target, budget, baseline=None, regression_pct=25.0,
          title="Bullet benchmark", label="", modes=None, budgets=None):
    """Returns (exit_code, annotations, summary_lines).

    A row with a missing / NaN / infinite / negative timing is reported instead of compared
    (NaN > budget is False, so a NaN p95 would otherwise pass). label is prefixed to messages.
    A shortfall does not also earn a "within budget" note.
    modes: {count: (bar, mode_text)} from bar_modes() when a same-run base exists; the bar replaces budget for that
    count and mode_text is appended to the messages. None = budget for every count (mode=raw, old messages).
    budgets: {count: bar} overriding budget per count without a base (--p95-target-ms); None = budget everywhere.
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
        bar, mode = (modes or {}).get(n, ((budgets or {}).get(n, budget), None))
        shown_bar = f"{bar}" if mode is None else f"{bar:.2f}"
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
    summary = table(results, floor, target, budget, title, modes, budgets) + [""]
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
    over the bar (the runner is provably slow); then head_bar = bar * min(factor, cap). Otherwise mode=raw, bar.
    bar: one bar for every count, or {count: bar} (--p95-target-ms)."""
    out = {}
    for n in counts:
        bar_n = bar[n] if isinstance(bar, dict) else bar
        bp = _base_p95(base, n)
        if factor is not None and bp is not None and bp > bar_n:
            eff = bar_n * min(factor, cap)
            out[n] = (eff, f"mode=slow-runner (base {bp:.1f} > {bar_n:.1f}, F={factor:.2f}, cap {cap:g}, bar {eff:.1f})")
        elif bp is None:
            out[n] = (bar_n, "mode=raw (no valid base at this count)")
        else:
            out[n] = (bar_n, "mode=raw")
    return out


def relative(head, base, floor, target, tol_pct, label="", names=BASE_NAMES["pr"]):
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
            sink.append(f"{label}no valid {names['base']} result at {n} bullets ({role}), so the same-runner "
                        f"regression check could not run")
        elif hp is not None:  # an invalid head row is already reported by check()
            limit = bp * (1 + tol_pct / 100)
            row.update(delta_pct=(hp - bp) / bp * 100 if bp > 0 else None, limit=limit, ok=hp <= limit)
            if hp > limit:
                sink.append(f"{label}p95 regressed vs {names['vs']} on the same runner at {n} bullets ({role}): "
                            f"{bp:.2f} -> {hp:.2f} ms, limit {limit:.2f} ms (+{tol_pct:g}%)")
        rows.append(row)
    return errors, warnings, rows


def comparison_lines(tiers, factor, base_p95, reference_ms, cap, tol_pct, names=BASE_NAMES["pr"], tier="plain"):
    """tiers: [(name, bar, rel_rows, head_results, modes)]. Markdown for the step summary."""
    def f(v, spec=".2f"):
        return "n/a" if v is None else format(v, spec)
    lines = [f"### Same-runner comparison: {names['cmp_title']}, measured in this job", "",
             f"Runner speed factor F = base {tier} p95 {base_p95:.2f} ms / reference {reference_ms:g} ms, "
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


def meta_mismatch(path, backend=None, batch=None):
    """What in the report's top-level "backend" / "batch" differs from the expectation ([] = matches)."""
    if backend is None and batch is None:
        return []
    try:
        with open(path) as f:
            doc = json.load(f)
        if not isinstance(doc, dict):
            raise ValueError("not a JSON object")
    except (OSError, ValueError) as e:
        return [f"cannot read {path}: {e}"]
    out = []
    if backend is not None and doc.get("backend") != backend:
        out.append(f'"backend" is {doc.get("backend")!r}, expected {backend!r}')
    got = doc.get("batch")
    if batch is not None and (isinstance(got, bool) or got != batch):
        out.append(f'"batch" is {got!r}, expected {batch!r}')
    return out


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
    ap.add_argument("--base-kind", choices=sorted(BASE_NAMES), default="pr",
                    help="what the same-run base is: pr (the PR base, main; default) or push-parent (a push to main: "
                    "the parent commit, the previous main tip). Same rules; only the wording and log differ")
    ap.add_argument("--base-sha", default="", help="commit of the same-run base, for the log only")
    ap.add_argument("--no-base-reason", default=None,
                    help="push-parent only: why there is no base report at all (logged as the fallback reason; "
                    "the gate is then the raw bars only)")
    ap.add_argument("--tier-name", default="plain",
                    help="name of the REPORT tier in messages, mode lines and the comparison table (default plain)")
    ap.add_argument("--title", default="Bullet benchmark", help="title of the REPORT tier's summary table")
    ap.add_argument("--p95-target-ms", type=positive_ms, default=None,
                    help="REPORT tier bar at the TARGET count (default: --p95-ms)")
    ap.add_argument("--expect-backend", default=None,
                    help='REPORT must have this top-level "backend" (hard fail); a base without it is unusable')
    ap.add_argument("--expect-batch", type=int, default=None,
                    help='REPORT must have this top-level "batch" (hard fail); a base without it is unusable')
    ap.add_argument("--informational", action="store_true",
                    help="report bars and the relative check as warnings only; exit 0 unless an --expect-* check fails")
    a = ap.parse_args(argv)
    names = BASE_NAMES[a.base_kind]
    tier = a.tier_name
    tlabel = "" if tier == "plain" else f"[{tier}] "
    if a.no_base_reason is not None and a.base_kind != "push-parent":
        ap.error("--no-base-reason needs --base-kind push-parent")

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
    meta_errors = [f"{tlabel}{m} in {a.report}: wrong tier (did the native library load?)"
                   for m in meta_mismatch(a.report, a.expect_backend, a.expect_batch)]

    # Same-run base (main). Unusable base -> mode=raw everywhere and no relative check (never looser).
    base_plain = base_hooked = None
    pre = []
    if a.base_report:
        try:
            base_plain = load(a.base_report)
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            pre.append(f"::warning::cannot read {names['base']} results from {a.base_report}: {e}; "
                       f"mode=raw (no usable base)")
        bad_meta = meta_mismatch(a.base_report, a.expect_backend, a.expect_batch) if base_plain is not None else []
        if bad_meta:
            pre.append(f"::warning::{tlabel}{names['base']} report {a.base_report}: {'; '.join(bad_meta)}; "
                       f"mode=raw (no usable base) and no relative check")
            base_plain = None
    if a.base_hooked_report and base_plain is not None:
        try:
            base_hooked, bfrac = load_hooked(a.base_hooked_report)
            if bfrac != 1.0:
                raise ValueError(f"hooked_fraction = {bfrac!r}, expected 1.0")
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            base_hooked = None
            pre.append(f"::warning::cannot use {names['base']} hooked results from {a.base_hooked_report}: {e}; "
                       f"hooked tier: mode=raw and no relative check")
    factor, base_p95 = speed_factor(base_plain, a.floor_bullets, a.reference_ms)
    if base_plain is not None and factor is None:
        pre.append(f"::warning::the {names['base']} run has no valid {tier} {a.floor_bullets}-bullet p95; "
                   f"mode=raw (no usable base) and no relative check")
        base_plain = base_hooked = None
    counts = [a.floor_bullets, a.target_bullets]
    hooked_budget = a.hooked_target_ms if a.hooked_target_ms is not None else a.p95_ms
    plain_modes = hooked_modes = None
    budgets = None
    plain_bar = a.p95_ms
    if a.p95_target_ms is not None:
        budgets = {a.floor_bullets: a.p95_ms, a.target_bullets: a.p95_target_ms}
        plain_bar = budgets
    if base_plain is not None:
        plain_modes = bar_modes(base_plain, counts, plain_bar, factor, a.slow_runner_cap)
        if base_hooked is not None:
            hooked_modes = bar_modes(base_hooked, counts, hooked_budget, factor, a.slow_runner_cap)
    mode_lines = []
    if a.base_kind == "push-parent":
        sha = f" {a.base_sha}" if a.base_sha else ""
        if a.no_base_reason is not None:
            mode_lines.append(f"perf base: none (push to main; parent commit{sha} unavailable: {a.no_base_reason}) "
                              f"-> FALLBACK mode=raw: raw bars only, no relative check")
        elif base_plain is None:
            mode_lines.append(f"perf base: parent commit{sha} (push to main), but its benchmark is unusable "
                              f"-> FALLBACK mode=raw: raw bars only, no relative check")
        else:
            mode_lines.append(f"perf base: parent commit{sha} (previous branch tip: main on push, the dispatched branch on workflow_dispatch), same job, same runner")
    if a.informational:
        mode_lines.append(f"perf mode: {tier}: informational (bars and relative check reported as warnings, "
                          f"never fail the job)")
    for name, modes in ((tier, plain_modes), ("hooked", hooked_modes if a.hooked_report else {})):
        if modes is None:
            mode_lines.append(f"perf mode: {name}: mode=raw (no usable same-run base)")
        for n, (_bar, m) in sorted((modes or {}).items()):
            mode_lines.append(f"perf mode: {name} {n}: {m}")

    code, annotations, summary = check(results, a.floor_bullets, a.target_bullets, a.p95_ms,
                                       baseline, a.regression_pct, title=a.title, label=tlabel,
                                       modes=plain_modes, budgets=budgets)
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
        errs, warns, rows = relative(results, base_plain, a.floor_bullets, a.target_bullets, a.rel_tolerance_pct,
                                     label=tlabel, names=names)
        tiers = [(tier, a.p95_ms, rows, results, plain_modes)]
        if a.hooked_report:
            if base_hooked is not None:
                herrs, hwarns, hrows = relative(hresults, base_hooked, a.floor_bullets, a.target_bullets,
                                                a.rel_tolerance_pct, label="[hooked] ", names=names)
                errs += herrs
                warns += hwarns
                tiers.append(("hooked", hooked_budget, hrows, hresults, hooked_modes))
            else:
                warns.append(f"[hooked] no {names['base']} hooked report: hooked mode=raw, and the hooked same-runner "
                             "regression check did not run")
        annotations += [f"::error::{m}" for m in errs] + [f"::warning::{m}" for m in warns]
        if errs:
            code = 1
        cmp_lines = comparison_lines(tiers, factor, base_p95, a.reference_ms, a.slow_runner_cap,
                                     a.rel_tolerance_pct, names, tier=tier)
        cmp_lines += [""] + [f"- :x: **FAIL** {m}" for m in errs] + [f"- :warning: **WARNING** {m}" for m in warns]
        summary = cmp_lines + [""] + summary
    elif a.base_report is None:
        reason = f": {a.no_base_reason}" if a.no_base_reason else ""
        summary = [names["none"].format(reason=reason), ""] + summary
    else:
        summary = [names["unusable"], ""] + summary
    if a.informational:
        annotations = [m.replace("::error::", "::warning::", 1) if m.startswith("::error::") else m
                       for m in annotations]
        summary = [s_.replace(":x: **FAIL**", ":warning: **WARNING (informational)**") for s_ in summary]
        summary = [f"_Informational tier ({tier}): misses are warnings and never fail the job._", ""] + summary
        code = 0
    if meta_errors:
        annotations = [f"::error::{m}" for m in meta_errors] + annotations
        summary = [f"- :x: **FAIL** {m}" for m in meta_errors] + [""] + summary
        code = 1
    if a.base_report or a.base_hooked_report or a.base_kind != "pr" or tier != "plain" or a.informational:
        print("\n".join(mode_lines))
    print("\n".join(summary))
    print("\n".join(annotations))
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("\n".join(summary) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
