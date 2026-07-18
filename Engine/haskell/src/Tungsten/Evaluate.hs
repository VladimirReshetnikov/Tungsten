{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Conservative, kernel-free evaluation of Wolfram expression trees.
--
-- Supported built-ins reduce deterministically.  Unknown or unsupported forms
-- remain symbolic, which makes partial evaluation safe for automation clients.
module Tungsten.Evaluate
  ( EvaluationError (..)
  , evaluate
  ) where

import Control.Monad (foldM)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Tungsten.Expression

newtype EvaluationError = EvaluationError {evaluationErrorMessage :: Text}
  deriving (Eq, Show)

-- | Evaluate an expression to a fixed point, with a depth guard for malformed
-- self-referential transformations.
evaluate :: Expr -> Either EvaluationError Expr
evaluate = evaluateAt 0

evaluateAt :: Int -> Expr -> Either EvaluationError Expr
evaluateAt depth expression
  | depth > 1024 = Left (EvaluationError "the evaluation recursion limit was exceeded")
  | otherwise = case expression of
      Call (Symbol "Hold") _ -> Right expression
      Call (Symbol "HoldForm") _ -> Right expression
      Call (Symbol "Unevaluated") _ -> Right expression
      Call (Symbol "Function") _ -> Right expression
      Call (Symbol "SetDelayed") _ -> Right expression
      Call (Symbol "RuleDelayed") _ -> Right expression
      Call (Symbol "If") arguments' -> evaluateIf depth arguments'
      Call (Symbol "And") arguments' -> evaluateAnd depth arguments'
      Call (Symbol "Or") arguments' -> evaluateOr depth arguments'
      Call expressionHead arguments' -> do
        evaluatedHead <- evaluateAt (depth + 1) expressionHead
        evaluatedArguments <- traverse (evaluateAt (depth + 1)) arguments'
        let evaluatedCall = Call evaluatedHead evaluatedArguments
        reduced <- reduceCall evaluatedCall
        if reduced == evaluatedCall
          then Right reduced
          else evaluateAt (depth + 1) reduced
      _ -> Right expression

evaluateIf :: Int -> [Expr] -> Either EvaluationError Expr
evaluateIf depth = \case
  condition : trueBranch : remaining -> do
    evaluatedCondition <- evaluateAt (depth + 1) condition
    case evaluatedCondition of
      Symbol "True" -> evaluateAt (depth + 1) trueBranch
      Symbol "False" -> case remaining of
        falseBranch : _ -> evaluateAt (depth + 1) falseBranch
        [] -> Right (Symbol "Null")
      _ -> Right (Call (Symbol "If") (evaluatedCondition : trueBranch : remaining))
  arguments' -> Right (Call (Symbol "If") arguments')

evaluateAnd :: Int -> [Expr] -> Either EvaluationError Expr
evaluateAnd depth = go []
 where
  go retained [] = Right $ case retained of
    [] -> Symbol "True"
    [single] -> single
    values -> Call (Symbol "And") values
  go retained (value : rest) = do
    evaluated <- evaluateAt (depth + 1) value
    case evaluated of
      Symbol "False" -> Right (Symbol "False")
      Symbol "True" -> go retained rest
      _ -> go (retained <> [evaluated]) rest

evaluateOr :: Int -> [Expr] -> Either EvaluationError Expr
evaluateOr depth = go []
 where
  go retained [] = Right $ case retained of
    [] -> Symbol "False"
    [single] -> single
    values -> Call (Symbol "Or") values
  go retained (value : rest) = do
    evaluated <- evaluateAt (depth + 1) value
    case evaluated of
      Symbol "True" -> Right (Symbol "True")
      Symbol "False" -> go retained rest
      _ -> go (retained <> [evaluated]) rest

reduceCall :: Expr -> Either EvaluationError Expr
reduceCall expression = case expression of
  Call (Call (Symbol "Function") functionArguments) values ->
    applyFunction functionArguments values
  Call (Symbol headName) values -> reduceBuiltin headName values
  _ -> Right expression

