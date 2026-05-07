# Prototype Corpus Overview

Created (UTC): 2026-04-28T00:44:03Z

Repository HEAD: 2689dffeee9f9c16d9e3cbe4bfd55ef011ecdf82

This document maps the prior-art reference projects under
[`src/Tungsten/Nummy/prior-art/`](../../prior-art/) into a single design picture. The
short version is that the corpus contains two related but distinct lineages:

- Practical power-tower and hyperoperation number libraries, mostly from
  incremental-game and googology contexts.
- Direct symmetric level-index arithmetic (SLI) experiments, where the
  representation is intended to model the SLI family rather than merely reach
  enormous values.

Those lineages overlap because both use the same core escape hatch: once a
number is too large or too small for ordinary floating point, represent it by
logging its magnitude and recording how many logarithms have been applied. They
diverge in the details that matter for Nummy: base-10 display convenience versus
mathematical SLI structure, fixed versus extensible tower height, explicit versus
implicit treatment of reciprocals, and whether arithmetic is a numerically
specified model or a pragmatic dominance heuristic.

## Executive Map

| Prototype | Representation | Main strength | Relation to SLI |
| --- | --- | --- | --- |
| [`break_infinity.js`](../../prior-art/break_infinity.js/) | Decimal scientific notation: `mantissa * 10^exponent`, with a very large integer exponent range. | Fast drop-in `Decimal`-like arithmetic for incremental games above double range. | Not SLI. It is the one-logarithm gateway: useful for ordinary huge decimals, but it has no general level/index ladder. |
| [`hypercalc`](../../prior-art/hypercalc/) | Power-tower pair/triple: a PT count plus a floating value, with uncertainty in the Perl implementation. | The clearest ancestor of practical base-10 tower arithmetic; broad calculator behavior and notation. | SLI-adjacent. `pt` is a base-10 level count, and `log10`/`pow10` decrement/increment that level, but it is not a symmetric SLI implementation. |
| [`break_eternity.js`](../../prior-art/break_eternity.js/) | `sign`, integer `layer`, and `mag`: layer 0 is ordinary `sign * mag`; positive layers are repeated base-10 exponentiation. Negative `mag` at nonzero layers represents reciprocals. | The most polished practical tower library in the corpus; supports tetration/slog/pentation-scale operations with aggressive normalization. | Closest practical base-10 analogue to SLI, but not identical: its layers are decimal power-tower layers and its reciprocal side is encoded through negative magnitude rather than a separate reciprocal bit. |
| [`OmegaNum.js`](../../prior-art/OmegaNum.js/) | `sign` plus an array of hyperoperation counters, normalized upward when an entry exceeds `Number.MAX_SAFE_INTEGER`. | Goes beyond fixed layer/magnitude systems toward Knuth-arrow and `f_omega`-style scales. | Beyond ordinary SLI. It generalizes the tower idea into a hyperoperation stack rather than a finite level-index arithmetic model. |
| [`GSLI`](../../prior-art/GSLI/) | Generalized SLI with level/index/sign encoded into one `double` in the public `gsli_double` type; lower-level `gsli_rep` exposes the normalized representation. | Most production-like direct SLI kernel: ordinary values are preserved well, and huge/tiny values use generalized SLI transforms. | Directly in the SLI family. This is the strongest implementation reference for Nummy if the goal is an SLI number type. |
| [`level-index-simulator`](../../prior-art/level-index-simulator/) | MATLAB `sli` class with configurable `level_bits`, `index_bits`, `sign`, `reciprocal`, `level`, `index`, and reconstructed `value`. | Experimental SLI laboratory for custom precision, bit allocation, rounding, and accuracy studies. | Direct SLI simulator. Its explicit reciprocal bit and quantized level/index fields are especially useful for reasoning about formats. |
| [`expol.py`](../../prior-art/expol.py/) | Python exponent-list/scientific notation pair `[mantissa, exponent]`, with exploratory formatting and tetration helpers. | Readable experiment in extended scientific notation and notation formatting. | Mostly pre-SLI. It resembles `break_infinity.js` more than SLI; the README also calls out correctness limits. |
| [`python/break_eternity.py`](../../prior-art/python/break_eternity.py) | Compact Python list form: sign bit, magnitude/log magnitude, and optional layer. | Small, readable sketch of layer/magnitude arithmetic. | Useful as a pedagogical bridge from `break_infinity` to `break_eternity`-style layers, not a full SLI model. |
| [`python/hypernums.py`](../../prior-art/python/hypernums.py) | `Hypernum` with `pt`, `mantissa`, and decimal exponent, after Hypercalc. | Readable Python version of the Hypercalc PT model. | Good reference for the PT side of the SLI-adjacent lineage. It is easier to study than the full Perl calculator. |

