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
import Data.List (sortBy, transpose)
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
  Call (Call (Symbol "SortBy") [function]) [subject] ->
    reduceBuiltin "SortBy" [subject, function]
  Call (Call (Symbol "ReverseSortBy") [function]) [subject] ->
    reduceBuiltin "ReverseSortBy" [subject, function]
  Call (Call (Symbol "Select") [criterion]) [subject] ->
    reduceBuiltin "Select" [subject, criterion]
  Call (Call (Symbol "Discard") [criterion]) [subject] ->
    reduceBuiltin "Discard" [subject, criterion]
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
  "Identity" -> Right (unary headName id values)
  "IntegerQ" -> Right (unary headName (boolean . isInteger) values)
  "NumberQ" -> Right (unary headName (boolean . isNumber) values)
  "StringQ" -> Right (unary headName (boolean . isString) values)
  "EvenQ" -> Right (reduceParity True headName values)
  "OddQ" -> Right (reduceParity False headName values)
  "First" -> Right (reduceFirstLast True headName values)
  "Last" -> Right (reduceFirstLast False headName values)
  "Rest" -> Right (reduceRestMost True headName values)
  "Most" -> Right (reduceRestMost False headName values)
  "Part" -> reducePart values
  "Extract" -> reduceExtract values
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
  "Merge" -> reduceMerge values
  "GroupBy" -> reduceGroupBy values
  "GatherBy" -> reduceGatherBy values
  "Gather" -> reduceGather values
  "KeyComplement" -> reduceKeyComplement values
  "KeyUnion" -> reduceKeyUnion values
  "KeyIntersection" -> reduceKeyIntersection values
  "Tally" -> reduceTally values
  "Counts" -> reduceCounts values
  "Catenate" -> reduceCatenate values
  "Differences" -> reduceDifferences values
  "Riffle" -> reduceRiffle values
  "AllTrue" -> reduceTruthCollection "AllTrue" and values
  "AnyTrue" -> reduceTruthCollection "AnyTrue" or values
  "NoneTrue" -> reduceTruthCollection "NoneTrue" (not . or) values
  "ContainsAll" -> reduceContains "ContainsAll" containsAll values
  "ContainsAny" -> reduceContains "ContainsAny" containsAny values
  "ContainsNone" -> reduceContains "ContainsNone" (\left right -> not (containsAny left right)) values
  "ContainsExactly" -> reduceContains "ContainsExactly" containsExactly values
  "Subsets" -> reduceSubsets values
  "Permutations" -> reducePermutations values
  "Permute" -> reducePermute values
  "PadLeft" -> reducePad True values
  "PadRight" -> reducePad False values
  "Mean" -> reduceMean values
  "Median" -> reduceMedian values
  "Order" -> Right (reduceOrder values)
  "OrderedQ" -> reduceOrderedQ values
  "Ordering" -> reduceOrderingIndices values
  "Sort" -> reduceSort False values
  "ReverseSort" -> reduceSort True values
  "SortBy" -> reduceSortBy False values
  "ReverseSortBy" -> reduceSortBy True values
  "Union" -> reduceSetOperation SetUnion values
  "Intersection" -> reduceSetOperation SetIntersection values
  "Complement" -> reduceSetOperation SetComplement values
  "Select" -> reduceSelect False values
  "Discard" -> reduceSelect True values
  "SelectFirst" -> reduceSelectFirst values
  "TakeWhile" -> reduceTakeWhile values
  "LengthWhile" -> reduceLengthWhile values
  "Pick" -> reducePick values
  "Boole" -> Right (reduceBoole values)
  "MatchQ" -> Right (reduceMatchQ values)
  "FreeQ" -> reduceFreeQ values
  "MemberQ" -> reduceMemberQ values
  "Count" -> reduceCount values
  "Cases" -> reduceCases values
  "DeleteCases" -> reduceDeleteCases values
  "FirstCase" -> reduceFirstCase values
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
  "Replace" -> reduceReplace values
  "ReplaceAll" -> reduceReplaceAll values
  "ReplaceRepeated" -> reduceReplaceRepeated values
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

reduceParity :: Bool -> Text -> [Expr] -> Expr
reduceParity evenMode _ [Integer value] = boolean (even value == evenMode)
reduceParity _ headName values = Call (Symbol headName) values

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
  selectPart association (Call (Symbol "List") selectors)
    | Just entries <- associationEntries association
    , Just keys <- traverse keySelectorValue selectors =
        Right (associationExpr (mapMaybe (`findAssociationEntry` entries) keys))
    | Just _ <- associationEntries association
    , any isKeySelector selectors =
        Left (EvaluationError "an Association Part selector list cannot mix keys with other selectors")
  selectPart association selector
    | Just entries <- associationEntries association
    , Just selectorPath <- associationPartSelector selector =
        maybe
          (Left (EvaluationError "an Association Part selector is out of range or absent"))
          (Right . associationEntryValue)
          (associationEntryForSelector selectorPath entries)
  selectPart (Call _ values) (Integer index) =
    let resolved = if index > 0 then index - 1 else fromIntegral (length values) + index
     in if resolved >= 0 && resolved < fromIntegral (length values)
          then Right (values !! fromIntegral resolved)
          else Left (EvaluationError "a Part index is out of range")
  selectPart expression index = Right (Call (Symbol "Part") [expression, index])

reduceExtract :: [Expr] -> Either EvaluationError Expr
reduceExtract [subject, positions] = do
  let paths = positionPaths positions
  if null paths
    then Left (EvaluationError "Extract received an invalid position specification")
    else do
      selected <- traverse extractPath paths
      case selected of
        firstSelected : _ ->
          pure (if hasMultiplePositionPaths positions then evaluatedList selected else firstSelected)
        [] -> Left (EvaluationError "Extract received an empty internal position set")
 where
  extractPath path =
    maybe
      (Left (EvaluationError "Extract received an invalid position"))
      Right
      (selectAtPath path subject)
reduceExtract values = Right (Call (Symbol "Extract") values)

data AssociationEntry = AssociationEntry !Text !Expr !Expr
  deriving (Eq, Show)

data PathSelector
  = ArgumentSelector !Integer
  | KeySelector !Expr
  deriving (Eq, Show)

keySelectorValue :: Expr -> Maybe Expr
keySelectorValue (Call (Symbol "Key") [key]) = Just key
keySelectorValue _ = Nothing

isKeySelector :: Expr -> Bool
isKeySelector = maybe False (const True) . keySelectorValue

associationPartSelector :: Expr -> Maybe PathSelector
associationPartSelector (Integer position) = Just (ArgumentSelector position)
associationPartSelector selector
  | Just key <- keySelectorValue selector = Just (KeySelector key)
associationPartSelector key@String {} = Just (KeySelector key)
associationPartSelector _ = Nothing

associationEntryValue :: AssociationEntry -> Expr
associationEntryValue (AssociationEntry _ _ value) = value

associationEntryForSelector :: PathSelector -> [AssociationEntry] -> Maybe AssociationEntry
associationEntryForSelector selector entries = do
  index <- associationEntryIndex selector entries
  pure (entries !! index)

associationEntryIndex :: PathSelector -> [AssociationEntry] -> Maybe Int
associationEntryIndex (ArgumentSelector position) entries =
  resolvePosition (length entries) position
associationEntryIndex (KeySelector key) entries = go 0 entries
 where
  go _ [] = Nothing
  go index (AssociationEntry _ candidate _ : rest)
    | key == candidate = Just index
    | otherwise = go (index + 1) rest

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
    canonicalCompare left right
reduceKeySort values = Right (Call (Symbol "KeySort") values)

reduceMerge :: [Expr] -> Either EvaluationError Expr
reduceMerge [Call (Symbol "List") associations, combiner] = do
  entryLists <- traverse (requireAssociation "Merge") associations
  let groups = foldl' addEntryGroup [] (concat entryLists)
  combined <- traverse combineGroup groups
  pure (associationExpr combined)
 where
  addEntryGroup groups (AssociationEntry ruleHead key value) =
    case groupIndex key groups of
      Nothing -> groups <> [(ruleHead, key, [value])]
      Just index -> case groups !! index of
        (firstRuleHead, firstKey, groupedValues) ->
          replaceListIndex index (firstRuleHead, firstKey, groupedValues <> [value]) groups
  combineGroup (ruleHead, key, groupedValues) = do
    combinedValue <- evaluate (Call combiner [list groupedValues])
    pure (AssociationEntry ruleHead key combinedValue)
  groupIndex key = go 0
   where
    go _ [] = Nothing
    go index ((_, candidate, _) : rest)
      | key == candidate = Just index
      | otherwise = go (index + 1) rest
reduceMerge values = Right (Call (Symbol "Merge") values)

