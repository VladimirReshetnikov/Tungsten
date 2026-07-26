{-# LANGUAGE OverloadedStrings #-}

-- | Exact, kernel-free numeric and algebraic reducers.
--
-- This module owns built-ins whose inputs and outputs can be represented with
-- arbitrary-precision integers and reduced rationals alone.  Unsupported
-- domains deliberately return 'Nothing', leaving the original Wolfram call
-- symbolic in the same way as the Python compatibility evaluator.
module Tungsten.NumericAlgebra
  ( reduceNumericBuiltin
  ) where

import Data.Bits ((.&.), (.|.), complement, shiftL, shiftR, xor)
import Data.Char (toUpper)
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Expression (Expr (..))

-- | Attempt one exact numeric reduction.  The outer 'Either' is reserved for
-- Python-compatible diagnostics from structurally invalid constructors; the
-- ordinary unsupported-domain result is @Right Nothing@.
reduceNumericBuiltin :: Text -> [Expr] -> Either Text (Maybe Expr)
reduceNumericBuiltin "FromDigits" arguments' = Just <$> reduceFromDigits arguments'
reduceNumericBuiltin "ChineseRemainder" arguments' = Just <$> reduceChineseRemainder arguments'
reduceNumericBuiltin headName arguments' = Right $ case headName of
  "FactorInteger" -> reduceFactorInteger arguments'
  "IntegerExponent" -> reduceIntegerExponent arguments'
  "ContinuedFraction" -> reduceContinuedFraction arguments'
  "FromContinuedFraction" -> reduceFromContinuedFraction arguments'
  "IntegerPartitions" -> reduceIntegerPartitions arguments'
  "Binomial" -> integerBinary binomialInteger arguments'
  "Multinomial" -> reduceMultinomial arguments'
  "JacobiSymbol" -> reduceJacobiSymbol arguments'
  "KroneckerSymbol" -> reduceKroneckerSymbol arguments'
  "Fibonacci" -> integerUnary fibonacciInteger arguments'
  "LucasL" -> integerUnary lucasInteger arguments'
  "BernoulliB" -> constrainedIntegerExprUnary (>= 0) (fromFraction . bernoulliNumber) arguments'
  "EulerE" -> constrainedIntegerUnary (>= 0) eulerNumber arguments'
  "HarmonicNumber" -> reduceHarmonicNumber arguments'
  "UnitStep" -> integerVariadic (\values -> if all (>= 0) values then 1 else 0) arguments'
  "Unitize" -> integerUnary (\value -> if value == 0 then 0 else 1) arguments'
  "RealSign" -> integerUnary signum arguments'
  "RealAbs" -> integerUnary abs arguments'
  "Ramp" -> integerUnary (max 0) arguments'
  "Mod" -> reduceMod arguments'
  "Quotient" -> reduceQuotient arguments'
  "QuotientRemainder" -> reduceQuotientRemainder arguments'
  "KroneckerDelta" -> reduceKroneckerDelta arguments'
  "DiscreteDelta" -> integerVariadic (\values -> if all (== 0) values then 1 else 0) arguments'
  "GCD" -> integerVariadic (foldl' gcd 0 . map abs) arguments'
  "LCM" -> integerVariadic (foldl' lcm 1 . map abs) arguments'
  "Divisors" -> reduceDivisors arguments'
  "PrimeQ" -> integerPredicate isPrime arguments'
  "CompositeQ" -> integerPredicate (\value -> value >= 4 && not (isPrime value)) arguments'
  "PrimePowerQ" -> integerPredicate isPrimePower arguments'
  "EulerPhi" -> constrainedIntegerUnary (> 0) eulerPhi arguments'
  "CarmichaelLambda" -> constrainedIntegerUnary (> 0) carmichaelLambda arguments'
  "MoebiusMu" -> constrainedIntegerUnary (> 0) moebiusMu arguments'
  "LiouvilleLambda" -> constrainedIntegerUnary (> 0) liouvilleLambda arguments'
  "JordanTotient" -> reduceJordanTotient arguments'
  "RamanujanTau" -> constrainedIntegerUnary (>= 1) ramanujanTau arguments'
  "DivisorSigma" -> reduceDivisorSigma arguments'
  "PrimePi" -> constrainedIntegerUnary (>= 0) primePi arguments'
  "Prime" -> constrainedIntegerUnary (>= 1) nthPrime arguments'
  "NextPrime" -> reduceNextPrime arguments'
  "PowerMod" -> reducePowerMod arguments'
  "ModularInverse" -> reduceModularInverse arguments'
  "MultiplicativeOrder" -> reduceMultiplicativeOrder arguments'
  "PrimitiveRoot" -> reducePrimitiveRoot arguments'
  "IntegerLength" -> reduceIntegerLength arguments'
  "IntegerDigits" -> reduceIntegerDigits arguments'
  "IntegerReverse" -> reduceIntegerReverse arguments'
  "DigitCount" -> reduceDigitCount arguments'
  "BitAnd" -> integerVariadic (foldl' (.&.) (-1)) arguments'
  "BitOr" -> integerVariadic (foldl' (.|.) 0) arguments'
  "BitXor" -> integerVariadic (foldl' xor 0) arguments'
  "BitShiftLeft" -> reduceBitShift True arguments'
  "BitShiftRight" -> reduceBitShift False arguments'
  "BitNot" -> integerUnary complement arguments'
  "BitClear" -> reduceBitMutation False arguments'
  "BitSet" -> reduceBitMutation True arguments'
  "BitGet" -> reduceBitGet arguments'
  "BitLength" -> integerUnary integerBitLength arguments'
  "PartitionsP" -> integerUnary (partitionCount False) arguments'
  "PartitionsQ" -> integerUnary (partitionCount True) arguments'
  _ -> Nothing

reduceFactorInteger :: [Expr] -> Maybe Expr
reduceFactorInteger [] = Nothing
reduceFactorInteger (value : options) = do
  (partialLimit, gaussianIntegers) <- parseFactorOptions options
  if gaussianIntegers
    then do
      if partialLimit == Nothing then pure () else Nothing
      factors <- gaussianFactorsForExpr value
      Just . listExpr $
        [ listExpr [gaussianExpr factor, Integer exponentValue]
        | (factor, exponentValue) <- factors
        ]
    else do
      (numerator, denominator) <- exactFractionParts value
      Just . listExpr . map factorPair $
        specialFactors partialLimit numerator denominator
 where
  factorPair (factor, exponentValue) =
    listExpr [Integer factor, Integer exponentValue]
  specialFactors _ 0 _ = [(0, 1)]
  specialFactors _ 1 1 = [(1, 1)]
  specialFactors _ (-1) 1 = [(-1, 1)]
  specialFactors partialLimit numerator denominator =
    (if numerator < 0 then [(-1, 1)] else [])
      <> factorWithLimit (abs numerator) partialLimit
      <> [ (factor, negate exponentValue)
         | (factor, exponentValue) <- factorWithLimit denominator partialLimit
         ]

gaussianFactorsForExpr :: Expr -> Maybe [((Integer, Integer), Integer)]
gaussianFactorsForExpr value
  | Just gaussian <- exactGaussianInteger value = Just (gaussianFactorInteger gaussian)
  | Just (numerator, denominator) <- exactFractionParts value =
      Just
        ( gaussianFactorInteger (numerator, 0)
            <> [ (factor, negate exponentValue)
               | (factor, exponentValue) <- gaussianFactorInteger (denominator, 0)
               ]
        )
  | otherwise = Nothing

exactGaussianInteger :: Expr -> Maybe (Integer, Integer)
exactGaussianInteger (Integer value) = Just (value, 0)
exactGaussianInteger (Rational numerator 1) = Just (numerator, 0)
exactGaussianInteger (Complex realPart imaginaryPart) = do
  realValue <- exactIntegerPart realPart
  imaginaryValue <- exactIntegerPart imaginaryPart
  Just (realValue, imaginaryValue)
exactGaussianInteger (Symbol name)
  | name `elem` ["I", "System`I"] = Just (0, 1)
exactGaussianInteger (Call (Symbol headName) values)
  | headName `elem` ["Complex", "System`Complex"] = case values of
      [realPart, imaginaryPart] -> do
        realValue <- exactIntegerPart realPart
        imaginaryValue <- exactIntegerPart imaginaryPart
        Just (realValue, imaginaryValue)
      _ -> Nothing
  | headName `elem` ["Plus", "System`Plus"] =
      foldl' addGaussian (Just (0, 0)) (map exactGaussianInteger values)
  | headName `elem` ["Times", "System`Times"] =
      foldl' multiplyGaussian (Just (1, 0)) (map exactGaussianInteger values)
exactGaussianInteger _ = Nothing

exactIntegerPart :: Expr -> Maybe Integer
exactIntegerPart (Integer value) = Just value
exactIntegerPart (Rational numerator 1) = Just numerator
exactIntegerPart _ = Nothing

addGaussian
  :: Maybe (Integer, Integer)
  -> Maybe (Integer, Integer)
  -> Maybe (Integer, Integer)
addGaussian (Just (leftReal, leftImaginary)) (Just (rightReal, rightImaginary)) =
  Just (leftReal + rightReal, leftImaginary + rightImaginary)
addGaussian _ _ = Nothing

multiplyGaussian
  :: Maybe (Integer, Integer)
  -> Maybe (Integer, Integer)
  -> Maybe (Integer, Integer)
multiplyGaussian (Just (leftReal, leftImaginary)) (Just (rightReal, rightImaginary)) =
  Just
    ( leftReal * rightReal - leftImaginary * rightImaginary
    , leftReal * rightImaginary + leftImaginary * rightReal
    )
multiplyGaussian _ _ = Nothing

gaussianExpr :: (Integer, Integer) -> Expr
gaussianExpr (realPart, 0) = Integer realPart
gaussianExpr (realPart, imaginaryPart) =
  Complex (Integer realPart) (Integer imaginaryPart)

gaussianFactorInteger :: (Integer, Integer) -> [((Integer, Integer), Integer)]
gaussianFactorInteger (0, 0) = [((0, 0), 1)]
gaussianFactorInteger value@(realPart, imaginaryPart)
  | norm == 1 = [(value, 1)]
  | otherwise =
      let (remaining, factors) =
            foldl' dividePrimeCandidates (value, []) (map fst (factorInteger norm))
       in if remaining == (1, 0)
            then factors
            else (remaining, 1) : factors
 where
  norm = realPart * realPart + imaginaryPart * imaginaryPart
  dividePrimeCandidates state prime =
    foldl' divideCandidate state (gaussianPrimeCandidates prime)
  divideCandidate (remaining, factors) candidate =
    let (quotient, exponentValue) = divideRepeatedlyGaussian remaining candidate 0
     in ( quotient
        , factors
            <> if exponentValue == 0 then [] else [(candidate, exponentValue)]
        )

divideRepeatedlyGaussian
  :: (Integer, Integer)
  -> (Integer, Integer)
  -> Integer
  -> ((Integer, Integer), Integer)
divideRepeatedlyGaussian value divisor exponentValue =
  case divideGaussianInteger value divisor of
    Nothing -> (value, exponentValue)
    Just quotient -> divideRepeatedlyGaussian quotient divisor (exponentValue + 1)

gaussianPrimeCandidates :: Integer -> [(Integer, Integer)]
gaussianPrimeCandidates 2 = [(1, 1)]
gaussianPrimeCandidates prime
  | prime `mod` 4 == 3 = [(prime, 0)]
  | otherwise = case sumOfTwoSquares prime of
      Nothing -> [(prime, 0)]
      Just (small, large)
        | small == large -> [(small, large)]
        | otherwise -> [(small, large), (large, small)]

sumOfTwoSquares :: Integer -> Maybe (Integer, Integer)
sumOfTwoSquares prime = search 1
 where
  search first
    | first * first > prime = Nothing
    | otherwise =
        let secondSquared = prime - first * first
            second = integerSquareRoot secondSquared
         in if second >= first && second * second == secondSquared
              then Just (first, second)
              else search (first + 1)

integerSquareRoot :: Integer -> Integer
integerSquareRoot value
  | value < 2 = value
  | otherwise = converge (value `div` 2 + 1)
 where
  converge estimate =
    let next = (estimate + value `div` estimate) `div` 2
     in if next >= estimate then estimate else converge next

divideGaussianInteger
  :: (Integer, Integer)
  -> (Integer, Integer)
  -> Maybe (Integer, Integer)
divideGaussianInteger (realPart, imaginaryPart) (divisorReal, divisorImaginary) =
  let norm = divisorReal * divisorReal + divisorImaginary * divisorImaginary
      realNumerator = realPart * divisorReal + imaginaryPart * divisorImaginary
      imaginaryNumerator = imaginaryPart * divisorReal - realPart * divisorImaginary
   in if realNumerator `mod` norm == 0 && imaginaryNumerator `mod` norm == 0
        then Just (realNumerator `div` norm, imaginaryNumerator `div` norm)
        else Nothing

exactFractionParts :: Expr -> Maybe (Integer, Integer)
exactFractionParts (Integer value) = Just (value, 1)
exactFractionParts (Rational numerator denominator) = Just (numerator, denominator)
exactFractionParts _ = Nothing

parseFactorOptions :: [Expr] -> Maybe (Maybe Integer, Bool)
parseFactorOptions = foldl' parseOne (Just (Nothing, False))
 where
  parseOne Nothing _ = Nothing
  parseOne (Just (_, gaussian)) (Integer limit)
    | limit > 0 = Just (Just limit, gaussian)
  parseOne (Just (limit, _)) (Call (Symbol "Rule") [Symbol option, Symbol truth])
    | option `elem` ["GaussianIntegers", "System`GaussianIntegers"]
    , truth `elem` ["True", "False", "System`True", "System`False"] =
        Just (limit, truth `elem` ["True", "System`True"])
  parseOne _ _ = Nothing

factorWithLimit :: Integer -> Maybe Integer -> [(Integer, Integer)]
factorWithLimit value Nothing = factorInteger value
factorWithLimit value (Just limit) = partialFactorInteger value limit

partialFactorInteger :: Integer -> Integer -> [(Integer, Integer)]
partialFactorInteger value limit = go value candidates
 where
  candidates = 2 : [3, 5 .. limit]
  go 1 _ = []
  go remaining [] = [(remaining, 1)]
  go remaining (candidate : rest)
    | candidate * candidate > remaining = [(remaining, 1)]
    | otherwise =
        let (exponentValue, quotient) = divideRepeatedly remaining candidate 0
         in (if exponentValue == 0 then [] else [(candidate, exponentValue)])
              <> go quotient rest
  divideRepeatedly remaining candidate exponentValue
    | remaining `mod` candidate == 0 =
        divideRepeatedly (remaining `div` candidate) candidate (exponentValue + 1)
    | otherwise = (exponentValue, remaining)

reduceIntegerExponent :: [Expr] -> Maybe Expr
reduceIntegerExponent [Integer value] = integerExponent value 10
reduceIntegerExponent [Integer value, Integer base]
  | abs base > 1 = integerExponent value (abs base)
reduceIntegerExponent _ = Nothing

integerExponent :: Integer -> Integer -> Maybe Expr
integerExponent 0 _ = Just (Symbol "Infinity")
integerExponent value base = Just (Integer (go (abs value) 0))
 where
  go remaining exponentValue
    | remaining `mod` base == 0 = go (remaining `div` base) (exponentValue + 1)
    | otherwise = exponentValue

reduceContinuedFraction :: [Expr] -> Maybe Expr
reduceContinuedFraction [value] = do
  fraction <- fractionFromExpr value
  Just (listExpr (map Integer (continuedFractionTerms fraction)))
reduceContinuedFraction [value, Integer limit]
  | limit > 0 = do
      fraction <- fractionFromExpr value
      Just
        ( listExpr
            (map Integer (take (fromInteger limit) (continuedFractionTerms fraction)))
        )
reduceContinuedFraction _ = Nothing

fractionFromExpr :: Expr -> Maybe Fraction
fractionFromExpr (Integer value) = Just (Fraction value 1)
fractionFromExpr (Rational numerator denominator) =
  Just (normalizeFraction (Fraction numerator denominator))
fractionFromExpr _ = Nothing

continuedFractionTerms :: Fraction -> [Integer]
continuedFractionTerms (Fraction 0 _) = [0]
continuedFractionTerms (Fraction numerator denominator) =
  map (signum numerator *) (go (abs numerator) denominator)
 where
  go currentNumerator currentDenominator =
    let (quotient, remainder) = currentNumerator `divMod` currentDenominator
     in quotient
          : if remainder == 0
              then []
              else go currentDenominator remainder

reduceFromContinuedFraction :: [Expr] -> Maybe Expr
reduceFromContinuedFraction [Call (Symbol "List") []] = Just (Symbol "Infinity")
reduceFromContinuedFraction [Call (Symbol "List") terms] = do
  integers <- integerArguments terms
  case reverse integers of
    [] -> Just (Symbol "Infinity")
    final : rest -> fromTerms (Fraction final 1) rest
 where
  fromTerms value [] = Just (fromFraction value)
  fromTerms (Fraction 0 _) _ = Just (Symbol "ComplexInfinity")
  fromTerms (Fraction numerator denominator) (term : remaining) =
    fromTerms
      (addFraction (Fraction term 1) (Fraction denominator numerator))
      remaining
reduceFromContinuedFraction _ = Nothing

reduceIntegerPartitions :: [Expr] -> Maybe Expr
reduceIntegerPartitions [Integer value] =
  Just (partitionListExpr value 0 (max 0 value))
reduceIntegerPartitions [Integer value, specification] = do
  (minimumLength, maximumLength) <- partitionLengthBounds value specification
  Just (partitionListExpr value minimumLength maximumLength)
reduceIntegerPartitions _ = Nothing

partitionLengthBounds :: Integer -> Expr -> Maybe (Integer, Integer)
partitionLengthBounds _ (Integer maximumLength)
  | maximumLength >= 0 = Just (0, maximumLength)
partitionLengthBounds _ (Call (Symbol "List") [Integer exactLength])
  | exactLength >= 0 = Just (exactLength, exactLength)
partitionLengthBounds _ (Call (Symbol "List") [Integer minimumLength, Integer maximumLength])
  | minimumLength >= 0 && maximumLength >= minimumLength =
      Just (minimumLength, maximumLength)
partitionLengthBounds _ _ = Nothing

partitionListExpr :: Integer -> Integer -> Integer -> Expr
partitionListExpr value minimumLength maximumLength
  | value < 0 = listExpr []
  | otherwise =
      listExpr
        [ listExpr (map Integer partition)
        | partition <- integerPartitions value value maximumLength
        , fromIntegral (length partition) >= minimumLength
        ]

integerPartitions :: Integer -> Integer -> Integer -> [[Integer]]
integerPartitions 0 _ _ = [[]]
integerPartitions _ _ maximumLength | maximumLength <= 0 = []
integerPartitions remaining maximumPart maximumLength =
  [ first : rest
  | first <- reverse [1 .. min maximumPart remaining]
  , rest <- integerPartitions (remaining - first) first (maximumLength - 1)
  ]

reduceFromDigits :: [Expr] -> Either Text Expr
reduceFromDigits [digits] = fromDigits digits 10
reduceFromDigits [digits, Integer base]
  | base >= 2 = fromDigits digits base
reduceFromDigits [_digits, _base] =
  Left "FromDigits expects an integer base >= 2."
reduceFromDigits _ =
  Left "FromDigits expects digits and an optional base."

fromDigits :: Expr -> Integer -> Either Text Expr
fromDigits (String source) base = do
  values <- traverse (characterDigit base) (T.unpack source)
  pure (Integer (foldl' (\result value -> result * base + value) 0 values))
fromDigits (Call (Symbol "List") digits) base = do
  values <-
    maybe
      (Left "FromDigits expects a list of explicit integer digits.")
      Right
      (integerArguments digits)
  pure (Integer (foldl' (\result value -> result * base + value) 0 values))
fromDigits _ _ = Left "FromDigits expects a string or a list of digits."

characterDigit :: Integer -> Char -> Either Text Integer
characterDigit base character =
  let upper = toUpper character
      value
        | character >= '0' && character <= '9' =
            Just (toInteger (fromEnum character - fromEnum '0'))
        | upper >= 'A' && upper <= 'Z' = Just (toInteger (fromEnum upper - fromEnum 'A' + 10))
        | otherwise = Nothing
   in case value of
        Just digit | digit < base && base <= 36 -> Right digit
        _ ->
          Left
            ( "FromDigits cannot interpret '"
                <> T.singleton character
                <> "' as a base-"
                <> T.pack (show base)
                <> " digit."
            )

reduceChineseRemainder :: [Expr] -> Either Text Expr
reduceChineseRemainder [residuesExpression, moduliExpression] = do
  residues <- integerList "residues" residuesExpression
  moduli <- integerList "moduli" moduliExpression
  if length residues /= length moduli
    then Left "ChineseRemainder expects residues and moduli of the same length."
    else Integer <$> foldMChinese (0, 1) (zip residues moduli)
reduceChineseRemainder _ =
  Left "ChineseRemainder expects two list arguments."

integerList :: Text -> Expr -> Either Text [Integer]
integerList description (Call (Symbol "List") values) =
  maybe
    (Left ("ChineseRemainder currently expects explicit integer " <> description <> "."))
    Right
    (integerArguments values)
integerList description _ =
  Left ("ChineseRemainder expects a list of " <> description <> ".")

foldMChinese :: (Integer, Integer) -> [(Integer, Integer)] -> Either Text Integer
foldMChinese (currentResidue, _) [] = Right currentResidue
foldMChinese (currentResidue, currentModulus) ((residue, signedModulus) : rest)
  | signedModulus == 0 = Left "ChineseRemainder moduli must be nonzero."
  | (residue - currentResidue) `mod` commonDivisor /= 0 =
      Left "ChineseRemainder system is inconsistent for the given residues and moduli."
  | otherwise = case modularInverse (currentModulus `div` commonDivisor) reducedModulus of
      Nothing -> Left "ChineseRemainder requires invertible reduced moduli."
      Just inverse ->
        let offset = ((residue - currentResidue) `div` commonDivisor * inverse) `mod` reducedModulus
            combinedModulus = currentModulus * reducedModulus
            combinedResidue = (currentResidue + currentModulus * offset) `mod` combinedModulus
         in foldMChinese (combinedResidue, combinedModulus) rest
 where
  modulus = abs signedModulus
  commonDivisor = gcd currentModulus modulus
  reducedModulus = modulus `div` commonDivisor

listExpr :: [Expr] -> Expr
listExpr = Call (Symbol "List")

booleanExpr :: Bool -> Expr
booleanExpr True = Symbol "True"
booleanExpr False = Symbol "False"

integerArguments :: [Expr] -> Maybe [Integer]
integerArguments = traverse $ \value -> case value of
  Integer integerValue -> Just integerValue
  _ -> Nothing

integerUnary :: (Integer -> Integer) -> [Expr] -> Maybe Expr
integerUnary function [Integer value] = Just (Integer (function value))
integerUnary _ _ = Nothing

constrainedIntegerUnary
  :: (Integer -> Bool)
  -> (Integer -> Integer)
  -> [Expr]
  -> Maybe Expr
constrainedIntegerUnary predicate function [Integer value]
  | predicate value = Just (Integer (function value))
constrainedIntegerUnary _ _ _ = Nothing

constrainedIntegerExprUnary
  :: (Integer -> Bool)
  -> (Integer -> Expr)
  -> [Expr]
  -> Maybe Expr
constrainedIntegerExprUnary predicate function [Integer value]
  | predicate value = Just (function value)
constrainedIntegerExprUnary _ _ _ = Nothing

integerBinary :: (Integer -> Integer -> Integer) -> [Expr] -> Maybe Expr
integerBinary function [Integer left, Integer right] = Just (Integer (function left right))
integerBinary _ _ = Nothing

integerVariadic :: ([Integer] -> Integer) -> [Expr] -> Maybe Expr
integerVariadic function values = Integer . function <$> integerArguments values

integerPredicate :: (Integer -> Bool) -> [Expr] -> Maybe Expr
integerPredicate predicate [Integer value] = Just (booleanExpr (predicate value))
integerPredicate _ _ = Nothing

reduceMultinomial :: [Expr] -> Maybe Expr
reduceMultinomial values = do
  integers <- integerArguments values
  if any (< 0) integers
    then Nothing
    else
      let total = sum integers
          denominator = product (map factorialInteger integers)
       in Just (Integer (factorialInteger total `div` denominator))

reduceJacobiSymbol :: [Expr] -> Maybe Expr
reduceJacobiSymbol [Integer numerator, Integer denominator]
  | denominator > 0 && odd denominator = Just (Integer (jacobiSymbol numerator denominator))
reduceJacobiSymbol _ = Nothing

jacobiSymbol :: Integer -> Integer -> Integer
jacobiSymbol numerator denominator = go (numerator `mod` denominator) denominator 1
 where
  go 0 currentDenominator result = if currentDenominator == 1 then result else 0
  go currentNumerator currentDenominator result =
    let (oddNumerator, powersOfTwo) = removeTwos currentNumerator (0 :: Integer)
        afterTwos
          | even powersOfTwo = result
          | currentDenominator `mod` 8 `elem` [3, 5] = negate result
          | otherwise = result
        afterReciprocity
          | oddNumerator `mod` 4 == 3 && currentDenominator `mod` 4 == 3 = negate afterTwos
          | otherwise = afterTwos
     in go (currentDenominator `mod` oddNumerator) oddNumerator afterReciprocity
  removeTwos value count
    | even value = removeTwos (value `div` 2) (count + 1)
    | otherwise = (value, count)

reduceKroneckerSymbol :: [Expr] -> Maybe Expr
reduceKroneckerSymbol [Integer numerator, Integer denominator] =
  Just (Integer (kroneckerSymbol numerator denominator))
reduceKroneckerSymbol _ = Nothing

kroneckerSymbol :: Integer -> Integer -> Integer
kroneckerSymbol numerator 0 = if abs numerator == 1 then 1 else 0
kroneckerSymbol _ 1 = 1
kroneckerSymbol numerator denominator
  | denominator < 0 =
      (if numerator < 0 then -1 else 1) * kroneckerSymbol numerator (abs denominator)
  | otherwise =
      let (oddDenominator, powersOfTwo) = removeTwos denominator (0 :: Integer)
          atTwo
            | even powersOfTwo = 1
            | even numerator = 0
            | numerator `mod` 8 `elem` [1, 7] = 1
            | otherwise = -1
          oddPart = if oddDenominator == 1 then 1 else jacobiSymbol numerator oddDenominator
       in atTwo * oddPart
 where
  removeTwos value count
    | even value = removeTwos (value `div` 2) (count + 1)
    | otherwise = (value, count)

bernoulliNumber :: Integer -> Fraction
bernoulliNumber index = snd (foldl' appendValue ([Fraction 1 1], Fraction 1 1) [1 .. index])
 where
  appendValue (previous, _) current =
    let weighted =
          [ multiplyFraction (binomialInteger (current + 1) position) value
          | (position, value) <- zip [0 ..] previous
          ]
        total = foldl' addFraction (Fraction 0 1) weighted
        next = multiplyFraction (-1) (divideFraction total (Fraction (current + 1) 1))
     in (previous <> [next], next)

eulerNumber :: Integer -> Integer
eulerNumber index = snd (foldl' appendValue ([1], 1) [1 .. index])
 where
  appendValue (previous, _) current
    | odd current = (previous <> [0], 0)
    | otherwise =
        let next =
              negate
                ( sum
                    [ binomialInteger current position * (previous !! fromInteger position)
                    | position <- [0, 2 .. current - 2]
                    ]
                )
         in (previous <> [next], next)

factorialInteger :: Integer -> Integer
factorialInteger value = product [1 .. value]

binomialInteger :: Integer -> Integer -> Integer
binomialInteger n k
  | k < 0 = 0
  | n >= 0 = if k > n then 0 else choose n k
  | otherwise = (if odd k then negate else id) (choose (k - n - 1) k)
 where
  choose upper lower =
    let selected = min lower (upper - lower)
     in product [upper - selected + 1 .. upper] `div` product [1 .. selected]

fibonacciInteger :: Integer -> Integer
fibonacciInteger value
  | value >= 0 = fst (fibonacciPair value)
  | otherwise =
      let positive = fst (fibonacciPair (abs value))
       in if even value then negate positive else positive

fibonacciPair :: Integer -> (Integer, Integer)
fibonacciPair 0 = (0, 1)
fibonacciPair value =
  let (a, b) = fibonacciPair (value `div` 2)
      c = a * (2 * b - a)
      d = a * a + b * b
   in if even value then (c, d) else (d, c + d)

lucasInteger :: Integer -> Integer
lucasInteger value =
  let magnitude = abs value
      (current, next) = fibonacciPair magnitude
      positive = 2 * next - current
   in if value < 0 && odd magnitude then negate positive else positive

reduceHarmonicNumber :: [Expr] -> Maybe Expr
reduceHarmonicNumber [Integer count]
  | count >= 0 = Just (fromFraction (harmonicFraction count 1))
reduceHarmonicNumber [Integer count, Integer order]
  | count >= 0 = Just (fromFraction (harmonicFraction count order))
reduceHarmonicNumber _ = Nothing

harmonicFraction :: Integer -> Integer -> Fraction
harmonicFraction count order =
  foldl' addFraction (Fraction 0 1)
    [ if order >= 0
        then Fraction 1 (index ^ order)
        else Fraction (index ^ abs order) 1
    | index <- [1 .. count]
    ]

reduceMod :: [Expr] -> Maybe Expr
reduceMod values = do
  integers <- integerArguments values
  case integers of
    [dividend, divisor]
      | divisor == 0 -> Just (Symbol "Indeterminate")
      | otherwise -> Just (Integer (dividend `mod` divisor))
    [dividend, divisor, offset]
      | divisor == 0 -> Just (Symbol "Indeterminate")
      | otherwise -> Just (Integer (offset + ((dividend - offset) `mod` divisor)))
    _ -> Nothing

reduceQuotient :: [Expr] -> Maybe Expr
reduceQuotient values = do
  integers <- integerArguments values
  case integers of
    [dividend, divisor] -> quotientWithOffset dividend divisor 0
    [dividend, divisor, offset] -> quotientWithOffset dividend divisor offset
    _ -> Nothing
 where
  quotientWithOffset dividend divisor offset
    | divisor == 0 =
        Just (Symbol (if dividend == 0 then "Indeterminate" else "ComplexInfinity"))
    | otherwise =
        let remainder = offset + ((dividend - offset) `mod` divisor)
         in Just (Integer ((dividend - remainder) `div` divisor))

reduceQuotientRemainder :: [Expr] -> Maybe Expr
reduceQuotientRemainder [Integer dividend, Integer divisor]
  | divisor /= 0 =
      let remainder = dividend `mod` divisor
          quotient = (dividend - remainder) `div` divisor
       in Just (listExpr [Integer quotient, Integer remainder])
reduceQuotientRemainder _ = Nothing

reduceKroneckerDelta :: [Expr] -> Maybe Expr
reduceKroneckerDelta values = do
  integers <- integerArguments values
  pure . Integer $ case integers of
    [] -> 1
    [value] -> if value == 0 then 1 else 0
    first : rest -> if all (== first) rest then 1 else 0

reduceDivisors :: [Expr] -> Maybe Expr
reduceDivisors [Integer value]
  | value /= 0 = Just (listExpr (map Integer (positiveDivisors (abs value))))
reduceDivisors _ = Nothing

positiveDivisors :: Integer -> [Integer]
positiveDivisors value = small <> large
 where
  (small, large) = collect 1 [] []
  collect candidate lower upper
    | candidate * candidate > value = (reverse lower, upper)
    | value `mod` candidate /= 0 = collect (candidate + 1) lower upper
    | candidate == value `div` candidate =
        collect (candidate + 1) (candidate : lower) upper
    | otherwise =
        collect (candidate + 1) (candidate : lower) (value `div` candidate : upper)

isPrimePower :: Integer -> Bool
isPrimePower value
  | value < 2 = False
  | otherwise = case factorInteger value of
      [_] -> True
      _ -> False

isPrime :: Integer -> Bool
isPrime value
  | value < 2 = False
  | value `elem` smallPrimes = True
  | any (\prime -> value `mod` prime == 0) smallPrimes = False
  | otherwise = millerRabin value witnesses
 where
  smallPrimes = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]
  witnesses
    | value < 2 ^ (64 :: Integer) = smallPrimes
    | otherwise = smallPrimes <> [41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97]

millerRabin :: Integer -> [Integer] -> Bool
millerRabin value = all passesWitness . filter (< value)
 where
  (powerOfTwo, oddPart) = factorTwos 0 (value - 1)
  factorTwos count remaining
    | even remaining = factorTwos (count + 1) (remaining `div` 2)
    | otherwise = (count, remaining)
  passesWitness witness =
    let initial = modularPower witness oddPart value
     in initial == 1
          || initial == value - 1
          || any (== value - 1) (take (powerOfTwo - 1) (drop 1 (iterate squareMod initial)))
  squareMod operand = (operand * operand) `mod` value

modularPower :: Integer -> Integer -> Integer -> Integer
modularPower base exponentValue modulus = go (base `mod` modulus) exponentValue 1
 where
  go _ 0 result = result
  go current exponent' result =
    let nextResult = if odd exponent' then (result * current) `mod` modulus else result
        nextCurrent = (current * current) `mod` modulus
     in go nextCurrent (exponent' `div` 2) nextResult

factorInteger :: Integer -> [(Integer, Integer)]
factorInteger value = factor (abs value) 2
 where
  factor 1 _ = []
  factor remaining candidate
    | candidate * candidate > remaining = [(remaining, 1)]
    | otherwise =
        let (exponentValue, quotient) = divideRepeatedly remaining candidate 0
            nextCandidate = if candidate == 2 then 3 else candidate + 2
         in (if exponentValue == 0 then [] else [(candidate, exponentValue)])
              <> factor quotient nextCandidate
  divideRepeatedly remaining candidate exponentValue
    | remaining `mod` candidate == 0 =
        divideRepeatedly (remaining `div` candidate) candidate (exponentValue + 1)
    | otherwise = (exponentValue, remaining)

eulerPhi :: Integer -> Integer
eulerPhi 1 = 1
eulerPhi value =
  foldl' (\result (prime, _) -> result - result `div` prime) value (factorInteger value)

moebiusMu :: Integer -> Integer
moebiusMu 1 = 1
moebiusMu value
  | any ((> 1) . snd) factors = 0
  | odd (length factors) = -1
  | otherwise = 1
 where
  factors = factorInteger value

liouvilleLambda :: Integer -> Integer
liouvilleLambda value =
  if odd (sum (map snd (factorInteger value))) then -1 else 1

carmichaelLambda :: Integer -> Integer
carmichaelLambda value = foldl' lcm 1 (map primePowerLambda (factorInteger value))
 where
  primePowerLambda (2, exponentValue)
    | exponentValue >= 3 = 2 ^ (exponentValue - 2)
  primePowerLambda (prime, exponentValue) =
    (prime - 1) * prime ^ (exponentValue - 1)

reduceJordanTotient :: [Expr] -> Maybe Expr
reduceJordanTotient [Integer order, Integer value]
  | order >= 0 && value > 0 = Just (Integer (jordanTotient order value))
reduceJordanTotient _ = Nothing

jordanTotient :: Integer -> Integer -> Integer
jordanTotient 0 value = if value == 1 then 1 else 0
jordanTotient order value =
  foldl'
    (\result (prime, _) -> result `div` (prime ^ order) * (prime ^ order - 1))
    (value ^ order)
    (factorInteger value)

ramanujanTau :: Integer -> Integer
ramanujanTau index = coefficients !! fromInteger degree
 where
  degree = index - 1
  initial = 1 : replicate (fromInteger degree) 0
  coefficients = foldl' multiplyFactor initial [1 .. degree]
  multiplyFactor current part =
    foldl' (accumulateTerm current part) (replicate (length current) 0) [0 .. degree]
  accumulateTerm current part next sourceIndex =
    let coefficient = current !! fromInteger sourceIndex
        maximumExponent = min 24 ((degree - sourceIndex) `div` part)
     in if coefficient == 0
          then next
          else
            foldl'
              (addExponent coefficient part sourceIndex)
              next
              [0 .. maximumExponent]
  addExponent coefficient part sourceIndex next exponentValue =
    let target = sourceIndex + part * exponentValue
        multiplier =
          (if odd exponentValue then negate else id)
            (binomialInteger 24 exponentValue)
        targetIndex = fromInteger target
        updated = next !! targetIndex + coefficient * multiplier
     in replaceAt targetIndex updated next

reduceDivisorSigma :: [Expr] -> Maybe Expr
reduceDivisorSigma [Integer order, Integer value]
  | value /= 0 =
      Just . fromFraction . foldl' addFraction (Fraction 0 1) $
        map (divisorPower order) (positiveDivisors (abs value))
 where
  divisorPower exponentValue divisor
    | exponentValue >= 0 = Fraction (divisor ^ exponentValue) 1
    | otherwise = Fraction 1 (divisor ^ abs exponentValue)
reduceDivisorSigma _ = Nothing

primePi :: Integer -> Integer
primePi upper = fromIntegral (length (filter isPrime [2 .. upper]))

nthPrime :: Integer -> Integer
nthPrime index = search 2 0
 where
  search candidate found
    | isPrime candidate && found + 1 == index = candidate
    | otherwise = search (candidate + 1) (if isPrime candidate then found + 1 else found)

reduceNextPrime :: [Expr] -> Maybe Expr
reduceNextPrime [Integer value] = Just (Integer (nextPrime value 1))
reduceNextPrime [Integer value, Integer offset] = Just (Integer (nextPrime value offset))
reduceNextPrime _ = Nothing

nextPrime :: Integer -> Integer -> Integer
nextPrime value 0 = value
nextPrime value offset
  | offset > 0 = walkForward (value + 1) offset
  | otherwise = walkBackward (value - 1) (abs offset)
 where
  walkForward candidate remaining
    | isPrime candidate = if remaining == 1 then candidate else walkForward (candidate + 1) (remaining - 1)
    | otherwise = walkForward (candidate + 1) remaining
  walkBackward candidate remaining
    | candidate < 2 = 2 - remaining
    | isPrime candidate = if remaining == 1 then candidate else walkBackward (candidate - 1) (remaining - 1)
    | otherwise = walkBackward (candidate - 1) remaining

reducePowerMod :: [Expr] -> Maybe Expr
reducePowerMod [Integer base, Integer exponentValue, Integer modulusValue]
  | modulusValue /= 0 = do
      let modulus = abs modulusValue
      effectiveBase <-
        if exponentValue < 0
          then modularInverse base modulus
          else Just base
      Just (Integer (modularPower effectiveBase (abs exponentValue) modulus))
reducePowerMod _ = Nothing

reduceModularInverse :: [Expr] -> Maybe Expr
reduceModularInverse [Integer value, Integer modulusValue]
  | modulusValue /= 0 = Integer <$> modularInverse value (abs modulusValue)
reduceModularInverse _ = Nothing

modularInverse :: Integer -> Integer -> Maybe Integer
modularInverse value modulus =
  let (divisor, coefficient, _) = extendedGcd value modulus
   in if abs divisor == 1 then Just ((coefficient * signum divisor) `mod` modulus) else Nothing

extendedGcd :: Integer -> Integer -> (Integer, Integer, Integer)
extendedGcd left 0 = (left, 1, 0)
extendedGcd left right =
  let (divisor, coefficient, otherCoefficient) = extendedGcd right (left `mod` right)
   in (divisor, otherCoefficient, coefficient - (left `div` right) * otherCoefficient)

reduceMultiplicativeOrder :: [Expr] -> Maybe Expr
reduceMultiplicativeOrder [Integer value, Integer modulus]
  | modulus > 0 && gcd value modulus == 1 =
      Just (Integer (multiplicativeOrder value modulus))
reduceMultiplicativeOrder _ = Nothing

multiplicativeOrder :: Integer -> Integer -> Integer
multiplicativeOrder value modulus = search 1 (value `mod` modulus)
 where
  search exponentValue residue
    | residue == 1 = exponentValue
    | otherwise = search (exponentValue + 1) ((residue * value) `mod` modulus)

reducePrimitiveRoot :: [Expr] -> Maybe Expr
reducePrimitiveRoot [Integer modulus]
  | modulus > 1 = Integer <$> firstPrimitiveRoot modulus
reducePrimitiveRoot _ = Nothing

firstPrimitiveRoot :: Integer -> Maybe Integer
firstPrimitiveRoot modulus = findCandidate 1
 where
  targetOrder = eulerPhi modulus
  findCandidate candidate
    | candidate >= modulus = Nothing
    | gcd candidate modulus == 1
        && multiplicativeOrder candidate modulus == targetOrder = Just candidate
    | otherwise = findCandidate (candidate + 1)

reduceIntegerLength :: [Expr] -> Maybe Expr
reduceIntegerLength [Integer value] = Just (Integer (integerLength value 10))
reduceIntegerLength [Integer value, Integer base]
  | base >= 2 = Just (Integer (integerLength value base))
reduceIntegerLength _ = Nothing

integerLength :: Integer -> Integer -> Integer
integerLength 0 _ = 0
integerLength value base = go (abs value) 0
 where
  go 0 count = count
  go remaining count = go (remaining `div` base) (count + 1)

reduceIntegerDigits :: [Expr] -> Maybe Expr
reduceIntegerDigits [Integer value] = Just (digitsExpr value 10)
reduceIntegerDigits [Integer value, Integer base]
  | base >= 2 = Just (digitsExpr value base)
reduceIntegerDigits [Integer value, Integer base, Integer width]
  | base >= 2 && width >= 0 =
      let digits = integerDigits value base
          selected
            | width == 0 = digits
            | fromIntegral (length digits) > width = drop (length digits - fromIntegral width) digits
            | otherwise = replicate (fromIntegral width - length digits) 0 <> digits
       in Just (listExpr (map Integer selected))
reduceIntegerDigits _ = Nothing

digitsExpr :: Integer -> Integer -> Expr
digitsExpr value base = listExpr (map Integer (integerDigits value base))

integerDigits :: Integer -> Integer -> [Integer]
integerDigits 0 _ = [0]
integerDigits value base = reverse (go (abs value))
 where
  go 0 = []
  go remaining = remaining `mod` base : go (remaining `div` base)

reduceIntegerReverse :: [Expr] -> Maybe Expr
reduceIntegerReverse [Integer value] = Just (Integer (integerReverse value 10))
reduceIntegerReverse [Integer value, Integer base]
  | base >= 2 = Just (Integer (integerReverse value base))
reduceIntegerReverse _ = Nothing

integerReverse :: Integer -> Integer -> Integer
integerReverse value base =
  foldl' (\result digit -> result * base + digit) 0 (reverse (integerDigits value base))

reduceDigitCount :: [Expr] -> Maybe Expr
reduceDigitCount [Integer value] = Just (digitCountExpr value 10)
reduceDigitCount [Integer value, Integer base]
  | base >= 2 = Just (digitCountExpr value base)
reduceDigitCount [Integer value, Integer base, Integer digit]
  | base >= 2 && digit >= 0 && digit < base =
      Just (Integer (countDigit value base digit))
reduceDigitCount _ = Nothing

digitCountExpr :: Integer -> Integer -> Expr
digitCountExpr value base =
  listExpr
    [ Integer (countDigit value base digit)
    | digit <- [1 .. base - 1] <> [0]
    ]

countDigit :: Integer -> Integer -> Integer -> Integer
countDigit value base target =
  fromIntegral (length (filter (== target) (integerDigits value base)))

reduceBitShift :: Bool -> [Expr] -> Maybe Expr
reduceBitShift leftMode [Integer value] =
  Just (Integer (if leftMode then shiftL value 1 else shiftR value 1))
reduceBitShift leftMode [Integer value, Integer count]
  | count >= 0 =
      Just . Integer $
        if leftMode
          then shiftL value (fromInteger count)
          else shiftR value (fromInteger count)
  | otherwise =
      Just . Integer $
        if leftMode
          then shiftR value (fromInteger (abs count))
          else shiftL value (fromInteger (abs count))
reduceBitShift _ _ = Nothing

reduceBitMutation :: Bool -> [Expr] -> Maybe Expr
reduceBitMutation setMode [Integer value, Integer index]
  | index >= 0 =
      let mask = shiftL 1 (fromInteger index)
       in Just (Integer (if setMode then value .|. mask else value .&. complement mask))
reduceBitMutation _ _ = Nothing

reduceBitGet :: [Expr] -> Maybe Expr
reduceBitGet [Integer value, Integer index]
  | index >= 0 = Just (Integer ((shiftR value (fromInteger index)) .&. 1))
reduceBitGet _ = Nothing

integerBitLength :: Integer -> Integer
integerBitLength value = go effective 0
 where
  effective = if value >= 0 then value else complement value
  go 0 count = count
  go remaining count = go (shiftR remaining 1) (count + 1)

partitionCount :: Bool -> Integer -> Integer
partitionCount _ value | value < 0 = 0
partitionCount distinct value = last (foldl' addPart initial [1 .. value])
 where
  size = fromInteger value + 1
  initial = 1 : replicate (size - 1) 0
  addPart counts part =
    let targets
          | distinct = reverse [part .. value]
          | otherwise = [part .. value]
     in foldl' (updateCount part) counts targets
  updateCount part counts target =
    let targetIndex = fromInteger target
        sourceIndex = fromInteger (target - part)
        updated = counts !! targetIndex + counts !! sourceIndex
     in replaceAt targetIndex updated counts

replaceAt :: Int -> value -> [value] -> [value]
replaceAt 0 value (_ : suffix) = value : suffix
replaceAt index value (first : suffix) = first : replaceAt (index - 1) value suffix
replaceAt _ _ [] = []

data Fraction = Fraction !Integer !Integer
  deriving (Eq, Show)

normalizeFraction :: Fraction -> Fraction
normalizeFraction (Fraction numerator denominator) =
  let sign = if denominator < 0 then -1 else 1
      divisor = gcd numerator denominator
   in Fraction (sign * numerator `div` divisor) (abs denominator `div` divisor)

addFraction :: Fraction -> Fraction -> Fraction
addFraction (Fraction leftNumerator leftDenominator) (Fraction rightNumerator rightDenominator) =
  normalizeFraction
    ( Fraction
        (leftNumerator * rightDenominator + rightNumerator * leftDenominator)
        (leftDenominator * rightDenominator)
    )

multiplyFraction :: Integer -> Fraction -> Fraction
multiplyFraction multiplier (Fraction numerator denominator) =
  normalizeFraction (Fraction (multiplier * numerator) denominator)

divideFraction :: Fraction -> Fraction -> Fraction
divideFraction (Fraction leftNumerator leftDenominator) (Fraction rightNumerator rightDenominator) =
  normalizeFraction
    (Fraction (leftNumerator * rightDenominator) (leftDenominator * rightNumerator))

fromFraction :: Fraction -> Expr
fromFraction value = case normalizeFraction value of
  Fraction numerator 1 -> Integer numerator
  Fraction numerator denominator -> Rational numerator denominator