## The Shared Ladder

The prototypes can be arranged by how many logarithmic escape hatches they add.

1. Ordinary floating point has no escape hatch. It stores an exponent, but the
   exponent itself is bounded by the hardware format.
2. `break_infinity.js` externalizes that exponent into a JavaScript number and
   stores `mantissa * 10^exponent`. Addition aligns exponents when the gap is
   small and otherwise returns the dominant addend. Multiplication adds
   exponents. This is extended scientific notation, not level-index arithmetic.
3. Hypercalc and `python/hypernums.py` add a PT counter. A value with `pt = 0`
   is ordinary scientific notation; `pt = 1` represents something like
   `10^value`; `pt = 2` represents `10^(10^value)`, and so on. `log10`
   decrements `pt`; `pow10` increments it.
4. `break_eternity.js` turns that PT idea into a compact normalized
   `sign/layer/mag` API. Its `layer` is the PT count, and `mag` is the current
   logarithmic payload. It keeps `mag` inside a safe range by moving values up
   and down between layers.
5. `OmegaNum.js` abandons fixed-height tower layers and uses an array where
   higher entries represent higher hyperoperation ranks. A large enough entry
   is promoted to the next rank, so the representation can talk about values far
   above any fixed `sign/layer/mag` tower model.
6. `GSLI` and `level-index-simulator` are the SLI branch. They also use a
   level plus an index, but the point is not just decimal display or game
   notation. The representation is a numerical format with sign, reciprocal
   symmetry, normalized index ranges, rounding behavior, and operations defined
   around the SLI transform.

This is why the same operations keep reappearing. Logs lower the level, exponent
functions raise it, multiplication can often be reduced to addition in log
space, and addition becomes either a `log(1 + exp(delta))` calculation near the
same scale or a dominance decision when the operands are too far apart.

## Relation to Symmetric Level-Index Arithmetic

SLI represents a real number by separating ordinary sign from magnitude and then
representing the magnitude with a level and an index. At level 0, the index is
near ordinary arithmetic. At higher levels, the represented magnitude is reached
by repeatedly applying an exponential-like map; logarithms move back down the
levels. The symmetric part is the important small-value counterpart: the format
must also represent tiny positive magnitudes, usually through a reciprocal side
or negative/signed level convention, so overflow and underflow are treated as
dual phenomena.

The direct SLI prototypes are:

- `GSLI`, which implements generalized SLI in C++ and packs the normalized
  representation into a single double-valued payload for `gsli_double`.
- `level-index-simulator`, which exposes the SLI components directly as MATLAB
  fields and quantizes them according to configurable bit counts.

The power-tower prototypes are related but should not be read as SLI
implementations:

- Hypercalc, `break_eternity.js`, and `python/hypernums.py` use base-10 tower
  levels because that is natural for decimal notation and calculator display.
- `break_eternity.js` has a symmetric-flavored reciprocal encoding, but its
  "small side" is a negative `mag` at nonzero layer rather than an explicit
  reciprocal field.
- These libraries intentionally use dominance shortcuts for operations at high
  layers. That is right for many game/calculator workloads, but it is different
  from specifying a numerical SLI format with explicit rounding semantics.

`break_infinity.js` is still farther away: it gives Nummy a good example of
fast extended scientific notation, but its representation has no level ladder.
`OmegaNum.js` goes the other direction: it surpasses fixed level-index models by
adding hyperoperation ranks, which is useful for understanding the edge of the
design space but not a direct SLI kernel.

## Comparing Approaches

### Representation Shape

`break_infinity.js` is the simplest. It keeps a decimal mantissa and an integer
exponent, normalized so the mantissa is near `[1, 10)`. The exponent limit is
chosen around the largest integer range that JavaScript can handle precisely
enough for the library's purposes.

Hypercalc adds one structural field: `pt`, the number of base-10 logarithms that
separate the stored value from the represented value. The Perl implementation
also tracks uncertainty, which is unusual and valuable: it acknowledges that
when almost all arithmetic is in logarithmic space, propagated uncertainty is
part of the model rather than a display afterthought.

`break_eternity.js` is the compact layer/magnitude form:

```text
sign * 10^10^...^mag
```

where the count of 10s is `layer`. It normalizes by promoting huge `mag` values
to a higher layer and demoting small layer values back down when possible. This
is the most useful source for API ergonomics, notation behavior, and practical
game arithmetic.

`OmegaNum.js` stores an array. Element 0 is the bottom payload; element 1 acts
like a tower/layer count; higher elements count higher arrow ranks. The
normalizer carries overly large entries upward. That makes the representation
qualitatively different from SLI: SLI fixes the kind of transform and moves
between levels, while OmegaNum extends the kind of transform itself.