data ValueGroup = ValueGroup !Expr ![Expr]
  deriving (Eq, Show)

addValueGroup :: Expr -> Expr -> [ValueGroup] -> [ValueGroup]
addValueGroup key value groups = case valueGroupIndex key groups of
  Nothing -> groups <> [ValueGroup key [value]]
  Just index -> case groups !! index of
    ValueGroup firstKey groupedValues ->
      replaceListIndex index (ValueGroup firstKey (groupedValues <> [value])) groups

valueGroupIndex :: Expr -> [ValueGroup] -> Maybe Int
valueGroupIndex key = go 0
 where
  go _ [] = Nothing
  go index (ValueGroup candidate _ : rest)
    | key == candidate = Just index
    | otherwise = go (index + 1) rest

listOrAssociationValues :: Text -> Expr -> Either EvaluationError [Expr]
listOrAssociationValues _ (Call (Symbol "List") values) = Right values
listOrAssociationValues operation association = do
  entries <- requireAssociation operation association
  pure [value | AssociationEntry _ _ value <- entries]

groupValuesBy :: Expr -> [Expr] -> Either EvaluationError [ValueGroup]
groupValuesBy keyFunction = foldM add []
 where
  add groups value = do
    key <- evaluate (Call keyFunction [value])
    pure (addValueGroup key value groups)

reduceGroupBy :: [Expr] -> Either EvaluationError Expr
reduceGroupBy [dataExpression, specification] = do
  values <- listOrAssociationValues "GroupBy" dataExpression
  let (keyFunction, valueFunction) = case specification of
        Call (Symbol "Rule") [key, value] -> (key, Just value)
        _ -> (specification, Nothing)
  groups <- groupValuesBy keyFunction values
  entries <- traverse (groupEntry valueFunction) groups
  pure (associationExpr entries)
 where
  groupEntry valueFunction (ValueGroup key groupedValues) = do
    payload <- case valueFunction of
      Nothing -> Right (list groupedValues)
      Just function -> evaluate (Call function [list groupedValues])
    pure (AssociationEntry "Rule" key payload)
reduceGroupBy values = Right (Call (Symbol "GroupBy") values)

reduceGatherBy :: [Expr] -> Either EvaluationError Expr
reduceGatherBy [dataExpression, keyFunction] = do
  values <- listOrAssociationValues "GatherBy" dataExpression
  groups <- groupValuesBy keyFunction values
  pure (list [list groupedValues | ValueGroup _ groupedValues <- groups])
reduceGatherBy values = Right (Call (Symbol "GatherBy") values)

reduceGather :: [Expr] -> Either EvaluationError Expr
reduceGather [dataExpression] = do
  values <- listOrAssociationValues "Gather" dataExpression
  let groups = foldl' (\retained value -> addValueGroup value value retained) [] values
  pure (list [list groupedValues | ValueGroup _ groupedValues <- groups])
reduceGather values = Right (Call (Symbol "Gather") values)

requireAssociationList :: Text -> Expr -> Either EvaluationError [[AssociationEntry]]
requireAssociationList operation (Call (Symbol "List") associations@(_ : _)) =
  traverse (requireAssociation operation) associations
requireAssociationList operation _ =
  Left (EvaluationError (operation <> " expects a non-empty list of Associations"))

uniqueKeys :: [AssociationEntry] -> [Expr]
uniqueKeys = foldl' appendKey []
 where
  appendKey keys (AssociationEntry _ key _)
    | key `elem` keys = keys
    | otherwise = keys <> [key]

reduceKeyComplement :: [Expr] -> Either EvaluationError Expr
reduceKeyComplement [associations] = do
  members <- requireAssociationList "KeyComplement" associations
  case members of
    firstMember : remaining ->
      let laterKeys = uniqueKeys (concat remaining)
       in pure
            ( associationExpr
                [ entry
                | entry@(AssociationEntry _ key _) <- firstMember
                , key `notElem` laterKeys
                ]
            )
    [] -> Left (EvaluationError "KeyComplement expects a non-empty list of Associations")
reduceKeyComplement values = Right (Call (Symbol "KeyComplement") values)

reduceKeyUnion :: [Expr] -> Either EvaluationError Expr
reduceKeyUnion [associations] = do
  members <- requireAssociationList "KeyUnion" associations
  let keys = uniqueKeys (concat members)
      align member =
        associationExpr
          [ case findAssociationEntry key member of
              Just entry -> entry
              Nothing ->
                AssociationEntry
                  "Rule"
                  key
                  (Call (Symbol "Missing") [String "KeyAbsent", key])
          | key <- keys
          ]
  pure (list (map align members))
reduceKeyUnion values = Right (Call (Symbol "KeyUnion") values)

reduceKeyIntersection :: [Expr] -> Either EvaluationError Expr
reduceKeyIntersection [associations] = do
  members <- requireAssociationList "KeyIntersection" associations
  case members of
    firstMember : remaining -> do
      let keys =
            [ key
            | AssociationEntry _ key _ <- firstMember
            , all (maybe False (const True) . findAssociationEntry key) remaining
            ]
          project member = associationExpr (mapMaybe (`findAssociationEntry` member) keys)
      pure (list (map project members))
    [] -> Left (EvaluationError "KeyIntersection expects a non-empty list of Associations")
reduceKeyIntersection values = Right (Call (Symbol "KeyIntersection") values)

reduceTally :: [Expr] -> Either EvaluationError Expr
reduceTally [dataExpression] = do
  values <- listOrAssociationValues "Tally" dataExpression
  let groups = foldl' (\retained value -> addValueGroup value value retained) [] values
  pure
    ( list
        [ list [key, Integer (fromIntegral (length groupedValues))]
        | ValueGroup key groupedValues <- groups
        ]
    )
reduceTally values = Right (Call (Symbol "Tally") values)

reduceCounts :: [Expr] -> Either EvaluationError Expr
reduceCounts [dataExpression] = do
  values <- listOrAssociationValues "Counts" dataExpression
  let groups = foldl' (\retained value -> addValueGroup value value retained) [] values
  pure
    ( associationExpr
        [ AssociationEntry "Rule" key (Integer (fromIntegral (length groupedValues)))
        | ValueGroup key groupedValues <- groups
        ]
    )
reduceCounts values = Right (Call (Symbol "Counts") values)

reduceCatenate :: [Expr] -> Either EvaluationError Expr
reduceCatenate [dataExpression] = do
  values <- listOrAssociationValues "Catenate" dataExpression
  nested <-
    maybe
      (Left (EvaluationError "Catenate expects lists as its first-level values"))
      Right
      (traverse listArguments values)
  pure (list (concat nested))
reduceCatenate values = Right (Call (Symbol "Catenate") values)

reduceDifferences :: [Expr] -> Either EvaluationError Expr
reduceDifferences [Call (Symbol "List") values] =
  Right
    ( list
        ( zipWith
            (\left right -> reducePlus [right, reduceTimes [Integer (-1), left]])
            values
            (drop 1 values)
        )
    )
reduceDifferences values = Right (Call (Symbol "Differences") values)

reduceRiffle :: [Expr] -> Either EvaluationError Expr
reduceRiffle [Call (Symbol "List") values, separator] = case separator of
  Call (Symbol "List") [] -> Left (EvaluationError "Riffle expects a non-empty separator list")
  Call (Symbol "List") separators -> Right (list (interleave separators values))
  _ -> Right (list (interleave [separator] values))
 where
  interleave separators values' = go 0 values'
   where
    separatorCount = length separators
    go _ [] = []
    go _ [single] = [single]
    go index (value : rest) =
      value : separators !! (index `mod` separatorCount) : go (index + 1) rest
reduceRiffle values = Right (Call (Symbol "Riffle") values)

reduceTruthCollection :: Text -> ([Bool] -> Bool) -> [Expr] -> Either EvaluationError Expr
reduceTruthCollection operation combine [dataExpression, test] = do
  values <- listOrAssociationValues operation dataExpression
  outcomes <- traverse (evaluate . Call test . pure) values
  pure (boolean (combine (map (== Symbol "True") outcomes)))
reduceTruthCollection operation _ values = Right (Call (Symbol operation) values)

reduceContains :: Text -> ([Expr] -> [Expr] -> Bool) -> [Expr] -> Either EvaluationError Expr
reduceContains operation relation [left, right] = do
  leftValues <- listOrAssociationValues operation left
  rightValues <- listOrAssociationValues operation right
  pure (boolean (relation leftValues rightValues))
reduceContains operation _ values = Right (Call (Symbol operation) values)

containsAll :: [Expr] -> [Expr] -> Bool
containsAll left right = all (`elem` left) right

containsAny :: [Expr] -> [Expr] -> Bool
containsAny left right = any (`elem` left) right

