# Redesigning Mathematica From Scratch: A Design Sketch

- Status: Opinion / design speculation (not a roadmap; not implementation guidance for Tungsten)
- Audience: Vladimir, as a thinking-partner reply to "if you designed Mathematica's core language and engine today, how would it look?"
- Scope: language and evaluation engine only. Notebook front-end, kernel/server architecture, Wolfram Knowledgebase, and compiled-numerics back-end are out of scope.
- Created (UTC): 2026-04-28T01:41:15Z
- Repository HEAD: d7b15d267848a0ad22ccd1798e790bb27f621835
- Related context:
  - [Tungsten README](../../README.md)
  - [Tungsten Architecture](../architecture.md)
  - [Tungsten Gap and Argument-Shape Review](./2026-04-27-tungsten-gap-and-shape-review.md)
  - [Tungsten Numeric Tower](../numeric-tower.md)
  - [Tungsten Pattern Matching Plan](../pattern-matching-plan.md)

## Framing

Vladimir, a fair warning before I get started: this is the kind of question where the answer
mostly tells you more about me than about Mathematica. I'll try to keep it honest about what I
think Wolfram got *right* — there is a lot of it — and reserve the criticism for the places where
the 1988 commitments still leak through and the language has accreted compatibility ballast around
them.

The exercise here is "core language and evaluation engine, no backward-compatibility constraints,
designed today." So I am not going to reinvent the front end, the wolfram-server bus, the
knowledgebase, or the compiled-numerics back-end. I am going to pretend I have a clean slate for
the **expression model, the evaluator, the binding/scoping rules, the type/attribute system, the
numeric tower, and the package/module surface** — and that I have full benefit of hindsight from
Lisp, ML, Haskell, Scala, Kotlin, OCaml, Racket, Clojure, Julia, APL/J/K, Maple, Sage, SymPy,
Coq/Lean, Idris, and the painful corners that Tungsten itself has turned up while reimplementing
Wolfram semantics by hand.

Short answer: **not completely different. The core idea is so good that throwing it away would be
silly. But the *expression* of that core idea would be substantially refined**, and the evaluator
would be much smaller, much more predictable, and much more compositional.

## What is genuinely good about Mathematica's core (and would survive)

These are the load-bearing ideas I would not change.

### 1. Term rewriting as the *universal* evaluation model

Mathematica's central insight is that essentially everything — numerical computation, symbolic
algebra, control flow, definitions, even macros and metaprogramming — can be modeled as
*pattern-driven term rewriting on s-expressions*. Built-ins and user code use the same machinery.
This is the right substrate for a symbolic-and-numeric language, and 35+ years of practical use
across math, physics, engineering, and education has not surfaced a better one. The closest serious
competitor I know of is the typed-lambda-calculus-plus-rewriting hybrid in Lean / Coq, and that's
a different kind of system aimed at proof.

### 2. Homoiconicity through `H[a, b, c]`

Every expression has a head and a (possibly empty) sequence of arguments. Programs and data are
the same thing. `Hold[expr]` is a coherent meta-language move; you can write `f[Hold[g[x]]]` and
*see* the structure. This is Lisp-grade and I would keep it without flinching.

### 3. Patterns as a *first-class language* for transformation

`x_Integer`, `_?Positive`, `___`, `OptionsPattern[]`, `Except[...]`, `Verbatim[...]`,
`HoldPattern[...]`, named alternatives, structural conditions via `/;`, and the postorder /
preorder traversal model in `Cases` / `Replace` / `ReplaceAll` / `ReplaceRepeated` are the most
expressive structural-matching surface I know of in any production language. Rust's `match`,
Scala's case classes, and OCaml's variants are all dramatically less expressive in the
*sequence-pattern* and *associative/commutative-pattern* dimensions. Keep it.

### 4. Notebooks as first-class computational documents

I'm explicitly excluding the front end from the redesign scope, but the *idea* — that programs
and their typeset output and their textual narrative live in one persistent document, evaluated
incrementally — is one of the great computer-science design moves of the 1980s and continues to
be underappreciated in mainstream PL design. (Jupyter is a worse, JSON-blob, mostly-string
shadow of it.)

