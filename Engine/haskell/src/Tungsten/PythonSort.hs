-- | A stable, state-threading port of CPython 3.13's list-sort scheduler.
--
-- This module deliberately follows CPython's comparison schedule instead of
-- using 'Data.List.sortBy'.  Wolfram ordering functions can mutate an
-- 'EvaluationSession', so otherwise-equivalent stable sorting algorithms are
-- observably different when their comparator calls occur in a different
-- order.
module Tungsten.PythonSort
  ( pythonStableSortByState
  ) where

-- CPython's listsort uses 64 as both the largest minimum-run value and the
-- cutoff below which one natural run is extended by binary insertion sort.
maximumMinimumRun :: Int
maximumMinimumRun = 64

minimumGallop :: Int
minimumGallop = 7

data PendingRun = PendingRun
  { pendingStart :: !Int
  , pendingLength :: !Int
  , pendingPower :: !Int
  }

data SortMachine s item = SortMachine
  { machineItems :: ![item]
  , machineUserState :: !s
  , machineMinimumGallop :: !Int
  , machinePendingRuns :: ![PendingRun]
  , machineListLength :: !Int
  }

data SortEnvironment err s item = SortEnvironment
  { environmentCompare :: s -> item -> item -> Either err (Ordering, s)
  , environmentMachine :: !(SortMachine s item)
  }

newtype SortAction err s item result = SortAction
  { runSortAction
      :: SortEnvironment err s item
      -> Either err (result, SortEnvironment err s item)
  }

instance Functor (SortAction err s item) where
  fmap transform action = SortAction $ \environment -> do
    (value, updated) <- runSortAction action environment
    Right (transform value, updated)

instance Applicative (SortAction err s item) where
  pure value = SortAction $ \environment -> Right (value, environment)
  functionAction <*> valueAction = SortAction $ \environment -> do
    (function, functionEnvironment) <- runSortAction functionAction environment
    (value, valueEnvironment) <- runSortAction valueAction functionEnvironment
    Right (function value, valueEnvironment)

instance Monad (SortAction err s item) where
  action >>= continue = SortAction $ \environment -> do
    (value, updated) <- runSortAction action environment
    runSortAction (continue value) updated

-- | Sort a list stably while threading comparator state in the exact order in
-- which CPython 3.13's @list.sort@ invokes @<@.
--
-- Only 'LT' is interpreted as a successful less-than result.  'EQ' and 'GT'
-- both mean "not less", matching the boolean contract used internally by
-- CPython.  Comparator failures short-circuit immediately.
pythonStableSortByState
  :: (s -> item -> item -> Either err (Ordering, s))
  -> s
  -> [item]
  -> Either err ([item], s)
pythonStableSortByState compareItems initialState items = do
  let itemCount = length items
      initialMachine =
        SortMachine
          { machineItems = items
          , machineUserState = initialState
          , machineMinimumGallop = minimumGallop
          , machinePendingRuns = []
          , machineListLength = itemCount
          }
      initialEnvironment =
        SortEnvironment
          { environmentCompare = compareItems
          , environmentMachine = initialMachine
          }
  (_, finalEnvironment) <- runSortAction pythonSort initialEnvironment
  let finalMachine = environmentMachine finalEnvironment
  Right (machineItems finalMachine, machineUserState finalMachine)

pythonSort :: SortAction err s item ()
pythonSort = do
  total <- getsMachine machineListLength
  if total < 2
    then pure ()
    else do
      let minimumRun = computeMinimumRun total
      discoverRuns minimumRun 0 total
      forceCollapseRuns

discoverRuns :: Int -> Int -> Int -> SortAction err s item ()
discoverRuns minimumRun start remaining
  | remaining <= 0 = pure ()
  | otherwise = do
      naturalLength <- countRun start remaining
      runLength <-
        if naturalLength < minimumRun
          then do
            let forcedLength = min minimumRun remaining
            binarySort start forcedLength naturalLength
            pure forcedLength
          else pure naturalLength
      foundNewRun runLength
      modifyMachine $ \machine ->
        machine
          { machinePendingRuns =
              machinePendingRuns machine
                ++ [PendingRun start runLength 0]
          }
      discoverRuns minimumRun (start + runLength) (remaining - runLength)

