{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure plans for the runtime-backed random collection operations.
--
-- The expression evaluator must stay deterministic, so random selection is
-- represented as a small request tree.  'RandomBelow' requests an integer in
-- @[0, bound)@; a session interpreter can satisfy that request from an
-- injectable runtime callback, while tests can use 'runRandomPlanState' with a
-- scripted source of draws.
module Tungsten.Random
  ( RandomPlan (..)
  , RandomPlanError (..)
  , randomPermutationPlan
  , randomSamplePlan
  , runRandomPlanState
  , runRandomPlanWith
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Expression (Expr (..))

-- | A pure computation that either finishes, fails validation, or requests a
-- uniformly distributed integer below an exclusive upper bound.
data RandomPlan value
  = RandomDone value
  | RandomFailed !RandomPlanError
  | RandomBelow !Integer (Integer -> RandomPlan value)

newtype RandomPlanError = RandomPlanError
  { randomPlanErrorMessage :: Text
  }
  deriving (Eq, Show)

-- | Interpret a plan with an explicitly threaded state.  This is useful both
-- for deterministic tests and for adapting the plan to another pure effect
-- representation.
runRandomPlanState
  :: (Integer -> state -> Either RandomPlanError (Integer, state))
  -> state
  -> RandomPlan value
  -> Either RandomPlanError (value, state)
runRandomPlanState drawBelow = go
 where
  go state = \case
    RandomDone value -> Right (value, state)
    RandomFailed failure -> Left failure
    RandomBelow bound resume -> do
      (draw, updated) <- drawBelow bound state
      go updated (resume draw)

-- | Interpret a plan in any monad that can provide bounded integer draws.
-- A session can pass an action that emits its @RandomBelow@ runtime effect;
-- production IO can pass the corresponding field from @SessionRuntime@.
runRandomPlanWith
  :: Monad action
  => (Integer -> action Integer)
  -> RandomPlan value
  -> action (Either RandomPlanError value)
runRandomPlanWith drawBelow = go
 where
  go = \case
    RandomDone value -> pure (Right value)
    RandomFailed failure -> pure (Left failure)
    RandomBelow bound resume -> drawBelow bound >>= go . resume

-- | Plan @RandomSample[expression]@ or
-- @RandomSample[expression, count]@ after ordinary argument evaluation.
--
-- The draw schedule mirrors CPython's @random.sample@: a compact pool is used
-- when it is cheaper than a selected-index set, and sparse samples use
-- rejection sampling.  Matching the schedule makes scripted runtimes precise
-- while retaining uniform sampling without replacement.
randomSamplePlan :: Expr -> Maybe Expr -> RandomPlan Expr
randomSamplePlan expression count = case sampleItems expression of
  Left failure -> RandomFailed failure
  Right (items, rebuild) ->
    case resolveSampleCount (toInteger (length items)) count of
      Left failure -> RandomFailed failure
      Right selectedCount
        | selectedCount == 0 -> RandomDone (rebuild [])
        | toInteger (length items) <= sampleSetSize selectedCount ->
            sampleFromPool
              rebuild
              selectedCount
              (toInteger (length items))
              (Seq.fromList items)
              []
        | otherwise ->
            sampleWithSelectedIndices
              rebuild
              selectedCount
              (toInteger (length items))
              (Seq.fromList items)
              Set.empty
              []

-- | Plan @RandomPermutation[n]@ after ordinary argument evaluation.  The
-- permutation uses the same descending Fisher--Yates swaps as Python's
-- @random.shuffle@ and is returned in canonical @Cycles[...]@ form.
randomPermutationPlan :: Expr -> RandomPlan Expr
randomPermutationPlan = \case
  Integer lengthValue
    | lengthValue < 0 ->
        RandomFailed
          (RandomPlanError "RandomPermutation expects a non-negative integer.")
    | lengthValue <= 1 -> RandomDone emptyCycles
    | otherwise -> shufflePermutation lengthValue lengthValue Map.empty
  _ ->
    RandomFailed
      (RandomPlanError "RandomPermutation currently expects an integer length.")

data SampleItem = SampleItem
  { sampleItemValue :: !Expr
  , sampleItemEntry :: !(Maybe Expr)
  }

sampleItems
  :: Expr
  -> Either RandomPlanError ([SampleItem], [SampleItem] -> Expr)
sampleItems association
  | Just entries <- associationEntries association =
      Right
        ( [SampleItem value (Just entry) | entry <- entries, Just value <- [ruleValue entry]]
        , rebuildAssociation
        )
sampleItems (Call expressionHead values) =
  Right
    ( [SampleItem value Nothing | value <- values]
    , rebuildOrdinary expressionHead
    )
sampleItems _ =
  Left (RandomPlanError "RandomSample expects a nonatomic expression.")

resolveSampleCount
  :: Integer
  -> Maybe Expr
  -> Either RandomPlanError Integer
resolveSampleCount available count = do
  requested <- case count of
    Nothing -> Right available
    Just (Symbol "All") -> Right available
    Just (Call (Symbol name) [Integer maximumCount])
      | systemNameIs "UpTo" name -> Right (min available maximumCount)
    Just (Integer exactCount) -> Right exactCount
    _ ->
      Left
        ( RandomPlanError
            "RandomSample expects an integer, UpTo[n], All, or no count."
        )
  if requested < 0 || requested > available
    then
      Left
        ( RandomPlanError
            "RandomSample count must be between 0 and the sequence length."
        )
    else Right requested

-- CPython starts with the difference between a small set and an empty list.
-- For larger samples it adds the smallest power of four that can hold three
-- times the requested number of selected indices.
sampleSetSize :: Integer -> Integer
sampleSetSize selectedCount
  | selectedCount <= 5 = 21
  | otherwise = 21 + leastPowerOfFourAtLeast (3 * selectedCount)

leastPowerOfFourAtLeast :: Integer -> Integer
leastPowerOfFourAtLeast target = go 1
 where
  go power
    | power >= target = power
    | otherwise = go (power * 4)

sampleFromPool
  :: ([SampleItem] -> Expr)
  -> Integer
  -> Integer
  -> Seq.Seq SampleItem
  -> [SampleItem]
  -> RandomPlan Expr
sampleFromPool rebuild remaining activeLength pool retained
  | remaining == 0 = RandomDone (rebuild (reverse retained))
  | otherwise =
      checkedRandomBelow activeLength $ \draw ->
        let selectedIndex = fromInteger draw
            lastIndex = fromInteger (activeLength - 1)
            selected = Seq.index pool selectedIndex
            lastActive = Seq.index pool lastIndex
            updatedPool = Seq.update selectedIndex lastActive pool
         in sampleFromPool
              rebuild
              (remaining - 1)
              (activeLength - 1)
              updatedPool
              (selected : retained)

sampleWithSelectedIndices
  :: ([SampleItem] -> Expr)
  -> Integer
  -> Integer
  -> Seq.Seq SampleItem
  -> Set.Set Integer
  -> [SampleItem]
  -> RandomPlan Expr
sampleWithSelectedIndices rebuild remaining populationLength population selected retained
  | remaining == 0 = RandomDone (rebuild (reverse retained))
  | otherwise = requestUniqueIndex
 where
  requestUniqueIndex =
    checkedRandomBelow populationLength $ \draw ->
      if Set.member draw selected
        then requestUniqueIndex
        else
          sampleWithSelectedIndices
            rebuild
            (remaining - 1)
            populationLength
            population
            (Set.insert draw selected)
            (Seq.index population (fromInteger draw) : retained)

checkedRandomBelow
  :: Integer
  -> (Integer -> RandomPlan value)
  -> RandomPlan value
checkedRandomBelow bound resume =
  RandomBelow bound $ \draw ->
    if draw < 0 || draw >= bound
      then
        RandomFailed
          ( RandomPlanError
              ( "random-below callback returned "
                  <> T.pack (show draw)
                  <> " for exclusive upper bound "
                  <> T.pack (show bound)
                  <> "."
              )
          )
      else resume draw

rebuildAssociation :: [SampleItem] -> Expr
rebuildAssociation items =
  Call
    (Symbol "Association")
    ( normalizeAssociationEntries
        [entry | item <- items, Just entry <- [sampleItemEntry item]]
    )

normalizeAssociationEntries :: [Expr] -> [Expr]
normalizeAssociationEntries = foldl retainEntry []
 where
  retainEntry retained entry = case ruleKey entry of
    Nothing -> retained
    Just key -> case break ((== Just key) . ruleKey) retained of
      (_, []) -> retained <> [entry]
      (before, _ : after) -> before <> (entry : after)

rebuildOrdinary :: Expr -> [SampleItem] -> Expr
rebuildOrdinary expressionHead items =
  Call expressionHead retained
 where
  values = map sampleItemValue items
  spliced
    | suppressesSequences expressionHead = values
    | otherwise = concatMap (spliceArgument expressionHead) values
  retained
    | expressionHead `elem` [Symbol "Association", Symbol "List"] =
        filter (/= Symbol "Nothing") spliced
    | otherwise = spliced

spliceArgument :: Expr -> Expr -> [Expr]
spliceArgument expressionHead = \case
  Call (Symbol sequenceHead) sequenceValues
    | systemNameIs "Sequence" sequenceHead -> sequenceValues
  Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues]
    | systemNameIs "Splice" spliceHead
    , systemNameIs "List" listHead
    , expressionHead == Symbol "List" -> spliceValues
  Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues, target]
    | systemNameIs "Splice" spliceHead
    , systemNameIs "List" listHead
    , target == expressionHead -> spliceValues
  value -> [value]

