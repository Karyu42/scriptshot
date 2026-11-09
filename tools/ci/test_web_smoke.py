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
    "project.binary": b"ECFG\x00application/run/main_scene\x00res://scenes/main.tscn",
}
SMOKE_PCK = dict(GOOD_PCK)
SMOKE_PCK.update({
    "project.binary": b"ECFG\x00\x10\x00\x00\x00_custom_features\x14\x00\x00\x00\x04\x00\x00\x00\t\x00\x00\x00web_smoke\x00",
    "src/qa/web_smoke.tscn.remap": b"[remap]",
    "src/qa/web_smoke.gd.remap": b"[remap]",
    "src/qa/web_smoke.gdc": b"x",
    "src/qa/web_smoke_shot.lua": b"return {}",
})
DLINK = ["index.side.wasm", "index.wasm", LUA]


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
            export_dir(d, [LUA], DLINK, GOOD_PCK)
            self.assertTrue(w.check_export(d))

    def test_native_lib_in_export_fails(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            files = dict(GOOD_PCK)
            files["scriptshot_native.gdextension"] = b"[configuration]"
            files[".godot/extension_list.cfg"] += b"res://scriptshot_native.gdextension\n"
            export_dir(d, [NATIVE, LUA], ["index.side.wasm", "index.wasm", LUA, NATIVE], files)
            self.assertFalse(w.check_export(d))

    def test_qa_files_in_a_shipping_export_fail(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            export_dir(d, [LUA], DLINK, SMOKE_PCK)
            self.assertFalse(w.check_export(d))

    def test_websmoke_autoload_in_a_shipping_export_fails(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            files = dict(GOOD_PCK)
            files["project.binary"] += b"autoload/WebSmoke\x00*res://src/qa/web_smoke.gd"
            export_dir(d, [LUA], DLINK, files)
            self.assertFalse(w.check_export(d))

    def test_smoke_export_passes_with_smoke_files_and_feature(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            export_dir(d, [LUA], DLINK, SMOKE_PCK)
            self.assertTrue(w.check_export(d, smoke=True))

    def test_smoke_export_without_the_feature_fails(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            files = dict(SMOKE_PCK)
            files["project.binary"] = GOOD_PCK["project.binary"]
            export_dir(d, [LUA], DLINK, files)
            self.assertFalse(w.check_export(d, smoke=True))

    def test_no_dlink_template_fails(self):
        with tempfile.TemporaryDirectory() as t:
            d = Path(t)
            export_dir(d, [LUA], ["index.wasm", LUA], GOOD_PCK)
            self.assertFalse(w.check_export(d))


GOOD_MARKERS = [
    "SMOKE_START platform=Web feature=true args=",
    "SMOKE_MAIN_OK scene=res://scenes/main.tscn backend=gdscript native_class=false",
    "SMOKE_LUA_OK bullets=16 backend=gdscript on_spawn=8 chunk=src/qa/web_smoke_shot.lua",
    "SMOKE_BACKEND backend=gdscript requested=gdscript fallback_warnings=0",
    "SMOKE_DONE ok",
]


class MarkerTest(unittest.TestCase):
    def test_good_markers_pass(self):
        self.assertEqual(w.check_markers(GOOD_MARKERS, 0), [])

    def test_fallback_count_is_exact_not_a_substring(self):
        m = [x.replace("fallback_warnings=0", "fallback_warnings=10") for x in GOOD_MARKERS]
        self.assertTrue(w.check_markers(m, 1))
        self.assertTrue(w.check_markers(m, 0))
        m = [x.replace("fallback_warnings=0", "fallback_warnings=1") for x in GOOD_MARKERS]
        self.assertEqual(w.check_markers(m, 1), [])

    def test_native_backend_fails(self):
        m = [x.replace("SMOKE_BACKEND backend=gdscript", "SMOKE_BACKEND backend=native") for x in GOOD_MARKERS]
        self.assertTrue(w.check_markers(m, 0))
        m = [x.replace("bullets=16 backend=gdscript", "bullets=16 backend=gdscriptx") for x in GOOD_MARKERS]
        self.assertTrue(w.check_markers(m, 0))

    def test_missing_or_failed_done_fails(self):
        self.assertTrue(w.check_markers(GOOD_MARKERS[:-1], 0))
        self.assertTrue(w.check_markers(GOOD_MARKERS + ["SMOKE_DONE fail"], 0))

    def test_zero_bullets_fails(self):
        m = [x.replace("bullets=16", "bullets=0") for x in GOOD_MARKERS]
        self.assertTrue(w.check_markers(m, 0))


class WindowTest(unittest.TestCase):
    BOOT = {"markers": False}
    LUA = {"markers": True}

    def test_boot_passes_when_the_window_completes(self):
        self.assertEqual(w.window_problems(self.BOOT, 1.8, 7.8, 90), [])

    def test_boot_fails_when_the_window_does_not_complete(self):
        out = w.window_problems(self.BOOT, 88.0, None, 90)
        self.assertEqual(len(out), 1)
        self.assertIn("did not run for 6s", out[0])

    def test_engine_never_started_fails(self):
        self.assertTrue(w.window_problems(self.BOOT, None, None, 90))
        self.assertTrue(w.window_problems(self.LUA, None, None, 90))

    def test_marker_scenarios_rely_on_markers(self):
        self.assertEqual(w.window_problems(self.LUA, 1.8, None, 90), [])


if __name__ == "__main__":
    unittest.main()