compareLess :: item -> item -> SortAction err s item Bool
compareLess left right = SortAction $ \environment -> do
  let machine = environmentMachine environment
  (ordering, updatedState) <-
    environmentCompare environment (machineUserState machine) left right
  let updatedMachine = machine {machineUserState = updatedState}
  Right (ordering == LT, environment {environmentMachine = updatedMachine})

compareAt :: Int -> Int -> SortAction err s item Bool
compareAt leftIndex rightIndex = do
  left <- itemAt leftIndex
  right <- itemAt rightIndex
  compareLess left right

itemAt :: Int -> SortAction err s item item
itemAt index = getsMachine (listItemAt index . machineItems)

getsMachine :: (SortMachine s item -> value) -> SortAction err s item value
getsMachine project = SortAction $ \environment ->
  Right (project (environmentMachine environment), environment)

modifyMachine
  :: (SortMachine s item -> SortMachine s item)
  -> SortAction err s item ()
modifyMachine transform = SortAction $ \environment ->
  Right
    ( ()
    , environment
        { environmentMachine = transform (environmentMachine environment)
        }
    )

listItemAt :: Int -> [item] -> item
listItemAt index values = case drop index values of
  value : _ -> value
  [] -> error "Tungsten.PythonSort: internal index out of bounds"

lastItem :: [item] -> item
lastItem [] = error "Tungsten.PythonSort: internal empty list"
lastItem [value] = value
lastItem (_ : remaining) = lastItem remaining

withoutLast :: [item] -> [item]
withoutLast [] = error "Tungsten.PythonSort: internal empty list"
withoutLast [_] = []
withoutLast (value : remaining) = value : withoutLast remaining

replaceSlice :: Int -> Int -> [item] -> [item] -> [item]
replaceSlice start width replacement values =
  take start values ++ replacement ++ drop (start + width) values

setSlice :: Int -> Int -> [item] -> SortAction err s item ()
setSlice start width replacement =
  modifyMachine $ \machine ->
    machine
      { machineItems =
          replaceSlice start width replacement (machineItems machine)
      }

reverseSlice :: Int -> Int -> SortAction err s item ()
reverseSlice start width = do
  values <- getsMachine machineItems
  let reversed = reverse (take width (drop start values))
  setSlice start width reversed

-- This is a direct structural translation of CPython 3.13's count_run().
-- Its special handling of equal stretches is important both for stability and
-- for matching comparison traces on descending inputs containing duplicates.
countRun :: Int -> Int -> SortAction err s item Int
countRun start remaining
  | remaining <= 0 = pure 0
  | otherwise = ascend 1
 where
  ascend n
    | n >= remaining = pure n
    | otherwise = do
        nextIsSmaller <- compareAt (start + n) (start + n - 1)
        if nextIsSmaller
          then beginDescending n
          else ascend (n + 1)

  beginDescending n
    | n > 1 = do
        prefixIncreased <- compareAt start (start + n - 1)
        if prefixIncreased
          then pure n
          else do
            reverseSlice start n
            descend (n + 1) 0
    | otherwise = descend 2 0

  descend n equalTransitions
    | n >= remaining = finishDescending n equalTransitions
    | otherwise = do
        nextIsSmaller <- compareAt (start + n) (start + n - 1)
        if nextIsSmaller
          then do
            reverseEqualSuffix n equalTransitions
            descend (n + 1) 0
          else do
            nextIsLarger <- compareAt (start + n - 1) (start + n)
            if nextIsLarger
              then finishDescending n equalTransitions
              else descend (n + 1) (equalTransitions + 1)

  finishDescending n equalTransitions = do
    reverseEqualSuffix n equalTransitions
    reverseSlice start n
    extendAscending n

  reverseEqualSuffix n equalTransitions
    | equalTransitions <= 0 = pure ()
    | otherwise =
        let equalCount = equalTransitions + 1
         in reverseSlice (start + n - equalCount) equalCount

  extendAscending n
    | n >= remaining = pure n
    | otherwise = do
        nextIsSmaller <- compareAt (start + n) (start + n - 1)
        if nextIsSmaller
          then pure n
          else extendAscending (n + 1)