containsExactly :: [Expr] -> [Expr] -> Bool
containsExactly left right = containsAll left right && containsAll right left

reduceSubsets :: [Expr] -> Either EvaluationError Expr
reduceSubsets = \case
  [dataExpression] -> subsetsWithSizes dataExpression Nothing
  [dataExpression, specification] -> subsetsWithSizes dataExpression (Just specification)
  values -> Right (Call (Symbol "Subsets") values)
 where
  subsetsWithSizes dataExpression specification = do
    values <- listOrAssociationValues "Subsets" dataExpression
    sizes <- collectionSizes "Subsets" (length values) [0 .. length values] specification
    pure (list [list subset | size <- sizes, subset <- combinationsOf size values])

reducePermutations :: [Expr] -> Either EvaluationError Expr
reducePermutations = \case
  [dataExpression] -> permutationsWithSizes dataExpression Nothing
  [dataExpression, specification] -> permutationsWithSizes dataExpression (Just specification)
  values -> Right (Call (Symbol "Permutations") values)
 where
  permutationsWithSizes dataExpression specification = do
    values <- listOrAssociationValues "Permutations" dataExpression
    sizes <- collectionSizes "Permutations" (length values) [length values] specification
    pure (list [list permutation | size <- sizes, permutation <- permutationsOf size values])

collectionSizes :: Text -> Int -> [Int] -> Maybe Expr -> Either EvaluationError [Int]
collectionSizes _ _ defaults Nothing = Right defaults
collectionSizes operation maximumSize _ (Just specification) = case specification of
  Call (Symbol "List") [Integer size]
    | size >= 0 -> Right (inBounds [fromIntegral size])
  Call (Symbol "List") [Integer lower, Integer upper]
    | lower >= 0 && upper >= lower -> Right (inBounds [fromIntegral lower .. fromIntegral upper])
  Integer upper
    | upper >= 0 -> Right [0 .. min maximumSize (fromIntegral upper)]
  _ -> Left (EvaluationError (operation <> " received an unsupported size specification"))
 where
  inBounds = filter (<= maximumSize)

combinationsOf :: Int -> [value] -> [[value]]
combinationsOf 0 _ = [[]]
combinationsOf _ [] = []
combinationsOf count (value : rest)
  | count < 0 = []
  | otherwise =
      map (value :) (combinationsOf (count - 1) rest) <> combinationsOf count rest

permutationsOf :: Int -> [value] -> [[value]]
permutationsOf 0 _ = [[]]
permutationsOf count values
  | count < 0 = []
  | otherwise =
      [ value : permutation
      | (value, remaining) <- selectEach values
      , permutation <- permutationsOf (count - 1) remaining
      ]
 where
  selectEach [] = []
  selectEach (value : rest) =
    (value, rest) : [(selected, value : remaining) | (selected, remaining) <- selectEach rest]

