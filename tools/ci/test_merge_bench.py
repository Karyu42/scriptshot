"""Unit tests for merge_bench.py. All numbers are FABRICATED TEST DATA."""
import contextlib
import io
import json
import os
import tempfile
import unittest

import merge_bench


def row(n, p50, p95, p99, reached=True, min_alive=None):
    return {"bullets": n, "work_p50_ms": p50, "work_p95_ms": p95, "work_p99_ms": p99, "reached": reached,
            "min_alive_before_step": n if min_alive is None else min_alive}


def run(*docs, raw=None):
    with tempfile.TemporaryDirectory() as d:
        paths = []
        for i, doc in enumerate(docs):
            p = os.path.join(d, f"in{i}.json")
            with open(p, "w") as f:
                f.write(raw if raw is not None and i == 0 else json.dumps(doc, allow_nan=True))
            paths.append(p)
        out = os.path.join(d, "out.json")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = merge_bench.main([out, *paths])
        merged = None
        if code == 0:
            with open(out) as f:
                merged = json.load(f)
        return code, buf.getvalue(), merged


class MergeBenchTest(unittest.TestCase):
    def test_two_rounds_take_the_mean_three_the_median(self):
        a = {"godot": "x", "results": [row(5000, 1.0, 8.0, 9.0)]}
        b = {"godot": "x", "results": [row(5000, 2.0, 10.0, 11.0)]}
        c = {"godot": "x", "results": [row(5000, 3.0, 30.0, 31.0)]}
        code, _, m = run(a, b)
        self.assertEqual(code, 0)
        self.assertEqual(m["rounds"], 2)
        self.assertEqual(m["results"][0]["work_p95_ms"], 9.0)
        self.assertEqual(m["results"][0]["work_p95_samples_ms"], [8.0, 10.0])
        _, _, m = run(a, b, c)
        self.assertEqual(m["results"][0]["work_p95_ms"], 10.0)

    def test_one_round_is_identity(self):
        a = {"godot": "x", "hooked_fraction": 1.0, "results": [row(5000, 1.0, 8.0, 9.0), row(10000, 2, 16, 18)]}
        _, _, m = run(a)
        self.assertEqual([r["work_p95_ms"] for r in m["results"]], [8.0, 16.0])
        self.assertEqual(m["hooked_fraction"], 1.0)

    def test_a_bad_round_poisons_the_value(self):
        a = {"results": [row(5000, 1.0, float("nan"), 9.0)]}
        b = {"results": [row(5000, 1.0, 8.0, 9.0)]}
        _, _, m = run(a, b)
        self.assertIsNone(m["results"][0]["work_p95_ms"])

    def test_shortfall_in_any_round_and_min_alive(self):
        a = {"results": [row(5000, 1.0, 8.0, 9.0, reached=False, min_alive=4000)]}
        b = {"results": [row(5000, 1.0, 8.0, 9.0)]}
        _, _, m = run(a, b)
        self.assertFalse(m["results"][0]["reached"])
        self.assertEqual(m["results"][0]["min_alive_before_step"], 4000)

    def test_count_missing_in_one_round_is_dropped(self):
        a = {"results": [row(5000, 1, 8, 9), row(10000, 1, 16, 18)]}
        b = {"results": [row(5000, 1, 8, 9)]}
        _, _, m = run(a, b)
        self.assertEqual([r["bullets"] for r in m["results"]], [5000])

    def test_mismatched_hooked_fraction_is_nulled(self):
        a = {"hooked_fraction": 1.0, "results": [row(5000, 1, 8, 9)]}
        b = {"hooked_fraction": 0.5, "results": [row(5000, 1, 8, 9)]}
        _, _, m = run(a, b)
        self.assertIsNone(m["hooked_fraction"])

    def test_unreadable_input_fails(self):
        for raw in ("", "{", "[]", '{"results": [1]}'):
            code, out, _ = run({}, raw=raw)
            self.assertEqual(code, 1, raw)
            self.assertIn("::error::merge_bench.py: cannot read", out)

    def test_backend_and_batch_must_match_in_every_round(self):
        a = {"backend": "native", "batch": 1, "results": [row(5000, 1.0, 2.0, 3.0)]}
        b = {"backend": "native", "batch": 1, "results": [row(5000, 1.0, 2.2, 3.0)]}
        c = {"backend": "gdscript", "batch": 1, "results": [row(5000, 1.0, 9.0, 10.0)]}
        _, _, m = run(a, b)
        self.assertEqual((m["backend"], m["batch"]), ("native", 1))
        _, _, m = run(a, c)
        self.assertIsNone(m["backend"])  # a fallback round must not pass as native
        self.assertEqual(m["batch"], 1)
        _, _, m = run(a, dict(b, batch=0))
        self.assertIsNone(m["batch"])
        _, _, m = run({"results": [row(5000, 1.0, 2.0, 3.0)]})
        self.assertNotIn("backend", m)


if __name__ == "__main__":
    unittest.main()
