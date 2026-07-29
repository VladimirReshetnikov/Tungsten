{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Kernel-free extraction and SQLite FTS indexing of Wolfram documentation.
module Tungsten.DocsIndex
  ( DocumentationError (..)
  , DocumentationRecord (..)
  , DocumentationHit (..)
  , buildDocumentationIndex
  , ensureDocumentationIndex
  , searchDocumentation
  , readDocumentation
  , resolveDocumentationIdentifier
  , documentationRecordFromPath
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isHexDigit, isSpace, toLower)
import Data.List (findIndex, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import qualified Data.Text.IO as TextIO
import Numeric (showHex)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , listDirectory
  , makeAbsolute
  , removeFile
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( (</>)
  , splitDirectories
  , takeBaseName
  , takeDirectory
  , takeExtension
  )
import System.IO (Handle, hClose, hSetEncoding, utf8)
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe, NoStream)
  , createProcess
  , proc
  , readProcessWithExitCode
  , waitForProcess
  )
import Text.Read (readMaybe)
import Tungsten.Discovery
import Tungsten.Json
import Tungsten.WolframString

newtype DocumentationError = DocumentationError {documentationErrorMessage :: Text}
  deriving (Eq, Show)

data DocumentationRecord = DocumentationRecord
  { documentationId :: !(Maybe Integer)
  , documentationTitle :: !Text
  , documentationPaclet :: !Text
  , documentationKind :: !Text
  , documentationCategory :: !Text
  , documentationPath :: !FilePath
  , documentationPreview :: !Text
  , documentationText :: !Text
  }
  deriving (Eq, Show)

data DocumentationHit = DocumentationHit
  { documentationHitTitle :: !Text
  , documentationHitPaclet :: !Text
  , documentationHitKind :: !Text
  , documentationHitCategory :: !Text
  , documentationHitPath :: !FilePath
  , documentationHitPreview :: !Text
  , documentationHitSnippet :: !Text
  , documentationHitScore :: !Text
  }
  deriving (Eq, Show)

buildDocumentationIndex
  :: WolframInstallation
  -> Maybe FilePath
  -> IO (Either DocumentationError FilePath)
buildDocumentationIndex installation requestedPath = do
  let target = maybe (installationDefaultIndexPath installation) id requestedPath
  absoluteTarget <- makeAbsolute target
  sqlite <- findExecutable "sqlite3"
  case sqlite of
    Nothing -> pure (Left (DocumentationError "sqlite3 is required to build the documentation index"))
    Just sqliteExecutable -> do
      preparation <- try $ do
        createDirectoryIfMissing True (takeDirectory absoluteTarget)
        exists <- doesFileExist absoluteTarget
        if exists then removeFile absoluteTarget else pure ()
      case (preparation :: Either IOException ()) of
        Left exception -> pure (Left (DocumentationError (T.pack (show exception))))
        Right () -> do
          files <- documentationNotebookFiles (installationDocsRoots installation)
          recordsResult <- traverse documentationRecordFromPath files
          case sequence recordsResult of
            Left documentationError -> pure (Left documentationError)
            Right records -> do
              writeResult <- writeSqliteIndex sqliteExecutable absoluteTarget installation records
              pure (absoluteTarget <$ writeResult)

ensureDocumentationIndex
  :: WolframInstallation
  -> Maybe FilePath
  -> Bool
  -> IO (Either DocumentationError FilePath)
ensureDocumentationIndex installation requestedPath rebuild = do
  let target = maybe (installationDefaultIndexPath installation) id requestedPath
  exists <- doesFileExist target
  if rebuild || not exists
    then buildDocumentationIndex installation requestedPath
    else Right <$> makeAbsolute target

searchDocumentation
  :: WolframInstallation
  -> Text
  -> Maybe FilePath
  -> Int
  -> Bool
  -> IO (Either DocumentationError [DocumentationHit])
searchDocumentation installation query indexPath limit rebuild = do
  fastPaths <- findDocumentationPaths installation query (max 0 limit)
  if null fastPaths
    then do
      targetResult <- ensureDocumentationIndex installation indexPath rebuild
      case targetResult of
        Left documentationError -> pure (Left documentationError)
        Right target -> searchSqlite target query (max 0 limit)
    else do
      records <- traverse documentationRecordFromPath fastPaths
      pure (map recordHit <$> sequence records)
 where
  recordHit record =
    DocumentationHit
      { documentationHitTitle = documentationTitle record
      , documentationHitPaclet = documentationPaclet record
      , documentationHitKind = documentationKind record
      , documentationHitCategory = documentationCategory record
      , documentationHitPath = documentationPath record
      , documentationHitPreview = documentationPreview record
      , documentationHitSnippet = documentationPreview record
      , documentationHitScore = "0.0"
      }

