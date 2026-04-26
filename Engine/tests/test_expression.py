from __future__ import annotations

import re
import unittest

from tungsten.discovery import discover_installation
from tungsten.expression import EvaluationSession
from tungsten.expression import Real
from tungsten.expression import TungstenExitRequested
from tungsten.expression import evaluate
from tungsten.expression import parse_full_form
from tungsten.expression import parse_input_form
from tungsten.expression import parse_standard_form
from tungsten.expression import WolframSyntaxError


class ExpressionParserTests(unittest.TestCase):
    def test_parse_full_form(self) -> None:
        expr = parse_full_form("Plus[1, Times[2, x]]")
        self.assertEqual(expr.to_full_form(), "Plus[1, Times[2, x]]")

    def test_parse_input_form_with_implicit_times_and_power(self) -> None:
        expr = parse_input_form("1 + 2 x^3")
        self.assertEqual(expr.to_full_form(), "Plus[1, Times[2, Power[x, 3]]]")

    def test_parse_wolfram_numeric_literal_surface_forms(self) -> None:
        examples = {
            "Hold[1.]": "Hold[1.]",
            "Hold[.5]": "Hold[.5]",
            "Hold[1`20]": "Hold[1`20]",
            "Hold[1`]": "Hold[1`]",
            "Hold[1``20]": "Hold[1``20]",
            "Hold[1.2`.5]": "Hold[1.2`.5]",
            "Hold[1.2``.5]": "Hold[1.2``.5]",
            "Hold[1.2`20*^3]": "Hold[1.2`20*^3]",
            "Hold[1.2``20*^-3]": "Hold[1.2``20*^-3]",
            "Hold[1.2`*^3]": "Hold[1.2`*^3]",
            "Hold[16^^ff]": "Hold[255]",
            "Hold[16^^f.f]": "Hold[16^^f.f]",
            "Hold[2^^1.01*^3]": "Hold[2^^1.01*^3]",
            "Hold[16^^ff`20]": "Hold[16^^ff`20]",
            "Hold[16^^f.f``20]": "Hold[16^^f.f``20]",
            "Hold[16^^f`*^2]": "Hold[16^^f`*^2]",
            "Hold[16^^f``2*^2]": "Hold[16^^f``2*^2]",
            "Hold[36^^z.z]": "Hold[36^^z.z]",
            "Hold[10^^.5]": "Hold[10^^.5]",
            "Hold[10^^1.]": "Hold[10^^1.]",
        }
        for source, expected in examples.items():
            with self.subTest(source=source):
                self.assertEqual(parse_input_form(source).to_full_form(), expected)

        self.assertEqual(parse_input_form("Hold[1..]").to_full_form(), "Hold[Repeated[1]]")
        self.assertEqual(parse_input_form("Hold[1...]").to_full_form(), "Hold[RepeatedNull[1]]")
        self.assertEqual(parse_input_form("Hold[1.2`3..]").to_full_form(), "Hold[Repeated[1.2`3]]")
        self.assertEqual(parse_input_form("Hold[1.2``3..]").to_full_form(), "Hold[Repeated[1.2``3]]")

    def test_reject_malformed_wolfram_numeric_literal_forms(self) -> None:
        examples = [
            "Hold[1*^3.5]",
            "Hold[1*^.5]",
            "Hold[1.2``*^3]",
            "Hold[37^^10]",
            "Hold[2^^102]",
            "Hold[16^^f..]",
        ]
        for source in examples:
            with self.subTest(source=source):
                with self.assertRaises(WolframSyntaxError):
                    parse_input_form(source)

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
        pattern_test = parse_input_form("x_?IntegerQ")
        optional_default = parse_input_form("x_Integer:7")
        optional_dot = parse_input_form("x_.")
        alternatives = parse_input_form("a | b | c")
        head_blank = parse_input_form("_[1]")
        self.assertEqual(blank.to_full_form(), "Blank[Integer]")
        self.assertEqual(sequence.to_full_form(), "BlankSequence[Symbol]")
        self.assertEqual(null_sequence.to_full_form(), "BlankNullSequence[]")
        self.assertEqual(named.to_full_form(), "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]")
        self.assertEqual(pattern_test.to_full_form(), "PatternTest[Pattern[x, Blank[]], IntegerQ]")
        self.assertEqual(optional_default.to_full_form(), "Optional[Pattern[x, Blank[Integer]], 7]")
        self.assertEqual(optional_dot.to_full_form(), "Optional[Pattern[x, Blank[]]]")
        self.assertEqual(alternatives.to_full_form(), "Alternatives[a, b, c]")
        self.assertEqual(head_blank.to_full_form(), "Blank[][1]")

    def test_parse_input_form_named_sequence_pattern_shorthand(self) -> None:
        sequence = parse_input_form("x__")
        null_sequence = parse_input_form("x___")
        typed_sequence = parse_input_form("x__Integer")
        typed_null_sequence = parse_input_form("x___Symbol")
        colon_sequence = parse_input_form("x : __")
        self.assertEqual(sequence.to_full_form(), "Pattern[x, BlankSequence[]]")
        self.assertEqual(null_sequence.to_full_form(), "Pattern[x, BlankNullSequence[]]")
        self.assertEqual(typed_sequence.to_full_form(), "Pattern[x, BlankSequence[Integer]]")
        self.assertEqual(typed_null_sequence.to_full_form(), "Pattern[x, BlankNullSequence[Symbol]]")
        self.assertEqual(colon_sequence.to_full_form(), "Pattern[x, BlankSequence[]]")

    def test_parse_part_and_span_syntax(self) -> None:
        expr = parse_input_form("expr[[1, 2 ;; -1]]")
        self.assertEqual(expr.to_full_form(), "Part[expr, 1, Span[2, -1]]")

    def test_parse_replace_operator_forms_to_named_functions(self) -> None:
        replace_all = parse_input_form("f[a] /. a -> b")
        replace_repeated = parse_standard_form("f[a] //. a -> b")
        self.assertEqual(replace_all.to_full_form(), "ReplaceAll[f[a], Rule[a, b]]")
        self.assertEqual(replace_all.to_input_form(), "f[a] /. a -> b")
        self.assertEqual(replace_repeated.to_full_form(), "ReplaceRepeated[f[a], Rule[a, b]]")
        self.assertEqual(replace_repeated.to_input_form(), "f[a] //. a -> b")

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
        self.assertEqual(condition.to_input_form(), "x_ /; x > 0")
        self.assertEqual(delayed_rhs_condition.to_input_form(), "x_ :> x + 1 /; x > 0")
        self.assertEqual(alternatives_condition.to_input_form(), "a | b /; False")

    def test_parse_pure_function_shorthand_and_slots(self) -> None:
        postfix = parse_input_form("f @ # &")
        self_ref = parse_input_form("#0[x] &")
        named = parse_input_form("#name &")
        slot_sequence = parse_input_form("## &")
        slot_sequence_from_second = parse_input_form("##2 &")
        named_symbol = parse_input_form("x |-> x + x")
        named_list = parse_input_form("{x, y} |-> x + y")
        escaped = parse_input_form(r"x \[Function] x + x")
        nested_named = parse_input_form("x |-> y |-> x[y]")
        self.assertEqual(postfix.to_full_form(), "Function[f[Slot[1]]]")
        self.assertEqual(self_ref.to_full_form(), "Function[Slot[0][x]]")
        self.assertEqual(named.to_full_form(), 'Function[Slot[1]["name"]]')
        self.assertEqual(slot_sequence.to_full_form(), "Function[SlotSequence[1]]")
        self.assertEqual(slot_sequence_from_second.to_full_form(), "Function[SlotSequence[2]]")
        self.assertEqual(named_symbol.to_full_form(), "Function[x, Plus[x, x]]")
        self.assertEqual(named_list.to_full_form(), "Function[List[x, y], Plus[x, y]]")
        self.assertEqual(escaped.to_full_form(), "Function[x, Plus[x, x]]")
        self.assertEqual(nested_named.to_full_form(), "Function[x, Function[y, x[y]]]")

    def test_parse_string_pattern_operators_and_named_patterns(self) -> None:
        concatenation = parse_input_form('"a" ~~ DigitCharacter.. ~~ EndOfString')
        named_capture = parse_input_form('x : DigitCharacter..')
        self.assertEqual(
            concatenation.to_full_form(),
            'StringExpression[StringExpression["a", Repeated[DigitCharacter]], EndOfString]',
        )
        self.assertEqual(named_capture.to_full_form(), "Pattern[x, Repeated[DigitCharacter]]")

    def test_parse_structural_operator_forms(self) -> None:
        same_q = parse_input_form("a === b")
        unsame_q = parse_input_form("a =!= b")
        composition = parse_input_form("f @* g")
        right_composition = parse_input_form("f /* g")
        map_apply = parse_input_form("f @@@ xs")
        dot_expr = parse_input_form("{a, b} . {c, d}")
        string_join = parse_input_form('"a" <> "b" <> "c"')
        output_history = parse_input_form("% + %% + %12")
        self.assertEqual(same_q.to_full_form(), "SameQ[a, b]")
        self.assertEqual(unsame_q.to_full_form(), "UnsameQ[a, b]")
        self.assertEqual(composition.to_full_form(), "Composition[f, g]")
        self.assertEqual(right_composition.to_full_form(), "RightComposition[f, g]")
        self.assertEqual(map_apply.to_full_form(), "MapApply[f, xs]")
        self.assertEqual(dot_expr.to_full_form(), "Dot[List[a, b], List[c, d]]")
        self.assertEqual(string_join.to_full_form(), 'StringJoin[StringJoin["a", "b"], "c"]')
        self.assertEqual(output_history.to_full_form(), "Plus[Plus[Out[-1], Out[-2]], Out[12]]")
        self.assertEqual(same_q.to_input_form(), "a === b")
        self.assertEqual(unsame_q.to_input_form(), "a =!= b")
        self.assertEqual(composition.to_input_form(), "f @* g")
        self.assertEqual(right_composition.to_input_form(), "f /* g")
        self.assertEqual(map_apply.to_input_form(), "f @@@ xs")
        self.assertEqual(dot_expr.to_input_form(), "{a, b} . {c, d}")
        self.assertEqual(string_join.to_input_form(), '"a" <> "b" <> "c"')
        self.assertEqual(output_history.to_input_form(), "% + %% + Out[12]")

    def test_parse_assignment_and_update_operator_forms_as_inert_heads(self) -> None:
        examples = {
            "Hold[a = 2]": "Hold[Set[a, 2]]",
            "Hold[a := 2]": "Hold[SetDelayed[a, 2]]",
            "Hold[a = b = c]": "Hold[Set[a, Set[b, c]]]",
            "Hold[x += 2]": "Hold[AddTo[x, 2]]",
            "Hold[x -= 2]": "Hold[SubtractFrom[x, 2]]",
            "Hold[x *= 2]": "Hold[TimesBy[x, 2]]",
            "Hold[x /= 2]": "Hold[DivideBy[x, 2]]",
            "Hold[x =.]": "Hold[Unset[x]]",
            "Hold[x = .]": "Hold[Unset[x]]",
            "Hold[lhs ^= rhs]": "Hold[UpSet[lhs, rhs]]",
            "Hold[lhs ^:= rhs]": "Hold[UpSetDelayed[lhs, rhs]]",
            "Hold[f /: lhs = rhs]": "Hold[TagSet[f, lhs, rhs]]",
            "Hold[f /: lhs := rhs]": "Hold[TagSetDelayed[f, lhs, rhs]]",
            "Hold[f /: lhs =.]": "Hold[TagUnset[f, lhs]]",
            "Hold[f /: lhs = .]": "Hold[TagUnset[f, lhs]]",
        }
        for source, expected in examples.items():
            with self.subTest(source=source):
                expr = parse_input_form(source)
                self.assertEqual(expr.to_full_form(), expected)

        self.assertEqual(parse_input_form("Hold[a = 2]").to_input_form(), "Hold[a = 2]")
        self.assertEqual(parse_input_form("Hold[f /: lhs := rhs]").to_input_form(), "Hold[f /: lhs := rhs]")

    def test_parse_remaining_ascii_operator_forms_as_inert_heads(self) -> None:
        examples = {
            "Hold[x++]": "Hold[Increment[x]]",
            "Hold[++x]": "Hold[PreIncrement[x]]",
            "Hold[x--]": "Hold[Decrement[x]]",
            "Hold[--x]": "Hold[PreDecrement[x]]",
            "Hold[x!]": "Hold[Factorial[x]]",
            "Hold[x!!]": "Hold[Factorial2[x]]",
            "Hold[fn'[x] + fn''[x]]": "Hold[Plus[Derivative[1][fn][x], Derivative[2][fn][x]]]",
            "Hold[Int[a_.*x_, x_Symbol]]": "Hold[Int[Times[Optional[Pattern[a, Blank[]]], Pattern[x, Blank[]]], Pattern[x, Blank[Symbol]]]]",
            "Hold[c_. pf_Foo]": "Hold[Times[Optional[Pattern[c, Blank[]]], Pattern[pf, Blank[Foo]]]]",
            "Hold[x_ n_ /; DataType[n, FCVariable]]": "Hold[Condition[Times[Pattern[x, Blank[]], Pattern[n, Blank[]]], DataType[n, FCVariable]]]",
            "Hold[x_ n_]": "Hold[Times[Pattern[x, Blank[]], Pattern[n, Blank[]]]]",
            "Hold[a::b]": 'Hold[MessageName[a, "b"]]',
            'Hold[a::"b"]': 'Hold[MessageName[a, "b"]]',
            "Hold[a::b::c]": 'Hold[MessageName[a, "b", "c"]]',
            "Hold[a ** b]": "Hold[NonCommutativeMultiply[a, b]]",
            "Hold[Abs[#1.#2] >= 0.98 &]": "Hold[Function[GreaterEqual[Abs[Dot[Slot[1], Slot[2]]], 0.98]]]",
            "Hold[f[#1] #2 &]": "Hold[Function[Times[f[Slot[1]], Slot[2]]]]",
            "Hold[4 #[[1]] &]": "Hold[Function[Times[4, Part[Slot[1], 1]]]]",
            "Hold[a ~ f ~ b]": "Hold[f[a, b]]",
            "Hold[a~f~b*c]": "Hold[Times[f[a, b], c]]",
            "Hold[a <-> b]": "Hold[TwoWayRule[a, b]]",
            "Hold[<< foo]": 'Hold[Get["foo"]]',
            "Hold[x >> file]": 'Hold[Put[x, "file"]]',
            "Hold[x >>> file]": 'Hold[PutAppend[x, "file"]]',
            "Hold[?foo]": 'Hold[Information["foo", Rule[LongForm, False]]]',
            "Hold[??foo]": 'Hold[Information["foo", Rule[LongForm, True]]]',
            "Hold[x;]": "Hold[CompoundExpression[x, Null]]",
            "Hold[16^^ff]": "Hold[255]",
            "Hold[1.23``20]": "Hold[1.23``20]",
        }
        for source, expected in examples.items():
            with self.subTest(source=source):
                expr = parse_input_form(source)
                self.assertEqual(expr.to_full_form(), expected)

        self.assertEqual(parse_input_form("Hold[a::b::c]").to_input_form(), "Hold[a::b::c]")
        self.assertEqual(parse_input_form("Hold[x!!]").to_input_form(), "Hold[x!!]")
        self.assertEqual(parse_input_form("Hold[fn''[x]]").to_input_form(), "Hold[fn''[x]]")
        self.assertEqual(parse_input_form("Hold[#1.#2 &]").to_input_form(), "Hold[# . #2 &]")
        self.assertEqual(parse_input_form("Hold[<< foo]").to_input_form(), "Hold[<< foo]")

    def test_input_form_uses_operator_forms_without_unnecessary_parentheses(self) -> None:
        downvalue = parse_full_form("RuleDelayed[HoldPattern[In[1]], Range[10]]")
        downvalue_with_replacement = parse_full_form(
            "RuleDelayed[HoldPattern[In[2]], ReplaceAll[Range[10], Rule[5, 55]]]"
        )
        held_replacement = parse_full_form("Hold[ReplaceAll[Range[10], Rule[5, 55]]]")
        typed_sequence = parse_input_form("__Integer")
        null_sequence = parse_input_form("___")
        map_expr = parse_input_form("f /@ xs")
        apply_expr = parse_input_form("f @@ xs")
        map_all_expr = parse_input_form("f //@ xs")

        self.assertEqual(downvalue.to_input_form(), "HoldPattern[In[1]] :> Range[10]")
        self.assertEqual(
            downvalue_with_replacement.to_input_form(),
            "HoldPattern[In[2]] :> (Range[10] /. 5 -> 55)",
        )
        self.assertEqual(held_replacement.to_input_form(), "Hold[Range[10] /. 5 -> 55]")
        self.assertEqual(typed_sequence.to_input_form(), "__Integer")
        self.assertEqual(null_sequence.to_input_form(), "___")
        self.assertEqual(map_expr.to_input_form(), "f /@ xs")
        self.assertEqual(apply_expr.to_input_form(), "f @@ xs")
        self.assertEqual(map_all_expr.to_input_form(), "f //@ xs")

    def test_parser_skips_comments_inside_expression(self) -> None:
        expr = parse_input_form('f["alpha", (* ignored *) beta]')
        self.assertEqual(expr.to_full_form(), 'f["alpha", beta]')

        self.assertEqual(parse_input_form("(* comment-only file *)").to_full_form(), "Null")

        quote_in_comment = parse_input_form('Hold[a (* Message[f::\\"tag\\"], *) + b]')
        self.assertEqual(quote_in_comment.to_full_form(), "Hold[Plus[a, b]]")

        continued = parse_input_form("Hold[a + \\\r\n b]")
        self.assertEqual(continued.to_full_form(), "Hold[Plus[a, b]]")

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

    def test_string_expression_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("StringExpression.nb", 95944117)
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), 'StringExpression["ab", Blank[]]')

    def test_string_contains_q_repeated_digit_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("StringContainsQ.nb", 59481413)
        expr = parse_standard_form(source)
        self.assertEqual(expr.to_full_form(), 'StringContainsQ["a1 and a2", Repeated[DigitCharacter]]')

    def test_string_position_startofstring_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("StringEndsQ.nb", 1560366778)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            'StringPosition["agaatcgagttgacacgaccgaaaacgacc", StringExpression[StringExpression[StringExpression[StartOfString, Pattern[x, Blank[]]], BlankSequence[]], Pattern[x, Blank[]]]]',
        )

    def test_freeq_integer_example_from_docs_parses_standard_form(self) -> None:
        source = self._extract_boxdata_by_cell_id("FreeQ.nb", 205371076)
        expr = parse_standard_form(source)
        self.assertEqual(
            expr.to_full_form(),
            "FreeQ[List[a, b, b, a, a, a], Blank[Integer]]",
        )

    def test_named_character_symbols_and_inert_operators_parse_in_standard_form(self) -> None:
        escaped_operator = parse_standard_form(r"a \[CirclePlus] b")
        greek_symbols = parse_standard_form(r"\[Alpha] + \[Beta]")
        self.assertEqual(escaped_operator.to_full_form(), "CirclePlus[a, b]")
        self.assertEqual(greek_symbols.to_full_form(), r"Plus[\[Alpha], \[Beta]]")

    def test_row_box_named_character_operator_parses_in_standard_form(self) -> None:
        expr = parse_standard_form(r'RowBox[{"a", "\\[CirclePlus]", "b"}]')
        self.assertEqual(expr.to_full_form(), "CirclePlus[a, b]")

    def test_common_script_boxes_parse_in_standard_form(self) -> None:
        subscript = parse_standard_form('SubscriptBox["x", "i"]')
        subsuperscript = parse_standard_form('SubsuperscriptBox["x", "i", "2"]')
        overscript = parse_standard_form('OverscriptBox["x", "~"]')
        underoverscript = parse_standard_form('UnderoverscriptBox["x", "a", "b"]')
        self.assertEqual(subscript.to_full_form(), "Subscript[x, i]")
        self.assertEqual(subsuperscript.to_full_form(), "Subsuperscript[x, i, 2]")
        self.assertEqual(overscript.to_full_form(), 'Overscript[x, "~"]')
        self.assertEqual(underoverscript.to_full_form(), "Underoverscript[x, a, b]")


