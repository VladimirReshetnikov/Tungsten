#!/usr/bin/env python3
"""Verify explicit Haskell ownership of every Python evaluator dispatch head.

This is migration-only development tooling.  It inventories the Python
compatibility evaluator's reviewed top-level dispatch functions, then inspects
only the Haskell runtime bindings that actually dispatch evaluator, session,
or REPL work.  General Haskell string literals (including documentation and
tests) are deliberately not evidence of ownership.

The static check must be paired with behavioral differential gates: an
explicit dispatch path proves ownership, not semantic parity by itself.
"""

from __future__ import annotations

import ast
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
PYTHON_SOURCE = ROOT / "src" / "tungsten"
HASKELL_SOURCE = ROOT / "haskell" / "src" / "Tungsten"
HASKELL_EVALUATOR = HASKELL_SOURCE / "Evaluate.hs"
HASKELL_EXPRESSION = HASKELL_SOURCE / "Expression.hs"
HASKELL_NUMERIC = HASKELL_SOURCE / "NumericAlgebra.hs"
HASKELL_POLYNOMIAL = HASKELL_SOURCE / "PolynomialAlgebra.hs"
HASKELL_ALGEBRAIC = HASKELL_SOURCE / "AlgebraicRoots.hs"
HASKELL_STRING_PATTERNS = HASKELL_SOURCE / "StringPatterns.hs"
HASKELL_TEXTUAL_FORMS = HASKELL_SOURCE / "TextualForms.hs"
HASKELL_SESSION = HASKELL_SOURCE / "Session.hs"
HASKELL_REPL = HASKELL_SOURCE / "Repl.hs"

# A lower count means that this inventory stopped recognizing part of the
# compatibility dispatcher.  A higher count is allowed, but every new head is
# immediately subject to the same Haskell ownership requirement.
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

# These bindings are the reviewed Haskell runtime dispatch sites.  Keep this a
# list of mechanisms, never a list of heads: a head only passes when it is
# extracted from the current implementation of one of these mechanisms.
EVALUATOR_CASE_BINDINGS = {
    "evaluateAt",
    "reduceCall",
    "reduceBuiltin",
}
NUMERIC_DISPATCH_BINDING = "reduceNumericBuiltin"
POLYNOMIAL_DISPATCH_BINDING = "reducePolynomialBuiltin"
ALGEBRAIC_DISPATCH_BINDING = "reduceAlgebraicRootBuiltin"
# These bindings dispatch Wolfram heads inside the string-pattern evaluator.
# Date-element and rendering cases are intentionally absent: their string
# tags are data formats, not evaluator dispatch ownership.
STRING_PATTERN_DISPATCH_BINDINGS = {
    "characterMatchesSymbol",
    "characterPredicateM",
    "flattenList",
    "flattenStringExpression",
    "matchCharacterPatternM",
    "matchStringPatternStatesM",
    "normalizeWhitespace",
    "ruleView",
    "singleCharacterPattern",
}
SESSION_CASE_BINDINGS = {
    "evaluateSessionAtRaw",
    "evaluateHeldSessionPatternBuiltin",
    "reduceSessionEvaluatedCall",
}
SESSION_COLLECTION_BINDINGS = {
    "inPlaceArithmeticVariants",
    "staticHeldHeadNames",
    "updateConstructors",
}
# Routing-only collections such as qualifiedAliasDispatchHeads and
# directSessionDispatchHead do not reduce anything themselves and therefore do
# not establish ownership.  heldPatternBuiltinHeads is similarly not credited
# wholesale; its implemented keys are read from the handler's case arms.
# History heads are session evaluator dispatch now; the REPL only owns exit
# recognition and supplies retained history through EvaluationSession.
REPL_CASE_BINDINGS = {
    "exitCode",
}

