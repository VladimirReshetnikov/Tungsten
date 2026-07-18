{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | JSON-first command-line entry points for the Haskell engine.
module Tungsten.Cli
  ( CliCommand (..)
  , ExpressionCommand (..)
  , NotebookCommand (..)
  , FrontEndCommand (..)
  , SourceSpec (..)
  , parseCliArguments
  , decodeNotebookPatches
  , runCli
  ) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import Text.Read (readMaybe)
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
import Tungsten.Discovery
import Tungsten.Expression
import Tungsten.Frontend
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.Licensing
import Tungsten.Notebook
import Tungsten.Parser
import Tungsten.Repl (runRepl)

data CliCommand
  = ProtocolCommand
  | ReplCommand !Bool
  | EnvironmentCommand !Bool
  | KernelCommand !SourceSpec !(Maybe FilePath) !Bool !Bool
  | FrontEndCommand !FrontEndCommand
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
  | PatchNotebookCommand !FilePath !FilePath !(Maybe FilePath)
  deriving (Eq, Show)

data FrontEndCommand
  = ProbeFrontEndCommand !Bool
  | RunFrontEndCommand !Text !Bool !Bool
  | OpenFrontEndNotebookCommand !FilePath !Bool
  | OpenFrontEndDocumentationCommand !Text !Bool
  | ExecuteFrontEndTokenCommand !Text !(Maybe FilePath) !Bool
  deriving (Eq, Show)

parseCliArguments :: [String] -> Either Text CliCommand
parseCliArguments = \case
  [] -> Right ProtocolCommand
  ["protocol"] -> Right ProtocolCommand
  ["repl"] -> Right (ReplCommand True)
  ["repl", "--no-banner"] -> Right (ReplCommand False)
  ["env", "show"] -> Right (EnvironmentCommand False)
  ["env", "show", "--probe"] -> Right (EnvironmentCommand True)
  ["--help"] -> Right HelpCommand
  ["-h"] -> Right HelpCommand
  "expr" : "parse" : arguments' -> parseExpressionArguments ParseCommand arguments'
  "expr" : "evaluate" : arguments' -> parseExpressionArguments EvaluateCommand arguments'
  "kernel" : "eval" : arguments' -> parseKernelArguments arguments'
  "frontend" : "probe" : arguments' ->
    FrontEndCommand . ProbeFrontEndCommand <$> parseRequireSuccess arguments'
  "frontend" : "run" : arguments' -> parseFrontEndRunArguments arguments'
  "frontend" : "open-notebook" : arguments' -> parseFrontEndOpenNotebookArguments arguments'
  "frontend" : "open-doc" : identifier : arguments' ->
    FrontEndCommand . OpenFrontEndDocumentationCommand (T.pack identifier)
      <$> parseRequireSuccess arguments'
  "frontend" : "token" : token : arguments' -> parseFrontEndTokenArguments (T.pack token) arguments'
  "notebook" : "inspect" : arguments' -> parseNotebookInspectArguments arguments'
  "notebook" : "create" : arguments' -> parseNotebookCreateArguments arguments'
  "notebook" : "patch" : arguments' -> parseNotebookPatchArguments arguments'
  _ -> Left "expected 'protocol', 'repl', an 'expr' command, or a 'notebook' command"

parseNotebookInspectArguments :: [String] -> Either Text CliCommand
parseNotebookInspectArguments ["--file", path] =
  Right (NotebookCliCommand (InspectNotebookCommand path))
parseNotebookInspectArguments [] = Left "notebook inspect requires --file PATH"
parseNotebookInspectArguments _ = Left "usage: notebook inspect --file PATH"

parseKernelArguments :: [String] -> Either Text CliCommand
parseKernelArguments = go Nothing Nothing False False
 where
  go source workingDirectory requireFrontEnd requireSuccess [] = case source of
    Nothing -> Left "kernel eval requires exactly one of --code or --file"
    Just sourceSpec -> Right (KernelCommand sourceSpec workingDirectory requireFrontEnd requireSuccess)
  go Nothing work frontEnd requireSuccess ("--code" : value : rest) =
    go (Just (InlineSource (T.pack value))) work frontEnd requireSuccess rest
  go Nothing work frontEnd requireSuccess ("--file" : value : rest) =
    go (Just (FileSource value)) work frontEnd requireSuccess rest
  go (Just _) _ _ _ ((flag@("--code")) : _ : _) = Left (T.pack flag <> " conflicts with the existing kernel source")
  go (Just _) _ _ _ ((flag@("--file")) : _ : _) = Left (T.pack flag <> " conflicts with the existing kernel source")
  go source Nothing frontEnd requireSuccess ("--working-directory" : value : rest) =
    go source (Just value) frontEnd requireSuccess rest
  go _ (Just _) _ _ ("--working-directory" : _ : _) = Left "--working-directory may be supplied only once"
  go source work _ requireSuccess ("--front-end" : rest) = go source work True requireSuccess rest
  go source work frontEnd _ ("--require-success" : rest) = go source work frontEnd True rest
  go _ _ _ _ [flag]
    | flag `elem` ["--code", "--file", "--working-directory"] = Left (T.pack flag <> " requires a value")
  go _ _ _ _ (flag : _) = Left ("unknown kernel eval option: " <> T.pack flag)

parseRequireSuccess :: [String] -> Either Text Bool
parseRequireSuccess [] = Right False
parseRequireSuccess ["--require-success"] = Right True
parseRequireSuccess _ = Left "only --require-success is accepted for this FrontEnd command"

parseFrontEndRunArguments :: [String] -> Either Text CliCommand
parseFrontEndRunArguments = go Nothing True False
 where
  go (Just code) wrap requireSuccess [] =
    Right (FrontEndCommand (RunFrontEndCommand code wrap requireSuccess))
  go Nothing _ _ [] = Left "frontend run requires --code TEXT"
  go Nothing wrap requireSuccess ("--code" : value : rest) =
    go (Just (T.pack value)) wrap requireSuccess rest
  go (Just _) _ _ ("--code" : _ : _) = Left "frontend run accepts --code only once"
  go code _ requireSuccess ("--no-wrap" : rest) = go code False requireSuccess rest
  go code wrap _ ("--require-success" : rest) = go code wrap True rest
  go _ _ _ ["--code"] = Left "--code requires a value"
  go _ _ _ (flag : _) = Left ("unknown frontend run option: " <> T.pack flag)

parseFrontEndOpenNotebookArguments :: [String] -> Either Text CliCommand
parseFrontEndOpenNotebookArguments = go Nothing False
 where
  go (Just path) requireSuccess [] =
    Right (FrontEndCommand (OpenFrontEndNotebookCommand path requireSuccess))
  go Nothing _ [] = Left "frontend open-notebook requires --file PATH"
  go Nothing requireSuccess ("--file" : value : rest) = go (Just value) requireSuccess rest
  go (Just _) _ ("--file" : _ : _) = Left "frontend open-notebook accepts --file only once"
  go path _ ("--require-success" : rest) = go path True rest
  go _ _ ["--file"] = Left "--file requires a value"
  go _ _ (flag : _) = Left ("unknown frontend open-notebook option: " <> T.pack flag)

parseFrontEndTokenArguments :: Text -> [String] -> Either Text CliCommand
parseFrontEndTokenArguments token = go Nothing False
 where
  go notebookPath requireSuccess [] =
    Right (FrontEndCommand (ExecuteFrontEndTokenCommand token notebookPath requireSuccess))
  go Nothing requireSuccess ("--file" : value : rest) = go (Just value) requireSuccess rest
  go (Just _) _ ("--file" : _ : _) = Left "frontend token accepts --file only once"
  go path _ ("--require-success" : rest) = go path True rest
  go _ _ ["--file"] = Left "--file requires a value"
  go _ _ (flag : _) = Left ("unknown frontend token option: " <> T.pack flag)

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

parseNotebookPatchArguments :: [String] -> Either Text CliCommand
parseNotebookPatchArguments = go Nothing Nothing Nothing
 where
  go notebookFile specFile outputFile [] = case (notebookFile, specFile) of
    (Just notebookPath, Just specPath) ->
      Right (NotebookCliCommand (PatchNotebookCommand notebookPath specPath outputFile))
    _ -> Left "notebook patch requires --file PATH and --spec PATH"
  go Nothing spec output ("--file" : path : rest) = go (Just path) spec output rest
  go (Just _) _ _ ("--file" : _ : _) = Left "notebook patch accepts --file only once"
  go file Nothing output ("--spec" : path : rest) = go file (Just path) output rest
  go _ (Just _) _ ("--spec" : _ : _) = Left "notebook patch accepts --spec only once"
  go file spec Nothing ("--out" : path : rest) = go file spec (Just path) rest
  go _ _ (Just _) ("--out" : _ : _) = Left "notebook patch accepts --out only once"
  go _ _ _ [flag]
    | flag `elem` ["--file", "--spec", "--out"] = Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown notebook patch option: " <> T.pack flag)

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
  Right (ReplCommand showBanner) -> configureHandles *> runRepl showBanner
  Right (EnvironmentCommand includeProbe) -> do
    installation <- discoverInstallation
    payload <- if includeProbe
      then do
        evaluation <- evaluateKernelText installation "2+2" Nothing False
        frontEnd <- probeFrontEnd installation
        pure (addEnvironmentProbe evaluation frontEnd (installationPayload installation))
      else pure (installationPayload installation)
    emitJson payload
    pure 0
  Right (KernelCommand sourceSpec workingDirectory requireFrontEnd requireSuccess) -> do
    installation <- discoverInstallation
    result <- case sourceSpec of
      InlineSource source -> evaluateKernelText installation source workingDirectory requireFrontEnd
      FileSource path -> evaluateKernelFile installation path workingDirectory requireFrontEnd
    emitJson (kernelPayload result)
    pure $ if requireSuccess && kernelSuccess result == Just False
      then 1
      else if kernelEvaluationAvailable result then 0 else 2
  Right (FrontEndCommand command) -> runFrontEndCommand command
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
  PatchNotebookCommand notebookPath specPath outputPath -> do
    notebookSource <- readSource (FileSource notebookPath)
    specSource <- readSource (FileSource specPath)
    case (notebookSource, specSource) of
      (Left message, _) -> emitNotebookError "patch" "InputError" message
      (_, Left message) -> emitNotebookError "patch" "InputError" message
      (Right source, Right specText) -> case parseNotebook source of
        Left notebookError ->
          emitNotebookError "patch" "NotebookError" (notebookErrorMessage notebookError)
        Right document -> case parseJson specText of
          Left jsonError -> emitNotebookError "patch" "JsonError" (jsonErrorMessage jsonError)
          Right payload -> case decodeNotebookPatches payload of
            Left message -> emitNotebookError "patch" "PatchError" message
            Right patches -> case applyNotebookPatches patches document of
              Left notebookError ->
                emitNotebookError "patch" "PatchError" (notebookErrorMessage notebookError)
              Right patched -> do
                let destination = maybe notebookPath id outputPath
                writeResult <- try (TextIO.writeFile destination (renderNotebook patched))
                case (writeResult :: Either IOException ()) of
                  Left exception -> emitNotebookError "patch" "OutputError" (T.pack (show exception))
                  Right () -> emitJson (notebookPayload patched) *> pure 0

decodeNotebookPatches :: JsonValue -> Either Text [NotebookPatch]
decodeNotebookPatches (JsonObject specification) = case Map.lookup "operations" specification of
  Nothing -> Right []
  Just (JsonArray operations) -> traverse decodeNotebookPatch operations
  Just _ -> Left "patch specification operations must be an array"
decodeNotebookPatches _ = Left "a patch specification must be a JSON object"

decodeNotebookPatch :: JsonValue -> Either Text NotebookPatch
decodeNotebookPatch (JsonObject operation) = do
  operationName <- requiredString "op" operation
  case T.strip operationName of
    "append_cell" ->
      AppendCell
        <$> optionalPath "container_path" operation
        <*> patchCell (Just "Text") operation
    "insert_cell" ->
      InsertCell
        <$> optionalPath "container_path" operation
        <*> requiredInt "index" operation
        <*> patchCell (Just "Text") operation
    "replace_cell" ->
      ReplaceCell
        <$> requiredPath "path" operation
        <*> optionalStringField "style" operation
        <*> patchContent operation
    "delete_item" -> DeleteItem <$> requiredPath "path" operation
    "set_option" -> do
      name <- requiredString "name" operation
      valueSource <- requiredString "value_expr" operation
      value <- first parseErrorMessage (parseInputForm valueSource)
      pure (SetNotebookOption name value)
    unsupported -> Left ("unsupported patch operation: " <> unsupported)
decodeNotebookPatch _ = Left "patch operations must be JSON objects"

patchCell :: Maybe Text -> Map.Map Text JsonValue -> Either Text NotebookCell
patchCell defaultStyle operation =
  NotebookCell
    <$> patchContent operation
    <*> ((<|> defaultStyle) <$> optionalStringField "style" operation)
    <*> pure []

patchContent :: Map.Map Text JsonValue -> Either Text Expr
patchContent operation = do
  contentSource <- optionalStringField "content_expr" operation
  text <- optionalStringField "text" operation
  case contentSource of
    Just source -> first parseErrorMessage (parseInputForm source)
    Nothing -> Right (String (maybe "" id text))

requiredString :: Text -> Map.Map Text JsonValue -> Either Text Text
requiredString key values = case Map.lookup key values of
  Just (JsonString value) -> Right value
  Nothing -> Left ("missing patch field: " <> key)
  Just _ -> Left ("patch field must be a string: " <> key)

optionalStringField :: Text -> Map.Map Text JsonValue -> Either Text (Maybe Text)
optionalStringField key values = case Map.lookup key values of
  Nothing -> Right Nothing
  Just JsonNull -> Right Nothing
  Just (JsonString value) -> Right (Just value)
  Just _ -> Left ("patch field must be a string: " <> key)

requiredInt :: Text -> Map.Map Text JsonValue -> Either Text Int
requiredInt key values = case Map.lookup key values of
  Just (JsonNumber source) ->
    maybe (Left ("patch field must be an integer: " <> key)) Right (readMaybe (T.unpack source))
  Nothing -> Left ("missing patch field: " <> key)
  Just _ -> Left ("patch field must be an integer: " <> key)

optionalPath :: Text -> Map.Map Text JsonValue -> Either Text (Maybe [Int])
optionalPath key values = case Map.lookup key values of
  Nothing -> Right Nothing
  Just JsonNull -> Right Nothing
  Just value -> Just <$> pathValue key value

requiredPath :: Text -> Map.Map Text JsonValue -> Either Text [Int]
requiredPath key values = case Map.lookup key values of
  Nothing -> Left ("missing patch field: " <> key)
  Just value -> pathValue key value

pathValue :: Text -> JsonValue -> Either Text [Int]
pathValue key (JsonArray values) = traverse component values
 where
  component (JsonNumber source) =
    maybe (Left ("patch path must contain integers: " <> key)) Right (readMaybe (T.unpack source))
  component _ = Left ("patch path must contain integers: " <> key)
pathValue key _ = Left ("patch path must be an integer array: " <> key)

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

installationPayload :: WolframInstallation -> JsonValue
installationPayload installation =
  JsonObject
    ( Map.fromList
        [ ("available_installations", JsonArray (map installationSummaryPayload (installationAvailable installation)))
        , ("bundled_python_client", jsonMaybeString (installationBundledPythonClient installation))
        , ("default_index_path", JsonString (T.pack (installationDefaultIndexPath installation)))
        , ("docs_roots", JsonArray (map (JsonString . T.pack) (installationDocsRoots installation)))
        , ("frontend_executable", jsonMaybeString (installationFrontendExecutable installation))
        , ("install_dir", jsonMaybeString (installationInstallDir installation))
        , ("kernel_cli", jsonMaybeString (installationKernelCli installation))
        , ("kernel_executable", jsonMaybeString (installationKernelExecutable installation))
        , ("mathpass", jsonMaybeString (installationMathpass installation))
        , ("mathpass_candidates", JsonArray (map (JsonString . T.pack) (installationMathpassCandidates installation)))
        , ("product", JsonString (installationProduct installation))
        , ("product_family", JsonString (installationProductFamily installation))
        , ("selection_reason", maybe JsonNull JsonString (installationSelectionReason installation))
        , ("system_base", jsonMaybeString (installationSystemBase installation))
        , ("user_base", jsonMaybeString (installationUserBase installation))
        , ("version", maybe JsonNull JsonString (installationVersion installation))
        , ("wolframscript", jsonMaybeString (installationWolframscript installation))
        ]
    )

installationSummaryPayload :: InstallationSummary -> JsonValue
installationSummaryPayload summary =
  JsonObject
    ( Map.fromList
        [ ("install_dir", JsonString (T.pack (summaryInstallDir summary)))
        , ("kernel_cli", jsonMaybeString (summaryKernelCli summary))
        , ("product", JsonString (summaryProduct summary))
        , ("product_family", JsonString (summaryProductFamily summary))
        , ("version", maybe JsonNull JsonString (summaryVersion summary))
        , ("wolframscript", jsonMaybeString (summaryWolframscript summary))
        ]
    )

jsonMaybeString :: Maybe FilePath -> JsonValue
jsonMaybeString = maybe JsonNull (JsonString . T.pack)

kernelPayload :: KernelEvaluationResult -> JsonValue
kernelPayload result =
  JsonObject
    ( Map.fromList
        [ ("absolute_timing", jsonMaybeDouble (kernelAbsoluteTiming result))
        , ("cached_max_license_processes", JsonNull)
        , ("cleaned_tungsten_processes", JsonArray [])
        , ("command", JsonArray (map JsonString (kernelCommand result)))
        , ("elapsed_seconds", jsonDouble (kernelElapsedSeconds result))
        , ("evaluation_available", JsonBool (kernelEvaluationAvailable result))
        , ("exit_code", jsonInteger (fromIntegral (kernelExitCode result)))
        , ("failure_type", maybe JsonNull JsonString (kernelFailureType result))
        , ("json_path", jsonMaybeString (kernelJsonPath result))
        , ("launch_gate_wait_seconds", JsonNumber "0")
        , ("license_processes", jsonMaybeInt (kernelLicenseProcesses result))
        , ("license_wait_satisfied", JsonNull)
        , ("license_wait_seconds", JsonNumber "0")
        , ("mathpass", mathpassPayload (kernelMathpass result))
        , ("max_license_processes", jsonMaybeInt (kernelMaxLicenseProcesses result))
        , ("messages", JsonArray (map JsonString (kernelMessages result)))
        , ("messages_text", JsonArray (map JsonString (kernelMessagesText result)))
        , ("observed_wolfram_processes", JsonArray [])
        , ("output", JsonArray (map JsonString (kernelOutput result)))
        , ("result", maybe JsonNull JsonString (kernelResult result))
        , ("result_head", maybe JsonNull JsonString (kernelResultHead result))
        , ("stderr", JsonString (kernelStderr result))
        , ("stdout", JsonString (kernelStdout result))
        , ("success", maybe JsonNull JsonBool (kernelSuccess result))
        , ("timing", jsonMaybeDouble (kernelTiming result))
        , ("used_mathpass_workaround", JsonBool (kernelUsedMathpassWorkaround result))
        ]
    )

mathpassPayload :: MathpassInspection -> JsonValue
mathpassPayload inspection =
  JsonObject
    ( Map.fromList
        [ ("duplicate_entry_count", jsonInteger (fromIntegral (mathpassDuplicateEntryCount inspection)))
        , ("header_present", JsonBool (mathpassHeaderPresent inspection))
        , ("original_line_count", jsonInteger (fromIntegral (mathpassOriginalLineCount inspection)))
        , ("path", jsonMaybeString (mathpassPath inspection))
        , ("unique_entry_count", jsonInteger (fromIntegral (mathpassUniqueEntryCount inspection)))
        ]
    )

jsonMaybeInt :: Maybe Int -> JsonValue
jsonMaybeInt = maybe JsonNull (jsonInteger . fromIntegral)

jsonMaybeDouble :: Maybe Double -> JsonValue
jsonMaybeDouble = maybe JsonNull jsonDouble

jsonDouble :: Double -> JsonValue
jsonDouble = JsonNumber . T.pack . show

addEnvironmentProbe :: KernelEvaluationResult -> KernelEvaluationResult -> JsonValue -> JsonValue
addEnvironmentProbe evaluation frontEnd (JsonObject values) =
  JsonObject
    ( Map.insert
        "probe"
        ( JsonObject
            ( Map.fromList
                [ ("evaluation", kernelPayload evaluation)
                , ("front_end", kernelPayload frontEnd)
                ]
            )
        )
        values
    )
addEnvironmentProbe _ _ payload = payload

runFrontEndCommand :: FrontEndCommand -> IO Int
runFrontEndCommand command = do
  installation <- discoverInstallation
  (result, requireSuccess) <- case command of
    ProbeFrontEndCommand required -> (,required) <$> probeFrontEnd installation
    RunFrontEndCommand code wrap required -> (,required) <$> runFrontEnd installation code wrap
    OpenFrontEndNotebookCommand path required -> (,required) <$> openNotebook installation path
    OpenFrontEndDocumentationCommand identifier required ->
      (,required) <$> openDocumentation installation identifier
    ExecuteFrontEndTokenCommand token notebookPath required ->
      (,required) <$> executeFrontEndToken installation token notebookPath
  emitJson (kernelPayload result)
  pure (kernelCommandExit requireSuccess result)

kernelCommandExit :: Bool -> KernelEvaluationResult -> Int
kernelCommandExit requireSuccess result
  | requireSuccess && kernelSuccess result == Just False = 1
  | kernelEvaluationAvailable result = 0
  | otherwise = 2

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
    , "  tungsten-hs repl [--no-banner]"
    , "  tungsten-hs env show"
    , "  tungsten-hs kernel eval (--code TEXT | --file PATH) [--working-directory PATH] [--front-end] [--require-success]"
    , "  tungsten-hs frontend probe [--require-success]"
    , "  tungsten-hs frontend run --code TEXT [--no-wrap] [--require-success]"
    , "  tungsten-hs frontend open-notebook --file PATH [--require-success]"
    , "  tungsten-hs frontend open-doc IDENTIFIER [--require-success]"
    , "  tungsten-hs frontend token TOKEN [--file PATH] [--require-success]"
    , "  tungsten-hs expr parse (--code TEXT | --file PATH) [--form input|fullform]"
    , "  tungsten-hs expr evaluate (--code TEXT | --file PATH) [--form input|fullform]"
    , "  tungsten-hs notebook inspect --file PATH"
    , "  tungsten-hs notebook create --file PATH [--title TEXT] [--cell STYLE:TEXT ...]"
    , "  tungsten-hs notebook patch --file PATH --spec PATH [--out PATH]"
    , ""
    , "With no arguments, tungsten-hs serves the JSON-lines protocol for backward compatibility."
    ]
