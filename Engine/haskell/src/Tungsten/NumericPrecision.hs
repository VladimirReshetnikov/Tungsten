{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Arbitrary-precision numeric conversion for the kernel-free evaluator.
--
-- The constructive-real representation is deliberately private.  Consumers
-- receive ordinary 'Expr' values whose real components use Wolfram-compatible
-- source text, so no approximation type becomes part of Tungsten's public
-- expression model.
module Tungsten.NumericPrecision
  ( approximateInexactNumericCall
  , exactNumericCallReduction
  , numericizeExpression
  , reduceNumericPrecisionBuiltin
  ) where

import qualified Data.Complex as Complex
import Data.Char (isDigit)
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Number.CReal (CReal, showCReal)
import Data.Ratio (denominator, numerator, (%))
import Data.Text (Text)
import qualified Data.Text as T
import Text.Read (readMaybe)
import Tungsten.Expression
import Tungsten.SystemSymbols
  ( isSystemSymbol
  , normalizeSystemSymbolName
  )

-- Keep requested allocations bounded by an 'Int'.  The bound is intentionally
-- generous for an interactive expression engine while preventing a malformed
-- precision literal from overflowing Text and constructive-real APIs.
maximumNumericDigits :: Integer
maximumNumericDigits = 100000

data NumericTarget
  = MachineTarget
  | DecimalTarget !Int
  deriving (Eq, Show)

data StoredRealKind
  = StoredMachineReal
  | StoredPrecisionReal !Integer
  | StoredAccuracyReal !Integer
  deriving (Eq, Show)

data StoredReal = StoredReal
  { storedValue :: !Rational
  , storedKind :: !StoredRealKind
  , storedScale :: !Int
  , storedNegativeZero :: !Bool
  , storedMachineSource :: !Text
  }
  deriving (Eq, Show)

-- Both projections are retained: CReal supplies arbitrary digits, while the
-- Double projection gives Python-compatible machine results and cheap domain
-- classification without comparing constructive reals.
data Approximation = Approximation
  { constructiveValue :: !(Complex.Complex CReal)
  , machineValue :: !(Complex.Complex Double)
  , approximationIsReal :: !Bool
  , approximationRealIsZero :: !Bool
  , approximationImaginaryIsZero :: !Bool
  }

-- | Handle the three precision built-ins.  'Nothing' means that the supplied
-- head belongs to another reducer; recognized heads always return 'Just',
-- including diagnostic-free raw recovery for unsupported argument shapes.
reduceNumericPrecisionBuiltin :: Text -> [Expr] -> Maybe Expr
reduceNumericPrecisionBuiltin headName values = case headName of
  "N" -> Just (reduceN values)
  "SetPrecision" -> Just (reduceSetPrecision values)
  "SetAccuracy" -> Just (reduceSetAccuracy values)
  _ -> Nothing

reduceN :: [Expr] -> Expr
reduceN [] = Call (Symbol "N") []
reduceN values@(subject : tailValues) =
  case splitNArguments tailValues of
    Nothing -> Call (Symbol "N") values
    Just (precisionExpression, options) ->
      let positional = precisionExpression >>= nPrecisionArgument
          optionPrecision = nOptionPrecision options
          precision = maximumMaybe positional optionPrecision
       in if maybe False (> maximumNumericDigits) precision
            then Call (Symbol "N") values
            else numericizeExpression precision subject

splitNArguments :: [Expr] -> Maybe (Maybe Expr, [Expr])
splitNArguments values =
  let (precisionExpression, options) = case values of
        first : rest
          | optionRuleParts first == Nothing -> (Just first, rest)
        _ -> (Nothing, values)
   in if all ((/= Nothing) . optionRuleParts) options
        then Just (precisionExpression, options)
        else Nothing

nPrecisionArgument :: Expr -> Maybe Integer
nPrecisionArgument = \case
  Symbol name
    | systemSymbolIs "MachinePrecision" name -> Nothing
  Integer value -> Just (max 1 value)
  Real source -> do
    info <- parseStoredReal source
    Just (max 1 (truncateRational (storedValue info)))
  _ -> Nothing

nOptionPrecision :: [Expr] -> Maybe Integer
nOptionPrecision = foldl retainMaximum Nothing
 where
  retainMaximum retained option = case optionRuleParts option of
    Just (name, Symbol automatic)
      | name `elem` numericPrecisionOptionNames
      , systemSymbolIs "Automatic" automatic -> retained
    Just (name, value)
      | name `elem` numericPrecisionOptionNames ->
          maximumMaybe retained (nPrecisionArgument value)
    _ -> retained

numericPrecisionOptionNames :: [Text]
numericPrecisionOptionNames = ["WorkingPrecision", "AccuracyGoal", "PrecisionGoal"]

maximumMaybe :: Ord value => Maybe value -> Maybe value -> Maybe value
maximumMaybe Nothing right = right
maximumMaybe left Nothing = left
maximumMaybe (Just left) (Just right) = Just (max left right)

optionRuleParts :: Expr -> Maybe (Text, Expr)
optionRuleParts (Call (Symbol ruleHead) [Symbol name, value])
  | systemSymbolIs "Rule" ruleHead || systemSymbolIs "RuleDelayed" ruleHead =
      Just (name, value)
optionRuleParts _ = Nothing

data PrecisionLike
  = PrecisionMachine
  | PrecisionInfinity
  | PrecisionFinite !Integer
  | PrecisionUnsupported
  deriving (Eq, Show)

precisionLikeArgument :: Expr -> PrecisionLike
precisionLikeArgument = \case
  Symbol name
    | systemSymbolIs "MachinePrecision" name -> PrecisionMachine
    | systemSymbolIs "Infinity" name -> PrecisionInfinity
  Integer value -> PrecisionFinite (max 0 value)
  Real source -> case parseStoredReal source of
    Just info -> PrecisionFinite (max 0 (truncateRational (storedValue info)))
    Nothing -> PrecisionUnsupported
  _ -> PrecisionUnsupported

reduceSetPrecision :: [Expr] -> Expr
reduceSetPrecision [subject, precisionExpression] =
  case precisionLikeArgument precisionExpression of
    PrecisionUnsupported -> Call (Symbol "SetPrecision") [subject, precisionExpression]
    PrecisionMachine -> numericizeExpression Nothing subject
    PrecisionInfinity -> exactifyReals subject
    PrecisionFinite precision
      | precision > maximumNumericDigits ->
          Call (Symbol "SetPrecision") [subject, precisionExpression]
    PrecisionFinite precision -> setFinitePrecision precision subject
reduceSetPrecision values = Call (Symbol "SetPrecision") values

reduceSetAccuracy :: [Expr] -> Expr
reduceSetAccuracy [subject, accuracyExpression] =
  case precisionLikeArgument accuracyExpression of
    PrecisionUnsupported -> Call (Symbol "SetAccuracy") [subject, accuracyExpression]
    PrecisionMachine -> numericizeExpression Nothing subject
    PrecisionInfinity -> exactifyReals subject
    PrecisionFinite accuracy
      | accuracy > maximumNumericDigits ->
          Call (Symbol "SetAccuracy") [subject, accuracyExpression]
    PrecisionFinite accuracy -> setFiniteAccuracy accuracy subject
reduceSetAccuracy values = Call (Symbol "SetAccuracy") values

setFinitePrecision :: Integer -> Expr -> Expr
setFinitePrecision requested expression = case expression of
  Integer value -> exactRealAtPrecision (value % 1) precision
  Rational value denominatorValue ->
    exactRealAtPrecision (value % denominatorValue) precision
  Real source -> case parseStoredReal source of
    Just info ->
      Real
        ( formatStoredFixed info
            <> "`" <> decimalInteger precision <> "."
        )
    Nothing -> expression
  Complex realPart imaginaryPart ->
    makeNumericComplex
      (setFinitePrecision requested realPart)
      (setFinitePrecision requested imaginaryPart)
  Call expressionHead values ->
    Call expressionHead (map (setFinitePrecision requested) values)
  _ -> expression
 where
  precision = max 1 requested

setFiniteAccuracy :: Integer -> Expr -> Expr
setFiniteAccuracy requested expression = case expression of
  Integer value -> exactRealAtAccuracy (value % 1) accuracy
  Rational value denominatorValue ->
    exactRealAtAccuracy (value % denominatorValue) accuracy
  Real source -> case parseStoredReal source of
    Just info ->
      Real
        ( formatStoredFixed info
            <> "``" <> decimalInteger accuracy <> "."
        )
    Nothing -> expression
  Complex realPart imaginaryPart ->
    makeNumericComplex
      (setFiniteAccuracy requested realPart)
      (setFiniteAccuracy requested imaginaryPart)
  Call expressionHead values ->
    Call expressionHead (map (setFiniteAccuracy requested) values)
  _ -> expression
 where
  accuracy = max 0 requested

exactifyReals :: Expr -> Expr
exactifyReals expression = case expression of
  Real source -> case parseStoredReal source of
    Just info -> rationalExpression (storedValue info)
    Nothing -> expression
  Complex realPart imaginaryPart ->
    makeNumericComplex (exactifyReals realPart) (exactifyReals imaginaryPart)
  Call expressionHead values -> Call expressionHead (map exactifyReals values)
  _ -> expression

-- | Recursively apply the Python compatibility numeric bridge.  'Nothing'
-- denotes MachinePrecision; finite requests are decimal significant digits.
numericizeExpression :: Maybe Integer -> Expr -> Expr
numericizeExpression requested expression =
  case targetFromRequest requested of
    Nothing -> expression
    Just target -> numericize target expression

targetFromRequest :: Maybe Integer -> Maybe NumericTarget
targetFromRequest Nothing = Just MachineTarget
targetFromRequest (Just requested)
  | requested > maximumNumericDigits = Nothing
  | otherwise = Just (DecimalTarget (fromInteger (max 1 requested)))

numericize :: NumericTarget -> Expr -> Expr
numericize target expression
  | Just simplified <- exactNumericReduction expression
  , simplified /= expression = numericize target simplified
numericize target expression = case expression of
  Integer value -> exactRealForTarget target (value % 1)
  Rational value denominatorValue ->
    exactRealForTarget target (value % denominatorValue)
  Complex realPart imaginaryPart ->
    makeNumericComplex
      (numericize target realPart)
      (numericize target imaginaryPart)
  rootValue@Root {} -> maybe rootValue id (approximateExpression target rootValue)
  Symbol name -> case constantApproximation (targetDigits target) name of
    Just approximation -> approximationExpression target approximation
    Nothing -> expression
  Real {} -> expression
  SpecialReal {} -> expression
  String {} -> expression
  ByteArray {} -> expression
  SparseArray {} -> expression
  Call expressionHead values ->
    let effectiveTarget = case inexactCallTarget expression of
          Just inherited -> inherited
          Nothing -> target
     in case approximateExpression effectiveTarget expression of
          Just approximated -> approximated
          Nothing ->
            let numericized = Call expressionHead (map (numericize target) values)
             in case approximateExpression effectiveTarget numericized of
                  Just approximated -> approximated
                  Nothing -> numericized

-- | Evaluate one supported numeric call only when an inexact argument makes
-- Python's ordinary transcendental reducer numeric.  This is the reusable
-- entry point for the broader transcendental family.
approximateInexactNumericCall :: Text -> [Expr] -> Maybe Expr
approximateInexactNumericCall headName values = do
  let expression = Call (Symbol headName) values
  target <- inexactCallTarget expression
  approximateExpression target expression

inexactCallTarget :: Expr -> Maybe NumericTarget
inexactCallTarget (Call (Symbol headName) values)
  | maybe False (`elem` transcendentalHeadNames) (numericCallHeadName headName)
  , any containsInexactReal values =
      Just (combinedInexactTarget values)
  | otherwise = Nothing
inexactCallTarget _ = Nothing

containsInexactReal :: Expr -> Bool
containsInexactReal = \case
  Real {} -> True
  SpecialReal {} -> True
  Complex realPart imaginaryPart ->
    containsInexactReal realPart || containsInexactReal imaginaryPart
  Call _ values -> any containsInexactReal values
  _ -> False

combinedInexactTarget :: [Expr] -> NumericTarget
combinedInexactTarget values =
  case traverse immediateInexactDigits values of
    Nothing -> MachineTarget
    Just candidates -> case [digits | Just digits <- candidates] of
      [] -> MachineTarget
      explicit -> DecimalTarget (minimum explicit)

-- 'Nothing' is a machine/special boundary; 'Just Nothing' is exact or a call
-- ignored by Python's immediate-argument precision combiner.
immediateInexactDigits :: Expr -> Maybe (Maybe Int)
immediateInexactDigits = \case
  SpecialReal {} -> Nothing
  Real source -> do
    info <- parseStoredReal source
    case storedKind info of
      StoredMachineReal -> Nothing
      StoredPrecisionReal precision ->
        Just (Just (boundedPositiveDigits precision))
      StoredAccuracyReal accuracy ->
        let effective = accuracy + decimalMagnitudeForPrecision info
         in Just (Just (boundedPositiveDigits effective))
  Complex realPart imaginaryPart -> do
    left <- immediateInexactDigits realPart
    right <- immediateInexactDigits imaginaryPart
    Just (minimumOptional left right)
  _ -> Just Nothing

minimumOptional :: Ord value => Maybe value -> Maybe value -> Maybe value
minimumOptional Nothing right = right
minimumOptional left Nothing = left
minimumOptional (Just left) (Just right) = Just (min left right)

boundedPositiveDigits :: Integer -> Int
boundedPositiveDigits value =
  fromInteger (min maximumNumericDigits (max 1 value))

decimalMagnitudeForPrecision :: StoredReal -> Integer
decimalMagnitudeForPrecision info
  | storedValue info == 0 = 0
  | otherwise = toInteger (decimalExponent (storedValue info))

targetDigits :: NumericTarget -> Int
targetDigits MachineTarget = 20
targetDigits (DecimalTarget digits) = digits

exactRealForTarget :: NumericTarget -> Rational -> Expr
exactRealForTarget MachineTarget value = machineRealExpression (fromRational value)
exactRealForTarget (DecimalTarget digits) value = exactRealAtPrecision value (toInteger digits)

exactRealAtPrecision :: Rational -> Integer -> Expr
exactRealAtPrecision value requested =
  case boundedFormatDigits requested of
    Nothing -> rationalExpression value
    Just digits ->
      Real (formatExactSignificant False digits value <> precisionMarker digits)

exactRealAtAccuracy :: Rational -> Integer -> Expr
exactRealAtAccuracy value requested =
  case boundedNonnegativeInt (max requested 0) of
    Nothing -> rationalExpression value
    Just accuracy ->
      let contextDigits = max 16 (accuracy + 8)
       in Real
            ( formatExactSignificant False contextDigits value
                <> "``" <> decimalInt accuracy <> "."
            )

boundedFormatDigits :: Integer -> Maybe Int
boundedFormatDigits requested
  | requested > maximumNumericDigits = Nothing
  | otherwise = Just (fromInteger (max 1 requested))

boundedNonnegativeInt :: Integer -> Maybe Int
boundedNonnegativeInt requested
  | requested > maximumNumericDigits = Nothing
  | otherwise = Just (fromInteger (max 0 requested))

precisionMarker :: Int -> Text
precisionMarker digits = "`" <> decimalInt digits <> "."

approximateExpression :: NumericTarget -> Expr -> Maybe Expr
approximateExpression target expression = do
  approximation <- expressionApproximation (targetDigits target) expression
  pure (approximationExpression target approximation)

approximationExpression :: NumericTarget -> Approximation -> Expr
approximationExpression MachineTarget approximation =
  let classifiedReal = Complex.realPart (machineValue approximation)
      classifiedImaginary = Complex.imagPart (machineValue approximation)
      realValue =
        constructiveMachineValue
          (approximationRealIsZero approximation)
          (Complex.realPart (constructiveValue approximation))
          classifiedReal
      imaginaryValue =
        constructiveMachineValue
          (approximationImaginaryIsZero approximation)
          (Complex.imagPart (constructiveValue approximation))
          classifiedImaginary
   in if isNaN classifiedReal || isNaN classifiedImaginary
        then Symbol "Indeterminate"
        else
          if approximationIsReal approximation
            then machineRealExpression (preserveNonFinite classifiedReal realValue)
            else
              if isInfinite classifiedReal || isInfinite classifiedImaginary
                then Symbol "ComplexInfinity"
                else
                  makeNumericComplex
                    (machineRealExpression realValue)
                    (machineRealExpression imaginaryValue)
approximationExpression (DecimalTarget digits) approximation =
  let realMachine = Complex.realPart (machineValue approximation)
      imaginaryMachine = Complex.imagPart (machineValue approximation)
      realConstructive = Complex.realPart (constructiveValue approximation)
      imaginaryConstructive = Complex.imagPart (constructiveValue approximation)
   in if isNaN realMachine || isNaN imaginaryMachine
        then Symbol "Indeterminate"
        else
          let realExpression =
                approximateRealExpression
                  digits
                  (approximationRealIsZero approximation)
                  realConstructive
                  realMachine
           in if approximationIsReal approximation
                then realExpression
                else
                  makeNumericComplex
                    realExpression
                    ( approximateRealExpression
                        digits
                        (approximationImaginaryIsZero approximation)
                        imaginaryConstructive
                        imaginaryMachine
                    )

approximateRealExpression :: Int -> Bool -> CReal -> Double -> Expr
approximateRealExpression digits knownZero constructive machine =
  Real
    ( formatConstructiveSignificant digits knownZero constructive machine
        <> precisionMarker digits
    )

-- GHC's host libm and SymPy occasionally choose adjacent binary64 values for
-- elementary functions (for example, Sin[1.2]).  Python's bridge computes at
-- decimal working precision and only then projects to a machine real.  Do the
-- same from the independent constructive value; 25 significant decimal digits
-- are comfortably sufficient to select the nearest binary64 value.  The
-- ordinary Double projection remains authoritative for domain and overflow
-- classification, so a divergent constructive operation is never forced for
-- a non-finite result.
constructiveMachineValue :: Bool -> CReal -> Double -> Double
constructiveMachineValue knownZero constructive classified
  | isNaN classified || isInfinite classified = classified
  | otherwise =
      case readMaybe
        ( T.unpack
            ( normalizeDoubleMantissa
                (formatConstructiveSignificant 25 knownZero constructive classified)
            )
        ) of
        Just projected -> projected
        Nothing -> classified

preserveNonFinite :: Double -> Double -> Double
preserveNonFinite classified projected
  | isNaN classified || isInfinite classified = classified
  | otherwise = projected

expressionApproximation :: Int -> Expr -> Maybe Approximation
expressionApproximation digits = \case
  Integer value ->
    Just (realApproximation (value == 0) (fromInteger value) (fromInteger value))
  Rational value denominatorValue ->
    let exactValue = value % denominatorValue
     in Just
          ( realApproximation
              (value == 0)
              (fromRational exactValue)
              (fromRational exactValue)
          )
  Real source -> do
    info <- parseStoredReal source
    machine <- readMaybe (T.unpack (storedMachineSource info))
    Just
      ( realApproximation
          (storedValue info == 0)
          (fromRational (storedValue info))
          machine
      )
  Complex realPart imaginaryPart -> do
    realApproximationValue <- expressionApproximation digits realPart
    imaginaryApproximationValue <- expressionApproximation digits imaginaryPart
    if approximationIsReal realApproximationValue
        && approximationIsReal imaginaryApproximationValue
      then
        let realC = Complex.realPart (constructiveValue realApproximationValue)
            imaginaryC = Complex.realPart (constructiveValue imaginaryApproximationValue)
            realD = Complex.realPart (machineValue realApproximationValue)
            imaginaryD = Complex.realPart (machineValue imaginaryApproximationValue)
         in Just
              ( Approximation
                  (realC Complex.:+ imaginaryC)
                  (realD Complex.:+ imaginaryD)
                  (numericComponentIsZero imaginaryPart)
                  (approximationRealIsZero realApproximationValue)
                  (approximationRealIsZero imaginaryApproximationValue)
              )
      else Nothing
  rootValue@Root {} -> rootApproximation digits rootValue
  Symbol name -> constantApproximation digits name
  Call (Symbol headName) values -> do
    dispatch <- numericCallHeadName headName
    callApproximation digits dispatch values
  _ -> Nothing

realApproximation :: Bool -> CReal -> Double -> Approximation
realApproximation knownZero constructive machine =
  Approximation
    (constructive Complex.:+ 0)
    (machine Complex.:+ 0)
    True
    knownZero
    True

constantApproximation :: Int -> Text -> Maybe Approximation
constantApproximation digits name = do
  dispatch <- numericCallHeadName name
  case dispatch of
    "Pi" -> Just (realApproximation False pi pi)
    "E" -> Just (realApproximation False (exp 1) (exp 1))
    "EulerGamma" -> do
      value <- eulerGammaConstant digits
      Just (realApproximation False value 0.5772156649015329)
    "GoldenRatio" ->
      Just (realApproximation False ((1 + sqrt 5) / 2) ((1 + sqrt 5) / 2))
    "Catalan" -> do
      value <- catalanConstant digits
      Just (realApproximation False value 0.915965594177219)
    "Degree" -> Just (realApproximation False (pi / 180) (pi / 180))
    "I" ->
      Just
        ( Approximation
            (0 Complex.:+ 1)
            (0 Complex.:+ 1)
            False
            True
            False
        )
    _ -> Nothing

numericCallHeadName :: Text -> Maybe Text
numericCallHeadName name
  | isSystemSymbol name = normalizeSystemSymbolName name
  | T.any (== '`') name = Nothing
  | otherwise = Just name

systemSymbolIs :: Text -> Text -> Bool
systemSymbolIs expected actual = numericCallHeadName actual == Just expected

callApproximation :: Int -> Text -> [Expr] -> Maybe Approximation
callApproximation digits headName values = case (headName, values) of
  ("Plus", _) ->
    foldApproximation digits addApproximation (realApproximation True 0 0) values
  ("Times", _) ->
    foldApproximation digits multiplyApproximation (realApproximation False 1 1) values
  ("Power", [Symbol baseName, Integer exponentValue])
    | systemSymbolIs "E" baseName ->
        Just
          ( realApproximation
              False
              (exp (fromInteger exponentValue))
              (exp (fromInteger exponentValue))
          )
  ("Power", [base, exponentExpression]) -> do
    baseValue <- expressionApproximation digits base
    exponentValue <- expressionApproximation digits exponentExpression
    Just (powerApproximation exponentExpression baseValue exponentValue)
  ("Sqrt", [value]) -> do
    approximation <- expressionApproximation digits value
    Just (unaryApproximation "Sqrt" approximation)
  ("Abs", [value]) -> do
    approximation <- expressionApproximation digits value
    Just (absoluteApproximation approximation)
  ("Root", rootArguments) -> rootCallApproximation digits rootArguments
  ("Exp", [value]) -> unaryCall "Exp" value
  ("Log", [value])
    | numericComponentIsNegativeOne value ->
        Just
          ( Approximation
              (0 Complex.:+ pi)
              (0 Complex.:+ pi)
              False
              True
              False
          )
  ("Log", [value]) -> unaryCall "Log" value
  ("Log", [base, value]) -> do
    baseApproximation <- expressionApproximation digits base
    valueApproximation <- expressionApproximation digits value
    Just
      ( divideApproximation
          (unaryApproximation "Log" valueApproximation)
          (unaryApproximation "Log" baseApproximation)
      )
  ("ArcCoth", [value])
    | numericComponentIsZero value ->
        Just
          ( Approximation
              (0 Complex.:+ pi / 2)
              (0 Complex.:+ pi / 2)
              False
              True
              False
          )
  ("ArcTan", [x, y]) -> do
    xValue <- expressionApproximation digits x
    yValue <- expressionApproximation digits y
    if approximationIsReal xValue && approximationIsReal yValue
      then
        let xC = Complex.realPart (constructiveValue xValue)
            yC = Complex.realPart (constructiveValue yValue)
            xD = Complex.realPart (machineValue xValue)
            yD = Complex.realPart (machineValue yValue)
         in Just (realApproximation False (atan2 yC xC) (atan2 yD xD))
      else Nothing
  (_, [value])
    | headName `elem` unaryTranscendentalHeadNames -> unaryCall headName value
  _ -> Nothing
 where
  unaryCall name value = unaryApproximation name <$> expressionApproximation digits value

foldApproximation
  :: Int
  -> (Approximation -> Approximation -> Approximation)
  -> Approximation
  -> [Expr]
  -> Maybe Approximation
foldApproximation digits operation initial values = do
  approximations <- traverse (expressionApproximation digits) values
  Just (foldl operation initial approximations)

addApproximation :: Approximation -> Approximation -> Approximation
addApproximation left right =
  approximationFromValues
    (approximationIsReal left && approximationIsReal right)
    (approximationRealIsZero left && approximationRealIsZero right)
    (approximationImaginaryIsZero left && approximationImaginaryIsZero right)
    (constructiveValue left + constructiveValue right)
    (machineValue left + machineValue right)

multiplyApproximation :: Approximation -> Approximation -> Approximation
multiplyApproximation left right =
  approximationFromValues
    (approximationIsReal left && approximationIsReal right)
    ( productIsZero
        (approximationRealIsZero left)
        (approximationRealIsZero right)
        && productIsZero
          (approximationImaginaryIsZero left)
          (approximationImaginaryIsZero right)
    )
    ( productIsZero
        (approximationRealIsZero left)
        (approximationImaginaryIsZero right)
        && productIsZero
          (approximationImaginaryIsZero left)
          (approximationRealIsZero right)
    )
    (constructiveValue left * constructiveValue right)
    (machineValue left * machineValue right)

divideApproximation :: Approximation -> Approximation -> Approximation
divideApproximation left right =
  approximationFromValues
    (approximationIsReal left && approximationIsReal right)
    ( productIsZero
        (approximationRealIsZero left)
        (approximationRealIsZero right)
        && productIsZero
          (approximationImaginaryIsZero left)
          (approximationImaginaryIsZero right)
    )
    ( productIsZero
        (approximationImaginaryIsZero left)
        (approximationRealIsZero right)
        && productIsZero
          (approximationRealIsZero left)
          (approximationImaginaryIsZero right)
    )
    (divideComplex (constructiveValue left) (constructiveValue right))
    (machineValue left / machineValue right)

productIsZero :: Bool -> Bool -> Bool
productIsZero leftIsZero rightIsZero = leftIsZero || rightIsZero

powerApproximation :: Expr -> Approximation -> Approximation -> Approximation
powerApproximation exponentExpression baseValue exponentValue =
  case exponentExpression of
    Integer powerValue
      | approximationIsReal baseValue ->
          let constructiveBase = Complex.realPart (constructiveValue baseValue)
              machineBase = Complex.realPart (machineValue baseValue)
              baseIsZero = approximationRealIsZero baseValue
              resultIsZero = powerValue > 0 && baseIsZero
           in realApproximation
                resultIsZero
                (realIntegerPower constructiveBase powerValue)
                (realIntegerPower machineBase powerValue)
    Integer powerValue ->
      let baseIsZero =
            approximationRealIsZero baseValue
              && approximationImaginaryIsZero baseValue
          resultRealIsZero = powerValue > 0 && baseIsZero
          resultImaginaryIsZero = approximationIsReal baseValue || baseIsZero
       in approximationFromValues
            (approximationIsReal baseValue)
            resultRealIsZero
            resultImaginaryIsZero
            (integerComplexPower (constructiveValue baseValue) powerValue)
            (integerComplexPower (machineValue baseValue) powerValue)
    _
      | approximationIsReal baseValue
      , Complex.realPart (machineValue baseValue) > 0 ->
          positiveRealComplexPower baseValue exponentValue
    _ ->
      let resultIsReal =
            approximationIsReal baseValue
              && approximationIsReal exponentValue
              && Complex.realPart (machineValue baseValue) >= 0
       in approximationFromValues
            resultIsReal
            False
            resultIsReal
            (constructiveValue baseValue ** constructiveValue exponentValue)
            (machineValue baseValue ** machineValue exponentValue)

realIntegerPower :: (Fractional value) => value -> Integer -> value
realIntegerPower value powerValue
  | powerValue < 0 = recip (value ^ negate powerValue)
  | otherwise = value ^ powerValue

positiveRealComplexPower :: Approximation -> Approximation -> Approximation
positiveRealComplexPower baseValue exponentValue =
  Approximation
    (constructiveResult constructiveBase (constructiveValue exponentValue))
    (machineResult machineBase (machineValue exponentValue))
    (approximationIsReal exponentValue)
    False
    (approximationImaginaryIsZero exponentValue)
 where
  constructiveBase = Complex.realPart (constructiveValue baseValue)
  machineBase = Complex.realPart (machineValue baseValue)
  constructiveResult base exponentValue' =
    let logarithm = log base
        realExponent = Complex.realPart exponentValue'
        imaginaryExponent = Complex.imagPart exponentValue'
        scale = exp (realExponent * logarithm)
        angle = imaginaryExponent * logarithm
     in (scale * cos angle) Complex.:+ (scale * sin angle)
  machineResult base exponentValue' =
    let logarithm = log base
        realExponent = Complex.realPart exponentValue'
        imaginaryExponent = Complex.imagPart exponentValue'
        scale = exp (realExponent * logarithm)
        angle = imaginaryExponent * logarithm
     in (scale * cos angle) Complex.:+ (scale * sin angle)

integerComplexPower :: (RealFloat value) => Complex.Complex value -> Integer -> Complex.Complex value
integerComplexPower value powerValue
  | powerValue < 0 = recip (value ^ negate powerValue)
  | otherwise = value ^ powerValue

absoluteApproximation :: Approximation -> Approximation
absoluteApproximation approximation =
  let constructive = constructiveValue approximation
      machine = machineValue approximation
      constructiveMagnitude =
        sqrt
          ( Complex.realPart constructive * Complex.realPart constructive
              + Complex.imagPart constructive * Complex.imagPart constructive
          )
      machineMagnitude = Complex.magnitude machine
   in realApproximation
        ( approximationRealIsZero approximation
            && approximationImaginaryIsZero approximation
        )
        constructiveMagnitude
        machineMagnitude

unaryApproximation :: Text -> Approximation -> Approximation
unaryApproximation headName approximation =
  case realUnaryApproximation headName approximation of
    Just result -> result
    Nothing ->
      let (realIsZero, imaginaryIsZero) =
            complexUnaryKnownZeros headName approximation
       in approximationFromValues
            False
            realIsZero
            imaginaryIsZero
            (applyUnaryTranscendental headName (approximationIsReal approximation) (constructiveValue approximation))
            (applyUnaryTranscendental headName (approximationIsReal approximation) (machineValue approximation))

complexUnaryKnownZeros :: Text -> Approximation -> (Bool, Bool)
complexUnaryKnownZeros headName approximation =
  case baseName of
    "Exp" -> (False, imaginaryIsZero)
    name
      | name `elem` oddComplexFunctionNames -> (realIsZero, imaginaryIsZero)
    name
      | name `elem` evenComplexFunctionNames ->
          (False, realIsZero || imaginaryIsZero)
    "Haversine" -> (realIsZero && imaginaryIsZero, realIsZero || imaginaryIsZero)
    _ -> (False, False)
 where
  baseName = maybe headName id (degreeBaseName headName)
  realIsZero = approximationRealIsZero approximation
  imaginaryIsZero = approximationImaginaryIsZero approximation
  oddComplexFunctionNames =
    [ "Sin", "Tan", "Cot", "Csc"
    , "Sinh", "Tanh", "Coth", "Csch"
    , "ArcSin", "ArcTan", "ArcSinh", "ArcTanh", "ArcCsch"
    , "Gudermannian", "InverseGudermannian", "InverseHaversine"
    ]
  evenComplexFunctionNames = ["Cos", "Sec", "Cosh", "Sech"]

realUnaryApproximation :: Text -> Approximation -> Maybe Approximation
realUnaryApproximation headName approximation
  | not (approximationIsReal approximation) = Nothing
  | otherwise = do
      let constructive = Complex.realPart (constructiveValue approximation)
          machine = Complex.realPart (machineValue approximation)
      constructiveResult <- applyRealUnaryTranscendental headName machine constructive
      machineResult <- applyRealUnaryTranscendental headName machine machine
      Just
        ( realApproximation
            (realUnaryResultIsZero headName approximation)
            constructiveResult
            machineResult
        )

realUnaryResultIsZero :: Text -> Approximation -> Bool
realUnaryResultIsZero headName approximation =
  approximationRealIsZero approximation
    && baseName
      `elem` [ "Sin", "Tan", "Sinh", "Tanh"
             , "ArcSin", "ArcTan", "ArcSinh", "ArcTanh"
             , "Haversine", "InverseHaversine"
             , "Gudermannian", "InverseGudermannian"
             ]
 where
  baseName = maybe headName id (degreeBaseName headName)

applyRealUnaryTranscendental
  :: Floating value
  => Text
  -> Double
  -> value
  -> Maybe value
applyRealUnaryTranscendental headName domainValue value =
  case degreeBaseName headName of
    Just base
      | "Arc" `T.isPrefixOf` base ->
          (/ (pi / 180)) <$> applyBase base value
      | otherwise -> applyBase base (value * (pi / 180))
    Nothing -> applyBase headName value
 where
  applyBase name argument = case name of
    "Sqrt" | domainValue >= 0 -> Just (sqrt argument)
    "Exp" -> Just (exp argument)
    "Log" | domainValue > 0 -> Just (log argument)
    "Sin" -> Just (sin argument)
    "Cos" -> Just (cos argument)
    "Tan" -> Just (tan argument)
    "Cot" | domainValue /= 0 -> Just (recip (tan argument))
    "Sec" -> Just (recip (cos argument))
    "Csc" | domainValue /= 0 -> Just (recip (sin argument))
    "ArcSin" | abs domainValue <= 1 -> Just (asin argument)
    "ArcCos" | abs domainValue <= 1 -> Just (acos argument)
    "ArcTan" -> Just (atan argument)
    "ArcCot" -> Just (pi / 2 - atan argument)
    "ArcSec" | abs domainValue >= 1 -> Just (acos (recip argument))
    "ArcCsc" | abs domainValue >= 1 -> Just (asin (recip argument))
    "Sinh" -> Just (sinh argument)
    "Cosh" -> Just (cosh argument)
    "Tanh" -> Just (tanh argument)
    "Coth" | domainValue /= 0 -> Just (recip (tanh argument))
    "Sech" -> Just (recip (cosh argument))
    "Csch" | domainValue /= 0 -> Just (recip (sinh argument))
    "ArcSinh" -> Just (asinh argument)
    "ArcCosh" | domainValue >= 1 -> Just (acosh argument)
    "ArcTanh" | abs domainValue < 1 -> Just (atanh argument)
    "ArcCoth" | abs domainValue > 1 -> Just (atanh (recip argument))
    "ArcSech" | domainValue > 0 && domainValue <= 1 -> Just (acosh (recip argument))
    "ArcCsch" | domainValue /= 0 -> Just (asinh (recip argument))
    "Haversine" -> Just ((1 - cos argument) / 2)
    "InverseHaversine" | domainValue >= 0 && domainValue <= 1 ->
      Just (2 * asin (sqrt argument))
    "Gudermannian" -> Just (2 * atan (tanh (argument / 2)))
    "InverseGudermannian" | abs domainValue < pi / 2 ->
      Just (log (tan (pi / 4 + argument / 2)))
    _ -> Nothing

approximationFromValues
  :: Bool
  -> Bool
  -> Bool
  -> Complex.Complex CReal
  -> Complex.Complex Double
  -> Approximation
approximationFromValues resultIsReal realIsZero imaginaryIsZero constructive machine =
  Approximation constructive machine resultIsReal realIsZero imaginaryIsZero

applyUnaryTranscendental
  :: RealFloat value
  => Text
  -> Bool
  -> Complex.Complex value
  -> Complex.Complex value
applyUnaryTranscendental headName argumentIsReal value =
  case degreeBaseName headName of
    Just base
      | "Arc" `T.isPrefixOf` base ->
          applyBase base value / (pi / 180)
      | otherwise -> applyBase base (value * (pi / 180))
    Nothing -> applyBase headName value
 where
  applyBase name argument = case name of
    "Sqrt" -> sqrt argument
    "Exp" -> exp argument
    "Log" -> log argument
    "Sin" -> sin argument
    "Cos" -> cos argument
    "Tan" -> tan argument
    "Cot" -> recip (tan argument)
    "Sec" -> recip (cos argument)
    "Csc" -> recip (sin argument)
    "ArcSin" -> asin argument
    "ArcCos" -> acos argument
    "ArcTan" -> atan argument
    "ArcCot"
      | argumentIsReal -> pi / 2 - atan argument
      | otherwise -> atan (recip argument)
    "ArcSec" -> acos (recip argument)
    "ArcCsc" -> asin (recip argument)
    "Sinh" -> sinh argument
    "Cosh" -> cosh argument
    "Tanh" -> tanh argument
    "Coth" -> recip (tanh argument)
    "Sech" -> recip (cosh argument)
    "Csch" -> recip (sinh argument)
    "ArcSinh" -> asinh argument
    "ArcCosh" -> acosh argument
    "ArcTanh" -> atanh argument
    "ArcCoth" -> atanh (recip argument)
    "ArcSech" -> acosh (recip argument)
    "ArcCsch" -> asinh (recip argument)
    "Haversine" -> (1 - cos argument) / 2
    "InverseHaversine" -> 2 * asin (sqrt argument)
    "Gudermannian" -> 2 * atan (tanh (argument / 2))
    "InverseGudermannian" -> log (tan (pi / 4 + argument / 2))
    _ -> argument

degreeBaseName :: Text -> Maybe Text
degreeBaseName name = do
  base <- T.stripSuffix "Degrees" name
  if base `elem` degreeTranscendentalBaseNames then Just base else Nothing

degreeTranscendentalBaseNames :: [Text]
degreeTranscendentalBaseNames =
  [ "Sin", "Cos", "Tan", "Cot", "Sec", "Csc"
  , "ArcSin", "ArcCos", "ArcTan", "ArcCot", "ArcSec", "ArcCsc"
  ]

unaryTranscendentalHeadNames :: [Text]
unaryTranscendentalHeadNames =
  [ "Sin", "Cos", "Tan", "Cot", "Sec", "Csc"
  , "ArcSin", "ArcCos", "ArcTan", "ArcCot", "ArcSec", "ArcCsc"
  , "Sinh", "Cosh", "Tanh", "Coth", "Sech", "Csch"
  , "ArcSinh", "ArcCosh", "ArcTanh", "ArcCoth", "ArcSech", "ArcCsch"
  , "Haversine", "InverseHaversine", "Gudermannian", "InverseGudermannian"
  ] <> map (<> "Degrees") degreeTranscendentalBaseNames

transcendentalHeadNames :: [Text]
transcendentalHeadNames = ["Exp", "Log", "ArcTan"] <> unaryTranscendentalHeadNames

-- | Exact and singular outcomes shared by ordinary evaluation and 'N'.
-- Keeping these ahead of constructive evaluation is also a termination
-- boundary: reciprocal functions at a proved zero must never force CReal's
-- non-terminating reciprocal search.
exactNumericCallReduction :: Text -> [Expr] -> Maybe Expr
exactNumericCallReduction headName values =
  exactNumericReduction (Call (Symbol headName) values)

exactNumericReduction :: Expr -> Maybe Expr
exactNumericReduction (Call (Symbol headName) values) = do
  dispatch <- numericCallHeadName headName
  case (dispatch, values) of
    ("Exp", [Integer 0]) -> Just (Integer 1)
    ("Exp", [Integer 1]) -> Just (Symbol "E")
    ("Exp", [Complex realPart imaginaryPart])
      | not (containsInexactReal realPart || containsInexactReal imaginaryPart) ->
          Just (exactComplexExponential realPart imaginaryPart)
    ("Exp", [value])
      | not (containsInexactReal value) ->
          Just (Call (Symbol "Power") [Symbol "E", value])
    ("Log", [Integer 1]) -> Just (Integer 0)
    ("Log", [Symbol name])
      | systemSymbolIs "E" name -> Just (Integer 1)
    ("Log", [value])
      | exactNegativeOne value ->
          Just
            ( Call
                (Symbol "Times")
                [Complex (Integer 0) (Integer 1), Symbol "Pi"]
            )
    ("Log", [value])
      | numericComponentIsZero value -> Just (Symbol "-Infinity")
    ("Log", [base, value])
      | numericComponentIsZero value -> Just (Symbol "-Infinity")
      | numericComponentIsOne base && numericComponentIsOne value ->
          Just (Symbol "Indeterminate")
      | numericComponentIsOne base -> Just (Symbol "ComplexInfinity")
      | exactOne value -> Just (Integer 0)
    ("ArcTan", [x, y])
      | numericComponentIsZero x && numericComponentIsZero y ->
          Just (Symbol "Indeterminate")
    (name, [value])
      | name `elem` ["ArcTanh", "ArcCoth"]
      , exactOne value -> Just (Symbol "Infinity")
    (name, [value])
      | name `elem` ["ArcTanh", "ArcCoth"]
      , exactNegativeOne value -> Just (Symbol "-Infinity")
    (name, [value])
      | name `elem` ["ArcTanh", "ArcCoth"]
      , numericComponentIsOne value || numericComponentIsNegativeOne value ->
          Just (Symbol "ComplexInfinity")
    (name, [value])
      | name `elem` ["Cot", "Csc", "Coth", "Csch", "ArcSec", "ArcCsc", "ArcCsch"]
      , numericComponentIsZero value -> Just (Symbol "ComplexInfinity")
    ("ArcCoth", [value])
      | exactZero value ->
          Just
            ( Call
                (Symbol "Times")
                [Complex (Integer 0) (Rational 1 2), Symbol "Pi"]
            )
    ("ArcSech", [value])
      | exactZero value -> Just (Symbol "Infinity")
      | numericComponentIsZero value -> Just (Symbol "ComplexInfinity")
    (name, [value])
      | name `elem` exactOddFunctionNames
      , Just exactValue <- asExactRational value
      , exactValue < 0 ->
          Just
            ( Call
                (Symbol "Times")
                [ Integer (-1)
                , Call (Symbol name) [rationalExpression (negate exactValue)]
                ]
            )
    (name, [value])
      | name `elem` exactEvenFunctionNames
      , Just exactValue <- asExactRational value
      , exactValue < 0 ->
          Just (Call (Symbol name) [rationalExpression (negate exactValue)])
    ("Sin", [value]) -> exactSin value
    ("Cos", [value]) -> exactCos value
    ("Tan", [value]) -> exactTan value
    ("Cot", [value]) -> exactReciprocalTrig exactTan value
    ("Sec", [value]) -> exactReciprocalTrig exactCos value
    ("Csc", [value]) -> exactReciprocalTrig exactSin value
    (name, [value])
      | name `elem` inverseCircularHeadNames -> exactInverseCircular name value
    (name, [value])
      | Just base <- degreeBaseName name -> exactDegreeFunction base value
    (name, [value])
      | name `elem` ["ArcSin", "ArcTan", "Sinh", "Tanh", "ArcSinh", "ArcTanh", "Gudermannian", "InverseGudermannian", "Haversine", "InverseHaversine"]
      , exactZero value -> Just (Integer 0)
    (name, [value])
      | name `elem` ["Cosh", "Sech"]
      , exactZero value -> Just (Integer 1)
    (name, [value])
      | name `elem` ["ArcCosh", "ArcSech"]
      , exactOne value -> Just (Integer 0)
    _ -> Nothing
exactNumericReduction _ = Nothing

exactOddFunctionNames :: [Text]
exactOddFunctionNames =
  [ "Sin", "Tan", "Cot", "Csc"
  , "Sinh", "Tanh", "Coth", "Csch"
  , "Gudermannian", "InverseGudermannian"
  ]

exactEvenFunctionNames :: [Text]
exactEvenFunctionNames = ["Cos", "Sec", "Cosh", "Sech", "Haversine"]

exactComplexExponential :: Expr -> Expr -> Expr
exactComplexExponential realPart imaginaryPart =
  Call
    (Symbol "Times")
    [ scale
    , Call
        (Symbol "Plus")
        [ Call (Symbol "Cos") [imaginaryPart]
        , Call
            (Symbol "Times")
            [ Complex (Integer 0) (Integer 1)
            , Call (Symbol "Sin") [imaginaryPart]
            ]
        ]
    ]
 where
  scale
    | exactZero realPart = Integer 1
    | exactOne realPart = Symbol "E"
    | otherwise = Call (Symbol "Power") [Symbol "E", realPart]

exactSin :: Expr -> Maybe Expr
exactSin value
  | exactZero value = Just (Integer 0)
  | otherwise = do
      multiple <- piMultiple value
      lookup (normalizePiMultiple multiple) sinExactTable

exactCos :: Expr -> Maybe Expr
exactCos value
  | exactZero value = Just (Integer 1)
  | otherwise = do
      multiple <- piMultiple value
      lookup (normalizePiMultiple multiple) cosExactTable

exactTan :: Expr -> Maybe Expr
exactTan value
  | exactZero value = Just (Integer 0)
  | otherwise = do
      multiple <- piMultiple value
      let normalized = normalizePiMultiple multiple
      if normalized `elem` [1 % 2, 3 % 2]
        then Just (Symbol "ComplexInfinity")
        else lookup normalized tanExactTable

exactReciprocalTrig :: (Expr -> Maybe Expr) -> Expr -> Maybe Expr
exactReciprocalTrig directFunction value = do
  direct <- directFunction value
  case direct of
    Symbol "ComplexInfinity" -> Just (Integer 0)
    _
      | exactExpressionZero direct -> Just (Symbol "ComplexInfinity")
      | otherwise -> Just (Call (Symbol "Power") [direct, Integer (-1)])

inverseCircularHeadNames :: [Text]
inverseCircularHeadNames = ["ArcSin", "ArcCos", "ArcTan", "ArcCot", "ArcSec", "ArcCsc"]

exactInverseCircular :: Text -> Expr -> Maybe Expr
exactInverseCircular headName value
  | exactNegativeOne value = lookup headName negativeOneValues
  | exactZero value = lookup headName zeroValues
  | exactOne value = lookup headName oneValues
  | otherwise = Nothing
 where
  negativeOneValues =
    [ ("ArcSin", piExpression ((-1) % 2))
    , ("ArcCos", Symbol "Pi")
    , ("ArcTan", piExpression ((-1) % 4))
    , ("ArcCot", piExpression (3 % 4))
    , ("ArcSec", Symbol "Pi")
    , ("ArcCsc", piExpression ((-1) % 2))
    ]
  zeroValues =
    [ ("ArcSin", Integer 0)
    , ("ArcCos", piExpression (1 % 2))
    , ("ArcTan", Integer 0)
    , ("ArcCot", piExpression (1 % 2))
    ]
  oneValues =
    [ ("ArcSin", piExpression (1 % 2))
    , ("ArcCos", Integer 0)
    , ("ArcTan", piExpression (1 % 4))
    , ("ArcCot", piExpression (1 % 4))
    , ("ArcSec", Integer 0)
    , ("ArcCsc", piExpression (1 % 2))
    ]

exactDegreeFunction :: Text -> Expr -> Maybe Expr
exactDegreeFunction base value
  | "Arc" `T.isPrefixOf` base = do
      radians <- exactNumericReduction (Call (Symbol base) [value])
      case radians of
        Symbol name
          | name `elem` ["ComplexInfinity", "Indeterminate", "Infinity", "-Infinity"] ->
              Just radians
        _ -> do
          multiple <- piMultiple radians
          Just (rationalExpression (180 * multiple))
  | otherwise = do
      degreeValue <- asExactRational value
      exactNumericReduction
        (Call (Symbol base) [piExpression (degreeValue / 180)])

piExpression :: Rational -> Expr
piExpression multiple
  | multiple == 0 = Integer 0
  | multiple == 1 = Symbol "Pi"
  | otherwise =
      Call
        (Symbol "Times")
        [rationalExpression multiple, Symbol "Pi"]

sinExactTable, cosExactTable, tanExactTable :: [(Rational, Expr)]
sinExactTable =
  [ (0, Integer 0), (1 % 6, Rational 1 2), (1 % 2, Integer 1)
  , (5 % 6, Rational 1 2), (1, Integer 0), (7 % 6, Rational (-1) 2)
  , (3 % 2, Integer (-1)), (11 % 6, Rational (-1) 2)
  ]
cosExactTable =
  [ (0, Integer 1), (1 % 3, Rational 1 2), (1 % 2, Integer 0)
  , (2 % 3, Rational (-1) 2), (1, Integer (-1)), (4 % 3, Rational (-1) 2)
  , (3 % 2, Integer 0), (5 % 3, Rational 1 2)
  ]
tanExactTable =
  [ (0, Integer 0), (1 % 4, Integer 1), (3 % 4, Integer (-1))
  , (1, Integer 0), (5 % 4, Integer 1), (7 % 4, Integer (-1))
  ]

piMultiple :: Expr -> Maybe Rational
piMultiple (Symbol name)
  | systemSymbolIs "Pi" name = Just 1
piMultiple (Call (Symbol timesHead) values)
  | systemSymbolIs "Times" timesHead = do
      let piFactors = [() | Symbol name <- values, systemSymbolIs "Pi" name]
          rationalFactors =
            [ factor
            | value <- values
            , Just factor <- [asExactRational value]
            ]
          unsupported =
            [ value
            | value <- values
            , case value of
                Symbol name -> not (systemSymbolIs "Pi" name)
                Integer {} -> False
                Rational {} -> False
                _ -> True
            ]
      if length piFactors == 1 && null unsupported
        then Just (product rationalFactors)
        else Nothing
piMultiple _ = Nothing

asExactRational :: Expr -> Maybe Rational
asExactRational = \case
  Integer value -> Just (value % 1)
  Rational value denominatorValue -> Just (value % denominatorValue)
  _ -> Nothing

normalizePiMultiple :: Rational -> Rational
normalizePiMultiple value =
  let quotient = floor (value / 2) :: Integer
   in value - fromInteger (2 * quotient)

exactZero :: Expr -> Bool
exactZero (Integer 0) = True
exactZero (Rational 0 _) = True
exactZero _ = False

exactOne :: Expr -> Bool
exactOne (Integer 1) = True
exactOne (Rational value denominatorValue) = value == denominatorValue
exactOne _ = False

exactNegativeOne :: Expr -> Bool
exactNegativeOne (Integer (-1)) = True
exactNegativeOne (Rational value denominatorValue) = value == negate denominatorValue
exactNegativeOne _ = False

-- Brent-McMillan's Bessel-series formula.  Both its truncation loop and the
-- asymptotic n choice carry explicit guards, so a future regression cannot
-- turn a constant request into an unbounded pure computation.
eulerGammaConstant :: Int -> Maybe CReal
eulerGammaConstant digits = do
  let safetyDigits = digits + 14
      n = max 4 (ceiling (fromIntegral safetyDigits * log 10 / 4 :: Double))
      maximumTerms = 8 * n + 4 * safetyDigits + 128
  (aSum, bSum) <- besselSums n safetyDigits maximumTerms
  Just (fromRational (aSum / bSum) - log (fromIntegral n))

besselSums :: Int -> Int -> Int -> Maybe (Rational, Rational)
besselSums n requiredDigits maximumTerms = go 1 0 1 0 1
 where
  nSquared = toInteger n * toInteger n
  threshold = 10 ^ requiredDigits
  go k harmonic term aSum bSum
    | k > maximumTerms = Nothing
    | otherwise =
        let kInteger = toInteger k
            nextHarmonic = harmonic + 1 % kInteger
            nextTerm = term * (nSquared % (kInteger * kInteger))
            nextA = aSum + nextHarmonic * nextTerm
            nextB = bSum + nextTerm
            safelyPastPeak = k > 2 * n
            converged =
              safelyPastPeak
                && abs (numerator nextTerm) * threshold * denominator nextB
                  < numerator nextB * denominator nextTerm
         in if converged
              then Just (nextA, nextB)
              else go (k + 1) nextHarmonic nextTerm nextA nextB

-- Ramanujan's central-binomial series converges geometrically and combines
-- only exact rational terms with constructive pi/log/sqrt values.
catalanConstant :: Int -> Maybe CReal
catalanConstant digits = do
  series <- catalanSeries (digits + 14) (4 * (digits + 14) + 128)
  let radical = sqrt 3 :: CReal
  Just (pi / 8 * log (2 + radical) + 3 / 8 * fromRational series)

catalanSeries :: Int -> Int -> Maybe Rational
catalanSeries requiredDigits maximumTerms = go 0 1 0
 where
  threshold = 10 ^ requiredDigits
  go n term retained
    | n > maximumTerms = Nothing
    | otherwise =
        let updated = retained + term
            nInteger = toInteger n
            nextTerm =
              term
                * ((2 * nInteger + 1) * (nInteger + 1)
                    % (2 * (2 * nInteger + 3) * (2 * nInteger + 3)))
            converged = abs (numerator nextTerm) * threshold < denominator nextTerm
         in if converged then Just updated else go (n + 1) nextTerm updated

rootCallApproximation :: Int -> [Expr] -> Maybe Approximation
rootCallApproximation digits values = do
  (function, rootIndex, method) <- case values of
    [function, Integer rootIndex]
      | rootIndex >= 1 -> Just (function, rootIndex, 0)
    [function, Integer rootIndex, Integer method]
      | rootIndex >= 1 -> Just (function, rootIndex, method)
    _ -> Nothing
  coefficients <- rootFunctionCoefficients function
  rootApproximation digits (Root coefficients (rootIndex - 1) method)

type IntegerPolynomial = Map.Map Int Integer

rootFunctionCoefficients :: Expr -> Maybe [Integer]
rootFunctionCoefficients function = do
  polynomial <- case function of
    Call (Symbol functionHead) [body]
      | systemSymbolIs "Function" functionHead ->
          integerPolynomial slotOne body
    Call (Symbol functionHead) [parameter@(Symbol _), body]
      | systemSymbolIs "Function" functionHead ->
          integerPolynomial (== parameter) body
    _ -> Nothing
  if Map.null polynomial
    then Nothing
    else do
      let degree = fst (Map.findMax polynomial)
      if degree < 1 || degree > 1000
        then Nothing
        else
          Just
            [Map.findWithDefault 0 power polynomial | power <- [0 .. degree]]
 where
  slotOne (Call (Symbol slotHead) []) = systemSymbolIs "Slot" slotHead
  slotOne (Call (Symbol slotHead) [Integer 1]) = systemSymbolIs "Slot" slotHead
  slotOne _ = False

integerPolynomial :: (Expr -> Bool) -> Expr -> Maybe IntegerPolynomial
integerPolynomial isVariable expression
  | isVariable expression = Just (Map.singleton 1 1)
integerPolynomial _ (Integer value) = Just (integerConstantPolynomial value)
integerPolynomial _ (Rational value denominatorValue)
  | denominatorValue == 1 = Just (integerConstantPolynomial value)
integerPolynomial isVariable (Call (Symbol headName) values)
  | systemSymbolIs "Plus" headName = do
      terms <- traverse (integerPolynomial isVariable) values
      Just (foldl addIntegerPolynomial Map.empty terms)
  | systemSymbolIs "Times" headName = do
      factors <- traverse (integerPolynomial isVariable) values
      foldIntegerPolynomialProduct factors
integerPolynomial isVariable (Call (Symbol headName) [base, Integer powerValue])
  | systemSymbolIs "Power" headName
  , powerValue >= 0
  , powerValue <= 1000 = do
      polynomial <- integerPolynomial isVariable base
      integerPolynomialPower polynomial powerValue
integerPolynomial _ _ = Nothing

integerConstantPolynomial :: Integer -> IntegerPolynomial
integerConstantPolynomial 0 = Map.empty
integerConstantPolynomial value = Map.singleton 0 value

addIntegerPolynomial :: IntegerPolynomial -> IntegerPolynomial -> IntegerPolynomial
addIntegerPolynomial left right =
  Map.filter (/= 0) (Map.unionWith (+) left right)

foldIntegerPolynomialProduct :: [IntegerPolynomial] -> Maybe IntegerPolynomial
foldIntegerPolynomialProduct = go (Map.singleton 0 1)
 where
  go retained [] = Just retained
  go retained (factor : rest) = do
    productValue <- multiplyIntegerPolynomial retained factor
    go productValue rest

multiplyIntegerPolynomial
  :: IntegerPolynomial
  -> IntegerPolynomial
  -> Maybe IntegerPolynomial
multiplyIntegerPolynomial left right =
  let productValue =
        Map.filter
          (/= 0)
          ( Map.fromListWith
              (+)
              [ (leftDegree + rightDegree, leftValue * rightValue)
              | (leftDegree, leftValue) <- Map.toList left
              , (rightDegree, rightValue) <- Map.toList right
              ]
          )
   in if Map.null productValue || fst (Map.findMax productValue) <= 1000
        then Just productValue
        else Nothing

integerPolynomialPower
  :: IntegerPolynomial
  -> Integer
  -> Maybe IntegerPolynomial
integerPolynomialPower base powerValue = go (Map.singleton 0 1) base powerValue
 where
  go retained _ 0 = Just retained
  go retained factor 1 = multiplyIntegerPolynomial retained factor
  go retained factor remaining
    | odd remaining = do
        updated <- multiplyIntegerPolynomial retained factor
        squared <- multiplyIntegerPolynomial factor factor
        go updated squared (remaining `div` 2)
    | otherwise = do
        squared <- multiplyIntegerPolynomial factor factor
        go retained squared (remaining `div` 2)

rootApproximation :: Int -> Expr -> Maybe Approximation
rootApproximation digits (Root coefficients rootIndex _)
  | rootIndex < 0 || rootIndex >= toInteger degree = Nothing
  | otherwise = do
      roots <- approximatePolynomialRoots coefficients
      selected <- listAt (fromInteger rootIndex) roots
      let isRealRoot = rootIsNumericallyReal selected
          -- Durand-Kerner contributes roughly machine precision.  Newton
          -- doubles correct digits per step; two guard steps cover the
          -- formatter margin without constructing an exponentially deep
          -- constructive-real closure.
          targetBlocks = max 1 ((digits + 32) `div` 15)
          iterations = min 32 (2 + ceilingLog2 targetBlocks)
          constructiveRoot =
            if isRealRoot
              then
                refineRealRoot
                  coefficients
                  iterations
                  (fromRational (toRational (Complex.realPart selected)))
                    Complex.:+ 0
              else
                refineComplexRoot
                  coefficients
                  iterations
                  ( fromRational (toRational (Complex.realPart selected))
                      Complex.:+ fromRational (toRational (Complex.imagPart selected))
                  )
      Just
        ( Approximation
            constructiveRoot
            selected
            isRealRoot
            False
            isRealRoot
        )
 where
  degree = length coefficients - 1
rootApproximation _ _ = Nothing

approximatePolynomialRoots :: [Integer] -> Maybe [Complex.Complex Double]
approximatePolynomialRoots coefficients
  | degree <= 0 = Nothing
  | otherwise = Just (sortPolynomialRoots (iterateRoots (0 :: Int) initialRoots))
 where
  degree = length coefficients - 1
  leading = fromInteger (last coefficients)
  radius =
    1
      + maximum
        (0 : [abs (fromInteger coefficient / leading) | coefficient <- init coefficients])
  initialRoots =
    [ Complex.mkPolar radius (2 * pi * fromIntegral index / fromIntegral degree + 0.137)
    | index <- [0 .. degree - 1]
    ]
  maximumIterations = 512
  iterateRoots iteration roots
    | iteration >= maximumIterations = roots
    | maximum (0 : map Complex.magnitude deltas) < 1e-14 = updated
    | otherwise = iterateRoots (iteration + 1) updated
   where
    deltas = zipWith correction [(0 :: Int) ..] roots
    updated = zipWith (-) roots deltas
    correction index rootValue =
      let denominatorValue =
            product
              [ rootValue - other
              | (otherIndex, other) <- zip [0 ..] roots
              , otherIndex /= index
              ]
       in if Complex.magnitude denominatorValue < 1e-30
            then 0
            else polynomialDouble coefficients rootValue / denominatorValue

sortPolynomialRoots :: [Complex.Complex Double] -> [Complex.Complex Double]
sortPolynomialRoots roots = sortBy compareRoot (realRoots <> complexRoots)
 where
  realRoots =
    [ Complex.realPart value Complex.:+ 0
    | value <- roots
    , rootIsNumericallyReal value
    ]
  complexRoots = [value | value <- roots, not (rootIsNumericallyReal value)]
  compareRoot left right =
    compare
      (not (rootIsNumericallyReal left), Complex.realPart left, Complex.imagPart left)
      (not (rootIsNumericallyReal right), Complex.realPart right, Complex.imagPart right)

rootIsNumericallyReal :: Complex.Complex Double -> Bool
rootIsNumericallyReal value =
  abs (Complex.imagPart value)
    <= 1e-9 * max 1 (abs (Complex.realPart value))

polynomialDouble :: [Integer] -> Complex.Complex Double -> Complex.Complex Double
polynomialDouble coefficients value =
  foldr (\coefficient retained -> fromInteger coefficient + value * retained) 0 coefficients

refineRealRoot :: [Integer] -> Int -> CReal -> CReal
refineRealRoot coefficients iterations = go iterations
 where
  derivative = polynomialDerivative coefficients
  go 0 value = value
  go remaining value =
    go
      (remaining - 1)
      ( value
          - polynomialConstructiveReal coefficients value
            / polynomialConstructiveReal derivative value
      )

refineComplexRoot
  :: [Integer]
  -> Int
  -> Complex.Complex CReal
  -> Complex.Complex CReal
refineComplexRoot coefficients iterations = go iterations
 where
  derivative = polynomialDerivative coefficients
  go 0 value = value
  go remaining value =
    go
      (remaining - 1)
      ( value
          - divideComplex
              (polynomialConstructiveComplex coefficients value)
              (polynomialConstructiveComplex derivative value)
      )

polynomialDerivative :: [Integer] -> [Integer]
polynomialDerivative coefficients =
  [toInteger power * coefficient | (power, coefficient) <- zip [1 :: Int ..] (drop 1 coefficients)]

polynomialConstructiveReal :: [Integer] -> CReal -> CReal
polynomialConstructiveReal coefficients value =
  foldr (\coefficient retained -> fromInteger coefficient + value * retained) 0 coefficients

polynomialConstructiveComplex
  :: [Integer]
  -> Complex.Complex CReal
  -> Complex.Complex CReal
polynomialConstructiveComplex coefficients value =
  foldr (\coefficient retained -> fromInteger coefficient + value * retained) 0 coefficients

divideComplex
  :: Fractional value
  => Complex.Complex value
  -> Complex.Complex value
  -> Complex.Complex value
divideComplex left right =
  let a = Complex.realPart left
      b = Complex.imagPart left
      c = Complex.realPart right
      d = Complex.imagPart right
      norm = c * c + d * d
   in ((a * c + b * d) / norm) Complex.:+ ((b * c - a * d) / norm)

ceilingLog2 :: Int -> Int
ceilingLog2 value = go 0 1
 where
  go exponentValue power
    | power >= value = exponentValue
    | otherwise = go (exponentValue + 1) (power * 2)

listAt :: Int -> [value] -> Maybe value
listAt index _ | index < 0 = Nothing
listAt _ [] = Nothing
listAt 0 (value : _) = Just value
listAt index (_ : rest) = listAt (index - 1) rest

formatConstructiveSignificant :: Int -> Bool -> CReal -> Double -> Text
formatConstructiveSignificant _ True _ _ = "0."
formatConstructiveSignificant digits False value estimate =
  case constructiveRationalForFormatting digits value estimate of
    Nothing -> "0."
    Just rationalValue
      | rationalValue == 0 -> "0."
      | otherwise -> formatExactSignificant True digits rationalValue

constructiveRationalForFormatting :: Int -> CReal -> Double -> Maybe Rational
constructiveRationalForFormatting digits value estimate
  | estimate /= 0 && not (isNaN estimate) && not (isInfinite estimate) =
      parseAt estimatedGuardPlaces
  | otherwise = search initialPlaces
 where
  estimatedExponent
    | estimate == 0 || isNaN estimate || isInfinite estimate = 0
    | otherwise = floor (logBase 10 (abs estimate))
  requiredPlaces = max 0 (digits - estimatedExponent - 1)
  estimatedGuardPlaces = min maximumPlaces (requiredPlaces + 18)
  initialPlaces = min maximumPlaces (max 38 (digits + 18))
  maximumPlaces = fromInteger maximumNumericDigits
  parseAt places = parseFixedRational (T.pack (showCReal places value))
  search places = do
    sampled <- parseAt places
    if sampled /= 0 || places >= maximumPlaces
      then Just sampled
      else search (min maximumPlaces (places * 2))

formatExactSignificant :: Bool -> Int -> Rational -> Text
formatExactSignificant padTrailing digits value
  | value == 0 = "0."
  | otherwise =
      let magnitudePower = decimalExponent value
          scale = digits - magnitudePower - 1
          rounded = roundAtDecimalScale scale value
          fixed
            | scale >= 0 = formatFixedRational rounded scale (value < 0 && rounded == 0)
            | otherwise = formatFixedRational rounded 0 False
       in if padTrailing
            then ensureApproximatePoint digits scale fixed
            else trimFixedFraction fixed

ensureApproximatePoint :: Int -> Int -> Text -> Text
ensureApproximatePoint digits scale source
  | digits == 1 && scale == 0 = case T.stripSuffix "." source of
      Just whole -> whole <> ".0"
      Nothing -> source
  | otherwise = source

roundAtDecimalScale :: Int -> Rational -> Rational
roundAtDecimalScale scale value
  | scale >= 0 =
      let factor = 10 ^ scale
       in roundHalfEven (value * fromInteger factor) % factor
  | otherwise =
      let factor = 10 ^ negate scale
       in fromInteger (roundHalfEven (value / fromInteger factor) * factor)

roundHalfEven :: Rational -> Integer
roundHalfEven value =
  let valueNumerator = numerator value
      valueDenominator = denominator value
      (quotient, remainder) = valueNumerator `quotRem` valueDenominator
      comparison = compare (2 * abs remainder) valueDenominator
      awayFromZero = quotient + signum valueNumerator
   in case comparison of
        LT -> quotient
        GT -> awayFromZero
        EQ -> if even quotient then quotient else awayFromZero

decimalExponent :: Rational -> Int
decimalExponent value
  | value == 0 = 0
  | otherwise =
      let absoluteNumerator = abs (numerator value)
          valueDenominator = denominator value
          candidate = decimalLength absoluteNumerator - decimalLength valueDenominator
       in if compareAtPower absoluteNumerator valueDenominator candidate == LT
            then candidate - 1
            else candidate

compareAtPower :: Integer -> Integer -> Int -> Ordering
compareAtPower left right power
  | power >= 0 = compare left (right * 10 ^ power)
  | otherwise = compare (left * 10 ^ negate power) right

decimalLength :: Integer -> Int
decimalLength = T.length . decimalInteger . abs

formatStoredFixed :: StoredReal -> Text
formatStoredFixed info =
  formatFixedRational
    (storedValue info)
    (storedScale info)
    (storedNegativeZero info)

formatFixedRational :: Rational -> Int -> Bool -> Text
formatFixedRational value scale negativeZero =
  let scaled = numerator value * (10 ^ scale) `div` denominator value
      sign = if scaled < 0 || (scaled == 0 && negativeZero) then "-" else ""
      digits = decimalInteger (abs scaled)
   in if scale == 0
        then sign <> digits <> "."
        else
          let padded = T.replicate (max 0 (scale + 1 - T.length digits)) "0" <> digits
              decimalPosition = T.length padded - scale
           in sign <> T.take decimalPosition padded <> "." <> T.drop decimalPosition padded

trimFixedFraction :: Text -> Text
trimFixedFraction source
  | not (T.isInfixOf "." source) = source <> "."
  | otherwise = T.dropWhileEnd (== '0') source

rationalExpression :: Rational -> Expr
rationalExpression value
  | denominator value == 1 = Integer (numerator value)
  | otherwise = Rational (numerator value) (denominator value)

makeNumericComplex :: Expr -> Expr -> Expr
makeNumericComplex realPart imaginaryPart
  | exactExpressionZero imaginaryPart = realPart
  | machineRealExpr realPart || machineRealExpr imaginaryPart =
      Complex (toMachineComponent realPart) (toMachineComponent imaginaryPart)
  | otherwise = Complex realPart imaginaryPart

exactExpressionZero :: Expr -> Bool
exactExpressionZero (Integer 0) = True
exactExpressionZero (Rational 0 _) = True
exactExpressionZero _ = False

numericComponentIsZero :: Expr -> Bool
numericComponentIsZero expression
  | exactExpressionZero expression = True
numericComponentIsZero (Real source) =
  maybe False ((== 0) . storedValue) (parseStoredReal source)
numericComponentIsZero (Complex realPart imaginaryPart) =
  numericComponentIsZero realPart && numericComponentIsZero imaginaryPart
numericComponentIsZero _ = False

numericComponentIsOne :: Expr -> Bool
numericComponentIsOne (Integer 1) = True
numericComponentIsOne (Rational numeratorValue denominatorValue) =
  numeratorValue == denominatorValue
numericComponentIsOne (Real source) =
  maybe False ((== 1) . storedValue) (parseStoredReal source)
numericComponentIsOne _ = False

numericComponentIsNegativeOne :: Expr -> Bool
numericComponentIsNegativeOne (Integer (-1)) = True
numericComponentIsNegativeOne (Rational numeratorValue denominatorValue) =
  numeratorValue == negate denominatorValue
numericComponentIsNegativeOne (Real source) =
  maybe False ((== (-1)) . storedValue) (parseStoredReal source)
numericComponentIsNegativeOne _ = False

machineRealExpr :: Expr -> Bool
machineRealExpr (Real source) = case parseStoredReal source of
  Just info -> storedKind info == StoredMachineReal
  Nothing -> False
machineRealExpr _ = False

toMachineComponent :: Expr -> Expr
toMachineComponent expression@(Real source) = case parseStoredReal source of
  Just info -> case storedKind info of
    StoredMachineReal -> expression
    _ -> maybe expression machineRealExpression (readMaybe (T.unpack (storedMachineSource info)))
  Nothing -> expression
toMachineComponent (Integer value) = machineRealExpression (fromInteger value)
toMachineComponent (Rational value denominatorValue) =
  machineRealExpression (fromInteger value / fromInteger denominatorValue)
toMachineComponent expression = expression

machineRealExpression :: Double -> Expr
machineRealExpression value
  | isNaN value = Symbol "Indeterminate"
  | isInfinite value = SpecialReal OverflowReal
  | otherwise = Real (formatMachineRealSource value)

-- Kept byte-for-byte compatible with Evaluate.formatMachineReal.  It lives
-- here as well to avoid a module cycle while this bridge remains internal.
formatMachineRealSource :: Double -> Text
formatMachineRealSource value =
  case splitScientific (T.pack (show value)) of
    Just (mantissa, magnitudePower)
      | magnitudePower >= -4 && magnitudePower < 16 ->
          ensureMachinePoint (scientificToFixed mantissa magnitudePower)
      | otherwise ->
          stripTerminalZero mantissa <> "*^" <> formatExponent magnitudePower
    Nothing -> ensureMachinePoint (T.pack (show value))

splitScientific :: Text -> Maybe (Text, Int)
splitScientific source =
  case T.break (`elem` ("eE" :: String)) source of
    (mantissa, exponentSource)
      | T.null exponentSource -> Nothing
      | otherwise -> (,) mantissa <$> readMaybe (T.unpack (T.drop 1 exponentSource))

scientificToFixed :: Text -> Int -> Text
scientificToFixed mantissa magnitudePower =
  let (sign, unsigned) = case T.uncons mantissa of
        Just ('-', rest) -> ("-", rest)
        Just ('+', rest) -> ("", rest)
        _ -> ("", mantissa)
      (whole, fractionWithPoint) = T.breakOn "." unsigned
      fraction = if T.null fractionWithPoint then "" else T.drop 1 fractionWithPoint
      digits = whole <> fraction
      decimalPosition = T.length whole + magnitudePower
      fixed
        | decimalPosition <= 0 = "0." <> T.replicate (negate decimalPosition) "0" <> digits
        | decimalPosition >= T.length digits = digits <> T.replicate (decimalPosition - T.length digits) "0" <> ".0"
        | otherwise = T.take decimalPosition digits <> "." <> T.drop decimalPosition digits
   in sign <> trimFractionZeros fixed

trimFractionZeros :: Text -> Text
trimFractionZeros source
  | not (T.isInfixOf "." source) = source
  | otherwise =
      let trimmed = T.dropWhileEnd (== '0') source
       in if T.isSuffixOf "." trimmed then trimmed <> "0" else trimmed

stripTerminalZero :: Text -> Text
stripTerminalZero source = maybe source id (T.stripSuffix ".0" source)

formatExponent :: Int -> Text
formatExponent magnitudePower =
  let magnitude = decimalInt (abs magnitudePower)
      padded = if T.length magnitude < 2 then "0" <> magnitude else magnitude
   in (if magnitudePower < 0 then "-" else "+") <> padded

ensureMachinePoint :: Text -> Text
ensureMachinePoint source
  | Just withoutZero <- T.stripSuffix ".0" source = withoutZero <> "."
  | T.isInfixOf "." source = source
  | otherwise = source <> "."

parseStoredReal :: Text -> Maybe StoredReal
parseStoredReal source = do
  (literal, magnitudePower, exponentSource) <- splitRealMagnitude source
  let (numberSource, markerSource) = T.breakOn "`" literal
  (baseValue, baseScale, negativeZero) <- parseDecimalRational numberSource
  if abs magnitudePower > 100000
    then Nothing
    else do
      let exponentMagnitude = fromInteger (abs magnitudePower)
          value =
            if magnitudePower >= 0
              then baseValue * fromInteger (10 ^ exponentMagnitude)
              else baseValue / fromInteger (10 ^ exponentMagnitude)
          scale = baseScale + if magnitudePower < 0 then exponentMagnitude else 0
          kind = parseStoredRealKind markerSource
          machineSource = normalizeDoubleMantissa numberSource <> exponentSource
      Just
        StoredReal
          { storedValue = value
          , storedKind = kind
          , storedScale = scale
          , storedNegativeZero = negativeZero
          , storedMachineSource = machineSource
          }

splitRealMagnitude :: Text -> Maybe (Text, Integer, Text)
splitRealMagnitude source =
  case T.breakOn "*^" source of
    (literal, marker)
      | T.null marker -> Just (literal, 0, "")
      | otherwise -> do
          let exponentSource = T.drop 2 marker
          if T.null exponentSource || T.isInfixOf "*^" exponentSource
            then Nothing
            else do
              magnitudePower <- readMaybe (T.unpack exponentSource)
              Just (literal, magnitudePower, "e" <> exponentSource)

parseDecimalRational :: Text -> Maybe (Rational, Int, Bool)
parseDecimalRational source = do
  let (sign, unsigned) = case T.uncons source of
        Just ('-', rest) -> (-1, rest)
        Just ('+', rest) -> (1, rest)
        _ -> (1, source)
      pieces = T.splitOn "." unsigned
  (whole, fraction) <- case pieces of
    [wholePart] -> Just (wholePart, "")
    [wholePart, fractionPart] -> Just (wholePart, fractionPart)
    _ -> Nothing
  if (T.null whole && T.null fraction)
      || not (T.all isDigit whole)
      || not (T.all isDigit fraction)
    then Nothing
    else do
      coefficient <-
        readMaybe
          (T.unpack (if T.null (whole <> fraction) then "0" else whole <> fraction))
      let scale = T.length fraction
          signedCoefficient = sign * coefficient
      Just
        ( signedCoefficient % (10 ^ scale)
        , scale
        , sign < 0 && coefficient == 0
        )

parseFixedRational :: Text -> Maybe Rational
parseFixedRational source = do
  (value, _, _) <- parseDecimalRational source
  Just value

parseStoredRealKind :: Text -> StoredRealKind
parseStoredRealKind markerSource
  | T.null markerSource = StoredMachineReal
  | T.null specification = StoredMachineReal
  | isAccuracy = StoredAccuracyReal (parseMarkerValue specification)
  | otherwise = StoredPrecisionReal (parseMarkerValue specification)
 where
  afterFirst = T.drop 1 markerSource
  isAccuracy = T.isPrefixOf "`" afterFirst
  specification = if isAccuracy then T.drop 1 afterFirst else afterFirst

parseMarkerValue :: Text -> Integer
parseMarkerValue source = case parseDecimalRational source of
  Just (value, _, _) -> max 0 (truncateRational value)
  Nothing -> 0

truncateRational :: Rational -> Integer
truncateRational value = numerator value `quot` denominator value

normalizeDoubleMantissa :: Text -> Text
normalizeDoubleMantissa source
  | T.isPrefixOf "-." source = "-0" <> T.drop 1 source
  | T.isPrefixOf "+." source = "+0" <> T.drop 1 source
  | T.isPrefixOf "." source = "0" <> source
  | T.isSuffixOf "." source = source <> "0"
  | otherwise = source

decimalInteger :: Integer -> Text
decimalInteger = T.pack . show

decimalInt :: Int -> Text
decimalInt = T.pack . show
