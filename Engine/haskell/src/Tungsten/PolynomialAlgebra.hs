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
  "MonomialList" -> reduceMonomialList compareExpression values
  "Coefficient" -> reduceCoefficient compareExpression values
  "CoefficientList" -> reduceCoefficientList compareExpression values
  "Numerator" -> reduceFractionPart compareExpression True values
  "Denominator" -> reduceFractionPart compareExpression False values
  "Together" -> reduceRationalFunction compareExpression values
  "Cancel" -> reduceRationalFunction compareExpression values
  "Apart" -> reduceApart compareExpression values
  "Factor" -> reduceFactor compareExpression False values
  "FactorList" -> reduceFactor compareExpression True values
  "PolynomialGCD" -> reducePolynomialGcdLcm compareExpression False values
  "PolynomialLCM" -> reducePolynomialGcdLcm compareExpression True values
  "PolynomialMod" -> reducePolynomialMod compareExpression values
  "PolynomialQuotient" -> reducePolynomialDivision compareExpression True values
  "PolynomialRemainder" -> reducePolynomialDivision compareExpression False values
  "Resultant" -> reduceResultant compareExpression values
  "Discriminant" -> reduceDiscriminant compareExpression values
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

data MonomialOrder
  = MonomialLexicographic
  | MonomialDegreeLexicographic
  | MonomialDegreeReverseLexicographic
  deriving (Eq, Show)

data MonomialDirection
  = MonomialDescending
  | MonomialAscending
  deriving (Eq, Show)

reduceMonomialList :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceMonomialList compareExpression arguments = do
  (expression, explicitVariables, order, direction) <-
    monomialListArguments arguments
  let discoveredVariables =
        discoverVariables compareExpression explicitVariables [expression]
      orderingDimensions =
        if monomialListUsesImplicitVariables arguments
          then length discoveredVariables
          else length explicitVariables
  if hasDuplicateExpressions explicitVariables
    then Nothing
    else do
      polynomial <- expressionToPolynomial discoveredVariables expression
      let grouped
            | isZeroPolynomial polynomial && orderingDimensions > 0 =
                Map.singleton
                  (replicate orderingDimensions 0)
                  (zeroPolynomial (length discoveredVariables))
            | otherwise =
                groupMonomialTerms orderingDimensions polynomial
          ordered =
            sortBy
              (compareMonomialGroups order direction)
              (Map.toList grouped)
      pure
        ( Call
            (Symbol "List")
            [ groupedMonomialToExpr
                compareExpression
                discoveredVariables
                orderingDimensions
                powers
                groupedCoefficient
            | (powers, groupedCoefficient) <- ordered
            ]
        )

monomialListArguments
  :: [Expr]
  -> Maybe (Expr, [Expr], MonomialOrder, MonomialDirection)
monomialListArguments = \case
  [expression] ->
    Just
      ( expression
      , []
      , MonomialLexicographic
      , MonomialDescending
      )
  [expression, possibleOrder]
    | Just (order, direction) <- monomialOrder possibleOrder ->
        Just (expression, [], order, direction)
  [expression, variablesExpression] -> do
    variables <- variableExpressions variablesExpression
    Just
      ( expression
      , variables
      , MonomialLexicographic
      , MonomialDescending
      )
  [expression, variablesExpression, orderExpression] -> do
    variables <- variableExpressions variablesExpression
    (order, direction) <- monomialOrder orderExpression
    Just (expression, variables, order, direction)
  _ -> Nothing

monomialListUsesImplicitVariables :: [Expr] -> Bool
monomialListUsesImplicitVariables = \case
  [_] -> True
  [_, possibleOrder] -> case monomialOrder possibleOrder of
    Just _ -> True
    Nothing -> False
  _ -> False

monomialOrder :: Expr -> Maybe (MonomialOrder, MonomialDirection)
monomialOrder (Symbol name)
  | systemHeadIn "Lexicographic" name =
      Just (MonomialLexicographic, MonomialDescending)
  | systemHeadIn "DegreeLexicographic" name =
      Just (MonomialDegreeLexicographic, MonomialDescending)
  | systemHeadIn "DegreeReverseLexicographic" name =
      Just (MonomialDegreeReverseLexicographic, MonomialDescending)
  | systemHeadIn "NegativeLexicographic" name =
      Just (MonomialLexicographic, MonomialAscending)
  | systemHeadIn "NegativeDegreeLexicographic" name =
      Just (MonomialDegreeLexicographic, MonomialAscending)
  | systemHeadIn "NegativeDegreeReverseLexicographic" name =
      Just (MonomialDegreeReverseLexicographic, MonomialAscending)
monomialOrder _ = Nothing

hasDuplicateExpressions :: [Expr] -> Bool
hasDuplicateExpressions values =
  length (Set.fromList (map fullForm values)) /= length values

groupMonomialTerms
  :: Int
  -> Polynomial
  -> Map.Map [Int] Polynomial
groupMonomialTerms orderingDimensions (Polynomial terms) =
  Map.fromListWith addPolynomial
    [ ( take orderingDimensions powers
      , Polynomial
          (Map.singleton (replicate orderingDimensions 0 <> drop orderingDimensions powers) coefficient)
      )
    | (powers, coefficient) <- Map.toList terms
    ]

compareMonomialGroups
  :: MonomialOrder
  -> MonomialDirection
  -> ([Int], Polynomial)
  -> ([Int], Polynomial)
  -> Ordering
