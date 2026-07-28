{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | A small @wolfram.exe@-style interactive loop over immutable sessions.
module Tungsten.Repl
  ( ReplState (..)
  , ReplStep (..)
  , initialReplState
  , evaluateReplLine
  , runRepl
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import System.IO (hFlush, isEOF, stderr, stdout)
import Tungsten.Evaluate (evaluationErrorMessage)
import Tungsten.Expression
import Tungsten.Parser
import Tungsten.Session

data ReplState = ReplState
  { replSession :: !EvaluationSession
  , replNextLine :: !Integer
  , replInputHistory :: !(Map.Map Integer Expr)
  , replInputStrings :: !(Map.Map Integer Text)
  , replOutputHistory :: !(Map.Map Integer Expr)
  , replMessageHistory :: !(Map.Map Integer [EvaluationMessage])
  }
  deriving (Eq, Show)

data ReplStep
  = ReplValue !Integer !Expr !ReplState
  | ReplExit !Int !ReplState
  | ReplFailure !Text !ReplState
  | ReplEmpty !ReplState
  deriving (Eq, Show)

initialReplState :: ReplState
initialReplState =
  ReplState
    { replSession = emptySession
    , replNextLine = 1
    , replInputHistory = Map.empty
    , replInputStrings = Map.empty
    , replOutputHistory = Map.empty
    , replMessageHistory = Map.empty
    }

evaluateReplLine :: ReplState -> Text -> IO ReplStep
evaluateReplLine state source
  | T.null (T.strip source) = pure (ReplEmpty state)
  | otherwise = case parseInputForm source of
      Left parseError -> pure (ReplFailure (parseErrorMessage parseError) transientState)
      Right parsed -> do
        let line = replNextLine state
            withUnprunedInput =
              transientState
                { replInputHistory = Map.insert line parsed (replInputHistory state)
                , replInputStrings = Map.insert line source (replInputStrings state)
                }
            withInput =
              pruneReplHistory
                line
                transientSession
                withUnprunedInput
            activeSession = installReplHistory line withInput transientSession
            activeState = withInput {replSession = activeSession}
        evaluateInSession activeSession parsed >>= \case
          Left evaluationError ->
            pure
              ( ReplFailure
                  (evaluationErrorMessage evaluationError)
                  activeState {replNextLine = line + 1}
              )
          Right (result, updatedSession) -> pure $ case exitCode result of
            Just code ->
              let finished =
                    finishReplHistory
                      line
                      Nothing
                      activeState
                      updatedSession
               in ReplExit code finished
            Nothing ->
              ReplValue
                line
                result
                (finishReplHistory line (Just result) activeState updatedSession)
 where
  transientSession =
    (replSession state)
      { sessionGeneratedMessages = []
      , sessionVisibleMessages = []
      , sessionPrints = []
      }
  transientState = state {replSession = transientSession}

installReplHistory
  :: Integer
  -> ReplState
  -> EvaluationSession
  -> EvaluationSession
installReplHistory line state session =
  session
    { sessionHistoryLine = Just line
    , sessionInputHistory = replInputHistory state
    , sessionInputStringHistory = replInputStrings state
    , sessionOutputHistory = replOutputHistory state
    , sessionMessageHistory = replMessageHistory state
    }

finishReplHistory
  :: Integer
  -> Maybe Expr
  -> ReplState
  -> EvaluationSession
  -> ReplState
finishReplHistory line output state session =
  let withEffects =
        state
          { replNextLine = line + 1
          , replOutputHistory =
              maybe
                (replOutputHistory state)
                (\value -> Map.insert line value (replOutputHistory state))
                output
          , replMessageHistory =
              Map.insert
                line
                (sessionVisibleMessages session)
                (replMessageHistory state)
          }
      retained = pruneReplHistory line session withEffects
   in retained
        { replSession = installReplHistory line retained session
        }

pruneReplHistory :: Integer -> EvaluationSession -> ReplState -> ReplState
pruneReplHistory line session state =
  case sessionHistoryLengthLimit session of
    Nothing -> state
    Just retainedLength ->
      let cutoff = line - retainedLength + 1
          retained = Map.filterWithKey (\index _ -> index >= cutoff)
       in state
            { replInputHistory = retained (replInputHistory state)
            , replInputStrings = retained (replInputStrings state)
            , replOutputHistory = retained (replOutputHistory state)
            , replMessageHistory = retained (replMessageHistory state)
            }

exitCode :: Expr -> Maybe Int
exitCode = \case
  Symbol "Exit" -> Just 0
  Symbol "Quit" -> Just 0
  Call (Symbol "Exit") [] -> Just 0
  Call (Symbol "Quit") [] -> Just 0
  Call (Symbol "Exit") [Integer value] -> Just (fromInteger value)
  Call (Symbol "Quit") [Integer value] -> Just (fromInteger value)
  _ -> Nothing

runRepl :: Bool -> IO Int
runRepl showBanner = do
  if showBanner
    then TextIO.putStrLn "Tungsten Haskell kernel-free REPL. Exit with Exit[] or Quit[]."
    else pure ()
  loop initialReplState
 where
  loop state = do
    TextIO.putStr ("In[" <> T.pack (show (replNextLine state)) <> "]:= ")
    hFlush stdout
    finished <- isEOF
    if finished
      then TextIO.putStrLn "" *> pure 0
      else do
        source <- TextIO.getLine
        evaluateReplLine state source >>= \case
          ReplEmpty updated -> loop updated
          ReplFailure message updated -> TextIO.putStrLn ("Error: " <> message) *> loop updated
          ReplExit code updated -> emitSessionStreams updated *> pure code
          ReplValue line value updated -> do
            emitSessionStreams updated
            TextIO.putStrLn ("Out[" <> T.pack (show line) <> "]= " <> fullForm value)
            loop updated

  emitSessionStreams updated = do
    mapM_ TextIO.putStrLn (sessionPrints (replSession updated))
    mapM_
      (TextIO.hPutStrLn stderr . evaluationMessageText)
      (sessionVisibleMessages (replSession updated))
    hFlush stderr