### 5. Declarative attribute-based control of *evaluation order*

`HoldAll`, `HoldFirst`, `HoldRest`, `Listable`, `Flat`, `Orderless`, `OneIdentity`, `Protected`,
`NumericFunction`, `Constant`, `ReadProtected` — the *idea* of pinning these on the symbol rather
than threading them through call sites is excellent, even though the *menagerie* needs reform
(see below). The attribute system is what makes user-defined `Plus`-like functions plausible
without macros.

### 6. The numeric / symbolic continuum

`1/3 + 1/6 == 1/2` is exact and stays exact unless you ask for `N[]`. Real numbers carry explicit
precision metadata. `Sqrt[2]^2` simplifies to `2`. Most languages that do this do it as a library
on top of a numeric-first model and the seams show. Mathematica's "exact-by-default, inexact when
you opt in" policy is the right default for a system that is going to be used to *think with*.

### 7. The REPL with `In[n]` / `Out[n]` history

It's one of the most under-noticed parts of the surface, and Tungsten's experience reproducing it
in a kernel-free `tungsten.exe` confirms how load-bearing it is for casual scripting. Keep.

## What is broken or distorted, and would change

These are the places where I think 35 years of compatibility have left load-bearing scars.

### 1. The `Hold*` attribute zoo is evidence of a missing meta-language

`HoldAll`, `HoldFirst`, `HoldRest`, `HoldAllComplete`, `HoldComplete`, `HoldForm`, `HoldPattern`,
`Hold`, `Unevaluated`, `Evaluate`, `ReleaseHold`, `Defer` — and the surrounding folklore about
when each one is the right tool — is what Tungsten's evaluator has had to model painstakingly to
get any kind of parity. The reason the surface is this big is that **Mathematica conflates
"control evaluation order" with "talk about the syntactic shape of an expression."**

In a modern design I would split these:

- **One quote/quasi-quote primitive.** `'expr` (or some chosen syntax) produces an inert
  expression value. There is no need for half a dozen distinct hold attributes if the language has
  a clean way to talk about "the syntactic value of `expr`" vs "the result of evaluating `expr`."
  This is essentially the Scheme/Racket move, and it deflates a lot of the menagerie.
- **One *sequencing* primitive.** Today, `HoldAll` on a head means "do not evaluate any argument
  before the head sees them." That is a *strategy* concern, and it should be expressible without
  inventing nine variants. A function declares which of its parameters are evaluated by the
  evaluator and which are received quoted; everything else is library.
- **No `HoldComplete`/`HoldAllComplete` distinction.** The reason these exist is to control
  whether `Sequence` flattening, upvalue dispatch, and tracing happen. If those operations are
  themselves explicit pipeline stages instead of implicit ambient behaviors (see the evaluation
  loop point below), the meta-attribute is unnecessary.

### 2. The evaluation loop should be explicit and inspectable

Today the standard evaluation loop is described in tutorials as a long ordered list of steps —
evaluate head, apply `HoldFirst`, evaluate args, apply `Listable` threading, apply `Flat`
flattening, apply `Orderless` reordering, apply `OneIdentity`, apply `UpValues`, apply
`DownValues`, apply `SubValues`, apply built-in semantics, apply `NValues` if `N[]` is in scope —
and almost no Mathematica user can recite it correctly under pressure. Tungsten's evaluator has
the same problem, and the gap report's cross-cutting items (the options system, compound LHS,
direct value-list assignment) are basically about "the loop has too many implicit responsibilities
that should be lifted out."

I would design the loop as a small set of *named, composable* stages:

1. **Resolve** the head to a callable (symbol → definition / built-in / closure).
2. **Project** the arguments through the head's *evaluation specification* — a piece of data on
   the head that says, per parameter, whether it is evaluated, quoted, expanded as a sequence,
   or threaded.
3. **Normalize** under structural attributes — `Flat`, `Orderless`, `OneIdentity` — but as
   *explicit normal forms*, with a debug surface that shows you the result.
