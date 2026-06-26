(* ::Package:: *)

(* :Title: OptimizedExpressions *)
(* :Context: OptimizedExpressions` *)
(* :Author: Vladimir Reshetnikov and OpenAI Codex *)
(* :Summary:
   DAG-preserving manipulation of Experimental`OptimizedExpression objects.

   The package answers the 2020 Mathematica StackExchange question
   "Computations with OptimizedExpressions without completely expanding them".
   It implements a structural common-subexpression DAG over Wolfram expressions
   and round-trips through Experimental`OptimizedExpression[Block[...]].

   Core properties:
     * existing optimized operands are imported through their temporary-variable
       definitions instead of by Normal/expansion;
     * temporaries from different operands are semantic, not nominal -- two
       operands that call the same subexpression t$123 and u$9 share one DAG node;
     * arithmetic and exact-symbol substitution construct new root nodes and then
       re-emit one optimized expression for the whole result;
     * the optimizer exposes size and exclusion controls missing from the
       Experimental`OptimizeExpression interface: small composite leaves may be
       kept intact, and caller-selected patterns/heads may be treated as opaque.
*)

BeginPackage["OptimizedExpressions`"];

OptimizeExpressionDAG::usage =
  "OptimizeExpressionDAG[expr] returns an Experimental`OptimizedExpression whose \
temporaries are chosen by a structural common-subexpression DAG.  It accepts \
ordinary expressions and existing Experimental`OptimizedExpression objects.  \
Options include \"AtomicLeafCount\" (composite expressions of this LeafCount or \
smaller are kept as opaque leaves), \"ExcludedPatterns\", \"ExcludedHeads\", \
\"MinCommonLeafCount\", \"MaxInlineLeafCount\", and \"OptimizationSymbol\".";

OptimizedApply::usage =
  "OptimizedApply[f, {e1, e2, ...}] combines optimized or ordinary operands \
without expanding existing Experimental`OptimizedExpression operands.  f may be \
a symbolic head such as Plus, Times, or List, or a pure Function.  The result is \
a single optimized expression with shared subexpressions deduplicated across all \
operands.";

OptimizedPlus::usage =
  "OptimizedPlus[e1, e2, ...] adds optimized or ordinary operands and returns one \
optimized expression.";

OptimizedTimes::usage =
  "OptimizedTimes[e1, e2, ...] multiplies optimized or ordinary operands and \
returns one optimized expression.";

OptimizedDivide::usage =
  "OptimizedDivide[num, den] returns an optimized representation of num/den \
without expanding optimized operands.";

OptimizedSubstitute::usage =
  "OptimizedSubstitute[expr, x -> replacement] substitutes replacement for the \
symbol x in expr while both sides remain in DAG form.  A list of symbol rules is \
also accepted.  Composite pattern rewriting is intentionally out of scope; use \
the exact-symbol form for production-scale DAG substitution.";

OptimizedExpressionNormal::usage =
  "OptimizedExpressionNormal[expr] expands an optimized expression to an ordinary \
Wolfram expression.  It is intended for tests and small inspections; production \
operations should use the DAG functions instead.";

OptimizedExpressionData::usage =
  "OptimizedExpressionData[expr] returns an Association describing the canonical \
expression DAG: node count, selected temporary count, roots, occurrence counts, \
leaf counts, and the generated optimized expression.";

OptimizeExpressionDAG::badopt =
  "Option `1` has unsupported value `2`.";
OptimizedApply::arity =
  "The pure function supplied to OptimizedApply did not accept `1` operands.";
OptimizedSubstitute::rules =
  "OptimizedSubstitute expects a rule or a list of rules whose left sides are symbols.";
OptimizedExpressionNormal::input =
  "Expression `1` is not an optimized expression produced by this package or by the system optimizer.";

Options[OptimizeExpressionDAG] = {
  "AtomicLeafCount" -> 1,
  "ExcludedPatterns" -> {},
  "ExcludedHeads" -> {},
  "MinCommonLeafCount" -> 2,
  "MaxInlineLeafCount" -> 50,
  "OptimizationSymbol" -> "opt"
};
Options[OptimizedApply] = Options[OptimizeExpressionDAG];
Options[OptimizedPlus] = Options[OptimizeExpressionDAG];
Options[OptimizedTimes] = Options[OptimizeExpressionDAG];
Options[OptimizedDivide] = Options[OptimizeExpressionDAG];
Options[OptimizedSubstitute] = Options[OptimizeExpressionDAG];
Options[OptimizedExpressionNormal] = Options[OptimizeExpressionDAG];
Options[OptimizedExpressionData] = Options[OptimizeExpressionDAG];

