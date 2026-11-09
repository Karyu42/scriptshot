#!/usr/bin/env python3
"""GUT counts from a tools/run_tests.sh log, and the "native backend actually ran" gate.

    python3 tools/ci/gut_counts.py reports/gut.log [--expect-native] [--json OUT] [--summary FILE] [--label OS]

run_tests.sh runs the default suite as two GUT processes ("run_tests.sh: Lua host guards", then "run_tests.sh:
unit + bullet hooks"). Each prints a totals block (Scripts / Tests / Passing Tests / [Failing Tests] /
[Risky/Pending] / Asserts / Time). This reads the last block of each process and prints tests, passing, failing
and pending per process and in total.

--expect-native: exit 1 unless every process printed its totals, nothing failed, and Risky/Pending is 0. The
native-only GUT tests (test_native_backend, test_native_reflection, test_native_parity, the native half of
test_batch_hook) are pending when NativeBulletSim is not registered, so pending > 0 means the library did not load.
Linux reference: built 10 host + 1088 unit, 0 pending; unbuilt 10 + 1014 passing, 74 pending.
"""
import argparse
import json
import re
import sys

ANSI = re.compile(r"\x1b\[[0-9;]*m")
SECTION = re.compile(r"^run_tests\.sh: (Lua host guards|unit \+ bullet hooks)\s*$")
FIELDS = {
    "Scripts": "scripts",
    "Tests": "tests",
    "Passing Tests": "passing",
    "Failing Tests": "failing",
    "Risky/Pending": "pending",
    "Asserts": "asserts",
}
LINE = re.compile(r"^(Scripts|Tests|Passing Tests|Failing Tests|Risky/Pending|Asserts|Time)\s+([0-9.]+)s?\s*$")


def parse(text):
    """{section: {tests, passing, failing, pending, asserts, scripts, time_s}} (last totals block per section)."""
    sections = {}
    name = "suite"
    block = None
    for raw in text.splitlines():
        line = ANSI.sub("", raw).rstrip("\r")
        m = SECTION.match(line)
        if m:
            name = m.group(1)
            block = None
            continue
        m = LINE.match(line.strip())
        if not m:
            continue
        key, val = m.groups()
        if key == "Scripts":
            # A new totals block starts. Absent Failing/Pending lines mean 0.
            block = {"scripts": 0, "tests": 0, "passing": 0, "failing": 0, "pending": 0, "asserts": 0, "time_s": 0.0}
            sections[name] = block
        if block is None:
            continue
        if key == "Time":
            block["time_s"] = float(val)
        else:
            block[FIELDS[key]] = int(float(val))
    return sections


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("--expect-native", action="store_true", help="fail unless pending == 0 and nothing failed")
    ap.add_argument("--expect-sections", type=int, default=2, help="GUT processes expected (default 2)")
    ap.add_argument("--json", help="write the counts as JSON here")
    ap.add_argument("--summary", help="append a markdown table here (e.g. $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--label", default="", help="shown in the summary heading (e.g. the OS)")
    a = ap.parse_args(argv)
    with open(a.log, encoding="utf-8", errors="replace") as f:
        sections = parse(f.read())
    total = {k: sum(s[k] for s in sections.values()) for k in ("tests", "passing", "failing", "pending")}
    for name, s in sections.items():
        print(f"gut_counts: {name}: tests {s['tests']}, passing {s['passing']}, failing {s['failing']}, "
              f"pending {s['pending']} ({s['time_s']:.1f} s)")
    print(f"gut_counts: total: tests {total['tests']}, passing {total['passing']}, failing {total['failing']}, "
          f"pending {total['pending']}")
    problems = []
    if len(sections) < a.expect_sections:
        problems.append(f"found {len(sections)} GUT totals block(s), expected {a.expect_sections}")
    if a.expect_native:
        if total["failing"]:
            problems.append(f"{total['failing']} failing test(s)")
        if total["pending"]:
            problems.append(f"{total['pending']} pending test(s): the native library did not load "
                            "(the native GUT tests are pending without NativeBulletSim)")
        if total["tests"] and total["passing"] != total["tests"]:
            problems.append(f"passing {total['passing']} != tests {total['tests']}")
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"sections": sections, "total": total, "problems": problems}, f, indent=2)
    if a.summary:
        with open(a.summary, "a", encoding="utf-8") as f:
            f.write(f"### GUT counts{' (' + a.label + ')' if a.label else ''}\n\n")
            f.write("| process | tests | passing | failing | pending | time |\n|---|---:|---:|---:|---:|---:|\n")
            for name, s in sections.items():
                f.write(f"| {name} | {s['tests']} | {s['passing']} | {s['failing']} | {s['pending']} | "
                        f"{s['time_s']:.1f} s |\n")
            f.write(f"| **total** | {total['tests']} | {total['passing']} | {total['failing']} | "
                    f"{total['pending']} | |\n\n")
            for p in problems:
                f.write(f"- :x: {p}\n")
    for p in problems:
        print(f"::error::gut_counts: {p}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
