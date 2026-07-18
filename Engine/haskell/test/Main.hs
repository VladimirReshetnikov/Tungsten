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

main :: IO ()
main = do
  results <- sequence tests
  if and results
    then TextIO.putStrLn "All Haskell expression/JSON foundation tests passed."
    else exitFailure

tests :: [IO Bool]
tests =
  [ checkFullForms
  , checkSmartConstructors
  , checkExpressionJsonRoundTrips
  , checkJsonCodec
  , checkProtocol
  , checkProtocolErrors
  ]

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
