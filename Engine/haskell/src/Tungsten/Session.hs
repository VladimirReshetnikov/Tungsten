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
      Call (Symbol headName) [Symbol name, rhs]
        | Just constructor <- Map.lookup headName updateConstructors ->
            evaluateUpdate depth session name constructor rhs
      Call (Symbol headName) _
        | headName `elem` ["Hold", "HoldForm", "Unevaluated", "Function", "SetDelayed", "RuleDelayed"] ->
            Right (expression, session)
      Call expressionHead arguments' -> do
        (evaluatedHead, headSession) <- evaluateSessionAt (depth + 1) session expressionHead
        (evaluatedArguments, argumentsSession) <- evaluateArguments depth headSession arguments'
        let evaluatedCall = Call evaluatedHead evaluatedArguments
        reduced <- evaluate evaluatedCall
        if reduced == evaluatedCall
          then Right (reduced, argumentsSession)
          else evaluateSessionAt (depth + 1) argumentsSession reduced
      _ -> Right (expression, session)

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

symbolName :: Expr -> Maybe Text
symbolName (Symbol name) = Just name
symbolName _ = Nothing
