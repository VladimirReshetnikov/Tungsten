from __future__ import annotations

import re
import unittest

from tungsten.discovery import discover_installation
from tungsten.expression import evaluate
from tungsten.expression import parse_full_form
from tungsten.expression import parse_input_form
from tungsten.expression import parse_standard_form
from tungsten.expression import WolframEvaluationError


class ExpressionParserTests(unittest.TestCase):
    def test_parse_full_form(self) -> None:
        expr = parse_full_form("Plus[1, Times[2, x]]")
        self.assertEqual(expr.to_full_form(), "Plus[1, Times[2, x]]")

    def test_parse_input_form_with_implicit_times_and_power(self) -> None:
        expr = parse_input_form("1 + 2 x^3")
        self.assertEqual(expr.to_full_form(), "Plus[1, Times[2, Power[x, 3]]]")

    def test_arithmetic_and_boolean_operator_forms_do_not_flatten_during_parse(self) -> None:
        plus_expr = parse_input_form("1 + 2 + 3")
        times_expr = parse_input_form("2 * 3 * 4")
        and_expr = parse_input_form("a && b && c")
        or_expr = parse_input_form("a || b || c")
        self.assertEqual(plus_expr.to_full_form(), "Plus[Plus[1, 2], 3]")
        self.assertEqual(times_expr.to_full_form(), "Times[Times[2, 3], 4]")
        self.assertEqual(and_expr.to_full_form(), "And[And[a, b], c]")
        self.assertEqual(or_expr.to_full_form(), "Or[Or[a, b], c]")

    def test_parse_standard_form_subset_with_prefix_and_postfix_application(self) -> None:
        expr = parse_standard_form("f @ x // g")
        self.assertEqual(expr.to_full_form(), "g[f[x]]")

    def test_parse_input_form_pattern_shorthand_and_alternatives(self) -> None:
        blank = parse_input_form("_Integer")
        sequence = parse_input_form("__Symbol")
        null_sequence = parse_input_form("___")
        named = parse_input_form("f[x_Integer, y_]")
        alternatives = parse_input_form("a | b | c")
        head_blank = parse_input_form("_[1]")
        self.assertEqual(blank.to_full_form(), "Blank[Integer]")
        self.assertEqual(sequence.to_full_form(), "BlankSequence[Symbol]")
        self.assertEqual(null_sequence.to_full_form(), "BlankNullSequence[]")
        self.assertEqual(named.to_full_form(), "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]")
        self.assertEqual(alternatives.to_full_form(), "Alternatives[a, b, c]")
        self.assertEqual(head_blank.to_full_form(), "Blank[][1]")

    def test_parse_input_form_rejects_named_sequence_pattern_shorthand(self) -> None:
        with self.assertRaises(WolframEvaluationError):
            parse_input_form("x__")
        with self.assertRaises(WolframEvaluationError):
            parse_input_form("x___")

    def test_parse_part_and_span_syntax(self) -> None:
        expr = parse_input_form("expr[[1, 2 ;; -1]]")
        self.assertEqual(expr.to_full_form(), "Part[expr, 1, Span[2, -1]]")

    def test_parse_replace_operator_forms_to_named_functions(self) -> None:
        replace_all = parse_input_form("f[a] /. a -> b")
        replace_repeated = parse_standard_form("f[a] //. a -> b")
        self.assertEqual(replace_all.to_full_form(), "ReplaceAll[f[a], Rule[a, b]]")
        self.assertEqual(replace_all.to_input_form(), "ReplaceAll[f[a], a -> b]")
        self.assertEqual(replace_repeated.to_full_form(), "ReplaceRepeated[f[a], Rule[a, b]]")

    def test_parse_condition_and_delayed_rule_precedence(self) -> None:
        condition = parse_input_form("x_ /; x > 0")
        delayed_rhs_condition = parse_input_form("x_ :> x + 1 /; x > 0")
        alternatives_condition = parse_input_form("a | b /; False")
        self.assertEqual(
            condition.to_full_form(),
            "Condition[Pattern[x, Blank[]], Greater[x, 0]]",
        )
        self.assertEqual(
            delayed_rhs_condition.to_full_form(),
            "RuleDelayed[Pattern[x, Blank[]], Condition[Plus[x, 1], Greater[x, 0]]]",
        )
        self.assertEqual(
            alternatives_condition.to_full_form(),
            "Condition[Alternatives[a, b], False]",
        )

    def test_parse_pure_function_shorthand_and_slots(self) -> None:
        postfix = parse_input_form("f @ # &")
        self_ref = parse_input_form("#0[x] &")
        named = parse_input_form("#name &")
        self.assertEqual(postfix.to_full_form(), "Function[f[Slot[1]]]")
        self.assertEqual(self_ref.to_full_form(), "Function[Slot[0][x]]")
        self.assertEqual(named.to_full_form(), 'Function[Slot[1]["name"]]')

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
        for docs_root in cls.docs_roots:
            candidate = docs_root / "ReferencePages" / "Symbols" / notebook_name
            if not candidate.exists():
                continue
            notebook_text = candidate.read_text(encoding="utf-8")
            match = re.search(pattern, notebook_text, flags=re.DOTALL)
            if match is not None:
                return match.group(0)
        raise AssertionError(f"Could not find example matching {pattern!r} in any {notebook_name} copy.")

    @classmethod
    def _extract_boxdata_by_cell_id(cls, notebook_name: str, cell_id: int) -> str:
        for docs_root in cls.docs_roots:
            candidate = docs_root / "ReferencePages" / "Symbols" / notebook_name
            if not candidate.exists():
                continue
            notebook_text = candidate.read_text(encoding="utf-8")
            marker = f"CellID->{cell_id}"
            marker_index = notebook_text.find(marker)
            if marker_index < 0:
                continue

            boxdata_start = notebook_text.rfind("Cell[BoxData[", 0, marker_index)
            if boxdata_start < 0:
                continue

            content_start = boxdata_start + len("Cell[BoxData[")
            depth = 1
            index = content_start
            in_string = False
            while index < len(notebook_text):
                char = notebook_text[index]
                if in_string:
                    if char == "\\":
                        index += 2
                        continue
                    if char == "\"":
                        in_string = False
                    index += 1
                    continue

                if char == "\"":
                    in_string = True
                    index += 1
                    continue
                if char == "[":
                    depth += 1
                elif char == "]":
                    depth -= 1
                    if depth == 0:
                        return notebook_text[content_start:index].strip()
                index += 1

        raise AssertionError(f"Could not parse BoxData contents for input cell {cell_id} in any {notebook_name} copy.")

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

    def test_association_key_part_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Association.nb", 192453798)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "Part[Association[Rule[a, x], Rule[b, y], Rule[c, z]], Key[b]]",
        )

    def test_association_string_key_part_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Association.nb", 581979623)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            'Part[Association[Rule["a", x], Rule["b", y], Rule["c", z]], "b"]',
        )

    def test_association_numeric_part_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Association.nb", 703193542)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "Part[Association[Rule[a, x], Rule[b, y], Rule[c, z]], 2]",
        )

    def test_association_mixed_nesting_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Association.nb", 100783286)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "Part[List[Association[Rule[a, x], Rule[b, List[y, z]]]], 1, Key[b], 2]",
        )

    def test_association_mixed_string_key_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Association.nb", 622564489)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            'Part[List[Association[Rule["a", x], Rule["b", List[y, z]]]], 1, "b", 2]',
        )

    def test_matchq_example_from_docs_parses_standard_form_pattern_shorthand(self) -> None:
        source = self._extract_boxdata_by_cell_id("MatchQ.nb", 407610699)
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), "MatchQ[12345, Blank[Integer]]")

    def test_cases_except_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Cases.nb", 648587074)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "Cases[List[1, 1, f[a], 2, 3, y, f[8], 9, f[10]], Except[Blank[Integer]]]",
        )

    def test_condition_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("Condition.nb", 152728435)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "ReplaceAll[List[6, -7, 3, 2, -1, -2], Rule[Condition[Pattern[x, Blank[]], Less[x, 0]], w]]",
        )

    def test_freeq_integer_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("FreeQ.nb", 205371076)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "FreeQ[List[a, b, b, a, a, a], Blank[Integer]]",
        )


