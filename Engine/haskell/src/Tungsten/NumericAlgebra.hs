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
import Data.Text (Text)
import Tungsten.Expression (Expr (..))

-- | Attempt one exact numeric reduction.  The outer 'Either' is reserved for
-- Python-compatible diagnostics from structurally invalid constructors; the
-- ordinary unsupported-domain result is @Right Nothing@.
reduceNumericBuiltin :: Text -> [Expr] -> Either Text (Maybe Expr)
reduceNumericBuiltin headName arguments' = Right $ case headName of
  "Binomial" -> integerBinary binomialInteger arguments'
  "Multinomial" -> reduceMultinomial arguments'
  "Fibonacci" -> integerUnary fibonacciInteger arguments'
  "LucasL" -> integerUnary lucasInteger arguments'
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
  "DivisorSigma" -> reduceDivisorSigma arguments'
  "PrimePi" -> constrainedIntegerUnary (>= 0) primePi arguments'
  "Prime" -> constrainedIntegerUnary (>= 1) nthPrime arguments'
  "NextPrime" -> reduceNextPrime arguments'
  "PowerMod" -> reducePowerMod arguments'
  "ModularInverse" -> reduceModularInverse arguments'
  "MultiplicativeOrder" -> reduceMultiplicativeOrder arguments'
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

fromFraction :: Fraction -> Expr
fromFraction value = case normalizeFraction value of
  Fraction numerator 1 -> Integer numerator
  Fraction numerator denominator -> Rational numerator denominator
