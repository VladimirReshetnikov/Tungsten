{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Notebook Assistant response extraction and free-form Chatbook requests.
module Tungsten.Assistant
  ( AssistantCodeBlock (..)
  , NotebookAssistantResult (..)
  , assistantSuccess
  , assistantResultPayload
  , parseAssistantPayload
  , finalizeAssistantAskPayload
  , extractAssistantText
  , extractAssistantCodeBlocks
  , assistantCodeBlockPayload
  , buildAssistantAskScript
  , askAssistant
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Discovery (WolframInstallation)
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.WolframString (parseWolframStringLiteral, wlString)

data AssistantCodeBlock = AssistantCodeBlock
  { assistantCodeBlockIndex :: !Int
  , assistantCodeBlockLanguage :: !Text
  , assistantCodeBlockCode :: !Text
  , assistantCodeBlockInsertable :: !Bool
  }
  deriving (Eq, Show)

data NotebookAssistantResult = NotebookAssistantResult
  { assistantEvaluation :: !KernelEvaluationResult
  , assistantPayload :: !JsonValue
  }
  deriving (Eq, Show)

assistantSuccess :: NotebookAssistantResult -> Bool
assistantSuccess result = payloadSuccess (assistantPayload result)

assistantResultPayload :: NotebookAssistantResult -> JsonValue
assistantResultPayload result =
  JsonObject
    ( Map.fromList
        [ ("assistant", assistantPayload result)
        , ("assistant_success", JsonBool (assistantSuccess result))
        , ("evaluation", kernelEvaluationPayload (assistantEvaluation result))
        ]
    )

parseAssistantPayload :: KernelEvaluationResult -> JsonValue
parseAssistantPayload evaluation
  | not (kernelEvaluationAvailable evaluation) =
      errorPayload
        "EvaluationUnavailable"
        ( nonemptyOr
            "The Wolfram evaluation did not produce a structured payload."
            (kernelStderr evaluation)
        )
  | kernelSuccess evaluation == Just False =
      errorPayload
        (maybe "KernelEvaluationFailure" id (kernelFailureType evaluation))
        ( nonemptyOr
            (maybe "The Wolfram evaluation failed." id (kernelResult evaluation))
            (kernelStderr evaluation)
        )
  | otherwise = case kernelResult evaluation of
      Nothing -> missingPayload
      Just "" -> missingPayload
      Just rawResult ->
        let payloadText = parseWolframStringLiteral rawResult
         in case parseJson payloadText of
              Left jsonError ->
                JsonObject
                  ( Map.fromList
                      [ ("error", JsonString ("Unable to parse assistant payload JSON: " <> jsonErrorMessage jsonError))
                      , ("error_type", JsonString "InvalidAssistantPayload")
                      , ("raw_result", JsonString rawResult)
                      , ("success", JsonBool False)
                      ]
                  )
              Right payload@JsonObject {} -> payload
              Right payload ->
                JsonObject
                  ( Map.fromList
                      [ ("error", JsonString "The assistant payload was not a JSON object.")
                      , ("error_type", JsonString "InvalidAssistantPayload")
                      , ("raw_payload", payload)
                      , ("success", JsonBool False)
                      ]
                  )
 where
  missingPayload =
    errorPayload
      "MissingAssistantPayload"
      "The Wolfram evaluation completed but did not return an assistant payload."

finalizeAssistantAskPayload :: JsonValue -> JsonValue
finalizeAssistantAskPayload original@(JsonObject payload)
  | not (payloadSuccess original) = original
  | otherwise = case Map.lookup "assistant_chat_object_string" payload of
      Just (JsonString chatObject) | not (T.null chatObject) ->
        let response = extractAssistantText chatObject
         in if T.null response
              then
                JsonObject
                  ( Map.fromList
                      [ ("assistant_chat_object_string", JsonString chatObject)
                      , ("error", JsonString "Notebook Assistant completed, but Tungsten could not extract an assistant text response.")
                      , ("error_type", JsonString "AssistantResponseUnavailable")
                      , ("success", JsonBool False)
                      ]
                  )
              else
                let codeBlocks = extractAssistantCodeBlocks response
                    wolframBlocks = filter assistantCodeBlockInsertable codeBlocks
                 in JsonObject
                      ( Map.insert "response_text" (JsonString response)
                          ( Map.insert "code_blocks" (JsonArray (map assistantCodeBlockPayload codeBlocks))
                              ( Map.insert "wolfram_code_blocks" (JsonArray (map assistantCodeBlockPayload wolframBlocks))
                                  (Map.delete "assistant_chat_object_string" payload)
                              )
                          )
                      )
      _ ->
        errorPayload
          "AssistantResponseUnavailable"
          "Notebook Assistant did not return a chat object string that Tungsten could inspect."
finalizeAssistantAskPayload payload = payload

extractAssistantText :: Text -> Text
extractAssistantText chatObject = case assistantSections of
  [] -> ""
  sections -> T.intercalate "\n\n" (filter (not . T.null) (textChunks (last sections)))
 where
  roleSections = drop 1 (T.splitOn "\"Role\"" chatObject)
  assistantSections =
    filter
      (\section -> beforeMarker "\"Content\"" section `containsQuotedValue` "Assistant")
      roleSections
  textChunks section =
    [ decodeChatString raw
    | typed <- drop 1 (T.splitOn "\"Type\"" (beforeMarker "\"Metadata\"" section))
    , beforeMarker "\"Data\"" typed `containsQuotedValue` "Text"
    , Just dataSection <- [afterMarker "\"Data\"" typed]
    , Just raw <- [quotedValue dataSection]
    ]

extractAssistantCodeBlocks :: Text -> [AssistantCodeBlock]
extractAssistantCodeBlocks = go 0
 where
  go index source = case afterMarker "```" source of
    Nothing -> []
    Just fenced -> case T.breakOn "\n" fenced of
      (_, rest) | T.null rest -> []
      (languageSource, rest) ->
        let codeSource = T.drop 1 rest
            (code, suffix) = T.breakOn "```" codeSource
         in if T.null suffix
              then []
              else
                let language = T.strip languageSource
                    displayLanguage = if T.null language then "Unknown" else language
                    normalized = T.toLower (T.unwords (T.words language))
                    insertable = normalized `elem` wolframLanguages
                    block = AssistantCodeBlock index displayLanguage (T.strip code) insertable
                 in block : go (index + 1) (T.drop 3 suffix)
  wolframLanguages = ["wolfram", "wolfram language", "wolframlanguage", "mathematica", "wl"]

assistantCodeBlockPayload :: AssistantCodeBlock -> JsonValue
assistantCodeBlockPayload block =
  JsonObject
    ( Map.fromList
        [ ("code", JsonString (assistantCodeBlockCode block))
        , ("index", JsonNumber (T.pack (show (assistantCodeBlockIndex block))))
        , ("insertable", JsonBool (assistantCodeBlockInsertable block))
        , ("language", JsonString (assistantCodeBlockLanguage block))
        ]
    )

buildAssistantAskScript
  :: Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe [Text]
  -> Text
buildAssistantAskScript prompt systemPrompt extraInstructions modelService modelName requestedTools =
  T.unlines
    [ "Needs[\"Wolfram`Chatbook`\" -> None];"
    , "tungstenSettings = ImportString[" <> wlString settingsJson <> ", \"RawJSON\"];"
    , "tungstenPrompt = " <> wlString prompt <> ";"
    , "tungstenSystemPrompt = " <> wlString (maybe "" T.strip systemPrompt) <> ";"
    , "tungstenExtraInstructions = " <> wlString (maybe "" T.strip extraInstructions) <> ";"
    , "tungstenChatCellEvaluate = Symbol[\"Wolfram`Chatbook`ChatCellEvaluate\"];"
    , "ClearAll[tungstenError, tungstenChatSettings];"
    , "tungstenError[type_String, message_String, extra_: <||>] := Join[<|\"success\" -> False, \"error_type\" -> type, \"error\" -> message|>, extra];"
    , "tungstenChatSettings[nbo_NotebookObject] := Quiet @ Check[CurrentValue[nbo, {TaggingRules, \"ChatNotebookSettings\"}] = tungstenSettings, Null];"
    , "tungstenResult = Module[{assistantNotebook, chatCell, chatObject, chatRaw, combinedPrompt},"
    , "  combinedPrompt = Which[tungstenSystemPrompt =!= \"\" && tungstenExtraInstructions =!= \"\", tungstenSystemPrompt <> \"\\n\\n\" <> tungstenPrompt <> \"\\n\\n\" <> tungstenExtraInstructions, tungstenSystemPrompt =!= \"\", tungstenSystemPrompt <> \"\\n\\n\" <> tungstenPrompt, tungstenExtraInstructions =!= \"\", tungstenPrompt <> \"\\n\\n\" <> tungstenExtraInstructions, True, tungstenPrompt];"
    , "  assistantNotebook = Quiet @ Check[CreateDocument[Notebook[{Cell[\"Tungsten Assistant Ask Session\", \"Section\"]}], Visible -> False], $Failed];"
    , "  If[! MatchQ[assistantNotebook, _NotebookObject], tungstenError[\"AssistantNotebookCreateFailed\", \"Tungsten could not create the temporary Notebook Assistant notebook.\"],"
    , "    tungstenChatSettings @ assistantNotebook;"
    , "    SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];"
    , "    NotebookWrite[assistantNotebook, Cell[combinedPrompt, \"ChatInput\"]];"
    , "    chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];"
    , "    chatObject = Quiet @ Check[If[MatchQ[chatCell, _CellObject], tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed], $Failed];"
    , "    chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];"
    , "    Quiet @ Check[NotebookClose @ assistantNotebook, Null];"
    , "    <|\"success\" -> True, \"prompt\" -> tungstenPrompt, \"assistant_chat_object_string\" -> chatRaw|>"
    , "  ]"
    , "];"
    , "ExportString[tungstenResult, \"RawJSON\"]"
    ]
 where
  tools = maybe defaultTools id requestedTools
  defaultTools = ["WolframLanguageEvaluator", "DocumentationSearcher", "WolframAlpha"]
  baseSettings =
    Map.fromList
      [ ("AutoSaveConversations", JsonBool False)
      , ("Tools", JsonArray (map JsonString tools))
      ]
  settings = case (modelService, modelName) of
    (Nothing, Nothing) -> baseSettings
    _ ->
      Map.insert
        "Model"
        ( JsonObject
            ( Map.fromList
                [ ("Name", JsonString (maybe "Automatic" id modelName))
                , ("Service", JsonString (maybe "Automatic" id modelService))
                ]
            )
        )
        baseSettings
  settingsJson = encodeJson (JsonObject settings)

askAssistant
  :: WolframInstallation
  -> Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe [Text]
  -> IO NotebookAssistantResult
askAssistant installation prompt systemPrompt extraInstructions modelService modelName tools = do
  evaluation <-
    evaluateKernelText
      installation
      (buildAssistantAskScript prompt systemPrompt extraInstructions modelService modelName tools)
      Nothing
      True
  pure
    NotebookAssistantResult
      { assistantEvaluation = evaluation
      , assistantPayload = finalizeAssistantAskPayload (parseAssistantPayload evaluation)
      }

payloadSuccess :: JsonValue -> Bool
payloadSuccess (JsonObject payload) = Map.lookup "success" payload == Just (JsonBool True)
payloadSuccess _ = False

errorPayload :: Text -> Text -> JsonValue
errorPayload errorType message =
  JsonObject
    ( Map.fromList
        [ ("error", JsonString message)
        , ("error_type", JsonString errorType)
        , ("success", JsonBool False)
        ]
    )

nonemptyOr :: Text -> Text -> Text
nonemptyOr fallback value = if T.null value then fallback else value

beforeMarker :: Text -> Text -> Text
beforeMarker marker = fst . T.breakOn marker

afterMarker :: Text -> Text -> Maybe Text
afterMarker marker source =
  let (_, suffix) = T.breakOn marker source
   in if T.null suffix then Nothing else Just (T.drop (T.length marker) suffix)

containsQuotedValue :: Text -> Text -> Bool
containsQuotedValue source value = ("\"" <> value <> "\"") `T.isInfixOf` source

quotedValue :: Text -> Maybe Text
quotedValue source = do
  afterArrow <- afterMarker "->" source
  (_, quoted) <- T.uncons (T.dropWhile (/= '"') afterArrow)
  pure (scan False [] quoted)
 where
  scan _ output text | T.null text = T.concat (reverse output)
  scan escaped output text =
    let character = T.head text
        rest = T.tail text
     in if character == '"' && not escaped
          then T.concat (reverse output)
          else
            let nextEscaped = character == '\\' && not escaped
             in scan nextEscaped (T.singleton character : output) rest

decodeChatString :: Text -> Text
decodeChatString raw =
  let once = parseWolframStringLiteral ("\"" <> raw <> "\"")
   in if any (`T.isInfixOf` once) ["\\n", "\\t", "\\\"", "\\\\"]
        then parseWolframStringLiteral ("\"" <> once <> "\"")
        else once
