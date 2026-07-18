{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic discovery and local parsing for Wolfram parser corpora.
module Tungsten.ParserCorpus
  ( CorpusFile (..)
  , ParserAttempt (..)
  , ParserCorpusResult (..)
  , defaultCorpusExtensions
  , discoverCorpusFiles
  , summarizeCorpusDiscovery
  , parseCorpusFile
  , localCorpusResults
  , classifyParserOutcome
  , corpusFilePayload
  , parserAttemptPayload
  , parserCorpusResultPayload
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import qualified Data.ByteString as BS
import Data.Bits (xor)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  , makeAbsolute
  )
import System.FilePath
  ( (</>)
  , makeRelative
  , takeExtension
  )
import Tungsten.Expression (Expr, arguments, fullForm)
import Tungsten.Json
import Tungsten.Notebook
import Tungsten.Parser

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

defaultCorpusExtensions :: [Text]
defaultCorpusExtensions = [".wl", ".m", ".wls", ".mt", ".wlt", ".nb", ".nbp"]

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
  "standard" -> Left "StandardForm parsing is not implemented by the Haskell parser"
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
