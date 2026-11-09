#!/usr/bin/env python3
"""Headless-browser smoke test for the Web export (issues #40, #36).

Usage:
  web_smoke.py check-export <export_dir> [--smoke]
  web_smoke.py run <export_dir> <artifact_dir> [--timeout S] [--scenarios boot,lua,native]

check-export inspects the exported files without a browser:
  * GODOT_CONFIG.gdextensionLibs lists lua-gdextension's no-threads side module
    and nothing from scriptshot_native,
  * no libscriptshot_native* file sits next to index.html,
  * index.pck holds no scriptshot_native.gdextension, no bin/ file, and its
    .godot/extension_list.cfg lists only exported extensions,
  * index.side.wasm is present (the dlink template was used),
  * shipping export (default): no src/qa/ file in the pck, no WebSmoke
    autoload and no `web_smoke` custom feature in project.binary;
    --smoke ("Web (smoke)" preset): the smoke scene, script and Lua shot are in
    the pck and project.binary carries the `web_smoke` feature.

run serves <export_dir> over plain HTTP (no COOP/COEP: the no-threads template
does not need cross-origin isolation), opens it in headless Chromium with
Playwright and runs the named scenarios:
  boot    meant for the shipping export: the engine starts and the main scene
          runs for 6 s with no console error. Fails if that window does not
          complete before the timeout.
  lua     meant for the "Web (smoke)" export, whose main scene is
          src/qa/web_smoke.tscn (feature override). Needs SMOKE_DONE ok,
          SMOKE_LUA_OK with backend=gdscript, and exactly
          SMOKE_BACKEND backend=gdscript ... fallback_warnings=0.
  native  the smoke export with GODOT_CONFIG.args = ["--", "--bullet-backend=native"]:
          exactly one fallback warning, bullets still spawn on gdscript.
Every scenario fails on a page error, a console error that is not allowlisted,
or any request for a scriptshot_native wasm. Each scenario writes
<scenario>.png, <scenario>.console.log and <scenario>.requests.log; summary-<scenarios>.json
holds the timings (summary-<scenarios>.json). Exit code is non-zero on any failure.

Chromium: CHROME_PATH if set, else Playwright's bundled Chromium
(`python -m playwright install chromium`).
"""
from __future__ import annotations

import functools
import http.server
import json
import os
import re
import socketserver
import struct
import sys
import threading
import time
from pathlib import Path

SMOKE_FILES = ("src/qa/web_smoke.tscn", "src/qa/web_smoke.gd", "src/qa/web_smoke_shot.lua")
SMOKE_FEATURE = b"web_smoke"
NATIVE_MARK = "scriptshot_native"
LUA_LIB = re.compile(r"^libluagdextension\.web\.template_(debug|release)\.wasm32\.nothreads\.wasm$")
FALLBACK = "BulletManager: native bullets were requested but NativeBulletSim is not available"
# Console lines Godot reports through console.error that are known to be benign.
# Each entry is a regex on the first line of the message; the indented "at:"
# and GDScript backtrace lines that follow an allowed message are allowed with it.
ALLOWLIST = [
    # lua-gdextension 0.8.2 reads an optional project setting it never registers
    # (same warning on desktop).
    re.compile(r"^WARNING: Property not found: 'lua_gdextension/lua_script_language/script_import_map'\.$"),
]
SCENARIOS = {
    "boot": {"args": [], "markers": False, "fallback": 0},
    "lua": {"args": [], "markers": True, "fallback": 0},
    "native": {"args": ["--", "--bullet-backend=native"], "markers": True, "fallback": 1},
}
BOOT_SETTLE_S = 6.0


def fail(msg: str) -> None:
    print(f"web_smoke: FAIL: {msg}", flush=True)


# --- export inspection -------------------------------------------------------

def godot_config(html: str) -> dict:
    m = re.search(r"const GODOT_CONFIG = (\{.*?\});", html, re.S)
    if not m:
        raise ValueError("GODOT_CONFIG not found in index.html")
    return json.loads(m.group(1))