`GSLI` and `level-index-simulator` expose the SLI design directly. GSLI hides
most of it behind a `double` encoding in its main type; the simulator keeps the
fields visible and quantized for experiments.

### Arithmetic Strategy

All projects share the same addition problem: if two values are far apart, the
smaller value often cannot affect the larger one at the stored precision.

- `break_infinity.js` aligns exponents only when their gap is small enough to
  matter.
- Hypercalc and `hypernums.py` compute same-scale sums through logarithmic
  identities such as `log10(10^a + 10^b)`, and otherwise return the dominant
  term.
- `break_eternity.js` treats layer 2 and above as dominance territory for many
  ordinary operations, with special handling for layer 0 and layer 1.
- `OmegaNum.js` uses the same broad idea, but comparisons and arithmetic also
  have to account for array length and higher arrow ranks.
- GSLI has the most SLI-specific implementation: operations move through
  `log_abs`, `exp`, normalized representatives, and dominance thresholds
  derived from the generalized transform.
- `level-index-simulator` makes these choices inspectable by letting
  experiments choose level/index bit widths and by rounding after operations.

Multiplication, division, powers, roots, and exponentials are easier to express
once a logarithmic representation exists. A recurring pattern is:

```text
a * b   -> exp(log(a) + log(b))
a / b   -> exp(log(a) - log(b))
a ^ b   -> exp(b * log(a))
pow10 x -> raise level
log10 x -> lower level
```

The difference is not the identity; it is the boundary behavior, the base, the
normalization thresholds, and the rounding model.

### Small Values And Sign

SLI cares about small positive values as much as large positive values. That is
why `level-index-simulator` has both `sign` and `reciprocal`, and why GSLI has
explicit machinery for negative levels or reciprocal-like encodings.

The game/googology libraries are less uniform:

- `break_infinity.js` can represent tiny decimals by using negative exponents,
  but only within its one-exponent model.
- Hypercalc supports negative represented values by sign, but its PT structure
  is primarily a large-magnitude representation.
- `break_eternity.js` uses negative `mag` at nonzero `layer` to represent
  reciprocals, which is compact and practical but is not the same as a separate
  reciprocal bit.
- `OmegaNum.js` has a sign field, but its emphasis is positive huge-number
  growth through hyperoperations.

For Nummy, this argues for keeping sign and reciprocal/small-side semantics
first-class in any SLI-oriented design, even if decimal tower notation is also
supported at the API boundary.

### Precision, Error, And Rounding

The prototypes make different bets:

- `break_infinity.js` and `break_eternity.js` optimize for speed and stable
  gameplay-scale behavior, not strict correctly rounded arithmetic.
- Hypercalc's uncertainty field is a reminder that a useful calculator can
  expose approximation explicitly.
- `OmegaNum.js` prioritizes range and notation over conventional precision.
- `GSLI` treats representation limits and dominance thresholds as part of the
  numerical design.
- `level-index-simulator` is the best place to study quantization because
  `level_bits` and `index_bits` are explicit.
- `expol.py` and the loose Python ports are useful for reading and prototyping,
  but they should not be treated as correctness authorities.

### Licensing And Reuse

The corpus is a reference set, not a single codebase to merge wholesale.
`break_infinity.js`, `break_eternity.js`, and `OmegaNum.js` are MIT-licensed.
`level-index-simulator` is BSD 2-Clause. `GSLI`, Hypercalc, and `expol.py` are
GPL-family or GPL-bearing snapshots. That makes the permissive projects easier
to reuse directly, while the GPL projects are better treated as design and
behavior references unless Nummy intentionally adopts compatible licensing for
derived code.

## Project Notes

### break_infinity.js

This is the baseline extended-decimal library. It is valuable because it shows
how far a simple mantissa/exponent pair can go while preserving a familiar
`Decimal` API. It also demonstrates the natural first approximation for
addition: if the exponent difference exceeds the significant-digit budget,
return the larger operand.

For Nummy, it is a useful lower layer or fallback path, but it should not be
mistaken for SLI. It cannot represent "the number after repeatedly applying
exponential maps" except by storing a single very large decimal exponent.

### Hypercalc

Hypercalc is the oldest and most conceptually central PT reference in this
directory. Its internal PT representation is exactly the idea that later game
libraries streamlined: represent `10^(10^(... value ...))` by storing how many
10-based exponentiations have been peeled off. The Perl version also carries an
uncertainty value through many operations.

Its relevance to SLI is historical and conceptual. It is not symmetric
level-index arithmetic, but it explains why layer-counted base-10 systems feel
natural: decimal calculators, notation, and `log10`/`pow10` transitions line up.

### break_eternity.js

