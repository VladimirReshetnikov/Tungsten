{-# LANGUAGE OverloadedStrings #-}

module Tungsten.AlgebraicRootsTests (checkAlgebraicRootsEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (evaluate)
import Tungsten.Expression (fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

-- | Focused compatibility checks for the algebraic-root dispatch family.
-- These intentionally exercise both the stateless evaluator and session path;
-- the latter is where @$MaxRootDegree@ is supplied during integration.
checkAlgebraicRootsEvaluator :: IO Bool
checkAlgebraicRootsEvaluator = and <$> traverse checkValue valueCases

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ( "primitive and repeated Root canonicalization"
    , "{Root[2 #^3-4&,2],Root[(#^2-2)^2&,4],Root[#^2-4&,2]}"
    , "List[Root[Function[Plus[-2, Power[Slot[1], 3]]], 2, 0], Root[Function[Plus[-2, Power[Slot[1], 2]]], 2, 0], 2]"
    )
  , ( "algebraic Root coefficients"
    , "{Root[I #+1&,1],Root[((1+I)/2)#^2+1&,1],Root[#^2-2^(1/3)&,2]}"
    , "List[Root[Function[Plus[1, Power[Slot[1], 2]]], 2, 0], Root[Function[Plus[2, Times[2, Power[Slot[1], 2]], Power[Slot[1], 4]]], 1, 0], Root[Function[Plus[-2, Power[Slot[1], 6]]], 2, 0]]"
    )
  , ( "RootReduce and MinimalPolynomial"
    , "{RootReduce[Root[#^3-2&,1]^3],RootReduce[1/Root[#^3-2&,1]],MinimalPolynomial[Root[#^3-2&,1]^2,x]}"
    , "List[2, Root[Function[Plus[-1, Times[2, Power[Slot[1], 3]]]], 1, 0], Plus[-4, Power[x, 3]]]"
    )
  , ( "independent algebraic sums"
    , "RootReduce[Root[#^2-2&,2]+Root[#^2-3&,2]]"
    , "Root[Function[Plus[1, Times[-10, Power[Slot[1], 2]], Power[Slot[1], 4]]], 4, 0]"
    )
  , ( "rational-angle trigonometry"
    , "{RootReduce[Sin[Pi/5]],RootReduce[Cos[2Pi/7]],RootReduce[SinDegrees[20]],RootReduce[Haversine[Pi/5]]}"
    , "List[Root[Function[Plus[5, Times[-20, Power[Slot[1], 2]], Times[16, Power[Slot[1], 4]]]], 3, 0], Root[Function[Plus[-1, Times[-4, Slot[1]], Times[4, Power[Slot[1], 2]], Times[8, Power[Slot[1], 3]]]], 3, 0], Root[Function[Plus[-3, Times[36, Power[Slot[1], 2]], Times[-96, Power[Slot[1], 4]], Times[64, Power[Slot[1], 6]]]], 4, 0], Root[Function[Plus[1, Times[-12, Slot[1]], Times[16, Power[Slot[1], 2]]]], 1, 0]]"
    )
  , ( "components and conjugation"
    , "{RootReduce[Re[Root[#^2+1&,1]]],RootReduce[Im[Root[#^2+1&,1]]],RootReduce[Abs[Root[#^2+1&,1]]],Conjugate[Root[#^3-2&,2]],RootReduce[Re[Root[#^3-2&,2]]]}"
    , "List[0, -1, 1, Root[Function[Plus[-2, Power[Slot[1], 3]]], 3, 0], Root[Function[Plus[1, Times[4, Power[Slot[1], 3]]]], 1, 0]]"
    )
  , ( "real root counts with multiplicity"
    , "{CountRoots[x^3-x,x],CountRoots[x^2+1,x],CountRoots[(x-1)^2(x+1),{x,-2,2}],CountRoots[(x-1)^2,{x,1,1}]}"
    , "List[3, 0, 3, 2]"
    )
  , ( "rectangular complex root count"
    , "CountRoots[x^2+1,{x,-1-I,1+I}]"
    , "2"
    )
  , ( "root intervals"
    , "{RootIntervals[(x-1)^2(x+1)],RootIntervals[x^2+1]}"
    , "List[List[List[List[-1, -1], List[1, 1]], List[List[1], List[2]]], List[List[], List[]]]"
    )
  , ( "dyadic isolating intervals"
    , "{IsolatingInterval[Root[#^2-2&,1]],IsolatingInterval[Root[#^2+1&,1]]}"
    , "List[List[Rational[-91, 64], Rational[-45, 32]], List[Complex[Rational[-1, 128], Rational[-129, 128]], Complex[Rational[1, 128], Rational[-127, 128]]]]"
    )
  , ( "RootSum callable and Normal expansion"
    , "{RootSum[#^2-2&,(#^2&)],RootSum[(#-1)^2&,(#&)],Normal[RootSum[(#-1)^2&,f]]}"
    , "List[4, 2, Times[2, f[1]]]"
    )
  , ( "radicals through supported quartics"
    , "{ToRadicals[Root[#^2-2&,2]],ToRadicals[Root[#^2+1&,1]],ToRadicals[Root[#^3-2&,1]],ToRadicals[Root[#^4-2&,1]],ToRadicals[Root[#^5-#-1&,1]]}"
    , "List[Power[2, Rational[1, 2]], Complex[0, -1], Power[2, Rational[1, 3]], Times[-1, Power[2, Rational[1, 4]]], Root[Function[Plus[-1, Times[-1, Slot[1]], Power[Slot[1], 5]]], 1, 0]]"
    )
  , ( "univariate polynomial Solve"
    , "{Solve[x^2==1,x],Solve[x^2+1==0,x],Solve[{x^2==1,x+1==0},x],Solve[(x-1)^2==0,x]}"
    , "List[List[List[Rule[x, -1]], List[Rule[x, 1]]], List[List[Rule[x, Root[Function[Plus[1, Power[Slot[1], 2]]], 1, 0]]], List[Rule[x, Root[Function[Plus[1, Power[Slot[1], 2]]], 2, 0]]]], List[List[Rule[x, -1]]], List[List[Rule[x, 1]]]]"
    )
  , ( "exact square linear Solve"
    , "{Solve[{x+y==3,x-y==1},{x,y}],Solve[{2x+y==5,x-3y==-4},{x,y}],Solve[Sqrt[2]x==1,x],Solve[Pi x==1,x]}"
    , "List[List[List[Rule[x, 2], Rule[y, 1]]], List[List[Rule[x, Rational[11, 7]], Rule[y, Rational[13, 7]]]], List[List[Rule[x, Times[Rational[1, 2], Power[2, Rational[1, 2]]]]]], List[List[Rule[x, Power[Pi, -1]]]]]"
    )
  , ( "Solve soft-domain boundary"
    , "{Solve[False,x],Solve[True,{x,y}],Solve[x^2==a,x],Solve[{x+y==3},{x,y}]}"
    , "List[List[], List[List[]], Solve[Equal[Power[x, 2], a], x], Solve[List[Equal[Plus[x, y], 3]], List[x, y]]]"
    )
  , ( "unsupported algebraic calls remain inert"
    , "{Root[Sin[#]&,1],Root[#^2-2&,0],RootReduce[x],MinimalPolynomial[x],CountRoots[x^2+1,{x,a,b}]}"
    , "List[Root[Function[Sin[Slot[1]]], 1], Root[Function[Plus[Power[Slot[1], 2], -2]], 0], RootReduce[x], MinimalPolynomial[x], CountRoots[Plus[1, Power[x, 2]], List[x, a, b]]]"
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
      | otherwise -> do
          sessionResult <- evaluateInSession emptySession expression
          case sessionResult of
            Left sessionError -> failCheck label ("session error: " <> showText sessionError)
            Right (sessionValue, _)
              | fullForm sessionValue == expected -> pure True
              | otherwise ->
                  failCheck label ("session expected " <> expected <> ", got " <> fullForm sessionValue)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("Algebraic roots test failed (" <> label <> "): " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