compareMonomialGroups order direction (left, _) (right, _) =
  case direction of
    MonomialDescending -> compareKey right left
    MonomialAscending -> compareKey left right
 where
  compareKey = case order of
    MonomialLexicographic -> compare
    MonomialDegreeLexicographic ->
      \leftPowers rightPowers ->
        compare (sum leftPowers, leftPowers) (sum rightPowers, rightPowers)
    MonomialDegreeReverseLexicographic ->
      \leftPowers rightPowers ->
        compare
          (sum leftPowers, reverse (map negate leftPowers))
          (sum rightPowers, reverse (map negate rightPowers))

groupedMonomialToExpr
  :: CanonicalCompare
  -> [Expr]
  -> Int
  -> [Int]
  -> Polynomial
  -> Expr
groupedMonomialToExpr
  compareExpression
  variables
  orderingDimensions
  powers
  groupedCoefficient =
    makeTimes compareExpression (coefficientExpression : variableFactors)
 where
  coefficientExpression =
    polynomialToExpr compareExpression variables groupedCoefficient
  variableFactors =
    [ if exponent == 1
        then variable
        else Call (Symbol "Power") [variable, Integer (fromIntegral exponent)]
    | (variable, exponent) <-
        take orderingDimensions (zip variables powers)
    , exponent > 0
    ]

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

reduceFractionPart :: CanonicalCompare -> Bool -> [Expr] -> Maybe Expr
reduceFractionPart compareExpression selectNumerator [Call (Symbol headName) items]
  | systemHeadIn "List" headName =
      Just
        ( Call
            (Symbol "List")
            [selectFractionPart compareExpression selectNumerator item | item <- items]
        )
reduceFractionPart compareExpression selectNumerator [expression] =
  Just (selectFractionPart compareExpression selectNumerator expression)
reduceFractionPart _ _ _ = Nothing

selectFractionPart :: CanonicalCompare -> Bool -> Expr -> Expr
selectFractionPart compareExpression selectNumerator value =
  let (numerator, denominator) = structuralFractionParts compareExpression value
   in if selectNumerator then numerator else denominator

structuralFractionParts :: CanonicalCompare -> Expr -> (Expr, Expr)
structuralFractionParts _ (Rational numerator denominator) =
  (Integer numerator, Integer denominator)
structuralFractionParts compareExpression (Call (Symbol headName) factors)
  | systemHeadIn "Times" headName =
      let parts = map (structuralFractionParts compareExpression) factors
       in ( makeTimes compareExpression (map fst parts)
          , makeTimes compareExpression (map snd parts)
          )
structuralFractionParts _ (Call (Symbol headName) [base, Integer power])
  | systemHeadIn "Power" headName
  , power < 0 =
      ( Integer 1
      , if power == -1
          then base
          else Call (Symbol "Power") [base, Integer (negate power)]
      )
structuralFractionParts _ expression = (expression, Integer 1)

data RationalPolynomial = RationalPolynomial !Polynomial !Polynomial
  deriving (Eq, Show)

reduceRationalFunction :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceRationalFunction compareExpression [Call (Symbol headName) items]
  | systemHeadIn "List" headName = do
      results <- traverse (reduceRationalFunction compareExpression . pure) items
      pure (Call (Symbol "List") results)
reduceRationalFunction compareExpression [expression] = do
  let variables = discoverVariables compareExpression [] [expression]
  rationalFunction <- expressionToRationalPolynomial variables expression
  normalized <- cancelRationalPolynomial variables rationalFunction
  pure (rationalPolynomialToExpr compareExpression variables normalized)
reduceRationalFunction _ _ = Nothing

reduceApart :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceApart compareExpression arguments = case arguments of
  [expression] -> apartWith expression
  [expression, variable] ->
    let variables = discoverVariables compareExpression [variable] [expression]
     in apartWithVariables variables expression
  _ -> Nothing
 where
  apartWith expression =
    apartWithVariables (discoverVariables compareExpression [] [expression]) expression
  apartWithVariables variables expression = do
    rationalFunction <- expressionToRationalPolynomial variables expression
    normalized@(RationalPolynomial _ denominator) <-
      cancelRationalPolynomial variables rationalFunction
    let (_, residualDenominator) = extractMonomialFactor (length variables) denominator
    if polynomialTotalDegree residualDenominator <= 1
      then Just (rationalPolynomialToExpr compareExpression variables normalized)
      else Nothing

reduceFactor :: CanonicalCompare -> Bool -> [Expr] -> Maybe Expr
reduceFactor compareExpression returnList arguments = case arguments of
  [expression] -> factorOne expression
  [expression, option]
    | acceptsRationalFactorOption option -> factorOne expression
  _ -> Nothing
 where
  factorOne expression = do
    let variables = discoverVariables compareExpression [] [expression]
    polynomial <- expressionToPolynomial variables expression
    let factorization = factorPolynomial variables polynomial
    pure
      ( if returnList
          then factorizationListExpr compareExpression variables factorization
          else factorizationExpr compareExpression variables factorization
      )

acceptsRationalFactorOption :: Expr -> Bool
acceptsRationalFactorOption (Call (Symbol ruleHead) [Symbol optionName, Symbol valueName]) =
  systemHeadIn "Rule" ruleHead
    && ( (systemHeadIn "GaussianIntegers" optionName && systemHeadIn "False" valueName)
           || (systemHeadIn "Extension" optionName && systemHeadIn "None" valueName)
       )
acceptsRationalFactorOption _ = False