4. **Match** the (optionally normalized) call against the head's rule list, in a *deterministic*
   order with no hidden tie-breakers.
5. **Apply** the matched rule, producing a new expression.
6. **Continue** until a fixpoint — but the fixpoint criterion should be *explicit*, with a budget,
   so accidental infinite rewrites surface as bounded errors instead of hangs.

Each stage is a function the user can call directly. `Trace` becomes a thin shell over those
stages instead of a separate, mysteriously-implemented mechanism.

### 3. Pattern matching should be *total and predictable*

Wolfram's pattern matcher is the single most powerful piece of the language and also has the most
folklore. Repeated-bound names, nested `Verbatim`, the `f[x_, x_]` rule that everyone has to be
told, the difference between `Cases[..., patt :> rhs]` and `Cases[..., patt -> rhs]`, the question
of whether `Heads -> True` is the default for this particular head, the `Longest` / `Shortest`
greediness flips inside `StringExpression`, the `OptionsPattern` / `Default[h]` interaction —
these are not *mistakes* exactly, but they are evidence that the matcher accreted features rather
than being designed.

I would:

- **Pin down a single matching algorithm** — explicitly as AC-matching (associative-commutative
  matching) over the structural attributes, with a clear specification, complexity bounds (yes,
  AC-matching is NP-hard in the worst case; the spec should say so and offer a `MatchTimeBudget`
  rather than making the user discover this empirically), and *no implementation-defined order*.
- **One name per concept.** `_` is anonymous-blank; `x_` is named-blank; nothing else changes
  meaning based on context. Get rid of `Optional` vs `_.` vs `Default[h]` as three half-disjoint
  ways to say the same thing.
- **Make `OptionsPattern` actually *typed* against the function's option schema**, not a
  free-floating list of rules. (See the options point below.)
- **Make traversal-with-defaults explicit.** `Cases`, `Position`, `Replace`, `ReplaceAll`,
  `Map`, `MapAt` should share one `traversal` argument with one shape (`{level, heads, order,
  budget}`), not have each head inherit an idiosyncratic mix of `Heads -> ...` defaults from
  history. Tungsten's gap report flags this exact asymmetry as cross-cutting hole #1c — that's not
  a Tungsten bug, that's a faithful reproduction of the kernel.

### 4. Real lexical scoping, with an explicit fluid binder for the rare case Block solved

`Module[{x = init}, body]` is *not* lexical scoping. It is gensymming a fresh symbol `x$N` and
substituting it in the body, where `N` is a per-process counter. The result *behaves* like lexical
scoping in 95% of cases, but it leaks: the gensymmed names are real symbols, they show up in
serialization, they participate in `Names["..."]`, they break `==` between equivalent closures, and
they cost real memory.

`Block[{x = init}, body]` is *dynamic* scoping by the definition the rest of the world uses, and
the docs sometimes call it "local rebinding," which obscures rather than clarifies the issue.
Real-world code uses `Block` for two completely different reasons that should not have been
collapsed:

- *fluid let* (temporarily rebind `$RecursionLimit` for a calculation) — a legitimate dynamic
  scope use case that every serious language has under some other name (`parameterize` in Racket,
  `with` in Common Lisp);
- *evaluator hijacking* (temporarily redefine `f` to mean something else inside this expression)
  — usually a code smell, and should require an explicit, scary-looking primitive.

I would replace this with:

- **`let` and `letrec`** with real lexical scoping. Closures capture by reference. No gensym.
- **`fluid-let` (or `parameterize`)** as the explicit dynamic-scope primitive, only for symbols
  declared `Dynamic` (a one-bit attribute, not a separate scope construct), and *only* for those
  symbols. `$RecursionLimit`, `$IterationLimit`, `$ContextPath`, the random seed, and similar
  ambient parameters are explicitly `Dynamic`. Everything else is lexical, full stop.
- **No `Block` over arbitrary symbols.** If you need to redefine `f` for a region, write the
  evaluator hijack out longhand; you should be made to feel it.

### 5. A real options system, designed up front

