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

newtype ParserContext = ParserContext
  { suppressTaggedUnset :: Bool
  }

type Parser = Parsec Text ParserContext

initialParserContext :: ParserContext
initialParserContext = ParserContext False

-- | Parse one complete Wolfram FullForm expression.
parseFullForm :: Text -> Either ParseError Expr
parseFullForm source =
  first (ParseError . T.pack . show)
    ( Parsec.runParser
        (ignored *> option (Symbol "Null") expressionParser <* eof)
        initialParserContext
        "Wolfram FullForm"
        source
    )

-- | Parse the most common Wolfram InputForm surface syntax.  This slice covers
-- calls, lists, patterns, slots, arithmetic, comparisons, Boolean operators,
-- rules, replacements, assignments, application, and compound expressions.
parseInputForm :: Text -> Either ParseError Expr
parseInputForm source =
  first (ParseError . T.pack . show)
    ( Parsec.runParser
        (ignored *> option (Symbol "Null") inputExpressionParser <* eof)
        initialParserContext
        "Wolfram InputForm"
        source
    )

inputExpressionParser :: Parser Expr
inputExpressionParser = do
  expression <- namedFunctionParser
  case tagSetPrefixParts expression of
    Just _ -> fail "Expected '=', ':=', or '=.' after '/:'."
    Nothing -> pure expression

namedFunctionParser :: Parser Expr
namedFunctionParser = do
  parameters <- compoundExpressionParser
  option parameters $ do
    _ <- operator "|->" ""
    body <- namedFunctionParser
    pure (Call (Symbol "Function") [parameters, body])

compoundExpressionParser :: Parser Expr
compoundExpressionParser = do
  firstExpression <- assignmentParser
  remaining <- many $ do
    _ <- operator ";" ";"
    option (Symbol "Null") assignmentParser
  pure $ case remaining of
    [] -> firstExpression
    values -> Call (Symbol "CompoundExpression") (firstExpression : values)

