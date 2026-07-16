# Nummy Implementation: Asymptotic Power-Tower with Leading-Digit Extraction

Created (UTC): 2026-04-28T19:13:36Z

Repository HEAD: 83d5cc4c911c6227d582e0bd7945632bd91d271c

This directory holds the beta Nummy implementation track. It implements the
asymptotic power-tower idea now summarized in the unified prototype comparison
under [`../../docs/reports/alpha-beta-gamma-unified-comparison.md`](../../docs/reports/alpha-beta-gamma-unified-comparison.md).
The older standalone Nummy proposals are archived under
[`../../docs/proposals/archived/`](../../docs/proposals/archived/).

## What it does

Two surfaces:

1. **Asymptotic-tower library.** The headline computation is the
   MathOverflow #79217 expression archived under
   [`../../docs/how-to-calculate-1010101010-1010/`](../../docs/how-to-calculate-1010101010-1010/):

   ```text
   N = 10^(10^(10^(10^(10^(-10^10)))))
   ```

   Calling `compute_mo_expression()` returns a structured report whose
   digits match the published derivation exactly:

   ```text
   N's integer part begins '1', followed by 9999999987 zero(s), then '2811012357389'
   (10000000001 digits total); fractional part begins .4407116278182784...
   ```

   That output is produced in milliseconds at 80 decimal digits of
   working precision. The leading-digit information is all there in a
   small Python object; nothing tries to materialize the 10-billion-digit
   integer in memory.

2. **REPL calculator (`tungsten.exe`-flavoured).** Run with `python -m
   nummy` (or the installed `nummy` console script) to get an
   `In[n]:= ` / `Out[n]= ` prompt loop with a deliberately tiny grammar:

   ```text
   In[1]:= 5.77 * 2.11

   Out[1]= 12.1747

   In[2]:= x = % * 100

   Out[2]= x = 1217.47

   In[3]:= 10 ^ (10 ^ 10)

   Out[3]= 10^^2(10.0)
   ```

   Supported syntax: integer and floating-point literals (with optional
   Mathematica-style precision suffix, see below), identifiers,
   `+ - * / ^`, parentheses, immediate assignment `name = expr`, history
   references `%`, `%%`, `%n`. Unassigned variables resolve to `0`.

   ### Precision

   Each value carries a precision tag (decimal digits).  The session
   precision is configurable via the magic identifier `Precision`, and
   results display their precision with a Mathematica-style ``\\`prec``
   suffix whenever it differs from `MachinePrecision` (16):

   ```text
   In[1]:= Precision = 50

   Out[1]= Precision = 50

   In[2]:= 1 / 7

   Out[2]= 0.14285714285714285714285714285714285714285714285714`50

   In[3]:= 1.5`30 / 7

   Out[3]= 0.214285714285714285714285714286`30

   In[4]:= pi = 3.141592653589793238462643383279502884`30

   Out[4]= pi = 3.14159265358979323846264338328`30

   In[5]:= pi * 2

   Out[5]= 6.28318530717958647692528676656`30
   ```

   Precision-propagation rules:

   * Integer literals are *exact* (`Precision[3]` is effectively
     infinite); they never drag down the precision of an operation.
   * Float literals without a backtick adopt the current session
     precision.
   * `value\`n` annotates a literal with `n` decimal digits of precision.
   * Operations use `min` over operand precisions (treating `EXACT` as
     "infinite").  When two exact integers combine into a non-integer
     result (e.g. `5 / 3`), the result is demoted to the session
     precision.

   Internal arithmetic runs at `claimed_precision + 10` guard digits, so
   every displayed digit is provably correct -- subject to the standard
   cascading-tail caveat that values close to a precision boundary (a
   long `...999` or `...000` tail) may shift in the last digit.

   Values whose `|log10|` exceeds about `10^6` print in
   `10^^layer(mag)` notation via the library's `PowerTower` formatter
   (and without a precision suffix -- towers are described
   structurally).  Exponents whose magnitude exceeds `10^15` are
   refused; that regime is the asymptotic-tower library's job
   (`compute_mo_expression`).

   ### Reproducing the MathOverflow #79217 answer

   The expression `10^(10^(10^(10^(10^(-10^10)))))` cannot be evaluated
   directly with ordinary mpmath at any reasonable precision -- the
   leading 13 trailing digits of the integer part live below the
   dominant `10^(10^10)` magnitude, and the asymptotic-series
   propagation in `nummy.compute_mo_expression` is the only way to get
   them.  The REPL exposes that machinery as the Mathematica-style
   built-in `LeadingDigits[k, n]`, which computes the leading digits
   of `10^^k(-10^n)`:

   ```text
   In[1]:= LeadingDigits[5, 10]

     10^^5(-10^10)
     integer part has 10,000,000,001 digits
     leading digit:                 1
     followed by zero(s):           9,999,999,987
     trailing integer digits:       2811012357389
     fractional digits:             .4407116278182784
     dropped higher-order terms:  <= 10^(-9999999975.403)

   Out[1]= 2811012357389.441
   ```

   Crank up the precision and the same call resolves more fractional
   digits of the leading correction (10^11 * ln(10)^4):

   ```text
   In[2]:= Precision = 30

   Out[2]= Precision = 30

   In[3]:= LeadingDigits[5, 10]

     10^^5(-10^10)
     integer part has 10,000,000,001 digits
     leading digit:                 1
     followed by zero(s):           9,999,999,987
     trailing integer digits:       2811012357389
     fractional digits:             .440711627818278478365617826416
     dropped higher-order terms:  <= 10^(-9999999975.403)

   Out[3]= 2811012357389.44071162781827848`30
   ```

   The returned value is the additive correction on top of the
   dominant `10^(10^10)`; the multi-line summary above it spells out
   the full integer-part shape in compact form (one `1`, ten billion
   minus thirteen zeros, then `2811012357389`).

## How it works

The library propagates an **asymptotic Taylor series** in a small parameter
`x` through each level of `10^(.)`. Starting from `v_1 = 10^(-10^10) = x`,
each subsequent `v_{k+1} = 10^v_k` updates a `(scale, series(x))` pair:
the new scale absorbs the constant term `10^M`, and the series captures
the perturbation. When the scale outgrows `mpmath.mpf` capacity (at level
4 -> 5 for the MO problem) it is *deferred* as a one-layer power tower
rather than materialized.

At the end, evaluating the series at `x = 10^(-10^10)` produces a clean
`(dominant 10^E, mpf correction)` decomposition. The dominant
contributes the leading `1` and a long run of zeros; the correction
contributes the trailing 13 integer digits and the fractional part.

The derivation is embodied in the `nummy/asymptotic.py`, `nummy/leading_digits.py`,
and `nummy/mo.py` modules. The contrast with alpha, gamma, and the prior-art
approaches is summarized in
[`../../docs/reports/alpha-beta-gamma-unified-comparison.md`](../../docs/reports/alpha-beta-gamma-unified-comparison.md).

## Layout

```
Engine/Nummy/src/beta/
|-- README.md                  -- this file
|-- pyproject.toml             -- minimal package metadata
|-- nummy/
|   |-- __init__.py
|   |-- __main__.py            -- `python -m nummy` entry point (launches REPL)
|   |-- tower.py               -- PowerTower (sign, layer, mag) for general magnitude work
|   |-- series.py              -- PerturbationSeries with mpmath coefficients
|   |-- asymptotic.py          -- AsymptoticTowerValue + apply_pow10 propagator
|   |-- leading_digits.py      -- LeadingDigits report assembly
|   |-- mo.py                  -- compute_mo_expression: MathOverflow #79217 driver
|   |-- calc.py                -- REPL lexer / parser / evaluator
|   `-- repl.py                -- interactive In[n]:= / Out[n]= loop
|-- tests/
|   |-- test_tower.py
|   |-- test_series.py
|   |-- test_asymptotic.py
|   |-- test_mo.py
|   |-- test_calc_lexer.py
|   |-- test_calc_parser.py
|   |-- test_calc_evaluator.py
|   |-- test_repl.py
|   |-- test_calc_functions.py
|   `-- test_extra.py
`-- examples/
    `-- mo_question.py
