{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Immutable evaluation sessions with symbol own-values.
module Tungsten.Session
  ( Definition (..)
  , EvaluationSession (..)
  , emptySession
  , evaluateInSession
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Tungsten.Evaluate
import Tungsten.Expression

data Definition
  = ImmediateValue !Expr
  | DelayedValue !Expr
  deriving (Eq, Show)

newtype EvaluationSession = EvaluationSession
  { sessionDefinitions :: Map.Map Text Definition
  }
  deriving (Eq, Show)

emptySession :: EvaluationSession
emptySession = EvaluationSession Map.empty

data Iterator = Iterator !(Maybe Text) ![Expr]
  deriving (Eq, Show)

data ControlSignal
  = Thrown !Expr !(Maybe Expr) !(Maybe Expr)
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
  finalizeSessionResult (evaluateSessionAt 0 session expression)

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
    Right result -> Right result

evaluateSessionAt
  :: Int
  -> EvaluationSession
  -> Expr
  -> SessionResult Expr
evaluateSessionAt depth session expression
  | depth > 1024 =
      sessionFailure session "the session evaluation recursion limit was exceeded"
  | otherwise = case expression of
      Symbol name -> case Map.lookup name (sessionDefinitions session) of
        Nothing -> Right (expression, session)
        Just (ImmediateValue value)
          | value == expression -> Right (expression, session)
        Just (ImmediateValue value) -> evaluateSessionAt (depth + 1) session value
        Just (DelayedValue value) -> evaluateSessionAt (depth + 1) session value
      Call (Symbol "Set") [Symbol name, rhs] -> do
        (value, updated) <- evaluateSessionAt (depth + 1) session rhs
        pure (value, define name (ImmediateValue value) updated)
      Call (Symbol "SetDelayed") [Symbol name, rhs] ->
        Right (Symbol "Null", define name (DelayedValue rhs) session)
      Call (Symbol "Unset") [Symbol name] ->
        Right (Symbol "Null", removeDefinitions [name] session)
      Call (Symbol headName) symbols
        | headName `elem` ["Clear", "ClearAll"]
        , Just names <- traverse symbolName symbols ->
            Right (Symbol "Null", removeDefinitions names session)
      Call (Symbol "CompoundExpression") expressions ->
        evaluateSequence depth session expressions
      Call (Symbol "If") arguments' -> evaluateSessionIf depth session arguments'
      Call (Symbol "And") arguments' -> evaluateSessionAnd depth session arguments'
      Call (Symbol "Or") arguments' -> evaluateSessionOr depth session arguments'
      Call (Symbol "Catch") arguments' ->
        evaluateSessionCatch depth session arguments'
      Call (Symbol "Throw") arguments' ->
        evaluateSessionThrow depth session arguments'
      Call (Symbol "Table") arguments' ->
        evaluateSessionTable depth session arguments'
      Call (Symbol "Do") arguments' ->
        evaluateSessionDo depth session arguments'
      Call (Symbol "Sum") arguments' ->
        evaluateSessionAccumulator "Sum" "Plus" depth session arguments'
      Call (Symbol "Product") arguments' ->
        evaluateSessionAccumulator "Product" "Times" depth session arguments'
      Call (Symbol headName) [Symbol name, rhs]
        | Just constructor <- Map.lookup headName updateConstructors ->
            evaluateUpdate depth session name constructor rhs
      Call (Symbol headName) _
        | headName `elem` ["Hold", "HoldForm", "HoldPattern", "Unevaluated", "Function", "SetDelayed", "RuleDelayed"] ->
            Right (expression, session)
      Call expressionHead arguments' -> do
        (evaluatedHead, headSession) <- evaluateSessionAt (depth + 1) session expressionHead
        if isHeldSessionHead evaluatedHead
          then Right (Call evaluatedHead arguments', headSession)
          else do
            (evaluatedArguments, argumentsSession) <- evaluateArguments depth headSession arguments'
            let evaluatedCall = Call evaluatedHead evaluatedArguments
                normalizedCall = normalizeEvaluatedCall evaluatedHead evaluatedArguments
            reduced <- liftPureEvaluation argumentsSession (evaluate evaluatedCall)
            if reduced == normalizedCall
              then Right (reduced, argumentsSession)
              else evaluateSessionAt (depth + 1) argumentsSession reduced
      _ -> Right (expression, session)

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
    Right result -> Right result

catchMatches :: Maybe Expr -> Maybe Expr -> Bool
catchMatches Nothing Nothing = True
catchMatches (Just form) (Just tag) = matchesPattern tag form
catchMatches _ _ = False

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
      Left (IterationEvaluationFailure evaluationExit) ->
        Left evaluationExit
      Right (_, updated) -> Right (Symbol "Null", updated)
  _ -> Right (Call (Symbol "Do") arguments', session)

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
    (value, updated) <-
      liftIterationEvaluation
        (evaluateSessionAt (currentDepth + 1) current body)
    Right (if retainValues then value : retained else retained, updated)
  collect currentDepth current (iteratorSpec : remainingSpecs) retained = do
    (Iterator variable values, resolvedSession) <-
      resolveIterator currentDepth current iteratorSpec
    case variable of
      Nothing -> collectWithoutVariable currentDepth resolvedSession values retained
      Just name ->
        let previousDefinition =
              Map.lookup name (sessionDefinitions resolvedSession)
         in collectWithVariable
              currentDepth
              name
              previousDefinition
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
        , restoreDefinition name previous currentSession
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
      let previousDefinition = Map.lookup name (sessionDefinitions resolvedSession)
       in collectWithVariable name previousDefinition resolvedSession values []
 where
  collectWithoutVariable current [] results =
    Right (evaluatedList (reverse results), current)
  collectWithoutVariable current (_ : rest) results = do
    (value, updated) <- tableLoop (depth + 1) current body remainingSpecs
    collectWithoutVariable updated rest (value : results)
  collectWithVariable name previous current [] results =
    Right
      ( evaluatedList (reverse results)
      , restoreDefinition name previous current
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
  -> Maybe Definition
  -> IterationFailure
  -> IterationFailure
restoreIterationFailure name previous = \case
  InvalidIterator failedSession ->
    InvalidIterator (restoreDefinition name previous failedSession)
  IterationEvaluationFailure evaluationExit ->
    IterationEvaluationFailure
      ( mapEvaluationExitSession
          (restoreDefinition name previous)
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
  name `elem` ["Table", "Do", "Sum", "Product", "Catch", "Throw"]
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
  :: Int
  -> EvaluationSession
  -> Text
  -> (Expr -> Expr -> Expr)
  -> Expr
  -> SessionResult Expr
evaluateUpdate depth session name constructor rhs = do
  (current, currentSession) <- evaluateSessionAt (depth + 1) session (Symbol name)
  (value, valueSession) <- evaluateSessionAt (depth + 1) currentSession rhs
  result <- liftPureEvaluation valueSession (evaluate (constructor current value))
  pure (result, define name (ImmediateValue result) valueSession)

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

logicalResult :: Text -> Expr -> [Expr] -> Expr
logicalResult _ identity [] = identity
logicalResult _ _ [single] = single
logicalResult headName _ values = Call (Symbol headName) values

define :: Text -> Definition -> EvaluationSession -> EvaluationSession
define name value session =
  session {sessionDefinitions = Map.insert name value (sessionDefinitions session)}

removeDefinitions :: [Text] -> EvaluationSession -> EvaluationSession
removeDefinitions names session =
  session
    { sessionDefinitions =
        foldl (flip Map.delete) (sessionDefinitions session) names
    }

restoreDefinition :: Text -> Maybe Definition -> EvaluationSession -> EvaluationSession
restoreDefinition name = \case
  Nothing -> removeDefinitions [name]
  Just previous -> define name previous

symbolName :: Expr -> Maybe Text
symbolName (Symbol name) = Just name
symbolName _ = Nothing
