{-# LANGUAGE OverloadedStrings #-}

-- | Structured execution through a discovered local Wolfram kernel.
module Tungsten.Kernel
  ( KernelEvaluationResult (..)
  , evaluateKernelText
  , evaluateKernelFile
  , buildWrapperScript
  , kernelEvaluationPayload
  ) where

import Control.Exception (IOException, bracket, try)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Directory
  ( doesFileExist
  , getCurrentDirectory
  , getTemporaryDirectory
  , makeAbsolute
  , removeFile
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (hClose, hSetEncoding, openTempFile, utf8)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Text.Read (readMaybe)
import Tungsten.Discovery
import Tungsten.Expression (Expr (String), fullForm)
import Tungsten.Json
import Tungsten.Licensing

data KernelEvaluationResult = KernelEvaluationResult
  { kernelCommand :: ![Text]
  , kernelExitCode :: !Int
  , kernelSuccess :: !(Maybe Bool)
  , kernelFailureType :: !(Maybe Text)
  , kernelResult :: !(Maybe Text)
  , kernelResultHead :: !(Maybe Text)
  , kernelMessages :: ![Text]
  , kernelMessagesText :: ![Text]
  , kernelOutput :: ![Text]
  , kernelTiming :: !(Maybe Double)
  , kernelAbsoluteTiming :: !(Maybe Double)
  , kernelStdout :: !Text
  , kernelStderr :: !Text
  , kernelJsonPath :: !(Maybe FilePath)
  , kernelEvaluationAvailable :: !Bool
  , kernelMathpass :: !MathpassInspection
  , kernelUsedMathpassWorkaround :: !Bool
  , kernelLicenseProcesses :: !(Maybe Int)
  , kernelMaxLicenseProcesses :: !(Maybe Int)
  , kernelElapsedSeconds :: !Double
  }
  deriving (Eq, Show)

evaluateKernelText
  :: WolframInstallation
  -> Text
  -> Maybe FilePath
  -> Bool
  -> IO KernelEvaluationResult
evaluateKernelText installation code workingDirectory requireFrontEnd =
  withTextTempFile "tungsten-input.wl" code $ \codePath ->
    evaluateKernelFile installation codePath workingDirectory requireFrontEnd

evaluateKernelFile
  :: WolframInstallation
  -> FilePath
  -> Maybe FilePath
  -> Bool
  -> IO KernelEvaluationResult
evaluateKernelFile installation codePath requestedWorkingDirectory requireFrontEnd = do
  inspection <- inspectMathpass (installationMathpass installation)
  case installationKernelCli installation of
    Nothing -> pure (kernelUnavailable inspection)
    Just kernelPath -> do
      kernelExists <- doesFileExist kernelPath
      if not kernelExists
        then pure (kernelUnavailable inspection)
        else do
          workingDirectory <- maybe getCurrentDirectory makeAbsolute requestedWorkingDirectory
          absoluteCodePath <- makeAbsolute codePath
          withUnusedTempPath "tungsten-result.json" $ \resultPath ->
            withTextTempFile
              "tungsten-wrapper.wl"
              (buildWrapperScript absoluteCodePath resultPath workingDirectory requireFrontEnd)
              $ \wrapperPath ->
                withMathpass (installationMathpass installation) $ \mathpassPath usedMathpass mathpassInspection ->
                  runKernel
                    kernelPath
                    wrapperPath
                    resultPath
                    workingDirectory
                    mathpassPath
                    usedMathpass
                    mathpassInspection

runKernel
  :: FilePath
  -> FilePath
  -> FilePath
  -> FilePath
  -> Maybe FilePath
  -> Bool
  -> MathpassInspection
  -> IO KernelEvaluationResult
runKernel kernelPath wrapperPath resultPath workingDirectory mathpassPath usedMathpass inspection = do
  environment <- getEnvironment
  let arguments =
        ["-noprompt"]
          <> maybe [] (\path -> ["-pwfile", path]) mathpassPath
          <> ["-script", wrapperPath]
      command = map T.pack (kernelPath : arguments)
      process =
        (proc kernelPath arguments)
          { cwd = Just workingDirectory
          , env = Just (("TUNGSTEN_KERNEL_RESULT_PATH", resultPath) : environment)
          }
  started <- getCurrentTime
  completed <- try (readCreateProcessWithExitCode process "")
  finished <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime finished started)
  case (completed :: Either IOException (ExitCode, String, String)) of
    Left exception ->
      pure
        ( (emptyKernelResult inspection)
            { kernelCommand = command
            , kernelExitCode = 126
            , kernelFailureType = Just "LaunchFailure"
            , kernelStderr = T.pack (show exception)
            , kernelUsedMathpassWorkaround = usedMathpass
            , kernelElapsedSeconds = elapsed
            }
        )
    Right (exitCode, stdoutText, stderrText) -> do
      resultExists <- doesFileExist resultPath
      payload <- if resultExists
        then first jsonErrorMessage . parseJson <$> TextIO.readFile resultPath
        else pure (Left "the Wolfram kernel did not write a result payload")
      pure
        ( resultFromPayload
            command
            (exitCodeValue exitCode)
            (T.pack stdoutText)
            (T.pack stderrText)
            (if resultExists then Just resultPath else Nothing)
            usedMathpass
            inspection
            elapsed
            payload
        )

resultFromPayload
  :: [Text]
  -> Int
  -> Text
  -> Text
  -> Maybe FilePath
  -> Bool
  -> MathpassInspection
  -> Double
  -> Either Text JsonValue
  -> KernelEvaluationResult
resultFromPayload command exitCode stdoutText stderrText jsonPath usedMathpass inspection elapsed payload =
  case payload of
    Left message ->
      (emptyKernelResult inspection)
        { kernelCommand = command
        , kernelExitCode = exitCode
        , kernelFailureType = Just "ResultUnavailable"
        , kernelStdout = stdoutText
        , kernelStderr = if T.null stderrText then message else stderrText <> "\n" <> message
        , kernelJsonPath = jsonPath
        , kernelUsedMathpassWorkaround = usedMathpass
        , kernelElapsedSeconds = elapsed
        }
    Right (JsonObject values) ->
      (emptyKernelResult inspection)
        { kernelCommand = command
        , kernelExitCode = exitCode
        , kernelSuccess = optionalBool "success" values
        , kernelFailureType = optionalString "failure_type" values
        , kernelResult = optionalString "result" values
        , kernelResultHead = optionalString "result_head" values
        , kernelMessages = stringList "messages" values
        , kernelMessagesText = stringList "messages_text" values
        , kernelOutput = stringList "output" values
        , kernelTiming = optionalDouble "timing" values
        , kernelAbsoluteTiming = optionalDouble "absolute_timing" values
        , kernelStdout = stdoutText
        , kernelStderr = stderrText
        , kernelJsonPath = jsonPath
        , kernelEvaluationAvailable = True
        , kernelUsedMathpassWorkaround = usedMathpass
        , kernelLicenseProcesses = optionalInt "license_processes" values
        , kernelMaxLicenseProcesses = optionalInt "max_license_processes" values
        , kernelElapsedSeconds = elapsed
        }
    Right _ ->
      resultFromPayload command exitCode stdoutText stderrText jsonPath usedMathpass inspection elapsed (Left "the kernel result payload is not a JSON object")

kernelUnavailable :: MathpassInspection -> KernelEvaluationResult
kernelUnavailable inspection =
  (emptyKernelResult inspection)
    { kernelExitCode = 127
    , kernelFailureType = Just "KernelNotFound"
    , kernelStderr = "No local Wolfram kernel installation was discovered."
    }

emptyKernelResult :: MathpassInspection -> KernelEvaluationResult
emptyKernelResult inspection =
  KernelEvaluationResult
    { kernelCommand = []
    , kernelExitCode = 0
    , kernelSuccess = Nothing
    , kernelFailureType = Nothing
    , kernelResult = Nothing
    , kernelResultHead = Nothing
    , kernelMessages = []
    , kernelMessagesText = []
    , kernelOutput = []
    , kernelTiming = Nothing
    , kernelAbsoluteTiming = Nothing
    , kernelStdout = ""
    , kernelStderr = ""
    , kernelJsonPath = Nothing
    , kernelEvaluationAvailable = False
    , kernelMathpass = inspection
    , kernelUsedMathpassWorkaround = False
    , kernelLicenseProcesses = Nothing
    , kernelMaxLicenseProcesses = Nothing
    , kernelElapsedSeconds = 0
    }

buildWrapperScript :: FilePath -> FilePath -> FilePath -> Bool -> Text
buildWrapperScript codePath resultPath workingDirectory requireFrontEnd =
  T.unlines
    [ "$HistoryLength = 0;"
    , "SetDirectory[" <> pathLiteral workingDirectory <> "];"
    , "userCode = Import[" <> pathLiteral codePath <> ", \"Text\"];"
    , "output = {};"
    , "ClearAll[Tungsten`Private`CapturedPrint, Tungsten`Private`Stringify, Tungsten`Private`StringList];"
    , "Tungsten`Private`CapturedPrint[args___] := AppendTo[output, ToString[SequenceForm[args], OutputForm, PageWidth -> Infinity]];"
    , "Tungsten`Private`Stringify[value_] := Quiet @ Check[ToString[Unevaluated[value], InputForm, PageWidth -> Infinity], \"$Failed\"];"
    , "Tungsten`Private`StringList[value_] := If[ListQ[value], Map[Tungsten`Private`Stringify, value], {}];"
    , "heldExpr = Quiet @ Check[ToExpression[userCode, InputForm, HoldComplete], $Failed];"
    , "If[heldExpr === $Failed, Export[" <> pathLiteral resultPath <> ", <|\"success\" -> False, \"failure_type\" -> \"ParseFailure\", \"result\" -> \"$Failed\", \"result_head\" -> \"$Failed\", \"messages\" -> {}, \"messages_text\" -> {}, \"output\" -> output, \"timing\" -> Null, \"absolute_timing\" -> Null|>, \"RawJSON\"]; Exit[2]];"
    , "heldExpr = Replace[heldExpr, HoldComplete[exprs__] :> HoldComplete[CompoundExpression[exprs]]];"
    , "evalExpr = If[" <> booleanLiteral requireFrontEnd <> ", HoldComplete[UsingFrontEnd[ReleaseHold[heldExpr]]], heldExpr];"
    , "ed = Block[{Print = Tungsten`Private`CapturedPrint}, EvaluationData[ReleaseHold[evalExpr]]];"
    , "result = Lookup[ed, \"Result\", $Failed];"
    , "payload = <|\"success\" -> TrueQ[Lookup[ed, \"Success\", False]], \"failure_type\" -> Replace[Lookup[ed, \"FailureType\", None], {None -> Null, value_ :> Tungsten`Private`Stringify[value]}], \"result\" -> Tungsten`Private`Stringify[result], \"result_head\" -> Tungsten`Private`Stringify[Head[result]], \"license_processes\" -> Quiet @ Check[$LicenseProcesses, Null], \"max_license_processes\" -> Quiet @ Check[$MaxLicenseProcesses, Null], \"messages\" -> Tungsten`Private`StringList[Lookup[ed, \"Messages\", {}]], \"messages_text\" -> Tungsten`Private`StringList[Lookup[ed, \"MessagesText\", {}]], \"output\" -> output, \"timing\" -> Replace[Lookup[ed, \"Timing\", Missing[\"NotAvailable\"]], Missing[__] -> Null], \"absolute_timing\" -> Replace[Lookup[ed, \"AbsoluteTiming\", Missing[\"NotAvailable\"]], Missing[__] -> Null]|>;"
    , "Export[" <> pathLiteral resultPath <> ", payload, \"RawJSON\"];"
    , "Exit[0];"
    ]

kernelEvaluationPayload :: KernelEvaluationResult -> JsonValue
kernelEvaluationPayload result =
  JsonObject
    ( Map.fromList
        [ ("absolute_timing", maybe JsonNull jsonDouble (kernelAbsoluteTiming result))
        , ("cached_max_license_processes", JsonNull)
        , ("cleaned_tungsten_processes", JsonArray [])
        , ("command", JsonArray (map JsonString (kernelCommand result)))
        , ("elapsed_seconds", jsonDouble (kernelElapsedSeconds result))
        , ("evaluation_available", JsonBool (kernelEvaluationAvailable result))
        , ("exit_code", jsonInteger (fromIntegral (kernelExitCode result)))
        , ("failure_type", maybe JsonNull JsonString (kernelFailureType result))
        , ("json_path", maybe JsonNull (JsonString . T.pack) (kernelJsonPath result))
        , ("launch_gate_wait_seconds", JsonNumber "0")
        , ("license_processes", maybe JsonNull (jsonInteger . fromIntegral) (kernelLicenseProcesses result))
        , ("license_wait_satisfied", JsonNull)
        , ("license_wait_seconds", JsonNumber "0")
        , ("mathpass", mathpassPayload (kernelMathpass result))
        , ("max_license_processes", maybe JsonNull (jsonInteger . fromIntegral) (kernelMaxLicenseProcesses result))
        , ("messages", JsonArray (map JsonString (kernelMessages result)))
        , ("messages_text", JsonArray (map JsonString (kernelMessagesText result)))
        , ("observed_wolfram_processes", JsonArray [])
        , ("output", JsonArray (map JsonString (kernelOutput result)))
        , ("result", maybe JsonNull JsonString (kernelResult result))
        , ("result_head", maybe JsonNull JsonString (kernelResultHead result))
        , ("stderr", JsonString (kernelStderr result))
        , ("stdout", JsonString (kernelStdout result))
        , ("success", maybe JsonNull JsonBool (kernelSuccess result))
        , ("timing", maybe JsonNull jsonDouble (kernelTiming result))
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
        , ("path", maybe JsonNull (JsonString . T.pack) (mathpassPath inspection))
        , ("unique_entry_count", jsonInteger (fromIntegral (mathpassUniqueEntryCount inspection)))
        ]
    )

jsonInteger :: Integer -> JsonValue
jsonInteger = JsonNumber . T.pack . show

jsonDouble :: Double -> JsonValue
jsonDouble = JsonNumber . T.pack . show

withMathpass
  :: Maybe FilePath
  -> (Maybe FilePath -> Bool -> MathpassInspection -> IO value)
  -> IO value
withMathpass Nothing action = action Nothing False emptyMathpassInspection
withMathpass (Just source) action = do
  exists <- doesFileExist source
  if not exists
    then action Nothing False emptyMathpassInspection
    else
      withUnusedTempPath "tungsten-mathpass.txt" $ \destination -> do
        inspection <- writeDeduplicatedMathpass source destination
        action (Just destination) True inspection

withTextTempFile :: FilePath -> Text -> (FilePath -> IO value) -> IO value
withTextTempFile template contents action =
  bracket create removeIfPresent action
 where
  create = do
    directory <- getTemporaryDirectory
    (path, handle) <- openTempFile directory template
    hSetEncoding handle utf8
    TextIO.hPutStr handle contents
    hClose handle
    pure path

withUnusedTempPath :: FilePath -> (FilePath -> IO value) -> IO value
withUnusedTempPath template action = bracket create removeIfPresent action
 where
  create = do
    directory <- getTemporaryDirectory
    (path, handle) <- openTempFile directory template
    hClose handle
    removeFile path
    pure path

removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()

pathLiteral :: FilePath -> Text
pathLiteral path = fullForm (String (T.pack (map slash path)))
 where
  slash '\\' = '/'
  slash character = character

booleanLiteral :: Bool -> Text
booleanLiteral True = "True"
booleanLiteral False = "False"

exitCodeValue :: ExitCode -> Int
exitCodeValue ExitSuccess = 0
exitCodeValue (ExitFailure value) = value

optionalBool :: Text -> Map.Map Text JsonValue -> Maybe Bool
optionalBool key values = case Map.lookup key values of
  Just (JsonBool value) -> Just value
  _ -> Nothing

optionalString :: Text -> Map.Map Text JsonValue -> Maybe Text
optionalString key values = case Map.lookup key values of
  Just (JsonString value) -> Just value
  _ -> Nothing

stringList :: Text -> Map.Map Text JsonValue -> [Text]
stringList key values = case Map.lookup key values of
  Just (JsonArray items) -> [value | JsonString value <- items]
  _ -> []

optionalDouble :: Text -> Map.Map Text JsonValue -> Maybe Double
optionalDouble key values = case Map.lookup key values of
  Just (JsonNumber source) -> readMaybe (T.unpack source)
  _ -> Nothing

optionalInt :: Text -> Map.Map Text JsonValue -> Maybe Int
optionalInt key values = case Map.lookup key values of
  Just (JsonNumber source) -> readMaybe (T.unpack source)
  _ -> Nothing
