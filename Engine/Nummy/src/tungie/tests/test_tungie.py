from __future__ import annotations

import io
import unittest

from tungie import EvaluationSession
from tungie import evaluate
from tungie import parse
from tungie.errors import TungieSyntaxError
from tungie.repl import run_repl


def eval_text(source: str, session: EvaluationSession | None = None) -> str:
    return evaluate(parse(source), session=session).to_full_form()


class ParserTests(unittest.TestCase):
    def test_parses_calculator_expression_subset(self) -> None:
        self.assertEqual(parse("1 + 2 x^3").to_full_form(), "Plus[1, Times[2, Power[x, 3]]]")
        self.assertEqual(parse("{1, 2, 3}").to_full_form(), "List[1, 2, 3]")
        self.assertEqual(parse("1.2`20").to_full_form(), "1.2`20")
        self.assertEqual(parse("1.2``3").to_full_form(), "1.2``3")
        self.assertEqual(parse("1.2*^3").to_full_form(), "1.2*^3")
        self.assertEqual(parse(".5").to_full_form(), ".5")
        self.assertEqual(parse("1.2/^3").to_full_form(), "1.2*^-3")
        self.assertEqual(parse("1.2*^-3").to_input_form(), "1.2/^3")
        self.assertEqual(parse("1.2 *^ -3").to_input_form(), "1.2/^3")
        self.assertEqual(
            parse("1.2*^^3").to_full_form(),
            "ScientificScale[1.2, Pow10Tower[1, 3]]",
        )
        self.assertEqual(
            parse("1.2/^^3").to_full_form(),
            "ScientificScale[1.2, Times[-1, Pow10Tower[1, 3]]]",
        )
        self.assertEqual(parse("1.2*^^^3").to_input_form(), "1.2*^^^3")

    def test_rejects_deliberately_excluded_syntax(self) -> None:
        rejected = [
            '"x"',
            "a -> b",
            "a :> b",
            "16^^ff",
            "x = y = 5",
            "1 < 2 < 3",
            "f[1; 2]",
            "(1; 2)",
            "1.2/^-3",
            "1.2/^^-3",
            "1.2/^^(-3)",
            "1.2*^^-3",
            "1.2*^^(-3)",
        ]
        for source in rejected:
            with self.subTest(source=source):
                with self.assertRaises(TungieSyntaxError):
                    parse(source)