The `OptionsPattern[] / OptionValue[] / Options[f] = {...}` system is what every Mathematica user
has to learn and what Tungsten's gap report flags as "cross-cutting hole #1: options as a service."
The reason it is awkward is that **options are bolted onto a positional-argument-only language by
convention**. Every option-taking head implements the convention slightly differently, options are
not validated against the function's declared option schema, and the type of "the options
collection" is `List[Rule]` — which means you cannot statically tell options from data.

I would design it in:

- **Keyword arguments are part of the calling convention.** A function declares its keyword
  parameters with names, types, defaults, and (optionally) validators. Calls pass keywords by name.
  No `OptionValue[opts, "Method"]` lookup boilerplate.
- **Options are validated at call time** against the declared schema, with a clear error if you
  pass an unknown keyword. (Tungsten's gap report notes that today every option-bearing head
  silently drops options it doesn't understand. That's a footgun, not a feature.)
- **`Options[f]` becomes derivable**, not a separate mutable global.

This single change deletes a surprising fraction of the language's surface area.

### 6. Compound left-hand-side assignment as a real lens / mutable-cell story

`m[[i, j]] = v`, `assoc[k] = v`, `Increment[parts[i]]`, `AppendTo[parts[i], x]` are all *parsed*
in vanilla Mathematica but require the kernel to recognize each LHS shape and rewrite it as
`m = ReplacePart[m, {i, j} -> v]` or analogous. Tungsten's gap report has this as cross-cutting
hole #3 because it's a long tail of special cases.

The cleaner design I'd reach for:

- **Persistent data structures by default** for `List`, `Association`, `SparseArray` — backed by
  RRB-trees / HAMTs — so that "rewrite" assignment is *cheap* and the implementation is uniform.
- **First-class lenses or paths.** `m[[i, j]] = v` desugars to `update(m, [i, j], v)` where
  `[i, j]` is a path value you can pass around and compose. This is what Clojure's `assoc-in` and
  Haskell's lens libraries do, and it generalizes to arbitrary nested updates without the kernel
  having to enumerate "compound LHS shapes I support."
- **Explicit mutable cells** as a separate type for the rare case where in-place mutation is
  semantically important (e.g., a hot-loop accumulator). Today `AppendTo` *looks* like mutation but
  actually rewrites. That's fine for elegance and bad for predicting performance.

### 7. Symbol contexts → real lexical packages

The `Begin["foo`Private`"]` / `End[]` context system is a 1990s solution to the "symbol namespaces"
problem and shows its age. It's textually scoped (or rather, dynamically scoped via
`$ContextPath`), there's no real import/export distinction, package boundaries are by convention,
and circular imports are a folk hazard.

I'd replace it with a conventional ML-style module system:

- A **module** is a named, lexically-scoped collection of definitions with explicit
  `export`-ed bindings. (Notebooks are modules.)
- A **package** is a directory of modules with an explicit `package.toml`-equivalent that lists
  dependencies, version, and ABI surface.
- Imports are `import foo.Bar` or `import foo.Bar as B`. No `$ContextPath`. No mutable global
  symbol table.
- Context strings, `Begin` / `End`, `BeginPackage` / `EndPackage`, `Needs`, `Get`, `Put`, `Save`
  → all dropped from the user surface. If you need to do dynamic loading at runtime, you call a
  function for it; the linker is not the user-language's primary surface.

### 8. The numeric tower, with real precision *and* unit tracking

The numeric tower is the area where I'd preserve the most existing behavior and fix the most bugs.

The good parts that survive:

- exact integers and rationals as the default;
- precision- and accuracy-marked arbitrary-precision reals;
- complex numbers as first-class atoms;
- `Sqrt[2]^2 == 2` style structural simplification of exact algebraic manipulations.

What I would change:

- **Make precision propagation a *type-level* obligation, not a folk practice.** Today
  Mathematica's bigfloat engine *mostly* tracks precision through arithmetic, but compound
  operations leak. The result is that experienced users sprinkle `SetPrecision`, `Chop`, `N[..., p]`
  defensively. A modern design declares precision as part of the value's static type and forces
  operators to propagate it explicitly — interval arithmetic semantics, but exposed honestly.
