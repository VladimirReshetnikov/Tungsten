{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | JSON-first command-line entry points for the Haskell engine.
module Tungsten.Cli
  ( CliCommand (..)
  , ExpressionCommand (..)
  , SourceSpec (..)
  , parseCliArguments
  , runCli
  ) where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import System.IO
  ( BufferMode (LineBuffering)
  , hIsEOF
  , hSetBuffering
  , hSetEncoding
  , stderr
  , stdin
  , stdout
  , utf8
  )
import Tungsten.Evaluate (evaluate, evaluationErrorMessage)
import Tungsten.Expression
import Tungsten.Json
import Tungsten.Parser

data CliCommand
  = ProtocolCommand
  | ExpressionCliCommand !ExpressionCommand !SourceSpec !Text
  | HelpCommand
  deriving (Eq, Show)

data ExpressionCommand = ParseCommand | EvaluateCommand
  deriving (Eq, Show)

data SourceSpec = InlineSource !Text | FileSource !FilePath
  deriving (Eq, Show)

parseCliArguments :: [String] -> Either Text CliCommand
parseCliArguments = \case
  [] -> Right ProtocolCommand
  ["protocol"] -> Right ProtocolCommand
  ["--help"] -> Right HelpCommand
  ["-h"] -> Right HelpCommand
  "expr" : "parse" : arguments' -> parseExpressionArguments ParseCommand arguments'
  "expr" : "evaluate" : arguments' -> parseExpressionArguments EvaluateCommand arguments'
  _ -> Left "expected 'protocol', 'expr parse', or 'expr evaluate'"

parseExpressionArguments :: ExpressionCommand -> [String] -> Either Text CliCommand
parseExpressionArguments expressionCommand = go Nothing "input"
 where
  go source form [] = case source of
    Nothing -> Left "expression commands require exactly one of --code or --file"
    Just sourceSpec -> Right (ExpressionCliCommand expressionCommand sourceSpec form)
  go source form ("--code" : value : rest) =
    addSource source (InlineSource (T.pack value)) >>= \updated -> go (Just updated) form rest
  go source form ("--file" : value : rest) =
    addSource source (FileSource value) >>= \updated -> go (Just updated) form rest
  go source _ ("--form" : value : rest) = go source (T.pack value) rest
  go _ _ [flag]
    | flag `elem` ["--code", "--file", "--form"] = Left (T.pack flag <> " requires a value")
  go _ _ (flag : _) = Left ("unknown expression option: " <> T.pack flag)
  addSource Nothing value = Right value
  addSource (Just _) _ = Left "--code and --file are mutually exclusive"

runCli :: [String] -> IO Int
runCli arguments' = case parseCliArguments arguments' of
  Left message -> do
    TextIO.hPutStrLn stderr ("tungsten-hs: " <> message)
    TextIO.hPutStrLn stderr usage
    pure 2
  Right HelpCommand -> TextIO.putStrLn usage *> pure 0
  Right ProtocolCommand -> configureHandles *> serveProtocol *> pure 0
  Right (ExpressionCliCommand command sourceSpec form) ->
    runExpressionCommand command sourceSpec form

configureHandles :: IO ()
configureHandles = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  hSetBuffering stdout LineBuffering

serveProtocol :: IO ()
serveProtocol = do
  finished <- hIsEOF stdin
  if finished
    then pure ()
    else do
      line <- TextIO.hGetLine stdin
      let response = case decodeRequestLine line of
            Left jsonError -> ProtocolFailure Nothing "" (jsonErrorMessage jsonError)
            Right request -> handleProtocolRequest request
      TextIO.putStr (encodeResponseLine response)
      serveProtocol

runExpressionCommand :: ExpressionCommand -> SourceSpec -> Text -> IO Int
runExpressionCommand command sourceSpec requestedForm = do
  sourceResult <- readSource sourceSpec
  case sourceResult of
    Left message -> emitError command requestedForm "InputError" message Nothing
    Right source -> case parseSource requestedForm source of
      Left message -> emitError command requestedForm "ParseError" message Nothing
      Right (normalizedForm, expression) -> case command of
        ParseCommand -> do
          emitJson (parsePayload normalizedForm source expression)
          pure 0
        EvaluateCommand -> case evaluate expression of
          Left evaluationError ->
            emitError
              command
              normalizedForm
              "EvaluationError"
              (evaluationErrorMessage evaluationError)
              (Just expression)
          Right result -> do
            emitJson (evaluationPayload normalizedForm source expression result)
            pure 0

readSource :: SourceSpec -> IO (Either Text Text)
readSource (InlineSource source) = pure (Right source)
readSource (FileSource path) = do
  result <- try (TextIO.readFile path)
  pure $ first (T.pack . show) (result :: Either IOException Text)

parseSource :: Text -> Text -> Either Text (Text, Expr)
parseSource requestedForm source = case T.toLower (T.strip requestedForm) of
  "input" -> parseWith "input" parseInputForm
  "inputform" -> parseWith "input" parseInputForm
  "full" -> parseWith "fullform" parseFullForm
  "fullform" -> parseWith "fullform" parseFullForm
  other -> Left ("unsupported expression form: " <> other)
 where
  parseWith normalized parser = (normalized,) <$> first parseErrorMessage (parser source)

parsePayload :: Text -> Text -> Expr -> JsonValue
parsePayload form source expression =
  JsonObject
    ( Map.fromList
        [ ("command", JsonString "parse")
        , ("depth", JsonNumber (T.pack (show (expressionDepth expression))))
        , ("form", JsonString form)
        , ("full_form", JsonString (fullForm expression))
        , ("length", JsonNumber (T.pack (show (length (arguments expression)))))
        , ("source", JsonString source)
        , ("success", JsonBool True)
        , ("tree", exprToJson expression)
        ]
    )

evaluationPayload :: Text -> Text -> Expr -> Expr -> JsonValue
evaluationPayload form source parsed result =
  JsonObject
    ( Map.fromList
        [ ("command", JsonString "evaluate")
        , ("form", JsonString form)
        , ("parsed_full_form", JsonString (fullForm parsed))
        , ("parsed_tree", exprToJson parsed)
        , ("result", expressionPayload result)
        , ("source", JsonString source)
        , ("success", JsonBool True)
        ]
    )

expressionPayload :: Expr -> JsonValue
expressionPayload expression =
  JsonObject
    ( Map.fromList
        [ ("depth", JsonNumber (T.pack (show (expressionDepth expression))))
        , ("full_form", JsonString (fullForm expression))
        , ("length", JsonNumber (T.pack (show (length (arguments expression)))))
        , ("tree", exprToJson expression)
        ]
    )

emitError :: ExpressionCommand -> Text -> Text -> Text -> Maybe Expr -> IO Int
emitError command form errorType message parsed = do
  emitJson
    ( JsonObject
        ( withParsed
            ( Map.fromList
                [ ("command", JsonString (commandName command))
                , ("error", JsonString message)
                , ("error_type", JsonString errorType)
                , ("form", JsonString form)
                , ("success", JsonBool False)
                ]
            )
        )
    )
  pure 1
 where
  withParsed = case parsed of
    Nothing -> id
    Just expression ->
      Map.insert "parsed_full_form" (JsonString (fullForm expression))
        . Map.insert "parsed_tree" (exprToJson expression)

emitJson :: JsonValue -> IO ()
emitJson = TextIO.putStrLn . encodeJson

commandName :: ExpressionCommand -> Text
commandName ParseCommand = "parse"
commandName EvaluateCommand = "evaluate"

expressionDepth :: Expr -> Int
expressionDepth expression = case arguments expression of
  [] -> 1
  values -> 1 + maximum (map expressionDepth values)

usage :: Text
usage =
  T.unlines
    [ "Usage:"
    , "  tungsten-hs protocol"
    , "  tungsten-hs expr parse (--code TEXT | --file PATH) [--form input|fullform]"
    , "  tungsten-hs expr evaluate (--code TEXT | --file PATH) [--form input|fullform]"
    , ""
    , "With no arguments, tungsten-hs serves the JSON-lines protocol for backward compatibility."
    ]
