{-# LANGUAGE OverloadedStrings #-}

module Tungsten.NumericAlgebraTests (checkNumericAlgebraEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkNumericAlgebraEvaluator :: IO Bool
checkNumericAlgebraEvaluator = do
  valueResults <- traverse checkValue valueCases
  errorResults <- traverse checkError errorCases
  pure (and (valueResults <> errorResults))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ( "integer combinatorics and signed sequences"
    , "{Binomial[-3,2],Binomial[3,-2],Multinomial[2,3,4],Fibonacci[-6],LucasL[-6]}"
    , "List[6, 0, 1260, -8, 18]"
    )
  , ( "exact harmonic numbers"
    , "{HarmonicNumber[0],HarmonicNumber[5],HarmonicNumber[5,2],HarmonicNumber[3,-2]}"
    , "List[0, Rational[137, 60], Rational[5269, 3600], 14]"
    )
  , ( "integer step sign and ramp functions"
    , "{UnitStep[],UnitStep[-1,0],Unitize[0],Unitize[-9],RealSign[-3],RealAbs[-3],Ramp[-3]}"
    , "List[1, 0, 0, 1, -1, 3, 0]"
    )
  , ( "modulus quotient and zero divisors"
    , "{Mod[-14,5],Mod[14,5,-1],Mod[1,0],Quotient[-14,5],Quotient[0,0],Quotient[1,0],QuotientRemainder[-14,5]}"
    , "List[1, -1, Indeterminate, -3, Indeterminate, ComplexInfinity, List[-3, 1]]"
    )
  , ( "delta gcd and lcm identities"
    , "{KroneckerDelta[],KroneckerDelta[0],KroneckerDelta[3,3,3],DiscreteDelta[],DiscreteDelta[0,1],GCD[],GCD[-12,18,30],LCM[],LCM[-4,6,0]}"
    , "List[1, 1, 1, 1, 0, 0, 6, 1, 0]"
    )
  , ( "divisors and prime predicates"
    , "{Divisors[-12],PrimeQ[1000000007],PrimeQ[1000000008],CompositeQ[1],CompositeQ[8],PrimePowerQ[27],PrimePowerQ[12]}"
    , "List[List[1, 2, 3, 4, 6, 12], True, False, False, True, True, False]"
    )
  , ( "multiplicative arithmetic functions"
    , "{EulerPhi[12],CarmichaelLambda[12],MoebiusMu[6],MoebiusMu[12],LiouvilleLambda[18],JordanTotient[2,10],DivisorSigma[2,6],DivisorSigma[-1,6]}"
    , "List[4, 2, 1, 0, -1, 72, 50, 2]"
    )
  , ( "prime navigation"
    , "{PrimePi[100],Prime[10],NextPrime[10],NextPrime[10,3],NextPrime[10,-2],NextPrime[7,0]}"
    , "List[25, 29, 11, 17, 5, 7]"
    )
  , ( "modular powers inverses and order"
    , "{PowerMod[3,5,7],PowerMod[3,-1,7],PowerMod[2,-1,4],ModularInverse[3,7],ModularInverse[2,4],MultiplicativeOrder[2,7],MultiplicativeOrder[2,6]}"
    , "List[5, 5, PowerMod[2, -1, 4], 5, ModularInverse[2, 4], 3, MultiplicativeOrder[2, 6]]"
    )
  , ( "integer digit projections"
    , "{IntegerLength[0],IntegerLength[12345],IntegerDigits[12345],IntegerDigits[12345,16],IntegerDigits[12,2,8],IntegerReverse[-1234],DigitCount[1122],DigitCount[16,2],DigitCount[16,2,0]}"
    , "List[0, 5, List[1, 2, 3, 4, 5], List[3, 0, 3, 9], List[0, 0, 0, 0, 1, 1, 0, 0], 4321, List[2, 2, 0, 0, 0, 0, 0, 0, 0, 0], List[1, 4], 4]"
    )
  , ( "arbitrary precision bit operations"
    , "{BitAnd[],BitAnd[12,10],BitOr[],BitOr[12,10],BitXor[12,10],BitShiftLeft[3,2],BitShiftLeft[16,-2],BitShiftRight[-8,2],BitNot[0],BitClear[15,2],BitSet[8,1],BitGet[-2,1],BitLength[-8]}"
    , "List[-1, 8, 0, 14, 6, 12, 4, -2, -1, 11, 10, 1, 3]"
    )
  , ( "integer partition counts"
    , "{PartitionsP[-1],PartitionsP[0],PartitionsP[10],PartitionsQ[-1],PartitionsQ[0],PartitionsQ[10]}"
    , "List[0, 1, 42, 0, 1, 10]"
    )
  , ( "unsupported domains remain symbolic"
    , "{GCD[2,x],Divisors[0],EulerPhi[0],Prime[0],IntegerDigits[2,1],HarmonicNumber[-1]}"
    , "List[GCD[2, x], Divisors[0], EulerPhi[0], Prime[0], IntegerDigits[2, 1], HarmonicNumber[-1]]"
    )
  , ( "qualified System dispatch and Global isolation"
    , "{System`GCD[12,18],System`PrimeQ[7],Global`GCD[12,18]}"
    , "List[6, True, Global`GCD[12, 18]]"
    )
  , ( "exact rational and bounded integer factorization"
    , "{FactorInteger[-12],FactorInteger[18/35],FactorInteger[0],FactorInteger[1],FactorInteger[-1],FactorInteger[210,2],FactorInteger[210,5],FactorInteger[12,GaussianIntegers->False]}"
    , "List[List[List[-1, 1], List[2, 2], List[3, 1]], List[List[2, 1], List[3, 2], List[5, -1], List[7, -1]], List[List[0, 1]], List[List[1, 1]], List[List[-1, 1]], List[List[2, 1], List[105, 1]], List[List[2, 1], List[3, 1], List[5, 1], List[7, 1]], List[List[2, 2], List[3, 1]]]"
    )
  , ( "integer exponent and continued fractions"
    , "{IntegerExponent[1000],IntegerExponent[-81,-3],IntegerExponent[0,10],ContinuedFraction[415/93],ContinuedFraction[415/93,2],ContinuedFraction[-415/93],FromContinuedFraction[{4,2,6,7}],FromContinuedFraction[{}],FromContinuedFraction[{1,0}]}"
    , "List[3, 4, Infinity, List[4, 2, 6, 7], List[4, 2], List[-4, -2, -6, -7], Rational[415, 93], Infinity, ComplexInfinity]"
    )
  , ( "integer partition enumeration"
    , "{IntegerPartitions[-1],IntegerPartitions[0],IntegerPartitions[4],IntegerPartitions[4,2],IntegerPartitions[4,{2}],IntegerPartitions[4,{1,2}]}"
    , "List[List[], List[List[]], List[List[4], List[3, 1], List[2, 2], List[2, 1, 1], List[1, 1, 1, 1]], List[List[4], List[3, 1], List[2, 2]], List[List[3, 1], List[2, 2]], List[List[4], List[3, 1], List[2, 2]]]"
    )
  , ( "digit reconstruction and generalized Chinese remainder"
    , "{FromDigits[{}],FromDigits[{1,2,3,4}],FromDigits[{1,2,3,4},16],FromDigits[\"abc\",16],FromDigits[{2,-1},10],ChineseRemainder[{2,3,2},{3,5,7}],ChineseRemainder[{1,3},{2,4}],ChineseRemainder[{},{}]}"
    , "List[0, 1234, 4660, 2748, 19, 23, 3, 0]"
    )
  , ( "qualified structural numeric reducers"
    , "{System`FactorInteger[12],System`ContinuedFraction[10/7],System`FromDigits[{1,0,1},2],System`ChineseRemainder[{2,3},{3,5}]}"
    , "List[List[List[2, 2], List[3, 1]], List[1, 2, 3], 5, 8]"
    )
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ( "FromDigits arity"
    , "FromDigits[]"
    , "FromDigits expects digits and an optional base."
    )
  , ( "FromDigits base domain"
    , "FromDigits[{1,2},1]"
    , "FromDigits expects an integer base >= 2."
    )
  , ( "FromDigits string digit domain"
    , "FromDigits[\"g\",16]"
    , "FromDigits cannot interpret 'g' as a base-16 digit."
    )
  , ( "FromDigits list element domain"
    , "FromDigits[{1,x},10]"
    , "FromDigits expects a list of explicit integer digits."
    )
  , ( "FromDigits subject domain"
    , "FromDigits[x]"
    , "FromDigits expects a string or a list of digits."
    )
  , ( "ChineseRemainder arity"
    , "ChineseRemainder[]"
    , "ChineseRemainder expects two list arguments."
    )
  , ( "ChineseRemainder residue shape"
    , "ChineseRemainder[x,{3}]"
    , "ChineseRemainder expects a list of residues."
    )
  , ( "ChineseRemainder lengths"
    , "ChineseRemainder[{1},{2,3}]"
    , "ChineseRemainder expects residues and moduli of the same length."
    )
  , ( "ChineseRemainder integer moduli"
    , "ChineseRemainder[{1},{x}]"
    , "ChineseRemainder currently expects explicit integer moduli."
    )
  , ( "ChineseRemainder nonzero moduli"
    , "ChineseRemainder[{1},{0}]"
    , "ChineseRemainder moduli must be nonzero."
    )
  , ( "ChineseRemainder consistency"
    , "ChineseRemainder[{0,1},{2,4}]"
    , "ChineseRemainder system is inconsistent for the given residues and moduli."
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

checkError :: (Text, Text, Text) -> IO Bool
checkError (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left (EvaluationError actual)
      | actual == expected -> pure True
      | otherwise -> failCheck label ("expected error " <> expected <> ", got " <> actual)
    Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAILED numeric algebra evaluator: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
