"""Fixture tests for cold_import.sh: one retry, only when Godot died on a signal (rc >= 128).

The fake godot is a shell script; its log lines are FABRICATED test data.
"""
import os
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "cold_import.sh")

# Behaviour per call, read from a counter file: "abort" = SIGABRT (exit 134), "segv" = SIGSEGV (139),
# "fail" = plain exit 1, "ok" = exit 0.
FAKE = """#!/usr/bin/env bash
n=$(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/calls"
plan=($FAKE_PLAN); what="${plan[$((n - 1))]:-ok}"
echo "Godot Engine v4.7.2.stable.official (fake call $n)"
echo "[  47% ] reimport | source_code_pro.fnt"
case "$what" in
  abort) echo "double free or corruption (!prev)"; kill -ABRT $$ ;;
  segv) echo "handle_crash: Program crashed with signal 11"; echo "[1] godot() [0x1c7ae9f]"; kill -SEGV $$ ;;
  fail) echo "ERROR: Failed loading resource"; exit 1 ;;
  *) echo "[ DONE ] reimport"; exit 0 ;;
esac
"""


def run(plan):
    with tempfile.TemporaryDirectory() as d:
        fake = os.path.join(d, "godot")
        with open(fake, "w") as f:
            f.write(FAKE)
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
        logs = os.path.join(d, "logs")
        env = dict(os.environ, GODOT=fake, FAKE_DIR=d, FAKE_PLAN=plan)
        p = subprocess.run(["bash", SCRIPT, d, "head", logs], env=env, capture_output=True, text=True)
        calls = 0
        if os.path.exists(os.path.join(d, "calls")):
            with open(os.path.join(d, "calls")) as f:
                calls = int(f.read())
        files = sorted(os.listdir(logs)) if os.path.isdir(logs) else []
        crashed = ""
        if "import-head-1-crashed.log" in files:
            with open(os.path.join(logs, "import-head-1-crashed.log")) as f:
                crashed = f.read()
        return p.returncode, p.stdout, calls, files, crashed


class ColdImportTest(unittest.TestCase):
    def test_ok_first_time_runs_once(self):
        code, out, calls, files, _ = run("ok")
        self.assertEqual((code, calls), (0, 1))
        self.assertIn("import ok (attempt 1)", out)
        self.assertNotIn("::warning", out)

    def test_signal_abort_retries_once_with_warning_excerpt_and_full_log(self):
        code, out, calls, files, crashed = run("abort ok")
        self.assertEqual((code, calls), (0, 2))
        self.assertIn("::warning title=head cold import crashed (retrying once)::", out)
        self.assertIn("signal 6 (exit 134)", out)
        self.assertIn("double free or corruption (!prev)", out.split("::warning")[1])
        self.assertEqual(out.count("::warning"), 1)
        self.assertNotIn("\n", out.split("::warning")[1].split("cold_import.sh:")[0].strip())  # one annotation line
        self.assertIn("import-head-1-crashed.log", files)
        self.assertIn("double free or corruption (!prev)", crashed)
        self.assertIn("import ok (attempt 2)", out)

    def test_segv_backtrace_lines_are_in_the_excerpt(self):
        code, out, calls, _, _ = run("segv ok")
        self.assertEqual((code, calls), (0, 2))
        self.assertIn("handle_crash: Program crashed with signal 11", out)
        self.assertIn("[1] godot() [0x1c7ae9f]", out)

    def test_plain_nonzero_exit_fails_at_once_without_retry(self):
        code, out, calls, files, _ = run("fail ok")
        self.assertEqual((code, calls), (1, 1))
        self.assertIn("::error title=head cold import failed::", out)
        self.assertIn("exited 1 (not a signal)", out)
        self.assertNotIn("::warning", out)
        self.assertNotIn("import-head-1-crashed.log", files)

    def test_only_one_retry(self):
        code, out, calls, _, _ = run("abort abort ok")
        self.assertEqual((code, calls), (1, 2))
        self.assertIn("::error title=head cold import crashed twice::", out)

    def test_signal_then_real_error_fails(self):
        code, out, calls, _, _ = run("abort fail")
        self.assertEqual((code, calls), (1, 2))
        self.assertIn("exited 1 (not a signal)", out)


if __name__ == "__main__":
    unittest.main()
