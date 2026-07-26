{-# LANGUAGE OverloadedStrings #-}

module Tungsten.CollectionExtensionsTests (checkCollectionExtensions) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkCollectionExtensions :: IO Bool
checkCollectionExtensions = do
  values <- traverse checkValue valueCases
  errors <- traverse checkError errorCases
  pure (and (values <> errors))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("default clip below", "Clip[-3]", "-1")
  , ("explicit clip above", "Clip[9,{-5,5}]", "5")
  , ("clip replacement", "Clip[-7,{-5,5},{100,200}]", "100")
  , ("clip retains source real", "Clip[1.25,{0,2}]", "1.25")
  , ("adjacent split", "Split[{a,a,b,b,a}]", "List[List[a, a], List[b, b], List[a]]")
  , ("split by parity", "SplitBy[{1,3,2,4,5},EvenQ]", "List[List[1, 3], List[2, 4], List[5]]")
  , ("custom split test", "Split[{1,3,2,4},SameQ[Mod[#1,2],Mod[#2,2]]&]", "List[List[1, 3], List[2, 4]]")
  , ("delete adjacent duplicates", "DeleteAdjacentDuplicates[{a,a,b,a,a}]", "List[a, b, a]")
  , ("fixed subsequences", "Subsequences[{a,b,c},{2}]", "List[List[a, b], List[b, c]]")
  , ("subsequence range", "Subsequences[{a,b,c},{0,2}]", "List[List[], List[a], List[b], List[c], List[a, b], List[b, c]]")
  , ("alphabetic sort", "AlphabeticSort[{\"beta\",\"Alpha\",\"gamma\"}]", "List[\"Alpha\", \"beta\", \"gamma\"]")
  , ("natural numeric sort", "NumericalSort[{\"x10\",\"x2\",\"x1\"}]", "List[\"x1\", \"x2\", \"x10\"]")
  , ("lexicographic order less", "LexicographicOrder[{1,2},{1,3}]", "1")
  , ("lexicographic order equal", "LexicographicOrder[{1,2},{1,2}]", "0")
  , ("lexicographic order greater", "LexicographicOrder[{1,3},{1,2}]", "-1")
  , ("lexicographic string prefix", "LexicographicOrder[\"a\",\"aa\"]", "1")
  , ("lexicographic sort", "LexicographicSort[{{1,3},{1,2},{0,9}}]", "List[List[0, 9], List[1, 2], List[1, 3]]")
  , ("delete duplicates", "DeleteDuplicates[{a,b,a,c,b}]", "List[a, b, c]")
  , ("delete duplicates by", "DeleteDuplicatesBy[{{a},{b,c},{d},{e,f}},Length]", "List[List[a], List[b, c]]")
  , ("delete duplicates custom test", "DeleteDuplicatesBy[{1,2,3,4,5,6},Mod[#,3]&,SameQ]", "List[1, 2, 3]")
  , ("association value duplicates", "DeleteDuplicates[<|a->1,b->1,c->2|>]", "Association[Rule[a, 1], Rule[c, 2]]")
  , ("duplicate free true", "DuplicateFreeQ[{a,b,c}]", "True")
  , ("duplicate free false", "DuplicateFreeQ[{a,b,a}]", "False")
  , ("contains only", "ContainsOnly[{1,2,3},{1,2,3,4}]", "True")
  , ("contains only false", "ContainsOnly[{1,2,5},{1,2,3,4}]", "False")
  , ("contains only same test", "ContainsOnly[{1.0,2},{1,2,3},SameTest->Equal]", "True")
  , ("counts by", "CountsBy[{1.5,1.7,1.9,2.5,3.7},Floor]", "Association[Rule[1, 3], Rule[2, 1], Rule[3, 1]]")
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ("clip requires numeric input", "Clip[x]", "Clip currently evaluates only for explicit real numeric arguments.")
  , ("clip validates bounds", "Clip[1,{0}]", "Clip currently expects bounds of the form {min, max}.")
  , ("subsequence spec", "Subsequences[{a,b},{0,1,2}]", "Subsequences currently supports n, {n}, or {min, max} length specs.")
  , ("alphabetic sort atom", "AlphabeticSort[x]", "AlphabeticSort expects a compound expression")
  , ("contains only arity", "ContainsOnly[{1}]", "ContainsOnly expects two arguments and an optional SameTest rule.")
  ]

checkValue :: (Text, Text, Text) -> IO Bool
checkValue (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left evaluationError -> failCheck label ("evaluation error: " <> showText evaluationError)
    Right result
      | fullForm result /= expected ->
          failCheck label ("expected " <> expected <> ", got " <> fullForm result)
      | otherwise -> checkSessionValue label expression expected

checkSessionValue :: Text -> Expr -> Text -> IO Bool
checkSessionValue label expression expected = do
  evaluated <- evaluateInSession emptySession expression
  case evaluated of
    Left evaluationError ->
      failCheck label ("session evaluation error: " <> showText evaluationError)
    Right (result, _)
      | fullForm result == expected -> pure True
      | otherwise ->
          failCheck label ("session expected " <> expected <> ", got " <> fullForm result)

checkError :: (Text, Text, Text) -> IO Bool
checkError (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left (EvaluationError message)
      | message == expected -> pure True
      | otherwise -> failCheck label ("expected error " <> expected <> ", got " <> message)
    Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAIL: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
