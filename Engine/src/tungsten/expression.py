from __future__ import annotations

import base64
import binascii
import bz2
from contextvars import ContextVar
import csv
from dataclasses import dataclass, field
from decimal import ROUND_HALF_EVEN, Decimal, InvalidOperation, localcontext
from fractions import Fraction
from functools import cmp_to_key
import gzip
import html
from importlib import resources
import io
import itertools
import json
import math
import random
import re
import sys
import time
import unicodedata
from typing import Callable, Iterable, Sequence, TypeGuard
from xml.etree import ElementTree

from .named_characters import encode_printable_ascii
from .wolfram_strings import has_inline_boxes
from .wolfram_strings import inline_box_escape
from .wolfram_strings import inline_box_segments
from .wolfram_strings import parse_wl_string_literal
from .wolfram_strings import skip_wl_comment
from .wolfram_strings import skip_wl_string
from .wolfram_strings import wl_string


class WolframSyntaxError(ValueError):
    """Raised when Tungsten cannot parse a Wolfram expression."""


class WolframEvaluationError(ValueError):
    """Raised when Tungsten cannot structurally evaluate a built-in expression."""


class TungstenExitRequested(Exception):
    """Raised when kernel-free evaluation reaches Exit or Quit."""

    def __init__(self, code: int = 0) -> None:
        super().__init__(code)
        self.code = int(code)


class TungstenAbortRequested(Exception):
    """Internal non-local signal raised when evaluation reaches Abort[]."""


class _TungstenThrowSignal(Exception):
    def __init__(self, value: Expr, tag: Expr | None = None, handler: Expr | None = None) -> None:
        super().__init__(value, tag, handler)
        self.value = value
        self.tag = tag
        self.handler = handler


class _TungstenTimeConstraintSignal(Exception):
    """Internal signal raised when the innermost active time constraint expires."""


class _TungstenConfirmSignal(Exception):
    """Internal signal raised by Confirm-family functions for Enclose to catch."""

    def __init__(self, failure: Expr, tag: Expr | None = None) -> None:
        super().__init__(failure, tag)
        self.failure = failure
        self.tag = tag


class _TungstenTerminatedEvaluationSignal(Exception):
    """Internal signal raised when a system evaluation limit is exceeded."""

    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


class _TungstenBreakSignal(Exception):
    """Internal signal raised by ``Break[]``.

    Propagates outward until the nearest enclosing ``Do`` / ``While`` /
    ``For`` loop catches it and exits with ``Null``. Per the Wolfram
    docs, ``Break`` does *not* propagate through ``Table`` / ``Sum`` /
    ``Product``, so those heads do not catch this signal.
    """


class _TungstenContinueSignal(Exception):
    """Internal signal raised by ``Continue[]``.

    Same propagation rules as ``_TungstenBreakSignal``: caught by the
    next ``Do`` / ``While`` / ``For`` loop, which skips the rest of
    the body and resumes with the next iteration.
    """


class _TungstenReturnSignal(Exception):
    """Internal signal raised by ``Return[expr]`` and
    ``Return[expr, head]``.

    The one-argument form (``head_name`` is ``None``) is caught at
    the boundary of a function-definition rule application — i.e.,
    when a matched ``DownValues`` / ``SubValues`` / ``UpValues`` rule's
    RHS is evaluated. The two-argument form (``head_name`` is the
    string name of the targeted head, e.g. ``"Module"`` or
    ``"For"``) is caught by the corresponding head's evaluator.
    """

    def __init__(self, value: Expr, head_name: str | None = None) -> None:
        super().__init__(value, head_name)
        self.value = value
        self.head_name = head_name


class _TungstenGotoSignal(Exception):
    """Internal signal raised by ``Goto[label]``.

    Caught by the nearest enclosing ``CompoundExpression`` whose
    arguments contain a matching ``Label[label]`` marker. Evaluation
    resumes from the position after the matched ``Label``.
    """

    def __init__(self, label: Expr) -> None:
        super().__init__(label)
        self.label = label


_CONTROL_SIGNAL_TYPES = (
    TungstenExitRequested,
    TungstenAbortRequested,
    _TungstenThrowSignal,
    _TungstenTimeConstraintSignal,
    _TungstenConfirmSignal,
    _TungstenTerminatedEvaluationSignal,
    _TungstenBreakSignal,
    _TungstenContinueSignal,
    _TungstenReturnSignal,
    _TungstenGotoSignal,
)


class Expr:
    def head(self) -> Expr:
        raise NotImplementedError

    def args(self) -> tuple[Expr, ...]:
        return ()

    def is_atom(self) -> bool:
        return not self.args()

    def to_full_form(self) -> str:
        raise NotImplementedError

    def to_input_form(self) -> str:
        return self.to_full_form()

    def to_dict(self) -> dict[str, object]:
        raise NotImplementedError

    def has_head(self, name: str) -> bool:
        return False


@dataclass(frozen=True)
class Symbol(Expr):
    name: str

    def head(self) -> Expr:
        return Symbol("Symbol")

    def to_full_form(self) -> str:
        return encode_printable_ascii(self.name)

    def to_input_form(self) -> str:
        return self.name

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "symbol",
            "name": self.name,
        }

    def has_head(self, name: str) -> bool:
        return self.name == name


@dataclass(frozen=True)
class Integer(Expr):
    value: int

    def head(self) -> Expr:
        return Symbol("Integer")

    def to_full_form(self) -> str:
        return str(self.value)

    def to_input_form(self) -> str:
        return str(self.value)

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "integer",
            "value": self.value,
        }


@dataclass(frozen=True)
class Real(Expr):
    text: str

    def head(self) -> Expr:
        return Symbol("Real")

    def to_full_form(self) -> str:
        return self.text

    def to_input_form(self) -> str:
        return self.text

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "real",
            "text": self.text,
        }


@dataclass(frozen=True)
class RationalNumber(Expr):
    value: Fraction

    def head(self) -> Expr:
        return Symbol("Rational")

    def to_full_form(self) -> str:
        return f"Rational[{self.value.numerator}, {self.value.denominator}]"

    def to_input_form(self) -> str:
        return f"{self.value.numerator}/{self.value.denominator}"

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "rational",
            "numerator": self.value.numerator,
            "denominator": self.value.denominator,
        }


@dataclass(frozen=True)
class ComplexNumber(Expr):
    real_part: Expr
    imaginary_part: Expr

    def head(self) -> Expr:
        return Symbol("Complex")

    def to_full_form(self) -> str:
        return f"Complex[{self.real_part.to_full_form()}, {self.imaginary_part.to_full_form()}]"

    def to_input_form(self) -> str:
        if _is_exact_zero(self.real_part):
            return _format_imaginary_input(self.imaginary_part)
        if _is_negative_real_number(self.imaginary_part):
            return f"{self.real_part.to_input_form()} - {_format_imaginary_input(_negate_real_expr(self.imaginary_part))}"
        return f"{self.real_part.to_input_form()} + {_format_imaginary_input(self.imaginary_part)}"

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "complex",
            "real": self.real_part.to_dict(),
            "imaginary": self.imaginary_part.to_dict(),
        }


@dataclass(frozen=True)
class RootNumber(Expr):
    coefficients: tuple[int, ...]
    index: int
    method: int = 0

    def head(self) -> Expr:
        return Symbol("Root")

    def args(self) -> tuple[Expr, ...]:
        return (self._function_expr(), integer(self.index + 1), integer(self.method))

    def is_atom(self) -> bool:
        return False

    def has_head(self, name: str) -> bool:
        return name == "Root"

    def to_full_form(self) -> str:
        return f"Root[{self._function_expr().to_full_form()}, {self.index + 1}, {self.method}]"

    def to_input_form(self) -> str:
        return f"Root[{self._function_expr().to_input_form()}, {self.index + 1}, {self.method}]"

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "root",
            "coefficients": list(self.coefficients),
            "index": self.index + 1,
            "method": self.method,
        }

    def _function_expr(self) -> Expr:
        body = _polynomial_expr_from_coefficients(self.coefficients, call("Slot", integer(1)))
        return call("Function", body)


@dataclass(frozen=True)
class SpecialReal(Expr):
    name: str

    def head(self) -> Expr:
        return Symbol("Real")

    def to_full_form(self) -> str:
        return f"{self.name}[]"

    def to_input_form(self) -> str:
        return self.to_full_form()

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "real",
            "special": self.name,
        }


@dataclass(frozen=True)
class String(Expr):
    value: str

    def head(self) -> Expr:
        return Symbol("String")

    def to_full_form(self) -> str:
        return wl_string(self.value)

    def to_input_form(self) -> str:
        return wl_string(self.value)

    def to_dict(self) -> dict[str, object]:
        payload = {
            "type": "string",
            "value": self.value,
        }
        if has_inline_boxes(self.value):
            payload["inline_boxes"] = [
                segment.to_dict()
                for segment in inline_box_segments(self.value)
            ]
        return payload


@dataclass(frozen=True)
class ByteArrayExpr(Expr):
    values: tuple[int, ...]

    def head(self) -> Expr:
        return Symbol("ByteArray")

    def to_full_form(self) -> str:
        encoded = base64.b64encode(bytes(self.values)).decode("ascii")
        return f'ByteArray["{encoded}"]'

    def to_input_form(self) -> str:
        return self.to_full_form()

    def to_dict(self) -> dict[str, object]:
        encoded = base64.b64encode(bytes(self.values)).decode("ascii")
        return {
            "type": "byte_array",
            "values": list(self.values),
            "base64": encoded,
            "length": len(self.values),
        }


@dataclass(frozen=True)
class _SparseArrayEntry:
    indices: tuple[int, ...]
    value: Expr


@dataclass(frozen=True)
class SparseArrayExpr(Expr):
    dimensions: tuple[int, ...]
    entries: tuple[_SparseArrayEntry, ...]
    fill_value: Expr = field(default_factory=lambda: Integer(0))
    _backend: object | None = field(default=None, init=False, compare=False, repr=False, hash=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "_backend", _build_sparse_backend(self.dimensions, self.entries, self.fill_value))

    def head(self) -> Expr:
        return Symbol("SparseArray")

    def to_full_form(self) -> str:
        return _sparse_array_constructor_call(self).to_full_form()

    def to_input_form(self) -> str:
        return _sparse_array_constructor_call(self).to_input_form()

    def to_dict(self) -> dict[str, object]:
        payload: dict[str, object] = {
            "type": "sparse_array",
            "dimensions": list(self.dimensions),
            "fill_value": self.fill_value.to_dict(),
            "entries": [
                {
                    "indices": list(entry.indices),
                    "value": entry.value.to_dict(),
                }
                for entry in self.entries
            ],
            "explicit_length": len(self.entries),
        }
        if self._backend is not None:
            backend_type = type(self._backend)
            payload["backend"] = f"{backend_type.__module__}.{backend_type.__name__}"
        return payload


_SYSTEM_SYMBOL_NAMES = {
    "$Aborted",
    "$AssertFunction",
    "$Canceled",
    "$Context",
    "$ContextPath",
    "$Failed",
    "$HistoryLength",
    "$IterationLimit",
    "$Line",
    "$MachineEpsilon",
    "$MachinePrecision",
    "$MaxRootDegree",
    "$MaxMachineNumber",
    "$MessageList",
    "$MessagePrePrint",
    "$MinMachineNumber",
    "$OutputSizeLimit",
    "$Post",
    "$Pre",
    "$PrePrint",
    "$PreRead",
    "$RecursionLimit",
    "Abs",
    "Abort",
    "AbortProtect",
    "AbsoluteTiming",
    "AccountingForm",
    "Accuracy",
    "All",
    "AlphabeticSort",
    "Alternatives",
    "And",
    "Apart",
    "Append",
    "AppendTo",
    "Apply",
    "Array",
    "ArrayDepth",
    "ArrayFlatten",
    "ArrayPad",
    "ArrayQ",
    "ArrayReshape",
    "ArrayRules",
    "Association",
    "AssociationMap",
    "AssociationQ",
    "AssociationThread",
    "Assert",
    "AtomQ",
    "Attributes",
    "Automatic",
    "AutoDelete",
    "Baseline",
    "BaselinePosition",
    "BaseDecode",
    "BaseEncode",
    "BaseForm",
    "Blank",
    "BlankNullSequence",
    "BlankSequence",
    "BlockMap",
    "Boole",
    "BoxData",
    "ByteArray",
    "ByteArrayQ",
    "ByteArrayToString",
    "CForm",
    "Cancel",
    "Cases",
    "Catch",
    "CharacterRange",
    "Characters",
    "Check",
    "CheckAbort",
    "CenterDot",
    "CircleDot",
    "CircleMinus",
    "CirclePlus",
    "CircleTimes",
    "Clear",
    "ClearAll",
    "ClearAttributes",
    "Clip",
    "Coefficient",
    "CoefficientList",
    "Collect",
    "Comap",
    "ComapApply",
    "Complex",
    "ComplexInfinity",
    "Complement",
    "ComposeList",
    "Composition",
    "Confirm",
    "ConfirmAssert",
    "ConfirmBy",
    "ConfirmMatch",
    "ConfirmationFailed",
    "Condition",
    "Conjugate",
    "Congruent",
    "Constant",
    "ConstantArray",
    "Construct",
    "Context",
    "Contexts",
    "Counts",
    "Cross",
    "Cycles",
    "DatePattern",
    "Delete",
    "DeleteAdjacentDuplicates",
    "DeleteCases",
    "DeleteDuplicates",
    "DeleteDuplicatesBy",
    "Decompose",
    "Derivative",
    "Det",
    "Depth",
    "DecimalForm",
    "DegreeLexicographic",
    "DegreeReverseLexicographic",
    "Denominator",
    "DiagonalMatrix",
    "Diamond",
    "DigitCharacter",
    "DigitQ",
    "Discard",
    "DirectedEdge",
    "Dimensions",
    "DiscreteDelta",
    "DiscreteRatio",
    "DiscreteShift",
    "Discriminant",
    "DisplayForm",
    "Distribute",
    "Divide",
    "Dot",
    "DoubleLeftArrow",
    "DoubleLeftRightArrow",
    "DoubleRightArrow",
    "DoubleVerticalBar",
    "DownArrow",
    "DownValues",
    "Drop",
    "DuplicateFreeQ",
    "Element",
    "EndOfLine",
    "EndOfString",
    "EngineeringForm",
    "Equal",
    "Editable",
    "Equivalent",
    "EvenQ",
    "Except",
    "Expand",
    "Exponent",
    "ExportByteArray",
    "ExportString",
    "Extract",
    "Exit",
    "Failsafe",
    "FailsafeFailed",
    "False",
    "Factor",
    "FactorInteger",
    "FactorList",
    "Failure",
    "FailureQ",
    "ExactNumberQ",
    "Extension",
    "First",
    "FirstCase",
    "FixedPoint",
    "FixedPointList",
    "Flat",
    "Flatten",
    "FlattenAt",
    "Fold",
    "FoldList",
    "FoldPair",
    "FoldPairList",
    "FoldWhile",
    "FoldWhileList",
    "FreeQ",
    "FromCharacterCode",
    "FortranForm",
    "FullForm",
    "Function",
    "GaussianIntegers",
    "General",
    "Greater",
    "GreaterEqual",
    "GroebnerBasis",
    "Head",
    "HexadecimalCharacter",
    "Hold",
    "HoldAll",
    "HoldAllComplete",
    "HoldComplete",
    "HoldFirst",
    "HoldForm",
    "HoldPattern",
    "HoldRest",
    "Identity",
    "IdentityMatrix",
    "If",
    "I",
    "Im",
    "In",
    "InString",
    "InputForm",
    "ImportByteArray",
    "ImportString",
    "Implies",
    "InexactNumberQ",
    "Indeterminate",
    "Infinity",
    "Inequality",
    "Inner",
    "Insert",
    "Intersection",
    "Inverse",
    "Integer",
    "IntegerExponent",
    "IntegerQ",
    "Join",
    "Key",
    "KeyDrop",
    "KeyExistsQ",
    "KeyMap",
    "KeyMemberQ",
    "KeySelect",
    "KeyTake",
    "KeyValueMap",
    "KeyValuePattern",
    "Keys",
    "KroneckerDelta",
    "Last",
    "Length",
    "LetterCharacter",
    "LetterQ",
    "LeviCivitaTensor",
    "LengthWhile",
    "Less",
    "LessEqual",
    "LessEqualGreater",
    "Lexicographic",
    "LexicographicOrder",
    "LexicographicSort",
    "Level",
    "List",
    "Listable",
    "Locked",
    "Lookup",
    "Longest",
    "LongLeftArrow",
    "LongLeftRightArrow",
    "LongRightArrow",
    "MakeBoxes",
    "MakeExpression",
    "MachineIntegerQ",
    "MachineNumberQ",
    "Map",
    "MapAll",
    "MapApply",
    "MapAt",
    "MapIndexed",
    "MapThread",
    "MatchQ",
    "MathMLForm",
    "MatrixForm",
    "MatrixPower",
    "Max",
    "MaximalBy",
    "MemberQ",
    "Message",
    "MessageList",
    "MessageName",
    "MinimalPolynomial",
    "Min",
    "MinimalBy",
    "Missing",
    "MissingQ",
    "MinusPlus",
    "Mod",
    "Modulus",
    "MonomialList",
    "Most",
    "MachinePrecision",
    "Names",
    "NegativeDegreeLexicographic",
    "NegativeDegreeReverseLexicographic",
    "NegativeLexicographic",
    "Nest",
    "NestList",
    "NestWhile",
    "NestWhileList",
    "N",
    "NHoldAll",
    "NHoldFirst",
    "NHoldRest",
    "NonThreadable",
    "None",
    "Normal",
    "Not",
    "NotElement",
    "NotSubset",
    "NotSubsetEqual",
    "NotSuperset",
    "NotSupersetEqual",
    "Nothing",
    "Null",
    "NumberForm",
    "NumberQ",
    "NumberString",
    "NumberMarks",
    "Numerator",
    "NumericalSort",
    "NumericFunction",
    "OddQ",
    "Off",
    "OneIdentity",
    "On",
    "Operate",
    "Or",
    "Order",
    "OrderedQ",
    "Ordering",
    "OrderingBy",
    "Out",
    "OutputForm",
    "Outer",
    "Overflow",
    "OwnValues",
    "Overscript",
    "OverscriptBox",
    "OptionsPattern",
    "Optional",
    "Orderless",
    "OrderlessPatternSequence",
    "Part",
    "Partition",
    "Pause",
    "PaddedForm",
    "Pattern",
    "PatternSequence",
    "PatternTest",
    "PercentForm",
    "Permutations",
    "Permute",
    "Piecewise",
    "Pick",
    "Plus",
    "PlusMinus",
    "PolynomialGCD",
    "PolynomialLCM",
    "PolynomialMod",
    "PolynomialQ",
    "PolynomialQuotient",
    "PolynomialReduce",
    "PolynomialRemainder",
    "Position",
    "Power",
    "Precision",
    "Print",
    "PrintForm",
    "Precedes",
    "PrecedesEqual",
    "Prepend",
    "Proportion",
    "Protect",
    "Protected",
    "PunctuationCharacter",
    "Quotient",
    "QuotientRemainder",
    "Quit",
    "Quiet",
    "Ramp",
    "RandomPermutation",
    "RandomSample",
    "Range",
    "Rational",
    "Re",
    "Real",
    "RealAbs",
    "RealSign",
    "RealValuedNumberQ",
    "ReadProtected",
    "Reap",
    "ReleaseHold",
    "RegularExpression",
    "Repeated",
    "RepeatedNull",
    "Replace",
    "ReplaceAll",
    "ReplaceAt",
    "ReplacePart",
    "ReplaceRepeated",
    "Resultant",
    "Rest",
    "Reverse",
    "ReverseSort",
    "ReverseSortBy",
    "RightComposition",
    "RightArrow",
    "Root",
    "RootReduce",
    "RotateLeft",
    "RotateRight",
    "Rule",
    "RuleDelayed",
    "SameAs",
    "SameQ",
    "SameTest",
    "Scan",
    "ScientificForm",
    "Select",
    "SelectFirst",
    "SetAttributes",
    "SetAccuracy",
    "SetPrecision",
    "ShowSpecialCharacters",
    "ShowStringCharacters",
    "Shallow",
    "Short",
    "Shortest",
    "Sequence",
    "SequenceFold",
    "SequenceFoldList",
    "SequenceForm",
    "SequenceHold",
    "Sign",
    "Slot",
    "SlotSequence",
    "SmallCircle",
    "Sort",
    "SortBy",
    "Sow",
    "Span",
    "SquareIntersection",
    "SquareSubset",
    "SquareSubsetEqual",
    "SquareSuperset",
    "SquareSupersetEqual",
    "SquareUnion",
    "Star",
    "StartOfLine",
    "StartOfString",
    "StandardForm",
    "SparseArray",
    "SparseArrayQ",
    "String",
    "StringCases",
    "StringContainsQ",
    "StringDrop",
    "StringEndsQ",
    "StringExpression",
    "StringFreeQ",
    "StringForm",
    "StringInsert",
    "StringJoin",
    "StringLength",
    "StringMatchQ",
    "StringPosition",
    "StringQ",
    "StringReplace",
    "StringReverse",
    "StringStartsQ",
    "StringTake",
    "StringToByteArray",
    "StripBoxes",
    "Subresultants",
    "Subsets",
    "Subset",
    "SubsetEqual",
    "Subscript",
    "SubscriptBox",
    "Subsuperscript",
    "SubsuperscriptBox",
    "Succeeds",
    "SucceedsEqual",
    "Superset",
    "SupersetEqual",
    "SyntaxLength",
    "SyntaxQ",
    "Switch",
    "Symbol",
    "SymbolName",
    "TableForm",
    "Tally",
    "Take",
    "TakeDrop",
    "TakeList",
    "TakeWhile",
    "Thread",
    "Through",
    "Times",
    "TimeConstrained",
    "TimeRemaining",
    "TensorProduct",
    "Temporary",
    "TeXForm",
    "TextForm",
    "Tilde",
    "TildeEqual",
    "TildeFullEqual",
    "TildeTilde",
    "ToBoxes",
    "ToCharacterCode",
    "ToExpression",
    "ToString",
    "Together",
    "TraditionalForm",
    "TreeForm",
    "Throw",
    "True",
    "TrueQ",
    "Tuples",
    "Unequal",
    "Unevaluated",
    "Underscript",
    "UnderscriptBox",
    "UndirectedEdge",
    "Underflow",
    "Underoverscript",
    "UnderoverscriptBox",
    "UnitStep",
    "UnitVector",
    "Unitize",
    "Union",
    "UpArrow",
    "UpTo",
    "Unique",
    "Unprotect",
    "UnsameQ",
    "ValueQ",
    "Values",
    "Variables",
    "Verbatim",
    "VerticalBar",
    "VerticalSeparator",
    "Vee",
    "Wedge",
    "Whitespace",
    "WhitespaceCharacter",
    "Which",
    "WithCleanup",
    "WordBoundary",
    "WordCharacter",
}


_SYSTEM_SYMBOL_SNAPSHOT_RESOURCE = "data/system_symbols_wolfram_15_0.json"


_SPECIAL_SESSION_SETTING_DEFAULTS: dict[str, Expr] = {
    "$RecursionLimit": Integer(1024),
    "$IterationLimit": Integer(4096),
    "$HistoryLength": Symbol("Infinity"),
    "$MaxExtraPrecision": Integer(50),
    "$MaxRootDegree": Integer(1000),
    # The Wolfram terminal front end owns this setting through OutputSizeLimit`.
    # Tungsten keeps a small, explicit REPL setting instead so console output can
    # remain usable without loading a front-end package.
    "$OutputSizeLimit": Integer(12000),
}


_SPECIAL_SESSION_SETTING_MINIMUMS = {
    "$RecursionLimit": 20,
    "$IterationLimit": 20,
    "$HistoryLength": 0,
    "$MaxExtraPrecision": 0,
    "$MaxRootDegree": 1,
    "$OutputSizeLimit": 0,
}


_KNOWN_ATTRIBUTE_NAMES = {
    "Constant",
    "Flat",
    "HoldAll",
    "HoldAllComplete",
    "HoldFirst",
    "HoldRest",
    "Listable",
    "Locked",
    "NHoldAll",
    "NHoldFirst",
    "NHoldRest",
    "NonThreadable",
    "NumericFunction",
    "OneIdentity",
    "Orderless",
    "Protected",
    "ReadProtected",
    "SequenceHold",
    "Stub",
    "Temporary",
}


_HOLD_ALL_ATTRIBUTE_NAMES = {"HoldAll", "HoldAllComplete"}


def _load_system_symbol_snapshot() -> dict[str, tuple[str, ...]]:
    try:
        resource = resources.files(__package__).joinpath(_SYSTEM_SYMBOL_SNAPSHOT_RESOURCE)
        payload = json.loads(resource.read_text(encoding="utf-8-sig"))
    except (AttributeError, FileNotFoundError, ModuleNotFoundError, TypeError, json.JSONDecodeError):
        return {}

    symbols = payload.get("symbols")
    if not isinstance(symbols, list):
        return {}

    result: dict[str, tuple[str, ...]] = {}
    for row in symbols:
        if not isinstance(row, list | tuple) or len(row) != 2:
            continue
        name, attributes = row
        if not isinstance(name, str):
            continue
        if not isinstance(attributes, list):
            attributes = []
        result[name] = tuple(attribute for attribute in attributes if isinstance(attribute, str))
    return result


@dataclass
class SymbolRecord:
    """Per-symbol storage owned by ``SymbolRegistry``.

    The legacy single-slot ``own_value`` field continues to exist for the
    bare-symbol Set / SetDelayed path that has shipped since 2026-04-23.
    The four ``*_definitions`` lists are the canonical, ordered storage
    for compound-LHS Set / SetDelayed and the upcoming UpSet / TagSet
    implementation; they are populated and consulted through
    ``tungsten.expression_definitions``.

    For now the legacy slot remains the source of truth for the bare-symbol
    case; the canonical list is *additive* and the two views are kept in
    sync by ``coalesce_legacy_own_value``. Once remaining own-value
    compatibility seams are removed, ``own_value`` can retire and the
    canonical list can become the only write path.
    """

    full_name: str
    context: str
    short_name: str
    built_in: bool = False
    attributes: tuple[str, ...] = ()
    own_value: Expr | None = None
    down_values: tuple[Expr, ...] = ()
    up_values: tuple[Expr, ...] = ()
    sub_values: tuple[Expr, ...] = ()
    # Canonical ordered lists for definition storage. The
    # element type is ``tungsten.expression_definitions.Definition``; using
    # ``list`` here avoids an import cycle at module load time.
    own_values_definitions: list = field(default_factory=list)
    down_values_definitions: list = field(default_factory=list)
    up_values_definitions: list = field(default_factory=list)
    sub_values_definitions: list = field(default_factory=list)
    n_values_definitions: list = field(default_factory=list)

    def definitions_for_kind(self, kind: str) -> list:
        """Return the live mutable list for the requested value kind.

        ``kind`` is one of the ``VALUE_KIND_*`` constants exported by
        ``tungsten.expression_definitions``. This indirection keeps the
        canonical-vs-legacy storage details inside ``SymbolRecord`` so
        callers don't depend on individual field names.
        """
        if kind == "OwnValues":
            return self.own_values_definitions
        if kind == "DownValues":
            return self.down_values_definitions
        if kind == "UpValues":
            return self.up_values_definitions
        if kind == "SubValues":
            return self.sub_values_definitions
        if kind == "NValues":
            return self.n_values_definitions
        raise ValueError(f"Unknown value kind: {kind!r}")


class SymbolRegistry:
    def __init__(self) -> None:
        self.current_context = "Global`"
        self.context_path = ("System`", "Global`")
        self._symbols: dict[str, SymbolRecord] = {}
        self._contexts: set[str] = {self.current_context, *self.context_path}
        self._module_number = 0
        self._string_unique_counters: dict[str, int] = {}
        for name in sorted(_SYSTEM_SYMBOL_NAMES):
            self.ensure_full_name(f"System`{name}", built_in=True)
        for name, attributes in _load_system_symbol_snapshot().items():
            self.ensure_full_name(f"System`{name}", built_in=True, attributes=attributes, validate=False)
        for name, default_value in _SPECIAL_SESSION_SETTING_DEFAULTS.items():
            record = self.ensure_full_name(f"System`{name}", built_in=True)
            if record.own_value is None:
                record.own_value = default_value
        message_preprint = self.ensure_full_name("System`$MessagePrePrint", built_in=True)
        if message_preprint.own_value is None:
            message_preprint.own_value = Symbol("Automatic")

    def _mirror_own_value_into_canonical(self, record: SymbolRecord) -> None:
        """Reflect the legacy single-slot ``own_value`` into the canonical
        ``own_values_definitions`` list.

        Called whenever the legacy slot is updated through Set / Unset.
        Compound-LHS Set writes directly through
        ``tungsten.expression_definitions.assign_definition`` and does not
        use this mirror. ``own_values_expr`` falls back to the legacy slot
        when the canonical list is empty so registry-seeded values such as
        ``$MessagePrePrint = Automatic`` remain visible without a canonical
        entry being created at module-load time.
        """
        from .expression_definitions import Definition

        canonical = record.own_values_definitions
        if record.own_value is None:
            canonical.clear()
            return
        display = self._display_symbol_for_record(record)
        canonical[:] = [
            Definition(
                hold_pattern=call("HoldPattern", display),
                rhs=record.own_value,
                delayed=False,
            )
        ]

    @property
    def contexts(self) -> tuple[str, ...]:
        return tuple(sorted(self._contexts))

    def ensure_full_name(
        self,
        full_name: str,
        *,
        built_in: bool = False,
        attributes: Sequence[str] | None = None,
        validate: bool = True,
    ) -> SymbolRecord:
        record = self._symbols.get(full_name)
        if record is not None:
            if built_in and not record.built_in:
                record.built_in = True
            if attributes is not None:
                record.attributes = tuple(attributes)
            self._contexts.add(record.context)
            return record

        context, short_name = _split_symbol_full_name(full_name)
        if validate and (not _is_valid_context_name(context) or not _is_valid_symbol_short_name(short_name)):
            raise WolframEvaluationError(f"Invalid Wolfram symbol name: {full_name!r}.")
        if not _is_valid_context_name(context):
            raise WolframEvaluationError(f"Invalid Wolfram symbol context: {full_name!r}.")
        record = SymbolRecord(
            full_name=full_name,
            context=context,
            short_name=short_name,
            built_in=built_in,
            attributes=tuple(attributes or ()),
        )
        self._symbols[full_name] = record
        self._contexts.add(context)
        return record

    def ensure_name(self, name: str, *, built_in: bool = False) -> SymbolRecord:
        full_name = self.resolve_full_name(name)
        record = self._symbols.get(full_name)
        if record is not None:
            if built_in and not record.built_in:
                record.built_in = True
            return record
        return self.ensure_full_name(full_name, built_in=built_in)

    def resolve_full_name(self, name: str) -> str:
        if "`" in name:
            context, short_name = _split_symbol_full_name(name)
            if not context:
                context = self.current_context
            full_name = f"{context}{short_name}"
            if full_name in self._symbols:
                return full_name
            if not _is_valid_context_name(context) or not _is_valid_symbol_short_name(short_name):
                raise WolframEvaluationError(f"Invalid Wolfram symbol name: {name!r}.")
            return full_name
        for context in self.context_path:
            full_name = f"{context}{name}"
            if full_name in self._symbols:
                return full_name
        if not _is_valid_symbol_short_name(name):
            raise WolframEvaluationError(f"Invalid Wolfram symbol name: {name!r}.")
        return f"{self.current_context}{name}"

    def resolve_existing(self, name: str) -> SymbolRecord | None:
        try:
            full_name = self.resolve_full_name(name)
        except WolframEvaluationError:
            return None
        return self._symbols.get(full_name)

    def record_for_symbol(self, expr: Symbol) -> SymbolRecord:
        return self.ensure_name(expr.name)

    def symbol_from_name(self, name: str) -> Symbol:
        record = self.ensure_name(name)
        return self._display_symbol_for_record(record)

    def allocate_module_local_symbols(
        self, locals_in_order: Sequence[Symbol]
    ) -> tuple[tuple[Symbol, ...], tuple[SymbolRecord, ...]]:
        """Allocate a fresh symbol per local with a *shared* counter suffix.

        ``Module[{x, y, ...}, body]`` allocates ``x$N``, ``y$N``, … all
        with the same `N` (the new module-counter value). This helper
        increments the counter once and returns the freshly-created
        symbols and their records in the same order as the input. The
        returned ``Symbol`` instances are display-symbol forms ready to
        substitute into the body; the records are the live registry
        entries so the caller can install own values on them.

        Each local symbol's ``OwnValues`` slot is left empty; the caller
        is responsible for installing initializer values.
        """
        self._module_number += 1
        suffix = self._module_number
        fresh_symbols: list[Symbol] = []
        fresh_records: list[SymbolRecord] = []
        for local in locals_in_order:
            base_record = self.record_for_symbol(local)
            fresh_full_name = f"{base_record.context}{base_record.short_name}${suffix}"
            fresh_record = self.ensure_full_name(fresh_full_name)
            fresh_symbols.append(self._display_symbol_for_record(fresh_record))
            fresh_records.append(fresh_record)
        return tuple(fresh_symbols), tuple(fresh_records)

    def unique_symbol(self, base: Expr | None = None) -> Symbol:
        if base is None:
            self._module_number += 1
            return self._display_symbol_for_record(self.ensure_full_name(f"{self.current_context}${self._module_number}"))
        if isinstance(base, Symbol):
            base_record = self.record_for_symbol(base)
            self._module_number += 1
            return self._display_symbol_for_record(
                self.ensure_full_name(f"{base_record.context}{base_record.short_name}${self._module_number}")
            )
        if isinstance(base, String):
            prefix = base.value
            if not prefix or not _is_valid_symbol_short_name(f"{prefix}1"):
                raise WolframEvaluationError("Unique expects a valid symbol or symbol-name prefix.")
            next_index = self._string_unique_counters.get(prefix, 0) + 1
            while self.resolve_existing(f"{self.current_context}{prefix}{next_index}") is not None:
                next_index += 1
            self._string_unique_counters[prefix] = next_index
            return self._display_symbol_for_record(self.ensure_full_name(f"{self.current_context}{prefix}{next_index}"))
        raise WolframEvaluationError("Unique expects no argument, a symbol, a string prefix, or a list of those forms.")

    def _display_symbol_for_record(self, record: SymbolRecord) -> Symbol:
        if record.context in set(self.context_path) | {self.current_context}:
            return Symbol(record.short_name)
        return Symbol(record.full_name)

    def names(self, pattern: Expr | None = None) -> tuple[str, ...]:
        if pattern is None:
            patterns = (string("*"),)
        elif isinstance(pattern, Call) and pattern.has_head("List"):
            patterns = tuple(pattern.arguments)
        else:
            patterns = (pattern,)
        matched: set[str] = set()
        for item in patterns:
            if not isinstance(item, String):
                raise WolframEvaluationError("Names expects a string pattern or a list of string patterns.")
            matched.update(self._names_for_string_pattern(item.value))
        return tuple(sorted(matched))

    def _names_for_string_pattern(self, pattern: str) -> tuple[str, ...]:
        has_context = "`" in pattern
        regex = _wolfram_name_pattern_to_regex(pattern)
        result: list[str] = []
        visible_contexts = set(self.context_path) | {self.current_context}
        for record in self._symbols.values():
            candidate = record.full_name if has_context else record.short_name
            if not has_context and record.context not in visible_contexts:
                continue
            if regex.fullmatch(candidate):
                result.append(record.short_name if record.context in visible_contexts else record.full_name)
        return tuple(result)

    def contexts_matching(self, pattern: Expr | None = None) -> tuple[str, ...]:
        if pattern is None:
            return self.contexts
        if not isinstance(pattern, String):
            raise WolframEvaluationError("Contexts expects an optional string pattern.")
        regex = _wolfram_name_pattern_to_regex(pattern.value)
        return tuple(context for context in self.contexts if regex.fullmatch(context))

    def name_q(self, pattern: Expr) -> Symbol:
        return _bool_symbol(bool(self.names(pattern)))

    def attributes_for_symbol(self, expr: Symbol) -> tuple[str, ...]:
        return self.record_for_symbol(expr).attributes

    def attributes_for_name(self, name: str) -> tuple[str, ...]:
        record = self.resolve_existing(name)
        if record is None:
            return ()
        return record.attributes

    def replace_attributes(self, record: SymbolRecord, attributes: Iterable[str]) -> None:
        record.attributes = _canonical_attribute_tuple(attributes)

    def add_attributes(self, record: SymbolRecord, attributes: Iterable[str]) -> None:
        record.attributes = _canonical_attribute_tuple((*record.attributes, *attributes))

    def remove_attributes(self, record: SymbolRecord, attributes: Iterable[str]) -> None:
        removed = set(attributes)
        record.attributes = _canonical_attribute_tuple(
            attribute for attribute in record.attributes if attribute not in removed
        )

    def clear_values(self, record: SymbolRecord) -> None:
        record.own_value = None
        record.down_values = ()
        record.up_values = ()
        record.sub_values = ()
        record.own_values_definitions.clear()
        record.down_values_definitions.clear()
        record.up_values_definitions.clear()
        record.sub_values_definitions.clear()
        record.n_values_definitions.clear()

    def display_symbol_for_record(self, record: SymbolRecord) -> Symbol:
        return self._display_symbol_for_record(record)


def _canonical_attribute_tuple(attributes: Iterable[str]) -> tuple[str, ...]:
    return tuple(sorted(set(attributes)))


def _split_symbol_full_name(name: str) -> tuple[str, str]:
    index = name.rfind("`")
    if index < 0:
        return "", name
    return name[:index + 1], name[index + 1:]


def _is_valid_context_name(context: str) -> bool:
    if not context or not context.endswith("`"):
        return False
    parts = context[:-1].split("`")
    return all(part and _is_valid_symbol_short_name(part) for part in parts)


def _is_valid_symbol_short_name(name: str) -> bool:
    if not name:
        return False
    first = name[0]
    if not (first.isalpha() or first == "$"):
        return False
    return all(char.isalnum() or char == "$" for char in name[1:])


def _wolfram_name_pattern_to_regex(pattern: str) -> re.Pattern[str]:
    pieces: list[str] = []
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "\\" and index + 1 < len(pattern):
            pieces.append(re.escape(pattern[index + 1]))
            index += 2
            continue
        if char == "*":
            pieces.append(".*")
        elif char == "@":
            pieces.append("[^A-Z]+")
        else:
            pieces.append(re.escape(char))
        index += 1
    return re.compile("".join(pieces))


@dataclass(frozen=True)
class EvaluationMessage:
    """A message generated during kernel-free evaluation."""

    name: Expr
    text: str

    def name_expr(self) -> Expr:
        return call("HoldForm", self.name)

    def to_dict(self) -> dict[str, object]:
        return {
            "name": self.name.to_input_form(),
            "full_name": self.name.to_full_form(),
            "text": self.text,
        }


@dataclass(frozen=True)
class _QuietScope:
    off_spec: Expr
    on_spec: Expr


@dataclass
class _MessageCollector:
    spec: Expr
    quiet_depth: int
    messages: list[EvaluationMessage]


@dataclass
class _AbortProtectScope:
    pending_abort: bool = False


@dataclass(frozen=True)
class _CheckAbortScope:
    abort_protect_depth: int


@dataclass(frozen=True)
class _TimeConstraintScope:
    deadline: float | None


@dataclass
class _ReapScope:
    patterns: tuple[Expr, ...]
    pattern_list_mode: bool
    buckets: list[dict[Expr, list[Expr]]]


@dataclass(frozen=True)
class _EncloseScope:
    form: Expr | None


@dataclass
class EvaluationSession:
    """Process-local evaluator state for Wolfram-console-style history."""

    line: int = 0
    inputs: dict[int, Expr] | None = None
    in_strings: dict[int, str] | None = None
    outputs: dict[int, Expr] | None = None
    expanding_inputs: set[int] | None = None
    message_history: dict[int, tuple[EvaluationMessage, ...]] | None = None
    current_messages: list[EvaluationMessage] | None = None
    current_visible_messages: list[EvaluationMessage] | None = None
    print_history: dict[int, tuple[str, ...]] | None = None
    current_prints: list[str] | None = None
    disabled_messages: set[str] | None = None
    assert_enabled: bool = False

    def __post_init__(self) -> None:
        if self.inputs is None:
            self.inputs = {}
        if self.in_strings is None:
            self.in_strings = {}
        if self.outputs is None:
            self.outputs = {}
        if self.expanding_inputs is None:
            self.expanding_inputs = set()
        if self.message_history is None:
            self.message_history = {}
        if self.current_messages is None:
            self.current_messages = []
        if self.current_visible_messages is None:
            self.current_visible_messages = []
        if self.print_history is None:
            self.print_history = {}
        if self.current_prints is None:
            self.current_prints = []
        if self.disabled_messages is None:
            self.disabled_messages = set()

    def _start_input_line(self) -> int:
        self.line += 1
        assert self.current_messages is not None
        assert self.current_visible_messages is not None
        assert self.current_prints is not None
        self.current_messages.clear()
        self.current_visible_messages.clear()
        self.current_prints.clear()
        return self.line

    def _record_input(self, source: str, expr: Expr) -> None:
        assert self.inputs is not None
        assert self.in_strings is not None
        self.inputs[self.line] = expr
        self.in_strings[self.line] = source
        self._prune_history()

    def begin_input(self, source: str, expr: Expr) -> int:
        line = self._start_input_line()
        self._record_input(source, expr)
        return line

    def prepare_input(self, source: str) -> tuple[int, str, Expr]:
        """Apply $PreRead, parse, and store a Wolfram-console input line."""

        line = self._start_input_line()
        prepared_source = _apply_pre_read_hook(source, self)
        expr = parse_input_form(prepared_source)
        self._record_input(prepared_source, expr)
        return line, prepared_source, expr

    def finish_output(self, expr: Expr) -> None:
        assert self.outputs is not None
        assert self.message_history is not None
        assert self.current_visible_messages is not None
        assert self.print_history is not None
        assert self.current_prints is not None
        self.outputs[self.line] = history_output_expr(expr)
        self.message_history[self.line] = tuple(self.current_visible_messages)
        self.print_history[self.line] = tuple(self.current_prints)
        self._prune_history()

    def preprint_output(self, expr: Expr) -> Expr:
        return _apply_pre_print_hook(expr, self)

    def _prune_history(self) -> None:
        history_length = _history_length_limit()
        if history_length is None:
            return
        cutoff = self.line - history_length + 1
        for table in (self.inputs, self.in_strings, self.outputs, self.message_history, self.print_history):
            assert table is not None
            for key in tuple(table):
                if key < cutoff:
                    del table[key]

    def resolve_index(self, argument: Expr | None) -> int:
        if argument is None:
            return self.line - 1
        evaluated = evaluate(argument, session=self)
        if not isinstance(evaluated, Integer):
            raise WolframEvaluationError("History functions expect an integer line specification.")
        if evaluated.value < 0:
            return self.line + evaluated.value
        return evaluated.value


_ACTIVE_EVALUATION_SESSION: ContextVar[EvaluationSession | None] = ContextVar(
    "tungsten_active_evaluation_session",
    default=None,
)
_ACTIVE_OWN_VALUE_SYMBOLS: ContextVar[tuple[str, ...]] = ContextVar(
    "tungsten_active_own_value_symbols",
    default=(),
)
_ACTIVE_EVALUATION_DEPTH: ContextVar[int] = ContextVar(
    "tungsten_active_evaluation_depth",
    default=0,
)
_ACTIVE_EVALUATION_ITERATION_COUNT: ContextVar[int] = ContextVar(
    "tungsten_active_evaluation_iteration_count",
    default=0,
)
_MAIN_LOOP_HOOKS_SUPPRESSED: ContextVar[bool] = ContextVar(
    "tungsten_main_loop_hooks_suppressed",
    default=False,
)
_ACTIVE_QUIET_SCOPES: ContextVar[tuple[_QuietScope, ...]] = ContextVar(
    "tungsten_active_quiet_scopes",
    default=(),
)
_ACTIVE_MESSAGE_COLLECTORS: ContextVar[tuple[_MessageCollector, ...]] = ContextVar(
    "tungsten_active_message_collectors",
    default=(),
)
_ACTIVE_ABORT_PROTECT_SCOPES: ContextVar[tuple[_AbortProtectScope, ...]] = ContextVar(
    "tungsten_active_abort_protect_scopes",
    default=(),
)
_ACTIVE_CHECK_ABORT_SCOPES: ContextVar[tuple[_CheckAbortScope, ...]] = ContextVar(
    "tungsten_active_check_abort_scopes",
    default=(),
)
_ACTIVE_TIME_CONSTRAINTS: ContextVar[tuple[_TimeConstraintScope, ...]] = ContextVar(
    "tungsten_active_time_constraints",
    default=(),
)
_ACTIVE_REAP_SCOPES: ContextVar[tuple[_ReapScope, ...]] = ContextVar(
    "tungsten_active_reap_scopes",
    default=(),
)
_ACTIVE_ENCLOSE_SCOPES: ContextVar[tuple[_EncloseScope, ...]] = ContextVar(
    "tungsten_active_enclose_scopes",
    default=(),
)
_TIME_CONSTRAINT_SUPPRESSION_DEPTH: ContextVar[int] = ContextVar(
    "tungsten_time_constraint_suppression_depth",
    default=0,
)
_GLOBAL_MESSAGES: list[EvaluationMessage] = []
_GLOBAL_VISIBLE_MESSAGES: list[EvaluationMessage] = []
_GLOBAL_PRINTS: list[str] = []
_GLOBAL_DISABLED_MESSAGES: set[str] = set()
_GLOBAL_ASSERT_ENABLED = False


def _active_evaluation_session() -> EvaluationSession | None:
    return _ACTIVE_EVALUATION_SESSION.get()


def _current_disabled_messages() -> set[str]:
    session = _active_evaluation_session()
    if session is not None:
        assert session.disabled_messages is not None
        return session.disabled_messages
    return _GLOBAL_DISABLED_MESSAGES


def _current_message_lists() -> tuple[list[EvaluationMessage], list[EvaluationMessage]]:
    session = _active_evaluation_session()
    if session is not None:
        assert session.current_messages is not None
        assert session.current_visible_messages is not None
        return session.current_messages, session.current_visible_messages
    return _GLOBAL_MESSAGES, _GLOBAL_VISIBLE_MESSAGES


def _current_prints() -> list[str]:
    session = _active_evaluation_session()
    if session is not None:
        assert session.current_prints is not None
        return session.current_prints
    return _GLOBAL_PRINTS


def _assert_enabled() -> bool:
    session = _active_evaluation_session()
    if session is not None:
        return session.assert_enabled
    return _GLOBAL_ASSERT_ENABLED


def _set_assert_enabled(enabled: bool) -> None:
    global _GLOBAL_ASSERT_ENABLED
    session = _active_evaluation_session()
    if session is not None:
        session.assert_enabled = enabled
        return
    _GLOBAL_ASSERT_ENABLED = enabled


_SESSION_HOOK_NAMES = {"$PreRead", "$Pre", "$Post", "$PrePrint", "$MessagePrePrint"}


def _hook_symbol_record(name: str) -> SymbolRecord | None:
    return _SYMBOL_REGISTRY.resolve_existing(f"System`{name}")


def _hook_value(name: str, session: EvaluationSession) -> Expr | None:
    record = _hook_symbol_record(name)
    if record is None or record.own_value is None:
        return None
    return _evaluate_with_main_loop_hooks_suppressed(
        _SYMBOL_REGISTRY.display_symbol_for_record(record),
        session,
    )


def _evaluate_with_main_loop_hooks_suppressed(expr: Expr, session: EvaluationSession) -> Expr:
    hook_token = _MAIN_LOOP_HOOKS_SUPPRESSED.set(True)
    session_token = _ACTIVE_EVALUATION_SESSION.set(session)
    try:
        return evaluate(expr, session=session)
    finally:
        _ACTIVE_EVALUATION_SESSION.reset(session_token)
        _MAIN_LOOP_HOOKS_SUPPRESSED.reset(hook_token)


def _apply_hook_function(function: Expr, argument: Expr, session: EvaluationSession) -> Expr:
    return _evaluate_with_main_loop_hooks_suppressed(
        Call(head_expr=function, arguments=(argument,)),
        session,
    )


def _apply_optional_hook(name: str, argument: Expr, session: EvaluationSession) -> Expr:
    function = _hook_value(name, session)
    if function is None:
        return argument
    return _apply_hook_function(function, argument, session)


def _apply_pre_read_hook(source: str, session: EvaluationSession) -> str:
    session_token = _ACTIVE_EVALUATION_SESSION.set(session)
    try:
        function = _hook_value("$PreRead", session)
        if function is None:
            return source
        result = _apply_hook_function(function, string(source), session)
        if isinstance(result, String):
            return result.value
        emit_message(
            call("MessageName", symbol("$PreRead"), string("prstr")),
            f'$PreRead[{wl_string(source)}] returned {result.to_input_form()}, which is not a string.',
        )
        return source
    finally:
        _ACTIVE_EVALUATION_SESSION.reset(session_token)


def _apply_pre_hook(expr: Expr, session: EvaluationSession) -> Expr:
    return _apply_optional_hook("$Pre", expr, session)


def _apply_post_hook(expr: Expr, session: EvaluationSession) -> Expr:
    return _apply_optional_hook("$Post", expr, session)


def _apply_pre_print_hook(expr: Expr, session: EvaluationSession) -> Expr:
    return _apply_optional_hook("$PrePrint", expr, session)


def _apply_message_pre_print_hook(expr: Expr) -> Expr:
    session = _active_evaluation_session()
    if session is None:
        return expr
    function = _hook_value("$MessagePrePrint", session)
    if function is None or (isinstance(function, Symbol) and _system_dispatch_name(function) == "Automatic"):
        return expr
    return _apply_hook_function(function, expr, session)


def _message_list_expr(messages: Sequence[EvaluationMessage]) -> Call:
    return _evaluated_list_expr(*(message.name_expr() for message in messages))


def current_message_list_expr() -> Call:
    messages, _visible_messages = _current_message_lists()
    return _message_list_expr(messages)


def message_list_expr(arguments: Sequence[Expr]) -> Expr:
    session = _active_evaluation_session()
    if session is None:
        return _evaluated_list_expr()
    if len(arguments) != 1:
        raise WolframEvaluationError("MessageList expects exactly one line specification.")
    index = session.resolve_index(arguments[0])
    assert session.message_history is not None
    return _message_list_expr(session.message_history.get(index, ()))


def _message_name_key(name: Expr) -> str:
    return name.to_full_form()


def _message_name_components(name: Expr) -> tuple[str, tuple[str, ...]] | None:
    if not isinstance(name, Call) or not name.has_head("MessageName") or len(name.arguments) < 2:
        return None
    tags: list[str] = []
    for tag in name.arguments[1:]:
        if isinstance(tag, String):
            tags.append(tag.value)
        elif isinstance(tag, Symbol):
            tags.append(tag.name)
        else:
            return None
    return name.arguments[0].to_full_form(), tuple(tags)


def _message_spec_matches(spec: Expr, name: Expr) -> bool:
    if isinstance(spec, Symbol):
        if spec.name == "All":
            return True
        if spec.name == "None":
            return False
        return _message_spec_matches(call("MessageName", spec, string("trace")), name)
    if isinstance(spec, String):
        return False
    if isinstance(spec, Call):
        if spec.has_head("List"):
            return any(_message_spec_matches(item, name) for item in spec.arguments)
        if spec.has_head("MessageName"):
            if spec == name:
                return True
            spec_components = _message_name_components(spec)
            name_components = _message_name_components(name)
            if spec_components is None or name_components is None:
                return False
            spec_base, spec_tags = spec_components
            name_base, name_tags = name_components
            if spec_base == "General" and spec_tags and name_tags:
                return spec_tags[-1] == name_tags[-1]
            return spec_base == name_base and spec_tags == name_tags
    return False


def _quiet_suppression_depth(name: Expr) -> int | None:
    scopes = _ACTIVE_QUIET_SCOPES.get()
    for index in range(len(scopes) - 1, -1, -1):
        scope = scopes[index]
        if _message_spec_matches(scope.on_spec, name):
            return None
        if _message_spec_matches(scope.off_spec, name):
            return index + 1
    return None


def _format_message_insertion(expr: Expr) -> str:
    transformed = _apply_message_pre_print_hook(expr)
    _label, text = display_output_parts(transformed)
    return text


def _message_text(name: Expr, text: str | None = None, insertions: Sequence[Expr] = ()) -> str:
    rendered_name = name.to_input_form()
    if text is None:
        if insertions:
            rendered_args = ", ".join(_format_message_insertion(item) for item in insertions)
            return f"{rendered_name}: {rendered_args}"
        return f"{rendered_name}: Message generated."
    return f"{rendered_name}: {text}"


def emit_message(name: Expr, text: str | None = None, insertions: Sequence[Expr] = ()) -> bool:
    key = _message_name_key(name)
    disabled_messages = _current_disabled_messages()
    if key in disabled_messages:
        return False
    components = _message_name_components(name)
    if components is not None and components[1]:
        general_name = call("MessageName", symbol("General"), string(components[1][-1]))
        if _message_name_key(general_name) in disabled_messages:
            return False

    message = EvaluationMessage(name=name, text=_message_text(name, text, insertions))
    messages, visible_messages = _current_message_lists()
    messages.append(message)

    suppressed_depth = _quiet_suppression_depth(name)
    for collector in _ACTIVE_MESSAGE_COLLECTORS.get():
        if suppressed_depth is not None and collector.quiet_depth < suppressed_depth:
            continue
        if _message_spec_matches(collector.spec, name):
            collector.messages.append(message)

    if suppressed_depth is None:
        visible_messages.append(message)
        return True
    return False


def _message_name_for_expr(expr: Expr) -> Expr:
    if isinstance(expr, Call) and isinstance(expr.head_expr, Symbol):
        return call("MessageName", symbol(_system_dispatch_name(expr.head_expr)), string("error"))
    if isinstance(expr, Symbol):
        return call("MessageName", symbol(_system_dispatch_name(expr)), string("error"))
    return call("MessageName", symbol("General"), string("error"))


def emit_evaluation_error_message(expr: Expr, error: WolframEvaluationError) -> None:
    emit_message(_message_name_for_expr(expr), str(error))


def _push_quiet_scope(off_spec: Expr, on_spec: Expr) -> object:
    scopes = _ACTIVE_QUIET_SCOPES.get()
    return _ACTIVE_QUIET_SCOPES.set(scopes + (_QuietScope(off_spec=off_spec, on_spec=on_spec),))


def _push_message_collector(spec: Expr) -> tuple[object, _MessageCollector]:
    collectors = _ACTIVE_MESSAGE_COLLECTORS.get()
    collector = _MessageCollector(spec=spec, quiet_depth=len(_ACTIVE_QUIET_SCOPES.get()), messages=[])
    token = _ACTIVE_MESSAGE_COLLECTORS.set(collectors + (collector,))
    return token, collector


def _set_message_enabled(spec: Expr, enabled: bool) -> None:
    disabled = _current_disabled_messages()
    if isinstance(spec, Call) and spec.has_head("List"):
        for item in spec.arguments:
            _set_message_enabled(item, enabled)
        return
    if isinstance(spec, Symbol):
        _set_message_enabled(call("MessageName", spec, string("trace")), enabled)
        return
    if isinstance(spec, Call) and spec.has_head("MessageName"):
        key = _message_name_key(spec)
        if enabled:
            disabled.discard(key)
        else:
            disabled.add(key)
        return
    raise WolframEvaluationError("On and Off expect message names, symbols, or lists of message names.")


def _set_on_off_enabled(spec: Expr, *, enabled: bool) -> None:
    if isinstance(spec, Call) and spec.has_head("List"):
        for item in spec.arguments:
            _set_on_off_enabled(item, enabled=enabled)
        return
    if isinstance(spec, Symbol) and _system_dispatch_name(spec) == "Assert":
        _set_assert_enabled(enabled)
        return
    _set_message_enabled(spec, enabled)


def _current_abort_protect_depth() -> int:
    return len(_ACTIVE_ABORT_PROTECT_SCOPES.get())


def _active_check_abort_handles_current_abort() -> bool:
    check_scopes = _ACTIVE_CHECK_ABORT_SCOPES.get()
    if not check_scopes:
        return False
    return check_scopes[-1].abort_protect_depth == _current_abort_protect_depth()


def _defer_abort_to_current_protect() -> bool:
    scopes = _ACTIVE_ABORT_PROTECT_SCOPES.get()
    if not scopes:
        return False
    scopes[-1].pending_abort = True
    return True


def _time_constraint_remaining_seconds() -> float | None:
    if _TIME_CONSTRAINT_SUPPRESSION_DEPTH.get() > 0:
        return None
    deadlines = [scope.deadline for scope in _ACTIVE_TIME_CONSTRAINTS.get() if scope.deadline is not None]
    if not deadlines:
        return None
    return min(deadline - time.monotonic() for deadline in deadlines)


def _check_time_constraints() -> None:
    remaining = _time_constraint_remaining_seconds()
    if remaining is not None and remaining <= 0:
        raise _TungstenTimeConstraintSignal()


def _parse_real_seconds(expr: Real, function_name: str) -> float:
    text = expr.text
    if "*^" in text:
        mantissa, exponent = text.split("*^", 1)
        mantissa = mantissa.split("`", 1)[0]
        normalized = f"{mantissa}e{exponent}"
    else:
        normalized = text.split("`", 1)[0]
    try:
        return float(normalized)
    except ValueError as exc:
        raise WolframEvaluationError(f"{function_name} expects a numeric time in seconds.") from exc


def _seconds_value(expr: Expr, function_name: str, *, allow_infinity: bool = False) -> float:
    if isinstance(expr, Integer):
        return float(expr.value)
    if isinstance(expr, Real):
        return _parse_real_seconds(expr, function_name)
    if allow_infinity and isinstance(expr, Symbol) and expr.name == "Infinity":
        return math.inf
    raise WolframEvaluationError(f"{function_name} expects a numeric time in seconds.")


def _push_time_constraint(seconds: float) -> object:
    scopes = _ACTIVE_TIME_CONSTRAINTS.get()
    deadline = None if math.isinf(seconds) else time.monotonic() + seconds
    return _ACTIVE_TIME_CONSTRAINTS.set(scopes + (_TimeConstraintScope(deadline=deadline),))


def _all_pattern_expr() -> Expr:
    return call("Blank")


def _abort_protected_time_suppressed(expr: Expr) -> Expr:
    depth = _TIME_CONSTRAINT_SUPPRESSION_DEPTH.get()
    token = _TIME_CONSTRAINT_SUPPRESSION_DEPTH.set(depth + 1)
    try:
        return abort_protect_expr((expr,))
    finally:
        _TIME_CONSTRAINT_SUPPRESSION_DEPTH.reset(token)


_SYMBOL_REGISTRY = SymbolRegistry()


def _system_dispatch_name(expr: Symbol) -> str:
    record = _SYMBOL_REGISTRY.resolve_existing(expr.name)
    if record is not None and record.context == "System`" and record.built_in:
        return record.short_name
    return expr.name


def _is_system_symbol(expr: Expr, name: str) -> bool:
    return isinstance(expr, Symbol) and _system_dispatch_name(expr) == name


def _is_system_infinity(expr: Expr) -> bool:
    return _is_system_symbol(expr, "Infinity")


def _system_setting_record(name: str) -> SymbolRecord | None:
    return _SYMBOL_REGISTRY.resolve_existing(f"System`{name}")


def _system_setting_value(name: str) -> Expr:
    record = _system_setting_record(name)
    if record is not None and record.own_value is not None:
        return record.own_value
    return _SPECIAL_SESSION_SETTING_DEFAULTS[name]


def _finite_system_limit_value(name: str) -> int | None:
    value = _system_setting_value(name)
    if _is_system_infinity(value):
        return None
    if isinstance(value, Integer):
        return value.value
    default_value = _SPECIAL_SESSION_SETTING_DEFAULTS[name]
    return default_value.value if isinstance(default_value, Integer) else None


def _history_length_limit() -> int | None:
    return _finite_system_limit_value("$HistoryLength")


def output_size_limit_value() -> int | None:
    return _finite_system_limit_value("$OutputSizeLimit")


@dataclass(frozen=True)
class Call(Expr):
    head_expr: Expr
    arguments: tuple[Expr, ...]

    def head(self) -> Expr:
        return self.head_expr

    def args(self) -> tuple[Expr, ...]:
        return self.arguments

    def is_atom(self) -> bool:
        return False

    def has_head(self, name: str) -> bool:
        return isinstance(self.head_expr, Symbol) and _system_dispatch_name(self.head_expr) == name

    def to_full_form(self) -> str:
        return f"{self.head_expr.to_full_form()}[{', '.join(arg.to_full_form() for arg in self.arguments)}]"

    def to_input_form(self) -> str:
        return _format_input(self)

    def to_dict(self) -> dict[str, object]:
        return {
            "type": "call",
            "head": self.head_expr.to_dict(),
            "args": [arg.to_dict() for arg in self.arguments],
        }


_PREC_ATOM = 1000
_PREC_CALL = 190
_PREC_PART = 190
_PREC_PATTERN = 185
_PREC_PATTERN_TEST = 184
_PREC_MESSAGE_NAME = 183
_PREC_POSTFIX_UNARY = 175
_PREC_INFIX_FUNCTION = 165
_PREC_POWER = 160
_PREC_PREFIX = 150
_PREC_NONCOMMUTATIVE_TIMES = 145
_PREC_TIMES = 140
_PREC_PLUS = 120
_PREC_COMPARE = 100
_PREC_AND = 80
_PREC_OR = 70
_PREC_ALTERNATIVES = 65
_PREC_STRING_EXPRESSION = 64
_PREC_NAMED_PATTERN = 63
_PREC_CONDITION = 62
_PREC_RULE = 60
_PREC_TWO_WAY_RULE = 61
_PREC_REPLACE = 50
_PREC_MAP = 45
_PREC_APPLY = 44
_PREC_COMPOSITION = 43
_PREC_ASSIGNMENT = 40
_PREC_PUT = 35
_PREC_POSTFIX = 30
_PREC_SEMICOLON = 20
_PREC_FUNCTION = 10
_PREC_LOWEST = 0


_INFIX_OPERATOR_HEADS: dict[str, tuple[str, int, bool, bool]] = {
    "Equal": ("==", _PREC_COMPARE, True, True),
    "Unequal": ("!=", _PREC_COMPARE, True, True),
    "SameQ": ("===", _PREC_COMPARE, True, True),
    "UnsameQ": ("=!=", _PREC_COMPARE, True, True),
    "Less": ("<", _PREC_COMPARE, True, True),
    "LessEqual": ("<=", _PREC_COMPARE, True, True),
    "Greater": (">", _PREC_COMPARE, True, True),
    "GreaterEqual": (">=", _PREC_COMPARE, True, True),
    "And": ("&&", _PREC_AND, False, True),
    "Or": ("||", _PREC_OR, False, True),
    "Alternatives": ("|", _PREC_ALTERNATIVES, False, True),
    "StringExpression": ("~~", _PREC_STRING_EXPRESSION, False, False),
    "TwoWayRule": ("<->", _PREC_TWO_WAY_RULE, True, True),
    "Rule": ("->", _PREC_RULE, True, True),
    "RuleDelayed": (":>", _PREC_RULE, True, True),
    "ReplaceAll": ("/.", _PREC_REPLACE, False, True),
    "ReplaceRepeated": ("//.", _PREC_REPLACE, False, True),
    "Map": ("/@", _PREC_MAP, False, True),
    "MapAll": ("//@", _PREC_MAP, False, True),
    "Apply": ("@@", _PREC_APPLY, False, True),
    "MapApply": ("@@@", _PREC_APPLY, False, True),
    "Composition": ("@*", _PREC_COMPOSITION, True, True),
    "RightComposition": ("/*", _PREC_COMPOSITION, True, True),
    "Set": ("=", _PREC_ASSIGNMENT, True, True),
    "SetDelayed": (":=", _PREC_ASSIGNMENT, True, True),
    "UpSet": ("^=", _PREC_ASSIGNMENT, True, True),
    "UpSetDelayed": ("^:=", _PREC_ASSIGNMENT, True, True),
    "AddTo": ("+=", _PREC_ASSIGNMENT, True, True),
    "SubtractFrom": ("-=", _PREC_ASSIGNMENT, True, True),
    "TimesBy": ("*=", _PREC_ASSIGNMENT, True, True),
    "DivideBy": ("/=", _PREC_ASSIGNMENT, True, True),
    "NonCommutativeMultiply": ("**", _PREC_NONCOMMUTATIVE_TIMES, False, True),
    "Dot": (".", _PREC_TIMES, False, True),
    "StringJoin": ("<>", _PREC_PLUS, False, True),
}


def _format_input(expr: Expr, parent_precedence: int = _PREC_LOWEST) -> str:
    if isinstance(expr, Call):
        text, precedence = _format_call_input(expr)
    elif isinstance(expr, RationalNumber):
        text, precedence = expr.to_input_form(), _PREC_TIMES
    elif isinstance(expr, ComplexNumber):
        text, precedence = expr.to_input_form(), _PREC_PLUS
    else:
        text, precedence = expr.to_input_form(), _PREC_ATOM

    if precedence < parent_precedence:
        return f"({text})"
    return text


def _format_call_input(expr: Call) -> tuple[str, int]:
    slot_name = _format_slot_name_shorthand(expr)
    if slot_name is not None:
        return slot_name, _PREC_ATOM

    derivative = _format_derivative(expr)
    if derivative is not None:
        return derivative, _PREC_POSTFIX_UNARY

    if isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        arguments = expr.arguments

        if head_name == "List":
            return "{" + ", ".join(_format_input(arg) for arg in arguments) + "}", _PREC_ATOM
        if head_name == "Association":
            return "<|" + ", ".join(_format_input(arg) for arg in arguments) + "|>", _PREC_ATOM
        if head_name in {"Blank", "BlankSequence", "BlankNullSequence"}:
            formatted_blank = _format_blank(head_name, arguments)
            if formatted_blank is not None:
                return formatted_blank, _PREC_ATOM
        if head_name == "Slot":
            formatted_slot = _format_slot(arguments)
            if formatted_slot is not None:
                return formatted_slot, _PREC_ATOM
        if head_name == "SlotSequence":
            formatted_slot_sequence = _format_slot_sequence(arguments)
            if formatted_slot_sequence is not None:
                return formatted_slot_sequence, _PREC_ATOM
        if head_name == "Out":
            formatted_out = _format_out(arguments)
            if formatted_out is not None:
                return formatted_out, _PREC_ATOM
        if head_name == "Pattern" and len(arguments) == 2 and isinstance(arguments[0], Symbol):
            return _format_pattern(arguments[0], arguments[1]), _PREC_PATTERN
        if head_name == "PatternTest" and len(arguments) == 2:
            return (
                f"{_format_input(arguments[0], _PREC_PATTERN_TEST)}?{_format_input(arguments[1], _PREC_PATTERN_TEST + 1)}",
                _PREC_PATTERN_TEST,
            )
        if head_name == "Optional" and len(arguments) == 1:
            return f"{_format_input(arguments[0], _PREC_PATTERN)}.", _PREC_PATTERN
        if head_name == "Optional" and len(arguments) == 2:
            return (
                f"{_format_input(arguments[0], _PREC_NAMED_PATTERN)}:{_format_input(arguments[1], _PREC_NAMED_PATTERN)}",
                _PREC_NAMED_PATTERN,
            )
        if head_name == "Repeated" and len(arguments) == 1:
            return f"{_format_input(arguments[0], _PREC_POSTFIX)}..", _PREC_POSTFIX
        if head_name == "RepeatedNull" and len(arguments) == 1:
            return f"{_format_input(arguments[0], _PREC_POSTFIX)}...", _PREC_POSTFIX
        if head_name == "Condition" and len(arguments) == 2:
            return (
                f"{_format_input(arguments[0], _PREC_CONDITION)} /; {_format_input(arguments[1], _PREC_CONDITION + 1)}",
                _PREC_CONDITION,
            )
        if head_name == "Function":
            formatted_function = _format_function(arguments)
            if formatted_function is not None:
                return formatted_function
        if head_name == "Information" and len(arguments) == 2:
            formatted_information = _format_information(arguments)
            if formatted_information is not None:
                return formatted_information, _PREC_PREFIX
        if head_name == "Get" and len(arguments) == 1:
            formatted_file_name = _format_file_name(arguments[0])
            if formatted_file_name is not None:
                return f"<< {formatted_file_name}", _PREC_PREFIX
        if head_name == "MessageName" and len(arguments) >= 2:
            formatted_message_name = _format_message_name(arguments)
            if formatted_message_name is not None:
                return formatted_message_name, _PREC_MESSAGE_NAME
        if head_name in {"Put", "PutAppend"} and len(arguments) == 2:
            formatted_put = _format_put(head_name, arguments)
            if formatted_put is not None:
                return formatted_put, _PREC_PUT
        if head_name in {"TagSet", "TagSetDelayed", "TagUnset"}:
            formatted_tag_set = _format_tag_set(head_name, arguments)
            if formatted_tag_set is not None:
                return formatted_tag_set, _PREC_ASSIGNMENT
        if head_name in {"Increment", "Decrement", "Factorial", "Factorial2", "Unset"} and len(arguments) == 1:
            operator = {
                "Increment": "++",
                "Decrement": "--",
                "Factorial": "!",
                "Factorial2": "!!",
                "Unset": "=.",
            }[head_name]
            separator = " " if head_name == "Unset" else ""
            return f"{_format_input(arguments[0], _PREC_POSTFIX_UNARY)}{separator}{operator}", _PREC_POSTFIX_UNARY
        if head_name in {"PreIncrement", "PreDecrement"} and len(arguments) == 1:
            operator = "++" if head_name == "PreIncrement" else "--"
            return f"{operator}{_format_input(arguments[0], _PREC_POSTFIX_UNARY)}", _PREC_POSTFIX_UNARY
        if head_name in _INFIX_OPERATOR_HEADS and len(arguments) >= 2:
            operator, precedence, right_associative, spaced = _INFIX_OPERATOR_HEADS[head_name]
            return _format_infix(arguments, operator, precedence, right_associative=right_associative, spaced=spaced), precedence
        escaped_operator = _ESCAPED_INFIX_OPERATOR_TOKENS_BY_HEAD.get(head_name)
        if escaped_operator is not None and len(arguments) >= 2:
            precedence = _escaped_infix_operator_precedence(head_name)
            return _format_escaped_infix(arguments, escaped_operator, precedence), precedence
        if head_name == "Plus" and arguments:
            return _format_plus(arguments), _PREC_PLUS
        if head_name == "Times" and arguments:
            return _format_times(arguments), _PREC_TIMES
        if head_name == "Power" and len(arguments) == 2:
            return _format_power(arguments[0], arguments[1]), _PREC_POWER
        if head_name == "Not" and len(arguments) == 1:
            return "!" + _format_input(arguments[0], _PREC_PREFIX), _PREC_PREFIX
        if head_name == "Span" and arguments:
            return _format_span(arguments), _PREC_FUNCTION
        if head_name == "Part" and len(arguments) >= 1:
            target = _format_input(arguments[0], _PREC_PART)
            spec = ", ".join(_format_input(arg) for arg in arguments[1:])
            return f"{target}[[{spec}]]", _PREC_PART

    if isinstance(expr.head_expr, Call) and _format_derivative(expr.head_expr) is not None:
        head = _format_input(expr.head_expr)
    else:
        head = _format_input(expr.head_expr, _PREC_CALL)
    args = ", ".join(_format_input(arg) for arg in expr.arguments)
    return f"{head}[{args}]", _PREC_CALL


def _format_derivative(expr: Call) -> str | None:
    if len(expr.arguments) != 1:
        return None
    if not isinstance(expr.head_expr, Call) or not expr.head_expr.has_head("Derivative"):
        return None
    orders = expr.head_expr.arguments
    if len(orders) != 1 or not isinstance(orders[0], Integer) or orders[0].value <= 0:
        return None
    primes = "'" * orders[0].value
    return f"{_format_input(expr.arguments[0], _PREC_POSTFIX_UNARY)}{primes}"


def _format_infix(
    arguments: Sequence[Expr],
    operator: str,
    precedence: int,
    *,
    right_associative: bool,
    spaced: bool,
) -> str:
    separator = f" {operator} " if spaced else operator
    pieces: list[str] = []
    last_index = len(arguments) - 1
    for index, argument in enumerate(arguments):
        if right_associative:
            operand_precedence = precedence + 1 if index == 0 else precedence
        else:
            operand_precedence = precedence if index == 0 else precedence + 1
        if 0 < index < last_index:
            operand_precedence = precedence + 1
        pieces.append(_format_input(argument, operand_precedence))
    return separator.join(pieces)


def _format_escaped_infix(
    arguments: Sequence[Expr],
    operator: str,
    precedence: int,
) -> str:
    pieces: list[str] = []
    for argument in arguments:
        operand = _format_input(argument)
        if _infix_argument_needs_parentheses(argument, precedence):
            operand = f"({operand})"
        pieces.append(operand)
    return f" {operator} ".join(pieces)


def _input_form_precedence(expr: Expr) -> int:
    if isinstance(expr, Call):
        return _format_call_input(expr)[1]
    if isinstance(expr, RationalNumber):
        return _PREC_TIMES
    if isinstance(expr, ComplexNumber):
        return _PREC_PLUS
    return _PREC_ATOM


def _escaped_infix_operator_precedence(head_name: str) -> int:
    return _ESCAPED_INFIX_OPERATOR_PRECEDENCES.get(head_name, _PREC_COMPARE)


def _infix_argument_needs_parentheses(argument: Expr, precedence: int) -> bool:
    argument_precedence = _input_form_precedence(argument)
    if argument_precedence < precedence:
        return True
    return argument_precedence == precedence and isinstance(argument, Call)


def _format_information(arguments: Sequence[Expr]) -> str | None:
    name, option = arguments
    if not isinstance(name, String):
        return None
    if not isinstance(option, Call) or not option.has_head("Rule") or len(option.arguments) != 2:
        return None
    option_name, option_value = option.arguments
    if not isinstance(option_name, Symbol) or option_name.name != "LongForm":
        return None
    if isinstance(option_value, Symbol) and option_value.name == "False":
        prefix = "?"
    elif isinstance(option_value, Symbol) and option_value.name == "True":
        prefix = "??"
    else:
        return None
    formatted_name = _format_file_name(name)
    if formatted_name is None:
        return None
    return prefix + formatted_name


def _format_message_name(arguments: Sequence[Expr]) -> str | None:
    base = _format_input(arguments[0], _PREC_MESSAGE_NAME)
    tags: list[str] = []
    for tag in arguments[1:]:
        formatted_tag = _format_message_tag(tag)
        if formatted_tag is None:
            return None
        tags.append(formatted_tag)
    return base + "".join(f"::{tag}" for tag in tags)


def _format_message_tag(expr: Expr) -> str | None:
    if isinstance(expr, String):
        if _is_simple_symbol_name(expr.value):
            return expr.value
        return expr.to_input_form()
    if isinstance(expr, Symbol):
        return expr.to_input_form()
    return None


def _format_file_name(expr: Expr) -> str | None:
    if isinstance(expr, String):
        if _is_simple_file_name(expr.value):
            return expr.value
        return expr.to_input_form()
    if isinstance(expr, Symbol):
        return expr.to_input_form()
    return None


def _format_put(head_name: str, arguments: Sequence[Expr]) -> str | None:
    formatted_file_name = _format_file_name(arguments[1])
    if formatted_file_name is None:
        return None
    operator = ">>>" if head_name == "PutAppend" else ">>"
    return f"{_format_input(arguments[0], _PREC_PUT)} {operator} {formatted_file_name}"


def _format_tag_set(head_name: str, arguments: Sequence[Expr]) -> str | None:
    if head_name == "TagUnset" and len(arguments) == 2:
        return (
            f"{_format_input(arguments[0], _PREC_ASSIGNMENT + 1)} /: "
            f"{_format_input(arguments[1], _PREC_ASSIGNMENT + 1)} =."
        )
    if head_name not in {"TagSet", "TagSetDelayed"} or len(arguments) != 3:
        return None
    operator = "=" if head_name == "TagSet" else ":="
    return (
        f"{_format_input(arguments[0], _PREC_ASSIGNMENT + 1)} /: "
        f"{_format_input(arguments[1], _PREC_ASSIGNMENT + 1)} {operator} "
        f"{_format_input(arguments[2], _PREC_ASSIGNMENT)}"
    )


def _is_simple_symbol_name(value: str) -> bool:
    return re.fullmatch(r"[$A-Za-z][$A-Za-z0-9]*", value) is not None


def _is_simple_file_name(value: str) -> bool:
    return re.fullmatch(r"[$A-Za-z0-9_./\\-]+", value) is not None


def _format_blank(head_name: str, arguments: Sequence[Expr]) -> str | None:
    prefix = {
        "Blank": "_",
        "BlankSequence": "__",
        "BlankNullSequence": "___",
    }[head_name]
    if len(arguments) == 0:
        return prefix
    if len(arguments) == 1 and isinstance(arguments[0], Symbol):
        return prefix + arguments[0].to_input_form()
    return None


def _format_pattern(name: Symbol, pattern: Expr) -> str:
    if isinstance(pattern, Call) and isinstance(pattern.head_expr, Symbol):
        head_name = _system_dispatch_name(pattern.head_expr)
        if head_name in {"Blank", "BlankSequence", "BlankNullSequence"}:
            formatted_blank = _format_blank(head_name, pattern.arguments)
            if formatted_blank is not None:
                return f"{name.to_input_form()}{formatted_blank}"
    return f"{name.to_input_form()} : {_format_input(pattern, _PREC_NAMED_PATTERN)}"


def _format_function(arguments: Sequence[Expr]) -> tuple[str, int] | None:
    if len(arguments) == 1:
        return f"{_format_input(arguments[0], _PREC_FUNCTION + 1)} &", _PREC_FUNCTION
    if len(arguments) == 2:
        parameters, body = arguments
        return (
            f"{_format_function_parameters(parameters)} |-> {_format_input(body, _PREC_FUNCTION)}",
            _PREC_FUNCTION,
        )
    return None


def _format_function_parameters(parameters: Expr) -> str:
    if isinstance(parameters, Call) and parameters.has_head("List"):
        return "{" + ", ".join(_format_input(parameter) for parameter in parameters.arguments) + "}"
    return _format_input(parameters, _PREC_FUNCTION + 1)


def _format_slot(arguments: Sequence[Expr]) -> str | None:
    if len(arguments) == 0:
        return "#"
    if len(arguments) == 1 and isinstance(arguments[0], Integer):
        if arguments[0].value == 1:
            return "#"
        return f"#{arguments[0].value}"
    if len(arguments) == 1 and isinstance(arguments[0], String) and _is_simple_slot_name(arguments[0].value):
        return f"#{arguments[0].value}"
    return None


def _format_slot_sequence(arguments: Sequence[Expr]) -> str | None:
    if len(arguments) == 0:
        return "##"
    if len(arguments) == 1 and isinstance(arguments[0], Integer):
        if arguments[0].value == 1:
            return "##"
        return f"##{arguments[0].value}"
    return None


def _format_slot_name_shorthand(expr: Call) -> str | None:
    if len(expr.arguments) != 1 or not isinstance(expr.arguments[0], String):
        return None
    if not isinstance(expr.head_expr, Call) or not expr.head_expr.has_head("Slot"):
        return None
    if len(expr.head_expr.arguments) != 1:
        return None
    slot_index = expr.head_expr.arguments[0]
    if not isinstance(slot_index, Integer) or slot_index.value != 1:
        return None
    if not _is_simple_slot_name(expr.arguments[0].value):
        return None
    return f"#{expr.arguments[0].value}"


def _is_simple_slot_name(value: str) -> bool:
    return re.fullmatch(r"[$A-Za-z][$A-Za-z0-9]*", value) is not None


def _format_out(arguments: Sequence[Expr]) -> str | None:
    if len(arguments) == 0:
        # Bare ``Out[]`` round-trips through the ``%`` shorthand so explicit
        # ``Out[]`` and the parsed form share the same input-form rendering.
        return "%"
    if len(arguments) != 1 or not isinstance(arguments[0], Integer):
        return None
    line = arguments[0].value
    if line < 0:
        return "%" * abs(line)
    return None


def _format_plus(arguments: Sequence[Expr]) -> str:
    pieces: list[str] = []
    for index, argument in enumerate(arguments):
        if _is_negative_term(argument):
            stripped = _strip_negative_term(argument)
            if index == 0:
                formatted = _format_input(stripped, _PREC_PREFIX)
                pieces.append("-" + formatted)
            else:
                formatted = _format_input(stripped, _PREC_PLUS + 1)
                pieces.append("- " + formatted)
        elif index == 0:
            pieces.append(_format_input(argument, _PREC_PLUS))
        else:
            pieces.append("+ " + _format_input(argument, _PREC_PLUS + 1))
    return " ".join(pieces)


def _format_times(arguments: Sequence[Expr]) -> str:
    if len(arguments) == 2:
        denominator = _inverse_denominator(arguments[1])
        if denominator is not None:
            return f"{_format_input(arguments[0], _PREC_TIMES)} / {_format_input(denominator, _PREC_TIMES + 1)}"

    if arguments and isinstance(arguments[0], Integer) and arguments[0].value == -1:
        stripped = arguments[1] if len(arguments) == 2 else call("Times", *arguments[1:])
        if len(arguments) == 2:
            return "-" + _format_input(stripped, _PREC_PREFIX)
        return "-" + _format_input(stripped, _PREC_PREFIX)

    return " * ".join(_format_input(argument, _PREC_TIMES + (0 if index == 0 else 1)) for index, argument in enumerate(arguments))


def _inverse_denominator(expr: Expr) -> Expr | None:
    if (
        isinstance(expr, Call)
        and expr.has_head("Power")
        and len(expr.arguments) == 2
        and isinstance(expr.arguments[1], Integer)
        and expr.arguments[1].value == -1
    ):
        return expr.arguments[0]
    return None


def _format_power(base: Expr, exponent: Expr) -> str:
    formatted_base = _format_input(base, _PREC_POWER + 1)
    if isinstance(exponent, Integer) and exponent.value < 0:
        formatted_exponent = f"({exponent.to_input_form()})"
    else:
        formatted_exponent = _format_input(exponent, _PREC_POWER)
    return f"{formatted_base}^{formatted_exponent}"


def _is_negative_term(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and len(expr.arguments) >= 1
        and isinstance(expr.arguments[0], Integer)
        and expr.arguments[0].value == -1
    )


def _strip_negative_term(expr: Expr) -> Expr:
    if not _is_negative_term(expr):
        return expr

    assert isinstance(expr, Call)
    if len(expr.arguments) == 2:
        return expr.arguments[1]
    return call("Times", *expr.arguments[1:])


def _format_span(arguments: Sequence[Expr]) -> str:
    if len(arguments) == 2:
        start, end = arguments
        if isinstance(start, Integer) and start.value == 1 and isinstance(end, Symbol) and end.name == "All":
            return ";;"
        if isinstance(start, Integer) and start.value == 1:
            return f";; {end.to_input_form()}"
        if isinstance(end, Symbol) and end.name == "All":
            return f"{start.to_input_form()} ;;"
        return f"{start.to_input_form()} ;; {end.to_input_form()}"

    if len(arguments) == 3:
        start, end, step = arguments
        return f"{start.to_input_form()} ;; {end.to_input_form()} ;; {step.to_input_form()}"

    return "Span[" + ", ".join(arg.to_input_form() for arg in arguments) + "]"


def symbol(name: str) -> Symbol:
    try:
        _SYMBOL_REGISTRY.ensure_name(name)
    except WolframEvaluationError:
        # Existing AST code uses a few structural pseudo-symbol spellings, such as
        # -Infinity, that are not constructible Wolfram identifiers. Keep the atom;
        # user-facing Symbol["..."] validation still goes through the registry.
        pass
    return Symbol(name)


def integer(value: int) -> Integer:
    return Integer(int(value))


def real(text: str) -> Real:
    return Real(text)


def rational_number(numerator: int, denominator: int) -> Expr:
    numerator = int(numerator)
    denominator = int(denominator)
    if denominator == 0:
        return symbol("Indeterminate") if numerator == 0 else symbol("ComplexInfinity")
    value = Fraction(numerator, denominator)
    if value.denominator == 1:
        return integer(value.numerator)
    return RationalNumber(value)


def complex_number(real_part: Expr, imaginary_part: Expr) -> Expr:
    if _is_exact_zero(imaginary_part):
        return real_part
    if _is_machine_real_atom(real_part) or _is_machine_real_atom(imaginary_part):
        real_part = _exact_to_real(real_part, None) if _is_exact_real_number(real_part) else real_part
        imaginary_part = _exact_to_real(imaginary_part, None) if _is_exact_real_number(imaginary_part) else imaginary_part
        if isinstance(real_part, Real):
            real_info = _real_info(real_part)
            if real_info is not None and real_info.precision is not None:
                real_part = _machine_real(float(real_info.value))
        if isinstance(imaginary_part, Real):
            imaginary_info = _real_info(imaginary_part)
            if imaginary_info is not None and imaginary_info.precision is not None:
                imaginary_part = _machine_real(float(imaginary_info.value))
    return ComplexNumber(real_part, imaginary_part)


def root_number(coefficients: Sequence[int], index: int, method: int = 0) -> RootNumber:
    normalized = tuple(int(coefficient) for coefficient in coefficients)
    if len(normalized) < 2 or normalized[-1] == 0:
        raise WolframEvaluationError("Root expects a nonconstant polynomial with nonzero leading coefficient.")
    if index < 0:
        raise WolframEvaluationError("Root index must be positive.")
    return RootNumber(normalized, int(index), int(method))


def _polynomial_expr_from_coefficients(coefficients: Sequence[int], variable: Expr) -> Expr:
    terms: list[Expr] = []
    for exponent, coefficient in enumerate(coefficients):
        if coefficient == 0:
            continue
        coefficient_expr = integer(coefficient)
        if exponent == 0:
            terms.append(coefficient_expr)
            continue
        power_expr = variable if exponent == 1 else call("Power", variable, integer(exponent))
        if coefficient == 1:
            terms.append(power_expr)
        elif coefficient == -1:
            terms.append(call("Times", integer(-1), power_expr))
        else:
            terms.append(call("Times", coefficient_expr, power_expr))
    if not terms:
        return integer(0)
    return call("Plus", *terms)


def special_real(name: str) -> SpecialReal:
    if name not in {"Overflow", "Underflow"}:
        raise WolframEvaluationError(f"Unsupported special real atom: {name}.")
    return SpecialReal(name)


def string(value: str) -> String:
    return String(value)


def byte_array_expr(values: Iterable[int]) -> ByteArrayExpr:
    normalized = tuple(int(value) for value in values)
    for value in normalized:
        if value < 0 or value > 255:
            raise WolframEvaluationError("ByteArray values must be integers between 0 and 255.")
    return ByteArrayExpr(normalized)


_FLAT_HEADS = {"Alternatives", "CompoundExpression"}

_LEVEL_INFINITY = 1_000_000_000
_MISSING = object()
_ESCAPED_TOKEN_MAP = {
    r"\[And]": "&&",
    r"\[Equal]": "==",
    r"\[Function]": "|->",
    r"\[GreaterEqual]": ">=",
    r"\[InvisibleApplication]": "@",
    r"\[InvisibleTimes]": "*",
    r"\[Rule]": "->",
    r"\[RuleDelayed]": ":>",
    r"\[LessEqual]": "<=",
    r"\[LeftAssociation]": "<|",
    r"\[NotEqual]": "!=",
    r"\[Or]": "||",
    r"\[RightAssociation]": "|>",
}


_ESCAPED_SYMBOL_ALIASES = {
    r"\[Degree]": "Degree",
    r"\[ExponentialE]": "E",
    r"\[ImaginaryI]": "I",
    r"\[ImaginaryJ]": "I",
    r"\[Infinity]": "Infinity",
    r"\[Pi]": "Pi",
}


_ESCAPED_INFIX_OPERATOR_HEADS = {
    r"\[CenterDot]": "CenterDot",
    r"\[CircleDot]": "CircleDot",
    r"\[CircleMinus]": "CircleMinus",
    r"\[CirclePlus]": "CirclePlus",
    r"\[CircleTimes]": "CircleTimes",
    r"\[Congruent]": "Congruent",
    r"\[Cross]": "Cross",
    r"\[Diamond]": "Diamond",
    r"\[DirectedEdge]": "DirectedEdge",
    r"\[DiscreteRatio]": "DiscreteRatio",
    r"\[DiscreteShift]": "DiscreteShift",
    r"\[DoubleLeftArrow]": "DoubleLeftArrow",
    r"\[DoubleLeftRightArrow]": "DoubleLeftRightArrow",
    r"\[DoubleRightArrow]": "DoubleRightArrow",
    r"\[DoubleVerticalBar]": "DoubleVerticalBar",
    r"\[DownArrow]": "DownArrow",
    r"\[Element]": "Element",
    r"\[Equivalent]": "Equivalent",
    r"\[Implies]": "Implies",
    r"\[Intersection]": "Intersection",
    r"\[LeftArrow]": "LeftArrow",
    r"\[LeftRightArrow]": "LeftRightArrow",
    r"\[LessEqualGreater]": "LessEqualGreater",
    r"\[LongLeftArrow]": "LongLeftArrow",
    r"\[LongLeftRightArrow]": "LongLeftRightArrow",
    r"\[LongRightArrow]": "LongRightArrow",
    r"\[MinusPlus]": "MinusPlus",
    r"\[NotElement]": "NotElement",
    r"\[NotSubset]": "NotSubset",
    r"\[NotSubsetEqual]": "NotSubsetEqual",
    r"\[NotSuperset]": "NotSuperset",
    r"\[NotSupersetEqual]": "NotSupersetEqual",
    r"\[PlusMinus]": "PlusMinus",
    r"\[Precedes]": "Precedes",
    r"\[PrecedesEqual]": "PrecedesEqual",
    r"\[Proportion]": "Proportion",
    r"\[RightArrow]": "RightArrow",
    r"\[SmallCircle]": "SmallCircle",
    r"\[SquareIntersection]": "SquareIntersection",
    r"\[SquareSubset]": "SquareSubset",
    r"\[SquareSubsetEqual]": "SquareSubsetEqual",
    r"\[SquareSuperset]": "SquareSuperset",
    r"\[SquareSupersetEqual]": "SquareSupersetEqual",
    r"\[SquareUnion]": "SquareUnion",
    r"\[Star]": "Star",
    r"\[Subset]": "Subset",
    r"\[SubsetEqual]": "SubsetEqual",
    r"\[Succeeds]": "Succeeds",
    r"\[SucceedsEqual]": "SucceedsEqual",
    r"\[Superset]": "Superset",
    r"\[SupersetEqual]": "SupersetEqual",
    r"\[TensorProduct]": "TensorProduct",
    r"\[Tilde]": "Tilde",
    r"\[TildeEqual]": "TildeEqual",
    r"\[TildeFullEqual]": "TildeFullEqual",
    r"\[TildeTilde]": "TildeTilde",
    r"\[UndirectedEdge]": "UndirectedEdge",
    r"\[Union]": "Union",
    r"\[UnionPlus]": "UnionPlus",
    r"\[UpArrow]": "UpArrow",
    r"\[Vee]": "Vee",
    r"\[VerticalBar]": "VerticalBar",
    r"\[VerticalSeparator]": "VerticalSeparator",
    r"\[Wedge]": "Wedge",
}


_ADDITIONAL_ESCAPED_INFIX_OPERATOR_HEAD_NAMES = {
    "Backslash",
    "Because",
    "Cap",
    "Coproduct",
    "Cup",
    "CupCap",
    "Del",
    "DotEqual",
    "DoubleDownArrow",
    "DoubleLeftTee",
    "DoubleLongLeftArrow",
    "DoubleLongLeftRightArrow",
    "DoubleLongRightArrow",
    "DoubleUpArrow",
    "DoubleUpDownArrow",
    "DownArrowBar",
    "DownArrowUpArrow",
    "DownLeftRightVector",
    "DownLeftTeeVector",
    "DownLeftVector",
    "DownLeftVectorBar",
    "DownRightTeeVector",
    "DownRightVector",
    "DownRightVectorBar",
    "DownTee",
    "DownTeeArrow",
    "EqualTilde",
    "Equilibrium",
    "GreaterEqualLess",
    "GreaterFullEqual",
    "GreaterGreater",
    "GreaterLess",
    "GreaterSlantEqual",
    "GreaterTilde",
    "HumpDownHump",
    "HumpEqual",
    "LeftArrowBar",
    "LeftArrowRightArrow",
    "LeftDownTeeVector",
    "LeftDownVector",
    "LeftDownVectorBar",
    "LeftTee",
    "LeftTeeArrow",
    "LeftTeeVector",
    "LeftTriangle",
    "LeftTriangleBar",
    "LeftTriangleEqual",
    "LeftUpDownVector",
    "LeftUpTeeVector",
    "LeftUpVector",
    "LeftUpVectorBar",
    "LeftVector",
    "LeftVectorBar",
    "LessFullEqual",
    "LessGreater",
    "LessLess",
    "LessSlantEqual",
    "LessTilde",
    "LowerLeftArrow",
    "LowerRightArrow",
    "Nand",
    "NestedGreaterGreater",
    "NestedLessLess",
    "Nor",
    "NotCongruent",
    "NotCupCap",
    "NotDoubleVerticalBar",
    "NotGreater",
    "NotGreaterEqual",
    "NotGreaterFullEqual",
    "NotGreaterLess",
    "NotGreaterTilde",
    "NotLeftTriangle",
    "NotLeftTriangleEqual",
    "NotLess",
    "NotLessEqual",
    "NotLessFullEqual",
    "NotLessGreater",
    "NotLessTilde",
    "NotPrecedes",
    "NotPrecedesSlantEqual",
    "NotPrecedesTilde",
    "NotReverseElement",
    "NotRightTriangle",
    "NotRightTriangleEqual",
    "NotSquareSubsetEqual",
    "NotSquareSupersetEqual",
    "NotSucceeds",
    "NotSucceedsSlantEqual",
    "NotSucceedsTilde",
    "NotTilde",
    "NotTildeEqual",
    "NotTildeFullEqual",
    "NotTildeTilde",
    "Perpendicular",
    "PrecedesSlantEqual",
    "PrecedesTilde",
    "Proportional",
    "ReverseElement",
    "ReverseEquilibrium",
    "ReverseUpEquilibrium",
    "RightArrowBar",
    "RightArrowLeftArrow",
    "RightDownTeeVector",
    "RightDownVector",
    "RightDownVectorBar",
    "RightTee",
    "RightTeeArrow",
    "RightTeeVector",
    "RightTriangle",
    "RightTriangleBar",
    "RightTriangleEqual",
    "RightUpDownVector",
    "RightUpTeeVector",
    "RightUpVector",
    "RightUpVectorBar",
    "RightVector",
    "RightVectorBar",
    "RoundImplies",
    "ShortDownArrow",
    "ShortLeftArrow",
    "ShortRightArrow",
    "ShortUpArrow",
    "Square",
    "SuchThat",
    "SucceedsSlantEqual",
    "SucceedsTilde",
    "Therefore",
    "UpArrowBar",
    "UpArrowDownArrow",
    "UpDownArrow",
    "UpEquilibrium",
    "UpTee",
    "UpTeeArrow",
    "UpperLeftArrow",
    "UpperRightArrow",
    "VerticalTilde",
    "Xor",
}

_ESCAPED_INFIX_OPERATOR_HEADS.update(
    {f"\\[{name}]": name for name in _ADDITIONAL_ESCAPED_INFIX_OPERATOR_HEAD_NAMES}
)

_ESCAPED_INFIX_OPERATOR_TOKENS_BY_HEAD = {
    head_name: escaped_token
    for escaped_token, head_name in _ESCAPED_INFIX_OPERATOR_HEADS.items()
}

_ESCAPED_INFIX_OPERATOR_PRECEDENCES = {
    "CirclePlus": 125,
    "CircleTimes": 142,
    "Diamond": 144,
}

_ESCAPED_INFIX_TEX_OPERATORS = {
    "CirclePlus": r"\oplus",
    "CircleTimes": r"\otimes",
    "Diamond": r"\diamond",
}

_TEX_INFIX_OPERATOR_TOKENS = {
    tex_operator: _ESCAPED_INFIX_OPERATOR_TOKENS_BY_HEAD[head_name]
    for head_name, tex_operator in _ESCAPED_INFIX_TEX_OPERATORS.items()
}

_ESCAPED_INFIX_MATHML_OPERATOR_ENTITIES = {
    "CirclePlus": "&#8853;",
    "CircleTimes": "&#8855;",
    "Diamond": "&#8900;",
}

_MATHML_OPERATOR_TEXT_TOKENS = {
    "\u2295": r"\[CirclePlus]",
    "\u2297": r"\[CircleTimes]",
    "\u22c4": r"\[Diamond]",
    "&#8853;": r"\[CirclePlus]",
    "&#8855;": r"\[CircleTimes]",
    "&#8900;": r"\[Diamond]",
}

for _escaped_operator_head in set(_ESCAPED_INFIX_OPERATOR_HEADS.values()):
    try:
        _SYMBOL_REGISTRY.ensure_full_name(f"System`{_escaped_operator_head}", built_in=True)
    except WolframEvaluationError:
        pass


def call(head: str | Expr, *arguments: Expr) -> Call:
    head_expr = Symbol(head) if isinstance(head, str) else head
    normalized: list[Expr] = []
    if isinstance(head_expr, Symbol) and head_expr.name in _FLAT_HEADS:
        for argument in arguments:
            if isinstance(argument, Call) and argument.has_head(head_expr.name):
                normalized.extend(argument.arguments)
            else:
                normalized.append(argument)
    else:
        normalized.extend(arguments)

    return Call(head_expr=head_expr, arguments=tuple(normalized))


def list_expr(*items: Expr) -> Call:
    return call("List", *items)


def _evaluated_list_expr(*items: Expr) -> Call:
    # Raw parser lists must preserve Nothing in held syntax. Evaluator-created
    # lists instead mirror Wolfram's ordinary List construction behavior.
    arguments = _normalize_arguments_for_head("List", items, evaluated=True)
    return call("List", *arguments)


@dataclass(frozen=True)
class _AssociationEntry:
    rule_head: str
    key: Expr
    value: Expr

    def to_expr(self) -> Expr:
        return call(self.rule_head, self.key, self.value)


@dataclass(frozen=True)
class _IndexSelector:
    index: int


@dataclass(frozen=True)
class _KeySelector:
    key: Expr


@dataclass(frozen=True)
class _SelectedPart:
    selector: _IndexSelector | _KeySelector
    child: Expr
    entry: _AssociationEntry | None = None


@dataclass(frozen=True)
class _SelectionItem:
    index: int
    value: Expr
    entry: _AssociationEntry | None = None


def _rule_entry(expr: Expr) -> _AssociationEntry | None:
    if not isinstance(expr, Call):
        return None
    if not expr.has_head("Rule") and not expr.has_head("RuleDelayed"):
        return None
    if len(expr.arguments) != 2:
        return None
    return _AssociationEntry(
        rule_head=expr.head_expr.name,
        key=expr.arguments[0],
        value=expr.arguments[1],
    )


def _association_entries(expr: Expr) -> tuple[_AssociationEntry, ...] | None:
    if not isinstance(expr, Call) or not expr.has_head("Association"):
        return None

    entries: list[_AssociationEntry] = []
    for argument in expr.arguments:
        entry = _rule_entry(argument)
        if entry is None:
            return None
        entries.append(entry)
    return tuple(entries)


def _is_association(expr: Expr) -> bool:
    return _association_entries(expr) is not None


def _normalize_association_entries(entries: Iterable[_AssociationEntry]) -> tuple[_AssociationEntry, ...]:
    ordered: list[_AssociationEntry] = []
    first_positions: dict[Expr, int] = {}

    for entry in entries:
        previous = first_positions.get(entry.key)
        if previous is None:
            first_positions[entry.key] = len(ordered)
            ordered.append(entry)
        else:
            # Wolfram associations keep the key's first slot and update the value.
            ordered[previous] = entry

    return tuple(ordered)


def _association_expr(entries: Iterable[_AssociationEntry]) -> Call:
    normalized = _normalize_association_entries(entries)
    return call("Association", *(entry.to_expr() for entry in normalized))


def _association_entry_map(entries: Sequence[_AssociationEntry]) -> dict[Expr, _AssociationEntry]:
    return {entry.key: entry for entry in entries}


def _association_values(expr: Expr) -> tuple[Expr, ...]:
    entries = _association_entries(expr)
    if entries is None:
        raise WolframEvaluationError(f"Expected an association, got {expr.to_input_form()}.")
    return tuple(entry.value for entry in entries)


def _association_from_arguments(arguments: Sequence[Expr]) -> Call | None:
    entries: list[_AssociationEntry] = []

    if len(arguments) == 1:
        source = arguments[0]
        nested_entries = _association_entries(source)
        if nested_entries is not None:
            return _association_expr(nested_entries)
        if isinstance(source, Call) and source.has_head("List"):
            for item in source.arguments:
                entry = _rule_entry(item)
                if entry is None:
                    return None
                entries.append(entry)
            return _association_expr(entries)

    for argument in arguments:
        nested_entries = _association_entries(argument)
        if nested_entries is not None:
            entries.extend(nested_entries)
            continue
        entry = _rule_entry(argument)
        if entry is None:
            return None
        entries.append(entry)

    return _association_expr(entries)


def _build_sparse_backend(
    dimensions: Sequence[int],
    entries: Sequence[_SparseArrayEntry],
    fill_value: Expr,
) -> object | None:
    try:
        import numpy as np
        import sparse as sparse_module
    except Exception:
        return None

    try:
        rank = len(dimensions)
        coords = np.empty((rank, len(entries)), dtype=np.int64)
        data = np.empty((len(entries),), dtype=object)
        for column, entry in enumerate(entries):
            for axis, index in enumerate(entry.indices):
                coords[axis, column] = index - 1
            data[column] = entry.value
        return sparse_module.COO(
            coords,
            data,
            shape=tuple(dimensions),
            fill_value=fill_value,
            has_duplicates=False,
            sorted=True,
            prune=False,
        )
    except Exception:
        return None


def _sparse_array_constructor_call(array: SparseArrayExpr) -> Call:
    rules = list_expr(*(
        call("Rule", list_expr(*(integer(index) for index in entry.indices)), entry.value)
        for entry in array.entries
    ))
    dimensions = list_expr(*(integer(dimension) for dimension in array.dimensions))
    if array.fill_value == integer(0):
        return call("SparseArray", rules, dimensions)
    return call("SparseArray", rules, dimensions, array.fill_value)


def _sparse_array_expr(
    dimensions: Sequence[int],
    entries: Iterable[_SparseArrayEntry],
    fill_value: Expr | None = None,
) -> SparseArrayExpr:
    normalized_dimensions = tuple(int(dimension) for dimension in dimensions)
    if not normalized_dimensions:
        raise WolframEvaluationError("SparseArray expects at least one dimension.")
    if any(dimension < 0 for dimension in normalized_dimensions):
        raise WolframEvaluationError("SparseArray dimensions must be non-negative.")

    fill = integer(0) if fill_value is None else fill_value
    rank = len(normalized_dimensions)
    seen: set[tuple[int, ...]] = set()
    normalized_entries: list[_SparseArrayEntry] = []
    for entry in entries:
        indices = tuple(entry.indices)
        if len(indices) != rank:
            raise WolframEvaluationError("SparseArray rule positions must match the array rank.")
        if indices in seen:
            # Wolfram keeps the first repeated position in SparseArray rules.
            continue
        seen.add(indices)
        for axis, index in enumerate(indices):
            if index < 1 or index > normalized_dimensions[axis]:
                raise WolframEvaluationError("SparseArray rule positions must be inside the array dimensions.")
        if entry.value == fill:
            continue
        normalized_entries.append(_SparseArrayEntry(indices, entry.value))

    normalized_entries.sort(key=lambda entry: entry.indices)
    return SparseArrayExpr(
        dimensions=normalized_dimensions,
        entries=tuple(normalized_entries),
        fill_value=fill,
    )


def _sparse_array_entry_map(array: SparseArrayExpr) -> dict[tuple[int, ...], Expr]:
    return {entry.indices: entry.value for entry in array.entries}


def _sparse_array_value_at(array: SparseArrayExpr, indices: Sequence[int]) -> Expr:
    return _sparse_array_entry_map(array).get(tuple(indices), array.fill_value)


def _sparse_position_from_expr(position: Expr, rank_hint: int | None = None) -> tuple[int, ...] | None:
    if isinstance(position, Integer):
        if rank_hint not in {None, 1}:
            return None
        return (position.value,)
    if isinstance(position, Call) and position.has_head("List"):
        if not all(isinstance(item, Integer) for item in position.arguments):
            return None
        indices = tuple(item.value for item in position.arguments if isinstance(item, Integer))
        if rank_hint is not None and len(indices) != rank_hint:
            return None
        return indices
    return None


def _sparse_position_sequence_from_expr(
    positions: Expr,
    values: Expr,
    rank_hint: int | None,
) -> list[tuple[tuple[int, ...], Expr]] | None:
    if not isinstance(positions, Call) or not positions.has_head("List"):
        return None
    if not isinstance(values, Call) or not values.has_head("List"):
        return None
    if len(positions.arguments) != len(values.arguments):
        raise WolframEvaluationError("SparseArray position and value lists must have the same length.")

    if rank_hint in {None, 1} and all(isinstance(item, Integer) for item in positions.arguments):
        return [
            ((position.value,), value)
            for position, value in zip(positions.arguments, values.arguments, strict=True)
            if isinstance(position, Integer)
        ]

    expanded: list[tuple[tuple[int, ...], Expr]] = []
    for position, value in zip(positions.arguments, values.arguments, strict=True):
        indices = _sparse_position_from_expr(position, rank_hint)
        if indices is None:
            return None
        expanded.append((indices, value))
    return expanded


def _sparse_rule_pairs(rule: Expr, rank_hint: int | None) -> list[tuple[tuple[int, ...], Expr]]:
    entry = _rule_entry(rule)
    if entry is None:
        raise WolframEvaluationError("SparseArray expects rules or a dense list.")

    vectorized = _sparse_position_sequence_from_expr(entry.key, entry.value, rank_hint)
    if vectorized is not None:
        return vectorized

    indices = _sparse_position_from_expr(entry.key, rank_hint)
    if indices is None:
        raise WolframEvaluationError("SparseArray currently supports explicit integer positions, not patterns or Band.")
    return [(indices, entry.value)]


def _sparse_rule_exprs(data: Expr) -> tuple[Expr, ...] | None:
    if _rule_entry(data) is not None:
        return (data,)
    if isinstance(data, Call) and data.has_head("List") and all(_rule_entry(item) is not None for item in data.arguments):
        return data.arguments
    return None


def _infer_sparse_dimensions(pairs: Sequence[tuple[tuple[int, ...], Expr]]) -> tuple[int, ...]:
    if not pairs:
        raise WolframEvaluationError("SparseArray dimensions cannot be inferred from an empty rule set.")
    rank = len(pairs[0][0])
    if rank == 0 or any(len(indices) != rank for indices, _value in pairs):
        raise WolframEvaluationError("SparseArray rule positions must have a consistent rank.")
    return tuple(max(indices[axis] for indices, _value in pairs) for axis in range(rank))


def _strict_dense_dimensions(expr: Expr) -> tuple[int, ...]:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return ()
    if not expr.arguments:
        return (0,)
    child_dimensions = [_strict_dense_dimensions(argument) for argument in expr.arguments]
    first = child_dimensions[0]
    if any(dimensions != first for dimensions in child_dimensions):
        raise WolframEvaluationError("SparseArray dense input must be rectangular.")
    return (len(expr.arguments), *first)


def _dense_dimensions(expr: Expr) -> tuple[int, ...]:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return ()
    if not expr.arguments:
        return (0,)
    child_dimensions = [_dense_dimensions(argument) for argument in expr.arguments]
    common: list[int] = []
    for values in zip(*child_dimensions):
        if len(set(values)) != 1:
            break
        common.append(values[0])
    return (len(expr.arguments), *common)


def _dense_sparse_entries(
    expr: Expr,
    dimensions: Sequence[int],
    fill_value: Expr,
    indices: tuple[int, ...] = (),
) -> list[_SparseArrayEntry]:
    if not dimensions:
        return [] if expr == fill_value else [_SparseArrayEntry(indices, expr)]
    if not isinstance(expr, Call) or not expr.has_head("List") or len(expr.arguments) != dimensions[0]:
        raise WolframEvaluationError("SparseArray dense input must match the requested dimensions.")
    entries: list[_SparseArrayEntry] = []
    for offset, item in enumerate(expr.arguments, start=1):
        entries.extend(_dense_sparse_entries(item, dimensions[1:], fill_value, (*indices, offset)))
    return entries


def sparse_array(*arguments: Expr) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("SparseArray expects data, optional dimensions, and an optional implicit value.")

    data = arguments[0]
    fill_value = arguments[2] if len(arguments) == 3 else integer(0)
    dimensions: tuple[int, ...] | None = None
    if len(arguments) >= 2:
        dimensions = tuple(_normalize_dimensions(arguments[1], "SparseArray"))

    if isinstance(data, SparseArrayExpr):
        if dimensions is not None and dimensions != data.dimensions:
            raise WolframEvaluationError("SparseArray cannot reinterpret an existing sparse array with different dimensions.")
        if fill_value == data.fill_value:
            return data
        dense = sparse_array_normal(data)
        assert isinstance(dense, Call)
        return _sparse_array_expr(data.dimensions, _dense_sparse_entries(dense, data.dimensions, fill_value), fill_value)

    if isinstance(data, Symbol) and data.name == "Automatic" and dimensions is not None:
        return _sparse_array_expr(dimensions, (), fill_value)

    rank_hint = len(dimensions) if dimensions is not None else None
    rule_exprs = _sparse_rule_exprs(data)
    if rule_exprs is not None:
        pairs: list[tuple[tuple[int, ...], Expr]] = []
        for rule in rule_exprs:
            pairs.extend(_sparse_rule_pairs(rule, rank_hint))
        final_dimensions = dimensions if dimensions is not None else _infer_sparse_dimensions(pairs)
        return _sparse_array_expr(
            final_dimensions,
            (_SparseArrayEntry(indices, value) for indices, value in pairs),
            fill_value,
        )

    dense_dimensions = _strict_dense_dimensions(data)
    if not dense_dimensions:
        raise WolframEvaluationError("SparseArray expects a rule specification or a rectangular dense list.")
    final_dimensions = dimensions if dimensions is not None else dense_dimensions
    if final_dimensions != dense_dimensions:
        raise WolframEvaluationError("SparseArray dense input dimensions do not match the explicit dimensions.")
    return _sparse_array_expr(final_dimensions, _dense_sparse_entries(data, final_dimensions, fill_value), fill_value)


def sparse_array_q(expr: Expr) -> Symbol:
    return _bool_symbol(isinstance(expr, SparseArrayExpr))


def sparse_array_normal(array: SparseArrayExpr) -> Expr:
    entry_map = _sparse_array_entry_map(array)

    def build(prefix: tuple[int, ...]) -> Expr:
        axis = len(prefix)
        if axis == len(array.dimensions):
            return entry_map.get(prefix, array.fill_value)
        return _evaluated_list_expr(*(
            build((*prefix, index))
            for index in range(1, array.dimensions[axis] + 1)
        ))

    return build(())


def dimensions_expr(expr: Expr) -> Expr:
    if isinstance(expr, SparseArrayExpr):
        return _evaluated_list_expr(*(integer(dimension) for dimension in expr.dimensions))
    return _evaluated_list_expr(*(integer(dimension) for dimension in _dense_dimensions(expr)))


def array_rules(expr: Expr) -> Expr:
    if not isinstance(expr, SparseArrayExpr):
        raise WolframEvaluationError("ArrayRules currently expects a SparseArray.")
    default_position = list_expr(*(call("Blank") for _axis in expr.dimensions))
    return _evaluated_list_expr(
        *(
            call("Rule", list_expr(*(integer(index) for index in entry.indices)), entry.value)
            for entry in expr.entries
        ),
        call("Rule", default_position, expr.fill_value),
    )


def sparse_array_property(array: SparseArrayExpr, property_expr: Expr) -> Expr:
    if not isinstance(property_expr, String):
        raise WolframEvaluationError("SparseArray properties must be requested by string name.")
    name = property_expr.value
    if name == "ImplicitValue":
        return array.fill_value
    if name == "ExplicitLength":
        return integer(len(array.entries))
    if name == "ExplicitValues":
        return _evaluated_list_expr(*(entry.value for entry in array.entries))
    if name == "ExplicitPositions":
        return _evaluated_list_expr(
            *(list_expr(*(integer(index) for index in entry.indices)) for entry in array.entries)
        )
    if name == "Density":
        total_size = math.prod(array.dimensions)
        if total_size == 0:
            return integer(0)
        return rational_number(len(array.entries), total_size)
    raise WolframEvaluationError(f"Unsupported SparseArray property: {name}.")


def _sparse_selector_indices(size: int, spec: Expr, function_name: str) -> tuple[list[int], bool]:
    if isinstance(spec, Integer):
        resolved = _try_resolve_index(size, spec.value)
        if resolved is None:
            raise WolframEvaluationError(f"{function_name} specifications are invalid for SparseArray.")
        return ([resolved + 1], False)
    if isinstance(spec, Symbol) and spec.name == "All":
        return (list(range(1, size + 1)), True)
    if isinstance(spec, Call) and spec.has_head("Span"):
        selectors: list[int] = []
        for index in _expand_span_spec_from_count(size, spec):
            resolved = _try_resolve_index(size, index)
            if resolved is None:
                raise WolframEvaluationError(f"{function_name} specifications are invalid for SparseArray.")
            selectors.append(resolved + 1)
        return (selectors, True)
    if isinstance(spec, Call) and spec.has_head("List"):
        selectors: list[int] = []
        for item in spec.arguments:
            nested, _preserve = _sparse_selector_indices(size, item, function_name)
            selectors.extend(nested)
        return (selectors, True)
    raise WolframEvaluationError(f"Unsupported {function_name} specification for SparseArray: {spec.to_input_form()}.")


def sparse_array_part(array: SparseArrayExpr, specs: Sequence[Expr]) -> Expr:
    if len(specs) > len(array.dimensions):
        raise WolframEvaluationError("Part received too many specifications for SparseArray.")

    selections: list[tuple[list[int], bool]] = []
    for axis, dimension in enumerate(array.dimensions):
        if axis < len(specs):
            selections.append(_sparse_selector_indices(dimension, specs[axis], "Part"))
        else:
            selections.append((list(range(1, dimension + 1)), True))

    if not any(preserve for _indices, preserve in selections):
        return _sparse_array_value_at(array, tuple(indices[0] for indices, _preserve in selections))

    output_dimensions = tuple(len(indices) for indices, preserve in selections if preserve)
    output_maps: list[dict[int, list[int]]] = []
    for indices, preserve in selections:
        if not preserve:
            output_maps.append({})
            continue
        mapping: dict[int, list[int]] = {}
        for output_index, source_index in enumerate(indices, start=1):
            mapping.setdefault(source_index, []).append(output_index)
        output_maps.append(mapping)

    output_entries: list[_SparseArrayEntry] = []
    for entry in array.entries:
        output_index_options: list[list[int]] = []
        include = True
        for axis, source_index in enumerate(entry.indices):
            selected_indices, preserve = selections[axis]
            if preserve:
                mapped = output_maps[axis].get(source_index)
                if not mapped:
                    include = False
                    break
                output_index_options.append(mapped)
            elif source_index != selected_indices[0]:
                include = False
                break
        if not include:
            continue
        for output_indices in itertools.product(*output_index_options):
            output_entries.append(_SparseArrayEntry(tuple(output_indices), entry.value))

    return _sparse_array_expr(output_dimensions, output_entries, array.fill_value)


def _sparse_binary_elementwise(function_name: str, left: Expr, right: Expr) -> Expr:
    if isinstance(left, Call) and left.has_head("List"):
        return evaluate(call(function_name, left, sparse_array_normal(right) if isinstance(right, SparseArrayExpr) else right))
    if isinstance(right, Call) and right.has_head("List"):
        return evaluate(call(function_name, sparse_array_normal(left) if isinstance(left, SparseArrayExpr) else left, right))

    if isinstance(left, SparseArrayExpr) and isinstance(right, SparseArrayExpr):
        if left.dimensions != right.dimensions:
            raise WolframEvaluationError(f"{function_name} expects SparseArray dimensions to agree.")
        fill = evaluate(call(function_name, left.fill_value, right.fill_value))
        left_entries = _sparse_array_entry_map(left)
        right_entries = _sparse_array_entry_map(right)
        entries: list[_SparseArrayEntry] = []
        for indices in sorted(set(left_entries) | set(right_entries)):
            value = evaluate(call(
                function_name,
                left_entries.get(indices, left.fill_value),
                right_entries.get(indices, right.fill_value),
            ))
            entries.append(_SparseArrayEntry(indices, value))
        return _sparse_array_expr(left.dimensions, entries, fill)

    if isinstance(left, SparseArrayExpr):
        fill = evaluate(call(function_name, left.fill_value, right))
        return _sparse_array_expr(
            left.dimensions,
            (_SparseArrayEntry(entry.indices, evaluate(call(function_name, entry.value, right))) for entry in left.entries),
            fill,
        )

    if isinstance(right, SparseArrayExpr):
        fill = evaluate(call(function_name, left, right.fill_value))
        return _sparse_array_expr(
            right.dimensions,
            (_SparseArrayEntry(entry.indices, evaluate(call(function_name, left, entry.value))) for entry in right.entries),
            fill,
        )

    return evaluate(call(function_name, left, right))


def evaluate_sparse_array_arithmetic(expr: Call) -> Expr | None:
    if not expr.has_head("Plus") and not expr.has_head("Times"):
        return None
    if not any(isinstance(argument, SparseArrayExpr) for argument in expr.arguments):
        return None
    if not expr.arguments:
        return integer(0) if expr.has_head("Plus") else integer(1)
    function_name = "Plus" if expr.has_head("Plus") else "Times"
    current = expr.arguments[0]
    for argument in expr.arguments[1:]:
        current = _sparse_binary_elementwise(function_name, current, argument)
    return current


def _bool_symbol(value: bool) -> Symbol:
    return symbol("True" if value else "False")


def _failure_details_expr(fields: Iterable[tuple[str, Expr]]) -> Call:
    return _association_expr(_AssociationEntry("Rule", string(name), value) for name, value in fields)


def _failure_expr(kind: str | Expr, fields: Iterable[tuple[str, Expr]]) -> Call:
    kind_expr = symbol(kind) if isinstance(kind, str) else kind
    return call("Failure", kind_expr, _failure_details_expr(fields))


def _is_failure_expr(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Failure")


def _is_missing_expr(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Missing")


def _is_failure_symbol(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name in {"$Failed", "$Canceled", "$Aborted"}


def _is_failure_q_expr(expr: Expr) -> bool:
    return _is_failure_expr(expr) or _is_failure_symbol(expr)


def _is_confirm_failure_expr(expr: Expr) -> bool:
    return _is_failure_q_expr(expr) or _is_missing_expr(expr)


def _is_failsafe_failure_expr(expr: Expr) -> bool:
    return _is_confirm_failure_expr(expr)


def _failure_entries(expr: Expr) -> tuple[_AssociationEntry, ...]:
    if not _is_failure_expr(expr) or len(expr.arguments) < 2:
        return ()
    details = expr.arguments[1]
    entries = _association_entries(details)
    if entries is not None:
        return entries
    if isinstance(details, Call) and details.has_head("List"):
        result: list[_AssociationEntry] = []
        for item in details.arguments:
            entry = _rule_entry(item)
            if entry is not None:
                result.append(entry)
        return tuple(result)
    return ()


def failure_property(expr: Expr, key: Expr) -> Expr:
    if not isinstance(key, String):
        raise WolframEvaluationError("Failure property lookup expects a string key.")
    if key.value in {"Type", "FailureType"} and _is_failure_expr(expr) and expr.arguments:
        return expr.arguments[0]
    for entry in _failure_entries(expr):
        if entry.key == key:
            return entry.value
    return call("Missing", string("KeyAbsent"), key)


def _is_boolean_symbol(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name in {"True", "False"}


def _truth_value(expr: Expr) -> bool | None:
    if isinstance(expr, Symbol):
        if expr.name == "True":
            return True
        if expr.name == "False":
            return False
    return None


def _is_integer_expr(expr: Expr) -> bool:
    return isinstance(expr, Integer)


def _integer_values(arguments: Sequence[Expr]) -> list[int] | None:
    values: list[int] = []
    for argument in arguments:
        if not isinstance(argument, Integer):
            return None
        values.append(argument.value)
    return values


@dataclass(frozen=True)
class _RealInfo:
    value: Decimal
    precision: int | None
    accuracy: int | None


def _is_indeterminate_expr(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "Indeterminate"


def _is_complex_infinity_expr(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "ComplexInfinity"


def _is_positive_infinity_expr(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "Infinity"


def _is_negative_infinity_expr(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "-Infinity"


def _is_exact_real_number(expr: Expr) -> bool:
    return isinstance(expr, Integer | RationalNumber)


def _is_inexact_real_number(expr: Expr) -> bool:
    return isinstance(expr, Real | SpecialReal)


def _is_machine_real_atom(expr: Expr) -> bool:
    if not isinstance(expr, Real):
        return False
    info = _real_info(expr)
    return info is not None and info.precision is None and info.accuracy is None


def _is_machine_number_expr(expr: Expr) -> bool:
    if _is_machine_real_atom(expr):
        return True
    if isinstance(expr, ComplexNumber):
        return _is_machine_real_atom(expr.real_part) and _is_machine_real_atom(expr.imaginary_part)
    return False


def _is_real_number_expr(expr: Expr) -> bool:
    return _is_exact_real_number(expr) or _is_inexact_real_number(expr)


def _is_number_expr(expr: Expr) -> bool:
    return _is_real_number_expr(expr) or isinstance(expr, ComplexNumber)


def _is_atom_expr(expr: Expr) -> bool:
    return isinstance(expr, (Symbol, Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String, ByteArrayExpr, SparseArrayExpr))


def _is_exact_zero(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value == 0
    if isinstance(expr, RationalNumber):
        return expr.value.numerator == 0
    return False


def _is_numeric_zero(expr: Expr) -> bool:
    if _is_exact_zero(expr):
        return True
    if isinstance(expr, Real):
        info = _real_info(expr)
        return info is not None and info.value == 0
    if isinstance(expr, ComplexNumber):
        return _is_numeric_zero(expr.real_part) and _is_numeric_zero(expr.imaginary_part)
    return False


def _is_negative_real_number(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value < 0
    if isinstance(expr, RationalNumber):
        return expr.value < 0
    if isinstance(expr, Real):
        info = _real_info(expr)
        return info is not None and info.value < 0
    return False


def _format_imaginary_input(expr: Expr) -> str:
    if isinstance(expr, Integer) and expr.value == 1:
        return "I"
    if isinstance(expr, RationalNumber) and expr.value == 1:
        return "I"
    return f"{expr.to_input_form()}*I"


def _exact_fraction(expr: Expr) -> Fraction | None:
    if isinstance(expr, Integer):
        return Fraction(expr.value, 1)
    if isinstance(expr, RationalNumber):
        return expr.value
    return None


def _fraction_expr(value: Fraction) -> Expr:
    return rational_number(value.numerator, value.denominator)


def _real_info(expr: Real) -> _RealInfo | None:
    text = expr.text
    exponent = 0
    if "*^" in text:
        literal, exponent_text = text.split("*^", 1)
        try:
            exponent = int(exponent_text)
        except ValueError:
            return None
    else:
        literal = text

    precision: int | None = None
    accuracy: int | None = None
    marker_index = literal.find("`")
    if marker_index >= 0:
        number_text = literal[:marker_index]
        precision_text = literal[marker_index + 1:]
        is_accuracy_marker = precision_text.startswith("`")
        if is_accuracy_marker:
            precision_text = precision_text[1:]
        if precision_text:
            try:
                marker_value = max(0, int(Decimal(precision_text)))
            except (InvalidOperation, ValueError):
                marker_value = 0
            if is_accuracy_marker:
                accuracy = marker_value
            else:
                precision = marker_value
    else:
        number_text = literal

    if number_text.startswith("+"):
        number_text = number_text[1:]
    if not number_text or number_text in {"+", "-", "."}:
        return None
    try:
        value = Decimal(number_text) * (Decimal(10) ** exponent)
    except InvalidOperation:
        return None
    return _RealInfo(value=value, precision=precision, accuracy=accuracy)


def _decimal_log10_abs(value: Decimal) -> float | None:
    if value == 0:
        return None
    try:
        return math.log10(abs(float(value)))
    except (OverflowError, ValueError):
        adjusted = value.adjusted()
        scaled = value.scaleb(-adjusted)
        return adjusted + math.log10(abs(float(scaled)))


def _effective_real_precision(info: _RealInfo) -> float | str:
    if info.precision is not None:
        return float(info.precision)
    if info.accuracy is not None:
        log_value = _decimal_log10_abs(info.value)
        if log_value is None:
            return 0.0
        return float(info.accuracy) + log_value
    return "machine"


def _effective_real_accuracy(info: _RealInfo) -> float | str:
    if info.accuracy is not None:
        return float(info.accuracy)
    if info.precision is not None:
        log_value = _decimal_log10_abs(info.value)
        if log_value is None:
            return float(info.precision)
        return float(info.precision) - log_value
    log_value = _decimal_log10_abs(info.value)
    if log_value is None:
        log_value = math.log10(float.fromhex("0x1.0000000000000p-1022"))
    return sys.float_info.mant_dig * math.log10(2) - log_value


def _combined_inexact_precision(arguments: Sequence[Expr]) -> int | None:
    precision: int | None = None
    for argument in arguments:
        if isinstance(argument, SpecialReal):
            return None
        if isinstance(argument, Real):
            info = _real_info(argument)
            if info is None:
                return None
            effective = _effective_real_precision(info)
            if effective == "machine":
                return None
            numeric_precision = max(1, int(effective))
            precision = numeric_precision if precision is None else min(precision, numeric_precision)
        elif isinstance(argument, ComplexNumber):
            component_precision = _combined_inexact_precision((argument.real_part, argument.imaginary_part))
            if _contains_machine_real(argument.real_part) or _contains_machine_real(argument.imaginary_part):
                return None
            if component_precision is not None:
                precision = component_precision if precision is None else min(precision, component_precision)
    return precision


def _contains_inexact_real(expr: Expr) -> bool:
    if isinstance(expr, Real | SpecialReal):
        return True
    if isinstance(expr, ComplexNumber):
        return _contains_inexact_real(expr.real_part) or _contains_inexact_real(expr.imaginary_part)
    return False


def _contains_machine_real(expr: Expr) -> bool:
    if isinstance(expr, SpecialReal):
        return False
    if isinstance(expr, Real):
        return _is_machine_real_atom(expr)
    if isinstance(expr, ComplexNumber):
        return _contains_machine_real(expr.real_part) or _contains_machine_real(expr.imaginary_part)
    return False


def _decimal_for_expr(expr: Expr, precision: int) -> Decimal | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        with localcontext() as context:
            context.prec = max(precision, 1)
            return Decimal(exact.numerator) / Decimal(exact.denominator)
    if isinstance(expr, Real):
        info = _real_info(expr)
        return info.value if info is not None else None
    return None


def _float_for_expr(expr: Expr) -> float | None:
    exact = _exact_fraction(expr)
    if exact is not None:
        return float(exact)
    if isinstance(expr, SpecialReal):
        return math.inf if expr.name == "Overflow" else 0.0
    if isinstance(expr, Real):
        info = _real_info(expr)
        return float(info.value) if info is not None else None
    return None


def _machine_real(value: float) -> Expr:
    if math.isnan(value):
        return symbol("Indeterminate")
    if math.isinf(value):
        return special_real("Overflow")
    text = repr(float(value))
    if text.endswith(".0"):
        text = text[:-2] + "."
    text = text.replace("e", "*^").replace("E", "*^")
    if "." not in text and "*^" not in text:
        text += "."
    return real(text)


def _decimal_real(value: Decimal, precision: int) -> Expr:
    if not value.is_finite():
        return special_real("Overflow")
    text = format(value, "f")
    if "." not in text:
        text += "."
    return real(f"{text}`{precision}.")


def _decimal_real_accuracy(value: Decimal, accuracy: int) -> Expr:
    if not value.is_finite():
        return special_real("Overflow")
    text = format(value, "f")
    if "." not in text:
        text += "."
    return real(f"{text}``{accuracy}.")


def _inexact_real_result(arguments: Sequence[Expr], operation: Callable[[Sequence[Decimal]], Decimal]) -> Expr | None:
    precision = _combined_inexact_precision(arguments)
    if precision is None:
        values = [_float_for_expr(argument) for argument in arguments]
        if any(value is None for value in values):
            return None
        assert all(value is not None for value in values)
        float_values = [float(value) for value in values]
        if not float_values:
            return None
        try:
            result = float_values[0]
            if operation is _DECIMAL_SUM:
                result = sum(float_values)
            elif operation is _DECIMAL_PRODUCT:
                result = math.prod(float_values)
            else:
                return None
        except OverflowError:
            return special_real("Overflow")
        return _machine_real(result)

    decimal_values = [_decimal_for_expr(argument, precision) for argument in arguments]
    if any(value is None for value in decimal_values):
        return None
    assert all(value is not None for value in decimal_values)
    with localcontext() as context:
        context.prec = max(precision, 1)
        try:
            return _decimal_real(operation([Decimal(value) for value in decimal_values]), precision)
        except (InvalidOperation, ZeroDivisionError):
            return symbol("Indeterminate")


def _DECIMAL_SUM(values: Sequence[Decimal]) -> Decimal:
    return sum(values, Decimal(0))


def _DECIMAL_PRODUCT(values: Sequence[Decimal]) -> Decimal:
    product = Decimal(1)
    for value in values:
        product *= value
    return product


def _negate_real_expr(expr: Expr) -> Expr:
    if isinstance(expr, Integer):
        return integer(-expr.value)
    if isinstance(expr, RationalNumber):
        return _fraction_expr(-expr.value)
    if isinstance(expr, Real):
        return _add_real_expr(integer(0), expr, negate_right=True) or call("Times", integer(-1), expr)
    if isinstance(expr, SpecialReal):
        return call("Times", integer(-1), expr)
    return call("Times", integer(-1), expr)


def _add_real_expr(left: Expr, right: Expr, *, negate_right: bool = False) -> Expr | None:
    if negate_right:
        right = _mul_real_expr(integer(-1), right) or call("Times", integer(-1), right)
    if isinstance(left, SpecialReal) or isinstance(right, SpecialReal):
        if isinstance(left, SpecialReal) and isinstance(right, SpecialReal):
            if left.name == right.name:
                return left
            return special_real("Overflow")
        special = left if isinstance(left, SpecialReal) else right
        other = right if special is left else left
        if special.name == "Underflow":
            return other
        return special

    left_fraction = _exact_fraction(left)
    right_fraction = _exact_fraction(right)
    if left_fraction is not None and right_fraction is not None:
        return _fraction_expr(left_fraction + right_fraction)
    return _inexact_real_result((left, right), _DECIMAL_SUM)


def _mul_real_expr(left: Expr, right: Expr) -> Expr | None:
    if isinstance(left, SpecialReal) or isinstance(right, SpecialReal):
        if _is_numeric_zero(left) or _is_numeric_zero(right):
            return integer(0) if (isinstance(left, SpecialReal) and left.name == "Underflow") or (isinstance(right, SpecialReal) and right.name == "Underflow") else symbol("Indeterminate")
        if isinstance(left, SpecialReal) and isinstance(right, SpecialReal):
            if {left.name, right.name} == {"Overflow", "Underflow"}:
                return symbol("Indeterminate")
            return left
        special = left if isinstance(left, SpecialReal) else right
        return special

    left_fraction = _exact_fraction(left)
    right_fraction = _exact_fraction(right)
    if left_fraction is not None and right_fraction is not None:
        return _fraction_expr(left_fraction * right_fraction)
    return _inexact_real_result((left, right), _DECIMAL_PRODUCT)


def _div_real_expr(numerator: Expr, denominator: Expr) -> Expr | None:
    if _is_numeric_zero(denominator):
        return symbol("Indeterminate") if _is_numeric_zero(numerator) else symbol("ComplexInfinity")
    if isinstance(denominator, SpecialReal):
        return special_real("Underflow") if denominator.name == "Overflow" else special_real("Overflow")
    if isinstance(numerator, SpecialReal):
        return numerator

    numerator_fraction = _exact_fraction(numerator)
    denominator_fraction = _exact_fraction(denominator)
    if numerator_fraction is not None and denominator_fraction is not None:
        return _fraction_expr(numerator_fraction / denominator_fraction)

    precision = _combined_inexact_precision((numerator, denominator))
    if precision is None:
        left = _float_for_expr(numerator)
        right = _float_for_expr(denominator)
        if left is None or right is None:
            return None
        try:
            return _machine_real(left / right)
        except ZeroDivisionError:
            return symbol("Indeterminate") if left == 0 else symbol("ComplexInfinity")

    left_decimal = _decimal_for_expr(numerator, precision)
    right_decimal = _decimal_for_expr(denominator, precision)
    if left_decimal is None or right_decimal is None:
        return None
    with localcontext() as context:
        context.prec = max(precision, 1)
        try:
            return _decimal_real(left_decimal / right_decimal, precision)
        except (InvalidOperation, ZeroDivisionError):
            return symbol("Indeterminate") if left_decimal == 0 else symbol("ComplexInfinity")


def _real_power_expr(base: Expr, exponent: Expr) -> Expr | None:
    exponent_fraction = _exact_fraction(exponent)
    if exponent_fraction is not None and exponent_fraction.denominator == 1:
        power = exponent_fraction.numerator
        if power == 0:
            return symbol("Indeterminate") if _is_numeric_zero(base) else integer(1)
        if power < 0:
            positive = _real_power_expr(base, integer(-power))
            if positive is None:
                return None
            return _div_real_expr(integer(1), positive)

        if isinstance(base, SpecialReal):
            return base
        base_fraction = _exact_fraction(base)
        if base_fraction is not None:
            return _fraction_expr(base_fraction ** power)

        precision = _combined_inexact_precision((base,))
        if precision is None:
            base_float = _float_for_expr(base)
            return _machine_real(base_float ** power) if base_float is not None else None
        base_decimal = _decimal_for_expr(base, precision)
        if base_decimal is None:
            return None
        with localcontext() as context:
            context.prec = max(precision, 1)
            return _decimal_real(base_decimal ** int(power), precision)

    if _contains_inexact_real(base) or _contains_inexact_real(exponent):
        base_float = _float_for_expr(base)
        exponent_float = _float_for_expr(exponent)
        if base_float is None or exponent_float is None:
            return None
        try:
            return _machine_real(base_float ** exponent_float)
        except (OverflowError, ValueError):
            return None
    return None


def _complex_parts(expr: Expr) -> tuple[Expr, Expr] | None:
    if isinstance(expr, ComplexNumber):
        return expr.real_part, expr.imaginary_part
    if _is_real_number_expr(expr):
        return expr, integer(0)
    return None


def _add_numeric_expr(left: Expr, right: Expr) -> Expr | None:
    left_parts = _complex_parts(left)
    right_parts = _complex_parts(right)
    if left_parts is not None and right_parts is not None:
        real_part = _add_real_expr(left_parts[0], right_parts[0])
        imaginary_part = _add_real_expr(left_parts[1], right_parts[1])
        if real_part is None or imaginary_part is None:
            return None
        if isinstance(left, ComplexNumber) or isinstance(right, ComplexNumber):
            return complex_number(real_part, imaginary_part)
        return real_part
    return None


def _mul_numeric_expr(left: Expr, right: Expr) -> Expr | None:
    left_parts = _complex_parts(left)
    right_parts = _complex_parts(right)
    if left_parts is None or right_parts is None:
        return None
    if isinstance(left, ComplexNumber) or isinstance(right, ComplexNumber):
        ac = _mul_real_expr(left_parts[0], right_parts[0])
        bd = _mul_real_expr(left_parts[1], right_parts[1])
        ad = _mul_real_expr(left_parts[0], right_parts[1])
        bc = _mul_real_expr(left_parts[1], right_parts[0])
        if ac is None or bd is None or ad is None or bc is None:
            return None
        real_part = _add_real_expr(ac, bd, negate_right=True)
        imaginary_part = _add_real_expr(ad, bc)
        if real_part is None or imaginary_part is None:
            return None
        return complex_number(real_part, imaginary_part)
    return _mul_real_expr(left, right)


def _div_numeric_expr(numerator: Expr, denominator: Expr) -> Expr | None:
    numerator_parts = _complex_parts(numerator)
    denominator_parts = _complex_parts(denominator)
    if numerator_parts is None or denominator_parts is None:
        return None
    if not isinstance(numerator, ComplexNumber) and not isinstance(denominator, ComplexNumber):
        return _div_real_expr(numerator, denominator)

    c, d = denominator_parts
    c2 = _mul_real_expr(c, c)
    d2 = _mul_real_expr(d, d)
    denom = _add_real_expr(c2, d2) if c2 is not None and d2 is not None else None
    if denom is None:
        return None
    if _is_numeric_zero(denom):
        return symbol("Indeterminate") if _is_numeric_zero(numerator) else symbol("ComplexInfinity")
    conjugate = complex_number(c, _negate_real_expr(d))
    multiplied = _mul_numeric_expr(numerator, conjugate)
    multiplied_parts = _complex_parts(multiplied) if multiplied is not None else None
    if multiplied_parts is None:
        return None
    real_part = _div_real_expr(multiplied_parts[0], denom)
    imaginary_part = _div_real_expr(multiplied_parts[1], denom)
    if real_part is None or imaginary_part is None:
        return None
    return complex_number(real_part, imaginary_part)


def _numeric_power_expr(base: Expr, exponent: Expr) -> Expr | None:
    exponent_fraction = _exact_fraction(exponent)
    if isinstance(base, ComplexNumber) and exponent_fraction is not None and exponent_fraction.denominator == 1:
        power = exponent_fraction.numerator
        if power == 0:
            return symbol("Indeterminate") if _is_numeric_zero(base) else integer(1)
        if power < 0:
            positive = _numeric_power_expr(base, integer(-power))
            if positive is None:
                return None
            return _div_numeric_expr(integer(1), positive)
        result: Expr = integer(1)
        factor: Expr = base
        remaining = power
        while remaining:
            if remaining & 1:
                multiplied = _mul_numeric_expr(result, factor)
                if multiplied is None:
                    return None
                result = multiplied
            remaining >>= 1
            if remaining:
                squared = _mul_numeric_expr(factor, factor)
                if squared is None:
                    return None
                factor = squared
        return result
    if _is_real_number_expr(base):
        return _real_power_expr(base, exponent)
    return None


def _compare_real_expr(left: Expr, right: Expr) -> int | None:
    algebraic_compare = _compare_algebraic_real_expr(left, right)
    if algebraic_compare is not None:
        return algebraic_compare
    transcendental_compare = _compare_transcendental_real_expr(left, right)
    if transcendental_compare is not None:
        return transcendental_compare

    if isinstance(left, SpecialReal) or isinstance(right, SpecialReal):
        if left == right:
            return 0
        if isinstance(left, SpecialReal) and left.name == "Overflow":
            return 1
        if isinstance(right, SpecialReal) and right.name == "Overflow":
            return -1
        if isinstance(left, SpecialReal) and left.name == "Underflow":
            right_value = _float_for_expr(right)
            if right_value is None:
                return None
            return 1 if right_value <= 0 else -1
        if isinstance(right, SpecialReal) and right.name == "Underflow":
            left_value = _float_for_expr(left)
            if left_value is None:
                return None
            return -1 if left_value <= 0 else 1

    if _is_positive_infinity_expr(left):
        return 0 if _is_positive_infinity_expr(right) else 1
    if _is_positive_infinity_expr(right):
        return -1
    if _is_negative_infinity_expr(left):
        return 0 if _is_negative_infinity_expr(right) else -1
    if _is_negative_infinity_expr(right):
        return 1

    left_fraction = _exact_fraction(left)
    right_fraction = _exact_fraction(right)
    if left_fraction is not None and right_fraction is not None:
        return (left_fraction > right_fraction) - (left_fraction < right_fraction)

    precision = _combined_inexact_precision((left, right))
    if precision is None:
        left_float = _float_for_expr(left)
        right_float = _float_for_expr(right)
        if left_float is None or right_float is None:
            return None
        return (left_float > right_float) - (left_float < right_float)

    left_decimal = _decimal_for_expr(left, precision)
    right_decimal = _decimal_for_expr(right, precision)
    if left_decimal is None or right_decimal is None:
        return None
    return (left_decimal > right_decimal) - (left_decimal < right_decimal)


def _numeric_same_value(left: Expr, right: Expr) -> bool | None:
    left_parts = _complex_parts(left)
    right_parts = _complex_parts(right)
    if left_parts is None or right_parts is None:
        return None
    real_compare = _compare_real_expr(left_parts[0], right_parts[0])
    imaginary_compare = _compare_real_expr(left_parts[1], right_parts[1])
    if real_compare is None or imaginary_compare is None:
        return None
    return real_compare == 0 and imaginary_compare == 0


def _real_abs_expr(expr: Expr) -> Expr | None:
    if isinstance(expr, SpecialReal):
        return expr
    if isinstance(expr, Integer):
        return integer(abs(expr.value))
    if isinstance(expr, RationalNumber):
        return _fraction_expr(abs(expr.value))
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            return None
        if info.precision is None:
            return _machine_real(abs(float(info.value)))
        return _decimal_real(abs(info.value), info.precision)
    return None


def _perfect_square_root(value: Fraction) -> Fraction | None:
    if value < 0:
        return None
    numerator_root = math.isqrt(value.numerator)
    denominator_root = math.isqrt(value.denominator)
    if numerator_root * numerator_root == value.numerator and denominator_root * denominator_root == value.denominator:
        return Fraction(numerator_root, denominator_root)
    return None


def _numeric_abs_expr(expr: Expr) -> Expr | None:
    if _is_real_number_expr(expr):
        return _real_abs_expr(expr)
    if not isinstance(expr, ComplexNumber):
        symbolic_abs = _symbolic_abs_expr(expr)
        if symbolic_abs is not None:
            return symbolic_abs
        return None
    real_square = _mul_real_expr(expr.real_part, expr.real_part)
    imaginary_square = _mul_real_expr(expr.imaginary_part, expr.imaginary_part)
    if real_square is None or imaginary_square is None:
        return None
    square_sum = _add_real_expr(real_square, imaginary_square)
    if square_sum is None:
        return None
    exact = _exact_fraction(square_sum)
    if exact is not None:
        root = _perfect_square_root(exact)
        if root is not None:
            return _fraction_expr(root)
        return call("Power", _fraction_expr(exact), rational_number(1, 2))
    square_sum_float = _float_for_expr(square_sum)
    if square_sum_float is None:
        return None
    return _machine_real(math.sqrt(square_sum_float))


def _symbolic_abs_expr(expr: Expr) -> Expr | None:
    if isinstance(expr, Call) and expr.has_head("Times"):
        numeric_factor: Expr = integer(1)
        symbolic_factors: list[Expr] = []
        saw_numeric = False
        for factor in expr.arguments:
            if _is_number_expr(factor):
                multiplied = _mul_numeric_expr(numeric_factor, factor)
                if multiplied is None:
                    return None
                numeric_factor = multiplied
                saw_numeric = True
            else:
                symbolic_factors.append(factor)
        if not saw_numeric:
            return None
        numeric_abs = _numeric_abs_expr(numeric_factor)
        if numeric_abs is None:
            return None
        if not symbolic_factors:
            return numeric_abs
        symbolic_part = symbolic_factors[0] if len(symbolic_factors) == 1 else Call(
            head_expr=symbol("Times"),
            arguments=tuple(symbolic_factors),
        )
        symbolic_abs = call("Abs", symbolic_part)
        if _numeric_same_value(numeric_abs, integer(1)) is True:
            return symbolic_abs
        return evaluate(call("Times", numeric_abs, symbolic_abs))

    if isinstance(expr, Call) and expr.has_head("Power") and len(expr.arguments) == 2:
        base, exponent = expr.arguments
        exact_exponent = _exact_fraction(exponent)
        if exact_exponent is not None and exact_exponent.denominator == 1 and exact_exponent.numerator >= 0:
            return evaluate(call("Power", call("Abs", base), exponent))

    return None


def _byte_array_values(expr: Expr) -> tuple[int, ...] | None:
    if isinstance(expr, ByteArrayExpr):
        return expr.values
    return None


def _normalize_base_encoding_name(value: Expr, function_name: str) -> str:
    if not isinstance(value, String):
        raise WolframEvaluationError(f"{function_name} expects the encoding name to be a string.")
    normalized = value.value.strip().lower()
    if normalized == "base16":
        return "Base16"
    if normalized == "base64":
        return "Base64"
    if normalized == "base85ascii":
        return "Base85ASCII"
    raise WolframEvaluationError(
        f'{function_name} currently supports only "Base16", "Base64", and "Base85ASCII".'
    )


_SINGLE_BYTE_ENCODINGS = {
    "ascii": "ascii",
    "iso8859-1": "latin-1",
    "iso-8859-1": "latin-1",
    "latin1": "latin-1",
    "latin-1": "latin-1",
    "iso8859-15": "iso8859_15",
    "iso-8859-15": "iso8859_15",
    "windowsansi": "cp1252",
    "windows-ansi": "cp1252",
    "windows-1252": "cp1252",
    "cp1252": "cp1252",
}

_MULTIBYTE_ENCODINGS = {
    "utf-8": "utf-8",
    "utf8": "utf-8",
    "utf-16le": "utf-16le",
    "utf16le": "utf-16le",
    "utf-16be": "utf-16be",
    "utf16be": "utf-16be",
    "utf-32le": "utf-32le",
    "utf32le": "utf-32le",
    "utf-32be": "utf-32be",
    "utf32be": "utf-32be",
}


def _normalize_character_encoding_name(
    value: Expr | None,
    function_name: str,
    *,
    default_unicode: bool = False,
) -> tuple[str, str]:
    if value is None:
        return ("Unicode", "Unicode") if default_unicode else ("utf-8", "UTF-8")
    if not isinstance(value, String):
        raise WolframEvaluationError(f"{function_name} expects the encoding name to be a string.")
    raw = value.value.strip()
    normalized = raw.lower()
    if normalized == "unicode":
        return "Unicode", "Unicode"
    if normalized in {"printableascii", "printable-ascii"}:
        return "PrintableASCII", raw
    single = _SINGLE_BYTE_ENCODINGS.get(normalized)
    if single is not None:
        return single, raw
    multi = _MULTIBYTE_ENCODINGS.get(normalized)
    if multi is not None:
        return multi, raw
    raise WolframEvaluationError(
        f'{function_name} currently supports "Unicode", "PrintableASCII", "UTF-8", "UTF-16LE", '
        '"UTF-16BE", "UTF-32LE", "UTF-32BE", "ASCII", "WindowsANSI", "ISO8859-1", and "ISO8859-15".'
    )


def _decode_bytes_to_string(data: bytes, codec_name: str) -> str:
    if codec_name == "Unicode":
        return "".join(chr(byte) for byte in data)
    if codec_name in {"PrintableASCII", "ascii"}:
        return "".join(chr(byte) if byte < 128 else chr(0xF200 + byte) for byte in data)
    decoded = data.decode(codec_name, errors="surrogateescape")
    return "".join(chr(ord(char) - 0xDC00) if 0xDC80 <= ord(char) <= 0xDCFF else char for char in decoded)


def _string_to_character_codes(value: str, encoding_name: str) -> list[Expr]:
    if encoding_name == "Unicode":
        return [integer(ord(char)) for char in value]
    if encoding_name == "PrintableASCII":
        encoding_name = "ascii"
    if encoding_name in _SINGLE_BYTE_ENCODINGS.values():
        codes: list[Expr] = []
        for char in value:
            try:
                encoded = char.encode(encoding_name)
            except UnicodeEncodeError:
                codes.append(symbol("None"))
                continue
            assert len(encoded) == 1
            codes.append(integer(encoded[0]))
        return codes
    return [integer(byte) for byte in value.encode(encoding_name)]


def _expression_arithmetic_module():
    from . import expression_arithmetic as _arithmetic

    return _arithmetic


def _evaluate_integer_arithmetic(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_integer_arithmetic(expr)


def _evaluate_numeric_constructor(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_numeric_constructor(expr)


def _evaluate_numeric_arithmetic(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_numeric_arithmetic(expr)


def _evaluate_integer_relation(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_integer_relation(expr)


def _evaluate_numeric_relation(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_numeric_relation(expr)


def _evaluate_inequality(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_inequality(expr)


def _evaluate_boolean_logic(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_boolean_logic(expr)


def _evaluate_held_boolean_logic(head: Symbol, arguments: Sequence[Expr]) -> Expr:
    return _expression_arithmetic_module()._evaluate_held_boolean_logic(head, arguments)


def _evaluate_simple_predicates(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_simple_predicates(expr)


def _evaluate_integer_special_functions(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_integer_special_functions(expr)


def _evaluate_numeric_special_functions(expr: Call) -> Expr | None:
    return _expression_arithmetic_module()._evaluate_numeric_special_functions(expr)


def _expression_polynomial_module():
    from . import expression_polynomial as _polynomial

    return _polynomial


def _evaluate_polynomial_functions(expr: Call) -> Expr | None:
    return _expression_polynomial_module()._evaluate_polynomial_functions(expr)


def _expression_algebraic_module():
    from . import expression_algebraic as _algebraic

    return _algebraic


def _evaluate_algebraic_functions(expr: Call) -> Expr | None:
    return _expression_algebraic_module()._evaluate_algebraic_functions(expr)


def _numericize_algebraic_expr(expr: Expr, precision: int | None) -> Expr | None:
    return _expression_algebraic_module()._numericize_algebraic_expr(expr, precision)


def _is_real_algebraic_expr(expr: Expr) -> bool:
    return _expression_algebraic_module()._is_real_algebraic_expr(expr)


def _compare_algebraic_real_expr(left: Expr, right: Expr) -> int | None:
    return _expression_algebraic_module()._compare_algebraic_real_expr(left, right)


def _conjugate_algebraic_expr(expr: Expr) -> Expr | None:
    return _expression_algebraic_module()._conjugate_algebraic_expr(expr)


def _flatten_list_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    """If ``arguments`` is a single ``List[...]`` wrapper, unwrap once.

    Returns the original tuple otherwise. Used by ``Min`` / ``Max`` and
    similar fold heads that accept either ``f[a, b]`` or ``f[{a, b}]``.
    """
    if len(arguments) == 1 and isinstance(arguments[0], Call) and arguments[0].has_head("List"):
        return tuple(arguments[0].arguments)
    return tuple(arguments)


def _option_rule_parts(option: Expr) -> tuple[str, Expr] | None:
    if not isinstance(option, Call) or len(option.arguments) != 2:
        return None
    if not option.has_head("Rule") and not option.has_head("RuleDelayed"):
        return None
    name, value = option.arguments
    if not isinstance(name, Symbol):
        return None
    return name.name, value


def _split_trailing_option_rules(arguments: Sequence[Expr]) -> tuple[tuple[Expr, ...], tuple[Expr, ...]]:
    split_index = len(arguments)
    while split_index > 0 and _option_rule_parts(arguments[split_index - 1]) is not None:
        split_index -= 1
    return tuple(arguments[:split_index]), tuple(arguments[split_index:])


def _option_value(options: Sequence[Expr], name: str) -> Expr | None:
    for option in reversed(options):
        parts = _option_rule_parts(option)
        if parts is None:
            continue
        option_name, option_value = parts
        if option_name == name:
            return option_value
    return None


def _same_test_from_options(options: Sequence[Expr]) -> Expr | None:
    same_test = _option_value(options, "SameTest")
    if isinstance(same_test, Symbol) and same_test.name == "Automatic":
        return None
    return same_test


def _flatten_min_max_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    flattened: list[Expr] = []

    def visit(argument: Expr) -> None:
        if isinstance(argument, Call) and argument.has_head("List"):
            for item in argument.arguments:
                visit(item)
            return
        flattened.append(argument)

    for argument in arguments:
        visit(argument)
    return tuple(flattened)


def _min_max_expr(head: Expr, arguments: Sequence[Expr]) -> Expr | None:
    head_name = head.name if isinstance(head, Symbol) else None
    if head_name not in {"Min", "Max"}:
        return None

    flattened = _flatten_min_max_arguments(arguments)
    identity = symbol("Infinity") if head_name == "Min" else symbol("-Infinity")
    absorbing = symbol("-Infinity") if head_name == "Min" else symbol("Infinity")
    if not flattened:
        return identity

    numeric_arguments: list[Expr] = []
    symbolic_arguments: list[Expr] = []
    for argument in flattened:
        if _is_positive_infinity_expr(argument) or _is_negative_infinity_expr(argument):
            if argument == absorbing:
                return absorbing
            numeric_arguments.append(argument)
        elif _is_real_number_expr(argument) or _is_real_algebraic_expr(argument) or _is_real_transcendental_expr(argument):
            numeric_arguments.append(argument)
        else:
            symbolic_arguments.append(argument)

    best: Expr | None = None
    if numeric_arguments:
        best = numeric_arguments[0]
        for argument in numeric_arguments[1:]:
            comparison = _compare_real_expr(argument, best)
            if comparison is None:
                return None
            if (head_name == "Min" and comparison < 0) or (head_name == "Max" and comparison > 0):
                best = argument

    result_arguments: list[Expr] = []
    if best is not None and best != identity:
        result_arguments.append(best)
    result_arguments.extend(symbolic_arguments)

    if not result_arguments:
        return identity
    if len(result_arguments) == 1:
        return result_arguments[0]

    result_arguments = list(dict.fromkeys(result_arguments))
    normalized = (
        _normalize_attribute_call(head, result_arguments)
        if isinstance(head, Symbol)
        else tuple(result_arguments)
    )
    result = Call(head_expr=head, arguments=normalized)
    if result.arguments == tuple(arguments):
        return None
    return result


def _real_rounding_expr(head: Expr, argument: Expr) -> Expr | None:
    """Floor / Ceiling / Round / IntegerPart / FractionalPart on real numbers."""
    head_name = head.name if isinstance(head, Symbol) else None
    if head_name not in {"Floor", "Ceiling", "Round", "IntegerPart", "FractionalPart"}:
        return None

    if isinstance(argument, ComplexNumber):
        real_part = _real_rounding_expr(head, argument.real_part)
        imaginary_part = _real_rounding_expr(head, argument.imaginary_part)
        if real_part is None or imaginary_part is None:
            return None
        return complex_number(real_part, imaginary_part)

    if not _is_real_number_expr(argument):
        return None

    fraction = _exact_fraction(argument)
    if fraction is not None:
        if head_name == "Floor":
            return integer(math.floor(fraction))
        if head_name == "Ceiling":
            return integer(math.ceil(fraction))
        if head_name == "Round":
            # Wolfram's Round uses banker's rounding (round half to even).
            # ``Fraction.__round__`` already implements banker's rounding.
            return integer(round(fraction))
        if head_name == "IntegerPart":
            # Truncation toward zero.
            integer_value = int(fraction)
            return integer(integer_value)
        if head_name == "FractionalPart":
            integer_value = int(fraction)
            remainder = fraction - integer_value
            if remainder.denominator == 1:
                return integer(remainder.numerator)
            return _fraction_expr(remainder)
        return None

    if isinstance(argument, Real):
        info = _real_info(argument)
        if info is None:
            return None
        is_machine = info.precision is None and info.accuracy is None
        if is_machine and head_name == "FractionalPart":
            # Machine reals follow IEEE semantics for FractionalPart, so
            # FractionalPart[3.7] is 0.7000000000000002 just like the kernel.
            float_value = float(info.value)
            return _machine_real(float_value - math.trunc(float_value))
        # Use Decimal arithmetic to preserve precision and to avoid float
        # rounding issues for round-half-to-even.
        value = info.value
        if head_name == "Floor":
            return integer(math.floor(value))
        if head_name == "Ceiling":
            return integer(math.ceil(value))
        if head_name == "Round":
            # Decimal supports ROUND_HALF_EVEN directly.
            return integer(int(value.to_integral_value(rounding=ROUND_HALF_EVEN)))
        if head_name == "IntegerPart":
            # Truncation toward zero.
            return integer(int(value))
        if head_name == "FractionalPart":
            integer_part = int(value)
            remainder = value - integer_part
            return _decimal_real(remainder, info.precision or 0)
        return None

    return None


def _rounding_multiple_expr(head: Expr, argument: Expr, multiple: Expr) -> Expr | None:
    head_name = head.name if isinstance(head, Symbol) else None
    if head_name not in {"Floor", "Ceiling", "Round"}:
        return None
    if not _is_number_expr(argument) or not _is_number_expr(multiple):
        return None
    if _is_numeric_zero(multiple):
        return symbol("Indeterminate")
    quotient = _div_numeric_expr(argument, multiple)
    if quotient is None:
        return None
    if _is_indeterminate_expr(quotient) or _is_complex_infinity_expr(quotient):
        return symbol("Indeterminate")
    rounded = _real_rounding_expr(head, quotient)
    if rounded is None:
        return None
    return _mul_numeric_expr(multiple, rounded)


def _numeric_mod_expr(arguments: Sequence[Expr]) -> Expr | None:
    if len(arguments) not in {2, 3}:
        return None
    if not all(_is_real_number_expr(argument) for argument in arguments):
        return None

    dividend, divisor = arguments[0], arguments[1]
    offset = arguments[2] if len(arguments) == 3 else integer(0)
    if _is_numeric_zero(divisor):
        return symbol("Indeterminate")

    shifted = _add_real_expr(dividend, offset, negate_right=True)
    if shifted is None:
        return None
    quotient = _div_real_expr(shifted, divisor)
    if quotient is None or _is_indeterminate_expr(quotient) or _is_complex_infinity_expr(quotient):
        return None
    quotient_floor = _real_rounding_expr(symbol("Floor"), quotient)
    if quotient_floor is None:
        return None
    product = _mul_real_expr(divisor, quotient_floor)
    if product is None:
        return None
    remainder = _add_real_expr(shifted, product, negate_right=True)
    if remainder is None:
        return None
    return _add_real_expr(offset, remainder)


def _sqrt_expr(argument: Expr) -> Expr | None:
    """Sqrt for the explicit-number subset.

    Falls through to ``Power[arg, 1/2]`` for everything else, matching the
    common Wolfram lowering. Exact powers are routed through ``Power`` so the
    arithmetic evaluator can extract perfect factors from non-perfect roots.
    """
    if isinstance(argument, Integer):
        if argument.value < 0:
            # Sqrt[-n] -> Sqrt[n] * I for positive n. The kernel canonical
            # ordering puts the numeric magnitude first.
            if argument.value == 0:
                return integer(0)
            magnitude_root = _sqrt_expr(integer(-argument.value))
            if magnitude_root is None:
                return None
            return call("Times", magnitude_root, symbol("I"))
        if argument.value == 0:
            return integer(0)
        root = math.isqrt(argument.value)
        if root * root == argument.value:
            return integer(root)
        return evaluate(call("Power", argument, rational_number(1, 2)))
    if isinstance(argument, RationalNumber):
        numerator_root = _sqrt_expr(integer(argument.value.numerator))
        denominator_root = _sqrt_expr(integer(argument.value.denominator))
        if numerator_root is None or denominator_root is None:
            return None
        if isinstance(numerator_root, Integer) and isinstance(denominator_root, Integer):
            return rational_number(numerator_root.value, denominator_root.value)
        return evaluate(call("Power", argument, rational_number(1, 2)))
    if isinstance(argument, Real):
        info = _real_info(argument)
        if info is None or info.value < 0:
            return None
        return _machine_real(math.sqrt(float(info.value)))
    return None


def _n_precision_argument(expr: Expr | None) -> int | None:
    if expr is None:
        return None
    if isinstance(expr, Symbol) and expr.name == "MachinePrecision":
        return None
    if isinstance(expr, Integer):
        return max(1, expr.value)
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is not None:
            return max(1, int(info.value))
    return None


def _n_expr_from_arguments(arguments: Sequence[Expr]) -> Expr | None:
    if not arguments:
        return None
    expr = arguments[0]
    tail = list(arguments[1:])
    precision_expr: Expr | None = None
    if tail and _option_rule_parts(tail[0]) is None:
        precision_expr = tail.pop(0)
    if any(_option_rule_parts(option) is None for option in tail):
        return None
    return _n_expr(expr, precision_expr, tuple(tail))


def _n_option_precision(options: Sequence[Expr]) -> int | None:
    precision: int | None = None
    for option in options:
        parts = _option_rule_parts(option)
        if parts is None:
            continue
        name, value = parts
        if name not in {"WorkingPrecision", "AccuracyGoal", "PrecisionGoal"}:
            continue
        if isinstance(value, Symbol) and value.name == "Automatic":
            continue
        option_precision = _n_precision_argument(value)
        if option_precision is not None:
            precision = option_precision if precision is None else max(precision, option_precision)
    return precision


def _precision_like_argument(expr: Expr) -> str | int | None:
    if isinstance(expr, Symbol):
        if expr.name == "MachinePrecision":
            return "machine"
        if expr.name == "Infinity":
            return None
    if isinstance(expr, Integer):
        return max(0, expr.value)
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is not None:
            return max(0, int(info.value))
    return "unsupported"


def _n_expr(expr: Expr, precision_expr: Expr | None = None, options: Sequence[Expr] = ()) -> Expr:
    precision = _n_precision_argument(precision_expr)
    option_precision = _n_option_precision(options)
    if option_precision is not None:
        precision = option_precision if precision is None else max(precision, option_precision)
    return _numericize_expr(expr, precision)


class _SympyNumericConversionError(ValueError):
    pass


def _sympy_module():
    import sympy as _sp

    return _sp


def _sympy_constant(name: str):
    _sp = _sympy_module()
    constants = {
        "Pi": _sp.pi,
        "E": _sp.E,
        "EulerGamma": _sp.EulerGamma,
        "GoldenRatio": _sp.GoldenRatio,
        "Catalan": _sp.Catalan,
        "Degree": _sp.pi / _sp.Integer(180),
        "I": _sp.I,
    }
    return constants.get(name)


def _sympy_unary_transcendental_function(name: str):
    _sp = _sympy_module()

    def wolfram_acot(value):
        if value.is_real is True:
            return _sp.pi / 2 - _sp.atan(value)
        return _sp.acot(value)

    functions = {
        "Sin": _sp.sin,
        "Cos": _sp.cos,
        "Tan": _sp.tan,
        "Cot": _sp.cot,
        "Sec": _sp.sec,
        "Csc": _sp.csc,
        "ArcSin": _sp.asin,
        "ArcCos": _sp.acos,
        "ArcTan": _sp.atan,
        "ArcCot": wolfram_acot,
        "ArcSec": _sp.asec,
        "ArcCsc": _sp.acsc,
        "Sinh": _sp.sinh,
        "Cosh": _sp.cosh,
        "Tanh": _sp.tanh,
        "Coth": _sp.coth,
        "Sech": _sp.sech,
        "Csch": _sp.csch,
        "ArcSinh": _sp.asinh,
        "ArcCosh": _sp.acosh,
        "ArcTanh": _sp.atanh,
        "ArcCoth": _sp.acoth,
        "ArcSech": _sp.asech,
        "ArcCsch": _sp.acsch,
        "Haversine": lambda value: (1 - _sp.cos(value)) / 2,
        "InverseHaversine": lambda value: 2 * _sp.asin(_sp.sqrt(value)),
        "Gudermannian": lambda value: 2 * _sp.atan(_sp.tanh(value / 2)),
        "InverseGudermannian": lambda value: _sp.log(_sp.tan(_sp.pi / 4 + value / 2)),
    }
    return functions.get(name)


def _degree_transcendental_base_name(name: str) -> str | None:
    if not name.endswith("Degrees"):
        return None
    base = name[:-7]
    return base if base in _DEGREE_TRANSCENDENTAL_BASE_NAMES else None


_DEGREE_TRANSCENDENTAL_BASE_NAMES = {
    "Sin",
    "Cos",
    "Tan",
    "Cot",
    "Sec",
    "Csc",
    "ArcSin",
    "ArcCos",
    "ArcTan",
    "ArcCot",
    "ArcSec",
    "ArcCsc",
}


def _expr_to_sympy_numeric(expr: Expr):
    _sp = _sympy_module()
    if isinstance(expr, Integer):
        return _sp.Integer(expr.value)
    if isinstance(expr, RationalNumber):
        return _sp.Rational(expr.value.numerator, expr.value.denominator)
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            raise _SympyNumericConversionError(expr.to_full_form())
        return _sp.Float(str(info.value), info.precision or 17)
    if isinstance(expr, ComplexNumber):
        return _expr_to_sympy_numeric(expr.real_part) + _sp.I * _expr_to_sympy_numeric(expr.imaginary_part)
    if isinstance(expr, RootNumber):
        return _expression_algebraic_module()._root_to_sympy(expr)
    if isinstance(expr, Symbol):
        constant = _sympy_constant(expr.name)
        if constant is None:
            raise _SympyNumericConversionError(expr.name)
        return constant
    if isinstance(expr, Call):
        head_name = expr.head_expr.name if isinstance(expr.head_expr, Symbol) else None
        if head_name == "Plus":
            return _sp.Add(*(_expr_to_sympy_numeric(argument) for argument in expr.arguments))
        if head_name == "Times":
            return _sp.Mul(*(_expr_to_sympy_numeric(argument) for argument in expr.arguments))
        if head_name == "Power" and len(expr.arguments) == 2:
            return _sp.Pow(_expr_to_sympy_numeric(expr.arguments[0]), _expr_to_sympy_numeric(expr.arguments[1]))
        if head_name == "Sqrt" and len(expr.arguments) == 1:
            return _sp.sqrt(_expr_to_sympy_numeric(expr.arguments[0]))
        if head_name == "Abs" and len(expr.arguments) == 1:
            return _sp.Abs(_expr_to_sympy_numeric(expr.arguments[0]))
        if head_name == "Exp" and len(expr.arguments) == 1:
            return _sp.exp(_expr_to_sympy_numeric(expr.arguments[0]))
        if head_name == "Log":
            if len(expr.arguments) == 1:
                return _sp.log(_expr_to_sympy_numeric(expr.arguments[0]))
            if len(expr.arguments) == 2:
                return _sp.log(_expr_to_sympy_numeric(expr.arguments[1]), _expr_to_sympy_numeric(expr.arguments[0]))
        if head_name == "ArcTan" and len(expr.arguments) == 2:
            return _sp.atan2(_expr_to_sympy_numeric(expr.arguments[1]), _expr_to_sympy_numeric(expr.arguments[0]))
        degree_base = _degree_transcendental_base_name(head_name or "")
        if degree_base is not None and len(expr.arguments) == 1:
            function = _sympy_unary_transcendental_function(degree_base)
            argument = _expr_to_sympy_numeric(expr.arguments[0])
            if degree_base.startswith("Arc"):
                return function(argument) / (_sp.pi / 180)
            return function(argument * _sp.pi / 180)
        function = _sympy_unary_transcendental_function(head_name or "")
        if function is not None and len(expr.arguments) == 1:
            return function(_expr_to_sympy_numeric(expr.arguments[0]))
    raise _SympyNumericConversionError(expr.to_full_form())


def _sympy_number_to_expr(value, precision: int | None) -> Expr | None:
    _sp = _sympy_module()
    try:
        numeric = _sp.N(value, precision or 17)
    except (TypeError, ValueError):
        return None
    if numeric == _sp.oo or numeric == _sp.zoo:
        return symbol("ComplexInfinity")
    if numeric == -_sp.oo:
        return symbol("-Infinity")
    if numeric is _sp.nan or numeric == _sp.nan:
        return symbol("Indeterminate")
    if not getattr(numeric, "is_number", False):
        return None
    real_part, imaginary_part = numeric.as_real_imag()
    if precision is None:
        try:
            real_expr = _machine_real(float(real_part))
            imaginary_float = float(imaginary_part)
        except (TypeError, ValueError, OverflowError):
            return None
        if imaginary_float == 0.0:
            return real_expr
        return complex_number(real_expr, _machine_real(imaginary_float))

    real_expr = _decimal_from_sympy_real(real_part, precision)
    imaginary_is_zero = bool(imaginary_part == 0)
    if real_expr is None:
        return None
    if imaginary_is_zero:
        return real_expr
    imaginary_expr = _decimal_from_sympy_real(imaginary_part, precision)
    if imaginary_expr is None:
        return None
    return complex_number(real_expr, imaginary_expr)


def _decimal_from_sympy_real(value, precision: int) -> Expr | None:
    _sp = _sympy_module()
    try:
        numeric = _sp.N(value, precision)
        return _decimal_real(Decimal(str(numeric).replace("e", "E")), precision)
    except (InvalidOperation, TypeError, ValueError):
        return None


def _try_numericize_via_sympy(expr: Expr, precision: int | None) -> Expr | None:
    try:
        sympy_expr = _expr_to_sympy_numeric(expr)
    except _SympyNumericConversionError:
        return None
    if getattr(sympy_expr, "free_symbols", None):
        return None
    return _sympy_number_to_expr(sympy_expr, precision)


def _sympy_exact_expr_to_tungsten(expr) -> Expr | None:
    _sp = _sympy_module()
    expr = _sp.sympify(expr)
    if expr is _sp.S.NaN or expr == _sp.nan:
        return symbol("Indeterminate")
    if expr is _sp.S.ComplexInfinity or expr == _sp.zoo:
        return symbol("ComplexInfinity")
    if expr is _sp.S.Infinity or expr == _sp.oo:
        return symbol("Infinity")
    if expr is _sp.S.NegativeInfinity or expr == -_sp.oo:
        return symbol("-Infinity")
    if expr == _sp.I:
        return symbol("I")
    if expr == -_sp.I:
        return complex_number(integer(0), integer(-1))
    if expr == _sp.pi:
        return symbol("Pi")
    if expr == _sp.E:
        return symbol("E")
    if expr.is_Integer:
        return integer(int(expr))
    if expr.is_Rational:
        return rational_number(int(expr.p), int(expr.q))
    if expr.is_number:
        real_part, imaginary_part = expr.as_real_imag()
        if imaginary_part != 0:
            real_expr = _sympy_exact_expr_to_tungsten(real_part)
            imaginary_expr = _sympy_exact_expr_to_tungsten(imaginary_part)
            if real_expr is None or imaginary_expr is None:
                return None
            if _is_real_number_expr(real_expr) and _is_real_number_expr(imaginary_expr):
                return complex_number(real_expr, imaginary_expr)
            imaginary_term = evaluate(call("Times", imaginary_expr, symbol("I")))
            if _is_exact_zero(real_expr):
                return imaginary_term
            return evaluate(call("Plus", real_expr, imaginary_term))
    if expr.is_Add:
        terms = tuple(_sympy_exact_expr_to_tungsten(term) for term in expr.as_ordered_terms())
        if any(term is None for term in terms):
            return None
        return evaluate(call("Plus", *(term for term in terms if term is not None)))
    if expr.is_Mul:
        factors = tuple(_sympy_exact_expr_to_tungsten(factor) for factor in expr.as_ordered_factors())
        if any(factor is None for factor in factors):
            return None
        return evaluate(call("Times", *(factor for factor in factors if factor is not None)))
    if expr.is_Pow:
        base = _sympy_exact_expr_to_tungsten(expr.base)
        exponent = _sympy_exact_expr_to_tungsten(expr.exp)
        if base is None or exponent is None:
            return None
        return evaluate(call("Power", base, exponent))
    if expr.func == _sp.exp and len(expr.args) == 1:
        exponent = _sympy_exact_expr_to_tungsten(expr.args[0])
        return None if exponent is None else evaluate(call("Power", symbol("E"), exponent))
    if expr.func == _sp.log and len(expr.args) == 1:
        argument = _sympy_exact_expr_to_tungsten(expr.args[0])
        return None if argument is None else call("Log", argument)
    function_name = _sympy_function_name(expr)
    if function_name is not None:
        arguments = tuple(_sympy_exact_expr_to_tungsten(argument) for argument in expr.args)
        if any(argument is None for argument in arguments):
            return None
        return call(function_name, *(argument for argument in arguments if argument is not None))
    return None


def _sympy_function_name(expr) -> str | None:
    name_by_function = {
        "sin": "Sin",
        "cos": "Cos",
        "tan": "Tan",
        "cot": "Cot",
        "sec": "Sec",
        "csc": "Csc",
        "asin": "ArcSin",
        "acos": "ArcCos",
        "atan": "ArcTan",
        "acot": "ArcCot",
        "asec": "ArcSec",
        "acsc": "ArcCsc",
        "sinh": "Sinh",
        "cosh": "Cosh",
        "tanh": "Tanh",
        "coth": "Coth",
        "sech": "Sech",
        "csch": "Csch",
        "asinh": "ArcSinh",
        "acosh": "ArcCosh",
        "atanh": "ArcTanh",
        "acoth": "ArcCoth",
        "asech": "ArcSech",
        "acsch": "ArcCsch",
    }
    return name_by_function.get(expr.func.__name__)


def _evaluate_transcendental_function_expr(expr: Call) -> Expr | None:
    head_name = expr.head_expr.name if isinstance(expr.head_expr, Symbol) else None
    if head_name == "Log" and len(expr.arguments) in {1, 2} and _is_numeric_zero(expr.arguments[-1]):
        return symbol("-Infinity")
    if head_name == "Exp":
        if len(expr.arguments) != 1:
            return None
        try:
            sympy_result = _transcendental_call_to_sympy(expr)
            numeric_result = _inexact_transcendental_result(expr, sympy_result)
            if numeric_result is not None:
                return numeric_result
            result = _sympy_exact_expr_to_tungsten(sympy_result)
            if result is not None and result != expr:
                return result
        except _SympyNumericConversionError:
            pass
        return evaluate(call("Power", symbol("E"), expr.arguments[0]))
    if head_name == "Log" and len(expr.arguments) == 2:
        try:
            sympy_result = _transcendental_call_to_sympy(expr)
            numeric_result = _inexact_transcendental_result(expr, sympy_result)
            if numeric_result is not None:
                return numeric_result
            result = _sympy_exact_expr_to_tungsten(sympy_result)
            if result is not None and result != expr:
                return result
        except _SympyNumericConversionError:
            pass
        return evaluate(call("Times", call("Log", expr.arguments[1]), call("Power", call("Log", expr.arguments[0]), integer(-1))))
    try:
        sympy_result = _transcendental_call_to_sympy(expr)
    except _SympyNumericConversionError:
        return None
    numeric_result = _inexact_transcendental_result(expr, sympy_result)
    if numeric_result is not None:
        return numeric_result
    if _transcendental_result_should_remain_inert(head_name or "", sympy_result):
        return None
    result = _sympy_exact_expr_to_tungsten(sympy_result)
    if result is None or result == expr:
        return None
    return result


def _inexact_transcendental_result(expr: Call, sympy_result) -> Expr | None:
    if not any(_expr_contains_inexact_real(argument) for argument in expr.arguments):
        return None
    precision = _combined_inexact_precision(expr.arguments)
    return _sympy_number_to_expr(sympy_result, precision)


def _transcendental_call_to_sympy(expr: Call):
    _sp = _sympy_module()
    head_name = expr.head_expr.name if isinstance(expr.head_expr, Symbol) else None
    if head_name == "Exp" and len(expr.arguments) == 1:
        return _sp.exp(_expr_to_sympy_numeric(expr.arguments[0]))
    if head_name == "Log" and len(expr.arguments) == 1:
        return _sp.log(_expr_to_sympy_numeric(expr.arguments[0]))
    if head_name == "Log" and len(expr.arguments) == 2:
        return _sp.log(_expr_to_sympy_numeric(expr.arguments[1]), _expr_to_sympy_numeric(expr.arguments[0]))
    if head_name == "ArcTan" and len(expr.arguments) == 2:
        return _sp.atan2(_expr_to_sympy_numeric(expr.arguments[1]), _expr_to_sympy_numeric(expr.arguments[0]))
    degree_base = _degree_transcendental_base_name(head_name or "")
    if degree_base is not None and len(expr.arguments) == 1:
        function = _sympy_unary_transcendental_function(degree_base)
        argument = _expr_to_sympy_numeric(expr.arguments[0])
        if degree_base.startswith("Arc"):
            return function(argument) / (_sp.pi / 180)
        return function(argument * _sp.pi / 180)
    function = _sympy_unary_transcendental_function(head_name or "")
    if function is not None and len(expr.arguments) == 1:
        return function(_expr_to_sympy_numeric(expr.arguments[0]))
    raise _SympyNumericConversionError(expr.to_full_form())


def _transcendental_result_should_remain_inert(head_name: str, sympy_result) -> bool:
    _sp = _sympy_module()
    result = _sp.sympify(sympy_result)
    if head_name in {"Haversine", "InverseHaversine", "Gudermannian", "InverseGudermannian"}:
        return bool(result.atoms(_sp.Function))
    degree_base = _degree_transcendental_base_name(head_name)
    if degree_base is not None and degree_base.startswith("Arc") and result.atoms(_sp.Function):
        return True
    if result.has(_sp.log) and head_name != "Log":
        return True
    if head_name.startswith("Arc") and result.atoms(_sp.Function):
        return True
    return False


def _is_real_transcendental_expr(expr: Expr) -> bool:
    if _is_number_expr(expr):
        return False
    if not _is_numeric_transcendental_expr(expr):
        return False
    try:
        sympy_expr = _expr_to_sympy_numeric(expr)
    except _SympyNumericConversionError:
        return False
    return bool(sympy_expr.is_real)


def _is_numeric_transcendental_expr(expr: Expr) -> bool:
    try:
        sympy_expr = _expr_to_sympy_numeric(expr)
    except _SympyNumericConversionError:
        return False
    if getattr(sympy_expr, "free_symbols", None):
        return False
    return bool(getattr(sympy_expr, "is_number", False))


def _numeric_q_value(expr: Expr) -> bool:
    if _is_indeterminate_expr(expr) or _is_complex_infinity_expr(expr):
        return False
    if _is_positive_infinity_expr(expr) or _is_negative_infinity_expr(expr):
        return False
    if _is_number_expr(expr) or isinstance(expr, RootNumber):
        return True
    return _is_numeric_transcendental_expr(expr)


def simplify_expr(expr: Expr) -> Expr:
    if not _numeric_q_value(expr):
        return expr
    candidates = [expr]
    root_reduced = _root_reduce_numeric_candidate(expr)
    if root_reduced is not None:
        candidates.append(root_reduced)
    sympy_simplified = _simplify_numeric_via_sympy(expr)
    if sympy_simplified is not None:
        candidates.append(sympy_simplified)
    return min(candidates, key=_simplification_cost)


def _root_reduce_numeric_candidate(expr: Expr) -> Expr | None:
    try:
        reduced = _expression_algebraic_module()._root_reduce_expr((expr,))
    except Exception:
        return None
    if reduced is None:
        return None
    return evaluate(reduced)


def _simplify_numeric_via_sympy(expr: Expr) -> Expr | None:
    _sp = _sympy_module()
    try:
        sympy_expr = _expr_to_sympy_numeric(expr)
    except _SympyNumericConversionError:
        return None
    if getattr(sympy_expr, "free_symbols", None):
        return None
    try:
        simplified = _low_risk_sympy_simplify(sympy_expr)
    except Exception:
        return None
    if _expr_contains_inexact_real(expr):
        return _sympy_number_to_expr(simplified, _combined_inexact_precision((expr,)))
    converted = _sympy_exact_expr_to_tungsten(simplified)
    if converted is None:
        return None
    return evaluate(converted)


def _low_risk_sympy_simplify(expr):
    _sp = _sympy_module()
    current = _sp.powsimp(expr, combine="all", force=False)
    current = _sp.trigsimp(current, method="matching")
    current = _sp.cancel(current)
    current = _sp.factor_terms(current)
    return current


def _simplification_cost(expr: Expr) -> tuple[int, str]:
    full_form = expr.to_full_form()
    return len(full_form), full_form


def _expr_contains_inexact_real(expr: Expr) -> bool:
    if _contains_inexact_real(expr):
        return True
    if isinstance(expr, Call):
        return any(_expr_contains_inexact_real(argument) for argument in expr.arguments)
    return False


def _compare_transcendental_real_expr(left: Expr, right: Expr) -> int | None:
    try:
        left_sym = _expr_to_sympy_numeric(left)
        right_sym = _expr_to_sympy_numeric(right)
    except _SympyNumericConversionError:
        return None
    if getattr(left_sym, "free_symbols", None) or getattr(right_sym, "free_symbols", None):
        return None
    if left_sym.is_real is not True or right_sym.is_real is not True:
        return None
    difference = left_sym - right_sym
    if difference == 0:
        return 0
    sign = _sympy_proved_sign(difference)
    if sign is not None:
        return sign
    return _sympy_numeric_sign_with_extra_precision(difference)


def _sympy_proved_sign(expr) -> int | None:
    _sp = _sympy_module()
    sign = _sp.sign(expr)
    if sign in {_sp.Integer(-1), _sp.Integer(0), _sp.Integer(1)}:
        return int(sign)
    if expr.is_positive is True:
        return 1
    if expr.is_negative is True:
        return -1
    if expr.is_zero is True:
        return 0
    return None


def _sympy_numeric_sign_with_extra_precision(expr) -> int | None:
    _sp = _sympy_module()
    extra = _finite_system_limit_value("$MaxExtraPrecision")
    max_digits = 80 if extra is None else max(20, 30 + extra)
    digits = 30
    while digits <= max_digits:
        try:
            numeric = _sp.N(expr, digits)
        except (TypeError, ValueError, _sp.PrecisionExhausted):
            return None
        if numeric == 0:
            return 0
        if numeric.is_real is not True:
            return None
        try:
            absolute = abs(numeric)
            if absolute > _sp.Float(10) ** (-(digits - 8)):
                return 1 if numeric > 0 else -1
        except (TypeError, ValueError):
            return None
        digits *= 2
    return None


def _numericize_evaluable_call(expr: Call, precision: int | None) -> Expr | None:
    head_name = expr.head_expr.name if isinstance(expr.head_expr, Symbol) else None
    if head_name in {"Plus", "Times", "Power", "Sqrt", "Abs"} and all(
        _is_number_expr(argument) for argument in expr.arguments
    ):
        evaluated = evaluate(expr)
        if evaluated != expr:
            return _numericize_expr(evaluated, precision)
    degree_base = _degree_transcendental_base_name(head_name or "")
    if (
        head_name in {"Exp", "Log", "ArcTan"}
        or degree_base is not None
        or _sympy_unary_transcendental_function(head_name or "") is not None
    ) and all(_is_number_expr(argument) for argument in expr.arguments):
        return _try_numericize_via_sympy(expr, precision)
    return None


def _numericize_expr(expr: Expr, precision: int | None) -> Expr:
    algebraic = _numericize_algebraic_expr(expr, precision)
    if algebraic is not None:
        return algebraic
    if isinstance(expr, Integer | RationalNumber):
        return _exact_to_real(expr, precision)
    if isinstance(expr, ComplexNumber):
        return complex_number(
            _numericize_expr(expr.real_part, precision),
            _numericize_expr(expr.imaginary_part, precision),
        )
    if isinstance(expr, Symbol):
        constant = _sympy_constant(expr.name)
        if constant is not None:
            numeric_constant = _sympy_number_to_expr(constant, precision)
            if numeric_constant is not None:
                return numeric_constant
        return expr
    if isinstance(expr, Real | SpecialReal | String | ByteArrayExpr):
        return expr
    if isinstance(expr, Call):
        sympy_numeric = _try_numericize_via_sympy(expr, precision)
        if sympy_numeric is not None:
            return sympy_numeric
        numericized = Call(
            head_expr=expr.head_expr,
            arguments=tuple(_numericize_expr(argument, precision) for argument in expr.arguments),
        )
        evaluated = _numericize_evaluable_call(numericized, precision)
        if evaluated is not None:
            return evaluated
        return numericized
    return expr


def _exact_to_real(expr: Expr, precision: int | None) -> Expr:
    exact = _exact_fraction(expr)
    if exact is None:
        return expr
    if precision is None:
        return _machine_real(float(exact))
    with localcontext() as context:
        context.prec = max(precision, 1)
        return _decimal_real(Decimal(exact.numerator) / Decimal(exact.denominator), precision)


def _real_to_fraction(expr: Real) -> Expr:
    info = _real_info(expr)
    if info is None:
        return expr
    return _fraction_expr(Fraction(info.value))


def _set_precision_expr(expr: Expr, precision_expr: Expr) -> Expr:
    precision = _precision_like_argument(precision_expr)
    if precision == "unsupported":
        return call("SetPrecision", expr, precision_expr)
    return _set_precision_recursive(expr, precision)


def _set_precision_recursive(expr: Expr, precision: str | int | None) -> Expr:
    if precision == "machine":
        return _numericize_expr(expr, None)
    if precision is None:
        if isinstance(expr, Real):
            return _real_to_fraction(expr)
        if isinstance(expr, ComplexNumber):
            return complex_number(
                _set_precision_recursive(expr.real_part, precision),
                _set_precision_recursive(expr.imaginary_part, precision),
            )
        if isinstance(expr, Call):
            return Call(expr.head_expr, tuple(_set_precision_recursive(argument, precision) for argument in expr.arguments))
        return expr
    if isinstance(precision, int):
        if _is_exact_real_number(expr):
            return _exact_to_real(expr, max(1, precision))
        if isinstance(expr, Real):
            info = _real_info(expr)
            if info is None:
                return expr
            return _decimal_real(info.value, max(1, precision))
        if isinstance(expr, ComplexNumber):
            return complex_number(
                _set_precision_recursive(expr.real_part, precision),
                _set_precision_recursive(expr.imaginary_part, precision),
            )
        if isinstance(expr, Call):
            return Call(expr.head_expr, tuple(_set_precision_recursive(argument, precision) for argument in expr.arguments))
    return expr


def _set_accuracy_expr(expr: Expr, accuracy_expr: Expr) -> Expr:
    accuracy = _precision_like_argument(accuracy_expr)
    if accuracy == "unsupported":
        return call("SetAccuracy", expr, accuracy_expr)
    return _set_accuracy_recursive(expr, accuracy)


def _set_accuracy_recursive(expr: Expr, accuracy: str | int | None) -> Expr:
    if accuracy == "machine":
        return _numericize_expr(expr, None)
    if accuracy is None:
        return _set_precision_recursive(expr, None)
    if isinstance(accuracy, int):
        if _is_exact_real_number(expr):
            exact = _exact_fraction(expr)
            assert exact is not None
            with localcontext() as context:
                context.prec = max(accuracy + 8, 16)
                return _decimal_real_accuracy(Decimal(exact.numerator) / Decimal(exact.denominator), accuracy)
        if isinstance(expr, Real):
            info = _real_info(expr)
            if info is None:
                return expr
            return _decimal_real_accuracy(info.value, accuracy)
        if isinstance(expr, ComplexNumber):
            return complex_number(
                _set_accuracy_recursive(expr.real_part, accuracy),
                _set_accuracy_recursive(expr.imaginary_part, accuracy),
            )
        if isinstance(expr, Call):
            return Call(expr.head_expr, tuple(_set_accuracy_recursive(argument, accuracy) for argument in expr.arguments))
    return expr


def _precision_expr(expr: Expr) -> Expr:
    precision = _precision_value(expr)
    if precision == "machine":
        return symbol("MachinePrecision")
    if precision is None:
        return symbol("Infinity")
    return _machine_real(float(precision))


def _precision_value(expr: Expr) -> float | str | None:
    if _is_exact_real_number(expr):
        return None
    if isinstance(expr, RootNumber):
        return None
    if isinstance(expr, SpecialReal):
        return 0.0
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            return "machine"
        return _effective_real_precision(info)
    if isinstance(expr, ComplexNumber):
        real_precision = _precision_value(expr.real_part)
        imaginary_precision = _precision_value(expr.imaginary_part)
        if real_precision == "machine" or imaginary_precision == "machine":
            return "machine"
        explicit = [value for value in (real_precision, imaginary_precision) if isinstance(value, int | float)]
        if explicit:
            return min(explicit)
        return None
    if isinstance(expr, Call):
        child_precisions = [_precision_value(argument) for argument in expr.arguments]
        if any(precision == "machine" for precision in child_precisions):
            return "machine"
        explicit = [precision for precision in child_precisions if isinstance(precision, int | float)]
        if explicit:
            return min(explicit)
    return None


def _accuracy_expr(expr: Expr) -> Expr:
    accuracy = _accuracy_value(expr)
    if accuracy is None:
        return symbol("Infinity")
    if math.isinf(accuracy):
        return symbol("Infinity") if accuracy > 0 else symbol("-Infinity")
    return _machine_real(float(accuracy))


def _accuracy_value(expr: Expr) -> float | None:
    if _is_exact_real_number(expr):
        return None
    if isinstance(expr, RootNumber):
        return None
    if isinstance(expr, SpecialReal):
        return float("-inf") if expr.name == "Overflow" else float("inf")
    if isinstance(expr, Real):
        info = _real_info(expr)
        if info is None:
            return None
        value = _effective_real_accuracy(info)
        if value == "machine":
            return sys.float_info.mant_dig * math.log10(2)
        return float(value)
    if isinstance(expr, ComplexNumber):
        real_accuracy = _accuracy_value(expr.real_part)
        imaginary_accuracy = _accuracy_value(expr.imaginary_part)
        explicit = [value for value in (real_accuracy, imaginary_accuracy) if value is not None]
        if explicit:
            return min(explicit)
        return None
    if isinstance(expr, Call):
        explicit = [value for value in (_accuracy_value(argument) for argument in expr.arguments) if value is not None]
        if explicit:
            return min(explicit)
    return None


def byte_array(arguments: Sequence[Expr]) -> ByteArrayExpr:
    if len(arguments) != 1:
        raise WolframEvaluationError("ByteArray expects exactly one argument.")
    source = arguments[0]
    if isinstance(source, ByteArrayExpr):
        return source
    if isinstance(source, String):
        try:
            decoded = base64.b64decode(source.value.encode("ascii"), validate=True)
        except (UnicodeEncodeError, binascii.Error) as exc:
            raise WolframEvaluationError("ByteArray string input must be valid Base64.") from exc
        return byte_array_expr(decoded)
    if isinstance(source, Call) and source.has_head("List"):
        values = _integer_values(source.arguments)
        if values is None:
            raise WolframEvaluationError("ByteArray list input must contain only integers.")
        return byte_array_expr(values)
    raise WolframEvaluationError("ByteArray expects a byte list, a Base64 string, or another ByteArray.")


def _require_byte_array(expr: Expr, function_name: str, *, allow_empty_list: bool = False) -> ByteArrayExpr:
    if isinstance(expr, ByteArrayExpr):
        return expr
    if allow_empty_list and isinstance(expr, Call) and expr.has_head("List") and not expr.arguments:
        return byte_array_expr(())
    raise WolframEvaluationError(f"{function_name} expects a ByteArray.")


def base_encode(byte_array_value: Expr, encoding_value: Expr | None = None) -> String:
    values = _require_byte_array(byte_array_value, "BaseEncode").values
    encoding_name = "Base64" if encoding_value is None else _normalize_base_encoding_name(encoding_value, "BaseEncode")
    payload = bytes(values)
    if encoding_name == "Base64":
        return string(base64.b64encode(payload).decode("ascii"))
    if encoding_name == "Base16":
        return string(base64.b16encode(payload).decode("ascii"))
    assert encoding_name == "Base85ASCII"
    return string(base64.a85encode(payload).decode("ascii"))


def _filter_base_decode_input(text: str, encoding_name: str) -> str:
    if encoding_name == "Base16":
        return "".join(character for character in text if character in "0123456789abcdefABCDEF")
    if encoding_name == "Base64":
        return "".join(
            character
            for character in text
            if character.isalnum() or character in "+/=_-"
        )
    return "".join(character for character in text if character == "z" or "!" <= character <= "u")


def base_decode(text_value: Expr, encoding_value: Expr | None = None) -> ByteArrayExpr:
    if not isinstance(text_value, String):
        raise WolframEvaluationError("BaseDecode expects the input data to be a string.")
    encoding_name = "Base64" if encoding_value is None else _normalize_base_encoding_name(encoding_value, "BaseDecode")
    filtered = _filter_base_decode_input(text_value.value, encoding_name)
    try:
        if encoding_name == "Base64":
            decoded = base64.b64decode(filtered.encode("ascii"), validate=False)
        elif encoding_name == "Base16":
            decoded = base64.b16decode(filtered.encode("ascii"), casefold=True)
        else:
            decoded = base64.a85decode(filtered.encode("ascii"), adobe=False, ignorechars=b" \t\n\r\v")
    except (UnicodeEncodeError, binascii.Error, ValueError) as exc:
        raise WolframEvaluationError(f"BaseDecode failed for {encoding_name}.") from exc
    return byte_array_expr(decoded)


def characters(expr: Expr) -> Expr:
    if isinstance(expr, String):
        return list_expr(*(string(character) for character in expr.value))
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(*(characters(item) for item in expr.arguments))
    raise WolframEvaluationError("Characters expects a string or a list of strings.")


def to_character_code(expr: Expr, encoding_value: Expr | None = None) -> Expr:
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "ToCharacterCode",
        default_unicode=True,
    )
    if isinstance(expr, String):
        return list_expr(*_string_to_character_codes(expr.value, encoding_name))
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(*(to_character_code(item, encoding_value) for item in expr.arguments))
    raise WolframEvaluationError("ToCharacterCode expects a string or a list of strings.")


def _int_list(expr: Expr, function_name: str) -> list[int]:
    if isinstance(expr, Integer):
        return [expr.value]
    if isinstance(expr, Call) and expr.has_head("List"):
        values = _integer_values(expr.arguments)
        if values is None:
            raise WolframEvaluationError(f"{function_name} expects an integer or a list of integers.")
        return values
    raise WolframEvaluationError(f"{function_name} expects an integer or a list of integers.")


def from_character_code(expr: Expr, encoding_value: Expr | None = None) -> String:
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "FromCharacterCode",
        default_unicode=True,
    )
    values = _int_list(expr, "FromCharacterCode")
    if encoding_name == "Unicode":
        try:
            return string("".join(chr(value) for value in values))
        except ValueError as exc:
            raise WolframEvaluationError("FromCharacterCode Unicode input must contain valid code points.") from exc
    if any(value < 0 or value > 0x10FFFF for value in values):
        raise WolframEvaluationError("FromCharacterCode input must contain valid non-negative Unicode code points.")
    pieces: list[str] = []
    pending_bytes: list[int] = []

    def flush_pending_bytes() -> None:
        if pending_bytes:
            pieces.append(_decode_bytes_to_string(bytes(pending_bytes), encoding_name))
            pending_bytes.clear()

    for value in values:
        if value <= 255:
            pending_bytes.append(value)
        else:
            flush_pending_bytes()
            try:
                pieces.append(chr(value))
            except ValueError as exc:
                raise WolframEvaluationError("FromCharacterCode input must contain valid Unicode code points.") from exc
    flush_pending_bytes()
    return string("".join(pieces))


def string_to_byte_array(expr: Expr, encoding_value: Expr | None = None) -> ByteArrayExpr:
    if not isinstance(expr, String):
        raise WolframEvaluationError("StringToByteArray expects a string.")
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "StringToByteArray",
        default_unicode=False,
    )
    if encoding_name == "Unicode":
        raise WolframEvaluationError('StringToByteArray does not currently support the "Unicode" pseudo-encoding.')
    if encoding_name == "PrintableASCII":
        encoding_name = "ascii"
    try:
        return byte_array_expr(expr.value.encode(encoding_name))
    except (LookupError, UnicodeEncodeError) as exc:
        raise WolframEvaluationError(
            f'StringToByteArray could not represent the string in encoding {encoding_value.to_input_form() if encoding_value is not None else "\"UTF-8\""}.'
        ) from exc


def byte_array_to_string(expr: Expr, encoding_value: Expr | None = None) -> String:
    byte_values = _require_byte_array(expr, "ByteArrayToString", allow_empty_list=True).values
    encoding_name, _display_name = _normalize_character_encoding_name(
        encoding_value,
        "ByteArrayToString",
        default_unicode=False,
    )
    if encoding_name == "Unicode":
        raise WolframEvaluationError('ByteArrayToString does not currently support the "Unicode" pseudo-encoding.')
    return string(_decode_bytes_to_string(bytes(byte_values), encoding_name))


_TEXTUAL_EXPRESSION_FORM_NAMES = {
    "c": "CForm",
    "cform": "CForm",
    "input": "InputForm",
    "inputform": "InputForm",
    "fortran": "FortranForm",
    "fortranform": "FortranForm",
    "mathml": "MathMLForm",
    "mathmlform": "MathMLForm",
    "output": "OutputForm",
    "outputform": "OutputForm",
    "standard": "StandardForm",
    "standardform": "StandardForm",
    "text": "TextForm",
    "textform": "TextForm",
    "tex": "TeXForm",
    "texform": "TeXForm",
    "traditional": "TraditionalForm",
    "traditionalform": "TraditionalForm",
}

_PARSE_TEXTUAL_EXPRESSION_FORM_NAMES = {"InputForm", "StandardForm", "TraditionalForm", "TeXForm", "MathMLForm"}
_RENDER_TEXTUAL_EXPRESSION_FORM_NAMES = {
    "CForm",
    "FortranForm",
    "InputForm",
    "MathMLForm",
    "OutputForm",
    "StandardForm",
    "TextForm",
    "TeXForm",
    "TraditionalForm",
}
_BOX_EXPRESSION_FORM_NAMES = {"InputForm", "StandardForm", "TraditionalForm"}


def _normalize_textual_expression_form(
    value: Expr | None,
    function_name: str,
    *,
    purpose: str = "parse",
) -> str:
    if value is None:
        return "InputForm"
    if isinstance(value, Symbol):
        key = value.name.strip().lower()
    elif isinstance(value, String):
        key = value.value.strip().lower()
    else:
        raise WolframEvaluationError(f"{function_name} expects a supported expression form specification.")
    normalized = _TEXTUAL_EXPRESSION_FORM_NAMES.get(key)
    supported = _RENDER_TEXTUAL_EXPRESSION_FORM_NAMES if purpose == "render" else _PARSE_TEXTUAL_EXPRESSION_FORM_NAMES
    if normalized is None or normalized not in supported:
        raise WolframEvaluationError(f"{function_name} does not support this expression form.")
    return normalized


def _normalize_box_expression_form(value: Expr | None, function_name: str) -> str:
    if value is None:
        return "StandardForm"
    normalized = _normalize_textual_expression_form(value, function_name)
    if normalized not in _BOX_EXPRESSION_FORM_NAMES:
        raise WolframEvaluationError(
            f"{function_name} supports InputForm, StandardForm, and TraditionalForm as box forms."
        )
    return normalized


_STANDARD_FORM_BOX_HEADS = {
    "AdjustmentBox",
    "BoxData",
    "FormBox",
    "FrameBox",
    "GridBox",
    "OverscriptBox",
    "PaneBox",
    "StyleBox",
    "SubscriptBox",
    "SubsuperscriptBox",
    "TagBox",
    "TemplateBox",
    "TooltipBox",
    "FractionBox",
    "InterpretationBox",
    "RadicalBox",
    "RowBox",
    "SqrtBox",
    "SuperscriptBox",
    "UnderscriptBox",
    "UnderoverscriptBox",
}


_DISPLAY_FORM_HEADS = {
    "AccountingForm",
    "BaseForm",
    "CForm",
    "DecimalForm",
    "DisplayForm",
    "EngineeringForm",
    "FortranForm",
    "FullForm",
    "InputForm",
    "MathMLForm",
    "MatrixForm",
    "NumberForm",
    "OutputForm",
    "PaddedForm",
    "PercentForm",
    "PrintForm",
    "ScientificForm",
    "SequenceForm",
    "StandardForm",
    "StringForm",
    "TableForm",
    "TextForm",
    "TeXForm",
    "TraditionalForm",
    "TreeForm",
}

_VALUE_STRIPPING_DISPLAY_FORM_HEADS = {
    "CForm",
    "FortranForm",
    "FullForm",
    "InputForm",
    "MathMLForm",
    "OutputForm",
    "PrintForm",
    "SequenceForm",
    "StandardForm",
    "TextForm",
    "TeXForm",
    "TraditionalForm",
}

_TEXT_RENDERING_DISPLAY_FORM_HEADS = {
    "CForm",
    "FortranForm",
    "MathMLForm",
    "OutputForm",
    "PrintForm",
    "SequenceForm",
    "TextForm",
    "TeXForm",
    "TraditionalForm",
}


@dataclass(frozen=True)
class _DisplayFormCall:
    name: str
    arguments: tuple[Expr, ...]

    @property
    def payload(self) -> Expr:
        return self.arguments[0]

    @property
    def specs(self) -> tuple[Expr, ...]:
        return self.arguments[1:]

    def as_expr(self) -> Expr:
        return call(self.name, *self.arguments)


def _display_form_wrapper(expr: Expr) -> tuple[str, Expr] | None:
    wrapper = _display_form_call(expr)
    if wrapper is None:
        return None
    return wrapper.name, wrapper.payload


def _display_form_call(expr: Expr) -> _DisplayFormCall | None:
    if not isinstance(expr, Call) or not expr.arguments or not isinstance(expr.head_expr, Symbol):
        return None
    head_name = _system_dispatch_name(expr.head_expr)
    if head_name not in _DISPLAY_FORM_HEADS:
        return None
    return _DisplayFormCall(head_name, expr.arguments)


def _display_form_call_text(wrapper: _DisplayFormCall) -> str:
    return _display_form_text(wrapper.payload, wrapper.name, wrapper.specs)


def _display_form_text(expr: Expr, form_name: str, specs: Sequence[Expr] = ()) -> str:
    if form_name in {"OutputForm", "TextForm", "PrintForm"}:
        return _output_form_text(expr)
    if form_name == "FullForm":
        return expr.to_full_form()
    if form_name == "TraditionalForm":
        return _traditional_form_text(expr)
    if form_name == "TeXForm":
        return _tex_form_text(expr)
    if form_name == "MathMLForm":
        return _mathml_form_text(expr)
    if form_name == "CForm":
        return _c_like_form_text(expr, target="c")
    if form_name == "FortranForm":
        return _c_like_form_text(expr, target="fortran")
    if form_name in {"NumberForm", "DecimalForm", "ScientificForm", "EngineeringForm", "AccountingForm", "PaddedForm", "PercentForm"}:
        return _number_display_form_text(expr, form_name, specs)
    if form_name == "BaseForm":
        return _base_form_text(expr, specs)
    if form_name in {"TableForm", "MatrixForm"}:
        return _table_form_text(expr)
    if form_name == "TreeForm":
        return _tree_form_text(expr)
    if form_name == "DisplayForm":
        return _display_form_boxes_text(expr)
    if form_name == "SequenceForm":
        return _sequence_form_text((expr, *specs))
    if form_name == "StringForm":
        return _string_form_text(expr, specs)
    return expr.to_input_form()


def _output_form_text(expr: Expr) -> str:
    return _format_structured_text(expr, _format_output_atom)


def _traditional_form_text(expr: Expr) -> str:
    return inline_box_escape(call("FormBox", _make_traditional_boxes(expr), symbol("TraditionalForm")).to_input_form())


def _tex_form_text(expr: Expr) -> str:
    wrapper = _display_form_wrapper(expr)
    if wrapper is not None:
        form_name, payload = wrapper
        if form_name == "StandardForm":
            return _tex_format_expr(payload, traditional=False)
        if form_name == "InputForm":
            return _tex_escape_text(payload.to_input_form())
        if form_name == "FullForm":
            return _tex_escape_text(payload.to_full_form())
        if form_name == "OutputForm":
            return _tex_escape_text(payload.to_input_form())
        if form_name == "TraditionalForm":
            return _tex_format_expr(payload, traditional=True)
    return _tex_format_expr(expr, traditional=True)


def _mathml_form_text(expr: Expr) -> str:
    wrapper = _display_form_wrapper(expr)
    traditional = True
    payload = expr
    if wrapper is not None:
        form_name, payload = wrapper
        traditional = form_name != "StandardForm"
    body = _mathml_format_expr(payload, traditional=traditional)
    return "<math>\n" + _indent_xml(body, 1) + "\n</math>\n"


def _traditional_plus_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    nonnumeric = [argument for argument in arguments if not _is_number_expr(argument)]
    numeric = [argument for argument in arguments if _is_number_expr(argument)]
    return tuple(nonnumeric + numeric)


def _format_structured_text(expr: Expr, atom_formatter: Callable[[Expr], str]) -> str:
    entries = _association_entries(expr)
    if entries is not None:
        pieces = [
            f"{_format_structured_text(entry.key, atom_formatter)} {' :> ' if entry.rule_head == 'RuleDelayed' else ' -> '}{_format_structured_text(entry.value, atom_formatter)}"
            for entry in entries
        ]
        return "<|" + ", ".join(pieces) + "|>"
    if isinstance(expr, Call) and isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        arguments = expr.arguments
        if head_name == "List":
            return "{" + ", ".join(_format_structured_text(argument, atom_formatter) for argument in arguments) + "}"
        if head_name == "Rule" and len(arguments) == 2:
            return (
                _format_structured_text(arguments[0], atom_formatter)
                + " -> "
                + _format_structured_text(arguments[1], atom_formatter)
            )
        if head_name == "RuleDelayed" and len(arguments) == 2:
            return (
                _format_structured_text(arguments[0], atom_formatter)
                + " :> "
                + _format_structured_text(arguments[1], atom_formatter)
            )
        if head_name == "Plus" and arguments:
            return " + ".join(_format_structured_text(argument, atom_formatter) for argument in arguments)
        if head_name == "Times" and arguments:
            return " ".join(_format_structured_text(argument, atom_formatter) for argument in arguments)
        if head_name == "Power" and len(arguments) == 2:
            base, exponent = arguments
            exponent_text = _format_structured_text(exponent, atom_formatter)
            if isinstance(exponent, RationalNumber) or (
                isinstance(exponent, Call)
                and isinstance(exponent.head_expr, Symbol)
                and _system_dispatch_name(exponent.head_expr) in {"Plus", "Times", "Rational"}
            ):
                exponent_text = f"({exponent_text})"
            return _format_structured_text(base, atom_formatter) + "^" + exponent_text
        if head_name == "Rational" and len(arguments) == 2:
            return (
                _format_structured_text(arguments[0], atom_formatter)
                + "/"
                + _format_structured_text(arguments[1], atom_formatter)
            )
    if isinstance(expr, Call):
        head = _format_structured_text(expr.head_expr, atom_formatter)
        arguments = ", ".join(_format_structured_text(argument, atom_formatter) for argument in expr.arguments)
        return f"{head}[{arguments}]"
    return atom_formatter(expr)


def _format_output_atom(expr: Expr) -> str:
    if isinstance(expr, String):
        return expr.value
    return expr.to_input_form()


def _c_like_form_text(expr: Expr, *, target: str) -> str:
    if isinstance(expr, Symbol):
        return expr.to_input_form()
    if isinstance(expr, Integer):
        return str(expr.value)
    if isinstance(expr, Real):
        return expr.text.replace("*^", "e")
    if isinstance(expr, RationalNumber):
        return _format_float_like(float(expr.value))
    if isinstance(expr, SpecialReal):
        return expr.name
    if isinstance(expr, ComplexNumber):
        return f"Complex({_c_like_form_text(expr.real_part, target=target)},{_c_like_form_text(expr.imaginary_part, target=target)})"
    if isinstance(expr, String):
        return wl_string(expr.value)
    if isinstance(expr, ByteArrayExpr):
        return _c_like_form_text(call("ByteArray", list_expr(*(integer(value) for value in expr.values))), target=target)
    if not isinstance(expr, Call):
        return expr.to_input_form()

    if isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        arguments = expr.arguments
        if head_name == "List":
            return "List(" + ",".join(_c_like_form_text(argument, target=target) for argument in arguments) + ")"
        if head_name == "Association":
            return "Association(" + ",".join(_c_like_form_text(argument, target=target) for argument in arguments) + ")"
        if head_name in {"Rule", "RuleDelayed"} and len(arguments) == 2:
            return (
                "Rule("
                + _c_like_form_text(arguments[0], target=target)
                + ","
                + _c_like_form_text(arguments[1], target=target)
                + ")"
            )
        if head_name == "Plus" and arguments:
            return " + ".join(_c_like_form_text(argument, target=target) for argument in arguments)
        if head_name == "Times" and arguments:
            return "*".join(_c_like_factor_text(argument, target=target) for argument in arguments)
        if head_name == "Power" and len(arguments) == 2:
            base, exponent = arguments
            if _is_half_power_exponent(exponent):
                return "Sqrt(" + _c_like_form_text(base, target=target) + ")"
            if target == "fortran":
                return _c_like_factor_text(base, target=target) + "**" + _c_like_factor_text(exponent, target=target)
            return "Power(" + _c_like_form_text(base, target=target) + "," + _c_like_form_text(exponent, target=target) + ")"
        if head_name == "Rational" and len(arguments) == 2:
            return (
                "("
                + _c_like_form_text(arguments[0], target=target)
                + ")/("
                + _c_like_form_text(arguments[1], target=target)
                + ")"
            )

    head = _c_like_form_text(expr.head_expr, target=target)
    arguments = ",".join(_c_like_form_text(argument, target=target) for argument in expr.arguments)
    return f"{head}({arguments})"


def _c_like_factor_text(expr: Expr, *, target: str) -> str:
    if isinstance(expr, Call) and isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        if head_name in {"Plus", "Rule", "RuleDelayed"}:
            return "(" + _c_like_form_text(expr, target=target) + ")"
    return _c_like_form_text(expr, target=target)


def _is_half_power_exponent(expr: Expr) -> bool:
    if isinstance(expr, RationalNumber):
        return expr.value == Fraction(1, 2)
    return (
        isinstance(expr, Call)
        and expr.has_head("Rational")
        and len(expr.arguments) == 2
        and isinstance(expr.arguments[0], Integer)
        and isinstance(expr.arguments[1], Integer)
        and expr.arguments[0].value == 1
        and expr.arguments[1].value == 2
    )


def _format_float_like(value: float) -> str:
    if math.isnan(value) or math.isinf(value):
        return str(value)
    return format(value, ".16g")


def _number_display_form_text(expr: Expr, form_name: str, specs: Sequence[Expr]) -> str:
    total_digits, fraction_digits = _number_form_digit_specs(specs)

    def formatter(atom: Expr) -> str:
        return _format_number_display_atom(
            atom,
            form_name,
            total_digits=total_digits,
            fraction_digits=fraction_digits,
        )

    return _format_structured_text(expr, formatter)


def _number_form_digit_specs(specs: Sequence[Expr]) -> tuple[int | None, int | None]:
    if not specs:
        return None, None
    spec = specs[0]
    if isinstance(spec, Integer):
        return max(0, spec.value), None
    if isinstance(spec, Call) and spec.has_head("List") and spec.arguments:
        total = spec.arguments[0]
        fraction = spec.arguments[1] if len(spec.arguments) > 1 else None
        return (
            max(0, total.value) if isinstance(total, Integer) else None,
            max(0, fraction.value) if isinstance(fraction, Integer) else None,
        )
    return None, None


def _format_number_display_atom(
    expr: Expr,
    form_name: str,
    *,
    total_digits: int | None,
    fraction_digits: int | None,
) -> str:
    if isinstance(expr, Real):
        value = _real_to_float(expr)
        if form_name == "PercentForm":
            value *= 100
        text = _format_decimal_text(value, total_digits=total_digits, fraction_digits=fraction_digits, form_name=form_name)
    elif isinstance(expr, Integer):
        text = str(expr.value * 100) if form_name == "PercentForm" else str(expr.value)
    else:
        return _format_output_atom(expr)

    if form_name == "AccountingForm" and text.startswith("-"):
        text = f"({text[1:]})"
    if form_name == "PercentForm":
        text += "%"
    if form_name == "PaddedForm" and total_digits is not None:
        text = text.rjust(total_digits)
    return text


def _real_to_float(expr: Real) -> float:
    text = expr.text.replace("`", "").replace("*^", "e")
    try:
        return float(text)
    except ValueError:
        return math.nan


def _format_decimal_text(
    value: float,
    *,
    total_digits: int | None,
    fraction_digits: int | None,
    form_name: str,
) -> str:
    if math.isnan(value) or math.isinf(value):
        return str(value)
    if fraction_digits is not None:
        base = f"{value:.{fraction_digits}f}"
    elif total_digits is not None and total_digits > 0:
        base = f"{value:.{total_digits}g}"
    else:
        base = _format_float_like(value)

    if form_name == "DecimalForm":
        return base
    if form_name == "ScientificForm":
        digits = max(1, total_digits or 6)
        return f"{value:.{digits - 1}e}".replace("e", "*10^")
    if form_name == "EngineeringForm":
        return _format_engineering_text(value, total_digits or 6)
    return base


def _format_engineering_text(value: float, digits: int) -> str:
    if value == 0:
        return "0"
    exponent = int(math.floor(math.log10(abs(value)) / 3) * 3)
    mantissa = value / (10 ** exponent)
    return f"{mantissa:.{max(0, digits - 1)}g}*10^{exponent}"


def _base_form_text(expr: Expr, specs: Sequence[Expr]) -> str:
    base = _base_form_base(specs)

    def formatter(atom: Expr) -> str:
        if isinstance(atom, Integer):
            return _integer_base_text(atom.value, base)
        if isinstance(atom, Real):
            return atom.text + f"_{base}"
        if isinstance(atom, RationalNumber):
            return _integer_base_text(atom.value.numerator, base) + "/" + _integer_base_text(atom.value.denominator, base)
        return _format_output_atom(atom)

    return _format_structured_text(expr, formatter)


def _base_form_base(specs: Sequence[Expr]) -> int:
    if specs and isinstance(specs[0], Integer):
        return min(36, max(2, specs[0].value))
    return 10


def _integer_base_text(value: int, base: int) -> str:
    digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    sign = "-" if value < 0 else ""
    remaining = abs(value)
    if remaining == 0:
        body = "0"
    else:
        pieces: list[str] = []
        while remaining:
            remaining, digit = divmod(remaining, base)
            pieces.append(digits[digit])
        body = "".join(reversed(pieces))
    return f"{base}^^{sign}{body}"


def _table_form_text(expr: Expr) -> str:
    rows = _table_rows(expr)
    if rows is None:
        return _output_form_text(expr)
    if not rows:
        return ""
    widths = [0] * max(len(row) for row in rows)
    for row in rows:
        for index, cell in enumerate(row):
            widths[index] = max(widths[index], len(cell))
    rendered_rows = [
        "   ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)).rstrip()
        for row in rows
    ]
    return "\n".join(rendered_rows)


def _table_rows(expr: Expr) -> list[list[str]] | None:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return None
    if all(isinstance(row, Call) and row.has_head("List") for row in expr.arguments):
        return [
            [_output_form_text(cell) for cell in row.arguments]
            for row in expr.arguments
            if isinstance(row, Call)
        ]
    return [[_output_form_text(item)] for item in expr.arguments]


def _tree_form_text(expr: Expr) -> str:
    if not isinstance(expr, Call):
        return _output_form_text(expr)
    return expr.to_full_form()


def _display_form_boxes_text(expr: Expr) -> str:
    if _looks_like_standard_form_boxes(expr):
        try:
            return _box_item_to_standard_text(_strip_box_expression(expr))
        except (WolframSyntaxError, WolframEvaluationError, ValueError):
            return expr.to_input_form()
    return _output_form_text(expr)


def _sequence_form_text(arguments: Sequence[Expr]) -> str:
    return "".join(_output_form_text(argument) for argument in arguments)


def _string_form_text(template: Expr, arguments: Sequence[Expr]) -> str:
    if not isinstance(template, String):
        return _format_structured_text(call("StringForm", template, *arguments), _format_output_atom)
    rendered_arguments = [_output_form_text(argument) for argument in arguments]
    text = template.value
    for index, value in enumerate(rendered_arguments, start=1):
        text = text.replace(f"`{index}`", value)
    for value in rendered_arguments:
        if "``" not in text:
            break
        text = text.replace("``", value, 1)
    return text


def _tex_format_expr(expr: Expr, *, traditional: bool) -> str:
    if isinstance(expr, Symbol):
        return _tex_symbol_name(expr.to_input_form())
    if isinstance(expr, Integer):
        return str(expr.value)
    if isinstance(expr, RationalNumber):
        return rf"\frac{{{expr.value.numerator}}}{{{expr.value.denominator}}}"
    if isinstance(expr, Real):
        return _tex_escape_text(expr.text)
    if isinstance(expr, SpecialReal):
        return _tex_escape_text(expr.name)
    if isinstance(expr, ComplexNumber):
        return _tex_format_expr(call("Complex", expr.real_part, expr.imaginary_part), traditional=traditional)
    if isinstance(expr, String):
        return r"\text{" + _tex_escape_text(wl_string(expr.value)) + "}"
    if isinstance(expr, ByteArrayExpr):
        return _tex_escape_text(expr.to_input_form())
    if not isinstance(expr, Call):
        return _tex_escape_text(expr.to_input_form())

    if isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        arguments = expr.arguments
        if head_name == "List":
            return r"\{" + ", ".join(_tex_format_expr(argument, traditional=traditional) for argument in arguments) + r"\}"
        if head_name == "Association":
            return r"\langle|" + ", ".join(_tex_format_expr(argument, traditional=traditional) for argument in arguments) + r"|\rangle"
        if head_name == "Rule" and len(arguments) == 2:
            return (
                _tex_format_expr(arguments[0], traditional=traditional)
                + r"\to "
                + _tex_format_expr(arguments[1], traditional=traditional)
            )
        if head_name == "RuleDelayed" and len(arguments) == 2:
            return (
                _tex_format_expr(arguments[0], traditional=traditional)
                + r"\mathrel{:}\joinrel\to "
                + _tex_format_expr(arguments[1], traditional=traditional)
            )
        escaped_tex_operator = _ESCAPED_INFIX_TEX_OPERATORS.get(head_name)
        if escaped_tex_operator is not None and len(arguments) >= 2:
            return _tex_escaped_infix(
                arguments,
                escaped_tex_operator,
                _escaped_infix_operator_precedence(head_name),
                traditional=traditional,
            )
        if head_name == "Plus" and arguments:
            ordered = _traditional_plus_arguments(arguments) if traditional else arguments
            return "+".join(_tex_format_expr(argument, traditional=traditional) for argument in ordered)
        if head_name == "Times" and arguments:
            return " ".join(_tex_factor_text(argument, traditional=traditional) for argument in arguments)
        if head_name == "Power" and len(arguments) == 2:
            base, exponent = arguments
            if isinstance(exponent, RationalNumber) and exponent.value == Fraction(1, 2):
                return r"\sqrt{" + _tex_format_expr(base, traditional=traditional) + "}"
            if (
                isinstance(exponent, Call)
                and exponent.has_head("Rational")
                and len(exponent.arguments) == 2
                and isinstance(exponent.arguments[0], Integer)
                and isinstance(exponent.arguments[1], Integer)
                and exponent.arguments[0].value == 1
                and exponent.arguments[1].value == 2
            ):
                return r"\sqrt{" + _tex_format_expr(base, traditional=traditional) + "}"
            return (
                _tex_power_base_text(base, traditional=traditional)
                + "^{"
                + _tex_format_expr(exponent, traditional=traditional)
                + "}"
            )
        if head_name == "Rational" and len(arguments) == 2:
            return (
                r"\frac{"
                + _tex_format_expr(arguments[0], traditional=traditional)
                + "}{"
                + _tex_format_expr(arguments[1], traditional=traditional)
                + "}"
            )
        if head_name in {"Sin", "Cos", "Tan", "Log", "Exp"} and len(arguments) == 1:
            name = "ln" if head_name == "Log" else head_name.lower()
            return rf"\{name}\left(" + _tex_format_expr(arguments[0], traditional=traditional) + r"\right)"

    head = _tex_format_expr(expr.head_expr, traditional=traditional)
    arguments = ", ".join(_tex_format_expr(argument, traditional=traditional) for argument in expr.arguments)
    head_context = None
    if isinstance(expr.head_expr, Symbol):
        try:
            head_context = _SYMBOL_REGISTRY.record_for_symbol(expr.head_expr).context
        except WolframEvaluationError:
            head_context = None
    if traditional and head_context == "Global`":
        return head + r"\left(" + arguments + r"\right)"
    return head + r"\left[" + arguments + r"\right]"


def _tex_factor_text(expr: Expr, *, traditional: bool) -> str:
    if isinstance(expr, Call) and isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        if head_name in {"Plus", "Rule", "RuleDelayed"}:
            return r"\left(" + _tex_format_expr(expr, traditional=traditional) + r"\right)"
    return _tex_format_expr(expr, traditional=traditional)


def _tex_power_base_text(expr: Expr, *, traditional: bool) -> str:
    if isinstance(expr, (Symbol, Integer, Real, RationalNumber)):
        return _tex_format_expr(expr, traditional=traditional)
    return r"\left(" + _tex_format_expr(expr, traditional=traditional) + r"\right)"


def _tex_escaped_infix(
    arguments: Sequence[Expr],
    operator: str,
    precedence: int,
    *,
    traditional: bool,
) -> str:
    pieces: list[str] = []
    for argument in arguments:
        text = _tex_format_expr(argument, traditional=traditional)
        if _infix_argument_needs_parentheses(argument, precedence):
            text = r"\left(" + text + r"\right)"
        pieces.append(text)
    return (operator + " ").join(pieces)


_TEX_SYMBOL_NAMES = {
    "alpha": r"\alpha",
    "beta": r"\beta",
    "gamma": r"\gamma",
    "delta": r"\delta",
    "epsilon": r"\epsilon",
    "theta": r"\theta",
    "lambda": r"\lambda",
    "mu": r"\mu",
    "pi": r"\pi",
    "sigma": r"\sigma",
    "phi": r"\phi",
    "omega": r"\omega",
}


def _tex_symbol_name(name: str) -> str:
    lower = name.lower()
    if lower in _TEX_SYMBOL_NAMES:
        return _TEX_SYMBOL_NAMES[lower]
    if len(name) == 1 and (name.isalpha() or name.isdigit()):
        return _tex_escape_text(name)
    return r"\text{" + _tex_escape_text(name) + "}"


def _tex_escape_text(text: str) -> str:
    replacements = {
        "\\": r"\backslash{}",
        "{": r"\{",
        "}": r"\}",
        "_": r"\_",
        "%": r"\%",
        "#": r"\#",
        "&": r"\&",
        "$": r"\$",
    }
    return "".join(replacements.get(char, char) for char in text)


def _mathml_format_expr(expr: Expr, *, traditional: bool) -> str:
    if isinstance(expr, Symbol):
        return f"<mi>{html.escape(expr.to_input_form())}</mi>"
    if isinstance(expr, Integer):
        return f"<mn>{expr.value}</mn>"
    if isinstance(expr, RationalNumber):
        return f"<mfrac><mn>{expr.value.numerator}</mn><mn>{expr.value.denominator}</mn></mfrac>"
    if isinstance(expr, Real):
        return f"<mn>{html.escape(expr.text)}</mn>"
    if isinstance(expr, SpecialReal):
        return f"<mi>{html.escape(expr.name)}</mi>"
    if isinstance(expr, ComplexNumber):
        return _mathml_format_expr(call("Complex", expr.real_part, expr.imaginary_part), traditional=traditional)
    if isinstance(expr, String):
        return f"<mtext>{html.escape(wl_string(expr.value))}</mtext>"
    if isinstance(expr, ByteArrayExpr):
        return f"<mtext>{html.escape(expr.to_input_form())}</mtext>"
    if not isinstance(expr, Call):
        return f"<mtext>{html.escape(expr.to_input_form())}</mtext>"

    if isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        arguments = expr.arguments
        if head_name == "List":
            return _mathml_row([_mathml_operator("{"), *_mathml_join(arguments, ",", traditional=traditional), _mathml_operator("}")])
        if head_name == "Rule" and len(arguments) == 2:
            return _mathml_row([
                _mathml_format_expr(arguments[0], traditional=traditional),
                _mathml_operator("->"),
                _mathml_format_expr(arguments[1], traditional=traditional),
            ])
        if head_name == "RuleDelayed" and len(arguments) == 2:
            return _mathml_row([
                _mathml_format_expr(arguments[0], traditional=traditional),
                _mathml_operator(":>"),
                _mathml_format_expr(arguments[1], traditional=traditional),
            ])
        escaped_mathml_operator = _ESCAPED_INFIX_MATHML_OPERATOR_ENTITIES.get(head_name)
        if escaped_mathml_operator is not None and len(arguments) >= 2:
            return _mathml_row(
                _mathml_join(arguments, escaped_mathml_operator, traditional=traditional)
            )
        if head_name == "Plus" and arguments:
            ordered = _traditional_plus_arguments(arguments) if traditional else arguments
            return _mathml_row(_mathml_join(ordered, "+", traditional=traditional))
        if head_name == "Times" and arguments:
            return _mathml_row(_mathml_join(arguments, "\u2062", traditional=traditional))
        if head_name == "Power" and len(arguments) == 2:
            base, exponent = arguments
            if isinstance(exponent, RationalNumber) and exponent.value == Fraction(1, 2):
                return f"<msqrt>{_mathml_format_expr(base, traditional=traditional)}</msqrt>"
            return (
                "<msup>"
                + _mathml_format_expr(base, traditional=traditional)
                + _mathml_format_expr(exponent, traditional=traditional)
                + "</msup>"
            )
        if head_name == "Rational" and len(arguments) == 2:
            return (
                "<mfrac>"
                + _mathml_format_expr(arguments[0], traditional=traditional)
                + _mathml_format_expr(arguments[1], traditional=traditional)
                + "</mfrac>"
            )

    head = _mathml_format_expr(expr.head_expr, traditional=traditional)
    return _mathml_row([head, _mathml_operator("["), *_mathml_join(expr.arguments, ",", traditional=traditional), _mathml_operator("]")])


def _mathml_join(arguments: Sequence[Expr], operator: str, *, traditional: bool) -> list[str]:
    pieces: list[str] = []
    for index, argument in enumerate(arguments):
        if index:
            pieces.append(_mathml_operator(operator))
        pieces.append(_mathml_format_expr(argument, traditional=traditional))
    return pieces


def _mathml_operator(operator: str) -> str:
    if operator.startswith("&#") and operator.endswith(";"):
        return f"<mo>{operator}</mo>"
    return f"<mo>{html.escape(operator)}</mo>"


def _mathml_row(pieces: Sequence[str]) -> str:
    return "<mrow>" + "".join(pieces) + "</mrow>"


def _indent_xml(text: str, level: int) -> str:
    indent = " " * level
    return "\n".join(indent + line if line else line for line in text.splitlines())


@dataclass(frozen=True)
class _DisplayWrapper:
    label: str
    payload: Expr
    text: str


def history_output_expr(expr: Expr) -> Expr:
    wrapper = _display_form_call(expr)
    if wrapper is not None:
        if wrapper.name in _VALUE_STRIPPING_DISPLAY_FORM_HEADS:
            return wrapper.payload
        return expr
    short_wrapper = _short_shallow_display_wrapper(expr)
    if short_wrapper is not None:
        return short_wrapper.payload
    return expr


def _short_shallow_display_wrapper(expr: Expr) -> _DisplayWrapper | None:
    if not isinstance(expr, Call) or not expr.arguments or not isinstance(expr.head_expr, Symbol):
        return None
    head_name = _system_dispatch_name(expr.head_expr)
    if head_name == "Short":
        return _DisplayWrapper(
            head_name,
            expr.arguments[0],
            _short_display_text(expr.arguments[0], expr.arguments[1:]),
        )
    if head_name == "Shallow":
        return _DisplayWrapper(
            head_name,
            expr.arguments[0],
            _shallow_display_text(expr.arguments[0], expr.arguments[1:]),
        )
    return None


def _short_display_text(expr: Expr, specs: Sequence[Expr] = (), *, max_chars: int | None = None) -> str:
    scale = 1
    if specs and isinstance(specs[0], Integer):
        scale = max(0, specs[0].value)
    front = max(1, 10 * scale)
    back = max(0, 5 * scale)
    depth_limit = max(1, 3 + scale)
    text = _format_short_expr(expr, depth_limit=depth_limit, front=front, back=back, top_level=True)
    if max_chars is not None and len(text) > max_chars:
        return _center_truncate_text(text, max_chars)
    return text


def _shallow_display_text(expr: Expr, specs: Sequence[Expr] = (), *, max_chars: int | None = None) -> str:
    depth_limit, length_limit = _shallow_limits(specs)
    text = _format_shallow_expr(expr, depth_limit=depth_limit, length_limit=length_limit, top_level=True)
    if max_chars is not None and len(text) > max_chars:
        return _center_truncate_text(text, max_chars)
    return text


def _shallow_limits(specs: Sequence[Expr]) -> tuple[int | None, int | None]:
    depth_limit: int | None = 4
    length_limit: int | None = 10
    if not specs:
        return depth_limit, length_limit
    spec = specs[0]
    if isinstance(spec, Integer):
        return max(0, spec.value), length_limit
    if _is_system_infinity(spec):
        return None, length_limit
    if isinstance(spec, Call) and spec.has_head("List") and len(spec.arguments) >= 1:
        parsed_depth = _display_limit_component(spec.arguments[0], depth_limit)
        parsed_length = (
            _display_limit_component(spec.arguments[1], length_limit)
            if len(spec.arguments) >= 2
            else length_limit
        )
        return parsed_depth, parsed_length
    return depth_limit, length_limit


def _display_limit_component(expr: Expr, default: int | None) -> int | None:
    if isinstance(expr, Integer):
        return max(0, expr.value)
    if _is_system_infinity(expr):
        return None
    return default


def _format_short_expr(
    expr: Expr,
    *,
    depth_limit: int,
    front: int,
    back: int,
    top_level: bool = False,
) -> str:
    children = _display_children(expr)
    if children is None:
        return _format_display_atom(expr, top_level=top_level)
    if depth_limit <= 0:
        return _display_skeleton(len(children))

    rendered = _format_short_children(children, depth_limit=depth_limit - 1, front=front, back=back)
    return _wrap_display_children(expr, rendered)


def _format_shallow_expr(
    expr: Expr,
    *,
    depth_limit: int | None,
    length_limit: int | None,
    top_level: bool = False,
) -> str:
    children = _display_children(expr)
    if children is None:
        return _format_display_atom(expr, top_level=top_level)
    if depth_limit is not None and depth_limit <= 0:
        return _display_skeleton(len(children))

    rendered = _format_shallow_children(children, depth_limit=depth_limit, length_limit=length_limit)
    return _wrap_display_children(expr, rendered)


def _format_short_children(
    children: Sequence[tuple[str | None, Expr]],
    *,
    depth_limit: int,
    front: int,
    back: int,
) -> list[str]:
    if len(children) <= front + back + 1:
        selected: list[tuple[str | None, Expr] | str] = list(children)
    else:
        omitted = len(children) - front - back
        selected = [*children[:front], _display_skeleton(omitted)]
        if back:
            selected.extend(children[-back:])

    rendered: list[str] = []
    for item in selected:
        if isinstance(item, str):
            rendered.append(item)
        else:
            prefix, child = item
            child_text = _format_short_expr(child, depth_limit=depth_limit, front=front, back=back)
            rendered.append(_format_display_child(prefix, child_text))
    return rendered


def _format_shallow_children(
    children: Sequence[tuple[str | None, Expr]],
    *,
    depth_limit: int | None,
    length_limit: int | None,
) -> list[str]:
    child_depth = None if depth_limit is None else depth_limit - 1
    if length_limit is not None and len(children) > length_limit:
        selected: list[tuple[str | None, Expr] | str] = [*children[:length_limit], _display_skeleton(len(children) - length_limit)]
    else:
        selected = list(children)

    rendered: list[str] = []
    for item in selected:
        if isinstance(item, str):
            rendered.append(item)
        else:
            prefix, child = item
            child_text = _format_shallow_expr(child, depth_limit=child_depth, length_limit=length_limit)
            rendered.append(_format_display_child(prefix, child_text))
    return rendered


def _display_children(expr: Expr) -> tuple[tuple[str | None, Expr], ...] | None:
    entries = _association_entries(expr)
    if entries is not None:
        return tuple((_format_association_entry_prefix(entry), entry.value) for entry in entries)
    if isinstance(expr, Call):
        return tuple((None, argument) for argument in expr.arguments)
    return None


def _format_association_entry_prefix(entry: _AssociationEntry) -> str:
    operator = ":>" if entry.rule_head == "RuleDelayed" else "->"
    return f"{_format_input(entry.key)} {operator} "


def _format_display_child(prefix: str | None, child_text: str) -> str:
    if prefix is None:
        return child_text
    return prefix + child_text


def _wrap_display_children(expr: Expr, rendered: Sequence[str]) -> str:
    if _association_entries(expr) is not None:
        return "<|" + ", ".join(rendered) + "|>"
    if isinstance(expr, Call) and expr.has_head("List"):
        return "{" + ", ".join(rendered) + "}"
    if isinstance(expr, Call):
        head = _format_input(expr.head_expr, _PREC_CALL)
        return f"{head}[{', '.join(rendered)}]"
    return _format_display_atom(expr)


def _format_display_atom(expr: Expr, *, top_level: bool = False) -> str:
    if top_level and isinstance(expr, String):
        return expr.value
    return expr.to_input_form()


def _display_skeleton(count: int) -> str:
    return f"<<{count}>>"


def _center_truncate_text(text: str, max_chars: int) -> str:
    if max_chars <= 0:
        return _display_skeleton(len(text)) + " chars"
    if len(text) <= max_chars:
        return text
    marker = f" <<{len(text) - max_chars} chars>> "
    if len(marker) >= max_chars:
        return marker[:max_chars]
    prefix = (max_chars - len(marker) + 1) // 2
    suffix = max_chars - len(marker) - prefix
    return text[:prefix] + marker + (text[-suffix:] if suffix > 0 else "")


def apply_output_size_limit(expr: Expr, text: str) -> str:
    limit = output_size_limit_value()
    if limit is None or len(text) <= limit:
        return text
    shortened = _short_display_text(history_output_expr(expr), max_chars=limit)
    if len(shortened) <= limit:
        return shortened
    return _center_truncate_text(shortened, limit)


def display_output_parts(expr: Expr) -> tuple[str | None, str]:
    wrapper = _display_form_call(expr)
    if wrapper is not None:
        return wrapper.name, _display_form_call_text(wrapper)
    short_wrapper = _short_shallow_display_wrapper(expr)
    if short_wrapper is not None:
        return short_wrapper.label, short_wrapper.text
    if isinstance(expr, String):
        return None, expr.value
    return None, expr.to_input_form()


def _looks_like_standard_form_boxes(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and isinstance(expr.head_expr, Symbol)
        and expr.head_expr.name in _STANDARD_FORM_BOX_HEADS
    )


def _parse_textual_expression(text: str, form_name: str) -> Expr:
    if form_name == "InputForm":
        return parse_input_form(text)
    if form_name == "StandardForm":
        return parse_standard_form(text)
    if form_name == "TraditionalForm":
        parsed_box = _parse_single_inline_box_text(text)
        if parsed_box is not None:
            return _interpret_standard_form(parsed_box)
        return parse_standard_form(text)
    if form_name == "TeXForm":
        return _parse_tex_form_text(text)
    if form_name == "MathMLForm":
        return _parse_mathml_form_text(text)
    raise WolframSyntaxError(f"Unsupported textual expression form: {form_name}")


def _parse_single_inline_box_text(text: str) -> Expr | None:
    segments = inline_box_segments(text.strip())
    if len(segments) != 1 or segments[0].source != text.strip():
        return None
    return parse_input_form(segments[0].box_expression)


def _parse_tex_form_text(text: str) -> Expr:
    normalized = _tex_to_wolfram_text(text.strip())
    return parse_standard_form(normalized)


def _tex_to_wolfram_text(text: str) -> str:
    text = text.replace(r"\left", "").replace(r"\right", "")
    text = _replace_tex_group_function(text, r"\frac", lambda first, second: f"(({_tex_to_wolfram_text(first)})/({_tex_to_wolfram_text(second)}))", arity=2)
    text = _replace_tex_group_function(text, r"\sqrt", lambda first: f"(({_tex_to_wolfram_text(first)})^(1/2))", arity=1)
    text = _replace_tex_group_function(text, r"\text", lambda first: _tex_to_wolfram_text(first), arity=1)
    for name, tex_name in _TEX_SYMBOL_NAMES.items():
        text = text.replace(tex_name, name)
    text = text.replace(r"\mathrel{:}\joinrel\to", ":>")
    text = text.replace(r"\{", "{").replace(r"\}", "}")
    text = text.replace(r"\to", "->")
    text = text.replace(r"\[", "[").replace(r"\]", "]")
    text = text.replace(r"\(", "(").replace(r"\)", ")")
    for tex_operator, escaped_operator in _TEX_INFIX_OPERATOR_TOKENS.items():
        text = text.replace(tex_operator, escaped_operator)
    text = text.replace("^{", "^(")
    text = _close_tex_superscript_groups(text)
    return text


def _replace_tex_group_function(text: str, marker: str, replacement: Callable[..., str], *, arity: int) -> str:
    while True:
        start = text.find(marker)
        if start < 0:
            return text
        index = start + len(marker)
        groups: list[str] = []
        end = index
        for _ in range(arity):
            while end < len(text) and text[end].isspace():
                end += 1
            if end >= len(text) or text[end] != "{":
                return text
            group, end = _read_braced_tex_group(text, end)
            groups.append(group)
        text = text[:start] + replacement(*groups) + text[end:]


def _read_braced_tex_group(text: str, start: int) -> tuple[str, int]:
    depth = 0
    content_start = start + 1
    index = start
    while index < len(text):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[content_start:index], index + 1
        index += 1
    raise WolframSyntaxError("Unclosed TeX group.")


def _close_tex_superscript_groups(text: str) -> str:
    result: list[str] = []
    index = 0
    while index < len(text):
        if text.startswith("^(", index):
            result.append("^(")
            index += 2
            depth = 1
            while index < len(text):
                char = text[index]
                if char == "{":
                    depth += 1
                    result.append("(")
                elif char == "}":
                    depth -= 1
                    result.append(")" if depth == 0 else ")")
                    index += 1
                    break
                else:
                    result.append(char)
                index += 1
            continue
        result.append(text[index])
        index += 1
    return "".join(result)


def _parse_mathml_form_text(text: str) -> Expr:
    try:
        root = ElementTree.fromstring(text)
    except ElementTree.ParseError as exc:
        raise WolframSyntaxError("Invalid MathML input.") from exc
    wolfram_text = _mathml_element_to_wolfram_text(root)
    return parse_standard_form(wolfram_text)


def _mathml_element_to_wolfram_text(element: ElementTree.Element) -> str:
    tag = _xml_local_name(element.tag)
    children = list(element)
    if tag == "math":
        if len(children) == 1:
            return _mathml_element_to_wolfram_text(children[0])
        return _mathml_row_to_wolfram_text(children)
    if tag == "mrow":
        return _mathml_row_to_wolfram_text(children)
    if tag in {"mi", "mn"}:
        return (element.text or "").strip()
    if tag == "mtext":
        return wl_string(element.text or "")
    if tag == "mo":
        return _mathml_operator_text(element.text or "")
    if tag == "mfrac" and len(children) >= 2:
        return f"(({_mathml_element_to_wolfram_text(children[0])})/({_mathml_element_to_wolfram_text(children[1])}))"
    if tag == "msup" and len(children) >= 2:
        return f"(({_mathml_element_to_wolfram_text(children[0])})^({_mathml_element_to_wolfram_text(children[1])}))"
    if tag == "msqrt" and children:
        return f"(({_mathml_row_to_wolfram_text(children)})^(1/2))"
    raise WolframSyntaxError(f"Unsupported MathML element: {tag}.")


def _mathml_row_to_wolfram_text(children: Sequence[ElementTree.Element]) -> str:
    pieces = [_mathml_element_to_wolfram_text(child) for child in children]
    if pieces and pieces[0] in {"{", "[", "("} and pieces[-1] in {"}", "]", ")"}:
        return pieces[0] + "".join(pieces[1:-1]) + pieces[-1]
    return " ".join(piece for piece in pieces if piece != "\u2062")


def _mathml_operator_text(text: str) -> str:
    stripped = text.strip()
    if stripped == "\u2062":
        return "\u2062"
    operator_token = _MATHML_OPERATOR_TEXT_TOKENS.get(stripped)
    if operator_token is not None:
        return operator_token
    return stripped


def _xml_local_name(tag: str) -> str:
    if "}" in tag:
        return tag.rsplit("}", 1)[1]
    return tag


def to_string_expr(expr: Expr, form_value: Expr | None = None, options: Sequence[Expr] = ()) -> String:
    format_type = _option_value(options, "FormatType")
    if form_value is None and format_type is not None:
        form_value = format_type

    if form_value is None:
        wrapper = _display_form_call(expr)
        if wrapper is not None:
            return string(_encode_to_string_text(_display_form_call_text(wrapper), options))
        form_value = symbol("OutputForm")

    form_name = _normalize_textual_expression_form(form_value, "ToString", purpose="render")
    wrapper = _display_form_call(expr)
    if wrapper is not None and wrapper.name in _TEXT_RENDERING_DISPLAY_FORM_HEADS:
        return string(_encode_to_string_text(_display_form_call_text(wrapper), options))
    if form_name == "InputForm":
        text = expr.to_input_form()
    elif form_name == "StandardForm":
        # Tungsten's StandardForm string subset intentionally renders as parseable WL text,
        # not as FrontEnd box escapes. The parser accepts it through parse_standard_form.
        text = expr.to_input_form()
    elif form_name == "OutputForm":
        text = _output_form_text(expr)
    elif form_name == "TextForm":
        text = _output_form_text(expr)
    elif form_name == "CForm":
        text = _c_like_form_text(expr, target="c")
    elif form_name == "FortranForm":
        text = _c_like_form_text(expr, target="fortran")
    elif form_name == "TraditionalForm":
        text = _traditional_form_text(expr)
    elif form_name == "TeXForm":
        text = _tex_form_text(expr)
    elif form_name == "MathMLForm":
        text = _mathml_form_text(expr).rstrip("\n")
    else:
        raise AssertionError(f"Unhandled textual expression form: {form_name}")
    if _to_string_number_marks(options) is False:
        text = _strip_number_marks_text(text)
    return string(_encode_to_string_text(text, options))


def _to_string_number_marks(options: Sequence[Expr]) -> bool | None:
    value = _option_value(options, "NumberMarks")
    if isinstance(value, Symbol):
        if _system_dispatch_name(value) == "True":
            return True
        if _system_dispatch_name(value) == "False":
            return False
    return None


def _strip_number_marks_text(text: str) -> str:
    return re.sub(r"(?<=[0-9.])``?[0-9.]*", "", text)


def _to_string_character_encoding(options: Sequence[Expr]) -> str:
    value = _option_value(options, "CharacterEncoding")
    encoding_name, _display_name = _normalize_character_encoding_name(
        value,
        "ToString",
        default_unicode=True,
    )
    return encoding_name


def _encode_to_string_text(text: str, options: Sequence[Expr]) -> str:
    encoding_name = _to_string_character_encoding(options)
    if encoding_name == "Unicode":
        return text
    if encoding_name in {"PrintableASCII", "ascii"}:
        return encode_printable_ascii(text)
    if encoding_name in _SINGLE_BYTE_ENCODINGS.values():
        encoded: list[str] = []
        for char in text:
            try:
                char.encode(encoding_name)
            except UnicodeEncodeError:
                encoded.append(encode_printable_ascii(char))
            else:
                encoded.append(char)
        return "".join(encoded)
    return "".join(chr(byte) for byte in text.encode(encoding_name))


def to_expression_expr(input_expr: Expr, form_value: Expr | None = None, wrapper_head: Expr | None = None) -> Expr:
    if isinstance(input_expr, Call) and input_expr.has_head("List"):
        return _evaluated_list_expr(
            *(to_expression_expr(item, form_value, wrapper_head) for item in input_expr.arguments)
        )

    if form_value is None and _looks_like_standard_form_boxes(input_expr):
        form_name = "StandardForm"
    else:
        form_name = _normalize_textual_expression_form(form_value, "ToExpression")

    try:
        if isinstance(input_expr, String):
            parsed = _parse_textual_expression(input_expr.value, form_name)
        elif form_name == "StandardForm" and _looks_like_standard_form_boxes(input_expr):
            parsed = _interpret_standard_form(input_expr)
        elif form_name == "TraditionalForm" and _looks_like_standard_form_boxes(input_expr):
            parsed = _interpret_standard_form(input_expr)
        else:
            raise WolframEvaluationError("ToExpression expects a string or a supported box expression.")
    except WolframSyntaxError as exc:
        raise WolframEvaluationError(f"ToExpression could not parse the input as {form_name}.") from exc

    if wrapper_head is not None:
        parsed = Call(head_expr=wrapper_head, arguments=(parsed,))
    return evaluate(parsed)


def to_boxes_expr(expr: Expr, form_value: Expr | None = None) -> Expr:
    form_name = _normalize_box_expression_form(form_value, "ToBoxes")
    boxes = _make_boxes(expr, form_name)
    if form_name == "TraditionalForm":
        return call("FormBox", boxes, symbol("TraditionalForm"))
    return boxes


def make_boxes_expr(expr: Expr, form_value: Expr | None = None) -> Expr:
    form_name = _normalize_box_expression_form(form_value, "MakeBoxes")
    return _make_boxes(expr, form_name)


def make_expression_expr(box_expr: Expr, form_value: Expr | None = None) -> Expr:
    form_name = _normalize_textual_expression_form(form_value, "MakeExpression") if form_value is not None else "StandardForm"
    try:
        if isinstance(box_expr, String):
            parsed = _parse_textual_expression(box_expr.value, form_name)
        elif form_name in {"StandardForm", "TraditionalForm"} and _looks_like_standard_form_boxes(box_expr):
            parsed = _interpret_standard_form(box_expr)
        else:
            raise WolframEvaluationError("MakeExpression expects a string or a supported box expression.")
    except WolframSyntaxError as exc:
        raise WolframEvaluationError(f"MakeExpression could not parse the input as {form_name}.") from exc
    return call("HoldComplete", parsed)


def strip_boxes_expr(box_expr: Expr) -> Expr:
    return call("BoxData", _strip_box_expression(box_expr))


def syntax_q_expr(input_expr: Expr, form_value: Expr | None = None) -> Symbol:
    return _bool_symbol(_syntax_q(input_expr, form_value))


def syntax_length_expr(input_expr: Expr, form_value: Expr | None = None) -> Integer:
    if isinstance(input_expr, String):
        form_name = _normalize_textual_expression_form(form_value, "SyntaxLength")
        return integer(_syntax_length_text(input_expr.value, form_name))
    if _looks_like_standard_form_boxes(input_expr):
        text = _box_expr_to_standard_text(input_expr)
        return integer(_syntax_length_text(text, "StandardForm"))
    raise WolframEvaluationError("SyntaxLength expects a string or a supported StandardForm box expression.")


def _make_boxes(expr: Expr, form_name: str) -> Expr:
    if form_name == "InputForm":
        return string(expr.to_input_form())
    if form_name == "StandardForm":
        return _make_standard_boxes(expr)
    if form_name == "TraditionalForm":
        return _make_traditional_boxes(expr)
    raise WolframEvaluationError("Box conversion currently supports only InputForm, StandardForm, and TraditionalForm.")


def _make_standard_boxes(expr: Expr) -> Expr:
    wrapper = _display_form_call(expr)
    if wrapper is not None:
        form_name, payload = wrapper.name, wrapper.payload
        if form_name == "InputForm":
            return _input_form_display_boxes(payload)
        if form_name == "FullForm":
            return _full_form_display_boxes(payload)
        if form_name == "OutputForm":
            return _output_form_display_boxes(payload)
        if form_name == "StandardForm":
            return _standard_form_display_boxes(payload)
        if form_name == "TraditionalForm":
            return _traditional_form_display_boxes(payload)
        if form_name == "TeXForm":
            return _tex_form_display_boxes(payload)
        if form_name == "MathMLForm":
            return _mathml_form_display_boxes(payload)
        if form_name in {
            "AccountingForm",
            "BaseForm",
            "CForm",
            "DecimalForm",
            "DisplayForm",
            "EngineeringForm",
            "FortranForm",
            "MatrixForm",
            "NumberForm",
            "PaddedForm",
            "PercentForm",
            "PrintForm",
            "ScientificForm",
            "SequenceForm",
            "StringForm",
            "TableForm",
            "TextForm",
            "TreeForm",
        }:
            return _textual_display_boxes(wrapper)

    if isinstance(expr, Symbol):
        return string(expr.to_input_form())
    if isinstance(expr, Integer):
        return string(str(expr.value))
    if isinstance(expr, RationalNumber):
        return call("FractionBox", _make_standard_boxes(integer(expr.value.numerator)), _make_standard_boxes(integer(expr.value.denominator)))
    if isinstance(expr, Real):
        return string(expr.text)
    if isinstance(expr, SpecialReal):
        return _generic_call_boxes(call(expr.name))
    if isinstance(expr, ComplexNumber):
        return _make_standard_boxes(call("Complex", expr.real_part, expr.imaginary_part))
    if isinstance(expr, String):
        return string(wl_string(expr.value))
    if isinstance(expr, ByteArrayExpr):
        return _make_standard_boxes(call("ByteArray", list_expr(*(integer(value) for value in expr.values))))
    if not isinstance(expr, Call):
        return string(expr.to_input_form())

    if isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        if head_name == "List":
            return _bracketed_row_box("{", expr.arguments, "}")
        if head_name == "Association":
            return _bracketed_row_box("<|", expr.arguments, "|>")
        if head_name == "Rule" and len(expr.arguments) == 2:
            return _infix_row_box(expr.arguments[0], "->", expr.arguments[1])
        if head_name == "RuleDelayed" and len(expr.arguments) == 2:
            return _infix_row_box(expr.arguments[0], ":>", expr.arguments[1])
        escaped_operator = _ESCAPED_INFIX_OPERATOR_TOKENS_BY_HEAD.get(head_name)
        if escaped_operator is not None and len(expr.arguments) >= 2:
            return _escaped_infix_row_box(
                expr.arguments,
                escaped_operator,
                _escaped_infix_operator_precedence(head_name),
                traditional=False,
            )
        if head_name == "Plus" and len(expr.arguments) >= 2:
            return _separated_row_box(expr.arguments, "+")
        if head_name == "Times" and len(expr.arguments) >= 2:
            return _separated_row_box(expr.arguments, " ")
        if head_name == "Power" and len(expr.arguments) == 2:
            base, exponent = expr.arguments
            if isinstance(exponent, Integer) and exponent.value == -1:
                return call("FractionBox", string("1"), _make_standard_boxes(base))
            return call("SuperscriptBox", _make_standard_boxes(base), _make_standard_boxes(exponent))
        if head_name == "Rational" and len(expr.arguments) == 2:
            return call("FractionBox", _make_standard_boxes(expr.arguments[0]), _make_standard_boxes(expr.arguments[1]))
        if head_name == "Subscript" and len(expr.arguments) == 2:
            return call("SubscriptBox", _make_standard_boxes(expr.arguments[0]), _make_standard_boxes(expr.arguments[1]))
        if head_name == "Subsuperscript" and len(expr.arguments) == 3:
            return call(
                "SubsuperscriptBox",
                _make_standard_boxes(expr.arguments[0]),
                _make_standard_boxes(expr.arguments[1]),
                _make_standard_boxes(expr.arguments[2]),
            )
        if head_name == "Overscript" and len(expr.arguments) == 2:
            return call("OverscriptBox", _make_standard_boxes(expr.arguments[0]), _make_standard_boxes(expr.arguments[1]))
        if head_name == "Underscript" and len(expr.arguments) == 2:
            return call("UnderscriptBox", _make_standard_boxes(expr.arguments[0]), _make_standard_boxes(expr.arguments[1]))
        if head_name == "Underoverscript" and len(expr.arguments) == 3:
            return call(
                "UnderoverscriptBox",
                _make_standard_boxes(expr.arguments[0]),
                _make_standard_boxes(expr.arguments[1]),
                _make_standard_boxes(expr.arguments[2]),
            )

    return _generic_call_boxes(expr)


def _make_traditional_boxes(expr: Expr) -> Expr:
    wrapper = _display_form_wrapper(expr)
    if wrapper is not None:
        form_name, payload = wrapper
        if form_name == "TraditionalForm":
            return _make_traditional_boxes(payload)
        if form_name == "StandardForm":
            return _make_standard_boxes(payload)

    if isinstance(expr, (Symbol, Integer, Real, SpecialReal, String, ByteArrayExpr)):
        return _make_standard_boxes(expr)
    if isinstance(expr, RationalNumber):
        return call("FractionBox", _make_traditional_boxes(integer(expr.value.numerator)), _make_traditional_boxes(integer(expr.value.denominator)))
    if isinstance(expr, ComplexNumber):
        return _make_traditional_boxes(call("Complex", expr.real_part, expr.imaginary_part))
    if not isinstance(expr, Call):
        return string(expr.to_input_form())

    if isinstance(expr.head_expr, Symbol):
        head_name = _system_dispatch_name(expr.head_expr)
        if head_name == "List":
            return _bracketed_traditional_row_box("{", expr.arguments, "}")
        if head_name == "Association":
            return _bracketed_traditional_row_box("<|", expr.arguments, "|>")
        if head_name == "Rule" and len(expr.arguments) == 2:
            return _infix_traditional_row_box(expr.arguments[0], "->", expr.arguments[1])
        if head_name == "RuleDelayed" and len(expr.arguments) == 2:
            return _infix_traditional_row_box(expr.arguments[0], ":>", expr.arguments[1])
        escaped_operator = _ESCAPED_INFIX_OPERATOR_TOKENS_BY_HEAD.get(head_name)
        if escaped_operator is not None and len(expr.arguments) >= 2:
            return _escaped_infix_row_box(
                expr.arguments,
                escaped_operator,
                _escaped_infix_operator_precedence(head_name),
                traditional=True,
            )
        if head_name == "Plus" and len(expr.arguments) >= 2:
            return _separated_traditional_row_box(_traditional_plus_arguments(expr.arguments), "+")
        if head_name == "Times" and len(expr.arguments) >= 2:
            return _separated_traditional_row_box(expr.arguments, " ")
        if head_name == "Power" and len(expr.arguments) == 2:
            base, exponent = expr.arguments
            if isinstance(exponent, Integer) and exponent.value == -1:
                return call("FractionBox", string("1"), _make_traditional_boxes(base))
            if isinstance(exponent, RationalNumber) and exponent.value == Fraction(1, 2):
                return call("SqrtBox", _make_traditional_boxes(base))
            return call("SuperscriptBox", _make_traditional_boxes(base), _make_traditional_boxes(exponent))
        if head_name == "Rational" and len(expr.arguments) == 2:
            return call("FractionBox", _make_traditional_boxes(expr.arguments[0]), _make_traditional_boxes(expr.arguments[1]))
        if head_name == "Subscript" and len(expr.arguments) == 2:
            return call("SubscriptBox", _make_traditional_boxes(expr.arguments[0]), _make_traditional_boxes(expr.arguments[1]))
        if head_name == "Subsuperscript" and len(expr.arguments) == 3:
            return call(
                "SubsuperscriptBox",
                _make_traditional_boxes(expr.arguments[0]),
                _make_traditional_boxes(expr.arguments[1]),
                _make_traditional_boxes(expr.arguments[2]),
            )

    return _generic_traditional_call_boxes(expr)


def _rule_option(name: str, value: Expr) -> Expr:
    return call("Rule", symbol(name), value)


def _input_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "InterpretationBox",
        call(
            "StyleBox",
            string(expr.to_input_form()),
            _rule_option("ShowStringCharacters", symbol("True")),
            _rule_option("NumberMarks", symbol("True")),
        ),
        call("InputForm", expr),
        _rule_option("Editable", symbol("True")),
        _rule_option("AutoDelete", symbol("True")),
    )


def _full_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "TagBox",
        call(
            "StyleBox",
            _make_full_form_boxes(expr),
            _rule_option("ShowSpecialCharacters", symbol("False")),
            _rule_option("ShowStringCharacters", symbol("True")),
            _rule_option("NumberMarks", symbol("True")),
        ),
        symbol("FullForm"),
    )


def _output_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "InterpretationBox",
        call(
            "PaneBox",
            string(expr.to_input_form()),
            _rule_option("BaselinePosition", symbol("Baseline")),
        ),
        expr,
        _rule_option("Editable", symbol("False")),
    )


def _standard_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "TagBox",
        call("FormBox", _make_standard_boxes(expr), symbol("StandardForm")),
        symbol("StandardForm"),
        _rule_option("Editable", symbol("True")),
    )


def _traditional_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "TagBox",
        call("FormBox", _make_traditional_boxes(expr), symbol("TraditionalForm")),
        symbol("TraditionalForm"),
        _rule_option("Editable", symbol("True")),
    )


def _tex_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "InterpretationBox",
        string(wl_string(_tex_form_text(expr))),
        expr,
        _rule_option("Editable", symbol("True")),
        _rule_option("AutoDelete", symbol("True")),
    )


def _mathml_form_display_boxes(expr: Expr) -> Expr:
    return call(
        "InterpretationBox",
        string(wl_string(_mathml_form_text(expr).rstrip("\n"))),
        expr,
        _rule_option("Editable", symbol("True")),
        _rule_option("AutoDelete", symbol("True")),
    )


def _textual_display_boxes(wrapper: _DisplayFormCall) -> Expr:
    return call(
        "InterpretationBox",
        string(_display_form_call_text(wrapper)),
        wrapper.as_expr(),
        _rule_option("Editable", symbol("True")),
        _rule_option("AutoDelete", symbol("True")),
    )


def _make_full_form_boxes(expr: Expr) -> Expr:
    if isinstance(expr, RationalNumber):
        return _make_full_form_boxes(
            call("Rational", integer(expr.value.numerator), integer(expr.value.denominator))
        )
    if isinstance(expr, ComplexNumber):
        return _make_full_form_boxes(call("Complex", expr.real_part, expr.imaginary_part))
    if isinstance(expr, SpecialReal):
        return _make_full_form_boxes(call(expr.name))
    if isinstance(expr, ByteArrayExpr):
        encoded = base64.b64encode(bytes(expr.values)).decode("ascii")
        return _make_full_form_boxes(call("ByteArray", string(encoded)))
    if not isinstance(expr, Call):
        return string(expr.to_full_form())

    if expr.arguments:
        arguments = _separated_full_form_boxes(expr.arguments, ",")
    else:
        arguments = string("")
    return _row_box(_make_full_form_boxes(expr.head_expr), string("["), arguments, string("]"))


def _separated_full_form_boxes(arguments: Sequence[Expr], separator: str) -> Expr:
    pieces: list[Expr] = []
    for index, argument in enumerate(arguments):
        if index:
            pieces.append(string(separator))
        pieces.append(_make_full_form_boxes(argument))
    return _row_box(*pieces)


def _bracketed_row_box(open_token: str, arguments: Sequence[Expr], close_token: str) -> Expr:
    if arguments:
        middle = _separated_row_box(arguments, ",")
    else:
        middle = string("")
    return _row_box(string(open_token), middle, string(close_token))


def _bracketed_traditional_row_box(open_token: str, arguments: Sequence[Expr], close_token: str) -> Expr:
    if arguments:
        middle = _separated_traditional_row_box(arguments, ",")
    else:
        middle = string("")
    return _row_box(string(open_token), middle, string(close_token))


def _generic_call_boxes(expr: Call) -> Expr:
    if expr.arguments:
        arguments = _separated_row_box(expr.arguments, ",")
    else:
        arguments = string("")
    return _row_box(_make_standard_boxes(expr.head_expr), string("["), arguments, string("]"))


def _generic_traditional_call_boxes(expr: Call) -> Expr:
    if expr.arguments:
        arguments = _separated_traditional_row_box(expr.arguments, ",")
    else:
        arguments = string("")
    return _row_box(_make_traditional_boxes(expr.head_expr), string("["), arguments, string("]"))


def _infix_row_box(left: Expr, operator: str, right: Expr) -> Expr:
    return _row_box(_make_standard_boxes(left), string(operator), _make_standard_boxes(right))


def _infix_traditional_row_box(left: Expr, operator: str, right: Expr) -> Expr:
    return _row_box(_make_traditional_boxes(left), string(operator), _make_traditional_boxes(right))


def _escaped_infix_row_box(
    arguments: Sequence[Expr],
    operator: str,
    precedence: int,
    *,
    traditional: bool,
) -> Expr:
    pieces: list[Expr] = []
    box_maker = _make_traditional_boxes if traditional else _make_standard_boxes
    for index, argument in enumerate(arguments):
        if index:
            pieces.append(string(operator))
        argument_boxes = box_maker(argument)
        if _infix_argument_needs_parentheses(argument, precedence):
            argument_boxes = _row_box(string("("), argument_boxes, string(")"))
        pieces.append(argument_boxes)
    return _row_box(*pieces)


def _separated_row_box(arguments: Sequence[Expr], separator: str) -> Expr:
    pieces: list[Expr] = []
    for index, argument in enumerate(arguments):
        if index:
            pieces.append(string(separator))
        pieces.append(_make_standard_boxes(argument))
    return _row_box(*pieces)


def _separated_traditional_row_box(arguments: Sequence[Expr], separator: str) -> Expr:
    pieces: list[Expr] = []
    for index, argument in enumerate(arguments):
        if index:
            pieces.append(string(separator))
        pieces.append(_make_traditional_boxes(argument))
    return _row_box(*pieces)


def _row_box(*items: Expr) -> Expr:
    return call("RowBox", list_expr(*items))


def _strip_box_expression(expr: Expr) -> Expr:
    if isinstance(expr, Call):
        if expr.has_head("BoxData") and len(expr.arguments) == 1:
            return _strip_box_expression(expr.arguments[0])
        if (
            isinstance(expr.head_expr, Symbol)
            and expr.head_expr.name in {"AdjustmentBox", "FormBox", "FrameBox", "PaneBox", "StyleBox", "TooltipBox"}
            and expr.arguments
        ):
            return _strip_box_expression(expr.arguments[0])
        if expr.has_head("RowBox") and len(expr.arguments) == 1:
            items = expr.arguments[0]
            if isinstance(items, Call) and items.has_head("List"):
                stripped_items = [
                    stripped
                    for item in items.arguments
                    for stripped in _strip_row_box_item(item)
                ]
                return call("RowBox", list_expr(*stripped_items))
        return Call(
            head_expr=_strip_box_expression(expr.head_expr),
            arguments=tuple(_strip_box_expression(argument) for argument in expr.arguments),
        )
    return expr


def _strip_row_box_item(expr: Expr) -> list[Expr]:
    stripped = _strip_box_expression(expr)
    if isinstance(stripped, String) and _is_nonsemantic_row_box_token(stripped.value):
        return []
    return [stripped]


def _is_nonsemantic_row_box_token(value: str) -> bool:
    if value.isspace():
        return True
    if value.startswith("(*"):
        try:
            return skip_wl_comment(value, 0) == len(value)
        except WolframSyntaxError:
            return False
    return value in {
        r"\[InvisibleSpace]",
        r"\[NegativeMediumSpace]",
        r"\[NegativeThickSpace]",
        r"\[NegativeThinSpace]",
        r"\[NegativeVeryThinSpace]",
        r"\[NoBreak]",
        r"\[ThickSpace]",
        r"\[ThinSpace]",
        r"\[VeryThinSpace]",
    }


def _syntax_q(input_expr: Expr, form_value: Expr | None) -> bool:
    if isinstance(input_expr, String):
        if not input_expr.value:
            return False
        form_name = _normalize_textual_expression_form(form_value, "SyntaxQ")
        try:
            _parse_textual_expression(input_expr.value, form_name)
            return True
        except WolframSyntaxError:
            return False
    if _looks_like_standard_form_boxes(input_expr):
        try:
            _interpret_standard_form(input_expr)
            return True
        except WolframSyntaxError:
            return False
    raise WolframEvaluationError("SyntaxQ expects a string or a supported StandardForm box expression.")


def _syntax_length_text(text: str, form_name: str) -> int:
    if not text:
        return 0
    try:
        _parse_textual_expression(text, form_name)
        return len(text)
    except WolframSyntaxError as exc:
        message = str(exc)
        offset = _syntax_error_offset(message)
        if offset is not None:
            if offset >= len(text) or "found ''" in message or "Unexpected ''" in message:
                return len(text) + 2
            return max(0, offset)
        return len(text) + 1


def _syntax_error_offset(message: str) -> int | None:
    match = re.search(r"offset (\d+)", message)
    if match is None:
        return None
    return int(match.group(1))


def _box_expr_to_standard_text(expr: Expr) -> str:
    if isinstance(expr, Call) and expr.has_head("BoxData") and len(expr.arguments) == 1:
        return _box_expr_to_standard_text(expr.arguments[0])
    if isinstance(expr, Call) and expr.has_head("RowBox"):
        return _box_item_to_standard_text(expr)
    return _box_item_to_standard_text(expr)


def symbol_expr(name: Expr) -> Symbol:
    if not isinstance(name, String):
        raise WolframEvaluationError("Symbol expects a string symbol name.")
    return _SYMBOL_REGISTRY.symbol_from_name(name.value)


def symbol_name_expr(expr: Expr) -> String:
    if isinstance(expr, Symbol):
        return string(_SYMBOL_REGISTRY.record_for_symbol(expr).short_name)
    if isinstance(expr, String):
        record = _SYMBOL_REGISTRY.resolve_existing(expr.value)
        if record is not None:
            return string(record.short_name)
        context, short_name = _split_symbol_full_name(expr.value)
        if context and _is_valid_symbol_short_name(short_name):
            return string(short_name)
    raise WolframEvaluationError("SymbolName expects a symbol or an existing symbol name.")


def context_expr(expr: Expr | None = None) -> String:
    if expr is None:
        return string(_SYMBOL_REGISTRY.current_context)
    if isinstance(expr, Symbol):
        return string(_SYMBOL_REGISTRY.record_for_symbol(expr).context)
    if isinstance(expr, String):
        record = _SYMBOL_REGISTRY.resolve_existing(expr.value)
        if record is None:
            raise WolframEvaluationError(f"Context could not find a symbol named {expr.value!r}.")
        return string(record.context)
    raise WolframEvaluationError("Context expects zero arguments, a symbol, or an existing symbol name.")


def contexts_expr(pattern: Expr | None = None) -> Call:
    return _evaluated_list_expr(*(string(context) for context in _SYMBOL_REGISTRY.contexts_matching(pattern)))


def names_expr(pattern: Expr | None = None) -> Call:
    return _evaluated_list_expr(*(string(name) for name in _SYMBOL_REGISTRY.names(pattern)))


def name_q_expr(pattern: Expr) -> Symbol:
    return _SYMBOL_REGISTRY.name_q(pattern)


def attributes_expr(expr: Expr) -> Call:
    if _is_direct_evaluate_expr(expr):
        assert isinstance(expr, Call)
        return attributes_expr(evaluate(expr.arguments[0]))
    if isinstance(expr, Call) and expr.has_head("List"):
        return _evaluated_list_expr(*(attributes_expr(item) for item in expr.arguments))
    if isinstance(expr, Symbol):
        attributes = _SYMBOL_REGISTRY.attributes_for_symbol(expr)
        return _evaluated_list_expr(*(symbol(attribute) for attribute in attributes))
    if isinstance(expr, String):
        record = _SYMBOL_REGISTRY.resolve_existing(expr.value)
        if record is None:
            emit_message(
                call("MessageName", symbol("Attributes"), string("notfound")),
                f"Symbol {expr.value} not found.",
            )
            return call("Attributes", expr)
        attributes = record.attributes
        return _evaluated_list_expr(*(symbol(attribute) for attribute in attributes))
    raise WolframEvaluationError("Attributes expects a symbol, string symbol name, or list of symbols/names.")


def _record_is_protected(record: SymbolRecord) -> bool:
    return "Protected" in record.attributes


def _record_is_locked(record: SymbolRecord) -> bool:
    return "Locked" in record.attributes


def _special_session_setting_name(record: SymbolRecord) -> str | None:
    if record.context != "System`":
        return None
    if record.short_name not in _SPECIAL_SESSION_SETTING_DEFAULTS:
        return None
    return record.short_name


def _record_allows_value_mutation(record: SymbolRecord) -> bool:
    if _special_session_setting_name(record) is not None:
        return True
    return not _record_is_protected(record) or record.full_name in {
        f"System`{name}"
        for name in _SESSION_HOOK_NAMES
    }


def _emit_protected_symbol_message(head_name: str, record: SymbolRecord) -> None:
    display = _SYMBOL_REGISTRY.display_symbol_for_record(record)
    emit_message(
        call("MessageName", symbol(head_name), string("wrsym")),
        f"Symbol {display.to_input_form()} is Protected.",
    )


def _emit_locked_symbol_message(head_name: str, record: SymbolRecord) -> None:
    display = _SYMBOL_REGISTRY.display_symbol_for_record(record)
    emit_message(
        call("MessageName", symbol(head_name), string("locked")),
        f"Symbol {display.to_input_form()} is locked.",
    )


def _emit_special_symbol_message(head_name: str, record: SymbolRecord) -> None:
    display = _SYMBOL_REGISTRY.display_symbol_for_record(record)
    emit_message(
        call("MessageName", symbol(head_name), string("spsym")),
        f"Symbol {display.to_input_form()} is a special system symbol.",
    )


def _setting_value_is_valid(name: str, value: Expr) -> bool:
    if name == "$MaxRootDegree":
        return isinstance(value, Integer) and 1 <= value.value <= 2**63 - 1
    if _is_system_infinity(value):
        return True
    minimum = _SPECIAL_SESSION_SETTING_MINIMUMS[name]
    return isinstance(value, Integer) and value.value >= minimum


def _emit_setting_limit_message(record: SymbolRecord, value: Expr) -> None:
    display = _SYMBOL_REGISTRY.display_symbol_for_record(record)
    emit_message(
        call("MessageName", display, string("limset")),
        f"Cannot set {display.to_input_form()} to {value.to_input_form()}.",
    )


def _attribute_name_from_expr(expr: Expr) -> str | None:
    if not isinstance(expr, Symbol):
        return None
    name = _system_dispatch_name(expr)
    return name if name in _KNOWN_ATTRIBUTE_NAMES else None


def _attribute_names_from_expr(expr: Expr, function_name: str) -> tuple[str, ...] | None:
    if isinstance(expr, Call) and expr.has_head("List"):
        names: list[str] = []
        for argument in expr.arguments:
            name = _attribute_name_from_expr(argument)
            if name is None:
                _emit_unknown_attribute_message(argument)
                return None
            names.append(name)
        return _canonical_attribute_tuple(names)
    name = _attribute_name_from_expr(expr)
    if name is None:
        _emit_unknown_attribute_message(expr)
        return None
    return (name,)


def _emit_unknown_attribute_message(expr: Expr) -> None:
    emit_message(
        call("MessageName", symbol("Attributes"), string("attnf")),
        f"{expr.to_input_form()} is not a known attribute.",
    )


def _symbol_record_from_attribute_target(expr: Expr, function_name: str) -> SymbolRecord | None:
    if isinstance(expr, Symbol):
        return _SYMBOL_REGISTRY.record_for_symbol(expr)
    if isinstance(expr, String):
        record = _SYMBOL_REGISTRY.resolve_existing(expr.value)
        if record is not None:
            return record
    emit_message(
        call("MessageName", symbol(function_name), string("sym")),
        f"Argument {expr.to_input_form()} is expected to be a symbol.",
    )
    return None


def _records_from_attribute_targets(expr: Expr, function_name: str) -> list[SymbolRecord] | None:
    if isinstance(expr, Call) and expr.has_head("List"):
        records: list[SymbolRecord] = []
        for argument in expr.arguments:
            child_records = _records_from_attribute_targets(argument, function_name)
            if child_records is None:
                return None
            records.extend(child_records)
        return records
    record = _symbol_record_from_attribute_target(expr, function_name)
    return None if record is None else [record]


def _records_from_name_or_symbol_specs(
    arguments: Sequence[Expr],
    function_name: str,
    *,
    strings_are_patterns: bool,
) -> list[SymbolRecord]:
    records: list[SymbolRecord] = []

    def add_from_spec(spec: Expr) -> None:
        if isinstance(spec, Call) and spec.has_head("List"):
            for item in spec.arguments:
                add_from_spec(item)
            return
        if isinstance(spec, Symbol):
            records.append(_SYMBOL_REGISTRY.record_for_symbol(spec))
            return
        if isinstance(spec, String):
            if strings_are_patterns:
                for name in _SYMBOL_REGISTRY.names(spec):
                    record = _SYMBOL_REGISTRY.resolve_existing(name)
                    if record is not None:
                        records.append(record)
                return
            record = _SYMBOL_REGISTRY.resolve_existing(spec.value)
            if record is not None:
                records.append(record)
                return
        emit_message(
            call("MessageName", symbol(function_name), string("ssym")),
            f"{spec.to_input_form()} is not a symbol or a valid string pattern.",
        )

    for argument in arguments:
        add_from_spec(argument)
    return records


def set_attributes_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 2:
        raise WolframEvaluationError("SetAttributes expects a symbol or list of symbols and an attribute specification.")
    records = _records_from_attribute_targets(arguments[0], "SetAttributes")
    attributes = _attribute_names_from_expr(arguments[1], "SetAttributes")
    if records is None or attributes is None:
        return symbol("Null")
    for record in records:
        if _record_is_locked(record):
            _emit_locked_symbol_message("Attributes", record)
            continue
        _SYMBOL_REGISTRY.add_attributes(record, attributes)
    return symbol("Null")


def clear_attributes_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 2:
        raise WolframEvaluationError("ClearAttributes expects a symbol or list of symbols and an attribute specification.")
    records = _records_from_attribute_targets(arguments[0], "ClearAttributes")
    attributes = _attribute_names_from_expr(arguments[1], "ClearAttributes")
    if records is None or attributes is None:
        return symbol("Null")
    for record in records:
        if _record_is_locked(record):
            _emit_locked_symbol_message("Attributes", record)
            continue
        _SYMBOL_REGISTRY.remove_attributes(record, attributes)
    return symbol("Null")


def set_attributes_assignment(lhs: Call, rhs_value: Expr) -> Expr:
    if len(lhs.arguments) != 1:
        raise WolframEvaluationError("Attributes assignment expects exactly one target symbol.")
    record = _symbol_record_from_attribute_target(lhs.arguments[0], "Attributes")
    attributes = _attribute_names_from_expr(rhs_value, "Attributes")
    if record is not None and attributes is not None:
        if _record_is_locked(record):
            _emit_locked_symbol_message("Attributes", record)
        else:
            _SYMBOL_REGISTRY.replace_attributes(record, attributes)
    return rhs_value


def protect_expr(arguments: Sequence[Expr], *, protect: bool) -> Call:
    function_name = "Protect" if protect else "Unprotect"
    records = _records_from_name_or_symbol_specs(arguments, function_name, strings_are_patterns=True)
    changed: list[String] = []
    for record in records:
        if _record_is_locked(record):
            _emit_locked_symbol_message("Protect", record)
            continue
        had_protected = _record_is_protected(record)
        if protect:
            if not had_protected:
                _SYMBOL_REGISTRY.add_attributes(record, ("Protected",))
                changed.append(string(_SYMBOL_REGISTRY.display_symbol_for_record(record).to_input_form()))
        elif had_protected:
            _SYMBOL_REGISTRY.remove_attributes(record, ("Protected",))
            changed.append(string(_SYMBOL_REGISTRY.display_symbol_for_record(record).to_input_form()))
    return _evaluated_list_expr(*changed)


def clear_all_expr(arguments: Sequence[Expr]) -> Expr:
    for record in _records_from_name_or_symbol_specs(arguments, "ClearAll", strings_are_patterns=True):
        if _special_session_setting_name(record) is not None:
            _emit_special_symbol_message("ClearAll", record)
            continue
        if _record_is_locked(record):
            _emit_locked_symbol_message("ClearAll", record)
            continue
        if _record_is_protected(record):
            _emit_protected_symbol_message("ClearAll", record)
            continue
        _SYMBOL_REGISTRY.clear_values(record)
        _SYMBOL_REGISTRY.replace_attributes(record, ())
    return symbol("Null")


def _own_value_rule(record: SymbolRecord) -> Expr | None:
    if record.own_value is None:
        return None
    lhs = call("HoldPattern", _SYMBOL_REGISTRY.display_symbol_for_record(record))
    return call("RuleDelayed", lhs, record.own_value)


def _normalize_assignment_lhs(lhs: Expr) -> Expr:
    """Normalize a Set/SetDelayed left-hand side before storing a rule.

    Wolfram's assignment machinery holds the outer assignment expression but
    still evaluates ordinary arguments of compound LHS forms. The defined
    head's attributes matter here: ``f[a] = rhs`` evaluates ``a`` unless
    ``f`` has a holding attribute, while ``Pattern`` and ``Condition`` keep
    their protected pieces inert through their own attributes. Head
    expressions are normalized separately so own-value tags and curried
    subvalue retargeting match the kernel's practical behavior.
    """
    if not isinstance(lhs, Call):
        return lhs
    if lhs.has_head("Condition") and len(lhs.arguments) == 2:
        body, test = lhs.arguments
        return call("Condition", _normalize_assignment_lhs(body), test)

    normalized_head = _normalize_assignment_head(lhs.head_expr)
    if isinstance(normalized_head, Symbol):
        attribute_names = _attribute_names_for_symbol(normalized_head)
        prepared = tuple(
            _evaluate_argument_with_attributes(argument, attribute_names, index)
            for index, argument in enumerate(lhs.arguments)
        )
        if not _attributes_suppress_sequence_splicing(attribute_names):
            prepared = _splice_sequence_arguments(prepared, enclosing_head=normalized_head)
        if _system_dispatch_name(normalized_head) in {"Association", "List"}:
            prepared = _drop_nothing_arguments(prepared)
        prepared = _normalize_attribute_call(normalized_head, prepared)
        return Call(head_expr=normalized_head, arguments=prepared)

    prepared = _splice_sequence_arguments(
        tuple(evaluate(argument) for argument in lhs.arguments),
        enclosing_head=normalized_head,
    )
    return Call(head_expr=normalized_head, arguments=prepared)


def _normalize_assignment_head(head: Expr) -> Expr:
    if isinstance(head, Symbol):
        return evaluate(head)
    if isinstance(head, Call):
        return evaluate(_normalize_assignment_lhs(head))
    return evaluate(head)


def _assignment_target_record(
    lhs: Expr,
    function_name: str,
) -> tuple[str, SymbolRecord] | None:
    from .expression_definitions import VALUE_KIND_DOWN, VALUE_KIND_OWN, VALUE_KIND_SUB, classify_assignment_lhs

    kind, target = classify_assignment_lhs(lhs)
    if kind not in {VALUE_KIND_OWN, VALUE_KIND_DOWN, VALUE_KIND_SUB} or target is None:
        raise WolframEvaluationError(
            f"{function_name} does not support this left-hand side in Tungsten yet."
        )
    record = _SYMBOL_REGISTRY.record_for_symbol(target)
    if not _record_allows_value_mutation(record):
        _emit_protected_symbol_message(function_name, record)
        return None
    return kind, record


def _same_symbol(a: Expr, b: Expr) -> bool:
    if not isinstance(a, Symbol) or not isinstance(b, Symbol):
        return False
    try:
        a_name = _SYMBOL_REGISTRY.record_for_symbol(a).full_name
        b_name = _SYMBOL_REGISTRY.record_for_symbol(b).full_name
        return a_name == b_name
    except WolframEvaluationError:
        return False


def _assign_compound_definition(
    function_name: str,
    lhs: Expr,
    rhs: Expr,
    *,
    delayed: bool,
) -> Expr:
    target = _assignment_target_record(lhs, function_name)
    if target is None:
        return call(function_name, lhs, rhs) if function_name == "Set" else symbol("Null")
    kind, record = target
    from .expression_definitions import VALUE_KIND_OWN, assign_definition

    if kind == VALUE_KIND_OWN:
        record.own_value = rhs
        _refresh_canonical_own_values(record)
        if record.own_values_definitions:
            record.own_values_definitions[-1].delayed = delayed
        return symbol("Null") if delayed else rhs

    assign_definition(
        record,
        kind=kind,
        hold_pattern=call("HoldPattern", lhs),
        rhs=rhs,
        delayed=delayed,
    )
    return symbol("Null") if delayed else rhs


def _tag_reaches_head_chain(tag: Symbol, expr: Expr) -> bool:
    current = expr
    while isinstance(current, Call):
        head = current.head_expr
        if _same_symbol(head, tag):
            return True
        current = head
    return _same_symbol(current, tag)


def _tag_occurs_in_upvalue_position(tag: Symbol, lhs: Expr) -> bool:
    if isinstance(lhs, Call) and lhs.has_head("Condition") and len(lhs.arguments) == 2:
        return _tag_occurs_in_upvalue_position(tag, lhs.arguments[0])
    if isinstance(lhs, Call) and lhs.has_head("HoldPattern") and len(lhs.arguments) == 1:
        return _tag_occurs_in_upvalue_position(tag, lhs.arguments[0])
    if not isinstance(lhs, Call):
        return False
    return any(
        _same_symbol(argument, tag)
        or (isinstance(argument, Call) and _tag_reaches_head_chain(tag, argument))
        for argument in lhs.arguments
    )


def _emit_tag_position_message(function_name: str, tag: Symbol, lhs: Expr) -> None:
    emit_message(
        call("MessageName", symbol(function_name), string("tagpos")),
        f"Tag {tag.to_input_form()} does not occur in a supported position in {lhs.to_input_form()}.",
    )


def _tag_assignment_target(
    tag: Symbol,
    lhs: Expr,
    function_name: str,
) -> tuple[str, SymbolRecord] | None:
    tag_record = _SYMBOL_REGISTRY.record_for_symbol(tag)
    from .expression_definitions import VALUE_KIND_UP, classify_assignment_lhs

    natural_kind, natural_target = classify_assignment_lhs(lhs)
    if natural_target is not None:
        natural_record = _SYMBOL_REGISTRY.record_for_symbol(natural_target)
        if natural_record.full_name == tag_record.full_name:
            if not _record_allows_value_mutation(tag_record):
                _emit_protected_symbol_message(function_name, tag_record)
                return None
            return natural_kind, tag_record

    if _tag_occurs_in_upvalue_position(tag, lhs):
        if not _record_allows_value_mutation(tag_record):
            _emit_protected_symbol_message(function_name, tag_record)
            return None
        return VALUE_KIND_UP, tag_record

    _emit_tag_position_message(function_name, tag, lhs)
    return None


def tag_set_expr(arguments: Sequence[Expr], *, delayed: bool) -> Expr:
    function_name = "TagSetDelayed" if delayed else "TagSet"
    if len(arguments) != 3:
        raise WolframEvaluationError(f"{function_name} expects a tag, left-hand side, and right-hand side.")
    tag, lhs, rhs = arguments
    if not isinstance(tag, Symbol):
        raise WolframEvaluationError(f"{function_name} expects a symbol tag.")
    rhs_value = rhs if delayed else evaluate(rhs)
    lhs = _normalize_assignment_lhs(lhs)
    target = _tag_assignment_target(tag, lhs, function_name)
    if target is None:
        return symbol("Null") if delayed else call(function_name, tag, lhs, rhs_value)
    kind, record = target
    from .expression_definitions import VALUE_KIND_OWN, assign_definition

    if kind == VALUE_KIND_OWN:
        record.own_value = rhs_value
        _refresh_canonical_own_values(record)
        if record.own_values_definitions:
            record.own_values_definitions[-1].delayed = delayed
        return symbol("Null") if delayed else rhs_value

    assign_definition(
        record,
        kind=kind,
        hold_pattern=call("HoldPattern", lhs),
        rhs=rhs_value,
        delayed=delayed,
    )
    return symbol("Null") if delayed else rhs_value


def set_delayed_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``SetDelayed[lhs, rhs]`` (``lhs := rhs``).

    For the bare-symbol case, the RHS is stored *unevaluated* and gets
    evaluated each time the symbol is read. This is the canonical Wolfram
    contract for ``:=`` (delayed assignment). Compound LHS forms such as
    ``f[x_] := rhs`` and ``f[x_][y_] := rhs`` are stored as DownValues or
    SubValues on the target symbol and applied by the evaluator's ordinary
    definition dispatch.
    """
    if len(arguments) != 2:
        raise WolframEvaluationError("SetDelayed expects exactly two arguments.")
    lhs, rhs = arguments
    lhs = _normalize_assignment_lhs(lhs)
    if not isinstance(lhs, Symbol):
        return _assign_compound_definition("SetDelayed", lhs, rhs, delayed=True)
    record = _SYMBOL_REGISTRY.record_for_symbol(lhs)
    if not _record_allows_value_mutation(record):
        _emit_protected_symbol_message("SetDelayed", record)
        return symbol("Null")
    setting_name = _special_session_setting_name(record)
    if setting_name is not None and not _setting_value_is_valid(setting_name, rhs):
        _emit_setting_limit_message(record, rhs)
        return symbol("Null")
    record.own_value = rhs
    _refresh_canonical_own_values(record)
    # Reflect the delayed flag on the canonical Definition so future
    # consumers can distinguish the two forms.
    if record.own_values_definitions:
        record.own_values_definitions[-1].delayed = True
    return symbol("Null")


def _apply_inplace_arithmetic_to_symbol(
    head_name: str,
    target: Expr,
    delta: int,
    *,
    return_old: bool,
) -> Expr:
    """Mutate a Symbol's own value by ``delta`` and return the old or
    new value.

    Used by ``Increment`` / ``PreIncrement`` / ``Decrement`` /
    ``PreDecrement``. ``head_name`` is only used for error messages.
    Currently only bare-symbol targets are supported; compound targets
    such as ``parts[i]`` fall through to the inert form.
    """
    if not isinstance(target, Symbol):
        raise WolframEvaluationError(
            f"{head_name} currently expects a bare-symbol target."
        )
    record = _SYMBOL_REGISTRY.record_for_symbol(target)
    if not _record_allows_value_mutation(record):
        _emit_protected_symbol_message(head_name, record)
        raise WolframEvaluationError(
            f"{head_name}: cannot modify protected symbol."
        )
    old_value = evaluate(target)
    new_value = evaluate(call("Plus", old_value, integer(delta)))
    record.own_value = new_value
    _refresh_canonical_own_values(record)
    return old_value if return_old else new_value


def increment_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``Increment[x]`` (parser form ``x++``).

    Returns the value of ``x`` *before* the increment, then sets
    ``x`` to ``x + 1``. Tungsten currently supports only bare-symbol
    targets; compound targets such as ``parts[i]`` fall through to
    the inert form.
    """
    if len(arguments) != 1:
        raise WolframEvaluationError("Increment expects exactly one argument.")
    return _apply_inplace_arithmetic_to_symbol(
        "Increment", arguments[0], +1, return_old=True
    )


def decrement_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``Decrement[x]`` (parser form ``x--``).

    Returns the old value of ``x`` and sets ``x`` to ``x - 1``.
    """
    if len(arguments) != 1:
        raise WolframEvaluationError("Decrement expects exactly one argument.")
    return _apply_inplace_arithmetic_to_symbol(
        "Decrement", arguments[0], -1, return_old=True
    )


def pre_increment_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``PreIncrement[x]`` (parser form ``++x``).

    Sets ``x`` to ``x + 1`` and returns the new value.
    """
    if len(arguments) != 1:
        raise WolframEvaluationError("PreIncrement expects exactly one argument.")
    return _apply_inplace_arithmetic_to_symbol(
        "PreIncrement", arguments[0], +1, return_old=False
    )


def pre_decrement_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``PreDecrement[x]`` (parser form ``--x``).

    Sets ``x`` to ``x - 1`` and returns the new value.
    """
    if len(arguments) != 1:
        raise WolframEvaluationError("PreDecrement expects exactly one argument.")
    return _apply_inplace_arithmetic_to_symbol(
        "PreDecrement", arguments[0], -1, return_old=False
    )


def set_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 2:
        raise WolframEvaluationError("Set expects exactly two arguments.")
    lhs, rhs = arguments
    rhs_value = evaluate(rhs)
    if isinstance(lhs, Call) and lhs.has_head("Attributes"):
        return set_attributes_assignment(lhs, rhs_value)
    lhs = _normalize_assignment_lhs(lhs)
    if not isinstance(lhs, Symbol):
        return _assign_compound_definition("Set", lhs, rhs_value, delayed=False)
    record = _SYMBOL_REGISTRY.record_for_symbol(lhs)
    if not _record_allows_value_mutation(record):
        _emit_protected_symbol_message("Set", record)
        return call("Set", lhs, rhs_value)
    setting_name = _special_session_setting_name(record)
    if setting_name is not None and not _setting_value_is_valid(setting_name, rhs_value):
        _emit_setting_limit_message(record, rhs_value)
        return record.own_value if record.own_value is not None else _SPECIAL_SESSION_SETTING_DEFAULTS[setting_name]
    record.own_value = rhs_value
    _refresh_canonical_own_values(record)
    return rhs_value


def _refresh_canonical_own_values(record: "SymbolRecord") -> None:
    """Mirror the legacy ``own_value`` slot into the canonical own-values list.

    The legacy slot remains the source of truth for bare-symbol evaluation.
    This helper keeps ``OwnValues[sym]`` honest about what's currently stored,
    while compound definitions write directly to the canonical DownValues and
    SubValues lists.
    """
    _SYMBOL_REGISTRY._mirror_own_value_into_canonical(record)


def unset_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 1:
        raise WolframEvaluationError("Unset expects exactly one argument.")
    lhs = _normalize_assignment_lhs(arguments[0])
    if not isinstance(lhs, Symbol):
        target = _assignment_target_record(lhs, "Unset")
        if target is None:
            return symbol("$Failed")
        kind, record = target
        from .expression_definitions import remove_definitions

        return symbol("Null") if remove_definitions(record, kind, call("HoldPattern", lhs)) else symbol("$Failed")
    record = _SYMBOL_REGISTRY.record_for_symbol(lhs)
    if not _record_allows_value_mutation(record):
        _emit_protected_symbol_message("Unset", record)
        return symbol("$Failed")
    if _special_session_setting_name(record) is not None:
        _emit_special_symbol_message("Unset", record)
        return symbol("$Failed")
    record.own_value = None
    _refresh_canonical_own_values(record)
    return symbol("Null")


def tag_unset_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 2:
        raise WolframEvaluationError("TagUnset expects a tag and a left-hand side.")
    tag, lhs = arguments
    if not isinstance(tag, Symbol):
        raise WolframEvaluationError("TagUnset expects a symbol tag.")
    lhs = _normalize_assignment_lhs(lhs)
    target = _tag_assignment_target(tag, lhs, "TagUnset")
    if target is None:
        return symbol("$Failed")
    kind, record = target
    from .expression_definitions import VALUE_KIND_OWN, coalesce_legacy_own_value, remove_definitions

    if remove_definitions(record, kind, call("HoldPattern", lhs)):
        if kind == VALUE_KIND_OWN:
            if not record.own_values_definitions:
                record.own_value = None
            else:
                coalesce_legacy_own_value(record)
        return symbol("Null")
    emit_message(
        call("MessageName", symbol("TagUnset"), string("norep")),
        f"Assignment on {tag.to_input_form()} for {lhs.to_input_form()} not found.",
    )
    return symbol("$Failed")


def _clear_record(record: SymbolRecord) -> None:
    if _special_session_setting_name(record) is not None:
        _emit_special_symbol_message("Clear", record)
        return
    if not _record_allows_value_mutation(record):
        _emit_protected_symbol_message("Clear", record)
        return
    _SYMBOL_REGISTRY.clear_values(record)


def clear_expr(arguments: Sequence[Expr]) -> Expr:
    for argument in arguments:
        _clear_one(argument)
    return symbol("Null")


def _clear_one(argument: Expr) -> None:
    if isinstance(argument, Call) and argument.has_head("List"):
        for item in argument.arguments:
            _clear_one(item)
        return
    if isinstance(argument, Symbol):
        _clear_record(_SYMBOL_REGISTRY.record_for_symbol(argument))
        return
    if isinstance(argument, String):
        for name in _SYMBOL_REGISTRY.names(argument):
            record = _SYMBOL_REGISTRY.resolve_existing(name)
            if record is not None:
                _clear_record(record)
        return
    emit_message(
        call("MessageName", symbol("Clear"), string("ssym")),
        f"{argument.to_input_form()} is not a symbol or a valid string pattern.",
    )


def own_values_expr(expr: Expr) -> Call:
    """Returns the list of own-value rules for ``expr``.

    Reads from the canonical ``own_values_definitions`` storage when
    populated, and falls back to the legacy single-slot ``own_value``
    field for symbols whose values were seeded directly during registry
    initialization (e.g., ``$MessagePrePrint = Automatic``). Once all
    own-value writes use canonical storage directly, this fallback can retire.
    """
    from .expression_definitions import VALUE_KIND_OWN, rules_for_kind

    if isinstance(expr, Symbol):
        record = _SYMBOL_REGISTRY.record_for_symbol(expr)
    elif isinstance(expr, String):
        record = _SYMBOL_REGISTRY.resolve_existing(expr.value)
        if record is None:
            raise WolframEvaluationError(f"OwnValues could not find a symbol named {expr.value!r}.")
    else:
        raise WolframEvaluationError("OwnValues expects a symbol or the name of an existing symbol.")
    if record.own_values_definitions:
        return _evaluated_list_expr(*rules_for_kind(record, VALUE_KIND_OWN))
    if record.own_value is not None:
        lhs = call("HoldPattern", _SYMBOL_REGISTRY.display_symbol_for_record(record))
        return _evaluated_list_expr(call("RuleDelayed", lhs, record.own_value))
    return _evaluated_list_expr()


def _own_values_record(expr: Expr, function_name: str) -> SymbolRecord | None:
    """Resolve the SymbolRecord for ``expr`` for a values getter.

    Returns ``None`` when ``expr`` is a string naming a symbol that doesn't
    exist (the kernel returns ``{}`` here rather than erroring).
    """
    if isinstance(expr, Symbol):
        return _SYMBOL_REGISTRY.record_for_symbol(expr)
    if isinstance(expr, String):
        return _SYMBOL_REGISTRY.resolve_existing(expr.value)
    raise WolframEvaluationError(
        f"{function_name} expects a symbol or the name of an existing symbol."
    )


def history_expr(head_name: str, arguments: Sequence[Expr]) -> Expr:
    session = _active_evaluation_session()
    if session is None:
        return call(head_name, *arguments)
    if len(arguments) > 1:
        raise WolframEvaluationError(f"{head_name} expects zero or one line specification.")

    index = session.resolve_index(arguments[0] if arguments else None)
    if head_name == "In":
        assert session.inputs is not None
        assert session.expanding_inputs is not None
        stored = session.inputs.get(index)
        if stored is None or index in session.expanding_inputs:
            return call("In", integer(index))
        session.expanding_inputs.add(index)
        try:
            return evaluate(stored, session=session)
        finally:
            session.expanding_inputs.discard(index)
    if head_name == "InString":
        assert session.in_strings is not None
        stored_text = session.in_strings.get(index)
        return string(stored_text) if stored_text is not None else call("InString", integer(index))
    if head_name == "Out":
        assert session.outputs is not None
        stored_output = session.outputs.get(index)
        return stored_output if stored_output is not None else call("Out", integer(index))
    raise WolframEvaluationError(f"Unsupported history function {head_name}.")


def down_values_expr(expr: Expr) -> Call:
    """Return the list of down-values for ``expr``.

    For the session-history symbols ``In`` / ``InString`` / ``Out``, the
    list is synthesized from the active ``EvaluationSession``'s recorded
    history (read-only, current behavior). For any other symbol, the list
    is read from the canonical ``record.down_values_definitions`` storage
    populated by supported compound-LHS Set / SetDelayed definitions.
    """
    session = _active_evaluation_session()
    if session is not None and isinstance(expr, Symbol):
        name = _system_dispatch_name(expr)
        if name == "In":
            assert session.inputs is not None
            return _evaluated_list_expr(
                *(
                    call("RuleDelayed", call("HoldPattern", call("In", integer(index))), value)
                    for index, value in sorted(session.inputs.items())
                )
            )
        if name == "InString":
            assert session.in_strings is not None
            return _evaluated_list_expr(
                *(
                    call("RuleDelayed", call("HoldPattern", call("InString", integer(index))), string(value))
                    for index, value in sorted(session.in_strings.items())
                )
            )
        if name == "Out":
            assert session.outputs is not None
            return _evaluated_list_expr(
                *(
                    call("RuleDelayed", call("HoldPattern", call("Out", integer(index))), value)
                    for index, value in sorted(session.outputs.items())
                )
            )

    record = _own_values_record(expr, "DownValues")
    if record is None:
        return _evaluated_list_expr()
    from .expression_definitions import VALUE_KIND_DOWN, rules_for_kind
    return _evaluated_list_expr(*rules_for_kind(record, VALUE_KIND_DOWN))


def up_values_expr(expr: Expr) -> Call:
    """Return the list of up-values for ``expr``.

    Currently always empty for the bare-symbol Set / SetDelayed subset;
    the upcoming UpSet / UpSetDelayed pass will populate the canonical
    ``up_values_definitions`` storage and this getter immediately reflects
    that.
    """
    record = _own_values_record(expr, "UpValues")
    if record is None:
        return _evaluated_list_expr()
    from .expression_definitions import VALUE_KIND_UP, rules_for_kind
    return _evaluated_list_expr(*rules_for_kind(record, VALUE_KIND_UP))


def sub_values_expr(expr: Expr) -> Call:
    """Return the list of sub-values for ``expr``.

    Reads from the canonical ``sub_values_definitions`` storage populated by
    supported curried compound-LHS Set / SetDelayed definitions such as
    ``f[x_][y_] := ...``.
    """
    record = _own_values_record(expr, "SubValues")
    if record is None:
        return _evaluated_list_expr()
    from .expression_definitions import VALUE_KIND_SUB, rules_for_kind
    return _evaluated_list_expr(*rules_for_kind(record, VALUE_KIND_SUB))


def n_values_expr(expr: Expr) -> Call:
    """Return the list of N-values for ``expr``.

    Currently always empty; reserved for the upcoming NValues storage.
    """
    record = _own_values_record(expr, "NValues")
    if record is None:
        return _evaluated_list_expr()
    from .expression_definitions import VALUE_KIND_N, rules_for_kind
    return _evaluated_list_expr(*rules_for_kind(record, VALUE_KIND_N))


def _definition_pattern_expr(hold_pattern: Expr) -> Expr:
    if isinstance(hold_pattern, Call) and hold_pattern.has_head("HoldPattern") and len(hold_pattern.arguments) == 1:
        return hold_pattern.arguments[0]
    return hold_pattern


def _apply_definitions(expr: Expr, definitions: Sequence[object]) -> Expr | None:
    """Apply the first matching definition rule to ``expr``.

    Each rule is evaluated as a function-application boundary: a bare
    ``Return[value]`` raised inside the rule's RHS is caught here and
    unwraps to ``value``, matching the kernel's "Return exits the
    nearest enclosing function definition" semantics. Headed
    ``Return[value, head]`` signals propagate through unchanged so
    the targeted handler upstream can catch them.
    """
    for definition in definitions:
        pattern = _definition_pattern_expr(definition.hold_pattern)
        bindings = _match_pattern(expr, pattern)
        if bindings is None:
            continue
        condition = getattr(definition, "condition", None)
        if condition is not None and not _condition_test_succeeds(condition, bindings):
            continue
        try:
            replacement, applied = _instantiate_replacement_template(
                definition.rhs,
                bindings,
                delayed=definition.delayed,
                evaluate_result=False,
            )
            if applied:
                assert replacement is not None
                replacement = _evaluate_iteration_continuation(replacement)
        except _TungstenReturnSignal as signal:
            if signal.head_name is None:
                return signal.value
            raise
        if applied:
            assert replacement is not None
            return replacement
    return None


def _apply_down_value_definitions(head: Symbol, expr: Expr) -> Expr | None:
    record = _SYMBOL_REGISTRY.record_for_symbol(head)
    if not record.down_values_definitions:
        return None
    return _apply_definitions(expr, tuple(record.down_values_definitions))


def _head_chain_symbols(expr: Expr) -> tuple[Symbol, ...]:
    symbols: list[Symbol] = []
    current = expr
    while isinstance(current, Call):
        head = current.head_expr
        if isinstance(head, Symbol):
            symbols.append(head)
            break
        current = head
    return tuple(symbols)


def _up_value_candidate_symbols(expr: Expr) -> tuple[Symbol, ...]:
    if not isinstance(expr, Call):
        return ()
    candidates: list[Symbol] = []
    seen: set[str] = set()

    def add(candidate: Symbol) -> None:
        try:
            full_name = _SYMBOL_REGISTRY.record_for_symbol(candidate).full_name
        except WolframEvaluationError:
            return
        if full_name in seen:
            return
        seen.add(full_name)
        candidates.append(candidate)

    for argument in expr.arguments:
        if isinstance(argument, Symbol):
            add(argument)
        elif isinstance(argument, Call):
            for candidate in _head_chain_symbols(argument):
                add(candidate)
    return tuple(candidates)


def _apply_up_value_definitions(expr: Expr) -> Expr | None:
    for candidate in _up_value_candidate_symbols(expr):
        record = _SYMBOL_REGISTRY.record_for_symbol(candidate)
        if not record.up_values_definitions:
            continue
        result = _apply_definitions(expr, tuple(record.up_values_definitions))
        if result is not None:
            return result
    return None


def _subvalue_target_symbol(expr: Expr) -> Symbol | None:
    head = expr.head_expr if isinstance(expr, Call) else None
    while isinstance(head, Call):
        head = head.head_expr
    return head if isinstance(head, Symbol) else None


def _apply_sub_value_definitions(expr: Expr) -> Expr | None:
    if not isinstance(expr, Call):
        return None
    target = _subvalue_target_symbol(expr)
    if target is None:
        return None
    record = _SYMBOL_REGISTRY.record_for_symbol(target)
    if not record.sub_values_definitions:
        return None
    return _apply_definitions(expr, tuple(record.sub_values_definitions))


def exit_expr(arguments: Sequence[Expr]) -> None:
    if len(arguments) == 0:
        raise TungstenExitRequested(0)
    if len(arguments) == 1:
        code = evaluate(arguments[0])
        if not isinstance(code, Integer):
            raise WolframEvaluationError("Exit and Quit expect an optional integer exit code.")
        raise TungstenExitRequested(code.value)
    raise WolframEvaluationError("Exit and Quit expect zero or one argument.")


def abort_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 0:
        raise WolframEvaluationError("Abort expects no arguments.")
    if not _active_check_abort_handles_current_abort() and _defer_abort_to_current_protect():
        return symbol("Null")
    raise TungstenAbortRequested()


def throw_expr(arguments: Sequence[Expr]) -> None:
    if len(arguments) == 1:
        raise _TungstenThrowSignal(evaluate(arguments[0]))
    if len(arguments) == 2:
        raise _TungstenThrowSignal(evaluate(arguments[0]), evaluate(arguments[1]))
    if len(arguments) == 3:
        raise _TungstenThrowSignal(evaluate(arguments[0]), evaluate(arguments[1]), evaluate(arguments[2]))
    raise WolframEvaluationError("Throw expects one, two, or three arguments.")


def break_expr(arguments: Sequence[Expr]) -> None:
    """Raise a ``_TungstenBreakSignal`` so the nearest enclosing
    ``Do`` / ``While`` / ``For`` exits cleanly.

    ``Break`` takes no arguments. If any are supplied, Tungsten falls
    through to the inert form (matching the kernel's ``Break::argx``
    error and inert return).
    """
    if len(arguments) != 0:
        raise WolframEvaluationError("Break expects no arguments.")
    raise _TungstenBreakSignal()


def continue_expr(arguments: Sequence[Expr]) -> None:
    """Raise a ``_TungstenContinueSignal`` so the nearest enclosing
    ``Do`` / ``While`` / ``For`` skips to its next iteration.

    Like ``Break``, ``Continue`` takes no arguments; extra arguments
    fall through to the inert form via ``WolframEvaluationError``.
    """
    if len(arguments) != 0:
        raise WolframEvaluationError("Continue expects no arguments.")
    raise _TungstenContinueSignal()


def return_expr(arguments: Sequence[Expr]) -> None:
    """Raise a ``_TungstenReturnSignal`` for ``Return[expr]`` or
    ``Return[expr, head]``.

    The single-argument form propagates through the evaluator until a
    function-definition rule application catches it (so an ordinary
    SetDelayed-defined ``f[x_] := ...; Return[v]; ...`` returns ``v``
    from ``f[...]``). The two-argument form names the enclosing head
    that should catch the signal — the head must evaluate to a
    ``Symbol`` (e.g. ``Module``, ``Block``, ``For``, ``While``,
    ``Do``).

    A bare ``Return[]`` is treated as ``Return[Null]`` to match the
    kernel; arities outside ``{0, 1, 2}`` fall through to the inert
    form.
    """
    if len(arguments) == 0:
        raise _TungstenReturnSignal(symbol("Null"))
    if len(arguments) == 1:
        raise _TungstenReturnSignal(evaluate(arguments[0]))
    if len(arguments) == 2:
        head_expr = evaluate(arguments[1])
        if not isinstance(head_expr, Symbol):
            raise WolframEvaluationError(
                "Return's second argument must evaluate to a Symbol."
            )
        raise _TungstenReturnSignal(evaluate(arguments[0]), head_expr.name)
    raise WolframEvaluationError("Return expects zero, one, or two arguments.")


def label_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``Label[name]``.

    ``Label`` is a marker for ``Goto``: by itself it has no
    side effect and stays inert (``Label[name]`` evaluates to
    ``Label[name]``), matching the kernel. The marker semantics
    happen entirely inside ``CompoundExpression`` — when a ``Goto``
    signal is raised, that handler scans its argument list for a
    structurally matching ``Label[...]`` and resumes from after it.
    """
    if len(arguments) != 1:
        raise WolframEvaluationError("Label expects exactly one argument.")
    return call("Label", arguments[0])


def goto_expr(arguments: Sequence[Expr]) -> None:
    """Raise a ``_TungstenGotoSignal`` so the nearest enclosing
    ``CompoundExpression`` resumes at a matching ``Label``.

    The label argument is evaluated before the signal is raised so that
    forms like ``Goto[Symbol[\"end\"]]`` work the same as the literal
    ``Goto[end]``. If no enclosing ``CompoundExpression`` carries a
    matching ``Label``, the signal propagates to ``evaluate`` and is
    converted back to the inert ``Goto[label]`` form.
    """
    if len(arguments) != 1:
        raise WolframEvaluationError("Goto expects exactly one argument.")
    raise _TungstenGotoSignal(evaluate(arguments[0]))


def _uncaught_throw_result(signal: _TungstenThrowSignal) -> Expr:
    if signal.tag is None:
        return call("Throw", signal.value)
    tag = evaluate(signal.tag)
    if signal.handler is not None:
        return _apply_callable(signal.handler, (signal.value, tag))
    return call("Throw", signal.value, tag)


def catch_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Catch expects one, two, or three arguments.")

    form = evaluate(arguments[1]) if len(arguments) >= 2 else None
    handler = evaluate(arguments[2]) if len(arguments) == 3 else None
    try:
        return evaluate(arguments[0])
    except _TungstenThrowSignal as signal:
        if form is None:
            if signal.tag is None:
                return signal.value
            raise

        if signal.tag is None:
            raise

        tag = evaluate(signal.tag)
        if _match_pattern(tag, form) is None:
            raise
        if handler is None:
            return signal.value
        return _apply_callable(handler, (signal.value, tag))


def _enclose_scope_matches(scope: _EncloseScope, tag: Expr | None) -> bool:
    if scope.form is None:
        return tag is None
    if tag is None:
        return False
    return _match_pattern(tag, scope.form) is not None


def _has_matching_enclose_scope(tag: Expr | None) -> bool:
    return any(_enclose_scope_matches(scope, tag) for scope in _ACTIVE_ENCLOSE_SCOPES.get())


def _confirmation_failure(
    confirmation_type: str,
    expression: Expr,
    info: Expr,
    extra_fields: Sequence[tuple[str, Expr]] = (),
) -> Expr:
    fields: list[tuple[str, Expr]] = [
        ("ConfirmationType", symbol(confirmation_type)),
        ("Expression", expression),
        ("Information", info),
    ]
    fields.extend(extra_fields)
    return _failure_expr("ConfirmationFailed", fields)


def _confirm_or_return_failure(failure: Expr, tag: Expr | None) -> Expr:
    if _has_matching_enclose_scope(tag):
        raise _TungstenConfirmSignal(failure, tag)
    emit_message(call("MessageName", symbol("Confirm"), string("confirmnotag")))
    return failure


def _confirm_info(arguments: Sequence[Expr], info_index: int) -> Expr:
    if len(arguments) > info_index:
        return evaluate(arguments[info_index])
    return symbol("Null")


def confirm_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Confirm expects one, two, or three arguments.")
    value = evaluate(arguments[0])
    if not _is_confirm_failure_expr(value):
        return value
    info = _confirm_info(arguments, 1)
    tag = evaluate(arguments[2]) if len(arguments) == 3 else None
    if _is_failure_expr(value) and len(arguments) == 1:
        failure = value
    else:
        failure = _confirmation_failure("Confirm", value, info)
    return _confirm_or_return_failure(failure, tag)


def confirm_by_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {2, 3, 4}:
        raise WolframEvaluationError("ConfirmBy expects two, three, or four arguments.")
    value = evaluate(arguments[0])
    function = evaluate(arguments[1])
    if _apply_callable(function, (value,)) == symbol("True"):
        return value
    info = _confirm_info(arguments, 2)
    tag = evaluate(arguments[3]) if len(arguments) == 4 else None
    failure = _confirmation_failure("ConfirmBy", value, info, (("Function", function),))
    return _confirm_or_return_failure(failure, tag)


def confirm_match_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {2, 3, 4}:
        raise WolframEvaluationError("ConfirmMatch expects two, three, or four arguments.")
    value = evaluate(arguments[0])
    pattern = arguments[1]
    if _match_pattern(value, pattern) is not None:
        return value
    info = _confirm_info(arguments, 2)
    tag = evaluate(arguments[3]) if len(arguments) == 4 else None
    failure = _confirmation_failure("ConfirmMatch", value, info, (("Pattern", pattern),))
    return _confirm_or_return_failure(failure, tag)


def confirm_assert_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("ConfirmAssert expects one, two, or three arguments.")
    test = evaluate(arguments[0])
    if test == symbol("True"):
        return symbol("Null")
    info = _confirm_info(arguments, 1)
    tag = evaluate(arguments[2]) if len(arguments) == 3 else None
    failure = _confirmation_failure("ConfirmAssert", test, info, (("Test", test),))
    return _confirm_or_return_failure(failure, tag)


def _handle_enclosed_failure(failure: Expr, handler: Expr | None) -> Expr:
    if handler is None:
        return failure
    evaluated_handler = evaluate(handler)
    if isinstance(evaluated_handler, String):
        return failure_property(failure, evaluated_handler)
    return _apply_callable(evaluated_handler, (failure,))


def enclose_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Enclose expects one, two, or three arguments.")
    handler = arguments[1] if len(arguments) >= 2 else None
    form = evaluate(arguments[2]) if len(arguments) == 3 else None
    scope = _EncloseScope(form=form)
    scopes = _ACTIVE_ENCLOSE_SCOPES.get()
    token = _ACTIVE_ENCLOSE_SCOPES.set(scopes + (scope,))
    try:
        try:
            return evaluate(arguments[0])
        except _TungstenConfirmSignal as signal:
            if not _enclose_scope_matches(scope, signal.tag):
                raise
            return _handle_enclosed_failure(signal.failure, handler)
    finally:
        _ACTIVE_ENCLOSE_SCOPES.reset(token)


def assert_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2}:
        raise WolframEvaluationError("Assert expects one or two arguments.")
    if not _assert_enabled():
        return call("Assert", *arguments)
    test = evaluate(arguments[0])
    if test == symbol("True"):
        return symbol("Null")
    tag = evaluate(arguments[1]) if len(arguments) == 2 else symbol("Null")
    emit_message(call("MessageName", symbol("Assert"), string("asrtfl")), insertions=(test, tag))
    return symbol("Null")


def failsafe_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Failsafe expects one, two, or three arguments.")
    return call("Failsafe", *(evaluate(argument) for argument in arguments))


def failsafe_apply(function: Expr, arguments: Sequence[Expr]) -> Expr:
    assert isinstance(function, Call)
    if len(function.arguments) == 1:
        for argument in arguments:
            if _is_failsafe_failure_expr(argument):
                return argument
        return _apply_callable(function.arguments[0], arguments)
    if len(function.arguments) in {2, 3}:
        test_result = _apply_callable(function.arguments[1], arguments)
        if test_result == symbol("True"):
            return _apply_callable(function.arguments[0], arguments)
        if len(function.arguments) == 3:
            return _apply_callable(function.arguments[2], arguments)
        return _failure_expr("FailsafeFailed", (("Arguments", call("Hold", *arguments)),))
    raise WolframEvaluationError("Failsafe expects one, two, or three arguments.")


def with_cleanup_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {2, 3}:
        raise WolframEvaluationError("WithCleanup expects two or three arguments.")
    cleanup = arguments[-1]
    pending: BaseException | None = None
    result: Expr = symbol("Null")

    if len(arguments) == 3:
        try:
            _abort_protected_time_suppressed(arguments[0])
            _check_time_constraints()
        except _CONTROL_SIGNAL_TYPES as signal:
            pending = signal

    if pending is None:
        try:
            result = evaluate(arguments[-2])
        except _CONTROL_SIGNAL_TYPES as signal:
            pending = signal

    _abort_protected_time_suppressed(cleanup)
    if pending is not None:
        raise pending
    return result


def check_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {2, 3}:
        raise WolframEvaluationError("Check expects two or three arguments.")
    spec = evaluate(arguments[2]) if len(arguments) == 3 else symbol("All")
    token, collector = _push_message_collector(spec)
    try:
        result = evaluate(arguments[0])
    finally:
        _ACTIVE_MESSAGE_COLLECTORS.reset(token)
    if collector.messages:
        return evaluate(arguments[1])
    return result


def quiet_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) == 1:
        off_spec = symbol("All")
        on_spec = symbol("None")
    elif len(arguments) == 2:
        off_spec = evaluate(arguments[1])
        on_spec = symbol("None")
    elif len(arguments) == 3:
        off_spec = evaluate(arguments[1])
        on_spec = evaluate(arguments[2])
    else:
        raise WolframEvaluationError("Quiet expects one, two, or three arguments.")
    token = _push_quiet_scope(off_spec, on_spec)
    try:
        return evaluate(arguments[0])
    finally:
        _ACTIVE_QUIET_SCOPES.reset(token)


def message_expr(arguments: Sequence[Expr]) -> Expr:
    if not arguments:
        raise WolframEvaluationError("Message expects a message name.")
    message_name = arguments[0]
    if not (isinstance(message_name, Call) and message_name.has_head("MessageName")):
        raise WolframEvaluationError("Message expects a message name of the form symbol::tag.")
    insertions = tuple(evaluate(argument) for argument in arguments[1:])
    emit_message(message_name, insertions=insertions)
    return symbol("Null")


def off_expr(arguments: Sequence[Expr]) -> Expr:
    if not arguments:
        return symbol("Null")
    for argument in arguments:
        _set_on_off_enabled(evaluate(argument), enabled=False)
    return symbol("Null")


def on_expr(arguments: Sequence[Expr]) -> Expr:
    if not arguments:
        return symbol("Null")
    for argument in arguments:
        _set_on_off_enabled(evaluate(argument), enabled=True)
    return symbol("Null")


def _format_print_argument(expr: Expr) -> str:
    _label, text = display_output_parts(expr)
    return text


def print_expr(arguments: Sequence[Expr]) -> Expr:
    evaluated_arguments = tuple(evaluate(argument) for argument in arguments)
    _current_prints().append("".join(_format_print_argument(argument) for argument in evaluated_arguments))
    return symbol("Null")


def compound_expression_expr(arguments: Sequence[Expr]) -> Expr:
    """Evaluate ``expr1; expr2; ...`` left to right and return the
    final value (or ``Null`` for a trailing semicolon).

    ``Goto[label]`` raised inside any ``arg`` is caught here: Tungsten
    scans the argument list for the first ``Label[label]`` whose label
    is structurally equal to the goto target and resumes evaluation
    from the position immediately after that ``Label``. A goto whose
    target does not match any ``Label`` in this CompoundExpression
    propagates outward so an enclosing CompoundExpression (or the
    top-level evaluator's inert-fallback) can handle it.

    ``Label[name]`` itself is handled inline by ``label_expr`` and
    just returns ``Null``; the marker behavior happens entirely in
    this loop. The Label scan is structural: ``Label[a]`` matches
    ``Goto[a]`` because Tungsten compares the label expressions for
    equality after evaluating the goto argument.
    """
    result: Expr = symbol("Null")
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        try:
            result = evaluate(argument)
        except TungstenAbortRequested:
            if not _defer_abort_to_current_protect():
                raise
            result = symbol("Null")
        except _TungstenGotoSignal as signal:
            target_index = _find_label_index(arguments, signal.label)
            if target_index is None:
                raise
            index = target_index + 1
            result = symbol("Null")
            continue
        index += 1
    return result


def _find_label_index(arguments: Sequence[Expr], label: Expr) -> int | None:
    """Return the index of the first ``Label[label]`` argument matching
    ``label``, or ``None`` if no marker matches.

    Labels can be evaluated lazily — ``Label[end]`` parses with ``end``
    as a symbol that may have an own value at goto-time. Tungsten
    compares the *unevaluated* label argument inside ``Label[...]``
    against the goto target so a label slot whose name evaluates
    differently from the goto's argument still matches when the
    surface text is identical (the kernel's behavior in practice).
    """
    for index, argument in enumerate(arguments):
        if not (isinstance(argument, Call) and argument.has_head("Label")):
            continue
        if len(argument.arguments) != 1:
            continue
        if argument.arguments[0] == label:
            return index
    return None


def check_abort_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 2:
        raise WolframEvaluationError("CheckAbort expects exactly two arguments.")
    scopes = _ACTIVE_CHECK_ABORT_SCOPES.get()
    scope = _CheckAbortScope(abort_protect_depth=_current_abort_protect_depth())
    token = _ACTIVE_CHECK_ABORT_SCOPES.set(scopes + (scope,))
    try:
        try:
            return evaluate(arguments[0])
        except TungstenAbortRequested:
            return evaluate(arguments[1])
    finally:
        _ACTIVE_CHECK_ABORT_SCOPES.reset(token)


def abort_protect_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 1:
        raise WolframEvaluationError("AbortProtect expects exactly one argument.")
    scope = _AbortProtectScope()
    scopes = _ACTIVE_ABORT_PROTECT_SCOPES.get()
    token = _ACTIVE_ABORT_PROTECT_SCOPES.set(scopes + (scope,))
    try:
        try:
            result = evaluate(arguments[0])
        except TungstenAbortRequested:
            scope.pending_abort = True
            result = symbol("Null")
    finally:
        _ACTIVE_ABORT_PROTECT_SCOPES.reset(token)
    if scope.pending_abort:
        raise TungstenAbortRequested()
    return result


def pause_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 1:
        raise WolframEvaluationError("Pause expects exactly one argument.")
    seconds = _seconds_value(evaluate(arguments[0]), "Pause")
    if not math.isfinite(seconds) or seconds < 0:
        raise WolframEvaluationError("Pause expects a non-negative finite number of seconds.")
    end_time = time.monotonic() + seconds
    while True:
        remaining_constraint = _time_constraint_remaining_seconds()
        if remaining_constraint is not None and remaining_constraint <= 0:
            raise _TungstenTimeConstraintSignal()
        remaining_pause = end_time - time.monotonic()
        if remaining_pause <= 0:
            return symbol("Null")
        sleep_for = remaining_pause
        if remaining_constraint is not None:
            sleep_for = min(sleep_for, max(remaining_constraint, 0.0))
        time.sleep(min(sleep_for, 0.05))


def absolute_timing_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 1:
        raise WolframEvaluationError("AbsoluteTiming expects exactly one argument.")
    start = time.perf_counter()
    result = evaluate(arguments[0])
    elapsed = time.perf_counter() - start
    return _evaluated_list_expr(_real_from_float(elapsed, "AbsoluteTiming"), result)


def time_constrained_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {2, 3}:
        raise WolframEvaluationError("TimeConstrained expects two or three arguments.")
    seconds = _seconds_value(evaluate(arguments[1]), "TimeConstrained", allow_infinity=True)
    if seconds < 0:
        seconds = 0.0
    token = _push_time_constraint(seconds)
    timed_out = False
    try:
        try:
            result = evaluate(arguments[0])
            if not math.isinf(seconds):
                _check_time_constraints()
            return result
        except _TungstenTimeConstraintSignal:
            timed_out = True
    finally:
        _ACTIVE_TIME_CONSTRAINTS.reset(token)
    if timed_out and len(arguments) == 3:
        return evaluate(arguments[2])
    return symbol("$Aborted")


def time_remaining_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) != 0:
        raise WolframEvaluationError("TimeRemaining expects no arguments.")
    remaining = _time_constraint_remaining_seconds()
    if remaining is None:
        return symbol("Infinity")
    return _real_from_float(max(0.0, remaining), "TimeRemaining")


def _normalize_sow_tags(arguments: Sequence[Expr]) -> tuple[Expr, tuple[Expr, ...]]:
    if len(arguments) == 1:
        return evaluate(arguments[0]), (symbol("None"),)
    if len(arguments) == 2:
        value = evaluate(arguments[0])
        tag_expr = evaluate(arguments[1])
        if isinstance(tag_expr, Call) and tag_expr.has_head("List"):
            return value, tag_expr.arguments
        return value, (tag_expr,)
    raise WolframEvaluationError("Sow expects one or two arguments.")


def _reap_pattern_matches(scope: _ReapScope, tag: Expr) -> list[int]:
    return [
        index
        for index, pattern in enumerate(scope.patterns)
        if _match_pattern(tag, pattern) is not None
    ]


def sow_expr(arguments: Sequence[Expr]) -> Expr:
    value, tags = _normalize_sow_tags(arguments)
    for tag in tags:
        scopes = _ACTIVE_REAP_SCOPES.get()
        for scope in reversed(scopes):
            matching_indices = _reap_pattern_matches(scope, tag)
            if not matching_indices:
                continue
            for index in matching_indices:
                bucket = scope.buckets[index]
                bucket.setdefault(tag, []).append(value)
            break
    return value


def _reap_scope_result(scope: _ReapScope, handler: Expr | None) -> Expr:
    pattern_results: list[Expr] = []
    for bucket in scope.buckets:
        groups: list[Expr] = []
        for tag, values in bucket.items():
            values_expr = _evaluated_list_expr(*values)
            if handler is None:
                groups.append(values_expr)
            else:
                groups.append(_apply_callable(handler, (tag, values_expr)))
        if scope.pattern_list_mode:
            pattern_results.append(_evaluated_list_expr(*groups))
        else:
            pattern_results.extend(groups)
    return _evaluated_list_expr(*pattern_results)


def reap_expr(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Reap expects one, two, or three arguments.")
    pattern_spec = evaluate(arguments[1]) if len(arguments) >= 2 else _all_pattern_expr()
    pattern_list_mode = isinstance(pattern_spec, Call) and pattern_spec.has_head("List")
    patterns = pattern_spec.arguments if pattern_list_mode else (pattern_spec,)
    handler = evaluate(arguments[2]) if len(arguments) == 3 else None
    scope = _ReapScope(
        patterns=tuple(patterns),
        pattern_list_mode=pattern_list_mode,
        buckets=[{} for _ in patterns],
    )
    scopes = _ACTIVE_REAP_SCOPES.get()
    token = _ACTIVE_REAP_SCOPES.set(scopes + (scope,))
    try:
        result = evaluate(arguments[0])
    finally:
        _ACTIVE_REAP_SCOPES.reset(token)
    return _evaluated_list_expr(result, _reap_scope_result(scope, handler))


def unique_expr(spec: Expr | None = None) -> Expr:
    if spec is None:
        return _SYMBOL_REGISTRY.unique_symbol()
    if isinstance(spec, Call) and spec.has_head("List"):
        return _evaluated_list_expr(*(_SYMBOL_REGISTRY.unique_symbol(item) for item in spec.arguments))
    return _SYMBOL_REGISTRY.unique_symbol(spec)


def value_q_expr(expr: Expr) -> Symbol:
    if isinstance(expr, Symbol):
        record = _SYMBOL_REGISTRY.record_for_symbol(expr)
        if record.full_name in {"System`$Context", "System`$ContextPath"}:
            return _bool_symbol(True)
        return _bool_symbol(record.own_value is not None)
    try:
        return _bool_symbol(evaluate(expr) != expr)
    except WolframEvaluationError:
        return _bool_symbol(False)


def _normalize_import_export_format_name(value: Expr, function_name: str) -> str:
    if not isinstance(value, String):
        raise WolframEvaluationError(f"{function_name} expects the format name to be a string.")
    normalized = _IMPORT_EXPORT_FORMAT_NAMES.get(value.value.strip().lower())
    if normalized is None:
        supported = ", ".join(f'"{name}"' for name in sorted(set(_IMPORT_EXPORT_FORMAT_NAMES.values())))
        raise WolframEvaluationError(f"{function_name} currently supports only {supported}.")
    return normalized


def _normalize_import_export_format_spec(value: Expr, function_name: str) -> _ImportExportFormatSpec:
    if isinstance(value, String):
        return _ImportExportFormatSpec(_normalize_import_export_format_name(value, function_name))
    if isinstance(value, Call) and value.has_head("List") and len(value.arguments) == 2:
        outer_name = _normalize_import_export_format_name(value.arguments[0], function_name)
        if outer_name not in _COMPRESSED_FORMAT_NAMES:
            raise WolframEvaluationError(
                f"{function_name} currently supports list format specifications only for compression wrappers such as {{\"GZIP\", \"Text\"}}."
            )
        return _ImportExportFormatSpec(
            outer_name,
            _normalize_import_export_format_spec(value.arguments[1], function_name),
        )
    raise WolframEvaluationError(
        f"{function_name} expects a format string or a compression-wrapper format specification."
    )


def _raw_bytes_to_string(data: bytes) -> String:
    return string("".join(chr(byte) for byte in data))


def _raw_string_to_bytes(value: Expr | str, function_name: str) -> bytes:
    text = value.value if isinstance(value, String) else value
    byte_values: list[int] = []
    for character in text:
        code_point = ord(character)
        if code_point < 0 or code_point > 255:
            raise WolframEvaluationError(
                f"{function_name} raw string data currently expects characters with code points between 0 and 255."
            )
        byte_values.append(code_point)
    return bytes(byte_values)


def _expr_to_byte_values(expr: Expr, function_name: str) -> tuple[int, ...]:
    if isinstance(expr, ByteArrayExpr):
        return expr.values
    if isinstance(expr, Call) and expr.has_head("List"):
        values = _integer_values(expr.arguments)
        if values is None:
            raise WolframEvaluationError(f"{function_name} expects a byte list or a ByteArray.")
        return byte_array_expr(values).values
    raise WolframEvaluationError(f"{function_name} expects a byte list or a ByteArray.")


def _real_from_float(value: float, function_name: str) -> Real:
    if not math.isfinite(value):
        raise WolframEvaluationError(f"{function_name} does not currently support infinite or indeterminate real values.")
    text = format(value, ".15g")
    if "E" in text:
        text = text.replace("E", "e")
    if "e" not in text and "." not in text:
        text += "."
    return real(text)


def _json_to_expr(data: object, *, raw_json: bool) -> Expr:
    if isinstance(data, _JsonObjectPairs):
        entries = [
            _AssociationEntry(rule_head="Rule", key=string(key), value=_json_to_expr(value, raw_json=raw_json))
            for key, value in data.pairs
        ]
        if raw_json:
            return _association_expr(entries)
        return list_expr(*(entry.to_expr() for entry in entries))
    if data is None:
        return symbol("Null")
    if isinstance(data, bool):
        return _bool_symbol(data)
    if isinstance(data, int):
        return integer(data)
    if isinstance(data, float):
        return _real_from_float(data, "ImportString")
    if isinstance(data, str):
        return string(data)
    if isinstance(data, list):
        return list_expr(*(_json_to_expr(item, raw_json=raw_json) for item in data))
    raise WolframEvaluationError("Unsupported JSON value encountered during import.")


def _rule_sequence_entries(expr: Expr) -> tuple[_AssociationEntry, ...] | None:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return None
    entries: list[_AssociationEntry] = []
    for item in expr.arguments:
        entry = _rule_entry(item)
        if entry is None:
            return None
        entries.append(entry)
    return tuple(entries)


def _expr_to_json_value(expr: Expr, function_name: str, *, raw_json: bool) -> object:
    if isinstance(expr, String):
        return expr.value
    if isinstance(expr, Integer):
        return expr.value
    if isinstance(expr, Real):
        try:
            value = float(expr.text.replace("*^", "e"))
        except ValueError as exc:
            raise WolframEvaluationError(f"{function_name} could not convert {expr.to_input_form()} to a JSON number.") from exc
        if not math.isfinite(value):
            raise WolframEvaluationError(f"{function_name} does not currently support infinite or indeterminate JSON numbers.")
        return value
    if isinstance(expr, Symbol):
        if expr.name == "True":
            return True
        if expr.name == "False":
            return False
        if expr.name == "Null":
            return None
        raise WolframEvaluationError(f"{function_name} does not currently support exporting the symbol {expr.name} to JSON.")

    if isinstance(expr, Call) and expr.has_head("List"):
        entries = _rule_sequence_entries(expr)
        if entries is not None:
            if raw_json:
                raise WolframEvaluationError(f"{function_name} RawJSON export expects associations for JSON objects, not lists of rules.")
            result: dict[str, object] = {}
            for entry in entries:
                if not isinstance(entry.key, String):
                    raise WolframEvaluationError(f"{function_name} JSON object keys must be strings.")
                result[entry.key.value] = _expr_to_json_value(entry.value, function_name, raw_json=raw_json)
            return result
        return [_expr_to_json_value(item, function_name, raw_json=raw_json) for item in expr.arguments]

    association_entries = _association_entries(expr)
    if association_entries is not None:
        result: dict[str, object] = {}
        for entry in association_entries:
            if not isinstance(entry.key, String):
                raise WolframEvaluationError(f"{function_name} JSON object keys must be strings.")
            result[entry.key.value] = _expr_to_json_value(entry.value, function_name, raw_json=raw_json)
        return result

    raise WolframEvaluationError(f"{function_name} does not currently support exporting {expr.to_input_form()} as JSON.")


def _import_json_string(data: str, function_name: str, *, raw_json: bool) -> Expr:
    try:
        parsed = json.loads(data, object_pairs_hook=lambda pairs: _JsonObjectPairs(tuple(pairs)))
    except json.JSONDecodeError as exc:
        raise WolframEvaluationError(f"{function_name} could not parse the JSON payload.") from exc
    return _json_to_expr(parsed, raw_json=raw_json)


def _export_json_string(expr: Expr, function_name: str, *, raw_json: bool) -> String:
    value = _expr_to_json_value(expr, function_name, raw_json=raw_json)
    return string(json.dumps(value, ensure_ascii=False, indent="\t", separators=(",", ":")))


def _parse_tabular_atom(text: str) -> Expr:
    stripped = text.strip()
    if stripped == "":
        return string("")
    if re.fullmatch(r"[+-]?\d+", stripped):
        return integer(int(stripped))
    if _TABULAR_REAL_TOKEN.fullmatch(stripped):
        normalized = stripped.replace("*^", "e").replace("D", "e").replace("d", "e")
        try:
            return _real_from_float(float(normalized), "ImportString")
        except ValueError:
            pass
    return string(text)


def _import_delimited_string(data: str, delimiter: str) -> Expr:
    rows: list[Expr] = []
    reader = csv.reader(io.StringIO(data), delimiter=delimiter)
    for row in reader:
        rows.append(list_expr(*(_parse_tabular_atom(field) for field in row)))
    return list_expr(*rows)


def _import_table_string(data: str) -> Expr:
    rows: list[Expr] = []
    for line in data.splitlines():
        if line.strip() == "":
            rows.append(list_expr())
            continue
        rows.append(list_expr(*(_parse_tabular_atom(field) for field in line.split())))
    return list_expr(*rows)


def _tabular_export_rows(expr: Expr, function_name: str) -> list[list[str]]:
    def render_field(field: Expr) -> str:
        if isinstance(field, String):
            return field.value
        return field.to_input_form()

    if isinstance(expr, Call) and expr.has_head("List"):
        if not expr.arguments:
            return []
        if all(not (isinstance(item, Call) and item.has_head("List")) for item in expr.arguments):
            return [[render_field(item)] for item in expr.arguments]

        rows: list[list[str]] = []
        for row in expr.arguments:
            if not isinstance(row, Call) or not row.has_head("List"):
                raise WolframEvaluationError(f"{function_name} expects either a flat list or a list of rows.")
            rows.append([render_field(item) for item in row.arguments])
        return rows

    return [[render_field(expr)]]


def _export_delimited_string(expr: Expr, delimiter: str, function_name: str) -> String:
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter=delimiter, lineterminator="\n")
    writer.writerows(_tabular_export_rows(expr, function_name))
    return string(output.getvalue())


def _export_table_string(expr: Expr, function_name: str) -> String:
    rows = _tabular_export_rows(expr, function_name)
    return string("\n".join("\t".join(row) for row in rows))


def export_string(expr: Expr, format_value: Expr) -> String:
    spec = _normalize_import_export_format_spec(format_value, "ExportString")
    if spec.inner is not None:
        return _raw_bytes_to_string(export_byte_array(expr, format_value).values)

    if spec.name == "Text":
        return expr if isinstance(expr, String) else string(expr.to_input_form())
    if spec.name == "String":
        return expr if isinstance(expr, String) else string(expr.to_input_form())
    if spec.name == "Byte":
        return _raw_bytes_to_string(bytes(_expr_to_byte_values(expr, "ExportString")))
    if spec.name == "JSON":
        return _export_json_string(expr, "ExportString", raw_json=False)
    if spec.name == "RawJSON":
        return _export_json_string(expr, "ExportString", raw_json=True)
    if spec.name == "CSV":
        return _export_delimited_string(expr, ",", "ExportString")
    if spec.name == "TSV":
        return _export_delimited_string(expr, "\t", "ExportString")
    if spec.name == "Table":
        return _export_table_string(expr, "ExportString")
    if spec.name == "WL":
        return string(expr.to_input_form())
    raise WolframEvaluationError(f"Unsupported ExportString format: {spec.name}.")


def import_string_expr(data: Expr, format_value: Expr) -> Expr:
    if not isinstance(data, String):
        raise WolframEvaluationError("ImportString expects the source data to be a string.")
    spec = _normalize_import_export_format_spec(format_value, "ImportString")
    if spec.inner is not None:
        compressed = _raw_string_to_bytes(data, "ImportString")
        return import_byte_array(byte_array_expr(compressed), format_value)

    if spec.name == "Text" or spec.name == "String":
        return data
    if spec.name == "Byte":
        return list_expr(*(integer(value) for value in _raw_string_to_bytes(data, "ImportString")))
    if spec.name == "JSON":
        return _import_json_string(data.value, "ImportString", raw_json=False)
    if spec.name == "RawJSON":
        return _import_json_string(data.value, "ImportString", raw_json=True)
    if spec.name == "CSV":
        return _import_delimited_string(data.value, ",")
    if spec.name == "TSV":
        return _import_delimited_string(data.value, "\t")
    if spec.name == "Table":
        return _import_table_string(data.value)
    if spec.name == "WL":
        return parse_input_form(data.value)
    raise WolframEvaluationError(f"Unsupported ImportString format: {spec.name}.")


def _compress_bytes(data: bytes, format_name: str) -> bytes:
    if format_name == "GZIP":
        return gzip.compress(data)
    if format_name == "BZIP2":
        return bz2.compress(data)
    raise WolframEvaluationError(f"Unsupported compression wrapper: {format_name}.")


def _decompress_bytes(data: bytes, format_name: str, function_name: str) -> bytes:
    try:
        if format_name == "GZIP":
            return gzip.decompress(data)
        if format_name == "BZIP2":
            return bz2.decompress(data)
    except OSError as exc:
        raise WolframEvaluationError(f"{function_name} could not decompress the {format_name} payload.") from exc
    raise WolframEvaluationError(f"Unsupported compression wrapper: {format_name}.")


def export_byte_array(expr: Expr, format_value: Expr) -> ByteArrayExpr:
    spec = _normalize_import_export_format_spec(format_value, "ExportByteArray")
    if spec.inner is not None:
        inner_bytes = export_byte_array(expr, spec.inner.to_expr()).values
        return byte_array_expr(_compress_bytes(bytes(inner_bytes), spec.name))

    if spec.name == "Byte":
        return byte_array_expr(_expr_to_byte_values(expr, "ExportByteArray"))
    if spec.name == "String":
        if isinstance(expr, String):
            return byte_array_expr(_raw_string_to_bytes(expr, "ExportByteArray"))
        return byte_array_expr(_raw_string_to_bytes(expr.to_input_form(), "ExportByteArray"))
    if spec.name in _UTF8_TEXTUAL_FORMAT_NAMES:
        return byte_array_expr(export_string(expr, format_value).value.encode("utf-8"))
    raise WolframEvaluationError(f"Unsupported ExportByteArray format: {spec.name}.")


def import_byte_array(data: Expr, format_value: Expr) -> Expr:
    byte_values = _require_byte_array(data, "ImportByteArray").values
    spec = _normalize_import_export_format_spec(format_value, "ImportByteArray")
    if spec.inner is not None:
        decompressed = _decompress_bytes(bytes(byte_values), spec.name, "ImportByteArray")
        return import_byte_array(byte_array_expr(decompressed), spec.inner.to_expr())

    if spec.name == "Byte":
        return list_expr(*(integer(value) for value in byte_values))
    if spec.name == "String":
        return _raw_bytes_to_string(bytes(byte_values))
    if spec.name in _UTF8_TEXTUAL_FORMAT_NAMES:
        return import_string_expr(string(_decode_bytes_to_string(bytes(byte_values), "utf-8")), format_value)
    raise WolframEvaluationError(f"Unsupported ImportByteArray format: {spec.name}.")


def _string_thread(
    expr: Expr,
    function_name: str,
    scalar_function: Callable[[String], Expr],
) -> Expr:
    if isinstance(expr, String):
        return scalar_function(expr)
    if isinstance(expr, Call) and expr.has_head("List"):
        return list_expr(*(_string_thread(item, function_name, scalar_function) for item in expr.arguments))
    raise WolframEvaluationError(f"{function_name} expects a string or a list of strings.")


def string_length(expr: Expr) -> Expr:
    return _string_thread(expr, "StringLength", lambda item: integer(len(item.value)))


def _validate_string_selectors(length_value: int, selectors: Sequence[int], function_name: str) -> list[int]:
    for selector in selectors:
        _resolve_index(length_value, selector)
    return list(selectors)


def _normalize_string_take_drop_selectors(text: str, spec: Expr | int, function_name: str) -> list[int]:
    count = len(text)

    if isinstance(spec, int):
        selectors = list(range(1, spec + 1)) if spec >= 0 else list(range(count + spec + 1, count + 1))
        return _validate_string_selectors(count, selectors, function_name)

    if isinstance(spec, Integer):
        return _normalize_string_take_drop_selectors(text, spec.value, function_name)

    if isinstance(spec, Symbol) and spec.name == "All":
        return list(range(1, count + 1))

    if isinstance(spec, Call) and spec.has_head("UpTo"):
        if len(spec.arguments) != 1 or not isinstance(spec.arguments[0], Integer):
            raise WolframEvaluationError(f"{function_name} currently supports only integer UpTo specifications.")
        limit = spec.arguments[0].value
        if limit >= 0:
            return list(range(1, min(count, limit) + 1))
        kept = min(count, -limit)
        return list(range(count - kept + 1, count + 1))

    if isinstance(spec, Call) and spec.has_head("Span"):
        return _validate_string_selectors(count, _expand_span_spec_from_count(count, spec), function_name)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1:
            item = spec.arguments[0]
            if isinstance(item, Integer):
                return _validate_string_selectors(count, [item.value], function_name)
            if isinstance(item, Symbol) and item.name == "All":
                return list(range(1, count + 1))
            if isinstance(item, Call) and item.has_head("UpTo"):
                return _normalize_string_take_drop_selectors(text, item, function_name)
            raise WolframEvaluationError(
                f"{function_name} single-element list specifications must contain an integer, All, or UpTo[n]."
            )
        if len(spec.arguments) in {2, 3}:
            return _validate_string_selectors(
                count,
                _expand_span_spec_from_count(count, Call(head_expr=Symbol("Span"), arguments=spec.arguments)),
                function_name,
            )
        raise WolframEvaluationError(f"{function_name} list specifications must contain one, two, or three items.")

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _string_take_or_drop_scalar(text: str, spec: Expr | int, *, drop: bool) -> String:
    function_name = "StringDrop" if drop else "StringTake"
    selectors = _normalize_string_take_drop_selectors(text, spec, function_name)
    if drop:
        removed = {_resolve_index(len(text), selector) for selector in selectors}
        return string("".join(character for index, character in enumerate(text) if index not in removed))
    return string("".join(text[_resolve_index(len(text), selector)] for selector in selectors))


def string_take(expr: Expr, spec: Expr | int) -> Expr:
    return _string_thread(expr, "StringTake", lambda item: _string_take_or_drop_scalar(item.value, spec, drop=False))


def string_drop(expr: Expr, spec: Expr | int) -> Expr:
    return _string_thread(expr, "StringDrop", lambda item: _string_take_or_drop_scalar(item.value, spec, drop=True))


def _flatten_string_join_items(expr: Expr) -> list[str]:
    if isinstance(expr, String):
        return [expr.value]
    if isinstance(expr, Call) and expr.has_head("List"):
        flattened: list[str] = []
        for item in expr.arguments:
            flattened.extend(_flatten_string_join_items(item))
        return flattened
    raise WolframEvaluationError("StringJoin expects strings or nested lists of strings.")


def string_join(*exprs: Expr) -> String:
    pieces: list[str] = []
    for expr in exprs:
        pieces.extend(_flatten_string_join_items(expr))
    return string("".join(pieces))


def _resolve_string_insert_index(length_value: int, position: int) -> int:
    if position > 0:
        resolved = position - 1
    elif position < 0:
        resolved = length_value + position + 1
    else:
        raise WolframEvaluationError("StringInsert positions must be nonzero integers.")

    if not 0 <= resolved <= length_value:
        raise WolframEvaluationError(f"StringInsert position {position} is out of range for length {length_value}.")
    return resolved


def _normalize_string_insert_positions(length_value: int, positions: Expr | int) -> list[int]:
    if isinstance(positions, int):
        return [_resolve_string_insert_index(length_value, positions)]

    if isinstance(positions, Integer):
        return [_resolve_string_insert_index(length_value, positions.value)]

    if isinstance(positions, Call) and positions.has_head("List"):
        normalized: list[int] = []
        for item in positions.arguments:
            if not isinstance(item, Integer):
                raise WolframEvaluationError("StringInsert position lists must contain only integers.")
            normalized.append(_resolve_string_insert_index(length_value, item.value))
        return normalized

    raise WolframEvaluationError("StringInsert expects an integer position or a list of integer positions.")


def _string_insert_scalar(text: str, insertion: str, positions: Expr | int) -> String:
    resolved_positions = _normalize_string_insert_positions(len(text), positions)
    grouped: dict[int, list[str]] = {}
    for resolved in resolved_positions:
        grouped.setdefault(resolved, []).append(insertion)

    pieces: list[str] = []
    for index in range(len(text) + 1):
        pieces.extend(grouped.get(index, ()))
        if index < len(text):
            pieces.append(text[index])
    return string("".join(pieces))


def string_insert(expr: Expr, insertion: Expr, positions: Expr | int) -> Expr:
    if not isinstance(insertion, String):
        raise WolframEvaluationError("StringInsert expects the inserted value to be a string.")
    return _string_thread(
        expr,
        "StringInsert",
        lambda item: _string_insert_scalar(item.value, insertion.value, positions),
    )


def string_reverse(expr: Expr) -> Expr:
    return _string_thread(expr, "StringReverse", lambda item: string(item.value[::-1]))


def to_upper_case(expr: Expr) -> Expr:
    return _string_thread(expr, "ToUpperCase", lambda item: string(item.value.upper()))


def to_lower_case(expr: Expr) -> Expr:
    return _string_thread(expr, "ToLowerCase", lambda item: string(item.value.lower()))


def capitalize_string(expr: Expr) -> Expr:
    def _capitalize(item: String) -> Expr:
        text = item.value
        if not text:
            return string(text)
        return string(text[0].upper() + text[1:])
    return _string_thread(expr, "Capitalize", _capitalize)


def string_repeat(expr: Expr, count_expr: Expr, target_length_expr: Expr | None = None) -> Expr:
    if not isinstance(count_expr, Integer) or count_expr.value < 0:
        raise WolframEvaluationError("StringRepeat expects a non-negative integer count.")
    count = count_expr.value
    target_length: int | None = None
    if target_length_expr is not None:
        if not isinstance(target_length_expr, Integer) or target_length_expr.value < 0:
            raise WolframEvaluationError(
                "StringRepeat expects a non-negative integer target length."
            )
        target_length = target_length_expr.value

    def _repeat(item: String) -> Expr:
        if not item.value:
            if target_length is not None and target_length > 0:
                raise WolframEvaluationError(
                    "StringRepeat cannot pad an empty string to a positive length."
                )
            return string("")
        if target_length is None:
            return string(item.value * count)
        repeats_needed = (target_length + len(item.value) - 1) // len(item.value)
        repeats = max(count, repeats_needed)
        return string((item.value * repeats)[:target_length])

    return _string_thread(expr, "StringRepeat", _repeat)


def _pad_string(text: str, target_length: int, padding: str, *, on_left: bool) -> str:
    if not padding:
        raise WolframEvaluationError("String padding character must be a non-empty string.")
    if len(text) >= target_length:
        return text[len(text) - target_length :] if on_left else text[:target_length]
    needed = target_length - len(text)
    repeats = (needed + len(padding) - 1) // len(padding)
    pad_block = (padding * repeats)[:needed]
    return pad_block + text if on_left else text + pad_block


def string_pad_left(expr: Expr, target_length_expr: Expr, padding_expr: Expr | None = None) -> Expr:
    if not isinstance(target_length_expr, Integer) or target_length_expr.value < 0:
        raise WolframEvaluationError("StringPadLeft expects a non-negative integer target length.")
    target_length = target_length_expr.value
    padding_text = " "
    if padding_expr is not None:
        if not isinstance(padding_expr, String):
            raise WolframEvaluationError("StringPadLeft currently expects a string padding value.")
        padding_text = padding_expr.value

    def _pad(item: String) -> Expr:
        return string(_pad_string(item.value, target_length, padding_text, on_left=True))

    return _string_thread(expr, "StringPadLeft", _pad)


def string_pad_right(expr: Expr, target_length_expr: Expr, padding_expr: Expr | None = None) -> Expr:
    if not isinstance(target_length_expr, Integer) or target_length_expr.value < 0:
        raise WolframEvaluationError("StringPadRight expects a non-negative integer target length.")
    target_length = target_length_expr.value
    padding_text = " "
    if padding_expr is not None:
        if not isinstance(padding_expr, String):
            raise WolframEvaluationError("StringPadRight currently expects a string padding value.")
        padding_text = padding_expr.value

    def _pad(item: String) -> Expr:
        return string(_pad_string(item.value, target_length, padding_text, on_left=False))

    return _string_thread(expr, "StringPadRight", _pad)


def string_count(expr: Expr, pattern_expr: Expr) -> Expr:
    """Count non-overlapping matches of a literal-string pattern.

    Tungsten supports literal-string and ``List`` of literal-string patterns
    in this pass. Richer string-pattern matching (regex, character classes)
    can come later if needed; ``StringPosition`` already covers the more
    elaborate pattern surface.
    """
    if isinstance(pattern_expr, Call) and pattern_expr.has_head("List"):
        sub_results = [string_count(expr, pattern) for pattern in pattern_expr.arguments]
        if all(isinstance(result, Integer) for result in sub_results):
            return integer(sum(result.value for result in sub_results))
        return list_expr(*sub_results)

    if not isinstance(pattern_expr, String):
        raise WolframEvaluationError(
            "StringCount currently expects literal-string patterns."
        )

    needle = pattern_expr.value

    def _count(item: String) -> Expr:
        if not needle:
            return integer(0)
        return integer(item.value.count(needle))

    return _string_thread(expr, "StringCount", _count)


def string_split(expr: Expr, separator_expr: Expr | None = None) -> Expr:
    """StringSplit[s] / StringSplit[s, sep] / StringSplit[s, {seps...}].

    ``StringSplit[s]`` splits on whitespace runs (Wolfram's default). With
    explicit separators, Tungsten supports literal strings and lists of
    literal strings. Empty results are dropped, matching Wolfram's
    practical behavior.
    """

    def _split_one(item: String) -> Expr:
        if separator_expr is None:
            tokens = item.value.split()
            return list_expr(*(string(token) for token in tokens))
        separators = _string_split_separators(separator_expr)
        text = item.value
        # Split on the union of separators by repeatedly finding the
        # earliest occurrence of any separator.
        pieces: list[str] = []
        cursor = 0
        while cursor <= len(text):
            best_index: int | None = None
            best_separator: str | None = None
            for separator in separators:
                if not separator:
                    continue
                found = text.find(separator, cursor)
                if found != -1 and (best_index is None or found < best_index or (
                    found == best_index and best_separator is not None and len(separator) > len(best_separator)
                )):
                    best_index = found
                    best_separator = separator
            if best_index is None or best_separator is None:
                pieces.append(text[cursor:])
                break
            pieces.append(text[cursor:best_index])
            cursor = best_index + len(best_separator)
            if cursor > len(text):
                break
            if cursor == len(text):
                pieces.append("")
                break
        return list_expr(*(string(piece) for piece in pieces if piece != ""))

    return _string_thread(expr, "StringSplit", _split_one)


def _string_split_separators(separator_expr: Expr) -> list[str]:
    if isinstance(separator_expr, String):
        return [separator_expr.value]
    if isinstance(separator_expr, Call) and separator_expr.has_head("List"):
        result: list[str] = []
        for argument in separator_expr.arguments:
            if not isinstance(argument, String):
                raise WolframEvaluationError(
                    "StringSplit currently expects literal-string separators."
                )
            result.append(argument.value)
        return result
    raise WolframEvaluationError(
        "StringSplit currently expects a literal-string separator or a list of them."
    )


def string_riffle(expr: Expr, separator: Expr | None = None) -> Expr:
    """StringRiffle[list] / StringRiffle[list, sep] / StringRiffle[list, {l, sep, r}].

    Joins explicit strings using ``sep`` (default `" "`). The triple form
    wraps the result with the supplied left and right delimiters and uses
    the middle string as the separator between elements. Tungsten unpacks
    nested lists by joining each row with ``sep`` and then joining the
    rows with `"\n"`, matching Wolfram's two-level case.
    """
    if not isinstance(expr, Call) or not expr.has_head("List"):
        raise WolframEvaluationError("StringRiffle expects a List as the first argument.")

    separator_text = " "
    left_text = ""
    right_text = ""
    if separator is not None:
        if isinstance(separator, String):
            separator_text = separator.value
        elif isinstance(separator, Call) and separator.has_head("List") and len(separator.arguments) == 3 \
                and all(isinstance(piece, String) for piece in separator.arguments):
            left_text = separator.arguments[0].value  # type: ignore[union-attr]
            separator_text = separator.arguments[1].value  # type: ignore[union-attr]
            right_text = separator.arguments[2].value  # type: ignore[union-attr]
        else:
            raise WolframEvaluationError(
                "StringRiffle currently expects a string separator or a "
                "{left, sep, right} triple of strings."
            )

    def _to_text(item: Expr) -> str:
        if isinstance(item, String):
            return item.value
        if isinstance(item, Call) and item.has_head("List") and all(isinstance(piece, String) for piece in item.arguments):
            return separator_text.join(piece.value for piece in item.arguments)  # type: ignore[union-attr]
        if isinstance(item, Integer):
            return str(item.value)
        raise WolframEvaluationError(
            "StringRiffle expects items convertible to strings; non-string "
            "items beyond integers are not yet supported."
        )

    body = separator_text.join(_to_text(item) for item in expr.arguments)
    return string(left_text + body + right_text)


def string_trim(expr: Expr, pattern_expr: Expr | None = None) -> Expr:
    if pattern_expr is None:
        return _string_thread(expr, "StringTrim", lambda item: string(item.value.strip()))
    if not isinstance(pattern_expr, String):
        raise WolframEvaluationError(
            "StringTrim currently expects a literal-string trim pattern."
        )
    pattern_text = pattern_expr.value

    def _trim(item: String) -> Expr:
        text = item.value
        while text.startswith(pattern_text):
            text = text[len(pattern_text) :]
        while text.endswith(pattern_text):
            text = text[: -len(pattern_text)]
        return string(text)

    return _string_thread(expr, "StringTrim", _trim)


@dataclass
class _StringPatternState:
    end: int
    bindings: dict[str, Expr]


@dataclass(frozen=True)
class _StringPatternSpec:
    pattern: Expr
    template: Expr | None
    delayed: bool


@dataclass
class _StringFoundMatch:
    start: int
    end: int
    bindings: dict[str, Expr]
    spec: _StringPatternSpec


@dataclass(frozen=True)
class _ImportExportFormatSpec:
    name: str
    inner: _ImportExportFormatSpec | None = None

    def to_expr(self) -> Expr:
        if self.inner is None:
            return string(self.name)
        return list_expr(string(self.name), self.inner.to_expr())


@dataclass(frozen=True)
class _JsonObjectPairs:
    pairs: tuple[tuple[str, object], ...]


_STRING_CHARACTER_CLASS_SYMBOLS = {
    "DigitCharacter",
    "HexadecimalCharacter",
    "LetterCharacter",
    "PunctuationCharacter",
    "WhitespaceCharacter",
    "WordCharacter",
}

_STRING_ZERO_WIDTH_SYMBOLS = {
    "EndOfLine",
    "StartOfString",
    "EndOfString",
    "StartOfLine",
    "WordBoundary",
}

_UNSUPPORTED_STRING_PATTERN_HEADS = {
    "Optional",
    "OptionsPattern",
}

_NUMBER_STRING_REGEX = re.compile(
    r"[+-]?(?:(?:\d+(?:\.\d*)?|\.\d+)(?:(?:[eE]|\*\^)[+-]?\d+)?)"
)

_DATE_PATTERN_DEFAULT_SEPARATOR_REGEX = r"[/\-:.]"
_MONTH_NAME_REGEX = (
    r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"
)
_DAY_NAME_REGEX = (
    r"(?:Mon(?:day)?|Tue(?:sday)?|Wed(?:nesday)?|Thu(?:rsday)?|Fri(?:day)?|"
    r"Sat(?:urday)?|Sun(?:day)?)"
)

_IMPORT_EXPORT_FORMAT_NAMES = {
    "byte": "Byte",
    "bzip2": "BZIP2",
    "csv": "CSV",
    "gzip": "GZIP",
    "json": "JSON",
    "rawjson": "RawJSON",
    "string": "String",
    "table": "Table",
    "text": "Text",
    "tsv": "TSV",
    "wl": "WL",
}

_COMPRESSED_FORMAT_NAMES = {"GZIP", "BZIP2"}
_UTF8_TEXTUAL_FORMAT_NAMES = {"CSV", "JSON", "RawJSON", "Table", "Text", "TSV", "WL"}
_TABULAR_REAL_TOKEN = re.compile(
    r"^[+-]?(?:\d+\.\d*|\.\d+|\d+(?:[eEdD][+-]?\d+)|\d+\*\^[+-]?\d+|\d+\.\d*(?:[eEdD][+-]?\d+)?|\.\d+(?:[eEdD][+-]?\d+)?)$"
)


def _unsupported_string_pattern(expr: Expr) -> WolframEvaluationError:
    return WolframEvaluationError(
        f"Unsupported Wolfram string-pattern form in the current Tungsten subset: {expr.to_input_form()}."
    )


def _normalize_string_pattern_element(pattern: Expr) -> Expr:
    if isinstance(pattern, Symbol) and pattern.name == "Whitespace":
        return call("Repeated", symbol("WhitespaceCharacter"))
    return pattern


def _flatten_string_expression_parts(pattern: Expr) -> list[Expr]:
    normalized = _normalize_string_pattern_element(pattern)
    if isinstance(normalized, Call) and normalized.has_head("StringExpression"):
        flattened: list[Expr] = []
        for item in normalized.arguments:
            flattened.extend(_flatten_string_expression_parts(item))
        return flattened
    return [normalized]


def _is_single_character_string_class_pattern(expr: Expr) -> bool:
    normalized = _normalize_string_pattern_element(expr)
    if isinstance(normalized, String):
        return len(normalized.value) == 1
    if isinstance(normalized, Symbol):
        return normalized.name in _STRING_CHARACTER_CLASS_SYMBOLS
    if isinstance(normalized, Call) and isinstance(normalized.head_expr, Symbol):
        head_name = normalized.head_expr.name
        if head_name == "List":
            return all(_is_single_character_string_class_pattern(argument) for argument in normalized.arguments)
        if head_name == "Blank":
            return len(normalized.arguments) == 0
        if head_name == "CharacterRange":
            return len(normalized.arguments) == 2
        if head_name == "HoldPattern":
            return len(normalized.arguments) == 1 and _is_single_character_string_class_pattern(normalized.arguments[0])
        if head_name in {"Longest", "Shortest"}:
            return bool(normalized.arguments) and _is_single_character_string_class_pattern(normalized.arguments[0])
        if head_name == "PatternTest":
            return len(normalized.arguments) == 2 and _is_single_character_string_class_pattern(normalized.arguments[0])
        if head_name == "Pattern":
            return len(normalized.arguments) == 2 and _is_single_character_string_class_pattern(normalized.arguments[1])
        if head_name == "Condition":
            return len(normalized.arguments) == 2 and _is_single_character_string_class_pattern(normalized.arguments[0])
        if head_name == "Alternatives":
            return bool(normalized.arguments) and all(
                _is_single_character_string_class_pattern(argument)
                for argument in normalized.arguments
            )
        if head_name == "Except":
            return len(normalized.arguments) == 1 and _is_single_character_string_class_pattern(normalized.arguments[0])
    return False


def _is_unbounded_string_pattern(expr: Expr) -> bool:
    normalized = _normalize_string_pattern_element(expr)
    return (
        isinstance(normalized, Call)
        and isinstance(normalized.head_expr, Symbol)
        and normalized.head_expr.name in {"BlankSequence", "BlankNullSequence", "Repeated", "RepeatedNull"}
    )


def _is_word_character(character: str) -> bool:
    return character.isalnum() or character == "_"


def _is_word_boundary(text: str, position: int) -> bool:
    previous_is_word = position > 0 and _is_word_character(text[position - 1])
    next_is_word = position < len(text) and _is_word_character(text[position])
    return previous_is_word != next_is_word


def _is_start_of_line(text: str, position: int) -> bool:
    return position == 0 or (position > 0 and text[position - 1] == "\n")


def _is_end_of_line(text: str, position: int) -> bool:
    return position == len(text) or (position < len(text) and text[position] in {"\n", "\r"})


def _character_range_bounds(pattern: Call) -> tuple[str, str]:
    if len(pattern.arguments) != 2:
        raise WolframEvaluationError("CharacterRange expects exactly two arguments in string patterns.")
    start, end = pattern.arguments
    if not isinstance(start, String) or not isinstance(end, String) or len(start.value) != 1 or len(end.value) != 1:
        raise WolframEvaluationError("CharacterRange currently expects one-character string bounds.")
    return start.value, end.value


def _string_character_matches_symbol(name: str, character: str) -> bool:
    if name == "DigitCharacter":
        return character.isdigit()
    if name == "HexadecimalCharacter":
        return character in "0123456789abcdefABCDEF"
    if name == "LetterCharacter":
        return character.isalpha()
    if name == "PunctuationCharacter":
        return unicodedata.category(character).startswith("P")
    if name == "WhitespaceCharacter":
        return character.isspace()
    if name == "WordCharacter":
        return _is_word_character(character)
    return False


def _string_predicate_succeeds(criterion: Expr, value: String) -> bool:
    if isinstance(criterion, Symbol):
        if criterion.name == "DigitQ":
            return bool(value.value) and all(character.isdigit() for character in value.value)
        if criterion.name == "LetterQ":
            return bool(value.value) and all(character.isalpha() for character in value.value)
    return _predicate_succeeds(criterion, value)


def _string_pattern_test_succeeds(criterion: Expr, text: str, start: int, end: int) -> bool:
    return all(_string_predicate_succeeds(criterion, string(character)) for character in text[start:end])


def _date_pattern_element_regex(element: str) -> str:
    if element == "Year":
        return r"(?:\d{1,4})"
    if element == "Quarter":
        return r"(?:[1-4])"
    if element == "Month":
        return r"(?:(?:1[0-2])|(?:0?[1-9]))"
    if element == "MonthName":
        return _MONTH_NAME_REGEX
    if element == "Day":
        return r"(?:(?:[12]\d)|(?:3[01])|(?:0?[1-9]))"
    if element == "DayName":
        return _DAY_NAME_REGEX
    if element == "Hour":
        return r"(?:(?:2[0-3])|(?:[01]?\d))"
    if element == "AMPM":
        return r"(?:AM|PM|A\.M\.|P\.M\.)"
    if element in {"Minute", "Second"}:
        return r"(?:[0-5]?\d)"
    raise WolframEvaluationError(f'DatePattern does not support date element "{element}".')


def _string_pattern_to_regex_fragment(pattern: Expr) -> str | None:
    normalized = _normalize_string_pattern_element(pattern)
    if isinstance(normalized, String):
        return re.escape(normalized.value)
    if isinstance(normalized, Symbol):
        if normalized.name == "DigitCharacter":
            return r"\d"
        if normalized.name == "HexadecimalCharacter":
            return r"[0-9A-Fa-f]"
        if normalized.name == "LetterCharacter":
            return r"[^\W\d_]"
        if normalized.name == "PunctuationCharacter":
            return r"[^\w\s]"
        if normalized.name == "WhitespaceCharacter":
            return r"\s"
        if normalized.name == "WordCharacter":
            return r"\w"
        if normalized.name == "Whitespace":
            return r"\s+"
        return None
    if not isinstance(normalized, Call) or not isinstance(normalized.head_expr, Symbol):
        return None

    head_name = normalized.head_expr.name
    if head_name == "HoldPattern" and len(normalized.arguments) == 1:
        return _string_pattern_to_regex_fragment(normalized.arguments[0])
    if head_name == "StringExpression":
        fragments = [_string_pattern_to_regex_fragment(item) for item in _flatten_string_expression_parts(normalized)]
        if any(fragment is None for fragment in fragments):
            return None
        return "".join(fragment for fragment in fragments if fragment is not None)
    if head_name == "Alternatives":
        fragments = [_string_pattern_to_regex_fragment(argument) for argument in normalized.arguments]
        if any(fragment is None for fragment in fragments):
            return None
        return "(?:" + "|".join(fragment for fragment in fragments if fragment is not None) + ")"
    if head_name == "RegularExpression" and len(normalized.arguments) == 1 and isinstance(normalized.arguments[0], String):
        return "(?:" + normalized.arguments[0].value + ")"
    if head_name == "CharacterRange":
        start_char, end_char = _character_range_bounds(normalized)
        return "[" + re.escape(start_char) + "-" + re.escape(end_char) + "]"
    if head_name == "Blank" and len(normalized.arguments) == 0:
        return r"."
    if head_name == "BlankSequence" and len(normalized.arguments) == 0:
        return r".+"
    if head_name == "BlankNullSequence" and len(normalized.arguments) == 0:
        return r".*"
    if head_name in {"Repeated", "RepeatedNull"} and len(normalized.arguments) in {1, 2}:
        inner = _string_pattern_to_regex_fragment(normalized.arguments[0])
        if inner is None:
            return None
        count_min, count_max = _repetition_count_bounds(normalized)
        if count_max >= _LEVEL_INFINITY:
            quantifier = "+" if head_name == "Repeated" else "*"
        elif count_min == count_max:
            quantifier = "{" + str(count_min) + "}"
        else:
            quantifier = "{" + str(count_min) + "," + str(count_max) + "}"
        return "(?:" + inner + ")" + quantifier
    return None


def _date_pattern_regex(pattern: Call) -> re.Pattern[str]:
    if len(pattern.arguments) not in {1, 2}:
        raise WolframEvaluationError("DatePattern expects a date-element list and an optional separator.")

    elements_expr = pattern.arguments[0]
    if not isinstance(elements_expr, Call) or not elements_expr.has_head("List") or not elements_expr.arguments:
        raise WolframEvaluationError("DatePattern expects a non-empty list of date-element strings.")
    elements: list[str] = []
    for item in elements_expr.arguments:
        if not isinstance(item, String):
            raise WolframEvaluationError("DatePattern date elements must be strings.")
        elements.append(item.value)

    if len(pattern.arguments) == 1:
        separator = _DATE_PATTERN_DEFAULT_SEPARATOR_REGEX
    else:
        separator = _string_pattern_to_regex_fragment(pattern.arguments[1])
        if separator is None:
            raise WolframEvaluationError("DatePattern separator must be a supported string-pattern expression.")

    parts: list[str] = []
    for index, element in enumerate(elements):
        if index:
            parts.append(separator)
        parts.append(_date_pattern_element_regex(element))
    return re.compile("".join(parts), re.IGNORECASE)


def _match_single_character_string_pattern(
    character: str,
    pattern: Expr,
    bindings: dict[str, Expr],
) -> list[dict[str, Expr]]:
    current = dict(bindings)
    normalized = _normalize_string_pattern_element(pattern)

    if isinstance(normalized, String):
        return [current] if normalized.value == character else []

    if isinstance(normalized, Symbol):
        if normalized.name in _STRING_CHARACTER_CLASS_SYMBOLS:
            return [current] if _string_character_matches_symbol(normalized.name, character) else []
        if normalized.name in _STRING_ZERO_WIDTH_SYMBOLS or normalized.name == "Whitespace":
            raise _unsupported_string_pattern(normalized)
        raise _unsupported_string_pattern(normalized)

    if not isinstance(normalized, Call) or not isinstance(normalized.head_expr, Symbol):
        raise _unsupported_string_pattern(normalized)

    head_name = normalized.head_expr.name
    if head_name in _UNSUPPORTED_STRING_PATTERN_HEADS:
        raise _unsupported_string_pattern(normalized)

    if head_name in {"Longest", "Shortest"}:
        if len(normalized.arguments) not in {1, 2}:
            raise WolframEvaluationError(f"{head_name} expects one or two arguments.")
        return _match_single_character_string_pattern(character, normalized.arguments[0], current)

    if head_name == "HoldPattern":
        if len(normalized.arguments) != 1:
            raise WolframEvaluationError("HoldPattern expects exactly one argument.")
        return _match_single_character_string_pattern(character, normalized.arguments[0], current)

    if head_name == "List":
        matches: list[dict[str, Expr]] = []
        for branch in normalized.arguments:
            matches.extend(_match_single_character_string_pattern(character, branch, current))
        return matches

    if head_name == "Alternatives":
        matches: list[dict[str, Expr]] = []
        for branch in normalized.arguments:
            matches.extend(_match_single_character_string_pattern(character, branch, current))
        return matches

    if head_name == "Condition":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Condition expects exactly two arguments.")
        matches = _match_single_character_string_pattern(character, normalized.arguments[0], current)
        return [
            match
            for match in matches
            if _condition_test_succeeds(normalized.arguments[1], match)
        ]

    if head_name == "PatternTest":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("PatternTest expects exactly two arguments.")
        matches = _match_single_character_string_pattern(character, normalized.arguments[0], current)
        return [
            match
            for match in matches
            if _string_predicate_succeeds(normalized.arguments[1], string(character))
        ]

    if head_name == "Pattern":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Pattern expects exactly two arguments.")
        name_expr, inner_pattern = normalized.arguments
        if not isinstance(name_expr, Symbol):
            raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
        if _is_unbounded_string_pattern(inner_pattern):
            raise _unsupported_string_pattern(normalized)
        matches = _match_single_character_string_pattern(character, inner_pattern, current)
        bound_value = string(character)
        updated_matches: list[dict[str, Expr]] = []
        for match in matches:
            existing = match.get(name_expr.name)
            if existing is not None and existing != bound_value:
                continue
            updated = dict(match)
            updated[name_expr.name] = bound_value
            updated_matches.append(updated)
        return updated_matches

    if head_name == "Except":
        if len(normalized.arguments) not in {1, 2}:
            raise WolframEvaluationError("Except expects one or two arguments in string patterns.")
        disallowed_pattern = normalized.arguments[0]
        allowed_pattern = normalized.arguments[1] if len(normalized.arguments) == 2 else call("Blank")
        if not _is_single_character_string_class_pattern(disallowed_pattern):
            raise WolframEvaluationError("String-pattern Except expects a single-character disallowed pattern.")
        if not _is_single_character_string_class_pattern(allowed_pattern):
            raise WolframEvaluationError("String-pattern Except expects a single-character allowed pattern.")
        allowed = _match_single_character_string_pattern(character, allowed_pattern, current)
        if not allowed:
            return []
        results: list[dict[str, Expr]] = []
        for match in allowed:
            disallowed = _match_single_character_string_pattern(character, disallowed_pattern, match)
            if not disallowed:
                results.append(match)
        return results

    if head_name == "Blank":
        if len(normalized.arguments) != 0:
            raise _unsupported_string_pattern(normalized)
        return [current]

    if head_name == "CharacterRange":
        start_char, end_char = _character_range_bounds(normalized)
        return [current] if start_char <= character <= end_char else []

    raise _unsupported_string_pattern(normalized)


def _order_string_states(states: Iterable[_StringPatternState], *, prefer_longest: bool) -> list[_StringPatternState]:
    return sorted(states, key=lambda item: item.end, reverse=prefer_longest)


def _match_repeated_string_pattern(
    pattern: Call,
    text: str,
    start: int,
    bindings: dict[str, Expr],
    *,
    prefer_longest: bool,
) -> list[_StringPatternState]:
    head_name = pattern.head_expr.name
    assert head_name in {"Repeated", "RepeatedNull"}
    if len(pattern.arguments) not in {1, 2}:
        raise WolframEvaluationError(f"{head_name} expects one or two arguments in string patterns.")

    inner = pattern.arguments[0]
    count_min, count_max = _repetition_count_bounds(pattern)
    if count_min > count_max:
        return []

    results: list[_StringPatternState] = []

    def recurse(position: int, count: int, current: dict[str, Expr]) -> None:
        if count >= count_min:
            results.append(_StringPatternState(end=position, bindings=dict(current)))
        if count >= count_max:
            return
        for state in _match_string_pattern_states(inner, text, position, current, prefer_longest=prefer_longest):
            if state.end == position:
                # Repeating a zero-width string pattern would otherwise create
                # infinitely many equivalent matches.
                continue
            recurse(state.end, count + 1, state.bindings)

    recurse(start, 0, dict(bindings))
    return _order_string_states(results, prefer_longest=prefer_longest)


def _match_string_expression_parts(
    parts: Sequence[Expr],
    text: str,
    start: int,
    bindings: dict[str, Expr],
    *,
    prefer_longest: bool,
) -> list[_StringPatternState]:
    normalized_parts = [_normalize_string_pattern_element(part) for part in parts]
    states = [_StringPatternState(end=start, bindings=dict(bindings))]
    for item in normalized_parts:
        next_states: list[_StringPatternState] = []
        for state in states:
            next_states.extend(
                _match_string_pattern_states(
                    item,
                    text,
                    state.end,
                    state.bindings,
                    prefer_longest=prefer_longest,
                )
            )
        if not next_states:
            return []
        states = _order_string_states(next_states, prefer_longest=prefer_longest)
    return states


def _match_string_pattern_states(
    pattern: Expr,
    text: str,
    start: int,
    bindings: dict[str, Expr] | None = None,
    *,
    prefer_longest: bool = True,
) -> list[_StringPatternState]:
    current = {} if bindings is None else dict(bindings)
    normalized = _normalize_string_pattern_element(pattern)

    if isinstance(normalized, String):
        if text.startswith(normalized.value, start):
            return [_StringPatternState(end=start + len(normalized.value), bindings=current)]
        return []

    if isinstance(normalized, Symbol):
        if normalized.name == "Whitespace":
            return _match_string_pattern_states(
                call("Repeated", symbol("WhitespaceCharacter")),
                text,
                start,
                current,
                prefer_longest=prefer_longest,
            )
        if normalized.name == "StartOfString":
            return [_StringPatternState(end=start, bindings=current)] if start == 0 else []
        if normalized.name == "EndOfString":
            return [_StringPatternState(end=start, bindings=current)] if start == len(text) else []
        if normalized.name == "StartOfLine":
            return [_StringPatternState(end=start, bindings=current)] if _is_start_of_line(text, start) else []
        if normalized.name == "EndOfLine":
            return [_StringPatternState(end=start, bindings=current)] if _is_end_of_line(text, start) else []
        if normalized.name == "WordBoundary":
            return [_StringPatternState(end=start, bindings=current)] if _is_word_boundary(text, start) else []
        if normalized.name == "NumberString":
            match = _NUMBER_STRING_REGEX.match(text, start)
            return [_StringPatternState(end=match.end(), bindings=current)] if match is not None else []
        if normalized.name in _STRING_CHARACTER_CLASS_SYMBOLS:
            if start >= len(text):
                return []
            matches = _match_single_character_string_pattern(text[start], normalized, current)
            return [_StringPatternState(end=start + 1, bindings=match) for match in matches]
        raise _unsupported_string_pattern(normalized)

    if not isinstance(normalized, Call) or not isinstance(normalized.head_expr, Symbol):
        raise _unsupported_string_pattern(normalized)

    head_name = normalized.head_expr.name
    if head_name in _UNSUPPORTED_STRING_PATTERN_HEADS:
        raise _unsupported_string_pattern(normalized)

    if head_name == "HoldPattern":
        if len(normalized.arguments) != 1:
            raise WolframEvaluationError("HoldPattern expects exactly one argument.")
        return _match_string_pattern_states(
            normalized.arguments[0],
            text,
            start,
            current,
            prefer_longest=prefer_longest,
        )

    if head_name in {"Longest", "Shortest"}:
        if len(normalized.arguments) not in {1, 2}:
            raise WolframEvaluationError(f"{head_name} expects one or two arguments.")
        return _match_string_pattern_states(
            normalized.arguments[0],
            text,
            start,
            current,
            prefer_longest=(head_name == "Longest"),
        )

    if head_name == "StringExpression":
        return _match_string_expression_parts(
            _flatten_string_expression_parts(normalized),
            text,
            start,
            current,
            prefer_longest=prefer_longest,
        )

    if head_name == "Alternatives":
        matches: list[_StringPatternState] = []
        for branch in normalized.arguments:
            matches.extend(
                _match_string_pattern_states(branch, text, start, current, prefer_longest=prefer_longest)
            )
        return matches

    if head_name == "Condition":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Condition expects exactly two arguments.")
        matches = _match_string_pattern_states(
            normalized.arguments[0],
            text,
            start,
            current,
            prefer_longest=prefer_longest,
        )
        return [
            state
            for state in matches
            if _condition_test_succeeds(normalized.arguments[1], state.bindings)
        ]

    if head_name == "PatternTest":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("PatternTest expects exactly two arguments.")
        matches = _match_string_pattern_states(
            normalized.arguments[0],
            text,
            start,
            current,
            prefer_longest=prefer_longest,
        )
        return [
            state
            for state in matches
            if _string_pattern_test_succeeds(normalized.arguments[1], text, start, state.end)
        ]

    if head_name == "Pattern":
        if len(normalized.arguments) != 2:
            raise WolframEvaluationError("Pattern expects exactly two arguments.")
        name_expr, inner_pattern = normalized.arguments
        if not isinstance(name_expr, Symbol):
            raise WolframEvaluationError("Pattern expects a symbol as its first argument.")
        matches = _match_string_pattern_states(
            inner_pattern,
            text,
            start,
            current,
            prefer_longest=prefer_longest,
        )
        updated_matches: list[_StringPatternState] = []
        for state in matches:
            bound_value = string(text[start:state.end])
            existing = state.bindings.get(name_expr.name)
            if existing is not None and existing != bound_value:
                continue
            updated_bindings = dict(state.bindings)
            updated_bindings[name_expr.name] = bound_value
            updated_matches.append(_StringPatternState(end=state.end, bindings=updated_bindings))
        return updated_matches

    if head_name == "Blank":
        if len(normalized.arguments) != 0:
            raise _unsupported_string_pattern(normalized)
        if start >= len(text):
            return []
        return [_StringPatternState(end=start + 1, bindings=current)]

    if head_name in {"BlankSequence", "BlankNullSequence"}:
        if len(normalized.arguments) != 0:
            raise _unsupported_string_pattern(normalized)
        minimum_length = 0 if head_name == "BlankNullSequence" else 1
        if prefer_longest:
            ends = range(len(text), start + minimum_length - 1, -1)
        else:
            ends = range(start + minimum_length, len(text) + 1)
        return [
            _StringPatternState(end=end, bindings=dict(current))
            for end in ends
        ]

    if head_name in {"Repeated", "RepeatedNull"}:
        return _match_repeated_string_pattern(normalized, text, start, current, prefer_longest=prefer_longest)

    if head_name == "Except":
        if start >= len(text):
            return []
        matches = _match_single_character_string_pattern(text[start], normalized, current)
        return [_StringPatternState(end=start + 1, bindings=match) for match in matches]

    if head_name == "CharacterRange":
        if start >= len(text):
            return []
        matches = _match_single_character_string_pattern(text[start], normalized, current)
        return [_StringPatternState(end=start + 1, bindings=match) for match in matches]

    if head_name == "RegularExpression":
        if len(normalized.arguments) != 1 or not isinstance(normalized.arguments[0], String):
            raise WolframEvaluationError("RegularExpression expects exactly one string argument in string patterns.")
        try:
            regex = re.compile(normalized.arguments[0].value)
        except re.error as error:
            raise WolframEvaluationError(f"Invalid RegularExpression pattern: {error}.") from error
        match = regex.match(text, start)
        return [_StringPatternState(end=match.end(), bindings=current)] if match is not None else []

    if head_name == "DatePattern":
        regex = _date_pattern_regex(normalized)
        match = regex.match(text, start)
        return [_StringPatternState(end=match.end(), bindings=current)] if match is not None else []

    raise _unsupported_string_pattern(normalized)


def _normalize_string_pattern_specs(pattern: Expr, function_name: str) -> list[_StringPatternSpec]:
    if isinstance(pattern, Call) and pattern.has_head("List"):
        return [_StringPatternSpec(item, None, False) for item in pattern.arguments]
    return [_StringPatternSpec(pattern, None, False)]


def _normalize_string_cases_specs(pattern_spec: Expr) -> list[_StringPatternSpec]:
    if isinstance(pattern_spec, Call) and pattern_spec.has_head("List"):
        specs: list[_StringPatternSpec] = []
        for item in pattern_spec.arguments:
            specs.extend(_normalize_string_cases_specs(item))
        return specs
    if _is_replacement_rule_expr(pattern_spec):
        assert isinstance(pattern_spec, Call)
        pattern, template = pattern_spec.arguments
        delayed = pattern_spec.has_head("RuleDelayed")
        if not delayed:
            template = evaluate(template)
        return [_StringPatternSpec(pattern, template, delayed)]
    return [_StringPatternSpec(pattern_spec, None, False)]


def _normalize_string_replace_specs(rules: Expr) -> list[_StringPatternSpec]:
    if isinstance(rules, Call) and rules.has_head("List"):
        specs: list[_StringPatternSpec] = []
        for item in rules.arguments:
            specs.extend(_normalize_string_replace_specs(item))
        return specs
    if not _is_replacement_rule_expr(rules):
        raise WolframEvaluationError("StringReplace expects a rule or a list of rules.")
    assert isinstance(rules, Call)
    pattern, template = rules.arguments
    delayed = rules.has_head("RuleDelayed")
    if not delayed:
        template = evaluate(template)
    return [_StringPatternSpec(pattern, template, delayed)]


def _first_string_match_at(
    text: str,
    start: int,
    specs: Sequence[_StringPatternSpec],
    *,
    require_end: bool = False,
) -> _StringFoundMatch | None:
    for spec in specs:
        matches = _match_string_pattern_states(spec.pattern, text, start)
        for match in matches:
            if require_end and match.end != len(text):
                continue
            return _StringFoundMatch(start=start, end=match.end, bindings=match.bindings, spec=spec)
    return None


def _collect_string_matches(
    text: str,
    specs: Sequence[_StringPatternSpec],
    *,
    overlaps: bool,
    limit: int | None = None,
    require_start: bool = False,
    require_end: bool = False,
) -> list[_StringFoundMatch]:
    matches: list[_StringFoundMatch] = []
    start = 0
    while start <= len(text):
        found = _first_string_match_at(text, start, specs, require_end=require_end)
        if found is None:
            if require_start:
                break
            start += 1
            continue
        matches.append(found)
        if limit is not None and len(matches) >= limit:
            break
        if require_start:
            break
        if overlaps:
            start += 1
        else:
            start = found.end if found.end > start else start + 1
    return matches


def _match_string_boolean(
    text: str,
    specs: Sequence[_StringPatternSpec],
    *,
    require_start: bool = False,
    require_end: bool = False,
) -> bool:
    return bool(_collect_string_matches(text, specs, overlaps=True, limit=1, require_start=require_start, require_end=require_end))


def _string_position_scalar(text: str, specs: Sequence[_StringPatternSpec], limit: int | None) -> Expr:
    matches = _collect_string_matches(text, specs, overlaps=True, limit=limit)
    return list_expr(*(list_expr(integer(match.start + 1), integer(match.end)) for match in matches))


def _flatten_string_expression_pieces(expr: Expr) -> list[Expr]:
    if isinstance(expr, Call) and expr.has_head("StringExpression"):
        flattened: list[Expr] = []
        for item in expr.arguments:
            flattened.extend(_flatten_string_expression_pieces(item))
        return flattened
    return [expr]


def _string_expression_from_pieces(pieces: Sequence[Expr]) -> Expr:
    flattened: list[Expr] = []
    for piece in pieces:
        flattened.extend(_flatten_string_expression_pieces(piece))

    if not flattened:
        return string("")

    merged: list[Expr] = []
    string_buffer = ""
    for piece in flattened:
        if isinstance(piece, String):
            string_buffer += piece.value
            continue
        if string_buffer:
            merged.append(string(string_buffer))
            string_buffer = ""
        merged.append(piece)
    if string_buffer:
        merged.append(string(string_buffer))

    if not merged:
        return string("")
    if len(merged) == 1:
        return merged[0]
    if all(isinstance(piece, String) for piece in merged):
        return string("".join(piece.value for piece in merged if isinstance(piece, String)))
    return call("StringExpression", *merged)


def string_match_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringMatchQ")
    return _string_thread(
        expr,
        "StringMatchQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs, require_start=True, require_end=True)),
    )


def string_free_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringFreeQ")
    return _string_thread(
        expr,
        "StringFreeQ",
        lambda item: _bool_symbol(not _match_string_boolean(item.value, specs)),
    )


def string_position(expr: Expr, pattern: Expr, limit: Expr | int | None = None) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringPosition")
    normalized_limit = _normalize_match_limit(limit)
    return _string_thread(
        expr,
        "StringPosition",
        lambda item: _string_position_scalar(item.value, specs, normalized_limit),
    )


def string_contains_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringContainsQ")
    return _string_thread(
        expr,
        "StringContainsQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs)),
    )


def string_starts_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringStartsQ")
    return _string_thread(
        expr,
        "StringStartsQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs, require_start=True)),
    )


def string_ends_q(expr: Expr, pattern: Expr) -> Expr:
    specs = _normalize_string_pattern_specs(pattern, "StringEndsQ")
    return _string_thread(
        expr,
        "StringEndsQ",
        lambda item: _bool_symbol(_match_string_boolean(item.value, specs, require_end=True)),
    )


def _first_string_case_or_replacement_match_at(
    text: str,
    start: int,
    specs: Sequence[_StringPatternSpec],
) -> tuple[_StringFoundMatch, Expr] | None:
    for spec in specs:
        matches = _match_string_pattern_states(spec.pattern, text, start)
        for match in matches:
            found = _StringFoundMatch(start=start, end=match.end, bindings=match.bindings, spec=spec)
            if spec.template is None:
                return (found, string(text[start:match.end]))
            transformed, applied = _instantiate_replacement_template(
                spec.template,
                match.bindings,
                delayed=spec.delayed,
            )
            if not applied:
                continue
            assert transformed is not None
            return (found, transformed)
    return None


def _string_cases_scalar(text: str, specs: Sequence[_StringPatternSpec], limit: int | None) -> Expr:
    results: list[Expr] = []
    position = 0
    while position <= len(text):
        if limit is not None and len(results) >= limit:
            break
        found = _first_string_case_or_replacement_match_at(text, position, specs)
        if found is None:
            if position >= len(text):
                break
            position += 1
            continue
        match, result = found
        results.append(result)
        position = match.end if match.end > position else position + 1
    return _evaluated_list_expr(*results)


def string_cases(expr: Expr, pattern_spec: Expr, limit: Expr | int | None = None) -> Expr:
    specs = _normalize_string_cases_specs(pattern_spec)
    normalized_limit = _normalize_match_limit(limit)
    return _string_thread(
        expr,
        "StringCases",
        lambda item: _string_cases_scalar(item.value, specs, normalized_limit),
    )


def _string_replace_scalar(text: str, specs: Sequence[_StringPatternSpec], limit: int | None) -> Expr:
    pieces: list[Expr] = []
    position = 0
    replacements = 0

    while position <= len(text):
        if limit is not None and replacements >= limit:
            break
        found = _first_string_case_or_replacement_match_at(text, position, specs)
        if found is None:
            if position >= len(text):
                break
            pieces.append(string(text[position]))
            position += 1
            continue
        match, transformed = found
        pieces.append(transformed)
        replacements += 1
        next_position = match.end if match.end > position else position + 1
        position = next_position

    if position < len(text):
        pieces.append(string(text[position:]))

    return _string_expression_from_pieces(pieces)


def string_replace(expr: Expr, rules: Expr, limit: Expr | int | None = None) -> Expr:
    specs = _normalize_string_replace_specs(rules)
    normalized_limit = _normalize_match_limit(limit)
    return _string_thread(
        expr,
        "StringReplace",
        lambda item: _string_replace_scalar(item.value, specs, normalized_limit),
    )


_UNSUPPORTED_PATTERN_HEADS: set[str] = set()


def _expression_patterns_module():
    from . import expression_patterns as _patterns

    return _patterns


def _match_pattern(
    expr: Expr,
    pattern: Expr,
    bindings: dict[str, Expr] | None = None,
    *,
    ignore_inactive: bool = False,
) -> dict[str, Expr] | None:
    return _expression_patterns_module()._match_pattern(
        expr, pattern, bindings, ignore_inactive=ignore_inactive
    )


def match_q(expr: Expr, pattern: Expr) -> Symbol:
    return _expression_patterns_module().match_q(expr, pattern)


def free_q(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    *,
    include_heads: bool = True,
) -> Symbol:
    return _expression_patterns_module().free_q(expr, pattern, spec, include_heads=include_heads)


def _condition_test_succeeds(test: Expr, bindings: dict[str, Expr]) -> bool:
    return _expression_patterns_module()._condition_test_succeeds(test, bindings)


def _repetition_count_bounds(repetition: Call) -> tuple[int, int | None]:
    return _expression_patterns_module()._repetition_count_bounds(repetition)


def _level_bounds_match(
    positive_level: int,
    negative_level: int,
    level_min: int,
    level_max: int,
) -> bool:
    return _expression_patterns_module()._level_bounds_match(
        positive_level, negative_level, level_min, level_max
    )


def _normalize_match_limit(limit: Expr | int | None) -> int | None:
    return _expression_patterns_module()._normalize_match_limit(limit)


def _missing_not_found() -> Expr:
    return _expression_patterns_module()._missing_not_found()


def _selection_spec(criterion: Expr, function_name: str):
    return _expression_patterns_module()._selection_spec(criterion, function_name)


def _selection_items(expr: Expr, function_name: str):
    return _expression_patterns_module()._selection_items(expr, function_name)


def _selection_elements(expr: Expr, items, function_name: str) -> Expr:
    return _expression_patterns_module()._selection_elements(expr, items, function_name)


def _selection_projection(
    expr: Expr,
    items,
    function_name: str,
    property_spec,
) -> Expr:
    return _expression_patterns_module()._selection_projection(
        expr, items, function_name, property_spec
    )


def _select_first_projection(item, property_spec, default: Expr | object = _MISSING) -> Expr:
    return _expression_patterns_module()._select_first_projection(
        item, property_spec, default
    )


def _predicate_succeeds_with_arguments(criterion: Expr, arguments: Sequence[Expr]) -> bool:
    return _expression_patterns_module()._predicate_succeeds_with_arguments(criterion, arguments)


def _predicate_succeeds(criterion: Expr, value: Expr) -> bool:
    return _expression_patterns_module()._predicate_succeeds(criterion, value)


def if_expr(arguments: Sequence[Expr]) -> Expr:
    return _expression_patterns_module().if_expr(arguments)


def which_expr(arguments: Sequence[Expr]) -> Expr:
    return _expression_patterns_module().which_expr(arguments)


def switch_expr(arguments: Sequence[Expr]) -> Expr:
    return _expression_patterns_module().switch_expr(arguments)


def piecewise_expr(arguments: Sequence[Expr]) -> Expr:
    return _expression_patterns_module().piecewise_expr(arguments)


def pick(expr: Expr, selector: Expr, pattern: Expr | None = None) -> Expr:
    return _expression_patterns_module().pick(expr, selector, pattern)


def clip_expr(arguments: Sequence[Expr]) -> Expr:
    return _expression_patterns_module().clip_expr(arguments)


def _instantiate_replacement_template(
    template: Expr,
    bindings: dict[str, Expr],
    *,
    delayed: bool,
    evaluate_result: bool = True,
) -> tuple[Expr, bool]:
    return _expression_patterns_module()._instantiate_replacement_template(
        template, bindings, delayed=delayed, evaluate_result=evaluate_result
    )


def _is_replacement_rule_expr(expr: Expr) -> bool:
    return _expression_patterns_module()._is_replacement_rule_expr(expr)


def replace(
    expr: Expr,
    rules: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    *,
    include_heads: bool = False,
) -> Expr:
    return _expression_patterns_module().replace(expr, rules, spec, include_heads=include_heads)


def replace_all(expr: Expr, rules: Expr) -> Expr:
    return _expression_patterns_module().replace_all(expr, rules)


def replace_repeated(expr: Expr, rules: Expr) -> Expr:
    return _expression_patterns_module().replace_repeated(expr, rules)


def replace_at(expr: Expr, rules: Expr, positions: Expr | int) -> Expr:
    return _expression_patterns_module().replace_at(expr, rules, positions)


def cases(
    expr: Expr,
    pattern_spec: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
    *,
    include_heads: bool = False,
) -> Expr:
    return _expression_patterns_module().cases(
        expr, pattern_spec, spec, limit, include_heads=include_heads
    )


def delete_cases(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
    *,
    include_heads: bool = False,
) -> Expr:
    return _expression_patterns_module().delete_cases(
        expr, pattern, spec, limit, include_heads=include_heads
    )


def head_of(expr: Expr) -> Expr:
    return expr.head()


def length(expr: Expr) -> int:
    if isinstance(expr, SparseArrayExpr):
        return expr.dimensions[0] if expr.dimensions else 0
    byte_values = _byte_array_values(expr)
    if byte_values is not None:
        return len(byte_values)
    return len(expr.args())


def depth(expr: Expr) -> int:
    if isinstance(expr, SparseArrayExpr):
        return len(expr.dimensions) + 1
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            return 2
        return 1 + max(depth(entry.value) for entry in entries)

    if not isinstance(expr, Call):
        return 1

    if not expr.arguments:
        return 2
    return 1 + max(depth(argument) for argument in expr.arguments)


def part(expr: Expr, *specs: int | Expr) -> Expr:
    normalized = tuple(integer(spec) if isinstance(spec, int) else spec for spec in specs)
    if not normalized:
        return expr
    if isinstance(expr, SparseArrayExpr):
        return sparse_array_part(expr, normalized)
    return _part_recursive(expr, normalized)


def extract(expr: Expr, positions: Expr | Sequence[Expr | Sequence[int] | int]) -> Expr:
    if isinstance(positions, Expr):
        if _is_collection_of_position_specs(positions):
            return _evaluated_list_expr(
                *[part(expr, *_position_components_from_expr(item)) for item in positions.arguments]
            )
        if _is_single_position_spec_expr(positions):
            return part(expr, *_position_components_from_expr(positions))
        raise WolframEvaluationError("Extract positions must be a position list or a list of position lists.")

    extracted: list[Expr] = []
    for item in positions:
        if isinstance(item, Expr):
            if _is_collection_of_position_specs(item):
                extracted.extend(part(expr, *_position_components_from_expr(child)) for child in item.arguments)
            else:
                extracted.append(part(expr, *_position_components_from_expr(item)))
            continue
        if isinstance(item, int):
            extracted.append(part(expr, item))
            continue
        extracted.append(part(expr, *item))
    return _evaluated_list_expr(*extracted)


def level(expr: Expr, spec: Expr | int | tuple[int, int] = 1) -> list[Expr]:
    records: list[_LevelRecord] = []
    _collect_levels(expr, 0, records)
    level_min, level_max = _normalize_level_spec(spec)
    return [record.expr for record in records if _level_matches(record, level_min, level_max)]


_HELD_ARGUMENT_HEADS = {
    "Function",
    "Hold",
    "HoldComplete",
    "HoldForm",
    "HoldPattern",
    "Unevaluated",
}


_SEQUENCE_SUPPRESSING_HEADS = {
    "HoldComplete",
    "Rule",
    "RuleDelayed",
    "Unevaluated",
}


_HOLD_ALL_COMPLETE_HEADS = {
    "HoldComplete",
    "Unevaluated",
}


_RELEASE_HOLD_HEADS = {
    "Hold",
    "HoldComplete",
    "HoldForm",
    "Unevaluated",
}


_UNEVALUATED_TRANSPARENT_HEADS = {
    "Abs",
    "Accuracy",
    "And",
    "AlphabeticSort",
    "Append",
    "AppendTo",
    "Apply",
    "Array",
    "ArrayDepth",
    "ArrayFlatten",
    "ArrayPad",
    "ArrayQ",
    "ArrayReshape",
    "ArrayRules",
    "AtomQ",
    "BaseDecode",
    "BaseEncode",
    "BlockMap",
    "Boole",
    "ByteArray",
    "ByteArrayQ",
    "ByteArrayToString",
    "Cases",
    "Characters",
    "Clip",
    "Comap",
    "ComapApply",
    "ComposeList",
    "Composition",
    "ConstantArray",
    "Construct",
    "Cross",
    "Delete",
    "DeleteAdjacentDuplicates",
    "DeleteCases",
    "DeleteDuplicates",
    "DeleteDuplicatesBy",
    "Det",
    "Depth",
    "Dimensions",
    "Discard",
    "DiscreteDelta",
    "Dot",
    "Drop",
    "DuplicateFreeQ",
    "Equal",
    "ExactNumberQ",
    "Extract",
    "First",
    "FirstCase",
    "FixedPoint",
    "FixedPointList",
    "Flatten",
    "FlattenAt",
    "Fold",
    "FoldList",
    "FoldPair",
    "FoldPairList",
    "FoldWhile",
    "FoldWhileList",
    "FreeQ",
    "FromCharacterCode",
    "Greater",
    "GreaterEqual",
    "Head",
    "Identity",
    "If",
    "Im",
    "IntegerQ",
    "InexactNumberQ",
    "Insert",
    "Inverse",
    "Join",
    "KroneckerDelta",
    "Last",
    "LeviCivitaTensor",
    "Length",
    "LengthWhile",
    "Less",
    "LessEqual",
    "LexicographicOrder",
    "LexicographicSort",
    "Level",
    "Lookup",
    "MachineIntegerQ",
    "MachineNumberQ",
    "Map",
    "MapAll",
    "MapApply",
    "MapAt",
    "MapIndexed",
    "MapThread",
    "MatchQ",
    "MatrixPower",
    "Max",
    "MaximalBy",
    "MemberQ",
    "Min",
    "MinimalBy",
    "Mod",
    "Most",
    "N",
    "Nest",
    "NestList",
    "NestWhile",
    "NestWhileList",
    "Not",
    "Normal",
    "NumberQ",
    "NumericalSort",
    "Operate",
    "Or",
    "Order",
    "OrderedQ",
    "Ordering",
    "OrderingBy",
    "Outer",
    "Part",
    "Partition",
    "Pick",
    "Plus",
    "Position",
    "Power",
    "Precision",
    "Prepend",
    "Quotient",
    "QuotientRemainder",
    "Ramp",
    "RandomSample",
    "Range",
    "Re",
    "RealAbs",
    "RealSign",
    "RealValuedNumberQ",
    "Replace",
    "ReplaceAll",
    "ReplaceAt",
    "ReplacePart",
    "ReplaceRepeated",
    "Rest",
    "Reverse",
    "ReverseSort",
    "ReverseSortBy",
    "RightComposition",
    "RotateLeft",
    "RotateRight",
    "SameQ",
    "Scan",
    "Select",
    "SelectFirst",
    "SetAccuracy",
    "SetPrecision",
    "SequenceFold",
    "SequenceFoldList",
    "Sign",
    "Sort",
    "SortBy",
    "SparseArray",
    "SparseArrayQ",
    "Split",
    "SplitBy",
    "Subsequences",
    "Conjugate",
    "StringContainsQ",
    "StringDrop",
    "StringEndsQ",
    "StringFreeQ",
    "StringInsert",
    "StringJoin",
    "StringLength",
    "StringMatchQ",
    "StringPosition",
    "StringReplace",
    "StringReverse",
    "StringStartsQ",
    "StringTake",
    "StringToByteArray",
    "Switch",
    "Take",
    "TakeDrop",
    "TakeList",
    "TakeWhile",
    "Thread",
    "Through",
    "Times",
    "Tr",
    "Transpose",
    "ToCharacterCode",
    "Tuples",
    "UnitStep",
    "UnitVector",
    "Unitize",
    "UnsameQ",
    "Which",
}


def _splice_sequence_arguments(arguments: Sequence[Expr], enclosing_head: Expr | None = None) -> tuple[Expr, ...]:
    spliced: list[Expr] = []
    for argument in arguments:
        if isinstance(argument, Call) and argument.has_head("Sequence"):
            spliced.extend(argument.arguments)
            continue
        if (
            isinstance(argument, Call)
            and argument.has_head("Splice")
            and len(argument.arguments) in {1, 2}
            and isinstance(argument.arguments[0], Call)
            and argument.arguments[0].has_head("List")
        ):
            # ``Splice[{e1, ...}]`` defaults to splicing into ``List`` heads;
            # ``Splice[{e1, ...}, h]`` splices when the enclosing head matches
            # ``h``. Bare ``Splice[{...}]`` outside a call stays inert.
            target_head: Expr = (
                argument.arguments[1] if len(argument.arguments) == 2 else Symbol("List")
            )
            if enclosing_head is not None and enclosing_head == target_head:
                spliced.extend(argument.arguments[0].arguments)
                continue
        spliced.append(argument)
    return tuple(spliced)


def _is_nothing_expr(expr: Expr) -> bool:
    return isinstance(expr, Symbol) and expr.name == "Nothing"


def _drop_nothing_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    return tuple(argument for argument in arguments if not _is_nothing_expr(argument))


def _attributes_hold_argument(attribute_names: set[str], index: int) -> bool:
    if attribute_names & _HOLD_ALL_ATTRIBUTE_NAMES:
        return True
    if "HoldFirst" in attribute_names and index == 0:
        return True
    if "HoldRest" in attribute_names and index > 0:
        return True
    return False


def _attributes_suppress_sequence_splicing(attribute_names: set[str]) -> bool:
    return "SequenceHold" in attribute_names or "HoldAllComplete" in attribute_names


def _attribute_names_for_symbol(expr: Symbol) -> set[str]:
    return set(_SYMBOL_REGISTRY.record_for_symbol(expr).attributes)


def _evaluate_argument_with_attributes(argument: Expr, attribute_names: set[str], index: int) -> Expr:
    if _attributes_hold_argument(attribute_names, index):
        if "HoldAllComplete" in attribute_names:
            return argument
        if _is_direct_evaluate_expr(argument):
            return _evaluate_direct_evaluate_argument(argument)
        return argument
    return evaluate(argument)


def _prepare_symbol_call_arguments(head: Symbol, raw_arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    attribute_names = _attribute_names_for_symbol(head)
    prepared = tuple(
        _evaluate_argument_with_attributes(argument, attribute_names, index)
        for index, argument in enumerate(raw_arguments)
    )
    if not _attributes_suppress_sequence_splicing(attribute_names):
        prepared = _splice_sequence_arguments(prepared, enclosing_head=head)
    if _system_dispatch_name(head) in {"Association", "List"}:
        prepared = _drop_nothing_arguments(prepared)
    return prepared


def _is_direct_evaluate_expr(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Evaluate") and len(expr.arguments) == 1


def _is_direct_unevaluated_expr(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Unevaluated") and len(expr.arguments) == 1


def _strip_unevaluated_argument(expr: Expr) -> Expr:
    return expr.arguments[0] if _is_direct_unevaluated_expr(expr) and isinstance(expr, Call) else expr


def _strip_unevaluated_arguments(arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    return tuple(_strip_unevaluated_argument(argument) for argument in arguments)


def _evaluate_direct_evaluate_argument(expr: Expr) -> Expr:
    if not _is_direct_evaluate_expr(expr):
        return expr
    assert isinstance(expr, Call)
    payload = expr.arguments[0]
    # Wolfram's Evaluate only overrides holding at the first level. An
    # Unevaluated wrapper immediately inside it blocks that override when the
    # whole Evaluate[...] appears as the direct held argument.
    if _is_direct_unevaluated_expr(payload):
        return payload
    return evaluate(payload)


def _evaluate_evaluate_payload(expr: Expr) -> Expr:
    if _is_direct_unevaluated_expr(expr):
        assert isinstance(expr, Call)
        return evaluate(expr.arguments[0])
    return evaluate(expr)


def _evaluate_transparent_argument(expr: Expr) -> Expr:
    return _strip_unevaluated_argument(evaluate(expr))


def _normalize_held_arguments_for_head(head_name: str, arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    normalized: list[Expr] = []
    for argument in arguments:
        if head_name not in _HOLD_ALL_COMPLETE_HEADS and _is_direct_evaluate_expr(argument):
            normalized.append(_evaluate_direct_evaluate_argument(argument))
        else:
            normalized.append(argument)
    return _normalize_arguments_for_head(head_name, normalized, evaluated=False)


def _normalize_arguments_for_head(
    head_name: str,
    arguments: Sequence[Expr],
    *,
    evaluated: bool,
) -> tuple[Expr, ...]:
    normalized = tuple(arguments)
    if head_name not in _SEQUENCE_SUPPRESSING_HEADS:
        normalized = _splice_sequence_arguments(normalized, enclosing_head=Symbol(head_name))
    if evaluated and head_name in {"Association", "List"}:
        normalized = _drop_nothing_arguments(normalized)
    return normalized


def release_hold(expr: Expr) -> Expr:
    if (
        isinstance(expr, Call)
        and isinstance(expr.head_expr, Symbol)
        and expr.head_expr.name in _RELEASE_HOLD_HEADS
    ):
        if len(expr.arguments) == 1:
            return evaluate(expr.arguments[0])
        return evaluate(call("Sequence", *expr.arguments))
    return expr


def _is_inactive_wrapper(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Inactive") and len(expr.arguments) == 1


def _inactive_target_matches(target: Expr, pattern: Expr | None) -> bool:
    return pattern is None or _match_pattern(target, pattern) is not None


def _activate_inactive(expr: Expr, pattern: Expr | None) -> Expr:
    if _is_inactive_wrapper(expr):
        assert isinstance(expr, Call)
        target = expr.arguments[0]
        activated_target = _activate_inactive(target, pattern)
        if _inactive_target_matches(target, pattern):
            return activated_target
        return Call(head_expr=expr.head_expr, arguments=(activated_target,))

    if isinstance(expr, Call):
        activated_head = _activate_inactive(expr.head_expr, pattern)
        activated_arguments = tuple(_activate_inactive(argument, pattern) for argument in expr.arguments)
        return Call(head_expr=activated_head, arguments=activated_arguments)

    return expr


def activate_expr(expr: Expr, pattern: Expr | None = None) -> Expr:
    return evaluate(_activate_inactive(expr, pattern))


def first(expr: Expr, default: Expr | object = _MISSING) -> Expr:
    entries = _association_entries(expr)
    if entries is not None and entries:
        return entries[0].value
    if isinstance(expr, Call) and expr.arguments:
        return expr.arguments[0]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    raise WolframEvaluationError(f"Cannot take First of {expr.to_input_form()}.")


def last(expr: Expr, default: Expr | object = _MISSING) -> Expr:
    entries = _association_entries(expr)
    if entries is not None and entries:
        return entries[-1].value
    if isinstance(expr, Call) and expr.arguments:
        return expr.arguments[-1]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    raise WolframEvaluationError(f"Cannot take Last of {expr.to_input_form()}.")


def rest(expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            raise WolframEvaluationError(f"Cannot take Rest of {expr.to_input_form()} with length zero.")
        return _association_expr(entries[1:])

    compound = _require_compound(expr, "Rest")
    if not compound.arguments:
        raise WolframEvaluationError(f"Cannot take Rest of {expr.to_input_form()} with length zero.")
    return _rebuild(compound, compound.arguments[1:])


def most(expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            raise WolframEvaluationError(f"Cannot take Most of {expr.to_input_form()} with length zero.")
        return _association_expr(entries[:-1])

    compound = _require_compound(expr, "Most")
    if not compound.arguments:
        raise WolframEvaluationError(f"Cannot take Most of {expr.to_input_form()} with length zero.")
    return _rebuild(compound, compound.arguments[:-1])


def take(expr: Expr, *specs: Expr | int) -> Expr:
    """Take[expr, spec], or matrix-style Take[expr, spec1, spec2, ...].

    Multiple specs slice along consecutive levels: ``Take[matrix, 2, 3]``
    takes the first 2 rows, then takes 3 from each. Each spec uses the
    full single-level vocabulary (``n``, ``All``, ``Span``, ``{m, n, s}``,
    ``{n}``, ``UpTo[n]``).
    """
    return _multi_take_or_drop(expr, list(specs), drop=False)


def drop(expr: Expr, *specs: Expr | int) -> Expr:
    return _multi_take_or_drop(expr, list(specs), drop=True)


def _multi_take_or_drop(expr: Expr, specs: list[Expr | int], *, drop: bool) -> Expr:
    if not specs:
        return expr
    compound = _require_compound(expr, "Drop" if drop else "Take")
    spec, *rest = specs
    sliced = _take_or_drop(compound, (spec,), drop=drop)
    if not rest:
        return sliced
    if not isinstance(sliced, Call):
        return sliced
    new_arguments = tuple(
        _multi_take_or_drop(argument, list(rest), drop=drop)
        for argument in sliced.arguments
    )
    return _rebuild(sliced, new_arguments)


def select(expr: Expr, criterion: Expr, limit: Expr | int | None = None) -> Expr:
    selector, property_spec = _selection_spec(criterion, "Select")
    remaining = _normalize_match_limit(limit)
    selected: list[_SelectionItem] = []

    for item in _selection_items(expr, "Select"):
        if not _predicate_succeeds(selector, item.value):
            continue
        if remaining == 0:
            break
        selected.append(item)
        if remaining is not None:
            remaining -= 1

    return _selection_projection(expr, selected, "Select", property_spec)


def discard(expr: Expr, criterion: Expr, limit: Expr | int | None = None) -> Expr:
    selector, property_spec = _selection_spec(criterion, "Discard")
    remaining = _normalize_match_limit(limit)
    retained: list[_SelectionItem] = []

    for item in _selection_items(expr, "Discard"):
        if remaining != 0 and _predicate_succeeds(selector, item.value):
            if remaining is not None:
                remaining -= 1
            continue
        retained.append(item)

    return _selection_projection(expr, retained, "Discard", property_spec)


def select_first(expr: Expr, criterion: Expr, default: Expr | object = _MISSING) -> Expr:
    selector, property_spec = _selection_spec(criterion, "SelectFirst")
    for item in _selection_items(expr, "SelectFirst"):
        if _predicate_succeeds(selector, item.value):
            return _select_first_projection(item, property_spec, default)
    return _select_first_projection(None, property_spec, default)


def take_while(expr: Expr, criterion: Expr) -> Expr:
    retained: list[_SelectionItem] = []
    for item in _selection_items(expr, "TakeWhile"):
        if not _predicate_succeeds(criterion, item.value):
            break
        retained.append(item)
    return _selection_elements(expr, retained, "TakeWhile")


def append(expr: Expr, item: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        entry = _rule_entry(item)
        if entry is None:
            raise WolframEvaluationError("Append expects a rule when appending to an Association.")
        remaining = [existing for existing in entries if existing.key != entry.key]
        remaining.append(entry)
        return _association_expr(remaining)

    compound = _require_compound(expr, "Append")
    return _rebuild(compound, (*compound.arguments, item))


def prepend(expr: Expr, item: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        entry = _rule_entry(item)
        if entry is None:
            raise WolframEvaluationError("Prepend expects a rule when prepending to an Association.")
        remaining = [existing for existing in entries if existing.key != entry.key]
        return _association_expr([entry, *remaining])

    compound = _require_compound(expr, "Prepend")
    return _rebuild(compound, (item, *compound.arguments))


def join(*exprs: Expr) -> Expr:
    if not exprs:
        raise WolframEvaluationError("Join expects at least one expression.")

    if all(_is_association(expr) for expr in exprs):
        merged: list[_AssociationEntry] = []
        for expr in exprs:
            assert (entries := _association_entries(expr)) is not None
            merged.extend(entries)
        return _association_expr(merged)

    compounds = [_require_compound(expr, "Join") for expr in exprs]
    head_expr = compounds[0].head_expr
    for compound in compounds[1:]:
        if compound.head_expr != head_expr:
            raise WolframEvaluationError("Join expects all expressions to have the same head.")

    arguments: list[Expr] = []
    for compound in compounds:
        arguments.extend(compound.arguments)
    return Call(head_expr=head_expr, arguments=tuple(arguments))


def reverse(expr: Expr, level_spec: Expr | None = None) -> Expr:
    """Reverse[expr] (default: level 1) or Reverse[expr, levelspec].

    The level spec follows Wolfram's ``Reverse`` contract: an integer ``n``
    means "reverse the level-1..level-n axes", a ``{n}`` list means "reverse
    only at level ``n``", and a ``{m, n}`` list means "reverse on every level
    from ``m`` to ``n`` inclusive".
    """
    if level_spec is None:
        levels: set[int] = {1}
    else:
        levels = _normalize_reverse_levels(level_spec)

    return _reverse_at_levels(expr, levels, current_level=1)


def _normalize_reverse_levels(level_spec: Expr) -> set[int]:
    if isinstance(level_spec, Integer):
        if level_spec.value < 1:
            raise WolframEvaluationError(
                "Reverse expects a positive integer level specification."
            )
        # Wolfram's Reverse[expr, n] reverses only the n-th level. Use
        # {l1, l2, ...} or {min, max} for multi-level reversal.
        return {level_spec.value}
    if isinstance(level_spec, Call) and level_spec.has_head("List"):
        if len(level_spec.arguments) == 1 and isinstance(level_spec.arguments[0], Integer):
            target = level_spec.arguments[0].value
            if target < 0:
                raise WolframEvaluationError(
                    "Reverse expects a non-negative level specification."
                )
            return {target} if target >= 1 else set()
        if len(level_spec.arguments) == 2 and all(
            isinstance(item, Integer) for item in level_spec.arguments
        ):
            low = level_spec.arguments[0].value  # type: ignore[union-attr]
            high = level_spec.arguments[1].value  # type: ignore[union-attr]
            if low < 1 or high < low:
                raise WolframEvaluationError(
                    "Reverse expects a positive {min, max} level range."
                )
            return set(range(low, high + 1))
    raise WolframEvaluationError(
        "Reverse currently supports an integer or {n}/{min, max} level spec."
    )


def _reverse_at_levels(expr: Expr, levels: set[int], current_level: int) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        new_entries = [
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_reverse_at_levels(entry.value, levels, current_level + 1),
            )
            for entry in entries
        ]
        if current_level in levels:
            new_entries = list(reversed(new_entries))
        return _association_expr(new_entries)

    if isinstance(expr, Call):
        new_arguments = tuple(
            _reverse_at_levels(argument, levels, current_level + 1)
            for argument in expr.arguments
        )
        if current_level in levels:
            new_arguments = tuple(reversed(new_arguments))
        return _rebuild(expr, new_arguments)

    return expr


def rotate_left(expr: Expr, amount: Expr | int = 1) -> Expr:
    """``RotateLeft[expr]`` / ``RotateLeft[expr, n]`` /
    ``RotateLeft[expr, {n1, n2, …}]``.

    The list-of-amounts form rotates each level in turn: ``n1``
    positions left at the outermost level, then ``n2`` positions left
    at every immediate child, and so on. Levels not listed are left
    untouched. Each level must be a ``List`` with at least one
    element to rotate.
    """
    if isinstance(amount, Call) and amount.has_head("List"):
        amounts: list[int] = []
        for argument in amount.arguments:
            amounts.append(_normalize_integer_argument(argument, "RotateLeft"))
        return _rotate_per_axis(expr, amounts, "RotateLeft")

    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            return _association_expr(entries)
        count = len(entries)
        offset = _normalize_integer_argument(amount, "RotateLeft") % count
        if offset == 0:
            return _association_expr(entries)
        return _association_expr(entries[offset:] + entries[:offset])

    compound = _require_compound(expr, "RotateLeft")
    if not compound.arguments:
        return compound

    count = len(compound.arguments)
    offset = _normalize_integer_argument(amount, "RotateLeft") % count
    if offset == 0:
        return compound
    return _rebuild(compound, compound.arguments[offset:] + compound.arguments[:offset])


def rotate_right(expr: Expr, amount: Expr | int = 1) -> Expr:
    if isinstance(amount, Call) and amount.has_head("List"):
        amounts: list[int] = []
        for argument in amount.arguments:
            amounts.append(-_normalize_integer_argument(argument, "RotateRight"))
        return _rotate_per_axis(expr, amounts, "RotateRight")
    return rotate_left(expr, -_normalize_integer_argument(amount, "RotateRight"))


def _rotate_per_axis(expr: Expr, amounts: Sequence[int], function_name: str) -> Expr:
    """Apply per-axis left rotations recursively.

    The first amount rotates the outer ``List`` (or association) left
    by that many positions. Remaining amounts apply to every child of
    the resulting outer expression. Tungsten requires every level
    consumed by ``amounts`` to be a list-shaped expression — empty
    levels are returned unchanged.
    """
    if not amounts:
        return expr
    head_amount = amounts[0]
    rest = amounts[1:]
    entries = _association_entries(expr)
    if entries is not None:
        rotated = rotate_left(expr, head_amount)
        if not rest:
            return rotated
        rotated_entries = _association_entries(rotated) or ()
        new_entries = [
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_rotate_per_axis(entry.value, rest, function_name),
            )
            for entry in rotated_entries
        ]
        return _association_expr(new_entries)
    compound = _require_compound(expr, function_name)
    rotated = rotate_left(expr, head_amount)
    if not rest:
        return rotated
    if not (isinstance(rotated, Call) and rotated.has_head(compound.head_expr.name if isinstance(compound.head_expr, Symbol) else "List")):
        return rotated
    new_children = [_rotate_per_axis(child, rest, function_name) for child in rotated.arguments]
    return _rebuild(rotated, new_children)


def flatten(expr: Expr, level_spec: Expr | int | None = None, head_spec: Expr | None = None) -> Expr:
    """``Flatten[expr]`` / ``Flatten[expr, n]`` / ``Flatten[expr, n, h]``.

    The 3-arg form flattens nested ``h``-headed subexpressions instead of
    matching the outer expression's head. ``n`` may be ``Infinity`` (no
    depth cap) or a non-negative integer.
    """
    if isinstance(expr, SparseArrayExpr):
        if head_spec is not None:
            raise WolframEvaluationError(
                "Flatten currently does not implement the 3-argument head-selecting form for SparseArray inputs."
            )
        return _sparse_array_flatten(expr, level_spec)
    compound = _require_compound(expr, "Flatten")
    max_depth = _normalize_flatten_level(level_spec)
    if max_depth == 0:
        return compound
    if head_spec is None:
        return _flatten_same_head(compound, max_depth)
    return _flatten_named_head(compound, head_spec, max_depth)


def _flatten_named_head(expr: Call, target_head: Expr, remaining: int | None) -> Expr:
    """Flatten nested calls whose head equals ``target_head`` while
    keeping the outer head intact. Mirrors ``Flatten[expr, n, h]``.
    """
    if remaining == 0:
        return expr

    arguments: list[Expr] = []
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == target_head:
            nested = _flatten_named_head(argument, target_head, None if remaining is None else remaining - 1)
            assert isinstance(nested, Call)
            arguments.extend(nested.arguments)
            continue
        if isinstance(argument, Call):
            arguments.append(_flatten_named_head(argument, target_head, remaining))
        else:
            arguments.append(argument)
    return _rebuild(expr, arguments)


def array_depth(expr: Expr) -> Expr:
    return integer(_array_depth_value(expr))


def _array_depth_value(expr: Expr) -> int:
    if isinstance(expr, SparseArrayExpr):
        return len(expr.dimensions)
    if isinstance(expr, Call) and expr.has_head("List"):
        if not expr.arguments:
            return 1
        return 1 + max(_array_depth_value(argument) for argument in expr.arguments)
    return 0


def array_q(expr: Expr, depth_expr: Expr | None = None, test: Expr | None = None) -> Expr:
    try:
        dimensions = expr.dimensions if isinstance(expr, SparseArrayExpr) else _strict_dense_dimensions(expr)
    except WolframEvaluationError:
        return _bool_symbol(False)

    if not dimensions:
        return _bool_symbol(False)

    if depth_expr is not None:
        if not isinstance(depth_expr, Integer):
            raise WolframEvaluationError("ArrayQ currently expects an explicit integer depth.")
        if len(dimensions) != depth_expr.value:
            return _bool_symbol(False)

    if test is None:
        return _bool_symbol(True)

    if isinstance(expr, SparseArrayExpr):
        total_size = math.prod(dimensions)
        if len(expr.entries) < total_size and not _predicate_succeeds(test, expr.fill_value):
            return _bool_symbol(False)
        return _bool_symbol(all(_predicate_succeeds(test, entry.value) for entry in expr.entries))

    return _bool_symbol(all(_predicate_succeeds(test, value) for value in _dense_leaf_values(expr)))


def _dense_leaf_values(expr: Expr) -> tuple[Expr, ...]:
    if isinstance(expr, Call) and expr.has_head("List"):
        values: list[Expr] = []
        for argument in expr.arguments:
            values.extend(_dense_leaf_values(argument))
        return tuple(values)
    return (expr,)


def _array_dimensions(expr: Expr, function_name: str) -> tuple[int, ...]:
    if isinstance(expr, SparseArrayExpr):
        return expr.dimensions
    dimensions = _strict_dense_dimensions(expr)
    if not dimensions:
        raise WolframEvaluationError(f"{function_name} expects a rectangular array.")
    return dimensions


def _array_indices(dimensions: Sequence[int]) -> Iterable[tuple[int, ...]]:
    return itertools.product(*(range(1, dimension + 1) for dimension in dimensions))


def _array_linear_index(indices: Sequence[int], dimensions: Sequence[int]) -> int:
    linear = 0
    for index, dimension in zip(indices, dimensions, strict=True):
        linear = linear * dimension + (index - 1)
    return linear


def _array_indices_from_linear(linear: int, dimensions: Sequence[int]) -> tuple[int, ...]:
    if not dimensions:
        return ()
    result = [1] * len(dimensions)
    remaining = linear
    for axis in range(len(dimensions) - 1, -1, -1):
        dimension = dimensions[axis]
        remaining, offset = divmod(remaining, dimension)
        result[axis] = offset + 1
    return tuple(result)


def _array_value_at(expr: Expr, indices: Sequence[int]) -> Expr:
    if isinstance(expr, SparseArrayExpr):
        return _sparse_array_value_at(expr, indices)
    current = expr
    for index in indices:
        if not isinstance(current, Call) or not current.has_head("List"):
            raise WolframEvaluationError("Expected a rectangular List array.")
        current = current.arguments[index - 1]
    return current


def _build_dense_array(dimensions: Sequence[int], builder: Callable[[tuple[int, ...]], Expr]) -> Expr:
    return _build_array_from_dimensions(dimensions, builder)


def _sparse_array_flatten(array: SparseArrayExpr, level_spec: Expr | int | None = None) -> Expr:
    level = _normalize_flatten_level(level_spec)
    rank = len(array.dimensions)
    if level == 0 or rank <= 1:
        return array

    if level is None:
        collapse_count = rank
    else:
        collapse_count = min(rank, level + 1)
    new_dimensions = (math.prod(array.dimensions[:collapse_count]), *array.dimensions[collapse_count:])

    entries: list[_SparseArrayEntry] = []
    collapsed_dimensions = array.dimensions[:collapse_count]
    for entry in array.entries:
        collapsed_index = _array_linear_index(entry.indices[:collapse_count], collapsed_dimensions) + 1
        entries.append(_SparseArrayEntry((collapsed_index, *entry.indices[collapse_count:]), entry.value))
    return _sparse_array_expr(new_dimensions, entries, array.fill_value)


def array_reshape(expr: Expr, dimensions_expr: Expr | int, padding: Expr | None = None) -> Expr:
    dimensions = tuple(_normalize_dimensions(dimensions_expr, "ArrayReshape"))
    fill = integer(0) if padding is None else padding

    if isinstance(expr, SparseArrayExpr):
        return _sparse_array_reshape(expr, dimensions, fill)

    values = _dense_leaf_values(expr)
    total_size = math.prod(dimensions) if dimensions else 1

    def value_at(indices: tuple[int, ...]) -> Expr:
        linear = _array_linear_index(indices, dimensions) if dimensions else 0
        return values[linear] if linear < len(values) else fill

    if not dimensions:
        return values[0] if values else fill
    return _build_dense_array(dimensions, value_at)


def _sparse_array_reshape(array: SparseArrayExpr, dimensions: Sequence[int], fill: Expr) -> Expr:
    old_total = math.prod(array.dimensions)
    new_total = math.prod(dimensions) if dimensions else 1
    if not dimensions:
        if old_total == 0:
            return fill
        return _sparse_array_value_at(array, _array_indices_from_linear(0, array.dimensions))

    can_preserve_sparse = new_total <= old_total or array.fill_value == fill
    if not can_preserve_sparse:
        return array_reshape(sparse_array_normal(array), list_expr(*(integer(dimension) for dimension in dimensions)), fill)

    output_fill = array.fill_value if new_total <= old_total else fill
    entries: list[_SparseArrayEntry] = []
    for entry in array.entries:
        linear = _array_linear_index(entry.indices, array.dimensions)
        if linear >= new_total:
            continue
        entries.append(_SparseArrayEntry(_array_indices_from_linear(linear, dimensions), entry.value))
    return _sparse_array_expr(dimensions, entries, output_fill)


def _normalize_array_padding(padding_expr: Expr | int, rank: int) -> list[tuple[int, int]]:
    if isinstance(padding_expr, int):
        if padding_expr < 0:
            raise WolframEvaluationError("ArrayPad expects non-negative padding widths.")
        return [(padding_expr, padding_expr)] * rank
    if isinstance(padding_expr, Integer):
        return _normalize_array_padding(padding_expr.value, rank)
    if isinstance(padding_expr, Call) and padding_expr.has_head("List"):
        if rank == 1 and len(padding_expr.arguments) == 2 and all(isinstance(item, Integer) for item in padding_expr.arguments):
            left = padding_expr.arguments[0].value  # type: ignore[union-attr]
            right = padding_expr.arguments[1].value  # type: ignore[union-attr]
            if left < 0 or right < 0:
                raise WolframEvaluationError("ArrayPad expects non-negative padding widths.")
            return [(left, right)]
        if len(padding_expr.arguments) == rank and all(isinstance(item, Integer) for item in padding_expr.arguments):
            widths = [item.value for item in padding_expr.arguments if isinstance(item, Integer)]
            if any(width < 0 for width in widths):
                raise WolframEvaluationError("ArrayPad expects non-negative padding widths.")
            return [(width, width) for width in widths]
        if len(padding_expr.arguments) == rank:
            pairs: list[tuple[int, int]] = []
            for item in padding_expr.arguments:
                if not isinstance(item, Call) or not item.has_head("List") or len(item.arguments) != 2:
                    raise WolframEvaluationError("ArrayPad expects padding widths as p, {p1, ...}, or {{l1, r1}, ...}.")
                if not all(isinstance(part, Integer) for part in item.arguments):
                    raise WolframEvaluationError("ArrayPad padding widths must be explicit integers.")
                left = item.arguments[0].value  # type: ignore[union-attr]
                right = item.arguments[1].value  # type: ignore[union-attr]
                if left < 0 or right < 0:
                    raise WolframEvaluationError("ArrayPad expects non-negative padding widths.")
                pairs.append((left, right))
            return pairs
    raise WolframEvaluationError("ArrayPad expects padding widths as p, {p1, ...}, or {{l1, r1}, ...}.")


def array_pad(expr: Expr, padding_expr: Expr | int, padding_value: Expr | None = None) -> Expr:
    dimensions = _array_dimensions(expr, "ArrayPad")
    widths = _normalize_array_padding(padding_expr, len(dimensions))
    fill = integer(0) if padding_value is None else padding_value
    new_dimensions = tuple(dimension + left + right for dimension, (left, right) in zip(dimensions, widths, strict=True))
    left_offsets = tuple(left for left, _right in widths)

    if isinstance(expr, SparseArrayExpr):
        if fill == expr.fill_value:
            return _sparse_array_expr(
                new_dimensions,
                (
                    _SparseArrayEntry(
                        tuple(index + offset for index, offset in zip(entry.indices, left_offsets, strict=True)),
                        entry.value,
                    )
                    for entry in expr.entries
                ),
                expr.fill_value,
            )
        return array_pad(sparse_array_normal(expr), padding_expr, fill)

    def value_at(indices: tuple[int, ...]) -> Expr:
        source_indices: list[int] = []
        for index, dimension, (left, _right) in zip(indices, dimensions, widths, strict=True):
            source_index = index - left
            if source_index < 1 or source_index > dimension:
                return fill
            source_indices.append(source_index)
        return _array_value_at(expr, source_indices)

    return _build_dense_array(new_dimensions, value_at)


def array_flatten(expr: Expr) -> Expr:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        raise WolframEvaluationError("ArrayFlatten expects a rectangular list of array blocks.")
    block_rows: list[tuple[Expr, ...]] = []
    for row in expr.arguments:
        if not isinstance(row, Call) or not row.has_head("List"):
            raise WolframEvaluationError("ArrayFlatten expects a rectangular list of array blocks.")
        block_rows.append(row.arguments)
    if not block_rows:
        return _evaluated_list_expr()
    column_count = len(block_rows[0])
    if column_count == 0 or any(len(row) != column_count for row in block_rows):
        raise WolframEvaluationError("ArrayFlatten expects a rectangular block matrix.")

    block_shapes: list[list[tuple[int, int]]] = []
    any_sparse = False
    for row in block_rows:
        shape_row: list[tuple[int, int]] = []
        for block in row:
            if isinstance(block, SparseArrayExpr):
                if len(block.dimensions) != 2:
                    raise WolframEvaluationError("ArrayFlatten currently expects rank-2 SparseArray blocks.")
                if block.fill_value != integer(0):
                    return array_flatten(_blocks_to_dense_expr(block_rows))
                any_sparse = True
                shape_row.append((block.dimensions[0], block.dimensions[1]))
                continue
            dimensions = _strict_dense_dimensions(block)
            if len(dimensions) != 2:
                raise WolframEvaluationError("ArrayFlatten currently expects rank-2 array blocks.")
            shape_row.append((dimensions[0], dimensions[1]))
        block_shapes.append(shape_row)

    row_heights: list[int] = []
    for row_index, shape_row in enumerate(block_shapes):
        height = shape_row[0][0]
        if any(shape[0] != height for shape in shape_row):
            raise WolframEvaluationError(f"ArrayFlatten block row {row_index + 1} has inconsistent heights.")
        row_heights.append(height)

    column_widths: list[int] = []
    for column_index in range(column_count):
        width = block_shapes[0][column_index][1]
        if any(shape_row[column_index][1] != width for shape_row in block_shapes):
            raise WolframEvaluationError(f"ArrayFlatten block column {column_index + 1} has inconsistent widths.")
        column_widths.append(width)

    output_dimensions = (sum(row_heights), sum(column_widths))
    if any_sparse:
        entries: list[_SparseArrayEntry] = []
        row_offset = 0
        for block_row, height in zip(block_rows, row_heights, strict=True):
            column_offset = 0
            for block, width in zip(block_row, column_widths, strict=True):
                entries.extend(_array_flatten_block_entries(block, row_offset, column_offset))
                column_offset += width
            row_offset += height
        return _sparse_array_expr(output_dimensions, entries, integer(0))

    rows: list[Expr] = []
    for block_row, height in zip(block_rows, row_heights, strict=True):
        for local_row in range(1, height + 1):
            row_values: list[Expr] = []
            for block in block_row:
                assert isinstance(block, Call)
                block_row_expr = block.arguments[local_row - 1]
                assert isinstance(block_row_expr, Call)
                row_values.extend(block_row_expr.arguments)
            rows.append(_evaluated_list_expr(*row_values))
    return _evaluated_list_expr(*rows)


def _blocks_to_dense_expr(block_rows: Sequence[Sequence[Expr]]) -> Expr:
    return _evaluated_list_expr(*(
        _evaluated_list_expr(*(sparse_array_normal(block) if isinstance(block, SparseArrayExpr) else block for block in row))
        for row in block_rows
    ))


def _array_flatten_block_entries(block: Expr, row_offset: int, column_offset: int) -> list[_SparseArrayEntry]:
    entries: list[_SparseArrayEntry] = []
    if isinstance(block, SparseArrayExpr):
        for entry in block.entries:
            entries.append(_SparseArrayEntry((row_offset + entry.indices[0], column_offset + entry.indices[1]), entry.value))
        return entries
    dimensions = _strict_dense_dimensions(block)
    for row, column in _array_indices(dimensions):
        value = _array_value_at(block, (row, column))
        if value != integer(0):
            entries.append(_SparseArrayEntry((row_offset + row, column_offset + column), value))
    return entries


def _normalize_transpose_permutation(rank: int, permutation_expr: Expr | None) -> tuple[int, ...]:
    if rank < 2 and permutation_expr is None:
        return tuple(range(rank))
    if permutation_expr is None:
        return (1, 0, *range(2, rank))
    if not isinstance(permutation_expr, Call) or not permutation_expr.has_head("List"):
        raise WolframEvaluationError("Transpose expects a permutation list as its second argument.")
    if len(permutation_expr.arguments) != rank or not all(isinstance(item, Integer) for item in permutation_expr.arguments):
        raise WolframEvaluationError("Transpose permutation length must match the array rank.")
    permutation = tuple(item.value - 1 for item in permutation_expr.arguments if isinstance(item, Integer))
    if sorted(permutation) != list(range(rank)):
        raise WolframEvaluationError("Transpose expects a permutation of array axes.")
    return permutation


def transpose(expr: Expr, permutation_expr: Expr | None = None) -> Expr:
    dimensions = _array_dimensions(expr, "Transpose")
    permutation = _normalize_transpose_permutation(len(dimensions), permutation_expr)
    if permutation == tuple(range(len(dimensions))):
        return expr
    new_dimensions = tuple(dimensions[axis] for axis in permutation)

    if isinstance(expr, SparseArrayExpr):
        return _sparse_array_expr(
            new_dimensions,
            (
                _SparseArrayEntry(tuple(entry.indices[axis] for axis in permutation), entry.value)
                for entry in expr.entries
            ),
            expr.fill_value,
        )

    def value_at(indices: tuple[int, ...]) -> Expr:
        source_indices = [0] * len(dimensions)
        for output_axis, source_axis in enumerate(permutation):
            source_indices[source_axis] = indices[output_axis]
        return _array_value_at(expr, source_indices)

    return _build_dense_array(new_dimensions, value_at)


def delete(expr: Expr, positions: Expr | int) -> Expr:
    paths, invalid = _expand_operation_paths(expr, integer(positions) if isinstance(positions, int) else positions)
    unique_paths = _dedupe_paths(paths)
    if invalid or any(not path for path in unique_paths):
        raise WolframEvaluationError(f"Delete positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(unique_paths):
        result, changed = _try_delete_at_path(result, path)
        if not changed:
            raise WolframEvaluationError(f"Delete positions are invalid for {expr.to_input_form()}.")
    return result


def replace_part(expr: Expr, replacements: Expr) -> Expr:
    rules = _normalize_replace_part_rules(replacements)
    planned: list[tuple[list[_IndexSelector | _KeySelector], Expr]] = []
    seen_paths: set[tuple[_IndexSelector | _KeySelector, ...]] = set()

    for position_spec, replacement in rules:
        paths, _invalid = _expand_operation_paths(expr, position_spec)
        for path in paths:
            key = tuple(path)
            if key in seen_paths:
                continue
            seen_paths.add(key)
            planned.append((path, replacement))

    result = expr
    for path, replacement in _sort_path_items(planned):
        result, _changed = _try_replace_at_path(result, path, replacement)
    return result


def insert(expr: Expr, item: Expr, positions: Expr | int) -> Expr:
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) == 1 and isinstance(positions, (Integer, int)):
            return _sparse_vector_insert(expr, item, _normalize_integer_argument(positions, "Insert"))
        return insert(sparse_array_normal(expr), item, positions)

    paths = _insert_paths(positions)
    result = expr
    for path in _sort_paths(paths):
        result, changed = _try_insert_at_path(result, path, item)
        if not changed:
            raise WolframEvaluationError(f"Insert positions are invalid for {expr.to_input_form()}.")
    return result


def _insert_paths(positions: Expr | int) -> list[list[_IndexSelector]]:
    if isinstance(positions, int):
        return [[_IndexSelector(positions)]]
    if isinstance(positions, Integer):
        return [[_IndexSelector(positions.value)]]
    if isinstance(positions, Call) and positions.has_head("List"):
        if all(isinstance(item, Integer) for item in positions.arguments):
            return [[_IndexSelector(item.value) for item in positions.arguments if isinstance(item, Integer)]]
        paths: list[list[_IndexSelector]] = []
        for item in positions.arguments:
            if not isinstance(item, Call) or not item.has_head("List") or not all(isinstance(part, Integer) for part in item.arguments):
                raise WolframEvaluationError("Insert expects an integer position, a position list, or a list of position lists.")
            paths.append([_IndexSelector(part.value) for part in item.arguments if isinstance(part, Integer)])
        return paths
    raise WolframEvaluationError("Insert expects an integer position, a position list, or a list of position lists.")


def _insert_offset(length_value: int, index: int) -> int | None:
    if index == 0:
        return 0
    if index > 0:
        offset = index - 1
    else:
        offset = length_value + index + 1
    if 0 <= offset <= length_value:
        return offset
    return None


def _try_insert_at_path(expr: Expr, path: Sequence[_IndexSelector], item: Expr) -> tuple[Expr, bool]:
    if not path:
        return (expr, False)
    if not isinstance(expr, Call):
        return (expr, False)

    selector = path[0]
    if len(path) == 1:
        offset = _insert_offset(len(expr.arguments), selector.index)
        if offset is None:
            return (expr, False)
        arguments = list(expr.arguments)
        arguments.insert(offset, item)
        return (_rebuild(expr, arguments), True)

    resolved = _try_resolve_index(len(expr.arguments), selector.index)
    if resolved is None:
        return (expr, False)
    arguments = list(expr.arguments)
    updated_child, changed = _try_insert_at_path(arguments[resolved], path[1:], item)
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _sparse_vector_insert(array: SparseArrayExpr, item: Expr, index: int) -> Expr:
    length_value = array.dimensions[0]
    offset = _insert_offset(length_value, index)
    if offset is None:
        raise WolframEvaluationError("Insert position is invalid for SparseArray.")
    inserted_index = offset + 1
    entries: list[_SparseArrayEntry] = []
    for entry in array.entries:
        source_index = entry.indices[0]
        target_index = source_index + 1 if source_index >= inserted_index else source_index
        entries.append(_SparseArrayEntry((target_index,), entry.value))
    if item != array.fill_value:
        entries.append(_SparseArrayEntry((inserted_index,), item))
    return _sparse_array_expr((length_value + 1,), entries, array.fill_value)


def flatten_at(expr: Expr, positions: Expr | int) -> Expr:
    if isinstance(expr, SparseArrayExpr):
        return flatten_at(sparse_array_normal(expr), positions)
    paths, invalid = _expand_operation_paths(expr, integer(positions) if isinstance(positions, int) else positions)
    unique_paths = _dedupe_paths(paths)
    if invalid or any(not path for path in unique_paths):
        raise WolframEvaluationError(f"FlattenAt positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(unique_paths):
        result, changed = _try_flatten_at_path(result, path)
        if not changed:
            raise WolframEvaluationError(f"FlattenAt positions are invalid for {expr.to_input_form()}.")
    return result


def _try_flatten_at_path(expr: Expr, path: Sequence[_IndexSelector | _KeySelector]) -> tuple[Expr, bool]:
    if not path or not isinstance(expr, Call):
        return (expr, False)
    selector = path[0]
    if not isinstance(selector, _IndexSelector):
        return (expr, False)
    resolved = selector.index - 1
    if not 0 <= resolved < len(expr.arguments):
        return (expr, False)
    arguments = list(expr.arguments)
    if len(path) == 1:
        target = arguments[resolved]
        if not isinstance(target, Call):
            return (expr, False)
        arguments[resolved:resolved + 1] = list(target.arguments)
        return (_rebuild(expr, arguments), True)
    updated_child, changed = _try_flatten_at_path(arguments[resolved], path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def split(expr: Expr, test: Expr | None = None) -> Expr:
    values = _sequence_values(expr, "Split")
    if not values:
        return _evaluated_list_expr()
    groups: list[list[Expr]] = [[values[0]]]
    for value in values[1:]:
        if _duplicate_test_succeeds(test, groups[-1][-1], value):
            groups[-1].append(value)
        else:
            groups.append([value])
    return _evaluated_list_expr(*(_evaluated_list_expr(*group) for group in groups))


def split_by(expr: Expr, function: Expr) -> Expr:
    values = _sequence_values(expr, "SplitBy")
    if not values:
        return _evaluated_list_expr()
    groups: list[list[Expr]] = [[values[0]]]
    previous_key = evaluate(_apply_callable(function, (values[0],)))
    for value in values[1:]:
        key = evaluate(_apply_callable(function, (value,)))
        if key == previous_key:
            groups[-1].append(value)
        else:
            groups.append([value])
            previous_key = key
    return _evaluated_list_expr(*(_evaluated_list_expr(*group) for group in groups))


def delete_adjacent_duplicates(expr: Expr, test: Expr | None = None) -> Expr:
    values = _sequence_values(expr, "DeleteAdjacentDuplicates")
    if not values:
        return _evaluated_list_expr()
    kept = [values[0]]
    for value in values[1:]:
        if not _duplicate_test_succeeds(test, kept[-1], value):
            kept.append(value)
    return _evaluated_list_expr(*kept)


def subsequences(expr: Expr, spec: Expr | None = None) -> Expr:
    values = _sequence_values(expr, "Subsequences")
    count = len(values)
    if spec is None:
        bounds = (1, count)
    elif isinstance(spec, Integer):
        bounds = (1, spec.value)
    elif isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1 and isinstance(spec.arguments[0], Integer):
            target = spec.arguments[0].value
            bounds = (target, target)
        elif len(spec.arguments) == 2 and isinstance(spec.arguments[0], Integer) and isinstance(spec.arguments[1], Integer):
            bounds = (spec.arguments[0].value, spec.arguments[1].value)
        else:
            raise WolframEvaluationError("Subsequences currently supports n, {n}, or {min, max} length specs.")
    else:
        raise WolframEvaluationError("Subsequences expects an integer count or a length specification list.")

    lower = max(bounds[0], 0)
    upper = min(max(bounds[1], -1), count)
    output: list[Expr] = []
    for length_value in range(lower, upper + 1):
        if length_value == 0:
            output.append(_evaluated_list_expr())
            continue
        for start in range(0, count - length_value + 1):
            output.append(_evaluated_list_expr(*values[start:start + length_value]))
    return _evaluated_list_expr(*output)


def _is_function_expr(expr: Expr) -> bool:
    return isinstance(expr, Call) and expr.has_head("Function")


def _is_positional_pure_function_expr(expr: Expr) -> bool:
    if not _is_function_expr(expr):
        return False
    assert isinstance(expr, Call)
    if len(expr.arguments) == 1:
        return True
    if len(expr.arguments) in {2, 3} and isinstance(expr.arguments[0], Symbol):
        return _system_dispatch_name(expr.arguments[0]) == "Null"
    return False


def _named_function_parameter_symbols(expr: Expr) -> tuple[Symbol, ...] | None:
    if not _is_function_expr(expr):
        return None

    assert isinstance(expr, Call)
    if len(expr.arguments) not in {2, 3}:
        return None

    parameter_expr = expr.arguments[0]
    if isinstance(parameter_expr, Symbol):
        if _system_dispatch_name(parameter_expr) == "Null":
            return None
        return (parameter_expr,)

    if isinstance(parameter_expr, Call) and parameter_expr.has_head("List") and all(
        isinstance(argument, Symbol)
        for argument in parameter_expr.arguments
    ):
        return tuple(parameter_expr.arguments)

    return None


def _is_named_pure_function_expr(expr: Expr) -> bool:
    return _named_function_parameter_symbols(expr) is not None


def _is_pure_function_expr(expr: Expr) -> bool:
    return _is_positional_pure_function_expr(expr) or _is_named_pure_function_expr(expr)


def _named_function_body(expr: Call) -> Expr:
    return expr.arguments[1]


def _positional_function_body(expr: Call) -> Expr:
    if len(expr.arguments) == 1:
        return expr.arguments[0]
    if len(expr.arguments) in {2, 3} and isinstance(expr.arguments[0], Symbol):
        if _system_dispatch_name(expr.arguments[0]) == "Null":
            return expr.arguments[1]
    raise WolframEvaluationError("Expected a positional pure Function expression.")


def _function_attribute_expr(function: Call) -> Expr | None:
    if len(function.arguments) == 3:
        return function.arguments[2]
    return None


def _function_attribute_names(function: Expr) -> set[str]:
    if not isinstance(function, Call) or not _is_function_expr(function):
        return set()
    attrs = _function_attribute_expr(function)
    if attrs is None:
        return set()
    if isinstance(attrs, Symbol):
        return {_system_dispatch_name(attrs)}
    if isinstance(attrs, Call) and attrs.has_head("List"):
        names: set[str] = set()
        for argument in attrs.arguments:
            if not isinstance(argument, Symbol):
                raise WolframEvaluationError("Function attributes must be symbols or a list of symbols.")
            names.add(_system_dispatch_name(argument))
        return names
    raise WolframEvaluationError("Function attributes must be a symbol or a list of symbols.")


def _rebuild_named_parameter_expr(original: Expr, parameters: Sequence[Symbol]) -> Expr:
    if isinstance(original, Symbol):
        if len(parameters) != 1:
            raise WolframEvaluationError("Function with a single-symbol parameter specification expects exactly one parameter.")
        return parameters[0]
    if isinstance(original, Call) and original.has_head("List"):
        return list_expr(*parameters)
    raise WolframEvaluationError("Unsupported named Function parameter specification.")


def _rebuild_named_function(function: Call, parameters: Sequence[Symbol], body: Expr) -> Call:
    rebuilt_arguments: list[Expr] = [
        _rebuild_named_parameter_expr(function.arguments[0], parameters),
        body,
    ]
    if len(function.arguments) == 3:
        rebuilt_arguments.append(function.arguments[2])
    return Call(head_expr=function.head_expr, arguments=tuple(rebuilt_arguments))


def _collect_symbol_names(expr: Expr, target: set[str]) -> None:
    if isinstance(expr, Symbol):
        target.add(expr.name)
        return

    if isinstance(expr, Call):
        _collect_symbol_names(expr.head_expr, target)
        for argument in expr.arguments:
            _collect_symbol_names(argument, target)


def _fresh_symbol_name(base_name: str, unavailable_names: set[str]) -> str:
    candidate = f"{base_name}$"
    if candidate not in unavailable_names:
        unavailable_names.add(candidate)
        return candidate

    index = 1
    while True:
        candidate = f"{base_name}${index}"
        if candidate not in unavailable_names:
            unavailable_names.add(candidate)
            return candidate
        index += 1


def _fresh_parameter_symbols(
    parameters: Sequence[Symbol],
    unavailable_names: set[str],
) -> tuple[tuple[Symbol, ...], dict[str, Symbol]]:
    fresh_parameters: list[Symbol] = []
    rename_map: dict[str, Symbol] = {}
    for parameter in parameters:
        fresh_symbol = symbol(_fresh_symbol_name(parameter.name, unavailable_names))
        fresh_parameters.append(fresh_symbol)
        rename_map[parameter.name] = fresh_symbol
    return tuple(fresh_parameters), rename_map


def _rename_bound_symbols_in_expr(expr: Expr, rename_map: dict[str, Symbol]) -> Expr:
    if not rename_map:
        return expr

    if isinstance(expr, Symbol):
        return rename_map.get(expr.name, expr)

    if isinstance(expr, (Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    scoping_info = _local_scoping_call_info(expr)
    if scoping_info is not None:
        head_symbol, bound_symbols, binding_arguments, body = scoping_info
        shadowed_names = {parameter.name for parameter in bound_symbols}
        nested_rename_map = {
            name: replacement
            for name, replacement in rename_map.items()
            if name not in shadowed_names
        }
        if not nested_rename_map and not (set(rename_map) & shadowed_names):
            # Nothing the inner scope would observe.
            return expr
        # Binding RHS values are evaluated in the outer scope, so they get
        # the unfiltered rename map. The body sees only the filtered map
        # because inner bindings shadow.
        renamed_binding_arguments: list[Expr] = []
        for binding in binding_arguments:
            if isinstance(binding, Symbol):
                renamed_binding_arguments.append(binding)
                continue
            assert isinstance(binding, Call)
            renamed_value = _rename_bound_symbols_in_expr(binding.arguments[1], rename_map)
            renamed_binding_arguments.append(
                Call(head_expr=binding.head_expr, arguments=(binding.arguments[0], renamed_value))
            )
        renamed_body = _rename_bound_symbols_in_expr(body, nested_rename_map)
        renamed_bindings_list = Call(
            head_expr=Symbol("List"), arguments=tuple(renamed_binding_arguments)
        )
        return Call(head_expr=expr.head_expr, arguments=(renamed_bindings_list, renamed_body))

    inner_parameters = _named_function_parameter_symbols(expr)
    if inner_parameters is not None:
        assert isinstance(expr, Call)
        shadowed_names = {parameter.name for parameter in inner_parameters}
        nested_rename_map = {
            name: replacement
            for name, replacement in rename_map.items()
            if name not in shadowed_names
        }
        if not nested_rename_map:
            return expr
        renamed_body = _rename_bound_symbols_in_expr(_named_function_body(expr), nested_rename_map)
        return _rebuild_named_function(expr, inner_parameters, renamed_body)

    renamed_head = _rename_bound_symbols_in_expr(expr.head_expr, rename_map)
    renamed_arguments = tuple(
        _rename_bound_symbols_in_expr(argument, rename_map)
        for argument in expr.arguments
    )
    return Call(head_expr=renamed_head, arguments=renamed_arguments)


_LOCAL_SCOPING_HEAD_NAMES = frozenset({"With", "Module", "Block"})


def _local_scoping_call_info(
    expr: Expr,
) -> tuple[Symbol, tuple[Symbol, ...], tuple[Expr, ...], Expr] | None:
    """If ``expr`` is a recognized ``With`` / ``Module`` / ``Block`` call,
    return ``(head_symbol, bound_symbols, binding_arguments, body)``.

    ``bound_symbols`` is the ordered tuple of inner-bound parameter symbols
    (one per binding). ``binding_arguments`` is the original list of binding
    expressions exactly as they appeared in the call's first argument
    (``Set[name, value]`` / ``SetDelayed[name, value]`` / bare ``Symbol``
    for the Module/Block "no init" form). ``body`` is the second argument.

    Returns ``None`` for any malformed shape so callers fall back to the
    default substitute-everywhere recursion.
    """
    if not isinstance(expr, Call):
        return None
    if len(expr.arguments) != 2:
        return None
    head = expr.head_expr
    if not isinstance(head, Symbol):
        return None
    if _system_dispatch_name(head) not in _LOCAL_SCOPING_HEAD_NAMES:
        return None

    bindings_expr = expr.arguments[0]
    if not (isinstance(bindings_expr, Call) and bindings_expr.has_head("List")):
        return None

    bound_symbols: list[Symbol] = []
    for binding in bindings_expr.arguments:
        if isinstance(binding, Symbol):
            bound_symbols.append(binding)
            continue
        if isinstance(binding, Call) and (binding.has_head("Set") or binding.has_head("SetDelayed")):
            if len(binding.arguments) != 2:
                return None
            name = binding.arguments[0]
            if not isinstance(name, Symbol):
                return None
            bound_symbols.append(name)
            continue
        return None

    return head, tuple(bound_symbols), tuple(bindings_expr.arguments), expr.arguments[1]


def _substitute_named_symbols_in_expr(
    expr: Expr,
    substitutions: dict[str, Expr],
    unavailable_names: set[str],
) -> tuple[Expr, bool]:
    if not substitutions:
        return expr, False

    if isinstance(expr, Symbol):
        replacement = substitutions.get(expr.name)
        if replacement is None:
            return expr, False
        return replacement, True

    if isinstance(expr, (Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr, False

    if not isinstance(expr, Call):
        return expr, False

    scoping_info = _local_scoping_call_info(expr)
    if scoping_info is not None:
        return _substitute_through_local_scoping(expr, scoping_info, substitutions, unavailable_names)

    inner_parameters = _named_function_parameter_symbols(expr)
    if inner_parameters is not None:
        assert isinstance(expr, Call)
        shadowed_names = {parameter.name for parameter in inner_parameters}
        active_substitutions = {
            name: replacement
            for name, replacement in substitutions.items()
            if name not in shadowed_names
        }
        if not active_substitutions:
            return expr, False

        _preview_body, body_changed = _substitute_named_symbols_in_expr(
            _named_function_body(expr),
            active_substitutions,
            unavailable_names | shadowed_names,
        )
        if not body_changed:
            return expr, False

        rename_unavailable = set(unavailable_names)
        _collect_symbol_names(expr.arguments[0], rename_unavailable)
        _collect_symbol_names(_named_function_body(expr), rename_unavailable)
        for replacement in active_substitutions.values():
            _collect_symbol_names(replacement, rename_unavailable)

        fresh_parameters, rename_map = _fresh_parameter_symbols(inner_parameters, rename_unavailable)
        renamed_body = _rename_bound_symbols_in_expr(_named_function_body(expr), rename_map)
        substituted_body, _ = _substitute_named_symbols_in_expr(
            renamed_body,
            active_substitutions,
            unavailable_names | {parameter.name for parameter in fresh_parameters},
        )
        return _rebuild_named_function(expr, fresh_parameters, substituted_body), True

    substituted_head, head_changed = _substitute_named_symbols_in_expr(expr.head_expr, substitutions, unavailable_names)
    changed = head_changed
    substituted_arguments: list[Expr] = []
    for argument in expr.arguments:
        substituted_argument, argument_changed = _substitute_named_symbols_in_expr(argument, substitutions, unavailable_names)
        substituted_arguments.append(substituted_argument)
        changed = changed or argument_changed

    if not changed:
        return expr, False
    return Call(head_expr=substituted_head, arguments=tuple(substituted_arguments)), True


def _substitute_through_local_scoping(
    expr: Call,
    scoping_info: tuple[Symbol, tuple[Symbol, ...], tuple[Expr, ...], Expr],
    substitutions: dict[str, Expr],
    unavailable_names: set[str],
) -> tuple[Expr, bool]:
    """Apply capture-avoiding substitution through a ``With`` / ``Module`` /
    ``Block`` call. Inner-bound names shadow the substitution inside the
    body; binding RHS values still see the full substitution because they
    are evaluated in the outer scope. When an inner-bound name appears
    free in any active substitution value, the inner name is alpha-renamed
    to a fresh symbol throughout the bindings list and body.
    """
    head_symbol, bound_symbols, binding_arguments, body = scoping_info
    bound_names = {parameter.name for parameter in bound_symbols}

    new_binding_arguments: list[Expr] = []
    bindings_changed = False
    for binding in binding_arguments:
        if isinstance(binding, Symbol):
            new_binding_arguments.append(binding)
            continue
        assert isinstance(binding, Call)
        old_value = binding.arguments[1]
        new_value, value_changed = _substitute_named_symbols_in_expr(
            old_value, substitutions, unavailable_names
        )
        bindings_changed = bindings_changed or value_changed
        if value_changed:
            new_binding_arguments.append(
                Call(head_expr=binding.head_expr, arguments=(binding.arguments[0], new_value))
            )
        else:
            new_binding_arguments.append(binding)

    active_substitutions = {
        name: replacement
        for name, replacement in substitutions.items()
        if name not in bound_names
    }

    if not active_substitutions:
        if not bindings_changed:
            return expr, False
        new_bindings_list = Call(
            head_expr=Symbol("List"), arguments=tuple(new_binding_arguments)
        )
        return Call(head_expr=expr.head_expr, arguments=(new_bindings_list, body)), True

    # Decide whether the body would observe any substitution; if not, no
    # alpha-renaming is required and the existing call shape can be reused.
    _preview_body, body_changed = _substitute_named_symbols_in_expr(
        body, active_substitutions, unavailable_names | bound_names
    )

    if not body_changed:
        if not bindings_changed:
            return expr, False
        new_bindings_list = Call(
            head_expr=Symbol("List"), arguments=tuple(new_binding_arguments)
        )
        return Call(head_expr=expr.head_expr, arguments=(new_bindings_list, body)), True

    # Capture-avoiding alpha-rename of inner-bound names that would shadow
    # free variables in the active substitution values.
    rename_unavailable = set(unavailable_names) | bound_names
    for binding in new_binding_arguments:
        _collect_symbol_names(binding, rename_unavailable)
    _collect_symbol_names(body, rename_unavailable)
    for replacement in active_substitutions.values():
        _collect_symbol_names(replacement, rename_unavailable)

    fresh_parameters, rename_map = _fresh_parameter_symbols(bound_symbols, rename_unavailable)

    renamed_binding_arguments: list[Expr] = []
    for binding, fresh_symbol in zip(new_binding_arguments, fresh_parameters, strict=True):
        if isinstance(binding, Symbol):
            renamed_binding_arguments.append(fresh_symbol)
            continue
        assert isinstance(binding, Call)
        renamed_binding_arguments.append(
            Call(head_expr=binding.head_expr, arguments=(fresh_symbol, binding.arguments[1]))
        )

    renamed_body = _rename_bound_symbols_in_expr(body, rename_map)
    substituted_body, _ = _substitute_named_symbols_in_expr(
        renamed_body,
        active_substitutions,
        unavailable_names | {parameter.name for parameter in fresh_parameters},
    )
    new_bindings_list = Call(
        head_expr=Symbol("List"), arguments=tuple(renamed_binding_arguments)
    )
    return Call(head_expr=expr.head_expr, arguments=(new_bindings_list, substituted_body)), True


def _slot_index(expr: Expr) -> int | None:
    if not isinstance(expr, Call) or not expr.has_head("Slot"):
        return None
    if len(expr.arguments) == 0:
        return 1
    if len(expr.arguments) != 1:
        raise WolframEvaluationError("Slot expects zero arguments or a single index.")
    argument = expr.arguments[0]
    if isinstance(argument, Integer):
        return argument.value
    if isinstance(argument, String):
        return None
    raise WolframEvaluationError("Slot expects an integer index or a string name.")


def _named_slot_key(expr: Expr) -> str | None:
    if not isinstance(expr, Call) or not expr.has_head("Slot"):
        return None
    if len(expr.arguments) != 1:
        return None
    argument = expr.arguments[0]
    if isinstance(argument, String):
        return argument.value
    return None


def _slot_sequence_index(expr: Expr) -> int | None:
    if not isinstance(expr, Call) or not expr.has_head("SlotSequence"):
        return None
    if len(expr.arguments) == 0:
        return 1
    if len(expr.arguments) != 1 or not isinstance(expr.arguments[0], Integer):
        raise WolframEvaluationError("SlotSequence expects zero arguments or a single positive integer index.")
    index = expr.arguments[0].value
    if index <= 0:
        raise WolframEvaluationError("SlotSequence indices must be positive integers.")
    return index


def _slot_sequence_values(expr: Expr, arguments: Sequence[Expr]) -> tuple[Expr, ...] | None:
    sequence_index = _slot_sequence_index(expr)
    if sequence_index is None:
        return None
    start = sequence_index - 1
    if start >= len(arguments):
        return ()
    return tuple(arguments[start:])


def _replace_slots_in_expr(expr: Expr, arguments: Sequence[Expr], self_function: Expr) -> Expr:
    slot_index = _slot_index(expr)
    if slot_index is not None:
        if slot_index == 0:
            return self_function
        if slot_index < 0:
            raise WolframEvaluationError("Slot indices must be non-negative integers.")
        if slot_index > len(arguments):
            raise WolframEvaluationError(
                f"Slot {slot_index} cannot be filled from {len(arguments)} argument(s)."
            )
        return arguments[slot_index - 1]

    named_key = _named_slot_key(expr)
    if named_key is not None:
        if not arguments:
            raise WolframEvaluationError(
                f"Named Slot {named_key!r} cannot be filled from zero argument(s)."
            )
        first = arguments[0]
        if _is_association(first):
            return lookup(first, string(named_key))
        # For non-Association arguments, named slots fall back to function-call form
        # ``firstArg["name"]``, mirroring how the kernel surfaces the slot.
        return Call(head_expr=first, arguments=(string(named_key),))

    slot_sequence_values = _slot_sequence_values(expr, arguments)
    if slot_sequence_values is not None:
        return call("Sequence", *slot_sequence_values)

    if isinstance(expr, (Symbol, Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    # Positional slots inside nested positional pure functions belong to the
    # inner function and should remain untouched.
    if _is_positional_pure_function_expr(expr):
        return expr

    replaced_head = _replace_slots_in_expr(expr.head_expr, arguments, self_function)
    replaced_arguments: list[Expr] = []
    for argument in expr.arguments:
        argument_sequence_values = _slot_sequence_values(argument, arguments)
        if argument_sequence_values is not None:
            replaced_arguments.extend(argument_sequence_values)
            continue
        replaced_arguments.append(_replace_slots_in_expr(argument, arguments, self_function))
    return Call(head_expr=replaced_head, arguments=tuple(replaced_arguments))


def _function_holds_argument(attribute_names: set[str], index: int) -> bool:
    return _attributes_hold_argument(attribute_names, index)


def _function_suppresses_sequence_splicing(attribute_names: set[str]) -> bool:
    return _attributes_suppress_sequence_splicing(attribute_names)


def _prepare_pure_function_arguments(function: Expr, raw_arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    attribute_names = _function_attribute_names(function)
    prepared = tuple(
        argument if _function_holds_argument(attribute_names, index) else evaluate(argument)
        for index, argument in enumerate(raw_arguments)
    )
    if not _function_suppresses_sequence_splicing(attribute_names):
        prepared = _splice_sequence_arguments(prepared)
    return prepared


def _listable_argument_rows(arguments: Sequence[Expr]) -> list[tuple[Expr, ...]] | None:
    list_lengths = [
        len(argument.arguments)
        for argument in arguments
        if isinstance(argument, Call) and argument.has_head("List")
    ]
    if not list_lengths:
        return None
    first_length = list_lengths[0]
    if any(length != first_length for length in list_lengths[1:]):
        raise WolframEvaluationError("Listable Function arguments have incompatible list lengths.")
    rows: list[tuple[Expr, ...]] = []
    for index in range(first_length):
        row: list[Expr] = []
        for argument in arguments:
            if isinstance(argument, Call) and argument.has_head("List"):
                row.append(argument.arguments[index])
            else:
                row.append(argument)
        rows.append(tuple(row))
    return rows


def _flatten_flat_arguments(head: Symbol, arguments: Sequence[Expr], attribute_names: set[str]) -> tuple[Expr, ...]:
    if "Flat" not in attribute_names:
        return tuple(arguments)
    flattened: list[Expr] = []
    for argument in arguments:
        if isinstance(argument, Call) and argument.head_expr == head:
            flattened.extend(argument.arguments)
        else:
            flattened.append(argument)
    return tuple(flattened)


def _order_orderless_arguments(arguments: Sequence[Expr], attribute_names: set[str]) -> tuple[Expr, ...]:
    if "Orderless" not in attribute_names:
        return tuple(arguments)
    return tuple(sorted(arguments, key=cmp_to_key(_canonical_compare)))


def _normalize_attribute_call(head: Symbol, arguments: Sequence[Expr]) -> tuple[Expr, ...]:
    attribute_names = _attribute_names_for_symbol(head)
    flattened = _flatten_flat_arguments(head, arguments, attribute_names)
    return _order_orderless_arguments(flattened, attribute_names)


def _thread_listable_symbol_call(head: Symbol, arguments: Sequence[Expr]) -> Expr | None:
    attribute_names = _attribute_names_for_symbol(head)
    if "Listable" not in attribute_names:
        return None
    rows = _listable_argument_rows(arguments)
    if rows is None:
        return None
    return _evaluated_list_expr(*(evaluate(Call(head_expr=head, arguments=row)) for row in rows))


def _apply_pure_function_without_listable(function: Expr, arguments: Sequence[Expr]) -> Expr:
    if not _is_positional_pure_function_expr(function):
        raise WolframEvaluationError("Expected a positional pure Function expression.")
    assert isinstance(function, Call)
    substituted = _replace_slots_in_expr(_positional_function_body(function), arguments, function)
    return evaluate(substituted)


def _apply_named_pure_function_without_listable(function: Expr, arguments: Sequence[Expr]) -> Expr:
    parameter_symbols = _named_function_parameter_symbols(function)
    if parameter_symbols is None:
        raise WolframEvaluationError("Expected a named-parameter Function expression.")

    if len(arguments) < len(parameter_symbols):
        raise WolframEvaluationError(
            f"Function expects {len(parameter_symbols)} named argument(s), but only {len(arguments)} were supplied."
        )

    assert isinstance(function, Call)
    substitutions = {
        parameter.name: arguments[index]
        for index, parameter in enumerate(parameter_symbols)
    }
    unavailable_names = {parameter.name for parameter in parameter_symbols}
    for argument in arguments[:len(parameter_symbols)]:
        _collect_symbol_names(argument, unavailable_names)
    substituted, _ = _substitute_named_symbols_in_expr(
        _named_function_body(function),
        substitutions,
        unavailable_names,
    )
    return evaluate(substituted)


def _apply_pure_function(function: Expr, arguments: Sequence[Expr]) -> Expr:
    attribute_names = _function_attribute_names(function)
    if "Listable" in attribute_names:
        rows = _listable_argument_rows(arguments)
        if rows is not None:
            return _evaluated_list_expr(*(_apply_pure_function(function, row) for row in rows))

    if _is_positional_pure_function_expr(function):
        return _apply_pure_function_without_listable(function, arguments)
    if _is_named_pure_function_expr(function):
        return _apply_named_pure_function_without_listable(function, arguments)
    raise WolframEvaluationError("Unsupported Function parameter specification.")


def _apply_callable(function: Expr, arguments: Sequence[Expr]) -> Expr:
    if _is_pure_function_expr(function):
        return _apply_pure_function(function, arguments)
    if isinstance(function, Call) and function.has_head("SameAs") and len(function.arguments) == 1:
        return same_q(*arguments, function.arguments[0])
    if isinstance(function, Call) and function.has_head("Composition"):
        return composition_apply(function.arguments, arguments)
    if isinstance(function, Call) and function.has_head("RightComposition"):
        return right_composition_apply(function.arguments, arguments)
    if isinstance(function, Call) and function.has_head("Scan"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("Scan[f] expects exactly one argument when used as an operator.")
            return scan(function.arguments[0], arguments[0])
        if len(function.arguments) == 2:
            if len(arguments) != 1:
                raise WolframEvaluationError("Scan[f, levelspec] expects exactly one argument when used as an operator.")
            return scan(function.arguments[0], arguments[0], function.arguments[1])
    if isinstance(function, Call) and function.has_head("MapApply"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("MapApply[f] expects exactly one argument when used as an operator.")
            return map_apply(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("MapAll"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("MapAll[f] expects exactly one argument when used as an operator.")
            return map_all(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("MapIndexed"):
        if len(function.arguments) == 1:
            if len(arguments) != 1:
                raise WolframEvaluationError("MapIndexed[f] expects exactly one argument when used as an operator.")
            return map_indexed(function.arguments[0], arguments[0])
        if len(function.arguments) == 2:
            if len(arguments) != 1:
                raise WolframEvaluationError(
                    "MapIndexed[f, levelspec] expects exactly one argument when used as an operator."
                )
            return map_indexed(function.arguments[0], arguments[0], function.arguments[1])
    if isinstance(function, Call) and function.has_head("KeySelect") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("KeySelect[crit] expects exactly one argument when used as an operator.")
        return key_select(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("Comap") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("Comap[functions] expects exactly one argument when used as an operator.")
        return comap(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("ComapApply") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError(
                "ComapApply[functions] expects exactly one argument when used as an operator."
            )
        return comap_apply(function.arguments[0], arguments[0])
    if isinstance(function, Call) and function.has_head("SortBy") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("SortBy[f] expects exactly one argument when used as an operator.")
        return sort_by(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("ReverseSortBy") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("ReverseSortBy[f] expects exactly one argument when used as an operator.")
        return sort_by(arguments[0], function.arguments[0], reverse=True)
    if isinstance(function, Call) and function.has_head("OrderingBy") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("OrderingBy[f] expects exactly one argument when used as an operator.")
        return ordering_by(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("MinimalBy") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("MinimalBy[f] expects exactly one argument when used as an operator.")
        return minimal_by(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("MaximalBy") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("MaximalBy[f] expects exactly one argument when used as an operator.")
        return maximal_by(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("LexicographicOrder") and len(function.arguments) == 1:
        if len(arguments) != 2:
            raise WolframEvaluationError(
                "LexicographicOrder[p] expects exactly two arguments when used as an operator."
            )
        return lexicographic_order(arguments[0], arguments[1], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringContainsQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError(
                "StringContainsQ[patt] expects exactly one argument when used as an operator."
            )
        return string_contains_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringMatchQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringMatchQ[patt] expects exactly one argument when used as an operator.")
        return string_match_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringFreeQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringFreeQ[patt] expects exactly one argument when used as an operator.")
        return string_free_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringStartsQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringStartsQ[patt] expects exactly one argument when used as an operator.")
        return string_starts_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringEndsQ") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError("StringEndsQ[patt] expects exactly one argument when used as an operator.")
        return string_ends_q(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("StringPosition") and len(function.arguments) == 1:
        if len(arguments) != 1:
            raise WolframEvaluationError(
                "StringPosition[patt] expects exactly one argument when used as an operator."
            )
        return string_position(arguments[0], function.arguments[0])
    if isinstance(function, Call) and function.has_head("Failsafe") and len(function.arguments) in {1, 2, 3}:
        return failsafe_apply(function, arguments)
    return evaluate(Call(head_expr=function, arguments=tuple(arguments)))


def _is_callable_expr(expr: Expr) -> bool:
    if _is_pure_function_expr(expr):
        return True
    if not isinstance(expr, Call):
        return False
    if expr.has_head("SameAs") and len(expr.arguments) == 1:
        return True
    if expr.has_head("Composition"):
        return True
    if expr.has_head("RightComposition"):
        return True
    if expr.has_head("MapApply") and len(expr.arguments) == 1:
        return True
    if expr.has_head("MapAll") and len(expr.arguments) == 1:
        return True
    if expr.has_head("MapIndexed") and len(expr.arguments) in {1, 2}:
        return True
    if expr.has_head("KeySelect") and len(expr.arguments) == 1:
        return True
    if expr.has_head("Scan") and len(expr.arguments) in {1, 2}:
        return True
    if expr.has_head("Comap") and len(expr.arguments) == 1:
        return True
    if expr.has_head("ComapApply") and len(expr.arguments) == 1:
        return True
    if expr.has_head("SortBy") and len(expr.arguments) == 1:
        return True
    if expr.has_head("ReverseSortBy") and len(expr.arguments) == 1:
        return True
    if expr.has_head("OrderingBy") and len(expr.arguments) == 1:
        return True
    if expr.has_head("MinimalBy") and len(expr.arguments) == 1:
        return True
    if expr.has_head("MaximalBy") and len(expr.arguments) == 1:
        return True
    if expr.has_head("LexicographicOrder") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringContainsQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringMatchQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringFreeQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringStartsQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringEndsQ") and len(expr.arguments) == 1:
        return True
    if expr.has_head("StringPosition") and len(expr.arguments) == 1:
        return True
    if expr.has_head("Failsafe") and len(expr.arguments) in {1, 2, 3}:
        return True
    return False


def same_q(*arguments: Expr) -> Symbol:
    if len(arguments) <= 1:
        return _bool_symbol(True)
    first_argument = arguments[0]
    return _bool_symbol(all(argument == first_argument for argument in arguments[1:]))


def unsame_q(*arguments: Expr) -> Symbol:
    seen: set[Expr] = set()
    for argument in arguments:
        if argument in seen:
            return _bool_symbol(False)
        seen.add(argument)
    return _bool_symbol(True)


@dataclass(frozen=True)
class _OrderingItem:
    index: int
    value: Expr
    entry: _AssociationEntry | None = None
    keys: tuple[Expr, ...] = ()


def _integer_sign(value: int) -> int:
    return (value > 0) - (value < 0)


def _text_compare(left: str, right: str) -> int:
    return (left > right) - (left < right)


def _is_orderable_real_expr(expr: Expr) -> bool:
    return (
        _is_real_number_expr(expr)
        or _is_positive_infinity_expr(expr)
        or _is_negative_infinity_expr(expr)
    )


def _orderable_complex_parts(expr: Expr) -> tuple[Expr, Expr] | None:
    if isinstance(expr, ComplexNumber):
        return expr.real_part, expr.imaginary_part
    if _is_orderable_real_expr(expr):
        return expr, integer(0)
    return None


def _number_kind_rank(expr: Expr) -> int:
    if _is_negative_infinity_expr(expr):
        return 0
    if isinstance(expr, Integer):
        return 1
    if isinstance(expr, RationalNumber):
        return 2
    if isinstance(expr, Real):
        return 3
    if isinstance(expr, SpecialReal):
        return 4
    if _is_positive_infinity_expr(expr):
        return 5
    if isinstance(expr, ComplexNumber):
        return 6
    return 7


def _expr_kind_rank(expr: Expr) -> int:
    if _orderable_complex_parts(expr) is not None:
        return 0
    if isinstance(expr, String):
        return 1
    if isinstance(expr, Symbol):
        return 2
    if isinstance(expr, ByteArrayExpr):
        return 3
    if isinstance(expr, SparseArrayExpr):
        return 4
    if isinstance(expr, Call):
        return 5
    return 6


def _numeric_tie_compare(left: Expr, right: Expr) -> int:
    rank_compare = _number_kind_rank(left) - _number_kind_rank(right)
    if rank_compare != 0:
        return _integer_sign(rank_compare)
    return _text_compare(left.to_full_form(), right.to_full_form())


def _canonical_compare(left: Expr, right: Expr) -> int:
    """Return -1 when left is before right in Tungsten's canonical order."""

    if left == right:
        return 0

    left_parts = _orderable_complex_parts(left)
    right_parts = _orderable_complex_parts(right)
    if left_parts is not None and right_parts is not None:
        real_compare = _compare_real_expr(left_parts[0], right_parts[0])
        if real_compare:
            return _integer_sign(real_compare)
        imaginary_compare = _compare_real_expr(left_parts[1], right_parts[1])
        if imaginary_compare:
            return _integer_sign(imaginary_compare)
        return _numeric_tie_compare(left, right)

    rank_compare = _expr_kind_rank(left) - _expr_kind_rank(right)
    if rank_compare != 0:
        return _integer_sign(rank_compare)

    if isinstance(left, String) and isinstance(right, String):
        return _text_compare(left.value, right.value)
    if isinstance(left, Symbol) and isinstance(right, Symbol):
        return _text_compare(left.name, right.name)
    if isinstance(left, ByteArrayExpr) and isinstance(right, ByteArrayExpr):
        return _integer_sign((left.values > right.values) - (left.values < right.values))
    if isinstance(left, SparseArrayExpr) and isinstance(right, SparseArrayExpr):
        return _text_compare(left.to_full_form(), right.to_full_form())
    if isinstance(left, Call) and isinstance(right, Call):
        head_compare = _canonical_compare(left.head_expr, right.head_expr)
        if head_compare != 0:
            return head_compare
        return _lexicographic_sequence_compare(left.arguments, right.arguments)

    return _text_compare(left.to_full_form(), right.to_full_form())


def _lexicographic_sequence_compare(
    left_items: Sequence[Expr],
    right_items: Sequence[Expr],
    ordering_function: Expr | None = None,
) -> int:
    for left_item, right_item in zip(left_items, right_items):
        item_compare = (
            _ordering_function_compare(ordering_function, left_item, right_item)
            if ordering_function is not None
            else _canonical_compare(left_item, right_item)
        )
        if item_compare != 0:
            return item_compare
    return _integer_sign(len(left_items) - len(right_items))


def order_expr(left: Expr, right: Expr) -> Integer:
    return integer(-_canonical_compare(left, right))


def _ordering_function_compare(ordering_function: Expr, left: Expr, right: Expr) -> int:
    result = evaluate(_apply_callable(ordering_function, (left, right)))
    truth = _truth_value(result)
    if truth is True:
        return -1
    if truth is False:
        reverse = evaluate(_apply_callable(ordering_function, (right, left)))
        reverse_truth = _truth_value(reverse)
        if reverse_truth is True:
            return 1
        if reverse_truth is False:
            return 0
        if isinstance(reverse, Integer):
            return _integer_sign(reverse.value)
        return 0
    if isinstance(result, Integer):
        return -_integer_sign(result.value)
    return _canonical_compare(left, right)


def _sequence_ordering_items(expr: Expr, function_name: str) -> list[_OrderingItem]:
    entries = _association_entries(expr)
    if entries is not None:
        return [
            _OrderingItem(index=index, value=entry.value, entry=entry)
            for index, entry in enumerate(entries, start=1)
        ]

    compound = _require_compound(expr, function_name)
    return [
        _OrderingItem(index=index, value=argument)
        for index, argument in enumerate(compound.arguments, start=1)
    ]


def _rebuild_ordered_expr(expr: Expr, items: Sequence[_OrderingItem]) -> Expr:
    if _association_entries(expr) is not None:
        return _association_expr(item.entry for item in items if item.entry is not None)
    compound = _require_compound(expr, "ordering operation")
    return _rebuild(compound, [item.value for item in items])


def _sort_items_by_value(
    items: Sequence[_OrderingItem],
    ordering_function: Expr | None = None,
    *,
    reverse: bool = False,
    same_test: Expr | None = None,
) -> list[_OrderingItem]:
    def compare(left: _OrderingItem, right: _OrderingItem) -> int:
        if same_test is not None and _duplicate_test_succeeds(same_test, left.value, right.value):
            return 0
        result = (
            _ordering_function_compare(ordering_function, left.value, right.value)
            if ordering_function is not None
            else _canonical_compare(left.value, right.value)
        )
        return -result if reverse else result

    return sorted(items, key=cmp_to_key(compare))


def _sort_count_slice(
    sorted_items: Sequence[_OrderingItem],
    count: Expr | None,
    function_name: str,
) -> list[_OrderingItem]:
    if count is None or (isinstance(count, Symbol) and count.name == "All"):
        return list(sorted_items)
    if not isinstance(count, Integer):
        raise WolframEvaluationError(f"{function_name} expects an integer or All count.")
    n = count.value
    if n >= 0:
        return list(sorted_items[:n])
    return list(sorted_items[n:]) if abs(n) <= len(sorted_items) else list(sorted_items)


def ordering(
    expr: Expr,
    count: Expr | None = None,
    ordering_function: Expr | None = None,
    *,
    same_test: Expr | None = None,
) -> Call:
    sorted_items = _sort_items_by_value(
        _sequence_ordering_items(expr, "Ordering"),
        ordering_function,
        same_test=same_test,
    )
    selected = _sort_count_slice(sorted_items, count, "Ordering")
    return _evaluated_list_expr(*(integer(item.index) for item in selected))


def sort_expr(
    expr: Expr,
    ordering_function: Expr | None = None,
    count: Expr | None = None,
    *,
    reverse: bool = False,
    same_test: Expr | None = None,
) -> Expr:
    items = _sequence_ordering_items(expr, "Sort")
    sorted_items = _sort_items_by_value(
        items,
        ordering_function,
        reverse=reverse,
        same_test=same_test,
    )
    sorted_items = _sort_count_slice(sorted_items, count, "Sort")
    return _rebuild_ordered_expr(expr, sorted_items)


def alphabetic_sort(expr: Expr) -> Expr:
    items = _sequence_ordering_items(expr, "AlphabeticSort")

    def key(item: _OrderingItem) -> str:
        value = item.value
        return value.value.casefold() if isinstance(value, String) else value.to_input_form().casefold()

    return _rebuild_ordered_expr(expr, sorted(items, key=key))


def _numerical_sort_key_text(value: str) -> tuple[tuple[int, str | int], ...]:
    parts: list[tuple[int, str | int]] = []
    for part in re.split(r"(\d+)", value.casefold()):
        if not part:
            continue
        if part.isdigit():
            parts.append((1, int(part)))
        else:
            parts.append((0, part))
    return tuple(parts)


def numerical_sort(expr: Expr) -> Expr:
    items = _sequence_ordering_items(expr, "NumericalSort")

    def key(item: _OrderingItem) -> tuple[tuple[int, str | int], ...]:
        value = item.value
        text = value.value if isinstance(value, String) else value.to_input_form()
        return _numerical_sort_key_text(text)

    return _rebuild_ordered_expr(expr, sorted(items, key=key))


def random_sample(expr: Expr, count: Expr | None = None) -> Expr:
    items = list(_sequence_ordering_items(expr, "RandomSample"))
    if count is None or (isinstance(count, Symbol) and count.name == "All"):
        sample_count = len(items)
    elif isinstance(count, Call) and count.has_head("UpTo") and len(count.arguments) == 1 and isinstance(count.arguments[0], Integer):
        sample_count = min(len(items), count.arguments[0].value)
    elif isinstance(count, Integer):
        sample_count = count.value
    else:
        raise WolframEvaluationError("RandomSample expects an integer, UpTo[n], All, or no count.")
    if sample_count < 0 or sample_count > len(items):
        raise WolframEvaluationError("RandomSample count must be between 0 and the sequence length.")
    return _rebuild_ordered_expr(expr, random.sample(items, sample_count))


def ordered_q(expr: Expr, ordering_function: Expr | None = None) -> Symbol:
    items = _sequence_ordering_items(expr, "OrderedQ")
    for left, right in zip(items, items[1:]):
        compare = (
            _ordering_function_compare(ordering_function, left.value, right.value)
            if ordering_function is not None
            else _canonical_compare(left.value, right.value)
        )
        if compare > 0:
            return _bool_symbol(False)
    return _bool_symbol(True)


def _key_function_list(functions: Expr) -> tuple[tuple[Expr, ...], bool]:
    if isinstance(functions, Call) and functions.has_head("List"):
        return functions.arguments, True
    return (functions,), False


def _items_with_keys(expr: Expr, functions: Expr, function_name: str) -> tuple[list[_OrderingItem], bool]:
    key_functions, key_spec_is_list = _key_function_list(functions)
    items = []
    for item in _sequence_ordering_items(expr, function_name):
        keys = tuple(_apply_callable(function, (item.value,)) for function in key_functions)
        items.append(_OrderingItem(index=item.index, value=item.value, entry=item.entry, keys=keys))
    return items, key_spec_is_list


def _compare_key_tuples(
    left_keys: Sequence[Expr],
    right_keys: Sequence[Expr],
    ordering_function: Expr | None,
    same_test: Expr | None = None,
) -> int:
    for left_key, right_key in zip(left_keys, right_keys):
        if same_test is not None and _duplicate_test_succeeds(same_test, left_key, right_key):
            continue
        compare = (
            _ordering_function_compare(ordering_function, left_key, right_key)
            if ordering_function is not None
            else _canonical_compare(left_key, right_key)
        )
        if compare != 0:
            return compare
    return _integer_sign(len(left_keys) - len(right_keys))


def _sort_items_by_keys(
    items: Sequence[_OrderingItem],
    *,
    key_spec_is_list: bool,
    ordering_function: Expr | None = None,
    reverse: bool = False,
    stable_ties: bool = False,
    same_test: Expr | None = None,
) -> list[_OrderingItem]:
    def compare(left: _OrderingItem, right: _OrderingItem) -> int:
        result = _compare_key_tuples(left.keys, right.keys, ordering_function, same_test)
        if result == 0 and same_test is None and not key_spec_is_list and not stable_ties:
            result = _canonical_compare(left.value, right.value)
        return -result if reverse else result

    return sorted(items, key=cmp_to_key(compare))


def sort_by(
    expr: Expr,
    functions: Expr,
    ordering_function: Expr | None = None,
    *,
    reverse: bool = False,
    same_test: Expr | None = None,
) -> Expr:
    items, key_spec_is_list = _items_with_keys(expr, functions, "SortBy")
    sorted_items = _sort_items_by_keys(
        items,
        key_spec_is_list=key_spec_is_list,
        ordering_function=ordering_function,
        reverse=reverse,
        same_test=same_test,
    )
    return _rebuild_ordered_expr(expr, sorted_items)


def ordering_by(
    expr: Expr,
    functions: Expr,
    count: Expr | None = None,
    ordering_function: Expr | None = None,
    *,
    same_test: Expr | None = None,
) -> Call:
    items, key_spec_is_list = _items_with_keys(expr, functions, "OrderingBy")
    sorted_items = _sort_items_by_keys(
        items,
        key_spec_is_list=key_spec_is_list,
        ordering_function=ordering_function,
        same_test=same_test,
    )
    selected = _sort_count_slice(sorted_items, count, "OrderingBy")
    return _evaluated_list_expr(*(integer(item.index) for item in selected))


def _by_count(count: Expr | None, total: int, function_name: str) -> int | None:
    if count is None:
        return None
    if isinstance(count, Symbol) and count.name == "All":
        return total
    if isinstance(count, Call) and count.has_head("UpTo") and len(count.arguments) == 1:
        argument = count.arguments[0]
        if not isinstance(argument, Integer):
            raise WolframEvaluationError(f"{function_name} expects UpTo[n] with an integer n.")
        return max(0, min(total, argument.value))
    if not isinstance(count, Integer):
        raise WolframEvaluationError(f"{function_name} expects an integer, UpTo[n], or All count.")
    if count.value < 0:
        raise WolframEvaluationError(f"{function_name} expects a non-negative count.")
    return min(total, count.value)


def _extreme_by(
    expr: Expr,
    functions: Expr,
    count: Expr | None,
    ordering_function: Expr | None,
    *,
    maximal: bool,
) -> Expr:
    function_name = "MaximalBy" if maximal else "MinimalBy"
    items, _ = _items_with_keys(expr, functions, function_name)
    if not items:
        return _rebuild_ordered_expr(expr, [])

    if count is None:
        best = items[0].keys
        selected = [items[0]]
        for item in items[1:]:
            compare = _compare_key_tuples(item.keys, best, ordering_function)
            if maximal:
                compare = -compare
            if compare < 0:
                best = item.keys
                selected = [item]
            elif compare == 0:
                selected.append(item)
        return _rebuild_ordered_expr(expr, selected)

    sorted_items = _sort_items_by_keys(
        items,
        key_spec_is_list=True,
        ordering_function=ordering_function,
        reverse=maximal,
        stable_ties=True,
    )
    return _rebuild_ordered_expr(expr, sorted_items[:_by_count(count, len(sorted_items), function_name)])


def minimal_by(
    expr: Expr,
    functions: Expr,
    count: Expr | None = None,
    ordering_function: Expr | None = None,
) -> Expr:
    return _extreme_by(expr, functions, count, ordering_function, maximal=False)


def maximal_by(
    expr: Expr,
    functions: Expr,
    count: Expr | None = None,
    ordering_function: Expr | None = None,
) -> Expr:
    return _extreme_by(expr, functions, count, ordering_function, maximal=True)


def _lexicographic_elements(expr: Expr) -> tuple[Expr, ...] | None:
    if isinstance(expr, String):
        return tuple(string(char) for char in expr.value)
    if isinstance(expr, Call):
        return expr.arguments
    return None


def _lexicographic_compare(left: Expr, right: Expr, ordering_function: Expr | None = None) -> int:
    left_items = _lexicographic_elements(left)
    right_items = _lexicographic_elements(right)
    if left_items is None or right_items is None:
        return (
            _ordering_function_compare(ordering_function, left, right)
            if ordering_function is not None
            else _canonical_compare(left, right)
        )
    return _lexicographic_sequence_compare(left_items, right_items, ordering_function)


def lexicographic_order(left: Expr, right: Expr, ordering_function: Expr | None = None) -> Integer:
    return integer(-_lexicographic_compare(left, right, ordering_function))


def lexicographic_sort(expr: Expr, ordering_function: Expr | None = None) -> Expr:
    items = _sequence_ordering_items(expr, "LexicographicSort")

    def compare(left: _OrderingItem, right: _OrderingItem) -> int:
        return _lexicographic_compare(left.value, right.value, ordering_function)

    sorted_items = sorted(items, key=cmp_to_key(compare))
    return _rebuild_ordered_expr(expr, sorted_items)


def scan(
    function: Expr,
    expr: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    *,
    include_heads: bool = False,
) -> Symbol:
    level_spec = integer(1) if spec is None else spec
    if not include_heads:
        for item in level(expr, level_spec):
            _apply_callable(function, (item,))
        return symbol("Null")

    level_min, level_max = _normalize_level_spec(level_spec)

    def walk(current: Expr, current_level: int) -> None:
        entries = _association_entries(current)
        if entries is not None:
            for entry in entries:
                walk(entry.value, current_level + 1)
        elif isinstance(current, Call):
            walk(current.head_expr, current_level + 1)
            for argument in current.arguments:
                walk(argument, current_level + 1)
        if _level_in_range(current_level, current, level_min, level_max):
            _apply_callable(function, (current,))

    walk(expr, 0)
    return symbol("Null")


def map_apply(function: Expr, expr: Expr, level_spec: Expr | None = None) -> Expr:
    """``MapApply[f, expr]`` / ``MapApply[f, expr, levelspec]``.

    The default form replaces the head of every immediate child with
    ``f`` (matching ``f @@@ expr``). With a level spec, the same
    head-replacement rule applies at every position whose level
    matches the spec.
    """
    if level_spec is None:
        entries = _association_entries(expr)
        if entries is not None:
            return _association_expr(
                _AssociationEntry(
                    rule_head=entry.rule_head,
                    key=entry.key,
                    value=apply_head(function, entry.value),
                )
                for entry in entries
            )
        if not isinstance(expr, Call):
            return expr
        return _rebuild(expr, tuple(apply_head(function, argument) for argument in expr.arguments))

    level_min, level_max = _normalize_level_spec(level_spec)
    return _walk_map_apply_levels(function, expr, level_min, level_max, current_level=0)


def _walk_map_apply_levels(
    function: Expr, expr: Expr, level_min: int, level_max: int, current_level: int
) -> Expr:
    """Walk ``expr`` and replace heads at every position whose level
    matches the spec — analogous to ``Map`` but using ``apply_head``
    (the ``MapApply`` rule) at each visited node.
    """
    entries = _association_entries(expr)
    if entries is not None:
        new_entries = [
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_walk_map_apply_levels(
                    function, entry.value, level_min, level_max, current_level + 1
                ),
            )
            for entry in entries
        ]
        rebuilt: Expr = _association_expr(new_entries)
        if _level_in_range(current_level, expr, level_min, level_max) and current_level >= 1:
            return apply_head(function, rebuilt)
        return rebuilt

    if isinstance(expr, Call):
        new_arguments = tuple(
            _walk_map_apply_levels(function, argument, level_min, level_max, current_level + 1)
            for argument in expr.arguments
        )
        rebuilt = _rebuild(expr, new_arguments)
        if _level_in_range(current_level, expr, level_min, level_max) and current_level >= 1:
            return apply_head(function, rebuilt)
        return rebuilt

    return expr


def _map_all_recursive(function: Expr, expr: Expr, include_heads: bool) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        rebuilt = _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_map_all_recursive(function, entry.value, include_heads),
            )
            for entry in entries
        )
        return _apply_callable(function, (rebuilt,))

    if isinstance(expr, Call):
        new_arguments = tuple(
            _map_all_recursive(function, argument, include_heads) for argument in expr.arguments
        )
        if include_heads:
            new_head = _map_all_recursive(function, expr.head_expr, include_heads)
            rebuilt = Call(head_expr=new_head, arguments=new_arguments)
        else:
            rebuilt = _rebuild(expr, new_arguments)
        return _apply_callable(function, (rebuilt,))

    return _apply_callable(function, (expr,))


def map_all(function: Expr, expr: Expr, *, include_heads: bool = False) -> Expr:
    return _map_all_recursive(function, expr, include_heads)


def map_indexed(function: Expr, expr: Expr, spec: Expr | int | tuple[int, int] | None = None) -> Expr:
    """``MapIndexed[f, expr]`` / ``MapIndexed[f, expr, levelspec]``.

    The default level is 1, applying ``f`` to each immediate child
    along with that child's one-element index list. With a level spec,
    ``MapIndexed`` walks the tree per the kernel's contract:
    integer ``n`` means levels ``1..n``; ``{n}`` means level ``n`` only;
    integers may be negative to count from the leaves toward the root.
    Each call receives the structural position as a list of integers
    (or ``Key[k]`` components for association traversal).
    """
    level_spec: Expr | int | tuple[int, int] = (1, 1) if spec is None else spec
    level_min, level_max = _normalize_level_spec(level_spec)

    def recurse(current: Expr, path: tuple[Expr, ...]) -> Expr:
        positive_level = len(path)
        entries = _association_entries(current)
        if entries is not None:
            new_entries = []
            for entry in entries:
                child_path = path + (call("Key", entry.key),)
                new_entries.append(
                    _AssociationEntry(
                        rule_head=entry.rule_head,
                        key=entry.key,
                        value=recurse(entry.value, child_path),
                    )
                )
            mapped: Expr = _association_expr(new_entries)
        elif isinstance(current, Call) and not _is_atom_like_call(current):
            new_args = []
            for index, argument in enumerate(current.arguments, start=1):
                child_path = path + (integer(index),)
                new_args.append(recurse(argument, child_path))
            mapped = _rebuild(current, tuple(new_args))
        else:
            mapped = current
        # Apply ``f`` at this level if it falls within the requested
        # bounds — note ``MapIndexed`` *replaces* the visited subexpression
        # with ``f[subexpr, position]``, unlike ``Map`` which always
        # rewrites the immediate slot.
        negative_level = -depth(mapped)
        if positive_level >= 1 and _level_bounds_match(positive_level, negative_level, level_min, level_max):
            return _apply_callable(function, (mapped, list_expr(*path)))
        return mapped

    return recurse(expr, ())


def _is_atom_like_call(expr: Expr) -> bool:
    """Tungsten treats numeric atoms with bracketed FullForm
    (``Rational``, ``Complex``, ``Overflow[]``, ``SparseArray``,
    etc.) as atoms for traversal. Pattern heads should still be
    recursed; only structural-atom heads are excluded.
    """
    return False  # ordinary structural traversal includes everything for now


def construct(function: Expr, *arguments: Expr) -> Expr:
    return _apply_callable(function, arguments)


def composition_apply(functions: Sequence[Expr], arguments: Sequence[Expr]) -> Expr:
    if not functions:
        if len(arguments) == 1:
            return arguments[0]
        return _evaluated_list_expr(*arguments)

    current = _apply_callable(functions[-1], arguments)
    for function in reversed(functions[:-1]):
        current = _apply_callable(function, (current,))
    return current


def right_composition_apply(functions: Sequence[Expr], arguments: Sequence[Expr]) -> Expr:
    if not functions:
        if len(arguments) == 1:
            return arguments[0]
        return _evaluated_list_expr(*arguments)

    current = _apply_callable(functions[0], arguments)
    for function in functions[1:]:
        current = _apply_callable(function, (current,))
    return current


def compose_list(functions_expr: Expr, initial: Expr) -> Expr:
    if not isinstance(functions_expr, Call):
        raise WolframEvaluationError("ComposeList expects a list or other nonatomic expression of functions.")

    current = initial
    results = [initial]
    for function in functions_expr.arguments:
        current = _apply_callable(function, (current,))
        results.append(current)
    return _evaluated_list_expr(*results)


def nest(function: Expr, expr: Expr, count: Expr | int) -> Expr:
    iterations = _normalize_integer_argument(count, "Nest")
    if iterations < 0:
        raise WolframEvaluationError("Nest expects a non-negative integer iteration count.")
    current = expr
    for _ in range(iterations):
        current = _apply_callable(function, (current,))
    return current


def nest_list(function: Expr, expr: Expr, count: Expr | int) -> Expr:
    iterations = _normalize_integer_argument(count, "NestList")
    if iterations < 0:
        raise WolframEvaluationError("NestList expects a non-negative integer iteration count.")
    current = expr
    results = [expr]
    for _ in range(iterations):
        current = _apply_callable(function, (current,))
        results.append(current)
    return _evaluated_list_expr(*results)


_ITERATION_SAFETY_LIMIT = 65536


def nest_while(
    function: Expr,
    expr: Expr,
    test: Expr,
    history_spec: Expr | int | None = None,
    extra_iterations: Expr | int | None = None,
) -> Expr:
    """NestWhile[f, expr, test] / NestWhile[..., m] / NestWhile[..., m, max] /
    NestWhile[..., m, max, n].

    The history-spec argument ``m`` controls how many recent values the test
    receives: ``m = 1`` (default) is a unary predicate, ``m = 2`` makes the
    test binary on the previous and current value, ``All`` passes the full
    history, and other positive integers feed the last ``m`` values.
    The optional ``max`` is the maximum number of iterations (matching
    Wolfram's contract). Beyond Wolfram's contract, the safety cap still
    applies as a final fallback. The trailing-count ``n`` argument runs
    ``n`` extra iterations after the predicate first fails.
    """
    history_size = _normalize_nest_while_history(history_spec)
    max_iterations = _normalize_nest_while_max(extra_iterations)

    history: list[Expr] = [expr]
    iterations = 0
    while True:
        if not _predicate_with_history(test, history, history_size):
            break
        if iterations >= _ITERATION_SAFETY_LIMIT:
            raise WolframEvaluationError("NestWhile exceeded the Tungsten iteration safety limit.")
        if max_iterations is not None and iterations >= max_iterations:
            break
        history.append(_apply_callable(function, (history[-1],)))
        iterations += 1
    return history[-1]


def nest_while_list(
    function: Expr,
    expr: Expr,
    test: Expr,
    history_spec: Expr | int | None = None,
    extra_iterations: Expr | int | None = None,
) -> Expr:
    history_size = _normalize_nest_while_history(history_spec)
    max_iterations = _normalize_nest_while_max(extra_iterations)

    history: list[Expr] = [expr]
    iterations = 0
    while True:
        if not _predicate_with_history(test, history, history_size):
            return _evaluated_list_expr(*history)
        if iterations >= _ITERATION_SAFETY_LIMIT:
            raise WolframEvaluationError(
                "NestWhileList exceeded the Tungsten iteration safety limit."
            )
        if max_iterations is not None and iterations >= max_iterations:
            return _evaluated_list_expr(*history)
        history.append(_apply_callable(function, (history[-1],)))
        iterations += 1


def _normalize_nest_while_history(spec: Expr | int | None) -> int | None:
    """Convert NestWhile's ``m`` argument to a concrete history size or
    ``None`` for ``All``.

    Returns ``1`` when no spec is given (the default unary predicate).
    """
    if spec is None:
        return 1
    if isinstance(spec, int):
        if spec < 1:
            raise WolframEvaluationError("NestWhile history size must be a positive integer or All.")
        return spec
    if isinstance(spec, Integer):
        return _normalize_nest_while_history(spec.value)
    if isinstance(spec, Symbol) and spec.name == "All":
        return None
    raise WolframEvaluationError("NestWhile history size must be a positive integer or All.")


def _normalize_nest_while_max(spec: Expr | int | None) -> int | None:
    if spec is None:
        return None
    if isinstance(spec, int):
        return max(0, spec)
    if isinstance(spec, Integer):
        return max(0, spec.value)
    if isinstance(spec, Symbol) and spec.name == "Infinity":
        return None
    raise WolframEvaluationError(
        "NestWhile max iterations must be a non-negative integer or Infinity."
    )


def _predicate_with_history(test: Expr, history: Sequence[Expr], history_size: int | None) -> bool:
    if history_size is None:
        arguments = tuple(history)
    else:
        arguments = tuple(history[-history_size:])
    if len(arguments) < (history_size or len(arguments)):
        # Not enough history yet; conventionally Wolfram returns True so
        # iteration starts. We only reach here when history_size > 1 and the
        # history hasn't grown enough, which means the predicate must succeed
        # to permit further iterations.
        return True
    outcome = evaluate(_apply_callable(test, arguments))
    return isinstance(outcome, Symbol) and outcome.name == "True"


def fixed_point(function: Expr, expr: Expr, max_iterations: Expr | int | None = None) -> Expr:
    explicit_limit = max_iterations is not None
    limit = _ITERATION_SAFETY_LIMIT if max_iterations is None else _normalize_integer_argument(max_iterations, "FixedPoint")
    if limit < 0:
        raise WolframEvaluationError("FixedPoint expects a non-negative maximum iteration count.")
    current = expr
    for _ in range(limit):
        updated = _apply_callable(function, (current,))
        if updated == current:
            return current
        current = updated
    if explicit_limit:
        return current
    raise WolframEvaluationError("FixedPoint exceeded the Tungsten iteration safety limit.")


def fixed_point_list(function: Expr, expr: Expr, max_iterations: Expr | int | None = None) -> Expr:
    explicit_limit = max_iterations is not None
    limit = _ITERATION_SAFETY_LIMIT if max_iterations is None else _normalize_integer_argument(max_iterations, "FixedPointList")
    if limit < 0:
        raise WolframEvaluationError("FixedPointList expects a non-negative maximum iteration count.")
    current = expr
    results = [expr]
    for _ in range(limit):
        updated = _apply_callable(function, (current,))
        results.append(updated)
        if updated == current:
            return _evaluated_list_expr(*results)
        current = updated
    if explicit_limit:
        return _evaluated_list_expr(*results)
    raise WolframEvaluationError("FixedPointList exceeded the Tungsten iteration safety limit.")


def operate(operator: Expr, expr: Expr, level_value: Expr | int = 1) -> Expr:
    level_number = _normalize_integer_argument(level_value, "Operate")
    if level_number < 0:
        raise WolframEvaluationError("Operate expects a non-negative integer level.")
    if level_number == 0:
        # Wolfram's Operate[p, expr, 0] wraps the entire expression: p[expr].
        return _apply_callable(operator, (expr,))
    if not isinstance(expr, Call):
        return expr
    if level_number == 1:
        return Call(head_expr=_apply_callable(operator, (expr.head_expr,)), arguments=expr.arguments)
    if not isinstance(expr.head_expr, Call):
        return expr
    return Call(head_expr=operate(operator, expr.head_expr, level_number - 1), arguments=expr.arguments)


def comap(functions_expr: Expr, expr: Expr) -> Expr:
    entries = _association_entries(functions_expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_apply_callable(entry.value, (expr,)),
            )
            for entry in entries
        )
    if not isinstance(functions_expr, Call):
        return functions_expr
    return _rebuild(
        functions_expr,
        tuple(_apply_callable(function, (expr,)) for function in functions_expr.arguments),
    )


def comap_apply(functions_expr: Expr, expr: Expr) -> Expr:
    entries = _association_entries(functions_expr)
    if entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=apply_head(entry.value, expr),
            )
            for entry in entries
        )
    if not isinstance(functions_expr, Call):
        return functions_expr
    return _rebuild(
        functions_expr,
        tuple(apply_head(function, expr) for function in functions_expr.arguments),
    )


def through(expr: Expr, target_head: Expr | None = None) -> Expr:
    """``Through[f[a, b]]`` / ``Through[f[a, b], head]``.

    The single-argument form distributes the arguments through every
    function held by the head of ``expr``: ``Through[(f + g)[x]]``
    becomes ``f[x] + g[x]``. The two-argument form only threads when
    the head of ``expr`` matches ``head`` (by name); otherwise the
    expression is returned unchanged, matching the kernel's
    ``Through[(f + g)[x, y], List]`` -> ``(f + g)[x, y]`` behavior.
    """
    if not isinstance(expr, Call):
        return expr
    if target_head is not None:
        if not isinstance(target_head, Symbol):
            raise WolframEvaluationError("Through's second argument must be a Symbol head.")
        outer_head = expr.head_expr
        if not (isinstance(outer_head, Call) and isinstance(outer_head.head_expr, Symbol) and outer_head.head_expr.name == target_head.name):
            return expr
    head_entries = _association_entries(expr.head_expr)
    if head_entries is not None:
        return _association_expr(
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_apply_callable(entry.value, expr.arguments),
            )
            for entry in head_entries
        )
    if not isinstance(expr.head_expr, Call):
        return expr
    return _rebuild(
        expr.head_expr,
        tuple(_apply_callable(function, expr.arguments) for function in expr.head_expr.arguments),
    )


def _sequence_values(expr: Expr, function_name: str) -> tuple[Expr, ...]:
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) != 1:
            raise WolframEvaluationError(f"{function_name} expects a one-dimensional SparseArray sequence.")
        return tuple(_sparse_array_value_at(expr, (index,)) for index in range(1, expr.dimensions[0] + 1))
    return tuple(item.value for item in _selection_items(expr, function_name))


def map_thread(function: Expr, sequences_expr: Expr, level_value: Expr | int | None = None) -> Expr:
    """MapThread[f, {l1, l2, ...}] / MapThread[f, lists, n].

    With ``n`` the threading depth, the parallel ``List`` structures must
    agree in shape down to level ``n``; ``f`` is applied to each n-tuple of
    leaves at that depth.
    """
    depth_value = 1 if level_value is None else _normalize_integer_argument(level_value, "MapThread")
    if depth_value < 0:
        raise WolframEvaluationError("MapThread expects a non-negative depth.")
    if not isinstance(sequences_expr, Call) or not sequences_expr.has_head("List"):
        raise WolframEvaluationError("MapThread expects a list of sequences.")

    sequences = list(sequences_expr.arguments)
    if not sequences:
        return _evaluated_list_expr()

    return _map_thread_recurse(function, sequences, depth_value)


def _map_thread_recurse(function: Expr, sequences: Sequence[Expr], depth: int) -> Expr:
    if depth == 0:
        return _apply_callable(function, tuple(sequences))
    if not all(isinstance(sequence, Call) and sequence.has_head("List") for sequence in sequences):
        raise WolframEvaluationError(
            "MapThread expects parallel List structures down to the requested depth."
        )
    lengths = {len(sequence.arguments) for sequence in sequences if isinstance(sequence, Call)}
    if len(lengths) != 1:
        raise WolframEvaluationError("MapThread expects sequences of the same length.")
    length_value = lengths.pop()
    return _evaluated_list_expr(
        *(
            _map_thread_recurse(
                function,
                tuple(
                    sequence.arguments[index]
                    for sequence in sequences
                    if isinstance(sequence, Call)
                ),
                depth - 1,
            )
            for index in range(length_value)
        )
    )


def thread(expr: Expr, thread_head: Expr | None = None) -> Expr:
    if not isinstance(expr, Call):
        return expr

    effective_head = symbol("List") if thread_head is None else thread_head
    lengths: set[int] = set()
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == effective_head:
            lengths.add(len(argument.arguments))

    if not lengths:
        return expr
    if len(lengths) != 1:
        raise WolframEvaluationError("Thread expects all threaded arguments to have the same length.")

    length_value = lengths.pop()
    results: list[Expr] = []
    for index in range(length_value):
        threaded_arguments: list[Expr] = []
        for argument in expr.arguments:
            if isinstance(argument, Call) and argument.head_expr == effective_head:
                threaded_arguments.append(argument.arguments[index])
            else:
                threaded_arguments.append(argument)
        results.append(Call(head_expr=expr.head_expr, arguments=tuple(threaded_arguments)))

    if isinstance(effective_head, Symbol) and effective_head.name == "List":
        return _evaluated_list_expr(*results)
    return Call(head_expr=effective_head, arguments=tuple(results))


def distribute(
    expr: Expr,
    distributed_head: Expr | None = None,
    outer_head: Expr | None = None,
    distributed_replacement: Expr | None = None,
    outer_replacement: Expr | None = None,
) -> Expr:
    """``Distribute[expr]`` / ``Distribute[expr, g]`` / ``Distribute[expr, g, f]``
    / ``Distribute[expr, g, f, gp, fp]``.

    The 5-argument form replaces the inner head ``g`` with ``gp`` and the
    outer head ``f`` with ``fp`` while distributing. The 3- and 5-argument
    forms also restrict distribution to expressions whose outer head is ``f``.
    """
    if not isinstance(expr, Call):
        return expr

    effective_distributed_head = symbol("Plus") if distributed_head is None else distributed_head
    if outer_head is not None and expr.head_expr != outer_head:
        return expr

    effective_outer_replacement = (
        outer_replacement if outer_replacement is not None else effective_distributed_head
    )
    effective_inner_replacement = (
        distributed_replacement if distributed_replacement is not None else expr.head_expr
    )

    argument_options: list[tuple[Expr, ...]] = []
    found = False
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == effective_distributed_head:
            argument_options.append(argument.arguments)
            found = True
        else:
            argument_options.append((argument,))

    if not found:
        return expr

    distributed_arguments: list[Expr] = []

    def recurse(index: int, chosen: list[Expr]) -> None:
        if index == len(argument_options):
            distributed_arguments.append(
                Call(head_expr=effective_inner_replacement, arguments=tuple(chosen))
            )
            return
        for option in argument_options[index]:
            recurse(index + 1, [*chosen, option])

    recurse(0, [])
    return Call(head_expr=effective_outer_replacement, arguments=tuple(distributed_arguments))


def outer(function: Expr, *args: Expr) -> Expr:
    """Apply ``Outer`` over one or more sequences with optional levelspec(s).

    Supported call shapes mirror the kernel:

    - ``Outer[f, t1, ..., tn]`` descends ``ti`` to its full depth (``Infinity``
      levelspec) and applies ``f`` to every combination of leaf elements.
    - ``Outer[f, t1, ..., tn, n]`` descends ``n`` levels into each ``ti``.
    - ``Outer[f, t1, ..., tn, n1, n2, ..., nk]`` accepts up to ``n``
      per-sequence integer levelspecs at the tail; the last spec is broadcast
      to any remaining sequences.

    A leaf reached before the requested level (because the input ran out of
    nesting) is treated as a leaf, matching the kernel's behavior on irregular
    inputs.
    """
    if not args:
        raise WolframEvaluationError("Outer expects at least one sequence.")

    sequences = list(args)
    levels: list[int] = []
    while len(sequences) > 1 and isinstance(sequences[-1], Integer):
        levels.insert(0, sequences.pop().value)
    if not sequences:
        raise WolframEvaluationError("Outer expects at least one sequence.")

    def depth_for(index: int) -> int | None:
        if not levels:
            return None
        if index < len(levels):
            return levels[index]
        return levels[-1]

    normalized_sequences: list[Call] = []
    for sequence in sequences:
        compound = _require_compound(sequence, "Outer")
        normalized_sequences.append(compound)

    def descend(node: Expr, depth_remaining: int | None, index: int, chosen: list[Expr]) -> Expr:
        if depth_remaining == 0 or not isinstance(node, Call):
            return recurse(index + 1, [*chosen, node])
        next_depth = depth_remaining - 1 if depth_remaining is not None else None
        return _rebuild(
            node,
            tuple(descend(child, next_depth, index, chosen) for child in node.arguments),
        )

    def recurse(index: int, chosen: list[Expr]) -> Expr:
        if index == len(normalized_sequences):
            return _apply_callable(function, tuple(chosen))
        return descend(normalized_sequences[index], depth_for(index), index, chosen)

    return recurse(0, [])


def inner(function: Expr, left: Expr, right: Expr, combiner: Expr) -> Expr:
    left_compound = _require_compound(left, "Inner")
    right_compound = _require_compound(right, "Inner")
    if len(left_compound.arguments) != len(right_compound.arguments):
        raise WolframEvaluationError("Inner expects expressions with the same length.")
    combined = [
        _apply_callable(function, (left_item, right_item))
        for left_item, right_item in zip(left_compound.arguments, right_compound.arguments, strict=True)
    ]
    return _apply_callable(combiner, tuple(combined))


def tuples_expr(items: Expr, count: Expr | int | None = None) -> Expr:
    """``Tuples[{seq1, seq2, …}]`` / ``Tuples[seq, n]`` /
    ``Tuples[seq, {n1, n2, …}]``.

    The list-of-sequences form takes the Cartesian product. The
    ``Tuples[seq, n]`` form repeats ``seq`` ``n`` times. The
    multi-shape ``Tuples[seq, {n1, n2, …}]`` returns nested tuples
    whose i-th level has length ``ni`` — equivalent to wrapping each
    element in a ``Tuples[seq, n_inner]`` recursively.
    """
    if count is None:
        if not isinstance(items, Call) or not items.has_head("List"):
            raise WolframEvaluationError("Tuples expects a list of sequences or a sequence with a repetition count.")
        sequences = [_sequence_values(item, "Tuples") for item in items.arguments]
        return _flat_tuples_product(sequences)

    if isinstance(count, Call) and count.has_head("List"):
        shape: list[int] = []
        for argument in count.arguments:
            shape.append(_normalize_integer_argument(argument, "Tuples"))
        if any(value < 0 for value in shape):
            raise WolframEvaluationError("Tuples shape components must be non-negative integers.")
        base_items = _sequence_values(items, "Tuples")
        return _shaped_tuples(base_items, shape)

    repetitions = _normalize_integer_argument(count, "Tuples")
    if repetitions < 0:
        raise WolframEvaluationError("Tuples expects a non-negative repetition count.")
    base_items = _sequence_values(items, "Tuples")
    sequences = [base_items] * repetitions
    return _flat_tuples_product(sequences)


def _flat_tuples_product(sequences: Sequence[Sequence[Expr]]) -> Expr:
    results: list[Expr] = [_evaluated_list_expr()]
    for sequence in sequences:
        next_results: list[Expr] = []
        for prefix in results:
            assert isinstance(prefix, Call) and prefix.has_head("List")
            for item in sequence:
                next_results.append(_evaluated_list_expr(*prefix.arguments, item))
        results = next_results
    return _evaluated_list_expr(*results)


def _shaped_tuples(base_items: Sequence[Expr], shape: Sequence[int]) -> Expr:
    """Recursive constructor for ``Tuples[seq, {n1, n2, …}]``.

    Equivalent to ``Tuples[Tuples[seq, n2, …], n1]``, i.e. the outermost
    level cycles through every length-``n1`` choice of inner tuples.
    Empty shape returns the trivial single-element nested-list Tuples
    output (``{}`` when shape is empty: matches the kernel).
    """
    if not shape:
        return _evaluated_list_expr()
    if len(shape) == 1:
        return _flat_tuples_product([base_items] * shape[0])
    inner_results: Call = _shaped_tuples(base_items, shape[1:])  # type: ignore[assignment]
    inner_choices = inner_results.arguments
    # Outer level: every length-shape[0] choice of inner_choices.
    outer = _flat_tuples_product([inner_choices] * shape[0])
    return outer




def _normalize_dimensions(dimensions: Expr | int, function_name: str) -> list[int]:
    if isinstance(dimensions, int):
        if dimensions < 0:
            raise WolframEvaluationError(f"{function_name} expects non-negative dimensions.")
        return [dimensions]
    if isinstance(dimensions, Integer):
        return _normalize_dimensions(dimensions.value, function_name)
    if isinstance(dimensions, Call) and dimensions.has_head("List"):
        values = [_normalize_integer_argument(item, function_name) for item in dimensions.arguments]
        if any(value < 0 for value in values):
            raise WolframEvaluationError(f"{function_name} expects non-negative dimensions.")
        return values
    raise WolframEvaluationError(f"{function_name} expects an integer dimension or a list of dimensions.")


def _build_array_from_dimensions(
    dimensions: Sequence[int],
    builder,
    origins: Sequence[int] | None = None,
    indices: tuple[int, ...] = (),
) -> Expr:
    if not dimensions:
        return builder(indices)
    size = dimensions[0]
    base = origins[0] if origins is not None else 1
    return _evaluated_list_expr(*(
        _build_array_from_dimensions(
            dimensions[1:],
            builder,
            None if origins is None else origins[1:],
            (*indices, index),
        )
        for index in range(base, base + size)
    ))


def _normalize_array_origins(origin_expr: Expr | None, dimension_count: int) -> list[int] | None:
    """Convert Array's optional origin argument to a per-dimension origin list.

    Wolfram accepts ``Array[f, n, base]`` and ``Array[f, n, {b1, b2, ...}]``
    plus the ``{lo, hi}`` shorthand that picks ``lo`` as the origin when
    ``hi - lo + 1 == size``. This helper normalizes those forms; it
    returns ``None`` when no explicit origin was supplied.
    """
    if origin_expr is None:
        return None
    if isinstance(origin_expr, Integer):
        return [origin_expr.value] * dimension_count
    if isinstance(origin_expr, Call) and origin_expr.has_head("List"):
        # ``{lo, hi}`` for a 1-D array picks ``lo`` as the origin.
        if dimension_count == 1 and len(origin_expr.arguments) == 2 and all(
            isinstance(item, Integer) for item in origin_expr.arguments
        ):
            return [origin_expr.arguments[0].value]  # type: ignore[union-attr]
        if len(origin_expr.arguments) != dimension_count:
            raise WolframEvaluationError(
                "Array origin list must have one entry per array dimension."
            )
        origins: list[int] = []
        for item in origin_expr.arguments:
            if not isinstance(item, Integer):
                raise WolframEvaluationError(
                    "Array origin entries must be explicit integers."
                )
            origins.append(item.value)
        return origins
    raise WolframEvaluationError(
        "Array currently expects an integer origin or a list of integer origins."
    )


def array(function: Expr, dimensions: Expr | int, origin: Expr | None = None) -> Expr:
    normalized_dimensions = _normalize_dimensions(dimensions, "Array")
    normalized_origins = _normalize_array_origins(origin, len(normalized_dimensions))
    return _build_array_from_dimensions(
        normalized_dimensions,
        lambda indices: _apply_callable(function, tuple(integer(index) for index in indices)),
        normalized_origins,
    )


def constant_array(value: Expr, dimensions: Expr | int) -> Expr:
    normalized_dimensions = _normalize_dimensions(dimensions, "ConstantArray")
    return _build_array_from_dimensions(normalized_dimensions, lambda _indices: value)


def range_expr(arguments: Sequence[Expr]) -> Expr:
    """Range[n], Range[m, n], Range[m, n, s], plus the iterator-list form
    Range[{n1, n2, ...}].

    The iterator-list form returns a list of one-argument ``Range`` results,
    matching the kernel's ``Range[{2, 5}] -> {Range[2], Range[5]} -> {{1, 2},
    {1, 2, 3, 4, 5}}`` chain.
    """
    if len(arguments) == 1 and isinstance(arguments[0], Call) and arguments[0].has_head("List"):
        nested_arguments = arguments[0].arguments
        if not all(isinstance(argument, Integer) for argument in nested_arguments):
            raise WolframEvaluationError(
                "Range currently supports only explicit integer arguments inside the iterator list."
            )
        return _evaluated_list_expr(*(range_expr((argument,)) for argument in nested_arguments))

    if len(arguments) not in {1, 2, 3}:
        raise WolframEvaluationError("Range expects one, two, or three integer arguments.")
    values = _integer_values(arguments)
    if values is None:
        raise WolframEvaluationError("Range currently supports only explicit integer arguments.")
    if len(values) == 1:
        start, end, step = 1, values[0], 1
    elif len(values) == 2:
        start, end = values
        step = 1
    else:
        start, end, step = values
    if step == 0:
        raise WolframEvaluationError("Range step cannot be zero.")
    if (step > 0 and start > end) or (step < 0 and start < end):
        return _evaluated_list_expr()
    stop = end + (1 if step > 0 else -1)
    return _evaluated_list_expr(*(integer(item) for item in range(start, stop, step)))


def unit_vector(arguments: Sequence[Expr]) -> Expr:
    values = _integer_values(arguments)
    if values is None or len(values) != 2:
        raise WolframEvaluationError("UnitVector currently supports exactly two explicit integer arguments.")
    length_value, position = values
    if length_value < 0:
        raise WolframEvaluationError("UnitVector expects a non-negative length.")
    if position < 1 or position > length_value:
        raise WolframEvaluationError("UnitVector position must be between 1 and the vector length.")
    return _evaluated_list_expr(*(
        integer(1 if index == position else 0)
        for index in range(1, length_value + 1)
    ))


def identity_matrix(size: Expr | int) -> Expr:
    dimension = _normalize_integer_argument(size, "IdentityMatrix")
    if dimension < 0:
        raise WolframEvaluationError("IdentityMatrix expects a non-negative integer size.")
    return _evaluated_list_expr(*(
        _evaluated_list_expr(*(integer(1 if row == column else 0) for column in range(1, dimension + 1)))
        for row in range(1, dimension + 1)
    ))


def diagonal_matrix(
    values_expr: Expr,
    offset_expr: Expr | int | None = None,
    size_expr: Expr | int | None = None,
) -> Expr:
    """DiagonalMatrix[list], DiagonalMatrix[list, k], DiagonalMatrix[list, k, n].

    With ``k > 0`` the diagonal moves up by ``k`` positions; with ``k < 0`` it
    moves down. The optional third argument ``n`` overrides the resulting
    matrix size; without it, the matrix is square and large enough to hold the
    full diagonal (``len(values) + |k|`` per side).
    """
    values = _sequence_values(values_expr, "DiagonalMatrix")
    offset = 0 if offset_expr is None else _normalize_integer_argument(offset_expr, "DiagonalMatrix")
    if size_expr is None:
        size = len(values) + abs(offset)
    else:
        size = _normalize_integer_argument(size_expr, "DiagonalMatrix")
        if size < 0:
            raise WolframEvaluationError("DiagonalMatrix size must be non-negative.")

    # Place values along the diagonal at column - row == offset.
    rows: list[Expr] = []
    for row_index in range(size):
        row_items: list[Expr] = []
        for column_index in range(size):
            on_diagonal = (column_index - row_index) == offset
            value_index = row_index if offset >= 0 else row_index + offset
            if on_diagonal and 0 <= value_index < len(values):
                row_items.append(values[value_index])
            else:
                row_items.append(integer(0))
        rows.append(_evaluated_list_expr(*row_items))
    return _evaluated_list_expr(*rows)


def partition(
    expr: Expr,
    size: Expr | int,
    offset: Expr | int | None = None,
    k_spec: Expr | int | None = None,
    padding: Expr | None = None,
) -> Expr:
    """Partition[expr, n], Partition[expr, n, d], Partition[expr, n, d, k],
    Partition[expr, n, d, {kL, kR}], Partition[expr, n, d, kspec, padding].

    The 4- and 5-argument forms cover the cyclic / aligned variants. Without
    the optional ``padding`` argument, out-of-range positions wrap cyclically
    in the practical Wolfram style; with ``padding`` they are filled.
    """
    window = _normalize_integer_argument(size, "Partition")
    step = window if offset is None else _normalize_integer_argument(offset, "Partition")
    if window <= 0 or step <= 0:
        raise WolframEvaluationError("Partition expects positive integer block sizes and offsets.")
    items = _selection_items(expr, "Partition")

    if k_spec is None:
        # Default 2/3-arg form: no overhang at either end (k = {1, n}).
        kL, kR = 1, window
    else:
        kL, kR = _resolve_partition_k_spec(k_spec, window)

    length = len(items)
    start_first = 1 - (kL - 1)
    start_last_target = length - (kR - 1)
    if start_last_target < start_first:
        return _evaluated_list_expr()

    # Largest valid start ≤ target that is congruent to start_first mod step.
    diff = start_last_target - start_first
    num_offsets = diff // step + 1

    results: list[Expr] = []
    for index in range(num_offsets):
        block_start = start_first + index * step
        block_items: list[_SelectionItem] = []
        for offset_index in range(window):
            position = block_start + offset_index
            if 1 <= position <= length:
                block_items.append(items[position - 1])
            elif padding is not None:
                block_items.append(_SelectionItem(index=0, value=padding))
            elif length == 0:
                # No elements to wrap to.
                return _evaluated_list_expr()
            else:
                cyclic_position = ((position - 1) % length) + 1
                block_items.append(items[cyclic_position - 1])
        results.append(_selection_elements(expr, block_items, "Partition"))
    return _evaluated_list_expr(*results)


def _resolve_partition_k_spec(k_spec: Expr | int, window: int) -> tuple[int, int]:
    """Map Partition's k argument to a concrete ``(kL, kR)`` pair.

    Integer ``1`` is ``{1, 1}``; integer ``-1`` is ``{n, n}`` (full cyclic).
    Other integer ``k`` is currently treated as ``{k, k}``. For lists, ``-1``
    in either slot resolves to ``n``.
    """
    if isinstance(k_spec, int):
        spec_value = k_spec
    elif isinstance(k_spec, Integer):
        spec_value = k_spec.value
    elif isinstance(k_spec, Call) and k_spec.has_head("List") and len(k_spec.arguments) == 2 \
            and all(isinstance(item, Integer) for item in k_spec.arguments):
        kL_raw = k_spec.arguments[0].value  # type: ignore[union-attr]
        kR_raw = k_spec.arguments[1].value  # type: ignore[union-attr]
        return _normalize_partition_alignment(kL_raw, window), _normalize_partition_alignment(kR_raw, window)
    else:
        raise WolframEvaluationError(
            "Partition currently expects an integer or {kL, kR} alignment."
        )
    if spec_value == -1:
        return window, window
    return _normalize_partition_alignment(spec_value, window), _normalize_partition_alignment(spec_value, window)


def _normalize_partition_alignment(value: int, window: int) -> int:
    if value == -1:
        return window
    if 1 <= value <= window:
        return value
    raise WolframEvaluationError(
        "Partition alignment must be -1 or an integer between 1 and the block size."
    )


def block_map(function: Expr, expr: Expr, size: Expr | int, offset: Expr | int | None = None) -> Expr:
    window = _normalize_integer_argument(size, "BlockMap")
    step = window if offset is None else _normalize_integer_argument(offset, "BlockMap")
    if window <= 0 or step <= 0:
        raise WolframEvaluationError("BlockMap expects positive integer block sizes and offsets.")
    items = _selection_items(expr, "BlockMap")
    results: list[Expr] = []
    for start in range(0, len(items) - window + 1, step):
        block_expr = _selection_elements(expr, items[start:start + window], "BlockMap")
        results.append(_apply_callable(function, (block_expr,)))
    return _evaluated_list_expr(*results)


def take_list(expr: Expr, specs_expr: Expr) -> Expr:
    if not isinstance(specs_expr, Call) or not specs_expr.has_head("List"):
        raise WolframEvaluationError("TakeList expects a list of specifications.")
    remaining = expr
    taken: list[Expr] = []
    for spec in specs_expr.arguments:
        if isinstance(spec, Symbol) and spec.name == "All":
            taken.append(remaining)
            entries = _association_entries(remaining)
            if entries is not None:
                remaining = _association_expr([])
            elif isinstance(remaining, Call):
                remaining = _rebuild(remaining, ())
            else:
                remaining = remaining
            continue
        taken.append(take(remaining, spec))
        remaining = drop(remaining, spec)
    return _evaluated_list_expr(*taken)


def take_drop(expr: Expr, spec: Expr) -> Expr:
    return _evaluated_list_expr(take(expr, spec), drop(expr, spec))


def fold(function: Expr, *rest: Expr) -> Expr:
    """Fold[f, init, expr] or Fold[f, expr] (no initial value).

    The two-argument form ``Fold[f, expr]`` uses ``First[expr]`` as the
    initial value and folds over ``Rest[expr]``, matching the kernel's
    contract. ``expr`` must be nonempty in this form.
    """
    if len(rest) == 1:
        # Fold[f, expr] — drop into the first/rest split.
        items = list(_selection_items(rest[0], "Fold"))
        if not items:
            raise WolframEvaluationError("Fold[f, expr] expects a nonempty sequence.")
        current = items[0].value
        for item in items[1:]:
            current = _apply_callable(function, (current, item.value))
        return current
    if len(rest) == 2:
        initial, expr = rest
        current = initial
        for item in _selection_items(expr, "Fold"):
            current = _apply_callable(function, (current, item.value))
        return current
    raise WolframEvaluationError("Fold expects two or three arguments.")


def fold_list(function: Expr, *rest: Expr) -> Expr:
    """FoldList[f, init, expr] or FoldList[f, expr] (no initial value).

    The two-argument form folds with ``First[expr]`` as the initial value
    and over ``Rest[expr]``; the result includes that initial value as
    the leading entry. Matches the kernel's contract.
    """
    if len(rest) == 1:
        items = list(_selection_items(rest[0], "FoldList"))
        if not items:
            return _evaluated_list_expr()
        current = items[0].value
        results: list[Expr] = [current]
        for item in items[1:]:
            current = _apply_callable(function, (current, item.value))
            results.append(current)
        return _evaluated_list_expr(*results)
    if len(rest) == 2:
        initial, expr = rest
        current = initial
        results = [initial]
        for item in _selection_items(expr, "FoldList"):
            current = _apply_callable(function, (current, item.value))
            results.append(current)
        return _evaluated_list_expr(*results)
    raise WolframEvaluationError("FoldList expects two or three arguments.")


def sequence_fold(function: Expr, initial_expr: Expr, expr: Expr, arity: Expr | int | None = None) -> Expr:
    history_expr = sequence_fold_list(function, initial_expr, expr, arity)
    assert isinstance(history_expr, Call) and history_expr.has_head("List")
    return history_expr.arguments[-1]


def sequence_fold_list(function: Expr, initial_expr: Expr, expr: Expr, arity: Expr | int | None = None) -> Expr:
    initial_values = _sequence_values(initial_expr, "SequenceFoldList")
    inputs = list(_sequence_values(expr, "SequenceFoldList"))
    if not initial_values:
        raise WolframEvaluationError("SequenceFoldList expects at least one initial value.")

    state_values = list(initial_values)
    results = list(initial_values)
    argument_count = len(initial_values) + 1 if arity is None else _normalize_integer_argument(arity, "SequenceFoldList")
    if argument_count < len(initial_values):
        raise WolframEvaluationError("SequenceFoldList expects an argument count greater than or equal to the number of initial values.")
    consumed_per_step = argument_count - len(initial_values)
    if consumed_per_step <= 0:
        raise WolframEvaluationError("SequenceFoldList currently expects each step to consume at least one input element.")

    index = 0
    while index + consumed_per_step <= len(inputs):
        step_arguments = tuple(state_values[-len(initial_values):]) + tuple(inputs[index:index + consumed_per_step])
        current = _apply_callable(function, step_arguments)
        results.append(current)
        state_values.append(current)
        index += consumed_per_step
    return _evaluated_list_expr(*results)


def _fold_while_history_arguments(results: Sequence[Expr], history_spec: Expr | int | None) -> tuple[Expr, ...]:
    if history_spec is None:
        return (results[-1],)
    if isinstance(history_spec, Symbol) and history_spec.name == "All":
        return tuple(results)
    history_length = _normalize_integer_argument(history_spec, "FoldWhileList")
    if history_length <= 0:
        raise WolframEvaluationError("FoldWhileList expects a positive history length or All.")
    return tuple(results[-min(history_length, len(results)):])


def fold_while_list(
    function: Expr,
    initial: Expr,
    expr: Expr,
    test: Expr,
    history_spec: Expr | int | None = None,
    extra_results: Expr | int | None = None,
) -> Expr:
    inputs = [item.value for item in _selection_items(expr, "FoldWhileList")]
    results: list[Expr] = [initial]

    if not _predicate_succeeds_with_arguments(test, _fold_while_history_arguments(results, history_spec)):
        return _evaluated_list_expr(*results)

    failure_detected = False
    index = 0
    while index < len(inputs):
        updated = _apply_callable(function, (results[-1], inputs[index]))
        results.append(updated)
        index += 1
        if not _predicate_succeeds_with_arguments(test, _fold_while_history_arguments(results, history_spec)):
            failure_detected = True
            break

    if not failure_detected:
        return _evaluated_list_expr(*results)

    trailing = 0 if extra_results is None else _normalize_integer_argument(extra_results, "FoldWhileList")
    if trailing < 0:
        keep_count = max(1, len(results) + trailing)
        return _evaluated_list_expr(*results[:keep_count])

    while trailing > 0 and index < len(inputs):
        results.append(_apply_callable(function, (results[-1], inputs[index])))
        index += 1
        trailing -= 1
    return _evaluated_list_expr(*results)


def fold_while(
    function: Expr,
    initial: Expr,
    expr: Expr,
    test: Expr,
    history_spec: Expr | int | None = None,
    extra_results: Expr | int | None = None,
) -> Expr:
    history_expr = fold_while_list(function, initial, expr, test, history_spec, extra_results)
    assert isinstance(history_expr, Call) and history_expr.has_head("List")
    return history_expr.arguments[-1]


def _fold_pair_project(pair_values: tuple[Expr, Expr], projection: Expr | None) -> Expr:
    if projection is None:
        return pair_values[0]
    return _apply_callable(projection, (list_expr(*pair_values),))


def fold_pair_list(function: Expr, initial: Expr, expr: Expr, projection: Expr | None = None) -> Expr:
    inputs = [item.value for item in _selection_items(expr, "FoldPairList")]
    current = initial
    results: list[Expr] = []
    for input_value in inputs:
        pair_expr = _apply_callable(function, (current, input_value))
        if not isinstance(pair_expr, Call) or not pair_expr.has_head("List") or len(pair_expr.arguments) != 2:
            raise WolframEvaluationError(
                f"FoldPairList expects each function application to return a list of two elements, got {pair_expr.to_input_form()}."
            )
        pair_values = (pair_expr.arguments[0], pair_expr.arguments[1])
        results.append(_fold_pair_project(pair_values, projection))
        current = pair_values[1]
    return _evaluated_list_expr(*results)


def fold_pair(function: Expr, initial: Expr, expr: Expr, projection: Expr | None = None) -> Expr:
    history_expr = fold_pair_list(function, initial, expr, projection)
    assert isinstance(history_expr, Call) and history_expr.has_head("List")
    if not history_expr.arguments:
        return call("FoldPair", function, initial, expr) if projection is None else call("FoldPair", function, initial, expr, projection)
    return history_expr.arguments[-1]


def length_while(expr: Expr, criterion: Expr) -> Integer:
    count = 0
    for item in _selection_items(expr, "LengthWhile"):
        if not _predicate_succeeds(criterion, item.value):
            break
        count += 1
    return integer(count)


def first_case(
    expr: Expr,
    pattern_spec: Expr,
    default: Expr | object = _MISSING,
    spec: Expr | int | tuple[int, int] | None = None,
) -> Expr:
    results = cases(expr, pattern_spec, spec=spec, limit=1)
    if results.arguments:
        return results.arguments[0]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    return _missing_not_found()


def _is_heads_option_rule(expr: Expr) -> bool:
    """True for ``Heads -> True/False`` and ``Heads :> True/False`` rules."""
    if not isinstance(expr, Call):
        return False
    if not (expr.has_head("Rule") or expr.has_head("RuleDelayed")):
        return False
    if len(expr.arguments) != 2:
        return False
    key, value = expr.arguments
    if not (isinstance(key, Symbol) and key.name == "Heads"):
        return False
    return isinstance(value, Symbol) and value.name in {"True", "False"}


def position(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    limit: Expr | int | None = None,
    *,
    include_heads: bool = True,
) -> Expr:
    level_spec: Expr | int | tuple[int, int] = (0, _LEVEL_INFINITY) if spec is None else spec
    level_min, level_max = _normalize_level_spec(level_spec)
    remaining = _normalize_match_limit(limit)
    results: list[Expr] = []

    def append_match_path(path: Sequence[Expr]) -> None:
        nonlocal remaining
        results.append(list_expr(*path))
        if remaining is not None:
            remaining -= 1

    def recurse(current: Expr, positive_level: int, path: list[Expr]) -> None:
        nonlocal remaining
        if remaining == 0:
            return

        entries = _association_entries(current)
        if entries is not None:
            if include_heads:
                recurse(current.head_expr, positive_level + 1, [*path, integer(0)])
                if remaining == 0:
                    return
            for entry in entries:
                recurse(entry.value, positive_level + 1, [*path, call("Key", entry.key)])
                if remaining == 0:
                    return
            negative_level = -depth(current)
            if (
                _level_bounds_match(positive_level, negative_level, level_min, level_max)
                and _match_pattern(current, pattern) is not None
            ):
                append_match_path(path)
            return

        if isinstance(current, Call):
            if include_heads:
                recurse(current.head_expr, positive_level + 1, [*path, integer(0)])
                if remaining == 0:
                    return
            for index, argument in enumerate(current.arguments, start=1):
                recurse(argument, positive_level + 1, [*path, integer(index)])
                if remaining == 0:
                    return

        negative_level = -depth(current)
        if (
            _level_bounds_match(positive_level, negative_level, level_min, level_max)
            and _match_pattern(current, pattern) is not None
        ):
            append_match_path(path)

    recurse(expr, 0, [])
    return list_expr(*results)


def member_q(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    *,
    include_heads: bool = False,
) -> Symbol:
    """``MemberQ[expr, patt]`` / ``MemberQ[expr, patt, levelspec]`` /
    ``MemberQ[expr, patt, levelspec, Heads -> True/False]``.

    The Wolfram default for ``MemberQ`` is level ``{1}`` and
    ``Heads -> False`` — i.e. immediate non-head members. Tungsten's
    structural traversal matches that contract and also honors the
    explicit ``Heads`` option when supplied.
    """
    effective_spec: Expr | int | tuple[int, int] = (1, 1) if spec is None else spec
    positions = position(expr, pattern, spec=effective_spec, limit=1, include_heads=include_heads)
    assert isinstance(positions, Call) and positions.has_head("List")
    return _bool_symbol(bool(positions.arguments))


def _duplicate_test_succeeds(test: Expr | None, left: Expr, right: Expr) -> bool:
    if test is None:
        return left == right
    evaluated = evaluate(_apply_callable(test, (left, right)))
    return isinstance(evaluated, Symbol) and evaluated.name == "True"


def _same_test_succeeds(test: Expr | None, left: Expr, right: Expr) -> bool:
    return _duplicate_test_succeeds(test, left, right)


def _contains_by_same_test(items: Sequence[Expr], candidate: Expr, test: Expr | None) -> bool:
    return any(_same_test_succeeds(test, candidate, item) for item in items)


def delete_duplicates(expr: Expr, test: Expr | None = None) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        kept: list[_AssociationEntry] = []
        seen_values: list[Expr] = []
        for entry in entries:
            if any(_duplicate_test_succeeds(test, entry.value, prior) for prior in seen_values):
                continue
            kept.append(entry)
            seen_values.append(entry.value)
        return _association_expr(kept)

    compound = _require_compound(expr, "DeleteDuplicates")
    kept_arguments: list[Expr] = []
    for argument in compound.arguments:
        if any(_duplicate_test_succeeds(test, argument, prior) for prior in kept_arguments):
            continue
        kept_arguments.append(argument)
    return _rebuild(compound, kept_arguments)


def delete_duplicates_by(expr: Expr, function: Expr, test: Expr | None = None) -> Expr:
    """``DeleteDuplicatesBy[expr, f]`` /
    ``DeleteDuplicatesBy[expr, f, test]``.

    Each element's key is computed via ``f`` and tested against
    previously kept keys. With no test, structural equality decides
    duplication. With a binary test, the element is dropped when
    ``test[earlier_key, current_key]`` evaluates to explicit ``True``
    for any previously kept key.
    """

    def is_duplicate_key(seen_keys: Sequence[Expr], key: Expr) -> bool:
        if test is None:
            return any(key == prior for prior in seen_keys)
        for prior in seen_keys:
            outcome = evaluate(_apply_callable(test, (prior, key)))
            if isinstance(outcome, Symbol) and outcome.name == "True":
                return True
        return False

    entries = _association_entries(expr)
    if entries is not None:
        kept: list[_AssociationEntry] = []
        seen_keys: list[Expr] = []
        for entry in entries:
            key = _apply_callable(function, (entry.value,))
            if is_duplicate_key(seen_keys, key):
                continue
            kept.append(entry)
            seen_keys.append(key)
        return _association_expr(kept)

    compound = _require_compound(expr, "DeleteDuplicatesBy")
    kept_arguments: list[Expr] = []
    seen_keys: list[Expr] = []
    for argument in compound.arguments:
        key = _apply_callable(function, (argument,))
        if is_duplicate_key(seen_keys, key):
            continue
        kept_arguments.append(argument)
        seen_keys.append(key)
    return _rebuild(compound, kept_arguments)


def duplicate_free_q(expr: Expr, test: Expr | None = None) -> Symbol:
    entries = _association_entries(expr)
    values = [entry.value for entry in entries] if entries is not None else list(_require_compound(expr, "DuplicateFreeQ").arguments)
    for index, left in enumerate(values):
        for right in values[index + 1:]:
            if _duplicate_test_succeeds(test, left, right):
                return _bool_symbol(False)
    return _bool_symbol(True)


def _list_rows(expr: Expr, function_name: str) -> list[tuple[Expr, ...]] | None:
    if not isinstance(expr, Call) or not expr.has_head("List"):
        return None
    rows: list[tuple[Expr, ...]] = []
    for argument in expr.arguments:
        if not isinstance(argument, Call) or not argument.has_head("List"):
            return None
        rows.append(argument.arguments)
    return rows


def dot(arguments: Sequence[Expr]) -> Expr:
    if len(arguments) < 2:
        raise WolframEvaluationError("Dot expects at least two arguments.")

    def dot_two(left: Expr, right: Expr) -> Expr:
        if isinstance(left, SparseArrayExpr) and isinstance(right, SparseArrayExpr):
            return _sparse_dot(left, right)
        if isinstance(left, SparseArrayExpr):
            return dot_two(sparse_array_normal(left), right)
        if isinstance(right, SparseArrayExpr):
            return dot_two(left, sparse_array_normal(right))

        left_rows = _list_rows(left, "Dot")
        right_rows = _list_rows(right, "Dot")

        if isinstance(left, Call) and left.has_head("List") and isinstance(right, Call) and right.has_head("List") and left_rows is None and right_rows is None:
            if len(left.arguments) != len(right.arguments):
                raise WolframEvaluationError("Dot expects vectors of the same length.")
            return call("Plus", *(
                call("Times", left_item, right_item)
                for left_item, right_item in zip(left.arguments, right.arguments, strict=True)
            ))

        if left_rows is not None and right_rows is None and isinstance(right, Call) and right.has_head("List"):
            return list_expr(*(dot_two(list_expr(*row), right) for row in left_rows))

        if left_rows is None and isinstance(left, Call) and left.has_head("List") and right_rows is not None:
            if len(left.arguments) != len(right_rows):
                raise WolframEvaluationError("Dot expects compatible vector/matrix dimensions.")
            right_width = len(right_rows[0]) if right_rows else 0
            if any(len(row) != right_width for row in right_rows):
                raise WolframEvaluationError("Dot currently expects rectangular matrices.")
            columns = [
                list_expr(*(row[column_index] for row in right_rows))
                for column_index in range(right_width)
            ]
            return list_expr(*(dot_two(left, column) for column in columns))

        if left_rows is not None and right_rows is not None:
            left_width = len(left_rows[0]) if left_rows else 0
            if any(len(row) != left_width for row in left_rows):
                raise WolframEvaluationError("Dot currently expects rectangular matrices.")
            right_width = len(right_rows[0]) if right_rows else 0
            if any(len(row) != right_width for row in right_rows) or left_width != len(right_rows):
                raise WolframEvaluationError("Dot currently expects compatible matrix dimensions.")
            return list_expr(*(dot_two(list_expr(*row), right) for row in left_rows))

        raise WolframEvaluationError("Dot currently supports List vectors and List matrices only.")

    current = arguments[0]
    for argument in arguments[1:]:
        current = evaluate(dot_two(current, argument))
    return current


def _sparse_dot(left: SparseArrayExpr, right: SparseArrayExpr) -> Expr:
    if left.fill_value != integer(0) or right.fill_value != integer(0):
        return dot((sparse_array_normal(left), sparse_array_normal(right)))

    left_rank = len(left.dimensions)
    right_rank = len(right.dimensions)
    if left_rank not in {1, 2} or right_rank not in {1, 2}:
        raise WolframEvaluationError("Dot currently supports sparse vectors and matrices only.")

    left_entries = _sparse_array_entry_map(left)
    right_entries = _sparse_array_entry_map(right)

    def add_to(target: dict[tuple[int, ...], Expr], indices: tuple[int, ...], contribution: Expr) -> None:
        if contribution == integer(0):
            return
        previous = target.get(indices)
        target[indices] = contribution if previous is None else evaluate(call("Plus", previous, contribution))

    if left_rank == 1 and right_rank == 1:
        if left.dimensions[0] != right.dimensions[0]:
            raise WolframEvaluationError("Dot expects vectors of the same length.")
        total_terms = [
            evaluate(call("Times", left_value, right_entries[indices]))
            for indices, left_value in left_entries.items()
            if indices in right_entries
        ]
        return evaluate(call("Plus", *total_terms)) if total_terms else integer(0)

    if left_rank == 2 and right_rank == 1:
        rows, width = left.dimensions
        if width != right.dimensions[0]:
            raise WolframEvaluationError("Dot expects compatible sparse matrix/vector dimensions.")
        output: dict[tuple[int, ...], Expr] = {}
        for (row, column), left_value in left_entries.items():
            right_value = right_entries.get((column,))
            if right_value is not None:
                add_to(output, (row,), evaluate(call("Times", left_value, right_value)))
        return _sparse_array_expr(
            (rows,),
            (_SparseArrayEntry(indices, value) for indices, value in output.items()),
            integer(0),
        )

    if left_rank == 1 and right_rank == 2:
        width = left.dimensions[0]
        right_rows, columns = right.dimensions
        if width != right_rows:
            raise WolframEvaluationError("Dot expects compatible sparse vector/matrix dimensions.")
        output: dict[tuple[int, ...], Expr] = {}
        for (row, column), right_value in right_entries.items():
            left_value = left_entries.get((row,))
            if left_value is not None:
                add_to(output, (column,), evaluate(call("Times", left_value, right_value)))
        return _sparse_array_expr(
            (columns,),
            (_SparseArrayEntry(indices, value) for indices, value in output.items()),
            integer(0),
        )

    rows, width = left.dimensions
    right_rows, columns = right.dimensions
    if width != right_rows:
        raise WolframEvaluationError("Dot expects compatible sparse matrix dimensions.")
    right_by_row: dict[int, list[tuple[int, Expr]]] = {}
    for (row, column), value in right_entries.items():
        right_by_row.setdefault(row, []).append((column, value))

    output: dict[tuple[int, ...], Expr] = {}
    for (row, shared), left_value in left_entries.items():
        for column, right_value in right_by_row.get(shared, ()):
            add_to(output, (row, column), evaluate(call("Times", left_value, right_value)))
    return _sparse_array_expr(
        (rows, columns),
        (_SparseArrayEntry(indices, value) for indices, value in output.items()),
        integer(0),
    )


def _is_one_expr_value(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value == 1
    if isinstance(expr, RationalNumber):
        return expr.value == 1
    return False


def _expr_sum(terms: Sequence[Expr]) -> Expr:
    return evaluate(call("Plus", *terms)) if terms else integer(0)


def _expr_product(factors: Sequence[Expr]) -> Expr:
    return evaluate(call("Times", *factors)) if factors else integer(1)


def _expr_negate(expr: Expr) -> Expr:
    if _is_exact_zero(expr):
        return integer(0)
    return evaluate(call("Times", integer(-1), expr))


def _expr_subtract(left: Expr, right: Expr) -> Expr:
    if _is_exact_zero(right):
        return left
    return evaluate(call("Plus", left, _expr_negate(right)))


def _expr_inverse(expr: Expr) -> Expr:
    if _is_one_expr_value(expr):
        return integer(1)
    return evaluate(call("Power", expr, integer(-1)))


def _expr_divide(numerator: Expr, denominator: Expr) -> Expr:
    if _is_exact_zero(numerator):
        return integer(0)
    if _is_one_expr_value(denominator):
        return numerator
    return evaluate(call("Times", numerator, _expr_inverse(denominator)))


def _matrix_rows(expr: Expr, function_name: str) -> list[list[Expr]]:
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) != 2:
            raise WolframEvaluationError(f"{function_name} expects a matrix.")
        rows, columns = expr.dimensions
        return [
            [_sparse_array_value_at(expr, (row, column)) for column in range(1, columns + 1)]
            for row in range(1, rows + 1)
        ]
    rows = _list_rows(expr, function_name)
    if rows is None:
        raise WolframEvaluationError(f"{function_name} expects a matrix.")
    width = len(rows[0]) if rows else 0
    if any(len(row) != width for row in rows):
        raise WolframEvaluationError(f"{function_name} expects a rectangular matrix.")
    return [list(row) for row in rows]


def _require_square_matrix_rows(expr: Expr, function_name: str) -> list[list[Expr]]:
    rows = _matrix_rows(expr, function_name)
    width = len(rows[0]) if rows else 0
    if len(rows) != width:
        raise WolframEvaluationError(f"{function_name} expects a square matrix.")
    return rows


def _require_square_matrix_size(expr: Expr, function_name: str) -> int:
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) != 2 or expr.dimensions[0] != expr.dimensions[1]:
            raise WolframEvaluationError(f"{function_name} expects a square matrix.")
        return expr.dimensions[0]
    return len(_require_square_matrix_rows(expr, function_name))


def _fraction_matrix(rows: Sequence[Sequence[Expr]]) -> list[list[Fraction]] | None:
    matrix: list[list[Fraction]] = []
    for row in rows:
        fraction_row: list[Fraction] = []
        for value in row:
            fraction = _exact_fraction(value)
            if fraction is None:
                return None
            fraction_row.append(fraction)
        matrix.append(fraction_row)
    return matrix


def _fraction_to_expr(value: Fraction) -> Expr:
    return rational_number(value.numerator, value.denominator)


def _determinant_exact_numeric(rows: Sequence[Sequence[Expr]]) -> Expr | None:
    matrix = _fraction_matrix(rows)
    if matrix is None:
        return None
    n = len(matrix)
    if n == 0:
        return integer(1)

    sign = 1
    for column in range(n):
        pivot_row = next((row for row in range(column, n) if matrix[row][column] != 0), None)
        if pivot_row is None:
            return integer(0)
        if pivot_row != column:
            matrix[column], matrix[pivot_row] = matrix[pivot_row], matrix[column]
            sign *= -1
        pivot = matrix[column][column]
        for row in range(column + 1, n):
            if matrix[row][column] == 0:
                continue
            factor = matrix[row][column] / pivot
            for target_column in range(column, n):
                matrix[row][target_column] -= factor * matrix[column][target_column]

    determinant = Fraction(sign, 1)
    for index in range(n):
        determinant *= matrix[index][index]
    return _fraction_to_expr(determinant)


def _permutation_sign(values: Sequence[int]) -> int:
    inversions = 0
    for left_index, left in enumerate(values):
        for right in values[left_index + 1:]:
            if left > right:
                inversions += 1
    return -1 if inversions % 2 else 1


def _determinant_from_candidates(row_candidates: Sequence[Sequence[tuple[int, Expr]]]) -> Expr:
    n = len(row_candidates)
    if n == 0:
        return integer(1)
    if any(not candidates for candidates in row_candidates):
        return integer(0)

    terms: list[Expr] = []

    def recurse(row_index: int, used_columns: set[int], columns: list[int], factors: list[Expr]) -> None:
        if row_index == n:
            sign = _permutation_sign(columns)
            term_factors = ([integer(-1)] if sign < 0 else []) + factors
            terms.append(_expr_product(term_factors))
            return
        for column, value in row_candidates[row_index]:
            if column in used_columns or _is_exact_zero(value):
                continue
            used_columns.add(column)
            columns.append(column)
            factors.append(value)
            recurse(row_index + 1, used_columns, columns, factors)
            factors.pop()
            columns.pop()
            used_columns.remove(column)

    recurse(0, set(), [], [])
    return _expr_sum(terms)


def _determinant_symbolic(rows: Sequence[Sequence[Expr]]) -> Expr:
    candidates = [
        [(column_index, value) for column_index, value in enumerate(row) if not _is_exact_zero(value)]
        for row in rows
    ]
    return _determinant_from_candidates(candidates)


def _determinant_from_rows(rows: Sequence[Sequence[Expr]]) -> Expr:
    numeric = _determinant_exact_numeric(rows)
    if numeric is not None:
        return numeric
    return _determinant_symbolic(rows)


def _determinant_sparse(array: SparseArrayExpr) -> Expr:
    if len(array.dimensions) != 2 or array.dimensions[0] != array.dimensions[1]:
        raise WolframEvaluationError("Det expects a square matrix.")
    if array.fill_value != integer(0):
        return _determinant_from_rows(_matrix_rows(array, "Det"))
    n = array.dimensions[0]
    rows: list[list[tuple[int, Expr]]] = [[] for _ in range(n)]
    for entry in array.entries:
        row, column = entry.indices
        if not _is_exact_zero(entry.value):
            rows[row - 1].append((column - 1, entry.value))
    return _determinant_from_candidates(rows)


def det(expr: Expr) -> Expr:
    if isinstance(expr, SparseArrayExpr):
        return _determinant_sparse(expr)
    rows = _require_square_matrix_rows(expr, "Det")
    return _determinant_from_rows(rows)


def _inverse_exact_numeric(rows: Sequence[Sequence[Expr]]) -> Expr | None:
    matrix = _fraction_matrix(rows)
    if matrix is None:
        return None
    n = len(matrix)
    augmented = [
        [*matrix[row], *(Fraction(1 if row == column else 0, 1) for column in range(n))]
        for row in range(n)
    ]

    for column in range(n):
        pivot_row = next((row for row in range(column, n) if augmented[row][column] != 0), None)
        if pivot_row is None:
            raise WolframEvaluationError("Inverse expects a nonsingular matrix.")
        if pivot_row != column:
            augmented[column], augmented[pivot_row] = augmented[pivot_row], augmented[column]
        pivot = augmented[column][column]
        augmented[column] = [value / pivot for value in augmented[column]]
        for row in range(n):
            if row == column:
                continue
            factor = augmented[row][column]
            if factor == 0:
                continue
            augmented[row] = [
                value - factor * pivot_value
                for value, pivot_value in zip(augmented[row], augmented[column], strict=True)
            ]

    return _evaluated_list_expr(*(
        _evaluated_list_expr(*(_fraction_to_expr(value) for value in augmented[row][n:]))
        for row in range(n)
    ))


def _minor_rows(rows: Sequence[Sequence[Expr]], remove_row: int, remove_column: int) -> list[list[Expr]]:
    return [
        [value for column, value in enumerate(row) if column != remove_column]
        for row_index, row in enumerate(rows)
        if row_index != remove_row
    ]


def _sparse_diagonal_inverse(array: SparseArrayExpr) -> Expr | None:
    if len(array.dimensions) != 2 or array.dimensions[0] != array.dimensions[1] or array.fill_value != integer(0):
        return None
    size = array.dimensions[0]
    diagonal: dict[int, Expr] = {}
    for entry in array.entries:
        row, column = entry.indices
        if row != column:
            return None
        diagonal[row] = entry.value
    if len(diagonal) != size:
        raise WolframEvaluationError("Inverse expects a nonsingular matrix.")
    entries: list[_SparseArrayEntry] = []
    for index in range(1, size + 1):
        value = diagonal[index]
        if _is_exact_zero(value):
            raise WolframEvaluationError("Inverse expects a nonsingular matrix.")
        entries.append(_SparseArrayEntry((index, index), _expr_inverse(value)))
    return _sparse_array_expr(array.dimensions, entries, integer(0))


def inverse(expr: Expr) -> Expr:
    if isinstance(expr, SparseArrayExpr):
        sparse_diagonal = _sparse_diagonal_inverse(expr)
        if sparse_diagonal is not None:
            return sparse_diagonal
    rows = _require_square_matrix_rows(expr, "Inverse")
    numeric = _inverse_exact_numeric(rows)
    if numeric is not None:
        return numeric

    determinant = _determinant_from_rows(rows)
    if _is_exact_zero(determinant):
        raise WolframEvaluationError("Inverse expects a nonsingular matrix.")
    size = len(rows)
    inverse_rows: list[Expr] = []
    for output_row in range(size):
        values: list[Expr] = []
        for output_column in range(size):
            cofactor = _determinant_from_rows(_minor_rows(rows, output_column, output_row))
            if (output_row + output_column) % 2:
                cofactor = _expr_negate(cofactor)
            values.append(_expr_divide(cofactor, determinant))
        inverse_rows.append(_evaluated_list_expr(*values))
    return _evaluated_list_expr(*inverse_rows)


def _sparse_identity_matrix(size: int) -> SparseArrayExpr:
    return _sparse_array_expr(
        (size, size),
        (_SparseArrayEntry((index, index), integer(1)) for index in range(1, size + 1)),
        integer(0),
    )


def matrix_power(expr: Expr, exponent_expr: Expr | int) -> Expr:
    exponent = _normalize_integer_argument(exponent_expr, "MatrixPower")
    size = _require_square_matrix_size(expr, "MatrixPower")
    if exponent == 0:
        return _sparse_identity_matrix(size) if isinstance(expr, SparseArrayExpr) else identity_matrix(size)

    base = inverse(expr) if exponent < 0 else expr
    remaining = abs(exponent)
    result: Expr = _sparse_identity_matrix(size) if isinstance(base, SparseArrayExpr) else identity_matrix(size)
    while remaining:
        if remaining & 1:
            result = evaluate(dot((result, base)))
        remaining >>= 1
        if remaining:
            base = evaluate(dot((base, base)))
    return result


def _vector_values(expr: Expr, function_name: str) -> tuple[Expr, ...]:
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) != 1:
            raise WolframEvaluationError(f"{function_name} expects vectors.")
        return tuple(_sparse_array_value_at(expr, (index,)) for index in range(1, expr.dimensions[0] + 1))
    if isinstance(expr, Call) and expr.has_head("List"):
        return expr.arguments
    raise WolframEvaluationError(f"{function_name} expects vectors.")


def cross(left: Expr, right: Expr) -> Expr:
    left_values = _vector_values(left, "Cross")
    right_values = _vector_values(right, "Cross")
    if len(left_values) != len(right_values) or len(left_values) not in {2, 3}:
        raise WolframEvaluationError("Cross currently supports pairs of 2D or 3D vectors.")
    if len(left_values) == 2:
        return _expr_subtract(
            _expr_product((left_values[0], right_values[1])),
            _expr_product((left_values[1], right_values[0])),
        )
    result_values = (
        _expr_subtract(_expr_product((left_values[1], right_values[2])), _expr_product((left_values[2], right_values[1]))),
        _expr_subtract(_expr_product((left_values[2], right_values[0])), _expr_product((left_values[0], right_values[2]))),
        _expr_subtract(_expr_product((left_values[0], right_values[1])), _expr_product((left_values[1], right_values[0]))),
    )
    if isinstance(left, SparseArrayExpr) or isinstance(right, SparseArrayExpr):
        return _sparse_array_expr(
            (3,),
            (_SparseArrayEntry((index,), value) for index, value in enumerate(result_values, start=1)),
            integer(0),
        )
    return _evaluated_list_expr(*result_values)


def _combine_terms(terms: Sequence[Expr], combiner: Expr | None) -> Expr:
    if combiner is None or (isinstance(combiner, Symbol) and _system_dispatch_name(combiner) == "Plus"):
        return _expr_sum(terms)
    return evaluate(_apply_callable(combiner, tuple(terms)))


def tr(expr: Expr, combiner: Expr | None = None, level_expr: Expr | None = None) -> Expr:
    """``Tr[array]`` / ``Tr[array, f]`` / ``Tr[array, f, n]``.

    The two-argument form folds the diagonal of a vector or matrix
    through ``f``. The three-argument form is a rank-restricted
    contraction: it folds along the first ``n`` axes (always combining
    using ``f``), so ``Tr[m, Plus, 1]`` of a matrix is the column-wise
    sum (equivalent to ``Total[m]`` here, which folds level 1).
    """
    if level_expr is None:
        dimensions = _array_dimensions(expr, "Tr")
        if len(dimensions) == 1:
            terms = [_array_value_at(expr, (index,)) for index in range(1, dimensions[0] + 1)]
            return _combine_terms(terms, combiner)
        if len(dimensions) != 2:
            raise WolframEvaluationError("Tr currently supports vectors and matrices.")
        diagonal_count = min(dimensions)
        if isinstance(expr, SparseArrayExpr) and expr.fill_value == integer(0):
            terms = [
                entry.value
                for entry in expr.entries
                if entry.indices[0] == entry.indices[1] and entry.indices[0] <= diagonal_count
            ]
            return _combine_terms(terms, combiner)
        terms = [_array_value_at(expr, (index, index)) for index in range(1, diagonal_count + 1)]
        return _combine_terms(terms, combiner)

    if not isinstance(level_expr, Integer) or level_expr.value < 1:
        raise WolframEvaluationError("Tr level must be a positive integer.")
    level = level_expr.value
    if combiner is None:
        combiner = symbol("Plus")
    return _tr_at_level(expr, combiner, level)


def _tr_at_level(expr: Expr, combiner: Expr, level: int) -> Expr:
    """Fold the first ``level`` axes of an array through ``combiner``.

    ``Tr[m, Plus, 1]`` is column-wise sum; ``Tr[t, Times, 2]`` for a
    rank-3 tensor multiplies entries along the first two axes
    pairwise. Tungsten requires the array to actually have ``level``
    immediate-list axes so each combine has consistent arity.
    """
    if level == 0:
        return expr
    if level == 1:
        compound = _require_compound(expr, "Tr")
        if not compound.has_head("List"):
            raise WolframEvaluationError("Tr expects a List at every contracted level.")
        # When the inner items are themselves lists of equal width, contract
        # column-wise; otherwise contract scalar arguments.
        if all(isinstance(arg, Call) and arg.has_head("List") for arg in compound.arguments):
            row_lengths = {len(arg.arguments) for arg in compound.arguments}
            if len(row_lengths) == 1:
                width = row_lengths.pop()
                columns = [
                    [arg.arguments[index] for arg in compound.arguments]
                    for index in range(width)
                ]
                return _evaluated_list_expr(*(_combine_terms(col, combiner) for col in columns))
        return _combine_terms(compound.arguments, combiner)
    # Recurse into each child first so Tr[t, f, k] for k > 1 walks the
    # tensor depth-first, then fold the resulting contracted siblings.
    compound = _require_compound(expr, "Tr")
    if not compound.has_head("List"):
        raise WolframEvaluationError("Tr expects a List at every contracted level.")
    contracted_children = [_tr_at_level(child, combiner, level - 1) for child in compound.arguments]
    return _tr_at_level(list_expr(*contracted_children), combiner, 1)


def levi_civita_tensor(dimension_expr: Expr, head_expr: Expr | None = None) -> Expr:
    dimension = _normalize_integer_argument(dimension_expr, "LeviCivitaTensor")
    if dimension < 0:
        raise WolframEvaluationError("LeviCivitaTensor expects a non-negative dimension.")
    dimensions = (dimension,) * dimension
    sparse_requested = isinstance(head_expr, Symbol) and _system_dispatch_name(head_expr) == "SparseArray"
    if sparse_requested:
        return _sparse_array_expr(
            dimensions if dimensions else (1,),
            (
                _SparseArrayEntry(tuple(permutation), integer(_permutation_sign(tuple(index - 1 for index in permutation))))
                for permutation in itertools.permutations(range(1, dimension + 1), dimension)
            ),
            integer(0),
        )

    def value_at(indices: tuple[int, ...]) -> Expr:
        if len(set(indices)) != len(indices):
            return integer(0)
        return integer(_permutation_sign(tuple(index - 1 for index in indices)))

    if not dimensions:
        return integer(1)
    return _build_dense_array(dimensions, value_at)


def apply_head(new_head: Expr, expr: Expr, level_spec: Expr | None = None) -> Expr:
    """Apply[f, expr] / Apply[f, expr, levelspec].

    The default form replaces the head of ``expr`` with ``new_head``. With a
    level spec, the head of every subexpression whose level matches the spec
    is replaced.
    """
    if level_spec is None:
        entries = _association_entries(expr)
        if entries is not None:
            return _apply_callable(new_head, tuple(entry.value for entry in entries))
        if not isinstance(expr, Call):
            return expr
        return _apply_callable(new_head, expr.arguments)

    level_min, level_max = _normalize_level_spec(level_spec)
    return _walk_apply_levels(new_head, expr, level_min, level_max, current_level=0)


def _walk_apply_levels(
    new_head: Expr, expr: Expr, level_min: int, level_max: int, current_level: int
) -> Expr:
    """Walk expr and replace heads at every position whose level matches."""
    entries = _association_entries(expr)
    if entries is not None:
        new_entries = [
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_walk_apply_levels(
                    new_head, entry.value, level_min, level_max, current_level + 1
                ),
            )
            for entry in entries
        ]
        rebuilt = _association_expr(new_entries)
        if _level_in_range(current_level, expr, level_min, level_max):
            return _apply_callable(new_head, tuple(entry.value for entry in new_entries))
        return rebuilt

    if isinstance(expr, Call):
        new_arguments = tuple(
            _walk_apply_levels(new_head, argument, level_min, level_max, current_level + 1)
            for argument in expr.arguments
        )
        rebuilt = _rebuild(expr, new_arguments)
        if _level_in_range(current_level, expr, level_min, level_max):
            return _apply_callable(new_head, new_arguments)
        return rebuilt

    # Atom: Apply at level 0 just returns the atom; per Wolfram semantics
    # Apply on an atom is a no-op outside the level-0 case.
    return expr


def _level_in_range(
    current_level: int, expr: Expr, level_min: int, level_max: int
) -> bool:
    """Decide whether ``current_level`` matches the requested levelspec.

    A negative ``level_min`` / ``level_max`` follows Wolfram's convention of
    counting from leaves toward the root: level ``-1`` is depth-1 (atoms),
    level ``-n`` is the level whose subtrees have depth ``n``. We compare
    using the depth of ``expr``.
    """
    negative_level = -depth(expr)
    return _level_bounds_match(current_level, negative_level, level_min, level_max)


def map_expr(
    function: Expr,
    expr: Expr,
    level_spec: Expr | None = None,
    *,
    include_heads: bool = False,
) -> Expr:
    """Map[f, expr] / Map[f, expr, levelspec] / Map[..., Heads -> True/False].

    The default form applies ``f`` to each immediate argument; with a level
    spec, ``f`` is applied to every subexpression whose level matches the
    spec, postorder. Atoms below the lowest matching level are left alone.
    With ``Heads -> True`` the head of every visited call is also wrapped.
    """
    if level_spec is None:
        entries = _association_entries(expr)
        if entries is not None:
            return _association_expr(
                _AssociationEntry(
                    rule_head=entry.rule_head,
                    key=entry.key,
                    value=_apply_callable(function, (entry.value,)),
                )
                for entry in entries
            )
        if not isinstance(expr, Call):
            return expr
        rebuilt_arguments = tuple(_apply_callable(function, (argument,)) for argument in expr.arguments)
        if include_heads:
            return Call(
                head_expr=_apply_callable(function, (expr.head_expr,)),
                arguments=rebuilt_arguments,
            )
        return _rebuild(expr, rebuilt_arguments)

    level_min, level_max = _normalize_level_spec(level_spec)
    return _walk_map_levels(
        function, expr, level_min, level_max, current_level=0, include_heads=include_heads
    )


def _walk_map_levels(
    function: Expr,
    expr: Expr,
    level_min: int,
    level_max: int,
    current_level: int,
    *,
    include_heads: bool = False,
) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        new_entries = [
            _AssociationEntry(
                rule_head=entry.rule_head,
                key=entry.key,
                value=_walk_map_levels(
                    function,
                    entry.value,
                    level_min,
                    level_max,
                    current_level + 1,
                    include_heads=include_heads,
                ),
            )
            for entry in entries
        ]
        rebuilt = _association_expr(new_entries)
        if _level_in_range(current_level, expr, level_min, level_max):
            return _apply_callable(function, (rebuilt,))
        return rebuilt

    if isinstance(expr, Call):
        new_arguments = tuple(
            _walk_map_levels(
                function,
                argument,
                level_min,
                level_max,
                current_level + 1,
                include_heads=include_heads,
            )
            for argument in expr.arguments
        )
        if include_heads:
            new_head = _walk_map_levels(
                function,
                expr.head_expr,
                level_min,
                level_max,
                current_level + 1,
                include_heads=include_heads,
            )
            rebuilt = Call(head_expr=new_head, arguments=new_arguments)
        else:
            rebuilt = _rebuild(expr, new_arguments)
        if _level_in_range(current_level, expr, level_min, level_max):
            return _apply_callable(function, (rebuilt,))
        return rebuilt

    if _level_in_range(current_level, expr, level_min, level_max):
        return _apply_callable(function, (expr,))
    return expr


def map_at(function: Expr, expr: Expr, positions: Expr | int) -> Expr:
    paths, invalid = _expand_operation_paths(expr, integer(positions) if isinstance(positions, int) else positions)
    if invalid:
        raise WolframEvaluationError(f"MapAt positions are invalid for {expr.to_input_form()}.")

    result = expr
    for path in _sort_paths(paths):
        result, changed = _try_map_at_path(result, function, path)
        if not changed:
            raise WolframEvaluationError(f"MapAt positions are invalid for {expr.to_input_form()}.")
    return result


def association(*arguments: Expr) -> Expr:
    constructed = _association_from_arguments(arguments)
    if constructed is not None:
        return constructed
    return call("Association", *arguments)


def association_q(expr: Expr) -> Symbol:
    return _bool_symbol(_is_association(expr))


def keys_expr(expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "Keys")
    return _evaluated_list_expr(*(entry.key for entry in entries))


def values_expr(expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "Values")
    return _evaluated_list_expr(*(entry.value for entry in entries))


def normal(expr: Expr) -> Expr:
    if isinstance(expr, Call) and expr.has_head("RootSum"):
        try:
            expanded_root_sum = _expression_algebraic_module()._normal_root_sum_expr(expr.arguments)
        except Exception:
            expanded_root_sum = None
        if expanded_root_sum is not None:
            return expanded_root_sum
    if isinstance(expr, SparseArrayExpr):
        return sparse_array_normal(expr)
    byte_values = _byte_array_values(expr)
    if byte_values is not None:
        return list_expr(*(integer(value) for value in byte_values))
    entries = _require_association_entries(expr, "Normal")
    return list_expr(*(entry.to_expr() for entry in entries))


def lookup(expr: Expr, key_spec: Expr, default: Expr | None = None) -> Expr:
    entries = _require_association_entries(expr, "Lookup")
    entry_map = _association_entry_map(entries)

    def lookup_one(key: Expr) -> Expr:
        entry = entry_map.get(key)
        if entry is not None:
            return entry.value
        if default is not None:
            return default
        return call("Missing", string("KeyAbsent"), key)

    if isinstance(key_spec, Call) and key_spec.has_head("List"):
        return _evaluated_list_expr(*(lookup_one(item) for item in key_spec.arguments))
    return lookup_one(key_spec)


def key_exists_q(expr: Expr, key: Expr) -> Symbol:
    entries = _require_association_entries(expr, "KeyExistsQ")
    return _bool_symbol(any(entry.key == key for entry in entries))


def key_member_q(expr: Expr, key: Expr) -> Symbol:
    return key_exists_q(expr, key)


def key_take(expr: Expr, key_spec: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyTake")
    entry_map = _association_entry_map(entries)
    selected: list[_AssociationEntry] = []
    for key in _key_spec_items(key_spec):
        entry = entry_map.get(key)
        if entry is not None:
            selected.append(entry)
    return _association_expr(selected)


def key_drop(expr: Expr, key_spec: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyDrop")
    keys_to_drop = set(_key_spec_items(key_spec))
    return _association_expr(entry for entry in entries if entry.key not in keys_to_drop)


def key_select(expr: Expr, criterion: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeySelect")
    return _association_expr(entry for entry in entries if _predicate_succeeds(criterion, entry.key))


def key_map(function: Expr, expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyMap")
    return _association_expr(
        _AssociationEntry(
            rule_head=entry.rule_head,
            key=_apply_callable(function, (entry.key,)),
            value=entry.value,
        )
        for entry in entries
    )


def key_value_map(function: Expr, expr: Expr) -> Expr:
    entries = _require_association_entries(expr, "KeyValueMap")
    return _evaluated_list_expr(*(_apply_callable(function, (entry.key, entry.value)) for entry in entries))


def association_thread(keys: Expr, values: Expr) -> Expr:
    if not isinstance(keys, Call) or not keys.has_head("List"):
        raise WolframEvaluationError("AssociationThread expects a list of keys.")
    if not isinstance(values, Call) or not values.has_head("List"):
        raise WolframEvaluationError("AssociationThread expects a list of values.")
    if len(keys.arguments) != len(values.arguments):
        raise WolframEvaluationError("AssociationThread expects key and value lists of equal length.")
    return _association_expr(
        _AssociationEntry("Rule", key, value)
        for key, value in zip(keys.arguments, values.arguments, strict=True)
    )


def association_map(function: Expr, keys: Expr) -> Expr:
    if not isinstance(keys, Call) or not keys.has_head("List"):
        raise WolframEvaluationError("AssociationMap currently supports only the key-list form.")
    return _association_expr(
        _AssociationEntry("Rule", key, _apply_callable(function, (key,)))
        for key in keys.arguments
    )


def merge_associations(associations: Expr, combiner: Expr) -> Expr:
    """Merge[{a1, a2, ...}, f] gathers values for each key into a list and
    applies ``f`` to that list, returning a new association.

    Tungsten currently expects a List of Associations as the first argument.
    Lists of rule-lists are not normalized in this pass; pass ``Association``
    explicitly when needed.
    """
    if not isinstance(associations, Call) or not associations.has_head("List"):
        raise WolframEvaluationError("Merge currently expects a list of associations.")
    grouped: dict[int, _AssociationEntry] = {}
    keys_in_order: list[Expr] = []
    grouped_values: list[list[Expr]] = []
    rule_heads: list[str] = []
    for member in associations.arguments:
        entries = _association_entries(member)
        if entries is None:
            raise WolframEvaluationError(
                "Merge currently expects every list element to be an Association."
            )
        for entry in entries:
            existing_index: int | None = None
            for index, existing_key in enumerate(keys_in_order):
                if existing_key == entry.key:
                    existing_index = index
                    break
            if existing_index is None:
                keys_in_order.append(entry.key)
                grouped_values.append([entry.value])
                rule_heads.append(entry.rule_head)
            else:
                grouped_values[existing_index].append(entry.value)
    new_entries = [
        _AssociationEntry(
            rule_head=rule_heads[index],
            key=keys_in_order[index],
            value=evaluate(_apply_callable(combiner, (list_expr(*values),))),
        )
        for index, values in enumerate(grouped_values)
    ]
    return _association_expr(new_entries)


def group_by(data: Expr, spec: Expr) -> Expr:
    """GroupBy[list, f] / GroupBy[list, f -> g].

    The arrow-form spec ``f -> g`` first groups by ``f`` and then applies
    ``g`` to each group's value list before storing it.
    """
    items = _list_or_association_values(data, "GroupBy")

    if isinstance(spec, Call) and spec.has_head("Rule") and len(spec.arguments) == 2:
        key_function, value_function = spec.arguments
    else:
        key_function = spec
        value_function = None

    keys_in_order: list[Expr] = []
    grouped_values: list[list[Expr]] = []
    for item in items:
        key = evaluate(_apply_callable(key_function, (item,)))
        existing_index: int | None = None
        for index, existing_key in enumerate(keys_in_order):
            if existing_key == key:
                existing_index = index
                break
        if existing_index is None:
            keys_in_order.append(key)
            grouped_values.append([item])
        else:
            grouped_values[existing_index].append(item)

    entries: list[_AssociationEntry] = []
    for key, values in zip(keys_in_order, grouped_values):
        if value_function is None:
            payload = list_expr(*values)
        else:
            payload = evaluate(_apply_callable(value_function, (list_expr(*values),)))
        entries.append(_AssociationEntry(rule_head="Rule", key=key, value=payload))
    return _association_expr(entries)


def gather_by(data: Expr, key_function: Expr) -> Expr:
    """GatherBy[list, f] groups consecutive runs of equal keys, but in the
    Wolfram contract elements are gathered globally regardless of position.
    Returns a list of lists in first-occurrence order.
    """
    items = _list_or_association_values(data, "GatherBy")
    keys_in_order: list[Expr] = []
    grouped_values: list[list[Expr]] = []
    for item in items:
        key = evaluate(_apply_callable(key_function, (item,)))
        existing_index: int | None = None
        for index, existing_key in enumerate(keys_in_order):
            if existing_key == key:
                existing_index = index
                break
        if existing_index is None:
            keys_in_order.append(key)
            grouped_values.append([item])
        else:
            grouped_values[existing_index].append(item)
    return list_expr(*(list_expr(*group) for group in grouped_values))


def gather(data: Expr) -> Expr:
    """Gather[list]: groups equal elements (using structural identity)."""
    items = _list_or_association_values(data, "Gather")
    keys_in_order: list[Expr] = []
    grouped_values: list[list[Expr]] = []
    for item in items:
        existing_index: int | None = None
        for index, existing_key in enumerate(keys_in_order):
            if existing_key == item:
                existing_index = index
                break
        if existing_index is None:
            keys_in_order.append(item)
            grouped_values.append([item])
        else:
            grouped_values[existing_index].append(item)
    return list_expr(*(list_expr(*group) for group in grouped_values))


def _associations_only(values: Sequence[Expr], function_name: str) -> list[tuple[_AssociationEntry, ...]]:
    result: list[tuple[_AssociationEntry, ...]] = []
    for member in values:
        entries = _association_entries(member)
        if entries is None:
            raise WolframEvaluationError(
                f"{function_name} currently expects every entry to be an Association."
            )
        result.append(entries)
    return result


def key_complement(associations: Expr) -> Expr:
    """KeyComplement[{a1, a2, ...}] returns entries of ``a1`` whose keys
    don't appear in any later association, preserving ``a1``'s entry order.
    """
    if not isinstance(associations, Call) or not associations.has_head("List") or not associations.arguments:
        raise WolframEvaluationError("KeyComplement expects a non-empty list of associations.")
    members = _associations_only(associations.arguments, "KeyComplement")
    later_keys: list[Expr] = []
    for member in members[1:]:
        for entry in member:
            if not any(entry.key == existing for existing in later_keys):
                later_keys.append(entry.key)
    return _association_expr(
        entry for entry in members[0] if not any(entry.key == existing for existing in later_keys)
    )


def key_union(associations: Expr) -> Expr:
    """KeyUnion[{a1, a2, ...}] returns a list of associations all sharing the
    union of keys. Missing keys are filled with ``Missing["KeyAbsent", k]``.
    """
    if not isinstance(associations, Call) or not associations.has_head("List") or not associations.arguments:
        raise WolframEvaluationError("KeyUnion expects a non-empty list of associations.")
    members = _associations_only(associations.arguments, "KeyUnion")
    all_keys: list[Expr] = []
    for member in members:
        for entry in member:
            if not any(entry.key == existing for existing in all_keys):
                all_keys.append(entry.key)

    output: list[Expr] = []
    for member in members:
        entry_map = {id(entry.key): entry for entry in member}
        # Use structural equality lookup; cannot rely on dict by Expr identity.
        new_entries: list[_AssociationEntry] = []
        for key in all_keys:
            found: _AssociationEntry | None = None
            for entry in member:
                if entry.key == key:
                    found = entry
                    break
            if found is not None:
                new_entries.append(found)
            else:
                new_entries.append(
                    _AssociationEntry(
                        rule_head="Rule",
                        key=key,
                        value=call("Missing", string("KeyAbsent"), key),
                    )
                )
        output.append(_association_expr(new_entries))
    return list_expr(*output)


def key_intersection(associations: Expr) -> Expr:
    """KeyIntersection[{a1, a2, ...}] returns a list of associations all
    sharing the keys present in every input, with each association keeping
    its own value for those keys.
    """
    if not isinstance(associations, Call) or not associations.has_head("List") or not associations.arguments:
        raise WolframEvaluationError("KeyIntersection expects a non-empty list of associations.")
    members = _associations_only(associations.arguments, "KeyIntersection")
    common_keys: list[Expr] = []
    for entry in members[0]:
        if all(any(entry.key == other_entry.key for other_entry in member) for member in members[1:]):
            if not any(entry.key == existing for existing in common_keys):
                common_keys.append(entry.key)

    output: list[Expr] = []
    for member in members:
        new_entries: list[_AssociationEntry] = []
        for key in common_keys:
            for entry in member:
                if entry.key == key:
                    new_entries.append(entry)
                    break
        output.append(_association_expr(new_entries))
    return list_expr(*output)


def _require_compound(expr: Expr, function_name: str) -> Call:
    if isinstance(expr, Call):
        return expr
    raise WolframEvaluationError(f"{function_name} expects a nonatomic expression.")


def _list_or_association_values(expr: Expr, function_name: str) -> tuple[Expr, ...]:
    """Return a tuple of element values for a List or an Association.

    For ``List[...]`` returns its arguments verbatim. For ``Association[...]``
    returns the values of each entry (matching Wolfram's values-only
    behavior on associations for ``Total``, ``Sort``, etc.). Other shapes
    raise a Tungsten evaluation error.
    """
    entries = _association_entries(expr)
    if entries is not None:
        return tuple(entry.value for entry in entries)
    if isinstance(expr, Call) and expr.has_head("List"):
        return tuple(expr.arguments)
    raise WolframEvaluationError(f"{function_name} expects a list or association.")


def mean_expr(expr: Expr) -> Expr:
    items = _list_or_association_values(expr, "Mean")
    if not items:
        raise WolframEvaluationError("Mean of an empty list is undefined.")
    n = integer(len(items))
    summed = evaluate(call("Plus", *items))
    return evaluate(call("Times", summed, call("Power", n, integer(-1))))


def variance_expr(expr: Expr) -> Expr:
    """Variance[list] = sum((x - mean)^2) / (n - 1) for sample variance."""
    items = _list_or_association_values(expr, "Variance")
    if len(items) < 2:
        raise WolframEvaluationError("Variance requires at least two elements.")
    mean = mean_expr(expr)
    deviations = [
        evaluate(call("Plus", item, call("Times", integer(-1), mean))) for item in items
    ]
    squared = [evaluate(call("Power", deviation, integer(2))) for deviation in deviations]
    summed = evaluate(call("Plus", *squared))
    return evaluate(call("Times", summed, call("Power", integer(len(items) - 1), integer(-1))))


def standard_deviation_expr(expr: Expr) -> Expr:
    return evaluate(call("Sqrt", variance_expr(expr)))


def norm_expr(expr: Expr, p_expr: Expr | None = None) -> Expr:
    """Norm[v] for an explicit numeric vector; Norm[v, p] for the p-norm."""
    compound = _require_compound(expr, "Norm")
    if not compound.has_head("List"):
        raise WolframEvaluationError("Norm currently expects a List of explicit numbers.")

    def absolute_value(item: Expr) -> Expr:
        return evaluate(call("Abs", item))

    if p_expr is None:
        # Default Euclidean norm.
        squares = [
            evaluate(call("Power", absolute_value(item), integer(2)))
            for item in compound.arguments
        ]
        return evaluate(call("Sqrt", call("Plus", *squares)))

    if isinstance(p_expr, Symbol) and p_expr.name == "Infinity":
        # L-infinity = Max[Abs[v]].
        if not compound.arguments:
            return integer(0)
        return evaluate(call("Max", *(absolute_value(item) for item in compound.arguments)))

    if isinstance(p_expr, Integer) and p_expr.value > 0:
        powered = [
            evaluate(call("Power", absolute_value(item), p_expr))
            for item in compound.arguments
        ]
        return evaluate(
            call("Power", call("Plus", *powered), call("Power", p_expr, integer(-1)))
        )

    raise WolframEvaluationError(
        "Norm currently expects a positive integer p or Infinity."
    )


def median_expr(expr: Expr) -> Expr:
    items = _list_or_association_values(expr, "Median")
    if not items:
        raise WolframEvaluationError("Median of an empty list is undefined.")
    if not all(_is_real_number_expr(item) for item in items):
        raise WolframEvaluationError("Median currently expects explicit real-valued numbers.")
    sorted_items = sorted(items, key=lambda item: float(_exact_fraction(item)) if _is_exact_real_number(item)
                          else float(_real_info(item).value))  # type: ignore[union-attr]
    n = len(sorted_items)
    if n % 2 == 1:
        return sorted_items[n // 2]
    left = sorted_items[n // 2 - 1]
    right = sorted_items[n // 2]
    summed = evaluate(call("Plus", left, right))
    return evaluate(call("Times", summed, rational_number(1, 2)))


def _sort_real_values_ascending(items: Sequence[Expr], function_name: str) -> list[Expr]:
    """Sort an iterable of explicit real-valued numbers ascending.

    Mirrors the ad-hoc comparator ``median_expr`` uses; the helper exists
    so the family of statistics heads (``MinMax``, ``RankedMin`` /
    ``RankedMax``, ``Quantile``, ``Quartiles``, ``BinCounts`` /
    ``BinLists``) can share a single rejection path for non-numeric
    inputs.
    """
    if not all(_is_real_number_expr(item) for item in items):
        raise WolframEvaluationError(
            f"{function_name} currently expects explicit real-valued numbers."
        )
    return sorted(
        items,
        key=lambda item: (
            float(_exact_fraction(item))  # type: ignore[arg-type]
            if _is_exact_real_number(item)
            else float(_real_info(item).value)  # type: ignore[union-attr]
        ),
    )


def min_max_expr(expr: Expr) -> Expr:
    """``MinMax[list]`` returns ``{Min[list], Max[list]}`` in one pass.

    The empty list yields ``{Infinity, -Infinity}`` per the kernel
    (i.e., the identities of ``Min`` and ``Max``), so that
    ``MinMax[{}]`` is the unit element of ``Min``/``Max`` over all
    real numbers.
    """
    items = _list_or_association_values(expr, "MinMax")
    if not items:
        return list_expr(symbol("Infinity"), call("Times", integer(-1), symbol("Infinity")))
    return _evaluated_list_expr(
        evaluate(call("Min", *items)),
        evaluate(call("Max", *items)),
    )


def _ranked_pick(items: Sequence[Expr], k_expr: Expr, function_name: str, *, descending: bool) -> Expr:
    """Return the ``k``-th smallest (``descending=False``) or largest
    (``descending=True``) element of ``items``.

    Tungsten preserves duplicates the way the kernel does: ``RankedMin``
    is the inverse-CDF-style "pick from sorted list at index k" rather
    than "k-th distinct value." Indices are 1-based; negative indices
    count from the opposite end, matching the kernel.
    """
    if not isinstance(k_expr, Integer):
        raise WolframEvaluationError(
            f"{function_name} expects an explicit integer rank."
        )
    if not items:
        raise WolframEvaluationError(f"{function_name} requires a nonempty list.")
    sorted_items = _sort_real_values_ascending(items, function_name)
    if descending:
        sorted_items = list(reversed(sorted_items))
    n = len(sorted_items)
    rank = k_expr.value
    if rank == 0 or rank > n or rank < -n:
        raise WolframEvaluationError(
            f"{function_name} rank {rank} is out of range for a list of length {n}."
        )
    if rank > 0:
        return sorted_items[rank - 1]
    return sorted_items[n + rank]


def ranked_min_expr(expr: Expr, k_expr: Expr) -> Expr:
    """``RankedMin[list, k]`` — the ``k``-th smallest element."""
    items = _list_or_association_values(expr, "RankedMin")
    return _ranked_pick(items, k_expr, "RankedMin", descending=False)


def ranked_max_expr(expr: Expr, k_expr: Expr) -> Expr:
    """``RankedMax[list, k]`` — the ``k``-th largest element."""
    items = _list_or_association_values(expr, "RankedMax")
    return _ranked_pick(items, k_expr, "RankedMax", descending=True)


def mode_expr(expr: Expr) -> Expr:
    """``Mode[list]`` — the most common element.

    Matches the kernel's tie-breaking: when several elements share the
    maximum count, return the canonical-order minimum among them. For
    an empty list, return the inert ``Mode[{}]`` form (matching the
    kernel's response).
    """
    items = _list_or_association_values(expr, "Mode")
    if not items:
        return call("Mode", expr)
    counts_dict: dict[int, int] = {}
    keys: list[Expr] = []
    for item in items:
        for index, existing in enumerate(keys):
            if existing == item:
                counts_dict[index] += 1
                break
        else:
            counts_dict[len(keys)] = 1
            keys.append(item)
    max_count = max(counts_dict.values())
    candidates = [keys[index] for index, count in counts_dict.items() if count == max_count]
    sorted_candidates = sort_expr(list_expr(*candidates))
    assert isinstance(sorted_candidates, Call) and sorted_candidates.has_head("List")
    return sorted_candidates.arguments[0]


def _default_quantile_parameters() -> tuple[Expr, Expr, Expr, Expr]:
    """Return ``{{0, 0}, {1, 0}}`` parameters used by ``Quantile`` by
    default — Wolfram's documented type-1 inverse-CDF form.
    """
    return integer(0), integer(0), integer(1), integer(0)


def _quartiles_parameters() -> tuple[Expr, Expr, Expr, Expr]:
    """Return ``{{1/2, 0}, {0, 1}}`` (the kernel's Quartiles default,
    type 7 in the Hyndman-Fan classification).
    """
    return rational_number(1, 2), integer(0), integer(0), integer(1)


def _parse_quantile_parameters(spec: Expr) -> tuple[Expr, Expr, Expr, Expr]:
    """Validate and return ``(a, b, c, d)`` from a ``{{a, b}, {c, d}}``
    nested-list specification.
    """
    if not (isinstance(spec, Call) and spec.has_head("List") and len(spec.arguments) == 2):
        raise WolframEvaluationError(
            "Quantile parameters must be a list ``{{a, b}, {c, d}}``."
        )
    first, second = spec.arguments
    if not (isinstance(first, Call) and first.has_head("List") and len(first.arguments) == 2):
        raise WolframEvaluationError(
            "Quantile parameters must be a list ``{{a, b}, {c, d}}``."
        )
    if not (isinstance(second, Call) and second.has_head("List") and len(second.arguments) == 2):
        raise WolframEvaluationError(
            "Quantile parameters must be a list ``{{a, b}, {c, d}}``."
        )
    a, b = first.arguments
    c, d = second.arguments
    return a, b, c, d


def _quantile_one(
    sorted_items: Sequence[Expr],
    q_expr: Expr,
    parameters: tuple[Expr, Expr, Expr, Expr],
) -> Expr:
    """Compute one quantile against an already-sorted list of explicit
    real-valued numbers.

    Implements the Hyndman-Fan parameterization (Wolfram's
    ``Quantile[list, q, {{a, b}, {c, d}}]``):
    ``p = a + (n + b)*q``; ``i = Floor[p]``; ``f = p - i``. When ``f``
    is exactly zero the result is ``s[[i]]`` with no interpolation;
    otherwise it is ``s[[i]] + (c + d*f) * (s[[i+1]] - s[[i]])``.
    Out-of-range ``i`` clamp to the first or last element. Inputs are
    kept as exact ``Integer`` / ``Rational`` when possible so the
    canonical-rational kernel default ``{{0, 0}, {1, 0}}`` produces
    integer results for integer inputs.
    """
    a, b, c, d = parameters
    n = len(sorted_items)
    n_expr = integer(n)
    p_expr = evaluate(call("Plus", a, call("Times", call("Plus", n_expr, b), q_expr)))
    i_expr = evaluate(call("Floor", p_expr))
    f_expr = evaluate(call("Plus", p_expr, call("Times", integer(-1), i_expr)))
    if not (isinstance(i_expr, Integer) and _is_real_number_expr(f_expr)):
        raise WolframEvaluationError(
            "Quantile could not reduce its position calculation to an explicit number."
        )
    i = i_expr.value
    if i < 1:
        return sorted_items[0]
    if i >= n:
        return sorted_items[-1]
    base = sorted_items[i - 1]
    next_value = sorted_items[i]
    sign = _compare_real_expr(f_expr, integer(0))
    if sign is not None and sign == 0:
        return base
    weight = evaluate(call("Plus", c, call("Times", d, f_expr)))
    return evaluate(
        call(
            "Plus",
            base,
            call("Times", weight, call("Plus", next_value, call("Times", integer(-1), base))),
        )
    )


def quantile_expr(expr: Expr, q_expr: Expr, parameters_expr: Expr | None = None) -> Expr:
    """``Quantile[list, q]`` / ``Quantile[list, {q1, …}]`` /
    ``Quantile[list, q, {{a, b}, {c, d}}]``.

    The default parameters are ``{{0, 0}, {1, 0}}`` (type 1, inverse
    CDF). Lists of quantile probabilities thread the computation
    elementwise. Inputs must be explicit real-valued numbers.
    """
    items = _list_or_association_values(expr, "Quantile")
    if not items:
        raise WolframEvaluationError("Quantile of an empty list is undefined.")
    sorted_items = _sort_real_values_ascending(items, "Quantile")
    parameters = (
        _parse_quantile_parameters(parameters_expr)
        if parameters_expr is not None
        else _default_quantile_parameters()
    )
    if isinstance(q_expr, Call) and q_expr.has_head("List"):
        return _evaluated_list_expr(
            *(_quantile_one(sorted_items, q, parameters) for q in q_expr.arguments)
        )
    return _quantile_one(sorted_items, q_expr, parameters)


def quartiles_expr(expr: Expr) -> Expr:
    """``Quartiles[list]`` returns ``{Q1, Median, Q3}`` using
    ``{{1/2, 0}, {0, 1}}`` (type 7) — Wolfram's documented
    ``Quartiles`` parameterization, distinct from the default
    ``Quantile`` parameterization.
    """
    items = _list_or_association_values(expr, "Quartiles")
    if not items:
        raise WolframEvaluationError("Quartiles of an empty list is undefined.")
    sorted_items = _sort_real_values_ascending(items, "Quartiles")
    parameters = _quartiles_parameters()
    return _evaluated_list_expr(
        _quantile_one(sorted_items, rational_number(1, 4), parameters),
        _quantile_one(sorted_items, rational_number(1, 2), parameters),
        _quantile_one(sorted_items, rational_number(3, 4), parameters),
    )


def _bin_spec_bounds(
    items: Sequence[Expr],
    spec: Expr,
    function_name: str,
) -> tuple[Expr, Expr, Expr]:
    """Resolve a bin specification to an ``(xmin, xmax, dx)`` triple of
    explicit real numbers.

    The kernel accepts a bare ``dx`` (use the data's min / max snapped
    to an aligned bin) or an explicit ``{xmin, xmax, dx}`` list. The
    aligned-bin form for the bare ``dx`` snaps ``xmin`` to
    ``Floor[Min[items]/dx]*dx`` and ``xmax`` to
    ``Ceiling[Max[items]/dx]*dx``, which matches
    ``BinCounts[Range[10], 2]`` → ``{1, 2, 2, 2, 2, 1}``.
    """
    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) != 3:
            raise WolframEvaluationError(
                f"{function_name} expects a bin spec ``dx`` or ``{{xmin, xmax, dx}}``."
            )
        xmin_expr, xmax_expr, dx_expr = spec.arguments
        for value, role in (
            (xmin_expr, "xmin"),
            (xmax_expr, "xmax"),
            (dx_expr, "dx"),
        ):
            if not _is_real_number_expr(value):
                raise WolframEvaluationError(
                    f"{function_name} {role} must be an explicit real-valued number."
                )
        return xmin_expr, xmax_expr, dx_expr

    if not _is_real_number_expr(spec):
        raise WolframEvaluationError(
            f"{function_name} expects a bin spec ``dx`` or ``{{xmin, xmax, dx}}``."
        )
    if not items:
        raise WolframEvaluationError(
            f"{function_name} cannot infer auto bin bounds from an empty list."
        )
    if not all(_is_real_number_expr(item) for item in items):
        raise WolframEvaluationError(
            f"{function_name} currently expects explicit real-valued numbers."
        )
    min_value = evaluate(call("Min", *items))
    max_value = evaluate(call("Max", *items))
    xmin = evaluate(call("Times", call("Floor", call("Times", min_value, call("Power", spec, integer(-1)))), spec))
    # Auto-binning extends one bin past the data so the maximum data
    # point lands in a half-open bin ``[k*dx, (k+1)*dx)`` rather than
    # being dropped at the right edge. This matches the kernel:
    # ``BinCounts[Range[10], 2]`` -> ``{1, 2, 2, 2, 2, 1}`` (six bins).
    xmax = evaluate(
        call(
            "Times",
            call(
                "Plus",
                call("Floor", call("Times", max_value, call("Power", spec, integer(-1)))),
                integer(1),
            ),
            spec,
        )
    )
    return xmin, xmax, spec


def _bin_index(item: Expr, xmin: Expr, dx: Expr) -> int | None:
    """Return the zero-based bin index for ``item`` given lower bound
    ``xmin`` and bin width ``dx``, or ``None`` if it falls below the
    range.
    """
    diff = evaluate(call("Plus", item, call("Times", integer(-1), xmin)))
    sign = _compare_real_expr(diff, integer(0))
    if sign is None or sign < 0:
        return None
    quotient = evaluate(call("Times", diff, call("Power", dx, integer(-1))))
    floored = evaluate(call("Floor", quotient))
    if isinstance(floored, Integer):
        return floored.value
    raise WolframEvaluationError("BinCounts could not reduce a position to an explicit integer.")


def _bin_count(xmin: Expr, xmax: Expr, dx: Expr, function_name: str) -> int:
    span = evaluate(call("Plus", xmax, call("Times", integer(-1), xmin)))
    quotient = evaluate(call("Times", span, call("Power", dx, integer(-1))))
    floored = evaluate(call("Floor", quotient))
    if not isinstance(floored, Integer):
        raise WolframEvaluationError(
            f"{function_name} could not determine an integer bin count from the spec."
        )
    if floored.value <= 0:
        raise WolframEvaluationError(
            f"{function_name} requires xmax > xmin and a positive bin width."
        )
    return floored.value


def bin_counts_expr(expr: Expr, spec: Expr | None = None) -> Expr:
    """``BinCounts[list]`` / ``BinCounts[list, dx]`` /
    ``BinCounts[list, {xmin, xmax, dx}]``.

    Each bin covers ``[lo, hi)`` so the right edge of the last bin is
    *not* counted (matching the kernel). The auto-binning ``BinCounts[
    list, dx]`` form snaps ``xmin``/``xmax`` to multiples of ``dx``
    using ``Floor`` / ``Ceiling`` — also matching the kernel's
    documented contract.
    """
    items = _list_or_association_values(expr, "BinCounts")
    if spec is None:
        spec = integer(1)
    xmin, xmax, dx = _bin_spec_bounds(items, spec, "BinCounts")
    bin_count = _bin_count(xmin, xmax, dx, "BinCounts")
    counts = [0] * bin_count
    for item in items:
        if not _is_real_number_expr(item):
            raise WolframEvaluationError(
                "BinCounts currently expects explicit real-valued numbers."
            )
        index = _bin_index(item, xmin, dx)
        if index is None or index >= bin_count:
            continue
        counts[index] += 1
    return _evaluated_list_expr(*(integer(c) for c in counts))


def bin_lists_expr(expr: Expr, spec: Expr | None = None) -> Expr:
    """``BinLists[list]`` / ``BinLists[list, dx]`` /
    ``BinLists[list, {xmin, xmax, dx}]``.

    Same bin partition as ``BinCounts`` but returns the actual binned
    elements rather than per-bin counts. Items below ``xmin`` and at
    or above ``xmax`` are dropped; per-bin element order matches the
    input list order.
    """
    items = _list_or_association_values(expr, "BinLists")
    if spec is None:
        spec = integer(1)
    xmin, xmax, dx = _bin_spec_bounds(items, spec, "BinLists")
    bin_count = _bin_count(xmin, xmax, dx, "BinLists")
    bins: list[list[Expr]] = [[] for _ in range(bin_count)]
    for item in items:
        if not _is_real_number_expr(item):
            raise WolframEvaluationError(
                "BinLists currently expects explicit real-valued numbers."
            )
        index = _bin_index(item, xmin, dx)
        if index is None or index >= bin_count:
            continue
        bins[index].append(item)
    return list_expr(*(list_expr(*b) for b in bins))


def _parse_cycles_argument(expr: Expr, function_name: str) -> list[list[int]]:
    """Validate a ``Cycles[{{...}, …}]`` argument and return the cycles
    as a list of integer lists.
    """
    if not (isinstance(expr, Call) and expr.has_head("Cycles")):
        raise WolframEvaluationError(
            f"{function_name} expects a ``Cycles[{{...}}]`` argument."
        )
    if len(expr.arguments) != 1:
        raise WolframEvaluationError(
            f"{function_name} expects ``Cycles`` with exactly one cycle-list argument."
        )
    cycles_arg = expr.arguments[0]
    if not (isinstance(cycles_arg, Call) and cycles_arg.has_head("List")):
        raise WolframEvaluationError(
            f"{function_name} expects ``Cycles[{{cycle1, cycle2, …}}]``."
        )
    cycles: list[list[int]] = []
    seen: set[int] = set()
    for cycle in cycles_arg.arguments:
        if not (isinstance(cycle, Call) and cycle.has_head("List")):
            raise WolframEvaluationError(
                f"{function_name}: every cycle must be a List of positive integers."
            )
        if not cycle.arguments:
            continue
        positions: list[int] = []
        for index_expr in cycle.arguments:
            if not (isinstance(index_expr, Integer) and index_expr.value > 0):
                raise WolframEvaluationError(
                    f"{function_name}: cycle entries must be positive integers."
                )
            if index_expr.value in seen:
                raise WolframEvaluationError(
                    f"{function_name}: cycle entries must be disjoint."
                )
            seen.add(index_expr.value)
            positions.append(index_expr.value)
        cycles.append(positions)
    return cycles


def _cycles_to_permutation_list(cycles: Sequence[Sequence[int]], length: int) -> list[int]:
    """Convert a disjoint-cycle decomposition to a 1-based permutation
    list of length ``length``.

    Each entry of the returned list answers "where does position i go
    under the permutation?" — ``permutation_list[i-1]`` is the image
    of position ``i``.
    """
    permutation = list(range(1, length + 1))
    for cycle in cycles:
        if len(cycle) < 2:
            continue
        # Cycle (a b c) means a -> b, b -> c, c -> a.
        for i, src in enumerate(cycle):
            destination = cycle[(i + 1) % len(cycle)]
            if src - 1 >= length:
                raise WolframEvaluationError(
                    "Cycles refer to a position beyond the requested permutation length."
                )
            permutation[src - 1] = destination
    return permutation


def _permutation_list_to_cycles(permutation: Sequence[int]) -> list[list[int]]:
    """Convert a 1-based permutation list to its disjoint-cycle
    decomposition, dropping fixed points (single-element cycles), and
    rotating each cycle to start at its minimum element so the result
    is canonical.
    """
    n = len(permutation)
    visited = [False] * n
    cycles: list[list[int]] = []
    for start in range(1, n + 1):
        if visited[start - 1]:
            continue
        cycle: list[int] = []
        current = start
        while not visited[current - 1]:
            visited[current - 1] = True
            cycle.append(current)
            current = permutation[current - 1]
        if len(cycle) > 1:
            # Canonicalize: rotate so the cycle starts at its minimum.
            min_index = cycle.index(min(cycle))
            cycle = cycle[min_index:] + cycle[:min_index]
            cycles.append(cycle)
    return cycles


def permutation_list_expr(perm_expr: Expr, length_expr: Expr | None = None) -> Expr:
    """``PermutationList[Cycles[{{…}}]]`` /
    ``PermutationList[Cycles[{{…}}], n]``.

    Convert disjoint cycles into the equivalent positional list. The
    optional ``n`` extends the result with fixed points up to length
    ``n``; without it, the list runs through the largest cycle entry.
    """
    cycles = _parse_cycles_argument(perm_expr, "PermutationList")
    inferred_length = max((max(cycle) for cycle in cycles if cycle), default=0)
    if length_expr is None:
        target_length = inferred_length
    elif isinstance(length_expr, Integer) and length_expr.value >= 0:
        target_length = length_expr.value
    else:
        raise WolframEvaluationError(
            "PermutationList expects a non-negative integer length."
        )
    if inferred_length > target_length:
        raise WolframEvaluationError(
            "PermutationList length is shorter than the largest cycle entry."
        )
    permutation = _cycles_to_permutation_list(cycles, target_length)
    return _evaluated_list_expr(*(integer(value) for value in permutation))


def permutation_cycles_expr(list_expr_input: Expr) -> Expr:
    """``PermutationCycles[{p1, p2, …}]``.

    Convert a 1-based permutation list to its canonical disjoint-cycle
    representation as ``Cycles[{{…}, …}]``. The input must be a
    permutation of ``Range[Length[input]]`` — otherwise the call falls
    through to its inert form.
    """
    if not (isinstance(list_expr_input, Call) and list_expr_input.has_head("List")):
        raise WolframEvaluationError(
            "PermutationCycles expects a List of positive integers."
        )
    n = len(list_expr_input.arguments)
    permutation: list[int] = []
    for argument in list_expr_input.arguments:
        if not isinstance(argument, Integer) or argument.value < 1 or argument.value > n:
            raise WolframEvaluationError(
                "PermutationCycles expects a permutation of {1, …, n}."
            )
        permutation.append(argument.value)
    if len(set(permutation)) != n:
        raise WolframEvaluationError(
            "PermutationCycles expects a permutation of {1, …, n}."
        )
    cycles = _permutation_list_to_cycles(permutation)
    return call(
        "Cycles",
        list_expr(*(list_expr(*(integer(p) for p in cycle)) for cycle in cycles)),
    )


def permutation_order_expr(perm_expr: Expr) -> Expr:
    """``PermutationOrder[Cycles[{{…}}]]`` — the LCM of the cycle
    lengths, i.e. the smallest ``k`` for which ``perm^k`` is the
    identity. Trivial cycles (length 1) are dropped before computing
    the LCM.
    """
    cycles = _parse_cycles_argument(perm_expr, "PermutationOrder")
    lengths = [len(cycle) for cycle in cycles if len(cycle) > 1]
    if not lengths:
        return integer(1)
    from math import lcm

    result = lengths[0]
    for length in lengths[1:]:
        result = lcm(result, length)
    return integer(result)


def permute_expr(list_expr_input: Expr, perm_expr: Expr) -> Expr:
    """``Permute[expr, perm]`` / ``Permute[expr, Cycles[{{…}}]]``.

    Apply a permutation to the first-level elements of a non-association
    compound expression. The kernel's contract is that
    ``Permute[expr, perm][[perm[[i]]]] == expr[[i]]``, i.e. the
    element at original position ``i`` ends up at the position named
    by ``perm[[i]]``.
    """
    if _association_entries(list_expr_input) is not None:
        raise WolframEvaluationError("Permute expects a non-association expression.")
    if not isinstance(list_expr_input, Call):
        raise WolframEvaluationError("Permute expects a compound expression.")
    n = len(list_expr_input.arguments)
    if isinstance(perm_expr, Call) and perm_expr.has_head("Cycles"):
        cycles = _parse_cycles_argument(perm_expr, "Permute")
        max_index = max((max(cycle) for cycle in cycles if cycle), default=0)
        if max_index > n:
            raise WolframEvaluationError(
                "Permute: cycle indexes a position beyond the list length."
            )
        permutation = _cycles_to_permutation_list(cycles, n)
    elif isinstance(perm_expr, Call) and perm_expr.has_head("List"):
        if len(perm_expr.arguments) != n:
            raise WolframEvaluationError(
                "Permute: positional permutation length must equal the list length."
            )
        permutation = []
        for argument in perm_expr.arguments:
            if not isinstance(argument, Integer) or argument.value < 1 or argument.value > n:
                raise WolframEvaluationError(
                    "Permute: positional permutation must be a permutation of {1, …, n}."
                )
            permutation.append(argument.value)
        if len(set(permutation)) != n:
            raise WolframEvaluationError(
                "Permute: positional permutation must be a permutation of {1, …, n}."
            )
    else:
        raise WolframEvaluationError(
            "Permute expects a permutation as a positional list or ``Cycles[{{…}}]``."
        )
    output: list[Expr | None] = [None] * n
    for source_index in range(n):
        destination = permutation[source_index] - 1
        output[destination] = list_expr_input.arguments[source_index]
    # All destinations should be filled because the permutation is bijective.
    assert all(item is not None for item in output)
    return _rebuild(list_expr_input, output)  # type: ignore[arg-type]


def _peek_sequence_list_pattern(pattern: Expr) -> Call | None:
    """Return the inner ``List[…]`` pattern of a sequence-search
    pattern, peeking through ``Condition`` and ``HoldPattern`` wrappers.

    Returns ``None`` when the pattern's structural shape isn't a fixed
    ``List`` — Tungsten currently only supports fixed-arity sequence
    patterns; variable-length sequences (``{a_, b__, c_}``) would
    require enumerating slice widths and are out of scope here.
    """
    current = pattern
    while isinstance(current, Call) and current.head_expr is not None:
        if isinstance(current.head_expr, Symbol) and current.head_expr.name in {"Condition", "HoldPattern"} and current.arguments:
            current = current.arguments[0]
            continue
        break
    if isinstance(current, Call) and current.has_head("List"):
        return current
    return None


def _sequence_pattern_match_first(items: Sequence[Expr], pattern: Expr, start_index: int) -> int | None:
    """Return the inclusive end index of the first match of ``pattern``
    against a contiguous slice of ``items`` starting at ``start_index``,
    or ``None`` if no match is found at that position.

    The supported pattern shape is a fixed-arity ``List[…]``, optionally
    wrapped in ``Condition`` or ``HoldPattern``. Tungsten's ordinary
    pattern matcher does the actual matching, so guards via
    ``Condition`` reduce through the same evaluator path used by
    ``Cases`` / ``MatchQ``.
    """
    inner_list = _peek_sequence_list_pattern(pattern)
    if inner_list is None:
        raise WolframEvaluationError(
            "SequenceCases / SequencePosition / SequenceCount expect a fixed-arity "
            "List pattern, optionally wrapped in Condition or HoldPattern."
        )
    pattern_arity = len(inner_list.arguments)
    end = start_index + pattern_arity
    if end > len(items):
        return None
    slice_call = list_expr(*items[start_index:end])
    if _match_pattern(slice_call, pattern) is None:
        return None
    return end


def _sequence_match_spans(items: Sequence[Expr], pattern: Expr) -> list[tuple[int, int]]:
    """Return ``[(start, end_inclusive), …]`` 1-based spans of every
    non-overlapping match of ``pattern`` against contiguous slices of
    ``items``.
    """
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(items):
        end = _sequence_pattern_match_first(items, pattern, index)
        if end is None:
            index += 1
            continue
        spans.append((index + 1, end))
        index = end
    return spans


def sequence_cases_expr(list_expr_input: Expr, pattern: Expr) -> Expr:
    """``SequenceCases[list, patt]`` — collect every matching contiguous
    sublist of ``list`` against the ``List`` pattern (with optional
    ``Condition`` guard at the top level).
    """
    if not (isinstance(list_expr_input, Call) and list_expr_input.has_head("List")):
        raise WolframEvaluationError("SequenceCases expects a List as its first argument.")
    items = list_expr_input.arguments
    spans = _sequence_match_spans(items, pattern)
    return list_expr(
        *(list_expr(*items[start - 1:end]) for start, end in spans)
    )


def sequence_position_expr(list_expr_input: Expr, pattern: Expr) -> Expr:
    """``SequencePosition[list, patt]`` — return ``{start, end}`` 1-based
    inclusive spans of every non-overlapping match.
    """
    if not (isinstance(list_expr_input, Call) and list_expr_input.has_head("List")):
        raise WolframEvaluationError("SequencePosition expects a List as its first argument.")
    spans = _sequence_match_spans(list_expr_input.arguments, pattern)
    return list_expr(*(list_expr(integer(start), integer(end)) for start, end in spans))


def sequence_count_expr(list_expr_input: Expr, pattern: Expr) -> Expr:
    """``SequenceCount[list, patt]`` — count of non-overlapping matches."""
    if not (isinstance(list_expr_input, Call) and list_expr_input.has_head("List")):
        raise WolframEvaluationError("SequenceCount expects a List as its first argument.")
    spans = _sequence_match_spans(list_expr_input.arguments, pattern)
    return integer(len(spans))


def total(expr: Expr, levelspec: Expr | None = None) -> Expr:
    """``Total[expr]`` / ``Total[expr, n]`` / ``Total[expr, {n}]``.

    Without a level spec, ``Total`` sums first-level elements: a list of
    numbers folds into a single number, a list of same-length lists
    folds into the column-wise list of sums, and an association folds
    over its values.

    With a level spec ``Total`` follows the kernel's contract:
    integer ``n`` means levels ``1..n`` (so ``Total[m, 2]`` of a matrix
    is the scalar sum of every entry; ``Total[t, Infinity]`` of a
    tensor is the scalar sum of every leaf), and ``{n}`` means level
    ``n`` only (``Total[m, {1}]`` is the column-wise sum;
    ``Total[m, {2}]`` is the row-wise sum).
    """
    if levelspec is None:
        return _total_default(expr)
    return _total_with_levelspec(expr, levelspec)


def _total_default(expr: Expr) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            return integer(0)
        return evaluate(call("Plus", *(entry.value for entry in entries)))
    if isinstance(expr, Call) and expr.has_head("List"):
        if not expr.arguments:
            return integer(0)
        # If every element is itself a same-length List, sum column-wise.
        if all(isinstance(arg, Call) and arg.has_head("List") for arg in expr.arguments):
            row_lengths = {len(arg.arguments) for arg in expr.arguments}
            if len(row_lengths) == 1:
                width = row_lengths.pop()
                if width == 0:
                    return list_expr()
                columns: list[Expr] = []
                for column_index in range(width):
                    column_args = [arg.arguments[column_index] for arg in expr.arguments]
                    columns.append(evaluate(call("Plus", *column_args)))
                return _evaluated_list_expr(*columns)
        return evaluate(call("Plus", *expr.arguments))
    raise WolframEvaluationError("Total expects a list or association.")


def _total_with_levelspec(expr: Expr, levelspec: Expr) -> Expr:
    """Apply ``Total[..., levelspec]`` semantics.

    The level spec is interpreted in the kernel-compatible way:
    integer ``n`` (or ``{1, n}``) means "sum over levels 1 through
    ``n`` inclusive", which collapses ``n`` outer dimensions into the
    accumulator and leaves the inner shape intact. ``{n}`` (the
    single-element list) selects exactly one level. ``Infinity`` is
    equivalent to ``ArrayDepth[expr]``.
    """
    if isinstance(levelspec, Call) and levelspec.has_head("List"):
        if len(levelspec.arguments) == 1:
            level_arg = levelspec.arguments[0]
            single_level = _resolve_total_level(level_arg)
            return _total_at_single_level(expr, single_level)
    upper = _resolve_total_level(levelspec)
    # Sum across levels 1..upper by applying the default Total upper
    # times, but stop early once the result is no longer a list /
    # association so ``Total[..., Infinity]`` collapses to a scalar
    # without raising on the scalar layer.
    result = expr
    for _ in range(upper):
        if not (
            (isinstance(result, Call) and result.has_head("List"))
            or _association_entries(result) is not None
        ):
            break
        result = _total_default(result)
    return result


def _resolve_total_level(level_arg: Expr) -> int:
    if isinstance(level_arg, Integer):
        if level_arg.value < 0:
            raise WolframEvaluationError("Total levelspec must be a non-negative integer or Infinity.")
        return level_arg.value
    if isinstance(level_arg, Symbol) and level_arg.name == "Infinity":
        # ``Infinity`` collapses every level — Tungsten uses the array
        # depth as the practical upper bound.
        return _LEVEL_INFINITY
    raise WolframEvaluationError("Total levelspec must be a non-negative integer or Infinity.")


def _total_at_single_level(expr: Expr, level: int) -> Expr:
    """``Total[expr, {level}]`` — sum exactly at the requested
    1-based level. Implemented by recursing into the expression to
    depth ``level - 1`` and collapsing only that level's siblings.
    """
    if level <= 0:
        raise WolframEvaluationError("Total[..., {n}] requires n >= 1.")
    if level == 1:
        return _total_default(expr)

    def descend(current: Expr, remaining: int) -> Expr:
        if remaining == 1:
            return _total_default(current)
        if isinstance(current, Call) and current.has_head("List"):
            return list_expr(*(descend(child, remaining - 1) for child in current.arguments))
        entries = _association_entries(current)
        if entries is not None:
            new_entries = [
                _AssociationEntry(rule_head=entry.rule_head, key=entry.key, value=descend(entry.value, remaining - 1))
                for entry in entries
            ]
            return _association_expr(new_entries)
        raise WolframEvaluationError("Total[..., {n}] expects nested lists matching the requested level.")

    return descend(expr, level)


def tally(expr: Expr, test: Expr | None = None) -> Expr:
    items = _list_or_association_values(expr, "Tally")
    keys: list[Expr] = []
    counts: list[int] = []
    for item in items:
        index: int | None = None
        for existing_index, existing_key in enumerate(keys):
            if test is None:
                if existing_key == item:
                    index = existing_index
                    break
            else:
                outcome = evaluate(_apply_callable(test, (existing_key, item)))
                if isinstance(outcome, Symbol) and outcome.name == "True":
                    index = existing_index
                    break
        if index is None:
            keys.append(item)
            counts.append(1)
        else:
            counts[index] += 1
    return list_expr(*(list_expr(key, integer(count)) for key, count in zip(keys, counts)))


def counts(expr: Expr, test: Expr | None = None) -> Expr:
    items = _list_or_association_values(expr, "Counts")
    keys: list[Expr] = []
    occurrences: dict[int, int] = {}
    for item in items:
        position: int | None = None
        for existing_index, existing_key in enumerate(keys):
            if _same_test_succeeds(test, existing_key, item):
                position = existing_index
                break
        if position is None:
            keys.append(item)
            occurrences[len(keys) - 1] = 1
        else:
            occurrences[position] += 1
    entries: list[_AssociationEntry] = []
    for index, key in enumerate(keys):
        entries.append(
            _AssociationEntry(rule_head="Rule", key=key, value=integer(occurrences[index]))
        )
    return _association_expr(entries)


def catenate(expr: Expr) -> Expr:
    """Concatenate the immediate elements of a List or Association.

    For ``List[items...]``, every immediate item must itself be a List or
    Association (associations contribute their values). For an
    ``Association`` whose values are Lists, returns the catenation of
    those values.
    """
    entries = _association_entries(expr)
    if entries is not None:
        sequences = [entry.value for entry in entries]
    else:
        compound = _require_compound(expr, "Catenate")
        if not compound.has_head("List"):
            raise WolframEvaluationError("Catenate expects a list or association.")
        sequences = list(compound.arguments)
    flat: list[Expr] = []
    for sequence in sequences:
        if _association_entries(sequence) is not None:
            inner_entries = _association_entries(sequence) or ()
            flat.extend(entry.value for entry in inner_entries)
            continue
        if isinstance(sequence, Call) and sequence.has_head("List"):
            flat.extend(sequence.arguments)
            continue
        raise WolframEvaluationError(
            "Catenate expects every immediate element to be a list or association."
        )
    return list_expr(*flat)


def differences(expr: Expr, order_expr: Expr | None = None) -> Expr:
    """``Differences[list]`` / ``Differences[list, n]`` /
    ``Differences[array, {n1, n2, …}]``.

    The 1-arg form computes the first-difference list; the 2-arg
    form repeats that ``n`` times. The multivariate spec
    ``{n1, n2, …}`` applies first-differences ``n1`` times along
    axis 1, then ``n2`` times along axis 2, and so on for nested
    rectangular arrays.
    """
    if order_expr is None:
        return _differences_axis(expr, 1)

    if isinstance(order_expr, Integer):
        if order_expr.value < 0:
            raise WolframEvaluationError("Differences expects a non-negative integer order.")
        order = order_expr.value
        items_seq = list(_list_or_association_values(expr, "Differences"))
        for _ in range(order):
            items_seq = _differences_one_pass(items_seq)
            if not items_seq:
                break
        return _evaluated_list_expr(*items_seq)

    if isinstance(order_expr, Call) and order_expr.has_head("List"):
        orders: list[int] = []
        for component in order_expr.arguments:
            if not (isinstance(component, Integer) and component.value >= 0):
                raise WolframEvaluationError(
                    "Differences multivariate orders must be non-negative integers."
                )
            orders.append(component.value)
        return _differences_multivariate(expr, orders)

    raise WolframEvaluationError("Differences expects an integer order or a list of orders.")


def _differences_one_pass(items: Sequence[Expr]) -> list[Expr]:
    if len(items) <= 1:
        return []
    return [
        evaluate(call("Plus", items[index + 1], call("Times", integer(-1), items[index])))
        for index in range(len(items) - 1)
    ]


def _differences_axis(expr: Expr, count: int) -> Expr:
    items_seq = list(_list_or_association_values(expr, "Differences"))
    for _ in range(count):
        items_seq = _differences_one_pass(items_seq)
        if not items_seq:
            break
    return _evaluated_list_expr(*items_seq)


def _differences_multivariate(expr: Expr, orders: Sequence[int]) -> Expr:
    """Apply ``orders[0]`` first-differences along axis 1, then
    ``orders[1]`` along axis 2, etc. Each axis recurses into the
    inner rows.
    """
    if not orders:
        return expr
    head_order, *tail_orders = orders
    items = list(_list_or_association_values(expr, "Differences"))

    # Apply ``head_order`` first-differences along the outermost axis.
    for _ in range(head_order):
        items = _differences_one_pass(items)
        if not items:
            return list_expr()

    if not tail_orders:
        return list_expr(*items)

    return list_expr(*(_differences_multivariate(item, tail_orders) for item in items))


def accumulate(expr: Expr, function: Expr | None = None) -> Expr:
    """``Accumulate[list]`` / ``Accumulate[list, f]``.

    Without ``f`` it computes running totals (``Plus``-folded prefixes).
    With ``f`` it computes ``FoldList[f, First[list], Rest[list]]``-style
    running results, applying the supplied callable to ``(running,
    next)`` pairs.
    """
    combiner: callable[[Expr, Expr], Expr]
    if function is None:
        combiner = lambda running, item: evaluate(call("Plus", running, item))
    else:
        combiner = lambda running, item: evaluate(_apply_callable(function, (running, item)))

    entries = _association_entries(expr)
    if entries is not None:
        if not entries:
            return _association_expr([])
        running: Expr | None = None
        new_entries: list[_AssociationEntry] = []
        for entry in entries:
            running = entry.value if running is None else combiner(running, entry.value)
            new_entries.append(
                _AssociationEntry(rule_head=entry.rule_head, key=entry.key, value=running)
            )
        return _association_expr(new_entries)
    items = _list_or_association_values(expr, "Accumulate")
    if not items:
        return list_expr()
    running: Expr | None = None
    output: list[Expr] = []
    for item in items:
        running = item if running is None else combiner(running, item)
        output.append(running)
    return _evaluated_list_expr(*output)


def riffle(expr: Expr, separator: Expr, span: Expr | None = None) -> Expr:
    """``Riffle[list, x]`` / ``Riffle[list, {x1, …, xk}]`` /
    ``Riffle[list, x, {a, b, s}]``.

    Without a span, the separator is inserted between every adjacent
    pair (or cycled through a list of separators). With ``{a, b, s}``
    Tungsten inserts the separator into the *output* at positions
    ``a, a + s, a + 2 s, …`` up to and including ``b`` (where ``b``
    can be a negative offset from the end of the output, matching the
    kernel's ``Riffle[list, x, {2, -1, 2}]`` style).
    """
    compound = _require_compound(expr, "Riffle")
    if not compound.has_head("List"):
        raise WolframEvaluationError("Riffle currently expects a List as the first argument.")
    items = compound.arguments
    if not items:
        return list_expr()

    if span is None:
        separators: tuple[Expr, ...]
        if isinstance(separator, Call) and separator.has_head("List"):
            separators = tuple(separator.arguments)
            if not separators:
                return list_expr(*items)
        else:
            separators = (separator,)
        output: list[Expr] = [items[0]]
        for index, item in enumerate(items[1:], start=1):
            output.append(separators[(index - 1) % len(separators)])
            output.append(item)
        return list_expr(*output)

    if not (isinstance(span, Call) and span.has_head("List") and len(span.arguments) == 3):
        raise WolframEvaluationError("Riffle span spec must be a ``{a, b, s}`` list.")
    a_expr, b_expr, s_expr = span.arguments
    if not all(isinstance(part, Integer) for part in (a_expr, b_expr, s_expr)):
        raise WolframEvaluationError("Riffle span spec components must be explicit integers.")
    a = a_expr.value
    b_raw = b_expr.value
    s = s_expr.value
    if s <= 0:
        raise WolframEvaluationError("Riffle span step must be a positive integer.")
    if a < 1:
        raise WolframEvaluationError("Riffle span start position must be a positive integer.")

    # Simulate the kernel's interleaving rule: walk the output positions
    # 1, 2, 3, ... — at each output position emit the separator when the
    # position equals the next AP step (a, a+s, a+2s, …); otherwise emit
    # the next item from ``items`` if any remain. When ``b`` is positive,
    # cap the AP at ``b``. When ``b`` is non-positive (Wolfram convention:
    # negative offset from the end of the resulting list), Tungsten
    # treats it as "until the items are exhausted, then place one
    # trailing separator at the next AP step." This matches the
    # kernel's ``{2, -1, s}`` style.
    n = len(items)
    use_natural_end = b_raw <= 0
    max_ap_position = b_raw if not use_natural_end else None

    result: list[Expr] = []
    current_ap = a
    item_index = 0
    output_position = 1
    while True:
        if max_ap_position is not None and current_ap > max_ap_position:
            if item_index < n:
                result.append(items[item_index])
                item_index += 1
                output_position += 1
                continue
            break
        if output_position == current_ap:
            result.append(separator)
            current_ap += s
            output_position += 1
            continue
        if item_index < n:
            result.append(items[item_index])
            item_index += 1
            output_position += 1
            continue
        break
    return list_expr(*result)


def count_items(
    expr: Expr,
    pattern: Expr,
    spec: Expr | int | tuple[int, int] | None = None,
    *,
    include_heads: bool = False,
) -> Expr:
    """``Count[expr, patt]`` / ``Count[expr, patt, levelspec]`` /
    ``Count[expr, patt, levelspec, Heads -> True/False]``.

    Tungsten implements ``Count`` over the same traversal as
    ``Position``: with the default level spec ``{1}`` and ``Heads ->
    False`` it counts immediate-argument matches; with deeper
    levelspecs and ``Heads -> True`` it walks heads as well.
    """
    effective_spec: Expr | int | tuple[int, int] = (1, 1) if spec is None else spec
    positions = position(expr, pattern, spec=effective_spec, include_heads=include_heads)
    assert isinstance(positions, Call) and positions.has_head("List")
    return integer(len(positions.arguments))


def all_true(expr: Expr, test: Expr) -> Expr:
    items = _list_or_association_values(expr, "AllTrue")
    for item in items:
        outcome = evaluate(_apply_callable(test, (item,)))
        if not (isinstance(outcome, Symbol) and outcome.name == "True"):
            return _bool_symbol(False)
    return _bool_symbol(True)


def any_true(expr: Expr, test: Expr) -> Expr:
    items = _list_or_association_values(expr, "AnyTrue")
    for item in items:
        outcome = evaluate(_apply_callable(test, (item,)))
        if isinstance(outcome, Symbol) and outcome.name == "True":
            return _bool_symbol(True)
    return _bool_symbol(False)


def none_true(expr: Expr, test: Expr) -> Expr:
    items = _list_or_association_values(expr, "NoneTrue")
    for item in items:
        outcome = evaluate(_apply_callable(test, (item,)))
        if isinstance(outcome, Symbol) and outcome.name == "True":
            return _bool_symbol(False)
    return _bool_symbol(True)


def contains_all(left: Expr, right: Expr) -> Expr:
    left_items = _list_or_association_values(left, "ContainsAll")
    right_items = _list_or_association_values(right, "ContainsAll")
    return _bool_symbol(all(any(left_item == right_item for left_item in left_items) for right_item in right_items))


def contains_any(left: Expr, right: Expr) -> Expr:
    left_items = _list_or_association_values(left, "ContainsAny")
    right_items = _list_or_association_values(right, "ContainsAny")
    return _bool_symbol(any(any(left_item == right_item for left_item in left_items) for right_item in right_items))


def contains_none(left: Expr, right: Expr) -> Expr:
    left_items = _list_or_association_values(left, "ContainsNone")
    right_items = _list_or_association_values(right, "ContainsNone")
    return _bool_symbol(not any(any(left_item == right_item for left_item in left_items) for right_item in right_items))


def contains_exactly(left: Expr, right: Expr) -> Expr:
    left_items = _list_or_association_values(left, "ContainsExactly")
    right_items = _list_or_association_values(right, "ContainsExactly")
    left_set = list(left_items)
    right_set = list(right_items)
    # Wolfram's ContainsExactly ignores duplicates and order: the two sets must
    # have identical underlying value sets.
    return _bool_symbol(
        all(any(item == other for other in left_set) for item in right_set)
        and all(any(item == other for other in right_set) for item in left_set)
    )


def contains_only(arguments: Sequence[Expr]) -> Expr:
    """``ContainsOnly[a, b]`` / ``ContainsOnly[a, b, SameTest -> f]``.

    Returns ``True`` when every element of ``a`` appears in ``b`` under
    structural identity, or under the supplied ``SameTest`` predicate.
    """
    data, same_test = _split_same_test_option_arguments(arguments, "ContainsOnly")
    if len(data) != 2:
        raise WolframEvaluationError("ContainsOnly expects two arguments and an optional SameTest rule.")
    left_items = _list_or_association_values(data[0], "ContainsOnly")
    right_items = list(_list_or_association_values(data[1], "ContainsOnly"))
    for item in left_items:
        if not any(_same_test_succeeds(same_test, item, candidate) for candidate in right_items):
            return _bool_symbol(False)
    return _bool_symbol(True)


def vector_q(expr: Expr, test: Expr | None = None) -> Expr:
    """``VectorQ[expr]`` / ``VectorQ[expr, test]``.

    Returns ``True`` when ``expr`` is a length-1 array — a flat ``List``
    whose every element is itself non-``List`` — and (optionally) every
    element satisfies ``test``. ``SparseArray`` rank-1 values qualify too.
    """
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) != 1:
            return _bool_symbol(False)
        if test is None:
            return _bool_symbol(True)
        if expr.dimensions[0] > len(expr.entries) and not _predicate_succeeds(test, expr.fill_value):
            return _bool_symbol(False)
        return _bool_symbol(all(_predicate_succeeds(test, entry.value) for entry in expr.entries))
    if not (isinstance(expr, Call) and expr.has_head("List")):
        return _bool_symbol(False)
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.has_head("List"):
            return _bool_symbol(False)
    if test is None:
        return _bool_symbol(True)
    return _bool_symbol(all(_predicate_succeeds(test, value) for value in expr.arguments))


def matrix_q(expr: Expr, test: Expr | None = None) -> Expr:
    """``MatrixQ[expr]`` / ``MatrixQ[expr, test]``.

    Returns ``True`` for rank-2 rectangular ``List`` arrays (and rank-2
    ``SparseArray`` values) whose every element optionally satisfies
    ``test``.
    """
    if isinstance(expr, SparseArrayExpr):
        if len(expr.dimensions) != 2:
            return _bool_symbol(False)
        if test is None:
            return _bool_symbol(True)
        total_size = expr.dimensions[0] * expr.dimensions[1]
        if total_size > len(expr.entries) and not _predicate_succeeds(test, expr.fill_value):
            return _bool_symbol(False)
        return _bool_symbol(all(_predicate_succeeds(test, entry.value) for entry in expr.entries))
    try:
        dimensions = _strict_dense_dimensions(expr)
    except WolframEvaluationError:
        return _bool_symbol(False)
    if len(dimensions) != 2:
        return _bool_symbol(False)
    if test is None:
        return _bool_symbol(True)
    return _bool_symbol(all(_predicate_succeeds(test, value) for value in _dense_leaf_values(expr)))


def first_position(
    expr: Expr,
    pattern: Expr,
    default: Expr | object = _MISSING,
    spec: Expr | int | tuple[int, int] | None = None,
) -> Expr:
    """``FirstPosition[expr, patt]`` / ``FirstPosition[expr, patt, default]`` /
    ``FirstPosition[expr, patt, default, levelspec]``.

    Returns the first match's exact structural position list. Falls back
    to ``default`` (or ``Missing["NotFound"]`` if absent) when no match
    exists. Defaults to the ``Position``-style traversal: levels
    ``{0, Infinity}`` with heads included.
    """
    positions = position(expr, pattern, spec=spec, limit=1)
    assert isinstance(positions, Call) and positions.has_head("List")
    if positions.arguments:
        return positions.arguments[0]
    if default is not _MISSING:
        return default  # type: ignore[return-value]
    return _missing_not_found()


def position_largest(expr: Expr) -> Expr:
    """``PositionLargest[list]`` returns the 1-based positions of the
    largest elements in ``list`` under canonical Tungsten order. Ties
    yield multiple positions; the empty list yields ``{}``.
    """
    items = _list_or_association_values(expr, "PositionLargest")
    if not items:
        return list_expr()
    largest_indices: list[int] = []
    for index, item in enumerate(items, start=1):
        if not largest_indices:
            largest_indices.append(index)
            continue
        comparison = _canonical_compare(item, items[largest_indices[0] - 1])
        if comparison > 0:
            largest_indices = [index]
        elif comparison == 0:
            largest_indices.append(index)
    return list_expr(*(integer(idx) for idx in largest_indices))


def position_smallest(expr: Expr) -> Expr:
    """``PositionSmallest[list]`` returns the 1-based positions of the
    smallest elements in ``list`` under canonical Tungsten order. Ties
    yield multiple positions; the empty list yields ``{}``.
    """
    items = _list_or_association_values(expr, "PositionSmallest")
    if not items:
        return list_expr()
    smallest_indices: list[int] = []
    for index, item in enumerate(items, start=1):
        if not smallest_indices:
            smallest_indices.append(index)
            continue
        comparison = _canonical_compare(item, items[smallest_indices[0] - 1])
        if comparison < 0:
            smallest_indices = [index]
        elif comparison == 0:
            smallest_indices.append(index)
    return list_expr(*(integer(idx) for idx in smallest_indices))


def position_index(expr: Expr) -> Expr:
    """``PositionIndex[list]`` returns an ``Association`` mapping each
    distinct element to the list of 1-based positions where it occurs,
    in first-occurrence order.
    """
    items = _list_or_association_values(expr, "PositionIndex")
    order: list[Expr] = []
    bucket: dict[int, list[int]] = {}
    keys: dict[int, Expr] = {}
    for index, item in enumerate(items, start=1):
        for existing_id, existing_key in keys.items():
            if existing_key == item:
                bucket[existing_id].append(index)
                break
        else:
            element_id = id(item) if isinstance(item, (Call, SparseArrayExpr)) else len(keys)
            # ``id()`` can collide if Python reuses memory addresses, so seed
            # from a counter when no existing key matches.
            unique_id = len(keys)
            while unique_id in keys:
                unique_id += 1
            keys[unique_id] = item
            bucket[unique_id] = [index]
            order.append(item)
    entries: list[_AssociationEntry] = []
    for representative in order:
        for unique_id, key in keys.items():
            if key == representative:
                entries.append(
                    _AssociationEntry(
                        rule_head=Symbol("Rule"),
                        key=representative,
                        value=list_expr(*(integer(idx) for idx in bucket[unique_id])),
                    )
                )
                break
    return _association_expr(entries)


def count_distinct(expr: Expr) -> Expr:
    """``CountDistinct[list]`` returns the number of distinct elements
    in ``list`` under structural identity.
    """
    items = _list_or_association_values(expr, "CountDistinct")
    seen: list[Expr] = []
    for item in items:
        if not any(item == existing for existing in seen):
            seen.append(item)
    return integer(len(seen))


def counts_by(expr: Expr, key_function: Expr) -> Expr:
    """``CountsBy[list, f]`` returns an ``Association`` mapping each
    distinct ``f``-key to the number of elements that produced it.
    """
    items = _list_or_association_values(expr, "CountsBy")
    order: list[Expr] = []
    counts: dict[int, int] = {}
    keys: dict[int, Expr] = {}
    for item in items:
        key = evaluate(_apply_callable(key_function, (item,)))
        for unique_id, existing in keys.items():
            if existing == key:
                counts[unique_id] += 1
                break
        else:
            unique_id = len(keys)
            keys[unique_id] = key
            counts[unique_id] = 1
            order.append(key)
    entries: list[_AssociationEntry] = []
    for representative in order:
        for unique_id, key in keys.items():
            if key == representative:
                entries.append(
                    _AssociationEntry(
                        rule_head=Symbol("Rule"),
                        key=representative,
                        value=integer(counts[unique_id]),
                    )
                )
                break
    return _association_expr(entries)


def ratios(expr: Expr) -> Expr:
    """``Ratios[list]`` returns the list of adjacent quotients
    ``list[[i + 1]] / list[[i]]``. Returns ``{}`` for inputs of length
    ≤ 1.
    """
    items = _list_or_association_values(expr, "Ratios")
    if len(items) <= 1:
        return list_expr()
    output: list[Expr] = []
    for index in range(1, len(items)):
        output.append(
            evaluate(
                call(
                    "Times",
                    items[index],
                    call("Power", items[index - 1], integer(-1)),
                )
            )
        )
    return _evaluated_list_expr(*output)


def subdivide(arguments: Sequence[Expr]) -> Expr:
    """``Subdivide[n]`` / ``Subdivide[n, k]`` / ``Subdivide[xmin, xmax, k]``.

    Returns ``k + 1`` evenly-spaced points spanning ``[0, n]``,
    ``[0, n]``, or ``[xmin, xmax]`` respectively. The single-argument
    form ``Subdivide[n]`` returns ``n + 1`` points spanning ``[0, 1]``.
    """
    if len(arguments) == 1:
        n_expr = arguments[0]
        if not isinstance(n_expr, Integer) or n_expr.value <= 0:
            raise WolframEvaluationError("Subdivide expects a positive integer count.")
        n = n_expr.value
        return _evaluated_list_expr(
            *(
                evaluate(call("Times", integer(index), rational_number(1, n)))
                for index in range(n + 1)
            )
        )
    if len(arguments) == 2:
        n_expr, k_expr = arguments
        if not isinstance(k_expr, Integer) or k_expr.value <= 0:
            raise WolframEvaluationError("Subdivide expects a positive integer subdivision count.")
        return _evaluated_list_expr(
            *(
                evaluate(
                    call("Times", n_expr, integer(index), call("Power", k_expr, integer(-1)))
                )
                for index in range(k_expr.value + 1)
            )
        )
    if len(arguments) == 3:
        lo_expr, hi_expr, k_expr = arguments
        if not isinstance(k_expr, Integer) or k_expr.value <= 0:
            raise WolframEvaluationError("Subdivide expects a positive integer subdivision count.")
        k = k_expr.value
        step = call(
            "Times",
            call("Plus", hi_expr, call("Times", integer(-1), lo_expr)),
            call("Power", integer(k), integer(-1)),
        )
        return _evaluated_list_expr(
            *(
                evaluate(call("Plus", lo_expr, call("Times", integer(index), step)))
                for index in range(k + 1)
            )
        )
    raise WolframEvaluationError("Subdivide expects 1, 2, or 3 arguments.")


def subset_map(function: Expr, target: Expr, positions_expr: Expr) -> Expr:
    """``SubsetMap[f, list, positions]`` extracts the elements at
    ``positions``, applies ``f`` to that sublist, then re-injects the
    transformed values into ``list`` at the same positions. The result
    has the same shape as ``list``.
    """
    if not isinstance(target, Call) or not target.has_head("List"):
        raise WolframEvaluationError("SubsetMap currently expects a List as the second argument.")
    if not (isinstance(positions_expr, Call) and positions_expr.has_head("List")):
        raise WolframEvaluationError(
            "SubsetMap expects a List of positions as the third argument."
        )

    items = list(target.arguments)
    indices: list[int] = []
    for raw_position in positions_expr.arguments:
        # Accept ``i`` (integer) or ``{i}`` (single-element list) — the
        # most common shapes. Wolfram also accepts deeper paths but the
        # documented examples are flat first-level positions.
        if isinstance(raw_position, Integer):
            indices.append(raw_position.value)
            continue
        if (
            isinstance(raw_position, Call)
            and raw_position.has_head("List")
            and len(raw_position.arguments) == 1
            and isinstance(raw_position.arguments[0], Integer)
        ):
            indices.append(raw_position.arguments[0].value)
            continue
        raise WolframEvaluationError(
            "SubsetMap currently supports flat integer positions (or one-element ``{i}`` lists)."
        )

    resolved: list[int] = []
    for index in indices:
        resolved_index = _resolve_index(len(items), index)
        resolved.append(resolved_index)

    selected = list_expr(*(items[idx] for idx in resolved))
    transformed = evaluate(_apply_callable(function, (selected,)))
    if not (isinstance(transformed, Call) and transformed.has_head("List")):
        raise WolframEvaluationError(
            "SubsetMap expects the function to return a List of the same length as the selection."
        )
    if len(transformed.arguments) != len(resolved):
        raise WolframEvaluationError(
            "SubsetMap expects the function to return a List of the same length as the selection."
        )

    new_items = list(items)
    for slot, value in zip(resolved, transformed.arguments):
        new_items[slot] = value
    return _rebuild(target, tuple(new_items))


def _resolve_size_range(
    spec: Expr | None,
    function_name: str,
    *,
    default_lower: int,
    default_upper: int,
) -> tuple[int, int, int]:
    """Resolve a kernel-style length spec ``n``, ``{n}``, ``{min, max}``,
    or ``{min, max, step}`` into a ``(lower, upper, step)`` triple.

    Used by ``Subsets`` and ``Permutations`` so both heads share the
    full step-aware vocabulary.
    """
    if spec is None:
        return default_lower, default_upper, 1
    if isinstance(spec, Integer):
        return default_lower, spec.value, 1
    if isinstance(spec, Symbol) and spec.name == "All":
        return default_lower, default_upper, 1
    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1 and isinstance(spec.arguments[0], Integer):
            target = spec.arguments[0].value
            return target, target, 1
        if (
            len(spec.arguments) == 2
            and isinstance(spec.arguments[0], Integer)
            and isinstance(spec.arguments[1], Integer)
        ):
            return spec.arguments[0].value, spec.arguments[1].value, 1
        if (
            len(spec.arguments) == 3
            and all(isinstance(arg, Integer) for arg in spec.arguments)
        ):
            lower = spec.arguments[0].value  # type: ignore[union-attr]
            upper = spec.arguments[1].value  # type: ignore[union-attr]
            step = spec.arguments[2].value  # type: ignore[union-attr]
            if step == 0:
                raise WolframEvaluationError(
                    f"{function_name} length spec step must be nonzero."
                )
            return lower, upper, step
    raise WolframEvaluationError(
        f"{function_name} expects ``n``, ``{{n}}``, ``{{min, max}}``, or ``{{min, max, step}}``."
    )


def _stepped_range(lower: int, upper: int, step: int) -> list[int]:
    """Return the integer range used by ``Subsets`` / ``Permutations``
    for a stepped-length spec. Negative steps walk downward; positive
    steps walk upward, both inclusive of both endpoints when they
    align with the step.
    """
    sizes: list[int] = []
    if step > 0:
        size = lower
        while size <= upper:
            sizes.append(size)
            size += step
    else:
        size = lower
        while size >= upper:
            sizes.append(size)
            size += step
    return sizes


def subsets(expr: Expr, spec: Expr | None = None) -> Expr:
    items = _list_or_association_values(expr, "Subsets")
    n = len(items)
    lower, upper, step = _resolve_size_range(
        spec, "Subsets", default_lower=0, default_upper=n
    )

    from itertools import combinations

    output: list[Expr] = []
    for size in _stepped_range(lower, upper, step):
        if size < 0 or size > n:
            continue
        for combination in combinations(items, size):
            output.append(list_expr(*combination))
    return list_expr(*output)


def permutations(expr: Expr, spec: Expr | None = None) -> Expr:
    items = _list_or_association_values(expr, "Permutations")
    n = len(items)
    if spec is None:
        bounds = (n, n)
        step = 1
    else:
        bounds_lower, bounds_upper, step = _resolve_size_range(
            spec, "Permutations", default_lower=1 if n > 0 else 0, default_upper=n
        )
        bounds = (bounds_lower, bounds_upper)

    from itertools import permutations as _itertools_permutations

    output: list[Expr] = []
    sizes = _stepped_range(bounds[0], bounds[1], step) if spec is not None else [n]
    for size in sizes:
        if size < 0 or size > n:
            continue
        for permutation in _itertools_permutations(items, size):
            output.append(list_expr(*permutation))
    return list_expr(*output)


def _cycles_expr_from_permutation(permutation: Sequence[int]) -> Expr:
    seen: set[int] = set()
    cycles: list[Expr] = []
    for start in range(1, len(permutation) + 1):
        if start in seen or permutation[start - 1] == start:
            seen.add(start)
            continue
        cycle: list[int] = []
        current = start
        while current not in seen:
            seen.add(current)
            cycle.append(current)
            current = permutation[current - 1]
        if len(cycle) > 1:
            cycles.append(list_expr(*(integer(index) for index in cycle)))
    return call("Cycles", list_expr(*cycles))


def random_permutation(expr: Expr) -> Expr:
    if isinstance(expr, Integer):
        if expr.value < 0:
            raise WolframEvaluationError("RandomPermutation expects a non-negative integer.")
        values = list(range(1, expr.value + 1))
        random.shuffle(values)
        return _cycles_expr_from_permutation(values)
    raise WolframEvaluationError("RandomPermutation currently expects an integer length.")


def _canonical_sorted_items(items: Sequence[Expr]) -> list[Expr]:
    return sorted(items, key=cmp_to_key(_canonical_compare))


@dataclass(frozen=True)
class _IntervalSegment:
    left: Expr
    right: Expr


def _is_negative_one_expr(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value == -1
    if isinstance(expr, RationalNumber):
        return expr.value == -1
    return False


def _is_positive_one_expr(expr: Expr) -> bool:
    if isinstance(expr, Integer):
        return expr.value == 1
    if isinstance(expr, RationalNumber):
        return expr.value == 1
    return False


def _interval_comparison_endpoint(expr: Expr) -> Expr:
    if _is_positive_infinity_expr(expr) or _is_negative_infinity_expr(expr):
        return expr
    if (
        isinstance(expr, Call)
        and expr.has_head("Times")
        and len(expr.arguments) == 2
        and any(_is_negative_one_expr(argument) for argument in expr.arguments)
        and any(_is_positive_infinity_expr(argument) for argument in expr.arguments)
    ):
        return symbol("-Infinity")
    if isinstance(expr, Call) and expr.has_head("DirectedInfinity") and len(expr.arguments) == 1:
        direction = expr.arguments[0]
        if _is_positive_one_expr(direction):
            return symbol("Infinity")
        if _is_negative_one_expr(direction):
            return symbol("-Infinity")
    return expr


def _interval_endpoint_compare(left: Expr, right: Expr) -> int | None:
    return _compare_real_expr(
        _interval_comparison_endpoint(left),
        _interval_comparison_endpoint(right),
    )


def _interval_segment_from_argument(argument: Expr) -> _IntervalSegment | None:
    if isinstance(argument, Call) and argument.has_head("List"):
        if len(argument.arguments) != 2:
            return None
        left, right = argument.arguments
    else:
        left = argument
        right = argument
    comparison = _interval_endpoint_compare(left, right)
    if comparison is None:
        return None
    if comparison <= 0:
        return _IntervalSegment(left, right)
    return _IntervalSegment(right, left)


def _interval_segment_compare(left: _IntervalSegment, right: _IntervalSegment) -> int:
    left_compare = _interval_endpoint_compare(left.left, right.left)
    if left_compare is not None and left_compare != 0:
        return _integer_sign(left_compare)
    right_compare = _interval_endpoint_compare(left.right, right.right)
    if right_compare is not None and right_compare != 0:
        return _integer_sign(right_compare)
    return 0


def _normalize_interval_segments(segments: Sequence[_IntervalSegment]) -> list[_IntervalSegment] | None:
    if not segments:
        return []
    sorted_segments = sorted(segments, key=cmp_to_key(_interval_segment_compare))
    merged: list[_IntervalSegment] = []
    for segment in sorted_segments:
        if not merged:
            merged.append(segment)
            continue
        last = merged[-1]
        overlap_compare = _interval_endpoint_compare(segment.left, last.right)
        if overlap_compare is None:
            return None
        if overlap_compare <= 0:
            right_compare = _interval_endpoint_compare(segment.right, last.right)
            if right_compare is None:
                return None
            if right_compare > 0:
                merged[-1] = _IntervalSegment(last.left, segment.right)
            continue
        merged.append(segment)
    return merged


def _interval_segments_from_arguments(arguments: Sequence[Expr]) -> list[_IntervalSegment] | None:
    segments: list[_IntervalSegment] = []
    for argument in arguments:
        segment = _interval_segment_from_argument(argument)
        if segment is None:
            return None
        segments.append(segment)
    return _normalize_interval_segments(segments)


def _interval_segments_from_interval(expr: Expr) -> list[_IntervalSegment] | None:
    if not isinstance(expr, Call) or not expr.has_head("Interval"):
        return None
    return _interval_segments_from_arguments(expr.arguments)


def _interval_segment_expr(segment: _IntervalSegment) -> Expr:
    return list_expr(segment.left, segment.right)


def _interval_expr_from_segments(segments: Sequence[_IntervalSegment]) -> Expr:
    return call("Interval", *(_interval_segment_expr(segment) for segment in segments))


def interval_expr(arguments: Sequence[Expr]) -> Expr:
    segments = _interval_segments_from_arguments(arguments)
    if segments is None:
        return call("Interval", *arguments)
    return _interval_expr_from_segments(segments)


def interval_union(arguments: Sequence[Expr]) -> Expr:
    segments: list[_IntervalSegment] = []
    for argument in arguments:
        argument_segments = _interval_segments_from_interval(argument)
        if argument_segments is None:
            return call("IntervalUnion", *arguments)
        segments.extend(argument_segments)
    normalized = _normalize_interval_segments(segments)
    if normalized is None:
        return call("IntervalUnion", *arguments)
    return _interval_expr_from_segments(normalized)


def _intersect_interval_segment(left: _IntervalSegment, right: _IntervalSegment) -> _IntervalSegment | None:
    start_compare = _interval_endpoint_compare(left.left, right.left)
    end_compare = _interval_endpoint_compare(left.right, right.right)
    if start_compare is None or end_compare is None:
        return None
    start = left.left if start_compare >= 0 else right.left
    end = left.right if end_compare <= 0 else right.right
    containment_compare = _interval_endpoint_compare(start, end)
    if containment_compare is not None and containment_compare <= 0:
        return _IntervalSegment(start, end)
    return None


def interval_intersection(arguments: Sequence[Expr]) -> Expr:
    if not arguments:
        return call("Interval")
    initial = _interval_segments_from_interval(arguments[0])
    if initial is None:
        return call("IntervalIntersection", *arguments)
    current = initial
    for argument in arguments[1:]:
        argument_segments = _interval_segments_from_interval(argument)
        if argument_segments is None:
            return call("IntervalIntersection", *arguments)
        intersections: list[_IntervalSegment] = []
        for left in current:
            for right in argument_segments:
                segment = _intersect_interval_segment(left, right)
                if segment is not None:
                    intersections.append(segment)
        normalized = _normalize_interval_segments(intersections)
        if normalized is None:
            return call("IntervalIntersection", *arguments)
        current = normalized
        if not current:
            break
    return _interval_expr_from_segments(current)


def _interval_contains_segment(container: Sequence[_IntervalSegment], candidate: _IntervalSegment) -> bool:
    for segment in container:
        left_compare = _interval_endpoint_compare(segment.left, candidate.left)
        right_compare = _interval_endpoint_compare(candidate.right, segment.right)
        if left_compare is None or right_compare is None:
            continue
        if left_compare <= 0 and right_compare <= 0:
            return True
    return False


def interval_member_q(interval: Expr, item: Expr) -> Expr:
    segments = _interval_segments_from_interval(interval)
    if segments is None:
        return symbol("False")
    if isinstance(item, Call) and item.has_head("List"):
        return _evaluated_list_expr(*(interval_member_q(interval, element) for element in item.arguments))
    item_segments = _interval_segments_from_interval(item)
    if item_segments is not None:
        return _bool_symbol(all(_interval_contains_segment(segments, segment) for segment in item_segments))
    item_segment = _interval_segment_from_argument(item)
    if item_segment is None:
        return symbol("False")
    return _bool_symbol(_interval_contains_segment(segments, item_segment))


def _unique_by_same_test(items: Sequence[Expr], test: Expr | None) -> list[Expr]:
    unique: list[Expr] = []
    for item in items:
        if not _contains_by_same_test(unique, item, test):
            unique.append(item)
    return unique


def _split_same_test_option_arguments(
    arguments: Sequence[Expr],
    function_name: str,
) -> tuple[tuple[Expr, ...], Expr | None]:
    data_arguments, options = _split_trailing_option_rules(arguments)
    unsupported = [
        option
        for option in options
        if (parts := _option_rule_parts(option)) is not None and parts[0] != "SameTest"
    ]
    if unsupported:
        raise WolframEvaluationError(f"{function_name} currently supports only the SameTest option.")
    return data_arguments, _same_test_from_options(options)


def union(arguments: Sequence[Expr]) -> Expr:
    """Union[list1, list2, ...] returns sorted unique elements."""
    arguments, same_test = _split_same_test_option_arguments(arguments, "Union")
    if not arguments:
        return list_expr()
    items: list[Expr] = []
    for argument in arguments:
        items.extend(_list_or_association_values(argument, "Union"))
    return list_expr(*_unique_by_same_test(_canonical_sorted_items(items), same_test))


def intersection(arguments: Sequence[Expr]) -> Expr:
    arguments, same_test = _split_same_test_option_arguments(arguments, "Intersection")
    if not arguments:
        return list_expr()
    initial = list(_list_or_association_values(arguments[0], "Intersection"))
    for argument in arguments[1:]:
        other = _list_or_association_values(argument, "Intersection")
        initial = [item for item in initial if any(_same_test_succeeds(same_test, item, other_item) for other_item in other)]
    return list_expr(*_canonical_sorted_items(_unique_by_same_test(initial, same_test)))


def complement(arguments: Sequence[Expr]) -> Expr:
    arguments, same_test = _split_same_test_option_arguments(arguments, "Complement")
    if not arguments:
        return list_expr()
    base = list(_list_or_association_values(arguments[0], "Complement"))
    excluded: list[Expr] = []
    for argument in arguments[1:]:
        for item in _list_or_association_values(argument, "Complement"):
            if not _contains_by_same_test(excluded, item, same_test):
                excluded.append(item)
    survivors: list[Expr] = []
    for item in base:
        if not _contains_by_same_test(excluded, item, same_test):
            survivors.append(item)
    return list_expr(*_unique_by_same_test(_canonical_sorted_items(survivors), same_test))


def pad_left(expr: Expr, target_length_expr: Expr, fill_expr: Expr | None = None) -> Expr:
    compound = _require_compound(expr, "PadLeft")
    if not compound.has_head("List"):
        raise WolframEvaluationError("PadLeft currently expects a List as the first argument.")
    if not isinstance(target_length_expr, Integer):
        raise WolframEvaluationError("PadLeft currently expects an integer target length.")
    target_length = target_length_expr.value
    fill: Expr = fill_expr if fill_expr is not None else integer(0)
    if target_length < 0:
        raise WolframEvaluationError("PadLeft expects a non-negative target length.")
    items = list(compound.arguments)
    if target_length <= len(items):
        return list_expr(*items[len(items) - target_length :])
    return list_expr(*([fill] * (target_length - len(items)) + items))


def pad_right(expr: Expr, target_length_expr: Expr, fill_expr: Expr | None = None) -> Expr:
    compound = _require_compound(expr, "PadRight")
    if not compound.has_head("List"):
        raise WolframEvaluationError("PadRight currently expects a List as the first argument.")
    if not isinstance(target_length_expr, Integer):
        raise WolframEvaluationError("PadRight currently expects an integer target length.")
    target_length = target_length_expr.value
    fill: Expr = fill_expr if fill_expr is not None else integer(0)
    if target_length < 0:
        raise WolframEvaluationError("PadRight expects a non-negative target length.")
    items = list(compound.arguments)
    if target_length <= len(items):
        return list_expr(*items[:target_length])
    return list_expr(*(items + [fill] * (target_length - len(items))))


def chinese_remainder(residues_expr: Expr, moduli_expr: Expr) -> Expr:
    """ChineseRemainder[{r1, r2, ...}, {m1, m2, ...}] for explicit-integer
    pairwise-coprime moduli. Returns the smallest non-negative integer ``x``
    such that ``Mod[x, mi] == ri`` for every ``i``.
    """
    if not isinstance(residues_expr, Call) or not residues_expr.has_head("List"):
        raise WolframEvaluationError("ChineseRemainder expects a list of residues.")
    if not isinstance(moduli_expr, Call) or not moduli_expr.has_head("List"):
        raise WolframEvaluationError("ChineseRemainder expects a list of moduli.")
    if len(residues_expr.arguments) != len(moduli_expr.arguments):
        raise WolframEvaluationError(
            "ChineseRemainder expects residues and moduli of the same length."
        )

    if not all(isinstance(item, Integer) for item in residues_expr.arguments):
        raise WolframEvaluationError("ChineseRemainder currently expects explicit integer residues.")
    if not all(isinstance(item, Integer) for item in moduli_expr.arguments):
        raise WolframEvaluationError("ChineseRemainder currently expects explicit integer moduli.")

    residues = [item.value for item in residues_expr.arguments]  # type: ignore[union-attr]
    moduli = [item.value for item in moduli_expr.arguments]  # type: ignore[union-attr]

    if any(modulus == 0 for modulus in moduli):
        raise WolframEvaluationError("ChineseRemainder moduli must be nonzero.")

    # Iterative CRT: combine pairs (r, m) into a single congruence modulo lcm.
    current_residue = 0
    current_modulus = 1
    for residue, modulus in zip(residues, moduli):
        modulus = abs(modulus)
        gcd_value = math.gcd(current_modulus, modulus)
        if (residue - current_residue) % gcd_value != 0:
            raise WolframEvaluationError(
                "ChineseRemainder system is inconsistent for the given residues and moduli."
            )
        # Solve current_modulus * t ≡ (residue - current_residue) (mod modulus / gcd)
        reduced_modulus = modulus // gcd_value
        try:
            inverse = pow(current_modulus // gcd_value, -1, reduced_modulus)
        except ValueError as exc:
            raise WolframEvaluationError(
                "ChineseRemainder requires invertible reduced moduli."
            ) from exc
        offset = ((residue - current_residue) // gcd_value * inverse) % reduced_modulus
        current_residue = (current_residue + current_modulus * offset) % (current_modulus * reduced_modulus)
        current_modulus = current_modulus * reduced_modulus
    return integer(current_residue)


def from_digits(digits_expr: Expr, base_expr: Expr | None = None) -> Expr:
    base = 10
    if base_expr is not None:
        if not isinstance(base_expr, Integer) or base_expr.value < 2:
            raise WolframEvaluationError("FromDigits expects an integer base >= 2.")
        base = base_expr.value
    if isinstance(digits_expr, String):
        digit_values: list[int] = []
        for character in digits_expr.value:
            try:
                digit_values.append(int(character, base))
            except ValueError:
                raise WolframEvaluationError(
                    f"FromDigits cannot interpret {character!r} as a base-{base} digit."
                )
    elif isinstance(digits_expr, Call) and digits_expr.has_head("List"):
        digit_values = []
        for digit in digits_expr.arguments:
            if not isinstance(digit, Integer):
                raise WolframEvaluationError("FromDigits expects a list of explicit integer digits.")
            digit_values.append(digit.value)
    else:
        raise WolframEvaluationError("FromDigits expects a string or a list of digits.")
    result = 0
    for value in digit_values:
        result = result * base + value
    return integer(result)


def key_sort(expr: Expr, ordering_function: Expr | None = None) -> Expr:
    entries = _require_association_entries(expr, "KeySort")
    import functools
    indices = list(range(len(entries)))

    if ordering_function is None:
        def default_compare(left_index: int, right_index: int) -> int:
            return _canonical_compare(entries[left_index].key, entries[right_index].key)
        indices.sort(key=functools.cmp_to_key(default_compare))
        return _association_expr([entries[index] for index in indices])

    def comparator_less(left_index: int, right_index: int) -> bool:
        outcome = evaluate(
            _apply_callable(ordering_function, (entries[left_index].key, entries[right_index].key))
        )
        return isinstance(outcome, Symbol) and outcome.name == "True"

    def comparator_compare(left_index: int, right_index: int) -> int:
        if comparator_less(left_index, right_index):
            return -1
        if comparator_less(right_index, left_index):
            return 1
        return 0

    indices.sort(key=functools.cmp_to_key(comparator_compare))
    return _association_expr([entries[index] for index in indices])


def _require_association_entries(expr: Expr, function_name: str) -> tuple[_AssociationEntry, ...]:
    entries = _association_entries(expr)
    if entries is None:
        raise WolframEvaluationError(f"{function_name} expects an Association.")
    return entries


def _rebuild(expr: Call, arguments: Sequence[Expr]) -> Call:
    if isinstance(expr.head_expr, Symbol):
        arguments = _normalize_arguments_for_head(expr.head_expr.name, arguments, evaluated=True)
    return Call(head_expr=expr.head_expr, arguments=tuple(arguments))


def _normalize_integer_argument(value: Expr | int, function_name: str) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, Integer):
        return value.value
    raise WolframEvaluationError(f"{function_name} expects an integer argument.")


def _sequence_length(expr: Expr) -> int:
    entries = _association_entries(expr)
    if entries is not None:
        return len(entries)
    if isinstance(expr, Call):
        return len(expr.arguments)
    return 0


def _take_or_drop(expr: Expr, specs: Sequence[Expr | int], *, drop: bool) -> Expr:
    function_name = "Drop" if drop else "Take"
    spec = specs[0]

    entries = _association_entries(expr)
    if entries is not None and _is_association_key_selector_list(spec):
        # The kernel supports key-list specs on associations
        # (``Take[<|a -> 1, b -> 2, c -> 3|>, {Key[a], Key[b]}]``); raise a
        # Tungsten diagnostic so callers don't get silent inertness.
        raise WolframEvaluationError(
            f"{function_name} on associations currently supports only numeric or span selectors; "
            "key-list selectors such as ``{Key[a], …}`` are not yet implemented."
        )

    selectors = _normalize_take_drop_selectors(expr, spec, function_name)
    if entries is not None:
        if drop:
            removed = {_resolve_index(len(entries), selector) for selector in selectors}
            return _association_expr(entry for index, entry in enumerate(entries) if index not in removed)
        return _association_expr(entries[_resolve_index(len(entries), selector)] for selector in selectors)

    compound = _require_compound(expr, function_name)
    if drop:
        removed = {_resolve_index(len(compound.arguments), selector) for selector in selectors}
        return _rebuild(
            compound,
            tuple(argument for index, argument in enumerate(compound.arguments) if index not in removed),
        )
    return _rebuild(compound, tuple(_select_single_part_value(compound, selector) for selector in selectors))


def _is_association_key_selector_list(spec: Expr | int) -> bool:
    """Detect a ``{Key[k1], …}`` or ``{"k1", …}`` selector list, which the
    kernel honors on associations but which Tungsten does not yet implement.
    """
    if not isinstance(spec, Call) or not spec.has_head("List"):
        return False
    if not spec.arguments:
        return False
    for entry in spec.arguments:
        if isinstance(entry, Call) and entry.has_head("Key"):
            return True
        if isinstance(entry, String):
            return True
    return False


def _normalize_take_drop_selectors(expr: Expr, spec: Expr | int, function_name: str) -> list[int]:
    count = _sequence_length(expr)

    if isinstance(spec, int):
        selectors = list(range(1, spec + 1)) if spec >= 0 else list(range(count + spec + 1, count + 1))
        return _validate_selectors(expr, selectors, function_name)

    if isinstance(spec, Integer):
        return _normalize_take_drop_selectors(expr, spec.value, function_name)

    if isinstance(spec, Symbol) and spec.name == "All":
        return list(range(1, count + 1))

    if isinstance(spec, Symbol) and spec.name == "None":
        # Wolfram's Take[expr, None] / Drop[expr, None] selects nothing,
        # which means Take returns an empty result and Drop returns expr
        # untouched. The caller's drop/take branch interprets an empty
        # selector list correctly without further work.
        return []

    if isinstance(spec, Call) and spec.has_head("Span"):
        return _validate_selectors(expr, _expand_span_spec(expr, spec), function_name)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1:
            item = spec.arguments[0]
            if isinstance(item, Integer):
                return _validate_selectors(expr, [item.value], function_name)
            if isinstance(item, Symbol) and item.name == "All":
                return list(range(1, count + 1))
            raise WolframEvaluationError(f"{function_name} single-element list specifications must contain an integer or All.")
        if len(spec.arguments) in {2, 3}:
            return _validate_selectors(
                expr,
                _expand_span_spec_from_count(count, Call(head_expr=Symbol("Span"), arguments=spec.arguments)),
                function_name,
            )
        raise WolframEvaluationError(f"{function_name} list specifications must contain one, two, or three items.")

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _validate_selectors(expr: Expr, selectors: Sequence[int], function_name: str) -> list[int]:
    count = _sequence_length(expr)
    for selector in selectors:
        _resolve_index(count, selector)
    return list(selectors)


def _normalize_flatten_level(level_spec: Expr | int | None) -> int | None:
    if level_spec is None:
        return None
    if isinstance(level_spec, int):
        if level_spec < 0:
            raise WolframEvaluationError("Flatten levels must be non-negative.")
        return level_spec
    if isinstance(level_spec, Integer):
        return _normalize_flatten_level(level_spec.value)
    if isinstance(level_spec, Symbol) and level_spec.name == "Infinity":
        return None
    raise WolframEvaluationError("Flatten levels must be a non-negative integer or Infinity.")


def _flatten_same_head(expr: Call, remaining: int | None) -> Expr:
    if remaining == 0:
        return expr

    arguments: list[Expr] = []
    for argument in expr.arguments:
        if isinstance(argument, Call) and argument.head_expr == expr.head_expr:
            nested = _flatten_same_head(argument, None if remaining is None else remaining - 1)
            assert isinstance(nested, Call)
            arguments.extend(nested.arguments)
            continue
        arguments.append(argument)
    return _rebuild(expr, arguments)


def _normalize_replace_part_rules(replacements: Expr) -> list[tuple[Expr, Expr]]:
    if isinstance(replacements, Call) and (replacements.has_head("Rule") or replacements.has_head("RuleDelayed")):
        if len(replacements.arguments) != 2:
            raise WolframEvaluationError("ReplacePart rules must contain exactly two arguments.")
        return [(replacements.arguments[0], replacements.arguments[1])]

    if isinstance(replacements, Call) and replacements.has_head("List"):
        rules: list[tuple[Expr, Expr]] = []
        for item in replacements.arguments:
            if not isinstance(item, Call) or (not item.has_head("Rule") and not item.has_head("RuleDelayed")) or len(item.arguments) != 2:
                raise WolframEvaluationError("ReplacePart expects a rule or a list of rules.")
            rules.append((item.arguments[0], item.arguments[1]))
        return rules

    raise WolframEvaluationError("ReplacePart expects a rule or a list of rules.")


def _expand_operation_paths(
    expr: Expr,
    positions: Expr | Sequence[Expr | Sequence[int] | int],
) -> tuple[list[list[_IndexSelector | _KeySelector]], bool]:
    if isinstance(positions, Expr):
        return _expand_position_expr_to_exact_paths(expr, positions)

    paths: list[list[_IndexSelector | _KeySelector]] = []
    invalid = False
    for item in positions:
        if isinstance(item, Expr):
            expanded, had_invalid = _expand_position_expr_to_exact_paths(expr, item)
            paths.extend(expanded)
            invalid = invalid or had_invalid
            continue
        if isinstance(item, int):
            expanded, had_invalid = _expand_position_expr_to_exact_paths(expr, integer(item))
            paths.extend(expanded)
            invalid = invalid or had_invalid
            continue
        components = [integer(component) for component in item]
        expanded, had_invalid = _expand_exact_position_components(expr, components)
        paths.extend(expanded)
        invalid = invalid or had_invalid
    return (paths, invalid)


def _expand_position_expr_to_exact_paths(expr: Expr, spec: Expr) -> tuple[list[list[_IndexSelector | _KeySelector]], bool]:
    if _is_collection_of_position_specs(spec):
        paths: list[list[_IndexSelector | _KeySelector]] = []
        invalid = False
        assert isinstance(spec, Call)
        for item in spec.arguments:
            expanded, had_invalid = _expand_exact_position_components(expr, _position_components_from_expr(item))
            paths.extend(expanded)
            invalid = invalid or had_invalid
        return (paths, invalid)

    if _is_single_position_spec_expr(spec):
        return _expand_exact_position_components(expr, _position_components_from_expr(spec))

    raise WolframEvaluationError(f"Unsupported position specification: {spec.to_input_form()}.")


def _expand_exact_position_components(
    expr: Expr,
    components: Sequence[Expr],
) -> tuple[list[list[_IndexSelector | _KeySelector]], bool]:
    if not components:
        return ([[]], False)

    selections, invalid = _resolve_component_selections(expr, components[0], allow_head=False, function_name="Position")
    paths: list[list[_IndexSelector | _KeySelector]] = []
    for selection in selections:
        child_paths, child_invalid = _expand_exact_position_components(selection.child, components[1:])
        invalid = invalid or child_invalid
        for child_path in child_paths:
            paths.append([selection.selector, *child_path])
    return (paths, invalid)


def _resolve_component_selections(
    expr: Expr,
    component: Expr,
    *,
    allow_head: bool,
    function_name: str,
) -> tuple[list[_SelectedPart], bool]:
    if isinstance(component, Integer) and component.value == 0:
        if not allow_head:
            raise WolframEvaluationError(f"{function_name} does not support index 0 in this position.")
        return ([_SelectedPart(_IndexSelector(0), head_of(expr))], False)

    entries = _association_entries(expr)
    if entries is not None:
        return _resolve_association_component_selections(entries, component, function_name=function_name)

    if isinstance(expr, Call):
        return _resolve_call_component_selections(expr, component, function_name=function_name)

    return ([], True)


def _resolve_call_component_selections(
    expr: Call,
    component: Expr,
    *,
    function_name: str,
) -> tuple[list[_SelectedPart], bool]:
    selectors, invalid = _resolve_numeric_selectors(
        len(expr.arguments),
        component,
        function_name=function_name,
        allow_head=False,
    )
    return ([selection for selection in (_selected_part_from_exact_selector(expr, selector) for selector in selectors) if selection is not None], invalid)


def _resolve_association_component_selections(
    entries: Sequence[_AssociationEntry],
    component: Expr,
    *,
    function_name: str,
) -> tuple[list[_SelectedPart], bool]:
    if _is_key_selector_atom(component):
        key = _key_from_selector(component)
        selection = _selected_association_part(entries, _KeySelector(key))
        return ([selection], False) if selection is not None else ([], True)

    if isinstance(component, Call) and component.has_head("List"):
        kinds = {_selector_atom_kind(item) for item in component.arguments}
        if None in kinds:
            raise WolframEvaluationError(f"Unsupported selector inside {function_name} specification: {component.to_input_form()}.")
        if "numeric" in kinds and "key" in kinds:
            raise WolframEvaluationError("Association selector lists may not mix numeric and key selectors.")
        if kinds == {"key"}:
            selections: list[_SelectedPart] = []
            invalid = False
            for item in component.arguments:
                selection = _selected_association_part(entries, _KeySelector(_key_from_selector(item)))
                if selection is None:
                    invalid = True
                    continue
                selections.append(selection)
            return (selections, invalid)

    selectors, invalid = _resolve_numeric_selectors(
        len(entries),
        component,
        function_name=function_name,
        allow_head=False,
    )
    selections = [selection for selection in (_selected_association_part(entries, selector) for selector in selectors) if selection is not None]
    return (selections, invalid)


def _resolve_numeric_selectors(
    length_value: int,
    component: Expr,
    *,
    function_name: str,
    allow_head: bool,
) -> tuple[list[_IndexSelector], bool]:
    if isinstance(component, Integer):
        if component.value == 0:
            if allow_head:
                return ([_IndexSelector(0)], False)
            raise WolframEvaluationError(f"{function_name} does not support index 0 in this position.")
        resolved = _try_resolve_index(length_value, component.value)
        if resolved is None:
            return ([], True)
        return ([_IndexSelector(resolved + 1)], False)

    if isinstance(component, Symbol) and component.name == "All":
        return ([_IndexSelector(index) for index in range(1, length_value + 1)], False)

    if isinstance(component, Call) and component.has_head("Span"):
        selectors: list[_IndexSelector] = []
        invalid = False
        for index in _expand_span_spec_from_count(length_value, component):
            resolved = _try_resolve_index(length_value, index)
            if resolved is None:
                invalid = True
                continue
            selectors.append(_IndexSelector(resolved + 1))
        return (selectors, invalid)

    if isinstance(component, Call) and component.has_head("List"):
        selectors: list[_IndexSelector] = []
        invalid = False
        for item in component.arguments:
            kind = _selector_atom_kind(item)
            if kind == "key":
                raise WolframEvaluationError(f"Unsupported selector inside {function_name} specification: {item.to_input_form()}.")
            nested, nested_invalid = _resolve_numeric_selectors(
                length_value,
                item,
                function_name=function_name,
                allow_head=False,
            )
            selectors.extend(nested)
            invalid = invalid or nested_invalid
        return (selectors, invalid)

    raise WolframEvaluationError(f"Unsupported {function_name} specification: {component.to_input_form()}.")


def _selector_atom_kind(expr: Expr) -> str | None:
    if isinstance(expr, Integer):
        return "numeric"
    if isinstance(expr, Symbol) and expr.name == "All":
        return "numeric"
    if isinstance(expr, Call) and expr.has_head("Span"):
        return "numeric"
    if _is_key_selector_atom(expr):
        return "key"
    return None


def _is_key_selector_atom(expr: Expr) -> bool:
    return isinstance(expr, String) or (
        isinstance(expr, Call)
        and expr.has_head("Key")
        and len(expr.arguments) == 1
    )


def _key_from_selector(expr: Expr) -> Expr:
    if isinstance(expr, String):
        return expr
    if isinstance(expr, Call) and expr.has_head("Key") and len(expr.arguments) == 1:
        return expr.arguments[0]
    raise WolframEvaluationError(f"Expected a key selector, got {expr.to_input_form()}.")


def _is_position_component(expr: Expr) -> bool:
    return _is_selector_atom(expr) or (
        isinstance(expr, Call)
        and expr.has_head("List")
        and all(_is_selector_atom(item) for item in expr.arguments)
    )


def _is_collection_of_position_specs(expr: Expr) -> bool:
    return (
        isinstance(expr, Call)
        and expr.has_head("List")
        and bool(expr.arguments)
        and all(
            isinstance(item, Call)
            and item.has_head("List")
            and all(_is_position_component(component) for component in item.arguments)
            for item in expr.arguments
        )
    )


def _is_selector_atom(expr: Expr) -> bool:
    return _selector_atom_kind(expr) is not None


def _is_single_position_spec_expr(expr: Expr) -> bool:
    if isinstance(expr, Integer) or _is_key_selector_atom(expr):
        return True
    return isinstance(expr, Call) and expr.has_head("List") and all(_is_position_component(item) for item in expr.arguments)


def _try_resolve_index(length_value: int, index: int) -> int | None:
    try:
        return _resolve_index(length_value, index)
    except WolframEvaluationError:
        return None


def _dedupe_paths(paths: Sequence[Sequence[_IndexSelector | _KeySelector]]) -> list[list[_IndexSelector | _KeySelector]]:
    seen: set[tuple[_IndexSelector | _KeySelector, ...]] = set()
    unique: list[list[_IndexSelector | _KeySelector]] = []
    for path in paths:
        key = tuple(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(list(path))
    return unique


def _sort_paths(
    paths: Sequence[Sequence[_IndexSelector | _KeySelector]],
) -> list[list[_IndexSelector | _KeySelector]]:
    return [
        list(path)
        for path in sorted(
            (tuple(path) for path in paths),
            key=lambda path: (len(path), tuple(_path_component_sort_key(component) for component in path)),
            reverse=True,
        )
    ]


def _sort_path_items(
    items: Sequence[tuple[Sequence[_IndexSelector | _KeySelector], Expr]],
) -> list[tuple[list[_IndexSelector | _KeySelector], Expr]]:
    return [
        (list(path), value)
        for path, value in sorted(
            ((tuple(path), value) for path, value in items),
            key=lambda item: (len(item[0]), tuple(_path_component_sort_key(component) for component in item[0])),
            reverse=True,
        )
    ]


def _path_component_sort_key(component: _IndexSelector | _KeySelector) -> tuple[int, int | str]:
    if isinstance(component, _IndexSelector):
        return (0, component.index)
    return (1, component.key.to_input_form())


def _try_delete_at_path(
    expr: Expr,
    path: Sequence[_IndexSelector | _KeySelector],
) -> tuple[Expr, bool]:
    if not path:
        return (expr, False)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        if len(path) == 1:
            del mutable[index]
            return (_association_expr(mutable), True)
        updated_child, changed = _try_delete_at_path(entry.value, path[1:])
        if not changed:
            return (expr, False)
        mutable[index] = _AssociationEntry(entry.rule_head, entry.key, updated_child)
        return (_association_expr(mutable), True)

    if not isinstance(expr, Call):
        return (expr, False)
    selector = path[0]
    if not isinstance(selector, _IndexSelector):
        return (expr, False)
    resolved = selector.index - 1
    if not 0 <= resolved < len(expr.arguments):
        return (expr, False)

    arguments = list(expr.arguments)
    if len(path) == 1:
        del arguments[resolved]
        return (_rebuild(expr, arguments), True)

    updated_child, changed = _try_delete_at_path(arguments[resolved], path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _try_replace_at_path(
    expr: Expr,
    path: Sequence[_IndexSelector | _KeySelector],
    replacement: Expr,
) -> tuple[Expr, bool]:
    if not path:
        return (replacement, True)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        if len(path) == 1:
            mutable[index] = _AssociationEntry(entry.rule_head, entry.key, replacement)
            return (_association_expr(mutable), True)
        updated_child, changed = _try_replace_at_path(entry.value, path[1:], replacement)
        if not changed:
            return (expr, False)
        mutable[index] = _AssociationEntry(entry.rule_head, entry.key, updated_child)
        return (_association_expr(mutable), True)

    if not isinstance(expr, Call):
        return (expr, False)
    selector = path[0]
    if not isinstance(selector, _IndexSelector):
        return (expr, False)
    resolved = selector.index - 1
    if not 0 <= resolved < len(expr.arguments):
        return (expr, False)

    arguments = list(expr.arguments)
    updated_child, changed = _try_replace_at_path(arguments[resolved], path[1:], replacement)
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _try_map_at_path(
    expr: Expr,
    function: Expr,
    path: Sequence[_IndexSelector | _KeySelector],
) -> tuple[Expr, bool]:
    if not path:
        return (_apply_callable(function, (expr,)), True)

    entries = _association_entries(expr)
    if entries is not None:
        selection = _select_association_entry(entries, path[0])
        if selection is None:
            return (expr, False)
        index, entry = selection
        mutable = list(entries)
        if len(path) == 1:
            mutable[index] = _AssociationEntry(
                entry.rule_head,
                entry.key,
                _apply_callable(function, (entry.value,)),
            )
            return (_association_expr(mutable), True)
        updated_child, changed = _try_map_at_path(entry.value, function, path[1:])
        if not changed:
            return (expr, False)
        mutable[index] = _AssociationEntry(entry.rule_head, entry.key, updated_child)
        return (_association_expr(mutable), True)

    if not isinstance(expr, Call):
        return (expr, False)
    selector = path[0]
    if not isinstance(selector, _IndexSelector):
        return (expr, False)
    resolved = selector.index - 1
    if not 0 <= resolved < len(expr.arguments):
        return (expr, False)

    arguments = list(expr.arguments)
    updated_child, changed = _try_map_at_path(arguments[resolved], function, path[1:])
    if not changed:
        return (expr, False)
    arguments[resolved] = updated_child
    return (_rebuild(expr, arguments), True)


def _select_association_entry(
    entries: Sequence[_AssociationEntry],
    selector: _IndexSelector | _KeySelector,
) -> tuple[int, _AssociationEntry] | None:
    if isinstance(selector, _IndexSelector):
        index = selector.index - 1
        if 0 <= index < len(entries):
            return (index, entries[index])
        return None

    for index, entry in enumerate(entries):
        if entry.key == selector.key:
            return (index, entry)
    return None


def _selected_association_part(
    entries: Sequence[_AssociationEntry],
    selector: _IndexSelector | _KeySelector,
) -> _SelectedPart | None:
    selected = _select_association_entry(entries, selector)
    if selected is None:
        return None
    _index, entry = selected
    return _SelectedPart(selector=selector, child=entry.value, entry=entry)


def _selected_part_from_exact_selector(expr: Expr, selector: _IndexSelector) -> _SelectedPart | None:
    if selector.index == 0:
        return _SelectedPart(selector=selector, child=head_of(expr))
    if not isinstance(expr, Call):
        return None
    index = selector.index - 1
    if not 0 <= index < len(expr.arguments):
        return None
    return _SelectedPart(selector=selector, child=expr.arguments[index])


def _component_is_multi(component: Expr) -> bool:
    return (
        (isinstance(component, Symbol) and component.name == "All")
        or (isinstance(component, Call) and component.has_head("Span"))
        or (isinstance(component, Call) and component.has_head("List"))
    )


def _part_recursive(expr: Expr, specs: Sequence[Expr]) -> Expr:
    if not specs:
        return expr

    component = specs[0]
    selections, invalid = _resolve_component_selections(expr, component, allow_head=True, function_name="Part")
    multi = _component_is_multi(component)
    if invalid or (not selections and not multi):
        raise WolframEvaluationError(f"Part specifications are invalid for {expr.to_input_form()}.")

    remaining = specs[1:]
    if not multi:
        return _part_recursive(selections[0].child, remaining) if remaining else selections[0].child

    transformed = [(_part_recursive(selection.child, remaining) if remaining else selection.child) for selection in selections]
    return _rebuild_selected_parts(expr, selections, transformed)


def _rebuild_selected_parts(
    expr: Expr,
    selections: Sequence[_SelectedPart],
    values: Sequence[Expr],
) -> Expr:
    entries = _association_entries(expr)
    if entries is not None:
        rebuilt_entries: list[_AssociationEntry] = []
        for selection, value in zip(selections, values, strict=True):
            if selection.entry is None:
                continue
            rebuilt_entries.append(
                _AssociationEntry(
                    rule_head=selection.entry.rule_head,
                    key=selection.entry.key,
                    value=value,
                )
            )
        return _association_expr(rebuilt_entries)

    if not isinstance(expr, Call):
        raise WolframEvaluationError("Cannot rebuild selected parts from an atom.")
    return _rebuild(expr, values)


def evaluate(
    expr: Expr,
    *,
    session: EvaluationSession | None = None,
    _iteration_continuation: bool = False,
) -> Expr:
    previous_depth = _ACTIVE_EVALUATION_DEPTH.get()
    if previous_depth == 0 and session is None:
        _GLOBAL_MESSAGES.clear()
        _GLOBAL_VISIBLE_MESSAGES.clear()
        _GLOBAL_PRINTS.clear()
    iteration_root_token = None
    previous_iteration_count = _ACTIVE_EVALUATION_ITERATION_COUNT.get()
    if not _iteration_continuation:
        iteration_root_token = _ACTIVE_EVALUATION_ITERATION_COUNT.set(0)
        previous_iteration_count = 0
    apply_main_loop_hooks = (
        previous_depth == 0
        and session is not None
        and not _MAIN_LOOP_HOOKS_SUPPRESSED.get()
    )
    session_token = None
    if session is not None:
        session_token = _ACTIVE_EVALUATION_SESSION.set(session)
    current_depth = previous_depth if _iteration_continuation else previous_depth + 1
    recursion_limit = _finite_system_limit_value("$RecursionLimit")
    if recursion_limit is not None and current_depth > recursion_limit:
        emit_message(
            call("MessageName", symbol("$RecursionLimit"), string("reclim")),
            f"Recursion depth exceeded {recursion_limit}.",
        )
        if session_token is not None:
            _ACTIVE_EVALUATION_SESSION.reset(session_token)
        if iteration_root_token is not None:
            _ACTIVE_EVALUATION_ITERATION_COUNT.reset(iteration_root_token)
        if previous_depth > 0:
            raise _TungstenTerminatedEvaluationSignal("RecursionLimit")
        return call("TerminatedEvaluation", symbol("RecursionLimit"))
    iteration_count = previous_iteration_count + 1
    iteration_token = _ACTIVE_EVALUATION_ITERATION_COUNT.set(iteration_count)
    iteration_limit = _finite_system_limit_value("$IterationLimit")
    if iteration_limit is not None and iteration_count > iteration_limit:
        emit_message(
            call("MessageName", symbol("$IterationLimit"), string("itlim")),
            f"Iteration count exceeded {iteration_limit}.",
        )
        if session_token is not None:
            _ACTIVE_EVALUATION_SESSION.reset(session_token)
        _ACTIVE_EVALUATION_ITERATION_COUNT.reset(iteration_token)
        if iteration_root_token is not None:
            _ACTIVE_EVALUATION_ITERATION_COUNT.reset(iteration_root_token)
        if previous_depth > 0:
            raise _TungstenTerminatedEvaluationSignal("IterationLimit")
        return call("TerminatedEvaluation", symbol("IterationLimit"))
    depth_token = _ACTIVE_EVALUATION_DEPTH.set(current_depth)
    try:
        try:
            _check_time_constraints()
            input_expr = _apply_pre_hook(expr, session) if apply_main_loop_hooks else expr
            result = _evaluate(input_expr)
            return _apply_post_hook(result, session) if apply_main_loop_hooks else result
        except _TungstenTimeConstraintSignal:
            if previous_depth > 0:
                raise
            return symbol("$Aborted")
        except _TungstenThrowSignal as signal:
            if previous_depth > 0:
                raise
            return _uncaught_throw_result(signal)
        except _TungstenConfirmSignal as signal:
            if previous_depth > 0:
                raise
            emit_message(call("MessageName", symbol("Confirm"), string("confirmnotag")))
            return signal.failure
        except _TungstenTerminatedEvaluationSignal as signal:
            if previous_depth > 0:
                raise
            return call("TerminatedEvaluation", symbol(signal.reason))
        except _TungstenBreakSignal:
            if previous_depth > 0:
                raise
            # Bare ``Break[]`` outside a loop emits ``Break::nofwd`` and
            # stays inert. Tungsten reproduces the inert fallback (the
            # message is currently not emitted).
            return call("Break")
        except _TungstenContinueSignal:
            if previous_depth > 0:
                raise
            return call("Continue")
        except _TungstenReturnSignal as signal:
            if previous_depth > 0:
                raise
            # Uncaught ``Return[expr]`` / ``Return[expr, head]`` becomes
            # the inert ``Return[evaluated_expr]`` / ``Return[..., head]``
            # form, matching the kernel's "Return outside a function
            # definition" behavior.
            if signal.head_name is None:
                return call("Return", signal.value)
            return call("Return", signal.value, symbol(signal.head_name))
        except _TungstenGotoSignal as signal:
            if previous_depth > 0:
                raise
            # ``Goto`` whose target ``Label`` is not present in any
            # enclosing CompoundExpression becomes inert ``Goto[label]``.
            return call("Goto", signal.label)
        except TungstenAbortRequested:
            if previous_depth > 0:
                raise
            return symbol("$Aborted")
        except WolframEvaluationError as exc:
            emit_evaluation_error_message(expr, exc)
            return expr
    finally:
        if session_token is not None:
            _ACTIVE_EVALUATION_SESSION.reset(session_token)
        _ACTIVE_EVALUATION_ITERATION_COUNT.reset(iteration_token)
        _ACTIVE_EVALUATION_DEPTH.reset(depth_token)
        if iteration_root_token is not None:
            _ACTIVE_EVALUATION_ITERATION_COUNT.reset(iteration_root_token)


def _evaluate(expr: Expr) -> Expr:
    from .expression_evaluator import evaluate_once

    return evaluate_once(expr)


def _evaluate_iteration_continuation(expr: Expr) -> Expr:
    return evaluate(expr, _iteration_continuation=True)


def parse_expression(text: str, form: str = "input") -> Expr:
    from .expression_parser import parse_expression as _parse_expression

    return _parse_expression(text, form=form)


def parse_input_form(text: str) -> Expr:
    from .expression_parser import parse_input_form as _parse_input_form

    return _parse_input_form(text)


def parse_full_form(text: str) -> Expr:
    from .expression_parser import parse_full_form as _parse_full_form

    return _parse_full_form(text)


def parse_standard_form(text: str) -> Expr:
    from .expression_parser import parse_standard_form as _parse_standard_form

    return _parse_standard_form(text)


def _interpret_standard_form(expr: Expr) -> Expr:
    from .expression_parser import interpret_standard_form

    return interpret_standard_form(expr)


def _box_item_to_standard_text(expr: Expr) -> str:
    from .expression_parser import box_item_to_standard_text

    return box_item_to_standard_text(expr)


def _resolve_index(length_value: int, index: int) -> int:
    if index > 0:
        resolved = index - 1
    elif index < 0:
        resolved = length_value + index
    else:
        raise WolframEvaluationError("Only top-level Part specifications may use index 0.")

    if not 0 <= resolved < length_value:
        raise WolframEvaluationError(f"Part index {index} is out of range for length {length_value}.")
    return resolved


def _select_single_part_value(expr: Call, index: int) -> Expr:
    return expr.arguments[_resolve_index(len(expr.arguments), index)]


def _expand_span_spec(expr: Expr, span: Call) -> list[int]:
    count = _sequence_length(expr)
    if count == 0 and not _is_association(expr) and not isinstance(expr, Call):
        raise WolframEvaluationError("Span cannot be applied to an atom.")
    return _expand_span_spec_from_count(count, span)


def _expand_span_spec_from_count(length_value: int, span: Call) -> list[int]:
    if length_value < 0:
        raise WolframEvaluationError("Span cannot be applied to an atom.")

    if len(span.arguments) not in {2, 3}:
        raise WolframEvaluationError("Span must contain two or three arguments.")

    start_expr = span.arguments[0]
    end_expr = span.arguments[1]
    step_expr = span.arguments[2] if len(span.arguments) == 3 else integer(1)

    start = _span_endpoint_value(start_expr, length_value, default=1)
    end = _span_endpoint_value(end_expr, length_value, default=length_value)
    step = _span_step_value(step_expr)

    if step == 0:
        raise WolframEvaluationError("Span step cannot be zero.")

    stop = end + (1 if step > 0 else -1)
    return list(range(start, stop, step))


def _span_endpoint_value(expr: Expr, length_value: int, *, default: int) -> int:
    if isinstance(expr, Symbol) and expr.name == "All":
        return length_value
    if isinstance(expr, Integer):
        value = expr.value
        if value < 0:
            return length_value + value + 1
        return value
    return default


def _span_step_value(expr: Expr) -> int:
    if isinstance(expr, Integer):
        return expr.value
    raise WolframEvaluationError("Span steps must be integers.")


def _position_components_from_expr(expr: Expr) -> list[Expr]:
    if isinstance(expr, Integer) or _is_key_selector_atom(expr):
        return [expr]
    if isinstance(expr, Call) and expr.has_head("List"):
        return list(expr.arguments)
    raise WolframEvaluationError(f"Expected a Wolfram position list, got {expr.to_input_form()}.")


def _key_spec_items(expr: Expr) -> list[Expr]:
    if isinstance(expr, Call) and expr.has_head("List"):
        return list(expr.arguments)
    return [expr]


@dataclass(frozen=True)
class _LevelRecord:
    expr: Expr
    positive_level: int
    negative_level: int


def _collect_levels(expr: Expr, positive_level: int, target: list[_LevelRecord]) -> None:
    entries = _association_entries(expr)
    if entries is not None:
        for entry in entries:
            _collect_levels(entry.value, positive_level + 1, target)
        target.append(_LevelRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))
        return
    if isinstance(expr, Call):
        for argument in expr.arguments:
            _collect_levels(argument, positive_level + 1, target)
    target.append(_LevelRecord(expr=expr, positive_level=positive_level, negative_level=-depth(expr)))


def _normalize_level_bound(expr: Expr) -> int:
    if isinstance(expr, Integer):
        return expr.value
    if isinstance(expr, Symbol) and expr.name == "Infinity":
        return _LEVEL_INFINITY
    raise WolframEvaluationError(f"Unsupported level bound: {expr.to_input_form()}.")


def _normalize_level_spec(spec: Expr | int | tuple[int, int]) -> tuple[int, int]:
    if isinstance(spec, int):
        if spec >= 0:
            return (0 if spec == 0 else 1, spec)
        return (1, spec)

    if isinstance(spec, tuple):
        if len(spec) != 2:
            raise WolframEvaluationError("Python tuple level specifications must contain exactly two integers.")
        return spec

    if isinstance(spec, Integer):
        return _normalize_level_spec(spec.value)

    if isinstance(spec, Symbol) and spec.name == "Infinity":
        return (1, _LEVEL_INFINITY)

    if isinstance(spec, Call) and spec.has_head("List"):
        if len(spec.arguments) == 1 and isinstance(spec.arguments[0], (Integer, Symbol)):
            value = _normalize_level_bound(spec.arguments[0])
            return (value, value)
        if len(spec.arguments) == 2 and all(
            isinstance(item, Integer) or (isinstance(item, Symbol) and item.name == "Infinity")
            for item in spec.arguments
        ):
            return (_normalize_level_bound(spec.arguments[0]), _normalize_level_bound(spec.arguments[1]))

    raise WolframEvaluationError(f"Unsupported Level specification: {spec.to_input_form() if isinstance(spec, Expr) else spec!r}.")


def _level_matches(record: _LevelRecord, level_min: int, level_max: int) -> bool:
    return _level_bounds_match(record.positive_level, record.negative_level, level_min, level_max)
