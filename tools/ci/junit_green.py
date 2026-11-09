#!/usr/bin/env python3
"""Is a GUT junit XML file a green result?   python3 tools/ci/junit_green.py PATH

Exit 0 (green) only if PATH exists, is non-empty, parses as XML, its root is <testsuites> or <testsuite>, every
failures= / errors= attribute on the root and on each <testsuite> is a non-negative integer, their sum is 0, and there
is no <failure> or <error> element. Anything else exits 1 (red) with the reason on stdout. A missing attribute
counts as 0 (GUT 9.x writes failures= but no errors=). Used by tools/run_tests.sh before it accepts a killed
(teardown hang, #41) or exit-134 (lua-gdextension shutdown abort) godot as a pass.
"""
import os
import sys
import xml.etree.ElementTree as ET


def verdict(path):
    """(green: bool, reason: str)."""
    try:
        if os.path.getsize(path) == 0:
            return False, f"junit file {path} is empty"
        root = ET.parse(path).getroot()
    except FileNotFoundError:
        return False, f"junit file {path} was not written"
    except (OSError, ET.ParseError) as e:
        return False, f"junit file {path} is unreadable or malformed: {e}"
    if root.tag not in ("testsuites", "testsuite"):
        return False, f"junit file {path} has root <{root.tag}>, expected <testsuites> or <testsuite>"
    suites = [root] + [el for el in root.iter("testsuite") if el is not root]
    total = 0
    for el in suites:
        for attr in ("failures", "errors"):
            raw = el.get(attr, "0")
            try:
                v = int(raw)
            except ValueError:
                return False, f"junit <{el.tag} name={el.get('name')!r}> has {attr}={raw!r}, not an integer"
            if v < 0:
                return False, f"junit <{el.tag} name={el.get('name')!r}> has {attr}={v}"
            total += v
    elements = sum(1 for _ in root.iter("failure")) + sum(1 for _ in root.iter("error"))
    if total or elements:
        return False, f"junit file {path} reports failures/errors (attributes sum {total}, elements {elements})"
    return True, f"junit file {path}: 0 failures, 0 errors"


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: junit_green.py PATH", file=sys.stderr)
        return 2
    ok, reason = verdict(argv[0])
    print(f"junit_green.py: {reason}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