readDocumentation
  :: WolframInstallation
  -> Text
  -> Maybe FilePath
  -> Bool
  -> IO (Either DocumentationError DocumentationRecord)
readDocumentation installation identifier indexPath rebuild = do
  fastPaths <- findDocumentationPaths installation identifier 1
  case fastPaths of
    path : _ -> documentationRecordFromPath path
    [] -> do
      targetResult <- ensureDocumentationIndex installation indexPath rebuild
      case targetResult of
        Left documentationError -> pure (Left documentationError)
        Right target -> do
          primary <- readSqlite target identifier
          case primary of
            Right (Just record) -> pure (Right record)
            Left documentationError -> pure (Left documentationError)
            Right Nothing -> do
              hits <- searchDocumentation installation identifier (Just target) 1 False
              case hits of
                Right (hit : _) -> do
                  fallback <- readSqlite target (documentationHitPaclet hit)
                  pure $ case fallback of
                    Right (Just record) -> Right record
                    Right Nothing -> notFound identifier
                    Left documentationError -> Left documentationError
                Right [] -> pure (notFound identifier)
                Left documentationError -> pure (Left documentationError)

resolveDocumentationIdentifier
  :: WolframInstallation
  -> Text
  -> Maybe FilePath
  -> IO (Either DocumentationError Text)
resolveDocumentationIdentifier installation identifier indexPath
  | "paclet:" `T.isPrefixOf` identifier = pure (Right identifier)
  | otherwise =
      fmap documentationPaclet <$> readDocumentation installation identifier indexPath False

documentationRecordFromPath :: FilePath -> IO (Either DocumentationError DocumentationRecord)
documentationRecordFromPath notebookPath = do
  sourceResult <- try (BS.readFile notebookPath)
  case (sourceResult :: Either IOException BS.ByteString) of
    Left exception -> pure (Left (DocumentationError (T.pack (show exception))))
    Right bytes -> do
      absolutePath <- makeAbsolute notebookPath
      let source = TE.decodeUtf8With TEE.lenientDecode bytes
          title = extractTitle source notebookPath
          (kind, category, paclet) = inferKindAndPaclet notebookPath
          strings = filterUsefulStrings (extractStringLiterals source)
          textValue = collapseText 20000 (T.unwords strings)
          previewSource = T.unwords [fragment | fragment <- strings, fragment /= title]
      pure
        ( Right
            DocumentationRecord
              { documentationId = Nothing
              , documentationTitle = title
              , documentationPaclet = paclet
              , documentationKind = kind
              , documentationCategory = category
              , documentationPath = absolutePath
              , documentationPreview = collapseText 300 previewSource
              , documentationText = textValue
              }
        )

writeSqliteIndex
  :: FilePath
  -> FilePath
  -> WolframInstallation
  -> [DocumentationRecord]
  -> IO (Either DocumentationError ())
writeSqliteIndex sqlite target installation records = do
  processResult <- try $ do
    (Just input, _, Just errors, processHandle) <-
      createProcess
        (proc sqlite [target])
          { std_in = CreatePipe
          , std_out = NoStream
          , std_err = CreatePipe
          }
    hSetEncoding input utf8
    hSetEncoding errors utf8
    writeIndexScript input installation records
    hClose input
    errorText <- TextIO.hGetContents errors
    exitCode <- waitForProcess processHandle
    pure (exitCode, errorText)
  case (processResult :: Either IOException (ExitCode, Text)) of
    Left exception -> pure (Left (DocumentationError (T.pack (show exception))))
    Right (ExitSuccess, _) -> pure (Right ())
    Right (ExitFailure code, errorText) ->
      pure
        ( Left
            ( DocumentationError
                ("sqlite3 exited with code " <> T.pack (show code) <> ": " <> T.strip errorText)
            )
        )

