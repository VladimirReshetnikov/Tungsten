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

data IterationFailure
  = InvalidIterator !EvaluationSession
  | IterationEvaluationFailure !EvaluationError
  deriving (Eq, Show)

evaluateInSession :: EvaluationSession -> Expr -> Either EvaluationError (Expr, EvaluationSession)
evaluateInSession = evaluateSessionAt 0

evaluateSessionAt
  :: Int
  -> EvaluationSession
  -> Expr
  -> Either EvaluationError (Expr, EvaluationSession)
evaluateSessionAt depth session expression
  | depth > 1024 = Left (EvaluationError "the session evaluation recursion limit was exceeded")
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
      Call (Symbol "Table") arguments' ->
        evaluateSessionTable depth session arguments'
      Call (Symbol headName) [Symbol name, rhs]
        | Just constructor <- Map.lookup headName updateConstructors ->
            evaluateUpdate depth session name constructor rhs
      Call (Symbol headName) _
        | headName `elem` ["Hold", "HoldForm", "Unevaluated", "Function", "SetDelayed", "RuleDelayed"] ->
            Right (expression, session)
      Call expressionHead arguments' -> do
        (evaluatedHead, headSession) <- evaluateSessionAt (depth + 1) session expressionHead
        if evaluatedHead == Symbol "Table"
          then Right (Call evaluatedHead arguments', headSession)
          else do
            (evaluatedArguments, argumentsSession) <- evaluateArguments depth headSession arguments'
            let evaluatedCall = Call evaluatedHead evaluatedArguments
            reduced <- evaluate evaluatedCall
            if reduced == evaluatedCall
              then Right (reduced, argumentsSession)
              else evaluateSessionAt (depth + 1) argumentsSession reduced
      _ -> Right (expression, session)

evaluateSessionTable
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> Either EvaluationError (Expr, EvaluationSession)
evaluateSessionTable depth session arguments' = case arguments' of
  body : iteratorSpecs@(_ : _) ->
    case tableLoop depth session body iteratorSpecs of
      Left (InvalidIterator updated) ->
        Right (Call (Symbol "Table") arguments', updated)
      Left (IterationEvaluationFailure evaluationFailure) ->
        Left evaluationFailure
      Right result -> Right result
  _ -> Right (Call (Symbol "Table") arguments', session)

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
        Right (Iterator (Just name) (evaluatedListArguments values), updated)
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
  :: Either EvaluationError value
  -> Either IterationFailure value
liftIterationEvaluation = either (Left . IterationEvaluationFailure) Right

restoreIterationFailure
  :: Text
  -> Maybe Definition
  -> IterationFailure
  -> IterationFailure
restoreIterationFailure name previous = \case
  InvalidIterator failedSession ->
    InvalidIterator (restoreDefinition name previous failedSession)
  failure -> failure

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

evaluateSequence
  :: Int
  -> EvaluationSession
  -> [Expr]
  -> Either EvaluationError (Expr, EvaluationSession)
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
  -> Either EvaluationError (Expr, EvaluationSession)
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
  -> Either EvaluationError (Expr, EvaluationSession)
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
  -> Either EvaluationError (Expr, EvaluationSession)
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
  -> Either EvaluationError ([Expr], EvaluationSession)
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
  -> Either EvaluationError (Expr, EvaluationSession)
evaluateUpdate depth session name constructor rhs = do
  (current, currentSession) <- evaluateSessionAt (depth + 1) session (Symbol name)
  (value, valueSession) <- evaluateSessionAt (depth + 1) currentSession rhs
  result <- evaluate (constructor current value)
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
