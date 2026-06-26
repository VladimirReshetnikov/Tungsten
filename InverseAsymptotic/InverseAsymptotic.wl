(* ::Package:: *)

(* :Title: InverseAsymptotic *)
(* :Context: InverseAsymptotic` *)
(* :Author: Smithereens project *)
(* :Summary:
   Real-branch asymptotic reversion for functions whose local expansions are
   finite generalized power-log series.  The main target is inverse functions
   that Wolfram Language's built-in InverseFunction/Series machinery sends to a
   complex branch or refuses to invert because the expansion is not an ordinary
   SeriesData object.

   The package computes the branch x(y) selected by a real one-sided approach
   to x0.  Internally it represents expressions in the output displacement
   s = y - y0 as terms c s^a Log[s]^b, ordered asymptotically as s -> 0+.
   This is enough to handle analytic, Puiseux, irrational-power, and logarithmic
   perturbations such as

     x + x^2 (1 + Log[x])
     x + x^Sqrt[2]
     x^2 + x^3

   and many similar compositions.
*)

BeginPackage["InverseAsymptotic`"];

InverseAsymptotic::usage =
  "InverseAsymptotic[f, {x, x0}, {y, y0}] computes an asymptotic expansion \
for the real branch x(y) satisfying f[x(y)] == y near x -> x0 and y -> y0. \
The first argument can be an expression in x, a pure function, or a \
ConditionalExpression.  y0 can be Automatic, in which case it is obtained by \
Limit.  Use SeriesTermGoal -> n to request n distinct powers of y-y0.";

InverseAsymptoticData::usage =
  "InverseAsymptoticData[f, {x, x0}, {y, y0}] returns an Association containing \
the inverse expansion, normalized input expansion, retained term table, final \
residual term table, and method diagnostics.";

InverseAsymptoticTerms::usage =
  "InverseAsymptoticTerms[f, {x, x0}, {y, y0}] returns the canonical term table \
for InverseAsymptotic[f, {x, x0}, {y, y0}].  Each term is an Association with \
keys \"Power\", \"LogPower\", \"Coefficient\", and \"Term\".";

InverseAsymptoticVerify::usage =
  "InverseAsymptoticVerify[f, approx, {x, x0}, {y, y0}] checks the composition \
f[approx] - y asymptotically.  It returns an Association whose \
\"ResidualSmallerThanLastTerm\" key is True when the leading residual is smaller \
than the last retained term of approx.";

Options[InverseAsymptotic] = {
  SeriesTermGoal -> 4,
  Assumptions -> $Assumptions,
  Direction -> -1,
  "MaxIterations" -> Automatic,
  "WorkingTermGoal" -> Automatic,
  "FallbackToSystemInverse" -> True,
  "PostSimplify" -> FullSimplify
};

Options[InverseAsymptoticData] = Options[InverseAsymptotic];
Options[InverseAsymptoticTerms] = Options[InverseAsymptotic];
Options[InverseAsymptoticVerify] = Options[InverseAsymptotic];

InverseAsymptotic::badxspec =
  "Expected an input specification of the form {x, x0}, with x a symbol; got `1`.";

InverseAsymptotic::badyspec =
  "Expected an output specification of the form {y, y0}, with y a symbol; got `1`.";

InverseAsymptotic::lim =
  "Could not determine the output expansion point y0 by Limit.  Specify {y, y0} explicitly.";

InverseAsymptotic::lead =
  "The leading term `1` of the normalized function is not invertible by the current transseries method.";

InverseAsymptotic::unsupported =
  "The expression `1` is outside the finite power-log transseries fragment currently supported.";

Begin["`Private`"];

(* ---------------------------------------------------------------------- *)
(* Term ordering and canonicalization                                      *)
(* ---------------------------------------------------------------------- *)

ClearAll[
  simpleSimplify, simplifyCoefficient,
  zeroTermQ, sameScalarQ, scalarLessQ, scalarGreaterQ, sameTermScaleQ,
  termOrderLessQ, sortTerms, appendCombinedTerm, canonicalTerms,
  truncateTerms, distinctPowers, termToExpression, termsToExpression,
  termAssociations, expressionTermTable
];

simpleSimplify[expr_, ass_] :=
  Quiet@TimeConstrained[Simplify[expr, ass], 0.15, expr];

simplifyCoefficient[expr_, ass_] :=
  Quiet@TimeConstrained[Simplify[expr, ass], 0.25, expr];

zeroTermQ[c_, ass_] :=
  TrueQ[c === 0] ||
    TrueQ[Quiet@TimeConstrained[Simplify[c == 0, ass], 0.05, False]] ||
    TrueQ[Quiet@TimeConstrained[PossibleZeroQ[c], 0.05, False]];

sameScalarQ[a_, b_, ass_] :=
  TrueQ[a === b] ||
    TrueQ[Quiet@TimeConstrained[Simplify[a == b, ass], 0.05, False]] ||
    TrueQ[Quiet@TimeConstrained[PossibleZeroQ[a - b], 0.05, False]];

numericScalarQ[x_] := Quiet@NumericQ[N[x, 50]];

scalarLessQ[a_, b_, ass_] := Module[{cmp},
  If[TrueQ[a === b], Return[False]];
  cmp = Quiet@TimeConstrained[Simplify[a < b, ass], 0.05, $Failed];
  Which[
    TrueQ[cmp], True,
    TrueQ[Quiet@TimeConstrained[Simplify[a >= b, ass], 0.05, False]], False,
    numericScalarQ[a] && numericScalarQ[b], TrueQ[N[a, 50] < N[b, 50]],
    True, OrderedQ[{ToString[InputForm[a]], ToString[InputForm[b]]}]
  ]
];

scalarGreaterQ[a_, b_, ass_] := Module[{cmp},
  If[TrueQ[a === b], Return[False]];
  cmp = Quiet@TimeConstrained[Simplify[a > b, ass], 0.05, $Failed];
  Which[
    TrueQ[cmp], True,
    TrueQ[Quiet@TimeConstrained[Simplify[a <= b, ass], 0.05, False]], False,
    numericScalarQ[a] && numericScalarQ[b], TrueQ[N[a, 50] > N[b, 50]],
    True, OrderedQ[{ToString[InputForm[b]], ToString[InputForm[a]]}]
  ]
];

sameTermScaleQ[{p1_, l1_, _}, {p2_, l2_, _}, ass_] :=
  sameScalarQ[p1, p2, ass] && sameScalarQ[l1, l2, ass];

(* As s -> 0+, smaller powers dominate.  At the same power, larger Log[s]
   powers dominate in magnitude. *)
termOrderLessQ[{p1_, l1_, _}, {p2_, l2_, _}, ass_] :=
  If[sameScalarQ[p1, p2, ass],
    scalarGreaterQ[l1, l2, ass],
    scalarLessQ[p1, p2, ass]
  ];

sortTerms[terms_List, ass_] := Sort[terms, termOrderLessQ[#1, #2, ass] &];

appendCombinedTerm[acc_List, {p_, l_, c_}, ass_] := Module[
  {pos, existing, newCoeff},
  If[zeroTermQ[c, ass], Return[acc]];
  pos = FirstPosition[acc, t_ /; sameTermScaleQ[t, {p, l, c}, ass], Missing["NotFound"], {1}];
  If[MissingQ[pos],
    Append[acc, {p, l, c}],
    existing = acc[[First[pos]]];
    newCoeff = simplifyCoefficient[existing[[3]] + c, ass];
    If[zeroTermQ[newCoeff, ass],
      Delete[acc, First[pos]],
      ReplacePart[acc, First[pos] -> {existing[[1]], existing[[2]], newCoeff}]
    ]
  ]
];

canonicalTerms[terms_List, ass_] :=
  sortTerms[Fold[appendCombinedTerm[#1, #2, ass] &, {}, terms], ass];

distinctPowers[terms_List, ass_] := Module[{powers = {}, p},
  Do[
    p = term[[1]];
    If[! AnyTrue[powers, Function[q, sameScalarQ[q, p, ass]]],
      powers = Append[powers, p]
    ],
    {term, sortTerms[terms, ass]}
  ];
  powers
];

truncateTerms[terms_List, Infinity, ass_] := canonicalTerms[terms, ass];

truncateTerms[terms_List, goal_Integer?NonNegative, ass_] := Module[
  {sorted, powers = {}, out = {}, p},
  If[goal == 0, Return[{}]];
  sorted = canonicalTerms[terms, ass];
  Do[
    p = term[[1]];
    If[! AnyTrue[powers, sameScalarQ[#, p, ass] &],
      If[Length[powers] >= goal, Break[]];
      powers = Append[powers, p];
    ];
    out = Append[out, term],
    {term, sorted}
  ];
  out
];

termToExpression[{p_, l_, c_}, s_] := Module[{powerPart, logPart},
  powerPart = If[sameScalarQ[p, 0, True], 1, s^p];
  logPart = If[sameScalarQ[l, 0, True], 1, Log[s]^l];
  c powerPart logPart
];

termsToExpression[terms_List, s_] := Total[termToExpression[#, s] & /@ terms];

termAssociations[terms_List, s_] :=
  (<|"Power" -> #[[1]], "LogPower" -> #[[2]], "Coefficient" -> #[[3]],
      "Term" -> termToExpression[#, s]|> &) /@ terms;

expressionTermTable[expr_, s_, goal_, ass_] := Module[{terms},
  terms = expandExpression[expr, s, goal, ass];
  If[terms === $Failed, $Failed, termAssociations[terms, s]]
];

(* ---------------------------------------------------------------------- *)
(* Generalized power-log series arithmetic                                 *)
(* ---------------------------------------------------------------------- *)

ClearAll[
  oneSeries, scaleSeries, addSeries, negateSeries, subtractSeries,
  multiplySeries, divideByMonomial, monomialPowerSeries, powerSeries,
  logSeries, expressionHead, expandExpression, finiteBinomialDepth
];

oneSeries = {{0, 0, 1}};

scaleSeries[terms_List, c_, goal_, ass_] :=
  truncateTerms[({#[[1]], #[[2]], simplifyCoefficient[c #[[3]], ass]} &) /@ terms, goal, ass];

addSeries[series_List, goal_, ass_] := truncateTerms[Join @@ series, goal, ass];

negateSeries[terms_List, goal_, ass_] := scaleSeries[terms, -1, goal, ass];

subtractSeries[a_List, b_List, goal_, ass_] :=
  addSeries[{a, negateSeries[b, goal, ass]}, goal, ass];

multiplySeries[a_List, b_List, goal_, ass_] := Module[{raw},
  If[a === {} || b === {}, Return[{}]];
  raw = Flatten[
    Table[
      {ta[[1]] + tb[[1]], ta[[2]] + tb[[2]],
        simplifyCoefficient[ta[[3]] tb[[3]], ass]},
      {ta, a}, {tb, b}
    ],
    1
  ];
  truncateTerms[raw, goal, ass]
];

divideByMonomial[terms_List, {p0_, l0_, c0_}, goal_, ass_] :=
  truncateTerms[
    ({simpleSimplify[#[[1]] - p0, ass], simpleSimplify[#[[2]] - l0, ass],
        simplifyCoefficient[#[[3]]/c0, ass]} &) /@ terms,
    goal,
    ass
  ];

monomialPowerSeries[{p_, l_, c_}, a_, goal_, ass_] :=
  truncateTerms[{{simpleSimplify[a p, ass], simpleSimplify[a l, ass],
      simplifyCoefficient[c^a, ass]}}, goal, ass];

finiteBinomialDepth[goal_] := Which[
  goal === Infinity, 12,
  IntegerQ[goal], Max[8, 3 goal + 4],
  True, 16
];

powerSeries[terms_List, n_Integer?NonNegative, goal_, ass_] := Module[{out, k},
  If[n == 0, Return[oneSeries]];
  out = oneSeries;
  For[k = 1, k <= n, k++,
    out = multiplySeries[out, terms, goal, ass]
  ];
  out
];

powerSeries[terms_List, exponent_, goal_, ass_] := Module[
  {canonical, lead, tail, relative, binomialSum, relativePower, depth, k},
  If[terms === {}, Return[{}]];
  If[sameScalarQ[exponent, 0, ass], Return[oneSeries]];
  If[IntegerQ[exponent] && exponent > 0, Return[powerSeries[terms, exponent, goal, ass]]];

  canonical = canonicalTerms[terms, ass];
  lead = First[canonical];
  tail = Rest[canonical];
  If[tail === {},
    Return[monomialPowerSeries[lead, exponent, goal, ass]]
  ];

  relative = divideByMonomial[tail, lead, goal, ass];
  binomialSum = oneSeries;
  relativePower = oneSeries;
  depth = finiteBinomialDepth[goal];
  For[k = 1, k <= depth, k++,
    relativePower = multiplySeries[relativePower, relative, goal, ass];
    If[relativePower === {}, Break[]];
    If[addSeries[{binomialSum, relativePower}, goal, ass] === binomialSum, Break[]];
    binomialSum = addSeries[
      {binomialSum, scaleSeries[relativePower, Binomial[exponent, k], goal, ass]},
      goal,
      ass
    ];
  ];
  multiplySeries[monomialPowerSeries[lead, exponent, goal, ass], binomialSum, goal, ass]
];

logSeries[terms_List, s_, goal_, ass_] := Module[
  {canonical, lead, tail, p0, l0, c0, baseTerms = {}, relative, logTail,
    relativePower, depth, k},
  If[terms === {}, Return[$Failed]];
  canonical = canonicalTerms[terms, ass];
  lead = First[canonical];
  {p0, l0, c0} = lead;
  If[! sameScalarQ[l0, 0, ass],
    Message[InverseAsymptotic::unsupported, Log[termsToExpression[terms, s]]];
    Return[$Failed]
  ];

  If[! sameScalarQ[c0, 1, ass],
    baseTerms = Append[baseTerms, {0, 0, Log[c0]}]
  ];
  If[! sameScalarQ[p0, 0, ass],
    baseTerms = Append[baseTerms, {0, 1, p0}]
  ];

  tail = Rest[canonical];
  If[tail === {}, Return[truncateTerms[baseTerms, goal, ass]]];
  relative = divideByMonomial[tail, lead, goal, ass];
  logTail = {};
  relativePower = oneSeries;
  depth = finiteBinomialDepth[goal];
  For[k = 1, k <= depth, k++,
    relativePower = multiplySeries[relativePower, relative, goal, ass];
    If[relativePower === {}, Break[]];
    If[addSeries[{baseTerms, logTail, relativePower}, goal, ass] ===
        addSeries[{baseTerms, logTail}, goal, ass], Break[]];
    logTail = addSeries[
      {logTail, scaleSeries[relativePower, (-1)^(k + 1)/k, goal, ass]},
      goal,
      ass
    ];
  ];
  addSeries[{baseTerms, logTail}, goal, ass]
];

expressionHead[expr_] := Head[Unevaluated[expr]];

expandExpression[expr_, s_Symbol, goal_, ass_] := Module[
  {h, parts, seriesParts, result},
  Which[
    TrueQ[expr === 0], {},
    FreeQ[Unevaluated[expr], s], {{0, 0, expr}},
    TrueQ[Unevaluated[expr] === s], {{1, 0, 1}},
    MatchQ[Unevaluated[expr], Power[s, _]], {{expr[[2]], 0, 1}},
    MatchQ[Unevaluated[expr], Log[s]], {{0, 1, 1}},
    MatchQ[Unevaluated[expr], Power[Log[s], _]], {{0, expr[[2]], 1}},

    True,
      h = expressionHead[expr];
      Switch[h,
        Plus,
          parts = List @@ expr;
          seriesParts = expandExpression[#, s, goal, ass] & /@ parts;
          If[MemberQ[seriesParts, $Failed], $Failed, addSeries[seriesParts, goal, ass]],

        Times,
          parts = List @@ expr;
          result = oneSeries;
          Do[
            seriesParts = expandExpression[part, s, goal, ass];
            If[seriesParts === $Failed, Return[$Failed]];
            result = multiplySeries[result, seriesParts, goal, ass],
            {part, parts}
          ];
          result,

        Power,
          parts = List @@ expr;
          If[Length[parts] =!= 2 || ! FreeQ[parts[[2]], s],
            Message[InverseAsymptotic::unsupported, expr];
            Return[$Failed]
          ];
          seriesParts = expandExpression[parts[[1]], s, goal, ass];
          If[seriesParts === $Failed, $Failed, powerSeries[seriesParts, parts[[2]], goal, ass]],

        Log,
          parts = List @@ expr;
          If[Length[parts] =!= 1,
            Message[InverseAsymptotic::unsupported, expr];
            Return[$Failed]
          ];
          seriesParts = expandExpression[First[parts], s, goal, ass];
          If[seriesParts === $Failed, $Failed, logSeries[seriesParts, s, goal, ass]],

        _,
          Message[InverseAsymptotic::unsupported, expr];
          $Failed
      ]
  ]
];

(* ---------------------------------------------------------------------- *)
(* Public API                                                              *)
(* ---------------------------------------------------------------------- *)

ClearAll[
  parseXSpec, parseYSpec, normalizeInputExpression, directionAssumption,
  limitOptions, postSimplifyFunction, systemInverseFallback, inverseDataCore,
  hybridAsymptoticExpression, hybridAsymptoticTerms, finalResidualTerms,
  residualSmallerThanRetainedQ
];

parseXSpec[{x_Symbol, x0_}] := {x, x0};
parseXSpec[spec_] := (Message[InverseAsymptotic::badxspec, spec]; $Failed);

parseYSpec[{y_Symbol, y0_}] := {y, y0};
parseYSpec[y_Symbol] := {y, Automatic};
parseYSpec[spec_] := (Message[InverseAsymptotic::badyspec, spec]; $Failed);

normalizeInputExpression[fun_Function, x_Symbol] := normalizeInputExpression[fun[x], x];
normalizeInputExpression[ConditionalExpression[e_, cond_], _Symbol] := {e, cond};
normalizeInputExpression[e_, _Symbol] := {e, True};

directionAssumption[s_Symbol, -1] := s > 0;
directionAssumption[s_Symbol, "FromAbove"] := s > 0;
directionAssumption[s_Symbol, 1] := s < 0;
directionAssumption[s_Symbol, "FromBelow"] := s < 0;
directionAssumption[s_Symbol, _] := s > 0;

limitOptions[Automatic] := Sequence[];
limitOptions[dir_] := Sequence[Direction -> dir];

postSimplifyFunction[FullSimplify] :=
  Function[{expr, ass}, Quiet@TimeConstrained[FullSimplify[expr, ass], 5, expr]];
postSimplifyFunction[Simplify] :=
  Function[{expr, ass}, Quiet@TimeConstrained[Simplify[expr, ass], 3, expr]];
postSimplifyFunction[None] := (First[{##}] &);
postSimplifyFunction[Automatic] := postSimplifyFunction[FullSimplify];
postSimplifyFunction[f_] := f;

systemInverseFallback[fexpr_, {x_, _}, {y_, y0_}, n_, ass_] := Quiet@Module[
  {res},
  res = TimeConstrained[
    Assuming[ass, Asymptotic[
      InverseFunction[Function[t, fexpr /. x -> t]][y],
      {y, y0, n},
      SeriesTermGoal -> n,
      Assumptions -> ass
    ]],
    20,
    $Failed
  ];
  res
];

finalResidualTerms[phi_, u_, expansion_, s_, goal_, ass_] :=
  hybridAsymptoticTerms[(phi /. u -> expansion) - s, s, goal, ass];

hybridAsymptoticExpression[expr_, s_, goal_, ass_] := Module[{built, terms},
  built = Quiet@TimeConstrained[
    Assuming[ass, Asymptotic[expr, {s, 0, goal}, SeriesTermGoal -> goal,
      Assumptions -> ass]],
    15,
    $Failed
  ];
  If[built === $Failed, built = expr];
  terms = Quiet@TimeConstrained[expandExpression[built, s, goal, ass], 15, $Failed];
  If[terms === $Failed,
    built,
    termsToExpression[truncateTerms[terms, goal, ass], s]
  ]
];

hybridAsymptoticTerms[expr_, s_, goal_, ass_] := Module[{expanded, terms},
  expanded = hybridAsymptoticExpression[expr, s, goal, ass];
  If[expanded === $Failed, Return[$Failed]];
  terms = Quiet@TimeConstrained[expandExpression[expanded, s, goal, ass], 15, $Failed];
  terms
];

residualSmallerThanRetainedQ[phi_, u_, gTerms_, s_, n_, workGoal_, ass_] := Module[
  {finalTerms, finalExpr, residualTerms, lastTerm, leadingResidual},
  finalTerms = truncateTerms[gTerms, n, ass];
  If[Length[distinctPowers[finalTerms, ass]] < n, Return[False]];
  finalExpr = termsToExpression[finalTerms, s];
  residualTerms = finalResidualTerms[phi, u, finalExpr, s, workGoal, ass];
  Which[
    residualTerms === $Failed, False,
    residualTerms === {}, True,
    finalTerms === {}, False,
    True,
      lastTerm = Last[finalTerms];
      leadingResidual = First[residualTerms];
      termOrderLessQ[lastTerm, leadingResidual, ass]
  ]
];

InverseAsymptotic[fun_, xspec_, yspec_, opts : OptionsPattern[]] := Module[{data},
  data = InverseAsymptoticData[fun, xspec, yspec, opts];
  If[AssociationQ[data] && KeyExistsQ[data, "Expansion"], data["Expansion"], data]
];

InverseAsymptotic[fun_, xspec_, y_Symbol, opts : OptionsPattern[]] :=
  InverseAsymptotic[fun, xspec, {y, Automatic}, opts];

InverseAsymptoticData[fun_, xspec_, yspec_, opts : OptionsPattern[]] := Module[
  {
    parsedX, parsedY, x, x0, y, y0Input, y0, n, ass0, dir, maxIterations,
    workGoal, fallbackQ, post, raw, condition, u, s, phi, phiSeries, lead,
    p0, l0, c0, seedTerms, gTerms, gExpr, derivative, iter, resTerms,
    deltaTerms, newTerms, finalTerms, finalExprS, finalExprY,
    residualTerms, method = "NewtonTransseries", fallback, fullAssumptions
  },

  parsedX = parseXSpec[xspec];
  If[parsedX === $Failed, Return[$Failed]];
  parsedY = parseYSpec[yspec];
  If[parsedY === $Failed, Return[$Failed]];
  {x, x0} = parsedX;
  {y, y0Input} = parsedY;

  n = OptionValue[SeriesTermGoal] /. Automatic -> 4;
  ass0 = OptionValue[Assumptions];
  dir = OptionValue[Direction];
  maxIterations = OptionValue["MaxIterations"] /. Automatic -> Max[4, n + 2];
  workGoal = OptionValue["WorkingTermGoal"] /. Automatic -> n + 1;
  fallbackQ = TrueQ[OptionValue["FallbackToSystemInverse"]];
  post = postSimplifyFunction[OptionValue["PostSimplify"]];

  {raw, condition} = normalizeInputExpression[fun, x];
  fullAssumptions = ass0 && condition && directionAssumption[x - x0, dir];

  y0 = If[y0Input === Automatic,
    Quiet@TimeConstrained[
      Assuming[fullAssumptions, Limit[raw, x -> x0, limitOptions[dir]]],
      10,
      $Failed
    ],
    y0Input
  ];
  If[y0 === $Failed || ! FreeQ[y0, x],
    Message[InverseAsymptotic::lim];
    If[fallbackQ,
      fallback = systemInverseFallback[raw, {x, x0}, {y, y0Input /. Automatic -> 0}, n, ass0];
      Return[fallback],
      Return[$Failed]
    ]
  ];

  u = Unique["u$"];
  s = Unique["s$"];
  fullAssumptions = ass0 && (condition /. x -> x0 + u) &&
    directionAssumption[u, dir] && s > 0;
  phi = Quiet@FullSimplify[(raw /. x -> x0 + u) - y0, fullAssumptions];

  phiSeries = expandExpression[phi, u, workGoal, fullAssumptions];
  If[phiSeries === $Failed || phiSeries === {},
    If[fallbackQ,
      fallback = systemInverseFallback[raw, {x, x0}, {y, y0}, n, ass0];
      Return[<|"Expansion" -> fallback, "Method" -> "SystemInverseFallback"|>],
      Return[$Failed]
    ]
  ];

  lead = First[phiSeries];
  {p0, l0, c0} = lead;
  If[! sameScalarQ[l0, 0, fullAssumptions] ||
      sameScalarQ[p0, 0, fullAssumptions] ||
      zeroTermQ[c0, fullAssumptions],
    Message[InverseAsymptotic::lead, lead];
    If[fallbackQ,
      fallback = systemInverseFallback[raw, {x, x0}, {y, y0}, n, ass0];
      Return[<|"Expansion" -> fallback, "Method" -> "SystemInverseFallback"|>],
      Return[$Failed]
    ]
  ];

  seedTerms = {{1/p0, 0, c0^(-1/p0)}};
  gTerms = seedTerms;
  gExpr = termsToExpression[gTerms, s];
  derivative = Quiet@D[phi, u];

  For[iter = 1, iter <= maxIterations, iter++,
    resTerms = finalResidualTerms[phi, u, gExpr, s, workGoal, fullAssumptions];
    If[resTerms === $Failed || resTerms === {}, Break[]];

    deltaTerms = hybridAsymptoticTerms[
      termsToExpression[resTerms, s]/(derivative /. u -> gExpr),
      s,
      workGoal,
      fullAssumptions
    ];
    If[deltaTerms === $Failed || deltaTerms === {}, Break[]];

    newTerms = hybridAsymptoticTerms[
      gExpr - termsToExpression[deltaTerms, s],
      s,
      workGoal,
      fullAssumptions
    ];
    If[newTerms === $Failed || newTerms === {}, Break[]];

    If[canonicalTerms[newTerms, fullAssumptions] === canonicalTerms[gTerms, fullAssumptions],
      Break[]
    ];
    gTerms = newTerms;
    gExpr = termsToExpression[gTerms, s];
    If[residualSmallerThanRetainedQ[phi, u, gTerms, s, n, workGoal, fullAssumptions],
      Break[]
    ];
  ];

  finalTerms = truncateTerms[gTerms, n, fullAssumptions];
  finalExprS = termsToExpression[finalTerms, s];
  residualTerms = finalResidualTerms[phi, u, finalExprS, s, workGoal, fullAssumptions];
  finalExprY = Quiet@post[x0 + (finalExprS /. s -> y - y0), ass0 && (y - y0 > 0)];

  <|
    "Expansion" -> finalExprY,
    "Terms" -> termAssociations[finalTerms, y - y0],
    "NormalizedFunction" -> phi,
    "NormalizedFunctionTerms" -> termAssociations[phiSeries, u],
    "OutputPoint" -> y0,
    "InputPoint" -> x0,
    "Iterations" -> iter - 1,
    "Method" -> method,
    "ResidualTerms" -> If[residualTerms === $Failed, $Failed,
      termAssociations[truncateTerms[residualTerms, n + 1, fullAssumptions], s]]
  |>
];

InverseAsymptoticTerms[fun_, xspec_, yspec_, opts : OptionsPattern[]] := Module[{data},
  data = InverseAsymptoticData[fun, xspec, yspec, opts];
  If[AssociationQ[data], data["Terms"], data]
];

InverseAsymptoticTerms[fun_, xspec_, y_Symbol, opts : OptionsPattern[]] :=
  InverseAsymptoticTerms[fun, xspec, {y, Automatic}, opts];

InverseAsymptoticVerify[fun_, approx_, xspec_, yspec_, opts : OptionsPattern[]] := Module[
  {
    parsedX, parsedY, x, x0, y, y0Input, y0, n, ass0, dir, raw, condition,
    u, s, phi, approxS, approxTerms, residualTerms, lastTerm, leadingResidual,
    smallerQ, fullAssumptions
  },
  parsedX = parseXSpec[xspec];
  If[parsedX === $Failed, Return[$Failed]];
  parsedY = parseYSpec[yspec];
  If[parsedY === $Failed, Return[$Failed]];
  {x, x0} = parsedX;
  {y, y0Input} = parsedY;
  n = OptionValue[SeriesTermGoal] /. Automatic -> 4;
  ass0 = OptionValue[Assumptions];
  dir = OptionValue[Direction];
  {raw, condition} = normalizeInputExpression[fun, x];

  fullAssumptions = ass0 && condition && directionAssumption[x - x0, dir];
  y0 = If[y0Input === Automatic,
    Quiet@TimeConstrained[
      Assuming[fullAssumptions, Limit[raw, x -> x0, limitOptions[dir]]],
      10,
      $Failed
    ],
    y0Input
  ];
  If[y0 === $Failed, Return[$Failed]];

  u = Unique["u$"];
  s = Unique["s$"];
  fullAssumptions = ass0 && (condition /. x -> x0 + u) &&
    directionAssumption[u, dir] && s > 0;
  phi = Quiet@FullSimplify[(raw /. x -> x0 + u) - y0, fullAssumptions];
  approxS = Quiet@FullSimplify[(approx - x0) /. y -> y0 + s, fullAssumptions];
  approxTerms = expandExpression[approxS, s, n + 2, fullAssumptions];
  residualTerms = finalResidualTerms[phi, u, approxS, s, n + 3, fullAssumptions];
  If[approxTerms === $Failed || residualTerms === $Failed, Return[$Failed]];

  lastTerm = If[approxTerms === {}, Missing["NoTerms"], Last[truncateTerms[approxTerms, n, fullAssumptions]]];
  leadingResidual = If[residualTerms === {}, 0, First[residualTerms]];
  smallerQ = Which[
    residualTerms === {}, True,
    MissingQ[lastTerm], Missing["NoLastTerm"],
    True, termOrderLessQ[lastTerm, leadingResidual, fullAssumptions]
  ];

  <|
    "ResidualSmallerThanLastTerm" -> smallerQ,
    "LastRetainedTerm" -> If[MissingQ[lastTerm], lastTerm, termToExpression[lastTerm, y - y0]],
    "LeadingResidualTerm" -> If[leadingResidual === 0, 0, termToExpression[leadingResidual, y - y0]],
    "ApproximationTerms" -> termAssociations[truncateTerms[approxTerms, n, fullAssumptions], y - y0],
    "ResidualTerms" -> termAssociations[truncateTerms[residualTerms, n + 1, fullAssumptions], y - y0]
  |>
];

InverseAsymptoticVerify[fun_, approx_, xspec_, y_Symbol, opts : OptionsPattern[]] :=
  InverseAsymptoticVerify[fun, approx, xspec, {y, Automatic}, opts];

End[];
EndPackage[];