writeIndexScript :: Handle -> WolframInstallation -> [DocumentationRecord] -> IO ()
writeIndexScript input installation records = do
  TextIO.hPutStrLn input ".bail on"
  TextIO.hPutStrLn input "BEGIN IMMEDIATE;"
  TextIO.hPutStrLn input
    "CREATE TABLE documents (id INTEGER PRIMARY KEY, title TEXT NOT NULL, paclet TEXT NOT NULL, kind TEXT NOT NULL, category TEXT NOT NULL, path TEXT NOT NULL, preview TEXT NOT NULL, text TEXT NOT NULL);"
  TextIO.hPutStrLn input
    "CREATE VIRTUAL TABLE documents_fts USING fts5(title, paclet, kind, category, preview, text, content='documents', content_rowid='id');"
  TextIO.hPutStrLn input "CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
  let rootsJson = encodeJson (JsonArray (map (JsonString . T.pack) (installationDocsRoots installation)))
  TextIO.hPutStrLn input
    ("INSERT INTO metadata(key, value) VALUES(" <> sqlText "docs_roots" <> ", " <> sqlText rootsJson <> ");")
  forM_ records $ \record ->
    TextIO.hPutStrLn input
      ( "INSERT INTO documents(title, paclet, kind, category, path, preview, text) VALUES("
          <> T.intercalate
            ", "
            ( map
                sqlText
                [ documentationTitle record
                , documentationPaclet record
                , documentationKind record
                , documentationCategory record
                , T.pack (documentationPath record)
                , documentationPreview record
                , documentationText record
                ]
            )
          <> ");"
      )
  TextIO.hPutStrLn input "INSERT INTO documents_fts(documents_fts) VALUES('rebuild');"
  TextIO.hPutStrLn input "COMMIT;"

searchSqlite :: FilePath -> Text -> Int -> IO (Either DocumentationError [DocumentationHit])
searchSqlite target query limit = do
  let statement =
        "SELECT documents.title, documents.paclet, documents.kind, documents.category, documents.path, documents.preview, "
          <> "snippet(documents_fts, 5, '[', ']', ' … ', 18) AS snippet, bm25(documents_fts) AS score "
          <> "FROM documents_fts JOIN documents ON documents.id = documents_fts.rowid "
          <> "WHERE documents_fts MATCH "
          <> sqlText (buildMatchQuery query)
          <> " ORDER BY score LIMIT "
          <> T.pack (show limit)
          <> ";"
  rows <- sqliteJsonQuery target statement
  pure (rows >>= traverse decodeHit)

readSqlite :: FilePath -> Text -> IO (Either DocumentationError (Maybe DocumentationRecord))
readSqlite target identifier = do
  pathExists <- doesFileExist (T.unpack identifier)
  absoluteIdentifier <- if pathExists then Just <$> makeAbsolute (T.unpack identifier) else pure Nothing
  let condition = case absoluteIdentifier of
        Just path -> "path = " <> sqlText (T.pack path)
        Nothing
          | "paclet:" `T.isPrefixOf` identifier ->
              "paclet = " <> sqlText identifier <> " COLLATE NOCASE"
          | otherwise ->
              "title = " <> sqlText identifier <> " COLLATE NOCASE OR paclet = " <> sqlText identifier <> " COLLATE NOCASE"
      statement =
        "SELECT id, title, paclet, kind, category, path, preview, text FROM documents WHERE "
          <> condition
          <> " LIMIT 1;"
  rows <- sqliteJsonQuery target statement
  pure $ do
    values <- rows
    case values of
      [] -> Right Nothing
      value : _ -> Just <$> decodeRecord value

sqliteJsonQuery :: FilePath -> Text -> IO (Either DocumentationError [JsonValue])
sqliteJsonQuery target statement = do
  sqlite <- findExecutable "sqlite3"
  case sqlite of
    Nothing -> pure (Left (DocumentationError "sqlite3 is required to query the documentation index"))
    Just executable -> do
      processResult <- try (readProcessWithExitCode executable ["-json", target, T.unpack statement] "")
      case (processResult :: Either IOException (ExitCode, String, String)) of
        Left exception -> pure (Left (DocumentationError (T.pack (show exception))))
        Right (ExitFailure code, _, errors) ->
          pure (Left (DocumentationError ("sqlite3 exited with code " <> T.pack (show code) <> ": " <> T.strip (T.pack errors))))
        Right (ExitSuccess, output, _)
          | null (dropWhile isSpace output) -> pure (Right [])
          | otherwise -> case parseJson (T.pack output) of
              Left jsonError -> pure (Left (DocumentationError (jsonErrorMessage jsonError)))
              Right (JsonArray rows) -> pure (Right rows)
              Right _ -> pure (Left (DocumentationError "sqlite3 did not return a JSON array"))

