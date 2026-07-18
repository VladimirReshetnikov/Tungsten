{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Kernel-free parsing for the structural Wolfram FullForm language.
--
-- The parser deliberately preserves arbitrary integers and real-number source
-- lexemes.  It accepts nested Wolfram comments and chained expression heads,
-- so values such as @Derivative[2][f][x]@ retain their exact tree shape.
module Tungsten.Parser
  ( ParseError (..)
  , parseFullForm
  ) where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.Char (chr, digitToInt, isAlpha, isAlphaNum, isDigit, isHexDigit, isSpace, ord)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (readOct)
import Text.Parsec
  ( Parsec
  , anyChar
  , between
  , char
  , choice
  , count
  , eof
  , many
  , many1
  , notFollowedBy
  , oneOf
  , optionMaybe
  , satisfy
  , sepBy
  , skipMany
  , string
  , try
  , unexpected
  , (<|>)
  )
import qualified Text.Parsec as Parsec
import Tungsten.Expression

newtype ParseError = ParseError {parseErrorMessage :: Text}
  deriving (Eq, Show)

type Parser = Parsec Text ()

-- | Parse one complete Wolfram FullForm expression.
parseFullForm :: Text -> Either ParseError Expr
parseFullForm source =
  first (ParseError . T.pack . show)
    (Parsec.parse (ignored *> expressionParser <* eof) "Wolfram FullForm" source)

expressionParser :: Parser Expr
expressionParser = do
  atom <- lexeme atomParser
  argumentLists <- many argumentsParser
  foldCalls atom argumentLists

foldCalls :: Expr -> [[Expr]] -> Parser Expr
foldCalls expression argumentLists = foldl' step (pure expression) argumentLists
 where
  step accumulated arguments' = accumulated >>= (`canonicalCall` arguments')

canonicalCall :: Expr -> [Expr] -> Parser Expr
canonicalCall (Symbol "Rational") [Integer numerator, Integer denominator] =
  either (fail . T.unpack . expressionErrorMessage) pure (rational numerator denominator)
canonicalCall (Symbol "Complex") [realPart, imaginaryPart] =
  pure (Complex realPart imaginaryPart)
canonicalCall expressionHead arguments' = pure (Call expressionHead arguments')

argumentsParser :: Parser [Expr]
argumentsParser =
  lexeme
    (between (symbolChar '[') (symbolChar ']') (expressionParser `sepBy` symbolChar ','))

atomParser :: Parser Expr
atomParser =
  choice
    [ try numberParser
    , String <$> stringLiteralParser
    , Symbol <$> symbolParser
    , between (symbolChar '(') (symbolChar ')') expressionParser
    ]

numberParser :: Parser Expr
numberParser = do
  source <- numberLexeme
  case integerFromSource source of
    Just value -> pure (Integer value)
    Nothing -> pure (Real source)

numberLexeme :: Parser Text
numberLexeme = do
  sign <- optionText (char '-')
  mantissa <- try leadingPoint <|> digitsWithOptionalPoint
  precision <- optionalText precisionParser
  magnitude <- optionalText magnitudeParser
  let source = sign <> mantissa <> precision <> magnitude
  notFollowedBy (satisfy isSymbolContinuation)
  pure source
 where
  leadingPoint = do
    point <- char '.'
    digits <- many1 (satisfy isDigit)
    pure (T.cons point (T.pack digits))
  digitsWithOptionalPoint = do
    digits <- T.pack <$> many1 (satisfy isDigit)
    decimal <- optionMaybe $ try $ do
      point <- char '.'
      notFollowedBy (char '.')
      fraction <- T.pack <$> many (satisfy isDigit)
      pure (T.cons point fraction)
    pure (digits <> maybe "" id decimal)

integerFromSource :: Text -> Maybe Integer
integerFromSource source
  | T.any (`elem` (".`*" :: String)) source = Nothing
  | otherwise = case reads (T.unpack source) of
      [(value, "")] -> Just value
      _ -> Nothing

