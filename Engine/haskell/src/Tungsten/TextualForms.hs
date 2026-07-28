{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Kernel-free textual, box, base-encoding, and in-memory import/export
-- conversions.  This module deliberately depends only on the expression and
-- parser layers, so the evaluator can use it without introducing a cycle with
-- the JSON-first process protocol.
module Tungsten.TextualForms
  ( baseDecodeExpr
  , baseEncodeExpr
  , exportByteArrayExpr
  , exportStringExpr
  , importByteArrayExpr
  , importStringExpr
  , makeBoxesExpr
  , makeExpressionExpr
  , parseStandardFormSource
  , stripBoxesExpr
  , syntaxLengthExpr
  , syntaxQExpr
  , toBoxesExpr
  , toExpressionExpr
  , toStringExpr
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteString as BS
import Data.Char (chr, isAlphaNum, isDigit, isSpace, ord, toUpper)
import Data.List (partition)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
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
import Text.Parsec.Text (Parser)
import Text.Read (readMaybe)
import Tungsten.Expression
import Tungsten.NamedCharacters (encodePrintableAscii)
import Tungsten.Parser (parseErrorMessage, parseInputForm)
import Tungsten.SystemSymbols (normalizeSystemSymbolName)
import Tungsten.WolframString (wlString)

type Conversion = Either Text Expr

-- | Parse StandardForm source and interpret box constructors when the parsed
-- tree is a box expression.  Plain StandardForm text shares InputForm's
-- surface grammar; boxes add a semantic projection after that syntax pass.
parseStandardFormSource :: Text -> Either Text Expr
parseStandardFormSource source = case parseInputForm source of
  Left parseError -> Left (parseErrorMessage parseError)
  Right expression
    | looksLikeBoxes expression -> interpretBoxes expression
    | otherwise -> Right expression

shortSystemName :: Text -> Text
shortSystemName name = maybe name id (normalizeSystemSymbolName name)

listItems :: Expr -> Maybe [Expr]
listItems (Call (Symbol name) values)
  | shortSystemName name == "List" = Just values
listItems _ = Nothing

ruleOption :: Text -> Expr -> Expr
ruleOption name value = Call (Symbol "Rule") [Symbol name, value]

boolean :: Bool -> Expr
boolean value = Symbol (if value then "True" else "False")

-- Base encodings -----------------------------------------------------------

data BaseEncoding = Base16 | Base64 | Base85ASCII
  deriving (Eq, Show)

baseEncodingName :: BaseEncoding -> Text
baseEncodingName = \case
  Base16 -> "Base16"
  Base64 -> "Base64"
  Base85ASCII -> "Base85ASCII"

requireBaseEncoding :: Text -> Expr -> Either Text BaseEncoding
requireBaseEncoding operation = \case
  String raw -> case T.toLower (T.strip raw) of
    "base16" -> Right Base16
    "base64" -> Right Base64
    "base85ascii" -> Right Base85ASCII
    _ -> Left (operation <> " currently supports Base64, Base16, and Base85ASCII.")
  _ -> Left (operation <> " expects the encoding name to be a string.")

baseEncodeExpr :: [Expr] -> Conversion
baseEncodeExpr values = case values of
  [ByteArray bytes] -> Right (String (encodeBase Base64 bytes))
  [ByteArray bytes, encodingExpression] -> do
    encoding <- requireBaseEncoding "BaseEncode" encodingExpression
    Right (String (encodeBase encoding bytes))
  [_] -> Left "BaseEncode expects a ByteArray."
  [_, _] -> Left "BaseEncode expects a ByteArray."
  _ -> Left "BaseEncode expects a byte array and an optional base encoding."

baseDecodeExpr :: [Expr] -> Conversion
baseDecodeExpr values = case values of
  [String source] -> decode Base64 source
  [String source, encodingExpression] -> do
    encoding <- requireBaseEncoding "BaseDecode" encodingExpression
    decode encoding source
  [_] -> Left "BaseDecode expects the input data to be a string."
  [_, _] -> Left "BaseDecode expects the input data to be a string."
  _ -> Left "BaseDecode expects a string and an optional base encoding."
 where
  decode encoding source =
    maybe
      (Left ("BaseDecode failed for " <> baseEncodingName encoding <> "."))
      (Right . ByteArray)
      (decodeBase encoding source)

encodeBase :: BaseEncoding -> BS.ByteString -> Text
encodeBase encoding bytes = case encoding of
  Base16 -> T.pack (concatMap byteHex (BS.unpack bytes))
  Base64 -> base64Encode bytes
  Base85ASCII -> ascii85Encode bytes
 where
  byteHex byte =
    let digits = map toUpper (showHex byte "")
     in if length digits == 1 then '0' : digits else digits

decodeBase :: BaseEncoding -> Text -> Maybe BS.ByteString
decodeBase encoding source = case encoding of
  Base16 -> base16Decode filtered16
  Base64 -> base64DecodePermissive filtered64
  Base85ASCII -> ascii85Decode filtered85
 where
  filtered16 = T.filter (`elem` ("0123456789abcdefABCDEF" :: String)) source
  filtered64 = T.filter (\c -> isAlphaNum c || c `elem` ("+/=_-" :: String)) source
  filtered85 = T.filter (\c -> c == 'z' || (c >= '!' && c <= 'u')) source

base16Decode :: Text -> Maybe BS.ByteString
base16Decode source
  | odd (T.length source) = Nothing
  | otherwise = BS.pack <$> pairs (T.unpack source)
 where
  pairs [] = Just []
  pairs (first : second : rest) = do
    high <- hexDigitValue first
    low <- hexDigitValue second
    ((fromIntegral (high * 16 + low)) :) <$> pairs rest
  pairs _ = Nothing

  hexDigitValue character
    | character >= '0' && character <= '9' = Just (ord character - ord '0')
    | upper >= 'A' && upper <= 'F' = Just (10 + ord upper - ord 'A')
    | otherwise = Nothing
   where
    upper = toUpper character

base64Encode :: BS.ByteString -> Text
base64Encode = T.pack . go . BS.unpack
 where
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  pick value = alphabet !! fromIntegral value
  go [] = []
  go [a] =
    [ pick (a `shiftR` 2)
    , pick ((a .&. 0x03) `shiftL` 4)
    , '='
    , '='
    ]
  go [a, b] =
    [ pick (a `shiftR` 2)
    , pick (((a .&. 0x03) `shiftL` 4) .|. (b `shiftR` 4))
    , pick ((b .&. 0x0f) `shiftL` 2)
    , '='
    ]
  go (a : b : c : rest) =
    [ pick (a `shiftR` 2)
    , pick (((a .&. 0x03) `shiftL` 4) .|. (b `shiftR` 4))
    , pick (((b .&. 0x0f) `shiftL` 2) .|. (c `shiftR` 6))
    , pick (c .&. 0x3f)
    ]
      <> go rest

base64DecodePermissive :: Text -> Maybe BS.ByteString
base64DecodePermissive source =
  decodeBase64Strict (padBase64 (T.filter (`notElem` ("-_" :: String)) source))
 where
  padBase64 value =
    let unpadded = T.dropWhileEnd (== '=') value
        padding = (4 - T.length unpadded `mod` 4) `mod` 4
     in unpadded <> T.replicate padding "="

decodeBase64Strict :: Text -> Maybe BS.ByteString
decodeBase64Strict encoded
  | T.length encoded `mod` 4 /= 0 = Nothing
  | otherwise = BS.pack . concat <$> traverse decodeQuad (chunksOf4 (T.unpack encoded))
 where
  decodeQuad [a, b, '=', '='] = do
    first <- base64Digit a
    second <- base64Digit b
    if second .&. 0x0f == 0
      then pure [fromIntegral ((first `shiftL` 2) .|. (second `shiftR` 4))]
      else Nothing
  decodeQuad [a, b, c, '='] = do
    first <- base64Digit a
    second <- base64Digit b
    third <- base64Digit c
    if third .&. 0x03 == 0
      then
        pure
          [ fromIntegral ((first `shiftL` 2) .|. (second `shiftR` 4))
          , fromIntegral (((second .&. 0x0f) `shiftL` 4) .|. (third `shiftR` 2))
          ]
      else Nothing
  decodeQuad [a, b, c, d] = do
    first <- base64Digit a
    second <- base64Digit b
    third <- base64Digit c
    fourth <- base64Digit d
    pure
      [ fromIntegral ((first `shiftL` 2) .|. (second `shiftR` 4))
      , fromIntegral (((second .&. 0x0f) `shiftL` 4) .|. (third `shiftR` 2))
      , fromIntegral (((third .&. 0x03) `shiftL` 6) .|. fourth)
      ]
  decodeQuad _ = Nothing

  base64Digit character
    | character >= 'A' && character <= 'Z' = Just (ord character - ord 'A')
    | character >= 'a' && character <= 'z' = Just (26 + ord character - ord 'a')
    | character >= '0' && character <= '9' = Just (52 + ord character - ord '0')
    | character == '+' = Just 62
    | character == '/' = Just 63
    | otherwise = Nothing

  chunksOf4 [] = []
  chunksOf4 values = take 4 values : chunksOf4 (drop 4 values)

ascii85Encode :: BS.ByteString -> Text
ascii85Encode = T.pack . go . BS.unpack
 where
  go [] = []
  go values =
    let (group, rest) = splitAt 4 values
        padded = group <> replicate (4 - length group) 0
        encoded = encodeGroup padded
        emitted
          | length group == 4 && all (== 0) group = "z"
          | length group == 4 = encoded
          | otherwise = take (length group + 1) encoded
     in emitted <> go rest

  encodeGroup [a, b, c, d] =
    let value =
          fromIntegral a `shiftL` 24
            .|. fromIntegral b `shiftL` 16
            .|. fromIntegral c `shiftL` 8
            .|. fromIntegral d :: Integer
        digits = reverse (take 5 (unfold85 value <> repeat 0))
     in map (chr . (+ 33) . fromIntegral) digits
  encodeGroup _ = []
  unfold85 0 = []
  unfold85 value = value `mod` 85 : unfold85 (value `div` 85)

ascii85Decode :: Text -> Maybe BS.ByteString
ascii85Decode source = BS.pack . concat <$> gather [] [] (T.unpack source)
 where
  gather groups pending [] = do
    final <- decodePartial pending
    pure (reverse groups <> [final | not (null final)])
  gather groups [] ('z' : rest) = gather ([0, 0, 0, 0] : groups) [] rest
  gather _ pending ('z' : _) | not (null pending) = Nothing
  gather groups pending (character : rest)
    | character < '!' || character > 'u' = gather groups pending rest
    | length next == 5 = do
        decoded <- decode85Group next
        gather (decoded : groups) [] rest
    | otherwise = gather groups next rest
   where
    next = pending <> [character]

  decodePartial [] = Just []
  decodePartial [_] = Nothing
  decodePartial pending = do
    decoded <- decode85Group (pending <> replicate (5 - length pending) 'u')
    pure (take (length pending - 1) decoded)

  decode85Group characters = do
    digits <- traverse (\c -> if c >= '!' && c <= 'u' then Just (ord c - 33) else Nothing) characters
    let value = foldl' (\total digitValue -> total * 85 + fromIntegral digitValue) 0 digits :: Integer
    if value > 0xffffffff
      then Nothing
      else
        Just
          [ fromIntegral (value `shiftR` 24)
          , fromIntegral (value `shiftR` 16)
          , fromIntegral (value `shiftR` 8)
          , fromIntegral value
          ]

-- Textual expression forms -------------------------------------------------

data TextForm
  = CForm
  | FortranForm
  | InputForm
  | MathMLForm
  | OutputForm
  | StandardForm
  | TextForm
  | TeXForm
  | TraditionalForm
  deriving (Eq, Show)

formName :: TextForm -> Text
formName = T.pack . show

normalizeTextForm :: Text -> Bool -> Maybe Expr -> Either Text TextForm
normalizeTextForm operation renderPurpose formExpression = do
  normalized <- case formExpression of
    Nothing -> Right InputForm
    Just (Symbol value) -> fromName value
    Just (String value) -> fromName value
    Just _ -> Left (operation <> " expects a supported expression form specification.")
  if renderPurpose || normalized `elem` [InputForm, StandardForm, TraditionalForm, TeXForm, MathMLForm]
    then Right normalized
    else Left (operation <> " does not support this expression form.")
 where
  fromName raw = case T.toLower (T.strip (shortSystemName raw)) of
    "c" -> Right CForm
    "cform" -> Right CForm
    "fortran" -> Right FortranForm
    "fortranform" -> Right FortranForm
    "input" -> Right InputForm
    "inputform" -> Right InputForm
    "mathml" -> Right MathMLForm
    "mathmlform" -> Right MathMLForm
    "output" -> Right OutputForm
    "outputform" -> Right OutputForm
    "standard" -> Right StandardForm
    "standardform" -> Right StandardForm
    "text" -> Right TextForm
    "textform" -> Right TextForm
    "tex" -> Right TeXForm
    "texform" -> Right TeXForm
    "traditional" -> Right TraditionalForm
    "traditionalform" -> Right TraditionalForm
    _ -> Left (operation <> " does not support this expression form.")

normalizeBoxForm :: Text -> Maybe Expr -> Either Text TextForm
normalizeBoxForm operation formExpression = do
  form <- maybe (Right StandardForm) (normalizeTextForm operation False . Just) formExpression
  if form `elem` [InputForm, StandardForm, TraditionalForm]
    then Right form
    else Left (operation <> " supports InputForm, StandardForm, and TraditionalForm as box forms.")

toStringExpr :: [Expr] -> Conversion
toStringExpr values = do
  let (positional, options) = splitTrailingOptions values
      formatType = optionValue "FormatType" options
  case positional of
    [expression] -> render expression (formatType >>= Just)
    [expression, explicitForm] -> render expression (Just explicitForm)
    _ -> Left "ToString expects an expression, an optional supported form specifier, and options."
 where
  render expression requestedForm = do
    form <- case requestedForm of
      Nothing -> Right OutputForm
      Just formExpression -> normalizeTextForm "ToString" True (Just formExpression)
    let text = renderTextualForm form expression
        stripped = case optionValue "NumberMarks" (snd (splitTrailingOptions values)) of
          Just (Symbol name) | shortSystemName name == "False" -> stripNumberMarks text
          _ -> text
    encoded <- encodeToStringOptions stripped (snd (splitTrailingOptions values))
    Right (String encoded)

splitTrailingOptions :: [Expr] -> ([Expr], [Expr])
splitTrailingOptions = go [] . reverse
 where
  go options (value : rest)
    | isOptionRule value = go (value : options) rest
  go options rest = (reverse rest, options)
  isOptionRule = \case
    Call (Symbol name) [Symbol _, _] -> shortSystemName name `elem` ["Rule", "RuleDelayed"]
    _ -> False

optionValue :: Text -> [Expr] -> Maybe Expr
optionValue target = foldl' choose Nothing
 where
  choose current = \case
    Call (Symbol ruleHead) [Symbol name, value]
      | shortSystemName ruleHead `elem` ["Rule", "RuleDelayed"]
      , shortSystemName name == target -> Just value
    _ -> current

encodeToStringOptions :: Text -> [Expr] -> Either Text Text
encodeToStringOptions source options = case optionValue "CharacterEncoding" options of
  Nothing -> Right source
  Just (String raw) -> case T.toLower (T.strip raw) of
    "unicode" -> Right source
    "printableascii" -> Right (encodePrintableAscii source)
    "ascii" -> Right (encodePrintableAscii source)
    "us-ascii" -> Right (encodePrintableAscii source)
    "utf-8" -> Right (rawBytesText (TE.encodeUtf8 source))
    "utf8" -> Right (rawBytesText (TE.encodeUtf8 source))
    _ -> Left "ToString currently supports Unicode, PrintableASCII, UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ASCII, WindowsANSI, ISO8859-1, and ISO8859-15."
  Just _ -> Left "ToString expects the encoding name to be a string."

stripNumberMarks :: Text -> Text
stripNumberMarks = T.pack . go . T.unpack
 where
  go [] = []
  go ('`' : rest) = go (dropWhile (\c -> isDigit c || c == '.') rest)
  go (character : rest) = character : go rest

renderTextualForm :: TextForm -> Expr -> Text
renderTextualForm form expression =
  case displayWrapper expression of
    Just (wrapperName, payload)
      | form == OutputForm -> renderDisplayWrapper wrapperName payload
    _ -> case form of
      InputForm -> textualInputForm expression
      StandardForm -> textualInputForm expression
      OutputForm -> outputFormText expression
      TextForm -> outputFormText expression
      CForm -> cLikeText False expression
      FortranForm -> cLikeText True expression
      TraditionalForm -> "\\!\\(\\*" <> inputForm (Call (Symbol "FormBox") [makeBoxes TraditionalForm expression, Symbol "TraditionalForm"]) <> "\\)"
      TeXForm -> texText expression
      MathMLForm -> mathMlFormText False expression

displayWrapper :: Expr -> Maybe (Text, Expr)
displayWrapper = \case
  Call (Symbol name) (payload : _)
    | shortSystemName name
        `elem` [ "InputForm", "FullForm", "OutputForm", "StandardForm", "TraditionalForm"
               , "TeXForm", "MathMLForm", "CForm", "FortranForm", "TextForm"
               ] -> Just (shortSystemName name, payload)
  _ -> Nothing

renderDisplayWrapper :: Text -> Expr -> Text
renderDisplayWrapper wrapperName payload = case wrapperName of
  "InputForm" -> textualInputForm payload
  "FullForm" -> fullForm payload
  "OutputForm" -> outputFormText payload
  "StandardForm" -> textualInputForm payload
  "TraditionalForm" -> renderTextualForm TraditionalForm payload
  "TeXForm" -> texText payload
  "MathMLForm" -> mathMlFormText True payload
  "CForm" -> cLikeText False payload
  "FortranForm" -> cLikeText True payload
  "TextForm" -> outputFormText payload
  _ -> inputForm payload

mathMlFormText :: Bool -> Expr -> Text
mathMlFormText includeFinalNewline expression =
  "<math>\n " <> mathMlText expression <> "\n</math>" <> if includeFinalNewline then "\n" else ""

textualInputForm :: Expr -> Text
textualInputForm expression = case expression of
  Call (Symbol name) values
    | Just (wlOperator, _, _) <- namedInfixOperator (shortSystemName name)
    , length values >= 2 -> T.intercalate (" " <> wlOperator <> " ") (map textualInputForm values)
  _ -> inputForm expression

outputFormText :: Expr -> Text
outputFormText = inputForm

cLikeText :: Bool -> Expr -> Text
cLikeText fortran = go
 where
  go expression = case expression of
    Symbol name -> shortSystemName name
    Integer value -> T.pack (show value)
    Rational numerator denominator ->
      "(" <> T.pack (show numerator) <> (if fortran then ".0/" else "/") <> T.pack (show denominator) <> ")"
    Real source -> source
    SpecialReal kind -> specialRealName kind
    String source -> wlString source
    Call (Symbol name) values -> case (shortSystemName name, values) of
      ("Plus", operands) -> T.intercalate "+" (map go operands)
      ("Times", operands) -> T.intercalate "*" (map go operands)
      ("Power", [base, powerValue])
        | fortran -> go base <> "**" <> go powerValue
        | otherwise -> "Power(" <> go base <> "," <> go powerValue <> ")"
      (headName, operands) -> headName <> "(" <> T.intercalate "," (map go operands) <> ")"
    _ -> inputForm expression

texText :: Expr -> Text
texText = \case
  Symbol name -> texSymbol (shortSystemName name)
  Integer value -> T.pack (show value)
  Rational numerator denominator -> "\\frac{" <> T.pack (show numerator) <> "}{" <> T.pack (show denominator) <> "}"
  Real source -> source
  SpecialReal kind -> specialRealName kind
  String source -> "\\text{" <> source <> "}"
  Call (Symbol name) values -> case (shortSystemName name, values) of
    (headName, operands)
      | Just (_, texOperator, _) <- namedInfixOperator headName
      , length operands >= 2 -> T.intercalate ("" <> texOperator <> " ") (map texText operands)
    ("List", operands) -> "\\{" <> T.intercalate ", " (map texText operands) <> "\\}"
    ("Plus", operands) -> T.intercalate "+" (map texText (traditionalPlusArguments operands))
    ("Times", operands) -> T.intercalate " " (map texText operands)
    ("Power", [base, Rational 1 2]) -> "\\sqrt{" <> texText base <> "}"
    ("Power", [base, powerValue]) -> texPowerBase base <> "^{" <> texText powerValue <> "}"
    ("Rule", [left, right]) -> texText left <> "\\to " <> texText right
    (headName, operands) -> texSymbol headName <> "[" <> T.intercalate "," (map texText operands) <> "]"
  expression -> inputForm expression
 where
  texSymbol "Pi" = "\\pi"
  texSymbol "Infinity" = "\\infty"
  texSymbol name = name
  texPowerBase value@Symbol {} = texText value
  texPowerBase value@Integer {} = texText value
  texPowerBase value@Real {} = texText value
  texPowerBase value = "\\left(" <> texText value <> "\\right)"

mathMlText :: Expr -> Text
mathMlText = \case
  Symbol name -> "<mi>" <> xmlEscape (shortSystemName name) <> "</mi>"
  Integer value -> "<mn>" <> T.pack (show value) <> "</mn>"
  Rational numerator denominator ->
    "<mfrac><mn>" <> T.pack (show numerator) <> "</mn><mn>" <> T.pack (show denominator) <> "</mn></mfrac>"
  Real source -> "<mn>" <> xmlEscape source <> "</mn>"
  SpecialReal kind -> "<mi>" <> specialRealName kind <> "</mi>"
  String source -> "<mtext>" <> xmlEscape source <> "</mtext>"
  Call (Symbol name) values -> case (shortSystemName name, values) of
    (headName, operands)
      | Just (_, _, entity) <- namedInfixOperator headName
      , length operands >= 2 -> rowWith ("<mo>" <> entity <> "</mo>") (map mathMlText operands)
    ("Plus", operands) -> rowWith "<mo>+</mo>" (map mathMlText (traditionalPlusArguments operands))
    ("Times", operands) -> rowWith "<mo>&#8289;</mo>" (map mathMlText operands)
    ("Power", [base, Rational 1 2]) -> "<msqrt>" <> mathMlText base <> "</msqrt>"
    ("Power", [base, powerValue]) -> "<msup>" <> mathMlText base <> mathMlText powerValue <> "</msup>"
    ("List", operands) -> "<mrow><mo>{</mo>" <> rowWith "<mo>,</mo>" (map mathMlText operands) <> "<mo>}</mo></mrow>"
    (headName, operands) ->
      "<mrow><mi>" <> xmlEscape headName <> "</mi><mo>[</mo>"
        <> rowWith "<mo>,</mo>" (map mathMlText operands)
        <> "<mo>]</mo></mrow>"
  expression -> "<mtext>" <> xmlEscape (inputForm expression) <> "</mtext>"
 where
  rowWith separator pieces = "<mrow>" <> T.intercalate separator pieces <> "</mrow>"

xmlEscape :: Text -> Text
xmlEscape =
  T.replace "\"" "&quot;"
    . T.replace ">" "&gt;"
    . T.replace "<" "&lt;"
    . T.replace "&" "&amp;"

traditionalPlusArguments :: [Expr] -> [Expr]
traditionalPlusArguments values =
  let (numeric, other) = partition isNumericAtom values
   in other <> numeric
 where
  isNumericAtom Integer {} = True
  isNumericAtom Rational {} = True
  isNumericAtom Real {} = True
  isNumericAtom SpecialReal {} = True
  isNumericAtom _ = False

namedInfixOperator :: Text -> Maybe (Text, Text, Text)
namedInfixOperator = \case
  "CirclePlus" -> Just ("\\[CirclePlus]", "\\oplus", "&#8853;")
  "CircleTimes" -> Just ("\\[CircleTimes]", "\\otimes", "&#8855;")
  "Diamond" -> Just ("\\[Diamond]", "\\diamond", "&#8900;")
  _ -> Nothing

-- Boxes --------------------------------------------------------------------

toBoxesExpr :: [Expr] -> Conversion
toBoxesExpr values = case values of
  [expression] -> Right (makeBoxes StandardForm expression)
  [expression, formExpression] -> do
    form <- normalizeBoxForm "ToBoxes" (Just formExpression)
    let boxes = makeBoxes form expression
    Right (if form == TraditionalForm then Call (Symbol "FormBox") [boxes, Symbol "TraditionalForm"] else boxes)
  _ -> Left "ToBoxes expects an expression and an optional form."

makeBoxesExpr :: [Expr] -> Conversion
makeBoxesExpr values = case values of
  [expression] -> Right (makeBoxes StandardForm expression)
  [expression, formExpression] -> do
    form <- normalizeBoxForm "MakeBoxes" (Just formExpression)
    Right (makeBoxes form expression)
  _ -> Left "MakeBoxes expects an expression and an optional form."

makeBoxes :: TextForm -> Expr -> Expr
makeBoxes form expression
  | form == InputForm = String (inputForm expression)
  | form == TraditionalForm = makeTraditionalBoxes expression
  | otherwise = makeStandardBoxes expression

makeStandardBoxes :: Expr -> Expr
makeStandardBoxes expression = case displayWrapper expression of
  Just (wrapperName, payload) -> displayBoxes wrapperName payload expression
  Nothing -> case expression of
    Symbol name -> String (inputForm (Symbol name))
    Integer value -> String (T.pack (show value))
    Rational numerator denominator ->
      Call (Symbol "FractionBox") [String (T.pack (show numerator)), String (T.pack (show denominator))]
    Real source -> String source
    SpecialReal kind -> makeStandardBoxes (Call (Symbol (specialRealName kind)) [])
    Complex realPart imaginaryPart -> makeStandardBoxes (Call (Symbol "Complex") [realPart, imaginaryPart])
    String source -> String (wlString source)
    ByteArray bytes -> makeStandardBoxes (Call (Symbol "ByteArray") [Call (Symbol "List") (map (Integer . fromIntegral) (BS.unpack bytes))])
    Call (Symbol name) values -> standardCallBoxes (shortSystemName name) values
    Call expressionHead values -> genericCallBoxes makeStandardBoxes expressionHead values
    _ -> String (inputForm expression)

makeTraditionalBoxes :: Expr -> Expr
makeTraditionalBoxes expression = case expression of
  Call (Symbol name) [payload]
    | shortSystemName name == "TraditionalForm" -> makeTraditionalBoxes payload
    | shortSystemName name == "StandardForm" -> makeStandardBoxes payload
  Symbol {} -> makeStandardBoxes expression
  Integer {} -> makeStandardBoxes expression
  Rational numerator denominator ->
    Call (Symbol "FractionBox") [makeTraditionalBoxes (Integer numerator), makeTraditionalBoxes (Integer denominator)]
  Real {} -> makeStandardBoxes expression
  SpecialReal {} -> makeStandardBoxes expression
  String {} -> makeStandardBoxes expression
  ByteArray {} -> makeStandardBoxes expression
  Complex realPart imaginaryPart -> makeTraditionalBoxes (Call (Symbol "Complex") [realPart, imaginaryPart])
  Call (Symbol name) values -> traditionalCallBoxes (shortSystemName name) values
  Call expressionHead values -> genericCallBoxes makeTraditionalBoxes expressionHead values
  _ -> String (inputForm expression)

standardCallBoxes :: Text -> [Expr] -> Expr
standardCallBoxes name values = case (name, values) of
  (headName, operands)
    | Just (operator, _, _) <- namedInfixOperator headName
    , length operands >= 2 -> separatedBoxes makeStandardBoxes operator operands
  ("List", operands) -> bracketedBoxes makeStandardBoxes "{" operands "}"
  ("Association", operands) -> bracketedBoxes makeStandardBoxes "<|" operands "|>"
  ("Rule", [left, right]) -> rowBox [makeStandardBoxes left, String "->", makeStandardBoxes right]
  ("RuleDelayed", [left, right]) -> rowBox [makeStandardBoxes left, String ":>", makeStandardBoxes right]
  ("Plus", operands@(_ : _ : _)) -> separatedBoxes makeStandardBoxes "+" operands
  ("Times", operands@(_ : _ : _)) -> separatedBoxes makeStandardBoxes " " operands
  ("Power", [base, Integer (-1)]) -> Call (Symbol "FractionBox") [String "1", makeStandardBoxes base]
  ("Power", [base, powerValue]) -> Call (Symbol "SuperscriptBox") [makeStandardBoxes base, makeStandardBoxes powerValue]
  ("Subscript", [base, subscript]) -> Call (Symbol "SubscriptBox") [makeStandardBoxes base, makeStandardBoxes subscript]
  ("Subsuperscript", [base, subscript, superscript]) -> Call (Symbol "SubsuperscriptBox") (map makeStandardBoxes [base, subscript, superscript])
  ("Overscript", [base, over]) -> Call (Symbol "OverscriptBox") (map makeStandardBoxes [base, over])
  ("Underscript", [base, under]) -> Call (Symbol "UnderscriptBox") (map makeStandardBoxes [base, under])
  ("Underoverscript", [base, under, over]) -> Call (Symbol "UnderoverscriptBox") (map makeStandardBoxes [base, under, over])
  _ -> genericCallBoxes makeStandardBoxes (Symbol name) values

traditionalCallBoxes :: Text -> [Expr] -> Expr
traditionalCallBoxes name values = case (name, values) of
  (headName, operands)
    | Just (operator, _, _) <- namedInfixOperator headName
    , length operands >= 2 -> separatedBoxes makeTraditionalBoxes operator operands
  ("List", operands) -> bracketedBoxes makeTraditionalBoxes "{" operands "}"
  ("Association", operands) -> bracketedBoxes makeTraditionalBoxes "<|" operands "|>"
  ("Rule", [left, right]) -> rowBox [makeTraditionalBoxes left, String "->", makeTraditionalBoxes right]
  ("RuleDelayed", [left, right]) -> rowBox [makeTraditionalBoxes left, String ":>", makeTraditionalBoxes right]
  ("Plus", operands) | length operands >= 2 -> separatedBoxes makeTraditionalBoxes "+" (traditionalPlusArguments operands)
  ("Times", operands) | length operands >= 2 -> separatedBoxes makeTraditionalBoxes " " operands
  ("Power", [base, Integer (-1)]) -> Call (Symbol "FractionBox") [String "1", makeTraditionalBoxes base]
  ("Power", [base, Rational 1 2]) -> Call (Symbol "SqrtBox") [makeTraditionalBoxes base]
  ("Power", [base, powerValue]) -> Call (Symbol "SuperscriptBox") [makeTraditionalBoxes base, makeTraditionalBoxes powerValue]
  ("Subscript", [base, subscript]) -> Call (Symbol "SubscriptBox") [makeTraditionalBoxes base, makeTraditionalBoxes subscript]
  ("Subsuperscript", [base, subscript, superscript]) -> Call (Symbol "SubsuperscriptBox") (map makeTraditionalBoxes [base, subscript, superscript])
  _ -> genericCallBoxes makeTraditionalBoxes (Symbol name) values

rowBox :: [Expr] -> Expr
rowBox items = Call (Symbol "RowBox") [Call (Symbol "List") items]

separatedBoxes :: (Expr -> Expr) -> Text -> [Expr] -> Expr
separatedBoxes box separator values =
  rowBox (concat (zipWith (\index value -> [String separator | index > (0 :: Int)] <> [box value]) [0 ..] values))

bracketedBoxes :: (Expr -> Expr) -> Text -> [Expr] -> Text -> Expr
bracketedBoxes box opening values closing =
  rowBox ([String opening] <> middle <> [String closing])
 where
  middle
    | null values = [String ""]
    | otherwise = [separatedBoxes box "," values]

genericCallBoxes :: (Expr -> Expr) -> Expr -> [Expr] -> Expr
genericCallBoxes box expressionHead values =
  rowBox ([box expressionHead, String "["] <> middle <> [String "]"])
 where
  middle
    | null values = [String ""]
    | otherwise = [separatedBoxes box "," values]

displayBoxes :: Text -> Expr -> Expr -> Expr
displayBoxes wrapperName payload original = case wrapperName of
  "InputForm" ->
    Call (Symbol "InterpretationBox")
      [ Call (Symbol "StyleBox")
          [ String (inputForm payload)
          , ruleOption "ShowStringCharacters" (Symbol "True")
          , ruleOption "NumberMarks" (Symbol "True")
          ]
      , original
      , ruleOption "Editable" (Symbol "True")
      , ruleOption "AutoDelete" (Symbol "True")
      ]
  "FullForm" ->
    Call (Symbol "TagBox")
      [ Call (Symbol "StyleBox")
          [ makeFullFormBoxes payload
          , ruleOption "ShowSpecialCharacters" (Symbol "False")
          , ruleOption "ShowStringCharacters" (Symbol "True")
          , ruleOption "NumberMarks" (Symbol "True")
          ]
      , Symbol "FullForm"
      ]
  "OutputForm" ->
    Call (Symbol "InterpretationBox")
      [ Call (Symbol "PaneBox") [String (inputForm payload), ruleOption "BaselinePosition" (Symbol "Baseline")]
      , payload
      , ruleOption "Editable" (Symbol "False")
      ]
  "StandardForm" ->
    Call (Symbol "TagBox")
      [ Call (Symbol "FormBox") [makeStandardBoxes payload, Symbol "StandardForm"]
      , Symbol "StandardForm"
      , ruleOption "Editable" (Symbol "True")
      ]
  "TraditionalForm" ->
    Call (Symbol "TagBox")
      [ Call (Symbol "FormBox") [makeTraditionalBoxes payload, Symbol "TraditionalForm"]
      , Symbol "TraditionalForm"
      , ruleOption "Editable" (Symbol "True")
      ]
  "TeXForm" -> textualInterpretationBox (wlString (texText payload)) payload
  "MathMLForm" -> textualInterpretationBox (wlString (renderTextualForm MathMLForm payload)) payload
  "CForm" -> textualInterpretationBox (cLikeText False payload) original
  "FortranForm" -> textualInterpretationBox (cLikeText True payload) original
  "TextForm" -> textualInterpretationBox (outputFormText payload) original
  _ -> makeStandardBoxes original

textualInterpretationBox :: Text -> Expr -> Expr
textualInterpretationBox source semantic =
  Call (Symbol "InterpretationBox")
    [ String source
    , semantic
    , ruleOption "Editable" (Symbol "True")
    , ruleOption "AutoDelete" (Symbol "True")
    ]

makeFullFormBoxes :: Expr -> Expr
makeFullFormBoxes = \case
  Rational numerator denominator -> makeFullFormBoxes (Call (Symbol "Rational") [Integer numerator, Integer denominator])
  SpecialReal kind -> makeFullFormBoxes (Call (Symbol (specialRealName kind)) [])
  Complex realPart imaginaryPart -> makeFullFormBoxes (Call (Symbol "Complex") [realPart, imaginaryPart])
  ByteArray values -> makeFullFormBoxes (Call (Symbol "ByteArray") [String (base64Encode values)])
  Call expressionHead values -> genericCallBoxes makeFullFormBoxes expressionHead values
  expression -> String (fullForm expression)

makeExpressionExpr :: [Expr] -> Conversion
makeExpressionExpr values = case values of
  [boxExpression] -> holdComplete <$> parseExpressionInput "MakeExpression" StandardForm boxExpression
  [boxExpression, formExpression] -> do
    form <- normalizeTextForm "MakeExpression" False (Just formExpression)
    holdComplete <$> parseExpressionInput "MakeExpression" form boxExpression
  _ -> Left "MakeExpression expects boxes and an optional form."
 where
  holdComplete expression = Call (Symbol "HoldComplete") [expression]

toExpressionExpr :: [Expr] -> Conversion
toExpressionExpr values = case values of
  [inputExpression] -> convert inputExpression Nothing Nothing
  [inputExpression, formExpression] -> convert inputExpression (Just formExpression) Nothing
  [inputExpression, formExpression, wrapper] -> convert inputExpression (Just formExpression) (Just wrapper)
  _ -> Left "ToExpression expects input, an optional supported form specifier, and an optional wrapper head."
 where
  convert inputExpression requestedForm wrapper = case listItems inputExpression of
    Just items -> Call (Symbol "List") <$> traverse (\item -> convert item requestedForm wrapper) items
    Nothing -> do
      form <-
        if requestedForm == Nothing && looksLikeBoxes inputExpression
          then Right StandardForm
          else normalizeTextForm "ToExpression" False requestedForm
      parsed <- parseExpressionInput "ToExpression" form inputExpression
      Right (maybe parsed (\headExpression -> Call headExpression [parsed]) wrapper)

parseExpressionInput :: Text -> TextForm -> Expr -> Conversion
parseExpressionInput operation form inputExpression =
  case inputExpression of
    String source -> parseText source
    _ | form `elem` [StandardForm, TraditionalForm] && looksLikeBoxes inputExpression ->
      firstText (operation <> " could not parse the input as " <> formName form <> ".") (interpretBoxes inputExpression)
    _ -> Left (operation <> " expects a string or a supported box expression.")
 where
  parseText source =
    let parsedSpecial = case form of
          TeXForm -> parseTexSpecial source
          MathMLForm -> parseMathMlDocument source `orMaybe` parseNamedMathMl source
          _ -> Nothing
        normalized = case form of
          TraditionalForm -> traditionalSource source
          TeXForm -> texSource source
          MathMLForm -> mathMlSource source
          _ -> source
     in case parsedSpecial of
          Just parsed -> Right parsed
          Nothing ->
            firstText
              (operation <> " could not parse the input as " <> formName form <> ".")
              (parseInputForm normalized)

  firstText message = either (const (Left message)) Right

traditionalSource :: Text -> Text
traditionalSource source =
  case T.stripPrefix "\\!\\(\\*" (T.strip source) >>= T.stripSuffix "\\)" of
    Nothing -> source
    Just boxSource ->
      case parseInputForm boxSource of
        Left _ -> source
        Right boxes -> case interpretBoxes boxes of
          Left _ -> source
          Right parsed -> inputForm parsed

texSource :: Text -> Text
texSource source =
  let roots = replaceTexRoots source
      fractions = replaceTexFractions roots
      grouping = T.replace "\\right" "" (T.replace "\\left" "" fractions)
      symbols = T.replace "\\infty" "Infinity" (T.replace "\\pi" "Pi" grouping)
      operators =
        T.replace "\\diamond" "Diamond"
          (T.replace "\\otimes" "CircleTimes" (T.replace "\\oplus" "CirclePlus" (T.replace "\\to" "->" symbols)))
      superscripts = replaceTexSuperscripts operators
   in T.replace "\\}" "}" (T.replace "\\{" "{" superscripts)

replaceTexSuperscripts :: Text -> Text
replaceTexSuperscripts source =
  let (before, rest) = T.breakOn "^{" source
   in case T.stripPrefix "^" rest >>= extractBraceGroup of
        Nothing -> source
        Just (powerValue, after) ->
          before <> "^(" <> texSource powerValue <> ")" <> replaceTexSuperscripts after

parseNamedTeX :: Text -> Maybe Expr
parseNamedTeX source = firstMatch namedOperators
 where
  namedOperators = [("\\oplus", "CirclePlus"), ("\\otimes", "CircleTimes"), ("\\diamond", "Diamond")]
  firstMatch [] = Nothing
  firstMatch ((token, headName) : rest) =
    let pieces = map T.strip (T.splitOn token source)
     in if length pieces >= 2
          then Call (Symbol headName) <$> traverse parsePiece pieces
          else firstMatch rest
  parsePiece piece = either (const Nothing) Just (parseInputForm (texSource piece))

parseTexSpecial :: Text -> Maybe Expr
parseTexSpecial source =
  parseNamedTeX source
    `orMaybe` parseFraction
    `orMaybe` parseSquareRoot
 where
  parseFraction = do
    (before, [numeratorSource, denominatorSource], after) <- extractTexCommand "\\frac" 2 (T.strip source)
    if T.null (T.strip before) && T.null (T.strip after)
      then do
        numerator <- parseTexOperand numeratorSource
        denominator <- parseTexOperand denominatorSource
        pure (Call (Symbol "Times") [numerator, Call (Symbol "Power") [denominator, Integer (-1)]])
      else Nothing
  parseSquareRoot = do
    (before, [radicandSource], after) <- extractTexCommand "\\sqrt" 1 (T.strip source)
    if T.null (T.strip before) && T.null (T.strip after)
      then do
        radicand <- parseTexOperand radicandSource
        pure
          ( Call
              (Symbol "Power")
              [ radicand
              , Call (Symbol "Times") [Integer 1, Call (Symbol "Power") [Integer 2, Integer (-1)]]
              ]
          )
      else Nothing
  parseTexOperand value =
    parseTexSpecial value
      `orMaybe` either (const Nothing) Just (parseInputForm (texSource value))

replaceTexFractions :: Text -> Text
replaceTexFractions source = maybe source replaceOne (extractTexCommand "\\frac" 2 source)
 where
  replaceOne (before, [numerator, denominator], after) =
    replaceTexFractions (before <> "((" <> texSource numerator <> ")/(" <> texSource denominator <> "))" <> after)
  replaceOne _ = source

replaceTexRoots :: Text -> Text
replaceTexRoots source = maybe source replaceOne (extractTexCommand "\\sqrt" 1 source)
 where
  replaceOne (before, [radicand], after) =
    replaceTexRoots (before <> "((" <> texSource radicand <> ")^(1/2))" <> after)
  replaceOne _ = source

extractTexCommand :: Text -> Int -> Text -> Maybe (Text, [Text], Text)
extractTexCommand command arity source = do
  let (before, rest) = T.breakOn command source
  afterCommand <- T.stripPrefix command rest
  (groups, after) <- extractGroups arity afterCommand
  pure (before, groups, after)
 where
  extractGroups 0 text = Just ([], text)
  extractGroups remaining text = do
    (group, after) <- extractBraceGroup (T.stripStart text)
    (following, final) <- extractGroups (remaining - 1) after
    pure (group : following, final)

extractBraceGroup :: Text -> Maybe (Text, Text)
extractBraceGroup source = do
  rest <- T.stripPrefix "{" source
  gather 1 [] (T.unpack rest)
 where
  gather :: Int -> [Char] -> [Char] -> Maybe (Text, Text)
  gather _ _ [] = Nothing
  gather depth retained (character : remaining)
    | character == '{' = gather (depth + 1) (character : retained) remaining
    | character == '}' && depth == 1 = Just (T.pack (reverse retained), T.pack remaining)
    | character == '}' = gather (depth - 1) (character : retained) remaining
    | otherwise = gather depth (character : retained) remaining

mathMlSource :: Text -> Text
mathMlSource =
  T.replace "<mo>&#8900;</mo>" " \\[Diamond] "
    . T.replace "<mo>&#8855;</mo>" " \\[CircleTimes] "
    . T.replace "<mo>&#8853;</mo>" " \\[CirclePlus] "
    . T.replace "</mrow>" ""
    . T.replace "<mrow>" ""
    . T.replace "</math>" ""
    . T.replace "<math>" ""
    . T.replace "<mo>&#8289;</mo>" "*"
    . T.replace "<mo>+</mo>" "+"
    . T.replace "<mo>,</mo>" ","
    . T.replace "<mo>[</mo>" "["
    . T.replace "<mo>]</mo>" "]"
    . T.replace "<mo>{</mo>" "{"
    . T.replace "<mo>}</mo>" "}"
    . stripXmlTag "mi"
    . stripXmlTag "mn"
    . stripXmlTag "mtext"

data MathMlPart = MathMlExpression !Expr | MathMlOperator !Text
  deriving (Eq, Show)

parseMathMlDocument :: Text -> Maybe Expr
parseMathMlDocument source = do
  afterOpen <- T.stripPrefix "<math>" (T.strip source)
  (expression, remaining) <- parseMathMlNode afterOpen
  _ <- T.stripPrefix "</math>" (T.strip remaining)
  pure expression

parseMathMlNode :: Text -> Maybe (Expr, Text)
parseMathMlNode rawSource =
  let source = T.stripStart rawSource
   in parseAtomTag "mi" Symbol source
        `orMaybe` parseAtomTag "mn" parseMathNumber source
        `orMaybe` parseAtomTag "mtext" String source
        `orMaybe` parseContainer source
 where
  parseAtomTag tag constructor source = do
    afterOpen <- T.stripPrefix ("<" <> tag <> ">") source
    let (content, closing) = T.breakOn ("</" <> tag <> ">") afterOpen
    remaining <- T.stripPrefix ("</" <> tag <> ">") closing
    pure (constructor (xmlUnescape content), remaining)

  parseMathNumber source =
    either (const (Symbol source)) id (parseInputForm source)

  parseContainer source
    | Just remaining <- T.stripPrefix "<msup>" source = do
        (base, afterBase) <- parseMathMlNode remaining
        (powerValue, afterPower) <- parseMathMlNode afterBase
        final <- T.stripPrefix "</msup>" (T.stripStart afterPower)
        pure (Call (Symbol "Power") [base, powerValue], final)
    | Just remaining <- T.stripPrefix "<mfrac>" source = do
        (numerator, afterNumerator) <- parseMathMlNode remaining
        (denominator, afterDenominator) <- parseMathMlNode afterNumerator
        final <- T.stripPrefix "</mfrac>" (T.stripStart afterDenominator)
        pure (Call (Symbol "Times") [numerator, Call (Symbol "Power") [denominator, Integer (-1)]], final)
    | Just remaining <- T.stripPrefix "<msqrt>" source = do
        (radicand, afterRadicand) <- parseMathMlNode remaining
        final <- T.stripPrefix "</msqrt>" (T.stripStart afterRadicand)
        pure (Call (Symbol "Power") [radicand, Rational 1 2], final)
    | Just remaining <- T.stripPrefix "<mrow>" source = do
        (parts, final) <- parseMathMlParts remaining
        expression <- combineMathMlParts parts
        pure (expression, final)
    | otherwise = Nothing

parseMathMlParts :: Text -> Maybe ([MathMlPart], Text)
parseMathMlParts rawSource
  | Just remaining <- T.stripPrefix "</mrow>" source = Just ([], remaining)
  | Just afterOpen <- T.stripPrefix "<mo>" source = do
      let (operator, closing) = T.breakOn "</mo>" afterOpen
      afterOperator <- T.stripPrefix "</mo>" closing
      (rest, final) <- parseMathMlParts afterOperator
      pure (MathMlOperator operator : rest, final)
  | otherwise = do
      (expression, afterExpression) <- parseMathMlNode source
      (rest, final) <- parseMathMlParts afterExpression
      pure (MathMlExpression expression : rest, final)
 where
  source = T.stripStart rawSource

combineMathMlParts :: [MathMlPart] -> Maybe Expr
combineMathMlParts [MathMlExpression expression] = Just expression
combineMathMlParts parts
  | Just values <- operandsFor "+" = Just (Call (Symbol "Plus") values)
  | Just values <- operandsFor "&#8289;" = Just (Call (Symbol "Times") values)
  | Just values <- operandsFor "&#8853;" = Just (Call (Symbol "CirclePlus") values)
  | Just values <- operandsFor "&#8855;" = Just (Call (Symbol "CircleTimes") values)
  | Just values <- operandsFor "&#8900;" = Just (Call (Symbol "Diamond") values)
  | otherwise = bracketed parts
 where
  operandsFor operator = traverse partExpression (splitMathMlParts operator parts)
  partExpression [MathMlExpression expression] = Just expression
  partExpression _ = Nothing

  bracketed (MathMlOperator opening : remaining)
    | Just closing <- Map.lookup opening (Map.fromList [("{", "}"), ("[", "]")])
    , Just (inside, MathMlOperator actualClosing) <- unsnoc remaining
    , actualClosing == closing =
        let groups = splitMathMlParts "," inside
         in case traverse partExpression groups of
              Just values | opening == "{" -> Just (Call (Symbol "List") values)
              _ -> Nothing
  bracketed _ = Nothing

splitMathMlParts :: Text -> [MathMlPart] -> [[MathMlPart]]
splitMathMlParts operator = go [[]]
 where
  go groups [] = map reverse (reverse groups)
  go (current : rest) (MathMlOperator value : values)
    | value == operator = go ([] : current : rest) values
  go (current : rest) (value : values) = go ((value : current) : rest) values
  go [] _ = []

unsnoc :: [value] -> Maybe ([value], value)
unsnoc [] = Nothing
unsnoc values = Just (init values, last values)

orMaybe :: Maybe value -> Maybe value -> Maybe value
orMaybe first second = case first of
  Just value -> Just value
  Nothing -> second

xmlUnescape :: Text -> Text
xmlUnescape =
  T.replace "&quot;" "\""
    . T.replace "&gt;" ">"
    . T.replace "&lt;" "<"
    . T.replace "&amp;" "&"

parseNamedMathMl :: Text -> Maybe Expr
parseNamedMathMl source = firstMatch namedOperators
 where
  namedOperators =
    [ ("<mo>&#8853;</mo>", "CirclePlus")
    , ("<mo>&#8855;</mo>", "CircleTimes")
    , ("<mo>&#8900;</mo>", "Diamond")
    ]
  firstMatch [] = Nothing
  firstMatch ((token, headName) : rest) =
    let withoutEnvelope = T.replace "</mrow>" "" (T.replace "<mrow>" "" (T.replace "</math>" "" (T.replace "<math>" "" source)))
        pieces = map T.strip (T.splitOn token withoutEnvelope)
     in if length pieces >= 2
          then Call (Symbol headName) <$> traverse parsePiece pieces
          else firstMatch rest
  parsePiece piece = either (const Nothing) Just (parseInputForm (mathMlSource piece))

stripXmlTag :: Text -> Text -> Text
stripXmlTag tag = T.replace ("</" <> tag <> ">") "" . T.replace ("<" <> tag <> ">") ""

looksLikeBoxes :: Expr -> Bool
looksLikeBoxes = \case
  Call (Symbol name) _ ->
    shortSystemName name
      `elem` [ "AdjustmentBox", "BoxData", "FormBox", "FrameBox", "GridBox"
             , "OverscriptBox", "PaneBox", "StyleBox", "SubscriptBox"
             , "SubsuperscriptBox", "TagBox", "TemplateBox", "TooltipBox"
             , "FractionBox", "InterpretationBox", "RadicalBox", "RowBox"
             , "SqrtBox", "SuperscriptBox", "UnderoverscriptBox", "UnderscriptBox"
             ]
  _ -> False

interpretBoxes :: Expr -> Either Text Expr
interpretBoxes expression = case expression of
  Call (Symbol name) values -> case (shortSystemName name, values) of
    ("InterpretationBox", _visual : semantic : _) -> Right semantic
    ("RowBox", [items])
      | Just rowItems <- listItems items
      , Just parsed <- interpretNamedRow rowItems -> Right parsed
    (wrapper, first : _)
      | wrapper `elem` ["AdjustmentBox", "BoxData", "FormBox", "FrameBox", "PaneBox", "StyleBox", "TagBox", "TooltipBox"] -> interpretBoxes first
    ("SubscriptBox", arguments') -> interpretScriptBox "Subscript" 2 arguments'
    ("SubsuperscriptBox", arguments') -> interpretScriptBox "Subsuperscript" 3 arguments'
    ("OverscriptBox", arguments') -> interpretScriptBox "Overscript" 2 arguments'
    ("UnderscriptBox", arguments') -> interpretScriptBox "Underscript" 2 arguments'
    ("UnderoverscriptBox", arguments') -> interpretScriptBox "Underoverscript" 3 arguments'
    _ -> boxText expression >>= firstText "box parse failure" . parseInputForm
  _ -> Left "unsupported box expression"
 where
  firstText message = either (const (Left message)) Right

interpretScriptBox :: Text -> Int -> [Expr] -> Either Text Expr
interpretScriptBox headName arity values
  | length values < arity = Left (headName <> " box has too few operands")
  | otherwise = Call (Symbol headName) <$> traverse interpretBoxOperand (take arity values)

interpretBoxOperand :: Expr -> Either Text Expr
interpretBoxOperand (String source)
  | T.null (T.strip source) = Right (String source)
  | otherwise = case parseInputForm (T.strip source) of
      Right expression -> Right expression
      Left _ -> Right (String source)
interpretBoxOperand expression
  | looksLikeBoxes expression = interpretBoxes expression
  | otherwise = Right expression

interpretNamedRow :: [Expr] -> Maybe Expr
interpretNamedRow values = firstMatch operators
 where
  operators = [("\\[CirclePlus]", "CirclePlus"), ("\\[CircleTimes]", "CircleTimes"), ("\\[Diamond]", "Diamond")]
  firstMatch [] = Nothing
  firstMatch ((token, headName) : rest) =
    let groups = splitItems token values
     in if length groups >= 2
          then Call (Symbol headName) <$> traverse interpretGroup groups
          else firstMatch rest
  interpretGroup [item] = either (const Nothing) Just (interpretBoxItem item)
  interpretGroup items = either (const Nothing) Just (interpretBoxes (rowBox items))
  interpretBoxItem item@Call {} = interpretBoxes item
  interpretBoxItem (String source) = either (const (Left "box parse failure")) Right (parseInputForm source)
  interpretBoxItem _ = Left "box parse failure"

splitItems :: Text -> [Expr] -> [[Expr]]
splitItems token = go [[]]
 where
  go groups [] = map reverse (reverse groups)
  go (current : rest) (String value : values)
    | value == token = go ([] : current : rest) values
  go (current : rest) (value : values) = go ((value : current) : rest) values
  go [] _ = []

boxText :: Expr -> Either Text Text
boxText = \case
  String source -> Right source
  Call (Symbol name) values -> case (shortSystemName name, values) of
    ("RowBox", [items]) -> maybe (Left "RowBox expects a list") (fmap T.concat . traverse boxText) (listItems items)
    ("FractionBox", [numerator, denominator]) -> binary numerator "/" denominator
    ("SuperscriptBox", [base, powerValue]) -> binary base "^" powerValue
    ("SqrtBox", [radicand]) -> (\text -> "(" <> text <> ")^(1/2)") <$> boxText radicand
    ("SubscriptBox", [base, subscript]) -> callText "Subscript" [base, subscript]
    ("SubsuperscriptBox", [base, subscript, superscript]) -> callText "Subsuperscript" [base, subscript, superscript]
    ("OverscriptBox", [base, over]) -> callText "Overscript" [base, over]
    ("UnderscriptBox", [base, under]) -> callText "Underscript" [base, under]
    ("UnderoverscriptBox", [base, under, over]) -> callText "Underoverscript" [base, under, over]
    (wrapper, first : _)
      | wrapper `elem` ["AdjustmentBox", "BoxData", "FormBox", "FrameBox", "PaneBox", "StyleBox", "TagBox", "TooltipBox"] -> boxText first
    ("InterpretationBox", _visual : semantic : _) -> Right (inputForm semantic)
    _ -> Left "unsupported box expression"
  _ -> Left "unsupported box item"
 where
  binary left operator right = do
    leftText <- boxText left
    rightText <- boxText right
    Right ("(" <> leftText <> ")" <> operator <> "(" <> rightText <> ")")
  callText headName arguments' = do
    rendered <- traverse boxText arguments'
    Right (headName <> "[" <> T.intercalate "," rendered <> "]")

stripBoxesExpr :: [Expr] -> Conversion
stripBoxesExpr = \case
  [boxExpression] -> Right (Call (Symbol "BoxData") [stripBoxExpression boxExpression])
  _ -> Left "StripBoxes expects exactly one box expression."

stripBoxExpression :: Expr -> Expr
stripBoxExpression = \case
  Call (Symbol name) [value]
    | shortSystemName name == "BoxData" -> stripBoxExpression value
  Call (Symbol name) (value : _)
    | shortSystemName name `elem` ["AdjustmentBox", "FormBox", "FrameBox", "PaneBox", "StyleBox", "TooltipBox"] -> stripBoxExpression value
  Call headExpression@(Symbol name) [items]
    | shortSystemName name == "RowBox"
    , Just values <- listItems items ->
        Call headExpression [Call (Symbol "List") (filter (not . nonsemanticBoxToken) (map stripBoxExpression values))]
  Call expressionHead values -> Call (stripBoxExpression expressionHead) (map stripBoxExpression values)
  expression -> expression

nonsemanticBoxToken :: Expr -> Bool
nonsemanticBoxToken = \case
  String source -> T.all isSpace source || source `elem` invisibleTokens
  _ -> False
 where
  invisibleTokens =
    [ "\\[InvisibleSpace]", "\\[NegativeMediumSpace]", "\\[NegativeThickSpace]"
    , "\\[NegativeThinSpace]", "\\[NegativeVeryThinSpace]", "\\[NoBreak]"
    , "\\[ThickSpace]", "\\[ThinSpace]", "\\[VeryThinSpace]"
    ]

syntaxQExpr :: [Expr] -> Conversion
syntaxQExpr values = case values of
  [inputExpression] -> check inputExpression Nothing
  [inputExpression, formExpression] -> check inputExpression (Just formExpression)
  _ -> Left "SyntaxQ expects input and an optional form."
 where
  check inputExpression requestedForm = case inputExpression of
    String source
      | T.null source -> Right (boolean False)
      | otherwise -> do
          form <- normalizeTextForm "SyntaxQ" False requestedForm
          Right (boolean (isRight (parseExpressionInput "SyntaxQ" form inputExpression)))
    _ | looksLikeBoxes inputExpression -> Right (boolean (isRight (interpretBoxes inputExpression)))
    _ -> Left "SyntaxQ expects a string or a supported StandardForm box expression."

syntaxLengthExpr :: [Expr] -> Conversion
syntaxLengthExpr values = case values of
  [inputExpression] -> measure inputExpression Nothing
  [inputExpression, formExpression] -> measure inputExpression (Just formExpression)
  _ -> Left "SyntaxLength expects input and an optional form."
 where
  measure inputExpression requestedForm = case inputExpression of
    String source -> do
      form <- normalizeTextForm "SyntaxLength" False requestedForm
      let parsed = parseExpressionInput "SyntaxLength" form inputExpression
      Right (Integer (fromIntegral (if isRight parsed then T.length source else T.length source + 2)))
    _ | looksLikeBoxes inputExpression -> do
      source <- boxText inputExpression
      let parsed = parseInputForm source
      Right (Integer (fromIntegral (if isRight parsed then T.length source else T.length source + 2)))
    _ -> Left "SyntaxLength expects a string or a supported StandardForm box expression."

isRight :: Either left right -> Bool
isRight (Right _) = True
isRight (Left _) = False

-- In-memory import/export --------------------------------------------------

data FormatSpec = FormatSpec !Text !(Maybe FormatSpec)
  deriving (Eq, Show)

normalizeFormatSpec :: Text -> Expr -> Either Text FormatSpec
normalizeFormatSpec operation = \case
  String raw -> FormatSpec <$> normalizeFormatName operation raw <*> pure Nothing
  expression
    | Just [outerExpression, innerExpression] <- listItems expression -> do
        outer <- case outerExpression of
          String raw -> normalizeFormatName operation raw
          _ -> Left (operation <> " expects the format name to be a string.")
        if outer `elem` ["GZIP", "BZIP2"]
          then FormatSpec outer . Just <$> normalizeFormatSpec operation innerExpression
          else Left (operation <> " currently supports list format specifications only for compression wrappers such as {\"GZIP\", \"Text\"}.")
  _ -> Left (operation <> " expects a format string or a compression-wrapper format specification.")

normalizeFormatName :: Text -> Text -> Either Text Text
normalizeFormatName operation raw =
  case Map.lookup (T.toLower (T.strip raw)) names of
    Just name -> Right name
    Nothing -> Left (operation <> " currently supports only \"BZIP2\", \"Byte\", \"CSV\", \"GZIP\", \"JSON\", \"RawJSON\", \"String\", \"TSV\", \"Table\", \"Text\", \"WL\".")
 where
  names = Map.fromList
    [ ("byte", "Byte"), ("bzip2", "BZIP2"), ("csv", "CSV"), ("gzip", "GZIP")
    , ("json", "JSON"), ("rawjson", "RawJSON"), ("string", "String"), ("table", "Table")
    , ("text", "Text"), ("tsv", "TSV"), ("wl", "WL")
    ]

exportStringExpr :: [Expr] -> Conversion
exportStringExpr = \case
  [expression, formatExpression] -> do
    spec <- normalizeFormatSpec "ExportString" formatExpression
    exportStringWith spec expression
  _ -> Left "ExportString currently expects an expression and an explicit format specification."

importStringExpr :: [Expr] -> Conversion
importStringExpr = \case
  [String source, formatExpression] -> do
    spec <- normalizeFormatSpec "ImportString" formatExpression
    importStringWith spec source
  [_, _] -> Left "ImportString expects the source data to be a string."
  _ -> Left "ImportString currently expects a string and an explicit format specification."

exportByteArrayExpr :: [Expr] -> Conversion
exportByteArrayExpr = \case
  [expression, formatExpression] -> do
    spec <- normalizeFormatSpec "ExportByteArray" formatExpression
    exportByteArrayWith spec expression
  _ -> Left "ExportByteArray currently expects an expression and an explicit format specification."

importByteArrayExpr :: [Expr] -> Conversion
importByteArrayExpr = \case
  [ByteArray bytes, formatExpression] -> do
    spec <- normalizeFormatSpec "ImportByteArray" formatExpression
    importByteArrayWith spec bytes
  [_, _] -> Left "ImportByteArray expects a ByteArray."
  _ -> Left "ImportByteArray currently expects a byte array and an explicit format specification."

exportStringWith :: FormatSpec -> Expr -> Conversion
exportStringWith (FormatSpec outer (Just _)) _ = Left ("Unsupported compression wrapper: " <> outer <> ".")
exportStringWith (FormatSpec name Nothing) expression = case name of
  "Text" -> Right (asText expression)
  "String" -> Right (asText expression)
  "Byte" -> String . rawBytesText <$> exprBytes "ExportString" expression
  "JSON" -> String . encodeJsonPretty <$> exprJson "ExportString" False expression
  "RawJSON" -> String . encodeJsonPretty <$> exprJson "ExportString" True expression
  "CSV" -> String . exportDelimited ',' <$> tabularRows "ExportString" expression
  "TSV" -> String . exportDelimited '\t' <$> tabularRows "ExportString" expression
  "Table" -> String . T.intercalate "\n" . map (T.intercalate "\t") <$> tabularRows "ExportString" expression
  "WL" -> Right (String (inputForm expression))
  _ -> Left ("Unsupported ExportString format: " <> name <> ".")
 where
  asText value@String {} = value
  asText value = String (inputForm value)

importStringWith :: FormatSpec -> Text -> Conversion
importStringWith (FormatSpec outer (Just _)) _ = Left ("Unsupported compression wrapper: " <> outer <> ".")
importStringWith (FormatSpec name Nothing) source = case name of
  "Text" -> Right (String source)
  "String" -> Right (String source)
  "Byte" -> Call (Symbol "List") . map (Integer . fromIntegral) . BS.unpack <$> rawTextBytes "ImportString" source
  "JSON" -> jsonToExpr False <$> parseJsonText "ImportString" source
  "RawJSON" -> jsonToExpr True <$> parseJsonText "ImportString" source
  "CSV" -> Right (importDelimited ',' source)
  "TSV" -> Right (importDelimited '\t' source)
  "Table" -> Right (importTable source)
  "WL" -> either (Left . parseErrorMessage) Right (parseInputForm source)
  _ -> Left ("Unsupported ImportString format: " <> name <> ".")

exportByteArrayWith :: FormatSpec -> Expr -> Conversion
exportByteArrayWith (FormatSpec outer (Just _)) _ = Left ("Unsupported compression wrapper: " <> outer <> ".")
exportByteArrayWith spec@(FormatSpec name Nothing) expression = case name of
  "Byte" -> ByteArray <$> exprBytes "ExportByteArray" expression
  "String" -> case expression of
    String source -> ByteArray <$> rawTextBytes "ExportByteArray" source
    _ -> ByteArray <$> rawTextBytes "ExportByteArray" (inputForm expression)
  _ | name `elem` ["CSV", "JSON", "RawJSON", "Table", "Text", "TSV", "WL"] -> do
        exported <- exportStringWith spec expression
        case exported of
          String source -> Right (ByteArray (TE.encodeUtf8 source))
          _ -> Left "ExportByteArray textual export did not produce a string."
  _ -> Left ("Unsupported ExportByteArray format: " <> name <> ".")

importByteArrayWith :: FormatSpec -> BS.ByteString -> Conversion
importByteArrayWith (FormatSpec outer (Just _)) _ = Left ("Unsupported compression wrapper: " <> outer <> ".")
importByteArrayWith spec@(FormatSpec name Nothing) bytes = case name of
  "Byte" -> Right (Call (Symbol "List") (map (Integer . fromIntegral) (BS.unpack bytes)))
  "String" -> Right (String (rawBytesText bytes))
  _ | name `elem` ["CSV", "JSON", "RawJSON", "Table", "Text", "TSV", "WL"] ->
        importStringWith spec (decodeUtf8Preserving bytes)
  _ -> Left ("Unsupported ImportByteArray format: " <> name <> ".")

exprBytes :: Text -> Expr -> Either Text BS.ByteString
exprBytes _ (ByteArray bytes) = Right bytes
exprBytes operation expression
  | Just items <- listItems expression = do
      values <- traverse integerByte items
      Right (BS.pack values)
  | otherwise = Left (operation <> " expects a byte list or a ByteArray.")
 where
  integerByte (Integer value)
    | value >= 0 && value <= 255 = Right (fromIntegral value)
    | otherwise = Left "ByteArray values must be integers between 0 and 255."
  integerByte _ = Left (operation <> " expects a byte list or a ByteArray.")

rawBytesText :: BS.ByteString -> Text
rawBytesText = T.pack . map (chr . fromIntegral) . BS.unpack

rawTextBytes :: Text -> Text -> Either Text BS.ByteString
rawTextBytes operation source = BS.pack <$> traverse convert (T.unpack source)
 where
  convert character
    | ord character <= 255 = Right (fromIntegral (ord character))
    | otherwise = Left (operation <> " raw string data currently expects characters with code points between 0 and 255.")

decodeUtf8Preserving :: BS.ByteString -> Text
decodeUtf8Preserving bytes =
  case TE.decodeUtf8' bytes of
    Right source -> source
    Left _ -> rawBytesText bytes

-- Small JSON model preserving object member order.
data JsonAtom
  = JsonNull
  | JsonBool !Bool
  | JsonNumber !Text
  | JsonString !Text
  | JsonArray ![JsonAtom]
  | JsonObject ![(Text, JsonAtom)]
  deriving (Eq, Show)

parseJsonText :: Text -> Text -> Either Text JsonAtom
parseJsonText operation source =
  case Parsec.parse (jsonSpaces *> jsonValue <* jsonSpaces <* eof) "JSON input" source of
    Left _ -> Left (operation <> " could not parse the JSON payload.")
    Right value -> Right value

jsonValue :: Parser JsonAtom
jsonValue = choice
  [ JsonNull <$ string "null"
  , JsonBool True <$ string "true"
  , JsonBool False <$ string "false"
  , JsonString <$> jsonStringParser
  , JsonArray <$> between (char '[' *> jsonSpaces) (jsonSpaces *> char ']') (jsonValue `sepBy` comma)
  , JsonObject <$> between (char '{' *> jsonSpaces) (jsonSpaces *> char '}') (jsonMember `sepBy` comma)
  , JsonNumber . T.pack <$> jsonNumberParser
 ]
 where
  comma = try (jsonSpaces *> char ',' <* jsonSpaces)
  jsonMember = do
    key <- jsonStringParser
    jsonSpaces *> char ':' *> jsonSpaces
    value <- jsonValue
    pure (key, value)

jsonSpaces :: Parser ()
jsonSpaces = skipMany (oneOf " \t\r\n")

jsonNumberParser :: Parser String
jsonNumberParser = do
  sign <- option "" (pure <$> char '-')
  whole <- (pure <$> char '0' <* notFollowedBy digit) <|> ((:) <$> oneOf ['1' .. '9'] <*> many digit)
  fraction <- option "" ((:) <$> char '.' <*> many1 digit)
  exponentText <- option "" $ do
    marker <- oneOf "eE"
    exponentSign <- option "" (pure <$> oneOf "+-")
    digits <- many1 digit
    pure (marker : exponentSign <> digits)
  pure (sign <> whole <> fraction <> exponentText)

jsonStringParser :: Parser Text
jsonStringParser = T.pack <$> between (char '"') (char '"') (many character)
 where
  character = satisfy (\value -> value >= '\x20' && value /= '"' && value /= '\\') <|> escaped
  escaped = char '\\' *> (anyChar >>= escape)
  escape = \case
    '"' -> pure '"'
    '\\' -> pure '\\'
    '/' -> pure '/'
    'b' -> pure '\b'
    'f' -> pure '\f'
    'n' -> pure '\n'
    'r' -> pure '\r'
    't' -> pure '\t'
    'u' -> chr . foldl' (\total digitValue -> total * 16 + digitValue) 0 <$> count 4 hexValue
    marker -> unexpected ("JSON escape \\" <> [marker])
  hexValue = do
    value <- satisfy (\c -> isDigit c || toUpper c `elem` ['A' .. 'F'])
    pure (if isDigit value then ord value - ord '0' else 10 + ord (toUpper value) - ord 'A')

jsonToExpr :: Bool -> JsonAtom -> Expr
jsonToExpr rawJson = \case
  JsonNull -> Symbol "Null"
  JsonBool value -> boolean value
  JsonNumber source
    | Just value <- (readMaybe (T.unpack source) :: Maybe Integer) -> Integer value
    | otherwise -> Real (normalizeJsonReal source)
  JsonString source -> String source
  JsonArray values -> Call (Symbol "List") (map (jsonToExpr rawJson) values)
  JsonObject entries ->
    let rules = [Call (Symbol "Rule") [String key, jsonToExpr rawJson value] | (key, value) <- entries]
     in Call (Symbol (if rawJson then "Association" else "List")) rules

normalizeJsonReal :: Text -> Text
normalizeJsonReal source
  | T.any (`elem` (".eE" :: String)) source = T.replace "E" "e" source
  | otherwise = source <> "."

exprJson :: Text -> Bool -> Expr -> Either Text JsonAtom
exprJson operation rawJson = \case
  String source -> Right (JsonString source)
  Integer value -> Right (JsonNumber (T.pack (show value)))
  Real source -> Right (JsonNumber (T.replace "*^" "e" (T.takeWhile (/= '`') source)))
  Symbol name | shortSystemName name == "True" -> Right (JsonBool True)
  Symbol name | shortSystemName name == "False" -> Right (JsonBool False)
  Symbol name | shortSystemName name == "Null" -> Right JsonNull
  Symbol name -> Left (operation <> " does not currently support exporting the symbol " <> name <> " to JSON.")
  expression
    | Just items <- listItems expression ->
        case traverse ruleEntry items of
          Just entries
            | rawJson -> Left (operation <> " RawJSON export expects associations for JSON objects, not lists of rules.")
            | otherwise -> JsonObject <$> traverse convertEntry entries
          Nothing -> JsonArray <$> traverse (exprJson operation rawJson) items
  Call (Symbol name) entries
    | shortSystemName name == "Association" ->
        maybe
          (Left (operation <> " does not currently support exporting " <> inputForm (Call (Symbol name) entries) <> " as JSON."))
          (fmap JsonObject . traverse convertEntry)
          (traverse ruleEntry entries)
  expression -> Left (operation <> " does not currently support exporting " <> inputForm expression <> " as JSON.")
 where
  ruleEntry = \case
    Call (Symbol name) [key, value]
      | shortSystemName name `elem` ["Rule", "RuleDelayed"] -> Just (key, value)
    _ -> Nothing
  convertEntry (String key, value) = (key,) <$> exprJson operation rawJson value
  convertEntry _ = Left (operation <> " JSON object keys must be strings.")

encodeJsonPretty :: JsonAtom -> Text
encodeJsonPretty = go 0
 where
  go depth = \case
    JsonNull -> "null"
    JsonBool False -> "false"
    JsonBool True -> "true"
    JsonNumber source -> source
    JsonString source -> jsonString source
    JsonArray [] -> "[]"
    JsonArray values ->
      "[\n" <> indent (depth + 1) <> T.intercalate (",\n" <> indent (depth + 1)) (map (go (depth + 1)) values) <> "\n" <> indent depth <> "]"
    JsonObject [] -> "{}"
    JsonObject entries ->
      "{\n" <> indent (depth + 1)
        <> T.intercalate
          (",\n" <> indent (depth + 1))
          [jsonString key <> ":" <> go (depth + 1) value | (key, value) <- entries]
        <> "\n" <> indent depth <> "}"
  indent depth = T.replicate depth "\t"

jsonString :: Text -> Text
jsonString source = "\"" <> T.concatMap escape source <> "\""
 where
  escape '"' = "\\\""
  escape '\\' = "\\\\"
  escape '\b' = "\\b"
  escape '\f' = "\\f"
  escape '\n' = "\\n"
  escape '\r' = "\\r"
  escape '\t' = "\\t"
  escape character
    | ord character < 0x20 = "\\u" <> T.justifyRight 4 '0' (T.pack (showHex (ord character) ""))
    | otherwise = T.singleton character

tabularRows :: Text -> Expr -> Either Text [[Text]]
tabularRows operation expression = case listItems expression of
  Just [] -> Right []
  Just values
    | all (maybe True (const False) . listItems) values -> Right [[renderField value] | value <- values]
    | otherwise -> traverse row values
  Nothing -> Right [[renderField expression]]
 where
  row value = maybe (Left (operation <> " expects either a flat list or a list of rows.")) (Right . map renderField) (listItems value)
  renderField (String source) = source
  renderField value = inputForm value

exportDelimited :: Char -> [[Text]] -> Text
exportDelimited delimiter rows = T.concat [T.intercalate (T.singleton delimiter) (map quote row) <> "\n" | row <- rows]
 where
  quote field
    | T.any (\character -> character `elem` [delimiter, '"', '\n', '\r']) field = "\"" <> T.replace "\"" "\"\"" field <> "\""
    | otherwise = field

importDelimited :: Char -> Text -> Expr
importDelimited delimiter source =
  Call (Symbol "List") [Call (Symbol "List") (map parseTabularAtom row) | row <- parseDelimitedRows delimiter source]

parseDelimitedRows :: Char -> Text -> [[Text]]
parseDelimitedRows delimiter = finalize . go False [] [] [] . T.unpack
 where
  go _ field row rows [] = (field, row, rows)
  go quoted field row rows ('"' : '"' : rest)
    | quoted = go True ('"' : field) row rows rest
  go quoted field row rows ('"' : rest) = go (not quoted) field row rows rest
  go False field row rows (character : rest)
    | character == delimiter = go False [] (T.pack (reverse field) : row) rows rest
    | character == '\n' = go False [] [] (reverse (T.pack (reverse field) : row) : rows) rest
    | character == '\r' = go False field row rows rest
  go quoted field row rows (character : rest) = go quoted (character : field) row rows rest
  finalize (field, row, rows)
    | null field && null row = reverse rows
    | otherwise = reverse (reverse (T.pack (reverse field) : row) : rows)

importTable :: Text -> Expr
importTable source =
  Call (Symbol "List")
    [ Call (Symbol "List") (map parseTabularAtom (if T.null (T.strip line) then [] else T.words line))
    | line <- T.lines source
    ]

parseTabularAtom :: Text -> Expr
parseTabularAtom source
  | T.null stripped = String ""
  | Just value <- readMaybe (T.unpack stripped) :: Maybe Integer = Integer value
  | looksReal stripped = Real (normalizeJsonReal (T.replace "D" "e" (T.replace "d" "e" (T.replace "*^" "e" stripped))))
  | otherwise = String source
 where
  stripped = T.strip source
  looksReal value =
    T.any (`elem` (".eEdD" :: String)) value
      && maybe False (const True) (readMaybe (T.unpack (T.replace "D" "e" (T.replace "d" "e" (T.replace "*^" "e" value)))) :: Maybe Double)