reduceBuiltin :: Text -> [Expr] -> Either EvaluationError Expr
reduceBuiltin headName values = case headName of
  "Plus" -> Right (reducePlus values)
  "Times" -> Right (reduceTimes values)
  "Power" -> Right (reducePower values)
  "Factorial" -> Right (reduceFactorial values)
  "Factorial2" -> Right (reduceFactorial2 values)
  "Abs" -> Right (reduceAbs values)
  "Sign" -> Right (reduceSign values)
  "Not" -> Right (reduceNot values)
  "Equal" -> Right (reduceEquality True values)
  "Unequal" -> Right (reduceEquality False values)
  "SameQ" -> Right (boolean (allEqual values))
  "UnsameQ" -> Right (boolean (allDistinct values))
  "Less" -> Right (reduceOrdering (<) headName values)
  "LessEqual" -> Right (reduceOrdering (<=) headName values)
  "Greater" -> Right (reduceOrdering (>) headName values)
  "GreaterEqual" -> Right (reduceOrdering (>=) headName values)
  "Inequality" -> Right (reduceInequality values)
  "Head" -> Right (unary headName headExpr values)
  "Length" -> Right (unary headName (Integer . fromIntegral . length . arguments) values)
  "Depth" -> Right (unary headName (Integer . fromIntegral . expressionDepth) values)
  "AtomQ" -> Right (unary headName (boolean . isAtom) values)
  "ListQ" -> Right (unary headName (boolean . hasHead "List") values)
  "IntegerQ" -> Right (unary headName (boolean . isInteger) values)
  "NumberQ" -> Right (unary headName (boolean . isNumber) values)
  "StringQ" -> Right (unary headName (boolean . isString) values)
  "First" -> Right (reduceFirstLast True headName values)
  "Last" -> Right (reduceFirstLast False headName values)
  "Rest" -> Right (reduceRestMost True headName values)
  "Most" -> Right (reduceRestMost False headName values)
  "Part" -> reducePart values
  "Range" -> Right (reduceRange values)
  "Total" -> Right (reduceTotal values)
  "Accumulate" -> Right (reduceAccumulate values)
  "Reverse" -> Right (unaryCallArguments headName reverse values)
  "Join" -> Right (reduceJoin values)
  "Map" -> Right (reduceMap values)
  "Apply" -> Right (reduceApply values)
  "ReplaceAll" -> Right (reduceReplaceAll values)
  "CompoundExpression" -> Right (if null values then Symbol "Null" else last values)
  _ -> Right (Call (Symbol headName) values)

data Exact = Exact !Integer !Integer
  deriving (Eq, Ord, Show)

toExact :: Expr -> Maybe Exact
toExact (Integer value) = Just (Exact value 1)
toExact (Rational numerator denominator) = Just (normalizeExact numerator denominator)
toExact _ = Nothing

fromExact :: Exact -> Expr
fromExact (Exact numerator denominator)
  | denominator == 1 = Integer numerator
  | otherwise = Rational numerator denominator

normalizeExact :: Integer -> Integer -> Exact
normalizeExact numerator denominator =
  let sign = if denominator < 0 then -1 else 1
      divisor = gcd numerator denominator
   in Exact (sign * numerator `div` divisor) (abs denominator `div` divisor)

addExact :: Exact -> Exact -> Exact
addExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  normalizeExact
    (leftNumerator * rightDenominator + rightNumerator * leftDenominator)
    (leftDenominator * rightDenominator)

multiplyExact :: Exact -> Exact -> Exact
multiplyExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  normalizeExact (leftNumerator * rightNumerator) (leftDenominator * rightDenominator)

reducePlus :: [Expr] -> Expr
reducePlus originalValues =
  let values = concatMap (flattenHead "Plus") originalValues
      exactSum = foldl' addExact (Exact 0 1) (mapMaybe toExact values)
      symbolic = filter (not . isExact) values
      combined = (if exactSum == Exact 0 1 then [] else [fromExact exactSum]) <> symbolic
   in case combined of
        [] -> Integer 0
        [single] -> single
        _ -> Call (Symbol "Plus") combined

reduceTimes :: [Expr] -> Expr
reduceTimes originalValues =
  let values = concatMap (flattenHead "Times") originalValues
      exactProduct = foldl' multiplyExact (Exact 1 1) (mapMaybe toExact values)
      symbolic = filter (not . isExact) values
      combined
        | exactProduct == Exact 0 1 = [Integer 0]
        | exactProduct == Exact 1 1 && not (null symbolic) = symbolic
        | otherwise = fromExact exactProduct : symbolic
   in case combined of
        [] -> Integer 1
        [single] -> single
        _ -> Call (Symbol "Times") combined

reducePower :: [Expr] -> Expr
reducePower [base, Integer exponentValue]
  | exponentValue == 0 = Integer 1
  | exponentValue == 1 = base
  | Just (Exact numerator denominator) <- toExact base =
      if exponentValue > 0
        then fromExact (normalizeExact (numerator ^ exponentValue) (denominator ^ exponentValue))
        else
          if numerator == 0
            then Call (Symbol "Power") [base, Integer exponentValue]
            else
              fromExact
                ( normalizeExact
                    (denominator ^ abs exponentValue)
                    (numerator ^ abs exponentValue)
                )
reducePower values = Call (Symbol "Power") values

reduceFactorial :: [Expr] -> Expr
reduceFactorial [Integer value]
  | value >= 0 = Integer (product [1 .. value])
