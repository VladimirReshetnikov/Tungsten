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
import Data.List (sortBy)
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
  Call (Call (Symbol "KeySelect") [criterion]) [association] ->
    reduceBuiltin "KeySelect" [association, criterion]
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
  "Association" -> Right (reduceAssociation values)
  "AssociationQ" -> Right (unary headName (boolean . isAssociation) values)
  "IntegerQ" -> Right (unary headName (boolean . isInteger) values)
  "NumberQ" -> Right (unary headName (boolean . isNumber) values)
  "StringQ" -> Right (unary headName (boolean . isString) values)
  "First" -> Right (reduceFirstLast True headName values)
  "Last" -> Right (reduceFirstLast False headName values)
  "Rest" -> Right (reduceRestMost True headName values)
  "Most" -> Right (reduceRestMost False headName values)
  "Part" -> reducePart values
  "Keys" -> reduceKeys values
  "Values" -> reduceValues values
  "Normal" -> reduceNormal values
  "Lookup" -> reduceLookup values
  "KeyExistsQ" -> reduceKeyExistsQ headName values
  "KeyMemberQ" -> reduceKeyExistsQ headName values
  "KeyTake" -> reduceKeyTakeDrop True values
  "KeyDrop" -> reduceKeyTakeDrop False values
  "KeySelect" -> reduceKeySelect values
  "KeyMap" -> reduceKeyMap values
  "KeyValueMap" -> reduceKeyValueMap values
  "AssociationThread" -> reduceAssociationThread values
  "AssociationMap" -> reduceAssociationMap values
  "KeySort" -> reduceKeySort values
  "Range" -> Right (reduceRange values)
  "Total" -> Right (reduceTotal values)
  "Accumulate" -> Right (reduceAccumulate values)
  "Reverse" -> Right (unaryCallArguments headName reverse values)
  "RotateLeft" -> Right (reduceRotate True headName values)
  "RotateRight" -> Right (reduceRotate False headName values)
  "Take" -> reduceTakeDrop True values
  "Drop" -> reduceTakeDrop False values
  "Append" -> Right (reduceAppendPrepend False headName values)
  "Prepend" -> Right (reduceAppendPrepend True headName values)
  "Join" -> Right (reduceJoin values)
  "Flatten" -> Right (reduceFlatten values)
  "Delete" -> reduceDelete values
  "Insert" -> reduceInsert values
  "ReplacePart" -> Right (reduceReplacePart values)
  "Map" -> Right (reduceMap values)
  "MapAt" -> Right (reduceMapAt values)
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
reduceFirstLast first _ [association]
  | Just entries <- associationEntries association
  , AssociationEntry _ _ value : remaining <- entries =
      if first then value else foldl' (\_ (AssociationEntry _ _ next) -> next) value remaining
reduceFirstLast first _ [Call _ (value : remaining)] =
  if first then value else foldl' (\_ next -> next) value remaining
reduceFirstLast _ headName values = Call (Symbol headName) values

reduceRestMost :: Bool -> Text -> [Expr] -> Expr
reduceRestMost rest _ [association]
  | Just entries@(_ : _) <- associationEntries association =
      associationExpr (if rest then drop 1 entries else reverse (drop 1 (reverse entries)))
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

data AssociationEntry = AssociationEntry !Text !Expr !Expr
  deriving (Eq, Show)

ruleEntry :: Expr -> Maybe AssociationEntry
ruleEntry (Call (Symbol ruleHead) [key, value])
  | ruleHead `elem` ["Rule", "RuleDelayed"] =
      Just (AssociationEntry ruleHead key value)
ruleEntry _ = Nothing

associationEntries :: Expr -> Maybe [AssociationEntry]
associationEntries (Call (Symbol "Association") values) = traverse ruleEntry values
associationEntries _ = Nothing

isAssociation :: Expr -> Bool
isAssociation = maybe False (const True) . associationEntries

associationExpr :: [AssociationEntry] -> Expr
associationExpr entries =
  Call (Symbol "Association") (map entryExpression (normalizeAssociationEntries entries))
 where
  entryExpression (AssociationEntry ruleHead key value) =
    Call (Symbol ruleHead) [key, value]