class EvaluationTests(unittest.TestCase):
    def test_exact_integer_and_rational_arithmetic(self) -> None:
        self.assertEqual(eval_text("1 + 2*3"), "7")
        self.assertEqual(eval_text("2^10"), "1024")
        self.assertEqual(eval_text("2^-3"), "Rational[1, 8]")
        self.assertEqual(eval_text("1/2 + 1/3"), "Rational[5, 6]")
        self.assertEqual(eval_text("(2/3) (9/4)"), "Rational[3, 2]")
        self.assertEqual(eval_text("Rational[2, 4]"), "Rational[1, 2]")

    def test_invalid_numeric_operations_return_undefined_and_emit_messages(self) -> None:
        invalid = {
            "1/0": "Division by zero.",
            "0/0": "Division by zero.",
            "1./0.": "Division by zero.",
            "Rational[1, 0]": "Division by zero.",
            "0^-1": "Zero cannot be raised to a negative power.",
            "0.^-1": "Zero cannot be raised to a negative power.",
            "(-1)^(1/2)": "Negative numbers cannot be raised to non-integer powers.",
            "Sqrt[-1]": "Negative numbers cannot be raised to non-integer powers.",
        }
        for source, message in invalid.items():
            with self.subTest(source=source):
                session = EvaluationSession()
                _line, result = session.evaluate_input(parse(source))
                self.assertEqual(result.to_full_form(), "Undefined")
                self.assertEqual(session.current_messages, [f"Evaluate::error: {message}"])

    def test_undefined_propagates_through_arithmetic_and_relations(self) -> None:
        self.assertEqual(eval_text("Undefined + 1"), "Undefined")
        self.assertEqual(eval_text("2 Undefined"), "Undefined")
        self.assertEqual(eval_text("Undefined/3"), "Undefined")
        self.assertEqual(eval_text("Undefined^2"), "Undefined")
        self.assertEqual(eval_text("Undefined < 3"), "Undefined")
        self.assertEqual(eval_text("Undefined == Undefined"), "Undefined")
        self.assertEqual(eval_text("Abs[Undefined]"), "Undefined")
        self.assertEqual(eval_text("Min[1, Undefined]"), "Undefined")
        self.assertEqual(eval_text("UndefinedQ[Undefined]"), "True")
        self.assertEqual(eval_text("UndefinedQ[1]"), "False")
        session = EvaluationSession()
        _line, result = session.evaluate_input(parse("UndefinedQ[1/0]"))
        self.assertEqual(result.to_full_form(), "True")
        self.assertEqual(session.current_messages, ["Evaluate::error: Division by zero."])

    def test_if_treats_undefined_condition_specially(self) -> None:
        self.assertEqual(eval_text("If[Undefined, 1, 2]"), "Undefined")
        self.assertEqual(eval_text("If[True, Undefined, 2]"), "Undefined")
        self.assertEqual(eval_text("If[False, Undefined, 2]"), "2")

    def test_tracked_precision_real_arithmetic(self) -> None:
        self.assertEqual(eval_text(".5"), ".5`16")
        self.assertEqual(
            eval_text(".500000000000000000000000000000000000"),
            ".500000000000000000000000000000000000`36",
        )
        self.assertEqual(eval_text("1.234567890123456789 + 0"), "1.234567890123456789`19")
        self.assertEqual(eval_text("1 + 2."), "3.`16")
        self.assertEqual(eval_text("1./3"), "0.3333333333333333`16")
        self.assertEqual(eval_text("1.25`20 + 2.5`20"), "3.75`20")
        self.assertEqual(eval_text("N[1/3]"), "0.3333333333333333`16")
        self.assertEqual(eval_text("N[1/3, 20]"), "0.33333333333333333333`20")
        self.assertEqual(eval_text("N[Pi, 20]"), "3.1415926535897932385`20")
        self.assertEqual(eval_text("N[Sqrt[2], 20]"), "1.4142135623730950488`20")
        self.assertEqual(eval_text("10^309."), "1`16*^309")
        self.assertEqual(eval_text("10^309.`20"), "1`20*^309")
        self.assertEqual(eval_text("1.1*^^2"), "1.1`16*^100")
        self.assertEqual(evaluate(parse("1.1/^^2")).to_input_form(), "1.1`16/^100")
        self.assertEqual(
            eval_text("1.1*^^6"),
            "ScientificScale[1.1`16, Pow10Tower[1, 6]]",
        )
        self.assertEqual(evaluate(parse("1.1*^^6")).to_input_form(), "1.1`16*^^6")

    def test_precision_and_accuracy_builtins(self) -> None:
        self.assertEqual(eval_text("Precision[1]"), "Infinity")
        self.assertEqual(eval_text("Precision[1.]"), "16.")
        self.assertEqual(
            eval_text("Precision[.500000000000000000000000000000000000]"),
            "36.",
        )
        self.assertEqual(eval_text("Precision[1.23`20]"), "20.")
        self.assertEqual(eval_text("Precision[.1`0]"), "0.")
        self.assertEqual(eval_text("Abs[-.1`0]"), "0.1`0")
        self.assertEqual(eval_text(".1`0 + 0"), "0.1`0")
        self.assertEqual(eval_text("Accuracy[1000.]"), "13.")
        self.assertEqual(eval_text("SetPrecision[1/3, 20]"), "0.33333333333333333333`20")
        self.assertEqual(eval_text("SetPrecision[1.25, Infinity]"), "Rational[5, 4]")
        self.assertEqual(eval_text("SetAccuracy[1.23, 20]"), "1.23``20")
        self.assertEqual(eval_text("MachineNumberQ[1.]"), "False")

    def test_calculator_builtins(self) -> None:
        self.assertEqual(eval_text("Abs[-3]"), "3")
        self.assertEqual(eval_text("Sign[-3/2]"), "-1")
        self.assertEqual(eval_text("Floor[3.7]"), "3")
        self.assertEqual(eval_text("Ceiling[-3.7]"), "-3")
        self.assertEqual(eval_text("Round[2.5]"), "2")
        self.assertEqual(eval_text("IntegerPart[-3.7]"), "-3")
        self.assertEqual(eval_text("FractionalPart[-3.7]"), "-0.7`16")
        self.assertEqual(eval_text("Min[3, 2, 5]"), "2")
        self.assertEqual(eval_text("Max[3/2, 1.7]"), "1.7`16")
        self.assertEqual(eval_text("Exp[1.]"), "2.718281828459045`16")
        self.assertEqual(eval_text("Exp[1]"), "E")
        self.assertEqual(eval_text("Log[E]"), "1")
        self.assertEqual(eval_text("Log[10, 1000]"), "3")

    def test_booleans_if_lists_and_comparisons(self) -> None:
        self.assertEqual(eval_text("True && False"), "False")
        self.assertEqual(eval_text("True || False"), "True")
        self.assertEqual(eval_text("!False"), "True")
        self.assertEqual(eval_text("If[1 < 2, 7, 9]"), "7")
        self.assertEqual(eval_text("1/2 < .75"), "True")
        self.assertEqual(eval_text("{1, 2} + 3"), "List[4, 5]")
        self.assertEqual(eval_text("N[{1/2, 1/3}, 5]"), "List[0.5`5, 0.33333`5]")

    def test_excluded_builtins_remain_inert(self) -> None:
        self.assertEqual(eval_text("Sin[0]"), "Sin[0]")
        self.assertEqual(eval_text("Quit"), "Quit")
        self.assertEqual(eval_text("Boole[True]"), "Boole[True]")
        self.assertEqual(eval_text("InputForm[1 + x]"), "InputForm[Plus[1, x]]")
        self.assertEqual(eval_text("Short[{1, 2, 3}]"), "Short[List[1, 2, 3]]")

    def test_precision_symbol_controls_unspecified_exact_power_approximation(self) -> None:
        session = EvaluationSession()
        self.assertEqual(session.evaluate_input(parse("$Precision"))[1].to_full_form(), "16")
        self.assertEqual(session.evaluate_input(parse("2^(1/2)"))[1].to_full_form(), "1.414213562373095`16")
        self.assertEqual(session.evaluate_input(parse("$Precision = 20"))[1].to_full_form(), "20")
        self.assertEqual(
            session.evaluate_input(parse("2^(1/2)"))[1].to_full_form(),
            "1.4142135623730950488`20",
        )
        self.assertEqual(
            session.evaluate_input(parse("N[2^(1/2), 50]"))[1].to_full_form(),
            "1.4142135623730950488016887242096980785696718753769`50",
        )
        self.assertEqual(
            session.evaluate_input(parse("N[2^(1/2), 52]"))[1].to_full_form(),
            "1.414213562373095048801688724209698078569671875376948`52",
        )
        self.assertEqual(session.evaluate_input(parse("N[$Precision, 50]"))[1].to_full_form(), "50.`50")
        self.assertEqual(session.evaluate_input(parse("$Precision"))[1].to_full_form(), "20")
        self.assertEqual(eval_text("N[Sqrt[2], 20]"), "1.4142135623730950488`20")

    def test_exact_power_rules(self) -> None:
        self.assertEqual(eval_text("(1/8)^(-1/3)"), "2")
        self.assertEqual(eval_text("(27/8)^(2/3)"), "Rational[9, 4]")
        self.assertEqual(eval_text("2^(1/2)"), "1.414213562373095`16")
        self.assertEqual(eval_text("2^.5`50"), "1.414213562373095048801688724209698078569671875377`49")
        self.assertEqual(eval_text("0^0"), "1")
        self.assertEqual(eval_text("x^0"), "1")
        self.assertEqual(eval_text("0^(1/2)"), "0")
        self.assertEqual(eval_text("1^x"), "1")

    def test_session_assignment_clear_and_history(self) -> None:
        session = EvaluationSession()
        self.assertEqual(session.evaluate_input(parse("x = 3"))[1].to_full_form(), "3")
        self.assertEqual(session.evaluate_input(parse("x + 2"))[1].to_full_form(), "5")
        self.assertEqual(session.evaluate_input(parse("% + %1"))[1].to_full_form(), "8")
        self.assertEqual(session.evaluate_input(parse("Out[1]"))[1].to_full_form(), "3")
        self.assertEqual(session.evaluate_input(parse("Clear[x]"))[1].to_full_form(), "Null")
        self.assertEqual(session.evaluate_input(parse("x + 2"))[1].to_full_form(), "Plus[2, x]")

    def test_top_level_semicolon_programs(self) -> None:
        session = EvaluationSession()
        self.assertEqual(session.evaluate_input(parse("x = 1; x + 2"))[1].to_full_form(), "3")
        line, result = session.evaluate_input(parse("x = 2;"))
        self.assertEqual(result.to_full_form(), "Null")
        self.assertEqual(session.outputs[line].to_full_form(), "Null")
        self.assertEqual(session.evaluate_input(parse("Out[2]"))[1].to_full_form(), "Null")
        self.assertEqual(session.evaluate_input(parse("%"))[1].to_full_form(), "Null")

    def test_predefined_symbols_cannot_be_assigned(self) -> None:
        session = EvaluationSession()
        line, result = session.evaluate_input(parse("Pi = 3"))
        self.assertEqual(result.to_full_form(), "Null")
        self.assertEqual(session.outputs[line].to_full_form(), "Null")
        self.assertEqual(session.current_messages, ["Evaluate::error: Cannot assign to predefined symbol Pi."])
        self.assertEqual(session.evaluate_input(parse("Pi"))[1].to_full_form(), "Pi")

        _line, result = session.evaluate_input(parse("Plus = 1/0"))
        self.assertEqual(result.to_full_form(), "Null")
        self.assertEqual(session.current_messages, ["Evaluate::error: Cannot assign to predefined symbol Plus."])

    def test_clear_reports_predefined_symbols_and_clears_others(self) -> None:
        session = EvaluationSession()
        session.evaluate_input(parse("x = 3"))
        session.evaluate_input(parse("y = 4"))

        _line, result = session.evaluate_input(parse("Clear[x, Pi, y, E]"))
        messages = list(session.current_messages or [])

        self.assertEqual(result.to_full_form(), "Null")
        self.assertEqual(
            messages,
            [
                "Evaluate::error: Cannot clear predefined symbol Pi.",
                "Evaluate::error: Cannot clear predefined symbol E.",
            ],
        )
        self.assertEqual(session.evaluate_input(parse("x"))[1].to_full_form(), "x")
        self.assertEqual(session.evaluate_input(parse("y"))[1].to_full_form(), "y")


