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
    on the same runner (tools/ci/perf_ab.sh). Two extra checks, both judged at FLOOR (hard) and TARGET (warning):
      - RELATIVE gate: head p95 > base p95 * (1 + --rel-tolerance-pct/100) + --rel-slack-ms fails (plain and hooked).
      - RUNNER-NORMALIZED budgets: speed factor F = base plain FLOOR p95 / --reference-ms, clamped to
        [1.0, --max-speed-factor]. The absolute budgets (--p95-ms, --hooked-target-ms) are applied to head p95 / F.
        The clamp at 1.0 means a fast runner is never made looser than the plain absolute gate.
    No usable base (push to main, workflow_dispatch, or a base run without a valid FLOOR row) = F 1.0 and no relative
    gate, i.e. exactly the absolute gates. That fallback is never looser than the normalized gates.
    The comparison table (base, head, delta %, normalized, verdict) is written to --summary.

"work" is the CPU time of one tick of bullet work on the headless dummy renderer. It is not a GPU
or rendering measurement (see docs/qa/stress-test-plan.md). The full results table and verdict
lines are appended to --summary (pass "$GITHUB_STEP_SUMMARY"); annotations go to stdout.
"""
import argparse
import json
import math
import sys

# Reference machine for runner normalization: main's plain 5,000-bullet work p95 on a "fast" GitHub-hosted
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


def table(results, floor, target, budget, title="Bullet benchmark", factor=1.0):
    norm = "" if factor == 1.0 else f", applied to p95 / runner speed factor {factor:.2f}"
    lines = [
        f"### {title} (headless CPU work per tick, budget p95 <= {budget} ms{norm})",
        "",
        "| bullets | role | work p50 ms | work p95 ms | work p99 ms | verdict |",
        "|---:|---|---:|---:|---:|---|",
    ]
    for n, r in sorted(results.items()):
        role = "floor" if n == floor else "target" if n == target else ""
        if role:
            ok = not bad_timings(r) and r["work_p95_ms"] / factor <= budget and r.get("reached") is not False
            verdict = "pass" if ok else ("**FAIL**" if role == "floor" else "over budget / shortfall (warning)")
        else:
            verdict = "info"
        lines.append(f"| {n} | {role} | {fmt(r, 'work_p50_ms')} | {fmt(r, 'work_p95_ms')} | "
                     f"{fmt(r, 'work_p99_ms')} | {verdict} |")
    return lines


def check(results, floor, target, budget, baseline=None, regression_pct=25.0,
          title="Bullet benchmark", label="", factor=1.0):
    """Returns (exit_code, annotations, summary_lines).

    A row with a missing / NaN / infinite / negative timing is reported instead of compared
    (NaN > budget is False, so a NaN p95 would otherwise pass). label is prefixed to messages.
    A shortfall does not also earn a "within budget" note.
    factor (>= 1.0) is the runner speed factor: the budget is applied to p95 / factor. 1.0 = absolute gate.
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
        eff = p95 / factor
        if factor == 1.0:
            shown = f"p95 {p95:.2f} ms"
        else:
            shown = f"normalized p95 {eff:.2f} ms (raw {p95:.2f} ms / runner speed factor {factor:.2f})"
        if eff > budget:
            sink.append(f"{label}{shown} > budget {budget} ms at {n} bullets ({role})")
        elif not shortfall:
            within = f"within {budget} ms" if factor == 1.0 else f"{shown} within {budget} ms"
            notes.append(f"{label}{n} bullets ({role}): p50 {r['work_p50_ms']:.2f} / p95 {p95:.2f} / "
                         f"p99 {r['work_p99_ms']:.2f} ms, {within}")
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
    summary = table(results, floor, target, budget, title, factor) + [""]
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


def check_hooked_report(a, factor=1.0):
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
        label=label, factor=factor)
    if frac != 1.0:
        # Without this a run whose --hooked was dropped would pass as a cheap plain run.
        msg = f"{label}the report is not a fully hooked run (hooked_fraction = {frac!r}, expected 1.0)"
        annotations.insert(0, f"::error::{msg}")
        summary.insert(len(summary) - 1, f"- :x: **FAIL** {msg}")
        code = 1
    return code, annotations, summary, results