decodeRecord :: JsonValue -> Either DocumentationError DocumentationRecord
decodeRecord value = do
  fields <- objectFields value
  DocumentationRecord
    <$> optionalIntegerField "id" fields
    <*> textField "title" fields
    <*> textField "paclet" fields
    <*> textField "kind" fields
    <*> textField "category" fields
    <*> (T.unpack <$> textField "path" fields)
    <*> textField "preview" fields
    <*> textField "text" fields

optionalIntegerField :: Text -> Map.Map Text JsonValue -> Either DocumentationError (Maybe Integer)
optionalIntegerField key fields = case Map.lookup key fields of
  Nothing -> Right Nothing
  Just JsonNull -> Right Nothing
  Just (JsonNumber value) ->
    maybe (Left (DocumentationError ("invalid integer field: " <> key))) (Right . Just)
      (readMaybe (T.unpack value))
  Just _ -> Left (DocumentationError ("invalid integer field: " <> key))

decodeHit :: JsonValue -> Either DocumentationError DocumentationHit
decodeHit value = do
  fields <- objectFields value
  DocumentationHit
    <$> textField "title" fields
    <*> textField "paclet" fields
    <*> textField "kind" fields
    <*> textField "category" fields
    <*> (T.unpack <$> textField "path" fields)
    <*> textField "preview" fields
    <*> textField "snippet" fields
    <*> numberField "score" fields

objectFields :: JsonValue -> Either DocumentationError (Map.Map Text JsonValue)
objectFields (JsonObject fields) = Right fields
objectFields _ = Left (DocumentationError "documentation index row must be a JSON object")

textField :: Text -> Map.Map Text JsonValue -> Either DocumentationError Text
textField key fields = case Map.lookup key fields of
  Just (JsonString value) -> Right value
  _ -> Left (DocumentationError ("documentation index row is missing text field " <> key))

numberField :: Text -> Map.Map Text JsonValue -> Either DocumentationError Text
numberField key fields = case Map.lookup key fields of
  Just (JsonNumber value) -> Right value
  _ -> Left (DocumentationError ("documentation index row is missing numeric field " <> key))

documentationNotebookFiles :: [FilePath] -> IO [FilePath]
documentationNotebookFiles roots = concat <$> traverse walkRoot roots
 where
  walkRoot root = do
    exists <- doesDirectoryExist root
    if exists then walk root else pure []
  walk path = do
    names <- sort <$> listDirectory path
    nested <- forM names $ \name -> do
      let child = path </> name
      isDirectory <- doesDirectoryExist child
      if isDirectory
        then walk child
        else pure [child | map toLower (takeExtension child) == ".nb"]
    pure (concat nested)

findDocumentationPaths :: WolframInstallation -> Text -> Int -> IO [FilePath]
findDocumentationPaths installation identifier limit = case stemFromIdentifier identifier of
  Nothing -> pure []
  Just stem -> do
    paths <- documentationNotebookFiles (installationDocsRoots installation)
    pure
      ( take limit
          [ path
          | path <- paths
          , map toLower (takeBaseName path) == map toLower (T.unpack stem)
          ]
      )

stemFromIdentifier :: Text -> Maybe Text
stemFromIdentifier identifier =
  let candidate
        | "paclet:" `T.isPrefixOf` identifier = lastOrEmpty (T.splitOn "/" identifier)
        | otherwise = T.pack (takeBaseName (T.unpack identifier))
   in if T.null candidate || T.any (not . validStemCharacter) candidate
        then Nothing
        else Just candidate
 where
  validStemCharacter character = isAlphaNum character || character `elem` ("_.-" :: String)
  lastOrEmpty [] = ""
  lastOrEmpty values = last values

extractTitle :: Text -> FilePath -> Text
extractTitle source path = case T.breakOn "WindowTitle" source of
  (_, remainder) | T.null remainder -> T.pack (takeBaseName path)
  (_, remainder) ->
    let afterName = T.drop (T.length "WindowTitle") remainder
        afterArrow = T.stripStart (maybe afterName id (T.stripPrefix "->" (T.stripStart afterName)))
     in case T.uncons afterArrow of
          Just ('"', _) ->
            let end = skipWolframString afterArrow 0
             in parseWolframStringLiteral (T.take end afterArrow)
          _ ->
            let value = T.takeWhile validTitleCharacter afterArrow
             in if T.null value then T.pack (takeBaseName path) else value
 where
  validTitleCharacter character = isAlphaNum character || character `elem` ("`.$_-" :: String)