binarySort :: Int -> Int -> Int -> SortAction err s item ()
binarySort start width sortedCount = insertFrom initialCount
 where
  initialCount
    | sortedCount == 0 = 1
    | otherwise = sortedCount

  insertFrom index
    | index >= width = pure ()
    | otherwise = do
        values <- getsMachine machineItems
        let runValues = take width (drop start values)
            pivot = listItemAt index runValues
        insertionIndex <- locate pivot runValues 0 index
        let sortedPrefix = take index runValues
            replacement =
              take insertionIndex sortedPrefix
                ++ [pivot]
                ++ drop insertionIndex sortedPrefix
                ++ drop (index + 1) runValues
        setSlice start width replacement
        insertFrom (index + 1)

  locate pivot runValues left right
    | left >= right = pure left
    | otherwise = do
        let middle = (left + right) `div` 2
        pivotIsSmaller <- compareLess pivot (listItemAt middle runValues)
        if pivotIsSmaller
          then locate pivot runValues left middle
          else locate pivot runValues (middle + 1) right

computeMinimumRun :: Int -> Int
computeMinimumRun = go 0
 where
  go shiftedBit value
    | value < maximumMinimumRun = value + shiftedBit
    | otherwise = go (shiftedBit .|. (value `mod` 2)) (value `div` 2)

  (.|.) left right
    | left /= 0 || right /= 0 = 1
    | otherwise = 0

powerLoop :: Int -> Int -> Int -> Int -> Int
powerLoop firstStart firstLength secondLength totalLength =
  go 0 (2 * firstStart + firstLength) (2 * firstStart + 2 * firstLength + secondLength)
 where
  go result midpointA midpointB
    | midpointA >= totalLength =
        go
          (result + 1)
          (2 * (midpointA - totalLength))
          (2 * (midpointB - totalLength))
    | midpointB >= totalLength = result + 1
    | otherwise = go (result + 1) (2 * midpointA) (2 * midpointB)

foundNewRun :: Int -> SortAction err s item ()
foundNewRun newLength = do
  runs <- getsMachine machinePendingRuns
  totalLength <- getsMachine machineListLength
  case reverse runs of
    [] -> pure ()
    newest : _ -> do
      let power =
            powerLoop
              (pendingStart newest)
              (pendingLength newest)
              newLength
              totalLength
      collapseAbove power
      modifyMachine $ \machine ->
        machine
          { machinePendingRuns =
              modifyLast
                (\run -> run {pendingPower = power})
                (machinePendingRuns machine)
          }
 where
  collapseAbove power = do
    runs <- getsMachine machinePendingRuns
    let runCount = length runs
    if runCount > 1 && pendingPower (listItemAt (runCount - 2) runs) > power
      then mergeAt (runCount - 2) >> collapseAbove power
      else pure ()

modifyLast :: (value -> value) -> [value] -> [value]
modifyLast _ [] = []
modifyLast transform values =
  take (length values - 1) values ++ [transform (lastItem values)]

forceCollapseRuns :: SortAction err s item ()
forceCollapseRuns = do
  runs <- getsMachine machinePendingRuns
  let runCount = length runs
  if runCount <= 1
    then pure ()
    else do
      let initialIndex = runCount - 2
          mergeIndex
            | initialIndex > 0
                && pendingLength (listItemAt (initialIndex - 1) runs)
                  < pendingLength (listItemAt (initialIndex + 1) runs) =
                initialIndex - 1
            | otherwise = initialIndex
      mergeAt mergeIndex
      forceCollapseRuns

