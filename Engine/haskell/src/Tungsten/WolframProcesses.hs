{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Wolfram process inspection, cached license limits, and launch coordination.
module Tungsten.WolframProcesses
  ( WolframProcessInfo (..)
  , WolframProcessSnapshot (..)
  , wolframProcessAgeSeconds
  , wolframProcessPayload
  , wolframProcessSnapshotPayload
  , activeWolframProcessCount
  , isControllingProcessCandidate
  , readCachedMaxLicenseProcesses
  , readCachedMaxLicenseProcessesAt
  , writeCachedMaxLicenseProcesses
  , writeCachedMaxLicenseProcessesAt
  , listWolframProcesses
  , snapshotWolframProcesses
  , cleanupStaleTungstenProcesses
  , withWolframLaunchGate
  , waitForWolframLicenseSlot
  , waitForWolframLicenseSlotWith
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getTemporaryDirectory
  , removeDirectory
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeDirectory)
import System.Info (os)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)
import Tungsten.Json

data WolframProcessInfo = WolframProcessInfo
  { wolframProcessPid :: !Int
  , wolframProcessParentPid :: !Int
  , wolframProcessName :: !Text
  , wolframProcessExecutablePath :: !(Maybe FilePath)
  , wolframProcessCommandLine :: !(Maybe Text)
  , wolframProcessStartedUtc :: !(Maybe Text)
  , wolframProcessTungstenOwned :: !Bool
  , wolframProcessHeadlessBatch :: !Bool
  , wolframProcessParentMissing :: !Bool
  , wolframProcessControllingCandidate :: !Bool
  }
  deriving (Eq, Show)

data WolframProcessSnapshot = WolframProcessSnapshot
  { wolframSnapshotProcesses :: ![WolframProcessInfo]
  , wolframSnapshotCachedMaxLicenseProcesses :: !(Maybe Int)
  }
  deriving (Eq, Show)

wolframProcessAgeSeconds :: UTCTime -> WolframProcessInfo -> Maybe Double
wolframProcessAgeSeconds now process = do
  source <- wolframProcessStartedUtc process
  started <-
    parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack source)
      :: Maybe UTCTime
  pure (max 0 (realToFrac (diffUTCTime now started)))

wolframProcessPayload :: UTCTime -> WolframProcessInfo -> JsonValue
wolframProcessPayload now process =
  JsonObject
    ( Map.fromList
        [ ("age_seconds", maybe JsonNull jsonDouble (wolframProcessAgeSeconds now process))
        , ("command_line", maybe JsonNull JsonString (wolframProcessCommandLine process))
        , ("controlling_process_candidate", JsonBool (wolframProcessControllingCandidate process))
        , ("executable_path", maybe JsonNull (JsonString . T.pack) (wolframProcessExecutablePath process))
        , ("headless_batch", JsonBool (wolframProcessHeadlessBatch process))
        , ("name", JsonString (wolframProcessName process))
        , ("parent_missing", JsonBool (wolframProcessParentMissing process))
        , ("parent_pid", jsonInteger (fromIntegral (wolframProcessParentPid process)))
        , ("pid", jsonInteger (fromIntegral (wolframProcessPid process)))
        , ("started_utc", maybe JsonNull JsonString (wolframProcessStartedUtc process))
        , ("tungsten_owned", JsonBool (wolframProcessTungstenOwned process))
        ]
    )

wolframProcessSnapshotPayload :: UTCTime -> WolframProcessSnapshot -> JsonValue
wolframProcessSnapshotPayload now snapshot =
  JsonObject
    ( Map.fromList
        [ ("active_count", jsonInteger (fromIntegral (activeWolframProcessCount snapshot)))
        , ( "cached_max_license_processes"
          , maybe JsonNull (jsonInteger . fromIntegral) (wolframSnapshotCachedMaxLicenseProcesses snapshot)
          )
        , ("processes", JsonArray (map (wolframProcessPayload now) (wolframSnapshotProcesses snapshot)))
        ]
    )

activeWolframProcessCount :: WolframProcessSnapshot -> Int
activeWolframProcessCount =
  length . filter wolframProcessControllingCandidate . wolframSnapshotProcesses

isControllingProcessCandidate :: Text -> Text -> Bool
isControllingProcessCandidate name commandLine
  | normalized `elem` ["mathematica", "mathematica.exe", "wolframdesktop", "wolframdesktop.exe"] = True
  | normalized `elem` ["wolfram", "wolfram.exe", "wolframkernel", "wolframkernel.exe", "mathkernel", "mathkernel.exe"] =
      not (any (`T.isInfixOf` lowerCommand) [" -mathlink ", " -subkernel ", "playerpass"])
  | otherwise = False
 where
  normalized = T.toLower name
  lowerCommand = T.toLower commandLine

readCachedMaxLicenseProcesses :: IO (Maybe Int)
readCachedMaxLicenseProcesses = cachePath >>= readCachedMaxLicenseProcessesAt

