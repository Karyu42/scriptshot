"""godot-cpp binding_hooks: guard generated builtin destructors at generation time.

The submodule stays at 10.0.0-stable; this file is ours. GodotCPPBindings
reads env["binding_hooks"] when it emits gen/src/variant/*.cpp, so a clean
first `scons target=template_debug` gets the guards (unlike a parse-time
patch of gen/, which is empty until after generation).

Generated operator= still calls `_method_bindings.destructor(&opaque)`
unguarded. That only matters after CORE deinitialize, when we no longer
assign builtins; shutdown hits ~Type(), which is what we guard.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

API_JSON = "gdextension/extension_api-4-7.json"
GUARD_LINES = [
    "\tif (!::godot::internal::builtin_destructors_enabled) {",
    "\t\treturn;",
    "\t}",
]
# ~Type() that calls the builtin destructor, with the guard immediately inside.
GUARDED_DTOR_RE = re.compile(
    r"~[A-Za-z0-9_]+\(\) \{\n"
    r"\tif \(!::godot::internal::builtin_destructors_enabled\) \{\n"
    r"\t\treturn;\n"
    r"\t\}\n"
    r"\t_method_bindings\.destructor\(&opaque\);\n"
    r"\}"
)
UNGUARDED_DTOR_RE = re.compile(
    r"~[A-Za-z0-9_]+\(\) \{\n"
    r"\t_method_bindings\.destructor\(&opaque\);\n"
    r"\}"
)


def builtin_classes_with_destructor(native_root: Path) -> list[str]:
    api_path = native_root / "godot-cpp" / API_JSON
    api = json.loads(api_path.read_text())
    return [b["name"] for b in api["builtin_classes"] if b.get("has_destructor")]


def _snake(name: str) -> str:
    out: list[str] = []
    for i, ch in enumerate(name):
        if ch.isupper() and i:
            out.append("_")
        out.append(ch.lower())
    return "".join(out)


def guarded_builtin_sources(native_root: Path) -> list[str]:
    return [_snake(name) + ".cpp" for name in builtin_classes_with_destructor(native_root)]


def expected_guard_count(native_root: Path) -> int:
    return len(builtin_classes_with_destructor(native_root))


def count_destructor_guards(native_root: Path) -> dict:
    variant_dir = native_root / "godot-cpp" / "gen" / "src" / "variant"
    if not variant_dir.is_dir():
        raise RuntimeError("scriptshot: %s is missing (bindings were not generated)" % variant_dir)
    expected = expected_guard_count(native_root)
    expected_files = set(guarded_builtin_sources(native_root))
    guarded = 0
    unguarded: list[str] = []
    missing: list[str] = []
    present: list[str] = []
    for name in sorted(expected_files):
        path = variant_dir / name
        if not path.is_file():
            missing.append(name)
            continue
        text = path.read_text()
        n_ok = len(GUARDED_DTOR_RE.findall(text))
        n_bad = len(UNGUARDED_DTOR_RE.findall(text))
        present.append(name)
        guarded += n_ok
        if n_ok != 1 or n_bad != 0:
            unguarded.append("%s (guarded ~Type()=%d, unguarded ~Type()=%d)" % (name, n_ok, n_bad))
    return {
        "expected": expected,
        "guarded": guarded,
        "unguarded": unguarded,
        "missing": missing,
        "files": present,
        "variant_cpp": len(list(variant_dir.glob("*.cpp"))),
    }


def assert_destructor_guards(native_root: Path) -> dict:
    info = count_destructor_guards(native_root)
    errors: list[str] = []
    if info["missing"]:
        errors.append("missing generated files: %s" % ", ".join(info["missing"]))
    if info["unguarded"]:
        errors.append("unguarded or mis-guarded destructors: %s" % ", ".join(info["unguarded"]))
    if info["guarded"] != info["expected"]:
        errors.append(
            "guarded ~Type() count is %d, expected %d (extension_api has_destructor builtins)"
            % (info["guarded"], info["expected"])
        )
    if errors:
        raise RuntimeError("scriptshot: destructor guards failed: " + "; ".join(errors))
    return info


class ScriptshotBindingHooks:
    """Passed to godot-cpp as binding_hooks. Other hook points are no-ops."""

    def alter_builtin_class_header(self, builtin_api, result):
        return result

    def alter_builtin_class_source(self, builtin_api, result):
        if not builtin_api.get("has_destructor"):
            return result
        out = []
        for i, line in enumerate(result):
            if (
                line == "\t_method_bindings.destructor(&opaque);"
                and i > 0
                and "::~" in result[i - 1]
                and result[i - 1].endswith("() {")
            ):
                out.extend(GUARD_LINES)
            out.append(line)
        return out

    def alter_engine_class_header(self, class_api, result):
        return result

    def alter_engine_class_source(self, class_api, result):
        return result

    def alter_global_constants(self, api, header):
        return header

    def alter_utility_functions_header(self, api, header):
        return header

    def alter_utility_functions_source(self, api, source):
        return source


def main(argv: list[str]) -> int:
    native_root = Path(__file__).resolve().parent
    try:
        info = assert_destructor_guards(native_root)
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 1
    print(
        "scriptshot: destructor guards ok: %d/%d ~Type() guarded in %d variant .cpp files"
        % (info["guarded"], info["expected"], info["variant_cpp"])
    )
    for name in info["files"]:
        print("  %s" % name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