reducePolynomialGcdLcm :: CanonicalCompare -> Bool -> [Expr] -> Maybe Expr
reducePolynomialGcdLcm _ False [] = Just (Integer 0)
reducePolynomialGcdLcm _ True [] = Just (Integer 1)
reducePolynomialGcdLcm compareExpression useLcm expressions = do
  let variables = discoverVariables compareExpression [] expressions
  if length variables > 1
    then Nothing
    else do
      polynomials <- traverse (expressionToPolynomial variables) expressions
      result <-
        if useLcm
          then foldPolynomialLcm polynomials
          else foldPolynomialGcd polynomials
      pure
        ( if useLcm
            then factorizationExpr compareExpression variables (factorPolynomial variables result)
            else polynomialToExpr compareExpression variables result
        )

reducePolynomialMod :: CanonicalCompare -> [Expr] -> Maybe Expr
reducePolynomialMod compareExpression [expression, Integer modulus]
  | modulus > 1 = do
      let variables = discoverVariables compareExpression [] [expression]
      Polynomial terms <- expressionToPolynomial variables expression
      reducedTerms <-
        traverse
          (\(powers, coefficient) -> do
              residue <- polynomialModCoefficient modulus coefficient
              pure (powers, residue)
          )
          (Map.toList terms)
      pure
        ( polynomialToExpr
            compareExpression
            variables
            (Polynomial (Map.fromList (filter ((/= zeroGaussian) . snd) reducedTerms)))
        )
reducePolynomialMod _ _ = Nothing

polynomialModCoefficient :: Integer -> Gaussian -> Maybe Gaussian
polynomialModCoefficient
  modulus
  (Gaussian (Exact numerator denominator) imaginary)
    | imaginary /= zeroExact = Nothing
    | otherwise = do
        denominatorInverse <- modularInverseInteger denominator modulus
        let residue = (numerator `mod` modulus * denominatorInverse) `mod` modulus
        pure (Gaussian (Exact residue 1) zeroExact)

modularInverseInteger :: Integer -> Integer -> Maybe Integer
modularInverseInteger value modulus =
  let (greatestCommonDivisor, coefficient, _) =
        extendedGreatestCommonDivisor (value `mod` modulus) modulus
   in if greatestCommonDivisor == 1
        then Just (coefficient `mod` modulus)
        else Nothing

extendedGreatestCommonDivisor
  :: Integer
  -> Integer
  -> (Integer, Integer, Integer)
extendedGreatestCommonDivisor left 0 =
  (abs left, signum left, 0)
extendedGreatestCommonDivisor left right =
  let (divisor, rightCoefficient, remainderCoefficient) =
        extendedGreatestCommonDivisor right (left `mod` right)
   in ( divisor
      , remainderCoefficient
      , rightCoefficient - (left `div` right) * remainderCoefficient
      )

reduceResultant :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceResultant compareExpression [leftExpression, rightExpression, variableSpec] = do
  [variable] <- variableExpressions variableSpec
  let variables =
        discoverVariables
          compareExpression
          [variable]
          [leftExpression, rightExpression]
      dimensions = length variables
  left <- expressionToPolynomial variables leftExpression
  right <- expressionToPolynomial variables rightExpression
  result <- resultantPolynomial dimensions left right
  pure (polynomialToExpr compareExpression variables result)
reduceResultant _ _ = Nothing

reduceDiscriminant :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceDiscriminant compareExpression [expression, variableSpec] = do
  [variable] <- variableExpressions variableSpec
  let variables = discoverVariables compareExpression [variable] [expression]
      dimensions = length variables
  polynomial <- expressionToPolynomial variables expression
  case leadingVariableDegree polynomial of
    Nothing -> Just (Integer 0)
    Just 0 -> Just (Integer 0)
    Just degree -> do
      derivative <- derivativeInLeadingVariable dimensions polynomial
      resultant <- resultantPolynomial dimensions polynomial derivative
      leadingCoefficient <- leadingVariableCoefficient dimensions degree polynomial
      quotient <- dividePolynomialExactly dimensions resultant leadingCoefficient
      let signed
            | odd (degree * (degree - 1) `div` 2) = negatePolynomial quotient
            | otherwise = quotient
      pure (polynomialToExpr compareExpression variables signed)
reduceDiscriminant _ _ = Nothing

resultantPolynomial
  :: Int
  -> Polynomial
  -> Polynomial
  -> Maybe Polynomial
resultantPolynomial dimensions left right
  | isZeroPolynomial left || isZeroPolynomial right =
      Just (zeroPolynomial dimensions)
  | otherwise =
      polynomialDeterminant
        dimensions
        ( sylvesterMatrix
            dimensions
            leftDegree
            rightDegree
            leftCoefficients
            rightCoefficients
        )
 where
  leftDegree = maybe 0 id (leadingVariableDegree left)
  rightDegree = maybe 0 id (leadingVariableDegree right)
  leftCoefficients = descendingLeadingVariableCoefficients dimensions leftDegree left
  rightCoefficients = descendingLeadingVariableCoefficients dimensions rightDegree right

leadingVariableDegree :: Polynomial -> Maybe Int
leadingVariableDegree (Polynomial terms) =
  case Map.keys terms of
    [] -> Nothing
    powers -> Just (maximum (map firstPower powers))

leadingVariableCoefficient
  :: Int
  -> Int
  -> Polynomial
  -> Maybe Polynomial