mergeAt :: Int -> SortAction err s item ()
mergeAt runIndex = do
  runs <- getsMachine machinePendingRuns
  let firstRun = listItemAt runIndex runs
      secondRun = listItemAt (runIndex + 1) runs
      firstStart = pendingStart firstRun
      firstLength = pendingLength firstRun
      secondStart = pendingStart secondRun
      secondLength = pendingLength secondRun
      combinedRun = firstRun {pendingLength = firstLength + secondLength}
      updatedRuns =
        take runIndex runs
          ++ [combinedRun]
          ++ drop (runIndex + 2) runs
  modifyMachine $ \machine -> machine {machinePendingRuns = updatedRuns}
  values <- getsMachine machineItems
  let firstValues = take firstLength (drop firstStart values)
      secondValues = take secondLength (drop secondStart values)
      firstSecondValue = listItemAt 0 secondValues
  skippedFirst <- gallopRight firstSecondValue firstValues firstLength 0
  let remainingFirstLength = firstLength - skippedFirst
      remainingFirstValues = drop skippedFirst firstValues
      remainingStart = firstStart + skippedFirst
  if remainingFirstLength == 0
    then pure ()
    else do
      keptSecond <-
        gallopLeft
          (lastItem remainingFirstValues)
          secondValues
          secondLength
          (secondLength - 1)
      if keptSecond <= 0
        then pure ()
        else do
          let remainingSecondValues = take keptSecond secondValues
          merged <-
            if remainingFirstLength <= keptSecond
              then mergeLow remainingFirstValues remainingSecondValues
              else mergeHigh remainingFirstValues remainingSecondValues
          setSlice
            remainingStart
            (remainingFirstLength + keptSecond)
            merged

gallopLeft
  :: item
  -> [item]
  -> Int
  -> Int
  -> SortAction err s item Int
gallopLeft key values width hint = do
  hintIsSmaller <- compareLess (listItemAt hint values) key
  (lastOffset, offset) <-
    if hintIsSmaller
      then expandRight 0 1 (width - hint)
      else expandLeft 0 1 (hint + 1)
  binarySearch (lastOffset + 1) offset
 where
  expandRight lastOffset offset maximumOffset
    | offset >= maximumOffset =
        pure
          ( lastOffset + hint
          , min offset maximumOffset + hint
          )
    | otherwise = do
        candidateIsSmaller <- compareLess (listItemAt (hint + offset) values) key
        if candidateIsSmaller
          then expandRight offset (2 * offset + 1) maximumOffset
          else pure (lastOffset + hint, offset + hint)

  expandLeft lastOffset offset maximumOffset
    | offset >= maximumOffset = translate lastOffset (min offset maximumOffset)
    | otherwise = do
        candidateIsSmaller <- compareLess (listItemAt (hint - offset) values) key
        if candidateIsSmaller
          then translate lastOffset offset
          else expandLeft offset (2 * offset + 1) maximumOffset

  translate lastOffset offset =
    pure (hint - offset, hint - lastOffset)

  binarySearch left right
    | left >= right = pure right
    | otherwise = do
        let middle = left + ((right - left) `div` 2)
        candidateIsSmaller <- compareLess (listItemAt middle values) key
        if candidateIsSmaller
          then binarySearch (middle + 1) right
          else binarySearch left middle

gallopRight
  :: item
  -> [item]
  -> Int
  -> Int
  -> SortAction err s item Int
gallopRight key values width hint = do
  keyIsSmaller <- compareLess key (listItemAt hint values)
  (lastOffset, offset) <-
    if keyIsSmaller
      then expandLeft 0 1 (hint + 1)
      else expandRight 0 1 (width - hint)
  binarySearch (lastOffset + 1) offset
 where
  expandLeft lastOffset offset maximumOffset
    | offset >= maximumOffset = translate lastOffset (min offset maximumOffset)
    | otherwise = do
        keyIsSmaller <- compareLess key (listItemAt (hint - offset) values)
        if keyIsSmaller
          then expandLeft offset (2 * offset + 1) maximumOffset
          else translate lastOffset offset

  translate lastOffset offset =
    pure (hint - offset, hint - lastOffset)

  expandRight lastOffset offset maximumOffset
    | offset >= maximumOffset =
        pure
          ( lastOffset + hint
          , min offset maximumOffset + hint
          )
    | otherwise = do
        keyIsSmaller <- compareLess key (listItemAt (hint + offset) values)
        if keyIsSmaller
          then pure (lastOffset + hint, offset + hint)
          else expandRight offset (2 * offset + 1) maximumOffset

  binarySearch left right
    | left >= right = pure right
    | otherwise = do
        let middle = left + ((right - left) `div` 2)
        keyIsSmaller <- compareLess key (listItemAt middle values)
        if keyIsSmaller
          then binarySearch left middle
          else binarySearch (middle + 1) right

