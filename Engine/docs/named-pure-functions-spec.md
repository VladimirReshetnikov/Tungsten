# Named Pure Functions in Tungsten

- Status: Draft implementation specification for kernel-free pure-function scoping and attributes
- Audience: Tungsten maintainers and contributors extending the expression subsystem
- Scope: `src/Tungsten/src/tungsten/expression.py`
- Created (UTC): 2026-04-24T16:05:00Z
- Updated (UTC): 2026-04-25T20:58:10Z
- Repository HEAD: beeccd1b652dd32394ba3e4f6128a8a3c30abf9a

## Purpose

This document specifies Tungsten's support for Wolfram named-parameter pure functions:

- `Function[x, body]`
- `Function[{x}, body]`
- `Function[{x, y}, body]`
- `x |-> body`
- `{x} |-> body`
- `{x, y} |-> body`
- `x \[Function] body`
- `{x, y} \[Function] body`

The important semantic requirement is lexical scoping with capture-avoiding renaming. The design is
based on:

- live-kernel experiments on this machine with Wolfram 14.3;
- the official `Function` documentation:
  [Function](https://reference.wolfram.com/language/ref/Function.html);
- the official scoping tutorial:
  [Modularity and the Naming of Things](https://reference.wolfram.com/language/tutorial/ModularityAndTheNamingOfThings.html?view=all).

This document is intentionally narrower than full Wolfram scoping semantics. It defines the subset
that Tungsten should implement now.

## Canonical representation

Tungsten lowers all named pure-function surface syntaxes to ordinary `Function[...]` expressions:

- `x |-> x + x` -> `Function[x, Plus[x, x]]`
- `{x, y} |-> x + y` -> `Function[List[x, y], Plus[x, y]]`
- `x \[Function] x + x` -> `Function[x, Plus[x, x]]`

This keeps the AST representation aligned with Wolfram's own head-based form and avoids a parallel
internal node kind for operator syntax.

## Supported parameter forms

For the first implementation, Tungsten accepts these parameter specifications for named pure
functions:

- a single symbol, such as `x`;
- a `List` of zero or more symbols, such as `{x}` or `{x, y}`.

Parsing is intentionally more permissive than evaluation. For example, `f[x] |-> body` is parsed as
`Function[f[x], body]`, because the Wolfram parser accepts the syntax structurally. However,
application of such a function is rejected during evaluation because `f[x]` is not a valid named
parameter specification for the Tungsten subset.

## Hold behavior

Like ordinary Wolfram `Function`, Tungsten treats the function body as held until application. This
means:

- `evaluate(Function[x, body])` returns the function expression itself;
- arguments are substituted into the held body during function application;
- only the substituted result is then passed back through ordinary Tungsten evaluation.

Tungsten now assigns evaluator semantics to the third-argument attribute form
`Function[params, body, attrs]` for attributes that affect pure-function application in the
offline evaluator:

- `HoldFirst`, `HoldRest`, `HoldAll`, and `HoldAllComplete` control which actual arguments are
  evaluated before substitution into the held body.
- `SequenceHold` and `HoldAllComplete` suppress direct `Sequence[...]` argument splicing before
  substitution.
- `Listable` threads the pure function over same-length list arguments, reusing scalar arguments.

Other attribute names are accepted and preserved structurally, but they do not yet change
Tungsten evaluation.

## Application model

For a function `Function[params, body]` applied to arguments `arg1, arg2, ...`:

1. parameters are matched positionally against arguments;
2. extra arguments are ignored;
3. each matched parameter is substituted into `body`;
4. the substituted result is then evaluated with Tungsten's normal inert evaluator.

For this initial implementation, Tungsten requires enough actual arguments to fill all named
parameters. If too few arguments are supplied, evaluation raises a `WolframEvaluationError` instead
of reproducing kernel messages.

This is slightly stricter than the live kernel for named functions, but it matches Tungsten's
existing treatment of missing positional `Slot` arguments.

For `Function[Null, body]` and `Function[Null, body, attrs]`, Tungsten uses the positional-slot
application model rather than treating `Null` as a named parameter. This mirrors Wolfram's explicit
parameter-placeholder form for functions whose body refers to `#`, `#n`, `#name`, `##`, and `##n`.

## Lexical scoping and shadowing

Named function parameters are local binders. They shadow outer substitutions with the same textual
name.

Examples from the live kernel:

- `(x |-> x |-> x)[a]` -> `Function[x, x]`
- `(x |-> x |-> y)[y]` -> `Function[x, y]`
- `(x |-> x |-> x[y])[y]` -> `Function[x, x[y]]`

The rule is:

- when substitution enters `Function[innerParams, innerBody]`, any outer substitution whose key is
  bound by `innerParams` is removed before descending into `innerBody`.

## Capture-avoiding renaming

### Required behavior

The live kernel shows the key rule quoted in the Wolfram scoping tutorial:

- named formal parameters are renamed whenever the body of the inner function is modified by the
  action of another pure function.

This rule is intentionally broader than minimal capture avoidance. Tungsten should match that
behavior.

### Renaming trigger

When an outer named pure function substitutes into a nested named pure function:

- compute the recursive substitution of the inner body using the outer substitutions that are not
  shadowed by the inner parameter list;
- if that recursive substitution does not change the inner body at all, keep the inner parameters
  unchanged;
- if that recursive substitution changes the inner body in any way, alpha-rename all parameters of
  that inner function before producing the final result.

Important consequence:

- renaming is not limited to parameters that actually collide with free variables in substituted
  arguments;
- if one part of the inner body changes, every parameter in the inner parameter list is renamed.

### Examples that must rename

Live-kernel results:

- `(x |-> y |-> x[y])[y]` -> `Function[y$, y[y$]]`
- `(x |-> y |-> x)[a]` -> `Function[y$, a]`
- `(x |-> y |-> f[x])[a]` -> `Function[y$, f[a]]`
- `(x |-> {y, z} |-> f[x, y, z])[a]` -> `Function[{y$, z$}, f[a, y$, z$]]`
- `(x |-> y |-> z |-> {x, y, z})[y]` -> `Function[y$, Function[z$, {y, y$, z$}]]`

### Examples that must not rename

Live-kernel results:

- `(x |-> y |-> y)[a]` -> `Function[y, y]`
- `(x |-> y |-> f[y])[a]` -> `Function[y, f[y]]`
- `(x |-> {y, z} |-> f[y, z])[a]` -> `Function[{y, z}, f[y, z]]`

These show that the trigger is "body changed", not "inner function exists".

## Precise substitution algorithm

For Tungsten's current subset, application of a named pure function should use this algorithm:

1. Normalize the parameter specification to an ordered list of symbol names.
2. Build a substitution map from parameter names to supplied arguments.
3. Apply a recursive substitution routine to the held body.
4. The recursive substitution routine behaves as follows:

   1. At a free symbol occurrence, replace the symbol if its name appears in the substitution map.
   2. At atoms other than symbols, leave the expression unchanged.
   3. At general non-`Function` calls, recursively substitute into the head and arguments.
   4. At a nested named pure function:

      1. Determine its own parameter list.
      2. Remove shadowed entries from the incoming substitution map.
      3. Recursively test whether the inner body changes under that reduced substitution map.
      4. If the inner body does not change, return the inner function unchanged.
      5. If the inner body changes:

         1. generate a fresh symbol for every parameter in the inner parameter list;
         2. rename bound occurrences of those parameters throughout the inner body;
         3. recursively apply the reduced outer substitution to that renamed body;
         4. rebuild the inner function using the fresh parameter list.

5. Evaluate the fully substituted result with Tungsten's ordinary evaluator.

## Fresh name generation

Tungsten should generate fresh names in Wolfram-style `$` form:

- prefer `x$`;
- if `x$` is already in use, try `x$1`, `x$2`, and so on.

Fresh names must avoid collision with:

- symbols already present in the relevant function body;
- symbols appearing in substituted argument expressions;
- symbols that are already reserved by earlier renamings in the same application.

Exact kernel serial-number behavior is not required. Tungsten only needs stable, collision-free,
Wolfram-shaped fresh names.

## Bound-occurrence renaming

When renaming a current function parameter `x` to `x$`, only occurrences bound by that function are
renamed.

That means:

- occurrences in the current function body are renamed;
- occurrences inside deeper named functions are renamed only if those deeper functions do not bind
  the same name themselves;
- the parameter declarations of deeper functions are not rewritten unless those deeper functions are
  independently being renamed by the algorithm above.

This rule is what makes the following work correctly:

- original: `(x |-> y |-> x[y])[y]`
- rename inner binder first: `Function[x, Function[y$, x[y$]]]`
- then substitute `x -> y`: `Function[y$, y[y$]]`

If Tungsten substituted first and renamed later by raw textual replacement, it would incorrectly
rename both `y` occurrences.

## Interaction with positional pure functions

Positional pure functions such as `body &` and `Function[body]` do not bind named symbols. Outer
named-parameter substitution should therefore descend into their bodies normally.

Example target behavior:

- `Function[x, # + x &][a]` -> `Function[Plus[Slot[1], a]]`

The converse is different: existing positional-slot substitution must continue to treat nested
positional pure functions as scope boundaries for `Slot` references.

## Deliberate boundaries for this milestone

This implementation does not attempt to reproduce every Wolfram scoping construct. In particular:

- no named arguments;
- no interaction-specific renaming across rules, pattern names, `With`, `Module`, or other scoping
  constructs beyond ordinary recursive traversal;
- no mutable attribute registry or evaluator-wide attribute semantics beyond the pure-function
  application subset described above. Tungsten does have a read-only Wolfram 14.3
  <code>System`</code> attribute snapshot for `Attributes`, `Names`, and `NameQ`;
- no attempt to mimic kernel messages exactly.

The original milestone was specifically about named pure functions and capture-avoiding
substitution. The current implementation also covers positional `SlotSequence` splicing and the
pure-function attribute subset above because those semantics share the same application boundary.

## Validation examples

These examples should be locked in as Tungsten tests:

- parse:
  - `x |-> x + x` -> `Function[x, Plus[x, x]]`
  - `{x, y} |-> x + y` -> `Function[List[x, y], Plus[x, y]]`
  - `x \[Function] x + x` -> `Function[x, Plus[x, x]]`
  - `##2 &` -> `Function[SlotSequence[2]]`
- evaluate:
  - `(Function[x, x + x])[a]` -> `Plus[a, a]`
  - `(f[##2] &)[a, b, c]` -> `f[b, c]`
  - `Function[Null, HoldComplete[#], HoldAll][1 + 2]` -> `HoldComplete[Plus[1, 2]]`
  - `Function[Null, f[#], Listable][{a, b}]` -> `List[f[a], f[b]]`
  - `(({x, y} |-> x + y))[a, b]` -> `Plus[a, b]`
  - `(x |-> y |-> x[y])[y]` -> `Function[y$, y[y$]]`
  - `(x |-> y |-> f[x])[a]` -> `Function[y$, f[a]]`
  - `(x |-> y |-> y)[a]` -> `Function[y, y]`
  - `(x |-> {y, z} |-> f[x, y, z])[a]` -> `Function[List[y$, z$], f[a, y$, z$]]`
  - `Function[x, # + x &][a]` -> `Function[Plus[Slot[1], a]]`
