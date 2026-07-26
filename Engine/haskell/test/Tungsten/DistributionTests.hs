{-# LANGUAGE OverloadedStrings #-}

module Tungsten.DistributionTests (checkDistributionEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkDistributionEvaluator :: IO Bool
checkDistributionEvaluator = do
  values <- traverse checkValue valueCases
  errors <- traverse checkError errorCases
  pure (and (values <> errors))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("default median quantile", "Quantile[{1,2,3,4,5},1/2]", "3")
  , ("default lower quantile", "Quantile[{1,2,3,4,5},1/4]", "2")
  , ("integer quantile position", "Quantile[{1,2,3,4,5,6},1/2]", "3")
  , ("quantile list threading", "Quantile[{1,2,3,4,5},{1/4,1/2,3/4}]", "List[2, 3, 4]")
  , ("type seven interpolation", "Quantile[Range[10],1/2,{{1/2,0},{0,1}}]", "Rational[11, 2]")
  , ("quartiles even sample", "Quartiles[Range[10]]", "List[3, Rational[11, 2], 8]")
  , ("quartiles odd sample", "Quartiles[{1,2,3,4,5}]", "List[Rational[7, 4], 3, Rational[17, 4]]")
  , ("explicit bin counts", "BinCounts[Range[10],{0,10,2}]", "List[1, 2, 2, 2, 2]")
  , ("source real bin counts", "BinCounts[{1.1,2.5,3.7,4.0},{0,5,1}]", "List[0, 1, 1, 1, 1]")
  , ("automatic bin bounds", "BinCounts[Range[10],2]", "List[1, 2, 2, 2, 2, 1]")
  , ("bin lists preserve values", "BinLists[Range[10],{0,10,2}]", "List[List[1], List[2, 3], List[4, 5], List[6, 7], List[8, 9]]")
  , ("canonical cycles", "PermutationCycles[{2,3,1,4}]", "Cycles[List[List[1, 2, 3]]]")
  , ("multiple canonical cycles", "PermutationCycles[{3,1,2,5,4}]", "Cycles[List[List[1, 3, 2], List[4, 5]]]")
  , ("cycle list with explicit length", "PermutationList[Cycles[{{1,2,3}}],4]", "List[2, 3, 1, 4]")
  , ("two transpositions", "PermutationList[Cycles[{{1,2},{3,4}}],4]", "List[2, 1, 4, 3]")
  , ("inferred permutation length", "PermutationList[Cycles[{{2,4}}]]", "List[1, 4, 3, 2]")
  , ("empty permutation", "PermutationList[Cycles[{}]]", "List[]")
  , ("permutation order", "PermutationOrder[Cycles[{{1,2,3,4,5},{6,7}}]]", "10")
  , ("identity permutation order", "PermutationOrder[Cycles[{}]]", "1")
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ("empty quantile", "Quantile[{},1/2]", "Quantile of an empty list is undefined.")
  , ("symbolic quantile data", "Quantile[{1,x},1/2]", "Quantile currently expects explicit real-valued numbers.")
  , ("quantile parameter shape", "Quantile[{1,2},1/2,{1,2}]", "Quantile parameters must be a list ``{{a, b}, {c, d}}``.")
  , ("empty automatic bins", "BinCounts[{},2]", "BinCounts cannot infer auto bin bounds from an empty list.")
  , ("malformed bin spec", "BinLists[{1,2},{0,2}]", "BinLists expects a bin spec ``dx`` or ``{xmin, xmax, dx}``.")
  , ("nonpositive bin width", "BinCounts[{1,2},{0,2,0}]", "BinCounts requires xmax > xmin and a positive bin width.")
  , ("short permutation length", "PermutationList[Cycles[{{1,3}}],2]", "PermutationList length is shorter than the largest cycle entry.")
  , ("overlapping cycles", "PermutationOrder[Cycles[{{1,2},{2,3}}]]", "PermutationOrder: cycle entries must be disjoint.")
  , ("invalid permutation list", "PermutationCycles[{1,1}]", "PermutationCycles expects a permutation of {1, …, n}.")
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