- **Distinguish `Real` (a structured type) from `MachineReal` (an unboxed `f64` type)** at the
  level of the type system, not just at the level of `MachineNumberQ`. Today Mathematica's
  one-`Real`-fits-all design is what produces the famous "I called `N[expr]` and lost ten digits
  silently" bug class.
- **Units in the core, not as `Quantity[...]` library values.** `9.81 m/s^2` should be a literal,
  compatible operations should be type-checked at parse time when possible, and dimensional
  analysis should be free. Mathematica did add `Quantity`, but it's bolted on after the fact and
  doesn't compose with `Compile`, with sparse arrays, or with most third-party packages.
- **Floating-point semantics that match IEEE-754 honestly.** Mathematica's machine-precision
  story has subtle divergences from `f64` semantics around overflow, denormals, and rounding mode
  that are mostly invisible but occasionally bite. (See `docs/cas-floating-point-shortcomings.md`
  in the parent repo, which appears to be exactly the kind of artifact this comes from.)
- **Autodiff in the core.** `Derivative[1][f]` works today symbolically, but operator-overload-
  based forward and reverse-mode AD does not exist as a primitive. In 2026 every numeric DSL has
  AD; the symbolic system has a head start and should use it.

### 9. A real type system — gradual, and over the term-rewriting model

This is the most controversial piece, so let me be specific about what I do *and don't* mean.

I do *not* mean: "make Mathematica into Haskell." Restricting symbolic computation to a Hindley-
Milner-typed core would break some of the language's most powerful idioms. `f[x_, y_, z_]` matching
heterogeneous trees is exactly what symbolic algebra wants.

I *do* mean: **gradual typing**, in the TypeScript / Typed Racket / mypy sense, layered *over* the
universal expression model.

- Every expression has a type. By default, the type is `Expr` (the top type — no constraints).
- Built-ins have *real* declared types. `Sin :: Real -> Real` (in some appropriate type algebra),
  `Plus :: List[Numeric] -> Numeric`, `Map :: (a -> b) -> List[a] -> List[b]`. The signature is
  visible to the user, queryable, and used for error messages.
- User definitions can opt in to types: `f[x_Integer, y_Integer] :: Integer := x + y`. The type
  annotation participates in dispatch.
- Pattern types (`x_Integer`, `_?Positive`, `OptionsPattern[]`) are *the same thing as* the type
  annotations — patterns are predicates, types are predicates, and the system unifies them.
- The type checker is *advisory by default*. It produces warnings the way TypeScript's
  `--noImplicitAny` does, not errors. Mathematica's culture is to write quick exploratory
  expressions; that culture has to survive.
- An **opt-in `--strict` mode** turns warnings into errors. Library code is expected to
  type-check; user notebooks are not.

The reason this is the right move is that the current "everything matches anything until it
doesn't" design produces a class of bug that is *the most common bug Mathematica users ship*: a
function defined for `_Integer` arguments silently failing to match when the caller passed a
`Real`, the `Failure` propagating through three layers of evaluation, and finally surfacing as a
mysterious `Hold[Plus[1, _, "abc"]]` head three calls down. Gradual types catch this without
giving up symbolic flexibility.

### 10. An explicit, reified effect surface

In modern Mathematica, `Print`, `Random*`, `Get`/`Put`, `Run`, network access, file I/O, and FE
control all live at the same syntactic level as `Sin[x]`. There is no static way to know whether
calling `f[x]` will write to disk. The language is effectively unrestricted-IO.

I would adopt a lightweight *effect tagging* discipline:

- Every built-in declares its effects: `Pure`, `Random`, `IO`, `Network`, `Mutates[g]`,
  `FrontEnd`.
- Effects propagate up through the type system (a function that calls anything with effect `e`
  has effect `e`).
- A few key combinators take effect-bound arguments (`Cases`, `Map`, parallel constructs) and
  refuse `IO`-effected callbacks unless the user explicitly opts in.
- `Random*` becomes pure given an explicit seed value passed in (and `SeedRandom` is the explicit
  way to reify the seed). This is the Haskell move and it makes parallel Monte Carlo *predictable*
  rather than something you have to babysit with `BlockRandom`.