def pck_files(path: Path) -> dict[str, bytes]:
    """Path -> bytes for every file in a Godot 4 .pck (format 2-4, unencrypted)."""
    b = path.read_bytes()
    if b[:4] != b"GDPC":
        raise ValueError(f"{path} is not a Godot pck")
    ver, _ma, _mi, _pa, flags = struct.unpack_from("<5I", b, 4)
    if flags & 1:
        raise ValueError("encrypted pck directory is not supported")
    base, dir_off = struct.unpack_from("<QQ", b, 24)
    off = dir_off if ver >= 3 else 24 + 8 + 64
    if ver < 3:
        base = 0
    (n,) = struct.unpack_from("<I", b, off)
    off += 4
    out: dict[str, bytes] = {}
    for _ in range(n):
        (ln,) = struct.unpack_from("<I", b, off)
        off += 4
        name = b[off:off + ln].rstrip(b"\0").decode()
        off += ln
        foff, fsize = struct.unpack_from("<QQ", b, off)
        off += 16 + 16 + 4
        out[name.removeprefix("res://")] = b[base + foff: base + foff + fsize]
    return out


def check_export(export_dir: Path, smoke: bool = False) -> bool:
    ok = True
    html = (export_dir / "index.html").read_text()
    cfg = godot_config(html)
    libs = cfg.get("gdextensionLibs", [])
    print(f"gdextensionLibs = {json.dumps(libs)}")
    if not any(LUA_LIB.match(x) for x in libs):
        fail("lua-gdextension no-threads side module is not in gdextensionLibs"); ok = False
    if any(NATIVE_MARK in x for x in libs):
        fail("the native bullet wasm is in gdextensionLibs"); ok = False
    if len(libs) != 1:
        fail(f"expected exactly one GDExtension library, got {len(libs)}"); ok = False
    files = sorted(p.name for p in export_dir.iterdir() if p.is_file())
    total = sum((export_dir / f).stat().st_size for f in files)
    print("files:")
    for f in files:
        print(f"  {(export_dir / f).stat().st_size:>10}  {f}")
    print(f"total {total} B ({total / 1048576:.2f} MiB)")
    if "index.side.wasm" not in files:
        fail("index.side.wasm missing: the export did not use the dlink template"); ok = False
    for lib in libs:
        if lib not in files:
            fail(f"{lib} is listed but not exported"); ok = False
    if any(NATIVE_MARK in f for f in files):
        fail("a scriptshot_native file was exported"); ok = False
    pck = pck_files(export_dir / "index.pck")
    bad = [p for p in pck if p == "scriptshot_native.gdextension" or p.startswith("bin/")]
    if bad:
        fail(f"pck contains native-lib entries: {bad}"); ok = False
    ext_list = pck.get(".godot/extension_list.cfg", b"").decode().split()
    print(f"pck .godot/extension_list.cfg = {ext_list}")
    if any(NATIVE_MARK in x for x in ext_list):
        fail("pck extension_list.cfg still lists scriptshot_native.gdextension"); ok = False
    if "res://addons/lua-gdextension/luagdextension.gdextension" not in ext_list:
        fail("pck extension_list.cfg does not list lua-gdextension"); ok = False
    if "scripting/sandbox.lua" not in pck:
        fail("pck is missing scripting/sandbox.lua"); ok = False
    qa = sorted(p for p in pck if p.startswith("src/qa/"))
    binary = pck.get("project.binary", b"")
    has_feature = b"_custom_features" in binary and SMOKE_FEATURE in binary.split(b"_custom_features", 1)[1][:64]
    print(f"pck src/qa/ entries = {qa}")
    print(f"project.binary: WebSmoke autoload={b'autoload/WebSmoke' in binary}, web_smoke custom feature={has_feature}")
    if b"autoload/WebSmoke" in binary:
        fail("project.binary registers a WebSmoke autoload"); ok = False
    if smoke:
        for need in SMOKE_FILES:
            if need not in pck and need + ".remap" not in pck:
                fail(f"smoke export is missing {need}"); ok = False
        if not has_feature:
            fail("smoke export does not carry the web_smoke custom feature"); ok = False
    else:
        if qa:
            fail(f"shipping export contains QA files: {qa}"); ok = False
        if has_feature:
            fail("shipping export carries the web_smoke custom feature"); ok = False
    print("check-export:", "ok" if ok else "FAILED")
    return ok


# --- browser run -------------------------------------------------------------

class _Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, *_a: object) -> None:
        pass


_Handler.extensions_map.update({
    ".wasm": "application/wasm",
    ".js": "text/javascript",
    ".pck": "application/octet-stream",
    ".html": "text/html",
})


