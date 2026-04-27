from __future__ import annotations

from dataclasses import dataclass
import re
import sys
from typing import Iterable, Sequence, TypeGuard
import unicodedata


# The Pratt parser recurses deeply into nested expressions; CPython's default
# 1000-frame limit trips on real-world packages such as
# ``mathics-core/mathics/Packages/DiscreteMath/RSolve.m``. Raising the limit at
# import time keeps the module side-effect minimal.
_PARSER_RECURSION_FLOOR = 5000
if sys.getrecursionlimit() < _PARSER_RECURSION_FLOOR:
    sys.setrecursionlimit(_PARSER_RECURSION_FLOOR)

from .wolfram_strings import parse_wl_string_literal
from .wolfram_strings import skip_wl_comment
from .wolfram_strings import skip_wl_string
from .wolfram_strings import wl_string

from .expression import _ADDITIONAL_ESCAPED_INFIX_OPERATOR_HEAD_NAMES
from .expression import _ESCAPED_INFIX_OPERATOR_HEADS
from .expression import _ESCAPED_SYMBOL_ALIASES
from .expression import _ESCAPED_TOKEN_MAP
from .expression import _FLAT_HEADS
from .expression import _PREC_ALTERNATIVES
from .expression import _PREC_AND
from .expression import _PREC_APPLY
from .expression import _PREC_ASSIGNMENT
from .expression import _PREC_ATOM
from .expression import _PREC_CALL
from .expression import _PREC_COMPOSITION
from .expression import _PREC_COMPARE
from .expression import _PREC_CONDITION
from .expression import _PREC_FUNCTION
from .expression import _PREC_INFIX_FUNCTION
from .expression import _PREC_LOWEST
from .expression import _PREC_MAP
from .expression import _PREC_MESSAGE_NAME
from .expression import _PREC_OR
from .expression import _PREC_PART
from .expression import _PREC_PLUS
from .expression import _PREC_POSTFIX
from .expression import _PREC_POSTFIX_UNARY
from .expression import _PREC_POWER
from .expression import _PREC_PREFIX
from .expression import _PREC_PUT
from .expression import _PREC_REPLACE
from .expression import _PREC_RULE
from .expression import _PREC_STRING_EXPRESSION
from .expression import _PREC_TIMES
from .expression import _PREC_TWO_WAY_RULE
from .expression import Call
from .expression import ComplexNumber
from .expression import Expr
from .expression import Integer
from .expression import RationalNumber
from .expression import Real
from .expression import SpecialReal
from .expression import String
from .expression import Symbol
from .expression import WolframSyntaxError
from .expression import _association_from_arguments
from .expression import _is_association
from .expression import call
from .expression import integer
from .expression import list_expr
from .expression import rational_number
from .expression import real
from .expression import string
from .expression import symbol


def parse_expression(text: str, form: str = "input") -> Expr:
    normalized_form = form.strip().lower()
    if normalized_form not in {"input", "fullform", "full", "standard", "standardform"}:
        raise ValueError(f"Unsupported Wolfram expression form: {form!r}")

    parser = _Parser(text)
    expr = parser.parse()
    if normalized_form in {"standard", "standardform"}:
        return _interpret_standard_form(expr)
    return expr


def parse_input_form(text: str) -> Expr:
    return parse_expression(text, form="input")


def parse_full_form(text: str) -> Expr:
    return parse_expression(text, form="fullform")


def parse_standard_form(text: str) -> Expr:
    return parse_expression(text, form="standard")


def interpret_standard_form(expr: Expr) -> Expr:
    return _interpret_standard_form(expr)


def box_item_to_standard_text(expr: Expr) -> str:
    return _box_item_to_standard_text(expr)


_BOX_UNWRAP_HEADS = {
    "AdjustmentBox",
    "BoxData",
    "FormBox",
    "FrameBox",
    "PaneBox",
    "StyleBox",
    "TagBox",
    "TooltipBox",
}


