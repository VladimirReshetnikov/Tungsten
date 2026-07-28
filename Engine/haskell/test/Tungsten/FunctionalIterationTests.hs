{-# LANGUAGE OverloadedStrings #-}

module Tungsten.FunctionalIterationTests
  ( checkFunctionalIterationEvaluator
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkFunctionalIterationEvaluator :: IO Bool
checkFunctionalIterationEvaluator = do
  values <- traverse checkValue valueCases
  sessionValues <- traverse checkSessionSource sessionCases
  errors <- traverse checkError errorCases
  pure (and (values <> sessionValues <> errors))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ( "construct applies an arbitrary callable"
    , "Construct[# + 1 &, 2]"
    , "3"
    )
  , ( "compose list preserves every stage"
    , "ComposeList[{f,g,h},x]"
    , "List[x, f[x], g[f[x]], h[g[f[x]]]]"
    )
  , ( "nest and nest list"
    , "{Nest[f,x,3],NestList[f,x,3]}"
    , "List[f[f[f[x]]], List[x, f[x], f[f[x]], f[f[f[x]]]]]"
    )
  , ( "fixed point convergence and history"
    , "{FixedPoint[#/.a->b&,a],FixedPointList[#/.a->b&,a]}"
    , "List[b, List[a, b, b]]"
    )
  , ( "fixed point explicit limit is soft"
    , "{FixedPoint[#-1&,5,2],FixedPoint[#-1&,5,0]}"
    , "List[3, 5]"
    )
  , ( "fold with and without an initial value"
    , "{Fold[f,x,{a,b,c}],Fold[Plus,{1,2,3,4}]}"
    , "List[f[f[f[x, a], b], c], 10]"
    )
  , ( "fold list with and without an initial value"
    , "{FoldList[f,x,{a,b,c}],FoldList[Plus,{1,2,3,4}]}"
    , "List[List[x, f[x, a], f[f[x, a], b], f[f[f[x, a], b], c]], List[1, 3, 6, 10]]"
    )
  , ( "qualified System dispatch and Global isolation"
    , "{System`Nest[f,x,2],System`Fold[Plus,{1,2,3}],Global`Nest[f,x,2]}"
    , "List[f[f[x]], 6, Global`Nest[f, x, 2]]"
    )
  ]

sessionCases :: [(Text, Text, Text)]
sessionCases =
  [ ( "session callbacks preserve nest side effects"
    , "n=0; {Nest[(n++;#+1)&,0,3],n}"
    , "List[3, 3]"
    )
  , ( "session callbacks preserve fold definitions"
    , "n=0; f[x_,y_]:=(n++;x+y); {Fold[f,0,{1,2,3}],n}"
    , "List[6, 3]"
    )
  , ( "session callbacks preserve fixed point effects"
    , "n=0; {FixedPoint[(n++;Min[#+1,2])&,0],n}"
    , "List[2, 3]"
    )
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ( "construct arity"
    , "Construct[]"
    , "Construct expects at least one argument."
    )
  , ( "compose list subject"
    , "ComposeList[x,0]"
    , "ComposeList expects a list or other nonatomic expression of functions."
    )
  , ( "nest count domain"
    , "Nest[f,x,-1]"
    , "Nest expects a non-negative integer iteration count."
    )
  , ( "fixed point limit domain"
    , "FixedPoint[f,x,-1]"
    , "FixedPoint expects a non-negative maximum iteration count."
    )
  , ( "fold empty sequence"
    , "Fold[f,{}]"
    , "Fold[f, expr] expects a nonempty sequence."
    )
  ]

checkValue :: (Text, Text, Text) -> IO Bool
checkValue (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left evaluationError -> failCheck label ("evaluation error: " <> showText evaluationError)
    Right pureResult
      | fullForm pureResult /= expected ->
          failCheck label ("expected " <> expected <> ", got " <> fullForm pureResult)
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
          failCheck
            label
            ("session expected " <> expected <> ", got " <> fullForm result)

checkSessionSource :: (Text, Text, Text) -> IO Bool
checkSessionSource (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> checkSessionValue label expression expected

checkError :: (Text, Text, Text) -> IO Bool
checkError (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left (EvaluationError message)
      | message == expected -> pure True
      | otherwise ->
          failCheck label ("expected error " <> expected <> ", got " <> message)
    Right result ->
      failCheck label ("expected an evaluation error, got " <> fullForm result)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAILED functional iteration evaluator: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