def speed_factor(base_plain, floor, reference_ms, max_factor):
    """(factor, raw_ratio, base_p95). factor = base plain FLOOR p95 / reference, clamped to [1.0, max_factor].
    (1.0, None, None) when there is no usable base FLOOR row (missing, bad timing, or a shortfall)."""
    r = (base_plain or {}).get(floor)
    if not isinstance(r, dict) or bad_timings(r) or r.get("reached") is False:
        return 1.0, None, None
    b = float(r["work_p95_ms"])
    if not (isinstance(reference_ms, (int, float)) and math.isfinite(reference_ms) and reference_ms > 0):
        return 1.0, None, b
    raw = b / reference_ms
    return min(max(raw, 1.0), max(max_factor, 1.0)), raw, b


def relative(head, base, floor, target, tol_pct, slack_ms, label=""):
    """Same-runner regression gate. Returns (errors, warnings, rows); FLOOR misses are errors, TARGET warnings.
    rows: [{"bullets", "role", "base", "head", "delta_pct", "limit", "ok"}] (None where not computable)."""
    errors, warnings, rows = [], [], []
    for n, role, sink in ((floor, "hard floor", errors), (target, "target", warnings)):
        hp, bp = _p95(head, n), _p95(base, n)
        hr, br = (head or {}).get(n), (base or {}).get(n)
        if isinstance(hr, dict) and hr.get("reached") is False:
            hp = None
        if isinstance(br, dict) and (br.get("reached") is False or bad_timings(br)):
            bp = None
        row = {"bullets": n, "role": role, "base": bp, "head": hp, "delta_pct": None, "limit": None, "ok": None}
        if bp is None:
            sink.append(f"{label}no valid base (main) result at {n} bullets ({role}), so the same-runner "
                        f"regression check could not run")
        elif hp is not None:  # an invalid head row is already reported by check()
            limit = bp * (1 + tol_pct / 100) + slack_ms
            row.update(delta_pct=(hp - bp) / bp * 100 if bp > 0 else None, limit=limit, ok=hp <= limit)
            if hp > limit:
                sink.append(f"{label}p95 regressed vs main on the same runner at {n} bullets ({role}): "
                            f"{bp:.2f} -> {hp:.2f} ms, limit {limit:.2f} ms (+{tol_pct:g}% +{slack_ms:g} ms)")
        rows.append(row)
    return errors, warnings, rows


