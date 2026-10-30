"""Unit tests for check_export_preset.py. Presets below are minimal TEST DATA, not the project's presets."""
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

import check_export_preset as c


def cfg(platform, name, **opts):
    body = "".join(f'{k.replace("__", "/")}={v}\n' for k, v in opts.items())
    return (f'[preset.0]\n\nname="{name}"\nplatform="{platform}"\nrunnable=false\n'
            f'[preset.0.options]\n\n{body}')


def run(text, name):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "export_presets.cfg")
        with open(p, "w") as f:
            f.write(text)
        out = io.StringIO()
        with redirect_stdout(out):
            rc = c.main(["x", p, name])
        return rc, out.getvalue()




def android(**over):
    o = {"gradle_build__use_gradle_build": "false", "architectures__arm64-v8a": "true",
         "architectures__armeabi-v7a": "false", "architectures__x86": "false", "architectures__x86_64": "false",
         "keystore__debug": '""', "keystore__release": '""'}
    o.update(over)
    return cfg("Android", "Android", **o)


class CheckExportPresetTest(unittest.TestCase):
    def test_android_ok(self):
        rc, out = run(android(), "Android")
        self.assertEqual(rc, 0, out)

    def test_missing_preset(self):
        rc, out = run(android(), "Windows Desktop")
        self.assertEqual(rc, 1)
        self.assertIn("not found", out)

    def test_android_x86_64_rejected(self):
        rc, out = run(android(**{"architectures__x86_64": "true"}), "Android")
        self.assertEqual(rc, 1)
        self.assertIn("architectures/x86_64", out)

    def test_android_gradle_rejected(self):
        rc, out = run(android(gradle_build__use_gradle_build="true"), "Android")
        self.assertEqual(rc, 1)

    def test_committed_keystore_rejected(self):
        rc, out = run(android(keystore__release='"/home/me/release.keystore"'), "Android")
        self.assertEqual(rc, 1)
        self.assertIn("keystore/release", out)

    def test_password_rejected_anywhere(self):
        rc, out = run(android(keystore__release_password='"hunter2"'), "Android")
        self.assertEqual(rc, 1)
        self.assertIn("release_password", out)

    def test_macos_adhoc_ok(self):
        t = cfg("macOS", "macOS", codesign__codesign="1", notarization__notarization="0",
                binary_format__architecture='"universal"')
        self.assertEqual(run(t, "macOS")[0], 0)

    def test_macos_unsigned_rejected(self):
        t = cfg("macOS", "macOS", codesign__codesign="0", notarization__notarization="0")
        rc, out = run(t, "macOS")
        self.assertEqual(rc, 1)
        self.assertIn("ad-hoc", out)

    def test_macos_notarization_rejected(self):
        t = cfg("macOS", "macOS", codesign__codesign="1", notarization__notarization="2")
        self.assertEqual(run(t, "macOS")[0], 1)

    def test_web_warns_not_fails(self):
        t = cfg("Web", "Web", variant__extensions_support="false", variant__thread_support="true")
        rc, out = run(t, "Web")
        self.assertEqual(rc, 0)
        self.assertIn("::warning::", out)

    def test_ios_rejected(self):
        self.assertEqual(run(cfg("iOS", "iOS"), "iOS")[0], 1)


if __name__ == "__main__":
    unittest.main()
