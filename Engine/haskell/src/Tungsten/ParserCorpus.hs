{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic discovery and local parsing for Wolfram parser corpora.
module Tungsten.ParserCorpus
  ( CorpusFile (..)
  , ParserAttempt (..)
  , ParserCorpusResult (..)
  , ParserCorpusOptions (..)
  , ParserCorpusRun (..)
  , defaultCorpusExtensions
  , defaultParserCorpusOptions
  , discoverCorpusFiles
  , summarizeCorpusDiscovery
  , parseCorpusFile
  , localCorpusResults
  , parseFilesWithWolframKernel
  , decodeWolframBatchAttempts
  , compareParserCorpus
  , parserCorpusRunPayload
  , writeParserCorpusOutputs
  , classifyParserOutcome
  , corpusFilePayload
  , parserAttemptPayload
  , parserCorpusResultPayload
  ) where

import Control.Concurrent (forkIO, modifyMVar, newEmptyMVar, newMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Control.Monad (forM, replicateM, replicateM_)
import qualified Data.ByteString as BS
import Data.Bits (xor)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TextIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , createDirectoryIfMissing
  , getFileSize
  , listDirectory
  , makeAbsolute
  )
import System.FilePath
  ( (</>)
  , makeRelative
  , takeExtension
  )
import Text.Read (readMaybe)
import Tungsten.Expression (Expr, arguments, fullForm)
import Tungsten.Discovery (WolframInstallation)
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.Notebook
import Tungsten.Parser
import qualified Tungsten.TextualForms as TextualForms
import Tungsten.WolframString (parseWolframStringLiteral, wlString)

data CorpusFile = CorpusFile
  { corpusFilePath :: !FilePath
  , corpusFileRelativePath :: !Text
  , corpusFileExtension :: !Text
  , corpusFileKind :: !Text
  , corpusFileSource :: !Text
  , corpusFileSizeBytes :: !Integer
  }
  deriving (Eq, Show)

data ParserAttempt = ParserAttempt
  { parserAttemptParser :: !Text
  , parserAttemptStatus :: !Text
  , parserAttemptElapsedMilliseconds :: !(Maybe Double)
  , parserAttemptErrorType :: !(Maybe Text)
  , parserAttemptError :: !(Maybe Text)
  , parserAttemptSummary :: !(Map.Map Text JsonValue)
  }
  deriving (Eq, Show)

data ParserCorpusResult = ParserCorpusResult
  { parserCorpusFile :: !CorpusFile
  , parserCorpusTungsten :: !ParserAttempt
  , parserCorpusWolfram :: !ParserAttempt
  , parserCorpusOutcome :: !Text
  }
  deriving (Eq, Show)

data ParserCorpusOptions = ParserCorpusOptions
  { parserCorpusRoot :: !FilePath
  , parserCorpusOutputDirectory :: !(Maybe FilePath)
  , parserCorpusExtensions :: ![Text]
  , parserCorpusIncludeGlobs :: ![Text]
  , parserCorpusExcludeGlobs :: ![Text]
  , parserCorpusMaximumFiles :: !(Maybe Int)
  , parserCorpusMaximumBytes :: !(Maybe Integer)
  , parserCorpusSourceForm :: !Text
  , parserCorpusCompareWolfram :: !Bool
  , parserCorpusKernelBatchSize :: !Int
  , parserCorpusTungstenWorkers :: !Int
  , parserCorpusPreviewCharacters :: !Int
  , parserCorpusShuffle :: !Bool
  , parserCorpusSeed :: !Int
  , parserCorpusWriteOutputs :: !Bool
  }
  deriving (Eq, Show)

data ParserCorpusRun = ParserCorpusRun
  { parserCorpusRunSummary :: !JsonValue
  , parserCorpusRunResults :: ![ParserCorpusResult]
  , parserCorpusRunOutputFiles :: !(Map.Map Text FilePath)
  }
  deriving (Eq, Show)

defaultCorpusExtensions :: [Text]
defaultCorpusExtensions = [".wl", ".m", ".wls", ".mt", ".wlt", ".nb", ".nbp"]

defaultParserCorpusOptions :: FilePath -> ParserCorpusOptions
defaultParserCorpusOptions root =
  ParserCorpusOptions
    { parserCorpusRoot = root
    , parserCorpusOutputDirectory = Nothing
    , parserCorpusExtensions = []
    , parserCorpusIncludeGlobs = []
    , parserCorpusExcludeGlobs = []
    , parserCorpusMaximumFiles = Nothing
    , parserCorpusMaximumBytes = Just (2 * 1024 * 1024)
    , parserCorpusSourceForm = "input"
    , parserCorpusCompareWolfram = True
    , parserCorpusKernelBatchSize = 100
    , parserCorpusTungstenWorkers = 1
    , parserCorpusPreviewCharacters = 2000
    , parserCorpusShuffle = False
    , parserCorpusSeed = 0
    , parserCorpusWriteOutputs = True
    }

discoverCorpusFiles
  :: FilePath
  -> [Text]
  -> [Text]
  -> [Text]
  -> Maybe Int
  -> Bool
  -> Int
  -> IO (Either Text [CorpusFile])
discoverCorpusFiles requestedRoot requestedExtensions includeGlobs excludeGlobs maxFiles shuffle seed = do
  isDirectory <- doesDirectoryExist requestedRoot
  isFile <- doesFileExist requestedRoot
  if not isDirectory
    then pure . Left $
      if isFile
        then "Parser corpus root is not a directory: " <> T.pack requestedRoot
        else "Parser corpus root does not exist: " <> T.pack requestedRoot
    else do
      root <- makeAbsolute requestedRoot
      paths <- walkFiles root
      records <- fmap concat . forM paths $ \path -> do
        let extension = T.toLower (T.pack (takeExtension path))
            relative = normalizeRelativePath (makeRelative root path)
        if not (Set.member extension normalizedExtensions)
          || (not (null normalizedIncludes) && not (matchesAny relative normalizedIncludes))
          || matchesAny relative normalizedExcludes
          then pure []
          else do
            sizeResult <- try (getFileSize path)
            pure $ case (sizeResult :: Either IOException Integer) of
              Left _ -> []
              Right sizeBytes ->
                [ CorpusFile
                    { corpusFilePath = path
                    , corpusFileRelativePath = relative
                    , corpusFileExtension = extension
                    , corpusFileKind = if Set.member extension notebookExtensions then "notebook" else "source"
                    , corpusFileSource = sourceFromRelativePath relative
                    , corpusFileSizeBytes = sizeBytes
                    }
                ]
      let ordered = sortOn (T.toCaseFold . corpusFileRelativePath) records
          shuffled = if shuffle then deterministicShuffle seed ordered else ordered
          limited = maybe shuffled (\count -> take (max 0 count) shuffled) maxFiles
      pure (Right limited)
 where
  normalizedExtensions =
    Set.fromList (normalizeExtensions (if null requestedExtensions then defaultCorpusExtensions else requestedExtensions))
  normalizedIncludes = map normalizeGlob (filter (not . T.null . T.strip) includeGlobs)
  normalizedExcludes = map normalizeGlob (filter (not . T.null . T.strip) excludeGlobs)
  notebookExtensions = Set.fromList [".nb", ".nbp"]

summarizeCorpusDiscovery :: FilePath -> [CorpusFile] -> IO JsonValue
summarizeCorpusDiscovery root files = do
  absoluteRoot <- makeAbsolute root
  pure
    ( JsonObject
        ( Map.fromList
            [ ("by_extension", counterPayload corpusFileExtension files)
            , ("by_kind", counterPayload corpusFileKind files)
            , ("by_source", counterPayload corpusFileSource files)
            , ("corpus_root", JsonString (T.pack absoluteRoot))
            , ("file_count", jsonInteger (fromIntegral (length files)))
            , ("total_bytes", jsonInteger (sum (map corpusFileSizeBytes files)))
            ]
        )
    )

parseCorpusFile :: CorpusFile -> Text -> Maybe Integer -> Int -> IO ParserAttempt
parseCorpusFile file sourceForm maxBytes previewCharacters
  | Just limit <- maxBytes, corpusFileSizeBytes file > limit =
      pure
        ( skippedAttempt
            "tungsten"
            "FileTooLarge"
            ( "File is "
                <> T.pack (show (corpusFileSizeBytes file))
                <> " bytes; max_bytes is "
                <> T.pack (show limit)
                <> "."
            )
        )
  | otherwise = do
      started <- getCurrentTime
      sourceResult <- try (BS.readFile (corpusFilePath file))
      finishedRead <- getCurrentTime
      case (sourceResult :: Either IOException BS.ByteString) of
        Left exception ->
          pure
            ( failureAttempt
                (elapsedMilliseconds started finishedRead)
                "IOException"
                (truncateText previewCharacters (T.pack (show exception)))
            )
        Right bytes -> do
          let source = TE.decodeUtf8With TEE.lenientDecode bytes
              parsed =
                if corpusFileKind file == "notebook"
                  then either (Left . notebookErrorMessage) (Right . notebookSummary) (parseNotebook source)
                  else expressionSummary sourceForm previewCharacters <$> parseExpression sourceForm source
          finished <- getCurrentTime
          pure $ case parsed of
            Left message ->
              failureAttempt
                (elapsedMilliseconds started finished)
                "ParseError"
                (truncateText previewCharacters message)
            Right summary ->
              ParserAttempt
                { parserAttemptParser = "tungsten"
                , parserAttemptStatus = "success"
                , parserAttemptElapsedMilliseconds = Just (elapsedMilliseconds started finished)
                , parserAttemptErrorType = Nothing
                , parserAttemptError = Nothing
                , parserAttemptSummary = summary
                }

localCorpusResults
  :: [CorpusFile]
  -> Text
  -> Maybe Integer
  -> Int
  -> IO [ParserCorpusResult]
localCorpusResults files sourceForm maxBytes previewCharacters =
  forM files $ \file -> do
    tungsten <- parseCorpusFile file sourceForm maxBytes previewCharacters
    let wolfram =
          skippedAttempt
            "wolfram"
            "WolframComparisonDisabled"
            "Wolfram kernel comparison was disabled for this run."
    pure
      ParserCorpusResult
        { parserCorpusFile = file
        , parserCorpusTungsten = tungsten
        , parserCorpusWolfram = wolfram
        , parserCorpusOutcome = classifyParserOutcome tungsten wolfram
        }

parseFilesWithWolframKernel
  :: WolframInstallation
  -> [CorpusFile]
  -> Int
  -> IO (Map.Map Text ParserAttempt)
parseFilesWithWolframKernel _ [] _ = pure Map.empty
parseFilesWithWolframKernel installation files previewCharacters = do
  evaluation <- evaluateKernelText installation (wolframBatchScript files previewCharacters) Nothing False
  if not (kernelEvaluationAvailable evaluation)
    then pure (attemptsForAll (kernelUnavailableAttempt evaluation))
    else case kernelResult evaluation of
      Nothing ->
        pure
          ( attemptsForAll
              (wolframFailure Nothing "MissingKernelResult" "Wolfram kernel evaluation completed without a result string.")
          )
      Just rawResult -> case decodeWolframBatchAttempts files previewCharacters rawResult of
        Left message ->
          pure
            ( attemptsForAll
                ( wolframFailure
                    Nothing
                    "InvalidKernelPayload"
                    (truncateText previewCharacters ("Could not decode Wolfram parser batch payload: " <> message))
                )
            )
        Right attempts -> pure attempts
 where
  attemptsForAll attempt = Map.fromList [(corpusFileRelativePath file, attempt) | file <- files]
  kernelUnavailableAttempt evaluation =
    skippedAttempt
      "wolfram"
      (maybe "KernelUnavailable" id (kernelFailureType evaluation))
      (if T.null (kernelStderr evaluation)
        then "Wolfram kernel did not produce a structured result."
        else kernelStderr evaluation)

decodeWolframBatchAttempts
  :: [CorpusFile]
  -> Int
  -> Text
  -> Either Text (Map.Map Text ParserAttempt)
decodeWolframBatchAttempts files previewCharacters rawResult = do
  payloads <- decodeKernelBatch rawResult
  pure (foldl addMissing (foldl decodeItem Map.empty payloads) files)
 where
  pathMap =
    Map.fromList
      [ (normalizeRelativePath (corpusFilePath file), file)
      | file <- files
      ]
  decodeItem attempts (JsonObject item) = case (Map.lookup "path" item, Map.lookup "attempt" item) of
    (Just (JsonString path), Just attemptPayload) -> case Map.lookup path pathMap of
      Nothing -> attempts
      Just file -> case attemptFromWolframPayload previewCharacters attemptPayload of
        Left _ -> attempts
        Right attempt -> Map.insert (corpusFileRelativePath file) attempt attempts
    _ -> attempts
  decodeItem attempts _ = attempts
  addMissing attempts file =
    Map.insertWith
      (\_ existing -> existing)
      (corpusFileRelativePath file)
      ( wolframFailure
          Nothing
          "MissingFileResult"
          "Wolfram parser batch did not include this file in its JSON payload."
      )
      attempts

compareParserCorpus
  :: WolframInstallation
  -> ParserCorpusOptions
  -> IO (Either Text ParserCorpusRun)
compareParserCorpus installation requestedOptions = do
  absoluteRoot <- makeAbsolute (parserCorpusRoot requestedOptions)
  compareParserCorpusResolved
    installation
    requestedOptions {parserCorpusRoot = absoluteRoot}

compareParserCorpusResolved
  :: WolframInstallation
  -> ParserCorpusOptions
  -> IO (Either Text ParserCorpusRun)
compareParserCorpusResolved installation options = do
  totalStarted <- getCurrentTime
  discoveryStarted <- getCurrentTime
  discovery <-
    discoverCorpusFiles
      (parserCorpusRoot options)
      (parserCorpusExtensions options)
      (parserCorpusIncludeGlobs options)
      (parserCorpusExcludeGlobs options)
      (parserCorpusMaximumFiles options)
      (parserCorpusShuffle options)
      (parserCorpusSeed options)
  discoveryFinished <- getCurrentTime
  case discovery of
    Left message -> pure (Left message)
    Right files -> do
      tungstenStarted <- getCurrentTime
      tungstenAttempts <-
        parseFilesLocally
          (parserCorpusTungstenWorkers options)
          files
          (parserCorpusSourceForm options)
          (parserCorpusMaximumBytes options)
          (parserCorpusPreviewCharacters options)
      tungstenFinished <- getCurrentTime
      wolframStarted <- getCurrentTime
      wolframAttempts <- if parserCorpusCompareWolfram options
        then parseEligibleBatches files
        else pure Map.empty
      wolframFinished <- getCurrentTime
      let tungstenMap = Map.fromList tungstenAttempts
          results = map (resultFor tungstenMap wolframAttempts) files
          wallTimings =
            Map.fromList
              [ ("discovery_elapsed_ms", elapsedMilliseconds discoveryStarted discoveryFinished)
              , ("tungsten_wall_elapsed_ms", elapsedMilliseconds tungstenStarted tungstenFinished)
              , ("wolfram_wall_elapsed_ms", elapsedMilliseconds wolframStarted wolframFinished)
              ]
      generated <- getCurrentTime
      let summaryWithoutOutputs = buildRunSummary generated options files results wallTimings
      outputStarted <- getCurrentTime
      outputFiles <- if parserCorpusWriteOutputs options
        then do
          let outputDirectory = maybe (parserCorpusRoot options </> "validation") id (parserCorpusOutputDirectory options)
          writeParserCorpusOutputs outputDirectory summaryWithoutOutputs results
        else pure Map.empty
      outputFinished <- getCurrentTime
      totalFinished <- getCurrentTime
      let finalTimings =
            Map.insert "output_write_elapsed_ms" (elapsedMilliseconds outputStarted outputFinished)
              (Map.insert "total_elapsed_ms" (elapsedMilliseconds totalStarted totalFinished) wallTimings)
          finalSummary =
            addSummaryOutputFiles outputFiles
              (buildRunSummary generated options files results finalTimings)
      if Map.null outputFiles
        then pure ()
        else rewriteSummaryAndReport outputFiles finalSummary results
      pure
        ( Right
            ParserCorpusRun
              { parserCorpusRunSummary = finalSummary
              , parserCorpusRunResults = results
              , parserCorpusRunOutputFiles = outputFiles
              }
        )
 where
  eligible file = maybe True (corpusFileSizeBytes file <=) (parserCorpusMaximumBytes options)
  parseEligibleBatches files =
    fmap Map.unions
      ( traverse
          (\batch -> parseFilesWithWolframKernel installation batch (parserCorpusPreviewCharacters options))
          (chunksOf (max 1 (parserCorpusKernelBatchSize options)) (filter eligible files))
      )
  resultFor tungstenAttempts wolframAttempts file =
    let tungsten = Map.findWithDefault missingTungsten (corpusFileRelativePath file) tungstenAttempts
        wolfram = Map.findWithDefault (defaultWolfram file) (corpusFileRelativePath file) wolframAttempts
     in ParserCorpusResult file tungsten wolfram (classifyParserOutcome tungsten wolfram)
  missingTungsten = parserFailure "tungsten" Nothing "MissingTungstenResult" "Local parser did not produce a result."
  defaultWolfram file
    | parserCorpusCompareWolfram options =
        skippedAttempt
          "wolfram"
          "FileTooLarge"
          ( "File is "
              <> T.pack (show (corpusFileSizeBytes file))
              <> " bytes; max_bytes is "
              <> maybe "None" (T.pack . show) (parserCorpusMaximumBytes options)
              <> "."
          )
    | otherwise =
        skippedAttempt
          "wolfram"
          "WolframComparisonDisabled"
          "Wolfram kernel comparison was disabled for this run."

parseFilesLocally
  :: Int
  -> [CorpusFile]
  -> Text
  -> Maybe Integer
  -> Int
  -> IO [(Text, ParserAttempt)]
parseFilesLocally requestedWorkers files sourceForm maxBytes previewCharacters
  | workers <= 1 || length files <= 1 = traverse parseOne files
  | otherwise = do
      resultVariables <- replicateM (length files) newEmptyMVar
      jobs <- newMVar (zip files resultVariables)
      replicateM_ workers (forkIO (worker jobs))
      traverse takeMVar resultVariables
 where
  workers = max 1 requestedWorkers
  parseOne file = do
    attempt <- parseCorpusFile file sourceForm maxBytes previewCharacters
    pure (corpusFileRelativePath file, attempt)
  worker jobs = do
    next <- modifyMVar jobs $ \case
      [] -> pure ([], Nothing)
      job : remaining -> pure (remaining, Just job)
    case next of
      Nothing -> pure ()
      Just (file, resultVariable) -> parseOne file >>= putMVar resultVariable >> worker jobs

parserCorpusRunPayload :: Bool -> ParserCorpusRun -> JsonValue
parserCorpusRunPayload includeResults run =
  JsonObject
    ( Map.fromList
        ( [ ("output_files", outputFilesPayload (parserCorpusRunOutputFiles run))
          , ("summary", parserCorpusRunSummary run)
          ]
            <> if includeResults
              then [("results", JsonArray (map parserCorpusResultPayload (parserCorpusRunResults run)))]
              else []
        )
    )

writeParserCorpusOutputs
  :: FilePath
  -> JsonValue
  -> [ParserCorpusResult]
  -> IO (Map.Map Text FilePath)
writeParserCorpusOutputs outputDirectory summary results = do
  createDirectoryIfMissing True outputDirectory
  let summaryPath = outputDirectory </> "parser-corpus-summary.json"
      resultsPath = outputDirectory </> "parser-corpus-results.jsonl"
      reportPath = outputDirectory </> "parser-corpus-report.md"
  TextIO.writeFile summaryPath (encodeJson summary <> "\n")
  TextIO.writeFile resultsPath (T.unlines (map (encodeJson . parserCorpusResultPayload) results))
  TextIO.writeFile reportPath (renderMarkdownReport summary results)
  pure
    ( Map.fromList
        [ ("report", reportPath)
        , ("results_jsonl", resultsPath)
        , ("summary", summaryPath)
        ]
    )

wolframBatchScript :: [CorpusFile] -> Int -> Text
wolframBatchScript files previewCharacters =
  T.unlines
    [ "tungstenParserCorpusFiles = ImportString[" <> wlString pathsJson <> ", \"RawJSON\"];"
    , "tungstenParserCorpusPreviewChars = " <> T.pack (show previewCharacters) <> ";"
    , "ClearAll[tungstenParserCorpusShortString, tungstenParserCorpusParseOne];"
    , "tungstenParserCorpusShortString[text_] := If[StringQ[text] && StringLength[text] > tungstenParserCorpusPreviewChars, StringTake[text, tungstenParserCorpusPreviewChars] <> \"...\", text];"
    , "tungstenParserCorpusParseOne[path_String] := Module[{started, text, held, normalized, rendered, fullRendered},"
    , "  started = AbsoluteTime[];"
    , "  text = Quiet @ Check[Import[path, \"Text\", CharacterEncoding -> \"UTF-8\"], $Failed];"
    , "  If[text === $Failed, Return @ <|\"parser\" -> \"wolfram\", \"status\" -> \"failure\", \"elapsed_ms\" -> N[1000 * (AbsoluteTime[] - started)], \"error_type\" -> \"ImportFailure\", \"error\" -> \"Import[path, Text] returned $Failed.\"|>];"
    , "  held = Quiet @ Check[ToExpression[text, InputForm, HoldComplete], $Failed];"
    , "  If[held === $Failed, Return @ <|\"parser\" -> \"wolfram\", \"status\" -> \"failure\", \"elapsed_ms\" -> N[1000 * (AbsoluteTime[] - started)], \"error_type\" -> \"ParseFailure\", \"error\" -> \"ToExpression[text, InputForm, HoldComplete] returned $Failed.\"|>];"
    , "  normalized = Replace[held, HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]];"
    , "  rendered = Quiet @ Check[ToString[normalized, InputForm, PageWidth -> Infinity], \"$Failed\"];"
    , "  fullRendered = Quiet @ Check[ToString[FullForm[normalized], OutputForm, PageWidth -> Infinity], \"$Failed\"];"
    , "  <|\"parser\" -> \"wolfram\", \"status\" -> \"success\", \"elapsed_ms\" -> N[1000 * (AbsoluteTime[] - started)], \"summary\" -> <|"
    , "    \"held_head\" -> Quiet @ Check[ToString[Head[normalized], InputForm], \"$Failed\"],"
    , "    \"leaf_count\" -> Quiet @ Check[LeafCount[normalized], Null],"
    , "    \"byte_count\" -> Quiet @ Check[ByteCount[normalized], Null],"
    , "    \"input_form_preview\" -> tungstenParserCorpusShortString[rendered],"
    , "    \"full_form_preview\" -> tungstenParserCorpusShortString[fullRendered]|>|>"
    , "];"
    , "ExportString[Map[<|\"path\" -> #, \"attempt\" -> tungstenParserCorpusParseOne[#]|> &, tungstenParserCorpusFiles], \"RawJSON\"]"
    ]
 where
  pathsJson =
    encodeJson
      ( JsonArray
          [ JsonString (normalizeRelativePath (corpusFilePath file))
          | file <- files
          ]
      )

decodeKernelBatch :: Text -> Either Text [JsonValue]
decodeKernelBatch rawResult = do
  let stripped = T.strip rawResult
      decoded
        | T.length stripped >= 2 && T.head stripped == '"' && T.last stripped == '"' =
            parseWolframStringLiteral stripped
        | otherwise = stripped
  payload <- case parseJson decoded of
    Left jsonError -> Left (jsonErrorMessage jsonError)
    Right value -> Right value
  case payload of
    JsonArray values -> Right values
    _ -> Left "Wolfram parser batch payload was not a JSON array."

attemptFromWolframPayload :: Int -> JsonValue -> Either Text ParserAttempt
attemptFromWolframPayload previewCharacters (JsonObject payload) = do
  status <- optionalStringValue "status" payload "failure"
  let elapsed = Map.lookup "elapsed_ms" payload >>= optionalJsonDouble
      errorType = Map.lookup "error_type" payload >>= optionalJsonString
      errorMessage =
        fmap (truncateText previewCharacters) (Map.lookup "error" payload >>= optionalJsonString)
      summary = case Map.lookup "summary" payload of
        Just (JsonObject values) -> values
        _ -> Map.empty
  pure
    ParserAttempt
      { parserAttemptParser = "wolfram"
      , parserAttemptStatus = status
      , parserAttemptElapsedMilliseconds = elapsed
      , parserAttemptErrorType = errorType
      , parserAttemptError = errorMessage
      , parserAttemptSummary = summary
      }
attemptFromWolframPayload _ _ = Left "Wolfram parser attempt was not a JSON object."

buildRunSummary
  :: UTCTime
  -> ParserCorpusOptions
  -> [CorpusFile]
  -> [ParserCorpusResult]
  -> Map.Map Text Double
  -> JsonValue
buildRunSummary generated options files results wallTimings =
  JsonObject
    ( Map.fromList
        [ ("by_extension", counterPayload corpusFileExtension files)
        , ("by_kind", counterPayload corpusFileKind files)
        , ("by_source", counterPayload corpusFileSource files)
        , ("corpus_root", JsonString (T.pack absoluteRoot))
        , ("file_count", jsonInteger (fromIntegral (length files)))
        , ("generated_utc", JsonString generatedUtc)
        , ("options", parserCorpusOptionsPayload options)
        , ("outcomes", counterPayload parserCorpusOutcome results)
        , ("timings", timingsPayload wallTimings results)
        , ("total_bytes", jsonInteger (sum (map corpusFileSizeBytes files)))
        , ("tungsten_failure_types", failureTypesPayload parserCorpusTungsten results)
        , ("tungsten_statuses", counterPayload (parserAttemptStatus . parserCorpusTungsten) results)
        , ("wolfram_failure_types", failureTypesPayload parserCorpusWolfram results)
        , ("wolfram_statuses", counterPayload (parserAttemptStatus . parserCorpusWolfram) results)
        ]
    )
 where
  absoluteRoot = parserCorpusRoot options
  generatedUtc = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" generated)

parserCorpusOptionsPayload :: ParserCorpusOptions -> JsonValue
parserCorpusOptionsPayload options =
  JsonObject
    ( Map.fromList
        [ ("compare_wolfram", JsonBool (parserCorpusCompareWolfram options))
        , ("exclude_globs", textArray (parserCorpusExcludeGlobs options))
        , ("extensions", textArray normalizedExtensions)
        , ("include_globs", textArray (parserCorpusIncludeGlobs options))
        , ("kernel_batch_size", jsonInteger (fromIntegral (parserCorpusKernelBatchSize options)))
        , ("max_bytes", maybe JsonNull jsonInteger (parserCorpusMaximumBytes options))
        , ("max_files", maybe JsonNull (jsonInteger . fromIntegral) (parserCorpusMaximumFiles options))
        , ("preview_chars", jsonInteger (fromIntegral (parserCorpusPreviewCharacters options)))
        , ("seed", jsonInteger (fromIntegral (parserCorpusSeed options)))
        , ("shuffle", JsonBool (parserCorpusShuffle options))
        , ("source_form", JsonString (parserCorpusSourceForm options))
        , ("tungsten_workers", jsonInteger (fromIntegral (parserCorpusTungstenWorkers options)))
        ]
    )
 where
  normalizedExtensions =
    normalizeExtensions
      (if null (parserCorpusExtensions options) then defaultCorpusExtensions else parserCorpusExtensions options)
  textArray = JsonArray . map JsonString

timingsPayload :: Map.Map Text Double -> [ParserCorpusResult] -> JsonValue
timingsPayload wallTimings results =
  JsonObject
    ( Map.map jsonDouble
        ( Map.insert "tungsten_attempt_elapsed_ms" tungstenAttempts
            ( Map.insert "wolfram_attempt_elapsed_ms" wolframAttempts
                ( Map.insert "tungsten_files_per_second_wall" tungstenRate
                    (Map.insert "wolfram_files_per_second_wall" wolframRate wallTimings)
                )
            )
        )
    )
 where
  tungstenAttempts = sumAttemptMilliseconds parserCorpusTungsten results
  wolframAttempts = sumAttemptMilliseconds parserCorpusWolfram results
  tungstenRate = rate (length results) (Map.lookup "tungsten_wall_elapsed_ms" wallTimings)
  wolframCount = length (filter ((/= "skipped") . parserAttemptStatus . parserCorpusWolfram) results)
  wolframRate = rate wolframCount (Map.lookup "wolfram_wall_elapsed_ms" wallTimings)

sumAttemptMilliseconds :: (value -> ParserAttempt) -> [value] -> Double
sumAttemptMilliseconds projection =
  sum . map (maybe 0 id . parserAttemptElapsedMilliseconds . projection)

rate :: Int -> Maybe Double -> Double
rate _ Nothing = 0
rate _ (Just elapsed) | elapsed <= 0 = 0
rate count (Just elapsed) = fromIntegral count / (elapsed / 1000)

failureTypesPayload :: (value -> ParserAttempt) -> [value] -> JsonValue
failureTypesPayload projection values =
  counterPayload failureType (filter ((== "failure") . parserAttemptStatus . projection) values)
 where
  failureType = maybe "Unknown" id . parserAttemptErrorType . projection

addSummaryOutputFiles :: Map.Map Text FilePath -> JsonValue -> JsonValue
addSummaryOutputFiles outputFiles (JsonObject summary)
  | Map.null outputFiles = JsonObject summary
  | otherwise = JsonObject (Map.insert "output_files" (outputFilesPayload outputFiles) summary)
addSummaryOutputFiles _ summary = summary

outputFilesPayload :: Map.Map Text FilePath -> JsonValue
outputFilesPayload = JsonObject . Map.map (JsonString . T.pack)

rewriteSummaryAndReport
  :: Map.Map Text FilePath
  -> JsonValue
  -> [ParserCorpusResult]
  -> IO ()
rewriteSummaryAndReport outputFiles summary results = do
  case Map.lookup "summary" outputFiles of
    Nothing -> pure ()
    Just path -> TextIO.writeFile path (encodeJson summary <> "\n")
  case Map.lookup "report" outputFiles of
    Nothing -> pure ()
    Just path -> TextIO.writeFile path (renderMarkdownReport summary results)

renderMarkdownReport :: JsonValue -> [ParserCorpusResult] -> Text
renderMarkdownReport summary results =
  T.unlines
    ( [ "# Tungsten Parser Corpus Comparison"
      , ""
      , "- Generated UTC: `" <> fieldText "generated_utc" <> "`"
      , "- Corpus root: `" <> fieldText "corpus_root" <> "`"
      , "- Files considered: `" <> fieldRendered "file_count" <> "`"
      , "- Total bytes considered: `" <> fieldRendered "total_bytes" <> "`"
      , ""
      , "## Outcomes"
      , ""
      ]
        <> objectBullets "outcomes" "- None"
        <> ["", "## Tungsten Failure Types", ""]
        <> objectBullets "tungsten_failure_types" "- None"
        <> ["", "## First Wolfram-Accepted Tungsten Gaps", ""]
        <> resultBullets "tungsten_gap" parserCorpusTungsten
        <> ["", "## First Tungsten-Accepted Wolfram Rejections", ""]
        <> resultBullets "tungsten_only_success" parserCorpusWolfram
    )
 where
  summaryMap = case summary of
    JsonObject values -> values
    _ -> Map.empty
  field key = Map.lookup key summaryMap
  fieldText key = case field key of
    Just (JsonString value) -> value
    _ -> "None"
  fieldRendered key = maybe "None" encodeJson (field key)
  objectBullets key fallback = case field key of
    Just (JsonObject values) | not (Map.null values) ->
      ["- `" <> name <> "`: `" <> encodeJson value <> "`" | (name, value) <- Map.toAscList values]
    _ -> [fallback]
  resultBullets outcome projection = case take 50 (filter ((== outcome) . parserCorpusOutcome) results) of
    [] -> ["- None in this run."]
    selected -> map (resultBullet projection) selected
  resultBullet projection result =
    let file = parserCorpusFile result
        attempt = projection result
        reason = maybe (parserAttemptStatus attempt) id (parserAttemptErrorType attempt)
     in "- `" <> corpusFileRelativePath file <> "` ("
          <> corpusFileExtension file <> ", " <> T.pack (show (corpusFileSizeBytes file))
          <> " bytes): " <> reason

optionalStringValue :: Text -> Map.Map Text JsonValue -> Text -> Either Text Text
optionalStringValue key payload fallback = case Map.lookup key payload of
  Nothing -> Right fallback
  Just (JsonString value) -> Right value
  Just _ -> Left (key <> " must be a string")

optionalJsonString :: JsonValue -> Maybe Text
optionalJsonString (JsonString value) = Just value
optionalJsonString _ = Nothing

optionalJsonDouble :: JsonValue -> Maybe Double
optionalJsonDouble (JsonNumber value) = readMaybe (T.unpack value)
optionalJsonDouble _ = Nothing

parserFailure :: Text -> Maybe Double -> Text -> Text -> ParserAttempt
parserFailure parserName elapsed errorType message =
  ParserAttempt
    { parserAttemptParser = parserName
    , parserAttemptStatus = "failure"
    , parserAttemptElapsedMilliseconds = elapsed
    , parserAttemptErrorType = Just errorType
    , parserAttemptError = Just message
    , parserAttemptSummary = Map.empty
    }

wolframFailure :: Maybe Double -> Text -> Text -> ParserAttempt
wolframFailure = parserFailure "wolfram"

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf count values =
  let (prefix, suffix) = splitAt (max 1 count) values
   in prefix : chunksOf count suffix

classifyParserOutcome :: ParserAttempt -> ParserAttempt -> Text
classifyParserOutcome tungsten wolfram
  | parserAttemptStatus tungsten == "skipped" || parserAttemptStatus wolfram == "skipped" = "skipped"
  | statuses == ("success", "success") = "both_success"
  | statuses == ("failure", "success") = "tungsten_gap"
  | statuses == ("success", "failure") = "tungsten_only_success"
  | statuses == ("failure", "failure") = "both_fail"
  | otherwise = fst statuses <> "_vs_" <> snd statuses
 where
  statuses = (parserAttemptStatus tungsten, parserAttemptStatus wolfram)

corpusFilePayload :: CorpusFile -> JsonValue
corpusFilePayload file =
  JsonObject
    ( Map.fromList
        [ ("extension", JsonString (corpusFileExtension file))
        , ("kind", JsonString (corpusFileKind file))
        , ("path", JsonString (T.pack (corpusFilePath file)))
        , ("relative_path", JsonString (corpusFileRelativePath file))
        , ("size_bytes", jsonInteger (corpusFileSizeBytes file))
        , ("source", JsonString (corpusFileSource file))
        ]
    )

parserAttemptPayload :: ParserAttempt -> JsonValue
parserAttemptPayload attempt =
  JsonObject
    ( Map.fromList
        ( [ ("parser", JsonString (parserAttemptParser attempt))
          , ("status", JsonString (parserAttemptStatus attempt))
          , ("summary", JsonObject (parserAttemptSummary attempt))
          ]
            <> maybe [] (pure . ("elapsed_ms",) . jsonDouble) (parserAttemptElapsedMilliseconds attempt)
            <> maybe [] (pure . ("error_type",) . JsonString) (parserAttemptErrorType attempt)
            <> maybe [] (pure . ("error",) . JsonString) (parserAttemptError attempt)
        )
    )

parserCorpusResultPayload :: ParserCorpusResult -> JsonValue
parserCorpusResultPayload result =
  JsonObject
    ( Map.fromList
        [ ("file", corpusFilePayload (parserCorpusFile result))
        , ("outcome", JsonString (parserCorpusOutcome result))
        , ("tungsten", parserAttemptPayload (parserCorpusTungsten result))
        , ("wolfram", parserAttemptPayload (parserCorpusWolfram result))
        ]
    )

parseExpression :: Text -> Text -> Either Text Expr
parseExpression sourceForm source = case T.toLower (T.strip sourceForm) of
  "input" -> mapParseError (parseInputForm source)
  "inputform" -> mapParseError (parseInputForm source)
  "full" -> mapParseError (parseFullForm source)
  "fullform" -> mapParseError (parseFullForm source)
  "standard" -> TextualForms.parseStandardFormSource source
  "standardform" -> TextualForms.parseStandardFormSource source
  other -> Left ("unsupported parser corpus source form: " <> other)
 where
  mapParseError = either (Left . parseErrorMessage) Right

expressionSummary :: Text -> Int -> Expr -> Map.Map Text JsonValue
expressionSummary sourceForm previewCharacters expression =
  Map.fromList
    [ ("depth", jsonInteger (fromIntegral (expressionDepth expression)))
    , ("form", JsonString sourceForm)
    , ("full_form_preview", JsonString (truncateText previewCharacters (fullForm expression)))
    , ("input_form_preview", JsonString (truncateText previewCharacters (fullForm expression)))
    , ("length", jsonInteger (fromIntegral (length (arguments expression))))
    ]

notebookSummary :: NotebookDocument -> Map.Map Text JsonValue
notebookSummary document =
  Map.fromList
    [ ("cell_count", jsonInteger (fromIntegral (cellCount document)))
    , ("group_count", jsonInteger (fromIntegral (groupCount document)))
    , ("title", maybe JsonNull JsonString (notebookTitle document))
    ]

expressionDepth :: Expr -> Int
expressionDepth expression = case arguments expression of
  [] -> 1
  values -> 1 + maximum (map expressionDepth values)

failureAttempt :: Double -> Text -> Text -> ParserAttempt
failureAttempt elapsed errorType message =
  ParserAttempt
    { parserAttemptParser = "tungsten"
    , parserAttemptStatus = "failure"
    , parserAttemptElapsedMilliseconds = Just elapsed
    , parserAttemptErrorType = Just errorType
    , parserAttemptError = Just message
    , parserAttemptSummary = Map.empty
    }

skippedAttempt :: Text -> Text -> Text -> ParserAttempt
skippedAttempt parserName reason message =
  ParserAttempt
    { parserAttemptParser = parserName
    , parserAttemptStatus = "skipped"
    , parserAttemptElapsedMilliseconds = Nothing
    , parserAttemptErrorType = Just reason
    , parserAttemptError = Just message
    , parserAttemptSummary = Map.empty
    }

normalizeExtensions :: [Text] -> [Text]
normalizeExtensions = stableUnique . map normalize . filter (not . T.null . T.strip)
 where
  normalize value =
    let lowered = T.toLower (T.strip value)
     in if "." `T.isPrefixOf` lowered then lowered else "." <> lowered
  stableUnique = reverse . snd . foldl add (Set.empty, [])
  add (seen, output) value
    | Set.member value seen = (seen, output)
    | otherwise = (Set.insert value seen, value : output)

normalizeGlob :: Text -> Text
normalizeGlob = T.replace "\\" "/"

normalizeRelativePath :: FilePath -> Text
normalizeRelativePath = normalizeGlob . T.pack

matchesAny :: Text -> [Text] -> Bool
matchesAny value = any (`globMatches` value)

globMatches :: Text -> Text -> Bool
globMatches patternText valueText = match (T.unpack patternText) (T.unpack valueText)
 where
  match [] [] = True
  match [] _ = False
  match ('*' : rest) value = match rest value || case value of
    [] -> False
    _ : tailValue -> match ('*' : rest) tailValue
  match ('?' : rest) (_ : tailValue) = match rest tailValue
  match ('[' : rest) (character : tailValue) = case parseClass rest of
    Nothing -> character == '[' && match rest tailValue
    Just (accepted, remaining) -> accepted character && match remaining tailValue
  match (expected : rest) (actual : tailValue) = expected == actual && match rest tailValue
  match _ _ = False

  parseClass characters = case break (== ']') characters of
    (_, []) -> Nothing
    (members, _ : remaining) -> Just ((`elem` classCharacters members), remaining)
  classCharacters [] = []
  classCharacters (first : '-' : lastCharacter : rest) = [first .. lastCharacter] <> classCharacters rest
  classCharacters (character : rest) = character : classCharacters rest

sourceFromRelativePath :: Text -> Text
sourceFromRelativePath relativePath = case T.splitOn "/" relativePath of
  first : second : _ | first `elem` ["github", "notebookarchive"] -> first <> "/" <> second
  first : _ -> first
  [] -> ""

walkFiles :: FilePath -> IO [FilePath]
walkFiles path = do
  names <- sort <$> listDirectory path
  nested <- forM names $ \name -> do
    let child = path </> name
    isDirectory <- doesDirectoryExist child
    if isDirectory then walkFiles child else pure [child]
  pure (concat nested)

deterministicShuffle :: Int -> [CorpusFile] -> [CorpusFile]
deterministicShuffle seed = sortOn (shuffleKey seed . corpusFileRelativePath)

shuffleKey :: Int -> Text -> Word64
shuffleKey seed = T.foldl' step (fromIntegral seed `xor` 14695981039346656037)
 where
  step value character = (value `xor` fromIntegral (fromEnum character)) * 1099511628211

counterPayload :: (value -> Text) -> [value] -> JsonValue
counterPayload projection values =
  JsonObject
    ( Map.fromList
        [ (key, jsonInteger count)
        | (key, count) <- Map.toAscList counts
        ]
    )
 where
  counts = foldl (\result value -> Map.insertWith (+) (projection value) 1 result) Map.empty values

elapsedMilliseconds :: UTCTime -> UTCTime -> Double
elapsedMilliseconds started finished = realToFrac (diffUTCTime finished started) * 1000

truncateText :: Int -> Text -> Text
truncateText limit value
  | limit <= 0 || T.length value <= limit = value
  | otherwise = T.stripEnd (T.take (max 0 (limit - 3)) value) <> "..."

jsonInteger :: Integer -> JsonValue
jsonInteger = JsonNumber . T.pack . show

jsonDouble :: Double -> JsonValue
jsonDouble = JsonNumber . T.pack . show
