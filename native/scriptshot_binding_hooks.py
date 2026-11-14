"""godot-cpp binding_hooks: guard generated builtin shutdown paths at generation time.

The submodule stays at 10.0.0-stable; this file is ours. GodotCPPBindings
reads env["binding_hooks"] when it emits gen/src/variant/*.cpp, so a clean
first `scons target=template_debug` gets the guards (unlike a parse-time
patch of gen/, which is empty until after generation).

Copy operator=, engine-calling constructors, and RID copy-assign are no-ops
when builtin destructors are disabled, matching ~Type(). Handwritten
Variant / String / StringName / Ref paths are patched the same way at
SConstruct time (see apply_handwritten_shutdown_guards).
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
# Copy operator= that destroys and/or reconstructs via the engine. Move assign only swaps.
GUARDED_ASSIGN_RE = re.compile(
    r"&[A-Za-z0-9_]+::operator=\(const [A-Za-z0-9_]+ &p_other\) \{\n"
    r"\tif \(!::godot::internal::builtin_destructors_enabled\) \{\n"
    r"\t\treturn \*this;\n"
    r"\t\}\n"
    r"\t(?:_method_bindings\.destructor\(&opaque\);|::godot::internal::_call_builtin_constructor\()"
)
UNGUARDED_ASSIGN_RE = re.compile(
    r"&[A-Za-z0-9_]+::operator=\(const [A-Za-z0-9_]+ &p_other\) \{\n"
    r"\t(?:_method_bindings\.destructor\(&opaque\);|::godot::internal::_call_builtin_constructor\()"
)
ASSIGN_OPEN_RE = re.compile(
    r"^([A-Za-z0-9_]+) &\1::operator=\(const \1 &p_other\) \{$"
)
ASSIGN_GUARD_LINES = [
    "\tif (!::godot::internal::builtin_destructors_enabled) {",
    "\t\treturn *this;",
    "\t}",
]
# Type::Type(...) that calls into the engine (not move constructors, which only swap).
CTOR_OPEN_RE = re.compile(r"^([A-Za-z0-9_]+)::\1\([^;]*\) \{$")
GUARDED_CTOR_RE = re.compile(
    r"::[A-Za-z0-9_]+\([^;{]*\) \{\n"
    r"\tif \(!::godot::internal::builtin_destructors_enabled\) \{\n"
    r"\t\treturn;\n"
    r"\t\}\n"
    r"\t(?:::godot::internal::_call_builtin_constructor|_method_bindings\.from_variant_constructor)\("
)
UNGUARDED_CTOR_RE = re.compile(
    r"::[A-Za-z0-9_]+\([^;{]*\) \{\n"
    r"\t(?:::godot::internal::_call_builtin_constructor|_method_bindings\.from_variant_constructor)\("
)

# RID has no destructor; its generated file name is rid.cpp (not r_i_d.cpp).
RID_SOURCE = "rid.cpp"

FLAG_CHECK = "builtin_destructors_enabled"


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


def guarded_assign_sources(native_root: Path) -> list[str]:
    names = guarded_builtin_sources(native_root)
    if RID_SOURCE not in names:
        names = names + [RID_SOURCE]
    return names


def expected_guard_count(native_root: Path) -> int:
    return len(builtin_classes_with_destructor(native_root))


def expected_assign_count(native_root: Path) -> int:
    return len(guarded_assign_sources(native_root))


def _ctor_calls_engine(line: str) -> bool:
    return (
        "::_call_builtin_constructor(" in line
        or "from_variant_constructor(" in line
    )


def count_destructor_guards(native_root: Path) -> dict:
    variant_dir = native_root / "godot-cpp" / "gen" / "src" / "variant"
    if not variant_dir.is_dir():
        raise RuntimeError("scriptshot: %s is missing (bindings were not generated)" % variant_dir)
    expected = expected_guard_count(native_root)
    expected_assign = expected_assign_count(native_root)
    expected_files = set(guarded_assign_sources(native_root))
    dtor_files = set(guarded_builtin_sources(native_root))
    guarded = 0
    guarded_assign = 0
    guarded_ctor = 0
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
        n_ok_assign = len(GUARDED_ASSIGN_RE.findall(text))
        n_bad_assign = len(UNGUARDED_ASSIGN_RE.findall(text))
        n_ok_ctor = len(GUARDED_CTOR_RE.findall(text))
        n_bad_ctor = len(UNGUARDED_CTOR_RE.findall(text))
        present.append(name)
        guarded += n_ok
        guarded_assign += n_ok_assign
        guarded_ctor += n_ok_ctor
        if name in dtor_files and (n_ok != 1 or n_bad != 0):
            unguarded.append("%s (guarded ~Type()=%d, unguarded ~Type()=%d)" % (name, n_ok, n_bad))
        if n_ok_assign != 1 or n_bad_assign != 0:
            unguarded.append(
                "%s (guarded operator=%d, unguarded operator=%d)"
                % (name, n_ok_assign, n_bad_assign)
            )
        if n_bad_ctor != 0:
            unguarded.append("%s (unguarded engine constructors=%d)" % (name, n_bad_ctor))
    # Any other generated variant source must not have a leftover unguarded assign/ctor.
    for path in sorted(variant_dir.glob("*.cpp")):
        if path.name in expected_files:
            continue
        text = path.read_text()
        n_bad_assign = len(UNGUARDED_ASSIGN_RE.findall(text))
        n_bad_ctor = len(UNGUARDED_CTOR_RE.findall(text))
        if n_bad_assign or n_bad_ctor:
            unguarded.append(
                "%s (extra unguarded operator=%d, constructors=%d)"
                % (path.name, n_bad_assign, n_bad_ctor)
            )
    return {
        "expected": expected,
        "expected_assign": expected_assign,
        "guarded": guarded,
        "guarded_assign": guarded_assign,
        "guarded_ctor": guarded_ctor,
        "unguarded": unguarded,
        "missing": missing,
        "files": present,
        "variant_cpp": len(list(variant_dir.glob("*.cpp"))),
    }


def _insert_guard_after_opens(
    text: str,
    is_open,
    return_stmt: str,
    extra_lines: list[str] | None = None,
) -> tuple[str, int]:
    """Insert a flag early-return after matching function opens. Idempotent."""
    ends_nl = text.endswith("\n")
    lines = text.splitlines()
    out: list[str] = []
    inserted = 0
    for i, line in enumerate(lines):
        out.append(line)
        if not is_open(line, i, lines):
            continue
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if FLAG_CHECK in nxt:
            continue
        indent = line[: len(line) - len(line.lstrip("\t"))] + "\t"
        out.append("%sif (!::godot::internal::builtin_destructors_enabled) {" % indent)
        for extra in extra_lines or []:
            out.append("%s\t%s" % (indent, extra))
        out.append("%s\t%s" % (indent, return_stmt))
        out.append("%s}" % indent)
        inserted += 1
    result = "\n".join(out)
    if ends_nl:
        result += "\n"
    return result, inserted


def apply_handwritten_shutdown_guards(native_root: Path) -> dict:
    """Patch handwritten godot-cpp sources. Idempotent. Does not vendor the submodule."""
    root = native_root / "godot-cpp"
    counts: dict[str, int] = {}

    def _write(path: Path, new: str, key: str, n: int) -> None:
        if n:
            path.write_text(new)
        counts[key] = n

    variant_cpp = root / "src/variant/variant.cpp"
    text = variant_cpp.read_text()
    text, n = _insert_guard_after_opens(
        text,
        lambda line, _i, _ls: line.startswith("Variant &Variant::operator=(const Variant &")
        and line.endswith("{"),
        "return *this;",
    )
    _write(variant_cpp, text, "variant_assign", n)
    text = variant_cpp.read_text()
    text, n = _insert_guard_after_opens(
        text,
        lambda line, _i, _ls: line.startswith("void Variant::clear(") and line.endswith("{"),
        "return;",
    )
    _write(variant_cpp, text, "variant_clear", n)
    text = variant_cpp.read_text()

    def _is_variant_ctor(line: str, _i: int, _ls: list[str]) -> bool:
        if not line.startswith("Variant::Variant(") or not line.endswith("{"):
            return False
        return "&&" not in line

    text, n = _insert_guard_after_opens(text, _is_variant_ctor, "return;")
    _write(variant_cpp, text, "variant_ctor", n)

    char_cpp = root / "src/variant/char_string.cpp"
    text = char_cpp.read_text()
    text, n = _insert_guard_after_opens(
        text,
        lambda line, _i, _ls: bool(re.match(r"^String::String\(const (char|wchar_t|char16_t|char32_t) \*from\) \{$", line)),
        "return;",
    )
    _write(char_cpp, text, "string_cstr_ctor", n)
    text = char_cpp.read_text()
    text, n = _insert_guard_after_opens(
        text,
        lambda line, _i, _ls: bool(re.match(r"^String &String::operator=\(const (char|wchar_t|char16_t|char32_t) \*p_str\) \{$", line)),
        "return *this;",
    )
    _write(char_cpp, text, "string_cstr_assign", n)
    text = char_cpp.read_text()
    text, n = _insert_guard_after_opens(
        text,
        lambda line, _i, _ls: line.startswith("StringName::StringName(const char *from, bool p_static)")
        and line.endswith("{"),
        "return;",
    )
    _write(char_cpp, text, "string_name_cstr_ctor", n)

    ptrcall = root / "include/godot_cpp/core/builtin_ptrcall.hpp"
    text = ptrcall.read_text()
    # Backstop: every generated constructor goes through this helper.
    old = (
        "void _call_builtin_constructor(const GDExtensionPtrConstructor constructor, GDExtensionTypePtr base, Args... args) {\n"
        "\tstd::array<GDExtensionConstTypePtr, sizeof...(Args)> call_args = { { (GDExtensionConstTypePtr)args... } };\n"
        "\tconstructor(base, call_args.data());\n"
        "}\n"
    )
    new = (
        "void _call_builtin_constructor(const GDExtensionPtrConstructor constructor, GDExtensionTypePtr base, Args... args) {\n"
        "\tif (!builtin_destructors_enabled) {\n"
        "\t\treturn;\n"
        "\t}\n"
        "\tstd::array<GDExtensionConstTypePtr, sizeof...(Args)> call_args = { { (GDExtensionConstTypePtr)args... } };\n"
        "\tconstructor(base, call_args.data());\n"
        "}\n"
    )
    # The flag lives in this same namespace (godot::internal) once godot.hpp is patched.
    # Declare it here if this header is included first.
    extern_decl = "extern bool builtin_destructors_enabled;\n\n"
    if "extern bool builtin_destructors_enabled;" not in text:
        needle = "namespace internal {\n\n"
        if needle not in text:
            raise RuntimeError("scriptshot: namespace internal not found in %s" % ptrcall)
        text = text.replace(needle, needle + extern_decl, 1)
        counts["ptrcall_extern"] = 1
    else:
        counts["ptrcall_extern"] = 0
    if new not in text:
        if old not in text:
            raise RuntimeError("scriptshot: _call_builtin_constructor pattern not found in %s" % ptrcall)
        text = text.replace(old, new, 1)
        ptrcall.write_text(text)
        counts["ptrcall_ctor"] = 1
    else:
        counts["ptrcall_ctor"] = 0

    ref_hpp = root / "include/godot_cpp/classes/ref.hpp"
    text = ref_hpp.read_text()
    extern_ref = "namespace internal {\nextern bool builtin_destructors_enabled;\n}\n\n"
    if "extern bool builtin_destructors_enabled;" not in text:
        needle = "namespace godot {\n\n"
        if needle not in text:
            # file has "namespace godot {\n\n// Helper"
            raise RuntimeError("scriptshot: namespace godot not found in %s" % ref_hpp)
        text = text.replace(needle, needle + extern_ref, 1)
        counts["ref_extern"] = 1
    else:
        counts["ref_extern"] = 0
    text, n = _insert_guard_after_opens(
        text,
        lambda line, _i, _ls: line.strip() == "void unref() {",
        "return;",
        extra_lines=["reference = nullptr;"],
    )
    _write(ref_hpp, text, "ref_unref", n)
    if counts.get("ref_extern") and counts["ref_unref"] == 0:
        # extern was added; write even if unref was already guarded
        ref_hpp.write_text(text)

    return counts


HANDWRITTEN_REQUIRED = {
    "variant_assign": "Variant &Variant::operator=(const Variant &other) {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn *this;\n"
    "\t}",
    "variant_clear": "void Variant::clear() {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn;\n"
    "\t}",
    "variant_ctor": "Variant::Variant() {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn;\n"
    "\t}",
    "variant_copy_ctor": "Variant::Variant(const Variant &other) {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn;\n"
    "\t}",
    "string_cstr_ctor": "String::String(const char *from) {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn;\n"
    "\t}",
    "string_cstr_assign": "String &String::operator=(const char *p_str) {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn *this;\n"
    "\t}",
    "string_name_cstr_ctor": "StringName::StringName(const char *from, bool p_static) {\n"
    "\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\treturn;\n"
    "\t}",
    "ptrcall_ctor": "void _call_builtin_constructor(const GDExtensionPtrConstructor constructor, GDExtensionTypePtr base, Args... args) {\n"
    "\tif (!builtin_destructors_enabled) {\n"
    "\t\treturn;\n"
    "\t}",
    "ref_unref": "void unref() {\n"
    "\t\tif (!::godot::internal::builtin_destructors_enabled) {\n"
    "\t\t\treference = nullptr;\n"
    "\t\t\treturn;\n"
    "\t\t}",
}


def count_handwritten_shutdown_guards(native_root: Path) -> dict:
    root = native_root / "godot-cpp"
    files = {
        "variant_assign": root / "src/variant/variant.cpp",
        "variant_clear": root / "src/variant/variant.cpp",
        "variant_ctor": root / "src/variant/variant.cpp",
        "variant_copy_ctor": root / "src/variant/variant.cpp",
        "string_cstr_ctor": root / "src/variant/char_string.cpp",
        "string_cstr_assign": root / "src/variant/char_string.cpp",
        "string_name_cstr_ctor": root / "src/variant/char_string.cpp",
        "ptrcall_ctor": root / "include/godot_cpp/core/builtin_ptrcall.hpp",
        "ref_unref": root / "include/godot_cpp/classes/ref.hpp",
    }
    missing: list[str] = []
    present: list[str] = []
    for key, path in files.items():
        if not path.is_file():
            missing.append("%s (missing %s)" % (key, path))
            continue
        text = path.read_text()
        if HANDWRITTEN_REQUIRED[key] not in text:
            missing.append(key)
        else:
            present.append(key)
    return {"expected": list(HANDWRITTEN_REQUIRED), "present": present, "missing": missing}


def assert_handwritten_shutdown_guards(native_root: Path) -> dict:
    info = count_handwritten_shutdown_guards(native_root)
    if info["missing"]:
        raise RuntimeError(
            "scriptshot: handwritten shutdown guards failed: " + ", ".join(info["missing"])
        )
    return info


def assert_destructor_guards(native_root: Path) -> dict:
    info = count_destructor_guards(native_root)
    errors: list[str] = []
    if info["missing"]:
        errors.append("missing generated files: %s" % ", ".join(info["missing"]))
    if info["unguarded"]:
        errors.append("unguarded or mis-guarded shutdown paths: %s" % ", ".join(info["unguarded"]))
    if info["guarded"] != info["expected"]:
        errors.append(
            "guarded ~Type() count is %d, expected %d (extension_api has_destructor builtins)"
            % (info["guarded"], info["expected"])
        )
    if info["guarded_assign"] != info["expected_assign"]:
        errors.append(
            "guarded copy operator= count is %d, expected %d"
            % (info["guarded_assign"], info["expected_assign"])
        )
    if errors:
        raise RuntimeError("scriptshot: destructor guards failed: " + "; ".join(errors))
    handwritten = assert_handwritten_shutdown_guards(native_root)
    info["handwritten"] = handwritten["present"]
    return info


class ScriptshotBindingHooks:
    """Passed to godot-cpp as binding_hooks. Other hook points are no-ops."""

    def alter_builtin_class_header(self, builtin_api, result):
        return result

    def alter_builtin_class_source(self, builtin_api, result):
        has_dtor = builtin_api.get("has_destructor")
        out = []
        for i, line in enumerate(result):
            if (
                has_dtor
                and line == "\t_method_bindings.destructor(&opaque);"
                and i > 0
                and "::~" in result[i - 1]
                and result[i - 1].endswith("() {")
            ):
                out.extend(GUARD_LINES)
            elif ASSIGN_OPEN_RE.match(line):
                out.append(line)
                out.extend(ASSIGN_GUARD_LINES)
                continue
            elif (
                CTOR_OPEN_RE.match(line)
                and i + 1 < len(result)
                and _ctor_calls_engine(result[i + 1])
            ):
                out.append(line)
                out.extend(GUARD_LINES)
                continue
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
        "scriptshot: destructor guards ok: %d/%d ~Type(), %d/%d copy operator=, %d engine constructors, handwritten %s"
        % (
            info["guarded"],
            info["expected"],
            info["guarded_assign"],
            info["expected_assign"],
            info["guarded_ctor"],
            ",".join(info.get("handwritten") or []),
        )
    )
    for name in info["files"]:
        print("  %s" % name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