def comparison_lines(tiers, factor, raw_ratio, base_p95, reference_ms, max_factor, tol_pct, slack_ms):
    """tiers: [(name, budget, rel_rows, head_results)]. Markdown for the step summary."""
    def f(v, spec=".2f"):
        return "n/a" if v is None else format(v, spec)
    lines = ["### Same-runner comparison: PR head vs base (main), measured in this job", ""]
    if raw_ratio is None:
        lines.append("Runner speed factor **1.00** (no usable base plain 5k p95; absolute budgets apply unscaled).")
    else:
        lines.append(f"Runner speed factor **{factor:.2f}** = base plain p95 {base_p95:.2f} ms / reference "
                     f"{reference_ms:g} ms = {raw_ratio:.2f}, clamped to [1.00, {max_factor:.2f}]. "
                     f"The absolute budgets are applied to **head p95 / {factor:.2f}** (normalized). "
                     f"The clamp at 1.00 means a fast runner never loosens them.")
    lines += [f"Relative gate: head p95 <= base p95 x {1 + tol_pct / 100:.2f} + {slack_ms:g} ms "
              f"(hard at the floor count, warning at the target count).", "",
              "| tier | bullets | role | base p95 ms | head p95 ms | delta % | rel. limit ms | "
              "head normalized ms | budget ms | verdict |",
              "|---|---:|---|---:|---:|---:|---:|---:|---:|---|"]
    for name, budget, rows, head in tiers:
        for r in rows:
            hr = (head or {}).get(r["bullets"])
            norm = r["head"] / factor if r["head"] is not None else None
            abs_ok = norm is not None and norm <= budget and not (isinstance(hr, dict) and hr.get("reached") is False)
            bad = []
            if r["ok"] is False:
                bad.append("regression")
            elif r["ok"] is None:
                bad.append("no comparison")
            if not abs_ok:
                bad.append("over budget" if norm is not None else "invalid head")
            if not bad:
                verdict = "pass"
            elif r["role"] == "hard floor":
                verdict = "**FAIL** (" + ", ".join(bad) + ")"
            else:
                verdict = "warning (" + ", ".join(bad) + ")"
            delta = "n/a" if r["delta_pct"] is None else f"{r['delta_pct']:+.1f}%"
            lines.append(f"| {name} | {r['bullets']} | {'floor' if r['role'] == 'hard floor' else 'target'} | "
                         f"{f(r['base'])} | {f(r['head'])} | {delta} | {f(r['limit'])} | {f(norm)} | {budget:g} | "
                         f"{verdict} |")
    return lines


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
    ap.add_argument("--base-report", help="plain bench.json of the PR base (main), measured in the same job on the "
                    "same runner. Enables the relative gate and runner normalization (see above)")
    ap.add_argument("--base-hooked-report", help="hooked bench.json of the PR base, same job (relative hooked gate)")
    ap.add_argument("--rel-tolerance-pct", type=float, default=10.0,
                    help="relative gate: allowed head-over-base p95 growth in %% (default 10)")
    ap.add_argument("--rel-slack-ms", type=float, default=0.5,
                    help="relative gate: absolute slack in ms added on top of the %% tolerance (default 0.5)")
    ap.add_argument("--reference-ms", type=float, default=REFERENCE_PLAIN_FLOOR_P95_MS,
                    help=f"reference machine's main plain floor p95 (default {REFERENCE_PLAIN_FLOOR_P95_MS})")
    ap.add_argument("--max-speed-factor", type=float, default=3.0,
                    help="upper clamp of the runner speed factor (default 3.0; the lower clamp is always 1.0)")
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

    # Same-run base (main). Unusable base -> absolute gates (factor 1.0), which are never looser.
    base_plain = base_hooked = None
    pre = []
    if a.base_report:
        try:
            base_plain = load(a.base_report)
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            pre.append(f"::warning::cannot read base (main) results from {a.base_report}: {e}; "
                       f"falling back to the absolute budgets")
    if a.base_hooked_report and base_plain is not None:
        try:
            base_hooked, bfrac = load_hooked(a.base_hooked_report)
            if bfrac != 1.0:
                raise ValueError(f"hooked_fraction = {bfrac!r}, expected 1.0")
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as e:
            base_hooked = None
            pre.append(f"::warning::cannot use base (main) hooked results from {a.base_hooked_report}: {e}; "
                       f"the hooked relative check is skipped")
    factor, raw_ratio, base_p95 = speed_factor(base_plain, a.floor_bullets, a.reference_ms, a.max_speed_factor)
    if base_plain is not None and raw_ratio is None:
        pre.append(f"::warning::the base (main) run has no valid plain {a.floor_bullets}-bullet p95; "
                   f"falling back to the absolute budgets and skipping the relative gate")
        base_plain = base_hooked = None

    code, annotations, summary = check(results, a.floor_bullets, a.target_bullets, a.p95_ms,
                                       baseline, a.regression_pct, factor=factor)
    annotations = pre + annotations
    hresults = None
    if a.hooked_report:
        hcode, hann, hsum, hresults = check_hooked_report(a, factor)
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
        hooked_budget = a.hooked_target_ms if a.hooked_target_ms is not None else a.p95_ms
        errs, warns, rows = relative(results, base_plain, a.floor_bullets, a.target_bullets,
                                     a.rel_tolerance_pct, a.rel_slack_ms)
        tiers = [("plain", a.p95_ms, rows, results)]
        if a.hooked_report:
            if base_hooked is not None:
                herrs, hwarns, hrows = relative(hresults, base_hooked, a.floor_bullets, a.target_bullets,
                                                a.rel_tolerance_pct, a.rel_slack_ms, label="[hooked] ")
                errs += herrs
                warns += hwarns
                tiers.append(("hooked", hooked_budget, hrows, hresults))
            else:
                warns.append("[hooked] no base (main) hooked report, so the hooked same-runner regression "
                             "check did not run")
        annotations += [f"::error::{m}" for m in errs] + [f"::warning::{m}" for m in warns]
        if errs:
            code = 1
        cmp_lines = comparison_lines(tiers, factor, raw_ratio, base_p95, a.reference_ms, a.max_speed_factor,
                                     a.rel_tolerance_pct, a.rel_slack_ms)
        cmp_lines += [""] + [f"- :x: **FAIL** {m}" for m in errs] + [f"- :warning: **WARNING** {m}" for m in warns]
        summary = cmp_lines + [""] + summary
    elif a.base_report is None:
        summary = ["_No same-run base (main) benchmark (push to main or workflow_dispatch): "
                   "absolute budgets, runner speed factor 1.00._", ""] + summary
    else:
        summary = ["_The base (main) benchmark of this job was unusable: absolute budgets, runner speed factor "
                   "1.00, no relative gate._", ""] + summary
    print("\n".join(summary))
    print("\n".join(annotations))
    if a.summary:
        with open(a.summary, "a") as f:
            f.write("\n".join(summary) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