normalizeAssociationEntries :: [AssociationEntry] -> [AssociationEntry]
normalizeAssociationEntries = foldl' insertEntry [] . filter retainedEntry
 where
  retainedEntry (AssociationEntry _ key _) = key /= Symbol "Nothing"
  insertEntry retained entry@(AssociationEntry _ key _) =
    case matchingIndex key retained of
      Just index -> replaceListIndex index entry retained
      Nothing -> retained <> [entry]
  matchingIndex key = go 0
   where
    go _ [] = Nothing
    go index (AssociationEntry _ candidate _ : rest)
      | key == candidate = Just index
      | otherwise = go (index + 1) rest

reduceAssociation :: [Expr] -> Expr
reduceAssociation values = case associationFromArguments values of
  Just entries -> associationExpr entries
  Nothing -> Call (Symbol "Association") values

associationFromArguments :: [Expr] -> Maybe [AssociationEntry]
associationFromArguments [Call (Symbol "List") values] =
  traverse ruleEntry (filter (/= Symbol "Nothing") values)
associationFromArguments values =
  concat <$> traverse entriesFromArgument (filter (/= Symbol "Nothing") values)
 where
  entriesFromArgument argument =
    case associationEntries argument of
      Just entries -> Just entries
      Nothing -> pure <$> ruleEntry argument

requireAssociation :: Text -> Expr -> Either EvaluationError [AssociationEntry]
requireAssociation operation expression =
  maybe
    (Left (EvaluationError (operation <> " expects an Association")))
    Right
    (associationEntries expression)

evaluatedList :: [Expr] -> Expr
evaluatedList = list . filter (/= Symbol "Nothing")

reduceKeys :: [Expr] -> Either EvaluationError Expr
reduceKeys [association] = do
  entries <- requireAssociation "Keys" association
  pure (evaluatedList [key | AssociationEntry _ key _ <- entries])
reduceKeys values = Right (Call (Symbol "Keys") values)

reduceValues :: [Expr] -> Either EvaluationError Expr
reduceValues [association] = do
  entries <- requireAssociation "Values" association
  pure (evaluatedList [value | AssociationEntry _ _ value <- entries])
reduceValues values = Right (Call (Symbol "Values") values)

reduceNormal :: [Expr] -> Either EvaluationError Expr
reduceNormal [association] = case associationEntries association of
  Just entries ->
    pure
      ( list
          [ Call (Symbol ruleHead) [key, value]
          | AssociationEntry ruleHead key value <- entries
          ]
      )
  Nothing -> Right (Call (Symbol "Normal") [association])
reduceNormal values = Right (Call (Symbol "Normal") values)

reduceLookup :: [Expr] -> Either EvaluationError Expr
reduceLookup = \case
  [association, keySpecification] -> lookupWithDefault association keySpecification Nothing
  [association, keySpecification, defaultValue] ->
    lookupWithDefault association keySpecification (Just defaultValue)
  values -> Right (Call (Symbol "Lookup") values)
 where
  lookupWithDefault association keySpecification defaultValue = do
    entries <- requireAssociation "Lookup" association
    let lookupOne key = case findAssociationEntry key entries of
          Just (AssociationEntry _ _ value) -> value
          Nothing -> case defaultValue of
            Just value -> value
            Nothing -> Call (Symbol "Missing") [String "KeyAbsent", key]
    pure $ case keySpecification of
      Call (Symbol "List") keys -> evaluatedList (map lookupOne keys)
      key -> lookupOne key

findAssociationEntry :: Expr -> [AssociationEntry] -> Maybe AssociationEntry
findAssociationEntry _ [] = Nothing
findAssociationEntry key (entry@(AssociationEntry _ candidate _) : rest)
  | key == candidate = Just entry
  | otherwise = findAssociationEntry key rest

reduceKeyExistsQ :: Text -> [Expr] -> Either EvaluationError Expr
reduceKeyExistsQ _ [association, key] = do
  entries <- requireAssociation "KeyExistsQ" association
  pure (boolean (maybe False (const True) (findAssociationEntry key entries)))