This is not a full Koka/Eff-style algebraic-effects system — that is too heavy for the symbolic /
exploratory culture Mathematica targets. But annotation + propagation + a few enforcement points
is enough to remove the worst footguns.

## What I would *not* change (defending some Mathematica choices)

It is easy to throw out the bathwater. A few places where I think Wolfram got it right and a
modern design should resist the temptation to "improve":

### 1. Implicit one-shot transformation rules

`expr /. x -> 2` is one of the friendliest substitution surfaces in any language. Some of the
*proposed* improvements (typed substitutions, capture-avoiding by default, hygiene) would make the
common case heavier without buying enough. The right move is to keep `/.` as it is and add
*opt-in* hygienic substitution via a `safe` modifier.

### 2. Orderless / Listable / Flat / OneIdentity as overloading mechanism

Designers from typed-FP traditions look at `Listable` and reach for typeclasses. Don't. `Listable`
is an absurdly cheap way to get vectorized arithmetic without committing to a typeclass hierarchy,
and it composes with `Hold*` and patterns in ways no typeclass design I've seen reproduces. Keep
the *attribute* model; just lift it (per the loop-stages reform) so the user can see when each
attribute kicked in.

### 3. The "no explicit returns, last expression wins" rule

`f[x_] := ( a = x^2; a + 1 )` is fine. Forcing every function to use a `return` keyword would cost
brevity in interactive / exploratory work without buying clarity in larger code, where
`CompoundExpression` is rare anyway.

### 4. `///` and `//` as composition / postfix-application

`expr // f` and `f /@ list` are *better* than the equivalents in Haskell and Clojure for
interactive use because they read in the order the user thinks. Keep them. (Maybe rationalize the
operator precedence table — it has too many levels for anyone to memorize — but that's polish.)

### 5. Notebooks as the default authoring surface

Already covered above. The rest of the world is still catching up; do not abandon it.

### 6. The exact-by-default numeric culture

Mathematica's choice that `1/3` is exact and `0.333333333` is approximate is the right default for
a language used for *thinking*. Most modern numeric DSLs default to floating-point and force users
into a third-party `Rational` library to recover sanity. Don't do that.

## A concrete sketch of the redesigned core

Below, an outline of the resulting language. Names are placeholders; pretend they are a tasteful
choice.

### Expression model

```
Expr ::= Atom
       | Application(head: Expr, args: Vector[Expr], kwargs: Map[Symbol, Expr])
Atom ::= Symbol
       | Integer            -- arbitrary-size
       | Rational           -- normalized
       | Real(value, prec)  -- machine or arbitrary, with precision in the type
       | MachineReal        -- distinct unboxed type
       | Complex(re, im)
       | String             -- with explicit Unicode normalization
       | ByteArray
       | Boolean            -- distinct, not just True / False symbols
       | Quote(Expr)        -- the single quotation primitive
       | Closure(env, params, body, effects)
       | Quantity(value, units)
```

`kwargs` makes keyword arguments part of the calling convention from day one, which kills the
options-system kludge. `Quote` is the single quotation primitive that replaces the entire
`Hold*` / `Unevaluated` / `HoldComplete` family.

### Evaluator

A single function `eval(env, expr)` consisting of explicit pipeline stages, all individually
callable:

```
eval(env, expr):
    head, projected_args, projected_kwargs = project(env, expr)
    normalized = normalize(env, head, projected_args)
    rule, bindings           = match(env, head, normalized, projected_kwargs)
    return apply(env, rule, bindings)
```

`project` consults the head's *evaluation specification*, not a dozen `Hold*` attribute flags.
`normalize` runs structural attributes (`Flat`, `Orderless`, `OneIdentity`) deterministically and
once. `match` is AC-matching with a published algorithm and an explicit budget. `apply` reduces
the matched RHS in the captured environment.

The evaluation loop iterates `eval` to a fixpoint with an *explicit, configurable* budget, and the
budget exhaustion produces a structured `EvaluationBudgetExceeded[expr, budget, trace]` value, not
a hang.

### Definitions

One uniform definitional form:

```
def f(x: Integer, y: Integer) -> Integer:
    x + y
```

with desugarings to the rule-rewriting representation. Pattern-bearing rules:

```
rule MyHead[x_Integer, y_Integer] -> x + y
rule MyHead[x_, y_]              -> "fallback"
```

are direct sugar for `f`'s downvalue list. `SetDelayed` (`:=`) becomes the *only* form (today's
`Set` is a footgun in 90% of the cases people reach for it; make `=` the eager-evaluation form
for `let`, not for definitions). `UpValues`, `SubValues`, `NValues` become explicit, named
attachments to a definition rather than separate global tables.

