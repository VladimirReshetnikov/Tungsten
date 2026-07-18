{-# LANGUAGE OverloadedStrings #-}

-- | Cross-platform discovery of local Wolfram installations.
module Tungsten.Discovery
  ( InstallationSummary (..)
  , WolframInstallation (..)
  , parseVersion
  , sortInstallations
  , discoverInstallation
  ) where

import Control.Monad (filterM)
import Data.Char (isDigit, toLower)
import Data.List (isInfixOf, nubBy, sortBy)
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getHomeDirectory
  , listDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory, takeFileName)

data InstallationSummary = InstallationSummary
  { summaryProduct :: !Text
  , summaryProductFamily :: !Text
  , summaryVersion :: !(Maybe Text)
  , summaryInstallDir :: !FilePath
  , summaryKernelCli :: !(Maybe FilePath)
  , summaryWolframscript :: !(Maybe FilePath)
  }
  deriving (Eq, Show)

data WolframInstallation = WolframInstallation
  { installationProduct :: !Text
  , installationProductFamily :: !Text
  , installationVersion :: !(Maybe Text)
  , installationInstallDir :: !(Maybe FilePath)
  , installationKernelCli :: !(Maybe FilePath)
  , installationKernelExecutable :: !(Maybe FilePath)
  , installationFrontendExecutable :: !(Maybe FilePath)
  , installationWolframscript :: !(Maybe FilePath)
  , installationMathpass :: !(Maybe FilePath)
  , installationMathpassCandidates :: ![FilePath]
  , installationDocsRoots :: ![FilePath]
  , installationBundledPythonClient :: !(Maybe FilePath)
  , installationDefaultIndexPath :: !FilePath
  , installationUserBase :: !(Maybe FilePath)
  , installationSystemBase :: !(Maybe FilePath)
  , installationAvailable :: ![InstallationSummary]
  , installationSelectionReason :: !(Maybe Text)
  }
  deriving (Eq, Show)

parseVersion :: Text -> [Int]
parseVersion value = go (T.splitOn "." value)
 where
  go [] = []
  go (fragment : rest) | T.null (T.strip fragment) = go rest
  go (fragment : rest) = case parseFragment fragment of
    Nothing -> []
    Just number -> number : go rest
  parseFragment fragment
    | T.null fragment || not (T.all isDigit fragment) = Nothing
    | otherwise = case reads (T.unpack fragment) of
        [(number, "")] -> Just number
        _ -> Nothing

sortInstallations :: [InstallationSummary] -> [InstallationSummary]
sortInstallations = sortBy compareInstallation
 where
  compareInstallation left right =
    compare (familyPriority left) (familyPriority right)
      <> compareVersionDescending (summaryVersion left) (summaryVersion right)
      <> compare (map toLower (summaryInstallDir left)) (map toLower (summaryInstallDir right))
  familyPriority summary
    | summaryProductFamily summary == "wolfram" = 0 :: Int
    | otherwise = 1
  compareVersionDescending left right =
    compare (maybe [] parseVersion right) (maybe [] parseVersion left)

discoverInstallation :: IO WolframInstallation
discoverInstallation = do
  explicitHome <- lookupEnv "TUNGSTEN_WOLFRAM_HOME"
  requestedFamily <- normalizeRequestedFamily <$> lookupEnv "TUNGSTEN_WOLFRAM_PRODUCT"
  candidates <- discoverCandidates explicitHome
  let available = sortInstallations candidates
      selected = selectInstallation explicitHome requestedFamily available
      selectionReason = case selected of
        Nothing -> Nothing
        Just _ | explicitHome /= Nothing -> Just "TUNGSTEN_WOLFRAM_HOME"
        Just _ | requestedFamily /= Nothing -> ("TUNGSTEN_WOLFRAM_PRODUCT=" <>) <$> requestedFamily
        Just _ -> Just "default-product-preference"
  buildInstallation selected available selectionReason