readCachedMaxLicenseProcessesAt :: FilePath -> IO (Maybe Int)
readCachedMaxLicenseProcessesAt path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      sourceResult <- try (TextIO.readFile path)
      pure $ case (sourceResult :: Either IOException Text) of
        Left _ -> Nothing
        Right source -> case parseJson source of
          Right (JsonObject payload) -> case Map.lookup "max_license_processes" payload of
            Just (JsonNumber value) -> readMaybe (T.unpack value) >>= positive
            _ -> Nothing
          _ -> Nothing
 where
  positive value = if value > 0 then Just value else Nothing

writeCachedMaxLicenseProcesses :: Int -> IO ()
writeCachedMaxLicenseProcesses value = cachePath >>= \path -> writeCachedMaxLicenseProcessesAt path value

writeCachedMaxLicenseProcessesAt :: FilePath -> Int -> IO ()
writeCachedMaxLicenseProcessesAt _ value | value <= 0 = pure ()
writeCachedMaxLicenseProcessesAt path value = do
  createDirectoryIfMissing True (takeDirectory path)
  now <- getCurrentTime
  let payload =
        JsonObject
          ( Map.fromList
              [ ("max_license_processes", jsonInteger (fromIntegral value))
              , ("updated_utc", JsonString (T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)))
              ]
          )
  TextIO.writeFile path (encodeJson payload <> "\n")

listWolframProcesses :: IO [WolframProcessInfo]
listWolframProcesses
  | os /= "mingw32" = pure []
  | otherwise = do
      executable <- findPowerShell
      case executable of
        Nothing -> pure []
        Just command -> do
          completed <- try (readProcessWithExitCode command powershellArguments "")
          pure $ case (completed :: Either IOException (ExitCode, String, String)) of
            Right (ExitSuccess, stdoutText, _) -> decodeProcessRows (T.pack stdoutText)
            _ -> []

snapshotWolframProcesses :: IO WolframProcessSnapshot
snapshotWolframProcesses =
  WolframProcessSnapshot <$> listWolframProcesses <*> readCachedMaxLicenseProcesses

cleanupStaleTungstenProcesses :: Double -> IO [Int]
cleanupStaleTungstenProcesses minimumAge = do
  now <- getCurrentTime
  processes <- listWolframProcesses
  fmap catMaybes . forM processes $ \process ->
    if stale now process
      then terminateProcessTree (wolframProcessPid process)
      else pure Nothing
 where
  stale now process =
    wolframProcessTungstenOwned process
      && wolframProcessHeadlessBatch process
      && wolframProcessParentMissing process
      && maybe True (>= minimumAge) (wolframProcessAgeSeconds now process)

withWolframLaunchGate
  :: Double
  -> Double
  -> (Double -> IO value)
  -> IO (Either Text value)
withWolframLaunchGate timeoutSeconds pollSeconds action = do
  root <- cacheRoot
  let lockDirectory = root </> "wolfram-launch.lock"
  createDirectoryIfMissing True root
  started <- getCurrentTime
  acquire lockDirectory started
 where
  acquire lockDirectory started = do
    acquired <- try (createDirectory lockDirectory)
    case (acquired :: Either IOException ()) of
      Right () ->
        Right <$> bracket (pure lockDirectory) release (const (elapsedSince started >>= action))
      Left _ -> do
        now <- getCurrentTime
        let waited = realToFrac (diffUTCTime now started)
        if waited >= timeoutSeconds
          then pure (Left "Timed out waiting for the Tungsten Wolfram launch gate.")
          else threadDelay (secondsToMicroseconds pollSeconds) >> acquire lockDirectory started
  release lockDirectory = do
    exists <- doesDirectoryExist lockDirectory
    if exists then removeDirectory lockDirectory else pure ()

waitForWolframLicenseSlot
  :: Maybe Int
  -> Double
  -> Double
  -> IO (WolframProcessSnapshot, Double, Bool)
waitForWolframLicenseSlot = waitForWolframLicenseSlotWith snapshotWolframProcesses

waitForWolframLicenseSlotWith
  :: IO WolframProcessSnapshot
  -> Maybe Int
  -> Double
  -> Double
  -> IO (WolframProcessSnapshot, Double, Bool)
waitForWolframLicenseSlotWith snapshotAction cachedMaximum timeoutSeconds pollSeconds = do
  started <- getCurrentTime
  firstSnapshot <- snapshotAction
  case cachedMaximum of
    Nothing -> pure (firstSnapshot, 0, True)
    Just maximumProcesses
      | activeWolframProcessCount firstSnapshot < maximumProcesses -> pure (firstSnapshot, 0, True)
      | otherwise -> poll started maximumProcesses firstSnapshot
 where
  poll started maximumProcesses snapshot = do
    waited <- elapsedSince started
    if waited >= timeoutSeconds
      then pure (snapshot, waited, False)
      else do
        threadDelay (secondsToMicroseconds pollSeconds)
        next <- snapshotAction
        if activeWolframProcessCount next < maximumProcesses
          then do
            finishedWait <- elapsedSince started
            pure (next, finishedWait, True)
          else poll started maximumProcesses next

