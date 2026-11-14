#!/usr/bin/env python3
"""Fake-godot tests for tools/run_tests.sh: the exit-after-results guard (#41), the exit-134 / Windows abort path and
the junit gate (#42), and the import-log Lua check (a res:// Lua chunk lua-gdextension ran at scan and that raised),
under whatever bash runs the script.

    python3 -m unittest tools/ci/test_run_tests_guard.py -v
    RUN_TESTS_BASH=/bin/bash python3 -m unittest tools/ci/test_run_tests_guard.py -v   # macOS: bash 3.2

Each case copies run_tests.sh and junit_green.py into a scratch project (fetch_native_libs.sh is stubbed, so no
network), points $GODOT at a shell script that prints a GUT-like summary, optionally writes the junit file GUT would
write, and then exits with a code, hangs, or prints results within its first second. GUT_EXIT_GRACE_S is 1.
RUN_TESTS_BASH picks the interpreter (default: `bash` on PATH; on Windows pass Git Bash's full path, because a
bare `bash` from Python can resolve to WSL's System32 bash.exe).
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASH = os.environ.get("RUN_TESTS_BASH", "bash")
IS_WINDOWS = os.name == "nt"

# A POSIX-sh fake of `godot`. --import reads:
#   FAKE_IMPORT      clean | lua_error (lua-gdextension ran a res://*.lua chunk at scan and it raised)
#   FAKE_IMPORT_END  its exit code (default 0; 139 is the segfault-at-exit some boxes show)
# A test run reads FAKE_* from the environment:
#   FAKE_BANNER  green | pending | red | crash | none
#   FAKE_JUNIT   green | red | errors | malformed | empty | none
#   FAKE_END     exit:<code> | hang
#   FAKE_EARLY   1 = print the results immediately (inside the guard's first second)
#   FAKE_GUT_LUA 1 = the run itself prints a Lua error naming a res:// chunk (tests do this on purpose)
FAKE_GODOT = r"""#!/bin/sh
for a in "$@"; do
  if [ "$a" = "--import" ]; then
    echo "fake import"
    if [ "${FAKE_IMPORT:-clean}" = lua_error ]; then
      echo 'ERROR: [string "res://scripting/starters/spiral.lua"]:3: attempt to index a nil value (global '"'"'state'"'"')'
      echo '   at: _reload (src/script-language/LuaScript.cpp:152)'
    fi
    exit "${FAKE_IMPORT_END:-0}"
  fi
done
junit=""
for a in "$@"; do
  case "$a" in
    -gjunit_xml_file=*) junit="${a#-gjunit_xml_file=}" ;;
  esac
done
case "$junit" in
  res://*) junit="$PWD/${junit#res://}" ;;
esac
[ "${FAKE_EARLY:-0}" = 1 ] || sleep 1
echo "fake gut: $*"
[ "${FAKE_GUT_LUA:-0}" = 1 ] && echo 'ERROR: [string "res://tests/x.lua"]:1: boom'
case "${FAKE_BANNER:-green}" in
  green)   printf 'Tests 3\nPassing Tests 3\n---- All tests passed! ----\n' ;;
  pending) printf 'Tests 3\nPassing Tests 2\nRisky/Pending 1\n---- 1 pending/risky tests. ----\n' ;;
  red)     printf 'Tests 3\nPassing Tests 2\nFailing Tests 1\n---- 1 failing tests ----\n' ;;
  crash)   printf 'handle_crash: Program crashed with signal 11\n---- All tests passed! ----\n' ;;
  none)    printf 'still running\n' ;;