### Modules

```
module Foo.Bar:
    import Foo.Baz as Baz
    export myFunc, myConst

    def myConst: 42
    def myFunc(x): Baz.helper(x) + myConst
```

Strict lexical scope. `import` is the only cross-module visibility primitive. There is no
`$ContextPath`. There is no `Begin`/`End`. Notebooks are modules.

### Scoping

```
let x = 1 in expr               -- non-recursive lexical
letrec f = ... in expr          -- recursive lexical
fluid x = v in expr             -- explicit dynamic, only for Dynamic-tagged symbols
```

That is all. No `Module` (gensym-based pseudo-lexical), no `Block` (silent dynamic), no `With`
(capture-avoiding macro that confuses everyone the first time).

### Patterns

The pattern language is the same as today's, with these reforms:

- one canonical name per concept (`_` blank, `__` blank-sequence, `___` null-blank-sequence,
  `x_` named-blank, `x_Type` typed-named-blank, `_?pred` predicate-blank, `_(\Pi expr)` test-blank,
  `Alternatives` for `|`, `Except`, `Verbatim`, `HoldPattern` — but not `Optional` *and* `_.`
  *and* `Default[h]`; pick one);
- type predicates are part of the type system, so `x_Integer` and the type annotation
  `x: Integer` resolve through the same predicate;
- the matching algorithm is published as AC-matching with an explicit budget;
- `OptionsPattern[]` is replaced by keyword-argument matching against the declared option schema.

### Numeric semantics

- `Integer`, `Rational` exact and unbounded.
- `Real(p)` arbitrary-precision with precision `p` part of the type. Operations propagate `p`
  according to interval semantics, with the result's precision computed from inputs.
- `MachineReal` distinct from `Real` in the type system, exact `f64` semantics, no precision
  metadata.
- `Complex` parameterized by component type (`Complex[Integer]`, `Complex[Real(p)]`,
  `Complex[MachineReal]`).
- `Quantity[value, units]` is an atom; the unit algebra is part of the type system.
- Autodiff via `forward` and `reverse` derivative operators in the core.

### Effects

- Every symbol declares effects: `Pure`, `Random`, `IO`, `Network`, `Mutates`, `FrontEnd`.
- The type checker propagates them.
- `parallel`, `Map`, `Cases`, `Replace` reject impure callbacks unless explicitly opted in.

## Honest counterfactuals

A few places where my redesign is *worse* than vanilla Mathematica in some dimension, and I should
own that:

1. **Gradual types add ceremony.** A user who just wants to type `x = 1; x + 1` doesn't want to
   think about `x: Integer`. Defaulting types to `Expr` and treating annotations as advisory
   recovers most of this, but a fraction of the "fluent on the first day" feel is lost. The
   tradeoff has to be that the *uncluttered* path stays uncluttered; the type machinery is opt-in.

2. **Real lexical scoping breaks `Block[]` cleverness that was actually load-bearing.** A few
   important Mathematica idioms (overriding `Print` for the duration of a calculation, fluidly
   redefining `$RecursionLimit`) are easier in the `Block` model than in `fluid-let`. The new
   design would require those use cases to declare their target as `Dynamic`. Cleaner, but
   migrating the existing corpus would be painful — which the no-backward-compatibility framing of
   the question lets us ignore, but a real product launch could not.

