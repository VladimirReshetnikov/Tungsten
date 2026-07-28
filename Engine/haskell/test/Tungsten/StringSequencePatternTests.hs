{-# LANGUAGE OverloadedStrings #-}

module Tungsten.StringSequencePatternTests
  ( checkStringSequencePatterns
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkStringSequencePatterns :: IO Bool
checkStringSequencePatterns = do
  values <- traverse checkValue valueCases
  errors <- traverse checkError errorCases
  stateful <- traverse checkSessionOnly sessionCases
  pure (and (values <> errors <> stateful))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("digit runs", "StringCases[\"abc123def45\",DigitCharacter..]", "List[\"123\", \"45\"]")
  , ("named repeated character", "StringCases[\"abbcbccaabbabccaa\", x_ ~~ x_]", "List[\"bb\", \"cc\", \"aa\", \"bb\", \"cc\", \"aa\"]")
  , ("delayed named case", "StringCases[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]", "List[\"[123]\"]")
  , ("delayed named replacement", "StringReplace[\"abc123def\", x : DigitCharacter.. :> \"[\" <> x <> \"]\"]", "\"abc[123]def\"")
  , ("symbolic replacement", "StringReplace[\"abc123\",DigitCharacter..->tag]", "StringExpression[\"abc\", tag]")
  , ("nested list threading cases", "StringCases[{\"a1\",\"b22\"},DigitCharacter..]", "List[List[\"1\"], List[\"22\"]]")
  , ("nested list threading replacement limit", "StringReplace[{\"a1\",\"b22\"},DigitCharacter..->\"X\",1]", "List[\"aX\", \"bX\"]")
  , ("longest string expression", "StringPosition[\"ababa\", \"a\" ~~ ___ ~~ \"a\"]", "List[List[1, 5], List[3, 5]]")
  , ("shortest string expression", "StringPosition[\"ababa\", Shortest[\"a\" ~~ ___ ~~ \"a\"]]", "List[List[1, 3], List[3, 5]]")
  , ("bounded repetition", "StringCases[\"aaaab\",Repeated[\"a\",{2,3}]]", "List[\"aaa\"]")
  , ("number strings", "StringCases[\"a1 23 -4.5\",NumberString]", "List[\"1\", \"23\", \"-4.5\"]")
  , ("regular expression", "StringCases[\"abc123\",RegularExpression[\"[a-z]+\"]]", "List[\"abc\"]")
  , ("date pattern", "StringCases[\"on 2026-04-25 ok\",DatePattern[{\"Year\",\"Month\",\"Day\"}]]", "List[\"2026-04-25\"]")
  , ("character exclusions", "StringCases[\"a1\",Except[LetterCharacter,_]]", "List[\"1\"]")
  , ("line boundaries", "StringCases[\"a\\nb\", StartOfLine ~~ LetterCharacter]", "List[\"a\", \"b\"]")
  , ("fixed sequence cases", "SequenceCases[{1,2,3,4,5,6},{a_,b_}/;b==a+1]", "List[List[1, 2], List[3, 4], List[5, 6]]")
  , ("fixed sequence positions", "SequencePosition[{1,2,3,1,2,3},{1,2}]", "List[List[1, 2], List[4, 5]]")
  , ("fixed sequence count", "SequenceCount[{1,2,3,1,2,3},{1,2}]", "2")
  , ("rolling sequence fold", "SequenceFold[f,{x0,x1},{a,b,c}]", "f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]")
  , ("rolling sequence fold history", "SequenceFoldList[f,{x0,x1},{a,b,c}]", "List[x0, x1, f[x0, x1, a], f[x1, f[x0, x1, a], b], f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]]")
  , ("explicit sequence fold arity", "SequenceFoldList[f,{x0,x1},{a,b,c,d,e},4]", "List[x0, x1, f[x0, x1, a, b], f[x1, f[x0, x1, a, b], c, d]]")
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ("invalid except width", "StringCases[\"abc\",Except[\"ab\"]]", "String-pattern Except expects a single-character disallowed pattern.")
  , ("invalid string pattern", "StringCases[\"abc\", Optional[\"a\"] ~~ \"b\"]", "Unsupported Wolfram string-pattern form in the current Tungsten subset: Optional[\"a\"].")
  , ("replacement requires rules", "StringReplace[\"abc\",\"a\"]", "StringReplace expects a rule or a list of rules.")
  , ("sequence search requires list", "SequenceCases[x,{_}]", "SequenceCases expects a List as its first argument.")
  , ("sequence search requires fixed pattern", "SequenceCount[{1,2},x_]", "SequenceCases / SequencePosition / SequenceCount expect a fixed-arity List pattern, optionally wrapped in Condition or HoldPattern.")
  , ("sequence fold requires initial values", "SequenceFoldList[f,{},{}]", "SequenceFoldList expects at least one initial value.")
  , ("sequence fold requires positive consumption", "SequenceFoldList[f,{x0,x1},{a},2]", "SequenceFoldList currently expects each step to consume at least one input element.")
  ]

sessionCases :: [(Text, Text, Text)]
sessionCases =
  [ ("sequence fold threads assignments", "i=0;{SequenceFoldList[Function[{s,v},i=i+1;s+v],{0},{1,2,3}],i}", "List[List[0, 1, 3, 6], 3]")
  , ("sequence conditions retain failed callback effects", "i=0;{SequenceCount[{1,2,3},{x_}/;(i=i+1;EvenQ[x])],i}", "List[1, 3]")
  , ("string tests retain callback effects", "i=0;{StringCases[\"a1b2\",_?((i=i+1;True)&):>\"hit\"],i}", "List[List[\"hit\", \"hit\", \"hit\", \"hit\"], 4]")
  , ("string replacements thread delayed effects", "i=0;{StringReplace[\"aba\",x:\"a\":>(i=i+1;ToUpperCase[x])],i}", "List[\"AbA\", 2]")
  ]

checkValue :: (Text, Text, Text) -> IO Bool
checkValue (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left evaluationError -> failCheck label ("evaluation error: " <> showText evaluationError)
    Right result
      | fullForm result /= expected ->
          failCheck label ("expected " <> expected <> ", got " <> fullForm result)
      | otherwise -> checkSessionValue label expression expected

checkSessionValue :: Text -> Expr -> Text -> IO Bool
checkSessionValue label expression expected = do
  evaluated <- evaluateInSession emptySession expression
  case evaluated of
    Left evaluationError ->
      failCheck label ("session evaluation error: " <> showText evaluationError)
    Right (result, _)
      | fullForm result == expected -> pure True
      | otherwise ->
          failCheck label ("session expected " <> expected <> ", got " <> fullForm result)

checkSessionOnly :: (Text, Text, Text) -> IO Bool
checkSessionOnly (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> checkSessionValue label expression expected

checkError :: (Text, Text, Text) -> IO Bool
checkError (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left (EvaluationError message)
      | message == expected -> pure True
      | otherwise -> failCheck label ("expected error " <> expected <> ", got " <> message)
    Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAIL: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
