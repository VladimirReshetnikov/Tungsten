{-# LANGUAGE OverloadedStrings #-}

module Tungsten.IntervalTests (checkIntervalEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkIntervalEvaluator :: IO Bool
checkIntervalEvaluator = and <$> traverse checkValue valueCases

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("empty interval", "Interval[]", "Interval[]")
  , ("singleton interval", "Interval[3]", "Interval[List[3, 3]]")
  , ("reversed interval", "Interval[{3,1}]", "Interval[List[1, 3]]")
  , ("overlapping intervals", "Interval[{1,3},{2,5}]", "Interval[List[1, 5]]")
  , ("disjoint intervals sort", "Interval[{3,4},{1,2}]", "Interval[List[1, 2], List[3, 4]]")
  , ("symbolic intervals stay inert", "Interval[{a,b}]", "Interval[List[a, b]]")
  , ("infinite intervals merge", "Interval[{-Infinity,0},{0,Infinity}]", "Interval[List[Times[-1, Infinity], Infinity]]")
  , ("source real endpoints compare exactly", "Interval[{1.,3/2}]", "Interval[List[1., Rational[3, 2]]]")
  , ("empty interval union", "IntervalUnion[]", "Interval[]")
  , ("touching interval union", "IntervalUnion[Interval[{1,2}],Interval[{2,4}]]", "Interval[List[1, 4]]")
  , ("disjoint interval union", "IntervalUnion[Interval[{3,4}],Interval[{1,2}]]", "Interval[List[1, 2], List[3, 4]]")
  , ("empty interval intersection", "IntervalIntersection[]", "Interval[]")
  , ("overlapping interval intersection", "IntervalIntersection[Interval[{1,3}],Interval[{2,5}]]", "Interval[List[2, 3]]")
  , ("disjoint interval intersection", "IntervalIntersection[Interval[{1,2}],Interval[{3,4}]]", "Interval[]")
  , ("point intersections", "IntervalIntersection[Interval[{1,2},{4,5}],Interval[{2,4}]]", "Interval[List[2, 2], List[4, 4]]")
  , ("scalar membership", "IntervalMemberQ[Interval[{1,3}],2]", "True")
  , ("vectorized membership", "IntervalMemberQ[Interval[{1,3}],{1,4}]", "List[True, False]")
  , ("subinterval membership", "IntervalMemberQ[Interval[{1,3}],Interval[{2,3}]]", "True")
  , ("empty subinterval membership", "IntervalMemberQ[Interval[],Interval[]]", "True")
  , ("symbolic membership", "IntervalMemberQ[Interval[{1,3}],x]", "False")
  , ("invalid container membership", "IntervalMemberQ[x,1]", "False")
  , ("malformed membership stays inert", "IntervalMemberQ[Interval[{1,3}]]", "IntervalMemberQ[Interval[List[1, 3]]]")
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

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAIL: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
