from __future__ import annotations

import re
import unittest

from tungsten.discovery import discover_installation
from tungsten.expression import evaluate
from tungsten.expression import parse_full_form
from tungsten.expression import parse_input_form
from tungsten.expression import parse_standard_form


class ExpressionParserTests(unittest.TestCase):
    def test_parse_full_form(self) -> None:
        expr = parse_full_form("Plus[1, Times[2, x]]")
        self.assertEqual(expr.to_full_form(), "Plus[1, Times[2, x]]")

    def test_parse_input_form_with_implicit_times_and_power(self) -> None:
        expr = parse_input_form("1 + 2 x^3")
        self.assertEqual(expr.to_full_form(), "Plus[1, Times[2, Power[x, 3]]]")

    def test_parse_standard_form_subset_with_prefix_and_postfix_application(self) -> None:
        expr = parse_standard_form("f @ x // g")
        self.assertEqual(expr.to_full_form(), "g[f[x]]")

    def test_parse_part_and_span_syntax(self) -> None:
        expr = parse_input_form("expr[[1, 2 ;; -1]]")
        self.assertEqual(expr.to_full_form(), "Part[expr, 1, Span[2, -1]]")

    def test_parser_skips_comments_inside_expression(self) -> None:
        expr = parse_input_form('f["alpha", (* ignored *) beta]')
        self.assertEqual(expr.to_full_form(), 'f["alpha", beta]')

    def test_parser_preserves_inline_box_escapes_inside_strings(self) -> None:
        expr = parse_input_form(r'"hello \!\(\*GraphicsBox[{CircleBox[]}]\)"')
        self.assertEqual(expr.to_input_form(), r'"hello \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)"')
        self.assertEqual(expr.to_dict()["inline_boxes"][0]["box_expression"], "GraphicsBox[{CircleBox[]}]")


class StandardFormBoxNotebookExamplesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        installation = discover_installation()
        if not installation.docs_roots:
            raise unittest.SkipTest("No local Wolfram documentation roots were discovered.")
        cls.docs_roots = installation.docs_roots

    @classmethod
    def _load_reference_notebook(cls, notebook_name: str) -> str:
        for docs_root in cls.docs_roots:
            candidate = docs_root / "ReferencePages" / "Symbols" / notebook_name
            if candidate.exists():
                return candidate.read_text(encoding="utf-8")
        raise unittest.SkipTest(f"Could not find local documentation notebook {notebook_name}.")

    @classmethod
    def _extract_example(cls, notebook_name: str, pattern: str) -> str:
        notebook_text = cls._load_reference_notebook(notebook_name)
        match = re.search(pattern, notebook_text, flags=re.DOTALL)
        if match is None:
            raise AssertionError(f"Could not find example matching {pattern!r} in {notebook_name}.")
        return match.group(0)

    def test_fraction_box_example_from_docs_unwraps_styled_operands(self) -> None:
        source = self._extract_example(
            "FractionBox.nb",
            r'FractionBox\[\s*StyleBox\["x",\s*"TI"\],\s*StyleBox\["y",\s*"TI"\]\s*\]',
        )
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "Times[x, Power[y, -1]]")

    def test_sqrt_box_display_form_example_from_docs_parses_as_half_power(self) -> None:
        source = self._extract_example(
            "SqrtBox.nb",
            r'TagBox\[\s*SqrtBox\["x"\],\s*DisplayForm\s*\]',
        )
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "Power[x, Rational[1, 2]]")

    def test_radical_box_traditional_form_example_from_docs_parses_as_inverse_power(self) -> None:
        source = self._extract_example(
            "RadicalBox.nb",
            r'FormBox\[\s*RadicalBox\["x",\s*"3"\],\s*TraditionalForm\s*\]',
        )
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "Power[x, Rational[1, 3]]")

    def test_superscript_box_example_from_docs_unwraps_styled_operands(self) -> None:
        source = self._extract_example(
            "SuperscriptBox.nb",
            r'SuperscriptBox\[\s*StyleBox\["x",\s*"TI"\],\s*StyleBox\["y",\s*"TI"\]\s*\]',
        )
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "Power[x, y]")

    def test_superscript_box_with_fractional_rowbox_exponent_matches_radical_docs(self) -> None:
        source = self._extract_example(
            "RadicalBox.nb",
            r'SuperscriptBox\["x",\s*RowBox\[\{"1",\s*"/",\s*"3"\}\]\s*\]',
        )
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "Power[x, Rational[1, 3]]")

    def test_fraction_box_with_nested_boxes_from_docs_keeps_structure(self) -> None:
        source = self._extract_example(
            "FractionBox.nb",
            r'TagBox\[\s*FractionBox\[\s*SuperscriptBox\["x",\s*"3"\],\s*RowBox\[\{"1",\s*"\+",\s*"a",\s*" ",\s*"b"\}\]\s*\],\s*DisplayForm\s*\]',
        )
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "Times[Power[x, 3], Power[Plus[1, Times[a, b]], -1]]")