class ExpressionEvaluationTests(unittest.TestCase):
    def assert_evaluates_with_message(
        self,
        source: str,
        expected_full_form: str,
        expected_message_name: str | None = None,
    ) -> None:
        session = EvaluationSession()
        parsed = parse_input_form(source)
        session.begin_input(source, parsed)
        result = evaluate(parsed, session=session)
        session.finish_output(result)
        self.assertEqual(result.to_full_form(), expected_full_form)
        assert session.message_history is not None
        messages = session.message_history[session.line]
        self.assertTrue(messages)
        if expected_message_name is not None:
            self.assertEqual(messages[0].name.to_input_form(), expected_message_name)

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

    def test_sequence_and_nothing_follow_argument_list_rules(self) -> None:
        self.assertEqual(evaluate(parse_input_form("{Sequence[1, 2], 3}")).to_full_form(), "List[1, 2, 3]")
        self.assertEqual(evaluate(parse_input_form("f[Sequence[1, 2], 3]")).to_full_form(), "f[1, 2, 3]")
        self.assertEqual(
            evaluate(parse_input_form("Hold[Sequence[1 + 1, 2 + 2]]")).to_full_form(),
            "Hold[Plus[1, 1], Plus[2, 2]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("HoldComplete[Sequence[1 + 1, 2 + 2]]")).to_full_form(),
            "HoldComplete[Sequence[Plus[1, 1], Plus[2, 2]]]",
        )
        self.assertEqual(evaluate(parse_input_form("Function[Sequence[x, x + x]][a]")).to_full_form(), "Plus[a, a]")
        self.assertEqual(evaluate(parse_input_form("{Sequence[Nothing, 1], 2}")).to_full_form(), "List[1, 2]")
        self.assertEqual(evaluate(parse_input_form("f[Sequence[Nothing, 1], 2]")).to_full_form(), "f[Nothing, 1, 2]")
        self.assertEqual(evaluate(parse_input_form("{Nothing[1 + 1], 2}")).to_full_form(), "List[2]")
        self.assertEqual(evaluate(parse_input_form("f[Nothing, 1]")).to_full_form(), "f[Nothing, 1]")
        self.assertEqual(evaluate(parse_input_form("Nothing[1 + 1]")).to_full_form(), "Nothing")
        self.assertEqual(evaluate(parse_input_form("Hold[Nothing]")).to_full_form(), "Hold[Nothing]")
        self.assertEqual(evaluate(parse_input_form("ReleaseHold[Hold[{Nothing, 1}]]")).to_full_form(), "List[1]")

    def test_evaluation_control_heads_match_wolfram_ordering(self) -> None:
        inactive_sum = evaluate(parse_input_form("Inactive[Plus][1, 2]"))
        inactive_evaluates_arguments = evaluate(parse_input_form("Inactive[Plus][1 + 2, 3 + 4]"))
        inactive_non_symbol_atom = evaluate(parse_input_form("Inactive[3]"))
        inactive_direct_evaluate = evaluate(parse_input_form("Inactive[Evaluate[1 + 2]]"))
        activated_sum = evaluate(parse_input_form("Activate[Inactive[Plus][1, 2]]"))
        activated_held_sum = evaluate(parse_input_form("Activate[Hold[Inactive[Plus][1, 2]]]"))
        activated_times_only = evaluate(parse_input_form("Activate[Inactive[Plus][Inactive[Times][2, 3], 4], Times]"))
        evaluate_in_hold = evaluate(parse_input_form("Hold[Evaluate[1 + 2]]"))
        evaluate_in_hold_complete = evaluate(parse_input_form("HoldComplete[Evaluate[1 + 2]]"))
        evaluate_unevaluated_top_level = evaluate(parse_input_form("Evaluate[Unevaluated[1 + 2]]"))
        evaluate_unevaluated_in_hold = evaluate(parse_input_form("Hold[Evaluate[Unevaluated[1 + 2]]]"))
        length_unevaluated = evaluate(parse_input_form("Length[Unevaluated[1 + 2]]"))
        head_unevaluated = evaluate(parse_input_form("Head[Unevaluated[1 + 2]]"))
        part_unevaluated = evaluate(parse_input_form("Part[Unevaluated[f[a, b]], 1]"))

        self.assertEqual(inactive_sum.to_full_form(), "Inactive[Plus][1, 2]")
        self.assertEqual(inactive_evaluates_arguments.to_full_form(), "Inactive[Plus][3, 7]")
        self.assertEqual(inactive_non_symbol_atom.to_full_form(), "3")
        self.assertEqual(inactive_direct_evaluate.to_full_form(), "3")
        self.assertEqual(activated_sum.to_full_form(), "3")
        self.assertEqual(activated_held_sum.to_full_form(), "Hold[Plus[1, 2]]")
        self.assertEqual(activated_times_only.to_full_form(), "Inactive[Plus][6, 4]")
        self.assertEqual(evaluate_in_hold.to_full_form(), "Hold[3]")
        self.assertEqual(evaluate_in_hold_complete.to_full_form(), "HoldComplete[Evaluate[Plus[1, 2]]]")
        self.assertEqual(evaluate_unevaluated_top_level.to_full_form(), "3")
        self.assertEqual(evaluate_unevaluated_in_hold.to_full_form(), "Hold[Unevaluated[Plus[1, 2]]]")
        self.assertEqual(length_unevaluated.to_full_form(), "2")
        self.assertEqual(head_unevaluated.to_full_form(), "Plus")
        self.assertEqual(part_unevaluated.to_full_form(), "a")

    def test_abort_throw_and_catch_follow_nonlocal_control_flow(self) -> None:
        self.assertEqual(evaluate(parse_input_form("Abort[]")).to_full_form(), "$Aborted")
        self.assertEqual(evaluate(parse_input_form("1 + Abort[]")).to_full_form(), "$Aborted")
        self.assertEqual(evaluate(parse_input_form("Catch[Abort[]]")).to_full_form(), "$Aborted")

        self.assertEqual(evaluate(parse_input_form("Catch[1 + Throw[x] + 3]")).to_full_form(), "x")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[1 + 2]]")).to_full_form(), "3")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag], tag]")).to_full_form(), "x")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag], _Symbol]")).to_full_form(), "x")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag], tag, h]")).to_full_form(), "h[x, tag]")
        self.assertEqual(
            evaluate(parse_input_form("Catch[Throw[x, tag], tag, Function[{v, t}, h[v, t]]]")).to_full_form(),
            "h[x, tag]",
        )
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag], tag, Hold]")).to_full_form(), "Hold[x, tag]")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, 1 + 2], 3]")).to_full_form(), "x")
        self.assertEqual(
            evaluate(parse_input_form("Catch[Catch[Throw[x, inner], outer], inner]")).to_full_form(),
            "x",
        )
        self.assertEqual(evaluate(parse_input_form("Catch[Hold[Throw[x]]]")).to_full_form(), "Hold[Throw[x]]")

        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag]]")).to_full_form(), "Throw[x, tag]")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag], other]")).to_full_form(), "Throw[x, tag]")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x], _]")).to_full_form(), "Throw[x]")
        self.assertEqual(evaluate(parse_input_form("Throw[x, tag, h]")).to_full_form(), "h[x, tag]")
        self.assertEqual(evaluate(parse_input_form("Catch[Throw[x, tag, h], tag]")).to_full_form(), "x")
        self.assertEqual(evaluate(parse_input_form("Catch[Catch[Throw[x, tag, h], other], _]")).to_full_form(), "x")

    def test_sow_reap_collect_nearest_matching_tags(self) -> None:
        self.assertEqual(evaluate(parse_input_form("Sow[1]")).to_full_form(), "1")
        self.assertEqual(
            evaluate(parse_input_form("Reap[Sow[1]; Sow[2]; 3]")).to_full_form(),
            "List[3, List[List[1, 2]]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("Reap[Sow[1, a]; Sow[2, b]; 3]")).to_full_form(),
            "List[3, List[List[1], List[2]]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("Reap[Sow[1, a]; Sow[2, b]; 3, a]")).to_full_form(),
            "List[3, List[List[1]]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("Reap[Sow[1, {a, b}]; 3, {a, b}]")).to_full_form(),
            "List[3, List[List[List[1]], List[List[1]]]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("Reap[Sow[1, a]; Sow[2, a]; 3, _, f]")).to_full_form(),
            "List[3, List[f[a, List[1, 2]]]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("Reap[Sow[1]; 3, _, f]")).to_full_form(),
            "List[3, List[f[None, List[1]]]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("Reap[Reap[Sow[1, a]; 2, a], _]")).to_full_form(),
            "List[List[2, List[List[1]]], List[]]",
        )

    def test_check_abort_abort_protect_and_timing_control_flow(self) -> None:
        self.assertEqual(evaluate(parse_input_form("CheckAbort[Abort[], fail]")).to_full_form(), "fail")
        self.assertEqual(
            evaluate(parse_input_form('CheckAbort[AbortProtect[Abort[]; Print["after"]; 7], fail]')).to_full_form(),
            "fail",
        )
        self.assertEqual(
            evaluate(parse_input_form("CheckAbort[AbortProtect[CheckAbort[Abort[], inner]; 7], fail]")).to_full_form(),
            "7",
        )
        self.assertEqual(evaluate(parse_input_form("AbortProtect[CheckAbort[Abort[], inner]]")).to_full_form(), "inner")
        self.assertEqual(evaluate(parse_input_form("Pause[0]")).to_full_form(), "Null")
        self.assertEqual(evaluate(parse_input_form("TimeRemaining[]")).to_full_form(), "Infinity")
        self.assertEqual(evaluate(parse_input_form("TimeConstrained[Pause[0]; 7, 1, fail]")).to_full_form(), "7")
        self.assertEqual(
            evaluate(parse_input_form("TimeConstrained[Pause[0.02]; 7, 0.001, fail]")).to_full_form(),
            "fail",
        )
        self.assertEqual(
            evaluate(parse_input_form("TimeConstrained[Pause[0.02]; 7, 0.001]")).to_full_form(),
            "$Aborted",
        )
        self.assertEqual(
            evaluate(
                parse_input_form("CheckAbort[AbortProtect[TimeConstrained[Pause[.02]; 7, .001, inner]], fail]")
            ).to_full_form(),
            "inner",
        )
        time_remaining = evaluate(parse_input_form("TimeConstrained[TimeRemaining[], 1, fail]"))
        self.assertIsInstance(time_remaining, Real)
        self.assertGreaterEqual(float(time_remaining.text), 0.0)
        self.assertLessEqual(float(time_remaining.text), 1.0)

        timing = evaluate(parse_input_form("AbsoluteTiming[1 + 2]"))
        self.assertEqual(timing.head().to_full_form(), "List")
        self.assertIsInstance(timing.arguments[0], Real)
        self.assertEqual(timing.arguments[1].to_full_form(), "3")

    def test_failure_missing_confirm_enclose_assert_and_failsafe(self) -> None:
        self.assertEqual(evaluate(parse_input_form('FailureQ[Failure["x", <||>]]')).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("FailureQ[$Failed]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("FailureQ[$Canceled]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("FailureQ[$Aborted]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form('FailureQ[Missing["x"]]')).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form('MissingQ[Missing["x"]]')).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("MissingQ[$Failed]")).to_full_form(), "False")

        self.assertEqual(evaluate(parse_input_form("Enclose[1 + Confirm[2]]")).to_full_form(), "3")
        self.assertEqual(
            evaluate(parse_input_form('Enclose[Confirm[Missing["Nope"], "info"], "Expression"]')).to_full_form(),
            'Missing["Nope"]',
        )
        self.assertEqual(
            evaluate(parse_input_form('Enclose[Confirm[Missing["Nope"], "info"], "Information"]')).to_full_form(),
            '"info"',
        )
        self.assertEqual(evaluate(parse_input_form("Enclose[ConfirmBy[3, IntegerQ]]")).to_full_form(), "3")
        self.assertEqual(
            evaluate(parse_input_form('Enclose[ConfirmBy[3, StringQ, "info"], "Function"]')).to_full_form(),
            "StringQ",
        )
        self.assertEqual(evaluate(parse_input_form("Enclose[ConfirmMatch[3, _Integer]]")).to_full_form(), "3")
        self.assertEqual(
            evaluate(parse_input_form('Enclose[ConfirmMatch[3, _String, "info"], "Pattern"]')).to_full_form(),
            "Blank[String]",
        )
        self.assertEqual(evaluate(parse_input_form("Enclose[ConfirmAssert[True]]")).to_full_form(), "Null")
        self.assertEqual(
            evaluate(parse_input_form('Enclose[ConfirmAssert[1 + 1 == 3, "bad"], "Information"]')).to_full_form(),
            '"bad"',
        )
        self.assertEqual(
            evaluate(parse_input_form('Enclose[Confirm[$Failed, "info", tag], "Information", tag]')).to_full_form(),
            '"info"',
        )

        self.assertEqual(evaluate(parse_input_form("Failsafe[f][1, 2]")).to_full_form(), "f[1, 2]")
        self.assertEqual(
            evaluate(parse_input_form('Failsafe[f][1, Missing["x"], Failure["bad", <||>]]')).to_full_form(),
            'Missing["x"]',
        )
        self.assertEqual(evaluate(parse_input_form("Failsafe[f, SameQ][1, 1]")).to_full_form(), "f[1, 1]")
        self.assertEqual(
            evaluate(parse_input_form('Failsafe[f, SameQ][1, 2]["Type"]')).to_full_form(),
            "FailsafeFailed",
        )
        self.assertEqual(evaluate(parse_input_form("Failsafe[f, SameQ, g][1, 2]")).to_full_form(), "g[1, 2]")

    def test_assert_on_off_and_with_cleanup_control_flow(self) -> None:
        session = EvaluationSession()

        def submit(code: str) -> str:
            parsed = parse_input_form(code)
            session.begin_input(code, parsed)
            result = evaluate(parsed, session=session)
            session.finish_output(result)
            return result.to_full_form()

        self.assertEqual(submit('Assert[Print["x"]; False]'), 'Assert[CompoundExpression[Print["x"], False]]')
        assert session.print_history is not None
        self.assertEqual(session.print_history[1], ())
        self.assertEqual(submit("On[Assert]"), "Null")
        self.assertEqual(submit("Assert[True]"), "Null")
        self.assertEqual(submit("Check[Assert[False, tag], msg]"), "msg")
        assert session.message_history is not None
        self.assertEqual([message.name.to_input_form() for message in session.message_history[4]], ["Assert::asrtfl"])
        self.assertEqual(submit("Off[Assert]"), "Null")
        self.assertEqual(submit('Assert[Print["x"]; False]'), 'Assert[CompoundExpression[Print["x"], False]]')
        self.assertEqual(session.print_history[6], ())

        self.assertEqual(submit('WithCleanup[1 + 2, Print["cleanup"]]'), "3")
        self.assertEqual(session.print_history[7], ("cleanup",))
        self.assertEqual(
            submit('CheckAbort[WithCleanup[Print["expr1"]; Abort[]; Print["expr2"], Print["cleanup"]], caught]'),
            "caught",
        )
        self.assertEqual(session.print_history[8], ("expr1", "cleanup"))
        self.assertEqual(
            submit(
                'CheckAbort[WithCleanup[Print["init1"]; Abort[]; Print["init2"], Print["expr"], Print["cleanup"]], caught]'
            ),
            "caught",
        )
        self.assertEqual(session.print_history[9], ("init1", "init2", "cleanup"))
        self.assertEqual(submit('Catch[WithCleanup[Throw[x], Print["cleanup"]]]'), "x")
        self.assertEqual(session.print_history[10], ("cleanup",))
        self.assertEqual(
            submit('Enclose[WithCleanup[Confirm[$Failed, "bad"], Print["cleanup"]], "Information"]'),
            '"bad"',
        )
        self.assertEqual(session.print_history[11], ("cleanup",))
        self.assertEqual(
            submit('TimeConstrained[WithCleanup[Pause[0.02]; 7, Print["cleanup"]], 0.001, timeout]'),
            "timeout",
        )
        self.assertEqual(session.print_history[12], ("cleanup",))

    def test_messages_check_quiet_off_on_print_and_message_history(self) -> None:
        session = EvaluationSession()

        def submit(code: str) -> str:
            parsed = parse_input_form(code)
            session.begin_input(code, parsed)
            result = evaluate(parsed, session=session)
            session.finish_output(result)
            return result.to_full_form()

        self.assertEqual(submit("Part[f[a], 2]"), "Part[f[a], 2]")
        assert session.message_history is not None
        self.assertEqual(session.message_history[1][0].name.to_input_form(), "Part::error")
        self.assertEqual(submit("MessageList[1]"), 'List[HoldForm[MessageName[Part, "error"]]]')

        self.assertEqual(submit("Check[Part[f[a], 2], fallback]"), "fallback")
        self.assertEqual(submit("Check[Part[f[a], 2], fallback, Other::error]"), "Part[f[a], 2]")
        self.assertEqual(submit("Check[Part[f[a], 2], $MessageList]"), 'List[HoldForm[MessageName[Part, "error"]]]')

        self.assertEqual(submit("Quiet[Part[f[a], 2]]"), "Part[f[a], 2]")
        self.assertEqual(session.message_history[6], ())
        self.assertEqual(submit("Check[Quiet[Part[f[a], 2]], fallback]"), "Part[f[a], 2]")
        self.assertEqual(submit("Quiet[Check[Part[f[a], 2], fallback]]"), "fallback")
        self.assertEqual(session.message_history[8], ())

        self.assertEqual(submit("Off[f::tag]"), "Null")
        self.assertEqual(submit("Check[Message[f::tag], fallback]"), "Null")
        self.assertEqual(session.message_history[10], ())
        self.assertEqual(submit("On[f::tag]"), "Null")
        self.assertEqual(submit("Check[Message[f::tag], fallback]"), "fallback")

        self.assertEqual(submit('Print["a", 1 + 2, x]'), "Null")
        assert session.print_history is not None
        self.assertEqual(session.print_history[13], ("a3x",))
        self.assertEqual(submit("Print[InputForm[{1, 2/3, a + b}]]"), "Null")
        self.assertEqual(session.print_history[14], ("{1, 2/3, a + b}",))
        self.assertEqual(submit("Print[FullForm[{1, 2/3, a + b}]]"), "Null")
        self.assertEqual(session.print_history[15], ("List[1, Rational[2, 3], Plus[a, b]]",))

    def test_ignoring_inactive_patterns_match_active_and_inactive_forms(self) -> None:
        inactive_match = evaluate(parse_input_form("MatchQ[Inactive[f][1], IgnoringInactive[f[_]]]"))
        active_pattern_match = evaluate(
            parse_input_form("MatchQ[Inactive[Plus][1, 2], IgnoringInactive[HoldPattern[Plus[_, _]]]]")
        )
        free_q = evaluate(parse_input_form("FreeQ[{Inactive[Plus][1, 2]}, IgnoringInactive[HoldPattern[Plus[_, _]]]]"))
        cases = evaluate(
            parse_input_form("Cases[{Inactive[Plus][1, 2], Inactive[f][1]}, IgnoringInactive[HoldPattern[Plus[_, _]]]]")
        )
        replacement = evaluate(parse_input_form("Inactive[f][1] /. IgnoringInactive[f[x_]] :> x"))
        original_binding = evaluate(parse_input_form("Inactive[f][Inactive[g][1]] /. IgnoringInactive[f[x_]] :> x"))
        inactive_wrapper_binding = evaluate(parse_input_form("Inactive[f[1]] /. IgnoringInactive[f[x_]] :> x"))

        self.assertEqual(inactive_match.to_full_form(), "True")
        self.assertEqual(active_pattern_match.to_full_form(), "True")
        self.assertEqual(free_q.to_full_form(), "False")
        self.assertEqual(cases.to_full_form(), "List[Inactive[Plus][1, 2]]")
        self.assertEqual(replacement.to_full_form(), "1")
        self.assertEqual(original_binding.to_full_form(), "Inactive[g][1]")
        self.assertEqual(inactive_wrapper_binding.to_full_form(), "1")

    def test_nothing_is_removed_from_evaluated_list_results_only(self) -> None:
        self.assertEqual(evaluate(parse_input_form("<|Nothing, a -> 1|>")).to_full_form(), "Association[Rule[a, 1]]")
        self.assertEqual(
            evaluate(parse_input_form("<|a -> Nothing, b -> 1|>")).to_full_form(),
            "Association[Rule[a, Nothing], Rule[b, 1]]",
        )
        self.assertEqual(evaluate(parse_input_form("{a, b} /. a -> Nothing")).to_full_form(), "List[b]")
        self.assertEqual(
            evaluate(parse_input_form("Hold[{a, b}] /. a -> Nothing")).to_full_form(),
            "Hold[List[Nothing, b]]",
        )
        self.assertEqual(evaluate(parse_input_form("f[a, b] /. a -> Nothing")).to_full_form(), "f[Nothing, b]")
        self.assertEqual(evaluate(parse_input_form("Cases[{1, 2, 3}, 2 :> Nothing]")).to_full_form(), "List[]")
        self.assertEqual(evaluate(parse_input_form("Map[If[# > 0, #, Nothing] &, {-1, 2}]")).to_full_form(), "List[2]")
        self.assertEqual(evaluate(parse_input_form("Values[<|a -> Nothing, b -> 1|>]")).to_full_form(), "List[1]")
        self.assertEqual(evaluate(parse_input_form("Lookup[<|a -> Nothing, b -> 1|>, {a, b}]")).to_full_form(), "List[1]")
        self.assertEqual(evaluate(parse_input_form("Keys[<|Nothing -> 1, a -> 2|>]")).to_full_form(), "List[a]")
        self.assertEqual(evaluate(parse_input_form("Level[Hold[Nothing], {-1}]")).to_full_form(), "List[]")
        self.assertEqual(evaluate(parse_input_form("ReplacePart[{a, b}, 1 -> Nothing]")).to_full_form(), "List[b]")
        self.assertEqual(evaluate(parse_input_form("MapAt[Nothing &, {a, b}, 1]")).to_full_form(), "List[b]")
        self.assertEqual(evaluate(parse_input_form("ConstantArray[Nothing, 3]")).to_full_form(), "List[]")
        self.assertEqual(evaluate(parse_input_form("Array[Nothing &, 3]")).to_full_form(), "List[]")

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
        self.assertEqual(mixed_operator.to_full_form(), "Less[1, 2, a]")

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
        self.assertEqual(result.to_full_form(), "List[a, b, g[b]]")

    def test_level_positive_two_returns_first_two_levels(self) -> None:
        result = evaluate(parse_input_form("Level[f[a, g[b]], 2]"))
        self.assertEqual(result.to_full_form(), "List[a, b, g[b]]")

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
        slot_sequence = evaluate(parse_input_form("(f[##] &)[a, b, c]"))
        slot_sequence_from_second = evaluate(parse_input_form("(f[##2] &)[a, b, c]"))
        slot_sequence_top_level = evaluate(parse_input_form("(## &)[a, b]"))
        slot_sequence_missing = evaluate(parse_input_form("(f[##4] &)[a, b, c]"))
        self.assertEqual(applied.to_full_form(), "Plus[a, 1]")
        self.assertEqual(explicit_slot.to_full_form(), "x")
        self.assertEqual(apply_result.to_full_form(), "Plus[a, b]")
        self.assertEqual(map_result.to_full_form(), "List[Plus[a, 1], Plus[b, 1]]")
        self.assertEqual(map_at_result.to_full_form(), "g[a, f[b]]")
        self.assertEqual(named.to_full_form(), 'obj["name"]')
        self.assertEqual(slot_sequence.to_full_form(), "f[a, b, c]")
        self.assertEqual(slot_sequence_from_second.to_full_form(), "f[b, c]")
        self.assertEqual(slot_sequence_top_level.to_full_form(), "Sequence[a, b]")
        self.assertEqual(slot_sequence_missing.to_full_form(), "f[]")

    def test_pure_functions_support_self_reference_and_nested_lexical_scoping(self) -> None:
        self_reference = evaluate(parse_input_form("(#0&)[x]"))
        nested = evaluate(parse_input_form("Function[Function[#1]][a][b]"))
        nested_slot_sequence = evaluate(parse_input_form("Function[Function[f[##]]][a, b][c, d]"))
        self.assertEqual(self_reference.to_full_form(), "Function[Slot[0]]")
        self.assertEqual(nested.to_full_form(), "b")
        self.assertEqual(nested_slot_sequence.to_full_form(), "f[c, d]")

    def test_pure_function_slot_errors_surface_when_argument_is_missing(self) -> None:
        self.assert_evaluates_with_message("(#2&)[a]", "Function[Slot[2]][a]", "General::error")
        self.assert_evaluates_with_message(
            "(f[##0]&)[a]",
            "Function[f[SlotSequence[0]]][a]",
            "General::error",
        )

    def test_pure_function_attributes_control_argument_evaluation_and_threading(self) -> None:
        default_eval = evaluate(parse_input_form("Function[Null, HoldComplete[#]][1 + 2]"))
        hold_all = evaluate(parse_input_form("Function[Null, HoldComplete[#], HoldAll][1 + 2]"))
        attrs_list = evaluate(parse_input_form("Function[Null, HoldComplete[#], {HoldAll}][1 + 2]"))
        hold_first = evaluate(parse_input_form("Function[Null, HoldComplete[#1, #2], HoldFirst][1 + 2, 3 + 4]"))
        hold_rest = evaluate(parse_input_form("Function[Null, HoldComplete[#1, #2], HoldRest][1 + 2, 3 + 4]"))
        hold_all_pair = evaluate(parse_input_form("Function[Null, HoldComplete[#1, #2], HoldAll][1 + 2, 3 + 4]"))
        sequence_spliced = evaluate(parse_input_form("Function[Null, HoldComplete[##]][Sequence[a, b]]"))
        sequence_held = evaluate(parse_input_form("Function[Null, HoldComplete[##], SequenceHold][Sequence[a, b]]"))
        hold_all_complete = evaluate(
            parse_input_form("Function[Null, HoldComplete[##], HoldAllComplete][Sequence[1 + 2, 3 + 4]]")
        )
        listable = evaluate(parse_input_form("Function[Null, f[#], Listable][{a, b}]"))
        listable_named = evaluate(parse_input_form("Function[{x, y}, f[x, y], Listable][{a, b}, {c, d}]"))
        listable_scalar = evaluate(parse_input_form("Function[Null, f[#1, #2], Listable][{a, b}, z]"))
        listable_hold_all = evaluate(
            parse_input_form("Function[Null, HoldComplete[#], {Listable, HoldAll}][{1 + 2, 3 + 4}]")
        )
        self.assertEqual(default_eval.to_full_form(), "HoldComplete[3]")
        self.assertEqual(hold_all.to_full_form(), "HoldComplete[Plus[1, 2]]")
        self.assertEqual(attrs_list.to_full_form(), "HoldComplete[Plus[1, 2]]")
        self.assertEqual(hold_first.to_full_form(), "HoldComplete[Plus[1, 2], 7]")
        self.assertEqual(hold_rest.to_full_form(), "HoldComplete[3, Plus[3, 4]]")
        self.assertEqual(hold_all_pair.to_full_form(), "HoldComplete[Plus[1, 2], Plus[3, 4]]")
        self.assertEqual(sequence_spliced.to_full_form(), "HoldComplete[a, b]")
        self.assertEqual(sequence_held.to_full_form(), "HoldComplete[Sequence[a, b]]")
        self.assertEqual(hold_all_complete.to_full_form(), "HoldComplete[Sequence[Plus[1, 2], Plus[3, 4]]]")
        self.assertEqual(listable.to_full_form(), "List[f[a], f[b]]")
        self.assertEqual(listable_named.to_full_form(), "List[f[a, c], f[b, d]]")
        self.assertEqual(listable_scalar.to_full_form(), "List[f[a, z], f[b, z]]")
        self.assertEqual(
            listable_hold_all.to_full_form(),
            "List[HoldComplete[Plus[1, 2]], HoldComplete[Plus[3, 4]]]",
        )

        self.assert_evaluates_with_message(
            "Function[Null, f[#1, #2], Listable][{a, b}, {c, d, e}]",
            "Function[Null, f[Slot[1], Slot[2]], Listable][List[a, b], List[c, d, e]]",
            "General::error",
        )

    def test_named_pure_functions_apply_with_capture_avoiding_renaming(self) -> None:
        direct = evaluate(parse_input_form("(Function[x, x + x])[a]"))
        list_syntax = evaluate(parse_input_form("(({x, y} |-> x + y))[a, b]"))
        escaped = evaluate(parse_input_form(r"(x \[Function] x + x)[a]"))
        nested_capture = evaluate(parse_input_form("(x |-> y |-> x[y])[y]"))
        nested_no_capture = evaluate(parse_input_form("(x |-> y |-> x[y])[z]"))
        liberal_rename = evaluate(parse_input_form("(x |-> y |-> f[x])[a]"))
        no_rename = evaluate(parse_input_form("(x |-> y |-> y)[a]"))
        shadowed = evaluate(parse_input_form("(x |-> x |-> x[y])[y]"))
        recursive = evaluate(parse_input_form("(x |-> y |-> z |-> {x, y, z})[y]"))
        positional_nested = evaluate(parse_input_form("(Function[x, # + x &])[a]"))
        self.assertEqual(direct.to_full_form(), "Plus[a, a]")
        self.assertEqual(list_syntax.to_full_form(), "Plus[a, b]")
        self.assertEqual(escaped.to_full_form(), "Plus[a, a]")
        self.assertEqual(nested_capture.to_full_form(), "Function[y$, y[y$]]")
        self.assertEqual(nested_no_capture.to_full_form(), "Function[y$, z[y$]]")
        self.assertEqual(liberal_rename.to_full_form(), "Function[y$, f[a]]")
        self.assertEqual(no_rename.to_full_form(), "Function[y, y]")
        self.assertEqual(shadowed.to_full_form(), "Function[x, x[y]]")
        self.assertEqual(recursive.to_full_form(), "Function[y$, Function[z$, List[y, y$, z$]]]")
        self.assertEqual(positional_nested.to_full_form(), "Function[Plus[Slot[1], a]]")

    def test_named_pure_function_errors_when_arguments_or_parameters_are_invalid(self) -> None:
        self.assert_evaluates_with_message(
            "(Function[{x, y}, x + y])[a]",
            "Function[List[x, y], Plus[x, y]][a]",
            "General::error",
        )
        self.assert_evaluates_with_message("(Function[f[x], x])[a]", "Function[f[x], x][a]", "General::error")

    def test_identity_sameq_unsameq_sameas_and_composition_family(self) -> None:
        identity = evaluate(parse_input_form("Identity[x]"))
        same_q = evaluate(parse_input_form("SameQ[a, a, a]"))
        unsame_q = evaluate(parse_input_form("UnsameQ[a, b, c]"))
        unsame_q_false = evaluate(parse_input_form("UnsameQ[a, b, a]"))
        same_as_true = evaluate(parse_input_form("SameAs[y][y]"))
        same_as_false = evaluate(parse_input_form("SameAs[y][x, y]"))
        composition = evaluate(parse_input_form("Composition[f, g][x]"))
        right_composition = evaluate(parse_input_form("RightComposition[f, g][x]"))
        compose_list = evaluate(parse_input_form("ComposeList[{f, g, h}, x]"))
        self.assertEqual(identity.to_full_form(), "x")
        self.assertEqual(same_q.to_full_form(), "True")
        self.assertEqual(unsame_q.to_full_form(), "True")
        self.assertEqual(unsame_q_false.to_full_form(), "False")
        self.assertEqual(same_as_true.to_full_form(), "True")
        self.assertEqual(same_as_false.to_full_form(), "False")
        self.assertEqual(composition.to_full_form(), "f[g[x]]")
        self.assertEqual(right_composition.to_full_form(), "g[f[x]]")
        self.assertEqual(compose_list.to_full_form(), "List[x, f[x], g[f[x]], h[g[f[x]]]]")

    def test_structural_callable_family_supports_map_scan_construct_and_through(self) -> None:
        scan_result = evaluate(parse_input_form("Scan[f, {a, b}]"))
        map_apply = evaluate(parse_input_form("MapApply[f, {g[a, b], h[c]}]"))
        map_apply_operator = evaluate(parse_input_form("MapApply[f][{g[a, b], h[c]}]"))
        map_all = evaluate(parse_input_form("MapAll[f, g[a, b]]"))
        map_indexed = evaluate(parse_input_form("MapIndexed[f, g[a, b]]"))
        construct = evaluate(parse_input_form("Construct[# + 1 &, 2]"))
        operate = evaluate(parse_input_form("Operate[p, f[x, y]]"))
        comap = evaluate(parse_input_form("Comap[{f, g}, x]"))
        comap_apply = evaluate(parse_input_form("ComapApply[{f, g}, {x, y}]"))
        through_result = evaluate(parse_input_form("Through[p[f, g][x, y]]"))
        self.assertEqual(scan_result.to_full_form(), "Null")
        self.assertEqual(map_apply.to_full_form(), "List[f[a, b], f[c]]")
        self.assertEqual(map_apply_operator.to_full_form(), "List[f[a, b], f[c]]")
        self.assertEqual(map_all.to_full_form(), "f[g[f[a], f[b]]]")
        self.assertEqual(map_indexed.to_full_form(), "g[f[a, List[1]], f[b, List[2]]]")
        self.assertEqual(construct.to_full_form(), "3")
        self.assertEqual(operate.to_full_form(), "p[f][x, y]")
        self.assertEqual(comap.to_full_form(), "List[f[x], g[x]]")
        self.assertEqual(comap_apply.to_full_form(), "List[f[x, y], g[x, y]]")
        self.assertEqual(through_result.to_full_form(), "p[f[x, y], g[x, y]]")

    def test_nesting_threading_arrays_and_linear_algebra_family(self) -> None:
        nest_result = evaluate(parse_input_form("Nest[f, x, 3]"))
        nest_list_result = evaluate(parse_input_form("NestList[f, x, 3]"))
        nest_while_result = evaluate(parse_input_form("NestWhile[# + 1 &, 0, # < 3 &]"))
        nest_while_list_result = evaluate(parse_input_form("NestWhileList[# + 1 &, 0, # < 3 &]"))
        fixed_point_result = evaluate(parse_input_form("FixedPoint[# /. a -> b &, a]"))
        fixed_point_list_result = evaluate(parse_input_form("FixedPointList[# /. a -> b &, a]"))
        map_thread_result = evaluate(parse_input_form("MapThread[f, {{a, b}, {c, d}}]"))
        thread_result = evaluate(parse_input_form("Thread[f[{a, b}, {c, d}]]"))
        outer_result = evaluate(parse_input_form("Outer[f, {a, b}, {c, d}]"))
        inner_result = evaluate(parse_input_form("Inner[f, {a, b}, {c, d}, g]"))
        dot_result = evaluate(parse_input_form("{a, b} . {c, d}"))
        tuples_result = evaluate(parse_input_form("Tuples[{{a, b}, {c, d}}]"))
        array_result = evaluate(parse_input_form("Array[f, 3]"))
        constant_array_result = evaluate(parse_input_form("ConstantArray[x, 3]"))
        range_result = evaluate(parse_input_form("Range[2, 5]"))
        unit_vector_result = evaluate(parse_input_form("UnitVector[4, 2]"))
        identity_matrix_result = evaluate(parse_input_form("IdentityMatrix[2]"))
        diagonal_matrix_result = evaluate(parse_input_form("DiagonalMatrix[{a, b}]"))
        partition_result = evaluate(parse_input_form("Partition[{a, b, c, d, e}, 2]"))
        take_list_result = evaluate(parse_input_form("TakeList[{a, b, c, d, e}, {2, 1}]"))
        take_drop_result = evaluate(parse_input_form("TakeDrop[{a, b, c, d}, 2]"))
        self.assertEqual(nest_result.to_full_form(), "f[f[f[x]]]")
        self.assertEqual(nest_list_result.to_full_form(), "List[x, f[x], f[f[x]], f[f[f[x]]]]")
        self.assertEqual(nest_while_result.to_full_form(), "3")
        self.assertEqual(nest_while_list_result.to_full_form(), "List[0, 1, 2, 3]")
        self.assertEqual(fixed_point_result.to_full_form(), "b")
        self.assertEqual(fixed_point_list_result.to_full_form(), "List[a, b, b]")
        self.assertEqual(map_thread_result.to_full_form(), "List[f[a, c], f[b, d]]")
        self.assertEqual(thread_result.to_full_form(), "List[f[a, c], f[b, d]]")
        self.assertEqual(
            outer_result.to_full_form(),
            "List[List[f[a, c], f[a, d]], List[f[b, c], f[b, d]]]",
        )
        self.assertEqual(inner_result.to_full_form(), "g[f[a, c], f[b, d]]")
        self.assertEqual(dot_result.to_full_form(), "Plus[Times[a, c], Times[b, d]]")
        self.assertEqual(tuples_result.to_full_form(), "List[List[a, c], List[a, d], List[b, c], List[b, d]]")
        self.assertEqual(array_result.to_full_form(), "List[f[1], f[2], f[3]]")
        self.assertEqual(constant_array_result.to_full_form(), "List[x, x, x]")
        self.assertEqual(range_result.to_full_form(), "List[2, 3, 4, 5]")
        self.assertEqual(unit_vector_result.to_full_form(), "List[0, 1, 0, 0]")
        self.assertEqual(identity_matrix_result.to_full_form(), "List[List[1, 0], List[0, 1]]")
        self.assertEqual(diagonal_matrix_result.to_full_form(), "List[List[a, 0], List[0, b]]")
        self.assertEqual(partition_result.to_full_form(), "List[List[a, b], List[c, d]]")
        self.assertEqual(take_list_result.to_full_form(), "List[List[a, b], List[c]]")
        self.assertEqual(take_drop_result.to_full_form(), "List[List[a, b], List[c, d]]")

        self.assert_evaluates_with_message("UnitVector[3]", "UnitVector[3]", "UnitVector::error")

    def test_fold_search_and_duplicate_family(self) -> None:
        fold_result = evaluate(parse_input_form("Fold[f, x, {a, b, c}]"))
        fold_list_result = evaluate(parse_input_form("FoldList[f, x, {a, b, c}]"))
        sequence_fold_result = evaluate(parse_input_form("SequenceFold[f, {x0, x1}, {a, b, c}]"))
        sequence_fold_list_result = evaluate(parse_input_form("SequenceFoldList[f, {x0, x1}, {a, b, c}]"))
        length_while_result = evaluate(parse_input_form("LengthWhile[{2, 4, 6, 7, 8}, EvenQ]"))
        first_case_result = evaluate(parse_input_form("FirstCase[{a, 1, b, 2}, _Integer]"))
        position_result = evaluate(parse_input_form("Position[f[a, g[a]], a, Infinity]"))
        member_q_result = evaluate(parse_input_form("MemberQ[f[a, g[a]], a, Infinity]"))
        delete_duplicates_result = evaluate(parse_input_form("DeleteDuplicates[{a, b, a, c, b}]"))
        delete_duplicates_by_result = evaluate(parse_input_form("DeleteDuplicatesBy[{{a}, {b, c}, {d}, {e, f}}, Length]"))
        duplicate_free_true = evaluate(parse_input_form("DuplicateFreeQ[{a, b, c}]"))
        duplicate_free_false = evaluate(parse_input_form("DuplicateFreeQ[{a, b, a}]"))
        self.assertEqual(fold_result.to_full_form(), "f[f[f[x, a], b], c]")
        self.assertEqual(
            fold_list_result.to_full_form(),
            "List[x, f[x, a], f[f[x, a], b], f[f[f[x, a], b], c]]",
        )
        self.assertEqual(
            sequence_fold_result.to_full_form(),
            "f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]",
        )
        self.assertEqual(
            sequence_fold_list_result.to_full_form(),
            "List[x0, x1, f[x0, x1, a], f[x1, f[x0, x1, a], b], f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]]",
        )
        self.assertEqual(length_while_result.to_full_form(), "3")
        self.assertEqual(first_case_result.to_full_form(), "1")
        self.assertEqual(position_result.to_full_form(), "List[List[1], List[2, 1]]")
        self.assertEqual(member_q_result.to_full_form(), "True")
        self.assertEqual(delete_duplicates_result.to_full_form(), "List[a, b, c]")
        self.assertEqual(delete_duplicates_by_result.to_full_form(), "List[List[a], List[b, c]]")
        self.assertEqual(duplicate_free_true.to_full_form(), "True")
        self.assertEqual(duplicate_free_false.to_full_form(), "False")

    def test_blockmap_distribute_foldwhile_and_foldpair_family(self) -> None:
        block_map_result = evaluate(parse_input_form("BlockMap[f, {a, b, c, d, e}, 2]"))
        block_map_overlap = evaluate(parse_input_form("BlockMap[f, {a, b, c, d, e}, 2, 1]"))
        block_map_head = evaluate(parse_input_form("BlockMap[f, h[a, b, c, d, e], 2]"))
        distribute_default = evaluate(parse_input_form("Distribute[f[a + b, c + d]]"))
        distribute_head = evaluate(parse_input_form("Distribute[f[g[a, b], h[c, d]], g]"))
        fold_while_result = evaluate(parse_input_form("FoldWhile[#1 + #2 &, 0, {1, 2, 3, 4}, # < 4 &]"))
        fold_while_list_result = evaluate(parse_input_form("FoldWhileList[#1 + #2 &, 0, {1, 2, 3, 4}, # < 4 &]"))
        fold_while_history = evaluate(parse_input_form("FoldWhileList[#1 + #2 &, 0, {1, 2, 3, 4}, # < 4 &, 2]"))
        fold_pair_list_result = evaluate(
            parse_input_form("FoldPairList[Function[{y, x}, {y + x, y - x}], y0, {a, b, c}]")
        )
        fold_pair_result = evaluate(
            parse_input_form("FoldPair[Function[{y, x}, {y + x, y - x}], y0, {a, b, c}]")
        )
        fold_pair_last = evaluate(
            parse_input_form("FoldPairList[Function[{y, x}, {y + x, y - x}], y0, {a, b, c}, Last]")
        )
        self.assertEqual(block_map_result.to_full_form(), "List[f[List[a, b]], f[List[c, d]]]")
        self.assertEqual(
            block_map_overlap.to_full_form(),
            "List[f[List[a, b]], f[List[b, c]], f[List[c, d]], f[List[d, e]]]",
        )
        self.assertEqual(block_map_head.to_full_form(), "List[f[h[a, b]], f[h[c, d]]]")
        self.assertEqual(
            distribute_default.to_full_form(),
            "Plus[f[a, c], f[a, d], f[b, c], f[b, d]]",
        )
        self.assertEqual(distribute_head.to_full_form(), "g[f[a, h[c, d]], f[b, h[c, d]]]")
        self.assertEqual(fold_while_result.to_full_form(), "6")
        self.assertEqual(fold_while_list_result.to_full_form(), "List[0, 1, 3, 6]")
        self.assertEqual(fold_while_history.to_full_form(), "List[0, 1, 3, 6, 10]")
        self.assertEqual(
            fold_pair_list_result.to_full_form(),
            "List[Plus[y0, a], Plus[Plus[y0, Times[-1, a]], b], Plus[Plus[Plus[y0, Times[-1, a]], Times[-1, b]], c]]",
        )
        self.assertEqual(
            fold_pair_result.to_full_form(),
            "Plus[Plus[Plus[y0, Times[-1, a]], Times[-1, b]], c]",
        )
        self.assertEqual(
            fold_pair_last.to_full_form(),
            "List[Plus[y0, Times[-1, a]], Plus[Plus[y0, Times[-1, a]], Times[-1, b]], Plus[Plus[Plus[y0, Times[-1, a]], Times[-1, b]], Times[-1, c]]]",
        )

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
        key_select = evaluate(parse_input_form('KeySelect[<|"a" -> 1, bb -> 2|>, StringQ]'))
        key_select_operator = evaluate(parse_input_form('KeySelect[StringQ][<|"a" -> 1, bb -> 2|>]'))
        key_map = evaluate(parse_input_form("KeyMap[f, <|a -> 1, b -> 2|>]"))
        key_value_map = evaluate(parse_input_form("KeyValueMap[f, <|a -> 1, b -> 2|>]"))
        association_thread = evaluate(parse_input_form("AssociationThread[{a, b, c}, {1, 2, 3}]"))
        association_map = evaluate(parse_input_form("AssociationMap[f, {a, b, c}]"))
        self.assertEqual(key_take.to_full_form(), "Association[Rule[c, 3], Rule[a, 1]]")
        self.assertEqual(key_drop.to_full_form(), "Association[Rule[b, 2]]")
        self.assertEqual(key_select.to_full_form(), 'Association[Rule["a", 1]]')
        self.assertEqual(key_select_operator.to_full_form(), 'Association[Rule["a", 1]]')
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
        map_indexed = evaluate(parse_input_form("MapIndexed[f, <|a -> x, b -> y|>]"))
        self.assertEqual(first_result.to_full_form(), "1")
        self.assertEqual(last_result.to_full_form(), "3")
        self.assertEqual(rest_result.to_full_form(), "Association[Rule[b, 2], Rule[c, 3]]")
        self.assertEqual(most_result.to_full_form(), "Association[Rule[a, 1], Rule[b, 2]]")
        self.assertEqual(take_result.to_full_form(), "Association[Rule[a, 1], Rule[b, 2]]")
        self.assertEqual(drop_result.to_full_form(), "Association[Rule[c, 3]]")
        self.assertEqual(append_result.to_full_form(), "Association[Rule[b, 2], Rule[a, 9]]")
        self.assertEqual(prepend_result.to_full_form(), "Association[Rule[a, 9], Rule[b, 2]]")
        self.assertEqual(join_result.to_full_form(), "Association[Rule[a, 9], Rule[b, 2], Rule[c, 3]]")
        self.assertEqual(apply_result.to_full_form(), "g[1, 2]")
        self.assertEqual(map_result.to_full_form(), "Association[Rule[a, g[1]], Rule[b, g[2]]]")
        self.assertEqual(
            map_indexed.to_full_form(),
            "Association[Rule[a, f[x, List[Key[a]]]], Rule[b, f[y, List[Key[b]]]]]",
        )

    def test_select_family_supports_predicates_properties_limits_and_operator_forms(self) -> None:
        select_result = evaluate(parse_input_form("Select[f[1, a, 2, 3], IntegerQ]"))
        select_limited = evaluate(parse_input_form("Select[f[1, a, 2, 3], IntegerQ, 2]"))
        select_zero = evaluate(parse_input_form("Select[f[1, a, 2, 3], IntegerQ, 0]"))
        select_indices = evaluate(parse_input_form('Select[f[1, a, 2, 3], # > 1 & -> "Index"]'))
        select_props = evaluate(parse_input_form('Select[{1, a, 2, 3}, # > 1 & -> {"Element", "Index"}]'))
        select_operator = evaluate(parse_input_form("Select[EvenQ][{1, 2, 3, 4}]"))
        discard_result = evaluate(parse_input_form("Discard[f[1, 2, 3, 4], EvenQ, 1]"))
        discard_indices = evaluate(parse_input_form('Discard[{1, 2, 3, 4}, EvenQ -> "Index"]'))
        select_first = evaluate(parse_input_form("SelectFirst[{1, a, 2, 3}, # > 1 &]"))
        select_first_default = evaluate(parse_input_form("SelectFirst[{1, a}, # > 1 &, q]"))
        select_first_props = evaluate(parse_input_form('SelectFirst[{1, a}, # > 1 & -> {"Element", "Index"}, q]'))
        self.assertEqual(select_result.to_full_form(), "f[1, 2, 3]")
        self.assertEqual(select_limited.to_full_form(), "f[1, 2]")
        self.assertEqual(select_zero.to_full_form(), "f[]")
        self.assertEqual(select_indices.to_full_form(), "List[3, 4]")
        self.assertEqual(
            select_props.to_full_form(),
            'Association[Rule["Element", List[2, 3]], Rule["Index", List[3, 4]]]',
        )
        self.assertEqual(select_operator.to_full_form(), "List[2, 4]")
        self.assertEqual(discard_result.to_full_form(), "f[1, 3, 4]")
        self.assertEqual(discard_indices.to_full_form(), "List[1, 3]")
        self.assertEqual(select_first.to_full_form(), "2")
        self.assertEqual(select_first_default.to_full_form(), "q")
        self.assertEqual(
            select_first_props.to_full_form(),
            'Association[Rule["Element", q], Rule["Index", Missing["NotFound"]]]',
        )

    def test_select_family_operates_on_association_values(self) -> None:
        select_result = evaluate(parse_input_form("Select[<|a -> 1, b -> x, c -> 2|>, IntegerQ]"))
        select_limited = evaluate(parse_input_form("Select[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"))
        discard_result = evaluate(parse_input_form("Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"))
        select_first = evaluate(parse_input_form("SelectFirst[<|a -> 1, b -> x, c -> 2|>, IntegerQ]"))
        select_first_missing = evaluate(parse_input_form("SelectFirst[<|a -> x, b -> y|>, IntegerQ]"))
        select_indices = evaluate(parse_input_form('Select[<|a -> 1, b -> x, c -> 2|>, MatchQ[#, _Integer] & -> "Index"]'))
        discard_indices = evaluate(parse_input_form('Discard[<|a -> 1, b -> x, c -> 2|>, MatchQ[#, _Integer] & -> "Index"]'))
        self.assertEqual(select_result.to_full_form(), "Association[Rule[a, 1], Rule[c, 2]]")
        self.assertEqual(select_limited.to_full_form(), "Association[Rule[a, 1]]")
        self.assertEqual(discard_result.to_full_form(), "Association[Rule[b, x], Rule[c, 2]]")
        self.assertEqual(select_first.to_full_form(), "1")
        self.assertEqual(select_first_missing.to_full_form(), 'Missing["NotFound"]')
        self.assertEqual(select_indices.to_full_form(), "List[1, 3]")
        self.assertEqual(discard_indices.to_full_form(), "List[2]")

    def test_takewhile_preserves_heads_and_association_order(self) -> None:
        take_result = evaluate(parse_input_form("TakeWhile[f[2, 4, 6, 7, 8], EvenQ]"))
        assoc_take = evaluate(parse_input_form("TakeWhile[<|a -> 2, b -> 4, c -> 1, d -> 8|>, EvenQ]"))
        self.assertEqual(take_result.to_full_form(), "f[2, 4, 6]")
        self.assertEqual(assoc_take.to_full_form(), "Association[Rule[a, 2], Rule[b, 4]]")

    def test_if_which_switch_piecewise_and_boole_follow_structural_rules(self) -> None:
        if_true = evaluate(parse_input_form("If[True, 1 + 2, 1/0]"))
        if_unknown = evaluate(parse_input_form("If[x, 1 + 2, 9]"))
        if_unknown_branch = evaluate(parse_input_form("If[x, 1, 2, 3]"))
        which_true = evaluate(parse_input_form("Which[False, a, True, 1 + 2]"))
        which_unknown = evaluate(parse_input_form("Which[False, a, x, 1/0, True, 2 + 2]"))
        switch_pattern = evaluate(parse_input_form("Switch[a, _Integer, 1, _Symbol, 2]"))
        switch_unmatched = evaluate(parse_input_form("Switch[1 + 2, 4, a]"))
        boole_true = evaluate(parse_input_form("Boole[1 < 2]"))
        boole_unknown = evaluate(parse_input_form("Boole[x]"))
        piecewise_true = evaluate(parse_input_form("Piecewise[{{1 + 2, True}, {1/0, True}}]"))
        piecewise_unknown = evaluate(parse_input_form("Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]"))
        self.assertEqual(if_true.to_full_form(), "3")
        self.assertEqual(if_unknown.to_full_form(), "If[x, Plus[1, 2], 9]")
        self.assertEqual(if_unknown_branch.to_full_form(), "3")
        self.assertEqual(which_true.to_full_form(), "3")
        self.assertEqual(which_unknown.to_full_form(), "Which[x, Times[1, Power[0, -1]], True, Plus[2, 2]]")
        self.assertEqual(switch_pattern.to_full_form(), "2")
        self.assertEqual(switch_unmatched.to_full_form(), "Switch[3, 4, a]")
        self.assertEqual(boole_true.to_full_form(), "1")
        self.assertEqual(boole_unknown.to_full_form(), "Boole[x]")
        self.assertEqual(piecewise_true.to_full_form(), "3")
        self.assertEqual(piecewise_unknown.to_full_form(), "Piecewise[List[List[2, x]], 4]")

    def test_integer_predicates_and_integer_only_numeric_functions(self) -> None:
        integer_q = evaluate(parse_input_form("IntegerQ[3]"))
        integer_q_false = evaluate(parse_input_form("IntegerQ[x]"))
        string_q = evaluate(parse_input_form('StringQ["x"]'))
        string_q_false = evaluate(parse_input_form("StringQ[x]"))
        unit_step = evaluate(parse_input_form("UnitStep[2, 0, 5]"))
        unit_step_false = evaluate(parse_input_form("UnitStep[2, -1]"))
        unitize_zero = evaluate(parse_input_form("Unitize[0]"))
        unitize_nonzero = evaluate(parse_input_form("Unitize[-5]"))
        sign_value = evaluate(parse_input_form("Sign[-7]"))
        abs_value = evaluate(parse_input_form("Abs[-7]"))
        real_sign = evaluate(parse_input_form("RealSign[-7]"))
        real_abs = evaluate(parse_input_form("RealAbs[-7]"))
        ramp_value = evaluate(parse_input_form("Ramp[-3]"))
        self.assertEqual(integer_q.to_full_form(), "True")
        self.assertEqual(integer_q_false.to_full_form(), "False")
        self.assertEqual(string_q.to_full_form(), "True")
        self.assertEqual(string_q_false.to_full_form(), "False")
        self.assertEqual(unit_step.to_full_form(), "1")
        self.assertEqual(unit_step_false.to_full_form(), "0")
        self.assertEqual(unitize_zero.to_full_form(), "0")
        self.assertEqual(unitize_nonzero.to_full_form(), "1")
        self.assertEqual(sign_value.to_full_form(), "-1")
        self.assertEqual(abs_value.to_full_form(), "7")
        self.assertEqual(real_sign.to_full_form(), "-1")
        self.assertEqual(real_abs.to_full_form(), "7")
        self.assertEqual(ramp_value.to_full_form(), "0")

    def test_numeric_tower_atoms_and_predicates(self) -> None:
        rational = evaluate(parse_input_form("Rational[2, 4]"))
        rational_integer = evaluate(parse_input_form("Rational[4, 2]"))
        exact_complex = evaluate(parse_input_form("1 + 2 I"))
        exact_zero_imaginary = evaluate(parse_input_form("Complex[1, 0]"))
        machine_zero_imaginary = evaluate(parse_input_form("Complex[1., 0.]"))
        overflow = evaluate(parse_input_form("Overflow[]"))
        underflow = evaluate(parse_input_form("Underflow[]"))

        self.assertEqual(rational.to_full_form(), "Rational[1, 2]")
        self.assertEqual(rational.to_input_form(), "1/2")
        self.assertEqual(rational_integer.to_full_form(), "2")
        self.assertEqual(exact_complex.to_full_form(), "Complex[1, 2]")
        self.assertEqual(exact_zero_imaginary.to_full_form(), "1")
        self.assertEqual(machine_zero_imaginary.to_full_form(), "Complex[1., 0.]")
        self.assertEqual(overflow.to_full_form(), "Overflow[]")
        self.assertEqual(underflow.to_full_form(), "Underflow[]")

        self.assertEqual(evaluate(parse_input_form("Head[Rational[1, 2]]")).to_full_form(), "Rational")
        self.assertEqual(evaluate(parse_input_form("Head[I]")).to_full_form(), "Complex")
        self.assertEqual(evaluate(parse_input_form("Head[Overflow[]]")).to_full_form(), "Real")
        self.assertEqual(evaluate(parse_input_form("AtomQ[Rational[1, 2]]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("AtomQ[1 + 2 I]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("AtomQ[Overflow[]]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("AtomQ[f[1]]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("Length[Rational[1, 2]]")).to_full_form(), "0")

        self.assertEqual(evaluate(parse_input_form("NumberQ[1 + 2 I]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("NumberQ[Infinity]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("NumberQ[Overflow[]]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("ExactNumberQ[1 + 2 I]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("ExactNumberQ[1. + 2 I]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("InexactNumberQ[1. + 2 I]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("RealValuedNumberQ[1/2]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("RealValuedNumberQ[1. + 0. I]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("RealValuedNumberQ[Overflow[]]")).to_full_form(), "True")

    def test_numeric_tower_arithmetic_precision_and_complex_functions(self) -> None:
        rational_sum = evaluate(parse_input_form("1/2 + 1/3"))
        rational_product = evaluate(parse_input_form("(2/3) (9/4)"))
        reciprocal = evaluate(parse_input_form("(1/2)^-2"))
        division_by_zero = evaluate(parse_input_form("1/0"))
        zero_division = evaluate(parse_input_form("0/0"))
        machine_sum = evaluate(parse_input_form("1. + 2"))
        arbitrary_sum = evaluate(parse_input_form("1.25`20 + 2.5`20"))
        machine_approximation = evaluate(parse_input_form("N[1/3]"))
        arbitrary_approximation = evaluate(parse_input_form("N[1/3, 20]"))

        self.assertEqual(rational_sum.to_full_form(), "Rational[5, 6]")
        self.assertEqual(rational_product.to_full_form(), "Rational[3, 2]")
        self.assertEqual(reciprocal.to_full_form(), "4")
        self.assertEqual(division_by_zero.to_full_form(), "ComplexInfinity")
        self.assertEqual(zero_division.to_full_form(), "Indeterminate")
        self.assertEqual(machine_sum.to_full_form(), "3.")
        self.assertEqual(arbitrary_sum.to_full_form(), "3.75`20.")
        self.assertEqual(machine_approximation.to_full_form(), "0.3333333333333333")
        self.assertEqual(arbitrary_approximation.to_full_form(), "0.33333333333333333333`20.")

        self.assertEqual(evaluate(parse_input_form("Precision[1]")).to_full_form(), "Infinity")
        self.assertEqual(evaluate(parse_input_form("Precision[1.]")).to_full_form(), "MachinePrecision")
        self.assertEqual(evaluate(parse_input_form("Precision[1.23`20]")).to_full_form(), "20.")
        self.assertEqual(evaluate(parse_input_form("Accuracy[1]")).to_full_form(), "Infinity")
        self.assertEqual(evaluate(parse_input_form("Accuracy[1000.]")).to_full_form(), "12.954589770191003")
        self.assertEqual(evaluate(parse_input_form("Accuracy[1.23`20]")).to_full_form(), "19.910094888560604")
        self.assertEqual(evaluate(parse_input_form("Precision[Overflow[]]")).to_full_form(), "0.")
        self.assertEqual(evaluate(parse_input_form("Accuracy[Overflow[]]")).to_full_form(), "-Infinity")
        self.assertEqual(evaluate(parse_input_form("Accuracy[Underflow[]]")).to_full_form(), "Infinity")
        self.assertEqual(evaluate(parse_input_form("$MachinePrecision")).to_full_form(), "15.954589770191003")
        self.assertEqual(evaluate(parse_input_form("$MaxMachineNumber")).to_full_form(), "1.7976931348623157*^+308")
        self.assertEqual(evaluate(parse_input_form("$MinMachineNumber")).to_full_form(), "2.2250738585072014*^-308")
        self.assertEqual(evaluate(parse_input_form("$MachineEpsilon")).to_full_form(), "2.220446049250313*^-16")
        self.assertEqual(evaluate(parse_input_form("MachineNumberQ[1.]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("MachineNumberQ[1.`20]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("MachineNumberQ[1. + 2. I]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("MachineIntegerQ[2^63 - 1]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("MachineIntegerQ[2^63]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("SetPrecision[1/3, 20]")).to_full_form(), "0.33333333333333333333`20.")
        self.assertEqual(evaluate(parse_input_form("SetPrecision[1., 20]")).to_full_form(), "1.`20.")
        self.assertEqual(evaluate(parse_input_form("SetPrecision[1., MachinePrecision]")).to_full_form(), "1.")
        self.assertEqual(evaluate(parse_input_form("SetPrecision[1.25, Infinity]")).to_full_form(), "Rational[5, 4]")
        self.assertEqual(evaluate(parse_input_form("SetAccuracy[1.23, 20]")).to_full_form(), "1.23``20.")

        self.assertEqual(evaluate(parse_input_form("Re[1 + 2 I]")).to_full_form(), "1")
        self.assertEqual(evaluate(parse_input_form("Im[1 + 2 I]")).to_full_form(), "2")
        self.assertEqual(evaluate(parse_input_form("Conjugate[1 + 2 I]")).to_full_form(), "Complex[1, -2]")
        self.assertEqual(evaluate(parse_input_form("Abs[3 + 4 I]")).to_full_form(), "5")
        self.assertEqual(evaluate(parse_input_form("Abs[1 + I]")).to_full_form(), "Power[2, Rational[1, 2]]")
        self.assertEqual(evaluate(parse_input_form("ToString[Abs[1 + I]]")).to_full_form(), '"2^(1/2)"')

        self.assertEqual(evaluate(parse_input_form("Max[1/2, .75]")).to_full_form(), ".75")
        self.assertEqual(evaluate(parse_input_form("Min[1/2, .75]")).to_full_form(), "Rational[1, 2]")
        self.assertEqual(evaluate(parse_input_form("1/2 < .75")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("Overflow[] > 10^100")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("1/Overflow[]")).to_full_form(), "Underflow[]")
        self.assertEqual(evaluate(parse_input_form("1/Underflow[]")).to_full_form(), "Overflow[]")

    def test_byte_array_and_string_encoding_family(self) -> None:
        byte_array_result = evaluate(parse_input_form("ByteArray[{65, 66, 67}]"))
        byte_array_from_base64 = evaluate(parse_input_form('ByteArray["QUJD"]'))
        byte_array_q_true = evaluate(parse_input_form('ByteArrayQ[ByteArray["QUJD"]]'))
        byte_array_q_false = evaluate(parse_input_form("ByteArrayQ[{65, 66, 67}]"))
        length_result = evaluate(parse_input_form('Length[ByteArray["QUJD"]]'))
        normal_result = evaluate(parse_input_form('Normal[ByteArray["QUJD"]]'))
        base64_encoded = evaluate(parse_input_form('BaseEncode[ByteArray[{65, 66, 67}], "Base64"]'))
        base16_encoded = evaluate(parse_input_form('BaseEncode[ByteArray[{0, 255}], "Base16"]'))
        base85_encoded = evaluate(parse_input_form('BaseEncode[ByteArray[{0, 0, 0, 0}], "Base85ASCII"]'))
        base64_decoded = evaluate(parse_input_form('Normal[BaseDecode["QUJD", "Base64"]]'))
        base16_decoded = evaluate(parse_input_form('Normal[BaseDecode["00ff", "Base16"]]'))
        base85_decoded = evaluate(parse_input_form('Normal[BaseDecode["z", "Base85ASCII"]]'))
        characters_result = evaluate(parse_input_form('Characters["abc"]'))
        characters_list_result = evaluate(parse_input_form('Characters[{"ab", "c"}]'))
        unicode_codes = evaluate(parse_input_form('ToCharacterCode[FromCharacterCode[{97, 233}]]'))
        utf8_codes = evaluate(parse_input_form('ToCharacterCode[FromCharacterCode[{97, 233}], "UTF-8"]'))
        ascii_codes = evaluate(parse_input_form('ToCharacterCode[FromCharacterCode[{97, 233}], "ASCII"]'))
        from_unicode = evaluate(parse_input_form("FromCharacterCode[{97, 233}]"))
        from_latin1 = evaluate(parse_input_form('ToCharacterCode[FromCharacterCode[{97, 233}, "ISO8859-1"]]'))
        string_to_byte_array = evaluate(parse_input_form('StringToByteArray[FromCharacterCode[{97, 233}], "UTF-8"]'))
        byte_array_to_string = evaluate(parse_input_form('ToCharacterCode[ByteArrayToString[ByteArray[{97, 195, 169}], "UTF-8"]]'))
        invalid_utf8_fallback = evaluate(parse_input_form('ToCharacterCode[ByteArrayToString[ByteArray[{97, 162, 98}], "UTF-8"]]'))
        empty_byte_array_string = evaluate(parse_input_form("ByteArrayToString[{}]"))
        self.assertEqual(byte_array_result.to_full_form(), 'ByteArray["QUJD"]')
        self.assertEqual(byte_array_from_base64.to_full_form(), 'ByteArray["QUJD"]')
        self.assertEqual(byte_array_q_true.to_full_form(), "True")
        self.assertEqual(byte_array_q_false.to_full_form(), "False")
        self.assertEqual(length_result.to_full_form(), "3")
        self.assertEqual(normal_result.to_full_form(), "List[65, 66, 67]")
        self.assertEqual(base64_encoded.to_full_form(), '"QUJD"')
        self.assertEqual(base16_encoded.to_full_form(), '"00FF"')
        self.assertEqual(base85_encoded.to_full_form(), '"z"')
        self.assertEqual(base64_decoded.to_full_form(), "List[65, 66, 67]")
        self.assertEqual(base16_decoded.to_full_form(), "List[0, 255]")
        self.assertEqual(base85_decoded.to_full_form(), "List[0, 0, 0, 0]")
        self.assertEqual(characters_result.to_full_form(), 'List["a", "b", "c"]')
        self.assertEqual(characters_list_result.to_full_form(), 'List[List["a", "b"], List["c"]]')
        self.assertEqual(unicode_codes.to_full_form(), "List[97, 233]")
        self.assertEqual(utf8_codes.to_full_form(), "List[97, 195, 169]")
        self.assertEqual(ascii_codes.to_full_form(), "List[97, None]")
        self.assertEqual(from_unicode.to_full_form(), '"aé"')
        self.assertEqual(from_latin1.to_full_form(), "List[97, 233]")
        self.assertEqual(string_to_byte_array.to_full_form(), 'ByteArray["YcOp"]')
        self.assertEqual(byte_array_to_string.to_full_form(), "List[97, 233]")
        self.assertEqual(invalid_utf8_fallback.to_full_form(), "List[97, 162, 98]")
        self.assertEqual(empty_byte_array_string.to_full_form(), '""')

        self.assert_evaluates_with_message(
            'StringToByteArray[FromCharacterCode[{97, 233}], "ASCII"]',
            'StringToByteArray[FromCharacterCode[List[97, 233]], "ASCII"]',
            "StringToByteArray::error",
        )

    def test_import_export_string_and_byte_array_formats(self) -> None:
        import_text = evaluate(parse_input_form('ImportString["abc", "Text"]'))
        import_byte = evaluate(parse_input_form('ImportString["abc", "Byte"]'))
        import_json = evaluate(parse_input_form('ImportString["{\\"a\\":1,\\"b\\":[2,3]}", "JSON"]'))
        import_raw_json = evaluate(parse_input_form('ImportString["{\\"a\\":1,\\"b\\":[2,3]}", "RawJSON"]'))
        import_csv = evaluate(parse_input_form('ImportString["1,2\\n3,4\\n", "CSV"]'))
        import_tsv = evaluate(parse_input_form('ImportString["1\\t2\\n3\\t4\\n", "TSV"]'))
        import_table = evaluate(parse_input_form('ImportString["1 2\\n3 4\\n", "Table"]'))
        import_wl = evaluate(parse_input_form('ImportString["f[a, 1]", "WL"]'))

        export_byte = evaluate(parse_input_form('ExportString[{97, 98, 99}, "Byte"]'))
        export_wl = evaluate(parse_input_form('ExportString[f[a, 1], "WL"]'))
        json_roundtrip = evaluate(parse_input_form('ImportString[ExportString[{"a" -> 1, "b" -> {2, 3}}, "JSON"], "JSON"]'))
        json_from_association = evaluate(parse_input_form('ImportString[ExportString[<|"a" -> 1|>, "JSON"], "JSON"]'))
        raw_json_roundtrip = evaluate(parse_input_form('ImportString[ExportString[<|"a" -> 1, "b" -> {2, 3}|>, "RawJSON"], "RawJSON"]'))
        csv_roundtrip = evaluate(parse_input_form('ImportString[ExportString[{{1, 2}, {3, 4}}, "CSV"], "CSV"]'))
        tsv_roundtrip = evaluate(parse_input_form('ImportString[ExportString[{1, 2, 3}, "TSV"], "TSV"]'))
        table_roundtrip = evaluate(parse_input_form('ImportString[ExportString[{{1, 2}, {3, 4}}, "Table"], "Table"]'))

        import_byte_array_byte = evaluate(parse_input_form('ImportByteArray[ByteArray[{97, 98, 99}], "Byte"]'))
        import_byte_array_string = evaluate(parse_input_form('ImportByteArray[ByteArray[{97, 98, 99}], "String"]'))
        export_byte_array_byte = evaluate(parse_input_form('Normal[ExportByteArray[{97, 98, 99}, "Byte"]]'))
        export_byte_array_string = evaluate(parse_input_form('Normal[ExportByteArray["abc", "String"]]'))
        gzip_string_roundtrip = evaluate(parse_input_form('ImportString[ExportString["hello", {"GZIP", "String"}], {"GZIP", "String"}]'))
        gzip_csv_roundtrip = evaluate(parse_input_form('ImportByteArray[ExportByteArray[{{1, 2}, {3, 4}}, {"GZIP", "CSV"}], {"GZIP", "CSV"}]'))
        bzip_raw_json_roundtrip = evaluate(parse_input_form('ImportByteArray[ExportByteArray[<|"a" -> 1|>, {"BZIP2", "RawJSON"}], {"BZIP2", "RawJSON"}]'))

        self.assertEqual(import_text.to_full_form(), '"abc"')
        self.assertEqual(import_byte.to_full_form(), "List[97, 98, 99]")
        self.assertEqual(import_json.to_full_form(), 'List[Rule["a", 1], Rule["b", List[2, 3]]]')
        self.assertEqual(import_raw_json.to_full_form(), 'Association[Rule["a", 1], Rule["b", List[2, 3]]]')
        self.assertEqual(import_csv.to_full_form(), "List[List[1, 2], List[3, 4]]")
        self.assertEqual(import_tsv.to_full_form(), "List[List[1, 2], List[3, 4]]")
        self.assertEqual(import_table.to_full_form(), "List[List[1, 2], List[3, 4]]")
        self.assertEqual(import_wl.to_full_form(), "f[a, 1]")
        self.assertEqual(export_byte.to_full_form(), '"abc"')
        self.assertEqual(export_wl.to_full_form(), '"f[a, 1]"')
        self.assertEqual(json_roundtrip.to_full_form(), 'List[Rule["a", 1], Rule["b", List[2, 3]]]')
        self.assertEqual(json_from_association.to_full_form(), 'List[Rule["a", 1]]')
        self.assertEqual(raw_json_roundtrip.to_full_form(), 'Association[Rule["a", 1], Rule["b", List[2, 3]]]')
        self.assertEqual(csv_roundtrip.to_full_form(), "List[List[1, 2], List[3, 4]]")
        self.assertEqual(tsv_roundtrip.to_full_form(), "List[List[1], List[2], List[3]]")
        self.assertEqual(table_roundtrip.to_full_form(), "List[List[1, 2], List[3, 4]]")
        self.assertEqual(import_byte_array_byte.to_full_form(), "List[97, 98, 99]")
        self.assertEqual(import_byte_array_string.to_full_form(), '"abc"')
        self.assertEqual(export_byte_array_byte.to_full_form(), "List[97, 98, 99]")
        self.assertEqual(export_byte_array_string.to_full_form(), "List[97, 98, 99]")
        self.assertEqual(gzip_string_roundtrip.to_full_form(), '"hello"')
        self.assertEqual(gzip_csv_roundtrip.to_full_form(), "List[List[1, 2], List[3, 4]]")
        self.assertEqual(bzip_raw_json_roundtrip.to_full_form(), 'Association[Rule["a", 1]]')

        self.assert_evaluates_with_message(
            'ExportString[{"a" -> 1}, "RawJSON"]',
            'ExportString[List[Rule["a", 1]], "RawJSON"]',
            "ExportString::error",
        )

    def test_to_string_and_to_expression_round_trip_input_and_standard_forms(self) -> None:
        input_string = evaluate(parse_input_form("ToString[HoldComplete[1 + 2], InputForm]"))
        standard_string = evaluate(parse_input_form("ToString[HoldComplete[f @ x // g], StandardForm]"))
        default_string = evaluate(parse_input_form("ToString[HoldComplete[{a -> b, f[x]}]]"))
        input_form_wrapper = evaluate(parse_input_form("ToString[InputForm[{1, 2/3, a + b}]]"))
        full_form_wrapper = evaluate(parse_input_form("ToString[FullForm[{1, 2/3, a + b}]]"))
        literal_input_form_wrapper = evaluate(parse_input_form("ToString[InputForm[1 + x], InputForm]"))
        literal_full_form_wrapper = evaluate(parse_input_form("ToString[FullForm[1 + x], InputForm]"))
        input_round_trip = evaluate(
            parse_input_form(
                "SameQ[ToExpression[ToString[HoldComplete[1 + 2], InputForm], InputForm], HoldComplete[1 + 2]]"
            )
        )
        standard_round_trip = evaluate(
            parse_input_form(
                "SameQ[ToExpression[ToString[HoldComplete[f @ x // g], StandardForm], StandardForm], HoldComplete[g[f[x]]]]"
            )
        )
        byte_array_round_trip = evaluate(
            parse_input_form(
                "SameQ[ToExpression[ToString[ByteArray[{1, 2, 255}], InputForm], InputForm], ByteArray[{1, 2, 255}]]"
            )
        )
        self.assertEqual(input_string.to_full_form(), '"HoldComplete[1 + 2]"')
        self.assertEqual(standard_string.to_full_form(), '"HoldComplete[g[f[x]]]"')
        self.assertEqual(default_string.to_full_form(), '"HoldComplete[{a -> b, f[x]}]"')
        self.assertEqual(input_form_wrapper.to_full_form(), '"{1, 2/3, a + b}"')
        self.assertEqual(full_form_wrapper.to_full_form(), '"List[1, Rational[2, 3], Plus[a, b]]"')
        self.assertEqual(literal_input_form_wrapper.to_full_form(), '"InputForm[1 + x]"')
        self.assertEqual(literal_full_form_wrapper.to_full_form(), '"FullForm[1 + x]"')
        self.assertEqual(input_round_trip.to_full_form(), "True")
        self.assertEqual(standard_round_trip.to_full_form(), "True")
        self.assertEqual(byte_array_round_trip.to_full_form(), "True")

    def test_to_expression_evaluates_after_optional_wrapper(self) -> None:
        default_input = evaluate(parse_input_form('ToExpression["1 + 2"]'))
        held_input = evaluate(parse_input_form('ToExpression["1 + 2", InputForm, HoldComplete]'))
        held_standard = evaluate(parse_input_form('ToExpression["f @ x // g", StandardForm, HoldComplete]'))
        identity_wrapped = evaluate(parse_input_form('ToExpression["1 + 2", InputForm, Identity]'))
        list_wrapped = evaluate(parse_input_form('ToExpression["f[a]", InputForm, List]'))
        box_default = evaluate(parse_input_form('ToExpression[RowBox[{"1", "+", "2"}], StandardForm, HoldComplete]'))
        box_implicit_standard = evaluate(parse_input_form('ToExpression[RowBox[{"1", "+", "2"}]]'))
        listable = evaluate(parse_input_form('ToExpression[{"1 + 2", "f @ x // g"}, StandardForm, HoldComplete]'))
        self.assertEqual(default_input.to_full_form(), "3")
        self.assertEqual(held_input.to_full_form(), "HoldComplete[Plus[1, 2]]")
        self.assertEqual(held_standard.to_full_form(), "HoldComplete[g[f[x]]]")
        self.assertEqual(identity_wrapped.to_full_form(), "3")
        self.assertEqual(list_wrapped.to_full_form(), "List[f[a]]")
        self.assertEqual(box_default.to_full_form(), "HoldComplete[Plus[1, 2]]")
        self.assertEqual(box_implicit_standard.to_full_form(), "3")
        self.assertEqual(listable.to_full_form(), "List[HoldComplete[Plus[1, 2]], HoldComplete[g[f[x]]]]")

        self.assert_evaluates_with_message("ToString[x, OutputForm]", "ToString[x, OutputForm]", "ToString::error")
        self.assert_evaluates_with_message(
            'ToExpression["x", TraditionalForm]',
            'ToExpression["x", TraditionalForm]',
            "ToExpression::error",
        )

    def test_box_conversion_and_syntax_builtins(self) -> None:
        make_expression = evaluate(parse_input_form('MakeExpression[RowBox[{"1", "+", "2"}], StandardForm]'))
        make_boxes = evaluate(parse_input_form("MakeBoxes[1 + 2, StandardForm]"))
        to_boxes = evaluate(parse_input_form("ToBoxes[1 + 2, StandardForm]"))
        input_form_boxes = evaluate(parse_input_form("ToBoxes[InputForm[1 + x]]"))
        full_form_boxes = evaluate(parse_input_form("ToBoxes[FullForm[1 + x]]"))
        output_form_boxes = evaluate(parse_input_form("ToBoxes[OutputForm[1 + x]]"))
        standard_form_boxes = evaluate(parse_input_form("ToBoxes[StandardForm[1 + x]]"))
        box_to_expression = evaluate(
            parse_input_form("ToExpression[MakeBoxes[HoldComplete[1 + 2], StandardForm], StandardForm]")
        )
        strip_boxes = evaluate(parse_input_form('StripBoxes[RowBox[{"1", " ", StyleBox["+", Red], "2"}]]'))
        syntax_true = evaluate(parse_input_form('SyntaxQ["1 + 2"]'))
        syntax_false = evaluate(parse_input_form('SyntaxQ["1 +"]'))
        syntax_box = evaluate(parse_input_form('SyntaxQ[RowBox[{"1", "+", "2"}]]'))
        syntax_length = evaluate(parse_input_form('SyntaxLength["1+2"]'))
        incomplete_length = evaluate(parse_input_form('SyntaxLength["1+"]'))

        self.assertEqual(make_expression.to_full_form(), "HoldComplete[Plus[1, 2]]")
        self.assertEqual(make_boxes.to_full_form(), 'RowBox[List["1", "+", "2"]]')
        self.assertEqual(to_boxes.to_full_form(), '"3"')
        self.assertEqual(
            input_form_boxes.to_full_form(),
            'InterpretationBox[StyleBox["1 + x", Rule[ShowStringCharacters, True], Rule[NumberMarks, True]], InputForm[Plus[1, x]], Rule[Editable, True], Rule[AutoDelete, True]]',
        )
        self.assertEqual(
            full_form_boxes.to_full_form(),
            'TagBox[StyleBox[RowBox[List["Plus", "[", RowBox[List["1", ",", "x"]], "]"]], Rule[ShowSpecialCharacters, False], Rule[ShowStringCharacters, True], Rule[NumberMarks, True]], FullForm]',
        )
        self.assertEqual(
            output_form_boxes.to_full_form(),
            'InterpretationBox[PaneBox["1 + x", Rule[BaselinePosition, Baseline]], Plus[1, x], Rule[Editable, False]]',
        )
        self.assertEqual(
            standard_form_boxes.to_full_form(),
            'TagBox[FormBox[RowBox[List["1", "+", "x"]], StandardForm], StandardForm, Rule[Editable, True]]',
        )
        self.assertEqual(box_to_expression.to_full_form(), "HoldComplete[Plus[1, 2]]")
        self.assertEqual(strip_boxes.to_full_form(), 'BoxData[RowBox[List["1", "+", "2"]]]')
        self.assertEqual(syntax_true.to_full_form(), "True")
        self.assertEqual(syntax_false.to_full_form(), "False")
        self.assertEqual(syntax_box.to_full_form(), "True")
        self.assertEqual(syntax_length.to_full_form(), "3")
        self.assertEqual(incomplete_length.to_full_form(), "4")

    def test_symbol_context_registry_and_name_queries(self) -> None:
        current_context = evaluate(parse_input_form("$Context"))
        context_path = evaluate(parse_input_form("$ContextPath"))
        qualified_context_path = evaluate(parse_input_form("System`$ContextPath"))
        context_function = evaluate(parse_input_form("Context[]"))
        system_context = evaluate(parse_input_form("Context[Plus]"))
        qualified_system_context = evaluate(parse_input_form("Context[System`Plus]"))
        symbol_name = evaluate(parse_input_form('SymbolName[Symbol["TungstenRegistryTest`alpha"]]'))
        symbol_context = evaluate(parse_input_form('Context[Symbol["TungstenRegistryTest`alpha"]]'))
        another_symbol = evaluate(parse_input_form('Symbol["TungstenRegistryTest`beta"]'))
        global_symbol = evaluate(parse_input_form('Symbol["Global`tungstenGlobalSymbol"]'))
        qualified_constructor = evaluate(parse_input_form('System`Symbol["Global`tungstenQualifiedSymbol"]'))
        system_symbol = evaluate(parse_input_form('Symbol["System`Plus"]'))
        contexts = evaluate(parse_input_form('Contexts["TungstenRegistryTest`*"]'))
        names = evaluate(parse_input_form('Names["TungstenRegistryTest`*"]'))
        visible_name = evaluate(parse_input_form('Names["System`Plus"]'))
        name_q_true = evaluate(parse_input_form('NameQ["TungstenRegistryTest`alpha"]'))
        name_q_wildcard = evaluate(parse_input_form('NameQ["TungstenRegistryTest`*"]'))
        name_q_false = evaluate(parse_input_form('NameQ["TungstenRegistryMissing`*"]'))
        visible_builtin = evaluate(parse_input_form('NameQ["Plus"]'))
        system_symbol_count = evaluate(parse_input_form('Length[Names["System`*"]]'))
        unimplemented_system_symbol = evaluate(parse_input_form('NameQ["System`AASTriangle"]'))
        plus_attributes = evaluate(parse_input_form("Attributes[Plus]"))
        string_attributes = evaluate(parse_input_form('Attributes["System`Plus"]'))
        attributes_attributes = evaluate(parse_input_form("Attributes[Attributes]"))
        listable_attributes = evaluate(parse_input_form("Attributes[{Plus, Times}]"))
        user_symbol_attributes = evaluate(parse_input_form("Attributes[tungstenNoAttributesSymbol]"))
        self.assertEqual(current_context.to_full_form(), '"Global`"')
        self.assertEqual(context_path.to_full_form(), 'List["System`", "Global`"]')
        self.assertEqual(qualified_context_path.to_full_form(), 'List["System`", "Global`"]')
        self.assertEqual(context_function.to_full_form(), '"Global`"')
        self.assertEqual(system_context.to_full_form(), '"System`"')
        self.assertEqual(qualified_system_context.to_full_form(), '"System`"')
        self.assertEqual(symbol_name.to_full_form(), '"alpha"')
        self.assertEqual(symbol_context.to_full_form(), '"TungstenRegistryTest`"')
        self.assertEqual(another_symbol.to_full_form(), "TungstenRegistryTest`beta")
        self.assertEqual(global_symbol.to_full_form(), "tungstenGlobalSymbol")
        self.assertEqual(qualified_constructor.to_full_form(), "tungstenQualifiedSymbol")
        self.assertEqual(system_symbol.to_full_form(), "Plus")
        self.assertEqual(contexts.to_full_form(), 'List["TungstenRegistryTest`"]')
        self.assertEqual(
            names.to_full_form(),
            'List["TungstenRegistryTest`alpha", "TungstenRegistryTest`beta"]',
        )
        self.assertEqual(visible_name.to_full_form(), 'List["Plus"]')
        self.assertEqual(name_q_true.to_full_form(), "True")
        self.assertEqual(name_q_wildcard.to_full_form(), "True")
        self.assertEqual(name_q_false.to_full_form(), "False")
        self.assertEqual(visible_builtin.to_full_form(), "True")
        self.assertEqual(system_symbol_count.to_full_form(), "7803")
        self.assertEqual(unimplemented_system_symbol.to_full_form(), "True")
        self.assertEqual(
            plus_attributes.to_full_form(),
            "List[Flat, Listable, NumericFunction, OneIdentity, Orderless, Protected]",
        )
        self.assertEqual(string_attributes.to_full_form(), plus_attributes.to_full_form())
        self.assertEqual(attributes_attributes.to_full_form(), "List[HoldAll, Listable, Protected]")
        self.assertEqual(
            listable_attributes.to_full_form(),
            "List[List[Flat, Listable, NumericFunction, OneIdentity, Orderless, Protected], "
            "List[Flat, Listable, NumericFunction, OneIdentity, Orderless, Protected]]",
        )
        self.assertEqual(user_symbol_attributes.to_full_form(), "List[]")

        self.assert_evaluates_with_message('Symbol["not a symbol"]', 'Symbol["not a symbol"]', "Symbol::error")
        self.assert_evaluates_with_message("Attributes[1 + 1]", "Attributes[Plus[1, 1]]", "Attributes::error")

    def test_unique_and_valueq_use_symbol_registry(self) -> None:
        unique_default = evaluate(parse_input_form("Unique[]"))
        unique_symbol = evaluate(parse_input_form("Unique[tungstenUniqueSymbol]"))
        unique_string_name = evaluate(parse_input_form('SymbolName[Unique["tungstenUniqueString"]]'))
        unique_list = evaluate(parse_input_form('Unique[{tungstenUniqueList, "tungstenUniqueListString"}]'))
        distinct = evaluate(parse_input_form('UnsameQ[Unique["tungstenDistinct"], Unique["tungstenDistinct"]]'))
        value_user_symbol = evaluate(parse_input_form("ValueQ[tungstenValueQSymbol]"))
        value_context = evaluate(parse_input_form("ValueQ[$Context]"))
        value_qualified_context = evaluate(parse_input_form("ValueQ[System`$Context]"))
        value_literal = evaluate(parse_input_form("ValueQ[1]"))
        value_string = evaluate(parse_input_form('ValueQ["abc"]'))
        value_evaluatable = evaluate(parse_input_form("ValueQ[1 + 2]"))
        value_inert_call = evaluate(parse_input_form("ValueQ[tungstenValueQHead[tungstenValueQSymbol]]"))
        self.assertRegex(unique_default.to_input_form(), r"^\$\d+$")
        self.assertRegex(unique_symbol.to_input_form(), r"^tungstenUniqueSymbol\$\d+$")
        self.assertRegex(unique_string_name.to_full_form(), r'^"tungstenUniqueString\d+"$')
        self.assertRegex(
            unique_list.to_full_form(),
            r"^List\[tungstenUniqueList\$\d+, tungstenUniqueListString\d+\]$",
        )
        self.assertEqual(distinct.to_full_form(), "True")
        self.assertEqual(value_user_symbol.to_full_form(), "False")
        self.assertEqual(value_context.to_full_form(), "True")
        self.assertEqual(value_qualified_context.to_full_form(), "True")
        self.assertEqual(value_literal.to_full_form(), "False")
        self.assertEqual(value_string.to_full_form(), "False")
        self.assertEqual(value_evaluatable.to_full_form(), "True")
        self.assertEqual(value_inert_call.to_full_form(), "False")

    def test_set_unset_clear_valueq_and_ownvalues_for_bare_symbols(self) -> None:
        def submit(code: str) -> str:
            return evaluate(parse_input_form(code)).to_full_form()

        self.assertEqual(submit("Clear[tungstenSetA, tungstenSetB, tungstenSetC]"), "Null")
        self.assertEqual(submit("OwnValues[tungstenSetA]"), "List[]")
        self.assertEqual(submit("ValueQ[tungstenSetA]"), "False")

        self.assertEqual(submit("tungstenSetA = 1 + 2"), "3")
        self.assertEqual(submit("tungstenSetA"), "3")
        self.assertEqual(submit("tungstenSetA = tungstenSetA + 4"), "7")
        self.assertEqual(submit("tungstenSetA"), "7")
        self.assertEqual(submit("ValueQ[tungstenSetA]"), "True")
        self.assertEqual(
            submit("OwnValues[tungstenSetA]"),
            "List[RuleDelayed[HoldPattern[tungstenSetA], 7]]",
        )
        self.assertEqual(
            submit('OwnValues["tungstenSetA"]'),
            "List[RuleDelayed[HoldPattern[tungstenSetA], 7]]",
        )

        self.assertEqual(submit("tungstenSetB = tungstenSetC"), "tungstenSetC")
        self.assertEqual(submit("OwnValues[tungstenSetB]"), "List[RuleDelayed[HoldPattern[tungstenSetB], tungstenSetC]]")
        self.assertEqual(submit("tungstenSetC = 9"), "9")
        self.assertEqual(submit("tungstenSetB"), "9")

        self.assertEqual(submit("tungstenSetA = ."), "Null")
        self.assertEqual(submit("ValueQ[tungstenSetA]"), "False")
        self.assertEqual(submit("OwnValues[tungstenSetA]"), "List[]")
        self.assertEqual(submit("Clear[{tungstenSetB, tungstenSetC}]"), "Null")
        self.assertEqual(submit("ValueQ[tungstenSetB]"), "False")
        self.assertEqual(submit("ValueQ[tungstenSetC]"), "False")

        self.assertEqual(submit("tungstenSetSelf = tungstenSetSelf"), "tungstenSetSelf")
        self.assertEqual(submit("tungstenSetSelf"), "tungstenSetSelf")
        self.assertEqual(submit("ValueQ[tungstenSetSelf]"), "True")
        self.assertEqual(submit("Clear[tungstenSetSelf]"), "Null")

    def test_set_unset_and_clear_reject_protected_symbols(self) -> None:
        self.assert_evaluates_with_message("Plus = 5", "Set[Plus, 5]", "Set::wrsym")
        self.assert_evaluates_with_message("Plus = .", "$Failed", "Unset::wrsym")
        self.assert_evaluates_with_message("Clear[Plus]", "Null", "Clear::wrsym")
        self.assertEqual(evaluate(parse_input_form("1 + 2")).to_full_form(), "3")

    def test_repl_history_symbols_and_downvalues_use_session_state(self) -> None:
        session = EvaluationSession()

        def submit(code: str) -> str:
            parsed = parse_input_form(code)
            session.begin_input(code, parsed)
            result = evaluate(parsed, session=session)
            session.finish_output(result)
            return result.to_full_form()

        self.assertEqual(submit("1 + 2"), "3")
        self.assertEqual(submit("$Line"), "2")
        self.assertEqual(submit("In[1]"), "3")
        self.assertEqual(submit("InString[1]"), '"1 + 2"')
        self.assertEqual(submit("Out[1]"), "3")
        self.assertEqual(submit("In[]"), "3")
        self.assertEqual(submit("InString[]"), '"In[]"')
        self.assertEqual(submit("Out[]"), '"In[]"')
        self.assertEqual(submit("%1 + 10"), "13")

        in_downvalues = submit("DownValues[In]")
        in_string_downvalues = submit("DownValues[InString]")
        out_downvalues = submit("DownValues[Out]")

        self.assertIn("RuleDelayed[HoldPattern[In[1]], Plus[1, 2]]", in_downvalues)
        self.assertIn('RuleDelayed[HoldPattern[InString[1]], "1 + 2"]', in_string_downvalues)
        self.assertIn("RuleDelayed[HoldPattern[Out[1]], 3]", out_downvalues)

    def test_repl_in_history_self_reference_stays_inert(self) -> None:
        session = EvaluationSession()
        parsed = parse_input_form("In[1]")
        session.begin_input("In[1]", parsed)
        result = evaluate(parsed, session=session)
        session.finish_output(result)
        self.assertEqual(result.to_full_form(), "In[1]")

    def test_repl_downvalues_can_be_used_as_replacement_rules_under_hold(self) -> None:
        session = EvaluationSession()

        def submit(code: str) -> str:
            parsed = parse_input_form(code)
            session.begin_input(code, parsed)
            result = evaluate(parsed, session=session)
            session.finish_output(result)
            return result.to_full_form()

        self.assertEqual(submit("Range[10]"), "List[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]")
        self.assertEqual(submit("Range[10] /. 5 -> 55"), "List[1, 2, 3, 4, 55, 6, 7, 8, 9, 10]")
        self.assertEqual(
            submit("Hold[In[2]] /. DownValues[In]"),
            "Hold[ReplaceAll[Range[10], Rule[5, 55]]]",
        )
        self.assertEqual(submit("Hold[x] /. x :> 1 + 2"), "Hold[Plus[1, 2]]")

    def test_repl_exit_and_quit_raise_session_exit(self) -> None:
        session = EvaluationSession()
        session.begin_input("Quit", parse_input_form("Quit"))
        with self.assertRaises(TungstenExitRequested) as quit_context:
            evaluate(parse_input_form("Quit"), session=session)
        self.assertEqual(quit_context.exception.code, 0)

        session.begin_input("Exit[5]", parse_input_form("Exit[5]"))
        with self.assertRaises(TungstenExitRequested) as exit_context:
            evaluate(parse_input_form("Exit[5]"), session=session)
        self.assertEqual(exit_context.exception.code, 5)

    def test_ordering_and_sorting_functions_follow_structural_order(self) -> None:
        self.assertEqual(evaluate(parse_input_form("Order[1, 2]")).to_full_form(), "1")
        self.assertEqual(evaluate(parse_input_form("Order[2, 1]")).to_full_form(), "-1")
        self.assertEqual(evaluate(parse_input_form("Order[a, a]")).to_full_form(), "0")
        self.assertEqual(evaluate(parse_input_form("Order[1, 1.]")).to_full_form(), "1")
        self.assertEqual(evaluate(parse_input_form("OrderedQ[{1, 2, 2}]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("OrderedQ[{2, 1}]")).to_full_form(), "False")
        self.assertEqual(evaluate(parse_input_form("OrderedQ[{3, 2, 1}, Greater]")).to_full_form(), "True")
        self.assertEqual(evaluate(parse_input_form("Ordering[{3, 1, 2}]")).to_full_form(), "List[2, 3, 1]")
        self.assertEqual(evaluate(parse_input_form("Ordering[{3, 1, 2}, 2]")).to_full_form(), "List[2, 3]")
        self.assertEqual(evaluate(parse_input_form("Ordering[{3, 1, 2}, -2]")).to_full_form(), "List[3, 1]")
        self.assertEqual(evaluate(parse_input_form("Ordering[{3, 1, 2}, All, Greater]")).to_full_form(), "List[1, 3, 2]")
        self.assertEqual(evaluate(parse_input_form("Sort[f[3, 1, 2]]")).to_full_form(), "f[1, 2, 3]")
        self.assertEqual(evaluate(parse_input_form("Sort[{3, 1, 2}, Greater]")).to_full_form(), "List[3, 2, 1]")
        self.assertEqual(evaluate(parse_input_form("ReverseSort[{3, 1, 2}]")).to_full_form(), "List[3, 2, 1]")
        self.assertEqual(evaluate(parse_input_form("ReverseSort[{3, 1, 2}, Greater]")).to_full_form(), "List[1, 2, 3]")
        self.assertEqual(evaluate(parse_input_form("Sort[<|b -> 2, a -> 1|>]")).to_full_form(), "Association[Rule[a, 1], Rule[b, 2]]")

    def test_by_key_ordering_and_extrema_functions(self) -> None:
        self.assertEqual(
            evaluate(parse_input_form("SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last]")).to_full_form(),
            "List[List[b, 1], List[a, 2], List[c, 2]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("SortBy[{{c, 2}, {a, 2}, {b, 1}}, {Last}]")).to_full_form(),
            "List[List[b, 1], List[c, 2], List[a, 2]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("SortBy[Last][{{a, 2}, {b, 1}}]")).to_full_form(),
            "List[List[b, 1], List[a, 2]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("ReverseSortBy[{{c, 2}, {a, 2}, {b, 1}}, Last]")).to_full_form(),
            "List[List[c, 2], List[a, 2], List[b, 1]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("ReverseSortBy[{{c, 2}, {a, 2}, {b, 1}}, {Last}]")).to_full_form(),
            "List[List[c, 2], List[a, 2], List[b, 1]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("OrderingBy[{{a, 2}, {b, 1}, {c, 3}}, Last, -2]")).to_full_form(),
            "List[1, 3]",
        )
        self.assertEqual(
            evaluate(parse_input_form("OrderingBy[Last][{{a, 2}, {b, 1}}]")).to_full_form(),
            "List[2, 1]",
        )
        self.assertEqual(
            evaluate(parse_input_form("MinimalBy[{{a, 1}, {b, 2}, {c, 1}}, Last]")).to_full_form(),
            "List[List[a, 1], List[c, 1]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("MaximalBy[{{a, 1}, {b, 2}, {c, 2}}, Last, 2]")).to_full_form(),
            "List[List[b, 2], List[c, 2]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("MinimalBy[<|a -> 2, b -> 1, c -> 1|>, Identity]")).to_full_form(),
            "Association[Rule[b, 1], Rule[c, 1]]",
        )
        self.assertEqual(
            evaluate(parse_input_form("ReverseSortBy[<|a -> 2, b -> 1, c -> 3|>, Identity]")).to_full_form(),
            "Association[Rule[c, 3], Rule[a, 2], Rule[b, 1]]",
        )

    def test_lexicographic_ordering_functions(self) -> None:
        self.assertEqual(evaluate(parse_input_form("LexicographicOrder[{1, 2}, {1, 3}]")).to_full_form(), "1")
        self.assertEqual(evaluate(parse_input_form("LexicographicOrder[{1, 2}, {1, 2}]")).to_full_form(), "0")
        self.assertEqual(evaluate(parse_input_form("LexicographicOrder[{1, 3}, {1, 2}]")).to_full_form(), "-1")
        self.assertEqual(evaluate(parse_input_form('LexicographicOrder["a", "aa"]')).to_full_form(), "1")
        self.assertEqual(
            evaluate(parse_input_form("LexicographicSort[{{1, 3}, {1, 2}, {0, 9}}]")).to_full_form(),
            "List[List[0, 9], List[1, 2], List[1, 3]]",
        )
        self.assertEqual(
            evaluate(parse_input_form('LexicographicSort[{"ba", "aa", "ab"}]')).to_full_form(),
            'List["aa", "ab", "ba"]',
        )
        self.assertEqual(
            evaluate(parse_input_form("Sort[{{1, 3}, {1, 2}}, LexicographicOrder[Order]]")).to_full_form(),
            "List[List[1, 2], List[1, 3]]",
        )

    def test_string_structural_operations_follow_list_like_semantics(self) -> None:
        string_length = evaluate(parse_input_form('StringLength[{"ab", "c"}]'))
        string_take = evaluate(parse_input_form('StringTake["abcdef", {2, 5, 2}]'))
        string_take_upto = evaluate(parse_input_form('StringTake["abc", UpTo[5]]'))
        string_take_list = evaluate(parse_input_form('StringTake[{"abc", "def"}, 2]'))
        string_drop = evaluate(parse_input_form('StringDrop["abcdef", {2, 5, 2}]'))
        string_drop_upto = evaluate(parse_input_form('StringDrop["abc", UpTo[5]]'))
        string_join = evaluate(parse_input_form('StringJoin[{"a", {"b", "c"}}]'))
        infix_join = evaluate(parse_input_form('"a" <> "b" <> "c"'))
        string_insert = evaluate(parse_input_form('StringInsert["abcd", "X", {2, 4}]'))
        string_reverse = evaluate(parse_input_form('StringReverse[{"ab", "cd"}]'))
        string_position = evaluate(parse_input_form('StringPosition["ababa", {"ba", "aba"}]'))
        string_position_list = evaluate(parse_input_form('StringPosition[{"ab", "ba"}, "a"]'))
        string_position_operator = evaluate(parse_input_form('StringPosition["aba"]["ababa"]'))
        string_position_empty = evaluate(parse_input_form('StringPosition["abc", ""]'))
        string_contains = evaluate(parse_input_form('StringContainsQ[{"ab", "cd"}, "a"]'))
        string_contains_empty = evaluate(parse_input_form('StringContainsQ["abc", ""]'))
        string_contains_operator = evaluate(parse_input_form('Select[{"ab", "cd", "ba"}, StringContainsQ["a"]]'))
        self.assertEqual(string_length.to_full_form(), "List[2, 1]")
        self.assertEqual(string_take.to_full_form(), '"bd"')
        self.assertEqual(string_take_upto.to_full_form(), '"abc"')
        self.assertEqual(string_take_list.to_full_form(), 'List["ab", "de"]')
        self.assertEqual(string_drop.to_full_form(), '"acef"')
        self.assertEqual(string_drop_upto.to_full_form(), '""')
        self.assertEqual(string_join.to_full_form(), '"abc"')
        self.assertEqual(infix_join.to_full_form(), '"abc"')
        self.assertEqual(string_insert.to_full_form(), '"aXbcXd"')
        self.assertEqual(string_reverse.to_full_form(), 'List["ba", "dc"]')
        self.assertEqual(string_position.to_full_form(), "List[List[1, 3], List[2, 3], List[3, 5], List[4, 5]]")
        self.assertEqual(string_position_list.to_full_form(), "List[List[List[1, 1]], List[List[2, 2]]]")
        self.assertEqual(string_position_operator.to_full_form(), "List[List[1, 3], List[3, 5]]")
        self.assertEqual(string_position_empty.to_full_form(), "List[List[1, 0], List[2, 1], List[3, 2], List[4, 3]]")
        self.assertEqual(string_contains.to_full_form(), "List[True, False]")
        self.assertEqual(string_contains_empty.to_full_form(), "True")
        self.assertEqual(string_contains_operator.to_full_form(), 'List["ab", "ba"]')

    def test_string_pattern_functions_support_bounded_symbolic_string_patterns(self) -> None:
        match_q = evaluate(parse_input_form('StringMatchQ["catalog", "c" ~~ __ ~~ "g"]'))
        free_q = evaluate(parse_input_form('StringFreeQ["catalog", DigitCharacter..]'))
        match_empty_null = evaluate(parse_input_form('StringMatchQ["", ___]'))
        match_empty_non_null = evaluate(parse_input_form('StringMatchQ["", __]'))
        contains_named = evaluate(parse_input_form('StringContainsQ["abbcbccaabbabccaa", x_ ~~ x_]'))
        starts_q = evaluate(parse_input_form('StringStartsQ["  a", WhitespaceCharacter.. ~~ LetterCharacter]'))
        ends_q = evaluate(parse_input_form('StringEndsQ["co2x", DigitCharacter ~~ LetterCharacter..]'))
        positions = evaluate(parse_input_form('StringPosition["catalogcat", "c" ~~ __ ~~ "t"]'))
        cases_digits = evaluate(parse_input_form('StringCases["abc123def45", DigitCharacter..]'))
        cases_empty_null = evaluate(parse_input_form('StringCases["", ___]'))
        cases_empty_non_null = evaluate(parse_input_form('StringCases["", __]'))
        cases_named = evaluate(parse_input_form('StringCases["abbcbccaabbabccaa", x_ ~~ x_]'))
        cases_transformed = evaluate(parse_input_form('StringCases["abc123def", x : DigitCharacter.. :> "[" <> x <> "]"]'))
        replace_digits = evaluate(parse_input_form('StringReplace["abc123def", x : DigitCharacter.. :> "[" <> x <> "]"]'))
        replace_non_string = evaluate(parse_input_form('StringReplace["abc123", DigitCharacter.. -> tag]'))
        starts_operator = evaluate(parse_input_form('Select[{"ab", "cd", "bc"}, StringStartsQ["a"]]'))
        ends_operator = evaluate(parse_input_form('Select[{"ab", "ca", "za"}, StringEndsQ["a"]]'))
        equivalent_whitespace = evaluate(parse_input_form('StringMatchQ["  a", Whitespace ~~ LetterCharacter]'))
        character_range = evaluate(parse_input_form('StringMatchQ["abc", CharacterRange["a", "z"]..]'))
        except_chars = evaluate(parse_input_form('StringCases["abc", Except["b"]]'))
        multi_unbounded = evaluate(parse_input_form('StringContainsQ["ababa", ___ ~~ "b" ~~ ___]'))
        letter_digit_runs = evaluate(parse_input_form('StringCases["abc123def45", LetterCharacter.. ~~ DigitCharacter..]'))
        default_longest = evaluate(parse_input_form('StringPosition["ababa", "a" ~~ ___ ~~ "a"]'))
        explicit_shortest = evaluate(parse_input_form('StringPosition["ababa", Shortest["a" ~~ ___ ~~ "a"]]'))
        named_sequence = evaluate(parse_input_form('StringCases["123", x : __ :> x]'))
        named_null_sequence = evaluate(parse_input_form('StringCases["", x : ___ :> x]'))
        tested_sequence = evaluate(parse_input_form('StringCases["123abc", x : __?DigitQ :> x]'))
        tested_pure_sequence = evaluate(parse_input_form('StringCases["abc", __?(StringMatchQ[#, LetterCharacter] &)]'))
        bounded_repeated = evaluate(parse_input_form('StringCases["aaaab", Repeated["a", {2, 3}]]'))
        bounded_repeated_null = evaluate(parse_input_form('StringCases["aaaab", RepeatedNull["a", {2, 3}]]'))
        regular_expression = evaluate(parse_input_form('StringCases["abc123", RegularExpression["[a-z]+"]]'))
        regular_expression_flags = evaluate(parse_input_form('StringCases["abc", RegularExpression["(?i)A"]]'))
        number_string = evaluate(parse_input_form('StringCases["a1 23 -4.5", NumberString]'))
        hex_characters = evaluate(parse_input_form('StringCases["aFz!?", HexadecimalCharacter]'))
        punctuation_characters = evaluate(parse_input_form('StringCases["aFz!?", PunctuationCharacter]'))
        word_boundaries = evaluate(parse_input_form('StringCases["a1 b", WordBoundary ~~ WordCharacter..]'))
        start_of_line = evaluate(parse_input_form('StringCases["a\\nb", StartOfLine ~~ LetterCharacter]'))
        end_of_line = evaluate(parse_input_form('StringCases["a\\nb", LetterCharacter ~~ EndOfLine]'))
        except_list = evaluate(parse_input_form('StringCases["abc", Except[{"a", "b"}]]'))
        except_alternatives = evaluate(parse_input_form('StringCases["abc", Except["a" | "b"]]'))
        except_character_class = evaluate(parse_input_form('StringCases["a1", Except[LetterCharacter, _]]'))
        date_pattern = evaluate(parse_input_form('StringCases["on 2026-04-25 ok", DatePattern[{"Year", "Month", "Day"}]]'))
        date_pattern_separator = evaluate(parse_input_form('StringCases["at 23:59", DatePattern[{"Hour", "Minute"}, ":"]]'))
        date_pattern_month = evaluate(parse_input_form('StringCases["12", DatePattern[{"Month"}]]'))
        digit_q = evaluate(parse_input_form('DigitQ["123"]'))
        letter_q = evaluate(parse_input_form('LetterQ["abc"]'))

        self.assertEqual(match_q.to_full_form(), "True")
        self.assertEqual(free_q.to_full_form(), "True")
        self.assertEqual(match_empty_null.to_full_form(), "True")
        self.assertEqual(match_empty_non_null.to_full_form(), "False")
        self.assertEqual(contains_named.to_full_form(), "True")
        self.assertEqual(starts_q.to_full_form(), "True")
        self.assertEqual(ends_q.to_full_form(), "True")
        self.assertEqual(positions.to_full_form(), "List[List[1, 10], List[8, 10]]")
        self.assertEqual(cases_digits.to_full_form(), 'List["123", "45"]')
        self.assertEqual(cases_empty_null.to_full_form(), 'List[""]')
        self.assertEqual(cases_empty_non_null.to_full_form(), "List[]")
        self.assertEqual(cases_named.to_full_form(), 'List["bb", "cc", "aa", "bb", "cc", "aa"]')
        self.assertEqual(cases_transformed.to_full_form(), 'List["[123]"]')
        self.assertEqual(replace_digits.to_full_form(), '"abc[123]def"')
        self.assertEqual(replace_non_string.to_full_form(), 'StringExpression["abc", tag]')
        self.assertEqual(starts_operator.to_full_form(), 'List["ab"]')
        self.assertEqual(ends_operator.to_full_form(), 'List["ca", "za"]')
        self.assertEqual(equivalent_whitespace.to_full_form(), "True")
        self.assertEqual(character_range.to_full_form(), "True")
        self.assertEqual(except_chars.to_full_form(), 'List["a", "c"]')
        self.assertEqual(multi_unbounded.to_full_form(), "True")
        self.assertEqual(letter_digit_runs.to_full_form(), 'List["abc123", "def45"]')
        self.assertEqual(default_longest.to_full_form(), "List[List[1, 5], List[3, 5]]")
        self.assertEqual(explicit_shortest.to_full_form(), "List[List[1, 3], List[3, 5]]")
        self.assertEqual(named_sequence.to_full_form(), 'List["123"]')
        self.assertEqual(named_null_sequence.to_full_form(), 'List[""]')
        self.assertEqual(tested_sequence.to_full_form(), 'List["123"]')
        self.assertEqual(tested_pure_sequence.to_full_form(), 'List["abc"]')
        self.assertEqual(bounded_repeated.to_full_form(), 'List["aaa"]')
        self.assertEqual(bounded_repeated_null.to_full_form(), 'List["aaa"]')
        self.assertEqual(regular_expression.to_full_form(), 'List["abc"]')
        self.assertEqual(regular_expression_flags.to_full_form(), 'List["a"]')
        self.assertEqual(number_string.to_full_form(), 'List["1", "23", "-4.5"]')
        self.assertEqual(hex_characters.to_full_form(), 'List["a", "F"]')
        self.assertEqual(punctuation_characters.to_full_form(), 'List["!", "?"]')
        self.assertEqual(word_boundaries.to_full_form(), 'List["a1", "b"]')
        self.assertEqual(start_of_line.to_full_form(), 'List["a", "b"]')
        self.assertEqual(end_of_line.to_full_form(), 'List["a", "b"]')
        self.assertEqual(except_list.to_full_form(), 'List["c"]')
        self.assertEqual(except_alternatives.to_full_form(), 'List["c"]')
        self.assertEqual(except_character_class.to_full_form(), 'List["1"]')
        self.assertEqual(date_pattern.to_full_form(), 'List["2026-04-25"]')
        self.assertEqual(date_pattern_separator.to_full_form(), 'List["23:59"]')
        self.assertEqual(date_pattern_month.to_full_form(), 'List["12"]')
        self.assertEqual(digit_q.to_full_form(), "True")
        self.assertEqual(letter_q.to_full_form(), "True")

    def test_string_pattern_subset_rejects_non_string_pattern_shapes(self) -> None:
        self.assert_evaluates_with_message(
            'StringCases["abc", Except["ab"]]',
            'StringCases["abc", Except["ab"]]',
            "StringCases::error",
        )
        self.assert_evaluates_with_message(
            'StringCases["abc", _LetterCharacter]',
            'StringCases["abc", Blank[LetterCharacter]]',
            "StringCases::error",
        )
        self.assert_evaluates_with_message(
            'StringCases["abc", Optional["a"] ~~ "b"]',
            'StringCases["abc", StringExpression[Optional["a"], "b"]]',
            "StringCases::error",
        )

    def test_integer_division_extrema_clipping_and_delta_functions(self) -> None:
        mod_two = evaluate(parse_input_form("Mod[-14, 5]"))
        mod_three = evaluate(parse_input_form("Mod[14, 5, -1]"))
        quotient_two = evaluate(parse_input_form("Quotient[-14, 5]"))
        quotient_three = evaluate(parse_input_form("Quotient[14, 5, -1]"))
        quotient_remainder = evaluate(parse_input_form("QuotientRemainder[-14, 5]"))
        min_empty = evaluate(parse_input_form("Min[]"))
        max_empty = evaluate(parse_input_form("Max[]"))
        min_value = evaluate(parse_input_form("Min[3, 1, 4]"))
        max_value = evaluate(parse_input_form("Max[3, 1, 4]"))
        clip_default = evaluate(parse_input_form("Clip[-3]"))
        clip_bounds = evaluate(parse_input_form("Clip[9, {-5, 5}]"))
        clip_replacements = evaluate(parse_input_form("Clip[-7, {-5, 5}, {100, 200}]"))
        kronecker = evaluate(parse_input_form("KroneckerDelta[3, 3, 3]"))
        kronecker_false = evaluate(parse_input_form("KroneckerDelta[3, 4, 3]"))
        discrete = evaluate(parse_input_form("DiscreteDelta[0, 0]"))
        discrete_false = evaluate(parse_input_form("DiscreteDelta[0, 1]"))
        self.assertEqual(mod_two.to_full_form(), "1")
        self.assertEqual(mod_three.to_full_form(), "-1")
        self.assertEqual(quotient_two.to_full_form(), "-3")
        self.assertEqual(quotient_three.to_full_form(), "3")
        self.assertEqual(quotient_remainder.to_full_form(), "List[-3, 1]")
        self.assertEqual(min_empty.to_full_form(), "Infinity")
        self.assertEqual(max_empty.to_full_form(), "-Infinity")
        self.assertEqual(min_value.to_full_form(), "1")
        self.assertEqual(max_value.to_full_form(), "4")
        self.assertEqual(clip_default.to_full_form(), "-1")
        self.assertEqual(clip_bounds.to_full_form(), "5")
        self.assertEqual(clip_replacements.to_full_form(), "100")
        self.assertEqual(kronecker.to_full_form(), "1")
        self.assertEqual(kronecker_false.to_full_form(), "0")
        self.assertEqual(discrete.to_full_form(), "1")
        self.assertEqual(discrete_false.to_full_form(), "0")

    def test_pick_supports_compatible_first_level_selectors(self) -> None:
        list_pick = evaluate(parse_input_form("Pick[{a, b, c, d}, {False, True, False, True}]"))
        head_pick = evaluate(parse_input_form("Pick[f[a, b, c, d], {False, True, False, True}]"))
        pattern_pick = evaluate(parse_input_form("Pick[{a, b, c, d}, {0, 1, 0, 1}, 1]"))
        association_pick = evaluate(parse_input_form("Pick[<|p -> a, q -> b, r -> c, s -> d|>, {False, True, False, True}]"))
        self.assertEqual(list_pick.to_full_form(), "List[b, d]")
        self.assertEqual(head_pick.to_full_form(), "f[b, d]")
        self.assertEqual(pattern_pick.to_full_form(), "List[b, d]")
        self.assertEqual(association_pick.to_full_form(), "Association[Rule[q, b], Rule[s, d]]")

        self.assert_evaluates_with_message(
            "Pick[{a, b, c, d}, {True, False}]",
            "Pick[List[a, b, c, d], List[True, False]]",
            "Pick::error",
        )

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
        self.assert_evaluates_with_message(
            "Part[<|a -> 1, b -> 2, c -> 3, d -> 4|>, {2, Key[d]}]",
            "Part[Association[Rule[a, 1], Rule[b, 2], Rule[c, 3], Rule[d, 4]], List[2, Key[d]]]",
            "Part::error",
        )

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

    def test_sequence_patterns_support_anonymous_blanksequence_argument_lists(self) -> None:
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
        multiple_true = evaluate(parse_input_form("MatchQ[f[a, b, c], f[__, __]]"))
        multiple_false = evaluate(parse_input_form("MatchQ[f[a], f[__, __]]"))
        multiple_null_true = evaluate(parse_input_form("MatchQ[f[a], f[___, ___]]"))
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
        self.assertEqual(multiple_true.to_full_form(), "True")
        self.assertEqual(multiple_false.to_full_form(), "False")
        self.assertEqual(multiple_null_true.to_full_form(), "True")

    def test_sequence_patterns_support_multiple_occurrences_and_named_bindings(self) -> None:
        split_two = evaluate(parse_input_form("Cases[{f[a, b, c]}, f[x__, y__] :> HoldComplete[{x}, {y}]]"))
        split_three = evaluate(
            parse_input_form("Cases[{f[a, b, c, d]}, f[x__, y__, z__] :> HoldComplete[{x}, {y}, {z}]]")
        )
        null_prefix = evaluate(parse_input_form("Cases[{f[a, b, c]}, f[x___, y__] :> HoldComplete[{x}, {y}]]"))
        same_name_pair = evaluate(parse_input_form("Cases[{f[a, b, a, b]}, f[x__, x__] :> HoldComplete[{x}]]"))
        same_name_single = evaluate(parse_input_form("Cases[{f[a, a]}, f[x__, x__] :> HoldComplete[{x}]]"))
        same_name_failure = evaluate(parse_input_form("Cases[{f[a, b, c]}, f[x__, x__] :> HoldComplete[{x}]]"))
        null_repeated_empty = evaluate(parse_input_form("Cases[{f[]}, f[x___, x___] :> HoldComplete[{x}]]"))
        null_repeated_single_failure = evaluate(parse_input_form("Cases[{f[a]}, f[x___, x___] :> HoldComplete[{x}]]"))
        null_repeated_pair = evaluate(parse_input_form("Cases[{f[a, a]}, f[x___, x___] :> HoldComplete[{x}]]"))
        typed_success = evaluate(parse_input_form("Cases[{f[1, 2, a]}, f[x__Integer, y___Symbol] :> HoldComplete[{x}, {y}]]"))
        typed_failure = evaluate(parse_input_form("Cases[{f[1, a, 2]}, f[x__Integer, y___Symbol] :> HoldComplete[{x}, {y}]]"))
        self.assertEqual(split_two.to_full_form(), "List[HoldComplete[List[a], List[b, c]]]")
        self.assertEqual(split_three.to_full_form(), "List[HoldComplete[List[a], List[b], List[c, d]]]")
        self.assertEqual(null_prefix.to_full_form(), "List[HoldComplete[List[], List[a, b, c]]]")
        self.assertEqual(same_name_pair.to_full_form(), "List[HoldComplete[List[a, b]]]")
        self.assertEqual(same_name_single.to_full_form(), "List[HoldComplete[List[a]]]")
        self.assertEqual(same_name_failure.to_full_form(), "List[]")
        self.assertEqual(null_repeated_empty.to_full_form(), "List[HoldComplete[List[]]]")
        self.assertEqual(null_repeated_single_failure.to_full_form(), "List[]")
        self.assertEqual(null_repeated_pair.to_full_form(), "List[HoldComplete[List[a]]]")
        self.assertEqual(typed_success.to_full_form(), "List[HoldComplete[List[1, 2], List[a]]]")
        self.assertEqual(typed_failure.to_full_form(), "List[]")

    def test_sequence_bindings_splice_in_replacements_and_conditions(self) -> None:
        cases_splice = evaluate(parse_input_form("Cases[{f[a, b]}, f[x__] :> x]"))
        replace_inside_call = evaluate(parse_input_form("f[g[a, b]] /. g[x__] :> x"))
        replace_with_hold = evaluate(parse_input_form("f[g[a, b]] /. g[x__] :> HoldComplete[x]"))
        guarded_true = evaluate(parse_input_form("Cases[{f[a, b], f[a]}, f[x__ /; Length[{x}] == 2] :> HoldComplete[x]]"))
        guarded_false = evaluate(parse_input_form("Cases[{f[a]}, f[x__ /; Length[{x}] == 2] :> HoldComplete[x]]"))
        null_top_level = evaluate(parse_input_form("Cases[{f[]}, f[x___] :> x]"))
        self.assertEqual(cases_splice.to_full_form(), "List[a, b]")
        self.assertEqual(replace_inside_call.to_full_form(), "f[a, b]")
        self.assertEqual(replace_with_hold.to_full_form(), "f[HoldComplete[a, b]]")
        self.assertEqual(guarded_true.to_full_form(), "List[HoldComplete[a, b]]")
        self.assertEqual(guarded_false.to_full_form(), "List[]")
        self.assertEqual(null_top_level.to_full_form(), "List[]")

    def test_pattern_tests_filter_single_and_sequence_patterns(self) -> None:
        scalar_true = evaluate(parse_input_form("MatchQ[1, _?IntegerQ]"))
        scalar_false = evaluate(parse_input_form("MatchQ[a, _?IntegerQ]"))
        sequence_true = evaluate(parse_input_form("Cases[{f[1, 2], f[1, a], f[]}, f[__?IntegerQ]]"))
        delayed_template = evaluate(parse_input_form("Cases[{1, a, 2}, x_?IntegerQ :> x + 10]"))
        self.assertEqual(scalar_true.to_full_form(), "True")
        self.assertEqual(scalar_false.to_full_form(), "False")
        self.assertEqual(sequence_true.to_full_form(), "List[f[1, 2]]")
        self.assertEqual(delayed_template.to_full_form(), "List[11, 12]")

    def test_optional_patterns_support_explicit_defaults_and_default_placeholders(self) -> None:
        explicit = evaluate(parse_input_form("Cases[{f[], f[2], f[a]}, f[x_:7] :> x]"))
        dotted = evaluate(parse_input_form("Cases[{f[], f[2]}, f[x_.] :> HoldComplete[x]]"))
        typed = evaluate(parse_input_form("Cases[{f[], f[2], f[a]}, f[x_Integer:7] :> x]"))
        tested_default = evaluate(parse_input_form("Cases[{f[]}, f[x_?IntegerQ:foo] :> x]"))
        typed_default = evaluate(parse_input_form("Cases[{f[]}, f[x_Integer:foo] :> x]"))
        omitted_before_required = evaluate(parse_input_form("Cases[{f[a]}, f[x_:7, y_] :> {x, y}]"))
        present_before_required = evaluate(parse_input_form("Cases[{f[a, b]}, f[x_:7, y_] :> {x, y}]"))
        self.assertEqual(explicit.to_full_form(), "List[7, 2, a]")
        self.assertEqual(dotted.to_full_form(), "List[HoldComplete[2]]")
        self.assertEqual(typed.to_full_form(), "List[7, 2]")
        self.assertEqual(tested_default.to_full_form(), "List[]")
        self.assertEqual(typed_default.to_full_form(), "List[foo]")
        self.assertEqual(omitted_before_required.to_full_form(), "List[List[7, a]]")
        self.assertEqual(present_before_required.to_full_form(), "List[List[a, b]]")

    def test_repeated_patternsequence_orderless_options_and_match_priorities(self) -> None:
        top_level_repeated = evaluate(parse_input_form("MatchQ[1, Repeated[_Integer]]"))
        top_level_pattern_sequence = evaluate(parse_input_form("MatchQ[1, PatternSequence[_Integer]]"))
        top_level_options = evaluate(parse_input_form("MatchQ[a -> 1, OptionsPattern[]]"))
        top_level_not_options = evaluate(parse_input_form("MatchQ[1, OptionsPattern[]]"))
        bounded_repeated = evaluate(
            parse_input_form("Cases[{f[1], f[1, 2], f[1, 2, 3], f[1, 2, 3, 4]}, f[Repeated[_Integer, {2, 3}]]]")
        )
        bounded_null = evaluate(
            parse_input_form("Cases[{f[], f[1], f[1, 2], f[1, 2, 3]}, f[RepeatedNull[_Integer, 2]]]")
        )
        repeated_sequence = evaluate(parse_input_form("Cases[{f[a, b, a, b], f[a, b, a]}, f[Repeated[PatternSequence[a, b]]] :> ok]"))
        named_sequence = evaluate(
            parse_input_form("Cases[{f[1, 2], f[1, 2, 3]}, f[x:PatternSequence[_Integer, _Integer]] :> HoldComplete[x]]")
        )
        orderless_sequence = evaluate(
            parse_input_form("Cases[{f[1, 2], f[2, 1]}, f[x:OrderlessPatternSequence[1, 2]] :> HoldComplete[x]]")
        )
        shortest_default = evaluate(parse_input_form("Cases[{f[a, b, c]}, f[x__, y__] :> HoldComplete[{x}, {y}]]"))
        longest_left = evaluate(parse_input_form("Cases[{f[a, b, c, d]}, f[Longest[x__], y__] :> HoldComplete[{x}, {y}]]"))
        longest_right = evaluate(parse_input_form("Cases[{f[a, b, c, d]}, f[x__, Longest[y__]] :> HoldComplete[{x}, {y}]]"))
        options = evaluate(
            parse_input_form("Cases[{f[], f[a -> 1], f[{a -> 1}], f[{{}}], f[a], f[1 -> 2]}, f[OptionsPattern[]]]")
        )
        options_binding = evaluate(parse_input_form("Cases[{f[], f[a -> 1]}, f[x:OptionsPattern[]] :> HoldComplete[x]]"))
        self.assertEqual(top_level_repeated.to_full_form(), "True")
        self.assertEqual(top_level_pattern_sequence.to_full_form(), "True")
        self.assertEqual(top_level_options.to_full_form(), "True")
        self.assertEqual(top_level_not_options.to_full_form(), "False")
        self.assertEqual(bounded_repeated.to_full_form(), "List[f[1, 2], f[1, 2, 3]]")
        self.assertEqual(bounded_null.to_full_form(), "List[f[], f[1], f[1, 2]]")
        self.assertEqual(repeated_sequence.to_full_form(), "List[ok]")
        self.assertEqual(named_sequence.to_full_form(), "List[HoldComplete[1, 2]]")
        self.assertEqual(orderless_sequence.to_full_form(), "List[HoldComplete[1, 2], HoldComplete[2, 1]]")
        self.assertEqual(shortest_default.to_full_form(), "List[HoldComplete[List[a], List[b, c]]]")
        self.assertEqual(longest_left.to_full_form(), "List[HoldComplete[List[a, b, c], List[d]]]")
        self.assertEqual(longest_right.to_full_form(), "List[HoldComplete[List[a], List[b, c, d]]]")
        self.assertEqual(options.to_full_form(), "List[f[], f[Rule[a, 1]], f[List[Rule[a, 1]]], f[List[List[]]]]")
        self.assertEqual(options_binding.to_full_form(), "List[HoldComplete[], HoldComplete[Rule[a, 1]]]")

    def test_freeq_defaults_to_heads_true_and_honors_levelspec(self) -> None:
        head_search = evaluate(parse_input_form("FreeQ[f[a], f]"))
        head_level = evaluate(parse_input_form("FreeQ[f[a], f, {1}]"))
        root_only = evaluate(parse_input_form("FreeQ[f[a], f, {0}]"))
        negative_level = evaluate(parse_input_form("FreeQ[f[a, g[b]], g[_], -1]"))
        integer_search = evaluate(parse_input_form("FreeQ[{a, b, b, a}, _Integer]"))
        self.assertEqual(head_search.to_full_form(), "False")
        self.assertEqual(head_level.to_full_form(), "False")
        self.assertEqual(root_only.to_full_form(), "True")
        self.assertEqual(negative_level.to_full_form(), "False")
        self.assertEqual(integer_search.to_full_form(), "True")

    def test_cases_supports_postorder_levels_limits_and_templates(self) -> None:
        leaf_search = evaluate(parse_input_form("Cases[f[a, g[a]], a, Infinity]"))
        postorder = evaluate(parse_input_form("Cases[f[g[a]], _, {0, Infinity}]"))
        negative_level = evaluate(parse_input_form("Cases[f[a, g[b]], _, -1]"))
        limited = evaluate(parse_input_form("Cases[f[a, g[a]], a, Infinity, 1]"))
        transformed = evaluate(parse_input_form("Cases[{f[a], f[b]}, f[x_] :> {x, x}]"))
        self.assertEqual(leaf_search.to_full_form(), "List[a, a]")
        self.assertEqual(postorder.to_full_form(), "List[a, g[a], f[g[a]]]")
        self.assertEqual(negative_level.to_full_form(), "List[a, b, g[b]]")
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
        negative_level = evaluate(parse_input_form("DeleteCases[f[a, g[a]], _Symbol, -1]"))
        limited = evaluate(parse_input_form("DeleteCases[{1, a, 2, a}, a, Infinity, 1]"))
        self.assertEqual(default_levels.to_full_form(), "f[g[a]]")
        self.assertEqual(all_levels.to_full_form(), "f[g[]]")
        self.assertEqual(negative_level.to_full_form(), "f[g[]]")
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

    def test_pattern_search_descends_association_values_not_keys(self) -> None:
        match_assoc = evaluate(parse_input_form("MatchQ[<|a -> 1|>, _Association]"))
        free_q_assoc = evaluate(parse_input_form("FreeQ[<|a -> 1|>, _Integer]"))
        free_q_key = evaluate(parse_input_form("FreeQ[<|a -> 1|>, a]"))
        free_q_head = evaluate(parse_input_form("FreeQ[<|a -> 1|>, Association]"))
        cases_direct = evaluate(parse_input_form("Cases[<|a -> x, b -> 2|>, _Integer]"))
        cases_assoc = evaluate(parse_input_form("Cases[{<|a -> 1|>}, _Integer, Infinity]"))
        cases_key = evaluate(parse_input_form("Cases[<|a -> x, b -> 2|>, a, {0, Infinity}]"))
        delete_direct = evaluate(parse_input_form("DeleteCases[<|a -> 1, b -> x, c -> 2|>, _Integer]"))
        delete_assoc = evaluate(parse_input_form("DeleteCases[{<|a -> 1, b -> x|>}, _Integer, Infinity]"))
        position_assoc = evaluate(parse_input_form("Position[<|a -> 1, b -> {2, x}|>, _Integer]"))
        member_key = evaluate(parse_input_form("MemberQ[<|a -> x, b -> 2|>, a, Infinity]"))
        member_value = evaluate(parse_input_form("MemberQ[<|a -> x, b -> 2|>, x, Infinity]"))
        first_case = evaluate(parse_input_form("FirstCase[<|a -> x, b -> 2|>, _Integer]"))
        self.assertEqual(match_assoc.to_full_form(), "True")
        self.assertEqual(free_q_assoc.to_full_form(), "False")
        self.assertEqual(free_q_key.to_full_form(), "True")
        self.assertEqual(free_q_head.to_full_form(), "False")
        self.assertEqual(cases_direct.to_full_form(), "List[2]")
        self.assertEqual(cases_assoc.to_full_form(), "List[1]")
        self.assertEqual(cases_key.to_full_form(), "List[]")
        self.assertEqual(delete_direct.to_full_form(), "Association[Rule[b, x]]")
        self.assertEqual(delete_assoc.to_full_form(), "List[Association[Rule[b, x]]]")
        self.assertEqual(position_assoc.to_full_form(), "List[List[Key[a]], List[Key[b], 1]]")
        self.assertEqual(member_key.to_full_form(), "False")
        self.assertEqual(member_value.to_full_form(), "True")
        self.assertEqual(first_case.to_full_form(), "2")

    def test_key_value_pattern_matches_association_entries_explicitly(self) -> None:
        simple_match = evaluate(parse_input_form("MatchQ[<|a -> 1, b -> 2|>, KeyValuePattern[a -> _Integer]]"))
        orderless_match = evaluate(parse_input_form("MatchQ[<|a -> 1, b -> 2|>, KeyValuePattern[{b -> 2, a -> _}]]"))
        missing_match = evaluate(parse_input_form("MatchQ[<|a -> 1|>, KeyValuePattern[b -> _]]"))
        nested_nonrecursive = evaluate(parse_input_form("MatchQ[<|a -> <|b -> 2|>|>, KeyValuePattern[b -> _]]"))
        bound_cases = evaluate(parse_input_form("Cases[{<|a -> 1|>, <|b -> x|>}, KeyValuePattern[k_ -> v_] :> {k, v}]"))
        nested_cases = evaluate(parse_input_form("Cases[<|x -> <|a -> 1|>, y -> <|b -> 2|>|>, KeyValuePattern[a -> _], {0, Infinity}]"))
        list_of_rules = evaluate(parse_input_form("MatchQ[{a -> 1, b -> 2}, KeyValuePattern[b -> _Integer]]"))
        rule_delayed_distinction = evaluate(parse_input_form("MatchQ[<|a :> 1|>, KeyValuePattern[a -> _]]"))
        rule_delayed_match = evaluate(parse_input_form("MatchQ[<|a :> 1|>, KeyValuePattern[a :> _]]"))
        duplicate_pattern = evaluate(parse_input_form("MatchQ[<|a -> 1|>, KeyValuePattern[{a -> _, a -> 1}]]"))
        self.assertEqual(simple_match.to_full_form(), "True")
        self.assertEqual(orderless_match.to_full_form(), "True")
        self.assertEqual(missing_match.to_full_form(), "False")
        self.assertEqual(nested_nonrecursive.to_full_form(), "False")
        self.assertEqual(bound_cases.to_full_form(), "List[List[a, 1], List[b, x]]")
        self.assertEqual(nested_cases.to_full_form(), "List[Association[Rule[a, 1]]]")
        self.assertEqual(list_of_rules.to_full_form(), "True")
        self.assertEqual(rule_delayed_distinction.to_full_form(), "False")
        self.assertEqual(rule_delayed_match.to_full_form(), "True")
        self.assertEqual(duplicate_pattern.to_full_form(), "False")


if __name__ == "__main__":
    unittest.main()
