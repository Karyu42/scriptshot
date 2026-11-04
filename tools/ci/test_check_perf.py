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
        code, out, _ = run_hooked(PLAIN_OK, [row(5000, 1.0, 1.5, 2.0, reached=False, min_alive=4100),
                                             row(10000, 1.0, 2.0, 3.0, reached=False, min_alive=8000)])
        self.assertEqual(code, 1)
        self.assertIn("::error::[hooked] shortfall at 5000 bullets (hard floor): only 4100 were alive", out)
        self.assertIn("::warning::[hooked] shortfall at 10000 bullets (target): only 8000 were alive", out)

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

    def test_warn_only_option_demotes_the_hooked_floor_but_not_the_plain_one(self):
        over = [row(5000, 9.0, 16.61, 20.0), row(10000, 12.0, 15.0, 17.0)]
        code, out, _ = run_hooked(PLAIN_OK, over, "--hooked-floor-warn-only")
        self.assertEqual(code, 0)
        self.assertIn("::warning::[hooked] p95 16.61 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)
        self.assertNotIn("::error::", out)
        code, out, _ = run_hooked([row(5000, 9.0, 17.0, 20.0), row(10000, 7.0, 8.0, 10.0)], over,
                                  "--hooked-floor-warn-only")
        self.assertEqual(code, 1)
        self.assertIn("::error::p95 17.00 ms > budget 16.6 ms at 5000 bullets (hard floor)", out)


if __name__ == "__main__":
    unittest.main()
