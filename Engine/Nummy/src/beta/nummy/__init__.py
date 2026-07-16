"""Nummy: asymptotic power-tower arithmetic with leading-digit extraction.

The package targets one specific computational regime: values of the form
10^(10^(...^v)) where the tower is several to a few hundred levels deep,
and where the leading digits depend on perturbations from a clean
integer-shaped tower.

Public surface:
    PowerTower             -- (sign, layer, mag) tower for general magnitude work.
    PerturbationSeries     -- power series with mpmath.mpf coefficients.
    AsymptoticTowerValue   -- (deferred scale, series) for inter-level perturbation.
    LeadingDigits          -- structured result describing leading digits.
    apply_pow10            -- propagate one level of 10^(.) for an asymptotic value.
    compute_mo_expression  -- worked example: MathOverflow #79217.

REPL / calculator:
    CalcSession, execute, parse, tokenize, format_value -- programmatic
        access to the limited expression-language calculator.
    run_repl                -- launch the interactive ``In[n]:=`` prompt.

See ``Engine/Nummy/docs/reports/alpha-beta-gamma-unified-comparison.md``
for the current cross-prototype design summary.
"""

__version__ = "0.1.0"

from .tower import PowerTower
from .series import PerturbationSeries, exp_of_series, pow10_of_series, ln10
from .asymptotic import AsymptoticTowerValue, apply_pow10
from .leading_digits import LeadingDigits, leading_digits_of
from .mo import compute_mo_expression
from .calc import (
    EXACT,
    MACHINE_PRECISION,
    CalcEvaluationError,
    CalcSession,
    CalcSyntaxError,
    ExecutionResult,
    PrecValue,
    execute,
    format_value,
    parse,
    tokenize,
)
from .repl import run_repl

__all__ = [
    "PowerTower",
    "PerturbationSeries",
    "AsymptoticTowerValue",
    "LeadingDigits",
    "apply_pow10",
    "compute_mo_expression",
    "exp_of_series",
    "pow10_of_series",
    "leading_digits_of",
    "ln10",
    "CalcSession",
    "CalcSyntaxError",
    "CalcEvaluationError",
    "ExecutionResult",
    "EXACT",
    "MACHINE_PRECISION",
    "PrecValue",
    "execute",
    "format_value",
    "parse",
    "tokenize",
    "run_repl",
]