reduceKeyExistsQ headName values = Right (Call (Symbol headName) values)

keySpecificationItems :: Expr -> [Expr]
keySpecificationItems (Call (Symbol "List") values) = values
keySpecificationItems value = [value]

reduceKeyTakeDrop :: Bool -> [Expr] -> Either EvaluationError Expr
reduceKeyTakeDrop takeMode [association, keySpecification] = do
  entries <- requireAssociation operationName association
  let keys = keySpecificationItems keySpecification
      selected
        | takeMode = mapMaybe (`findAssociationEntry` entries) keys
        | otherwise =
            [ entry
            | entry@(AssociationEntry _ key _) <- entries
            , key `notElem` keys
            ]
  pure (associationExpr selected)
 where
  operationName = if takeMode then "KeyTake" else "KeyDrop"
reduceKeyTakeDrop takeMode values =
  Right (Call (Symbol (if takeMode then "KeyTake" else "KeyDrop")) values)

reduceKeySelect :: [Expr] -> Either EvaluationError Expr
reduceKeySelect [association, criterion] = do
  entries <- requireAssociation "KeySelect" association
  retained <- traverse retain entries
  pure (associationExpr [entry | (True, entry) <- retained])
 where
  retain entry@(AssociationEntry _ key _) = do
    result <- evaluate (Call criterion [key])
    pure (result == Symbol "True", entry)
reduceKeySelect values = Right (Call (Symbol "KeySelect") values)

reduceKeyMap :: [Expr] -> Either EvaluationError Expr
reduceKeyMap [function, association] = do
  entries <- requireAssociation "KeyMap" association
  pure
    ( associationExpr
        [ AssociationEntry ruleHead (Call function [key]) value
        | AssociationEntry ruleHead key value <- entries
        ]
    )
reduceKeyMap values = Right (Call (Symbol "KeyMap") values)

reduceKeyValueMap :: [Expr] -> Either EvaluationError Expr
reduceKeyValueMap [function, association] = do
  entries <- requireAssociation "KeyValueMap" association
  pure
    ( evaluatedList
        [ Call function [key, value]
        | AssociationEntry _ key value <- entries
        ]
    )
reduceKeyValueMap values = Right (Call (Symbol "KeyValueMap") values)

reduceAssociationThread :: [Expr] -> Either EvaluationError Expr
reduceAssociationThread [Call (Symbol "List") keys, Call (Symbol "List") values]
  | length keys == length values =
      Right
        ( associationExpr
            (zipWith (AssociationEntry "Rule") keys values)
        )
  | otherwise = Left (EvaluationError "AssociationThread expects key and value lists of equal length")
reduceAssociationThread values = Right (Call (Symbol "AssociationThread") values)

reduceAssociationMap :: [Expr] -> Either EvaluationError Expr
reduceAssociationMap [function, Call (Symbol "List") keys] =
  Right
    ( associationExpr
        [AssociationEntry "Rule" key (Call function [key]) | key <- keys]
    )
reduceAssociationMap values = Right (Call (Symbol "AssociationMap") values)

reduceKeySort :: [Expr] -> Either EvaluationError Expr
reduceKeySort [association] = do
  entries <- requireAssociation "KeySort" association
  pure (associationExpr (sortBy compareKey entries))
 where
  compareKey (AssociationEntry _ left _) (AssociationEntry _ right _) =
    compare (canonicalKey left) (canonicalKey right)
  canonicalKey expression = (canonicalRank expression, fullForm expression)
  canonicalRank = \case
    Integer {} -> 0 :: Int
    Rational {} -> 0
    Real {} -> 0
    String {} -> 1
    Symbol {} -> 2
    _ -> 3
reduceKeySort values = Right (Call (Symbol "KeySort") values)

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
reduceTotal [association]
  | Just entries <- associationEntries association =
      reducePlus [value | AssociationEntry _ _ value <- entries]
reduceTotal values = Call (Symbol "Total") values