This is the most important practical power-tower library in the corpus. Its
`sign/layer/mag` representation is small, normalizable, and battle-tested in the
kind of workload where huge-number libraries actually get used interactively.
Layer 0 remains an ordinary magnitude; positive layers turn that magnitude into
a decimal power-tower payload. It includes not only ordinary arithmetic but
tetration, slog, layer addition, and pentation-scale helpers.

For Nummy, `break_eternity.js` is the best guide to ergonomics and pragmatic
operation behavior for tower numbers. The caution is that it bakes in base-10
layer semantics and approximation choices. If Nummy's core is meant to be SLI,
the representation should be specified independently, then compatibility
formatters or adapters can expose `break_eternity`-style notation.

### OmegaNum.js

OmegaNum starts from the same broad problem as `break_eternity.js` and then
keeps climbing. Its array representation promotes large counters into higher
hyperoperation ranks and supports arrow notation with a configurable maximum
arrow count. That moves it into the googology side of the design space.

For Nummy, OmegaNum is a useful reminder that "bigger than tetration" is a
different product requirement from "better SLI arithmetic." It may inspire
notation or upper-range experiments, but it is not the core reference for SLI
normalization, reciprocal symmetry, or finite-format rounding.

### GSLI

GSLI is the direct C++ reference for generalized SLI. It has two layers of
interest: a representation type that exposes level/index/sign concepts, and a
`gsli_double` interface that packs those concepts into one `double` payload. It
also deliberately preserves ordinary values in a conventional range before
moving into higher SLI levels.

For Nummy, this is the best implementation reference if the target is a serious
SLI number type. The important ideas are not just the formulas but the format
discipline: normalization ranges, special values, reciprocal/small-side
handling, and when high-level operations collapse to dominance.

### level-index-simulator

The MATLAB simulator is a companion to GSLI rather than a competitor. It is less
about API polish and more about studying the format. The visible `sign`,
`reciprocal`, `level`, and `index` fields make it clear what SLI stores, and the
`level_bits`/`index_bits` parameters make rounding and quantization explicit.

For Nummy, this prototype is the best reference for experiments: choose a field
allocation, run operations, inspect reconstruction error, and compare symmetric
behavior for large and tiny values.

### expol.py

`expol.py` is a Python extended-scientific-notation experiment with rich
formatting ambitions and some tetration-related helpers. The README explicitly
describes it as buggy and break-infinity-like.

For Nummy, it is useful mainly as a cautionary small prototype: extended
notation is easy to start, hard to make correct at operation boundaries, and
formatting can quickly become a large independent subsystem.

### python/break_eternity.py

This file is a compact Python sketch of a layer/magnitude library. It stores a
sign bit, a magnitude or logarithmic magnitude, and an optional layer count. It
implements the same basic moves as the larger JavaScript libraries: normalize,
compare by layer and magnitude, add by dominance or log-space identities, and
implement powers through logs.

For Nummy, its value is readability. It is a useful teaching model for the
transition from one-exponent arithmetic to tower layers.

### python/hypernums.py

`hypernums.py` is a Python `Hypernum` class explicitly modeled after Hypercalc.
It stores `pt`, `mantissa`, and decimal exponent, normalizes by promoting and
demoting PT levels, and implements a broad calculator-like API.

For Nummy, this is the easiest way to study Hypercalc's PT idea without first
absorbing the full Perl calculator. It is still a PT model, not SLI, but the code
is compact enough to be a useful reference when designing tests and examples.

## Design Takeaways For Nummy

1. Decide whether the core type is an SLI number or a tower-number API. The
   prototypes show that those designs rhyme, but the invariants are different.
2. If the core is SLI, start from `GSLI` and `level-index-simulator`, then add
   tower-style parsing/formatting as an adapter layer.
3. Preserve a high-quality ordinary-number path. GSLI's exact ordinary range and
   `break_infinity.js`'s familiar decimal behavior both point in this direction.
4. Make dominance decisions explicit. Returning the larger operand is often
   numerically reasonable, but it should be tied to documented precision or
   error semantics.
5. Keep sign and reciprocal handling first-class. A symmetric format should make
   tiny magnitudes as natural as huge magnitudes.
6. Separate representation, arithmetic, and notation. Hypercalc and `expol.py`
   show how quickly formatting and parser concerns can obscure the numerical
   core.
7. Treat OmegaNum as an upper-bound exploration. Its hyperoperation array is
   valuable context, but adopting it would change the goal from SLI arithmetic
   to googology-scale ordinal/hyperoperator arithmetic.

The practical synthesis is: Hypercalc explains the PT lineage,
`break_eternity.js` shows the polished base-10 tower API, OmegaNum shows what
happens beyond fixed towers, and GSLI plus `level-index-simulator` anchor the
actual SLI branch. Nummy can borrow notation and ergonomics from the first group
while letting the second group define the numerical core.