```

## Running

The package depends only on `mpmath`. From `Engine/Nummy/src/beta/`:

```bash
# Interactive REPL:
PYTHONPATH=. python -m nummy

# One-shot MathOverflow example:
PYTHONPATH=. python examples/mo_question.py

# Test suite (~2s, 144 tests):
PYTHONPATH=. python -m unittest discover -s tests -v

# Editable install (for downstream use; also creates a `nummy` console script):
pip install -e .
```

Python 3.10 or newer is required (the library uses `|`-union types and
modern `dataclasses` features).

## Worked example output

```text
MathOverflow #79217: 10^(10^(10^(10^(10^(-10^10)))))
============================================================
Sign:                          +
Integer part has               10,000,000,001 digits
Leading digit:                 1
Following zeros count:         9,999,999,987
Trailing integer digits:       2811012357389
First fractional digits:       .4407116278182784
Dropped higher-order terms:    <= 10^(-9999999975.403) (negligible vs. integer part)
```

## Scope and limits

Supported:

- Power towers `10^^K(B)` with `K` up to about 10 levels and `B` ranging
  from typical mpf values to `-10^N` for large `N`.
- The MathOverflow #79217 problem and its variants (different `K`,
  different inner constant `B`).
- `PowerTower(sign, layer, mag)` magnitude work for towers up to a few
  hundred levels (comparison, `pow10`/`log10`, conversion).

Not yet supported (and noted in the design proposal):

- General arithmetic between two arbitrary asymptotic-tower values when
  their dominant centers and small parameters are unrelated. Each
  asymptotic value carries its own `x` parameter; mixing two is a
  multivariate-series problem this proposal does not address.
- `apply_pow10` on a deferred-scale input (i.e., extending the MO chain
  beyond five levels). The propagator currently raises
  `NotImplementedError` in that branch with a pointer to the design
  proposal section that would describe the extension.

## Cross-references

- Unified prototype comparison:
  [`../../docs/reports/alpha-beta-gamma-unified-comparison.md`](../../docs/reports/alpha-beta-gamma-unified-comparison.md)
- The MathOverflow question that motivated the work:
  [`../../docs/how-to-calculate-1010101010-1010/`](../../docs/how-to-calculate-1010101010-1010/)
- Prior-art reference implementations whose approach is contrasted with
  this one: [`../../prior-art/`](../../prior-art/), surveyed in
  [`../../docs/reports/Prototype Corpus Overview.md`](../../docs/reports/Prototype%20Corpus%20Overview.md)