leadingVariableCoefficient dimensions degree polynomial =
  Map.lookup degree (leadingVariableCoefficients dimensions polynomial)

leadingVariableCoefficients
  :: Int
  -> Polynomial
  -> Map.Map Int Polynomial
leadingVariableCoefficients dimensions (Polynomial terms) =
  Map.fromListWith addPolynomial
    [ ( firstPower powers
      , Polynomial
          (Map.singleton (0 : drop 1 powers) coefficient)
      )
    | (powers, coefficient) <- Map.toList terms
    , length powers == dimensions
    ]

descendingLeadingVariableCoefficients
  :: Int
  -> Int
  -> Polynomial
  -> [Polynomial]
descendingLeadingVariableCoefficients dimensions degree polynomial =
  [ Map.findWithDefault
      (zeroPolynomial dimensions)
      currentDegree
      coefficients
  | currentDegree <- [degree, degree - 1 .. 0]
  ]
 where
  coefficients = leadingVariableCoefficients dimensions polynomial

derivativeInLeadingVariable :: Int -> Polynomial -> Maybe Polynomial
derivativeInLeadingVariable dimensions (Polynomial terms)
  | all ((== dimensions) . length . fst) (Map.toList terms) =
      Just
        ( Polynomial
            ( Map.fromListWith
                addGaussian
                [ ( (power - 1) : drop 1 powers
                  , multiplyGaussian
                      (Gaussian (Exact (fromIntegral power) 1) zeroExact)
                      coefficient
                  )
                | (powers, coefficient) <- Map.toList terms
                , let power = firstPower powers
                , power > 0
                ]
            )
        )
  | otherwise = Nothing

sylvesterMatrix
  :: Int
  -> Int
  -> Int
  -> [Polynomial]
  -> [Polynomial]
  -> [[Polynomial]]
sylvesterMatrix dimensions leftDegree rightDegree left right =
  [ shiftedPolynomialRow dimensions total shift left
  | shift <- [0 .. rightDegree - 1]
  ]
    <> [ shiftedPolynomialRow dimensions total shift right
       | shift <- [0 .. leftDegree - 1]
       ]
 where
  total = leftDegree + rightDegree

shiftedPolynomialRow
  :: Int
  -> Int
  -> Int
  -> [Polynomial]
  -> [Polynomial]
shiftedPolynomialRow dimensions total shift coefficients =
  replicate shift (zeroPolynomial dimensions)
    <> coefficients
    <> replicate
      (max 0 (total - shift - length coefficients))
      (zeroPolynomial dimensions)

polynomialDeterminant
  :: Int
  -> [[Polynomial]]
  -> Maybe Polynomial
polynomialDeterminant dimensions matrix
  | any ((/= size) . length) matrix = Nothing
  | size == 0 = Just (onePolynomial dimensions)
  | otherwise = bareiss 0 (onePolynomial dimensions) False matrix
 where
  size = length matrix

  bareiss
    :: Int
    -> Polynomial
    -> Bool
    -> [[Polynomial]]
    -> Maybe Polynomial
  bareiss column previousPivot negated rows
    | column == size - 1 =
        let determinant = rows !! column !! column
         in Just
              (if negated then negatePolynomial determinant else determinant)
    | otherwise = case
        [ rowIndex
        | rowIndex <- [column .. size - 1]
        , not (isZeroPolynomial (rows !! rowIndex !! column))
        ] of
        [] -> Just (zeroPolynomial dimensions)
        pivotIndex : _ -> do
          let swapped = swapRows column pivotIndex rows
              pivotRow = swapped !! column
              pivot = pivotRow !! column
              nextNegated = negated /= (pivotIndex /= column)
          reduced <-
            traverse
              (reduceRow column previousPivot pivot pivotRow)
              (zip [0 :: Int ..] swapped)
          bareiss (column + 1) pivot nextNegated reduced

  reduceRow
    :: Int
    -> Polynomial
    -> Polynomial
    -> [Polynomial]
    -> (Int, [Polynomial])
    -> Maybe [Polynomial]
  reduceRow column previousPivot pivot pivotRow (rowIndex, row)
    | rowIndex <= column = Just row
    | otherwise = do
        suffix <-
          traverse
            (reduceEntry column previousPivot pivot pivotRow row)
            [column + 1 .. size - 1]
        pure
          ( take column row
              <> [zeroPolynomial dimensions]
              <> suffix
          )

  reduceEntry
    :: Int
    -> Polynomial
    -> Polynomial
    -> [Polynomial]
    -> [Polynomial]
    -> Int
    -> Maybe Polynomial
  reduceEntry column previousPivot pivot pivotRow row targetColumn =
    dividePolynomialExactly
      dimensions
      ( subtractPolynomial
          (multiplyPolynomial (row !! targetColumn) pivot)
          (multiplyPolynomial (row !! column) (pivotRow !! targetColumn))
      )
      previousPivot

  swapRows :: Int -> Int -> [[Polynomial]] -> [[Polynomial]]
  swapRows leftIndex rightIndex rows
    | leftIndex == rightIndex = rows
    | otherwise =
        replaceAt
          rightIndex
          (rows !! leftIndex)
          (replaceAt leftIndex (rows !! rightIndex) rows)

dividePolynomialExactly
  :: Int
  -> Polynomial
  -> Polynomial
  -> Maybe Polynomial