reduceAccumulate :: [Expr] -> Expr
reduceAccumulate [Call (Symbol "List") values] =
  list (drop 1 (scanl (\acc value -> reducePlus [acc, value]) (Integer 0) values))
reduceAccumulate values = Call (Symbol "Accumulate") values

reduceAppendPrepend :: Bool -> Text -> [Expr] -> Expr
reduceAppendPrepend prepend _ [association, item]
  | Just entries <- associationEntries association
  , Just newEntry@(AssociationEntry _ newKey _) <- ruleEntry item =
      let retained = [entry | entry@(AssociationEntry _ key _) <- entries, key /= newKey]
       in associationExpr (if prepend then newEntry : retained else retained <> [newEntry])
reduceAppendPrepend prepend _ [Call expressionHead values, item] =
  Call expressionHead (if prepend then item : values else values <> [item])
reduceAppendPrepend _ headName values = Call (Symbol headName) values

reduceRotate :: Bool -> Text -> [Expr] -> Expr
reduceRotate left headName = \case
  [subject] -> rotate subject 1
  [subject, Integer amount] -> rotate subject amount
  values -> Call (Symbol headName) values
 where
  rotate (Call expressionHead arguments') amount
    | null arguments' = Call expressionHead []
    | otherwise =
        let count = length arguments'
            signed = if left then amount else negate amount
            offset = fromIntegral (signed `mod` fromIntegral count)
         in Call expressionHead (drop offset arguments' <> take offset arguments')
  rotate subject amount = Call (Symbol headName) [subject, Integer amount]

reduceTakeDrop :: Bool -> [Expr] -> Either EvaluationError Expr
reduceTakeDrop takeMode (subject : specifications@(_ : _)) =
  applySpecifications subject specifications
 where
  operationName = if takeMode then "Take" else "Drop"
  applySpecifications expression [] = Right expression
  applySpecifications expression (specification : remaining) = do
    sliced <- applySpecification expression specification
    if null remaining
      then Right sliced
      else case sliced of
        Call expressionHead values ->
          Call expressionHead <$> traverse (`applySpecifications` remaining) values
        _ -> Left (EvaluationError (operationName <> " encountered an atom before consuming every specification"))
  applySpecification (Call expressionHead values) specification = do
    selected <- specificationIndices takeMode (length values) specification
    pure (Call expressionHead [value | (index, value) <- zip [0 ..] values, index `elem` selected])
  applySpecification _ _ = Left (EvaluationError (operationName <> " expects an expression with arguments"))
reduceTakeDrop takeMode values =
  Right (Call (Symbol (if takeMode then "Take" else "Drop")) values)

specificationIndices :: Bool -> Int -> Expr -> Either EvaluationError [Int]
specificationIndices takeMode count specification = do
  selected <- case specification of
    Symbol "All" -> Right [0 .. count - 1]
    Symbol "None" -> Right []
    Integer amount
      | amount >= 0 -> Right [0 .. min count (fromIntegral amount) - 1]
      | otherwise -> Right [max 0 (count - fromIntegral (abs amount)) .. count - 1]
    Call (Symbol "List") [Integer position] ->
      maybe (Left invalid) (Right . pure) (resolvePosition count position)
    Call (Symbol "List") [Integer first, Integer last'] ->
      rangePositions first last' 1
    Call (Symbol "List") [Integer first, Integer last', Integer step]
      | step /= 0 -> rangePositions first last' step
    _ -> Left invalid
  pure
    ( if takeMode
        then selected
        else [index | index <- [0 .. count - 1], index `notElem` selected]
    )
 where
  invalid = EvaluationError "Take/Drop received an unsupported or out-of-range specification"
  rangePositions :: Integer -> Integer -> Integer -> Either EvaluationError [Int]
  rangePositions first last' step = do
    start <- maybe (Left invalid) Right (resolvePosition count first)
    finish <- maybe (Left invalid) Right (resolvePosition count last')
    let stepValue = fromIntegral step
        indices
          | stepValue > 0 && start <= finish = [start, start + stepValue .. finish]
          | stepValue < 0 && start >= finish = [start, start + stepValue .. finish]
          | otherwise = []
    pure indices

resolvePosition :: Int -> Integer -> Maybe Int
resolvePosition count position
  | position > 0 = valid (fromIntegral position - 1)
  | position < 0 = valid (count + fromIntegral position)
  | otherwise = Nothing
 where
  valid index = if index >= 0 && index < count then Just index else Nothing

reduceJoin :: [Expr] -> Expr
reduceJoin values
  | Just entryLists <- traverse associationEntries values =
      associationExpr (concat entryLists)
reduceJoin values = case values of
  Call expressionHead _ : _ ->
    case traverse (matchingArguments expressionHead) values of
      Just argumentLists -> Call expressionHead (concat argumentLists)
      Nothing -> Call (Symbol "Join") values
   where
    matchingArguments expected (Call actual arguments')
      | actual == expected = Just arguments'
    matchingArguments _ _ = Nothing
  _ -> Call (Symbol "Join") values

reduceFlatten :: [Expr] -> Expr
reduceFlatten = \case
  [subject@(Call expressionHead _)] -> flattenSameHead expressionHead Nothing subject
  [subject@(Call expressionHead _), Symbol "Infinity"] -> flattenSameHead expressionHead Nothing subject
  [subject@(Call expressionHead _), Integer level]
    | level >= 0 -> flattenSameHead expressionHead (Just (fromIntegral level)) subject
  [subject@(Call _ _), levelSpecification, targetHead]
    | Just level <- flattenLevel levelSpecification -> flattenNamedHead targetHead level subject
  values -> Call (Symbol "Flatten") values
 where
  flattenLevel (Symbol "Infinity") = Just Nothing
  flattenLevel (Integer level) | level >= 0 = Just (Just (fromIntegral level))
  flattenLevel _ = Nothing

flattenSameHead :: Expr -> Maybe Int -> Expr -> Expr
flattenSameHead target remaining expression@(Call expressionHead values)
  | remaining == Just 0 = expression
  | expressionHead /= target = expression
  | otherwise = Call expressionHead (concatMap expand values)
 where
  next = fmap (subtract 1) remaining
  expand child@(Call childHead _)
    | childHead == target = arguments (flattenSameHead target next child)
  expand child = [child]
flattenSameHead _ _ expression = expression

flattenNamedHead :: Expr -> Maybe Int -> Expr -> Expr
flattenNamedHead _ (Just 0) expression = expression
flattenNamedHead target remaining (Call expressionHead values) =
  Call expressionHead (concatMap expand values)
 where
  next = fmap (subtract 1) remaining
  expand child@(Call childHead _)
    | childHead == target = arguments (flattenNamedHead target next child)
    | otherwise = [flattenNamedHead target remaining child]
  expand child = [child]
flattenNamedHead _ _ expression = expression

reduceDelete :: [Expr] -> Either EvaluationError Expr
reduceDelete [subject, positions] =
  foldM deleteOne subject (sortOperationPaths (positionPaths positions))
 where
  deleteOne expression path = case deleteAtPath path expression of
    Just result -> Right result
    Nothing -> Left (EvaluationError "Delete received an invalid position")
reduceDelete values = Right (Call (Symbol "Delete") values)

reduceInsert :: [Expr] -> Either EvaluationError Expr
reduceInsert [subject, item, positions] =
  foldM insertOne subject (sortOperationPaths (positionPaths positions))
 where
  insertOne expression path = case insertAtPath path item expression of
    Just result -> Right result
    Nothing -> Left (EvaluationError "Insert received an invalid position")
reduceInsert values = Right (Call (Symbol "Insert") values)

reduceReplacePart :: [Expr] -> Expr
reduceReplacePart [subject, replacements] =
  foldl applyReplacement subject (sortReplacementRules (replacePartRules replacements))
 where
  applyReplacement expression (path, Symbol "Nothing") =
    maybe expression id (deleteAtPath path expression)
  applyReplacement expression (path, replacement) =
    maybe expression id (replaceAtPath path replacement expression)
reduceReplacePart values = Call (Symbol "ReplacePart") values

reduceMapAt :: [Expr] -> Expr
reduceMapAt [function, subject, positions] =
  foldl applyAt subject (sortOperationPaths (positionPaths positions))
 where
  applyAt expression path =
    maybe expression id (mapAtPath path function expression)
reduceMapAt values = Call (Symbol "MapAt") values

positionPaths :: Expr -> [[Integer]]
positionPaths (Integer position) = [[position]]
positionPaths (Call (Symbol "List") values)
  | Just path <- traverse integerValue values = [path]
  | otherwise = concatMap listPath values
 where
  listPath (Call (Symbol "List") components) = maybe [] pure (traverse integerValue components)
  listPath _ = []
positionPaths _ = []

replacePartRules :: Expr -> [([Integer], Expr)]
replacePartRules (Call (Symbol "List") rules) = concatMap replacePartRules rules
replacePartRules (Call (Symbol ruleHead) [position, replacement])
  | ruleHead `elem` ["Rule", "RuleDelayed"] =
      [(path, replacement) | path <- positionPaths position]
replacePartRules _ = []

sortOperationPaths :: [[Integer]] -> [[Integer]]
sortOperationPaths = sortBy comparePath
 where
  comparePath left right = case compare (length right) (length left) of
    EQ -> compare right left
    ordering -> ordering

sortReplacementRules :: [([Integer], Expr)] -> [([Integer], Expr)]
sortReplacementRules = sortBy (\(left, _) (right, _) -> comparePath left right)
 where
  comparePath left right = case compare (length right) (length left) of
    EQ -> compare right left
    ordering -> ordering

deleteAtPath :: [Integer] -> Expr -> Maybe Expr
deleteAtPath [] _ = Nothing
deleteAtPath [position] (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  pure (Call expressionHead (take index values <> drop (index + 1) values))
deleteAtPath (position : remaining) (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- deleteAtPath remaining (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
deleteAtPath _ _ = Nothing

replaceAtPath :: [Integer] -> Expr -> Expr -> Maybe Expr
replaceAtPath [] replacement _ = Just replacement
replaceAtPath (position : remaining) replacement (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- replaceAtPath remaining replacement (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
replaceAtPath _ _ _ = Nothing

mapAtPath :: [Integer] -> Expr -> Expr -> Maybe Expr
mapAtPath [] function expression = Just (Call function [expression])
mapAtPath (position : remaining) function (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- mapAtPath remaining function (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
mapAtPath _ _ _ = Nothing

insertAtPath :: [Integer] -> Expr -> Expr -> Maybe Expr
insertAtPath [] _ _ = Nothing
insertAtPath [position] item (Call expressionHead values) = do
  index <- insertOffset (length values) position
  pure (Call expressionHead (take index values <> [item] <> drop index values))
insertAtPath (position : remaining) item (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- insertAtPath remaining item (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
insertAtPath _ _ _ = Nothing

insertOffset :: Int -> Integer -> Maybe Int
insertOffset count position
  | position == 0 = Just 0
  | position > 0 = valid (fromIntegral position - 1)
  | otherwise = valid (count + fromIntegral position + 1)
 where
  valid index = if index >= 0 && index <= count then Just index else Nothing

replaceListIndex :: Int -> value -> [value] -> [value]
replaceListIndex index replacement values =
  take index values <> [replacement] <> drop (index + 1) values

reduceMap :: [Expr] -> Expr
reduceMap [function, association]
  | Just entries <- associationEntries association =
      associationExpr
        [ AssociationEntry ruleHead key (Call function [value])
        | AssociationEntry ruleHead key value <- entries
        ]
reduceMap [function, Call expressionHead values] =
  Call expressionHead [Call function [value] | value <- values]
reduceMap values = Call (Symbol "Map") values

reduceApply :: [Expr] -> Expr
reduceApply [newHead, association]
  | Just entries <- associationEntries association =
      Call newHead [value | AssociationEntry _ _ value <- entries]
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
expressionDepth expression
  | Just entries <- associationEntries expression =
      case [value | AssociationEntry _ _ value <- entries] of
        [] -> 1
        values -> 1 + maximum (map expressionDepth values)
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