suppressesSequences :: Expr -> Bool
suppressesSequences (Symbol name) =
  name `elem` ["HoldComplete", "Rule", "RuleDelayed", "Unevaluated"]
suppressesSequences _ = False

associationEntries :: Expr -> Maybe [Expr]
associationEntries (Call (Symbol name) values)
  | systemNameIs "Association" name
  , all isRule values = Just values
associationEntries _ = Nothing

isRule :: Expr -> Bool
isRule expression = case ruleKey expression of
  Just _ -> True
  Nothing -> False

ruleKey :: Expr -> Maybe Expr
ruleKey (Call (Symbol name) [key, _])
  | systemNameIs "Rule" name || systemNameIs "RuleDelayed" name = Just key
ruleKey _ = Nothing

ruleValue :: Expr -> Maybe Expr
ruleValue (Call (Symbol name) [_, value])
  | systemNameIs "Rule" name || systemNameIs "RuleDelayed" name = Just value
ruleValue _ = Nothing

systemNameIs :: Text -> Text -> Bool
systemNameIs expected actual =
  actual == expected || actual == "System`" <> expected

shufflePermutation
  :: Integer
  -> Integer
  -> Map.Map Integer Integer
  -> RandomPlan Expr
shufflePermutation lengthValue bound permutation
  | bound <= 1 = RandomDone (permutationCycles lengthValue permutation)
  | otherwise =
      checkedRandomBelow bound $ \zeroBasedIndex ->
        let selectedPosition = zeroBasedIndex + 1
            finalPosition = bound
            selectedValue = permutationValue selectedPosition permutation
            finalValue = permutationValue finalPosition permutation
            swapped =
              storePermutationValue
                finalPosition
                selectedValue
                (storePermutationValue selectedPosition finalValue permutation)
         in shufflePermutation lengthValue (bound - 1) swapped