def _interpret_standard_form(expr: Expr) -> Expr:
    if isinstance(expr, (Symbol, Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    if expr.has_head("InterpretationBox") and len(expr.arguments) >= 2:
        return _interpret_standard_form(expr.arguments[1])

    if isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _BOX_UNWRAP_HEADS and expr.arguments:
        return _interpret_standard_form(expr.arguments[0])

    if expr.has_head("RowBox"):
        return _interpret_row_box(expr)

    if expr.has_head("FractionBox"):
        return _interpret_fraction_box(expr)

    if expr.has_head("SqrtBox"):
        return _interpret_sqrt_box(expr)

    if expr.has_head("RadicalBox"):
        return _interpret_radical_box(expr)

    if expr.has_head("SuperscriptBox"):
        return _interpret_superscript_box(expr)

    if expr.has_head("SubscriptBox"):
        return _interpret_script_box(expr, "Subscript", 2)

    if expr.has_head("SubsuperscriptBox"):
        return _interpret_script_box(expr, "Subsuperscript", 3)

    if expr.has_head("OverscriptBox"):
        return _interpret_script_box(expr, "Overscript", 2)

    if expr.has_head("UnderscriptBox"):
        return _interpret_script_box(expr, "Underscript", 2)

    if expr.has_head("UnderoverscriptBox"):
        return _interpret_script_box(expr, "Underoverscript", 3)

    return Call(
        head_expr=_interpret_standard_form(expr.head_expr),
        arguments=tuple(_interpret_standard_form(argument) for argument in expr.arguments),
    )


def _interpret_row_box(expr: Call) -> Expr:
    if len(expr.arguments) != 1:
        return expr

    items = expr.arguments[0]
    if not isinstance(items, Call) or not items.has_head("List"):
        return expr

    text = _row_box_to_standard_text(expr)
    stripped = text.strip()
    if not stripped:
        return string("")
    return parse_standard_form(stripped)


def _row_box_to_standard_text(expr: Call) -> str:
    if len(expr.arguments) != 1:
        return expr.to_input_form()
    items = expr.arguments[0]
    if not isinstance(items, Call) or not items.has_head("List"):
        return expr.to_input_form()
    return _join_row_box_text(_box_item_to_standard_text(item) for item in items.arguments)


def _join_row_box_text(pieces: Iterable[str]) -> str:
    text = ""
    previous = ""
    for piece in pieces:
        if piece == "":
            continue
        if not text:
            text = piece
        elif _needs_row_box_separator(previous, piece):
            text += " " + piece
        else:
            text += piece
        previous = piece
    return text


def _needs_row_box_separator(left: str, right: str) -> bool:
    if left.isspace() or right.isspace() or left.endswith((" ", "\t", "\n")) or right.startswith((" ", "\t", "\n")):
        return False
    if left[-1:] in "[({<,.;+-*/^!@&|=_:" or right[:1] in "])}>,.;+-*/^!@&|=_:":
        return False
    return True


def _interpret_fraction_box(expr: Call) -> Expr:
    if len(expr.arguments) < 2:
        return expr
    numerator = _interpret_box_operand(expr.arguments[0])
    denominator = _interpret_box_operand(expr.arguments[1])
    return _make_division(numerator, denominator)


def _interpret_sqrt_box(expr: Call) -> Expr:
    if not expr.arguments:
        return expr
    radicand = _interpret_box_operand(expr.arguments[0])
    if _has_true_option(expr.arguments[1:], "SurdForm"):
        return call("Surd", radicand, integer(2))
    return call("Power", radicand, call("Rational", integer(1), integer(2)))


def _interpret_radical_box(expr: Call) -> Expr:
    if len(expr.arguments) < 2:
        return expr
    radicand = _interpret_box_operand(expr.arguments[0])
    index = _interpret_box_operand(expr.arguments[1])
    if _has_true_option(expr.arguments[2:], "SurdForm"):
        return call("Surd", radicand, index)
    return call("Power", radicand, _make_division(integer(1), index))


def _interpret_superscript_box(expr: Call) -> Expr:
    if len(expr.arguments) < 2:
        return expr
    base = _interpret_box_operand(expr.arguments[0])
    exponent = _interpret_box_operand(expr.arguments[1])
    return call("Power", base, exponent)


def _interpret_script_box(expr: Call, head_name: str, arity: int) -> Expr:
    if len(expr.arguments) < arity:
        return expr
    return call(head_name, *(_interpret_box_operand(argument) for argument in expr.arguments[:arity]))


def _interpret_box_operand(expr: Expr) -> Expr:
    interpreted = _interpret_standard_form(expr)
    return _coerce_box_operand(interpreted)


def _coerce_box_operand(expr: Expr) -> Expr:
    if isinstance(expr, String):
        text = expr.value.strip()
        if not text:
            return string(expr.value)
        try:
            return _canonicalize_box_expression(parse_input_form(text))
        except WolframSyntaxError:
            return string(expr.value)

    return _canonicalize_box_expression(expr)


def _canonicalize_box_expression(expr: Expr) -> Expr:
    if isinstance(expr, (Symbol, Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    normalized = call(
        _canonicalize_box_expression(expr.head_expr),
        *(_canonicalize_box_expression(argument) for argument in expr.arguments),
    )
    rational = _try_box_rational(normalized)
    if rational is not None:
        return rational
    return normalized


def _try_box_rational(expr: Call) -> Expr | None:
    if not expr.has_head("Times") or len(expr.arguments) != 2:
        return None

    numerator, denominator_power = expr.arguments
    if not isinstance(numerator, Integer):
        return None

    if (
        not isinstance(denominator_power, Call)
        or not denominator_power.has_head("Power")
        or len(denominator_power.arguments) != 2
    ):
        return None

    denominator, exponent = denominator_power.arguments
    if not isinstance(denominator, Integer):
        return None
    if not isinstance(exponent, Integer) or exponent.value != -1:
        return None

    return call("Rational", numerator, denominator)


def _box_item_to_standard_text(expr: Expr) -> str:
    if isinstance(expr, String):
        value = expr.value
        if value.startswith("\"") and value.endswith("\"") and len(value) >= 2:
            value = value[1:-1]
            if value.startswith(r"\<") and value.endswith(r"\>") and len(value) >= 4:
                return wl_string(value[2:-2])
            return wl_string(value)
        if value.startswith(r"\<") and value.endswith(r"\>") and len(value) >= 4:
            return wl_string(value[2:-2])
        return _normalize_row_box_token(value)

    if isinstance(expr, (Symbol, Integer, Real, RationalNumber, ComplexNumber, SpecialReal)):
        return expr.to_input_form()

    if isinstance(expr, Call):
        if expr.has_head("InterpretationBox") and len(expr.arguments) >= 2:
            return _interpret_standard_form(expr.arguments[1]).to_input_form()

        if isinstance(expr.head_expr, Symbol) and expr.head_expr.name in _BOX_UNWRAP_HEADS and expr.arguments:
            return _box_item_to_standard_text(expr.arguments[0])

        if expr.has_head("RowBox"):
            if _row_box_has_explicit_grouping(expr):
                return _row_box_to_standard_text(expr)
            try:
                interpreted = _interpret_row_box(expr)
            except WolframSyntaxError:
                if len(expr.arguments) == 1 and isinstance(expr.arguments[0], Call) and expr.arguments[0].has_head("List"):
                    return _join_row_box_text(_box_item_to_standard_text(item) for item in expr.arguments[0].arguments)
                raise
            return interpreted.to_input_form()

        if expr.has_head("FractionBox") and len(expr.arguments) >= 2:
            numerator = _box_item_to_standard_text(expr.arguments[0])
            denominator = _box_item_to_standard_text(expr.arguments[1])
            return f"(({numerator})/({denominator}))"

        if expr.has_head("SqrtBox") and expr.arguments:
            radicand = _box_item_to_standard_text(expr.arguments[0])
            if _has_true_option(expr.arguments[1:], "SurdForm"):
                return f"Surd[{radicand}, 2]"
            return f"(({radicand})^(1/2))"

        if expr.has_head("RadicalBox") and len(expr.arguments) >= 2:
            radicand = _box_item_to_standard_text(expr.arguments[0])
            index = _box_item_to_standard_text(expr.arguments[1])
            if _has_true_option(expr.arguments[2:], "SurdForm"):
                return f"Surd[{radicand}, {index}]"
            return f"(({radicand})^(1/({index})))"

        if expr.has_head("SuperscriptBox") and len(expr.arguments) >= 2:
            base = _box_item_to_standard_text(expr.arguments[0])
            exponent = _box_item_to_standard_text(expr.arguments[1])
            return f"(({base})^({exponent}))"

        if expr.has_head("SubscriptBox") and len(expr.arguments) >= 2:
            base = _box_item_to_standard_text(expr.arguments[0])
            subscript = _box_item_to_standard_text(expr.arguments[1])
            return f"Subscript[{base}, {subscript}]"

        if expr.has_head("SubsuperscriptBox") and len(expr.arguments) >= 3:
            base = _box_item_to_standard_text(expr.arguments[0])
            subscript = _box_item_to_standard_text(expr.arguments[1])
            superscript = _box_item_to_standard_text(expr.arguments[2])
            return f"Subsuperscript[{base}, {subscript}, {superscript}]"

        if expr.has_head("OverscriptBox") and len(expr.arguments) >= 2:
            base = _box_item_to_standard_text(expr.arguments[0])
            overscript = _box_item_to_standard_text(expr.arguments[1])
            return f"Overscript[{base}, {overscript}]"

        if expr.has_head("UnderscriptBox") and len(expr.arguments) >= 2:
            base = _box_item_to_standard_text(expr.arguments[0])
            underscript = _box_item_to_standard_text(expr.arguments[1])
            return f"Underscript[{base}, {underscript}]"

        if expr.has_head("UnderoverscriptBox") and len(expr.arguments) >= 3:
            base = _box_item_to_standard_text(expr.arguments[0])
            underscript = _box_item_to_standard_text(expr.arguments[1])
            overscript = _box_item_to_standard_text(expr.arguments[2])
            return f"Underoverscript[{base}, {underscript}, {overscript}]"

    return _interpret_standard_form(expr).to_input_form()


def _row_box_has_explicit_grouping(expr: Call) -> bool:
    if len(expr.arguments) != 1:
        return False
    items = expr.arguments[0]
    if not isinstance(items, Call) or not items.has_head("List") or len(items.arguments) < 2:
        return False
    first, last = items.arguments[0], items.arguments[-1]
    if not isinstance(first, String) or not isinstance(last, String):
        return False
    return (first.value, last.value) in {
        ("(", ")"),
        ("[", "]"),
        ("{", "}"),
    }


def _normalize_row_box_token(value: str) -> str:
    whitespace_tokens = {
        " ",
        "\t",
        "\n",
        r"\[InvisibleSpace]",
        r"\[InvisibleTimes]",
        r"\[NegativeMediumSpace]",
        r"\[NegativeThickSpace]",
        r"\[NegativeThinSpace]",
        r"\[NegativeVeryThinSpace]",
        r"\[NoBreak]",
        r"\[ThickSpace]",
        r"\[ThinSpace]",
        r"\[VeryThinSpace]",
    }
    if value in whitespace_tokens:
        return " "
    if value in _ESCAPED_TOKEN_MAP:
        return _ESCAPED_TOKEN_MAP[value]
    return value


def _make_division(numerator: Expr, denominator: Expr) -> Expr:
    if isinstance(numerator, Integer) and isinstance(denominator, Integer):
        return call("Rational", numerator, denominator)

    if isinstance(numerator, Integer) and numerator.value == 1:
        return call("Power", denominator, integer(-1))

    return call("Times", numerator, call("Power", denominator, integer(-1)))


def _has_true_option(arguments: Sequence[Expr], name: str) -> bool:
    for argument in arguments:
        if not isinstance(argument, Call):
            continue
        if not argument.has_head("Rule") and not argument.has_head("RuleDelayed"):
            continue
        if len(argument.arguments) != 2:
            continue
        option_name, option_value = argument.arguments
        if not isinstance(option_name, Symbol) or option_name.name != name:
            continue
        interpreted = _interpret_standard_form(option_value)
        if isinstance(interpreted, Symbol) and interpreted.name == "True":
            return True
    return False


@dataclass(frozen=True)
class _Token:
    kind: str
    text: str
    start: int
    end: int
    value: object | None = None


def _scan_string(text: str, start: int) -> tuple[_Token, int]:
    end = skip_wl_string(text, start)
    if end == len(text) and (not text or text[end - 1] != "\""):
        raise WolframSyntaxError("Unterminated Wolfram string literal.")
    raw = text[start:end]
    return _Token(kind="string", text=raw, start=start, end=end, value=parse_wl_string_literal(raw)), end


def _scan_number(text: str, start: int) -> tuple[_Token, int]:
    index = start
    while index < len(text) and text[index].isdigit():
        index += 1

    saw_digits = index > start
    if saw_digits and text.startswith("^^", index):
        return _scan_based_number(text, start, index)

    index, saw_decimal_dot, saw_digits = _scan_decimal_mantissa(text, start, allow_leading_dot=True)
    index, saw_precision = _scan_precision_marker(text, index)
    index, saw_magnitude = _scan_number_magnitude(text, index)

    token_text = text[start:index]
    if not token_text or token_text == "." or not saw_digits:
        raise WolframSyntaxError(f"Malformed Wolfram number near {text[start:start + 8]!r}.")

    if not saw_decimal_dot and not saw_precision and not saw_magnitude:
        return _Token(kind="integer", text=token_text, start=start, end=index, value=int(token_text)), index
    return _Token(kind="real", text=token_text, start=start, end=index, value=token_text), index


def _scan_based_number(text: str, start: int, base_end: int) -> tuple[_Token, int]:
    base = int(text[start:base_end])
    if base < 2 or base > 36:
        raise WolframSyntaxError("Wolfram base-number literals require a base between 2 and 36.")

    index = base_end + 2
    mantissa_start = index
    index, saw_base_dot, saw_digits = _scan_base_mantissa(text, index, base)
    if not saw_digits:
        raise WolframSyntaxError("Malformed Wolfram base-number literal.")
    if text.startswith("..", index):
        raise WolframSyntaxError("Malformed Wolfram base-number literal.")

    index, saw_precision = _scan_precision_marker(text, index)
    index, saw_magnitude = _scan_number_magnitude(text, index)

    token_text = text[start:index]
    if not saw_base_dot and not saw_precision and not saw_magnitude:
        digits = text[mantissa_start:index]
        return _Token(kind="integer", text=token_text, start=start, end=index, value=int(digits, base)), index
    return _Token(kind="real", text=token_text, start=start, end=index, value=token_text), index


def _scan_decimal_mantissa(text: str, start: int, *, allow_leading_dot: bool) -> tuple[int, bool, bool]:
    index = start
    saw_digits = False
    while index < len(text) and text[index].isdigit():
        saw_digits = True
        index += 1

    saw_dot = False
    if index < len(text) and text[index] == ".":
        if text.startswith("..", index):
            return index, saw_dot, saw_digits
        if index + 1 < len(text) and text[index + 1].isdigit():
            saw_dot = True
            index += 1
            while index < len(text) and text[index].isdigit():
                saw_digits = True
                index += 1
        elif saw_digits:
            saw_dot = True
            index += 1
        elif allow_leading_dot:
            raise WolframSyntaxError(f"Malformed Wolfram number near {text[start:start + 8]!r}.")

    return index, saw_dot, saw_digits


def _scan_precision_marker(text: str, index: int) -> tuple[int, bool]:
    if text.startswith("``", index):
        index += 2
        spec_end, _, saw_digits = _scan_decimal_mantissa(text, index, allow_leading_dot=True)
        if not saw_digits:
            raise WolframSyntaxError("Malformed Wolfram accuracy mark.")
        return spec_end, True

    if index < len(text) and text[index] == "`":
        index += 1
        spec_end, _, _ = _scan_decimal_mantissa(text, index, allow_leading_dot=True)
        return spec_end, True

    return index, False


def _scan_number_magnitude(text: str, index: int) -> tuple[int, bool]:
    if not text.startswith("*^", index):
        return index, False

    index += 2
    if index < len(text) and text[index] in "+-":
        index += 1
    exponent_start = index
    while index < len(text) and text[index].isdigit():
        index += 1
    if exponent_start == index:
        raise WolframSyntaxError("Malformed Wolfram numeric exponent.")
    if index < len(text) and text[index] == "." and not text.startswith("..", index):
        raise WolframSyntaxError("Malformed Wolfram numeric exponent.")
    return index, True


def _scan_base_mantissa(text: str, start: int, base: int) -> tuple[int, bool, bool]:
    index = start
    saw_dot = False
    saw_digits = False

    if index < len(text) and text[index] == ".":
        if index + 1 >= len(text) or _base_digit_value(text[index + 1]) is None:
            raise WolframSyntaxError("Malformed Wolfram base-number literal.")
        saw_dot = True
        index += 1

    while index < len(text):
        value = _base_digit_value(text[index])
        if value is not None:
            if value >= base:
                raise WolframSyntaxError(f"Malformed Wolfram base-{base} literal.")
            saw_digits = True
            index += 1
            continue
        if text[index] == "." and not saw_dot and not text.startswith("..", index):
            saw_dot = True
            index += 1
            continue
        break

    return index, saw_dot, saw_digits


def _base_digit_value(char: str) -> int | None:
    if "0" <= char <= "9":
        return ord(char) - ord("0")
    if "a" <= char <= "z":
        return ord(char) - ord("a") + 10
    if "A" <= char <= "Z":
        return ord(char) - ord("A") + 10
    return None


def _scan_percent_history(text: str, start: int) -> tuple[_Token, int]:
    index = start
    while index < len(text) and text[index] == "%":
        index += 1

    digits_start = index
    while index < len(text) and text[index].isdigit():
        index += 1

    token_text = text[start:index]
    if digits_start < index:
        return _Token(kind="percent", text=token_text, start=start, end=index, value=int(text[digits_start:index])), index
    return _Token(kind="percent", text=token_text, start=start, end=index, value=-(index - start)), index


def _is_symbol_start(char: str) -> bool:
    return char.isalpha() or char in {"$", "`"}


def _is_symbol_continue(char: str) -> bool:
    return char.isalnum() or char in {"$", "`"}


def _scan_symbol_with_escapes(text: str, start: int) -> tuple[_Token, int] | None:
    """Scan a symbol that may include ``\\:XXXX`` and similar character escapes.

    Wolfram folds simple character escapes outside string literals into the surrounding
    identifier. ``\\:ff0d`` standing alone becomes a one-character symbol; ``x\\:00b2``
    becomes the two-character symbol ``x²``. Returns ``None`` when the position does not
    begin a symbol token (so the tokenizer can try later branches).
    """
    if start >= len(text):
        return None
    first = text[start]
    chars: list[str] = []
    index = start
    if first == "\\":
        decoded = _scan_simple_character_escape(text, index)
        if decoded is None:
            return None
        chars.append(decoded[0])
        index = decoded[1]
    elif _is_symbol_start(first):
        chars.append(first)
        index += 1
    else:
        return None

    while index < len(text):
        char = text[index]
        if char == "\\":
            decoded = _scan_simple_character_escape(text, index)
            if decoded is not None:
                chars.append(decoded[0])
                index = decoded[1]
                continue
            break
        if _is_symbol_continue(char):
            chars.append(char)
            index += 1
            continue
        break

    name = "".join(chars)
    return _Token(kind="symbol", text=name, start=start, end=index, value=name), index


_MULTI_TOKENS = (
    "===",
    "=!=",
    "___",
    "^:=",
    "//=",
    "__",
    "##",
    "...",
    "//.",
    "//@",
    "@@@",
    ">>>",
    "<->",
    "..",
    "[[",
    "~~",
    "<>",
    "<|",
    "|>",
    "|->",
    "@*",
    "/*",
    ":=",
    "::",
    ":>",
    "->",
    "=.",
    "^=",
    "+=",
    "-=",
    "*=",
    "/=",
    "/:",
    "/;",
    "//",
    "/@",
    "/.",
    "@@",
    "++",
    "--",
    "**",
    "<<",
    ">>",
    "??",
    "<=",
    ">=",
    "==",
    "!=",
    "&&",
    "||",
    ";;",
)


_CHAINABLE_COMPARISON_HEADS = {
    "Equal",
    "Greater",
    "GreaterEqual",
    "Less",
    "LessEqual",
    "SameQ",
    "Unequal",
    "UnsameQ",
}


def _scan_escaped_token(text: str, start: int) -> tuple[_Token, int] | None:
    if not text.startswith(r"\[", start):
        return None

    end = text.find("]", start + 2)
    if end < 0:
        raise WolframSyntaxError(f"Unterminated Wolfram escaped token at offset {start}.")

    raw = text[start:end + 1]
    normalized = _ESCAPED_TOKEN_MAP.get(raw)
    if normalized is not None:
        return _Token(kind="operator", text=normalized, start=start, end=end + 1, value=normalized), end + 1

    alias = _ESCAPED_SYMBOL_ALIASES.get(raw)
    if alias is not None:
        return _Token(kind="symbol", text=raw, start=start, end=end + 1, value=alias), end + 1

    if raw in _ESCAPED_INFIX_OPERATOR_HEADS:
        return _Token(kind="operator", text=raw, start=start, end=end + 1, value=raw), end + 1

    return _Token(kind="symbol", text=raw, start=start, end=end + 1, value=raw), end + 1


_HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
_OCTAL_DIGITS = frozenset("01234567")


def _scan_simple_character_escape(text: str, start: int) -> tuple[str, int] | None:
    """Decode ``\\:XXXX`` / ``\\.XX`` / ``\\OOO`` / ``\\|XXXXXX`` to a Unicode character.

    Returns the decoded character and the index past the escape, or ``None`` if no such
    escape begins at ``start``. These four escape forms are recognized everywhere Wolfram
    accepts them, including outside string literals where Wolfram folds them into the
    surrounding identifier or operator.
    """
    if start >= len(text) or text[start] != "\\":
        return None
    if start + 1 >= len(text):
        return None
    marker = text[start + 1]
    if marker == ":":
        if start + 6 > len(text):
            return None
        hex_part = text[start + 2 : start + 6]
        if len(hex_part) == 4 and all(c in _HEX_DIGITS for c in hex_part):
            return chr(int(hex_part, 16)), start + 6
        return None
    if marker == ".":
        if start + 4 > len(text):
            return None
        hex_part = text[start + 2 : start + 4]
        if len(hex_part) == 2 and all(c in _HEX_DIGITS for c in hex_part):
            return chr(int(hex_part, 16)), start + 4
        return None
    if marker == "|":
        if start + 8 > len(text):
            return None
        hex_part = text[start + 2 : start + 8]
        if len(hex_part) == 6 and all(c in _HEX_DIGITS for c in hex_part):
            try:
                return chr(int(hex_part, 16)), start + 8
            except ValueError:
                return None
        return None
    if marker in _OCTAL_DIGITS:
        if start + 4 > len(text):
            return None
        oct_part = text[start + 1 : start + 4]
        if len(oct_part) == 3 and all(c in _OCTAL_DIGITS for c in oct_part):
            return chr(int(oct_part, 8)), start + 4
        return None
    return None


_INLINE_BOX_OPEN = "\\!\\("
_INLINE_BOX_BARE_OPEN = "\\("
_INLINE_BOX_CLOSE = "\\)"


_INLINE_BOX_FORM_PREFIXES = (
    "TraditionalForm",
    "StandardForm",
    "DisplayForm",
    "InputForm",
    "OutputForm",
    "FullForm",
    "MathMLForm",
    "TeXForm",
)


def _interpret_inline_box_content(inner: str) -> Expr:
    """Best-effort interpretation of the contents of a ``\\!\\(...\\)`` escape.

    Wolfram folds the typeset content back into the surrounding parse tree. Tungsten
    does not implement full box-language interpretation, but for the common shapes seen
    in real packages the inner text is a normal Wolfram expression — sometimes preceded
    by a form selector such as ``TraditionalForm\\``. This helper strips a recognized
    form prefix and tries to parse the remainder as an ordinary expression. On failure
    the construct surfaces as the inert head ``InlineBoxEscape[...]`` so the surrounding
    parse keeps going.
    """
    body = inner
    if body.startswith("\\*"):
        body = body[2:]
    body = body.strip()
    for form_name in _INLINE_BOX_FORM_PREFIXES:
        for separator in ("\\`", "`"):
            prefix = form_name + separator
            if body.startswith(prefix):
                body = body[len(prefix):]
                break
        else:
            continue
        break
    body = body.strip()
    if not body:
        return symbol("Null")
    try:
        return _Parser(body).parse()
    except WolframSyntaxError:
        return call("InlineBoxEscape", string(inner))


def _find_bare_box_end(text: str, start: int) -> int | None:
    """Return the index just past the matching ``\\)`` for a bare ``\\(`` at ``start``.

    Wolfram allows raw box syntax inline as ``\\(...\\)`` (without the leading ``\\!``),
    typically inside ``InputAliases`` and similar option specs. Returns ``None`` if no
    such construct begins at ``start``. Raises ``WolframSyntaxError`` if the construct
    is unterminated.
    """
    if not text.startswith(_INLINE_BOX_BARE_OPEN, start):
        return None
    index = start + len(_INLINE_BOX_BARE_OPEN)
    depth = 1
    n = len(text)
    while index < n:
        if text[index] == '"':
            index = skip_wl_string(text, index)
            continue
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue
        if text.startswith(_INLINE_BOX_BARE_OPEN, index):
            depth += 1
            index += len(_INLINE_BOX_BARE_OPEN)
            continue
        if text.startswith(_INLINE_BOX_CLOSE, index):
            depth -= 1
            index += len(_INLINE_BOX_CLOSE)
            if depth == 0:
                return index
            continue
        index += 1
    raise WolframSyntaxError(f"Unterminated bare box escape at offset {start}.")


def _interpret_bare_box_content(inner: str) -> Expr:
    """Best-effort interpretation of ``\\(...\\)`` raw box content.

    The Wolfram kernel turns this into a ``RowBox`` of textual tokens. Tungsten just
    surfaces the raw inner text via the inert head ``BareBoxEscape[...]`` so the
    surrounding parse can continue without trying to interpret the box language.
    """
    return call("BareBoxEscape", string(inner))


def _find_inline_box_end(text: str, start: int) -> int | None:
    """Return the index just past the matching ``\\)`` for the ``\\!\\(`` at ``start``.

    Returns ``None`` if no inline-box escape begins at ``start``. Raises
    ``WolframSyntaxError`` for an unterminated construct.
    """
    if not text.startswith(_INLINE_BOX_OPEN, start):
        return None
    index = start + len(_INLINE_BOX_OPEN)
    depth = 1
    n = len(text)
    while index < n:
        if text[index] == '"':
            index = skip_wl_string(text, index)
            continue
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue
        if text.startswith(_INLINE_BOX_BARE_OPEN, index):
            depth += 1
            index += len(_INLINE_BOX_BARE_OPEN)
            continue
        if text.startswith(_INLINE_BOX_CLOSE, index):
            depth -= 1
            index += len(_INLINE_BOX_CLOSE)
            if depth == 0:
                return index
            continue
        index += 1
    raise WolframSyntaxError(f"Unterminated Wolfram inline box escape at offset {start}.")


def _tokenize(text: str) -> list[_Token]:
    tokens: list[_Token] = []
    index = 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        if text[index] == "\\":
            continuation_end = _line_continuation_end(text, index)
            if continuation_end is not None:
                index = continuation_end
                continue
            inline_box_end = _find_inline_box_end(text, index)
            if inline_box_end is not None:
                inner = text[index + len(_INLINE_BOX_OPEN) : inline_box_end - len(_INLINE_BOX_CLOSE)]
                expr = _interpret_inline_box_content(inner)
                tokens.append(_Token(
                    kind="inline_box",
                    text=text[index:inline_box_end],
                    start=index,
                    end=inline_box_end,
                    value=expr,
                ))
                index = inline_box_end
                continue
            bare_box_end = _find_bare_box_end(text, index)
            if bare_box_end is not None:
                inner = text[index + len(_INLINE_BOX_BARE_OPEN) : bare_box_end - len(_INLINE_BOX_CLOSE)]
                expr = _interpret_bare_box_content(inner)
                tokens.append(_Token(
                    kind="inline_box",
                    text=text[index:bare_box_end],
                    start=index,
                    end=bare_box_end,
                    value=expr,
                ))
                index = bare_box_end
                continue
        if text.startswith("(*", index):
            index = skip_wl_comment(text, index)
            continue
        if text[index] == "\"":
            token, index = _scan_string(text, index)
            tokens.append(token)
            continue
        escaped_token = _scan_escaped_token(text, index)
        if escaped_token is not None:
            token, index = escaped_token
            tokens.append(token)
            continue
        symbol_token = _scan_symbol_with_escapes(text, index)
        if symbol_token is not None:
            token, index = symbol_token
            tokens.append(token)
            continue
        if text[index].isdigit() or (text[index] == "." and index + 1 < len(text) and text[index + 1].isdigit()):
            token, index = _scan_number(text, index)
            tokens.append(token)
            continue
        if text[index] == "%":
            token, index = _scan_percent_history(text, index)
            tokens.append(token)
            continue

        matched = False
        for candidate in _MULTI_TOKENS:
            if text.startswith(candidate, index):
                tokens.append(_Token(kind="operator", text=candidate, start=index, end=index + len(candidate), value=candidate))
                index += len(candidate)
                matched = True
                break
        if matched:
            continue

        char = text[index]
        if char in "[]{}(),.;:+-*/^!@<>_|&#=?~'":
            tokens.append(_Token(kind="operator", text=char, start=index, end=index + 1, value=char))
            index += 1
            continue

        raise WolframSyntaxError(f"Unexpected Wolfram syntax character {char!r} at offset {index}.")

    tokens.append(_Token(kind="eof", text="", start=len(text), end=len(text)))
    return tokens


def _line_continuation_end(text: str, start: int) -> int | None:
    index = start + 1
    while index < len(text) and text[index] in {" ", "\t"}:
        index += 1
    if index < len(text) and text[index] == "\r":
        index += 1
        if index < len(text) and text[index] == "\n":
            index += 1
        return index
    if index < len(text) and text[index] == "\n":
        return index + 1
    return None


class _Parser:
    _PART_BP = 190
    _CALL_BP = 190
    _PATTERN_BP = 185
    _PATTERN_TEST_BP = 184
    _MESSAGE_NAME_BP = 183
    _POSTFIX_UNARY_BP = 175
    _INFIX_FUNCTION_BP = 165
    _POWER_BP = 160
    _TIMES_BP = 140
    _NONCOMMUTATIVE_TIMES_BP = 145
    _DIAMOND_BP = 144
    _CIRCLE_TIMES_BP = 142
    _CIRCLE_PLUS_BP = 125
    _PLUS_BP = 120
    _COMPARE_BP = 100
    _AND_BP = 80
    _OR_BP = 70
    _ALTERNATIVES_BP = 65
    _STRING_EXPRESSION_BP = 64
    _NAMED_PATTERN_BP = 63
    _NAMED_PATTERN_LEFT_BP = 180
    _CONDITION_BP = 62
    _RULE_BP = 60
    _TWO_WAY_RULE_BP = 61
    _REPLACE_BP = 50
    _MAP_BP = 45
    _APPLY_BP = 44
    _COMPOSITION_BP = 43
    _ASSIGNMENT_BP = 40
    _PUT_BP = 35
    _AT_BP = 180
    _POSTFIX_BP = 30
    _SEMICOLON_BP = 20
    _FUNCTION_BP = 10
    _SPAN_BP = 110
    _PREFIX_BP = 150
    _ESCAPED_INFIX_BINDING_POWERS = {
        "CirclePlus": _CIRCLE_PLUS_BP,
        "CircleTimes": _CIRCLE_TIMES_BP,
        "Diamond": _DIAMOND_BP,
    }

    def __init__(self, text: str) -> None:
        self.text = text
        self.tokens = _tokenize(text)
        self.index = 0
        self._grouped_expr_ids: set[int] = set()
        self._operator_expr_heads: dict[int, str] = {}
        self._completed_span_ids: set[int] = set()

    def parse(self) -> Expr:
        if self._peek().kind == "eof":
            return symbol("Null")
        expr = self._parse_expression(0, terminators={"eof"})
        self._expect("eof")
        return expr

    def _peek(self) -> _Token:
        return self.tokens[self.index]

    def _token_terminates(self, token: _Token, terminators: set[str]) -> bool:
        if token.kind == "eof":
            return True
        if token.kind in terminators:
            return True
        # Only operator tokens terminate by text. Symbol tokens that happen to share
        # a name with a kind sentinel (notably ``eof``) must remain ordinary symbols.
        return token.kind == "operator" and token.text in terminators

    def _consume(self) -> _Token:
        token = self.tokens[self.index]
        self.index += 1
        return token

    def _match(self, *values: str) -> _Token | None:
        token = self._peek()
        if token.text in values or token.kind in values:
            self.index += 1
            return token
        return None

    def _expect(self, value: str) -> _Token:
        token = self._peek()
        if token.text == value or token.kind == value:
            self.index += 1
            return token
        raise WolframSyntaxError(f"Expected {value!r}, found {token.text!r} at offset {token.start}.")

    def _parse_expression(self, min_bp: int, terminators: set[str]) -> Expr:
        token = self._peek()
        if self._token_terminates(token, terminators):
            raise WolframSyntaxError(f"Unexpected {token.text!r} at offset {token.start}.")

        left = self._parse_prefix(terminators)

        while True:
            token = self._peek()
            if self._token_terminates(token, terminators):
                break

            if token.text in {"_", "__", "___"}:
                if self._PATTERN_BP < min_bp:
                    break
                if not self._can_attach_named_blank(left, token):
                    # Wolfram requires the symbol and underscore to be adjacent. With
                    # whitespace between them, the underscore introduces a fresh blank
                    # that combines via implicit Times.
                    if self._TIMES_BP < min_bp:
                        break
                    blank = self._parse_prefix_blank_at_pattern_position(token)
                    # Eagerly absorb a trailing optional-dot so ``_?P _.`` parses to
                    # ``Times[PatternTest[Blank[], P], Optional[Blank[]]]`` instead of
                    # leaving a stray Dot fragment.
                    if (
                        self._peek().text == "."
                        and self._is_optional_dot_candidate(blank)
                        and self._is_postfix_optional_dot_context(terminators)
                    ):
                        self._consume()
                        blank = call("Optional", blank)
                    left = self._make_implicit_times(left, blank)
                    continue
                left = self._parse_postfix_pattern(left)
                continue

            if token.text in {"..", "..."}:
                if self._PATTERN_BP < min_bp:
                    break
                self._consume()
                left = call("RepeatedNull" if token.text == "..." else "Repeated", left)
                continue

            if token.text == "?":
                if self._PATTERN_TEST_BP < min_bp:
                    break
                self._consume()
                test = self._parse_expression(
                    self._PATTERN_TEST_BP + 1,
                    terminators | {"eof", ",", "]", "]]", "}", "|>", ")"},
                )
                left = call("PatternTest", left, test)
                continue

            if token.text == "." and self._is_optional_dot_candidate(left) and self._is_postfix_optional_dot_context(terminators):
                if self._PATTERN_BP < min_bp:
                    break
                self._consume()
                left = call("Optional", left)
                continue

            if token.text == "!":
                if self._POSTFIX_UNARY_BP < min_bp:
                    break
                self._consume()
                if self._match("!") is not None:
                    left = call("Factorial2", left)
                else:
                    left = call("Factorial", left)
                continue

            if token.text == "'":
                if self._POSTFIX_UNARY_BP < min_bp:
                    break
                prime_count = 0
                while self._match("'") is not None:
                    prime_count += 1
                left = Call(head_expr=call("Derivative", integer(prime_count)), arguments=(left,))
                continue

            if token.text in {"++", "--"}:
                if self._POSTFIX_UNARY_BP < min_bp:
                    break
                self._consume()
                left = call("Increment" if token.text == "++" else "Decrement", left)
                continue

            if token.text == "=.":
                if self._POSTFIX_UNARY_BP < min_bp:
                    break
                self._consume()
                if self._is_tag_set_prefix(left):
                    left = call("TagUnset", left.arguments[0], left.arguments[1])
                else:
                    left = call("Unset", left)
                continue

            if token.text == "[":
                if self._CALL_BP < min_bp:
                    break
                self._consume()
                arguments = self._parse_sequence("]")
                self._expect("]")
                left = Call(head_expr=left, arguments=tuple(arguments))
                continue

            if token.text == "[[":
                if self._PART_BP < min_bp:
                    break
                self._consume()
                specs = self._parse_sequence("]")
                self._expect("]")
                self._expect("]")
                left = call("Part", left, *specs)
                continue

            if token.text == ";;":
                if self._SPAN_BP < min_bp:
                    break
                if id(left) in self._completed_span_ids and id(left) not in self._grouped_expr_ids:
                    # ``a ;; b ;; c`` is a single 3-part Span. Once that Span is
                    # complete, any further ``;;`` starts a fresh prefix-Span and
                    # combines via implicit Times, matching Wolfram's parse tree.
                    if self._TIMES_BP < min_bp:
                        break
                    self._consume()
                    next_span = self._finish_span(integer(1), terminators)
                    left = self._make_implicit_times(left, next_span)
                    continue
                left = self._parse_infix_span(left, min_bp, terminators)
                continue

            if token.text == "&":
                if self._FUNCTION_BP < min_bp:
                    break
                self._consume()
                left = call("Function", left)
                continue

            if token.text == "~":
                if self._INFIX_FUNCTION_BP < min_bp:
                    break
                left = self._parse_infix_function_apply(left, terminators)
                continue

            if self._starts_primary(token):
                if self._TIMES_BP < min_bp:
                    break
                right = self._parse_expression(self._TIMES_BP + 1, terminators)
                left = self._make_flat_parser_operator_call("Times", left, right)
                continue

            handled = self._parse_infix_operator(left, min_bp, terminators)
            if handled is None:
                break
            left = handled

        if self._is_tag_set_prefix(left):
            raise WolframSyntaxError("Expected '=', ':=', or '=.' after '/:'.")
        return left

    def _parse_prefix(self, terminators: set[str]) -> Expr:
        token = self._consume()

        if token.kind == "integer":
            return integer(int(token.value))

        if token.kind == "real":
            return real(str(token.value))

        if token.kind == "string":
            return string(str(token.value))

        if token.kind == "inline_box":
            return token.value if isinstance(token.value, Expr) else symbol("Null")

        if token.kind == "percent":
            return call("Out", integer(int(token.value)))

        if token.kind == "symbol":
            return symbol(str(token.value))

        if token.text == "(":
            expr = self._parse_expression(0, terminators={")"})
            self._expect(")")
            self._grouped_expr_ids.add(id(expr))
            return expr

        if token.text == "{":
            items = self._parse_sequence("}")
            self._expect("}")
            return list_expr(*items)

        if token.text == "<|":
            items = self._parse_sequence("|>")
            self._expect("|>")
            return call("Association", *items)

        if token.text in {"__", "___"}:
            return self._parse_prefix_sequence_blank("BlankSequence" if token.text == "__" else "BlankNullSequence")

        if token.text == "_":
            return self._parse_prefix_blank()

        if token.text == "#":
            return self._parse_prefix_slot()

        if token.text == "##":
            return self._parse_prefix_slot_sequence()

        if token.text in {"?", "??"}:
            name = self._parse_file_name_literal("information")
            return call("Information", name, call("Rule", symbol("LongForm"), symbol("True" if token.text == "??" else "False")))

        if token.text == "<<":
            return call("Get", self._parse_file_name_literal("Get"))

        if token.text in {"++", "--"}:
            head_name = "PreIncrement" if token.text == "++" else "PreDecrement"
            return call(head_name, self._parse_expression(self._POSTFIX_UNARY_BP, terminators))

        if token.text == "+":
            operand = self._parse_expression(self._PREFIX_BP, terminators)
            result = call("Plus", operand)
            self._operator_expr_heads[id(result)] = "Plus"
            return result

        if token.text == "-":
            operand = self._parse_expression(self._PREFIX_BP, terminators)
            if isinstance(operand, Integer):
                return integer(-operand.value)
            if isinstance(operand, Real):
                if operand.text.startswith("-"):
                    return real(operand.text[1:])
                return real(f"-{operand.text}")
            return call("Times", integer(-1), operand)

        if token.text == "!":
            return call("Not", self._parse_expression(self._PREFIX_BP, terminators))

        if token.text == ";;":
            return self._parse_prefix_span(terminators)

        raise WolframSyntaxError(f"Unexpected token {token.text!r} at offset {token.start}.")

    def _parse_sequence(self, end_token: str) -> list[Expr]:
        items: list[Expr] = []
        if self._peek().text == end_token:
            return items

        while True:
            token = self._peek()
            # Wolfram emits a Syntax::com warning and substitutes Null for an absent
            # comma-separated argument (``f[a,,b]``, ``f[a, b,]``). Tungsten matches the
            # resulting parse tree without re-emitting the warning.
            if token.text in {",", end_token}:
                items.append(symbol("Null"))
            else:
                items.append(self._parse_expression(0, terminators={",", end_token}))
            if self._match(",") is None:
                break
        return items

    def _starts_primary(self, token: _Token) -> bool:
        return token.kind in {"integer", "real", "string", "symbol", "percent", "inline_box"} or token.text in {
            "(",
            "{",
            "<|",
            "#",
            "##",
            "_",
            "__",
            "___",
            "<<",
        }

    def _can_start_expression(self, token: _Token) -> bool:
        # Tokens that ``_parse_prefix`` knows how to consume as the head of an expression.
        if self._starts_primary(token):
            return True
        return token.text in {"?", "??", "++", "--", "+", "-", "!", ";;"}

    def _parse_prefix_blank(self) -> Expr:
        blank_token = self.tokens[self.index - 1]
        next_token = self._peek()
        if next_token.kind == "symbol" and blank_token.end == next_token.start:
            return call("Blank", symbol(str(self._consume().value)))
        return call("Blank")

    def _parse_prefix_sequence_blank(self, head_name: str) -> Expr:
        blank_token = self.tokens[self.index - 1]
        next_token = self._peek()
        if next_token.kind == "symbol" and blank_token.end == next_token.start:
            return call(head_name, symbol(str(self._consume().value)))
        return call(head_name)

    def _can_attach_named_blank(self, left: Expr, blank_token: _Token) -> bool:
        if not isinstance(left, Symbol):
            return False
        if self.index == 0:
            return False
        previous_token = self.tokens[self.index - 1]
        return previous_token.end == blank_token.start

    def _parse_prefix_blank_at_pattern_position(self, blank_token: _Token) -> Expr:
        # The underscore-family token has not yet been consumed when this is called.
        consumed = self._consume()
        assert consumed is blank_token
        if blank_token.text == "_":
            return self._parse_prefix_blank()
        head_name = "BlankSequence" if blank_token.text == "__" else "BlankNullSequence"
        return self._parse_prefix_sequence_blank(head_name)

    def _make_implicit_times(self, left: Expr, right: Expr) -> Expr:
        return self._make_flat_parser_operator_call("Times", left, right)

    def _combine_colon(self, left: Expr, right: Expr) -> Expr:
        # Wolfram's ``:`` is right-associative when parsed naively but interprets each
        # contiguous chain ``a : b : c : d : ...`` as ``Optional[Pattern[a, b], <recurse on
        # rest>]`` with the leftmost two elements pairing into a ``Pattern`` if the very
        # first element is a symbol. ``right`` here is the already-parsed right-associative
        # tail produced by Pratt parsing, so we walk it and re-fold.
        chain = self._flatten_colon_chain(left) + self._flatten_colon_chain(right)
        return self._fold_colon_chain(chain)

    def _flatten_colon_chain(self, expr: Expr) -> list[Expr]:
        if (
            isinstance(expr, Call)
            and (expr.has_head("Pattern") or expr.has_head("Optional"))
            and len(expr.arguments) == 2
            and self._operator_expr_heads.get(id(expr)) == "Colon"
            and id(expr) not in self._grouped_expr_ids
        ):
            return [*self._flatten_colon_chain(expr.arguments[0]), *self._flatten_colon_chain(expr.arguments[1])]
        return [expr]

    def _fold_colon_chain(self, chain: list[Expr]) -> Expr:
        assert len(chain) >= 1
        if len(chain) == 1:
            return chain[0]
        head, second, *rest = chain
        if isinstance(head, Symbol):
            paired: Expr = call("Pattern", head, second)
        else:
            paired = call("Optional", head, second)
        self._operator_expr_heads[id(paired)] = "Colon"
        if not rest:
            return paired
        tail = self._fold_colon_chain([second_or_more for second_or_more in rest])
        wrapper = call("Optional", paired, tail) if isinstance(head, Symbol) else paired
        if not isinstance(head, Symbol):
            wrapper = call("Optional", paired, tail)
        self._operator_expr_heads[id(wrapper)] = "Colon"
        return wrapper

    def _make_compound_expression(self, left: Expr, right: Expr) -> Call:
        # ``CompoundExpression`` is normally parse-stage flat, but parentheses must act
        # as a structural barrier. A grouped right-hand-side stays nested.
        arguments: list[Expr] = []
        if (
            isinstance(left, Call)
            and left.has_head("CompoundExpression")
            and id(left) not in self._grouped_expr_ids
        ):
            arguments.extend(left.arguments)
        else:
            arguments.append(left)
        if (
            isinstance(right, Call)
            and right.has_head("CompoundExpression")
            and id(right) not in self._grouped_expr_ids
        ):
            arguments.extend(right.arguments)
        else:
            arguments.append(right)
        result = Call(head_expr=symbol("CompoundExpression"), arguments=tuple(arguments))
        self._operator_expr_heads[id(result)] = "CompoundExpression"
        return result

    def _parse_prefix_slot(self) -> Expr:
        slot_token = self.tokens[self.index - 1]
        next_token = self._peek()
        adjacent = slot_token.end == next_token.start
        if next_token.kind == "integer":
            return call("Slot", integer(int(self._consume().value)))
        split_slot = self._split_slot_index_before_dot(next_token)
        if split_slot is not None:
            return call("Slot", integer(split_slot))
        if adjacent and next_token.kind == "symbol":
            return call("Slot", string(str(self._consume().value)))
        if adjacent and next_token.kind == "string":
            return call("Slot", string(str(self._consume().value)))
        return call("Slot", integer(1))

    def _parse_prefix_slot_sequence(self) -> Expr:
        next_token = self._peek()
        if next_token.kind == "integer":
            return call("SlotSequence", integer(int(self._consume().value)))
        split_slot = self._split_slot_index_before_dot(next_token)
        if split_slot is not None:
            return call("SlotSequence", integer(split_slot))
        return call("SlotSequence", integer(1))

    def _split_slot_index_before_dot(self, token: _Token) -> int | None:
        if token.kind != "real" or not re.fullmatch(r"\d+\.", token.text):
            return None
        digits = token.text[:-1]
        self.tokens[self.index] = _Token(
            kind="operator",
            text=".",
            start=token.end - 1,
            end=token.end,
            value=".",
        )
        return int(digits)

    def _parse_file_name_literal(self, context: str) -> String:
        token = self._peek()
        if token.kind == "symbol":
            self._consume()
            return string(str(token.value))
        if token.kind == "string":
            self._consume()
            return string(str(token.value))
        raise WolframSyntaxError(f"Expected {context} name at offset {token.start}.")

    def _parse_message_tag(self) -> String:
        token = self._peek()
        if token.kind == "symbol":
            self._consume()
            return string(str(token.value))
        if token.kind == "string":
            self._consume()
            return string(str(token.value))
        raise WolframSyntaxError(f"Expected message tag at offset {token.start}.")

    def _parse_infix_function_apply(self, left: Expr, terminators: set[str]) -> Expr:
        self._expect("~")
        operator = self._parse_expression(0, terminators | {"~"})
        self._expect("~")
        right = self._parse_expression(
            self._INFIX_FUNCTION_BP + 1,
            terminators | {"eof", ",", "]", "]]", "}", "|>", ")"},
        )
        return Call(head_expr=operator, arguments=(left, right))

    @staticmethod
    def _is_tag_set_prefix(expr: Expr) -> TypeGuard[Call]:
        return isinstance(expr, Call) and expr.has_head("TagSetPrefix") and len(expr.arguments) == 2

    def _is_postfix_optional_dot_context(self, terminators: set[str]) -> bool:
        dot_token = self.tokens[self.index]
        next_token = self.tokens[self.index + 1]
        return (
            self._token_terminates(next_token, terminators)
            or next_token.text in {
                ",",
                "]",
                "]]",
                "}",
                "|>",
                ")",
                ";",
                "+",
                "-",
                "*",
                "/",
                "**",
                "^",
                "&&",
                "||",
                "|",
                "~~",
                "/;",
                "->",
                ":>",
                "<->",
                "/.",
                "//.",
                "/@",
                "//@",
                "@@",
                "@@@",
                "==",
                "!=",
                "===",
                "=!=",
                "<",
                "<=",
                ">",
                ">=",
                "=",
                ":=",
            }
            or (dot_token.end < next_token.start and self._starts_primary(next_token))
        )

    @staticmethod
    def _is_optional_dot_candidate(expr: Expr) -> bool:
        if not isinstance(expr, Call) or not isinstance(expr.head_expr, Symbol):
            return False
        if expr.head_expr.name == "Blank" and len(expr.arguments) == 0:
            return True
        if expr.head_expr.name != "Pattern" or len(expr.arguments) != 2 or not isinstance(expr.arguments[0], Symbol):
            return False
        inner = expr.arguments[1]
        return (
            isinstance(inner, Call)
            and isinstance(inner.head_expr, Symbol)
            and inner.head_expr.name == "Blank"
            and len(inner.arguments) == 0
        )

    def _parse_postfix_pattern(self, left: Expr) -> Expr:
        token = self._consume()
        if token.text in {"__", "___"}:
            if not isinstance(left, Symbol):
                raise WolframSyntaxError(
                    f"Named sequence pattern shorthand requires a symbol before {token.text!r} at offset {token.start}."
                )
            blank = self._parse_prefix_sequence_blank(
                "BlankSequence" if token.text == "__" else "BlankNullSequence"
            )
            return call("Pattern", left, blank)
        if not isinstance(left, Symbol):
            raise WolframSyntaxError(
                f"Named pattern shorthand requires a symbol before '_' at offset {token.start}."
            )
        blank = self._parse_prefix_blank()
        return call("Pattern", left, blank)

    def _parse_infix_span(self, left: Expr, min_bp: int, terminators: set[str]) -> Expr:
        del min_bp
        self._expect(";;")
        return self._finish_span(left, terminators)

    def _parse_prefix_span(self, terminators: set[str]) -> Expr:
        return self._finish_span(integer(1), terminators)

    def _finish_span(self, start: Expr, terminators: set[str]) -> Expr:
        # The first ``;;`` has already been consumed. The grammar accepts ``a ;; b``,
        # ``a ;; b ;; c``, ``a ;; ;; c`` (``All`` middle), ``a ;;`` (``All`` end), and
        # ``a ;; ;;`` (which Wolfram parses as two spans multiplied: only consume a
        # second ``;;`` as the step separator if there is an actual step operand to parse
        # after it).
        end = self._parse_span_argument(default=symbol("All"), terminators=terminators)
        if self._peek().text == ";;" and self._step_separator_followed_by_operand():
            self._consume()
            step = self._parse_span_argument(default=integer(1), terminators=terminators)
            result = call("Span", start, end, step)
        else:
            result = call("Span", start, end)
        self._completed_span_ids.add(id(result))
        return result

    def _step_separator_followed_by_operand(self) -> bool:
        if self.index + 1 >= len(self.tokens):
            return False
        following = self.tokens[self.index + 1]
        if following.kind == "eof":
            return False
        return self._can_start_expression(following)

    def _parse_span_argument(self, *, default: Expr, terminators: set[str]) -> Expr:
        token = self._peek()
        if (
            self._token_terminates(token, terminators)
            or (token.kind == "operator" and token.text in {",", "]", "]]", "}", "|>", ";;", ";"})
        ):
            return default
        return self._parse_expression(self._SPAN_BP + 1, terminators | {",", "]", "]]", "}", "|>"})

    def _parse_infix_operator(self, left: Expr, min_bp: int, terminators: set[str]) -> Expr | None:
        token = self._peek()
        text = token.text

        if text == "::":
            if self._MESSAGE_NAME_BP < min_bp:
                return None
            self._consume()
            tag = self._parse_message_tag()
            if isinstance(left, Call) and left.has_head("MessageName") and len(left.arguments) >= 2:
                return call("MessageName", *left.arguments, tag)
            return call("MessageName", left, tag)

        if text in {">>", ">>>"}:
            if self._PUT_BP < min_bp:
                return None
            self._consume()
            file_name = self._parse_file_name_literal("Put")
            return call("PutAppend" if text == ">>>" else "Put", left, file_name)

        if text == "/:":
            if self._ASSIGNMENT_BP < min_bp:
                return None
            self._consume()
            tagged_lhs = self._parse_expression(
                self._ASSIGNMENT_BP + 1,
                terminators=terminators | {"eof", ",", "]", "]]", "}", "|>", ")", "=."},
            )
            return call("TagSetPrefix", left, tagged_lhs)

        if text == ";":
            if self._SEMICOLON_BP < min_bp:
                return None
            self._consume()
            next_token = self._peek()
            if (
                self._token_terminates(next_token, terminators)
                or not self._can_start_expression(next_token)
            ):
                return self._make_compound_expression(left, symbol("Null"))
            right = self._parse_expression(
                self._SEMICOLON_BP + 1,
                terminators=terminators | {"eof", ",", "]", "]]", "}", "|>", ")"},
            )
            return self._make_compound_expression(left, right)

        if text == "=" and self.index + 1 < len(self.tokens) and self.tokens[self.index + 1].text == ".":
            if self._ASSIGNMENT_BP < min_bp:
                return None
            self._consume()
            self._consume()
            if self._is_tag_set_prefix(left):
                return call("TagUnset", left.arguments[0], left.arguments[1])
            return call("Unset", left)

        binary_specs: dict[str, tuple[int, int, str | None]] = {
            "^": (self._POWER_BP, self._POWER_BP, "Power"),
            "**": (self._NONCOMMUTATIVE_TIMES_BP, self._NONCOMMUTATIVE_TIMES_BP + 1, "NonCommutativeMultiply"),
            "*": (self._TIMES_BP, self._TIMES_BP + 1, "Times"),
            "/": (self._TIMES_BP, self._TIMES_BP + 1, None),
            "+": (self._PLUS_BP, self._PLUS_BP + 1, "Plus"),
            "-": (self._PLUS_BP, self._PLUS_BP + 1, None),
            "<>": (self._PLUS_BP, self._PLUS_BP + 1, "StringJoin"),
            "==": (self._COMPARE_BP, self._COMPARE_BP, "Equal"),
            "===": (self._COMPARE_BP, self._COMPARE_BP, "SameQ"),
            "!=": (self._COMPARE_BP, self._COMPARE_BP, "Unequal"),
            "=!=": (self._COMPARE_BP, self._COMPARE_BP, "UnsameQ"),
            "<": (self._COMPARE_BP, self._COMPARE_BP, "Less"),
            "<=": (self._COMPARE_BP, self._COMPARE_BP, "LessEqual"),
            ">": (self._COMPARE_BP, self._COMPARE_BP, "Greater"),
            ">=": (self._COMPARE_BP, self._COMPARE_BP, "GreaterEqual"),
            "&&": (self._AND_BP, self._AND_BP + 1, "And"),
            "||": (self._OR_BP, self._OR_BP + 1, "Or"),
            "|": (self._ALTERNATIVES_BP, self._ALTERNATIVES_BP + 1, "Alternatives"),
            "~~": (self._STRING_EXPRESSION_BP, self._STRING_EXPRESSION_BP + 1, "StringExpression"),
            # Wolfram's ``:`` (Pattern / Optional) has a high left binding power so it
            # consumes the right operand inside arithmetic chains (``a + z : b`` parses
            # as ``Plus[a, Pattern[z, b]]``), but a low right binding power so the right
            # operand absorbs everything down to commas/semicolons (``z : a + b`` parses
            # as ``Pattern[z, Plus[a, b]]``). Right-associative folding for chains is
            # handled in ``_combine_colon``.
            ":": (self._NAMED_PATTERN_LEFT_BP, self._NAMED_PATTERN_BP, "Pattern"),
            "/;": (self._CONDITION_BP, self._CONDITION_BP + 1, "Condition"),
            "<->": (self._TWO_WAY_RULE_BP, self._TWO_WAY_RULE_BP, "TwoWayRule"),
            "->": (self._RULE_BP, self._RULE_BP, "Rule"),
            ":>": (self._RULE_BP, self._RULE_BP, "RuleDelayed"),
            "/.": (self._REPLACE_BP, self._REPLACE_BP + 1, "ReplaceAll"),
            "//.": (self._REPLACE_BP, self._REPLACE_BP + 1, "ReplaceRepeated"),
            "/@": (self._MAP_BP, self._MAP_BP + 1, "Map"),
            "//@": (self._MAP_BP, self._MAP_BP + 1, "MapAll"),
            "@@": (self._APPLY_BP, self._APPLY_BP + 1, "Apply"),
            "@@@": (self._APPLY_BP, self._APPLY_BP + 1, "MapApply"),
            "@*": (self._COMPOSITION_BP, self._COMPOSITION_BP, "Composition"),
            "/*": (self._COMPOSITION_BP, self._COMPOSITION_BP, "RightComposition"),
            "@": (self._AT_BP, self._AT_BP, None),
            "//": (self._POSTFIX_BP, self._POSTFIX_BP + 1, None),
            ".": (self._TIMES_BP, self._TIMES_BP + 1, "Dot"),
            "=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "Set"),
            ":=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "SetDelayed"),
            "^=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "UpSet"),
            "^:=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "UpSetDelayed"),
            "+=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "AddTo"),
            "-=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "SubtractFrom"),
            "*=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "TimesBy"),
            "/=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "DivideBy"),
            "//=": (self._ASSIGNMENT_BP, self._ASSIGNMENT_BP, "ApplyTo"),
            "|->": (self._FUNCTION_BP, self._FUNCTION_BP, "Function"),
        }

        spec = binary_specs.get(text)
        escaped_operator_head = _ESCAPED_INFIX_OPERATOR_HEADS.get(text)
        if spec is None and escaped_operator_head is not None:
            escaped_bp = self._ESCAPED_INFIX_BINDING_POWERS.get(
                escaped_operator_head,
                self._COMPARE_BP,
            )
            spec = (escaped_bp, escaped_bp + 1, escaped_operator_head)
        if spec is None:
            return None

        left_bp, right_bp, head_name = spec
        if left_bp < min_bp:
            return None

        self._consume()
        right = self._parse_expression(
            right_bp,
            terminators=terminators | {"eof", ",", "]", "]]", "}", "|>", ")"},
        )

        if text == "/":
            return self._make_division_operator_call(left, right)
        if text == "-":
            return self._make_flat_parser_operator_call("Plus", left, call("Times", integer(-1), right))
        if text == ":":
            return self._combine_colon(left, right)
        if text == "@":
            return Call(head_expr=left, arguments=(right,))
        if text == "//":
            return Call(head_expr=right, arguments=(left,))
        if head_name is None:
            raise WolframSyntaxError(f"Unhandled Wolfram operator {text!r}.")
        if head_name in {"Set", "SetDelayed"} and self._is_tag_set_prefix(left):
            tag_head = "TagSet" if head_name == "Set" else "TagSetDelayed"
            return call(tag_head, left.arguments[0], left.arguments[1], right)
        if head_name in _CHAINABLE_COMPARISON_HEADS:
            return self._make_comparison_operator_call(head_name, left, right)
        if head_name in {"Plus", "Times"} or escaped_operator_head is not None:
            return self._make_flat_parser_operator_call(head_name, left, right)
        result = call(head_name, left, right)
        self._operator_expr_heads[id(result)] = head_name
        return result

    def _is_ungrouped_operator_call(self, expr: Expr, head_name: str) -> TypeGuard[Call]:
        return (
            isinstance(expr, Call)
            and expr.has_head(head_name)
            and self._operator_expr_heads.get(id(expr)) == head_name
            and id(expr) not in self._grouped_expr_ids
        )

    def _make_flat_parser_operator_call(self, head_name: str, left: Expr, right: Expr) -> Call:
        arguments: list[Expr] = []
        if self._is_ungrouped_operator_call(left, head_name):
            arguments.extend(left.arguments)
        else:
            arguments.append(left)
        if self._is_ungrouped_operator_call(right, head_name):
            arguments.extend(right.arguments)
        else:
            arguments.append(right)
        result = call(head_name, *arguments)
        self._operator_expr_heads[id(result)] = head_name
        return result

    def _make_division_operator_call(self, left: Expr, right: Expr) -> Call:
        reciprocal = call("Power", right, integer(-1))
        if self._is_ungrouped_operator_call(left, "Times") and left.arguments:
            prefix = left.arguments[:-1]
            divided_factor = call("Times", left.arguments[-1], reciprocal)
            result = call("Times", *prefix, divided_factor)
            self._operator_expr_heads[id(result)] = "Times"
            return result
        return call("Times", left, reciprocal)

    def _make_comparison_operator_call(self, head_name: str, left: Expr, right: Expr) -> Call:
        if self._is_ungrouped_operator_call(right, head_name):
            result = call(head_name, left, *right.arguments)
            self._operator_expr_heads[id(result)] = head_name
            return result

        right_operator_head = self._operator_expr_heads.get(id(right))
        if (
            isinstance(right, Call)
            and right_operator_head in _CHAINABLE_COMPARISON_HEADS
            and id(right) not in self._grouped_expr_ids
        ):
            tail: list[Expr] = [right.arguments[0]]
            for argument in right.arguments[1:]:
                tail.extend((symbol(right_operator_head), argument))
            result = call("Inequality", left, symbol(head_name), *tail)
            self._operator_expr_heads[id(result)] = "Inequality"
            return result

        if self._is_ungrouped_operator_call(right, "Inequality"):
            result = call("Inequality", left, symbol(head_name), *right.arguments)
            self._operator_expr_heads[id(result)] = "Inequality"
            return result

        result = call(head_name, left, right)
        self._operator_expr_heads[id(result)] = head_name
        return result