def serve(root: Path) -> tuple[socketserver.TCPServer, int]:
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), functools.partial(_Handler, directory=str(root)))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def classify(console: list[tuple[str, str]]) -> tuple[list[str], int]:
    """Returns (unexpected error lines, fallback warning count)."""
    bad: list[str] = []
    fallback = 0
    prev_allowed = False
    for kind, text in console:
        first = text.split("\n", 1)[0]
        if FALLBACK in first:
            fallback += 1
            prev_allowed = True
            continue
        if kind != "error" and not re.match(r"^(ERROR|SCRIPT ERROR|USER ERROR|WARNING|USER WARNING|SMOKE_FAIL)", first):
            prev_allowed = False
            continue
        # Continuation lines of the previous message: "at:" and, in debug
        # templates, the GDScript backtrace.
        if re.match(r"^\s+(at: |GDScript backtrace|\[\d+\] )", first):
            if not prev_allowed:
                bad.append(text)
            continue
        if any(rx.match(first) for rx in ALLOWLIST):
            prev_allowed = True
            continue
        prev_allowed = False
        bad.append(text)
    return bad, fallback


def window_problems(spec: dict, started_s: float | None, done_s: float | None, timeout: float) -> list[str]:
    """The engine must start, and a marker-less (boot) scenario must also finish
    its BOOT_SETTLE_S window before the timeout."""
    if started_s is None:
        return [f"engine did not start within {timeout:.0f}s (status overlay still shown)"]
    if not spec["markers"] and done_s is None:
        return [f"the main scene did not run for {BOOT_SETTLE_S:.0f}s after the engine started "
                f"(started at {started_s}s, timeout {timeout:.0f}s)"]
    return []


def marker_fields(line: str) -> dict[str, str]:
    """`SMOKE_X a=1 b=two` -> {"a": "1", "b": "two"}."""
    return dict(tok.split("=", 1) for tok in line.split()[1:] if "=" in tok)


def check_markers(markers: list[str], fallback: int) -> list[str]:
    """Exact checks on the smoke scene's marker lines."""
    problems: list[str] = []
    if markers.count("SMOKE_DONE ok") != 1 or any(m.startswith("SMOKE_DONE") and m != "SMOKE_DONE ok" for m in markers):
        problems.append(f"expected exactly one 'SMOKE_DONE ok' (markers: {markers})")
    lua = [marker_fields(m) for m in markers if m.split(" ", 1)[0] == "SMOKE_LUA_OK"]
    if len(lua) != 1 or lua[0].get("backend") != "gdscript" or not lua[0].get("bullets", "").isdigit() \
            or int(lua[0]["bullets"]) <= 0:
        problems.append(f"expected one 'SMOKE_LUA_OK bullets=<n> backend=gdscript' marker, got {lua}")
    backend = [marker_fields(m) for m in markers if m.split(" ", 1)[0] == "SMOKE_BACKEND"]
    if len(backend) != 1 or backend[0].get("backend") != "gdscript" \
            or backend[0].get("fallback_warnings") != str(fallback):
        problems.append(f"expected one 'SMOKE_BACKEND backend=gdscript ... fallback_warnings={fallback}', got {backend}")
    return problems


