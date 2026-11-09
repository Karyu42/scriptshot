"""Unit tests for check_perf.py. Run: python3 -m unittest discover -s tools/ci -p 'test_*.py' -v

All numbers below are FABRICATED TEST DATA, not benchmark measurements.
"""
import contextlib
import io
import json
import os
import tempfile
import unittest

import check_perf


def row(bullets, p50, p95, p99, reached=True, min_alive=None):
    """Same keys as tests/benchmark/bullet_benchmark.gd writes (FABRICATED values)."""
    return {"bullets": bullets, "frames": 600, "alive_at_end": bullets - 30,
            "min_alive_before_step": bullets - 30 if min_alive is None else min_alive,
            "reached": reached, "work_p50_ms": p50, "work_p95_ms": p95, "work_p99_ms": p99,
            "work_max_ms": p99 + 1, "work_mean_ms": p50}


def run(rows, *extra):
    """Writes a fake bench.json, runs main(), returns (exit_code, stdout, summary_text)."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "bench.json")
        summary = os.path.join(d, "summary.md")
        with open(path, "w") as f:
            json.dump({"godot": "test", "results": rows}, f)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_perf.main([path, "--summary", summary, *extra])
        with open(summary) as f:
            return code, out.getvalue(), f.read()


class CheckPerfTest(unittest.TestCase):
    def test_pass(self):
        code, out, summ = run([row(5000, 3.5, 5.0, 6.2), row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 0)
        self.assertNotIn("::error::", out)
        self.assertNotIn("::warning::", out)
        self.assertIn("| 5000 | floor |", summ)
        self.assertIn("| 10000 | target |", summ)

    def test_5k_over_budget_is_hard_fail(self):
        code, out, summ = run([row(5000, 9.0, 16.61, 20.0), row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 16.61 ms > budget 16.6 ms at 5000 bullets", out)
        self.assertIn("**FAIL**", summ)

    def test_5k_exactly_at_budget_passes(self):
        code, _, _ = run([row(5000, 9.0, 16.6, 20.0), row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 0)

    def test_5k_missing_is_hard_fail(self):
        code, out, summ = run([row(2000, 1.0, 1.5, 2.0), row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::no result for hard floor count of 5000 bullets", out)
        self.assertIn("**FAIL**", summ)

    def test_10k_over_budget_warns_but_does_not_fail(self):
        code, out, summ = run([row(5000, 6.0, 9.0, 11.0), row(10000, 12.0, 18.25, 22.0)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::p95 18.25 ms > budget 16.6 ms at 10000 bullets (target)", out)
        self.assertNotIn("::error::", out)
        self.assertIn("**WARNING**", summ)
        self.assertIn("over budget / shortfall (warning)", summ)
        # p50/p95/p99 of the over-budget 10k row are still reported.
        self.assertIn("| 10000 | target | 12.00 | 18.25 | 22.00 |", summ)

    def test_10k_missing_warns_but_does_not_fail(self):
        code, out, summ = run([row(5000, 3.5, 5.0, 6.2)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::no result for target count of 10000 bullets", out)
        self.assertIn("**WARNING**", summ)

    def test_both_bad_still_fails_on_floor(self):
        code, out, _ = run([row(10000, 12.0, 18.0, 22.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::", out)
        self.assertIn("::warning::", out)

    def test_baseline_regression_fails_at_floor_and_warns_at_target(self):
        with tempfile.TemporaryDirectory() as d:
            base = os.path.join(d, "base.json")
            with open(base, "w") as f:
                json.dump({"results": [row(5000, 2.0, 4.0, 5.0), row(10000, 5.0, 6.0, 7.0)]}, f)
            code, out, _ = run([row(5000, 3.0, 6.0, 7.0), row(10000, 7.0, 9.0, 10.0)], "--baseline", base)
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 regressed more than 25% vs baseline at 5000 bullets", out)
        self.assertIn("::warning::p95 regressed more than 25% vs baseline at 10000 bullets", out)

    def test_baseline_nonfinite_p95_fails_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            base = os.path.join(d, "base.json")
            with open(base, "w") as f:
                json.dump({"results": [row(5000, 2.0, float("nan"), 5.0), row(10000, 5.0, 6.0, 7.0)]}, f)
            code, out, _ = run([row(5000, 3.0, 6.0, 7.0), row(10000, 7.0, 8.0, 9.0)], "--baseline", base)
        self.assertEqual(code, 1)
        self.assertIn("::error::baseline p95 at 5000 bullets (hard floor) is missing or not a finite number", out)
        self.assertNotIn("Traceback", out)

    def test_5k_shortfall_is_hard_fail_even_if_fast(self):
        code, out, summ = run([row(5000, 1.0, 1.5, 2.0, reached=False, min_alive=4100), row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::shortfall at 5000 bullets (hard floor): only 4100 were alive", out)
        self.assertIn("**FAIL**", summ)

    def test_10k_shortfall_warns_but_does_not_fail(self):
        code, out, _ = run([row(5000, 3.5, 5.0, 6.2), row(10000, 1.0, 2.0, 3.0, reached=False, min_alive=8000)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::shortfall at 10000 bullets (target): only 8000 were alive", out)
        self.assertNotIn("::error::", out)

    def test_unreadable_report_fails(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_perf.main(["/nonexistent/bench.json"])
        self.assertEqual(code, 1)
        self.assertIn("::error::cannot read benchmark results", out.getvalue())

    def test_plain_nonfinite_or_negative_p95_fails_at_floor(self):
        # Same rule as the hooked tier: nan > budget is False, so a NaN p95 must not pass.
        for val in (float("nan"), float("inf"), float("-inf"), -1.0, None, "9.0"):
            bad = row(5000, 3.5, 5.0, 6.2)
            bad["work_p95_ms"] = val
            code, out, summ = run([bad, row(10000, 7.0, 8.0, 10.0)])
            self.assertEqual(code, 1, val)
            self.assertIn("::error::invalid timing at 5000 bullets (hard floor): work_p95_ms", out)
            self.assertNotIn("5000 bullets (hard floor): p50", out)
            self.assertNotIn("5000 bullets (hard floor): p50", summ)
            self.assertIn("**FAIL**", summ)

    def test_plain_other_bad_timings_fail_at_floor_like_the_hooked_path(self):
        for key, val in (("work_p50_ms", float("inf")), ("work_p99_ms", float("nan")), ("work_p95_ms", -0.01)):
            bad = row(5000, 3.5, 5.0, 6.2)
            bad[key] = val
            code, out, _ = run([bad, row(10000, 7.0, 8.0, 10.0)])
            self.assertEqual(code, 1, (key, val))
            self.assertIn(f"::error::invalid timing at 5000 bullets (hard floor): {key}", out)
        gone = row(5000, 3.5, 5.0, 6.2)
        del gone["work_p95_ms"]
        code, out, _ = run([gone, row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 1)
        self.assertIn("invalid timing at 5000 bullets (hard floor): work_p95_ms", out)

    def test_plain_10k_nan_only_warns(self):
        code, out, _ = run([row(5000, 3.5, 5.0, 6.2), row(10000, 7.0, float("nan"), 10.0)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::invalid timing at 10000 bullets (target): work_p95_ms", out)
        self.assertNotIn("::error::", out)

    def test_shortfall_under_budget_does_not_also_say_within_budget(self):
        code, out, summ = run([row(5000, 1.0, 1.5, 2.0, reached=False, min_alive=4100),
                               row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::shortfall at 5000 bullets", out)
        self.assertNotIn("5000 bullets (hard floor): p50", summ)
        self.assertIn("10000 bullets (target):", summ)

    def test_target_shortfall_under_budget_does_not_say_within_budget(self):
        code, out, summ = run([row(5000, 3.5, 5.0, 6.2),
                               row(10000, 1.0, 2.0, 3.0, reached=False, min_alive=8000)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::shortfall at 10000 bullets", out)
        self.assertNotIn("10000 bullets (target): p50", summ)
        self.assertIn("5000 bullets (hard floor):", summ)

    def test_shortfall_over_budget_reports_both_and_not_within(self):
        code, out, summ = run([row(5000, 20.0, 30.0, 40.0, reached=False, min_alive=1000),
                               row(10000, 7.0, 8.0, 10.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::shortfall at 5000 bullets", out)
        self.assertIn("::error::p95 30.00 ms > budget 16.6 ms at 5000 bullets", out)
        self.assertNotIn("5000 bullets (hard floor): p50", summ)

    def test_missing_baseline_file_is_a_clean_error(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bench.json")
            with open(path, "w") as f:
                json.dump({"results": [row(5000, 3.5, 5.0, 6.2), row(10000, 7.0, 8.0, 10.0)]}, f)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                try:
                    code = check_perf.main([path, "--baseline", os.path.join(d, "missing.json")])
                except Exception as exc:
                    self.fail(f"uncaught {type(exc).__name__}: {exc}")
        text = out.getvalue()
        self.assertEqual(code, 1)
        self.assertIn("::error::cannot read baseline results from", text)
        self.assertNotIn("Traceback", text)

    def test_unreadable_baseline_is_a_clean_error(self):
        for raw in ("{", "[]", '{"results": [1]}', ""):
            with tempfile.TemporaryDirectory() as d:
                path = os.path.join(d, "bench.json")
                base = os.path.join(d, "base.json")
                with open(path, "w") as f:
                    json.dump({"results": [row(5000, 3.5, 5.0, 6.2), row(10000, 7.0, 8.0, 10.0)]}, f)
                with open(base, "w") as f:
                    f.write(raw)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    try:
                        code = check_perf.main([path, "--baseline", base])
                    except Exception as exc:
                        self.fail(f"{raw!r} raised {type(exc).__name__}: {exc}")
            self.assertEqual(code, 1, raw)
            self.assertIn("::error::cannot read baseline results from", out.getvalue(), raw)


def run_hooked(plain_rows, hooked_rows, *extra, fraction=1.0, raw_hooked=None):
    """Writes a fake plain bench.json and a fake hooked one (FABRICATED values), runs main() with
    --hooked-report, returns (exit_code, stdout, summary_text). raw_hooked replaces the whole hooked file."""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "bench.json")
        hpath = os.path.join(d, "bench-hooked.json")
        summary = os.path.join(d, "summary.md")
        with open(path, "w") as f:
            json.dump({"godot": "test", "results": plain_rows}, f)
        with open(hpath, "w") as f:
            if raw_hooked is not None:
                f.write(raw_hooked)
            else:
                doc = {"godot": "test", "results": hooked_rows}
                if fraction is not None:
                    doc["hooked_fraction"] = fraction
                json.dump(doc, f, allow_nan=True)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_perf.main([path, "--hooked-report", hpath, "--summary", summary, *extra])
        with open(summary) as f:
            return code, out.getvalue(), f.read()


PLAIN_OK = [row(5000, 3.5, 5.0, 6.2), row(10000, 7.0, 8.0, 10.0)]
HOOKED_OK = [row(5000, 6.0, 9.0, 11.0), row(10000, 12.0, 15.0, 17.0)]


class HookedTierTest(unittest.TestCase):
    def test_plain_only_run_is_unchanged_by_the_hooked_option_being_absent(self):
        code, out, summ = run(PLAIN_OK)
        self.assertEqual(code, 0)
        self.assertNotIn("[hooked]", out + summ)

    def test_pass_reports_both_tiers(self):
        code, out, summ = run_hooked(PLAIN_OK, HOOKED_OK)
        self.assertEqual(code, 0)
        self.assertNotIn("::error::", out)
        self.assertNotIn("::warning::", out)
        self.assertIn("| 5000 | floor | 3.50 | 5.00 | 6.20 | pass |", summ)
        self.assertIn("| 5000 | floor | 6.00 | 9.00 | 11.00 | pass |", summ)
        self.assertIn("Hooked bullet benchmark", summ)
        self.assertIn("[hooked] 5000 bullets (hard floor)", summ)

    def test_hooked_5k_over_budget_is_hard_fail(self):
        code, out, summ = run_hooked(PLAIN_OK, [row(5000, 9.0, 16.61, 20.0), row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 16.61 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)
        self.assertIn("**FAIL**", summ)

    def test_hooked_5k_exactly_at_budget_passes(self):
        code, _, _ = run_hooked(PLAIN_OK, [row(5000, 9.0, 16.6, 20.0), row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 0)

    def test_hooked_10k_over_budget_only_warns(self):
        code, out, summ = run_hooked(PLAIN_OK, [row(5000, 6.0, 9.0, 11.0), row(10000, 20.0, 26.0, 28.0)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::[hooked] p95 26.00 ms > budget 16.6 ms at 10000 bullets (target)", out)
        self.assertNotIn("::error::", out)
        self.assertIn("| 10000 | target | 20.00 | 26.00 | 28.00 | over budget / shortfall (warning) |", summ)

    def test_a_bad_plain_tier_still_fails_when_hooked_is_fine(self):
        code, out, _ = run_hooked([row(5000, 9.0, 17.0, 20.0), row(10000, 7.0, 8.0, 10.0)], HOOKED_OK)
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 17.00 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)
        self.assertNotIn("[hooked] p95", out)

    def test_hooked_5k_missing_is_hard_fail(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] no result for hard floor count of 5000 bullets", out)

    def test_hooked_10k_missing_only_warns(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 6.0, 9.0, 11.0)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::[hooked] no result for target count of 10000 bullets", out)

    def test_hooked_5k_nan_p95_fails_instead_of_passing_silently(self):
        nan = float("nan")
        code, out, summ = run_hooked(PLAIN_OK, [row(5000, 6.0, nan, 11.0), row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] invalid timing at 5000 bullets (hard floor): work_p95_ms", out)
        self.assertIn("**FAIL**", summ)
        self.assertIn("| 5000 | floor | 6.00 | n/a | 11.00 | **FAIL** |", summ)

    def test_hooked_infinite_negative_and_missing_timings_fail_at_5k(self):
        for key, val in (("work_p50_ms", float("inf")), ("work_p99_ms", float("nan")),
                         ("work_p95_ms", -1.0), ("work_p95_ms", None), ("work_p95_ms", "9.0")):
            bad = row(5000, 6.0, 9.0, 11.0)
            bad[key] = val
            code, out, _ = run_hooked(PLAIN_OK, [bad, row(10000, 12.0, 15.0, 17.0)])
            self.assertEqual(code, 1, (key, val))
            self.assertIn(f"::error::[hooked] invalid timing at 5000 bullets (hard floor): {key}", out)
        gone = row(5000, 6.0, 9.0, 11.0)
        del gone["work_p95_ms"]
        code, out, _ = run_hooked(PLAIN_OK, [gone, row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 1)
        self.assertIn("invalid timing at 5000 bullets (hard floor): work_p95_ms", out)

    def test_hooked_10k_nan_only_warns(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 6.0, 9.0, 11.0), row(10000, 12.0, float("nan"), 17.0)])
        self.assertEqual(code, 0)
        self.assertIn("::warning::[hooked] invalid timing at 10000 bullets (target): work_p95_ms", out)
        self.assertNotIn("::error::", out)

    def test_hooked_shortfall_follows_the_same_policy(self):
        code, out, summ = run_hooked(PLAIN_OK, [row(5000, 1.0, 1.5, 2.0, reached=False, min_alive=4100),
                                                row(10000, 1.0, 2.0, 3.0, reached=False, min_alive=8000)])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] shortfall at 5000 bullets (hard floor): only 4100 were alive", out)
        self.assertIn("::warning::[hooked] shortfall at 10000 bullets (target): only 8000 were alive", out)
        self.assertNotIn("[hooked] 5000 bullets (hard floor): p50", summ)
        self.assertNotIn("[hooked] 10000 bullets (target): p50", summ)

    def test_a_report_that_is_not_fully_hooked_fails(self):
        for frac in (None, 0.0, 0.5, "1.0", True):
            code, out, summ = run_hooked(PLAIN_OK, HOOKED_OK, fraction=frac)
            self.assertEqual(code, 1, frac)
            self.assertIn("::error::[hooked] the report is not a fully hooked run", out)
            self.assertIn("**FAIL**", summ)

    def test_unreadable_or_malformed_hooked_report_fails(self):
        for raw in ("", "not json", "[]", '{"hooked_fraction": 1.0}', '{"hooked_fraction": 1.0, "results": [1]}'):
            code, out, _ = run_hooked(PLAIN_OK, None, raw_hooked=raw)
            self.assertEqual(code, 1, raw)
            self.assertIn("::error::[hooked] cannot read hooked benchmark results", out)

    def test_missing_hooked_report_file_fails(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bench.json")
            with open(path, "w") as f:
                json.dump({"results": PLAIN_OK}, f)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = check_perf.main([path, "--hooked-report", os.path.join(d, "nope.json")])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] cannot read hooked benchmark results", out.getvalue())

    # --- runner-calibrated hooked budget (--hooked-target-ms) -------------------------------------------

    def test_hooked_budget_defaults_to_the_plain_budget(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 9.0, 17.0, 20.0), row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 17.00 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)

    def test_hooked_5k_gate_at_22_ms_passes_at_21_9(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 9.0, 21.9, 23.0), row(10000, 12.0, 15.0, 17.0)],
                                  "--hooked-target-ms", "22.0")
        self.assertEqual(code, 0)
        self.assertNotIn("::error::", out)

    def test_hooked_5k_gate_at_22_ms_passes_exactly_at_22(self):
        code, _, _ = run_hooked(PLAIN_OK, [row(5000, 9.0, 22.0, 23.0), row(10000, 12.0, 15.0, 17.0)],
                                "--hooked-target-ms", "22.0")
        self.assertEqual(code, 0)

    def test_hooked_5k_gate_at_22_ms_fails_at_22_1(self):
        code, out, summ = run_hooked(PLAIN_OK, [row(5000, 9.0, 22.1, 23.0), row(10000, 12.0, 15.0, 17.0)],
                                     "--hooked-target-ms", "22.0")
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 22.10 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)
        self.assertIn("**FAIL**", summ)

    def test_hooked_budget_does_not_loosen_the_plain_tiers(self):
        code, out, _ = run_hooked([row(5000, 9.0, 17.0, 20.0), row(10000, 7.0, 8.0, 10.0)],
                                  [row(5000, 9.0, 18.0, 20.0), row(10000, 12.0, 15.0, 17.0)],
                                  "--hooked-target-ms", "22.0")
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 17.00 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)
        self.assertNotIn("[hooked] p95", out)

    def test_hooked_10k_stays_warn_only_at_the_hooked_budget(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 6.0, 9.0, 11.0), row(10000, 28.0, 30.0, 31.0)],
                                  "--hooked-target-ms", "22.0")
        self.assertEqual(code, 0)
        self.assertIn("::warning::[hooked] p95 30.00 ms > budget 22.0 ms at 10000 bullets (target)", out)
        self.assertNotIn("::error::", out)

    def test_nan_and_missing_still_fail_with_the_calibrated_budget(self):
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 6.0, float("nan"), 11.0), row(10000, 12.0, 15.0, 17.0)],
                                  "--hooked-target-ms", "22.0")
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] invalid timing at 5000 bullets (hard floor): work_p95_ms", out)
        code, out, _ = run_hooked(PLAIN_OK, [row(10000, 12.0, 15.0, 17.0)], "--hooked-target-ms", "22.0")
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] no result for hard floor count of 5000 bullets", out)

    # --- hooked/plain ratio: logged, never gated ---------------------------------------------------------

    def test_ratio_is_computed_and_logged_in_stdout_summary_and_json(self):
        with tempfile.TemporaryDirectory() as d:
            rj = os.path.join(d, "ratio.json")
            code, out, summ = run_hooked([row(5000, 3.0, 8.0, 9.0), row(10000, 6.0, 12.0, 13.0)],
                                         [row(5000, 6.0, 12.0, 13.0), row(10000, 12.0, 21.0, 22.0)],
                                         "--hooked-target-ms", "22.0", "--ratio-json", rj)
            with open(rj) as f:
                rows = json.load(f)["hooked_over_plain_p95"]
        self.assertEqual(code, 0)
        for text in (out, summ):
            self.assertIn("Hooked / plain p95 ratio", text)
            self.assertIn("| 5000 | 8.00 | 12.00 | 1.50x |", text)
            self.assertIn("| 10000 | 12.00 | 21.00 | 1.75x |", text)
        self.assertEqual([r["bullets"] for r in rows], [5000, 10000])
        self.assertAlmostEqual(rows[0]["ratio"], 1.5)
        self.assertAlmostEqual(rows[1]["ratio"], 1.75)

    def test_ratio_helper(self):
        plain = {5000: row(5000, 1, 4.0, 5), 10000: row(10000, 1, 0.0, 5)}
        hooked = {5000: row(5000, 1, 6.0, 7), 10000: row(10000, 1, 9.0, 7), 20000: row(20000, 1, 1.0, 1)}
        r = check_perf.ratios(plain, hooked, [5000, 10000, 20000, 30000])
        self.assertAlmostEqual(r[0]["ratio"], 1.5)
        self.assertIsNone(r[1]["ratio"], "zero plain p95")
        self.assertIsNone(r[2]["ratio"], "no plain row")
        self.assertIsNone(r[3]["ratio"], "no rows at all")
        self.assertEqual(r[1]["plain_p95_ms"], 0.0)

    def test_ratio_is_n_a_for_zero_missing_and_nan_without_crashing_or_failing(self):
        nan = float("nan")
        # plain 5k is zero, plain 10k row is missing: both n/a, and the gate result is unchanged (pass).
        code, out, summ = run_hooked([row(5000, 0.0, 0.0, 0.0)], HOOKED_OK)
        self.assertIn("| 5000 | 0.00 | 9.00 | n/a |", summ)
        self.assertIn("| 10000 | n/a | 15.00 | n/a |", summ)
        self.assertEqual(code, 0, "a missing plain 10k is only a warning, a zero 5k p95 is within budget")
        # NaN hooked 10k: ratio n/a, and only the existing 10k warning (not an error) results.
        code, out, summ = run_hooked(PLAIN_OK, [row(5000, 6.0, 9.0, 11.0), row(10000, 12.0, nan, 17.0)])
        self.assertEqual(code, 0)
        self.assertIn("| 10000 | 8.00 | n/a | n/a |", summ)

    def test_ratio_alone_never_fails_the_job(self):
        # A huge ratio (hooked 50x plain) within both budgets passes.
        code, out, summ = run_hooked([row(5000, 0.1, 0.2, 0.3), row(10000, 0.1, 0.2, 0.3)],
                                     [row(5000, 6.0, 10.0, 11.0), row(10000, 12.0, 15.0, 17.0)])
        self.assertEqual(code, 0)
        self.assertNotIn("::error::", out)
        self.assertIn("50.00x", summ)

    def test_ratio_json_write_failure_does_not_fail_the_job(self):
        code, out, _ = run_hooked(PLAIN_OK, HOOKED_OK, "--ratio-json", "/nonexistent-dir/ratio.json")
        self.assertEqual(code, 0)
        self.assertIn("::warning::could not write /nonexistent-dir/ratio.json", out)

    def test_no_ratio_section_without_a_hooked_report(self):
        _, out, summ = run(PLAIN_OK)
        self.assertNotIn("ratio", out + summ)


# --- same-run base (main) comparison: relative gate, runner normalization, clamp, fallback ------------------

def run_ab(plain, hooked, base_plain, base_hooked, *extra, raw_base=None):
    """Head plain/hooked plus base plain/hooked reports (FABRICATED values). base_* None = flag not passed.
    Returns (exit_code, stdout, summary_text)."""
    with tempfile.TemporaryDirectory() as d:
        def w(name, rows, hooked_doc=False):
            path = os.path.join(d, name)
            doc = {"godot": "test", "results": rows}
            if hooked_doc:
                doc["hooked_fraction"] = 1.0
            with open(path, "w") as f:
                json.dump(doc, f, allow_nan=True)
            return path
        args = [w("bench.json", plain), "--summary", os.path.join(d, "summary.md"),
                "--hooked-target-ms", "22.0"]
        if hooked is not None:
            args += ["--hooked-report", w("bench-hooked.json", hooked, True)]
        if raw_base is not None:
            bp = os.path.join(d, "base.json")
            with open(bp, "w") as f:
                f.write(raw_base)
            args += ["--base-report", bp]
        elif base_plain is not None:
            args += ["--base-report", w("base.json", base_plain)]
        if base_hooked is not None:
            args += ["--base-hooked-report", w("base-hooked.json", base_hooked, True)]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_perf.main(args + list(extra))
        with open(os.path.join(d, "summary.md")) as f:
            return code, out.getvalue(), f.read()


def pair(p5, p10):
    return [row(5000, p5 * 0.9, p5, p5 * 1.1), row(10000, p10 * 0.9, p10, p10 * 1.1)]


class SameRunBaseTest(unittest.TestCase):
    # The PR #35 situation: no sim change, slow runner. Plain 15 / hooked 22.8 on both base and head used to
    # fail the absolute 22 ms hooked gate; with the same-run base it passes (factor 2.0, normalized 11.4).
    def test_slow_runner_without_regression_passes(self):
        code, out, summ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), pair(15.2, 30.0), pair(22.6, 45.0))
        self.assertEqual(code, 0, out)
        self.assertNotIn("::error::", out)
        self.assertIn("Runner speed factor **2.03**", summ)
        self.assertIn("| hooked | 5000 | floor | 22.60 | 22.80 | +0.9% |", summ)

    def test_same_numbers_fail_without_a_base(self):
        code, out, _ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), None, None)
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 22.80 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)

    def test_relative_gate_fails_plain_floor_regression(self):
        # limit = 7.5 * 1.10 + 0.5 = 8.75
        code, out, summ = run_ab(pair(8.8, 15.0), pair(11.5, 22.0), pair(7.5, 15.0), pair(11.5, 22.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 regressed vs main on the same runner at 5000 bullets (hard floor): "
                      "7.50 -> 8.80 ms, limit 8.75 ms (+10% +0.5 ms)", out)
        self.assertIn("**FAIL** (regression)", summ)

    def test_relative_gate_passes_exactly_at_the_limit(self):
        code, out, _ = run_ab(pair(8.75, 15.0), pair(11.5, 22.0), pair(7.5, 15.0), pair(11.5, 22.0))
        self.assertEqual(code, 0, out)

    def test_relative_gate_fails_hooked_floor_regression(self):
        # limit = 11.5 * 1.10 + 0.5 = 13.15
        code, out, _ = run_ab(pair(7.5, 15.0), pair(13.2, 22.0), pair(7.5, 15.0), pair(11.5, 22.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 regressed vs main on the same runner at 5000 bullets (hard floor)", out)

    def test_relative_gate_at_target_only_warns(self):
        code, out, summ = run_ab(pair(7.5, 20.0), pair(11.5, 30.0), pair(7.5, 15.0), pair(11.5, 22.0))
        self.assertEqual(code, 0)
        self.assertIn("::warning::p95 regressed vs main on the same runner at 10000 bullets (target)", out)
        self.assertIn("::warning::[hooked] p95 regressed vs main on the same runner at 10000 bullets (target)", out)
        self.assertNotIn("::error::", out)
        self.assertIn("warning (regression", summ)

    def test_tolerance_and_slack_flags(self):
        args = ("--rel-tolerance-pct", "0", "--rel-slack-ms", "0")
        code, out, _ = run_ab(pair(7.6, 15.0), pair(11.5, 22.0), pair(7.5, 15.0), pair(11.5, 22.0), *args)
        self.assertEqual(code, 1)
        self.assertIn("limit 7.50 ms (+0% +0 ms)", out)
        code, _, _ = run_ab(pair(9.0, 15.0), pair(11.5, 22.0), pair(7.5, 15.0), pair(11.5, 22.0),
                            "--rel-tolerance-pct", "25", "--rel-slack-ms", "0")
        self.assertEqual(code, 0)

    def test_normalization_scales_the_absolute_budget(self):
        # Base plain 15 -> factor 2.0. Head hooked 40 is within relative (base 37) but normalized 20 <= 22: pass.
        code, out, summ = run_ab(pair(15.0, 30.0), pair(40.0, 80.0), pair(15.0, 30.0), pair(37.0, 80.0))
        self.assertEqual(code, 0, out)
        self.assertIn("normalized p95 20.00 ms (raw 40.00 ms / runner speed factor 2.00) within 22.0 ms", summ)
        self.assertIn("| 20.00 | 22 | pass |", summ)

    def test_normalized_budget_still_fails_when_base_and_head_are_both_too_slow(self):
        # Factor 2.0: head hooked 46 -> 23 > 22 fails although base was just as slow (main over budget too).
        code, out, summ = run_ab(pair(15.0, 30.0), pair(46.0, 90.0), pair(15.0, 30.0), pair(46.0, 90.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] normalized p95 23.00 ms (raw 46.00 ms / runner speed factor 2.00) "
                      "> budget 22.0 ms at 5000 bullets (hard floor)", out)
        self.assertIn("**FAIL** (over budget)", summ)

    def test_fast_runner_is_clamped_to_factor_one(self):
        # Base 3.75 = half the reference: factor would be 0.5 (stricter); it is clamped to 1.0, never below.
        code, out, summ = run_ab(pair(3.75, 8.0), pair(21.0, 30.0), pair(3.75, 8.0), pair(21.0, 30.0))
        self.assertEqual(code, 0, out)
        self.assertIn("Runner speed factor **1.00** = base plain p95 3.75 ms / reference 7.5 ms = 0.50", summ)
        self.assertEqual(check_perf.speed_factor({5000: row(5000, 1, 3.75, 4)}, 5000, 7.5, 3.0)[0], 1.0)

    def test_fast_runner_never_loosens_the_absolute_gate(self):
        # Factor 1.0: hooked 22.1 still fails the 22 ms gate even with no regression vs base.
        code, out, _ = run_ab(pair(7.0, 14.0), pair(22.1, 30.0), pair(7.0, 14.0), pair(22.1, 30.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 22.10 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)

    def test_factor_upper_clamp(self):
        f, raw, b = check_perf.speed_factor({5000: row(5000, 1, 75.0, 80)}, 5000, 7.5, 3.0)
        self.assertEqual((f, b), (3.0, 75.0))
        self.assertAlmostEqual(raw, 10.0)
        code, out, _ = run_ab(pair(75.0, 150.0), pair(70.0, 140.0), pair(75.0, 150.0), pair(70.0, 140.0))
        self.assertEqual(code, 1)  # 75 / 3 = 25 > 16.6: an absurdly slow runner cannot hide the budget
        self.assertIn("runner speed factor 3.00) > budget 16.6 ms", out)
        code, _, _ = run_ab(pair(75.0, 150.0), pair(70.0, 140.0), pair(75.0, 150.0), pair(70.0, 140.0),
                            "--max-speed-factor", "5.0")
        self.assertEqual(code, 0)  # 75 / 5 = 15 <= 16.6 once the cap is raised

    def test_reference_flag(self):
        code, _, summ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), pair(15.0, 30.0), pair(22.8, 45.0),
                               "--reference-ms", "15.0")
        self.assertEqual(code, 1)  # factor 1.0 at a 15 ms reference -> 22.8 > 22
        self.assertIn("Runner speed factor **1.00**", summ)

    def test_reference_constant_is_documented_value(self):
        self.assertEqual(check_perf.REFERENCE_PLAIN_FLOOR_P95_MS, 7.5)

    def test_fallback_without_base_is_the_absolute_gate(self):
        code, out, summ = run_ab(PLAIN_OK, HOOKED_OK, None, None)
        self.assertEqual(code, 0)
        self.assertIn("No same-run base (main) benchmark", summ)
        self.assertNotIn("Same-runner comparison", summ)
        self.assertNotIn("regressed vs main", out)

    def test_unreadable_base_falls_back_with_a_warning(self):
        for raw in ("", "{", "[]", '{"results": [1]}'):
            code, out, summ = run_ab(PLAIN_OK, HOOKED_OK, None, None, raw_base=raw)
            self.assertEqual(code, 0, raw)
            self.assertIn("::warning::cannot read base (main) results", out)
            self.assertIn("base (main) benchmark of this job was unusable", summ)
        # ... and the fallback is the strict absolute gate, not a pass-through.
        code, out, _ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), None, None, raw_base="{")
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 22.80 ms > budget 22.0 ms", out)

    def test_base_without_valid_floor_row_falls_back(self):
        for base in ([row(10000, 1, 15.0, 16)], [row(5000, 1, float("nan"), 2), row(10000, 1, 15.0, 16)],
                     [row(5000, 1, 15.0, 16, reached=False, min_alive=10), row(10000, 1, 15.0, 16)]):
            code, out, _ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), base, pair(22.8, 45.0))
            self.assertEqual(code, 1)
            self.assertIn("::warning::the base (main) run has no valid plain 5000-bullet p95", out)
            self.assertIn("::error::[hooked] p95 22.80 ms > budget 22.0 ms", out)

    def test_missing_base_hooked_skips_only_the_hooked_relative_check(self):
        code, out, summ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), pair(15.0, 30.0), None)
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::[hooked] no base (main) hooked report", out)
        self.assertIn("speed factor 2.00) within 22.0 ms", summ)

    def test_base_10k_missing_only_warns(self):
        code, out, _ = run_ab(PLAIN_OK, HOOKED_OK, [row(5000, 3.5, 5.0, 6.2)], HOOKED_OK)
        self.assertEqual(code, 0)
        self.assertIn("::warning::no valid base (main) result at 10000 bullets (target)", out)

    def test_head_errors_still_fail_with_a_base(self):
        code, out, _ = run_ab([row(5000, 1, float("nan"), 2), row(10000, 7.0, 8.0, 10.0)], HOOKED_OK,
                              PLAIN_OK, HOOKED_OK)
        self.assertEqual(code, 1)
        self.assertIn("::error::invalid timing at 5000 bullets (hard floor): work_p95_ms", out)
        code, out, _ = run_ab([row(5000, 1, 4.0, 2, reached=False, min_alive=10), row(10000, 7.0, 8.0, 10.0)],
                              HOOKED_OK, PLAIN_OK, HOOKED_OK)
        self.assertEqual(code, 1)
        self.assertIn("::error::shortfall at 5000 bullets", out)

    def test_summary_table_has_base_head_delta_normalized_verdict(self):
        _, _, summ = run_ab(pair(15.0, 30.0), pair(22.8, 45.0), pair(15.0, 30.0), pair(22.6, 45.0))
        self.assertIn("| tier | bullets | role | base p95 ms | head p95 ms | delta % | rel. limit ms | "
                      "head normalized ms | budget ms | verdict |", summ)
        self.assertIn("| plain | 5000 | floor | 15.00 | 15.00 | +0.0% | 17.00 | 7.50 | 16.6 | pass |", summ)
        self.assertIn("| hooked | 10000 | target | 45.00 | 45.00 | +0.0% | 50.00 | 22.50 | 22 | warning (over budget) |",
                      summ)
        # The comparison comes first in the summary, before the per-tier tables.
        self.assertLess(summ.index("Same-runner comparison"), summ.index("### Bullet benchmark"))


if __name__ == "__main__":
    unittest.main()
