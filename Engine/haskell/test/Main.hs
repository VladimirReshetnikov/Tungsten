{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Exit (exitFailure)
import Tungsten.Expression
import Tungsten.Json
import Tungsten.Parser

main :: IO ()
main = do
  results <- sequence tests
  if and results
    then TextIO.putStrLn "All Haskell expression/JSON foundation tests passed."
    else exitFailure

tests :: [IO Bool]
tests =
  [ checkFullForms
  , checkFullFormParser
  , checkFullFormParserErrors
  , checkInputFormParser
  , checkInputFormParserErrors
  , checkSmartConstructors
  , checkExpressionJsonRoundTrips
  , checkJsonCodec
  , checkProtocol
  , checkProtocolErrors
  ]

checkFullFormParser :: IO Bool
checkFullFormParser = do
  let cases =
        [ ("nested calls", "Plus[1, Times[2, x]]", Call (Symbol "Plus") [Integer 1, Call (Symbol "Times") [Integer 2, Symbol "x"]])
        , ("chained heads", "Derivative[2][f][x]", Call (Call (Call (Symbol "Derivative") [Integer 2]) [Symbol "f"]) [Symbol "x"])
        , ("nested comments", "Plus[1, (* outer (* inner *) end *) 2]", Call (Symbol "Plus") [Integer 1, Integer 2])
        , ("arbitrary integer", "999999999999999999999999999999999999", Integer 999999999999999999999999999999999999)
        , ("leading-point real", ".5`30", Real ".5`30")
        , ("precision real", "6.02214076`8*^23", Real "6.02214076`8*^23")
        , ("normalized rational", "Rational[-6, -8]", Rational 3 4)
        , ("complex atom", "Complex[Rational[1, 2], -3]", Complex (Rational 1 2) (Integer (-3)))
        , ("escaped string", "\"line\\n snowman \\:2603 face \\|01f600\"", String "line\n snowman ☃ face 😀")
        , ("parenthesized head", "(f)[x]", Call (Symbol "f") [Symbol "x"])
        ]
  and
    <$> traverse
      (\(label, source, expected) -> assertEqual ("FullForm parser: " <> label) (Right expected) (parseFullForm source))
      cases

checkFullFormParserErrors :: IO Bool
checkFullFormParserErrors = do
  first <- assertLeft "reject trailing FullForm input" (parseFullForm "f[x] trailing")
  second <- assertLeft "reject invalid rational" (parseFullForm "Rational[1, 0]")
  third <- assertLeft "reject malformed real exponent" (parseFullForm "1.2*^3.5")
  fourth <- assertLeft "reject unterminated comment" (parseFullForm "f[1] (* open")
  pure (and [first, second, third, fourth])

checkInputFormParser :: IO Bool
checkInputFormParser = do
  let cases =
        [ ("implicit multiplication and power", "1 + 2 x^3", "Plus[1, Times[2, Power[x, 3]]]")
        , ("exact division", "1/6 + 1/3", "Plus[Rational[1, 6], Rational[1, 3]]")
        , ("right associative power", "a^b^c", "Power[a, Power[b, c]]")
        , ("unary minus precedence", "-x^2", "Times[-1, Power[x, 2]]")
        , ("lists and calls", "f[{a, b}, g[x]]", "f[List[a, b], g[x]]")
        , ("uniform comparison", "a < b < c", "Less[a, b, c]")
        , ("mixed comparison", "a < b <= c", "Inequality[a, Less, b, LessEqual, c]")
        , ("Boolean operators", "a && b || c", "Or[And[a, b], c]")
        , ("rule", "a -> b + 1", "Rule[a, Plus[b, 1]]")
        , ("replacement", "f[a] /. a -> b", "ReplaceAll[f[a], Rule[a, b]]")
        , ("condition", "x_ /; x > 0", "Condition[Pattern[x, Blank[]], Greater[x, 0]]")
        , ("typed patterns", "f[x_Integer, y_]", "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]")
        , ("sequence blanks", "f[__, ___Symbol]", "f[BlankSequence[], BlankNullSequence[Symbol]]")
        , ("alternatives", "a | b | c", "Alternatives[a, b, c]")
        , ("slots and pure function", "#1 + #name &", "Function[Plus[Slot[1], Slot[\"name\"]]]")
        , ("slot sequence", "f[##2] &", "Function[f[SlotSequence[2]]]")
        , ("prefix and postfix application", "f @ x // g", "g[f[x]]")
        , ("part", "expr[[1, 2]]", "Part[expr, 1, 2]")
        , ("right associative assignment", "a = b = 2", "Set[a, Set[b, 2]]")
        , ("delayed assignment", "f[x_] := x^2", "SetDelayed[f[Pattern[x, Blank[]]], Power[x, 2]]")
        , ("factorials", "n! + n!!", "Plus[Factorial[n], Factorial2[n]]")
        , ("association", "<|a -> 1, b :> 2|>", "Association[Rule[a, 1], RuleDelayed[b, 2]]")
        , ("compound expression", "x = 1; x + 1;", "CompoundExpression[Set[x, 1], Plus[x, 1], Null]")
        ]
  and
    <$> traverse
      (\(label, source, expected) -> assertEqual ("InputForm parser: " <> label) (Right expected) (fullForm <$> parseInputForm source))
      cases

checkInputFormParserErrors :: IO Bool
checkInputFormParserErrors = do
  first <- assertLeft "reject incomplete InputForm call" (parseInputForm "f[1")
  second <- assertLeft "reject incomplete InputForm operator" (parseInputForm "1 +")
  third <- assertLeft "reject malformed InputForm part" (parseInputForm "x[[1]")
  pure (and [first, second, third])

checkFullForms :: IO Bool
checkFullForms = do
  let rootValue = expectRight (root [-2, 0, 1] 0 0)
      sparseValue =
        expectRight
          ( sparseArray
              [3, 4]
              [SparseEntry [1, 2] (String "value")]
              (Integer 0)
          )
      cases =
        [ ("symbol", "System`Plus", fullForm (Symbol "System`Plus"))
        , ("escaped symbol", "\\:03b1", fullForm (Symbol "α"))
        , ("arbitrary integer", "123456789012345678901234567890", fullForm (Integer 123456789012345678901234567890))
        , ("rational", "Rational[-2, 3]", fullForm (Rational (-2) 3))
        , ("real lexeme", "1.2300`40", fullForm (Real "1.2300`40"))
        , ("complex", "Complex[Rational[1, 2], -3]", fullForm (Complex (Rational 1 2) (Integer (-3))))
        , ("string", "\"a\\\"b\\\\c\\n\"", fullForm (String "a\"b\\c\n"))
        , ("byte array", "ByteArray[\"AAH+/w==\"]", fullForm (ByteArray (BS.pack [0, 1, 254, 255])))
        , ("call", "f[x, List[1, 2]]", fullForm (Call (Symbol "f") [Symbol "x", Call (Symbol "List") [Integer 1, Integer 2]]))
        , ("root", "Root[Function[Plus[-2, Power[Slot[1], 2]]], 1, 0]", fullForm rootValue)
        , ("sparse", "SparseArray[List[Rule[List[1, 2], \"value\"]], List[3, 4]]", fullForm sparseValue)
        ]
  and <$> traverse (\(label, expected, actual) -> assertEqual label expected actual) cases

checkSmartConstructors :: IO Bool
checkSmartConstructors = do
  let normalized = expectRight (rational (-6) (-8))
      checks =
        [ assertEqual "rational normalization" (Rational 3 4) normalized
        , assertLeft "zero denominator" (rational 1 0)
        , assertLeft "constant root" (root [1] 0 0)
        , assertLeft "invalid sparse coordinate" (sparseArray [2] [SparseEntry [3] (Integer 1)] (Integer 0))
        , assertLeft "duplicate sparse coordinate" (sparseArray [2] [SparseEntry [1] (Integer 1), SparseEntry [1] (Integer 2)] (Integer 0))
        , assertEqual "complex is atomic" [] (arguments (Complex (Integer 1) (Integer 2)))
        , assertEqual "root arguments" [Call (Symbol "Function") [Call (Symbol "Plus") [Integer (-2), Call (Symbol "Slot") [Integer 1]]], Integer 1, Integer 0] (arguments (expectRight (root [-2, 1] 0 0)))
        ]
  and <$> sequence checks

checkExpressionJsonRoundTrips :: IO Bool
checkExpressionJsonRoundTrips = do
  let expressions =
        [ Symbol "Global`x"
        , Integer 999999999999999999999999999999999999999999
        , Rational (-7) 13
        , Real "6.02214076*^23`8"
        , Complex (Integer 2) (Real "-0.0")
        , String "snowman ☃\n"
        , ByteArray (BS.pack [0 .. 255])
        , Call (Symbol "f") [Integer 1, Symbol "x"]
        , expectRight (root [1, 0, 1] 1 2)
        , expectRight (sparseArray [2] [SparseEntry [2] (Rational 1 3)] (Integer 0))
        ]
  and
    <$> traverse
      (\expression -> assertEqual ("expression JSON round trip: " <> fullForm expression) (Right expression) (exprFromJson (exprToJson expression)))
      expressions

checkJsonCodec :: IO Bool
checkJsonCodec = do
  let source = "{\"z\":-0.25e+12,\"a\":[true,null,\"snowman \\u2603\",\"face \\uD83D\\uDE00\"]}"
      expected =
        JsonObject
          ( Map.fromList
              [ ("a", JsonArray [JsonBool True, JsonNull, JsonString "snowman ☃", JsonString "face 😀"])
              , ("z", JsonNumber "-0.25e+12")
              ]
          )
      parsed = parseJson source
      encoded = encodeJson expected
  first <- assertEqual "JSON parse with numeric lexeme and surrogates" (Right expected) parsed
  second <- assertEqual "JSON deterministic encoding" "{\"a\":[true,null,\"snowman ☃\",\"face 😀\"],\"z\":-0.25e+12}" encoded
  third <- assertEqual "JSON codec round trip" (Right expected) (parseJson encoded)
  fourth <- assertLeft "reject leading-zero JSON number" (parseJson "01")
  fifth <- assertLeft "reject non-JSON whitespace" (parseJson "\fnull")
  pure (and [first, second, third, fourth, fifth])

checkProtocol :: IO Bool
checkProtocol = do
  let requestLine =
        encodeJson
          ( JsonObject
              ( Map.fromList
                  [ ("id", JsonString "request-7")
                  , ("command", JsonString "full_form")
                  , ("expression", exprToJson (Call (Symbol "Plus") [Integer 1, Symbol "x"]))
                  ]
              )
          )
      request = expectRight (decodeRequestLine requestLine)
      response = handleProtocolRequest request
      encoded = encodeResponseLine response
      decodedResponse = parseJson (withoutNewline encoded)
      expectedResult =
        JsonObject
          ( Map.fromList
              [ ("full_form", JsonString "Plus[1, x]")
              , ("expression", exprToJson (Call (Symbol "Plus") [Integer 1, Symbol "x"]))
              ]
          )
      expectedResponse =
        JsonObject
          ( Map.fromList
              [ ("id", JsonString "request-7")
              , ("command", JsonString "full_form")
              , ("success", JsonBool True)
              , ("result", expectedResult)
              ]
          )
  assertEqual "JSON-lines full_form request" (Right expectedResponse) decodedResponse

checkProtocolErrors :: IO Bool
checkProtocolErrors = do
  first <- assertLeft "protocol command must be a string" (decodeRequestLine "{\"command\":42}")
  let request = ProtocolRequest (Just (JsonNumber "9")) "evaluate" Nothing
      expected =
        ProtocolFailure
          { protocolResponseId = Just (JsonNumber "9")
          , protocolResponseCommand = "evaluate"
          , protocolError = "unsupported command: evaluate"
          }
  second <- assertEqual "unknown protocol command" expected (handleProtocolRequest request)
  pure (first && second)

withoutNewline :: Text -> Text
withoutNewline value = case Text.unsnoc value of
  Just (prefix, '\n') -> prefix
  _ -> value

assertEqual :: (Eq value, Show value) => Text -> value -> value -> IO Bool
assertEqual label expected actual
  | expected == actual = pure True
  | otherwise = do
      TextIO.putStrLn ("FAIL: " <> label)
      putStrLn ("  expected: " ++ show expected)
      putStrLn ("  actual:   " ++ show actual)
      pure False

assertLeft :: Show value => Text -> Either error value -> IO Bool
assertLeft _ (Left _) = pure True
assertLeft label (Right value) = do
  TextIO.putStrLn ("FAIL: " <> label <> " unexpectedly succeeded")
  print value
  pure False

expectRight :: Show error => Either error value -> value
expectRight (Right value) = value
expectRight (Left failure) = error ("unexpected Left: " ++ show failure)
