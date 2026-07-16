# Agent Review: `Engine/Nummy/src/gamma`

Created (UTC): 2026-04-28T21:25:00Z

## Directory intent

`gamma/` is a **research prototype**: it is intentionally narrow and acceptance-test-driven.
The goal is to represent and partially evaluate tower-scale quantities (hundreds of base-10
`10^(...)` layers) without materializing impossible digit strings, while still being able to
recover conventional finite information (a “tail”) in special regimes like the archived
MathOverflow example.

## What’s in here

- `docs/`
  - `prior-art-summary.md`: quick scan of prior art relevant to tower-scale numbers and “range-only” arithmetic.
  - `proposed-approach.md`: the concrete approach used by the prototype (structural towers + landmark+tail).
- `nummy_tower/`
  - `Pow10Tower`: structural `10^^h(top)` representation (no eager evaluation).
  - `compute_pow10_tower_small_bottom_linear`: first-order perturbation propagation specialized for tiny `10^bottom_exponent`.
  - `compute_mo_1010101010_1010`: the motivating MathOverflow computation as an explicit acceptance helper.
  - `tests/`: `unittest` coverage for the above.
- `gamma_repl.py`
  - A small calculator REPL with `In[n]:=` / `Out[n]=` prompts and `%`/`%%`/`%n` history,
    inspired by `Engine`’s `tungsten.exe` interface.

## Observations

- The prototype is deliberately not a “general big-number arithmetic” library:
  - most operations are only defined on ordinary finite `Decimal` scalars;
  - towers are carried structurally and only evaluated via explicit, guarded helpers.
- The motivating MathOverflow example is treated as a first-class acceptance target:
  - a pure “range-only” representation cannot recover the `2811012357389...` tail, but
    the perturbation-propagation model can.

## Conclusions / next natural steps

- Add additional evaluation modes beyond first-order perturbation propagation:
  - higher-order truncations and/or interval bounds so the “tiny positive number” can be bounded.
- Grow the tower arithmetic surface in a dominance-aware direction:
  - arithmetic that keeps a small number of dominant terms instead of a single landmark+tail.
