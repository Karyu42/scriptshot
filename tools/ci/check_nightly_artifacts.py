#!/usr/bin/env python3
"""Verify Linux/Windows/web export folders are shipping builds, not QA.

Usage:
  check_nightly_artifacts.py --linux DIR --windows DIR --web DIR

Checks:
  * Each folder has the ready-to-run binary or web tree, plus the Lua (and
    desktop native) libraries the export job already required.
  * The packed project contains no src/qa/ files (web_smoke, playtest autoplay).
  * The web tree matches the shipping Web preset: lua-gdextension in, native
    bullet wasm out, no web_smoke/playtest feature.
Exit 0 if all pass, 1 otherwise.
"""
from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import web_smoke  # noqa: E402

QA_PREFIX = "src/qa/"
QA_FEATURES = (b"web_smoke", b"playtest")


def fail(msg: str) -> None:
    print(f"check_nightly_artifacts: FAIL: {msg}", flush=True)


def pck_from_blob(blob: bytes, start: int) -> dict[str, bytes] | None:
    """Parse a Godot 4 pck at offset `start`, or None if that is not a pck."""
    if blob[start:start + 4] != b"GDPC":
        return None
    if start + 28 > len(blob):
        return None
    ver, _ma, _mi, _pa, flags = struct.unpack_from("<5I", blob, start + 4)
    if ver < 2 or ver > 4 or flags & 1:
        return None
    base, dir_off = struct.unpack_from("<QQ", blob, start + 24)
    off = dir_off if ver >= 3 else 24 + 8 + 64
    if ver < 3:
        base = 0
    dir_at = start + off
    if dir_at + 4 > len(blob):
        return None
    (n,) = struct.unpack_from("<I", blob, dir_at)
    if n < 1 or n > 20000:
        return None
    out: dict[str, bytes] = {}
    cursor = dir_at + 4
    try:
        for _ in range(n):
            (ln,) = struct.unpack_from("<I", blob, cursor)
            cursor += 4
            name = blob[cursor:cursor + ln].rstrip(b"\0").decode()
            cursor += ln
            foff, fsize = struct.unpack_from("<QQ", blob, cursor)
            cursor += 16 + 16 + 4
            data_at = start + base + foff
            out[name.removeprefix("res://")] = blob[data_at:data_at + fsize]
    except (struct.error, UnicodeDecodeError, ValueError):
        return None
    return out


def embedded_pck(path: Path) -> dict[str, bytes]:
    blob = path.read_bytes()
    start = 0
    found: dict[str, bytes] | None = None
    while True:
        hit = blob.find(b"GDPC", start)
        if hit < 0:
            break
        parsed = pck_from_blob(blob, hit)
        if parsed:
            found = parsed
        start = hit + 4
    if not found:
        raise ValueError(f"{path} has no parseable embedded Godot pck")
    return found


def qa_in_pck(pck: dict[str, bytes]) -> list[str]:
    return sorted(p for p in pck if p.startswith(QA_PREFIX) or p.startswith("src/qa"))


def feature_on(pck: dict[str, bytes], feature: bytes) -> bool:
    binary = pck.get("project.binary", b"")
    if b"_custom_features" not in binary:
        return False
    window = binary.split(b"_custom_features", 1)[1][:64]
    return feature in window


def check_desktop(label: str, folder: Path, binary_name: str, native_name: str, lua_name: str) -> bool:
    ok = True
    print(f"== {label}: {folder}")
    binary = folder / binary_name
    if not binary.is_file() or binary.stat().st_size < 1024:
        fail(f"{label} missing {binary_name}"); return False
    if not (folder / native_name).is_file():
        fail(f"{label} missing {native_name}"); ok = False
    if not (folder / lua_name).is_file():
        fail(f"{label} missing {lua_name}"); ok = False
    try:
        pck = embedded_pck(binary)
    except ValueError as e:
        fail(str(e)); return False
    print(f"  embedded pck files: {len(pck)}")
    qa = qa_in_pck(pck)
    print(f"  src/qa/ entries: {qa}")
    if qa:
        fail(f"{label} pck contains QA files: {qa}"); ok = False
    for feat in QA_FEATURES:
        on = feature_on(pck, feat)
        print(f"  custom feature {feat.decode()}: {on}")
        if on:
            fail(f"{label} carries the {feat.decode()} QA feature"); ok = False
    return ok


def check_web(folder: Path) -> bool:
    print(f"== web: {folder}")
    ok = web_smoke.check_export(folder, smoke=False)
    pck = web_smoke.pck_files(folder / "index.pck")
    qa = qa_in_pck(pck)
    # check_export already fails on src/qa/; repeat so a playtest file is named.
    if qa:
        fail(f"web pck contains QA files: {qa}"); ok = False
    if feature_on(pck, b"playtest"):
        fail("web export carries the playtest QA feature"); ok = False
    return ok


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--linux", type=Path, required=True)
    ap.add_argument("--windows", type=Path, required=True)
    ap.add_argument("--web", type=Path, required=True)
    args = ap.parse_args(argv)
    ok = True
    ok &= check_desktop(
        "linux", args.linux,
        "Scriptshot.x86_64",
        "libscriptshot_native.linux.template_release.x86_64.so",
        "libluagdextension.linux.template_release.x86_64.so",
    )
    ok &= check_desktop(
        "windows", args.windows,
        "Scriptshot.exe",
        "libscriptshot_native.windows.template_release.x86_64.dll",
        "libluagdextension.windows.template_release.x86_64.dll",
    )
    ok &= check_web(args.web)
    print("check_nightly_artifacts:", "ok" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
