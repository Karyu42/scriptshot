"""Unit tests for junit_green.py (FABRICATED junit files)."""
import contextlib
import io
import os
import tempfile
import unittest

import junit_green

GREEN = ('<?xml version="1.0" encoding="UTF-8"?>\n<testsuites name="GutTests" failures="0" tests="2" >\n'
         '  <testsuite name="a.gd" tests="2" failures="0" skipped="1" time="0.1" >\n'
         '    <testcase name="t1" assertions="1" status="pass" classname="a.gd" time="0.1" ></testcase>\n'
         '    <testcase name="t2" assertions="0" status="pending" classname="a.gd" time="0" >'
         '<skipped message="pending"/></testcase>\n'
         '  </testsuite>\n</testsuites>\n')


def check(text):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "j.xml")
        if text is not None:
            with open(p, "w") as f:
                f.write(text)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            code = junit_green.main([p])
        return code, out.getvalue()


class JunitGreenTest(unittest.TestCase):
    def test_green(self):
        self.assertEqual(check(GREEN)[0], 0)

    def test_missing_empty_and_malformed_are_red(self):
        for text, why in ((None, "was not written"), ("", "is empty"), ("<testsuites", "malformed"),
                          ("not xml", "malformed"), ("<html/>", "expected <testsuites>")):
            code, out = check(text)
            self.assertEqual(code, 1, text)
            self.assertIn(why, out)

    def test_failures_or_errors_attributes_are_red(self):
        for old, new in (('<testsuites name="GutTests" failures="0"', '<testsuites name="GutTests" failures="1"'),
                         ('<testsuites name="GutTests"', '<testsuites name="GutTests" errors="1"'),
                         ('<testsuite name="a.gd" tests="2" failures="0"', '<testsuite name="a.gd" tests="2" failures="1"'),
                         ('<testsuite name="a.gd"', '<testsuite name="a.gd" errors="2"'),
                         ('failures="0" tests="2" >', 'failures="x" tests="2" >'),
                         ('failures="0" tests="2" >', 'failures="-1" tests="2" >')):
            code, _ = check(GREEN.replace(old, new, 1))
            self.assertEqual(code, 1, new)

    def test_failure_element_with_zero_counts_is_red(self):
        code, out = check(GREEN.replace('status="pass" classname="a.gd" time="0.1" >',
                                        'status="fail" classname="a.gd" time="0.1" ><failure message="x"/>'))
        self.assertEqual(code, 1)
        self.assertIn("elements 1", out)

    def test_single_testsuite_root(self):
        self.assertEqual(check('<testsuite name="x" tests="1" failures="0" errors="0"><testcase name="t"/></testsuite>')[0], 0)


if __name__ == "__main__":
    unittest.main()
