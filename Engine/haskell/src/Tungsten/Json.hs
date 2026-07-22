{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A dependency-light JSON value model and the first version of Tungsten's
-- newline-delimited process protocol.
module Tungsten.Json
  ( JsonValue (..)
  , JsonError (..)
  , parseJson
  , encodeJson
  , exprToJson
  , exprFromJson
  , ProtocolRequest (..)
  , ProtocolResponse (..)
  , protocolRequestFromJson
  , protocolResponseToJson
  , decodeRequestLine
  , encodeResponseLine
  , handleProtocolRequest
  ) where

import Data.Bifunctor (first)
import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteString as BS
import Data.Char (chr, digitToInt, isHexDigit, ord)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import Text.Parsec
  ( anyChar
  , between
  , char
  , choice
  , count
  , digit
  , eof
  , many
  , many1
  , notFollowedBy
  , oneOf
  , option
  , satisfy
  , sepBy
  , skipMany
  , string
  , try
  , unexpected
  , (<|>)
  )
import qualified Text.Parsec as Parsec
import Text.Parsec.String (Parser)
import Text.Read (readMaybe)
import Tungsten.Evaluate (evaluationErrorMessage)
import Tungsten.Expression
import Tungsten.Session
  ( EvaluationMessage (..)
  , emptySession
  , evaluateInSession
  , sessionPrints
  , sessionVisibleMessages
  )
import Tungsten.WolframString
import Tungsten.Parser (parseErrorMessage, parseFullForm, parseInputForm)

-- | JSON numbers retain their source lexeme.  This avoids silently rounding
-- arbitrary integers or decimal reals before the evaluator sees them.
data JsonValue
  = JsonNull
  | JsonBool !Bool
  | JsonNumber !Text
  | JsonString !Text
  | JsonArray ![JsonValue]
  | JsonObject !(Map Text JsonValue)
  deriving (Eq, Show)

newtype JsonError = JsonError {jsonErrorMessage :: Text}
  deriving (Eq, Show)

parseJson :: Text -> Either JsonError JsonValue
parseJson source =
  first (JsonError . T.pack . show)
    (Parsec.parse (jsonSpaces *> jsonValueParser <* jsonSpaces <* eof) "JSON input" (T.unpack source))

encodeJson :: JsonValue -> Text
encodeJson = \case
  JsonNull -> "null"
  JsonBool False -> "false"
  JsonBool True -> "true"
  JsonNumber source -> source
  JsonString value -> jsonString value
  JsonArray values -> "[" <> T.intercalate "," (map encodeJson values) <> "]"
  JsonObject values ->
    "{"
      <> T.intercalate
        ","
        [jsonString key <> ":" <> encodeJson value | (key, value) <- Map.toAscList values]
      <> "}"

jsonValueParser :: Parser JsonValue
jsonValueParser =
  choice
    [ JsonNull <$ string "null"
    , JsonBool True <$ string "true"
    , JsonBool False <$ string "false"
    , JsonString <$> jsonStringParser
    , JsonArray <$> between (char '[' *> jsonSpaces) (jsonSpaces *> char ']') arrayItems
    , JsonObject . Map.fromList
        <$> between (char '{' *> jsonSpaces) (jsonSpaces *> char '}') objectItems
    , JsonNumber . T.pack <$> jsonNumberParser
    ]
 where
  arrayItems = jsonValueParser `sepBy` (jsonSpaces *> char ',' <* jsonSpaces)
  objectItems = objectItem `sepBy` (jsonSpaces *> char ',' <* jsonSpaces)
  objectItem = do
    key <- jsonStringParser
    jsonSpaces
    _ <- char ':'
    jsonSpaces
    value <- jsonValueParser
    pure (key, value)

jsonSpaces :: Parser ()
jsonSpaces = skipMany (oneOf " \t\r\n")

jsonNumberParser :: Parser String
jsonNumberParser = do
  sign <- option "" (pure <$> char '-')
  whole <- zero <|> nonzero
  fraction <- option "" $ do
    point <- char '.'
    digits <- many1 digit
    pure (point : digits)
  exponentText <- option "" $ do
    marker <- oneOf "eE"
    exponentSign <- option "" (pure <$> oneOf "+-")
    digits <- many1 digit
    pure (marker : exponentSign ++ digits)
  pure (sign ++ whole ++ fraction ++ exponentText)
 where
  zero = do
    value <- char '0'
    notFollowedBy digit
    pure [value]
  nonzero = (:) <$> oneOf ['1' .. '9'] <*> many digit

jsonStringParser :: Parser Text
jsonStringParser = T.pack <$> between (char '"') (char '"') (many stringCharacter)
 where
  stringCharacter =
    satisfy (\character -> character >= '\x20' && character /= '"' && character /= '\\')
      <|> escapedCharacter
  escapedCharacter = do
    _ <- char '\\'
    anyChar >>= \case
      '"' -> pure '"'
      '\\' -> pure '\\'
      '/' -> pure '/'
      'b' -> pure '\b'
      'f' -> pure '\f'
      'n' -> pure '\n'
      'r' -> pure '\r'
      't' -> pure '\t'
      'u' -> unicodeCharacter
      marker -> unexpected ("JSON escape \\" ++ [marker])

unicodeCharacter :: Parser Char
unicodeCharacter = do
  firstCodeUnit <- hexQuad
  if firstCodeUnit >= 0xd800 && firstCodeUnit <= 0xdbff
    then do
      _ <- try (string "\\u")
      secondCodeUnit <- hexQuad
      if secondCodeUnit >= 0xdc00 && secondCodeUnit <= 0xdfff
        then
          pure
            ( chr
                ( 0x10000
                    + ((firstCodeUnit - 0xd800) `shiftL` 10)
                    + (secondCodeUnit - 0xdc00)
                )
            )
        else unexpected "non-low-surrogate JSON code unit"
    else
      if firstCodeUnit >= 0xdc00 && firstCodeUnit <= 0xdfff
        then unexpected "unpaired JSON low surrogate"
        else pure (chr firstCodeUnit)
 where
  hexQuad = foldl' (\value character -> value * 16 + digitToInt character) 0 <$> count 4 hexDigit
  hexDigit = satisfy isHexDigit

jsonString :: Text -> Text
jsonString value = "\"" <> T.concatMap escape value <> "\""
 where
  escape '"' = "\\\""
  escape '\\' = "\\\\"
  escape '\b' = "\\b"
  escape '\f' = "\\f"
  escape '\n' = "\\n"
  escape '\r' = "\\r"
  escape '\t' = "\\t"
  escape character
    | ord character < 0x20 = "\\u" <> pad 4 (showHex (ord character) "")
    | otherwise = T.singleton character
  pad width digits = T.pack (replicate (width - length digits) '0' ++ digits)

-- | Project an expression to the same tagged tree shape used by Tungsten's
-- Python implementation.
exprToJson :: Expr -> JsonValue
exprToJson expression = JsonObject $ case expression of
  Symbol name -> object [text "type" "symbol", text "name" name]
  Integer value -> object [text "type" "integer", number "value" value]
  Rational numerator denominator ->
    object
      [ text "type" "rational"
      , number "numerator" numerator
      , number "denominator" denominator
      ]
  Real source -> object [text "type" "real", text "text" source]
  Complex realPart imaginaryPart ->
    object
      [ text "type" "complex"
      , ("real", exprToJson realPart)
      , ("imaginary", exprToJson imaginaryPart)
      ]
  String value -> object (stringFields value)
  ByteArray values ->
    object
      [ text "type" "byte_array"
      , ("values", JsonArray (map (JsonNumber . T.pack . show) (BS.unpack values)))
      , text "base64" (base64Encode values)
      , number "length" (fromIntegral (BS.length values) :: Integer)
      ]
  Call expressionHead values ->
    object
      [ text "type" "call"
      , ("head", exprToJson expressionHead)
      , ("args", JsonArray (map exprToJson values))
      ]
  Root coefficients index method ->
    object
      [ text "type" "root"
      , ("coefficients", JsonArray (map (JsonNumber . T.pack . show) coefficients))
      , number "index" (index + 1)
      , number "method" method
      ]
  SparseArray dimensions entries fill ->
    object
      [ text "type" "sparse_array"
      , ("dimensions", JsonArray (map (JsonNumber . T.pack . show) dimensions))
      , ("fill_value", exprToJson fill)
      , ("entries", JsonArray (map sparseEntryToJson entries))
      , number "explicit_length" (fromIntegral (length entries) :: Integer)
      ]
 where
  object = Map.fromList
  text key value = (key, JsonString value)
  number key value = (key, JsonNumber (T.pack (show value)))
  stringFields value =
    [text "type" "string", text "value" value]
      <> if hasInlineBoxes value
        then [("inline_boxes", JsonArray (map inlineBoxSegmentToJson (inlineBoxSegments value)))]
        else []
  inlineBoxSegmentToJson (StringInlineBoxSegment boxExpression source) =
    JsonObject
      ( Map.fromList
          [ ("box_expression", JsonString boxExpression)
          , ("inline_box_escape", JsonString source)
          , ("kind", JsonString "inline_box")
          ]
      )
  inlineBoxSegmentToJson (StringTextSegment value) = JsonString value
  sparseEntryToJson (SparseEntry indices value) =
    JsonObject
      ( Map.fromList
          [ ("indices", JsonArray (map (JsonNumber . T.pack . show) indices))
          , ("value", exprToJson value)
          ]
      )

exprFromJson :: JsonValue -> Either JsonError Expr
exprFromJson payload = do
  values <- expectObject "expression" payload
  expressionType <- requireString "type" values
  case expressionType of
    "symbol" -> Symbol <$> requireString "name" values
    "integer" -> Integer <$> requireInteger "value" values
    "rational" -> do
      numerator <- requireInteger "numerator" values
      denominator <- requireInteger "denominator" values
      first expressionError (rational numerator denominator)
    "real" -> Real <$> requireString "text" values
    "complex" ->
      Complex
        <$> (requireValue "real" values >>= exprFromJson)
        <*> (requireValue "imaginary" values >>= exprFromJson)
    "string" -> String <$> requireString "value" values
    "byte_array" -> ByteArray . BS.pack <$> (requireArray "values" values >>= traverse byteValue)
    "call" ->
      Call
        <$> (requireValue "head" values >>= exprFromJson)
        <*> (requireArray "args" values >>= traverse exprFromJson)
    "root" -> do
      coefficients <- requireArray "coefficients" values >>= traverse integerValue
      externalIndex <- requireInteger "index" values
      method <- requireInteger "method" values
      first expressionError (root coefficients (externalIndex - 1) method)
    "sparse_array" -> do
      dimensions <- requireArray "dimensions" values >>= traverse integerValue
      entries <- requireArray "entries" values >>= traverse sparseEntryFromJson
      fill <- requireValue "fill_value" values >>= exprFromJson
      first expressionError (sparseArray dimensions entries fill)
    other -> Left (JsonError ("unsupported expression type: " <> other))
 where
  expressionError = JsonError . expressionErrorMessage
  byteValue value = do
    integerValue' <- integerValue value
    guardEither
      (integerValue' >= 0 && integerValue' <= 255)
      "byte-array values must be integers from 0 through 255"
    pure (fromInteger integerValue')
  sparseEntryFromJson value = do
    entry <- expectObject "sparse-array entry" value
    indices <- requireArray "indices" entry >>= traverse integerValue
    entryValue <- requireValue "value" entry >>= exprFromJson
    pure (SparseEntry indices entryValue)

data ProtocolRequest = ProtocolRequest
  { protocolRequestId :: !(Maybe JsonValue)
  , protocolCommand :: !Text
  , protocolExpression :: !(Maybe Expr)
  , protocolSource :: !(Maybe Text)
  , protocolForm :: !(Maybe Text)
  }
  deriving (Eq, Show)

data ProtocolResponse
  = ProtocolSuccess
      { protocolResponseId :: !(Maybe JsonValue)
      , protocolResponseCommand :: !Text
      , protocolResult :: !JsonValue
      }
  | ProtocolFailure
      { protocolResponseId :: !(Maybe JsonValue)
      , protocolResponseCommand :: !Text
      , protocolError :: !Text
      }
  deriving (Eq, Show)

protocolRequestFromJson :: JsonValue -> Either JsonError ProtocolRequest
protocolRequestFromJson payload = do
  values <- expectObject "protocol request" payload
  command <- requireString "command" values
  expression <- traverse exprFromJson (Map.lookup "expression" values)
  source <- optionalString "source" values
  form <- optionalString "form" values
  pure
    ProtocolRequest
      { protocolRequestId = Map.lookup "id" values
      , protocolCommand = command
      , protocolExpression = expression
      , protocolSource = source
      , protocolForm = form
      }

protocolResponseToJson :: ProtocolResponse -> JsonValue
protocolResponseToJson response = JsonObject (withIdentifier fields)
 where
  identifier = protocolResponseId response
  withIdentifier = maybe id (Map.insert "id") identifier
  fields = case response of
    ProtocolSuccess _ command result ->
      Map.fromList
        [ ("command", JsonString command)
        , ("success", JsonBool True)
        , ("result", result)
        ]
    ProtocolFailure _ command message ->
      Map.fromList
        [ ("command", JsonString command)
        , ("success", JsonBool False)
        , ("error", JsonString message)
        ]

decodeRequestLine :: Text -> Either JsonError ProtocolRequest
decodeRequestLine source = parseJson source >>= protocolRequestFromJson

encodeResponseLine :: ProtocolResponse -> Text
encodeResponseLine response = encodeJson (protocolResponseToJson response) <> "\n"

-- | Pure command dispatch for the protocol foundation.  Parser and evaluator
-- commands can be added without changing framing or response/error shapes.
handleProtocolRequest :: ProtocolRequest -> ProtocolResponse
handleProtocolRequest request = case protocolCommand request of
  "ping" ->
    ProtocolSuccess
      (protocolRequestId request)
      "ping"
      ( JsonObject
          ( Map.fromList
              [ ("protocol", JsonNumber "1")
              , ("version", JsonString "0.1.0")
              ]
          )
      )
  "full_form" -> case protocolExpression request of
    Just expression ->
      ProtocolSuccess
        (protocolRequestId request)
        "full_form"
        ( JsonObject
            ( Map.fromList
                [ ("full_form", JsonString (fullForm expression))
                , ("expression", exprToJson expression)
                ]
            )
        )
    Nothing -> failure "full_form requires an expression"
  "parse" -> case requestExpression request of
    Left message -> failure message
    Right expression ->
      ProtocolSuccess
        (protocolRequestId request)
        "parse"
        (expressionResult expression)
  "evaluate" -> case requestExpression request of
    Left message -> failure message
    Right expression -> case evaluateInSession emptySession expression of
      Left evaluationError -> failure (evaluationErrorMessage evaluationError)
      Right (result, updatedSession) ->
        ProtocolSuccess
          (protocolRequestId request)
          "evaluate"
          ( JsonObject
              ( Map.fromList
                  [ ("input", expressionResult expression)
                  , ( "messages"
                    , JsonArray
                        (map evaluationMessageResult (sessionVisibleMessages updatedSession))
                    )
                  , ("prints", JsonArray (map JsonString (sessionPrints updatedSession)))
                  , ("result", expressionResult result)
                  ]
              )
          )
  command -> failure ("unsupported command: " <> command)
 where
  failure message =
    ProtocolFailure (protocolRequestId request) (protocolCommand request) message

requestExpression :: ProtocolRequest -> Either Text Expr
requestExpression request = case protocolExpression request of
  Just expression -> Right expression
  Nothing -> case protocolSource request of
    Nothing -> Left (protocolCommand request <> " requires an expression or source")
    Just source -> case normalizedForm of
      "input" -> parseWith parseInputForm source
      "inputform" -> parseWith parseInputForm source
      "full" -> parseWith parseFullForm source
      "fullform" -> parseWith parseFullForm source
      other -> Left ("unsupported expression form: " <> other)
 where
  normalizedForm = T.toLower (T.strip (maybe "input" id (protocolForm request)))
  parseWith parser source = first parseErrorMessage (parser source)

expressionResult :: Expr -> JsonValue
expressionResult expression =
  JsonObject
    ( Map.fromList
        [ ("expression", exprToJson expression)
        , ("full_form", JsonString (fullForm expression))
        , ("input_form", JsonString (inputForm expression))
        ]
    )

evaluationMessageResult :: EvaluationMessage -> JsonValue
evaluationMessageResult message =
  JsonObject
    ( Map.fromList
        [ ("full_name", JsonString (fullForm (evaluationMessageFullName message)))
        , ("name", JsonString (evaluationMessageName message))
        , ("text", JsonString (evaluationMessageText message))
        ]
    )

expectObject :: Text -> JsonValue -> Either JsonError (Map Text JsonValue)
expectObject _ (JsonObject values) = Right values
expectObject label _ = Left (JsonError (label <> " must be a JSON object"))

requireValue :: Text -> Map Text JsonValue -> Either JsonError JsonValue
requireValue key values =
  maybe (Left (JsonError ("missing JSON field: " <> key))) Right (Map.lookup key values)

requireString :: Text -> Map Text JsonValue -> Either JsonError Text
requireString key values = requireValue key values >>= \case
  JsonString value -> Right value
  _ -> Left (JsonError ("JSON field must be a string: " <> key))

optionalString :: Text -> Map Text JsonValue -> Either JsonError (Maybe Text)
optionalString key values = case Map.lookup key values of
  Nothing -> Right Nothing
  Just (JsonString value) -> Right (Just value)
  Just _ -> Left (JsonError ("JSON field must be a string: " <> key))

requireArray :: Text -> Map Text JsonValue -> Either JsonError [JsonValue]
requireArray key values = requireValue key values >>= \case
  JsonArray value -> Right value
  _ -> Left (JsonError ("JSON field must be an array: " <> key))

requireInteger :: Text -> Map Text JsonValue -> Either JsonError Integer
requireInteger key values = requireValue key values >>= integerValue

integerValue :: JsonValue -> Either JsonError Integer
integerValue (JsonNumber source) =
  maybe (Left (JsonError "JSON number is not an integer")) Right (readMaybe (T.unpack source))
integerValue _ = Left (JsonError "expected a JSON integer")

guardEither :: Bool -> Text -> Either JsonError ()
guardEither condition message =
  if condition then Right () else Left (JsonError message)

base64Encode :: BS.ByteString -> Text
base64Encode = T.pack . go . BS.unpack
 where
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  pick value = alphabet !! fromIntegral value
  go [] = []
  go [a] = [pick (a `shiftR` 2), pick ((a .&. 3) `shiftL` 4), '=', '=']
  go [a, b] =
    [ pick (a `shiftR` 2)
    , pick (((a .&. 3) `shiftL` 4) .|. (b `shiftR` 4))
    , pick ((b .&. 15) `shiftL` 2)
    , '='
    ]
  go (a : b : c : rest) =
    [ pick (a `shiftR` 2)
    , pick (((a .&. 3) `shiftL` 4) .|. (b `shiftR` 4))
    , pick (((b .&. 15) `shiftL` 2) .|. (c `shiftR` 6))
    , pick (c .&. 63)
    ]
      ++ go rest
