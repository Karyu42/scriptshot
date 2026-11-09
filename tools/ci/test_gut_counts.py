#!/usr/bin/env python3
"""Unit tests for tools/ci/gut_counts.py (the 0-pending native gate)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gut_counts  # noqa: E402

BUILT = """run_tests.sh: Lua host guards
Scripts               1
Tests                10
Passing Tests        10
Asserts              83
Time              0.459s
\x1b[32m---- All tests passed! ----\x1b[0m
run_tests.sh: unit + bullet hooks
Scripts              70
Tests              1088
Passing Tests      1088
Asserts           57001
Time              53.153s
---- All tests passed! ----
"""
UNBUILT = BUILT.replace("Passing Tests      1088", "Passing Tests      1014\nRisky/Pending        74")
FAILING = BUILT.replace("Passing Tests      1088", "Passing Tests      1087\nFailing Tests         1")


class GutCounts(unittest.TestCase):
    def run_main(self, text, *args):
        with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False, encoding="utf-8") as f:
            f.write(text)
        try:
            return gut_counts.main([f.name, *args])
        finally:
            os.unlink(f.name)

    def test_parse_built(self):
        s = gut_counts.parse(BUILT)
        self.assertEqual(s["Lua host guards"]["tests"], 10)
        self.assertEqual(s["unit + bullet hooks"]["passing"], 1088)
        self.assertEqual(s["unit + bullet hooks"]["pending"], 0)

    def test_built_passes_expect_native(self):
        self.assertEqual(self.run_main(BUILT, "--expect-native"), 0)

    def test_unbuilt_fails_expect_native(self):
        self.assertEqual(gut_counts.parse(UNBUILT)["unit + bullet hooks"]["pending"], 74)
        self.assertEqual(self.run_main(UNBUILT, "--expect-native"), 1)

    def test_unbuilt_is_fine_without_expect_native(self):
        self.assertEqual(self.run_main(UNBUILT), 0)

    def test_failing_fails_expect_native(self):
        self.assertEqual(self.run_main(FAILING, "--expect-native"), 1)

    def test_missing_process_fails(self):
        one = BUILT.split("run_tests.sh: unit")[0]
        self.assertEqual(self.run_main(one, "--expect-native"), 1)

    def test_crlf_log(self):
        self.assertEqual(self.run_main(BUILT.replace("\n", "\r\n"), "--expect-native"), 0)


if __name__ == "__main__":
    unittest.main()
