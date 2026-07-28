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
import Tungsten.Session
  ( EvaluationMessage (evaluationMessageText)
  , EvaluationSession (sessionVisibleMessages)
  , emptySession
  , evaluateInSession
  )

checkFunctionalIterationEvaluator :: IO Bool
checkFunctionalIterationEvaluator = do
  values <- traverse checkValue valueCases
  sessionValues <- traverse checkSessionSource sessionCases
  errors <- traverse checkError errorCases
  sessionErrors <- traverse checkSessionError sessionErrorCases
  pure (and (values <> sessionValues <> errors <> sessionErrors))

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
  , ( "comap direct and operator forms rebuild nonatomic collections"
    , "{Comap[{#+1&,f},2],Comap[{f,g}][x],ComapApply[{f,g},h[x,y]],ComapApply[{f,g}][h[x,y]],ComapApply[{f,g},<|a->x,b:>y|>],Comap[f,x],ComapApply[{f,g},x],Comap[foo[f,g],x],Comap[<|a->f,b:>g|>,x]}"
    , "List[List[3, f[2]], List[f[x], g[x]], List[f[x, y], g[x, y]], List[f[x, y], g[x, y]], List[f[x, y], g[x, y]], f, List[x, x], foo[f[x], g[x]], Association[Rule[a, f[x]], RuleDelayed[b, g[x]]]]"
    )
  , ( "comap preserves Nothing boundaries by collection head"
    , "{Comap[{Nothing,f},x],ComapApply[{Nothing,f},h[x,y]],Comap[foo[Nothing,f],x],Comap[Association[a->Nothing,b->f],x]}"
    , "List[List[f[x]], List[f[x, y]], foo[Nothing, f[x]], Association[Rule[a, Nothing], Rule[b, f[x]]]]"
    )
  , ( "comap qualified System dispatch and Global isolation"
    , "{System`Comap[{f,g},x],System`ComapApply[{f,g}][h[x,y]],Global`Comap[{f,g},x],Global`Comap[{f,g}][x]}"
    , "List[List[f[x], g[x]], List[f[x, y], g[x, y]], Global`Comap[List[f, g], x], Global`Comap[List[f, g]][x]]"
    )
  , ( "nest and nest list"
    , "{Nest[f,x,3],NestList[f,x,3]}"
    , "List[f[f[f[x]]], List[x, f[x], f[f[x]], f[f[f[x]]]]]"
    )
  , ( "fixed point convergence and history"
    , "{FixedPoint[#/.a->b&,a],FixedPointList[#/.a->b&,a]}"
    , "List[b, List[a, b, b]]"
    )
  , ( "nest while and nest while list"
    , "{NestWhile[#+1&,0,#<3&],NestWhileList[#+1&,0,#<3&]}"
    , "List[3, List[0, 1, 2, 3]]"
    )
  , ( "nest while history and maximum controls"
    , "{NestWhile[#/2&,100,#>1&,2],NestWhileList[#+1&,0,#<10&,1,3]}"
    , "List[Rational[25, 64], List[0, 1, 2, 3]]"
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
  , ( "fold while retains the first failing result"
    , "{FoldWhile[Plus,0,{1,2,3,4},#<4&],FoldWhileList[Plus,0,{1,2,3,4},#<4&]}"
    , "List[6, List[0, 1, 3, 6]]"
    )
  , ( "fold while history and trailing controls"
    , "{FoldWhileList[Plus,0,{1,2,3,4},Length[{##}]<2||Last[{##}]<4&,2],FoldWhileList[Plus,0,{1,2,3,4},Length[{##}]<4&,All],FoldWhileList[Plus,0,{1,2,3,4,5},#<4&,1,2],FoldWhileList[Plus,0,{1,2,3,4},#<4&,1,-1],FoldWhileList[Plus,0,{1,2,3,4},#<4&,1,-99]}"
    , "List[List[0, 1, 3, 6], List[0, 1, 3, 6], List[0, 1, 3, 6, 10, 15], List[0, 1, 3], List[0]]"
    )
  , ( "fold while skips unused trailing-count validation"
    , "{FoldWhileList[Plus,99,{1,2},False&,1,x],FoldWhileList[Plus,0,{1,2},True&,1,x]}"
    , "List[List[99], List[0, 1, 3]]"
    )
  , ( "fold while filters Nothing results before selecting its output"
    , "{FoldWhile[Function[{y,x},Nothing],0,{1},True&],FoldWhileList[Function[{y,x},Nothing],0,{1},True&]}"
    , "List[0, List[0]]"
    )
  , ( "fold pair result, history, projection, and state"
    , "{FoldPair[{#1+#2,#1-#2}&,10,{1,2,3}],FoldPairList[{#1+#2,#1-#2}&,10,{1,2,3}],FoldPairList[{#1+#2,#1-#2}&,10,{1,2,3},Last]}"
    , "List[10, List[11, 11, 10], List[9, 7, 4]]"
    )
  , ( "fold pair empty input remains inert"
    , "{FoldPair[f,x,{}],FoldPairList[f,x,{}],FoldPair[f,x,h[]],FoldPairList[f,x,h[]]}"
    , "List[FoldPair[f, x, List[]], List[], FoldPair[f, x, h[]], List[]]"
    )
  , ( "fold pair filters Nothing projections before selecting a result"
    , "{FoldPair[List,0,{1},Nothing&],FoldPairList[List,0,{1},Nothing&]}"
    , "List[FoldPair[List, 0, List[1], Function[Nothing]], List[]]"
    )
  , ( "qualified System dispatch and Global isolation"
    , "{System`Nest[f,x,2],System`Fold[Plus,{1,2,3}],System`FoldWhile[Plus,0,{1,2,3},#<3&],System`FoldPair[{#1+#2,#1-#2}&,10,{1,2}],Global`Nest[f,x,2],Global`FoldWhile[f,x,{a},True&],Global`FoldPair[f,x,{a}]}"
    , "List[f[f[x]], 6, 3, 11, Global`Nest[f, x, 2], Global`FoldWhile[f, x, List[a], Function[True]], Global`FoldPair[f, x, List[a]]]"
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
  , ( "session comap callbacks preserve definitions effects and Nothing"
    , "ClearAll[f,g,c]; c=0; f[x_]:=(c++;x+1); g[x___]:=(c++;HoldComplete[x]); {Comap[{f,g},3],Comap[{f,g}][4],ComapApply[{g,g},h[a,b]],Comap[{(c++;Nothing)&,f},5],c}"
    , "List[List[4, HoldComplete[3]], List[5, HoldComplete[4]], List[HoldComplete[a, b], HoldComplete[a, b]], List[6], 8]"
    )
  , ( "session callbacks preserve fixed point effects"
    , "n=0; {FixedPoint[(n++;Min[#+1,2])&,0],n}"
    , "List[2, 3]"
    )
  , ( "session callbacks preserve nest while effects"
    , "n=0;t=0; {NestWhile[(n++;#+1)&,0,(t++;#<3)&],NestWhileList[(n++;#+1)&,0,(t++;#<3)&],n,t}"
    , "List[3, List[0, 1, 2, 3], 6, 8]"
    )
  , ( "session callbacks preserve fold while effects"
    , "n=0;t=0; f[x_,y_]:=(n++;x+y); q[x___]:=(t++;Last[{x}]<4); {FoldWhileList[f,0,{1,2,3,4,5},q,All,1],n,t}"
    , "List[List[0, 1, 3, 6, 10], 4, 4]"
    )
  , ( "session callbacks and projections preserve fold pair effects"
    , "c=0;p=0; f[y_,x_]:=(c++;{y+x,y-x}); q[pair_]:=(p++;Last[pair]); {FoldPairList[f,10,{1,2,3},q],FoldPair[f,10,{1,2},q],c,p}"
    , "List[List[9, 7, 4], 7, 5, 5]"
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
  , ( "comap arity"
    , "Comap[]"
    , "Comap expects exactly two arguments."
    )
  , ( "comap apply operator arity"
    , "ComapApply[{f,g}][x,y]"
    , "ComapApply[functions] expects exactly one argument when used as an operator."
    )
  , ( "nest count domain"
    , "Nest[f,x,-1]"
    , "Nest expects a non-negative integer iteration count."
    )
  , ( "fixed point limit domain"
    , "FixedPoint[f,x,-1]"
    , "FixedPoint expects a non-negative maximum iteration count."
    )
  , ( "nest while history domain"
    , "NestWhile[f,x,True,0]"
    , "NestWhile history size must be a positive integer or All."
    )
  , ( "fold empty sequence"
    , "Fold[f,{}]"
    , "Fold[f, expr] expects a nonempty sequence."
    )
  , ( "fold while arity"
    , "FoldWhile[f,0,{1}]"
    , "FoldWhile currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
    )
  , ( "fold while atomic input"
    , "FoldWhile[f,0,x,True&]"
    , "FoldWhileList expects a nonatomic expression."
    )
  , ( "fold while history domain"
    , "FoldWhileList[Plus,0,{1},True&,0]"
    , "FoldWhileList expects a positive history length or All."
    )
  , ( "fold while trailing count domain"
    , "FoldWhileList[Plus,0,{1},#<1&,1,x]"
    , "FoldWhileList expects an integer argument."
    )
  , ( "fold pair arity"
    , "FoldPair[f,x]"
    , "FoldPair currently supports a function, an initial value, inputs, and an optional projection."
    )
  , ( "fold pair callback shape"
    , "FoldPairList[f,0,{1}]"
    , "FoldPairList expects each function application to return a list of two elements, got f[0, 1]."
    )
  ]

sessionErrorCases :: [(Text, Text, Text, Text)]
sessionErrorCases =
  [ ( "session comap direct arity"
    , "Comap[]"
    , "Comap[]"
    , "Comap::error: Comap expects exactly two arguments."
    )
  , ( "session comap operator arity"
    , "Comap[{f,g}][x,y]"
    , "Comap[List[f, g]][x, y]"
    , "General::error: Comap[functions] expects exactly one argument when used as an operator."
    )
  , ( "session fold while preserves effects before a trailing-count failure"
    , "n=0;t=0; f[x_,y_]:=(n++;x+y); q[x_]:=(t++;x<1); {FoldWhileList[f,0,{1},q,1,x],n,t}"
    , "List[FoldWhileList[f, 0, List[1], q, 1, x], 1, 2]"
    , "FoldWhileList::error: FoldWhileList expects an integer argument."
    )
  , ( "session fold pair callback shape"
    , "n=0; f[y_,x_]:=(n++; y+x); {FoldPairList[f,0,{1}],n}"
    , "List[FoldPairList[f, 0, List[1]], 1]"
    , "FoldPairList::error: FoldPairList expects each function application to return a list of two elements, got 1."
    )
  , ( "session fold pair atomic input"
    , "FoldPair[f,0,x]"
    , "FoldPair[f, 0, x]"
    , "FoldPair::error: FoldPairList expects a nonatomic expression."
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

checkSessionError :: (Text, Text, Text, Text) -> IO Bool
checkSessionError (label, source, expectedResult, expectedMessage) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> do
    evaluated <- evaluateInSession emptySession expression
    case evaluated of
      Left evaluationError ->
        failCheck label ("unexpected terminal session error: " <> showText evaluationError)
      Right (result, updated)
        | fullForm result /= expectedResult ->
            failCheck label ("expected inert result " <> expectedResult <> ", got " <> fullForm result)
        | otherwise -> case reverse (sessionVisibleMessages updated) of
            message : _
              | evaluationMessageText message == expectedMessage -> pure True
              | otherwise ->
                  failCheck
                    label
                    ( "expected session message "
                        <> expectedMessage
                        <> ", got "
                        <> evaluationMessageText message
                    )
            [] -> failCheck label "expected a recovered session evaluation message"

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAILED functional iteration evaluator: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