class ReplTests(unittest.TestCase):
    def test_repl_ctrl_c_exits_without_traceback(self) -> None:
        class InterruptedInput(io.StringIO):
            def readline(self, *args, **kwargs) -> str:  # type: ignore[no-untyped-def]
                raise KeyboardInterrupt

        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=InterruptedInput(), stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 130)
        self.assertEqual(stdout.getvalue(), "In[1]:= \n")
        self.assertEqual(stderr.getvalue(), "")

    def test_repl_uses_tungsten_style_prompts_history_and_exit(self) -> None:
        stdin = io.StringIO("1+2\n% + 10\n%% + %1\nExit[7]\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 7)
        transcript = stdout.getvalue()
        self.assertIn("In[1]:=", transcript)
        self.assertIn("Out[1]= 3", transcript)
        self.assertIn("Out[2]= 13", transcript)
        self.assertIn("Out[3]= 6", transcript)
        self.assertEqual(stderr.getvalue(), "")

    def test_quit_is_not_a_repl_exit_command(self) -> None:
        stdin = io.StringIO("Quit\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        self.assertIn("Out[1]= Quit", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "")

    def test_repl_prints_messages_and_undefined_result(self) -> None:
        stdin = io.StringIO("1/0\nExit[]\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        self.assertIn("Out[1]= Undefined", stdout.getvalue())
        self.assertEqual(stderr.getvalue(), "Evaluate::error: Division by zero.\n")

    def test_repl_suppresses_null_results_but_continues_history(self) -> None:
        stdin = io.StringIO("1+1;\n2+2\nExit[]\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertNotIn("Out[1]=", transcript)
        self.assertIn("Out[2]= 4", transcript)
        self.assertEqual(stderr.getvalue(), "")

    def test_repl_reports_predefined_assignment_without_printing_null(self) -> None:
        stdin = io.StringIO("Pi = 3\n2+2\nExit[]\n")
        stdout = io.StringIO()
        stderr = io.StringIO()

        exit_code = run_repl(stdin=stdin, stdout=stdout, stderr=stderr, show_banner=False)

        self.assertEqual(exit_code, 0)
        transcript = stdout.getvalue()
        self.assertNotIn("Out[1]=", transcript)
        self.assertIn("Out[2]= 4", transcript)
        self.assertEqual(stderr.getvalue(), "Evaluate::error: Cannot assign to predefined symbol Pi.\n")


if __name__ == "__main__":
    unittest.main()