dividePolynomialExactly dimensions dividend divisor
  | isZeroPolynomial divisor = Nothing
  | otherwise = go (zeroPolynomial dimensions) dividend (zeroPolynomial dimensions) 0
 where
  go :: Polynomial -> Polynomial -> Polynomial -> Int -> Maybe Polynomial
  go quotient remaining remainder steps
    | steps > 200000 = Nothing
    | otherwise = case leadingTerm remaining of
        Nothing
          | isZeroPolynomial remainder -> Just quotient
          | otherwise -> Nothing
        Just (remainingPowers, remainingCoefficient) ->
          case leadingTerm divisor of
            Nothing -> Nothing
            Just (divisorPowers, divisorCoefficient)
              | monomialDivides divisorPowers remainingPowers -> do
                  coefficient <-
                    divideGaussian remainingCoefficient divisorCoefficient
                  let powerDifference =
                        zipWith (-) remainingPowers divisorPowers
                      term =
                        Polynomial
                          (Map.singleton powerDifference coefficient)
                  go
                    (addPolynomial quotient term)
                    (subtractPolynomial remaining (multiplyPolynomial term divisor))
                    remainder
                    (steps + 1)
              | otherwise ->
                  let leading =
                        Polynomial
                          (Map.singleton remainingPowers remainingCoefficient)
                   in go
                        quotient
                        (subtractPolynomial remaining leading)
                        (addPolynomial remainder leading)
                        (steps + 1)

monomialDivides :: [Int] -> [Int] -> Bool
monomialDivides divisor dividend =
  length divisor == length dividend
    && and (zipWith (<=) divisor dividend)

reducePolynomialDivision :: CanonicalCompare -> Bool -> [Expr] -> Maybe Expr
reducePolynomialDivision compareExpression selectQuotient [dividendExpr, divisorExpr, variable] = do
  let variables = discoverVariables compareExpression [variable] [dividendExpr, divisorExpr]
  if variables /= [variable]
    then Nothing
    else do
      dividend <- expressionToPolynomial variables dividendExpr
      divisor <- expressionToPolynomial variables divisorExpr
      (quotient, remainder) <- univariateDivide dividend divisor
      pure
        ( polynomialToExpr
            compareExpression
            variables
            (if selectQuotient then quotient else remainder)
        )
reducePolynomialDivision _ _ _ = Nothing

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

negatePolynomial :: Polynomial -> Polynomial
negatePolynomial (Polynomial terms) = Polynomial (Map.map negateGaussian terms)

subtractPolynomial :: Polynomial -> Polynomial -> Polynomial
subtractPolynomial left right = addPolynomial left (negatePolynomial right)

scalePolynomial :: Gaussian -> Polynomial -> Polynomial
scalePolynomial scalar (Polynomial terms)
  | scalar == zeroGaussian = Polynomial Map.empty
  | otherwise =
      Polynomial
        ( Map.filter
            (/= zeroGaussian)
            (Map.map (multiplyGaussian scalar) terms)
        )

