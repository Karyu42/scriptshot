"""Unit tests for web_smoke.py's console classifier and export checks (no browser)."""
import json
import struct
import tempfile
import unittest
from pathlib import Path

import web_smoke as w

LUA = "libluagdextension.web.template_release.wasm32.nothreads.wasm"
NATIVE = "libscriptshot_native.web.template_release.wasm32.nothreads.wasm"
FALLBACK = ("WARNING: BulletManager: native bullets were requested but NativeBulletSim is not available;"
            " staying on the GDScript backend.")


def pck(files):
    """Minimal unencrypted format-3 pck with the given {path: bytes}."""
    entries = b""
    blobs = b""
    for name, data in files.items():
        p = ("res://" + name).encode()
        p += b"\0" * (-len(p) % 4)
        entries += struct.pack("<I", len(p)) + p + struct.pack("<QQ", len(blobs), len(data)) + b"\0" * 16 + b"\0" * 4
        blobs += data
    header_len = 4 + 5 * 4 + 16 + 64
    base = header_len
    dir_off = base + len(blobs)
    head = b"GDPC" + struct.pack("<5I", 3, 4, 7, 2, 0) + struct.pack("<QQ", base, dir_off) + b"\0" * 64
    return head + blobs + struct.pack("<I", len(files)) + entries


def export_dir(d, libs, files, pck_files):
    html = "<script>const GODOT_CONFIG = %s;</script>" % json.dumps({"args": [], "gdextensionLibs": libs})
    (d / "index.html").write_text(html)
    for f in files:
        (d / f).write_bytes(b"x")
    (d / "index.pck").write_bytes(pck(pck_files))


GOOD_PCK = {
    ".godot/extension_list.cfg": b"res://addons/lua-gdextension/luagdextension.gdextension\n",
    "scripting/sandbox.lua": b"-- sandbox",
    "src/qa/web_smoke_shot.lua": b"return {}",
}


class ClassifyTest(unittest.TestCase):
    def test_allowlisted_warning_and_its_at_line_pass(self):
        console = [("error", "WARNING: Property not found: 'lua_gdextension/lua_script_language/script_import_map'."),
                   ("error", "   at: get_setting_with_override (core/config/project_settings.cpp:435)"),
                   ("log", "SMOKE_DONE ok")]
        self.assertEqual(w.classify(console), ([], 0))

    def test_an_error_fails_and_its_at_line_too(self):
        console = [("error", "ERROR: No GDExtension library found"), ("error", "   at: parse (x.cpp:1)")]
        bad, _ = w.classify(console)
        self.assertEqual(len(bad), 2)

    def test_fallback_warning_is_counted_with_its_backtrace(self):
        console = [("error", FALLBACK), ("error", "   at: push_warning (v.cpp:1)"),
                   ("error", "   GDScript backtrace (most recent call first):"),
                   ("error", "       [0] warn_missing (res://src/bullets/native_backend.gd:82)")]
        self.assertEqual(w.classify(console), ([], 1))
        self.assertEqual(w.classify(console + console)[1], 2)

    def test_log_lines_are_not_errors(self):
        self.assertEqual(w.classify([("log", "Godot Engine v4.7.2"), ("warning", "a js warning")]), ([], 0))


class CheckExportTest(unittest.TestCase):
    def test_lua_only_export_passes(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            export_dir(d, [LUA], ["index.side.wasm", "index.wasm", LUA], GOOD_PCK)
            self.assertTrue(w.check_export(d))

    def test_native_lib_in_export_fails(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            files = dict(GOOD_PCK)
            files["scriptshot_native.gdextension"] = b"[configuration]"
            files[".godot/extension_list.cfg"] += b"res://scriptshot_native.gdextension\n"
            export_dir(d, [NATIVE, LUA], ["index.side.wasm", "index.wasm", LUA, NATIVE], files)
            self.assertFalse(w.check_export(d))

    def test_no_dlink_template_fails(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            export_dir(d, [LUA], ["index.wasm", LUA], GOOD_PCK)
            self.assertFalse(w.check_export(d))


if __name__ == "__main__":
    unittest.main()
