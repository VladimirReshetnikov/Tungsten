{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Immutable evaluation sessions with ordered symbol value definitions.
module Tungsten.Session
  ( Definition (..)
  , DownValue (..)
  , EvaluationSession (..)
  , emptySession
  , evaluateInSession
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Evaluate
import Tungsten.Expression

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

data EvaluationSession = EvaluationSession
  { sessionDefinitions :: Map.Map Text Definition
  , sessionDownValues :: Map.Map Text [DownValue]
  , sessionModuleCounter :: !Integer
  }
  deriving (Eq, Show)

emptySession :: EvaluationSession
emptySession = EvaluationSession Map.empty Map.empty 0

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
            evaluateUpdate depth session name constructor rhs
      Call (Symbol headName) _
        | headName `elem` ["Hold", "HoldComplete", "HoldForm", "HoldPattern", "Unevaluated", "Function", "SetDelayed", "RuleDelayed", "Condition"] ->
            Right (expression, session)
      Call expressionHead arguments' -> do
        (evaluatedHead, headSession) <- evaluateSessionAt (depth + 1) session expressionHead
        if isHeldSessionHead evaluatedHead
          then Right (Call evaluatedHead arguments', headSession)
          else do
            (evaluatedArguments, argumentsSession) <- evaluateArguments depth headSession arguments'
            let evaluatedCall = Call evaluatedHead evaluatedArguments
                normalizedCall = normalizeEvaluatedCall evaluatedHead evaluatedArguments
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
                  Nothing -> do
                    reduced <-
                      liftPureEvaluation definitionSession (evaluate evaluatedCall)
                    if reduced == normalizedCall || evaluatedHead == Symbol "Level"
                      then Right (reduced, definitionSession)
                      else evaluateSessionAt (depth + 1) definitionSession reduced
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
