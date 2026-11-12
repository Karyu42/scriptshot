#!/usr/bin/env python3
"""Headless-Chromium runner for the Web (playtest) export.

Usage:
  playtest_web.py <export_dir> <artifact_dir> [--timeout S]

Serves the export over plain HTTP, opens it in headless Chromium, and waits
for PLAYTEST_DONE ok. Fails on PLAYTEST_DONE fail, PLAYTEST_FAIL, a page
error, an unexpected console error, or a timeout.
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

# Reuse the web smoke server, allowlist, and console classifier.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import web_smoke as smoke  # noqa: E402


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    export_dir, outdir = Path(argv[0]).resolve(), Path(argv[1]).resolve()
    timeout = 240.0
    rest = argv[2:]
    while rest:
        flag = rest.pop(0)
        if flag == "--timeout":
            timeout = float(rest.pop(0))
        else:
            print(f"unknown option {flag}")
            return 2
    outdir.mkdir(parents=True, exist_ok=True)
    from playwright.sync_api import sync_playwright

    srv, port = smoke.serve(export_dir)
    url = f"http://127.0.0.1:{port}/index.html"
    try:
        with sync_playwright() as pw:
            result = run(pw, os.environ.get("CHROME_PATH") or None, url, outdir, timeout)
    finally:
        srv.shutdown()
    status = "PASS" if result["ok"] else "FAIL"
    print(f"[{status}] playtest: engine started {result.get('engine_started_s')}s, "
          f"done {result.get('done_s')}s")
    for m in result.get("markers", []):
        print(f"    {m}")
    for p in result.get("problems", []):
        print(f"    problem: {p}")
    return 0 if result["ok"] else 1


def run(pw, chrome, url: str, outdir: Path, timeout: float) -> dict:
    result: dict = {"ok": False, "markers": [], "problems": []}
    console: list[tuple[str, str]] = []
    page_errors: list[str] = []
    launch: dict = {"headless": True, "args": [
        "--no-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader",
        "--ignore-gpu-blocklist",
    ]}
    if chrome:
        launch["executable_path"] = chrome
    browser = pw.chromium.launch(**launch)
    try:
        page = browser.new_page(viewport={"width": 1280, "height": 720})
        page.on("console", lambda m: console.append((m.type, m.text)))
        page.on("pageerror", lambda e: page_errors.append(str(e)))
        t0 = time.monotonic()
        page.goto(url)
        started = None
        done = None
        while time.monotonic() - t0 < timeout:
            if started is None and page.evaluate(
                    "(() => { const s = document.getElementById('status'); return !s || getComputedStyle(s).display === 'none'; })()"):
                started = time.monotonic() - t0
            texts = [t for _k, t in console]
            if page_errors:
                break
            if any(t.startswith("PLAYTEST_DONE") for t in texts):
                done = time.monotonic() - t0
                break
            page.wait_for_timeout(250)
        result["engine_started_s"] = None if started is None else round(started, 2)
        result["done_s"] = None if done is None else round(done, 2)
        page.screenshot(path=str(outdir / "web.png"))
    finally:
        browser.close()
    (outdir / "web.console.log").write_text("".join(f"[{k}] {t}\n" for k, t in console))
    texts = [t for _k, t in console]
    markers = [t for t in texts if t.startswith("PLAYTEST_")]
    result["markers"] = markers
    errors, _fallback = smoke.classify(console)
    errors = [e for e in errors if "PagedAllocator" not in e and "Pages in use exist at exit" not in e]
    problems: list[str] = []
    if page_errors:
        problems.append(f"page errors: {page_errors}")
    if started is None:
        problems.append(f"engine did not start within {timeout}s")
    if done is None:
        problems.append(f"PLAYTEST_DONE was not printed within {timeout}s")
    if any(t.startswith("PLAYTEST_FAIL") for t in texts) or any(t == "PLAYTEST_DONE fail" for t in texts):
        problems.append("playtest reported failure (see PLAYTEST_FAIL / PLAYTEST_DONE fail)")
    if not any(t == "PLAYTEST_DONE ok" for t in texts):
        problems.append("missing PLAYTEST_DONE ok")
    if errors:
        problems.append(f"{len(errors)} unexpected console error(s): {errors[:5]}")
    result["problems"] = problems
    result["ok"] = not problems
    return result


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
