{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | JSON-first command-line entry points for the Haskell engine.
module Tungsten.Cli
  ( CliCommand (..)
  , ExpressionCommand (..)
  , NotebookCommand (..)
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
import Tungsten.Notebook
import Tungsten.Parser

data CliCommand
  = ProtocolCommand
  | ExpressionCliCommand !ExpressionCommand !SourceSpec !Text
  | NotebookCliCommand !NotebookCommand
  | HelpCommand
  deriving (Eq, Show)

data ExpressionCommand = ParseCommand | EvaluateCommand
  deriving (Eq, Show)

data SourceSpec = InlineSource !Text | FileSource !FilePath
  deriving (Eq, Show)

data NotebookCommand
  = InspectNotebookCommand !FilePath
  | CreateNotebookCommand !FilePath !(Maybe Text) ![(Text, Text)]
  deriving (Eq, Show)

parseCliArguments :: [String] -> Either Text CliCommand
parseCliArguments = \case
  [] -> Right ProtocolCommand
  ["protocol"] -> Right ProtocolCommand
  ["--help"] -> Right HelpCommand
  ["-h"] -> Right HelpCommand
  "expr" : "parse" : arguments' -> parseExpressionArguments ParseCommand arguments'
  "expr" : "evaluate" : arguments' -> parseExpressionArguments EvaluateCommand arguments'
  "notebook" : "inspect" : arguments' -> parseNotebookInspectArguments arguments'
  "notebook" : "create" : arguments' -> parseNotebookCreateArguments arguments'
  _ -> Left "expected 'protocol', an 'expr' command, or a 'notebook' command"

parseNotebookInspectArguments :: [String] -> Either Text CliCommand
parseNotebookInspectArguments ["--file", path] =
  Right (NotebookCliCommand (InspectNotebookCommand path))
parseNotebookInspectArguments [] = Left "notebook inspect requires --file PATH"
parseNotebookInspectArguments _ = Left "usage: notebook inspect --file PATH"

parseNotebookCreateArguments :: [String] -> Either Text CliCommand
parseNotebookCreateArguments = go Nothing Nothing []
 where
  go file title cells [] = case file of
    Nothing -> Left "notebook create requires --file PATH"
    Just path -> Right (NotebookCliCommand (CreateNotebookCommand path title (reverse cells)))
  go Nothing title cells ("--file" : path : rest) = go (Just path) title cells rest
  go (Just _) _ _ ("--file" : _ : _) = Left "notebook create accepts --file only once"
  go file Nothing cells ("--title" : value : rest) = go file (Just (T.pack value)) cells rest
  go _ (Just _) _ ("--title" : _ : _) = Left "notebook create accepts --title only once"
  go file title cells ("--cell" : specification : rest) = do
    cell <- parseCellSpecification (T.pack specification)
    go file title (cell : cells) rest
  go _ _ _ [flag]
    | flag `elem` ["--file", "--title", "--cell"] = Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown notebook create option: " <> T.pack flag)

parseCellSpecification :: Text -> Either Text (Text, Text)
parseCellSpecification specification =
  let (style, remainder) = T.breakOn ":" specification
   in if T.null style || T.null remainder
        then Left "notebook cells must use STYLE:TEXT"
        else Right (style, T.drop 1 remainder)

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
  Right (NotebookCliCommand command) -> runNotebookCommand command

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

runNotebookCommand :: NotebookCommand -> IO Int
runNotebookCommand = \case
  InspectNotebookCommand path -> do
    sourceResult <- readSource (FileSource path)
    case sourceResult of
      Left message -> emitNotebookError "inspect" "InputError" message
      Right source -> case parseNotebook source of
        Left notebookError ->
          emitNotebookError "inspect" "NotebookError" (notebookErrorMessage notebookError)
        Right document -> emitJson (notebookPayload document) *> pure 0
  CreateNotebookCommand path title cells -> do
    let document = createNotebook title cells
    writeResult <- try (TextIO.writeFile path (renderNotebook document))
    case (writeResult :: Either IOException ()) of
      Left exception -> emitNotebookError "create" "OutputError" (T.pack (show exception))
      Right () -> emitJson (notebookPayload document) *> pure 0

notebookPayload :: NotebookDocument -> JsonValue
notebookPayload document =
  JsonObject
    ( Map.fromList
        [ ("cell_count", jsonInteger (fromIntegral (cellCount document)))
        , ("cells", JsonArray (map cellRecordPayload (flattenCells document)))
        , ("group_count", jsonInteger (fromIntegral (groupCount document)))
        , ("options", JsonArray (map (JsonString . fullForm) (notebookOptions document)))
        , ("title", maybe JsonNull JsonString (notebookTitle document))
        ]
    )

cellRecordPayload :: CellRecord -> JsonValue
cellRecordPayload record =
  JsonObject
    ( Map.fromList
        [ ("cell_id", maybe JsonNull jsonInteger (cellId cell))
        , ("cell_tags", JsonArray (map JsonString (cellTags cell)))
        , ("depth", jsonInteger (fromIntegral (max 0 (length (cellRecordPath record) - 1))))
        , ("expression_uuid", maybe JsonNull JsonString (expressionUuid cell))
        , ("index", jsonInteger (fromIntegral (cellRecordIndex record)))
        , ("kind", JsonString "cell")
        , ("options", JsonArray (map (JsonString . fullForm) (cellOptions cell)))
        , ("path", JsonArray (map (jsonInteger . fromIntegral) (cellRecordPath record)))
        , ("preview", JsonString (cellRecordPreview record))
        , ("style", maybe JsonNull JsonString (cellRecordStyle record))
        ]
    )
 where
  cell = cellRecordCell record

emitNotebookError :: Text -> Text -> Text -> IO Int
emitNotebookError command errorType message = do
  emitJson
    ( JsonObject
        ( Map.fromList
            [ ("command", JsonString command)
            , ("error", JsonString message)
            , ("error_type", JsonString errorType)
            , ("success", JsonBool False)
            ]
        )
    )
  pure 1

jsonInteger :: Integer -> JsonValue
jsonInteger = JsonNumber . T.pack . show

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
    , "  tungsten-hs notebook inspect --file PATH"
    , "  tungsten-hs notebook create --file PATH [--title TEXT] [--cell STYLE:TEXT ...]"
    , ""
    , "With no arguments, tungsten-hs serves the JSON-lines protocol for backward compatibility."
    ]