esac
if [ -n "$junit" ]; then
  mkdir -p "$(dirname "$junit")"
  case "${FAKE_JUNIT:-green}" in
    green)     printf '<?xml version="1.0"?>\n<testsuites name="GutTests" failures="0" tests="3"><testsuite name="a" failures="0" tests="3"></testsuite></testsuites>\n' >"$junit" ;;
    red)       printf '<?xml version="1.0"?>\n<testsuites name="GutTests" failures="1" tests="3"><testsuite name="a" failures="1" tests="3"><testcase name="t"><failure message="x"/></testcase></testsuite></testsuites>\n' >"$junit" ;;
    errors)    printf '<testsuites failures="0" errors="2" tests="3"></testsuites>\n' >"$junit" ;;
    malformed) printf '<testsuites failures="0"' >"$junit" ;;
    empty)     : >"$junit" ;;
    none)      ;;
  esac
  [ "${FAKE_JUNIT:-green}" = none ] || echo "Results saved to $junit"
fi
end="${FAKE_END:-exit:0}"
case "$end" in
  hang)   exec sleep 300 ;;
  exit:*) exit "${end#exit:}" ;;
esac
"""


def _posix(path):
    return path.replace("\\", "/")


class RunTestsGuard(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="run-tests-guard-")
        os.makedirs(os.path.join(cls.tmp, "tools", "ci"))
        shutil.copy(os.path.join(ROOT, "tools", "run_tests.sh"), os.path.join(cls.tmp, "tools", "run_tests.sh"))
        shutil.copy(os.path.join(ROOT, "tools", "ci", "junit_green.py"), os.path.join(cls.tmp, "tools", "ci"))
        with open(os.path.join(cls.tmp, "tools", "ci", "fetch_native_libs.sh"), "w", newline="\n") as f:
            f.write("#!/bin/sh\nexit 0\n")
        cls.godot = os.path.join(cls.tmp, "fake_godot")
        with open(cls.godot, "w", newline="\n") as f:
            f.write(FAKE_GODOT)
        os.chmod(cls.godot, 0o755)
        out = subprocess.run([BASH, "-c", 'echo "$BASH_VERSION"'], capture_output=True, text=True)
        print(f"\nrun_tests.sh guard tests under {BASH}: bash {out.stdout.strip()}", file=sys.stderr)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_tests(self, *gut_args, timeout=60, **fake):
        env = dict(os.environ)
        env.update({"GODOT": _posix(self.godot), "GUT_EXIT_GRACE_S": "1"})
        for k in ("FAKE_BANNER", "FAKE_JUNIT", "FAKE_END", "FAKE_EARLY", "FAKE_IMPORT", "FAKE_IMPORT_END", "FAKE_GUT_LUA"):
            env.pop(k, None)
        env.update({"FAKE_" + k.rstrip("_").upper(): str(v) for k, v in fake.items()})
        args = list(gut_args) or ["-gselect=fake"]
        t0 = time.monotonic()
        # Output goes to a file, not a pipe: a hung fake (and its sleep) would keep a pipe open after a timeout.
        with tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace") as out:
            kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if IS_WINDOWS else {"start_new_session": True}
            p = subprocess.Popen([BASH, _posix(os.path.join(self.tmp, "tools", "run_tests.sh")), *args],
                                 cwd=self.tmp, env=env, stdout=out, stderr=subprocess.STDOUT, **kw)
            try:
                rc = p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                self._kill_tree(p)
                raise
            finally:
                self.last_elapsed = time.monotonic() - t0
            out.seek(0)
            return rc, out.read()

    @staticmethod
    def _kill_tree(p):
        if IS_WINDOWS:
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(p.pid)], capture_output=True)
            # Git Bash children (the fake's sleep) are not always in the Windows job tree.
            subprocess.run([BASH, "-c", "pkill -f 'sleep 300' || true"], capture_output=True)
        else:
            import signal
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        p.wait()

    def assertPass(self, **fake):
        rc, out = self.run_tests(**fake)
        self.assertEqual(rc, 0, out)
        return out

    def assertFail(self, **fake):
        rc, out = self.run_tests(**fake)
        self.assertNotEqual(rc, 0, out)
        return out

    # --- normal exits -------------------------------------------------------------------------------------------
    def test_green_exit0_passes_and_streams_output(self):
        out = self.assertPass()
        self.assertIn("All tests passed", out)
        self.assertIn("Results saved to", out)

    def test_pending_banner_is_green(self):
        self.assertPass(banner="pending")

    def test_red_banner_exit1_fails(self):
        self.assertFail(banner="red", junit="red", end="exit:1")

    def test_split_suite_runs_two_processes(self):
        rc, out = self.run_tests("-ginclude_subdirs")
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.count("fake gut:"), 2, out)

    # --- lua-gdextension shutdown abort (134 on POSIX) -----------------------------------------------------------
    def test_abort134_green_junit_passes(self):
        out = self.assertPass(end="exit:134")
        self.assertIn("while releasing Lua", out)

    def test_abort134_without_junit_fails(self):
        self.assertFail(end="exit:134", junit="none")

    def test_abort134_red_junit_fails(self):
        self.assertFail(end="exit:134", junit="red")

    def test_abort134_junit_errors_fails(self):
        self.assertFail(end="exit:134", junit="errors")

    def test_abort134_crash_marker_fails(self):
        self.assertFail(end="exit:134", banner="crash")

    def test_other_nonzero_exit_with_green_junit_fails(self):
        self.assertFail(end="exit:7")

    # --- exit-after-results guard (#41) ----------------------------------------------------------------------------
    def test_hang_after_green_results_is_killed_and_passes(self):
        out = self.assertPass(end="hang")
        self.assertIn("teardown hang", out)
        self.assertLess(self.last_elapsed, 30)

    def test_hang_with_results_in_first_second_still_arms(self):
        out = self.assertPass(end="hang", early=1)
        self.assertIn("teardown hang", out)

    def test_hang_without_junit_fails(self):
        self.assertFail(end="hang", junit="none")

    def test_hang_with_malformed_junit_fails(self):
        self.assertFail(end="hang", junit="malformed")

    def test_hang_with_empty_junit_fails(self):
        self.assertFail(end="hang", junit="empty")

    def test_hang_with_red_banner_fails(self):
        self.assertFail(end="hang", banner="red")

    def test_hang_before_results_is_not_killed_by_the_guard(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_tests(end="hang", banner="none", junit="none", timeout=6)

    # Import-log Lua check: a res:// Lua chunk the binding ran at scan and that raised fails the run, judged by
    # the log's content, not godot's exit code.
    LUA_IMPORT_MSG = "godot --import ran a res:// Lua file and it raised"

    def test_lua_error_at_import_fails(self):
        rc, out = self.run_tests(import_="lua_error")
        self.assertNotEqual(rc, 0, out)
        self.assertIn(self.LUA_IMPORT_MSG, out)
        self.assertIn("spiral.lua\"]:3", out)

    def test_lua_error_at_import_is_reported_after_exit_139(self):
        rc, out = self.run_tests(import_="lua_error", import_end=139)
        self.assertNotEqual(rc, 0, out)
        self.assertIn(self.LUA_IMPORT_MSG, out)

    def test_clean_import_exit_139_is_not_reported_as_a_lua_error(self):
        rc, out = self.run_tests(import_end=139)
        self.assertIn("godot --import exited with status 139", out)
        self.assertNotIn(self.LUA_IMPORT_MSG, out)

    def test_lua_error_in_the_test_run_is_not_an_import_error(self):
        out = self.assertPass(gut_lua=1)
        self.assertNotIn(self.LUA_IMPORT_MSG, out)

    def test_res_junit_path_is_used(self):
        rc, out = self.run_tests("-gselect=fake", "-gjunit_xml_file=res://reports/j.xml", end="exit:134")
        self.assertEqual(rc, 0, out)
        self.assertTrue(os.path.exists(os.path.join(self.tmp, "reports", "j.xml")))


if __name__ == "__main__":
    unittest.main()
