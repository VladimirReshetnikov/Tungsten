{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Immutable evaluation sessions with ordered symbol value definitions.
module Tungsten.Session
  ( Definition (..)
  , DownValue (..)
  , EvaluationMessage (..)
  , EvaluationSession (..)
  , SessionRuntime (..)
  , SymbolState (..)
  , SymbolValues (..)
  , defaultSessionRuntime
  , emptySession
  , evaluateInSession
  , evaluateInSessionWithRuntime
  , sessionHistoryLengthLimit
  ) where

import Control.Concurrent (threadDelay)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Char (isAlpha, isAlphaNum, isPrint, ord)
import Data.List (findIndex, sortBy, transpose)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)
import Numeric (showHex)
import Prelude hiding (Left, Right)
import qualified Prelude as P
import System.Random (randomRIO)
import Text.Read (readMaybe)
import qualified Tungsten.AlgebraicRoots as AlgebraicRoots
import Tungsten.Evaluate
import Tungsten.Expression
import qualified Tungsten.PolynomialAlgebra as PolynomialAlgebra
import Tungsten.PythonSort (pythonStableSortByStateM)
import qualified Tungsten.Random as Random
import qualified Tungsten.StringPatterns as SP
import Tungsten.SystemSymbols
  ( SymbolAttribute (..)
  , isSystemSymbol
  , normalizeSystemSymbolName
  , symbolAttributeFromName
  , symbolAttributeName
  , systemSymbolAttributes
  , systemSymbolNames
  )
import qualified Tungsten.TextualForms as TextualForms

data Definition
  = ImmediateValue !Expr
  | DelayedValue !Expr
  deriving (Eq, Show)

data DownValue = DownValue
  { downValuePattern :: !Expr
  , downValueBody :: !Expr
  , downValueDelayed :: !Bool
  }
  deriving (Eq, Show)

-- DownValues, UpValues, and SubValues share the same ordered rule
-- representation and application contract.  The slot only controls which
-- symbol-owned list an assignment mutates or a call dispatches through.
data CompoundValueSlot
  = DownValueSlot
  | UpValueSlot
  | SubValueSlot
  deriving (Eq, Show)

data TaggedValueTarget
  = TaggedOwnValue !Text
  | TaggedCompoundValue !CompoundValueSlot !Text
  deriving (Eq, Show)

data EvaluationMessage = EvaluationMessage
  { evaluationMessageName :: !Text
  , evaluationMessageFullName :: !Expr
  , evaluationMessageText :: !Text
  }
  deriving (Eq, Show)

data QuietScope = QuietScope
  { quietScopeOffSpecification :: !Expr
  , quietScopeOnSpecification :: !Expr
  }
  deriving (Eq, Show)

data MessageCollector = MessageCollector
  { messageCollectorSpecification :: !Expr
  , messageCollectorQuietDepth :: !Int
  , messageCollectorMessages :: ![EvaluationMessage]
  }
  deriving (Eq, Show)

data AbortProtectScope = AbortProtectScope
  { abortProtectScopePending :: !Bool
  }
  deriving (Eq, Show)

data CheckAbortScope = CheckAbortScope
  { checkAbortScopeProtectDepth :: !Int
  }
  deriving (Eq, Show)

data ReapTagGroup = ReapTagGroup
  { reapTagGroupTag :: !Expr
  , reapTagGroupValues :: ![Expr]
  }
  deriving (Eq, Show)

data ReapScope = ReapScope
  { reapScopePatterns :: ![Expr]
  , reapScopePatternListMode :: !Bool
  , reapScopeBuckets :: ![[ReapTagGroup]]
  }
  deriving (Eq, Show)

data EncloseScope = EncloseScope
  { encloseScopeForm :: !(Maybe Expr)
  }
  deriving (Eq, Show)

data TimeConstraintScope = TimeConstraintScope
  { timeConstraintDeadline :: !(Maybe Double)
  }
  deriving (Eq, Show)

data SymbolValues = SymbolValues
  { symbolOwnValue :: !(Maybe Definition)
  , symbolOwnValuePattern :: !(Maybe Expr)
  , symbolDownValues :: ![DownValue]
  , symbolUpValues :: ![DownValue]
  , symbolSubValues :: ![DownValue]
  , symbolNValues :: ![DownValue]
  }
  deriving (Eq, Show)

data SymbolState = SymbolState
  { symbolKnown :: !Bool
  , symbolAttributeOverride :: !(Maybe (Set.Set SymbolAttribute))
  , symbolValues :: !SymbolValues
  }
  deriving (Eq, Show)

data EvaluationSession = EvaluationSession
  { sessionSymbols :: Map.Map Text SymbolState
  , sessionModuleCounter :: !Integer
  , sessionActiveOwnValues :: !(Set.Set Text)
  -- Update operators use attempted diagnostics as a recovery barrier even
  -- when Off prevents those diagnostics from entering either message list.
  , sessionMessageAttemptCount :: !Integer
  , sessionDisabledMessages :: !(Set.Set Text)
  , sessionAssertEnabled :: !Bool
  , sessionQuietScopes :: ![QuietScope]
  , sessionMessageCollectors :: ![MessageCollector]
  , sessionAbortProtectScopes :: ![AbortProtectScope]
  , sessionCheckAbortScopes :: ![CheckAbortScope]
  , sessionReapScopes :: ![ReapScope]
  , sessionEncloseScopes :: ![EncloseScope]
  , sessionTimeConstraintScopes :: ![TimeConstraintScope]
  , sessionTimeConstraintSuppressionDepth :: !Int
  , sessionGeneratedMessages :: ![EvaluationMessage]
  , sessionVisibleMessages :: ![EvaluationMessage]
  , sessionPrints :: ![Text]
  , sessionHistoryLine :: !(Maybe Integer)
  , sessionInputHistory :: !(Map.Map Integer Expr)
  , sessionInputStringHistory :: !(Map.Map Integer Text)
  , sessionOutputHistory :: !(Map.Map Integer Expr)
  , sessionMessageHistory :: !(Map.Map Integer [EvaluationMessage])
  , sessionExpandingInputHistory :: !(Set.Set Integer)
  }
  deriving (Eq, Show)

emptySession :: EvaluationSession
emptySession =
  EvaluationSession
    { sessionSymbols = initialSessionSymbols
    , sessionModuleCounter = 0
    , sessionActiveOwnValues = Set.empty
    , sessionMessageAttemptCount = 0
    , sessionDisabledMessages = Set.empty
    , sessionAssertEnabled = False
    , sessionQuietScopes = []
    , sessionMessageCollectors = []
    , sessionAbortProtectScopes = []
    , sessionCheckAbortScopes = []
    , sessionReapScopes = []
    , sessionEncloseScopes = []
    , sessionTimeConstraintScopes = []
    , sessionTimeConstraintSuppressionDepth = 0
    , sessionGeneratedMessages = []
    , sessionVisibleMessages = []
    , sessionPrints = []
    , sessionHistoryLine = Nothing
    , sessionInputHistory = Map.empty
    , sessionInputStringHistory = Map.empty
    , sessionOutputHistory = Map.empty
    , sessionMessageHistory = Map.empty
    , sessionExpandingInputHistory = Set.empty
    }

initialSessionSymbols :: Map.Map Text SymbolState
initialSessionSymbols =
  Map.fromList
    [ ( name
      , emptySymbolState
          { symbolKnown = True
          , symbolValues =
              emptySymbolValues
                { symbolOwnValue = Just (ImmediateValue value)
                }
          }
      )
    | (name, value) <- specialSessionOwnValueDefaults
    ]

data Iterator = Iterator !(Maybe Text) ![Expr]
  deriving (Eq, Show)

data ModuleBinding = ModuleBinding !Text !(Maybe Definition)
  deriving (Eq, Show)

data BlockBinding = BlockBinding !Text !(Maybe Definition)
  deriving (Eq, Show)

data WithBinding = WithBinding !Text !Expr !Bool
  deriving (Eq, Show)

data SymbolValueSnapshot = SymbolValueSnapshot
  { snapshotValues :: !SymbolValues
  }
  deriving (Eq, Show)

data ControlSignal
  = Thrown !Expr !(Maybe Expr) !(Maybe Expr)
  | ConfirmationFailed !Expr !(Maybe Expr)
  | Aborted
  | BreakSignal
  | ContinueSignal
  | Returned !Expr !(Maybe Text)
  | GotoSignal !Expr
  | TimeConstraintExpired
  deriving (Eq, Show)

data EvaluationExit
  = SessionEvaluationFailure !EvaluationError !EvaluationSession
  | SessionControl !ControlSignal !EvaluationSession
  deriving (Eq, Show)

-- Runtime effects are represented explicitly in the evaluation plan.  The
-- pure reducer and the immutable session machinery construct this small free
-- effect tree; only 'evaluateInSessionWithRuntime' interprets it in IO.
data SessionEffect value where
  ReadMonotonicTime :: SessionEffect Double
  SleepForSeconds :: !Double -> SessionEffect ()
  RandomBelow :: !Integer -> SessionEffect Integer

data RuntimeResult failure value where
  Left :: !failure -> RuntimeResult failure value
  Right :: value -> RuntimeResult failure value
  RuntimeEffect
    :: SessionEffect request
    -> (request -> RuntimeResult failure value)
    -> RuntimeResult failure value

instance Functor (RuntimeResult failure) where
  fmap function result = result >>= (pure . function)

instance Applicative (RuntimeResult failure) where
  pure = Right
  (<*>) = apRuntimeResult

instance Monad (RuntimeResult failure) where
  Left evaluationExit >>= _ = Left evaluationExit
  Right value >>= continuation = continuation value
  RuntimeEffect request resume >>= continuation =
    RuntimeEffect request (\response -> resume response >>= continuation)

apRuntimeResult
  :: RuntimeResult failure (value -> result)
  -> RuntimeResult failure value
  -> RuntimeResult failure result
apRuntimeResult functionAction valueAction = do
  function <- functionAction
  value <- valueAction
  pure (function value)

type SessionResult value =
  RuntimeResult EvaluationExit (value, EvaluationSession)

-- | Concrete effect handlers for session timing.  Tests may supply a
-- deterministic clock and sleeper; production consumers use
-- 'defaultSessionRuntime'.
data SessionRuntime = SessionRuntime
  { sessionRuntimeMonotonicSeconds :: IO Double
  , sessionRuntimeSleepSeconds :: Double -> IO ()
  , sessionRuntimeRandomBelow :: Integer -> IO Integer
  }

defaultSessionRuntime :: SessionRuntime
defaultSessionRuntime =
  SessionRuntime
    { sessionRuntimeMonotonicSeconds =
        (/ 1000000000) . fromIntegral <$> getMonotonicTimeNSec
    , sessionRuntimeSleepSeconds = \seconds ->
        if seconds <= 0
          then pure ()
          else threadDelay (ceiling (seconds * 1000000))
    , sessionRuntimeRandomBelow = \exclusiveUpperBound ->
        if exclusiveUpperBound <= 0
          then ioError (userError "random-below requires a positive upper bound")
          else randomRIO (0, exclusiveUpperBound - 1)
    }

-- Pattern matching can invoke arbitrary Condition and PatternTest callbacks.
-- This small state monad lets the shared matcher thread the same immutable
-- EvaluationSession used by ordinary evaluation, including effects from
-- failed alternatives and backtracking attempts.
newtype PatternSession value = PatternSession
  { runPatternSession :: EvaluationSession -> SessionResult value
  }

instance Functor PatternSession where
  fmap function action = PatternSession $ \session -> do
    (value, updated) <- runPatternSession action session
    Right (function value, updated)

instance Applicative PatternSession where
  pure value = PatternSession (\session -> Right (value, session))
  functionAction <*> valueAction = PatternSession $ \session -> do
    (function, functionSession) <- runPatternSession functionAction session
    (value, updated) <- runPatternSession valueAction functionSession
    Right (function value, updated)

instance Monad PatternSession where
  action >>= continuation = PatternSession $ \session -> do
    (value, updated) <- runPatternSession action session
    runPatternSession (continuation value) updated

heldPatternBuiltinHeads :: [Text]
heldPatternBuiltinHeads =
  [ "MatchQ"
  , "Cases"
  , "DeleteCases"
  , "FirstCase"
  , "Replace"
  , "ReplaceAll"
  , "ReplaceRepeated"
  , "ReplaceAt"
  , "Position"
  , "FirstPosition"
  , "Count"
  , "FreeQ"
  , "MemberQ"
  , "SequenceCases"
  , "SequencePosition"
  , "SequenceCount"
  , "StringCases"
  , "StringReplace"
  ]

evaluatePatternCallback :: Int -> Expr -> PatternSession (Maybe Expr)
evaluatePatternCallback depth expression = PatternSession $ \session -> do
  (value, updated) <- evaluateSessionAt (depth + 1) session expression
  Right (Just value, updated)

resolveSessionPatternAttributes
  :: Expr
  -> PatternSession (Set.Set SymbolAttribute)
resolveSessionPatternAttributes expression = PatternSession $ \session ->
  Right
    ( case expression of
        Symbol name -> symbolAttributesFor name session
        _ -> Set.empty
    , session
    )

instantiateSessionPattern
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult (Maybe [Expr])
instantiateSessionPattern depth session expression patternExpression templates =
  runPatternSession
    ( instantiatePatternMatchManyWithAttributes
        (evaluatePatternCallback depth)
        resolveSessionPatternAttributes
        expression
        patternExpression
        templates
    )
    session

sessionPatternMatches
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Bool
sessionPatternMatches depth session expression patternExpression = do
  (matched, updated) <-
    instantiateSessionPattern depth session expression patternExpression []
  Right (maybe False (const True) matched, updated)

data SessionPatternRule = SessionPatternRule !Expr !Expr
  deriving (Eq, Show)

sessionPatternRule :: Expr -> Maybe SessionPatternRule
sessionPatternRule = \case
  Call (Symbol ruleHead) [patternExpression, template]
    | isSessionSystemHead "Rule" ruleHead ->
        Just (SessionPatternRule patternExpression template)
  Call (Symbol ruleHead) [patternExpression, template]
    | isSessionSystemHead "RuleDelayed" ruleHead ->
        Just (SessionPatternRule patternExpression template)
  _ -> Nothing

sessionPatternRuleSet :: Expr -> Maybe [SessionPatternRule]
sessionPatternRuleSet (Call (Symbol listHead) values)
  | isSessionSystemHead "List" listHead = traverse sessionPatternRule values
sessionPatternRuleSet expression = pure <$> sessionPatternRule expression

nestedSessionPatternRuleSets :: Expr -> Maybe [Expr]
nestedSessionPatternRuleSets (Call (Symbol listHead) values@(_ : _))
  | isSessionSystemHead "List" listHead
  , all isRuleList values = Just values
 where
  isRuleList expression@(Call (Symbol nestedListHead) _)
    | isSessionSystemHead "List" nestedListHead =
        maybe False (const True) (sessionPatternRuleSet expression)
  isRuleList _ = False
nestedSessionPatternRuleSets _ = Nothing

prepareSessionPatternRules
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
prepareSessionPatternRules depth session = \case
  Call listHead@(Symbol listName) rules
    | isSessionSystemHead "List" listName -> do
        (prepared, updated) <- prepareRules session rules
        Right (Call listHead prepared, updated)
  Call ruleHead@(Symbol ruleName) [patternExpression, template]
    | isSessionSystemHead "Rule" ruleName -> do
        (preparedTemplate, updated) <-
          evaluateRuleTemplate depth session patternExpression template
        Right
          ( Call ruleHead [patternExpression, preparedTemplate]
          , updated
          )
  delayedRule@(Call (Symbol ruleName) [_, _])
    | isSessionSystemHead "RuleDelayed" ruleName ->
        Right (delayedRule, session)
  expression -> Right (expression, session)
 where
  prepareRules current [] = Right ([], current)
  prepareRules current (rule : rest) = do
    (preparedRule, ruleSession) <-
      prepareSessionPatternRules depth current rule
    (preparedRest, updated) <- prepareRules ruleSession rest
    Right (preparedRule : preparedRest, updated)

evaluateRuleTemplate
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateRuleTemplate depth session patternExpression template =
  let names = Set.toList (patternBindingNames patternExpression)
      snapshots =
        [ (name, snapshotSymbolValues name session)
        | name <- names
        ]
      scopedSession = clearDefinitions names session
   in restoreScopedResult
        snapshots
        (evaluateSessionAt (depth + 1) scopedSession template)

patternBindingNames :: Expr -> Set.Set Text
patternBindingNames = \case
  Call (Symbol "Verbatim") [_] -> Set.empty
  Call (Symbol "Pattern") [Symbol name, innerPattern] ->
    Set.insert name (patternBindingNames innerPattern)
  Call expressionHead values ->
    Set.unions
      (patternBindingNames expressionHead : map patternBindingNames values)
  _ -> Set.empty

data IterationFailure
  = InvalidIterator !EvaluationSession
  | IterationEvaluationFailure !EvaluationExit
  deriving (Eq, Show)

type IterationResult value = RuntimeResult IterationFailure value

evaluateInSession
  :: EvaluationSession
  -> Expr
  -> IO (Either EvaluationError (Expr, EvaluationSession))
evaluateInSession = evaluateInSessionWithRuntime defaultSessionRuntime

evaluateInSessionWithRuntime
  :: SessionRuntime
  -> EvaluationSession
  -> Expr
  -> IO (Either EvaluationError (Expr, EvaluationSession))
evaluateInSessionWithRuntime runtime session expression = do
  let registeredSession = registerExpressionSymbols expression session
      plan =
        finalizeSessionResult
          ( evaluateSessionAt
              0
              registeredSession
                { sessionMessageAttemptCount = 0
                , sessionQuietScopes = []
                , sessionMessageCollectors = []
                , sessionAbortProtectScopes = []
                , sessionCheckAbortScopes = []
                , sessionReapScopes = []
                , sessionEncloseScopes = []
                , sessionTimeConstraintScopes = []
                , sessionTimeConstraintSuppressionDepth = 0
                , sessionGeneratedMessages = []
                , sessionVisibleMessages = []
                , sessionPrints = []
                , sessionExpandingInputHistory = Set.empty
                }
              expression
          )
  runRuntimeResult runtime plan >>= \case
    P.Left (SessionEvaluationFailure evaluationFailure _) ->
      pure (P.Left evaluationFailure)
    P.Left (SessionControl _ stoppedSession) ->
      pure
        ( P.Left
            ( EvaluationError
                ( "an internal control signal escaped session finalization: "
                    <> T.pack (show stoppedSession)
                )
            )
        )
    P.Right result -> pure (P.Right result)

runRuntimeResult
  :: SessionRuntime
  -> RuntimeResult failure value
  -> IO (Either failure value)
runRuntimeResult runtime = \case
  Left evaluationExit -> pure (P.Left evaluationExit)
  Right value -> pure (P.Right value)
  RuntimeEffect ReadMonotonicTime resume ->
    sessionRuntimeMonotonicSeconds runtime
      >>= runRuntimeResult runtime . resume
  RuntimeEffect (SleepForSeconds seconds) resume ->
    sessionRuntimeSleepSeconds runtime seconds
      >> runRuntimeResult runtime (resume ())
  RuntimeEffect (RandomBelow exclusiveUpperBound) resume ->
    sessionRuntimeRandomBelow runtime exclusiveUpperBound
      >>= runRuntimeResult runtime . resume

inspectRuntimeResult
  :: RuntimeResult failure value
  -> (Either failure value -> RuntimeResult nextFailure result)
  -> RuntimeResult nextFailure result
inspectRuntimeResult action continuation = case action of
  Left evaluationExit -> continuation (P.Left evaluationExit)
  Right value -> continuation (P.Right value)
  RuntimeEffect request resume ->
    RuntimeEffect
      request
      (\response -> inspectRuntimeResult (resume response) continuation)

readSessionMonotonicTime :: RuntimeResult failure Double
readSessionMonotonicTime = RuntimeEffect ReadMonotonicTime Right

sleepSessionSeconds :: Double -> RuntimeResult failure ()
sleepSessionSeconds seconds = RuntimeEffect (SleepForSeconds seconds) Right

effectiveTimeConstraintDeadline :: EvaluationSession -> Maybe Double
effectiveTimeConstraintDeadline session
  | sessionTimeConstraintSuppressionDepth session > 0 = Nothing
  | otherwise = case
      [ deadline
      | TimeConstraintScope (Just deadline) <- sessionTimeConstraintScopes session
      ] of
      [] -> Nothing
      deadlines -> Just (minimum deadlines)

checkSessionTimeConstraint
  :: EvaluationSession
  -> SessionResult value
  -> SessionResult value
checkSessionTimeConstraint session continuation =
  case effectiveTimeConstraintDeadline session of
    Nothing -> continuation
    Just deadline -> do
      now <- readSessionMonotonicTime
      if now >= deadline
        then Left (SessionControl TimeConstraintExpired session)
        else continuation

registerExpressionSymbols :: Expr -> EvaluationSession -> EvaluationSession
registerExpressionSymbols expression session = case expression of
  Symbol name -> registerSymbol name session
  Call expressionHead values ->
    foldl
      (flip registerExpressionSymbols)
      (registerExpressionSymbols expressionHead session)
      values
  Complex realPart imaginaryPart ->
    registerExpressionSymbols
      imaginaryPart
      (registerExpressionSymbols realPart session)
  SparseArray _ entries fill ->
    foldl
      (\current (SparseEntry _ value) -> registerExpressionSymbols value current)
      (registerExpressionSymbols fill session)
      entries
  _ -> session

finalizeSessionResult :: SessionResult Expr -> SessionResult Expr
finalizeSessionResult result = inspectRuntimeResult result $ \case
    P.Left evaluationExit@(SessionEvaluationFailure _ _) -> Left evaluationExit
    P.Left (SessionControl (Thrown value tag handler) stoppedSession) ->
      case (tag, handler) of
        (Nothing, _) ->
          Right (Call (Symbol "Throw") [value], stoppedSession)
        (Just evaluatedTag, Nothing) ->
          Right
            ( Call (Symbol "Throw") [value, evaluatedTag]
            , stoppedSession
            )
        (Just evaluatedTag, Just evaluatedHandler) ->
          finalizeSessionResult
            ( evaluateSessionAt
                0
                stoppedSession
                (Call evaluatedHandler [value, evaluatedTag])
            )
    P.Left (SessionControl (ConfirmationFailed failure _) stoppedSession) ->
      Right
        ( failure
        , appendNamedMessage
            "Confirm"
            "confirmnotag"
            "Message generated."
            (clearEncloseScopes stoppedSession)
        )
    P.Left (SessionControl Aborted stoppedSession) ->
      Right (Symbol "$Aborted", clearAbortScopes stoppedSession)
    P.Left (SessionControl BreakSignal stoppedSession) ->
      Right (Call (Symbol "Break") [], stoppedSession)
    P.Left (SessionControl ContinueSignal stoppedSession) ->
      Right (Call (Symbol "Continue") [], stoppedSession)
    P.Left (SessionControl (Returned value target) stoppedSession) ->
      Right
        ( Call
            (Symbol "Return")
            (value : maybe [] (pure . Symbol) target)
        , stoppedSession
        )
    P.Left (SessionControl (GotoSignal tag) stoppedSession) ->
      Right (Call (Symbol "Goto") [tag], stoppedSession)
    P.Left (SessionControl TimeConstraintExpired stoppedSession) ->
      Right (Symbol "$Aborted", clearTimeConstraintScopes stoppedSession)
    P.Right success -> Right success

evaluateSessionAt
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionAt depth session expression =
  checkSessionTimeConstraint session $
    if exceedsSessionRecursionLimit depth session
      then sessionFailure session "the session evaluation recursion limit was exceeded"
      else
        recoverEvaluationFailure
          expression
          (evaluateSessionAtRaw depth session expression)

evaluateSessionAtRaw
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionAtRaw depth session expression = case expression of
      Symbol name
        | resolvedSymbolStorageName name session == "$Line"
        , Just line <- sessionHistoryLine session ->
            Right (Integer line, session)
        | resolvedSymbolStorageName name session == "$MessageList" ->
            Right (currentSessionMessageList session, session)
        | resolvedSymbolStorageName name session == "$Context" ->
            Right (String currentSessionContext, session)
        | resolvedSymbolStorageName name session == "$ContextPath" ->
            Right
              ( evaluatedList (map String currentSessionContextPath)
              , session
              )
        | isSystemSymbol name
        , displaySessionSymbolName name == "I" ->
            Right (Complex (Integer 0) (Integer 1), session)
        | isSystemSymbol name
        , displaySessionSymbolName name == "$MachinePrecision" ->
            Right (Real "15.954589770191003", session)
        | isSystemSymbol name
        , displaySessionSymbolName name == "$MaxMachineNumber" ->
            Right (Real "1.7976931348623157*^+308", session)
        | isSystemSymbol name
        , displaySessionSymbolName name == "$MinMachineNumber" ->
            Right (Real "2.2250738585072014*^-308", session)
        | isSystemSymbol name
        , displaySessionSymbolName name == "$MachineEpsilon" ->
            Right (Real "2.220446049250313*^-16", session)
        | otherwise -> case symbolOwnValueFor name session of
            Nothing ->
              Right
                ( expression
                , registerSymbol name session
                )
            Just (ImmediateValue value)
              | value == expression -> Right (expression, session)
            Just (ImmediateValue value) ->
              evaluateSessionOwnValue depth session name expression value
            Just (DelayedValue value) ->
              evaluateSessionOwnValue depth session name expression value
      Call (Symbol qualifiedName) arguments'
        | Just shortName <- T.stripPrefix "System`" qualifiedName
        , isSystemSymbol qualifiedName -> do
            case shortName of
              "And" ->
                evaluateSessionLogical
                  qualifiedName
                  (Symbol "True")
                  (Symbol "False")
                  depth
                  session
                  arguments'
              "Or" ->
                evaluateSessionLogical
                  qualifiedName
                  (Symbol "False")
                  (Symbol "True")
                  depth
                  session
                  arguments'
              _ | directSessionDispatchHead shortName -> do
                (result, updated) <- evaluateSessionAtRaw
                  depth
                  session
                  (Call (Symbol shortName) arguments')
                Right
                  ( if shortName `elem` staticHeldHeadNames
                        || shortName == "Inactive"
                      then restoreQualifiedSystemHead qualifiedName shortName result
                      else result
                  , updated
                  )
              _ ->
                evaluateSessionGenericCall
                  depth
                  session
                  (Symbol qualifiedName)
                  arguments'
      Call (Symbol "MessageList") arguments' ->
        evaluateSessionHistoricalMessageList depth session arguments'
      Call (Symbol historyHead) arguments'
        | historyHead `elem` ["In", "InString", "Out"] ->
            evaluateSessionHistoryCall historyHead depth session arguments'
      Call (Symbol "TagSet") arguments' ->
        evaluateSessionTagSet False depth session arguments'
      Call (Symbol "TagSetDelayed") arguments' ->
        evaluateSessionTagSet True depth session arguments'
      Call (Symbol "TagUnset") arguments' ->
        evaluateSessionTagUnset depth session arguments'
      Call (Symbol "Set") [Call (Symbol attributesHead) targets, rhs]
        | isSessionSystemHead "Attributes" attributesHead ->
            evaluateSessionAttributesAssignment depth session targets rhs
      Call (Symbol "Set") [Symbol name, rhs] -> do
        (value, updated) <- evaluateSessionAt (depth + 1) session rhs
        case specialSessionSettingName name of
          Just settingName
            | not (validSpecialSessionSetting settingName value) ->
                Right
                  ( currentSpecialSessionSettingValue settingName updated
                  , appendSpecialSettingLimitMessage settingName value updated
                  )
          Just _ -> pure (value, define name (ImmediateValue value) updated)
          Nothing
            | not (symbolAllowsValueMutation name updated) ->
                Right
                  ( Call (Symbol "Set") [Symbol name, value]
                  , appendSymbolMessage "Set" "wrsym" name "is Protected." updated
                  )
            | otherwise -> pure (value, define name (ImmediateValue value) updated)
      Call (Symbol "Set") [lhs@Call {}, rhs] ->
        evaluateDownValueAssignment False depth session lhs rhs
      Call (Symbol "Set") [_, _] ->
        sessionFailure session "Set does not support this left-hand side in Tungsten yet."
      Call (Symbol "SetDelayed") [Symbol name, rhs]
        | Just settingName <- specialSessionSettingName name
        , not (validSpecialSessionSetting settingName rhs) ->
            Right
              ( Symbol "Null"
              , appendSpecialSettingLimitMessage settingName rhs session
              )
        | Just _ <- specialSessionSettingName name ->
            Right (Symbol "Null", define name (DelayedValue rhs) session)
        | not (symbolAllowsValueMutation name session) ->
            Right
              ( Symbol "Null"
              , appendSymbolMessage
                  "SetDelayed"
                  "wrsym"
                  name
                  "is Protected."
                  session
              )
        | otherwise ->
            Right (Symbol "Null", define name (DelayedValue rhs) session)
      Call (Symbol "SetDelayed") [lhs@Call {}, rhs] ->
        evaluateDownValueAssignment True depth session lhs rhs
      Call (Symbol "Unset") [Symbol name]
        | Just _ <- specialSessionSettingName name ->
            Right
              ( Symbol "$Failed"
              , appendSymbolMessage
                  "Unset"
                  "spsym"
                  name
                  "is a special system symbol."
                  session
              )
        | not (symbolAllowsValueMutation name session) ->
            Right
              ( Symbol "$Failed"
              , appendSymbolMessage "Unset" "wrsym" name "is Protected." session
              )
        | otherwise ->
            Right (Symbol "Null", removeOwnValues [name] session)
      Call (Symbol "Unset") [lhs@Call {}] ->
        evaluateDownValueUnset depth session lhs
      Call (Symbol "Clear") targets ->
        evaluateSessionClear False session targets
      Call (Symbol "ClearAll") targets ->
        evaluateSessionClear True session targets
      Call (Symbol "Attributes") arguments' ->
        evaluateSessionAttributes depth session arguments'
      Call (Symbol "SetAttributes") arguments' ->
        evaluateSessionSetAttributes True depth session arguments'
      Call (Symbol "ClearAttributes") arguments' ->
        evaluateSessionSetAttributes False depth session arguments'
      Call (Symbol "Protect") targets ->
        evaluateSessionProtect True session targets
      Call (Symbol "Unprotect") targets ->
        evaluateSessionProtect False session targets
      Call (Symbol "CompoundExpression") expressions ->
        evaluateSessionCompoundExpression depth session expressions
      Call (Symbol "If") arguments' -> evaluateSessionIf depth session arguments'
      Call (Symbol "Which") arguments' ->
        evaluateSessionWhich depth session arguments'
      Call (Symbol "Switch") arguments' ->
        evaluateSessionSwitch depth session arguments'
      Call (Symbol "Piecewise") arguments' ->
        evaluateSessionPiecewise depth session arguments'
      Call (Symbol "And") arguments' -> evaluateSessionAnd depth session arguments'
      Call (Symbol "Or") arguments' -> evaluateSessionOr depth session arguments'
      Call (Symbol "Catch") arguments' ->
        evaluateSessionCatch depth session arguments'
      Call (Symbol "Throw") arguments' ->
        evaluateSessionThrow depth session arguments'
      Call (Symbol "Enclose") arguments' ->
        evaluateSessionEnclose depth session arguments'
      Call (Symbol "Confirm") arguments' ->
        evaluateSessionConfirm depth session arguments'
      Call (Symbol "ConfirmBy") arguments' ->
        evaluateSessionConfirmBy depth session arguments'
      Call (Symbol "ConfirmMatch") arguments' ->
        evaluateSessionConfirmMatch depth session arguments'
      Call (Symbol "ConfirmAssert") arguments' ->
        evaluateSessionConfirmAssert depth session arguments'
      Call (Symbol "Assert") arguments' ->
        evaluateSessionAssert depth session arguments'
      Call (Symbol "Abort") arguments' ->
        evaluateSessionAbort session arguments'
      Call (Symbol "CheckAbort") arguments' ->
        evaluateSessionCheckAbort depth session arguments'
      Call (Symbol "AbortProtect") arguments' ->
        evaluateSessionAbortProtect depth session arguments'
      Call (Symbol "WithCleanup") arguments' ->
        evaluateSessionWithCleanup depth session arguments'
      Call (Symbol "Pause") arguments' ->
        evaluateSessionPause depth session arguments'
      Call (Symbol "AbsoluteTiming") arguments' ->
        evaluateSessionAbsoluteTiming depth session arguments'
      Call (Symbol "TimeConstrained") arguments' ->
        evaluateSessionTimeConstrained depth session arguments'
      Call (Symbol "TimeRemaining") arguments' ->
        evaluateSessionTimeRemaining session arguments'
      Call (Symbol "Reap") arguments' ->
        evaluateSessionReap depth session arguments'
      Call (Symbol "Sow") arguments' ->
        evaluateSessionSow depth session arguments'
      Call (Symbol "Failsafe") arguments' ->
        evaluateSessionFailsafe depth session arguments'
      Call (Symbol "Break") arguments' ->
        evaluateLoopControl BreakSignal "Break" session arguments'
      Call (Symbol "Continue") arguments' ->
        evaluateLoopControl ContinueSignal "Continue" session arguments'
      Call (Symbol "Return") arguments' ->
        evaluateSessionReturn depth session arguments'
      Call (Symbol "Label") arguments' ->
        evaluateSessionLabel session arguments'
      Call (Symbol "Goto") arguments' ->
        evaluateSessionGoto depth session arguments'
      Call (Symbol "Message") arguments' ->
        evaluateSessionMessage depth session arguments'
      Call (Symbol "Off") arguments' ->
        evaluateSessionMessageControl "Off" False depth session arguments'
      Call (Symbol "On") arguments' ->
        evaluateSessionMessageControl "On" True depth session arguments'
      Call (Symbol "Quiet") arguments' ->
        evaluateSessionQuiet depth session arguments'
      Call (Symbol "Check") arguments' ->
        evaluateSessionCheck depth session arguments'
      Call (Symbol "AppendTo") arguments' ->
        evaluateSessionAppendTo depth session arguments'
      Call (Symbol headName) arguments'
        | Just (delta, returnOld) <- Map.lookup headName inPlaceArithmeticVariants ->
            evaluateSessionInPlaceArithmetic
              headName
              delta
              returnOld
              depth
              session
              arguments'
      Call (Symbol "Print") arguments' ->
        evaluateSessionPrint depth session arguments'
      Call (Symbol "Evaluate") arguments' ->
        evaluateSessionEvaluate depth session arguments'
      Call (Symbol "ReleaseHold") arguments' ->
        evaluateSessionReleaseHold depth session arguments'
      Call (Symbol "Inactive") arguments' ->
        evaluateSessionInactive depth session arguments'
      Call (Symbol "Activate") arguments' ->
        evaluateSessionActivate depth session arguments'
      Call (Symbol "Select") [criterion] ->
        evaluateSessionSelectionOperator "Select" depth session criterion
      Call (Symbol "Discard") [criterion] ->
        evaluateSessionSelectionOperator "Discard" depth session criterion
      Call (Symbol "SelectFirst") [criterion] ->
        evaluateSessionSelectionOperator "SelectFirst" depth session criterion
      Call (Symbol "ValueQ") arguments' ->
        evaluateSessionValueQ depth session arguments'
      Call (Symbol "OwnValues") arguments' ->
        evaluateSessionOwnValues session arguments'
      Call (Symbol "DownValues") arguments' ->
        evaluateSessionDefinitionValues
          "DownValues"
          symbolDownValues
          session
          arguments'
      Call (Symbol "UpValues") arguments' ->
        evaluateSessionDefinitionValues
          "UpValues"
          symbolUpValues
          session
          arguments'
      Call (Symbol "SubValues") arguments' ->
        evaluateSessionDefinitionValues
          "SubValues"
          symbolSubValues
          session
          arguments'
      Call (Symbol "NValues") arguments' ->
        evaluateSessionDefinitionValues
          "NValues"
          symbolNValues
          session
          arguments'
      Call (Symbol "Module") arguments' ->
        evaluateSessionModule depth session arguments'
      Call (Symbol "With") arguments' ->
        evaluateSessionWith depth session arguments'
      Call (Symbol headName) arguments'
        | headName
            `elem` ["Block", "InheritedBlock", "Internal`InheritedBlock"] ->
            evaluateSessionBlock headName depth session arguments'
      Call (Symbol "Table") arguments' ->
        evaluateSessionTable depth session arguments'
      Call (Symbol "Do") arguments' ->
        evaluateSessionDo depth session arguments'
      Call (Symbol "For") arguments' ->
        evaluateSessionFor depth session arguments'
      Call (Symbol "While") arguments' ->
        evaluateSessionWhile depth session arguments'
      Call (Symbol "Sum") arguments' ->
        evaluateSessionAccumulator "Sum" "Plus" depth session arguments'
      Call (Symbol "Product") arguments' ->
        evaluateSessionAccumulator "Product" "Times" depth session arguments'
      Call (Symbol headName) arguments'
        | headName `elem` heldPatternBuiltinHeads ->
            evaluateHeldSessionPatternBuiltin headName depth session arguments'
      Call (Symbol headName) [Symbol name, rhs]
        | Just constructor <- Map.lookup headName updateConstructors ->
            evaluateUpdate headName depth session name constructor rhs
      Call (Symbol "Function") arguments'
        | length arguments' `notElem` [1, 2, 3] ->
            sessionFailure
              session
              "Function expects one, two, or three arguments."
      Call (Symbol "SetDelayed") _ ->
        sessionFailure session "SetDelayed expects exactly two arguments."
      Call (Symbol headName) arguments'
        | headName `elem` staticHeldHeadNames ->
            evaluateStaticHeldCall depth session headName arguments'
      Call expressionHead arguments' ->
        evaluateSessionGenericCall depth session expressionHead arguments'
      _ -> Right (expression, session)

evaluateSessionOwnValue
  :: Int
  -> EvaluationSession
  -> Text
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionOwnValue depth session name expression value =
  let storageName = resolvedSymbolStorageName name session
      active = sessionActiveOwnValues session
   in if Set.member storageName active
        then Right (expression, session)
        else
          restoreActiveOwnValues
            active
            ( evaluateSessionAt
                (depth + 1)
                session
                  { sessionActiveOwnValues = Set.insert storageName active
                  }
                value
            )

restoreActiveOwnValues
  :: Set.Set Text
  -> SessionResult value
  -> SessionResult value
restoreActiveOwnValues active result = inspectRuntimeResult result $ \case
  P.Right (value, session) ->
    Right (value, session {sessionActiveOwnValues = active})
  P.Left evaluationExit ->
    Left
      ( mapEvaluationExitSession
          (\session -> session {sessionActiveOwnValues = active})
          evaluationExit
      )

evaluateSessionGenericCall
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionGenericCall depth session expressionHead arguments' = do
  (evaluatedHead, headSession) <-
    evaluateSessionAt (depth + 1) session expressionHead
  case evaluatedHead of
    Symbol nothingHead
      | isSessionSystemHead "Nothing" nothingHead -> do
          (_, updated) <- evaluateArguments depth headSession arguments'
          Right (Symbol "Nothing", updated)
    _ ->
      evaluateSessionPreparedGenericCall
        depth
        headSession
        expressionHead
        evaluatedHead
        arguments'

evaluateSessionPreparedGenericCall
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionPreparedGenericCall depth session expressionHead evaluatedHead arguments' = do
  (preparedArguments, argumentsSession) <-
    evaluateCallArgumentsWithAttributes
      depth
      session
      evaluatedHead
      arguments'
  let attributeNormalizedCall =
        normalizeSessionAttributeCall
          argumentsSession
          evaluatedHead
          preparedArguments
      attributeNormalizedArguments = case attributeNormalizedCall of
        Call _ values -> values
        _ -> preparedArguments
      normalizedArguments =
        stripSessionTransparentUnevaluatedArguments
          evaluatedHead
          attributeNormalizedArguments
      normalizedCall = Call evaluatedHead normalizedArguments
      allowSystemDispatch =
        evaluatedHeadAllowsDispatch expressionHead evaluatedHead
  case threadSessionListableCall depth argumentsSession normalizedCall of
    Just sessionResult -> sessionResult
    Nothing -> case evaluatedHead of
      callable
        | isSessionStructuralCallable callable ->
            evaluateSessionCallable
              depth
              argumentsSession
              callable
              normalizedArguments
      association@(Call (Symbol associationHead) _)
        | allowSystemDispatch
        , isSessionSystemHead "Association" associationHead ->
            evaluateSessionCallable
              depth
              argumentsSession
              association
              normalizedArguments
      Call (Symbol functionHead) functionArguments
        | isSessionSystemHead "Function" functionHead -> do
            instantiated <-
              liftPureEvaluation
                argumentsSession
                ( instantiateFunctionCallWithHead
                    (Symbol functionHead)
                    functionArguments
                    normalizedArguments
                )
            if instantiated == normalizedCall
              then Right (instantiated, argumentsSession)
              else evaluateSessionAt (depth + 1) argumentsSession instantiated
      _ -> do
        (upValueReplacement, upValueSession) <-
          if suppressSymbolCallUpValues evaluatedHead argumentsSession
            then Right (Nothing, argumentsSession)
            else applySessionUpValue depth argumentsSession normalizedCall
        case upValueReplacement of
          Just replacement -> Right (replacement, upValueSession)
          Nothing -> case evaluatedHead of
            Symbol logicalHead
              | allowSystemDispatch
              , isSessionSystemHead "And" logicalHead ->
                  Right
                    ( reduceHeldLogicalAlias
                        logicalHead
                        (Symbol "True")
                        (Symbol "False")
                        normalizedArguments
                    , upValueSession
                    )
            Symbol logicalHead
              | allowSystemDispatch
              , isSessionSystemHead "Or" logicalHead ->
                  Right
                    ( reduceHeldLogicalAlias
                        logicalHead
                        (Symbol "False")
                        (Symbol "True")
                        normalizedArguments
                    , upValueSession
                    )
            _ -> do
              (definitionReplacement, definitionSession) <-
                case evaluatedHead of
                  Symbol _ ->
                    applySessionDownValue depth upValueSession normalizedCall
                  Call {} ->
                    applySessionSubValue depth upValueSession normalizedCall
                  _ -> Right (Nothing, upValueSession)
              case definitionReplacement of
                Just replacement -> Right (replacement, definitionSession)
                Nothing ->
                  if expressionHead /= evaluatedHead
                      && evaluatedHead == Symbol "CompoundExpression"
                    then Right (normalizedCall, definitionSession)
                    else
                      case reduceSessionEvaluatedCallForDispatch
                        allowSystemDispatch
                        depth
                        definitionSession
                        normalizedCall of
                        Just sessionReduction -> sessionReduction
                        Nothing -> do
                          reduced <-
                            liftPureEvaluation
                              definitionSession
                              ( reduceEvaluatedCallForDispatch
                                  allowSystemDispatch
                                  definitionSession
                                  normalizedCall
                              )
                          Right (reduced, definitionSession)

suppressSymbolCallUpValues :: Expr -> EvaluationSession -> Bool
suppressSymbolCallUpValues (Symbol name) session =
  symbolHasAttribute name HoldAllComplete session
suppressSymbolCallUpValues _ _ = False

reduceHeldLogicalAlias :: Text -> Expr -> Expr -> [Expr] -> Expr
reduceHeldLogicalAlias headName identity decisive values
  | all isBoolean values =
      if decisive `elem` values then decisive else identity
  | otherwise = Call (Symbol headName) values
 where
  isBoolean value = value `elem` [Symbol "False", Symbol "True"]

evaluatedHeadAllowsDispatch :: Expr -> Expr -> Bool
evaluatedHeadAllowsDispatch _ evaluatedHead = case evaluatedHead of
  Symbol evaluatedName
    | Just shortName <- T.stripPrefix "System`" evaluatedName ->
        shortName `elem` qualifiedAliasDispatchHeads
  _ -> True

qualifiedAliasDispatchHeads :: [Text]
qualifiedAliasDispatchHeads =
  [ "Abs"
  , "Accuracy"
  , "Apart"
  , "And"
  , "Arg"
  , "AtomQ"
  , "BernoulliB"
  , "Binomial"
  , "BitAnd"
  , "BitClear"
  , "BitGet"
  , "BitLength"
  , "BitNot"
  , "BitOr"
  , "BitSet"
  , "BitShiftLeft"
  , "BitShiftRight"
  , "BitXor"
  , "ByteArrayQ"
  , "CarmichaelLambda"
  , "Cancel"
  , "ChineseRemainder"
  , "Complex"
  , "ComplexExpand"
  , "CompositeQ"
  , "Conjugate"
  , "Coefficient"
  , "CoefficientList"
  , "Collect"
  , "Comap"
  , "ComapApply"
  , "ComposeList"
  , "Construct"
  , "ContinuedFraction"
  , "Context"
  , "Contexts"
  , "CountRoots"
  , "Decompose"
  , "Denominator"
  , "DigitCount"
  , "Discriminant"
  , "DiscreteDelta"
  , "DivisorSigma"
  , "Divisors"
  , "Equal"
  , "EvenQ"
  , "ExactNumberQ"
  , "EulerPhi"
  , "EulerE"
  , "Expand"
  , "Exponent"
  , "FailureQ"
  , "FactorInteger"
  , "Factor"
  , "FactorList"
  , "FullSimplify"
  , "Fibonacci"
  , "FixedPoint"
  , "FixedPointList"
  , "Fold"
  , "FoldList"
  , "FoldWhile"
  , "FoldWhileList"
  , "FoldPair"
  , "FoldPairList"
  , "FromContinuedFraction"
  , "FromDigits"
  , "GCD"
  , "Greater"
  , "GreaterEqual"
  , "GroebnerBasis"
  , "HarmonicNumber"
  , "IntegerDigits"
  , "IntegerExponent"
  , "IntegerLength"
  , "IntegerPartitions"
  , "IntegerQ"
  , "IntegerReverse"
  , "InexactNumberQ"
  , "Im"
  , "Inequality"
  , "IsolatingInterval"
  , "JacobiSymbol"
  , "JordanTotient"
  , "KroneckerDelta"
  , "KroneckerSymbol"
  , "LCM"
  , "Less"
  , "LessEqual"
  , "LiouvilleLambda"
  , "LucasL"
  , "MapAll"
  , "MapApply"
  , "MachineIntegerQ"
  , "MachineNumberQ"
  , "Max"
  , "Min"
  , "MinimalPolynomial"
  , "MissingQ"
  , "Mod"
  , "MonomialList"
  , "ModularInverse"
  , "MoebiusMu"
  , "Multinomial"
  , "MultiplicativeOrder"
  , "N"
  , "NameQ"
  , "Names"
  , "Nest"
  , "NestList"
  , "NextPrime"
  , "Numerator"
  , "Not"
  , "NumberQ"
  , "NumericQ"
  , "OddQ"
  , "Or"
  , "Overflow"
  , "PartitionsP"
  , "PartitionsQ"
  , "Plus"
  , "Power"
  , "PowerMod"
  , "Precision"
  , "SetAccuracy"
  , "SetPrecision"
  , "Prime"
  , "PrimePi"
  , "PrimePowerQ"
  , "PrimeQ"
  , "PolynomialQ"
  , "PolynomialGCD"
  , "PolynomialLCM"
  , "PolynomialMod"
  , "PolynomialQuotient"
  , "PolynomialReduce"
  , "PolynomialRemainder"
  , "PrimitiveRoot"
  , "Quotient"
  , "QuotientRemainder"
  , "Ramp"
  , "RandomPermutation"
  , "RandomSample"
  , "RamanujanTau"
  , "Rational"
  , "Re"
  , "RealAbs"
  , "RealSign"
  , "RealValuedNumberQ"
  , "ReIm"
  , "Resultant"
  , "Root"
  , "RootIntervals"
  , "RootReduce"
  , "RootSum"
  , "Sign"
  , "Sqrt"
  , "Simplify"
  , "Solve"
  , "StringQ"
  , "Subresultants"
  , "Symbol"
  , "SymbolName"
  , "Times"
  , "ToRadicals"
  , "Together"
  , "TrueQ"
  , "UnitStep"
  , "Unitize"
  , "Underflow"
  , "Unequal"
  , "Unique"
  , "Variables"
  ] <> numericTranscendentalDispatchHeads

numericTranscendentalDispatchHeads :: [Text]
numericTranscendentalDispatchHeads =
  [ "Exp", "Log"
  , "Sin", "Cos", "Tan", "Cot", "Sec", "Csc"
  , "ArcSin", "ArcCos", "ArcTan", "ArcCot", "ArcSec", "ArcCsc"
  , "Sinh", "Cosh", "Tanh", "Coth", "Sech", "Csch"
  , "ArcSinh", "ArcCosh", "ArcTanh", "ArcCoth", "ArcSech", "ArcCsch"
  , "Haversine", "InverseHaversine", "Gudermannian", "InverseGudermannian"
  , "SinDegrees", "CosDegrees", "TanDegrees", "CotDegrees", "SecDegrees", "CscDegrees"
  , "ArcSinDegrees", "ArcCosDegrees", "ArcTanDegrees", "ArcCotDegrees"
  , "ArcSecDegrees", "ArcCscDegrees"
  ]

directSessionDispatchHead :: Text -> Bool
directSessionDispatchHead name =
  name
    `elem` ( [ "Set"
             , "SetDelayed"
             , "Unset"
             , "TagSet"
             , "TagSetDelayed"
             , "TagUnset"
             , "Clear"
             , "ClearAll"
             , "Attributes"
             , "SetAttributes"
             , "ClearAttributes"
             , "Protect"
             , "Unprotect"
             , "CompoundExpression"
             , "If"
             , "Which"
             , "Switch"
             , "Piecewise"
             , "And"
             , "Or"
             , "Catch"
             , "Throw"
             , "Enclose"
             , "Confirm"
             , "ConfirmBy"
             , "ConfirmMatch"
             , "ConfirmAssert"
             , "Assert"
             , "Abort"
             , "CheckAbort"
             , "AbortProtect"
             , "WithCleanup"
             , "Pause"
             , "AbsoluteTiming"
             , "TimeConstrained"
             , "TimeRemaining"
             , "Reap"
             , "Sow"
             , "Failsafe"
             , "Break"
             , "Continue"
             , "Return"
             , "Label"
             , "Goto"
             , "Message"
             , "MessageList"
             , "In"
             , "InString"
             , "Out"
             , "Off"
             , "On"
             , "Quiet"
             , "Check"
             , "AppendTo"
             , "Print"
             , "Evaluate"
             , "ReleaseHold"
             , "Inactive"
             , "Activate"
             , "Select"
             , "Discard"
             , "SelectFirst"
             , "ValueQ"
             , "OwnValues"
             , "DownValues"
             , "UpValues"
             , "SubValues"
             , "NValues"
             , "Module"
             , "With"
             , "Block"
             , "InheritedBlock"
             , "Table"
             , "Do"
             , "For"
             , "While"
             , "Sum"
             , "Product"
             ]
               <> heldPatternBuiltinHeads
               <> Map.keys inPlaceArithmeticVariants
               <> Map.keys updateConstructors
               <> staticHeldHeadNames
           )

evaluateHeldSessionPatternBuiltin
  :: Text
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateHeldSessionPatternBuiltin headName depth session arguments' =
  case (headName, arguments') of
    ("MatchQ", [subjectExpression, patternExpression]) -> do
      (subject, subjectSession) <-
        evaluateSessionAt (depth + 1) session subjectExpression
      (matches, updated) <-
        sessionPatternMatches depth subjectSession subject patternExpression
      Right (sessionBoolean matches, updated)
    ("Cases", subjectExpression : patternExpression : extras)
      | length extras <= 3 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (preparedPattern, patternSession) <-
            prepareCasePattern depth subjectSession patternExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth patternSession extras
          evaluateSessionCases
            depth
            updated
            subject
            preparedPattern
            evaluatedExtras
    ("DeleteCases", subjectExpression : patternExpression : extras)
      | length extras <= 3 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth subjectSession extras
          evaluateSessionDeleteCases
            depth
            updated
            subject
            patternExpression
            evaluatedExtras
    ("FirstCase", subjectExpression : patternExpression : extras)
      | length extras <= 2 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (preparedPattern, updated) <-
            prepareCasePattern depth subjectSession patternExpression
          evaluateSessionFirstCase
            depth
            updated
            subject
            preparedPattern
            extras
    ("Position", subjectExpression : patternExpression : extras)
      | length extras <= 3 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth subjectSession extras
          evaluateSessionPosition
            depth
            updated
            subject
            patternExpression
            evaluatedExtras
    ("FirstPosition", subjectExpression : patternExpression : extras)
      | length extras <= 2 -> do
          (subject, updated) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          evaluateSessionFirstPosition
            depth
            updated
            subject
            patternExpression
            extras
    ("Count", subjectExpression : patternExpression : extras)
      | length extras <= 2 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth subjectSession extras
          evaluateSessionCount
            depth
            updated
            subject
            patternExpression
            evaluatedExtras
    ("FreeQ", subjectExpression : patternExpression : extras)
      | length extras <= 2 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth subjectSession extras
          evaluateSessionFreeQ
            depth
            updated
            subject
            patternExpression
            evaluatedExtras
    ("MemberQ", subjectExpression : patternExpression : extras)
      | length extras <= 2 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth subjectSession extras
          evaluateSessionMemberQ
            depth
            updated
            subject
            patternExpression
            evaluatedExtras
    (sequenceHead, [subjectExpression, patternExpression])
      | sequenceHead `elem` ["SequenceCases", "SequencePosition", "SequenceCount"] -> do
          (subject, updated) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          evaluateSessionSequenceSearch
            sequenceHead
            depth
            updated
            subject
            patternExpression
    (stringHead, subjectExpression : patternExpression : extras)
      | stringHead `elem` ["StringCases", "StringReplace"]
      , length extras <= 1 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (preparedPattern, patternSession) <-
            prepareSessionPatternRules depth subjectSession patternExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth patternSession extras
          evaluateSessionStringTransform
            stringHead
            depth
            updated
            subject
            preparedPattern
            evaluatedExtras
    ("Replace", subjectExpression : rulesExpression : extras)
      | length extras <= 2 -> do
          (subject, subjectSession) <-
            evaluateSessionAt (depth + 1) session subjectExpression
          (rules, rulesSession) <-
            prepareSessionPatternRules depth subjectSession rulesExpression
          (evaluatedExtras, updated) <-
            evaluateArguments depth rulesSession extras
          evaluateSessionReplace depth updated subject rules evaluatedExtras
    ("ReplaceAll", [subjectExpression, rulesExpression]) -> do
      (subject, subjectSession) <-
        evaluateSessionAt (depth + 1) session subjectExpression
      (rules, updated) <-
        prepareSessionPatternRules depth subjectSession rulesExpression
      evaluateSessionReplaceAll depth updated subject rules
    ("ReplaceRepeated", [subjectExpression, rulesExpression]) -> do
      (subject, subjectSession) <-
        evaluateSessionAt (depth + 1) session subjectExpression
      (rules, updated) <-
        prepareSessionPatternRules depth subjectSession rulesExpression
      evaluateSessionReplaceRepeated depth updated subject rules
    ("ReplaceAt", [subjectExpression, rulesExpression, positionsExpression]) -> do
      (subject, subjectSession) <-
        evaluateSessionAt (depth + 1) session subjectExpression
      (rules, rulesSession) <-
        prepareSessionPatternRules depth subjectSession rulesExpression
      (positions, updated) <-
        evaluateSessionAt (depth + 1) rulesSession positionsExpression
      evaluateSessionReplaceAt depth updated subject rules positions
    _ -> sessionFailure session (heldPatternArityMessage headName)

prepareCasePattern
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
prepareCasePattern depth session expression =
  case sessionPatternRule expression of
    Just _ -> prepareSessionPatternRules depth session expression
    Nothing -> Right (expression, session)

sessionBoolean :: Bool -> Expr
sessionBoolean True = Symbol "True"
sessionBoolean False = Symbol "False"

heldPatternArityMessage :: Text -> Text
heldPatternArityMessage = \case
  "MatchQ" -> "MatchQ expects exactly two arguments."
  "FreeQ" ->
    "FreeQ expects an expression, a pattern, and an optional level specification."
  "Cases" ->
    "Cases expects an expression, a pattern or transformation rule, and optional level and match limits."
  "DeleteCases" ->
    "DeleteCases expects an expression, a pattern, and optional level and match limits."
  "FirstCase" ->
    "FirstCase expects an expression, a pattern, and optional default and level specification."
  "Replace" ->
    "Replace expects an expression, replacement rules, and an optional level specification."
  "ReplaceAll" -> "ReplaceAll expects exactly two arguments."
  "ReplaceRepeated" -> "ReplaceRepeated expects exactly two arguments."
  "ReplaceAt" -> "ReplaceAt expects exactly three arguments."
  "Position" ->
    "Position expects an expression, a pattern, and optional level and result limits."
  "FirstPosition" ->
    "FirstPosition expects an expression, a pattern, and optional default and level specification."
  "Count" -> "Count expects an expression, a pattern, and an optional levelspec."
  "MemberQ" ->
    "MemberQ expects an expression, a pattern, and an optional level specification."
  "SequenceCases" -> "SequenceCases expects a list and a List pattern."
  "SequencePosition" -> "SequencePosition expects a list and a List pattern."
  "SequenceCount" -> "SequenceCount expects a list and a List pattern."
  "StringCases" ->
    "StringCases expects a string, a pattern or rule, and an optional match limit."
  "StringReplace" ->
    "StringReplace expects a string, rules, and an optional replacement limit."
  headName -> headName <> " received an unsupported argument list."

patternFailure
  :: EvaluationSession
  -> Text
  -> RuntimeResult EvaluationExit value
patternFailure session message =
  Left (SessionEvaluationFailure (EvaluationError message) session)

sessionLevelBounds
  :: EvaluationSession
  -> Expr
  -> RuntimeResult EvaluationExit LevelBounds
sessionLevelBounds session specification =
  case normalizeLevelSpec specification of
    P.Left (EvaluationError message) ->
      Left (SessionEvaluationFailure (EvaluationError message) session)
    P.Right bounds -> Right bounds

patternSelectionLimit
  :: Text
  -> EvaluationSession
  -> Maybe Expr
  -> RuntimeResult EvaluationExit (Maybe Integer)
patternSelectionLimit operation session limit =
  case selectionLimit operation limit of
    P.Left (EvaluationError message) ->
      Left (SessionEvaluationFailure (EvaluationError message) session)
    P.Right normalized -> Right normalized

evaluateSessionCount
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCount depth session subject patternExpression extras = do
  let (includeHeads, positionalExtras) =
        stripSessionHeadsOption False extras
  bounds <- case positionalExtras of
    [] -> sessionLevelBounds session (Call (Symbol "List") [Integer 1])
    [specification] -> sessionLevelBounds session specification
    _ -> patternFailure session "Count expects two or three arguments."
  (count, updated) <-
    countSessionMatches
      depth
      session
      bounds
      patternExpression
      (collectPatternRecords includeHeads 0 subject)
  Right (Integer count, updated)

evaluateSessionFreeQ
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFreeQ depth session subject patternExpression extras = do
  let (includeHeads, positionalExtras) =
        stripSessionHeadsOption True extras
  bounds <- case positionalExtras of
    [] ->
      sessionLevelBounds
        session
        (Call (Symbol "List") [Integer 0, Symbol "Infinity"])
    [specification] -> sessionLevelBounds session specification
    _ -> patternFailure session "FreeQ expects two or three arguments."
  (found, updated) <-
    firstSessionMatch
      depth
      session
      bounds
      patternExpression
      (collectPatternRecords includeHeads 0 subject)
  Right (sessionBoolean (not found), updated)

evaluateSessionMemberQ
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMemberQ depth session subject patternExpression extras = do
  let (includeHeads, positionalExtras) = stripSessionHeadsOption False extras
  bounds <- case positionalExtras of
    [] -> sessionLevelBounds session (Call (Symbol "List") [Integer 1])
    [specification] -> sessionLevelBounds session specification
    _ -> patternFailure session "MemberQ expects an expression, a pattern, and an optional level specification."
  (found, updated) <-
    firstSessionMatch
      depth
      session
      bounds
      patternExpression
      (collectPatternRecords includeHeads 0 subject)
  Right (sessionBoolean found, updated)

countSessionMatches
  :: Int
  -> EvaluationSession
  -> LevelBounds
  -> Expr
  -> [PatternRecord]
  -> SessionResult Integer
countSessionMatches depth = go 0
 where
  go count session _ _ [] = Right (count, session)
  go count session bounds patternExpression (PatternRecord value positive negative : rest)
    | not (levelMatches bounds positive negative) =
        go count session bounds patternExpression rest
    | otherwise = do
        (matches, updated) <-
          sessionPatternMatches depth session value patternExpression
        go
          (if matches then count + 1 else count)
          updated
          bounds
          patternExpression
          rest

firstSessionMatch
  :: Int
  -> EvaluationSession
  -> LevelBounds
  -> Expr
  -> [PatternRecord]
  -> SessionResult Bool
firstSessionMatch depth = go
 where
  go session _ _ [] = Right (False, session)
  go session bounds patternExpression (PatternRecord value positive negative : rest)
    | not (levelMatches bounds positive negative) =
        go session bounds patternExpression rest
    | otherwise = do
        (matches, updated) <-
          sessionPatternMatches depth session value patternExpression
        if matches
          then Right (True, updated)
          else go updated bounds patternExpression rest

evaluateSessionCases
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCases depth session subject patternOrRule extras = do
  let (includeHeads, positionalExtras) =
        stripSessionHeadsOption False extras
  (bounds, limit) <- case positionalExtras of
    [] -> do
      normalized <- sessionLevelBounds session (Integer 1)
      Right (normalized, Nothing)
    [specification] -> do
      normalized <- sessionLevelBounds session specification
      Right (normalized, Nothing)
    [specification, limitExpression] -> do
      normalized <- sessionLevelBounds session specification
      normalizedLimit <-
        patternSelectionLimit "Cases" session (Just limitExpression)
      Right (normalized, normalizedLimit)
    _ -> patternFailure session "Cases expects between two and four arguments."
  let rule = sessionPatternRule patternOrRule
      patternExpression =
        case rule of
          Just (SessionPatternRule pattern' _) -> pattern'
          Nothing -> patternOrRule
  (results, updated) <-
    collectSessionCases
      depth
      session
      bounds
      limit
      patternExpression
      rule
      (collectPatternRecords includeHeads 0 subject)
  Right (Call (Symbol "List") results, updated)

evaluateSessionSequenceSearch
  :: Text
  -> Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionSequenceSearch operation depth session subject patternExpression = do
  items <- case subject of
    Call (Symbol listHead) values
      | isSessionSystemHead "List" listHead -> Right values
    _ ->
      patternFailure
        session
        (operation <> " expects a List as its first argument.")
  arity <- case sessionSequencePatternArity patternExpression of
    Just value
      | value > 0 -> Right value
    Just _ ->
      patternFailure
        session
        "SequenceCases / SequencePosition / SequenceCount expect a nonempty fixed-arity List pattern."
    Nothing ->
      patternFailure
        session
        "SequenceCases / SequencePosition / SequenceCount expect a fixed-arity List pattern, optionally wrapped in Condition or HoldPattern."
  (spans, updated) <- collect 0 [] session items arity
  Right
    ( case operation of
        "SequenceCases" ->
          evaluatedList
            [ evaluatedList (take arity (drop start items))
            | (start, _) <- spans
            ]
        "SequencePosition" ->
          evaluatedList
            [ evaluatedList
                [ Integer (fromIntegral start + 1)
                , Integer (fromIntegral end)
                ]
            | (start, end) <- spans
            ]
        _ -> Integer (fromIntegral (length spans))
    , updated
    )
 where
  collect start retained current items arity
    | start >= length items = Right (retained, current)
    | start + arity > length items = Right (retained, current)
    | otherwise = do
        let candidate = evaluatedList (take arity (drop start items))
        (matches, matchedSession) <-
          sessionPatternMatches depth current candidate patternExpression
        if matches
          then
            collect
              (start + arity)
              (retained <> [(start, start + arity)])
              matchedSession
              items
              arity
          else collect (start + 1) retained matchedSession items arity

sessionSequencePatternArity :: Expr -> Maybe Int
sessionSequencePatternArity = \case
  Call (Symbol wrapperHead) (inner : _)
    | isSessionSystemHead "Condition" wrapperHead
        || isSessionSystemHead "HoldPattern" wrapperHead ->
        sessionSequencePatternArity inner
  Call (Symbol listHead) patterns
    | isSessionSystemHead "List" listHead -> Just (length patterns)
  _ -> Nothing

evaluateSessionStringTransform
  :: Text
  -> Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionStringTransform operation depth session subject patternExpression extras = do
  limit <- case extras of
    [] -> Right Nothing
    [limitExpression] ->
      patternSelectionLimit operation session (Just limitExpression)
    _ -> patternFailure session (heldPatternArityMessage operation)
  case operation of
    "StringCases" ->
      sessionStringThread
        operation
        (\current source -> do
            (results, updated) <-
              collectSessionStringCases
                depth
                current
                source
                (SP.normalizeStringCasesSpecs patternExpression)
                limit
            Right (evaluatedList results, updated)
        )
        session
        subject
    _ -> do
      specifications <- case SP.normalizeStringReplaceSpecs patternExpression of
        P.Left message -> patternFailure session message
        P.Right values -> Right values
      sessionStringThread
        operation
        (\current source ->
            replaceSessionStringMatches
              depth
              current
              source
              specifications
              limit
        )
        session
        subject

sessionStringThread
  :: Text
  -> (EvaluationSession -> Text -> SessionResult Expr)
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
sessionStringThread operation scalar = go
 where
  go current (String source) = scalar current source
  go current (Call (Symbol listHead) values)
    | isSessionSystemHead "List" listHead = do
        (threaded, updated) <- threadValues current values
        Right (evaluatedList threaded, updated)
  go current _ =
    sessionFailure
      current
      (operation <> " expects a string or a list of strings.")

  threadValues current [] = Right ([], current)
  threadValues current (value : rest) = do
    (threaded, threadedSession) <- go current value
    (following, updated) <- threadValues threadedSession rest
    Right (threaded : following, updated)

evaluateSessionStringExpression
  :: Int
  -> Map.Map Text Expr
  -> Expr
  -> PatternSession Expr
evaluateSessionStringExpression depth bindings expression =
  PatternSession $ \session ->
    evaluateSessionAt
      (depth + 1)
      session
      (substituteNamedSymbols bindings expression)

runSessionStringPattern
  :: EvaluationSession
  -> SP.StringPatternM PatternSession value
  -> SessionResult value
runSessionStringPattern session action = do
  (result, updated) <- runPatternSession (SP.runStringPatternM action) session
  case result of
    P.Left message -> patternFailure updated message
    P.Right value -> Right (value, updated)

applySessionStringMatch
  :: Int
  -> EvaluationSession
  -> Text
  -> SP.StringFoundMatch
  -> SessionResult (Maybe Expr)
applySessionStringMatch depth session source found =
  runSessionStringPattern
    session
    ( SP.applyStringPatternSpecM
        (evaluateSessionStringExpression depth)
        source
        found
    )

sessionStringMatchesForSpecAt
  :: Int
  -> EvaluationSession
  -> Text
  -> Int
  -> SP.StringPatternSpec
  -> SessionResult [SP.StringFoundMatch]
sessionStringMatchesForSpecAt depth session source start specification =
  runSessionStringPattern
    session
    ( SP.stringPatternMatchesForSpecAtM
        (evaluateSessionStringExpression depth)
        source
        start
        specification
    )

collectSessionStringCases
  :: Int
  -> EvaluationSession
  -> Text
  -> [SP.StringPatternSpec]
  -> Maybe Integer
  -> SessionResult [Expr]
collectSessionStringCases depth = go 0 0 []
 where
  go position matchCount retained session source specifications remaining
    | maybe False (matchCount >=) remaining =
        Right (retained, session)
    | position > T.length source = Right (retained, session)
    | otherwise = do
        (result, matchedSession) <-
          firstApplicable session source position specifications
        case result of
          Nothing ->
            if position >= T.length source
              then Right (retained, matchedSession)
              else
                go
                  (position + 1)
                  matchCount
                  retained
                  matchedSession
                  source
                  specifications
                  remaining
          Just (found, value) ->
            let end = SP.stringMatchEnd found
                next = if end > position then end else position + 1
             in go
                  next
                  (matchCount + 1)
                  (retained <> spliceSessionCaseResult value)
                  matchedSession
                  source
                  specifications
                  remaining

  firstApplicable session _ _ [] = Right (Nothing, session)
  firstApplicable session source position (specification : rest) = do
    (matches, matchedSession) <-
      sessionStringMatchesForSpecAt depth session source position specification
    tryMatches matchedSession matches
   where
    tryMatches current [] = firstApplicable current source position rest
    tryMatches current (match : matches) = do
      (applied, appliedSession) <-
        applySessionStringMatch depth current source match
      case applied of
        Just value -> Right (Just (match, value), appliedSession)
        Nothing -> tryMatches appliedSession matches

replaceSessionStringMatches
  :: Int
  -> EvaluationSession
  -> Text
  -> [SP.StringPatternSpec]
  -> Maybe Integer
  -> SessionResult Expr
replaceSessionStringMatches depth = go 0 0 []
 where
  go position replacementCount pieces session source specifications limit
    | maybe False (replacementCount >=) limit =
        Right
          ( sessionStringExpressionFromPieces
              (pieces <> [String (T.drop position source)])
          , session
          )
    | position > T.length source =
        Right (sessionStringExpressionFromPieces pieces, session)
    | otherwise = do
        (result, matchedSession) <-
          firstApplicable session source position specifications
        case result of
          Nothing ->
            if position >= T.length source
              then
                Right
                  (sessionStringExpressionFromPieces pieces, matchedSession)
              else
                go
                  (position + 1)
                  replacementCount
                  (pieces <> [String (T.take 1 (T.drop position source))])
                  matchedSession
                  source
                  specifications
                  limit
          Just (found, value) ->
            let end = SP.stringMatchEnd found
                next = if end > position then end else position + 1
             in go
                  next
                  (replacementCount + 1)
                  (pieces <> [value])
                  matchedSession
                  source
                  specifications
                  limit

  firstApplicable session _ _ [] = Right (Nothing, session)
  firstApplicable session source position (specification : rest) = do
    (matches, matchedSession) <-
      sessionStringMatchesForSpecAt depth session source position specification
    tryMatches matchedSession matches
   where
    tryMatches current [] = firstApplicable current source position rest
    tryMatches current (match : matches) = do
      (applied, appliedSession) <-
        applySessionStringMatch depth current source match
      case applied of
        Just value -> Right (Just (match, value), appliedSession)
        Nothing -> tryMatches appliedSession matches

sessionStringExpressionFromPieces :: [Expr] -> Expr
sessionStringExpressionFromPieces pieces = case removeNeutralEmpty (merge pieces) of
  [] -> String ""
  [single] -> single
  merged
    | all isStringValue merged ->
        String (T.concat [value | String value <- merged])
    | otherwise -> Call (Symbol "StringExpression") merged
 where
  removeNeutralEmpty merged
    | any (not . isStringValue) merged = filter (/= String "") merged
    | otherwise = merged
  merge = foldl append [] . concatMap flatten
  flatten (Call (Symbol stringExpressionHead) values)
    | isSessionSystemHead "StringExpression" stringExpressionHead =
        concatMap flatten values
  flatten expression = [expression]
  append retained (String value) = case reverse retained of
    String previous : rest -> reverse rest <> [String (previous <> value)]
    _ -> retained <> [String value]
  append retained value = retained <> [value]
  isStringValue String {} = True
  isStringValue _ = False

collectSessionCases
  :: Int
  -> EvaluationSession
  -> LevelBounds
  -> Maybe Integer
  -> Expr
  -> Maybe SessionPatternRule
  -> [PatternRecord]
  -> SessionResult [Expr]
collectSessionCases depth = go
 where
  go session _ (Just 0) _ _ _ = Right ([], session)
  go session _ _ _ _ [] = Right ([], session)
  go session bounds remaining patternExpression rule (PatternRecord value positive negative : rest)
    | not (levelMatches bounds positive negative) =
        go session bounds remaining patternExpression rule rest
    | otherwise = do
        (transformed, updated) <- case rule of
          Nothing -> do
            (matches, matchedSession) <-
              sessionPatternMatches depth session value patternExpression
            Right (if matches then Just value else Nothing, matchedSession)
          Just patternRule ->
            applySessionPatternRule depth session value patternRule
        case transformed of
          Nothing ->
            go updated bounds remaining patternExpression rule rest
          Just result -> do
            (following, completed) <-
              go
                updated
                bounds
                (subtractSessionLimit remaining)
                patternExpression
                rule
                rest
            Right (spliceSessionCaseResult result <> following, completed)

subtractSessionLimit :: Maybe Integer -> Maybe Integer
subtractSessionLimit Nothing = Nothing
subtractSessionLimit (Just value) = Just (value - 1)

spliceSessionCaseResult :: Expr -> [Expr]
spliceSessionCaseResult (Call (Symbol sequenceHead) values)
  | isSessionSystemHead "Sequence" sequenceHead = values
spliceSessionCaseResult (Symbol "Nothing") = []
spliceSessionCaseResult value = [value]

evaluateSessionFirstCase
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFirstCase depth session subject patternOrRule extras = do
  let (defaultValue, specification) = case extras of
        [] -> (Nothing, Integer 1)
        [defaultExpression] -> (Just defaultExpression, Integer 1)
        [defaultExpression, levelSpecification] ->
          (Just defaultExpression, levelSpecification)
        _ -> (Nothing, Integer 1)
  bounds <- sessionLevelBounds session specification
  let rule = sessionPatternRule patternOrRule
      patternExpression =
        case rule of
          Just (SessionPatternRule pattern' _) -> pattern'
          Nothing -> patternOrRule
  (matched, updated) <-
    firstSessionCase
      depth
      session
      bounds
      patternExpression
      rule
      (collectPatternRecords False 0 subject)
  case matched of
    Just value -> Right (value, updated)
    Nothing -> case defaultValue of
      Nothing -> Right (Call (Symbol "Missing") [String "NotFound"], updated)
      Just defaultExpression -> Right (defaultExpression, updated)

firstSessionCase
  :: Int
  -> EvaluationSession
  -> LevelBounds
  -> Expr
  -> Maybe SessionPatternRule
  -> [PatternRecord]
  -> SessionResult (Maybe Expr)
firstSessionCase depth = go
 where
  go session _ _ _ [] = Right (Nothing, session)
  go session bounds patternExpression rule (PatternRecord value positive negative : rest)
    | not (levelMatches bounds positive negative) =
        go session bounds patternExpression rule rest
    | otherwise = do
        (transformed, updated) <- case rule of
          Nothing -> do
            (matches, matchedSession) <-
              sessionPatternMatches depth session value patternExpression
            Right (if matches then Just value else Nothing, matchedSession)
          Just patternRule ->
            applySessionPatternRule depth session value patternRule
        case transformed of
          Just _ -> Right (transformed, updated)
          Nothing -> go updated bounds patternExpression rule rest

applySessionPatternRule
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionPatternRule
  -> SessionResult (Maybe Expr)
applySessionPatternRule depth session expression (SessionPatternRule patternExpression template) =
  case template of
    Call (Symbol conditionHead) [body, condition]
      | isSessionSystemHead "Condition" conditionHead -> do
          (instantiated, matchedSession) <-
            instantiateSessionPattern
              depth
              session
              expression
              patternExpression
              [body, condition]
          case instantiated of
            Just [instantiatedBody, instantiatedCondition] -> do
              (conditionResult, conditionSession) <-
                evaluateSessionAt
                  (depth + 1)
                  matchedSession
                  instantiatedCondition
              if conditionResult == Symbol "True"
                then do
                  (result, updated) <-
                    evaluateSessionAt
                      (depth + 1)
                      conditionSession
                      instantiatedBody
                  Right (Just result, updated)
                else Right (Nothing, conditionSession)
            _ -> Right (Nothing, matchedSession)
    _ -> do
      (instantiated, matchedSession) <-
        instantiateSessionPattern
          depth
          session
          expression
          patternExpression
          [template]
      case instantiated of
        Just [instantiatedTemplate] -> do
          (result, updated) <-
            evaluateSessionAt
              (depth + 1)
              matchedSession
              instantiatedTemplate
          Right (Just result, updated)
        _ -> Right (Nothing, matchedSession)

evaluateSessionDeleteCases
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionDeleteCases depth session subject patternExpression extras = do
  let (includeHeads, positionalExtras) =
        stripSessionHeadsOption False extras
  (bounds, limit) <- case positionalExtras of
    [] -> do
      normalized <- sessionLevelBounds session (Integer 1)
      Right (normalized, Nothing)
    [specification] -> do
      normalized <- sessionLevelBounds session specification
      Right (normalized, Nothing)
    [specification, limitExpression] -> do
      normalized <- sessionLevelBounds session specification
      normalizedLimit <-
        patternSelectionLimit "DeleteCases" session (Just limitExpression)
      Right (normalized, normalizedLimit)
    _ ->
      patternFailure
        session
        "DeleteCases expects between two and four arguments."
  (paths, updated) <-
    collectSessionMatchingPaths
      depth
      session
      bounds
      limit
      patternExpression
      (collectPositionPathRecords includeHeads 0 [] subject)
  if [] `elem` paths
    then Right (Call (Symbol "Sequence") [], updated)
    else do
      result <- deleteSessionPaths updated subject (sortOperationPaths paths)
      finishSessionRewrite depth updated subject result

deleteSessionPaths
  :: EvaluationSession
  -> Expr
  -> [[PathSelector]]
  -> RuntimeResult EvaluationExit Expr
deleteSessionPaths _ expression [] = Right expression
deleteSessionPaths session expression (path : rest) =
  case deleteAtPath path expression of
    Nothing ->
      Left
        ( SessionEvaluationFailure
            (EvaluationError "DeleteCases encountered an invalid matched path")
            session
        )
    Just updated -> deleteSessionPaths session updated rest

evaluateSessionPosition
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionPosition depth session subject patternExpression extras = do
  let (includeHeads, positionalExtras) =
        stripSessionHeadsOption True extras
  (bounds, limit) <- case positionalExtras of
    [] -> do
      normalized <-
        sessionLevelBounds
          session
          (Call (Symbol "List") [Integer 0, Symbol "Infinity"])
      Right (normalized, Nothing)
    [specification] -> do
      normalized <- sessionLevelBounds session specification
      Right (normalized, Nothing)
    [specification, limitExpression] -> do
      normalized <- sessionLevelBounds session specification
      normalizedLimit <-
        patternSelectionLimit "Position" session (Just limitExpression)
      Right (normalized, normalizedLimit)
    _ ->
      patternFailure
        session
        "Position expects an expression, a pattern, and optional level and result limits"
  (paths, updated) <-
    collectSessionMatchingPaths
      depth
      session
      bounds
      limit
      patternExpression
      (collectPositionPathRecords includeHeads 0 [] subject)
  Right
    ( Call (Symbol "List") (map pathExpression paths)
    , updated
    )

stripSessionHeadsOption :: Bool -> [Expr] -> (Bool, [Expr])
stripSessionHeadsOption defaultValue values = case reverse values of
  Call (Symbol ruleHead) [Symbol "Heads", Symbol value] : rest
    | ruleHead `elem` ["Rule", "RuleDelayed"]
    , value `elem` ["True", "False"] ->
        (value == "True", reverse rest)
  _ -> (defaultValue, values)

evaluateSessionFirstPosition
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFirstPosition depth session subject patternExpression extras = do
  let (defaultValue, specification) = case extras of
        [] ->
          ( Nothing
          , Call (Symbol "List") [Integer 0, Symbol "Infinity"]
          )
        [defaultExpression] ->
          ( Just defaultExpression
          , Call (Symbol "List") [Integer 0, Symbol "Infinity"]
          )
        [defaultExpression, levelSpecification] ->
          (Just defaultExpression, levelSpecification)
        _ ->
          ( Nothing
          , Call (Symbol "List") [Integer 0, Symbol "Infinity"]
          )
  bounds <- sessionLevelBounds session specification
  (paths, updated) <-
    collectSessionMatchingPaths
      depth
      session
      bounds
      (Just 1)
      patternExpression
      (collectPositionPathRecords True 0 [] subject)
  case paths of
    firstPath : _ -> Right (pathExpression firstPath, updated)
    [] -> case defaultValue of
      Nothing -> Right (Call (Symbol "Missing") [String "NotFound"], updated)
      Just defaultExpression -> Right (defaultExpression, updated)

collectSessionMatchingPaths
  :: Int
  -> EvaluationSession
  -> LevelBounds
  -> Maybe Integer
  -> Expr
  -> [PatternPathRecord]
  -> SessionResult [[PathSelector]]
collectSessionMatchingPaths depth = go
 where
  go session _ (Just 0) _ _ = Right ([], session)
  go session _ _ _ [] = Right ([], session)
  go session bounds remaining patternExpression (PatternPathRecord value positive negative path : rest)
    | not (levelMatches bounds positive negative) =
        go session bounds remaining patternExpression rest
    | otherwise = do
        (matches, updated) <-
          sessionPatternMatches depth session value patternExpression
        if matches
          then do
            (following, completed) <-
              go
                updated
                bounds
                (subtractSessionLimit remaining)
                patternExpression
                rest
            Right (path : following, completed)
          else go updated bounds remaining patternExpression rest

requireSessionPatternRules
  :: Text
  -> EvaluationSession
  -> Expr
  -> RuntimeResult EvaluationExit [SessionPatternRule]
requireSessionPatternRules operation session expression =
  case sessionPatternRuleSet expression of
    Just rules -> Right rules
    Nothing ->
      Left
        ( SessionEvaluationFailure
            ( EvaluationError
                (operation <> " expects a rule or flat list of rules")
            )
            session
        )

applySessionPatternRules
  :: Int
  -> EvaluationSession
  -> Expr
  -> [SessionPatternRule]
  -> SessionResult (Maybe Expr)
applySessionPatternRules = applySessionPatternRulesInContext False

applySessionPatternRulesInContext
  :: Bool
  -> Int
  -> EvaluationSession
  -> Expr
  -> [SessionPatternRule]
  -> SessionResult (Maybe Expr)
applySessionPatternRulesInContext _ _ session _ [] = Right (Nothing, session)
applySessionPatternRulesInContext heldContext depth session expression (rule : rest) = do
  (replacement, updated) <-
    if heldContext
      then applyHeldSessionPatternRule depth session expression rule
      else applySessionPatternRule depth session expression rule
  case replacement of
    Just _ -> Right (replacement, updated)
    Nothing ->
      applySessionPatternRulesInContext
        heldContext
        depth
        updated
        expression
        rest

applyHeldSessionPatternRule
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionPatternRule
  -> SessionResult (Maybe Expr)
applyHeldSessionPatternRule depth session expression (SessionPatternRule patternExpression template) =
  case template of
    Call (Symbol conditionHead) [body, condition]
      | isSessionSystemHead "Condition" conditionHead -> do
          (instantiated, matchedSession) <-
            instantiateSessionPattern
              depth
              session
              expression
              patternExpression
              [body, condition]
          case instantiated of
            Just [instantiatedBody, instantiatedCondition] -> do
              (conditionResult, updated) <-
                evaluateSessionAt
                  (depth + 1)
                  matchedSession
                  instantiatedCondition
              Right
                ( if conditionResult == Symbol "True"
                    then Just instantiatedBody
                    else Nothing
                , updated
                )
            _ -> Right (Nothing, matchedSession)
    _ -> do
      (instantiated, updated) <-
        instantiateSessionPattern
          depth
          session
          expression
          patternExpression
          [template]
      case instantiated of
        Just [result] -> Right (Just result, updated)
        _ -> Right (Nothing, updated)

evaluateSessionReplace
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionReplace depth session subject rulesExpression extras =
  case nestedSessionPatternRuleSets rulesExpression of
    Just nested ->
      evaluateNestedSessionReplacements
        (\current rules -> evaluateSessionReplace depth current subject rules extras)
        session
        nested
    Nothing -> do
      rules <-
        requireSessionPatternRules "Replace" session rulesExpression
      let (includeHeads, positionalExtras) =
            stripSessionHeadsOption False extras
      bounds <- case positionalExtras of
        [] -> sessionLevelBounds session (Call (Symbol "List") [Integer 0])
        [specification] -> sessionLevelBounds session specification
        _ -> patternFailure session "Replace expects two or three arguments."
      (result, updated) <-
        replaceSessionRecords
          depth
          session
          rules
          subject
          [ record
          | record@(PatternPathRecord _ positive negative _) <-
              collectPositionPathRecords includeHeads 0 [] subject
          , levelMatches bounds positive negative
          ]
      finishSessionRewrite depth updated subject result

replaceSessionRecords
  :: Int
  -> EvaluationSession
  -> [SessionPatternRule]
  -> Expr
  -> [PatternPathRecord]
  -> SessionResult Expr
replaceSessionRecords _ session _ current [] = Right (current, session)
replaceSessionRecords depth session rules current (PatternPathRecord _ _ _ path : rest) =
  case selectAtPath path current of
    Nothing ->
      sessionFailure session "Replace encountered an invalid selected path"
    Just selected -> do
      (replacement, updated) <-
        applySessionPatternRules depth session selected rules
      let next = case replacement of
            Nothing -> current
            Just value -> maybe current id (replaceAtPath path value current)
      replaceSessionRecords depth updated rules next rest

evaluateSessionReplaceAt
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionReplaceAt depth session subject rulesExpression positions = do
  rules <- requireSessionPatternRules "ReplaceAt" session rulesExpression
  paths <- case operationPositionPaths positions of
    Nothing ->
      patternFailure
        session
        "ReplaceAt received an invalid position specification"
    Just validPaths -> Right validPaths
  (result, updated) <-
    replaceSessionPaths
      depth
      session
      rules
      subject
      (sortOperationPaths paths)
  finishSessionRewrite depth updated subject result

replaceSessionPaths
  :: Int
  -> EvaluationSession
  -> [SessionPatternRule]
  -> Expr
  -> [[PathSelector]]
  -> SessionResult Expr
replaceSessionPaths _ session _ current [] = Right (current, session)
replaceSessionPaths depth session rules current (path : rest) =
  case selectAtPath path current of
    Nothing ->
      sessionFailure session "ReplaceAt encountered an invalid selected path"
    Just selected -> do
      (replacement, updated) <-
        applySessionPatternRules depth session selected rules
      next <- case replacement of
        Nothing -> Right current
        Just value -> case replaceAtPath path value current of
          Nothing ->
            patternFailure
              updated
              "ReplaceAt encountered an invalid selected path"
          Just replaced -> Right replaced
      replaceSessionPaths depth updated rules next rest

evaluateSessionReplaceAll
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionReplaceAll depth session subject rulesExpression =
  case nestedSessionPatternRuleSets rulesExpression of
    Just nested ->
      evaluateNestedSessionReplacements
        (evaluateSessionReplaceAll depth `flip` subject)
        session
        nested
    Nothing -> do
      rules <-
        requireSessionPatternRules "ReplaceAll" session rulesExpression
      replaceAllSessionTree depth session rules subject

evaluateNestedSessionReplacements
  :: (EvaluationSession -> Expr -> SessionResult Expr)
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateNestedSessionReplacements operation = go []
 where
  go results session [] =
    Right (Call (Symbol "List") (reverse results), session)
  go results session (rules : rest) = do
    (result, updated) <- operation session rules
    go (result : results) updated rest

replaceAllSessionTree
  :: Int
  -> EvaluationSession
  -> [SessionPatternRule]
  -> Expr
  -> SessionResult Expr
replaceAllSessionTree = replaceAllSessionTreeInContext False

replaceAllSessionTreeInContext
  :: Bool
  -> Int
  -> EvaluationSession
  -> [SessionPatternRule]
  -> Expr
  -> SessionResult Expr
replaceAllSessionTreeInContext heldContext depth session rules expression = do
  (rootReplacement, matchedSession) <-
    applySessionPatternRulesInContext
      heldContext
      depth
      session
      expression
      rules
  case rootReplacement of
    Just replacement -> Right (replacement, matchedSession)
    Nothing -> descend matchedSession expression
 where
  descend current association@(Call associationHead@(Symbol _) _)
    | Just entries <- sessionAssociationEntries association = do
        (updatedHead, headSession) <-
          replaceAllSessionTreeInContext
            heldContext
            depth
            current
            rules
            associationHead
        (updatedEntries, completed) <-
          replaceSessionAssociationEntries
            heldContext
            depth
            headSession
            rules
            entries
        Right
          ( if updatedHead == associationHead && updatedEntries == entries
              then association
              else if updatedHead == Symbol "Association"
              then
                normalizedSessionAssociation
                  (map sessionAssociationEntryExpr updatedEntries)
              else
                Call updatedHead (map sessionAssociationEntryExpr updatedEntries)
          , completed
          )
  descend current (Call expressionHead values) = do
    (updatedHead, headSession) <-
      replaceAllSessionTreeInContext
        heldContext
        depth
        current
        rules
        expressionHead
    let childHeldContext =
          heldContext || sessionReplacementHeldArgumentHead expressionHead
    (updatedValues, completed) <-
      replaceAllSessionValues
        childHeldContext
        depth
        headSession
        rules
        values
    Right
      ( if updatedHead == expressionHead && updatedValues == values
          then Call expressionHead values
          else if heldContext
          then Call updatedHead updatedValues
          else rebuildWithSplicing updatedHead updatedValues
      , completed
      )
  descend current value = Right (value, current)

sessionReplacementHeldArgumentHead :: Expr -> Bool
sessionReplacementHeldArgumentHead (Symbol name) =
  name
    `elem` [ "Function"
           , "Hold"
           , "HoldComplete"
           , "HoldForm"
           , "HoldPattern"
           , "Unevaluated"
           ]
sessionReplacementHeldArgumentHead _ = False

data SessionAssociationEntry =
  SessionAssociationEntry !Text !Expr !Expr
  deriving (Eq, Show)

sessionAssociationEntries :: Expr -> Maybe [SessionAssociationEntry]
sessionAssociationEntries (Call (Symbol associationHead) values)
  | isSessionSystemHead "Association" associationHead =
      traverse entry values
 where
  entry (Call (Symbol ruleHead) [key, value])
    | isSessionSystemHead "Rule" ruleHead
        || isSessionSystemHead "RuleDelayed" ruleHead =
        Just (SessionAssociationEntry ruleHead key value)
  entry _ = Nothing
sessionAssociationEntries _ = Nothing

sessionAssociationEntryExpr :: SessionAssociationEntry -> Expr
sessionAssociationEntryExpr (SessionAssociationEntry ruleHead key value) =
  Call (Symbol ruleHead) [key, value]

replaceSessionAssociationEntries
  :: Bool
  -> Int
  -> EvaluationSession
  -> [SessionPatternRule]
  -> [SessionAssociationEntry]
  -> SessionResult [SessionAssociationEntry]
replaceSessionAssociationEntries heldContext depth = go []
 where
  go retained session _ [] = Right (reverse retained, session)
  go retained session rules (SessionAssociationEntry ruleHead key value : rest) = do
    (updatedValue, updated) <-
      replaceAllSessionTreeInContext
        heldContext
        depth
        session
        rules
        value
    go
      (SessionAssociationEntry ruleHead key updatedValue : retained)
      updated
      rules
      rest

replaceAllSessionValues
  :: Bool
  -> Int
  -> EvaluationSession
  -> [SessionPatternRule]
  -> [Expr]
  -> SessionResult [Expr]
replaceAllSessionValues heldContext depth = go []
 where
  go retained session _ [] = Right (reverse retained, session)
  go retained session rules (value : rest) = do
    (updatedValue, updated) <-
      replaceAllSessionTreeInContext
        heldContext
        depth
        session
        rules
        value
    go (updatedValue : retained) updated rules rest

finishSessionRewrite
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Expr
finishSessionRewrite depth session original result
  | result == original = Right (result, session)
  | otherwise = evaluateSessionAt (depth + 1) session result

evaluateSessionReplaceRepeated
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionReplaceRepeated depth session subject rulesExpression =
  case nestedSessionPatternRuleSets rulesExpression of
    Just nested ->
      evaluateNestedSessionReplacements
        (evaluateSessionReplaceRepeated depth `flip` subject)
        session
        nested
    Nothing -> do
      rules <-
        requireSessionPatternRules
          "ReplaceRepeated"
          session
          rulesExpression
      iterateReplacement 0 session rules subject
 where
  iterateReplacement :: Int -> EvaluationSession -> [SessionPatternRule] -> Expr -> SessionResult Expr
  iterateReplacement iterations currentSession rules current
    | iterations >= 1024 =
        sessionFailure
          currentSession
          "ReplaceRepeated exceeded its iteration safety limit"
    | otherwise = do
        (rewritten, rewrittenSession) <-
          replaceAllSessionTree depth currentSession rules current
        if rewritten == current
          then Right (current, rewrittenSession)
          else
            iterateReplacement
              (iterations + 1)
              rewrittenSession
              rules
              rewritten
reduceSessionEvaluatedCall
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe (SessionResult Expr)
reduceSessionEvaluatedCall depth session = \case
  expression@(Call (Symbol "ToExpression") _) ->
    Just $ do
      parsed <- liftPureEvaluation session (reduceEvaluatedCall expression)
      evaluateSessionAt (depth + 1) session parsed
  Call (Symbol "Collect") values@[_, _, _] ->
    Just (evaluateSessionCollect depth session values)
  Call (Symbol "Exponent") values@[_, _, _] ->
    Just (evaluateSessionExponent depth session values)
  Call (Symbol "Normal") [expression]
    | Just expanded <-
        AlgebraicRoots.expandRootSumForNormal
          (sessionAlgebraicRootContext session)
          expression ->
        Just (evaluateSessionAt (depth + 1) session expanded)
  expression@(Call (Symbol normalizationHead) _)
    | normalizationHead
        `elem` ( [ "Collect"
                 , "Decompose"
                 , "Discriminant"
                 , "GroebnerBasis"
                 , "MonomialList"
                 , "N"
                 , "Normal"
                 , "PolynomialMod"
                 , "PolynomialReduce"
                 , "Resultant"
                 , "SetAccuracy"
                 , "SetPrecision"
                 , "Subresultants"
                 ]
                   <> numericTranscendentalDispatchHeads
               ) ->
    Just $ do
      reduced <- liftPureEvaluation session (reduceEvaluatedCall expression)
      if reduced == expression
        then Right (reduced, session)
        else evaluateSessionAt (depth + 1) session reduced
  expression@(Call (Symbol algebraicHead) values)
    | algebraicHead `elem` algebraicRootDispatchHeads ->
        Just $ case
          AlgebraicRoots.reduceAlgebraicRootBuiltin
            (sessionAlgebraicRootContext session)
            algebraicHead
            values of
          Nothing -> Right (expression, session)
          Just reduced
            | reduced == expression -> Right (reduced, session)
            | otherwise -> evaluateSessionAt (depth + 1) session reduced
  Call (Symbol "RandomSample") values ->
    Just $ case values of
      [expression] ->
        evaluateSessionRandomPlan session (Random.randomSamplePlan expression Nothing)
      [expression, count] ->
        evaluateSessionRandomPlan session (Random.randomSamplePlan expression (Just count))
      _ ->
        sessionFailure
          session
          "RandomSample expects an expression and an optional count."
  Call (Symbol "RandomPermutation") values ->
    Just $ case values of
      [lengthExpression] ->
        evaluateSessionRandomPlan session (Random.randomPermutationPlan lengthExpression)
      _ -> sessionFailure session "RandomPermutation expects an integer length."
  Call (Symbol "Symbol") values ->
    Just (evaluateSessionSymbol session values)
  Call (Symbol "SymbolName") values ->
    Just (evaluateSessionSymbolName session values)
  Call (Symbol "Unique") values ->
    Just (evaluateSessionUnique session values)
  Call (Symbol "Names") values ->
    Just (evaluateSessionNames session values)
  Call (Symbol "NameQ") values ->
    Just (evaluateSessionNameQ session values)
  Call (Symbol "Contexts") values ->
    Just (evaluateSessionContexts session values)
  Call (Symbol "Context") values ->
    Just (evaluateSessionContext session values)
  Call (Call (Symbol "SortBy") [function]) values ->
    Just $ case values of
      [subject] -> evaluateSessionSortBy False depth session [subject, function]
      _ ->
        sessionFailure
          session
          "SortBy[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "ReverseSortBy") [function]) values ->
    Just $ case values of
      [subject] -> evaluateSessionSortBy True depth session [subject, function]
      _ ->
        sessionFailure
          session
          "ReverseSortBy[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "OrderingBy") [functions]) values ->
    Just $ case values of
      [subject] -> evaluateSessionOrderingBy depth session [subject, functions]
      _ ->
        sessionFailure
          session
          "OrderingBy[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "MinimalBy") [functions]) values ->
    Just $ case values of
      [subject] ->
        evaluateSessionExtremeBy False depth session [subject, functions]
      _ ->
        sessionFailure
          session
          "MinimalBy[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "MaximalBy") [functions]) values ->
    Just $ case values of
      [subject] ->
        evaluateSessionExtremeBy True depth session [subject, functions]
      _ ->
        sessionFailure
          session
          "MaximalBy[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "Comap") [functions]) values ->
    Just $ case values of
      [subject] -> evaluateSessionComap False depth session [functions, subject]
      _ ->
        sessionFailure
          session
          "Comap[functions] expects exactly one argument when used as an operator."
  Call (Call (Symbol "ComapApply") [functions]) values ->
    Just $ case values of
      [subject] -> evaluateSessionComap True depth session [functions, subject]
      _ ->
        sessionFailure
          session
          "ComapApply[functions] expects exactly one argument when used as an operator."
  Call (Call (Symbol "MapAll") [function]) values ->
    Just $ case values of
      [subject] -> evaluateSessionMapAll depth session [function, subject]
      _ ->
        sessionFailure
          session
          "MapAll[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "MapApply") [function]) values ->
    Just $ case values of
      [subject] -> evaluateSessionMapApply depth session [function, subject]
      _ ->
        sessionFailure
          session
          "MapApply[f] expects exactly one argument when used as an operator."
  Call (Call (Symbol "MapIndexed") [function]) values ->
    Just $ case values of
      [subject] -> evaluateSessionMapIndexed depth session [function, subject]
      _ ->
        sessionFailure
          session
          "MapIndexed[f] expects exactly one argument when used as an operator."
  Call (Symbol "AssociationMap") values ->
    Just (evaluateSessionAssociationMap depth session values)
  Call (Symbol setHead) values
    | setHead `elem` ["Union", "Intersection", "Complement"]
    , any isSessionOptionRule values ->
        Just (evaluateSessionSetOperation setHead depth session values)
  Call (Symbol equalityHead) values
    | isSessionSystemHead "Equal" equalityHead
    , any isSessionOptionRule values ->
        Just (evaluateSessionEqualWithSameTest depth session values)
  Call (Symbol sortHead) values
    | any (`isSessionSystemHead` sortHead) ["Sort", "ReverseSort"]
    , length values == 2 ->
        Just
          ( evaluateSessionSort
              (isSessionSystemHead "ReverseSort" sortHead)
              depth
              session
              values
          )
  Call (Symbol orderingHead) values
    | isSessionSystemHead "Ordering" orderingHead
    , length values `elem` [3, 4] ->
        Just (evaluateSessionOrdering depth session values)
  Call (Symbol orderedHead) values
    | isSessionSystemHead "OrderedQ" orderedHead
    , length values == 2 ->
        Just (evaluateSessionOrderedQ depth session values)
  Call (Symbol arrayHead) values
    | arrayHead == "Array" ->
        Just (evaluateSessionArray depth session values)
  Call (Symbol arrayHead) values
    | any (`isSessionSystemHead` arrayHead) ["ArrayQ", "VectorQ", "MatrixQ"]
    , arrayPredicateHasTest arrayHead values ->
        Just (evaluateSessionArrayPredicate depth session arrayHead values)
  Call (Symbol truthHead) values
    | any (`isSessionSystemHead` truthHead) ["AllTrue", "AnyTrue", "NoneTrue"] ->
        Just (evaluateSessionTruthCollection depth session truthHead values)
  Call (Symbol tallyHead) values
    | any (`isSessionSystemHead` tallyHead) ["Tally", "Counts"]
    , length values == 2 ->
        Just (evaluateSessionTallyCounts depth session tallyHead values)
  Call (Symbol countsByHead) values
    | isSessionSystemHead "CountsBy" countsByHead ->
        Just (evaluateSessionCountsBy depth session values)
  Call (Symbol accumulateHead) values
    | isSessionSystemHead "Accumulate" accumulateHead
    , length values == 2 ->
        Just (evaluateSessionAccumulate depth session values)
  Call (Symbol containsOnlyHead) values
    | isSessionSystemHead "ContainsOnly" containsOnlyHead
    , Just test <- sessionContainsOnlyCallback values ->
        Just (evaluateSessionContainsOnly depth session test values)
  Call (Symbol "Apply") values ->
    Just (evaluateSessionApply depth session values)
  Call (Symbol "KeyMap") values ->
    Just (evaluateSessionKeyMap depth session values)
  Call (Symbol "KeyValueMap") values ->
    Just (evaluateSessionKeyValueMap depth session values)
  Call (Symbol "Map") values ->
    Just (evaluateSessionMap depth session values)
  Call (Symbol "Scan") values ->
    Just (evaluateSessionScan depth session values)
  Call (Symbol "Operate") values ->
    Just (evaluateSessionOperate depth session values)
  Call (Symbol "Inner") values ->
    Just (evaluateSessionInner depth session values)
  Call (Symbol "Outer") values ->
    Just (evaluateSessionOuter depth session values)
  Call (Symbol "Through") values ->
    Just (evaluateSessionThrough depth session values)
  Call (Symbol "Tr") values ->
    Just (evaluateSessionTr depth session values)
  Call (Symbol "MapAll") values ->
    Just (evaluateSessionMapAll depth session values)
  Call (Symbol "MapApply") values ->
    Just (evaluateSessionMapApply depth session values)
  Call (Symbol "MapIndexed") values ->
    Just (evaluateSessionMapIndexed depth session values)
  Call (Symbol "MapThread") values ->
    Just (evaluateSessionMapThread depth session values)
  Call (Symbol "BlockMap") values ->
    Just (evaluateSessionBlockMap depth session values)
  Call (Symbol "SubsetMap") values ->
    Just (evaluateSessionSubsetMap depth session values)
  Call (Symbol "FlattenAt") values ->
    Just (evaluateSessionFlattenAt session values)
  Call (Symbol "MapAt") values ->
    Just (evaluateSessionMapAt depth session values)
  Call (Symbol "Construct") values ->
    Just (evaluateSessionConstruct depth session values)
  Call (Symbol "ComposeList") values ->
    Just (evaluateSessionComposeList depth session values)
  Call (Symbol "Comap") values ->
    Just (evaluateSessionComap False depth session values)
  Call (Symbol "ComapApply") values ->
    Just (evaluateSessionComap True depth session values)
  Call (Symbol "Nest") values ->
    Just (evaluateSessionNest False depth session values)
  Call (Symbol "NestList") values ->
    Just (evaluateSessionNest True depth session values)
  Call (Symbol "NestWhile") values ->
    Just (evaluateSessionNestWhile False depth session values)
  Call (Symbol "NestWhileList") values ->
    Just (evaluateSessionNestWhile True depth session values)
  Call (Symbol "FixedPoint") values ->
    Just (evaluateSessionFixedPoint False depth session values)
  Call (Symbol "FixedPointList") values ->
    Just (evaluateSessionFixedPoint True depth session values)
  Call (Symbol "Fold") values ->
    Just (evaluateSessionFold False depth session values)
  Call (Symbol "FoldList") values ->
    Just (evaluateSessionFold True depth session values)
  Call (Symbol "FoldWhile") values ->
    Just (evaluateSessionFoldWhile False depth session values)
  Call (Symbol "FoldWhileList") values ->
    Just (evaluateSessionFoldWhile True depth session values)
  Call (Symbol "FoldPair") values ->
    Just (evaluateSessionFoldPair False depth session values)
  Call (Symbol "FoldPairList") values ->
    Just (evaluateSessionFoldPair True depth session values)
  Call (Symbol "Total") values ->
    Just (evaluateSessionTotal depth session values)
  Call (Symbol "SequenceFold") values ->
    Just (evaluateSessionSequenceFold False depth session values)
  Call (Symbol "SequenceFoldList") values ->
    Just (evaluateSessionSequenceFold True depth session values)
  Call (Symbol "Select") values ->
    Just (evaluateSessionSelect False depth session values)
  Call (Symbol "Discard") values ->
    Just (evaluateSessionSelect True depth session values)
  Call (Symbol "SelectFirst") values ->
    Just (evaluateSessionSelectFirst depth session values)
  Call (Symbol "SortBy") values ->
    Just (evaluateSessionSortBy False depth session values)
  Call (Symbol "ReverseSortBy") values ->
    Just (evaluateSessionSortBy True depth session values)
  Call (Symbol "OrderingBy") values ->
    Just (evaluateSessionOrderingBy depth session values)
  Call (Symbol "MinimalBy") values ->
    Just (evaluateSessionExtremeBy False depth session values)
  Call (Symbol "MaximalBy") values ->
    Just (evaluateSessionExtremeBy True depth session values)
  Call (Symbol "TakeWhile") values ->
    Just (evaluateSessionTakeWhile depth session values)
  Call (Symbol "LengthWhile") values ->
    Just (evaluateSessionLengthWhile depth session values)
  Call (Symbol "KeySelect") values ->
    Just (evaluateSessionKeySelect depth session values)
  _ -> Nothing

evaluateSessionRandomPlan
  :: EvaluationSession
  -> Random.RandomPlan Expr
  -> SessionResult Expr
evaluateSessionRandomPlan session = \case
  Random.RandomDone value -> Right (value, session)
  Random.RandomFailed failure ->
    sessionFailure session (Random.randomPlanErrorMessage failure)
  Random.RandomBelow exclusiveUpperBound resume ->
    RuntimeEffect
      (RandomBelow exclusiveUpperBound)
      (evaluateSessionRandomPlan session . resume)

algebraicRootDispatchHeads :: [Text]
algebraicRootDispatchHeads =
  [ "CountRoots"
  , "IsolatingInterval"
  , "MinimalPolynomial"
  , "Root"
  , "RootIntervals"
  , "RootReduce"
  , "RootSum"
  , "Solve"
  , "ToRadicals"
  ]

sessionAlgebraicRootContext
  :: EvaluationSession
  -> AlgebraicRoots.AlgebraicRootContext
sessionAlgebraicRootContext session =
  AlgebraicRoots.defaultAlgebraicRootContext
    { AlgebraicRoots.simplifyAlgebraicExpression = simplifyGenerated
    , AlgebraicRoots.maximumAlgebraicRootDegree = maximumDegree
    }
 where
  maximumDegree = case currentSpecialSessionSettingValue "$MaxRootDegree" session of
    Integer value -> value
    _ -> 1000

  simplifyGenerated expression =
    case evaluate expression of
      P.Left _ -> expression
      P.Right result -> result

evaluateSessionCollect
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCollect depth session values = case values of
  [expression, variableSpec, function] ->
    case
      PolynomialAlgebra.collectCoefficientPlan
        canonicalCompare
        expression
        variableSpec of
      Nothing -> Right (Call (Symbol "Collect") values, session)
      Just (PolynomialAlgebra.CollectDirect coefficient) ->
        evaluateSessionCallable depth session function [coefficient]
      Just (PolynomialAlgebra.CollectTerms terms) ->
        applyTerms function [] session terms
   where
    applyTerms _ retained currentSession [] =
      evaluateSessionAt
        (depth + 1)
        currentSession
        (Call (Symbol "Plus") (reverse retained))
    applyTerms callback retained currentSession ((monomial, coefficient) : rest) = do
      (transformed, transformedSession) <-
        evaluateSessionCallable depth currentSession callback [coefficient]
      (term, termSession) <-
        if monomial == Integer 1
          then Right (transformed, transformedSession)
          else
            evaluateSessionAt
              (depth + 1)
              transformedSession
              (Call (Symbol "Times") [monomial, transformed])
      applyTerms callback (term : retained) termSession rest
  _ -> Right (Call (Symbol "Collect") values, session)

evaluateSessionExponent
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionExponent depth session values = case values of
  [expression, form, function] ->
    case
      PolynomialAlgebra.exponentValuesForForm
        canonicalCompare
        expression
        form of
      Nothing -> Right (Call (Symbol "Exponent") values, session)
      Just exponentValues ->
        evaluateSessionCallable depth session function exponentValues
  _ -> Right (Call (Symbol "Exponent") values, session)

reduceSessionEvaluatedCallForDispatch
  :: Bool
  -> Int
  -> EvaluationSession
  -> Expr
  -> Maybe (SessionResult Expr)
reduceSessionEvaluatedCallForDispatch allowQualified depth session expression =
  case reducerDispatchView allowQualified session expression of
    Nothing -> reduceSessionEvaluatedCall depth session expression
    Just (dispatched, restore) ->
      fmap (mapSessionResultValue restore)
        (reduceSessionEvaluatedCall depth session dispatched)

reduceEvaluatedCallForDispatch
  :: Bool
  -> EvaluationSession
  -> Expr
  -> Either EvaluationError Expr
reduceEvaluatedCallForDispatch allowQualified session expression =
  case reducerDispatchView allowQualified session expression of
    Nothing -> reduceEvaluatedCall expression
    Just (dispatched, restore) ->
      restore <$> reduceEvaluatedCall dispatched

reducerDispatchView
  :: Bool
  -> EvaluationSession
  -> Expr
  -> Maybe (Expr, Expr -> Expr)
reducerDispatchView allowQualified session expression = case expression of
  Call (Symbol originalHead) values
    | isSystemSymbol originalHead
    , Just shortName <- normalizeSystemSymbolName originalHead ->
        if originalHead /= shortName && not allowQualified
          then Nothing
          else
            let barrierName = reducerBarrierName shortName session expression
                protectBareSameHead =
                  originalHead /= shortName
                    || not (symbolHasAttribute originalHead Flat session)
                dispatchedValues =
                  if protectBareSameHead
                    then map (shieldReducerArgument shortName barrierName) values
                    else values
                restore =
                  restoreReducerBarrier barrierName shortName
                    . restoreQualifiedSystemHead originalHead shortName
             in Just (Call (Symbol shortName) dispatchedValues, restore)
  Call (Call (Symbol originalHead) operatorArguments) values
    | isSystemSymbol originalHead
    , Just shortName <- normalizeSystemSymbolName originalHead ->
        if originalHead /= shortName && not allowQualified
          then Nothing
          else
            let restore = restoreQualifiedOperatorHead originalHead shortName
             in Just
                  ( Call
                      (Call (Symbol shortName) operatorArguments)
                      values
                  , restore
                  )
  _ -> Nothing

reducerBarrierName :: Text -> EvaluationSession -> Expr -> Text
reducerBarrierName shortName session expression = choose 0
 where
  baseName = "Tungsten`Private`QualifiedDispatchBarrier$" <> shortName
  choose suffix =
    let candidate =
          if suffix == (0 :: Integer)
            then baseName
            else baseName <> "$" <> T.pack (show suffix)
     in if Map.member candidate (sessionSymbols session)
            || expressionContainsSymbol candidate expression
          then choose (suffix + 1)
          else candidate

expressionContainsSymbol :: Text -> Expr -> Bool
expressionContainsSymbol target = \case
  Symbol name -> name == target
  Call expressionHead values ->
    expressionContainsSymbol target expressionHead
      || any (expressionContainsSymbol target) values
  Complex realPart imaginaryPart ->
    expressionContainsSymbol target realPart
      || expressionContainsSymbol target imaginaryPart
  SparseArray _ entries fill ->
    any
      (\(SparseEntry _ value) -> expressionContainsSymbol target value)
      entries
      || expressionContainsSymbol target fill
  _ -> False

shieldReducerArgument :: Text -> Text -> Expr -> Expr
shieldReducerArgument shortName barrierName = \case
  Call (Symbol nestedHead) values
    | nestedHead == shortName -> Call (Symbol barrierName) values
  value -> value

restoreReducerBarrier :: Text -> Text -> Expr -> Expr
restoreReducerBarrier barrierName shortName = go
 where
  go = \case
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

restoreQualifiedOperatorHead :: Text -> Text -> Expr -> Expr
restoreQualifiedOperatorHead qualifiedName shortName = \case
  Call (Call (Symbol resultHead) operatorArguments) values
    | resultHead == shortName ->
        Call (Call (Symbol qualifiedName) operatorArguments) values
  result -> result

mapSessionResultValue
  :: (value -> value)
  -> SessionResult value
  -> SessionResult value
mapSessionResultValue update =
  fmap (\(value, session) -> (update value, session))

evaluateSessionMessage
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMessage depth session = \case
  [] -> sessionFailure session "Message expects a message name."
  messageName : insertionExpressions
    | isSessionMessageName messageName -> do
        (insertions, updated) <-
          evaluateArguments depth session insertionExpressions
        appendSessionMessageInsertions depth updated messageName insertions
    | otherwise ->
        sessionFailure
          session
          "Message expects a message name of the form symbol::tag."

evaluateSessionMessageControl
  :: Text
  -> Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMessageControl _ enabled depth = go
 where
  go session [] = Right (Symbol "Null", session)
  go session (specificationExpression : rest) = do
    (specification, evaluated) <-
      evaluateSessionAt (depth + 1) session specificationExpression
    controlled <- setSessionMessageEnabled enabled evaluated specification
    go controlled rest

evaluateSessionQuiet
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionQuiet depth session = \case
  [body] ->
    evaluateSessionQuietBody
      depth
      session
      body
      (Symbol "All")
      (Symbol "None")
  [body, offSpecificationExpression] -> do
    (offSpecification, updated) <-
      evaluateSessionAt
        (depth + 1)
        session
        offSpecificationExpression
    evaluateSessionQuietBody
      depth
      updated
      body
      offSpecification
      (Symbol "None")
  [body, offSpecificationExpression, onSpecificationExpression] -> do
    (offSpecification, offSession) <-
      evaluateSessionAt
        (depth + 1)
        session
        offSpecificationExpression
    (onSpecification, updated) <-
      evaluateSessionAt
        (depth + 1)
        offSession
        onSpecificationExpression
    evaluateSessionQuietBody
      depth
      updated
      body
      offSpecification
      onSpecification
  _ -> sessionFailure session "Quiet expects one, two, or three arguments."

evaluateSessionQuietBody
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionQuietBody depth session body offSpecification onSpecification =
  restoreQuietScopes
    baselineDepth
    ( evaluateSessionAt
        (depth + 1)
        session
          { sessionQuietScopes =
              sessionQuietScopes session
                <> [QuietScope offSpecification onSpecification]
          }
        body
    )
 where
  baselineDepth = length (sessionQuietScopes session)

restoreQuietScopes :: Int -> SessionResult value -> SessionResult value
restoreQuietScopes baselineDepth result = inspectRuntimeResult result $ \case
  P.Right (value, session) ->
    Right
      ( value
      , session
          { sessionQuietScopes =
              take baselineDepth (sessionQuietScopes session)
          }
      )
  P.Left evaluationExit ->
    Left
      ( mapEvaluationExitSession
          ( \session ->
              session
                { sessionQuietScopes =
                    take baselineDepth (sessionQuietScopes session)
                }
          )
          evaluationExit
      )

evaluateSessionCheck
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCheck depth session = \case
  [body, fallback] ->
    evaluateSessionCheckBody depth session body fallback (Symbol "All")
  [body, fallback, specificationExpression] -> do
    (specification, updated) <-
      evaluateSessionAt (depth + 1) session specificationExpression
    evaluateSessionCheckBody depth updated body fallback specification
  _ -> sessionFailure session "Check expects two or three arguments."

evaluateSessionCheckBody
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateSessionCheckBody depth session body fallback specification =
  inspectRuntimeResult (evaluateSessionAt (depth + 1) scopedSession body) $ \case
    P.Right (value, stoppedSession) ->
      let (captured, restoredSession) =
            popSessionMessageCollector baselineDepth stoppedSession
       in if null captured
            then Right (value, restoredSession)
            else evaluateSessionAt (depth + 1) restoredSession fallback
    P.Left evaluationExit ->
      Left
        ( mapEvaluationExitSession
            (snd . popSessionMessageCollector baselineDepth)
            evaluationExit
        )
 where
  baselineDepth = length (sessionMessageCollectors session)
  scopedSession =
    session
      { sessionMessageCollectors =
          sessionMessageCollectors session
            <> [ MessageCollector
                   { messageCollectorSpecification = specification
                   , messageCollectorQuietDepth = length (sessionQuietScopes session)
                   , messageCollectorMessages = []
                   }
               ]
      }

popSessionMessageCollector
  :: Int
  -> EvaluationSession
  -> ([EvaluationMessage], EvaluationSession)
popSessionMessageCollector baselineDepth session =
  ( captured
  , session
      { sessionMessageCollectors =
          take baselineDepth (sessionMessageCollectors session)
      }
  )
 where
  captured = case drop baselineDepth (sessionMessageCollectors session) of
    collector : _ -> messageCollectorMessages collector
    [] -> []

setSessionMessageEnabled
  :: Bool
  -> EvaluationSession
  -> Expr
  -> RuntimeResult EvaluationExit EvaluationSession
setSessionMessageEnabled enabled session = \case
  Call (Symbol listHead) specifications
    | isSessionSystemHead "List" listHead ->
        setList session specifications
  Symbol name
    | isSessionSystemHead "Assert" name ->
        Right (session {sessionAssertEnabled = enabled})
  specification@(Symbol _) ->
    setSessionMessageEnabled
      enabled
      session
      (Call (Symbol "MessageName") [specification, String "trace"])
  specification@(Call (Symbol messageHead) _)
    | isSessionSystemHead "MessageName" messageHead ->
        Right
          session
            { sessionDisabledMessages =
                updateDisabledMessageKey
                  enabled
                  (fullForm specification)
                  (sessionDisabledMessages session)
            }
  _ -> invalid
 where
  setList current [] = Right current
  setList current (specification : rest) = do
    updated <- setSessionMessageEnabled enabled current specification
    setList updated rest

  invalid =
    Left
      ( SessionEvaluationFailure
          ( EvaluationError
              "On and Off expect message names, symbols, or lists of message names."
          )
          session
      )

updateDisabledMessageKey :: Bool -> Text -> Set.Set Text -> Set.Set Text
updateDisabledMessageKey True = Set.delete
updateDisabledMessageKey False = Set.insert

currentSessionMessageList :: EvaluationSession -> Expr
currentSessionMessageList session =
  Call
    (Symbol "List")
    [ Call (Symbol "HoldForm") [evaluationMessageFullName message]
    | message <- sessionGeneratedMessages session
    ]

evaluateSessionHistoricalMessageList
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionHistoricalMessageList depth session arguments' =
  case sessionHistoryLine session of
    Nothing -> Right (evaluatedList [], session)
    Just currentLine -> case arguments' of
      [lineSpecification] -> do
        (evaluatedIndex, updated) <-
          evaluateSessionAt (depth + 1) session lineSpecification
        case evaluatedIndex of
          Integer requested ->
            let resolved =
                  if requested < 0
                    then currentLine + requested
                    else requested
                messages =
                  Map.findWithDefault [] resolved (sessionMessageHistory updated)
             in Right
                  ( Call
                      (Symbol "List")
                      [ Call
                          (Symbol "HoldForm")
                          [evaluationMessageFullName message]
                      | message <- messages
                      ]
                  , updated
                  )
          _ ->
            sessionFailure
              updated
              "History functions expect an integer line specification."
      _ ->
        sessionFailure
          session
          "MessageList expects exactly one line specification."

evaluateSessionHistoryCall
  :: Text
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionHistoryCall headName depth session arguments' =
  case sessionHistoryLine session of
    Nothing -> Right (Call (Symbol headName) arguments', session)
    Just currentLine -> case arguments' of
      [] -> resolveAt (currentLine - 1) session
      [lineSpecification] -> do
        (evaluatedIndex, updated) <-
          evaluateSessionAt (depth + 1) session lineSpecification
        case evaluatedIndex of
          Integer requested ->
            resolveAt
              (if requested < 0 then currentLine + requested else requested)
              updated
          _ ->
            sessionFailure
              updated
              "History functions expect an integer line specification."
      _ ->
        sessionFailure
          session
          (headName <> " expects zero or one line specification.")
 where
  unresolved index = Call (Symbol headName) [Integer index]

  resolveAt index current = case headName of
    "Out" ->
      Right
        ( Map.findWithDefault
            (unresolved index)
            index
            (sessionOutputHistory current)
        , current
        )
    "InString" ->
      Right
        ( maybe
            (unresolved index)
            String
            (Map.lookup index (sessionInputStringHistory current))
        , current
        )
    _ -> case Map.lookup index (sessionInputHistory current) of
      Nothing -> Right (unresolved index, current)
      Just stored
        | Set.member index (sessionExpandingInputHistory current) ->
            Right (unresolved index, current)
        | otherwise ->
            restoreSessionInputExpansion
              (sessionExpandingInputHistory current)
              ( evaluateSessionAt
                  (depth + 1)
                  current
                    { sessionExpandingInputHistory =
                        Set.insert index (sessionExpandingInputHistory current)
                    }
                  stored
              )

restoreSessionInputExpansion
  :: Set.Set Integer
  -> SessionResult Expr
  -> SessionResult Expr
restoreSessionInputExpansion expanding result =
  inspectRuntimeResult result $ \case
    P.Right (value, session) ->
      Right
        ( value
        , session {sessionExpandingInputHistory = expanding}
        )
    P.Left evaluationExit ->
      Left
        ( mapEvaluationExitSession
            (\session -> session {sessionExpandingInputHistory = expanding})
            evaluationExit
        )

isSessionMessageName :: Expr -> Bool
isSessionMessageName = \case
  Call (Symbol messageHead) _ -> isSessionSystemHead "MessageName" messageHead
  _ -> False

renderMessageInsertion :: Expr -> Text
renderMessageInsertion = \case
  Call (Symbol formHead) [payload@(Call (Symbol listHead) values)]
    | isSessionSystemHead "FullForm" formHead
    , isSessionSystemHead "List" listHead
    , all isMessageNumericAtom values -> inputForm payload
  expression -> TextualForms.displayOutputText expression
 where
  isMessageNumericAtom = \case
    Integer _ -> True
    _ -> False

appendSessionMessageInsertions
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult Expr
appendSessionMessageInsertions depth session messageName insertions
  | sessionMessageIsDisabled messageName session =
      Right
        ( Symbol "Null"
        , appendSessionMessage messageName "Message generated." session
        )
  | otherwise = do
      (messageText, formattedSession) <-
        formatSessionMessageInsertions depth session insertions
      Right
        ( Symbol "Null"
        , appendEnabledSessionMessage messageName messageText formattedSession
        )

formatSessionMessageInsertions
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Text
formatSessionMessageInsertions depth = go []
 where
  go rendered session [] =
    Right
      ( if null rendered
          then "Message generated."
          else T.intercalate ", " (reverse rendered)
      , session
      )
  go rendered session (insertion : rest) = do
    (transformed, updated) <-
      applySessionMessagePrePrint depth session insertion
    go (renderMessageInsertion transformed : rendered) updated rest

applySessionMessagePrePrint
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
applySessionMessagePrePrint depth session insertion =
  case symbolOwnValueFor "$MessagePrePrint" session of
    Nothing -> Right (insertion, session)
    Just _ -> do
      (function, updated) <-
        evaluateSessionAt (depth + 1) session (Symbol "$MessagePrePrint")
      case function of
        Symbol name
          | isSessionSystemHead "Automatic" name ->
              Right (insertion, updated)
        _ -> evaluateSessionCallable depth updated function [insertion]

evaluateSessionPrint
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionPrint depth session values = do
  (evaluatedValues, updated) <- evaluateArguments depth session values
  Right
    ( Symbol "Null"
    , updated
        { sessionPrints =
            sessionPrints updated <> [T.concat (map renderPrintValue evaluatedValues)]
        }
    )

renderPrintValue :: Expr -> Text
renderPrintValue = TextualForms.displayOutputText

evaluateSessionSelectionOperator
  :: Text
  -> Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionSelectionOperator headName depth session criterion = do
  (evaluatedCriterion, updated) <-
    evaluateSessionAt (depth + 1) session criterion
  Right
    ( Call
        (Symbol "Function")
        [ Call
            (Symbol headName)
            [Call (Symbol "Slot") [], evaluatedCriterion]
        ]
    , updated
    )

evaluateSessionCallable
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCallable depth session function arguments' = case function of
  Symbol nothingHead
    | isSessionSystemHead "Nothing" nothingHead -> do
        (_, updated) <- evaluateArguments depth session arguments'
        Right (Symbol "Nothing", updated)
  Call (Symbol sameAsHead) [comparison]
    | isSessionSystemHead "SameAs" sameAsHead ->
        Right
          ( sessionBoolean (all (== comparison) arguments')
          , session
          )
  Call (Symbol compositionHead) functions
    | isSessionSystemHead "Composition" compositionHead ->
        evaluateSessionComposition False depth session functions arguments'
  Call (Symbol compositionHead) functions
    | isSessionSystemHead "RightComposition" compositionHead ->
        evaluateSessionComposition True depth session functions arguments'
  Call (Symbol scanHead) scanArguments
    | isSessionSystemHead "Scan" scanHead ->
        case scanArguments of
          [callbackFunction] -> case arguments' of
            [subject] ->
              evaluateSessionScan depth session [callbackFunction, subject]
            _ ->
              sessionFailure
                session
                "Scan[f] expects exactly one argument when used as an operator."
          [callbackFunction, levelSpecification] -> case arguments' of
            [subject] ->
              evaluateSessionScan
                depth
                session
                [callbackFunction, subject, levelSpecification]
            _ ->
              sessionFailure
                session
                "Scan[f, levelspec] expects exactly one argument when used as an operator."
          _ ->
            evaluateSessionAt
              (depth + 1)
              session
              (Call function arguments')
  Call (Symbol associationHead) associationValues
    | isSessionSystemHead "Association" associationHead
    , [key] <- arguments'
    , let association = Call (Symbol "Association") associationValues
    , Just collection <- sessionOrderedCollection association
    , sessionCollectionAssociation collection ->
        case sessionAssociationItemIndex
          (SessionKeySelector key)
          (sessionCollectionItems collection) of
          Nothing ->
            Right
              (Call (Symbol "Missing") [String "KeyAbsent", key], session)
          Just index -> case sessionListItemAt index (sessionCollectionItems collection) of
            Nothing ->
              Right
                (Call (Symbol "Missing") [String "KeyAbsent", key], session)
            Just selected -> Right (sessionItemValue selected, session)
  Call (Symbol failsafeHead) failsafeArguments
    | isSessionSystemHead "Failsafe" failsafeHead
    , length failsafeArguments `elem` [1, 2, 3] ->
        evaluateSessionFailsafeApply
          depth
          session
          failsafeArguments
          arguments'
  Call (Symbol functionHead) functionArguments
    | isSessionSystemHead "Function" functionHead -> do
        instantiated <-
          liftPureEvaluation
            session
            ( instantiateFunctionCallWithHead
                (Symbol functionHead)
                functionArguments
                arguments'
            )
        evaluateSessionAt (depth + 1) session instantiated
  _ ->
    evaluateSessionAt
      (depth + 1)
      session
      (Call function arguments')

isSessionStructuralCallable :: Expr -> Bool
isSessionStructuralCallable = \case
  Call (Symbol sameAsHead) [_]
    | isSessionSystemHead "SameAs" sameAsHead -> True
  Call (Symbol callableHead) arguments' ->
    isSessionSystemHead "Composition" callableHead
      || isSessionSystemHead "RightComposition" callableHead
      || ( isSessionSystemHead "Scan" callableHead
             && length arguments' `elem` [1, 2]
         )
      || ( isSessionSystemHead "Failsafe" callableHead
             && length arguments' `elem` [1, 2, 3]
         )
  _ -> False

evaluateSessionComposition
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> [Expr]
  -> SessionResult Expr
evaluateSessionComposition rightComposition depth session functions arguments' =
  case if rightComposition then functions else reverse functions of
    [] ->
      Right
        ( case arguments' of
            [argument] -> argument
            _ -> evaluatedList arguments'
        , session
        )
    firstFunction : remainingFunctions -> do
      (initial, initialSession) <-
        applyCompositionFunction session firstFunction arguments'
      applyUnary remainingFunctions initial initialSession
 where
  applyCompositionFunction currentSession function functionArguments =
    case function of
      Call (Symbol functionHead) _
        | isSessionSystemHead "Function" functionHead ->
            let stageResult =
                  evaluateSessionCallable
                    depth
                    currentSession
                    function
                    functionArguments
             in case stageResult of
                  Left failure@(SessionEvaluationFailure (EvaluationError message) _)
                    | message == "Unsupported Function parameter specification." ->
                        -- Python recovers malformed Function specifications at
                        -- the staged application. Valid named functions with
                        -- too few arguments instead abort the whole composition.
                        recoverEvaluationFailure
                          (Call function functionArguments)
                          (Left failure)
                  _ -> stageResult
      _ ->
        evaluateSessionCallable
          depth
          currentSession
          function
          functionArguments

  applyUnary [] current currentSession = Right (current, currentSession)
  applyUnary (function : rest) current currentSession = do
    (updatedValue, updatedSession) <-
      applyCompositionFunction currentSession function [current]
    applyUnary rest updatedValue updatedSession

evaluateSessionAssociationMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAssociationMap depth session = \case
  [function, Call (Symbol "List") keys] -> do
    (rules, updated) <- mapKeys function [] session keys
    Right (normalizedSessionAssociation rules, updated)
  [_, _] ->
    sessionFailure
      session
      "AssociationMap currently supports only the key-list form."
  _ -> sessionFailure session "AssociationMap expects exactly two arguments."
 where
  mapKeys _ retained currentSession [] = Right (retained, currentSession)
  mapKeys function retained currentSession (key : rest) = do
    (value, updated) <-
      evaluateSessionCallable depth currentSession function [key]
    mapKeys
      function
      (retained <> [Call (Symbol "Rule") [key, value]])
      updated
      rest

sessionListOrAssociationCollection :: Expr -> Maybe SessionOrderedCollection
sessionListOrAssociationCollection expression@(Call (Symbol expressionHead) _)
  | isSessionSystemHead "List" expressionHead = sessionOrderedCollection expression
  | isSessionSystemHead "Association" expressionHead = do
      collection <- sessionOrderedCollection expression
      if sessionCollectionAssociation collection then Just collection else Nothing
sessionListOrAssociationCollection _ = Nothing

evaluateSessionArray
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionArray depth session values = case values of
  [function, dimensionsExpression] ->
    build function dimensionsExpression Nothing
  [function, dimensionsExpression, originsExpression] ->
    build function dimensionsExpression (Just originsExpression)
  _ -> sessionFailure session "Array expects two or three arguments."
 where
  build function dimensionsExpression originsExpression = do
    arbitraryDimensions <-
      liftSessionText session (sessionArrayDimensions dimensionsExpression)
    origins <-
      liftSessionText
        session
        (sessionArrayOrigins (length arbitraryDimensions) originsExpression)
    case arbitraryDimensions of
      0 : _ -> Right (evaluatedList [], session)
      _ -> do
        dimensions <-
          liftSessionText session (traverse boundedDimension arbitraryDimensions)
        if sessionDenseArrayNodes dimensions > 1000000
          then sessionFailure session "Array output exceeds the native materialization limit."
          else buildLevel function dimensions origins [] session

  buildLevel function [] origins reversedIndices current =
    evaluateSessionCallable
      depth
      current
      function
      [ Integer (origin + fromIntegral index)
      | (origin, index) <- zip origins (reverse reversedIndices)
      ]
  buildLevel function (dimension : remaining) origins reversedIndices current =
    buildChildren 0 [] current
   where
    buildChildren index retained childSession
      | index >= dimension = Right (evaluatedList retained, childSession)
      | otherwise = do
          (child, updated) <-
            buildLevel
              function
              remaining
              origins
              (index : reversedIndices)
              childSession
          buildChildren (index + 1) (retained <> [child]) updated

sessionArrayDimensions :: Expr -> Either Text [Integer]
sessionArrayDimensions (Integer dimension) =
  pure <$> nonnegative dimension
sessionArrayDimensions (Call (Symbol listHead) dimensions)
  | isSessionSystemHead "List" listHead = traverse requireDimension dimensions
 where
  requireDimension (Integer dimension) = nonnegative dimension
  requireDimension _ = P.Left "Array expects an integer argument."
sessionArrayDimensions _ =
  P.Left "Array expects an integer dimension or a list of dimensions."

nonnegative :: Integer -> Either Text Integer
nonnegative dimension
  | dimension < 0 = P.Left "Array expects non-negative dimensions."
  | otherwise = P.Right dimension

boundedDimension :: Integer -> Either Text Int
boundedDimension dimension
  | dimension > toInteger (maxBound :: Int) =
      P.Left "Array dimension is too large for this runtime."
  | otherwise = P.Right (fromInteger dimension)

sessionArrayOrigins :: Int -> Maybe Expr -> Either Text [Integer]
sessionArrayOrigins rank Nothing = P.Right (replicate rank 1)
sessionArrayOrigins rank (Just (Integer origin)) = P.Right (replicate rank origin)
sessionArrayOrigins 1 (Just (Call (Symbol listHead) [Integer lower, Integer _upper]))
  | isSessionSystemHead "List" listHead = P.Right [lower]
sessionArrayOrigins rank (Just (Call (Symbol listHead) origins))
  | isSessionSystemHead "List" listHead
  , length origins /= rank =
      P.Left "Array origin list must have one entry per array dimension."
  | isSessionSystemHead "List" listHead = traverse requireOrigin origins
 where
  requireOrigin (Integer origin) = P.Right origin
  requireOrigin _ = P.Left "Array origin entries must be explicit integers."
sessionArrayOrigins _ (Just _) =
  P.Left "Array currently expects an integer origin or a list of integer origins."

sessionDenseArrayNodes :: [Int] -> Integer
sessionDenseArrayNodes = go 1 0
 where
  go _ total [] = total
  go prefix total (dimension : remaining) =
    let nextPrefix = prefix * fromIntegral dimension
        nextTotal = total + nextPrefix
     in if nextTotal > 1000000
          then nextTotal
          else go nextPrefix nextTotal remaining

liftSessionText
  :: EvaluationSession
  -> Either Text value
  -> RuntimeResult EvaluationExit value
liftSessionText current = \case
  P.Left message -> patternFailure current message
  P.Right value -> Right value

arrayPredicateHasTest :: Text -> [Expr] -> Bool
arrayPredicateHasTest operation values
  | isSessionSystemHead "ArrayQ" operation = length values == 3
  | otherwise = length values == 2

evaluateSessionArrayPredicate
  :: Int
  -> EvaluationSession
  -> Text
  -> [Expr]
  -> SessionResult Expr
evaluateSessionArrayPredicate depth session operation values = do
  let (subject, test, shapeArguments) = case values of
        [expression, depthExpression, predicate] ->
          (expression, predicate, [expression, depthExpression])
        [expression, predicate] -> (expression, predicate, [expression])
        _ -> (Symbol "Null", Symbol "False", [])
  shapeResult <-
    liftPureEvaluation
      session
      (reduceEvaluatedCall (Call (Symbol operation) shapeArguments))
  if shapeResult /= Symbol "True"
    then Right (shapeResult, session)
    else testElements test session (arrayPredicateValues subject)
 where
  testElements _ current [] = Right (Symbol "True", current)
  testElements predicate current (value : remaining) = do
    (outcome, updated) <-
      evaluateSessionCallable depth current predicate [value]
    if outcome == Symbol "True"
      then testElements predicate updated remaining
      else Right (Symbol "False", updated)

arrayPredicateValues :: Expr -> [Expr]
arrayPredicateValues (SparseArray dimensions entries fill) =
  ( if product dimensions > fromIntegral (length entries)
      then [fill]
      else []
  )
    <> [value | SparseEntry _ value <- entries]
arrayPredicateValues (Call (Symbol listHead) values)
  | isSessionSystemHead "List" listHead = concatMap arrayPredicateValues values
arrayPredicateValues expression = [expression]

evaluateSessionTruthCollection
  :: Int
  -> EvaluationSession
  -> Text
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTruthCollection depth session operation = \case
  [subject, test] -> case sessionListOrAssociationCollection subject of
    Nothing ->
      sessionFailure session (operation <> " expects a list or association.")
    Just collection ->
      testValues session (map sessionItemValue (sessionCollectionItems collection))
   where
    testValues current [] =
      Right (Symbol (if isAny then "False" else "True"), current)
    testValues current (value : remaining) = do
      (outcome, updated) <-
        evaluateSessionCallable depth current test [value]
      let succeeded = outcome == Symbol "True"
      if isAny
        then
          if succeeded
            then Right (Symbol "True", updated)
            else testValues updated remaining
        else
          if isNone
            then
              if succeeded
                then Right (Symbol "False", updated)
                else testValues updated remaining
            else
              if succeeded
                then testValues updated remaining
                else Right (Symbol "False", updated)
    isAny = isSessionSystemHead "AnyTrue" operation
    isNone = isSessionSystemHead "NoneTrue" operation
  _ ->
    sessionFailure
      session
      (operation <> " expects a list and a test function.")

evaluateSessionTallyCounts
  :: Int
  -> EvaluationSession
  -> Text
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTallyCounts depth session operation = \case
  [subject, test] -> case sessionListOrAssociationCollection subject of
    Nothing ->
      sessionFailure session (operation <> " expects a list or association.")
    Just collection -> do
      (groups, updated) <-
        groupValues [] session (map sessionItemValue (sessionCollectionItems collection))
      let row (key, count) = evaluatedList [key, Integer count]
          rule (key, count) = Call (Symbol "Rule") [key, Integer count]
      Right
        ( if isSessionSystemHead "Tally" operation
            then evaluatedList (map row groups)
            else normalizedSessionAssociation (map rule groups)
        , updated
        )
   where
    groupValues retained current [] = Right (retained, current)
    groupValues retained current (value : remaining) = do
      (matching, updated) <- findGroup 0 current value retained
      let next = case matching of
            Nothing -> retained <> [(value, 1)]
            Just index ->
              let (key, count) = retained !! index
               in replaceSessionListIndex index (key, count + 1) retained
      groupValues next updated remaining
    findGroup _ current _ [] = Right (Nothing, current)
    findGroup index current value ((key, _) : remaining) = do
      (outcome, updated) <-
        evaluateSessionCallable depth current test [key, value]
      if outcome == Symbol "True"
        then Right (Just index, updated)
        else findGroup (index + 1) updated value remaining
  _ ->
    sessionFailure
      session
      ( operation
          <> if isSessionSystemHead "Tally" operation
            then " expects a list and an optional binary test."
            else " expects a list or association and an optional binary test."
      )

evaluateSessionCountsBy
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCountsBy depth session = \case
  [subject, function] -> case sessionListOrAssociationCollection subject of
    Nothing -> sessionFailure session "CountsBy expects a list or association."
    Just collection -> do
      (groups, updated) <-
        countKeys [] session (map sessionItemValue (sessionCollectionItems collection))
      Right
        ( normalizedSessionAssociation
            [Call (Symbol "Rule") [key, Integer count] | (key, count) <- groups]
        , updated
        )
   where
    countKeys retained current [] = Right (retained, current)
    countKeys retained current (value : remaining) = do
      (key, updated) <- evaluateSessionCallable depth current function [value]
      let next = case findIndex ((== key) . fst) retained of
            Nothing -> retained <> [(key, 1)]
            Just index ->
              let (firstKey, count) = retained !! index
               in replaceSessionListIndex index (firstKey, count + 1) retained
      countKeys next updated remaining
  _ -> sessionFailure session "CountsBy expects a list and a key function."

evaluateSessionAccumulate
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAccumulate depth session = \case
  [subject, combiner] -> case sessionListOrAssociationCollection subject of
    Nothing -> sessionFailure session "Accumulate expects a list or association."
    Just collection -> do
      (accumulated, updated) <-
        accumulate session (map sessionItemValue (sessionCollectionItems collection))
      let items = zipWith replaceSessionItemValue (sessionCollectionItems collection) accumulated
      Right (rebuildSessionCollection collection items, updated)
   where
    accumulate current [] = Right ([], current)
    accumulate current (firstValue : remaining) =
      go firstValue [firstValue] current remaining
    go _ retained current [] = Right (retained, current)
    go accumulator retained current (value : remaining) = do
      (next, updated) <-
        evaluateSessionCallable depth current combiner [accumulator, value]
      go next (retained <> [next]) updated remaining
  _ ->
    sessionFailure
      session
      "Accumulate expects a list and an optional binary combiner."

sessionContainsOnlyCallback :: [Expr] -> Maybe Expr
sessionContainsOnlyCallback values = case drop 2 values of
  [] -> Nothing
  options -> foldl retain Nothing options
 where
  retain _current (Call (Symbol ruleHead) [Symbol optionName, function])
    | isSessionSystemHead "Rule" ruleHead
        || isSessionSystemHead "RuleDelayed" ruleHead
    , isSessionSystemHead "SameTest" optionName =
        if isAutomatic function then Nothing else Just function
  retain current _ = current
  isAutomatic (Symbol name) = isSessionSystemHead "Automatic" name
  isAutomatic _ = False

evaluateSessionContainsOnly
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionContainsOnly depth session test values = case take 2 values of
  [left, right] ->
    case (sessionListOrAssociationCollection left, sessionListOrAssociationCollection right) of
      (Just leftCollection, Just rightCollection) ->
        checkLeft
          session
          (map sessionItemValue (sessionCollectionItems leftCollection))
          (map sessionItemValue (sessionCollectionItems rightCollection))
      _ -> sessionFailure session "ContainsOnly expects a list or association."
  _ ->
    sessionFailure
      session
      "ContainsOnly expects two arguments and an optional SameTest rule."
 where
  checkLeft current [] _ = Right (Symbol "True", current)
  checkLeft current (value : remaining) candidates = do
    (found, updated) <- anyMatch current value candidates
    if found
      then checkLeft updated remaining candidates
      else Right (Symbol "False", updated)
  anyMatch current _ [] = Right (False, current)
  anyMatch current value (candidate : remaining) = do
    (outcome, updated) <-
      evaluateSessionCallable depth current test [value, candidate]
    if outcome == Symbol "True"
      then Right (True, updated)
      else anyMatch updated value remaining

evaluateSessionMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMap depth session values =
 case stripSessionHeadsOption False values of
  (includeHeads, [function, subject]) -> case sessionOrderedCollection subject of
    Nothing -> Right (subject, session)
    Just collection -> do
      (mapped, updated) <- mapItems function [] session (sessionCollectionItems collection)
      let rebuilt = rebuildSessionCollection collection mapped
      if includeHeads && not (sessionCollectionAssociation collection)
        then case rebuilt of
          Call expressionHead arguments' -> do
            (mappedHead, headSession) <-
              evaluateSessionCallable depth updated function [expressionHead]
            Right (Call mappedHead arguments', headSession)
          _ -> Right (rebuilt, updated)
        else Right (rebuilt, updated)
  (includeHeads, [function, subject, levelSpecification]) -> do
    (bounds, boundsSession) <-
      liftSessionLevelBounds
        session
        levelSpecification
    evaluateSessionMapLevels
      depth
      includeHeads
      function
      bounds
      0
      boundsSession
      subject
  _ ->
    sessionFailure
      session
      "Map expects a function, an expression, and an optional level specification."
 where
  mapItems _ retained currentSession [] = Right (retained, currentSession)
  mapItems function retained currentSession (item : rest) = do
    (value, updated) <-
      evaluateSessionCallable depth currentSession function [sessionItemValue item]
    mapItems
      function
      (retained <> [replaceSessionItemValue item value])
      updated
      rest

evaluateSessionScan
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionScan depth session values =
  case stripSessionHeadsOption False values of
    (_includeHeads, [_function]) ->
      Right (Call (Symbol "Scan") values, session)
    (includeHeads, [function, subject]) ->
      scanWithBounds
        includeHeads
        function
        (SessionLevelBounds 1 1)
        session
        subject
    (includeHeads, [function, subject, levelSpecification]) -> do
      (bounds, boundsSession) <-
        liftSessionLevelBounds session levelSpecification
      scanWithBounds includeHeads function bounds boundsSession subject
    _ ->
      sessionFailure
        session
        "Scan expects a function, an expression, and an optional level specification."
 where
  scanWithBounds includeHeads function bounds currentSession subject = do
    (_, updated) <-
      scanTree includeHeads function bounds 0 currentSession subject
    Right (Symbol "Null", updated)

  scanTree includeHeads function bounds positive currentSession expression = do
    (_, descendantsSession) <-
      case sessionOrderedCollection expression of
        Just collection
          | sessionCollectionAssociation collection ->
              scanItems
                includeHeads
                function
                bounds
                positive
                currentSession
                (sessionCollectionItems collection)
        _ -> case expression of
          Call expressionHead arguments' -> do
            (_, headSession) <-
              if includeHeads
                then
                  scanTree
                    includeHeads
                    function
                    bounds
                    (positive + 1)
                    currentSession
                    expressionHead
                else Right (expressionHead, currentSession)
            scanValues
              includeHeads
              function
              bounds
              positive
              headSession
              arguments'
          _ -> Right (expression, currentSession)
    if sessionLevelMatches bounds positive expression
      then do
        (_, callbackSession) <-
          evaluateSessionCallable
            depth
            descendantsSession
            function
            [expression]
        Right (expression, callbackSession)
      else Right (expression, descendantsSession)

  scanItems _ _ _ _ currentSession [] =
    Right (Symbol "Null", currentSession)
  scanItems includeHeads function bounds positive currentSession (item : rest) = do
    (_, updated) <-
      scanTree
        includeHeads
        function
        bounds
        (positive + 1)
        currentSession
        (sessionItemValue item)
    scanItems includeHeads function bounds positive updated rest

  scanValues _ _ _ _ currentSession [] =
    Right (Symbol "Null", currentSession)
  scanValues includeHeads function bounds positive currentSession (value : rest) = do
    (_, updated) <-
      scanTree
        includeHeads
        function
        bounds
        (positive + 1)
        currentSession
        value
    scanValues includeHeads function bounds positive updated rest

evaluateSessionMapIndexed
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMapIndexed depth session = \case
  [function] ->
    Right (Call (Symbol "MapIndexed") [function], session)
  [function, subject] ->
    mapTree function (SessionLevelBounds 1 1) 0 [] session subject
  [function, subject, levelSpecification] -> do
    (bounds, boundsSession) <-
      liftSessionLevelBounds session levelSpecification
    mapTree function bounds 0 [] boundsSession subject
  _ ->
    sessionFailure
      session
      "MapIndexed expects a function, an expression, and an optional level specification."
 where
  mapTree function bounds positive path currentSession expression = do
    (rebuilt, rebuiltSession) <-
      case sessionOrderedCollection expression of
        Just collection
          | sessionCollectionAssociation collection -> do
              (mappedItems, updated) <-
                walkItems
                  function
                  bounds
                  positive
                  path
                  []
                  currentSession
                  (sessionCollectionItems collection)
              Right (rebuildSessionCollection collection mappedItems, updated)
        _ -> case expression of
          Call expressionHead values -> do
            (mappedValues, updated) <-
              walkValues
                function
                bounds
                positive
                path
                1
                []
                currentSession
                values
            Right (normalizeEvaluatedCall expressionHead mappedValues, updated)
          _ -> Right (expression, currentSession)
    if positive >= 1 && sessionLevelMatches bounds positive rebuilt
      then
        evaluateSessionCallable
          depth
          rebuiltSession
          function
          [rebuilt, Call (Symbol "List") path]
      else Right (rebuilt, rebuiltSession)

  walkItems _ _ _ _ retained currentSession [] =
    Right (retained, currentSession)
  walkItems function bounds positive path retained currentSession (item : rest) = do
    let component = case sessionItemKey item of
          Just key -> Call (Symbol "Key") [key]
          Nothing -> Integer (sessionItemIndex item)
    (mapped, updated) <-
      mapTree
        function
        bounds
        (positive + 1)
        (path <> [component])
        currentSession
        (sessionItemValue item)
    walkItems
      function
      bounds
      positive
      path
      (retained <> [replaceSessionItemValue item mapped])
      updated
      rest

  walkValues _ _ _ _ _ retained currentSession [] =
    Right (retained, currentSession)
  walkValues function bounds positive path index retained currentSession (value : rest) = do
    (mapped, updated) <-
      mapTree
        function
        bounds
        (positive + 1)
        (path <> [Integer index])
        currentSession
        value
    walkValues
      function
      bounds
      positive
      path
      (index + 1)
      (retained <> [mapped])
      updated
      rest

evaluateSessionMapThread
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMapThread depth session = \case
  [function, sequences] ->
    threadSequences function sequences 1 session
  [function, sequences, Integer requestedDepth]
    | requestedDepth < 0 ->
        sessionFailure session "MapThread expects a non-negative depth."
    | requestedDepth > fromIntegral (maxBound :: Int) ->
        threadSequences function sequences maxBound session
    | otherwise ->
        threadSequences function sequences (fromIntegral requestedDepth) session
  [_, _, _] ->
    sessionFailure session "MapThread expects an integer argument."
  _ ->
    sessionFailure
      session
      "MapThread expects a function, a list of sequences, and an optional level."
 where
  threadSequences
    :: Expr
    -> Expr
    -> Int
    -> EvaluationSession
    -> SessionResult Expr
  threadSequences function sequences requestedDepth currentSession =
    case sequences of
      Call (Symbol listHead) sequenceValues
        | isSessionSystemHead "List" listHead ->
            if null sequenceValues
              then Right (Call (Symbol "List") [], currentSession)
              else threadAtDepth function requestedDepth currentSession sequenceValues
      _ ->
        sessionFailure
          currentSession
          "MapThread expects a list of sequences."

  threadAtDepth
    :: Expr
    -> Int
    -> EvaluationSession
    -> [Expr]
    -> SessionResult Expr
  threadAtDepth function remaining currentSession sequenceValues
    | remaining == 0 =
        evaluateSessionCallable depth currentSession function sequenceValues
    | otherwise =
        case traverse parallelListValues sequenceValues of
          Nothing ->
            sessionFailure
              currentSession
              "MapThread expects parallel List structures down to the requested depth."
          Just parallelValues -> case parallelValues of
            [] -> Right (Call (Symbol "List") [], currentSession)
            firstValues : remainingValues
              | any ((/= length firstValues) . length) remainingValues ->
                  sessionFailure
                    currentSession
                    "MapThread expects sequences of the same length."
              | otherwise ->
                  threadColumns
                    function
                    (remaining - 1)
                    []
                    currentSession
                    parallelValues

  parallelListValues :: Expr -> Maybe [Expr]
  parallelListValues = \case
    Call (Symbol listHead) values
      | isSessionSystemHead "List" listHead -> Just values
    _ -> Nothing

  threadColumns
    :: Expr
    -> Int
    -> [Expr]
    -> EvaluationSession
    -> [[Expr]]
    -> SessionResult Expr
  threadColumns function remaining retained currentSession parallelValues =
    case splitParallelValues parallelValues of
      Nothing ->
        Right (normalizeEvaluatedCall (Symbol "List") retained, currentSession)
      Just (column, rest) -> do
        (mapped, updated) <-
          threadAtDepth function remaining currentSession column
        threadColumns function remaining (retained <> [mapped]) updated rest

  splitParallelValues :: [[Expr]] -> Maybe ([Expr], [[Expr]])
  splitParallelValues [] = Nothing
  splitParallelValues values = collect [] [] values
   where
    collect retainedHeads retainedTails [] =
      Just (reverse retainedHeads, reverse retainedTails)
    collect _ _ ([] : _) = Nothing
    collect retainedHeads retainedTails ((value : rest) : remaining) =
      collect (value : retainedHeads) (rest : retainedTails) remaining

evaluateSessionBlockMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionBlockMap depth session = \case
  [function, subject, Integer window] ->
    blockMap function subject window window session
  [function, subject, Integer window, Integer offset] ->
    blockMap function subject window offset session
  [_, _, _] ->
    sessionFailure session "BlockMap expects an integer argument."
  [_, _, _, _] ->
    sessionFailure session "BlockMap expects an integer argument."
  _ ->
    sessionFailure
      session
      "BlockMap currently supports a function, an expression, a block size, and an optional offset."
 where
  blockMap function subject window offset currentSession
    | window <= 0 || offset <= 0 =
        sessionFailure
          currentSession
          "BlockMap expects positive integer block sizes and offsets."
    | otherwise = case sessionOrderedCollection subject of
        Nothing ->
          sessionFailure
            currentSession
            "BlockMap expects a nonatomic expression."
        Just collection ->
          mapWindows
            function
            collection
            window
            offset
            0
            []
            currentSession

  mapWindows function collection window offset start retained currentSession
    | start + window > itemCount =
        Right (normalizeEvaluatedCall (Symbol "List") retained, currentSession)
    | otherwise = do
        let items = sessionCollectionItems collection
            blockItems =
              take
                (fromIntegral window)
                (drop (fromIntegral start) items)
            block = rebuildSessionCollection collection blockItems
        (mapped, updated) <-
          evaluateSessionCallable depth currentSession function [block]
        mapWindows
          function
          collection
          window
          offset
          (start + offset)
          (retained <> [mapped])
          updated
   where
    itemCount = toInteger (length (sessionCollectionItems collection))

evaluateSessionSubsetMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSubsetMap depth session = \case
  [function, Call (Symbol targetHead) targetValues, positions]
    | isSessionSystemHead "List" targetHead ->
        case positions of
          Call (Symbol positionsHead) rawPositions
            | isSessionSystemHead "List" positionsHead ->
                case traverse normalizePosition rawPositions of
                  P.Left message -> sessionFailure session message
                  P.Right requestedPositions ->
                    case traverse (resolvePosition (length targetValues)) requestedPositions of
                      P.Left message -> sessionFailure session message
                      P.Right resolvedPositions ->
                        case traverse (`sessionListItemAt` targetValues) resolvedPositions of
                          Nothing ->
                            sessionFailure
                              session
                              "SubsetMap could not resolve a validated position."
                          Just selectedValues -> do
                            (callbackResult, callbackSession) <-
                              evaluateSessionCallable
                                depth
                                session
                                function
                                [Call (Symbol "List") selectedValues]
                            (transformed, transformedSession) <-
                              evaluateSessionAt (depth + 1) callbackSession callbackResult
                            case transformed of
                              Call (Symbol transformedHead) transformedValues
                                | isSessionSystemHead "List" transformedHead
                                , length transformedValues == length resolvedPositions ->
                                    Right
                                      ( normalizeEvaluatedCall
                                          (Symbol targetHead)
                                          ( replaceSelectedValues
                                              targetValues
                                              (zip resolvedPositions transformedValues)
                                          )
                                      , transformedSession
                                      )
                              _ -> invalidCallbackResult transformedSession
          _ ->
            sessionFailure
              session
              "SubsetMap expects a List of positions as the third argument."
  [_, _, _] ->
    sessionFailure
      session
      "SubsetMap currently expects a List as the second argument."
  _ ->
    sessionFailure
      session
      "SubsetMap expects a function, a list, and a list of positions."
 where
  normalizePosition = \case
    Integer position -> P.Right position
    Call (Symbol listHead) [Integer position]
      | isSessionSystemHead "List" listHead -> P.Right position
    _ ->
      P.Left
        "SubsetMap currently supports flat integer positions (or one-element ``{i}`` lists)."

  resolvePosition count position
    | position == 0 =
        P.Left "Only top-level Part specifications may use index 0."
    | otherwise =
        case resolveSessionPosition count position of
          Just resolved -> P.Right resolved
          Nothing ->
            P.Left
              ( "Part index "
                  <> T.pack (show position)
                  <> " is out of range for length "
                  <> T.pack (show count)
                  <> "."
              )

  replaceSelectedValues values [] = values
  replaceSelectedValues values ((index, replacement) : rest) =
    replaceSelectedValues
      (replaceSessionListIndex index replacement values)
      rest

  invalidCallbackResult currentSession =
    sessionFailure
      currentSession
      "SubsetMap expects the function to return a List of the same length as the selection."

evaluateSessionOperate
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOperate depth session = \case
  [operator, subject] -> operateSessionAtLevel depth session operator subject 1
  [operator, subject, Integer level]
    | level >= 0 -> operateSessionAtLevel depth session operator subject level
    | otherwise ->
        sessionFailure session "Operate expects a non-negative integer level."
  [_, _, _] -> sessionFailure session "Operate expects an integer argument."
  _ ->
    sessionFailure
      session
      "Operate expects an operator, an expression, and an optional positive level."

evaluateSessionInner
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionInner depth session = \case
  [function, Call _ leftValues, Call _ rightValues, combiner]
    | length leftValues /= length rightValues ->
        sessionFailure session "Inner expects expressions with the same length."
    | otherwise -> combinePairs function combiner session [] leftValues rightValues
  [_, _, _, _] ->
    sessionFailure session "Inner expects a nonatomic expression."
  _ -> sessionFailure session "Inner expects exactly four arguments."
 where
  combinePairs _ combiner current combined [] [] =
    evaluateSessionCallable depth current combiner (reverse combined)
  combinePairs function combiner current combined (left : leftRest) (right : rightRest) = do
    (value, updated) <-
      evaluateSessionCallable depth current function [left, right]
    combinePairs
      function
      combiner
      updated
      (value : combined)
      leftRest
      rightRest
  combinePairs _ _ current _ _ _ =
    sessionFailure current "Inner expects expressions with the same length."

evaluateSessionOuter
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOuter depth session values =
  case outerTraversalPlan values of
    P.Left (EvaluationError message) -> sessionFailure session message
    P.Right (function, sequences) -> recurse function sequences [] session
 where
  recurse function [] chosen current =
    evaluateSessionCallable depth current function (reverse chosen)
  recurse function ((node, remainingDepth) : rest) chosen current =
    descend function node remainingDepth rest chosen current

  descend function node (Just 0) rest chosen current =
    recurse function rest (node : chosen) current
  descend function (Call expressionHead children) remainingDepth rest chosen current = do
    (descended, updated) <-
      descendChildren
        function
        (fmap (subtract 1) remainingDepth)
        rest
        chosen
        []
        current
        children
    Right (rebuildOuterCall expressionHead descended, updated)
  descend function node _ rest chosen current =
    recurse function rest (node : chosen) current

  descendChildren _ _ _ _ retained current [] =
    Right (reverse retained, current)
  descendChildren function remainingDepth rest chosen retained current (child : children) = do
    (descended, updated) <-
      descend function child remainingDepth rest chosen current
    descendChildren
      function
      remainingDepth
      rest
      chosen
      (descended : retained)
      updated
      children

  rebuildOuterCall expressionHead@Symbol {} = rebuildWithSplicing expressionHead
  rebuildOuterCall expressionHead = Call expressionHead

evaluateSessionThrough
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionThrough depth session = \case
  [subject] -> through subject Nothing
  [subject, targetHead] -> through subject (Just targetHead)
  _ ->
    sessionFailure
      session
      "Through expects an expression and an optional restricting head."
 where
  through subject@Call {} targetHead = case targetHead of
    Nothing -> distribute subject
    Just (Symbol targetName)
      | targetMatches subject targetName -> distribute subject
      | otherwise -> Right (subject, session)
    Just _ ->
      sessionFailure
        session
        "Through's second argument must be a Symbol head."
  through subject _ = Right (subject, session)

  targetMatches (Call functionsContainer _) targetName =
    case functionsContainer of
      Call (Symbol containerHead) _ -> containerHead == targetName
      _ -> False
  targetMatches _ _ = False

  distribute subject@(Call functionsContainer callArguments) =
    case sessionAssociationEntries functionsContainer of
      Just entries -> mapAssociation callArguments [] session entries
      Nothing -> case functionsContainer of
        Call containerHead functions ->
          mapFunctions containerHead callArguments [] session functions
        _ -> Right (subject, session)
  distribute subject = Right (subject, session)

  mapAssociation _ retained current [] =
    Right (normalizedSessionAssociation (reverse retained), current)
  mapAssociation callArguments retained current (SessionAssociationEntry ruleHead key function : rest) = do
    (value, updated) <-
      evaluateSessionCallable depth current function callArguments
    mapAssociation
      callArguments
      (Call (Symbol ruleHead) [key, value] : retained)
      updated
      rest

  mapFunctions containerHead _ retained current [] =
    Right (rebuildContainer containerHead (reverse retained), current)
  mapFunctions containerHead callArguments retained current (function : rest) = do
    (value, updated) <-
      evaluateSessionCallable depth current function callArguments
    mapFunctions
      containerHead
      callArguments
      (value : retained)
      updated
      rest

  rebuildContainer containerHead@Symbol {} = rebuildWithSplicing containerHead
  rebuildContainer containerHead = Call containerHead

evaluateSessionTr
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTr depth session trInputs =
  case trEvaluationPlan trInputs of
    P.Left (EvaluationError message) -> sessionFailure session message
    P.Right (TrTermsPlan combiner terms) ->
      combineTerms combiner terms session
    P.Right (TrLevelPlan combiner subject level) ->
      contractLevel combiner subject level session
 where
  combineTerms combiner terms current = case combiner of
    Symbol combinerName
      | isSessionSystemHead "Plus" combinerName ->
          evaluateSessionAt
            (depth + 1)
            current
            (Call (Symbol "Plus") terms)
    _ -> do
      (combined, updated) <-
        evaluateSessionCallable depth current combiner terms
      evaluateSessionAt (depth + 1) updated combined

  contractLevel combiner subject level current
    | level == 1 = case requireList subject of
        P.Left message -> sessionFailure current message
        P.Right values -> case equalWidthRows values of
          Just rows -> combineColumns combiner [] current (transpose rows)
          Nothing -> combineTerms combiner values current
    | otherwise = case requireList subject of
        P.Left message -> sessionFailure current message
        P.Right values ->
          contractChildren combiner (level - 1) [] current values

  contractChildren combiner _ retained current [] =
    contractLevel
      combiner
      (Call (Symbol "List") (reverse retained))
      1
      current
  contractChildren combiner level retained current (value : rest) = do
    (contracted, updated) <- contractLevel combiner value level current
    contractChildren combiner level (contracted : retained) updated rest

  combineColumns _ retained current [] =
    Right
      ( rebuildWithSplicing (Symbol "List") (reverse retained)
      , current
      )
  combineColumns combiner retained current (column : rest) = do
    (combined, updated) <- combineTerms combiner column current
    combineColumns combiner (combined : retained) updated rest

  requireList expression = case listValues expression of
    Just values -> P.Right values
    Nothing -> case expression of
      Call {} ->
        P.Left "Tr expects a List at every contracted level."
      _ -> P.Left "Tr expects a nonatomic expression."

  equalWidthRows [] = Nothing
  equalWidthRows values = do
    rows <- traverse listValues values
    case rows of
      [] -> Nothing
      firstRow : remaining
        | all ((== length firstRow) . length) remaining -> Just rows
        | otherwise -> Nothing

  listValues (Call (Symbol listHead) listItems)
    | isSessionSystemHead "List" listHead = Just listItems
  listValues _ = Nothing

operateSessionAtLevel
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> Integer
  -> SessionResult Expr
operateSessionAtLevel depth session operator subject level
  | level == 0 = evaluateSessionCallable depth session operator [subject]
  | level > toInteger (sessionCallHeadDepth subject) = Right (subject, session)
  | otherwise = descend level session subject
 where
  descend 0 current value =
    evaluateSessionCallable depth current operator [value]
  descend remaining current (Call expressionHead values) = do
    (operatedHead, updated) <- descend (remaining - 1) current expressionHead
    Right (Call operatedHead values, updated)
  descend _ current value = Right (value, current)

sessionCallHeadDepth :: Expr -> Int
sessionCallHeadDepth (Call expressionHead _) = 1 + sessionCallHeadDepth expressionHead
sessionCallHeadDepth _ = 0

evaluateSessionMapAll
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMapAll depth session values =
  case stripSessionHeadsOption False values of
    (_includeHeads, [_function]) ->
      Right (Call (Symbol "MapAll") values, session)
    (includeHeads, [function, subject]) ->
      mapTree includeHeads function session subject
    _ ->
      sessionFailure
        session
        "MapAll currently supports exactly two arguments."
 where
  mapTree includeHeads function currentSession expression =
    case sessionOrderedCollection expression of
      Just collection
        | sessionCollectionAssociation collection -> do
            (mappedItems, updated) <-
              mapItems
                includeHeads
                function
                []
                currentSession
                (sessionCollectionItems collection)
            evaluateSessionCallable
              depth
              updated
              function
              [rebuildSessionCollection collection mappedItems]
      _ -> case expression of
        Call expressionHead arguments' -> do
          (mappedArguments, argumentsSession) <-
            mapValues
              includeHeads
              function
              []
              currentSession
              arguments'
          (mappedHead, headSession) <-
            if includeHeads
              then mapTree includeHeads function argumentsSession expressionHead
              else Right (expressionHead, argumentsSession)
          evaluateSessionCallable
            depth
            headSession
            function
            [normalizeEvaluatedCall mappedHead mappedArguments]
        _ ->
          evaluateSessionCallable
            depth
            currentSession
            function
            [expression]

  mapItems _ _ retained currentSession [] =
    Right (retained, currentSession)
  mapItems includeHeads function retained currentSession (item : rest) = do
    (mapped, updated) <-
      mapTree
        includeHeads
        function
        currentSession
        (sessionItemValue item)
    mapItems
      includeHeads
      function
      (retained <> [replaceSessionItemValue item mapped])
      updated
      rest

  mapValues _ _ retained currentSession [] =
    Right (retained, currentSession)
  mapValues includeHeads function retained currentSession (value : rest) = do
    (mapped, updated) <-
      mapTree includeHeads function currentSession value
    mapValues
      includeHeads
      function
      (retained <> [mapped])
      updated
      rest

evaluateSessionMapApply
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMapApply depth session = \case
  [function] -> Right (Call (Symbol "MapApply") [function], session)
  [function, subject] -> mapImmediate function session subject
  [function, subject, levelSpecification] -> do
    (bounds, boundsSession) <-
      liftSessionLevelBounds session levelSpecification
    mapTree function bounds 0 boundsSession subject
  _ ->
    sessionFailure
      session
      "MapApply expects a function, an expression, and an optional level specification."
 where
  mapImmediate function currentSession expression =
    case sessionOrderedCollection expression of
      Just collection
        | sessionCollectionAssociation collection -> do
            (mappedItems, updated) <-
              mapImmediateItems
                function
                []
                currentSession
                (sessionCollectionItems collection)
            Right (rebuildSessionCollection collection mappedItems, updated)
      _ -> case expression of
        Call expressionHead arguments' -> do
          (mappedArguments, updated) <-
            mapImmediateValues function [] currentSession arguments'
          Right
            ( normalizeEvaluatedCall expressionHead mappedArguments
            , updated
            )
        _ -> Right (expression, currentSession)

  mapImmediateItems _ retained currentSession [] =
    Right (retained, currentSession)
  mapImmediateItems function retained currentSession (item : rest) = do
    (mapped, updated) <-
      evaluateSessionTraversalHead
        depth
        function
        currentSession
        (sessionItemValue item)
    mapImmediateItems
      function
      (retained <> [replaceSessionItemValue item mapped])
      updated
      rest

  mapImmediateValues _ retained currentSession [] =
    Right (retained, currentSession)
  mapImmediateValues function retained currentSession (value : rest) = do
    (mapped, updated) <-
      evaluateSessionTraversalHead depth function currentSession value
    mapImmediateValues
      function
      (retained <> [mapped])
      updated
      rest

  mapTree function bounds positive currentSession expression =
    case sessionOrderedCollection expression of
      Just collection
        | sessionCollectionAssociation collection -> do
            (mappedItems, updated) <-
              mapTreeItems
                function
                bounds
                (positive + 1)
                []
                currentSession
                (sessionCollectionItems collection)
            let rebuilt = rebuildSessionCollection collection mappedItems
            if selected bounds positive expression
              then
                evaluateSessionTraversalHead depth function updated rebuilt
              else Right (rebuilt, updated)
      _ -> case expression of
        Call expressionHead arguments' -> do
          (mappedArguments, updated) <-
            mapTreeValues
              function
              bounds
              (positive + 1)
              []
              currentSession
              arguments'
          let rebuilt = normalizeEvaluatedCall expressionHead mappedArguments
          if selected bounds positive expression
            then
              evaluateSessionTraversalHead depth function updated rebuilt
            else
              Right (rebuilt, updated)
        _ -> Right (expression, currentSession)

  selected bounds positive expression =
    positive >= 1 && sessionLevelMatches bounds positive expression

  mapTreeItems _ _ _ retained currentSession [] =
    Right (retained, currentSession)
  mapTreeItems function bounds positive retained currentSession (item : rest) = do
    (mapped, updated) <-
      mapTree
        function
        bounds
        positive
        currentSession
        (sessionItemValue item)
    mapTreeItems
      function
      bounds
      positive
      (retained <> [replaceSessionItemValue item mapped])
      updated
      rest

  mapTreeValues _ _ _ retained currentSession [] =
    Right (retained, currentSession)
  mapTreeValues function bounds positive retained currentSession (value : rest) = do
    (mapped, updated) <-
      mapTree function bounds positive currentSession value
    mapTreeValues
      function
      bounds
      positive
      (retained <> [mapped])
      updated
      rest

evaluateSessionTraversalHead
  :: Int
  -> Expr
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionTraversalHead depth function session expression =
  case sessionOrderedCollection expression of
    Just collection
      | sessionCollectionAssociation collection ->
          evaluateSessionCallable
            depth
            session
            function
            (map sessionItemValue (sessionCollectionItems collection))
    _ -> case expression of
      Call _ values -> evaluateSessionCallable depth session function values
      _ -> Right (expression, session)

evaluateSessionConstruct
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionConstruct _ session [] =
  sessionFailure session "Construct expects at least one argument."
evaluateSessionConstruct depth session (function : functionArguments) =
  evaluateSessionCallable depth session function functionArguments

evaluateSessionComposeList
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionComposeList depth session = \case
  [Call _ functions, initial] ->
    compose functions initial [initial] session
  [_functions, _initial] ->
    sessionFailure
      session
      "ComposeList expects a list or other nonatomic expression of functions."
  _ -> sessionFailure session "ComposeList expects exactly two arguments."
 where
  compose [] _ retained currentSession =
    Right (evaluatedList retained, currentSession)
  compose (function : remaining) current retained currentSession = do
    (updated, nextSession) <-
      evaluateSessionCallable depth currentSession function [current]
    compose remaining updated (retained <> [updated]) nextSession

evaluateSessionComap
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionComap applyToArguments depth session arguments' =
  case arguments' of
    [functions] -> Right (Call (Symbol operation) [functions], session)
    [functions, subject] -> mapFunctions functions subject
    _ ->
      sessionFailure
        session
        (operation <> " expects exactly two arguments.")
 where
  operation = if applyToArguments then "ComapApply" else "Comap"

  mapFunctions functions subject = case sessionOrderedCollection functions of
    Nothing -> Right (functions, session)
    Just collection -> do
      (mapped, updated) <-
        mapItems subject [] session (sessionCollectionItems collection)
      Right (rebuildSessionCollection collection mapped, updated)

  mapItems _ retained currentSession [] = Right (retained, currentSession)
  mapItems subject retained currentSession (item : rest) = do
    (value, updated) <-
      applyFunction subject currentSession (sessionItemValue item)
    mapItems
      subject
      (retained <> [replaceComapItemValue item value])
      updated
      rest

  applyFunction subject currentSession function
    | applyToArguments = case comapApplyArguments subject of
        Nothing -> Right (subject, currentSession)
        Just values ->
          evaluateSessionCallable depth currentSession function values
    | otherwise =
        evaluateSessionCallable depth currentSession function [subject]

  comapApplyArguments subject = case sessionOrderedCollection subject of
    Just collection
      | sessionCollectionAssociation collection ->
          Just (map sessionItemValue (sessionCollectionItems collection))
    _ -> case subject of
      Call _ values -> Just values
      _ -> Nothing

  replaceComapItemValue item value =
    item
      { sessionItemValue = value
      , sessionItemOriginal = case sessionItemOriginal item of
          Call ruleHead [key, _] -> Call ruleHead [key, value]
          _ -> value
      }

evaluateSessionNest
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionNest returnHistory depth session = \case
  [function, initial, countExpression] -> do
    iterations <-
      sessionNonNegativeIterationCount
        operation
        "expects a non-negative integer iteration count."
        session
        countExpression
    build function iterations [initial] session
  _ ->
    sessionFailure
      session
      (operation <> " expects exactly three arguments.")
 where
  operation = if returnHistory then "NestList" else "Nest"
  build _ 0 retained currentSession =
    Right
      ( if returnHistory then evaluatedList retained else last retained
      , currentSession
      )
  build function remaining retained currentSession = do
    (updated, nextSession) <-
      evaluateSessionCallable depth currentSession function [last retained]
    build function (remaining - 1) (retained <> [updated]) nextSession

evaluateSessionNestWhile
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionNestWhile returnHistory depth session arguments' =
  case arguments' of
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
      sessionFailure
        session
        (operation <> " expects f, expr, test, optional m, optional max.")
 where
  operation = if returnHistory then "NestWhileList" else "NestWhile"

  nestWhile function initial test historyExpression maximumExpression = do
    historySize <- normalizeHistory historyExpression
    maximumIterations <- normalizeMaximum maximumExpression
    iterateWhile function test historySize maximumIterations 0 [initial] session

  normalizeHistory Nothing = Right (Just 1)
  normalizeHistory (Just (Integer value))
    | value >= 1 = Right (Just value)
  normalizeHistory (Just (Symbol name))
    | isSessionSystemHead "All" name = Right Nothing
  normalizeHistory _ =
    patternFailure
      session
      "NestWhile history size must be a positive integer or All."

  normalizeMaximum Nothing = Right Nothing
  normalizeMaximum (Just (Integer value)) = Right (Just (max 0 value))
  normalizeMaximum (Just (Symbol name))
    | isSessionSystemHead "Infinity" name = Right Nothing
  normalizeMaximum _ =
    patternFailure
      session
      "NestWhile max iterations must be a non-negative integer or Infinity."

  iterateWhile function test historySize maximumIterations iterations history currentSession = do
    (predicateResult, testedSession) <-
      predicateWithHistory test historySize history currentSession
    if not predicateResult
      then finish history testedSession
      else
        if iterations >= sessionIterationSafetyLimit
          then
            sessionFailure
              testedSession
              (operation <> " exceeded the Tungsten iteration safety limit.")
          else case maximumIterations of
            Just maximumValue
              | iterations >= maximumValue -> finish history testedSession
            _ -> do
              (updated, nextSession) <-
                evaluateSessionCallable
                  depth
                  testedSession
                  function
                  [last history]
              iterateWhile
                function
                test
                historySize
                maximumIterations
                (iterations + 1)
                (history <> [updated])
                nextSession

  predicateWithHistory test historySize history currentSession =
    case historySize of
      Just required
        | fromIntegral (length history) < required -> Right (True, currentSession)
        | otherwise ->
            applyPredicate
              test
              (drop (length history - fromIntegral required) history)
              currentSession
      Nothing -> applyPredicate test history currentSession

  applyPredicate test predicateArguments currentSession = do
    (result, updated) <-
      evaluateSessionCallable depth currentSession test predicateArguments
    Right (result == Symbol "True", updated)

  finish history currentSession =
    Right
      (if returnHistory then evaluatedList history else last history, currentSession)

evaluateSessionFixedPoint
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFixedPoint returnHistory depth session = \case
  [function, initial] ->
    findFixedPoint function initial sessionIterationSafetyLimit False
  [function, initial, countExpression] -> do
    limit <-
      sessionNonNegativeIterationCount
        operation
        "expects a non-negative maximum iteration count."
        session
        countExpression
    findFixedPoint function initial limit True
  _ ->
    sessionFailure
      session
      ( operation
          <> " expects a function, an expression, and an optional iteration limit."
      )
 where
  operation = if returnHistory then "FixedPointList" else "FixedPoint"
  findFixedPoint callback initial limit explicitLimit =
    iterateUntilStable limit initial [initial] session
   where
    iterateUntilStable 0 current retained currentSession
      | explicitLimit = finish current retained currentSession
      | otherwise =
          sessionFailure
            currentSession
            (operation <> " exceeded the Tungsten iteration safety limit.")
    iterateUntilStable remaining current retained currentSession = do
      (updated, nextSession) <-
        evaluateSessionCallable depth currentSession callback [current]
      let nextRetained = retained <> [updated]
      if updated == current
        then finish current nextRetained nextSession
        else
          iterateUntilStable
            (remaining - 1)
            updated
            nextRetained
            nextSession
    finish current retained currentSession =
      Right
        (if returnHistory then evaluatedList retained else current, currentSession)

evaluateSessionFold
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFold returnHistory depth session = \case
  [function, subject] -> do
    values <- sessionSequenceValues session operation subject
    case values of
      []
        | returnHistory -> Right (evaluatedList [], session)
        | otherwise ->
            sessionFailure
              session
              "Fold[f, expr] expects a nonempty sequence."
      initial : remaining -> finish function initial remaining
  [function, initial, subject] -> do
    values <- sessionSequenceValues session operation subject
    finish function initial values
  _ ->
    sessionFailure
      session
      (operation <> " expects two or three arguments.")
 where
  operation = if returnHistory then "FoldList" else "Fold"
  finish function initial values =
    build function initial values [initial] session
  build _ current [] retained currentSession =
    Right
      (if returnHistory then evaluatedList retained else current, currentSession)
  build function current (value : remaining) retained currentSession = do
    (updated, nextSession) <-
      evaluateSessionCallable depth currentSession function [current, value]
    build
      function
      updated
      remaining
      (retained <> [updated])
      nextSession

evaluateSessionFoldWhile
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFoldWhile returnHistory depth session arguments' =
  case arguments' of
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
      sessionFailure
        session
        ( operation
            <> " currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
        )
 where
  operation = if returnHistory then "FoldWhileList" else "FoldWhile"

  foldWhile function initial subject test historyExpression trailingExpression = do
    inputs <- sessionSequenceValues session "FoldWhileList" subject
    historySize <- normalizeHistory historyExpression
    (initialSucceeds, testedSession) <-
      testHistory test historySize [initial] session
    if initialSucceeds
      then
        foldInputs
          function
          test
          historySize
          trailingExpression
          [initial]
          inputs
          testedSession
      else finish [initial] testedSession

  normalizeHistory Nothing = Right (Just 1)
  normalizeHistory (Just (Integer value))
    | value > 0 = Right (Just value)
  normalizeHistory (Just (Symbol name))
    | isSessionSystemHead "All" name = Right Nothing
  normalizeHistory _ =
    patternFailure
      session
      "FoldWhileList expects a positive history length or All."

  foldInputs _ _ _ _ results [] currentSession = finish results currentSession
  foldInputs function test historySize trailingExpression results (inputValue : remaining) currentSession = do
    (updated, functionSession) <-
      evaluateSessionCallable
        depth
        currentSession
        function
        [last results, inputValue]
    let nextResults = results <> [updated]
    (predicateSucceeds, testedSession) <-
      testHistory test historySize nextResults functionSession
    if predicateSucceeds
      then
        foldInputs
          function
          test
          historySize
          trailingExpression
          nextResults
          remaining
          testedSession
      else
        finishFailure
          function
          trailingExpression
          nextResults
          remaining
          testedSession

  finishFailure function trailingExpression results remaining currentSession =
    case trailingExpression of
      Nothing -> finish results currentSession
      Just (Integer trailing)
        | trailing < 0 ->
            let retainedCount =
                  min
                    (toInteger (length results))
                    (max 1 (toInteger (length results) + trailing))
             in finish (take (fromInteger retainedCount) results) currentSession
        | otherwise ->
            appendTrailing function trailing results remaining currentSession
      Just _ ->
        patternFailure
          currentSession
          "FoldWhileList expects an integer argument."

  appendTrailing _ 0 results _ currentSession = finish results currentSession
  appendTrailing _ _ results [] currentSession = finish results currentSession
  appendTrailing function remainingCount results (inputValue : remaining) currentSession = do
    (updated, nextSession) <-
      evaluateSessionCallable
        depth
        currentSession
        function
        [last results, inputValue]
    appendTrailing
      function
      (remainingCount - 1)
      (results <> [updated])
      remaining
      nextSession

  testHistory test historySize history currentSession = do
    (result, updated) <-
      evaluateSessionCallable
        depth
        currentSession
        test
        (historyArguments historySize history)
    Right (result == Symbol "True", updated)

  historyArguments Nothing history = history
  historyArguments (Just required) history
    | required >= toInteger (length history) = history
    | otherwise = drop (length history - fromInteger required) history

  finish results currentSession =
    let retained = filter (/= Symbol "Nothing") results
     in Right
          ( case (returnHistory, retained) of
              (True, _) -> evaluatedList retained
              (False, []) -> Symbol "Nothing"
              (False, _) -> last retained
          , currentSession
          )

evaluateSessionFoldPair
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFoldPair returnHistory depth session arguments' =
  case arguments' of
    [function, initial, subject] ->
      foldPairs function initial subject Nothing
    [function, initial, subject, projection] ->
      foldPairs function initial subject (Just projection)
    _ ->
      sessionFailure
        session
        ( operation
            <> " currently supports a function, an initial value, inputs, and an optional projection."
        )
 where
  operation = if returnHistory then "FoldPairList" else "FoldPair"
  foldPairs function initial subject projection = do
    inputs <- sessionSequenceValues session "FoldPairList" subject
    (projected, updated) <-
      build function projection initial inputs [] session
    let retained = filter (/= Symbol "Nothing") projected
    case retained of
      []
        | returnHistory -> Right (evaluatedList [], updated)
        | otherwise -> Right (Call (Symbol "FoldPair") arguments', updated)
      _
        | returnHistory -> Right (evaluatedList retained, updated)
        | otherwise -> Right (last retained, updated)

  build _ _ _ [] retained currentSession = Right (retained, currentSession)
  build function projection current (inputValue : remaining) retained currentSession = do
    (pairExpression, pairSession) <-
      evaluateSessionCallable depth currentSession function [current, inputValue]
    case pairExpression of
      Call (Symbol listHead) [first, second]
        | isSessionSystemHead "List" listHead -> do
            (projected, projectionSession) <- case projection of
              Nothing -> Right (first, pairSession)
              Just projectionFunction ->
                evaluateSessionCallable
                  depth
                  pairSession
                  projectionFunction
                  [evaluatedList [first, second]]
            build
              function
              projection
              second
              remaining
              (retained <> [projected])
              projectionSession
      _ ->
        sessionFailure
          pairSession
          ( "FoldPairList expects each function application to return a list of two elements, got "
              <> inputForm pairExpression
              <> "."
          )

sessionNonNegativeIterationCount
  :: Text
  -> Text
  -> EvaluationSession
  -> Expr
  -> RuntimeResult EvaluationExit Integer
sessionNonNegativeIterationCount operation negativeMessage session = \case
  Integer value
    | value >= 0 -> Right value
    | otherwise ->
        patternFailure session (operation <> " " <> negativeMessage)
  _ -> patternFailure session (operation <> " expects an integer argument.")

sessionIterationSafetyLimit :: Integer
sessionIterationSafetyLimit = 65536

evaluateSessionSequenceFold
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSequenceFold returnHistory depth session arguments' =
  case arguments' of
    [function, initialExpression, inputsExpression] ->
      foldSequence function initialExpression inputsExpression Nothing
    [function, initialExpression, inputsExpression, arityExpression] ->
      foldSequence function initialExpression inputsExpression (Just arityExpression)
    _ ->
      sessionFailure
        session
        ( operation
            <> " expects a function, initial values, inputs, and an optional argument count."
        )
 where
  operation = if returnHistory then "SequenceFoldList" else "SequenceFold"

  foldSequence function initialExpression inputsExpression arityExpression = do
    initialValues <- sessionSequenceValues session operation initialExpression
    inputs <- sessionSequenceValues session operation inputsExpression
    if null initialValues
      then
        sessionFailure
          session
          "SequenceFoldList expects at least one initial value."
      else do
        argumentCount <- case arityExpression of
          Nothing -> Right (length initialValues + 1)
          Just (Integer value)
            | value >= fromIntegral (minBound :: Int)
            , value <= fromIntegral (maxBound :: Int) -> Right (fromIntegral value)
          Just _ ->
            patternFailure
              session
              "SequenceFoldList expects an integer argument."
        if argumentCount < length initialValues
          then
            sessionFailure
              session
              "SequenceFoldList expects an argument count greater than or equal to the number of initial values."
          else do
            let consumedPerStep = argumentCount - length initialValues
            if consumedPerStep <= 0
              then
                sessionFailure
                  session
                  "SequenceFoldList currently expects each step to consume at least one input element."
              else do
                (history, updated) <-
                  buildHistory
                    function
                    (length initialValues)
                    consumedPerStep
                    initialValues
                    inputs
                    session
                Right
                  ( if returnHistory
                      then evaluatedList history
                      else last history
                  , updated
                  )

  buildHistory function stateWidth consumedPerStep history remaining current
    | length remaining < consumedPerStep = Right (history, current)
    | otherwise = do
        let state = drop (length history - stateWidth) history
            (consumed, rest) = splitAt consumedPerStep remaining
        (value, updated) <-
          evaluateSessionCallable depth current function (state <> consumed)
        buildHistory
          function
          stateWidth
          consumedPerStep
          (history <> [value])
          rest
          updated

sessionSequenceValues
  :: EvaluationSession
  -> Text
  -> Expr
  -> RuntimeResult EvaluationExit [Expr]
sessionSequenceValues session operation expression = case expression of
  sparse@(SparseArray dimensions _ _)
    | length dimensions /= 1 ->
        patternFailure
          session
          (operation <> " expects a one-dimensional SparseArray sequence.")
    | otherwise -> do
        dense <-
          liftPureEvaluation
            session
            (reduceEvaluatedCall (Call (Symbol "Normal") [sparse]))
        case dense of
          Call (Symbol listHead) values
            | isSessionSystemHead "List" listHead -> Right values
          _ ->
            patternFailure
              session
              (operation <> " expects a one-dimensional SparseArray sequence.")
  _ -> case sessionOrderedCollection expression of
    Just collection -> Right (map sessionItemValue (sessionCollectionItems collection))
    Nothing ->
      patternFailure
        session
        (operation <> " expects a nonatomic expression.")

evaluateSessionKeyMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionKeyMap depth session = \case
  [function, association] -> case sessionOrderedCollection association of
    Just collection
      | sessionCollectionAssociation collection -> do
          (rules, updated) <- mapKeys function [] session (sessionCollectionItems collection)
          Right (normalizedSessionAssociation rules, updated)
    _ -> sessionFailure session "KeyMap expects an Association."
  _ -> sessionFailure session "KeyMap expects exactly two arguments."
 where
  mapKeys _ retained currentSession [] = Right (retained, currentSession)
  mapKeys function retained currentSession (item : rest) = case sessionItemKey item of
    Nothing -> sessionFailure currentSession "KeyMap expects an Association."
    Just key -> do
      (mappedKey, updated) <-
        evaluateSessionCallable depth currentSession function [key]
      let ruleHead = sessionItemRuleHead item
      mapKeys
        function
        ( retained
            <> [ Call
                   (Symbol ruleHead)
                   [mappedKey, sessionItemValue item]
               ]
        )
        updated
        rest

evaluateSessionKeyValueMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionKeyValueMap depth session = \case
  [function, association] -> case sessionOrderedCollection association of
    Just collection
      | sessionCollectionAssociation collection -> do
          (values, updated) <- mapEntries function [] session (sessionCollectionItems collection)
          Right (evaluatedList values, updated)
    _ -> sessionFailure session "KeyValueMap expects an Association."
  _ -> sessionFailure session "KeyValueMap expects exactly two arguments."
 where
  mapEntries _ retained currentSession [] = Right (retained, currentSession)
  mapEntries function retained currentSession (item : rest) = case sessionItemKey item of
    Nothing -> sessionFailure currentSession "KeyValueMap expects an Association."
    Just key -> do
      (mapped, updated) <-
        evaluateSessionCallable
          depth
          currentSession
          function
          [key, sessionItemValue item]
      mapEntries function (retained <> [mapped]) updated rest

evaluateSessionApply
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionApply depth session = \case
  [function, subject] -> case sessionOrderedCollection subject of
    Nothing -> Right (subject, session)
    Just collection ->
      evaluateSessionCallable
        depth
        session
        function
        (map sessionItemValue (sessionCollectionItems collection))
  [function, subject, levelSpecification] -> do
    (bounds, boundsSession) <-
      liftSessionLevelBounds
        session
        levelSpecification
    evaluateSessionApplyLevels
      depth
      function
      bounds
      0
      boundsSession
      subject
  _ ->
    sessionFailure
      session
      "Apply expects a head, an expression, and an optional level specification."

data SessionLevelBounds = SessionLevelBounds !Int !Int
  deriving (Eq, Show)

sessionLevelInfinity :: Int
sessionLevelInfinity = maxBound `div` 4

liftSessionLevelBounds
  :: EvaluationSession
  -> Expr
  -> SessionResult SessionLevelBounds
liftSessionLevelBounds session specification =
  case normalizeSessionLevelSpec specification of
    P.Left message -> sessionFailure session message
    P.Right bounds -> Right (bounds, session)

normalizeSessionLevelSpec :: Expr -> Either Text SessionLevelBounds
normalizeSessionLevelSpec specification = case specification of
  Integer level
    | level >= 0 ->
        P.Right
          ( SessionLevelBounds
              (if level == 0 then 0 else 1)
              (boundedSessionLevel level)
          )
    | otherwise ->
        P.Right (SessionLevelBounds 1 (boundedSessionLevel level))
  Symbol "Infinity" -> P.Right (SessionLevelBounds 1 sessionLevelInfinity)
  Call (Symbol "List") [bound] -> do
    value <- normalizeSessionLevelBound bound
    P.Right (SessionLevelBounds value value)
  Call (Symbol "List") [lower, upper]
    | isSessionLevelBound lower
    , isSessionLevelBound upper ->
        SessionLevelBounds
          <$> normalizeSessionLevelBound lower
          <*> normalizeSessionLevelBound upper
  _ ->
    P.Left
      ( "Unsupported Level specification: '"
          <> inputForm specification
          <> "'."
      )

normalizeSessionLevelBound :: Expr -> Either Text Int
normalizeSessionLevelBound = \case
  Integer value -> P.Right (boundedSessionLevel value)
  Symbol "Infinity" -> P.Right sessionLevelInfinity
  value -> P.Left ("Unsupported level bound: " <> inputForm value <> ".")

isSessionLevelBound :: Expr -> Bool
isSessionLevelBound Integer {} = True
isSessionLevelBound (Symbol "Infinity") = True
isSessionLevelBound _ = False

boundedSessionLevel :: Integer -> Int
boundedSessionLevel value
  | value > fromIntegral sessionLevelInfinity = sessionLevelInfinity
  | value < fromIntegral (negate sessionLevelInfinity) = negate sessionLevelInfinity
  | otherwise = fromIntegral value

sessionLevelMatches :: SessionLevelBounds -> Int -> Expr -> Bool
sessionLevelMatches (SessionLevelBounds lower upper) positive expression
  | lower >= 0 && upper >= 0 = lower <= positive && positive <= upper
  | lower < 0 && upper < 0 = lower <= negative && negative <= upper
  | lower >= 0 && upper < 0 = positive >= lower && negative <= upper
  | otherwise = negative >= lower || positive <= upper
 where
  negative = negate (sessionExpressionDepth expression)

sessionExpressionDepth :: Expr -> Int
sessionExpressionDepth (SparseArray dimensions _ _) = length dimensions + 1
sessionExpressionDepth expression
  | Just collection <- sessionOrderedCollection expression
  , sessionCollectionAssociation collection =
      case map sessionItemValue (sessionCollectionItems collection) of
        [] -> 2
        values -> 1 + maximum (map sessionExpressionDepth values)
sessionExpressionDepth (Call _ []) = 2
sessionExpressionDepth (Call _ values) =
  1 + maximum (map sessionExpressionDepth values)
sessionExpressionDepth _ = 1

evaluateSessionMapLevels
  :: Int
  -> Bool
  -> Expr
  -> SessionLevelBounds
  -> Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionMapLevels depth includeHeads function bounds positive session expression =
  case sessionOrderedCollection expression of
    Just collection
      | sessionCollectionAssociation collection -> do
          (mappedItems, updated) <-
            walkItems [] session (sessionCollectionItems collection)
          let rebuilt = rebuildSessionCollection collection mappedItems
          if sessionLevelMatches bounds positive expression
            then evaluateSessionCallable depth updated function [rebuilt]
            else Right (rebuilt, updated)
    _ -> case expression of
      Call expressionHead values -> do
        (mappedValues, updated) <- walkValues [] session values
        (mappedHead, headSession) <-
          if includeHeads
            then
              evaluateSessionMapLevels
                depth
                includeHeads
                function
                bounds
                (positive + 1)
                updated
                expressionHead
            else Right (expressionHead, updated)
        let rebuilt = normalizeEvaluatedCall mappedHead mappedValues
        if sessionLevelMatches bounds positive expression
          then evaluateSessionCallable depth headSession function [rebuilt]
          else Right (rebuilt, headSession)
      _
        | sessionLevelMatches bounds positive expression ->
            evaluateSessionCallable depth session function [expression]
        | otherwise -> Right (expression, session)
 where
  walkItems retained currentSession [] = Right (retained, currentSession)
  walkItems retained currentSession (item : rest) = do
    (mapped, updated) <-
      evaluateSessionMapLevels
        depth
        includeHeads
        function
        bounds
        (positive + 1)
        currentSession
        (sessionItemValue item)
    walkItems
      (retained <> [replaceSessionItemValue item mapped])
      updated
      rest

  walkValues retained currentSession [] = Right (retained, currentSession)
  walkValues retained currentSession (value : rest) = do
    (mapped, updated) <-
      evaluateSessionMapLevels
        depth
        includeHeads
        function
        bounds
        (positive + 1)
        currentSession
        value
    walkValues (retained <> [mapped]) updated rest

evaluateSessionApplyLevels
  :: Int
  -> Expr
  -> SessionLevelBounds
  -> Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionApplyLevels depth function bounds positive session expression =
  case sessionOrderedCollection expression of
    Just collection
      | sessionCollectionAssociation collection -> do
          (mappedItems, updated) <-
            walkItems [] session (sessionCollectionItems collection)
          if sessionLevelMatches bounds positive expression
            then
              evaluateSessionCallable
                depth
                updated
                function
                (map sessionItemValue mappedItems)
            else Right (rebuildSessionCollection collection mappedItems, updated)
    _ -> case expression of
      Call expressionHead values -> do
        (mappedValues, updated) <- walkValues [] session values
        if sessionLevelMatches bounds positive expression
          then evaluateSessionCallable depth updated function mappedValues
          else Right (normalizeEvaluatedCall expressionHead mappedValues, updated)
      _ -> Right (expression, session)
 where
  walkItems retained currentSession [] = Right (retained, currentSession)
  walkItems retained currentSession (item : rest) = do
    (mapped, updated) <-
      evaluateSessionApplyLevels
        depth
        function
        bounds
        (positive + 1)
        currentSession
        (sessionItemValue item)
    walkItems
      (retained <> [replaceSessionItemValue item mapped])
      updated
      rest

  walkValues retained currentSession [] = Right (retained, currentSession)
  walkValues retained currentSession (value : rest) = do
    (mapped, updated) <-
      evaluateSessionApplyLevels
        depth
        function
        bounds
        (positive + 1)
        currentSession
        value
    walkValues (retained <> [mapped]) updated rest

evaluateSessionTotal
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTotal depth session = \case
  [subject] -> totalSubject subject
  values@[_, _] -> Right (Call (Symbol "Total") values, session)
  _ ->
    sessionFailure
      session
      "Total expects an expression and an optional level specification."
 where
  totalSubject (Call (Symbol "List") values)
    | Just rows <- traverse listValues values
    , equalRowLengths rows =
        case rows of
          [] -> Right (Integer 0, session)
          firstRow : _ -> do
            (columns, updated) <-
              totalColumns [] session rows [0 .. length firstRow - 1]
            Right (evaluatedList columns, updated)
    | otherwise = evaluateSum session values
  totalSubject association = case sessionOrderedCollection association of
    Just collection
      | sessionCollectionAssociation collection ->
          evaluateSum
            session
            (map sessionItemValue (sessionCollectionItems collection))
    _ -> sessionFailure session "Total expects a list or association."

  listValues (Call (Symbol "List") values) = Just values
  listValues _ = Nothing

  equalRowLengths [] = True
  equalRowLengths (firstRow : remaining) =
    all ((== length firstRow) . length) remaining

  totalColumns retained currentSession _ [] = Right (retained, currentSession)
  totalColumns retained currentSession rows (index : rest) = do
    let values = mapMaybeSession (sessionListItemAt index) rows
    (totalValue, updated) <- evaluateSum currentSession values
    totalColumns (retained <> [totalValue]) updated rows rest

  evaluateSum currentSession values =
    evaluateSessionAt
      (depth + 1)
      currentSession
      (Call (Symbol "Plus") values)

mapMaybeSession :: (value -> Maybe result) -> [value] -> [result]
mapMaybeSession function = foldr retain []
 where
  retain value results = case function value of
    Just result -> result : results
    Nothing -> results

data SessionPathSelector
  = SessionArgumentSelector !Integer
  | SessionKeySelector !Expr
  deriving (Eq, Show)

evaluateSessionFlattenAt
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFlattenAt session = \case
  [target, positions] -> do
    (subject, subjectSession) <- densifyTarget target
    case expandSessionPositionPaths subject positions of
      P.Left message -> sessionFailure subjectSession message
      P.Right (resolvedPaths, invalid)
        | invalid || any null uniquePaths -> invalidPositions subjectSession subject
        | otherwise ->
            flattenPaths
              subject
              subject
              subjectSession
              (sortSessionPaths uniquePaths)
       where
        uniquePaths = deduplicateSessionPaths resolvedPaths
  _ -> sessionFailure session "FlattenAt expects exactly two arguments."
 where
  densifyTarget sparse@SparseArray {} = do
    dense <-
      liftPureEvaluation
        session
        (reduceEvaluatedCall (Call (Symbol "Normal") [sparse]))
    Right (dense, session)
  densifyTarget target = Right (target, session)

  flattenPaths _ result currentSession [] = Right (result, currentSession)
  flattenPaths originalSubject result currentSession (path : rest) =
    case flattenSessionAtPath result path of
      Nothing -> invalidPositions currentSession originalSubject
      Just updated ->
        flattenPaths originalSubject updated currentSession rest

  invalidPositions currentSession subject =
    sessionFailure
      currentSession
      ("FlattenAt positions are invalid for " <> inputForm subject <> ".")

deduplicateSessionPaths :: [[SessionPathSelector]] -> [[SessionPathSelector]]
deduplicateSessionPaths = foldl retain []
 where
  retain paths path
    | path `elem` paths = paths
    | otherwise = paths <> [path]

flattenSessionAtPath :: Expr -> [SessionPathSelector] -> Maybe Expr
flattenSessionAtPath _ [] = Nothing
flattenSessionAtPath expression (selector : remaining) = case (expression, selector) of
  (Call expressionHead values, SessionArgumentSelector position) -> do
    index <- resolveSessionPosition (length values) position
    selected <- sessionListItemAt index values
    if null remaining
      then case selected of
        Call _ nestedValues ->
          Just
            ( rebuildSessionFlattenAtCall
                expressionHead
                (take index values <> nestedValues <> drop (index + 1) values)
            )
        _ -> Nothing
      else do
        updated <- flattenSessionAtPath selected remaining
        Just
          ( rebuildSessionFlattenAtCall
              expressionHead
              (replaceSessionListIndex index updated values)
          )
  _ -> Nothing

rebuildSessionFlattenAtCall :: Expr -> [Expr] -> Expr
rebuildSessionFlattenAtCall expressionHead values = case expressionHead of
  Symbol headName -> Call expressionHead retained
   where
    spliced
      | headName `elem` ["HoldComplete", "Rule", "RuleDelayed", "Unevaluated"] =
          values
      | otherwise = concatMap spliceArgument values
    retained
      | headName `elem` ["Association", "List"] =
          filter (/= Symbol "Nothing") spliced
      | otherwise = spliced
    spliceArgument = \case
      Call (Symbol sequenceHead) sequenceValues
        | isSessionSystemHead "Sequence" sequenceHead -> sequenceValues
      Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues]
        | isSessionSystemHead "Splice" spliceHead
        , isSessionSystemHead "List" listHead
        , expressionHead == Symbol "List" -> spliceValues
      Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues, target]
        | isSessionSystemHead "Splice" spliceHead
        , isSessionSystemHead "List" listHead
        , target == expressionHead -> spliceValues
      value -> [value]
  _ -> Call expressionHead values

evaluateSessionMapAt
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMapAt depth session = \case
  [function, subject, positions] ->
    case expandSessionPositionPaths subject positions of
      P.Left message -> sessionFailure session message
      P.Right (resolvedPaths, invalid)
        | invalid -> invalidPositions session subject
        | otherwise ->
            mapPaths
              subject
              function
              subject
              session
              (sortSessionPaths resolvedPaths)
  _ -> sessionFailure session "MapAt currently supports exactly three arguments."
 where
  mapPaths _ _ result currentSession [] = Right (result, currentSession)
  mapPaths originalSubject function result currentSession (path : rest) = do
    (mapped, updated) <-
      evaluateSessionMapAtPath depth function currentSession result path
    case mapped of
      Nothing -> invalidPositions updated originalSubject
      Just value ->
        mapPaths originalSubject function value updated rest

  invalidPositions currentSession subject =
    sessionFailure
      currentSession
      ("MapAt positions are invalid for " <> inputForm subject <> ".")

evaluateSessionMapAtPath
  :: Int
  -> Expr
  -> EvaluationSession
  -> Expr
  -> [SessionPathSelector]
  -> SessionResult (Maybe Expr)
evaluateSessionMapAtPath depth function session expression = \case
  [] -> do
    (mapped, updated) <-
      evaluateSessionCallable depth session function [expression]
    Right (Just mapped, updated)
  selector : remaining -> case sessionOrderedCollection expression of
    Just collection
      | sessionCollectionAssociation collection ->
          case sessionAssociationItemIndex selector (sessionCollectionItems collection) of
            Nothing -> Right (Nothing, session)
            Just index -> case sessionListItemAt index (sessionCollectionItems collection) of
              Nothing -> Right (Nothing, session)
              Just selected -> do
                let items = sessionCollectionItems collection
                (mapped, updated) <-
                  evaluateSessionMapAtPath
                    depth
                    function
                    session
                    (sessionItemValue selected)
                    remaining
                Right
                  ( fmap
                      ( \value ->
                          rebuildSessionCollection
                            collection
                            (replaceSessionListIndex index (replaceSessionItemValue selected value) items)
                      )
                      mapped
                  , updated
                  )
    Just collection -> case selector of
      SessionArgumentSelector position ->
        case resolveSessionPosition (length (sessionCollectionItems collection)) position of
          Nothing -> Right (Nothing, session)
          Just index -> case sessionListItemAt index (sessionCollectionItems collection) of
            Nothing -> Right (Nothing, session)
            Just selected -> do
              let items = sessionCollectionItems collection
              (mapped, updated) <-
                evaluateSessionMapAtPath
                  depth
                  function
                  session
                  (sessionItemValue selected)
                  remaining
              Right
                ( fmap
                    ( \value ->
                        rebuildSessionCollection
                          collection
                          (replaceSessionListIndex index (replaceSessionItemValue selected value) items)
                    )
                    mapped
                , updated
                )
      SessionKeySelector _ -> Right (Nothing, session)
    Nothing -> Right (Nothing, session)

data SessionPathSelection = SessionPathSelection
  { sessionPathSelectionSelector :: !SessionPathSelector
  , sessionPathSelectionValue :: !Expr
  }
  deriving (Eq, Show)

expandSessionPositionPaths
  :: Expr
  -> Expr
  -> Either Text ([[SessionPathSelector]], Bool)
expandSessionPositionPaths expression specification
  | isSessionPositionCollection specification =
      case specification of
        Call (Symbol listHead) pathExpressions
          | isSessionSystemHead "List" listHead ->
              expandPaths [] False pathExpressions
        _ -> unsupportedPositionSpecification specification
  | isSingleSessionPositionSpecification specification =
      expandSessionExactPath
        expression
        (sessionPositionComponents specification)
  | otherwise = unsupportedPositionSpecification specification
 where
  expandPaths retained invalid [] = P.Right (retained, invalid)
  expandPaths retained invalid (pathSpecification : rest) = do
    (paths, pathInvalid) <-
      expandSessionExactPath
        expression
        (sessionPositionComponents pathSpecification)
    expandPaths (retained <> paths) (invalid || pathInvalid) rest

expandSessionExactPath
  :: Expr
  -> [Expr]
  -> Either Text ([[SessionPathSelector]], Bool)
expandSessionExactPath _ [] = P.Right ([[]], False)
expandSessionExactPath expression (component : remaining) = do
  (selections, selectionInvalid) <-
    resolveSessionPathComponent expression component
  expandSelections [] selectionInvalid selections
 where
  expandSelections retained invalid [] = P.Right (retained, invalid)
  expandSelections retained invalid (selection : rest) = do
    (childPaths, childInvalid) <-
      expandSessionExactPath
        (sessionPathSelectionValue selection)
        remaining
    let paths =
          [ sessionPathSelectionSelector selection : childPath
          | childPath <- childPaths
          ]
    expandSelections
      (retained <> paths)
      (invalid || childInvalid)
      rest

resolveSessionPathComponent
  :: Expr
  -> Expr
  -> Either Text ([SessionPathSelection], Bool)
resolveSessionPathComponent _ (Integer 0) =
  P.Left "Position does not support index 0 in this position."
resolveSessionPathComponent expression component =
  case sessionOrderedCollection expression of
    Nothing -> P.Right ([], True)
    Just collection
      | sessionCollectionAssociation collection ->
          resolveSessionAssociationComponent
            (sessionCollectionItems collection)
            component
      | otherwise -> do
          (indices, invalid) <-
            resolveSessionNumericSelectors
              (length (sessionCollectionItems collection))
              component
          P.Right
            ( mapMaybeSession
                (sessionSelectionAt (sessionCollectionItems collection))
                indices
            , invalid
            )

resolveSessionAssociationComponent
  :: [SessionOrderedItem]
  -> Expr
  -> Either Text ([SessionPathSelection], Bool)
resolveSessionAssociationComponent items component
  | Just key <- sessionKeySelectorValue component =
      selectSessionAssociationKeys items [key]
resolveSessionAssociationComponent items component@(Call (Symbol listHead) selectors)
  | isSessionSystemHead "List" listHead =
      case traverse sessionAssociationSelectorKind selectors of
        Nothing -> unsupportedSelectorInsidePosition component
        Just kinds
          | any id kinds && any not kinds ->
              P.Left "Association selector lists may not mix numeric and key selectors."
          | any id kinds ->
              selectKeys
                (mapMaybeSession sessionKeySelectorValue selectors)
          | otherwise -> selectNumeric
 where
  selectNumeric = do
    (indices, invalid) <-
      resolveSessionNumericSelectors (length items) component
    P.Right
      (mapMaybeSession (sessionSelectionAt items) indices, invalid)

  selectKeys keys = selectSessionAssociationKeys items keys
resolveSessionAssociationComponent items component = do
  (indices, invalid) <-
    resolveSessionNumericSelectors (length items) component
  P.Right (mapMaybeSession (sessionSelectionAt items) indices, invalid)

selectSessionAssociationKeys
  :: [SessionOrderedItem]
  -> [Expr]
  -> Either Text ([SessionPathSelection], Bool)
selectSessionAssociationKeys items = go [] False
 where
  go retained invalid [] = P.Right (retained, invalid)
  go retained invalid (key : rest) =
    case sessionAssociationItemIndex (SessionKeySelector key) items of
      Nothing -> go retained True rest
      Just index -> case sessionListItemAt index items of
        Nothing -> go retained True rest
        Just item ->
          go
            ( retained
                <> [SessionPathSelection (SessionKeySelector key) (sessionItemValue item)]
            )
            invalid
            rest

sessionSelectionAt
  :: [SessionOrderedItem]
  -> Int
  -> Maybe SessionPathSelection
sessionSelectionAt items index = do
  item <- sessionListItemAt index items
  Just
    ( SessionPathSelection
        (SessionArgumentSelector (fromIntegral index + 1))
        (sessionItemValue item)
    )

resolveSessionNumericSelectors
  :: Int
  -> Expr
  -> Either Text ([Int], Bool)
resolveSessionNumericSelectors count component = case component of
  Integer 0 ->
    P.Left "Position does not support index 0 in this position."
  Integer position ->
    P.Right
      ( maybe [] pure resolved
      , maybe True (const False) resolved
      )
   where
    resolved = resolveSessionPosition count position
  Symbol "All" -> P.Right ([0 .. count - 1], False)
  spanSpecification@(Call (Symbol spanHead) _)
    | isSessionSystemHead "Span" spanHead -> do
        positions <- expandSessionPositionSpan count spanSpecification
        let resolved = map (resolveSessionPosition count) positions
        P.Right
          ( mapMaybeSession id resolved
          , any (maybe True (const False)) resolved
          )
  Call (Symbol listHead) selectors
    | isSessionSystemHead "List" listHead ->
        appendSelectors [] False selectors
  _ ->
    P.Left
      ( "Unsupported Position specification: "
          <> inputForm component
          <> "."
      )
 where
  appendSelectors retained invalid [] = P.Right (retained, invalid)
  appendSelectors retained invalid (selector : rest)
    | isSessionKeySelector selector = unsupportedSelectorInsidePosition selector
    | otherwise = do
        (nested, nestedInvalid) <-
          resolveSessionNumericSelectors count selector
        appendSelectors
          (retained <> nested)
          (invalid || nestedInvalid)
          rest

expandSessionPositionSpan :: Int -> Expr -> Either Text [Integer]
expandSessionPositionSpan count (Call (Symbol spanHead) arguments')
  | isSessionSystemHead "Span" spanHead =
      case arguments' of
        [startExpression, endExpression] ->
          expand startExpression endExpression (Integer 1)
        [startExpression, endExpression, stepExpression] ->
          expand startExpression endExpression stepExpression
        _ -> P.Left "Span must contain two or three arguments."
 where
  expand startExpression endExpression stepExpression = do
    step <- case stepExpression of
      Integer value -> P.Right value
      _ -> P.Left "Span steps must be integers."
    if step == 0
      then P.Left "Span step cannot be zero."
      else
        let start = spanEndpoint startExpression 1
            end = spanEndpoint endExpression (fromIntegral count)
         in P.Right
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
expandSessionPositionSpan _ _ = P.Left "Span must contain two or three arguments."

isSessionPositionCollection :: Expr -> Bool
isSessionPositionCollection (Call (Symbol listHead) values) =
  isSessionSystemHead "List" listHead
    && not (null values)
    && all isExplicitSessionPositionPath values
isSessionPositionCollection _ = False

isExplicitSessionPositionPath :: Expr -> Bool
isExplicitSessionPositionPath (Call (Symbol listHead) components) =
  isSessionSystemHead "List" listHead
    && all isSessionPositionComponent components
isExplicitSessionPositionPath _ = False

isSingleSessionPositionSpecification :: Expr -> Bool
isSingleSessionPositionSpecification Integer {} = True
isSingleSessionPositionSpecification expression
  | isSessionKeySelector expression = True
isSingleSessionPositionSpecification (Call (Symbol listHead) components) =
  isSessionSystemHead "List" listHead
    && all isSessionPositionComponent components
isSingleSessionPositionSpecification _ = False

isSessionPositionComponent :: Expr -> Bool
isSessionPositionComponent expression
  | isSessionSelectorAtom expression = True
isSessionPositionComponent (Call (Symbol listHead) selectors) =
  isSessionSystemHead "List" listHead
    && all isSessionSelectorAtom selectors
isSessionPositionComponent _ = False

isSessionSelectorAtom :: Expr -> Bool
isSessionSelectorAtom expression =
  isSessionNumericSelectorAtom expression || isSessionKeySelector expression

isSessionNumericSelectorAtom :: Expr -> Bool
isSessionNumericSelectorAtom Integer {} = True
isSessionNumericSelectorAtom (Symbol "All") = True
isSessionNumericSelectorAtom (Call (Symbol spanHead) _) =
  isSessionSystemHead "Span" spanHead
isSessionNumericSelectorAtom _ = False

isSessionKeySelector :: Expr -> Bool
isSessionKeySelector = maybe False (const True) . sessionKeySelectorValue

sessionKeySelectorValue :: Expr -> Maybe Expr
sessionKeySelectorValue key@String {} = Just key
sessionKeySelectorValue (Call (Symbol keyHead) [key])
  | isSessionSystemHead "Key" keyHead = Just key
sessionKeySelectorValue _ = Nothing

sessionAssociationSelectorKind :: Expr -> Maybe Bool
sessionAssociationSelectorKind expression
  | isSessionKeySelector expression = Just True
  | isSessionNumericSelectorAtom expression = Just False
sessionAssociationSelectorKind _ = Nothing

sessionPositionComponents :: Expr -> [Expr]
sessionPositionComponents (Call (Symbol listHead) components)
  | isSessionSystemHead "List" listHead = components
sessionPositionComponents expression = [expression]

unsupportedPositionSpecification
  :: Expr
  -> Either Text value
unsupportedPositionSpecification specification =
  P.Left
    ( "Unsupported position specification: "
        <> inputForm specification
        <> "."
    )

unsupportedSelectorInsidePosition :: Expr -> Either Text value
unsupportedSelectorInsidePosition selector =
  P.Left
    ( "Unsupported selector inside Position specification: "
        <> inputForm selector
        <> "."
    )

sessionAssociationItemIndex
  :: SessionPathSelector
  -> [SessionOrderedItem]
  -> Maybe Int
sessionAssociationItemIndex (SessionArgumentSelector position) items =
  resolveSessionPosition (length items) position
sessionAssociationItemIndex (SessionKeySelector key) items = go 0 items
 where
  go _ [] = Nothing
  go index (item : rest)
    | sessionItemKey item == Just key = Just index
    | otherwise = go (index + 1) rest

resolveSessionPosition :: Int -> Integer -> Maybe Int
resolveSessionPosition count position
  | position > 0
  , position <= fromIntegral count = Just (fromIntegral position - 1)
  | position < 0
  , position >= negate (fromIntegral count) = Just (count + fromIntegral position)
  | otherwise = Nothing

sortSessionPaths :: [[SessionPathSelector]] -> [[SessionPathSelector]]
sortSessionPaths = sortBy compareSessionPath

compareSessionPath :: [SessionPathSelector] -> [SessionPathSelector] -> Ordering
compareSessionPath left right = case compare (length right) (length left) of
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
  compareSelector (SessionArgumentSelector leftPosition) (SessionArgumentSelector rightPosition) =
    compare leftPosition rightPosition
  compareSelector (SessionKeySelector leftKey) (SessionKeySelector rightKey) =
    compare (inputForm leftKey) (inputForm rightKey)
  compareSelector SessionArgumentSelector {} SessionKeySelector {} = LT
  compareSelector SessionKeySelector {} SessionArgumentSelector {} = GT

replaceSessionListIndex :: Int -> value -> [value] -> [value]
replaceSessionListIndex index replacement values =
  take index values <> [replacement] <> drop (index + 1) values

sessionListItemAt :: Int -> [value] -> Maybe value
sessionListItemAt 0 (value : _) = Just value
sessionListItemAt index (_ : rest)
  | index > 0 = sessionListItemAt (index - 1) rest
sessionListItemAt _ _ = Nothing

replaceSessionItemValue :: SessionOrderedItem -> Expr -> SessionOrderedItem
replaceSessionItemValue item value =
  item
    { sessionItemValue = value
    , sessionItemOriginal = case sessionItemKey item of
        Just key ->
          Call (Symbol (sessionItemRuleHead item)) [key, value]
        Nothing -> value
    }

sessionItemRuleHead :: SessionOrderedItem -> Text
sessionItemRuleHead item = case sessionItemOriginal item of
  Call (Symbol ruleHead) [_, _]
    | ruleHead `elem` ["Rule", "RuleDelayed"] -> ruleHead
  _ -> "Rule"

data SessionDecoratedItem = SessionDecoratedItem
  { decoratedSessionItem :: !SessionOrderedItem
  , decoratedSessionKeys :: ![Expr]
  }
  deriving (Eq, Show)

splitSessionSameTestOptions
  :: Text
  -> [Expr]
  -> Either Text ([Expr], Maybe Expr)
splitSessionSameTestOptions operation values
  | any ((/= "SameTest") . fst) optionParts =
      P.Left (operation <> " currently supports only the SameTest option.")
  | otherwise = P.Right (dataValues, normalizeSameTest selectedSameTest)
 where
  (dataValues, options) = splitTrailingSessionOptions values
  optionParts =
    [ parts
    | option <- options
    , Just parts <- [sessionOptionRuleParts option]
    ]
  selectedSameTest = foldl retainLast Nothing optionParts
  retainLast retained (name, value)
    | name == "SameTest" = Just value
    | otherwise = retained
  normalizeSameTest (Just (Symbol "Automatic")) = Nothing
  normalizeSameTest other = other

evaluateSessionEqualWithSameTest
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionEqualWithSameTest depth session values =
  case splitSessionSameTestOptions "Equal" values of
    P.Left message -> sessionFailure session message
    P.Right (dataValues, sameTest) ->
      let compareAdjacent current (left : right : rest) = do
            (same, updated) <- sessionValuesSame depth sameTest current left right
            if same
              then compareAdjacent updated (right : rest)
              else Right (Symbol "False", updated)
          compareAdjacent current _ = Right (Symbol "True", current)
       in compareAdjacent session dataValues

evaluateSessionSetOperation
  :: Text
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSetOperation operation depth session values =
  case splitSessionSameTestOptions operation values of
    P.Left message -> sessionFailure session message
    P.Right (dataValues, sameTest) -> case traverse sessionListValues dataValues of
      Nothing -> sessionFailure session (operation <> " expects a list or association.")
      Just lists -> case (operation, lists) of
        ("Union", _) -> do
          (unique, updated) <- uniqueSessionValues depth sameTest session (concat lists)
          Right (evaluatedList unique, updated)
        ("Intersection", first : remaining) -> do
          (uniqueFirst, firstSession) <- uniqueSessionValues depth sameTest session first
          (retained, updated) <- retainIntersection sameTest firstSession uniqueFirst remaining
          Right (evaluatedList retained, updated)
        ("Complement", first : remaining) -> do
          (uniqueFirst, firstSession) <- uniqueSessionValues depth sameTest session first
          (retained, updated) <- removeComplement sameTest firstSession uniqueFirst (concat remaining)
          Right (evaluatedList retained, updated)
        _ -> sessionFailure session (operation <> " expects at least one list.")
 where
  sessionListValues (Call (Symbol listHead) listValues)
    | isSessionSystemHead "List" listHead = Just listValues
  sessionListValues _ = Nothing
  retainIntersection _ current [] _ = Right ([], current)
  retainIntersection selectedSameTest current (candidate : rest) lists = do
    (present, updated) <- presentInEvery selectedSameTest current candidate lists
    (retained, finalSession) <- retainIntersection selectedSameTest updated rest lists
    Right (if present then candidate : retained else retained, finalSession)
  presentInEvery _ current _ [] = Right (True, current)
  presentInEvery selectedSameTest current candidate (listValues : rest) = do
    (present, updated) <- anySessionValueSame depth selectedSameTest current candidate listValues
    if present then presentInEvery selectedSameTest updated candidate rest else Right (False, updated)
  removeComplement _ current [] _ = Right ([], current)
  removeComplement selectedSameTest current (candidate : rest) excluded = do
    (present, updated) <- anySessionValueSame depth selectedSameTest current candidate excluded
    (retained, finalSession) <- removeComplement selectedSameTest updated rest excluded
    Right (if present then retained else candidate : retained, finalSession)

uniqueSessionValues
  :: Int
  -> Maybe Expr
  -> EvaluationSession
  -> [Expr]
  -> SessionResult [Expr]
uniqueSessionValues depth sameTest session values = go session [] (sortBy canonicalCompare values)
 where
  go current retained [] = Right (reverse retained, current)
  go current retained (candidate : rest) = do
    (duplicate, updated) <- anySessionValueSame depth sameTest current candidate retained
    go updated (if duplicate then retained else candidate : retained) rest

anySessionValueSame
  :: Int
  -> Maybe Expr
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult Bool
anySessionValueSame _ _ session _ [] = Right (False, session)
anySessionValueSame depth sameTest session candidate (value : rest) = do
  (same, updated) <- sessionValuesSame depth sameTest session candidate value
  if same
    then Right (True, updated)
    else anySessionValueSame depth sameTest updated candidate rest

sessionValuesSame
  :: Int
  -> Maybe Expr
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Bool
sessionValuesSame _ Nothing session left right = Right (left == right, session)
sessionValuesSame depth (Just function) session left right =
  evaluateSessionSameTest depth (Just function) session left right

splitTrailingSessionOptions :: [Expr] -> ([Expr], [Expr])
splitTrailingSessionOptions values =
  (reverse reversedArguments, reverse reversedOptions)
 where
  (reversedOptions, reversedArguments) =
    span isSessionOptionRule (reverse values)

isSessionOptionRule :: Expr -> Bool
isSessionOptionRule expression = case sessionOptionRuleParts expression of
  Just _ -> True
  Nothing -> False

sessionOptionRuleParts :: Expr -> Maybe (Text, Expr)
sessionOptionRuleParts = \case
  Call (Symbol ruleHead) [Symbol name, value]
    | ruleHead `elem` ["Rule", "RuleDelayed"] -> Just (name, value)
  _ -> Nothing

evaluateSessionSort
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSort reverseMode depth session = \case
  [subject, specification] -> case sessionOrderedCollection subject of
    Nothing -> sessionFailure session (operation <> " expects a nonatomic expression.")
    Just collection -> do
      (sorted, updated) <-
        pythonStableSortByStateM
          compareItems
          session
          (sessionCollectionItems collection)
      Right (rebuildSessionCollection collection sorted, updated)
   where
    compareItems current left right = do
      ordering <- case sameTestFunction specification of
        Just test -> do
          (same, updated) <-
            evaluateSessionSameTest
              depth
              (Just test)
              current
              (sessionItemValue left)
              (sessionItemValue right)
          Right
            ( if same
                then EQ
                else canonicalCompare (sessionItemValue left) (sessionItemValue right)
            , updated
            )
        Nothing ->
          evaluateSessionOrderingCompare
            depth
            specification
            current
            (sessionItemValue left)
            (sessionItemValue right)
      let (result, updated) = ordering
      Right (if reverseMode then invertSessionOrdering result else result, updated)
  _ -> sessionFailure session (operation <> " expects one or two arguments.")
 where
  operation = if reverseMode then "ReverseSort" else "Sort"
  sameTestFunction (Call (Symbol ruleHead) [Symbol optionName, function])
    | isSessionSystemHead "Rule" ruleHead
        || isSessionSystemHead "RuleDelayed" ruleHead
    , isSessionSystemHead "SameTest" optionName = Just function
  sameTestFunction _ = Nothing

evaluateSessionOrdering
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOrdering depth session values =
  case splitSessionSameTestOptions "Ordering" values of
    P.Left message -> sessionFailure session message
    P.Right ([subject, count, function], sameTest) -> case sessionOrderedCollection subject of
      Nothing -> sessionFailure session "Ordering expects a nonatomic expression."
      Just collection -> do
        (sorted, updated) <-
          pythonStableSortByStateM
            (compareItems sameTest function)
            session
            (sessionCollectionItems collection)
        case sliceSessionOrderingCount (Just count) sorted of
          P.Left message -> sessionFailure updated message
          P.Right selected ->
            Right (evaluatedList (map (Integer . sessionItemIndex) selected), updated)
    _ ->
      sessionFailure
        session
        "Ordering expects an expression, an optional count, and an optional ordering function."
 where
  compareItems sameTest function current left right = do
    (same, sameSession) <-
      sessionValuesSame
        depth
        sameTest
        current
        (sessionItemValue left)
        (sessionItemValue right)
    if same
      then Right (EQ, sameSession)
      else
        evaluateSessionOrderingCompare
          depth
          function
          sameSession
          (sessionItemValue left)
          (sessionItemValue right)

evaluateSessionOrderedQ
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOrderedQ depth session = \case
  [subject, function] -> case sessionOrderedCollection subject of
    Nothing -> sessionFailure session "OrderedQ expects a nonatomic expression."
    Just collection ->
      checkPairs session (map sessionItemValue (sessionCollectionItems collection))
   where
    checkPairs current (left : right : remaining) = do
      (outcome, updated) <-
        evaluateSessionCallable depth current function [left, right]
      if outcome == Symbol "True"
        then checkPairs updated (right : remaining)
        else Right (Symbol "False", updated)
    checkPairs current _ = Right (Symbol "True", current)
  _ -> sessionFailure session "OrderedQ expects one or two arguments."

evaluateSessionSortBy
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSortBy reverseMode depth session values =
  case splitSessionSameTestOptions operation values of
    P.Left message -> sessionFailure session message
    P.Right (sortArguments, sameTest) -> case sortArguments of
      [_]
        | sameTest == Nothing ->
            Right (Call (Symbol operation) values, session)
      [subject, functions] ->
        sortSubject subject functions Nothing sameTest
      [subject, functions, orderingFunction] ->
        sortSubject subject functions (Just orderingFunction) sameTest
      _ ->
        sessionFailure
          session
          ( operation
              <> " expects an expression, functions, optional ordering function, and optional SameTest rule."
          )
 where
  operation = if reverseMode then "ReverseSortBy" else "SortBy"

  sortSubject subject functions orderingFunction sameTest =
    case sessionOrderedCollection subject of
      Nothing -> sessionFailure session "SortBy expects a nonatomic expression."
      Just collection -> do
        let (keyFunctions, keySpecIsList) =
              sessionOrderingKeyFunctions functions
        (decorated, keySession) <-
          decorateSessionItems
            depth
            keyFunctions
            session
            (sessionCollectionItems collection)
        (sorted, updated) <-
          pythonStableSortByStateM
            ( compareDecoratedSessionItems
                reverseMode
                keySpecIsList
                depth
                orderingFunction
                sameTest
            )
            keySession
            decorated
        Right
          ( rebuildSessionCollection
              collection
              (map decoratedSessionItem sorted)
          , updated
          )

evaluateSessionOrderingBy
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOrderingBy depth session values =
  case splitSessionSameTestOptions "OrderingBy" values of
    P.Left message -> sessionFailure session message
    P.Right (orderingArguments, sameTest) -> case orderingArguments of
      [_]
        | sameTest == Nothing ->
            Right (Call (Symbol "OrderingBy") values, session)
      [subject, functions] ->
        orderSubject subject functions Nothing Nothing sameTest
      [subject, functions, count] ->
        orderSubject subject functions (Just count) Nothing sameTest
      [subject, functions, count, orderingFunction] ->
        orderSubject
          subject
          functions
          (Just count)
          (Just orderingFunction)
          sameTest
      _ ->
        sessionFailure
          session
          "OrderingBy expects an expression, functions, optional count, optional ordering function, and optional SameTest rule."
 where
  orderSubject subject functions count orderingFunction sameTest =
    case sessionOrderedCollection subject of
      Nothing ->
        sessionFailure session "OrderingBy expects a nonatomic expression."
      Just collection -> do
        let (keyFunctions, keySpecIsList) =
              sessionOrderingKeyFunctions functions
        (decorated, keySession) <-
          decorateSessionItems
            depth
            keyFunctions
            session
            (sessionCollectionItems collection)
        (sorted, sortedSession) <-
          pythonStableSortByStateM
            ( compareDecoratedSessionItems
                False
                keySpecIsList
                depth
                orderingFunction
                sameTest
            )
            keySession
            decorated
        case sliceSessionOrderingCount count sorted of
          P.Left message -> sessionFailure sortedSession message
          P.Right selected ->
            Right
              ( evaluatedList
                  ( map
                      ( Integer
                          . sessionItemIndex
                          . decoratedSessionItem
                      )
                      selected
                  )
              , sortedSession
              )

evaluateSessionExtremeBy
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionExtremeBy maximal depth session values =
  case values of
    [_] -> Right (Call (Symbol operation) values, session)
    [subject, functions] ->
      selectSubject subject functions Nothing Nothing
    [subject, functions, count] ->
      selectSubject subject functions (Just count) Nothing
    [subject, functions, count, orderingFunction] ->
      selectSubject
        subject
        functions
        (Just count)
        (Just orderingFunction)
    _ ->
      sessionFailure
        session
        ( operation
            <> " expects data, a function specification, optional count, and optional ordering function."
        )
 where
  operation = if maximal then "MaximalBy" else "MinimalBy"

  selectSubject subject functions count orderingFunction =
    case sessionOrderedCollection subject of
      Nothing ->
        sessionFailure
          session
          (operation <> " expects a nonatomic expression.")
      Just collection -> do
        let (keyFunctions, _) = sessionOrderingKeyFunctions functions
        (decorated, keySession) <-
          decorateSessionItems
            depth
            keyFunctions
            session
            (sessionCollectionItems collection)
        case decorated of
          [] ->
            Right (rebuildSessionCollection collection [], keySession)
          first : rest -> case count of
            Nothing -> do
              (selected, updated) <-
                selectTiedExtrema
                  orderingFunction
                  first
                  [first]
                  keySession
                  rest
              Right
                ( rebuildSessionCollection
                    collection
                    (map decoratedSessionItem selected)
                , updated
                )
            Just countExpression -> do
              (sorted, sortedSession) <-
                pythonStableSortByStateM
                  ( compareDecoratedSessionItems
                      maximal
                      True
                      depth
                      orderingFunction
                      Nothing
                  )
                  keySession
                  decorated
              case sliceSessionExtremeCount operation countExpression sorted of
                P.Left message -> sessionFailure sortedSession message
                P.Right selected ->
                  Right
                    ( rebuildSessionCollection
                        collection
                        (map decoratedSessionItem selected)
                    , sortedSession
                    )

  selectTiedExtrema _ _ retained currentSession [] =
    Right (retained, currentSession)
  selectTiedExtrema
    orderingFunction
    best
    retained
    currentSession
    (item : rest) = do
      (ordering, updated) <-
        compareDecoratedSessionItems
          False
          True
          depth
          orderingFunction
          Nothing
          currentSession
          item
          best
      if ordering == preferredOrdering
        then
          selectTiedExtrema
            orderingFunction
            item
            [item]
            updated
            rest
        else
          selectTiedExtrema
            orderingFunction
            best
            (if ordering == EQ then retained <> [item] else retained)
            updated
            rest

  preferredOrdering = if maximal then GT else LT

sessionOrderingKeyFunctions :: Expr -> ([Expr], Bool)
sessionOrderingKeyFunctions = \case
  Call (Symbol listHead) functions
    | isSessionSystemHead "List" listHead -> (functions, True)
  function -> ([function], False)

sliceSessionOrderingCount
  :: Maybe Expr
  -> [value]
  -> Either Text [value]
sliceSessionOrderingCount count values = case count of
  Nothing -> P.Right values
  Just (Symbol "All") -> P.Right values
  Just (Integer amount)
    | amount >= 0 -> P.Right (takeSessionInteger amount values)
    | negate amount > toInteger (length values) -> P.Right values
    | otherwise ->
        P.Right
          ( drop
              (length values - fromInteger (negate amount))
              values
          )
  Just _ -> P.Left "OrderingBy expects an integer or All count."

sliceSessionExtremeCount
  :: Text
  -> Expr
  -> [value]
  -> Either Text [value]
sliceSessionExtremeCount operation count values = case count of
  Symbol "All" -> P.Right values
  Integer amount
    | amount < 0 ->
        P.Left (operation <> " expects a non-negative count.")
    | otherwise -> P.Right (takeSessionInteger amount values)
  Call (Symbol upToHead) [Integer amount]
    | isSessionSystemHead "UpTo" upToHead ->
        P.Right (takeSessionInteger (max 0 amount) values)
  Call (Symbol upToHead) [_]
    | isSessionSystemHead "UpTo" upToHead ->
        P.Left (operation <> " expects UpTo[n] with an integer n.")
  _ ->
    P.Left
      (operation <> " expects an integer, UpTo[n], or All count.")

takeSessionInteger :: Integer -> [value] -> [value]
takeSessionInteger amount values
  | amount <= 0 = []
  | amount >= toInteger (length values) = values
  | otherwise = take (fromInteger amount) values

decorateSessionItems
  :: Int
  -> [Expr]
  -> EvaluationSession
  -> [SessionOrderedItem]
  -> SessionResult [SessionDecoratedItem]
decorateSessionItems depth functions = go []
 where
  go retained session [] = Right (retained, session)
  go retained session (item : rest) = do
    (keys, updated) <- decorateKeys [] session functions
    go (retained <> [SessionDecoratedItem item keys]) updated rest
   where
    decorateKeys keys currentSession [] = Right (keys, currentSession)
    decorateKeys keys currentSession (function : remaining) = do
      (key, updated) <-
        evaluateSessionCallable
          depth
          currentSession
          function
          [sessionItemValue item]
      decorateKeys (keys <> [key]) updated remaining

compareDecoratedSessionItems
  :: Bool
  -> Bool
  -> Int
  -> Maybe Expr
  -> Maybe Expr
  -> EvaluationSession
  -> SessionDecoratedItem
  -> SessionDecoratedItem
  -> SessionResult Ordering
compareDecoratedSessionItems
  reverseMode
  keySpecIsList
  depth
  orderingFunction
  sameTest
  session
  left
  right = do
    (keyOrdering, updated) <-
      compareKeys
        session
        (decoratedSessionKeys left)
        (decoratedSessionKeys right)
    let tieOrdering
          | sameTest /= Nothing = EQ
          | keySpecIsList = EQ
          | otherwise =
              canonicalCompare
                (sessionItemValue (decoratedSessionItem left))
                (sessionItemValue (decoratedSessionItem right))
        result = if keyOrdering == EQ then tieOrdering else keyOrdering
    Right (reverseIfNeeded result, updated)
 where
  compareKeys currentSession [] [] = Right (EQ, currentSession)
  compareKeys currentSession [] (_ : _) = Right (LT, currentSession)
  compareKeys currentSession (_ : _) [] = Right (GT, currentSession)
  compareKeys currentSession (leftKey : leftRest) (rightKey : rightRest) = do
    (same, sameTestSession) <-
      evaluateSessionSameTest depth sameTest currentSession leftKey rightKey
    if same
      then compareKeys sameTestSession leftRest rightRest
      else do
        (ordering, orderingSession) <- case orderingFunction of
          Nothing -> Right (canonicalCompare leftKey rightKey, sameTestSession)
          Just function ->
            evaluateSessionOrderingCompare
              depth
              function
              sameTestSession
              leftKey
              rightKey
        if ordering == EQ
          then compareKeys orderingSession leftRest rightRest
          else Right (ordering, orderingSession)

  reverseIfNeeded ordering
    | reverseMode = invertSessionOrdering ordering
    | otherwise = ordering

evaluateSessionSameTest
  :: Int
  -> Maybe Expr
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Bool
evaluateSessionSameTest _ Nothing session _ _ = Right (False, session)
evaluateSessionSameTest depth (Just function) session left right = do
  (firstValue, firstSession) <-
    evaluateSessionCallable depth session function [left, right]
  (result, updated) <-
    evaluateSessionAt (depth + 1) firstSession firstValue
  Right (result == Symbol "True", updated)

evaluateSessionOrderingCompare
  :: Int
  -> Expr
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Ordering
evaluateSessionOrderingCompare depth function session left right = do
  (firstValue, firstSession) <-
    evaluateSessionCallable depth session function [left, right]
  (firstResult, evaluatedSession) <-
    evaluateSessionAt (depth + 1) firstSession firstValue
  case firstResult of
    Symbol "True" -> Right (LT, evaluatedSession)
    Symbol "False" -> do
      (reverseValue, reverseSession) <-
        evaluateSessionCallable depth evaluatedSession function [right, left]
      (reverseResult, finalSession) <-
        evaluateSessionAt (depth + 1) reverseSession reverseValue
      Right (reverseOrdering reverseResult, finalSession)
    Integer value -> Right (integerOrdering (negate value), evaluatedSession)
    _ -> Right (canonicalCompare left right, evaluatedSession)
 where
  reverseOrdering (Symbol "True") = GT
  reverseOrdering (Symbol "False") = EQ
  reverseOrdering (Integer value) = integerOrdering value
  reverseOrdering _ = EQ
  integerOrdering value
    | value < 0 = LT
    | value > 0 = GT
    | otherwise = EQ

invertSessionOrdering :: Ordering -> Ordering
invertSessionOrdering LT = GT
invertSessionOrdering EQ = EQ
invertSessionOrdering GT = LT

data SessionOrderedItem = SessionOrderedItem
  { sessionItemIndex :: !Integer
  , sessionItemValue :: !Expr
  , sessionItemKey :: !(Maybe Expr)
  , sessionItemOriginal :: !Expr
  }
  deriving (Eq, Show)

data SessionOrderedCollection = SessionOrderedCollection
  { sessionCollectionOriginal :: !Expr
  , sessionCollectionAssociation :: !Bool
  , sessionCollectionItems :: ![SessionOrderedItem]
  }
  deriving (Eq, Show)

sessionOrderedCollection :: Expr -> Maybe SessionOrderedCollection
sessionOrderedCollection expression@(Call (Symbol associationHead) rules)
  | isSessionSystemHead "Association" associationHead
  , Just items <- traverse (uncurry associationItem) (zip [1 ..] rules) =
      Just (SessionOrderedCollection expression True items)
sessionOrderedCollection expression@(Call _ values) =
  Just
    ( SessionOrderedCollection
        expression
        False
        [ SessionOrderedItem index value Nothing value
        | (index, value) <- zip [1 ..] values
        ]
    )
sessionOrderedCollection _ = Nothing

associationItem :: Integer -> Expr -> Maybe SessionOrderedItem
associationItem index rule@(Call (Symbol ruleHead) [key, value])
  | isSessionSystemHead "Rule" ruleHead
      || isSessionSystemHead "RuleDelayed" ruleHead =
      Just (SessionOrderedItem index value (Just key) rule)
associationItem _ _ = Nothing

rebuildSessionCollection
  :: SessionOrderedCollection
  -> [SessionOrderedItem]
  -> Expr
rebuildSessionCollection collection retained =
  case sessionCollectionOriginal collection of
    Call expressionHead _
      | sessionCollectionAssociation collection ->
          normalizedSessionAssociation (map sessionItemOriginal retained)
      | otherwise ->
          normalizeEvaluatedCall expressionHead (map sessionItemValue retained)
    expression -> expression

data SessionSelectionProperty
  = SelectionElement
  | SelectionIndex
  deriving (Eq, Show)

data SessionSelectionPropertySpec
  = SingleSelectionProperty !SessionSelectionProperty
  | MultipleSelectionProperties ![SessionSelectionProperty]
  deriving (Eq, Show)

parseSessionSelectionSpec
  :: Text
  -> Expr
  -> Either Text (Expr, Maybe SessionSelectionPropertySpec)
parseSessionSelectionSpec operation criterion = case criterion of
  Call (Symbol "Rule") [selector, propertyExpression] -> do
    propertySpec <- parsePropertyExpression propertyExpression
    P.Right (selector, Just propertySpec)
  Call (Symbol "Rule") _ ->
    P.Left (operation <> " property specifications must contain exactly two arguments.")
  _ -> P.Right (criterion, Nothing)
 where
  parsePropertyExpression (String "Element") =
    P.Right (SingleSelectionProperty SelectionElement)
  parsePropertyExpression (String "Index") =
    P.Right (SingleSelectionProperty SelectionIndex)
  parsePropertyExpression (Call (Symbol "List") properties) =
    MultipleSelectionProperties <$> traverse parseProperty properties
  parsePropertyExpression _ =
    P.Left
      ( operation
          <> " currently supports only \"Element\" and \"Index\" properties."
      )
  parseProperty (String "Element") = P.Right SelectionElement
  parseProperty (String "Index") = P.Right SelectionIndex
  parseProperty _ =
    P.Left
      ( operation
          <> " currently supports only \"Element\" and \"Index\" properties."
      )

projectSessionSelection
  :: SessionOrderedCollection
  -> [SessionOrderedItem]
  -> Maybe SessionSelectionPropertySpec
  -> Expr
projectSessionSelection collection retained = \case
  Nothing -> elements
  Just (SingleSelectionProperty SelectionElement) -> elements
  Just (SingleSelectionProperty SelectionIndex) -> indices
  Just (MultipleSelectionProperties properties) ->
    normalizedSessionAssociation
      [ Call
          (Symbol "Rule")
          [String (selectionPropertyName property), project property]
      | property <- properties
      ]
 where
  elements = rebuildSessionCollection collection retained
  indices = Call (Symbol "List") (map (Integer . sessionItemIndex) retained)
  project SelectionElement = elements
  project SelectionIndex = indices

projectSessionSelectFirst
  :: Maybe SessionOrderedItem
  -> Maybe Expr
  -> Maybe SessionSelectionPropertySpec
  -> Expr
projectSessionSelectFirst selected defaultValue = \case
  Nothing -> element
  Just (SingleSelectionProperty SelectionElement) -> element
  Just (SingleSelectionProperty SelectionIndex) -> index
  Just (MultipleSelectionProperties properties) ->
    normalizedSessionAssociation
      [ Call
          (Symbol "Rule")
          [String (selectionPropertyName property), project property]
      | property <- properties
      ]
 where
  missing = Call (Symbol "Missing") [String "NotFound"]
  element = maybe (maybe missing id defaultValue) sessionItemValue selected
  index = maybe missing (Integer . sessionItemIndex) selected
  project SelectionElement = element
  project SelectionIndex = index

selectionPropertyName :: SessionSelectionProperty -> Text
selectionPropertyName SelectionElement = "Element"
selectionPropertyName SelectionIndex = "Index"

normalizedSessionAssociation :: [Expr] -> Expr
normalizedSessionAssociation rules =
  let expression = Call (Symbol "Association") rules
   in either (const expression) id (reduceEvaluatedCall expression)

evaluateSessionPredicate
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Bool
evaluateSessionPredicate depth session criterion value = do
  (firstResult, firstSession) <-
    evaluateSessionAt (depth + 1) session (Call criterion [value])
  (finalResult, finalSession) <-
    evaluateSessionAt (depth + 1) firstSession firstResult
  Right (finalResult == Symbol "True", finalSession)

evaluateSessionSelect
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSelect discardMode depth session values =
  case values of
    [subject, criterion] -> select subject criterion Nothing
    [subject, criterion, limit] -> select subject criterion (Just limit)
    _ ->
      sessionFailure
        session
        ( operation
            <> " expects an expression, a criterion or property specification, and an optional limit."
        )
 where
  operation = if discardMode then "Discard" else "Select"
  select subject criterion limitExpression =
    case parseSessionSelectionSpec operation criterion of
      P.Left message -> sessionFailure session message
      P.Right (selector, propertySpec) -> case sessionOrderedCollection subject of
        Nothing -> sessionFailure session (operation <> " expects a nonatomic expression.")
        Just collection -> case sessionSelectionLimit limitExpression of
          Nothing ->
            sessionFailure
              session
              "Match limits must be non-negative integers or Infinity."
          Just remaining -> do
            (retained, updated) <-
              if discardMode
                then discardItems selector remaining [] session (sessionCollectionItems collection)
                else selectItems selector remaining [] session (sessionCollectionItems collection)
            Right (projectSessionSelection collection retained propertySpec, updated)

  selectItems _ _ retained currentSession [] =
    Right (retained, currentSession)
  selectItems criterion remaining retained currentSession (item : rest) = do
    (matches, updated) <-
      evaluateSessionPredicate depth currentSession criterion (sessionItemValue item)
    if matches
      then case remaining of
        Just 0 -> Right (retained, updated)
        Just count ->
          selectItems criterion (Just (count - 1)) (retained <> [item]) updated rest
        Nothing -> selectItems criterion Nothing (retained <> [item]) updated rest
      else selectItems criterion remaining retained updated rest

  discardItems _ _ retained currentSession [] =
    Right (retained, currentSession)
  discardItems criterion remaining retained currentSession items@(item : rest) =
    case remaining of
      Just 0 -> Right (retained <> items, currentSession)
      _ -> do
        (matches, updated) <-
          evaluateSessionPredicate depth currentSession criterion (sessionItemValue item)
        if matches
          then case remaining of
            Just count -> discardItems criterion (Just (count - 1)) retained updated rest
            Nothing -> discardItems criterion Nothing retained updated rest
          else discardItems criterion remaining (retained <> [item]) updated rest

evaluateSessionSelectFirst
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSelectFirst depth session values = case values of
  [subject, criterion] -> selectFirst subject criterion Nothing
  [subject, criterion, defaultValue] -> selectFirst subject criterion (Just defaultValue)
  _ ->
    sessionFailure
      session
      "SelectFirst expects an expression, a criterion or property specification, and an optional default."
 where
  selectFirst subject criterion defaultValue =
    case parseSessionSelectionSpec "SelectFirst" criterion of
      P.Left message -> sessionFailure session message
      P.Right (selector, propertySpec) -> case sessionOrderedCollection subject of
        Nothing -> sessionFailure session "SelectFirst expects a nonatomic expression."
        Just collection ->
          findMatch
            selector
            defaultValue
            propertySpec
            (sessionCollectionItems collection)
            session

  findMatch _ defaultValue propertySpec [] currentSession =
    Right (projectSessionSelectFirst Nothing defaultValue propertySpec, currentSession)
  findMatch criterion defaultValue propertySpec (item : rest) currentSession = do
    (matches, updated) <-
      evaluateSessionPredicate depth currentSession criterion (sessionItemValue item)
    if matches
      then Right (projectSessionSelectFirst (Just item) defaultValue propertySpec, updated)
      else findMatch criterion defaultValue propertySpec rest updated

evaluateSessionTakeWhile
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTakeWhile depth session values = case values of
  [subject, criterion] -> case sessionOrderedCollection subject of
    Nothing -> sessionFailure session "TakeWhile expects a nonatomic expression."
    Just collection -> do
      (retained, updated) <- retainWhile criterion [] session (sessionCollectionItems collection)
      Right (rebuildSessionCollection collection retained, updated)
  _ -> sessionFailure session "TakeWhile expects exactly two arguments."
 where
  retainWhile _ retained currentSession [] = Right (retained, currentSession)
  retainWhile criterion retained currentSession (item : rest) = do
    (matches, updated) <-
      evaluateSessionPredicate depth currentSession criterion (sessionItemValue item)
    if matches
      then retainWhile criterion (retained <> [item]) updated rest
      else Right (retained, updated)

evaluateSessionLengthWhile
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionLengthWhile depth session values = case values of
  [subject, criterion] -> case sessionOrderedCollection subject of
    Nothing -> sessionFailure session "LengthWhile expects a nonatomic expression."
    Just collection -> do
      (count, updated) <- matchingLength criterion 0 session (sessionCollectionItems collection)
      Right (Integer count, updated)
  _ -> sessionFailure session "LengthWhile expects exactly two arguments."
 where
  matchingLength _ count currentSession [] = Right (count, currentSession)
  matchingLength criterion count currentSession (item : rest) = do
    (matches, updated) <-
      evaluateSessionPredicate depth currentSession criterion (sessionItemValue item)
    if matches
      then matchingLength criterion (count + 1) updated rest
      else Right (count, updated)

evaluateSessionKeySelect
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionKeySelect depth session values = case values of
  [association, criterion] -> case sessionOrderedCollection association of
    Just collection
      | sessionCollectionAssociation collection -> do
          (retained, updated) <- retainKeys criterion [] session (sessionCollectionItems collection)
          Right (rebuildSessionCollection collection retained, updated)
    _ -> sessionFailure session "KeySelect expects an Association."
  [_] -> Right (Call (Symbol "KeySelect") values, session)
  _ -> sessionFailure session "KeySelect expects an association and a criterion."
 where
  retainKeys _ retained currentSession [] = Right (retained, currentSession)
  retainKeys criterion retained currentSession (item : rest) = case sessionItemKey item of
    Nothing -> sessionFailure currentSession "KeySelect expects an Association."
    Just key -> do
      (matches, updated) <- evaluateSessionPredicate depth currentSession criterion key
      retainKeys criterion (if matches then retained <> [item] else retained) updated rest

sessionSelectionLimit :: Maybe Expr -> Maybe (Maybe Integer)
sessionSelectionLimit Nothing = Just Nothing
sessionSelectionLimit (Just (Symbol "Infinity")) = Just Nothing
sessionSelectionLimit (Just (Integer limit))
  | limit >= 0 = Just (Just limit)
sessionSelectionLimit _ = Nothing

evaluateSessionThrow
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionThrow depth session arguments' =
  case arguments' of
    [_] -> throwEvaluated
    [_, _] -> throwEvaluated
    [_, _, _] -> throwEvaluated
    _ -> Right (Call (Symbol "Throw") arguments', session)
 where
  throwEvaluated = do
    (evaluatedArguments, updated) <-
      evaluateArguments depth session arguments'
    case evaluatedArguments of
      [value] ->
        Left (SessionControl (Thrown value Nothing Nothing) updated)
      [value, tag] ->
        Left (SessionControl (Thrown value (Just tag) Nothing) updated)
      [value, tag, handler] ->
        Left (SessionControl (Thrown value (Just tag) (Just handler)) updated)
      _ -> Right (Call (Symbol "Throw") arguments', updated)

evaluateSessionAbort
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAbort session = \case
  []
    | activeCheckAbortHandlesCurrentAbort session ->
        Left (SessionControl Aborted session)
    | Just deferred <- deferAbortToCurrentProtect session ->
        Right (Symbol "Null", deferred)
    | otherwise -> Left (SessionControl Aborted session)
  _ -> sessionFailure session "Abort expects no arguments."

evaluateSessionCheckAbort
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCheckAbort depth session = \case
  [body, fallback] ->
    inspectRuntimeResult (evaluateSessionAt (depth + 1) scopedSession body) $ \case
      P.Left (SessionControl Aborted stoppedSession) ->
        evaluateSessionAt
          (depth + 1)
          (popCheckAbortScopes baselineDepth stoppedSession)
          fallback
      P.Left evaluationExit ->
        Left
          ( mapEvaluationExitSession
              (popCheckAbortScopes baselineDepth)
              evaluationExit
          )
      P.Right (value, stoppedSession) ->
        Right
          ( value
          , popCheckAbortScopes baselineDepth stoppedSession
          )
   where
    baselineDepth = length (sessionCheckAbortScopes session)
    scopedSession =
      session
        { sessionCheckAbortScopes =
            sessionCheckAbortScopes session
              <> [ CheckAbortScope
                     { checkAbortScopeProtectDepth =
                         length (sessionAbortProtectScopes session)
                     }
                 ]
        }
  _ -> sessionFailure session "CheckAbort expects exactly two arguments."

evaluateSessionAbortProtect
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAbortProtect depth session = \case
  [body] ->
    inspectRuntimeResult (evaluateSessionAt (depth + 1) scopedSession body) $ \case
      P.Left (SessionControl Aborted stoppedSession) ->
        Left
          ( SessionControl
              Aborted
              (popAbortProtectScopes baselineDepth stoppedSession)
          )
      P.Left evaluationExit ->
        Left
          ( mapEvaluationExitSession
              (popAbortProtectScopes baselineDepth)
              evaluationExit
          )
      P.Right (value, stoppedSession) ->
        let pending = abortProtectScopePendingAt baselineDepth stoppedSession
            restored = popAbortProtectScopes baselineDepth stoppedSession
         in if pending
              then Left (SessionControl Aborted restored)
              else Right (value, restored)
   where
    baselineDepth = length (sessionAbortProtectScopes session)
    scopedSession =
      session
        { sessionAbortProtectScopes =
            sessionAbortProtectScopes session
              <> [AbortProtectScope {abortProtectScopePending = False}]
        }
  _ -> sessionFailure session "AbortProtect expects exactly one argument."

activeCheckAbortHandlesCurrentAbort :: EvaluationSession -> Bool
activeCheckAbortHandlesCurrentAbort session =
  case reverse (sessionCheckAbortScopes session) of
    scope : _ ->
      checkAbortScopeProtectDepth scope
        == length (sessionAbortProtectScopes session)
    [] -> False

deferAbortToCurrentProtect :: EvaluationSession -> Maybe EvaluationSession
deferAbortToCurrentProtect session =
  case reverse (sessionAbortProtectScopes session) of
    scope : outerScopes ->
      Just
        session
          { sessionAbortProtectScopes =
              reverse
                ( scope {abortProtectScopePending = True}
                    : outerScopes
                )
          }
    [] -> Nothing

abortProtectScopePendingAt :: Int -> EvaluationSession -> Bool
abortProtectScopePendingAt baselineDepth session =
  case drop baselineDepth (sessionAbortProtectScopes session) of
    scope : _ -> abortProtectScopePending scope
    [] -> False

popAbortProtectScopes :: Int -> EvaluationSession -> EvaluationSession
popAbortProtectScopes baselineDepth session =
  session
    { sessionAbortProtectScopes =
        take baselineDepth (sessionAbortProtectScopes session)
    }

popCheckAbortScopes :: Int -> EvaluationSession -> EvaluationSession
popCheckAbortScopes baselineDepth session =
  session
    { sessionCheckAbortScopes =
        take baselineDepth (sessionCheckAbortScopes session)
    }

clearAbortScopes :: EvaluationSession -> EvaluationSession
clearAbortScopes session =
  session
    { sessionAbortProtectScopes = []
    , sessionCheckAbortScopes = []
    }

clearTimeConstraintScopes :: EvaluationSession -> EvaluationSession
clearTimeConstraintScopes session =
  session
    { sessionTimeConstraintScopes = []
    , sessionTimeConstraintSuppressionDepth = 0
    }

popTimeConstraintScopes :: Int -> EvaluationSession -> EvaluationSession
popTimeConstraintScopes baselineDepth session =
  session
    { sessionTimeConstraintScopes =
        take baselineDepth (sessionTimeConstraintScopes session)
    }

evaluateWithTimeConstraintSuppressed
  :: Int
  -> SessionResult value
  -> SessionResult value
evaluateWithTimeConstraintSuppressed baselineDepth result =
  inspectRuntimeResult result $ \case
    P.Left evaluationExit ->
      Left
        ( mapEvaluationExitSession restoreSuppressionDepth evaluationExit
        )
    P.Right (value, stoppedSession) ->
      Right (value, restoreSuppressionDepth stoppedSession)
 where
  restoreSuppressionDepth stoppedSession =
    stoppedSession
      { sessionTimeConstraintSuppressionDepth =
          baselineDepth
      }

evaluateSessionPause
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionPause depth session = \case
  [secondsExpression] -> do
    (secondsValue, updated) <-
      evaluateSessionAt (depth + 1) session secondsExpression
    case runtimeSecondsValue "Pause" False secondsValue of
      P.Left message -> sessionFailure updated message
      P.Right seconds
        | isInfinite seconds || isNaN seconds || seconds < 0 ->
            sessionFailure
              updated
              "Pause expects a non-negative finite number of seconds."
        | otherwise -> do
            start <- readSessionMonotonicTime
            pauseUntil updated (start + seconds)
  _ -> sessionFailure session "Pause expects exactly one argument."
 where
  pauseUntil currentSession endTime = do
    now <- readSessionMonotonicTime
    case effectiveTimeConstraintDeadline currentSession of
      Just deadline
        | now >= deadline ->
            Left (SessionControl TimeConstraintExpired currentSession)
      deadline ->
        let remainingPause = endTime - now
            remainingConstraint = maybe remainingPause (\value -> value - now) deadline
            sleepFor = min 0.05 (min remainingPause remainingConstraint)
         in if remainingPause <= 0
              then Right (Symbol "Null", currentSession)
              else do
                sleepSessionSeconds (max 0 sleepFor)
                pauseUntil currentSession endTime

evaluateSessionAbsoluteTiming
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAbsoluteTiming depth session = \case
  [body] -> do
    start <- readSessionMonotonicTime
    (value, updated) <- evaluateSessionAt (depth + 1) session body
    finished <- readSessionMonotonicTime
    Right
      ( evaluatedList
          [ Real (formatMachineReal (max 0 (finished - start)))
          , value
          ]
      , updated
      )
  _ ->
    sessionFailure
      session
      "AbsoluteTiming expects exactly one argument."

evaluateSessionTimeConstrained
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTimeConstrained depth session = \case
  [body, secondsExpression] ->
    begin body secondsExpression Nothing
  [body, secondsExpression, fallback] ->
    begin body secondsExpression (Just fallback)
  _ ->
    sessionFailure
      session
      "TimeConstrained expects two or three arguments."
 where
  begin body secondsExpression fallback = do
    (secondsValue, secondsSession) <-
      evaluateSessionAt (depth + 1) session secondsExpression
    case runtimeSecondsValue "TimeConstrained" True secondsValue of
      P.Left message -> sessionFailure secondsSession message
      P.Right rawSeconds ->
        let seconds
              | rawSeconds < 0 = 0
              | otherwise = rawSeconds
         in if isInfinite seconds
              then runBody body fallback secondsSession Nothing False
              else do
                now <- readSessionMonotonicTime
                runBody body fallback secondsSession (Just (now + seconds)) True

  runBody body fallback currentSession deadline checkOnCompletion =
    let baselineDepth = length (sessionTimeConstraintScopes currentSession)
        scopedSession =
          currentSession
            { sessionTimeConstraintScopes =
                sessionTimeConstraintScopes currentSession
                  <> [TimeConstraintScope deadline]
            }
        bodyResult = evaluateSessionAt (depth + 1) scopedSession body
        checkedResult =
          inspectRuntimeResult bodyResult $ \case
            P.Left evaluationExit -> Left evaluationExit
            P.Right success@(_, stoppedSession)
              | checkOnCompletion ->
                  checkSessionTimeConstraint stoppedSession (Right success)
            P.Right success -> Right success
     in finish baselineDepth fallback checkedResult

  finish baselineDepth fallback result =
    inspectRuntimeResult result $ \case
      P.Left (SessionControl TimeConstraintExpired stoppedSession) ->
        let restored = popTimeConstraintScopes baselineDepth stoppedSession
         in case fallback of
              Nothing -> Right (Symbol "$Aborted", restored)
              Just fallbackExpression ->
                evaluateSessionAt (depth + 1) restored fallbackExpression
      P.Left evaluationExit ->
        Left
          ( mapEvaluationExitSession
              (popTimeConstraintScopes baselineDepth)
              evaluationExit
          )
      P.Right (value, stoppedSession) ->
        Right (value, popTimeConstraintScopes baselineDepth stoppedSession)

evaluateSessionTimeRemaining
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTimeRemaining session = \case
  [] -> case effectiveTimeConstraintDeadline session of
    Nothing -> Right (Symbol "Infinity", session)
    Just deadline -> do
      now <- readSessionMonotonicTime
      Right
        ( Real (formatMachineReal (max 0 (deadline - now)))
        , session
        )
  _ -> sessionFailure session "TimeRemaining expects no arguments."

runtimeSecondsValue :: Text -> Bool -> Expr -> Either Text Double
runtimeSecondsValue functionName allowInfinity = \case
  Integer value -> P.Right (fromInteger value)
  Real source ->
    maybe
      (P.Left (functionName <> " expects a numeric time in seconds."))
      P.Right
      (parseRuntimeReal source)
  Symbol "Infinity"
    | allowInfinity -> P.Right (1 / 0)
  _ -> P.Left (functionName <> " expects a numeric time in seconds.")

parseRuntimeReal :: Text -> Maybe Double
parseRuntimeReal source =
  readMaybe (T.unpack normalized)
 where
  (literal, exponentMarker) = T.breakOn "*^" source
  mantissa = normalizeRuntimeMantissa (T.takeWhile (/= '`') literal)
  normalized
    | T.null exponentMarker = mantissa
    | otherwise = mantissa <> "e" <> T.drop 2 exponentMarker

normalizeRuntimeMantissa :: Text -> Text
normalizeRuntimeMantissa source
  | T.isPrefixOf "-." source = "-0" <> T.drop 1 source
  | T.isPrefixOf "+." source = "+0" <> T.drop 1 source
  | T.isPrefixOf "." source = "0" <> source
  | T.isSuffixOf "." source = source <> "0"
  | otherwise = source

evaluateSessionWithCleanup
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionWithCleanup depth session = \case
  [body, cleanup] -> evaluateBody session body cleanup
  [initializer, body, cleanup] ->
    inspectRuntimeResult (evaluateAbortProtected initializer session) $ \case
      P.Left (SessionControl controlSignal stoppedSession) ->
        evaluateCleanup (P.Left controlSignal) stoppedSession cleanup
      P.Left evaluationFailure -> Left evaluationFailure
      P.Right (_, initializedSession) ->
        inspectRuntimeResult
          ( checkSessionTimeConstraint
              initializedSession
              (Right (Symbol "Null", initializedSession))
          )
          $ \case
          P.Left (SessionControl controlSignal stoppedSession) ->
            evaluateCleanup (P.Left controlSignal) stoppedSession cleanup
          P.Left evaluationFailure -> Left evaluationFailure
          P.Right (_, checkedSession) ->
            evaluateBody checkedSession body cleanup
  _ -> sessionFailure session "WithCleanup expects two or three arguments."
 where
  evaluateBody currentSession body cleanup =
    inspectRuntimeResult
      (evaluateSessionAt (depth + 1) currentSession body)
      $ \case
      P.Left (SessionControl controlSignal stoppedSession) ->
        evaluateCleanup (P.Left controlSignal) stoppedSession cleanup
      P.Left evaluationFailure -> Left evaluationFailure
      P.Right (value, bodySession) ->
        evaluateCleanup (P.Right value) bodySession cleanup

  evaluateCleanup pending currentSession cleanup =
    inspectRuntimeResult (evaluateAbortProtected cleanup currentSession) $ \case
      P.Left cleanupExit -> Left cleanupExit
      P.Right (_, cleanedSession) ->
        case pending of
          P.Left controlSignal ->
            Left (SessionControl controlSignal cleanedSession)
          P.Right value -> Right (value, cleanedSession)

  evaluateAbortProtected expression currentSession =
    let baselineSuppressionDepth =
          sessionTimeConstraintSuppressionDepth currentSession
        suppressedSession =
          currentSession
            { sessionTimeConstraintSuppressionDepth =
                baselineSuppressionDepth + 1
            }
     in evaluateWithTimeConstraintSuppressed
          baselineSuppressionDepth
          (evaluateSessionAbortProtect depth suppressedSession [expression])

evaluateSessionReap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionReap depth session = \case
  [body] ->
    beginReap session body (Call (Symbol "Blank") []) Nothing
  [body, patternExpression] -> do
    (patternSpecification, updated) <-
      evaluateSessionAt (depth + 1) session patternExpression
    beginReap updated body patternSpecification Nothing
  [body, patternExpression, handlerExpression] -> do
    (patternSpecification, patternSession) <-
      evaluateSessionAt (depth + 1) session patternExpression
    (handler, updated) <-
      evaluateSessionAt (depth + 1) patternSession handlerExpression
    beginReap updated body patternSpecification (Just handler)
  _ -> sessionFailure session "Reap expects one, two, or three arguments."
 where
  beginReap currentSession body patternSpecification handler =
    inspectRuntimeResult (evaluateSessionAt (depth + 1) scopedSession body) $ \case
      P.Left evaluationExit ->
        Left
          ( mapEvaluationExitSession
              (popReapScopes baselineDepth)
              evaluationExit
          )
      P.Right (value, stoppedSession) ->
        let restored = popReapScopes baselineDepth stoppedSession
         in case reapScopeAt baselineDepth stoppedSession of
              Nothing ->
                sessionFailure restored "Reap lost its active collection scope."
              Just completedScope ->
                finishReapScope depth handler value completedScope restored
   where
    (patternListMode, patterns) = reapPatterns patternSpecification
    baselineDepth = length (sessionReapScopes currentSession)
    scopedSession =
      currentSession
        { sessionReapScopes =
            sessionReapScopes currentSession
              <> [ ReapScope
                     { reapScopePatterns = patterns
                     , reapScopePatternListMode = patternListMode
                     , reapScopeBuckets = replicate (length patterns) []
                     }
                 ]
        }

evaluateSessionSow
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSow depth session = \case
  [valueExpression] -> do
    (value, updated) <-
      evaluateSessionAt (depth + 1) session valueExpression
    sowTags value [Symbol "None"] updated
  [valueExpression, tagExpression] -> do
    (value, valueSession) <-
      evaluateSessionAt (depth + 1) session valueExpression
    (tagSpecification, updated) <-
      evaluateSessionAt (depth + 1) valueSession tagExpression
    sowTags value (normalizedSowTags tagSpecification) updated
  _ -> sessionFailure session "Sow expects one or two arguments."
 where
  sowTags value tags currentSession = do
    (_, updated) <- sowEachTag currentSession tags
    Right (value, updated)
   where
    sowEachTag current [] = Right ((), current)
    sowEachTag current (tag : rest) = do
      (_, taggedSession) <- routeSownValue depth current value tag
      sowEachTag taggedSession rest

evaluateSessionFailsafe
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFailsafe depth session arguments'
  | length arguments' `elem` [1, 2, 3] = do
      (evaluatedArguments, updated) <-
        evaluateArguments depth session arguments'
      Right (Call (Symbol "Failsafe") evaluatedArguments, updated)
  | otherwise =
      sessionFailure session "Failsafe expects one, two, or three arguments."

evaluateSessionFailsafeApply
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFailsafeApply depth session failsafeArguments callArguments =
  case failsafeArguments of
    [function] ->
      case firstSessionFailureValue callArguments of
        Just failure -> Right (failure, session)
        Nothing ->
          evaluateSessionCallable depth session function callArguments
    [function, test] -> do
      (testResult, testedSession) <-
        evaluateSessionCallable depth session test callArguments
      if testResult == Symbol "True"
        then
          evaluateSessionCallable
            depth
            testedSession
            function
            callArguments
        else
          Right
            ( sessionFailureExpr
                "FailsafeFailed"
                [ ( "Arguments"
                  , Call (Symbol "Hold") callArguments
                  )
                ]
            , testedSession
            )
    [function, test, failureFunction] -> do
      (testResult, testedSession) <-
        evaluateSessionCallable depth session test callArguments
      evaluateSessionCallable
        depth
        testedSession
        (if testResult == Symbol "True" then function else failureFunction)
        callArguments
    _ ->
      sessionFailure session "Failsafe expects one, two, or three arguments."

firstSessionFailureValue :: [Expr] -> Maybe Expr
firstSessionFailureValue [] = Nothing
firstSessionFailureValue (value : rest)
  | isSessionFailsafeFailureValue value = Just value
  | otherwise = firstSessionFailureValue rest

isSessionFailsafeFailureValue :: Expr -> Bool
isSessionFailsafeFailureValue expression =
  isSessionFailureValue expression
    || isSessionMissingValue expression
    || expression
      `elem` [Symbol "$Failed", Symbol "$Canceled", Symbol "$Aborted"]

isSessionFailureValue :: Expr -> Bool
isSessionFailureValue = \case
  Call (Symbol failureHead) _ ->
    isSessionSystemHead "Failure" failureHead
  _ -> False

isSessionMissingValue :: Expr -> Bool
isSessionMissingValue = \case
  Call (Symbol missingHead) _ ->
    isSessionSystemHead "Missing" missingHead
  _ -> False

sessionFailureExpr :: Text -> [(Text, Expr)] -> Expr
sessionFailureExpr failureType fields =
  Call
    (Symbol "Failure")
    [ Symbol failureType
    , normalizedSessionAssociation
        [ Call (Symbol "Rule") [String name, value]
        | (name, value) <- fields
        ]
    ]

reapPatterns :: Expr -> (Bool, [Expr])
reapPatterns = \case
  Call (Symbol listHead) patterns
    | isSessionSystemHead "List" listHead -> (True, patterns)
  patternExpression -> (False, [patternExpression])

normalizedSowTags :: Expr -> [Expr]
normalizedSowTags = \case
  Call (Symbol listHead) tags
    | isSessionSystemHead "List" listHead -> tags
  tag -> [tag]

routeSownValue
  :: Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult ()
routeSownValue depth session value tag =
  search (length (sessionReapScopes session) - 1) session
 where
  search index currentSession
    | index < 0 = Right ((), currentSession)
    | otherwise =
        case reapScopeAt index currentSession of
          Nothing -> search (index - 1) currentSession
          Just scope -> do
            (matchingIndices, matchedSession) <-
              matchingReapPatternIndices
                depth
                currentSession
                tag
                (reapScopePatterns scope)
            if null matchingIndices
              then search (index - 1) matchedSession
              else
                case updateReapScopeAt
                  index
                  (appendSownValue matchingIndices tag value)
                  matchedSession of
                    Nothing ->
                      sessionFailure
                        matchedSession
                        "Sow lost its matching Reap scope."
                    Just updated -> Right ((), updated)

matchingReapPatternIndices
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult [Int]
matchingReapPatternIndices depth = go 0 []
 where
  go _ retained session _ [] = Right (reverse retained, session)
  go index retained session tag (patternExpression : rest) = do
    (matched, updated) <-
      sessionPatternMatches depth session tag patternExpression
    go
      (index + 1)
      (if matched then index : retained else retained)
      updated
      tag
      rest

appendSownValue :: [Int] -> Expr -> Expr -> ReapScope -> ReapScope
appendSownValue matchingIndices tag value scope =
  scope
    { reapScopeBuckets =
        zipWith append [0 ..] (reapScopeBuckets scope)
    }
 where
  append index bucket
    | index `elem` matchingIndices = appendReapTagGroup tag value bucket
    | otherwise = bucket

appendReapTagGroup :: Expr -> Expr -> [ReapTagGroup] -> [ReapTagGroup]
appendReapTagGroup tag value = \case
  [] -> [ReapTagGroup tag [value]]
  group : rest
    | reapTagGroupTag group == tag ->
        group {reapTagGroupValues = reapTagGroupValues group <> [value]}
          : rest
    | otherwise -> group : appendReapTagGroup tag value rest

finishReapScope
  :: Int
  -> Maybe Expr
  -> Expr
  -> ReapScope
  -> EvaluationSession
  -> SessionResult Expr
finishReapScope depth handler value scope session = do
  (bucketResults, updated) <-
    evaluateReapBuckets
      depth
      handler
      (reapScopePatternListMode scope)
      session
      (reapScopeBuckets scope)
  Right
    ( evaluatedList [value, evaluatedList bucketResults]
    , updated
    )

evaluateReapBuckets
  :: Int
  -> Maybe Expr
  -> Bool
  -> EvaluationSession
  -> [[ReapTagGroup]]
  -> SessionResult [Expr]
evaluateReapBuckets depth handler patternListMode = go []
 where
  go retained session [] = Right (retained, session)
  go retained session (bucket : rest) = do
    (groups, groupSession) <-
      evaluateReapTagGroups depth handler session bucket
    go
      ( if patternListMode
          then retained <> [evaluatedList groups]
          else retained <> groups
      )
      groupSession
      rest

evaluateReapTagGroups
  :: Int
  -> Maybe Expr
  -> EvaluationSession
  -> [ReapTagGroup]
  -> SessionResult [Expr]
evaluateReapTagGroups depth handler = go []
 where
  go retained session [] = Right (retained, session)
  go retained session (group : rest) = do
    let values = evaluatedList (reapTagGroupValues group)
    (result, updated) <- case handler of
      Nothing -> Right (values, session)
      Just function ->
        evaluateSessionCallable
          depth
          session
          function
          [reapTagGroupTag group, values]
    go (retained <> [result]) updated rest

reapScopeAt :: Int -> EvaluationSession -> Maybe ReapScope
reapScopeAt index session =
  case drop index (sessionReapScopes session) of
    scope : _ -> Just scope
    [] -> Nothing

updateReapScopeAt
  :: Int
  -> (ReapScope -> ReapScope)
  -> EvaluationSession
  -> Maybe EvaluationSession
updateReapScopeAt index update session =
  case splitAt index (sessionReapScopes session) of
    (before, scope : after) ->
      Just
        session
          { sessionReapScopes = before <> (update scope : after)
          }
    _ -> Nothing

popReapScopes :: Int -> EvaluationSession -> EvaluationSession
popReapScopes baselineDepth session =
  session
    { sessionReapScopes =
        take baselineDepth (sessionReapScopes session)
    }

evaluateSessionReturn
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionReturn depth session = \case
  [] -> Left (SessionControl (Returned (Symbol "Null") Nothing) session)
  [valueExpression] -> do
    (value, updated) <-
      evaluateSessionAt (depth + 1) session valueExpression
    Left (SessionControl (Returned value Nothing) updated)
  arguments'@[valueExpression, headExpression] -> do
    (evaluatedHead, headSession) <-
      evaluateSessionAt (depth + 1) session headExpression
    case evaluatedHead of
      Symbol headName -> do
        (value, updated) <-
          evaluateSessionAt (depth + 1) headSession valueExpression
        Left (SessionControl (Returned value (Just headName)) updated)
      _ -> Right (Call (Symbol "Return") arguments', headSession)
  arguments' -> Right (Call (Symbol "Return") arguments', session)

evaluateLoopControl
  :: ControlSignal
  -> Text
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateLoopControl controlSignal headName session = \case
  [] -> Left (SessionControl controlSignal session)
  arguments' -> Right (Call (Symbol headName) arguments', session)

evaluateSessionValueQ
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionValueQ depth session = \case
  [Symbol name] ->
    let updated = registerSymbol name session
     in Right
          ( sessionBoolean
              ( isImplicitContextValue name updated
                  || case symbolOwnValueFor name updated of
                    Just _ -> True
                    Nothing -> False
              )
          , updated
          )
  [expression] -> do
    (evaluated, updated) <-
      evaluateSessionAt (depth + 1) session expression
    Right (sessionBoolean (evaluated /= expression), updated)
  _ -> sessionFailure session "ValueQ expects exactly one argument."

isImplicitContextValue :: Text -> EvaluationSession -> Bool
isImplicitContextValue name session =
  resolvedSymbolStorageName name session
    `elem` ["$Context", "$ContextPath"]

evaluateSessionSymbol
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSymbol session = \case
  [String name] ->
    case resolvedSessionSymbolFullName name session of
      Just fullName ->
        Right
          ( Symbol (displaySessionSymbolName fullName)
          , registerSymbol fullName session
          )
      Nothing -> sessionFailure session (invalidSessionSymbolNameMessage name)
  [_] -> sessionFailure session "Symbol expects a string symbol name."
  _ -> sessionFailure session "Symbol expects exactly one string argument."

evaluateSessionSymbolName
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSymbolName session = \case
  [Symbol name] ->
    case resolvedSessionSymbolFullName name session of
      Just fullName
        | Just (_, shortName) <- splitSessionSymbolFullName fullName ->
            Right (String shortName, registerSymbol fullName session)
      _ -> sessionFailure session "SymbolName expects a symbol or an existing symbol name."
  [String name] ->
    case existingSessionSymbolFullName name session of
      Just fullName
        | Just (_, shortName) <- splitSessionSymbolFullName fullName ->
            Right (String shortName, session)
      _ ->
        case splitSessionSymbolFullName name of
          Just (_, shortName)
            | validSessionSymbolShortName shortName ->
                Right (String shortName, session)
          _ -> sessionFailure session "SymbolName expects a symbol or an existing symbol name."
  [_] -> sessionFailure session "SymbolName expects a symbol or an existing symbol name."
  _ -> sessionFailure session "SymbolName expects exactly one argument."

evaluateSessionUnique
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionUnique session = \case
  [] -> allocateSessionCounterUnique currentSessionContext "$" session
  [Call (Symbol listHead) specifications]
    | isSessionSystemHead "List" listHead ->
        allocateList [] session specifications
  [specification] -> allocateSessionUniqueItem session specification
  _ ->
    sessionFailure
      session
      "Unique currently expects zero arguments or one symbol, string, or list argument."
 where
  allocateList retained current [] =
    Right (evaluatedList (reverse retained), current)
  allocateList retained current (specification : rest) = do
    (generated, updated) <-
      allocateSessionUniqueItem current specification
    allocateList (generated : retained) updated rest

evaluateSessionEvaluate
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionEvaluate depth session = \case
  [Call (Symbol unevaluatedHead) [payload]]
    | isSessionSystemHead "Unevaluated" unevaluatedHead ->
        evaluateSessionAt (depth + 1) session payload
  [payload] -> evaluateSessionAt (depth + 1) session payload
  _ -> sessionFailure session "Evaluate expects exactly one argument."

allocateSessionUniqueItem
  :: EvaluationSession
  -> Expr
  -> SessionResult Expr
allocateSessionUniqueItem session = \case
  Symbol name ->
    case resolvedSessionSymbolFullName name session of
      Just fullName
        | Just (context, shortName) <- splitSessionSymbolFullName fullName ->
            allocateSessionCounterUnique
              context
              (shortName <> "$")
              (registerSymbol fullName session)
      _ -> sessionFailure session (invalidSessionSymbolNameMessage name)
  String prefix
    | validSessionSymbolShortName (prefix <> "1") ->
        allocateStringPrefix 1
    | otherwise ->
        sessionFailure
          session
          "Unique expects a valid symbol or symbol-name prefix."
   where
    allocateStringPrefix :: Integer -> SessionResult Expr
    allocateStringPrefix index =
      let fullName =
            currentSessionContext
              <> prefix
              <> T.pack (show index)
       in if isKnownSessionFullName fullName session
            then allocateStringPrefix (index + 1)
            else
              Right
                ( Symbol (displaySessionSymbolName fullName)
                , registerSymbol fullName session
                )
  _ ->
    sessionFailure
      session
      "Unique expects no argument, a symbol, a string prefix, or a list of those forms."

allocateSessionCounterUnique
  :: Text
  -> Text
  -> EvaluationSession
  -> SessionResult Expr
allocateSessionCounterUnique context prefix session =
  let nextCounter = sessionModuleCounter session + 1
      fullName = context <> prefix <> T.pack (show nextCounter)
      allocated = session {sessionModuleCounter = nextCounter}
   in if validSessionSymbolName fullName
        then
          Right
            ( Symbol (displaySessionSymbolName fullName)
            , registerSymbol fullName allocated
            )
        else
          sessionFailure
            allocated
            (invalidSessionSymbolNameMessage fullName)

evaluateSessionNames
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionNames session = \case
  [] -> namesForPatterns ["*"]
  [specification] ->
    case sessionNamePatterns specification of
      Just patterns -> namesForPatterns patterns
      Nothing ->
        sessionFailure
          session
          "Names expects a string pattern or a list of string patterns."
  _ ->
    sessionFailure
      session
      "Names expects zero arguments or one string pattern/list of string patterns."
 where
  namesForPatterns patterns =
    Right
      ( evaluatedList
          (map String (matchingSessionDisplayNames patterns session))
      , session
      )

evaluateSessionNameQ
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionNameQ session = \case
  [specification] ->
    case sessionNamePatterns specification of
      Just patterns ->
        Right
          ( sessionBoolean
              (not (null (matchingSessionDisplayNames patterns session)))
          , session
          )
      Nothing ->
        sessionFailure
          session
          "Names expects a string pattern or a list of string patterns."
  _ -> sessionFailure session "NameQ expects exactly one string pattern."

evaluateSessionContexts
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionContexts session = \case
  [] -> contextsMatching (const True)
  [String patternText] ->
    contextsMatching (wildcardSymbolNameMatches patternText)
  [_] -> sessionFailure session "Contexts expects an optional string pattern."
  _ ->
    sessionFailure
      session
      "Contexts expects zero arguments or one string pattern."
 where
  contextsMatching predicate =
    Right
      ( evaluatedList
          [ String context
          | context <- knownSessionContexts session
          , predicate context
          ]
      , session
      )

evaluateSessionContext
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionContext session = \case
  [] -> Right (String currentSessionContext, session)
  [Symbol name] -> case registerResolvedSymbol name of
    Just resolved ->
      contextForFullName
        (Just resolved)
        "Context expects zero arguments, a symbol, or an existing symbol name."
    Nothing -> sessionFailure session (invalidSessionSymbolNameMessage name)
  [String name] ->
    case existingSessionSymbolFullName name session of
      Nothing ->
        sessionFailure
          session
          ( "Context could not find a symbol named "
              <> pythonReprName name
              <> "."
          )
      Just fullName ->
        contextForFullName
          (Just (fullName, session))
          "Context expects zero arguments, a symbol, or an existing symbol name."
  [_] ->
    sessionFailure
      session
      "Context expects zero arguments, a symbol, or an existing symbol name."
  _ ->
    sessionFailure
      session
      "Context expects zero arguments or one symbol/name argument."
 where
  registerResolvedSymbol name = do
    fullName <- resolvedSessionSymbolFullName name session
    pure (fullName, registerSymbol fullName session)

  contextForFullName resolved errorMessage = case resolved of
    Just (fullName, updated)
      | Just (context, _) <- splitSessionSymbolFullName fullName ->
          Right (String context, updated)
    _ -> sessionFailure session errorMessage

evaluateSessionOwnValues
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOwnValues session = \case
  [Symbol name] -> ownValuesFor name (registerSymbol name session)
  [String name]
    | isKnownSessionSymbol name session -> ownValuesFor name session
    | otherwise ->
        sessionFailure
          session
          ("OwnValues could not find a symbol named '" <> name <> "'.")
  [_] ->
    sessionFailure
      session
      "OwnValues expects a symbol or the name of an existing symbol."
  _ ->
    sessionFailure
      session
      "OwnValues expects exactly one symbol or symbol-name string."
 where
  ownValuesFor name updated =
    let displayedSymbol = Symbol (displaySessionSymbolName name)
        rules = case symbolOwnValueFor name updated of
          Nothing -> []
          Just (ImmediateValue value) -> [ownValueRule displayedSymbol value]
          Just (DelayedValue value) -> [ownValueRule displayedSymbol value]
     in Right (evaluatedList rules, updated)

  ownValueRule symbol value =
    Call
      (Symbol "RuleDelayed")
      [Call (Symbol "HoldPattern") [symbol], value]

evaluateSessionDefinitionValues
  :: Text
  -> (SymbolValues -> [DownValue])
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionDefinitionValues headName selectDefinitions session = \case
  [Symbol name] -> valuesFor name (registerSymbol name session)
  [String name]
    | isKnownSessionSymbol name session -> valuesFor name session
    | otherwise -> Right (evaluatedList [], session)
  [_] ->
    sessionFailure
      session
      (headName <> " expects a symbol or the name of an existing symbol.")
  _ ->
    sessionFailure
      session
      (headName <> " expects exactly one symbol.")
 where
  valuesFor name updated =
    Right
      ( evaluatedList
          (map definitionRule (selectDefinitions (symbolValuesFor name updated)))
      , updated
      )

  definitionRule definition =
    Call
      (Symbol "RuleDelayed")
      [ Call (Symbol "HoldPattern") [downValuePattern definition]
      , downValueBody definition
      ]

evaluateSessionAttributes
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAttributes depth session = \case
  [target] -> attributesForTarget session target
  _ ->
    sessionFailure
      session
      "Attributes expects a symbol, string symbol name, or list of symbols/names."
 where
  attributesForTarget current = \case
    Call (Symbol evaluateHead) [payload]
      | isSessionSystemHead "Evaluate" evaluateHead -> do
          (evaluated, updated) <-
            evaluateSessionAt (depth + 1) current payload
          attributesForTarget updated evaluated
    Call (Symbol listHead) values
      | isSessionSystemHead "List" listHead -> do
          (results, updated) <- attributesForTargets current values
          Right (evaluatedList results, updated)
    Symbol name ->
      Right
        ( attributeList (symbolAttributesFor name current)
        , registerSymbol name current
        )
    String name
      | isKnownSessionSymbol name current ->
          Right (attributeList (symbolAttributesFor name current), current)
      | otherwise ->
          Right
            ( Call (Symbol "Attributes") [String name]
            , appendNamedMessage
                "Attributes"
                "notfound"
                ("Symbol " <> name <> " not found.")
                current
            )
    invalid ->
      sessionFailure
        current
        ( "Attributes expects a symbol, string symbol name, or list of symbols/names; got "
            <> inputForm invalid
            <> "."
        )

  attributesForTargets current [] = Right ([], current)
  attributesForTargets current (target : rest) = do
    (result, updated) <- attributesForTarget current target
    (remaining, completed) <- attributesForTargets updated rest
    Right (result : remaining, completed)

attributeList :: Set.Set SymbolAttribute -> Expr
attributeList attributes =
  evaluatedList
    [ Symbol (symbolAttributeName attribute)
    | attribute <- Set.toAscList attributes
    ]

evaluateSessionSetAttributes
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSetAttributes addMode _depth session = \case
  [targetsExpression, attributesExpression] ->
    let (targets, targetSession) =
          attributeTargets operation targetsExpression session
        (attributes, parsedSession) =
          parseAttributeSpecification attributesExpression targetSession
     in case (targets, attributes) of
      (Just names, Just requested) ->
        Right
          ( Symbol "Null"
          , foldl (updateAttributes requested) parsedSession names
          )
      _ -> Right (Symbol "Null", parsedSession)
  _ ->
    sessionFailure
      session
      ( operation
          <> " expects a symbol or list of symbols and an attribute specification."
      )
 where
  operation = if addMode then "SetAttributes" else "ClearAttributes"
  updateAttributes requested current name
    | symbolHasAttribute name Locked current =
        appendSymbolMessage "Attributes" "locked" name "is locked." current
    | otherwise =
        let existing = symbolAttributesFor name current
            updated =
              if addMode
                then Set.union existing requested
                else Set.difference existing requested
         in setSymbolAttributes name updated current

evaluateSessionAttributesAssignment
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> Expr
  -> SessionResult Expr
evaluateSessionAttributesAssignment depth session targets rhs = do
  (value, valueSession) <- evaluateSessionAt (depth + 1) session rhs
  case targets of
    [target] ->
      let (names, targetSession) =
            attributeAssignmentTarget "Attributes" target valueSession
          (attributes, parsedSession) =
            parseAttributeSpecification value targetSession
       in case (names, attributes) of
            (Just [name], Just requested)
              | symbolHasAttribute name Locked parsedSession ->
                  Right
                    ( value
                    , appendSymbolMessage
                        "Attributes"
                        "locked"
                        name
                        "is locked."
                        parsedSession
                    )
              | otherwise ->
                  Right (value, setSymbolAttributes name requested parsedSession)
            _ -> Right (value, parsedSession)
    _ ->
      sessionFailure
        valueSession
        "Attributes assignment expects exactly one target symbol."

attributeAssignmentTarget
  :: Text
  -> Expr
  -> EvaluationSession
  -> (Maybe [Text], EvaluationSession)
attributeAssignmentTarget operation expression session = case expression of
  Symbol name -> (Just [name], registerSymbol name session)
  String name
    | isKnownSessionSymbol name session -> (Just [name], session)
  invalid ->
    ( Nothing
    , appendNamedMessage
        operation
        "sym"
        ("Argument " <> inputForm invalid <> " is expected to be a symbol.")
        session
    )

attributeTargets
  :: Text
  -> Expr
  -> EvaluationSession
  -> (Maybe [Text], EvaluationSession)
attributeTargets operation expression session = case expression of
  Call (Symbol listHead) values
    | isSessionSystemHead "List" listHead -> collect session values
  Symbol name -> (Just [name], registerSymbol name session)
  String name
    | isKnownSessionSymbol name session -> (Just [name], session)
  invalid ->
    ( Nothing
    , appendNamedMessage
        operation
        "sym"
        ("Argument " <> inputForm invalid <> " is expected to be a symbol.")
        session
    )
 where
  collect current [] = (Just [], current)
  collect current (value : rest) =
    let (firstNames, firstSession) = attributeTargets operation value current
     in case firstNames of
          Nothing -> (Nothing, firstSession)
          Just first ->
            let (remainingNames, updated) = collect firstSession rest
             in case remainingNames of
                  Just remaining -> (Just (first <> remaining), updated)
                  Nothing -> (Nothing, updated)

parseAttributeSpecification
  :: Expr
  -> EvaluationSession
  -> (Maybe (Set.Set SymbolAttribute), EvaluationSession)
parseAttributeSpecification expression session =
  case rawNames expression of
    Nothing -> invalid expression session
    Just names -> parseNames Set.empty session names
 where
  rawNames (Symbol name) = Just [name]
  rawNames (Call (Symbol listHead) values)
    | isSessionSystemHead "List" listHead = traverse symbolName values
  rawNames _ = Nothing

  parseNames retained current [] = (Just retained, current)
  parseNames retained current (name : rest) =
    case symbolAttributeFromName (systemAttributeSymbolName name) of
      Just attribute -> parseNames (Set.insert attribute retained) current rest
      Nothing -> invalid (Symbol name) current

  invalid value current =
    ( Nothing
    , appendNamedMessage
        "Attributes"
        "attnf"
        (inputForm value <> " is not a known attribute.")
        current
    )

evaluateSessionProtect
  :: Bool
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionProtect protectMode session targets =
  let (names, targetSession) =
        sessionSymbolTargets operation targets session
      (changed, updated) = foldl update ([], targetSession) names
   in Right (evaluatedList (map String changed), updated)
 where
  operation = if protectMode then "Protect" else "Unprotect"
  update (changed, current) name
    | symbolHasAttribute name Locked current =
        ( changed
        , appendSymbolMessage "Protect" "locked" name "is locked." current
        )
    | otherwise =
        let attributes = symbolAttributesFor name current
            wasProtected = Set.member Protected attributes
            shouldChange = wasProtected /= protectMode
            updatedAttributes =
              if protectMode
                then Set.insert Protected attributes
                else Set.delete Protected attributes
            updated =
              if shouldChange
                then setSymbolAttributes name updatedAttributes current
                else current
         in ( if shouldChange
                then changed <> [displaySessionSymbolName name]
                else changed
            , updated
            )

evaluateSessionClear
  :: Bool
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionClear clearAttributesMode session targets =
  if clearAttributesMode
    then
      let (names, targetSession) =
            sessionSymbolTargets "ClearAll" targets session
          updated = foldl (clearOne "ClearAll") targetSession names
       in Right (Symbol "Null", updated)
    else
      Right
        ( Symbol "Null"
        , foldl clearTarget session targets
        )
 where
  clearTarget current = \case
    Symbol name -> clearOne "Clear" (registerSymbol name current) name
    Call (Symbol listHead) values
      | isSessionSystemHead "List" listHead ->
          foldl clearTarget current values
    String patternText ->
      foldl
        (clearOne "Clear")
        current
        (matchingSessionSymbolNames patternText current)
    invalid ->
      appendNamedMessage
        "Clear"
        "ssym"
        ( inputForm invalid
            <> " is not a symbol or a valid string pattern."
        )
        current

  clearOne operation current name
    | Just _ <- specialSessionSettingName name =
        appendSymbolMessage
          operation
          "spsym"
          name
          "is a special system symbol."
          current
    | clearAttributesMode
    , symbolHasAttribute name Locked current =
        appendSymbolMessage operation "locked" name "is locked." current
    | symbolHasAttribute name Protected current
    , clearAttributesMode || not (isProtectedValueHook name current) =
        appendSymbolMessage operation "wrsym" name "is Protected." current
    | clearAttributesMode =
        setSymbolAttributes
          name
          Set.empty
          (setSymbolValues name emptySymbolValues current)
    | otherwise = setSymbolValues name emptySymbolValues current

sessionSymbolTargets
  :: Text
  -> [Expr]
  -> EvaluationSession
  -> ([Text], EvaluationSession)
sessionSymbolTargets operation targets initialSession = go [] initialSession targets
 where
  go retained current [] = (retained, current)
  go retained current (target : rest) = case target of
    Symbol name ->
      go (retained <> [name]) (registerSymbol name current) rest
    Call (Symbol listHead) values
      | isSessionSystemHead "List" listHead ->
          let (nested, nestedSession) = go [] current values
           in go (retained <> nested) nestedSession rest
    String patternText ->
      go
        (retained <> matchingSessionSymbolNames patternText current)
        current
        rest
    invalid ->
      go
        retained
        ( appendNamedMessage
            operation
            "ssym"
            ( inputForm invalid
                <> " is not a symbol or a valid string pattern."
            )
            current
        )
        rest

matchingSessionSymbolNames :: Text -> EvaluationSession -> [Text]
matchingSessionSymbolNames patternText session =
  [ name
  | name <- allNames
  , Just candidate <- [patternCandidate name]
  , wildcardSymbolNameMatches patternText candidate
  ]
 where
  allNames =
    Set.toAscList
      (Set.fromList systemSymbolNames `Set.union` Map.keysSet (sessionSymbols session))
  patternCandidate name
    | "`" `T.isInfixOf` patternText
    , "`" `T.isInfixOf` name = Just name
    | "`" `T.isInfixOf` patternText
    , isSystemSymbol name = Just ("System`" <> name)
    | "`" `T.isInfixOf` patternText = Just ("Global`" <> name)
    | Just shortName <- T.stripPrefix "System`" name = Just shortName
    | "`" `T.isInfixOf` name = Nothing
    | Map.member ("System`" <> name) (sessionSymbols session) = Nothing
    | otherwise = Just name

wildcardSymbolNameMatches :: Text -> Text -> Bool
wildcardSymbolNameMatches patternText candidate =
  match (T.unpack patternText) (T.unpack candidate)
 where
  match [] [] = True
  match [] _ = False
  match ('\\' : escaped : rest) (character : remaining)
    | escaped == character = match rest remaining
  match ('*' : rest) remaining =
    match rest remaining
      || case remaining of
        [] -> False
        _ : suffix -> match ('*' : rest) suffix
  match ('@' : rest) remaining =
    let prefix = takeWhile (not . isUpperAscii) remaining
     in not (null prefix)
          && any (\count -> match rest (drop count remaining)) [1 .. length prefix]
  match (expected : rest) (actual : remaining)
    | expected == actual = match rest remaining
  match _ _ = False
  isUpperAscii character = 'A' <= character && character <= 'Z'

evaluateDownValueAssignment
  :: Bool
  -> Int
  -> EvaluationSession
  -> Expr
  -> Expr
  -> SessionResult Expr
evaluateDownValueAssignment delayed depth session lhs rhs
  | delayed = do
      (normalizedLhs, normalizedSession) <-
        normalizeAssignmentLhs depth session lhs
      store normalizedSession normalizedLhs rhs
  | otherwise = do
      (value, valueSession) <- evaluateSessionAt (depth + 1) session rhs
      (normalizedLhs, normalizedSession) <-
        normalizeAssignmentLhs depth valueSession lhs
      store normalizedSession normalizedLhs value
 where
  store updated normalizedLhs storedBody =
    case compoundValueOwner normalizedLhs of
      Just (slot, owner)
        | symbolAllowsValueMutation owner updated ->
            let definition = DownValue normalizedLhs storedBody delayed
                result = if delayed then Symbol "Null" else storedBody
             in Right
                  ( result
                  , defineCompoundValue slot owner definition updated
                  )
      Just (_, owner) ->
        let assignmentHead = if delayed then "SetDelayed" else "Set"
            result =
              if delayed
                then Symbol "Null"
                else Call (Symbol assignmentHead) [normalizedLhs, storedBody]
         in Right
              ( result
              , appendSymbolMessage
                  assignmentHead
                  "wrsym"
                  owner
                  "is Protected."
                  updated
              )
      _ ->
        let assignmentHead = if delayed then "SetDelayed" else "Set"
         in sessionFailure
              updated
              ( assignmentHead
                  <> " does not support this left-hand side in Tungsten yet."
              )

evaluateSessionTagSet
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTagSet delayed depth session = \case
  [Symbol tag, lhs, rhs]
    | delayed -> do
        let taggedSession = registerSymbol tag session
        (normalizedLhs, normalizedSession) <-
          normalizeAssignmentLhs depth taggedSession lhs
        store normalizedSession tag normalizedLhs rhs
    | otherwise -> do
        let taggedSession = registerSymbol tag session
        (value, valueSession) <-
          evaluateSessionAt (depth + 1) taggedSession rhs
        (normalizedLhs, normalizedSession) <-
          normalizeAssignmentLhs depth valueSession lhs
        store normalizedSession tag normalizedLhs value
  [_, _, _] ->
    sessionFailure session (operation <> " expects a symbol tag.")
  _ ->
    sessionFailure
      session
      (operation <> " expects a tag, left-hand side, and right-hand side.")
 where
  operation = if delayed then "TagSetDelayed" else "TagSet"

  store current tag normalizedLhs storedBody =
    case taggedAssignmentTarget current tag normalizedLhs of
      Nothing ->
        Right
          ( failedAssignment tag normalizedLhs storedBody
          , appendTagPositionMessage operation tag normalizedLhs current
          )
      Just target
        | not (symbolAllowsValueMutation tag current) ->
            Right
              ( failedAssignment tag normalizedLhs storedBody
              , appendSymbolMessage
                  operation
                  "wrsym"
                  tag
                  "is Protected."
                  current
              )
        | otherwise ->
            let updated = case target of
                  TaggedOwnValue _ ->
                    define
                      tag
                      (if delayed then DelayedValue storedBody else ImmediateValue storedBody)
                      current
                  TaggedCompoundValue slot _ ->
                    defineCompoundValue
                      slot
                      tag
                      (DownValue normalizedLhs storedBody delayed)
                      current
             in Right
                  ( if delayed then Symbol "Null" else storedBody
                  , updated
                  )

  failedAssignment tag normalizedLhs storedBody
    | delayed = Symbol "Null"
    | otherwise =
        Call
          (Symbol operation)
          [Symbol tag, normalizedLhs, storedBody]

evaluateSessionTagUnset
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTagUnset depth session = \case
  [Symbol tag, lhs] -> do
    let taggedSession = registerSymbol tag session
    (normalizedLhs, normalizedSession) <-
      normalizeAssignmentLhs depth taggedSession lhs
    case taggedAssignmentTarget normalizedSession tag normalizedLhs of
      Nothing ->
        Right
          ( Symbol "$Failed"
          , appendTagPositionMessage
              "TagUnset"
              tag
              normalizedLhs
              normalizedSession
          )
      Just _
        | not (symbolAllowsValueMutation tag normalizedSession) ->
            Right
              ( Symbol "$Failed"
              , appendSymbolMessage
                  "TagUnset"
                  "wrsym"
                  tag
                  "is Protected."
                  normalizedSession
              )
      Just (TaggedOwnValue _)
        | symbolOwnValuePatternFor tag normalizedSession
            == Just normalizedLhs ->
            Right
              ( Symbol "Null"
              , removeOwnValues [tag] normalizedSession
              )
      Just (TaggedCompoundValue slot _)
        | hasCompoundValue slot tag normalizedLhs normalizedSession ->
            Right
              ( Symbol "Null"
              , removeCompoundValue slot tag normalizedLhs normalizedSession
              )
      Just _ ->
        Right
          ( Symbol "$Failed"
          , appendNamedMessage
              "TagUnset"
              "norep"
              ( "Assignment on "
                  <> inputForm (Symbol tag)
                  <> " for "
                  <> inputForm normalizedLhs
                  <> " not found."
              )
              normalizedSession
          )
  [_, _] -> sessionFailure session "TagUnset expects a symbol tag."
  _ -> sessionFailure session "TagUnset expects a tag and a left-hand side."

taggedAssignmentTarget
  :: EvaluationSession
  -> Text
  -> Expr
  -> Maybe TaggedValueTarget
taggedAssignmentTarget session tag lhs =
  case naturalTaggedValueTarget lhs of
    Just naturalTarget
      | sameTargetSymbol naturalTarget -> retarget naturalTarget
    _
      | tagOccursInUpValuePosition session tag lhs ->
          Just (TaggedCompoundValue UpValueSlot tag)
      | otherwise -> Nothing
 where
  sameTargetSymbol = \case
    TaggedOwnValue name -> sameSessionSymbol session tag name
    TaggedCompoundValue _ name -> sameSessionSymbol session tag name

  retarget = \case
    TaggedOwnValue _ -> Just (TaggedOwnValue tag)
    TaggedCompoundValue slot _ -> Just (TaggedCompoundValue slot tag)

naturalTaggedValueTarget :: Expr -> Maybe TaggedValueTarget
naturalTaggedValueTarget = \case
  Call (Symbol wrapper) (body : _)
    | wrapper `elem` ["Condition", "HoldPattern"] ->
        naturalTaggedValueTarget body
  Symbol name -> Just (TaggedOwnValue name)
  Call (Symbol name) _ -> Just (TaggedCompoundValue DownValueSlot name)
  Call (Call (Symbol name) _) _ ->
    Just (TaggedCompoundValue SubValueSlot name)
  _ -> Nothing

tagOccursInUpValuePosition :: EvaluationSession -> Text -> Expr -> Bool
tagOccursInUpValuePosition session tag = \case
  Call (Symbol "Condition") [body, _] ->
    tagOccursInUpValuePosition session tag body
  Call (Symbol "HoldPattern") [body] ->
    tagOccursInUpValuePosition session tag body
  Call _ values -> any occursInArgument values
  _ -> False
 where
  occursInArgument = \case
    Symbol name -> sameSessionSymbol session tag name
    expression@Call {} ->
      maybe False (sameSessionSymbol session tag) (headChainSymbol expression)
    _ -> False

appendTagPositionMessage
  :: Text
  -> Text
  -> Expr
  -> EvaluationSession
  -> EvaluationSession
appendTagPositionMessage operation tag lhs =
  appendNamedMessage
    operation
    "tagpos"
    ( "Tag "
        <> inputForm (Symbol tag)
        <> " does not occur in a supported position in "
        <> inputForm lhs
        <> "."
    )

evaluateDownValueUnset
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateDownValueUnset depth session lhs = do
  (normalizedLhs, normalizedSession) <- normalizeAssignmentLhs depth session lhs
  case compoundValueOwner normalizedLhs of
    Just (_, owner)
      | not (symbolAllowsValueMutation owner normalizedSession) ->
          Right
            ( Symbol "$Failed"
            , appendSymbolMessage
                "Unset"
                "wrsym"
                owner
                "is Protected."
                normalizedSession
            )
    Just (slot, owner)
      | hasCompoundValue slot owner normalizedLhs normalizedSession ->
          Right
            ( Symbol "Null"
            , removeCompoundValue slot owner normalizedLhs normalizedSession
            )
    _ -> Right (Symbol "$Failed", normalizedSession)

normalizeAssignmentLhs
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
normalizeAssignmentLhs depth session expression = case expression of
  Call (Symbol wrapper) [body, test]
    | wrapper == "Condition" || wrapper == "System`Condition" -> do
        (normalizedBody, updated) <- normalizeAssignmentLhs depth session body
        Right (Call (Symbol "Condition") [normalizedBody, test], updated)
  Call expressionHead arguments' -> do
    (normalizedHead, headSession) <-
      evaluateSessionAt (depth + 1) session expressionHead
    (normalizedArguments, updated) <-
      evaluateCallArgumentsWithAttributes
        depth
        headSession
        normalizedHead
        arguments'
    Right
      ( normalizeSessionAttributeCall updated normalizedHead normalizedArguments
      , updated
      )
  _ -> Right (expression, session)

compoundValueOwner :: Expr -> Maybe (CompoundValueSlot, Text)
compoundValueOwner = \case
  Call (Symbol wrapper) (body : _)
    | wrapper `elem` ["Condition", "HoldPattern"] -> compoundValueOwner body
  Call (Symbol name) _ -> Just (DownValueSlot, name)
  Call (Call (Symbol name) _) _ -> Just (SubValueSlot, name)
  _ -> Nothing

applySessionUpValue
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult (Maybe Expr)
applySessionUpValue depth session expression =
  let (candidates, registeredSession) =
        upValueCandidateSymbols session expression
   in tryCandidates registeredSession candidates
 where
  tryCandidates current [] = Right (Nothing, current)
  tryCandidates current (name : rest) = do
    (replacement, updated) <-
      applySessionDefinitions
        depth
        current
        expression
        (compoundValuesFor UpValueSlot name current)
    case replacement of
      Just _ -> Right (replacement, updated)
      Nothing -> tryCandidates updated rest

upValueCandidateSymbols
  :: EvaluationSession
  -> Expr
  -> ([Text], EvaluationSession)
upValueCandidateSymbols session expression = case expression of
  Call _ values ->
    let (_, retained, updated) =
          foldl addArgument (Set.empty, [], session) values
     in (reverse retained, updated)
  _ -> ([], session)
 where
  addArgument accumulated argument = case argument of
    Symbol name -> addCandidate accumulated name
    Call {} -> maybe accumulated (addCandidate accumulated) (headChainSymbol argument)
    _ -> accumulated

  addCandidate (seen, retained, current) name =
    let registered = registerSymbol name current
        storageName = resolvedSymbolStorageName name registered
     in if Set.member storageName seen
          then (seen, retained, registered)
          else (Set.insert storageName seen, name : retained, registered)

applySessionDownValue
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult (Maybe Expr)
applySessionDownValue depth session expression@(Call (Symbol name) _) =
  applySessionDefinitions
    depth
    session
    expression
    (compoundValuesFor DownValueSlot name session)
applySessionDownValue _ session _ = Right (Nothing, session)

applySessionSubValue
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult (Maybe Expr)
applySessionSubValue depth session expression@(Call (Call {}) _) =
  case subValueTargetSymbol expression of
    Just name ->
      applySessionDefinitions
        depth
        session
        expression
        (compoundValuesFor SubValueSlot name session)
    Nothing -> Right (Nothing, session)
applySessionSubValue _ session _ = Right (Nothing, session)

subValueTargetSymbol :: Expr -> Maybe Text
subValueTargetSymbol (Call expressionHead _) = headChainSymbol expressionHead
subValueTargetSymbol _ = Nothing

headChainSymbol :: Expr -> Maybe Text
headChainSymbol (Symbol name) = Just name
headChainSymbol (Call nestedHead _) = headChainSymbol nestedHead
headChainSymbol _ = Nothing

sameSessionSymbol :: EvaluationSession -> Text -> Text -> Bool
sameSessionSymbol session first second =
  resolvedSymbolStorageName first session
    == resolvedSymbolStorageName second session

applySessionDefinitions
  :: Int
  -> EvaluationSession
  -> Expr
  -> [DownValue]
  -> SessionResult (Maybe Expr)
applySessionDefinitions depth session expression = tryDefinitions session
 where
  tryDefinitions current [] = Right (Nothing, current)
  tryDefinitions current (definition : rest) = do
    let (patternExpression, lhsCondition) =
          downValueMatchPattern definition
        templates = downValueBody definition : maybe [] pure lhsCondition
    (instantiated, matchedSession) <-
      instantiateSessionPattern
        depth
        current
        expression
        patternExpression
        templates
    case (lhsCondition, instantiated) of
      (_, Nothing) -> tryDefinitions matchedSession rest
      (Nothing, Just [replacement]) ->
        applyReplacement matchedSession definition replacement rest
      (Just _, Just [replacement, instantiatedCondition]) -> do
        (conditionResult, updated) <-
          evaluateSessionAt
            (depth + 1)
            matchedSession
            instantiatedCondition
        if conditionResult == Symbol "True"
          then applyReplacement updated definition replacement rest
          else tryDefinitions updated rest
      _ -> tryDefinitions matchedSession rest

  applyReplacement current definition replacement rest =
    case replacement of
      Call (Symbol conditionHead) [body, condition]
        | isSessionSystemHead "Condition" conditionHead
        , downValueDelayed definition ->
            inspectRuntimeResult
              (evaluateSessionAt (depth + 1) current condition)
              $ \case
              P.Left (SessionControl (Returned value Nothing) updated) ->
                Right (Just value, updated)
              P.Left evaluationExit -> Left evaluationExit
              P.Right (conditionResult, updated)
                | conditionResult == Symbol "True" ->
                    catchBareReturn (evaluateReplacement updated body)
                | otherwise -> tryDefinitions updated rest
      Call (Symbol conditionHead) [_, _]
        | isSessionSystemHead "Condition" conditionHead ->
            Right (Just replacement, current)
      _ -> catchBareReturn (evaluateReplacement current replacement)

  catchBareReturn result = inspectRuntimeResult result $ \case
    P.Left (SessionControl (Returned value Nothing) updated) ->
      Right (Just value, updated)
    P.Left evaluationExit -> Left evaluationExit
    P.Right success -> Right success

  evaluateReplacement current replacement = do
    (result, updated) <-
      evaluateSessionAt (depth + 1) current replacement
    Right (Just result, updated)

downValueMatchPattern :: DownValue -> (Expr, Maybe Expr)
downValueMatchPattern definition = case downValuePattern definition of
  Call (Symbol conditionHead) [patternExpression, condition]
    | isSessionSystemHead "Condition" conditionHead ->
        (patternExpression, Just condition)
  patternExpression -> (patternExpression, Nothing)

evaluateSessionCatch
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCatch depth session = \case
  [body] -> catchBody depth session body Nothing Nothing
  [body, formExpression] -> do
    (form, updated) <-
      evaluateSessionAt (depth + 1) session formExpression
    catchBody depth updated body (Just form) Nothing
  [body, formExpression, handlerExpression] -> do
    (form, formSession) <-
      evaluateSessionAt (depth + 1) session formExpression
    (handler, handlerSession) <-
      evaluateSessionAt (depth + 1) formSession handlerExpression
    catchBody depth handlerSession body (Just form) (Just handler)
  arguments' -> Right (Call (Symbol "Catch") arguments', session)

catchBody
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe Expr
  -> Maybe Expr
  -> SessionResult Expr
catchBody depth session body form handler =
  inspectRuntimeResult (evaluateSessionAt (depth + 1) session body) $ \case
    P.Left evaluationExit@(SessionEvaluationFailure _ _) ->
      Left evaluationExit
    P.Left evaluationExit@(SessionControl (Thrown value tag _) stoppedSession)
      | catchMatches form tag ->
          case (handler, tag) of
            (Nothing, _) -> Right (value, stoppedSession)
            (Just evaluatedHandler, Just evaluatedTag) ->
              evaluateSessionAt
                (depth + 1)
                stoppedSession
                (Call evaluatedHandler [value, evaluatedTag])
            _ -> Left evaluationExit
      | otherwise -> Left evaluationExit
    P.Left evaluationExit -> Left evaluationExit
    P.Right success -> Right success

catchMatches :: Maybe Expr -> Maybe Expr -> Bool
catchMatches Nothing Nothing = True
catchMatches (Just form) (Just tag) = matchesPattern tag form
catchMatches _ _ = False

evaluateSessionEnclose
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionEnclose depth session = \case
  [body] -> encloseBody session body Nothing Nothing
  [body, handler] -> encloseBody session body (Just handler) Nothing
  [body, handler, formExpression] -> do
    (form, updated) <-
      evaluateSessionAt (depth + 1) session formExpression
    encloseBody updated body (Just handler) (Just form)
  _ -> sessionFailure session "Enclose expects one, two, or three arguments."
 where
  encloseBody currentSession body handler form =
    inspectRuntimeResult (evaluateSessionAt (depth + 1) scopedSession body) $ \case
      P.Left
        ( SessionControl
            confirmation@(ConfirmationFailed failure tag)
            stoppedSession
          ) ->
          inspectRuntimeResult
            (encloseScopeMatches depth stoppedSession form tag)
            $ \case
            P.Left matchingExit ->
              Left
                ( mapEvaluationExitSession
                    (popEncloseScopes baselineDepth)
                    matchingExit
                )
            P.Right (False, matchedSession) ->
              Left
                ( SessionControl
                    confirmation
                    (popEncloseScopes baselineDepth matchedSession)
                )
            P.Right (True, matchedSession) ->
              restoreEncloseScopes
                baselineDepth
                (handleEnclosedFailure depth matchedSession failure handler)
      P.Left evaluationExit ->
        Left
          ( mapEvaluationExitSession
              (popEncloseScopes baselineDepth)
              evaluationExit
          )
      P.Right (value, stoppedSession) ->
        Right (value, popEncloseScopes baselineDepth stoppedSession)
   where
    baselineDepth = length (sessionEncloseScopes currentSession)
    scopedSession =
      currentSession
        { sessionEncloseScopes =
            sessionEncloseScopes currentSession
              <> [EncloseScope {encloseScopeForm = form}]
        }

handleEnclosedFailure
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe Expr
  -> SessionResult Expr
handleEnclosedFailure _ session failure Nothing = Right (failure, session)
handleEnclosedFailure depth session failure (Just handlerExpression) = do
  (handler, updated) <-
    evaluateSessionAt (depth + 1) session handlerExpression
  case handler of
    String _ -> do
      value <-
        liftPureEvaluation
          updated
          (reduceEvaluatedCall (Call failure [handler]))
      Right (value, updated)
    _ -> evaluateSessionCallable depth updated handler [failure]

encloseScopeMatches
  :: Int
  -> EvaluationSession
  -> Maybe Expr
  -> Maybe Expr
  -> SessionResult Bool
encloseScopeMatches _ session Nothing Nothing = Right (True, session)
encloseScopeMatches depth session (Just form) (Just tag) =
  sessionPatternMatches depth session tag form
encloseScopeMatches _ session _ _ = Right (False, session)

matchingEncloseScopeExists
  :: Int
  -> EvaluationSession
  -> Maybe Expr
  -> [EncloseScope]
  -> SessionResult Bool
matchingEncloseScopeExists depth = go
 where
  go session _ [] = Right (False, session)
  go session tag (scope : rest) = do
    (matches, updated) <-
      encloseScopeMatches depth session (encloseScopeForm scope) tag
    if matches
      then Right (True, updated)
      else go updated tag rest

restoreEncloseScopes :: Int -> SessionResult value -> SessionResult value
restoreEncloseScopes baselineDepth result = inspectRuntimeResult result $ \case
  P.Right (value, session) ->
    Right (value, popEncloseScopes baselineDepth session)
  P.Left evaluationExit ->
    Left
      ( mapEvaluationExitSession
          (popEncloseScopes baselineDepth)
          evaluationExit
      )

popEncloseScopes :: Int -> EvaluationSession -> EvaluationSession
popEncloseScopes baselineDepth session =
  session
    { sessionEncloseScopes =
        take baselineDepth (sessionEncloseScopes session)
    }

clearEncloseScopes :: EvaluationSession -> EvaluationSession
clearEncloseScopes session = session {sessionEncloseScopes = []}

evaluateSessionConfirm
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionConfirm depth session arguments'
  | length arguments' `notElem` [1, 2, 3] =
      sessionFailure session "Confirm expects one, two, or three arguments."
  | valueExpression : _ <- arguments' = do
      (value, valueSession) <-
        evaluateSessionAt (depth + 1) session valueExpression
      if not (isSessionConfirmFailureValue value)
        then Right (value, valueSession)
        else do
          (information, informationSession) <-
            evaluateConfirmationInformation depth valueSession arguments' 1
          (tag, taggedSession) <-
            evaluateConfirmationTag depth informationSession arguments' 2
          let failure
                | length arguments' == 1
                , isSessionFailureValue value = value
                | otherwise =
                    sessionConfirmationFailure
                      "Confirm"
                      value
                      information
                      []
          raiseSessionConfirmation depth taggedSession failure tag
  | otherwise =
      sessionFailure session "Confirm expects one, two, or three arguments."

evaluateSessionConfirmBy
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionConfirmBy depth session arguments'
  | length arguments' `notElem` [2, 3, 4] =
      sessionFailure session "ConfirmBy expects two, three, or four arguments."
  | valueExpression : functionExpression : _ <- arguments' = do
      (value, valueSession) <-
        evaluateSessionAt (depth + 1) session valueExpression
      (function, functionSession) <-
        evaluateSessionAt (depth + 1) valueSession functionExpression
      (testResult, testedSession) <-
        evaluateSessionCallable depth functionSession function [value]
      if testResult == Symbol "True"
        then Right (value, testedSession)
        else do
          (information, informationSession) <-
            evaluateConfirmationInformation depth testedSession arguments' 2
          (tag, taggedSession) <-
            evaluateConfirmationTag depth informationSession arguments' 3
          raiseSessionConfirmation
            depth
            taggedSession
            ( sessionConfirmationFailure
                "ConfirmBy"
                value
                information
                [("Function", function)]
            )
            tag
  | otherwise =
      sessionFailure session "ConfirmBy expects two, three, or four arguments."

evaluateSessionConfirmMatch
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionConfirmMatch depth session arguments'
  | length arguments' `notElem` [2, 3, 4] =
      sessionFailure session "ConfirmMatch expects two, three, or four arguments."
  | valueExpression : patternExpression : _ <- arguments' = do
      (value, valueSession) <-
        evaluateSessionAt (depth + 1) session valueExpression
      (matches, matchedSession) <-
        sessionPatternMatches depth valueSession value patternExpression
      if matches
        then Right (value, matchedSession)
        else do
          (information, informationSession) <-
            evaluateConfirmationInformation depth matchedSession arguments' 2
          (tag, taggedSession) <-
            evaluateConfirmationTag depth informationSession arguments' 3
          raiseSessionConfirmation
            depth
            taggedSession
            ( sessionConfirmationFailure
                "ConfirmMatch"
                value
                information
                [("Pattern", patternExpression)]
            )
            tag
  | otherwise =
      sessionFailure session "ConfirmMatch expects two, three, or four arguments."

evaluateSessionConfirmAssert
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionConfirmAssert depth session arguments'
  | length arguments' `notElem` [1, 2, 3] =
      sessionFailure
        session
        "ConfirmAssert expects one, two, or three arguments."
  | testExpression : _ <- arguments' = do
      (testResult, testedSession) <-
        evaluateSessionAt (depth + 1) session testExpression
      if testResult == Symbol "True"
        then Right (Symbol "Null", testedSession)
        else do
          (information, informationSession) <-
            evaluateConfirmationInformation depth testedSession arguments' 1
          (tag, taggedSession) <-
            evaluateConfirmationTag depth informationSession arguments' 2
          raiseSessionConfirmation
            depth
            taggedSession
            ( sessionConfirmationFailure
                "ConfirmAssert"
                testResult
                information
                [("Test", testResult)]
            )
            tag
  | otherwise =
      sessionFailure
        session
        "ConfirmAssert expects one, two, or three arguments."

evaluateSessionAssert
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAssert depth session arguments'
  | length arguments' `notElem` [1, 2] =
      sessionFailure session "Assert expects one or two arguments."
  | not (sessionAssertEnabled session) =
      Right (Call (Symbol "Assert") arguments', session)
  | testExpression : _ <- arguments' = do
      (testResult, testedSession) <-
        evaluateSessionAt (depth + 1) session testExpression
      if testResult == Symbol "True"
        then Right (Symbol "Null", testedSession)
        else do
          (tag, taggedSession) <- case drop 1 arguments' of
            tagExpression : _ ->
              evaluateSessionAt (depth + 1) testedSession tagExpression
            [] -> Right (Symbol "Null", testedSession)
          appendSessionMessageInsertions
            depth
            taggedSession
            ( Call
                (Symbol "MessageName")
                [Symbol "Assert", String "asrtfl"]
            )
            [testResult, tag]
  | otherwise =
      sessionFailure session "Assert expects one or two arguments."

evaluateConfirmationInformation
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> Int
  -> SessionResult Expr
evaluateConfirmationInformation depth session arguments' index =
  case drop index arguments' of
    expression : _ -> evaluateSessionAt (depth + 1) session expression
    [] -> Right (Symbol "Null", session)

evaluateConfirmationTag
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> Int
  -> SessionResult (Maybe Expr)
evaluateConfirmationTag depth session arguments' index =
  case drop index arguments' of
    expression : _ -> do
      (tag, updated) <- evaluateSessionAt (depth + 1) session expression
      Right (Just tag, updated)
    [] -> Right (Nothing, session)

sessionConfirmationFailure
  :: Text
  -> Expr
  -> Expr
  -> [(Text, Expr)]
  -> Expr
sessionConfirmationFailure confirmationType expression information extraFields =
  sessionFailureExpr
    "ConfirmationFailed"
    ( [ ("ConfirmationType", Symbol confirmationType)
      , ("Expression", expression)
      , ("Information", information)
      ]
        <> extraFields
    )

isSessionConfirmFailureValue :: Expr -> Bool
isSessionConfirmFailureValue = isSessionFailsafeFailureValue

raiseSessionConfirmation
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe Expr
  -> SessionResult Expr
raiseSessionConfirmation depth session failure tag = do
  (matchingScope, matchedSession) <-
    matchingEncloseScopeExists
      depth
      session
      tag
      (sessionEncloseScopes session)
  if matchingScope
    then
      Left
        ( SessionControl
            (ConfirmationFailed failure tag)
            matchedSession
        )
    else
      Right
        ( failure
        , appendNamedMessage
            "Confirm"
            "confirmnotag"
            "Message generated."
            matchedSession
        )

evaluateSessionModule
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionModule depth session = \case
  [Call (Symbol listHead) [], body]
    | isSessionSystemHead "List" listHead ->
        evaluateTargetedReturn "Module" depth session body
  [Call (Symbol listHead) bindingExpressions, body]
    | isSessionSystemHead "List" listHead
    , Just duplicate <- duplicateBindingName bindingExpressions ->
        sessionFailure session ("Module has duplicate binding for '" <> duplicate <> "'.")
    | isSessionSystemHead "List" listHead
    , Just bindings <- parseModuleBindings bindingExpressions -> do
        let nextCounter = sessionModuleCounter session + 1
            allocatedSession =
              session {sessionModuleCounter = nextCounter}
            renameMap =
              Map.fromList
                [ (name, freshModuleName name nextCounter)
                | ModuleBinding name _ <- bindings
                ]
        ((), bodySession) <-
          initializeModuleBindings depth renameMap allocatedSession bindings
        let renamedBody = renameBoundSymbols renameMap body
        evaluateTargetedReturn "Module" depth bodySession renamedBody
    | otherwise ->
        sessionFailure session "Module expects valid symbol locals in its first argument."
  [_, _] ->
    sessionFailure session "Module expects a List of locals as its first argument."
  arguments' -> Right (Call (Symbol "Module") arguments', session)

evaluateSessionWith
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionWith depth session = \case
  [Call (Symbol listHead) [], body]
    | isSessionSystemHead "List" listHead ->
        evaluateSessionAt (depth + 1) session body
  [Call (Symbol listHead) bindingExpressions, body]
    | isSessionSystemHead "List" listHead ->
        inspectRuntimeResult
          (collectWithBindings depth session Set.empty Map.empty bindingExpressions)
          $ \case
          P.Left evaluationExit -> Left evaluationExit
          P.Right (Nothing, updated) ->
            case duplicateBindingName bindingExpressions of
              Just duplicate ->
                sessionFailure updated ("With has duplicate binding for '" <> duplicate <> "'.")
              Nothing ->
                sessionFailure updated "With expects valid symbol bindings in its first argument."
          P.Right (Just substitutions, updated) ->
            evaluateSessionAt
              (depth + 1)
              updated
              (substituteNamedSymbols substitutions body)
  [_, _] ->
    sessionFailure session "With expects a List of bindings as its first argument."
  arguments' -> Right (Call (Symbol "With") arguments', session)

collectWithBindings
  :: Int
  -> EvaluationSession
  -> Set.Set Text
  -> Map.Map Text Expr
  -> [Expr]
  -> SessionResult (Maybe (Map.Map Text Expr))
collectWithBindings _ session _ substitutions [] =
  Right (Just substitutions, session)
collectWithBindings depth session seen substitutions (binding : rest) =
  case parseWithBinding binding of
    Nothing -> Right (Nothing, session)
    Just (WithBinding name rhs delayed)
      | Set.member name seen -> Right (Nothing, session)
      | delayed ->
          collectWithBindings
            depth
            session
            (Set.insert name seen)
            (Map.insert name rhs substitutions)
            rest
      | otherwise -> do
          (value, updated) <- evaluateSessionAt (depth + 1) session rhs
          collectWithBindings
            depth
            updated
            (Set.insert name seen)
            (Map.insert name value substitutions)
            rest

parseWithBinding :: Expr -> Maybe WithBinding
parseWithBinding = \case
  Call (Symbol setHead) [Symbol name, rhs]
    | isSessionSystemHead "Set" setHead ->
        Just (WithBinding name rhs False)
  Call (Symbol setHead) [Symbol name, rhs]
    | isSessionSystemHead "SetDelayed" setHead ->
        Just (WithBinding name rhs True)
  _ -> Nothing

evaluateSessionBlock
  :: Text
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionBlock headName depth session = \case
  [Call (Symbol listHead) [], body]
    | isSessionSystemHead "List" listHead ->
        evaluateTargetedReturn (blockReturnTarget headName) depth session body
  [Call (Symbol listHead) bindingExpressions, body]
    | isSessionSystemHead "List" listHead
    , Just duplicate <- duplicateBindingName bindingExpressions ->
        sessionFailure session ("Block has duplicate binding for '" <> duplicate <> "'.")
    | isSessionSystemHead "List" listHead
    , Just bindings <- parseBlockBindings bindingExpressions ->
        let snapshots =
              [ (name, snapshotSymbolValues name session)
              | BlockBinding name _ <- bindings
              ]
            scopedResult = do
              ((), initialized) <-
                initializeBlockBindings depth session bindings
              evaluateTargetedReturn
                (blockReturnTarget headName)
                depth
                initialized
                body
         in restoreScopedResult snapshots scopedResult
    | otherwise ->
        sessionFailure session "Block expects valid symbol locals in its first argument."
  [_, _] ->
    sessionFailure session "Block expects a List of locals as its first argument."
  arguments' -> Right (Call (Symbol headName) arguments', session)

duplicateBindingName :: [Expr] -> Maybe Text
duplicateBindingName = go Set.empty
 where
  go _ [] = Nothing
  go seen (binding : rest) = case localBindingName binding of
    Just name
      | Set.member name seen -> Just name
      | otherwise -> go (Set.insert name seen) rest
    Nothing -> go seen rest
  localBindingName = \case
    Symbol name -> Just name
    Call (Symbol setHead) [Symbol name, _]
      | isSessionSystemHead "Set" setHead
          || isSessionSystemHead "SetDelayed" setHead -> Just name
    _ -> Nothing

blockReturnTarget :: Text -> Text
blockReturnTarget "Internal`InheritedBlock" = "InheritedBlock"
blockReturnTarget headName = headName

parseBlockBindings :: [Expr] -> Maybe [BlockBinding]
parseBlockBindings expressions = do
  bindings <- traverse parseBinding expressions
  let names = [name | BlockBinding name _ <- bindings]
  if Set.size (Set.fromList names) == length names
    then Just bindings
    else Nothing
 where
  parseBinding = \case
    Symbol name -> Just (BlockBinding name Nothing)
    Call (Symbol setHead) [Symbol name, rhs]
      | isSessionSystemHead "Set" setHead ->
          Just (BlockBinding name (Just (ImmediateValue rhs)))
    Call (Symbol setHead) [Symbol name, rhs]
      | isSessionSystemHead "SetDelayed" setHead ->
          Just (BlockBinding name (Just (DelayedValue rhs)))
    _ -> Nothing

initializeBlockBindings
  :: Int
  -> EvaluationSession
  -> [BlockBinding]
  -> SessionResult ()
initializeBlockBindings depth = go
 where
  go session [] = Right ((), session)
  go session (BlockBinding _ Nothing : rest) =
    go session rest
  go session (BlockBinding name (Just (DelayedValue rhs)) : rest) =
    go (define name (DelayedValue rhs) session) rest
  go session (BlockBinding name (Just (ImmediateValue rhs)) : rest) = do
    (value, updated) <- evaluateSessionAt (depth + 1) session rhs
    go (define name (ImmediateValue value) updated) rest

restoreScopedResult
  :: [(Text, SymbolValueSnapshot)]
  -> SessionResult value
  -> SessionResult value
restoreScopedResult snapshots result = inspectRuntimeResult result $ \case
  P.Left evaluationExit ->
    Left
      ( mapEvaluationExitSession
          (restoreSnapshots snapshots)
          evaluationExit
      )
  P.Right (value, session) ->
    Right (value, restoreSnapshots snapshots session)

restoreSnapshots
  :: [(Text, SymbolValueSnapshot)]
  -> EvaluationSession
  -> EvaluationSession
restoreSnapshots snapshots session =
  foldl
    (\updated (name, snapshot) -> restoreSymbolValues name snapshot updated)
    session
    snapshots

parseModuleBindings :: [Expr] -> Maybe [ModuleBinding]
parseModuleBindings expressions = do
  bindings <- traverse parseBinding expressions
  let names = [name | ModuleBinding name _ <- bindings]
  if Set.size (Set.fromList names) == length names
    then Just bindings
    else Nothing
 where
  parseBinding = \case
    Symbol name -> Just (ModuleBinding name Nothing)
    Call (Symbol setHead) [Symbol name, rhs]
      | isSessionSystemHead "Set" setHead ->
          Just (ModuleBinding name (Just (ImmediateValue rhs)))
    Call (Symbol setHead) [Symbol name, rhs]
      | isSessionSystemHead "SetDelayed" setHead ->
          Just (ModuleBinding name (Just (DelayedValue rhs)))
    _ -> Nothing

initializeModuleBindings
  :: Int
  -> Map.Map Text Text
  -> EvaluationSession
  -> [ModuleBinding]
  -> SessionResult ()
initializeModuleBindings depth renameMap = go
 where
  go session [] = Right ((), session)
  go session (ModuleBinding _ Nothing : rest) =
    go session rest
  go session (ModuleBinding name (Just (DelayedValue rhs)) : rest) =
    go (install name (DelayedValue rhs) session) rest
  go session (ModuleBinding name (Just (ImmediateValue rhs)) : rest) = do
    (value, updated) <- evaluateSessionAt (depth + 1) session rhs
    go (install name (ImmediateValue value) updated) rest

  install name storedDefinition session =
    case Map.lookup name renameMap of
      Just freshName -> define freshName storedDefinition session
      Nothing -> session

freshModuleName :: Text -> Integer -> Text
freshModuleName name counter = name <> "$" <> T.pack (show counter)

renameBoundSymbols :: Map.Map Text Text -> Expr -> Expr
renameBoundSymbols renameMap expression = case expression of
  Symbol name -> maybe expression Symbol (Map.lookup name renameMap)
  Call (Symbol headName) [Call (Symbol listHead) bindings, body]
    | any (`isSessionSystemHead` headName) scopeHeads
    , isSessionSystemHead "List" listHead
    , Just bindingNames <- traverse scopeBindingName bindings ->
        let shadowedNames = Set.fromList bindingNames
            bodyMap = Set.foldr Map.delete renameMap shadowedNames
         in Call
              (Symbol headName)
              [ Call
                  (Symbol "List")
                  (map (renameNestedBinding renameMap) bindings)
              , renameBoundSymbols bodyMap body
              ]
  Call (Symbol functionHead) (parameters : body : remaining)
    | isSessionSystemHead "Function" functionHead
    , length remaining <= 1
    , Just parameterNames <- functionParameterNames parameters ->
        let bodyMap =
              foldr Map.delete renameMap parameterNames
         in Call
              (Symbol functionHead)
              ( canonicalFunctionParameters parameters
                  : renameBoundSymbols bodyMap body
                  : remaining
              )
  Call expressionHead values ->
    Call
      (renameBoundSymbols renameMap expressionHead)
      (map (renameBoundSymbols renameMap) values)
  _ -> expression
 where
  scopeHeads =
    ["Module", "With", "Block"]

  canonicalFunctionParameters = \case
    Call (Symbol listHead) parameters
      | isSessionSystemHead "List" listHead ->
          Call (Symbol "List") parameters
    parameters -> parameters

renameNestedBinding :: Map.Map Text Text -> Expr -> Expr
renameNestedBinding renameMap = \case
  binding@(Symbol _) -> binding
  Call (Symbol headName) [name@(Symbol _), rhs]
    | isSessionSystemHead "Set" headName
        || isSessionSystemHead "SetDelayed" headName ->
        Call
          (Symbol headName)
          [name, renameBoundSymbols renameMap rhs]
  expression -> renameBoundSymbols renameMap expression

scopeBindingName :: Expr -> Maybe Text
scopeBindingName = \case
  Symbol name -> Just name
  Call (Symbol headName) [Symbol name, _]
    | isSessionSystemHead "Set" headName
        || isSessionSystemHead "SetDelayed" headName -> Just name
  _ -> Nothing

functionParameterNames :: Expr -> Maybe [Text]
functionParameterNames = \case
  Symbol nullName
    | isSessionSystemHead "Null" nullName -> Nothing
  Symbol name -> Just [name]
  Call (Symbol listHead) parameters
    | isSessionSystemHead "List" listHead ->
        traverse symbolName parameters
  _ -> Nothing

evaluateSessionTable
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionTable depth session arguments' = case arguments' of
  body : iteratorSpecs@(_ : _) ->
    inspectRuntimeResult (tableLoop depth session body iteratorSpecs) $ \case
      P.Left (InvalidIterator updated) ->
        sessionFailure updated (iteratorFailureMessage "Table" iteratorSpecs)
      P.Left (IterationEvaluationFailure evaluationExit) ->
        Left evaluationExit
      P.Right result -> Right result
  _ -> sessionFailure session "Table expects a body and at least one iterator specification."

evaluateSessionDo
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionDo depth session arguments' = case arguments' of
  body : iteratorSpecs@(_ : _) ->
    inspectRuntimeResult
      (flatIterationLoop False depth session body iteratorSpecs)
      $ \case
      P.Left (InvalidIterator updated) ->
        Right (Call (Symbol "Do") arguments', updated)
      P.Left
        ( IterationEvaluationFailure
            (SessionControl BreakSignal stoppedSession)
          ) ->
          Right (Symbol "Null", stoppedSession)
      P.Left
        ( IterationEvaluationFailure
            (SessionControl (Returned value (Just "Do")) stoppedSession)
          ) ->
          Right (value, stoppedSession)
      P.Left (IterationEvaluationFailure evaluationExit) ->
        Left evaluationExit
      P.Right (_, updated) -> Right (Symbol "Null", updated)
  _ -> Right (Call (Symbol "Do") arguments', session)

evaluateSessionFor
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionFor depth session arguments' =
  catchLoopBoundary "For" (runFor arguments')
 where
  runFor [initialization, test, increment, body] = do
    (_, initialized) <-
      evaluateSessionAt (depth + 1) session initialization
    loop 0 initialized
   where
    loop iteration current
      | iteration > iterationSafetyLimit =
          Right (Call (Symbol "For") arguments', current)
      | otherwise = do
          (testResult, tested) <-
            evaluateSessionAt (depth + 1) current test
          if testResult /= Symbol "True"
            then Right (Symbol "Null", tested)
            else do
              ((), bodySession) <-
                evaluateContinuableBody depth tested body
              (_, incremented) <-
                evaluateSessionAt (depth + 1) bodySession increment
              loop (iteration + 1) incremented
  runFor _ = Right (Call (Symbol "For") arguments', session)

evaluateSessionWhile
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionWhile depth session arguments' =
  catchLoopBoundary "While" (runWhile arguments')
 where
  runWhile [test] = loop test Nothing 0 session
  runWhile [test, body] = loop test (Just body) 0 session
  runWhile _ = Right (Call (Symbol "While") arguments', session)

  loop test body iteration current
    | iteration > iterationSafetyLimit =
        Right (Call (Symbol "While") arguments', current)
    | otherwise = do
        (testResult, tested) <-
          evaluateSessionAt (depth + 1) current test
        if testResult /= Symbol "True"
          then Right (Symbol "Null", tested)
          else do
            bodySession <- case body of
              Nothing -> Right tested
              Just expression -> do
                ((), updated) <-
                  evaluateContinuableBody depth tested expression
                Right updated
            loop test body (iteration + 1) bodySession

iterationSafetyLimit :: Int
iterationSafetyLimit = 65536

evaluateContinuableBody
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult ()
evaluateContinuableBody depth session body =
  inspectRuntimeResult (evaluateSessionAt (depth + 1) session body) $ \case
    P.Left (SessionControl ContinueSignal stoppedSession) ->
      Right ((), stoppedSession)
    P.Left evaluationExit -> Left evaluationExit
    P.Right (_, updated) -> Right ((), updated)

catchLoopBoundary :: Text -> SessionResult Expr -> SessionResult Expr
catchLoopBoundary target result = inspectRuntimeResult result $ \case
  P.Left (SessionControl BreakSignal stoppedSession) ->
    Right (Symbol "Null", stoppedSession)
  P.Left
    ( SessionControl
        (Returned value (Just actualTarget))
        stoppedSession
      )
    | actualTarget == target -> Right (value, stoppedSession)
  P.Left evaluationExit -> Left evaluationExit
  P.Right success -> Right success

evaluateSessionAccumulator
  :: Text
  -> Text
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAccumulator headName accumulatorHead depth session arguments' =
  case arguments' of
    body : iteratorSpecs@(_ : _)
      | all isListIteratorSpec iteratorSpecs ->
          inspectRuntimeResult
            (flatIterationLoop True depth session body iteratorSpecs)
            $ \case
            P.Left (InvalidIterator updated) ->
              sessionFailure updated (iteratorFailureMessage headName iteratorSpecs)
            P.Left (IterationEvaluationFailure evaluationExit) ->
              Left evaluationExit
            P.Right (terms, updated) ->
              evaluateSessionAt
                (depth + 1)
                updated
                ( Call
                    (Symbol accumulatorHead)
                    (accumulatorArguments accumulatorHead terms)
                )
      | otherwise ->
          sessionFailure session (headName <> " iterator specification must be a List.")
    _ ->
      sessionFailure session (headName <> " expects a body and at least one iterator specification.")
iteratorFailureMessage :: Text -> [Expr] -> Text
iteratorFailureMessage headName specifications
  | any hasZeroStep specifications = "Iterator step must be a nonzero real number."
  | otherwise = headName <> " received an invalid iterator specification."
 where
  hasZeroStep = \case
    Call (Symbol listHead) [_, _, _, step]
      | isSessionSystemHead "List" listHead -> exactIteratorZero step
    _ -> False
  exactIteratorZero (Integer 0) = True
  exactIteratorZero (Rational 0 _) = True
  exactIteratorZero _ = False

flatIterationLoop
  :: Bool
  -> Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> IterationResult ([Expr], EvaluationSession)
flatIterationLoop retainValues depth session body iteratorSpecs = do
  (reversed, updated) <- collect depth session iteratorSpecs []
  Right (reverse reversed, updated)
 where
  collect currentDepth current [] retained = do
    inspectRuntimeResult
      (evaluateSessionAt (currentDepth + 1) current body)
      $ \case
      P.Left (SessionControl ContinueSignal stoppedSession)
        | not retainValues -> Right (retained, stoppedSession)
      P.Left evaluationExit ->
        Left (IterationEvaluationFailure evaluationExit)
      P.Right (value, updated) ->
        Right (if retainValues then value : retained else retained, updated)
  collect currentDepth current (iteratorSpec : remainingSpecs) retained = do
    (Iterator variable values, resolvedSession) <-
      resolveIterator currentDepth current iteratorSpec
    case variable of
      Nothing -> collectWithoutVariable currentDepth resolvedSession values retained
      Just name ->
        let previousValues = snapshotSymbolValues name resolvedSession
         in collectWithVariable
              currentDepth
              name
              previousValues
              resolvedSession
              values
              retained
   where
    collectWithoutVariable _ currentSession [] retainedValues =
      Right (retainedValues, currentSession)
    collectWithoutVariable nestedDepth currentSession (_ : rest) retainedValues = do
      (nextRetained, updated) <-
        collect (nestedDepth + 1) currentSession remainingSpecs retainedValues
      collectWithoutVariable nestedDepth updated rest nextRetained
    collectWithVariable _ name previous currentSession [] retainedValues =
      Right
        ( retainedValues
        , restoreSymbolValues name previous currentSession
        )
    collectWithVariable nestedDepth name previous currentSession (value : rest) retainedValues =
      let bound = define name (ImmediateValue value) currentSession
       in inspectRuntimeResult
            (collect (nestedDepth + 1) bound remainingSpecs retainedValues)
            $ \case
            P.Left failure -> Left (restoreIterationFailure name previous failure)
            P.Right (nextRetained, updated) ->
              collectWithVariable
                nestedDepth
                name
                previous
                updated
                rest
                nextRetained

tableLoop
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> IterationResult (Expr, EvaluationSession)
tableLoop depth session body [] =
  liftIterationEvaluation (evaluateSessionAt (depth + 1) session body)
tableLoop depth session body (iteratorSpec : remainingSpecs) = do
  (Iterator variable values, resolvedSession) <-
    resolveIterator depth session iteratorSpec
  case variable of
    Nothing -> collectWithoutVariable resolvedSession values []
    Just name ->
      let previousValues = snapshotSymbolValues name resolvedSession
       in collectWithVariable name previousValues resolvedSession values []
 where
  collectWithoutVariable current [] results =
    Right (evaluatedList (reverse results), current)
  collectWithoutVariable current (_ : rest) results = do
    (value, updated) <- tableLoop (depth + 1) current body remainingSpecs
    collectWithoutVariable updated rest (value : results)
  collectWithVariable name previous current [] results =
    Right
      ( evaluatedList (reverse results)
      , restoreSymbolValues name previous current
      )
  collectWithVariable name previous current (value : rest) results =
    let bound = define name (ImmediateValue value) current
     in inspectRuntimeResult
          (tableLoop (depth + 1) bound body remainingSpecs)
          $ \case
          P.Left failure -> Left (restoreIterationFailure name previous failure)
          P.Right (result, updated) ->
            collectWithVariable name previous updated rest (result : results)

resolveIterator
  :: Int
  -> EvaluationSession
  -> Expr
  -> IterationResult (Iterator, EvaluationSession)
resolveIterator depth session iteratorSpec = case iteratorSpec of
  Integer count -> (,session) <$> countIterator session count
  Call (Symbol listHead) values
    | isSessionSystemHead "List" listHead ->
        resolveListIterator depth session values
  _ -> do
    (evaluated, updated) <-
      liftIterationEvaluation (evaluateSessionAt (depth + 1) session iteratorSpec)
    case evaluated of
      Integer count -> (,updated) <$> countIterator updated count
      _ -> invalidIterator updated

resolveListIterator
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> IterationResult (Iterator, EvaluationSession)
resolveListIterator depth session = \case
  [countExpression] -> do
    (evaluated, updated) <-
      liftIterationEvaluation (evaluateSessionAt (depth + 1) session countExpression)
    case evaluated of
      Integer count -> (,updated) <$> countIterator updated count
      _ -> invalidIterator updated
  Symbol name : [boundExpression] -> do
    (bound, updated) <-
      liftIterationEvaluation (evaluateSessionAt (depth + 1) session boundExpression)
    case bound of
      Call (Symbol "List") values ->
        Right (Iterator (Just name) values, updated)
      _ -> do
        values <- numericIteratorValues updated (Integer 1) bound (Integer 1)
        Right (Iterator (Just name) values, updated)
  Symbol name : [startExpression, endExpression] -> do
    (evaluated, updated) <-
      liftIterationEvaluation
        (evaluateArguments depth session [startExpression, endExpression])
    case evaluated of
      [start, end] -> do
        values <- numericIteratorValues updated start end (Integer 1)
        Right (Iterator (Just name) values, updated)
      _ -> invalidIterator updated
  Symbol name : [startExpression, endExpression, stepExpression] -> do
    (evaluated, updated) <-
      liftIterationEvaluation
        (evaluateArguments depth session [startExpression, endExpression, stepExpression])
    case evaluated of
      [start, end, step] -> do
        values <- numericIteratorValues updated start end step
        Right (Iterator (Just name) values, updated)
      _ -> invalidIterator updated
  _ -> invalidIterator session

countIterator :: EvaluationSession -> Integer -> IterationResult Iterator
countIterator session count
  | count > toInteger (maxBound :: Int) = invalidIterator session
  | otherwise =
      Right (Iterator Nothing (replicate (fromIntegral (max 0 count)) (Integer 0)))

numericIteratorValues
  :: EvaluationSession
  -> Expr
  -> Expr
  -> Expr
  -> IterationResult [Expr]
numericIteratorValues session start end step =
  maybe (invalidIterator session) Right (exactRangeValues start end step)

invalidIterator :: EvaluationSession -> IterationResult value
invalidIterator = Left . InvalidIterator

liftIterationEvaluation
  :: SessionResult value
  -> IterationResult (value, EvaluationSession)
liftIterationEvaluation result = inspectRuntimeResult result $ \case
  P.Left evaluationExit -> Left (IterationEvaluationFailure evaluationExit)
  P.Right success -> Right success

restoreIterationFailure
  :: Text
  -> SymbolValueSnapshot
  -> IterationFailure
  -> IterationFailure
restoreIterationFailure name previous = \case
  InvalidIterator failedSession ->
    InvalidIterator (restoreSymbolValues name previous failedSession)
  IterationEvaluationFailure evaluationExit ->
    IterationEvaluationFailure
      ( mapEvaluationExitSession
          (restoreSymbolValues name previous)
          evaluationExit
      )

evaluatedList :: [Expr] -> Expr
evaluatedList = Call (Symbol "List") . evaluatedListArguments

evaluatedListArguments :: [Expr] -> [Expr]
evaluatedListArguments = filter (/= Symbol "Nothing") . concatMap spliceArgument
 where
  spliceArgument = \case
    Call (Symbol sequenceHead) values
      | isSessionSystemHead "Sequence" sequenceHead -> values
    Call (Symbol spliceHead) [Call (Symbol listHead) values]
      | isSessionSystemHead "Splice" spliceHead
      , isSessionSystemHead "List" listHead -> values
    Call (Symbol spliceHead) [Call (Symbol listHead) values, target]
      | isSessionSystemHead "Splice" spliceHead
      , isSessionSystemHead "List" listHead
      , target == Symbol "List" -> values
    value -> [value]

isListIteratorSpec :: Expr -> Bool
isListIteratorSpec (Call (Symbol listHead) _) =
  isSessionSystemHead "List" listHead
isListIteratorSpec _ = False

accumulatorArguments :: Text -> [Expr] -> [Expr]
accumulatorArguments accumulatorHead = concatMap spliceArgument
 where
  spliceArgument = \case
    Call (Symbol "Sequence") values -> values
    Call (Symbol "Splice") [Call (Symbol "List") values, target]
      | target == Symbol accumulatorHead -> values
    value -> [value]

evaluateSessionCompoundExpression
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCompoundExpression depth session expressions =
  go (Symbol "Null") session expressions
 where
  originalExpressions = expressions

  go result current [] = Right (result, current)
  go _ current (expression : rest) =
    inspectRuntimeResult (evaluateSessionAt (depth + 1) current expression) $ \case
      P.Left controlExit@(SessionControl Aborted stoppedSession) ->
        case deferAbortToCurrentProtect stoppedSession of
          Just deferred -> go (Symbol "Null") deferred rest
          Nothing -> Left controlExit
      P.Left controlExit@(SessionControl (GotoSignal target) stoppedSession) ->
        case sessionLabelContinuation target originalExpressions of
          Just continuation -> go (Symbol "Null") stoppedSession continuation
          Nothing -> Left controlExit
      P.Left evaluationExit -> Left evaluationExit
      P.Right (result, updated) -> go result updated rest

sessionLabelContinuation :: Expr -> [Expr] -> Maybe [Expr]
sessionLabelContinuation _ [] = Nothing
sessionLabelContinuation target (expression : rest) = case expression of
  Call (Symbol labelHead) [tag]
    | isSessionSystemHead "Label" labelHead
    , tag == target -> Just rest
  _ -> sessionLabelContinuation target rest

evaluateSessionLabel
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionLabel session = \case
  [tag] -> Right (Call (Symbol "Label") [tag], session)
  _ -> sessionFailure session "Label expects exactly one argument."

evaluateSessionGoto
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionGoto depth session = \case
  [tagExpression] -> do
    (tag, updated) <- evaluateSessionAt (depth + 1) session tagExpression
    Left (SessionControl (GotoSignal tag) updated)
  _ -> sessionFailure session "Goto expects exactly one argument."

evaluateSessionIf
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionIf depth session = \case
  condition : trueBranch : remaining -> do
    (evaluatedCondition, updated) <- evaluateSessionAt (depth + 1) session condition
    case evaluatedCondition of
      Symbol "True" -> evaluateSessionAt (depth + 1) updated trueBranch
      Symbol "False" -> case remaining of
        falseBranch : _ -> evaluateSessionAt (depth + 1) updated falseBranch
        [] -> Right (Symbol "Null", updated)
      _ -> case remaining of
        _falseBranch : unknownBranch : _ ->
          evaluateSessionAt (depth + 1) updated unknownBranch
        _ -> Right (Call (Symbol "If") (evaluatedCondition : trueBranch : remaining), updated)
  arguments' -> Right (Call (Symbol "If") arguments', session)

evaluateSessionWhich
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionWhich depth session arguments'
  | null arguments' || odd (length arguments') =
      sessionFailure session "Which expects condition-value pairs."
  | otherwise = select session arguments'
 where
  select current [] = Right (Symbol "Null", current)
  select current (conditionExpression : valueExpression : remaining) = do
    (condition, updated) <-
      evaluateSessionAt (depth + 1) current conditionExpression
    case condition of
      Symbol "True" ->
        evaluateSessionAt (depth + 1) updated valueExpression
      Symbol "False" -> select updated remaining
      _ ->
        Right
          ( Call
              (Symbol "Which")
              (condition : valueExpression : remaining)
          , updated
          )
  select current remaining =
    Right (Call (Symbol "Which") remaining, current)

evaluateSessionSwitch
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSwitch depth session arguments'
  | length arguments' < 3 || even (length arguments') =
      sessionFailure
        session
        "Switch expects an expression followed by form-value pairs."
  | subjectExpression : formsAndValues <- arguments' = do
      (subject, subjectSession) <-
        evaluateSessionAt (depth + 1) session subjectExpression
      select subject formsAndValues subjectSession formsAndValues
  | otherwise =
      sessionFailure
        session
        "Switch expects an expression followed by form-value pairs."
 where
  select subject original current [] =
    Right (Call (Symbol "Switch") (subject : original), current)
  select subject original current (form : valueExpression : remaining) = do
    (matches, updated) <-
      sessionPatternMatches depth current subject form
    if matches
      then evaluateSessionAt (depth + 1) updated valueExpression
      else select subject original updated remaining
  select subject original current _ =
    Right (Call (Symbol "Switch") (subject : original), current)

evaluateSessionPiecewise
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionPiecewise depth session = \case
  [casesExpression] -> evaluateCases casesExpression Nothing
  [casesExpression, defaultExpression] ->
    evaluateCases casesExpression (Just defaultExpression)
  _ ->
    sessionFailure
      session
      "Piecewise expects a case list and an optional default value."
 where
  evaluateCases casesExpression defaultExpression =
    case casesExpression of
      Call (Symbol listHead) cases
        | isSessionSystemHead "List" listHead ->
            select [] session cases defaultExpression
      _ ->
        sessionFailure
          session
          "Piecewise expects its first argument to be a list of {value, condition} pairs."

  select retained current [] defaultExpression = do
    (defaultValue, updated) <- case defaultExpression of
      Nothing -> Right (Integer 0, current)
      Just expression -> evaluateSessionAt (depth + 1) current expression
    Right (retainedPiecewise retained defaultValue, updated)
  select retained current (caseExpression : remaining) defaultExpression =
    case caseExpression of
      Call (Symbol listHead) [valueExpression, conditionExpression]
        | isSessionSystemHead "List" listHead -> do
            (condition, conditionSession) <-
              evaluateSessionAt (depth + 1) current conditionExpression
            case condition of
              Symbol "True" -> do
                (selectedValue, updated) <-
                  evaluateSessionAt
                    (depth + 1)
                    conditionSession
                    valueExpression
                Right (retainedPiecewise retained selectedValue, updated)
              Symbol "False" ->
                select retained conditionSession remaining defaultExpression
              _ -> do
                (value, updated) <-
                  evaluateSessionAt
                    (depth + 1)
                    conditionSession
                    valueExpression
                select
                  (retained <> [(value, condition)])
                  updated
                  remaining
                  defaultExpression
      _ ->
        sessionFailure
          current
          "Piecewise cases must be two-element lists of {value, condition}."

  retainedPiecewise [] defaultValue = defaultValue
  retainedPiecewise retained defaultValue =
    Call
      (Symbol "Piecewise")
      [ Call
          (Symbol "List")
          [ Call (Symbol "List") [value, condition]
          | (value, condition) <- retained
          ]
      , defaultValue
      ]

evaluateSessionReleaseHold
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionReleaseHold depth session = \case
  [expression] -> do
    (heldExpression, updated) <-
      evaluateSessionAt (depth + 1) session expression
    case heldExpression of
      Call (Symbol wrapperHead) values
        | wrapperHead `elem` ["Hold", "HoldComplete", "HoldForm", "Unevaluated"] ->
            evaluateSessionAt
              (depth + 1)
              updated
              ( case values of
                  [value] -> value
                  _ -> Call (Symbol "Sequence") values
              )
      _ -> Right (heldExpression, updated)
  _ -> sessionFailure session "ReleaseHold expects exactly one argument."

evaluateSessionInactive
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionInactive depth session = \case
  [argument] -> do
    (prepared, preparedSession) <- prepareHeldArgument argument
    let normalized = normalizeSessionSequenceCall (Symbol "Inactive") [prepared]
        normalizedArguments = case normalized of
          Call _ values -> values
          _ -> [prepared]
    case normalizedArguments of
      [target]
        | inactiveScalar target -> Right (target, preparedSession)
        | otherwise ->
            Right (Call (Symbol "Inactive") [target], preparedSession)
      _ ->
        sessionFailure
          preparedSession
          "Inactive expects exactly one argument after Sequence splicing."
  _ -> sessionFailure session "Inactive expects exactly one argument."
 where
  prepareHeldArgument argument = case argument of
    Call (Symbol evaluateHead) [payload]
      | isSessionSystemHead "Evaluate" evaluateHead ->
          case payload of
            Call (Symbol unevaluatedHead) [_]
              | isSessionSystemHead "Unevaluated" unevaluatedHead ->
                  Right (payload, session)
            _ -> evaluateSessionAt (depth + 1) session payload
    _ -> Right (argument, session)

  inactiveScalar = \case
    Integer {} -> True
    Rational {} -> True
    Real {} -> True
    Complex {} -> True
    String {} -> True
    ByteArray {} -> True
    _ -> False

evaluateSessionActivate
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionActivate depth session = \case
  [sourceExpression] -> do
    (source, sourceSession) <-
      evaluateSessionAt (depth + 1) session sourceExpression
    (activated, updated) <-
      activateSessionTree depth Nothing sourceSession source
    evaluateSessionAt (depth + 1) updated activated
  [sourceExpression, patternExpression] -> do
    (source, sourceSession) <-
      evaluateSessionAt (depth + 1) session sourceExpression
    (patternExpression', patternSession) <-
      evaluateSessionAt (depth + 1) sourceSession patternExpression
    (activated, updated) <-
      activateSessionTree
        depth
        (Just patternExpression')
        patternSession
        source
    evaluateSessionAt (depth + 1) updated activated
  _ ->
    sessionFailure
      session
      "Activate expects an expression and an optional pattern."

activateSessionTree
  :: Int
  -> Maybe Expr
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
activateSessionTree depth patternExpression session expression =
  case expression of
    Call inactiveHead@(Symbol inactiveName) [target]
      | isSessionSystemHead "Inactive" inactiveName -> do
          (activatedTarget, targetSession) <-
            activateSessionTree depth patternExpression session target
          (matches, updated) <- case patternExpression of
            Nothing -> Right (True, targetSession)
            Just patternExpression' ->
              sessionPatternMatches
                depth
                targetSession
                target
                patternExpression'
          Right
            ( if matches
                then activatedTarget
                else Call inactiveHead [activatedTarget]
            , updated
            )
    Call expressionHead values -> do
      (activatedHead, headSession) <-
        activateSessionTree depth patternExpression session expressionHead
      (activatedValues, updated) <- activateValues [] headSession values
      Right (Call activatedHead activatedValues, updated)
    _ -> Right (expression, session)
 where
  activateValues retained current [] = Right (retained, current)
  activateValues retained current (value : remaining) = do
    (activated, updated) <-
      activateSessionTree depth patternExpression current value
    activateValues (retained <> [activated]) updated remaining

evaluateSessionAnd
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAnd =
  evaluateSessionLogical "And" (Symbol "True") (Symbol "False")

evaluateSessionOr
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOr =
  evaluateSessionLogical "Or" (Symbol "False") (Symbol "True")

evaluateSessionLogical
  :: Text
  -> Expr
  -> Expr
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionLogical headName identity decisive depth = go []
 where
  go retained session [] =
    let normalized =
          normalizeSessionAttributeCall
            session
            (Symbol headName)
            retained
        values = case normalized of
          Call _ normalizedValues -> normalizedValues
          _ -> retained
     in Right (logicalResult headName identity values, session)
  go retained session (value : rest) = do
    (evaluated, updated) <- evaluateSessionAt (depth + 1) session value
    if evaluated == decisive
      then Right (decisive, updated)
      else
        if evaluated == identity
          then go retained updated rest
          else go (retained <> [evaluated]) updated rest

evaluateArguments
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult [Expr]
evaluateArguments depth = go []
 where
  go retained session [] = Right (retained, session)
  go retained session (value : rest) = do
    (evaluated, updated) <- evaluateSessionAt (depth + 1) session value
    go (retained <> [evaluated]) updated rest

staticHeldHeadNames :: [Text]
staticHeldHeadNames =
  [ "Function"
  , "Hold"
  , "HoldComplete"
  , "HoldForm"
  , "HoldPattern"
  , "Unevaluated"
  ]

evaluateStaticHeldCall
  :: Int
  -> EvaluationSession
  -> Text
  -> [Expr]
  -> SessionResult Expr
evaluateStaticHeldCall depth session headName = prepare [] session
 where
  expressionHead = Symbol headName
  completeHold = headName `elem` ["HoldComplete", "Unevaluated"]

  prepare retained current [] =
    Right
      ( if completeHold
          then Call expressionHead retained
          else normalizeEvaluatedCall expressionHead retained
      , current
      )
  prepare retained current (argument : rest)
    | not completeHold
    , Call (Symbol evaluateHead) [payload] <- argument
    , isSessionSystemHead "Evaluate" evaluateHead = do
        (prepared, updated) <- case payload of
          Call (Symbol unevaluatedHead) [_]
            | isSessionSystemHead "Unevaluated" unevaluatedHead ->
                Right (payload, current)
          _ -> evaluateSessionAt (depth + 1) current payload
        prepare (retained <> [prepared]) updated rest
    | otherwise = prepare (retained <> [argument]) current rest

evaluateCallArgumentsWithAttributes
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult [Expr]
evaluateCallArgumentsWithAttributes depth session expressionHead arguments' =
  case sessionCallAttributes session expressionHead of
    P.Left (EvaluationError message) -> sessionFailure session message
    P.Right attributes ->
      prepare
        attributes
        (isSymbolExpression expressionHead)
        0
        []
        session
        arguments'
 where
  prepare _ _ _ retained current [] = Right (retained, current)
  prepare attributes symbolHead index retained current (argument : rest) = do
    (prepared, updated) <-
      if attributeHoldsArgument attributes index
        then evaluateHeldAttributeArgument attributes symbolHead current argument
        else evaluateSessionAt (depth + 1) current argument
    prepare
      attributes
      symbolHead
      (index + 1)
      (retained <> [prepared])
      updated
      rest

  evaluateHeldAttributeArgument attributes symbolHead current argument
    | Set.member HoldAllComplete attributes = Right (argument, current)
    | not symbolHead = Right (argument, current)
    | Call (Symbol evaluateHead) [payload] <- argument
    , isSessionSystemHead "Evaluate" evaluateHead =
        case payload of
          Call (Symbol unevaluatedHead) [_]
            | isSessionSystemHead "Unevaluated" unevaluatedHead ->
                Right (payload, current)
          _ -> evaluateSessionAt (depth + 1) current payload
    | otherwise = Right (argument, current)

  isSymbolExpression Symbol {} = True
  isSymbolExpression _ = False

attributeHoldsArgument :: Set.Set SymbolAttribute -> Int -> Bool
attributeHoldsArgument attributes index =
  Set.member HoldAll attributes
    || Set.member HoldAllComplete attributes
    || (Set.member HoldFirst attributes && index == 0)
    || (Set.member HoldRest attributes && index > 0)

normalizeSessionAttributeCall
  :: EvaluationSession
  -> Expr
  -> [Expr]
  -> Expr
normalizeSessionAttributeCall session expressionHead values =
  case sessionCallAttributes session expressionHead of
    P.Right attributes ->
      let symbolHead = case expressionHead of Symbol {} -> True; _ -> False
          sequenceNormalized =
            if Set.member SequenceHold attributes
                || Set.member HoldAllComplete attributes
              then Call expressionHead values
              else normalizeSessionSequenceCall expressionHead values
          flattened =
            if symbolHead && Set.member Flat attributes
              then flattenSameHead expressionHead (arguments sequenceNormalized)
              else arguments sequenceNormalized
          ordered =
            if symbolHead && Set.member Orderless attributes
              then sortBy canonicalCompare flattened
              else flattened
       in Call expressionHead ordered
    P.Left _ -> normalizeEvaluatedCall expressionHead values
 where
  flattenSameHead targetHead = concatMap flattenOne
   where
    flattenOne (Call nestedHead nestedValues)
      | nestedHead == targetHead = nestedValues
    flattenOne value = [value]

-- Session attributes are mutable, so sequence preparation here cannot reuse
-- the pure evaluator's fixed suppression table for Rule and RuleDelayed.
normalizeSessionSequenceCall :: Expr -> [Expr] -> Expr
normalizeSessionSequenceCall expressionHead values =
  Call expressionHead retained
 where
  spliced = concatMap spliceArgument values
  retained
    | sessionHeadExpressionIsAny ["Association", "List"] expressionHead =
        filter (/= Symbol "Nothing") spliced
    | otherwise = spliced
  spliceArgument = \case
    Call (Symbol sequenceHead) sequenceValues
      | isSessionSystemHead "Sequence" sequenceHead -> sequenceValues
    Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues]
      | isSessionSystemHead "Splice" spliceHead
      , isSessionSystemHead "List" listHead
      , expressionHead == Symbol "List" -> spliceValues
    Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues, target]
      | isSessionSystemHead "Splice" spliceHead
      , isSessionSystemHead "List" listHead
      , target == expressionHead -> spliceValues
    value -> [value]

stripSessionTransparentUnevaluatedArguments :: Expr -> [Expr] -> [Expr]
stripSessionTransparentUnevaluatedArguments expressionHead
  | sessionHeadExpressionIsAny
      [ "Composition"
      , "Head"
      , "Length"
      , "Part"
      , "Accuracy"
      , "BlockMap"
      , "ExactNumberQ"
      , "FlattenAt"
      , "InexactNumberQ"
      , "MachineIntegerQ"
      , "MachineNumberQ"
      , "MapIndexed"
      , "MapThread"
      , "MaximalBy"
      , "MinimalBy"
      , "NumberQ"
      , "N"
      , "OrderingBy"
      , "Outer"
      , "Plus"
      , "Precision"
      , "RandomSample"
      , "SetAccuracy"
      , "SetPrecision"
      , "RealValuedNumberQ"
      , "RightComposition"
      , "Scan"
      , "Operate"
      , "Thread"
      , "Through"
      , "Tr"
      ]
      expressionHead =
      map stripSessionDirectUnevaluated
  | otherwise = id

stripSessionDirectUnevaluated :: Expr -> Expr
stripSessionDirectUnevaluated = \case
  Call (Symbol unevaluatedHead) [value]
    | isSessionSystemHead "Unevaluated" unevaluatedHead -> value
  value -> value

threadSessionListableCall
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe (SessionResult Expr)
threadSessionListableCall depth session expression = case expression of
  Call expressionHead values ->
    case sessionCallAttributes session expressionHead of
      P.Right attributes
        | Set.member Listable attributes ->
            case listableArgumentRows values of
              P.Left (EvaluationError message) -> Just (sessionFailure session message)
              P.Right Nothing -> Nothing
              P.Right (Just rows) ->
                Just (evaluateRows expressionHead [] session rows)
      _ -> Nothing
  _ -> Nothing
 where
  evaluateRows _ retained current [] =
    Right (evaluatedList (reverse retained), current)
  evaluateRows expressionHead retained current (row : rest) = do
    (value, updated) <-
      evaluateSessionAt (depth + 1) current (Call expressionHead row)
    evaluateRows expressionHead (value : retained) updated rest

listableArgumentRows :: [Expr] -> Either EvaluationError (Maybe [[Expr]])
listableArgumentRows values = case listLengths of
  [] -> P.Right Nothing
  firstLength : remainingLengths
    | all (== firstLength) remainingLengths ->
        P.Right
          ( Just
              [ [ case value of
                    Call (Symbol listHead) elements
                      | isSessionSystemHead "List" listHead -> elements !! index
                    scalar -> scalar
                | value <- values
                ]
              | index <- [0 .. firstLength - 1]
              ]
          )
    | otherwise ->
        P.Left
          ( EvaluationError
              "Listable Function arguments have incompatible list lengths."
          )
 where
  listLengths =
    [ length elements
    | Call (Symbol listHead) elements <- values
    , isSessionSystemHead "List" listHead
    ]

sessionCallAttributes
  :: EvaluationSession
  -> Expr
  -> Either EvaluationError (Set.Set SymbolAttribute)
sessionCallAttributes session = \case
  Symbol name -> P.Right (symbolAttributesFor name session)
  Call (Symbol functionHead) functionArguments
    | isSessionSystemHead "Function" functionHead ->
        functionAttributeSet functionArguments
  _ -> P.Right Set.empty

functionAttributeSet
  :: [Expr]
  -> Either EvaluationError (Set.Set SymbolAttribute)
functionAttributeSet [_, _, specification] =
  Set.fromList . mapMaybeAttribute <$> attributeSymbols specification
 where
  attributeSymbols (Symbol name) = P.Right [name]
  attributeSymbols (Call (Symbol listHead) values)
    | isSessionSystemHead "List" listHead = traverse requireSymbol values
  attributeSymbols _ = invalid
  requireSymbol (Symbol name) = P.Right name
  requireSymbol _ = invalid
  invalid =
    P.Left
      (EvaluationError "Function attributes must be a symbol or a list of symbols.")
  mapMaybeAttribute =
    foldr
      (\name retained -> maybe retained (: retained) (symbolAttributeFromName (systemAttributeSymbolName name)))
      []
functionAttributeSet _ = P.Right Set.empty

isSessionSystemHead :: Text -> Text -> Bool
isSessionSystemHead expected actual =
  actual == expected || actual == "System`" <> expected

sessionHeadExpressionIsAny :: [Text] -> Expr -> Bool
sessionHeadExpressionIsAny expected = \case
  Symbol actual -> any (`isSessionSystemHead` actual) expected
  _ -> False

restoreQualifiedSystemHead :: Text -> Text -> Expr -> Expr
restoreQualifiedSystemHead qualifiedName shortName = \case
  Call (Symbol resultHead) values
    | resultHead == shortName -> Call (Symbol qualifiedName) values
  result -> result

evaluateUpdate
  :: Text
  -> Int
  -> EvaluationSession
  -> Text
  -> (Expr -> Expr -> Expr)
  -> Expr
  -> SessionResult Expr
evaluateUpdate headName depth session name _ rhs
  | symbolHasAttribute name Protected session
      || specialSessionSettingName name /= Nothing = do
      (value, updated) <- evaluateSessionAt (depth + 1) session rhs
      Right (Call (Symbol headName) [Symbol name, value], updated)
evaluateUpdate headName depth session name constructor rhs = do
  let initialMessageCount = sessionMessageAttemptCount session
  (current, currentSession) <- evaluateSessionAt (depth + 1) session (Symbol name)
  (value, valueSession) <- evaluateSessionAt (depth + 1) currentSession rhs
  if sessionMessageAttemptCount valueSession > initialMessageCount
    then Right (Call (Symbol headName) [Symbol name, rhs], valueSession)
    else do
      let beforeResultCount = sessionMessageAttemptCount valueSession
      (result, resultSession) <-
        evaluateSessionAt (depth + 1) valueSession (constructor current value)
      if sessionMessageAttemptCount resultSession > beforeResultCount
        then Right (Call (Symbol headName) [Symbol name, rhs], resultSession)
        else Right (result, define name (ImmediateValue result) resultSession)

evaluateSessionInPlaceArithmetic
  :: Text
  -> Integer
  -> Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionInPlaceArithmetic headName delta returnOld depth session = \case
  [Symbol name]
    | not (symbolAllowsValueMutation name session) ->
        sessionFailure
          (appendSymbolMessage headName "wrsym" name "is Protected." session)
          (headName <> ": cannot modify protected symbol.")
    | otherwise -> do
        (oldValue, oldValueSession) <-
          evaluateSessionAt (depth + 1) session (Symbol name)
        (newValue, newValueSession) <-
          evaluateSessionAt
            (depth + 1)
            oldValueSession
            (Call (Symbol "Plus") [oldValue, Integer delta])
        let updated = define name (ImmediateValue newValue) newValueSession
        Right (if returnOld then oldValue else newValue, updated)
  [_] ->
    sessionFailure
      session
      (headName <> " currently expects a bare-symbol target.")
  _ ->
    sessionFailure
      session
      (headName <> " expects exactly one argument.")

inPlaceArithmeticVariants :: Map.Map Text (Integer, Bool)
inPlaceArithmeticVariants =
  Map.fromList
    [ ("Increment", (1, True))
    , ("Decrement", (-1, True))
    , ("PreIncrement", (1, False))
    , ("PreDecrement", (-1, False))
    ]

evaluateSessionAppendTo
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionAppendTo depth session = \case
  [target, item] -> do
    (currentValue, currentSession) <-
      evaluateSessionAt (depth + 1) session target
    (itemValue, itemSession) <-
      evaluateSessionAt (depth + 1) currentSession item
    case appendSessionValue currentValue itemValue of
      P.Left (EvaluationError message) -> sessionFailure itemSession message
      P.Right appended ->
        evaluateSessionAt
          (depth + 1)
          itemSession
          (Call (Symbol "Set") [target, appended])
  _ -> sessionFailure session "AppendTo expects exactly two arguments."

appendSessionValue :: Expr -> Expr -> Either EvaluationError Expr
appendSessionValue currentValue itemValue
  | Just _ <- sessionAssociationEntries currentValue =
      if isSessionAssociationItem itemValue
        then
          let appendCall =
                Call (Symbol "Append") [currentValue, itemValue]
           in case reduceEvaluatedCall appendCall of
                P.Right result
                  | result /= appendCall -> P.Right result
                _ -> invalidAssociationItem
        else invalidAssociationItem
 where
  invalidAssociationItem =
    P.Left
      ( EvaluationError
          "Append expects a rule when appending to an Association."
      )
appendSessionValue currentValue itemValue = case currentValue of
  Call expressionHead values ->
    P.Right
      ( Call
          expressionHead
          (appendSessionArguments expressionHead (values <> [itemValue]))
      )
  _ -> P.Left (EvaluationError "Append expects a nonatomic expression.")

appendSessionArguments :: Expr -> [Expr] -> [Expr]
appendSessionArguments expressionHead values = case expressionHead of
  Symbol headName ->
    let spliced
          | headName
              `elem` ["HoldComplete", "Rule", "RuleDelayed", "Unevaluated"] =
              values
          | otherwise = concatMap spliceArgument values
     in if isSessionSystemHead "Association" headName
            || isSessionSystemHead "List" headName
          then filter (/= Symbol "Nothing") spliced
          else spliced
  _ -> values
 where
  spliceArgument = \case
    Call (Symbol sequenceHead) sequenceValues
      | isSessionSystemHead "Sequence" sequenceHead -> sequenceValues
    Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues]
      | isSessionSystemHead "Splice" spliceHead
      , isSessionSystemHead "List" listHead
      , expressionHead == Symbol "List" -> spliceValues
    Call (Symbol spliceHead) [Call (Symbol listHead) spliceValues, target]
      | isSessionSystemHead "Splice" spliceHead
      , isSessionSystemHead "List" listHead
      , target == expressionHead -> spliceValues
    value -> [value]

isSessionAssociationItem :: Expr -> Bool
isSessionAssociationItem = \case
  Call (Symbol ruleHead) [_, _] ->
    isSessionSystemHead "Rule" ruleHead
      || isSessionSystemHead "RuleDelayed" ruleHead
  _ -> False

updateConstructors :: Map.Map Text (Expr -> Expr -> Expr)
updateConstructors =
  Map.fromList
    [ ("AddTo", call2 "Plus")
    , ("SubtractFrom", \lhs rhs -> call2 "Plus" lhs (call2 "Times" (Integer (-1)) rhs))
    , ("TimesBy", call2 "Times")
    , ("DivideBy", \lhs rhs -> call2 "Times" lhs (call2 "Power" rhs (Integer (-1))))
    ]

call2 :: Text -> Expr -> Expr -> Expr
call2 headName lhs rhs = Call (Symbol headName) [lhs, rhs]

sessionFailure :: EvaluationSession -> Text -> SessionResult value
sessionFailure session message =
  Left (SessionEvaluationFailure (EvaluationError message) session)

recoverEvaluationFailure :: Expr -> SessionResult Expr -> SessionResult Expr
recoverEvaluationFailure expression result = inspectRuntimeResult result $ \case
  P.Left (SessionEvaluationFailure evaluationError stoppedSession) ->
    Right
      ( expression
      , appendEvaluationMessage expression evaluationError stoppedSession
      )
  P.Left evaluationExit -> Left evaluationExit
  P.Right success -> Right success

appendEvaluationMessage
  :: Expr
  -> EvaluationError
  -> EvaluationSession
  -> EvaluationSession
appendEvaluationMessage expression (EvaluationError messageText) session =
  appendNamedMessage headName "error" messageText session
 where
  headName = case expression of
    Call (Symbol symbolName') _ -> canonicalMessageHeadName symbolName'
    Symbol symbolName' -> canonicalMessageHeadName symbolName'
    _ -> "General"

  canonicalMessageHeadName name
    | isSystemSymbol name = maybe name id (normalizeSystemSymbolName name)
    | otherwise = name

appendNamedMessage :: Text -> Text -> Text -> EvaluationSession -> EvaluationSession
appendNamedMessage headName tag messageText session =
  appendSessionMessage
    ( Call
        (Symbol "MessageName")
        [Symbol headName, String tag]
    )
    messageText
    session

appendSessionMessage :: Expr -> Text -> EvaluationSession -> EvaluationSession
appendSessionMessage fullName messageText session =
  if sessionMessageIsDisabled fullName attempted
    then attempted
    else recordEnabledSessionMessage fullName messageText attempted
 where
  attempted =
    session
      { sessionMessageAttemptCount = sessionMessageAttemptCount session + 1
      }

appendEnabledSessionMessage
  :: Expr
  -> Text
  -> EvaluationSession
  -> EvaluationSession
appendEnabledSessionMessage fullName messageText session =
  recordEnabledSessionMessage fullName messageText attempted
 where
  attempted =
    session
      { sessionMessageAttemptCount = sessionMessageAttemptCount session + 1
      }

recordEnabledSessionMessage
  :: Expr
  -> Text
  -> EvaluationSession
  -> EvaluationSession
recordEnabledSessionMessage fullName messageText attempted =
  case suppressedDepth of
    Nothing ->
      recorded
        { sessionVisibleMessages =
            sessionVisibleMessages recorded <> [message]
        }
    Just _ -> recorded
 where
  suppressedDepth =
    quietSuppressionDepth fullName (sessionQuietScopes attempted)
  recorded =
    attempted
      { sessionGeneratedMessages =
          sessionGeneratedMessages attempted <> [message]
      , sessionMessageCollectors =
          map
            (collectSessionMessage suppressedDepth fullName message)
            (sessionMessageCollectors attempted)
      }
  messageName = sessionMessageDisplayName fullName
  message =
    EvaluationMessage
      { evaluationMessageName = messageName
      , evaluationMessageFullName = fullName
      , evaluationMessageText = messageName <> ": " <> messageText
      }

collectSessionMessage
  :: Maybe Int
  -> Expr
  -> EvaluationMessage
  -> MessageCollector
  -> MessageCollector
collectSessionMessage suppressedDepth fullName message collector =
  if visibleToCollector && sessionMessageSpecificationMatches specification fullName
    then
      collector
        { messageCollectorMessages =
            messageCollectorMessages collector <> [message]
        }
    else collector
 where
  specification = messageCollectorSpecification collector
  visibleToCollector = case suppressedDepth of
    Nothing -> True
    Just depth -> messageCollectorQuietDepth collector >= depth

quietSuppressionDepth :: Expr -> [QuietScope] -> Maybe Int
quietSuppressionDepth fullName scopes =
  decide (zip [length scopes, length scopes - 1 .. 1] (reverse scopes))
 where
  decide [] = Nothing
  decide ((depth, scope) : rest)
    | sessionMessageSpecificationMatches
        (quietScopeOnSpecification scope)
        fullName = Nothing
    | sessionMessageSpecificationMatches
        (quietScopeOffSpecification scope)
        fullName = Just depth
    | otherwise = decide rest

sessionMessageSpecificationMatches :: Expr -> Expr -> Bool
sessionMessageSpecificationMatches specification fullName =
  case specification of
    Symbol "All" -> True
    Symbol "None" -> False
    Symbol _ ->
      sessionMessageSpecificationMatches
        (Call (Symbol "MessageName") [specification, String "trace"])
        fullName
    String _ -> False
    Call (Symbol listHead) values
      | isSessionSystemHead "List" listHead ->
          any (`sessionMessageSpecificationMatches` fullName) values
    Call (Symbol messageHead) _
      | isSessionSystemHead "MessageName" messageHead ->
          specification == fullName
            || componentsMatch
    _ -> False
 where
  componentsMatch =
    case (messageNameComponents specification, messageNameComponents fullName) of
      (Just ("General", specificationTags), Just (_, nameTags))
        | not (null specificationTags)
        , not (null nameTags) -> last specificationTags == last nameTags
      (Just specificationComponents, Just nameComponents) ->
        specificationComponents == nameComponents
      _ -> False

sessionMessageIsDisabled :: Expr -> EvaluationSession -> Bool
sessionMessageIsDisabled messageName session =
  Set.member (fullForm messageName) disabled
    || maybe False generalTagIsDisabled (messageNameComponents messageName)
 where
  disabled = sessionDisabledMessages session
  generalTagIsDisabled (_, []) = False
  generalTagIsDisabled (_, tags) =
    Set.member
      ( fullForm
          ( Call
              (Symbol "MessageName")
              [Symbol "General", String (last tags)]
          )
      )
      disabled

messageNameComponents :: Expr -> Maybe (Text, [Text])
messageNameComponents = \case
  Call (Symbol messageHead) (base : tags@(_ : _))
    | isSessionSystemHead "MessageName" messageHead -> do
        tagNames <- traverse messageTagName tags
        Just (fullForm base, tagNames)
  _ -> Nothing
 where
  messageTagName (String value) = Just value
  messageTagName (Symbol value) = Just value
  messageTagName _ = Nothing

sessionMessageDisplayName :: Expr -> Text
sessionMessageDisplayName expression = case expression of
  Call (Symbol messageHead) values
    | isSessionSystemHead "MessageName" messageHead
    , Just _ <- messageNameComponents expression ->
        inputForm (Call (Symbol "MessageName") values)
  _ -> inputForm expression

appendSymbolMessage
  :: Text
  -> Text
  -> Text
  -> Text
  -> EvaluationSession
  -> EvaluationSession
appendSymbolMessage headName tag name suffix =
  appendNamedMessage
    headName
    tag
    ("Symbol " <> displaySessionSymbolName name <> " " <> suffix)

displaySessionSymbolName :: Text -> Text
displaySessionSymbolName name = maybe name id (visibleContextShortName name)

visibleContextShortName :: Text -> Maybe Text
visibleContextShortName name =
  strip "System`" `orElse` strip "Global`"
 where
  strip prefix = do
    shortName <- T.stripPrefix prefix name
    if T.null shortName || "`" `T.isInfixOf` shortName
      then Nothing
      else Just shortName
  orElse Nothing fallback = fallback
  orElse value _ = value

systemAttributeSymbolName :: Text -> Text
systemAttributeSymbolName name
  | isSystemSymbol name = maybe name id (normalizeSystemSymbolName name)
  | otherwise = name

liftPureEvaluation
  :: EvaluationSession
  -> Either EvaluationError value
  -> RuntimeResult EvaluationExit value
liftPureEvaluation session =
  either
    (\evaluationFailure ->
        Left (SessionEvaluationFailure evaluationFailure session)
    )
    Right

mapEvaluationExitSession
  :: (EvaluationSession -> EvaluationSession)
  -> EvaluationExit
  -> EvaluationExit
mapEvaluationExitSession updateSession = \case
  SessionEvaluationFailure evaluationFailure failedSession ->
    SessionEvaluationFailure evaluationFailure (updateSession failedSession)
  SessionControl controlSignal stoppedSession ->
    SessionControl controlSignal (updateSession stoppedSession)

evaluateTargetedReturn
  :: Text
  -> Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateTargetedReturn target depth session body =
  inspectRuntimeResult (evaluateSessionAt (depth + 1) session body) $ \case
    P.Left (SessionControl (Returned value (Just actualTarget)) stoppedSession)
      | actualTarget == target -> Right (value, stoppedSession)
    P.Left evaluationExit -> Left evaluationExit
    P.Right success -> Right success

logicalResult :: Text -> Expr -> [Expr] -> Expr
logicalResult _ identity [] = identity
logicalResult _ _ [single] = single
logicalResult headName _ values = Call (Symbol headName) values

define :: Text -> Definition -> EvaluationSession -> EvaluationSession
define name value session =
  modifySymbolValues
    name
    ( \values ->
        values
          { symbolOwnValue = Just value
          , symbolOwnValuePattern =
              Just (Symbol (displaySessionSymbolName name))
          }
    )
    session

defineCompoundValue
  :: CompoundValueSlot
  -> Text
  -> DownValue
  -> EvaluationSession
  -> EvaluationSession
defineCompoundValue slot name definition session =
  modifySymbolValues
    name
    (insertDefinition valuesForSlot updateSlot)
    session
 where
  valuesForSlot = compoundValuesFrom slot
  updateSlot values definitions = case slot of
    DownValueSlot -> values {symbolDownValues = definitions}
    UpValueSlot -> values {symbolUpValues = definitions}
    SubValueSlot -> values {symbolSubValues = definitions}
  insertDefinition select update values =
    update values (insertDownValue definition (select values))

insertDownValue :: DownValue -> [DownValue] -> [DownValue]
insertDownValue definition = replaceOrInsert
 where
  replaceOrInsert [] = [definition]
  replaceOrInsert (existing : rest)
    | downValuePattern existing == downValuePattern definition
    , downValueConditionKey existing == downValueConditionKey definition =
        definition : rest
    | downValueSpecificity (downValuePattern definition)
        < downValueSpecificity (downValuePattern existing) =
        definition : existing : rest
    | otherwise = existing : replaceOrInsert rest

downValueConditionKey :: DownValue -> Maybe Expr
downValueConditionKey definition = case downValueBody definition of
  Call (Symbol conditionHead) [_, condition]
    | isSessionSystemHead "Condition" conditionHead -> Just condition
  _ -> Nothing

downValueSpecificity :: Expr -> Int
downValueSpecificity = \case
  Call (Symbol "HoldPattern") [inner] -> downValueSpecificity inner
  Call (Symbol "Pattern") [_, inner] -> downValueSpecificity inner
  Call (Symbol "Blank") arguments' -> if null arguments' then 20 else 12
  Call (Symbol "BlankSequence") arguments' ->
    30 + sum (map downValueSpecificity arguments')
  Call (Symbol "BlankNullSequence") arguments' ->
    35 + sum (map downValueSpecificity arguments')
  Call (Symbol conditionHead) [inner, _]
    | isSessionSystemHead "Condition" conditionHead ->
        2 + downValueSpecificity inner
  Call (Symbol "PatternTest") [inner, _] -> 3 + downValueSpecificity inner
  Call (Symbol "Optional") (inner : _) -> 5 + downValueSpecificity inner
  Call (Symbol "Alternatives") alternatives ->
    4 + minimumOrZero (map downValueSpecificity alternatives)
  Call (Symbol repetitionHead) (inner : _)
    | repetitionHead `elem` ["Repeated", "RepeatedNull"] ->
        25 + downValueSpecificity inner
  Call _ arguments' -> sum (map downValueSpecificity arguments')
  _ -> 0
 where
  minimumOrZero [] = 0
  minimumOrZero values = minimum values

hasCompoundValue
  :: CompoundValueSlot
  -> Text
  -> Expr
  -> EvaluationSession
  -> Bool
hasCompoundValue slot name patternExpression session =
  any
    ((== patternExpression) . downValuePattern)
    (compoundValuesFor slot name session)

removeCompoundValue
  :: CompoundValueSlot
  -> Text
  -> Expr
  -> EvaluationSession
  -> EvaluationSession
removeCompoundValue slot name patternExpression session =
  modifySymbolValues
    name
    removeMatching
    session
 where
  removeMatching values =
    let retained =
          filter
            ((/= patternExpression) . downValuePattern)
            (compoundValuesFrom slot values)
     in case slot of
          DownValueSlot -> values {symbolDownValues = retained}
          UpValueSlot -> values {symbolUpValues = retained}
          SubValueSlot -> values {symbolSubValues = retained}

removeOwnValues :: [Text] -> EvaluationSession -> EvaluationSession
removeOwnValues names session =
  foldl
    ( \updated name ->
        modifySymbolValues
          name
          ( \values ->
              values
                { symbolOwnValue = Nothing
                , symbolOwnValuePattern = Nothing
                }
          )
          updated
    )
    session
    names

clearDefinitions :: [Text] -> EvaluationSession -> EvaluationSession
clearDefinitions names session =
  foldl
    (\updated name -> setSymbolValues name emptySymbolValues updated)
    session
    names

snapshotSymbolValues :: Text -> EvaluationSession -> SymbolValueSnapshot
snapshotSymbolValues name session =
  SymbolValueSnapshot
    { snapshotValues = symbolValuesFor name session
    }

restoreSymbolValues
  :: Text
  -> SymbolValueSnapshot
  -> EvaluationSession
  -> EvaluationSession
restoreSymbolValues name snapshot session =
  setSymbolValues name (snapshotValues snapshot) session

emptySymbolValues :: SymbolValues
emptySymbolValues =
  SymbolValues
    { symbolOwnValue = Nothing
    , symbolOwnValuePattern = Nothing
    , symbolDownValues = []
    , symbolUpValues = []
    , symbolSubValues = []
    , symbolNValues = []
    }

specialSessionSettingDefaults :: [(Text, Expr)]
specialSessionSettingDefaults =
  [ ("$RecursionLimit", Integer 1024)
  , ("$IterationLimit", Integer 4096)
  , ("$HistoryLength", Symbol "Infinity")
  , ("$MaxExtraPrecision", Integer 50)
  , ("$MaxRootDegree", Integer 1000)
  , ("$OutputSizeLimit", Integer 12000)
  ]

specialSessionOwnValueDefaults :: [(Text, Expr)]
specialSessionOwnValueDefaults =
  specialSessionSettingDefaults
    <> [("$MessagePrePrint", Symbol "Automatic")]

specialSessionSettingName :: Text -> Maybe Text
specialSessionSettingName name = do
  shortName <-
    if isSystemSymbol name
      then normalizeSystemSymbolName name
      else Nothing
  case lookup shortName specialSessionSettingDefaults of
    Just _ -> Just shortName
    Nothing -> Nothing

validSpecialSessionSetting :: Text -> Expr -> Bool
validSpecialSessionSetting "$MaxRootDegree" (Integer value) =
  value >= 1 && value <= 9223372036854775807
validSpecialSessionSetting "$MaxRootDegree" _ = False
validSpecialSessionSetting name (Symbol infinityName)
  | isSessionSystemHead "Infinity" infinityName =
      name /= "$MaxRootDegree"
validSpecialSessionSetting name (Integer value) =
  maybe False (value >=) (lookup name minimums)
 where
  minimums =
    [ ("$RecursionLimit", 20)
    , ("$IterationLimit", 20)
    , ("$HistoryLength", 0)
    , ("$MaxExtraPrecision", 0)
    , ("$OutputSizeLimit", 0)
    ]
validSpecialSessionSetting _ _ = False

currentSpecialSessionSettingValue :: Text -> EvaluationSession -> Expr
currentSpecialSessionSettingValue name session =
  case symbolOwnValueFor name session of
    Just (ImmediateValue value) -> value
    Just (DelayedValue value) -> value
    Nothing -> maybe (Symbol name) id (lookup name specialSessionSettingDefaults)

sessionHistoryLengthLimit :: EvaluationSession -> Maybe Integer
sessionHistoryLengthLimit session =
  case currentSpecialSessionSettingValue "$HistoryLength" session of
    Integer value -> Just value
    _ -> Nothing

appendSpecialSettingLimitMessage
  :: Text
  -> Expr
  -> EvaluationSession
  -> EvaluationSession
appendSpecialSettingLimitMessage name value =
  appendNamedMessage
    name
    "limset"
    ("Cannot set " <> name <> " to " <> inputForm value <> ".")

exceedsSessionRecursionLimit :: Int -> EvaluationSession -> Bool
exceedsSessionRecursionLimit depth session =
  case currentSpecialSessionSettingValue "$RecursionLimit" session of
    Symbol infinityName
      | isSessionSystemHead "Infinity" infinityName -> False
    Integer limit -> toInteger depth > limit
    _ -> depth > 1024

emptySymbolState :: SymbolState
emptySymbolState =
  SymbolState
    { symbolKnown = False
    , symbolAttributeOverride = Nothing
    , symbolValues = emptySymbolValues
    }

symbolStateFor :: Text -> EvaluationSession -> SymbolState
symbolStateFor name session =
  Map.findWithDefault
    emptySymbolState
    (resolvedSymbolStorageName name session)
    (sessionSymbols session)

symbolValuesFor :: Text -> EvaluationSession -> SymbolValues
symbolValuesFor name = symbolValues . symbolStateFor name

symbolOwnValueFor :: Text -> EvaluationSession -> Maybe Definition
symbolOwnValueFor name = symbolOwnValue . symbolValuesFor name

symbolOwnValuePatternFor :: Text -> EvaluationSession -> Maybe Expr
symbolOwnValuePatternFor name = symbolOwnValuePattern . symbolValuesFor name

compoundValuesFrom :: CompoundValueSlot -> SymbolValues -> [DownValue]
compoundValuesFrom DownValueSlot = symbolDownValues
compoundValuesFrom UpValueSlot = symbolUpValues
compoundValuesFrom SubValueSlot = symbolSubValues

compoundValuesFor
  :: CompoundValueSlot
  -> Text
  -> EvaluationSession
  -> [DownValue]
compoundValuesFor slot name = compoundValuesFrom slot . symbolValuesFor name

modifySymbolState
  :: Text
  -> (SymbolState -> SymbolState)
  -> EvaluationSession
  -> EvaluationSession
modifySymbolState name update session =
  let storageName = resolvedSymbolStorageName name session
      updatedState =
        update
          ( Map.findWithDefault
              emptySymbolState
              storageName
              (sessionSymbols session)
          )
      updatedSymbols =
        if updatedState == emptySymbolState
          then Map.delete storageName (sessionSymbols session)
          else Map.insert storageName updatedState (sessionSymbols session)
   in session {sessionSymbols = updatedSymbols}

modifySymbolValues
  :: Text
  -> (SymbolValues -> SymbolValues)
  -> EvaluationSession
  -> EvaluationSession
modifySymbolValues name update =
  modifySymbolState
    name
    ( \state ->
        state
          { symbolKnown = True
          , symbolValues = update (symbolValues state)
          }
    )

setSymbolValues :: Text -> SymbolValues -> EvaluationSession -> EvaluationSession
setSymbolValues name values =
  modifySymbolState
    name
    (\state -> state {symbolKnown = True, symbolValues = values})

currentSessionContext :: Text
currentSessionContext = "Global`"

currentSessionContextPath :: [Text]
currentSessionContextPath = ["System`", currentSessionContext]

validSessionSymbolShortName :: Text -> Bool
validSessionSymbolShortName name = case T.uncons name of
  Just (first, remaining) ->
    (isAlpha first || first == '$')
      && T.all
        (\character -> isAlphaNum character || character == '$')
        remaining
  Nothing -> False

validSessionContextName :: Text -> Bool
validSessionContextName context
  | not ("`" `T.isSuffixOf` context) = False
  | otherwise =
      let components = T.splitOn "`" (T.dropEnd 1 context)
       in not (null components)
            && all validSessionSymbolShortName components

splitSessionSymbolFullName :: Text -> Maybe (Text, Text)
splitSessionSymbolFullName name =
  let (context, shortName) = T.breakOnEnd "`" name
   in if T.null context
        then Nothing
        else Just (context, shortName)

validSessionSymbolName :: Text -> Bool
validSessionSymbolName name =
  case splitSessionSymbolFullName name of
    Just (context, shortName) ->
      validSessionContextName context
        && validSessionSymbolShortName shortName
    Nothing -> validSessionSymbolShortName name

sessionStorageFullName :: Text -> Maybe Text
sessionStorageFullName storageName
  | not (validSessionSymbolName storageName) = Nothing
  | "`" `T.isInfixOf` storageName = Just storageName
  | isSystemSymbol storageName = Just ("System`" <> storageName)
  | otherwise = Just (currentSessionContext <> storageName)

resolvedSessionSymbolFullName
  :: Text
  -> EvaluationSession
  -> Maybe Text
resolvedSessionSymbolFullName name session
  | isSystemSymbol name
  , Just shortName <- normalizeSystemSymbolName name =
      Just ("System`" <> shortName)
  | validSessionSymbolName name =
      sessionStorageFullName (resolvedSymbolStorageName name session)
  | otherwise = Nothing

existingSessionSymbolFullName
  :: Text
  -> EvaluationSession
  -> Maybe Text
existingSessionSymbolFullName name session = do
  fullName <- resolvedSessionSymbolFullName name session
  if isKnownSessionFullName fullName session
    then Just fullName
    else Nothing

isKnownSessionFullName :: Text -> EvaluationSession -> Bool
isKnownSessionFullName fullName session =
  case splitSessionSymbolFullName fullName of
    Just ("System`", shortName)
      | isSystemSymbol shortName -> True
    _ -> symbolKnown (symbolStateFor fullName session)

knownSessionFullNames :: EvaluationSession -> [Text]
knownSessionFullNames session =
  Set.toAscList
    ( Map.foldrWithKey
        addRegistered
        catalogNames
        (sessionSymbols session)
    )
 where
  catalogNames =
    Set.fromList ["System`" <> name | name <- systemSymbolNames]

  addRegistered storageName state retained
    | symbolKnown state =
        case sessionStorageFullName storageName of
          Just fullName -> Set.insert fullName retained
          Nothing -> retained
    | otherwise = retained

knownSessionContexts :: EvaluationSession -> [Text]
knownSessionContexts session =
  Set.toAscList
    ( Set.fromList
        ( currentSessionContextPath
            <> [ context
               | fullName <- knownSessionFullNames session
               , Just (context, _) <- [splitSessionSymbolFullName fullName]
               ]
        )
    )

sessionNamePatterns :: Expr -> Maybe [Text]
sessionNamePatterns = \case
  String patternText -> Just [patternText]
  Call (Symbol listHead) values
    | isSessionSystemHead "List" listHead ->
        traverse stringPattern values
  _ -> Nothing
 where
  stringPattern (String patternText) = Just patternText
  stringPattern _ = Nothing

matchingSessionDisplayNames :: [Text] -> EvaluationSession -> [Text]
matchingSessionDisplayNames patterns session =
  Set.toAscList
    ( Set.unions
        [ matchingNames patternText
        | patternText <- patterns
        ]
    )
 where
  matchingNames patternText =
    Set.fromList
      [ displaySessionSymbolName fullName
      | fullName <- knownSessionFullNames session
      , Just (context, shortName) <- [splitSessionSymbolFullName fullName]
      , let hasExplicitContext = "`" `T.isInfixOf` patternText
      , hasExplicitContext || context `elem` currentSessionContextPath
      , let candidate = if hasExplicitContext then fullName else shortName
      , wildcardSymbolNameMatches patternText candidate
      ]

invalidSessionSymbolNameMessage :: Text -> Text
invalidSessionSymbolNameMessage name =
  "Invalid Wolfram symbol name: " <> pythonReprName name <> "."

pythonReprName :: Text -> Text
pythonReprName name =
  T.singleton quote
    <> T.concatMap (escape quote) name
    <> T.singleton quote
 where
  quote
    | "'" `T.isInfixOf` name
    , not ("\"" `T.isInfixOf` name) = '"'
    | otherwise = '\''

  escape selectedQuote character
    | character == '\\' = "\\\\"
    | character == selectedQuote = "\\" <> T.singleton character
    | character == '\n' = "\\n"
    | character == '\r' = "\\r"
    | character == '\t' = "\\t"
    | isPrint character = T.singleton character
    | codePoint <= 0xff = "\\x" <> paddedHex 2 codePoint
    | codePoint <= 0xffff = "\\u" <> paddedHex 4 codePoint
    | otherwise = "\\U" <> paddedHex 8 codePoint
   where
    codePoint = ord character

  paddedHex width value =
    let digits = T.pack (showHex value "")
     in T.replicate (width - T.length digits) "0" <> digits

registerSymbol :: Text -> EvaluationSession -> EvaluationSession
registerSymbol name =
  modifySymbolState name (\state -> state {symbolKnown = True})

symbolStorageName :: Text -> Text
symbolStorageName name
  | Just shortName <- globalSessionSymbolName name = shortName
  | isSystemSymbol name = maybe name id (normalizeSystemSymbolName name)
  | otherwise = name

resolvedSymbolStorageName :: Text -> EvaluationSession -> Text
resolvedSymbolStorageName name session
  | "`" `T.isInfixOf` name = symbolStorageName name
  | isSystemSymbol name = symbolStorageName name
  | Map.member systemName (sessionSymbols session) = systemName
  | otherwise = symbolStorageName name
 where
  systemName = "System`" <> name

globalSessionSymbolName :: Text -> Maybe Text
globalSessionSymbolName name = do
  shortName <- T.stripPrefix "Global`" name
  if T.null shortName
      || "`" `T.isInfixOf` shortName
      || isSystemSymbol shortName
    then Nothing
    else Just shortName

symbolAttributesFor :: Text -> EvaluationSession -> Set.Set SymbolAttribute
symbolAttributesFor name session =
  case symbolAttributeOverride (symbolStateFor name session) of
    Just attributes -> attributes
    Nothing -> maybe Set.empty id (systemSymbolAttributes name)

symbolHasAttribute :: Text -> SymbolAttribute -> EvaluationSession -> Bool
symbolHasAttribute name attribute = Set.member attribute . symbolAttributesFor name

symbolAllowsValueMutation :: Text -> EvaluationSession -> Bool
symbolAllowsValueMutation name session =
  not (symbolHasAttribute name Protected session)
    || isProtectedValueHook name session
    || specialSessionSettingName name /= Nothing

isProtectedValueHook :: Text -> EvaluationSession -> Bool
isProtectedValueHook name session =
  resolvedSymbolStorageName name session
    `elem` [ "$PreRead"
           , "$Pre"
           , "$Post"
           , "$PrePrint"
           , "$MessagePrePrint"
           ]

setSymbolAttributes
  :: Text
  -> Set.Set SymbolAttribute
  -> EvaluationSession
  -> EvaluationSession
setSymbolAttributes name attributes =
  modifySymbolState
    name
    ( \state ->
        state
          { symbolKnown = True
          , symbolAttributeOverride = Just attributes
          }
    )

isKnownSessionSymbol :: Text -> EvaluationSession -> Bool
isKnownSessionSymbol name session =
  isSystemSymbol name
    || symbolKnown (symbolStateFor name session)

symbolName :: Expr -> Maybe Text
symbolName (Symbol name) = Just name
symbolName _ = Nothing