mergeLow :: [item] -> [item] -> SortAction err s item [item]
mergeLow firstValues secondValues =
  case secondValues of
    [] -> pure firstValues
    secondHead : secondTail ->
      let output = [secondHead]
       in if null secondTail
            then pure (output ++ firstValues)
            else
              if length firstValues == 1
                then pure (output ++ secondTail ++ firstValues)
                else do
                  gallopLimit <- getsMachine machineMinimumGallop
                  mergeStraight gallopLimit firstValues secondTail (reverse output) 0 0
 where
  finish outputReversed first remainingSecond =
    pure (reverse outputReversed ++ first ++ remainingSecond)

  copySecondThenFirst outputReversed first remainingSecond =
    pure (reverse outputReversed ++ remainingSecond ++ first)

  mergeStraight gallopLimit first second outputReversed firstWins secondWins = do
    secondIsSmaller <- compareLess (listItemAt 0 second) (listItemAt 0 first)
    if secondIsSmaller
      then do
        let remainingSecond = drop 1 second
            output = listItemAt 0 second : outputReversed
            nextSecondWins = secondWins + 1
        if null remainingSecond
          then finish output first []
          else
            if nextSecondWins >= gallopLimit
              then mergeGalloping (gallopLimit + 1) first remainingSecond output
              else mergeStraight gallopLimit first remainingSecond output 0 nextSecondWins
      else do
        let remainingFirst = drop 1 first
            output = listItemAt 0 first : outputReversed
            nextFirstWins = firstWins + 1
        if length remainingFirst == 1
          then copySecondThenFirst output remainingFirst second
          else
            if nextFirstWins >= gallopLimit
              then mergeGalloping (gallopLimit + 1) remainingFirst second output
              else mergeStraight gallopLimit remainingFirst second output nextFirstWins 0

  mergeGalloping gallopLimit first second outputReversed = do
    let reducedLimit = max 1 (gallopLimit - 1)
    modifyMachine $ \machine -> machine {machineMinimumGallop = reducedLimit}
    firstCount <- gallopRight (listItemAt 0 second) first (length first) 0
    let (firstBlock, remainingFirst) = splitAt firstCount first
        afterFirst = reverse firstBlock ++ outputReversed
    if length remainingFirst <= 1
      then
        if null remainingFirst
          then finish afterFirst [] second
          else copySecondThenFirst afterFirst remainingFirst second
      else do
        let afterSecondItem = listItemAt 0 second : afterFirst
            remainingSecond = drop 1 second
        if null remainingSecond
          then finish afterSecondItem remainingFirst []
          else do
            secondCount <-
              gallopLeft
                (listItemAt 0 remainingFirst)
                remainingSecond
                (length remainingSecond)
                0
            let (secondBlock, afterSecondBlock) = splitAt secondCount remainingSecond
                outputAfterBlock = reverse secondBlock ++ afterSecondItem
            if null afterSecondBlock
              then finish outputAfterBlock remainingFirst []
              else do
                let outputAfterFirstItem = listItemAt 0 remainingFirst : outputAfterBlock
                    afterFirstItem = drop 1 remainingFirst
                if length afterFirstItem == 1
                  then copySecondThenFirst outputAfterFirstItem afterFirstItem afterSecondBlock
                  else
                    if firstCount >= minimumGallop || secondCount >= minimumGallop
                      then
                        mergeGalloping
                          reducedLimit
                          afterFirstItem
                          afterSecondBlock
                          outputAfterFirstItem
                      else do
                        let penalizedLimit = reducedLimit + 1
                        modifyMachine $ \machine ->
                          machine {machineMinimumGallop = penalizedLimit}
                        mergeStraight
                          penalizedLimit
                          afterFirstItem
                          afterSecondBlock
                          outputAfterFirstItem
                          0
                          0