storePermutationValue
  :: Integer
  -> Integer
  -> Map.Map Integer Integer
  -> Map.Map Integer Integer
storePermutationValue position value
  | position == value = Map.delete position
  | otherwise = Map.insert position value

permutationValue :: Integer -> Map.Map Integer Integer -> Integer
permutationValue position = Map.findWithDefault position position

permutationCycles :: Integer -> Map.Map Integer Integer -> Expr
permutationCycles lengthValue permutation =
  Call (Symbol "Cycles") [Call (Symbol "List") (go 1 Set.empty [])]
 where
  go start seen retained
    | start > lengthValue = reverse retained
    | Set.member start seen = go (start + 1) seen retained
    | permutationValue start permutation == start =
        go (start + 1) (Set.insert start seen) retained
    | otherwise =
        let (cycleValues, updatedSeen) = buildCycle start seen []
            cycleExpression = Call (Symbol "List") (map Integer cycleValues)
         in go (start + 1) updatedSeen (cycleExpression : retained)

  buildCycle current seen retained
    | Set.member current seen = (reverse retained, seen)
    | otherwise =
        buildCycle
          (permutationValue current permutation)
          (Set.insert current seen)
          (current : retained)

emptyCycles :: Expr
emptyCycles = Call (Symbol "Cycles") [Call (Symbol "List") []]
