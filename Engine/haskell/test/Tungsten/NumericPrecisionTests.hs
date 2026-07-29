{-# LANGUAGE OverloadedStrings #-}

module Tungsten.NumericPrecisionTests
  ( checkNumericPrecisionEvaluator
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkNumericPrecisionEvaluator :: IO Bool
checkNumericPrecisionEvaluator = do
  values <- traverse checkValue valueCases
  sessions <- traverse checkSessionSource sessionCases
  pure (and (values <> sessions))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ( "N exact and named constants at 20 30 and 50 digits"
    , "{N[1/3],N[1/3,20],N[Pi,20],N[Pi,WorkingPrecision->30],N[Pi,50],N[E,50],N[EulerGamma,50],N[Catalan,50],N[GoldenRatio,50],N[Degree,50]}"
    , "List[0.3333333333333333, 0.33333333333333333333`20., 3.1415926535897932385`20., 3.14159265358979323846264338328`30., 3.1415926535897932384626433832795028841971693993751`50., 2.7182818284590452353602874713526624977572470937000`50., 0.57721566490153286060651209008240243104215933593992`50., 0.91596559417721901505460351493238411077414937428167`50., 1.6180339887498948482045868343656381177203091798058`50., 0.017453292519943295769236907684886127134428718885417`50.]"
    )
  , ( "N transcendental complex and algebraic branches"
    , "{N[Sin[Pi/6],20],N[Gudermannian[1],30],N[ArcCoth[2],30],N[Log[-1],20],N[Root[#^3-2&,1],30]}"
    , "List[0.5`20., 0.865769483239658624289601846192`30., 0.549306144334054845697622618461`30., Complex[0.`20., 3.1415926535897932385`20.], 1.25992104989487316476721060728`30.]"
    )
  , ( "N preserves existing inexact precision and recurses structurally"
    , "{N[1.2,50],N[Sin[1.2],50],N[Sin[1.2`20],50],N[Complex[1,2],20],N[Overflow[],20],N[{1/3,Pi,f[1/2]},20]}"
    , "List[1.2, 0.9320390859672264, 0.93203908596722634967`20., Complex[1.`20., 2.`20.], Overflow[], List[0.33333333333333333333`20., 3.1415926535897932385`20., f[0.5`20.]]]"
    )
  , ( "N options arity invalid precision and diagnostic-free recovery"
    , "{N[],N[Pi,20,30],N[Pi,x],N[Pi,2,WorkingPrecision->30,AccuracyGoal->25,foo->50],N[Pi,WorkingPrecision->Automatic],N[Pi,WorkingPrecision->x],N[Pi,20,x->1,30],N[Pi,20,x]}"
    , "List[N[], N[Pi, 20, 30], 3.141592653589793, 3.14159265358979323846264338328`30., 3.141592653589793, 3.141592653589793, N[Pi, 20, Rule[x, 1], 30], N[Pi, 20, x]]"
    )
  , ( "numeric precision qualification and Unevaluated transparency"
    , "{System`N[Pi,20],Global`N[Pi,20],N[Unevaluated[Pi],20],System`SetPrecision[1/3,20],Global`SetAccuracy[1/3,20]}"
    , "List[3.1415926535897932385`20., Global`N[Pi, 20], 3.1415926535897932385`20., 0.33333333333333333333`20., Global`SetAccuracy[Rational[1, 3], 20]]"
    )
  , ( "SetPrecision finite machine infinity recursive and raw boundaries"
    , "{SetPrecision[1/3,20],SetPrecision[1.,20],SetPrecision[1.,MachinePrecision],SetPrecision[1.25,Infinity],SetPrecision[f[1/3,1.20`7],20],SetPrecision[f[1.25],Infinity],SetPrecision[Pi,20],SetPrecision[1/3,x],SetPrecision[1/3,-2]}"
    , "List[0.33333333333333333333`20., 1.`20., 1., Rational[5, 4], f[0.33333333333333333333`20., 1.20`20.], f[Rational[5, 4]], Pi, SetPrecision[Rational[1, 3], x], 0.3`1.]"
    )
  , ( "SetAccuracy finite infinity recursive and raw boundaries"
    , "{SetAccuracy[1/3,20],SetAccuracy[1.23,20],SetAccuracy[f[1/3,1.20`7],20],SetAccuracy[f[1.25],Infinity],SetAccuracy[Pi,20],SetAccuracy[1/3,x],SetAccuracy[1/3,-2]}"
    , "List[0.3333333333333333333333333333``20., 1.23``20., f[0.3333333333333333333333333333``20., 1.20``20.], f[Rational[5, 4]], Pi, SetAccuracy[Rational[1, 3], x], 0.3333333333333333``0.]"
    )
  , ( "N singular numeric values retain Python symbolic outcomes"
    , "{N[Log[0],20],N[ArcTanh[1],20],N[ArcCoth[-1],20],N[Cot[0],20],N[Csc[0],20]}"
    , "List[-Infinity, Infinity, -Infinity, ComplexInfinity, ComplexInfinity]"
    )
  , ( "precision requests beyond the constructive allocation bound recover raw"
    , "{N[Pi,100001],N[Pi,WorkingPrecision->100001],SetPrecision[1/3,100001],SetAccuracy[1/3,100001]}"
    , "List[N[Pi, 100001], N[Pi, Rule[WorkingPrecision, 100001]], SetPrecision[Rational[1, 3], 100001], SetAccuracy[Rational[1, 3], 100001]]"
    )
  , ( "constructive formatting preserves underflowed real and complex components"
    , "{N[Exp[-1000],20],N[Exp[Complex[0,1/10^400]],50]}"
    , underflowAndTinyComplexExpected
    )
  , ( "ordinary inexact transcendental calls use the numeric bridge"
    , "{Sin[1.2],Sin[1.2`20],Exp[1.2],Log[1.2]}"
    , "List[0.9320390859672264, 0.93203908596722634967`20., 3.3201169227365477, 0.18232155679395462]"
    )
  , ( "ordinary exact complex transcendental calls use exact component formulas"
    , "{Exp[1+I],Sin[1+I],Cos[1+I],Tan[1+I],Sinh[1+I],Cosh[1+I],Tanh[1+I],Log[1+I]}"
    , "List[Times[E, Plus[Cos[1], Times[Complex[0, 1], Sin[1]]]], Plus[Times[Complex[0, 1], Cos[1], Sinh[1]], Times[Cosh[1], Sin[1]]], Plus[Times[Complex[0, -1], Sin[1], Sinh[1]], Times[Cos[1], Cosh[1]]], Times[Plus[Sin[2], Times[Complex[0, 1], Sinh[2]]], Power[Plus[Cos[2], Cosh[2]], -1]], Plus[Times[Complex[0, 1], Cosh[1], Sin[1]], Times[Cos[1], Sinh[1]]], Plus[Times[Complex[0, 1], Sin[1], Sinh[1]], Times[Cos[1], Cosh[1]]], Times[Plus[Times[Complex[0, 1], Cos[1], Sin[1]], Times[Cosh[1], Sinh[1]]], Power[Plus[Power[Cos[1], 2], Power[Sinh[1], 2]], -1]], Plus[Log[Power[2, Rational[1, 2]]], Times[Complex[0, Rational[1, 4]], Pi]]]"
    )
  , ( "ordinary exact transcendental degree and singular outcomes"
    , "{Exp[0],Exp[1],Log[E],SinDegrees[30],CosDegrees[60],TanDegrees[45],ArcSinDegrees[1],ArcCotDegrees[-1],Tan[Pi/2],Sec[Pi/2],Cot[0.],Csc[0.],Coth[0.],ArcSec[0.],ArcCsc[0.],ArcCoth[0],ArcCoth[0.],ArcSech[0],ArcSech[0.],ArcCsch[0.],ArcTan[0.,0.],Log[1,2],Log[1,1],Log[2,0.]}"
    , "List[1, E, 1, Rational[1, 2], Rational[1, 2], 1, 90, 135, ComplexInfinity, ComplexInfinity, ComplexInfinity, ComplexInfinity, ComplexInfinity, ComplexInfinity, ComplexInfinity, Times[Complex[0, Rational[1, 2]], Pi], Complex[0., 1.5707963267948966], Infinity, ComplexInfinity, ComplexInfinity, Indeterminate, ComplexInfinity, Indeterminate, -Infinity]"
    )
  ]

underflowAndTinyComplexExpected :: Text
underflowAndTinyComplexExpected =
  "List[0."
    <> Text.replicate 434 "0"
    <> "50759588975494567653`20., Complex[1."
    <> Text.replicate 49 "0"
    <> "`50., 0."
    <> Text.replicate 399 "0"
    <> "1"
    <> Text.replicate 49 "0"
    <> "`50.]]"

sessionCases :: [(Text, Text, Text)]
sessionCases =
  [ ( "numeric precision arguments evaluate once from left to right"
    , "i=0;{N[(i++;Pi),(i++;20)],SetPrecision[(i++;1/3),(i++;20)],SetAccuracy[(i++;1/3),(i++;20)],i,$MessageList}"
    , "List[3.1415926535897932385`20., 0.33333333333333333333`20., 0.3333333333333333333333333333``20., 6, List[]]"
    )
  , ( "numeric precision heads dispatch through ordinary aliases"
    , "ClearAll[nn,sp,sa];nn=N;sp=SetPrecision;sa=SetAccuracy;{nn[Pi,20],sp[1/3,20],sa[1/3,20],$MessageList}"
    , "List[3.1415926535897932385`20., 0.33333333333333333333`20., 0.3333333333333333333333333333``20., List[]]"
    )
  , ( "ordinary downvalues take precedence over numeric reducers"
    , "Unprotect[N,SetPrecision,SetAccuracy];N[x_]:=nOverride[x];SetPrecision[x_,p_]:=pOverride[x,p];SetAccuracy[x_,p_]:=aOverride[x,p];{N[Pi],SetPrecision[1/3,20],SetAccuracy[1/3,20],$MessageList}"
    , "List[nOverride[Pi], pOverride[Rational[1, 3], 20], aOverride[Rational[1, 3], 20], List[]]"
    )
  , ( "transcendental aliases and explicit contexts dispatch without Global leakage"
    , "ClearAll[sinAlias];sinAlias=Sin;{sinAlias[1.2],System`Sin[1.2],Global`Sin[1.2],System`SinDegrees[30],Global`SinDegrees[30],$MessageList}"
    , "List[0.9320390859672264, 0.9320390859672264, Global`Sin[1.2], Rational[1, 2], Global`SinDegrees[30], List[]]"
    )
  , ( "exact complex transcendental results re-enter active session definitions"
    , "Unprotect[Cos];Cos[z_]:=q;{Tan[1+I],ComplexExpand[Tan[1+I]],$MessageList}"
    , "List[Times[Plus[Sin[2], Times[Complex[0, 1], Sinh[2]]], Power[Plus[q, Cosh[2]], -1]], ComplexExpand[Times[Plus[Sin[2], Times[Complex[0, 1], Sinh[2]]], Power[Plus[q, Cosh[2]], -1]]], List[]]"
    )
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
          failCheck
            label
            ("session expected " <> expected <> ", got " <> fullForm result)

checkSessionSource :: (Text, Text, Text) -> IO Bool
checkSessionSource (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> checkSessionValue label expression expected

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAILED numeric precision evaluator: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
