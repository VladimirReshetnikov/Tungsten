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
import System.IO (hFlush, isEOF, stdout)
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
    }

evaluateReplLine :: ReplState -> Text -> ReplStep
evaluateReplLine state source
  | T.null (T.strip source) = ReplEmpty state
  | otherwise = case parseInputForm source of
      Left parseError -> ReplFailure (parseErrorMessage parseError) state
      Right parsed ->
        let line = replNextLine state
            withInput =
              state
                { replInputHistory = Map.insert line parsed (replInputHistory state)
                , replInputStrings = Map.insert line source (replInputStrings state)
                }
            resolved = resolveHistory withInput parsed
         in case evaluateInSession (replSession state) resolved of
              Left evaluationError ->
                ReplFailure
                  (evaluationErrorMessage evaluationError)
                  withInput {replNextLine = line + 1}
              Right (result, updatedSession) -> case exitCode result of
                Just code -> ReplExit code withInput {replSession = updatedSession}
                Nothing ->
                  let updated =
                        withInput
                          { replSession = updatedSession
                          , replNextLine = line + 1
                          , replOutputHistory = Map.insert line result (replOutputHistory state)
                          }
                   in ReplValue line result updated

resolveHistory :: ReplState -> Expr -> Expr
resolveHistory state expression = case expression of
  Symbol "$Line" -> Integer (replNextLine state)
  Call (Symbol "Out") [] -> outputAt (replNextLine state - 1)
  Call (Symbol "Out") [Integer index]
    | index < 0 -> outputAt (replNextLine state + index)
    | otherwise -> outputAt index
  Call (Symbol "In") [Integer index] ->
    maybe expression id (Map.lookup index (replInputHistory state))
  Call (Symbol "InString") [Integer index] ->
    maybe expression String (Map.lookup index (replInputStrings state))
  Call (Symbol headName) _
    | headName `elem` ["Hold", "HoldForm", "Unevaluated"] -> expression
  Call expressionHead arguments' ->
    Call (resolveHistory state expressionHead) (map (resolveHistory state) arguments')
  _ -> expression
 where
  outputAt index = maybe expression id (Map.lookup index (replOutputHistory state))

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
        case evaluateReplLine state source of
          ReplEmpty updated -> loop updated
          ReplFailure message updated -> TextIO.putStrLn ("Error: " <> message) *> loop updated
          ReplExit code _ -> pure code
          ReplValue line value updated -> do
            TextIO.putStrLn ("Out[" <> T.pack (show line) <> "]= " <> fullForm value)
            loop updated