discoverCandidates :: Maybe FilePath -> IO [InstallationSummary]
discoverCandidates explicitHome = do
  explicit <- case explicitHome of
    Nothing -> pure []
    Just path -> maybe [] pure <$> summarizeCandidate path
  standard <- if null explicit then standardCandidates else pure []
  pathCandidates <- if null explicit && null standard then executableCandidates else pure []
  pure (deduplicate (explicit <> standard <> pathCandidates))
 where
  deduplicate = nubBy (\left right -> summaryInstallDir left == summaryInstallDir right)

standardCandidates :: IO [InstallationSummary]
standardCandidates = do
  programFiles <- maybe "C:\\Program Files" id <$> lookupEnv "ProgramFiles"
  let researchRoot = programFiles </> "Wolfram Research"
      productRoots = [researchRoot </> "Wolfram", researchRoot </> "Wolfram Engine"]
  roots <- concat <$> traverse versionDirectories productRoots
  catMaybes <$> traverse summarizeCandidate roots

versionDirectories :: FilePath -> IO [FilePath]
versionDirectories root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      children <- listDirectory root
      filterM doesDirectoryExist [root </> child | child <- children, not (null (parseVersion (T.pack child)))]

executableCandidates :: IO [InstallationSummary]
executableCandidates = do
  executables <- traverse findExecutable ["wolfram", "WolframKernel", "wolframscript"]
  catMaybes <$> traverse summarizeCandidate (map takeDirectory (catMaybes executables))

summarizeCandidate :: FilePath -> IO (Maybe InstallationSummary)
summarizeCandidate original = do
  isFile <- doesFileExist original
  isDirectory <- doesDirectoryExist original
  let root = if isFile then takeDirectory original else original
  if not isFile && not isDirectory
    then pure Nothing
    else do
      resolved <- canonicalizePath root
      kernel <- firstExisting (if isFile then [original] else kernelCandidates resolved)
      script <- firstExisting (scriptCandidates resolved)
      if kernel == Nothing && script == Nothing
        then pure Nothing
        else do
          let family = inferProductFamily resolved
              versionText = T.pack (takeFileName resolved)
          pure
            ( Just
                InstallationSummary
                  { summaryProduct = if family == "engine" then "Wolfram Engine" else "Wolfram"
                  , summaryProductFamily = family
                  , summaryVersion = if null (parseVersion versionText) then Nothing else Just versionText
                  , summaryInstallDir = resolved
                  , summaryKernelCli = kernel
                  , summaryWolframscript = script
                  }
            )

selectInstallation
  :: Maybe FilePath
  -> Maybe Text
  -> [InstallationSummary]
  -> Maybe InstallationSummary
selectInstallation explicitHome requestedFamily available
  | explicitHome /= Nothing = listToMaybe available
  | Just family <- requestedFamily =
      case listToMaybe (filter ((== family) . summaryProductFamily) available) of
        Just matching -> Just matching
        Nothing -> listToMaybe available
  | otherwise = listToMaybe available

buildInstallation
  :: Maybe InstallationSummary
  -> [InstallationSummary]
  -> Maybe Text
  -> IO WolframInstallation
