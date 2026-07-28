{-# LANGUAGE OverloadedStrings #-}

module Tungsten.RandomTests (checkRandomPlanning) where

import Data.Text (Text)
import qualified Data.Text.IO as TextIO
import Tungsten.Expression (Expr (..), fullForm)
import Tungsten.Random
  ( RandomPlan
  , RandomPlanError (..)
  , randomPermutationPlan
  , randomSamplePlan
  , runRandomPlanState
  )

checkRandomPlanning :: IO Bool
checkRandomPlanning = do
  results <- sequence
    [ checkPlan
        "scripted pool sample"
        (randomSamplePlan (list [symbol "a", symbol "b", symbol "c", symbol "d"]) (Just (Integer 2)))
        [3, 1]
        "List[d, b]"
        [4, 3]
    , checkPlan
        "full pool sample matches CPython replacement order"
        (randomSamplePlan (list [symbol "a", symbol "b", symbol "c", symbol "d"]) Nothing)
        [0, 0, 0, 0]
        "List[a, d, c, b]"
        [4, 3, 2, 1]
    , checkPlan
        "duplicate values remain distinct population occurrences"
        ( randomSamplePlan
            (list [symbol "a", symbol "a", symbol "b", symbol "c"])
            (Just (Integer 3))
        )
        [0, 0, 0]
        "List[a, c, b]"
        [4, 3, 2]
    , checkPlan
        "sparse sample uses CPython rejection schedule"
        ( randomSamplePlan
            (list (map Integer [1 .. 30]))
            (Just (Integer 2))
        )
        [29, 29, 1]
        "List[30, 2]"
        [30, 30, 30]
    , checkPlan
        "UpTo clips at the source length"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Call (Symbol "UpTo") [Integer 5]))
        )
        [1, 0]
        "List[b, a]"
        [2, 1]
    , checkFailure
        "System-qualified All is not a Python count sentinel"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Symbol "System`All"))
        )
        "RandomSample expects an integer, UpTo[n], All, or no count."
    , checkPlan
        "System-qualified UpTo retains Python head normalization"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Call (Symbol "System`UpTo") [Integer 1]))
        )
        [1]
        "List[b]"
        [2]
    , checkPlan
        "zero sample consumes no randomness"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Integer 0))
        )
        []
        "List[]"
        []
    , checkPlan
        "empty full sample consumes no randomness"
        (randomSamplePlan (list []) Nothing)
        []
        "List[]"
        []
    , checkPlan
        "general expressions preserve their head"
        ( randomSamplePlan
            (Call (symbol "f") [symbol "a", symbol "b", symbol "c"])
            (Just (Integer 2))
        )
        [2, 0]
        "f[c, a]"
        [3, 2]
    , checkPlan
        "associations sample complete Rule and RuleDelayed entries"
        ( randomSamplePlan
            ( Call
                (Symbol "Association")
                [ rule "Rule" "a" 1
                , rule "RuleDelayed" "b" 2
                , rule "Rule" "c" 3
                ]
            )
            (Just (Integer 2))
        )
        [1, 0]
        "Association[RuleDelayed[b, 2], Rule[a, 1]]"
        [3, 2]
    , checkPlan
        "System-qualified associations rebuild canonically"
        ( randomSamplePlan
            ( Call
                (Symbol "System`Association")
                [rule "System`Rule" "a" 1, rule "Rule" "b" 2]
            )
            (Just (Integer 1))
        )
        [1]
        "Association[Rule[b, 2]]"
        [2]
    , checkPlan
        "Global Association remains an ordinary head"
        ( randomSamplePlan
            ( Call
                (Symbol "Global`Association")
                [rule "Rule" "a" 1, rule "Rule" "b" 2]
            )
            (Just (Integer 1))
        )
        [0]
        "Global`Association[Rule[a, 1]]"
        [2]
    , checkPlan
        "malformed Association rebuild drops Nothing without deduplicating"
        ( randomSamplePlan
            ( Call
                (Symbol "Association")
                [Symbol "Nothing", rule "Rule" "a" 1]
            )
            Nothing
        )
        [0, 0]
        "Association[Rule[a, 1]]"
        [2, 1]
    , checkPlan
        "raw Association Sequence retains duplicate-key occurrences"
        ( randomSamplePlan
            ( Call
                (Symbol "Association")
                [ Call
                    (Symbol "Sequence")
                    [rule "Rule" "a" 1, rule "Rule" "a" 2]
                ]
            )
            Nothing
        )
        [0]
        "Association[Rule[a, 1], Rule[a, 2]]"
        [1]
    , checkPlan
        "Sequence values splice while rebuilding ordinary heads"
        ( randomSamplePlan
            ( Call
                (symbol "f")
                [Call (Symbol "Sequence") [symbol "a", symbol "b"], symbol "c"]
            )
            Nothing
        )
        [0, 0]
        "f[a, b, c]"
        [2, 1]
    , checkPlan
        "HoldComplete suppresses sampled Sequence splicing"
        ( randomSamplePlan
            ( Call
                (Symbol "HoldComplete")
                [Call (Symbol "Sequence") [symbol "a", symbol "b"], symbol "c"]
            )
            Nothing
        )
        [0, 0]
        "HoldComplete[Sequence[a, b], c]"
        [2, 1]
    , checkPlan
        "default Splice expands while rebuilding List"
        ( randomSamplePlan
            ( list
                [ Call (Symbol "Splice") [list [symbol "a", symbol "b"]]
                , symbol "c"
                ]
            )
            Nothing
        )
        [0, 0]
        "List[a, b, c]"
        [2, 1]
    , checkPlan
        "targeted Splice expands while rebuilding its target head"
        ( randomSamplePlan
            ( Call
                (symbol "f")
                [ Call
                    (Symbol "Splice")
                    [list [symbol "a", symbol "b"], symbol "f"]
                , symbol "c"
                ]
            )
            Nothing
        )
        [0, 0]
        "f[a, b, c]"
        [2, 1]
    , checkPlan
        "List drops Nothing introduced into a rebuilt result"
        (randomSamplePlan (list [Symbol "Nothing", symbol "a"]) Nothing)
        [0, 0]
        "List[a]"
        [2, 1]
    , checkPlan
        "ordinary heads retain Nothing"
        (randomSamplePlan (Call (symbol "f") [Symbol "Nothing", symbol "a"]) Nothing)
        [0, 0]
        "f[Nothing, a]"
        [2, 1]
    , checkPlan
        "zero-draw Fisher-Yates permutation"
        (randomPermutationPlan (Integer 5))
        [0, 0, 0, 0]
        "Cycles[List[List[1, 2, 3, 4, 5]]]"
        [5, 4, 3, 2]
    , checkPlan
        "last-index Fisher-Yates draws produce the identity"
        (randomPermutationPlan (Integer 5))
        [4, 3, 2, 1]
        "Cycles[List[]]"
        [5, 4, 3, 2]
    , checkPlan
        "permutation cycles use canonical ascending starts"
        (randomPermutationPlan (Integer 5))
        [4, 2, 2, 0]
        "Cycles[List[List[1, 2], List[3, 4]]]"
        [5, 4, 3, 2]
    , checkPlan
        "zero-length permutation consumes no randomness"
        (randomPermutationPlan (Integer 0))
        []
        "Cycles[List[]]"
        []
    , checkPlan
        "one-element permutation consumes no randomness"
        (randomPermutationPlan (Integer 1))
        []
        "Cycles[List[]]"
        []
    , checkFailure
        "RandomSample rejects atoms"
        (randomSamplePlan (symbol "a") Nothing)
        "RandomSample expects a nonatomic expression."
    , checkFailure
        "RandomSample rejects symbolic counts"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (symbol "x"))
        )
        "RandomSample expects an integer, UpTo[n], All, or no count."
    , checkFailure
        "RandomSample rejects symbolic UpTo bounds"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Call (Symbol "UpTo") [symbol "x"]))
        )
        "RandomSample expects an integer, UpTo[n], All, or no count."
    , checkFailure
        "RandomSample rejects negative counts"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Integer (-1)))
        )
        "RandomSample count must be between 0 and the sequence length."
    , checkFailure
        "RandomSample rejects oversized exact counts"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Integer 3))
        )
        "RandomSample count must be between 0 and the sequence length."
    , checkFailure
        "RandomSample rejects negative UpTo counts"
        ( randomSamplePlan
            (list [symbol "a", symbol "b"])
            (Just (Call (Symbol "UpTo") [Integer (-1)]))
        )
        "RandomSample count must be between 0 and the sequence length."
    , checkFailure
        "RandomPermutation rejects negative lengths"
        (randomPermutationPlan (Integer (-1)))
        "RandomPermutation expects a non-negative integer."
    , checkFailure
        "RandomPermutation rejects non-integer lengths"
        (randomPermutationPlan (symbol "x"))
        "RandomPermutation currently expects an integer length."
    , checkInvalidDraw
    ]
  pure (and results)