mergeHigh :: [item] -> [item] -> SortAction err s item [item]
mergeHigh firstValues secondValues =
  case reverse firstValues of
    [] -> pure secondValues
    firstLast : reversedFirstTail ->
      let remainingFirst = reverse reversedFirstTail
          suffix = [firstLast]
       in if null remainingFirst
            then pure (secondValues ++ suffix)
            else
              if length secondValues == 1
                then pure (remainingFirst ++ secondValues ++ suffix)
                else do
                  gallopLimit <- getsMachine machineMinimumGallop
                  mergeStraight gallopLimit remainingFirst secondValues suffix 0 0
 where
  finish first second suffix = pure (first ++ second ++ suffix)

  -- merge_hi's CopyA case shifts the remaining A block right and places the
  -- sole remaining B item in front of it.
  copyFirstThenSecond first second suffix = pure (second ++ first ++ suffix)

  mergeStraight gallopLimit first second suffix firstWins secondWins = do
    secondIsSmaller <- compareLess (lastItem second) (lastItem first)
    if secondIsSmaller
      then do
        let remainingFirst = withoutLast first
            updatedSuffix = lastItem first : suffix
            nextFirstWins = firstWins + 1
        if null remainingFirst
          then finish [] second updatedSuffix
          else
            if nextFirstWins >= gallopLimit
              then mergeGalloping (gallopLimit + 1) remainingFirst second updatedSuffix
              else mergeStraight gallopLimit remainingFirst second updatedSuffix nextFirstWins 0
      else do
        let remainingSecond = withoutLast second
            updatedSuffix = lastItem second : suffix
            nextSecondWins = secondWins + 1
        if length remainingSecond == 1
          then copyFirstThenSecond first remainingSecond updatedSuffix
          else
            if nextSecondWins >= gallopLimit
              then mergeGalloping (gallopLimit + 1) first remainingSecond updatedSuffix
              else mergeStraight gallopLimit first remainingSecond updatedSuffix 0 nextSecondWins

  mergeGalloping gallopLimit first second suffix = do
    let reducedLimit = max 1 (gallopLimit - 1)
    modifyMachine $ \machine -> machine {machineMinimumGallop = reducedLimit}
    firstBoundary <- gallopRight (lastItem second) first (length first) (length first - 1)
    let (remainingFirst, firstBlock) = splitAt firstBoundary first
        afterFirst = firstBlock ++ suffix
        firstCount = length firstBlock
    if null remainingFirst
      then finish [] second afterFirst
      else do
        let afterSecondItem = lastItem second : afterFirst
            remainingSecond = withoutLast second
        if length remainingSecond == 1
          then copyFirstThenSecond remainingFirst remainingSecond afterSecondItem
          else do
            secondBoundary <-
              gallopLeft
                (lastItem remainingFirst)
                remainingSecond
                (length remainingSecond)
                (length remainingSecond - 1)
            let (afterSecondBlock, secondBlock) = splitAt secondBoundary remainingSecond
                suffixAfterBlock = secondBlock ++ afterSecondItem
                secondCount = length secondBlock
            if length afterSecondBlock <= 1
              then
                if null afterSecondBlock
                  then finish remainingFirst [] suffixAfterBlock
                  else copyFirstThenSecond remainingFirst afterSecondBlock suffixAfterBlock
              else do
                let suffixAfterFirstItem = lastItem remainingFirst : suffixAfterBlock
                    afterFirstItem = withoutLast remainingFirst
                if null afterFirstItem
                  then finish [] afterSecondBlock suffixAfterFirstItem
                  else
                    if firstCount >= minimumGallop || secondCount >= minimumGallop
                      then
                        mergeGalloping
                          reducedLimit
                          afterFirstItem
                          afterSecondBlock
                          suffixAfterFirstItem
                      else do
                        let penalizedLimit = reducedLimit + 1
                        modifyMachine $ \machine ->
                          machine {machineMinimumGallop = penalizedLimit}
                        mergeStraight
                          penalizedLimit
                          afterFirstItem
                          afterSecondBlock
                          suffixAfterFirstItem
                          0
                          0