reduceFactorial values = Call (Symbol "Factorial") values

reduceFactorial2 :: [Expr] -> Expr
reduceFactorial2 [Integer value]
  | value >= -1 = Integer (product [value, value - 2 .. 1])
reduceFactorial2 values = Call (Symbol "Factorial2") values

reduceAbs :: [Expr] -> Expr
reduceAbs [value]
  | Just (Exact numerator denominator) <- toExact value =
      fromExact (Exact (abs numerator) denominator)
reduceAbs values = Call (Symbol "Abs") values

reduceSign :: [Expr] -> Expr
reduceSign [value]
  | Just (Exact numerator _) <- toExact value = Integer (signum numerator)
reduceSign values = Call (Symbol "Sign") values

reduceNot :: [Expr] -> Expr
reduceNot [Symbol "True"] = Symbol "False"
reduceNot [Symbol "False"] = Symbol "True"
reduceNot [Call (Symbol "Not") [value]] = value
reduceNot values = Call (Symbol "Not") values

reduceEquality :: Bool -> [Expr] -> Expr
reduceEquality True values
  | length values < 2 = Symbol "True"
  | allEqual values = Symbol "True"
  | all isExact values = Symbol "False"
  | otherwise = Call (Symbol "Equal") values
reduceEquality False values
  | length values < 2 = Symbol "True"
  | not (allDistinct values) = Symbol "False"
  | all isExact values = Symbol "True"
  | otherwise = Call (Symbol "Unequal") values

reduceOrdering :: (Exact -> Exact -> Bool) -> Text -> [Expr] -> Expr
reduceOrdering relation headName values
  | length values < 2 = Symbol "True"
  | Just exactValues <- traverse toExact values =
      boolean (and (zipWith relation exactValues (drop 1 exactValues)))
  | otherwise = Call (Symbol headName) values

reduceInequality :: [Expr] -> Expr
reduceInequality values
  | length values < 3 || even (length values) = Call (Symbol "Inequality") values
  | otherwise =
      let triples = inequalityTriples values
          results = map evaluateTriple triples
       in if all (== Just True) results
            then Symbol "True"
            else
              if any (== Just False) results
                then Symbol "False"
                else Call (Symbol "Inequality") values
 where
  inequalityTriples (left : Symbol comparison : right : rest) =
    (left, comparison, right) : inequalityTriples (right : rest)
  inequalityTriples _ = []
  evaluateTriple (left, comparison, right) = do
    exactLeft <- toExact left
    exactRight <- toExact right
    relation <- case comparison of
      "Less" -> Just (<)
      "LessEqual" -> Just (<=)
      "Greater" -> Just (>)
      "GreaterEqual" -> Just (>=)
      "Equal" -> Just (==)
      "Unequal" -> Just (/=)
      _ -> Nothing
    pure (relation exactLeft exactRight)

unary :: Text -> (Expr -> Expr) -> [Expr] -> Expr
unary _ function [value] = function value
unary headName _ values = Call (Symbol headName) values

unaryCallArguments :: Text -> ([Expr] -> [Expr]) -> [Expr] -> Expr
unaryCallArguments _ function [Call expressionHead values] = Call expressionHead (function values)
unaryCallArguments headName _ values = Call (Symbol headName) values

reduceFirstLast :: Bool -> Text -> [Expr] -> Expr
reduceFirstLast first _ [Call _ (value : remaining)] =
  if first then value else foldl' (\_ next -> next) value remaining
reduceFirstLast _ headName values = Call (Symbol headName) values

reduceRestMost :: Bool -> Text -> [Expr] -> Expr
reduceRestMost rest _ [Call expressionHead values@(_ : _)] =
  Call expressionHead (if rest then drop 1 values else reverse (drop 1 (reverse values)))
reduceRestMost _ headName values = Call (Symbol headName) values

reducePart :: [Expr] -> Either EvaluationError Expr
reducePart [] = Right (Call (Symbol "Part") [])
reducePart (target : indices) = foldM selectPart target indices
 where
  selectPart expression (Integer 0) = Right (headExpr expression)
  selectPart (Call _ values) (Integer index) =
    let resolved = if index > 0 then index - 1 else fromIntegral (length values) + index
     in if resolved >= 0 && resolved < fromIntegral (length values)
          then Right (values !! fromIntegral resolved)
          else Left (EvaluationError "a Part index is out of range")
  selectPart expression index = Right (Call (Symbol "Part") [expression, index])

reduceRange :: [Expr] -> Expr
reduceRange values = case traverse integerValue values of
  Just [end] -> list (integerRange 1 end 1)
  Just [start, end] -> list (integerRange start end 1)
  Just [start, end, step] | step /= 0 -> list (integerRange start end step)
  _ -> Call (Symbol "Range") values
 where
  integerRange start end step
    | step > 0 && start <= end = map Integer [start, start + step .. end]
    | step < 0 && start >= end = map Integer [start, start + step .. end]
    | otherwise = []

