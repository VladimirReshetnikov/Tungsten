{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Immutable evaluation sessions with ordered symbol value definitions.
module Tungsten.Session
  ( Definition (..)
  , DownValue (..)
  , EvaluationMessage (..)
  , EvaluationSession (..)
  , emptySession
  , evaluateInSession
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.List (sortBy)
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Evaluate
import Tungsten.Expression
import Tungsten.PythonSort (pythonStableSortByState)

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

data EvaluationMessage = EvaluationMessage
  { evaluationMessageName :: !Text
  , evaluationMessageFullName :: !Expr
  , evaluationMessageText :: !Text
  }
  deriving (Eq, Show)

data EvaluationSession = EvaluationSession
  { sessionDefinitions :: Map.Map Text Definition
  , sessionDownValues :: Map.Map Text [DownValue]
  , sessionModuleCounter :: !Integer
  , sessionGeneratedMessages :: ![EvaluationMessage]
  , sessionVisibleMessages :: ![EvaluationMessage]
  , sessionPrints :: ![Text]
  }
  deriving (Eq, Show)

emptySession :: EvaluationSession
emptySession = EvaluationSession Map.empty Map.empty 0 [] [] []

data Iterator = Iterator !(Maybe Text) ![Expr]
  deriving (Eq, Show)

data ModuleBinding = ModuleBinding !Text !(Maybe Definition)
  deriving (Eq, Show)

data BlockBinding = BlockBinding !Text !(Maybe Definition)
  deriving (Eq, Show)

data WithBinding = WithBinding !Text !Expr !Bool
  deriving (Eq, Show)

data SymbolValueSnapshot = SymbolValueSnapshot
  { snapshotOwnValue :: !(Maybe Definition)
  , snapshotDownValues :: !(Maybe [DownValue])
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

data IterationFailure
  = InvalidIterator !EvaluationSession
  | IterationEvaluationFailure !EvaluationExit
  deriving (Eq, Show)

evaluateInSession :: EvaluationSession -> Expr -> Either EvaluationError (Expr, EvaluationSession)
evaluateInSession session expression =
  finalizeSessionResult
    ( evaluateSessionAt
        0
        session
          { sessionGeneratedMessages = []
          , sessionVisibleMessages = []
          , sessionPrints = []
          }
        expression
    )

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
  | depth > 1024 =
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
      Symbol name -> case Map.lookup name (sessionDefinitions session) of
        Nothing -> Right (expression, session)
        Just (ImmediateValue value)
          | value == expression -> Right (expression, session)
        Just (ImmediateValue value) -> evaluateSessionAt (depth + 1) session value
        Just (DelayedValue value) -> evaluateSessionAt (depth + 1) session value
      Call (Symbol "Set") [Symbol name, rhs] -> do
        (value, updated) <- evaluateSessionAt (depth + 1) session rhs
        pure (value, define name (ImmediateValue value) updated)
      Call (Symbol "Set") [lhs@Call {}, rhs] ->
        evaluateDownValueAssignment False depth session lhs rhs
      Call (Symbol "SetDelayed") [Symbol name, rhs] ->
        Right (Symbol "Null", define name (DelayedValue rhs) session)
      Call (Symbol "SetDelayed") [lhs@Call {}, rhs] ->
        evaluateDownValueAssignment True depth session lhs rhs
      Call (Symbol "Unset") [Symbol name] ->
        Right (Symbol "Null", removeOwnValues [name] session)
      Call (Symbol "Unset") [lhs@Call {}] ->
        evaluateDownValueUnset depth session lhs
      Call (Symbol headName) symbols
        | headName `elem` ["Clear", "ClearAll"]
        , Just names <- traverse symbolName symbols ->
            Right (Symbol "Null", clearDefinitions names session)
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
      Call (Symbol "Select") [criterion] ->
        evaluateSessionSelectionOperator "Select" depth session criterion
      Call (Symbol "Discard") [criterion] ->
        evaluateSessionSelectionOperator "Discard" depth session criterion
      Call (Symbol "SelectFirst") [criterion] ->
        evaluateSessionSelectionOperator "SelectFirst" depth session criterion
      Call (Symbol "Level") arguments' ->
        evaluateSessionLevel depth session arguments'
      Call (Symbol "OwnValues") arguments' ->
        evaluateSessionOwnValues session arguments'
      Call (Symbol "DownValues") arguments' ->
        evaluateSessionDownValues session arguments'
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
      Call (Symbol headName) [Symbol name, rhs]
        | Just constructor <- Map.lookup headName updateConstructors ->
            evaluateUpdate headName depth session name constructor rhs
      Call expressionHead@(Symbol headName) arguments'
        | headName `elem` ["Hold", "HoldComplete", "HoldForm", "HoldPattern", "Unevaluated", "Function", "SetDelayed", "RuleDelayed", "Condition"] ->
            Right
              ( if headName == "Function"
                  then normalizeEvaluatedCall expressionHead arguments'
                  else expression
              , session
              )
      Call expressionHead arguments' -> do
        (evaluatedHead, headSession) <- evaluateSessionAt (depth + 1) session expressionHead
        if evaluatedHead == Symbol "Association"
          then do
            reduced <-
              liftPureEvaluation
                headSession
                (reduceEvaluatedCall (Call evaluatedHead arguments'))
            Right (reduced, headSession)
          else if isHeldSessionHead evaluatedHead
            then Right (Call evaluatedHead arguments', headSession)
          else if evaluatedHead == Symbol "SelectFirst"
            then evaluateHeldSessionSelectFirst depth headSession arguments'
          else do
            (evaluatedArguments, argumentsSession) <- evaluateArguments depth headSession arguments'
            let normalizedCall = normalizeEvaluatedCall evaluatedHead evaluatedArguments
                normalizedArguments = case normalizedCall of
                  Call _ values -> values
                  _ -> evaluatedArguments
            case evaluatedHead of
              Call (Symbol "Function") functionArguments -> do
                instantiated <-
                  liftPureEvaluation
                    argumentsSession
                    (instantiateFunctionCall functionArguments normalizedArguments)
                if instantiated == normalizedCall
                  then Right (instantiated, argumentsSession)
                  else evaluateSessionAt (depth + 1) argumentsSession instantiated
              _ -> do
                (downValueReplacement, definitionSession) <-
                  applySessionDownValue depth argumentsSession normalizedCall
                case downValueReplacement of
                  Just replacement ->
                    Right (replacement, definitionSession)
                  Nothing ->
                    case reduceSessionEvaluatedCall depth definitionSession normalizedCall of
                      Just sessionReduction -> sessionReduction
                      Nothing -> do
                        reduced <-
                          liftPureEvaluation
                            definitionSession
                            (reduceEvaluatedCall normalizedCall)
                        Right (reduced, definitionSession)
      _ -> Right (expression, session)

reduceSessionEvaluatedCall
  :: Int
  -> EvaluationSession
  -> Expr
  -> Maybe (SessionResult Expr)
reduceSessionEvaluatedCall depth session = \case
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

evaluateHeldSessionSelectFirst
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateHeldSessionSelectFirst depth session values = case values of
  [subject, criterion] -> prepare subject criterion Nothing
  [subject, criterion, defaultValue] ->
    prepare subject criterion (Just defaultValue)
  _ ->
    sessionFailure
      session
      "SelectFirst expects an expression, a criterion or property specification, and an optional default."
 where
  prepare subject criterion defaultValue = do
    (evaluatedSubject, subjectSession) <-
      evaluateSessionAt (depth + 1) session subject
    (evaluatedCriterion, criterionSession) <-
      evaluateSessionAt (depth + 1) subjectSession criterion
    evaluateSessionSelectFirst
      depth
      criterionSession
      ( [evaluatedSubject, evaluatedCriterion]
          <> maybe [] pure defaultValue
      )

evaluateSessionCallable
  :: Int
  -> EvaluationSession
  -> Expr
  -> [Expr]
  -> SessionResult Expr
evaluateSessionCallable depth session function arguments' = case function of
  Symbol "Nothing" -> Right (Symbol "Nothing", session)
  association@(Call (Symbol "Association") _)
    | [key] <- arguments'
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
  Call (Symbol "Function") functionArguments -> do
    instantiated <-
      liftPureEvaluation
        session
        (instantiateFunctionCall functionArguments arguments')
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
  expandPaths retained invalid (pathExpression : rest) = do
    (paths, pathInvalid) <-
      expandSessionExactPath
        expression
        (sessionPositionComponents pathExpression)
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
sessionOrderedCollection expression@(Call (Symbol "Association") rules)
  | Just items <- traverse (uncurry associationItem) (zip [1 ..] rules) =
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
  | ruleHead `elem` ["Rule", "RuleDelayed"] =
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

evaluateSessionLevel
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionLevel depth session arguments' = do
  (evaluatedArguments, updated) <-
    evaluateArguments depth session arguments'
  result <-
    liftPureEvaluation
      updated
      (evaluate (Call (Symbol "Level") evaluatedArguments))
  Right (result, updated)

evaluateLoopControl
  :: ControlSignal
  -> Text
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateLoopControl controlSignal headName session = \case
  [] -> Left (SessionControl controlSignal session)
  arguments' -> Right (Call (Symbol headName) arguments', session)

evaluateSessionOwnValues
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOwnValues session = \case
  [symbol@(Symbol name)] ->
    let rules = case Map.lookup name (sessionDefinitions session) of
          Nothing -> []
          Just (ImmediateValue value) -> [ownValueRule symbol value]
          Just (DelayedValue value) -> [ownValueRule symbol value]
     in Right (Call (Symbol "List") rules, session)
  arguments' -> Right (Call (Symbol "OwnValues") arguments', session)
 where
  ownValueRule symbol value =
    Call
      (Symbol "RuleDelayed")
      [Call (Symbol "HoldPattern") [symbol], value]

evaluateSessionDownValues
  :: EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionDownValues session = \case
  [Symbol name] ->
    Right
      ( Call
          (Symbol "List")
          (map downValueRule (Map.findWithDefault [] name (sessionDownValues session)))
      , session
      )
  arguments' -> Right (Call (Symbol "DownValues") arguments', session)
 where
  downValueRule definition =
    Call
      (Symbol "RuleDelayed")
      [ Call (Symbol "HoldPattern") [downValuePattern definition]
      , downValueBody definition
      ]

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
    case downValueOwner normalizedLhs of
      Just owner
        | Set.notMember owner protectedDefinitionOwners ->
            let definition = DownValue normalizedLhs storedBody delayed
                result = if delayed then Symbol "Null" else storedBody
             in Right (result, defineDownValue owner definition updated)
      Just _
        | delayed -> Right (Symbol "Null", updated)
      _ ->
        let assignmentHead = if delayed then "SetDelayed" else "Set"
         in Right
              ( Call (Symbol assignmentHead) [normalizedLhs, storedBody]
              , updated
              )

evaluateDownValueUnset
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateDownValueUnset depth session lhs = do
  (normalizedLhs, normalizedSession) <- normalizeAssignmentLhs depth session lhs
  case downValueOwner normalizedLhs of
    Just owner
      | hasDownValue owner normalizedLhs normalizedSession ->
          Right
            ( Symbol "Null"
            , removeDownValue owner normalizedLhs normalizedSession
            )
    _ -> Right (Symbol "$Failed", normalizedSession)

normalizeAssignmentLhs
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
normalizeAssignmentLhs depth session expression = case expression of
  Call (Symbol "Condition") [body, test] -> do
    (normalizedBody, updated) <- normalizeAssignmentLhs depth session body
    Right (Call (Symbol "Condition") [normalizedBody, test], updated)
  Call (Symbol "HoldPattern") [_] -> Right (expression, session)
  Call expressionHead arguments' -> do
    (normalizedHead, headSession) <-
      evaluateSessionAt (depth + 1) session expressionHead
    (normalizedArguments, updated) <-
      normalizeAssignmentArguments depth headSession arguments'
    Right (Call normalizedHead normalizedArguments, updated)
  _ -> Right (expression, session)

normalizeAssignmentArguments
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult [Expr]
normalizeAssignmentArguments _ session [] = Right ([], session)
normalizeAssignmentArguments depth session (argument : rest)
  | containsPatternSyntax argument = do
      (remaining, updated) <-
        normalizeAssignmentArguments depth session rest
      Right (argument : remaining, updated)
  | otherwise = do
      (value, valueSession) <- evaluateSessionAt (depth + 1) session argument
      (remaining, updated) <-
        normalizeAssignmentArguments depth valueSession rest
      Right (value : remaining, updated)

containsPatternSyntax :: Expr -> Bool
containsPatternSyntax = \case
  Call (Symbol headName) _
    | headName `elem` patternHeads -> True
  Call expressionHead arguments' ->
    containsPatternSyntax expressionHead || any containsPatternSyntax arguments'
  _ -> False
 where
  patternHeads =
    [ "Pattern"
    , "Blank"
    , "BlankSequence"
    , "BlankNullSequence"
    , "Optional"
    , "PatternTest"
    , "Alternatives"
    , "Except"
    , "Repeated"
    , "RepeatedNull"
    , "PatternSequence"
    , "OrderlessPatternSequence"
    , "Longest"
    , "Shortest"
    , "OptionsPattern"
    , "Condition"
    , "Verbatim"
    ]

downValueOwner :: Expr -> Maybe Text
downValueOwner = \case
  Call (Symbol wrapper) (body : _)
    | wrapper `elem` ["Condition", "HoldPattern"] -> downValueOwner body
  Call (Symbol name) _ -> Just name
  _ -> Nothing

-- These are the System-style heads implemented or structurally recognized by
-- the Haskell evaluator. Until contexts and Attributes are ported, treating
-- this explicit surface as protected prevents user downvalues from replacing
-- core evaluation semantics while still allowing aliases between user heads.
protectedDefinitionOwners :: Set.Set Text
protectedDefinitionOwners =
  Set.fromList
    ( T.words
        ( "Abs Accumulate AddTo AllTrue Alternatives And AnyTrue Append Apply Association AssociationMap "
            <> "AssociationQ AssociationThread AtomQ Attributes Blank BlankNullSequence BlankSequence Block Boole Break "
            <> "Cases Catch Catenate Ceiling Clear ClearAll ClearAttributes Complement CompoundExpression Condition "
            <> "ContainsAll ContainsAny ContainsExactly ContainsNone Continue Count Counts Cycles Delete DeleteCases "
            <> "Depth Differences Discard DivideBy Do DownValues Drop Equal EvenQ Except Extract Factorial Factorial2 "
            <> "False First FirstCase FirstPosition Flatten Floor For FractionalPart FreeQ Function Gather GatherBy Greater "
            <> "GreaterEqual GroupBy Head Hold HoldForm HoldPattern Identity If IgnoringInactive Inactive Inequality "
            <> "InheritedBlock Insert IntegerPart IntegerQ Internal`InheritedBlock Intersection Join Key KeyComplement "
            <> "KeyDrop KeyExistsQ KeyIntersection KeyMap KeyMemberQ Keys KeySelect KeySort KeyTake KeyUnion KeyValueMap "
            <> "KeyValuePattern Last Length LengthWhile Level Less LessEqual List ListQ Longest Lookup Map MapAt MatchQ Max "
            <> "Mean Median MemberQ Merge Min Missing Module Most NValues NoneTrue Normal Not Null NumberQ OddQ Optional "
            <> "OptionsPattern Or Order OrderedQ Ordering OrderlessPatternSequence OwnValues PadLeft PadRight Part Pattern "
            <> "PatternSequence PatternTest Permutations Permute Pick Plus Position PositionIndex PositionLargest "
            <> "PositionSmallest Power Prepend Product Protect Range Replace ReplaceAll ReplaceAt ReplacePart "
            <> "ReplaceRepeated Rest Return Reverse ReverseSort ReverseSortBy Riffle RotateLeft RotateRight Round Rule "
            <> "RuleDelayed SameQ Select SelectFirst Sequence Set SetAttributes SetDelayed Shortest Sign Slot Sort SortBy "
            <> "Splice Sqrt StringQ Subsets SubtractFrom SubValues Sum Table Take TakeWhile Tally Throw Times TimesBy Total "
            <> "True Unequal Unevaluated Union Unprotect UnsameQ Unset UpValues Values Verbatim While With"
        )
    )

applySessionDownValue
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult (Maybe Expr)
applySessionDownValue depth session expression@(Call (Symbol name) _) =
  applyDefinitions session (Map.findWithDefault [] name (sessionDownValues session))
 where
  applyDefinitions current [] = Right (Nothing, current)
  applyDefinitions current (definition : rest) =
    let (patternExpression, lhsCondition) =
          downValueMatchPattern definition
     in case
          instantiatePatternMatch
            expression
            patternExpression
            (downValueBody definition)
        of
          Nothing -> applyDefinitions current rest
          Just replacement ->
            case lhsCondition of
              Nothing ->
                applyReplacement current definition replacement rest
              Just condition ->
                case
                  instantiatePatternMatch
                    expression
                    patternExpression
                    condition
                of
                  Nothing -> applyDefinitions current rest
                  Just instantiatedCondition -> do
                    (conditionResult, updated) <-
                      evaluateSessionAt
                        (depth + 1)
                        current
                        instantiatedCondition
                    if conditionResult == Symbol "True"
                      then applyReplacement updated definition replacement rest
                      else applyDefinitions updated rest

  applyReplacement current definition replacement rest =
    case replacement of
      Call (Symbol "Condition") [body, condition]
        | downValueDelayed definition ->
            case evaluateSessionAt (depth + 1) current condition of
              Left (SessionControl (Returned value Nothing) updated) ->
                Right (Just value, updated)
              Left evaluationExit -> Left evaluationExit
              Right (conditionResult, updated)
                | conditionResult == Symbol "True" ->
                    catchBareReturn (evaluateReplacement updated body)
                | otherwise -> applyDefinitions updated rest
      Call (Symbol "Condition") [_, _] ->
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
applySessionDownValue _ session _ = Right (Nothing, session)

downValueMatchPattern :: DownValue -> (Expr, Maybe Expr)
downValueMatchPattern definition = case downValuePattern definition of
  Call (Symbol "Condition") [patternExpression, condition] ->
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
  [Call (Symbol "List") [], body] ->
    evaluateTargetedReturn "Module" depth session body
  originalArguments@[Call (Symbol "List") bindingExpressions, body]
    | Just bindings <- parseModuleBindings bindingExpressions -> do
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
  [Call (Symbol "List") [], body] ->
    evaluateSessionAt (depth + 1) session body
  originalArguments@[Call (Symbol "List") bindingExpressions, body] ->
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
  Call (Symbol "Set") [Symbol name, rhs] ->
    Just (WithBinding name rhs False)
  Call (Symbol "SetDelayed") [Symbol name, rhs] ->
    Just (WithBinding name rhs True)
  _ -> Nothing

evaluateSessionBlock
  :: Text
  -> Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionBlock headName depth session = \case
  [Call (Symbol "List") [], body] ->
    evaluateTargetedReturn (blockReturnTarget headName) depth session body
  originalArguments@[Call (Symbol "List") bindingExpressions, body]
    | Just bindings <- parseBlockBindings bindingExpressions ->
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
    Call (Symbol "Set") [Symbol name, rhs] ->
      Just (BlockBinding name (Just (ImmediateValue rhs)))
    Call (Symbol "SetDelayed") [Symbol name, rhs] ->
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
    Call (Symbol "Set") [Symbol name, rhs] ->
      Just (ModuleBinding name (Just (ImmediateValue rhs)))
    Call (Symbol "SetDelayed") [Symbol name, rhs] ->
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
  Call (Symbol headName) [Call (Symbol "List") bindings, body]
    | headName `elem` scopeHeads
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
  Call (Symbol "Function") (parameters : body : remaining)
    | length remaining <= 1
    , Just parameterNames <- functionParameterNames parameters ->
        let bodyMap =
              foldr Map.delete renameMap parameterNames
         in Call
              (Symbol "Function")
              ( parameters
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

renameNestedBinding :: Map.Map Text Text -> Expr -> Expr
renameNestedBinding renameMap = \case
  binding@(Symbol _) -> binding
  Call (Symbol headName) [name@(Symbol _), rhs]
    | headName `elem` ["Set", "SetDelayed"] ->
        Call
          (Symbol headName)
          [name, renameBoundSymbols renameMap rhs]
  expression -> renameBoundSymbols renameMap expression

scopeBindingName :: Expr -> Maybe Text
scopeBindingName = \case
  Symbol name -> Just name
  Call (Symbol headName) [Symbol name, _]
    | headName `elem` ["Set", "SetDelayed"] -> Just name
  _ -> Nothing

functionParameterNames :: Expr -> Maybe [Text]
functionParameterNames = \case
  Symbol "Null" -> Nothing
  Symbol name -> Just [name]
  Call (Symbol "List") parameters ->
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
  Call (Symbol "List") values -> resolveListIterator depth session values
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

isHeldSessionHead :: Expr -> Bool
isHeldSessionHead (Symbol name) =
  name
    `elem` [ "Table"
           , "Do"
           , "For"
           , "While"
           , "Sum"
           , "Product"
           , "Catch"
           , "Throw"
           , "Break"
           , "Continue"
           , "OwnValues"
           , "DownValues"
           , "Condition"
           , "Module"
           , "With"
           , "Block"
           , "InheritedBlock"
           , "Internal`InheritedBlock"
           ]
isHeldSessionHead _ = False

isListIteratorSpec :: Expr -> Bool
isListIteratorSpec (Call (Symbol "List") _) = True
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
evaluateSessionAnd depth = go []
 where
  go retained session [] = Right (logicalResult "And" (Symbol "True") retained, session)
  go retained session (value : rest) = do
    (evaluated, updated) <- evaluateSessionAt (depth + 1) session value
    case evaluated of
      Symbol "False" -> Right (Symbol "False", updated)
      Symbol "True" -> go retained updated rest
      _ -> go (retained <> [evaluated]) updated rest

evaluateSessionOr
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> SessionResult Expr
evaluateSessionOr depth = go []
 where
  go retained session [] = Right (logicalResult "Or" (Symbol "False") retained, session)
  go retained session (value : rest) = do
    (evaluated, updated) <- evaluateSessionAt (depth + 1) session value
    case evaluated of
      Symbol "True" -> Right (Symbol "True", updated)
      Symbol "False" -> go retained updated rest
      _ -> go (retained <> [evaluated]) updated rest

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

evaluateUpdate
  :: Text
  -> Int
  -> EvaluationSession
  -> Text
  -> (Expr -> Expr -> Expr)
  -> Expr
  -> SessionResult Expr
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
  session
    { sessionGeneratedMessages =
        sessionGeneratedMessages session <> [message]
    , sessionVisibleMessages =
        sessionVisibleMessages session <> [message]
    }
 where
  headName = case expression of
    Call (Symbol symbolName') _ -> symbolName'
    Symbol symbolName' -> symbolName'
    _ -> "General"
  messageName = headName <> "::error"
  message =
    EvaluationMessage
      { evaluationMessageName = messageName
      , evaluationMessageFullName =
          Call
            (Symbol "MessageName")
            [Symbol headName, String "error"]
      , evaluationMessageText = messageName <> ": " <> messageText
      }

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
  session {sessionDefinitions = Map.insert name value (sessionDefinitions session)}

defineDownValue :: Text -> DownValue -> EvaluationSession -> EvaluationSession
defineDownValue name definition session =
  session
    { sessionDownValues =
        Map.alter
          (Just . insertDownValue definition . maybe [] id)
          name
          (sessionDownValues session)
    }

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
  Call (Symbol "Condition") [_, condition] -> Just condition
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
  Call (Symbol "Condition") [inner, _] -> 2 + downValueSpecificity inner
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

hasDownValue :: Text -> Expr -> EvaluationSession -> Bool
hasDownValue name patternExpression session =
  any
    ((== patternExpression) . downValuePattern)
    (Map.findWithDefault [] name (sessionDownValues session))

removeDownValue :: Text -> Expr -> EvaluationSession -> EvaluationSession
removeDownValue name patternExpression session =
  session
    { sessionDownValues =
        Map.update removeMatching name (sessionDownValues session)
    }
 where
  removeMatching definitions =
    case filter ((/= patternExpression) . downValuePattern) definitions of
      [] -> Nothing
      retained -> Just retained

removeOwnValues :: [Text] -> EvaluationSession -> EvaluationSession
removeOwnValues names session =
  session
    { sessionDefinitions =
        foldl (flip Map.delete) (sessionDefinitions session) names
    }

clearDefinitions :: [Text] -> EvaluationSession -> EvaluationSession
clearDefinitions names session =
  (removeOwnValues names session)
    { sessionDownValues =
        foldl (flip Map.delete) (sessionDownValues session) names
    }

snapshotSymbolValues :: Text -> EvaluationSession -> SymbolValueSnapshot
snapshotSymbolValues name session =
  SymbolValueSnapshot
    { snapshotOwnValue = Map.lookup name (sessionDefinitions session)
    , snapshotDownValues = Map.lookup name (sessionDownValues session)
    }

restoreSymbolValues
  :: Text
  -> SymbolValueSnapshot
  -> EvaluationSession
  -> EvaluationSession
restoreSymbolValues name snapshot session =
  let restoredOwn = restoreDefinition name (snapshotOwnValue snapshot) session
   in restoredOwn
        { sessionDownValues =
            case snapshotDownValues snapshot of
              Nothing -> Map.delete name (sessionDownValues restoredOwn)
              Just definitions ->
                Map.insert name definitions (sessionDownValues restoredOwn)
        }

restoreDefinition :: Text -> Maybe Definition -> EvaluationSession -> EvaluationSession
restoreDefinition name = \case
  Nothing -> removeOwnValues [name]
  Just previous -> define name previous

symbolName :: Expr -> Maybe Text
symbolName (Symbol name) = Just name
symbolName _ = Nothing