reducePermute :: [Expr] -> Either EvaluationError Expr
reducePermute [Call expressionHead subjectValues, permutationExpression]
  | expressionHead /= Symbol "Association" = do
      permutation <- parsePermutation (length subjectValues) permutationExpression
      reordered <-
        maybe
          (Left (EvaluationError "Permute received an invalid permutation"))
          Right
          (traverse (valueAtDestination subjectValues permutation) [1 .. length subjectValues])
      pure (Call expressionHead reordered)
 where
  valueAtDestination values' permutation destination = do
    sourceIndex <- findSourceIndex destination permutation
    pure (values' !! sourceIndex)
  findSourceIndex destination = go 0
   where
    go _ [] = Nothing
    go index (candidate : rest)
      | destination == candidate = Just index
      | otherwise = go (index + 1) rest
reducePermute values = Right (Call (Symbol "Permute") values)

parsePermutation :: Int -> Expr -> Either EvaluationError [Int]
parsePermutation count = \case
  Call (Symbol "List") values -> validate =<< traverse explicitPosition values
  Call (Symbol "Cycles") [Call (Symbol "List") cycles] -> do
    parsedCycles <- traverse parseCycle cycles
    validate (foldl' applyCycle [1 .. count] parsedCycles)
  _ -> Left (EvaluationError "Permute expects a positional list or Cycles expression")
 where
  explicitPosition (Integer position)
    | position > 0 && position <= fromIntegral count = Right (fromIntegral position)
  explicitPosition _ = Left (EvaluationError "Permute positions must be in range")
  parseCycle (Call (Symbol "List") positions) = traverse explicitPosition positions
  parseCycle _ = Left (EvaluationError "Permute cycles must contain position lists")
  validate permutation
    | length permutation == count
    , allDistinct permutation
    , all (`elem` permutation) [1 .. count] = Right permutation
    | otherwise = Left (EvaluationError "Permute expects a complete permutation")
  applyCycle permutation [] = permutation
  applyCycle permutation [_] = permutation
  applyCycle permutation (firstPosition : remaining) =
    foldl'
      (\result (source, destination) -> replaceListIndex (source - 1) destination result)
      permutation
      (zip (firstPosition : remaining) (remaining <> [firstPosition]))

reducePad :: Bool -> [Expr] -> Either EvaluationError Expr
reducePad leftMode = \case
  [Call (Symbol "List") values, Integer target] -> pad values target (Integer 0)
  [Call (Symbol "List") values, Integer target, fill] -> pad values target fill
  values -> Right (Call (Symbol (if leftMode then "PadLeft" else "PadRight")) values)
 where
  pad values target fill
    | target < 0 = Left (EvaluationError "PadLeft/PadRight expects a non-negative target length")
    | targetLength <= length values =
        Right
          ( list
              ( if leftMode
                  then drop (length values - targetLength) values
                  else take targetLength values
              )
          )
    | leftMode = Right (list (replicate (targetLength - length values) fill <> values))
    | otherwise = Right (list (values <> replicate (targetLength - length values) fill))
   where
    targetLength = fromIntegral target

reduceMean :: [Expr] -> Either EvaluationError Expr
reduceMean [dataExpression] = do
  values <- listOrAssociationValues "Mean" dataExpression
  case values of
    [] -> Left (EvaluationError "Mean of an empty collection is undefined")
    _ ->
      pure
        ( reduceTimes
            [reducePlus values, fromExact (normalizeExact 1 (fromIntegral (length values)))]
        )
reduceMean values = Right (Call (Symbol "Mean") values)

reduceMedian :: [Expr] -> Either EvaluationError Expr
reduceMedian [dataExpression] = do
  values <- listOrAssociationValues "Median" dataExpression
  exactValues <-
    maybe
      (Left (EvaluationError "Median currently expects explicit exact real numbers"))
      Right
      (traverse toExact values)
  case sortBy compareExactValue exactValues of
    [] -> Left (EvaluationError "Median of an empty collection is undefined")
    sorted ->
      let count = length sorted
       in if odd count
            then Right (fromExact (sorted !! (count `div` 2)))
            else
              Right
                ( fromExact
                    ( multiplyExact
                        (addExact (sorted !! (count `div` 2 - 1)) (sorted !! (count `div` 2)))
                        (Exact 1 2)
                    )
                )
 where
  compareExactValue (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
    compare (leftNumerator * rightDenominator) (rightNumerator * leftDenominator)
reduceMedian values = Right (Call (Symbol "Median") values)

data OrderedItem = OrderedItem !Int !Expr !(Maybe AssociationEntry) ![Expr]
  deriving (Eq, Show)

canonicalCompare :: Expr -> Expr -> Ordering
canonicalCompare left right
  | left == right = EQ
  | Just leftExact <- toExact left
  , Just rightExact <- toExact right =
      case compareExact leftExact rightExact of
        EQ -> compare (numericKindRank left, fullForm left) (numericKindRank right, fullForm right)
        ordering -> ordering
  | expressionKindRank left /= expressionKindRank right =
      compare (expressionKindRank left) (expressionKindRank right)
canonicalCompare (String left) (String right) = compare left right
canonicalCompare (Symbol left) (Symbol right) = compare left right
canonicalCompare (ByteArray left) (ByteArray right) = compare left right
canonicalCompare (Call leftHead leftValues) (Call rightHead rightValues) =
  case canonicalCompare leftHead rightHead of
    EQ -> compareExpressionLists leftValues rightValues
    ordering -> ordering
canonicalCompare left right = compare (fullForm left) (fullForm right)

compareExact :: Exact -> Exact -> Ordering
compareExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  compare (leftNumerator * rightDenominator) (rightNumerator * leftDenominator)

numericKindRank :: Expr -> Int
numericKindRank Integer {} = 0
numericKindRank Rational {} = 1
numericKindRank Real {} = 2
numericKindRank Complex {} = 3
numericKindRank Root {} = 4
numericKindRank _ = 5

expressionKindRank :: Expr -> Int
expressionKindRank expression = case expression of
  Integer {} -> 0
  Rational {} -> 0
  Real {} -> 0
  Complex {} -> 0
  Root {} -> 0
  String {} -> 1
  Symbol {} -> 2
  ByteArray {} -> 3
  SparseArray {} -> 4
  Call {} -> 5

compareExpressionLists :: [Expr] -> [Expr] -> Ordering
compareExpressionLists [] [] = EQ
compareExpressionLists [] (_ : _) = LT
compareExpressionLists (_ : _) [] = GT
compareExpressionLists (left : leftRest) (right : rightRest) =
  case canonicalCompare left right of
    EQ -> compareExpressionLists leftRest rightRest
    ordering -> ordering

orderedItems :: Text -> Expr -> Either EvaluationError [OrderedItem]
orderedItems _ association
  | Just entries <- associationEntries association =
      Right
        [ OrderedItem index value (Just entry) []
        | (index, entry@(AssociationEntry _ _ value)) <- zip [1 ..] entries
        ]
orderedItems _ (Call _ values) =
  Right [OrderedItem index value Nothing [] | (index, value) <- zip [1 ..] values]
orderedItems operation _ = Left (EvaluationError (operation <> " expects a compound expression"))

rebuildOrdered :: Expr -> [OrderedItem] -> Expr
rebuildOrdered association items
  | Just _ <- associationEntries association =
      associationExpr [entry | OrderedItem _ _ (Just entry) _ <- items]
rebuildOrdered (Call expressionHead _) items =
  Call expressionHead [value | OrderedItem _ value _ _ <- items]
rebuildOrdered expression _ = expression

orderingFunctionCompare :: Maybe Expr -> Expr -> Expr -> Ordering
orderingFunctionCompare Nothing = canonicalCompare
orderingFunctionCompare (Just function) = compareWithFunction
 where
  compareWithFunction left right = case evaluate (Call function [left, right]) of
    Right (Symbol "True") -> LT
    Right (Integer result) -> compare 0 result
    Right (Symbol "False") -> case evaluate (Call function [right, left]) of
      Right (Symbol "True") -> GT
      Right (Integer result) -> compare result 0
      _ -> EQ
    _ -> canonicalCompare left right

reduceOrder :: [Expr] -> Expr
reduceOrder [left, right] = Integer $ case canonicalCompare left right of
  LT -> 1
  EQ -> 0
  GT -> -1
reduceOrder values = Call (Symbol "Order") values

reduceOrderedQ :: [Expr] -> Either EvaluationError Expr
reduceOrderedQ = \case
  [subject] -> check subject Nothing
  [subject, function] -> check subject (Just function)
  values -> Right (Call (Symbol "OrderedQ") values)
 where
  check subject function = do
    items <- orderedItems "OrderedQ" subject
    let values = [value | OrderedItem _ value _ _ <- items]
        comparisons = zipWith (orderingFunctionCompare function) values (drop 1 values)
    pure (boolean (all (/= GT) comparisons))

reduceOrderingIndices :: [Expr] -> Either EvaluationError Expr
reduceOrderingIndices = \case
  [subject] -> order subject Nothing Nothing
  [subject, count] -> order subject (Just count) Nothing
  [subject, count, function] -> order subject (Just count) (Just function)
  values -> Right (Call (Symbol "Ordering") values)
 where
  order subject count function = do
    items <- orderedItems "Ordering" subject
    let sorted = sortBy (compareOrderedItems function) items
    selected <- countSlice "Ordering" count sorted
    pure (list [Integer (fromIntegral index) | OrderedItem index _ _ _ <- selected])

compareOrderedItems :: Maybe Expr -> OrderedItem -> OrderedItem -> Ordering
compareOrderedItems function (OrderedItem _ left _ _) (OrderedItem _ right _ _) =
  orderingFunctionCompare function left right

countSlice :: Text -> Maybe Expr -> [value] -> Either EvaluationError [value]
countSlice _ Nothing values = Right values
countSlice _ (Just (Symbol "All")) values = Right values
countSlice _ (Just (Integer count)) values
  | count >= 0 = Right (take (min (length values) (fromIntegral count)) values)
  | otherwise = Right (drop (max 0 (length values - fromIntegral (abs count))) values)
countSlice operation _ _ = Left (EvaluationError (operation <> " expects an integer or All count"))

reduceSort :: Bool -> [Expr] -> Either EvaluationError Expr
reduceSort reverseMode = \case
  [subject] -> sortSubject subject Nothing Nothing
  [subject, function] -> sortSubject subject (Just function) Nothing
  [subject, function, count] -> sortSubject subject (Just function) (Just count)
  values -> Right (Call (Symbol (if reverseMode then "ReverseSort" else "Sort")) values)
 where
  sortSubject subject function count = do
    items <- orderedItems operation subject
    let compareItems left right =
          let result = compareOrderedItems function left right
           in if reverseMode then invertOrdering result else result
        sorted = sortBy compareItems items
    selected <- countSlice operation count sorted
    pure (rebuildOrdered subject selected)
  operation = if reverseMode then "ReverseSort" else "Sort"

invertOrdering :: Ordering -> Ordering
invertOrdering LT = GT
invertOrdering EQ = EQ
invertOrdering GT = LT

reduceSortBy :: Bool -> [Expr] -> Either EvaluationError Expr
reduceSortBy reverseMode = \case
  [subject, functions] -> sortSubject subject functions Nothing
  [subject, functions, orderingFunction] -> sortSubject subject functions (Just orderingFunction)
  values -> Right (Call (Symbol operation) values)
 where
  sortSubject subject functions orderingFunction = do
    items <- orderedItems operation subject
    let (keyFunctions, stableTies) = case functions of
          Call (Symbol "List") values -> (values, True)
          _ -> ([functions], False)
    decorated <- traverse (decorate keyFunctions) items
    let compareItems (OrderedItem _ leftValue _ leftKeys) (OrderedItem _ rightValue _ rightKeys) =
          let keyOrdering = compareKeyLists orderingFunction leftKeys rightKeys
              tieOrdering = if stableTies then EQ else canonicalCompare leftValue rightValue
              result = if keyOrdering == EQ then tieOrdering else keyOrdering
           in if reverseMode then invertOrdering result else result
    pure (rebuildOrdered subject (sortBy compareItems decorated))
  decorate functions (OrderedItem index value entry _) = do
    keys <- traverse (\function -> evaluate (Call function [value])) functions
    pure (OrderedItem index value entry keys)
  operation = if reverseMode then "ReverseSortBy" else "SortBy"

compareKeyLists :: Maybe Expr -> [Expr] -> [Expr] -> Ordering
compareKeyLists _ [] [] = EQ
compareKeyLists _ [] (_ : _) = LT
compareKeyLists _ (_ : _) [] = GT
compareKeyLists function (left : leftRest) (right : rightRest) =
  case orderingFunctionCompare function left right of
    EQ -> compareKeyLists function leftRest rightRest
    ordering -> ordering

data SetOperation = SetUnion | SetIntersection | SetComplement

reduceSetOperation :: SetOperation -> [Expr] -> Either EvaluationError Expr
reduceSetOperation operation expressions = do
  collections <- traverse (listOrAssociationValues operationName) expressions
  pure (list (uniqueCanonical (sortBy canonicalCompare (resultValues collections))))
 where
  operationName = case operation of
    SetUnion -> "Union"
    SetIntersection -> "Intersection"
    SetComplement -> "Complement"
  resultValues collections = case operation of
    SetUnion -> concat collections
    SetIntersection -> case collections of
      [] -> []
      firstCollection : remaining ->
        [value | value <- firstCollection, all (value `elem`) remaining]
    SetComplement -> case collections of
      [] -> []
      firstCollection : remaining ->
        let excluded = concat remaining
         in [value | value <- firstCollection, value `notElem` excluded]

uniqueCanonical :: [Expr] -> [Expr]
uniqueCanonical = foldl' appendUnique []
 where
  appendUnique retained value
    | value `elem` retained = retained
    | otherwise = retained <> [value]

predicateMatches :: Expr -> Expr -> Either EvaluationError Bool
predicateMatches criterion value =
  (== Symbol "True") <$> evaluate (Call criterion [value])

selectionLimit :: Text -> Maybe Expr -> Either EvaluationError (Maybe Integer)
selectionLimit _ Nothing = Right Nothing
selectionLimit _ (Just (Symbol "Infinity")) = Right Nothing
selectionLimit _ (Just (Integer limit))
  | limit >= 0 = Right (Just limit)
selectionLimit operation _ =
  Left (EvaluationError (operation <> " expects a non-negative integer or Infinity limit"))

reduceSelect :: Bool -> [Expr] -> Either EvaluationError Expr
reduceSelect discardMode = \case
  [subject, criterion] -> selectSubject subject criterion Nothing
  [subject, criterion, limit] -> selectSubject subject criterion (Just limit)
  values -> Right (Call (Symbol operation) values)
 where
  selectSubject subject criterion limit
    | isPropertySelection criterion =
        Right (Call (Symbol operation) (subject : criterion : maybe [] pure limit))
    | otherwise = do
        items <- orderedItems operation subject
        remaining <- selectionLimit operation limit
        (_, selected) <- foldM (selectItem criterion) (remaining, []) items
        pure (rebuildOrdered subject selected)
  selectItem criterion (remaining, retained) item@(OrderedItem _ value _ _) = do
    matches <- predicateMatches criterion value
    let mayConsume = maybe True (> 0) remaining
        consumes = matches && mayConsume
        nextRemaining = case remaining of
          Just count | consumes -> Just (count - 1)
          _ -> remaining
        keep = if discardMode then not consumes else consumes
    pure (nextRemaining, if keep then retained <> [item] else retained)
  operation = if discardMode then "Discard" else "Select"

isPropertySelection :: Expr -> Bool
isPropertySelection (Call (Symbol "Rule") [_, _]) = True
isPropertySelection (Call (Symbol "RuleDelayed") [_, _]) = True
isPropertySelection _ = False

reduceSelectFirst :: [Expr] -> Either EvaluationError Expr
reduceSelectFirst = \case
  [subject, criterion] -> selectFirst subject criterion Nothing
  [subject, criterion, defaultValue] -> selectFirst subject criterion (Just defaultValue)
  values -> Right (Call (Symbol "SelectFirst") values)
 where
  selectFirst subject criterion defaultValue
    | isPropertySelection criterion =
        Right (Call (Symbol "SelectFirst") (subject : criterion : maybe [] pure defaultValue))
    | otherwise = do
        items <- orderedItems "SelectFirst" subject
        findMatch criterion defaultValue items
  findMatch _ defaultValue [] =
    Right (maybe (Call (Symbol "Missing") [String "NotFound"]) id defaultValue)
  findMatch criterion defaultValue (OrderedItem _ value _ _ : rest) = do
    matches <- predicateMatches criterion value
    if matches then Right value else findMatch criterion defaultValue rest

reduceTakeWhile :: [Expr] -> Either EvaluationError Expr
reduceTakeWhile [subject, criterion] = do
  items <- orderedItems "TakeWhile" subject
  retained <- takeMatching items
  pure (rebuildOrdered subject retained)
 where
  takeMatching [] = Right []
  takeMatching (item@(OrderedItem _ value _ _) : rest) = do
    matches <- predicateMatches criterion value
    if matches then (item :) <$> takeMatching rest else Right []
reduceTakeWhile values = Right (Call (Symbol "TakeWhile") values)

reduceLengthWhile :: [Expr] -> Either EvaluationError Expr
reduceLengthWhile [subject, criterion] = do
  items <- orderedItems "LengthWhile" subject
  Integer . fromIntegral <$> matchingLength items
 where
  matchingLength [] = Right (0 :: Int)
  matchingLength (OrderedItem _ value _ _ : rest) = do
    matches <- predicateMatches criterion value
    if matches then (1 +) <$> matchingLength rest else Right 0
reduceLengthWhile values = Right (Call (Symbol "LengthWhile") values)

reducePick :: [Expr] -> Either EvaluationError Expr
reducePick = \case
  [subject, selector] -> pickSubject subject selector (Symbol "True")
  [subject, selector, pattern] -> pickSubject subject selector pattern
  values -> Right (Call (Symbol "Pick") values)
 where
  pickSubject subject (Call (Symbol "List") selectors) pattern = do
    items <- orderedItems "Pick" subject
    if length items /= length selectors
      then Left (EvaluationError "Pick expects one selector per first-level value")
      else
        pure
          ( rebuildOrdered
              subject
              [item | (item, selector) <- zip items selectors, selector == pattern]
          )
  pickSubject _ _ _ = Left (EvaluationError "Pick expects a selector list")

reduceBoole :: [Expr] -> Expr
reduceBoole [Symbol "True"] = Integer 1
reduceBoole [Symbol "False"] = Integer 0
reduceBoole values = Call (Symbol "Boole") values

data PatternBinding
  = ScalarBinding !Expr
  | SequenceBinding ![Expr]
  deriving (Eq, Show)

type PatternBindings = [(Text, PatternBinding)]

data SequencePattern = SequencePattern
  { sequenceMinimum :: !Int
  , sequenceHead :: !(Maybe Expr)
  , sequenceName :: !(Maybe Text)
  , sequenceCondition :: !(Maybe Expr)
  }
  deriving (Eq, Show)

reduceMatchQ :: [Expr] -> Expr
reduceMatchQ [expression, patternExpression] =
  boolean (maybe False (const True) (matchPattern [] expression patternExpression))
reduceMatchQ values = Call (Symbol "MatchQ") values

matchPattern :: PatternBindings -> Expr -> Expr -> Maybe PatternBindings
matchPattern bindings expression patternExpression = case patternExpression of
  Call (Symbol "Verbatim") [literal] ->
    if expression == literal then Just bindings else Nothing
  Call (Symbol "Pattern") [Symbol name, innerPattern] -> do
    matched <- matchPattern bindings expression innerPattern
    bindScalar name expression matched
  Call (Symbol "Blank") [] -> Just bindings
  Call (Symbol "Blank") [requiredHead] ->
    if headExpr expression == requiredHead then Just bindings else Nothing
  Call (Symbol "BlankSequence") [] -> Just bindings
  Call (Symbol "BlankSequence") [requiredHead] ->
    if headExpr expression == requiredHead then Just bindings else Nothing
  Call (Symbol "BlankNullSequence") [] -> Just bindings
  Call (Symbol "BlankNullSequence") [requiredHead] ->
    if headExpr expression == requiredHead then Just bindings else Nothing
  Call (Symbol "Alternatives") alternatives -> firstMatch alternatives
  Call (Symbol "Except") [excluded] ->
    case matchPattern bindings expression excluded of
      Nothing -> Just bindings
      Just _ -> Nothing
  Call (Symbol "Except") [excluded, included] -> do
    matched <- matchPattern bindings expression included
    case matchPattern bindings expression excluded of
      Nothing -> Just matched
      Just _ -> Nothing
  Call (Symbol "Condition") [innerPattern, condition] -> do
    matched <- matchPattern bindings expression innerPattern
    conditionResult <- either (const Nothing) Just (evaluate (substituteBindings matched condition))
    if conditionResult == Symbol "True" then Just matched else Nothing
  Call patternHead patternArguments -> case expression of
    Call expressionHead expressionArguments -> do
      headBindings <- matchPattern bindings expressionHead patternHead
      matchPatternArguments headBindings expressionArguments patternArguments
    _ -> Nothing
  _ -> if expression == patternExpression then Just bindings else Nothing
 where
  firstMatch [] = Nothing
  firstMatch (alternative : rest) = case matchPattern bindings expression alternative of
    Just matched -> Just matched
    Nothing -> firstMatch rest

matchPatternArguments :: PatternBindings -> [Expr] -> [Expr] -> Maybe PatternBindings
matchPatternArguments bindings [] [] = Just bindings
matchPatternArguments _ [] patterns
  | minimumPatternArguments patterns > 0 = Nothing
matchPatternArguments bindings expressions (patternExpression : remainingPatterns)
  | Just sequencePattern <- sequencePatternDescriptor patternExpression =
      matchSequenceCounts sequencePattern (candidateCounts sequencePattern)
 where
  maximumCount = length expressions - minimumPatternArguments remainingPatterns
  candidateCounts descriptor = [sequenceMinimum descriptor .. maximumCount]
  matchSequenceCounts _ [] = Nothing
  matchSequenceCounts descriptor (count : rest) =
    let (segment, remainingExpressions) = splitAt count expressions
     in case matchSequencePattern bindings descriptor segment of
          Just matched -> case matchPatternArguments matched remainingExpressions remainingPatterns of
            Just completed -> Just completed
            Nothing -> matchSequenceCounts descriptor rest
          Nothing -> matchSequenceCounts descriptor rest
matchPatternArguments bindings (expression : remainingExpressions) (patternExpression : remainingPatterns) = do
  matched <- matchPattern bindings expression patternExpression
  matchPatternArguments matched remainingExpressions remainingPatterns
matchPatternArguments _ _ _ = Nothing

minimumPatternArguments :: [Expr] -> Int
minimumPatternArguments = sum . map minimumForPattern
 where
  minimumForPattern expression =
    maybe 1 sequenceMinimum (sequencePatternDescriptor expression)

sequencePatternDescriptor :: Expr -> Maybe SequencePattern
sequencePatternDescriptor = describe Nothing Nothing
 where
  describe name condition = \case
    Call (Symbol "Pattern") [Symbol patternName, inner] ->
      describe (Just patternName) condition inner
    Call (Symbol "Condition") [inner, test] ->
      describe name (Just test) inner
    Call (Symbol "BlankSequence") [] ->
      Just (SequencePattern 1 Nothing name condition)
    Call (Symbol "BlankSequence") [requiredHead] ->
      Just (SequencePattern 1 (Just requiredHead) name condition)
    Call (Symbol "BlankNullSequence") [] ->
      Just (SequencePattern 0 Nothing name condition)
    Call (Symbol "BlankNullSequence") [requiredHead] ->
      Just (SequencePattern 0 (Just requiredHead) name condition)
    _ -> Nothing

matchSequencePattern :: PatternBindings -> SequencePattern -> [Expr] -> Maybe PatternBindings
matchSequencePattern bindings descriptor values
  | length values < sequenceMinimum descriptor = Nothing
  | maybe False (\requiredHead -> any ((/= requiredHead) . headExpr) values) (sequenceHead descriptor) = Nothing
  | otherwise = do
      bound <- case sequenceName descriptor of
        Nothing -> Just bindings
        Just name -> bindSequence name values bindings
      case sequenceCondition descriptor of
        Nothing -> Just bound
        Just condition -> do
          result <- either (const Nothing) Just (evaluate (substituteBindings bound condition))
          if result == Symbol "True" then Just bound else Nothing

bindScalar :: Text -> Expr -> PatternBindings -> Maybe PatternBindings
bindScalar name value bindings = case lookup name bindings of
  Nothing -> Just ((name, ScalarBinding value) : bindings)
  Just (ScalarBinding existing) | existing == value -> Just bindings
  _ -> Nothing

bindSequence :: Text -> [Expr] -> PatternBindings -> Maybe PatternBindings
bindSequence name values bindings = case lookup name bindings of
  Nothing -> Just ((name, SequenceBinding values) : bindings)
  Just (SequenceBinding existing) | existing == values -> Just bindings
  _ -> Nothing

substituteBindings :: PatternBindings -> Expr -> Expr
substituteBindings bindings expression = case expression of
  Symbol name -> case lookup name bindings of
    Just (ScalarBinding value) -> value
    Just (SequenceBinding values) -> Call (Symbol "Sequence") values
    Nothing -> expression
  Call expressionHead values ->
    Call
      (substituteBindings bindings expressionHead)
      (concatMap substituteArgument values)
  _ -> expression
 where
  substituteArgument (Symbol name) = case lookup name bindings of
    Just (ScalarBinding value) -> [value]
    Just (SequenceBinding values) -> values
    Nothing -> [Symbol name]
  substituteArgument value = [substituteBindings bindings value]

data LevelBounds = LevelBounds !Int !Int
  deriving (Eq, Show)

data PatternRecord = PatternRecord !Expr !Int !Int
  deriving (Eq, Show)

data PatternPathRecord = PatternPathRecord !Expr !Int !Int ![PathSelector]
  deriving (Eq, Show)

levelInfinity :: Int
levelInfinity = maxBound `div` 4

normalizeLevelSpec :: Expr -> Either EvaluationError LevelBounds
normalizeLevelSpec = \case
  Integer level
    | level >= 0 -> Right (LevelBounds (if level == 0 then 0 else 1) (integerLevel level))
    | otherwise -> Right (LevelBounds 1 (integerLevel level))
  Symbol "Infinity" -> Right (LevelBounds 1 levelInfinity)
  Call (Symbol "List") [bound] -> do
    value <- normalizeLevelBound bound
    Right (LevelBounds value value)
  Call (Symbol "List") [lower, upper] ->
    LevelBounds <$> normalizeLevelBound lower <*> normalizeLevelBound upper
  _ -> Left (EvaluationError "an unsupported level specification was provided")
 where
  integerLevel value
    | value > fromIntegral levelInfinity = levelInfinity
    | value < fromIntegral (negate levelInfinity) = negate levelInfinity
    | otherwise = fromIntegral value

normalizeLevelBound :: Expr -> Either EvaluationError Int
normalizeLevelBound (Integer value)
  | value > fromIntegral levelInfinity = Right levelInfinity
  | value < fromIntegral (negate levelInfinity) = Right (negate levelInfinity)
  | otherwise = Right (fromIntegral value)
normalizeLevelBound (Symbol "Infinity") = Right levelInfinity
normalizeLevelBound _ = Left (EvaluationError "an unsupported level bound was provided")

levelMatches :: LevelBounds -> Int -> Int -> Bool
levelMatches (LevelBounds lower upper) positive negative
  | lower >= 0 && upper >= 0 = lower <= positive && positive <= upper
  | lower < 0 && upper < 0 = lower <= negative && negative <= upper
  | lower >= 0 && upper < 0 = positive >= lower && negative <= upper
  | otherwise = negative >= lower || positive <= upper

collectPatternRecords :: Bool -> Int -> Expr -> [PatternRecord]
collectPatternRecords includeHeads positive expression =
  children <> [PatternRecord expression positive (negate (expressionDepth expression))]
 where
  children
    | Just entries <- associationEntries expression =
        headRecords <> concatMap (collectPatternRecords includeHeads (positive + 1) . associationEntryValue) entries
    | Call expressionHead values <- expression =
        headRecordsFor expressionHead <> concatMap (collectPatternRecords includeHeads (positive + 1)) values
    | otherwise = []
  headRecords =
    if includeHeads
      then collectPatternRecords includeHeads (positive + 1) (Symbol "Association")
      else []
  headRecordsFor expressionHead =
    if includeHeads
      then collectPatternRecords includeHeads (positive + 1) expressionHead
      else []

collectPatternPathRecords :: Int -> [PathSelector] -> Expr -> [PatternPathRecord]
collectPatternPathRecords positive path expression =
  children <> [PatternPathRecord expression positive (negate (expressionDepth expression)) path]
 where
  children
    | Just entries <- associationEntries expression =
        concat
          [ collectPatternPathRecords
              (positive + 1)
              (path <> [KeySelector key])
              value
          | AssociationEntry _ key value <- entries
          ]
    | Call _ values <- expression =
        concat
          [ collectPatternPathRecords
              (positive + 1)
              (path <> [ArgumentSelector (fromIntegral index)])
              value
          | (index, value) <- zip [1 :: Int ..] values
          ]
    | otherwise = []

patternMatches :: Expr -> Expr -> Bool
patternMatches expression patternExpression =
  maybe False (const True) (matchPattern [] expression patternExpression)

matchingRecords :: LevelBounds -> Maybe Integer -> Expr -> [PatternRecord] -> [PatternRecord]
matchingRecords bounds limit patternExpression = go limit
 where
  go _ [] = []
  go (Just 0) _ = []
  go remaining (record@(PatternRecord expression positive negative) : rest)
    | levelMatches bounds positive negative
    , patternMatches expression patternExpression =
        record : go (subtractOne remaining) rest
    | otherwise = go remaining rest
  subtractOne Nothing = Nothing
  subtractOne (Just count) = Just (count - 1)

matchingPathRecords :: LevelBounds -> Maybe Integer -> Expr -> [PatternPathRecord] -> [PatternPathRecord]
matchingPathRecords bounds limit patternExpression = go limit
 where
  go _ [] = []
  go (Just 0) _ = []
  go remaining (record@(PatternPathRecord expression positive negative _) : rest)
    | levelMatches bounds positive negative
    , patternMatches expression patternExpression =
        record : go (subtractOne remaining) rest
    | otherwise = go remaining rest
  subtractOne Nothing = Nothing
  subtractOne (Just count) = Just (count - 1)

reduceFreeQ :: [Expr] -> Either EvaluationError Expr
reduceFreeQ = \case
  [expression, patternExpression] -> freeAtLevels expression patternExpression (Call (Symbol "List") [Integer 0, Symbol "Infinity"])
  [expression, patternExpression, specification] -> freeAtLevels expression patternExpression specification
  values -> Right (Call (Symbol "FreeQ") values)
 where
  freeAtLevels expression patternExpression specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds (Just 1) patternExpression (collectPatternRecords True 0 expression)
    pure (boolean (null matched))

reduceMemberQ :: [Expr] -> Either EvaluationError Expr
reduceMemberQ = \case
  [expression, patternExpression] -> memberAtLevels expression patternExpression (Call (Symbol "List") [Integer 1])
  [expression, patternExpression, specification] -> memberAtLevels expression patternExpression specification
  values -> Right (Call (Symbol "MemberQ") values)
 where
  memberAtLevels expression patternExpression specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds (Just 1) patternExpression (collectPatternRecords False 0 expression)
    pure (boolean (not (null matched)))

reduceCount :: [Expr] -> Either EvaluationError Expr
reduceCount = \case
  [expression, patternExpression] -> countAtLevels expression patternExpression (Call (Symbol "List") [Integer 1])
  [expression, patternExpression, specification] -> countAtLevels expression patternExpression specification
  values -> Right (Call (Symbol "Count") values)
 where
  countAtLevels expression patternExpression specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds Nothing patternExpression (collectPatternRecords False 0 expression)
    pure (Integer (fromIntegral (length matched)))

reduceCases :: [Expr] -> Either EvaluationError Expr
reduceCases = \case
  [expression, patternExpression] -> casesAtLevels expression patternExpression (Integer 1) Nothing
  [expression, patternExpression, specification] -> casesAtLevels expression patternExpression specification Nothing
  [expression, patternExpression, specification, limit] -> casesAtLevels expression patternExpression specification (Just limit)
  values -> Right (Call (Symbol "Cases") values)
 where
  casesAtLevels expression patternExpression specification limit = do
    bounds <- normalizeLevelSpec specification
    normalizedLimit <- selectionLimit "Cases" limit
    let (matchExpression, template) = case patternRule patternExpression of
          Just (PatternRule pattern' template') -> (pattern', Just template')
          Nothing -> (patternExpression, Nothing)
    results <- collectCases bounds normalizedLimit matchExpression template (collectPatternRecords False 0 expression)
    pure (evaluatedList results)
  collectCases _ _ _ _ [] = Right []
  collectCases _ (Just 0) _ _ _ = Right []
  collectCases bounds remaining patternExpression template (PatternRecord value positive negative : rest)
    | not (levelMatches bounds positive negative) =
        collectCases bounds remaining patternExpression template rest
    | otherwise = case matchPattern [] value patternExpression of
        Nothing -> collectCases bounds remaining patternExpression template rest
        Just bindings -> do
          transformed <- case template of
            Nothing -> Right (Just value)
            Just templateExpression -> instantiatePatternTemplate bindings templateExpression
          case transformed of
            Nothing -> collectCases bounds remaining patternExpression template rest
            Just result -> do
              following <- collectCases bounds (subtractOne remaining) patternExpression template rest
              pure (spliceCaseResult result <> following)
  subtractOne Nothing = Nothing
  subtractOne (Just count) = Just (count - 1)
  spliceCaseResult (Call (Symbol "Sequence") values) = values
  spliceCaseResult value = [value]

reduceDeleteCases :: [Expr] -> Either EvaluationError Expr
reduceDeleteCases = \case
  [expression, patternExpression] -> deleteAtLevels expression patternExpression (Integer 1) Nothing
  [expression, patternExpression, specification] -> deleteAtLevels expression patternExpression specification Nothing
  [expression, patternExpression, specification, limit] -> deleteAtLevels expression patternExpression specification (Just limit)
  values -> Right (Call (Symbol "DeleteCases") values)
 where
  deleteAtLevels expression patternExpression specification limit = do
    bounds <- normalizeLevelSpec specification
    normalizedLimit <- selectionLimit "DeleteCases" limit
    let matched =
          matchingPathRecords
            bounds
            normalizedLimit
            patternExpression
            (collectPatternPathRecords 0 [] expression)
        paths = [path | PatternPathRecord _ _ _ path <- matched]
    if [] `elem` paths
      then Right (Call (Symbol "Sequence") [])
      else foldM deletePath expression (sortOperationPaths paths)
  deletePath expression path =
    maybe
      (Left (EvaluationError "DeleteCases encountered an invalid matched path"))
      Right
      (deleteAtPath path expression)

reduceFirstCase :: [Expr] -> Either EvaluationError Expr
reduceFirstCase = \case
  [expression, patternExpression] -> firstAtLevels expression patternExpression Nothing (Integer 1)
  [expression, patternExpression, defaultValue] -> firstAtLevels expression patternExpression (Just defaultValue) (Integer 1)
  [expression, patternExpression, defaultValue, specification] ->
    firstAtLevels expression patternExpression (Just defaultValue) specification
  values -> Right (Call (Symbol "FirstCase") values)
 where
  firstAtLevels expression patternExpression defaultValue specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds (Just 1) patternExpression (collectPatternRecords False 0 expression)
    case matched of
      PatternRecord value _ _ : _ -> Right value
      [] -> Right (maybe (Call (Symbol "Missing") [String "NotFound"]) id defaultValue)

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
reduceTotal [Call (Symbol "List") values]
  | Just rows@(firstRow : _) <- traverse listArguments values
  , all ((== length firstRow) . length) rows =
      list (map reducePlus (transpose rows))
reduceTotal [Call (Symbol "List") values] = reducePlus values
reduceTotal [association]
  | Just entries <- associationEntries association =
      reducePlus [value | AssociationEntry _ _ value <- entries]
reduceTotal values = Call (Symbol "Total") values

reduceAccumulate :: [Expr] -> Expr
reduceAccumulate [association]
  | Just entries@(AssociationEntry _ _ firstValue : remaining) <- associationEntries association =
      let accumulatedValues =
            scanl
              (\accumulator (AssociationEntry _ _ value) -> reducePlus [accumulator, value])
              firstValue
              remaining
       in associationExpr
            ( zipWith
                (\(AssociationEntry ruleHead key _) value -> AssociationEntry ruleHead key value)
                entries
                accumulatedValues
            )
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

positionPaths :: Expr -> [[PathSelector]]
positionPaths expression
  | Just selector <- pathSelector expression = [[selector]]
positionPaths (Call (Symbol "List") values)
  | Just path <- traverse pathSelector values = [path]
  | otherwise = concatMap listPath values
 where
  listPath (Call (Symbol "List") components) = maybe [] pure (traverse pathSelector components)
  listPath _ = []
positionPaths _ = []

pathSelector :: Expr -> Maybe PathSelector
pathSelector (Integer position) = Just (ArgumentSelector position)
pathSelector selector
  | Just key <- keySelectorValue selector = Just (KeySelector key)
pathSelector _ = Nothing

hasMultiplePositionPaths :: Expr -> Bool
hasMultiplePositionPaths (Call (Symbol "List") values) =
  case traverse pathSelector values of
    Just _ -> False
    Nothing -> any isExplicitPath values
 where
  isExplicitPath (Call (Symbol "List") components) =
    maybe False (const True) (traverse pathSelector components)
  isExplicitPath _ = False
hasMultiplePositionPaths _ = False

replacePartRules :: Expr -> [([PathSelector], Expr)]
replacePartRules (Call (Symbol "List") rules) = concatMap replacePartRules rules
replacePartRules (Call (Symbol ruleHead) [position, replacement])
  | ruleHead `elem` ["Rule", "RuleDelayed"] =
      [(path, replacement) | path <- positionPaths position]
replacePartRules _ = []

sortOperationPaths :: [[PathSelector]] -> [[PathSelector]]
sortOperationPaths = sortBy compareOperationPath

sortReplacementRules :: [([PathSelector], Expr)] -> [([PathSelector], Expr)]
sortReplacementRules = sortBy (\(left, _) (right, _) -> compareOperationPath left right)

compareOperationPath :: [PathSelector] -> [PathSelector] -> Ordering
compareOperationPath left right = case compare (length right) (length left) of
  EQ -> compareSelectors right left
  ordering -> ordering
 where
  compareSelectors [] [] = EQ
  compareSelectors [] (_ : _) = LT
  compareSelectors (_ : _) [] = GT
  compareSelectors (leftSelector : leftRest) (rightSelector : rightRest) =
    case compareSelector leftSelector rightSelector of
      EQ -> compareSelectors leftRest rightRest
      ordering -> ordering
  compareSelector (ArgumentSelector leftPosition) (ArgumentSelector rightPosition) =
    compare leftPosition rightPosition
  compareSelector (KeySelector leftKey) (KeySelector rightKey) =
    compare (fullForm leftKey) (fullForm rightKey)
  compareSelector ArgumentSelector {} KeySelector {} = LT
  compareSelector KeySelector {} ArgumentSelector {} = GT

selectAtPath :: [PathSelector] -> Expr -> Maybe Expr
selectAtPath [] expression = Just expression
selectAtPath (selector : remaining) association
  | Just entries <- associationEntries association = do
      entry <- associationEntryForSelector selector entries
      selectAtPath remaining (associationEntryValue entry)
selectAtPath (ArgumentSelector position : remaining) (Call _ values) = do
  index <- resolvePosition (length values) position
  selectAtPath remaining (values !! index)
selectAtPath _ _ = Nothing

deleteAtPath :: [PathSelector] -> Expr -> Maybe Expr
deleteAtPath [] _ = Nothing
deleteAtPath [selector] association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      pure (associationExpr (take index entries <> drop (index + 1) entries))
deleteAtPath (selector : remaining) association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- deleteAtPath remaining (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
deleteAtPath [ArgumentSelector position] (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  pure (Call expressionHead (take index values <> drop (index + 1) values))
deleteAtPath (ArgumentSelector position : remaining) (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- deleteAtPath remaining (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
deleteAtPath _ _ = Nothing

replaceAtPath :: [PathSelector] -> Expr -> Expr -> Maybe Expr
replaceAtPath [] replacement _ = Just replacement
replaceAtPath (selector : remaining) replacement association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- replaceAtPath remaining replacement (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
replaceAtPath (ArgumentSelector position : remaining) replacement (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- replaceAtPath remaining replacement (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
replaceAtPath _ _ _ = Nothing

mapAtPath :: [PathSelector] -> Expr -> Expr -> Maybe Expr
mapAtPath [] function expression = Just (Call function [expression])
mapAtPath (selector : remaining) function association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- mapAtPath remaining function (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
mapAtPath (ArgumentSelector position : remaining) function (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- mapAtPath remaining function (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
mapAtPath _ _ _ = Nothing

replaceAssociationEntryValue :: Int -> Expr -> [AssociationEntry] -> [AssociationEntry]
replaceAssociationEntryValue index replacement entries =
  case entries !! index of
    AssociationEntry ruleHead key _ ->
      replaceListIndex index (AssociationEntry ruleHead key replacement) entries

insertAtPath :: [PathSelector] -> Expr -> Expr -> Maybe Expr
insertAtPath [] _ _ = Nothing
insertAtPath (selector : remaining@(_ : _)) item association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- insertAtPath remaining item (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
insertAtPath [ArgumentSelector position] item (Call expressionHead values) = do
  index <- insertOffset (length values) position
  pure (Call expressionHead (take index values <> [item] <> drop index values))
insertAtPath (ArgumentSelector position : remaining) item (Call expressionHead values) = do
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

data PatternRule = PatternRule !Expr !Expr
  deriving (Eq, Show)

reduceReplace :: [Expr] -> Either EvaluationError Expr
reduceReplace = \case
  [expression, rules] -> replaceAtLevels expression rules (Call (Symbol "List") [Integer 0])
  [expression, rules, specification] -> replaceAtLevels expression rules specification
  values -> Right (Call (Symbol "Replace") values)
 where
  replaceAtLevels expression rules specification
    | Just nested <- nestedPatternRuleSets rules =
        evaluatedList <$> traverse (\ruleset -> replaceAtLevels expression ruleset specification) nested
    | otherwise = do
        ruleset <- requirePatternRuleSet "Replace" rules
        bounds <- normalizeLevelSpec specification
        let records =
              [ record
              | record@(PatternPathRecord _ positive negative _) <- collectPatternPathRecords 0 [] expression
              , levelMatches bounds positive negative
              ]
        foldM (replaceRecord ruleset) expression records
  replaceRecord ruleset current (PatternPathRecord _ _ _ path) = do
    selected <-
      maybe
        (Left (EvaluationError "Replace encountered an invalid selected path"))
        Right
        (selectAtPath path current)
    replacement <- applyPatternRules ruleset selected
    pure $ case replacement of
      Nothing -> current
      Just value -> maybe current id (replaceAtPath path value current)

reduceReplaceAll :: [Expr] -> Either EvaluationError Expr
reduceReplaceAll [expression, rules]
  | Just nested <- nestedPatternRuleSets rules =
      evaluatedList <$> traverse (reduceReplaceAll . (expression :) . pure) nested
  | otherwise = do
      ruleset <- requirePatternRuleSet "ReplaceAll" rules
      replaceAllWithRules ruleset expression
reduceReplaceAll values = Right (Call (Symbol "ReplaceAll") values)

reduceReplaceRepeated :: [Expr] -> Either EvaluationError Expr
reduceReplaceRepeated [expression, rules]
  | Just nested <- nestedPatternRuleSets rules =
      evaluatedList <$> traverse (reduceReplaceRepeated . (expression :) . pure) nested
 | otherwise = do
      ruleset <- requirePatternRuleSet "ReplaceRepeated" rules
      iterateReplacement 0 ruleset expression
 where
  iterateReplacement :: Int -> [PatternRule] -> Expr -> Either EvaluationError Expr
  iterateReplacement iterations ruleset current
    | iterations >= 1024 = Left (EvaluationError "ReplaceRepeated exceeded its iteration safety limit")
    | otherwise = do
        updated <- replaceAllWithRules ruleset current
        if updated == current
          then Right current
          else iterateReplacement (iterations + 1) ruleset updated
reduceReplaceRepeated values = Right (Call (Symbol "ReplaceRepeated") values)

requirePatternRuleSet :: Text -> Expr -> Either EvaluationError [PatternRule]
requirePatternRuleSet operation expression =
  maybe
    (Left (EvaluationError (operation <> " expects a rule or flat list of rules")))
    Right
    (patternRuleSet expression)

patternRuleSet :: Expr -> Maybe [PatternRule]
patternRuleSet (Call (Symbol "List") values) = traverse patternRule values
patternRuleSet expression = pure <$> patternRule expression

patternRule :: Expr -> Maybe PatternRule
patternRule (Call (Symbol ruleHead) [patternExpression, template])
  | ruleHead `elem` ["Rule", "RuleDelayed"] = Just (PatternRule patternExpression template)
patternRule _ = Nothing

nestedPatternRuleSets :: Expr -> Maybe [Expr]
nestedPatternRuleSets (Call (Symbol "List") values@(_ : _))
  | all isRuleList values = Just values
 where
  isRuleList expression@(Call (Symbol "List") _) = maybe False (const True) (patternRuleSet expression)
  isRuleList _ = False
nestedPatternRuleSets _ = Nothing

applyPatternRules :: [PatternRule] -> Expr -> Either EvaluationError (Maybe Expr)
applyPatternRules [] _ = Right Nothing
applyPatternRules (PatternRule patternExpression template : rest) expression =
  case matchPattern [] expression patternExpression of
    Nothing -> applyPatternRules rest expression
    Just bindings -> do
      instantiated <- instantiatePatternTemplate bindings template
      case instantiated of
        Just value -> Right (Just value)
        Nothing -> applyPatternRules rest expression

instantiatePatternTemplate :: PatternBindings -> Expr -> Either EvaluationError (Maybe Expr)
instantiatePatternTemplate bindings (Call (Symbol "Condition") [template, condition]) = do
  conditionResult <- evaluate (substituteBindings bindings condition)
  if conditionResult == Symbol "True"
    then Just <$> evaluate (substituteBindings bindings template)
    else Right Nothing
instantiatePatternTemplate bindings template =
  Just <$> evaluate (substituteBindings bindings template)

replaceAllWithRules :: [PatternRule] -> Expr -> Either EvaluationError Expr
replaceAllWithRules rules expression = do
  rootReplacement <- applyPatternRules rules expression
  case rootReplacement of
    Just replacement -> Right replacement
    Nothing -> descend expression
 where
  descend association
    | Just entries <- associationEntries association = do
        headReplacement <- applyPatternRules rules (Symbol "Association")
        case headReplacement of
          Just replacementHead ->
            Right
              ( Call
                  replacementHead
                  [Call (Symbol ruleHead) [key, value] | AssociationEntry ruleHead key value <- entries]
              )
          Nothing -> do
            updated <- traverse replaceEntry entries
            pure (associationExpr [entry | Just entry <- updated])
  descend (Call expressionHead values) = do
    updatedHead <- replaceAllWithRules rules expressionHead
    updatedValues <- traverse (replaceAllWithRules rules) values
    pure (rebuildWithSplicing updatedHead updatedValues)
  descend value = Right value
  replaceEntry (AssociationEntry ruleHead key value) = do
    updated <- replaceAllWithRules rules value
    pure
      ( if updated == Symbol "Nothing"
          then Nothing
          else Just (AssociationEntry ruleHead key updated)
      )

rebuildWithSplicing :: Expr -> [Expr] -> Expr
rebuildWithSplicing expressionHead values =
  Call expressionHead (filterNothing (concatMap splice values))
 where
  splice (Call (Symbol "Sequence") sequenceValues) = sequenceValues
  splice value = [value]
  filterNothing
    | expressionHead == Symbol "List" = filter (/= Symbol "Nothing")
    | otherwise = id

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
