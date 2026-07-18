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
  , parseInputForm
  ) where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.Char (chr, digitToInt, isAlpha, isAlphaNum, isDigit, isHexDigit, isSpace, ord)
import Data.Text (Text)
import qualified Data.Text as T
import Text.Parsec
  ( Parsec
  , anyChar
  , between
  , char
  , chainl1
  , chainr1
  , choice
  , count
  , eof
  , getInput
  , many
  , many1
  , notFollowedBy
  , oneOf
  , option
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
import Tungsten.NamedCharacters
import Tungsten.WolframString (parseWolframStringLiteral)

newtype ParseError = ParseError {parseErrorMessage :: Text}
  deriving (Eq, Show)

type Parser = Parsec Text ()

-- | Parse one complete Wolfram FullForm expression.
parseFullForm :: Text -> Either ParseError Expr
parseFullForm source =
  first (ParseError . T.pack . show)
    (Parsec.parse (ignored *> expressionParser <* eof) "Wolfram FullForm" source)

-- | Parse the most common Wolfram InputForm surface syntax.  This slice covers
-- calls, lists, patterns, slots, arithmetic, comparisons, Boolean operators,
-- rules, replacements, assignments, application, and compound expressions.
parseInputForm :: Text -> Either ParseError Expr
parseInputForm source =
  first (ParseError . T.pack . show)
    (Parsec.parse (ignored *> inputExpressionParser <* eof) "Wolfram InputForm" source)

inputExpressionParser :: Parser Expr
inputExpressionParser = compoundExpressionParser

compoundExpressionParser :: Parser Expr
compoundExpressionParser = do
  firstExpression <- functionParser
  remaining <- many $ do
    _ <- operator ";" ""
    option (Symbol "Null") functionParser
  pure $ case remaining of
    [] -> firstExpression
    values -> Call (Symbol "CompoundExpression") (firstExpression : values)

functionParser :: Parser Expr
functionParser = do
  body <- assignmentParser
  ampersands <- many (operator "&" "&")
  pure (foldl' (\expression _ -> Call (Symbol "Function") [expression]) body ampersands)

assignmentParser :: Parser Expr
assignmentParser = do
  lhs <- replacementParser
  option lhs $ choice
    [ do
        _ <- operator ":=" ""
        rhs <- assignmentParser
        pure (Call (Symbol "SetDelayed") [lhs, rhs])
    , do
        _ <- operator "=" "=.!"
        rhs <- assignmentParser
        pure (Call (Symbol "Set") [lhs, rhs])
    ]

replacementParser :: Parser Expr
replacementParser = chainl1 ruleParser replacementOperator
 where
  replacementOperator = choice
    [ binary "//." (call2 "ReplaceRepeated")
    , binary "/." (call2 "ReplaceAll")
    ]

ruleParser :: Parser Expr
ruleParser = chainr1 conditionParser ruleOperator
 where
  ruleOperator = choice
    [ binary ":>" (call2 "RuleDelayed")
    , binary "->" (call2 "Rule")
    ]

conditionParser :: Parser Expr
conditionParser = chainl1 patternDefaultParser (binary "/;" (call2 "Condition"))

patternDefaultParser :: Parser Expr
patternDefaultParser = do
  lhs <- alternativesParser
  option lhs $ do
    _ <- operator ":" "=>"
    rhs <- patternDefaultParser
    pure (patternColonExpression lhs rhs)

patternColonExpression :: Expr -> Expr -> Expr
patternColonExpression lhs@(Call (Symbol "Pattern") [_, _]) defaultValue =
  Call (Symbol "Optional") [lhs, defaultValue]
patternColonExpression (Symbol name) patternExpression =
  Call (Symbol "Pattern") [Symbol name, patternExpression]
patternColonExpression patternExpression defaultValue =
  Call (Symbol "Optional") [patternExpression, defaultValue]

alternativesParser :: Parser Expr
alternativesParser = chainl1 orParser (binaryExcept "|" ">" (flatCall2 "Alternatives"))

orParser :: Parser Expr
orParser = chainl1 andParser (binary "||" (call2 "Or"))

andParser :: Parser Expr
andParser = chainl1 comparisonParser (binary "&&" (call2 "And"))

comparisonParser :: Parser Expr
comparisonParser = do
  firstExpression <- applyParser
  comparisons <- many ((,) <$> comparisonOperator <*> applyParser)
  pure (comparisonExpression firstExpression comparisons)
 where
  comparisonOperator = choice
    [ "SameQ" <$ operator "===" ""
    , "UnsameQ" <$ operator "=!=" ""
    , "LessEqual" <$ operator "<=" ""
    , "GreaterEqual" <$ operator ">=" ""
    , "Equal" <$ operator "==" "="
    , "Unequal" <$ operator "!=" ""
    , "Less" <$ operator "<" "|>"
    , "Greater" <$ operator ">" "="
    ]

comparisonExpression :: Expr -> [(Text, Expr)] -> Expr
comparisonExpression firstExpression comparisons = case comparisons of
  [] -> firstExpression
  (firstHead, firstValue) : remaining
    | all ((== firstHead) . fst) remaining ->
        Call (Symbol firstHead) (firstExpression : firstValue : map snd remaining)
    | otherwise ->
        Call
          (Symbol "Inequality")
          (firstExpression : concatMap (\(headName, value) -> [Symbol headName, value]) comparisons)

applyParser :: Parser Expr
applyParser = do
  firstExpression <- prefixApplyParser
  functions <- many (operator "//" ".=@" *> prefixApplyParser)
  pure (foldl' (\argument function -> Call function [argument]) firstExpression functions)
 where
  prefixApplyParser = do
    function <- plusParser
    rightApplication <- optionMaybe (operator "@" "@*")
    case rightApplication of
      Just _ -> Call function . pure <$> prefixApplyParser
      Nothing -> pure function

plusParser :: Parser Expr
plusParser = chainl1 timesParser plusOperator
 where
  plusOperator = choice
    [ binaryExcept "+" "=" (flatCall2 "Plus")
    , binaryExcept "-" "=>" (\lhs rhs -> flatCall2 "Plus" lhs (negateExpression rhs))
    ]

timesParser :: Parser Expr
timesParser = do
  firstFactor <- unaryParser
  operations <- many timesTail
  pure (foldl' applyTimes firstFactor operations)
 where
  timesTail = choice
    [ (,) Multiply <$> (operator "*" "*^*=" *> unaryParser)
    , (,) Divide <$> (operator "/" "/;.@=" *> unaryParser)
    , try ((,) Multiply <$> powerParser)
    ]
  applyTimes lhs (Multiply, rhs) = flatCall2 "Times" lhs rhs
  applyTimes lhs (Divide, rhs) = divideExpression lhs rhs

data TimesOperation = Multiply | Divide

unaryParser :: Parser Expr
unaryParser = choice
  [ operator "+" "+=" *> unaryParser
  , negateExpression <$> (operator "-" "-=>" *> unaryParser)
  , Call (Symbol "Not") . pure <$> (operator "!" "!=" *> unaryParser)
  , powerParser
  ]

powerParser :: Parser Expr
powerParser = do
  base <- postfixParser
  option base $ do
    _ <- operator "^" "^:="
    exponentValue <- unaryParser
    pure (Call (Symbol "Power") [base, exponentValue])

postfixParser :: Parser Expr
postfixParser = inputAtomParser >>= postfixes
 where
  postfixes expression =
    choice
      [ do
          indices <- partArgumentsParser
          postfixes (Call (Symbol "Part") (expression : indices))
      , do
          arguments' <- inputArgumentsParser
          called <- canonicalCall expression arguments'
          postfixes called
      , do
          _ <- operator "!!" ""
          postfixes (Call (Symbol "Factorial2") [expression])
      , do
          _ <- operator "!" "!="
          postfixes (Call (Symbol "Factorial") [expression])
      , do
          blank <- lexeme blankShapeParser
          let patternExpression = Call (Symbol "Pattern") [expression, blank]
          optionalPattern <- option patternExpression (operator "." "." *> pure (Call (Symbol "Optional") [patternExpression]))
          postfixes optionalPattern
      , do
          repetitionHead <- choice
            [ "RepeatedNull" <$ operator "..." ""
            , "Repeated" <$ operator ".." ""
            ]
          let repeatedExpression = case (repetitionHead, optionalDotCandidate expression) of
                ("RepeatedNull", True) ->
                  Call (Symbol "Repeated") [Call (Symbol "Optional") [expression]]
                _ -> Call (Symbol repetitionHead) [expression]
          postfixes repeatedExpression
      , do
          _ <- operator "?" ""
          test <- inputAtomParser >>= postfixes
          postfixes (Call (Symbol "PatternTest") [expression, test])
      , pure expression
      ]

optionalDotCandidate :: Expr -> Bool
optionalDotCandidate (Call (Symbol "Blank") []) = True
optionalDotCandidate (Call (Symbol "Pattern") [Symbol _, Call (Symbol "Blank") []]) = True
optionalDotCandidate _ = False

inputArgumentsParser :: Parser [Expr]
inputArgumentsParser =
  lexeme (between (char '[' <* notFollowedBy (char '[')) (char ']') (inputExpressionParser `sepBy` symbolChar ','))

partArgumentsParser :: Parser [Expr]
partArgumentsParser = do
  _ <- lexeme (try (string "[["))
  indices <- inputExpressionParser `sepBy` symbolChar ','
  _ <- lexeme (try (string "]]"))
  pure indices

inputAtomParser :: Parser Expr
inputAtomParser = lexeme $ choice
  [ try numberParser
  , String <$> stringLiteralParser
  , listParser
  , associationParser
  , percentHistoryParser
  , slotParser
  , blankShapeParser
  , Symbol <$> symbolParser
  , between (symbolChar '(') (symbolChar ')') inputExpressionParser
  ]

percentHistoryParser :: Parser Expr
percentHistoryParser = do
  markers <- many1 (char '%')
  if length markers == 1
    then do
      digits <- many (satisfy isDigit)
      pure $ case digits of
        [] -> Call (Symbol "Out") []
        _ -> Call (Symbol "Out") [Integer (read digits)]
    else pure (Call (Symbol "Out") [Integer (negate (fromIntegral (length markers)))])

listParser :: Parser Expr
listParser =
  Call (Symbol "List")
    <$> between (symbolChar '{') (symbolChar '}') (inputExpressionParser `sepBy` symbolChar ',')

associationParser :: Parser Expr
associationParser = do
  _ <- operator "<|" ""
  entries <- inputExpressionParser `sepBy` symbolChar ','
  _ <- operator "|>" ""
  pure (Call (Symbol "Association") entries)

slotParser :: Parser Expr
slotParser = try slotSequence <|> slot
 where
  slotSequence = do
    _ <- string "##"
    digits <- many (satisfy isDigit)
    pure (Call (Symbol "SlotSequence") [Integer (if null digits then 1 else read digits)])
  slot = do
    _ <- char '#'
    input <- getInput
    case T.uncons input of
      Just (character, _) | isDigit character -> do
        digits <- many1 (satisfy isDigit)
        pure (Call (Symbol "Slot") [Integer (read digits)])
      Just (character, _) | isSymbolStart character ->
        Call (Symbol "Slot") . pure . String <$> symbolParser
      _ -> pure (Call (Symbol "Slot") [Integer 1])

blankShapeParser :: Parser Expr
blankShapeParser = try $ do
  headName <- choice
    [ "BlankNullSequence" <$ try (string "___")
    , "BlankSequence" <$ try (string "__")
    , "Blank" <$ char '_'
    ]
  typeName <- optionMaybe symbolParser
  pure (Call (Symbol headName) (maybe [] (pure . Symbol) typeName))

binary :: Text -> (Expr -> Expr -> Expr) -> Parser (Expr -> Expr -> Expr)
binary operatorText constructor = constructor <$ operator operatorText ""

binaryExcept :: Text -> String -> (Expr -> Expr -> Expr) -> Parser (Expr -> Expr -> Expr)
binaryExcept operatorText blocked constructor = constructor <$ operator operatorText blocked

operator :: Text -> String -> Parser Text
operator operatorText blocked = lexeme (choice (map spellingParser (namedOperatorSpellings operatorText)))
 where
  spellingParser spelling = try $ do
    _ <- string (T.unpack spelling)
    if spelling /= operatorText || null blocked
      then pure operatorText
      else notFollowedBy (oneOf blocked) *> pure operatorText

call2 :: Text -> Expr -> Expr -> Expr
call2 headName lhs rhs = Call (Symbol headName) [lhs, rhs]

flatCall2 :: Text -> Expr -> Expr -> Expr
flatCall2 headName lhs rhs = case lhs of
  Call (Symbol actualHead) values | actualHead == headName ->
    Call (Symbol headName) (values <> [rhs])
  _ -> Call (Symbol headName) [lhs, rhs]

negateExpression :: Expr -> Expr
negateExpression expression = case expression of
  Integer value -> Integer (-value)
  Rational numerator denominator -> Rational (-numerator) denominator
  Real source -> Real $ case T.uncons source of
    Just ('-', rest) -> rest
    _ -> "-" <> source
  _ -> Call (Symbol "Times") [Integer (-1), expression]

divideExpression :: Expr -> Expr -> Expr
divideExpression (Integer numerator) (Integer denominator)
  | denominator /= 0 = either (const fallback) id (rational numerator denominator)
 where
  fallback = Call (Symbol "Times") [Integer numerator, Call (Symbol "Power") [Integer denominator, Integer (-1)]]
divideExpression lhs rhs =
  flatCall2 "Times" lhs (Call (Symbol "Power") [rhs, Integer (-1)])

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
  magnitude <- optionalText (try magnitudeParser)
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
    fraction <- optionalText $ try $ do
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
stringLiteralParser =
  parseWolframStringLiteral . T.concat
    <$> between (char '"') (char '"') (many stringSourceChunk)
 where
  stringSourceChunk =
    (T.singleton <$> satisfy (\character -> character /= '"' && character /= '\\'))
      <|> do
        slash <- char '\\'
        escaped <- anyChar
        pure (T.pack [slash, escaped])

symbolParser :: Parser Text
symbolParser = do
  firstComponent <- symbolComponent isSymbolStart
  remaining <- many (symbolComponent isSymbolContinuation)
  let name = T.concat (firstComponent : remaining)
  pure $ case T.uncons name of
    Just (character, rest) | T.null rest -> maybe name id (symbolAliasForCharacter character)
    _ -> name

symbolComponent :: (Char -> Bool) -> Parser Text
symbolComponent accepted =
  (T.singleton <$> satisfy accepted)
    <|> try (escapedSymbolCharacter accepted)

escapedSymbolCharacter :: (Char -> Bool) -> Parser Text
escapedSymbolCharacter accepted = do
  _ <- char '\\'
  character <- namedEscape <|> numericEscape
  if accepted character
    then pure (T.singleton character)
    else unexpected "a Wolfram operator or invalid identifier character"
 where
  namedEscape = do
    _ <- char '['
    name <- T.pack <$> many (satisfy (/= ']'))
    _ <- char ']'
    maybe (fail ("unknown Wolfram named character escape \\[" <> T.unpack name <> "]")) pure (namedCharacter name)
  numericEscape = choice
    [ char ':' *> hexadecimalCharacter 4
    , char '.' *> hexadecimalCharacter 2
    , char '|' *> hexadecimalCharacter 6
    ]
  hexadecimalCharacter width = do
    digits <- count width (satisfy isHexDigit)
    let codepoint = foldl' (\value digit -> value * 16 + digitToInt digit) 0 digits
    if codepoint > 0x10ffff
      then unexpected "a Unicode codepoint above U+10FFFF"
      else pure (chr codepoint)

isSymbolStart :: Char -> Bool
isSymbolStart character =
  isAlpha character
    || character == '$'
    || character == '`'
    || isNonAsciiSymbolCharacter character

isSymbolContinuation :: Char -> Bool
isSymbolContinuation character =
  isAlphaNum character
    || character == '$'
    || character == '`'
    || isNonAsciiSymbolCharacter character

isNonAsciiSymbolCharacter :: Char -> Bool
isNonAsciiSymbolCharacter character =
  let codepoint = ord character
   in codepoint > 127
        && not (codepoint >= 0xd800 && codepoint <= 0xdfff)
        && not (isNamedOperatorCharacter character)

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