Begin["`Private`"];

(* ---------------------------------------------------------------------- *)
(* option normalization                                                    *)

ClearAll[optionAssociation, normalizedPatterns, normalizedHeads, numericOption];

optionAssociation[head_, opts___] := Association[Options[head], opts];

normalizedPatterns[value_] := Which[
  value === None || value === {}, {},
  ListQ[value], value,
  True, {value}
];

normalizedHeads[value_] := Which[
  value === None || value === {}, {},
  ListQ[value], value,
  True, {value}
];

numericOption[name_, value_, pred_] := If[TrueQ[pred[value]],
  value,
  Message[OptimizeExpressionDAG::badopt, name, value];
  $Failed
];

ClearAll[normalizeOptions];
normalizeOptions[head_, opts___] := Module[
  {oa, atomic, minCommon, maxInline},
  oa = optionAssociation[head, opts];
  atomic = numericOption["AtomicLeafCount", oa["AtomicLeafCount"],
    IntegerQ[#] && # >= 0 &];
  minCommon = numericOption["MinCommonLeafCount", oa["MinCommonLeafCount"],
    IntegerQ[#] && # >= 1 &];
  maxInline = numericOption["MaxInlineLeafCount", oa["MaxInlineLeafCount"],
    IntegerQ[#] && # >= 1 &];
  If[MemberQ[{atomic, minCommon, maxInline}, $Failed], Return[$Failed]];
  <|
    "AtomicLeafCount" -> atomic,
    "ExcludedPatterns" -> normalizedPatterns[oa["ExcludedPatterns"]],
    "ExcludedHeads" -> normalizedHeads[oa["ExcludedHeads"]],
    "MinCommonLeafCount" -> minCommon,
    "MaxInlineLeafCount" -> maxInline,
    "OptimizationSymbol" -> oa["OptimizationSymbol"]
  |>
];

(* ---------------------------------------------------------------------- *)
(* builder                                                                 *)

ClearAll[createBuilder];

createBuilder[options_Association] := Module[
  {
    nodes = <||>, keyToId = <||>, nextId = 0,
    atomicLeafCount = options["AtomicLeafCount"],
    excludedPatterns = options["ExcludedPatterns"],
    excludedHeads = options["ExcludedHeads"],
    intern, internAtom, internOpaque, internCall, build, excludedQ,
    importNode, importDag, getNodes, getDag, expressionLeafCount
  },

  SetAttributes[excludedQ, HoldFirst];
  excludedQ[expr_] := Module[{head = Head[Unevaluated[expr]]},
    TrueQ[
      MemberQ[excludedHeads, head] ||
        AnyTrue[excludedPatterns, MatchQ[Unevaluated[expr], #] &]
    ]
  ];

  SetAttributes[expressionLeafCount, HoldFirst];
  expressionLeafCount[expr_] := Quiet @ Check[LeafCount[Unevaluated[expr]], 1];

  intern[key_, data_Association] := Module[{id},
    If[KeyExistsQ[keyToId, key], Return[keyToId[key]]];
    id = ++nextId;
    keyToId[key] = id;
    nodes[id] = Join[data, <|"Id" -> id|>];
    id
  ];

  SetAttributes[internAtom, HoldFirst];
  internAtom[expr_, extractable_: False, leafCount_: Automatic] := intern[
    HoldComplete["Atom", Unevaluated[expr]],
    <|
      "Kind" -> "Atom",
      "Expression" -> Unevaluated[expr],
      "LeafCount" -> Replace[leafCount, Automatic :> expressionLeafCount[expr]],
      "Extractable" -> TrueQ[extractable]
    |>
  ];

  SetAttributes[internOpaque, HoldFirst];
  internOpaque[expr_, extractable_] := internAtom[
    Unevaluated[expr],
    extractable,
    expressionLeafCount[expr]
  ];

  internCall[head_, children_List] := Module[{leaf},
    leaf = 1 + Total[Lookup[nodes /@ children, "LeafCount"]];
    intern[
      HoldComplete["Call", head, children],
      <|
        "Kind" -> "Call",
        "Head" -> head,
        "Children" -> children,
        "LeafCount" -> leaf,
        "Extractable" -> True
      |>
    ]
  ];

  SetAttributes[build, HoldFirst];
  build[expr_, env_: <||>] := Module[{head, parts, children, leaf},
    If[AtomQ[Unevaluated[expr]],
      If[Head[Unevaluated[expr]] === Symbol && KeyExistsQ[env, Unevaluated[expr]],
        Return[env[Unevaluated[expr]]]
      ];
      Return[internAtom[Unevaluated[expr]]]
    ];

    If[excludedQ[expr], Return[internOpaque[Unevaluated[expr], False]]];

    leaf = expressionLeafCount[expr];
    If[leaf <= atomicLeafCount,
      Return[internOpaque[Unevaluated[expr], True]]
    ];

    head = Unevaluated[Head[Unevaluated[expr]]];
    parts = List @@ Unevaluated[expr];
    children = build[#, env] & /@ parts;
    internCall[head, children]
  ];

  importNode[dag_Association, id_Integer, mapIn_Association] := Module[
    {map = mapIn, cached, source, result, children},
    If[KeyExistsQ[map, id], Return[{map[id], map}]];
    source = dag["Nodes"][id];
    result = If[source["Kind"] === "Atom",
      With[
        {
          expr = source["Expression"],
          extractable = source["Extractable"],
          leaf = source["LeafCount"]
        },
        internAtom[expr, extractable, leaf]
      ],
      children = source["Children"];
      {children, map} = Fold[
        Function[{state, child},
          Module[{cid, m},
            {cid, m} = importNode[dag, child, state[[2]]];
            {Append[state[[1]], cid], m}
          ]
        ],
        {{}, map},
        children
      ];
      internCall[source["Head"], children]
    ];
    map[id] = result;
    {result, map}
  ];

  importDag[dag_Association] := Module[{map = <||>, outputs = {}, id},
    Do[
      {id, map} = importNode[dag, output, map];
      AppendTo[outputs, id],
      {output, dag["Outputs"]}
    ];
    outputs
  ];

  getNodes[] := nodes;
  getDag[outputs_List] := <|"Nodes" -> nodes, "Outputs" -> outputs|>;

  <|
    "Build" -> Function[{expr, env}, build[expr, env]],
    "ImportDag" -> importDag,
    "ImportNode" -> importNode,
    "InternAtom" -> Function[{expr, extractable, leaf}, internAtom[expr, extractable, leaf]],
    "InternCall" -> internCall,
    "Nodes" -> getNodes,
    "Dag" -> getDag
  |>
];

(* ---------------------------------------------------------------------- *)
(* parsing input into the internal DAG                                     *)

ClearAll[optimizedExpressionHeldQ, parseInputToDag, parseOptimizedHeld];

optimizedExpressionHeldQ[HoldComplete[Experimental`OptimizedExpression[_]]] := True;
optimizedExpressionHeldQ[_] := False;

parseInputToDag[expr_, options_Association] := Module[{held},
  held = HoldComplete[expr];
  If[optimizedExpressionHeldQ[held],
    parseOptimizedHeld[held, options],
    Module[{builder, root},
      builder = createBuilder[options];
      root = builder["Build"][expr, <||>];
      builder["Dag"][{root}]
    ]
  ]
];

parseOptimizedHeld[
  held : HoldComplete[Experimental`OptimizedExpression[Block[vars_List, body_]]],
  options_Association
] := Module[
  {builder, varList, setHolds, outputHold, env = <||>, rhsId, outputId},
  builder = createBuilder[options];
  varList = vars;
  setHolds = Cases[
    held,
    HoldPattern[Set[lhs_Symbol, rhs_]] /; MemberQ[varList, Unevaluated[lhs]] :>
      HoldComplete[lhs, rhs],
    Infinity
  ];
  Do[
    Replace[
      setHold,
      HoldComplete[lhs_Symbol, rhs_] :> (
        rhsId = builder["Build"][rhs, env];
        env[Unevaluated[lhs]] = rhsId;
      )
    ],
    {setHold, setHolds}
  ];
  outputHold = Replace[
    held,
    {
      HoldComplete[Experimental`OptimizedExpression[Block[_List, CompoundExpression[___, last_]]]] :>
        HoldComplete[last],
      HoldComplete[Experimental`OptimizedExpression[Block[_List, e_]]] :>
        HoldComplete[e]
    },
    {0}
  ];
  outputId = Replace[outputHold, HoldComplete[e_] :> builder["Build"][e, env]];
  builder["Dag"][{outputId}]
];

parseOptimizedHeld[held_, options_Association] := Module[{builder, root},
  builder = createBuilder[options];
  root = Replace[held, HoldComplete[e_] :> builder["Build"][e, <||>]];
  builder["Dag"][{root}]
];

(* ---------------------------------------------------------------------- *)
(* DAG analysis and rendering                                              *)

ClearAll[nodeReferenceCounts, selectedTemporaryIds, makeTemporarySymbols];

nodeReferenceCounts[dag_Association] := Module[{counts = <||>, nodes = dag["Nodes"]},
  Do[counts[id] = 0, {id, Keys[nodes]}];
  Do[counts[output] = Lookup[counts, output, 0] + 1, {output, dag["Outputs"]}];
  KeyValueMap[
    Function[{id, node},
      If[node["Kind"] === "Call",
        Do[counts[child] = Lookup[counts, child, 0] + 1, {child, node["Children"]}]
      ]
    ],
    nodes
  ];
  counts
];

selectedTemporaryIds[dag_Association, options_Association] := Module[
  {counts, nodes, minCommon, maxInline},
  counts = nodeReferenceCounts[dag];
  nodes = dag["Nodes"];
  minCommon = options["MinCommonLeafCount"];
  maxInline = options["MaxInlineLeafCount"];
  Select[
    Keys[nodes],
    With[{node = nodes[#], count = Lookup[counts, #, 0]},
      TrueQ[node["Extractable"]] &&
        (node["LeafCount"] > maxInline ||
          (count > 1 && node["LeafCount"] >= minCommon))
    ] &
  ]
];

makeTemporarySymbols[n_Integer, base_] := Module[{context, name},
  {context, name} = Which[
    MatchQ[base, _Symbol], {Context[base], SymbolName[base]},
    StringQ[base] && StringLength[base] > 0, {"OptimizedExpressions`Private`", base},
    True, {"OptimizedExpressions`Private`", "opt"}
  ];
  Table[Symbol[context <> name <> "$" <> ToString[i]], {i, n}]
];

ClearAll[renderDag, makeHeldCompound, releaseOptimizedExpression];

renderDag[dag_Association, options_Association] := Module[
  {
    nodes = dag["Nodes"], selected, selectedSet, tempById = <||>, ordered = {},
    defs = {}, temps, render, ensure, outputExpr, tempSymbols
  },
  selected = selectedTemporaryIds[dag, options];
  selectedSet = AssociationThread[selected -> ConstantArray[True, Length[selected]]];
  tempSymbols = makeTemporarySymbols[Length[selected], options["OptimizationSymbol"]];
  Do[tempById[selected[[i]]] = tempSymbols[[i]], {i, Length[selected]}];

  Clear[render, ensure];

  ensure[id_Integer] := Module[{node, expr},
    If[! KeyExistsQ[selectedSet, id], Return[Null]];
    If[MemberQ[ordered, id], Return[Null]];
    node = nodes[id];
    If[node["Kind"] === "Call", Scan[ensure, node["Children"]]];
    expr = render[id, True];
    AppendTo[ordered, id];
    AppendTo[
      defs,
      With[{lhs = tempById[id], rhs = expr}, HoldComplete[Set[lhs, rhs]]]
    ];
  ];

  render[id_Integer, forceInline_: False] := Module[{node = nodes[id], renderedChildren},
    If[! TrueQ[forceInline] && KeyExistsQ[selectedSet, id],
      ensure[id];
      Return[tempById[id]]
    ];
    If[node["Kind"] === "Atom",
      Return[node["Expression"]]
    ];
    renderedChildren = render[#, False] & /@ node["Children"];
    Apply[node["Head"], renderedChildren]
  ];

  outputExpr = If[Length[dag["Outputs"]] === 1,
    render[First[dag["Outputs"]], False],
    Apply[List, render[#, False] & /@ dag["Outputs"]]
  ];

  If[defs === {},
    With[{out = outputExpr}, Experimental`OptimizedExpression[Block[{}, out]]],
    releaseOptimizedExpression[
      tempSymbols,
      makeHeldCompound[
        Join[defs, {With[{out = outputExpr}, HoldComplete[out]]}]
      ]
    ]
  ]
];

makeHeldCompound[holds_List] := Module[{held},
  held = Apply[HoldComplete, holds];
  held = held /. HoldComplete[seq___] :> HoldComplete[CompoundExpression[seq]];
  FixedPoint[
    Replace[
      #,
      HoldComplete[CompoundExpression[a___, HoldComplete[e_], b___]] :>
        HoldComplete[CompoundExpression[a, e, b]],
      {0}
    ] &,
    held
  ]
];

releaseOptimizedExpression[temps_List, HoldComplete[body_]] :=
  ReleaseHold @ HoldComplete[
    Experimental`OptimizedExpression[Block[temps, body]]
  ];

ClearAll[renderNormal];
renderNormal[dag_Association] := Module[{nodes = dag["Nodes"], render},
  Clear[render];
  render[id_Integer] := Module[{node = nodes[id]},
    If[node["Kind"] === "Atom",
      node["Expression"],
      Apply[node["Head"], render /@ node["Children"]]
    ]
  ];
  If[Length[dag["Outputs"]] === 1,
    render[First[dag["Outputs"]]],
    render /@ dag["Outputs"]
  ]
];

ClearAll[dagStatistics];
dagStatistics[dag_Association, options_Association] := Module[
  {nodes = dag["Nodes"], counts, selected},
  counts = nodeReferenceCounts[dag];
  selected = selectedTemporaryIds[dag, options];
  <|
    "NodeCount" -> Length[nodes],
    "TemporaryCount" -> Length[selected],
    "Roots" -> dag["Outputs"],
    "SelectedTemporaries" -> selected,
    "OccurrenceCounts" -> counts,
    "LeafCounts" -> Association @ KeyValueMap[#1 -> #2["LeafCount"] &, nodes],
    "Nodes" -> nodes
  |>
];

(* ---------------------------------------------------------------------- *)
(* DAG merging and transformations                                         *)

ClearAll[mergeDags];
mergeDags[dags_List, options_Association] := Module[
  {builder, roots},
  builder = createBuilder[options];
  roots = builder["ImportDag"] /@ dags;
  {builder, roots}
];

ClearAll[listNodeQ, nodeChildren, mapListable];

listNodeQ[dag_Association, id_Integer] := Module[{node = dag["Nodes"][id]},
  node["Kind"] === "Call" && node["Head"] === List
];

nodeChildren[dag_Association, id_Integer] := dag["Nodes"][id]["Children"];

mapListable[builder_, dag_Association, head_, roots_List] := Module[
  {listRoots, lengths, n, childAt, resultChildren},
  listRoots = Select[roots, listNodeQ[dag, #] &];
  If[listRoots === {}, Return[builder["InternCall"][head, roots]]];
  lengths = Length[nodeChildren[dag, #]] & /@ listRoots;
  If[Length[Union[lengths]] =!= 1, Return[builder["InternCall"][head, roots]]];
  n = First[lengths];
  childAt[root_, i_] := If[listNodeQ[dag, root], nodeChildren[dag, root][[i]], root];
  resultChildren = Table[
    builder["InternCall"][head, childAt[#, i] & /@ roots],
    {i, n}
  ];
  builder["InternCall"][List, resultChildren]
];

ClearAll[combineWithHead];
combineWithHead[head_, operands_List, options_Association] := Module[
  {dags, builder, importedRoots, roots, root, dag},
  dags = parseInputToDag[#, options] & /@ operands;
  {builder, importedRoots} = mergeDags[dags, options];
  roots = Flatten[importedRoots];
  dag = builder["Dag"][roots];
  root = If[MemberQ[{Plus, Times}, head],
    mapListable[builder, dag, head, roots],
    builder["InternCall"][head, roots]
  ];
  renderDag[builder["Dag"][{root}], options]
];

ClearAll[combineWithFunction];
combineWithFunction[fun_Function, operands_List, options_Association] := Module[
  {dags, builder, importedRoots, roots, placeholders, template, env, root},
  dags = parseInputToDag[#, options] & /@ operands;
  {builder, importedRoots} = mergeDags[dags, options];
  If[! AllTrue[importedRoots, Length[#] === 1 &], Return[$Failed]];
  roots = First /@ importedRoots;
  placeholders = Array[Unique["optArg$"] &, Length[roots]];
  template = Quiet @ Check[fun @@ placeholders, $Failed];
  If[template === $Failed,
    Message[OptimizedApply::arity, Length[operands]];
    Return[$Failed]
  ];
  env = AssociationThread[placeholders -> roots];
  root = builder["Build"][template, env];
  renderDag[builder["Dag"][{root}], options]
];

ClearAll[substituteDag];
substituteDag[target_, rules_List, options_Association] := Module[
  {
    targetDag, replacementDags, builder, importedTargetRoots, importedReplacementRoots,
    replacementBySymbol, nodes, subst, newRoots
  },
  targetDag = parseInputToDag[target, options];
  replacementDags = parseInputToDag[Last[#], options] & /@ rules;
  builder = createBuilder[options];
  importedTargetRoots = builder["ImportDag"][targetDag];
  importedReplacementRoots = builder["ImportDag"] /@ replacementDags;
  If[! AllTrue[importedReplacementRoots, Length[#] === 1 &], Return[$Failed]];
  replacementBySymbol = AssociationThread[First /@ rules -> (First /@ importedReplacementRoots)];
  nodes = builder["Nodes"][];

  Clear[subst];
  subst[id_Integer] := Module[{node = nodes[id], children},
    If[node["Kind"] === "Atom",
      If[Head[node["Expression"]] === Symbol && KeyExistsQ[replacementBySymbol, node["Expression"]],
        replacementBySymbol[node["Expression"]],
        id
      ],
      children = subst /@ node["Children"];
      builder["InternCall"][node["Head"], children]
    ]
  ];

  newRoots = subst /@ importedTargetRoots;
  renderDag[builder["Dag"][newRoots], options]
];

(* ---------------------------------------------------------------------- *)
(* public API                                                              *)

OptimizeExpressionDAG[expr_, opts : OptionsPattern[]] := Module[{options, dag},
  options = normalizeOptions[OptimizeExpressionDAG, opts];
  If[options === $Failed, Return[$Failed]];
  dag = parseInputToDag[expr, options];
  renderDag[dag, options]
];

OptimizedExpressionData[expr_, opts : OptionsPattern[]] := Module[
  {options, dag, stats, optimized},
  options = normalizeOptions[OptimizedExpressionData, opts];
  If[options === $Failed, Return[$Failed]];
  dag = parseInputToDag[expr, options];
  optimized = renderDag[dag, options];
  stats = dagStatistics[dag, options];
  Join[
    stats,
    <|
      "OptimizedExpression" -> optimized,
      "NormalExpression" -> renderNormal[dag],
      "Options" -> options
    |>
  ]
];

OptimizedExpressionNormal[expr_, opts : OptionsPattern[]] := Module[{options, dag},
  options = normalizeOptions[OptimizedExpressionNormal, opts];
  If[options === $Failed, Return[$Failed]];
  dag = parseInputToDag[expr, options];
  If[! AssociationQ[dag],
    Message[OptimizedExpressionNormal::input, HoldForm[expr]];
    Return[$Failed]
  ];
  renderNormal[dag]
];

OptimizedApply[head_Symbol, operands_List, opts : OptionsPattern[]] := Module[{options},
  options = normalizeOptions[OptimizedApply, opts];
  If[options === $Failed, Return[$Failed]];
  combineWithHead[head, operands, options]
];

OptimizedApply[fun_Function, operands_List, opts : OptionsPattern[]] := Module[{options},
  options = normalizeOptions[OptimizedApply, opts];
  If[options === $Failed, Return[$Failed]];
  combineWithFunction[fun, operands, options]
];

OptimizedPlus[args___, opts : OptionsPattern[]] := OptimizedApply[Plus, {args}, opts];

OptimizedTimes[args___, opts : OptionsPattern[]] := OptimizedApply[Times, {args}, opts];

OptimizedDivide[num_, den_, opts : OptionsPattern[]] := Module[{options, dags, builder, roots, inv, root},
  options = normalizeOptions[OptimizedDivide, opts];
  If[options === $Failed, Return[$Failed]];
  dags = parseInputToDag[#, options] & /@ {num, den};
  {builder, roots} = mergeDags[dags, options];
  inv = builder["InternCall"][Power, {roots[[2, 1]], builder["InternAtom"][-1, False, 1]}];
  root = builder["InternCall"][Times, {roots[[1, 1]], inv}];
  renderDag[builder["Dag"][{root}], options]
];

OptimizedSubstitute[expr_, rule : (_Rule | _RuleDelayed), opts : OptionsPattern[]] :=
  OptimizedSubstitute[expr, {rule}, opts];

OptimizedSubstitute[expr_, rules_List, opts : OptionsPattern[]] := Module[
  {options, normalizedRules},
  If[! AllTrue[rules, MatchQ[#, (_Symbol -> _) | (_Symbol :> _)] &],
    Message[OptimizedSubstitute::rules];
    Return[$Failed]
  ];
  options = normalizeOptions[OptimizedSubstitute, opts];
  If[options === $Failed, Return[$Failed]];
  normalizedRules = rules /. RuleDelayed -> Rule;
  substituteDag[expr, normalizedRules, options]
];

End[];
EndPackage[];
