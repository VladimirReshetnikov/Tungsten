{-# LANGUAGE OverloadedStrings #-}

-- | Immutable Wolfram expression values and their canonical structural view.
module Tungsten.Expression
  ( Expr (..)
  , SparseEntry (..)
  , ExpressionError (..)
  , rational
  , root
  , sparseArray
  , headExpr
  , arguments
  , isAtom
  , fullForm
  , inputForm
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import Tungsten.NamedCharacters (encodePrintableAscii, namedInfixOperatorEscape)
import Tungsten.WolframString (wlString)

-- | The kernel-free expression model.  Every constructor is immutable, and
-- arbitrary-sized 'Integer' values are retained without conversion through a
-- machine numeric type.
data Expr
  = Symbol !Text
  | Integer !Integer
  | Rational !Integer !Integer
  | Real !Text
  | Complex !Expr !Expr
  | String !Text
  | ByteArray !BS.ByteString
  | Call !Expr ![Expr]
  -- | Coefficients in ascending power order, a zero-based root index, and the
  -- Wolfram root-isolation method value.
  | Root ![Integer] !Integer !Integer
  | SparseArray ![Integer] ![SparseEntry] !Expr
  deriving (Eq, Show)

-- | One explicit, one-based element of a sparse array.
data SparseEntry = SparseEntry
  { sparseIndices :: ![Integer]
  , sparseValue :: !Expr
  }
  deriving (Eq, Show)

newtype ExpressionError = ExpressionError {expressionErrorMessage :: Text}
  deriving (Eq, Show)

-- | Construct a reduced rational with a positive denominator.
rational :: Integer -> Integer -> Either ExpressionError Expr
rational _ 0 = Left (ExpressionError "a rational denominator cannot be zero")
rational numerator denominator =
  let sign = if denominator < 0 then -1 else 1
      divisor = gcd numerator denominator
   in Right
        ( Rational
            (sign * (numerator `div` divisor))
            (abs denominator `div` divisor)
        )

-- | Construct a Wolfram algebraic root.  The index is zero-based, matching the
-- original Tungsten engine's in-memory representation.
root :: [Integer] -> Integer -> Integer -> Either ExpressionError Expr
root coefficients index method
  | length coefficients < 2 =
      Left (ExpressionError "Root requires a nonconstant polynomial")
  | last coefficients == 0 =
      Left (ExpressionError "Root requires a nonzero leading coefficient")
  | index < 0 = Left (ExpressionError "Root requires a nonnegative internal index")
  | otherwise = Right (Root coefficients index method)

-- | Construct a sparse array after checking its dimensions and explicit
-- one-based coordinates.
sparseArray :: [Integer] -> [SparseEntry] -> Expr -> Either ExpressionError Expr
sparseArray dimensions entries fill
  | null dimensions = Left (ExpressionError "SparseArray requires at least one dimension")
  | any (< 0) dimensions = Left (ExpressionError "SparseArray dimensions cannot be negative")
  | any invalidEntry entries =
      Left (ExpressionError "SparseArray entry indices do not match its dimensions")
  | Set.size (Set.fromList (map sparseIndices entries)) /= length entries =
      Left (ExpressionError "SparseArray explicit indices must be unique")
  | otherwise = Right (SparseArray dimensions entries fill)
 where
  invalidEntry (SparseEntry indices _) =
    length indices /= length dimensions
      || or (zipWith (\index dimension -> index < 1 || index > dimension) indices dimensions)

-- | The expression returned by Wolfram's structural @Head@ operation.
headExpr :: Expr -> Expr
headExpr expression = case expression of
  Symbol _ -> Symbol "Symbol"
  Integer _ -> Symbol "Integer"
  Rational _ _ -> Symbol "Rational"
  Real _ -> Symbol "Real"
  Complex _ _ -> Symbol "Complex"
  String _ -> Symbol "String"
  ByteArray _ -> Symbol "ByteArray"
  Call expressionHead _ -> expressionHead
  Root {} -> Symbol "Root"
  SparseArray {} -> Symbol "SparseArray"

-- | Structural arguments.  Sparse arrays and byte arrays remain compact atoms;
-- roots expose the same three arguments used by their FullForm projection.
arguments :: Expr -> [Expr]
arguments expression = case expression of
  Call _ values -> values
  Root coefficients index method ->
    [rootFunction coefficients, Integer (index + 1), Integer method]
  _ -> []

isAtom :: Expr -> Bool
isAtom expression = case expression of
  Call {} -> False
  Root {} -> False
  _ -> True

-- | Render the structural Wolfram @FullForm@ representation.
fullForm :: Expr -> Text
fullForm expression = case expression of
  Symbol name -> encodeSymbol name
  Integer value -> T.pack (show value)
  Rational numerator denominator ->
    apply "Rational" [T.pack (show numerator), T.pack (show denominator)]
  Real source -> source
  Complex realPart imaginaryPart ->
    apply "Complex" [fullForm realPart, fullForm imaginaryPart]
  String value -> wlString value
  ByteArray values -> apply "ByteArray" [wlString (base64Encode values)]
  Call expressionHead values -> apply (fullForm expressionHead) (map fullForm values)
  Root coefficients index method ->
    apply
      "Root"
      [ fullForm (rootFunction coefficients)
      , T.pack (show (index + 1))
      , T.pack (show method)
      ]
  SparseArray dimensions entries fill ->
    fullForm (sparseConstructor dimensions entries fill)

-- | Render the canonical Wolfram @InputForm@ surface syntax used by the
-- Python engine.  The precedence carried by 'formatInput' minimizes
-- parentheses around nested operators while preserving their grouping.
inputForm :: Expr -> Text
inputForm = formatInput precedenceLowest

precedenceAtom, precedenceCall, precedencePart, precedencePattern :: Int
precedencePatternTest, precedenceMessageName, precedencePostfixUnary :: Int
precedencePower, precedencePrefix, precedenceNonCommutativeTimes :: Int
precedenceTimes, precedencePlus, precedenceCompare, precedenceAnd :: Int
precedenceOr, precedenceAlternatives, precedenceStringExpression :: Int
precedenceNamedPattern, precedenceCondition, precedenceTwoWayRule :: Int
precedenceRule, precedenceReplace, precedenceMap, precedenceApply :: Int
precedenceComposition, precedenceAssignment, precedencePut :: Int
precedencePostfix, precedenceFunction, precedenceLowest :: Int
precedenceAtom = 1000
precedenceCall = 190
precedencePart = 190
precedencePattern = 185
precedencePatternTest = 184
precedenceMessageName = 183
precedencePostfixUnary = 175
precedencePower = 160
precedencePrefix = 150
precedenceNonCommutativeTimes = 145
precedenceTimes = 140
precedencePlus = 120
precedenceCompare = 100
precedenceAnd = 80
precedenceOr = 70
precedenceAlternatives = 65
precedenceStringExpression = 64
precedenceNamedPattern = 63
precedenceCondition = 62
precedenceTwoWayRule = 61
precedenceRule = 60
precedenceReplace = 50
precedenceMap = 45
precedenceApply = 44
precedenceComposition = 43
precedenceAssignment = 40
precedencePut = 35
precedencePostfix = 30
precedenceFunction = 10
precedenceLowest = 0

formatInput :: Int -> Expr -> Text
formatInput parentPrecedence expression =
  let (rendered, ownPrecedence) = formatInputExpression expression
   in if ownPrecedence < parentPrecedence
        then "(" <> rendered <> ")"
        else rendered

formatInputExpression :: Expr -> (Text, Int)
formatInputExpression expression = case expression of
  Symbol name -> (name, precedenceAtom)
  Integer value -> (T.pack (show value), precedenceAtom)
  Rational numerator denominator ->
    (T.pack (show numerator) <> "/" <> T.pack (show denominator), precedenceTimes)
  Real source -> (source, precedenceAtom)
  Complex realPart imaginaryPart -> (formatComplex realPart imaginaryPart, precedencePlus)
  String value -> (wlString value, precedenceAtom)
  ByteArray values ->
    (apply "ByteArray" [wlString (base64Encode values)], precedenceAtom)
  Call expressionHead values -> formatInputCall expressionHead values
  Root coefficients index method ->
    ( apply
        "Root"
        [ inputForm (rootFunction coefficients)
        , T.pack (show (index + 1))
        , T.pack (show method)
        ]
    , precedenceAtom
    )
  SparseArray dimensions entries fill ->
    (inputForm (sparseConstructor dimensions entries fill), precedenceAtom)

formatInputCall :: Expr -> [Expr] -> (Text, Int)
formatInputCall expressionHead values
  | Just shorthand <- formatSlotNameShorthand expressionHead values =
      (shorthand, precedenceAtom)
  | Just derivative <- formatDerivative (Call expressionHead values) =
      (derivative, precedencePostfixUnary)
  | otherwise = formatRegularInputCall expressionHead values

formatRegularInputCall :: Expr -> [Expr] -> (Text, Int)
formatRegularInputCall expressionHead@(Symbol name) values
  | Just shortName <- T.stripPrefix "System`" name =
      let shortHead = Symbol shortName
          formatted = formatRegularInputCall shortHead values
       in if formatted /= genericInputCall shortHead values
            then formatted
            else genericInputCall expressionHead values
formatRegularInputCall expressionHead values = case expressionHead of
  Symbol "List" ->
    ("{" <> T.intercalate ", " (map inputForm values) <> "}", precedenceAtom)
  Symbol "Association" ->
    ("<|" <> T.intercalate ", " (map inputForm values) <> "|>", precedenceAtom)
  Symbol headName
    | Just blank <- formatBlank headName values -> (blank, precedenceAtom)
  Symbol "Slot" -> case formatSlot values of
    Just slot -> (slot, precedenceAtom)
    Nothing -> genericInputCall expressionHead values
  Symbol "SlotSequence" -> case formatSlotSequence values of
    Just slot -> (slot, precedenceAtom)
    Nothing -> genericInputCall expressionHead values
  Symbol "Out" -> case formatOut values of
    Just out -> (out, precedenceAtom)
    Nothing -> genericInputCall expressionHead values
  Symbol "Pattern" -> case values of
    [name@(Symbol _), patternExpression] ->
      (formatPattern name patternExpression, precedencePattern)
    _ -> genericInputCall expressionHead values
  Symbol "PatternTest" -> case values of
    [patternExpression, test] ->
      ( formatInput precedencePatternTest patternExpression
          <> "?"
          <> formatInput (precedencePatternTest + 1) test
      , precedencePatternTest
      )
    _ -> genericInputCall expressionHead values
  Symbol "Optional" -> case values of
    [patternExpression] ->
      (formatInput precedencePattern patternExpression <> ".", precedencePattern)
    [patternExpression, defaultValue] ->
      ( formatInput precedenceNamedPattern patternExpression
          <> ":"
          <> formatInput precedenceNamedPattern defaultValue
      , precedenceNamedPattern
      )
    _ -> genericInputCall expressionHead values
  Symbol "Repeated" -> case values of
    [patternExpression] ->
      (formatInput precedencePostfix patternExpression <> "..", precedencePostfix)
    _ -> genericInputCall expressionHead values
  Symbol "RepeatedNull" -> case values of
    [patternExpression] ->
      (formatInput precedencePostfix patternExpression <> "...", precedencePostfix)
    _ -> genericInputCall expressionHead values
  Symbol "Condition" -> case values of
    [patternExpression, condition] ->
      ( formatInput precedenceCondition patternExpression
          <> " /; "
          <> formatInput (precedenceCondition + 1) condition
      , precedenceCondition
      )
    _ -> genericInputCall expressionHead values
  Symbol "Function" -> case values of
    [body] ->
      (formatInput (precedenceFunction + 1) body <> " &", precedenceFunction)
    [parameters, body] ->
      ( formatFunctionParameters parameters
          <> " |-> "
          <> formatInput precedenceFunction body
      , precedenceFunction
      )
    _ -> genericInputCall expressionHead values
  Symbol "Information" -> case formatInformation values of
    Just information -> (information, precedencePrefix)
    Nothing -> genericInputCall expressionHead values
  Symbol "Get" -> case values of
    [fileName]
      | Just renderedFileName <- formatFileName fileName ->
          ("<< " <> renderedFileName, precedencePrefix)
    _ -> genericInputCall expressionHead values
  Symbol "MessageName" -> case formatMessageName values of
    Just messageName -> (messageName, precedenceMessageName)
    Nothing -> genericInputCall expressionHead values
  Symbol headName
    | headName == "Put" || headName == "PutAppend" -> case formatPut headName values of
        Just putExpression -> (putExpression, precedencePut)
        Nothing -> genericInputCall expressionHead values
  Symbol headName
    | headName == "TagSet" || headName == "TagSetDelayed" || headName == "TagUnset" ->
        case formatTagSet headName values of
          Just tagSet -> (tagSet, precedenceAssignment)
          Nothing -> genericInputCall expressionHead values
  Symbol headName
    | Just operator <- postfixInputOperator headName -> case values of
        [value] ->
          ( formatInput precedencePostfixUnary value
              <> if headName == "Unset" then " " <> operator else operator
          , precedencePostfixUnary
          )
        _ -> genericInputCall expressionHead values
  Symbol headName
    | Just operator <- prefixInputOperator headName -> case values of
        [value] ->
          (operator <> formatInput precedencePostfixUnary value, precedencePostfixUnary)
        _ -> genericInputCall expressionHead values
  Symbol "Plus"
    | not (null values) -> (formatPlus values, precedencePlus)
  Symbol "Times"
    | not (null values) -> (formatTimes values, precedenceTimes)
  Symbol "Power" -> case values of
    [base, exponentValue] -> (formatPower base exponentValue, precedencePower)
    _ -> genericInputCall expressionHead values
  Symbol "Not" -> case values of
    [value] -> ("!" <> formatInput precedencePrefix value, precedencePrefix)
    _ -> genericInputCall expressionHead values
  Symbol "Span"
    | not (null values) -> (formatSpan values, precedenceFunction)
  Symbol "Part" -> case values of
    target : specifications ->
        ( formatInput precedencePart target
            <> "[["
            <> T.intercalate ", " (map inputForm specifications)
            <> "]]"
        , precedencePart
        )
    [] -> genericInputCall expressionHead values
  Symbol headName
    | Just (operator, operatorPrecedence) <- escapedInfixInputOperator headName
    , length values >= 2 ->
        ( T.intercalate
            (" " <> operator <> " ")
            (map (formatInput (operatorPrecedence + 1)) values)
        , operatorPrecedence
        )
  Symbol headName -> case infixInputOperator headName of
    Just operator
      | length values >= 2 ->
          ( formatInfix
              values
              (infixToken operator)
              (infixPrecedence operator)
              (infixRightAssociative operator)
              (infixSpaced operator)
          , infixPrecedence operator
          )
    _ -> genericInputCall expressionHead values
  _ -> genericInputCall expressionHead values

escapedInfixInputOperator :: Text -> Maybe (Text, Int)
escapedInfixInputOperator name = case name of
  "CirclePlus" -> Just ("\\[CirclePlus]", 125)
  "CircleTimes" -> Just ("\\[CircleTimes]", 142)
  "Diamond" -> Just ("\\[Diamond]", 144)
  _ -> fmap (\operator -> (operator, precedenceCompare)) (namedInfixOperatorEscape name)

formatBlank :: Text -> [Expr] -> Maybe Text
formatBlank headName values = do
  prefix <- case headName of
    "Blank" -> Just "_"
    "BlankSequence" -> Just "__"
    "BlankNullSequence" -> Just "___"
    _ -> Nothing
  case values of
    [] -> Just prefix
    [Symbol name] -> Just (prefix <> inputForm (Symbol name))
    _ -> Nothing

formatSlot :: [Expr] -> Maybe Text
formatSlot values = case values of
  [] -> Just "#"
  [Integer 1] -> Just "#"
  [Integer index] -> Just ("#" <> T.pack (show index))
  [String name]
    | isSimpleSymbolName name -> Just ("#" <> name)
  _ -> Nothing

formatSlotSequence :: [Expr] -> Maybe Text
formatSlotSequence values = case values of
  [] -> Just "##"
  [Integer 1] -> Just "##"
  [Integer index] -> Just ("##" <> T.pack (show index))
  _ -> Nothing

formatSlotNameShorthand :: Expr -> [Expr] -> Maybe Text
formatSlotNameShorthand expressionHead values = case (expressionHead, values) of
  (Call (Symbol "Slot") [Integer 1], [String name])
    | isSimpleSymbolName name -> Just ("#" <> name)
  _ -> Nothing

formatOut :: [Expr] -> Maybe Text
formatOut values = case values of
  [] -> Just "%"
  [Integer line]
    | line < 0 -> replicateIntegerText (abs line) "%"
  _ -> Nothing

formatPattern :: Expr -> Expr -> Text
formatPattern name patternExpression = case patternExpression of
  Call (Symbol headName) values
    | Just blank <- formatBlank headName values -> inputForm name <> blank
  _ -> inputForm name <> " : " <> formatInput precedenceNamedPattern patternExpression

formatDerivative :: Expr -> Maybe Text
formatDerivative expression = case expression of
  Call (Call (Symbol "Derivative") [Integer order]) [function]
    | order > 0 -> do
        primes <- replicateIntegerText order "'"
        pure (formatInput precedencePostfixUnary function <> primes)
  _ -> Nothing

formatInformation :: [Expr] -> Maybe Text
formatInformation values = case values of
  [ String name
    , Call (Symbol "Rule") [Symbol "LongForm", Symbol longForm]
    ] -> do
      prefix <- case longForm of
        "False" -> Just "?"
        "True" -> Just "??"
        _ -> Nothing
      renderedName <- formatFileName (String name)
      pure (prefix <> renderedName)
  _ -> Nothing

formatMessageName :: [Expr] -> Maybe Text
formatMessageName values = case values of
  base : firstTag : remainingTags -> do
    tags <- traverse formatMessageTag (firstTag : remainingTags)
    pure
      ( formatInput precedenceMessageName base
          <> T.concat ["::" <> tag | tag <- tags]
      )
  _ -> Nothing

formatMessageTag :: Expr -> Maybe Text
formatMessageTag expression = case expression of
  String tag
    | isSimpleSymbolName tag -> Just tag
    | otherwise -> Just (inputForm expression)
  Symbol _ -> Just (inputForm expression)
  _ -> Nothing

formatFileName :: Expr -> Maybe Text
formatFileName expression = case expression of
  String name
    | isSimpleFileName name -> Just name
    | otherwise -> Just (inputForm expression)
  Symbol _ -> Just (inputForm expression)
  _ -> Nothing

formatPut :: Text -> [Expr] -> Maybe Text
formatPut headName values = case values of
  [value, fileName] -> do
    renderedFileName <- formatFileName fileName
    let operator
          | headName == "PutAppend" = ">>>"
          | otherwise = ">>"
    pure
      ( formatInput precedencePut value
          <> " "
          <> operator
          <> " "
          <> renderedFileName
      )
  _ -> Nothing

formatTagSet :: Text -> [Expr] -> Maybe Text
formatTagSet headName values = case (headName, values) of
  ("TagUnset", [tag, target]) ->
    Just
      ( formatInput (precedenceAssignment + 1) tag
          <> " /: "
          <> formatInput (precedenceAssignment + 1) target
          <> " =."
      )
  ("TagSet", [tag, target, value]) -> Just (tagSet "=" tag target value)
  ("TagSetDelayed", [tag, target, value]) -> Just (tagSet ":=" tag target value)
  _ -> Nothing
 where
  tagSet operator tag target value =
    formatInput (precedenceAssignment + 1) tag
      <> " /: "
      <> formatInput (precedenceAssignment + 1) target
      <> " "
      <> operator
      <> " "
      <> formatInput precedenceAssignment value

postfixInputOperator :: Text -> Maybe Text
postfixInputOperator headName = case headName of
  "Increment" -> Just "++"
  "Decrement" -> Just "--"
  "Factorial" -> Just "!"
  "Factorial2" -> Just "!!"
  "Unset" -> Just "=."
  _ -> Nothing

prefixInputOperator :: Text -> Maybe Text
prefixInputOperator headName = case headName of
  "PreIncrement" -> Just "++"
  "PreDecrement" -> Just "--"
  _ -> Nothing

isSimpleSymbolName :: Text -> Bool
isSimpleSymbolName value = case T.uncons value of
  Nothing -> False
  Just (firstCharacter, remaining) ->
    isSymbolStart firstCharacter && T.all isSymbolContinue remaining
 where
  isSymbolStart character =
    character == '$'
      || character >= 'A' && character <= 'Z'
      || character >= 'a' && character <= 'z'
  isSymbolContinue character = isSymbolStart character || character >= '0' && character <= '9'

isSimpleFileName :: Text -> Bool
isSimpleFileName value =
  not (T.null value)
    && T.all
      (\character ->
         character == '$'
           || character == '_'
           || character == '.'
           || character == '/'
           || character == '\\'
           || character == '-'
           || character >= 'A' && character <= 'Z'
           || character >= 'a' && character <= 'z'
           || character >= '0' && character <= '9'
      )
      value

replicateIntegerText :: Integer -> Text -> Maybe Text
replicateIntegerText count value
  | count < 0 = Nothing
  | count > toInteger (maxBound :: Int) = Nothing
  | otherwise = Just (T.replicate (fromInteger count) value)

data InfixInputOperator = InfixInputOperator
  { infixToken :: !Text
  , infixPrecedence :: !Int
  , infixRightAssociative :: !Bool
  , infixSpaced :: !Bool
  }

infixInputOperator :: Text -> Maybe InfixInputOperator
infixInputOperator name = case name of
  "Equal" -> operator "==" precedenceCompare True True
  "Unequal" -> operator "!=" precedenceCompare True True
  "SameQ" -> operator "===" precedenceCompare True True
  "UnsameQ" -> operator "=!=" precedenceCompare True True
  "Less" -> operator "<" precedenceCompare True True
  "LessEqual" -> operator "<=" precedenceCompare True True
  "Greater" -> operator ">" precedenceCompare True True
  "GreaterEqual" -> operator ">=" precedenceCompare True True
  "And" -> operator "&&" precedenceAnd False True
  "Or" -> operator "||" precedenceOr False True
  "Alternatives" -> operator "|" precedenceAlternatives False True
  "StringExpression" -> operator "~~" precedenceStringExpression False False
  "TwoWayRule" -> operator "<->" precedenceTwoWayRule True True
  "Rule" -> operator "->" precedenceRule True True
  "RuleDelayed" -> operator ":>" precedenceRule True True
  "ReplaceAll" -> operator "/." precedenceReplace False True
  "ReplaceRepeated" -> operator "//." precedenceReplace False True
  "Map" -> operator "/@" precedenceMap False True
  "MapAll" -> operator "//@" precedenceMap False True
  "Apply" -> operator "@@" precedenceApply False True
  "MapApply" -> operator "@@@" precedenceApply False True
  "Composition" -> operator "@*" precedenceComposition True True
  "RightComposition" -> operator "/*" precedenceComposition True True
  "Set" -> operator "=" precedenceAssignment True True
  "SetDelayed" -> operator ":=" precedenceAssignment True True
  "UpSet" -> operator "^=" precedenceAssignment True True
  "UpSetDelayed" -> operator "^:=" precedenceAssignment True True
  "AddTo" -> operator "+=" precedenceAssignment True True
  "SubtractFrom" -> operator "-=" precedenceAssignment True True
  "TimesBy" -> operator "*=" precedenceAssignment True True
  "DivideBy" -> operator "/=" precedenceAssignment True True
  "NonCommutativeMultiply" -> operator "**" precedenceNonCommutativeTimes False True
  "Dot" -> operator "." precedenceTimes False True
  "StringJoin" -> operator "<>" precedencePlus False True
  _ -> Nothing
 where
  operator token precedence rightAssociative spaced =
    Just (InfixInputOperator token precedence rightAssociative spaced)

formatInfix :: [Expr] -> Text -> Int -> Bool -> Bool -> Text
formatInfix values operator precedence rightAssociative spaced =
  T.intercalate separator
    [ formatInput (operandPrecedence index) value
    | (index, value) <- zip [0 :: Int ..] values
    ]
 where
  separator
    | spaced = " " <> operator <> " "
    | otherwise = operator
  lastIndex = length values - 1
  operandPrecedence index
    | index > 0 && index < lastIndex = precedence + 1
    | rightAssociative && index == 0 = precedence + 1
    | not rightAssociative && index /= 0 = precedence + 1
    | otherwise = precedence

formatPlus :: [Expr] -> Text
formatPlus values = T.intercalate " " (zipWith formatTerm [0 :: Int ..] values)
 where
  formatTerm index value = case stripNegativeTerm value of
    Just positiveValue
      | index == 0 -> "-" <> formatInput precedencePrefix positiveValue
      | otherwise -> "- " <> formatInput (precedencePlus + 1) positiveValue
    Nothing
      | index == 0 -> formatInput precedencePlus value
      | otherwise -> "+ " <> formatInput (precedencePlus + 1) value

stripNegativeTerm :: Expr -> Maybe Expr
stripNegativeTerm (Call (Symbol "Times") (Integer (-1) : values)) = case values of
  [] -> Nothing
  [value] -> Just value
  _ -> Just (Call (Symbol "Times") values)
stripNegativeTerm _ = Nothing

formatTimes :: [Expr] -> Text
formatTimes values = case values of
  [numerator, Call (Symbol "Power") [denominator, Integer (-1)]] ->
    formatInput precedenceTimes numerator
      <> " / "
      <> formatInput (precedenceTimes + 1) denominator
  [Integer (-1)] -> "-Times[]"
  Integer (-1) : remaining
    | not (null remaining) ->
        let positiveProduct = case remaining of
              [value] -> value
              _ -> Call (Symbol "Times") remaining
         in "-" <> formatInput precedencePrefix positiveProduct
  _ ->
    T.intercalate
      " * "
      [ formatInput (precedenceTimes + if index == 0 then 0 else 1) value
      | (index, value) <- zip [0 :: Int ..] values
      ]

formatPower :: Expr -> Expr -> Text
formatPower base exponentValue =
  formatInput (precedencePower + 1) base
    <> "^"
    <> formattedExponent
 where
  formattedExponent = case exponentValue of
    Integer value
      | value < 0 -> "(" <> inputForm exponentValue <> ")"
    _ -> formatInput precedencePower exponentValue

formatSpan :: [Expr] -> Text
formatSpan values = case values of
  [Integer 1, Symbol "All"] -> ";;"
  [Integer 1, end] -> ";; " <> inputForm end
  [start, Symbol "All"] -> inputForm start <> " ;;"
  [start, end] -> inputForm start <> " ;; " <> inputForm end
  [start, end, step] ->
    inputForm start <> " ;; " <> inputForm end <> " ;; " <> inputForm step
  _ -> apply "Span" (map inputForm values)

formatFunctionParameters :: Expr -> Text
formatFunctionParameters expression = case expression of
  Call (Symbol "List") values ->
    "{" <> T.intercalate ", " (map inputForm values) <> "}"
  _ -> formatInput (precedenceFunction + 1) expression

genericInputCall :: Expr -> [Expr] -> (Text, Int)
genericInputCall expressionHead values =
  ( apply
      renderedHead
      (map inputForm values)
  , precedenceCall
  )
 where
  renderedHead = case formatDerivative expressionHead of
    Just _ -> inputForm expressionHead
    Nothing -> formatInput precedenceCall expressionHead

formatComplex :: Expr -> Expr -> Text
formatComplex realPart imaginaryPart
  | isExactZero realPart = formatImaginary imaginaryPart
  | Just positiveImaginary <- negateReal imaginaryPart =
      inputForm realPart <> " - " <> formatImaginary positiveImaginary
  | otherwise = inputForm realPart <> " + " <> formatImaginary imaginaryPart

formatImaginary :: Expr -> Text
formatImaginary expression
  | expression == Integer 1 = "I"
  | Rational numerator denominator <- expression
  , numerator == denominator = "I"
  | otherwise = inputForm expression <> "*I"

isExactZero :: Expr -> Bool
isExactZero (Integer value) = value == 0
isExactZero (Rational numerator _) = numerator == 0
isExactZero _ = False

negateReal :: Expr -> Maybe Expr
negateReal expression = case expression of
  Integer value
    | value < 0 -> Just (Integer (negate value))
  Rational numerator denominator
    | numerator * denominator < 0 -> Just (Rational (abs numerator) (abs denominator))
  Real source
    | Just positive <- T.stripPrefix "-" source
    , not (T.null positive) -> Just (Real positive)
  _ -> Nothing

apply :: Text -> [Text] -> Text
apply headText values = headText <> "[" <> T.intercalate ", " values <> "]"

rootFunction :: [Integer] -> Expr
rootFunction coefficients =
  Call (Symbol "Function") [Call (Symbol "Plus") (polynomialTerms coefficients)]

polynomialTerms :: [Integer] -> [Expr]
polynomialTerms coefficients =
  case concat (zipWith term [0 :: Integer ..] coefficients) of
    [] -> [Integer 0]
    terms -> terms
 where
  slot = Call (Symbol "Slot") [Integer 1]
  term _ 0 = []
  term 0 coefficient = [Integer coefficient]
  term powerIndex coefficient =
    let power =
          if powerIndex == 1
            then slot
            else Call (Symbol "Power") [slot, Integer powerIndex]
     in [ case coefficient of
            1 -> power
            -1 -> Call (Symbol "Times") [Integer (-1), power]
            _ -> Call (Symbol "Times") [Integer coefficient, power]
        ]

sparseConstructor :: [Integer] -> [SparseEntry] -> Expr -> Expr
sparseConstructor dimensions entries fill =
  Call (Symbol "SparseArray") arguments'
 where
  rules =
    Call
      (Symbol "List")
      [ Call
          (Symbol "Rule")
          [Call (Symbol "List") (map Integer indices), value]
      | SparseEntry indices value <- entries
      ]
  shape = Call (Symbol "List") (map Integer dimensions)
  arguments'
    | fill == Integer 0 = [rules, shape]
    | otherwise = [rules, shape, fill]

encodeSymbol :: Text -> Text
encodeSymbol = encodePrintableAscii

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
      ++ go rest
