{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Stateful Wolfram string-pattern matching shared by pure and session
-- evaluation.  The caller supplies expression evaluation, which lets
-- Condition, PatternTest, and replacement templates preserve session effects.
module Tungsten.StringPatterns
  ( StringFoundMatch (..)
  , StringPatternM
  , StringPatternSpec (..)
  , applyStringPatternSpecM
  , firstStringPatternMatchAtM
  , firstStringPatternMatchAtWithEndM
  , normalizeStringCasesSpecs
  , normalizeStringPatternSpecs
  , normalizeStringReplaceSpecs
  , runStringPatternM
  , stringPatternMatchesForSpecAtM
  ) where

import Control.Monad (filterM, foldM)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Array ((!))
import Data.Char
  ( GeneralCategory (..)
  , generalCategory
  , isAlpha
  , isAlphaNum
  , isDigit
  , isSpace
  , toLower
  )
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Text.Regex.TDFA (Regex)
import Text.Regex.TDFA.String (compile, execute)
import Text.Regex.TDFA (defaultCompOpt, defaultExecOpt)
import Tungsten.Expression
import Tungsten.SystemSymbols (normalizeSystemSymbolName)

type StringBindings = Map.Map Text Expr

type StringEvaluator monad = StringBindings -> Expr -> monad Expr

type StringPatternM monad = ExceptT Text monad

data StringPatternState = StringPatternState
  { stringStateEnd :: !Int
  , stringStateBindings :: !StringBindings
  }
  deriving (Eq, Show)

data StringPatternSpec = StringPatternSpec
  { stringSpecPattern :: !Expr
  , stringSpecTemplate :: !(Maybe Expr)
  , stringSpecDelayed :: !Bool
  }
  deriving (Eq, Show)

data StringFoundMatch = StringFoundMatch
  { stringMatchStart :: !Int
  , stringMatchEnd :: !Int
  , stringMatchBindings :: !StringBindings
  , stringMatchSpec :: !StringPatternSpec
  }
  deriving (Eq, Show)

runStringPatternM :: StringPatternM monad value -> monad (Either Text value)
runStringPatternM = runExceptT

normalizeStringCasesSpecs :: Expr -> [StringPatternSpec]
normalizeStringCasesSpecs = concatMap normalize . flattenList
 where
  normalize expression = case ruleView expression of
    Just (patternExpression, template, delayed) ->
      [StringPatternSpec patternExpression (Just template) delayed]
    Nothing -> [StringPatternSpec expression Nothing False]

normalizeStringPatternSpecs :: Expr -> [StringPatternSpec]
normalizeStringPatternSpecs =
  map (\patternExpression -> StringPatternSpec patternExpression Nothing False)
    . flattenList

normalizeStringReplaceSpecs
  :: Expr
  -> Either Text [StringPatternSpec]
normalizeStringReplaceSpecs expression =
  traverse requireRule (flattenList expression)
 where
  requireRule candidate = case ruleView candidate of
    Just (patternExpression, template, delayed) ->
      Right (StringPatternSpec patternExpression (Just template) delayed)
    Nothing -> Left "StringReplace expects a rule or a list of rules."

flattenList :: Expr -> [Expr]
flattenList (Call (Symbol listHead) values)
  | shortHead listHead == "List" = concatMap flattenList values
flattenList expression = [expression]

ruleView :: Expr -> Maybe (Expr, Expr, Bool)
ruleView (Call (Symbol ruleHead) [patternExpression, template])
  | shortHead ruleHead == "Rule" = Just (patternExpression, template, False)
  | shortHead ruleHead == "RuleDelayed" = Just (patternExpression, template, True)
ruleView _ = Nothing

firstStringPatternMatchAtM
  :: Monad monad
  => StringEvaluator monad
  -> Text
  -> Int
  -> [StringPatternSpec]
  -> StringPatternM monad (Maybe StringFoundMatch)
firstStringPatternMatchAtM evaluator source start = go
 where
  go = firstStringPatternMatchAtWithEndM evaluator source start Nothing

firstStringPatternMatchAtWithEndM
  :: Monad monad
  => StringEvaluator monad
  -> Text
  -> Int
  -> Maybe Int
  -> [StringPatternSpec]
  -> StringPatternM monad (Maybe StringFoundMatch)
firstStringPatternMatchAtWithEndM evaluator source start requiredEnd = go
 where
  go [] = pure Nothing
  go (specification : rest) = do
    matches <-
      stringPatternMatchesForSpecAtM
        evaluator
        source
        start
        specification
    let eligible = case requiredEnd of
          Nothing -> matches
          Just required ->
            [matched | matched <- matches, stringMatchEnd matched == required]
    case eligible of
      found : _ -> pure (Just found)
      [] -> go rest

stringPatternMatchesForSpecAtM
  :: Monad monad
  => StringEvaluator monad
  -> Text
  -> Int
  -> StringPatternSpec
  -> StringPatternM monad [StringFoundMatch]
stringPatternMatchesForSpecAtM evaluator source start specification = do
  states <-
    matchStringPatternStatesM
      evaluator
      (stringSpecPattern specification)
      source
      start
      Map.empty
      True
  pure
    [ StringFoundMatch
        { stringMatchStart = start
        , stringMatchEnd = stringStateEnd matched
        , stringMatchBindings = stringStateBindings matched
        , stringMatchSpec = specification
        }
    | matched <- states
    ]

applyStringPatternSpecM
  :: Monad monad
  => StringEvaluator monad
  -> Text
  -> StringFoundMatch
  -> StringPatternM monad (Maybe Expr)
applyStringPatternSpecM evaluator source found =
  case stringSpecTemplate specification of
    Nothing ->
      pure
        ( Just
            ( String
                ( T.take
                    (stringMatchEnd found - stringMatchStart found)
                    (T.drop (stringMatchStart found) source)
                )
            )
        )
    Just template ->
      evaluateTemplate template
 where
  specification = stringMatchSpec found
  bindings = stringMatchBindings found
  evaluateTemplate template = case template of
    Call (Symbol conditionHead) [body, condition]
      | stringSpecDelayed specification
      , shortHead conditionHead == "Condition" -> do
          result <- lift (evaluator bindings condition)
          if result == Symbol "True"
            then Just <$> lift (evaluator bindings body)
            else pure Nothing
    _ -> Just <$> lift (evaluator bindings template)

matchStringPatternStatesM
  :: Monad monad
  => StringEvaluator monad
  -> Expr
  -> Text
  -> Int
  -> StringBindings
  -> Bool
  -> StringPatternM monad [StringPatternState]
matchStringPatternStatesM evaluator originalPattern source start bindings preferLongest =
  case normalizeWhitespace originalPattern of
    String literal ->
      pure
        [ StringPatternState (start + T.length literal) bindings
        | literal `T.isPrefixOf` T.drop start source
        ]
    Symbol name -> matchSymbol name
    Call (Symbol originalHead) arguments' -> matchCall (shortHead originalHead) arguments'
    patternExpression -> unsupported patternExpression
 where
  sourceLength = T.length source
  state end current = StringPatternState end current

  matchSymbol originalName = case shortHead originalName of
    "Whitespace" ->
      matchStringPatternStatesM
        evaluator
        (Call (Symbol "Repeated") [Symbol "WhitespaceCharacter"])
        source
        start
        bindings
        preferLongest
    "StartOfString" -> pure [state start bindings | start == 0]
    "EndOfString" -> pure [state start bindings | start == sourceLength]
    "StartOfLine" -> pure [state start bindings | isStartOfLine source start]
    "EndOfLine" -> pure [state start bindings | isEndOfLine source start]
    "WordBoundary" -> pure [state start bindings | isWordBoundary source start]
    "NumberString" ->
      pure
        [ state end bindings
        | Just end <- [numberStringEnd source start]
        ]
    characterClass
      | characterClass `elem` stringCharacterClasses ->
          pure
            [ state (start + 1) bindings
            | Just character <- [characterAt source start]
            , characterMatchesSymbol characterClass character
            ]
    _ -> unsupported (Symbol originalName)

  matchCall headName arguments' = case headName of
    "Optional" -> case arguments' of
      inner : _ ->
        throwE
          ( "Unsupported Wolfram string-pattern form in the current Tungsten subset: "
              <> fullForm inner
              <> ".."
          )
      [] -> unsupported (Call (Symbol headName) arguments')
    "OptionsPattern" -> unsupported (Call (Symbol headName) arguments')
    "HoldPattern" -> case arguments' of
      [inner] -> recurse inner bindings preferLongest
      _ -> throwE "HoldPattern expects exactly one argument."
    "Longest" -> case arguments' of
      inner : rest
        | length rest <= 1 -> recurse inner bindings True
      _ -> throwE "Longest expects one or two arguments."
    "Shortest" -> case arguments' of
      inner : rest
        | length rest <= 1 -> recurse inner bindings False
      _ -> throwE "Shortest expects one or two arguments."
    "StringExpression" ->
      matchStringExpressionPartsM
        evaluator
        (concatMap flattenStringExpression arguments')
        source
        start
        bindings
        preferLongest
    "Alternatives" ->
      concat <$> traverse (\branch -> recurse branch bindings preferLongest) arguments'
    "Condition" -> case arguments' of
      [inner, condition] -> do
        states <- recurse inner bindings preferLongest
        filterM
          ( \matched -> do
              result <- lift (evaluator (stringStateBindings matched) condition)
              pure (result == Symbol "True")
          )
          states
      _ -> throwE "Condition expects exactly two arguments."
    "PatternTest" -> case arguments' of
      [inner, criterion] -> do
        states <- recurse inner bindings preferLongest
        filterM
          ( \matched ->
              stringPatternTestSucceedsM
                evaluator
                (stringStateBindings matched)
                criterion
                source
                start
                (stringStateEnd matched)
          )
          states
      _ -> throwE "PatternTest expects exactly two arguments."
    "Pattern" -> case arguments' of
      [Symbol name, inner] -> do
        states <- recurse inner bindings preferLongest
        pure
          [ state (stringStateEnd matched) updated
          | matched <- states
          , let value =
                  String
                    ( T.take
                        (stringStateEnd matched - start)
                        (T.drop start source)
                    )
          , let current = stringStateBindings matched
          , maybe True (== value) (Map.lookup name current)
          , let updated = Map.insert name value current
          ]
      [_, _] -> throwE "Pattern expects a symbol as its first argument."
      _ -> throwE "Pattern expects exactly two arguments."
    "Blank" -> case arguments' of
      [] -> pure [state (start + 1) bindings | start < sourceLength]
      _ -> unsupported (Call (Symbol headName) arguments')
    "BlankSequence" -> case arguments' of
      [] -> pure (variableWidthStates 1)
      _ -> unsupported (Call (Symbol headName) arguments')
    "BlankNullSequence" -> case arguments' of
      [] -> pure (variableWidthStates 0)
      _ -> unsupported (Call (Symbol headName) arguments')
    "Repeated" -> matchRepeatedM evaluator False arguments' source start bindings preferLongest
    "RepeatedNull" -> matchRepeatedM evaluator True arguments' source start bindings preferLongest
    "Except" -> matchSingleCharacterM evaluator (Call (Symbol headName) arguments') source start bindings
    "CharacterRange" -> matchSingleCharacterM evaluator (Call (Symbol headName) arguments') source start bindings
    "RegularExpression" -> matchRegularExpression arguments'
    "DatePattern" -> matchDatePatternM evaluator arguments' source start bindings preferLongest
    _ -> unsupported (Call (Symbol headName) arguments')

  recurse patternExpression current longest =
    matchStringPatternStatesM evaluator patternExpression source start current longest

  variableWidthStates minimumLength =
    [state end bindings | end <- orderedEnds minimumLength]

  orderedEnds minimumLength
    | preferLongest = [sourceLength, sourceLength - 1 .. start + minimumLength]
    | otherwise = [start + minimumLength .. sourceLength]

  matchRegularExpression = \case
    [String regexSource] -> do
      let (ignoreCase, rawRegex) =
            case T.stripPrefix "(?i)" regexSource of
              Just remainder -> (True, remainder)
              Nothing -> (False, regexSource)
          remaining = T.drop start source
          input = if ignoreCase then T.toLower remaining else remaining
          regexText = if ignoreCase then T.toLower rawRegex else rawRegex
      regex <- case compile defaultCompOpt defaultExecOpt ("^(" <> T.unpack regexText <> ")") of
        Left message -> throwE ("Invalid RegularExpression pattern: " <> T.pack message <> ".")
        Right value -> pure value
      result <- case execute (regex :: Regex) (T.unpack input) of
        Left message -> throwE ("Invalid RegularExpression pattern: " <> T.pack message <> ".")
        Right value -> pure value
      pure $ case result of
        Just matches ->
          let (_, matchLength) = matches ! 0
           in [state (start + matchLength) bindings]
        Nothing -> []
    _ -> throwE "RegularExpression expects exactly one string argument in string patterns."

  unsupported patternExpression =
    throwE
      ( "Unsupported Wolfram string-pattern form in the current Tungsten subset: "
          <> fullForm patternExpression
          <> "."
      )

matchStringExpressionPartsM
  :: Monad monad
  => StringEvaluator monad
  -> [Expr]
  -> Text
  -> Int
  -> StringBindings
  -> Bool
  -> StringPatternM monad [StringPatternState]
matchStringExpressionPartsM evaluator parts source start bindings preferLongest =
  foldM advance [StringPatternState start bindings] parts
 where
  advance states patternExpression = do
    following <- fmap concat $ traverse matchFrom states
    pure (orderStates preferLongest following)
   where
    matchFrom state =
      matchStringPatternStatesM
        evaluator
        patternExpression
        source
        (stringStateEnd state)
        (stringStateBindings state)
        preferLongest

matchRepeatedM
  :: Monad monad
  => StringEvaluator monad
  -> Bool
  -> [Expr]
  -> Text
  -> Int
  -> StringBindings
  -> Bool
  -> StringPatternM monad [StringPatternState]
matchRepeatedM evaluator allowsNull arguments' source start bindings preferLongest = do
  (inner, minimumCount, maximumCount) <- repetitionBounds allowsNull arguments'
  results <- recurse inner start 0 bindings minimumCount maximumCount
  pure (orderStates preferLongest results)
 where
  recurse inner position count current minimumCount maximumCount = do
    let completed = [StringPatternState position current | count >= minimumCount]
    if count >= maximumCount
      then pure completed
      else do
        states <-
          matchStringPatternStatesM
            evaluator
            inner
            source
            position
            current
            preferLongest
        following <- fmap concat $ traverse continue [matched | matched <- states, stringStateEnd matched /= position]
        pure (completed <> following)
   where
    continue matched =
      recurse
        inner
        (stringStateEnd matched)
        (count + 1)
        (stringStateBindings matched)
        minimumCount
        maximumCount

repetitionBounds
  :: Monad monad
  => Bool
  -> [Expr]
  -> StringPatternM monad (Expr, Int, Int)
repetitionBounds allowsNull = \case
  [inner] -> pure (inner, if allowsNull then 0 else 1, stringInfinity)
  [inner, specification] -> do
    let defaultMinimum = if allowsNull then 0 else 1
    (minimumCount, maximumCount) <- case specification of
      Integer value -> (,) defaultMinimum <$> repetitionBound value
      Symbol infinity
        | shortHead infinity == "Infinity" -> pure (defaultMinimum, stringInfinity)
      Call (Symbol listHead) [Integer value]
        | shortHead listHead == "List" -> do
            count <- repetitionBound value
            pure (count, count)
      Call (Symbol listHead) [Integer low, Integer high]
        | shortHead listHead == "List" ->
            (,) <$> repetitionBound low <*> repetitionBound high
      Call (Symbol listHead) [Integer low, Symbol infinity]
        | shortHead listHead == "List"
        , shortHead infinity == "Infinity" ->
            (,stringInfinity) <$> repetitionBound low
      _ -> throwE ("Unsupported " <> repetitionName <> " repetition specification.")
    pure (inner, minimumCount, maximumCount)
  _ -> throwE (repetitionName <> " expects one or two arguments in string patterns.")
 where
  repetitionName = if allowsNull then "RepeatedNull" else "Repeated"
  repetitionBound value
    | value < 0 = throwE (repetitionName <> " expects non-negative repetition bounds.")
    | value > fromIntegral stringInfinity = pure stringInfinity
    | otherwise = pure (fromIntegral value)

matchSingleCharacterM
  :: Monad monad
  => StringEvaluator monad
  -> Expr
  -> Text
  -> Int
  -> StringBindings
  -> StringPatternM monad [StringPatternState]
matchSingleCharacterM evaluator patternExpression source start bindings =
  case characterAt source start of
    Nothing -> pure []
    Just character -> do
      matched <- matchCharacterPatternM evaluator character patternExpression bindings
      pure [StringPatternState (start + 1) current | current <- matched]

matchCharacterPatternM
  :: Monad monad
  => StringEvaluator monad
  -> Char
  -> Expr
  -> StringBindings
  -> StringPatternM monad [StringBindings]
matchCharacterPatternM evaluator character originalPattern bindings =
  case normalizeWhitespace originalPattern of
    String literal -> pure [bindings | literal == T.singleton character]
    Symbol originalName
      | shortHead originalName `elem` stringCharacterClasses ->
          pure
            [bindings | characterMatchesSymbol (shortHead originalName) character]
      | otherwise -> unsupported
    Call (Symbol originalHead) arguments' -> matchCall (shortHead originalHead) arguments'
    _ -> unsupported
 where
  matchCall headName arguments' = case headName of
    "List" -> concat <$> traverse (\branch -> recurse branch bindings) arguments'
    "Alternatives" -> concat <$> traverse (\branch -> recurse branch bindings) arguments'
    "HoldPattern" -> case arguments' of
      [inner] -> recurse inner bindings
      _ -> throwE "HoldPattern expects exactly one argument."
    "Longest" -> case arguments' of
      inner : rest | length rest <= 1 -> recurse inner bindings
      _ -> throwE "Longest expects one or two arguments."
    "Shortest" -> case arguments' of
      inner : rest | length rest <= 1 -> recurse inner bindings
      _ -> throwE "Shortest expects one or two arguments."
    "Condition" -> case arguments' of
      [inner, condition] -> do
        matches <- recurse inner bindings
        filterM
          ( \current -> do
              result <- lift (evaluator current condition)
              pure (result == Symbol "True")
          )
          matches
      _ -> throwE "Condition expects exactly two arguments."
    "PatternTest" -> case arguments' of
      [inner, criterion] -> do
        matches <- recurse inner bindings
        filterM
          (\current -> characterPredicateM evaluator current criterion character)
          matches
      _ -> throwE "PatternTest expects exactly two arguments."
    "Pattern" -> case arguments' of
      [Symbol name, inner] -> do
        matches <- recurse inner bindings
        let value = String (T.singleton character)
        pure
          [ Map.insert name value current
          | current <- matches
          , maybe True (== value) (Map.lookup name current)
          ]
      [_, _] -> throwE "Pattern expects a symbol as its first argument."
      _ -> throwE "Pattern expects exactly two arguments."
    "Blank" -> case arguments' of
      [] -> pure [bindings]
      _ -> unsupported
    "CharacterRange" -> case arguments' of
      [String lower, String upper]
        | T.length lower == 1
        , T.length upper == 1 ->
            pure
              [ bindings
              | T.head lower <= character
              , character <= T.head upper
              ]
      _ ->
        throwE
          "CharacterRange currently expects one-character string bounds."
    "Except" -> case arguments' of
      [disallowed] -> except disallowed (Call (Symbol "Blank") [])
      [disallowed, allowed] -> except disallowed allowed
      _ -> throwE "Except expects one or two arguments in string patterns."
    _ -> unsupported

  except disallowed allowed = do
    if not (singleCharacterPattern disallowed)
      then throwE "String-pattern Except expects a single-character disallowed pattern."
      else pure ()
    if not (singleCharacterPattern allowed)
      then throwE "String-pattern Except expects a single-character allowed pattern."
      else pure ()
    allowedMatches <- recurse allowed bindings
    fmap concat $ traverse retainUnlessDisallowed allowedMatches
   where
    retainUnlessDisallowed current = do
      rejected <- recurse disallowed current
      pure [current | null rejected]

  recurse patternExpression current =
    matchCharacterPatternM evaluator character patternExpression current
  unsupported =
    throwE
      ( "Unsupported Wolfram string-pattern form in the current Tungsten subset: "
          <> fullForm originalPattern
          <> "."
      )

stringPatternTestSucceedsM
  :: Monad monad
  => StringEvaluator monad
  -> StringBindings
  -> Expr
  -> Text
  -> Int
  -> Int
  -> StringPatternM monad Bool
stringPatternTestSucceedsM evaluator bindings criterion source start end =
  and <$> traverse (characterPredicateM evaluator bindings criterion) characters
 where
  characters = T.unpack (T.take (end - start) (T.drop start source))

characterPredicateM
  :: Monad monad
  => StringEvaluator monad
  -> StringBindings
  -> Expr
  -> Char
  -> StringPatternM monad Bool
characterPredicateM evaluator bindings criterion character =
  case criterion of
    Symbol name
      | shortHead name == "DigitQ" -> pure (isDigit character)
      | shortHead name == "LetterQ" -> pure (isAlpha character)
    _ -> do
      result <-
        lift
          ( evaluator
              bindings
              (Call criterion [String (T.singleton character)])
          )
      pure (result == Symbol "True")

matchDatePatternM
  :: Monad monad
  => StringEvaluator monad
  -> [Expr]
  -> Text
  -> Int
  -> StringBindings
  -> Bool
  -> StringPatternM monad [StringPatternState]
matchDatePatternM evaluator arguments' source start bindings preferLongest = do
  (elements, separator) <- case arguments' of
    [Call (Symbol listHead) values]
      | shortHead listHead == "List", not (null values) ->
          (,) <$> traverse requireElement values <*> pure Nothing
    [Call (Symbol listHead) values, separatorExpression]
      | shortHead listHead == "List", not (null values) ->
          (,) <$> traverse requireElement values <*> pure (Just separatorExpression)
    _ -> throwE "DatePattern expects a date-element list and an optional separator."
  states <- foldM (advance separator) [StringPatternState start bindings] (zip [0 :: Int ..] elements)
  pure (orderStates preferLongest states)
 where
  requireElement (String value)
    | value `elem` supportedDateElements = pure value
    | otherwise =
        throwE ("DatePattern does not support date element \"" <> value <> "\".")
  requireElement _ = throwE "DatePattern date elements must be strings."

  advance separator states (index, element) = fmap concat $ traverse advanceState states
   where
    advanceState current = do
      separated <-
        if index == 0
          then pure [current]
          else case separator of
            Nothing -> pure (defaultDateSeparators current)
            Just patternExpression ->
              matchStringPatternStatesM
                evaluator
                patternExpression
                source
                (stringStateEnd current)
                (stringStateBindings current)
                preferLongest
      pure
        [ StringPatternState end (stringStateBindings separatedState)
        | separatedState <- separated
        , end <- dateElementEnds element source (stringStateEnd separatedState)
        ]

  defaultDateSeparators current =
    [ StringPatternState (stringStateEnd current + 1) (stringStateBindings current)
    | Just character <- [characterAt source (stringStateEnd current)]
    , character `elem` ("/-:." :: String)
    ]

dateElementEnds :: Text -> Text -> Int -> [Int]
dateElementEnds element source start = case element of
  "Year" -> numericEnds 1 4 (const True)
  "Quarter" -> numericEnds 1 1 (\value -> value >= 1 && value <= 4)
  "Month" -> numericEnds 1 2 (\value -> value >= 1 && value <= 12)
  "Day" -> numericEnds 1 2 (\value -> value >= 1 && value <= 31)
  "Hour" -> numericEnds 1 2 (\value -> value >= 0 && value <= 23)
  "Minute" -> numericEnds 1 2 (\value -> value >= 0 && value <= 59)
  "Second" -> numericEnds 1 2 (\value -> value >= 0 && value <= 59)
  "AMPM" -> namedEnds ["AM", "PM", "A.M.", "P.M."]
  "MonthName" -> namedEnds monthNames
  "DayName" -> namedEnds dayNames
  _ -> []
 where
  numericEnds minimumWidth maximumWidth valid =
    [ start + width
    | width <- [maximumWidth, maximumWidth - 1 .. minimumWidth]
    , let fragment = T.take width (T.drop start source)
    , T.length fragment == width
    , T.all isDigit fragment
    , Just value <- [readInteger fragment]
    , valid value
    ]
  namedEnds names =
    [ start + T.length candidate
    | candidate <- names
    , T.toCaseFold candidate `T.isPrefixOf` T.toCaseFold (T.drop start source)
    ]

monthNames :: [Text]
monthNames =
  [ "January", "Jan", "February", "Feb", "March", "Mar", "April", "Apr"
  , "May", "June", "Jun", "July", "Jul", "August", "Aug"
  , "September", "Sept", "Sep", "October", "Oct", "November", "Nov"
  , "December", "Dec"
  ]

dayNames :: [Text]
dayNames =
  [ "Monday", "Mon", "Tuesday", "Tue", "Wednesday", "Wed"
  , "Thursday", "Thu", "Friday", "Fri", "Saturday", "Sat"
  , "Sunday", "Sun"
  ]

supportedDateElements :: [Text]
supportedDateElements =
  [ "Year", "Quarter", "Month", "MonthName", "Day", "DayName"
  , "Hour", "AMPM", "Minute", "Second"
  ]

readInteger :: Text -> Maybe Integer
readInteger source = case reads (T.unpack source) of
  [(value, "")] -> Just value
  _ -> Nothing

numberStringEnd :: Text -> Int -> Maybe Int
numberStringEnd source start = do
  let rest0 = T.drop start source
      (signWidth, rest1) = case T.uncons rest0 of
        Just (character, following) | character `elem` ("+-" :: String) -> (1, following)
        _ -> (0, rest0)
      whole = T.takeWhile isDigit rest1
      rest2 = T.drop (T.length whole) rest1
      (dotWidth, fraction, rest3) = case T.uncons rest2 of
        Just ('.', following) ->
          let digits = T.takeWhile isDigit following
           in (1, digits, T.drop (T.length digits) following)
        _ -> (0, "", rest2)
      mantissaWidth = T.length whole + dotWidth + T.length fraction
  if T.null whole && T.null fraction
    then Nothing
    else
      let (exponentWidth, _) = exponentSuffix rest3
       in Just (start + signWidth + mantissaWidth + exponentWidth)
 where
  exponentSuffix remaining =
    case T.uncons remaining of
      Just (marker, afterMarker)
        | marker `elem` ("eE" :: String) -> exponentDigits 1 afterMarker
      _ -> case T.stripPrefix "*^" remaining of
        Just afterMarker -> exponentDigits 2 afterMarker
        Nothing -> (0, remaining)
  exponentDigits markerWidth remaining =
    let (signWidth, unsigned) = case T.uncons remaining of
          Just (character, following) | character `elem` ("+-" :: String) -> (1, following)
          _ -> (0, remaining)
        digits = T.takeWhile isDigit unsigned
     in if T.null digits
          then (0, remaining)
          else (markerWidth + signWidth + T.length digits, T.drop (T.length digits) unsigned)

singleCharacterPattern :: Expr -> Bool
singleCharacterPattern originalPattern = case normalizeWhitespace originalPattern of
  String value -> T.length value == 1
  Symbol name -> shortHead name `elem` stringCharacterClasses
  Call (Symbol originalHead) arguments' -> case shortHead originalHead of
    "List" -> all singleCharacterPattern arguments'
    "Alternatives" -> not (null arguments') && all singleCharacterPattern arguments'
    "Blank" -> null arguments'
    "CharacterRange" -> length arguments' == 2
    "HoldPattern" -> oneInner
    "Longest" -> oneOrTwoInner
    "Shortest" -> oneOrTwoInner
    "PatternTest" -> twoInner
    "Pattern" -> length arguments' == 2 && singleCharacterPattern (arguments' !! 1)
    "Condition" -> twoInner
    "Except" -> case arguments' of
      [inner] -> singleCharacterPattern inner
      _ -> False
    _ -> False
   where
    oneInner = case arguments' of
      [inner] -> singleCharacterPattern inner
      _ -> False
    oneOrTwoInner = case arguments' of
      [inner] -> singleCharacterPattern inner
      [inner, _] -> singleCharacterPattern inner
      _ -> False
    twoInner = case arguments' of
      [inner, _] -> singleCharacterPattern inner
      _ -> False
  _ -> False

normalizeWhitespace :: Expr -> Expr
normalizeWhitespace (Symbol name)
  | shortHead name == "Whitespace" =
      Call (Symbol "Repeated") [Symbol "WhitespaceCharacter"]
normalizeWhitespace expression = expression

flattenStringExpression :: Expr -> [Expr]
flattenStringExpression (Call (Symbol headName) values)
  | shortHead headName == "StringExpression" = concatMap flattenStringExpression values
flattenStringExpression expression = [normalizeWhitespace expression]

orderStates :: Bool -> [StringPatternState] -> [StringPatternState]
orderStates preferLongest =
  sortBy
    ( \left right ->
        if preferLongest
          then compare (stringStateEnd right) (stringStateEnd left)
          else compare (stringStateEnd left) (stringStateEnd right)
    )

characterAt :: Text -> Int -> Maybe Char
characterAt source index
  | index < 0 || index >= T.length source = Nothing
  | otherwise = Just (T.index source index)

stringCharacterClasses :: [Text]
stringCharacterClasses =
  [ "DigitCharacter"
  , "HexadecimalCharacter"
  , "LetterCharacter"
  , "PunctuationCharacter"
  , "WhitespaceCharacter"
  , "WordCharacter"
  ]

characterMatchesSymbol :: Text -> Char -> Bool
characterMatchesSymbol symbolName character = case symbolName of
  "DigitCharacter" -> isDigit character
  "HexadecimalCharacter" ->
    isDigit character || toLower character `elem` ("abcdef" :: String)
  "LetterCharacter" -> isAlpha character
  "PunctuationCharacter" -> isPunctuation character
  "WhitespaceCharacter" -> isSpace character
  "WordCharacter" -> isAlphaNum character || character == '_'
  _ -> False

isPunctuation :: Char -> Bool
isPunctuation character = generalCategory character `elem`
  [ ConnectorPunctuation
  , DashPunctuation
  , OpenPunctuation
  , ClosePunctuation
  , InitialQuote
  , FinalQuote
  , OtherPunctuation
  ]

isWordBoundary :: Text -> Int -> Bool
isWordBoundary source position =
  maybe False isWordCharacter (characterAt source (position - 1))
    /= maybe False isWordCharacter (characterAt source position)
 where
  isWordCharacter character = isAlphaNum character || character == '_'

isStartOfLine :: Text -> Int -> Bool
isStartOfLine source position =
  position == 0 || characterAt source (position - 1) == Just '\n'

isEndOfLine :: Text -> Int -> Bool
isEndOfLine source position =
  position == T.length source
    || characterAt source position `elem` [Just '\n', Just '\r']

shortHead :: Text -> Text
shortHead name = maybe name id (normalizeSystemSymbolName name)

stringInfinity :: Int
stringInfinity = 1000000
