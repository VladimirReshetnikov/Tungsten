{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Immutable evaluation sessions with ordered symbol value definitions.
module Tungsten.Session
  ( Definition (..)
  , DownValue (..)
  , EvaluationMessage (..)
  , EvaluationSession (..)
  , SymbolState (..)
  , SymbolValues (..)
  , emptySession
  , evaluateInSession
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Char (isAlpha, isAlphaNum, isPrint, ord)
import Data.List (sortBy)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import Tungsten.Evaluate
import Tungsten.Expression
import Tungsten.PythonSort (pythonStableSortByState)
import Tungsten.SystemSymbols
  ( SymbolAttribute (..)
  , isSystemSymbol
  , normalizeSystemSymbolName
  , symbolAttributeFromName
  , symbolAttributeName
  , systemSymbolAttributes
  , systemSymbolNames
  )

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
  , sessionGeneratedMessages :: ![EvaluationMessage]
  , sessionVisibleMessages :: ![EvaluationMessage]
  , sessionPrints :: ![Text]
  }
  deriving (Eq, Show)

emptySession :: EvaluationSession
emptySession = EvaluationSession initialSessionSymbols 0 Set.empty [] [] []

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
  | BreakSignal
  | ContinueSignal
  | Returned !Expr !(Maybe Text)
  deriving (Eq, Show)

data EvaluationExit
  = SessionEvaluationFailure !EvaluationError !EvaluationSession
  | SessionControl !ControlSignal !EvaluationSession
  deriving (Eq, Show)

type SessionResult value =
  Either EvaluationExit (value, EvaluationSession)

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

evaluateInSession :: EvaluationSession -> Expr -> Either EvaluationError (Expr, EvaluationSession)
evaluateInSession session expression =
  let registeredSession = registerExpressionSymbols expression session
   in finalizeSessionResult
        ( evaluateSessionAt
            0
            registeredSession
              { sessionGeneratedMessages = []
              , sessionVisibleMessages = []
              , sessionPrints = []
              }
            expression
        )

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

finalizeSessionResult
  :: SessionResult Expr
  -> Either EvaluationError (Expr, EvaluationSession)
finalizeSessionResult = \case
    Left (SessionEvaluationFailure evaluationFailure _) -> Left evaluationFailure
    Left (SessionControl (Thrown value tag handler) stoppedSession) ->
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
    Left (SessionControl BreakSignal stoppedSession) ->
      Right (Call (Symbol "Break") [], stoppedSession)
    Left (SessionControl ContinueSignal stoppedSession) ->
      Right (Call (Symbol "Continue") [], stoppedSession)
    Left (SessionControl (Returned value target) stoppedSession) ->
      Right
        ( Call
            (Symbol "Return")
            (value : maybe [] (pure . Symbol) target)
        , stoppedSession
        )
    Right result -> Right result

evaluateSessionAt
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionAt depth session expression
  | exceedsSessionRecursionLimit depth session =
      sessionFailure session "the session evaluation recursion limit was exceeded"
  | otherwise =
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
        evaluateSequence depth session expressions
      Call (Symbol "If") arguments' -> evaluateSessionIf depth session arguments'
      Call (Symbol "And") arguments' -> evaluateSessionAnd depth session arguments'
      Call (Symbol "Or") arguments' -> evaluateSessionOr depth session arguments'
      Call (Symbol "Catch") arguments' ->
        evaluateSessionCatch depth session arguments'
      Call (Symbol "Throw") arguments' ->
        evaluateSessionThrow depth session arguments'
      Call (Symbol "Break") arguments' ->
        evaluateLoopControl BreakSignal "Break" session arguments'
      Call (Symbol "Continue") arguments' ->
        evaluateLoopControl ContinueSignal "Continue" session arguments'
      Call (Symbol "Return") arguments' ->
        evaluateSessionReturn depth session arguments'
      Call (Symbol "Print") arguments' ->
        evaluateSessionPrint depth session arguments'
      Call (Symbol "Evaluate") arguments' ->
        evaluateSessionEvaluate depth session arguments'
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
restoreActiveOwnValues active = \case
  Right (value, session) ->
    Right (value, session {sessionActiveOwnValues = active})
  Left evaluationExit ->
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
  (preparedArguments, argumentsSession) <-
    evaluateCallArgumentsWithAttributes
      depth
      headSession
      evaluatedHead
      arguments'
  let normalizedCall =
        normalizeSessionAttributeCall
          argumentsSession
          evaluatedHead
          preparedArguments
      normalizedArguments = case normalizedCall of
        Call _ values -> values
        _ -> preparedArguments
      allowSystemDispatch =
        evaluatedHeadAllowsDispatch expressionHead evaluatedHead
  case threadSessionListableCall depth argumentsSession normalizedCall of
    Just sessionResult -> sessionResult
    Nothing -> case evaluatedHead of
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
  , "And"
  , "AtomQ"
  , "ByteArrayQ"
  , "Context"
  , "Contexts"
  , "Equal"
  , "EvenQ"
  , "Greater"
  , "GreaterEqual"
  , "IntegerQ"
  , "Inequality"
  , "Less"
  , "LessEqual"
  , "Max"
  , "Min"
  , "N"
  , "NameQ"
  , "Names"
  , "Not"
  , "NumberQ"
  , "OddQ"
  , "Or"
  , "Plus"
  , "Power"
  , "Sign"
  , "Sqrt"
  , "StringQ"
  , "Symbol"
  , "SymbolName"
  , "Times"
  , "Unequal"
  , "Unique"
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
             , "And"
             , "Or"
             , "Catch"
             , "Throw"
             , "Break"
             , "Continue"
             , "Return"
             , "Print"
             , "Evaluate"
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
      | length extras <= 1 -> do
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
  headName -> headName <> " received an unsupported argument list."

patternFailure :: EvaluationSession -> Text -> Either EvaluationExit value
patternFailure session message =
  Left (SessionEvaluationFailure (EvaluationError message) session)

sessionLevelBounds
  :: EvaluationSession
  -> Expr
  -> Either EvaluationExit LevelBounds
sessionLevelBounds session specification =
  case normalizeLevelSpec specification of
    Left (EvaluationError message) ->
      Left (SessionEvaluationFailure (EvaluationError message) session)
    Right bounds -> Right bounds

patternSelectionLimit
  :: Text
  -> EvaluationSession
  -> Maybe Expr
  -> Either EvaluationExit (Maybe Integer)
patternSelectionLimit operation session limit =
  case selectionLimit operation limit of
    Left (EvaluationError message) ->
      Left (SessionEvaluationFailure (EvaluationError message) session)
    Right normalized -> Right normalized

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
  bounds <- case extras of
    [] -> sessionLevelBounds session (Call (Symbol "List") [Integer 1])
    [specification] -> sessionLevelBounds session specification
    _ -> patternFailure session "MemberQ expects two or three arguments."
  (found, updated) <-
    firstSessionMatch
      depth
      session
      bounds
      patternExpression
      (collectPatternRecords False 0 subject)
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
  -> Either EvaluationExit Expr
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
  -> Either EvaluationExit [SessionPatternRule]
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
  Call (Symbol "AssociationMap") values ->
    Just (evaluateSessionAssociationMap depth session values)
  Call (Symbol "Apply") values ->
    Just (evaluateSessionApply depth session values)
  Call (Symbol "KeyMap") values ->
    Just (evaluateSessionKeyMap depth session values)
  Call (Symbol "KeyValueMap") values ->
    Just (evaluateSessionKeyValueMap depth session values)
  Call (Symbol "Map") values ->
    Just (evaluateSessionMap depth session values)
  Call (Symbol "MapAt") values ->
    Just (evaluateSessionMapAt depth session values)
  Call (Symbol "Total") values ->
    Just (evaluateSessionTotal depth session values)
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
  Call (Symbol "TakeWhile") values ->
    Just (evaluateSessionTakeWhile depth session values)
  Call (Symbol "LengthWhile") values ->
    Just (evaluateSessionLengthWhile depth session values)
  Call (Symbol "KeySelect") values ->
    Just (evaluateSessionKeySelect depth session values)
  _ -> Nothing

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
mapSessionResultValue update = \case
  Right (value, session) -> Right (update value, session)
  Left evaluationExit -> Left evaluationExit

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
renderPrintValue (String value) = value
renderPrintValue expression = inputForm expression

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
  Symbol "Nothing" -> Right (Symbol "Nothing", session)
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
            Just selected ->
              evaluateSessionAt
                (depth + 1)
                session
                (sessionItemValue selected)
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

evaluateSessionMap
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMap depth session = \case
  [function, subject] -> case sessionOrderedCollection subject of
    Nothing -> Right (subject, session)
    Just collection -> do
      (mapped, updated) <- mapItems function [] session (sessionCollectionItems collection)
      Right (rebuildSessionCollection collection mapped, updated)
  [function, subject, levelSpecification] -> do
    (bounds, boundsSession) <-
      liftSessionLevelBounds
        session
        levelSpecification
    evaluateSessionMapLevels
      depth
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
    Left message -> sessionFailure session message
    Right bounds -> Right (bounds, session)

normalizeSessionLevelSpec :: Expr -> Either Text SessionLevelBounds
normalizeSessionLevelSpec specification = case specification of
  Integer level
    | level >= 0 ->
        Right
          ( SessionLevelBounds
              (if level == 0 then 0 else 1)
              (boundedSessionLevel level)
          )
    | otherwise ->
        Right (SessionLevelBounds 1 (boundedSessionLevel level))
  Symbol "Infinity" -> Right (SessionLevelBounds 1 sessionLevelInfinity)
  Call (Symbol "List") [bound] -> do
    value <- normalizeSessionLevelBound bound
    Right (SessionLevelBounds value value)
  Call (Symbol "List") [lower, upper]
    | isSessionLevelBound lower
    , isSessionLevelBound upper ->
        SessionLevelBounds
          <$> normalizeSessionLevelBound lower
          <*> normalizeSessionLevelBound upper
  _ ->
    Left
      ( "Unsupported Level specification: '"
          <> inputForm specification
          <> "'."
      )

normalizeSessionLevelBound :: Expr -> Either Text Int
normalizeSessionLevelBound = \case
  Integer value -> Right (boundedSessionLevel value)
  Symbol "Infinity" -> Right sessionLevelInfinity
  value -> Left ("Unsupported level bound: " <> inputForm value <> ".")

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
  -> Expr
  -> SessionLevelBounds
  -> Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionMapLevels depth function bounds positive session expression =
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
        let rebuilt = normalizeEvaluatedCall expressionHead mappedValues
        if sessionLevelMatches bounds positive expression
          then evaluateSessionCallable depth updated function [rebuilt]
          else Right (rebuilt, updated)
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

evaluateSessionMapAt
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionMapAt depth session = \case
  [function, subject, positions] ->
    case expandSessionPositionPaths subject positions of
      Left message -> sessionFailure session message
      Right (resolvedPaths, invalid)
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
        Call (Symbol "List") pathExpressions ->
          expandPaths [] False pathExpressions
        _ -> unsupportedPositionSpecification specification
  | isSingleSessionPositionSpecification specification =
      expandSessionExactPath
        expression
        (sessionPositionComponents specification)
  | otherwise = unsupportedPositionSpecification specification
 where
  expandPaths retained invalid [] = Right (retained, invalid)
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
expandSessionExactPath _ [] = Right ([[]], False)
expandSessionExactPath expression (component : remaining) = do
  (selections, selectionInvalid) <-
    resolveSessionPathComponent expression component
  expandSelections [] selectionInvalid selections
 where
  expandSelections retained invalid [] = Right (retained, invalid)
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
  Left "Position does not support index 0 in this position."
resolveSessionPathComponent expression component =
  case sessionOrderedCollection expression of
    Nothing -> Right ([], True)
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
          Right
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
resolveSessionAssociationComponent items component@(Call (Symbol "List") selectors) =
  case traverse sessionAssociationSelectorKind selectors of
    Nothing -> unsupportedSelectorInsidePosition component
    Just kinds
      | any id kinds && any not kinds ->
          Left "Association selector lists may not mix numeric and key selectors."
      | any id kinds ->
          selectKeys
            (mapMaybeSession sessionKeySelectorValue selectors)
      | otherwise -> selectNumeric
 where
  selectNumeric = do
    (indices, invalid) <-
      resolveSessionNumericSelectors (length items) component
    Right
      (mapMaybeSession (sessionSelectionAt items) indices, invalid)

  selectKeys keys = selectSessionAssociationKeys items keys
resolveSessionAssociationComponent items component = do
  (indices, invalid) <-
    resolveSessionNumericSelectors (length items) component
  Right (mapMaybeSession (sessionSelectionAt items) indices, invalid)

selectSessionAssociationKeys
  :: [SessionOrderedItem]
  -> [Expr]
  -> Either Text ([SessionPathSelection], Bool)
selectSessionAssociationKeys items = go [] False
 where
  go retained invalid [] = Right (retained, invalid)
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
    Left "Position does not support index 0 in this position."
  Integer position ->
    Right
      ( maybe [] pure resolved
      , maybe True (const False) resolved
      )
   where
    resolved = resolveSessionPosition count position
  Symbol "All" -> Right ([0 .. count - 1], False)
  spanSpecification@(Call (Symbol "Span") _) -> do
    positions <- expandSessionPositionSpan count spanSpecification
    let resolved = map (resolveSessionPosition count) positions
    Right
      ( mapMaybeSession id resolved
      , any (maybe True (const False)) resolved
      )
  Call (Symbol "List") selectors -> appendSelectors [] False selectors
  _ ->
    Left
      ( "Unsupported Position specification: "
          <> inputForm component
          <> "."
      )
 where
  appendSelectors retained invalid [] = Right (retained, invalid)
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
expandSessionPositionSpan count (Call (Symbol "Span") arguments') =
  case arguments' of
    [startExpression, endExpression] ->
      expand startExpression endExpression (Integer 1)
    [startExpression, endExpression, stepExpression] ->
      expand startExpression endExpression stepExpression
    _ -> Left "Span must contain two or three arguments."
 where
  expand startExpression endExpression stepExpression = do
    step <- case stepExpression of
      Integer value -> Right value
      _ -> Left "Span steps must be integers."
    if step == 0
      then Left "Span step cannot be zero."
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
expandSessionPositionSpan _ _ = Left "Span must contain two or three arguments."

isSessionPositionCollection :: Expr -> Bool
isSessionPositionCollection (Call (Symbol "List") values) =
  not (null values) && all isExplicitSessionPositionPath values
isSessionPositionCollection _ = False

isExplicitSessionPositionPath :: Expr -> Bool
isExplicitSessionPositionPath (Call (Symbol "List") components) =
  all isSessionPositionComponent components
isExplicitSessionPositionPath _ = False

isSingleSessionPositionSpecification :: Expr -> Bool
isSingleSessionPositionSpecification Integer {} = True
isSingleSessionPositionSpecification expression
  | isSessionKeySelector expression = True
isSingleSessionPositionSpecification (Call (Symbol "List") components) =
  all isSessionPositionComponent components
isSingleSessionPositionSpecification _ = False

isSessionPositionComponent :: Expr -> Bool
isSessionPositionComponent expression
  | isSessionSelectorAtom expression = True
isSessionPositionComponent (Call (Symbol "List") selectors) =
  all isSessionSelectorAtom selectors
isSessionPositionComponent _ = False

isSessionSelectorAtom :: Expr -> Bool
isSessionSelectorAtom expression =
  isSessionNumericSelectorAtom expression || isSessionKeySelector expression

isSessionNumericSelectorAtom :: Expr -> Bool
isSessionNumericSelectorAtom Integer {} = True
isSessionNumericSelectorAtom (Symbol "All") = True
isSessionNumericSelectorAtom (Call (Symbol "Span") _) = True
isSessionNumericSelectorAtom _ = False

isSessionKeySelector :: Expr -> Bool
isSessionKeySelector = maybe False (const True) . sessionKeySelectorValue

sessionKeySelectorValue :: Expr -> Maybe Expr
sessionKeySelectorValue key@String {} = Just key
sessionKeySelectorValue (Call (Symbol "Key") [key]) = Just key
sessionKeySelectorValue _ = Nothing

sessionAssociationSelectorKind :: Expr -> Maybe Bool
sessionAssociationSelectorKind expression
  | isSessionKeySelector expression = Just True
  | isSessionNumericSelectorAtom expression = Just False
sessionAssociationSelectorKind _ = Nothing

sessionPositionComponents :: Expr -> [Expr]
sessionPositionComponents (Call (Symbol "List") components) = components
sessionPositionComponents expression = [expression]

unsupportedPositionSpecification
  :: Expr
  -> Either Text value
unsupportedPositionSpecification specification =
  Left
    ( "Unsupported position specification: "
        <> inputForm specification
        <> "."
    )

unsupportedSelectorInsidePosition :: Expr -> Either Text value
unsupportedSelectorInsidePosition selector =
  Left
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
      Left (operation <> " currently supports only the SameTest option.")
  | otherwise = Right (dataValues, normalizeSameTest selectedSameTest)
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

evaluateSessionSortBy
  :: Bool
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionSortBy reverseMode depth session values =
  case splitSessionSameTestOptions operation values of
    Left message -> sessionFailure session message
    Right (sortArguments, sameTest) -> case sortArguments of
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
        let (keyFunctions, keySpecIsList) = case functions of
              Call (Symbol "List") functionList -> (functionList, True)
              _ -> ([functions], False)
        (decorated, keySession) <-
          decorateSessionItems
            depth
            keyFunctions
            session
            (sessionCollectionItems collection)
        (sorted, updated) <-
          pythonStableSortByState
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
    Right (selector, Just propertySpec)
  Call (Symbol "Rule") _ ->
    Left (operation <> " property specifications must contain exactly two arguments.")
  _ -> Right (criterion, Nothing)
 where
  parsePropertyExpression (String "Element") =
    Right (SingleSelectionProperty SelectionElement)
  parsePropertyExpression (String "Index") =
    Right (SingleSelectionProperty SelectionIndex)
  parsePropertyExpression (Call (Symbol "List") properties) =
    MultipleSelectionProperties <$> traverse parseProperty properties
  parsePropertyExpression _ = unsupportedProperties
  parseProperty (String "Element") = Right SelectionElement
  parseProperty (String "Index") = Right SelectionIndex
  parseProperty _ = unsupportedProperties
  unsupportedProperties =
    Left
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
      Left message -> sessionFailure session message
      Right (selector, propertySpec) -> case sessionOrderedCollection subject of
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
      Left message -> sessionFailure session message
      Right (selector, propertySpec) -> case sessionOrderedCollection subject of
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
            case evaluateSessionAt (depth + 1) current condition of
              Left (SessionControl (Returned value Nothing) updated) ->
                Right (Just value, updated)
              Left evaluationExit -> Left evaluationExit
              Right (conditionResult, updated)
                | conditionResult == Symbol "True" ->
                    catchBareReturn (evaluateReplacement updated body)
                | otherwise -> tryDefinitions updated rest
      Call (Symbol conditionHead) [_, _]
        | isSessionSystemHead "Condition" conditionHead ->
            Right (Just replacement, current)
      _ -> catchBareReturn (evaluateReplacement current replacement)

  catchBareReturn = \case
    Left (SessionControl (Returned value Nothing) updated) ->
      Right (Just value, updated)
    result -> result

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
  case evaluateSessionAt (depth + 1) session body of
    Left evaluationExit@(SessionEvaluationFailure _ _) ->
      Left evaluationExit
    Left evaluationExit@(SessionControl (Thrown value tag _) stoppedSession)
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
    Left evaluationExit -> Left evaluationExit
    Right result -> Right result

catchMatches :: Maybe Expr -> Maybe Expr -> Bool
catchMatches Nothing Nothing = True
catchMatches (Just form) (Just tag) = matchesPattern tag form
catchMatches _ _ = False

evaluateSessionModule
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionModule depth session = \case
  [Call (Symbol listHead) [], body]
    | isSessionSystemHead "List" listHead ->
        evaluateTargetedReturn "Module" depth session body
  originalArguments@[Call (Symbol listHead) bindingExpressions, body]
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
        Right (Call (Symbol "Module") originalArguments, session)
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
  originalArguments@[Call (Symbol listHead) bindingExpressions, body]
    | isSessionSystemHead "List" listHead ->
        case collectWithBindings depth session Set.empty Map.empty bindingExpressions of
          Left evaluationExit -> Left evaluationExit
          Right (Nothing, updated) ->
            Right (Call (Symbol "With") originalArguments, updated)
          Right (Just substitutions, updated) ->
            evaluateSessionAt
              (depth + 1)
              updated
              (substituteNamedSymbols substitutions body)
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
  originalArguments@[Call (Symbol listHead) bindingExpressions, body]
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
        Right (Call (Symbol headName) originalArguments, session)
  arguments' -> Right (Call (Symbol headName) arguments', session)

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
restoreScopedResult snapshots = \case
  Left evaluationExit ->
    Left
      ( mapEvaluationExitSession
          (restoreSnapshots snapshots)
          evaluationExit
      )
  Right (value, session) ->
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
    case tableLoop depth session body iteratorSpecs of
      Left (InvalidIterator updated) ->
        Right (Call (Symbol "Table") arguments', updated)
      Left (IterationEvaluationFailure evaluationExit) ->
        Left evaluationExit
      Right result -> Right result
  _ -> Right (Call (Symbol "Table") arguments', session)

evaluateSessionDo
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionDo depth session arguments' = case arguments' of
  body : iteratorSpecs@(_ : _) ->
    case flatIterationLoop False depth session body iteratorSpecs of
      Left (InvalidIterator updated) ->
        Right (Call (Symbol "Do") arguments', updated)
      Left
        ( IterationEvaluationFailure
            (SessionControl BreakSignal stoppedSession)
          ) ->
          Right (Symbol "Null", stoppedSession)
      Left
        ( IterationEvaluationFailure
            (SessionControl (Returned value (Just "Do")) stoppedSession)
          ) ->
          Right (value, stoppedSession)
      Left (IterationEvaluationFailure evaluationExit) ->
        Left evaluationExit
      Right (_, updated) -> Right (Symbol "Null", updated)
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
  case evaluateSessionAt (depth + 1) session body of
    Left (SessionControl ContinueSignal stoppedSession) ->
      Right ((), stoppedSession)
    Left evaluationExit -> Left evaluationExit
    Right (_, updated) -> Right ((), updated)

catchLoopBoundary :: Text -> SessionResult Expr -> SessionResult Expr
catchLoopBoundary target = \case
  Left (SessionControl BreakSignal stoppedSession) ->
    Right (Symbol "Null", stoppedSession)
  Left
    ( SessionControl
        (Returned value (Just actualTarget))
        stoppedSession
      )
    | actualTarget == target -> Right (value, stoppedSession)
  result -> result

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
          case flatIterationLoop True depth session body iteratorSpecs of
            Left (InvalidIterator updated) -> inert updated
            Left (IterationEvaluationFailure evaluationExit) ->
              Left evaluationExit
            Right (terms, updated) ->
              evaluateSessionAt
                (depth + 1)
                updated
                ( Call
                    (Symbol accumulatorHead)
                    (accumulatorArguments accumulatorHead terms)
                )
    _ -> inert session
 where
  inert updated = Right (Call (Symbol headName) arguments', updated)

flatIterationLoop
  :: Bool
  -> Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> Either IterationFailure ([Expr], EvaluationSession)
flatIterationLoop retainValues depth session body iteratorSpecs = do
  (reversed, updated) <- collect depth session iteratorSpecs []
  Right (reverse reversed, updated)
 where
  collect currentDepth current [] retained = do
    case evaluateSessionAt (currentDepth + 1) current body of
      Left (SessionControl ContinueSignal stoppedSession)
        | not retainValues -> Right (retained, stoppedSession)
      evaluationResult -> do
        (value, updated) <- liftIterationEvaluation evaluationResult
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
       in case collect (nestedDepth + 1) bound remainingSpecs retainedValues of
            Left failure -> Left (restoreIterationFailure name previous failure)
            Right (nextRetained, updated) ->
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
  -> Either IterationFailure (Expr, EvaluationSession)
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
     in case tableLoop (depth + 1) bound body remainingSpecs of
          Left failure -> Left (restoreIterationFailure name previous failure)
          Right (result, updated) ->
            collectWithVariable name previous updated rest (result : results)

resolveIterator
  :: Int
  -> EvaluationSession
  -> Expr
  -> Either IterationFailure (Iterator, EvaluationSession)
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
  -> Either IterationFailure (Iterator, EvaluationSession)
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

countIterator :: EvaluationSession -> Integer -> Either IterationFailure Iterator
countIterator session count
  | count > toInteger (maxBound :: Int) = invalidIterator session
  | otherwise =
      Right (Iterator Nothing (replicate (fromIntegral (max 0 count)) (Integer 0)))

numericIteratorValues
  :: EvaluationSession
  -> Expr
  -> Expr
  -> Expr
  -> Either IterationFailure [Expr]
numericIteratorValues session start end step =
  maybe (invalidIterator session) Right (exactRangeValues start end step)

invalidIterator :: EvaluationSession -> Either IterationFailure value
invalidIterator = Left . InvalidIterator

liftIterationEvaluation
  :: SessionResult value
  -> Either IterationFailure (value, EvaluationSession)
liftIterationEvaluation =
  either
    (Left . IterationEvaluationFailure)
    Right

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
    Call (Symbol "Sequence") values -> values
    Call (Symbol "Splice") [Call (Symbol "List") values] -> values
    Call (Symbol "Splice") [Call (Symbol "List") values, target]
      | target == Symbol "List" -> values
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

evaluateSequence
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSequence depth = go (Symbol "Null")
 where
  go result session [] = Right (result, session)
  go _ session (expression : rest) = do
    (result, updated) <- evaluateSessionAt (depth + 1) session expression
    go result updated rest

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
      _ -> Right (Call (Symbol "If") (evaluatedCondition : trueBranch : remaining), updated)
  arguments' -> Right (Call (Symbol "If") arguments', session)

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
    Left (EvaluationError message) -> sessionFailure session message
    Right attributes ->
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
    Right attributes ->
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
    Left _ -> normalizeEvaluatedCall expressionHead values
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

threadSessionListableCall
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe (SessionResult Expr)
threadSessionListableCall depth session expression = case expression of
  Call expressionHead values ->
    case sessionCallAttributes session expressionHead of
      Right attributes
        | Set.member Listable attributes ->
            case listableArgumentRows values of
              Left (EvaluationError message) -> Just (sessionFailure session message)
              Right Nothing -> Nothing
              Right (Just rows) ->
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
  [] -> Right Nothing
  firstLength : remainingLengths
    | all (== firstLength) remainingLengths ->
        Right
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
        Left
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
  Symbol name -> Right (symbolAttributesFor name session)
  Call (Symbol functionHead) functionArguments
    | isSessionSystemHead "Function" functionHead ->
        functionAttributeSet functionArguments
  _ -> Right Set.empty

functionAttributeSet
  :: [Expr]
  -> Either EvaluationError (Set.Set SymbolAttribute)
functionAttributeSet [_, _, specification] =
  Set.fromList . mapMaybeAttribute <$> attributeSymbols specification
 where
  attributeSymbols (Symbol name) = Right [name]
  attributeSymbols (Call (Symbol listHead) values)
    | isSessionSystemHead "List" listHead = traverse requireSymbol values
  attributeSymbols _ = invalid
  requireSymbol (Symbol name) = Right name
  requireSymbol _ = invalid
  invalid =
    Left
      (EvaluationError "Function attributes must be a symbol or a list of symbols.")
  mapMaybeAttribute =
    foldr
      (\name retained -> maybe retained (: retained) (symbolAttributeFromName (systemAttributeSymbolName name)))
      []
functionAttributeSet _ = Right Set.empty

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
  let initialMessageCount = length (sessionGeneratedMessages session)
  (current, currentSession) <- evaluateSessionAt (depth + 1) session (Symbol name)
  (value, valueSession) <- evaluateSessionAt (depth + 1) currentSession rhs
  if length (sessionGeneratedMessages valueSession) > initialMessageCount
    then Right (Call (Symbol headName) [Symbol name, rhs], valueSession)
    else do
      let beforeResultCount = length (sessionGeneratedMessages valueSession)
      (result, resultSession) <-
        evaluateSessionAt (depth + 1) valueSession (constructor current value)
      if length (sessionGeneratedMessages resultSession) > beforeResultCount
        then Right (Call (Symbol headName) [Symbol name, rhs], resultSession)
        else Right (result, define name (ImmediateValue result) resultSession)

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
recoverEvaluationFailure expression = \case
  Left (SessionEvaluationFailure evaluationError stoppedSession) ->
    Right
      ( expression
      , appendEvaluationMessage expression evaluationError stoppedSession
      )
  result -> result

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
  session
    { sessionGeneratedMessages =
        sessionGeneratedMessages session <> [message]
    , sessionVisibleMessages =
        sessionVisibleMessages session <> [message]
    }
 where
  messageName = headName <> "::" <> tag
  message =
    EvaluationMessage
      { evaluationMessageName = messageName
      , evaluationMessageFullName =
          Call
            (Symbol "MessageName")
            [Symbol headName, String tag]
      , evaluationMessageText = messageName <> ": " <> messageText
      }

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
  -> Either EvaluationExit value
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
  case evaluateSessionAt (depth + 1) session body of
    Left (SessionControl (Returned value (Just actualTarget)) stoppedSession)
      | actualTarget == target -> Right (value, stoppedSession)
    result -> result

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
