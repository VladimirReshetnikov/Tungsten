{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact, kernel-free polynomial transformations.
--
-- The representation is deliberately small: coefficients live in Q(i), and
-- monomials use nonnegative machine-sized exponents.  Expressions outside
-- that ring are rejected so the evaluator can preserve them symbolically.
module Tungsten.PolynomialAlgebra
  ( reducePolynomialBuiltin
  ) where

import Prelude hiding (exponent)
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import Tungsten.Expression hiding (arguments)

data Exact = Exact !Integer !Integer
  deriving (Eq, Ord, Show)

data Gaussian = Gaussian !Exact !Exact
  deriving (Eq, Ord, Show)

newtype Polynomial = Polynomial {polynomialTerms :: Map.Map [Int] Gaussian}
  deriving (Eq, Show)

type CanonicalCompare = Expr -> Expr -> Ordering

reducePolynomialBuiltin :: CanonicalCompare -> Text -> [Expr] -> Maybe Expr
reducePolynomialBuiltin compareExpression headName values = case headName of
  "Simplify" -> unaryIdentity values
  "FullSimplify" -> unaryIdentity values
  "Expand" -> reduceExpand compareExpression values
  "PolynomialQ" -> reducePolynomialQ compareExpression values
  "Variables" -> reduceVariables compareExpression values
  "Coefficient" -> reduceCoefficient compareExpression values
  "CoefficientList" -> reduceCoefficientList compareExpression values
  _ -> Nothing

unaryIdentity :: [Expr] -> Maybe Expr
unaryIdentity [value] = Just value
unaryIdentity _ = Nothing

reduceExpand :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceExpand compareExpression [expression] = do
  let variables = discoverVariables compareExpression [] [expression]
  polynomial <- expressionToPolynomial variables expression
  pure (polynomialToExpr compareExpression variables polynomial)
reduceExpand compareExpression [expression, variable]
  | variable `elem` discoverVariables compareExpression [] [expression] =
      reduceExpand compareExpression [expression]
  | otherwise = Just expression
reduceExpand _ _ = Nothing

reducePolynomialQ :: CanonicalCompare -> [Expr] -> Maybe Expr
reducePolynomialQ compareExpression arguments = case arguments of
  [expression] ->
    let variables = discoverVariables compareExpression [] [expression]
     in Just (booleanExpr (hasPolynomialForm variables expression))
  [expression, variableSpec] -> do
    explicitVariables <- variableExpressions variableSpec
    let variables = discoverVariables compareExpression explicitVariables [expression]
    pure (booleanExpr (hasPolynomialForm variables expression))
  _ -> Nothing

reduceVariables :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceVariables compareExpression [expression] =
  let variables = discoverVariables compareExpression [] [expression]
   in if hasPolynomialForm variables expression
        then Just (Call (Symbol "List") variables)
        else Nothing
reduceVariables _ _ = Nothing

reduceCoefficient :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceCoefficient compareExpression arguments = case arguments of
  [expression, form] -> coefficientAt compareExpression expression form 1
  [expression, form, Integer exponent]
    | exponent < 0 -> Just (Integer 0)
    | exponent <= fromIntegral (maxBound :: Int) ->
        coefficientAt compareExpression expression form (fromIntegral exponent)
  [expression, Call (Symbol listHead) forms, Call (Symbol exponentHead) exponents]
    | systemHeadIn "List" listHead
    , systemHeadIn "List" exponentHead
    , length forms == length exponents -> do
        results <-
          traverse
            (\(form, exponent) -> reduceCoefficient compareExpression [expression, form, exponent])
            (zip forms exponents)
        pure (Call (Symbol "List") results)
  _ -> Nothing

coefficientAt :: CanonicalCompare -> Expr -> Expr -> Int -> Maybe Expr
coefficientAt compareExpression expression form exponent =
  naturalCoefficient `orElse` opaqueCoefficient
 where
  naturalVariables = discoverVariables compareExpression [] [expression, form]
  naturalCoefficient = coefficientWith naturalVariables
  opaqueVariables = discoverVariables compareExpression [form] [expression]
  opaqueCoefficient = coefficientWith opaqueVariables
  coefficientWith variables = do
    polynomial <- expressionToPolynomial variables expression
    formPolynomial <- expressionToPolynomial variables form
    formPowers <- singleMonomialPowers formPolynomial
    let selected = coefficientPolynomial exponent formPowers polynomial
    pure (polynomialToExpr compareExpression variables selected)

reduceCoefficientList :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceCoefficientList compareExpression arguments = case arguments of
  [expression, variableSpec] -> coefficientListWith compareExpression expression variableSpec Nothing
  [expression, variableSpec, dimensionsSpec] -> do
    dimensions <- coefficientDimensions dimensionsSpec
    coefficientListWith compareExpression expression variableSpec (Just dimensions)
  _ -> Nothing

coefficientListWith
  :: CanonicalCompare
  -> Expr
  -> Expr
  -> Maybe [Int]
  -> Maybe Expr
coefficientListWith compareExpression expression variableSpec requestedDimensions = do
  explicitVariables <- variableExpressions variableSpec
  if maybe False ((/= length explicitVariables) . length) requestedDimensions
    then Nothing
    else do
      let variables = discoverVariables compareExpression explicitVariables [expression]
      polynomial <- expressionToPolynomial variables expression
      let targetIndices = mapMaybe (`indexOf` variables) explicitVariables
      if length targetIndices /= length explicitVariables
        then Nothing
        else
          Just
            ( coefficientArrayExpr
                compareExpression
                variables
                targetIndices
                requestedDimensions
                polynomial
            )

coefficientDimensions :: Expr -> Maybe [Int]
coefficientDimensions (Integer value)
  | value >= 0
  , value <= fromIntegral (maxBound :: Int) = Just [fromIntegral value]
coefficientDimensions (Call (Symbol headName) values)
  | systemHeadIn "List" headName = traverse exactNonnegativeInt values
coefficientDimensions _ = Nothing

exactNonnegativeInt :: Expr -> Maybe Int
exactNonnegativeInt (Integer value)
  | value >= 0
  , value <= fromIntegral (maxBound :: Int) = Just (fromIntegral value)
exactNonnegativeInt _ = Nothing

coefficientArrayExpr
  :: CanonicalCompare
  -> [Expr]
  -> [Int]
  -> Maybe [Int]
  -> Polynomial
  -> Expr
coefficientArrayExpr compareExpression variables targetIndices requestedDimensions polynomial
  | null targetIndices = polynomialToExpr compareExpression variables polynomial
  | isZeroPolynomial polynomial && requestedDimensions == Nothing = Call (Symbol "List") []
  | otherwise = build 0 []
 where
  inferredCounts =
    [ 1 + maximum (0 : [powers !! index | powers <- Map.keys (polynomialTerms polynomial)])
    | index <- targetIndices
    ]
  counts = maybe inferredCounts id requestedDimensions
  build depth chosen
    | depth == length targetIndices =
        polynomialToExpr
          compareExpression
          variables
          (coefficientSlice (zip targetIndices chosen) polynomial)
    | otherwise =
        Call
          (Symbol "List")
          [build (depth + 1) (chosen <> [power]) | power <- [0 .. counts !! depth - 1]]

coefficientSlice :: [(Int, Int)] -> Polynomial -> Polynomial
coefficientSlice selected (Polynomial terms) =
  Polynomial
    ( Map.fromListWith addGaussian
        [ (removeSelected powers, coefficient)
        | (powers, coefficient) <- Map.toList terms
        , all (\(index, exponent) -> powers !! index == exponent) selected
        ]
    )
 where
  removeSelected powers =
    foldl' (\current (index, _) -> replaceAt index 0 current) powers selected

coefficientPolynomial :: Int -> [Int] -> Polynomial -> Polynomial
coefficientPolynomial exponent formPowers (Polynomial terms) =
  Polynomial
    ( Map.fromListWith addGaussian
        [ (zipWith (-) powers required, coefficient)
        | (powers, coefficient) <- Map.toList terms
        , matches powers required
        ]
    )
 where
  required = map (* exponent) formPowers
  matches powers target =
    and
      [ if formPower == 0 then True else power == formPower
      | (power, formPower) <- zip powers target
      ]

singleMonomialPowers :: Polynomial -> Maybe [Int]
singleMonomialPowers (Polynomial terms) = case Map.toList terms of
  [(powers, coefficient)]
    | coefficient == oneGaussian -> Just powers
  _ -> Nothing

hasPolynomialForm :: [Expr] -> Expr -> Bool
hasPolynomialForm variables expression = case expressionToPolynomial variables expression of
  Just _ -> True
  Nothing -> False

expressionToPolynomial :: [Expr] -> Expr -> Maybe Polynomial
expressionToPolynomial variables expression
  | Just index <- indexOf expression variables =
      Just (variablePolynomial (length variables) index)
expressionToPolynomial variables expression = case exactGaussian expression of
  Just coefficient -> Just (constantPolynomial (length variables) coefficient)
  Nothing -> case expression of
    Call (Symbol headName) values
      | systemHeadIn "Plus" headName ->
          foldl' addMaybe (Just (zeroPolynomial (length variables))) (map (expressionToPolynomial variables) values)
      | systemHeadIn "Times" headName ->
          foldl' multiplyMaybe (Just (onePolynomial (length variables))) (map (expressionToPolynomial variables) values)
      | systemHeadIn "Power" headName
      , [base, Integer exponent] <- values
      , exponent >= 0
      , exponent <= 4096 -> do
          basePolynomial <- expressionToPolynomial variables base
          pure (powerPolynomial basePolynomial exponent)
    _ -> Nothing
 where
  addMaybe accumulator next = addPolynomial <$> accumulator <*> next
  multiplyMaybe accumulator next = multiplyPolynomial <$> accumulator <*> next

discoverVariables :: CanonicalCompare -> [Expr] -> [Expr] -> [Expr]
discoverVariables compareExpression explicit expressions =
  explicit <> sortBy compareExpression implicit
 where
  explicitSet = Set.fromList (map fullForm explicit)
  discovered = foldl' (flip (collectVariables explicit)) [] expressions
  implicit =
    uniqueByFullForm
      [ variable
      | variable <- discovered
      , Set.notMember (fullForm variable) explicitSet
      ]

collectVariables :: [Expr] -> Expr -> [Expr] -> [Expr]
collectVariables explicit expression retained
  | expression `elem` explicit = expression : retained
collectVariables _ (Symbol name) retained
  | systemHeadIn "I" name = retained
  | otherwise = Symbol name : retained
collectVariables explicit (Call (Symbol headName) values) retained
  | any (`systemHeadIn` headName) ["Plus", "Times", "Power"] =
      foldl' (flip (collectVariables explicit)) retained values
collectVariables explicit (Call expressionHead values) retained =
  foldl' (flip (collectVariables explicit)) retained (expressionHead : values)
collectVariables explicit (Complex realPart imaginaryPart) retained =
  collectVariables explicit imaginaryPart (collectVariables explicit realPart retained)
collectVariables _ _ retained = retained

uniqueByFullForm :: [Expr] -> [Expr]
uniqueByFullForm = go Set.empty
 where
  go _ [] = []
  go seen (value : rest)
    | Set.member key seen = go seen rest
    | otherwise = value : go (Set.insert key seen) rest
   where
    key = fullForm value

variableExpressions :: Expr -> Maybe [Expr]
variableExpressions (Call (Symbol headName) values)
  | systemHeadIn "List" headName = Just values
variableExpressions value = Just [value]

indexOf :: Eq item => item -> [item] -> Maybe Int
indexOf target = go 0
 where
  go _ [] = Nothing
  go index (value : rest)
    | target == value = Just index
    | otherwise = go (index + 1) rest

zeroPolynomial :: Int -> Polynomial
zeroPolynomial _ = Polynomial Map.empty

onePolynomial :: Int -> Polynomial
onePolynomial dimensions = constantPolynomial dimensions oneGaussian

constantPolynomial :: Int -> Gaussian -> Polynomial
constantPolynomial dimensions coefficient
  | coefficient == zeroGaussian = Polynomial Map.empty
  | otherwise = Polynomial (Map.singleton (replicate dimensions 0) coefficient)

variablePolynomial :: Int -> Int -> Polynomial
variablePolynomial dimensions index =
  Polynomial (Map.singleton (replaceAt index 1 (replicate dimensions 0)) oneGaussian)

addPolynomial :: Polynomial -> Polynomial -> Polynomial
addPolynomial (Polynomial left) (Polynomial right) =
  Polynomial (Map.filter (/= zeroGaussian) (Map.unionWith addGaussian left right))

multiplyPolynomial :: Polynomial -> Polynomial -> Polynomial
multiplyPolynomial (Polynomial left) (Polynomial right) =
  Polynomial
    ( Map.filter
        (/= zeroGaussian)
        ( Map.fromListWith
            addGaussian
            [ (zipWith (+) leftPowers rightPowers, multiplyGaussian leftCoefficient rightCoefficient)
            | (leftPowers, leftCoefficient) <- Map.toList left
            , (rightPowers, rightCoefficient) <- Map.toList right
            ]
        )
    )

powerPolynomial :: Polynomial -> Integer -> Polynomial
powerPolynomial base exponent = go exponent (onePolynomial (polynomialDimensions base)) base
 where
  go 0 accumulator _ = accumulator
  go remaining accumulator factor
    | odd remaining = go (remaining `div` 2) (multiplyPolynomial accumulator factor) (multiplyPolynomial factor factor)
    | otherwise = go (remaining `div` 2) accumulator (multiplyPolynomial factor factor)

polynomialDimensions :: Polynomial -> Int
polynomialDimensions (Polynomial terms) = case Map.lookupMin terms of
  Just (powers, _) -> length powers
  Nothing -> 0

isZeroPolynomial :: Polynomial -> Bool
isZeroPolynomial (Polynomial terms) = Map.null terms

polynomialToExpr :: CanonicalCompare -> [Expr] -> Polynomial -> Expr
polynomialToExpr compareExpression variables (Polynomial terms) =
  makePlus compareExpression
    [ monomialToExpr compareExpression variables powers coefficient
    | (powers, coefficient) <- Map.toList terms
    ]

monomialToExpr :: CanonicalCompare -> [Expr] -> [Int] -> Gaussian -> Expr
monomialToExpr compareExpression variables powers coefficient =
  makeTimes compareExpression (coefficientFactors <> variableFactors)
 where
  coefficientFactors
    | coefficient == oneGaussian && any (> 0) powers = []
    | otherwise = [gaussianToExpr coefficient]
  variableFactors =
    [ if exponent == 1
        then variable
        else Call (Symbol "Power") [variable, Integer (fromIntegral exponent)]
    | (variable, exponent) <- zip variables powers
    , exponent > 0
    ]

makePlus :: CanonicalCompare -> [Expr] -> Expr
makePlus compareExpression values = case sortBy compareExpression values of
  [] -> Integer 0
  [single] -> single
  sorted -> Call (Symbol "Plus") sorted

makeTimes :: CanonicalCompare -> [Expr] -> Expr
makeTimes compareExpression values
  | Integer 0 `elem` values = Integer 0
  | otherwise = case sortBy compareExpression (filter (/= Integer 1) values) of
      [] -> Integer 1
      [single] -> single
      sorted -> Call (Symbol "Times") sorted

replaceAt :: Int -> item -> [item] -> [item]
replaceAt index replacement values =
  [if current == index then replacement else value | (current, value) <- zip [0 ..] values]

exactGaussian :: Expr -> Maybe Gaussian
exactGaussian (Integer value) = Just (Gaussian (exact value 1) zeroExact)
exactGaussian (Rational numerator denominator)
  | denominator /= 0 = Just (Gaussian (exact numerator denominator) zeroExact)
exactGaussian (Complex realPart imaginaryPart) = do
  Gaussian real zeroImaginary <- exactGaussian realPart
  Gaussian imaginary zeroNestedImaginary <- exactGaussian imaginaryPart
  if zeroImaginary == zeroExact && zeroNestedImaginary == zeroExact
    then Just (Gaussian real imaginary)
    else Nothing
exactGaussian (Symbol name)
  | systemHeadIn "I" name = Just (Gaussian zeroExact oneExact)
exactGaussian _ = Nothing

gaussianToExpr :: Gaussian -> Expr
gaussianToExpr (Gaussian real imaginary)
  | imaginary == zeroExact = exactToExpr real
  | otherwise = Complex (exactToExpr real) (exactToExpr imaginary)

exactToExpr :: Exact -> Expr
exactToExpr (Exact numerator denominator)
  | denominator == 1 = Integer numerator
  | otherwise = Rational numerator denominator

zeroExact :: Exact
zeroExact = Exact 0 1

oneExact :: Exact
oneExact = Exact 1 1

zeroGaussian :: Gaussian
zeroGaussian = Gaussian zeroExact zeroExact

oneGaussian :: Gaussian
oneGaussian = Gaussian oneExact zeroExact

exact :: Integer -> Integer -> Exact
exact _ 0 = zeroExact
exact numerator denominator =
  let sign = if denominator < 0 then -1 else 1
      divisor = gcd numerator denominator
   in Exact (sign * numerator `div` divisor) (abs denominator `div` divisor)

addExact :: Exact -> Exact -> Exact
addExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  exact
    (leftNumerator * rightDenominator + rightNumerator * leftDenominator)
    (leftDenominator * rightDenominator)

negateExact :: Exact -> Exact
negateExact (Exact numerator denominator) = Exact (negate numerator) denominator

multiplyExact :: Exact -> Exact -> Exact
multiplyExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  exact (leftNumerator * rightNumerator) (leftDenominator * rightDenominator)

addGaussian :: Gaussian -> Gaussian -> Gaussian
addGaussian (Gaussian leftReal leftImaginary) (Gaussian rightReal rightImaginary) =
  Gaussian (addExact leftReal rightReal) (addExact leftImaginary rightImaginary)

multiplyGaussian :: Gaussian -> Gaussian -> Gaussian
multiplyGaussian (Gaussian leftReal leftImaginary) (Gaussian rightReal rightImaginary) =
  Gaussian
    ( addExact
        (multiplyExact leftReal rightReal)
        (negateExact (multiplyExact leftImaginary rightImaginary))
    )
    ( addExact
        (multiplyExact leftReal rightImaginary)
        (multiplyExact leftImaginary rightReal)
    )

booleanExpr :: Bool -> Expr
booleanExpr True = Symbol "True"
booleanExpr False = Symbol "False"

orElse :: Maybe value -> Maybe value -> Maybe value
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

systemHeadIn :: Text -> Text -> Bool
systemHeadIn expected actual = actual == expected || actual == "System`" <> expected
