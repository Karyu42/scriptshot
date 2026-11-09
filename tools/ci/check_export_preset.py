#!/usr/bin/env python3
"""Policy check for a committed export_presets.cfg.

Usage: check_export_preset.py export_presets.cfg "<preset name>"

Runs in the `test` job on every pull request and push, and again in the manual `export` job.
Decisions encoded here (docs/qa/release-builds.md):
  * No secrets in the committed file: every option whose key ends in "password" must be empty, and the
    Android keystore paths/users must be empty (CI injects GODOT_ANDROID_KEYSTORE_* from env).
  * Android: arm64-v8a only, no Gradle build (the plain template export needs no Gradle/NDK).
  * macOS: ad-hoc signing only ("Built-in (ad-hoc only)" = 1), no notarization, no Apple account.
    Value 3 (Xcode codesign) is rejected: the export runner is Linux, where that mode does not exist.
  * Web: extensions_support must be on (dlink template). The Lua binding is a GDExtension and the
    no-dlink 4.7.2 template refuses to start with any GDExtension in the export (issue #40).
    exclude_filter must list scriptshot_native.gdextension, so web runs on the GDScript bullet
    pool and never packages the native bullet wasm (CoS ruling on #36). Threads on is a WARNING.
  * QA smoke files stay out of normal builds: every preset except "Web (smoke)" must list src/qa/*
    (or src/qa/web_smoke*) in exclude_filter and must not set the web_smoke custom feature.
    "Web (smoke)" (tools/ci/web_smoke.sh) must be the Web preset plus the web_smoke feature: same
    options, same meta, and the same exclude_filter minus the src/qa entry.
Exit code 0 = ok, 1 = policy violation or preset not found. Warnings do not fail.
"""
import configparser
import re
import sys

SECRET_SUFFIX = re.compile(r"password$")
ANDROID_ABIS = ("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
NATIVE_GDEXTENSION = "scriptshot_native.gdextension"
SMOKE_PRESET = "Web (smoke)"
SMOKE_FEATURE = "web_smoke"
QA_EXCLUDES = ("src/qa/*", "src/qa/web_smoke*")
# Meta keys the smoke preset may differ in from the shipping Web preset.
SMOKE_META_DIFF = ("name", "custom_features", "exclude_filter", "export_path", "runnable")


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


def split_list(value):
    return [x.strip() for x in unquote(value).split(",") if x.strip()]


def check_qa_files(cp, name, meta, opts):
    """src/qa/ (the web smoke scene) ships only in the smoke preset."""
    errors = []
    excludes = split_list(meta.get("exclude_filter", ""))
    features = split_list(meta.get("custom_features", ""))
    if name != SMOKE_PRESET:
        if not any(x in excludes for x in QA_EXCLUDES):
            errors.append("exclude_filter must list src/qa/* (the web smoke scene is not part of normal builds)")
        if SMOKE_FEATURE in features:
            errors.append(f"custom_features must not contain {SMOKE_FEATURE} (it makes the smoke scene the main scene)")
        return errors
    if unquote(meta.get("platform", "")) != "Web":
        errors.append(f"{SMOKE_PRESET} must be a Web preset")
    if SMOKE_FEATURE not in features:
        errors.append(f"{SMOKE_PRESET} must set custom_features to include {SMOKE_FEATURE}")
    if any(x in excludes for x in QA_EXCLUDES):
        errors.append(f"{SMOKE_PRESET} must not exclude src/qa/ (that is the smoke scene)")
    web_meta, web_opts = find_preset(cp, "Web")
    if web_meta is None:
        errors.append(f"{SMOKE_PRESET} needs the shipping Web preset to compare against")
        return errors
    want = [x for x in split_list(web_meta.get("exclude_filter", "")) if x not in QA_EXCLUDES]
    if excludes != want:
        errors.append(f"{SMOKE_PRESET} exclude_filter must be Web's without src/qa/*: want {want}, got {excludes}")
    for k in sorted(set(web_meta) | set(meta)):
        if k not in SMOKE_META_DIFF and web_meta.get(k) != meta.get(k):
            errors.append(f"{SMOKE_PRESET} {k} differs from Web ({web_meta.get(k)!r} vs {meta.get(k)!r})")
    for k in sorted(set(web_opts) | set(opts)):
        if web_opts.get(k) != opts.get(k):
            errors.append(f"{SMOKE_PRESET} option {k} differs from Web ({web_opts.get(k)!r} vs {opts.get(k)!r})")
    return errors


def check(cp, name):
    """Returns (errors, warnings)."""
    errors, warnings = [], []
    meta, opts = find_preset(cp, name)
    if meta is None:
        return [f"preset '{name}' not found in export_presets.cfg (names are case-sensitive)"], []

    for k, v in sorted(opts.items()):
        if SECRET_SUFFIX.search(k.split("/")[-1]) and v != "":
            errors.append(f"{k} is set in the committed file; secrets belong in env/export_credentials.cfg")

    errors.extend(check_qa_files(cp, name, meta, opts))
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
        # 1 = "Built-in (ad-hoc only)", the only ad-hoc mode on the Linux export runner.
        # 3 is Xcode codesign and exists only when the editor host is macOS, so a committed 3
        # would not be what CI actually exports.
        if opts.get("codesign/codesign", "") != "1":
            errors.append("codesign/codesign must be 1 (Built-in, ad-hoc only) on the Linux CI runner; "
                          "an unsigned arm64 app will not launch, and 3 (Xcode codesign) is macOS-host only")
        if opts.get("notarization/notarization", "0") != "0":
            errors.append("notarization/notarization must be 0 (Disabled): no Apple developer account")
        if opts.get("binary_format/architecture", "universal") != "universal":
            errors.append("binary_format/architecture must be universal")
    elif platform == "Web":
        if opts.get("variant/extensions_support", "false") != "true":
            errors.append("variant/extensions_support must be true: the Lua binding is a GDExtension and the "
                          "no-dlink template refuses to boot with one (issue #40)")
        excludes = [x.strip() for x in unquote(meta.get("exclude_filter", "")).split(",")]
        if NATIVE_GDEXTENSION not in excludes:
            errors.append(f"exclude_filter must list {NATIVE_GDEXTENSION}: web ships on the GDScript bullet "
                          "pool without the native wasm (issue #36)")
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