3. **Persistent data structures change the performance model.** `AppendTo[lst, x]` is O(n) today
   because `lst` is rewritten. Persistent vectors would make it O(log n) amortized, *but* the
   constant factors are larger, and a tight loop that builds a list of a million machine-reals is
   measurably slower than a Python `list.append` even with persistent structures. The right answer
   is "expose mutable cells when the user asks for them," but the cliff is real.

4. **Dropping `Block` over arbitrary symbols breaks meta-programming patterns.** Some advanced
   Mathematica code uses `Block[{f}, ...]` as a deliberate "scoped redefinition for a region"
   tool. Forcing this to be ugly is intentional, but loses some expressive power.

5. **Effect typing without a full algebraic-effects system is a half-measure.** A real effect
   discipline (Koka, Eff, or even Haskell's `IO`) would be more principled. Stopping at "tag and
   propagate, with a few enforcement points" is a deliberate compromise to keep the exploratory
   feel — but a reviewer who has lived with full effect systems will find it underbaked.

## Pragmatics: how this would land

This is moot under the no-backward-compatibility framing of the question, but worth saying out loud
because the *interesting* design tension in any "if I built it again" exercise is the migration
question.

If I were building this as a real product:

- I would ship the new core with a **Wolfram-compatibility front end** — a parser that reads the
  current InputForm, an attribute-translation table that maps `HoldAll` etc. to the new evaluation
  spec, and a stdlib shim that provides `Block`, `Module`, `OptionsPattern`, etc. as library
  layers over the new primitives.
- Notebooks would be readable, with the evaluation results sometimes diverging where the new
  semantics is incompatible. The diff would surface as warnings, not errors.
- Tungsten's experience reproducing Wolfram semantics from scratch is *exactly* the kind of test
  bed for that compatibility story: every place where Tungsten today has a "we deliberately
  diverge from the kernel here" comment is a place where the new design has an opportunity to
  pick a cleaner answer without a real-world install base shouting.

## What this exercise told me about Tungsten

Three things, that are not exactly "design recommendations" but are worth flagging because they
fall out of taking the redesign question seriously:

1. **Tungsten's `expression_evaluator.py` dispatch table is shaped like the old loop, not the
   redesigned one.** That is correct for a Wolfram-faithful tool. But if at any point the project
   wants a "Tungsten as a teaching language" branch — a kernel-free dialect that demonstrates what
   the language *could* be — the loop-stage refactor is the obvious starting point.

2. **The cross-cutting items in the gap report (options system, compound LHS, value-list
   assignment, pattern operator-form asymmetry) are exactly the items a redesign would *delete*
   rather than *implement*.** That is a useful framing for anyone deciding whether to invest in
   filling those gaps Wolfram-faithfully or to cap them with "Tungsten implements the subset that
   maps cleanly to a modern language; the rest is documented as out of scope."

3. **The numeric tower work in `expression_arithmetic.py` is closer to the redesign than the rest
   of the evaluator is.** The precision/accuracy doc reads like someone who has been forced by
   reimplementation to make a coherent semantic model, and the result is a more honest design
   than the kernel's own behavior in places.

## Summary

The core idea — pattern-driven term rewriting on s-expressions, with declarative attributes,
exact-by-default numerics, and notebooks as the authoring surface — is one of the great PL design
moves of the late 20th century, and a 2026 redesign should preserve it.

The *expression* of that idea — `HoldAll` zoo, `Block`/`Module`/`With` triplet, options as
convention rather than calling convention, compound LHS as kernel-special-cased rewrites, no real
type system, no effect tracking, gensym-based pseudo-lexical scoping, mutable global symbol table
masquerading as packages — is where 35 years of compatibility shows. A redesign would refine all
of those substantially.

The result would not be radically different to a Mathematica user on day one. It would feel like
"the same language, but every weird footgun you used to teach a new user about has been fixed."
That is, I think, the right kind of redesign for a system this load-bearing.

The result would be radically different to a *Mathematica implementer*. The evaluator would be
much smaller, much more inspectable, and much easier to be confident about — which is, not
coincidentally, exactly the property Tungsten has been chasing for the kernel-free subset.
