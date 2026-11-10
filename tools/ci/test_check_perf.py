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
    """CoS ruling for #42: raw mode by default; slow-runner mode only when the base also misses the bar;
    the relative check always applies, with no absolute slack. All numbers FABRICATED."""

    # --- raw mode (base under the bar) ---------------------------------------------------------------------

    def test_raw_mode_base_under_bar_head_over_fails_hooked_21_to_23(self):
        code, out, summ = run_ab(pair(7.5, 15.0), pair(23.0, 40.0), pair(7.5, 15.0), pair(21.0, 40.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 23.00 ms > budget 22.00 ms at 5000 bullets (hard floor), mode=raw", out)
        self.assertIn("perf mode: hooked 5000: mode=raw", out)
        self.assertIn("| hooked | 5000 | floor | 21.00 | 23.00 | +9.5% | 23.10 | pass | mode=raw | 22.00 | over | "
                      "**FAIL** (over bar) |", summ)

    def test_raw_mode_22_18_with_factor_1_86_fails(self):
        # The #42 CI runner: base plain 13.95 (F 1.86), base hooked 21.34 under the bar -> raw mode, 22.18 fails.
        code, out, _ = run_ab(pair(13.95, 28.0), pair(22.18, 43.0), pair(13.95, 28.0), pair(21.34, 42.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 22.18 ms > budget 22.00 ms at 5000 bullets (hard floor), mode=raw", out)

    def test_ge_plain_16_to_17_5_fails_in_raw_mode(self):
        # Relative limit 17.6 is not hit; the raw 16.6 bar is (base 16 < 16.6, so no slow-runner mode).
        code, out, _ = run_ab(pair(17.5, 30.0), pair(20.0, 40.0), pair(16.0, 30.0), pair(20.0, 40.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 17.50 ms > budget 16.60 ms at 5000 bullets (hard floor), mode=raw", out)
        self.assertNotIn("regressed vs main on the same runner at 5000", out)

    def test_ge_plain_10_to_11_1_fails_relative(self):
        code, out, _ = run_ab(pair(11.1, 20.0), pair(15.0, 30.0), pair(10.0, 20.0), pair(15.0, 30.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 regressed vs main on the same runner at 5000 bullets (hard floor): "
                      "10.00 -> 11.10 ms, limit 11.00 ms (+10%)", out)

    def test_ge_hooked_12_to_13_32_fails_relative(self):
        code, out, _ = run_ab(pair(8.0, 16.0), pair(13.32, 26.0), pair(8.0, 16.0), pair(12.0, 26.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 regressed vs main on the same runner at 5000 bullets (hard floor): "
                      "12.00 -> 13.32 ms, limit 13.20 ms (+10%)", out)

    def test_relative_passes_exactly_at_the_limit_and_has_no_slack(self):
        code, out, _ = run_ab(pair(11.0, 20.0), pair(15.0, 30.0), pair(10.0, 20.0), pair(15.0, 30.0))
        self.assertEqual(code, 0, out)
        code, out, _ = run_ab(pair(11.01, 20.0), pair(15.0, 30.0), pair(10.0, 20.0), pair(15.0, 30.0))
        self.assertEqual(code, 1)  # +0.5 ms slack would have let this pass

    def test_tolerance_flag(self):
        code, out, _ = run_ab(pair(7.6, 15.0), pair(11.5, 22.0), pair(7.5, 15.0), pair(11.5, 22.0),
                              "--rel-tolerance-pct", "0")
        self.assertEqual(code, 1)
        self.assertIn("limit 7.50 ms (+0%)", out)
        code, _, _ = run_ab(pair(9.0, 15.0), pair(11.5, 22.0), pair(7.5, 15.0), pair(11.5, 22.0),
                            "--rel-tolerance-pct", "25")
        self.assertEqual(code, 0)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run_ab(PLAIN_OK, HOOKED_OK, PLAIN_OK, HOOKED_OK, "--rel-slack-ms", "0.5")

    # --- slow-runner mode (base also over the bar) -----------------------------------------------------------

    def test_slow_runner_base_23_head_23_5_hooked_passes(self):
        code, out, summ = run_ab(pair(14.0, 28.0), pair(23.5, 45.0), pair(14.0, 28.0), pair(23.0, 45.0))
        self.assertEqual(code, 0, out)
        mode = "mode=slow-runner (base 23.0 > 22.0, F=1.87, cap 1.5, bar 33.0)"
        self.assertIn(f"perf mode: hooked 5000: {mode}", out)
        self.assertIn(f"| hooked | 5000 | floor | 23.00 | 23.50 | +2.2% | 25.30 | pass | {mode} | 33.00 | pass | pass |",
                      summ)
        self.assertIn("perf mode: plain 5000: mode=raw", out)  # plain base 14 < 16.6 stays raw

    def test_slow_runner_bar_uses_F_below_the_cap(self):
        # F = 9.0 / 7.5 = 1.2 -> bar 26.4; head 24.0 within relative (base 22.5 -> 24.75).
        code, out, _ = run_ab(pair(9.0, 18.0), pair(24.0, 45.0), pair(9.0, 18.0), pair(22.5, 45.0))
        self.assertEqual(code, 0, out)
        self.assertIn("mode=slow-runner (base 22.5 > 22.0, F=1.20, cap 1.5, bar 26.4)", out)

    def test_slow_runner_head_over_the_1_5x_cap_fails(self):
        # F = 4.0 is capped at 1.5: bar 33.0. Head 34 is within relative (32 -> 35.2) but over the cap.
        code, out, _ = run_ab(pair(30.0, 60.0), pair(34.0, 70.0), pair(30.0, 60.0), pair(32.0, 70.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 34.00 ms > budget 33.00 ms at 5000 bullets (hard floor), "
                      "mode=slow-runner (base 32.0 > 22.0, F=4.00, cap 1.5, bar 33.0)", out)
        # plain: base 30 > 16.6 -> slow-runner, bar 24.9; head 30 is over it.
        self.assertIn("::error::p95 30.00 ms > budget 24.90 ms at 5000 bullets (hard floor), mode=slow-runner", out)

    def test_slow_runner_with_regression_over_10_pct_fails(self):
        code, out, _ = run_ab(pair(14.0, 28.0), pair(25.4, 45.0), pair(14.0, 28.0), pair(23.0, 45.0))
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 regressed vs main on the same runner at 5000 bullets (hard floor): "
                      "23.00 -> 25.40 ms, limit 25.30 ms (+10%)", out)
        self.assertNotIn("[hooked] p95 25.40 ms > budget", out)  # within the slow-runner bar 33.0

    def test_slow_runner_factor_is_clamped_to_one(self):
        # Fast plain base (F = 0.5 -> 1.0) with a hooked base over the bar: slow-runner mode, but the bar stays 22.
        code, out, _ = run_ab(pair(3.75, 8.0), pair(23.0, 40.0), pair(3.75, 8.0), pair(23.0, 40.0))
        self.assertEqual(code, 1)
        self.assertIn("mode=slow-runner (base 23.0 > 22.0, F=1.00, cap 1.5, bar 22.0)", out)
        self.assertEqual(check_perf.speed_factor({5000: row(5000, 1, 3.75, 4)}, 5000, 7.5), (1.0, 3.75))

    def test_slow_runner_cap_and_reference_flags(self):
        args = (pair(30.0, 60.0), pair(34.0, 70.0), pair(30.0, 60.0), pair(32.0, 70.0))
        code, out, _ = run_ab(*args, "--slow-runner-cap", "2.0")
        self.assertIn("bar 44.0)", out)
        self.assertNotIn("[hooked] p95 34.00 ms > budget", out)
        code, out, _ = run_ab(pair(14.0, 28.0), pair(23.5, 45.0), pair(14.0, 28.0), pair(23.0, 45.0),
                              "--reference-ms", "14.0")
        self.assertEqual(code, 1)  # F = 1.0 -> bar 22.0
        self.assertIn("F=1.00, cap 1.5, bar 22.0", out)

    def test_target_uses_the_same_logic_and_only_warns(self):
        # plain 10k base 30 > 16.6 -> slow-runner bar 24.9; head 31 over it and > 33.0 relative: warnings only.
        code, out, summ = run_ab(pair(14.0, 34.0), pair(20.0, 40.0), pair(14.0, 30.0), pair(20.0, 40.0))
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::p95 34.00 ms > budget 24.90 ms at 10000 bullets (target), mode=slow-runner "
                      "(base 30.0 > 16.6, F=1.87, cap 1.5, bar 24.9)", out)
        self.assertIn("::warning::p95 regressed vs main on the same runner at 10000 bullets (target)", out)
        self.assertNotIn("::error::", out)
        self.assertIn("warning (regression, over bar)", summ)

    # --- no usable base -> raw mode ---------------------------------------------------------------------------

    def test_nan_base_gives_raw_mode(self):
        for base in ([row(5000, 1, float("nan"), 2), row(10000, 1, 30.0, 31)], [row(10000, 1, 30.0, 31)],
                     [row(5000, 1, 15.0, 16, reached=False, min_alive=10), row(10000, 1, 30.0, 31)]):
            code, out, summ = run_ab(pair(15.0, 30.0), pair(23.5, 45.0), base, pair(23.0, 45.0))
            self.assertEqual(code, 1)
            self.assertIn("::warning::the base (main) run has no valid plain 5000-bullet p95; mode=raw", out)
            self.assertIn("perf mode: hooked: mode=raw (no usable same-run base)", out)
            self.assertIn("::error::[hooked] p95 23.50 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)
            self.assertIn("unusable: mode=raw", summ)

    def test_nan_hooked_base_row_gives_raw_mode_for_that_count(self):
        code, out, _ = run_ab(pair(14.0, 28.0), pair(23.5, 45.0), pair(14.0, 28.0),
                              [row(5000, 1, float("nan"), 2), row(10000, 1, 45.0, 46)])
        self.assertEqual(code, 1)
        self.assertIn("perf mode: hooked 5000: mode=raw (no valid base at this count)", out)
        self.assertIn("::error::[hooked] p95 23.50 ms > budget 22.00 ms at 5000 bullets (hard floor), mode=raw", out)

    def test_fallback_without_base_is_the_absolute_gate(self):
        code, out, summ = run_ab(PLAIN_OK, HOOKED_OK, None, None)
        self.assertEqual(code, 0)
        self.assertIn("No same-run base (main) benchmark", summ)
        self.assertIn("mode=raw", summ)
        self.assertNotIn("Same-runner comparison", summ)
        code, out, _ = run_ab(pair(15.0, 30.0), pair(23.0, 45.0), None, None)
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 23.00 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)

    def test_unreadable_base_falls_back_to_raw_with_a_warning(self):
        for raw in ("", "{", "[]", '{"results": [1]}'):
            code, out, summ = run_ab(PLAIN_OK, HOOKED_OK, None, None, raw_base=raw)
            self.assertEqual(code, 0, raw)
            self.assertIn("::warning::cannot read base (main) results", out)
            self.assertIn("unusable: mode=raw", summ)
        code, out, _ = run_ab(pair(15.0, 30.0), pair(23.0, 45.0), None, None, raw_base="{")
        self.assertEqual(code, 1)

    def test_missing_base_hooked_gives_raw_hooked_mode(self):
        code, out, _ = run_ab(pair(14.0, 28.0), pair(23.0, 45.0), pair(14.0, 28.0), None)
        self.assertEqual(code, 1)
        self.assertIn("::warning::[hooked] no base (main) hooked report: hooked mode=raw", out)
        self.assertIn("::error::[hooked] p95 23.00 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)

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

    def test_summary_table_layout_and_order(self):
        _, _, summ = run_ab(pair(7.5, 15.0), pair(11.5, 23.0), pair(7.5, 15.0), pair(11.5, 23.0))
        self.assertIn("| tier | bullets | role | base p95 ms | head p95 ms | delta % | rel. limit ms | relative | "
                      "mode | head bar ms | bar check | verdict |", summ)
        self.assertIn("| plain | 5000 | floor | 7.50 | 7.50 | +0.0% | 8.25 | pass | mode=raw | 16.60 | pass | pass |",
                      summ)
        self.assertIn("**F = 1.00**", summ)
        self.assertLess(summ.index("Same-runner comparison"), summ.index("### Bullet benchmark"))


class PushParentBaseTest(unittest.TestCase):
    """CoS ruling 2026-11-10: a push to main is gated against its parent commit (the previous main tip), benchmarked
    in the same job, with the #42 rules unchanged; a missing / unusable parent falls back to the raw bars only and is
    logged. All numbers FABRICATED."""
    PUSH = ("--base-kind", "push-parent", "--base-sha", "a" * 40)

    # --- parent present: the #42 rules, unchanged --------------------------------------------------------------

    def test_parent_present_pass_logs_the_parent_base(self):
        code, out, summ = run_ab(pair(7.5, 15.0), pair(11.5, 23.0), pair(7.5, 15.0), pair(11.5, 23.0), *self.PUSH)
        self.assertEqual(code, 0, out)
        self.assertIn(f"perf base: parent commit {'a' * 40} (previous branch tip: main on push, the dispatched branch on workflow_dispatch), same job, same runner",
                      out)
        self.assertIn("perf mode: plain 5000: mode=raw", out)
        self.assertIn("perf mode: hooked 5000: mode=raw", out)
        self.assertIn("### Same-runner comparison: pushed head vs base (parent commit = previous main tip)", summ)
        self.assertNotIn("FALLBACK", out + summ)

    def test_parent_under_bar_head_over_hooked_bar_fails_raw(self):
        # Parent 21.0 meets the 22.0 bar, so no slow-runner mode: the pushed head at 23.6 fails the hard bar.
        code, out, _ = run_ab(pair(7.5, 15.0), pair(23.6, 45.0), pair(7.5, 15.0), pair(21.0, 45.0), *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 23.60 ms > budget 22.00 ms at 5000 bullets (hard floor), mode=raw", out)

    def test_parent_under_plain_bar_head_over_fails_raw(self):
        code, out, _ = run_ab(pair(16.7, 30.0), pair(20.0, 40.0), pair(16.0, 30.0), pair(20.0, 40.0), *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 16.70 ms > budget 16.60 ms at 5000 bullets (hard floor), mode=raw", out)

    def test_relative_check_vs_parent_has_no_slack(self):
        code, out, _ = run_ab(pair(11.01, 20.0), pair(15.0, 30.0), pair(10.0, 20.0), pair(15.0, 30.0), *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 regressed vs the parent commit on the same runner at 5000 bullets (hard floor): "
                      "10.00 -> 11.01 ms, limit 11.00 ms (+10%)", out)
        code, out, _ = run_ab(pair(11.0, 20.0), pair(15.0, 30.0), pair(10.0, 20.0), pair(15.0, 30.0), *self.PUSH)
        self.assertEqual(code, 0, out)

    def test_slow_runner_only_when_the_parent_also_misses_and_capped(self):
        # Parent hooked 23.0 > 22.0 and plain 14.0 (F 1.87 -> cap 1.5): bar 33.0; head 23.5 within +10% passes.
        code, out, _ = run_ab(pair(14.0, 28.0), pair(23.5, 45.0), pair(14.0, 28.0), pair(23.0, 45.0), *self.PUSH)
        self.assertEqual(code, 0, out)
        self.assertIn("perf mode: hooked 5000: mode=slow-runner (base 23.0 > 22.0, F=1.87, cap 1.5, bar 33.0)", out)
        # Same slow runner, but the head regressed more than 10% vs the parent: fails.
        code, out, _ = run_ab(pair(14.0, 28.0), pair(25.4, 45.0), pair(14.0, 28.0), pair(23.0, 45.0), *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 regressed vs the parent commit on the same runner at 5000 bullets", out)
        # Over the 1.5x cap: fails even though the parent is just as slow.
        code, out, _ = run_ab(pair(30.0, 60.0), pair(34.0, 70.0), pair(30.0, 60.0), pair(32.0, 70.0), *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 34.00 ms > budget 33.00 ms at 5000 bullets (hard floor), "
                      "mode=slow-runner", out)

    def test_10k_stays_warn_only_in_push_mode(self):
        code, out, _ = run_ab(pair(14.0, 34.0), pair(20.0, 60.0), pair(14.0, 30.0), pair(20.0, 40.0), *self.PUSH)
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::p95 regressed vs the parent commit on the same runner at 10000 bullets (target)", out)
        self.assertNotIn("::error::", out)

    # --- parent missing or unusable: raw bars only, logged as FALLBACK -----------------------------------------

    def test_parent_missing_falls_back_to_the_raw_bars_and_logs_it(self):
        reason = "HEAD has no parent commit (first commit or no history)"
        code, out, summ = run_ab(PLAIN_OK, HOOKED_OK, None, None, "--base-kind", "push-parent",
                                 "--no-base-reason", reason)
        self.assertEqual(code, 0, out)
        self.assertIn(f"perf base: none (push to main; parent commit unavailable: {reason}) -> FALLBACK mode=raw: "
                      f"raw bars only, no relative check", out)
        self.assertIn("perf mode: plain: mode=raw (no usable same-run base)", out)
        self.assertIn("perf mode: hooked: mode=raw (no usable same-run base)", out)
        self.assertIn(f"_FALLBACK: no same-run base (the parent commit could not be benchmarked: {reason})", summ)
        self.assertNotIn("Same-runner comparison", summ)
        # The hard bars still fail.
        code, out, _ = run_ab(pair(15.0, 30.0), pair(22.1, 45.0), None, None, "--base-kind", "push-parent",
                              "--no-base-reason", reason)
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] p95 22.10 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)
        code, out, _ = run_ab(pair(16.61, 30.0), HOOKED_OK, None, None, "--base-kind", "push-parent",
                              "--no-base-reason", reason)
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 16.61 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)

    def test_parent_that_cannot_be_benchmarked_falls_back_to_raw(self):
        # perf_ab.sh drops the base files when the parent has no tools/run_benchmark.sh or its run fails: the
        # --base-report path is then missing (or unreadable). Raw bars only, logged as FALLBACK.
        for raw in ("", "{", '{"results": [1]}'):
            code, out, summ = run_ab(pair(15.0, 30.0), pair(23.0, 45.0), None, None, *self.PUSH, raw_base=raw)
            self.assertEqual(code, 1, raw)
            self.assertIn("::warning::cannot read base (parent) results", out)
            self.assertIn("but its benchmark is unusable -> FALLBACK mode=raw", out)
            self.assertIn("::error::[hooked] p95 23.00 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)
            self.assertIn("_FALLBACK: the base (parent commit) benchmark of this job was unusable", summ)
        # A NaN parent plain 5k row cannot unlock slow-runner mode either.
        nan_base = [row(5000, 1, float("nan"), 2), row(10000, 1, 30.0, 31)]
        code, out, _ = run_ab(pair(15.0, 30.0), pair(23.5, 45.0), nan_base, pair(23.0, 45.0), *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::warning::the base (parent) run has no valid plain 5000-bullet p95; mode=raw", out)

    def test_parent_without_a_hooked_report_gives_raw_hooked_mode(self):
        code, out, _ = run_ab(pair(14.0, 28.0), pair(23.0, 45.0), pair(14.0, 28.0), None, *self.PUSH)
        self.assertEqual(code, 1)
        self.assertIn("::warning::[hooked] no base (parent) hooked report: hooked mode=raw", out)
        self.assertIn("::error::[hooked] p95 23.00 ms > budget 22.0 ms at 5000 bullets (hard floor)", out)

    def test_fallback_is_never_looser_than_the_raw_bars(self):
        # Exit code of the push fallback == the exit code with no base at all, over a grid around both bars.
        for p5 in (15.0, 16.6, 16.61, 20.0, 30.0):
            for h5 in (20.0, 22.0, 22.01, 23.6, 34.0):
                args = (pair(p5, 2 * p5), pair(h5, 2 * h5), None, None)
                raw_code, _, _ = run_ab(*args)
                fb_code, _, _ = run_ab(*args, "--base-kind", "push-parent", "--no-base-reason", "x")
                bad_code, _, _ = run_ab(*args, *self.PUSH, raw_base="{")
                self.assertEqual(fb_code, raw_code, (p5, h5))
                self.assertEqual(bad_code, raw_code, (p5, h5))
                self.assertEqual(raw_code, 0 if (p5 <= 16.6 and h5 <= 22.0) else 1, (p5, h5))

    def test_no_base_reason_needs_push_parent(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
            run_ab(PLAIN_OK, HOOKED_OK, None, None, "--no-base-reason", "x")
        self.assertEqual(cm.exception.code, 2)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            run_ab(PLAIN_OK, HOOKED_OK, None, None, "--base-kind", "post-merge")

    def test_pr_mode_wording_is_unchanged(self):
        code, out, summ = run_ab(pair(11.1, 20.0), pair(15.0, 30.0), pair(10.0, 20.0), pair(15.0, 30.0))
        self.assertEqual(code, 1)
        self.assertIn("regressed vs main on the same runner", out)
        self.assertIn("### Same-runner comparison: PR head vs base (main), measured in this job", summ)
        self.assertNotIn("perf base:", out)
        _, out, summ = run_ab(PLAIN_OK, HOOKED_OK, None, None)
        self.assertNotIn("perf base:", out)
        self.assertIn("_No same-run base (main) benchmark (push to main or workflow_dispatch)", summ)



class FloatFlagTest(unittest.TestCase):
    """Float flags are validated by argparse: a bad value exits 2 with a message naming the flag."""

    def _rejects(self, flag, value):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as cm:
            # flag=value so argparse does not read "-inf" or "-3" as an option.
            run([row(5000, 3.5, 5.0, 6.2)], f"{flag}={value}")
        self.assertEqual(cm.exception.code, 2)
        self.assertIn(flag, err.getvalue())
        self.assertIn("must be a", err.getvalue())

    def test_slow_runner_cap_rejects_non_finite_and_non_positive(self):
        for v in ("nan", "inf", "-inf", "0", "-1.5", "0.5", "abc"):
            with self.subTest(value=v):
                self._rejects("--slow-runner-cap", v)

    def test_ms_flags_reject_non_finite_and_non_positive(self):
        for flag in ("--p95-ms", "--hooked-target-ms", "--reference-ms"):
            for v in ("nan", "inf", "0", "-3"):
                with self.subTest(flag=flag, value=v):
                    self._rejects(flag, v)

    def test_percent_flags_reject_non_finite_and_negative(self):
        for flag in ("--regression-pct", "--rel-tolerance-pct"):
            for v in ("nan", "inf", "-1"):
                with self.subTest(flag=flag, value=v):
                    self._rejects(flag, v)

    def test_valid_values_are_accepted(self):
        code, _, _ = run([row(5000, 3.5, 5.0, 6.2), row(10000, 7.0, 8.0, 10.0)],
                         "--slow-runner-cap", "1", "--rel-tolerance-pct", "0", "--regression-pct", "0",
                         "--p95-ms", "16.6", "--reference-ms", "7.5")
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
