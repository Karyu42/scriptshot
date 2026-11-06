#!/usr/bin/env python3
"""Gate SPIKE_RESULT / SPIKE_DONE lines from the Lua export bench (Android emulator smoke).

Expects the format printed by docs/scripting/spike/bench/export_bench.gd and documented in
docs/scripting/testing.md section 2.4:

  SPIKE_RESULT {json}
  ...
  SPIKE_DONE

Loose CI gates (emulator without host GPU is slower than Linux reference):
  * exactly four SPIKE_RESULT lines before SPIKE_DONE
  * each result has os=Android and arch=x86_64 (emulator ABI)
  * modes present: C, A, B, B+hook
  * alive >= 990 for modes A, B, B+hook
  * lua_ms_p95 <= 10 for mode B
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

RESULT_RE = re.compile(r"SPIKE_RESULT\s+(\{.*\})")
DONE_RE = re.compile(r"\bSPIKE_DONE\b")
INFO_RE = re.compile(r"\bSPIKE_INFO\b")
ERROR_RE = re.compile(r"\bSPIKE_ERROR\b|SCRIPT ERROR")

EXPECTED_MODES = ("C", "A", "B", "B+hook")
ALIVE_MIN_HOOKED = 990
LUA_P95_MAX_B = 10.0


def parse_log(text: str) -> tuple[list[dict[str, Any]], bool, list[str]]:
    """Return (results, saw_done, errors). Stops collecting results after SPIKE_DONE."""
    results: list[dict[str, Any]] = []
    errors: list[str] = []
    saw_done = False
    for line in text.splitlines():
        if ERROR_RE.search(line) and "SPIKE_RESULT" not in line:
            # Keep going so we still report missing DONE, but record the error.
            errors.append(line.strip())
        if saw_done:
            continue
        if DONE_RE.search(line):
            saw_done = True
            continue
        m = RESULT_RE.search(line)
        if not m:
            continue
        try:
            results.append(json.loads(m.group(1)))
        except json.JSONDecodeError as exc:
            errors.append(f"bad SPIKE_RESULT JSON: {exc}: {m.group(1)[:120]}")
    return results, saw_done, errors


def check(results: list[dict[str, Any]], saw_done: bool, errors: list[str]) -> list[str]:
    fails: list[str] = []
    fails.extend(f"log error: {e}" for e in errors)
    if not saw_done:
        fails.append("SPIKE_DONE missing (timeout or crash before the bench finished)")
    if len(results) != 4:
        fails.append(f"expected exactly 4 SPIKE_RESULT lines before SPIKE_DONE, got {len(results)}")
    modes = [str(r.get("mode", "")) for r in results]
    if tuple(modes) != EXPECTED_MODES:
        fails.append(f"expected modes {list(EXPECTED_MODES)}, got {modes}")
    for r in results:
        os_name = r.get("os")
        arch = r.get("arch")
        mode = r.get("mode")
        if os_name != "Android":
            fails.append(f"mode={mode}: os={os_name!r} (want Android)")
        if arch != "x86_64":
            fails.append(f"mode={mode}: arch={arch!r} (want x86_64 on the GH emulator)")
        alive = r.get("alive")
        if mode in ("A", "B", "B+hook"):
            if not isinstance(alive, (int, float)) or alive < ALIVE_MIN_HOOKED:
                fails.append(f"mode={mode}: alive={alive!r} (want >= {ALIVE_MIN_HOOKED})")
        if mode == "B":
            p95 = r.get("lua_ms_p95")
            if not isinstance(p95, (int, float)) or p95 > LUA_P95_MAX_B:
                fails.append(f"mode=B: lua_ms_p95={p95!r} (want <= {LUA_P95_MAX_B})")
    return fails


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("log", nargs="?", help="path to logcat/tee file (default: stdin)")
    args = p.parse_args(argv)
    text = sys.stdin.read() if not args.log else open(args.log, encoding="utf-8", errors="replace").read()
    results, saw_done, errors = parse_log(text)
    fails = check(results, saw_done, errors)
    for r in results:
        print(
            f"SPIKE_RESULT mode={r.get('mode')} alive={r.get('alive')} "
            f"fps={r.get('fps')} lua_ms_p95={r.get('lua_ms_p95')} "
            f"frame_ms_p95={r.get('frame_ms_p95')} arch={r.get('arch')} os={r.get('os')}"
        )
    if fails:
        for f in fails:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    if not INFO_RE.search(text):
        print("WARN: no SPIKE_INFO line (extension may have failed to announce itself)", file=sys.stderr)
    print("OK: SPIKE_DONE with 4 gated SPIKE_RESULT lines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