class ExpressionEvaluationTests(unittest.TestCase):
    def test_length(self) -> None:
        result = evaluate(parse_input_form("Length[{a, b, c}]"))
        self.assertEqual(result.to_full_form(), "3")

    def test_depth(self) -> None:
        result = evaluate(parse_input_form("Depth[f[a, g[b]]]"))
        self.assertEqual(result.to_full_form(), "3")

    def test_part_with_selector_list(self) -> None:
        result = evaluate(parse_input_form("Part[f[a, b, c], {1, 3}]"))
        self.assertEqual(result.to_full_form(), "f[a, c]")

    def test_extract_multiple_positions(self) -> None:
        result = evaluate(parse_input_form("Extract[f[a, g[b]], {{1}, {2, 1}}]"))
        self.assertEqual(result.to_full_form(), "List[a, b]")

    def test_level_negative_one_returns_leaves(self) -> None:
        result = evaluate(parse_input_form("Level[f[a, g[b]], -1]"))
        self.assertEqual(result.to_full_form(), "List[a, b]")

    def test_level_positive_two_returns_first_two_levels(self) -> None:
        result = evaluate(parse_input_form("Level[f[a, g[b]], 2]"))
        self.assertEqual(result.to_full_form(), "List[a, g[b], b]")

    def test_first_last_and_defaults(self) -> None:
        first_result = evaluate(parse_input_form("First[f[a, b, c]]"))
        last_result = evaluate(parse_input_form("Last[f[a, b, c]]"))
        default_result = evaluate(parse_input_form("First[f[], Missing[none]]"))
        self.assertEqual(first_result.to_full_form(), "a")
        self.assertEqual(last_result.to_full_form(), "c")
        self.assertEqual(default_result.to_full_form(), "Missing[none]")

    def test_rest_and_most(self) -> None:
        rest_result = evaluate(parse_input_form("Rest[f[a, b, c]]"))
        most_result = evaluate(parse_input_form("Most[f[a, b, c]]"))
        self.assertEqual(rest_result.to_full_form(), "f[b, c]")
        self.assertEqual(most_result.to_full_form(), "f[a, b]")

    def test_take_and_drop_support_integer_and_range_specs(self) -> None:
        take_positive = evaluate(parse_input_form("Take[f[a, b, c, d], 2]"))
        take_negative = evaluate(parse_input_form("Take[f[a, b, c, d], -2]"))
        take_range = evaluate(parse_input_form("Take[f[a, b, c, d, e], {2, 5, 2}]"))
        drop_range = evaluate(parse_input_form("Drop[f[a, b, c, d, e], {2, 5, 2}]"))
        self.assertEqual(take_positive.to_full_form(), "f[a, b]")
        self.assertEqual(take_negative.to_full_form(), "f[c, d]")
        self.assertEqual(take_range.to_full_form(), "f[b, d]")
        self.assertEqual(drop_range.to_full_form(), "f[a, c, e]")

    def test_take_and_drop_support_all_and_singleton_list_specs(self) -> None:
        take_all = evaluate(parse_input_form("Take[f[a, b, c], All]"))
        take_singleton = evaluate(parse_input_form("Take[f[a, b, c], {2}]"))
        drop_singleton = evaluate(parse_input_form("Drop[f[a, b, c], {2}]"))
        self.assertEqual(take_all.to_full_form(), "f[a, b, c]")
        self.assertEqual(take_singleton.to_full_form(), "f[b]")
        self.assertEqual(drop_singleton.to_full_form(), "f[a, c]")

    def test_append_prepend_and_join_preserve_head(self) -> None:
        append_result = evaluate(parse_input_form("Append[f[a], b]"))
        prepend_result = evaluate(parse_input_form("Prepend[f[a], b]"))
        join_result = evaluate(parse_input_form("Join[f[a], f[b, c]]"))
        self.assertEqual(append_result.to_full_form(), "f[a, b]")
        self.assertEqual(prepend_result.to_full_form(), "f[b, a]")
        self.assertEqual(join_result.to_full_form(), "f[a, b, c]")

    def test_reverse_and_rotate(self) -> None:
        reverse_result = evaluate(parse_input_form("Reverse[f[a, b, c]]"))
        left_result = evaluate(parse_input_form("RotateLeft[f[a, b, c], 2]"))
        right_result = evaluate(parse_input_form("RotateRight[f[a, b, c], 2]"))
        self.assertEqual(reverse_result.to_full_form(), "f[c, b, a]")
        self.assertEqual(left_result.to_full_form(), "f[c, a, b]")
        self.assertEqual(right_result.to_full_form(), "f[b, c, a]")

    def test_flatten_same_head_recursively(self) -> None:
        flatten_all = evaluate(parse_input_form("Flatten[f[a, f[b, f[c]], d]]"))
        flatten_one = evaluate(parse_input_form("Flatten[f[a, f[b, f[c]], d], 1]"))
        self.assertEqual(flatten_all.to_full_form(), "f[a, b, c, d]")
        self.assertEqual(flatten_one.to_full_form(), "f[a, b, f[c], d]")

    def test_delete_removes_parts_by_position(self) -> None:
        delete_single = evaluate(parse_input_form("Delete[f[a, b, c], 2]"))
        delete_nested = evaluate(parse_input_form("Delete[f[a, g[b, c], d], {2, 1}]"))
        delete_multiple = evaluate(parse_input_form("Delete[f[a, b, c, d], {{2}, {4}}]"))
        self.assertEqual(delete_single.to_full_form(), "f[a, c]")
        self.assertEqual(delete_nested.to_full_form(), "f[a, g[c], d]")
        self.assertEqual(delete_multiple.to_full_form(), "f[a, c]")

    def test_replace_part_updates_structure_and_ignores_missing_positions(self) -> None:
        replace_single = evaluate(parse_input_form("ReplacePart[f[a, b, c], 2 -> x]"))
        replace_nested = evaluate(parse_input_form("ReplacePart[f[a, g[b, c], d], {2, 1} -> x]"))
        replace_multiple = evaluate(parse_input_form("ReplacePart[f[a, b, c], {{2} -> x, {3} -> y}]"))
        replace_invalid = evaluate(parse_input_form("ReplacePart[x, {1} -> y]"))
        replace_overlap = evaluate(parse_input_form("ReplacePart[f[g[a, b], c], {{1, 1} -> y, {1} -> x}]"))
        self.assertEqual(replace_single.to_full_form(), "f[a, x, c]")
        self.assertEqual(replace_nested.to_full_form(), "f[a, g[x, c], d]")
        self.assertEqual(replace_multiple.to_full_form(), "f[a, x, y]")
        self.assertEqual(replace_invalid.to_full_form(), "x")
        self.assertEqual(replace_overlap.to_full_form(), "f[x, c]")

    def test_apply_map_and_map_at_are_structural(self) -> None:
        apply_result = evaluate(parse_input_form("Apply[g, f[a, b]]"))
        apply_atom = evaluate(parse_input_form("Apply[g, x]"))
        map_result = evaluate(parse_input_form("Map[g, f[a, b]]"))
        map_atom = evaluate(parse_input_form("Map[g, x]"))
        map_at_result = evaluate(parse_input_form("MapAt[g, f[a, h[b, c], d], {2, 1}]"))
        map_at_multiple = evaluate(parse_input_form("MapAt[g, f[a, b, c], {{2}, {2}}]"))
        self.assertEqual(apply_result.to_full_form(), "g[a, b]")
        self.assertEqual(apply_atom.to_full_form(), "x")
        self.assertEqual(map_result.to_full_form(), "f[g[a], g[b]]")
        self.assertEqual(map_atom.to_full_form(), "x")
        self.assertEqual(map_at_result.to_full_form(), "f[a, h[g[b], c], d]")
        self.assertEqual(map_at_multiple.to_full_form(), "f[a, g[g[b]], c]")


if __name__ == "__main__":
    unittest.main()
