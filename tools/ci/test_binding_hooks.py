#!/usr/bin/env python3
"""Unit tests for native/scriptshot_binding_hooks.py.

Covers the #109 ~Type() guard and the copy operator= guard that no-ops
builtin destroy/reconstruct after CORE deinitialize.

    python3 -m unittest tools/ci/test_binding_hooks.py -v
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
    GUARDED_DTOR_RE,
    ScriptshotBindingHooks,
    UNGUARDED_ASSIGN_RE,
    UNGUARDED_DTOR_RE,
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
""".splitlines()


def _join(lines: list[str]) -> str:
    return "\n".join(lines) + "\n"


def _hooked(has_destructor: bool = True) -> list[str]:
    return ScriptshotBindingHooks().alter_builtin_class_source(
        {"has_destructor": has_destructor, "name": "StringName"},
        list(RAW_STRING_NAME),
    )


class BindingHooksTest(unittest.TestCase):
    def test_unguarded_source_is_detected(self):
        text = _join(RAW_STRING_NAME)
        self.assertEqual(len(UNGUARDED_DTOR_RE.findall(text)), 1)
        self.assertEqual(len(GUARDED_DTOR_RE.findall(text)), 0)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 1)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 0)

    def test_hook_guards_destructor_and_copy_assign(self):
        text = _join(_hooked())
        self.assertEqual(len(GUARDED_DTOR_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_DTOR_RE.findall(text)), 0)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 0)
        self.assertIn("\n".join(GUARD_LINES), text)
        self.assertIn("\n".join(ASSIGN_GUARD_LINES), text)
        # Destructor early-return is void; assignment must return *this.
        self.assertIn("\t\treturn;\n", text)
        self.assertIn("\t\treturn *this;\n", text)

    def test_hook_leaves_move_assign_alone(self):
        hooked = _join(_hooked())
        move = (
            "StringName &StringName::operator=(StringName &&p_other) {\n"
            "	std::swap(opaque, p_other.opaque);\n"
            "	return *this;\n"
            "}"
        )
        self.assertIn(move, hooked)
        # The guard sits only in the const-ref overload, not the move one.
        before_move, _, _ = hooked.partition(move)
        self.assertIn("return *this;", before_move)
        self.assertNotIn("builtin_destructors_enabled", move)

    def test_hook_skips_types_without_destructor(self):
        out = _hooked(has_destructor=False)
        self.assertEqual(out, RAW_STRING_NAME)

    def test_missing_assign_guard_is_detected(self):
        # Mutation: only ~Type() is guarded, as on main after #109.
        text = _join(_hooked()).replace("\n".join(ASSIGN_GUARD_LINES) + "\n", "")
        self.assertEqual(len(GUARDED_DTOR_RE.findall(text)), 1)
        self.assertEqual(len(UNGUARDED_DTOR_RE.findall(text)), 0)
        self.assertEqual(len(GUARDED_ASSIGN_RE.findall(text)), 0)
        self.assertEqual(len(UNGUARDED_ASSIGN_RE.findall(text)), 1)


if __name__ == "__main__":
    unittest.main()