data Script = Script
  { scriptValues :: [Integer]
  , scriptBoundsReversed :: [Integer]
  }

scriptedDraw
  :: Integer
  -> Script
  -> Either RandomPlanError (Integer, Script)
scriptedDraw bound script = case scriptValues script of
  [] -> Left (RandomPlanError "scripted random source was exhausted")
  draw : remaining ->
    Right
      ( draw
      , Script
          { scriptValues = remaining
          , scriptBoundsReversed = bound : scriptBoundsReversed script
          }
      )

checkPlan
  :: Text
  -> RandomPlan Expr
  -> [Integer]
  -> Text
  -> [Integer]
  -> IO Bool
checkPlan label plan draws expected expectedBounds =
  case runRandomPlanState scriptedDraw (Script draws []) plan of
    Left failure -> failCheck label ("unexpected failure: " <> randomPlanErrorMessage failure)
    Right (result, finalScript)
      | fullForm result /= expected ->
          failCheck label ("expected " <> expected <> ", got " <> fullForm result)
      | reverse (scriptBoundsReversed finalScript) /= expectedBounds ->
          failCheck label "random-below bounds differed from the expected schedule"
      | not (null (scriptValues finalScript)) ->
          failCheck label "script retained unused random draws"
      | otherwise -> pure True