_TOP_LEVEL_DECLARATION = re.compile(
    r"^(?:(?P<binding>[a-z][A-Za-z0-9_']*)\b|data\b|newtype\b|type\b|"
    r"class\b|instance\b)"
)
_STRING_LITERAL = re.compile(r'"([A-Za-z$][A-Za-z0-9$`]*)"')


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
    """Return the same Python AST inventory used by the native C++ gate."""

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
                    heads.update(
                        _short_name(name) for name in _string_constants(node.args[0])
                    )
                elif isinstance(node, ast.Compare) and _is_head_comparison(node):
                    for comparator in node.comparators:
                        heads.update(
                            _short_name(name)
                            for name in _string_constants(comparator)
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


def _strip_haskell_comments(source: str) -> str:
    """Remove comments while preserving strings and line/column layout."""

    result: list[str] = []
    index = 0
    block_depth = 0
    in_string = False
    in_character = False
    escaped = False
    while index < len(source):
        if block_depth:
            if source.startswith("{-", index):
                block_depth += 1
                result.extend("  ")
                index += 2
            elif source.startswith("-}", index):
                block_depth -= 1
                result.extend("  ")
                index += 2
            else:
                character = source[index]
                result.append("\n" if character == "\n" else " ")
                index += 1
            continue

        if in_string:
            character = source[index]
            result.append(character)
            index += 1
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue

        if in_character:
            character = source[index]
            result.append(character)
            index += 1
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == "'":
                in_character = False
            continue

        if source.startswith("--", index):
            newline = source.find("\n", index)
            if newline == -1:
                result.extend(" " * (len(source) - index))
                break
            result.extend(" " * (newline - index))
            index = newline
            continue
        if source.startswith("{-", index):
            block_depth = 1
            result.extend("  ")
            index += 2
            continue

        character = source[index]
        result.append(character)
        index += 1
        if character == '"':
            in_string = True
        elif character == "'" and (
            index == 1
            or not (source[index - 2].isalnum() or source[index - 2] in "_'")
        ):
            in_character = True

    if block_depth:
        raise RuntimeError("Unterminated Haskell block comment.")
    if in_string:
        raise RuntimeError("Unterminated Haskell string literal.")
    if in_character:
        raise RuntimeError("Unterminated Haskell character literal.")
    return "".join(result)


def _binding_source(source: str, binding_name: str) -> str:
    """Return all equations belonging to one top-level Haskell binding."""

    lines = source.splitlines(keepends=True)
    start: int | None = None
    for index, line in enumerate(lines):
        match = _TOP_LEVEL_DECLARATION.match(line)
        if match is None or match.group("binding") != binding_name:
            continue
        if "::" in line and "=" not in line:
            continue
        # Guarded equations commonly put their first ``=`` on the following
        # indented line, so the unindented equation header is the boundary.
        start = index
        break
    if start is None:
        raise RuntimeError(f"Could not locate Haskell binding {binding_name!r}.")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        match = _TOP_LEVEL_DECLARATION.match(lines[index])
        if match is None:
            continue
        next_binding = match.group("binding")
        if next_binding == binding_name:
            continue
        end = index
        break
    return "".join(lines[start:end])


def _outer_case_prefixes(binding: str) -> list[str]:
    """Return pattern-and-guard prefixes for the binding's outermost case."""

    lines = binding.splitlines(keepends=True)
    case_index = next(
        (
            index
            for index, line in enumerate(lines)
            if re.search(r"(?:\bcase\b.*\bof\s*$|\\case\s*$)", line.rstrip())
        ),
        None,
    )
    if case_index is None:
        return []

    pattern_like = re.compile(
        r"(?:[a-z][A-Za-z0-9_']*@)?(?:Call|Symbol)\b|"
        r'"[A-Za-z$]|\(|_\s*(?:\||->)'
    )
    candidates: list[tuple[int, int]] = []
    for index in range(case_index + 1, len(lines)):
        line = lines[index]
        stripped = line.lstrip(" ")
        if not stripped.strip() or not pattern_like.match(stripped):
            continue
        indentation = len(line) - len(stripped)
        candidates.append((index, indentation))
    if not candidates:
        return []

    outer_indent = min(indentation for _, indentation in candidates)
    starts = [index for index, indentation in candidates if indentation == outer_indent]
    prefixes: list[str] = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        chunk = "".join(lines[start:end])
        arrow = chunk.find("->")
        if arrow != -1:
            prefixes.append(chunk[:arrow])
    return prefixes


def _case_dispatch_heads(binding: str) -> set[str]:
    """Extract only literals in outer case patterns and their guards."""

    return {
        _short_name(name)
        for prefix in _outer_case_prefixes(binding)
        for name in _STRING_LITERAL.findall(prefix)
    }


def _nested_dispatch_heads(binding: str) -> set[str]:
    """Extract literal case arms and explicit normalized-head comparisons.

    This is used only for reviewed evaluator bindings with local dispatch
    helpers.  Restricting the scan to those bindings prevents error messages,
    format names, rendered symbols, and other incidental literals elsewhere in
    the runtime module from becoming owners.
    """

    literal_arms = re.findall(
        r'^\s*(?:\(\s*)?"([A-Za-z$][A-Za-z0-9$`]*)"[^\n]*->',
        binding,
        re.MULTILINE,
    )
    normalized_comparisons = re.findall(
        r'\b(?:shortHead|shortSystemName)\s+[A-Za-z][A-Za-z0-9_\x27]*'
        r'\s*==\s*"([A-Za-z$][A-Za-z0-9$`]*)"',
        binding,
    )
    return {
        _short_name(name) for name in literal_arms + normalized_comparisons
    }


def _collection_dispatch_heads(binding: str) -> set[str]:
    """Extract keys/items from a collection actively consulted by dispatch."""

    # Dispatch collections in Session.hs are vertically formatted lists or
    # Map.fromList tuples.  Only the list item / tuple key is an owner; strings
    # in tuple values construct reducer implementation details and must not be
    # mistaken for additional dispatch keys.
    return {
        _short_name(name)
        for name in re.findall(
            r'^\s*(?:\[|,)\s*(?:\(\s*)?'
            r'"([A-Za-z$][A-Za-z0-9$`]*)"',
            binding,
            re.MULTILINE,
        )
    }


def _typed_atom_heads(expression_source: str, evaluator_binding: str) -> set[str]:
    """Extract native expression heads covered by atomic self-evaluation.

    Haskell represents values such as exact rationals and complexes as typed
    ``Expr`` constructors rather than ordinary ``Call`` nodes.  A constructor
    is credited only when ``headExpr`` gives it an explicit Wolfram head,
    ``isAtom`` does not classify it as structurally non-atomic, and the pure
    evaluator retains its generic self-evaluation branch.  This intentionally
    excludes ``Root`` and cannot credit parser-only call canonicalization.
    """

    if (
        re.search(
            r"^\s*_\s*->\s*Right expression\s*$", evaluator_binding, re.MULTILINE
        )
        is None
    ):
        raise RuntimeError("The evaluator no longer has its atomic self-evaluation branch.")

    head_binding = _binding_source(expression_source, "headExpr")
    atom_binding = _binding_source(expression_source, "isAtom")
    if re.search(r"^\s*_\s*->\s*True\s*$", atom_binding, re.MULTILINE) is None:
        raise RuntimeError("Could not locate the default atomic Expr classification.")

    head_by_constructor = dict(
        re.findall(
            r'^\s*([A-Z][A-Za-z0-9_]*)\b[^\n]*->\s*Symbol\s*'
            r'"([A-Za-z$][A-Za-z0-9$`]*)"\s*$',
            head_binding,
            re.MULTILINE,
        )
    )
    non_atomic_constructors = set(
        re.findall(
            r"^\s*([A-Z][A-Za-z0-9_]*)\b[^\n]*->\s*False\s*$",
            atom_binding,
            re.MULTILINE,
        )
    )
    return {
        _short_name(head)
        for constructor, head in head_by_constructor.items()
        if constructor not in non_atomic_constructors
    }


def _canonical_boolean_atom_heads(
    evaluator_source: str, evaluator_binding: str
) -> set[str]:
    """Extract canonical Boolean symbols covered by symbol self-evaluation."""

    if (
        re.search(
            r"^\s*_\s*->\s*Right expression\s*$", evaluator_binding, re.MULTILINE
        )
        is None
    ):
        raise RuntimeError("The evaluator no longer has its atomic self-evaluation branch.")
    boolean_binding = _binding_source(evaluator_source, "boolean")
    heads = {
        _short_name(name)
        for name in re.findall(
            r'^boolean\s+[A-Z][A-Za-z0-9_]*\s*=\s*Symbol\s*'
            r'"([A-Za-z$][A-Za-z0-9$`]*)"\s*$',
            boolean_binding,
            re.MULTILINE,
        )
    }
    if not heads:
        raise RuntimeError("Could not locate canonical Boolean symbol constructors.")
    return heads


def haskell_evaluator_heads() -> set[str]:
    """Return owners from the connected, kernel-free evaluator modules."""

    evaluator_source = _strip_haskell_comments(
        HASKELL_EVALUATOR.read_text(encoding="utf-8")
    )
    expression_source = _strip_haskell_comments(
        HASKELL_EXPRESSION.read_text(encoding="utf-8")
    )
    numeric_source = _strip_haskell_comments(
        HASKELL_NUMERIC.read_text(encoding="utf-8")
    )
    polynomial_source = _strip_haskell_comments(
        HASKELL_POLYNOMIAL.read_text(encoding="utf-8")
    )
    algebraic_source = _strip_haskell_comments(
        HASKELL_ALGEBRAIC.read_text(encoding="utf-8")
    )
    string_pattern_source = _strip_haskell_comments(
        HASKELL_STRING_PATTERNS.read_text(encoding="utf-8")
    )
    # Reading this source is intentional even though its public dispatch keys
    # are already the case arms in Evaluate.reduceBuiltin.  The connectivity
    # assertion below prevents those keys from being credited if the delegate
    # is removed.
    _strip_haskell_comments(HASKELL_TEXTUAL_FORMS.read_text(encoding="utf-8"))

    heads: set[str] = set()
    evaluator_bindings = {
        binding_name: _binding_source(evaluator_source, binding_name)
        for binding_name in EVALUATOR_CASE_BINDINGS
    }
    for binding in evaluator_bindings.values():
        heads.update(_case_dispatch_heads(binding))
    heads.update(
        _typed_atom_heads(expression_source, evaluator_bindings["evaluateAt"])
    )
    heads.update(
        _canonical_boolean_atom_heads(
            evaluator_source, evaluator_bindings["evaluateAt"]
        )
    )

    numeric_binding = _binding_source(numeric_source, NUMERIC_DISPATCH_BINDING)
    if "NumericAlgebra.reduceNumericBuiltin" not in evaluator_bindings["reduceBuiltin"]:
        raise RuntimeError(
            "The exact-numeric dispatch binding is no longer connected to reduceBuiltin."
        )
    heads.update(
        _short_name(name)
        for name in re.findall(
            rf"^{re.escape(NUMERIC_DISPATCH_BINDING)}\s+\""
            r"([A-Za-z$][A-Za-z0-9$`]*)\"",
            numeric_binding,
            re.MULTILINE,
        )
    )
    heads.update(_case_dispatch_heads(numeric_binding))

    polynomial_binding = _binding_source(
        polynomial_source, POLYNOMIAL_DISPATCH_BINDING
    )
    if (
        "PolynomialAlgebra.reducePolynomialBuiltin"
        not in evaluator_bindings["reduceBuiltin"]
    ):
        raise RuntimeError(
            "The polynomial dispatch binding is no longer connected to reduceBuiltin."
        )
    heads.update(_case_dispatch_heads(polynomial_binding))

    algebraic_binding = _binding_source(
        algebraic_source, ALGEBRAIC_DISPATCH_BINDING
    )
    if (
        "AlgebraicRoots.reduceAlgebraicRootBuiltin"
        not in evaluator_bindings["reduceBuiltin"]
    ):
        raise RuntimeError(
            "The algebraic-root dispatch binding is no longer connected to reduceBuiltin."
        )
    heads.update(_case_dispatch_heads(algebraic_binding))

    if "TextualForms." not in evaluator_bindings["reduceBuiltin"]:
        raise RuntimeError(
            "TextualForms entry dispatch is no longer connected to reduceBuiltin."
        )
    if "SP." not in evaluator_source:
        raise RuntimeError(
            "StringPatterns is no longer connected to the pure evaluator."
        )
    for binding_name in STRING_PATTERN_DISPATCH_BINDINGS:
        heads.update(
            _nested_dispatch_heads(
                _binding_source(string_pattern_source, binding_name)
            )
        )
    return heads


def haskell_session_heads() -> set[str]:
    source = _strip_haskell_comments(HASKELL_SESSION.read_text(encoding="utf-8"))
    heads: set[str] = set()
    case_bindings = {
        binding_name: _binding_source(source, binding_name)
        for binding_name in SESSION_CASE_BINDINGS
    }
    for binding in case_bindings.values():
        heads.update(_case_dispatch_heads(binding))
    raw_dispatch = case_bindings["evaluateSessionAtRaw"]
    if "evaluateHeldSessionPatternBuiltin" not in raw_dispatch:
        raise RuntimeError(
            "The held-pattern handler is no longer connected to evaluateSessionAtRaw."
        )
    for binding_name in SESSION_COLLECTION_BINDINGS:
        if binding_name not in raw_dispatch:
            raise RuntimeError(
                f"Session dispatch no longer consults {binding_name!r}."
            )
        heads.update(
            _collection_dispatch_heads(_binding_source(source, binding_name))
        )
    return heads


def haskell_repl_heads() -> set[str]:
    source = _strip_haskell_comments(HASKELL_REPL.read_text(encoding="utf-8"))
    heads: set[str] = set()
    for binding_name in REPL_CASE_BINDINGS:
        heads.update(_case_dispatch_heads(_binding_source(source, binding_name)))
    return heads


def main() -> int:
    python_heads = python_dispatch_heads()
    pure_evaluator_heads = haskell_evaluator_heads()
    session_heads = haskell_session_heads()
    repl_heads = haskell_repl_heads()
    owned_heads = pure_evaluator_heads | session_heads | repl_heads
    missing = sorted(python_heads - owned_heads)

    pure_evaluator_owned = python_heads & pure_evaluator_heads
    session_owned = python_heads & session_heads
    repl_owned = python_heads & repl_heads
    session_only = (python_heads - pure_evaluator_heads) & (session_heads | repl_heads)
    print(
        "Python dispatch heads: "
        f"{len(python_heads)}; Haskell pure evaluator modules: "
        f"{len(pure_evaluator_owned)}; "
        f"Haskell session: {len(session_owned)}; Haskell REPL: {len(repl_owned)}; "
        f"session/REPL-only: {len(session_only)}; "
        f"owned union: {len(python_heads & owned_heads)}.",
        flush=True,
    )

    failed = False
    if len(python_heads) < BASELINE_DISPATCH_HEAD_COUNT:
        print(
            "Dispatch inventory regressed below the reviewed baseline: "
            f"{len(python_heads)} < {BASELINE_DISPATCH_HEAD_COUNT}.",
            file=sys.stderr,
        )
        failed = True
    if missing:
        print(
            f"Missing Haskell dispatch heads ({len(missing)}): " + ", ".join(missing),
            file=sys.stderr,
        )
        failed = True
    if failed:
        return 1

    print("All Python evaluator dispatch heads have an explicit Haskell owner.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
