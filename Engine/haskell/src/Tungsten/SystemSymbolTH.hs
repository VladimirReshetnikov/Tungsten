{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Compile-time loader and validator for the Wolfram System-symbol snapshot.
module Tungsten.SystemSymbolTH (systemSymbolEntriesFrom) where

import Control.Monad (unless, when)
import Data.Bits (bit, (.|.))
import qualified Data.ByteString as BS
import Data.Char (chr, digitToInt, isHexDigit, ord)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (qAddDependentFile)
import System.FilePath ((</>), takeDirectory)
import Text.Parsec
import Text.Parsec.String (Parser)
import Text.Read (readMaybe)

-- | Read the pinned snapshot and produce sorted @(name, attribute-mask)@
-- entries. The additional names are Tungsten's Python-only System symbols and
-- deliberately receive no attributes.
systemSymbolEntriesFrom :: FilePath -> [String] -> Q Exp
systemSymbolEntriesFrom relativePath additionalNames = do
  sourceLocation <- location
  let packageRoot = iterate takeDirectory (loc_filename sourceLocation) !! 4
      catalogPath = packageRoot </> relativePath
  qAddDependentFile catalogPath
  bytes <- runIO (BS.readFile catalogPath)
  source <-
    case TE.decodeUtf8' bytes of
      Left problem -> fail ("invalid UTF-8 in " <> catalogPath <> ": " <> show problem)
      Right decoded -> pure (T.unpack decoded)
  json <-
    case parse jsonDocument catalogPath source of
      Left problem -> fail (show problem)
      Right value -> pure value
  snapshotEntries <- either fail pure (validateCatalog catalogPath json)
  let snapshotNames = Set.fromList (map fst snapshotEntries)
      additions = Set.fromList additionalNames
  unless (Set.size additions == length additionalNames) $
    fail "duplicate Python-only System-symbol additions"
  unless (Set.null (Set.intersection snapshotNames additions)) $
    fail "Python-only System-symbol additions overlap the Wolfram snapshot"
  let combined = sortOn fst (snapshotEntries <> [(name, 0) | name <- additionalNames])
  unless (length combined == 7941) $
    fail ("expected 7,941 visible System symbols, found " <> show (length combined))
  listE
    [ tupE [litE (stringL name), litE (integerL mask)]
    | (name, mask) <- combined
    ]

data JsonValue
  = JsonObject [(String, JsonValue)]
  | JsonArray [JsonValue]
  | JsonString String
  | JsonNumber String
  | JsonBool Bool
  | JsonNull
  deriving stock (Eq, Show)

jsonDocument :: Parser JsonValue
jsonDocument = jsonSpace *> jsonValue <* eof

jsonValue :: Parser JsonValue
jsonValue =
  choice
    [ JsonObject <$> jsonObject
    , JsonArray <$> jsonArray
    , JsonString <$> jsonString
    , JsonNumber <$> jsonNumber
    , JsonBool True <$ string "true"
    , JsonBool False <$ string "false"
    , JsonNull <$ string "null"
    ]
    <* jsonSpace

jsonObject :: Parser [(String, JsonValue)]
jsonObject = between (symbolChar '{') (symbolChar '}') (field `sepBy` symbolChar ',')
 where
  field = do
    key <- jsonString <* jsonSpace
    _ <- symbolChar ':'
    value <- jsonValue
    pure (key, value)

jsonArray :: Parser [JsonValue]
jsonArray = between (symbolChar '[') (symbolChar ']') (jsonValue `sepBy` symbolChar ',')

jsonString :: Parser String
jsonString = char '"' *> many stringCharacter <* char '"'
 where
  stringCharacter =
    satisfy (\character -> character /= '"' && character /= '\\' && ord character >= 0x20)
      <|> (char '\\' *> escapedCharacter)

escapedCharacter :: Parser Char
escapedCharacter =
  choice
    [ '"' <$ char '"'
    , '\\' <$ char '\\'
    , '/' <$ char '/'
    , '\b' <$ char 'b'
    , '\f' <$ char 'f'
    , '\n' <$ char 'n'
    , '\r' <$ char 'r'
    , '\t' <$ char 't'
    , char 'u' *> unicodeCharacter
    ]

unicodeCharacter :: Parser Char
unicodeCharacter = do
  first <- fourHexDigits
  if first >= 0xd800 && first <= 0xdbff
    then do
      _ <- string "\\u"
      second <- fourHexDigits
      if second >= 0xdc00 && second <= 0xdfff
        then pure (chr (0x10000 + (first - 0xd800) * 0x400 + second - 0xdc00))
        else unexpected "non-low-surrogate Unicode escape"
    else
      if first >= 0xdc00 && first <= 0xdfff
        then unexpected "unpaired low-surrogate Unicode escape"
        else pure (chr first)

fourHexDigits :: Parser Int
fourHexDigits =
  foldl' (\value numeralCharacter -> value * 16 + digitToInt numeralCharacter) 0
    <$> count 4 (satisfy isHexDigit)

jsonNumber :: Parser String
jsonNumber = do
  sign <- option "" (string "-")
  integerPart <- string "0" <|> ((:) <$> oneOf ['1' .. '9'] <*> many digit)
  fractionalPart <- option "" ((:) <$> char '.' <*> many1 digit)
  exponentPart <- option "" $ do
    marker <- oneOf "eE"
    exponentSign <- option "" ((: []) <$> oneOf "+-")
    exponentDigits <- many1 digit
    pure (marker : exponentSign <> exponentDigits)
  pure (sign <> integerPart <> fractionalPart <> exponentPart)

symbolChar :: Char -> Parser Char
symbolChar character = char character <* jsonSpace

jsonSpace :: Parser ()
jsonSpace = skipMany (oneOf " \t\r\n\xfeff")

validateCatalog :: FilePath -> JsonValue -> Either String [(String, Integer)]
validateCatalog catalogPath = \case
  JsonObject fields -> do
    ensureUniqueObjectFields fields
    version <- requiredStringField "wolframVersion" fields
    unlessEither
      (version == "15.0.0 for Microsoft Windows (64-bit) (May 19, 2026)")
      ("unexpected Wolfram version in " <> catalogPath <> ": " <> show version)
    context <- requiredStringField "context" fields
    unlessEither (context == "System`") ("expected System` context in " <> catalogPath)
    declaredCount <- requiredIntegerField "symbolCount" fields
    symbolRows <- requiredArrayField "symbols" fields
    entries <- traverse validateSymbolRow symbolRows
    unlessEither (declaredCount == 7935) ("expected declared symbolCount 7935, found " <> show declaredCount)
    unlessEither (length entries == 7935) ("expected 7,935 snapshot rows, found " <> show (length entries))
    let table = Map.fromList entries
    unlessEither (Map.size table == length entries) "duplicate System-symbol name in snapshot"
    validateRepresentativeMetadata table
    pure entries
  _ -> Left ("expected a JSON object in " <> catalogPath)

validateSymbolRow :: JsonValue -> Either String (String, Integer)
validateSymbolRow = \case
  JsonArray [JsonString name, JsonArray rawAttributes] -> do
    unlessEither (not (null name) && '`' `notElem` name) ("invalid unqualified System-symbol name: " <> show name)
    attributes <- traverse jsonAttributeName rawAttributes
    unlessEither
      (Set.size (Set.fromList attributes) == length attributes)
      ("duplicate attribute for System symbol " <> show name)
    masks <- traverse attributeMask attributes
    pure (name, foldl' (.|.) 0 masks)
  malformed -> Left ("invalid System-symbol row: " <> take 160 (show malformed))

jsonAttributeName :: JsonValue -> Either String String
jsonAttributeName = \case
  JsonString name -> Right name
  malformed -> Left ("non-string System-symbol attribute: " <> show malformed)

attributeMask :: String -> Either String Integer
attributeMask name = bit <$> case name of
  "Constant" -> Right 0
  "Flat" -> Right 1
  "HoldAll" -> Right 2
  "HoldAllComplete" -> Right 3
  "HoldFirst" -> Right 4
  "HoldRest" -> Right 5
  "Listable" -> Right 6
  "Locked" -> Right 7
  "NHoldAll" -> Right 8
  "NHoldFirst" -> Right 9
  "NHoldRest" -> Right 10
  "NonThreadable" -> Right 11
  "NumericFunction" -> Right 12
  "OneIdentity" -> Right 13
  "Orderless" -> Right 14
  "Protected" -> Right 15
  "ReadProtected" -> Right 16
  "SequenceHold" -> Right 17
  _ -> Left ("unknown System-symbol attribute: " <> show name)

validateRepresentativeMetadata :: Map.Map String Integer -> Either String ()
validateRepresentativeMetadata table = do
  expect "Plus" ["Flat", "Listable", "NumericFunction", "OneIdentity", "Orderless", "Protected"]
  expect "Attributes" ["HoldAll", "Listable", "Protected"]
  expect "Function" ["HoldAll", "Protected"]
  expect "I" ["Locked", "Protected", "ReadProtected"]
  expect "Catalan" ["Constant", "Protected"]
  expect "ChampernowneNumber" ["Constant", "Listable", "NHoldFirst", "NumericFunction", "Protected", "ReadProtected"]
  expect "Degree" ["Constant", "Protected", "ReadProtected"]
  expect "E" ["Constant", "Protected", "ReadProtected"]
  expect "EulerGamma" ["Constant", "Protected"]
  expect "Glaisher" ["Constant", "Protected"]
  expect "GoldenAngle" ["Constant", "Protected"]
  expect "GoldenRatio" ["Constant", "Protected"]
  expect "Khinchin" ["Constant", "Protected"]
  expect "MachinePrecision" ["Constant", "Protected"]
  expect "Pi" ["Constant", "Protected", "ReadProtected"]
 where
  expect name attributes = do
    masks <- traverse attributeMask attributes
    let expected = foldl' (.|.) 0 masks
    case Map.lookup name table of
      Just actual | actual == expected -> Right ()
      Just actual -> Left ("unexpected attributes for " <> name <> ": mask " <> show actual)
      Nothing -> Left ("missing required System symbol " <> name)

ensureUniqueObjectFields :: [(String, JsonValue)] -> Either String ()
ensureUniqueObjectFields fields =
  unlessEither
    (length names == Set.size (Set.fromList names))
    "duplicate field in System-symbol catalog object"
 where
  names = map fst fields

requiredField :: String -> [(String, JsonValue)] -> Either String JsonValue
requiredField name fields =
  case [value | (key, value) <- fields, key == name] of
    [value] -> Right value
    [] -> Left ("missing System-symbol catalog field " <> show name)
    _ -> Left ("duplicate System-symbol catalog field " <> show name)

requiredStringField :: String -> [(String, JsonValue)] -> Either String String
requiredStringField name fields =
  requiredField name fields >>= \case
    JsonString value -> Right value
    _ -> Left ("expected string field " <> show name)

requiredIntegerField :: String -> [(String, JsonValue)] -> Either String Integer
requiredIntegerField name fields =
  requiredField name fields >>= \case
    JsonNumber value
      | Just integer <- readMaybe value -> Right integer
    _ -> Left ("expected integer field " <> show name)

requiredArrayField :: String -> [(String, JsonValue)] -> Either String [JsonValue]
requiredArrayField name fields =
  requiredField name fields >>= \case
    JsonArray values -> Right values
    _ -> Left ("expected array field " <> show name)

unlessEither :: Bool -> String -> Either String ()
unlessEither condition message = when (not condition) (Left message)
