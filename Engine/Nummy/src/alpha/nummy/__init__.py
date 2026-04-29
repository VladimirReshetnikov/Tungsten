"""Reference Python implementation for Nummy tower arithmetic."""

__version__ = "0.1.0-alpha"

from .calculator import (
    DEFAULT_CALCULATOR_PRECISION,
    CalculatorEvaluation,
    CalculatorSession,
    CalculatorSyntaxError,
    CalculatorValue,
    format_value,
    tokenize,
)
from .context import DEFAULT_CONTEXT, NummyContext
from .mo import MathOverflowCalculation, calculate_mathoverflow_integer_part
from .sparse_decimal import SparseDecimalInteger
from .tower import (
    DOMINATED_ADDEND,
    INEXACT,
    ROUNDED,
    TowerReal,
)

__all__ = [
    "CalculatorEvaluation",
    "CalculatorSession",
    "CalculatorSyntaxError",
    "CalculatorValue",
    "DEFAULT_CONTEXT",
    "DEFAULT_CALCULATOR_PRECISION",
    "DOMINATED_ADDEND",
    "INEXACT",
    "MathOverflowCalculation",
    "NummyContext",
    "ROUNDED",
    "SparseDecimalInteger",
    "TowerReal",
    "__version__",
    "calculate_mathoverflow_integer_part",
    "format_value",
    "tokenize",
]
