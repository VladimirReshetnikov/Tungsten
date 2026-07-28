{-# LANGUAGE OverloadedStrings #-}

module Tungsten.ArrayTests (checkArrayEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr (..), SparseEntry (..), fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkArrayEvaluator :: IO Bool
checkArrayEvaluator = do
  valueResults <- traverse checkValue valueCases
  errorResults <- traverse checkError errorCases
  exactErrorResults <- traverse checkExactError exactErrorCases
  sparseResults <- sequence
    [ checkDirect
        "Dimensions preserves compact SparseArray dimensions"
        (Call (Symbol "Dimensions") [SparseArray [2, 3] [] (Integer 0)])
        "List[2, 3]"
    , checkDirect
        "ArrayDepth uses compact SparseArray rank"
        (Call (Symbol "ArrayDepth") [SparseArray [2, 3] [] (Integer 0)])
        "2"
    , checkDirect
        "ArrayQ accepts a rank-one sparse array"
        ( Call
            (Symbol "ArrayQ")
            [ SparseArray [3] [SparseEntry [2] (Integer 7)] (Integer 0)
            , Integer 1
            , Symbol "IntegerQ"
            ]
        )
        "True"
    , checkDirect
        "VectorQ tests a sparse implicit value"
        ( Call
            (Symbol "VectorQ")
            [ SparseArray [3] [SparseEntry [2] (Integer 7)] (Symbol "x")
            , Symbol "IntegerQ"
            ]
        )
        "False"
    , checkDirect
        "MatrixQ accepts compact rank-two sparse arrays"
        (Call (Symbol "MatrixQ") [SparseArray [0, 4] [] (Integer 0)])
        "True"
    , checkDirectError
        "dense matrix reducers reject SparseArray inputs explicitly"
        (Call (Symbol "Det") [SparseArray [2, 2] [] (Integer 0)])
    ]
  pure (and (valueResults <> errorResults <> exactErrorResults <> sparseResults))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("Dimensions ragged common prefix", "Dimensions[{{1,2},{3}}]", "List[2]")
  , ("Dimensions rectangular", "Dimensions[{{1,2},{3,4}}]", "List[2, 2]")
  , ("Dimensions empty List", "Dimensions[{}]", "List[0]")
  , ("ArrayDepth follows List branches", "ArrayDepth[{1,{2,{3}}}]", "3")
  , ("ArrayDepth ignores non-List calls", "ArrayDepth[f[{1,2}]]", "0")
  , ("Array constructs a vector with one-based indices", "Array[f,3]", "List[f[1], f[2], f[3]]")
  , ("Array constructs a rank-two tensor", "Array[f,{2,2}]", "List[List[f[1, 1], f[1, 2]], List[f[2, 1], f[2, 2]]]")
  , ("Array uses a scalar origin on every axis", "Array[f,{2,2},0]", "List[List[f[0, 0], f[0, 1]], List[f[1, 0], f[1, 1]]]")
  , ("Array uses per-axis origins", "Array[f,{2,2},{0,-1}]", "List[List[f[0, -1], f[0, 0]], List[f[1, -1], f[1, 0]]]")
  , ("Array accepts the rank-one origin range shorthand", "Array[f,3,{4,6}]", "List[f[4], f[5], f[6]]")
  , ("Array evaluates pure-function cells", "Array[Function[x,x^2],3]", "List[1, 4, 9]")
  , ("Array calls its function once for scalar shape", "Array[f,{}]", "f[]")
  , ("ConstantArray rectangular", "ConstantArray[x,{2,3}]", "List[List[x, x, x], List[x, x, x]]")
  , ("ConstantArray scalar shape", "ConstantArray[x,{}]", "x")
  , ("ConstantArray preserves leading zero axes", "ConstantArray[x,{2,0,3}]", "List[List[], List[]]")
  , ("ConstantArray filters Nothing", "ConstantArray[Nothing,3]", "List[]")
  , ("nested ConstantArray filters Nothing per List", "ConstantArray[Nothing,{2,2}]", "List[List[], List[]]")
  , ("ArrayQ recognizes a vector", "ArrayQ[{1,2}]", "True")
  , ("ArrayQ recognizes a rectangular matrix", "ArrayQ[{{1,2},{3,4}},2,IntegerQ]", "True")
  , ("ArrayQ rejects ragged lists", "ArrayQ[{{1},{2,3}}]", "False")
  , ("ArrayQ accepts an empty rank-one array", "ArrayQ[{},1,IntegerQ]", "True")
  , ("ArrayQ rejects atoms", "ArrayQ[x]", "False")
  , ("ArrayQ rejects atoms before validating depth", "ArrayQ[x,bad]", "False")
  , ("ArrayQ rejects ragged lists before validating depth", "ArrayQ[{{1},{2,3}},bad]", "False")
  , ("VectorQ accepts an empty vector", "VectorQ[{}]", "True")
  , ("VectorQ treats non-List calls as elements", "VectorQ[{1,f[a]}]", "True")
  , ("VectorQ applies an element predicate", "VectorQ[{1,a},IntegerQ]", "False")
  , ("VectorQ rejects nested lists", "VectorQ[{{}}]", "False")
  , ("MatrixQ accepts zero-width rows", "MatrixQ[{{}}]", "True")
  , ("MatrixQ applies an element predicate", "MatrixQ[{{1,a}},IntegerQ]", "False")
  , ("MatrixQ rejects ragged rows", "MatrixQ[{{1},{2,3}}]", "False")
  , ("MatrixQ rejects the rank-one empty list", "MatrixQ[{}]", "False")
  , ("SparseArray constructs from explicit rules", "Normal[SparseArray[{{1,2}->a,{2,3}->b},{2,3}]]", "List[List[0, a, 0], List[0, 0, b]]")
  , ("SparseArray constructs from a dense matrix", "ArrayRules[SparseArray[{{0,1},{2,0}}]]", "List[Rule[List[1, 2], 1], Rule[List[2, 1], 2], Rule[List[Blank[], Blank[]], 0]]")
  , ("SparseArray expands vectorized rank-one rules", "Normal[SparseArray[{1,3}->{a,b}]]", "List[a, 0, b]")
  , ("SparseArray retains the first duplicate rule", "Normal[SparseArray[{{1,1}->a,{1,1}->b},{1,1}]]", "List[List[a]]")
  , ("SparseArray supports a nonzero implicit value", "Normal[SparseArray[{{1,1}->a},{2,2},z]]", "List[List[a, z], List[z, z]]")
  , ("SparseArray exposes canonical properties", "{SparseArrayQ[SparseArray[{{1}->a}]],SparseArray[{{2}->a,{1}->b},{3},z][\"ImplicitValue\"],SparseArray[{{2}->a,{1}->b},{3},z][\"ExplicitValues\"],SparseArray[{{2}->a,{1}->b},{3},z][\"Density\"]}", "List[True, z, List[b, a], Rational[2, 3]]")
  , ("SparseArray Density is an exact reduced fraction", "{SparseArray[{}, {4294967296,4294967296}][\"Density\"],SparseArray[{{1}->a,{2}->b},{4}][\"Density\"]}", "List[0, Rational[1, 2]]")
  , ("Length reads the first compact SparseArray dimension", "Length[SparseArray[{}, {4294967296,3}]]", "4294967296")
  , ("SparseArray Part preserves a compact slice", "SparseArray[{{1,2}->a},{2,3}][[1]]", "SparseArray[List[Rule[List[2], a]], List[3]]")
  , ("SparseArray Part selects duplicate projected coordinates", "Normal[SparseArray[{{1}->a,{3}->c},{3}][[{3,1,3}]]]", "List[c, a, c]")
  , ("SparseArray Extract uses compact coordinate lookup", "Extract[SparseArray[{{2,3}->a},{2,3}],{2,3}]", "a")
  , ("SparseArray Extract accepts selector paths", "Extract[SparseArray[{{1,1}->a,{2,3}->f},{2,3}],{All,2}]", "SparseArray[List[], List[2]]")
  , ("SparseArray addition merges explicit coordinates", "Normal[SparseArray[{{1,2}->a},{2,3}]+SparseArray[{{2,3}->b},{2,3}]]", "List[List[0, a, 0], List[0, 0, b]]")
  , ("SparseArray scalar arithmetic transforms the implicit value", "Normal[2 SparseArray[{{1}->a},{3}]+1]", "List[Plus[1, Times[2, a]], 1, 1]")
  , ("SparseArray scalar addition keeps canonical term order", "z+SparseArray[{{1}->b},{2}]", "SparseArray[List[Rule[List[1], Plus[b, z]]], List[2], z]")
  , ("ArrayReshape preserves compact SparseArray storage", "ArrayRules[ArrayReshape[SparseArray[{{2}->a,{5}->b},{6}],{2,3}]]", "List[Rule[List[1, 2], a], Rule[List[2, 2], b], Rule[List[Blank[], Blank[]], 0]]")
  , ("ArrayReshape falls back to dense padding when fills differ", "ArrayReshape[SparseArray[{{1}->a,{4}->d},{5}],{2,3},x]", "List[List[a, 0, 0], List[d, 0, x]]")
  , ("ArrayPad shifts compact SparseArray coordinates", "ArrayRules[ArrayPad[SparseArray[{{2}->a},{3}],1]]", "List[Rule[List[3], a], Rule[List[Blank[]], 0]]")
  , ("ArrayPad materializes differing boundary fill", "ArrayPad[SparseArray[{{2}->a},{3}],{1,2},x]", "List[x, 0, a, 0, x, x]")
  , ("ArrayPad preserves arbitrary-precision sparse widths", "ArrayPad[SparseArray[{{1}->a},{2}],{100000000000000000000,3}]", "SparseArray[List[Rule[List[100000000000000000001], a]], List[100000000000000000005]]")
  , ("Transpose permutes compact SparseArray axes", "ArrayRules[Transpose[SparseArray[{{1,2}->a,{2,1}->b},{2,3}]]]", "List[Rule[List[1, 2], b], Rule[List[2, 1], a], Rule[List[Blank[], Blank[]], 0]]")
  , ("Flatten linearizes compact SparseArray coordinates", "ArrayRules[Flatten[SparseArray[{{1,2}->a,{2,1}->b},{2,3}]]]", "List[Rule[List[2], a], Rule[List[4], b], Rule[List[Blank[]], 0]]")
  , ("Flatten supports partial rank collapse", "ArrayRules[Flatten[SparseArray[{{1,1,2}->x,{2,3,4}->y},{2,3,4}],1]]", "List[Rule[List[1, 2], x], Rule[List[6, 4], y], Rule[List[Blank[], Blank[]], 0]]")
  , ("ArrayFlatten combines sparse and dense zero-fill blocks", "ArrayRules[ArrayFlatten[{{SparseArray[{{1,1}->a},{2,2}],{{b},{c}}}}]]", "List[Rule[List[1, 1], a], Rule[List[1, 3], b], Rule[List[2, 3], c], Rule[List[Blank[], Blank[]], 0]]")
  , ("ArrayFlatten materializes nonzero sparse fill", "ArrayFlatten[{{SparseArray[{{1,1}->a},{2,2},z]}}]", "List[List[a, z], List[z, z]]")
  , ("sparse transforms retain arbitrary-precision dimensions", "{ArrayReshape[SparseArray[{{1000000000}->a},{1000000000}],{1000000,1000}],ArrayPad[SparseArray[{{1000000000}->a},{1000000000}],{2,3}],Flatten[SparseArray[{{1,1}->a},{1000000000,1000000000}]]}", "List[SparseArray[List[Rule[List[1000000, 1000], a]], List[1000000, 1000]], SparseArray[List[Rule[List[1000000002], a]], List[1000000005]], SparseArray[List[Rule[List[1], a]], List[1000000000000000000]]]")
  , ("Dot intersects compact sparse vector coordinates", "Dot[SparseArray[{{1}->a,{3}->c},{3}],SparseArray[{{1}->b,{2}->d},{3}]]", "Times[a, b]")
  , ("Dot multiplies a sparse matrix and vector", "ArrayRules[Dot[SparseArray[{{1,2}->a,{2,1}->b},{2,3}],SparseArray[{{2}->c,{3}->d},{3}]]]", "List[Rule[List[1], Times[a, c]], Rule[List[Blank[]], 0]]")
  , ("Dot multiplies a sparse vector and matrix", "ArrayRules[Dot[SparseArray[{{1}->a,{3}->c},{3}],SparseArray[{{1,2}->b,{3,1}->d},{3,2}]]]", "List[Rule[List[1], Times[c, d]], Rule[List[2], Times[a, b]], Rule[List[Blank[]], 0]]")
  , ("Dot multiplies compact sparse matrices", "ArrayRules[Dot[SparseArray[{{1,2}->a},{2,3}],SparseArray[{{2,1}->b},{3,2}]]]", "List[Rule[List[1, 1], Times[a, b]], Rule[List[Blank[], Blank[]], 0]]")
  , ("Dot falls back for nonzero sparse fills", "Dot[SparseArray[{{1}->a},{2},z],SparseArray[{{2}->b},{2},x]]", "Plus[Times[a, x], Times[b, z]]")
  , ("Dot keeps huge zero-fill matrices compact", "Dot[SparseArray[{{1,1}->a},{1000000000,1000000000}],SparseArray[{{1,2}->b},{1000000000,1000000000}]]", "SparseArray[List[Rule[List[1, 2], Times[a, b]]], List[1000000000, 1000000000]]")
  , ("Dot accumulates sparse products in coordinate order", "Dot[SparseArray[{{1,1}->a,{1,2}->b},{1,2}],SparseArray[{{1,1}->c,{2,1}->d},{2,1}]]", "SparseArray[List[Rule[List[1, 1], Plus[Times[a, c], Times[b, d]]]], List[1, 1]]")
  , ("ArrayReshape flattens and pads", "ArrayReshape[{{1,2},{3,4}},{3,2},x]", "List[List[1, 2], List[3, 4], List[x, x]]")
  , ("ArrayReshape truncates row-major leaves", "ArrayReshape[{{1,2},{3,4}},{3}]", "List[1, 2, 3]")
  , ("ArrayReshape preserves rank around a zero axis", "ArrayReshape[{{}}, {2,0,3}]", "List[List[], List[]]")
  , ("ArrayReshape scalar shape", "ArrayReshape[{1,2},{}]", "1")
  , ("ArrayReshape empty scalar shape uses fill", "ArrayReshape[{},{},x]", "x")
  , ("ArrayPad per-axis widths", "ArrayPad[{{1,2},{3,4}},{{1,0},{0,1}},x]", "List[List[x, x, x], List[1, 2, x], List[3, 4, x]]")
  , ("ArrayPad rank-one asymmetric shorthand", "ArrayPad[{1,2},{1,2},x]", "List[x, 1, 2, x, x]")
  , ("ArrayPad pads an empty vector", "ArrayPad[{},1]", "List[0, 0]")
  , ("ArrayPad preserves nested zero-width axes", "ArrayPad[{{}},{{1,0},{0,1}},x]", "List[List[x], List[x]]")
  , ("ArrayFlatten block matrix", "ArrayFlatten[{{{{1,2},{3,4}},{{5},{6}}},{{{7,8}},{{9}}}}]", "List[List[1, 2, 5], List[3, 4, 6], List[7, 8, 9]]")
  , ("ArrayFlatten empty block rows", "ArrayFlatten[{}]", "List[]")
  , ("ArrayFlatten retains a zero-width block row", "ArrayFlatten[{{{{}}}}]", "List[List[]]")
  , ("Transpose matrix", "Transpose[{{1,2,3},{4,5,6}}]", "List[List[1, 4], List[2, 5], List[3, 6]]")
  , ("Transpose rank-three permutation", "Transpose[{{{a,b},{c,d}},{{e,f},{g,h}}},{3,1,2}]", "List[List[List[a, c], List[e, g]], List[List[b, d], List[f, h]]]")
  , ("Transpose swaps only the first two rank-three axes by default", "Transpose[{{{a,b}},{{c,d}}}]", "List[List[List[a, b], List[c, d]]]")
  , ("Transpose turns one zero-width row into an empty vector", "Transpose[{{}}]", "List[]")
  , ("Transpose vector identity", "Transpose[{a,b,c}]", "List[a, b, c]")
  , ("UnitVector", "UnitVector[5,3]", "List[0, 0, 1, 0, 0]")
  , ("IdentityMatrix", "IdentityMatrix[3]", "List[List[1, 0, 0], List[0, 1, 0], List[0, 0, 1]]")
  , ("IdentityMatrix empty matrix", "IdentityMatrix[0]", "List[]")
  , ("LeviCivitaTensor scalar dimension", "LeviCivitaTensor[0]", "1")
  , ("LeviCivitaTensor rank one", "LeviCivitaTensor[1]", "List[1]")
  , ("LeviCivitaTensor rank two", "LeviCivitaTensor[2]", "List[List[0, 1], List[-1, 0]]")
  , ("LeviCivitaTensor ignores a non-sparse requested head", "LeviCivitaTensor[2,f]", "List[List[0, 1], List[-1, 0]]")
  , ("LeviCivitaTensor compact sparse form", "LeviCivitaTensor[2,SparseArray]", "SparseArray[List[Rule[List[1, 2], 1], Rule[List[2, 1], -1]], List[2, 2]]")
  , ("DiagonalMatrix offset", "DiagonalMatrix[{a,b},1]", "List[List[0, a, 0], List[0, 0, b], List[0, 0, 0]]")
  , ("DiagonalMatrix negative offset and size", "DiagonalMatrix[{a,b},-1,4]", "List[List[0, 0, 0, 0], List[a, 0, 0, 0], List[0, b, 0, 0], List[0, 0, 0, 0]]")
  , ("Tuples Cartesian product", "Tuples[{{a,b},{1,2}}]", "List[List[a, 1], List[a, 2], List[b, 1], List[b, 2]]")
  , ("Tuples repetition", "Tuples[{a,b},2]", "List[List[a, a], List[a, b], List[b, a], List[b, b]]")
  , ("Tuples empty shape", "Tuples[{a,b},{}]", "List[]")
  , ("Tuples shaped product", "Tuples[{a,b},{2,1}]", "List[List[List[a], List[a]], List[List[a], List[b]], List[List[b], List[a]], List[List[b], List[b]]]")
  , ("Partition preserves compound head", "Partition[f[a,b,c,d,e],2]", "List[f[a, b], f[c, d]]")
  , ("Partition cyclic alignment", "Partition[{a,b,c,d,e},3,2,-1]", "List[List[d, e, a], List[a, b, c], List[c, d, e]]")
  , ("Partition explicit padding", "Partition[{a,b,c},3,1,{2,2},x]", "List[List[x, a, b], List[a, b, c], List[b, c, x]]")
  , ("Partition preserves Association blocks", "Partition[<|a->1,b->2,c->3|>,2]", "List[Association[Rule[a, 1], Rule[b, 2]]]")
  , ("TakeList consumes sequentially", "TakeList[{a,b,c,d,e},{2,1,All}]", "List[List[a, b], List[c], List[d, e]]")
  , ("TakeDrop returns both projections", "TakeDrop[f[a,b,c,d],-2]", "List[f[c, d], f[a, b]]")
  , ("Dot vectors", "Dot[{a,b},{c,d}]", "Plus[Times[a, c], Times[b, d]]")
  , ("Dot cancels exact symbolic coefficients", "Dot[{a,a},{a,-a}]", "0")
  , ("Dot matrix vector", "Dot[{{1,2},{3,4}},{5,6}]", "List[17, 39]")
  , ("Dot vector matrix", "Dot[{1,2},{{3,4},{5,6}}]", "List[13, 16]")
  , ("Dot matrix matrix", "Dot[{{1,2},{3,4}},{{5,6},{7,8}}]", "List[List[19, 22], List[43, 50]]")
  , ("Dot evaluates left-associated intermediates", "Dot[{{1,2},{3,4}},{{5,6},{7,8}},{1,0}]", "List[19, 43]")
  , ("Cross exact 2D", "Cross[{1,2},{3,4}]", "-2")
  , ("Cross symbolic canonical signs", "Cross[{a,b,c},{d,e,f}]", "List[Plus[Times[-1, c, e], Times[b, f]], Plus[Times[-1, a, f], Times[c, d]], Plus[Times[-1, b, d], Times[a, e]]]")
  , ("Cross cancels equal symbolic products", "Cross[{a,a},{a,a}]", "0")
  , ("Det exact", "Det[{{1,2},{3,4}}]", "-2")
  , ("Det empty identity", "Det[{}]", "1")
  , ("Det symbolic canonical sign", "Det[{{a,b},{c,d}}]", "Plus[Times[-1, b, c], Times[a, d]]")
  , ("Det cancels equal symbolic permutations", "Det[{{a,a},{a,a}}]", "0")
  , ("Inverse exact", "Inverse[{{1,2},{3,4}}]", "List[List[-2, 1], List[Rational[3, 2], Rational[-1, 2]]]")
  , ("Inverse empty matrix", "Inverse[{}]", "List[]")
  , ("MatrixPower positive", "MatrixPower[{{1,1},{0,1}},3]", "List[List[1, 3], List[0, 1]]")
  , ("MatrixPower zero", "MatrixPower[{{a,b},{c,d}},0]", "List[List[1, 0], List[0, 1]]")
  , ("MatrixPower negative", "MatrixPower[{{1,2},{3,4}},-1]", "List[List[-2, 1], List[Rational[3, 2], Rational[-1, 2]]]")
  ]

errorCases :: [(Text, Text)]
errorCases =
  [ ("Take rejects oversized positive integer", "Take[{a,b},3]")
  , ("Drop rejects oversized negative integer", "Drop[{a,b},-3]")
  , ("ArrayPad rejects ragged arrays", "ArrayPad[{{1,2},{3}},1]")
  , ("ArrayFlatten rejects inconsistent block heights", "ArrayFlatten[{{{{1}},{{2},{3}}}}]")
  , ("Transpose rejects incomplete permutations", "Transpose[{{1,2},{3,4}},{1,1}]")
  , ("UnitVector rejects invalid positions", "UnitVector[3,4]")
  , ("Tuples rejects negative repetition", "Tuples[{a,b},-1]")
  , ("Partition rejects zero block size", "Partition[{a,b},0]")
  , ("Dot rejects scalar intermediate", "Dot[{1},{2},{3}]")
  , ("Cross rejects unsupported dimension", "Cross[{1},{2}]")
  , ("Det rejects nonsquare matrices", "Det[{{1,2,3},{4,5,6}}]")
  , ("Inverse rejects singular exact matrices", "Inverse[{{1,2},{2,4}}]")
  , ("Inverse rejects singular symbolic matrices", "Inverse[{{a,a},{a,a}}]")
  , ("MatrixPower requires an integer exponent", "MatrixPower[{{1}},x]")
  , ("SparseArray rejects an empty inferred rule set", "SparseArray[{}]")
  , ("SparseArray rejects out-of-bounds rules", "SparseArray[{{3}->a},{2}]")
  , ("SparseArray Part rejects too many axes", "SparseArray[{{1}->a},{2}][[1,1]]")
  , ("Flatten rejects a negative SparseArray level", "Flatten[SparseArray[{}, {2,2}],-1]")
  , ("ArrayFlatten rejects rank-one SparseArray blocks", "ArrayFlatten[{{SparseArray[{}, {2}]}}]")
  , ("Dot rejects incompatible sparse vectors", "Dot[SparseArray[{}, {2}],SparseArray[{}, {3}]]")
  , ("Dot rejects unsupported sparse tensor ranks", "Dot[SparseArray[{}, {2,2,2}],SparseArray[{}, {2,2,2}]]")
  ]

exactErrorCases :: [(Text, Text, Text)]
exactErrorCases =
  [ ("Array rejects negative dimensions", "Array[f,-1]", "Array expects non-negative dimensions.")
  , ("Array rejects a short origin list", "Array[f,{2,3},{4}]", "Array origin list must have one entry per array dimension.")
  , ("Array rejects symbolic origins", "Array[f,{2,3},{4,x}]", "Array origin entries must be explicit integers.")
  , ("ArrayQ requires an explicit depth", "ArrayQ[{{1}},x]", "ArrayQ currently expects an explicit integer depth.")
  , ("ArrayQ validates depth for empty arrays", "ArrayQ[{},x]", "ArrayQ currently expects an explicit integer depth.")
  , ("VectorQ validates arity", "VectorQ[{1},x,y]", "VectorQ expects an expression and an optional element predicate.")
  , ("MatrixQ validates arity", "MatrixQ[{{1}},x,y]", "MatrixQ expects an expression and an optional element predicate.")
  , ("ConstantArray bounds materialization", "ConstantArray[x,1000001]", "ConstantArray output exceeds the native materialization limit.")
  , ("IdentityMatrix bounds materialization", "IdentityMatrix[1000]", "IdentityMatrix output exceeds the native materialization limit.")
  , ("ArrayReshape bounds materialization", "ArrayReshape[{1},{1000001}]", "ArrayReshape output exceeds the native materialization limit.")
  , ("ArrayPad bounds materialization", "ArrayPad[{1},500000]", "ArrayPad output exceeds the native materialization limit.")
  , ("ArrayPad reports the Python ragged-list diagnostic", "ArrayPad[{{1,2},{3}},1]", "SparseArray dense input must be rectangular.")
  , ("ArrayFlatten diagnoses an empty block row", "ArrayFlatten[{{}}]", "ArrayFlatten expects a rectangular block matrix.")
  , ("ArrayFlatten diagnoses inconsistent row heights", "ArrayFlatten[{{{{1}},{{2},{3}}}}]", "ArrayFlatten block row 1 has inconsistent heights.")
  , ("Transpose diagnoses repeated axes", "Transpose[{{1,2},{3,4}},{1,1}]", "Transpose expects a permutation of array axes.")
  , ("Transpose diagnoses malformed permutations", "Transpose[{1,2},x]", "Transpose expects a permutation list as its second argument.")
  , ("LeviCivitaTensor rejects negative dimensions", "LeviCivitaTensor[-1]", "LeviCivitaTensor expects a non-negative dimension.")
  , ("LeviCivitaTensor requires an integer dimension", "LeviCivitaTensor[x]", "LeviCivitaTensor expects an integer argument.")
  , ("LeviCivitaTensor bounds dense materialization", "LeviCivitaTensor[8]", "LeviCivitaTensor output exceeds the native materialization limit.")
  , ("LeviCivitaTensor bounds sparse materialization", "LeviCivitaTensor[9,SparseArray]", "LeviCivitaTensor sparse output exceeds the native materialization limit.")
  ]

checkValue :: (Text, Text, Text) -> IO Bool
checkValue (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left evaluationError -> failCheck label ("evaluation error: " <> showText evaluationError)
    Right result
      | fullForm result == expected -> checkSessionValue label expression expected
      | otherwise ->
          failCheck
            label
            ("expected " <> expected <> ", got " <> fullForm result)

checkSessionValue :: Text -> Expr -> Text -> IO Bool
checkSessionValue label expression expected = do
  evaluated <- evaluateInSession emptySession expression
  case evaluated of
    Left evaluationError ->
      failCheck label ("session evaluation error: " <> showText evaluationError)
    Right (result, _)
      | fullForm result == expected -> pure True
      | otherwise ->
          failCheck
            label
            ("session expected " <> expected <> ", got " <> fullForm result)

checkError :: (Text, Text) -> IO Bool
checkError (label, source) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left _ -> pure True
    Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

checkExactError :: (Text, Text, Text) -> IO Bool
checkExactError (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left (EvaluationError actual)
      | actual == expected -> pure True
      | otherwise ->
          failCheck label ("expected error " <> expected <> ", got " <> actual)
    Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

checkDirect :: Text -> Expr -> Text -> IO Bool
checkDirect label expression expected = case evaluate expression of
  Left evaluationError -> failCheck label ("evaluation error: " <> showText evaluationError)
  Right result
    | fullForm result == expected -> pure True
    | otherwise ->
        failCheck label ("expected " <> expected <> ", got " <> fullForm result)

checkDirectError :: Text -> Expr -> IO Bool
checkDirectError label expression = case evaluate expression of
  Left _ -> pure True
  Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAILED array evaluator: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
