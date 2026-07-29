#!/usr/bin/env python3
"""Verify that every Python evaluator dispatch head has a native C++ path.

This is migration-only development tooling.  It statically inventories the
Python compatibility evaluator's top-level dispatch functions, then checks the
native evaluator and REPL dispatch sites.  It does not participate in the C++
runtime and must be paired with the behavioral differential gates.
"""

from __future__ import annotations

import ast
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
PYTHON_SOURCE = ROOT / "src" / "tungsten"
CPP_EVALUATOR = ROOT / "cpp" / "src" / "evaluator.cpp"
CPP_REPL = ROOT / "cpp" / "src" / "repl.cpp"

# A lower count means that this inventory stopped recognizing part of the
# compatibility dispatcher.  A higher count is allowed and must still be
# covered by C++.
BASELINE_DISPATCH_HEAD_COUNT = 537

DISPATCH_FUNCTIONS = {
    "evaluate_once",
    "_evaluate_algebraic_functions",
    "_evaluate_boolean_logic",
    "_evaluate_inequality",
    "_evaluate_integer_arithmetic",
    "_evaluate_integer_relation",
    "_evaluate_integer_special_functions",
    "_evaluate_numeric_arithmetic",
    "_evaluate_numeric_constructor",
    "_evaluate_numeric_relation",
    "_evaluate_numeric_special_functions",
    "_evaluate_polynomial_functions",
    "_evaluate_simple_predicates",
}

SESSION_DISPATCH_HEADS = {
    "Exit",
    "Quit",
}


def _string_constants(node: ast.AST) -> set[str]:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return {node.value}
    if isinstance(node, (ast.List, ast.Set, ast.Tuple)):
        return {
            element.value
            for element in node.elts
            if isinstance(element, ast.Constant) and isinstance(element.value, str)
        }
    return set()


def _short_name(name: str) -> str:
    return name.rsplit("`", 1)[-1]


def _is_head_comparison(node: ast.Compare) -> bool:
    left = node.left
    if isinstance(left, ast.Name):
        return "head" in left.id or left.id in {"function", "name"}
    return (
        isinstance(left, ast.Attribute)
        and left.attr == "name"
        and isinstance(left.value, ast.Name)
        and "head" in left.value.id
    )


def python_dispatch_heads() -> set[str]:
    heads: set[str] = set()
    expression_source = ""

    for path in sorted(PYTHON_SOURCE.glob("expression*.py")):
        source = path.read_text(encoding="utf-8")
        if path.name == "expression.py":
            expression_source = source
        module = ast.parse(source, filename=str(path))
        for function in module.body:
            if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if function.name not in DISPATCH_FUNCTIONS:
                continue
            for node in ast.walk(function):
                if (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "has_head"
                    and node.args
                ):
                    heads.update(_short_name(name) for name in _string_constants(node.args[0]))
                elif isinstance(node, ast.Compare) and _is_head_comparison(node):
                    for comparator in node.comparators:
                        heads.update(
                            _short_name(name) for name in _string_constants(comparator)
                        )

    # The generic transcendental dispatcher obtains these names from a
    # function table rather than spelling them in its top-level conditionals.
    expression_module = ast.parse(
        expression_source, filename=str(PYTHON_SOURCE / "expression.py")
    )
    transcendental_table = next(
        function
        for function in expression_module.body
        if isinstance(function, ast.FunctionDef)
        and function.name == "_sympy_unary_transcendental_function"
    )
    for node in ast.walk(transcendental_table):
        if isinstance(node, ast.Dict):
            for key in node.keys:
                heads.update(_string_constants(key))

    degree_names = re.search(
        r"_DEGREE_TRANSCENDENTAL_BASE_NAMES\s*=\s*\{([^}]+)\}",
        expression_source,
        re.DOTALL,
    )
    if degree_names is None:
        raise RuntimeError("Could not locate the degree transcendental dispatch table.")
    heads.update(
        base_name + "Degrees"
        for base_name in re.findall(r'"([A-Za-z]+)"', degree_names.group(1))
    )
    return heads


def cpp_evaluator_heads() -> set[str]:
    source = CPP_EVALUATOR.read_text(encoding="utf-8")
    heads = set(
        re.findall(
            r'(?:function|operation|name|head_name|argument_dispatch_name)\s*'
            r'(?:==|!=)\s*"([A-Za-z$][A-Za-z0-9$`]*)"',
            source,
        )
    )
    heads.update(
        re.findall(
            r'(?:has_head|is_symbol)\([^;\n]*?"([A-Za-z$][A-Za-z0-9$`]*)"',
            source,
        )
    )
    for collection in re.finditer(
        r"(?:heads|names|functions)\s*\{([^}]+)\}", source, re.DOTALL
    ):
        heads.update(
            re.findall(r'"([A-Za-z$][A-Za-z0-9$`]*)"', collection.group(1))
        )
    return {_short_name(name) for name in heads}


def cpp_repl_heads() -> set[str]:
    source = CPP_REPL.read_text(encoding="utf-8")
    return {
        head
        for head in SESSION_DISPATCH_HEADS
        if re.search(rf'"{re.escape(head)}"', source) is not None
    }


def main() -> int:
    python_heads = python_dispatch_heads()
    evaluator_heads = cpp_evaluator_heads()
    repl_heads = cpp_repl_heads()
    missing = sorted(python_heads - evaluator_heads - repl_heads)
    misplaced_session_heads = sorted(
        (python_heads - evaluator_heads) - SESSION_DISPATCH_HEADS
    )

    print(
        "Python dispatch heads: "
        f"{len(python_heads)}; native evaluator: "
        f"{len(python_heads & evaluator_heads)}; native REPL/session: "
        f"{len((python_heads - evaluator_heads) & repl_heads)}."
    )

    if len(python_heads) < BASELINE_DISPATCH_HEAD_COUNT:
        print(
            "Dispatch inventory regressed below the reviewed baseline: "
            f"{len(python_heads)} < {BASELINE_DISPATCH_HEAD_COUNT}.",
            file=sys.stderr,
        )
        return 1
    if misplaced_session_heads:
        print(
            "Python heads lack an evaluator path and are not session-owned: "
            + ", ".join(misplaced_session_heads),
            file=sys.stderr,
        )
        return 1
    if missing:
        print("Missing native dispatch heads: " + ", ".join(missing), file=sys.stderr)
        return 1
    if (python_heads - evaluator_heads) != SESSION_DISPATCH_HEADS:
        unexpected = sorted((python_heads - evaluator_heads) ^ SESSION_DISPATCH_HEADS)
        print(
            "The reviewed session-only dispatch boundary changed: "
            + ", ".join(unexpected),
            file=sys.stderr,
        )
        return 1

    print("All Python evaluator dispatch heads have an explicit native C++ owner.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
