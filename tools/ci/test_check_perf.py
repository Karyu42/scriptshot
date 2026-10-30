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


def row(bullets, p50, p95, p99):
    return {"bullets": bullets, "work_p50_ms": p50, "work_p95_ms": p95, "work_p99_ms": p99}


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
        self.assertIn("over budget (warning)", summ)
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

    def test_unreadable_report_fails(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = check_perf.main(["/nonexistent/bench.json"])
        self.assertEqual(code, 1)
        self.assertIn("::error::cannot read benchmark results", out.getvalue())


if __name__ == "__main__":
    unittest.main()
