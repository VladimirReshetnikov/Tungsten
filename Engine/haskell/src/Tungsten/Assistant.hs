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
  , finalizeAssistantAskCellPayload
  , finalizeAssistantAskCellPayloadWithInsertion
  , extractAssistantText
  , extractAssistantCodeBlocks
  , assistantCodeBlockPayload
  , buildAssistantAskScript
  , buildAssistantAskCellScript
  , buildAssistantInsertScript
  , askAssistant
  , askAssistantCell
  , askAssistantCellWithOptions
  ) where

import Control.Exception (IOException, try)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import System.Directory (makeAbsolute)
import Tungsten.Discovery (WolframInstallation)
import Tungsten.InlineBoxes
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.Notebook
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

finalizeAssistantAskCellPayload :: JsonValue -> JsonValue
finalizeAssistantAskCellPayload payload =
  finalizeAssistantAskCellPayloadWithInsertion payload "none" Nothing

finalizeAssistantAskCellPayloadWithInsertion :: JsonValue -> Text -> Maybe JsonValue -> JsonValue
finalizeAssistantAskCellPayloadWithInsertion original@(JsonObject payload) insertMode insertionPayload
  | not (payloadSuccess original) = original
  | otherwise = case Map.lookup "assistant_chat_object_string" payload of
      Just (JsonString chatObject) | not (T.null chatObject) ->
        let response = extractAssistantText chatObject
            sourceCell = maybe JsonNull id (Map.lookup "source_cell" payload)
         in if T.null response
              then
                JsonObject
                  ( Map.fromList
                      [ ("assistant_chat_object_string", JsonString chatObject)
                      , ("error", JsonString "Notebook Assistant completed, but Tungsten could not extract an assistant text response.")
                      , ("error_type", JsonString "AssistantResponseUnavailable")
                      , ("source_cell", sourceCell)
                      , ("success", JsonBool False)
                      ]
                  )
              else
                let codeBlocks = extractAssistantCodeBlocks response
                    wolframBlocks = filter assistantCodeBlockInsertable codeBlocks
                    insertion = maybe emptyInsertion id insertionPayload
                 in if not (payloadSuccess insertion)
                      then insertionFailure payload response codeBlocks wolframBlocks insertion
                      else
                        JsonObject
                          ( Map.insert "response_text" (JsonString response)
                              ( Map.insert "code_blocks" (JsonArray (map assistantCodeBlockPayload codeBlocks))
                                  ( Map.insert "wolfram_code_blocks" (JsonArray (map assistantCodeBlockPayload wolframBlocks))
                                      ( Map.insert "insert_mode" (JsonString insertMode)
                                          ( Map.insert "inserted" (payloadField "inserted" (JsonArray []) insertion)
                                              ( Map.insert "saved_notebook" (payloadField "saved_notebook" (JsonBool False) insertion)
                                                  (Map.delete "assistant_chat_object_string" payload)
                                              )
                                          )
                                      )
                                  )
                              )
                          )
      _ ->
        JsonObject
          ( Map.fromList
              [ ("error", JsonString "Notebook Assistant did not return a chat object string that Tungsten could inspect.")
              , ("error_type", JsonString "AssistantResponseUnavailable")
              , ("source_cell", maybe JsonNull id (Map.lookup "source_cell" payload))
              , ("success", JsonBool False)
              ]
          )
 where
  emptyInsertion =
    JsonObject
      ( Map.fromList
          [ ("inserted", JsonArray [])
          , ("saved_notebook", JsonBool False)
          , ("success", JsonBool True)
          ]
      )
finalizeAssistantAskCellPayloadWithInsertion payload _ _ = payload

insertionFailure
  :: Map.Map Text JsonValue
  -> Text
  -> [AssistantCodeBlock]
  -> [AssistantCodeBlock]
  -> JsonValue
  -> JsonValue