cacheRoot :: IO FilePath
cacheRoot = do
  localAppData <- lookupEnv "LOCALAPPDATA"
  case localAppData of
    Just path | not (null path) -> pure (path </> "Tungsten")
    _ -> (</> "Tungsten") <$> getTemporaryDirectory

cachePath :: IO FilePath
cachePath = (</> "wolfram-license-cache.json") <$> cacheRoot

findPowerShell :: IO (Maybe FilePath)
findPowerShell = findExecutable "pwsh" >>= \case
  Just path -> pure (Just path)
  Nothing -> findExecutable "powershell"

powershellArguments :: [String]
powershellArguments =
  [ "-NoLogo", "-NoProfile", "-Command"
  , "$all = Get-CimInstance Win32_Process | Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine, @{Name='StartedUtc';Expression={if ($_.CreationDate) {[System.Management.ManagementDateTimeConverter]::ToDateTime($_.CreationDate).ToUniversalTime().ToString('o')} else {$null}}}; $all | ConvertTo-Json -Compress -Depth 3"
  ]

decodeProcessRows :: Text -> [WolframProcessInfo]
decodeProcessRows source = case parseJson (T.strip source) of
  Right (JsonArray rows) -> buildRows rows
  Right row@JsonObject {} -> buildRows [row]
  _ -> []
 where
  buildRows rows =
    let livePids = [pid | JsonObject row <- rows, Just pid <- [integerField "ProcessId" row]]
     in catMaybes (map (decodeProcess livePids) rows)

decodeProcess :: [Int] -> JsonValue -> Maybe WolframProcessInfo
decodeProcess livePids (JsonObject row) = do
  pid <- integerField "ProcessId" row
  name <- stringField "Name" row
  let executablePath = T.unpack <$> optionalStringField "ExecutablePath" row
      commandLine = optionalStringField "CommandLine" row
      lowerCommand = T.toLower (maybe "" id commandLine)
      parentPid = maybe 0 id (integerField "ParentProcessId" row)
      isWolfram = T.toLower name `elem` wolframNames || maybe False (T.isInfixOf "wolfram" . T.toLower . T.pack) executablePath
  if not isWolfram
    then Nothing
    else
      Just
        WolframProcessInfo
          { wolframProcessPid = pid
          , wolframProcessParentPid = parentPid
          , wolframProcessName = name
          , wolframProcessExecutablePath = executablePath
          , wolframProcessCommandLine = commandLine
          , wolframProcessStartedUtc = optionalStringField "StartedUtc" row
          , wolframProcessTungstenOwned = any (`T.isInfixOf` lowerCommand) ["tungsten-wrapper-", "tungsten-mathpass-"]
          , wolframProcessHeadlessBatch = any (`T.isInfixOf` lowerCommand) [" -script ", " -run ", " -runfile "]
          , wolframProcessParentMissing = parentPid > 0 && parentPid `notElem` livePids
          , wolframProcessControllingCandidate = isControllingProcessCandidate name lowerCommand
          }
decodeProcess _ _ = Nothing

integerField :: Text -> Map.Map Text JsonValue -> Maybe Int
integerField key payload = case Map.lookup key payload of
  Just (JsonNumber value) -> readMaybe (T.unpack value)
  _ -> Nothing

stringField :: Text -> Map.Map Text JsonValue -> Maybe Text
stringField key payload = case Map.lookup key payload of
  Just (JsonString value) -> Just value
  _ -> Nothing

optionalStringField :: Text -> Map.Map Text JsonValue -> Maybe Text
optionalStringField = stringField

terminateProcessTree :: Int -> IO (Maybe Int)
terminateProcessTree pid
  | os /= "mingw32" = pure Nothing
  | otherwise = do
      completed <- try (readProcessWithExitCode "taskkill" ["/PID", show pid, "/T", "/F"] "")
      pure $ case (completed :: Either IOException (ExitCode, String, String)) of
        Right (ExitSuccess, _, _) -> Just pid
        _ -> Nothing

elapsedSince :: UTCTime -> IO Double
elapsedSince started = do
  now <- getCurrentTime
  pure (realToFrac (diffUTCTime now started))

secondsToMicroseconds :: Double -> Int
secondsToMicroseconds seconds = max 0 (floor (seconds * 1000000))

wolframNames :: [Text]
wolframNames =
  [ "mathkernel", "mathkernel.exe", "mathematica", "mathematica.exe"
  , "wolfram", "wolfram.exe", "wolframdesktop", "wolframdesktop.exe"
  , "wolframkernel", "wolframkernel.exe"
  ]

jsonInteger :: Integer -> JsonValue
jsonInteger = JsonNumber . T.pack . show

jsonDouble :: Double -> JsonValue
jsonDouble = JsonNumber . T.pack . show