shiftScalePolynomial :: [Int] -> Gaussian -> Polynomial -> Polynomial
shiftScalePolynomial shift scalar (Polynomial terms)
  | scalar == zeroGaussian = Polynomial Map.empty
  | otherwise =
      Polynomial
        ( Map.fromList
            [ (zipWith (+) shift powers, multiplyGaussian scalar coefficient)
            | (powers, coefficient) <- Map.toList terms
            ]
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

isOnePolynomial :: Polynomial -> Bool
isOnePolynomial (Polynomial terms) = case Map.toList terms of
  [(powers, coefficient)] -> all (== 0) powers && coefficient == oneGaussian
  _ -> False

expressionToRationalPolynomial :: [Expr] -> Expr -> Maybe RationalPolynomial
expressionToRationalPolynomial variables expression
  | Just polynomial <- expressionToPolynomial variables expression =
      Just (RationalPolynomial polynomial (onePolynomial (length variables)))
expressionToRationalPolynomial variables (Call (Symbol headName) values)
  | systemHeadIn "Plus" headName =
      foldl'
        addRationalMaybe
        (Just (RationalPolynomial (zeroPolynomial (length variables)) (onePolynomial (length variables))))
        (map (expressionToRationalPolynomial variables) values)
  | systemHeadIn "Times" headName =
      foldl'
        multiplyRationalMaybe
        (Just (RationalPolynomial (onePolynomial (length variables)) (onePolynomial (length variables))))
        (map (expressionToRationalPolynomial variables) values)
  | systemHeadIn "Power" headName
  , [base, Integer power] <- values
  , abs power <= 4096 = do
      RationalPolynomial numerator denominator <- expressionToRationalPolynomial variables base
      pure
        ( if power >= 0
            then RationalPolynomial (powerPolynomial numerator power) (powerPolynomial denominator power)
            else RationalPolynomial (powerPolynomial denominator (abs power)) (powerPolynomial numerator (abs power))
        )
expressionToRationalPolynomial _ _ = Nothing

addRationalMaybe :: Maybe RationalPolynomial -> Maybe RationalPolynomial -> Maybe RationalPolynomial
addRationalMaybe left right = addRationalPolynomial <$> left <*> right

multiplyRationalMaybe :: Maybe RationalPolynomial -> Maybe RationalPolynomial -> Maybe RationalPolynomial
multiplyRationalMaybe left right = multiplyRationalPolynomial <$> left <*> right

addRationalPolynomial :: RationalPolynomial -> RationalPolynomial -> RationalPolynomial
addRationalPolynomial
  (RationalPolynomial leftNumerator leftDenominator)
  (RationalPolynomial rightNumerator rightDenominator) =
    RationalPolynomial
      ( addPolynomial
          (multiplyPolynomial leftNumerator rightDenominator)
          (multiplyPolynomial rightNumerator leftDenominator)
      )
      (multiplyPolynomial leftDenominator rightDenominator)

multiplyRationalPolynomial :: RationalPolynomial -> RationalPolynomial -> RationalPolynomial
multiplyRationalPolynomial
  (RationalPolynomial leftNumerator leftDenominator)
  (RationalPolynomial rightNumerator rightDenominator) =
    RationalPolynomial
      (multiplyPolynomial leftNumerator rightNumerator)
      (multiplyPolynomial leftDenominator rightDenominator)

cancelRationalPolynomial :: [Expr] -> RationalPolynomial -> Maybe RationalPolynomial
cancelRationalPolynomial variables (RationalPolynomial numerator denominator)
  | isZeroPolynomial denominator = Nothing
  | isZeroPolynomial numerator =
      Just
        ( RationalPolynomial
            (zeroPolynomial (length variables))
            (onePolynomial (length variables))
        )
  | length variables == 1 = do
      common <- univariateGcd numerator denominator
      (reducedNumerator, numeratorRemainder) <- univariateDivide numerator common
      (reducedDenominator, denominatorRemainder) <- univariateDivide denominator common
      if isZeroPolynomial numeratorRemainder && isZeroPolynomial denominatorRemainder
        then normalizeRationalDenominator reducedNumerator reducedDenominator
        else Nothing
  | otherwise =
      let numeratorMonomial = commonMonomial (length variables) numerator
          denominatorMonomial = commonMonomial (length variables) denominator
          commonPowers = zipWith min numeratorMonomial denominatorMonomial
          reducedNumerator = divideMonomial commonPowers numerator
          reducedDenominator = divideMonomial commonPowers denominator
       in normalizeRationalDenominator reducedNumerator reducedDenominator

normalizeRationalDenominator :: Polynomial -> Polynomial -> Maybe RationalPolynomial
normalizeRationalDenominator numerator denominator = do
  (_, leadingCoefficient) <- leadingTerm denominator
  inverse <- reciprocalGaussian leadingCoefficient
  pure
    ( RationalPolynomial
        (scalePolynomial inverse numerator)
        (scalePolynomial inverse denominator)
    )

rationalPolynomialToExpr :: CanonicalCompare -> [Expr] -> RationalPolynomial -> Expr
rationalPolynomialToExpr compareExpression variables (RationalPolynomial numerator denominator)
  | isZeroPolynomial numerator = Integer 0
  | isOnePolynomial denominator = polynomialToExpr compareExpression variables numerator
  | otherwise =
      let (monomialPowers, residualDenominator) =
            extractMonomialFactor (length variables) denominator
          numeratorExpr = polynomialToExpr compareExpression variables numerator
          inverseVariables =
            [ Call (Symbol "Power") [variable, Integer (negate (fromIntegral power))]
            | (variable, power) <- zip variables monomialPowers
            , power > 0
            ]
          inverseResidual
            | isOnePolynomial residualDenominator = []
            | otherwise =
                [ Call
                    (Symbol "Power")
                    [polynomialToExpr compareExpression variables residualDenominator, Integer (-1)]
                ]
       in makeTimes compareExpression (numeratorExpr : inverseVariables <> inverseResidual)

leadingTerm :: Polynomial -> Maybe ([Int], Gaussian)
leadingTerm (Polynomial terms) = Map.lookupMax terms

polynomialTotalDegree :: Polynomial -> Int
polynomialTotalDegree (Polynomial terms) =
  maximum (0 : map sum (Map.keys terms))

commonMonomial :: Int -> Polynomial -> [Int]
commonMonomial dimensions (Polynomial terms) = case Map.keys terms of
  [] -> replicate dimensions 0
  firstPowers : remaining -> foldl' (zipWith min) firstPowers remaining

extractMonomialFactor :: Int -> Polynomial -> ([Int], Polynomial)
extractMonomialFactor dimensions polynomial =
  let powers = commonMonomial dimensions polynomial
   in (powers, divideMonomial powers polynomial)

divideMonomial :: [Int] -> Polynomial -> Polynomial
divideMonomial divisor (Polynomial terms) =
  Polynomial
    ( Map.fromList
        [ (zipWith (-) powers divisor, coefficient)
        | (powers, coefficient) <- Map.toList terms
        ]
    )

univariateDivide :: Polynomial -> Polynomial -> Maybe (Polynomial, Polynomial)
univariateDivide dividend divisor
  | isZeroPolynomial divisor = Nothing
  | otherwise = go (zeroPolynomial 1) dividend (0 :: Int)
 where
  (divisorPowers, divisorCoefficient) =
    maybe ([0], zeroGaussian) id (leadingTerm divisor)
  divisorDegree = firstPower divisorPowers
  go quotient remainder steps
    | steps > 100000 = Nothing
    | otherwise = case leadingTerm remainder of
        Nothing -> Just (quotient, remainder)
        Just (remainderPowers, remainderCoefficient)
          | firstPower remainderPowers < divisorDegree -> Just (quotient, remainder)
          | otherwise -> do
              coefficient <- divideGaussian remainderCoefficient divisorCoefficient
              let degreeDifference = firstPower remainderPowers - divisorDegree
                  term = Polynomial (Map.singleton [degreeDifference] coefficient)
                  nextQuotient = addPolynomial quotient term
                  nextRemainder =
                    subtractPolynomial
                      remainder
                      (shiftScalePolynomial [degreeDifference] coefficient divisor)
              go nextQuotient nextRemainder (steps + 1)

univariateGcd :: Polynomial -> Polynomial -> Maybe Polynomial
univariateGcd left right
  | isZeroPolynomial left = monicPolynomial right
  | isZeroPolynomial right = monicPolynomial left
  | otherwise = do
      (_, remainder) <- univariateDivide left right
      if isZeroPolynomial remainder
        then monicPolynomial right
        else univariateGcd right remainder

monicPolynomial :: Polynomial -> Maybe Polynomial
monicPolynomial polynomial = do
  (_, leadingCoefficient) <- leadingTerm polynomial
  inverse <- reciprocalGaussian leadingCoefficient
  pure (scalePolynomial inverse polynomial)

foldPolynomialGcd :: [Polynomial] -> Maybe Polynomial
foldPolynomialGcd [] = Just (zeroPolynomial 0)
foldPolynomialGcd (first : rest) = foldMaybe univariateGcd first rest

foldPolynomialLcm :: [Polynomial] -> Maybe Polynomial
foldPolynomialLcm [] = Just (onePolynomial 0)
foldPolynomialLcm (first : rest) = foldMaybe polynomialLcm first rest

polynomialLcm :: Polynomial -> Polynomial -> Maybe Polynomial
polynomialLcm left right
  | isZeroPolynomial left || isZeroPolynomial right = Just (zeroPolynomial 1)
  | otherwise = do
      common <- univariateGcd left right
      (quotient, remainder) <- univariateDivide left common
      if isZeroPolynomial remainder
        then monicPolynomial (multiplyPolynomial quotient right)
        else Nothing

foldMaybe :: (value -> value -> Maybe value) -> value -> [value] -> Maybe value
foldMaybe _ initial [] = Just initial
foldMaybe operation initial (value : rest) = do
  next <- operation initial value
  foldMaybe operation next rest

data Factorization = Factorization !Gaussian ![Int] ![(Polynomial, Int)] !Polynomial
  deriving (Eq, Show)

factorPolynomial :: [Expr] -> Polynomial -> Factorization
factorPolynomial variables polynomial
  | isZeroPolynomial polynomial =
      Factorization zeroGaussian (replicate (length variables) 0) [] (onePolynomial (length variables))
  | otherwise =
      let monomialPowers = commonMonomial (length variables) polynomial
          withoutMonomial = divideMonomial monomialPowers polynomial
          (content, primitive) = extractRationalContent withoutMonomial
          (linearFactors, remainder) = factorIntegerLinearRoots variables primitive
       in Factorization content monomialPowers linearFactors remainder

extractRationalContent :: Polynomial -> (Gaussian, Polynomial)
extractRationalContent polynomial@(Polynomial terms)
  | null coefficients = (oneGaussian, polynomial)
  | any hasImaginary coefficients = (oneGaussian, polynomial)
  | otherwise =
      let numerators = [abs numerator | Gaussian (Exact numerator _) _ <- coefficients]
          denominators = [denominator | Gaussian (Exact _ denominator) _ <- coefficients]
          numeratorGcd = foldl' gcd 0 numerators
          denominatorLcm = foldl' lcm 1 denominators
          unsignedContent = exact numeratorGcd denominatorLcm
          sign = case leadingTerm polynomial of
            Just (_, Gaussian (Exact leadingNumerator _) _)
              | leadingNumerator < 0 -> -1
            _ -> 1
          content = Gaussian (multiplyExact (Exact sign 1) unsignedContent) zeroExact
       in case reciprocalGaussian content of
            Just inverse -> (content, scalePolynomial inverse polynomial)
            Nothing -> (oneGaussian, polynomial)
 where
  coefficients = Map.elems terms
  hasImaginary (Gaussian _ imaginary) = imaginary /= zeroExact

factorIntegerLinearRoots :: [Expr] -> Polynomial -> ([(Polynomial, Int)], Polynomial)
factorIntegerLinearRoots variables polynomial
  | length variables /= 1 = ([], polynomial)
  | otherwise = go polynomial []
 where
  go current retained = case firstIntegerRoot current of
    Nothing -> (reverse retained, current)
    Just rootValue ->
      let factor =
            Polynomial
              ( Map.fromList
                  [ ([0], Gaussian (Exact (negate rootValue) 1) zeroExact)
                  , ([1], oneGaussian)
                  ]
              )
       in case univariateDivide current factor of
            Just (quotient, remainder)
              | isZeroPolynomial remainder -> go quotient (insertFactor factor retained)
            _ -> (reverse retained, current)
  insertFactor factor [] = [(factor, 1)]
  insertFactor factor ((existing, count) : rest)
    | factor == existing = (existing, count + 1) : rest
    | otherwise = (existing, count) : insertFactor factor rest

firstIntegerRoot :: Polynomial -> Maybe Integer
firstIntegerRoot polynomial@(Polynomial terms) = do
  coefficients <- traverse integerCoefficient (Map.toList terms)
  let constant = maybe 0 id (lookup 0 coefficients)
      candidates
        | constant == 0 = [0]
        | otherwise = concatMap (\divisor -> [negate divisor, divisor]) (positiveDivisors (abs constant))
  firstMatching (isPolynomialRoot polynomial) candidates
 where
  integerCoefficient ([degree], Gaussian (Exact numerator 1) imaginary)
    | imaginary == zeroExact = Just (degree, numerator)
  integerCoefficient _ = Nothing

positiveDivisors :: Integer -> [Integer]
positiveDivisors value =
  sortBy compare
    ( Set.toList
        ( Set.fromList
            [ candidate
            | trial <- [1 .. integerSquareRoot value]
            , value `mod` trial == 0
            , candidate <- [trial, value `div` trial]
            ]
        )
    )

integerSquareRoot :: Integer -> Integer
integerSquareRoot value = go 0 (value + 1)
 where
  go low high
    | high - low <= 1 = low
    | midpoint * midpoint <= value = go midpoint high
    | otherwise = go low midpoint
   where
    midpoint = (low + high) `div` 2

isPolynomialRoot :: Polynomial -> Integer -> Bool
isPolynomialRoot (Polynomial terms) rootValue =
  foldl'
    addGaussian
    zeroGaussian
    [ multiplyGaussian coefficient (gaussianPower (Gaussian (Exact rootValue 1) zeroExact) (firstPower powers))
    | (powers, coefficient) <- Map.toList terms
    ]
    == zeroGaussian

firstMatching :: (value -> Bool) -> [value] -> Maybe value
firstMatching _ [] = Nothing
firstMatching predicate (value : rest)
  | predicate value = Just value
  | otherwise = firstMatching predicate rest

firstPower :: [Int] -> Int
firstPower [] = 0
firstPower (power : _) = power

factorizationExpr :: CanonicalCompare -> [Expr] -> Factorization -> Expr
factorizationExpr compareExpression variables (Factorization content powers factors remainder)
  | content == zeroGaussian = Integer 0
  | otherwise =
      makeTimes
        compareExpression
        ( contentExpression
            <> monomialExpressions
            <> map factorExpression factors
            <> remainderExpression
        )
 where
  contentExpression
    | content == oneGaussian = []
    | otherwise = [gaussianToExpr content]
  monomialExpressions =
    [ if power == 1
        then variable
        else Call (Symbol "Power") [variable, Integer (fromIntegral power)]
    | (variable, power) <- zip variables powers
    , power > 0
    ]
  factorExpression (factor, multiplicity)
    | multiplicity == 1 = polynomialToExpr compareExpression variables factor
    | otherwise =
        Call
          (Symbol "Power")
          [polynomialToExpr compareExpression variables factor, Integer (fromIntegral multiplicity)]
  remainderExpression
    | isOnePolynomial remainder = []
    | otherwise = [polynomialToExpr compareExpression variables remainder]

factorizationListExpr :: CanonicalCompare -> [Expr] -> Factorization -> Expr
factorizationListExpr compareExpression variables (Factorization content powers factors remainder) =
  Call
    (Symbol "List")
    ( coefficientEntry
        : sortBy compareEntries (monomialEntries <> factorEntries <> remainderEntries)
    )
 where
  coefficientEntry = Call (Symbol "List") [gaussianToExpr content, Integer 1]
  monomialEntries =
    [ Call (Symbol "List") [variable, Integer (fromIntegral power)]
    | (variable, power) <- zip variables powers
    , power > 0
    ]
  factorEntries =
    [ Call
        (Symbol "List")
        [polynomialToExpr compareExpression variables factor, Integer (fromIntegral multiplicity)]
    | (factor, multiplicity) <- factors
    ]
  remainderEntries
    | isOnePolynomial remainder = []
    | otherwise =
        [Call (Symbol "List") [polynomialToExpr compareExpression variables remainder, Integer 1]]
  compareEntries (Call _ [left, _]) (Call _ [right, _]) = compareExpression left right
  compareEntries left right = compareExpression left right

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

negateGaussian :: Gaussian -> Gaussian
negateGaussian (Gaussian real imaginary) = Gaussian (negateExact real) (negateExact imaginary)

reciprocalGaussian :: Gaussian -> Maybe Gaussian
reciprocalGaussian (Gaussian real imaginary)
  | real == zeroExact && imaginary == zeroExact = Nothing
  | otherwise = do
      inverseNorm <- reciprocalExact (addExact (multiplyExact real real) (multiplyExact imaginary imaginary))
      pure
        ( Gaussian
            (multiplyExact real inverseNorm)
            (multiplyExact (negateExact imaginary) inverseNorm)
        )

divideGaussian :: Gaussian -> Gaussian -> Maybe Gaussian
divideGaussian numerator denominator =
  multiplyGaussian numerator <$> reciprocalGaussian denominator

gaussianPower :: Gaussian -> Int -> Gaussian
gaussianPower base power = go power oneGaussian base
 where
  go 0 accumulator _ = accumulator
  go remaining accumulator factor
    | odd remaining = go (remaining `div` 2) (multiplyGaussian accumulator factor) (multiplyGaussian factor factor)
    | otherwise = go (remaining `div` 2) accumulator (multiplyGaussian factor factor)

reciprocalExact :: Exact -> Maybe Exact
reciprocalExact (Exact 0 _) = Nothing
reciprocalExact (Exact numerator denominator) = Just (exact denominator numerator)

booleanExpr :: Bool -> Expr
booleanExpr True = Symbol "True"
booleanExpr False = Symbol "False"

orElse :: Maybe value -> Maybe value -> Maybe value
orElse (Just value) _ = Just value
orElse Nothing fallback = fallback

systemHeadIn :: Text -> Text -> Bool
systemHeadIn expected actual = actual == expected || actual == "System`" <> expected
