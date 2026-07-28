{-# LANGUAGE OverloadedStrings #-}

module Tungsten.PolynomialAlgebraTests (checkPolynomialAlgebraEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (evaluate)
import Tungsten.Expression (fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkPolynomialAlgebraEvaluator :: IO Bool
checkPolynomialAlgebraEvaluator = and <$> traverse checkValue valueCases

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ( "exact expansion"
    , "Expand[(x+1)^3]"
    , "Plus[1, Power[x, 3], Times[3, x], Times[3, Power[x, 2]]]"
    )
  , ( "polynomial predicates"
    , "{PolynomialQ[(x+1)^2,x],PolynomialQ[1/x,x],PolynomialQ[f[a]+f[a]^2,f[a]]}"
    , "List[True, False, True]"
    )
  , ( "implicit variable discovery"
    , "Variables[(x+y)^2+3z]"
    , "List[x, y, z]"
    )
  , ( "monomial lists and Gaussian coefficients"
    , "{MonomialList[x y+x^2+3,{x,y}],MonomialList[x^2+I x+1,x]}"
    , "List[List[Power[x, 2], Times[x, y], 3], List[Power[x, 2], Times[Complex[0, 1], x], 1]]"
    )
  , ( "monomial orders"
    , "{MonomialList[x^2+x y+y^2+x+y+1,{x,y},DegreeLexicographic],MonomialList[x^2+x y+y^2+x+y+1,NegativeLexicographic],MonomialList[x^2+x y+y^2+x+y+1,{x,y},NegativeDegreeReverseLexicographic]}"
    , "List[List[Power[x, 2], Times[x, y], Power[y, 2], x, y, 1], List[1, y, Power[y, 2], x, Times[x, y], Power[x, 2]], List[1, y, x, Power[y, 2], Times[x, y], Power[x, 2]]]"
    )
  , ( "monomial coefficient grouping and zero conventions"
    , "{MonomialList[x y+x z+y+z,x],MonomialList[x y+x z+y+z,{}],MonomialList[x+y,{}],MonomialList[0],MonomialList[0,x],MonomialList[3,x]}"
    , "List[List[Times[x, Plus[y, z]], Plus[y, z]], List[Times[Plus[1, x], Plus[y, z]]], List[Plus[x, y]], List[], List[0], List[3]]"
    )
  , ( "qualified monomial dispatch"
    , "{System`MonomialList[x^2+x,x],Global`MonomialList[x^2+x,x]}"
    , "List[List[Power[x, 2], x], Global`MonomialList[Plus[x, Power[x, 2]], x]]"
    )
  , ( "single coefficients"
    , "{Coefficient[2x^2 y+3x y+y,x,1],Coefficient[x^2y^2+3x y+1,x y,2]}"
    , "List[Times[3, y], 1]"
    )
  , ( "univariate coefficient arrays"
    , "{CoefficientList[x^2+3x+2,x],CoefficientList[0,x]}"
    , "List[List[2, 3, 1], List[]]"
    )
  , ( "multivariate coefficient arrays"
    , "CoefficientList[x y+2y+3,{x,y}]"
    , "List[List[3, 2], List[0, 1]]"
    )
  , ( "Gaussian coefficients"
    , "{PolynomialQ[x^2+I x+1,x],Coefficient[x^2+I x+1,x],CoefficientList[x^2+I x+1,x]}"
    , "List[True, Complex[0, 1], List[1, Complex[0, 1], 1]]"
    )
  , ( "structural fraction projections"
    , "{Numerator[(x^2-1)/(x+1)],Denominator[(x^2-1)/(x+1)],Numerator[{1/2,x/y}],Denominator[{1/2,x/y}]}"
    , "List[Plus[-1, Power[x, 2]], Plus[1, x], List[1, x], List[2, y]]"
    )
  , ( "rational combination and cancellation"
    , "{Together[1/x+1/y],Cancel[(x^2-1)/(x-1)],Apart[(x+1)/(x^2-1)]}"
    , "List[Times[Plus[x, y], Power[x, -1], Power[y, -1]], Plus[1, x], Power[Plus[-1, x], -1]]"
    )
  , ( "rational polynomial factorization"
    , "{Factor[x^2-1],Factor[2x y+2y],FactorList[2x^2-2],FactorList[0]}"
    , "List[Times[Plus[-1, x], Plus[1, x]], Times[2, y, Plus[1, x]], List[List[2, 1], List[Plus[-1, x], 1], List[Plus[1, x], 1]], List[List[0, 1]]]"
    )
  , ( "polynomial gcd lcm and division"
    , "{PolynomialGCD[x^2-1,x^2-x],PolynomialLCM[x-1,x+1],PolynomialQuotient[x^3-1,x-1,x],PolynomialRemainder[x^3-1,x-1,x]}"
    , "List[Plus[-1, x], Times[Plus[-1, x], Plus[1, x]], Plus[1, x, Power[x, 2]], 0]"
    )
  , ( "polynomial modular coefficients"
    , "{PolynomialMod[x^2+2x+3,5],PolynomialMod[-x^2-2x-3,5],PolynomialMod[x/2+2/3,5],PolynomialMod[x y+7x+12,5],PolynomialMod[3,5]}"
    , "List[Plus[3, Power[x, 2], Times[2, x]], Plus[2, Times[3, x], Times[4, Power[x, 2]]], Plus[4, Times[3, x]], Plus[2, Times[x, Plus[2, y]]], 3]"
    )
  , ( "polynomial modular domain and qualification boundaries"
    , "{PolynomialMod[1/5+x,5],PolynomialMod[x+I,5],PolynomialMod[3,1],System`PolynomialMod[x+7,5],Global`PolynomialMod[x+7,5]}"
    , "List[PolynomialMod[Plus[Rational[1, 5], x], 5], PolynomialMod[Plus[Complex[0, 1], x], 5], PolynomialMod[3, 1], Plus[2, x], Global`PolynomialMod[Plus[7, x], 5]]"
    )
  , ( "best-subset additive factoring with real and complex coefficients"
    , "{2x+x y+2,I x+I y+x y,(1+I)x+(1+I)y}"
    , "List[Plus[2, Times[x, Plus[2, y]]], Plus[Times[Complex[0, 1], y], Times[x, Plus[Complex[0, 1], y]]], Plus[Times[Complex[1, 1], x], Times[Complex[1, 1], y]]]"
    )
  , ( "qualified algebra dispatch"
    , "{System`Expand[(x+1)^2],System`Coefficient[x^2+2x+1,x],System`PolynomialQ[x^2,x],System`Cancel[(x^2-1)/(x-1)]}"
    , "List[Plus[1, Power[x, 2], Times[2, x]], 2, True, Plus[1, x]]"
    )
  , ( "unsupported algebra domains stay symbolic"
    , "{Expand[Sin[x]],Coefficient[Sin[x],x],CoefficientList[x^2,x,-1],Apart[1/(x^2-1)]}"
    , "List[Expand[Sin[x]], Coefficient[Sin[x], x], CoefficientList[Power[x, 2], x, -1], Apart[Power[Plus[-1, Power[x, 2]], -1]]]"
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
  TextIO.putStrLn ("Polynomial algebra test failed (" <> label <> "): " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