checkFailure :: Text -> RandomPlan Expr -> Text -> IO Bool
checkFailure label plan expected =
  case runRandomPlanState scriptedDraw (Script [] []) plan of
    Left failure
      | randomPlanErrorMessage failure == expected -> pure True
      | otherwise ->
          failCheck
            label
            ( "expected failure "
                <> expected
                <> ", got "
                <> randomPlanErrorMessage failure
            )
    Right (result, _) ->
      failCheck label ("expected a failure, got " <> fullForm result)

checkInvalidDraw :: IO Bool
checkInvalidDraw =
  let plan = randomSamplePlan (list [symbol "a", symbol "b"]) (Just (Integer 1))
   in case runRandomPlanState scriptedDraw (Script [2] []) plan of
        Left failure
          | randomPlanErrorMessage failure
              == "random-below callback returned 2 for exclusive upper bound 2." ->
              pure True
          | otherwise ->
              failCheck
                "out-of-range runtime draw"
                ("unexpected failure: " <> randomPlanErrorMessage failure)
        Right (result, _) ->
          failCheck
            "out-of-range runtime draw"
            ("expected a failure, got " <> fullForm result)

symbol :: Text -> Expr
symbol = Symbol

list :: [Expr] -> Expr
list = Call (Symbol "List")

rule :: Text -> Text -> Integer -> Expr
rule headName key value = Call (Symbol headName) [Symbol key, Integer value]

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAIL: " <> label <> ": " <> detail)
  pure False
