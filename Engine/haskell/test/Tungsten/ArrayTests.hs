{-# LANGUAGE OverloadedStrings #-}

module Tungsten.ArrayTests (checkArrayEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (evaluate)
import Tungsten.Expression (Expr (..), fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkArrayEvaluator :: IO Bool
checkArrayEvaluator = do
  valueResults <- traverse checkValue valueCases
  errorResults <- traverse checkError errorCases
  sparseResults <- sequence
    [ checkDirect
        "Dimensions preserves compact SparseArray dimensions"
        (Call (Symbol "Dimensions") [SparseArray [2, 3] [] (Integer 0)])
        "List[2, 3]"
    , checkDirect
        "ArrayDepth uses compact SparseArray rank"
        (Call (Symbol "ArrayDepth") [SparseArray [2, 3] [] (Integer 0)])
        "2"
    , checkDirectError
        "dense matrix reducers reject SparseArray inputs explicitly"
        (Call (Symbol "Det") [SparseArray [2, 2] [] (Integer 0)])
    ]
  pure (and (valueResults <> errorResults <> sparseResults))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("Dimensions ragged common prefix", "Dimensions[{{1,2},{3}}]", "List[2]")
  , ("Dimensions rectangular", "Dimensions[{{1,2},{3,4}}]", "List[2, 2]")
  , ("Dimensions empty List", "Dimensions[{}]", "List[0]")
  , ("ArrayDepth follows List branches", "ArrayDepth[{1,{2,{3}}}]", "3")
  , ("ArrayDepth ignores non-List calls", "ArrayDepth[f[{1,2}]]", "0")
  , ("ConstantArray rectangular", "ConstantArray[x,{2,3}]", "List[List[x, x, x], List[x, x, x]]")
  , ("ConstantArray filters Nothing", "ConstantArray[Nothing,3]", "List[]")
  , ("nested ConstantArray filters Nothing per List", "ConstantArray[Nothing,{2,2}]", "List[List[], List[]]")
  , ("ArrayReshape flattens and pads", "ArrayReshape[{{1,2},{3,4}},{3,2},x]", "List[List[1, 2], List[3, 4], List[x, x]]")
  , ("ArrayReshape scalar shape", "ArrayReshape[{1,2},{}]", "1")
  , ("ArrayReshape empty scalar shape uses fill", "ArrayReshape[{},{},x]", "x")
  , ("ArrayPad per-axis widths", "ArrayPad[{{1,2},{3,4}},{{1,0},{0,1}},x]", "List[List[x, x, x], List[1, 2, x], List[3, 4, x]]")
  , ("ArrayPad rank-one asymmetric shorthand", "ArrayPad[{1,2},{1,2},x]", "List[x, 1, 2, x, x]")
  , ("ArrayFlatten block matrix", "ArrayFlatten[{{{{1,2},{3,4}},{{5},{6}}},{{{7,8}},{{9}}}}]", "List[List[1, 2, 5], List[3, 4, 6], List[7, 8, 9]]")
  , ("ArrayFlatten empty block rows", "ArrayFlatten[{}]", "List[]")
  , ("Transpose matrix", "Transpose[{{1,2,3},{4,5,6}}]", "List[List[1, 4], List[2, 5], List[3, 6]]")
  , ("Transpose rank-three permutation", "Transpose[{{{a,b},{c,d}},{{e,f},{g,h}}},{3,1,2}]", "List[List[List[a, c], List[e, g]], List[List[b, d], List[f, h]]]")
  , ("Transpose vector identity", "Transpose[{a,b,c}]", "List[a, b, c]")
  , ("UnitVector", "UnitVector[5,3]", "List[0, 0, 1, 0, 0]")
  , ("IdentityMatrix", "IdentityMatrix[3]", "List[List[1, 0, 0], List[0, 1, 0], List[0, 0, 1]]")
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
checkSessionValue label expression expected = case evaluateInSession emptySession expression of
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
