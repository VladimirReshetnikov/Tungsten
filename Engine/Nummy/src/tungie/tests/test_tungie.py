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

    def test_machine_and_precision_real_arithmetic(self) -> None:
        self.assertEqual(eval_text("1 + 2."), "3.")
        self.assertEqual(eval_text("1./3"), "0.3333333333333333")
        self.assertEqual(eval_text("1.25`20 + 2.5`20"), "3.75`20.")
        self.assertEqual(eval_text("N[1/3]"), "0.3333333333333333")
        self.assertEqual(eval_text("N[1/3, 20]"), "0.33333333333333333333`20.")
        self.assertEqual(eval_text("N[Pi, 20]"), "3.1415926535897932385`20.")
        self.assertEqual(eval_text("N[Sqrt[2], 20]"), "1.4142135623730950488`20.")

    def test_precision_and_accuracy_builtins(self) -> None:
        self.assertEqual(eval_text("Precision[1]"), "Infinity")
        self.assertEqual(eval_text("Precision[1.]"), "MachinePrecision")
        self.assertEqual(eval_text("Precision[1.23`20]"), "20.")
        self.assertEqual(eval_text("Accuracy[1000.]"), "12.954589770191003")
        self.assertEqual(eval_text("SetPrecision[1/3, 20]"), "0.33333333333333333333`20.")
        self.assertEqual(eval_text("SetPrecision[1.25, Infinity]"), "Rational[5, 4]")
        self.assertEqual(eval_text("SetAccuracy[1.23, 20]"), "1.23``20.")

    def test_calculator_builtins(self) -> None:
        self.assertEqual(eval_text("Abs[-3]"), "3")
        self.assertEqual(eval_text("Sign[-3/2]"), "-1")
        self.assertEqual(eval_text("Floor[3.7]"), "3")
        self.assertEqual(eval_text("Ceiling[-3.7]"), "-3")
        self.assertEqual(eval_text("Round[2.5]"), "2")
        self.assertEqual(eval_text("IntegerPart[-3.7]"), "-3")
        self.assertEqual(eval_text("FractionalPart[-3.7]"), "-0.7000000000000002")
        self.assertEqual(eval_text("Min[3, 2, 5]"), "2")
        self.assertEqual(eval_text("Max[3/2, 1.7]"), "1.7")
        self.assertEqual(eval_text("Exp[1.]"), "2.718281828459045")
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
        self.assertEqual(eval_text("N[{1/2, 1/3}, 5]"), "List[0.5`5., 0.33333`5.]")

    def test_excluded_builtins_remain_inert(self) -> None:
        self.assertEqual(eval_text("Sin[0]"), "Sin[0]")
        self.assertEqual(eval_text("Quit"), "Quit")
        self.assertEqual(eval_text("Boole[True]"), "Boole[True]")
        self.assertEqual(eval_text("InputForm[1 + x]"), "InputForm[Plus[1, x]]")
        self.assertEqual(eval_text("Short[{1, 2, 3}]"), "Short[List[1, 2, 3]]")

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
        self.assertEqual(session.evaluate_input(parse("x = 2;"))[1].to_full_form(), "Null")


class ReplTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