buildInstallation selected available selectionReason = do
  localAppData <- lookupEnv "LOCALAPPDATA"
  appData <- lookupEnv "APPDATA"
  programData <- lookupEnv "ProgramData"
  home <- getHomeDirectory
  let family = maybe "wolfram" summaryProductFamily selected
      productName = maybe "Wolfram" summaryProduct selected
      version = selected >>= summaryVersion
      installDir = summaryInstallDir <$> selected
      userBaseName = if family == "engine" then "WolframEngine" else "Wolfram"
      userBase = (</> userBaseName) <$> appData
      systemBase = Just (maybe "C:\\ProgramData" id programData </> userBaseName)
      mathpassCandidates =
        catMaybes
          [ (</> "Licensing" </> "mathpass") <$> userBase
          , (</> "Licensing" </> "mathpass") <$> systemBase
          ]
      cacheRoot = maybe (home </> ".cache") id localAppData
      indexVersion = maybe "unknown" T.unpack version
      indexPrefix = if family == "engine" then "wolfram-engine" else "wolfram"
      defaultIndexPath = cacheRoot </> "Tungsten" </> "docs" </> (indexPrefix <> "-" <> indexVersion <> ".sqlite3")
  kernelExecutable <- optionalExisting installDir ["WolframKernel.exe", "WolframKernel"]
  frontendExecutable <- optionalExisting installDir ["WolframNB.exe", "Mathematica.exe", "Mathematica"]
  bundledClient <- optionalExistingDirectory installDir ["SystemFiles" </> "Components" </> "WolframClientForPython"]
  mathpass <- firstExisting mathpassCandidates
  docsRoots <- discoverDocsRoots installDir appData
  pure
    WolframInstallation
      { installationProduct = productName
      , installationProductFamily = family
      , installationVersion = version
      , installationInstallDir = installDir
      , installationKernelCli = selected >>= summaryKernelCli
      , installationKernelExecutable = kernelExecutable
      , installationFrontendExecutable = frontendExecutable
      , installationWolframscript = selected >>= summaryWolframscript
      , installationMathpass = mathpass
      , installationMathpassCandidates = mathpassCandidates
      , installationDocsRoots = docsRoots
      , installationBundledPythonClient = bundledClient
      , installationDefaultIndexPath = defaultIndexPath
      , installationUserBase = userBase
      , installationSystemBase = systemBase
      , installationAvailable = available
      , installationSelectionReason = selectionReason
      }

discoverDocsRoots :: Maybe FilePath -> Maybe FilePath -> IO [FilePath]
discoverDocsRoots installDir appData = do
  let candidates = catMaybes
        [ (</> "Documentation" </> "English" </> "System") <$> installDir
        , (</> "Wolfram" </> "Documentation" </> "English") <$> appData
        , (</> "WolframEngine" </> "Documentation" </> "English") <$> appData
        ]
  filterM doesDirectoryExist candidates

optionalExisting :: Maybe FilePath -> [FilePath] -> IO (Maybe FilePath)
optionalExisting Nothing _ = pure Nothing
optionalExisting (Just root) relativePaths = firstExisting [root </> path | path <- relativePaths]

optionalExistingDirectory :: Maybe FilePath -> [FilePath] -> IO (Maybe FilePath)
optionalExistingDirectory Nothing _ = pure Nothing
optionalExistingDirectory (Just root) relativePaths =
  listToMaybe <$> filterM doesDirectoryExist [root </> path | path <- relativePaths]

firstExisting :: [FilePath] -> IO (Maybe FilePath)
firstExisting paths = listToMaybe <$> filterM doesFileExist paths

kernelCandidates :: FilePath -> [FilePath]
kernelCandidates root =
  [ root </> "wolfram.exe"
  , root </> "wolfram"
  , root </> "WolframKernel.exe"
  , root </> "WolframKernel"
  ]

scriptCandidates :: FilePath -> [FilePath]
scriptCandidates root = [root </> "wolframscript.exe", root </> "wolframscript"]

inferProductFamily :: FilePath -> Text
inferProductFamily path
  | "wolfram engine" `isInfixOf` map toLower path = "engine"
  | "wolframengine" `isInfixOf` map toLower path = "engine"
  | otherwise = "wolfram"

normalizeRequestedFamily :: Maybe String -> Maybe Text
normalizeRequestedFamily value = case map toLower <$> value of
  Nothing -> Nothing
  Just "" -> Nothing
  Just alias
    | alias `elem` ["engine", "wolframengine", "wolfram-engine", "wefd"] -> Just "engine"
    | alias `elem` ["wolfram", "desktop", "paid", "mathematica"] -> Just "wolfram"
    | otherwise -> Just (T.pack alias)
