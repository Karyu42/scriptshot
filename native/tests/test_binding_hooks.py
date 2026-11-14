#!/usr/bin/env python3
"""Unit tests for native/scriptshot_binding_hooks.py.

Covers generated ~Type(), copy operator= (including RID), engine-calling
constructors, and the handwritten shutdown-path snippets.

    python3 -m unittest native/tests/test_binding_hooks.py -v
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "native"))

from scriptshot_binding_hooks import (  # noqa: E402
    ASSIGN_GUARD_LINES,
    GUARD_LINES,
    GUARDED_ASSIGN_RE,
    GUARDED_CTOR_RE,
    GUARDED_DTOR_RE,
    HANDWRITTEN_REQUIRED,
    ScriptshotBindingHooks,
    UNGUARDED_ASSIGN_RE,
    UNGUARDED_CTOR_RE,
    UNGUARDED_DTOR_RE,
    _insert_guard_after_opens,
    apply_handwritten_shutdown_guards,
    count_handwritten_shutdown_guards,
)

# Mirrors generated godot-cpp 10.0.0-stable builtin sources (line list, no newlines).
RAW_STRING_NAME = """StringName::~StringName() {
	_method_bindings.destructor(&opaque);
}

StringName &StringName::operator=(const StringName &p_other) {
	_method_bindings.destructor(&opaque);
	::godot::internal::_call_builtin_constructor(_method_bindings.constructor_1, &opaque, &p_other);
	return *this;
}

StringName &StringName::operator=(StringName &&p_other) {
	std::swap(opaque, p_other.opaque);
	return *this;
}

StringName::StringName() {
	::godot::internal::_call_builtin_constructor(_method_bindings.constructor_0, &opaque);
}

StringName::StringName(const StringName &p_from) {
	::godot::internal::_call_builtin_constructor(_method_bindings.constructor_1, &opaque, &p_from);
}

StringName::StringName(StringName &&p_other) {
	std::swap(opaque, p_other.opaque);
}

StringName::StringName(const Variant *p_variant) {
	_method_bindings.from_variant_constructor(&opaque, p_variant->_native_ptr());
}
""".splitlines()

RAW_RID = """RID &RID::operator=(const RID &p_other) {
	::godot::internal::_call_builtin_constructor(_method_bindings.constructor_1, &opaque, &p_other);
	return *this;
}

RID &RID::operator=(RID &&p_other) {
	std::swap(opaque, p_other.opaque);
	return *this;
}

RID::RID() {
	::godot::internal::_call_builtin_constructor(_method_bindings.constructor_0, &opaque);
}

