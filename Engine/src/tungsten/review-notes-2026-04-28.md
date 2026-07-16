# Tungsten Numeric Source Review Notes

Created (UTC): 2026-04-28T23:55:11Z
Repository HEAD: 7b191bfb92bffdc48fe7f81804217e67fb1e54ab

## Scope

These notes record observations from reviewing `Engine/src/tungsten/` for the
overflow/underflow large-number fallback design.

## Observations

- `expression.py` still owns both the core AST atom classes and many low-level numeric helpers.
  `expression_arithmetic.py` owns the evaluator dispatch for arithmetic, relations, predicates, and
  number-theory heads, but imports runtime helpers back from `expression.py`.
- `SpecialReal` is already the right model for Wolfram-compatible `Overflow[]` and `Underflow[]`:
  it is an atom, has head `Real`, prints like a nullary call, and serializes as a special real.
- The practical arithmetic seams are `_inexact_real_result`, `_div_real_expr`, and
  `_real_power_expr`, with `_add_numeric_expr`, `_mul_numeric_expr`, `_div_numeric_expr`, and
  `_numeric_power_expr` as the public helper layer above real arithmetic.
- `_machine_real` maps infinities to `Overflow[]`; Python float underflow can reach `_machine_real`
  as ordinary `0.0`, so underflow fallback must be detected before that conversion.
- Precision and accuracy queries are centralized through `_precision_value` and `_accuracy_value`,
  which makes adding a new large real atom feasible without changing many call sites.
- The current exact integer power path can allocate enormous Python integers if a large exponent is
  accepted. A structural exact-power guard belongs near that path even though the first requested
  behavior concerns floating-point overflow and underflow.

## Conclusions

- Do not replace `SpecialReal`; add a separate `LargeReal` atom with head `Real` for certified
  fallback results.
- Keep the pure large-number engine outside `expression.py` to avoid increasing the size and
  coupling of the already large expression module.
- Trigger fallback from failed or lossy finite-operand operations, not from arithmetic involving an
  explicit `Overflow[]` or `Underflow[]` operand.
- Carry certified precision and residual bounds as payload data. Formatting and `Precision` should
  consume that data instead of deriving claims from display length.
