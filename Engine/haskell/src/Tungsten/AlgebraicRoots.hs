{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact, kernel-free support for Tungsten's bounded algebraic-root family.
--
-- The public reducer is intentionally callback-driven.  The evaluator owns
-- canonical arithmetic ordering and the session owns @$MaxRootDegree@; this
-- module owns only algebraic conversion and returns 'Nothing' whenever an
-- input is outside the supported exact subset.  That soft boundary mirrors
-- the Python implementation's best-effort dispatch.
module Tungsten.AlgebraicRoots
  ( AlgebraicRootContext (..)
  , defaultAlgebraicRootContext
  , reduceAlgebraicRootBuiltin
  , expandRootSumForNormal
  ) where

import Control.Monad (foldM, guard)
import Data.Complex (Complex ((:+)))
import qualified Data.Complex as Complex
import Data.List (minimumBy, nub, sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (comparing)
import Data.Ratio (Ratio, denominator, numerator, (%))
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Expression (Expr (..))
import Tungsten.SystemSymbols (isSystemSymbol, normalizeSystemSymbolName)

-- | Integration callbacks supplied by 'Tungsten.Evaluate'.  The simplifier
-- must be total for the structural expressions constructed here: callers can
-- turn an evaluator error into the original expression, just as Python's
-- algebraic dispatcher catches conversion failures and leaves a call inert.
data AlgebraicRootContext = AlgebraicRootContext
  { simplifyAlgebraicExpression :: Expr -> Expr
  , maximumAlgebraicRootDegree :: Integer
  }

defaultAlgebraicRootContext :: AlgebraicRootContext
defaultAlgebraicRootContext =
  AlgebraicRootContext
    { simplifyAlgebraicExpression = id
    , maximumAlgebraicRootDegree = 1000
    }

-- | Reduce one already-evaluated algebraic-root built-in.  Unsupported arity,
-- domains, excessive degree, and hard factor-selection cases return 'Nothing'.
reduceAlgebraicRootBuiltin
  :: AlgebraicRootContext
  -> Text
  -> [Expr]
  -> Maybe Expr
reduceAlgebraicRootBuiltin context headName values = case headName of
  "Root" -> reduceRoot context values
  "RootReduce" -> reduceRootReduce context values
  "MinimalPolynomial" -> reduceMinimalPolynomial context values
  "ToRadicals" -> reduceToRadicals context values
  "RootIntervals" -> reduceRootIntervals context values
  "IsolatingInterval" -> reduceIsolatingInterval context values
  "CountRoots" -> reduceCountRoots context values
  "RootSum" -> reduceRootSum context values
  "Solve" -> reduceSolve context values
  _ -> Nothing

-- | Expansion hook for @Normal[RootSum[...]]@.  Unlike ordinary @RootSum@,
-- @Normal@ also expands a symbolic mapping head such as @f@.
expandRootSumForNormal
  :: AlgebraicRootContext
  -> Expr
  -> Maybe Expr
expandRootSumForNormal context (Call (Symbol headName) values)
  | systemHeadIs "RootSum" headName = normalRootSum context values
expandRootSumForNormal _ _ = Nothing

type Q = Ratio Integer

newtype QPoly = QPoly {qPolyCoefficients :: [Q]}
  deriving (Eq, Show)

zeroPoly :: QPoly
zeroPoly = QPoly []

onePoly :: QPoly
onePoly = QPoly [1]

xPoly :: QPoly
xPoly = QPoly [0, 1]

mkPoly :: [Q] -> QPoly
mkPoly = QPoly . reverse . dropWhile (== 0) . reverse

polyIsZero :: QPoly -> Bool
polyIsZero (QPoly values) = null values

polyIsOne :: QPoly -> Bool
polyIsOne (QPoly values) = values == [1]

polyDegree :: QPoly -> Int
polyDegree (QPoly values) = length values - 1

polyCoefficient :: Int -> QPoly -> Q
polyCoefficient index (QPoly values)
  | index < 0 || index >= length values = 0
  | otherwise = values !! index

polyLeading :: QPoly -> Q
polyLeading (QPoly []) = 0
polyLeading (QPoly values) = last values

polyAdd :: QPoly -> QPoly -> QPoly
polyAdd (QPoly left) (QPoly right) =
  mkPoly (zipWith (+) (pad count left) (pad count right))
 where
  count = max (length left) (length right)
  pad size values = values <> replicate (size - length values) 0

polyNegate :: QPoly -> QPoly
polyNegate (QPoly values) = mkPoly (map negate values)

polySubtract :: QPoly -> QPoly -> QPoly
polySubtract left right = polyAdd left (polyNegate right)

polyScale :: Q -> QPoly -> QPoly
polyScale scale (QPoly values) = mkPoly (map (scale *) values)

polyShift :: Int -> QPoly -> QPoly
polyShift amount polynomial@(QPoly values)
  | amount <= 0 = polynomial
  | null values = zeroPoly
  | otherwise = QPoly (replicate amount 0 <> values)

polyMultiply :: QPoly -> QPoly -> QPoly
polyMultiply (QPoly left) (QPoly right)
  | null left || null right = zeroPoly
  | otherwise =
      mkPoly
        [ sum
            [ left !! leftIndex * right !! (degreeIndex - leftIndex)
            | leftIndex <- [0 .. degreeIndex]
            , leftIndex < length left
            , degreeIndex - leftIndex < length right
            ]
        | degreeIndex <- [0 .. length left + length right - 2]
        ]

polyPower :: QPoly -> Int -> QPoly
polyPower _ exponentValue | exponentValue < 0 = zeroPoly
polyPower base exponentValue = go onePoly base exponentValue
 where
  go retained _ 0 = retained
  go retained factor remaining
    | odd remaining =
        go
          (polyMultiply retained factor)
          (polyMultiply factor factor)
          (remaining `div` 2)
    | otherwise =
        go retained (polyMultiply factor factor) (remaining `div` 2)

polyDerivative :: QPoly -> QPoly
polyDerivative (QPoly values) =
  mkPoly
    [fromIntegral exponentValue * coefficient | (exponentValue, coefficient) <- zip [1 :: Int ..] (drop 1 values)]

polyEvaluate :: QPoly -> Q -> Q
polyEvaluate (QPoly values) point = foldr (\coefficient retained -> coefficient + point * retained) 0 values

polyEvaluateComplex :: QPoly -> Complex Double -> Complex Double
polyEvaluateComplex (QPoly values) point =
  foldr
    (\coefficient retained -> fromRational coefficient + point * retained)
    0
    values

polyDivMod :: QPoly -> QPoly -> Maybe (QPoly, QPoly)
polyDivMod _ divisor | polyIsZero divisor = Nothing
polyDivMod dividend divisor = Just (go zeroPoly dividend)
 where
  divisorDegree = polyDegree divisor
  divisorLeading = polyLeading divisor
  go quotient remainder
    | polyIsZero remainder || polyDegree remainder < divisorDegree = (quotient, remainder)
    | otherwise =
        let shiftAmount = polyDegree remainder - divisorDegree
            factor = polyLeading remainder / divisorLeading
            term = polyShift shiftAmount (QPoly [factor])
            remainder' = polySubtract remainder (polyMultiply term divisor)
         in go (polyAdd quotient term) remainder'

polyExactDivide :: QPoly -> QPoly -> Maybe QPoly
polyExactDivide dividend divisor = do
  (quotient, remainder) <- polyDivMod dividend divisor
  guard (polyIsZero remainder)
  pure quotient

polyMonic :: QPoly -> QPoly
polyMonic polynomial
  | polyIsZero polynomial = polynomial
  | otherwise = polyScale (recip (polyLeading polynomial)) polynomial

polyGcd :: QPoly -> QPoly -> QPoly
polyGcd left right = go left right
 where
  go current divisor
    | polyIsZero divisor = polyMonic current
    | otherwise = case polyDivMod current divisor of
        Nothing -> zeroPoly
        Just (_, remainder) -> go divisor remainder

polySquareFree :: QPoly -> QPoly
polySquareFree polynomial
  | polyDegree polynomial <= 0 = polyMonic polynomial
  | otherwise =
      fromMaybe
        (polyMonic polynomial)
        (polyExactDivide polynomial (polyGcd polynomial (polyDerivative polynomial)))

squareFreeFactors :: QPoly -> [(QPoly, Int)]
squareFreeFactors polynomial
  | polyDegree polynomial <= 0 = []
  | otherwise = go 1 initialW initialC []
 where
  monic = polyMonic polynomial
  initialC = polyGcd monic (polyDerivative monic)
  initialW = fromMaybe monic (polyExactDivide monic initialC)
  go multiplicity w c retained
    | polyIsOne w = reverse retained
    | otherwise =
        let y = polyGcd w c
            factor = fromMaybe w (polyExactDivide w y)
            c' = fromMaybe onePoly (polyExactDivide c y)
            retained' =
              if polyDegree factor > 0
                then (polyMonic factor, multiplicity) : retained
                else retained
         in go (multiplicity + 1) y c' retained'

primitiveIntegerCoefficients :: QPoly -> Maybe [Integer]
primitiveIntegerCoefficients polynomial@(QPoly values)
  | polyDegree polynomial <= 0 = Nothing
  | otherwise =
      let commonDenominator = foldl' lcm 1 (map denominator values)
          integers = [numerator value * (commonDenominator `div` denominator value) | value <- values]
          content = foldl' gcd 0 (map abs integers)
          primitive = if content == 0 then integers else map (`div` content) integers
          signed = if last primitive < 0 then map negate primitive else primitive
       in Just signed

integerPoly :: [Integer] -> QPoly
integerPoly = mkPoly . map (% 1)

qExpr :: Q -> Expr
qExpr value
  | denominator value == 1 = Integer (numerator value)
  | otherwise = Rational (numerator value) (denominator value)

exactQ :: Expr -> Maybe Q
exactQ = \case
  Integer value -> Just (value % 1)
  Rational numeratorValue denominatorValue
    | denominatorValue /= 0 -> Just (numeratorValue % denominatorValue)
  Call (Symbol headName) values
    | systemHeadIs "Plus" headName -> sum <$> traverse exactQ values
    | systemHeadIs "Times" headName -> product <$> traverse exactQ values
    | systemHeadIs "Power" headName
    , [baseExpression, exponentExpression] <- values -> do
        baseValue <- exactQ baseExpression
        exponentValue <- exactQ exponentExpression
        guard (denominator exponentValue == 1)
        let integerExponent = numerator exponentValue
        if integerExponent >= 0
          then Just (baseValue ^ integerExponent)
          else do
            guard (baseValue /= 0)
            Just (recip (baseValue ^ negate integerExponent))
  _ -> Nothing

listExpr :: [Expr] -> Expr
listExpr = Call (Symbol "List")

ruleExpr :: Expr -> Expr -> Expr
ruleExpr left right = Call (Symbol "Rule") [left, right]

systemHeadIs :: Text -> Text -> Bool
systemHeadIs expected actual =
  actual == expected || actual == "System`" <> expected

dispatchHead :: Text -> Maybe Text
dispatchHead name
  | isSystemSymbol name = normalizeSystemSymbolName name
  | otherwise = Nothing

callHead :: Expr -> Maybe (Text, [Expr])
callHead (Call (Symbol headName) values) = do
  normalized <- dispatchHead headName
  pure (normalized, values)
callHead _ = Nothing

simplifyCall :: AlgebraicRootContext -> Text -> [Expr] -> Expr
simplifyCall context headName values =
  simplifyAlgebraicExpression context (Call (Symbol headName) values)

expressionAdd :: AlgebraicRootContext -> Expr -> Expr -> Expr
expressionAdd context left right = simplifyCall context "Plus" [left, right]

expressionNegate :: AlgebraicRootContext -> Expr -> Expr
expressionNegate context value = simplifyCall context "Times" [Integer (-1), value]

expressionMultiply :: AlgebraicRootContext -> Expr -> Expr -> Expr
expressionMultiply context left right = simplifyCall context "Times" [left, right]

expressionDivide :: AlgebraicRootContext -> Expr -> Expr -> Expr
expressionDivide context numeratorValue denominatorValue
  | Just ("Power", [radicand, exponentExpression]) <- callHead denominatorValue
  , Just exponentValue <- exactQ exponentExpression
  , exponentValue == 1 % 2
  , Just radicandValue <- exactQ radicand
  , radicandValue > 0 =
      simplifyCall
        context
        "Times"
        [ numeratorValue
        , qExpr (recip radicandValue)
        , denominatorValue
        ]
expressionDivide context numeratorValue denominatorValue =
  simplifyCall
    context
    "Times"
    [numeratorValue, Call (Symbol "Power") [denominatorValue, Integer (-1)]]

expressionPower :: AlgebraicRootContext -> Expr -> Expr -> Expr
expressionPower context base exponentValue =
  simplifyCall context "Power" [base, exponentValue]

type ExprPoly = Map.Map Int Expr

constantExprPoly :: Expr -> ExprPoly
constantExprPoly (Integer 0) = Map.empty
constantExprPoly value = Map.singleton 0 value

variableExprPoly :: ExprPoly
variableExprPoly = Map.singleton 1 (Integer 1)

exprPolyAdd :: AlgebraicRootContext -> ExprPoly -> ExprPoly -> ExprPoly
exprPolyAdd context left right =
  Map.filter (/= Integer 0) (Map.unionWith (expressionAdd context) left right)

exprPolyMultiply :: AlgebraicRootContext -> ExprPoly -> ExprPoly -> ExprPoly
exprPolyMultiply context left right =
  Map.filter
    (/= Integer 0)
    ( Map.fromListWith
        (expressionAdd context)
        [ (leftDegree + rightDegree, expressionMultiply context leftValue rightValue)
        | (leftDegree, leftValue) <- Map.toList left
        , (rightDegree, rightValue) <- Map.toList right
        ]
    )

exprPolyPower :: AlgebraicRootContext -> ExprPoly -> Int -> ExprPoly
exprPolyPower context base exponentValue = go (constantExprPoly (Integer 1)) base exponentValue
 where
  go retained _ 0 = retained
  go retained factor remaining
    | odd remaining =
        go
          (exprPolyMultiply context retained factor)
          (exprPolyMultiply context factor factor)
          (remaining `div` 2)
    | otherwise =
        go retained (exprPolyMultiply context factor factor) (remaining `div` 2)

polynomialFunctionBody :: Expr -> Maybe (Maybe Expr, Expr)
polynomialFunctionBody (Call (Symbol headName) values)
  | systemHeadIs "Function" headName = case values of
      [body] -> Just (Nothing, body)
      [parameter@(Symbol _), body] -> Just (Just parameter, body)
      [Call (Symbol listHead) [parameter@(Symbol _)], body]
        | systemHeadIs "List" listHead -> Just (Just parameter, body)
      _ -> Nothing
polynomialFunctionBody expression = Just (Nothing, expression)

isPolynomialVariable :: Maybe Expr -> Expr -> Bool
isPolynomialVariable (Just parameter) expression = expression == parameter
isPolynomialVariable Nothing (Call (Symbol headName) values)
  | systemHeadIs "Slot" headName = null values || values == [Integer 1]
isPolynomialVariable Nothing _ = False

containsPolynomialVariable :: Maybe Expr -> Expr -> Bool
containsPolynomialVariable parameter expression
  | isPolynomialVariable parameter expression = True
containsPolynomialVariable parameter (Call expressionHead values) =
  containsPolynomialVariable parameter expressionHead
    || any (containsPolynomialVariable parameter) values
containsPolynomialVariable _ _ = False

expressionPolynomial
  :: AlgebraicRootContext
  -> Maybe Expr
  -> Bool
  -> Expr
  -> Maybe ExprPoly
expressionPolynomial _ parameter allowConstants expression
  | isPolynomialVariable parameter expression = Just variableExprPoly
  | allowConstants && not (containsPolynomialVariable parameter expression) =
      Just (constantExprPoly expression)
expressionPolynomial _ _ _ (Integer value) = Just (constantExprPoly (Integer value))
expressionPolynomial _ _ _ value@(Rational _ _) = Just (constantExprPoly value)
expressionPolynomial context parameter allowConstants (Call (Symbol headName) values)
  | systemHeadIs "Plus" headName = do
      terms <- traverse (expressionPolynomial context parameter allowConstants) values
      pure (foldl' (exprPolyAdd context) Map.empty terms)
  | systemHeadIs "Times" headName = do
      factors <- traverse (expressionPolynomial context parameter allowConstants) values
      pure (foldl' (exprPolyMultiply context) (constantExprPoly (Integer 1)) factors)
expressionPolynomial context parameter allowConstants (Call (Symbol headName) [base, Integer exponentValue])
  | systemHeadIs "Power" headName
  , exponentValue >= 0
  , exponentValue <= 1000 = do
      polynomial <- expressionPolynomial context parameter allowConstants base
      pure (exprPolyPower context polynomial (fromInteger exponentValue))
expressionPolynomial _ _ _ _ = Nothing

functionExpressionPolynomial
  :: AlgebraicRootContext
  -> Bool
  -> Expr
  -> Maybe ExprPoly
functionExpressionPolynomial context allowConstants function = do
  (parameter, body) <- polynomialFunctionBody function
  polynomial <- expressionPolynomial context parameter allowConstants body
  guard (not (Map.null polynomial) && fst (Map.findMax polynomial) > 0)
  pure polynomial

rationalPolynomialFromExprPoly :: ExprPoly -> Maybe QPoly
rationalPolynomialFromExprPoly polynomial
  | Map.null polynomial = Nothing
  | otherwise = do
      let degreeValue = fst (Map.findMax polynomial)
      coefficients <- traverse (exactQ . fromMaybe (Integer 0) . (`Map.lookup` polynomial)) [0 .. degreeValue]
      let result = mkPoly coefficients
      guard (polyDegree result > 0)
      pure result

rationalFunctionPolynomial :: AlgebraicRootContext -> Expr -> Maybe QPoly
rationalFunctionPolynomial context function =
  functionExpressionPolynomial context False function >>= rationalPolynomialFromExprPoly

rationalPolynomialInVariable
  :: AlgebraicRootContext
  -> Expr
  -> Expr
  -> Maybe QPoly
rationalPolynomialInVariable context variable expression = do
  polynomial <- expressionPolynomial context (Just variable) False expression
  rationalPolynomialFromExprPoly polynomial

singlePolynomialVariable :: Expr -> Maybe Expr
singlePolynomialVariable expression = case nub (go expression) of
  [variable] -> Just variable
  _ -> Nothing
 where
  go value@(Symbol name)
    | dispatchHead name == Nothing = [value]
    | otherwise = []
  go (Call expressionHead values) = concatMap go (expressionHead : values)
  go _ = []

polyExpr :: AlgebraicRootContext -> Expr -> QPoly -> Expr
polyExpr context variable (QPoly coefficients) =
  case terms of
    [] -> Integer 0
    [singleTerm] -> singleTerm
    _ -> simplifyCall context "Plus" terms
 where
  terms = mapMaybe term [0 .. length coefficients - 1]
  term exponentValue =
    let coefficient = coefficients !! exponentValue
     in if coefficient == 0
          then Nothing
          else
            let powerValue = case exponentValue of
                  0 -> Integer 1
                  1 -> variable
                  _ -> expressionPower context variable (Integer (fromIntegral exponentValue))
                coefficientValue = qExpr coefficient
             in Just $ case exponentValue of
                  0 -> coefficientValue
                  _
                    | coefficient == 1 -> powerValue
                    | otherwise -> expressionMultiply context coefficientValue powerValue

rootIsNumericallyReal :: Complex Double -> Bool
rootIsNumericallyReal value =
  abs (Complex.imagPart value)
    <= 1e-8 * max 1 (abs (Complex.realPart value))

sortPolynomialRoots :: [Complex Double] -> [Complex Double]
sortPolynomialRoots values = sortBy (comparing orderingKey) normalized
 where
  normalized =
    [ if rootIsNumericallyReal value then Complex.realPart value :+ 0 else value
    | value <- values
    ]
  orderingKey value =
    (not (rootIsNumericallyReal value), Complex.realPart value, Complex.imagPart value)

approximatePolynomialRoots :: QPoly -> Maybe [Complex Double]
approximatePolynomialRoots polynomial@(QPoly coefficients)
  | degreeValue <= 0 = Nothing
  | otherwise = Just (sortPolynomialRoots (iterateRoots 0 initialRoots))
 where
  degreeValue = polyDegree polynomial
  leading :: Double
  leading = fromRational (last coefficients)
  radius =
    1
      + maximum
        (0 : [abs (fromRational coefficient / leading) | coefficient <- init coefficients])
  initialRoots =
    [ Complex.mkPolar
        radius
        (2 * pi * fromIntegral index / fromIntegral degreeValue + 0.137)
    | index <- [0 .. degreeValue - 1]
    ]
  iterateRoots iteration roots
    | iteration >= (768 :: Int) = roots
    | maximum (0 : map Complex.magnitude deltas) < 1e-13 = updated
    | otherwise = iterateRoots (iteration + 1) updated
   where
    deltas = zipWith correction [0 :: Int ..] roots
    updated = zipWith (-) roots deltas
    correction index rootValue =
      let denominatorValue =
            (leading :+ 0)
              * product
                [ rootValue - other
                | (otherIndex, other) <- zip [0 :: Int ..] roots
                , otherIndex /= index
                ]
       in if Complex.magnitude denominatorValue < 1e-28
            then 0
            else polyEvaluateComplex polynomial rootValue / denominatorValue

selectApproximateRoot :: QPoly -> Integer -> Maybe (Complex Double)
selectApproximateRoot polynomial index = do
  guard (index >= 0)
  roots <- approximatePolynomialRoots polynomial
  guard (index < toInteger (length roots))
  pure (roots !! fromInteger index)

nearestRootIndex :: QPoly -> Complex Double -> Maybe Integer
nearestRootIndex polynomial target = do
  roots <- approximatePolynomialRoots polynomial
  guard (not (null roots))
  let indexed = zip [0 :: Integer ..] roots
      (chosen, _) = minimumBy (comparing (Complex.magnitude . subtract target . snd)) indexed
  pure chosen

integerSquareRoot :: Integer -> Integer
integerSquareRoot value
  | value <= 0 = 0
  | otherwise = go value
 where
  go retained =
    let next = (retained + value `div` retained) `div` 2
     in if next >= retained then retained else go next

positiveDivisors :: Integer -> [Integer]
positiveDivisors value
  | value == 0 = []
  | otherwise =
      sortBy compare . nub $
        concat
          [ if divisor * divisor == magnitude
              then [divisor]
              else [divisor, magnitude `div` divisor]
          | divisor <- [1 .. integerSquareRoot magnitude]
          , magnitude `mod` divisor == 0
          ]
 where
  magnitude = abs value

rationalRootCandidates :: QPoly -> [Q]
rationalRootCandidates polynomial
  | polyDegree polynomial <= 0 = []
  | otherwise = case primitiveIntegerCoefficients polynomial of
      Just (constant : remaining)
        | constant == 0 ->
            0 : rationalRootCandidates (integerPoly remaining)
        | otherwise ->
            let leading = foldl' (\_ coefficient -> coefficient) constant remaining
             in nub
                  [ sign * numeratorValue % denominatorValue
                  | numeratorValue <- positiveDivisors constant
                  , denominatorValue <- positiveDivisors leading
                  , sign <- [-1, 1]
                  ]
      _ -> []

rationalRoots :: QPoly -> [Q]
rationalRoots polynomial =
  [candidate | candidate <- rationalRootCandidates polynomial, polyEvaluate polynomial candidate == 0]

nearComplex :: Complex Double -> Complex Double -> Bool
nearComplex left right =
  Complex.magnitude (left - right)
    <= 1e-7 * max 1 (max (Complex.magnitude left) (Complex.magnitude right))

canonicalRootFromPolynomial
  :: AlgebraicRootContext
  -> QPoly
  -> Complex Double
  -> Integer
  -> Maybe Expr
canonicalRootFromPolynomial context source target method = do
  guard (method == 0 || method == 1)
  let polynomial = polySquareFree source
      degreeValue = polyDegree polynomial
  guard (degreeValue > 0 && toInteger degreeValue <= maximumAlgebraicRootDegree context)
  case
      [ value
      | value <- rationalRoots polynomial
      , nearComplex target (fromRational value :+ 0)
      ] of
    value : _ -> Just (qExpr value)
    [] -> do
      coefficients <- primitiveIntegerCoefficients polynomial
      index <- nearestRootIndex polynomial target
      pure (Root coefficients index method)

type TPoly = [QPoly]

mkTPoly :: [QPoly] -> TPoly
mkTPoly = reverse . dropWhile polyIsZero . reverse

tPolyDegree :: TPoly -> Int
tPolyDegree values = length values - 1

tPolyCoefficient :: Int -> TPoly -> QPoly
tPolyCoefficient index values
  | index < 0 || index >= length values = zeroPoly
  | otherwise = values !! index

matrixAt :: [[value]] -> Int -> Int -> value
matrixAt matrix rowIndex columnIndex = matrix !! rowIndex !! columnIndex

replaceAt :: Int -> value -> [value] -> [value]
replaceAt index value values =
  take index values <> [value] <> drop (index + 1) values

replaceMatrixAt :: Int -> Int -> value -> [[value]] -> [[value]]
replaceMatrixAt rowIndex columnIndex value matrix =
  replaceAt
    rowIndex
    (replaceAt columnIndex value (matrix !! rowIndex))
    matrix

swapRows :: Int -> Int -> [[value]] -> [[value]]
swapRows left right matrix
  | left == right = matrix
  | otherwise =
      replaceAt right (matrix !! left) (replaceAt left (matrix !! right) matrix)

bareissDeterminant :: [[QPoly]] -> Maybe QPoly
bareissDeterminant [] = Just onePoly
bareissDeterminant [[value]] = Just value
bareissDeterminant matrix = go 0 onePoly 1 matrix
 where
  size = length matrix
  go pivotIndex previousPivot determinantSign retained
    | pivotIndex == size - 1 =
        Just (polyScale determinantSign (matrixAt retained pivotIndex pivotIndex))
    | otherwise = do
        pivotRow <-
          case
              [ rowIndex
              | rowIndex <- [pivotIndex .. size - 1]
              , not (polyIsZero (matrixAt retained rowIndex pivotIndex))
              ] of
            [] -> Nothing
            rowIndex : _ -> Just rowIndex
        let swapped = swapRows pivotIndex pivotRow retained
            nextSign = if pivotRow == pivotIndex then determinantSign else negate determinantSign
            pivot = matrixAt swapped pivotIndex pivotIndex
        updated <-
          foldM
            (updateCell pivotIndex pivot previousPivot)
            swapped
            [ (rowIndex, columnIndex)
            | rowIndex <- [pivotIndex + 1 .. size - 1]
            , columnIndex <- [pivotIndex + 1 .. size - 1]
            ]
        let cleared =
              foldl'
                (\current rowIndex -> replaceMatrixAt rowIndex pivotIndex zeroPoly current)
                updated
                [pivotIndex + 1 .. size - 1]
        go (pivotIndex + 1) pivot nextSign cleared
  updateCell pivotIndex pivot previousPivot retained (rowIndex, columnIndex) = do
    let numeratorValue =
          polySubtract
            (polyMultiply pivot (matrixAt retained rowIndex columnIndex))
            ( polyMultiply
                (matrixAt retained rowIndex pivotIndex)
                (matrixAt retained pivotIndex columnIndex)
            )
    value <-
      if polyIsOne previousPivot
        then Just numeratorValue
        else polyExactDivide numeratorValue previousPivot
    pure (replaceMatrixAt rowIndex columnIndex value retained)

resultantOverX :: TPoly -> TPoly -> Maybe QPoly
resultantOverX leftSource rightSource = do
  let left = mkTPoly leftSource
      right = mkTPoly rightSource
      leftDegree = tPolyDegree left
      rightDegree = tPolyDegree right
  guard (leftDegree > 0 && rightDegree > 0)
  let matrixSize = leftDegree + rightDegree
      rowFor polynomial degreeValue shiftAmount =
        [ if columnIndex >= shiftAmount && columnIndex <= shiftAmount + degreeValue
            then tPolyCoefficient (degreeValue - (columnIndex - shiftAmount)) polynomial
            else zeroPoly
        | columnIndex <- [0 .. matrixSize - 1]
        ]
      matrix =
        [rowFor left leftDegree shiftAmount | shiftAmount <- [0 .. rightDegree - 1]]
          <> [rowFor right rightDegree shiftAmount | shiftAmount <- [0 .. leftDegree - 1]]
  bareissDeterminant matrix

binomial :: Int -> Int -> Integer
binomial n k
  | k < 0 || k > n = 0
  | otherwise = product [toInteger (n - k' + 1) .. toInteger n] `div` product [1 .. toInteger k']
 where
  k' = min k (n - k)

substituteDifference :: QPoly -> TPoly
substituteDifference (QPoly coefficients) =
  mkTPoly
    [ foldl'
        polyAdd
        zeroPoly
        [ polyScale
            (coefficient * fromInteger (binomial exponentValue tExponent) * sign)
            (polyPower xPoly (exponentValue - tExponent))
        | (exponentValue, coefficient) <- zip [0 :: Int ..] coefficients
        , exponentValue >= tExponent
        , let sign = if odd tExponent then -1 else 1
        ]
    | tExponent <- [0 .. length coefficients - 1]
    ]

substituteProduct :: QPoly -> TPoly
substituteProduct (QPoly coefficients) =
  mkTPoly
    [ polyScale coefficient (polyPower xPoly exponentValue)
    | (exponentValue, coefficient) <- reverse (zip [0 :: Int ..] coefficients)
    ]

substitutePowerRelation :: Int -> TPoly
substitutePowerRelation exponentValue =
  mkTPoly
    ( [xPoly]
        <> replicate (max 0 (exponentValue - 1)) zeroPoly
        <> [QPoly [-1]]
    )

polySubstitutePower :: QPoly -> Int -> QPoly
polySubstitutePower (QPoly coefficients) exponentValue =
  mkPoly
    [ if index `mod` exponentValue == 0
        then coefficients !! (index `div` exponentValue)
        else 0
    | index <- [0 .. exponentValue * (length coefficients - 1)]
    ]

polyNegatedVariable :: QPoly -> QPoly
polyNegatedVariable (QPoly coefficients) =
  mkPoly
    [if odd exponentValue then negate coefficient else coefficient | (exponentValue, coefficient) <- zip [0 :: Int ..] coefficients]

polyReciprocalVariable :: QPoly -> QPoly
polyReciprocalVariable (QPoly coefficients) = mkPoly (reverse coefficients)

data Algebraic = Algebraic
  { algebraicPolynomial :: QPoly
  , algebraicApproximation :: Complex Double
  }
  deriving (Eq, Show)

rationalAlgebraic :: Q -> Algebraic
rationalAlgebraic value =
  Algebraic
    { algebraicPolynomial = QPoly [negate value, 1]
    , algebraicApproximation = fromRational value :+ 0
    }

imaginaryUnitAlgebraic :: Algebraic
imaginaryUnitAlgebraic = Algebraic (integerPoly [1, 0, 1]) (0 :+ 1)

algebraicResult
  :: AlgebraicRootContext
  -> QPoly
  -> Complex Double
  -> Maybe Algebraic
algebraicResult context candidate approximation = do
  let polynomial = polySquareFree candidate
  guard
    ( polyDegree polynomial > 0
        && toInteger (polyDegree polynomial) <= maximumAlgebraicRootDegree context
    )
  pure (Algebraic polynomial approximation)

algebraicNegate :: AlgebraicRootContext -> Algebraic -> Maybe Algebraic
algebraicNegate context value =
  algebraicResult
    context
    (polyNegatedVariable (algebraicPolynomial value))
    (negate (algebraicApproximation value))

algebraicReciprocal :: AlgebraicRootContext -> Algebraic -> Maybe Algebraic
algebraicReciprocal context value = do
  guard (Complex.magnitude (algebraicApproximation value) > 1e-15)
  algebraicResult
    context
    (polyReciprocalVariable (algebraicPolynomial value))
    (recip (algebraicApproximation value))

algebraicAdd
  :: AlgebraicRootContext
  -> Algebraic
  -> Algebraic
  -> Maybe Algebraic
algebraicAdd context left right = do
  candidate <-
    resultantOverX
      (map (\coefficient -> QPoly [coefficient]) (qPolyCoefficients (algebraicPolynomial left)))
      (substituteDifference (algebraicPolynomial right))
  algebraicResult
    context
    candidate
    (algebraicApproximation left + algebraicApproximation right)

algebraicMultiply
  :: AlgebraicRootContext
  -> Algebraic
  -> Algebraic
  -> Maybe Algebraic
algebraicMultiply context left right = do
  candidate <-
    resultantOverX
      (map (\coefficient -> QPoly [coefficient]) (qPolyCoefficients (algebraicPolynomial left)))
      (substituteProduct (algebraicPolynomial right))
  algebraicResult
    context
    candidate
    (algebraicApproximation left * algebraicApproximation right)

algebraicPowerInteger
  :: AlgebraicRootContext
  -> Algebraic
  -> Integer
  -> Maybe Algebraic
algebraicPowerInteger _ _ 0 = Just (rationalAlgebraic 1)
algebraicPowerInteger context value exponentValue
  | exponentValue < 0 = do
      inverse <- algebraicReciprocal context value
      algebraicPowerInteger context inverse (negate exponentValue)
  | exponentValue == 1 = Just value
  | exponentValue > 1000 = Nothing
  | otherwise = do
      candidate <-
        resultantOverX
          (map (\coefficient -> QPoly [coefficient]) (qPolyCoefficients (algebraicPolynomial value)))
          (substitutePowerRelation (fromInteger exponentValue))
      algebraicResult
        context
        candidate
        (algebraicApproximation value ^ exponentValue)

principalNthRoot :: Complex Double -> Integer -> Complex Double
principalNthRoot value exponentValue =
  exp (log value / (fromInteger exponentValue :+ 0))

algebraicNthRoot
  :: AlgebraicRootContext
  -> Algebraic
  -> Integer
  -> Maybe Algebraic
algebraicNthRoot context value exponentValue = do
  guard (exponentValue > 0 && exponentValue <= 1000)
  algebraicResult
    context
    (polySubstitutePower (algebraicPolynomial value) (fromInteger exponentValue))
    (principalNthRoot (algebraicApproximation value) exponentValue)

algebraicPowerRational
  :: AlgebraicRootContext
  -> Algebraic
  -> Q
  -> Maybe Algebraic
algebraicPowerRational context value exponentValue = do
  powered <- algebraicPowerInteger context value (numerator exponentValue)
  algebraicNthRoot context powered (denominator exponentValue)

algebraicRootValue :: [Integer] -> Integer -> Maybe Algebraic
algebraicRootValue coefficients index = do
  let polynomial = integerPoly coefficients
  guard (polyDegree polynomial > 0)
  approximation <- selectApproximateRoot polynomial index
  pure (Algebraic polynomial approximation)

algebraicFromExpr :: AlgebraicRootContext -> Expr -> Maybe Algebraic
algebraicFromExpr _ expression
  | Just value <- exactQ expression = Just (rationalAlgebraic value)
algebraicFromExpr _ (Symbol name)
  | dispatchHead name == Just "I" = Just imaginaryUnitAlgebraic
algebraicFromExpr context (Complex realPart imaginaryPart) = do
  realValue <- exactQ realPart
  imaginaryValue <- exactQ imaginaryPart
  scaledImaginary <- algebraicMultiply context (rationalAlgebraic imaginaryValue) imaginaryUnitAlgebraic
  algebraicAdd context (rationalAlgebraic realValue) scaledImaginary
algebraicFromExpr _ (Root coefficients index _) = algebraicRootValue coefficients index
algebraicFromExpr context expression
  | Just ("Plus", values) <- callHead expression = do
      terms <- traverse (algebraicFromExpr context) values
      foldM (algebraicAdd context) (rationalAlgebraic 0) terms
  | Just ("Times", values) <- callHead expression = do
      factors <- traverse (algebraicFromExpr context) values
      foldM (algebraicMultiply context) (rationalAlgebraic 1) factors
  | Just ("Power", [base, exponentExpression]) <- callHead expression
  , Just exponentValue <- exactQ exponentExpression = do
      algebraicBase <- algebraicFromExpr context base
      algebraicPowerRational context algebraicBase exponentValue
  | Just ("Sqrt", [base]) <- callHead expression = do
      algebraicBase <- algebraicFromExpr context base
      algebraicNthRoot context algebraicBase 2
  | Just ("Conjugate", [Root coefficients index _]) <- callHead expression = do
      value <- algebraicRootValue coefficients index
      pure (value {algebraicApproximation = Complex.conjugate (algebraicApproximation value)})
  | Just ("Re", [Root coefficients index _]) <- callHead expression =
      rootComponentAlgebraic context "Re" coefficients index
  | Just ("Im", [Root coefficients index _]) <- callHead expression =
      rootComponentAlgebraic context "Im" coefficients index
  | Just ("Abs", [Root coefficients index _]) <- callHead expression =
      rootComponentAlgebraic context "Abs" coefficients index
algebraicFromExpr context expression = trigAlgebraicFromExpr context expression

algebraicToExpr :: AlgebraicRootContext -> Integer -> Algebraic -> Maybe Expr
algebraicToExpr context method value =
  canonicalRootFromPolynomial
    context
    (algebraicPolynomial value)
    (algebraicApproximation value)
    method

approximateExpressionPolynomial :: AlgebraicRootContext -> ExprPoly -> Maybe [Complex Double]
approximateExpressionPolynomial context polynomial = do
  guard (not (Map.null polynomial))
  let degreeValue = fst (Map.findMax polynomial)
  coefficients <-
    traverse
      ( fmap algebraicApproximation
          . algebraicFromExpr context
          . fromMaybe (Integer 0)
          . (`Map.lookup` polynomial)
      )
      [0 .. degreeValue]
  approximateComplexCoefficientRoots coefficients

approximateComplexCoefficientRoots :: [Complex Double] -> Maybe [Complex Double]
approximateComplexCoefficientRoots coefficients
  | degreeValue <= 0 || Complex.magnitude leading < 1e-15 = Nothing
  | otherwise = Just (sortPolynomialRoots (iterateRoots 0 initialRoots))
 where
  degreeValue = length coefficients - 1
  leading = last coefficients
  radius = 1 + maximum (0 : [Complex.magnitude (coefficient / leading) | coefficient <- init coefficients])
  initialRoots =
    [ Complex.mkPolar radius (2 * pi * fromIntegral index / fromIntegral degreeValue + 0.137)
    | index <- [0 .. degreeValue - 1]
    ]
  evaluateAt point = foldr (\coefficient retained -> coefficient + point * retained) 0 coefficients
  iterateRoots iteration roots
    | iteration >= (768 :: Int) = roots
    | maximum (0 : map Complex.magnitude deltas) < 1e-13 = updated
    | otherwise = iterateRoots (iteration + 1) updated
   where
    deltas = zipWith correction [0 :: Int ..] roots
    updated = zipWith (-) roots deltas
    correction index rootValue =
      let denominatorValue =
            leading
              * product
                [ rootValue - other
                | (otherIndex, other) <- zip [0 :: Int ..] roots
                , otherIndex /= index
                ]
       in if Complex.magnitude denominatorValue < 1e-28
            then 0
            else evaluateAt rootValue / denominatorValue

algebraicCoefficientNorm
  :: AlgebraicRootContext
  -> ExprPoly
  -> Maybe (QPoly, [Complex Double])
algebraicCoefficientNorm context polynomial = do
  let entries = Map.toAscList polynomial
      nonRational = [(degreeValue, value) | (degreeValue, value) <- entries, exactQ value == Nothing]
  (coefficientDegree, coefficientExpr) <- case nonRational of
    [entry] -> Just entry
    _ -> Nothing
  coefficient <- algebraicFromExpr context coefficientExpr
  let rationalPart =
        mkPoly
          [ fromMaybe 0 (Map.lookup degreeValue polynomial >>= exactQ)
          | degreeValue <- [0 .. fst (Map.findMax polynomial)]
          ]
      coefficientTerm = polyShift coefficientDegree onePoly
      normArgument =
        [rationalPart, coefficientTerm]
      coefficientPolynomial =
        map
          (\value -> QPoly [value])
          (qPolyCoefficients (algebraicPolynomial coefficient))
  norm <- resultantOverX coefficientPolynomial normArgument
  roots <- approximateExpressionPolynomial context polynomial
  pure (norm, roots)

approximateRootsWithMultiplicity :: QPoly -> Maybe [Complex Double]
approximateRootsWithMultiplicity polynomial = do
  factorRoots <- traverse rootsForFactor (squareFreeFactors polynomial)
  pure (sortPolynomialRoots (concat factorRoots))
 where
  rootsForFactor (factor, multiplicity) = do
    roots <- approximatePolynomialRoots factor
    pure (concatMap (replicate multiplicity) roots)

polyAffineVariable :: QPoly -> Q -> Q -> QPoly
polyAffineVariable (QPoly coefficients) constant scale =
  foldl'
    polyAdd
    zeroPoly
    [ polyScale
        coefficient
        ( polyPower
            (QPoly [constant, scale])
            exponentValue
        )
    | (exponentValue, coefficient) <- zip [0 :: Int ..] coefficients
    ]

rootComponentAlgebraic
  :: AlgebraicRootContext
  -> Text
  -> [Integer]
  -> Integer
  -> Maybe Algebraic
rootComponentAlgebraic context component coefficients index = do
  value <- algebraicRootValue coefficients index
  let polynomial = algebraicPolynomial value
      approximation = algebraicApproximation value
      realTarget = Complex.realPart approximation :+ 0
      imaginaryTarget = Complex.imagPart approximation :+ 0
      absoluteTarget = Complex.magnitude approximation :+ 0
  if rootIsNumericallyReal approximation
    then case component of
      "Re" -> Just value
      "Im" -> Just (rationalAlgebraic 0)
      "Abs"
        | Complex.realPart approximation >= 0 -> Just value
        | otherwise -> algebraicNegate context value
      _ -> Nothing
    else case (component, polyDegree polynomial) of
      ("Re", 2) ->
        let leading = polyCoefficient 2 polynomial
            result = negate (polyCoefficient 1 polynomial) / (2 * leading)
         in Just (rationalAlgebraic result)
      ("Im", 2) -> do
        let leading = polyCoefficient 2 polynomial
            linear = polyCoefficient 1 polynomial
            constant = polyCoefficient 0 polynomial
            imaginarySquare = (4 * leading * constant - linear * linear) / (4 * leading * leading)
        algebraicResult context (QPoly [negate imaginarySquare, 0, 1]) imaginaryTarget
      ("Abs", 2) -> do
        let squareValue = polyCoefficient 0 polynomial / polyCoefficient 2 polynomial
        algebraicNthRoot context (rationalAlgebraic squareValue) 2
      ("Re", 3) ->
        let rootSum = negate (polyCoefficient 2 polynomial) / polyCoefficient 3 polynomial
         in algebraicResult context (polyAffineVariable polynomial rootSum (-2)) realTarget
      _ -> do
        let conjugateValue =
              value {algebraicApproximation = Complex.conjugate approximation}
        case component of
          "Re" -> do
            total <- algebraicAdd context value conjugateValue
            algebraicMultiply context total (rationalAlgebraic (1 % 2))
          "Im" -> do
            negatedConjugate <- algebraicNegate context conjugateValue
            difference <- algebraicAdd context value negatedConjugate
            denominatorValue <- algebraicMultiply context (rationalAlgebraic 2) imaginaryUnitAlgebraic
            inverse <- algebraicReciprocal context denominatorValue
            algebraicMultiply context difference inverse
          "Abs" -> do
            squareValue <- algebraicMultiply context value conjugateValue
            algebraicResult
              context
              (polySubstitutePower (algebraicPolynomial squareValue) 2)
              absoluteTarget
          _ -> Nothing

reduceRoot :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceRoot context values = do
  (function, oneBasedIndex, method) <- case values of
    [functionValue, Integer indexValue] -> Just (functionValue, indexValue, 0)
    [functionValue, Integer indexValue, Integer methodValue]
      | methodValue == 0 || methodValue == 1 ->
          Just (functionValue, indexValue, methodValue)
    _ -> Nothing
  guard (oneBasedIndex > 0)
  expressionPolynomialValue <- functionExpressionPolynomial context True function
  let originalDegree = fst (Map.findMax expressionPolynomialValue)
      zeroBasedIndex = oneBasedIndex - 1
  guard
    ( zeroBasedIndex < toInteger originalDegree
        && toInteger originalDegree <= maximumAlgebraicRootDegree context
    )
  case rationalPolynomialFromExprPoly expressionPolynomialValue of
    Just polynomial -> do
      roots <- approximateRootsWithMultiplicity polynomial
      guard (zeroBasedIndex < toInteger (length roots))
      canonicalRootFromPolynomial
        context
        polynomial
        (roots !! fromInteger zeroBasedIndex)
        method
    Nothing -> do
      (norm, roots) <- algebraicCoefficientNorm context expressionPolynomialValue
      guard (zeroBasedIndex < toInteger (length roots))
      canonicalRootFromPolynomial
        context
        norm
        (roots !! fromInteger zeroBasedIndex)
        method

reduceRootReduce :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceRootReduce context [Call (Symbol headName) values]
  | systemHeadIs "List" headName =
      Just
        ( listExpr
            [fromMaybe value (reduceRootReduce context [value]) | value <- values]
        )
reduceRootReduce context [expression] = do
  special <- rootReduceSpecial context expression
  case special of
    Just value -> Just value
    Nothing -> algebraicFromExpr context expression >>= algebraicToExpr context 0
reduceRootReduce _ _ = Nothing

rootReduceSpecial :: AlgebraicRootContext -> Expr -> Maybe (Maybe Expr)
rootReduceSpecial context expression
  | Just ("Conjugate", [Root coefficients index _]) <- callHead expression = do
      value <- algebraicRootValue coefficients index
      converted <-
        canonicalRootFromPolynomial
          context
          (algebraicPolynomial value)
          (Complex.conjugate (algebraicApproximation value))
          0
      pure (Just converted)
  | Just (component, [Root coefficients index _]) <- callHead expression
  , component `elem` ["Re", "Im", "Abs"] = do
      value <- rootComponentAlgebraic context component coefficients index
      converted <- algebraicToExpr context 0 value
      pure (Just converted)
  | otherwise = Just Nothing

reduceMinimalPolynomial :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceMinimalPolynomial context values = do
  (expression, variable, wrapFunction) <- case values of
    [value] -> Just (value, Call (Symbol "Slot") [Integer 1], True)
    [value, variableValue] -> Just (value, variableValue, False)
    _ -> Nothing
  algebraic <- algebraicFromExpr context expression
  let polynomial = polySquareFree (algebraicPolynomial algebraic)
  guard
    ( polyDegree polynomial > 0
        && toInteger (polyDegree polynomial) <= maximumAlgebraicRootDegree context
    )
  let result = polyExpr context variable polynomial
  pure (if wrapFunction then Call (Symbol "Function") [result] else result)

rationalPiMultiple :: Expr -> Maybe Q
rationalPiMultiple expression
  | Just value <- exactQ expression = if value == 0 then Just 0 else Nothing
rationalPiMultiple (Symbol name)
  | dispatchHead name == Just "Pi" = Just 1
  | dispatchHead name == Just "Degree" = Just (1 % 180)
rationalPiMultiple expression
  | Just ("Times", factors) <- callHead expression = go 1 Nothing factors
 where
  go coefficient piFactor [] = (*) coefficient <$> piFactor
  go coefficient piFactor (factor : rest)
    | Just value <- exactQ factor = go (coefficient * value) piFactor rest
  go coefficient Nothing (Symbol name : rest)
    | dispatchHead name == Just "Pi" = go coefficient (Just 1) rest
    | dispatchHead name == Just "Degree" = go coefficient (Just (1 % 180)) rest
  go _ _ _ = Nothing
rationalPiMultiple _ = Nothing

integerDivisors :: Integer -> [Integer]
integerDivisors value = positiveDivisors (abs value)

cyclotomicPolynomial :: Integer -> Maybe QPoly
cyclotomicPolynomial orderValue
  | orderValue <= 0 || orderValue > 4096 = Nothing
  | orderValue == 1 = Just (integerPoly [-1, 1])
  | otherwise = do
      let source =
            mkPoly
              ([-1] <> replicate (fromInteger orderValue - 1) 0 <> [1])
          properDivisors = filter (< orderValue) (integerDivisors orderValue)
      divisorFactors <- traverse cyclotomicPolynomial properDivisors
      foldM polyExactDivide source divisorFactors

cosineAlgebraic :: AlgebraicRootContext -> Q -> Maybe Algebraic
cosineAlgebraic context multiple = do
  let reduced = multiple / 2
      orderValue = denominator reduced
      angle = pi * fromRational multiple
  cyclotomic <- cyclotomicPolynomial orderValue
  candidate <-
    resultantOverX
      (map (\coefficient -> QPoly [coefficient]) (qPolyCoefficients cyclotomic))
      [onePoly, polyScale (-2) xPoly, onePoly]
  algebraicResult context candidate (cos angle :+ 0)

sineAlgebraic :: AlgebraicRootContext -> Q -> Maybe Algebraic
sineAlgebraic context multiple = cosineAlgebraic context (1 % 2 - multiple)

trigAlgebraic :: AlgebraicRootContext -> Text -> Q -> Maybe Algebraic
trigAlgebraic context headName multiple = case headName of
  "Cos" -> cosineAlgebraic context multiple
  "Sin" -> sineAlgebraic context multiple
  "Tan" -> do
    numeratorValue <- sineAlgebraic context multiple
    denominatorValue <- cosineAlgebraic context multiple
    divideTrig numeratorValue denominatorValue
  "Cot" -> do
    numeratorValue <- cosineAlgebraic context multiple
    denominatorValue <- sineAlgebraic context multiple
    divideTrig numeratorValue denominatorValue
  "Sec" -> algebraicReciprocal context =<< cosineAlgebraic context multiple
  "Csc" -> algebraicReciprocal context =<< sineAlgebraic context multiple
  _ -> Nothing
 where
  divideTrig numeratorValue denominatorValue = do
    inverse <- algebraicReciprocal context denominatorValue
    algebraicMultiply context numeratorValue inverse

trigAlgebraicFromExpr :: AlgebraicRootContext -> Expr -> Maybe Algebraic
trigAlgebraicFromExpr context expression
  | Just (headName, [argument]) <- callHead expression
  , headName `elem` ["Sin", "Cos", "Tan", "Cot", "Sec", "Csc"] = do
      multiple <- rationalPiMultiple argument
      trigAlgebraic context headName multiple
  | Just (headName, [argument]) <- callHead expression
  , Just baseName <- T.stripSuffix "Degrees" headName
  , baseName `elem` ["Sin", "Cos", "Tan", "Cot", "Sec", "Csc"] = do
      degreeValue <- exactQ argument
      trigAlgebraic context baseName (degreeValue / 180)
  | Just ("Haversine", [argument]) <- callHead expression = do
      multiple <- rationalPiMultiple argument
      cosine <- cosineAlgebraic context multiple
      negated <- algebraicNegate context cosine
      difference <- algebraicAdd context (rationalAlgebraic 1) negated
      algebraicMultiply context difference (rationalAlgebraic (1 % 2))
  | otherwise = Nothing

perfectIntegerRoot :: Integer -> Integer -> Maybe Integer
perfectIntegerRoot value degreeValue
  | value < 0 || degreeValue <= 0 = Nothing
  | otherwise =
      let approximate = round (fromInteger value ** (1 / fromInteger degreeValue) :: Double)
          candidates = filter (>= 0) [approximate - 1, approximate, approximate + 1]
       in case [candidate | candidate <- candidates, candidate ^ degreeValue == value] of
            candidate : _ -> Just candidate
            [] -> Nothing

exactRadical :: AlgebraicRootContext -> Q -> Integer -> Expr
exactRadical context value degreeValue
  | value == 0 = Integer 0
  | value > 0
  , Just numeratorRoot <- perfectIntegerRoot (numerator value) degreeValue
  , Just denominatorRoot <- perfectIntegerRoot (denominator value) degreeValue =
      qExpr (numeratorRoot % denominatorRoot)
  | value < 0 && degreeValue == 2 =
      expressionMultiply
        context
        (Complex (Integer 0) (Integer 1))
        (exactRadical context (negate value) degreeValue)
  | otherwise = expressionPower context (qExpr value) (Rational 1 degreeValue)

quadraticRadical :: AlgebraicRootContext -> RootValue -> Maybe Expr
quadraticRadical context (RootValue polynomial target) = do
  guard (polyDegree polynomial == 2)
  let a = polyCoefficient 2 polynomial
      b = polyCoefficient 1 polynomial
      c = polyCoefficient 0 polynomial
      discriminant = b * b - 4 * a * c
      radical = exactRadical context discriminant 2
      denominatorExpr = qExpr (2 * a)
      first = expressionDivide context (expressionAdd context (qExpr (negate b)) (expressionNegate context radical)) denominatorExpr
      second = expressionDivide context (expressionAdd context (qExpr (negate b)) radical) denominatorExpr
      candidates = [first, second]
      approximations =
        [ ((-fromRational b) - sqrt (fromRational discriminant :+ 0)) / (2 * fromRational a)
        , ((-fromRational b) + sqrt (fromRational discriminant :+ 0)) / (2 * fromRational a)
        ]
      indexed = zip candidates approximations
  pure (fst (minimumBy (comparing (Complex.magnitude . subtract target . snd)) indexed))

data RootValue = RootValue QPoly (Complex Double)

rootValueFromExpr :: Expr -> Maybe RootValue
rootValueFromExpr (Root coefficients index _) = do
  let polynomial = integerPoly coefficients
  target <- selectApproximateRoot polynomial index
  pure (RootValue polynomial target)
rootValueFromExpr _ = Nothing

binomialRadical :: AlgebraicRootContext -> RootValue -> Maybe Expr
binomialRadical context (RootValue polynomial target) = do
  let degreeValue = polyDegree polynomial
      middle = [polyCoefficient exponentValue polynomial | exponentValue <- [1 .. degreeValue - 1]]
  guard (degreeValue == 3 || degreeValue == 4)
  guard (all (== 0) middle)
  let radicand = negate (polyCoefficient 0 polynomial) / polyLeading polynomial
      magnitudeExpr = exactRadical context (abs radicand) (toInteger degreeValue)
      realPart = Complex.realPart target
      imaginaryPart = Complex.imagPart target
  if rootIsNumericallyReal target
    then
      Just
        ( if realPart < 0
            then expressionNegate context magnitudeExpr
            else magnitudeExpr
        )
    else
      if abs realPart < 1e-8
        then
          Just
            ( expressionMultiply
                context
                (Complex (Integer 0) (Integer (if imaginaryPart < 0 then -1 else 1)))
                magnitudeExpr
            )
        else Nothing

rootToRadicals :: AlgebraicRootContext -> Expr -> Expr
rootToRadicals context expression = case rootValueFromExpr expression of
  Nothing -> expression
  Just rootValue@(RootValue polynomial _) ->
    fromMaybe expression $ case polyDegree polynomial of
      1 -> do
        let result = negate (polyCoefficient 0 polynomial) / polyCoefficient 1 polynomial
        pure (qExpr result)
      2 -> quadraticRadical context rootValue
      3 -> binomialRadical context rootValue
      4 -> binomialRadical context rootValue
      _ -> Nothing

toRadicalsRecursive :: AlgebraicRootContext -> Expr -> Expr
toRadicalsRecursive context expression@Root {} = rootToRadicals context expression
toRadicalsRecursive context (Call expressionHead values) =
  let converted = map (toRadicalsRecursive context) values
   in if converted == values
        then Call expressionHead values
        else simplifyAlgebraicExpression context (Call expressionHead converted)
toRadicalsRecursive _ expression = expression

reduceToRadicals :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceToRadicals context [expression] = Just (toRadicalsRecursive context expression)
reduceToRadicals _ _ = Nothing

data RealEndpoint
  = NegativeInfinity
  | FiniteEndpoint Q
  | PositiveInfinity
  deriving (Eq, Ord, Show)

endpointFromExpr :: Expr -> Maybe RealEndpoint
endpointFromExpr expression
  | Just value <- exactQ expression = Just (FiniteEndpoint value)
endpointFromExpr (Symbol name)
  | dispatchHead name == Just "Infinity" = Just PositiveInfinity
endpointFromExpr expression
  | Just ("Times", [Integer (-1), Symbol name]) <- callHead expression
  , dispatchHead name == Just "Infinity" = Just NegativeInfinity
endpointFromExpr _ = Nothing

sturmSequence :: QPoly -> [QPoly]
sturmSequence polynomial = go [polySquareFree polynomial, polyDerivative (polySquareFree polynomial)]
 where
  go retained
    | length retained < 2 = retained
    | otherwise =
        let previous = retained !! (length retained - 2)
            current = last retained
         in if polyIsZero current
              then init retained
              else case polyDivMod previous current of
                Nothing -> retained
                Just (_, remainder)
                  | polyIsZero remainder -> retained
                  | otherwise -> go (retained <> [polyNegate remainder])

signOfQ :: Q -> Int
signOfQ value = compareOrdering (compare value 0)
 where
  compareOrdering LT = -1
  compareOrdering EQ = 0
  compareOrdering GT = 1

polySignAtEndpoint :: QPoly -> RealEndpoint -> Int
polySignAtEndpoint polynomial endpoint = case endpoint of
  FiniteEndpoint value -> signOfQ (polyEvaluate polynomial value)
  PositiveInfinity -> signOfQ (polyLeading polynomial)
  NegativeInfinity ->
    let sign = signOfQ (polyLeading polynomial)
     in if odd (polyDegree polynomial) then negate sign else sign

signVariations :: [Int] -> Int
signVariations values =
  length
    [ ()
    | (left, right) <- zip retained (drop 1 retained)
    , left /= right
    ]
 where
  retained = filter (/= 0) values

sturmVariations :: QPoly -> RealEndpoint -> Int
sturmVariations polynomial endpoint =
  signVariations (map (`polySignAtEndpoint` endpoint) (sturmSequence polynomial))

countFactorRootsInclusive :: QPoly -> RealEndpoint -> RealEndpoint -> Int
countFactorRootsInclusive polynomial first second
  | first == second = case first of
      FiniteEndpoint value -> if polyEvaluate polynomial value == 0 then 1 else 0
      _ -> 0
  | otherwise =
      let lower = min first second
          upper = max first second
          interiorAndUpper = sturmVariations polynomial lower - sturmVariations polynomial upper
          lowerCorrection = case lower of
            FiniteEndpoint value -> if polyEvaluate polynomial value == 0 then 1 else 0
            _ -> 0
       in interiorAndUpper + lowerCorrection

countRealRootsWithMultiplicity :: QPoly -> RealEndpoint -> RealEndpoint -> Integer
countRealRootsWithMultiplicity polynomial lower upper =
  sum
    [ toInteger multiplicity * toInteger (countFactorRootsInclusive factor lower upper)
    | (factor, multiplicity) <- squareFreeFactors polynomial
    ]

endpointComplex :: AlgebraicRootContext -> Expr -> Maybe (Complex Double)
endpointComplex _ expression
  | Just value <- exactQ expression = Just (fromRational value :+ 0)
endpointComplex _ (Complex realPart imaginaryPart) = do
  realValue <- exactQ realPart
  imaginaryValue <- exactQ imaginaryPart
  pure (fromRational realValue :+ fromRational imaginaryValue)
endpointComplex context expression = algebraicApproximation <$> algebraicFromExpr context expression

reduceCountRoots :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceCountRoots context [polynomialExpr, Call (Symbol listHead) [variable, lowerExpr, upperExpr]]
  | systemHeadIs "List" listHead = do
      polynomial <- rationalPolynomialInVariable context variable polynomialExpr
      case (endpointFromExpr lowerExpr, endpointFromExpr upperExpr) of
        (Just lower, Just upper) ->
          pure (Integer (countRealRootsWithMultiplicity polynomial lower upper))
        _ -> do
          lower <- endpointComplex context lowerExpr
          upper <- endpointComplex context upperExpr
          roots <- approximateRootsWithMultiplicity polynomial
          let lowerReal = min (Complex.realPart lower) (Complex.realPart upper)
              upperReal = max (Complex.realPart lower) (Complex.realPart upper)
              lowerImaginary = min (Complex.imagPart lower) (Complex.imagPart upper)
              upperImaginary = max (Complex.imagPart lower) (Complex.imagPart upper)
              within value =
                Complex.realPart value >= lowerReal - 1e-8
                  && Complex.realPart value <= upperReal + 1e-8
                  && Complex.imagPart value >= lowerImaginary - 1e-8
                  && Complex.imagPart value <= upperImaginary + 1e-8
          pure (Integer (toInteger (length (filter within roots))))
reduceCountRoots context [polynomialExpr, variable] = do
  polynomial <- rationalPolynomialInVariable context variable polynomialExpr
  pure (Integer (countRealRootsWithMultiplicity polynomial NegativeInfinity PositiveInfinity))
reduceCountRoots _ _ = Nothing

dyadicBounds :: Double -> Int -> (Q, Q)
dyadicBounds value exponentValue =
  let denominatorValue = 2 ^ exponentValue
      scaled = value * fromInteger denominatorValue
      nearest = round scaled
   in if abs (scaled - fromInteger nearest) < 1e-11
        then
          ( (2 * nearest - 1) % (2 * denominatorValue)
          , (2 * nearest + 1) % (2 * denominatorValue)
          )
        else
          let lower = floor scaled
           in (lower % denominatorValue, (lower + 1) % denominatorValue)

isolatingExponent :: Expr -> Int
isolatingExponent (Integer value)
  | value > 0 = fromInteger (min 30 (max 6 value))
isolatingExponent _ = 6

reduceIsolatingInterval :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceIsolatingInterval _ [expression]
  | Just value <- exactQ expression = Just (listExpr [qExpr value, qExpr value])
reduceIsolatingInterval _ [expression, _]
  | Just value <- exactQ expression = Just (listExpr [qExpr value, qExpr value])
reduceIsolatingInterval _ values = do
  (coefficients, index, exponentValue) <- case values of
    [Root coefficientsValue indexValue _] -> Just (coefficientsValue, indexValue, 6)
    [Root coefficientsValue indexValue _, exponentExpr] ->
      Just (coefficientsValue, indexValue, isolatingExponent exponentExpr)
    _ -> Nothing
  target <- selectApproximateRoot (integerPoly coefficients) index
  if rootIsNumericallyReal target
    then
      let (lower, upper) = dyadicBounds (Complex.realPart target) exponentValue
       in Just (listExpr [qExpr lower, qExpr upper])
    else
      let (lowerReal, upperReal) = dyadicBounds (Complex.realPart target) exponentValue
          (lowerImaginary, upperImaginary) = dyadicBounds (Complex.imagPart target) exponentValue
       in Just
            ( listExpr
                [ Complex (qExpr lowerReal) (qExpr lowerImaginary)
                , Complex (qExpr upperReal) (qExpr upperImaginary)
                ]
            )

rootIntervalEntry :: QPoly -> Int -> Complex Double -> (Q, Q, Int)
rootIntervalEntry factor multiplicity target =
  case
      [value | value <- rationalRoots factor, abs (fromRational value - Complex.realPart target) < 1e-8] of
    value : _ -> (value, value, multiplicity)
    [] ->
      let realValue = Complex.realPart target
          lower = floor realValue
          upper = ceiling realValue
       in if lower == upper
            then
              let (dyadicLower, dyadicUpper) = dyadicBounds realValue 6
               in (dyadicLower, dyadicUpper, multiplicity)
            else (lower % 1, upper % 1, multiplicity)

reduceRootIntervals :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceRootIntervals context [polynomialExpr] = do
  variable <- singlePolynomialVariable polynomialExpr
  polynomial <- rationalPolynomialInVariable context variable polynomialExpr
  entriesByFactor <- traverse factorEntries (squareFreeFactors polynomial)
  let entries = sortBy (comparing (\(lower, _, _) -> lower)) (concat entriesByFactor)
      intervalExpressions = [listExpr [qExpr lower, qExpr upper] | (lower, upper, _) <- entries]
      multiplicityExpressions = [listExpr [Integer (toInteger multiplicity)] | (_, _, multiplicity) <- entries]
  pure (listExpr [listExpr intervalExpressions, listExpr multiplicityExpressions])
 where
  factorEntries (factor, multiplicity) = do
    roots <- approximatePolynomialRoots factor
    pure
      [ rootIntervalEntry factor multiplicity rootValue
      | rootValue <- roots
      , rootIsNumericallyReal rootValue
      ]
reduceRootIntervals _ _ = Nothing

substituteExpression :: Expr -> Expr -> Expr -> Expr
substituteExpression target replacement expression
  | expression == target = replacement
substituteExpression _ _ expression@(Call (Symbol headName) _)
  | systemHeadIs "Function" headName = expression
substituteExpression target replacement (Call expressionHead values) =
  Call
    (substituteExpression target replacement expressionHead)
    (map (substituteExpression target replacement) values)
substituteExpression _ _ expression = expression

substituteSlots :: Expr -> Expr -> Expr
substituteSlots replacement expression
  | Just ("Slot", values) <- callHead expression
  , null values || values == [Integer 1] = replacement
substituteSlots _ expression@(Call (Symbol headName) _)
  | systemHeadIs "Function" headName = expression
substituteSlots replacement (Call expressionHead values) =
  Call
    (substituteSlots replacement expressionHead)
    (map (substituteSlots replacement) values)
substituteSlots _ expression = expression

applyPureFunction :: AlgebraicRootContext -> Expr -> Expr -> Maybe Expr
applyPureFunction context (Call (Symbol headName) values) argument
  | systemHeadIs "Function" headName = case values of
      [body] -> Just (simplifyAlgebraicExpression context (substituteSlots argument body))
      [parameter@(Symbol _), body] ->
        Just (simplifyAlgebraicExpression context (substituteExpression parameter argument body))
      [Call (Symbol listHead) [parameter@(Symbol _)], body]
        | systemHeadIs "List" listHead ->
            Just (simplifyAlgebraicExpression context (substituteExpression parameter argument body))
      _ -> Nothing
applyPureFunction _ _ _ = Nothing

isPureFunction :: Expr -> Bool
isPureFunction (Call (Symbol headName) _) = systemHeadIs "Function" headName
isPureFunction _ = False

polynomialRootExpressions
  :: AlgebraicRootContext
  -> QPoly
  -> Maybe [(Complex Double, Expr)]
polynomialRootExpressions context polynomial = do
  entriesByFactor <- traverse rootsForFactor (squareFreeFactors polynomial)
  pure (sortBy (comparing fstRoot) (concat entriesByFactor))
 where
  fstRoot (rootValue, _) =
    ( not (rootIsNumericallyReal rootValue)
    , Complex.realPart rootValue
    , Complex.imagPart rootValue
    )
  rootsForFactor (factor, multiplicity) = do
    roots <- approximatePolynomialRoots factor
    traverse
      (\rootValue -> do
          expression <- canonicalRootFromPolynomial context factor rootValue 0
          pure (replicate multiplicity (rootValue, expression))
      )
      roots
      >>= pure . concat

normalRootSum :: AlgebraicRootContext -> [Expr] -> Maybe Expr
normalRootSum context [polynomialFunction, mapping] = do
  polynomial <- rationalFunctionPolynomial context polynomialFunction
  roots <- polynomialRootExpressions context polynomial
  terms <- traverse mappedRoot roots
  pure $ case terms of
    [] -> Integer 0
    [term] -> term
    _ -> simplifyCall context "Plus" terms
 where
  mappedRoot (_, rootExpression) =
    let radicalRoot = toRadicalsRecursive context rootExpression
     in case applyPureFunction context mapping radicalRoot of
          Just result -> Just result
          Nothing -> Just (simplifyAlgebraicExpression context (Call mapping [radicalRoot]))
normalRootSum _ _ = Nothing

reduceRootSum :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceRootSum context values@[_, mapping]
  | isPureFunction mapping = do
      expanded <- normalRootSum context values
      fromMaybe expanded <$> pure (reduceRootReduce context [expanded])
reduceRootSum _ _ = Nothing

data SolveEquationSet
  = SolveContradiction
  | SolveEquations [Expr]

truthValue :: Expr -> Maybe Bool
truthValue (Symbol name)
  | dispatchHead name == Just "True" = Just True
  | dispatchHead name == Just "False" = Just False
truthValue _ = Nothing

solveVariables :: Expr -> Maybe [Expr]
solveVariables (Call (Symbol headName) values)
  | systemHeadIs "List" headName = do
      guard (not (null values) && length (nub values) == length values)
      pure values
solveVariables variable = Just [variable]

solveEquationExpressions :: AlgebraicRootContext -> Expr -> Maybe SolveEquationSet
solveEquationExpressions _ specification
  | Just False <- truthValue specification = Just SolveContradiction
  | Just True <- truthValue specification = Just (SolveEquations [])
solveEquationExpressions context (Call (Symbol headName) values)
  | systemHeadIs "List" headName = foldM retain (SolveEquations []) values
 where
  retain SolveContradiction _ = Just SolveContradiction
  retain (SolveEquations retained) expression
    | Just True <- truthValue expression = Just (SolveEquations retained)
    | Just False <- truthValue expression = Just SolveContradiction
    | otherwise = do
        expanded <- equationDifferences context expression
        pure (SolveEquations (retained <> expanded))
solveEquationExpressions context specification =
  SolveEquations <$> equationDifferences context specification

equationDifferences :: AlgebraicRootContext -> Expr -> Maybe [Expr]
equationDifferences context expression
  | Just ("Equal", values) <- callHead expression = case values of
      [] -> Just []
      [_] -> Just []
      _ ->
        Just
          [ expressionAdd context left (expressionNegate context right)
          | (left, right) <- zip values (drop 1 values)
          ]
equationDifferences _ expression = Just [expression]

rationalPolynomialInVariableAny
  :: AlgebraicRootContext
  -> Expr
  -> Expr
  -> Maybe QPoly
rationalPolynomialInVariableAny context variable expression = do
  polynomial <- expressionPolynomial context (Just variable) False expression
  if Map.null polynomial
    then Just zeroPoly
    else do
      let degreeValue = fst (Map.findMax polynomial)
      coefficients <-
        traverse
          (exactQ . fromMaybe (Integer 0) . (`Map.lookup` polynomial))
          [0 .. degreeValue]
      pure (mkPoly coefficients)

solveUnivariateRational
  :: AlgebraicRootContext
  -> Expr
  -> [Expr]
  -> Maybe Expr
solveUnivariateRational context variable equations = do
  polynomials <- traverse (rationalPolynomialInVariableAny context variable) equations
  let nonzero = filter (not . polyIsZero) polynomials
  if any ((<= 0) . polyDegree) nonzero
    then Just (listExpr [])
    else case nonzero of
      [] -> Just (listExpr [listExpr []])
      first : rest -> do
        let common = foldl' polyGcd first rest
        if polyDegree common <= 0
          then Just (listExpr [])
          else do
            let squareFree = polySquareFree common
            guard (toInteger (polyDegree squareFree) <= maximumAlgebraicRootDegree context)
            roots <- approximatePolynomialRoots squareFree
            solutions <-
              traverse
                (\rootValue -> do
                    solution <- canonicalRootFromPolynomial context squareFree rootValue 0
                    pure (listExpr [ruleExpr variable solution])
                )
                roots
            pure (listExpr solutions)

containsAnyVariable :: [Expr] -> Expr -> Bool
containsAnyVariable variables expression
  | expression `elem` variables = True
containsAnyVariable variables (Call expressionHead values) =
  containsAnyVariable variables expressionHead
    || any (containsAnyVariable variables) values
containsAnyVariable _ _ = False

allowedSolveConstant :: [Expr] -> Expr -> Bool
allowedSolveConstant variables expression
  | expression `elem` variables = False
allowedSolveConstant _ (Integer _) = True
allowedSolveConstant _ (Rational _ _) = True
allowedSolveConstant _ (Real _) = True
allowedSolveConstant _ (Complex realPart imaginaryPart) =
  allowedSolveConstant [] realPart && allowedSolveConstant [] imaginaryPart
allowedSolveConstant _ (Root {}) = True
allowedSolveConstant variables (Symbol name) =
  dispatchHead name /= Nothing && not (Symbol name `elem` variables)
allowedSolveConstant variables (Call expressionHead values) =
  allowedSolveConstant variables expressionHead
    && all (allowedSolveConstant variables) values
allowedSolveConstant _ _ = False

type LinearForm = ([Expr], Expr)

zeroLinearForm :: Int -> LinearForm
zeroLinearForm count = (replicate count (Integer 0), Integer 0)

addLinearForms
  :: AlgebraicRootContext
  -> LinearForm
  -> LinearForm
  -> LinearForm
addLinearForms context (leftCoefficients, leftConstant) (rightCoefficients, rightConstant) =
  ( zipWith (expressionAdd context) leftCoefficients rightCoefficients
  , expressionAdd context leftConstant rightConstant
  )

scaleLinearForm :: AlgebraicRootContext -> Expr -> LinearForm -> LinearForm
scaleLinearForm context scale (coefficients, constant) =
  ( map (expressionMultiply context scale) coefficients
  , expressionMultiply context scale constant
  )

linearForm
  :: AlgebraicRootContext
  -> [Expr]
  -> Expr
  -> Maybe LinearForm
linearForm _ variables expression
  | Just index <- lookupIndex expression variables =
      Just
        ( [if current == index then Integer 1 else Integer 0 | current <- [0 .. length variables - 1]]
        , Integer 0
        )
 where
  lookupIndex target = go 0
   where
    go _ [] = Nothing
    go index (value : rest)
      | target == value = Just index
      | otherwise = go (index + 1) rest
linearForm context variables expression
  | Just ("Plus", values) <- callHead expression = do
      terms <- traverse (linearForm context variables) values
      pure (foldl' (addLinearForms context) (zeroLinearForm (length variables)) terms)
  | Just ("Times", values) <- callHead expression = do
      let (variableFactors, constants) =
            foldr
              (\value (dependent, independent) ->
                  if containsAnyVariable variables value
                    then (value : dependent, independent)
                    else (dependent, value : independent)
              )
              ([], [])
              values
      guard (length variableFactors <= 1 && all (allowedSolveConstant variables) constants)
      let scale = case constants of
            [] -> Integer 1
            [value] -> value
            _ -> simplifyCall context "Times" constants
      case variableFactors of
        [] -> Just (replicate (length variables) (Integer 0), scale)
        [factor] -> scaleLinearForm context scale <$> linearForm context variables factor
        _ -> Nothing
  | not (containsAnyVariable variables expression)
  , allowedSolveConstant variables expression =
      Just (replicate (length variables) (Integer 0), expression)
linearForm _ _ _ = Nothing

linearSystemSolution
  :: AlgebraicRootContext
  -> [[Expr]]
  -> [Expr]
  -> Maybe [Expr]
linearSystemSolution context coefficients rhsValues = do
  let size = length coefficients
      augmented = zipWith (\row rhsValue -> row <> [rhsValue]) coefficients rhsValues
  guard (size > 0 && all ((== size) . length) coefficients)
  reduced <- foldM eliminateColumn augmented [0 .. size - 1]
  pure [last (reduced !! rowIndex) | rowIndex <- [0 .. size - 1]]
 where
  eliminateColumn matrix columnIndex = do
    pivotRow <-
      case
          [ rowIndex
          | rowIndex <- [columnIndex .. length matrix - 1]
          , matrixAt matrix rowIndex columnIndex /= Integer 0
          ] of
        [] -> Nothing
        rowIndex : _ -> Just rowIndex
    let swapped = swapRows columnIndex pivotRow matrix
        pivot = matrixAt swapped columnIndex columnIndex
        normalizedRow = map (\value -> expressionDivide context value pivot) (swapped !! columnIndex)
        normalized = replaceAt columnIndex normalizedRow swapped
        eliminateRow retained rowIndex
          | rowIndex == columnIndex = retained
          | otherwise =
              let factor = matrixAt retained rowIndex columnIndex
                  row = retained !! rowIndex
                  updatedRow =
                    zipWith
                      (\value pivotValue -> expressionAdd context value (expressionNegate context (expressionMultiply context factor pivotValue)))
                      row
                      normalizedRow
               in replaceAt rowIndex updatedRow retained
    pure (foldl' eliminateRow normalized [0 .. length normalized - 1])

solveSquareLinear
  :: AlgebraicRootContext
  -> [Expr]
  -> [Expr]
  -> Maybe Expr
solveSquareLinear context variables equations = do
  guard (length variables == length equations && not (null variables))
  forms <- traverse (linearForm context variables) equations
  let coefficients = map fst forms
      rhsValues = map (expressionNegate context . snd) forms
  solutions <- linearSystemSolution context coefficients rhsValues
  pure (listExpr [listExpr (zipWith ruleExpr variables solutions)])

reduceSolve :: AlgebraicRootContext -> [Expr] -> Maybe Expr
reduceSolve context [equationSpecification, variableSpecification] = do
  variables <- solveVariables variableSpecification
  equationSet <- solveEquationExpressions context equationSpecification
  case equationSet of
    SolveContradiction -> Just (listExpr [])
    SolveEquations [] -> Just (listExpr [listExpr []])
    SolveEquations equations -> case variables of
      [variable] ->
        case solveUnivariateRational context variable equations of
          Just result -> Just result
          Nothing -> solveSquareLinear context variables equations
      _ -> solveSquareLinear context variables equations
reduceSolve _ _ = Nothing