RID::RID(const RID &p_from) {
	::godot::internal::_call_builtin_constructor(_method_bindings.constructor_1, &opaque, &p_from);
}
""".splitlines()


def _join(lines: list[str]) -> str:
    return "\n".join(lines) + "\n"


def _hooked(source: list[str], has_destructor: bool = True, name: str = "StringName") -> list[str]:
    return ScriptshotBindingHooks().alter_builtin_class_source(
        {"has_destructor": has_destructor, "name": name},
        list(source),
    )


class BindingHooksTest(unittest.TestCase):
    def test_unguarded_source_is_detected(self):
        text = _join(RAW_STRING_NAME)
        self.assertEqual(len(UNGUARDED_DTOR_RE.findall(text)), 1)
        self.assertEqual(len(GUARDED_DTOR_RE.findall(text)), 0)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 1)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 0)
        self.assertGreaterEqual(len(UNGUARDED_CTOR_RE.findall(text)), 3)
        self.assertEqual(len(GUARDED_CTOR_RE.findall(text)), 0)

    def test_hook_guards_destructor_and_copy_assign(self):
        text = _join(_hooked(RAW_STRING_NAME))
        self.assertEqual(len(GUARDED_DTOR_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_DTOR_RE.findall(text)), 0)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 0)
        self.assertIn("\n".join(GUARD_LINES), text)
        self.assertIn("\n".join(ASSIGN_GUARD_LINES), text)
        self.assertIn("\t\treturn;\n", text)
        self.assertIn("\t\treturn *this;\n", text)

    def test_hook_guards_engine_constructors_and_leaves_move_ctor(self):
        text = _join(_hooked(RAW_STRING_NAME))
        self.assertEqual(len(UNGUARDED_CTOR_RE.findall(text)), 0)
        self.assertEqual(len(GUARDED_CTOR_RE.findall(text)), 3)
        move = (
            "StringName::StringName(StringName &&p_other) {\n"
            "	std::swap(opaque, p_other.opaque);\n"
            "}"
        )
        self.assertIn(move, text)
        self.assertNotIn("builtin_destructors_enabled", move)

    def test_hook_leaves_move_assign_alone(self):
        hooked = _join(_hooked(RAW_STRING_NAME))
        move = (
            "StringName &StringName::operator=(StringName &&p_other) {\n"
            "	std::swap(opaque, p_other.opaque);\n"
            "	return *this;\n"
            "}"
        )
        self.assertIn(move, hooked)
        before_move, _, _ = hooked.partition(move)
        self.assertIn("return *this;", before_move)
        self.assertNotIn("builtin_destructors_enabled", move)

    def test_hook_skips_types_without_destructor_except_assign_and_ctor(self):
        # A destructor-free type with no engine assign/ctor is unchanged.
        raw = ["int unused = 0;"]
        self.assertEqual(_hooked(raw, has_destructor=False, name="Vector2"), raw)

    def test_rid_copy_assign_and_ctors_are_guarded_without_destructor(self):
        text = _join(_hooked(RAW_RID, has_destructor=False, name="RID"))
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 0)
        self.assertEqual(len(GUARDED_CTOR_RE.findall(text)), 2)
        self.assertEqual(len(UNGUARDED_CTOR_RE.findall(text)), 0)
        move = (
            "RID &RID::operator=(RID &&p_other) {\n"
            "	std::swap(opaque, p_other.opaque);\n"
            "	return *this;\n"
            "}"
        )
        self.assertIn(move, text)

    def test_missing_assign_guard_is_detected(self):
        # Mutation: only ~Type() is guarded, as on main after #109.
        text = _join(_hooked(RAW_STRING_NAME)).replace("\n".join(ASSIGN_GUARD_LINES) + "\n", "")
        self.assertEqual(len(GUARDED_DTOR_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_DTOR_RE.findall(text)), 0)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 0)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 1)

    def test_missing_rid_assign_guard_is_detected(self):
        text = _join(RAW_RID)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 1)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 0)


class HandwrittenGuardTest(unittest.TestCase):
    def test_insert_guard_is_idempotent_and_returns_this(self):
        raw = "String &String::operator=(const char *p_str) {\n\t*this = String(p_str);\n\treturn *this;\n}\n"

        def is_open(line, _i, _ls):
            return line.startswith("String &String::operator=") and line.endswith("{")

        once, n1 = _insert_guard_after_opens(raw, is_open, "return *this;")
        twice, n2 = _insert_guard_after_opens(once, is_open, "return *this;")
        self.assertEqual(n1, 1)
        self.assertEqual(n2, 0)
        self.assertEqual(once, twice)
        self.assertIn("return *this;", once)
        self.assertEqual(once.count("builtin_destructors_enabled"), 1)
        self.assertIn(HANDWRITTEN_REQUIRED["string_cstr_assign"], once)

    def test_required_snippets_match_expected_shapes(self):
        self.assertIn("return *this;", HANDWRITTEN_REQUIRED["variant_assign"])
        self.assertIn("void Variant::clear()", HANDWRITTEN_REQUIRED["variant_clear"])
        self.assertIn("reference = nullptr;", HANDWRITTEN_REQUIRED["ref_unref"])
        self.assertIn("builtin_destructors_enabled", HANDWRITTEN_REQUIRED["ptrcall_ctor"])

    def test_apply_on_scratch_tree(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            native = Path(tmp)
            # Minimal tree with just the handwritten files (no gen/).
            (native / "godot-cpp/src/variant").mkdir(parents=True)
            (native / "godot-cpp/include/godot_cpp/core").mkdir(parents=True)
            (native / "godot-cpp/include/godot_cpp/classes").mkdir(parents=True)
            (native / "godot-cpp/src/variant/variant.cpp").write_text(
                "Variant::Variant() {\n"
                "\t::godot::gdextension_interface::variant_new_nil(_native_ptr());\n"
                "}\n"
                "Variant::Variant(const Variant &other) {\n"
                "\t::godot::gdextension_interface::variant_new_copy(_native_ptr(), other._native_ptr());\n"
                "}\n"
                "Variant &Variant::operator=(const Variant &other) {\n"
                "\tif (unlikely(this == &other)) {\n"
                "\t\treturn *this;\n"
                "\t}\n"
                "\tclear();\n"
                "\t::godot::gdextension_interface::variant_new_copy(_native_ptr(), other._native_ptr());\n"
                "\treturn *this;\n"
                "}\n"
                "void Variant::clear() {\n"
                "\t::godot::gdextension_interface::variant_destroy(_native_ptr());\n"
                "\t::godot::gdextension_interface::variant_new_nil(_native_ptr());\n"
                "}\n"
            )
            (native / "godot-cpp/src/variant/char_string.cpp").write_text(
                "String::String(const char *from) {\n"
                "\t::godot::gdextension_interface::string_new_with_latin1_chars(_native_ptr(), from);\n"
                "}\n"
                "String &String::operator=(const char *p_str) {\n"
                "\t*this = String(p_str);\n"
                "\treturn *this;\n"
                "}\n"
                "StringName::StringName(const char *from, bool p_static) {\n"
                "\t::godot::gdextension_interface::string_name_new_with_latin1_chars(&opaque, from, p_static);\n"
                "}\n"
            )
            (native / "godot-cpp/include/godot_cpp/core/builtin_ptrcall.hpp").write_text(
                "namespace godot {\n\n"
                "namespace internal {\n\n"
                "template <typename... Args>\n"
                "void _call_builtin_constructor(const GDExtensionPtrConstructor constructor, GDExtensionTypePtr base, Args... args) {\n"
                "\tstd::array<GDExtensionConstTypePtr, sizeof...(Args)> call_args = { { (GDExtensionConstTypePtr)args... } };\n"
                "\tconstructor(base, call_args.data());\n"
                "}\n"
                "} // namespace internal\n"
                "} // namespace godot\n"
            )
            (native / "godot-cpp/include/godot_cpp/classes/ref.hpp").write_text(
                "namespace godot {\n\n"
                "// Helper class for RefCounted objects, same as Godot one.\n"
                "template <typename T>\n"
                "class Ref {\n"
                "\tvoid unref() {\n"
                "\t\tif (reference) {\n"
                "\t\t\treference = nullptr;\n"
                "\t\t}\n"
                "\t}\n"
                "};\n"
                "} // namespace godot\n"
            )
            counts = apply_handwritten_shutdown_guards(native)
            self.assertGreater(counts["variant_assign"], 0)
            self.assertGreater(counts["variant_clear"], 0)
            self.assertGreater(counts["variant_ctor"], 0)
            self.assertGreater(counts["string_cstr_ctor"], 0)
            self.assertGreater(counts["string_cstr_assign"], 0)
            self.assertGreater(counts["string_name_cstr_ctor"], 0)
            self.assertGreater(counts["ptrcall_ctor"], 0)
            self.assertGreater(counts["ref_unref"], 0)
            info = count_handwritten_shutdown_guards(native)
            self.assertEqual(info["missing"], [])
            # Second apply is a no-op.
            again = apply_handwritten_shutdown_guards(native)
            self.assertTrue(all(v == 0 for k, v in again.items() if k not in ("ptrcall_extern", "ref_extern")))
            self.assertEqual(count_handwritten_shutdown_guards(native)["missing"], [])


if __name__ == "__main__":
    unittest.main()