reduceTotal :: [Expr] -> Expr
reduceTotal [Call (Symbol "List") values] = reducePlus values
reduceTotal values = Call (Symbol "Total") values

reduceAccumulate :: [Expr] -> Expr
reduceAccumulate [Call (Symbol "List") values] =
  list (drop 1 (scanl (\acc value -> reducePlus [acc, value]) (Integer 0) values))
reduceAccumulate values = Call (Symbol "Accumulate") values

reduceJoin :: [Expr] -> Expr
reduceJoin values = case traverse listArguments values of
  Just argumentLists -> list (concat argumentLists)
  Nothing -> Call (Symbol "Join") values

reduceMap :: [Expr] -> Expr
reduceMap [function, Call expressionHead values] =
  Call expressionHead [Call function [value] | value <- values]
reduceMap values = Call (Symbol "Map") values

reduceApply :: [Expr] -> Expr
reduceApply [newHead, Call _ values] = Call newHead values
reduceApply values = Call (Symbol "Apply") values

reduceReplaceAll :: [Expr] -> Expr
reduceReplaceAll [expression, rules] = replaceExpression (replacementRules rules) expression
reduceReplaceAll values = Call (Symbol "ReplaceAll") values

replacementRules :: Expr -> [(Expr, Expr)]
replacementRules (Call (Symbol "List") values) = concatMap replacementRules values
replacementRules (Call (Symbol "Rule") [lhs, rhs]) = [(lhs, rhs)]
replacementRules (Call (Symbol "RuleDelayed") [lhs, rhs]) = [(lhs, rhs)]
replacementRules _ = []

replaceExpression :: [(Expr, Expr)] -> Expr -> Expr
replaceExpression rules expression = case lookup expression rules of
  Just replacement -> replacement
  Nothing -> case expression of
    Call expressionHead values ->
      Call (replaceExpression rules expressionHead) (map (replaceExpression rules) values)
    _ -> expression

applyFunction :: [Expr] -> [Expr] -> Either EvaluationError Expr
applyFunction [body] values = Right (substituteSlots values body)
applyFunction [parameter, body] values =
  Right (substituteParameters parameter values body)
applyFunction functionArguments values =
  Right (Call (Call (Symbol "Function") functionArguments) values)

substituteSlots :: [Expr] -> Expr -> Expr
substituteSlots values expression = case expression of
  Call (Symbol "Slot") [Integer index]
    | index > 0 && index <= fromIntegral (length values) -> values !! fromIntegral (index - 1)
  Call expressionHead arguments' ->
    Call (substituteSlots values expressionHead) (map (substituteSlots values) arguments')
  _ -> expression

substituteParameters :: Expr -> [Expr] -> Expr -> Expr
substituteParameters parameter values body =
  let names = case parameter of
        Symbol name -> [name]
        Call (Symbol "List") parameters -> [name | Symbol name <- parameters]
        _ -> []
      replacements = zip (map Symbol names) values
   in replaceExpression replacements body

expressionDepth :: Expr -> Int
expressionDepth expression = case arguments expression of
  [] -> 1
  values -> 1 + maximum (map expressionDepth values)

flattenHead :: Text -> Expr -> [Expr]
flattenHead headName (Call (Symbol actualHead) values)
  | actualHead == headName = values
flattenHead _ expression = [expression]

hasHead :: Text -> Expr -> Bool
hasHead expected (Call (Symbol actual) _) = expected == actual
hasHead _ _ = False

isExact :: Expr -> Bool
isExact = maybe False (const True) . toExact

isInteger :: Expr -> Bool
isInteger Integer {} = True
isInteger _ = False

isNumber :: Expr -> Bool
isNumber Integer {} = True
isNumber Rational {} = True
isNumber Real {} = True
isNumber Complex {} = True
isNumber _ = False

isString :: Expr -> Bool
isString String {} = True
isString _ = False

integerValue :: Expr -> Maybe Integer
integerValue (Integer value) = Just value
integerValue _ = Nothing

listArguments :: Expr -> Maybe [Expr]
listArguments (Call (Symbol "List") values) = Just values
listArguments _ = Nothing

list :: [Expr] -> Expr
list = Call (Symbol "List")

boolean :: Bool -> Expr
boolean True = Symbol "True"
boolean False = Symbol "False"

allEqual :: Eq value => [value] -> Bool
allEqual [] = True
allEqual (firstValue : rest) = all (== firstValue) rest

allDistinct :: Eq value => [value] -> Bool
allDistinct [] = True
allDistinct (firstValue : rest) = firstValue `notElem` rest && allDistinct rest