spanParser :: Parser Expr
spanParser = do
  firstSpan <- try leadingSpan <|> do
    start <- plusParser
    option start (spanFrom start)
  remainingSpans <- many (try leadingSpan)
  pure (foldl' (flatCall2 "Times") firstSpan remainingSpans)
 where
  leadingSpan = spanFrom (Integer 1)
  spanFrom start = do
    _ <- operator ";;" ""
    end <- option (Symbol "All") (try plusParser)
    step <- optionMaybe (try (operator ";;" "" *> plusParser))
    pure
      ( Call
          (Symbol "Span")
          (start : end : maybe [] pure step)
      )

functionParser :: Parser Expr
functionParser = compositionParser >>= functionPostfixes
 where
  functionPostfixes expression =
    option expression $ do
      _ <- operator "&" "&"
      postfixed <- postfixesParser True (Call (Symbol "Function") [expression])
      continued <- continueAfterFunction postfixed
      functionPostfixes continued

  -- Function sits below rules, replacement, mapping, and composition but above
  -- assignment.  A higher-precedence operator can therefore continue after a
  -- completed postfix function: @p & -> property@ is a rule whose left side is
  -- @Function[p]@, while @lhs -> rhs &@ wraps the already-completed rule.
  -- Re-enter the higher-precedence layer with the completed tree parenthesized
  -- so the recursive-descent grammar can model that Pratt-style continuation.
  continueAfterFunction expression = do
    remaining <- getInput
    Parsec.setInput ("(" <> fullForm expression <> ")" <> remaining)
    compositionParser

assignmentParser :: Parser Expr
assignmentParser = do
  lhs <- taggedAssignmentPrefixParser
  option lhs (assignmentSuffix lhs)

taggedAssignmentPrefixParser :: Parser Expr
taggedAssignmentPrefixParser = functionParser >>= gatherPrefixes
 where
  gatherPrefixes lhs =
    option lhs $ do
      _ <- operator "/:" ""
      target <- withTaggedUnsetSuppression True functionParser
      gatherPrefixes (Call (Symbol "TagSetPrefix") [lhs, target])

assignmentSuffix :: Expr -> Parser Expr
assignmentSuffix lhs = choice
  [ do
      _ <- operator ":=" ""
      rhs <- assignmentParser
      pure (taggedAssignment "TagSetDelayed" "SetDelayed" lhs rhs)
  , do
      _ <- operator "=." ""
      continueAfterTaggedUnset (taggedUnset lhs)
  , try $ do
      _ <- operator "=" "=.!"
      _ <- operator "." ".0123456789"
      continueAfterTaggedUnset (taggedUnset lhs)
  , do
      _ <- operator "=" "=.!"
      rhs <- assignmentParser
      pure (taggedAssignment "TagSet" "Set" lhs rhs)
  ]

taggedAssignment :: Text -> Text -> Expr -> Expr -> Expr
taggedAssignment taggedHead ordinaryHead lhs rhs =
  case tagSetPrefixParts lhs of
    Just (tag, target) -> Call (Symbol taggedHead) [tag, target, rhs]
    Nothing -> Call (Symbol ordinaryHead) [lhs, rhs]

taggedUnset :: Expr -> Expr
taggedUnset lhs = case tagSetPrefixParts lhs of
  Just (tag, target) -> Call (Symbol "TagUnset") [tag, target]
  Nothing -> Call (Symbol "Unset") [lhs]

-- In Wolfram syntax @=.@ is a postfix operator even when it closes a tagged
-- assignment.  The surrounding recursive-descent layer has already returned
-- from the higher-precedence parser at this point, so reparse only a genuine
-- continuation with the completed tagged unset parenthesized as its left side.
continueAfterTaggedUnset :: Expr -> Parser Expr
continueAfterTaggedUnset expression = do
  remaining <- getInput
  if endsCurrentExpression remaining
    then pure expression
    else do
      Parsec.setInput ("(" <> inputForm expression <> ")" <> remaining)
      inputExpressionParser
 where
  endsCurrentExpression remaining =
    T.null remaining
      || maybe False (`elem` (",;)]}" :: String)) (fst <$> T.uncons remaining)
      || "|>" `T.isPrefixOf` remaining

tagSetPrefixParts :: Expr -> Maybe (Expr, Expr)
tagSetPrefixParts = \case
  Call (Symbol "TagSetPrefix") [tag, target] -> Just (tag, target)
  _ -> Nothing

withTaggedUnsetSuppression :: Bool -> Parser value -> Parser value
withTaggedUnsetSuppression suppressed parser = do
  previous <- Parsec.getState
  Parsec.putState (ParserContext suppressed)
  result <- parser
  Parsec.putState previous
  pure result

nestedInputExpressionParser :: Parser Expr
nestedInputExpressionParser =
  withTaggedUnsetSuppression False inputExpressionParser

compositionParser :: Parser Expr
compositionParser =
  chainl1 compositionTermParser (binary "/*" (flatCall2 "RightComposition"))
 where
  compositionTermParser =
    chainl1 applyOperatorParser (binary "@*" (flatCall2 "Composition"))

applyOperatorParser :: Parser Expr
applyOperatorParser = chainr1 mapOperatorParser applyOperator
 where
  applyOperator = choice
    [ binary "@@@" (call2 "MapApply")
    , binary "@@" (call2 "Apply")
    ]

mapOperatorParser :: Parser Expr
mapOperatorParser = chainr1 replacementParser mapOperator
 where
  mapOperator = choice
    [ binary "//@" (call2 "MapAll")
    , binary "/@" (call2 "Map")
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
  lhs <- stringExpressionParser
  option lhs $ do
    _ <- operator ":" "=>"
    rhs <- patternDefaultParser
    pure (patternColonExpression lhs rhs)

stringExpressionParser :: Parser Expr
stringExpressionParser =
  chainl1
    alternativesParser
    (binary "~~" (call2 "StringExpression"))

patternColonExpression :: Expr -> Expr -> Expr
patternColonExpression lhs@(Call (Symbol "Pattern") [_, _]) defaultValue =
  Call (Symbol "Optional") [lhs, defaultValue]
patternColonExpression (Symbol name) patternExpression =
  Call (Symbol "Pattern") [Symbol name, patternExpression]
patternColonExpression patternExpression defaultValue =
  Call (Symbol "Optional") [patternExpression, defaultValue]

alternativesParser :: Parser Expr
alternativesParser = chainl1 orParser (binaryExcept "|" ">-" (flatCall2 "Alternatives"))

orParser :: Parser Expr
orParser = chainl1 andParser (binary "||" (call2 "Or"))

andParser :: Parser Expr
andParser = chainl1 comparisonParser (binary "&&" (call2 "And"))

comparisonParser :: Parser Expr
comparisonParser = do
  firstExpression <- defaultNamedInfixParser
  comparisons <- many ((,) <$> comparisonOperator <*> defaultNamedInfixParser)
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

-- Generic named infix operators use the comparison binding power but are
-- left-associative (their Pratt right binding power is one tick higher).
-- Parsing them as each built-in comparison operand reproduces that asymmetry:
-- @a < b \[Precedes] c@ keeps @Precedes[b, c]@ on the comparison's right.
defaultNamedInfixParser :: Parser Expr
defaultNamedInfixParser = do
  firstExpression <- applyParser
  operations <- many ((,) <$> namedOperator <*> applyParser)
  pure (namedInfixExpression firstExpression operations)
 where
  namedOperator = namedInfixOperatorParser isDefaultNamedInfix
  isDefaultNamedInfix headName =
    headName /= "CirclePlus"
      && headName /= "CircleTimes"
      && headName /= "Diamond"

namedInfixExpression :: Expr -> [(Text, Expr)] -> Expr
namedInfixExpression = go
 where
  go expression [] = expression
  go expression ((headName, value) : remaining) =
    let (sameHead, rest) = span ((== headName) . fst) remaining
        operands = expression : value : map snd sameHead
     in go (Call (Symbol headName) operands) rest

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
  firstExpression <- spanParser
  functions <- many (operator "//" ".=@" *> spanParser)
  pure (foldl' (\argument function -> Call function [argument]) firstExpression functions)

-- The three named infix operators with non-default Wolfram precedences each
-- occupy their own layer.  Gathering operands in the layer itself makes an
-- unparenthesized chain n-ary while retaining a nested call introduced by
-- parentheses or an explicit head call as a structural boundary.
circlePlusParser :: Parser Expr
circlePlusParser = namedInfixChainParser "CirclePlus" timesParser timesParser

plusParser :: Parser Expr
plusParser = chainl1 circlePlusParser plusOperator
 where
  plusOperator = choice
    [ binary "<>" (call2 "StringJoin")
    , binaryExcept "+" "=" (flatCall2 "Plus")
    , binaryExcept "-" "=>" (\lhs rhs -> flatCall2 "Plus" lhs (negateExpression rhs))
    ]

timesParser :: Parser Expr
timesParser = do
  firstFactor <- unaryParser
  operations <- many timesTail
  pure (fst (foldl' applyTimes (firstFactor, False) operations))
 where
  timesTail = choice
    [ (,) Multiply <$> (operator "*" "*^*=" *> unaryParser)
    , (,) Divide <$> (operator "/" "/:;.@=*" *> unaryParser)
    , try $ do
        notFollowedBy (char '-')
        (,) Multiply <$> circleTimesParser
    ]
  applyTimes (lhs, isUngroupedTimes) (Multiply, rhs) =
    case (isUngroupedTimes, lhs) of
      (True, Call (Symbol "Times") values) ->
        (Call (Symbol "Times") (values <> [rhs]), True)
      _ -> (Call (Symbol "Times") [lhs, rhs], True)
  applyTimes (lhs, isUngroupedTimes) (Divide, rhs) =
    divideExpression isUngroupedTimes lhs rhs

data TimesOperation = Multiply | Divide

unaryParser :: Parser Expr
unaryParser = choice
  [ operator "+" "+=" *> unaryParser
  , negateExpression <$> (operator "-" "-=>" *> unaryParser)
  , Call (Symbol "Not") . pure <$> (operator "!" "=" *> comparisonParser)
  , circleTimesParser
  ]

circleTimesParser :: Parser Expr
circleTimesParser =
  namedInfixChainParser
    "CircleTimes"
    diamondParser
    (namedHighPrecedenceRightParser diamondParser)

diamondParser :: Parser Expr
diamondParser =
  namedInfixChainParser
    "Diamond"
    dotParser
    (namedHighPrecedenceRightParser dotParser)

-- Prefix operators may begin the right operand of a tighter infix operator.
-- Once a prefix appears, its own lower binding power controls how much of the
-- remainder it absorbs, mirroring the existing Dot/Power right-side parser.
namedHighPrecedenceRightParser :: Parser Expr -> Parser Expr
namedHighPrecedenceRightParser fallback = choice
  [ operator "+" "+=" *> unaryParser
  , negateExpression <$> (operator "-" "-=>" *> unaryParser)
  , Call (Symbol "Not") . pure <$> (operator "!" "=" *> comparisonParser)
  , fallback
  ]

namedInfixChainParser :: Text -> Parser Expr -> Parser Expr -> Parser Expr
namedInfixChainParser headName firstParser rightParser = do
  firstExpression <- firstParser
  remaining <- many (namedOperator *> rightParser)
  pure $ case remaining of
    [] -> firstExpression
    values -> Call (Symbol headName) (firstExpression : values)
 where
  namedOperator = namedInfixOperatorParser (== headName)

-- Wolfram's Dot binds more tightly than Times but less tightly than Power.
-- Prefix +/- sit between Dot and Times: they absorb a following Dot expression
-- while leaving a following product outside, so @-a.b*c@ is
-- @Times[Times[-1, Dot[a, b]], c]@.  A prefix operator may still begin the
-- right operand of Dot or Power even though its own binding power is lower.
dotParser :: Parser Expr
dotParser = do
  firstFactor <- powerParser
  remaining <- many (operator "." ".0123456789" *> highPrecedenceRightParser)
  pure $ case remaining of
    [] -> firstFactor
    values -> Call (Symbol "Dot") (firstFactor : values)

powerParser :: Parser Expr
powerParser = do
  base <- prefixUpdateParser
  option base $ do
    _ <- operator "^" "^:="
    exponentValue <- highPrecedenceRightParser
    pure (Call (Symbol "Power") [base, exponentValue])

-- Pratt-style prefix parsing permits a sign (or Not) at the start of a
-- high-precedence right operand.  Once present, the prefix operator applies
-- its own lower binding power, which is why @a^-b.c@ absorbs @b.c@ into the
-- exponent while @a^b.c@ leaves Dot outside Power.
highPrecedenceRightParser :: Parser Expr
highPrecedenceRightParser = choice
  [ operator "+" "+=" *> unaryParser
  , negateExpression <$> (operator "-" "-=>" *> unaryParser)
  , Call (Symbol "Not") . pure <$> (operator "!" "=" *> comparisonParser)
  , powerParser
  ]

prefixUpdateParser :: Parser Expr
prefixUpdateParser = choice
  [ Call (Symbol "PreIncrement") . pure <$> (operator "++" "" *> prefixUpdateParser)
  , Call (Symbol "PreDecrement") . pure <$> (operator "--" "" *> prefixUpdateParser)
  , prefixApplicationParser
  ]

prefixApplicationParser :: Parser Expr
prefixApplicationParser = do
  function <- postfixParser
  option function $ do
    _ <- operator "@" "@*"
    argument <- prefixUpdateParser
    pure (Call function [argument])

postfixParser :: Parser Expr
postfixParser = inputAtomParser >>= postfixesParser True

postfixesParser :: Bool -> Expr -> Parser Expr
postfixesParser allowPatternTest expression =
  choice
    [ do
        indices <- partArgumentsParser
        postfixesParser allowPatternTest (Call (Symbol "Part") (expression : indices))
    , do
        arguments' <- inputArgumentsParser
        called <- canonicalCall expression arguments'
        postfixesParser allowPatternTest called
    , do
        _ <- operator "!!" ""
        postfixesParser allowPatternTest (Call (Symbol "Factorial2") [expression])
    , do
        _ <- operator "!" "!="
        postfixesParser allowPatternTest (Call (Symbol "Factorial") [expression])
    , do
        primes <- many1 (operator "'" "")
        let derivative =
              Call
                (Call (Symbol "Derivative") [Integer (toInteger (length primes))])
                [expression]
        postfixesParser allowPatternTest derivative
    , do
        updateHead <- choice
          [ "Increment" <$ operator "++" ""
          , "Decrement" <$ operator "--" ""
          , do
              context <- Parsec.getState
              if suppressTaggedUnset context
                then Parsec.parserZero
                else "Unset" <$ operator "=." ""
          ]
        postfixesParser allowPatternTest (Call (Symbol updateHead) [expression])
    , do
        _ <- operator "::" ""
        tag <- messageTagParser
        let messageName = case expression of
              Call (Symbol "MessageName") values@(_ : _ : _) ->
                Call (Symbol "MessageName") (values <> [tag])
              _ -> Call (Symbol "MessageName") [expression, tag]
        postfixesParser allowPatternTest messageName
    , case expression of
        Symbol _ -> do
          blank <- lexeme blankShapeParser
          postfixesParser allowPatternTest (Call (Symbol "Pattern") [expression, blank])
        _ -> Parsec.parserZero
    , do
        if optionalDotCandidate expression
          then pure ()
          else Parsec.parserZero
        _ <- operator "." "."
        postfixesParser allowPatternTest (Call (Symbol "Optional") [expression])
    , do
        repetitionHead <- choice
          [ "RepeatedNull" <$ operator "..." ""
          , "Repeated" <$ operator ".." ""
          ]
        let repeatedExpression = case (repetitionHead, optionalDotCandidate expression) of
              ("RepeatedNull", True) ->
                Call (Symbol "Repeated") [Call (Symbol "Optional") [expression]]
              _ -> Call (Symbol repetitionHead) [expression]
        postfixesParser allowPatternTest repeatedExpression
    , if allowPatternTest
        then do
          _ <- operator "?" ""
          test <- inputAtomParser >>= postfixesParser False
          postfixesParser True (Call (Symbol "PatternTest") [expression, test])
        else Parsec.parserZero
    , pure expression
    ]

messageTagParser :: Parser Expr
messageTagParser =
  String <$> lexeme (stringLiteralParser <|> symbolParser)

optionalDotCandidate :: Expr -> Bool
optionalDotCandidate (Call (Symbol "Blank") []) = True
optionalDotCandidate (Call (Symbol "Pattern") [Symbol _, Call (Symbol "Blank") []]) = True
optionalDotCandidate _ = False

inputArgumentsParser :: Parser [Expr]
inputArgumentsParser =
  lexeme
    ( between
        (char '[' <* notFollowedBy (char '['))
        (char ']')
        (nestedInputExpressionParser `sepBy` symbolChar ',')
    )

partArgumentsParser :: Parser [Expr]
partArgumentsParser = do
  _ <- lexeme (try (string "[["))
  indices <- nestedInputExpressionParser `sepBy` symbolChar ','
  _ <- lexeme (try (string "]]"))
  pure indices

inputAtomParser :: Parser Expr
inputAtomParser = lexeme $ choice
  [ try numberParser
  , String <$> stringLiteralParser
  , listParser
  , try getParser
  , associationParser
  , percentHistoryParser
  , slotParser
  , blankShapeParser
  , Symbol <$> symbolParser
  , between (symbolChar '(') (symbolChar ')') nestedInputExpressionParser
  ]

getParser :: Parser Expr
getParser = do
  _ <- string "<<"
  fileName <- try contextualBareFileName <|> regularFileName
  pure (Call (Symbol "Get") [String fileName])
 where
  -- Get and Put use a context-sensitive filename token.  Only spaces and tabs,
  -- plus at most one line continuation, are skipped before scanning its broad
  -- path alphabet.  A plain newline or comment falls back to ordinary symbol
  -- tokenization, so @<<foo.wl@ and @<<\nfoo.wl@ intentionally parse
  -- differently just as they do in the Python reference.
  contextualBareFileName = do
    horizontalSpace
    _ <- optionMaybe lineContinuation
    horizontalSpace
    T.pack <$> many1 (satisfy isFileNameCharacter)
  regularFileName = ignored *> (stringLiteralParser <|> symbolParser)
  horizontalSpace = skipMany (void (oneOf " \t"))
  isFileNameCharacter character =
    isAlphaNum character
      || character `elem` ("_-*:/\\.`$!?~" :: String)

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
    <$> between
      (symbolChar '{')
      (symbolChar '}')
      (nestedInputExpressionParser `sepBy` symbolChar ',')

associationParser :: Parser Expr
associationParser = do
  _ <- operator "<|" ""
  entries <- nestedInputExpressionParser `sepBy` symbolChar ','
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

-- Parse either the canonical escaped spelling (\[Precedes]) or the direct
-- Unicode codepoint for any head in the complete named-infix catalog.  The
-- predicate lets precedence layers select only the heads they own without
-- duplicating the catalog in the grammar.
namedInfixOperatorParser :: (Text -> Bool) -> Parser Text
namedInfixOperatorParser accepted = lexeme (try escapedSpelling <|> try directSpelling)
 where
  escapedSpelling = try $ do
    _ <- string "\\["
    name <- T.pack <$> many1 (satisfy (/= ']'))
    _ <- char ']'
    case namedInfixOperatorHead name of
      Just headName | accepted headName -> pure headName
      _ -> unexpected "a named infix operator at this precedence"
  directSpelling = do
    character <- satisfy isNamedOperatorCharacter
    case namedInfixOperatorHeadForCharacter character of
      Just headName | accepted headName -> pure headName
      _ -> unexpected "a named infix operator at this precedence"

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

divideExpression :: Bool -> Expr -> Expr -> (Expr, Bool)
divideExpression isUngroupedTimes lhs rhs =
  case (isUngroupedTimes, lhs) of
    (True, Call (Symbol "Times") values@(_ : _)) ->
      let reciprocal = Call (Symbol "Power") [rhs, Integer (-1)]
          prefix = init values
          dividedFactor = Call (Symbol "Times") [last values, reciprocal]
       in (Call (Symbol "Times") (prefix <> [dividedFactor]), True)
    _ ->
      ( Call
          (Symbol "Times")
          [lhs, Call (Symbol "Power") [rhs, Integer (-1)]]
      , False
      )

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
  pure (Complex (canonicalComplexPart realPart) (canonicalComplexPart imaginaryPart))
canonicalCall expressionHead arguments' = pure (Call expressionHead arguments')

canonicalComplexPart :: Expr -> Expr
canonicalComplexPart expression = case expression of
  Call
    (Symbol "Times")
    [Integer numerator, Call (Symbol "Power") [Integer denominator, Integer (-1)]]
      | denominator /= 0 ->
          either (const expression) id (rational numerator denominator)
  _ -> expression

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
    fraction <- optionMaybe $ try $ do
      point <- char '.'
      digits <- T.pack <$> many (satisfy isDigit)
      if T.null digits then notFollowedBy (char '.') else pure ()
      pure (T.cons point digits)
    if T.null whole && maybe True (T.null . T.drop 1) fraction
      then unexpected "empty precision value"
      else pure (whole <> maybe "" id fraction)

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
ignored = skipMany (void (satisfy isSpace) <|> lineContinuation <|> wolframComment)

lineContinuation :: Parser ()
lineContinuation = void . try $ do
  _ <- char '\\'
  _ <- many (oneOf " \t")
  _ <- char '\n' <|> (char '\r' <* optionMaybe (char '\n'))
  pure ()

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
