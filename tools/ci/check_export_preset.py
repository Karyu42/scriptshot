#!/usr/bin/env python3
"""Policy check for a committed export_presets.cfg (used by the manual `export` CI job).

Usage: check_export_preset.py export_presets.cfg "<preset name>"

Decisions encoded here (docs/qa/release-builds.md):
  * No secrets in the committed file: every option whose key ends in "password" must be empty, and the
    Android keystore paths/users must be empty (CI injects GODOT_ANDROID_KEYSTORE_* from env).
  * Android: arm64-v8a only, no Gradle build (the plain template export needs no Gradle/NDK).
  * macOS: ad-hoc signing only ("Built-in (ad-hoc only)" = 1), no notarization, no Apple account.
  * Web: extensions_support is a WARNING when off (required once the Lua binding is a GDExtension).
Exit code 0 = ok, 1 = policy violation or preset not found. Warnings do not fail.
"""
import configparser
import re
import sys

SECRET_SUFFIX = re.compile(r"password$")
ANDROID_ABIS = ("armeabi-v7a", "arm64-v8a", "x86", "x86_64")


def parse(path):
    cp = configparser.RawConfigParser(delimiters=("=",), interpolation=None, strict=False)
    cp.optionxform = str  # keep key case
    with open(path, encoding="utf-8") as f:
        cp.read_file(f)
    return cp


def unquote(v):
    v = v.strip()
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] == '"' else v


def find_preset(cp, name):
    for sec in cp.sections():
        if re.fullmatch(r"preset\.\d+", sec) and unquote(cp.get(sec, "name", fallback="")) == name:
            opts = dict(cp.items(sec + ".options")) if cp.has_section(sec + ".options") else {}
            return dict(cp.items(sec)), {k: unquote(v) for k, v in opts.items()}
    return None, None


def check(cp, name):
    """Returns (errors, warnings)."""
    errors, warnings = [], []
    meta, opts = find_preset(cp, name)
    if meta is None:
        return [f"preset '{name}' not found in export_presets.cfg (names are case-sensitive)"], []

    for k, v in sorted(opts.items()):
        if SECRET_SUFFIX.search(k.split("/")[-1]) and v != "":
            errors.append(f"{k} is set in the committed file; secrets belong in env/export_credentials.cfg")

    platform = unquote(meta.get("platform", ""))
    if platform == "Android":
        for k in ("keystore/debug", "keystore/debug_user", "keystore/release", "keystore/release_user"):
            if opts.get(k, ""):
                errors.append(f"{k} must be empty in the committed preset (CI uses GODOT_ANDROID_KEYSTORE_* env)")
        if opts.get("gradle_build/use_gradle_build", "false") != "false":
            errors.append("gradle_build/use_gradle_build must be false (plain template export, no Gradle/NDK)")
        for abi in ANDROID_ABIS:
            want = "true" if abi == "arm64-v8a" else "false"
            got = opts.get(f"architectures/{abi}", "false")
            if got != want:
                errors.append(f"architectures/{abi} must be {want} (Android release target is arm64 only), got {got}")
    elif platform == "macOS":
        if opts.get("codesign/codesign", "") not in ("1", "3"):
            errors.append("codesign/codesign must be 1 (Built-in, ad-hoc only); an unsigned arm64 app will not launch")
        elif opts.get("codesign/codesign") == "3" and opts.get("codesign/identity", "") not in ("", "-"):
            errors.append("codesign/identity must be empty or '-' (ad-hoc); no Apple developer account is available")
        if opts.get("notarization/notarization", "0") != "0":
            errors.append("notarization/notarization must be 0 (Disabled): no Apple developer account")
        if opts.get("binary_format/architecture", "universal") != "universal":
            errors.append("binary_format/architecture must be universal")
    elif platform == "Web":
        if opts.get("variant/extensions_support", "false") != "true":
            warnings.append("variant/extensions_support is off: required as soon as the Lua binding is a GDExtension")
        if opts.get("variant/thread_support", "false") == "true":
            warnings.append("variant/thread_support is on: the host needs COOP/COEP headers (docs/qa/release-builds.md)")
    elif platform == "iOS":
        errors.append("iOS is not a release target; do not export it in CI")
    return errors, warnings


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    cp = parse(argv[1])
    errors, warnings = check(cp, argv[2])
    for w in warnings:
        print(f"::warning::{argv[2]}: {w}")
    for e in errors:
        print(f"::error::{argv[2]}: {e}")
    if not errors:
        print(f"export preset '{argv[2]}': policy ok")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
