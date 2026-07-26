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
  , ( "qualified algebra dispatch"
    , "{System`Expand[(x+1)^2],System`Coefficient[x^2+2x+1,x],System`PolynomialQ[x^2,x]}"
    , "List[Plus[1, Power[x, 2], Times[2, x]], 2, True]"
    )
  , ( "unsupported algebra domains stay symbolic"
    , "{Expand[Sin[x]],Coefficient[Sin[x],x],CoefficientList[x^2,x,-1]}"
    , "List[Expand[Sin[x]], Coefficient[Sin[x], x], CoefficientList[Power[x, 2], x, -1]]"
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