precisionParser :: Parser Text
precisionParser = do
  marker <- try (string "``") <|> string "`"
  specification <- optionalText decimalPrecision
  if marker == "``" && T.null specification
    then unexpected "accuracy mark without a value"
    else pure (T.pack marker <> specification)
 where
  decimalPrecision = do
    whole <- T.pack <$> many (satisfy isDigit)
    fraction <- optionalText $ do
      point <- char '.'
      digits <- T.pack <$> many1 (satisfy isDigit)
      pure (T.cons point digits)
    if T.null whole && T.null fraction
      then unexpected "empty precision value"
      else pure (whole <> fraction)

magnitudeParser :: Parser Text
magnitudeParser = do
  marker <- string "*^"
  sign <- optionText (oneOf "+-")
  exponentDigits <- T.pack <$> many1 (satisfy isDigit)
  notFollowedBy (char '.')
  pure (T.pack marker <> sign <> exponentDigits)

stringLiteralParser :: Parser Text
stringLiteralParser = between (char '"') (char '"') (T.concat <$> many stringChunk)
 where
  stringChunk =
    (T.singleton <$> satisfy (\character -> character /= '"' && character /= '\\'))
      <|> escapedStringChunk

escapedStringChunk :: Parser Text
escapedStringChunk = do
  _ <- char '\\'
  choice
    [ "\"" <$ char '"'
    , "\\" <$ char '\\'
    , "\b" <$ char 'b'
    , "\f" <$ char 'f'
    , "\n" <$ char 'n'
    , "\r" <$ char 'r'
    , "\t" <$ char 't'
    , "" <$ char '\n'
    , T.singleton . chr . hexadecimalValue <$> (char ':' *> count 4 hexDigit)
    , T.singleton . chr . hexadecimalValue <$> (char '|' *> count 6 hexDigit)
    , T.singleton . octalValue <$> count 3 (oneOf ['0' .. '7'])
    , namedCharacter
    , T.singleton <$> anyChar
    ]
 where
  hexDigit = satisfy isHexDigit
  hexadecimalValue = foldl' (\value character -> value * 16 + digitToInt character) 0
  octalValue characters = case readOct characters of
    [(value, "")] -> chr value
    _ -> error "the parser accepted a malformed octal escape"

namedCharacter :: Parser Text
namedCharacter = do
  name <- between (char '[') (char ']') (many1 (satisfy isAlpha))
  pure $ case name of
    "Alpha" -> "α"
    "Beta" -> "β"
    "Gamma" -> "γ"
    "Delta" -> "δ"
    "Pi" -> "π"
    "Infinity" -> "∞"
    "Degree" -> "°"
    "ImaginaryI" -> "ⅈ"
    _ -> "\\[" <> T.pack name <> "]"

symbolParser :: Parser Text
symbolParser = do
  firstCharacter <- satisfy isSymbolStart
  remaining <- many (satisfy isSymbolContinuation)
  pure (T.pack (firstCharacter : remaining))

isSymbolStart :: Char -> Bool
isSymbolStart character =
  isAlpha character
    || character == '$'
    || character == '`'
    || ord character > 127

isSymbolContinuation :: Char -> Bool
isSymbolContinuation character =
  isAlphaNum character
    || character == '$'
    || character == '`'
    || ord character > 127

ignored :: Parser ()
ignored = skipMany (void (satisfy isSpace) <|> wolframComment)

wolframComment :: Parser ()
wolframComment = try (string "(*") *> nestedComment 1
 where
  nestedComment :: Int -> Parser ()
  nestedComment 0 = pure ()
  nestedComment depth =
    choice
      [ try (string "(*") *> nestedComment (depth + 1)
      , try (string "*)") *> nestedComment (depth - 1)
      , anyChar *> nestedComment depth
      ]

lexeme :: Parser value -> Parser value
lexeme parser = parser <* ignored

symbolChar :: Char -> Parser Char
symbolChar character = lexeme (char character)

optionText :: Parser Char -> Parser Text
optionText parser = maybe "" T.singleton <$> optionMaybe parser

optionalText :: Parser Text -> Parser Text
optionalText parser = maybe "" id <$> optionMaybe parser