insertionFailure original response codeBlocks wolframBlocks insertion =
  JsonObject
    ( Map.fromList
        [ ("code_blocks", JsonArray (map assistantCodeBlockPayload codeBlocks))
        , ("error", payloadField "error" (JsonString "Tungsten could not insert the generated Wolfram code.") insertion)
        , ("error_type", payloadField "error_type" (JsonString "InsertionFailure") insertion)
        , ("response_text", JsonString response)
        , ("source_cell", maybe JsonNull id (Map.lookup "source_cell" original))
        , ("success", JsonBool False)
        , ("wolfram_code_blocks", JsonArray (map assistantCodeBlockPayload wolframBlocks))
        ]
    )

payloadField :: Text -> JsonValue -> JsonValue -> JsonValue
payloadField key fallback (JsonObject payload) = maybe fallback id (Map.lookup key payload)
payloadField _ fallback _ = fallback

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

buildAssistantAskCellScript
  :: FilePath
  -> Text
  -> JsonValue
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> Text
buildAssistantAskCellScript notebookPath question selector extraInstructions modelService modelName =
  T.unlines
    [ "Needs[\"Wolfram`Chatbook`\" -> None];"
    , "tungstenSelector = ImportString[" <> wlString (encodeJson selector) <> ", \"RawJSON\"];"
    , "tungstenSettings = ImportString[" <> wlString settingsJson <> ", \"RawJSON\"];"
    , "tungstenQuestion = " <> wlString question <> ";"
    , "tungstenNotebookPath = " <> wlString (T.pack (map slash notebookPath)) <> ";"
    , "tungstenExtraInstructions = " <> wlString combinedInstructions <> ";"
    , "tungstenChatCellEvaluate = Symbol[\"Wolfram`Chatbook`ChatCellEvaluate\"];"
    , "tungstenCellToString = Symbol[\"Wolfram`Chatbook`CellToString\"];"
    , assistantHelperBlock "tungstenCellToString @ cellExpr" ["tungstenPromptCell", "tungstenChatSettings"]
    , "tungstenPromptCell[sourceCell_CellObject] := Module[{sourceExpr, sourceText, sourceStyle, styleText},"
    , "  sourceExpr = Quiet @ Check[NotebookRead @ sourceCell, $Failed];"
    , "  sourceText = Quiet @ Check[tungstenCellToString @ sourceExpr, ToString[sourceExpr, InputForm, PageWidth -> Infinity]];"
    , "  sourceStyle = tungstenStringValue @ CurrentValue[sourceCell, CellStyle];"
    , "  styleText = Replace[sourceStyle, {s_String :> s, _ :> \"Unknown\"}];"
    , "  Cell[StringJoin[tungstenQuestion, \"\\n\\nSource notebook cell style: \", styleText, \"\\n\\nSource notebook cell contents:\\n\", sourceText, \"\\n\\n\", tungstenExtraInstructions], \"ChatInput\"]"
    , "];"
    , "tungstenChatSettings[nbo_NotebookObject] := Quiet @ Check[CurrentValue[nbo, {TaggingRules, \"ChatNotebookSettings\"}] = tungstenSettings, Null];"
    , "tungstenResult = Module[{sourceNotebook, sourceCell, assistantNotebook, promptCell, chatCell, chatObject, chatRaw},"
    , "  sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;"
    , "  If[AssociationQ @ sourceNotebook, sourceNotebook,"
    , "    SetSelectedNotebook @ sourceNotebook;"
    , "    sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];"
    , "    If[AssociationQ @ sourceCell, sourceCell,"
    , "      assistantNotebook = Quiet @ Check[CreateDocument[Notebook[{Cell[\"Tungsten Notebook Assistant Session\", \"Section\"]}], Visible -> False], $Failed];"
    , "      If[! MatchQ[assistantNotebook, _NotebookObject], tungstenError[\"AssistantNotebookCreateFailed\", \"Tungsten could not create the temporary Notebook Assistant notebook.\"],"
    , "        tungstenChatSettings @ assistantNotebook;"
    , "        SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];"
    , "        NotebookWrite[assistantNotebook, Cell[\"You are answering a question about a specific cell from a Wolfram notebook.\\n\\nAnswer the user's question directly.\\n\\nIf you provide Wolfram Language code, place it in a Wolfram Language code block.\", \"Text\"]];"
    , "        SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];"
    , "        NotebookWrite[assistantNotebook, Cell[StringJoin[\"Source notebook path: \", tungstenNotebookPath], \"Text\"]];"
    , "        SelectionMove[assistantNotebook, After, Notebook, AutoScroll -> False];"
    , "        promptCell = tungstenPromptCell @ sourceCell; NotebookWrite[assistantNotebook, promptCell];"
    , "        chatCell = Quiet @ Check[Last[Cells[assistantNotebook]], $Failed];"
    , "        chatObject = Quiet @ Check[If[MatchQ[chatCell, _CellObject], tungstenChatCellEvaluate[chatCell, assistantNotebook], $Failed], $Failed];"
    , "        chatRaw = ToString[chatObject, InputForm, PageWidth -> Infinity];"
    , "        Quiet @ Check[NotebookClose @ assistantNotebook, Null];"
    , "        <|\"success\" -> True, \"notebook_path\" -> tungstenNotebookPath, \"question\" -> tungstenQuestion, \"selector\" -> tungstenSelector, \"source_cell\" -> tungstenCellMetadata @ sourceCell, \"assistant_notebook_mode\" -> \"TemporaryHiddenChatNotebook\", \"assistant_notebook_closed\" -> True, \"assistant_chat_object_string\" -> chatRaw|>"
    , "      ]"
    , "    ]"
    , "  ]"
    , "];"
    , "ExportString[tungstenResult, \"RawJSON\"]"
    ]
 where
  slash '\\' = '/'
  slash character = character
  defaultInstructions =
    "Do not modify the notebook directly or use notebook-editing tools. "
      <> "Answer in chat only. If you provide Wolfram Language code, place it in a Wolfram Language code block."
  combinedInstructions = case fmap T.strip extraInstructions of
    Just extra | not (T.null extra) -> defaultInstructions <> "\n\n" <> extra
    _ -> defaultInstructions
  baseSettings =
    Map.fromList
      [ ("AutoSaveConversations", JsonBool False)
      , ( "Tools"
        , JsonArray (map JsonString ["WolframLanguageEvaluator", "DocumentationSearcher", "WolframAlpha"])
        )
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

buildAssistantInsertScript
  :: FilePath
  -> JsonValue
  -> [Text]
  -> Bool
  -> Text
buildAssistantInsertScript notebookPath selector codes saveNotebook =
  T.unlines
    [ "tungstenSelector = ImportString[" <> wlString (encodeJson selector) <> ", \"RawJSON\"];"
    , "tungstenCodes = ImportString[" <> wlString (encodeJson (JsonArray (map JsonString codes))) <> ", \"RawJSON\"];"
    , "tungstenNotebookPath = " <> wlString (T.pack (map slash notebookPath)) <> ";"
    , "tungstenSaveNotebook = " <> if saveNotebook then "True;" else "False;"
    , assistantHelperBlock "ToString[cellExpr, InputForm, PageWidth -> Infinity]" []
    , "tungstenResult = Module[{sourceNotebook, sourceCell, insertionPoint, inserted = {}, code, uuid, insertedCell},"
    , "  sourceNotebook = tungstenResolveNotebook @ tungstenNotebookPath;"
    , "  If[AssociationQ @ sourceNotebook, sourceNotebook,"
    , "    sourceCell = tungstenResolveCell[sourceNotebook, tungstenSelector];"
    , "    If[AssociationQ @ sourceCell, sourceCell,"
    , "      insertionPoint = sourceCell;"
    , "      Do["
    , "        uuid = CreateUUID[];"
    , "        SelectionMove[insertionPoint, After, Cell, AutoScroll -> False];"
    , "        NotebookWrite[sourceNotebook, Cell[code, \"Input\", ExpressionUUID -> uuid], All, AutoScroll -> False];"
    , "        insertedCell = Quiet @ Check[First[Cells[sourceNotebook, ExpressionUUID -> uuid]], None];"
    , "        If[MatchQ[insertedCell, _CellObject], insertionPoint = insertedCell];"
    , "        AppendTo[inserted, <|\"expression_uuid\" -> uuid, \"cell_id\" -> Replace[If[MatchQ[insertedCell, _CellObject], CurrentValue[insertedCell, CellID], Null], {value_Integer :> value, _ :> Null}], \"code\" -> code|>],"
    , "        {code, tungstenCodes}"
    , "      ];"
    , "      If[TrueQ @ tungstenSaveNotebook, NotebookSave @ sourceNotebook];"
    , "      <|\"success\" -> True, \"source_cell\" -> tungstenCellMetadata @ sourceCell, \"inserted\" -> inserted, \"saved_notebook\" -> TrueQ @ tungstenSaveNotebook|>"
    , "    ]"
    , "  ]"
    , "];"
    , "ExportString[tungstenResult, \"RawJSON\"]"
    ]
 where
  slash '\\' = '/'
  slash character = character

assistantHelperBlock :: Text -> [Text] -> Text
assistantHelperBlock previewExpression extraNames =
  T.unlines
    [ "ClearAll[" <> T.intercalate ", " clearNames <> "];"
    , "tungstenError[type_String, message_String, extra_: <||>] := Join[<|\"success\" -> False, \"error_type\" -> type, \"error\" -> message|>, extra];"
    , "tungstenStringValue[value_] := Replace[value, {None | Null | Inherited | Missing[__] -> Null, s_String :> s, other_ :> ToString[Unevaluated[other], InputForm, PageWidth -> Infinity]}];"
    , "tungstenStringList[value_] := Replace[value, {s_String :> {s}, list_List :> Cases[list, tag_String :> tag, Infinity], _ :> {}}];"
    , "tungstenCompactText[text_String] := StringTake[StringTrim @ StringReplace[text, WhitespaceCharacter .. -> \" \"], UpTo[240]];"
    , "tungstenCellMetadata[cell_CellObject] := Module[{cellExpr, preview}, cellExpr = Quiet @ Check[NotebookRead @ cell, $Failed]; preview = Quiet @ Check[" <> previewExpression <> ", \"\"]; <|\"expression_uuid\" -> tungstenStringValue @ CurrentValue[cell, ExpressionUUID], \"cell_id\" -> Replace[CurrentValue[cell, CellID], {value_Integer :> value, _ :> Null}], \"cell_tags\" -> tungstenStringList @ CurrentValue[cell, CellTags], \"style\" -> tungstenStringValue @ CurrentValue[cell, CellStyle], \"preview\" -> tungstenCompactText @ Replace[preview, Except[_String] :> \"\"]|>];"
    , "tungstenFindNotebook[path_String] := SelectFirst[Notebooks[], Quiet @ Check[NotebookFileName[#] === path, False] &, Missing[\"NotFound\"]];"
    , "tungstenResolveNotebook[path_String] := Module[{existing, opened}, existing = tungstenFindNotebook @ path; If[MatchQ[existing, _NotebookObject], Return[existing]]; opened = Quiet @ Check[NotebookOpen[path], $Failed]; If[MatchQ[opened, _NotebookObject], opened, tungstenError[\"NotebookOpenFailed\", \"Unable to open the requested notebook.\", <|\"notebook_path\" -> path|>]]];"
    , "tungstenResolveCell[nbo_NotebookObject, selector_Association] := Module[{matches = {}, cellIndex, allCells}, Which[StringQ @ Lookup[selector, \"expression_uuid\", Missing[\"NotFound\"]], matches = Cells[nbo, ExpressionUUID -> selector[\"expression_uuid\"]], IntegerQ @ Lookup[selector, \"cell_id\", Missing[\"NotFound\"]], matches = Cells[nbo, CellID -> selector[\"cell_id\"]], StringQ @ Lookup[selector, \"cell_tag\", Missing[\"NotFound\"]], matches = Cells[nbo, CellTags -> selector[\"cell_tag\"]], IntegerQ @ Lookup[selector, \"cell_index\", Missing[\"NotFound\"]], allCells = Cells[nbo]; cellIndex = selector[\"cell_index\"] + 1; matches = If[1 <= cellIndex <= Length[allCells], {allCells[[cellIndex]]}, {}], True, matches = {}]; Which[Length[matches] == 1, First[matches], Length[matches] == 0, tungstenError[\"CellNotFound\", \"No notebook cell matched the requested selector.\", <|\"selector\" -> selector|>], True, tungstenError[\"AmbiguousCellSelector\", \"More than one notebook cell matched the requested selector.\", <|\"selector\" -> selector, \"match_count\" -> Length[matches]|>]]];"
    ]
 where
  clearNames =
    stableUnique
      ( [ "tungstenError", "tungstenStringValue", "tungstenStringList"
        , "tungstenCompactText", "tungstenCellMetadata", "tungstenFindNotebook"
        , "tungstenResolveNotebook", "tungstenResolveCell"
        ]
          <> extraNames
      )
  stableUnique = reverse . snd . foldl add ([], [])
  add (seen, output) value
    | value `elem` seen = (seen, output)
    | otherwise = (value : seen, value : output)

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

askAssistantCell
  :: WolframInstallation
  -> FilePath
  -> CellSelector
  -> Text
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> IO (Either Text NotebookAssistantResult)
askAssistantCell installation requestedPath selector question extraInstructions modelService modelName =
  askAssistantCellWithOptions
    installation requestedPath selector question "none" False
    extraInstructions modelService modelName

askAssistantCellWithOptions
  :: WolframInstallation
  -> FilePath
  -> CellSelector
  -> Text
  -> Text
  -> Bool
  -> Maybe Text
  -> Maybe Text
  -> Maybe Text
  -> IO (Either Text NotebookAssistantResult)
askAssistantCellWithOptions installation requestedPath selector question insertMode saveNotebook extraInstructions modelService modelName = do
  sourceResult <- try (TextIO.readFile requestedPath)
  case (sourceResult :: Either IOException Text) of
    Left exception -> pure (Left (T.pack (show exception)))
    Right source -> case parseNotebook source of
      Left notebookError -> pure (Left (notebookErrorMessage notebookError))
      Right document -> case resolveNotebookCell document selector of
        Left inlineError -> pure (Left (inlineBoxErrorMessage inlineError))
        Right record -> do
          notebookPath <- makeAbsolute requestedPath
          let resolvedSelector = selectorFromCellRecord record
          evaluation <-
            evaluateKernelText
              installation
              ( buildAssistantAskCellScript
                  notebookPath question resolvedSelector
                  extraInstructions modelService modelName
              )
              Nothing
              True
          let rawPayload = parseAssistantPayload evaluation
              response = chatResponseFromPayload rawPayload
              blocks = maybe [] extractAssistantCodeBlocks response
              wolframCodes = map assistantCodeBlockCode (filter assistantCodeBlockInsertable blocks)
              selectedCodes = case insertMode of
                "all" -> wolframCodes
                "first" -> take 1 wolframCodes
                _ -> []
          insertionPayload <- if null selectedCodes || not (payloadSuccess rawPayload)
            then pure Nothing
            else do
              insertionEvaluation <-
                evaluateKernelText
                  installation
                  (buildAssistantInsertScript notebookPath resolvedSelector selectedCodes saveNotebook)
                  Nothing
                  True
              pure (Just (parseAssistantPayload insertionEvaluation))
          pure
            ( Right
                NotebookAssistantResult
                  { assistantEvaluation = evaluation
                  , assistantPayload =
                      finalizeAssistantAskCellPayloadWithInsertion rawPayload insertMode insertionPayload
                  }
            )

chatResponseFromPayload :: JsonValue -> Maybe Text
chatResponseFromPayload (JsonObject payload) = case Map.lookup "assistant_chat_object_string" payload of
  Just (JsonString chatObject) ->
    let response = extractAssistantText chatObject
     in if T.null response then Nothing else Just response
  _ -> Nothing
chatResponseFromPayload _ = Nothing

selectorFromCellRecord :: CellRecord -> JsonValue
selectorFromCellRecord record =
  JsonObject . Map.singleton key $ value
 where
  cell = cellRecordCell record
  (key, value) = case expressionUuid cell of
    Just uuid | not (T.null uuid) -> ("expression_uuid", JsonString uuid)
    _ -> case cellId cell of
      Just identifier -> ("cell_id", JsonNumber (T.pack (show identifier)))
      Nothing -> case filter (not . T.null) (cellTags cell) of
        tag : _ -> ("cell_tag", JsonString tag)
        [] -> ("cell_index", JsonNumber (T.pack (show (cellRecordIndex record))))

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
