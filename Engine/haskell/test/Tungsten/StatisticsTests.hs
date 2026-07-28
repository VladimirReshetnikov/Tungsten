{-# LANGUAGE OverloadedStrings #-}

module Tungsten.StatisticsTests (checkStatisticsEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkStatisticsEvaluator :: IO Bool
checkStatisticsEvaluator = do
  values <- traverse checkValue valueCases
  errors <- traverse checkError errorCases
  pure (and (values <> errors))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("sample variance", "Variance[{1,2,3,4,5}]", "Rational[5, 2]")
  , ("symbolic sample variance", "Variance[{a,b}]", "Plus[Power[Plus[a, Times[Rational[-1, 2], Plus[a, b]]], 2], Power[Plus[b, Times[Rational[-1, 2], Plus[a, b]]], 2]]")
  , ("standard deviation", "StandardDeviation[{1,2,3,4,5}]", "Power[Rational[5, 2], Rational[1, 2]]")
  , ("Euclidean norm", "Norm[{3,4}]", "5")
  , ("explicit p norm", "Norm[{1,2,3},2]", "Power[14, Rational[1, 2]]")
  , ("infinity norm", "Norm[{1,-2,3},Infinity]", "3")
  , ("empty norm", "Norm[{}]", "0")
  , ("empty p norm", "Norm[{},3]", "0")
  , ("minimum and maximum", "MinMax[{3,1,4,1,5,9,2,6}]", "List[1, 9]")
  , ("empty min max identities", "MinMax[{}]", "List[Infinity, Times[-1, Infinity]]")
  , ("symbolic min max", "MinMax[{a,b}]", "List[Min[a, b], Max[a, b]]")
  , ("ranked minimum keeps duplicates", "RankedMin[{3,1,4,1,5,9,2,6},2]", "1")
  , ("negative ranked minimum", "RankedMin[{3,1,4,1},-1]", "4")
  , ("ranked maximum", "RankedMax[{3,1,4,1,5,9,2,6},2]", "6")
  , ("negative ranked maximum", "RankedMax[{3,1,4,1},-1]", "1")
  , ("mode", "Mode[{1,1,2,3,3,3,4}]", "3")
  , ("mode canonical tie", "Mode[{a,a,b,c,c}]", "a")
  , ("empty mode remains inert", "Mode[{}]", "Mode[List[]]")
  , ("distinct list values", "CountDistinct[{1,2,2,3}]", "3")
  , ("distinct association values", "CountDistinct[<|a->1,b->1,c->2|>]", "2")
  , ("numeric ratios", "Ratios[{1,2,4,8,16}]", "List[2, 2, 2, 2]")
  , ("symbolic ratios", "Ratios[{a,b,c}]", "List[Times[b, Power[a, -1]], Times[c, Power[b, -1]]]")
  , ("empty ratios", "Ratios[{}]", "List[]")
  , ("singleton ratios", "Ratios[{42}]", "List[]")
  , ("unit subdivision", "Subdivide[4]", "List[0, Rational[1, 4], Rational[1, 2], Rational[3, 4], 1]")
  , ("scaled subdivision", "Subdivide[10,4]", "List[0, Rational[5, 2], 5, Rational[15, 2], 10]")
  , ("bounded subdivision", "Subdivide[1,10,4]", "List[1, Rational[13, 4], Rational[11, 2], Rational[31, 4], 10]")
  , ("symbolic scaled subdivision", "Subdivide[x,4]", "List[0, Times[Rational[1, 4], x], Times[Rational[1, 2], x], Times[Rational[3, 4], x], x]")
  , ("symbolic bounded subdivision", "Subdivide[a,b,2]", "List[a, Plus[a, Times[Rational[1, 2], Plus[b, Times[-1, a]]]], b]")
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ("variance needs two values", "Variance[{1}]", "Variance requires at least two elements.")
  , ("variance validates arity", "Variance[]", "Variance currently expects exactly one argument.")
  , ("standard deviation validates arity", "StandardDeviation[]", "StandardDeviation currently expects exactly one argument.")
  , ("norm rejects atoms", "Norm[x]", "Norm expects a nonatomic expression.")
  , ("norm validates p", "Norm[{1},0]", "Norm currently expects a positive integer p or Infinity.")
  , ("rank rejects zero", "RankedMin[{1},0]", "RankedMin rank 0 is out of range for a list of length 1.")
  , ("rank requires an integer", "RankedMax[{1},x]", "RankedMax expects an explicit integer rank.")
  , ("subdivide requires positive count", "Subdivide[0]", "Subdivide expects a positive integer count.")
  , ("subdivide validates arity", "Subdivide[]", "Subdivide expects 1, 2, or 3 arguments.")
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
