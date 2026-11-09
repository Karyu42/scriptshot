"""Unit tests for check_export_preset.py. Presets below are minimal TEST DATA, not the project's presets."""
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

import check_export_preset as c


def cfg(platform, name, exclude_filter="src/qa/*", index=0, custom_features="", **opts):
    body = "".join(f'{k.replace("__", "/")}={v}\n' for k, v in opts.items())
    return (f'[preset.{index}]\n\nname="{name}"\nplatform="{platform}"\nrunnable=false\n'
            f'custom_features="{custom_features}"\n'
            f'exclude_filter="{exclude_filter}"\n'
            f'[preset.{index}.options]\n\n{body}')


WEB_EXCLUDES = "*.md, src/qa/*, scriptshot_native.gdextension, bin/*"
SMOKE_EXCLUDES = "*.md, scriptshot_native.gdextension, bin/*"
WEB_OPTS = {"variant__extensions_support": "true", "variant__thread_support": "false"}


def web_pair(smoke_excludes=SMOKE_EXCLUDES, smoke_features="web_smoke", **smoke_opts):
    opts = dict(WEB_OPTS)
    opts.update(smoke_opts)
    return (cfg("Web", "Web", exclude_filter=WEB_EXCLUDES, **WEB_OPTS) + "\n"
            + cfg("Web", "Web (smoke)", exclude_filter=smoke_excludes, index=1,
                  custom_features=smoke_features, **opts))


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

    def test_macos_xcode_codesign_rejected(self):
        # 3 is Xcode codesign (macOS editor hosts only). Linux CI accepts 1 only.
        t = cfg("macOS", "macOS", codesign__codesign="3", codesign__identity='""',
                notarization__notarization="0", binary_format__architecture='"universal"')
        rc, out = run(t, "macOS")
        self.assertEqual(rc, 1)
        self.assertIn("must be 1", out)
        self.assertIn("Xcode", out)

    def test_macos_notarization_rejected(self):
        t = cfg("macOS", "macOS", codesign__codesign="1", notarization__notarization="2")
        self.assertEqual(run(t, "macOS")[0], 1)

    def test_web_threads_warns_not_fails(self):
        t = cfg("Web", "Web", exclude_filter="*.md, src/qa/*, scriptshot_native.gdextension, bin/*",
                variant__extensions_support="true", variant__thread_support="true")
        rc, out = run(t, "Web")
        self.assertEqual(rc, 0, out)
        self.assertIn("::warning::", out)

    def test_web_without_extensions_support_fails(self):
        t = cfg("Web", "Web", exclude_filter="scriptshot_native.gdextension",
                variant__extensions_support="false", variant__thread_support="false")
        rc, out = run(t, "Web")
        self.assertEqual(rc, 1)
        self.assertIn("extensions_support", out)

    def test_web_must_exclude_the_native_bullet_lib(self):
        t = cfg("Web", "Web", exclude_filter="tests/*, *.md",
                variant__extensions_support="true", variant__thread_support="false")
        rc, out = run(t, "Web")
        self.assertEqual(rc, 1)
        self.assertIn("scriptshot_native.gdextension", out)

    def test_shipping_preset_must_exclude_qa_files(self):
        t = cfg("Linux", "Linux", exclude_filter="tests/*, *.md")
        rc, out = run(t, "Linux")
        self.assertEqual(rc, 1)
        self.assertIn("src/qa/*", out)

    def test_qa_glob_alternative_is_accepted(self):
        self.assertEqual(run(cfg("Linux", "Linux", exclude_filter="src/qa/web_smoke*"), "Linux")[0], 0)

    def test_shipping_preset_must_not_set_the_smoke_feature(self):
        t = cfg("Linux", "Linux", custom_features="web_smoke")
        rc, out = run(t, "Linux")
        self.assertEqual(rc, 1)
        self.assertIn("web_smoke", out)

    def test_smoke_preset_matching_web_passes(self):
        rc, out = run(web_pair(), "Web (smoke)")
        self.assertEqual(rc, 0, out)
        self.assertEqual(run(web_pair(), "Web")[0], 0)

    def test_smoke_preset_must_not_exclude_qa(self):
        rc, out = run(web_pair(smoke_excludes=WEB_EXCLUDES), "Web (smoke)")
        self.assertEqual(rc, 1)
        self.assertIn("must not exclude src/qa/", out)

    def test_smoke_preset_needs_the_feature(self):
        rc, out = run(web_pair(smoke_features=""), "Web (smoke)")
        self.assertEqual(rc, 1)
        self.assertIn("custom_features", out)

    def test_smoke_preset_options_must_match_web(self):
        rc, out = run(web_pair(variant__thread_support="true"), "Web (smoke)")
        self.assertEqual(rc, 1)
        self.assertIn("variant/thread_support differs", out)

    def test_smoke_preset_must_keep_the_native_exclusion(self):
        rc, out = run(web_pair(smoke_excludes="*.md, bin/*"), "Web (smoke)")
        self.assertEqual(rc, 1)
        self.assertIn("scriptshot_native.gdextension", out)

    def test_ios_rejected(self):
        self.assertEqual(run(cfg("iOS", "iOS"), "iOS")[0], 1)


class CommittedPresetsTest(unittest.TestCase):
    def test_repo_presets_match_policy(self):
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
        path = os.path.join(root, "export_presets.cfg")
        self.assertTrue(os.path.isfile(path), path)
        for name in ("Windows Desktop", "macOS", "Linux", "Web", "Android", "Web (smoke)"):
            out = io.StringIO()
            with redirect_stdout(out):
                rc = c.main(["x", path, name])
            text = out.getvalue()
            self.assertEqual(rc, 0, text)
            self.assertIn("policy ok", text)
            self.assertNotIn("::error::", text)


if __name__ == "__main__":
    unittest.main()