class ExpressionEvaluationTests(unittest.TestCase):
    def test_integer_arithmetic_evaluates_only_when_arguments_are_explicit_integers(self) -> None:
        nested_plus = evaluate(parse_input_form("1 + 2 + 3"))
        nested_times = evaluate(parse_input_form("2 * 3 * 4"))
        nested_power = evaluate(parse_input_form("2^3"))
        mixed_operator = evaluate(parse_input_form("1 + 2 + a"))
        mixed_head = evaluate(parse_input_form("Plus[1, 2, a]"))
        unary_minus = evaluate(parse_input_form("-(1 + 2)"))
        self.assertEqual(nested_plus.to_full_form(), "6")
        self.assertEqual(nested_times.to_full_form(), "24")
        self.assertEqual(nested_power.to_full_form(), "8")
        self.assertEqual(mixed_operator.to_full_form(), "Plus[3, a]")
        self.assertEqual(mixed_head.to_full_form(), "Plus[1, 2, a]")
        self.assertEqual(unary_minus.to_full_form(), "-3")

    def test_relational_operators_evaluate_on_explicit_integers_only(self) -> None:
        equal_true = evaluate(parse_input_form("Equal[1, 1, 1]"))
        equal_false = evaluate(parse_input_form("Equal[1, 1, 2]"))
        less_true = evaluate(parse_input_form("Less[1, 2, 3]"))
        greater_false = evaluate(parse_input_form("Greater[3, 3, 1]"))
        mixed_direct = evaluate(parse_input_form("Less[1, 2, a]"))
        mixed_operator = evaluate(parse_input_form("1 < 2 < a"))
        self.assertEqual(equal_true.to_full_form(), "True")
        self.assertEqual(equal_false.to_full_form(), "False")
        self.assertEqual(less_true.to_full_form(), "True")
        self.assertEqual(greater_false.to_full_form(), "False")
        self.assertEqual(mixed_direct.to_full_form(), "Less[1, 2, a]")
        self.assertEqual(mixed_operator.to_full_form(), "Less[True, a]")

    def test_boolean_functions_evaluate_on_explicit_booleans_only(self) -> None:
        not_result = evaluate(parse_input_form("!(True)"))
        and_direct = evaluate(parse_input_form("And[True, False, x]"))
        and_operator = evaluate(parse_input_form("True && False && x"))
        or_direct = evaluate(parse_input_form("Or[False, False, x]"))
        or_operator = evaluate(parse_input_form("False || False || True"))
        self.assertEqual(not_result.to_full_form(), "False")
        self.assertEqual(and_direct.to_full_form(), "And[True, False, x]")
        self.assertEqual(and_operator.to_full_form(), "And[False, x]")
        self.assertEqual(or_direct.to_full_form(), "Or[False, False, x]")
        self.assertEqual(or_operator.to_full_form(), "True")

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

    def test_pure_functions_apply_and_integrate_with_map_apply_and_mapat(self) -> None:
        applied = evaluate(parse_input_form("(# + 1 &)[a]"))
        explicit_slot = evaluate(parse_input_form("Function[Slot[]][x]"))
        apply_result = evaluate(parse_input_form("Apply[#1 + #2 &, f[a, b]]"))
        map_result = evaluate(parse_input_form("Map[# + 1 &, {a, b}]"))
        map_at_result = evaluate(parse_input_form("MapAt[Function[f[#]], g[a, b], 2]"))
        named = evaluate(parse_input_form("(#name &)[obj]"))
        self.assertEqual(applied.to_full_form(), "Plus[a, 1]")
        self.assertEqual(explicit_slot.to_full_form(), "x")
        self.assertEqual(apply_result.to_full_form(), "Plus[a, b]")
        self.assertEqual(map_result.to_full_form(), "List[Plus[a, 1], Plus[b, 1]]")
        self.assertEqual(map_at_result.to_full_form(), "g[a, f[b]]")
        self.assertEqual(named.to_full_form(), 'obj["name"]')

    def test_pure_functions_support_self_reference_and_nested_lexical_scoping(self) -> None:
        self_reference = evaluate(parse_input_form("(#0&)[x]"))
        nested = evaluate(parse_input_form("Function[Function[#1]][a][b]"))
        self.assertEqual(self_reference.to_full_form(), "Function[Slot[0]]")
        self.assertEqual(nested.to_full_form(), "b")

    def test_pure_function_slot_errors_surface_when_argument_is_missing(self) -> None:
        with self.assertRaises(WolframEvaluationError):
            evaluate(parse_input_form("(#2&)[a]"))

    def test_association_constructor_and_depth(self) -> None:
        literal = evaluate(parse_input_form("<|a -> 1, a -> 2, b -> 3|>"))
        constructor = evaluate(parse_input_form("Association[{a -> 1, a -> 2, b -> 3}]"))
        depth_result = evaluate(parse_input_form("Depth[<|a -> <|b -> 1|>, c -> {2, 3}|>]"))
        association_q = evaluate(parse_input_form("AssociationQ[Association[a]]"))
        self.assertEqual(literal.to_full_form(), "Association[Rule[a, 2], Rule[b, 3]]")
        self.assertEqual(constructor.to_full_form(), "Association[Rule[a, 2], Rule[b, 3]]")
        self.assertEqual(depth_result.to_full_form(), "3")
        self.assertEqual(association_q.to_full_form(), "False")

    def test_association_access_conversion_and_lookup_functions(self) -> None:
        keys_result = evaluate(parse_input_form("Keys[<|a -> x, b -> y, c -> z|>]"))
        values_result = evaluate(parse_input_form("Values[<|a -> x, b -> y, c -> z|>]"))
        normal_result = evaluate(parse_input_form("Normal[<|a -> x, b -> y|>]"))
        lookup_single = evaluate(parse_input_form("Lookup[<|a -> 1, b -> 2|>, b]"))
        lookup_missing = evaluate(parse_input_form("Lookup[<|a -> 1, b -> 2|>, d]"))
        lookup_default = evaluate(parse_input_form("Lookup[<|a -> 1, b -> 2|>, {b, d}, q]"))
        key_exists = evaluate(parse_input_form("KeyExistsQ[<|a -> x, b -> y|>, b]"))
        key_member = evaluate(parse_input_form("KeyMemberQ[<|a -> x, b -> y|>, d]"))
        self.assertEqual(keys_result.to_full_form(), "List[a, b, c]")
        self.assertEqual(values_result.to_full_form(), "List[x, y, z]")
        self.assertEqual(normal_result.to_full_form(), "List[Rule[a, x], Rule[b, y]]")
        self.assertEqual(lookup_single.to_full_form(), "2")
        self.assertEqual(lookup_missing.to_full_form(), 'Missing["KeyAbsent", d]')
        self.assertEqual(lookup_default.to_full_form(), "List[2, q]")
        self.assertEqual(key_exists.to_full_form(), "True")
        self.assertEqual(key_member.to_full_form(), "False")

    def test_association_key_transforms_and_constructors(self) -> None:
        key_take = evaluate(parse_input_form("KeyTake[<|a -> 1, b -> 2, c -> 3|>, {c, a}]"))
        key_drop = evaluate(parse_input_form("KeyDrop[<|a -> 1, b -> 2, c -> 3|>, {c, a}]"))
        key_map = evaluate(parse_input_form("KeyMap[f, <|a -> 1, b -> 2|>]"))
        key_value_map = evaluate(parse_input_form("KeyValueMap[f, <|a -> 1, b -> 2|>]"))
        association_thread = evaluate(parse_input_form("AssociationThread[{a, b, c}, {1, 2, 3}]"))
        association_map = evaluate(parse_input_form("AssociationMap[f, {a, b, c}]"))
        self.assertEqual(key_take.to_full_form(), "Association[Rule[c, 3], Rule[a, 1]]")
        self.assertEqual(key_drop.to_full_form(), "Association[Rule[b, 2]]")
        self.assertEqual(key_map.to_full_form(), "Association[Rule[f[a], 1], Rule[f[b], 2]]")
        self.assertEqual(key_value_map.to_full_form(), "List[f[a, 1], f[b, 2]]")
        self.assertEqual(association_thread.to_full_form(), "Association[Rule[a, 1], Rule[b, 2], Rule[c, 3]]")
        self.assertEqual(association_map.to_full_form(), "Association[Rule[a, f[a]], Rule[b, f[b]], Rule[c, f[c]]]")

    def test_association_structural_functions_operate_on_values(self) -> None:
        first_result = evaluate(parse_input_form("First[<|a -> 1, b -> 2, c -> 3|>]"))
        last_result = evaluate(parse_input_form("Last[<|a -> 1, b -> 2, c -> 3|>]"))
        rest_result = evaluate(parse_input_form("Rest[<|a -> 1, b -> 2, c -> 3|>]"))
        most_result = evaluate(parse_input_form("Most[<|a -> 1, b -> 2, c -> 3|>]"))
        take_result = evaluate(parse_input_form("Take[<|a -> 1, b -> 2, c -> 3|>, 2]"))
        drop_result = evaluate(parse_input_form("Drop[<|a -> 1, b -> 2, c -> 3|>, 2]"))
        append_result = evaluate(parse_input_form("Append[<|a -> 1, b -> 2|>, a -> 9]"))
        prepend_result = evaluate(parse_input_form("Prepend[<|a -> 1, b -> 2|>, a -> 9]"))
        join_result = evaluate(parse_input_form("Join[<|a -> 1, b -> 2|>, <|a -> 9, c -> 3|>]"))
        apply_result = evaluate(parse_input_form("Apply[g, <|a -> 1, b -> 2|>]"))
        map_result = evaluate(parse_input_form("Map[g, <|a -> 1, b -> 2|>]"))
        self.assertEqual(first_result.to_full_form(), "1")
        self.assertEqual(last_result.to_full_form(), "3")
        self.assertEqual(rest_result.to_full_form(), "Association[Rule[b, 2], Rule[c, 3]]")
        self.assertEqual(most_result.to_full_form(), "Association[Rule[a, 1], Rule[b, 2]]")
        self.assertEqual(take_result.to_full_form(), "Association[Rule[a, 1], Rule[b, 2]]")
        self.assertEqual(drop_result.to_full_form(), "Association[Rule[c, 3]]")
        self.assertEqual(append_result.to_full_form(), "Association[Rule[b, 2], Rule[a, 9]]")
        self.assertEqual(prepend_result.to_full_form(), "Association[Rule[a, 9], Rule[b, 2]]")
        self.assertEqual(join_result.to_full_form(), "Association[Rule[b, 2], Rule[a, 9], Rule[c, 3]]")
        self.assertEqual(apply_result.to_full_form(), "g[1, 2]")
        self.assertEqual(map_result.to_full_form(), "Association[Rule[a, g[1]], Rule[b, g[2]]]")

    def test_association_part_extract_delete_replacepart_and_mapat(self) -> None:
        part_key = evaluate(parse_input_form("Part[<|a -> x, b -> y, c -> z|>, Key[b]]"))
        part_string = evaluate(parse_input_form('Part[<|"a" -> x, "b" -> {y, z}|>, "b", 2]'))
        part_numeric = evaluate(parse_input_form("Part[<|a -> x, b -> y, c -> z|>, 2]"))
        part_selector = evaluate(parse_input_form("Part[<|a -> 1, b -> 2, c -> 3, d -> 4|>, {Key[a], Key[c]}]"))
        extract_result = evaluate(parse_input_form("Extract[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]"))
        extract_nested = evaluate(parse_input_form("Extract[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]"))
        delete_result = evaluate(parse_input_form("Delete[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]"))
        delete_nested = evaluate(parse_input_form("Delete[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]"))
        replace_result = evaluate(parse_input_form("ReplacePart[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]} -> x, {Key[c]} -> z}]"))
        replace_nested = evaluate(parse_input_form("ReplacePart[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2} -> x]"))
        map_at_result = evaluate(parse_input_form("MapAt[f, <|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]"))
        map_at_nested = evaluate(parse_input_form("MapAt[f, {<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]"))
        self.assertEqual(part_key.to_full_form(), "y")
        self.assertEqual(part_string.to_full_form(), "z")
        self.assertEqual(part_numeric.to_full_form(), "y")
        self.assertEqual(part_selector.to_full_form(), "Association[Rule[a, 1], Rule[c, 3]]")
        self.assertEqual(extract_result.to_full_form(), "List[1, 3]")
        self.assertEqual(extract_nested.to_full_form(), "3")
        self.assertEqual(delete_result.to_full_form(), "Association[Rule[b, 2]]")
        self.assertEqual(delete_nested.to_full_form(), "List[Association[Rule[a, 1], Rule[b, List[2]]], 9]")
        self.assertEqual(replace_result.to_full_form(), "Association[Rule[a, x], Rule[b, 2], Rule[c, z]]")
        self.assertEqual(replace_nested.to_full_form(), "List[Association[Rule[a, 1], Rule[b, List[2, x]]], 9]")
        self.assertEqual(map_at_result.to_full_form(), "Association[Rule[a, f[1]], Rule[b, 2], Rule[c, f[3]]]")
        self.assertEqual(map_at_nested.to_full_form(), "List[Association[Rule[a, 1], Rule[b, List[2, f[3]]]], 9]")

    def test_association_mixed_selector_lists_are_rejected(self) -> None:
        with self.assertRaises(WolframEvaluationError):
            evaluate(parse_input_form("Part[<|a -> 1, b -> 2, c -> 3, d -> 4|>, {2, Key[d]}]"))

    def test_matchq_supports_pattern_subset(self) -> None:
        wildcard = evaluate(parse_input_form("MatchQ[f[1], _[1]]"))
        typed = evaluate(parse_input_form("MatchQ[f[1, g[a]], f[_Integer, g[_Symbol]]]"))
        repeated_true = evaluate(parse_input_form("MatchQ[f[a, a], f[x_, x_]]"))
        repeated_false = evaluate(parse_input_form("MatchQ[f[a, b], f[x_, x_]]"))
        alternatives = evaluate(parse_input_form("MatchQ[g[a], f[_] | g[_]]"))
        except_true = evaluate(parse_input_form("MatchQ[a, Except[_Integer]]"))
        except_false = evaluate(parse_input_form("MatchQ[2, Except[_Integer]]"))
        verbatim = evaluate(parse_input_form("MatchQ[_, Verbatim[_]]"))
        self.assertEqual(wildcard.to_full_form(), "True")
        self.assertEqual(typed.to_full_form(), "True")
        self.assertEqual(repeated_true.to_full_form(), "True")
        self.assertEqual(repeated_false.to_full_form(), "False")
        self.assertEqual(alternatives.to_full_form(), "True")
        self.assertEqual(except_true.to_full_form(), "True")
        self.assertEqual(except_false.to_full_form(), "False")
        self.assertEqual(verbatim.to_full_form(), "True")

    def test_condition_patterns_filter_matches_and_respect_precedence(self) -> None:
        positive = evaluate(parse_input_form("MatchQ[f[2], f[x_ /; x > 0]]"))
        negative = evaluate(parse_input_form("MatchQ[f[-1], f[x_ /; x > 0]]"))
        precedence = evaluate(parse_input_form("MatchQ[a, a | b /; False]"))
        parenthesized = evaluate(parse_input_form("MatchQ[a, a | (b /; False)]"))
        self.assertEqual(positive.to_full_form(), "True")
        self.assertEqual(negative.to_full_form(), "False")
        self.assertEqual(precedence.to_full_form(), "False")
        self.assertEqual(parenthesized.to_full_form(), "True")

    def test_sequence_patterns_support_one_anonymous_blanksequence_per_argument_list(self) -> None:
        top_level = evaluate(parse_input_form("MatchQ[a, __]"))
        top_level_typed = evaluate(parse_input_form("MatchQ[1, __Symbol]"))
        non_empty = evaluate(parse_input_form("MatchQ[f[a, b], f[__]]"))
        empty_false = evaluate(parse_input_form("MatchQ[f[], f[__]]"))
        empty_true = evaluate(parse_input_form("MatchQ[f[], f[___]]"))
        typed_true = evaluate(parse_input_form("MatchQ[f[a, b], f[__Symbol]]"))
        typed_false = evaluate(parse_input_form("MatchQ[f[a, 1], f[__Symbol]]"))
        middle_true = evaluate(parse_input_form("MatchQ[f[a, b, c], f[a, __, c]]"))
        middle_false = evaluate(parse_input_form("MatchQ[f[a, c], f[a, __, c]]"))
        middle_null_true = evaluate(parse_input_form("MatchQ[f[a, c], f[a, ___, c]]"))
        self.assertEqual(top_level.to_full_form(), "True")
        self.assertEqual(top_level_typed.to_full_form(), "False")
        self.assertEqual(non_empty.to_full_form(), "True")
        self.assertEqual(empty_false.to_full_form(), "False")
        self.assertEqual(empty_true.to_full_form(), "True")
        self.assertEqual(typed_true.to_full_form(), "True")
        self.assertEqual(typed_false.to_full_form(), "False")
        self.assertEqual(middle_true.to_full_form(), "True")
        self.assertEqual(middle_false.to_full_form(), "False")
        self.assertEqual(middle_null_true.to_full_form(), "True")

        with self.assertRaises(WolframEvaluationError):
            evaluate(parse_input_form("MatchQ[f[a, b], f[__, ___]]"))

    def test_freeq_defaults_to_heads_true_and_honors_levelspec(self) -> None:
        head_search = evaluate(parse_input_form("FreeQ[f[a], f]"))
        head_level = evaluate(parse_input_form("FreeQ[f[a], f, {1}]"))
        root_only = evaluate(parse_input_form("FreeQ[f[a], f, {0}]"))
        integer_search = evaluate(parse_input_form("FreeQ[{a, b, b, a}, _Integer]"))
        self.assertEqual(head_search.to_full_form(), "False")
        self.assertEqual(head_level.to_full_form(), "False")
        self.assertEqual(root_only.to_full_form(), "True")
        self.assertEqual(integer_search.to_full_form(), "True")

    def test_cases_supports_postorder_levels_limits_and_templates(self) -> None:
        leaf_search = evaluate(parse_input_form("Cases[f[a, g[a]], a, Infinity]"))
        postorder = evaluate(parse_input_form("Cases[f[g[a]], _, {0, Infinity}]"))
        limited = evaluate(parse_input_form("Cases[f[a, g[a]], a, Infinity, 1]"))
        transformed = evaluate(parse_input_form("Cases[{f[a], f[b]}, f[x_] :> {x, x}]"))
        self.assertEqual(leaf_search.to_full_form(), "List[a, a]")
        self.assertEqual(postorder.to_full_form(), "List[a, g[a], f[g[a]]]")
        self.assertEqual(limited.to_full_form(), "List[a]")
        self.assertEqual(transformed.to_full_form(), "List[List[a, a], List[b, b]]")

    def test_condition_patterns_and_delayed_rules_work_in_cases(self) -> None:
        guarded_pattern = evaluate(parse_input_form("Cases[{1, -2, 3}, x_ /; x > 0]"))
        guarded_template = evaluate(parse_input_form("Cases[{1, -2, 3}, x_ :> x + 1 /; x > 0]"))
        self.assertEqual(guarded_pattern.to_full_form(), "List[1, 3]")
        self.assertEqual(guarded_template.to_full_form(), "List[2, 4]")

    def test_cases_and_deletecases_support_anonymous_sequence_patterns(self) -> None:
        non_empty_cases = evaluate(parse_input_form("Cases[{f[a], f[a, b], f[]}, f[__]]"))
        all_cases = evaluate(parse_input_form("Cases[{f[a], f[a, b], f[]}, f[___]]"))
        typed_cases = evaluate(parse_input_form("Cases[{f[a, 1], f[a, b]}, f[__Symbol]]"))
        delete_non_empty = evaluate(parse_input_form("DeleteCases[{f[a], f[a, b], f[]}, f[__]]"))
        self.assertEqual(non_empty_cases.to_full_form(), "List[f[a], f[a, b]]")
        self.assertEqual(all_cases.to_full_form(), "List[f[a], f[a, b], f[]]")
        self.assertEqual(typed_cases.to_full_form(), "List[f[a, b]]")
        self.assertEqual(delete_non_empty.to_full_form(), "List[f[]]")

    def test_delete_cases_is_depth_first_and_supports_limits(self) -> None:
        default_levels = evaluate(parse_input_form("DeleteCases[f[a, g[a]], a]"))
        all_levels = evaluate(parse_input_form("DeleteCases[f[a, g[a]], a, Infinity]"))
        limited = evaluate(parse_input_form("DeleteCases[{1, a, 2, a}, a, Infinity, 1]"))
        self.assertEqual(default_levels.to_full_form(), "f[g[a]]")
        self.assertEqual(all_levels.to_full_form(), "f[g[]]")
        self.assertEqual(limited.to_full_form(), "List[1, 2, a]")

    def test_delete_cases_supports_condition_patterns(self) -> None:
        result = evaluate(parse_input_form("DeleteCases[{1, -2, 3}, x_ /; x > 0]"))
        self.assertEqual(result.to_full_form(), "List[-2]")

    def test_replace_supports_levelspecs_and_nested_rulesets(self) -> None:
        root_result = evaluate(parse_input_form("Replace[f[a], f[x_] :> x]"))
        positive_levels = evaluate(parse_input_form("Replace[f[g[a]], _ -> z, 2]"))
        negative_levels = evaluate(parse_input_form("Replace[f[g[a]], _Symbol -> s, -1]"))
        deep_result = evaluate(parse_input_form("Replace[f[g[a]], x_ :> p[x], {0, Infinity}]"))
        nested_rulesets = evaluate(parse_input_form("Replace[f[a], {{f[x_] :> x}, {a -> y}}]"))
        self.assertEqual(root_result.to_full_form(), "a")
        self.assertEqual(positive_levels.to_full_form(), "f[z]")
        self.assertEqual(negative_levels.to_full_form(), "f[g[s]]")
        self.assertEqual(deep_result.to_full_form(), "p[f[p[g[p[a]]]]]")
        self.assertEqual(nested_rulesets.to_full_form(), "List[a, f[a]]")

    def test_condition_patterns_and_delayed_rules_work_in_replace(self) -> None:
        lhs_condition_true = evaluate(parse_input_form("Replace[2, x_ /; x > 0 :> x + 1]"))
        lhs_condition_false = evaluate(parse_input_form("Replace[-1, x_ /; x > 0 :> x + 1]"))
        rhs_condition_true = evaluate(parse_input_form("Replace[2, x_ :> x + 1 /; x > 0]"))
        rhs_condition_false = evaluate(parse_input_form("Replace[-1, x_ :> x + 1 /; x > 0]"))
        fallback_rule = evaluate(parse_input_form("Replace[1, {x_ :> x + 1 /; x < 0, x_ :> x + 2}]"))
        self.assertEqual(lhs_condition_true.to_full_form(), "3")
        self.assertEqual(lhs_condition_false.to_full_form(), "-1")
        self.assertEqual(rhs_condition_true.to_full_form(), "3")
        self.assertEqual(rhs_condition_false.to_full_form(), "-1")
        self.assertEqual(fallback_rule.to_full_form(), "3")

    def test_replace_all_and_replace_repeated_support_operator_forms_and_fixed_points(self) -> None:
        replace_all = evaluate(parse_input_form("f[g[a]] /. g[x_] :> x"))
        replace_all_root = evaluate(parse_input_form("f[g[a]] /. x_ :> p[x]"))
        replace_all_nested_rulesets = evaluate(parse_input_form("f[a] /. {{a -> x}, {a -> y}}"))
        replace_repeated = evaluate(parse_input_form("f[a] //. f[x_] :> x"))
        replace_repeated_identity = evaluate(parse_input_form("f[a] //. x_ :> x"))
        replace_repeated_nested_rulesets = evaluate(parse_input_form("ReplaceRepeated[f[a], {{f[x_] :> x}, {a -> y}}]"))
        self.assertEqual(replace_all.to_full_form(), "f[a]")
        self.assertEqual(replace_all_root.to_full_form(), "p[f[g[a]]]")
        self.assertEqual(replace_all_nested_rulesets.to_full_form(), "List[f[x], f[y]]")
        self.assertEqual(replace_repeated.to_full_form(), "a")
        self.assertEqual(replace_repeated_identity.to_full_form(), "f[a]")
        self.assertEqual(replace_repeated_nested_rulesets.to_full_form(), "List[a, f[y]]")

    def test_condition_patterns_and_delayed_rules_work_in_replace_all_and_repeated(self) -> None:
        replace_all_lhs = evaluate(parse_input_form("f[2] /. f[x_ /; x > 0] :> x + 1"))
        replace_all_rhs = evaluate(parse_input_form("2 /. x_ :> x + 1 /; x > 0"))
        replace_all_rhs_false = evaluate(parse_input_form("-1 /. x_ :> x + 1 /; x > 0"))
        replace_repeated = evaluate(parse_input_form("1 //. x_ :> x + 1 /; x < 3"))
        self.assertEqual(replace_all_lhs.to_full_form(), "3")
        self.assertEqual(replace_all_rhs.to_full_form(), "3")
        self.assertEqual(replace_all_rhs_false.to_full_form(), "-1")
        self.assertEqual(replace_repeated.to_full_form(), "3")

    def test_replace_at_rewrites_only_exact_target_parts(self) -> None:
        single = evaluate(parse_input_form("ReplaceAt[f[g[a], h[a]], a -> x, {2, 1}]"))
        multiple = evaluate(parse_input_form("ReplaceAt[f[g[a], h[a]], a -> x, {{1, 1}, {2, 1}}]"))
        ruleset = evaluate(parse_input_form("ReplaceAt[f[g[a]], {g[x_] :> x, a -> x}, {1}]"))
        no_match = evaluate(parse_input_form("ReplaceAt[f[a, b, c], a -> x, 2]"))
        self.assertEqual(single.to_full_form(), "f[g[a], h[x]]")
        self.assertEqual(multiple.to_full_form(), "f[g[x], h[x]]")
        self.assertEqual(ruleset.to_full_form(), "f[a]")
        self.assertEqual(no_match.to_full_form(), "f[a, b, c]")

    def test_replace_family_handles_association_roots_values_and_key_paths(self) -> None:
        replace_root = evaluate(parse_input_form("Replace[<|a -> 1|>, _Association -> x]"))
        replace_value = evaluate(parse_input_form("Replace[<|a -> 1|>, _Integer -> x, Infinity]"))
        replace_all_root = evaluate(parse_input_form("<|a -> 1|> /. _Association -> z"))
        replace_all_value = evaluate(parse_input_form("<|a -> 1|> /. _Integer -> x"))
        replace_all_head = evaluate(parse_input_form("<|a -> 1|> /. _Symbol -> s"))
        replace_at_key = evaluate(parse_input_form("ReplaceAt[<|a -> 1, b -> 2|>, _Integer -> x, Key[b]]"))
        replace_at_nested = evaluate(parse_input_form("ReplaceAt[{<|a -> 1|>, 2}, _Integer -> x, {1, Key[a]}]"))
        self.assertEqual(replace_root.to_full_form(), "x")
        self.assertEqual(replace_value.to_full_form(), "Association[Rule[a, x]]")
        self.assertEqual(replace_all_root.to_full_form(), "z")
        self.assertEqual(replace_all_value.to_full_form(), "Association[Rule[a, x]]")
        self.assertEqual(replace_all_head.to_full_form(), "s[Rule[a, 1]]")
        self.assertEqual(replace_at_key.to_full_form(), "Association[Rule[a, 1], Rule[b, x]]")
        self.assertEqual(replace_at_nested.to_full_form(), "List[Association[Rule[a, x]], 2]")

    def test_pattern_search_treats_associations_as_opaque_for_now(self) -> None:
        match_assoc = evaluate(parse_input_form("MatchQ[<|a -> 1|>, _Association]"))
        free_q_assoc = evaluate(parse_input_form("FreeQ[<|a -> 1|>, _Integer]"))
        cases_assoc = evaluate(parse_input_form("Cases[{<|a -> 1|>}, _Integer, Infinity]"))
        delete_assoc = evaluate(parse_input_form("DeleteCases[{<|a -> 1|>}, _Integer, Infinity]"))
        self.assertEqual(match_assoc.to_full_form(), "True")
        self.assertEqual(free_q_assoc.to_full_form(), "True")
        self.assertEqual(cases_assoc.to_full_form(), "List[]")
        self.assertEqual(delete_assoc.to_full_form(), "List[Association[Rule[a, 1]]]")


if __name__ == "__main__":
    unittest.main()
