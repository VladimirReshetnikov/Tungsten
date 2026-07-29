{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact, kernel-free polynomial transformations.
--
-- The representation is deliberately small: coefficients live in Q(i), and
-- monomials use nonnegative machine-sized exponents.  Expressions outside
-- that ring are rejected so the evaluator can preserve them symbolically.
module Tungsten.PolynomialAlgebra
  ( CollectPlan (..)
  , collectCoefficientPlan
  , exponentValuesForForm
  , reducePolynomialBuiltin
  ) where

import Prelude hiding (exponent)
import Data.List (partition, sortBy)
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

-- | Exact callback work produced for the three-argument form of 'Collect'.
-- Direct plans match the empty-variable and zero-polynomial conventions;
-- term plans retain SymPy's descending lexicographic callback schedule.
data CollectPlan
  = CollectDirect !Expr
  | CollectTerms ![(Expr, Expr)]
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
  "Collect" -> reduceCollect compareExpression values
  "Coefficient" -> reduceCoefficient compareExpression values
  "Exponent" -> reduceExponent compareExpression values
  "CoefficientList" -> reduceCoefficientList compareExpression values
  "Numerator" -> reduceFractionPart compareExpression True values
  "Denominator" -> reduceFractionPart compareExpression False values
  "Together" -> reduceRationalFunction compareExpression values
  "Cancel" -> reduceRationalFunction compareExpression values
  "Apart" -> reduceApart compareExpression values
  "Factor" -> reduceFactor compareExpression False values
  "FactorList" -> reduceFactor compareExpression True values
  "Decompose" -> reduceDecompose compareExpression values
  "PolynomialGCD" -> reducePolynomialGcdLcm compareExpression False values
  "PolynomialLCM" -> reducePolynomialGcdLcm compareExpression True values
  "PolynomialMod" -> reducePolynomialMod compareExpression values
  "PolynomialQuotient" -> reducePolynomialDivision compareExpression True values
  "PolynomialRemainder" -> reducePolynomialDivision compareExpression False values
  "PolynomialReduce" -> reducePolynomialReduce compareExpression values
  "Resultant" -> reduceResultant compareExpression values
  "Discriminant" -> reduceDiscriminant compareExpression values
  "Subresultants" -> reduceSubresultants compareExpression values
  "GroebnerBasis" -> reduceGroebnerBasis compareExpression values
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
  | Call (Symbol blankHead) [Symbol matchedHead] <- variable
  , systemHeadIn "Blank" blankHead
  , systemHeadIn "Plus" matchedHead = reduceExpand compareExpression [expression]
  | Call (Symbol timesHead) factors <- expression
  , systemHeadIn "Times" timesHead
  , let (dependentFactors, independentFactors) =
          partition (containsExpression variable) factors
  , not (null dependentFactors)
  , not (null independentFactors) = do
      dependent <- reduceExpand compareExpression [timesExpression dependentFactors]
      let independent = timesExpression independentFactors
          attach term =
            timesExpression
              ( sortBy compareExpression
                  (concatMap flattenPartialTimes [term, independent])
              )
      pure $ case dependent of
        Call (Symbol plusHead) terms
          | systemHeadIn "Plus" plusHead ->
              Call (Symbol "Plus") (sortBy compareExpression (map attach terms))
        _ -> attach dependent
  | variable `elem` discoverVariables compareExpression [] [expression] = do
      polynomial <- expressionToPolynomial [variable] expression
      pure (polynomialToExpr compareExpression [variable] polynomial)
  | otherwise = Just expression
reduceExpand _ _ = Nothing

containsExpression :: Expr -> Expr -> Bool
containsExpression target expression
  | target == expression = True
containsExpression target (Call expressionHead values) =
  containsExpression target expressionHead || any (containsExpression target) values
containsExpression target (Complex realPart imaginaryPart) =
  containsExpression target realPart || containsExpression target imaginaryPart
containsExpression _ _ = False

timesExpression :: [Expr] -> Expr
timesExpression values = case filter (/= Integer 1) values of
  [] -> Integer 1
  [value] -> value
  retained -> Call (Symbol "Times") retained

flattenPartialTimes :: Expr -> [Expr]
flattenPartialTimes (Call (Symbol timesHead) values)
  | systemHeadIn "Times" timesHead = concatMap flattenPartialTimes values
flattenPartialTimes value = [value]

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

reduceCollect :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceCollect compareExpression arguments = case arguments of
  [expression, variableSpec] ->
    collectExpression compareExpression expression variableSpec
  [expression, variableSpec, function] -> do
    plan <- collectCoefficientPlan compareExpression expression variableSpec
    pure (collectPlanExpression compareExpression function plan)
  _ -> Nothing

collectExpression :: CanonicalCompare -> Expr -> Expr -> Maybe Expr
collectExpression compareExpression expression variableSpec = do
  explicitVariables <- variableExpressions variableSpec
  let variables =
        discoverVariables compareExpression explicitVariables [expression]
      explicitCount = length explicitVariables
  polynomial <- expressionToPolynomial variables expression
  if explicitCount == 0
    then pure (polynomialToExpr compareExpression variables polynomial)
    else
      pure
        ( makePlus
            compareExpression
            [ makeTimes
                compareExpression
                [ collectMonomialExpression
                    compareExpression
                    explicitVariables
                    selected
                , polynomialToExpr compareExpression variables coefficient
                ]
            | (selected, coefficient) <-
                Map.toList (collectGroups explicitCount polynomial)
            ]
        )

collectGroups
  :: Int
  -> Polynomial
  -> Map.Map (Maybe (Int, Int)) Polynomial
collectGroups explicitCount (Polynomial terms) =
  Map.fromListWith addPolynomial
    [ ( selected
      , Polynomial
          ( Map.singleton
              ( maybe powers (\(index, _) -> replaceAt index 0 powers) selected
              )
              coefficient
          )
      )
    | (powers, coefficient) <- Map.toList terms
    , let selected = firstPositivePower explicitCount powers
    ]

firstPositivePower :: Int -> [Int] -> Maybe (Int, Int)
firstPositivePower explicitCount powers =
  firstPositive (take explicitCount (zip [0 ..] powers))
 where
  firstPositive [] = Nothing
  firstPositive ((index, power) : rest)
    | power > 0 = Just (index, power)
    | otherwise = firstPositive rest

collectMonomialExpression
  :: CanonicalCompare
  -> [Expr]
  -> Maybe (Int, Int)
  -> Expr
collectMonomialExpression _ _ Nothing = Integer 1
collectMonomialExpression compareExpression variables (Just (index, power)) =
  collectedPositivePowerExpression
    compareExpression
    (variables !! index)
    power

-- | Build the exact coefficient callback schedule for @Collect[p, vars, f]@.
-- Coefficients remain expressions in all implicit variables.
collectCoefficientPlan
  :: CanonicalCompare
  -> Expr
  -> Expr
  -> Maybe CollectPlan
collectCoefficientPlan compareExpression expression variableSpec = do
  explicitVariables <- variableExpressions variableSpec
  if null explicitVariables
    then
      if bridgeConvertible [] expression
        then Just (CollectDirect expression)
        else Nothing
    else
      if hasDuplicateExpressions explicitVariables
        then Nothing
        else do
          let variables =
                discoverVariables compareExpression explicitVariables [expression]
              explicitCount = length explicitVariables
          polynomial <- expressionToPolynomial variables expression
          if isZeroPolynomial polynomial
            then Just (CollectDirect (Integer 0))
            else
              let orderedGroups =
                    sortBy
                      (\(left, _) (right, _) -> compare right left)
                      ( Map.toList
                          (groupMonomialTerms explicitCount polynomial)
                      )
               in Just
                    ( CollectTerms
                        [ ( fullMonomialExpression
                              compareExpression
                              explicitVariables
                              powers
                          , polynomialToExpr
                              compareExpression
                              variables
                              coefficient
                          )
                        | (powers, coefficient) <- orderedGroups
                        ]
                    )

collectPlanExpression
  :: CanonicalCompare
  -> Expr
  -> CollectPlan
  -> Expr
collectPlanExpression _ function (CollectDirect coefficient) =
  Call function [coefficient]
collectPlanExpression compareExpression function (CollectTerms terms) =
  makePlus
    compareExpression
    [ makeTimes compareExpression [monomial, Call function [coefficient]]
    | (monomial, coefficient) <- terms
    ]

fullMonomialExpression
  :: CanonicalCompare
  -> [Expr]
  -> [Int]
  -> Expr
fullMonomialExpression compareExpression variables powers =
  makeTimes
    compareExpression
    [ collectedPositivePowerExpression compareExpression variable power
    | (variable, power) <- zip variables powers
    , power > 0
    ]

collectedPositivePowerExpression
  :: CanonicalCompare
  -> Expr
  -> Int
  -> Expr
collectedPositivePowerExpression compareExpression variable outerPower =
  case naturalMonomialFactorization variable of
    Just (coefficient, factors)
      | coefficient == oneExact ->
          makeTimes
            compareExpression
            [ positiveIntegerPowerExpression
                factor
                (factorPower * toInteger outerPower)
            | (factor, factorPower) <- factors
            ]
    _ -> positivePowerExpression variable outerPower

positivePowerExpression :: Expr -> Int -> Expr
positivePowerExpression variable power =
  positiveIntegerPowerExpression variable (toInteger power)

positiveIntegerPowerExpression :: Expr -> Integer -> Expr
positiveIntegerPowerExpression variable power
  | power == 1 = variable
  | otherwise =
      Call (Symbol "Power") [variable, Integer power]

reduceExponent :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceExponent compareExpression arguments = case arguments of
  [expression, form] -> do
    values <- exponentValuesForForm compareExpression expression form
    case reverse values of
      maximumValue : _ -> Just maximumValue
      [] -> Nothing
  [expression, form, function] -> do
    values <- exponentValuesForForm compareExpression expression form
    pure (Call function values)
  _ -> Nothing

-- | Return the distinct exponents supplied to the optional third argument of
-- 'Exponent', sorted from least to greatest.
exponentValuesForForm
  :: CanonicalCompare
  -> Expr
  -> Expr
  -> Maybe [Expr]
exponentValuesForForm compareExpression expression form
  | expressionIsExactZero expression = Just [Symbol "-Infinity"]
  | bridgeConvertible [] expression && bridgeConvertible [] form = do
      formPowers <- naturalMonomialPowers form
      exponentValuesWithPowers compareExpression expression formPowers
  | bridgeConvertible [form] expression =
      exponentValuesWithPowers compareExpression expression [(form, 1)]
  | otherwise = Nothing

exponentValuesWithPowers
  :: CanonicalCompare
  -> Expr
  -> [(Expr, Int)]
  -> Maybe [Expr]
exponentValuesWithPowers compareExpression expression formPowers = do
  let bases = map fst formPowers
      variables = discoverVariables compareExpression bases [expression]
  polynomial <- expressionToPolynomial variables expression
  if isZeroPolynomial polynomial
    then Just [Symbol "-Infinity"]
    else
      pure
        ( map
            Integer
            ( Set.toAscList
                ( Set.fromList
                    [ exponentForPowers formPowers powers
                    | powers <- Map.keys (polynomialTerms polynomial)
                    ]
                )
            )
        )

exponentForPowers :: [(Expr, Int)] -> [Int] -> Integer
exponentForPowers [] _ = 0
exponentForPowers formPowers powers =
  minimum
    [ max 0 (toInteger termPower `div` toInteger formPower)
    | (termPower, (_, formPower)) <- zip powers formPowers
    ]

naturalMonomialPowers :: Expr -> Maybe [(Expr, Int)]
naturalMonomialPowers expression = do
  (coefficient, powers) <- naturalMonomialFactorization expression
  if coefficient /= oneExact
    then Nothing
    else traverse boundedPower powers
 where
  boundedPower (base, power)
    | power > 0
    , power <= toInteger (maxBound :: Int) =
        Just (base, fromInteger power)
    | otherwise = Nothing

naturalMonomialFactorization :: Expr -> Maybe (Exact, [(Expr, Integer)])
naturalMonomialFactorization expression
  | Just coefficient <- exactRealExpression expression =
      Just (coefficient, [])
naturalMonomialFactorization (Call (Symbol headName) factors)
  | systemHeadIn "Times" headName =
      foldl' combineNaturalFactors (Just (oneExact, [])) factors
naturalMonomialFactorization (Call (Symbol headName) [base, Integer power])
  | systemHeadIn "Power" headName
  , power > 0 = do
      (coefficient, powers) <- naturalMonomialFactorization base
      pure
        ( exactPower coefficient power
        , foldl'
            (\retained (factor, factorPower) ->
              insertNaturalPower factor (factorPower * power) retained
            )
            []
            powers
        )
naturalMonomialFactorization (Call (Symbol headName) _)
  | systemHeadIn "Power" headName = Nothing
naturalMonomialFactorization expression = Just (oneExact, [(expression, 1)])

combineNaturalFactors
  :: Maybe (Exact, [(Expr, Integer)])
  -> Expr
  -> Maybe (Exact, [(Expr, Integer)])
combineNaturalFactors accumulated expression = do
  (leftCoefficient, leftPowers) <- accumulated
  (rightCoefficient, rightPowers) <- naturalMonomialFactorization expression
  pure
    ( multiplyExact leftCoefficient rightCoefficient
    , foldl'
        (\retained (base, power) -> insertNaturalPower base power retained)
        leftPowers
        rightPowers
    )

insertNaturalPower
  :: Expr
  -> Integer
  -> [(Expr, Integer)]
  -> [(Expr, Integer)]
insertNaturalPower base power [] = [(base, power)]
insertNaturalPower base power ((existingBase, existingPower) : rest)
  | base == existingBase = (existingBase, existingPower + power) : rest
  | otherwise =
      (existingBase, existingPower) : insertNaturalPower base power rest

exactRealExpression :: Expr -> Maybe Exact
exactRealExpression expression = do
  Gaussian real imaginary <- exactGaussian expression
  if imaginary == zeroExact then Just real else Nothing

exactPower :: Exact -> Integer -> Exact
exactPower (Exact numerator denominator) power =
  exact (numerator ^ power) (denominator ^ power)

expressionIsExactZero :: Expr -> Bool
expressionIsExactZero expression =
  exactGaussian expression == Just zeroGaussian

-- This mirrors the Python bridge's natural arithmetic subset.  An explicit
-- form is checked before descending so opaque composites such as @f[t]@ can
-- still be treated as polynomial variables.
bridgeConvertible :: [Expr] -> Expr -> Bool
bridgeConvertible explicit expression
  | expression `elem` explicit = True
bridgeConvertible _ (Integer _) = True
bridgeConvertible _ (Rational _ denominator) = denominator /= 0
bridgeConvertible explicit (Complex realPart imaginaryPart) =
  bridgeConvertible explicit realPart
    && bridgeConvertible explicit imaginaryPart
bridgeConvertible _ (Symbol _) = True
bridgeConvertible explicit (Call (Symbol headName) values)
  | systemHeadIn "Plus" headName || systemHeadIn "Times" headName =
      all (bridgeConvertible explicit) values
  | systemHeadIn "Power" headName
  , [base, power] <- values =
      bridgeConvertible explicit base
        && bridgeConvertible explicit power
bridgeConvertible _ _ = False

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
  [Call (Symbol listHead) items, variable]
    | systemHeadIn "List" listHead ->
        Call (Symbol "List") <$> traverse (\item -> reduceApart compareExpression [item, variable]) items
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
    normalized <-
      cancelRationalPolynomial variables rationalFunction
    case variables of
      [_] -> apartUnivariate compareExpression variables normalized
      _ -> apartBySeparatedDenominator compareExpression variables normalized

apartUnivariate :: CanonicalCompare -> [Expr] -> RationalPolynomial -> Maybe Expr
apartUnivariate compareExpression variables normalized@(RationalPolynomial numerator denominator) = do
  (quotient, remainder) <- univariateDivide numerator denominator
  let (linearFactors, residualDenominator) = factorRationalLinearRoots denominator
  if null linearFactors || not (isConstantPolynomial residualDenominator)
    then Just (rationalPolynomialToExpr compareExpression variables normalized)
    else do
      denominatorDegree <- polynomialDegree denominator
      let denominatorPowers =
            [ (factor, power)
            | (factor, multiplicity) <- linearFactors
            , power <- [1 .. multiplicity]
            ]
      if length denominatorPowers /= denominatorDegree
        then Nothing
        else do
          basisPolynomials <-
            traverse
              (\(factor, power) -> do
                  (basis, basisRemainder) <- univariateDivide denominator (powerPolynomial factor (fromIntegral power))
                  if isZeroPolynomial basisRemainder then Just basis else Nothing
              )
              denominatorPowers
          coefficients <-
            solveGaussianLinearSystem
              [ [polynomialCoefficient degree basis | basis <- basisPolynomials]
              | degree <- [0 .. denominatorDegree - 1]
              ]
              [polynomialCoefficient degree remainder | degree <- [0 .. denominatorDegree - 1]]
          let quotientTerms =
                if isZeroPolynomial quotient
                  then []
                  else [polynomialToExpr compareExpression variables quotient]
              fractionTerms =
                [ makeTimes
                    compareExpression
                    [ gaussianToExpr coefficient
                    , Call
                        (Symbol "Power")
                        [ polynomialToExpr compareExpression variables factor
                        , Integer (negate (fromIntegral power))
                        ]
                    ]
                | ((factor, power), coefficient) <- zip denominatorPowers coefficients
                , coefficient /= zeroGaussian
                ]
          pure (makePlus compareExpression (quotientTerms <> fractionTerms))

isConstantPolynomial :: Polynomial -> Bool
isConstantPolynomial (Polynomial terms) =
  all (all (== 0) . fst) (Map.toList terms)

polynomialDegree :: Polynomial -> Maybe Int
polynomialDegree polynomial = firstPower . fst <$> leadingTerm polynomial

polynomialCoefficient :: Int -> Polynomial -> Gaussian
polynomialCoefficient degree (Polynomial terms) =
  Map.findWithDefault zeroGaussian [degree] terms

factorRationalLinearRoots :: Polynomial -> ([(Polynomial, Int)], Polynomial)
factorRationalLinearRoots = go []
 where
  go retained current = case firstRationalRoot current of
    Nothing -> (reverse retained, current)
    Just rootValue ->
      let factor = rationalLinearFactor rootValue
       in case univariateDivide current factor of
            Just (quotient, remainder)
              | isZeroPolynomial remainder -> go (insertFactor factor retained) quotient
            _ -> (reverse retained, current)
  insertFactor factor [] = [(factor, 1)]
  insertFactor factor ((existing, multiplicity) : rest)
    | factor == existing = (existing, multiplicity + 1) : rest
    | otherwise = (existing, multiplicity) : insertFactor factor rest

firstRationalRoot :: Polynomial -> Maybe Exact
firstRationalRoot polynomial@(Polynomial terms) = do
  coefficients <- traverse rationalCoefficient (Map.toList terms)
  let denominatorLcm = foldl' lcm 1 [denominator | (_, Exact _ denominator) <- coefficients]
      integerCoefficients =
        [ (degree, numerator * (denominatorLcm `div` denominator))
        | (degree, Exact numerator denominator) <- coefficients
        ]
      constant = maybe 0 id (lookup 0 integerCoefficients)
      leading = maybe 0 snd (safeLast integerCoefficients)
      numerators = if constant == 0 then [0] else positiveDivisors (abs constant)
      denominators = positiveDivisors (abs leading)
      candidates =
        Set.toList
          ( Set.fromList
              [ exact signedNumerator denominator
              | numerator <- numerators
              , denominator <- denominators
              , signedNumerator <- if numerator == 0 then [0] else [negate numerator, numerator]
              ]
          )
  firstMatching
    (isPolynomialRationalRoot polynomial)
    (sortBy compareExactValue candidates)
 where
  rationalCoefficient ([degree], Gaussian value imaginary)
    | imaginary == zeroExact = Just (degree, value)
  rationalCoefficient _ = Nothing
  safeLast [] = Nothing
  safeLast values = Just (last values)

compareExactValue :: Exact -> Exact -> Ordering
compareExactValue (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  compare (leftNumerator * rightDenominator) (rightNumerator * leftDenominator)

isPolynomialRationalRoot :: Polynomial -> Exact -> Bool
isPolynomialRationalRoot (Polynomial terms) rootValue =
  foldl'
    addGaussian
    zeroGaussian
    [ multiplyGaussian coefficient (gaussianPower (Gaussian rootValue zeroExact) (firstPower powers))
    | (powers, coefficient) <- Map.toList terms
    ]
    == zeroGaussian

rationalLinearFactor :: Exact -> Polynomial
rationalLinearFactor (Exact numerator denominator) =
  Polynomial
    ( Map.filter
        (/= zeroGaussian)
        (Map.fromList
        [ ([0], Gaussian (Exact (negate numerator) 1) zeroExact)
        , ([1], Gaussian (Exact denominator 1) zeroExact)
        ])
    )

apartBySeparatedDenominator
  :: CanonicalCompare
  -> [Expr]
  -> RationalPolynomial
  -> Maybe Expr
apartBySeparatedDenominator compareExpression variables normalized@(RationalPolynomial numerator denominator) = do
  denominatorDegree <- polynomialDegreeInFirstVariable denominator
  coefficientFactor <- nonzeroCoefficientSlice denominatorDegree denominator
  scalarCoefficients <-
    traverse
      (\degree -> polynomialScalarMultiple coefficientFactor (firstVariableCoefficient degree denominator))
      [0 .. denominatorDegree]
  let univariateDenominator =
        Polynomial
          ( Map.fromList
              [ ([degree], coefficient)
              | (degree, coefficient) <- zip [0 ..] scalarCoefficients
              , coefficient /= zeroGaussian
              ]
          )
      dimensions = length variables
      liftedDenominator = liftUnivariatePolynomial dimensions univariateDenominator
  if multiplyPolynomial coefficientFactor liftedDenominator /= denominator
    then Nothing
    else do
      (quotient, remainder) <- divideInFirstVariable numerator liftedDenominator
      let (linearFactors, residualDenominator) = factorRationalLinearRoots univariateDenominator
      if null linearFactors || not (isConstantPolynomial residualDenominator)
        then Just (rationalPolynomialToExpr compareExpression variables normalized)
        else do
          let denominatorPowers =
                [ (factor, power)
                | (factor, multiplicity) <- linearFactors
                , power <- [1 .. multiplicity]
                ]
          if length denominatorPowers /= denominatorDegree
            then Nothing
            else do
              basisPolynomials <-
                traverse
                  (\(factor, power) -> do
                      (basis, basisRemainder) <-
                        univariateDivide
                          univariateDenominator
                          (powerPolynomial factor (fromIntegral power))
                      if isZeroPolynomial basisRemainder then Just basis else Nothing
                  )
                  denominatorPowers
              coefficientPolynomials <-
                solvePolynomialLinearSystem
                  dimensions
                  [ [polynomialCoefficient degree basis | basis <- basisPolynomials]
                  | degree <- [0 .. denominatorDegree - 1]
                  ]
                  [firstVariableCoefficient degree remainder | degree <- [0 .. denominatorDegree - 1]]
              let quotientTerms =
                    if isZeroPolynomial quotient
                      then []
                      else [polynomialToExpr compareExpression variables quotient]
                  fractionTerms =
                    [ makeTimes
                        compareExpression
                        [ polynomialToExpr compareExpression variables partialCoefficient
                        , Call
                            (Symbol "Power")
                            [ polynomialToExpr
                                compareExpression
                                variables
                                (liftUnivariatePolynomial dimensions factor)
                            , Integer (negate (fromIntegral power))
                            ]
                        ]
                    | ((factor, power), partialCoefficient) <- zip denominatorPowers coefficientPolynomials
                    , not (isZeroPolynomial partialCoefficient)
                    ]
                  inside = makePlus compareExpression (quotientTerms <> fractionTerms)
                  coefficientExpression = polynomialToExpr compareExpression variables coefficientFactor
              pure
                ( if isOnePolynomial coefficientFactor
                    then inside
                    else
                      makeTimes
                        compareExpression
                        [inside, Call (Symbol "Power") [coefficientExpression, Integer (-1)]]
                )

polynomialDegreeInFirstVariable :: Polynomial -> Maybe Int
polynomialDegreeInFirstVariable (Polynomial terms)
  | Map.null terms = Nothing
  | otherwise = Just (maximum [firstPower powers | powers <- Map.keys terms])

firstVariableCoefficient :: Int -> Polynomial -> Polynomial
firstVariableCoefficient degree (Polynomial terms) =
  Polynomial
    ( Map.fromList
        [ (0 : drop 1 powers, coefficient)
        | (powers, coefficient) <- Map.toList terms
        , firstPower powers == degree
        ]
    )

nonzeroCoefficientSlice :: Int -> Polynomial -> Maybe Polynomial
nonzeroCoefficientSlice degree polynomial =
  let coefficient = firstVariableCoefficient degree polynomial
   in if isZeroPolynomial coefficient then Nothing else Just coefficient

polynomialScalarMultiple :: Polynomial -> Polynomial -> Maybe Gaussian
polynomialScalarMultiple basis value
  | isZeroPolynomial value = Just zeroGaussian
  | otherwise = do
      (_, basisLeading) <- leadingTerm basis
      (_, valueLeading) <- leadingTerm value
      scalar <- divideGaussian valueLeading basisLeading
      if scalePolynomial scalar basis == value then Just scalar else Nothing

liftUnivariatePolynomial :: Int -> Polynomial -> Polynomial
liftUnivariatePolynomial dimensions (Polynomial terms) =
  Polynomial
    ( Map.fromList
        [ (degree : replicate (dimensions - 1) 0, coefficient)
        | ([degree], coefficient) <- Map.toList terms
        ]
    )

divideInFirstVariable :: Polynomial -> Polynomial -> Maybe (Polynomial, Polynomial)
divideInFirstVariable dividend divisor
  | isZeroPolynomial divisor = Nothing
  | otherwise = go (zeroPolynomial dimensions) dividend 0
 where
  dimensions = polynomialDimensions dividend
  (divisorPowers, divisorCoefficient) = maybe ([], zeroGaussian) id (leadingTerm divisor)
  divisorDegree = firstPower divisorPowers
  go :: Polynomial -> Polynomial -> Int -> Maybe (Polynomial, Polynomial)
  go quotient remainder steps
    | steps > 100000 = Nothing
    | otherwise = case leadingTerm remainder of
        Nothing -> Just (quotient, remainder)
        Just (remainderPowers, remainderCoefficient)
          | firstPower remainderPowers < divisorDegree -> Just (quotient, remainder)
          | otherwise -> do
              coefficient <- divideGaussian remainderCoefficient divisorCoefficient
              let powers = zipWith (-) remainderPowers divisorPowers
              if any (< 0) powers
                then Just (quotient, remainder)
                else
                  let term = Polynomial (Map.singleton powers coefficient)
                   in go
                        (addPolynomial quotient term)
                        (subtractPolynomial remainder (multiplyPolynomial term divisor))
                        (steps + 1)

solvePolynomialLinearSystem
  :: Int
  -> [[Gaussian]]
  -> [Polynomial]
  -> Maybe [Polynomial]
solvePolynomialLinearSystem _dimensions coefficientRows rightHandSide
  | length coefficientRows /= length rightHandSide = Nothing
  | any ((/= size) . length) coefficientRows = Nothing
  | otherwise = map snd <$> eliminate 0 augmented
 where
  size = length rightHandSide
  augmented = zip coefficientRows rightHandSide
  eliminate column rows
    | column == size = Just rows
    | otherwise = do
        pivotIndex <-
          firstMatching
            (\rowIndex -> fst (rows !! rowIndex) !! column /= zeroGaussian)
            [column .. size - 1]
        pivotInverse <- reciprocalGaussian (fst (rows !! pivotIndex) !! column)
        let swapped = replaceAt pivotIndex (rows !! column) (replaceAt column (rows !! pivotIndex) rows)
            (pivotCoefficients, pivotValue) = swapped !! column
            normalizedPivot =
              ( map (multiplyGaussian pivotInverse) pivotCoefficients
              , scalePolynomial pivotInverse pivotValue
              )
            reduceRow rowIndex (rowCoefficients, rowValue)
              | rowIndex == column = normalizedPivot
              | otherwise =
                  let factor = rowCoefficients !! column
                   in ( zipWith
                          (\value pivotValueCoefficient ->
                              addGaussian value (negateGaussian (multiplyGaussian factor pivotValueCoefficient))
                          )
                          rowCoefficients
                          (fst normalizedPivot)
                      , subtractPolynomial
                          rowValue
                          (scalePolynomial factor (snd normalizedPivot))
                      )
            reduced = [reduceRow rowIndex row | (rowIndex, row) <- zip [0 :: Int ..] swapped]
        eliminate (column + 1) reduced

solveGaussianLinearSystem :: [[Gaussian]] -> [Gaussian] -> Maybe [Gaussian]
solveGaussianLinearSystem coefficientRows rightHandSide
  | length coefficientRows /= length rightHandSide = Nothing
  | any ((/= size) . length) coefficientRows = Nothing
  | otherwise = map last <$> eliminate 0 augmented
 where
  size = length rightHandSide
  augmented = zipWith (\row value -> row <> [value]) coefficientRows rightHandSide
  eliminate column rows
    | column == size = Just rows
    | otherwise = do
        pivotIndex <-
          firstMatching
            (\rowIndex -> rows !! rowIndex !! column /= zeroGaussian)
            [column .. size - 1]
        pivotInverse <- reciprocalGaussian (rows !! pivotIndex !! column)
        let swapped = replaceAt pivotIndex (rows !! column) (replaceAt column (rows !! pivotIndex) rows)
            pivotRow = map (multiplyGaussian pivotInverse) (swapped !! column)
            reduceRow rowIndex row
              | rowIndex == column = pivotRow
              | otherwise =
                  let factor = row !! column
                   in zipWith
                        (\value pivotValue -> addGaussian value (negateGaussian (multiplyGaussian factor pivotValue)))
                        row
                        pivotRow
            reduced = [reduceRow rowIndex row | (rowIndex, row) <- zip [0 :: Int ..] swapped]
        eliminate (column + 1) reduced

reduceFactor :: CanonicalCompare -> Bool -> [Expr] -> Maybe Expr
reduceFactor compareExpression returnList arguments = case arguments of
  [expression] -> factorOne expression
  [expression, option]
    | acceptsRationalFactorOption option -> factorOne expression
    | gaussianFactorOption option -> factorGaussian expression
    | Just modulus <- modularFactorOption option -> factorModular modulus expression
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
  factorGaussian expression = do
    let variables = discoverVariables compareExpression [] [expression]
    [variable] <- pure variables
    polynomial <- expressionToPolynomial variables expression
    if polynomial == plusOneQuadratic
      then
        let factors =
              [ Call (Symbol "Plus") [Complex (Integer 0) (Integer (-1)), variable]
              , Call (Symbol "Plus") [Complex (Integer 0) (Integer 1), variable]
              ]
         in Just (factorDomainResult returnList factors [1, 1])
      else Nothing
  factorModular modulus expression = do
    let variables = discoverVariables compareExpression [] [expression]
    [variable] <- pure variables
    polynomial <- expressionToPolynomial variables expression
    if modulus == 2 && polynomial == plusOneQuadratic
      then
        Just
          ( factorDomainResult
              returnList
              [Call (Symbol "Plus") [Integer 1, variable]]
              [2]
          )
      else
        if modulus == 5 && polynomial == minusOneQuadratic
          then
            Just
              ( factorDomainResult
                  returnList
                  [ Call (Symbol "Plus") [Integer 1, variable]
                  , Call (Symbol "Plus") [Integer (-1), variable]
                  ]
                  [1, 1]
              )
          else Nothing
  plusOneQuadratic =
    Polynomial
      (Map.fromList [([0], oneGaussian), ([2], oneGaussian)])
  minusOneQuadratic =
    Polynomial
      (Map.fromList [([0], negateGaussian oneGaussian), ([2], oneGaussian)])
  factorDomainResult :: Bool -> [Expr] -> [Int] -> Expr
  factorDomainResult False factors multiplicities =
    makeTimes
      compareExpression
      [ if multiplicity == 1
          then factor
          else Call (Symbol "Power") [factor, Integer (fromIntegral multiplicity)]
      | (factor, multiplicity) <- zip factors multiplicities
      ]
  factorDomainResult True factors multiplicities =
    Call
      (Symbol "List")
      ( Call (Symbol "List") [Integer 1, Integer 1]
          : [ Call (Symbol "List") [factor, Integer (fromIntegral multiplicity)]
            | (factor, multiplicity) <- zip factors multiplicities
            ]
      )

acceptsRationalFactorOption :: Expr -> Bool
acceptsRationalFactorOption (Call (Symbol ruleHead) [Symbol optionName, Symbol valueName]) =
  systemHeadIn "Rule" ruleHead
    && ( (systemHeadIn "GaussianIntegers" optionName && systemHeadIn "False" valueName)
           || (systemHeadIn "Extension" optionName && systemHeadIn "None" valueName)
       )
acceptsRationalFactorOption _ = False

gaussianFactorOption :: Expr -> Bool
gaussianFactorOption (Call (Symbol ruleHead) [Symbol optionName, optionValue])
  | systemHeadIn "Rule" ruleHead =
      ( systemHeadIn "GaussianIntegers" optionName
          && optionValue == Symbol "True"
      )
       || ( systemHeadIn "Extension" optionName
               && ( optionValue == Symbol "I"
                      || optionValue == Complex (Integer 0) (Integer 1)
                      || optionValue
                        == Call (Symbol "List") [Complex (Integer 0) (Integer 1)]
                  )
           )
gaussianFactorOption _ = False

modularFactorOption :: Expr -> Maybe Integer
modularFactorOption (Call (Symbol ruleHead) [Symbol optionName, Integer modulus])
  | systemHeadIn "Rule" ruleHead
  , systemHeadIn "Modulus" optionName
  , modulus > 1 = Just modulus
modularFactorOption _ = Nothing

reduceDecompose :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceDecompose compareExpression [expression, variableSpec] = do
  [variable] <- variableExpressions variableSpec
  let variables = discoverVariables compareExpression [variable] [expression]
      dimensions = length variables
  polynomial <- expressionToPolynomial variables expression
  decomposition <- decomposePolynomial dimensions polynomial
  pure
    ( Call
        (Symbol "List")
        (map (polynomialToExpr compareExpression variables) decomposition)
    )
reduceDecompose _ _ = Nothing

-- SymPy's univariate decomposition normalizes every non-linear right
-- component to be monic with zero constant term.  That normalization makes
-- the candidate deterministic: once an inner degree is chosen, its
-- coefficients are forced by the highest coefficients of the input.
-- Restrict the constructive search to modest degrees so adversarial expanded
-- powers recover symbolically instead of allocating an unbounded tower.
decomposePolynomial :: Int -> Polynomial -> Maybe [Polynomial]
decomposePolynomial dimensions polynomial = do
  degree <- case leadingVariableDegree polynomial of
    Nothing -> Just 0
    Just value
      | value <= 64 -> Just value
      | otherwise -> Nothing
  native <- decomposePolynomialNative dimensions degree polynomial
  case native of
    [single] ->
      Just
        ( maybe
            native
            (\(outer, inner) -> [outer, inner])
            (exponentGcdDecomposition dimensions single)
        )
    _ -> Just native

decomposePolynomialNative :: Int -> Int -> Polynomial -> Maybe [Polynomial]
decomposePolynomialNative dimensions degree polynomial =
  case firstPolynomialDecomposition candidateDegrees of
    Nothing -> Just [polynomial]
    Just (outer, inner) -> do
      outerDegree <- leadingVariableDegree outer
      innerDegree <- leadingVariableDegree inner
      outerParts <- decomposePolynomialNative dimensions outerDegree outer
      innerParts <- decomposePolynomialNative dimensions innerDegree inner
      pure (outerParts <> innerParts)
 where
  candidateDegrees =
    [ innerDegree
    | innerDegree <- [2 .. degree `div` 2]
    , degree `mod` innerDegree == 0
    ]
  firstPolynomialDecomposition [] = Nothing
  firstPolynomialDecomposition (innerDegree : rest) =
    case polynomialCompositionForInnerDegree dimensions degree innerDegree polynomial of
      Just decomposition -> Just decomposition
      Nothing -> firstPolynomialDecomposition rest

polynomialCompositionForInnerDegree
  :: Int
  -> Int
  -> Int
  -> Polynomial
  -> Maybe (Polynomial, Polynomial)
polynomialCompositionForInnerDegree dimensions degree innerDegree polynomial = do
  let outerDegree = degree `div` innerDegree
      leadingCoefficient = coefficientInLeadingVariable dimensions degree polynomial
  leadingScalar <- constantPolynomialGaussian dimensions leadingCoefficient
  let leadingDivisor =
        multiplyGaussian
          (Gaussian (Exact (fromIntegral outerDegree) 1) zeroExact)
          leadingScalar
  leadingDivisorInverse <- reciprocalGaussian leadingDivisor
  inner <-
    buildInner
      leadingScalar
      leadingDivisorInverse
      outerDegree
      1
      (powerPolynomial (variablePolynomial dimensions 0) (fromIntegral innerDegree))
  outer <- solveOuter outerDegree inner polynomial (zeroPolynomial dimensions)
  pure (outer, inner)
 where
  buildInner leadingScalar leadingDivisorInverse outerDegree offset inner
    | offset >= innerDegree = Just inner
    | otherwise = do
        let targetDegree = degree - offset
            target = coefficientInLeadingVariable dimensions targetDegree polynomial
            current =
              coefficientInLeadingVariable
                dimensions
                targetDegree
                ( scalePolynomial
                    leadingScalar
                    (powerPolynomial inner (fromIntegral outerDegree))
                )
            coefficient =
              scalePolynomial
                leadingDivisorInverse
                (subtractPolynomial target current)
            updated =
              addPolynomial
                inner
                (shiftLeadingVariablePower dimensions (innerDegree - offset) coefficient)
        buildInner leadingScalar leadingDivisorInverse outerDegree (offset + 1) updated

  solveOuter power inner residual outer
    | power < 0 =
        if isZeroPolynomial residual
          then Just outer
          else Nothing
    | otherwise =
        let coefficient =
              coefficientInLeadingVariable
                dimensions
                (power * innerDegree)
                residual
            outerTerm = shiftLeadingVariablePower dimensions power coefficient
            nextResidual =
              subtractPolynomial
                residual
                (multiplyPolynomial coefficient (powerPolynomial inner (fromIntegral power)))
         in solveOuter
              (power - 1)
              inner
              nextResidual
              (addPolynomial outer outerTerm)

exponentGcdDecomposition :: Int -> Polynomial -> Maybe (Polynomial, Polynomial)
exponentGcdDecomposition dimensions polynomial = do
  let positiveExponents =
        Set.toList
          ( Set.fromList
              [ firstPower powers
              | (powers, _) <- Map.toList (polynomialTerms polynomial)
              , firstPower powers > 0
              ]
          )
      constantCoefficient = coefficientInLeadingVariable dimensions 0 polynomial
  if length positiveExponents < 2 && isZeroPolynomial constantCoefficient
    then Nothing
    else do
      exponentDivisor <- case positiveExponents of
        [] -> Nothing
        firstExponent : rest -> Just (foldl' gcd firstExponent rest)
      if exponentDivisor <= 1
        then Nothing
        else
          let outer =
                Polynomial
                  ( Map.fromListWith
                      addGaussian
                      [ ( replaceAt
                            0
                            (firstPower powers `div` exponentDivisor)
                            powers
                        , coefficient
                        )
                      | (powers, coefficient) <- Map.toList (polynomialTerms polynomial)
                      ]
                  )
              inner =
                powerPolynomial
                  (variablePolynomial dimensions 0)
                  (fromIntegral exponentDivisor)
           in if outer == variablePolynomial dimensions 0
                then Nothing
                else Just (outer, inner)

coefficientInLeadingVariable :: Int -> Int -> Polynomial -> Polynomial
coefficientInLeadingVariable dimensions degree polynomial =
  Map.findWithDefault
    (zeroPolynomial dimensions)
    degree
    (leadingVariableCoefficients dimensions polynomial)

constantPolynomialGaussian :: Int -> Polynomial -> Maybe Gaussian
constantPolynomialGaussian dimensions (Polynomial terms) =
  case Map.toList terms of
    [(powers, coefficient)]
      | powers == replicate dimensions 0 -> Just coefficient
    _ -> Nothing

shiftLeadingVariablePower :: Int -> Int -> Polynomial -> Polynomial
shiftLeadingVariablePower dimensions power (Polynomial terms) =
  Polynomial
    ( Map.fromListWith
        addGaussian
        [ (replaceAt 0 (firstPower powers + power) powers, coefficient)
        | (powers, coefficient) <- Map.toList terms
        , length powers == dimensions
        ]
    )

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

reduceSubresultants :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceSubresultants
  compareExpression
  [leftExpression, rightExpression, variableSpec] = do
    [variable] <- variableExpressions variableSpec
    let variables =
          discoverVariables
            compareExpression
            [variable]
            [leftExpression, rightExpression]
        dimensions = length variables
    left <- expressionToPolynomial variables leftExpression
    right <- expressionToPolynomial variables rightExpression
    leftDegree <- leadingVariableDegree left
    rightDegree <- leadingVariableDegree right
    if leftDegree + rightDegree > 64
      then Nothing
      else do
        coefficients <-
          principalSubresultantCoefficients
            dimensions
            leftDegree
            rightDegree
            left
            right
        pure
          ( Call
              (Symbol "List")
              (map (polynomialToExpr compareExpression variables) coefficients)
          )
reduceSubresultants _ _ = Nothing

-- SymPy obtains these values from its subresultant polynomial remainder
-- sequence rather than directly from Sylvester minors.  That distinction is
-- observable for defective sequences: when a remainder drops by more than one
-- degree, Brown's exact scaling produces a different principal coefficient.
-- Keep the whole sequence so equal-degree inputs also retain SymPy's
-- last-polynomial-wins convention.
principalSubresultantCoefficients
  :: Int
  -> Int
  -> Int
  -> Polynomial
  -> Polynomial
  -> Maybe [Polynomial]
principalSubresultantCoefficients dimensions leftDegree rightDegree left right = do
  sequenceValues <-
    subresultantPolynomialSequence
      dimensions
      leftDegree
      rightDegree
      left
      right
  let lowerDegree = min leftDegree rightDegree
      degreeToPolynomial =
        Map.fromList
          [ (degree, polynomial)
          | polynomial <- sequenceValues
          , Just degree <- [leadingVariableDegree polynomial]
          , degree <= lowerDegree
          ]
  pure
    [ maybe
        (zeroPolynomial dimensions)
        (coefficientInLeadingVariable dimensions index)
        (Map.lookup index degreeToPolynomial)
    | index <- [0 .. lowerDegree]
    ]

-- Brown's subresultant PRS, matching SymPy's dup/dmp_inner_subresultants.
-- Coefficients are themselves exact polynomials in every implicit variable;
-- each quotient below is therefore required to divide exactly in Q(i)[vars].
subresultantPolynomialSequence
  :: Int
  -> Int
  -> Int
  -> Polynomial
  -> Polynomial
  -> Maybe [Polynomial]
subresultantPolynomialSequence dimensions leftDegree rightDegree left right = do
  let (higherDegree, lowerDegree, higher, lower)
        | leftDegree < rightDegree = (rightDegree, leftDegree, right, left)
        | otherwise = (leftDegree, rightDegree, left, right)
      degreeDifference = higherDegree - lowerDegree
  rawRemainder <-
    pseudoRemainderInLeadingVariable dimensions higher lower
  lowerLeading <-
    leadingVariableCoefficient dimensions lowerDegree lower
  let initialRemainder
        | odd (degreeDifference + 1) = negatePolynomial rawRemainder
        | otherwise = rawRemainder
      initialScale =
        negatePolynomial
          (powerPolynomial lowerLeading (fromIntegral degreeDifference))
  continue
    [higher, lower]
    lower
    lowerDegree
    initialRemainder
    lowerLeading
    initialScale
 where
  continue retained previous previousDegree remainder previousLeading scale
    | isZeroPolynomial remainder = Just retained
    | otherwise = do
        remainderDegree <- leadingVariableDegree remainder
        let degreeDrop = previousDegree - remainderDegree
            updatedRetained = retained <> [remainder]
            quotientDivisor =
              negatePolynomial
                ( multiplyPolynomial
                    previousLeading
                    (powerPolynomial scale (fromIntegral degreeDrop))
                )
        rawNext <-
          pseudoRemainderInLeadingVariable dimensions previous remainder
        if isZeroPolynomial rawNext
          then Just updatedRetained
          else do
            next <-
              dividePolynomialExactly dimensions rawNext quotientDivisor
            remainderLeading <-
              leadingVariableCoefficient
                dimensions
                remainderDegree
                remainder
            nextScale <-
              if degreeDrop > 1
                then
                  dividePolynomialExactly
                    dimensions
                    ( powerPolynomial
                        (negatePolynomial remainderLeading)
                        (fromIntegral degreeDrop)
                    )
                    (powerPolynomial scale (fromIntegral (degreeDrop - 1)))
                else Just (negatePolynomial remainderLeading)
            continue
              updatedRetained
              remainder
              remainderDegree
              next
              remainderLeading
              nextScale

pseudoRemainderInLeadingVariable
  :: Int
  -> Polynomial
  -> Polynomial
  -> Maybe Polynomial
pseudoRemainderInLeadingVariable dimensions dividend divisor = do
  dividendDegree <- leadingVariableDegree dividend
  divisorDegree <- leadingVariableDegree divisor
  if dividendDegree < divisorDegree
    then Just dividend
    else do
      divisorLeading <-
        leadingVariableCoefficient dimensions divisorDegree divisor
      reduce
        divisorDegree
        divisorLeading
        dividend
        dividendDegree
        (dividendDegree - divisorDegree + 1)
 where
  reduce divisorDegree divisorLeading remainder remainderDegree remainingPower = do
    remainderLeading <-
      leadingVariableCoefficient dimensions remainderDegree remainder
    let degreeShift = remainderDegree - divisorDegree
        nextPower = remainingPower - 1
        scaledRemainder = multiplyPolynomial remainder divisorLeading
        scaledDivisor =
          shiftLeadingVariablePower
            dimensions
            degreeShift
            (multiplyPolynomial divisor remainderLeading)
        nextRemainder = subtractPolynomial scaledRemainder scaledDivisor
    case leadingVariableDegree nextRemainder of
      Nothing -> Just (zeroPolynomial dimensions)
      Just nextDegree
        | nextDegree < divisorDegree ->
            if nextPower < 0
              then Nothing
              else
                Just
                  ( multiplyPolynomial
                      nextRemainder
                      (powerPolynomial divisorLeading (fromIntegral nextPower))
                  )
        | nextDegree < remainderDegree && nextPower >= 0 ->
            reduce
              divisorDegree
              divisorLeading
              nextRemainder
              nextDegree
              nextPower
        | otherwise -> Nothing

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

reducePolynomialReduce :: CanonicalCompare -> [Expr] -> Maybe Expr
reducePolynomialReduce
  compareExpression
  [dividendExpression, Call (Symbol listHead) reducerExpressions, variableSpec]
    | systemHeadIn "List" listHead = do
        explicitVariables <- variableExpressions variableSpec
        if null explicitVariables || hasDuplicateExpressions explicitVariables
          then Nothing
          else do
            let variables =
                  discoverVariables
                    compareExpression
                    explicitVariables
                    (dividendExpression : reducerExpressions)
                dimensions = length variables
                explicitDimensions = length explicitVariables
            dividend <- expressionToPolynomial variables dividendExpression
            reducers <- traverse (expressionToPolynomial variables) reducerExpressions
            if any isZeroPolynomial reducers
                || any
                  (not . hasScalarLeadingCoefficient explicitDimensions)
                  reducers
              then Nothing
              else do
                (quotients, remainder) <-
                  reducePolynomialByList dimensions dividend reducers
                pure
                  ( Call
                      (Symbol "List")
                      [ Call
                          (Symbol "List")
                          (map (polynomialToExpr compareExpression variables) quotients)
                      , polynomialToExpr compareExpression variables remainder
                      ]
                  )
reducePolynomialReduce _ _ = Nothing

-- Symbols not named as generators are coefficients in the Python bridge.
-- The native representation can still reduce by monic/scalar-leading
-- divisors because those operations never invert a symbolic coefficient.
-- Reject other divisors rather than accidentally treating their coefficient
-- symbols as additional Groebner generators.
hasScalarLeadingCoefficient :: Int -> Polynomial -> Bool
hasScalarLeadingCoefficient explicitDimensions (Polynomial terms) =
  case Map.keys terms of
    [] -> False
    powers ->
      let leadingExplicit = maximum (map (take explicitDimensions) powers)
       in all
            (\current ->
                take explicitDimensions current /= leadingExplicit
                  || all (== 0) (drop explicitDimensions current)
            )
            powers

reducePolynomialByList
  :: Int
  -> Polynomial
  -> [Polynomial]
  -> Maybe ([Polynomial], Polynomial)
reducePolynomialByList dimensions dividend divisors
  | any isZeroPolynomial divisors = Nothing
  | otherwise =
      go
        (replicate (length divisors) (zeroPolynomial dimensions))
        (zeroPolynomial dimensions)
        dividend
        0
 where
  go
    :: [Polynomial]
    -> Polynomial
    -> Polynomial
    -> Int
    -> Maybe ([Polynomial], Polynomial)
  go quotients remainder current steps
    | steps > 200000 = Nothing
    | otherwise = case leadingTerm current of
        Nothing -> Just (quotients, remainder)
        Just (currentPowers, currentCoefficient) ->
          case firstReduction currentPowers currentCoefficient 0 divisors of
            Just (index, term) ->
              go
                (replaceAt index (addPolynomial (quotients !! index) term) quotients)
                remainder
                (subtractPolynomial current (multiplyPolynomial term (divisors !! index)))
                (steps + 1)
            Nothing ->
              let leading =
                    Polynomial
                      (Map.singleton currentPowers currentCoefficient)
               in go
                    quotients
                    (addPolynomial remainder leading)
                    (subtractPolynomial current leading)
                    (steps + 1)

  firstReduction _ _ _ [] = Nothing
  firstReduction currentPowers currentCoefficient index (divisor : rest) =
    case leadingTerm divisor of
      Just (divisorPowers, divisorCoefficient)
        | monomialDivides divisorPowers currentPowers ->
            case divideGaussian currentCoefficient divisorCoefficient of
              Just coefficient ->
                Just
                  ( index
                  , Polynomial
                      ( Map.singleton
                          (zipWith (-) currentPowers divisorPowers)
                          coefficient
                      )
                  )
              Nothing -> firstReduction currentPowers currentCoefficient (index + 1) rest
      _ -> firstReduction currentPowers currentCoefficient (index + 1) rest

reduceGroebnerBasis :: CanonicalCompare -> [Expr] -> Maybe Expr
reduceGroebnerBasis
  compareExpression
  [Call (Symbol listHead) polynomialExpressions, variableSpec]
    | systemHeadIn "List" listHead = do
        explicitVariables <- variableExpressions variableSpec
        if null explicitVariables || hasDuplicateExpressions explicitVariables
          then Nothing
          else do
            let variables =
                  discoverVariables
                    compareExpression
                    explicitVariables
                    polynomialExpressions
            polynomials <-
              traverse
                (expressionToPolynomial variables)
                polynomialExpressions
            if any ((> 64) . polynomialTotalDegree) polynomials
                || sum (map (Map.size . polynomialTerms) polynomials) > 4096
              then Nothing
              else
                if variables /= explicitVariables
                  then do
                    basis <-
                      symbolicHomogeneousFullRankBasis
                        (length explicitVariables)
                        (length variables)
                        polynomials
                    pure (Call (Symbol "List") [explicitVariables !! index | index <- basis])
                  else do
                    basis <- groebnerBasis (length variables) polynomials
                    let expressions =
                          sortBy
                            compareExpression
                            (map (polynomialToExpr compareExpression variables) basis)
                    pure (Call (Symbol "List") expressions)
reduceGroebnerBasis _ _ = Nothing

-- A square homogeneous linear system with a nonzero determinant generates
-- every named variable over Python's rational-function coefficient field.
-- Proving that determinant in the polynomial ring avoids assuming that two
-- structurally similar symbolic rows are independent.
symbolicHomogeneousFullRankBasis
  :: Int
  -> Int
  -> [Polynomial]
  -> Maybe [Int]
symbolicHomogeneousFullRankBasis explicitDimensions dimensions polynomials = do
  let symbolicDimensions = dimensions - explicitDimensions
  if symbolicDimensions <= 0
      || length polynomials /= explicitDimensions
    then Nothing
    else do
      coefficientRows <-
        traverse
          (symbolicLinearCoefficientRow explicitDimensions dimensions)
          polynomials
      determinant <- polynomialDeterminant symbolicDimensions coefficientRows
      if isZeroPolynomial determinant
        then Nothing
        else Just [0 .. explicitDimensions - 1]

symbolicLinearCoefficientRow
  :: Int
  -> Int
  -> Polynomial
  -> Maybe [Polynomial]
symbolicLinearCoefficientRow explicitDimensions dimensions (Polynomial terms) = do
  indexedTerms <- traverse variableTerm (Map.toList terms)
  pure
    [ Polynomial
        ( Map.filter
            (/= zeroGaussian)
            ( Map.fromListWith
                addGaussian
                [ (coefficientPowers, coefficient)
                | (variableIndex, coefficientPowers, coefficient) <- indexedTerms
                , variableIndex == targetIndex
                ]
            )
        )
    | targetIndex <- [0 .. explicitDimensions - 1]
    ]
 where
  variableTerm (powers, coefficient) = do
    if length powers /= dimensions
      then Nothing
      else case
        [ index
        | (index, exponentValue) <- zip [0 :: Int ..] (take explicitDimensions powers)
        , exponentValue == 1
        ] of
        [variableIndex]
          | sum (take explicitDimensions powers) == 1 ->
              Just (variableIndex, drop explicitDimensions powers, coefficient)
        _ -> Nothing

groebnerBasis :: Int -> [Polynomial] -> Maybe [Polynomial]
groebnerBasis dimensions polynomials = do
  normalized <- traverse monicPolynomial (filter (not . isZeroPolynomial) polynomials)
  let initial = uniquePolynomials normalized
  if any isOnePolynomial initial
    then Just [onePolynomial dimensions]
    else do
      completed <-
        complete
          initial
          [ (left, right)
          | left <- [0 .. length initial - 1]
          , right <- [left + 1 .. length initial - 1]
          ]
          0
      reducedGroebnerBasis dimensions completed
 where
  complete
    :: [Polynomial]
    -> [(Int, Int)]
    -> Int
    -> Maybe [Polynomial]
  complete basis [] _ = Just basis
  complete basis ((leftIndex, rightIndex) : pairs) processed
    | processed > 20000 = Nothing
    | leftIndex >= length basis || rightIndex >= length basis = Nothing
    | otherwise = do
        sPolynomial <- makeSPolynomial (basis !! leftIndex) (basis !! rightIndex)
        (_, remainder) <- reducePolynomialByList dimensions sPolynomial basis
        if isZeroPolynomial remainder
          then complete basis pairs (processed + 1)
          else do
            normalizedRemainder <- monicPolynomial remainder
            if normalizedRemainder `elem` basis
              then complete basis pairs (processed + 1)
              else
                if length basis >= 128
                    || Map.size (polynomialTerms normalizedRemainder) > 4096
                  then Nothing
                  else
                    let newIndex = length basis
                        updatedBasis = basis <> [normalizedRemainder]
                        updatedPairs =
                          pairs <> [(index, newIndex) | index <- [0 .. newIndex - 1]]
                     in complete updatedBasis updatedPairs (processed + 1)

makeSPolynomial :: Polynomial -> Polynomial -> Maybe Polynomial
makeSPolynomial left right = do
  (leftPowers, leftCoefficient) <- leadingTerm left
  (rightPowers, rightCoefficient) <- leadingTerm right
  leftInverse <- reciprocalGaussian leftCoefficient
  rightInverse <- reciprocalGaussian rightCoefficient
  let commonPowers = zipWith max leftPowers rightPowers
      scaledLeft =
        shiftScalePolynomial
          (zipWith (-) commonPowers leftPowers)
          leftInverse
          left
      scaledRight =
        shiftScalePolynomial
          (zipWith (-) commonPowers rightPowers)
          rightInverse
          right
  pure (subtractPolynomial scaledLeft scaledRight)

reducedGroebnerBasis :: Int -> [Polynomial] -> Maybe [Polynomial]
reducedGroebnerBasis dimensions basis = do
  let minimal = minimalGroebnerBasis basis
  reduced <- traverse (reduceOne minimal) (zip [0 :: Int ..] minimal)
  normalized <- traverse monicPolynomial (filter (not . isZeroPolynomial) reduced)
  let unique = uniquePolynomials normalized
  if any isOnePolynomial unique
    then Just [onePolynomial dimensions]
    else Just unique
 where
  reduceOne minimal (index, polynomial) = do
    let others =
          [ other
          | (otherIndex, other) <- zip [0 :: Int ..] minimal
          , otherIndex /= index
          ]
    if null others
      then Just polynomial
      else snd <$> reducePolynomialByList dimensions polynomial others

minimalGroebnerBasis :: [Polynomial] -> [Polynomial]
minimalGroebnerBasis basis =
  let indexed = zip [0 :: Int ..] basis
   in
    [ polynomial
    | (index, polynomial) <- indexed
    , Just (powers, _) <- [leadingTerm polynomial]
    , not
        ( any
            (\(otherIndex, other) ->
                case leadingTerm other of
                  Just (otherPowers, _) ->
                    otherIndex /= index
                      && monomialDivides otherPowers powers
                      && (otherPowers /= powers || otherIndex < index)
                  Nothing -> False
            )
            indexed
        )
    ]

uniquePolynomials :: [Polynomial] -> [Polynomial]
uniquePolynomials = foldl' retain []
 where
  retain retained polynomial
    | polynomial `elem` retained = retained
    | otherwise = retained <> [polynomial]

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
          (primitiveFactors, remainder) = factorPrimitivePolynomial variables primitive
       in Factorization content monomialPowers primitiveFactors remainder

factorPrimitivePolynomial :: [Expr] -> Polynomial -> ([(Polynomial, Int)], Polynomial)
factorPrimitivePolynomial variables polynomial =
  let (linearFactors, remainder) = factorIntegerLinearRoots variables polynomial
   in if isOnePolynomial remainder
        then (linearFactors, remainder)
        else case perfectSquarePolynomial remainder of
          Just squareRoot ->
            let (rootFactors, rootRemainder) = factorIntegerLinearRoots variables squareRoot
                retainedRoot =
                  if isOnePolynomial rootRemainder
                    then []
                    else [(rootRemainder, 2)]
             in (linearFactors <> [(factor, multiplicity * 2) | (factor, multiplicity) <- rootFactors] <> retainedRoot, onePolynomial (length variables))
          Nothing -> case differenceOfSquaresFactors remainder of
            Just factors -> (linearFactors <> [(factor, 1) | factor <- factors], onePolynomial (length variables))
            Nothing -> (linearFactors, remainder)

perfectSquarePolynomial :: Polynomial -> Maybe Polynomial
perfectSquarePolynomial target = do
  (leadingPowers, leadingCoefficient) <- leadingTerm target
  if any odd leadingPowers then Nothing else do
    rootCoefficient <- squareRootGaussian leadingCoefficient
    let rootPowers = map (`div` 2) leadingPowers
        firstRoot = Polynomial (Map.singleton rootPowers rootCoefficient)
    buildSquareRoot rootPowers rootCoefficient firstRoot 0
 where
  buildSquareRoot :: [Int] -> Gaussian -> Polynomial -> Int -> Maybe Polynomial
  buildSquareRoot leadingRootPowers leadingRootCoefficient currentRoot steps
    | steps > 256 = Nothing
    | otherwise =
        let remainder = subtractPolynomial target (multiplyPolynomial currentRoot currentRoot)
         in case leadingTerm remainder of
              Nothing -> Just currentRoot
              Just (remainderPowers, remainderCoefficient)
                | and (zipWith (>=) remainderPowers leadingRootPowers) -> do
                    coefficient <-
                      divideGaussian
                        remainderCoefficient
                        (multiplyGaussian (Gaussian (Exact 2 1) zeroExact) leadingRootCoefficient)
                    let powers = zipWith (-) remainderPowers leadingRootPowers
                        nextRoot = addPolynomial currentRoot (Polynomial (Map.singleton powers coefficient))
                    buildSquareRoot leadingRootPowers leadingRootCoefficient nextRoot (steps + 1)
                | otherwise -> Nothing

differenceOfSquaresFactors :: Polynomial -> Maybe [Polynomial]
differenceOfSquaresFactors (Polynomial terms) = case Map.toList terms of
  [(leftPowers, leftCoefficient), (rightPowers, rightCoefficient)] ->
    chooseDifference (leftPowers, leftCoefficient) (rightPowers, rightCoefficient)
      `orElse` chooseDifference (rightPowers, rightCoefficient) (leftPowers, leftCoefficient)
  _ -> Nothing
 where
  chooseDifference (positivePowers, positiveCoefficient) (negativePowers, negativeCoefficient) = do
    positiveRoot <- monomialSquareRoot positivePowers positiveCoefficient
    negativeRoot <- monomialSquareRoot negativePowers (negateGaussian negativeCoefficient)
    let dimensions = length positivePowers
        positivePolynomial = uncurry (monomialPolynomial dimensions) positiveRoot
        negativePolynomial = uncurry (monomialPolynomial dimensions) negativeRoot
    pure
      [ subtractPolynomial positivePolynomial negativePolynomial
      , addPolynomial positivePolynomial negativePolynomial
      ]
  monomialSquareRoot powers coefficient
    | any odd powers = Nothing
    | otherwise = do
        coefficientRoot <- squareRootGaussian coefficient
        pure (map (`div` 2) powers, coefficientRoot)
  monomialPolynomial dimensions powers coefficient =
    if coefficient == zeroGaussian
      then zeroPolynomial dimensions
      else Polynomial (Map.singleton powers coefficient)

squareRootGaussian :: Gaussian -> Maybe Gaussian
squareRootGaussian (Gaussian (Exact numerator denominator) imaginary)
  | imaginary /= zeroExact = Nothing
  | numerator >= 0 = do
      numeratorRoot <- exactIntegerSquareRoot numerator
      denominatorRoot <- exactIntegerSquareRoot denominator
      pure (Gaussian (Exact numeratorRoot denominatorRoot) zeroExact)
  | otherwise = Nothing

exactIntegerSquareRoot :: Integer -> Maybe Integer
exactIntegerSquareRoot value
  | value < 0 = Nothing
  | otherwise =
      let squareRootValue = integerSquareRoot value
       in if squareRootValue * squareRootValue == value then Just squareRootValue else Nothing

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
    (coefficientEntry : monomialEntries <> factorEntries <> remainderEntries)
 where
  coefficientEntry = Call (Symbol "List") [gaussianToExpr content, Integer 1]
  monomialEntries = reverse
    [ Call (Symbol "List") [variable, Integer (fromIntegral power)]
    | (variable, power) <- zip variables powers
    , power > 0
    ]
  factorEntries =
    sortBy
      (\left right -> compare (fullForm left) (fullForm right))
      [ Call
          (Symbol "List")
          [polynomialToExpr compareExpression variables factor, Integer (fromIntegral multiplicity)]
      | (factor, multiplicity) <- factors
      ]
  remainderEntries
    | isOnePolynomial remainder = []
    | otherwise =
        [Call (Symbol "List") [polynomialToExpr compareExpression variables remainder, Integer 1]]

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
  | Integer 0 `elem` flattened = Integer 0
  | otherwise = case sortBy compareExpression (filter (/= Integer 1) flattened) of
      [] -> Integer 1
      [single] -> single
      sorted -> Call (Symbol "Times") sorted
 where
  flattened = concatMap flattenTimes values
  flattenTimes (Call (Symbol headName) factors)
    | systemHeadIn "Times" headName = concatMap flattenTimes factors
  flattenTimes value = [value]

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
