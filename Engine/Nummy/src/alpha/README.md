# Nummy Alpha Python Reference Implementation

Created (UTC): 2026-04-28T19:31:12Z

Repository HEAD: 3c2a03b0e2fe1a8eadcd7407d2fd5fa01dfb3852

This directory contains Nummy's first repository-owned Python reference
implementation. It is intentionally standard-library-only and focused on
structural base-10 power-tower arithmetic, sparse decimal integers, a compact
Tungsten-style calculator REPL, and the direct calculation of the MathOverflow
example archived under
`../../docs/how-to-calculate-1010101010-1010/`.

## Layout

| Path | Purpose |
| --- | --- |
| `nummy/` | Importable Python package. |
| `tests/` | Standard-library `unittest` coverage for the alpha implementation. |
| `IMPLEMENTATION_APPROACH.md` | Design rationale, prior-art conclusions, and current limitations. |
| `review-notes-2026-04-28.md` | Agent observations about this source directory. |
| `tests/review-notes-2026-04-28.md` | Agent observations about the alpha tests. |

Run the tests from this directory with:

```powershell
python -m unittest discover -s tests
```

Start the calculator REPL with:

```powershell
python -m nummy
```

The REPL supports floating-point and integer literals, `+`, `-`, `*`, `/`, `^`,
parentheses, immediate variable assignment, default-zero variables, and
Tungsten/Wolfram-style output history references: `%`, `%%`, and `%n`.
Calculator output uses Wolfram-style precision marks, for example
``0.33333333333333333333`20``. Decimal digits before the backtick are
generated from exact rational arithmetic for the certified arithmetic subset.

Configure the default output precision with:

```powershell
python -m nummy --precision 80
```

Per-expression precision can be requested with Wolfram-style input:

```text
1.23`30 * 2
1.23`30*^6
N[1 / 3, 60]
SetPrecision[1 / 7, 80]
```

If a structural tower approximation cannot certify ordinary decimal digits,
the result is marked with precision `0`. The archived MathOverflow expression
is an exception handled by the alpha perturbation path: entering the ordinary
expression itself prints the sparse leading term plus its first-order
correction:

```text
10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))
```

Taking the floor of the same ordinary expression gives the exact sparse integer
part and the stability metadata:

```text
Floor[10 ^ (10 ^ (10 ^ (10 ^ (10 ^ (-10 ^ 10)))))]
```

Run the MathOverflow calculation with:

```powershell
python -m nummy mo
```

For scripted REPL tests, suppress the banner with:

```powershell
python -m nummy repl --no-banner --precision 30
```