def run_scenario(pw, chrome: str | None, url: str, name: str, spec: dict, outdir: Path, timeout: float) -> dict:
    result: dict = {"scenario": name, "args": spec["args"], "ok": False}
    console: list[tuple[str, str]] = []
    requests: list[str] = []
    page_errors: list[str] = []
    failed: list[str] = []
    loaded: list[tuple[str, int]] = []
    launch: dict = {"headless": True, "args": [
        "--no-sandbox", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"]}
    if chrome:
        launch["executable_path"] = chrome
    browser = pw.chromium.launch(**launch)
    try:
        page = browser.new_page(viewport={"width": 1280, "height": 720})
        page.on("console", lambda m: console.append((m.type, m.text)))
        page.on("pageerror", lambda e: page_errors.append(str(e)))
        page.on("request", lambda r: requests.append(r.url))
        page.on("requestfailed", lambda r: failed.append(f"{r.url} {r.failure}"))
        page.on("response", lambda r: loaded.append((r.url, r.status)))
        if spec["args"]:
            def patch(route) -> None:
                resp = route.fetch()
                body = resp.text()
                if '"args":[]' not in body:
                    raise RuntimeError('GODOT_CONFIG "args":[] not found in index.html')
                route.fulfill(response=resp, body=body.replace('"args":[]', '"args":' + json.dumps(spec["args"]), 1))
            page.route("**/index.html", patch)
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
            if spec["markers"] and any(t.startswith("SMOKE_DONE") for t in texts):
                done = time.monotonic() - t0
                break
            if not spec["markers"] and started is not None and time.monotonic() - t0 >= started + BOOT_SETTLE_S:
                done = time.monotonic() - t0
                break
            page.wait_for_timeout(250)
        result["engine_started_s"] = None if started is None else round(started, 2)
        result["done_s"] = None if done is None else round(done, 2)
        result["cross_origin_isolated"] = page.evaluate("window.crossOriginIsolated")
        page.screenshot(path=str(outdir / f"{name}.png"))
    finally:
        browser.close()

    (outdir / f"{name}.console.log").write_text("".join(f"[{k}] {t}\n" for k, t in console))
    (outdir / f"{name}.requests.log").write_text("".join(u + "\n" for u in requests))
    texts = [t for _k, t in console]
    markers = [t for t in texts if t.startswith("SMOKE_")]
    result["markers"] = markers
    errors, fallback = classify(console)
    result["fallback_warnings"] = fallback
    result["unexpected_console_errors"] = errors
    names = [u.rsplit("/", 1)[-1].split("?", 1)[0] for u in requests]
    ok_names = {u.rsplit("/", 1)[-1].split("?", 1)[0] for u, st in loaded if 200 <= st < 300}
    result["failed_requests"] = failed
    result["requested"] = sorted(set(names))
    problems: list[str] = []
    if page_errors:
        problems.append(f"page errors: {page_errors}")
    problems.extend(window_problems(spec, result["engine_started_s"], result["done_s"], timeout))
    # Chromium can report ERR_ABORTED for a wasm it then loads from a second
    # fetch; what matters is that every engine file arrived with a 2xx.
    for need in ("index.wasm", "index.side.wasm", "index.pck"):
        if need not in ok_names:
            problems.append(f"{need} was not loaded (failed requests: {failed})")
    if any("ERR_ABORTED" not in f for f in failed):
        problems.append(f"failed requests: {failed}")
    if any(NATIVE_MARK in n for n in names):
        problems.append("the page requested a scriptshot_native wasm")
    if not any(LUA_LIB.match(n) for n in ok_names):
        problems.append("the lua-gdextension side module was never requested")
    if errors:
        problems.append(f"{len(errors)} unexpected console error(s): {errors[:5]}")
    if fallback != spec["fallback"]:
        problems.append(f"expected {spec['fallback']} native fallback warning(s), saw {fallback}")
    if spec["markers"]:
        problems.extend(check_markers(markers, spec["fallback"]))
    result["problems"] = problems
    result["ok"] = not problems
    return result


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "check-export":
        extra = argv[2:]
        if extra not in ([], ["--smoke"]):
            print(__doc__)
            return 2
        return 0 if check_export(Path(argv[1]), smoke=bool(extra)) else 1
    if len(argv) < 3 or argv[0] != "run":
        print(__doc__)
        return 2
    export_dir, outdir = Path(argv[1]).resolve(), Path(argv[2]).resolve()
    timeout = 90.0
    names = list(SCENARIOS)
    rest = argv[3:]
    while rest:
        flag = rest.pop(0)
        if flag == "--timeout":
            timeout = float(rest.pop(0))
        elif flag == "--scenarios":
            names = rest.pop(0).split(",")
        else:
            print(f"unknown option {flag}")
            return 2
    outdir.mkdir(parents=True, exist_ok=True)
    from playwright.sync_api import sync_playwright

    srv, port = serve(export_dir)
    url = f"http://127.0.0.1:{port}/index.html"
    results = []
    try:
        with sync_playwright() as pw:
            for name in names:
                r = run_scenario(pw, os.environ.get("CHROME_PATH") or None, url, name, SCENARIOS[name], outdir, timeout)
                results.append(r)
                status = "PASS" if r["ok"] else "FAIL"
                print(f"[{status}] {name}: engine started {r['engine_started_s']}s, done {r['done_s']}s, "
                      f"fallback warnings {r['fallback_warnings']}, crossOriginIsolated={r['cross_origin_isolated']}")
                for m in r["markers"]:
                    print(f"    {m}")
                for p in r["problems"]:
                    print(f"    problem: {p}")
    finally:
        srv.shutdown()
    (outdir / f"summary-{'-'.join(names)}.json").write_text(json.dumps(results, indent=2) + "\n")
    ok = all(r["ok"] for r in results)
    print("web_smoke:", "ok" if ok else "FAILED", f"(artifacts in {outdir})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