inferKindAndPaclet :: FilePath -> (Text, Text, Text)
inferKindAndPaclet path = case componentAfter "ReferencePages" components of
  Just category ->
    let pacletCategory = maybe ("ref/" <> T.toLower category) id (lookup category referenceCategories)
     in ("reference", category, "paclet:" <> pacletCategory <> "/" <> stem)
  Nothing -> case firstSection components of
    Just (section, category) -> (category, section, "paclet:" <> category <> "/" <> stem)
    Nothing -> ("document", "Other", "paclet:document/" <> stem)
 where
  components = map T.pack (splitDirectories path)
  stem = T.pack (takeBaseName path)
  componentAfter name values = do
    index <- findIndex (== name) values
    case drop (index + 1) values of
      value : _ -> Just value
      [] -> Nothing
  firstSection values = firstMatch sectionCategories
   where
    firstMatch [] = Nothing
    firstMatch ((section, category) : rest)
      | section `elem` values = Just (section, category)
      | otherwise = firstMatch rest

referenceCategories :: [(Text, Text)]
referenceCategories =
  [ ("Symbols", "ref")
  , ("Programs", "ref/program")
  , ("MenuItems", "ref/menuitem")
  , ("Characters", "ref/character")
  , ("Entities", "ref/entity")
  , ("Interpreters", "ref/interpreter")
  , ("FrontEndObjects", "ref/frontendobject")
  ]

sectionCategories :: [(Text, Text)]
sectionCategories =
  [ ("Guides", "guide")
  , ("Tutorials", "tutorial")
  , ("HowTos", "howto")
  , ("Workflows", "workflow")
  , ("WorkflowGuides", "workflowguide")
  , ("ExamplePages", "example")
  ]

extractStringLiterals :: Text -> [Text]
extractStringLiterals source = reverse (go 0 [])
 where
  sourceLength = T.length source
  go index output
    | index >= sourceLength = output
    | "(*" `T.isPrefixOf` T.drop index source = go (skipWolframComment source index) output
    | T.index source index == '"' =
        let nextIndex = skipWolframString source index
            literal = T.take (nextIndex - index) (T.drop index source)
         in go nextIndex (parseWolframStringLiteral literal : output)
    | otherwise = go (index + 1) output

filterUsefulStrings :: [Text] -> [Text]
filterUsefulStrings = filter useful . map T.strip
 where
  useful value =
    not (T.null value)
      && not (Set.member value noiseLiterals)
      && not (isUuid value)
      && not (isCompressedBlob value)

noiseLiterals :: Set.Set Text
noiseLiterals =
  Set.fromList
    [ "AnchorBar", "AnchorBarGrid", "Columns", "ExampleCount", "ExampleSection"
    , "LinkHand", "ObjectNameTranslation", "PacletNameCell", "PrimaryExamplesSection"
    , "Rows", "SeeAlsoRelated", "Spacer1"
    ]

isUuid :: Text -> Bool
isUuid value = case T.splitOn "-" value of
  [a, b, c, d, e] ->
    map T.length [a, b, c, d, e] == [8, 4, 4, 4, 12]
      && T.all isHexDigit (a <> b <> c <> d <> e)
  _ -> False

isCompressedBlob :: Text -> Bool
isCompressedBlob value =
  T.length value >= 200 && T.all (`elem` ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=:._-" :: String)) value

collapseText :: Int -> Text -> Text
collapseText limit value
  | T.length collapsed <= limit = collapsed
  | limit <= 0 = ""
  | otherwise = T.stripEnd (T.take (limit - 1) collapsed) <> "…"
 where
  collapsed = T.unwords (T.words value)

buildMatchQuery :: Text -> Text
buildMatchQuery query = case wordsBy (not . matchCharacter) query of
  [] -> "\"" <> T.replace "\"" "\"\"" query <> "\""
  terms -> T.intercalate " AND " ["\"" <> term <> "\"*" | term <- terms]
 where
  matchCharacter character = isAlphaNum character || character `elem` ("_.:/-" :: String)
  wordsBy separator = filter (not . T.null) . T.split separator

sqlText :: Text -> Text
sqlText value = "CAST(X'" <> TE.decodeUtf8 (hexBytes (TE.encodeUtf8 value)) <> "' AS TEXT)"
 where
  hexBytes = BS.concatMap (TE.encodeUtf8 . byteHex)
  byteHex byte =
    let digits = showHex byte ""
     in T.pack (replicate (2 - length digits) '0' <> digits)

notFound :: Text -> Either DocumentationError value
notFound identifier =
  Left (DocumentationError ("No documentation page found for " <> identifier <> "."))
