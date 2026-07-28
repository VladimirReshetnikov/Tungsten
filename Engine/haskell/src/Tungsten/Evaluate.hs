{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Conservative, kernel-free evaluation of Wolfram expression trees.
--
-- Supported built-ins reduce deterministically.  Unknown or unsupported forms
-- remain symbolic, which makes partial evaluation safe for automation clients.
module Tungsten.Evaluate
  ( EvaluationError (..)
  , LevelBounds (..)
  , PathSelector (..)
  , PatternPathRecord (..)
  , PatternRecord (..)
  , canonicalCompare
  , collectPatternPathRecords
  , collectPatternRecords
  , collectPositionPathRecords
  , deleteAtPath
  , evaluate
  , exactRangeValues
  , formatMachineReal
  , instantiateFunctionCall
  , instantiateFunctionCallWithHead
  , instantiatePatternMatch
  , instantiatePatternMatchWith
  , instantiatePatternMatchManyWith
  , instantiatePatternMatchManyWithAttributes
  , levelMatches
  , matchesPattern
  , normalizeEvaluatedCall
  , normalizeLevelSpec
  , operationPositionPaths
  , pathExpression
  , rebuildWithSplicing
  , reduceEvaluatedCall
  , replaceAtPath
  , selectAtPath
  , selectionLimit
  , sortOperationPaths
  , substituteNamedSymbols
  ) where

import Control.Monad ((<=<), foldM)
import Data.Bits ((.|.), shiftL, shiftR)
import qualified Data.ByteString as BS
import Data.Char (chr, isDigit, ord, toUpper)
import Data.Functor.Identity (Identity (..))
import Data.List (permutations, sort, sortBy, transpose)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import Foreign.C.Types (CDouble (..))
import Text.Read (readMaybe)
import Tungsten.Expression
import qualified Tungsten.NumericAlgebra as NumericAlgebra
import qualified Tungsten.PolynomialAlgebra as PolynomialAlgebra
import qualified Tungsten.StringPatterns as SP
import Tungsten.SystemSymbols
  ( SymbolAttribute (..)
  , isSystemSymbol
  , normalizeSystemSymbolName
  , systemSymbolAttributes
  )
import qualified Tungsten.TextualForms as TextualForms

-- GHC's pure Double atan2 differs from CPython's C-library result by up to a
-- few ulps on some quadrants.  Tungsten's JSON contract preserves the exact
-- machine-real spelling, so use the same C ABI operation as the reference.
foreign import ccall unsafe "atan2" cAtan2 :: CDouble -> CDouble -> CDouble

pythonAtan2 :: Double -> Double -> Double
pythonAtan2 imaginaryPart realPart =
  realToFrac
    (cAtan2 (realToFrac imaginaryPart) (realToFrac realPart))

newtype EvaluationError = EvaluationError {evaluationErrorMessage :: Text}
  deriving (Eq, Show)

textualReduction :: Either Text Expr -> Either EvaluationError Expr
textualReduction = either (Left . EvaluationError) Right

-- | Evaluate an expression to a fixed point, with a depth guard for malformed
-- self-referential transformations.
evaluate :: Expr -> Either EvaluationError Expr
evaluate = evaluateAt 0

evaluateAt :: Int -> Expr -> Either EvaluationError Expr
evaluateAt depth expression
  | depth > 1024 = Left (EvaluationError "the evaluation recursion limit was exceeded")
  | otherwise = case expression of
      Symbol name
        | systemHeadIn ["I"] name ->
            Right (Complex (Integer 0) (Integer 1))
      Call (Symbol headName) _
        | systemHeadIn ["HoldComplete", "Unevaluated"] headName ->
            Right expression
      Call (Symbol headName) arguments'
        | systemHeadIn ["MakeBoxes", "MakeExpression"] headName ->
            reducePureCallForDispatch (Call (Symbol headName) arguments')
      Call (Symbol ruleHead) (leftHandSide : heldArguments)
        | systemHeadIn ["RuleDelayed"] ruleHead -> do
            evaluatedLeft <- evaluateAt (depth + 1) leftHandSide
            Right
              ( normalizeEvaluatedCall
                  (Symbol ruleHead)
                  (evaluatedLeft : heldArguments)
              )
      Call (Symbol ruleHead) []
        | systemHeadIn ["RuleDelayed"] ruleHead -> Right expression
      Call (Symbol headName) arguments'
        | systemHeadIn
            [ "Hold"
            , "HoldForm"
            , "HoldPattern"
            , "SetDelayed"
            , "Condition"
            ]
            headName ->
            Right (normalizeEvaluatedCall (Symbol headName) arguments')
      -- Function holds its arguments, but Sequence still participates in the
      -- enclosing argument-list normalization before the function is called.
      Call (Symbol functionHead) arguments'
        | systemHeadIn ["Function"] functionHead ->
            Right (normalizeEvaluatedCall (Symbol functionHead) arguments')
      Call (Symbol "Table") _ -> Right expression
      Call (Symbol "Do") _ -> Right expression
      Call (Symbol "For") _ -> Right expression
      Call (Symbol "While") _ -> Right expression
      Call (Symbol "Sum") _ -> Right expression
      Call (Symbol "Product") _ -> Right expression
      Call (Symbol "Catch") _ -> Right expression
      Call (Symbol "Throw") _ -> Right expression
      Call (Symbol "Break") _ -> Right expression
      Call (Symbol "Continue") _ -> Right expression
      Call (Symbol "Return") _ -> Right expression
      Call (Symbol headName) _
        | systemHeadIn ["Label"] headName -> Right expression
      Call (Symbol "OwnValues") _ -> Right expression
      Call (Symbol "DownValues") _ -> Right expression
      Call (Symbol "Module") _ -> Right expression
      Call (Symbol "With") _ -> Right expression
      Call (Symbol "Block") _ -> Right expression
      Call (Symbol "InheritedBlock") _ -> Right expression
      Call (Symbol "Internal`InheritedBlock") _ -> Right expression
      Call (Symbol headName) arguments'
        | systemHeadIn ["Which"] headName ->
            evaluateWhich depth arguments'
      Call (Symbol headName) arguments'
        | systemHeadIn ["Switch"] headName ->
            evaluateSwitch depth arguments'
      Call (Symbol headName) arguments'
        | systemHeadIn ["Piecewise"] headName ->
            evaluatePiecewise depth arguments'
      Call (Symbol headName) arguments'
        | systemHeadIn ["ReleaseHold"] headName ->
            evaluateReleaseHold depth arguments'
      Call (Symbol headName) arguments'
        | systemHeadIn ["Inactive"] headName ->
            evaluateInactive depth headName arguments'
      Call (Symbol headName) arguments'
        | systemHeadIn ["Activate"] headName ->
            evaluateActivate depth arguments'
      Call (Symbol "If") arguments' -> evaluateIf depth arguments'
      Call (Symbol "And") arguments' -> evaluateAnd depth arguments'
      Call (Symbol "Or") arguments' -> evaluateOr depth arguments'
      Call expressionHead arguments' -> do
        evaluatedHead <- evaluateAt (depth + 1) expressionHead
        case evaluatedHead of
          Symbol associationHead
            | associationHead == "Association" ->
                reduceCall (Call evaluatedHead arguments')
            | associationHead == "System`Association" ->
                Right
                  ( Call
                      evaluatedHead
                      (filter (/= Symbol "Nothing") arguments')
                  )
          _ -> do
            evaluatedArguments <- traverse (evaluateAt (depth + 1)) arguments'
            let evaluatedCall = normalizeEvaluatedCall evaluatedHead evaluatedArguments
            threaded <- threadPureListableCall depth evaluatedCall
            case threaded of
              Just result -> Right result
              Nothing -> do
                reduced <- reducePureCallForDispatch evaluatedCall
                -- Some Python reducers deliberately return a final structural value:
                -- Sqrt preserves its raw nested Times shape for negative composite
                -- radicands, while Level exposes selected held subexpressions without
                -- evaluating them again.
                if reduced == evaluatedCall || preservesFinalReducerResult evaluatedHead
                  then Right reduced
                  else evaluateAt (depth + 1) reduced
      _ -> Right expression

threadPureListableCall :: Int -> Expr -> Either EvaluationError (Maybe Expr)
threadPureListableCall depth (Call expressionHead values)
  | staticSystemHeadHasAttribute Listable expressionHead = do
      rows <- pureListableArgumentRows values
      case rows of
        Nothing -> Right Nothing
        Just argumentRows -> do
          results <-
            traverse
              (evaluateAt (depth + 1) . Call expressionHead)
              argumentRows
          Right (Just (evaluatedList results))
threadPureListableCall _ _ = Right Nothing

staticSystemHeadHasAttribute :: SymbolAttribute -> Expr -> Bool
staticSystemHeadHasAttribute attribute (Symbol name) =
  isSystemSymbol name
    && maybe False (Set.member attribute) (systemSymbolAttributes name)
staticSystemHeadHasAttribute _ _ = False

pureListableArgumentRows :: [Expr] -> Either EvaluationError (Maybe [[Expr]])
pureListableArgumentRows values = case listLengths of
  [] -> Right Nothing
  firstLength : remainingLengths
    | all (== firstLength) remainingLengths ->
        Right
          ( Just
              [ [ case value of
                    Call (Symbol listHead) elements
                      | systemHeadIn ["List"] listHead -> elements !! index
                    scalar -> scalar
                | value <- values
                ]
              | index <- [0 .. firstLength - 1]
              ]
          )
    | otherwise ->
        Left
          ( EvaluationError
              "Listable Function arguments have incompatible list lengths."
          )
 where
  listLengths =
    [ length elements
    | Call (Symbol listHead) elements <- values
    , systemHeadIn ["List"] listHead
    ]

-- | Construct an ordinary evaluated call after applying the transparent
-- argument normalization shared by Wolfram heads.  Each enclosing call gets
-- one pass: nested calls have already normalized their own arguments.
normalizeEvaluatedCall :: Expr -> [Expr] -> Expr
normalizeEvaluatedCall expressionHead values =
  Call expressionHead retained
 where
  spliced
    | suppressesSequences expressionHead = values
    | otherwise = concatMap spliceArgument values
  retained
    | expressionHeadIsAny ["Association", "List"] =
        filter (/= Symbol "Nothing") spliced
    | otherwise = spliced
  spliceArgument = \case
    Call (Symbol sequenceHead) sequenceValues
      | systemHeadIn ["Sequence"] sequenceHead -> sequenceValues
    Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues]
      | systemHeadIn ["Splice"] spliceHead
      , systemHeadIn ["List"] listHead
      , expressionHead == Symbol "List" -> spliceValues
    Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues, target]
      | systemHeadIn ["Splice"] spliceHead
      , systemHeadIn ["List"] listHead
      , target == expressionHead -> spliceValues
    value -> [value]
  expressionHeadIsAny names = case expressionHead of
    Symbol name -> systemHeadIn names name
    _ -> False

suppressesSequences :: Expr -> Bool
suppressesSequences (Symbol name) =
  systemHeadIn
    [ "HoldComplete"
    , "Print"
    , "Rule"
    , "RuleDelayed"
    , "SetDelayed"
    , "Unevaluated"
    ]
    name
suppressesSequences _ = False

evaluateWhich :: Int -> [Expr] -> Either EvaluationError Expr
evaluateWhich depth arguments'
  | null arguments' || odd (length arguments') =
      Left (EvaluationError "Which expects condition-value pairs.")
  | otherwise = select arguments'
 where
  select [] = Right (Symbol "Null")
  select (condition : value : remaining) = do
    evaluatedCondition <- evaluateAt (depth + 1) condition
    case evaluatedCondition of
      Symbol "True" -> evaluateAt (depth + 1) value
      Symbol "False" -> select remaining
      _ ->
        Right
          ( Call
              (Symbol "Which")
              (evaluatedCondition : value : remaining)
          )
  select _ = Left (EvaluationError "Which expects condition-value pairs.")

evaluateSwitch :: Int -> [Expr] -> Either EvaluationError Expr
evaluateSwitch depth arguments'
  | length arguments' < 3 || even (length arguments') =
      Left
        ( EvaluationError
            "Switch expects an expression followed by form-value pairs."
        )
  | subject : formValues <- arguments' = do
      evaluatedSubject <- evaluateAt (depth + 1) subject
      select evaluatedSubject formValues formValues
  | otherwise =
      Left
        ( EvaluationError
            "Switch expects an expression followed by form-value pairs."
        )
 where
  select subject original [] =
    Right (Call (Symbol "Switch") (subject : original))
  select subject original (form : value : remaining)
    | matchesPattern subject form = evaluateAt (depth + 1) value
    | otherwise = select subject original remaining
  select subject original _ =
    Right (Call (Symbol "Switch") (subject : original))

evaluatePiecewise :: Int -> [Expr] -> Either EvaluationError Expr
evaluatePiecewise depth = \case
  [casesExpression] -> evaluateCases casesExpression Nothing
  [casesExpression, defaultExpression] ->
    evaluateCases casesExpression (Just defaultExpression)
  _ ->
    Left
      ( EvaluationError
          "Piecewise expects a case list and an optional default value."
      )
 where
  evaluateCases casesExpression defaultExpression = case casesExpression of
    Call (Symbol listHead) cases
      | systemHeadIn ["List"] listHead ->
          select [] cases defaultExpression
    _ ->
      Left
        ( EvaluationError
            "Piecewise expects its first argument to be a list of {value, condition} pairs."
        )

  select retained [] defaultExpression = do
    defaultValue <- case defaultExpression of
      Just value -> evaluateAt (depth + 1) value
      Nothing -> Right (Integer 0)
    Right
      ( if null retained
          then defaultValue
          else piecewiseResult (reverse retained) defaultValue
      )
  select retained (item : remaining) defaultExpression = case item of
    Call (Symbol listHead) [value, condition]
      | systemHeadIn ["List"] listHead -> do
          evaluatedCondition <- evaluateAt (depth + 1) condition
          case evaluatedCondition of
            Symbol "True" -> do
              selectedValue <- evaluateAt (depth + 1) value
              Right
                ( if null retained
                    then selectedValue
                    else piecewiseResult (reverse retained) selectedValue
                )
            Symbol "False" -> select retained remaining defaultExpression
            _ -> do
              evaluatedValue <- evaluateAt (depth + 1) value
              select
                ((evaluatedValue, evaluatedCondition) : retained)
                remaining
                defaultExpression
    _ ->
      Left
        ( EvaluationError
            "Piecewise cases must be two-element lists of {value, condition}."
        )

  piecewiseResult retained defaultValue =
    Call
      (Symbol "Piecewise")
      [ Call
          (Symbol "List")
          [ Call (Symbol "List") [value, condition]
          | (value, condition) <- retained
          ]
      , defaultValue
      ]

evaluateReleaseHold :: Int -> [Expr] -> Either EvaluationError Expr
evaluateReleaseHold depth = \case
  [argument] -> do
    evaluated <- evaluateAt (depth + 1) argument
    case evaluated of
      Call (Symbol heldHead) heldArguments
        | heldHead `elem` ["Hold", "HoldComplete", "HoldForm", "Unevaluated"] ->
            evaluateAt
              (depth + 1)
              ( case heldArguments of
                  [single] -> single
                  values -> Call (Symbol "Sequence") values
              )
      _ -> Right evaluated
  _ -> Left (EvaluationError "ReleaseHold expects exactly one argument.")

evaluateInactive
  :: Int
  -> Text
  -> [Expr]
  -> Either EvaluationError Expr
evaluateInactive depth originalHead = \case
  [argument] -> do
    prepared <- case argument of
      Call (Symbol evaluateHead) [payload]
        | systemHeadIn ["Evaluate"] evaluateHead ->
            case payload of
              Call (Symbol unevaluatedHead) [_]
                | systemHeadIn ["Unevaluated"] unevaluatedHead ->
                    Right payload
              _ -> evaluateAt (depth + 1) payload
      _ -> Right argument
    case normalizeEvaluatedCall (Symbol "Inactive") [prepared] of
      Call _ [target]
        | inactiveAtomicTarget target -> Right target
        | otherwise -> Right (Call (Symbol originalHead) [target])
      _ ->
        Left
          ( EvaluationError
              "Inactive expects exactly one argument after Sequence splicing."
          )
  _ -> Left (EvaluationError "Inactive expects exactly one argument.")

inactiveAtomicTarget :: Expr -> Bool
inactiveAtomicTarget = \case
  Integer _ -> True
  Rational _ _ -> True
  Real _ -> True
  Complex _ _ -> True
  String _ -> True
  ByteArray _ -> True
  _ -> False

evaluateActivate :: Int -> [Expr] -> Either EvaluationError Expr
evaluateActivate depth = \case
  [source] -> do
    evaluatedSource <- evaluateAt (depth + 1) source
    evaluateAt (depth + 1) (activateInactiveTree Nothing evaluatedSource)
  [source, patternExpression] -> do
    evaluatedSource <- evaluateAt (depth + 1) source
    evaluatedPattern <- evaluateAt (depth + 1) patternExpression
    evaluateAt
      (depth + 1)
      (activateInactiveTree (Just evaluatedPattern) evaluatedSource)
  _ ->
    Left
      ( EvaluationError
          "Activate expects an expression and an optional pattern."
      )

activateInactiveTree :: Maybe Expr -> Expr -> Expr
activateInactiveTree patternExpression expression = case expression of
  Call wrapperHead@(Symbol inactiveHead) [target]
    | systemHeadIn ["Inactive"] inactiveHead ->
        let activatedTarget = activateInactiveTree patternExpression target
         in if maybe True (matchesPattern target) patternExpression
              then activatedTarget
              else Call wrapperHead [activatedTarget]
  Call expressionHead values ->
    Call
      (activateInactiveTree patternExpression expressionHead)
      (map (activateInactiveTree patternExpression) values)
  _ -> expression

evaluateIf :: Int -> [Expr] -> Either EvaluationError Expr
evaluateIf depth = \case
  condition : trueBranch : remaining -> do
    evaluatedCondition <- evaluateAt (depth + 1) condition
    case evaluatedCondition of
      Symbol "True" -> evaluateAt (depth + 1) trueBranch
      Symbol "False" -> case remaining of
        falseBranch : _ -> evaluateAt (depth + 1) falseBranch
        [] -> Right (Symbol "Null")
      _ -> Right (Call (Symbol "If") (evaluatedCondition : trueBranch : remaining))
  arguments' -> Right (Call (Symbol "If") arguments')

evaluateAnd :: Int -> [Expr] -> Either EvaluationError Expr
evaluateAnd depth = go []
 where
  go retained [] = Right $ case retained of
    [] -> Symbol "True"
    [single] -> single
    values -> Call (Symbol "And") values
  go retained (value : rest) = do
    evaluated <- evaluateAt (depth + 1) value
    case evaluated of
      Symbol "False" -> Right (Symbol "False")
      Symbol "True" -> go retained rest
      _ -> go (retained <> [evaluated]) rest

evaluateOr :: Int -> [Expr] -> Either EvaluationError Expr
evaluateOr depth = go []
 where
  go retained [] = Right $ case retained of
    [] -> Symbol "False"
    [single] -> single
    values -> Call (Symbol "Or") values
  go retained (value : rest) = do
    evaluated <- evaluateAt (depth + 1) value
    case evaluated of
      Symbol "True" -> Right (Symbol "True")
      Symbol "False" -> go retained rest
      _ -> go (retained <> [evaluated]) rest

reduceCall :: Expr -> Either EvaluationError Expr
reduceCall expression = case expression of
  Call sparse@SparseArray {} values ->
    reduceSparseArrayProperty sparse values
  Call failure@(Call (Symbol failureHead) _) values
    | systemHeadIn ["Failure"] failureHead ->
        reduceFailureApplication failure values
  Call (Call functionHead@(Symbol functionName) functionArguments) values
    | systemHeadIn ["Function"] functionName ->
        applyFunctionWithHead functionHead functionArguments values
  Call (Call (Symbol "KeySelect") [criterion]) [association] ->
    reduceBuiltin "KeySelect" [association, criterion]
  Call (Call (Symbol "SortBy") [function]) [subject] ->
    reduceBuiltin "SortBy" [subject, function]
  Call (Call (Symbol "ReverseSortBy") [function]) [subject] ->
    reduceBuiltin "ReverseSortBy" [subject, function]
  Call (Call (Symbol "Comap") [functions]) values -> case values of
    [subject] -> reduceComap False [functions, subject]
    _ ->
      Left
        ( EvaluationError
            "Comap[functions] expects exactly one argument when used as an operator."
        )
  Call (Call (Symbol "ComapApply") [functions]) values -> case values of
    [subject] -> reduceComap True [functions, subject]
    _ ->
      Left
        ( EvaluationError
            "ComapApply[functions] expects exactly one argument when used as an operator."
        )
  Call (Call (Symbol "MapAll") [function]) values -> case values of
    [subject] -> reduceMapAll [function, subject]
    _ ->
      Left
        ( EvaluationError
            "MapAll[f] expects exactly one argument when used as an operator."
        )
  Call (Call (Symbol "MapApply") [function]) values -> case values of
    [subject] -> reduceMapApply [function, subject]
    _ ->
      Left
        ( EvaluationError
            "MapApply[f] expects exactly one argument when used as an operator."
        )
  Call (Call (Symbol "Select") [criterion]) [subject] ->
    reduceBuiltin "Select" [subject, criterion]
  Call (Call (Symbol "Discard") [criterion]) [subject] ->
    reduceBuiltin "Discard" [subject, criterion]
  Call (Call (Symbol "StringContainsQ") [patternExpression]) [subject] ->
    reduceBuiltin "StringContainsQ" [subject, patternExpression]
  Call (Call (Symbol "StringMatchQ") [patternExpression]) [subject] ->
    reduceBuiltin "StringMatchQ" [subject, patternExpression]
  Call (Call (Symbol "StringFreeQ") [patternExpression]) [subject] ->
    reduceBuiltin "StringFreeQ" [subject, patternExpression]
  Call (Call (Symbol "StringStartsQ") [patternExpression]) [subject] ->
    reduceBuiltin "StringStartsQ" [subject, patternExpression]
  Call (Call (Symbol "StringEndsQ") [patternExpression]) [subject] ->
    reduceBuiltin "StringEndsQ" [subject, patternExpression]
  Call (Call (Symbol "StringPosition") [patternExpression]) [subject] ->
    reduceBuiltin "StringPosition" [subject, patternExpression]
  Call (Symbol headName) values -> reduceBuiltin headName values
  _ -> Right expression

-- Explicit System heads share their bare reducer while retaining qualified
-- spelling whenever the reduction remains structural.  Direct bare calls do
-- not need this projection, and Global heads intentionally stay inert.
reducePureCallForDispatch :: Expr -> Either EvaluationError Expr
reducePureCallForDispatch expression =
  case pureReducerDispatchView expression of
    Nothing -> reduceCall expression
    Just (dispatched, restore) -> restore <$> reduceCall dispatched

pureReducerDispatchView :: Expr -> Maybe (Expr, Expr -> Expr)
pureReducerDispatchView expression = case expression of
  Call (Symbol originalHead) values
    | isSystemSymbol originalHead
    , Just shortName <- normalizeSystemSymbolName originalHead
    , originalHead /= shortName ->
        let barrierName = pureReducerBarrierName shortName expression
            dispatchedValues =
              map (shieldPureReducerArgument shortName barrierName) values
            restore =
              restorePureReducerBarrier barrierName shortName
                . restorePureQualifiedHead originalHead shortName
         in Just (Call (Symbol shortName) dispatchedValues, restore)
  Call (Call (Symbol originalHead) operatorArguments) values
    | isSystemSymbol originalHead
    , Just shortName <- normalizeSystemSymbolName originalHead
    , originalHead /= shortName ->
        Just
          ( Call
              (Call (Symbol shortName) operatorArguments)
              values
          , restorePureQualifiedOperatorHead originalHead shortName
          )
  _ -> Nothing

pureReducerBarrierName :: Text -> Expr -> Text
pureReducerBarrierName shortName expression = choose 0
 where
  baseName = "Tungsten`Private`QualifiedDispatchBarrier$" <> shortName
  choose suffix =
    let candidate =
          if suffix == (0 :: Integer)
            then baseName
            else baseName <> "$" <> T.pack (show suffix)
     in if pureExpressionContainsSymbol candidate expression
          then choose (suffix + 1)
          else candidate

pureExpressionContainsSymbol :: Text -> Expr -> Bool
pureExpressionContainsSymbol target = \case
  Symbol name -> name == target
  Call expressionHead values ->
    pureExpressionContainsSymbol target expressionHead
      || any (pureExpressionContainsSymbol target) values
  Complex realPart imaginaryPart ->
    pureExpressionContainsSymbol target realPart
      || pureExpressionContainsSymbol target imaginaryPart
  SparseArray _ entries fill ->
    any
      (\(SparseEntry _ value) -> pureExpressionContainsSymbol target value)
      entries
      || pureExpressionContainsSymbol target fill
  _ -> False

shieldPureReducerArgument :: Text -> Text -> Expr -> Expr
shieldPureReducerArgument shortName barrierName = \case
  Call (Symbol nestedHead) values
    | nestedHead == shortName -> Call (Symbol barrierName) values
  value -> value

restorePureReducerBarrier :: Text -> Text -> Expr -> Expr
restorePureReducerBarrier barrierName shortName = go
 where
  go = \case
    Symbol name
      | name == barrierName -> Symbol shortName
    Call expressionHead values ->
      let restoredHead = case expressionHead of
            Symbol name
              | name == barrierName -> Symbol shortName
            _ -> go expressionHead
       in Call restoredHead (map go values)
    Complex realPart imaginaryPart -> Complex (go realPart) (go imaginaryPart)
    SparseArray dimensions entries fill ->
      SparseArray
        dimensions
        [ SparseEntry indices (go value)
        | SparseEntry indices value <- entries
        ]
        (go fill)
    value -> value

restorePureQualifiedHead :: Text -> Text -> Expr -> Expr
restorePureQualifiedHead qualifiedName shortName = \case
  Call (Symbol resultHead) values
    | resultHead == shortName -> Call (Symbol qualifiedName) values
  result -> result

restorePureQualifiedOperatorHead :: Text -> Text -> Expr -> Expr
restorePureQualifiedOperatorHead qualifiedName shortName = \case
  Call (Call (Symbol resultHead) operatorArguments) values
    | resultHead == shortName ->
        Call (Call (Symbol qualifiedName) operatorArguments) values
  result -> result

preservesFinalReducerResult :: Expr -> Bool
preservesFinalReducerResult = \case
  Symbol headName -> systemHeadIn ["Sqrt", "Level"] headName
  _ -> False

-- | Reduce one call whose head and arguments have already been evaluated and
-- normalized by the session evaluator.  Unlike 'evaluate', this does not
-- recursively revisit children or chase the reducer result to a fixed point.
reduceEvaluatedCall :: Expr -> Either EvaluationError Expr
reduceEvaluatedCall = reduceCall

reduceBuiltin :: Text -> [Expr] -> Either EvaluationError Expr
reduceBuiltin headName values = case headName of
  "Rational" -> Right (reduceRationalConstructor values)
  "Complex" -> Right (reduceComplexConstructor values)
  "Re" -> Right (reduceComplexComponent "Re" values)
  "Im" -> Right (reduceComplexComponent "Im" values)
  "ReIm" -> Right (reduceReIm values)
  "Arg" -> Right (reduceArg values)
  "Conjugate" -> Right (reduceConjugate values)
  "Plus" -> reduceSparseArithmetic "Plus" values
  "Times" -> reduceSparseArithmetic "Times" values
  "Power" -> Right (reducePower values)
  "Factorial" -> Right (reduceFactorial values)
  "Factorial2" -> Right (reduceFactorial2 values)
  "Abs" -> Right (reduceAbs values)
  "Sign" -> Right (reduceSign values)
  "Floor" -> Right (reduceRounding RoundFloor headName values)
  "Ceiling" -> Right (reduceRounding RoundCeiling headName values)
  "Round" -> Right (reduceRounding RoundNearest headName values)
  "IntegerPart" -> Right (reduceRounding RoundIntegerPart headName values)
  "FractionalPart" -> Right (reduceRounding RoundFractionalPart headName values)
  "Clip" -> reduceClip values
  "Sqrt" -> Right (reduceSqrt values)
  "Not" -> Right (reduceNot values)
  "Equal" -> Right (reduceEquality True values)
  "Unequal" -> Right (reduceEquality False values)
  "SameQ" -> Right (boolean (allEqual values))
  "UnsameQ" -> Right (boolean (allDistinct values))
  "Less" -> Right (reduceOrdering (== LT) headName values)
  "LessEqual" -> Right (reduceOrdering (/= GT) headName values)
  "Greater" -> Right (reduceOrdering (== GT) headName values)
  "GreaterEqual" -> Right (reduceOrdering (/= LT) headName values)
  "Inequality" -> Right (reduceInequality values)
  "Head" -> Right (unary headName headExpr values)
  "Length" -> case values of
    [value] -> Right (expressionLength value)
    _ -> Left (EvaluationError "Length expects exactly one argument.")
  "Depth" -> Right (unary headName (Integer . fromIntegral . expressionDepth) values)
  "Dimensions" -> reduceDimensions values
  "ArrayDepth" -> reduceArrayDepth values
  "ArrayQ" -> reduceArrayQ values
  "SparseArray" -> reduceSparseArray values
  "SparseArrayQ" -> Right (unary headName (boolean . isSparseArray) values)
  "ArrayRules" -> reduceArrayRules values
  "AtomQ" -> Right (unary headName (boolean . isAtom) values)
  "ListQ" -> Right (unary headName (boolean . hasHead "List") values)
  "Association" -> Right (reduceAssociation values)
  "AssociationQ" -> Right (unary headName (boolean . isAssociation) values)
  "Identity" -> Right (unary headName id values)
  "IntegerQ" -> Right (unary headName (boolean . isInteger) values)
  "MachineIntegerQ" -> Right (transparentUnaryPredicate headName isMachineInteger values)
  "MachineNumberQ" -> Right (transparentUnaryPredicate headName isMachineNumber values)
  "NumberQ" -> Right (transparentUnaryPredicate headName isNumericValue values)
  "NumericQ" -> Right (unary headName (boolean . isNumericValue) values)
  "ExactNumberQ" -> Right (transparentUnaryPredicate headName isExactNumber values)
  "InexactNumberQ" -> Right (transparentUnaryPredicate headName isInexactNumber values)
  "RealValuedNumberQ" -> Right (transparentUnaryPredicate headName isRealValuedNumber values)
  "TrueQ" -> Right (unary headName (boolean . isTrueSymbol) values)
  "StringQ" -> Right (unary headName (boolean . isString) values)
  "FailureQ" -> Right (unary headName (boolean . isFailureQValue) values)
  "MissingQ" -> Right (unary headName (boolean . isMissingValue) values)
  "ByteArray" -> reduceByteArray values
  "ByteArrayQ" -> Right (unary headName (boolean . isByteArray) values)
  "Characters" -> reduceCharacters values
  "ToCharacterCode" -> reduceToCharacterCode values
  "FromCharacterCode" -> reduceFromCharacterCode values
  "StringToByteArray" -> reduceStringToByteArray values
  "ByteArrayToString" -> reduceByteArrayToString values
  "BaseEncode" -> textualReduction (TextualForms.baseEncodeExpr values)
  "BaseDecode" -> textualReduction (TextualForms.baseDecodeExpr values)
  "ToString" -> textualReduction (TextualForms.toStringExpr values)
  "ToExpression" -> textualReduction (TextualForms.toExpressionExpr values)
  "ToBoxes" -> textualReduction (TextualForms.toBoxesExpr values)
  "MakeBoxes" -> textualReduction (TextualForms.makeBoxesExpr values)
  "MakeExpression" -> textualReduction (TextualForms.makeExpressionExpr values)
  "StripBoxes" -> textualReduction (TextualForms.stripBoxesExpr values)
  "SyntaxQ" -> textualReduction (TextualForms.syntaxQExpr values)
  "SyntaxLength" -> textualReduction (TextualForms.syntaxLengthExpr values)
  "ExportString" -> textualReduction (TextualForms.exportStringExpr values)
  "ImportString" -> textualReduction (TextualForms.importStringExpr values)
  "ExportByteArray" -> textualReduction (TextualForms.exportByteArrayExpr values)
  "ImportByteArray" -> textualReduction (TextualForms.importByteArrayExpr values)
  "StringLength" -> reduceStringLength values
  "StringTake" -> reduceStringTakeDrop True values
  "StringDrop" -> reduceStringTakeDrop False values
  "StringJoin" -> reduceStringJoin values
  "StringInsert" -> reduceStringInsert values
  "StringReverse" -> reduceStringUnary "StringReverse" T.reverse values
  "ToUpperCase" -> reduceStringUnary "ToUpperCase" T.toUpper values
  "ToLowerCase" -> reduceStringUnary "ToLowerCase" T.toLower values
  "Capitalize" -> reduceStringUnary "Capitalize" capitalizeText values
  "StringRepeat" -> reduceStringRepeat values
  "StringPadLeft" -> reduceStringPad True values
  "StringPadRight" -> reduceStringPad False values
  "StringSplit" -> reduceStringSplit values
  "StringRiffle" -> reduceStringRiffle values
  "StringTrim" -> reduceStringTrim values
  "StringCount" -> reduceStringCount values
  "StringPosition" -> reduceStringPosition values
  "StringContainsQ" -> reduceStringPredicate StringContains values
  "StringMatchQ" -> reduceStringPredicate StringMatches values
  "StringFreeQ" -> reduceStringPredicate StringFree values
  "StringStartsQ" -> reduceStringPredicate StringStarts values
  "StringEndsQ" -> reduceStringPredicate StringEnds values
  "StringCases" -> reduceStringCases values
  "StringReplace" -> reduceStringReplace values
  "EvenQ" -> Right (reduceParity True headName values)
  "OddQ" -> Right (reduceParity False headName values)
  "First" -> Right (reduceFirstLast True headName values)
  "Last" -> Right (reduceFirstLast False headName values)
  "Rest" -> Right (reduceRestMost True headName values)
  "Most" -> Right (reduceRestMost False headName values)
  "Part" -> reducePart values
  "Extract" -> reduceExtract values
  "Level" -> reduceLevel values
  "Keys" -> reduceKeys values
  "Values" -> reduceValues values
  "Normal" -> reduceNormal values
  "Lookup" -> reduceLookup values
  "KeyExistsQ" -> reduceKeyExistsQ headName values
  "KeyMemberQ" -> reduceKeyExistsQ headName values
  "KeyTake" -> reduceKeyTakeDrop True values
  "KeyDrop" -> reduceKeyTakeDrop False values
  "KeySelect" -> reduceKeySelect values
  "KeyMap" -> reduceKeyMap values
  "KeyValueMap" -> reduceKeyValueMap values
  "AssociationThread" -> reduceAssociationThread values
  "AssociationMap" -> reduceAssociationMap values
  "KeySort" -> reduceKeySort values
  "Merge" -> reduceMerge values
  "GroupBy" -> reduceGroupBy values
  "GatherBy" -> reduceGatherBy values
  "Gather" -> reduceGather values
  "KeyComplement" -> reduceKeyComplement values
  "KeyUnion" -> reduceKeyUnion values
  "KeyIntersection" -> reduceKeyIntersection values
  "Tally" -> reduceTally values
  "Counts" -> reduceCounts values
  "Catenate" -> reduceCatenate values
  "Differences" -> reduceDifferences values
  "Riffle" -> reduceRiffle values
  "AllTrue" -> reduceTruthCollection "AllTrue" and values
  "AnyTrue" -> reduceTruthCollection "AnyTrue" or values
  "NoneTrue" -> reduceTruthCollection "NoneTrue" (not . or) values
  "ContainsAll" -> reduceContains "ContainsAll" containsAll values
  "ContainsAny" -> reduceContains "ContainsAny" containsAny values
  "ContainsNone" -> reduceContains "ContainsNone" (\left right -> not (containsAny left right)) values
  "ContainsExactly" -> reduceContains "ContainsExactly" containsExactly values
  "ContainsOnly" -> reduceContainsOnly values
  "DeleteAdjacentDuplicates" -> reduceDeleteAdjacentDuplicates values
  "DeleteDuplicates" -> reduceDeleteDuplicates values
  "DeleteDuplicatesBy" -> reduceDeleteDuplicatesBy values
  "DuplicateFreeQ" -> reduceDuplicateFreeQ values
  "Split" -> reduceSplit values
  "SplitBy" -> reduceSplitBy values
  "Subsequences" -> reduceSubsequences values
  "CountsBy" -> reduceCountsBy values
  "Subsets" -> reduceSubsets values
  "Permutations" -> reducePermutations values
  "Permute" -> reducePermute values
  "PermutationCycles" -> reducePermutationCycles values
  "PermutationList" -> reducePermutationList values
  "PermutationOrder" -> reducePermutationOrder values
  "PadLeft" -> reducePad True values
  "PadRight" -> reducePad False values
  "Min" -> Right (reduceMinMax True headName values)
  "Max" -> Right (reduceMinMax False headName values)
  "Mean" -> reduceMean values
  "Median" -> reduceMedian values
  "Variance" -> reduceVariance values
  "StandardDeviation" -> reduceStandardDeviation values
  "Norm" -> reduceNorm values
  "MinMax" -> reduceMinMaxPair values
  "RankedMin" -> reduceRankedExtremum False values
  "RankedMax" -> reduceRankedExtremum True values
  "Mode" -> reduceMode values
  "CountDistinct" -> reduceCountDistinct values
  "Ratios" -> reduceRatios values
  "Subdivide" -> reduceSubdivide values
  "Quantile" -> reduceQuantile values
  "Quartiles" -> reduceQuartiles values
  "BinCounts" -> reduceBins False values
  "BinLists" -> reduceBins True values
  "Order" -> Right (reduceOrder values)
  "OrderedQ" -> reduceOrderedQ values
  "Ordering" -> reduceOrderingIndices values
  "Sort" -> reduceSort False values
  "ReverseSort" -> reduceSort True values
  "AlphabeticSort" -> reduceTextSort False values
  "NumericalSort" -> reduceTextSort True values
  "LexicographicOrder" -> reduceLexicographicOrder values
  "LexicographicSort" -> reduceLexicographicSort values
  "SortBy" -> reduceSortBy False values
  "ReverseSortBy" -> reduceSortBy True values
  "Union" -> reduceSetOperation SetUnion values
  "Intersection" -> reduceSetOperation SetIntersection values
  "Complement" -> reduceSetOperation SetComplement values
  "Interval" -> Right (reduceInterval values)
  "IntervalUnion" -> Right (reduceIntervalUnion values)
  "IntervalIntersection" -> Right (reduceIntervalIntersection values)
  "IntervalMemberQ" -> Right (reduceIntervalMemberQ values)
  "Select" -> reduceSelect False values
  "Discard" -> reduceSelect True values
  "SelectFirst" -> reduceSelectFirst values
  "TakeWhile" -> reduceTakeWhile values
  "LengthWhile" -> reduceLengthWhile values
  "Pick" -> reducePick values
  "Boole" -> Right (reduceBoole values)
  "MatchQ" -> Right (reduceMatchQ values)
  "FreeQ" -> reduceFreeQ values
  "MemberQ" -> reduceMemberQ values
  "Count" -> reduceCount values
  "Cases" -> reduceCases values
  "DeleteCases" -> reduceDeleteCases values
  "FirstCase" -> reduceFirstCase values
  "Position" -> reducePosition values
  "FirstPosition" -> reduceFirstPosition values
  "PositionLargest" -> reducePositionExtrema True values
  "PositionSmallest" -> reducePositionExtrema False values
  "PositionIndex" -> reducePositionIndex values
  "Range" -> Right (reduceRange values)
  "Total" -> Right (reduceTotal values)
  "Accumulate" -> Right (reduceAccumulate values)
  "Reverse" -> Right (unaryCallArguments headName reverse values)
  "RotateLeft" -> Right (reduceRotate True headName values)
  "RotateRight" -> Right (reduceRotate False headName values)
  "Take" -> reduceTakeDrop True values
  "Drop" -> reduceTakeDrop False values
  "Array" -> reduceArray values
  "ConstantArray" -> reduceConstantArray values
  "ArrayReshape" -> reduceArrayReshape values
  "ArrayPad" -> reduceArrayPad values
  "ArrayFlatten" -> reduceArrayFlatten values
  "Transpose" -> reduceTranspose values
  "UnitVector" -> reduceUnitVector values
  "IdentityMatrix" -> reduceIdentityMatrix values
  "LeviCivitaTensor" -> reduceLeviCivitaTensor values
  "VectorQ" -> reduceVectorQ values
  "MatrixQ" -> reduceMatrixQ values
  "DiagonalMatrix" -> reduceDiagonalMatrix values
  "Tuples" -> reduceTuples values
  "Partition" -> reducePartition values
  "TakeList" -> reduceTakeList values
  "TakeDrop" -> reduceTakeDropPair values
  "SequenceFold" -> reduceSequenceFold False values
  "SequenceFoldList" -> reduceSequenceFold True values
  "SequenceCases" -> reduceSequenceSearch SequenceCases values
  "SequencePosition" -> reduceSequenceSearch SequencePosition values
  "SequenceCount" -> reduceSequenceSearch SequenceCount values
  "Dot" -> reduceDot values
  "Cross" -> reduceCross values
  "Det" -> reduceDet values
  "Inverse" -> reduceInverse values
  "MatrixPower" -> reduceMatrixPower values
  "Append" -> Right (reduceAppendPrepend False headName values)
  "Prepend" -> Right (reduceAppendPrepend True headName values)
  "Join" -> Right (reduceJoin values)
  "Flatten" -> reduceFlatten values
  "Delete" -> reduceDelete values
  "Insert" -> reduceInsert values
  "ReplacePart" -> Right (reduceReplacePart values)
  "Map" -> Right (reduceMap values)
  "MapAll" -> reduceMapAll values
  "MapApply" -> reduceMapApply values
  "MapAt" -> Right (reduceMapAt values)
  "Apply" -> Right (reduceApply values)
  "Construct" -> reduceConstruct values
  "ComposeList" -> reduceComposeList values
  "Comap" -> reduceComap False values
  "ComapApply" -> reduceComap True values
  "Nest" -> reduceNest False values
  "NestList" -> reduceNest True values
  "NestWhile" -> reduceNestWhile False values
  "NestWhileList" -> reduceNestWhile True values
  "FixedPoint" -> reduceFixedPoint False values
  "FixedPointList" -> reduceFixedPoint True values
  "Fold" -> reduceFold False values
  "FoldList" -> reduceFold True values
  "FoldWhile" -> reduceFoldWhile False values
  "FoldWhileList" -> reduceFoldWhile True values
  "FoldPair" -> reduceFoldPair False values
  "FoldPairList" -> reduceFoldPair True values
  "Replace" -> reduceReplace values
  "ReplaceAt" -> reduceReplaceAt values
  "ReplaceAll" -> reduceReplaceAll values
  "ReplaceRepeated" -> reduceReplaceRepeated values
  "CompoundExpression" -> Right (if null values then Symbol "Null" else last values)
  _ -> case NumericAlgebra.reduceNumericBuiltin headName values of
    Left message -> Left (EvaluationError message)
    Right (Just result) -> Right result
    Right Nothing ->
      Right
        ( maybe
            (Call (Symbol headName) values)
            id
            (PolynomialAlgebra.reducePolynomialBuiltin canonicalCompare headName values)
        )

data Exact = Exact !Integer !Integer
  deriving (Eq, Ord, Show)

data RoundingOperation
  = RoundFloor
  | RoundCeiling
  | RoundNearest
  | RoundIntegerPart
  | RoundFractionalPart
  deriving (Eq, Show)

data RealKind
  = MachineReal
  | MarkedReal !Integer
  deriving (Eq, Show)

data RealInfo = RealInfo !Exact !RealKind !Int !Bool !Text
  deriving (Eq, Show)

-- | Expand an inclusive exact integer/rational range.  Iterator evaluation
-- uses this reducer-owned helper so its arithmetic stays identical to Range
-- and the other exact-number built-ins without exposing the private Exact
-- representation across modules.
exactRangeValues :: Expr -> Expr -> Expr -> Maybe [Expr]
exactRangeValues start end step = do
  startExact <- toExact start
  endExact <- toExact end
  stepExact@(Exact stepNumerator _) <- toExact step
  if stepNumerator == 0
    then Nothing
    else generate 65536 startExact endExact stepExact
 where
  generate :: Int -> Exact -> Exact -> Exact -> Maybe [Expr]
  generate remaining current final increment
    | not (withinBounds current final increment) = Just []
    | remaining <= 0 = Nothing
    | otherwise =
        (fromExact current :)
          <$> generate (remaining - 1) (addExact current increment) final increment
  withinBounds current final (Exact incrementNumerator _)
    | incrementNumerator > 0 = compareExact current final /= GT
    | otherwise = compareExact current final /= LT

toExact :: Expr -> Maybe Exact
toExact (Integer value) = Just (Exact value 1)
toExact (Rational numerator denominator) = Just (normalizeExact numerator denominator)
toExact _ = Nothing

fromExact :: Exact -> Expr
fromExact (Exact numerator denominator)
  | denominator == 1 = Integer numerator
  | otherwise = Rational numerator denominator

normalizeExact :: Integer -> Integer -> Exact
normalizeExact numerator denominator =
  let sign = if denominator < 0 then -1 else 1
      divisor = gcd numerator denominator
   in Exact (sign * numerator `div` divisor) (abs denominator `div` divisor)

addExact :: Exact -> Exact -> Exact
addExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  normalizeExact
    (leftNumerator * rightDenominator + rightNumerator * leftDenominator)
    (leftDenominator * rightDenominator)

multiplyExact :: Exact -> Exact -> Exact
multiplyExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  normalizeExact (leftNumerator * rightNumerator) (leftDenominator * rightDenominator)

divideExact :: Exact -> Exact -> Maybe Exact
divideExact _ (Exact 0 _) = Nothing
divideExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  Just (normalizeExact (leftNumerator * rightDenominator) (leftDenominator * rightNumerator))

reduceRounding :: RoundingOperation -> Text -> [Expr] -> Expr
reduceRounding operation headName values =
  case values of
    [value]
      | Just result <- roundScalar operation value -> result
    [value, multiple]
      | operation `elem` [RoundFloor, RoundCeiling, RoundNearest]
      , Just exactValue <- toExact value
      , Just exactMultiple@(Exact multipleNumerator _) <- toExact multiple ->
          if multipleNumerator == 0
            then Symbol "Indeterminate"
            else case divideExact exactValue exactMultiple of
              Just quotient ->
                fromExact
                  (multiplyExact exactMultiple (Exact (roundExact operation quotient) 1))
              Nothing -> Call (Symbol headName) values
    _ -> Call (Symbol headName) values

reduceClip :: [Expr] -> Either EvaluationError Expr
reduceClip arguments' = case arguments' of
  [value] -> clip value (Integer (-1)) (Integer 1) Nothing
  [value, bounds] -> do
    (lower, upper) <- parseBounds bounds
    clip value lower upper Nothing
  [value, bounds, replacements] -> do
    (lower, upper) <- parseBounds bounds
    clip value lower upper (Just replacements)
  _ -> Left (EvaluationError "Clip expects one, two, or three arguments.")
 where
  parseBounds (Call (Symbol "List") [lower, upper]) = Right (lower, upper)
  parseBounds _ =
    Left
      ( EvaluationError
          "Clip currently expects bounds of the form {min, max}."
      )
  clip value lower upper replacements = do
    exactValue <-
      maybe
        ( Left
            ( EvaluationError
                "Clip currently evaluates only for explicit real numeric arguments."
            )
        )
        Right
        (explicitRealExact value)
    exactLower <- explicitBound lower
    exactUpper <- explicitBound upper
    if compareExact exactValue exactLower == LT
      then replacementAt 0 replacements lower
      else
        if compareExact exactValue exactUpper == GT
          then replacementAt 1 replacements upper
          else Right value
  explicitBound value =
    maybe
      ( Left
          ( EvaluationError
              "Clip currently evaluates only for explicit real numeric bounds."
          )
      )
      Right
      (explicitRealExact value)
  replacementAt :: Int -> Maybe Expr -> Expr -> Either EvaluationError Expr
  replacementAt _ Nothing boundary = Right boundary
  replacementAt index (Just (Call (Symbol "List") [lowerReplacement, upperReplacement])) _ =
    Right (if index == 0 then lowerReplacement else upperReplacement)
  replacementAt _ (Just _) _ =
    Left
      ( EvaluationError
          "Clip currently expects replacement values of the form {vmin, vmax}."
      )

roundScalar :: RoundingOperation -> Expr -> Maybe Expr
roundScalar operation value
  | Just exactValue <- toExact value = Just (roundExactExpr operation exactValue)
roundScalar operation (Real source) = do
  info <- parseRealInfo source
  roundReal operation info
roundScalar operation value
  | Just (realPart, imaginaryPart) <- explicitComplexParts value = do
      roundedReal <- roundScalar operation realPart
      roundedImaginary <- roundScalar operation imaginaryPart
      pure (makeComplex roundedReal roundedImaginary)
roundScalar _ _ = Nothing

explicitComplexParts :: Expr -> Maybe (Expr, Expr)
explicitComplexParts (Complex realPart imaginaryPart) = Just (realPart, imaginaryPart)
explicitComplexParts (Symbol name)
  | systemHeadIn ["I"] name = Just (Integer 0, Integer 1)
explicitComplexParts expression
  | isExplicitReal expression || isSpecialRealValue expression =
      Just (expression, Integer 0)
explicitComplexParts (Call (Symbol headName) values)
  | systemHeadIn ["Plus"] headName = do
      components <- traverse explicitComplexParts values
      pure (foldl' addComplexComponents (Integer 0, Integer 0) components)
  | systemHeadIn ["Times"] headName = do
      components <- traverse explicitComplexParts values
      pure (foldl' multiplyComplexComponents (Integer 1, Integer 0) components)
explicitComplexParts (Call (Symbol headName) [base, Integer powerValue])
  | systemHeadIn ["Power"] headName
  , powerValue >= 0
  , powerValue <= 1024 = do
      components <- explicitComplexParts base
      pure (powerComplexComponents components powerValue)
explicitComplexParts _ = Nothing

addComplexComponents :: (Expr, Expr) -> (Expr, Expr) -> (Expr, Expr)
addComplexComponents (leftReal, leftImaginary) (rightReal, rightImaginary) =
  ( reduceExplicitRealPlus [leftReal, rightReal]
  , reduceExplicitRealPlus [leftImaginary, rightImaginary]
  )

multiplyComplexComponents :: (Expr, Expr) -> (Expr, Expr) -> (Expr, Expr)
multiplyComplexComponents (leftReal, leftImaginary) (rightReal, rightImaginary) =
  ( reduceExplicitRealPlus
      [ reduceExplicitRealTimes [leftReal, rightReal]
      , negateExplicitReal
          (reduceExplicitRealTimes [leftImaginary, rightImaginary])
      ]
  , reduceExplicitRealPlus
      [ reduceExplicitRealTimes [leftReal, rightImaginary]
      , reduceExplicitRealTimes [leftImaginary, rightReal]
      ]
  )

powerComplexComponents :: (Expr, Expr) -> Integer -> (Expr, Expr)
powerComplexComponents base powerValue = go (Integer 1, Integer 0) base powerValue
 where
  go result _ 0 = result
  go result factor 1 = multiplyComplexComponents result factor
  go result factor remaining
    | odd remaining =
        go
          (multiplyComplexComponents result factor)
          (multiplyComplexComponents factor factor)
          (remaining `div` 2)
    | otherwise =
        go result (multiplyComplexComponents factor factor) (remaining `div` 2)

reduceExplicitRealPlus :: [Expr] -> Expr
reduceExplicitRealPlus values
  | any isMachineReal values
  , Just machineValues <- traverse explicitRealDouble values =
      Real (formatMachineReal (sum machineValues))
  | otherwise = reducePlus values

reduceExplicitRealTimes :: [Expr] -> Expr
reduceExplicitRealTimes values
  | any isMachineReal values
  , Just machineValues <- traverse explicitRealDouble values =
      Real (formatMachineReal (product machineValues))
  | otherwise = reduceTimes values

explicitRealDouble :: Expr -> Maybe Double
explicitRealDouble value
  | Just (Exact numerator denominator) <- toExact value =
      Just (fromInteger numerator / fromInteger denominator)
explicitRealDouble (Real source) = do
  RealInfo (Exact numerator denominator) kind _ _ machineSource <- parseRealInfo source
  case kind of
    MachineReal -> readMaybe (T.unpack machineSource)
    MarkedReal _ -> Just (fromInteger numerator / fromInteger denominator)
explicitRealDouble _ = Nothing

negateExplicitReal :: Expr -> Expr
negateExplicitReal value
  | Just exactValue <- toExact value = fromExact (negateExact exactValue)
negateExplicitReal value@(Real source)
  | explicitRealExact value == Just (Exact 0 1) = Real (positiveRealZeroSource source)
  | otherwise = Real (negateRealSource source)
negateExplicitReal value = reduceTimes [Integer (-1), value]

positiveRealZeroSource :: Text -> Text
positiveRealZeroSource source = case T.uncons source of
  Just ('-', rest) -> rest
  Just ('+', rest) -> rest
  _ -> source

negateRealSource :: Text -> Text
negateRealSource source = case T.uncons source of
  Just ('-', rest) -> rest
  Just ('+', rest) -> "-" <> rest
  _ -> "-" <> source

isExplicitReal :: Expr -> Bool
isExplicitReal value
  | Just _ <- toExact value = True
isExplicitReal (Real source) = case parseRealInfo source of
  Just _ -> True
  Nothing -> False
isExplicitReal _ = False

makeComplex :: Expr -> Expr -> Expr
makeComplex realPart imaginaryPart
  | Just (Exact 0 _) <- toExact imaginaryPart = realPart
  | isMachineReal realPart || isMachineReal imaginaryPart =
      Complex (toMachineReal realPart) (toMachineReal imaginaryPart)
  | otherwise = Complex realPart imaginaryPart

reduceComplexComponent :: Text -> [Expr] -> Expr
reduceComplexComponent component values = case values of
  [value]
    | Just (realPart, imaginaryPart) <- explicitComplexParts value ->
        if component == "Re" then realPart else imaginaryPart
  _ -> Call (Symbol component) values

reduceReIm :: [Expr] -> Expr
reduceReIm values = case values of
  [value]
    | Just (realPart, imaginaryPart) <- broadComplexParts value ->
        evaluatedList [realPart, imaginaryPart]
  _ -> Call (Symbol "ReIm") values

reduceConjugate :: [Expr] -> Expr
reduceConjugate values = case values of
  [value]
    | Just (realPart, imaginaryPart) <- explicitComplexParts value ->
        makeComplex realPart (negateExplicitReal imaginaryPart)
  _ -> Call (Symbol "Conjugate") values

reduceArg :: [Expr] -> Expr
reduceArg values = case values of
  [value]
    | Just (realPart, imaginaryPart) <- broadComplexParts value
    , Just result <- argFromComponents realPart imaginaryPart -> result
  _ -> Call (Symbol "Arg") values

broadComplexParts :: Expr -> Maybe (Expr, Expr)
broadComplexParts value
  | Just components <- explicitComplexParts value = Just components
  | numericValueReality value == Just True = Just (value, Integer 0)
broadComplexParts (Call (Symbol headName) values)
  | systemHeadIn ["Plus"] headName = do
      components <- traverse broadComplexParts values
      pure (foldl' addComplexComponents (Integer 0, Integer 0) components)
  | systemHeadIn ["Times"] headName = do
      components <- traverse broadComplexParts values
      pure (foldl' multiplyComplexComponents (Integer 1, Integer 0) components)
broadComplexParts _ = Nothing

argFromComponents :: Expr -> Expr -> Maybe Expr
argFromComponents realPart imaginaryPart = do
  realSign <- knownRealSign realPart
  imaginarySign <- knownRealSign imaginaryPart
  case (realSign, imaginarySign) of
    (EQ, EQ) -> Just (Integer 0)
    (_, EQ) ->
      Just (if realSign == LT then Symbol "Pi" else Integer 0)
    (EQ, _) ->
      Just
        ( piMultiple
            (if imaginarySign == LT then Exact (-1) 2 else Exact 1 2)
        )
    _
      | isMachineReal realPart || isMachineReal imaginaryPart -> do
          realValue <- explicitRealDouble realPart
          imaginaryValue <- explicitRealDouble imaginaryPart
          pure (Real (formatMachineReal (pythonAtan2 imaginaryValue realValue)))
      | containsInexactReal realPart || containsInexactReal imaginaryPart -> Nothing
      | equalExplicitMagnitude realPart imaginaryPart ->
          Just
            ( piMultiple
                ( case (realSign, imaginarySign) of
                    (GT, GT) -> Exact 1 4
                    (LT, GT) -> Exact 3 4
                    (LT, LT) -> Exact (-3) 4
                    _ -> Exact (-1) 4
                )
            )
      | isNumericValue realPart && isNumericValue imaginaryPart ->
          Just (Call (Symbol "ArcTan") [realPart, imaginaryPart])
      | otherwise -> Nothing

knownRealSign :: Expr -> Maybe Ordering
knownRealSign value
  | Just exactValue <- explicitRealExact value =
      Just (compareExact exactValue (Exact 0 1))
  | isSpecialRealValue value = Just GT
  | knownPositive value = Just GT
knownRealSign (Call (Symbol headName) values)
  | systemHeadIn ["Times"] headName = do
      signs <- traverse knownRealSign values
      pure
        ( if EQ `elem` signs
            then EQ
            else if odd (length (filter (== LT) signs)) then LT else GT
        )
knownRealSign _ = Nothing

equalExplicitMagnitude :: Expr -> Expr -> Bool
equalExplicitMagnitude left right = case (explicitRealExact left, explicitRealExact right) of
  (Just (Exact leftNumerator leftDenominator), Just (Exact rightNumerator rightDenominator)) ->
    abs leftNumerator * rightDenominator
      == abs rightNumerator * leftDenominator
  _ -> False

piMultiple :: Exact -> Expr
piMultiple coefficient = reduceTimes [fromExact coefficient, Symbol "Pi"]

-- Explicit numeric constructors remain ordinary calls in the parser.  They
-- become numeric atoms only after their arguments have evaluated, matching
-- the Python reference and Wolfram's distinction between held syntax and an
-- evaluated numeric value.
reduceRationalConstructor :: [Expr] -> Expr
reduceRationalConstructor values = case values of
  [Integer numerator, Integer denominator]
    | denominator == 0 ->
        if numerator == 0
          then Symbol "Indeterminate"
          else Symbol "ComplexInfinity"
    | otherwise -> fromExact (normalizeExact numerator denominator)
  _ -> Call (Symbol "Rational") values

reduceComplexConstructor :: [Expr] -> Expr
reduceComplexConstructor values = case values of
  [realPart, imaginaryPart]
    | isExplicitReal realPart
    , isExplicitReal imaginaryPart -> makeComplex realPart imaginaryPart
  _ -> Call (Symbol "Complex") values

isMachineReal :: Expr -> Bool
isMachineReal (Real source) = case parseRealInfo source of
  Just (RealInfo _ MachineReal _ _ _) -> True
  _ -> False
isMachineReal _ = False

toMachineReal :: Expr -> Expr
toMachineReal value@(Real source) = case parseRealInfo source of
  Just (RealInfo _ MachineReal _ _ _) -> value
  Just (RealInfo exactValue _ _ _ _) -> exactToMachineReal exactValue
  Nothing -> value
toMachineReal value
  | Just exactValue <- toExact value = exactToMachineReal exactValue
toMachineReal value = value

exactToMachineReal :: Exact -> Expr
exactToMachineReal (Exact numerator denominator) =
  Real (formatMachineReal (fromInteger numerator / fromInteger denominator))

roundExactExpr :: RoundingOperation -> Exact -> Expr
roundExactExpr RoundFractionalPart value = fromExact (fractionalExact value)
roundExactExpr operation value = Integer (roundExact operation value)

roundExact :: RoundingOperation -> Exact -> Integer
roundExact RoundFloor (Exact numerator denominator) = numerator `div` denominator
roundExact RoundCeiling (Exact numerator denominator) = negate ((negate numerator) `div` denominator)
roundExact RoundNearest (Exact numerator denominator) =
  let (quotient, remainder) = numerator `quotRem` denominator
      comparison = compare (2 * abs remainder) denominator
      awayFromZero = quotient + signum numerator
   in case comparison of
        LT -> quotient
        GT -> awayFromZero
        EQ -> if even quotient then quotient else awayFromZero
roundExact RoundIntegerPart (Exact numerator denominator) = numerator `quot` denominator
roundExact RoundFractionalPart _ = 0

fractionalExact :: Exact -> Exact
fractionalExact value@(Exact numerator denominator) =
  addExact value (Exact (negate (numerator `quot` denominator)) 1)

roundReal :: RoundingOperation -> RealInfo -> Maybe Expr
roundReal RoundFractionalPart (RealInfo _ MachineReal _ _ machineSource) = do
  machineValue <- readMaybe (T.unpack machineSource) :: Maybe Double
  if isInfinite machineValue || isNaN machineValue
    then Nothing
    else
      let remainder = machineValue - fromInteger (truncate machineValue)
       in Just (Real (formatMachineReal remainder))
roundReal RoundFractionalPart (RealInfo value (MarkedReal precision) scale negativeZero _) =
  Just
    ( Real
        ( formatFixedExact (fractionalExact value) scale negativeZero
            <> "`" <> T.pack (show precision) <> "."
        )
    )
roundReal operation (RealInfo value _ _ _ _) = Just (Integer (roundExact operation value))

parseRealInfo :: Text -> Maybe RealInfo
parseRealInfo source = do
  (literal, magnitudePower, exponentSource) <- splitRealMagnitude source
  let (numberSource, markerSource) = T.breakOn "`" literal
  (baseValue, baseScale, negativeZero) <- parseDecimalExact numberSource
  let maximumMagnitude = 100000 :: Integer
  if abs magnitudePower > maximumMagnitude
    then Nothing
    else do
      let exponentMagnitude = fromInteger (abs magnitudePower)
          value =
            if magnitudePower >= 0
              then multiplyExact baseValue (Exact (10 ^ exponentMagnitude) 1)
              else multiplyExact baseValue (Exact 1 (10 ^ exponentMagnitude))
          scale = baseScale + if magnitudePower < 0 then exponentMagnitude else 0
          kind = parseRealKind markerSource
          machineSource = normalizeDoubleMantissa numberSource <> exponentSource
      pure (RealInfo value kind scale negativeZero machineSource)

splitRealMagnitude :: Text -> Maybe (Text, Integer, Text)
splitRealMagnitude source =
  case T.breakOn "*^" source of
    (literal, marker)
      | T.null marker -> Just (literal, 0, "")
      | otherwise -> do
          let exponentSource = T.drop 2 marker
          if T.null exponentSource || T.isInfixOf "*^" exponentSource
            then Nothing
            else do
              magnitudePower <- readMaybe (T.unpack exponentSource)
              pure (literal, magnitudePower, "e" <> exponentSource)

parseDecimalExact :: Text -> Maybe (Exact, Int, Bool)
parseDecimalExact source = do
  let (sign, unsigned) = case T.uncons source of
        Just ('-', rest) -> (-1, rest)
        Just ('+', rest) -> (1, rest)
        _ -> (1, source)
      pieces = T.splitOn "." unsigned
  (whole, fraction) <- case pieces of
    [wholePart] -> Just (wholePart, "")
    [wholePart, fractionPart] -> Just (wholePart, fractionPart)
    _ -> Nothing
  if (T.null whole && T.null fraction)
      || not (T.all isDigit whole)
      || not (T.all isDigit fraction)
    then Nothing
    else do
      coefficient <- readMaybe (T.unpack (if T.null (whole <> fraction) then "0" else whole <> fraction))
      let scale = T.length fraction
          signedCoefficient = sign * coefficient
      pure
        ( normalizeExact signedCoefficient (10 ^ scale)
        , scale
        , sign < 0 && coefficient == 0
        )

parseRealKind :: Text -> RealKind
parseRealKind markerSource
  | T.null markerSource = MachineReal
  | T.null specification = MachineReal
  | isAccuracy = MarkedReal 0
  | otherwise = MarkedReal (parseMarkerValue specification)
 where
  afterFirst = T.drop 1 markerSource
  isAccuracy = T.isPrefixOf "`" afterFirst
  specification = if isAccuracy then T.drop 1 afterFirst else afterFirst

parseMarkerValue :: Text -> Integer
parseMarkerValue source =
  case parseDecimalExact source of
    Just (Exact numerator denominator, _, _) -> max 0 (numerator `quot` denominator)
    Nothing -> 0

normalizeDoubleMantissa :: Text -> Text
normalizeDoubleMantissa source
  | T.isPrefixOf "-." source = "-0" <> T.drop 1 source
  | T.isPrefixOf "+." source = "+0" <> T.drop 1 source
  | T.isPrefixOf "." source = "0" <> source
  | T.isSuffixOf "." source = source <> "0"
  | otherwise = source

formatMachineReal :: Double -> Text
formatMachineReal value =
  case splitScientific (T.pack (show value)) of
    Just (mantissa, magnitudePower)
      | magnitudePower >= -4 && magnitudePower < 16 ->
          ensureMachinePoint (scientificToFixed mantissa magnitudePower)
      | otherwise ->
          stripTerminalZero mantissa <> "*^" <> formatExponent magnitudePower
    Nothing -> ensureMachinePoint (T.pack (show value))

splitScientific :: Text -> Maybe (Text, Int)
splitScientific source =
  case T.break (`elem` ("eE" :: String)) source of
    (mantissa, exponentSource)
      | T.null exponentSource -> Nothing
      | otherwise -> (,) mantissa <$> readMaybe (T.unpack (T.drop 1 exponentSource))

scientificToFixed :: Text -> Int -> Text
scientificToFixed mantissa magnitudePower =
  let (sign, unsigned) = case T.uncons mantissa of
        Just ('-', rest) -> ("-", rest)
        Just ('+', rest) -> ("", rest)
        _ -> ("", mantissa)
      (whole, fractionWithPoint) = T.breakOn "." unsigned
      fraction = if T.null fractionWithPoint then "" else T.drop 1 fractionWithPoint
      digits = whole <> fraction
      decimalPosition = T.length whole + magnitudePower
      fixed
        | decimalPosition <= 0 = "0." <> T.replicate (negate decimalPosition) "0" <> digits
        | decimalPosition >= T.length digits = digits <> T.replicate (decimalPosition - T.length digits) "0" <> ".0"
        | otherwise = T.take decimalPosition digits <> "." <> T.drop decimalPosition digits
   in sign <> trimFractionZeros fixed

trimFractionZeros :: Text -> Text
trimFractionZeros source
  | not (T.isInfixOf "." source) = source
  | otherwise =
      let trimmed = T.dropWhileEnd (== '0') source
       in if T.isSuffixOf "." trimmed then trimmed <> "0" else trimmed

stripTerminalZero :: Text -> Text
stripTerminalZero source = maybe source id (T.stripSuffix ".0" source)

formatExponent :: Int -> Text
formatExponent magnitudePower =
  let magnitude = T.pack (show (abs magnitudePower))
      padded = if T.length magnitude < 2 then "0" <> magnitude else magnitude
   in (if magnitudePower < 0 then "-" else "+") <> padded

ensureMachinePoint :: Text -> Text
ensureMachinePoint source
  | Just withoutZero <- T.stripSuffix ".0" source = withoutZero <> "."
  | T.isInfixOf "." source = source
  | otherwise = source <> "."

formatFixedExact :: Exact -> Int -> Bool -> Text
formatFixedExact (Exact numerator denominator) scale negativeZero =
  let scaled = numerator * (10 ^ scale) `div` denominator
      sign = if scaled < 0 || (scaled == 0 && negativeZero) then "-" else ""
      digits = T.pack (show (abs scaled))
   in if scale == 0
        then sign <> digits <> "."
        else
          let padded = T.replicate (max 0 (scale + 1 - T.length digits)) "0" <> digits
              decimalPosition = T.length padded - scale
           in sign <> T.take decimalPosition padded <> "." <> T.drop decimalPosition padded

reducePlus :: [Expr] -> Expr
reducePlus originalValues =
  let values = concatMap (flattenHead "Plus") originalValues
   in case reduceExplicitComplexValues addComplexComponents (Integer 0, Integer 0) values of
        Just complexResult -> complexResult
        Nothing ->
          let exactSum = foldl' addExact (Exact 0 1) (mapMaybe toExact values)
              symbolic = sortBy canonicalCompare (filter (not . isExact) values)
              collected = collectLikeTerms symbolic
              combined = (if exactSum == Exact 0 1 then [] else [fromExact exactSum]) <> collected
           in case combined of
                [] -> Integer 0
                [single] -> single
                _ -> Call (Symbol "Plus") combined
 where
  collectLikeTerms terms = retainFirst Set.empty decomposed
   where
    decomposed = map termCoefficient terms
    coefficients =
      foldl'
        (\retained (coefficient, term) ->
          Map.insertWith addExact (fullForm term) coefficient retained)
        Map.empty
        decomposed
    retainFirst _ [] = []
    retainFirst seen ((_, term) : remaining)
      | Set.member key seen = retainFirst seen remaining
      | Exact 0 _ <- coefficient = retainFirst (Set.insert key seen) remaining
      | coefficient == Exact 1 1 = term : retainFirst (Set.insert key seen) remaining
      | otherwise =
          reduceTimes [fromExact coefficient, term]
            : retainFirst (Set.insert key seen) remaining
     where
      key = fullForm term
      coefficient = Map.findWithDefault (Exact 1 1) key coefficients
  termCoefficient (Call (Symbol "Times") factors) =
    let coefficient = foldl' multiplyExact (Exact 1 1) (mapMaybe toExact factors)
        symbolicFactors = filter (not . isExact) factors
     in (coefficient, reduceTimes symbolicFactors)
  termCoefficient term = (Exact 1 1, term)

reduceTimes :: [Expr] -> Expr
reduceTimes originalValues =
  let values = concatMap (flattenHead "Times") originalValues
   in case reduceExplicitComplexValues multiplyComplexComponents (Integer 1, Integer 0) values of
        Just complexResult -> complexResult
        Nothing ->
          let exactProduct = foldl' multiplyExact (Exact 1 1) (mapMaybe toExact values)
              symbolic = sortBy canonicalCompare (filter (not . isExact) values)
              collected = collectRepeated collectFactor symbolic
              combined
                | exactProduct == Exact 0 1 = [Integer 0]
                | exactProduct == Exact 1 1 && not (null collected) = collected
                | otherwise = fromExact exactProduct : collected
           in case combined of
                [] -> Integer 1
                [single] -> single
                _ -> Call (Symbol "Times") combined
 where
 collectFactor factor count = reducePower [factor, Integer count]

reduceExplicitComplexValues
  :: ((Expr, Expr) -> (Expr, Expr) -> (Expr, Expr))
  -> (Expr, Expr)
  -> [Expr]
  -> Maybe Expr
reduceExplicitComplexValues combine identity values = do
  components <- traverse explicitComplexParts values
  if any (not . exactZero . snd) components
    then
      let (realPart, imaginaryPart) = foldl' combine identity components
       in Just (makeComplex realPart imaginaryPart)
    else Nothing

reduceSparseArithmetic
  :: Text
  -> [Expr]
  -> Either EvaluationError Expr
reduceSparseArithmetic functionName values
  | not (any isSparseArray values) = Right (reduceOrdinary values)
  | null values = Right (if functionName == "Plus" then Integer 0 else Integer 1)
  | any isListExpression values = Right (Call (Symbol functionName) values)
  | first : remaining <- values = foldM (sparseBinary functionName) first remaining
  | otherwise = Right (reduceOrdinary values)
 where
  reduceOrdinary
    | functionName == "Plus" = reducePlus
    | otherwise = reduceTimes
  isListExpression (Call (Symbol listHead) _) = systemHeadIn ["List"] listHead
  isListExpression _ = False

sparseBinary
  :: Text
  -> Expr
  -> Expr
  -> Either EvaluationError Expr
sparseBinary functionName left right = case (left, right) of
  (SparseArray leftDimensions leftEntries leftFill, SparseArray rightDimensions rightEntries rightFill)
    | leftDimensions /= rightDimensions ->
        Left
          ( EvaluationError
              (functionName <> " expects SparseArray dimensions to agree.")
          )
    | otherwise -> do
        fill <- evaluateSparseScalar functionName leftFill rightFill
        let leftMap = Map.fromList [(indices, value) | SparseEntry indices value <- leftEntries]
            rightMap = Map.fromList [(indices, value) | SparseEntry indices value <- rightEntries]
            coordinates = Set.toAscList (Map.keysSet leftMap `Set.union` Map.keysSet rightMap)
        pairs <-
          traverse
            ( \indices -> do
                value <-
                  evaluateSparseScalar
                    functionName
                    (Map.findWithDefault leftFill indices leftMap)
                    (Map.findWithDefault rightFill indices rightMap)
                Right (indices, value)
            )
            coordinates
        canonicalSparseArray leftDimensions pairs fill
  (SparseArray dimensions entries fill, scalar) -> do
    outputFill <- evaluateSparseScalar functionName fill scalar
    pairs <-
      traverse
        ( \(SparseEntry indices value) -> do
            outputValue <- evaluateSparseScalar functionName value scalar
            Right (indices, outputValue)
        )
        entries
    canonicalSparseArray dimensions pairs outputFill
  (scalar, SparseArray dimensions entries fill) -> do
    outputFill <- evaluateSparseScalar functionName scalar fill
    pairs <-
      traverse
        ( \(SparseEntry indices value) -> do
            outputValue <- evaluateSparseScalar functionName scalar value
            Right (indices, outputValue)
        )
        entries
    canonicalSparseArray dimensions pairs outputFill
  _ -> evaluateSparseScalar functionName left right

evaluateSparseScalar
  :: Text
  -> Expr
  -> Expr
  -> Either EvaluationError Expr
evaluateSparseScalar "Plus" left right =
  Right
    ( reducePlus
        ( sortBy
            canonicalCompare
            (flattenHead "Plus" left <> flattenHead "Plus" right)
        )
    )
evaluateSparseScalar functionName left right =
  evaluate (Call (Symbol functionName) [left, right])

collectRepeated :: (Expr -> Integer -> Expr) -> [Expr] -> [Expr]
collectRepeated combine values = retainFirst Set.empty values
 where
  counts =
    foldl'
      (\retained value -> Map.insertWith (+) (fullForm value) (1 :: Integer) retained)
      Map.empty
      values
  retainFirst _ [] = []
  retainFirst seen (value : rest)
    | Set.member key seen = retainFirst seen rest
    | otherwise =
        let count = Map.findWithDefault 1 key counts
            collected = if count == 1 then value else combine value count
         in collected : retainFirst (Set.insert key seen) rest
   where
    key = fullForm value

reducePower :: [Expr] -> Expr
reducePower [] = Integer 1
reducePower [base] = base
reducePower [base, Integer exponentValue]
  | exponentValue == 0
  , isExplicitZero base = Symbol "Indeterminate"
  | exponentValue == 0 = Integer 1
  | exponentValue == 1 = base
  | Just (Exact numerator denominator) <- toExact base =
      if exponentValue > 0
        then fromExact (normalizeExact (numerator ^ exponentValue) (denominator ^ exponentValue))
        else
          if numerator == 0
            then Symbol "ComplexInfinity"
            else
              fromExact
                ( normalizeExact
                    (denominator ^ abs exponentValue)
                    (numerator ^ abs exponentValue)
                )
reducePower [base, exponentValue]
  | Just result <- reduceExactFractionalPower base exponentValue = result
  | Just (Exact 1 1) <- toExact base = Integer 1
reducePower values = Call (Symbol "Power") values

reduceExactFractionalPower :: Expr -> Expr -> Maybe Expr
reduceExactFractionalPower base exponentValue = do
  baseExact@(Exact baseNumerator _) <- toExact base
  Exact exponentNumerator exponentDenominator <- toExact exponentValue
  if exponentDenominator == 1
    then Nothing
    else
      if baseNumerator == 0
        then
          Just
            ( if exponentNumerator > 0
                then Integer 0
                else Symbol "ComplexInfinity"
            )
        else
          if baseNumerator < 0
            then
              if exponentNumerator == 1 && exponentDenominator == 2
                then
                  let positiveBase = fromExact (negateExact baseExact)
                      positivePower =
                        maybe
                          (Call (Symbol "Power") [positiveBase, exponentValue])
                          id
                          (reduceExactFractionalPower positiveBase exponentValue)
                   in Just (multiplyByImaginaryUnit positivePower)
                else Nothing
            else
              reducePositiveExactFractionalPower
                baseExact exponentNumerator exponentDenominator

reducePositiveExactFractionalPower :: Exact -> Integer -> Integer -> Maybe Expr
reducePositiveExactFractionalPower baseExact exponentNumerator exponentDenominator =
  let absoluteNumerator = abs exponentNumerator
      (outside, inside) =
        extractExactPowerRoot baseExact absoluteNumerator exponentDenominator
   in if outside == Exact 1 1
        && inside == baseExact
        && absoluteNumerator == 1
        then Nothing
        else
          let outsideFactor =
                if exponentNumerator < 0
                  then reciprocalExact outside
                  else outside
              radicalExponent =
                normalizeExact
                  (if exponentNumerator < 0 then -1 else 1)
                  exponentDenominator
              factors =
                (if outsideFactor == Exact 1 1 then [] else [fromExact outsideFactor])
                  <> ( if inside == Exact 1 1
                        then []
                        else [Call (Symbol "Power") [fromExact inside, fromExact radicalExponent]]
                     )
           in Just $ case factors of
                [] -> Integer 1
                [single] -> single
                _ -> reduceTimes factors

extractExactPowerRoot :: Exact -> Integer -> Integer -> (Exact, Exact)
extractExactPowerRoot (Exact numerator denominator) powerNumerator rootDegree =
  let (numeratorOutside, numeratorInside) =
        extractIntegerPowerRoot numerator powerNumerator rootDegree
      (denominatorOutside, denominatorInside) =
        extractIntegerPowerRoot denominator powerNumerator rootDegree
   in ( normalizeExact numeratorOutside denominatorOutside
      , normalizeExact numeratorInside denominatorInside
      )

extractIntegerPowerRoot :: Integer -> Integer -> Integer -> (Integer, Integer)
extractIntegerPowerRoot value powerNumerator rootDegree =
  foldl' collect (1, 1) (primeFactorization value)
 where
  collect (outside, inside) (prime, multiplicity) =
    let totalMultiplicity = multiplicity * powerNumerator
        (outsideMultiplicity, insideMultiplicity) = totalMultiplicity `divMod` rootDegree
     in ( outside * prime ^ outsideMultiplicity
        , inside * prime ^ insideMultiplicity
        )

primeFactorization :: Integer -> [(Integer, Integer)]
primeFactorization value = factor (abs value) 2
 where
  factor 1 _ = []
  factor remaining candidate
    | candidate * candidate > remaining = [(remaining, 1)]
    | otherwise =
        let (multiplicity, quotient) = divideRepeatedly remaining candidate 0
            nextCandidate = if candidate == 2 then 3 else candidate + 2
         in (if multiplicity == 0 then [] else [(candidate, multiplicity)])
              <> factor quotient nextCandidate
  divideRepeatedly remaining candidate multiplicity
    | remaining `mod` candidate == 0 =
        divideRepeatedly (remaining `div` candidate) candidate (multiplicity + 1)
    | otherwise = (multiplicity, remaining)

negateExact :: Exact -> Exact
negateExact (Exact numerator denominator) = Exact (negate numerator) denominator

reciprocalExact :: Exact -> Exact
reciprocalExact (Exact numerator denominator) = normalizeExact denominator numerator

multiplyByImaginaryUnit :: Expr -> Expr
multiplyByImaginaryUnit value
  | Just _ <- toExact value = Complex (Integer 0) value
multiplyByImaginaryUnit (Call (Symbol "Times") (coefficient : factors))
  | Just _ <- toExact coefficient =
      case Complex (Integer 0) coefficient : factors of
        [single] -> single
        values -> Call (Symbol "Times") values
multiplyByImaginaryUnit value =
  Call (Symbol "Times") [Complex (Integer 0) (Integer 1), value]

reduceSqrt :: [Expr] -> Expr
reduceSqrt [Integer value]
  | value < 0 =
      Call (Symbol "Times") [reduceSqrt [Integer (negate value)], Symbol "I"]
reduceSqrt [value]
  | Just _ <- toExact value =
      let exponentValue = Rational 1 2
       in maybe
            (reducePower [value, exponentValue])
            id
            (reduceExactFractionalPower value exponentValue)
reduceSqrt [Real source]
  | Just (RealInfo (Exact numerator denominator) _ _ _ _) <- parseRealInfo source
  , numerator >= 0 =
      let result = sqrt (fromInteger numerator / fromInteger denominator)
       in if isInfinite result || isNaN result
            then Call (Symbol "Sqrt") [Real source]
            else Real (formatMachineReal result)
reduceSqrt values = Call (Symbol "Sqrt") values

isExplicitZero :: Expr -> Bool
isExplicitZero value = case explicitRealExact value of
  Just (Exact 0 _) -> True
  _ -> False

reduceFactorial :: [Expr] -> Expr
reduceFactorial [Integer value]
  | value >= 0 = Integer (product [1 .. value])
reduceFactorial values = Call (Symbol "Factorial") values

reduceFactorial2 :: [Expr] -> Expr
reduceFactorial2 [Integer value]
  | value >= -1 = Integer (product [value, value - 2 .. 1])
reduceFactorial2 values = Call (Symbol "Factorial2") values

reduceAbs :: [Expr] -> Expr
reduceAbs [value]
  | Just (Exact numerator denominator) <- toExact value =
      fromExact (Exact (abs numerator) denominator)
reduceAbs values = Call (Symbol "Abs") values

reduceSign :: [Expr] -> Expr
reduceSign [value]
  | Just (Exact numerator _) <- toExact value = Integer (signum numerator)
reduceSign values = Call (Symbol "Sign") values

reduceNot :: [Expr] -> Expr
reduceNot [Symbol "True"] = Symbol "False"
reduceNot [Symbol "False"] = Symbol "True"
reduceNot values = Call (Symbol "Not") values

stringThread
  :: Text
  -> (Text -> Either EvaluationError Expr)
  -> Expr
  -> Either EvaluationError Expr
stringThread operation scalar = go
 where
  go (String value) = scalar value
  go (Call (Symbol "List") values) = evaluatedList <$> traverse go values
  go _ = Left (EvaluationError (operation <> " expects a string or a list of strings."))

reduceCharacters :: [Expr] -> Either EvaluationError Expr
reduceCharacters = \case
  [expression] ->
    stringThread
      "Characters"
      (Right . evaluatedList . map (String . T.singleton) . T.unpack)
      expression
  _ -> Left (EvaluationError "Characters expects exactly one argument.")

data CharacterEncoding
  = EncodingUnicode
  | EncodingPrintableAscii
  | EncodingAscii
  | EncodingLatin1
  | EncodingLatin15
  | EncodingWindows1252
  | EncodingUtf8
  | EncodingUtf16LE
  | EncodingUtf16BE
  | EncodingUtf32LE
  | EncodingUtf32BE
  deriving (Eq, Show)

reduceByteArray :: [Expr] -> Either EvaluationError Expr
reduceByteArray = \case
  [value@(ByteArray _)] -> Right value
  [String encoded] ->
    maybe
      (Left (EvaluationError "ByteArray string input must be valid Base64."))
      (Right . ByteArray)
      (decodeBase64Strict encoded)
  [Call (Symbol "List") values] -> do
    bytes <- traverse byteValue values
    Right (ByteArray (BS.pack bytes))
  [_] ->
    Left
      ( EvaluationError
          "ByteArray expects a byte list, a Base64 string, or another ByteArray."
      )
  _ -> Left (EvaluationError "ByteArray expects exactly one argument.")
 where
  byteValue (Integer value)
    | value >= 0
    , value <= 255 = Right (fromInteger value)
  byteValue _ =
    Left (EvaluationError "ByteArray list input must contain byte-sized integers.")

reduceToCharacterCode :: [Expr] -> Either EvaluationError Expr
reduceToCharacterCode values = case values of
  [expression] -> convert EncodingUnicode expression
  [expression, encodingExpression] -> do
    encoding <- requireCharacterEncoding "ToCharacterCode" encodingExpression
    convert encoding expression
  _ ->
    Left
      ( EvaluationError
          "ToCharacterCode expects a string and an optional encoding."
      )
 where
  convert encoding = \case
    String value -> Right (evaluatedList (textCharacterCodes encoding value))
    Call (Symbol "List") items -> evaluatedList <$> traverse (convert encoding) items
    _ ->
      Left
        ( EvaluationError
            "ToCharacterCode expects a string or a list of strings."
        )

reduceFromCharacterCode :: [Expr] -> Either EvaluationError Expr
reduceFromCharacterCode values = case values of
  [expression] -> String <$> fromCharacterCodes EncodingUnicode expression
  [expression, encodingExpression] -> do
    encoding <- requireCharacterEncoding "FromCharacterCode" encodingExpression
    String <$> fromCharacterCodes encoding expression
  _ ->
    Left
      ( EvaluationError
          "FromCharacterCode expects character codes and an optional encoding."
      )

reduceStringToByteArray :: [Expr] -> Either EvaluationError Expr
reduceStringToByteArray values = case values of
  [String value] -> ByteArray <$> encodeTextBytes EncodingUtf8 value
  [String value, encodingExpression] -> do
    encoding <- requireCharacterEncoding "StringToByteArray" encodingExpression
    if encoding == EncodingUnicode
      then
        Left
          ( EvaluationError
              "StringToByteArray does not currently support the Unicode pseudo-encoding."
          )
      else ByteArray <$> encodeTextBytes encoding value
  [_, _] -> Left (EvaluationError "StringToByteArray expects a string.")
  _ ->
    Left
      ( EvaluationError
          "StringToByteArray expects a string and an optional encoding."
      )

reduceByteArrayToString :: [Expr] -> Either EvaluationError Expr
reduceByteArrayToString values = case values of
  [expression] -> do
    bytes <- requireBytes expression
    String <$> decodeBytes EncodingUtf8 bytes
  [expression, encodingExpression] -> do
    bytes <- requireBytes expression
    encoding <- requireCharacterEncoding "ByteArrayToString" encodingExpression
    if encoding == EncodingUnicode
      then
        Left
          ( EvaluationError
              "ByteArrayToString does not currently support the Unicode pseudo-encoding."
          )
      else String <$> decodeBytes encoding bytes
  _ ->
    Left
      ( EvaluationError
          "ByteArrayToString expects a byte array and an optional encoding."
      )
 where
  requireBytes (ByteArray bytes) = Right bytes
  requireBytes (Call (Symbol "List") []) = Right BS.empty
  requireBytes _ = Left (EvaluationError "ByteArrayToString expects a ByteArray.")

requireCharacterEncoding :: Text -> Expr -> Either EvaluationError CharacterEncoding
requireCharacterEncoding operation = \case
  String raw ->
    maybe
      (Left (unsupportedCharacterEncoding operation))
      Right
      (normalizeCharacterEncoding raw)
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects the encoding name to be a string.")
      )

unsupportedCharacterEncoding :: Text -> EvaluationError
unsupportedCharacterEncoding operation =
  EvaluationError
    ( operation
        <> " currently supports Unicode, PrintableASCII, UTF-8, UTF-16LE, UTF-16BE, UTF-32LE, UTF-32BE, ASCII, WindowsANSI, ISO8859-1, and ISO8859-15."
    )

normalizeCharacterEncoding :: Text -> Maybe CharacterEncoding
normalizeCharacterEncoding raw = case T.toLower (T.strip raw) of
  "unicode" -> Just EncodingUnicode
  "printableascii" -> Just EncodingPrintableAscii
  "printable-ascii" -> Just EncodingPrintableAscii
  "ascii" -> Just EncodingAscii
  "iso8859-1" -> Just EncodingLatin1
  "iso-8859-1" -> Just EncodingLatin1
  "latin1" -> Just EncodingLatin1
  "latin-1" -> Just EncodingLatin1
  "iso8859-15" -> Just EncodingLatin15
  "iso-8859-15" -> Just EncodingLatin15
  "windowsansi" -> Just EncodingWindows1252
  "windows-ansi" -> Just EncodingWindows1252
  "windows-1252" -> Just EncodingWindows1252
  "cp1252" -> Just EncodingWindows1252
  "utf-8" -> Just EncodingUtf8
  "utf8" -> Just EncodingUtf8
  "utf-16le" -> Just EncodingUtf16LE
  "utf16le" -> Just EncodingUtf16LE
  "utf-16be" -> Just EncodingUtf16BE
  "utf16be" -> Just EncodingUtf16BE
  "utf-32le" -> Just EncodingUtf32LE
  "utf32le" -> Just EncodingUtf32LE
  "utf-32be" -> Just EncodingUtf32BE
  "utf32be" -> Just EncodingUtf32BE
  _ -> Nothing

textCharacterCodes :: CharacterEncoding -> Text -> [Expr]
textCharacterCodes EncodingUnicode = map (Integer . fromIntegral . ord) . T.unpack
textCharacterCodes encoding
  | isSingleByteEncoding encoding =
      map
        (maybe (Symbol "None") (Integer . fromIntegral) . encodeSingleByte encoding)
        . T.unpack
  | otherwise =
      either
        (const [])
        (map (Integer . fromIntegral) . BS.unpack)
        . encodeTextBytes encoding

fromCharacterCodes :: CharacterEncoding -> Expr -> Either EvaluationError Text
fromCharacterCodes encoding expression = do
  values <- case expression of
    Integer value -> Right [value]
    Call (Symbol "List") items -> traverse requireInteger items
    _ -> invalid
  if any (\value -> value < 0 || value > 0x10ffff) values
    then
      Left
        ( EvaluationError
            "FromCharacterCode input must contain valid non-negative Unicode code points."
        )
    else
      if encoding == EncodingUnicode
        then Right (T.pack (map (chr . fromInteger) values))
        else decodeMixed values
 where
  invalid =
    Left
      ( EvaluationError
          "FromCharacterCode expects an integer or a list of integers."
      )
  requireInteger (Integer value) = Right value
  requireInteger _ = invalid

  decodeMixed = finish <=< foldM step ([], [])
  step (pending, pieces) value
    | value <= 255 = Right (fromInteger value : pending, pieces)
    | otherwise = do
        (cleared, flushed) <- flush pending pieces
        Right (cleared, T.singleton (chr (fromInteger value)) : flushed)
  finish (pending, pieces) = do
    (_, flushed) <- flush pending pieces
    Right (T.concat (reverse flushed))
  flush [] pieces = Right ([], pieces)
  flush pending pieces = do
    decoded <- decodeBytes encoding (BS.pack (reverse pending))
    Right ([], decoded : pieces)

isSingleByteEncoding :: CharacterEncoding -> Bool
isSingleByteEncoding encoding =
  encoding
    `elem` [ EncodingPrintableAscii
           , EncodingAscii
           , EncodingLatin1
           , EncodingLatin15
           , EncodingWindows1252
           ]

encodeTextBytes :: CharacterEncoding -> Text -> Either EvaluationError BS.ByteString
encodeTextBytes encoding value = case encoding of
  EncodingUnicode ->
    Left (EvaluationError "Unicode is not a byte encoding in this operation.")
  EncodingPrintableAscii -> encodeSingleBytes EncodingAscii
  EncodingAscii -> encodeSingleBytes EncodingAscii
  EncodingLatin1 -> encodeSingleBytes EncodingLatin1
  EncodingLatin15 -> encodeSingleBytes EncodingLatin15
  EncodingWindows1252 -> encodeSingleBytes EncodingWindows1252
  EncodingUtf8 -> Right (TE.encodeUtf8 value)
  EncodingUtf16LE -> Right (TE.encodeUtf16LE value)
  EncodingUtf16BE -> Right (TE.encodeUtf16BE value)
  EncodingUtf32LE -> Right (TE.encodeUtf32LE value)
  EncodingUtf32BE -> Right (TE.encodeUtf32BE value)
 where
  encodeSingleBytes singleEncoding =
    case traverse (encodeSingleByte singleEncoding) (T.unpack value) of
      Nothing ->
        Left
          ( EvaluationError
              "StringToByteArray could not represent the string in the requested encoding."
          )
      Just bytes -> Right (BS.pack bytes)

decodeBytes :: CharacterEncoding -> BS.ByteString -> Either EvaluationError Text
decodeBytes encoding bytes = Right $ case encoding of
  EncodingUnicode -> T.pack (map (chr . fromIntegral) (BS.unpack bytes))
  EncodingPrintableAscii -> T.pack (map decodeAsciiByte (BS.unpack bytes))
  EncodingAscii -> T.pack (map decodeAsciiByte (BS.unpack bytes))
  EncodingLatin1 -> TE.decodeLatin1 bytes
  EncodingLatin15 -> T.pack (map decodeLatin15Byte (BS.unpack bytes))
  EncodingWindows1252 -> T.pack (map decodeWindows1252Byte (BS.unpack bytes))
  EncodingUtf8 -> TE.decodeUtf8With rawByteDecode bytes
  EncodingUtf16LE -> TE.decodeUtf16LEWith rawByteDecode bytes
  EncodingUtf16BE -> TE.decodeUtf16BEWith rawByteDecode bytes
  EncodingUtf32LE -> TE.decodeUtf32LEWith rawByteDecode bytes
  EncodingUtf32BE -> TE.decodeUtf32BEWith rawByteDecode bytes
 where
  rawByteDecode _ = fmap (chr . fromIntegral)
  decodeAsciiByte byte
    | byte < 128 = chr (fromIntegral byte)
    | otherwise = chr (0xf200 + fromIntegral byte)

encodeSingleByte :: CharacterEncoding -> Char -> Maybe Word8
encodeSingleByte encoding character = case encoding of
  EncodingPrintableAscii -> ascii
  EncodingAscii -> ascii
  EncodingLatin1
    | codepoint <= 255 -> Just (fromIntegral codepoint)
  EncodingLatin15 -> encodeLatin15 character
  EncodingWindows1252 -> encodeWindows1252 character
  _ -> Nothing
 where
  codepoint = ord character
  ascii
    | codepoint < 128 = Just (fromIntegral codepoint)
    | otherwise = Nothing

decodeLatin15Byte :: Word8 -> Char
decodeLatin15Byte byte = case byte of
  0xa4 -> '\x20ac'
  0xa6 -> '\x0160'
  0xa8 -> '\x0161'
  0xb4 -> '\x017d'
  0xb8 -> '\x017e'
  0xbc -> '\x0152'
  0xbd -> '\x0153'
  0xbe -> '\x0178'
  _ -> chr (fromIntegral byte)

encodeLatin15 :: Char -> Maybe Word8
encodeLatin15 character = case character of
  '\x20ac' -> Just 0xa4
  '\x0160' -> Just 0xa6
  '\x0161' -> Just 0xa8
  '\x017d' -> Just 0xb4
  '\x017e' -> Just 0xb8
  '\x0152' -> Just 0xbc
  '\x0153' -> Just 0xbd
  '\x0178' -> Just 0xbe
  _
    | ord character <= 255
    , ord character `notElem` [0xa4, 0xa6, 0xa8, 0xb4, 0xb8, 0xbc, 0xbd, 0xbe] ->
        Just (fromIntegral (ord character))
    | otherwise -> Nothing

windows1252Characters :: [(Word8, Char)]
windows1252Characters =
  [ (0x80, '\x20ac')
  , (0x82, '\x201a')
  , (0x83, '\x0192')
  , (0x84, '\x201e')
  , (0x85, '\x2026')
  , (0x86, '\x2020')
  , (0x87, '\x2021')
  , (0x88, '\x02c6')
  , (0x89, '\x2030')
  , (0x8a, '\x0160')
  , (0x8b, '\x2039')
  , (0x8c, '\x0152')
  , (0x8e, '\x017d')
  , (0x91, '\x2018')
  , (0x92, '\x2019')
  , (0x93, '\x201c')
  , (0x94, '\x201d')
  , (0x95, '\x2022')
  , (0x96, '\x2013')
  , (0x97, '\x2014')
  , (0x98, '\x02dc')
  , (0x99, '\x2122')
  , (0x9a, '\x0161')
  , (0x9b, '\x203a')
  , (0x9c, '\x0153')
  , (0x9e, '\x017e')
  , (0x9f, '\x0178')
  ]

decodeWindows1252Byte :: Word8 -> Char
decodeWindows1252Byte byte =
  maybe (chr (fromIntegral byte)) id (lookup byte windows1252Characters)

encodeWindows1252 :: Char -> Maybe Word8
encodeWindows1252 character =
  case [byte | (byte, decoded) <- windows1252Characters, decoded == character] of
    byte : _ -> Just byte
    []
      | codepoint < 128 || codepoint >= 160 && codepoint <= 255 ->
          Just (fromIntegral codepoint)
      | otherwise -> Nothing
 where
  codepoint = ord character

decodeBase64Strict :: Text -> Maybe BS.ByteString
decodeBase64Strict encoded
  | T.length encoded `mod` 4 /= 0 = Nothing
  | otherwise = BS.pack <$> decodeGroups (T.unpack encoded)
 where
  decodeGroups [] = Just []
  decodeGroups (a : b : c : d : rest) = do
    first <- base64Digit a
    second <- base64Digit b
    let byte1 = (first `shiftL` 2) .|. (second `shiftR` 4)
    case (c, d, rest) of
      ('=', '=', []) -> Just [byte1]
      (_, '=', []) -> do
        third <- base64Digit c
        let byte2 = (second `shiftL` 4) .|. (third `shiftR` 2)
        Just [byte1, byte2]
      ('=', _, _) -> Nothing
      (_, '=', _) -> Nothing
      _ -> do
        third <- base64Digit c
        fourth <- base64Digit d
        let byte2 = (second `shiftL` 4) .|. (third `shiftR` 2)
            byte3 = (third `shiftL` 6) .|. fourth
        ([byte1, byte2, byte3] <>) <$> decodeGroups rest
  decodeGroups _ = Nothing

  base64Digit character
    | character >= 'A' && character <= 'Z' =
        Just (fromIntegral (ord character - ord 'A'))
    | character >= 'a' && character <= 'z' =
        Just (fromIntegral (26 + ord character - ord 'a'))
    | character >= '0' && character <= '9' =
        Just (fromIntegral (52 + ord character - ord '0'))
    | character == '+' = Just 62
    | character == '/' = Just 63
    | otherwise = Nothing

reduceStringLength :: [Expr] -> Either EvaluationError Expr
reduceStringLength = \case
  [expression] ->
    stringThread
      "StringLength"
      (Right . Integer . fromIntegral . T.length)
      expression
  _ -> Left (EvaluationError "StringLength expects exactly one argument.")

reduceStringUnary
  :: Text
  -> (Text -> Text)
  -> [Expr]
  -> Either EvaluationError Expr
reduceStringUnary operation transform = \case
  [expression] ->
    stringThread operation (Right . String . transform) expression
  _ -> Left (EvaluationError (operation <> " expects exactly one argument."))

capitalizeText :: Text -> Text
capitalizeText value = case T.uncons value of
  Nothing -> value
  Just (firstCharacter, remaining) -> T.cons (toUpper firstCharacter) remaining

reduceStringTakeDrop :: Bool -> [Expr] -> Either EvaluationError Expr
reduceStringTakeDrop takeMode = \case
  [expression, specification] ->
    stringThread operation (slice specification) expression
  _ -> Left (EvaluationError (operation <> " expects exactly two arguments."))
 where
  operation = if takeMode then "StringTake" else "StringDrop"
  slice specification value = do
    indices <- stringSelectorIndices operation (T.length value) specification
    let characters' = T.unpack value
        selected
          | takeMode = [character | (index, character) <- zip [0 ..] characters', index `elem` indices]
          | otherwise = [character | (index, character) <- zip [0 ..] characters', index `notElem` indices]
    Right (String (T.pack selected))

stringSelectorIndices :: Text -> Int -> Expr -> Either EvaluationError [Int]
stringSelectorIndices operation count specification = case specification of
  Integer amount
    | amount >= 0
    , amount <= fromIntegral count -> Right [0 .. fromIntegral amount - 1]
    | amount < 0
    , abs amount <= fromIntegral count ->
        Right [count - fromIntegral (abs amount) .. count - 1]
    | otherwise -> invalid
  Symbol "All" -> Right [0 .. count - 1]
  Call (Symbol "UpTo") [Integer amount]
    | amount >= 0 -> Right [0 .. min count (fromIntegral amount) - 1]
    | otherwise ->
        let retained = min count (fromIntegral (abs amount))
         in Right [count - retained .. count - 1]
  spanSpecification@(Call (Symbol "Span") _) -> spanIndices spanSpecification
  Call (Symbol "List") [Integer position] ->
    maybe invalid (Right . pure) (resolvePosition count position)
  Call (Symbol "List") [Symbol "All"] -> Right [0 .. count - 1]
  Call (Symbol "List") [upTo@(Call (Symbol "UpTo") _)] ->
    stringSelectorIndices operation count upTo
  Call (Symbol "List") values
    | length values `elem` [2, 3] ->
        spanIndices (Call (Symbol "Span") values)
  _ -> invalid
 where
  invalid =
    Left
      ( EvaluationError
          ("Unsupported " <> operation <> " specification: " <> inputForm specification <> ".")
      )
  spanIndices spanSpecification = do
    positions <- expandPartSpan count spanSpecification
    maybe invalid Right (traverse (resolvePosition count) positions)

reduceStringJoin :: [Expr] -> Either EvaluationError Expr
reduceStringJoin values = String . T.concat <$> (concat <$> traverse flatten values)
 where
  flatten (String value) = Right [value]
  flatten (Call (Symbol "List") nested) = concat <$> traverse flatten nested
  flatten _ = Left (EvaluationError "StringJoin expects strings or nested lists of strings.")

reduceStringInsert :: [Expr] -> Either EvaluationError Expr
reduceStringInsert = \case
  [expression, String insertion, positions] ->
    stringThread "StringInsert" (insert positions insertion) expression
  [_, _, _] ->
    Left (EvaluationError "StringInsert expects the inserted value to be a string.")
  _ ->
    Left
      ( EvaluationError
          "StringInsert expects a source string, an insertion string, and positions."
      )
 where
  insert positions insertion value = do
    resolved <- stringInsertPositions (T.length value) positions
    let counts = Map.fromListWith (+) [(index, 1 :: Int) | index <- resolved]
        characters' = T.unpack value
        pieces =
          concat
            [ replicate (Map.findWithDefault 0 index counts) insertion
                <> if index < length characters'
                  then [T.singleton (characters' !! index)]
                  else []
            | index <- [0 .. length characters']
            ]
    Right (String (T.concat pieces))

stringInsertPositions :: Int -> Expr -> Either EvaluationError [Int]
stringInsertPositions count = \case
  Integer position -> pure <$> resolveInsert position
  Call (Symbol "List") positions -> traverse requirePosition positions
  _ ->
    Left
      ( EvaluationError
          "StringInsert expects an integer position or a list of integer positions."
      )
 where
  requirePosition (Integer position) = resolveInsert position
  requirePosition _ =
    Left (EvaluationError "StringInsert position lists must contain only integers.")
  resolveInsert position
    | position > 0
    , position <= fromIntegral count + 1 = Right (fromIntegral position - 1)
    | position < 0
    , position >= negate (fromIntegral count) - 1 =
        Right (count + fromIntegral position + 1)
    | position == 0 =
        Left (EvaluationError "StringInsert positions must be nonzero integers.")
    | otherwise =
        Left
          ( EvaluationError
              ( "StringInsert position "
                  <> T.pack (show position)
                  <> " is out of range for length "
                  <> T.pack (show count)
                  <> "."
              )
          )

reduceStringRepeat :: [Expr] -> Either EvaluationError Expr
reduceStringRepeat values = case values of
  [expression, countExpression] -> repeatString expression countExpression Nothing
  [expression, countExpression, targetExpression] ->
    repeatString expression countExpression (Just targetExpression)
  _ ->
    Left
      ( EvaluationError
          "StringRepeat expects a string, a count, and an optional target length."
      )
 where
  repeatString expression countExpression targetExpression = do
    count <- requireNonnegativeInt "StringRepeat expects a non-negative integer count." countExpression
    target <- traverse (requireNonnegativeInt "StringRepeat expects a non-negative integer target length.") targetExpression
    stringThread "StringRepeat" (repeatScalar count target) expression
  repeatScalar count target value = case target of
    Nothing -> Right (String (T.replicate count value))
    Just targetLength
      | T.null value && targetLength > 0 ->
          Left
            ( EvaluationError
                "StringRepeat cannot pad an empty string to a positive length."
            )
      | T.null value -> Right (String "")
      | otherwise ->
          let needed = ceilingDiv targetLength (T.length value)
           in Right (String (T.take targetLength (T.replicate (max count needed) value)))

reduceStringPad :: Bool -> [Expr] -> Either EvaluationError Expr
reduceStringPad leftMode values = case values of
  [expression, targetExpression] -> pad expression targetExpression (String " ")
  [expression, targetExpression, paddingExpression] ->
    pad expression targetExpression paddingExpression
  _ ->
    Left
      ( EvaluationError
          ( operation
              <> " expects a string, a target length, and an optional padding."
          )
      )
 where
  operation = if leftMode then "StringPadLeft" else "StringPadRight"
  pad expression targetExpression paddingExpression = do
    target <-
      requireNonnegativeInt
        (operation <> " expects a non-negative integer target length.")
        targetExpression
    padding <- case paddingExpression of
      String value -> Right value
      _ -> Left (EvaluationError (operation <> " currently expects a string padding value."))
    if T.null padding
      then Left (EvaluationError "String padding character must be a non-empty string.")
      else stringThread operation (Right . String . padText target padding) expression
  padText target padding value
    | T.length value >= target =
        if leftMode
          then T.drop (T.length value - target) value
          else T.take target value
    | otherwise =
        let needed = target - T.length value
            block = T.take needed (T.replicate (ceilingDiv needed (T.length padding)) padding)
         in if leftMode then block <> value else value <> block

requireNonnegativeInt :: Text -> Expr -> Either EvaluationError Int
requireNonnegativeInt message = \case
  Integer value
    | value >= 0
    , value <= fromIntegral (maxBound :: Int) -> Right (fromIntegral value)
  _ -> Left (EvaluationError message)

ceilingDiv :: Int -> Int -> Int
ceilingDiv numerator denominator
  | numerator <= 0 = 0
  | otherwise = (numerator + denominator - 1) `div` denominator

reduceStringSplit :: [Expr] -> Either EvaluationError Expr
reduceStringSplit = \case
  [expression] ->
    stringThread
      "StringSplit"
      (Right . evaluatedList . map String . T.words)
      expression
  [expression, separatorExpression] -> do
    separators <- stringSeparators separatorExpression
    stringThread
      "StringSplit"
      (Right . evaluatedList . map String . filter (not . T.null) . splitOnLiterals separators)
      expression
  _ ->
    Left
      ( EvaluationError
          "StringSplit currently expects a string and an optional separator."
      )

stringSeparators :: Expr -> Either EvaluationError [Text]
stringSeparators = \case
  String value -> Right [value]
  Call (Symbol "List") values -> traverse requireString values
  _ ->
    Left
      ( EvaluationError
          "StringSplit currently expects a literal-string separator or a list of them."
      )
 where
  requireString (String value) = Right value
  requireString _ =
    Left
      ( EvaluationError
          "StringSplit currently expects literal-string separators."
      )

splitOnLiterals :: [Text] -> Text -> [Text]
splitOnLiterals separators source = go source
 where
  retainedSeparators = filter (not . T.null) separators
  go remaining = case nextSeparator remaining retainedSeparators of
    Nothing -> [remaining]
    Just (prefix, separator) ->
      prefix : go (T.drop (T.length prefix + T.length separator) remaining)

nextSeparator :: Text -> [Text] -> Maybe (Text, Text)
nextSeparator source = foldl' choose Nothing
 where
  choose best separator =
    let (prefix, suffix) = T.breakOn separator source
     in if T.null suffix
          then best
          else case best of
            Nothing -> Just (prefix, separator)
            Just (bestPrefix, bestSeparator)
              | T.length prefix < T.length bestPrefix -> Just (prefix, separator)
              | T.length prefix == T.length bestPrefix
              , T.length separator > T.length bestSeparator -> Just (prefix, separator)
              | otherwise -> best

reduceStringRiffle :: [Expr] -> Either EvaluationError Expr
reduceStringRiffle values = case values of
  [expression] -> riffle expression "" " " ""
  [expression, String separator] -> riffle expression "" separator ""
  [ expression
    , Call (Symbol "List") [String leftDelimiter, String separator, String rightDelimiter]
    ] -> riffle expression leftDelimiter separator rightDelimiter
  [_, _] ->
    Left
      ( EvaluationError
          "StringRiffle currently expects a string separator or a {left, sep, right} triple of strings."
      )
  _ ->
    Left
      ( EvaluationError
          "StringRiffle expects a list and an optional separator or {l, sep, r} triple."
      )
 where
  riffle (Call (Symbol "List") items) leftDelimiter separator rightDelimiter = do
    rendered <- traverse (renderItem separator) items
    Right (String (leftDelimiter <> T.intercalate separator rendered <> rightDelimiter))
  riffle _ _ _ _ = Left (EvaluationError "StringRiffle expects a List as the first argument.")
  renderItem _ (String value) = Right value
  renderItem _ (Integer value) = Right (T.pack (show value))
  renderItem separator (Call (Symbol "List") items) = do
    values' <- traverse requireString items
    Right (T.intercalate separator values')
  renderItem _ _ =
    Left
      ( EvaluationError
          "StringRiffle expects items convertible to strings; non-string items beyond integers are not yet supported."
      )
  requireString (String value) = Right value
  requireString _ =
    Left
      ( EvaluationError
          "StringRiffle expects items convertible to strings; non-string items beyond integers are not yet supported."
      )

reduceStringTrim :: [Expr] -> Either EvaluationError Expr
reduceStringTrim = \case
  [expression] ->
    stringThread "StringTrim" (Right . String . T.strip) expression
  [expression, String patternText] ->
    stringThread "StringTrim" (Right . String . trimLiteral patternText) expression
  [_, _] ->
    Left
      ( EvaluationError
          "StringTrim currently expects a literal-string trim pattern."
      )
  _ ->
    Left
      ( EvaluationError
          "StringTrim expects a string and an optional literal-string trim pattern."
      )

trimLiteral :: Text -> Text -> Text
trimLiteral patternText source
  | T.null patternText = source
  | otherwise = trimEnd (trimStart source)
 where
  trimStart value = case T.stripPrefix patternText value of
    Just remaining -> trimStart remaining
    Nothing -> value
  trimEnd value = case T.stripSuffix patternText value of
    Just remaining -> trimEnd remaining
    Nothing -> value

reduceStringCount :: [Expr] -> Either EvaluationError Expr
reduceStringCount = \case
  [expression, patternExpression] -> do
    patterns <- literalStringPatterns "StringCount" patternExpression
    stringThread
      "StringCount"
      ( \value ->
          Right
            ( Integer
                ( sum
                    [ if T.null patternText
                        then 0
                        else fromIntegral (T.count patternText value)
                    | patternText <- patterns
                    ]
                )
            )
      )
      expression
  _ ->
    Left
      ( EvaluationError
          "StringCount expects a string and a literal-string pattern."
      )

data StringPredicateMode
  = StringContains
  | StringMatches
  | StringFree
  | StringStarts
  | StringEnds
  deriving (Eq, Show)

reduceStringPredicate
  :: StringPredicateMode
  -> [Expr]
  -> Either EvaluationError Expr
reduceStringPredicate mode values = case values of
  [_] -> Right (Call (Symbol operation) values)
  [expression, patternExpression] -> do
    let specifications = SP.normalizeStringPatternSpecs patternExpression
    stringThread
      operation
      (\source -> boolean <$> stringPredicateMatches mode source specifications)
      expression
  _ -> Left (EvaluationError (operation <> " expects a string and a pattern."))
 where
  operation = case mode of
    StringContains -> "StringContainsQ"
    StringMatches -> "StringMatchQ"
    StringFree -> "StringFreeQ"
    StringStarts -> "StringStartsQ"
    StringEnds -> "StringEndsQ"
  stringPredicateMatches predicateMode source specifications = do
    let requireStart = predicateMode `elem` [StringMatches, StringStarts]
        requireEnd = predicateMode `elem` [StringMatches, StringEnds]
    found <-
      stringPatternExists
        source
        specifications
        requireStart
        requireEnd
    Right (if predicateMode == StringFree then not found else found)

literalStringPatterns :: Text -> Expr -> Either EvaluationError [Text]
literalStringPatterns operation = \case
  String value -> Right [value]
  Call (Symbol "List") values -> traverse requireString values
  _ ->
    Left
      ( EvaluationError
          (operation <> " currently expects literal-string patterns.")
      )
 where
  requireString (String value) = Right value
  requireString _ =
    Left
      ( EvaluationError
          (operation <> " currently expects literal-string patterns.")
      )

reduceStringPosition :: [Expr] -> Either EvaluationError Expr
reduceStringPosition values = case values of
  [_] -> Right (Call (Symbol "StringPosition") values)
  [expression, patternExpression] -> positions expression patternExpression Nothing
  [expression, patternExpression, limitExpression] ->
    positions expression patternExpression (Just limitExpression)
  _ ->
    Left
      ( EvaluationError
          "StringPosition expects a string, a pattern, and an optional match limit."
      )
 where
  positions expression patternExpression limitExpression = do
    limit <- normalizeStringMatchLimit limitExpression
    let specifications = SP.normalizeStringPatternSpecs patternExpression
    stringThread
      "StringPosition"
      (\source -> evaluatedList . map pair <$> collectStringPatternSpans source specifications True limit)
      expression
  pair (start, end) = evaluatedList [Integer start, Integer end]

normalizeStringMatchLimit :: Maybe Expr -> Either EvaluationError (Maybe Int)
normalizeStringMatchLimit Nothing = Right Nothing
normalizeStringMatchLimit (Just (Symbol "Infinity")) = Right Nothing
normalizeStringMatchLimit (Just expression) =
  Just <$> requireNonnegativeInt "Match limits must be non-negative integers or Infinity." expression

reduceStringCases :: [Expr] -> Either EvaluationError Expr
reduceStringCases = \case
  [expression, patternExpression] ->
    cases expression patternExpression Nothing
  [expression, patternExpression, limitExpression] ->
    cases expression patternExpression (Just limitExpression)
  _ ->
    Left
      ( EvaluationError
          "StringCases expects a string, a pattern or rule, and an optional match limit."
      )
 where
  cases expression patternExpression limitExpression = do
    limit <- normalizeStringMatchLimit limitExpression
    let specifications = SP.normalizeStringCasesSpecs patternExpression
    stringThread
      "StringCases"
      (\source -> evaluatedList <$> collectStringCaseResults source specifications limit)
      expression

reduceStringReplace :: [Expr] -> Either EvaluationError Expr
reduceStringReplace = \case
  [expression, rulesExpression] ->
    replace expression rulesExpression Nothing
  [expression, rulesExpression, limitExpression] ->
    replace expression rulesExpression (Just limitExpression)
  _ ->
    Left
      ( EvaluationError
          "StringReplace expects a string, rules, and an optional replacement limit."
      )
 where
  replace expression rulesExpression limitExpression = do
    limit <- normalizeStringMatchLimit limitExpression
    specifications <-
      either (Left . EvaluationError) Right
        (SP.normalizeStringReplaceSpecs rulesExpression)
    stringThread
      "StringReplace"
      (\source -> replaceStringPatternMatches source specifications limit)
      expression

runPureStringPattern
  :: SP.StringPatternM (Either EvaluationError) value
  -> Either EvaluationError value
runPureStringPattern action = do
  result <- SP.runStringPatternM action
  either (Left . EvaluationError) Right result

evaluatePureStringExpression
  :: Map.Map Text Expr
  -> Expr
  -> Either EvaluationError Expr
evaluatePureStringExpression bindings expression =
  evaluate (substituteNamedSymbols bindings expression)

firstPureStringMatchAt
  :: Text
  -> Int
  -> [SP.StringPatternSpec]
  -> Either EvaluationError (Maybe SP.StringFoundMatch)
firstPureStringMatchAt source start specifications =
  runPureStringPattern
    ( SP.firstStringPatternMatchAtM
        evaluatePureStringExpression
        source
        start
        specifications
    )

firstPureStringMatchAtWithEnd
  :: Text
  -> Int
  -> Int
  -> [SP.StringPatternSpec]
  -> Either EvaluationError (Maybe SP.StringFoundMatch)
firstPureStringMatchAtWithEnd source start requiredEnd specifications =
  runPureStringPattern
    ( SP.firstStringPatternMatchAtWithEndM
        evaluatePureStringExpression
        source
        start
        (Just requiredEnd)
        specifications
    )

applyPureStringMatch
  :: Text
  -> SP.StringFoundMatch
  -> Either EvaluationError (Maybe Expr)
applyPureStringMatch source found =
  runPureStringPattern
    ( SP.applyStringPatternSpecM
        evaluatePureStringExpression
        source
        found
    )

pureStringMatchesForSpecAt
  :: Text
  -> Int
  -> SP.StringPatternSpec
  -> Either EvaluationError [SP.StringFoundMatch]
pureStringMatchesForSpecAt source start specification =
  runPureStringPattern
    ( SP.stringPatternMatchesForSpecAtM
        evaluatePureStringExpression
        source
        start
        specification
    )

stringPatternExists
  :: Text
  -> [SP.StringPatternSpec]
  -> Bool
  -> Bool
  -> Either EvaluationError Bool
stringPatternExists source specifications requireStart requireEnd = go firstStart
 where
  firstStart = 0
  lastStart = if requireStart then 0 else T.length source
  go start
    | start > lastStart = Right False
    | otherwise = do
        found <- firstMatchingSpecification start specifications
        case found of
          Just match
            | not requireEnd || SP.stringMatchEnd match == T.length source ->
                Right True
          _ ->
            if requireStart
              then Right False
              else go (start + 1)

  firstMatchingSpecification _ [] = Right Nothing
  firstMatchingSpecification start (specification : rest) = do
    found <-
      if requireEnd
        then
          firstPureStringMatchAtWithEnd
            source
            start
            (T.length source)
            [specification]
        else firstPureStringMatchAt source start [specification]
    case found of
      Just match
        | not requireEnd || SP.stringMatchEnd match == T.length source ->
            Right (Just match)
      _ -> firstMatchingSpecification start rest

collectStringPatternSpans
  :: Text
  -> [SP.StringPatternSpec]
  -> Bool
  -> Maybe Int
  -> Either EvaluationError [(Integer, Integer)]
collectStringPatternSpans source specifications overlaps limit = go 0 []
 where
  go start retained
    | maybe False (length retained >=) limit = Right retained
    | start > T.length source = Right retained
    | otherwise = do
        found <- firstPureStringMatchAt source start specifications
        case found of
          Nothing -> go (start + 1) retained
          Just match ->
            let end = SP.stringMatchEnd match
                next
                  | overlaps = start + 1
                  | end > start = end
                  | otherwise = start + 1
                spanValue =
                  ( fromIntegral start + 1
                  , fromIntegral end
                  )
             in go next (retained <> [spanValue])

collectStringCaseResults
  :: Text
  -> [SP.StringPatternSpec]
  -> Maybe Int
  -> Either EvaluationError [Expr]
collectStringCaseResults source specifications limit = go 0 []
 where
  go position retained
    | maybe False (length retained >=) limit = Right retained
    | position > T.length source = Right retained
    | otherwise = do
        result <- firstApplicable position specifications
        case result of
          Nothing ->
            if position >= T.length source
              then Right retained
              else go (position + 1) retained
          Just (found, value) ->
            let end = SP.stringMatchEnd found
                next = if end > position then end else position + 1
             in go next (retained <> [value])

  firstApplicable _ [] = Right Nothing
  firstApplicable position (specification : rest) = do
    matches <- pureStringMatchesForSpecAt source position specification
    tryMatches matches
   where
    tryMatches [] = firstApplicable position rest
    tryMatches (match : matches) = do
      applied <- applyPureStringMatch source match
      case applied of
        Just value -> Right (Just (match, value))
        Nothing -> tryMatches matches

replaceStringPatternMatches
  :: Text
  -> [SP.StringPatternSpec]
  -> Maybe Int
  -> Either EvaluationError Expr
replaceStringPatternMatches source specifications limit = go 0 0 []
 where
  go position replacementCount pieces
    | maybe False (replacementCount >=) limit =
        Right
          (stringExpressionFromPieces (pieces <> [String (T.drop position source)]))
    | position > T.length source = Right (stringExpressionFromPieces pieces)
    | otherwise = do
        result <- firstApplicable position specifications
        case result of
          Nothing ->
            if position >= T.length source
              then Right (stringExpressionFromPieces pieces)
              else
                go
                  (position + 1)
                  replacementCount
                  (pieces <> [String (T.take 1 (T.drop position source))])
          Just (found, value) ->
            let end = SP.stringMatchEnd found
                next = if end > position then end else position + 1
             in go next (replacementCount + 1) (pieces <> [value])

  firstApplicable _ [] = Right Nothing
  firstApplicable position (specification : rest) = do
    matches <- pureStringMatchesForSpecAt source position specification
    tryMatches matches
   where
    tryMatches [] = firstApplicable position rest
    tryMatches (match : matches) = do
      applied <- applyPureStringMatch source match
      case applied of
        Just value -> Right (Just (match, value))
        Nothing -> tryMatches matches

stringExpressionFromPieces :: [Expr] -> Expr
stringExpressionFromPieces pieces = case merge pieces of
  [] -> String ""
  [single] -> single
  merged
    | all isString merged -> String (T.concat [value | String value <- merged])
    | otherwise -> Call (Symbol "StringExpression") merged
 where
  merge = foldl append [] . concatMap flatten
  flatten (Call (Symbol stringExpressionHead) values)
    | systemHeadIn ["StringExpression"] stringExpressionHead = concatMap flatten values
  flatten expression = [expression]
  append retained (String value) = case reverse retained of
    String previous : rest -> reverse rest <> [String (previous <> value)]
    _ -> retained <> [String value]
  append retained value = retained <> [value]

reduceEquality :: Bool -> [Expr] -> Expr
reduceEquality True values
  | length values < 2 = Symbol "True"
  | allEqual values = Symbol "True"
  | Just numericValues <- traverse explicitRealExact values =
      boolean (allEqual numericValues)
  | otherwise = Call (Symbol "Equal") values
reduceEquality False values
  | length values < 2 = Symbol "True"
  | not (allDistinct values) = Symbol "False"
  | Just numericValues <- traverse explicitRealExact values =
      boolean (allDistinct numericValues)
  | otherwise = Call (Symbol "Unequal") values

reduceOrdering :: (Ordering -> Bool) -> Text -> [Expr] -> Expr
reduceOrdering relation headName values
  | length values < 2 = Symbol "True"
  | Just exactValues <- traverse toExact values =
      boolean
        ( and
            ( zipWith
                (\left right -> relation (compareExact left right))
                exactValues
                (drop 1 exactValues)
            )
        )
  | otherwise = Call (Symbol headName) values

reduceInequality :: [Expr] -> Expr
reduceInequality values
  | length values < 3 || even (length values) = Call (Symbol "Inequality") values
  | otherwise =
      let triples = inequalityTriples values
          results = map evaluateTriple triples
       in if all (== Just True) results
            then Symbol "True"
            else
              if any (== Just False) results
                then Symbol "False"
                else Call (Symbol "Inequality") values
 where
  inequalityTriples (left : Symbol comparison : right : rest) =
    (left, comparison, right) : inequalityTriples (right : rest)
  inequalityTriples _ = []
  evaluateTriple (left, comparison, right) = do
    exactLeft <- toExact left
    exactRight <- toExact right
    relation <- case comparison of
      "Less" -> Just (== LT)
      "LessEqual" -> Just (/= GT)
      "Greater" -> Just (== GT)
      "GreaterEqual" -> Just (/= LT)
      "Equal" -> Just (== EQ)
      "Unequal" -> Just (/= EQ)
      _ -> Nothing
    pure (relation (compareExact exactLeft exactRight))

unary :: Text -> (Expr -> Expr) -> [Expr] -> Expr
unary _ function [value] = function value
unary headName _ values = Call (Symbol headName) values

unaryCallArguments :: Text -> ([Expr] -> [Expr]) -> [Expr] -> Expr
unaryCallArguments _ function [Call expressionHead values] = Call expressionHead (function values)
unaryCallArguments headName _ values = Call (Symbol headName) values

reduceParity :: Bool -> Text -> [Expr] -> Expr
reduceParity evenMode _ [Integer value] = boolean (even value == evenMode)
reduceParity _ headName values = Call (Symbol headName) values

reduceFirstLast :: Bool -> Text -> [Expr] -> Expr
reduceFirstLast first _ [association]
  | Just entries <- associationEntries association
  , AssociationEntry _ _ value : remaining <- entries =
      if first then value else foldl' (\_ (AssociationEntry _ _ next) -> next) value remaining
reduceFirstLast first _ [Call _ (value : remaining)] =
  if first then value else foldl' (\_ next -> next) value remaining
reduceFirstLast _ headName values = Call (Symbol headName) values

reduceRestMost :: Bool -> Text -> [Expr] -> Expr
reduceRestMost rest _ [association]
  | Just entries@(_ : _) <- associationEntries association =
      associationExpr (if rest then drop 1 entries else reverse (drop 1 (reverse entries)))
reduceRestMost rest _ [Call expressionHead values@(_ : _)] =
  Call expressionHead (if rest then drop 1 values else reverse (drop 1 (reverse values)))
reduceRestMost _ headName values = Call (Symbol headName) values

reducePart :: [Expr] -> Either EvaluationError Expr
reducePart values@[] = invalidPartArity values
reducePart values@[_] = invalidPartArity values
reducePart (sparse@SparseArray {} : specifications) =
  sparseArrayPart sparse specifications
reducePart (target : specifications) = selectRecursively target specifications
 where
  selectRecursively expression [] = Right expression
  selectRecursively expression (specification : remaining) = do
    (selected, multiple) <- resolvePartSelections expression specification
    case (multiple, selected) of
      (False, [selection]) ->
        selectRecursively (selectedPartValue selection) remaining
      (False, _) -> invalidPartSelection expression
      (True, _) -> do
        transformed <-
          traverse
            (\selection -> selectRecursively (selectedPartValue selection) remaining)
            selected
        rebuildPartSelections expression selected transformed

resolvePartSelections :: Expr -> Expr -> Either EvaluationError ([SelectedPart], Bool)
resolvePartSelections expression (Integer 0) =
  Right ([SelectedExpression (headExpr expression)], False)
resolvePartSelections expression specification
  | Just entries <- associationEntries expression =
      resolveAssociationPartSelections expression entries specification
resolvePartSelections expression@(Call _ values) specification = do
  (indices, invalid) <- resolveNumericPartSelectors (length values) specification
  if invalid
    then invalidPartSelection expression
    else
      Right
        ( [SelectedExpression (values !! index) | index <- indices]
        , isMultiplePartSpecification specification
        )
resolvePartSelections expression _ = invalidPartSelection expression

resolveAssociationPartSelections
  :: Expr
  -> [AssociationEntry]
  -> Expr
  -> Either EvaluationError ([SelectedPart], Bool)
resolveAssociationPartSelections expression entries specification =
  case specification of
    Call (Symbol "List") selectors -> resolveSelectorList selectors
    _
      | Just selector <- associationPartSelector specification ->
          selectAssociation False [selector]
      | otherwise -> do
          (indices, invalid) <- resolveNumericPartSelectors (length entries) specification
          if invalid
            then invalidPartSelection expression
            else selectAssociation (isMultiplePartSpecification specification) (map indexSelector indices)
 where
  resolveSelectorList selectors =
    case traverse associationSelectorKind selectors of
      Nothing -> unsupportedSelectorInside (Call (Symbol "List") selectors)
      Just kinds
        | any id kinds && any not kinds ->
            Left
              ( EvaluationError
                  "Association selector lists may not mix numeric and key selectors."
              )
        | any id kinds ->
            selectAssociation True (mapMaybe associationPartSelector selectors)
        | otherwise -> do
            (indices, invalid) <- resolveNumericPartSelectors (length entries) (Call (Symbol "List") selectors)
            if invalid
              then invalidPartSelection expression
              else selectAssociation True (map indexSelector indices)

  selectAssociation multiple selectors =
    case traverse (`associationEntryForSelector` entries) selectors of
      Nothing -> invalidPartSelection expression
      Just selected -> Right (map SelectedAssociation selected, multiple)

  indexSelector index = ArgumentSelector (fromIntegral index + 1)

resolveNumericPartSelectors :: Int -> Expr -> Either EvaluationError ([Int], Bool)
resolveNumericPartSelectors count specification = case specification of
  Integer 0 ->
    Left (EvaluationError "Part does not support index 0 in this position.")
  Integer position ->
    Right (maybe [] pure resolved, maybe True (const False) resolved)
   where
    resolved = resolvePosition count position
  Symbol "All" -> Right ([0 .. count - 1], False)
  spanSpecification@(Call (Symbol "Span") _) -> do
    positions <- expandPartSpan count spanSpecification
    let resolved = map (resolvePosition count) positions
    Right (mapMaybe id resolved, any (maybe True (const False)) resolved)
  Call (Symbol "List") selectors -> foldM appendSelector ([], False) selectors
  selector
    | isPartKeySelector selector -> unsupportedSelectorInside selector
    | otherwise -> unsupportedPartSpecification selector
 where
  appendSelector (selected, invalid) selector
    | isPartKeySelector selector = unsupportedSelectorInside selector
    | otherwise = do
        (nested, nestedInvalid) <- resolveNumericPartSelectors count selector
        Right (selected <> nested, invalid || nestedInvalid)

expandPartSpan :: Int -> Expr -> Either EvaluationError [Integer]
expandPartSpan count (Call (Symbol "Span") arguments') = case arguments' of
  [startExpression, endExpression] ->
    expand startExpression endExpression (Integer 1)
  [startExpression, endExpression, stepExpression] ->
    expand startExpression endExpression stepExpression
  _ -> Left (EvaluationError "Span must contain two or three arguments.")
 where
  expand startExpression endExpression stepExpression = do
    step <- case stepExpression of
      Integer value -> Right value
      _ -> Left (EvaluationError "Span steps must be integers.")
    if step == 0
      then Left (EvaluationError "Span step cannot be zero.")
      else
        let start = spanEndpoint startExpression 1
            end = spanEndpoint endExpression (fromIntegral count)
         in Right
              ( if step > 0 && start <= end || step < 0 && start >= end
                  then [start, start + step .. end]
                  else []
              )
  spanEndpoint endpoint defaultValue = case endpoint of
    Symbol "All" -> fromIntegral count
    Integer value
      | value < 0 -> fromIntegral count + value + 1
      | otherwise -> value
    _ -> defaultValue
expandPartSpan _ _ = Left (EvaluationError "Span must contain two or three arguments.")

rebuildPartSelections
  :: Expr
  -> [SelectedPart]
  -> [Expr]
  -> Either EvaluationError Expr
rebuildPartSelections expression selected transformed
  | Just _ <- associationEntries expression =
      associationExpr
        <$> traverse
          (uncurry replaceSelectedAssociationValue)
          (zip selected transformed)
rebuildPartSelections (Call expressionHead _) _ transformed =
  Right (Call expressionHead transformed)
rebuildPartSelections expression _ _ = invalidPartSelection expression

selectedPartValue :: SelectedPart -> Expr
selectedPartValue (SelectedExpression expression) = expression
selectedPartValue (SelectedAssociation entry) = associationEntryValue entry

replaceSelectedAssociationValue
  :: SelectedPart
  -> Expr
  -> Either EvaluationError AssociationEntry
replaceSelectedAssociationValue (SelectedAssociation (AssociationEntry ruleHead key _)) value =
  Right (AssociationEntry ruleHead key value)
replaceSelectedAssociationValue (SelectedExpression _) _ =
  Left (EvaluationError "Part encountered an invalid internal Association selection")

associationSelectorKind :: Expr -> Maybe Bool
associationSelectorKind selector
  | isPartKeySelector selector = Just True
associationSelectorKind Integer {} = Just False
associationSelectorKind (Symbol "All") = Just False
associationSelectorKind (Call (Symbol "Span") _) = Just False
associationSelectorKind _ = Nothing

isPartKeySelector :: Expr -> Bool
isPartKeySelector String {} = True
isPartKeySelector selector = maybe False (const True) (keySelectorValue selector)

isMultiplePartSpecification :: Expr -> Bool
isMultiplePartSpecification (Symbol "All") = True
isMultiplePartSpecification (Call (Symbol "Span") _) = True
isMultiplePartSpecification (Call (Symbol "List") _) = True
isMultiplePartSpecification _ = False

invalidPartSelection :: Expr -> Either EvaluationError value
invalidPartSelection expression =
  Left
    ( EvaluationError
        ("Part specifications are invalid for " <> partDiagnosticForm expression <> ".")
    )

unsupportedPartSpecification :: Expr -> Either EvaluationError value
unsupportedPartSpecification selector =
  Left
    ( EvaluationError
        ("Unsupported Part specification: " <> partDiagnosticForm selector <> ".")
    )

unsupportedSelectorInside :: Expr -> Either EvaluationError value
unsupportedSelectorInside selector =
  Left
    ( EvaluationError
        ( "Unsupported selector inside Part specification: "
            <> partDiagnosticForm selector
            <> "."
        )
    )

partDiagnosticForm :: Expr -> Text
partDiagnosticForm = inputForm

invalidPartArity :: [Expr] -> Either EvaluationError Expr
invalidPartArity _ =
  Left
    ( EvaluationError
        "Part expects an expression and at least one part specification."
    )

data SparseAxisSelection
  = SparseScalar !Integer
  | SparseProjection !SparseIndexSequence

data SparseIndexSequence
  = SparseOne !Integer
  | SparseAll !Integer
  | SparseSpan !Integer !Integer !Integer
  | SparseConcatenate ![SparseIndexSequence]

sparseArrayPart
  :: Expr
  -> [Expr]
  -> Either EvaluationError Expr
sparseArrayPart (SparseArray dimensions entries fill) specifications
  | length specifications > length dimensions =
      Left
        ( EvaluationError
            "Part received too many specifications for SparseArray."
        )
  | otherwise = do
      specified <-
        sequence
          [ if axis < length specifications
              then normalizeSparseSelector dimension (specifications !! axis)
              else Right (SparseProjection (SparseAll dimension))
          | (axis, dimension) <- zip [0 :: Int ..] dimensions
          ]
      case traverse sparseScalarValue specified of
        Just indices -> Right (sparseValueAt entries fill indices)
        Nothing -> do
          let outputDimensions =
                [ sparseSequenceLength sequenceExpression
                | SparseProjection sequenceExpression <- specified
                ]
          outputPairs <- concat <$> traverse (projectEntry specified) entries
          canonicalSparseArray outputDimensions outputPairs fill
 where
  projectEntry selections (SparseEntry sourceIndices value) =
    if or
      [ source /= selected
      | (SparseScalar selected, source) <- zip selections sourceIndices
      ]
      then Right []
      else
        let options =
              [ sparseSequencePositions sequenceExpression source
              | (SparseProjection sequenceExpression, source) <-
                  zip selections sourceIndices
              ]
         in if any null options
              then Right []
              else
                Right
                  [ (indices, value)
                  | indices <- cartesianIndices options
                  ]
sparseArrayPart _ _ =
  Left (EvaluationError "Part currently expects a SparseArray value.")

sparseValueAt :: [SparseEntry] -> Expr -> [Integer] -> Expr
sparseValueAt entries fill target = go entries
 where
  go [] = fill
  go (SparseEntry indices value : remaining)
    | indices == target = value
    | otherwise = go remaining

sparseScalarValue :: SparseAxisSelection -> Maybe Integer
sparseScalarValue (SparseScalar index) = Just index
sparseScalarValue SparseProjection {} = Nothing

normalizeSparseSelector
  :: Integer
  -> Expr
  -> Either EvaluationError SparseAxisSelection
normalizeSparseSelector dimension = \case
  Integer position -> SparseScalar <$> resolveSparsePosition dimension position
  Symbol allName
    | systemHeadIn ["All"] allName ->
        Right (SparseProjection (SparseAll dimension))
  spanExpression@(Call (Symbol spanHead) _)
    | systemHeadIn ["Span"] spanHead ->
        SparseProjection <$> normalizeSparseSpan dimension spanExpression
  Call (Symbol listHead) values
    | systemHeadIn ["List"] listHead ->
        SparseProjection . SparseConcatenate
          <$> traverse (normalizeSparseSequence dimension) values
  selector ->
    Left
      ( EvaluationError
          ( "Unsupported Part specification for SparseArray: "
              <> inputForm selector
              <> "."
          )
      )

normalizeSparseSequence
  :: Integer
  -> Expr
  -> Either EvaluationError SparseIndexSequence
normalizeSparseSequence dimension = \case
  Integer position -> SparseOne <$> resolveSparsePosition dimension position
  Symbol allName
    | systemHeadIn ["All"] allName -> Right (SparseAll dimension)
  spanExpression@(Call (Symbol spanHead) _)
    | systemHeadIn ["Span"] spanHead -> normalizeSparseSpan dimension spanExpression
  Call (Symbol listHead) values
    | systemHeadIn ["List"] listHead ->
        SparseConcatenate <$> traverse (normalizeSparseSequence dimension) values
  selector ->
    Left
      ( EvaluationError
          ( "Unsupported Part specification for SparseArray: "
              <> inputForm selector
              <> "."
          )
      )

resolveSparsePosition
  :: Integer
  -> Integer
  -> Either EvaluationError Integer
resolveSparsePosition dimension position
  | position > 0
  , position <= dimension = Right position
  | position < 0
  , position >= negate dimension = Right (dimension + position + 1)
  | otherwise =
      Left
        ( EvaluationError
            "Part specifications are invalid for SparseArray."
        )

normalizeSparseSpan
  :: Integer
  -> Expr
  -> Either EvaluationError SparseIndexSequence
normalizeSparseSpan dimension (Call _ arguments') = case arguments' of
  [startExpression, endExpression] ->
    build startExpression endExpression (Integer 1)
  [startExpression, endExpression, stepExpression] ->
    build startExpression endExpression stepExpression
  _ -> Left (EvaluationError "Span must contain two or three arguments.")
 where
  build startExpression endExpression stepExpression = do
    step <- case stepExpression of
      Integer value -> Right value
      _ -> Left (EvaluationError "Span steps must be integers.")
    if step == 0
      then Left (EvaluationError "Span step cannot be zero.")
      else do
        let start = sparseSpanEndpoint startExpression 1
            end = sparseSpanEndpoint endExpression dimension
            count
              | step > 0 && start <= end = (end - start) `div` step + 1
              | step < 0 && start >= end = (start - end) `div` negate step + 1
              | otherwise = 0
            finalPosition = if count == 0 then start else start + (count - 1) * step
        if count > 0
          && ( start < 1
                 || start > dimension
                 || finalPosition < 1
                 || finalPosition > dimension
             )
          then
            Left
              ( EvaluationError
                  "Part specifications are invalid for SparseArray."
              )
          else Right (SparseSpan start step count)
  sparseSpanEndpoint endpoint defaultValue = case endpoint of
    Symbol allName
      | systemHeadIn ["All"] allName -> dimension
    Integer value
      | value < 0 -> dimension + value + 1
      | otherwise -> value
    _ -> defaultValue
normalizeSparseSpan _ _ =
  Left (EvaluationError "Span must contain two or three arguments.")

sparseSequenceLength :: SparseIndexSequence -> Integer
sparseSequenceLength = \case
  SparseOne _ -> 1
  SparseAll dimension -> dimension
  SparseSpan _ _ count -> count
  SparseConcatenate sequences -> sum (map sparseSequenceLength sequences)

sparseSequencePositions :: SparseIndexSequence -> Integer -> [Integer]
sparseSequencePositions sequenceExpression source = case sequenceExpression of
  SparseOne selected -> [1 | source == selected]
  SparseAll dimension -> [source | source >= 1 && source <= dimension]
  SparseSpan start step count
    | count <= 0 -> []
    | step > 0
    , source >= start
    , source <= start + (count - 1) * step
    , (source - start) `mod` step == 0 -> [(source - start) `div` step + 1]
    | step < 0
    , source <= start
    , source >= start + (count - 1) * step
    , (start - source) `mod` negate step == 0 -> [(start - source) `div` negate step + 1]
    | otherwise -> []
  SparseConcatenate sequences -> go 0 sequences
 where
  go _ [] = []
  go offset (current : remaining) =
    map (+ offset) (sparseSequencePositions current source)
      <> go (offset + sparseSequenceLength current) remaining

cartesianIndices :: [[Integer]] -> [[Integer]]
cartesianIndices = foldr extend [[]]
 where
  extend values suffixes = [value : suffix | value <- values, suffix <- suffixes]

reduceExtract :: [Expr] -> Either EvaluationError Expr
reduceExtract [sparse@SparseArray {}, positions] = case sparseExtractPaths positions of
  Nothing ->
    Left
      ( EvaluationError
          "Extract positions must be a position list or a list of position lists."
      )
  Just (paths, multiple) -> do
    selected <- traverse (sparseArrayPart sparse) paths
    case selected of
      firstSelected : _ ->
        Right (if multiple then evaluatedList selected else firstSelected)
      [] -> Left (EvaluationError "Extract received an empty internal position set")
reduceExtract [subject, positions] = do
  let paths = positionPaths positions
  if null paths
    then Left (EvaluationError "Extract received an invalid position specification")
    else do
      selected <- traverse extractPath paths
      case selected of
        firstSelected : _ ->
          pure (if hasMultiplePositionPaths positions then evaluatedList selected else firstSelected)
        [] -> Left (EvaluationError "Extract received an empty internal position set")
 where
  extractPath path =
    maybe
      (Left (EvaluationError "Extract received an invalid position"))
      Right
      (selectAtPath path subject)
reduceExtract values = Right (Call (Symbol "Extract") values)

sparseExtractPaths :: Expr -> Maybe ([[Expr]], Bool)
sparseExtractPaths position
  | sparseSelectorAtom position = Just ([[position]], False)
sparseExtractPaths (Call (Symbol listHead) values)
  | systemHeadIn ["List"] listHead
  , not (null values)
  , Just paths <- traverse sparseExplicitPath values = Just (paths, True)
  | systemHeadIn ["List"] listHead
  , all sparsePositionComponent values = Just ([values], False)
sparseExtractPaths _ = Nothing

sparseExplicitPath :: Expr -> Maybe [Expr]
sparseExplicitPath (Call (Symbol listHead) components)
  | systemHeadIn ["List"] listHead
  , all sparsePositionComponent components = Just components
sparseExplicitPath _ = Nothing

sparsePositionComponent :: Expr -> Bool
sparsePositionComponent expression
  | sparseSelectorAtom expression = True
sparsePositionComponent (Call (Symbol listHead) values)
  | systemHeadIn ["List"] listHead = all sparseSelectorAtom values
sparsePositionComponent _ = False

sparseSelectorAtom :: Expr -> Bool
sparseSelectorAtom Integer {} = True
sparseSelectorAtom (Symbol allName) = systemHeadIn ["All"] allName
sparseSelectorAtom (Call (Symbol spanHead) _) = systemHeadIn ["Span"] spanHead
sparseSelectorAtom _ = False

data AssociationEntry = AssociationEntry !Text !Expr !Expr
  deriving (Eq, Show)

data SelectedPart
  = SelectedExpression !Expr
  | SelectedAssociation !AssociationEntry
  deriving (Eq, Show)

data PathSelector
  = ArgumentSelector !Integer
  | KeySelector !Expr
  deriving (Eq, Show)

keySelectorValue :: Expr -> Maybe Expr
keySelectorValue (Call (Symbol "Key") [key]) = Just key
keySelectorValue _ = Nothing

associationPartSelector :: Expr -> Maybe PathSelector
associationPartSelector (Integer position) = Just (ArgumentSelector position)
associationPartSelector selector
  | Just key <- keySelectorValue selector = Just (KeySelector key)
associationPartSelector key@String {} = Just (KeySelector key)
associationPartSelector _ = Nothing

associationEntryValue :: AssociationEntry -> Expr
associationEntryValue (AssociationEntry _ _ value) = value

associationEntryForSelector :: PathSelector -> [AssociationEntry] -> Maybe AssociationEntry
associationEntryForSelector selector entries = do
  index <- associationEntryIndex selector entries
  pure (entries !! index)

associationEntryIndex :: PathSelector -> [AssociationEntry] -> Maybe Int
associationEntryIndex (ArgumentSelector position) entries =
  resolvePosition (length entries) position
associationEntryIndex (KeySelector key) entries = go 0 entries
 where
  go _ [] = Nothing
  go index (AssociationEntry _ candidate _ : rest)
    | key == candidate = Just index
    | otherwise = go (index + 1) rest

ruleEntry :: Expr -> Maybe AssociationEntry
ruleEntry (Call (Symbol ruleHead) [key, value])
  | systemHeadIn ["Rule", "RuleDelayed"] ruleHead =
      Just (AssociationEntry ruleHead key value)
ruleEntry _ = Nothing

associationEntries :: Expr -> Maybe [AssociationEntry]
associationEntries (Call (Symbol associationHead) values)
  | systemHeadIn ["Association"] associationHead = traverse ruleEntry values
associationEntries _ = Nothing

isFailureValue :: Expr -> Bool
isFailureValue (Call (Symbol failureHead) _) =
  systemHeadIn ["Failure"] failureHead
isFailureValue _ = False

isMissingValue :: Expr -> Bool
isMissingValue (Call (Symbol missingHead) _) =
  systemHeadIn ["Missing"] missingHead
isMissingValue _ = False

isFailureQValue :: Expr -> Bool
isFailureQValue expression =
  isFailureValue expression
    || expression `elem` [Symbol "$Failed", Symbol "$Canceled", Symbol "$Aborted"]

reduceFailureApplication
  :: Expr
  -> [Expr]
  -> Either EvaluationError Expr
reduceFailureApplication failure = \case
  [key] -> failureProperty failure key
  values -> Right (Call failure values)

failureProperty :: Expr -> Expr -> Either EvaluationError Expr
failureProperty failure key@(String propertyName)
  | propertyName `elem` ["Type", "FailureType"]
  , Call _ (failureType : _) <- failure = Right failureType
  | otherwise =
      Right
        ( maybe
            (Call (Symbol "Missing") [String "KeyAbsent", key])
            associationEntryValue
            (findFailureEntry key (failureEntries failure))
        )
failureProperty _ _ =
  Left
    ( EvaluationError
        "Failure property lookup expects a string key."
    )

failureEntries :: Expr -> [AssociationEntry]
failureEntries (Call _ (_ : details : _)) =
  case associationEntries details of
    Just entries -> entries
    Nothing -> case details of
      Call (Symbol listHead) values
        | systemHeadIn ["List"] listHead -> mapMaybe ruleEntry values
      _ -> []
failureEntries _ = []

findFailureEntry :: Expr -> [AssociationEntry] -> Maybe AssociationEntry
findFailureEntry _ [] = Nothing
findFailureEntry key (entry@(AssociationEntry _ candidate _) : rest)
  | key == candidate = Just entry
  | otherwise = findFailureEntry key rest

isAssociation :: Expr -> Bool
isAssociation = maybe False (const True) . associationEntries

associationExpr :: [AssociationEntry] -> Expr
associationExpr entries =
  Call (Symbol "Association") (map entryExpression (normalizeAssociationEntries entries))
 where
  entryExpression (AssociationEntry ruleHead key value) =
    Call (Symbol ruleHead) [key, value]

normalizeAssociationEntries :: [AssociationEntry] -> [AssociationEntry]
normalizeAssociationEntries = foldl' insertEntry []
 where
  insertEntry retained entry@(AssociationEntry _ key _) =
    case matchingIndex key retained of
      Just index -> replaceListIndex index entry retained
      Nothing -> retained <> [entry]
  matchingIndex key = go 0
   where
    go _ [] = Nothing
    go index (AssociationEntry _ candidate _ : rest)
      | key == candidate = Just index
      | otherwise = go (index + 1) rest

reduceAssociation :: [Expr] -> Expr
reduceAssociation values = case associationFromArguments values of
  Just entries -> associationExpr entries
  Nothing -> Call (Symbol "Association") values

associationFromArguments :: [Expr] -> Maybe [AssociationEntry]
associationFromArguments [Call (Symbol listHead) values]
  | systemHeadIn ["List"] listHead =
      traverse ruleEntry values
associationFromArguments values =
  concat <$> traverse entriesFromArgument (filter (/= Symbol "Nothing") values)
 where
  entriesFromArgument argument =
    case associationEntries argument of
      Just entries -> Just entries
      Nothing -> pure <$> ruleEntry argument

requireAssociation :: Text -> Expr -> Either EvaluationError [AssociationEntry]
requireAssociation operation expression =
  maybe
    (Left (EvaluationError (operation <> " expects an Association")))
    Right
    (associationEntries expression)

evaluatedList :: [Expr] -> Expr
evaluatedList = list . filter (/= Symbol "Nothing")

reduceKeys :: [Expr] -> Either EvaluationError Expr
reduceKeys [association] = do
  entries <- requireAssociation "Keys" association
  pure (evaluatedList [key | AssociationEntry _ key _ <- entries])
reduceKeys values = Right (Call (Symbol "Keys") values)

reduceValues :: [Expr] -> Either EvaluationError Expr
reduceValues [association] = do
  entries <- requireAssociation "Values" association
  pure (evaluatedList [value | AssociationEntry _ _ value <- entries])
reduceValues values = Right (Call (Symbol "Values") values)

reduceNormal :: [Expr] -> Either EvaluationError Expr
reduceNormal [sparse@SparseArray {}] = sparseArrayNormal sparse
reduceNormal [association] = case associationEntries association of
  Just entries ->
    pure
      ( list
          [ Call (Symbol ruleHead) [key, value]
          | AssociationEntry ruleHead key value <- entries
          ]
      )
  Nothing -> case association of
    ByteArray bytes ->
      Right (evaluatedList (map (Integer . fromIntegral) (BS.unpack bytes)))
    _ -> Right (Call (Symbol "Normal") [association])
reduceNormal values = Right (Call (Symbol "Normal") values)

reduceLookup :: [Expr] -> Either EvaluationError Expr
reduceLookup = \case
  [association, keySpecification] -> lookupWithDefault association keySpecification Nothing
  [association, keySpecification, defaultValue] ->
    lookupWithDefault association keySpecification (Just defaultValue)
  values -> Right (Call (Symbol "Lookup") values)
 where
  lookupWithDefault association keySpecification defaultValue = do
    entries <- requireAssociation "Lookup" association
    let lookupOne key = case findAssociationEntry key entries of
          Just (AssociationEntry _ _ value) -> value
          Nothing -> case defaultValue of
            Just value -> value
            Nothing -> Call (Symbol "Missing") [String "KeyAbsent", key]
    pure $ case keySpecification of
      Call (Symbol "List") keys -> evaluatedList (map lookupOne keys)
      key -> lookupOne key

findAssociationEntry :: Expr -> [AssociationEntry] -> Maybe AssociationEntry
findAssociationEntry _ [] = Nothing
findAssociationEntry key (entry@(AssociationEntry _ candidate _) : rest)
  | key == candidate = Just entry
  | otherwise = findAssociationEntry key rest

reduceKeyExistsQ :: Text -> [Expr] -> Either EvaluationError Expr
reduceKeyExistsQ _ [association, key] = do
  entries <- requireAssociation "KeyExistsQ" association
  pure (boolean (maybe False (const True) (findAssociationEntry key entries)))
reduceKeyExistsQ headName values = Right (Call (Symbol headName) values)

keySpecificationItems :: Expr -> [Expr]
keySpecificationItems (Call (Symbol "List") values) = values
keySpecificationItems value = [value]

reduceKeyTakeDrop :: Bool -> [Expr] -> Either EvaluationError Expr
reduceKeyTakeDrop takeMode [association, keySpecification] = do
  entries <- requireAssociation operationName association
  let keys = keySpecificationItems keySpecification
      selected
        | takeMode = mapMaybe (`findAssociationEntry` entries) keys
        | otherwise =
            [ entry
            | entry@(AssociationEntry _ key _) <- entries
            , key `notElem` keys
            ]
  pure (associationExpr selected)
 where
  operationName = if takeMode then "KeyTake" else "KeyDrop"
reduceKeyTakeDrop takeMode values =
  Right (Call (Symbol (if takeMode then "KeyTake" else "KeyDrop")) values)

reduceKeySelect :: [Expr] -> Either EvaluationError Expr
reduceKeySelect [association, criterion] = do
  entries <- requireAssociation "KeySelect" association
  retained <- traverse retain entries
  pure (associationExpr [entry | (True, entry) <- retained])
 where
  retain entry@(AssociationEntry _ key _) = do
    result <- evaluate (Call criterion [key])
    pure (result == Symbol "True", entry)
reduceKeySelect values = Right (Call (Symbol "KeySelect") values)

reduceKeyMap :: [Expr] -> Either EvaluationError Expr
reduceKeyMap [function, association] = do
  entries <- requireAssociation "KeyMap" association
  pure
    ( associationExpr
        [ AssociationEntry ruleHead (Call function [key]) value
        | AssociationEntry ruleHead key value <- entries
        ]
    )
reduceKeyMap values = Right (Call (Symbol "KeyMap") values)

reduceKeyValueMap :: [Expr] -> Either EvaluationError Expr
reduceKeyValueMap [function, association] = do
  entries <- requireAssociation "KeyValueMap" association
  pure
    ( evaluatedList
        [ Call function [key, value]
        | AssociationEntry _ key value <- entries
        ]
    )
reduceKeyValueMap values = Right (Call (Symbol "KeyValueMap") values)

reduceAssociationThread :: [Expr] -> Either EvaluationError Expr
reduceAssociationThread [Call (Symbol "List") keys, Call (Symbol "List") values]
  | length keys == length values =
      Right
        ( associationExpr
            (zipWith (AssociationEntry "Rule") keys values)
        )
  | otherwise = Left (EvaluationError "AssociationThread expects key and value lists of equal length")
reduceAssociationThread values = Right (Call (Symbol "AssociationThread") values)

reduceAssociationMap :: [Expr] -> Either EvaluationError Expr
reduceAssociationMap [function, Call (Symbol "List") keys] =
  Right
    ( associationExpr
        [AssociationEntry "Rule" key (Call function [key]) | key <- keys]
    )
reduceAssociationMap values = Right (Call (Symbol "AssociationMap") values)

reduceKeySort :: [Expr] -> Either EvaluationError Expr
reduceKeySort [association] = do
  entries <- requireAssociation "KeySort" association
  pure (associationExpr (sortBy compareKey entries))
 where
  compareKey (AssociationEntry _ left _) (AssociationEntry _ right _) =
    canonicalCompare left right
reduceKeySort values = Right (Call (Symbol "KeySort") values)

reduceMerge :: [Expr] -> Either EvaluationError Expr
reduceMerge [Call (Symbol "List") associations, combiner] = do
  entryLists <- traverse (requireAssociation "Merge") associations
  let groups = foldl' addEntryGroup [] (concat entryLists)
  combined <- traverse combineGroup groups
  pure (associationExpr combined)
 where
  addEntryGroup groups (AssociationEntry ruleHead key value) =
    case groupIndex key groups of
      Nothing -> groups <> [(ruleHead, key, [value])]
      Just index -> case groups !! index of
        (firstRuleHead, firstKey, groupedValues) ->
          replaceListIndex index (firstRuleHead, firstKey, groupedValues <> [value]) groups
  combineGroup (ruleHead, key, groupedValues) = do
    combinedValue <- evaluate (Call combiner [list groupedValues])
    pure (AssociationEntry ruleHead key combinedValue)
  groupIndex key = go 0
   where
    go _ [] = Nothing
    go index ((_, candidate, _) : rest)
      | key == candidate = Just index
      | otherwise = go (index + 1) rest
reduceMerge values = Right (Call (Symbol "Merge") values)

data ValueGroup = ValueGroup !Expr ![Expr]
  deriving (Eq, Show)

addValueGroup :: Expr -> Expr -> [ValueGroup] -> [ValueGroup]
addValueGroup key value groups = case valueGroupIndex key groups of
  Nothing -> groups <> [ValueGroup key [value]]
  Just index -> case groups !! index of
    ValueGroup firstKey groupedValues ->
      replaceListIndex index (ValueGroup firstKey (groupedValues <> [value])) groups

valueGroupIndex :: Expr -> [ValueGroup] -> Maybe Int
valueGroupIndex key = go 0
 where
  go _ [] = Nothing
  go index (ValueGroup candidate _ : rest)
    | key == candidate = Just index
    | otherwise = go (index + 1) rest

listOrAssociationValues :: Text -> Expr -> Either EvaluationError [Expr]
listOrAssociationValues _ (Call (Symbol "List") values) = Right values
listOrAssociationValues operation association = do
  entries <- requireAssociation operation association
  pure [value | AssociationEntry _ _ value <- entries]

groupValuesBy :: Expr -> [Expr] -> Either EvaluationError [ValueGroup]
groupValuesBy keyFunction = foldM add []
 where
  add groups value = do
    key <- evaluate (Call keyFunction [value])
    pure (addValueGroup key value groups)

reduceGroupBy :: [Expr] -> Either EvaluationError Expr
reduceGroupBy [dataExpression, specification] = do
  values <- listOrAssociationValues "GroupBy" dataExpression
  let (keyFunction, valueFunction) = case specification of
        Call (Symbol "Rule") [key, value] -> (key, Just value)
        _ -> (specification, Nothing)
  groups <- groupValuesBy keyFunction values
  entries <- traverse (groupEntry valueFunction) groups
  pure (associationExpr entries)
 where
  groupEntry valueFunction (ValueGroup key groupedValues) = do
    payload <- case valueFunction of
      Nothing -> Right (list groupedValues)
      Just function -> evaluate (Call function [list groupedValues])
    pure (AssociationEntry "Rule" key payload)
reduceGroupBy values = Right (Call (Symbol "GroupBy") values)

reduceGatherBy :: [Expr] -> Either EvaluationError Expr
reduceGatherBy [dataExpression, keyFunction] = do
  values <- listOrAssociationValues "GatherBy" dataExpression
  groups <- groupValuesBy keyFunction values
  pure (list [list groupedValues | ValueGroup _ groupedValues <- groups])
reduceGatherBy values = Right (Call (Symbol "GatherBy") values)

reduceGather :: [Expr] -> Either EvaluationError Expr
reduceGather [dataExpression] = do
  values <- listOrAssociationValues "Gather" dataExpression
  let groups = foldl' (\retained value -> addValueGroup value value retained) [] values
  pure (list [list groupedValues | ValueGroup _ groupedValues <- groups])
reduceGather values = Right (Call (Symbol "Gather") values)

requireAssociationList :: Text -> Expr -> Either EvaluationError [[AssociationEntry]]
requireAssociationList operation (Call (Symbol "List") associations@(_ : _)) =
  traverse (requireAssociation operation) associations
requireAssociationList operation _ =
  Left (EvaluationError (operation <> " expects a non-empty list of Associations"))

uniqueKeys :: [AssociationEntry] -> [Expr]
uniqueKeys = foldl' appendKey []
 where
  appendKey keys (AssociationEntry _ key _)
    | key `elem` keys = keys
    | otherwise = keys <> [key]

reduceKeyComplement :: [Expr] -> Either EvaluationError Expr
reduceKeyComplement [associations] = do
  members <- requireAssociationList "KeyComplement" associations
  case members of
    firstMember : remaining ->
      let laterKeys = uniqueKeys (concat remaining)
       in pure
            ( associationExpr
                [ entry
                | entry@(AssociationEntry _ key _) <- firstMember
                , key `notElem` laterKeys
                ]
            )
    [] -> Left (EvaluationError "KeyComplement expects a non-empty list of Associations")
reduceKeyComplement values = Right (Call (Symbol "KeyComplement") values)

reduceKeyUnion :: [Expr] -> Either EvaluationError Expr
reduceKeyUnion [associations] = do
  members <- requireAssociationList "KeyUnion" associations
  let keys = uniqueKeys (concat members)
      align member =
        associationExpr
          [ case findAssociationEntry key member of
              Just entry -> entry
              Nothing ->
                AssociationEntry
                  "Rule"
                  key
                  (Call (Symbol "Missing") [String "KeyAbsent", key])
          | key <- keys
          ]
  pure (list (map align members))
reduceKeyUnion values = Right (Call (Symbol "KeyUnion") values)

reduceKeyIntersection :: [Expr] -> Either EvaluationError Expr
reduceKeyIntersection [associations] = do
  members <- requireAssociationList "KeyIntersection" associations
  case members of
    firstMember : remaining -> do
      let keys =
            [ key
            | AssociationEntry _ key _ <- firstMember
            , all (maybe False (const True) . findAssociationEntry key) remaining
            ]
          project member = associationExpr (mapMaybe (`findAssociationEntry` member) keys)
      pure (list (map project members))
    [] -> Left (EvaluationError "KeyIntersection expects a non-empty list of Associations")
reduceKeyIntersection values = Right (Call (Symbol "KeyIntersection") values)

reduceTally :: [Expr] -> Either EvaluationError Expr
reduceTally [dataExpression] = do
  values <- listOrAssociationValues "Tally" dataExpression
  let groups = foldl' (\retained value -> addValueGroup value value retained) [] values
  pure
    ( list
        [ list [key, Integer (fromIntegral (length groupedValues))]
        | ValueGroup key groupedValues <- groups
        ]
    )
reduceTally values = Right (Call (Symbol "Tally") values)

reduceCounts :: [Expr] -> Either EvaluationError Expr
reduceCounts [dataExpression] = do
  values <- listOrAssociationValues "Counts" dataExpression
  let groups = foldl' (\retained value -> addValueGroup value value retained) [] values
  pure
    ( associationExpr
        [ AssociationEntry "Rule" key (Integer (fromIntegral (length groupedValues)))
        | ValueGroup key groupedValues <- groups
        ]
    )
reduceCounts values = Right (Call (Symbol "Counts") values)

reduceCatenate :: [Expr] -> Either EvaluationError Expr
reduceCatenate [dataExpression] = do
  values <- listOrAssociationValues "Catenate" dataExpression
  nested <-
    maybe
      (Left (EvaluationError "Catenate expects lists as its first-level values"))
      Right
      (traverse listArguments values)
  pure (list (concat nested))
reduceCatenate values = Right (Call (Symbol "Catenate") values)

reduceDifferences :: [Expr] -> Either EvaluationError Expr
reduceDifferences [Call (Symbol "List") values] =
  Right
    ( list
        ( zipWith
            (\left right -> reducePlus [right, reduceTimes [Integer (-1), left]])
            values
            (drop 1 values)
        )
    )
reduceDifferences values = Right (Call (Symbol "Differences") values)

reduceRiffle :: [Expr] -> Either EvaluationError Expr
reduceRiffle [Call (Symbol "List") values, separator] = case separator of
  Call (Symbol "List") [] -> Left (EvaluationError "Riffle expects a non-empty separator list")
  Call (Symbol "List") separators -> Right (list (interleave separators values))
  _ -> Right (list (interleave [separator] values))
 where
  interleave separators values' = go 0 values'
   where
    separatorCount = length separators
    go _ [] = []
    go _ [single] = [single]
    go index (value : rest) =
      value : separators !! (index `mod` separatorCount) : go (index + 1) rest
reduceRiffle values = Right (Call (Symbol "Riffle") values)

reduceTruthCollection :: Text -> ([Bool] -> Bool) -> [Expr] -> Either EvaluationError Expr
reduceTruthCollection operation combine [dataExpression, test] = do
  values <- listOrAssociationValues operation dataExpression
  outcomes <- traverse (evaluate . Call test . pure) values
  pure (boolean (combine (map (== Symbol "True") outcomes)))
reduceTruthCollection operation _ values = Right (Call (Symbol operation) values)

reduceContains :: Text -> ([Expr] -> [Expr] -> Bool) -> [Expr] -> Either EvaluationError Expr
reduceContains operation relation [left, right] = do
  leftValues <- listOrAssociationValues operation left
  rightValues <- listOrAssociationValues operation right
  pure (boolean (relation leftValues rightValues))
reduceContains operation _ values = Right (Call (Symbol operation) values)

containsAll :: [Expr] -> [Expr] -> Bool
containsAll left right = all (`elem` left) right

containsAny :: [Expr] -> [Expr] -> Bool
containsAny left right = any (`elem` left) right

containsExactly :: [Expr] -> [Expr] -> Bool
containsExactly left right = containsAll left right && containsAll right left

reduceContainsOnly :: [Expr] -> Either EvaluationError Expr
reduceContainsOnly arguments' = do
  (dataArguments, sameTest) <- splitSameTestOption "ContainsOnly" arguments'
  case dataArguments of
    [left, right] -> do
      leftValues <- listOrAssociationValues "ContainsOnly" left
      rightValues <- listOrAssociationValues "ContainsOnly" right
      outcomes <-
        traverse
          (\value -> anyEquivalent sameTest value rightValues)
          leftValues
      pure (boolean (and outcomes))
    _ ->
      Left
        ( EvaluationError
            "ContainsOnly expects two arguments and an optional SameTest rule."
        )

splitSameTestOption
  :: Text
  -> [Expr]
  -> Either EvaluationError ([Expr], Maybe Expr)
splitSameTestOption _operation arguments' = case reverse arguments' of
  Call (Symbol ruleHead) [Symbol optionName, function] : remaining
    | systemHeadIn ["Rule", "RuleDelayed"] ruleHead
    , systemHeadIn ["SameTest"] optionName ->
        Right (reverse remaining, normalizeAutomatic function)
  _ -> Right (arguments', Nothing)
 where
  normalizeAutomatic (Symbol name)
    | systemHeadIn ["Automatic"] name = Nothing
  normalizeAutomatic value = Just value

equivalentBy :: Maybe Expr -> Expr -> Expr -> Either EvaluationError Bool
equivalentBy Nothing left right = Right (left == right)
equivalentBy (Just test) left right = do
  result <- evaluate (Call test [left, right])
  pure (result == Symbol "True")

anyEquivalent :: Maybe Expr -> Expr -> [Expr] -> Either EvaluationError Bool
anyEquivalent _ _ [] = Right False
anyEquivalent test value (candidate : remaining) = do
  matches <- equivalentBy test value candidate
  if matches
    then Right True
    else anyEquivalent test value remaining

sequenceCollectionValues :: Text -> Expr -> Either EvaluationError [Expr]
sequenceCollectionValues operation expression = do
  items <- orderedItems operation expression
  pure [value | OrderedItem _ value _ _ <- items]

reduceSplit :: [Expr] -> Either EvaluationError Expr
reduceSplit arguments' = case arguments' of
  [subject] -> split subject Nothing
  [subject, test] -> split subject (Just test)
  _ -> Left (EvaluationError "Split expects a sequence and an optional test.")
 where
  split subject test = do
    values <- sequenceCollectionValues "Split" subject
    groups <- groupAdjacent test values
    pure (evaluatedList (map evaluatedList groups))

groupAdjacent :: Maybe Expr -> [Expr] -> Either EvaluationError [[Expr]]
groupAdjacent _ [] = Right []
groupAdjacent test (firstValue : remaining) = go firstValue [firstValue] [] remaining
 where
  go _ current retained [] = Right (retained <> [current])
  go previous current retained (value : rest) = do
    matches <- equivalentBy test previous value
    if matches
      then go value (current <> [value]) retained rest
      else go value [value] (retained <> [current]) rest

reduceSplitBy :: [Expr] -> Either EvaluationError Expr
reduceSplitBy [subject, keyFunction] = do
  values <- sequenceCollectionValues "SplitBy" subject
  case values of
    [] -> Right (evaluatedList [])
    firstValue : remaining -> do
      firstKey <- evaluate (Call keyFunction [firstValue])
      groups <- go keyFunction firstKey [firstValue] [] remaining
      pure (evaluatedList (map evaluatedList groups))
 where
  go _ _ current retained [] = Right (retained <> [current])
  go callback previousKey current retained (value : rest) = do
    key <- evaluate (Call callback [value])
    if key == previousKey
      then go callback key (current <> [value]) retained rest
      else go callback key [value] (retained <> [current]) rest
reduceSplitBy _ = Left (EvaluationError "SplitBy expects a sequence and a function.")

reduceDeleteAdjacentDuplicates :: [Expr] -> Either EvaluationError Expr
reduceDeleteAdjacentDuplicates arguments' = case arguments' of
  [subject] -> delete subject Nothing
  [subject, test] -> delete subject (Just test)
  _ ->
    Left
      ( EvaluationError
          "DeleteAdjacentDuplicates expects a sequence and an optional test."
      )
 where
  delete subject test = do
    values <- sequenceCollectionValues "DeleteAdjacentDuplicates" subject
    evaluatedList <$> retainAdjacent test values
  retainAdjacent _ [] = Right []
  retainAdjacent test (firstValue : remaining) =
    go firstValue [firstValue] remaining
   where
    go _ retained [] = Right retained
    go previous retained (value : rest) = do
      matches <- equivalentBy test previous value
      if matches
        then go previous retained rest
        else go value (retained <> [value]) rest

reduceDeleteDuplicates :: [Expr] -> Either EvaluationError Expr
reduceDeleteDuplicates arguments' = case arguments' of
  [subject] -> delete subject Nothing
  [subject, test] -> delete subject (Just test)
  _ ->
    Left
      ( EvaluationError
          "DeleteDuplicates expects a compound expression and an optional test."
      )
 where
  delete subject test = do
    items <- orderedItems "DeleteDuplicates" subject
    retained <- foldM (retainUniqueItem test) [] items
    pure (rebuildOrdered subject retained)

retainUniqueItem
  :: Maybe Expr
  -> [OrderedItem]
  -> OrderedItem
  -> Either EvaluationError [OrderedItem]
retainUniqueItem test retained item@(OrderedItem _ value _ _) = do
  duplicate <-
    anyEquivalent
      test
      value
      [prior | OrderedItem _ prior _ _ <- retained]
  pure (if duplicate then retained else retained <> [item])

reduceDeleteDuplicatesBy :: [Expr] -> Either EvaluationError Expr
reduceDeleteDuplicatesBy arguments' = case arguments' of
  [subject, function] -> delete subject function Nothing
  [subject, function, test] -> delete subject function (Just test)
  _ ->
    Left
      ( EvaluationError
          "DeleteDuplicatesBy expects a compound expression, a function, and an optional test."
      )
 where
  delete subject function test = do
    items <- orderedItems "DeleteDuplicatesBy" subject
    (_, retained) <- foldM (retainByKey function test) ([], []) items
    pure (rebuildOrdered subject retained)
  retainByKey function test (keys, retained) item@(OrderedItem _ value _ _) = do
    key <- evaluate (Call function [value])
    duplicate <- anyPriorKey test keys key
    pure
      ( if duplicate
          then (keys, retained)
          else (keys <> [key], retained <> [item])
      )
  anyPriorKey _ [] _ = Right False
  anyPriorKey test (prior : remaining) key = do
    matches <- equivalentBy test prior key
    if matches then Right True else anyPriorKey test remaining key

reduceDuplicateFreeQ :: [Expr] -> Either EvaluationError Expr
reduceDuplicateFreeQ arguments' = case arguments' of
  [subject] -> check subject Nothing
  [subject, test] -> check subject (Just test)
  _ ->
    Left
      ( EvaluationError
          "DuplicateFreeQ expects a compound expression and an optional test."
      )
 where
  check subject test = do
    values <- sequenceCollectionValues "DuplicateFreeQ" subject
    boolean <$> allDistinctBy test values
  allDistinctBy _ [] = Right True
  allDistinctBy test (value : remaining) = do
    duplicate <- anyEquivalent test value remaining
    if duplicate then Right False else allDistinctBy test remaining

reduceCountsBy :: [Expr] -> Either EvaluationError Expr
reduceCountsBy [subject, function] = do
  values <- listOrAssociationValues "CountsBy" subject
  groups <- groupValuesBy function values
  pure
    ( associationExpr
        [ AssociationEntry "Rule" key (Integer (fromIntegral (length groupedValues)))
        | ValueGroup key groupedValues <- groups
        ]
    )
reduceCountsBy _ = Left (EvaluationError "CountsBy expects a collection and a function.")

reduceSubsequences :: [Expr] -> Either EvaluationError Expr
reduceSubsequences arguments' = case arguments' of
  [subject] -> subsequences subject Nothing
  [subject, specification] -> subsequences subject (Just specification)
  _ ->
    Left
      ( EvaluationError
          "Subsequences expects a sequence and an optional length specification."
      )
 where
  subsequences subject specification = do
    values <- sequenceCollectionValues "Subsequences" subject
    (lowerBound, upperBound) <- subsequenceBounds (length values) specification
    let lower = max 0 lowerBound
        upper = min (length values) (max (-1) upperBound)
        output =
          [ evaluatedList (take width (drop start values))
          | width <- [lower .. upper]
          , start <- if width == 0 then [0] else [0 .. length values - width]
          ]
    if toInteger (length output) > maximumDenseArrayMaterializedNodes
      then
        Left
          ( EvaluationError
              "Subsequences output exceeds the native materialization limit."
          )
      else Right (evaluatedList output)
  subsequenceBounds count Nothing = Right (1, count)
  subsequenceBounds _ (Just (Integer upper)) = integerBounds 1 upper
  subsequenceBounds _ (Just (Call (Symbol "List") [Integer target])) =
    integerBounds target target
  subsequenceBounds _ (Just (Call (Symbol "List") [Integer lower, Integer upper])) =
    integerBounds lower upper
  subsequenceBounds _ (Just (Call (Symbol "List") _)) =
    Left
      ( EvaluationError
          "Subsequences currently supports n, {n}, or {min, max} length specs."
      )
  subsequenceBounds _ _ =
    Left
      ( EvaluationError
          "Subsequences expects an integer count or a length specification list."
      )
  integerBounds lower upper
    | lower < toInteger (minBound :: Int)
        || lower > toInteger (maxBound :: Int)
        || upper < toInteger (minBound :: Int)
        || upper > toInteger (maxBound :: Int) =
        Left (EvaluationError "Subsequences length specification is out of native range.")
    | otherwise = Right (fromInteger lower, fromInteger upper)

reduceSubsets :: [Expr] -> Either EvaluationError Expr
reduceSubsets = \case
  [dataExpression] -> subsetsWithSizes dataExpression Nothing
  [dataExpression, specification] -> subsetsWithSizes dataExpression (Just specification)
  values -> Right (Call (Symbol "Subsets") values)
 where
  subsetsWithSizes dataExpression specification = do
    values <- listOrAssociationValues "Subsets" dataExpression
    sizes <- collectionSizes "Subsets" (length values) [0 .. length values] specification
    pure (list [list subset | size <- sizes, subset <- combinationsOf size values])

reducePermutations :: [Expr] -> Either EvaluationError Expr
reducePermutations = \case
  [dataExpression] -> permutationsWithSizes dataExpression Nothing
  [dataExpression, specification] -> permutationsWithSizes dataExpression (Just specification)
  values -> Right (Call (Symbol "Permutations") values)
 where
  permutationsWithSizes dataExpression specification = do
    values <- listOrAssociationValues "Permutations" dataExpression
    sizes <- collectionSizes "Permutations" (length values) [length values] specification
    pure (list [list permutation | size <- sizes, permutation <- permutationsOf size values])

collectionSizes :: Text -> Int -> [Int] -> Maybe Expr -> Either EvaluationError [Int]
collectionSizes _ _ defaults Nothing = Right defaults
collectionSizes operation maximumSize _ (Just specification) = case specification of
  Call (Symbol "List") [Integer size]
    | size >= 0 -> Right (inBounds [fromIntegral size])
  Call (Symbol "List") [Integer lower, Integer upper]
    | lower >= 0 && upper >= lower -> Right (inBounds [fromIntegral lower .. fromIntegral upper])
  Integer upper
    | upper >= 0 -> Right [0 .. min maximumSize (fromIntegral upper)]
  _ -> Left (EvaluationError (operation <> " received an unsupported size specification"))
 where
  inBounds = filter (<= maximumSize)

combinationsOf :: Int -> [value] -> [[value]]
combinationsOf 0 _ = [[]]
combinationsOf _ [] = []
combinationsOf count (value : rest)
  | count < 0 = []
  | otherwise =
      map (value :) (combinationsOf (count - 1) rest) <> combinationsOf count rest

permutationsOf :: Int -> [value] -> [[value]]
permutationsOf 0 _ = [[]]
permutationsOf count values
  | count < 0 = []
  | otherwise =
      [ value : permutation
      | (value, remaining) <- selectEach values
      , permutation <- permutationsOf (count - 1) remaining
      ]
 where
  selectEach [] = []
  selectEach (value : rest) =
    (value, rest) : [(selected, value : remaining) | (selected, remaining) <- selectEach rest]

reducePermute :: [Expr] -> Either EvaluationError Expr
reducePermute [Call expressionHead subjectValues, permutationExpression]
  | expressionHead /= Symbol "Association" = do
      permutation <- parsePermutation (length subjectValues) permutationExpression
      reordered <-
        maybe
          (Left (EvaluationError "Permute received an invalid permutation"))
          Right
          (traverse (valueAtDestination subjectValues permutation) [1 .. length subjectValues])
      pure (Call expressionHead reordered)
 where
  valueAtDestination values' permutation destination = do
    sourceIndex <- findSourceIndex destination permutation
    pure (values' !! sourceIndex)
  findSourceIndex destination = go 0
   where
    go _ [] = Nothing
    go index (candidate : rest)
      | destination == candidate = Just index
      | otherwise = go (index + 1) rest
reducePermute values = Right (Call (Symbol "Permute") values)

parsePermutation :: Int -> Expr -> Either EvaluationError [Int]
parsePermutation count = \case
  Call (Symbol "List") values -> validate =<< traverse explicitPosition values
  Call (Symbol "Cycles") [Call (Symbol "List") cycles] -> do
    parsedCycles <- traverse parseCycle cycles
    validate (foldl' applyCycle [1 .. count] parsedCycles)
  _ -> Left (EvaluationError "Permute expects a positional list or Cycles expression")
 where
  explicitPosition (Integer position)
    | position > 0 && position <= fromIntegral count = Right (fromIntegral position)
  explicitPosition _ = Left (EvaluationError "Permute positions must be in range")
  parseCycle (Call (Symbol "List") positions) = traverse explicitPosition positions
  parseCycle _ = Left (EvaluationError "Permute cycles must contain position lists")
  validate permutation
    | length permutation == count
    , allDistinct permutation
    , all (`elem` permutation) [1 .. count] = Right permutation
    | otherwise = Left (EvaluationError "Permute expects a complete permutation")
  applyCycle permutation [] = permutation
  applyCycle permutation [_] = permutation
  applyCycle permutation (firstPosition : remaining) =
    foldl'
      (\result (source, destination) -> replaceListIndex (source - 1) destination result)
      permutation
      (zip (firstPosition : remaining) (remaining <> [firstPosition]))

reducePermutationList :: [Expr] -> Either EvaluationError Expr
reducePermutationList arguments' = case arguments' of
  [cyclesExpression] -> build cyclesExpression Nothing
  [cyclesExpression, lengthExpression] -> build cyclesExpression (Just lengthExpression)
  _ ->
    Left
      ( EvaluationError
          "PermutationList expects a Cycles expression and an optional length."
      )
 where
  build cyclesExpression requestedLength = do
    cycles <- parsePermutationCycles "PermutationList" cyclesExpression
    let inferredLength = maximum (0 : concat cycles)
    targetLength <- case requestedLength of
      Nothing -> Right inferredLength
      Just (Integer value)
        | value >= 0
        , value <= toInteger (maxBound :: Int) -> Right (fromInteger value)
      _ ->
        Left
          ( EvaluationError
              "PermutationList expects a non-negative integer length."
          )
    if inferredLength > targetLength
      then
        Left
          ( EvaluationError
              "PermutationList length is shorter than the largest cycle entry."
          )
      else do
        requirePermutationMaterialization "PermutationList" targetLength
        pure
          ( evaluatedList
              (map (Integer . fromIntegral) (cyclesToPermutation targetLength cycles))
          )

reducePermutationCycles :: [Expr] -> Either EvaluationError Expr
reducePermutationCycles [Call (Symbol "List") values] = do
  let count = length values
  permutation <- traverse (permutationPosition count) values
  if not (allDistinct permutation)
    then invalid
    else
      pure
        ( Call
            (Symbol "Cycles")
            [evaluatedList (map (evaluatedList . map (Integer . fromIntegral)) (permutationToCycles permutation))]
        )
 where
  permutationPosition count (Integer value)
    | value >= 1
    , value <= fromIntegral count = Right (fromInteger value)
  permutationPosition _ _ = invalid
  invalid =
    Left
      ( EvaluationError
          "PermutationCycles expects a permutation of {1, …, n}."
      )
reducePermutationCycles [_] =
  Left (EvaluationError "PermutationCycles expects a List of positive integers.")
reducePermutationCycles _ =
  Left (EvaluationError "PermutationCycles expects exactly one argument.")

reducePermutationOrder :: [Expr] -> Either EvaluationError Expr
reducePermutationOrder [cyclesExpression] = do
  cycles <- parsePermutationCycles "PermutationOrder" cyclesExpression
  pure
    ( Integer
        ( foldl'
            lcm
            1
            [toInteger (length cycleValues) | cycleValues <- cycles, length cycleValues > 1]
        )
    )
reducePermutationOrder _ =
  Left (EvaluationError "PermutationOrder expects exactly one Cycles expression.")

parsePermutationCycles :: Text -> Expr -> Either EvaluationError [[Int]]
parsePermutationCycles operation expression = case expression of
  Call (Symbol cyclesHead) [Call (Symbol "List") cycleExpressions]
    | systemHeadIn ["Cycles"] cyclesHead -> do
        cycles <- traverse parseCycle cycleExpressions
        let positions = concat cycles
        if allDistinct positions
          then Right cycles
          else
            Left
              ( EvaluationError
                  (operation <> ": cycle entries must be disjoint.")
              )
  Call (Symbol cyclesHead) _
    | systemHeadIn ["Cycles"] cyclesHead ->
        Left
          ( EvaluationError
              ( operation
                  <> " expects Cycles with exactly one cycle-list argument."
              )
          )
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects a Cycles expression.")
      )
 where
  parseCycle (Call (Symbol "List") values) = traverse parsePosition values
  parseCycle _ =
    Left
      ( EvaluationError
          (operation <> ": every cycle must be a List of positive integers.")
      )
  parsePosition (Integer value)
    | value > 0
    , value <= toInteger (maxBound :: Int) = Right (fromInteger value)
  parsePosition _ =
    Left
      ( EvaluationError
          (operation <> ": cycle entries must be positive integers.")
      )

cyclesToPermutation :: Int -> [[Int]] -> [Int]
cyclesToPermutation count = foldl' applyCycle [1 .. count]
 where
  applyCycle permutation [] = permutation
  applyCycle permutation [_] = permutation
  applyCycle permutation cycleValues@(firstPosition : remaining) =
    foldl'
      (\result (source, destination) -> replaceListIndex (source - 1) destination result)
      permutation
      (zip cycleValues (remaining <> [firstPosition]))

permutationToCycles :: [Int] -> [[Int]]
permutationToCycles permutation = reverse (go 1 Set.empty [])
 where
  count = length permutation
  go start visited retained
    | start > count = retained
    | Set.member start visited = go (start + 1) visited retained
    | otherwise =
        let (cycleValues, updated) = follow start visited []
            nextRetained = if length cycleValues > 1 then cycleValues : retained else retained
         in go (start + 1) updated nextRetained
  follow current visited retained
    | Set.member current visited = (retained, visited)
    | otherwise = case listElementAt (current - 1) permutation of
        Just nextPosition ->
          follow
            nextPosition
            (Set.insert current visited)
            (retained <> [current])
        Nothing -> (retained, visited)

requirePermutationMaterialization :: Text -> Int -> Either EvaluationError ()
requirePermutationMaterialization operation count
  | toInteger count <= maximumDenseArrayMaterializedNodes = Right ()
  | otherwise =
      Left
        ( EvaluationError
            (operation <> " output exceeds the native materialization limit.")
        )

listElementAt :: Int -> [value] -> Maybe value
listElementAt index _ | index < 0 = Nothing
listElementAt _ [] = Nothing
listElementAt 0 (value : _) = Just value
listElementAt index (_ : rest) = listElementAt (index - 1) rest

reducePad :: Bool -> [Expr] -> Either EvaluationError Expr
reducePad leftMode = \case
  [Call (Symbol "List") values, Integer target] -> pad values target (Integer 0)
  [Call (Symbol "List") values, Integer target, fill] -> pad values target fill
  values -> Right (Call (Symbol (if leftMode then "PadLeft" else "PadRight")) values)
 where
  pad values target fill
    | target < 0 = Left (EvaluationError "PadLeft/PadRight expects a non-negative target length")
    | targetLength <= length values =
        Right
          ( list
              ( if leftMode
                  then drop (length values - targetLength) values
                  else take targetLength values
              )
          )
    | leftMode = Right (list (replicate (targetLength - length values) fill <> values))
    | otherwise = Right (list (values <> replicate (targetLength - length values) fill))
   where
    targetLength = fromIntegral target

reduceMinMax :: Bool -> Text -> [Expr] -> Expr
reduceMinMax minimumMode headName originalValues =
  let values =
        sortBy minMaxCanonicalCompare
          (concatMap (flattenMinMaxArgument headName) originalValues)
      identity = if minimumMode then Symbol "Infinity" else Symbol "-Infinity"
      absorbing = if minimumMode then Symbol "-Infinity" else Symbol "Infinity"
   in if absorbing `elem` values
        then absorbing
        else
          let candidates = filter (/= identity) values
              numeric = [(value, exactValue) | value <- candidates, Just exactValue <- [explicitRealExact value]]
              symbolic = [value | value <- candidates, explicitRealExact value == Nothing]
              best = foldl' chooseBetter Nothing numeric
              resultValues = uniqueSortedCanonical (maybe symbolic ((: symbolic) . fst) best)
           in case resultValues of
                [] -> identity
                [single] -> single
                _ -> Call (Symbol headName) resultValues
 where
  chooseBetter Nothing candidate = Just candidate
  chooseBetter current@(Just (_, bestValue)) candidate@(_, candidateValue)
    | (minimumMode && compareExact candidateValue bestValue == LT)
        || (not minimumMode && compareExact candidateValue bestValue == GT) = Just candidate
    | otherwise = current

flattenMinMaxArgument :: Text -> Expr -> [Expr]
flattenMinMaxArgument headName (Call (Symbol nestedHead) values)
  | nestedHead == "List" || nestedHead == headName =
      concatMap (flattenMinMaxArgument headName) values
flattenMinMaxArgument _ value = [value]

explicitRealExact :: Expr -> Maybe Exact
explicitRealExact value
  | Just exactValue <- toExact value = Just exactValue
explicitRealExact (Real source) = do
  RealInfo exactValue _ _ _ _ <- parseRealInfo source
  pure exactValue
explicitRealExact _ = Nothing

minMaxCanonicalCompare :: Expr -> Expr -> Ordering
minMaxCanonicalCompare left right
  | Just leftExact <- explicitRealExact left
  , Just rightExact <- explicitRealExact right =
      case compareExact leftExact rightExact of
        EQ -> compare (numericKindRank left, fullForm left) (numericKindRank right, fullForm right)
        ordering -> ordering
minMaxCanonicalCompare left right = canonicalCompare left right

uniqueSortedCanonical :: [Expr] -> [Expr]
uniqueSortedCanonical = deduplicate . sortBy canonicalCompare
 where
  deduplicate [] = []
  deduplicate (value : rest) = value : deduplicate (dropWhile (== value) rest)

reduceMean :: [Expr] -> Either EvaluationError Expr
reduceMean [dataExpression] = do
  values <- listOrAssociationValues "Mean" dataExpression
  case values of
    [] -> Left (EvaluationError "Mean of an empty collection is undefined")
    _ ->
      pure
        ( reduceTimes
            [reducePlus values, fromExact (normalizeExact 1 (fromIntegral (length values)))]
        )
reduceMean values = Right (Call (Symbol "Mean") values)

reduceMedian :: [Expr] -> Either EvaluationError Expr
reduceMedian [dataExpression] = do
  values <- listOrAssociationValues "Median" dataExpression
  exactValues <-
    maybe
      (Left (EvaluationError "Median currently expects explicit exact real numbers"))
      Right
      (traverse toExact values)
  case sortBy compareExactValue exactValues of
    [] -> Left (EvaluationError "Median of an empty collection is undefined")
    sorted ->
      let count = length sorted
       in if odd count
            then Right (fromExact (sorted !! (count `div` 2)))
            else
              Right
                ( fromExact
                    ( multiplyExact
                        (addExact (sorted !! (count `div` 2 - 1)) (sorted !! (count `div` 2)))
                        (Exact 1 2)
                    )
                )
 where
  compareExactValue (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
    compare (leftNumerator * rightDenominator) (rightNumerator * leftDenominator)
reduceMedian values = Right (Call (Symbol "Median") values)

reduceVariance :: [Expr] -> Either EvaluationError Expr
reduceVariance [subject] = do
  values <- listOrAssociationValues "Variance" subject
  if length values < 2
    then Left (EvaluationError "Variance requires at least two elements.")
    else do
      let count = fromIntegral (length values)
          mean = reduceTimes [reducePlus values, fromExact (normalizeExact 1 count)]
          deviation value =
            reducePlus [value, reduceTimes [Integer (-1), mean]]
          squared value = reducePower [deviation value, Integer 2]
      pure
        ( reduceTimes
            [ reducePlus (map squared values)
            , fromExact (normalizeExact 1 (count - 1))
            ]
        )
reduceVariance _ =
  Left (EvaluationError "Variance currently expects exactly one argument.")

reduceStandardDeviation :: [Expr] -> Either EvaluationError Expr
reduceStandardDeviation [subject] =
  reduceSqrt . pure <$> reduceVariance [subject]
reduceStandardDeviation _ =
  Left
    ( EvaluationError
        "StandardDeviation currently expects exactly one argument."
    )

reduceNorm :: [Expr] -> Either EvaluationError Expr
reduceNorm values = case values of
  [subject] -> norm subject Nothing
  [subject, pValue] -> norm subject (Just pValue)
  _ -> Left (EvaluationError "Norm expects a vector and an optional p value.")
 where
  norm subject requestedExponent = case subject of
    Call (Symbol "List") elements -> case requestedExponent of
      Nothing ->
        pure
          ( reduceSqrt
              [reducePlus (map (\value -> reducePower [absolute value, Integer 2]) elements)]
          )
      Just (Symbol "Infinity") ->
        pure
          ( if null elements
              then Integer 0
              else reduceMinMax False "Max" (map absolute elements)
          )
      Just pValue@(Integer power)
        | power > 0 ->
            pure
              ( reducePower
                  [ reducePlus (map (\value -> reducePower [absolute value, pValue]) elements)
                  , fromExact (normalizeExact 1 power)
                  ]
              )
      _ ->
        Left
          ( EvaluationError
              "Norm currently expects a positive integer p or Infinity."
          )
    Call {} ->
      Left
        ( EvaluationError
            "Norm currently expects a List of explicit numbers."
        )
    _ -> Left (EvaluationError "Norm expects a nonatomic expression.")
  absolute value = reduceAbs [value]

reduceMinMaxPair :: [Expr] -> Either EvaluationError Expr
reduceMinMaxPair [subject] = do
  values <- listOrAssociationValues "MinMax" subject
  pure $ case values of
    [] ->
      evaluatedList
        [ Symbol "Infinity"
        , Call (Symbol "Times") [Integer (-1), Symbol "Infinity"]
        ]
    _ ->
      evaluatedList
        [reduceMinMax True "Min" values, reduceMinMax False "Max" values]
reduceMinMaxPair _ =
  Left (EvaluationError "MinMax expects exactly one argument.")

reduceRankedExtremum :: Bool -> [Expr] -> Either EvaluationError Expr
reduceRankedExtremum descending values = case values of
  [subject, rankExpression] -> do
    items <- listOrAssociationValues operation subject
    rank <- case rankExpression of
      Integer value -> Right value
      _ ->
        Left
          ( EvaluationError
              (operation <> " expects an explicit integer rank.")
          )
    if null items
      then Left (EvaluationError (operation <> " requires a nonempty list."))
      else do
        decorated <-
          maybe
            ( Left
                ( EvaluationError
                    ( operation
                        <> " currently expects explicit real-valued numbers."
                    )
                )
            )
            Right
            ( traverse
                (\item -> case explicitRealExact item of
                    Just exactValue -> Just (item, exactValue)
                    Nothing -> Nothing
                )
                items
            )
        let ordered =
              (if descending then reverse else id)
                (sortBy (\(_, left) (_, right) -> compareExact left right) decorated)
            count = toInteger (length ordered)
        if rank == 0 || rank > count || rank < negate count
          then
            Left
              ( EvaluationError
                  ( operation
                      <> " rank "
                      <> T.pack (show rank)
                      <> " is out of range for a list of length "
                      <> T.pack (show count)
                      <> "."
                  )
              )
          else
            let index = if rank > 0 then rank - 1 else count + rank
             in pure (fst (ordered !! fromInteger index))
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects a list and an integer rank.")
      )
 where
  operation = if descending then "RankedMax" else "RankedMin"

reduceMode :: [Expr] -> Either EvaluationError Expr
reduceMode [subject] = do
  values <- listOrAssociationValues "Mode" subject
  pure $ case values of
    [] -> Call (Symbol "Mode") [subject]
    _ ->
      let counts = foldl' countValue [] values
          maximumCount = maximum (map snd counts)
          candidates = [value | (value, count) <- counts, count == maximumCount]
       in case sortBy canonicalCompare candidates of
            firstCandidate : _ -> firstCandidate
            [] -> Call (Symbol "Mode") [subject]
 where
  countValue retained value = case break ((== value) . fst) retained of
    (_, []) -> retained <> [(value, 1 :: Integer)]
    (before, (existing, count) : after) ->
      before <> ((existing, count + 1) : after)
reduceMode _ = Left (EvaluationError "Mode expects exactly one argument.")

reduceCountDistinct :: [Expr] -> Either EvaluationError Expr
reduceCountDistinct [subject] = do
  values <- listOrAssociationValues "CountDistinct" subject
  pure (Integer (toInteger (length (uniqueCanonical values))))
reduceCountDistinct _ =
  Left (EvaluationError "CountDistinct expects exactly one argument.")

reduceRatios :: [Expr] -> Either EvaluationError Expr
reduceRatios [subject] = do
  values <- listOrAssociationValues "Ratios" subject
  pure
    ( evaluatedList
        [ reduceTimes [right, reducePower [left, Integer (-1)]]
        | (left, right) <- zip values (drop 1 values)
        ]
    )
reduceRatios _ = Left (EvaluationError "Ratios expects exactly one argument.")

reduceSubdivide :: [Expr] -> Either EvaluationError Expr
reduceSubdivide values = case values of
  [Integer count]
    | count > 0 -> do
        boundedSubdivision count
        pure
          ( evaluatedList
              [fromExact (normalizeExact index count) | index <- [0 .. count]]
          )
    | otherwise -> positiveCountError
  [_] -> positiveCountError
  [extent, Integer count]
    | count > 0 -> do
        boundedSubdivision count
        pure
          ( evaluatedList
              [ reduceTimes
                  [extent, Integer index, fromExact (normalizeExact 1 count)]
              | index <- [0 .. count]
              ]
          )
    | otherwise -> positiveSubdivisionError
  [_, _] -> positiveSubdivisionError
  [lower, upper, Integer count]
    | count > 0 -> do
        boundedSubdivision count
        let step =
              reduceTimes
                [ reducePlus [upper, reduceTimes [Integer (-1), lower]]
                , fromExact (normalizeExact 1 count)
                ]
        pure
          ( evaluatedList
              [reducePlus [lower, reduceTimes [Integer index, step]] | index <- [0 .. count]]
          )
    | otherwise -> positiveSubdivisionError
  [_, _, _] -> positiveSubdivisionError
  _ -> Left (EvaluationError "Subdivide expects 1, 2, or 3 arguments.")
 where
  positiveCountError =
    Left (EvaluationError "Subdivide expects a positive integer count.")
  positiveSubdivisionError =
    Left
      ( EvaluationError
          "Subdivide expects a positive integer subdivision count."
      )
  boundedSubdivision count
    | count + 1 <= maximumDenseArrayMaterializedNodes = Right ()
    | otherwise =
        Left
          ( EvaluationError
              "Subdivide output exceeds the native materialization limit."
          )

reduceQuantile :: [Expr] -> Either EvaluationError Expr
reduceQuantile arguments' = case arguments' of
  [subject, probability] -> quantiles subject probability defaultParameters
  [subject, probability, parametersExpression] -> do
    parameters <- parseQuantileParameters parametersExpression
    quantiles subject probability parameters
  _ ->
    Left
      ( EvaluationError
          "Quantile expects a collection, probabilities, and optional parameters."
      )
 where
  defaultParameters = (Integer 0, Integer 0, Integer 1, Integer 0)
  quantiles subject probability parameters = do
    items <- listOrAssociationValues "Quantile" subject
    sorted <- sortedExplicitRealItems "Quantile" items
    case sorted of
      [] -> Left (EvaluationError "Quantile of an empty list is undefined.")
      _ -> case probability of
        Call (Symbol "List") probabilities ->
          evaluatedList <$> traverse (quantileOne sorted parameters) probabilities
        value -> quantileOne sorted parameters value

reduceQuartiles :: [Expr] -> Either EvaluationError Expr
reduceQuartiles [subject] = do
  items <- listOrAssociationValues "Quartiles" subject
  sorted <- sortedExplicitRealItems "Quartiles" items
  case sorted of
    [] -> Left (EvaluationError "Quartiles of an empty list is undefined.")
    _ ->
      let parameters = (Rational 1 2, Integer 0, Integer 0, Integer 1)
       in evaluatedList
            <$> traverse
              (quantileOne sorted parameters)
              [Rational 1 4, Rational 1 2, Rational 3 4]
reduceQuartiles _ = Left (EvaluationError "Quartiles expects exactly one collection.")

parseQuantileParameters :: Expr -> Either EvaluationError (Expr, Expr, Expr, Expr)
parseQuantileParameters = \case
  Call
    (Symbol "List")
    [ Call (Symbol "List") [a, b]
      , Call (Symbol "List") [c, d]
      ] -> Right (a, b, c, d)
  _ ->
    Left
      ( EvaluationError
          "Quantile parameters must be a list ``{{a, b}, {c, d}}``."
      )

sortedExplicitRealItems :: Text -> [Expr] -> Either EvaluationError [Expr]
sortedExplicitRealItems operation values = do
  decorated <-
    maybe
      ( Left
          ( EvaluationError
              (operation <> " currently expects explicit real-valued numbers.")
          )
      )
      Right
      ( traverse
          (\value -> (\exactValue -> (value, exactValue)) <$> explicitRealExact value)
          values
      )
  pure (map fst (sortBy (\(_, left) (_, right) -> compareExact left right) decorated))

quantileOne :: [Expr] -> (Expr, Expr, Expr, Expr) -> Expr -> Either EvaluationError Expr
quantileOne [] _ _ =
  Left (EvaluationError "Quantile of an empty list is undefined.")
quantileOne sortedItems@(firstItem : remainingItems) (a, b, c, d) probability = do
  let count = length sortedItems
      finalItem = foldl' (\_ value -> value) firstItem remainingItems
      position =
        reducePlus
          [ a
          , reduceTimes [reducePlus [Integer (fromIntegral count), b], probability]
          ]
      integerPosition = reduceRounding RoundFloor "Floor" [position]
      fraction =
        reducePlus [position, reduceTimes [Integer (-1), integerPosition]]
  index <- case integerPosition of
    Integer value -> Right value
    _ -> positionError
  fractionExact <- maybe positionError Right (explicitRealExact fraction)
  if index < 1
    then Right firstItem
    else
      if index >= fromIntegral count
        then Right finalItem
        else
          case
              ( listElementAt (fromInteger index - 1) sortedItems
              , listElementAt (fromInteger index) sortedItems
              )
            of
              (Just base, Just nextValue)
                | compareExact fractionExact (Exact 0 1) == EQ -> Right base
                | otherwise ->
                    let weight = reducePlus [c, reduceTimes [d, fraction]]
                     in Right
                          ( reducePlus
                              [ base
                              , reduceTimes
                                  [ weight
                                  , reducePlus
                                      [nextValue, reduceTimes [Integer (-1), base]]
                                  ]
                              ]
                          )
              _ -> positionError
 where
  positionError =
    Left
      ( EvaluationError
          "Quantile could not reduce its position calculation to an explicit number."
      )

data BinBounds = BinBounds !Exact !Exact !Exact

reduceBins :: Bool -> [Expr] -> Either EvaluationError Expr
reduceBins listMode arguments' = case arguments' of
  [subject] -> bin subject (Integer 1)
  [subject, specification] -> bin subject specification
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects a collection and an optional bin specification.")
      )
 where
  operation = if listMode then "BinLists" else "BinCounts"
  bin subject specification = do
    items <- listOrAssociationValues operation subject
    bounds <- binBounds operation items specification
    count <- binCount operation bounds
    let emptyBins = replicate count []
    bins <- foldM (insertBin operation bounds count) emptyBins items
    pure
      ( if listMode
          then evaluatedList (map evaluatedList bins)
          else evaluatedList (map (Integer . fromIntegral . length) bins)
      )

binBounds :: Text -> [Expr] -> Expr -> Either EvaluationError BinBounds
binBounds operation items specification = case specification of
  Call (Symbol "List") [minimumExpression, maximumExpression, widthExpression] -> do
    minimumValue <- explicitBound "xmin" minimumExpression
    maximumValue <- explicitBound "xmax" maximumExpression
    width <- explicitBound "dx" widthExpression
    requirePositiveWidth width
    Right (BinBounds minimumValue maximumValue width)
  Call (Symbol "List") _ -> specificationError
  _ -> do
    width <- maybe specificationError Right (explicitRealExact specification)
    requirePositiveWidth width
    exactItems <-
      maybe
        ( Left
            ( EvaluationError
                (operation <> " currently expects explicit real-valued numbers.")
            )
        )
        Right
        (traverse explicitRealExact items)
    case exactItems of
      [] ->
        Left
          ( EvaluationError
              (operation <> " cannot infer auto bin bounds from an empty list.")
          )
      firstValue : rest -> do
        let minimumValue = foldl' exactMinimum firstValue rest
            maximumValue = foldl' exactMaximum firstValue rest
        minimumQuotient <- maybe specificationError Right (divideExact minimumValue width)
        maximumQuotient <- maybe specificationError Right (divideExact maximumValue width)
        let lower = multiplyExact (Exact (roundExact RoundFloor minimumQuotient) 1) width
            upper =
              multiplyExact
                (Exact (roundExact RoundFloor maximumQuotient + 1) 1)
                width
        Right (BinBounds lower upper width)
 where
  explicitBound role expression =
    maybe
      ( Left
          ( EvaluationError
              (operation <> " " <> role <> " must be an explicit real-valued number.")
          )
      )
      Right
      (explicitRealExact expression)
  requirePositiveWidth width
    | compareExact width (Exact 0 1) == GT = Right ()
    | otherwise =
        Left
          ( EvaluationError
              (operation <> " requires xmax > xmin and a positive bin width.")
          )
  specificationError =
    Left
      ( EvaluationError
          (operation <> " expects a bin spec ``dx`` or ``{xmin, xmax, dx}``.")
      )
  exactMinimum left right = if compareExact left right == GT then right else left
  exactMaximum left right = if compareExact left right == LT then right else left

binCount :: Text -> BinBounds -> Either EvaluationError Int
binCount operation (BinBounds minimumValue maximumValue width) = do
  quotient <-
    maybe
      invalid
      Right
      (divideExact (addExact maximumValue (negateExact minimumValue)) width)
  let count = roundExact RoundFloor quotient
  if count <= 0
    then invalid
    else
      if count > maximumDenseArrayMaterializedNodes
        then
          Left
            ( EvaluationError
                (operation <> " output exceeds the native materialization limit.")
            )
        else Right (fromInteger count)
 where
  invalid =
    Left
      ( EvaluationError
          (operation <> " requires xmax > xmin and a positive bin width.")
      )

insertBin
  :: Text
  -> BinBounds
  -> Int
  -> [[Expr]]
  -> Expr
  -> Either EvaluationError [[Expr]]
insertBin operation (BinBounds minimumValue _ width) count bins value = do
  exactValue <-
    maybe
      ( Left
          ( EvaluationError
              (operation <> " currently expects explicit real-valued numbers.")
          )
      )
      Right
      (explicitRealExact value)
  let difference = addExact exactValue (negateExact minimumValue)
  if compareExact difference (Exact 0 1) == LT
    then Right bins
    else do
      quotient <-
        maybe
          ( Left
              ( EvaluationError
                  (operation <> " requires a positive bin width.")
              )
          )
          Right
          (divideExact difference width)
      let index = roundExact RoundFloor quotient
      if index < 0 || index >= fromIntegral count
        then Right bins
        else
          let offset = fromInteger index
           in case listElementAt offset bins of
                Just binValues ->
                  Right (replaceListIndex offset (binValues <> [value]) bins)
                Nothing -> Right bins

data OrderedItem = OrderedItem !Int !Expr !(Maybe AssociationEntry) ![Expr]
  deriving (Eq, Show)

canonicalCompare :: Expr -> Expr -> Ordering
canonicalCompare left right
  | left == right = EQ
  | Just leftExact <- toExact left
  , Just rightExact <- toExact right =
      case compareExact leftExact rightExact of
        EQ -> compare (numericKindRank left, fullForm left) (numericKindRank right, fullForm right)
        ordering -> ordering
  | expressionKindRank left /= expressionKindRank right =
      compare (expressionKindRank left) (expressionKindRank right)
canonicalCompare (String left) (String right) = compare left right
canonicalCompare (Symbol left) (Symbol right) = compare left right
canonicalCompare (ByteArray left) (ByteArray right) = compare left right
canonicalCompare (Call leftHead leftValues) (Call rightHead rightValues) =
  case canonicalCompare leftHead rightHead of
    EQ -> compareExpressionLists leftValues rightValues
    ordering -> ordering
canonicalCompare left right = compare (fullForm left) (fullForm right)

compareExact :: Exact -> Exact -> Ordering
compareExact (Exact leftNumerator leftDenominator) (Exact rightNumerator rightDenominator) =
  compare (leftNumerator * rightDenominator) (rightNumerator * leftDenominator)

numericKindRank :: Expr -> Int
numericKindRank Integer {} = 0
numericKindRank Rational {} = 1
numericKindRank Real {} = 2
numericKindRank Complex {} = 3
numericKindRank Root {} = 4
numericKindRank _ = 5

expressionKindRank :: Expr -> Int
expressionKindRank expression = case expression of
  Integer {} -> 0
  Rational {} -> 0
  Real {} -> 0
  Complex {} -> 0
  Root {} -> 0
  String {} -> 1
  Symbol {} -> 2
  ByteArray {} -> 3
  SparseArray {} -> 4
  Call {} -> 5

compareExpressionLists :: [Expr] -> [Expr] -> Ordering
compareExpressionLists [] [] = EQ
compareExpressionLists [] (_ : _) = LT
compareExpressionLists (_ : _) [] = GT
compareExpressionLists (left : leftRest) (right : rightRest) =
  case canonicalCompare left right of
    EQ -> compareExpressionLists leftRest rightRest
    ordering -> ordering

orderedItems :: Text -> Expr -> Either EvaluationError [OrderedItem]
orderedItems _ association
  | Just entries <- associationEntries association =
      Right
        [ OrderedItem index value (Just entry) []
        | (index, entry@(AssociationEntry _ _ value)) <- zip [1 ..] entries
        ]
orderedItems _ (Call _ values) =
  Right [OrderedItem index value Nothing [] | (index, value) <- zip [1 ..] values]
orderedItems operation _ = Left (EvaluationError (operation <> " expects a compound expression"))

rebuildOrdered :: Expr -> [OrderedItem] -> Expr
rebuildOrdered association items
  | Just _ <- associationEntries association =
      associationExpr [entry | OrderedItem _ _ (Just entry) _ <- items]
rebuildOrdered (Call expressionHead _) items =
  Call expressionHead [value | OrderedItem _ value _ _ <- items]
rebuildOrdered expression _ = expression

orderingFunctionCompare :: Maybe Expr -> Expr -> Expr -> Ordering
orderingFunctionCompare Nothing = canonicalCompare
orderingFunctionCompare (Just function) = compareWithFunction
 where
  compareWithFunction left right = case evaluate (Call function [left, right]) of
    Right (Symbol "True") -> LT
    Right (Integer result) -> compare 0 result
    Right (Symbol "False") -> case evaluate (Call function [right, left]) of
      Right (Symbol "True") -> GT
      Right (Integer result) -> compare result 0
      _ -> EQ
    _ -> canonicalCompare left right

reduceOrder :: [Expr] -> Expr
reduceOrder [left, right] = Integer $ case canonicalCompare left right of
  LT -> 1
  EQ -> 0
  GT -> -1
reduceOrder values = Call (Symbol "Order") values

reduceOrderedQ :: [Expr] -> Either EvaluationError Expr
reduceOrderedQ = \case
  [subject] -> check subject Nothing
  [subject, function] -> check subject (Just function)
  values -> Right (Call (Symbol "OrderedQ") values)
 where
  check subject function = do
    items <- orderedItems "OrderedQ" subject
    let values = [value | OrderedItem _ value _ _ <- items]
        comparisons = zipWith (orderingFunctionCompare function) values (drop 1 values)
    pure (boolean (all (/= GT) comparisons))

reduceOrderingIndices :: [Expr] -> Either EvaluationError Expr
reduceOrderingIndices = \case
  [subject] -> order subject Nothing Nothing
  [subject, count] -> order subject (Just count) Nothing
  [subject, count, function] -> order subject (Just count) (Just function)
  values -> Right (Call (Symbol "Ordering") values)
 where
  order subject count function = do
    items <- orderedItems "Ordering" subject
    let sorted = sortBy (compareOrderedItems function) items
    selected <- countSlice "Ordering" count sorted
    pure (list [Integer (fromIntegral index) | OrderedItem index _ _ _ <- selected])

compareOrderedItems :: Maybe Expr -> OrderedItem -> OrderedItem -> Ordering
compareOrderedItems function (OrderedItem _ left _ _) (OrderedItem _ right _ _) =
  orderingFunctionCompare function left right

countSlice :: Text -> Maybe Expr -> [value] -> Either EvaluationError [value]
countSlice _ Nothing values = Right values
countSlice _ (Just (Symbol "All")) values = Right values
countSlice _ (Just (Integer count)) values
  | count >= 0 = Right (take (min (length values) (fromIntegral count)) values)
  | otherwise = Right (drop (max 0 (length values - fromIntegral (abs count))) values)
countSlice operation _ _ = Left (EvaluationError (operation <> " expects an integer or All count"))

reduceSort :: Bool -> [Expr] -> Either EvaluationError Expr
reduceSort reverseMode = \case
  [subject] -> sortSubject subject Nothing Nothing
  [subject, function] -> sortSubject subject (Just function) Nothing
  [subject, function, count] -> sortSubject subject (Just function) (Just count)
  values -> Right (Call (Symbol (if reverseMode then "ReverseSort" else "Sort")) values)
 where
  sortSubject subject function count = do
    items <- orderedItems operation subject
    let compareItems left right =
          let result = compareOrderedItems function left right
           in if reverseMode then invertOrdering result else result
        sorted = sortBy compareItems items
    selected <- countSlice operation count sorted
    pure (rebuildOrdered subject selected)
  operation = if reverseMode then "ReverseSort" else "Sort"

data NaturalSortPart
  = NaturalText !Text
  | NaturalNumber !Integer
  deriving (Eq, Show)

instance Ord NaturalSortPart where
  compare (NaturalText left) (NaturalText right) = compare left right
  compare NaturalText {} NaturalNumber {} = LT
  compare NaturalNumber {} NaturalText {} = GT
  compare (NaturalNumber left) (NaturalNumber right) = compare left right

reduceTextSort :: Bool -> [Expr] -> Either EvaluationError Expr
reduceTextSort numerical [subject] = do
  items <- orderedItems operation subject
  let key (OrderedItem _ value _ _) =
        let source = case value of
              String textValue -> textValue
              _ -> inputForm value
         in if numerical
              then Left (naturalSortParts (T.toCaseFold source))
              else Right (T.toCaseFold source)
      compareItems left right = compare (key left) (key right)
  pure (rebuildOrdered subject (sortBy compareItems items))
 where
  operation = if numerical then "NumericalSort" else "AlphabeticSort"
reduceTextSort numerical _ =
  Left
    ( EvaluationError
        ( (if numerical then "NumericalSort" else "AlphabeticSort")
            <> " expects exactly one compound expression."
        )
    )

naturalSortParts :: Text -> [NaturalSortPart]
naturalSortParts source = case T.uncons source of
  Nothing -> []
  Just (firstCharacter, _)
    | isDigit firstCharacter ->
        let (digits, remaining) = T.span isDigit source
            part = case readMaybe (T.unpack digits) of
              Just value -> NaturalNumber value
              Nothing -> NaturalText digits
         in part : naturalSortParts remaining
    | otherwise ->
        let (textPart, remaining) = T.span (not . isDigit) source
         in NaturalText textPart : naturalSortParts remaining

reduceLexicographicOrder :: [Expr] -> Either EvaluationError Expr
reduceLexicographicOrder arguments' = case arguments' of
  [left, right] -> Right (orderResult (lexicographicCompare Nothing left right))
  [left, right, function] ->
    Right (orderResult (lexicographicCompare (Just function) left right))
  _ ->
    Left
      ( EvaluationError
          "LexicographicOrder expects two expressions and an optional ordering function."
      )
 where
  orderResult ordering = Integer $ case ordering of
    LT -> 1
    EQ -> 0
    GT -> -1

reduceLexicographicSort :: [Expr] -> Either EvaluationError Expr
reduceLexicographicSort arguments' = case arguments' of
  [subject] -> sortSubject subject Nothing
  [subject, function] -> sortSubject subject (Just function)
  _ ->
    Left
      ( EvaluationError
          "LexicographicSort expects a compound expression and an optional ordering function."
      )
 where
  sortSubject subject function = do
    items <- orderedItems "LexicographicSort" subject
    let compareItems (OrderedItem _ left _ _) (OrderedItem _ right _ _) =
          lexicographicCompare function left right
    pure (rebuildOrdered subject (sortBy compareItems items))

lexicographicCompare :: Maybe Expr -> Expr -> Expr -> Ordering
lexicographicCompare function left right =
  case (lexicographicElements left, lexicographicElements right) of
    (Just leftValues, Just rightValues) -> compareValues leftValues rightValues
    _ -> orderingFunctionCompare function left right
 where
  compareValues [] [] = EQ
  compareValues [] (_ : _) = LT
  compareValues (_ : _) [] = GT
  compareValues (leftValue : leftRest) (rightValue : rightRest) =
    case orderingFunctionCompare function leftValue rightValue of
      EQ -> compareValues leftRest rightRest
      ordering -> ordering

lexicographicElements :: Expr -> Maybe [Expr]
lexicographicElements (String value) =
  Just (map (String . T.singleton) (T.unpack value))
lexicographicElements (Call _ values) = Just values
lexicographicElements _ = Nothing

invertOrdering :: Ordering -> Ordering
invertOrdering LT = GT
invertOrdering EQ = EQ
invertOrdering GT = LT

reduceSortBy :: Bool -> [Expr] -> Either EvaluationError Expr
reduceSortBy reverseMode = \case
  [subject, functions] -> sortSubject subject functions Nothing
  [subject, functions, orderingFunction] -> sortSubject subject functions (Just orderingFunction)
  values -> Right (Call (Symbol operation) values)
 where
  sortSubject subject functions orderingFunction = do
    items <- orderedItems operation subject
    let (keyFunctions, stableTies) = case functions of
          Call (Symbol "List") values -> (values, True)
          _ -> ([functions], False)
    decorated <- traverse (decorate keyFunctions) items
    let compareItems (OrderedItem _ leftValue _ leftKeys) (OrderedItem _ rightValue _ rightKeys) =
          let keyOrdering = compareKeyLists orderingFunction leftKeys rightKeys
              tieOrdering = if stableTies then EQ else canonicalCompare leftValue rightValue
              result = if keyOrdering == EQ then tieOrdering else keyOrdering
           in if reverseMode then invertOrdering result else result
    pure (rebuildOrdered subject (sortBy compareItems decorated))
  decorate functions (OrderedItem index value entry _) = do
    keys <- traverse (\function -> evaluate (Call function [value])) functions
    pure (OrderedItem index value entry keys)
  operation = if reverseMode then "ReverseSortBy" else "SortBy"

compareKeyLists :: Maybe Expr -> [Expr] -> [Expr] -> Ordering
compareKeyLists _ [] [] = EQ
compareKeyLists _ [] (_ : _) = LT
compareKeyLists _ (_ : _) [] = GT
compareKeyLists function (left : leftRest) (right : rightRest) =
  case orderingFunctionCompare function left right of
    EQ -> compareKeyLists function leftRest rightRest
    ordering -> ordering

data SetOperation = SetUnion | SetIntersection | SetComplement

reduceSetOperation :: SetOperation -> [Expr] -> Either EvaluationError Expr
reduceSetOperation operation expressions = do
  collections <- traverse (listOrAssociationValues operationName) expressions
  pure (list (uniqueCanonical (sortBy canonicalCompare (resultValues collections))))
 where
  operationName = case operation of
    SetUnion -> "Union"
    SetIntersection -> "Intersection"
    SetComplement -> "Complement"
  resultValues collections = case operation of
    SetUnion -> concat collections
    SetIntersection -> case collections of
      [] -> []
      firstCollection : remaining ->
        [value | value <- firstCollection, all (value `elem`) remaining]
    SetComplement -> case collections of
      [] -> []
      firstCollection : remaining ->
        let excluded = concat remaining
         in [value | value <- firstCollection, value `notElem` excluded]

uniqueCanonical :: [Expr] -> [Expr]
uniqueCanonical = foldl' appendUnique []
 where
  appendUnique retained value
    | value `elem` retained = retained
    | otherwise = retained <> [value]

data IntervalSegment = IntervalSegment !Expr !Expr
  deriving (Eq, Show)

reduceInterval :: [Expr] -> Expr
reduceInterval values =
  maybe
    (Call (Symbol "Interval") values)
    intervalExpression
    (intervalSegmentsFromArguments values)

reduceIntervalUnion :: [Expr] -> Expr
reduceIntervalUnion values =
  case traverse intervalSegmentsFromInterval values of
    Just segmentGroups ->
      maybe
        (Call (Symbol "IntervalUnion") values)
        intervalExpression
        (normalizeIntervalSegments (concat segmentGroups))
    Nothing -> Call (Symbol "IntervalUnion") values

reduceIntervalIntersection :: [Expr] -> Expr
reduceIntervalIntersection [] = intervalExpression []
reduceIntervalIntersection values =
  case traverse intervalSegmentsFromInterval values of
    Nothing -> Call (Symbol "IntervalIntersection") values
    Just [] -> intervalExpression []
    Just (initial : remaining) ->
      maybe
        (Call (Symbol "IntervalIntersection") values)
        intervalExpression
        (foldM intersectIntervalSets initial remaining)

reduceIntervalMemberQ :: [Expr] -> Expr
reduceIntervalMemberQ [intervalValue, item] =
  case intervalSegmentsFromInterval intervalValue of
    Nothing -> Symbol "False"
    Just container -> intervalMembership container item
reduceIntervalMemberQ values = Call (Symbol "IntervalMemberQ") values

intervalMembership :: [IntervalSegment] -> Expr -> Expr
intervalMembership container (Call (Symbol "List") values) =
  list (map (intervalMembership container) values)
intervalMembership container candidate =
  case intervalSegmentsFromInterval candidate of
    Just segments -> boolean (all (intervalContainsSegment container) segments)
    Nothing -> case intervalSegmentFromArgument candidate of
      Just segment -> boolean (intervalContainsSegment container segment)
      Nothing -> Symbol "False"

intervalContainsSegment :: [IntervalSegment] -> IntervalSegment -> Bool
intervalContainsSegment container (IntervalSegment candidateLeft candidateRight) =
  any contains container
 where
  contains (IntervalSegment left right) =
    case
      ( compareIntervalEndpoint left candidateLeft
      , compareIntervalEndpoint candidateRight right
      )
    of
      (Just leftOrdering, Just rightOrdering) ->
        leftOrdering /= GT && rightOrdering /= GT
      _ -> False

intervalSegmentsFromInterval :: Expr -> Maybe [IntervalSegment]
intervalSegmentsFromInterval (Call (Symbol "Interval") values) =
  intervalSegmentsFromArguments values
intervalSegmentsFromInterval _ = Nothing

intervalSegmentsFromArguments :: [Expr] -> Maybe [IntervalSegment]
intervalSegmentsFromArguments values = do
  segments <- traverse intervalSegmentFromArgument values
  normalizeIntervalSegments segments

intervalSegmentFromArgument :: Expr -> Maybe IntervalSegment
intervalSegmentFromArgument argument = do
  let (left, right) = case argument of
        Call (Symbol "List") [first, second] -> (first, second)
        _ -> (argument, argument)
  ordering <- compareIntervalEndpoint left right
  pure
    ( if ordering == GT
        then IntervalSegment right left
        else IntervalSegment left right
    )

normalizeIntervalSegments :: [IntervalSegment] -> Maybe [IntervalSegment]
normalizeIntervalSegments segments
  | not (allIntervalEndpointsComparable segments) = Nothing
  | otherwise = mergeSegments [] (sortBy compareSegments segments)
 where
  appendSegment [] segment = Just [segment]
  appendSegment retained@(IntervalSegment lastLeft lastRight : rest) segment@(IntervalSegment left right) = do
    overlap <- compareIntervalEndpoint left lastRight
    if overlap == GT
      then Just (segment : retained)
      else do
        rightOrdering <- compareIntervalEndpoint right lastRight
        let merged =
              if rightOrdering == GT
                then IntervalSegment lastLeft right
                else IntervalSegment lastLeft lastRight
        Just (merged : rest)

  compareSegments (IntervalSegment leftStart leftEnd) (IntervalSegment rightStart rightEnd) =
    case compareIntervalEndpoint leftStart rightStart of
      Just EQ -> maybe EQ id (compareIntervalEndpoint leftEnd rightEnd)
      Just ordering -> ordering
      Nothing -> EQ

  -- The merge is accumulated in reverse order so replacing the most recent
  -- segment remains constant-time. Restore Python's ascending output order.
  mergeSegments initial [] = Just (reverse initial)
  mergeSegments initial (value : remaining) = do
    next <- appendSegment initial value
    case remaining of
      [] -> Just (reverse next)
      _ -> mergeSegments next remaining

allIntervalEndpointsComparable :: [IntervalSegment] -> Bool
allIntervalEndpointsComparable segments =
  all pairComparable [(left, right) | left <- endpoints, right <- endpoints]
 where
  endpoints = concatMap (\(IntervalSegment left right) -> [left, right]) segments
  pairComparable (left, right) = case compareIntervalEndpoint left right of
    Just _ -> True
    Nothing -> False

intersectIntervalSets
  :: [IntervalSegment]
  -> [IntervalSegment]
  -> Maybe [IntervalSegment]
intersectIntervalSets left right =
  normalizeIntervalSegments
    (mapMaybe (uncurry intersectIntervalSegments) [(a, b) | a <- left, b <- right])

intersectIntervalSegments
  :: IntervalSegment
  -> IntervalSegment
  -> Maybe IntervalSegment
intersectIntervalSegments
  (IntervalSegment leftStart leftEnd)
  (IntervalSegment rightStart rightEnd) = do
    startOrdering <- compareIntervalEndpoint leftStart rightStart
    endOrdering <- compareIntervalEndpoint leftEnd rightEnd
    let start = if startOrdering == LT then rightStart else leftStart
        end = if endOrdering == GT then rightEnd else leftEnd
    containment <- compareIntervalEndpoint start end
    if containment == GT
      then Nothing
      else Just (IntervalSegment start end)

intervalExpression :: [IntervalSegment] -> Expr
intervalExpression =
  Call (Symbol "Interval")
    . map (\(IntervalSegment left right) -> list [left, right])

compareIntervalEndpoint :: Expr -> Expr -> Maybe Ordering
compareIntervalEndpoint leftValue rightValue =
  case (intervalEndpointKind leftValue, intervalEndpointKind rightValue) of
    (IntervalNegativeInfinity, IntervalNegativeInfinity) -> Just EQ
    (IntervalNegativeInfinity, _) -> Just LT
    (_, IntervalNegativeInfinity) -> Just GT
    (IntervalPositiveInfinity, IntervalPositiveInfinity) -> Just EQ
    (IntervalPositiveInfinity, _) -> Just GT
    (_, IntervalPositiveInfinity) -> Just LT
    (IntervalFinite left, IntervalFinite right) ->
      compareExact <$> explicitRealExact left <*> explicitRealExact right

data IntervalEndpointKind
  = IntervalNegativeInfinity
  | IntervalFinite !Expr
  | IntervalPositiveInfinity

intervalEndpointKind :: Expr -> IntervalEndpointKind
intervalEndpointKind (Symbol "Infinity") = IntervalPositiveInfinity
intervalEndpointKind (Symbol "-Infinity") = IntervalNegativeInfinity
intervalEndpointKind (Call (Symbol "DirectedInfinity") [direction])
  | Just (Exact 1 1) <- explicitRealExact direction = IntervalPositiveInfinity
  | Just (Exact (-1) 1) <- explicitRealExact direction = IntervalNegativeInfinity
intervalEndpointKind value@(Call (Symbol "Times") factors)
  | length factors == 2
  , Symbol "Infinity" `elem` factors
  , any isNegativeOne factors = IntervalNegativeInfinity
  | otherwise = IntervalFinite value
 where
  isNegativeOne factor = explicitRealExact factor == Just (Exact (-1) 1)
intervalEndpointKind value = IntervalFinite value

predicateMatches :: Expr -> Expr -> Either EvaluationError Bool
predicateMatches criterion value =
  (== Symbol "True") <$> evaluate (Call criterion [value])

selectionLimit :: Text -> Maybe Expr -> Either EvaluationError (Maybe Integer)
selectionLimit _ Nothing = Right Nothing
selectionLimit _ (Just (Symbol "Infinity")) = Right Nothing
selectionLimit _ (Just (Integer limit))
  | limit >= 0 = Right (Just limit)
selectionLimit operation _ =
  Left (EvaluationError (operation <> " expects a non-negative integer or Infinity limit"))

reduceSelect :: Bool -> [Expr] -> Either EvaluationError Expr
reduceSelect discardMode = \case
  [subject, criterion] -> selectSubject subject criterion Nothing
  [subject, criterion, limit] -> selectSubject subject criterion (Just limit)
  values -> Right (Call (Symbol operation) values)
 where
  selectSubject subject criterion limit
    | isPropertySelection criterion =
        Right (Call (Symbol operation) (subject : criterion : maybe [] pure limit))
    | otherwise = do
        items <- orderedItems operation subject
        remaining <- selectionLimit operation limit
        (_, selected) <- foldM (selectItem criterion) (remaining, []) items
        pure (rebuildOrdered subject selected)
  selectItem criterion (remaining, retained) item@(OrderedItem _ value _ _) = do
    matches <- predicateMatches criterion value
    let mayConsume = maybe True (> 0) remaining
        consumes = matches && mayConsume
        nextRemaining = case remaining of
          Just count | consumes -> Just (count - 1)
          _ -> remaining
        keep = if discardMode then not consumes else consumes
    pure (nextRemaining, if keep then retained <> [item] else retained)
  operation = if discardMode then "Discard" else "Select"

isPropertySelection :: Expr -> Bool
isPropertySelection (Call (Symbol "Rule") [_, _]) = True
isPropertySelection (Call (Symbol "RuleDelayed") [_, _]) = True
isPropertySelection _ = False

reduceSelectFirst :: [Expr] -> Either EvaluationError Expr
reduceSelectFirst = \case
  [subject, criterion] -> selectFirst subject criterion Nothing
  [subject, criterion, defaultValue] -> selectFirst subject criterion (Just defaultValue)
  values -> Right (Call (Symbol "SelectFirst") values)
 where
  selectFirst subject criterion defaultValue
    | isPropertySelection criterion =
        Right (Call (Symbol "SelectFirst") (subject : criterion : maybe [] pure defaultValue))
    | otherwise = do
        items <- orderedItems "SelectFirst" subject
        findMatch criterion defaultValue items
  findMatch _ defaultValue [] =
    Right (maybe (Call (Symbol "Missing") [String "NotFound"]) id defaultValue)
  findMatch criterion defaultValue (OrderedItem _ value _ _ : rest) = do
    matches <- predicateMatches criterion value
    if matches then Right value else findMatch criterion defaultValue rest

reduceTakeWhile :: [Expr] -> Either EvaluationError Expr
reduceTakeWhile [subject, criterion] = do
  items <- orderedItems "TakeWhile" subject
  retained <- takeMatching items
  pure (rebuildOrdered subject retained)
 where
  takeMatching [] = Right []
  takeMatching (item@(OrderedItem _ value _ _) : rest) = do
    matches <- predicateMatches criterion value
    if matches then (item :) <$> takeMatching rest else Right []
reduceTakeWhile values = Right (Call (Symbol "TakeWhile") values)

reduceLengthWhile :: [Expr] -> Either EvaluationError Expr
reduceLengthWhile [subject, criterion] = do
  items <- orderedItems "LengthWhile" subject
  Integer . fromIntegral <$> matchingLength items
 where
  matchingLength [] = Right (0 :: Int)
  matchingLength (OrderedItem _ value _ _ : rest) = do
    matches <- predicateMatches criterion value
    if matches then (1 +) <$> matchingLength rest else Right 0
reduceLengthWhile values = Right (Call (Symbol "LengthWhile") values)

reducePick :: [Expr] -> Either EvaluationError Expr
reducePick = \case
  [subject, selector] -> pickSubject subject selector (Symbol "True")
  [subject, selector, pattern] -> pickSubject subject selector pattern
  values -> Right (Call (Symbol "Pick") values)
 where
  pickSubject subject (Call (Symbol "List") selectors) pattern = do
    items <- orderedItems "Pick" subject
    if length items /= length selectors
      then Left (EvaluationError "Pick expects one selector per first-level value")
      else
        pure
          ( rebuildOrdered
              subject
              [item | (item, selector) <- zip items selectors, selector == pattern]
          )
  pickSubject _ _ _ = Left (EvaluationError "Pick expects a selector list")

reduceBoole :: [Expr] -> Expr
reduceBoole [Symbol "True"] = Integer 1
reduceBoole [Symbol "False"] = Integer 0
reduceBoole values = Call (Symbol "Boole") values

data PatternBinding
  = ScalarBinding !Expr
  | SequenceBinding ![Expr]
  deriving (Eq, Show)

type PatternBindings = [(Text, PatternBinding)]

data SequencePattern = SequencePattern
  { sequenceMinimum :: !Int
  , sequenceHead :: !(Maybe Expr)
  , sequenceName :: !(Maybe Text)
  , sequenceCondition :: !(Maybe Expr)
  , sequenceTest :: !(Maybe Expr)
  }
  deriving (Eq, Show)

reduceMatchQ :: [Expr] -> Expr
reduceMatchQ [expression, patternExpression] =
  boolean (maybe False (const True) (matchPattern [] expression patternExpression))
reduceMatchQ values = Call (Symbol "MatchQ") values

matchesPattern :: Expr -> Expr -> Bool
matchesPattern expression patternExpression =
  maybe False (const True) (matchPattern [] expression patternExpression)

-- | Match a subject against a Wolfram pattern and substitute the resulting
-- scalar or sequence bindings into a held template without evaluating it.
instantiatePatternMatch :: Expr -> Expr -> Expr -> Maybe Expr
instantiatePatternMatch expression patternExpression template = do
  bindings <- matchPattern [] expression patternExpression
  pure (substituteBindings bindings template)

-- | Match and instantiate a held template while delegating Condition and
-- PatternTest evaluation to the caller.  The callback lives in an arbitrary
-- monad so a session evaluator can thread definitions, messages, prints, and
-- other observable state through every attempted match in traversal order.
instantiatePatternMatchWith
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> Expr
  -> Expr
  -> Expr
  -> monad (Maybe Expr)
instantiatePatternMatchWith evaluator expression patternExpression template = do
  matched <- matchPatternM evaluator [] expression patternExpression
  pure (fmap (`substituteBindings` template) matched)

-- | Variant of 'instantiatePatternMatchWith' that keeps template boundaries
-- intact.  It is useful for a rule whose body and trailing Condition must be
-- instantiated from one match without running matcher callbacks twice.
instantiatePatternMatchManyWith
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> Expr
  -> Expr
  -> [Expr]
  -> monad (Maybe [Expr])
instantiatePatternMatchManyWith evaluator expression patternExpression templates = do
  matched <- matchPatternM evaluator [] expression patternExpression
  pure (fmap (\bindings -> map (substituteBindings bindings) templates) matched)

-- | Attribute-aware variant used by an evaluation session.  Resolving
-- attributes in the matcher's monad is intentional: a Condition or
-- PatternTest callback can mutate a symbol before a later nested call is
-- matched.
instantiatePatternMatchManyWithAttributes
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Expr
  -> Expr
  -> [Expr]
  -> monad (Maybe [Expr])
instantiatePatternMatchManyWithAttributes evaluator attributeResolver expression patternExpression templates = do
  matched <-
    matchPatternWithAttributesM
      evaluator
      attributeResolver
      []
      expression
      patternExpression
  pure (fmap (\bindings -> map (substituteBindings bindings) templates) matched)

matchPattern :: PatternBindings -> Expr -> Expr -> Maybe PatternBindings
matchPattern bindings expression patternExpression =
  runIdentity
    (matchPatternM purePatternEvaluator bindings expression patternExpression)

purePatternEvaluator :: Expr -> Identity (Maybe Expr)
purePatternEvaluator expression =
  Identity (either (const Nothing) Just (evaluate expression))

matchPatternM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> PatternBindings
  -> Expr
  -> Expr
  -> monad (Maybe PatternBindings)
matchPatternM evaluator =
  matchPatternWithAttributesM evaluator catalogPatternAttributes

catalogPatternAttributes
  :: Applicative monad
  => Expr
  -> monad (Set.Set SymbolAttribute)
catalogPatternAttributes (Symbol name) =
  pure (maybe Set.empty id (systemSymbolAttributes name))
catalogPatternAttributes _ = pure Set.empty

matchPatternWithAttributesM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> PatternBindings
  -> Expr
  -> Expr
  -> monad (Maybe PatternBindings)
matchPatternWithAttributesM evaluator attributeResolver bindings expression patternExpression = case patternExpression of
  Call (Symbol "IgnoringInactive") [innerPattern] ->
    matchIgnoringInactiveM evaluator attributeResolver bindings expression innerPattern
  Call (Symbol "Verbatim") [literal] ->
    pure (if expression == literal then Just bindings else Nothing)
  Call (Symbol "Pattern") [Symbol name, innerPattern] -> do
    matched <- recurse bindings expression innerPattern
    pure (matched >>= bindScalar name expression)
  Call (Symbol "Optional") [innerPattern] ->
    recurse bindings expression innerPattern
  Call (Symbol "Optional") [innerPattern, _] ->
    recurse bindings expression innerPattern
  Call (Symbol "Blank") [] -> pure (Just bindings)
  Call (Symbol "Blank") [requiredHead] ->
    pure (if headExpr expression == requiredHead then Just bindings else Nothing)
  Call (Symbol "BlankSequence") [] -> pure (Just bindings)
  Call (Symbol "BlankSequence") [requiredHead] ->
    pure (if headExpr expression == requiredHead then Just bindings else Nothing)
  Call (Symbol "BlankNullSequence") [] -> pure (Just bindings)
  Call (Symbol "BlankNullSequence") [requiredHead] ->
    pure (if headExpr expression == requiredHead then Just bindings else Nothing)
  Call (Symbol "Alternatives") alternatives -> firstMatch alternatives
  Call (Symbol "Except") [excluded] -> do
    excludedMatch <- recurse bindings expression excluded
    pure (case excludedMatch of Nothing -> Just bindings; Just _ -> Nothing)
  Call (Symbol "Except") [excluded, included] -> do
    allowed <- recurse bindings expression included
    case allowed of
      Nothing -> pure Nothing
      Just matched -> do
        excludedMatch <- recurse bindings expression excluded
        pure (case excludedMatch of Nothing -> Just matched; Just _ -> Nothing)
  Call (Symbol "Condition") [innerPattern, condition] -> do
    innerMatch <- recurse bindings expression innerPattern
    case innerMatch of
      Nothing -> pure Nothing
      Just matched -> do
        conditionResult <- evaluator (substituteBindings matched condition)
        pure
          ( if conditionResult == Just (Symbol "True")
              then Just matched
              else Nothing
          )
  Call (Symbol "PatternTest") [innerPattern, test] -> do
    innerMatch <- recurse bindings expression innerPattern
    case innerMatch of
      Nothing -> pure Nothing
      Just matched -> do
        testResult <- evaluator (Call test [expression])
        pure
          ( if testResult == Just (Symbol "True")
              then Just matched
              else Nothing
          )
  Call (Symbol "KeyValuePattern") [specification] ->
    matchKeyValuePatternM evaluator attributeResolver bindings expression specification
  Call (Symbol "HoldPattern") [innerPattern] ->
    recurse bindings expression innerPattern
  Call (Symbol "Longest") (innerPattern : _) ->
    recurse bindings expression innerPattern
  Call (Symbol "Shortest") (innerPattern : _) ->
    recurse bindings expression innerPattern
  _
    | Just _ <- sequencePatternBounds patternExpression ->
        matchSequencePatternElementsM evaluator attributeResolver False bindings patternExpression [expression]
  Call patternHead patternArguments -> case expression of
    Call expressionHead expressionArguments -> do
      headMatch <- recurse bindings expressionHead patternHead
      case headMatch of
        Nothing -> pure Nothing
        Just headBindings -> do
          attributes <- attributeResolver expressionHead
          matchCallArgumentsWithAttributesM
            evaluator
            attributeResolver
            False
            expressionHead
            attributes
            headBindings
            expressionArguments
            patternArguments
    _ -> pure Nothing
  _ -> pure (if expression == patternExpression then Just bindings else Nothing)
 where
  recurse = matchPatternWithAttributesM evaluator attributeResolver
  firstMatch [] = pure Nothing
  firstMatch (alternative : rest) = do
    matched <- recurse bindings expression alternative
    case matched of
      Just _ -> pure matched
      Nothing -> firstMatch rest

matchIgnoringInactiveM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> PatternBindings
  -> Expr
  -> Expr
  -> monad (Maybe PatternBindings)
matchIgnoringInactiveM evaluator attributeResolver bindings expression patternExpression = case activeView patternExpression of
  Call (Symbol "IgnoringInactive") [innerPattern] ->
    recurse bindings expression innerPattern
  Call (Symbol "HoldPattern") [innerPattern] ->
    recurse bindings expression innerPattern
  Call (Symbol "Verbatim") [literal] ->
    pure (if activeView expression == activeView literal then Just bindings else Nothing)
  Call (Symbol "Pattern") [Symbol name, innerPattern] -> do
    matched <- recurse bindings expression innerPattern
    pure (matched >>= bindScalar name expression)
  Call (Symbol "Blank") [] -> pure (Just bindings)
  Call (Symbol "Blank") [requiredHead] ->
    pure
      ( if headExpr (activeView expression) == activeView requiredHead
          then Just bindings
          else Nothing
      )
  Call (Symbol "Alternatives") alternatives -> firstMatch alternatives
  Call (Symbol "Except") [excluded] -> do
    excludedMatch <- recurse bindings expression excluded
    pure (case excludedMatch of Nothing -> Just bindings; Just _ -> Nothing)
  Call (Symbol "Except") [excluded, included] -> do
    allowed <- recurse bindings expression included
    case allowed of
      Nothing -> pure Nothing
      Just matched -> do
        excludedMatch <- recurse bindings expression excluded
        pure (case excludedMatch of Nothing -> Just matched; Just _ -> Nothing)
  Call (Symbol "Condition") [innerPattern, condition] -> do
    innerMatch <- recurse bindings expression innerPattern
    case innerMatch of
      Nothing -> pure Nothing
      Just matched -> do
        conditionResult <- evaluator (substituteBindings matched condition)
        pure
          ( if conditionResult == Just (Symbol "True")
              then Just matched
              else Nothing
          )
  Call (Symbol "PatternTest") [innerPattern, test] -> do
    innerMatch <- recurse bindings expression innerPattern
    case innerMatch of
      Nothing -> pure Nothing
      Just matched -> do
        testResult <- evaluator (Call test [expression])
        pure
          ( if testResult == Just (Symbol "True")
              then Just matched
              else Nothing
          )
  Call patternHead patternArguments -> case activeView expression of
    structuralExpression@(Call structuralHead structuralArguments) -> do
      let candidateHead = inactiveMatchingHead expression structuralExpression structuralHead
          candidateArguments = inactiveMatchingArguments expression structuralExpression structuralArguments
      headMatch <- recurse bindings candidateHead patternHead
      case headMatch of
        Nothing -> pure Nothing
        Just headBindings -> do
          attributes <- attributeResolver candidateHead
          matchCallArgumentsWithAttributesM
            evaluator
            attributeResolver
            True
            candidateHead
            attributes
            headBindings
            candidateArguments
            patternArguments
    _ -> pure Nothing
  structuralPattern ->
    pure (if activeView expression == structuralPattern then Just bindings else Nothing)
 where
  recurse = matchIgnoringInactiveM evaluator attributeResolver
  firstMatch [] = pure Nothing
  firstMatch (alternative : rest) = do
    matched <- recurse bindings expression alternative
    case matched of
      Just _ -> pure matched
      Nothing -> firstMatch rest

inactiveMatchingHead :: Expr -> Expr -> Expr -> Expr
inactiveMatchingHead original structural structuralHead
  | isInactiveWrapper original = case structural of
      Call activeHead _ -> activeHead
      _ -> structuralHead
  | otherwise = headExpr original

inactiveMatchingArguments :: Expr -> Expr -> [Expr] -> [Expr]
inactiveMatchingArguments original structural structuralArguments = case (original, structural) of
  (Call _ originalArguments, Call _ activeArguments)
    | not (isInactiveWrapper original)
    , length originalArguments == length activeArguments -> originalArguments
  _ -> structuralArguments

activeView :: Expr -> Expr
activeView expression
  | isInactiveWrapper expression = case expression of
      Call _ [inner] -> activeView inner
      _ -> expression
activeView (Call expressionHead values) =
  Call (activeView expressionHead) (map activeView values)
activeView expression = expression

isInactiveWrapper :: Expr -> Bool
isInactiveWrapper (Call (Symbol inactiveHead) [_]) =
  systemHeadIn ["Inactive"] inactiveHead
isInactiveWrapper _ = False

matchKeyValuePatternM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> PatternBindings
  -> Expr
  -> Expr
  -> monad (Maybe PatternBindings)
matchKeyValuePatternM evaluator attributeResolver bindings expression specification =
  case keyValuePatternElements expression of
    Nothing -> pure Nothing
    Just elements ->
      matchItems bindings elements (keyValuePatternItems specification) ([] :: [Int])
 where
  matchItems current _ [] _ = pure (Just current)
  matchItems current elements (patternExpression : remainingPatterns) usedIndices =
    tryElements 0 elements
   where
    tryElements _ [] = pure Nothing
    tryElements index (element : rest)
      | index `elem` usedIndices = tryElements (index + 1) rest
      | otherwise = do
          matched <-
            matchPatternWithAttributesM
              evaluator
              attributeResolver
              current
              element
              patternExpression
          case matched of
            Nothing -> tryElements (index + 1) rest
            Just updated -> do
              completed <-
                matchItems
                  updated
                  elements
                  remainingPatterns
                  (index : usedIndices)
              case completed of
                Just _ -> pure completed
                Nothing -> tryElements (index + 1) rest

keyValuePatternElements :: Expr -> Maybe [Expr]
keyValuePatternElements association
  | Just entries <- associationEntries association =
      Just
        [ Call (Symbol ruleHead) [key, value]
        | AssociationEntry ruleHead key value <- entries
        ]
keyValuePatternElements (Call (Symbol "List") values) = do
  _ <- traverse ruleEntry values
  Just values
keyValuePatternElements _ = Nothing

keyValuePatternItems :: Expr -> [Expr]
keyValuePatternItems (Call (Symbol "List") values) = values
keyValuePatternItems specification = [specification]

matchCallArgumentsWithAttributesM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> Expr
  -> Set.Set SymbolAttribute
  -> PatternBindings
  -> [Expr]
  -> [Expr]
  -> monad (Maybe PatternBindings)
matchCallArgumentsWithAttributesM evaluator attributeResolver ignoreInactive expressionHead attributes bindings expressions patterns =
  tryArgumentOrders argumentOrders
 where
  argumentOrders
    | Set.member Orderless attributes = uniqueArgumentPermutations expressions
    | otherwise = [expressions]
  tryArgumentOrders [] = pure Nothing
  tryArgumentOrders (ordered : rest) = do
    matched <-
      if Set.member Flat attributes
        then
          matchFlatPatternArgumentsM
            evaluator
            attributeResolver
            ignoreInactive
            expressionHead
            attributes
            bindings
            ordered
            patterns
        else
          matchPatternArgumentsM
            evaluator
            attributeResolver
            ignoreInactive
            bindings
            ordered
            patterns
    case matched of
      Just _ -> pure matched
      Nothing -> tryArgumentOrders rest

uniqueArgumentPermutations :: [Expr] -> [[Expr]]
uniqueArgumentPermutations [] = [[]]
uniqueArgumentPermutations values =
  [ selected : suffix
  | (selected, remaining) <- selectUniqueEach values
  , suffix <- uniqueArgumentPermutations remaining
  ]

-- Select the first occurrence of each distinct value at the current
-- permutation position.  This produces the same first-seen order as filtering
-- Python's itertools.permutations through a set, without retaining and
-- linearly rescanning up to n! completed permutations.
selectUniqueEach :: Eq value => [value] -> [(value, [value])]
selectUniqueEach [] = []
selectUniqueEach (value : rest) =
  (value, rest)
    : [ (selected, value : remaining)
      | (selected, remaining) <- selectUniqueEach rest
      , selected /= value
      ]

-- Python's itertools.permutations advances the leftmost selected position
-- first.  Data.List.permutations uses a different order, which is observable
-- when ambiguous patterns bind values or run effectful callbacks.
pythonOrderedPermutations :: [value] -> [[value]]
pythonOrderedPermutations [] = [[]]
pythonOrderedPermutations values =
  [ selected : suffix
  | (selected, remaining) <- selectEach values
  , suffix <- pythonOrderedPermutations remaining
  ]
 where
  selectEach [] = []
  selectEach (value : rest) =
    (value, rest)
      : [ (selected, value : remaining)
        | (selected, remaining) <- selectEach rest
        ]

matchFlatPatternArgumentsM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> Expr
  -> Set.Set SymbolAttribute
  -> PatternBindings
  -> [Expr]
  -> [Expr]
  -> monad (Maybe PatternBindings)
matchFlatPatternArgumentsM _ _ _ _ _ bindings [] [] = pure (Just bindings)
matchFlatPatternArgumentsM evaluator attributeResolver ignoreInactive expressionHead attributes bindings expressions (patternExpression : remainingPatterns)
  | Just (minimumCount, patternMaximum) <- sequencePatternBounds patternExpression =
      trySequenceLengths (candidateCounts minimumCount patternMaximum)
  | otherwise = tryScalarLengths [1 .. maximumLength]
 where
  remainingMinimum = minimumPatternArguments remainingPatterns
  maximumLength = length expressions - remainingMinimum
  candidateCounts minimumCount patternMaximum =
    let concreteMaximum = min patternMaximum maximumLength
     in if sequencePrefersLongest patternExpression
          then [concreteMaximum, concreteMaximum - 1 .. minimumCount]
          else [minimumCount .. concreteMaximum]
  trySequenceLengths [] = pure Nothing
  trySequenceLengths (count : rest) = do
    let (segment, remainingExpressions) = splitAt count expressions
    matched <-
      matchSequencePatternElementsM
        evaluator
        attributeResolver
        ignoreInactive
        bindings
        patternExpression
        segment
    completeOrContinue remainingExpressions rest matched trySequenceLengths
  tryScalarLengths [] = pure Nothing
  tryScalarLengths (count : rest) = do
    let (segment, remainingExpressions) = splitAt count expressions
        groupedExpression = case segment of
          [single]
            | Set.member OneIdentity attributes -> single
          _ -> Call expressionHead segment
    matched <-
      matchNestedPatternM
        evaluator
        attributeResolver
        ignoreInactive
        bindings
        groupedExpression
        patternExpression
    completeOrContinue remainingExpressions rest matched tryScalarLengths
  completeOrContinue _ rest Nothing continue = continue rest
  completeOrContinue remainingExpressions rest (Just updated) continue = do
    completed <-
      matchFlatPatternArgumentsM
        evaluator
        attributeResolver
        ignoreInactive
        expressionHead
        attributes
        updated
        remainingExpressions
        remainingPatterns
    case completed of
      Just _ -> pure completed
      Nothing -> continue rest
matchFlatPatternArgumentsM _ _ _ _ _ _ _ _ = pure Nothing

matchNestedPatternM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> PatternBindings
  -> Expr
  -> Expr
  -> monad (Maybe PatternBindings)
matchNestedPatternM evaluator attributeResolver ignoreInactive
  | ignoreInactive = matchIgnoringInactiveM evaluator attributeResolver
  | otherwise = matchPatternWithAttributesM evaluator attributeResolver

matchPatternArgumentsM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> PatternBindings
  -> [Expr]
  -> [Expr]
  -> monad (Maybe PatternBindings)
matchPatternArgumentsM _ _ _ bindings [] [] = pure (Just bindings)
matchPatternArgumentsM _ _ _ _ [] patterns
  | minimumPatternArguments patterns > 0 = pure Nothing
matchPatternArgumentsM evaluator attributeResolver ignoreInactive bindings expressions (patternExpression : remainingPatterns)
  | Just (minimumCount, patternMaximum) <- sequencePatternBounds patternExpression =
      matchSequenceCounts (candidateCounts minimumCount patternMaximum)
 where
  availableCount = length expressions - minimumPatternArguments remainingPatterns
  candidateCounts minimumCount patternMaximum =
    let maximumCount = min patternMaximum availableCount
     in if sequencePrefersLongest patternExpression
          then [maximumCount, maximumCount - 1 .. minimumCount]
          else [minimumCount .. maximumCount]
  matchSequenceCounts [] = pure Nothing
  matchSequenceCounts (count : rest) = do
    let (segment, remainingExpressions) = splitAt count expressions
    matched <-
      matchSequencePatternElementsM
        evaluator
        attributeResolver
        ignoreInactive
        bindings
        patternExpression
        segment
    case matched of
      Nothing -> matchSequenceCounts rest
      Just updated -> do
        completed <-
          matchPatternArgumentsM evaluator attributeResolver ignoreInactive updated remainingExpressions remainingPatterns
        case completed of
          Just _ -> pure completed
          Nothing -> matchSequenceCounts rest
matchPatternArgumentsM evaluator attributeResolver ignoreInactive bindings (expression : remainingExpressions) (patternExpression : remainingPatterns) = do
  matched <-
    matchNestedPatternM
      evaluator
      attributeResolver
      ignoreInactive
      bindings
      expression
      patternExpression
  case matched of
    Nothing -> pure Nothing
    Just updated ->
      matchPatternArgumentsM evaluator attributeResolver ignoreInactive updated remainingExpressions remainingPatterns
matchPatternArgumentsM _ _ _ _ _ _ = pure Nothing

minimumPatternArguments :: [Expr] -> Int
minimumPatternArguments =
  sum . map (maybe 1 fst . sequencePatternBounds)

sequencePatternBounds :: Expr -> Maybe (Int, Int)
sequencePatternBounds expression = case expression of
  Call (Symbol "BlankSequence") patternArguments
    | length patternArguments <= 1 -> Just (1, levelInfinity)
  Call (Symbol "BlankNullSequence") patternArguments
    | length patternArguments <= 1 -> Just (0, levelInfinity)
  Call (Symbol "PatternTest") [inner, _] -> sequencePatternBounds inner
  Call (Symbol "Condition") [inner, _] -> sequencePatternBounds inner
  Call (Symbol "HoldPattern") [inner] -> sequencePatternBounds inner
  Call (Symbol "Optional") [inner] ->
    Just (patternWidthBounds inner)
  Call (Symbol "Optional") [inner, _] ->
    let (_, maximumWidth) = patternWidthBounds inner
     in Just (0, maximumWidth)
  Call (Symbol "Alternatives") alternatives
    | not (null alternatives)
    , any isSequenceArgumentPattern alternatives ->
        let widths = map patternWidthBounds alternatives
         in Just
              ( minimum (map fst widths)
              , maximum (map snd widths)
              )
  Call (Symbol priority) (inner : _)
    | priority `elem` ["Longest", "Shortest"] -> sequencePatternBounds inner
  Call (Symbol "Pattern") [_, inner] -> sequencePatternBounds inner
  Call (Symbol repetitionHead) patternArguments
    | repetitionHead `elem` ["Repeated", "RepeatedNull"] -> do
        itemPattern <- case patternArguments of
          item : _ -> Just item
          [] -> Nothing
        (countMinimum, countMaximum) <- repetitionCountBounds repetitionHead patternArguments
        let (itemMinimum, itemMaximum) = patternWidthBounds itemPattern
        pure
          ( boundedMultiply itemMinimum countMinimum
          , boundedMultiply itemMaximum countMaximum
          )
  Call (Symbol "PatternSequence") patterns ->
    Just (addPatternWidths (map patternWidthBounds patterns))
  Call (Symbol "OrderlessPatternSequence") patterns ->
    Just (addPatternWidths (map patternWidthBounds patterns))
  Call (Symbol "OptionsPattern") patternArguments
    | length patternArguments <= 1 -> Just (0, levelInfinity)
  _ -> Nothing

isSequenceArgumentPattern :: Expr -> Bool
isSequenceArgumentPattern expression = case sequencePatternBounds expression of
  Just _ -> True
  Nothing -> False

sequencePrefersLongest :: Expr -> Bool
sequencePrefersLongest expression = case expression of
  Call (Symbol "Longest") (_ : _) -> True
  Call (Symbol "Shortest") (_ : _) -> False
  Call (Symbol "Optional") [_, _] -> True
  Call (Symbol wrapper) (inner : _)
    | wrapper `elem` ["PatternTest", "Condition", "HoldPattern"] ->
        sequencePrefersLongest inner
  Call (Symbol "Pattern") [_, inner] -> sequencePrefersLongest inner
  _ -> False

patternWidthBounds :: Expr -> (Int, Int)
patternWidthBounds expression =
  maybe (1, 1) id (sequencePatternBounds expression)

repetitionCountBounds :: Text -> [Expr] -> Maybe (Int, Int)
repetitionCountBounds repetitionHead patternArguments = case patternArguments of
  [_] -> Just (defaultMinimum, levelInfinity)
  [_, specification] -> case specification of
    Call (Symbol "List") [single] -> do
      count <- repetitionBound single
      Just (count, count)
    Call (Symbol "List") [lower, upper] ->
      (,) <$> repetitionBound lower <*> repetitionBound upper
    _ -> do
      upper <- repetitionBound specification
      Just (defaultMinimum, upper)
  _ -> Nothing
 where
  defaultMinimum = if repetitionHead == "Repeated" then 1 else 0

repetitionBound :: Expr -> Maybe Int
repetitionBound (Integer value)
  | value >= 0 = Just (fromInteger (min (toInteger levelInfinity) value))
repetitionBound (Symbol "Infinity") = Just levelInfinity
repetitionBound _ = Nothing

addPatternWidths :: [(Int, Int)] -> (Int, Int)
addPatternWidths = foldl addWidth (0, 0)
 where
  addWidth (minimumTotal, maximumTotal) (minimumWidth, maximumWidth) =
    ( boundedAdd minimumTotal minimumWidth
    , boundedAdd maximumTotal maximumWidth
    )

boundedAdd :: Int -> Int -> Int
boundedAdd left right
  | left >= levelInfinity || right >= levelInfinity = levelInfinity
  | otherwise = fromInteger (min (toInteger levelInfinity) (toInteger left + toInteger right))

boundedMultiply :: Int -> Int -> Int
boundedMultiply left right
  | left == 0 || right == 0 = 0
  | left >= levelInfinity || right >= levelInfinity = levelInfinity
  | otherwise = fromInteger (min (toInteger levelInfinity) (toInteger left * toInteger right))

bindOptionalDefaultM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> PatternBindings
  -> Expr
  -> Expr
  -> monad (Maybe PatternBindings)
bindOptionalDefaultM evaluator bindings patternExpression defaultValue = case patternExpression of
  Call (Symbol wrapper) (innerPattern : _)
    | wrapper `elem` ["HoldPattern", "Longest", "Shortest"] ->
        recurse bindings innerPattern
  Call (Symbol "PatternTest") [innerPattern, test] -> do
    matched <- recurse bindings innerPattern
    case matched of
      Nothing -> pure Nothing
      Just updated -> do
        result <- evaluator (Call test [defaultValue])
        pure (if result == Just (Symbol "True") then Just updated else Nothing)
  Call (Symbol "Condition") [innerPattern, condition] -> do
    matched <- recurse bindings innerPattern
    case matched of
      Nothing -> pure Nothing
      Just updated -> do
        result <- evaluator (substituteBindings updated condition)
        pure (if result == Just (Symbol "True") then Just updated else Nothing)
  Call (Symbol "Pattern") [Symbol name, innerPattern] -> do
    matched <- recurse bindings innerPattern
    pure (matched >>= bindScalar name defaultValue)
  Call (Symbol "Alternatives") alternatives -> firstAlternative alternatives
  Call (Symbol patternHead) _
    | patternHead
        `elem` [ "Blank"
               , "BlankSequence"
               , "BlankNullSequence"
               , "Repeated"
               , "RepeatedNull"
               , "PatternSequence"
               , "OrderlessPatternSequence"
               , "OptionsPattern"
               ] -> pure (Just bindings)
  _ -> pure (if patternExpression == defaultValue then Just bindings else Nothing)
 where
  recurse current innerPattern =
    bindOptionalDefaultM evaluator current innerPattern defaultValue
  firstAlternative [] = pure Nothing
  firstAlternative (alternative : rest) = do
    matched <- recurse bindings alternative
    case matched of
      Just _ -> pure matched
      Nothing -> firstAlternative rest

sequencePatternDescriptor :: Expr -> Maybe SequencePattern
sequencePatternDescriptor = describe Nothing Nothing Nothing
 where
  describe name condition test = \case
    Call (Symbol "Pattern") [Symbol patternName, inner] ->
      describe (Just patternName) condition test inner
    Call (Symbol "Condition") [inner, conditionExpression] ->
      describe name (Just conditionExpression) test inner
    Call (Symbol "PatternTest") [inner, predicate] ->
      describe name condition (Just predicate) inner
    Call (Symbol "BlankSequence") [] ->
      Just (SequencePattern 1 Nothing name condition test)
    Call (Symbol "BlankSequence") [requiredHead] ->
      Just (SequencePattern 1 (Just requiredHead) name condition test)
    Call (Symbol "BlankNullSequence") [] ->
      Just (SequencePattern 0 Nothing name condition test)
    Call (Symbol "BlankNullSequence") [requiredHead] ->
      Just (SequencePattern 0 (Just requiredHead) name condition test)
    _ -> Nothing

matchSequencePatternM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> PatternBindings
  -> SequencePattern
  -> [Expr]
  -> monad (Maybe PatternBindings)
matchSequencePatternM evaluator bindings descriptor values
  | length values < sequenceMinimum descriptor = pure Nothing
  | maybe False (\requiredHead -> any ((/= requiredHead) . headExpr) values) (sequenceHead descriptor) = pure Nothing
  | otherwise = validateSequenceTests
 where
  validateSequenceTests = case sequenceTest descriptor of
    Nothing -> bindAndValidateCondition
    Just test -> validateValues test values
  validateValues _ [] = bindAndValidateCondition
  validateValues test (value : rest) = do
    result <- evaluator (Call test [value])
    if result == Just (Symbol "True")
      then validateValues test rest
      else pure Nothing
  bindAndValidateCondition = case sequenceName descriptor of
    Nothing -> validateCondition bindings
    Just name -> case bindSequence name values bindings of
      Nothing -> pure Nothing
      Just bound -> validateCondition bound
  validateCondition bound = case sequenceCondition descriptor of
    Nothing -> pure (Just bound)
    Just condition -> do
      result <- evaluator (substituteBindings bound condition)
      pure
        ( if result == Just (Symbol "True")
            then Just bound
            else Nothing
        )

matchSequencePatternElementsM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> PatternBindings
  -> Expr
  -> [Expr]
  -> monad (Maybe PatternBindings)
matchSequencePatternElementsM evaluator attributeResolver ignoreInactive bindings patternExpression values = case patternExpression of
  Call (Symbol "Alternatives") alternatives ->
    firstAlternative alternatives
  Call (Symbol "HoldPattern") [innerPattern] ->
    recurse bindings innerPattern values
  Call (Symbol priority) (innerPattern : _)
    | priority `elem` ["Longest", "Shortest"] ->
        recurse bindings innerPattern values
  Call (Symbol "Condition") [innerPattern, condition] -> do
    matched <- recurse bindings innerPattern values
    case matched of
      Nothing -> pure Nothing
      Just updated -> do
        result <- evaluator (substituteBindings updated condition)
        pure
          ( if result == Just (Symbol "True")
              then Just updated
              else Nothing
          )
  Call (Symbol "PatternTest") [innerPattern, test] -> do
    matched <- recurse bindings innerPattern values
    case matched of
      Nothing -> pure Nothing
      Just updated -> validateValues updated test values
  Call (Symbol "Optional") [innerPattern]
    | null values -> pure Nothing
    | otherwise -> recurse bindings innerPattern values
  Call (Symbol "Optional") [innerPattern, defaultValue]
    | null values ->
        bindOptionalDefaultM evaluator bindings innerPattern defaultValue
    | otherwise -> recurse bindings innerPattern values
  Call (Symbol "Pattern") [Symbol name, innerPattern] -> do
    matched <- recurse bindings innerPattern values
    pure (matched >>= bindSequence name values)
  Call (Symbol "PatternSequence") patterns ->
    matchPatternArgumentsM evaluator attributeResolver ignoreInactive bindings values patterns
  Call (Symbol "OrderlessPatternSequence") patterns ->
    matchOrderlessPatternSequenceM
      evaluator
      attributeResolver
      ignoreInactive
      bindings
      values
      (pythonOrderedPermutations patterns)
  Call (Symbol "OptionsPattern") patternArguments
    | length patternArguments <= 1 ->
        pure (if all isOptionExpression values then Just bindings else Nothing)
  repeated@(Call (Symbol repetitionHead) _)
    | repetitionHead `elem` ["Repeated", "RepeatedNull"] ->
        matchRepeatedPatternM evaluator attributeResolver ignoreInactive bindings repeated values
  _
    | Just descriptor <- sequencePatternDescriptor patternExpression ->
        matchSequencePatternM evaluator bindings descriptor values
  _ -> case values of
    [value] ->
      matchNestedPatternM
        evaluator
        attributeResolver
        ignoreInactive
        bindings
        value
        patternExpression
    _ -> pure Nothing
 where
  recurse = matchSequencePatternElementsM evaluator attributeResolver ignoreInactive
  firstAlternative [] = pure Nothing
  firstAlternative (alternative : rest) = do
    matched <- recurse bindings alternative values
    case matched of
      Just _ -> pure matched
      Nothing -> firstAlternative rest
  validateValues updated _ [] = pure (Just updated)
  validateValues updated test (value : rest) = do
    result <- evaluator (Call test [value])
    if result == Just (Symbol "True")
      then validateValues updated test rest
      else pure Nothing

matchRepeatedPatternM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> PatternBindings
  -> Expr
  -> [Expr]
  -> monad (Maybe PatternBindings)
matchRepeatedPatternM evaluator attributeResolver ignoreInactive bindings (Call (Symbol repetitionHead) patternArguments) values =
  case patternArguments of
    [] -> pure Nothing
    itemPattern : _ -> case repetitionCountBounds repetitionHead patternArguments of
      Nothing -> pure Nothing
      Just (countMinimum, countMaximum)
        | countMinimum > countMaximum -> pure Nothing
        | otherwise ->
            matchFrom itemPattern countMinimum countMaximum values 0 bindings
 where
  matchFrom itemPattern countMinimum countMaximum remaining count current
    | null remaining =
        pure
          ( if count >= countMinimum && count <= countMaximum
              then Just current
              else Nothing
          )
    | count >= countMaximum = pure Nothing
    | otherwise = matchLengths (candidateLengths itemPattern remaining)
   where
    matchLengths [] = pure Nothing
    matchLengths (width : rest) = do
      let (segment, suffix) = splitAt width remaining
      matched <-
        matchSequencePatternElementsM
          evaluator
          attributeResolver
          ignoreInactive
          current
          itemPattern
          segment
      case matched of
        Nothing -> matchLengths rest
        Just updated -> do
          completed <-
            matchFrom
              itemPattern
              countMinimum
              countMaximum
              suffix
              (count + 1)
              updated
          case completed of
            Just _ -> pure completed
            Nothing -> matchLengths rest
  candidateLengths itemPattern remaining =
    let (itemMinimum, itemMaximum) = patternWidthBounds itemPattern
        concreteMinimum = max 1 itemMinimum
        concreteMaximum = min itemMaximum (length remaining)
     in if sequencePrefersLongest itemPattern
          then [concreteMaximum, concreteMaximum - 1 .. concreteMinimum]
          else [concreteMinimum .. concreteMaximum]
matchRepeatedPatternM _ _ _ _ _ _ = pure Nothing

matchOrderlessPatternSequenceM
  :: Monad monad
  => (Expr -> monad (Maybe Expr))
  -> (Expr -> monad (Set.Set SymbolAttribute))
  -> Bool
  -> PatternBindings
  -> [Expr]
  -> [[Expr]]
  -> monad (Maybe PatternBindings)
matchOrderlessPatternSequenceM _ _ _ _ _ [] = pure Nothing
matchOrderlessPatternSequenceM evaluator attributeResolver ignoreInactive bindings values (patterns : rest) = do
  matched <-
    matchPatternArgumentsM
      evaluator
      attributeResolver
      ignoreInactive
      bindings
      values
      patterns
  case matched of
    Just _ -> pure matched
    Nothing ->
      matchOrderlessPatternSequenceM
        evaluator
        attributeResolver
        ignoreInactive
        bindings
        values
        rest

isOptionExpression :: Expr -> Bool
isOptionExpression (Call (Symbol ruleHead) [key, _])
  | ruleHead `elem` ["Rule", "RuleDelayed"] = case key of
      Symbol {} -> True
      String {} -> True
      _ -> False
isOptionExpression (Call (Symbol "List") values) = all isOptionExpression values
isOptionExpression _ = False

bindScalar :: Text -> Expr -> PatternBindings -> Maybe PatternBindings
bindScalar name value bindings = case lookup name bindings of
  Nothing -> Just ((name, ScalarBinding value) : bindings)
  Just (ScalarBinding existing) | existing == value -> Just bindings
  _ -> Nothing

bindSequence :: Text -> [Expr] -> PatternBindings -> Maybe PatternBindings
bindSequence name values bindings = case lookup name bindings of
  Nothing -> Just ((name, SequenceBinding values) : bindings)
  Just (SequenceBinding existing) | existing == values -> Just bindings
  _ -> Nothing

substituteBindings :: PatternBindings -> Expr -> Expr
substituteBindings bindings expression = case expression of
  Symbol name -> case lookup name bindings of
    Just (ScalarBinding value) -> value
    Just (SequenceBinding values) -> Call (Symbol "Sequence") values
    Nothing -> expression
  Call expressionHead values ->
    Call
      (substituteBindings bindings expressionHead)
      (concatMap substituteArgument values)
  _ -> expression
 where
  substituteArgument (Symbol name) = case lookup name bindings of
    Just (ScalarBinding value) -> [value]
    Just (SequenceBinding values) -> values
    Nothing -> [Symbol name]
  substituteArgument value = [substituteBindings bindings value]

data LevelBounds = LevelBounds !Int !Int
  deriving (Eq, Show)

data PatternRecord = PatternRecord !Expr !Int !Int
  deriving (Eq, Show)

data PatternPathRecord = PatternPathRecord !Expr !Int !Int ![PathSelector]
  deriving (Eq, Show)

levelInfinity :: Int
levelInfinity = maxBound `div` 4

normalizeLevelSpec :: Expr -> Either EvaluationError LevelBounds
normalizeLevelSpec = \case
  Integer level
    | level >= 0 -> Right (LevelBounds (if level == 0 then 0 else 1) (integerLevel level))
    | otherwise -> Right (LevelBounds 1 (integerLevel level))
  Symbol "Infinity" -> Right (LevelBounds 1 levelInfinity)
  Call (Symbol "List") [bound] -> do
    value <- normalizeLevelBound bound
    Right (LevelBounds value value)
  Call (Symbol "List") [lower, upper] ->
    LevelBounds <$> normalizeLevelBound lower <*> normalizeLevelBound upper
  _ -> Left (EvaluationError "an unsupported level specification was provided")
 where
  integerLevel value
    | value > fromIntegral levelInfinity = levelInfinity
    | value < fromIntegral (negate levelInfinity) = negate levelInfinity
    | otherwise = fromIntegral value

normalizeLevelBound :: Expr -> Either EvaluationError Int
normalizeLevelBound (Integer value)
  | value > fromIntegral levelInfinity = Right levelInfinity
  | value < fromIntegral (negate levelInfinity) = Right (negate levelInfinity)
  | otherwise = Right (fromIntegral value)
normalizeLevelBound (Symbol "Infinity") = Right levelInfinity
normalizeLevelBound _ = Left (EvaluationError "an unsupported level bound was provided")

reduceLevel :: [Expr] -> Either EvaluationError Expr
reduceLevel arguments' = case map stripUnevaluated arguments' of
  [expression, specification] ->
    levelAtSpecification expression specification
  [expression, specification, Symbol "False"] ->
    levelAtSpecification expression specification
  [_, _, Symbol "True"] ->
    Left (EvaluationError "Level[..., ..., True] is not implemented yet")
  [_, _, _] ->
    Left (EvaluationError "the optional third Level argument must be True or False")
  _ ->
    Left
      ( EvaluationError
          "Level expects an expression, a level specification, and an optional heads flag"
      )
 where
  stripUnevaluated (Call (Symbol "Unevaluated") [value]) = value
  stripUnevaluated value = value

levelAtSpecification :: Expr -> Expr -> Either EvaluationError Expr
levelAtSpecification expression specification = do
  bounds <- normalizeLevelSpec specification
  Right
    ( normalizeEvaluatedCall
        (Symbol "List")
        [ value
        | PatternRecord value positive negative <-
            collectPatternRecords False 0 expression
        , levelMatches bounds positive negative
        ]
    )

levelMatches :: LevelBounds -> Int -> Int -> Bool
levelMatches (LevelBounds lower upper) positive negative
  | lower >= 0 && upper >= 0 = lower <= positive && positive <= upper
  | lower < 0 && upper < 0 = lower <= negative && negative <= upper
  | lower >= 0 && upper < 0 = positive >= lower && negative <= upper
  | otherwise = negative >= lower || positive <= upper

collectPatternRecords :: Bool -> Int -> Expr -> [PatternRecord]
collectPatternRecords includeHeads positive expression =
  children <> [PatternRecord expression positive (negate (expressionDepth expression))]
 where
  children
    | Just entries <- associationEntries expression =
        headRecords <> concatMap (collectPatternRecords includeHeads (positive + 1) . associationEntryValue) entries
    | Call expressionHead values <- expression =
        headRecordsFor expressionHead <> concatMap (collectPatternRecords includeHeads (positive + 1)) values
    | otherwise = []
  headRecords =
    if includeHeads
      then collectPatternRecords includeHeads (positive + 1) (Symbol "Association")
      else []
  headRecordsFor expressionHead =
    if includeHeads
      then collectPatternRecords includeHeads (positive + 1) expressionHead
      else []

collectPatternPathRecords :: Int -> [PathSelector] -> Expr -> [PatternPathRecord]
collectPatternPathRecords positive path expression =
  children <> [PatternPathRecord expression positive (negate (expressionDepth expression)) path]
 where
  children
    | Just entries <- associationEntries expression =
        concat
          [ collectPatternPathRecords
              (positive + 1)
              (path <> [KeySelector key])
              value
          | AssociationEntry _ key value <- entries
          ]
    | Call _ values <- expression =
        concat
          [ collectPatternPathRecords
              (positive + 1)
              (path <> [ArgumentSelector (fromIntegral index)])
              value
          | (index, value) <- zip [1 :: Int ..] values
          ]
    | otherwise = []

collectPositionPathRecords :: Bool -> Int -> [PathSelector] -> Expr -> [PatternPathRecord]
collectPositionPathRecords includeHeads positive path expression =
  children <> [PatternPathRecord expression positive (negate (expressionDepth expression)) path]
 where
  children
    | Just entries <- associationEntries expression =
        associationHeadRecords
          <> concat
            [ collectPositionPathRecords
                includeHeads
                (positive + 1)
                (path <> [KeySelector key])
                value
            | AssociationEntry _ key value <- entries
            ]
    | Call expressionHead values <- expression =
        callHeadRecords expressionHead
          <> concat
            [ collectPositionPathRecords
                includeHeads
                (positive + 1)
                (path <> [ArgumentSelector (fromIntegral index)])
                value
            | (index, value) <- zip [1 :: Int ..] values
            ]
    | otherwise = []
  associationHeadRecords =
    if includeHeads
      then collectPositionPathRecords includeHeads (positive + 1) (path <> [ArgumentSelector 0]) (Symbol "Association")
      else []
  callHeadRecords expressionHead =
    if includeHeads
      then collectPositionPathRecords includeHeads (positive + 1) (path <> [ArgumentSelector 0]) expressionHead
      else []

patternMatches :: Expr -> Expr -> Bool
patternMatches expression patternExpression =
  maybe False (const True) (matchPattern [] expression patternExpression)

matchingRecords :: LevelBounds -> Maybe Integer -> Expr -> [PatternRecord] -> [PatternRecord]
matchingRecords bounds limit patternExpression = go limit
 where
  go _ [] = []
  go (Just 0) _ = []
  go remaining (record@(PatternRecord expression positive negative) : rest)
    | levelMatches bounds positive negative
    , patternMatches expression patternExpression =
        record : go (subtractOne remaining) rest
    | otherwise = go remaining rest
  subtractOne Nothing = Nothing
  subtractOne (Just count) = Just (count - 1)

matchingPathRecords :: LevelBounds -> Maybe Integer -> Expr -> [PatternPathRecord] -> [PatternPathRecord]
matchingPathRecords bounds limit patternExpression = go limit
 where
  go _ [] = []
  go (Just 0) _ = []
  go remaining (record@(PatternPathRecord expression positive negative _) : rest)
    | levelMatches bounds positive negative
    , patternMatches expression patternExpression =
        record : go (subtractOne remaining) rest
    | otherwise = go remaining rest
  subtractOne Nothing = Nothing
  subtractOne (Just count) = Just (count - 1)

reduceFreeQ :: [Expr] -> Either EvaluationError Expr
reduceFreeQ = \case
  [expression, patternExpression] -> freeAtLevels expression patternExpression (Call (Symbol "List") [Integer 0, Symbol "Infinity"])
  [expression, patternExpression, specification] -> freeAtLevels expression patternExpression specification
  values -> Right (Call (Symbol "FreeQ") values)
 where
  freeAtLevels expression patternExpression specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds (Just 1) patternExpression (collectPatternRecords True 0 expression)
    pure (boolean (null matched))

reduceMemberQ :: [Expr] -> Either EvaluationError Expr
reduceMemberQ = \case
  [expression, patternExpression] -> memberAtLevels expression patternExpression (Call (Symbol "List") [Integer 1])
  [expression, patternExpression, specification] -> memberAtLevels expression patternExpression specification
  values -> Right (Call (Symbol "MemberQ") values)
 where
  memberAtLevels expression patternExpression specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds (Just 1) patternExpression (collectPatternRecords False 0 expression)
    pure (boolean (not (null matched)))

reduceCount :: [Expr] -> Either EvaluationError Expr
reduceCount = \case
  [expression, patternExpression] -> countAtLevels expression patternExpression (Call (Symbol "List") [Integer 1])
  [expression, patternExpression, specification] -> countAtLevels expression patternExpression specification
  values -> Right (Call (Symbol "Count") values)
 where
  countAtLevels expression patternExpression specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds Nothing patternExpression (collectPatternRecords False 0 expression)
    pure (Integer (fromIntegral (length matched)))

reduceCases :: [Expr] -> Either EvaluationError Expr
reduceCases = \case
  [expression, patternExpression] -> casesAtLevels expression patternExpression (Integer 1) Nothing
  [expression, patternExpression, specification] -> casesAtLevels expression patternExpression specification Nothing
  [expression, patternExpression, specification, limit] -> casesAtLevels expression patternExpression specification (Just limit)
  values -> Right (Call (Symbol "Cases") values)
 where
  casesAtLevels expression patternExpression specification limit = do
    bounds <- normalizeLevelSpec specification
    normalizedLimit <- selectionLimit "Cases" limit
    let (matchExpression, template) = case patternRule patternExpression of
          Just (PatternRule pattern' template') -> (pattern', Just template')
          Nothing -> (patternExpression, Nothing)
    results <- collectCases bounds normalizedLimit matchExpression template (collectPatternRecords False 0 expression)
    pure (evaluatedList results)
  collectCases _ _ _ _ [] = Right []
  collectCases _ (Just 0) _ _ _ = Right []
  collectCases bounds remaining patternExpression template (PatternRecord value positive negative : rest)
    | not (levelMatches bounds positive negative) =
        collectCases bounds remaining patternExpression template rest
    | otherwise = case matchPattern [] value patternExpression of
        Nothing -> collectCases bounds remaining patternExpression template rest
        Just bindings -> do
          transformed <- case template of
            Nothing -> Right (Just value)
            Just templateExpression -> instantiatePatternTemplate bindings templateExpression
          case transformed of
            Nothing -> collectCases bounds remaining patternExpression template rest
            Just result -> do
              following <- collectCases bounds (subtractOne remaining) patternExpression template rest
              pure (spliceCaseResult result <> following)
  subtractOne Nothing = Nothing
  subtractOne (Just count) = Just (count - 1)
  spliceCaseResult (Call (Symbol sequenceHead) values)
    | systemHeadIn ["Sequence"] sequenceHead = values
  spliceCaseResult value = [value]

reduceDeleteCases :: [Expr] -> Either EvaluationError Expr
reduceDeleteCases = \case
  [expression, patternExpression] -> deleteAtLevels expression patternExpression (Integer 1) Nothing
  [expression, patternExpression, specification] -> deleteAtLevels expression patternExpression specification Nothing
  [expression, patternExpression, specification, limit] -> deleteAtLevels expression patternExpression specification (Just limit)
  values -> Right (Call (Symbol "DeleteCases") values)
 where
  deleteAtLevels expression patternExpression specification limit = do
    bounds <- normalizeLevelSpec specification
    normalizedLimit <- selectionLimit "DeleteCases" limit
    let matched =
          matchingPathRecords
            bounds
            normalizedLimit
            patternExpression
            (collectPatternPathRecords 0 [] expression)
        paths = [path | PatternPathRecord _ _ _ path <- matched]
    if [] `elem` paths
      then Right (Call (Symbol "Sequence") [])
      else foldM deletePath expression (sortOperationPaths paths)
  deletePath expression path =
    maybe
      (Left (EvaluationError "DeleteCases encountered an invalid matched path"))
      Right
      (deleteAtPath path expression)

reduceFirstCase :: [Expr] -> Either EvaluationError Expr
reduceFirstCase = \case
  [expression, patternExpression] -> firstAtLevels expression patternExpression Nothing (Integer 1)
  [expression, patternExpression, defaultValue] -> firstAtLevels expression patternExpression (Just defaultValue) (Integer 1)
  [expression, patternExpression, defaultValue, specification] ->
    firstAtLevels expression patternExpression (Just defaultValue) specification
  values -> Right (Call (Symbol "FirstCase") values)
 where
  firstAtLevels expression patternExpression defaultValue specification = do
    bounds <- normalizeLevelSpec specification
    let matched =
          matchingRecords bounds (Just 1) patternExpression (collectPatternRecords False 0 expression)
    case matched of
      PatternRecord value _ _ : _ -> Right value
      [] -> Right (maybe (Call (Symbol "Missing") [String "NotFound"]) id defaultValue)

reducePosition :: [Expr] -> Either EvaluationError Expr
reducePosition values = case stripHeadsOption values of
  (includeHeads, [expression, patternExpression]) ->
    positionAtLevels includeHeads expression patternExpression (Call (Symbol "List") [Integer 0, Symbol "Infinity"]) Nothing
  (includeHeads, [expression, patternExpression, specification]) ->
    positionAtLevels includeHeads expression patternExpression specification Nothing
  (includeHeads, [expression, patternExpression, specification, limit]) ->
    positionAtLevels includeHeads expression patternExpression specification (Just limit)
  _ -> Left (EvaluationError "Position expects an expression, a pattern, and optional level and result limits")

positionAtLevels :: Bool -> Expr -> Expr -> Expr -> Maybe Expr -> Either EvaluationError Expr
positionAtLevels includeHeads expression patternExpression specification limit = do
  bounds <- normalizeLevelSpec specification
  normalizedLimit <- selectionLimit "Position" limit
  let matched =
        matchingPathRecords
          bounds
          normalizedLimit
          patternExpression
          (collectPositionPathRecords includeHeads 0 [] expression)
  pure
    ( list
        [ pathExpression path
        | PatternPathRecord _ _ _ path <- matched
        ]
    )

reduceFirstPosition :: [Expr] -> Either EvaluationError Expr
reduceFirstPosition = \case
  [expression, patternExpression] ->
    firstPositionAtLevels expression patternExpression Nothing (Call (Symbol "List") [Integer 0, Symbol "Infinity"])
  [expression, patternExpression, defaultValue] ->
    firstPositionAtLevels expression patternExpression (Just defaultValue) (Call (Symbol "List") [Integer 0, Symbol "Infinity"])
  [expression, patternExpression, defaultValue, specification] ->
    firstPositionAtLevels expression patternExpression (Just defaultValue) specification
  _ -> Left (EvaluationError "FirstPosition expects an expression, a pattern, and optional default and level specification")
 where
  firstPositionAtLevels expression patternExpression defaultValue specification = do
    positions <- positionAtLevels True expression patternExpression specification (Just (Integer 1))
    case positions of
      Call (Symbol "List") (firstPosition : _) -> Right firstPosition
      _ -> Right (maybe (Call (Symbol "Missing") [String "NotFound"]) id defaultValue)

reducePositionExtrema :: Bool -> [Expr] -> Either EvaluationError Expr
reducePositionExtrema largest [dataExpression] = do
  values <- listOrAssociationValues operation dataExpression
  pure (list (map Integer (extremePositions values)))
 where
  operation = if largest then "PositionLargest" else "PositionSmallest"
  desiredOrdering = if largest then GT else LT
  extremePositions :: [Expr] -> [Integer]
  extremePositions [] = []
  extremePositions (firstValue : remaining) = go 2 firstValue [1] remaining
  go _ _ retained [] = retained
  go index extreme retained (value : rest) = case canonicalCompare value extreme of
    ordering | ordering == desiredOrdering -> go (index + 1) value [index] rest
    EQ -> go (index + 1) extreme (retained <> [index]) rest
    _ -> go (index + 1) extreme retained rest
reducePositionExtrema largest _ =
  Left (EvaluationError (if largest then "PositionLargest expects exactly one argument" else "PositionSmallest expects exactly one argument"))

reducePositionIndex :: [Expr] -> Either EvaluationError Expr
reducePositionIndex [dataExpression] = do
  values <- listOrAssociationValues "PositionIndex" dataExpression
  pure (associationExpr (positionEntries values))
 where
  positionEntries values =
    [ AssociationEntry "Rule" key (list (map Integer positions))
    | (key, positions) <- foldl addPosition [] (zip [1 :: Integer ..] values)
    ]
  addPosition groups (position, value) = case matchingGroup value groups of
    Nothing -> groups <> [(value, [position])]
    Just index ->
      let (key, positions) = groups !! index
       in replaceListIndex index (key, positions <> [position]) groups
  matchingGroup value = go 0
   where
    go _ [] = Nothing
    go index ((key, _) : rest)
      | key == value = Just index
      | otherwise = go (index + 1) rest
reducePositionIndex _ = Left (EvaluationError "PositionIndex expects exactly one argument")

stripHeadsOption :: [Expr] -> (Bool, [Expr])
stripHeadsOption values = case reverse values of
  Call (Symbol ruleHead) [Symbol "Heads", Symbol value] : rest
    | ruleHead `elem` ["Rule", "RuleDelayed"]
    , value `elem` ["True", "False"] -> (value == "True", reverse rest)
  _ -> (True, values)

pathExpression :: [PathSelector] -> Expr
pathExpression = list . map selectorExpression
 where
  selectorExpression (ArgumentSelector position) = Integer position
  selectorExpression (KeySelector key) = Call (Symbol "Key") [key]

reduceRange :: [Expr] -> Expr
reduceRange values = case traverse integerValue values of
  Just [end] -> list (integerRange 1 end 1)
  Just [start, end] -> list (integerRange start end 1)
  Just [start, end, step] | step /= 0 -> list (integerRange start end step)
  _ -> Call (Symbol "Range") values
 where
  integerRange start end step
    | step > 0 && start <= end = map Integer [start, start + step .. end]
    | step < 0 && start >= end = map Integer [start, start + step .. end]
    | otherwise = []

reduceTotal :: [Expr] -> Expr
reduceTotal [Call (Symbol "List") values]
  | Just rows@(firstRow : _) <- traverse listArguments values
  , all ((== length firstRow) . length) rows =
      list (map reducePlus (transpose rows))
reduceTotal [Call (Symbol "List") values] = reducePlus values
reduceTotal [association]
  | Just entries <- associationEntries association =
      reducePlus [value | AssociationEntry _ _ value <- entries]
reduceTotal values = Call (Symbol "Total") values

reduceAccumulate :: [Expr] -> Expr
reduceAccumulate [association]
  | Just entries@(AssociationEntry _ _ firstValue : remaining) <- associationEntries association =
      let accumulatedValues =
            scanl
              (\accumulator (AssociationEntry _ _ value) -> reducePlus [accumulator, value])
              firstValue
              remaining
       in associationExpr
            ( zipWith
                (\(AssociationEntry ruleHead key _) value -> AssociationEntry ruleHead key value)
                entries
                accumulatedValues
            )
reduceAccumulate [Call (Symbol "List") values] =
  list (drop 1 (scanl (\acc value -> reducePlus [acc, value]) (Integer 0) values))
reduceAccumulate values = Call (Symbol "Accumulate") values

reduceAppendPrepend :: Bool -> Text -> [Expr] -> Expr
reduceAppendPrepend prepend _ [association, item]
  | Just entries <- associationEntries association
  , Just newEntry@(AssociationEntry _ newKey _) <- ruleEntry item =
      let retained = [entry | entry@(AssociationEntry _ key _) <- entries, key /= newKey]
       in associationExpr (if prepend then newEntry : retained else retained <> [newEntry])
reduceAppendPrepend prepend _ [Call expressionHead values, item] =
  Call expressionHead (if prepend then item : values else values <> [item])
reduceAppendPrepend _ headName values = Call (Symbol headName) values

reduceRotate :: Bool -> Text -> [Expr] -> Expr
reduceRotate left headName = \case
  [subject] -> rotate subject 1
  [subject, Integer amount] -> rotate subject amount
  values -> Call (Symbol headName) values
 where
  rotate (Call expressionHead arguments') amount
    | null arguments' = Call expressionHead []
    | otherwise =
        let count = length arguments'
            signed = if left then amount else negate amount
            offset = fromIntegral (signed `mod` fromIntegral count)
         in Call expressionHead (drop offset arguments' <> take offset arguments')
  rotate subject amount = Call (Symbol headName) [subject, Integer amount]

reduceDimensions :: [Expr] -> Either EvaluationError Expr
reduceDimensions [SparseArray dimensions _ _] =
  Right (evaluatedList (map Integer dimensions))
reduceDimensions [expression] =
  Right (evaluatedList (map (Integer . fromIntegral) (denseDimensions expression)))
reduceDimensions _ = Left (EvaluationError "Dimensions expects exactly one argument.")

-- Dimensions follows Wolfram's loose common-prefix rule.  Ragged children
-- stop the inferred shape at the first axis on which they disagree.
denseDimensions :: Expr -> [Int]
denseDimensions (Call (Symbol "List") []) = [0]
denseDimensions (Call (Symbol "List") values) =
  length values : commonDimensionPrefix (map denseDimensions values)
denseDimensions _ = []

commonDimensionPrefix :: [[Int]] -> [Int]
commonDimensionPrefix [] = []
commonDimensionPrefix (firstDimensions : remaining) =
  foldl' commonPrefix firstDimensions remaining
 where
  commonPrefix (left : leftRest) (right : rightRest)
    | left == right = left : commonPrefix leftRest rightRest
  commonPrefix _ _ = []

reduceArrayDepth :: [Expr] -> Either EvaluationError Expr
reduceArrayDepth [expression] = Right (Integer (fromIntegral (arrayDepthValue expression)))
reduceArrayDepth _ = Left (EvaluationError "ArrayDepth expects exactly one argument.")

arrayDepthValue :: Expr -> Int
arrayDepthValue (SparseArray dimensions _ _) = length dimensions
arrayDepthValue (Call (Symbol "List") []) = 1
arrayDepthValue (Call (Symbol "List") values) =
  1 + maximum (map arrayDepthValue values)
arrayDepthValue _ = 0

reduceArrayQ :: [Expr] -> Either EvaluationError Expr
reduceArrayQ = \case
  [expression] -> Right (boolean (arrayQValue expression Nothing Nothing))
  [expression, depthExpression] ->
    arrayQWithDepth expression depthExpression Nothing
  [expression, depthExpression, test] ->
    arrayQWithDepth expression depthExpression (Just test)
  _ ->
    Left
      ( EvaluationError
          "ArrayQ expects an expression, optional depth, and optional element test."
      )

arrayQWithDepth :: Expr -> Expr -> Maybe Expr -> Either EvaluationError Expr
arrayQWithDepth expression depthExpression test =
  case arrayRank expression of
    Nothing -> Right (Symbol "False")
    Just _ -> do
      depth <- requireArrayQDepth depthExpression
      Right (boolean (arrayQValue expression (Just depth) test))

arrayRank :: Expr -> Maybe Int
arrayRank (SparseArray dimensions _ _)
  | null dimensions = Nothing
  | otherwise = Just (length dimensions)
arrayRank expression = case strictDenseDimensions expression of
  Right dimensions
    | not (null dimensions) -> Just (length dimensions)
  _ -> Nothing

requireArrayQDepth :: Expr -> Either EvaluationError Integer
requireArrayQDepth (Integer depth) = Right depth
requireArrayQDepth _ =
  Left (EvaluationError "ArrayQ currently expects an explicit integer depth.")

arrayQValue :: Expr -> Maybe Integer -> Maybe Expr -> Bool
arrayQValue expression requestedDepth test = case expression of
  SparseArray dimensions entries fill ->
    not (null dimensions)
      && depthMatches (length dimensions)
      && sparseValuesPass dimensions entries fill
  _ -> case strictDenseDimensions expression of
    Left _ -> False
    Right dimensions ->
      not (null dimensions)
        && depthMatches (length dimensions)
        && maybe True (allPredicateTrue (denseLeafValues expression)) test
 where
  depthMatches actual =
    maybe True (== fromIntegral actual) requestedDepth
  sparseValuesPass dimensions entries fill = case test of
    Nothing -> True
    Just predicate ->
      let explicitValues = [value | SparseEntry _ value <- entries]
          hasImplicit = product dimensions > fromIntegral (length entries)
       in (not hasImplicit || predicateReturnsTrue predicate fill)
            && allPredicateTrue explicitValues predicate

reduceVectorQ :: [Expr] -> Either EvaluationError Expr
reduceVectorQ = \case
  [expression] -> Right (boolean (vectorQValue expression Nothing))
  [expression, test] -> Right (boolean (vectorQValue expression (Just test)))
  _ ->
    Left
      ( EvaluationError
          "VectorQ expects an expression and an optional element predicate."
      )

vectorQValue :: Expr -> Maybe Expr -> Bool
vectorQValue expression test = case expression of
  SparseArray dimensions entries fill ->
    length dimensions == 1
      && sparseElementsPass dimensions entries fill test
  Call (Symbol "List") values ->
    all (not . hasHead "List") values
      && maybe True (allPredicateTrue values) test
  _ -> False

reduceMatrixQ :: [Expr] -> Either EvaluationError Expr
reduceMatrixQ = \case
  [expression] -> Right (boolean (matrixQValue expression Nothing))
  [expression, test] -> Right (boolean (matrixQValue expression (Just test)))
  _ ->
    Left
      ( EvaluationError
          "MatrixQ expects an expression and an optional element predicate."
      )

matrixQValue :: Expr -> Maybe Expr -> Bool
matrixQValue expression test = case expression of
  SparseArray dimensions entries fill ->
    length dimensions == 2
      && sparseElementsPass dimensions entries fill test
  _ -> case strictDenseDimensions expression of
    Left _ -> False
    Right dimensions ->
      length dimensions == 2
        && maybe True (allPredicateTrue (denseLeafValues expression)) test

sparseElementsPass
  :: [Integer]
  -> [SparseEntry]
  -> Expr
  -> Maybe Expr
  -> Bool
sparseElementsPass _ _ _ Nothing = True
sparseElementsPass dimensions entries fill (Just predicate) =
  let explicitValues = [value | SparseEntry _ value <- entries]
      hasImplicit = product dimensions > fromIntegral (length entries)
   in (not hasImplicit || predicateReturnsTrue predicate fill)
        && allPredicateTrue explicitValues predicate

allPredicateTrue :: [Expr] -> Expr -> Bool
allPredicateTrue values predicate =
  all (predicateReturnsTrue predicate) values

predicateReturnsTrue :: Expr -> Expr -> Bool
predicateReturnsTrue predicate value =
  evaluate (Call predicate [value]) == Right (Symbol "True")

-- Unlike Dimensions, transformations require a genuinely rectangular List
-- tree.  An atom has rank zero; callers decide whether rank zero is valid.
strictDenseDimensions :: Expr -> Either EvaluationError [Int]
strictDenseDimensions (Call (Symbol "List") []) = Right [0]
strictDenseDimensions (Call (Symbol "List") values) = do
  childDimensions <- traverse strictDenseDimensions values
  case childDimensions of
    [] -> Right [0]
    firstDimensions : remaining
      | all (== firstDimensions) remaining ->
          Right (length values : firstDimensions)
      | otherwise ->
          Left (EvaluationError "SparseArray dense input must be rectangular.")
strictDenseDimensions _ = Right []

requireDenseArrayDimensions :: Text -> Expr -> Either EvaluationError [Int]
requireDenseArrayDimensions operation expression = case expression of
  SparseArray {} ->
    Left (EvaluationError (operation <> " currently supports dense List arrays only."))
  _ -> do
    dimensions <- strictDenseDimensions expression
    if null dimensions
      then Left (EvaluationError (operation <> " expects a rectangular array."))
      else Right dimensions

normalizeDenseDimensions :: Text -> Expr -> Either EvaluationError [Int]
normalizeDenseDimensions operation = \case
  Integer dimension -> pure <$> nonnegativeDimension operation dimension
  Call (Symbol "List") dimensions ->
    traverse normalizeOne dimensions
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects an integer dimension or a list of dimensions.")
      )
 where
  normalizeOne (Integer dimension) = nonnegativeDimension operation dimension
  normalizeOne _ = Left (EvaluationError (operation <> " expects an integer argument."))

nonnegativeDimension :: Text -> Integer -> Either EvaluationError Int
nonnegativeDimension operation dimension
  | dimension < 0 =
      Left (EvaluationError (operation <> " expects non-negative dimensions."))
  | dimension > toInteger (maxBound :: Int) =
      Left (EvaluationError (operation <> " dimension is too large for this runtime."))
  | otherwise = Right (fromInteger dimension)

maximumDenseArrayMaterializedNodes :: Integer
maximumDenseArrayMaterializedNodes = 1000000

guardDenseArrayMaterialization :: Text -> [Int] -> Either EvaluationError ()
guardDenseArrayMaterialization operation dimensions =
  if denseArrayMaterializedNodes dimensions <= maximumDenseArrayMaterializedNodes
    then Right ()
    else
      Left
        ( EvaluationError
            (operation <> " output exceeds the native materialization limit.")
        )

-- Count every materialized element at every rank, rather than only the leaf
-- product.  Shapes such as {1000001, 0} still allocate one million empty
-- child lists even though their leaf count is zero.
denseArrayMaterializedNodes :: [Int] -> Integer
denseArrayMaterializedNodes = go 1 0
 where
  go _ total [] = total
  go prefix total (dimension : remaining) =
    let nextPrefix = prefix * fromIntegral dimension
        nextTotal = total + nextPrefix
     in if nextTotal > maximumDenseArrayMaterializedNodes
          then nextTotal
          else go nextPrefix nextTotal remaining

buildDenseArrayM
  :: Text
  -> [Int]
  -> ([Int] -> Either EvaluationError Expr)
  -> Either EvaluationError Expr
buildDenseArrayM operation dimensions builder = do
  guardDenseArrayMaterialization operation dimensions
  build [] dimensions
 where
  build reversedIndices [] = builder (reverse reversedIndices)
  build reversedIndices (dimension : remaining) =
    evaluatedList
      <$> traverse
        (\index -> build (index : reversedIndices) remaining)
        [0 .. dimension - 1]

denseArrayValueAt :: Expr -> [Int] -> Either EvaluationError Expr
denseArrayValueAt = foldM select
 where
  select (Call (Symbol "List") values) index
    | index >= 0
    , index < length values = Right (values !! index)
  select _ _ = Left (EvaluationError "Expected a rectangular List array.")

denseLeafValues :: Expr -> [Expr]
denseLeafValues (Call (Symbol "List") values) = concatMap denseLeafValues values
denseLeafValues expression = [expression]

isSparseArray :: Expr -> Bool
isSparseArray SparseArray {} = True
isSparseArray _ = False

normalizeSparseDimensions :: Expr -> Either EvaluationError [Integer]
normalizeSparseDimensions = normalizeArbitraryDimensions "SparseArray"

normalizeArbitraryDimensions
  :: Text
  -> Expr
  -> Either EvaluationError [Integer]
normalizeArbitraryDimensions operation = \case
  Integer dimension -> pure <$> normalizeOne dimension
  Call (Symbol listHead) dimensions
    | systemHeadIn ["List"] listHead -> traverse requireInteger dimensions
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects an integer dimension or a list of dimensions.")
      )
 where
  requireInteger (Integer dimension) = normalizeOne dimension
  requireInteger _ =
    Left (EvaluationError (operation <> " expects an integer argument."))
  normalizeOne dimension
    | dimension < 0 =
        Left (EvaluationError (operation <> " expects non-negative dimensions."))
    | otherwise = Right dimension

canonicalSparseArray
  :: [Integer]
  -> [([Integer], Expr)]
  -> Expr
  -> Either EvaluationError Expr
canonicalSparseArray dimensions pairs fill
  | null dimensions =
      Left (EvaluationError "SparseArray expects at least one dimension.")
  | any (< 0) dimensions =
      Left (EvaluationError "SparseArray dimensions must be non-negative.")
  | otherwise = do
      retained <- retainFirst Set.empty [] pairs
      Right
        ( SparseArray
            dimensions
            [SparseEntry indices value | (indices, value) <- sortBy comparePair retained]
            fill
        )
 where
  comparePair (left, _) (right, _) = compare left right
  retainFirst _ retained [] = Right (reverse retained)
  retainFirst seen retained ((indices, value) : remaining)
    | length indices /= length dimensions =
        Left
          ( EvaluationError
              "SparseArray rule positions must match the array rank."
          )
    | or (zipWith (\index dimension -> index < 1 || index > dimension) indices dimensions) =
        Left
          ( EvaluationError
              "SparseArray rule positions must be inside the array dimensions."
          )
    | Set.member indices seen = retainFirst seen retained remaining
    | value == fill = retainFirst (Set.insert indices seen) retained remaining
    | otherwise =
        retainFirst
          (Set.insert indices seen)
          ((indices, value) : retained)
          remaining

reduceSparseArray :: [Expr] -> Either EvaluationError Expr
reduceSparseArray = \case
  [dataExpression] ->
    constructSparseArray dataExpression Nothing (Integer 0)
  [dataExpression, dimensionsExpression] -> do
    dimensions <- normalizeSparseDimensions dimensionsExpression
    constructSparseArray dataExpression (Just dimensions) (Integer 0)
  [dataExpression, dimensionsExpression, fill] -> do
    dimensions <- normalizeSparseDimensions dimensionsExpression
    constructSparseArray dataExpression (Just dimensions) fill
  _ ->
    Left
      ( EvaluationError
          "SparseArray expects data, optional dimensions, and an optional implicit value."
      )

constructSparseArray
  :: Expr
  -> Maybe [Integer]
  -> Expr
  -> Either EvaluationError Expr
constructSparseArray dataExpression requestedDimensions fill = case dataExpression of
  sparse@(SparseArray dimensions _ originalFill)
    | maybe False (/= dimensions) requestedDimensions ->
        Left
          ( EvaluationError
              "SparseArray cannot reinterpret an existing sparse array with different dimensions."
          )
    | fill == originalFill -> Right sparse
    | otherwise -> do
        dense <- sparseArrayNormal sparse
        pairs <- denseSparsePairs dense dimensions fill
        canonicalSparseArray dimensions pairs fill
  Symbol automaticName
    | systemHeadIn ["Automatic"] automaticName
    , Just dimensions <- requestedDimensions ->
        canonicalSparseArray dimensions [] fill
  _ -> case sparseRuleExpressions dataExpression of
    Just ruleExpressions -> do
      let rankHint = length <$> requestedDimensions
      pairs <- concat <$> traverse (sparseRulePairs rankHint) ruleExpressions
      dimensions <- case requestedDimensions of
        Just explicitDimensions -> Right explicitDimensions
        Nothing -> inferSparseDimensions pairs
      canonicalSparseArray dimensions pairs fill
    Nothing -> do
      inferredDenseDimensions <- strictDenseDimensions dataExpression
      if null inferredDenseDimensions
        then
          Left
            ( EvaluationError
                "SparseArray expects a rule specification or a rectangular dense list."
            )
        else do
          let inferredDimensions = map fromIntegral inferredDenseDimensions
              finalDimensions = maybe inferredDimensions id requestedDimensions
          if finalDimensions /= inferredDimensions
            then
              Left
                ( EvaluationError
                    "SparseArray dense input dimensions do not match the explicit dimensions."
                )
            else do
              pairs <- denseSparsePairs dataExpression finalDimensions fill
              canonicalSparseArray finalDimensions pairs fill

sparseRuleExpressions :: Expr -> Maybe [Expr]
sparseRuleExpressions expression
  | Just _ <- ruleEntry expression = Just [expression]
sparseRuleExpressions (Call (Symbol listHead) values)
  | systemHeadIn ["List"] listHead
  , all (maybe False (const True) . ruleEntry) values = Just values
sparseRuleExpressions _ = Nothing

sparseRulePairs
  :: Maybe Int
  -> Expr
  -> Either EvaluationError [([Integer], Expr)]
sparseRulePairs rankHint rule = case ruleEntry rule of
  Nothing ->
    Left (EvaluationError "SparseArray expects rules or a dense list.")
  Just (AssociationEntry _ position value) ->
    case sparsePositionSequence rankHint position value of
      Left message -> Left message
      Right (Just pairs) -> Right pairs
      Right Nothing -> case sparsePosition rankHint position of
        Just indices -> Right [(indices, value)]
        Nothing ->
          Left
            ( EvaluationError
                "SparseArray currently supports explicit integer positions, not patterns or Band."
            )

sparsePosition :: Maybe Int -> Expr -> Maybe [Integer]
sparsePosition rankHint (Integer position)
  | rankHint `elem` [Nothing, Just 1] = Just [position]
sparsePosition rankHint (Call (Symbol listHead) values)
  | systemHeadIn ["List"] listHead
  , Just indices <- traverse explicitInteger values
  , maybe True (== length indices) rankHint = Just indices
 where
  explicitInteger (Integer value) = Just value
  explicitInteger _ = Nothing
sparsePosition _ _ = Nothing

sparsePositionSequence
  :: Maybe Int
  -> Expr
  -> Expr
  -> Either EvaluationError (Maybe [([Integer], Expr)])
sparsePositionSequence rankHint positions values = case (positions, values) of
  (Call (Symbol positionsHead) positionValues, Call (Symbol valuesHead) entryValues)
    | systemHeadIn ["List"] positionsHead
    , systemHeadIn ["List"] valuesHead ->
        if length positionValues /= length entryValues
          then
            Left
              ( EvaluationError
                  "SparseArray position and value lists must have the same length."
              )
          else case traverse explicitInteger positionValues of
            Just indices
              | rankHint `elem` [Nothing, Just 1] ->
                  Right
                    ( Just
                        (zipWith (\index value -> ([index], value)) indices entryValues)
                    )
            _ ->
              Right
                ( zipWith (,)
                    <$> traverse (sparsePosition rankHint) positionValues
                    <*> pure entryValues
                )
  _ -> Right Nothing
 where
  explicitInteger (Integer value) = Just value
  explicitInteger _ = Nothing

inferSparseDimensions
  :: [([Integer], Expr)]
  -> Either EvaluationError [Integer]
inferSparseDimensions [] =
  Left
    ( EvaluationError
        "SparseArray dimensions cannot be inferred from an empty rule set."
    )
inferSparseDimensions pairs@((firstIndices, _) : _)
  | null firstIndices
      || any ((/= length firstIndices) . length . fst) pairs =
      Left
        ( EvaluationError
            "SparseArray rule positions must have a consistent rank."
        )
  | otherwise =
      Right
        [ maximum [indices !! axis | (indices, _) <- pairs]
        | axis <- [0 .. length firstIndices - 1]
        ]

denseSparsePairs
  :: Expr
  -> [Integer]
  -> Expr
  -> Either EvaluationError [([Integer], Expr)]
denseSparsePairs expression dimensions fill = go [] expression dimensions
 where
  go reversedIndices value [] =
    Right
      ( if value == fill
          then []
          else [(reverse reversedIndices, value)]
      )
  go reversedIndices (Call (Symbol listHead) values) (dimension : remaining)
    | systemHeadIn ["List"] listHead
    , toInteger (length values) == dimension =
        concat
          <$> sequence
            [ go (index : reversedIndices) value remaining
            | (index, value) <- zip [1 ..] values
            ]
  go _ _ _ =
    Left
      ( EvaluationError
          "SparseArray dense input must match the requested dimensions."
      )

sparseArrayNormal :: Expr -> Either EvaluationError Expr
sparseArrayNormal (SparseArray dimensions entries fill) = do
  guardSparseMaterialization "Normal" dimensions
  let entryMap = Map.fromList [(indices, value) | SparseEntry indices value <- entries]
  build entryMap [] dimensions
 where
  build entryMap reversedIndices [] =
    Right (Map.findWithDefault fill (reverse reversedIndices) entryMap)
  build entryMap reversedIndices (dimension : remaining) =
    evaluatedList
      <$> traverse
        (\index -> build entryMap (index : reversedIndices) remaining)
        [1 .. dimension]
sparseArrayNormal _ =
  Left (EvaluationError "Normal currently expects a SparseArray value.")

guardSparseMaterialization
  :: Text
  -> [Integer]
  -> Either EvaluationError ()
guardSparseMaterialization operation dimensions =
  if sparseMaterializedNodes dimensions <= maximumDenseArrayMaterializedNodes
    then Right ()
    else
      Left
        ( EvaluationError
            (operation <> " output exceeds the native materialization limit.")
        )

sparseMaterializedNodes :: [Integer] -> Integer
sparseMaterializedNodes = go 1 0
 where
  go _ total [] = total
  go prefix total (dimension : remaining) =
    let nextPrefix = prefix * dimension
        nextTotal = total + nextPrefix
     in if nextTotal > maximumDenseArrayMaterializedNodes
          then nextTotal
          else go nextPrefix nextTotal remaining

reduceArrayRules :: [Expr] -> Either EvaluationError Expr
reduceArrayRules [SparseArray dimensions entries fill] =
  Right
    ( evaluatedList
        ( [ Call
              (Symbol "Rule")
              [evaluatedList (map Integer indices), value]
          | SparseEntry indices value <- entries
          ]
            <> [ Call
                   (Symbol "Rule")
                   [ evaluatedList
                       [Call (Symbol "Blank") [] | _ <- dimensions]
                   , fill
                   ]
               ]
        )
    )
reduceArrayRules [_] =
  Left (EvaluationError "ArrayRules currently expects a SparseArray.")
reduceArrayRules _ =
  Left (EvaluationError "ArrayRules expects exactly one argument.")

reduceSparseArrayProperty
  :: Expr
  -> [Expr]
  -> Either EvaluationError Expr
reduceSparseArrayProperty sparse@(SparseArray dimensions entries fill) = \case
  [String propertyName] -> case propertyName of
    "ImplicitValue" -> Right fill
    "ExplicitLength" -> Right (Integer (fromIntegral (length entries)))
    "ExplicitValues" ->
      Right (evaluatedList [value | SparseEntry _ value <- entries])
    "ExplicitPositions" ->
      Right
        ( evaluatedList
            [evaluatedList (map Integer indices) | SparseEntry indices _ <- entries]
        )
    "Density" ->
      let totalSize = product dimensions
          explicitCount = fromIntegral (length entries)
       in Right
            ( if totalSize == 0 || explicitCount == 0
                then Integer 0
                else fromExact (normalizeExact explicitCount totalSize)
            )
    _ ->
      Left
        ( EvaluationError
            ("Unsupported SparseArray property: " <> propertyName <> ".")
        )
  [_] ->
    Left
      ( EvaluationError
          "SparseArray properties must be requested by string name."
      )
  values -> Right (Call sparse values)
reduceSparseArrayProperty sparse = \values -> Right (Call sparse values)

reduceArray :: [Expr] -> Either EvaluationError Expr
reduceArray = \case
  [function, dimensionsExpression] ->
    buildArray function dimensionsExpression Nothing
  [function, dimensionsExpression, originExpression] ->
    buildArray function dimensionsExpression (Just originExpression)
  _ -> Left (EvaluationError "Array expects two or three arguments.")

buildArray :: Expr -> Expr -> Maybe Expr -> Either EvaluationError Expr
buildArray function dimensionsExpression originExpression = do
  dimensions <- normalizeDenseDimensions "Array" dimensionsExpression
  origins <- normalizeArrayOrigins (length dimensions) originExpression
  buildDenseArrayM "Array" dimensions $ \indices ->
    evaluate
      ( Call
          function
          [ Integer (origin + fromIntegral index)
          | (origin, index) <- zip origins indices
          ]
      )

normalizeArrayOrigins
  :: Int
  -> Maybe Expr
  -> Either EvaluationError [Integer]
normalizeArrayOrigins rank Nothing = Right (replicate rank 1)
normalizeArrayOrigins rank (Just (Integer origin)) =
  Right (replicate rank origin)
normalizeArrayOrigins 1 (Just (Call (Symbol "List") [Integer lower, Integer _upper])) =
  Right [lower]
normalizeArrayOrigins rank (Just (Call (Symbol "List") values))
  | length values /= rank =
      Left
        ( EvaluationError
            "Array origin list must have one entry per array dimension."
        )
  | otherwise =
      traverse requireOrigin values
 where
  requireOrigin (Integer origin) = Right origin
  requireOrigin _ =
    Left (EvaluationError "Array origin entries must be explicit integers.")
normalizeArrayOrigins _ (Just _) =
  Left
    ( EvaluationError
        "Array currently expects an integer origin or a list of integer origins."
    )

reduceConstantArray :: [Expr] -> Either EvaluationError Expr
reduceConstantArray [value, dimensionsExpression] = do
  dimensions <- normalizeDenseDimensions "ConstantArray" dimensionsExpression
  buildDenseArrayM "ConstantArray" dimensions (const (Right value))
reduceConstantArray _ =
  Left (EvaluationError "ConstantArray currently supports exactly two arguments.")

reduceArrayReshape :: [Expr] -> Either EvaluationError Expr
reduceArrayReshape [expression, dimensionsExpression] =
  arrayReshape expression dimensionsExpression (Integer 0)
reduceArrayReshape [expression, dimensionsExpression, padding] =
  arrayReshape expression dimensionsExpression padding
reduceArrayReshape _ =
  Left
    ( EvaluationError
        "ArrayReshape expects an expression, dimensions, and an optional padding value."
    )

arrayReshape :: Expr -> Expr -> Expr -> Either EvaluationError Expr
arrayReshape sparse@SparseArray {} dimensionsExpression padding = do
  dimensions <-
    normalizeArbitraryDimensions "ArrayReshape" dimensionsExpression
  sparseArrayReshape sparse dimensions dimensionsExpression padding
arrayReshape expression dimensionsExpression padding = do
  dimensions <- normalizeDenseDimensions "ArrayReshape" dimensionsExpression
  guardDenseArrayMaterialization "ArrayReshape" dimensions
  let (result, _) = buildReshaped dimensions (denseLeafValues expression)
  Right result
 where
  buildReshaped [] (value : remaining) = (value, remaining)
  buildReshaped [] [] = (padding, [])
  buildReshaped (dimension : remainingDimensions) available =
    let (children, leftover) = buildChildren dimension available []
     in (evaluatedList (reverse children), leftover)
   where
    buildChildren 0 rest built = (built, rest)
    buildChildren count rest built =
      let (child, next) = buildReshaped remainingDimensions rest
       in buildChildren (count - 1) next (child : built)

sparseArrayReshape
  :: Expr
  -> [Integer]
  -> Expr
  -> Expr
  -> Either EvaluationError Expr
sparseArrayReshape sparse@(SparseArray oldDimensions entries oldFill) dimensions dimensionsExpression padding
  | null dimensions =
      if oldTotal == 0
        then Right padding
        else
          Right
            ( sparseValueAt
                entries
                oldFill
                (replicate (length oldDimensions) 1)
            )
  | newTotal > oldTotal
  , oldFill /= padding = do
      dense <- sparseArrayNormal sparse
      arrayReshape dense dimensionsExpression padding
  | otherwise = do
      pairs <-
        traverse
          ( \(SparseEntry indices value) ->
              let linear = sparseLinearIndex indices oldDimensions
               in Right (sparseIndicesFromLinear linear dimensions, value)
          )
          [ entry
          | entry@(SparseEntry indices _) <- entries
          , sparseLinearIndex indices oldDimensions < newTotal
          ]
      canonicalSparseArray dimensions pairs outputFill
 where
  oldTotal = product oldDimensions
  newTotal = product dimensions
  outputFill
    | newTotal <= oldTotal = oldFill
    | otherwise = padding
sparseArrayReshape _ _ _ _ =
  Left (EvaluationError "ArrayReshape currently expects an array.")

sparseLinearIndex :: [Integer] -> [Integer] -> Integer
sparseLinearIndex indices dimensions =
  foldl'
    (\linear (index, dimension) -> linear * dimension + index - 1)
    0
    (zip indices dimensions)

sparseIndicesFromLinear :: Integer -> [Integer] -> [Integer]
sparseIndicesFromLinear linear dimensions =
  snd (foldl' select (linear, []) (reverse dimensions))
 where
  select (remaining, indices) dimension =
    let (next, offset) = remaining `divMod` dimension
     in (next, offset + 1 : indices)

normalizeArrayPadding
  :: Int
  -> Expr
  -> Either EvaluationError [(Int, Int)]
normalizeArrayPadding rank = \case
  Integer width -> do
    normalized <- paddingWidth width
    Right (replicate rank (normalized, normalized))
  Call (Symbol "List") [Integer left, Integer right]
    | rank == 1 -> do
        normalizedLeft <- paddingWidth left
        normalizedRight <- paddingWidth right
        Right [(normalizedLeft, normalizedRight)]
  Call (Symbol "List") widths
    | length widths == rank
    , Just integerWidths <- traverse explicitInteger widths -> do
        normalized <- traverse paddingWidth integerWidths
        Right [(width, width) | width <- normalized]
  Call (Symbol "List") widths
    | length widths == rank -> traverse paddingPair widths
  _ -> Left invalidShape
 where
  explicitInteger (Integer value) = Just value
  explicitInteger _ = Nothing
  paddingWidth value
    | value < 0 =
        Left (EvaluationError "ArrayPad expects non-negative padding widths.")
    | value > toInteger (maxBound :: Int) =
        Left (EvaluationError "ArrayPad padding width is too large for this runtime.")
    | otherwise = Right (fromInteger value)
  paddingPair (Call (Symbol "List") [Integer left, Integer right]) =
    (,) <$> paddingWidth left <*> paddingWidth right
  paddingPair (Call (Symbol "List") [_, _]) =
    Left (EvaluationError "ArrayPad padding widths must be explicit integers.")
  paddingPair _ = Left invalidShape
  invalidShape =
    EvaluationError
      "ArrayPad expects padding widths as p, {p1, ...}, or {{l1, r1}, ...}."

reduceArrayPad :: [Expr] -> Either EvaluationError Expr
reduceArrayPad [expression, paddingExpression] =
  arrayPad expression paddingExpression (Integer 0)
reduceArrayPad [expression, paddingExpression, padding] =
  arrayPad expression paddingExpression padding
reduceArrayPad _ =
  Left
    ( EvaluationError
        "ArrayPad expects an array, padding widths, and an optional padding value."
    )

arrayPad :: Expr -> Expr -> Expr -> Either EvaluationError Expr
arrayPad sparse@(SparseArray dimensions entries sourceFill) paddingExpression padding = do
  widths <- normalizeSparseArrayPadding (length dimensions) paddingExpression
  let newDimensions =
        zipWith
          (\dimension (left, right) -> dimension + left + right)
          dimensions
          widths
  if padding == sourceFill
    then
      canonicalSparseArray
        newDimensions
        [ ( zipWith
              (\index (left, _) -> index + left)
              indices
              widths
          , value
          )
        | SparseEntry indices value <- entries
        ]
        sourceFill
    else do
      dense <- sparseArrayNormal sparse
      arrayPad dense paddingExpression padding
arrayPad expression paddingExpression padding = do
  dimensions <- requireDenseArrayDimensions "ArrayPad" expression
  widths <- normalizeArrayPadding (length dimensions) paddingExpression
  newDimensions <- sequence (zipWith paddedDimension dimensions widths)
  buildDenseArrayM "ArrayPad" newDimensions $ \indices -> do
    let sourceCoordinates = zipWith3 sourceCoordinate indices dimensions widths
    case sequence sourceCoordinates of
      Nothing -> Right padding
      Just sourceIndices -> denseArrayValueAt expression sourceIndices
 where
  paddedDimension dimension (left, right)
    | left > maxBound - dimension || right > maxBound - dimension - left =
        Left (EvaluationError "ArrayPad dimensions are too large for this runtime.")
    | otherwise = Right (dimension + left + right)
  sourceCoordinate index dimension (left, _)
    | index < left = Nothing
    | index - left >= dimension = Nothing
    | otherwise = Just (index - left)

normalizeSparseArrayPadding
  :: Int
  -> Expr
  -> Either EvaluationError [(Integer, Integer)]
normalizeSparseArrayPadding rank = \case
  Integer width -> do
    normalized <- paddingWidth width
    Right (replicate rank (normalized, normalized))
  Call (Symbol listHead) [Integer left, Integer right]
    | systemHeadIn ["List"] listHead
    , rank == 1 -> do
        normalizedLeft <- paddingWidth left
        normalizedRight <- paddingWidth right
        Right [(normalizedLeft, normalizedRight)]
  Call (Symbol listHead) widths
    | systemHeadIn ["List"] listHead
    , length widths == rank
    , Just integerWidths <- traverse explicitInteger widths -> do
        normalized <- traverse paddingWidth integerWidths
        Right [(width, width) | width <- normalized]
  Call (Symbol listHead) widths
    | systemHeadIn ["List"] listHead
    , length widths == rank -> traverse paddingPair widths
  _ -> Left invalidShape
 where
  explicitInteger (Integer value) = Just value
  explicitInteger _ = Nothing
  paddingWidth value
    | value < 0 =
        Left (EvaluationError "ArrayPad expects non-negative padding widths.")
    | otherwise = Right value
  paddingPair (Call (Symbol listHead) [Integer left, Integer right])
    | systemHeadIn ["List"] listHead =
        (,) <$> paddingWidth left <*> paddingWidth right
  paddingPair (Call (Symbol listHead) [_, _])
    | systemHeadIn ["List"] listHead =
        Left (EvaluationError "ArrayPad padding widths must be explicit integers.")
  paddingPair _ = Left invalidShape
  invalidShape =
    EvaluationError
      "ArrayPad expects padding widths as p, {p1, ...}, or {{l1, r1}, ...}."

reduceArrayFlatten :: [Expr] -> Either EvaluationError Expr
reduceArrayFlatten [expression] = arrayFlatten expression
reduceArrayFlatten _ =
  Left (EvaluationError "ArrayFlatten expects exactly one argument.")

arrayFlatten :: Expr -> Either EvaluationError Expr
arrayFlatten (Call (Symbol "List") []) = Right (evaluatedList [])
arrayFlatten (Call (Symbol "List") rowExpressions)
  | any rowContainsSparse rowExpressions =
      arrayFlattenSparseBlocks rowExpressions
 where
  rowContainsSparse (Call (Symbol listHead) blocks)
    | systemHeadIn ["List"] listHead = any isSparseArray blocks
  rowContainsSparse _ = False
arrayFlatten (Call (Symbol "List") rowExpressions) = do
  blockRows <- traverse requireBlockRow rowExpressions
  let columnCount = case blockRows of
        firstRow : _ -> length firstRow
        [] -> 0
  if columnCount == 0 || any ((/= columnCount) . length) blockRows
    then Left (EvaluationError "ArrayFlatten expects a rectangular block matrix.")
    else do
      shapeRows <- traverse (traverse blockShape) blockRows
      rowHeights <- traverse consistentRowHeight (zip [1 :: Int ..] shapeRows)
      columnWidths <-
        traverse
          (consistentColumnWidth shapeRows)
          [0 .. columnCount - 1]
      outputHeight <- checkedDimensionSum "ArrayFlatten" rowHeights
      outputWidth <- checkedDimensionSum "ArrayFlatten" columnWidths
      guardDenseArrayMaterialization "ArrayFlatten" [outputHeight, outputWidth]
      let outputRows =
            concat
              [ [ evaluatedList
                    ( concat
                        [ blockMatrixRows block !! localRow
                        | block <- blockRow
                        ]
                    )
                | localRow <- [0 .. height - 1]
                ]
              | (blockRow, height) <- zip blockRows rowHeights
              ]
      Right (evaluatedList outputRows)
 where
  requireBlockRow (Call (Symbol "List") blocks) = Right blocks
  requireBlockRow _ =
    Left (EvaluationError "ArrayFlatten expects a rectangular list of array blocks.")
  blockShape SparseArray {} =
    Left (EvaluationError "ArrayFlatten currently supports dense array blocks only.")
  blockShape block = do
    dimensions <- strictDenseDimensions block
    case dimensions of
      [height, width] -> Right (height, width)
      _ -> Left (EvaluationError "ArrayFlatten currently expects rank-2 array blocks.")
  consistentRowHeight (rowIndex, shapes) = case shapes of
    [] -> Left (EvaluationError "ArrayFlatten expects a rectangular block matrix.")
    (height, _) : remaining
      | all ((== height) . fst) remaining -> Right height
      | otherwise ->
          Left
            ( EvaluationError
                ( "ArrayFlatten block row "
                    <> T.pack (show rowIndex)
                    <> " has inconsistent heights."
                )
            )
  consistentColumnWidth shapes columnIndex = case shapes of
    [] -> Left (EvaluationError "ArrayFlatten expects a rectangular block matrix.")
    firstRow : remaining ->
      let width = snd (firstRow !! columnIndex)
       in if all ((== width) . snd . (!! columnIndex)) remaining
            then Right width
            else
              Left
                ( EvaluationError
                    ( "ArrayFlatten block column "
                        <> T.pack (show (columnIndex + 1))
                        <> " has inconsistent widths."
                    )
                )
  blockMatrixRows (Call (Symbol "List") rows) =
    [values | Call (Symbol "List") values <- rows]
  blockMatrixRows _ = []
arrayFlatten _ =
  Left (EvaluationError "ArrayFlatten expects a rectangular list of array blocks.")

arrayFlattenSparseBlocks :: [Expr] -> Either EvaluationError Expr
arrayFlattenSparseBlocks rowExpressions = do
  blockRows <- traverse requireBlockRow rowExpressions
  let columnCount = case blockRows of
        firstRow : _ -> length firstRow
        [] -> 0
  if columnCount == 0 || any ((/= columnCount) . length) blockRows
    then Left (EvaluationError "ArrayFlatten expects a rectangular block matrix.")
    else
      if any hasNonzeroSparseFill (concat blockRows)
        then do
          denseRows <- traverse (traverse densifyBlock) blockRows
          arrayFlatten
            ( evaluatedList
                [evaluatedList row | row <- denseRows]
            )
        else do
          shapeRows <- traverse (traverse sparseBlockShape) blockRows
          rowHeights <- traverse consistentRowHeight (zip [1 :: Int ..] shapeRows)
          columnWidths <-
            traverse
              (consistentColumnWidth shapeRows)
              [0 .. columnCount - 1]
          pairs <- collectRows blockRows rowHeights columnWidths 0
          canonicalSparseArray
            [sum rowHeights, sum columnWidths]
            pairs
            (Integer 0)
 where
  requireBlockRow (Call (Symbol listHead) blocks)
    | systemHeadIn ["List"] listHead = Right blocks
  requireBlockRow _ =
    Left
      ( EvaluationError
          "ArrayFlatten expects a rectangular list of array blocks."
      )
  hasNonzeroSparseFill (SparseArray _ _ fill) = fill /= Integer 0
  hasNonzeroSparseFill _ = False
  densifyBlock sparse@SparseArray {} = sparseArrayNormal sparse
  densifyBlock dense = Right dense
  sparseBlockShape (SparseArray dimensions _ _) = case dimensions of
    [height, width] -> Right (height, width)
    _ ->
      Left
        ( EvaluationError
            "ArrayFlatten currently expects rank-2 SparseArray blocks."
        )
  sparseBlockShape dense = do
    dimensions <- strictDenseDimensions dense
    case dimensions of
      [height, width] -> Right (fromIntegral height, fromIntegral width)
      _ ->
        Left
          ( EvaluationError
              "ArrayFlatten currently expects rank-2 array blocks."
          )
  consistentRowHeight (rowIndex, shapes) = case shapes of
    [] -> Left (EvaluationError "ArrayFlatten expects a rectangular block matrix.")
    (height, _) : remaining
      | all ((== height) . fst) remaining -> Right height
      | otherwise ->
          Left
            ( EvaluationError
                ( "ArrayFlatten block row "
                    <> T.pack (show rowIndex)
                    <> " has inconsistent heights."
                )
            )
  consistentColumnWidth shapes columnIndex = case shapes of
    [] -> Left (EvaluationError "ArrayFlatten expects a rectangular block matrix.")
    firstRow : remaining ->
      let width = snd (firstRow !! columnIndex)
       in if all ((== width) . snd . (!! columnIndex)) remaining
            then Right width
            else
              Left
                ( EvaluationError
                    ( "ArrayFlatten block column "
                        <> T.pack (show (columnIndex + 1))
                        <> " has inconsistent widths."
                    )
                )
  collectRows [] [] _ _ = Right []
  collectRows (blocks : remainingRows) (height : remainingHeights) widths rowOffset = do
    rowPairs <- collectBlocks blocks widths rowOffset 0
    remainingPairs <-
      collectRows remainingRows remainingHeights widths (rowOffset + height)
    Right (rowPairs <> remainingPairs)
  collectRows _ _ _ _ =
    Left (EvaluationError "ArrayFlatten encountered inconsistent block rows.")
  collectBlocks [] [] _ _ = Right []
  collectBlocks (block : remainingBlocks) (width : remainingWidths) rowOffset columnOffset = do
    blockPairs <- shiftedBlockPairs block rowOffset columnOffset
    remainingPairs <-
      collectBlocks
        remainingBlocks
        remainingWidths
        rowOffset
        (columnOffset + width)
    Right (blockPairs <> remainingPairs)
  collectBlocks _ _ _ _ =
    Left (EvaluationError "ArrayFlatten encountered inconsistent block columns.")
  shiftedBlockPairs (SparseArray _ entries _) rowOffset columnOffset =
    Right
      [ ([rowOffset + row, columnOffset + column], value)
      | SparseEntry [row, column] value <- entries
      ]
  shiftedBlockPairs block rowOffset columnOffset = do
    dimensions <- strictDenseDimensions block
    pairs <- denseSparsePairs block (map fromIntegral dimensions) (Integer 0)
    Right
      [ ([rowOffset + row, columnOffset + column], value)
      | ([row, column], value) <- pairs
      ]

checkedDimensionSum :: Text -> [Int] -> Either EvaluationError Int
checkedDimensionSum operation dimensions =
  let total = sum (map toInteger dimensions)
   in if total > toInteger (maxBound :: Int)
        then
          Left
            ( EvaluationError
                (operation <> " dimensions are too large for this runtime.")
            )
        else Right (fromInteger total)

reduceTranspose :: [Expr] -> Either EvaluationError Expr
reduceTranspose [expression] = transposeDense expression Nothing
reduceTranspose [expression, permutationExpression] =
  transposeDense expression (Just permutationExpression)
reduceTranspose _ =
  Left (EvaluationError "Transpose expects an array and an optional permutation.")

transposeDense :: Expr -> Maybe Expr -> Either EvaluationError Expr
transposeDense (SparseArray dimensions entries fill) permutationExpression = do
  permutation <-
    normalizeTransposePermutation (length dimensions) permutationExpression
  if permutation == [0 .. length dimensions - 1]
    then Right (SparseArray dimensions entries fill)
    else
      canonicalSparseArray
        [dimensions !! axis | axis <- permutation]
        [ ([indices !! axis | axis <- permutation], value)
        | SparseEntry indices value <- entries
        ]
        fill
transposeDense expression permutationExpression = do
  dimensions <- requireDenseArrayDimensions "Transpose" expression
  permutation <- normalizeTransposePermutation (length dimensions) permutationExpression
  if permutation == [0 .. length dimensions - 1]
    then Right expression
    else do
      let newDimensions = [dimensions !! axis | axis <- permutation]
      buildDenseArrayM "Transpose" newDimensions $ \outputIndices ->
        denseArrayValueAt expression (sourceIndices permutation outputIndices)
 where
  sourceIndices permutation outputIndices =
    [ sourceIndex axis
    | axis <- [0 .. length permutation - 1]
    ]
   where
    sourceIndex axis = case
      [index | (sourceAxis, index) <- zip permutation outputIndices, sourceAxis == axis]
      of
        index : _ -> index
        [] -> 0

normalizeTransposePermutation
  :: Int
  -> Maybe Expr
  -> Either EvaluationError [Int]
normalizeTransposePermutation rank Nothing
  | rank < 2 = Right [0 .. rank - 1]
  | otherwise = Right (1 : 0 : [2 .. rank - 1])
normalizeTransposePermutation rank (Just (Call (Symbol "List") values))
  | length values /= rank = Left lengthError
  | otherwise = do
      axes <- traverse explicitAxis values
      if sort axes == [1 .. toInteger rank]
        then Right (map (subtract 1 . fromInteger) axes)
        else Left (EvaluationError "Transpose expects a permutation of array axes.")
 where
  explicitAxis (Integer axis) = Right axis
  explicitAxis _ = Left lengthError
  lengthError =
    EvaluationError "Transpose permutation length must match the array rank."
normalizeTransposePermutation _ (Just _) =
  Left (EvaluationError "Transpose expects a permutation list as its second argument.")

reduceUnitVector :: [Expr] -> Either EvaluationError Expr
reduceUnitVector [Integer lengthValue, Integer position]
  | lengthValue < 0 =
      Left (EvaluationError "UnitVector expects a non-negative length.")
  | position < 1 || position > lengthValue =
      Left
        ( EvaluationError
            "UnitVector position must be between 1 and the vector length."
        )
  | otherwise = do
      lengthInt <- nonnegativeDimension "UnitVector" lengthValue
      buildDenseArrayM "UnitVector" [lengthInt] $ \case
        [index] ->
          Right (Integer (if toInteger (index + 1) == position then 1 else 0))
        _ -> Left (EvaluationError "UnitVector encountered an invalid array index.")
reduceUnitVector _ =
  Left
    ( EvaluationError
        "UnitVector currently supports exactly two explicit integer arguments."
    )

reduceIdentityMatrix :: [Expr] -> Either EvaluationError Expr
reduceIdentityMatrix [Integer size] = identityMatrix size
reduceIdentityMatrix [_] =
  Left (EvaluationError "IdentityMatrix expects an integer argument.")
reduceIdentityMatrix _ =
  Left (EvaluationError "IdentityMatrix expects exactly one argument.")

identityMatrix :: Integer -> Either EvaluationError Expr
identityMatrix size
  | size < 0 =
      Left (EvaluationError "IdentityMatrix expects a non-negative integer size.")
  | otherwise = do
      dimension <- nonnegativeDimension "IdentityMatrix" size
      buildDenseArrayM "IdentityMatrix" [dimension, dimension] $ \case
        [row, column] -> Right (Integer (if row == column then 1 else 0))
        _ -> Left (EvaluationError "IdentityMatrix encountered an invalid array index.")

reduceLeviCivitaTensor :: [Expr] -> Either EvaluationError Expr
reduceLeviCivitaTensor = \case
  [dimensionExpression] ->
    leviCivitaTensor dimensionExpression Nothing
  [dimensionExpression, requestedHead] ->
    leviCivitaTensor dimensionExpression (Just requestedHead)
  _ ->
    Left
      ( EvaluationError
          "LeviCivitaTensor expects a dimension and an optional head."
      )

leviCivitaTensor :: Expr -> Maybe Expr -> Either EvaluationError Expr
leviCivitaTensor (Integer dimensionValue) requestedHead
  | dimensionValue < 0 =
      Left
        ( EvaluationError
            "LeviCivitaTensor expects a non-negative dimension."
        )
  | otherwise = do
      dimension <- nonnegativeDimension "LeviCivitaTensor" dimensionValue
      if sparseRequested requestedHead
        then sparseLeviCivitaTensor dimension
        else denseLeviCivitaTensor dimension
leviCivitaTensor _ _ =
  Left (EvaluationError "LeviCivitaTensor expects an integer argument.")

sparseRequested :: Maybe Expr -> Bool
sparseRequested (Just (Symbol headName)) =
  systemHeadIn ["SparseArray"] headName
sparseRequested _ = False

denseLeviCivitaTensor :: Int -> Either EvaluationError Expr
denseLeviCivitaTensor 0 = Right (Integer 1)
denseLeviCivitaTensor dimension =
  buildDenseArrayM
    "LeviCivitaTensor"
    (replicate dimension dimension)
    (Right . Integer . fromIntegral . leviCivitaValue)
 where
  leviCivitaValue indices
    | allDistinct indices = permutationSign indices
    | otherwise = 0

sparseLeviCivitaTensor :: Int -> Either EvaluationError Expr
sparseLeviCivitaTensor 0 =
  Left
    ( EvaluationError
        "SparseArray rule positions must match the array rank."
    )
sparseLeviCivitaTensor dimension = do
  guardSparseLeviCivitaMaterialization dimension
  let permutations' = pythonOrderedPermutations [1 .. dimension]
  Right
    ( SparseArray
        (replicate dimension (fromIntegral dimension))
        [ SparseEntry
            (map fromIntegral permutation)
            (Integer (fromIntegral (permutationSign permutation)))
        | permutation <- permutations'
        ]
        (Integer 0)
    )

guardSparseLeviCivitaMaterialization :: Int -> Either EvaluationError ()
guardSparseLeviCivitaMaterialization dimension =
  if factorialWithinLimit dimension maximumEntryCount
    then Right ()
    else
      Left
        ( EvaluationError
            "LeviCivitaTensor sparse output exceeds the native materialization limit."
        )
 where
  entryWidth = toInteger dimension + 1
  maximumEntryCount = maximumDenseArrayMaterializedNodes `div` entryWidth

factorialWithinLimit :: Int -> Integer -> Bool
factorialWithinLimit dimension limit = go 2 1
 where
  go factor value
    | factor > toInteger dimension = True
    | value > limit `div` factor = False
    | otherwise = go (factor + 1) (value * factor)

data DenseSequence
  = DenseCompound !Expr ![Expr]
  | DenseAssociation ![AssociationEntry]
  deriving (Eq, Show)

data DenseSequenceItem = DenseSequenceItem !Expr !(Maybe AssociationEntry)
  deriving (Eq, Show)

requireDenseSequence :: Text -> Expr -> Either EvaluationError DenseSequence
requireDenseSequence _operation expression
  | Just entries <- associationEntries expression = Right (DenseAssociation entries)
requireDenseSequence _operation (Call expressionHead values) =
  Right (DenseCompound expressionHead values)
requireDenseSequence operation SparseArray {} =
  Left (EvaluationError (operation <> " currently supports dense sequences only."))
requireDenseSequence operation _ =
  Left (EvaluationError (operation <> " expects a compound expression."))

denseSequenceItems :: DenseSequence -> [DenseSequenceItem]
denseSequenceItems (DenseCompound _ values) =
  [DenseSequenceItem value Nothing | value <- values]
denseSequenceItems (DenseAssociation entries) =
  [ DenseSequenceItem value (Just entry)
  | entry@(AssociationEntry _ _ value) <- entries
  ]

denseSequenceValues :: DenseSequence -> [Expr]
denseSequenceValues sequenceExpression =
  [value | DenseSequenceItem value _ <- denseSequenceItems sequenceExpression]

rebuildDenseSequence :: DenseSequence -> [DenseSequenceItem] -> Expr
rebuildDenseSequence (DenseCompound expressionHead _) items =
  normalizeEvaluatedCall expressionHead
    [value | DenseSequenceItem value _ <- items]
rebuildDenseSequence (DenseAssociation _) items =
  associationExpr
    [entry | DenseSequenceItem _ (Just entry) <- items]

emptyDenseSequence :: DenseSequence -> Expr
emptyDenseSequence sequenceExpression = rebuildDenseSequence sequenceExpression []

reduceDiagonalMatrix :: [Expr] -> Either EvaluationError Expr
reduceDiagonalMatrix [valuesExpression] =
  diagonalMatrix valuesExpression 0 Nothing
reduceDiagonalMatrix [valuesExpression, Integer offset] =
  diagonalMatrix valuesExpression offset Nothing
reduceDiagonalMatrix [valuesExpression, Integer offset, Integer size] =
  diagonalMatrix valuesExpression offset (Just size)
reduceDiagonalMatrix [_valuesExpression, _offset] =
  Left (EvaluationError "DiagonalMatrix expects an integer argument.")
reduceDiagonalMatrix [_valuesExpression, _offset, _size] =
  Left (EvaluationError "DiagonalMatrix expects an integer argument.")
reduceDiagonalMatrix _ =
  Left
    ( EvaluationError
        "DiagonalMatrix expects a list, an optional offset, and an optional matrix size."
    )

diagonalMatrix :: Expr -> Integer -> Maybe Integer -> Either EvaluationError Expr
diagonalMatrix valuesExpression offset requestedSize = do
  values <- denseSequenceValues <$> requireDenseSequence "DiagonalMatrix" valuesExpression
  let inferredSize = toInteger (length values) + abs offset
      sizeValue = maybe inferredSize id requestedSize
  if sizeValue < 0
    then Left (EvaluationError "DiagonalMatrix size must be non-negative.")
    else do
      size <- nonnegativeDimension "DiagonalMatrix" sizeValue
      Right
        ( evaluatedList
            [ evaluatedList
                [ diagonalValue values row column
                | column <- [0 .. size - 1]
                ]
            | row <- [0 .. size - 1]
            ]
        )
 where
  diagonalValue values row column
    | toInteger column - toInteger row /= offset = Integer 0
    | valueIndex < 0 || valueIndex >= toInteger (length values) = Integer 0
    | otherwise = values !! fromInteger valueIndex
   where
    valueIndex
      | offset >= 0 = toInteger row
      | otherwise = toInteger row + offset

reduceTuples :: [Expr] -> Either EvaluationError Expr
reduceTuples [itemsExpression] = tuplesProduct itemsExpression Nothing
reduceTuples [itemsExpression, countExpression] =
  tuplesProduct itemsExpression (Just countExpression)
reduceTuples _ =
  Left
    ( EvaluationError
        "Tuples expects a list of sequences or a sequence with a repetition count."
    )

tuplesProduct :: Expr -> Maybe Expr -> Either EvaluationError Expr
tuplesProduct itemsExpression Nothing = case itemsExpression of
  Call (Symbol "List") sequenceExpressions -> do
    sequences <-
      traverse
        (fmap denseSequenceValues . requireDenseSequence "Tuples")
        sequenceExpressions
    Right (flatTuplesProduct sequences)
  _ ->
    Left
      ( EvaluationError
          "Tuples expects a list of sequences or a sequence with a repetition count."
      )
tuplesProduct itemsExpression (Just (Call (Symbol "List") shapeExpressions)) = do
  shape <- traverse tupleShapeDimension shapeExpressions
  baseItems <- denseSequenceValues <$> requireDenseSequence "Tuples" itemsExpression
  Right (shapedTuplesProduct baseItems shape)
tuplesProduct itemsExpression (Just (Integer repetitions)) = do
  count <- tupleShapeDimension (Integer repetitions)
  baseItems <- denseSequenceValues <$> requireDenseSequence "Tuples" itemsExpression
  Right (flatTuplesProduct (replicate count baseItems))
tuplesProduct _ (Just _) =
  Left (EvaluationError "Tuples expects an integer argument.")

tupleShapeDimension :: Expr -> Either EvaluationError Int
tupleShapeDimension (Integer value)
  | value < 0 =
      Left (EvaluationError "Tuples shape components must be non-negative integers.")
  | otherwise = nonnegativeDimension "Tuples" value
tupleShapeDimension _ = Left (EvaluationError "Tuples expects an integer argument.")

flatTuplesProduct :: [[Expr]] -> Expr
flatTuplesProduct sequences =
  evaluatedList (foldl' extend [evaluatedList []] sequences)
 where
  extend prefixes choices =
    [ evaluatedList (prefixValues prefix <> [choice])
    | prefix <- prefixes
    , choice <- choices
    ]
  prefixValues (Call (Symbol "List") values) = values
  prefixValues _ = []

shapedTuplesProduct :: [Expr] -> [Int] -> Expr
shapedTuplesProduct _ [] = evaluatedList []
shapedTuplesProduct baseItems [count] =
  flatTuplesProduct (replicate count baseItems)
shapedTuplesProduct baseItems (count : remainingShape) =
  let inner = shapedTuplesProduct baseItems remainingShape
      innerChoices = case inner of
        Call (Symbol "List") values -> values
        _ -> []
   in flatTuplesProduct (replicate count innerChoices)

reducePartition :: [Expr] -> Either EvaluationError Expr
reducePartition [expression, sizeExpression] =
  partitionDense expression sizeExpression Nothing Nothing Nothing
reducePartition [expression, sizeExpression, offsetExpression] =
  partitionDense expression sizeExpression (Just offsetExpression) Nothing Nothing
reducePartition [expression, sizeExpression, offsetExpression, alignmentExpression] =
  partitionDense
    expression sizeExpression (Just offsetExpression) (Just alignmentExpression) Nothing
reducePartition
  [expression, sizeExpression, offsetExpression, alignmentExpression, padding] =
    partitionDense
      expression sizeExpression (Just offsetExpression) (Just alignmentExpression) (Just padding)
reducePartition _ =
  Left
    ( EvaluationError
        ( "Partition expects an expression, a block size, an optional offset, "
            <> "an optional alignment k or {kL, kR}, and an optional padding value."
        )
    )

partitionDense
  :: Expr
  -> Expr
  -> Maybe Expr
  -> Maybe Expr
  -> Maybe Expr
  -> Either EvaluationError Expr
partitionDense expression sizeExpression offsetExpression alignmentExpression padding = do
  window <- positivePartitionInteger "block sizes" sizeExpression
  step <- case offsetExpression of
    Nothing -> Right window
    Just value -> positivePartitionInteger "block sizes and offsets" value
  sequenceExpression <- requireDenseSequence "Partition" expression
  (leftAlignment, rightAlignment) <-
    normalizePartitionAlignment window alignmentExpression
  let items = denseSequenceItems sequenceExpression
      itemCount = length items
      firstStart = 2 - leftAlignment
      lastStart = itemCount - (rightAlignment - 1)
  if lastStart < firstStart
    then Right (evaluatedList [])
    else do
      let blockCount = (lastStart - firstStart) `div` step + 1
          starts = take blockCount [firstStart, firstStart + step ..]
      blocks <- traverse (buildBlock sequenceExpression items itemCount window) starts
      Right (evaluatedList blocks)
 where
  buildBlock sequenceExpression items itemCount window start =
    case traverse (selectItem items itemCount) [start .. start + window - 1] of
      Nothing -> Right (emptyDenseSequence sequenceExpression)
      Just blockItems -> Right (rebuildDenseSequence sequenceExpression blockItems)
  selectItem items itemCount position
    | position >= 1 && position <= itemCount = Just (items !! (position - 1))
    | Just paddingValue <- padding = Just (DenseSequenceItem paddingValue Nothing)
    | itemCount == 0 = Nothing
    | otherwise =
        let cyclicPosition = ((position - 1) `mod` itemCount) + 1
         in Just (items !! (cyclicPosition - 1))

positivePartitionInteger :: Text -> Expr -> Either EvaluationError Int
positivePartitionInteger description (Integer value)
  | value <= 0 =
      Left
        ( EvaluationError
            ("Partition expects positive integer " <> description <> ".")
        )
  | otherwise = nonnegativeDimension "Partition" value
positivePartitionInteger _ _ =
  Left (EvaluationError "Partition expects an integer argument.")

normalizePartitionAlignment
  :: Int
  -> Maybe Expr
  -> Either EvaluationError (Int, Int)
normalizePartitionAlignment window Nothing = Right (1, window)
normalizePartitionAlignment window (Just (Integer value)) = do
  normalized <- partitionAlignment window value
  Right (normalized, normalized)
normalizePartitionAlignment window (Just (Call (Symbol "List") [Integer left, Integer right])) =
  (,) <$> partitionAlignment window left <*> partitionAlignment window right
normalizePartitionAlignment _ (Just _) =
  Left
    ( EvaluationError
        "Partition currently expects an integer or {kL, kR} alignment."
    )

partitionAlignment :: Int -> Integer -> Either EvaluationError Int
partitionAlignment window value
  | value == -1 = Right window
  | value >= 1 && value <= toInteger window = Right (fromInteger value)
  | otherwise =
      Left
        ( EvaluationError
            "Partition alignment must be -1 or an integer between 1 and the block size."
        )

reduceTakeList :: [Expr] -> Either EvaluationError Expr
reduceTakeList [expression, Call (Symbol "List") specifications] = do
  (taken, _) <- foldM consume ([], expression) specifications
  Right (evaluatedList taken)
 where
  consume (taken, remaining) (Symbol "All") = do
    let emptied = case requireDenseSequence "TakeList" remaining of
          Right sequenceExpression -> emptyDenseSequence sequenceExpression
          Left _ -> remaining
    Right (taken <> [remaining], emptied)
  consume (taken, remaining) specification = do
    next <- reduceTakeDrop True [remaining, specification]
    leftover <- reduceTakeDrop False [remaining, specification]
    Right (taken <> [next], leftover)
reduceTakeList [_, _] =
  Left (EvaluationError "TakeList expects a list of specifications.")
reduceTakeList _ = Left (EvaluationError "TakeList expects exactly two arguments.")

reduceTakeDropPair :: [Expr] -> Either EvaluationError Expr
reduceTakeDropPair [expression, specification] = do
  taken <- reduceTakeDrop True [expression, specification]
  dropped <- reduceTakeDrop False [expression, specification]
  Right (evaluatedList [taken, dropped])
reduceTakeDropPair _ = Left (EvaluationError "TakeDrop expects exactly two arguments.")

data SequenceSearchMode
  = SequenceCases
  | SequencePosition
  | SequenceCount
  deriving (Eq, Show)

reduceSequenceSearch
  :: SequenceSearchMode
  -> [Expr]
  -> Either EvaluationError Expr
reduceSequenceSearch mode = \case
  [source, patternExpression] -> do
    items <- case source of
      Call (Symbol listHead) values
        | systemHeadIn ["List"] listHead -> Right values
      _ ->
        Left
          ( EvaluationError
              (sequenceSearchName mode <> " expects a List as its first argument.")
          )
    arity <- sequenceSearchPatternArity patternExpression
    if arity <= 0
      then
        Left
          ( EvaluationError
              "SequenceCases / SequencePosition / SequenceCount expect a nonempty fixed-arity List pattern."
          )
      else do
        let spans = sequenceSearchSpans items patternExpression arity
        Right $ case mode of
          SequenceCases ->
            evaluatedList
              [ evaluatedList (take arity (drop start items))
              | (start, _) <- spans
              ]
          SequencePosition ->
            evaluatedList
              [ evaluatedList
                  [ Integer (fromIntegral start + 1)
                  , Integer (fromIntegral end)
                  ]
              | (start, end) <- spans
              ]
          SequenceCount -> Integer (fromIntegral (length spans))
  _ ->
    Left
      ( EvaluationError
          (sequenceSearchName mode <> " expects a list and a List pattern.")
      )

sequenceSearchName :: SequenceSearchMode -> Text
sequenceSearchName = \case
  SequenceCases -> "SequenceCases"
  SequencePosition -> "SequencePosition"
  SequenceCount -> "SequenceCount"

sequenceSearchPatternArity :: Expr -> Either EvaluationError Int
sequenceSearchPatternArity = go
 where
  go = \case
    Call (Symbol wrapperHead) (inner : _)
      | systemHeadIn ["Condition", "HoldPattern"] wrapperHead -> go inner
    Call (Symbol listHead) patterns
      | systemHeadIn ["List"] listHead -> Right (length patterns)
    _ ->
      Left
        ( EvaluationError
            "SequenceCases / SequencePosition / SequenceCount expect a fixed-arity List pattern, optionally wrapped in Condition or HoldPattern."
        )

sequenceSearchSpans :: [Expr] -> Expr -> Int -> [(Int, Int)]
sequenceSearchSpans items patternExpression arity = go 0
 where
  itemCount = length items
  go start
    | start >= itemCount = []
    | start + arity > itemCount = []
    | matchesPattern
        (evaluatedList (take arity (drop start items)))
        patternExpression =
        (start, start + arity) : go (start + arity)
    | otherwise = go (start + 1)

reduceConstruct :: [Expr] -> Either EvaluationError Expr
reduceConstruct [] =
  Left (EvaluationError "Construct expects at least one argument.")
reduceConstruct (function : functionArguments) =
  evaluate (Call function functionArguments)

reduceComposeList :: [Expr] -> Either EvaluationError Expr
reduceComposeList [Call _ functions, initial] =
  compose functions initial [initial]
 where
  compose [] _ retained = Right (evaluatedList retained)
  compose (function : remaining) current retained = do
    updated <- evaluate (Call function [current])
    compose remaining updated (retained <> [updated])
reduceComposeList [_functions, _initial] =
  Left
    ( EvaluationError
        "ComposeList expects a list or other nonatomic expression of functions."
    )
reduceComposeList _ =
  Left (EvaluationError "ComposeList expects exactly two arguments.")

reduceComap :: Bool -> [Expr] -> Either EvaluationError Expr
reduceComap applyToArguments arguments' = case arguments' of
  [functions] -> Right (Call (Symbol operation) [functions])
  [functions, subject] -> mapFunctions functions subject
  _ -> Left (EvaluationError (operation <> " expects exactly two arguments."))
 where
  operation = if applyToArguments then "ComapApply" else "Comap"

  mapFunctions functions subject = case associationEntries functions of
    Just entries -> associationExpr <$> traverse (mapEntry subject) entries
    Nothing -> case functions of
      Call expressionHead values -> do
        mapped <- traverse (applyFunction subject) values
        Right (normalizeEvaluatedCall expressionHead mapped)
      _ -> Right functions

  mapEntry subject (AssociationEntry ruleHead key function) =
    AssociationEntry ruleHead key <$> applyFunction subject function

  applyFunction subject function
    | applyToArguments = case comapApplyArguments subject of
        Nothing -> Right subject
        Just values -> applyCallable function values
    | otherwise = applyCallable function [subject]

  applyCallable (Symbol nothingHead) _
    | systemHeadIn ["Nothing"] nothingHead = Right (Symbol "Nothing")
  applyCallable function values = evaluate (Call function values)

  comapApplyArguments subject = case associationEntries subject of
    Just entries ->
      Just [value | AssociationEntry _ _ value <- entries]
    Nothing -> case subject of
      Call _ values -> Just values
      _ -> Nothing

reduceNest :: Bool -> [Expr] -> Either EvaluationError Expr
reduceNest returnHistory [function, initial, countExpression] = do
  iterations <-
    nonNegativeIterationCount
      operation
      "expects a non-negative integer iteration count."
      countExpression
  nested <- buildNestHistory function iterations [initial]
  Right (if returnHistory then evaluatedList nested else last nested)
 where
  operation = if returnHistory then "NestList" else "Nest"
reduceNest returnHistory _ =
  Left
    ( EvaluationError
        ( (if returnHistory then "NestList" else "Nest")
            <> " expects exactly three arguments."
        )
    )

buildNestHistory
  :: Expr
  -> Integer
  -> [Expr]
  -> Either EvaluationError [Expr]
buildNestHistory _ 0 retained = Right retained
buildNestHistory function remaining retained = do
  updated <- evaluate (Call function [last retained])
  buildNestHistory function (remaining - 1) (retained <> [updated])

reduceNestWhile :: Bool -> [Expr] -> Either EvaluationError Expr
reduceNestWhile returnHistory arguments' = case arguments' of
  [function, initial, test] ->
    nestWhile function initial test Nothing Nothing
  [function, initial, test, historyExpression] ->
    nestWhile function initial test (Just historyExpression) Nothing
  [function, initial, test, historyExpression, maximumExpression] ->
    nestWhile
      function
      initial
      test
      (Just historyExpression)
      (Just maximumExpression)
  _ ->
    Left
      ( EvaluationError
          ( operation
              <> " expects f, expr, test, optional m, optional max."
          )
      )
 where
  operation = if returnHistory then "NestWhileList" else "NestWhile"
  nestWhile function initial test historyExpression maximumExpression = do
    historySize <- normalizeNestWhileHistory historyExpression
    maximumIterations <- normalizeNestWhileMaximum maximumExpression
    history <- iterateWhile function test historySize maximumIterations 0 [initial]
    Right (if returnHistory then evaluatedList history else last history)

  iterateWhile function test historySize maximumIterations iterations history = do
    predicateResult <- nestWhilePredicate test historySize history
    if not predicateResult
      then Right history
      else
        if iterations >= iterationSafetyLimit
          then
            Left
              ( EvaluationError
                  (operation <> " exceeded the Tungsten iteration safety limit.")
              )
          else case maximumIterations of
            Just maximumValue
              | iterations >= maximumValue -> Right history
            _ -> do
              updated <- evaluate (Call function [last history])
              iterateWhile
                function
                test
                historySize
                maximumIterations
                (iterations + 1)
                (history <> [updated])

normalizeNestWhileHistory
  :: Maybe Expr
  -> Either EvaluationError (Maybe Integer)
normalizeNestWhileHistory Nothing = Right (Just 1)
normalizeNestWhileHistory (Just (Integer value))
  | value >= 1 = Right (Just value)
normalizeNestWhileHistory (Just (Symbol name))
  | systemHeadIn ["All"] name = Right Nothing
normalizeNestWhileHistory _ =
  Left
    ( EvaluationError
        "NestWhile history size must be a positive integer or All."
    )

normalizeNestWhileMaximum
  :: Maybe Expr
  -> Either EvaluationError (Maybe Integer)
normalizeNestWhileMaximum Nothing = Right Nothing
normalizeNestWhileMaximum (Just (Integer value)) = Right (Just (max 0 value))
normalizeNestWhileMaximum (Just (Symbol name))
  | systemHeadIn ["Infinity"] name = Right Nothing
normalizeNestWhileMaximum _ =
  Left
    ( EvaluationError
        "NestWhile max iterations must be a non-negative integer or Infinity."
    )

nestWhilePredicate
  :: Expr
  -> Maybe Integer
  -> [Expr]
  -> Either EvaluationError Bool
nestWhilePredicate test historySize history = case historySize of
  Just required
    | fromIntegral (length history) < required -> Right True
    | otherwise -> applyPredicate (drop (length history - fromIntegral required) history)
  Nothing -> applyPredicate history
 where
  applyPredicate predicateArguments = do
    result <- evaluate (Call test predicateArguments)
    Right (result == Symbol "True")

reduceFixedPoint :: Bool -> [Expr] -> Either EvaluationError Expr
reduceFixedPoint returnHistory = \case
  [function, initial] ->
    findFixedPoint function initial iterationSafetyLimit False
  [function, initial, countExpression] -> do
    limit <-
      nonNegativeIterationCount
        operation
        "expects a non-negative maximum iteration count."
        countExpression
    findFixedPoint function initial limit True
  _ ->
    Left
      ( EvaluationError
          ( operation
              <> " expects a function, an expression, and an optional iteration limit."
          )
      )
 where
  operation = if returnHistory then "FixedPointList" else "FixedPoint"
  findFixedPoint function initial limit explicitLimit =
    iterateUntilStable limit initial [initial]
   where
    iterateUntilStable 0 current retained
      | explicitLimit = finish current retained
      | otherwise =
          Left
            ( EvaluationError
                (operation <> " exceeded the Tungsten iteration safety limit.")
            )
    iterateUntilStable remaining current retained = do
      updated <- evaluate (Call function [current])
      let nextRetained = retained <> [updated]
      if updated == current
        then finish current nextRetained
        else iterateUntilStable (remaining - 1) updated nextRetained
    finish current retained =
      Right (if returnHistory then evaluatedList retained else current)

reduceFold :: Bool -> [Expr] -> Either EvaluationError Expr
reduceFold returnHistory = \case
  [function, subject] -> do
    values <- sequenceFoldCollectionValues operation subject
    case values of
      []
        | returnHistory -> Right (evaluatedList [])
        | otherwise ->
            Left (EvaluationError "Fold[f, expr] expects a nonempty sequence.")
      initial : remaining -> finish function initial remaining
  [function, initial, subject] -> do
    values <- sequenceFoldCollectionValues operation subject
    finish function initial values
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects two or three arguments.")
      )
 where
  operation = if returnHistory then "FoldList" else "Fold"
  finish function initial values = do
    history <- buildFoldHistory function initial values [initial]
    Right (if returnHistory then evaluatedList history else last history)

buildFoldHistory
  :: Expr
  -> Expr
  -> [Expr]
  -> [Expr]
  -> Either EvaluationError [Expr]
buildFoldHistory _ _ [] retained = Right retained
buildFoldHistory function current (value : remaining) retained = do
  updated <- evaluate (Call function [current, value])
  buildFoldHistory function updated remaining (retained <> [updated])

reduceFoldWhile :: Bool -> [Expr] -> Either EvaluationError Expr
reduceFoldWhile returnHistory arguments' = case arguments' of
  [function, initial, subject, test] ->
    foldWhile function initial subject test Nothing Nothing
  [function, initial, subject, test, historyExpression] ->
    foldWhile function initial subject test (Just historyExpression) Nothing
  [function, initial, subject, test, historyExpression, trailingExpression] ->
    foldWhile
      function
      initial
      subject
      test
      (Just historyExpression)
      (Just trailingExpression)
  _ ->
    Left
      ( EvaluationError
          ( operation
              <> " currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
          )
      )
 where
  operation = if returnHistory then "FoldWhileList" else "FoldWhile"

  foldWhile function initial subject test historyExpression trailingExpression = do
    inputs <- sequenceFoldCollectionValues "FoldWhileList" subject
    historySize <- normalizeFoldWhileHistory historyExpression
    initialSucceeds <- foldWhilePredicate test historySize [initial]
    if initialSucceeds
      then foldInputs function test historySize trailingExpression [initial] inputs
      else finish [initial]

  foldInputs _ _ _ _ results [] = finish results
  foldInputs function test historySize trailingExpression results (inputValue : remaining) = do
    updated <- evaluate (Call function [last results, inputValue])
    let nextResults = results <> [updated]
    predicateSucceeds <- foldWhilePredicate test historySize nextResults
    if predicateSucceeds
      then foldInputs function test historySize trailingExpression nextResults remaining
      else finishFailure function trailingExpression nextResults remaining

  finishFailure function trailingExpression results remaining =
    case trailingExpression of
      Nothing -> finish results
      Just (Integer trailing)
        | trailing < 0 ->
            let retainedCount =
                  min
                    (toInteger (length results))
                    (max 1 (toInteger (length results) + trailing))
             in finish (take (fromInteger retainedCount) results)
        | otherwise -> appendTrailing function trailing results remaining
      Just _ ->
        Left
          (EvaluationError "FoldWhileList expects an integer argument.")

  appendTrailing _ 0 results _ = finish results
  appendTrailing _ _ results [] = finish results
  appendTrailing function remainingCount results (inputValue : remaining) = do
    updated <- evaluate (Call function [last results, inputValue])
    appendTrailing
      function
      (remainingCount - 1)
      (results <> [updated])
      remaining

  finish results =
    let retained = filter (/= Symbol "Nothing") results
     in Right $ case (returnHistory, retained) of
          (True, _) -> evaluatedList retained
          (False, []) -> Symbol "Nothing"
          (False, _) -> last retained

normalizeFoldWhileHistory
  :: Maybe Expr
  -> Either EvaluationError (Maybe Integer)
normalizeFoldWhileHistory Nothing = Right (Just 1)
normalizeFoldWhileHistory (Just (Integer value))
  | value > 0 = Right (Just value)
normalizeFoldWhileHistory (Just (Symbol name))
  | systemHeadIn ["All"] name = Right Nothing
normalizeFoldWhileHistory _ =
  Left
    ( EvaluationError
        "FoldWhileList expects a positive history length or All."
    )

foldWhilePredicate
  :: Expr
  -> Maybe Integer
  -> [Expr]
  -> Either EvaluationError Bool
foldWhilePredicate test historySize history = do
  result <- evaluate (Call test (foldWhileHistoryArguments historySize history))
  Right (result == Symbol "True")

foldWhileHistoryArguments :: Maybe Integer -> [Expr] -> [Expr]
foldWhileHistoryArguments Nothing history = history
foldWhileHistoryArguments (Just required) history
  | required >= toInteger (length history) = history
  | otherwise = drop (length history - fromInteger required) history

reduceFoldPair :: Bool -> [Expr] -> Either EvaluationError Expr
reduceFoldPair returnHistory arguments' = case arguments' of
  [function, initial, subject] ->
    foldPairs function initial subject Nothing
  [function, initial, subject, projection] ->
    foldPairs function initial subject (Just projection)
  _ ->
    Left
      ( EvaluationError
          ( operation
              <> " currently supports a function, an initial value, inputs, and an optional projection."
          )
      )
 where
  operation = if returnHistory then "FoldPairList" else "FoldPair"
  foldPairs function initial subject projection = do
    inputs <- sequenceFoldCollectionValues "FoldPairList" subject
    projected <- build function projection initial inputs []
    let retained = filter (/= Symbol "Nothing") projected
    case retained of
      []
        | returnHistory -> Right (evaluatedList [])
        | otherwise -> Right (Call (Symbol "FoldPair") arguments')
      _
        | returnHistory -> Right (evaluatedList retained)
        | otherwise -> Right (last retained)

  build _ _ _ [] retained = Right retained
  build function projection current (inputValue : remaining) retained = do
    pairExpression <- evaluate (Call function [current, inputValue])
    (projected, next) <- projectPair projection pairExpression
    build function projection next remaining (retained <> [projected])

  projectPair projection pairExpression = case pairExpression of
    Call (Symbol listHead) [first, second]
      | systemHeadIn ["List"] listHead -> do
          projected <- case projection of
            Nothing -> Right first
            Just function ->
              evaluate (Call function [evaluatedList [first, second]])
          Right (projected, second)
    _ ->
      Left
        ( EvaluationError
            ( "FoldPairList expects each function application to return a list of two elements, got "
                <> inputForm pairExpression
                <> "."
            )
        )

nonNegativeIterationCount
  :: Text
  -> Text
  -> Expr
  -> Either EvaluationError Integer
nonNegativeIterationCount operation negativeMessage = \case
  Integer value
    | value >= 0 -> Right value
    | otherwise ->
        Left
          ( EvaluationError
              (operation <> " " <> negativeMessage)
          )
  _ ->
    Left
      ( EvaluationError
          (operation <> " expects an integer argument.")
      )

iterationSafetyLimit :: Integer
iterationSafetyLimit = 65536

reduceSequenceFold
  :: Bool
  -> [Expr]
  -> Either EvaluationError Expr
reduceSequenceFold returnHistory arguments' = case arguments' of
  [function, initialExpression, inputsExpression] ->
    foldSequence function initialExpression inputsExpression Nothing
  [function, initialExpression, inputsExpression, arityExpression] ->
    foldSequence function initialExpression inputsExpression (Just arityExpression)
  _ ->
    Left
      ( EvaluationError
          ( operation
              <> " expects a function, initial values, inputs, and an optional argument count."
          )
      )
 where
  operation = if returnHistory then "SequenceFoldList" else "SequenceFold"

  foldSequence function initialExpression inputsExpression arityExpression = do
    initialValues <- sequenceFoldCollectionValues operation initialExpression
    inputs <- sequenceFoldCollectionValues operation inputsExpression
    if null initialValues
      then
        Left
          (EvaluationError "SequenceFoldList expects at least one initial value.")
      else do
        argumentCount <- case arityExpression of
          Nothing -> Right (length initialValues + 1)
          Just (Integer value)
            | value >= fromIntegral (minBound :: Int)
            , value <= fromIntegral (maxBound :: Int) -> Right (fromIntegral value)
          Just _ ->
            Left
              (EvaluationError "SequenceFoldList expects an integer argument.")
        if argumentCount < length initialValues
          then
            Left
              ( EvaluationError
                  "SequenceFoldList expects an argument count greater than or equal to the number of initial values."
              )
          else do
            let consumedPerStep = argumentCount - length initialValues
            if consumedPerStep <= 0
              then
                Left
                  ( EvaluationError
                      "SequenceFoldList currently expects each step to consume at least one input element."
                  )
              else do
                history <-
                  buildSequenceFoldHistory
                    function
                    (length initialValues)
                    consumedPerStep
                    initialValues
                    inputs
                Right
                  ( if returnHistory
                      then evaluatedList history
                      else last history
                  )

sequenceFoldCollectionValues :: Text -> Expr -> Either EvaluationError [Expr]
sequenceFoldCollectionValues operation = \case
  SparseArray [dimension] entries fill
    | dimension <= 65536 ->
        Right
          [ sparseValueAt entries fill [index]
          | index <- [1 .. dimension]
          ]
    | otherwise ->
        Left
          ( EvaluationError
              (operation <> " exceeds the dense sequence materialization safety limit.")
          )
  SparseArray {} ->
    Left
      ( EvaluationError
          (operation <> " expects a one-dimensional SparseArray sequence.")
      )
  expression@Call {} -> do
    items <- orderedItems operation expression
    Right [value | OrderedItem _ value _ _ <- items]
  _ ->
    Left
      (EvaluationError (operation <> " expects a nonatomic expression."))

buildSequenceFoldHistory
  :: Expr
  -> Int
  -> Int
  -> [Expr]
  -> [Expr]
  -> Either EvaluationError [Expr]
buildSequenceFoldHistory function stateWidth consumedPerStep = go
 where
  go history remaining
    | length remaining < consumedPerStep = Right history
    | otherwise = do
        let state = drop (length history - stateWidth) history
            (consumed, rest) = splitAt consumedPerStep remaining
        current <- evaluate (Call function (state <> consumed))
        go (history <> [current]) rest

denseListValues :: Expr -> Maybe [Expr]
denseListValues (Call (Symbol "List") values) = Just values
denseListValues _ = Nothing

denseListRows :: Expr -> Maybe [[Expr]]
denseListRows expression = do
  rows <- denseListValues expression
  traverse denseListValues rows

reduceDot :: [Expr] -> Either EvaluationError Expr
reduceDot [] = Left (EvaluationError "Dot expects at least two arguments.")
reduceDot [_] = Left (EvaluationError "Dot expects at least two arguments.")
reduceDot (firstExpression : remaining) =
  foldM multiplyAndEvaluate firstExpression remaining
 where
  multiplyAndEvaluate left right = dotTwo left right >>= evaluate

dotTwo :: Expr -> Expr -> Either EvaluationError Expr
dotTwo left@SparseArray {} right@SparseArray {} = sparseDot left right
dotTwo left@SparseArray {} right = do
  denseLeft <- sparseArrayNormal left
  dotTwo denseLeft right
dotTwo left right@SparseArray {} = do
  denseRight <- sparseArrayNormal right
  dotTwo left denseRight
dotTwo left right =
  case (denseListRows left, denseListRows right, denseListValues left, denseListValues right) of
    (Nothing, Nothing, Just leftValues, Just rightValues)
      | length leftValues /= length rightValues ->
          Left (EvaluationError "Dot expects vectors of the same length.")
      | otherwise ->
          Right
            ( Call
                (Symbol "Plus")
                [Call (Symbol "Times") [leftValue, rightValue]
                | (leftValue, rightValue) <- zip leftValues rightValues
                ]
            )
    (Just leftRows, Nothing, _, Just _) ->
      evaluatedList
        <$> traverse
          (\row -> dotTwo (evaluatedList row) right)
          leftRows
    (Nothing, Just rightRows, Just leftValues, _)
      | length leftValues /= length rightRows ->
          Left (EvaluationError "Dot expects compatible vector/matrix dimensions.")
      | not (rectangularRows rightRows) ->
          Left (EvaluationError "Dot currently expects rectangular matrices.")
      | otherwise ->
          let rightWidth = matrixWidth rightRows
              columns =
                [evaluatedList [row !! column | row <- rightRows]
                | column <- [0 .. rightWidth - 1]
                ]
           in evaluatedList <$> traverse (dotTwo left) columns
    (Just leftRows, Just rightRows, _, _)
      | not (rectangularRows leftRows) ->
          Left (EvaluationError "Dot currently expects rectangular matrices.")
      | not (rectangularRows rightRows)
          || matrixWidth leftRows /= length rightRows ->
          Left (EvaluationError "Dot currently expects compatible matrix dimensions.")
      | otherwise ->
          evaluatedList
            <$> traverse
              (\row -> dotTwo (evaluatedList row) right)
              leftRows
    _ ->
      Left (EvaluationError "Dot currently supports List vectors and List matrices only.")

sparseDot :: Expr -> Expr -> Either EvaluationError Expr
sparseDot left@(SparseArray leftDimensions leftEntries leftFill) right@(SparseArray rightDimensions rightEntries rightFill)
  | leftFill /= Integer 0 || rightFill /= Integer 0 = do
      denseLeft <- sparseArrayNormal left
      denseRight <- sparseArrayNormal right
      dotTwo denseLeft denseRight
  | leftRank `notElem` [1, 2] || rightRank `notElem` [1, 2] =
      Left
        ( EvaluationError
            "Dot currently supports sparse vectors and matrices only."
        )
  | leftRank == 1 && rightRank == 1 = sparseVectorDot
  | leftRank == 2 && rightRank == 1 = sparseMatrixVectorDot
  | leftRank == 1 && rightRank == 2 = sparseVectorMatrixDot
  | otherwise = sparseMatrixMatrixDot
 where
  leftRank = length leftDimensions
  rightRank = length rightDimensions
  leftMap = Map.fromList [(indices, value) | SparseEntry indices value <- leftEntries]
  rightMap = Map.fromList [(indices, value) | SparseEntry indices value <- rightEntries]

  sparseVectorDot
    | leftDimensions /= rightDimensions =
        Left (EvaluationError "Dot expects vectors of the same length.")
    | otherwise = do
        terms <-
          traverse
            (uncurry (evaluateSparseScalar "Times"))
            [ (leftValue, rightValue)
            | (indices, leftValue) <- Map.toAscList leftMap
            , Just rightValue <- [Map.lookup indices rightMap]
            ]
        evaluate (Call (Symbol "Plus") terms)

  sparseMatrixVectorDot = case (leftDimensions, rightDimensions) of
    ([rows, width], [rightWidth])
      | width /= rightWidth ->
          Left
            ( EvaluationError
                "Dot expects compatible sparse matrix/vector dimensions."
            )
      | otherwise -> do
          output <-
            foldM
              ( \retained (SparseEntry indices leftValue) -> case indices of
                  [row, column] -> case Map.lookup [column] rightMap of
                    Nothing -> Right retained
                    Just rightValue ->
                      addSparseProduct retained [row] leftValue rightValue
                  _ ->
                    Left
                      ( EvaluationError
                          "Dot encountered an invalid sparse matrix coordinate."
                      )
              )
              Map.empty
              leftEntries
          canonicalSparseArray [rows] (Map.toAscList output) (Integer 0)
    _ ->
      Left
        ( EvaluationError
            "Dot currently supports sparse vectors and matrices only."
        )

  sparseVectorMatrixDot = case (leftDimensions, rightDimensions) of
    ([width], [rightRows, columns])
      | width /= rightRows ->
          Left
            ( EvaluationError
                "Dot expects compatible sparse vector/matrix dimensions."
            )
      | otherwise -> do
          output <-
            foldM
              ( \retained (SparseEntry indices rightValue) -> case indices of
                  [row, column] -> case Map.lookup [row] leftMap of
                    Nothing -> Right retained
                    Just leftValue ->
                      addSparseProduct retained [column] leftValue rightValue
                  _ ->
                    Left
                      ( EvaluationError
                          "Dot encountered an invalid sparse matrix coordinate."
                      )
              )
              Map.empty
              rightEntries
          canonicalSparseArray [columns] (Map.toAscList output) (Integer 0)
    _ ->
      Left
        ( EvaluationError
            "Dot currently supports sparse vectors and matrices only."
        )

  sparseMatrixMatrixDot = case (leftDimensions, rightDimensions) of
    ([rows, width], [rightRows, columns])
      | width /= rightRows ->
          Left
            ( EvaluationError
                "Dot expects compatible sparse matrix dimensions."
            )
      | otherwise -> do
          let rightByRow =
                foldl'
                  ( \retained (SparseEntry indices value) -> case indices of
                      [row, column] ->
                        Map.insertWith
                          (\newValues oldValues -> oldValues <> newValues)
                          row
                          [(column, value)]
                          retained
                      _ -> retained
                  )
                  Map.empty
                  rightEntries
          output <-
            foldM
              ( \retained (SparseEntry indices leftValue) -> case indices of
                  [row, shared] ->
                    foldM
                      ( \current (column, rightValue) ->
                          addSparseProduct
                            current
                            [row, column]
                            leftValue
                            rightValue
                      )
                      retained
                      (Map.findWithDefault [] shared rightByRow)
                  _ ->
                    Left
                      ( EvaluationError
                          "Dot encountered an invalid sparse matrix coordinate."
                      )
              )
              Map.empty
              leftEntries
          canonicalSparseArray [rows, columns] (Map.toAscList output) (Integer 0)
    _ ->
      Left
        ( EvaluationError
            "Dot currently supports sparse vectors and matrices only."
        )
sparseDot _ _ =
  Left (EvaluationError "Dot currently expects SparseArray values.")

addSparseProduct
  :: Map.Map [Integer] Expr
  -> [Integer]
  -> Expr
  -> Expr
  -> Either EvaluationError (Map.Map [Integer] Expr)
addSparseProduct retained indices left right = do
  contribution <- evaluateSparseScalar "Times" left right
  if contribution == Integer 0
    then Right retained
    else case Map.lookup indices retained of
      Nothing -> Right (Map.insert indices contribution retained)
      Just previous -> do
        combined <- evaluateSparseScalar "Plus" previous contribution
        Right
          ( if combined == Integer 0
              then Map.delete indices retained
              else Map.insert indices combined retained
          )

matrixWidth :: [[Expr]] -> Int
matrixWidth [] = 0
matrixWidth (row : _) = length row

rectangularRows :: [[Expr]] -> Bool
rectangularRows rows = all ((== matrixWidth rows) . length) rows

exactZero :: Expr -> Bool
exactZero expression = case toExact expression of
  Just (Exact numerator _) -> numerator == 0
  Nothing -> False

exactOne :: Expr -> Bool
exactOne expression = case toExact expression of
  Just (Exact numerator denominator) -> numerator == denominator
  Nothing -> False

expressionSum :: [Expr] -> Expr
expressionSum = reducePlus

expressionProduct :: [Expr] -> Expr
expressionProduct = reduceTimes

expressionNegate :: Expr -> Expr
expressionNegate expression
  | exactZero expression = Integer 0
  | otherwise = reduceTimes [Integer (-1), expression]

-- Canonical order places the signed term before the positive term.  This is
-- observable in FullForm for symbolic Cross, minors, and determinants.
expressionSubtract :: Expr -> Expr -> Expr
expressionSubtract left right
  | exactZero right = left
  | otherwise = reducePlus (sortBy canonicalCompare [left, expressionNegate right])

expressionInverse :: Expr -> Expr
expressionInverse expression
  | exactOne expression = Integer 1
  | otherwise = reducePower [expression, Integer (-1)]

expressionDivide :: Expr -> Expr -> Expr
expressionDivide numerator denominator
  | exactZero numerator = Integer 0
  | exactOne denominator = numerator
  | otherwise = reduceTimes [numerator, expressionInverse denominator]

reduceCross :: [Expr] -> Either EvaluationError Expr
reduceCross [left, right] = do
  leftValues <- requireDenseVector "Cross" left
  rightValues <- requireDenseVector "Cross" right
  if length leftValues /= length rightValues || length leftValues `notElem` [2, 3]
    then
      Left
        ( EvaluationError
            "Cross currently supports pairs of 2D or 3D vectors."
        )
    else case (leftValues, rightValues) of
      ([left1, left2], [right1, right2]) ->
        Right
          ( expressionSubtract
              (expressionProduct [left1, right2])
              (expressionProduct [left2, right1])
          )
      ([left1, left2, left3], [right1, right2, right3]) ->
        Right
          ( evaluatedList
              [ expressionSubtract
                  (expressionProduct [left2, right3])
                  (expressionProduct [left3, right2])
              , expressionSubtract
                  (expressionProduct [left3, right1])
                  (expressionProduct [left1, right3])
              , expressionSubtract
                  (expressionProduct [left1, right2])
                  (expressionProduct [left2, right1])
              ]
          )
      _ ->
        Left
          ( EvaluationError
              "Cross currently supports pairs of 2D or 3D vectors."
          )
reduceCross _ =
  Left (EvaluationError "Cross currently expects exactly two vector arguments.")

requireDenseVector :: Text -> Expr -> Either EvaluationError [Expr]
requireDenseVector _operation (Call (Symbol "List") values) = Right values
requireDenseVector operation SparseArray {} =
  Left (EvaluationError (operation <> " currently supports dense vectors only."))
requireDenseVector operation _ =
  Left (EvaluationError (operation <> " expects vectors."))

requireDenseMatrixRows :: Text -> Expr -> Either EvaluationError [[Expr]]
requireDenseMatrixRows operation SparseArray {} =
  Left (EvaluationError (operation <> " currently supports dense matrices only."))
requireDenseMatrixRows operation expression = case denseListRows expression of
  Nothing -> Left (EvaluationError (operation <> " expects a matrix."))
  Just rows
    | rectangularRows rows -> Right rows
    | otherwise ->
        Left (EvaluationError (operation <> " expects a rectangular matrix."))

requireSquareMatrixRows :: Text -> Expr -> Either EvaluationError [[Expr]]
requireSquareMatrixRows operation expression = do
  rows <- requireDenseMatrixRows operation expression
  if length rows == matrixWidth rows
    then Right rows
    else Left (EvaluationError (operation <> " expects a square matrix."))

reduceDet :: [Expr] -> Either EvaluationError Expr
reduceDet [expression] = determinantFromRows <$> requireSquareMatrixRows "Det" expression
reduceDet _ = Left (EvaluationError "Det expects exactly one matrix argument.")

determinantFromRows :: [[Expr]] -> Expr
determinantFromRows rows = case traverse (traverse toExact) rows of
  Just exactRows -> fromExact (determinantExact exactRows)
  Nothing -> determinantSymbolic rows

determinantExact :: [[Exact]] -> Exact
determinantExact [] = Exact 1 1
determinantExact rows = eliminate 0 1 rows
 where
  size = length rows
  eliminate column sign matrix
    | column == size =
        foldl'
          multiplyExact
          (Exact sign 1)
          [matrix !! index !! index | index <- [0 .. size - 1]]
    | otherwise = case findNonzeroPivot column matrix of
        Nothing -> Exact 0 1
        Just pivotIndex ->
          let swapped = swapListItems column pivotIndex matrix
              nextSign = if pivotIndex == column then sign else negate sign
              pivotRow = swapped !! column
              pivot = pivotRow !! column
              reduced =
                [ if rowIndex <= column
                    then row
                    else eliminateRow column pivot pivotRow row
                | (rowIndex, row) <- zip [0 :: Int ..] swapped
                ]
           in eliminate (column + 1) nextSign reduced

findNonzeroPivot :: Int -> [[Exact]] -> Maybe Int
findNonzeroPivot column rows = findAt column
 where
  findAt index
    | index >= length rows = Nothing
    | exactNumerator (rows !! index !! column) /= 0 = Just index
    | otherwise = findAt (index + 1)
  exactNumerator (Exact numerator _) = numerator

eliminateRow :: Int -> Exact -> [Exact] -> [Exact] -> [Exact]
eliminateRow column pivot pivotRow row =
  let factor = exactQuotient (row !! column) pivot
      prefix = take column row
      reducedSuffix =
        zipWith
          (\value pivotValue -> addExact value (negateExact (multiplyExact factor pivotValue)))
          (drop column row)
          (drop column pivotRow)
   in prefix <> reducedSuffix

exactQuotient :: Exact -> Exact -> Exact
exactQuotient numerator denominator = case divideExact numerator denominator of
  Just quotient -> quotient
  Nothing -> Exact 0 1

swapListItems :: Int -> Int -> [value] -> [value]
swapListItems leftIndex rightIndex values
  | leftIndex == rightIndex = values
  | otherwise =
      replaceListIndex
        rightIndex
        (values !! leftIndex)
        (replaceListIndex leftIndex (values !! rightIndex) values)

determinantSymbolic :: [[Expr]] -> Expr
determinantSymbolic [] = Integer 1
determinantSymbolic rows =
  expressionSum
    ( sortBy
        canonicalCompare
        [ term
        | permutation <- permutations [0 .. length rows - 1]
        , let factors = zipWith (!!) rows permutation
        , not (any exactZero factors)
        , let signedFactors =
                (if permutationSign permutation < 0 then [Integer (-1)] else [])
                  <> factors
        , let term = expressionProduct signedFactors
        , not (exactZero term)
        ]
    )

permutationSign :: [Int] -> Int
permutationSign values =
  if even inversionCount then 1 else -1
 where
  inversionCount =
    length
      [ ()
      | (leftIndex, left) <- zip [0 :: Int ..] values
      , right <- drop (leftIndex + 1) values
      , left > right
      ]

reduceInverse :: [Expr] -> Either EvaluationError Expr
reduceInverse [expression] = do
  rows <- requireSquareMatrixRows "Inverse" expression
  case traverse (traverse toExact) rows of
    Just exactRows -> inverseExact exactRows
    Nothing -> inverseSymbolic rows
reduceInverse _ =
  Left (EvaluationError "Inverse expects exactly one matrix argument.")

inverseExact :: [[Exact]] -> Either EvaluationError Expr
inverseExact rows = do
  reduced <- foldM eliminateColumn augmented [0 .. size - 1]
  Right
    ( evaluatedList
        [evaluatedList (map fromExact (drop size row)) | row <- reduced]
    )
 where
  size = length rows
  augmented =
    [ row
        <> [Exact (if rowIndex == column then 1 else 0) 1 | column <- [0 .. size - 1]]
    | (rowIndex, row) <- zip [0 :: Int ..] rows
    ]
  eliminateColumn matrix column = case findNonzeroPivot column matrix of
    Nothing -> Left (EvaluationError "Inverse expects a nonsingular matrix.")
    Just pivotIndex ->
      let swapped = swapListItems column pivotIndex matrix
          pivotRow = swapped !! column
          pivot = pivotRow !! column
          normalizedPivot = map (`exactQuotient` pivot) pivotRow
          withPivot = replaceListIndex column normalizedPivot swapped
          eliminateOther rowIndex row
            | rowIndex == column = normalizedPivot
            | otherwise =
                let factor = row !! column
                 in zipWith
                      (\value pivotValue ->
                        addExact value (negateExact (multiplyExact factor pivotValue)))
                      row
                      normalizedPivot
       in Right
            [ eliminateOther rowIndex row
            | (rowIndex, row) <- zip [0 :: Int ..] withPivot
            ]

inverseSymbolic :: [[Expr]] -> Either EvaluationError Expr
inverseSymbolic rows
  | exactZero determinant =
      Left (EvaluationError "Inverse expects a nonsingular matrix.")
  | otherwise =
      Right
        ( evaluatedList
            [ evaluatedList
                [ inverseEntry outputRow outputColumn
                | outputColumn <- [0 .. size - 1]
                ]
            | outputRow <- [0 .. size - 1]
            ]
        )
 where
  size = length rows
  determinant = determinantFromRows rows
  inverseEntry outputRow outputColumn =
    let cofactor =
          determinantFromRows (minorRows rows outputColumn outputRow)
        signedCofactor =
          if odd (outputRow + outputColumn)
            then expressionNegate cofactor
            else cofactor
     in expressionDivide signedCofactor determinant

minorRows :: [[value]] -> Int -> Int -> [[value]]
minorRows rows removedRow removedColumn =
  [ [value | (columnIndex, value) <- zip [0 :: Int ..] row, columnIndex /= removedColumn]
  | (rowIndex, row) <- zip [0 :: Int ..] rows
  , rowIndex /= removedRow
  ]

reduceMatrixPower :: [Expr] -> Either EvaluationError Expr
reduceMatrixPower [expression, Integer power] = matrixPower expression power
reduceMatrixPower [_, _] =
  Left (EvaluationError "MatrixPower expects an integer argument.")
reduceMatrixPower _ =
  Left (EvaluationError "MatrixPower expects a matrix and an integer exponent.")

matrixPower :: Expr -> Integer -> Either EvaluationError Expr
matrixPower expression power = do
  rows <- requireSquareMatrixRows "MatrixPower" expression
  identity <- identityMatrix (toInteger (length rows))
  base <- if power < 0 then reduceInverse [expression] else Right expression
  powerLoop identity base (abs power)
 where
  powerLoop result _ 0 = Right result
  powerLoop result base remaining = do
    nextResult <-
      if odd remaining
        then dotTwo result base >>= evaluate
        else Right result
    let nextRemaining = remaining `div` 2
    nextBase <-
      if nextRemaining > 0
        then dotTwo base base >>= evaluate
        else Right base
    powerLoop nextResult nextBase nextRemaining

reduceTakeDrop :: Bool -> [Expr] -> Either EvaluationError Expr
reduceTakeDrop takeMode (subject : specifications@(_ : _)) =
  applySpecifications subject specifications
 where
  operationName = if takeMode then "Take" else "Drop"
  applySpecifications expression [] = Right expression
  applySpecifications expression (specification : remaining) = do
    sliced <- applySpecification expression specification
    if null remaining
      then Right sliced
      else case sliced of
        Call expressionHead values ->
          Call expressionHead <$> traverse (`applySpecifications` remaining) values
        _ -> Left (EvaluationError (operationName <> " encountered an atom before consuming every specification"))
  applySpecification (Call expressionHead values) specification = do
    selected <- specificationIndices takeMode (length values) specification
    pure (Call expressionHead [value | (index, value) <- zip [0 ..] values, index `elem` selected])
  applySpecification _ _ = Left (EvaluationError (operationName <> " expects an expression with arguments"))
reduceTakeDrop takeMode values =
  Right (Call (Symbol (if takeMode then "Take" else "Drop")) values)

specificationIndices :: Bool -> Int -> Expr -> Either EvaluationError [Int]
specificationIndices takeMode count specification = do
  selected <- case specification of
    Symbol "All" -> Right [0 .. count - 1]
    Symbol "None" -> Right []
    Integer amount
      | amount >= 0
      , amount <= toInteger count -> Right [0 .. fromInteger amount - 1]
      | amount < 0
      , abs amount <= toInteger count ->
          Right [count - fromInteger (abs amount) .. count - 1]
      | otherwise -> Left (oversizedIntegerError amount)
    Call (Symbol "List") [Integer position] ->
      maybe (Left invalid) (Right . pure) (resolvePosition count position)
    Call (Symbol "List") [Integer first, Integer last'] ->
      rangePositions first last' 1
    Call (Symbol "List") [Integer first, Integer last', Integer step]
      | step /= 0 -> rangePositions first last' step
    _ -> Left invalid
  pure
    ( if takeMode
        then selected
        else [index | index <- [0 .. count - 1], index `notElem` selected]
    )
 where
  invalid = EvaluationError "Take/Drop received an unsupported or out-of-range specification"
  oversizedIntegerError amount
    | amount > toInteger count =
        EvaluationError
          ( "Part index "
              <> T.pack (show (toInteger count + 1))
              <> " is out of range for length "
              <> T.pack (show count)
              <> "."
          )
    | firstSelector < negate (toInteger count) =
        EvaluationError
          ( "Part index "
              <> T.pack (show firstSelector)
              <> " is out of range for length "
              <> T.pack (show count)
              <> "."
          )
    | otherwise =
        EvaluationError "Only top-level Part specifications may use index 0."
   where
    firstSelector = toInteger count + amount + 1
  rangePositions :: Integer -> Integer -> Integer -> Either EvaluationError [Int]
  rangePositions first last' step = do
    start <- maybe (Left invalid) Right (resolvePosition count first)
    finish <- maybe (Left invalid) Right (resolvePosition count last')
    let startValue = toInteger start
        finishValue = toInteger finish
        indices
          | step > 0 && startValue <= finishValue =
              map fromInteger [startValue, startValue + step .. finishValue]
          | step < 0 && startValue >= finishValue =
              map fromInteger [startValue, startValue + step .. finishValue]
          | otherwise = []
    pure indices

resolvePosition :: Int -> Integer -> Maybe Int
resolvePosition count position
  | position > 0
  , position <= fromIntegral count = Just (fromIntegral position - 1)
  | position < 0
  , position >= negate (fromIntegral count) = Just (count + fromIntegral position)
  | otherwise = Nothing

reduceJoin :: [Expr] -> Expr
reduceJoin values
  | Just entryLists <- traverse associationEntries values =
      associationExpr (concat entryLists)
reduceJoin values = case values of
  Call expressionHead _ : _ ->
    case traverse (matchingArguments expressionHead) values of
      Just argumentLists -> Call expressionHead (concat argumentLists)
      Nothing -> Call (Symbol "Join") values
   where
    matchingArguments expected (Call actual arguments')
      | actual == expected = Just arguments'
    matchingArguments _ _ = Nothing
  _ -> Call (Symbol "Join") values

reduceFlatten :: [Expr] -> Either EvaluationError Expr
reduceFlatten = \case
  [sparse@SparseArray {}] -> sparseArrayFlatten sparse Nothing
  [sparse@SparseArray {}, Symbol infinityName]
    | systemHeadIn ["Infinity"] infinityName -> sparseArrayFlatten sparse Nothing
  [sparse@SparseArray {}, Integer level]
    | level >= 0 -> sparseArrayFlatten sparse (Just level)
    | otherwise ->
        Left (EvaluationError "Flatten levels must be non-negative.")
  [SparseArray {}, _, _] ->
    Left
      ( EvaluationError
          "Flatten currently does not implement the 3-argument head-selecting form for SparseArray inputs."
      )
  [SparseArray {}, _] ->
    Left
      ( EvaluationError
          "Flatten levels must be a non-negative integer or Infinity."
      )
  [subject@(Call expressionHead _)] ->
    Right (flattenSameHead expressionHead Nothing subject)
  [subject@(Call expressionHead _), Symbol infinityName]
    | systemHeadIn ["Infinity"] infinityName ->
        Right (flattenSameHead expressionHead Nothing subject)
  [subject@(Call expressionHead _), Integer level]
    | level >= 0 ->
        Right (flattenSameHead expressionHead (Just (fromIntegral level)) subject)
  [subject@(Call _ _), levelSpecification, targetHead]
    | Just level <- flattenLevel levelSpecification ->
        Right (flattenNamedHead targetHead level subject)
  values -> Right (Call (Symbol "Flatten") values)
 where
  flattenLevel (Symbol "Infinity") = Just Nothing
  flattenLevel (Integer level) | level >= 0 = Just (Just (fromIntegral level))
  flattenLevel _ = Nothing

sparseArrayFlatten
  :: Expr
  -> Maybe Integer
  -> Either EvaluationError Expr
sparseArrayFlatten sparse@(SparseArray dimensions entries fill) requestedLevel
  | requestedLevel == Just 0 || rank <= 1 = Right sparse
  | otherwise =
      canonicalSparseArray
        newDimensions
        [ ( sparseLinearIndex
              (take collapseCount indices)
              collapsedDimensions
              + 1
              : drop collapseCount indices
          , value
          )
        | SparseEntry indices value <- entries
        ]
        fill
 where
  rank = length dimensions
  collapseCount = case requestedLevel of
    Nothing -> rank
    Just level -> fromInteger (min (toInteger rank) (level + 1))
  collapsedDimensions = take collapseCount dimensions
  newDimensions = product collapsedDimensions : drop collapseCount dimensions
sparseArrayFlatten _ _ =
  Left (EvaluationError "Flatten currently expects a SparseArray value.")

flattenSameHead :: Expr -> Maybe Int -> Expr -> Expr
flattenSameHead target remaining expression@(Call expressionHead values)
  | remaining == Just 0 = expression
  | expressionHead /= target = expression
  | otherwise = Call expressionHead (concatMap expand values)
 where
  next = fmap (subtract 1) remaining
  expand child@(Call childHead _)
    | childHead == target = arguments (flattenSameHead target next child)
  expand child = [child]
flattenSameHead _ _ expression = expression

flattenNamedHead :: Expr -> Maybe Int -> Expr -> Expr
flattenNamedHead _ (Just 0) expression = expression
flattenNamedHead target remaining (Call expressionHead values) =
  Call expressionHead (concatMap expand values)
 where
  next = fmap (subtract 1) remaining
  expand child@(Call childHead _)
    | childHead == target = arguments (flattenNamedHead target next child)
    | otherwise = [flattenNamedHead target remaining child]
  expand child = [child]
flattenNamedHead _ _ expression = expression

reduceDelete :: [Expr] -> Either EvaluationError Expr
reduceDelete [subject, positions] =
  foldM deleteOne subject (sortOperationPaths (positionPaths positions))
 where
  deleteOne expression path = case deleteAtPath path expression of
    Just result -> Right result
    Nothing -> Left (EvaluationError "Delete received an invalid position")
reduceDelete values = Right (Call (Symbol "Delete") values)

reduceInsert :: [Expr] -> Either EvaluationError Expr
reduceInsert [subject, item, positions] =
  foldM insertOne subject (sortOperationPaths (positionPaths positions))
 where
  insertOne expression path = case insertAtPath path item expression of
    Just result -> Right result
    Nothing -> Left (EvaluationError "Insert received an invalid position")
reduceInsert values = Right (Call (Symbol "Insert") values)

reduceReplacePart :: [Expr] -> Expr
reduceReplacePart [subject, replacements] =
  foldl applyReplacement subject (sortReplacementRules (replacePartRules replacements))
 where
  applyReplacement expression (path, Symbol "Nothing") =
    maybe expression id (deleteAtPath path expression)
  applyReplacement expression (path, replacement) =
    maybe expression id (replaceAtPath path replacement expression)
reduceReplacePart values = Call (Symbol "ReplacePart") values

reduceMapAt :: [Expr] -> Expr
reduceMapAt [function, subject, positions] =
  foldl applyAt subject (sortOperationPaths (positionPaths positions))
 where
  applyAt expression path =
    maybe expression id (mapAtPath path function expression)
reduceMapAt values = Call (Symbol "MapAt") values

positionPaths :: Expr -> [[PathSelector]]
positionPaths expression
  | Just selector <- pathSelector expression = [[selector]]
positionPaths (Call (Symbol "List") values)
  | Just path <- traverse pathSelector values = [path]
  | otherwise = concatMap listPath values
 where
  listPath (Call (Symbol "List") components) = maybe [] pure (traverse pathSelector components)
  listPath _ = []
positionPaths _ = []

operationPositionPaths :: Expr -> Maybe [[PathSelector]]
operationPositionPaths expression
  | Just selector <- pathSelector expression = Just [[selector]]
operationPositionPaths (Call (Symbol "List") values)
  | Just path <- traverse pathSelector values = Just [path]
  | otherwise = traverse explicitPath values
 where
  explicitPath (Call (Symbol "List") components) =
    traverse pathSelector components
  explicitPath _ = Nothing
operationPositionPaths _ = Nothing

pathSelector :: Expr -> Maybe PathSelector
pathSelector (Integer position) = Just (ArgumentSelector position)
pathSelector selector
  | Just key <- keySelectorValue selector = Just (KeySelector key)
pathSelector _ = Nothing

hasMultiplePositionPaths :: Expr -> Bool
hasMultiplePositionPaths (Call (Symbol "List") values) =
  case traverse pathSelector values of
    Just _ -> False
    Nothing -> any isExplicitPath values
 where
  isExplicitPath (Call (Symbol "List") components) =
    maybe False (const True) (traverse pathSelector components)
  isExplicitPath _ = False
hasMultiplePositionPaths _ = False

replacePartRules :: Expr -> [([PathSelector], Expr)]
replacePartRules (Call (Symbol "List") rules) = concatMap replacePartRules rules
replacePartRules (Call (Symbol ruleHead) [position, replacement])
  | ruleHead `elem` ["Rule", "RuleDelayed"] =
      [(path, replacement) | path <- positionPaths position]
replacePartRules _ = []

sortOperationPaths :: [[PathSelector]] -> [[PathSelector]]
sortOperationPaths = sortBy compareOperationPath

sortReplacementRules :: [([PathSelector], Expr)] -> [([PathSelector], Expr)]
sortReplacementRules = sortBy (\(left, _) (right, _) -> compareOperationPath left right)

compareOperationPath :: [PathSelector] -> [PathSelector] -> Ordering
compareOperationPath left right = case compare (length right) (length left) of
  EQ -> compareSelectors right left
  ordering -> ordering
 where
  compareSelectors [] [] = EQ
  compareSelectors [] (_ : _) = LT
  compareSelectors (_ : _) [] = GT
  compareSelectors (leftSelector : leftRest) (rightSelector : rightRest) =
    case compareSelector leftSelector rightSelector of
      EQ -> compareSelectors leftRest rightRest
      ordering -> ordering
  compareSelector (ArgumentSelector leftPosition) (ArgumentSelector rightPosition) =
    compare leftPosition rightPosition
  compareSelector (KeySelector leftKey) (KeySelector rightKey) =
    compare (fullForm leftKey) (fullForm rightKey)
  compareSelector ArgumentSelector {} KeySelector {} = LT
  compareSelector KeySelector {} ArgumentSelector {} = GT

selectAtPath :: [PathSelector] -> Expr -> Maybe Expr
selectAtPath [] expression = Just expression
selectAtPath (ArgumentSelector 0 : remaining) (Call expressionHead _) =
  selectAtPath remaining expressionHead
selectAtPath (selector : remaining) association
  | Just entries <- associationEntries association = do
      entry <- associationEntryForSelector selector entries
      selectAtPath remaining (associationEntryValue entry)
selectAtPath (ArgumentSelector position : remaining) (Call _ values) = do
  index <- resolvePosition (length values) position
  selectAtPath remaining (values !! index)
selectAtPath _ _ = Nothing

deleteAtPath :: [PathSelector] -> Expr -> Maybe Expr
deleteAtPath [] _ = Nothing
deleteAtPath [ArgumentSelector 0] (Call _ values) =
  Just (Call (Symbol "Sequence") values)
deleteAtPath (ArgumentSelector 0 : remaining) (Call expressionHead values) = do
  updatedHead <- deleteAtPath remaining expressionHead
  Just (Call updatedHead values)
deleteAtPath [selector] association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      pure (associationExpr (take index entries <> drop (index + 1) entries))
deleteAtPath (selector : remaining) association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- deleteAtPath remaining (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
deleteAtPath [ArgumentSelector position] (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  pure (Call expressionHead (take index values <> drop (index + 1) values))
deleteAtPath (ArgumentSelector position : remaining) (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- deleteAtPath remaining (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
deleteAtPath _ _ = Nothing

replaceAtPath :: [PathSelector] -> Expr -> Expr -> Maybe Expr
replaceAtPath [] replacement _ = Just replacement
replaceAtPath (ArgumentSelector 0 : remaining) replacement (Call expressionHead values) = do
  updatedHead <- replaceAtPath remaining replacement expressionHead
  Just (Call updatedHead values)
replaceAtPath (selector : remaining) replacement association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- replaceAtPath remaining replacement (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
replaceAtPath (ArgumentSelector position : remaining) replacement (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- replaceAtPath remaining replacement (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
replaceAtPath _ _ _ = Nothing

mapAtPath :: [PathSelector] -> Expr -> Expr -> Maybe Expr
mapAtPath [] function expression = Just (Call function [expression])
mapAtPath (selector : remaining) function association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- mapAtPath remaining function (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
mapAtPath (ArgumentSelector position : remaining) function (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- mapAtPath remaining function (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
mapAtPath _ _ _ = Nothing

replaceAssociationEntryValue :: Int -> Expr -> [AssociationEntry] -> [AssociationEntry]
replaceAssociationEntryValue index replacement entries =
  case entries !! index of
    AssociationEntry ruleHead key _ ->
      replaceListIndex index (AssociationEntry ruleHead key replacement) entries

insertAtPath :: [PathSelector] -> Expr -> Expr -> Maybe Expr
insertAtPath [] _ _ = Nothing
insertAtPath (selector : remaining@(_ : _)) item association
  | Just entries <- associationEntries association = do
      index <- associationEntryIndex selector entries
      updated <- insertAtPath remaining item (associationEntryValue (entries !! index))
      pure (associationExpr (replaceAssociationEntryValue index updated entries))
insertAtPath [ArgumentSelector position] item (Call expressionHead values) = do
  index <- insertOffset (length values) position
  pure (Call expressionHead (take index values <> [item] <> drop index values))
insertAtPath (ArgumentSelector position : remaining) item (Call expressionHead values) = do
  index <- resolvePosition (length values) position
  updated <- insertAtPath remaining item (values !! index)
  pure (Call expressionHead (replaceListIndex index updated values))
insertAtPath _ _ _ = Nothing

insertOffset :: Int -> Integer -> Maybe Int
insertOffset count position
  | position == 0 = Just 0
  | position > 0 = valid (fromIntegral position - 1)
  | otherwise = valid (count + fromIntegral position + 1)
 where
  valid index = if index >= 0 && index <= count then Just index else Nothing

replaceListIndex :: Int -> value -> [value] -> [value]
replaceListIndex index replacement values =
  take index values <> [replacement] <> drop (index + 1) values

reduceMap :: [Expr] -> Expr
reduceMap [function, association]
  | Just entries <- associationEntries association =
      associationExpr
        [ AssociationEntry ruleHead key (Call function [value])
        | AssociationEntry ruleHead key value <- entries
        ]
reduceMap [function, Call expressionHead values] =
  Call expressionHead [Call function [value] | value <- values]
reduceMap values = Call (Symbol "Map") values

reduceMapAll :: [Expr] -> Either EvaluationError Expr
reduceMapAll values =
  case stripMapAllHeadsOption values of
    (_includeHeads, [_function]) ->
      Right (Call (Symbol "MapAll") values)
    (includeHeads, [function, subject]) ->
      mapAllTree includeHeads function subject
    _ ->
      Left
        ( EvaluationError
            "MapAll currently supports exactly two arguments."
        )

stripMapAllHeadsOption :: [Expr] -> (Bool, [Expr])
stripMapAllHeadsOption values = case reverse values of
  Call (Symbol ruleHead) [Symbol "Heads", Symbol value] : rest
    | systemHeadIn ["Rule", "RuleDelayed"] ruleHead
    , value `elem` ["True", "False"] ->
        (value == "True", reverse rest)
  _ -> (False, values)

mapAllTree :: Bool -> Expr -> Expr -> Either EvaluationError Expr
mapAllTree includeHeads function expression
  | Just entries <- associationEntries expression = do
      mappedEntries <- traverse mapEntry entries
      applyTraversalCallable function [associationExpr mappedEntries]
  | Call expressionHead values <- expression = do
      mappedValues <- traverse (mapAllTree includeHeads function) values
      mappedHead <-
        if includeHeads
          then mapAllTree includeHeads function expressionHead
          else Right expressionHead
      applyTraversalCallable
        function
        [normalizeEvaluatedCall mappedHead mappedValues]
  | otherwise = applyTraversalCallable function [expression]
 where
  mapEntry (AssociationEntry ruleHead key value) =
    AssociationEntry ruleHead key <$> mapAllTree includeHeads function value

reduceMapApply :: [Expr] -> Either EvaluationError Expr
reduceMapApply = \case
  [function] -> Right (Call (Symbol "MapApply") [function])
  [function, subject] -> mapApplyImmediate function subject
  [function, subject, levelSpecification] -> do
    bounds <- normalizeLevelSpec levelSpecification
    mapApplyTree function bounds 0 subject
  _ ->
    Left
      ( EvaluationError
          "MapApply expects a function, an expression, and an optional level specification."
      )

mapApplyImmediate :: Expr -> Expr -> Either EvaluationError Expr
mapApplyImmediate function expression
  | Just entries <- associationEntries expression =
      associationExpr <$> traverse mapEntry entries
  | Call expressionHead values <- expression =
      normalizeEvaluatedCall expressionHead
        <$> traverse (applyTraversalHead function) values
  | otherwise = Right expression
 where
  mapEntry (AssociationEntry ruleHead key value) =
    AssociationEntry ruleHead key <$> applyTraversalHead function value

mapApplyTree
  :: Expr
  -> LevelBounds
  -> Int
  -> Expr
  -> Either EvaluationError Expr
mapApplyTree function bounds positive expression
  | Just entries <- associationEntries expression = do
      mappedEntries <- traverse mapEntry entries
      let rebuilt = associationExpr mappedEntries
      if selected
        then applyTraversalHead function rebuilt
        else Right rebuilt
  | Call expressionHead values <- expression = do
      mappedValues <-
        traverse (mapApplyTree function bounds (positive + 1)) values
      let rebuilt = normalizeEvaluatedCall expressionHead mappedValues
      if selected
        then applyTraversalHead function rebuilt
        else Right rebuilt
  | otherwise = Right expression
 where
  selected =
    positive >= 1
      && levelMatches
        bounds
        positive
        (negate (expressionDepth expression))
  mapEntry (AssociationEntry ruleHead key value) =
    AssociationEntry ruleHead key
      <$> mapApplyTree function bounds (positive + 1) value

applyTraversalHead :: Expr -> Expr -> Either EvaluationError Expr
applyTraversalHead function expression
  | Just entries <- associationEntries expression =
      applyTraversalCallable
        function
        [value | AssociationEntry _ _ value <- entries]
  | Call _ values <- expression = applyTraversalCallable function values
  | otherwise = Right expression

applyTraversalCallable :: Expr -> [Expr] -> Either EvaluationError Expr
applyTraversalCallable (Symbol nothingHead) _
  | systemHeadIn ["Nothing"] nothingHead = Right (Symbol "Nothing")
applyTraversalCallable function values = evaluate (Call function values)

reduceApply :: [Expr] -> Expr
reduceApply [newHead, association]
  | Just entries <- associationEntries association =
      Call newHead [value | AssociationEntry _ _ value <- entries]
reduceApply [newHead, Call _ values] = Call newHead values
reduceApply values = Call (Symbol "Apply") values

data PatternRule = PatternRule !Expr !Expr
  deriving (Eq, Show)

reduceReplace :: [Expr] -> Either EvaluationError Expr
reduceReplace = \case
  [expression, rules] -> replaceAtLevels expression rules (Call (Symbol "List") [Integer 0])
  [expression, rules, specification] -> replaceAtLevels expression rules specification
  values -> Right (Call (Symbol "Replace") values)
 where
  replaceAtLevels expression rules specification
    | Just nested <- nestedPatternRuleSets rules =
        evaluatedList <$> traverse (\ruleset -> replaceAtLevels expression ruleset specification) nested
    | otherwise = do
        ruleset <- requirePatternRuleSet "Replace" rules
        bounds <- normalizeLevelSpec specification
        let records =
              [ record
              | record@(PatternPathRecord _ positive negative _) <- collectPatternPathRecords 0 [] expression
              , levelMatches bounds positive negative
              ]
        foldM (replaceRecord ruleset) expression records
  replaceRecord ruleset current (PatternPathRecord _ _ _ path) = do
    selected <-
      maybe
        (Left (EvaluationError "Replace encountered an invalid selected path"))
        Right
        (selectAtPath path current)
    replacement <- applyPatternRules ruleset selected
    pure $ case replacement of
      Nothing -> current
      Just value -> maybe current id (replaceAtPath path value current)

reduceReplaceAt :: [Expr] -> Either EvaluationError Expr
reduceReplaceAt [expression, rules, positions] = do
  ruleset <- requirePatternRuleSet "ReplaceAt" rules
  paths <-
    maybe
      (Left (EvaluationError "ReplaceAt received an invalid position specification"))
      Right
      (operationPositionPaths positions)
  foldM (replaceSelected ruleset) expression (sortOperationPaths paths)
 where
  replaceSelected ruleset current path = do
    selected <-
      maybe
        (Left (EvaluationError "ReplaceAt encountered an invalid selected path"))
        Right
        (selectAtPath path current)
    replacement <- applyPatternRules ruleset selected
    case replacement of
      Nothing -> Right current
      Just value ->
        maybe
          (Left (EvaluationError "ReplaceAt encountered an invalid selected path"))
          Right
          (replaceAtPath path value current)
reduceReplaceAt _ = Left (EvaluationError "ReplaceAt expects exactly three arguments")

reduceReplaceAll :: [Expr] -> Either EvaluationError Expr
reduceReplaceAll [expression, rules]
  | Just nested <- nestedPatternRuleSets rules =
      evaluatedList <$> traverse (reduceReplaceAll . (expression :) . pure) nested
  | otherwise = do
      ruleset <- requirePatternRuleSet "ReplaceAll" rules
      replaceAllWithRules ruleset expression
reduceReplaceAll values = Right (Call (Symbol "ReplaceAll") values)

reduceReplaceRepeated :: [Expr] -> Either EvaluationError Expr
reduceReplaceRepeated [expression, rules]
  | Just nested <- nestedPatternRuleSets rules =
      evaluatedList <$> traverse (reduceReplaceRepeated . (expression :) . pure) nested
 | otherwise = do
      ruleset <- requirePatternRuleSet "ReplaceRepeated" rules
      iterateReplacement 0 ruleset expression
 where
  iterateReplacement :: Int -> [PatternRule] -> Expr -> Either EvaluationError Expr
  iterateReplacement iterations ruleset current
    | iterations >= 1024 = Left (EvaluationError "ReplaceRepeated exceeded its iteration safety limit")
    | otherwise = do
        updated <- replaceAllWithRules ruleset current
        if updated == current
          then Right current
          else iterateReplacement (iterations + 1) ruleset updated
reduceReplaceRepeated values = Right (Call (Symbol "ReplaceRepeated") values)

requirePatternRuleSet :: Text -> Expr -> Either EvaluationError [PatternRule]
requirePatternRuleSet operation expression =
  maybe
    (Left (EvaluationError (operation <> " expects a rule or flat list of rules")))
    Right
    (patternRuleSet expression)

patternRuleSet :: Expr -> Maybe [PatternRule]
patternRuleSet (Call (Symbol listHead) values)
  | systemHeadIn ["List"] listHead = traverse patternRule values
patternRuleSet expression = pure <$> patternRule expression

patternRule :: Expr -> Maybe PatternRule
patternRule (Call (Symbol ruleHead) [patternExpression, template])
  | systemHeadIn ["Rule", "RuleDelayed"] ruleHead =
      Just (PatternRule patternExpression template)
patternRule _ = Nothing

nestedPatternRuleSets :: Expr -> Maybe [Expr]
nestedPatternRuleSets (Call (Symbol listHead) values@(_ : _))
  | systemHeadIn ["List"] listHead
  , all isRuleList values = Just values
 where
  isRuleList expression@(Call (Symbol nestedListHead) _)
    | systemHeadIn ["List"] nestedListHead =
        maybe False (const True) (patternRuleSet expression)
  isRuleList _ = False
nestedPatternRuleSets _ = Nothing

applyPatternRules :: [PatternRule] -> Expr -> Either EvaluationError (Maybe Expr)
applyPatternRules = applyPatternRulesInContext False

applyPatternRulesInContext
  :: Bool
  -> [PatternRule]
  -> Expr
  -> Either EvaluationError (Maybe Expr)
applyPatternRulesInContext _ [] _ = Right Nothing
applyPatternRulesInContext heldContext (PatternRule patternExpression template : rest) expression =
  case matchPattern [] expression patternExpression of
    Nothing -> applyPatternRulesInContext heldContext rest expression
    Just bindings
      | heldContext -> do
          instantiated <- instantiateHeldPatternTemplate bindings template
          case instantiated of
            Just value -> Right (Just value)
            Nothing -> applyPatternRulesInContext heldContext rest expression
      | otherwise -> do
          instantiated <- instantiatePatternTemplate bindings template
          case instantiated of
            Just value -> Right (Just value)
            Nothing -> applyPatternRulesInContext heldContext rest expression

instantiatePatternTemplate :: PatternBindings -> Expr -> Either EvaluationError (Maybe Expr)
instantiatePatternTemplate bindings (Call (Symbol conditionHead) [template, condition])
  | systemHeadIn ["Condition"] conditionHead = do
      conditionResult <- evaluate (substituteBindings bindings condition)
      if conditionResult == Symbol "True"
        then Just <$> evaluate (substituteBindings bindings template)
        else Right Nothing
instantiatePatternTemplate bindings template =
  Just <$> evaluate (substituteBindings bindings template)

instantiateHeldPatternTemplate
  :: PatternBindings
  -> Expr
  -> Either EvaluationError (Maybe Expr)
instantiateHeldPatternTemplate bindings (Call (Symbol conditionHead) [template, condition])
  | systemHeadIn ["Condition"] conditionHead = do
      conditionResult <- evaluate (substituteBindings bindings condition)
      if conditionResult == Symbol "True"
        then Right (Just (substituteBindings bindings template))
        else Right Nothing
instantiateHeldPatternTemplate bindings template =
  Right (Just (substituteBindings bindings template))

replaceAllWithRules :: [PatternRule] -> Expr -> Either EvaluationError Expr
replaceAllWithRules rules = descendWithContext False
 where
  descendWithContext heldContext expression = do
    rootReplacement <- applyPatternRulesInContext heldContext rules expression
    case rootReplacement of
      Just replacement -> Right replacement
      Nothing -> descend heldContext expression

  descend heldContext association@(Call associationHead@(Symbol _) _)
    | Just entries <- associationEntries association = do
        headReplacement <- descendWithContext heldContext associationHead
        updated <- traverse (replaceEntry heldContext) entries
        pure
          ( if headReplacement == associationHead && updated == entries
              then association
              else if headReplacement == Symbol "Association"
              then associationExpr updated
              else
                Call
                  headReplacement
                  [ Call (Symbol ruleHead) [key, value]
                  | AssociationEntry ruleHead key value <- updated
                  ]
          )
  descend heldContext (Call expressionHead values) = do
    updatedHead <- descendWithContext heldContext expressionHead
    let childHeldContext =
          heldContext || replacementHeldArgumentHead expressionHead
    updatedValues <-
      traverse (descendWithContext childHeldContext) values
    pure
      ( if updatedHead == expressionHead && updatedValues == values
          then Call expressionHead values
          else if heldContext
          then Call updatedHead updatedValues
          else rebuildWithSplicing updatedHead updatedValues
      )
  descend _ value = Right value

  replaceEntry heldContext (AssociationEntry ruleHead key value) = do
    updated <- descendWithContext heldContext value
    pure (AssociationEntry ruleHead key updated)

replacementHeldArgumentHead :: Expr -> Bool
replacementHeldArgumentHead (Symbol name) =
  name
    `elem` [ "Function"
           , "Hold"
           , "HoldComplete"
           , "HoldForm"
           , "HoldPattern"
           , "Unevaluated"
           ]
replacementHeldArgumentHead _ = False

rebuildWithSplicing :: Expr -> [Expr] -> Expr
rebuildWithSplicing expressionHead values =
  Call expressionHead (filterNothing spliced)
 where
  spliced
    | replacementSuppressesSequences expressionHead = values
    | otherwise = concatMap splice values
  splice (Call (Symbol sequenceHead) sequenceValues)
    | systemHeadIn ["Sequence"] sequenceHead = sequenceValues
  splice value = [value]
  filterNothing
    | expressionHead `elem` [Symbol "Association", Symbol "List"] =
        filter (/= Symbol "Nothing")
    | otherwise = id

replacementSuppressesSequences :: Expr -> Bool
replacementSuppressesSequences (Symbol name) =
  name
    `elem` [ "HoldComplete"
           , "Rule"
           , "RuleDelayed"
           , "Unevaluated"
           ]
replacementSuppressesSequences _ = False

applyFunctionWithHead
  :: Expr
  -> [Expr]
  -> [Expr]
  -> Either EvaluationError Expr
applyFunctionWithHead functionHead functionArguments values = case functionArguments of
  [body] -> applyPositional body
  [parameter, body]
    | isNullFunctionParameter parameter -> applyPositional body
    | otherwise -> applyNamed parameter body
  [parameter, body, _]
    | isNullFunctionParameter parameter -> applyPositional body
    | otherwise -> applyNamed parameter body
  _ -> unsupported
 where
  selfFunction = Call functionHead functionArguments
  applyPositional = substituteSlots selfFunction values
  applyNamed parameter body = case namedParameterNames parameter of
    Just names
      | length values >= length names ->
          Right
            ( substituteNamedSymbols
                (Map.fromList (zip names values))
                body
            )
      | otherwise -> unsupported
    Nothing -> unsupported
  unsupported = Right (Call selfFunction values)

-- | Substitute already prepared call arguments into a held pure Function
-- body without evaluating that body.
instantiateFunctionCall :: [Expr] -> [Expr] -> Either EvaluationError Expr
instantiateFunctionCall = instantiateFunctionCallWithHead (Symbol "Function")

instantiateFunctionCallWithHead
  :: Expr
  -> [Expr]
  -> [Expr]
  -> Either EvaluationError Expr
instantiateFunctionCallWithHead functionHead functionArguments values = case functionArguments of
  [_] -> apply functionArguments values
  [parameter, _] -> validateParameter parameter
  [parameter, _, _] -> validateParameter parameter
  _ -> apply functionArguments values
 where
  apply = applyFunctionWithHead functionHead
  validateParameter parameter
    | isNullFunctionParameter parameter = apply functionArguments values
    | Just names <- namedParameterNames parameter =
        if length values < length names
          then
            Left
              ( EvaluationError
                  ( "Function expects "
                      <> T.pack (show (length names))
                      <> " named argument(s), but only "
                      <> T.pack (show (length values))
                      <> " were supplied."
                  )
              )
          else apply functionArguments values
    | otherwise =
        Left (EvaluationError "Unsupported Function parameter specification.")

substituteSlots :: Expr -> [Expr] -> Expr -> Either EvaluationError Expr
substituteSlots selfFunction values expression
  | Just slotResult <- positionalSlotValue expression = slotResult
  | otherwise = case slotSequenceValues expression of
      Left evaluationError -> Left evaluationError
      Right (Just replacements) -> Right (Call (Symbol "Sequence") replacements)
      Right Nothing -> case expression of
        nestedFunction@(Call (Symbol functionHead) functionArguments)
          | isFunctionHead functionHead
          , positionalFunctionArguments functionArguments -> Right nestedFunction
        Call expressionHead arguments' -> do
          substitutedHead <- substituteSlots selfFunction values expressionHead
          substitutedArguments <- concat <$> traverse substituteArgument arguments'
          Right (Call substitutedHead substitutedArguments)
        _ -> Right expression
 where
  positionalSlotValue :: Expr -> Maybe (Either EvaluationError Expr)
  positionalSlotValue (Call (Symbol slotHead) [])
    | systemHeadIn ["Slot"] slotHead = fillSlot 1
  positionalSlotValue (Call (Symbol slotHead) [Integer 0])
    | systemHeadIn ["Slot"] slotHead =
        Just (Right selfFunction)
  positionalSlotValue (Call (Symbol slotHead) [Integer index])
    | systemHeadIn ["Slot"] slotHead
    , index < 0 =
        Just (Left (EvaluationError "Slot indices must be non-negative integers."))
    | systemHeadIn ["Slot"] slotHead = fillSlot index
  positionalSlotValue (Call (Symbol slotHead) [String key])
    | systemHeadIn ["Slot"] slotHead =
        Just (namedSlotValue key)
  positionalSlotValue (Call (Symbol slotHead) arguments')
    | systemHeadIn ["Slot"] slotHead =
        Just
          ( Left
              ( EvaluationError
                  ( if length arguments' <= 1
                      then "Slot expects an integer index or a string name."
                      else "Slot expects zero arguments or a single index."
                  )
              )
          )
  positionalSlotValue _ = Nothing

  fillSlot :: Integer -> Maybe (Either EvaluationError Expr)
  fillSlot index
    | index > 0
    , index <= fromIntegral (length values) =
        Just (Right (values !! fromIntegral (index - 1)))
    | otherwise =
        Just
          ( Left
              ( EvaluationError
                  ( "Slot "
                      <> T.pack (show index)
                      <> " cannot be filled from "
                      <> T.pack (show (length values))
                      <> " argument(s)."
                  )
              )
          )

  namedSlotValue :: Text -> Either EvaluationError Expr
  namedSlotValue key = case values of
    [] ->
      Left
        ( EvaluationError
            ( "Named Slot '"
                <> key
                <> "' cannot be filled from zero argument(s)."
            )
        )
    first : _ -> case associationEntries first of
      Just _ -> reduceLookup [first, String key]
      Nothing -> Right (Call first [String key])

  slotSequenceValues :: Expr -> Either EvaluationError (Maybe [Expr])
  slotSequenceValues (Call (Symbol slotHead) [])
    | systemHeadIn ["SlotSequence"] slotHead = Right (Just values)
  slotSequenceValues (Call (Symbol slotHead) [Integer index])
    | systemHeadIn ["SlotSequence"] slotHead
    , index > 0 = Right (Just (dropInteger (index - 1) values))
    | systemHeadIn ["SlotSequence"] slotHead =
        Left
          (EvaluationError "SlotSequence indices must be positive integers.")
  slotSequenceValues (Call (Symbol slotHead) _)
    | systemHeadIn ["SlotSequence"] slotHead =
        Left
          ( EvaluationError
              "SlotSequence expects zero arguments or a single positive integer index."
          )
  slotSequenceValues _ = Right Nothing

  substituteArgument :: Expr -> Either EvaluationError [Expr]
  substituteArgument argument = do
    sequenceValues <- slotSequenceValues argument
    case sequenceValues of
      Just replacements -> Right replacements
      Nothing -> pure <$> substituteSlots selfFunction values argument

  positionalFunctionArguments :: [Expr] -> Bool
  positionalFunctionArguments = \case
    [_] -> True
    [parameter, _] -> isNullFunctionParameter parameter
    [parameter, _, _] -> isNullFunctionParameter parameter
    _ -> False

  isFunctionHead :: Text -> Bool
  isFunctionHead name = name == "Function" || name == "System`Function"

dropInteger :: Integer -> [value] -> [value]
dropInteger count values
  | count <= 0 = values
dropInteger _ [] = []
dropInteger count (_ : remaining) = dropInteger (count - 1) remaining

-- | Capture-aware simultaneous substitution for named Wolfram symbols.
-- Binding right-hand sides remain in their outer scope, while named Function
-- parameters and valid With/Module/Block locals shield their bodies.  When a
-- substitution reaches a shielded body, its binders are alpha-renamed using
-- the Python engine's deterministic @$@, @$1@, ... naming policy.
substituteNamedSymbols :: Map.Map Text Expr -> Expr -> Expr
substituteNamedSymbols substitutions expression =
  fst (substituteNamedSymbolsAt substitutions unavailable expression)
 where
  unavailable =
    Set.unions
      ( Map.keysSet substitutions
          : map collectSymbolNames (Map.elems substitutions)
      )

substituteNamedSymbolsAt
  :: Map.Map Text Expr
  -> Set.Set Text
  -> Expr
  -> (Expr, Bool)
substituteNamedSymbolsAt substitutions unavailable expression
  | Map.null substitutions = (expression, False)
  | otherwise = case expression of
      Symbol name -> case Map.lookup name substitutions of
        Nothing -> (expression, False)
        Just replacement -> (replacement, True)
      Call {} ->
        case localScopingCallParts expression of
          Just (boundNames, bindingArguments, body) ->
            substituteThroughLocalScoping
              expression
              boundNames
              bindingArguments
              body
              substitutions
              unavailable
          Nothing -> case namedFunctionParts expression of
            Just (parameter, parameterNames, body, remaining) ->
              substituteThroughNamedFunction
                expression
                parameter
                parameterNames
                body
                remaining
                substitutions
                unavailable
            Nothing -> substituteThroughCall substitutions unavailable expression
      _ -> (expression, False)

substituteThroughCall
  :: Map.Map Text Expr
  -> Set.Set Text
  -> Expr
  -> (Expr, Bool)
substituteThroughCall substitutions unavailable expression = case expression of
  Call expressionHead values ->
    let (substitutedHead, headChanged) =
          substituteNamedSymbolsAt substitutions unavailable expressionHead
        substitutedValues =
          map (substituteNamedSymbolsAt substitutions unavailable) values
        changed = headChanged || any snd substitutedValues
     in if changed
          then (Call substitutedHead (map fst substitutedValues), True)
          else (expression, False)
  _ -> (expression, False)

substituteThroughNamedFunction
  :: Expr
  -> Expr
  -> [Text]
  -> Expr
  -> [Expr]
  -> Map.Map Text Expr
  -> Set.Set Text
  -> (Expr, Bool)
substituteThroughNamedFunction
  original
  parameter
  parameterNames
  body
  remaining
  substitutions
  unavailable =
    let activeSubstitutions =
          foldr Map.delete substitutions parameterNames
     in if Map.null activeSubstitutions
          then (original, False)
          else
            let (_, bodyChanged) =
                  substituteNamedSymbolsAt
                    activeSubstitutions
                    (Set.union unavailable (Set.fromList parameterNames))
                    body
             in if not bodyChanged
                  then (original, False)
                  else
                    let renameUnavailable =
                          Set.unions
                            ( [ unavailable
                              , collectSymbolNames parameter
                              , collectSymbolNames body
                              ]
                                <> map
                                  collectSymbolNames
                                  (Map.elems activeSubstitutions)
                            )
                        (freshNames, _) =
                          freshSymbolNames parameterNames renameUnavailable
                        renameMap = Map.fromList (zip parameterNames freshNames)
                        renamedBody = renameBoundSymbolsInExpr renameMap body
                        (substitutedBody, _) =
                          substituteNamedSymbolsAt
                            activeSubstitutions
                            (Set.union unavailable (Set.fromList freshNames))
                            renamedBody
                     in ( rebuildNamedFunctionLike
                            original
                            parameter
                            freshNames
                            substitutedBody
                            remaining
                        , True
                        )

substituteThroughLocalScoping
  :: Expr
  -> [Text]
  -> [Expr]
  -> Expr
  -> Map.Map Text Expr
  -> Set.Set Text
  -> (Expr, Bool)
substituteThroughLocalScoping
  original
  boundNames
  bindingArguments
  body
  substitutions
  unavailable =
    let substitutedBindings =
          map (substituteBindingRhs substitutions unavailable) bindingArguments
        newBindingArguments = map fst substitutedBindings
        bindingsChanged = any snd substitutedBindings
        activeSubstitutions = foldr Map.delete substitutions boundNames
        rebuild bindings scopedBody = case original of
          Call expressionHead _ ->
            Call
              expressionHead
              [Call (Symbol "List") bindings, scopedBody]
          _ -> original
     in if Map.null activeSubstitutions
          then
            if bindingsChanged
              then (rebuild newBindingArguments body, True)
              else (original, False)
          else
            let (_, bodyChanged) =
                  substituteNamedSymbolsAt
                    activeSubstitutions
                    (Set.union unavailable (Set.fromList boundNames))
                    body
             in if not bodyChanged
                  then
                    if bindingsChanged
                      then (rebuild newBindingArguments body, True)
                      else (original, False)
                  else
                    let renameUnavailable =
                          Set.unions
                            ( [ unavailable
                              , Set.fromList boundNames
                              , collectSymbolNames body
                              ]
                                <> map collectSymbolNames newBindingArguments
                                <> map
                                  collectSymbolNames
                                  (Map.elems activeSubstitutions)
                            )
                        (freshNames, _) =
                          freshSymbolNames boundNames renameUnavailable
                        renameMap = Map.fromList (zip boundNames freshNames)
                        renamedBindings =
                          zipWith renameBindingName newBindingArguments freshNames
                        renamedBody = renameBoundSymbolsInExpr renameMap body
                        (substitutedBody, _) =
                          substituteNamedSymbolsAt
                            activeSubstitutions
                            (Set.union unavailable (Set.fromList freshNames))
                            renamedBody
                     in (rebuild renamedBindings substitutedBody, True)

substituteBindingRhs
  :: Map.Map Text Expr
  -> Set.Set Text
  -> Expr
  -> (Expr, Bool)
substituteBindingRhs substitutions unavailable binding = case binding of
  Symbol _ -> (binding, False)
  Call bindingHead [name, rhs] ->
    let (substitutedRhs, changed) =
          substituteNamedSymbolsAt substitutions unavailable rhs
     in if changed
          then (Call bindingHead [name, substitutedRhs], True)
          else (binding, False)
  _ -> (binding, False)

renameBindingName :: Expr -> Text -> Expr
renameBindingName binding freshName = case binding of
  Symbol _ -> Symbol freshName
  Call bindingHead [_, rhs] ->
    Call bindingHead [Symbol freshName, rhs]
  _ -> binding

renameBoundSymbolsInExpr :: Map.Map Text Text -> Expr -> Expr
renameBoundSymbolsInExpr renameMap expression
  | Map.null renameMap = expression
  | otherwise = case expression of
      Symbol name -> maybe expression Symbol (Map.lookup name renameMap)
      Call expressionHead values ->
        case localScopingCallParts expression of
          Just (boundNames, bindingArguments, body) ->
            let boundSet = Set.fromList boundNames
                nestedRenameMap = foldr Map.delete renameMap boundNames
                observedShadow =
                  not
                    ( Set.null
                        (Set.intersection (Map.keysSet renameMap) boundSet)
                    )
             in if Map.null nestedRenameMap && not observedShadow
                  then expression
                  else
                    Call
                      expressionHead
                      [ Call
                          (Symbol "List")
                          (map (renameBindingRhs renameMap) bindingArguments)
                      , renameBoundSymbolsInExpr nestedRenameMap body
                      ]
          Nothing -> case namedFunctionParts expression of
            Just (parameter, parameterNames, body, remaining) ->
              let nestedRenameMap =
                    foldr Map.delete renameMap parameterNames
               in if Map.null nestedRenameMap
                    then expression
                    else
                      rebuildNamedFunctionLike
                        expression
                        parameter
                        parameterNames
                        (renameBoundSymbolsInExpr nestedRenameMap body)
                        remaining
            Nothing ->
              Call
                (renameBoundSymbolsInExpr renameMap expressionHead)
                (map (renameBoundSymbolsInExpr renameMap) values)
      _ -> expression

renameBindingRhs :: Map.Map Text Text -> Expr -> Expr
renameBindingRhs renameMap binding = case binding of
  Symbol _ -> binding
  Call bindingHead [name, rhs] ->
    Call bindingHead [name, renameBoundSymbolsInExpr renameMap rhs]
  _ -> binding

localScopingCallParts :: Expr -> Maybe ([Text], [Expr], Expr)
localScopingCallParts = \case
  Call (Symbol headName) [Call (Symbol listHead) bindings, body]
    | systemHeadIn ["With", "Module", "Block"] headName
    , systemHeadIn ["List"] listHead -> do
        boundNames <- traverse localBindingName bindings
        Just (boundNames, bindings, body)
  _ -> Nothing
 where
  localBindingName = \case
    Symbol name -> Just name
    Call (Symbol bindingHead) [Symbol name, _]
      | systemHeadIn ["Set", "SetDelayed"] bindingHead -> Just name
    _ -> Nothing

namedFunctionParts :: Expr -> Maybe (Expr, [Text], Expr, [Expr])
namedFunctionParts = \case
  Call (Symbol functionHead) (parameter : body : remaining)
    | systemHeadIn ["Function"] functionHead
    , length remaining <= 1 -> do
        names <- namedParameterNames parameter
        Just (parameter, names, body, remaining)
  _ -> Nothing

namedParameterNames :: Expr -> Maybe [Text]
namedParameterNames = \case
  parameter
    | isNullFunctionParameter parameter -> Nothing
  Symbol name -> Just [name]
  Call (Symbol listHead) parameters
    | systemHeadIn ["List"] listHead -> traverse parameterName parameters
  _ -> Nothing
 where
  parameterName = \case
    Symbol name -> Just name
    _ -> Nothing

isNullFunctionParameter :: Expr -> Bool
isNullFunctionParameter (Symbol name) =
  name `elem` ["Null", "System`Null"]
isNullFunctionParameter _ = False

rebuildNamedFunctionLike :: Expr -> Expr -> [Text] -> Expr -> [Expr] -> Expr
rebuildNamedFunctionLike original originalParameter parameterNames body remaining =
  Call
    functionHead
    ( rebuildParameter originalParameter parameterNames
        : body
        : remaining
    )
 where
  functionHead = case original of
    Call headExpression _ -> headExpression
    _ -> Symbol "Function"
  rebuildParameter parameter names = case parameter of
    Symbol _ -> case names of
      [name] -> Symbol name
      _ -> parameter
    Call (Symbol listName) _
      | systemHeadIn ["List"] listName ->
          Call (Symbol "List") (map Symbol names)
    _ -> parameter

systemHeadIn :: [Text] -> Text -> Bool
systemHeadIn names name =
  name `elem` names
    || maybe False (`elem` names) (T.stripPrefix "System`" name)

collectSymbolNames :: Expr -> Set.Set Text
collectSymbolNames = \case
  Symbol name -> Set.singleton name
  Call expressionHead values ->
    Set.unions
      (collectSymbolNames expressionHead : map collectSymbolNames values)
  _ -> Set.empty

freshSymbolNames :: [Text] -> Set.Set Text -> ([Text], Set.Set Text)
freshSymbolNames names unavailable = go unavailable names []
 where
  go retained [] freshNames = (reverse freshNames, retained)
  go retained (name : rest) freshNames =
    let freshName = freshSymbolName name retained
     in go (Set.insert freshName retained) rest (freshName : freshNames)

freshSymbolName :: Text -> Set.Set Text -> Text
freshSymbolName baseName unavailable
  | Set.notMember firstCandidate unavailable = firstCandidate
  | otherwise = choose (1 :: Integer)
 where
  firstCandidate = baseName <> "$"
  choose index =
    let candidate = baseName <> "$" <> T.pack (show index)
     in if Set.member candidate unavailable
          then choose (index + 1)
          else candidate

expressionDepth :: Expr -> Int
expressionDepth Root {} = 1
expressionDepth (SparseArray dimensions _ _) = length dimensions + 1
expressionDepth expression
  | Just entries <- associationEntries expression =
      case [value | AssociationEntry _ _ value <- entries] of
        [] -> 2
        values -> 1 + maximum (map expressionDepth values)
expressionDepth (Call _ []) = 2
expressionDepth expression = case arguments expression of
  [] -> 1
  values -> 1 + maximum (map expressionDepth values)

expressionLength :: Expr -> Expr
expressionLength (ByteArray bytes) = Integer (fromIntegral (BS.length bytes))
expressionLength (SparseArray (firstDimension : _) _ _) = Integer firstDimension
expressionLength expression = Integer (fromIntegral (length (arguments expression)))

flattenHead :: Text -> Expr -> [Expr]
flattenHead headName (Call (Symbol actualHead) values)
  | actualHead == headName = values
flattenHead _ expression = [expression]

hasHead :: Text -> Expr -> Bool
hasHead expected (Call (Symbol actual) _) = expected == actual
hasHead _ _ = False

isExact :: Expr -> Bool
isExact = maybe False (const True) . toExact

isInteger :: Expr -> Bool
isInteger Integer {} = True
isInteger _ = False

transparentUnaryPredicate :: Text -> (Expr -> Bool) -> [Expr] -> Expr
transparentUnaryPredicate headName predicate =
  unary headName (boolean . predicate) . map stripDirectUnevaluated
 where
  stripDirectUnevaluated = \case
    Call (Symbol unevaluatedHead) [value]
      | systemHeadIn ["Unevaluated"] unevaluatedHead -> value
    value -> value

isMachineInteger :: Expr -> Bool
isMachineInteger (Integer value) =
  value >= negate (2 ^ (63 :: Integer))
    && value <= 2 ^ (63 :: Integer) - 1
isMachineInteger _ = False

isMachineNumber :: Expr -> Bool
isMachineNumber value@Real {} = isMachineReal value
isMachineNumber (Complex realPart imaginaryPart) =
  isMachineReal realPart && isMachineReal imaginaryPart
isMachineNumber value
  | Just (realPart, imaginaryPart) <- explicitComplexParts value =
      all isExplicitReal [realPart, imaginaryPart]
        && any isMachineReal [realPart, imaginaryPart]
isMachineNumber _ = False

isExactNumber :: Expr -> Bool
isExactNumber value =
  maybe False (const (not (containsInexactReal value))) (numericValueReality value)

isInexactNumber :: Expr -> Bool
isInexactNumber Real {} = True
isInexactNumber value
  | isSpecialRealValue value = True
isInexactNumber (Complex realPart imaginaryPart) =
  containsInexactReal realPart || containsInexactReal imaginaryPart
isInexactNumber value
  | Just (realPart, imaginaryPart) <- explicitComplexParts value =
      containsInexactReal realPart || containsInexactReal imaginaryPart
isInexactNumber _ = False

isNumericValue :: Expr -> Bool
isNumericValue = maybe False (const True) . numericValueReality

isRealValuedNumber :: Expr -> Bool
isRealValuedNumber value = numericValueReality value == Just True

isTrueSymbol :: Expr -> Bool
isTrueSymbol (Symbol "True") = True
isTrueSymbol _ = False

-- Python's numeric predicates use a deliberately bounded symbolic bridge:
-- explicit numeric atoms and Root values, seven named constants, arithmetic,
-- and the supported transcendental family.  The Bool records whether the
-- bridge can also prove that the value is real.
numericValueReality :: Expr -> Maybe Bool
numericValueReality = \case
  Integer {} -> Just True
  Rational {} -> Just True
  Real {} -> Just True
  Complex {} -> Just False
  rootValue@Root {} -> Just (rootValueIsReal rootValue)
  Symbol name -> Map.lookup name numericConstantReality
  special
    | isSpecialRealValue special -> Just True
  rootCall@(Call (Symbol rootHead) _)
    | systemHeadIn ["Root"] rootHead -> rootCallReality rootCall
  Call (Symbol headName) values -> numericCallReality headName values
  _ -> Nothing

numericConstantReality :: Map.Map Text Bool
numericConstantReality =
  Map.fromList
    [ ("Catalan", True)
    , ("Degree", True)
    , ("E", True)
    , ("EulerGamma", True)
    , ("GoldenRatio", True)
    , ("I", False)
    , ("Pi", True)
    ]

numericCallReality :: Text -> [Expr] -> Maybe Bool
numericCallReality headName values
  | headName `elem` ["Plus", "Times"] =
      allNumericReality values
  | headName == "Power" = case values of
      [base, powerExpression] -> do
        baseIsReal <- numericValueReality base
        powerIsReal <- numericValueReality powerExpression
        pure
          ( baseIsReal
              && powerIsReal
              && (isInteger powerExpression || knownNonNegative base)
          )
      _ -> Nothing
  | headName `elem` ["Abs", "Exp", "Sqrt"] = case values of
      [value] -> do
        valueIsReal <- numericValueReality value
        pure $ case headName of
          "Abs" -> True
          "Exp" -> valueIsReal
          _ -> valueIsReal && knownNonNegative value
      _ -> Nothing
  | headName == "Log" = case values of
      [value] -> numericPositiveArgumentsAreReal [value]
      [base, value] -> numericPositiveArgumentsAreReal [base, value]
      _ -> Nothing
  | headName == "ArcTan" = case values of
      [value] -> unaryRealFunction value
      [x, y] -> allNumericReality [x, y]
      _ -> Nothing
  | headName `elem` alwaysRealUnaryNumericHeads = case values of
      [value] -> unaryRealFunction value
      _ -> Nothing
  | headName `elem` boundedRealUnaryNumericHeads = case values of
      [value] -> boundedUnaryReality headName value
      _ -> Nothing
  | otherwise = Nothing

allNumericReality :: [Expr] -> Maybe Bool
allNumericReality values = and <$> traverse numericValueReality values

unaryRealFunction :: Expr -> Maybe Bool
unaryRealFunction value = numericValueReality value

numericPositiveArgumentsAreReal :: [Expr] -> Maybe Bool
numericPositiveArgumentsAreReal values = do
  realities <- traverse numericValueReality values
  pure (and realities && all knownPositive values)

alwaysRealUnaryNumericHeads :: [Text]
alwaysRealUnaryNumericHeads =
  [ "ArcCot"
  , "ArcCotDegrees"
  , "ArcSinh"
  , "ArcTanDegrees"
  , "Cos"
  , "CosDegrees"
  , "Cosh"
  , "Cot"
  , "CotDegrees"
  , "Coth"
  , "Csc"
  , "CscDegrees"
  , "Csch"
  , "Gudermannian"
  , "Haversine"
  , "Sec"
  , "SecDegrees"
  , "Sech"
  , "Sin"
  , "SinDegrees"
  , "Sinh"
  , "Tan"
  , "TanDegrees"
  , "Tanh"
  ]

boundedRealUnaryNumericHeads :: [Text]
boundedRealUnaryNumericHeads =
  [ "ArcCos"
  , "ArcCosDegrees"
  , "ArcCosh"
  , "ArcCoth"
  , "ArcCsc"
  , "ArcCscDegrees"
  , "ArcCsch"
  , "ArcSec"
  , "ArcSecDegrees"
  , "ArcSech"
  , "ArcSin"
  , "ArcSinDegrees"
  , "ArcTanh"
  , "InverseGudermannian"
  , "InverseHaversine"
  ]

boundedUnaryReality :: Text -> Expr -> Maybe Bool
boundedUnaryReality headName value = do
  valueIsReal <- numericValueReality value
  pure
    ( valueIsReal
        && case explicitRealExact value of
          Nothing -> False
          Just exactValue -> case headName of
            "ArcCos" -> inClosedUnitInterval exactValue
            "ArcCosDegrees" -> inClosedUnitInterval exactValue
            "ArcCosh" -> compareExact exactValue oneExact /= LT
            "ArcCoth" -> outsideClosedUnitInterval exactValue
            "ArcCsc" -> outsideOpenUnitInterval exactValue
            "ArcCscDegrees" -> outsideOpenUnitInterval exactValue
            "ArcCsch" -> compareExact exactValue zeroExact /= EQ
            "ArcSec" -> outsideOpenUnitInterval exactValue
            "ArcSecDegrees" -> outsideOpenUnitInterval exactValue
            "ArcSech" ->
              compareExact exactValue zeroExact == GT
                && compareExact exactValue oneExact /= GT
            "ArcSin" -> inClosedUnitInterval exactValue
            "ArcSinDegrees" -> inClosedUnitInterval exactValue
            "ArcTanh" -> inOpenUnitInterval exactValue
            "InverseHaversine" ->
              compareExact exactValue zeroExact /= LT
                && compareExact exactValue oneExact /= GT
            -- The real Gudermannian range is (-Pi/2, Pi/2).  Exact rational
            -- values with magnitude at most one are a safe proved subset.
            "InverseGudermannian" -> inClosedUnitInterval exactValue
            _ -> False
    )
 where
  zeroExact = Exact 0 1
  oneExact = Exact 1 1
  negativeOneExact = Exact (-1) 1
  inClosedUnitInterval exactValue =
    compareExact exactValue negativeOneExact /= LT
      && compareExact exactValue oneExact /= GT
  inOpenUnitInterval exactValue =
    compareExact exactValue negativeOneExact == GT
      && compareExact exactValue oneExact == LT
  outsideOpenUnitInterval exactValue =
    compareExact exactValue negativeOneExact /= GT
      || compareExact exactValue oneExact /= LT
  outsideClosedUnitInterval exactValue =
    compareExact exactValue negativeOneExact == LT
      || compareExact exactValue oneExact == GT

knownNonNegative :: Expr -> Bool
knownNonNegative value = case explicitRealExact value of
  Just exactValue -> compareExact exactValue (Exact 0 1) /= LT
  Nothing -> case value of
    Symbol name -> name `elem` ["Catalan", "Degree", "E", "EulerGamma", "GoldenRatio", "Pi"]
    Call (Symbol headName) [_] -> headName `elem` ["Abs", "Exp", "Sqrt"]
    _ -> False

knownPositive :: Expr -> Bool
knownPositive value = case explicitRealExact value of
  Just exactValue -> compareExact exactValue (Exact 0 1) == GT
  Nothing -> case value of
    Symbol name -> name `elem` ["Catalan", "Degree", "E", "EulerGamma", "GoldenRatio", "Pi"]
    Call (Symbol headName) [_] -> headName `elem` ["Exp"]
    _ -> False

containsInexactReal :: Expr -> Bool
containsInexactReal Real {} = True
containsInexactReal value
  | isSpecialRealValue value = True
containsInexactReal (Complex realPart imaginaryPart) =
  containsInexactReal realPart || containsInexactReal imaginaryPart
containsInexactReal (Call _ values) = any containsInexactReal values
containsInexactReal _ = False

isSpecialRealValue :: Expr -> Bool
isSpecialRealValue (Call (Symbol headName) []) =
  systemHeadIn ["Overflow", "Underflow"] headName
isSpecialRealValue _ = False

rootValueIsReal :: Expr -> Bool
rootValueIsReal (Root coefficients _ _) =
  polynomialHasOnlyRealLinearOrQuadraticRoots
    ( Map.fromList
        [ (degree, Exact coefficient 1)
        | (degree, coefficient) <- zip [0 ..] coefficients
        , coefficient /= 0
        ]
    )
rootValueIsReal _ = False

rootCallReality :: Expr -> Maybe Bool
rootCallReality (Call _ values) = do
  function <- case values of
    [function, Integer rootIndex]
      | rootIndex >= 1 -> Just function
    [function, Integer rootIndex, Integer _]
      | rootIndex >= 1 -> Just function
    _ -> Nothing
  polynomial <- rootFunctionPolynomial function
  if Map.null polynomial || fst (Map.findMax polynomial) < 1
    then Nothing
    else Just (polynomialHasOnlyRealLinearOrQuadraticRoots polynomial)
rootCallReality _ = Nothing

type PredicatePolynomial = Map.Map Integer Exact

rootFunctionPolynomial :: Expr -> Maybe PredicatePolynomial
rootFunctionPolynomial = \case
  Call (Symbol functionHead) [body]
    | systemHeadIn ["Function"] functionHead ->
        predicatePolynomial isSlotOne body
  Call (Symbol functionHead) [parameter@(Symbol _), body]
    | systemHeadIn ["Function"] functionHead ->
        predicatePolynomial (== parameter) body
  _ -> Nothing
 where
  isSlotOne (Call (Symbol slotHead) [Integer 1]) =
    systemHeadIn ["Slot"] slotHead
  isSlotOne _ = False

predicatePolynomial :: (Expr -> Bool) -> Expr -> Maybe PredicatePolynomial
predicatePolynomial isVariable expression
  | isVariable expression = Just (Map.singleton 1 (Exact 1 1))
predicatePolynomial _ expression
  | Just exactValue <- toExact expression = Just (constantPolynomial exactValue)
predicatePolynomial isVariable (Call (Symbol headName) values)
  | systemHeadIn ["Plus"] headName = do
      terms <- traverse (predicatePolynomial isVariable) values
      foldM polynomialAdd Map.empty terms
  | systemHeadIn ["Times"] headName = do
      factors <- traverse (predicatePolynomial isVariable) values
      foldM polynomialMultiply (Map.singleton 0 (Exact 1 1)) factors
predicatePolynomial isVariable (Call (Symbol headName) [base, Integer powerValue])
  | systemHeadIn ["Power"] headName
  , powerValue >= 0 = do
      polynomial <- predicatePolynomial isVariable base
      polynomialPower polynomial powerValue
predicatePolynomial _ _ = Nothing

constantPolynomial :: Exact -> PredicatePolynomial
constantPolynomial exactValue@(Exact numerator _)
  | numerator == 0 = Map.empty
  | otherwise = Map.singleton 0 exactValue

polynomialAdd :: PredicatePolynomial -> PredicatePolynomial -> Maybe PredicatePolynomial
polynomialAdd left right = boundedPolynomial (Map.unionWith addExact left right)

polynomialMultiply :: PredicatePolynomial -> PredicatePolynomial -> Maybe PredicatePolynomial
polynomialMultiply left right =
  boundedPolynomial
    ( Map.fromListWith
        addExact
        [ (leftDegree + rightDegree, multiplyExact leftCoefficient rightCoefficient)
        | (leftDegree, leftCoefficient) <- Map.toList left
        , (rightDegree, rightCoefficient) <- Map.toList right
        ]
    )

polynomialPower :: PredicatePolynomial -> Integer -> Maybe PredicatePolynomial
polynomialPower base powerValue = go (Map.singleton 0 (Exact 1 1)) base powerValue
 where
  go result _ 0 = Just result
  go result factor 1 = polynomialMultiply result factor
  go result factor remaining
    | odd remaining = do
        updated <- polynomialMultiply result factor
        squared <- polynomialMultiply factor factor
        go updated squared (remaining `div` 2)
    | otherwise = do
        squared <- polynomialMultiply factor factor
        go result squared (remaining `div` 2)

boundedPolynomial :: PredicatePolynomial -> Maybe PredicatePolynomial
boundedPolynomial polynomial =
  let retained = Map.filter (\(Exact numerator _) -> numerator /= 0) polynomial
   in if Map.size retained > 4096
        then Nothing
        else Just retained

polynomialHasOnlyRealLinearOrQuadraticRoots :: PredicatePolynomial -> Bool
polynomialHasOnlyRealLinearOrQuadraticRoots polynomial
  | Map.null polynomial = False
  | degree == 1 = True
  | degree == 2 =
      compareExact discriminant (Exact 0 1) /= LT
  | otherwise = False
 where
  degree = fst (Map.findMax polynomial)
  coefficient power = Map.findWithDefault (Exact 0 1) power polynomial
  a = coefficient 2
  b = coefficient 1
  c = coefficient 0
  discriminant =
    addExact
      (multiplyExact b b)
      (negateExact (multiplyExact (Exact 4 1) (multiplyExact a c)))

isString :: Expr -> Bool
isString String {} = True
isString _ = False

isByteArray :: Expr -> Bool
isByteArray ByteArray {} = True
isByteArray _ = False

integerValue :: Expr -> Maybe Integer
integerValue (Integer value) = Just value
integerValue _ = Nothing

listArguments :: Expr -> Maybe [Expr]
listArguments (Call (Symbol "List") values) = Just values
listArguments _ = Nothing

list :: [Expr] -> Expr
list = Call (Symbol "List")

boolean :: Bool -> Expr
boolean True = Symbol "True"
boolean False = Symbol "False"

allEqual :: Eq value => [value] -> Bool
allEqual [] = True
allEqual (firstValue : rest) = all (== firstValue) rest

allDistinct :: Eq value => [value] -> Bool
allDistinct [] = True
allDistinct (firstValue : rest) = firstValue `notElem` rest && allDistinct rest
