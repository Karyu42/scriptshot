#!/usr/bin/env python3
"""Unit tests for tools/ci/check_spike_result.py (no emulator required)."""
from __future__ import annotations

import unittest

from check_spike_result import check, parse_log

GOOD = """\
SPIKE_INFO godot=4.7.2-stable (official) os=Android web=false threads=true mobile=true renderer=SwiftShader cpu=
SPIKE_INFO lua runtime=lua version=Lua 5.4
SPIKE_RESULT {"alive":1000,"arch":"x86_64","fps":30.0,"frame_ms_med":33.0,"frame_ms_p95":40.0,"godot":"4.7.2-stable (official)","hooked":0,"lua":"Lua 5.4","lua_mem_kb":80,"lua_ms_med":0.01,"lua_ms_p95":0.02,"mode":"C","n":1000,"os":"Android","step_ms_med":1.0,"step_ms_p95":1.5}
SPIKE_RESULT {"alive":999,"arch":"x86_64","fps":28.0,"frame_ms_med":35.0,"frame_ms_p95":42.0,"godot":"4.7.2-stable (official)","hooked":999,"lua":"Lua 5.4","lua_mem_kb":80,"lua_ms_med":3.0,"lua_ms_p95":4.0,"mode":"A","n":1000,"os":"Android","step_ms_med":4.0,"step_ms_p95":5.0}
SPIKE_RESULT {"alive":999,"arch":"x86_64","fps":29.0,"frame_ms_med":34.0,"frame_ms_p95":41.0,"godot":"4.7.2-stable (official)","hooked":999,"lua":"Lua 5.4","lua_mem_kb":200,"lua_ms_med":1.5,"lua_ms_p95":2.5,"mode":"B","n":1000,"os":"Android","step_ms_med":2.5,"step_ms_p95":3.5}
SPIKE_RESULT {"alive":999,"arch":"x86_64","fps":28.0,"frame_ms_med":35.0,"frame_ms_p95":43.0,"godot":"4.7.2-stable (official)","hooked":999,"lua":"Lua 5.4","lua_mem_kb":700,"lua_ms_med":2.0,"lua_ms_p95":3.0,"mode":"B+hook","n":1000,"os":"Android","step_ms_med":3.0,"step_ms_p95":4.0}
SPIKE_DONE
"""


class TestCheckSpikeResult(unittest.TestCase):
    def test_good_log_passes(self) -> None:
        results, done, errors = parse_log(GOOD)
        self.assertTrue(done)
        self.assertEqual(errors, [])
        self.assertEqual(check(results, done, errors), [])

    def test_missing_done_fails(self) -> None:
        results, done, errors = parse_log(GOOD.replace("SPIKE_DONE", ""))
        fails = check(results, done, errors)
        self.assertTrue(any("SPIKE_DONE missing" in f for f in fails))

    def test_wrong_arch_fails(self) -> None:
        bad = GOOD.replace('"arch":"x86_64"', '"arch":"arm64"')
        results, done, errors = parse_log(bad)
        fails = check(results, done, errors)
        self.assertTrue(any("arch=" in f for f in fails))

    def test_low_alive_fails(self) -> None:
        bad = GOOD.replace('"mode":"A","n":1000,"os":"Android"', '"mode":"A","n":1000,"os":"Android"').replace(
            '{"alive":999,"arch":"x86_64","fps":28.0,"frame_ms_med":35.0,"frame_ms_p95":42.0,"godot":"4.7.2-stable (official)","hooked":999,"lua":"Lua 5.4","lua_mem_kb":80,"lua_ms_med":3.0,"lua_ms_p95":4.0,"mode":"A"',
            '{"alive":100,"arch":"x86_64","fps":28.0,"frame_ms_med":35.0,"frame_ms_p95":42.0,"godot":"4.7.2-stable (official)","hooked":100,"lua":"Lua 5.4","lua_mem_kb":80,"lua_ms_med":3.0,"lua_ms_p95":4.0,"mode":"A"',
            1,
        )
        results, done, errors = parse_log(bad)
        fails = check(results, done, errors)
        self.assertTrue(any("mode=A: alive=" in f for f in fails))

    def test_lua_p95_gate_on_b(self) -> None:
        bad = GOOD.replace(
            '"lua_ms_med":1.5,"lua_ms_p95":2.5,"mode":"B"',
            '"lua_ms_med":1.5,"lua_ms_p95":25.0,"mode":"B"',
            1,
        )
        results, done, errors = parse_log(bad)
        fails = check(results, done, errors)
        self.assertTrue(any("lua_ms_p95=" in f for f in fails))

    def test_wrong_mode_count(self) -> None:
        truncated = "\n".join(GOOD.splitlines()[:5]) + "\nSPIKE_DONE\n"
        results, done, errors = parse_log(truncated)
        fails = check(results, done, errors)
        self.assertTrue(any("exactly 4" in f for f in fails))


if __name__ == "__main__":
    unittest.main()
