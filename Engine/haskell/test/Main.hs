{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.Char (chr)
import Data.IORef (atomicModifyIORef', newIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesFileExist
  , executable
  , getPermissions
  , getTemporaryDirectory
  , removeDirectoryRecursive
  , removeFile
  , setPermissions
  )
import System.Exit (exitFailure)
import System.Info (os)
import System.IO (hClose, hSetEncoding, openTempFile, utf8)
import System.FilePath ((</>))
import Tungsten.Cli
import Tungsten.Assistant
import Tungsten.DocsIndex
import Tungsten.Expression
import Tungsten.Evaluate
import Tungsten.Discovery
import Tungsten.Frontend
import Tungsten.InlineBoxes
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.Licensing
import Tungsten.NamedCharacters
import Tungsten.Notebook
import Tungsten.Parser
import Tungsten.ParserCorpus
import Tungsten.Repl
import Tungsten.Session
import Tungsten.WolframString
import Tungsten.WolframProcesses

main :: IO ()
main = do
  results <- sequence tests
  if and results
    then TextIO.putStrLn "All Haskell expression/JSON foundation tests passed."
    else exitFailure

tests :: [IO Bool]
tests =
  [ checkFullForms
  , checkAssistant
  , checkWolframStrings
  , checkNamedCharacters
  , checkInlineBoxes
  , checkFullFormParser
  , checkFullFormParserErrors
  , checkInputFormParser
  , checkInputFormParserErrors
  , checkEvaluator
  , checkEvaluatorErrors
  , checkCliArguments
  , checkNotebookModel
  , checkNotebookErrors
  , checkNotebookPatches
  , checkNotebookPatchJson
  , checkEvaluationSession
  , checkRepl
  , checkDiscovery
  , checkDocumentationIndex
  , checkParserCorpus
  , checkWolframProcesses
  , checkLicensing
  , checkKernelRunner
  , checkFrontEndBuilders
  , checkSmartConstructors
  , checkExpressionJsonRoundTrips
  , checkJsonCodec
  , checkProtocol
  , checkParserEvaluatorProtocol
  , checkProtocolErrors
  ]

checkWolframProcesses :: IO Bool
checkWolframProcesses = withTemporaryDirectory "tungsten-processes" $ \temporary -> do
  let cache = temporary </> "wolfram-license-cache.json"
      controlling =
        WolframProcessInfo
          1 0 "Mathematica.exe" Nothing Nothing Nothing False False False True
      helper =
        WolframProcessInfo
          2 1 "WolframKernel.exe" Nothing (Just "wolframkernel.exe -mathlink helper")
          Nothing False False False False
      blocked = WolframProcessSnapshot [controlling, controlling {wolframProcessPid = 3}] (Just 2)
      free = WolframProcessSnapshot [controlling, helper] (Just 2)
  before <- readCachedMaxLicenseProcessesAt cache
  writeCachedMaxLicenseProcessesAt cache 2
  after <- readCachedMaxLicenseProcessesAt cache
  snapshots <- newIORef [blocked, free]
  let nextSnapshot = atomicModifyIORef' snapshots $ \case
        [] -> ([], free)
        value : rest -> (rest, value)
  (finalSnapshot, _, satisfied) <-
    waitForWolframLicenseSlotWith nextSnapshot (Just 2) 1 0
  gateResult <- withWolframLaunchGate 1 0 (\waited -> pure (waited >= 0))
  timeoutResult <-
    withWolframLaunchGate 1 0 $ \_ ->
      withWolframLaunchGate 0 0 (\_ -> pure True)
  checks <- sequence
    [ assertEqual "Wolfram process cache initially absent" Nothing before
    , assertEqual "Wolfram process cache round trip" (Just 2) after
    , assertEqual "Wolfram desktop controls a license" True (isControllingProcessCandidate "Mathematica.exe" "")
    , assertEqual "Wolfram MathLink helper does not control a license" False (isControllingProcessCandidate "WolframKernel.exe" "wolframkernel.exe -mathlink helper")
    , assertEqual "Wolfram process active count excludes helper" 1 (activeWolframProcessCount free)
    , assertEqual "Wolfram license wait becomes satisfied" True satisfied
    , assertEqual "Wolfram license wait returns free snapshot" free finalSnapshot
    , assertEqual "Wolfram launch gate acquisition" (Right True) gateResult
    , assertEqual
        "Wolfram launch gate timeout"
        (Right (Left "Timed out waiting for the Tungsten Wolfram launch gate."))
        timeoutResult
    ]
  pure (and checks)

checkAssistant :: IO Bool
checkAssistant = do
  let raw =
        "ChatObject[<|\"Messages\" -> {"
          <> "<|\"Role\" -> \"System\", \"Content\" -> {<|\"Type\" -> \"Text\", \"Data\" -> \"ignore\"|>}, \"Metadata\" -> <||>|>, "
          <> "<|\"Role\" -> \"Assistant\", \"Content\" -> {<|\"Type\" -> \"Text\", \"Data\" -> \"Use Plus.\\\\n```wolfram\\\\n2 + 2\\\\n```\"|>}, \"Metadata\" -> <||>|>"
          <> "}|>]"
      response = extractAssistantText raw
      blocks = extractAssistantCodeBlocks response
      successfulPayload =
        JsonObject
          ( Map.fromList
              [ ("assistant_chat_object_string", JsonString raw)
              , ("prompt", JsonString "add")
              , ("success", JsonBool True)
              ]
          )
      finalized = finalizeAssistantAskPayload successfulPayload
      cellPayload = case successfulPayload of
        JsonObject values ->
          JsonObject (Map.insert "source_cell" (JsonObject (Map.singleton "expression_uuid" (JsonString "abc"))) values)
        _ -> successfulPayload
      finalizedCell = finalizeAssistantAskCellPayload cellPayload
      insertionPayload =
        JsonObject
          ( Map.fromList
              [ ("inserted", JsonArray [JsonObject (Map.singleton "code" (JsonString "2 + 2"))])
              , ("saved_notebook", JsonBool True)
              , ("success", JsonBool True)
              ]
          )
      finalizedInsertion =
        finalizeAssistantAskCellPayloadWithInsertion cellPayload "first" (Just insertionPayload)
      script =
        buildAssistantAskScript
          "What is 2+2?" (Just "Answer Wolfram questions.")
          (Just "Use a fenced block.") Nothing Nothing Nothing
      cellScript =
        buildAssistantAskCellScript
          "/tmp/example.nb" "Explain this cell."
          (JsonObject (Map.singleton "expression_uuid" (JsonString "abc")))
          Nothing Nothing Nothing
      insertionScript =
        buildAssistantInsertScript
          "/tmp/example.nb"
          (JsonObject (Map.singleton "expression_uuid" (JsonString "abc")))
          ["2 + 2"] True
      prepareInlineScript =
        buildAssistantPrepareInlineScript
          "/tmp/example.nb"
          (JsonObject (Map.singleton "expression_uuid" (JsonString "abc")))
      captureInlineScript =
        buildAssistantCaptureInlineScript
          "/tmp/example.nb"
          (JsonObject (Map.singleton "expression_uuid" (JsonString "abc")))
          "all" True
  installation <- discoverInstallation
  unavailable <- askAssistant installation {installationKernelCli = Nothing} "2+2" Nothing Nothing Nothing Nothing Nothing
  kernelUnavailable <- evaluateKernelText installation {installationKernelCli = Nothing} "2+2" Nothing False
  let encodedPayload = wlString (encodeJson successfulPayload)
      parsedPayload =
        parseAssistantPayload
          kernelUnavailable
            { kernelEvaluationAvailable = True
            , kernelSuccess = Just True
            , kernelResult = Just encodedPayload
            }
      finalizedMap = case finalized of
        JsonObject values -> values
        _ -> Map.empty
      unavailableMap = case assistantPayload unavailable of
        JsonObject values -> values
        _ -> Map.empty
      finalizedCellMap = case finalizedCell of
        JsonObject values -> values
        _ -> Map.empty
      finalizedInsertionMap = case finalizedInsertion of
        JsonObject values -> values
        _ -> Map.empty
      checks =
        [ assertEqual "assistant response extraction" "Use Plus.\n```wolfram\n2 + 2\n```" response
        , assertEqual
            "assistant fenced code extraction"
            [AssistantCodeBlock 0 "wolfram" "2 + 2" True]
            blocks
        , assertEqual "assistant finalized response" (Just (JsonString response)) (Map.lookup "response_text" finalizedMap)
        , assertEqual "assistant finalized prompt" (Just (JsonString "add")) (Map.lookup "prompt" finalizedMap)
        , assertEqual "assistant strips raw chat object" Nothing (Map.lookup "assistant_chat_object_string" finalizedMap)
        , assertEqual "assistant payload JSON decoding" successfulPayload parsedPayload
        , assertEqual "assistant unavailable result" False (assistantSuccess unavailable)
        , assertEqual
            "assistant unavailable error type"
            (Just (JsonString "EvaluationUnavailable"))
            (Map.lookup "error_type" unavailableMap)
        , assertEqual "assistant ask script loads Chatbook" True ("Needs[\"Wolfram`Chatbook`\" -> None]" `Text.isInfixOf` script)
        , assertEqual "assistant ask script evaluates chat cell" True ("tungstenChatCellEvaluate[chatCell, assistantNotebook]" `Text.isInfixOf` script)
        , assertEqual "assistant ask script has no notebook selector" False ("tungstenResolveCell" `Text.isInfixOf` script)
        , assertEqual "assistant cell finalization mode" (Just (JsonString "none")) (Map.lookup "insert_mode" finalizedCellMap)
        , assertEqual "assistant cell finalization insertion" (Just (JsonArray [])) (Map.lookup "inserted" finalizedCellMap)
        , assertEqual "assistant cell finalization save" (Just (JsonBool False)) (Map.lookup "saved_notebook" finalizedCellMap)
        , assertEqual "assistant cell script resolves notebook" True ("tungstenResolveNotebook" `Text.isInfixOf` cellScript)
        , assertEqual "assistant cell script embeds selector" True ("expression_uuid" `Text.isInfixOf` cellScript)
        , assertEqual "assistant cell script requests FrontEnd chat" True ("tungstenChatCellEvaluate" `Text.isInfixOf` cellScript)
        , assertEqual "assistant insertion finalization mode" (Just (JsonString "first")) (Map.lookup "insert_mode" finalizedInsertionMap)
        , assertEqual "assistant insertion finalization save" (Just (JsonBool True)) (Map.lookup "saved_notebook" finalizedInsertionMap)
        , assertEqual "assistant insertion script writes input cells" True ("NotebookWrite[sourceNotebook, Cell[code, \"Input\"" `Text.isInfixOf` insertionScript)
        , assertEqual "assistant insertion script saves notebook" True ("tungstenSaveNotebook = True" `Text.isInfixOf` insertionScript)
        , assertEqual "assistant inline preparation opens assistant" True ("tungstenShowNotebookAssistance[sourceCell, \"Inline\"" `Text.isInfixOf` prepareInlineScript)
        , assertEqual "assistant inline preparation focuses input" True ("AttachedChatInputField" `Text.isInfixOf` prepareInlineScript)
        , assertEqual "assistant inline capture checks completion" True ("hasProgress" `Text.isInfixOf` captureInlineScript && "completed" `Text.isInfixOf` captureInlineScript)
        , assertEqual "assistant inline capture extracts code blocks" True ("tungstenCodeBlocksFromExpression" `Text.isInfixOf` captureInlineScript)
        , assertEqual "assistant inline capture inserts all blocks" True ("tungstenInsertMode = \"all\"" `Text.isInfixOf` captureInlineScript)
        , assertEqual "assistant inline capture saves inserted blocks" True ("tungstenSaveNotebook = True" `Text.isInfixOf` captureInlineScript)
        ]
  unitChecks <- and <$> sequence checks
  cellRunCheck <- withTemporaryDirectory "tungsten-assistant" $ \temporary -> do
    let notebookPath = temporary </> "assistant.nb"
    TextIO.writeFile
      notebookPath
      "Notebook[{Cell[\"2+2\", \"Input\", ExpressionUUID -> \"assistant-cell\"]}]"
    result <-
      askAssistantCell
        installation {installationKernelCli = Nothing}
        notebookPath (SelectCellIndex 0) "Explain this." Nothing Nothing Nothing
    prepared <-
      prepareInlineAssistant
        installation {installationKernelCli = Nothing}
        notebookPath (SelectExpressionUuid "assistant-cell")
    captured <-
      captureInlineAssistant
        installation {installationKernelCli = Nothing}
        notebookPath (SelectCellIndex 0) "all" True
    selected <- assertEqual
      "assistant selected-cell unavailable path"
      (Right False)
      (assistantSuccess <$> result)
    preparedCheck <- assertEqual
      "assistant inline preparation unavailable path"
      (Right False)
      (assistantSuccess <$> prepared)
    capturedCheck <- assertEqual
      "assistant inline capture unavailable path"
      (Right False)
      (assistantSuccess <$> captured)
    pure (selected && preparedCheck && capturedCheck)
  pure (unitChecks && cellRunCheck)

checkWolframStrings :: IO Bool
checkWolframStrings = do
  let boxExpression = "GraphicsBox[{CircleBox[]}]"
      rawEscape = "\\!\\(\\*" <> boxExpression <> "\\)"
      decodedEscape = Text.pack (map chr [0xf7c1, 0xf7c9, 0xf7c8]) <> boxExpression <> Text.singleton (chr 0xf7c0)
      decoded = "hello " <> decodedEscape
      expectedSegments =
        [ StringTextSegment "hello "
        , StringInlineBoxSegment boxExpression decodedEscape
        ]
      nestedExpression = "RowBox[{\"\\(ignored\\)\", (* \\(ignored\\) *) \\(x\\)}]"
      nestedEscape = inlineBoxEscape nestedExpression
      checks =
        [ assertEqual
            "decode inline-box string markers"
            decoded
            (parseWolframStringLiteral ("\"hello \\!\\(\\*" <> boxExpression <> "\\)\""))
        , assertEqual "segment decoded inline boxes" expectedSegments (splitInlineBoxes decoded)
        , assertEqual
            "segment raw inline boxes"
            [StringTextSegment "hello ", StringInlineBoxSegment boxExpression rawEscape]
            (splitInlineBoxes ("hello " <> rawEscape))
        , assertEqual
            "respect strings and comments while matching nested boxes"
            [StringInlineBoxSegment nestedExpression nestedEscape]
            (splitInlineBoxes nestedEscape)
        , assertEqual
            "compose inline-box source"
            ("icon: " <> rawEscape <> ".")
            (composeInlineBoxString "icon: " [boxExpression] ".")
        , assertEqual
            "compose inline-box literal"
            ("\"icon: \\\\!\\\\(\\\\*GraphicsBox[{CircleBox[]}]\\\\).\"")
            (composeInlineBoxStringLiteral "icon: " [boxExpression] ".")
        , assertEqual "replace boxes in display text" "hello [InlineBox]" (displayText "[InlineBox]" decoded)
        , assertEqual
            "decode Wolfram character escape families"
            "AαAAB\\q"
            (parseWolframStringLiteral "\"\\.41\\[Alpha]\\:0041\\101\\<B\\>\\q\"")
        , assertEqual
            "FullForm parser shares string decoding"
            (Right (String decoded))
            (parseFullForm ("\"hello \\!\\(\\*" <> boxExpression <> "\\)\""))
        , case exprToJson (String decoded) of
            JsonObject fields -> case Map.lookup "inline_boxes" fields of
              Just (JsonArray [JsonObject boxFields]) ->
                assertEqual
                  "string JSON exposes inline boxes"
                  (Just (JsonString boxExpression))
                  (Map.lookup "box_expression" boxFields)
              _ -> assertEqual "string JSON inline-box array shape" True False
            _ -> assertEqual "string JSON object shape" True False
        ]
  and <$> sequence checks

checkNamedCharacters :: IO Bool
checkNamedCharacters = do
  let catalogEntries = Map.toList namedCharacterCodepoints
      catalogDecodeCount =
        length
          [ ()
          | (name, codepoint) <- catalogEntries
          , parseFullForm ("\"\\[" <> name <> "]\"") == Right (String (Text.singleton (chr codepoint)))
          ]
      inputCases =
        [ ("named identifier", "\\[Alpha]", Symbol "α")
        , ("named identifier alias", "\\[Pi]", Symbol "Pi")
        , ("imaginary unit alias", "\\[ImaginaryI]", Symbol "I")
        , ("exponential alias", "\\[ExponentialE]", Symbol "E")
        , ("hex identifier alias", "\\:03C0", Symbol "Pi")
        , ("mid-identifier escape", "x\\:03C0", Symbol "xπ")
        , ("generic PUA identifier", "\\:E000", Symbol (Text.singleton (chr 0xe000)))
        , ("supplementary identifier", "\\|01F600", Symbol "😀")
        , ("named And operator", "a \\[And] b", Call (Symbol "And") [Symbol "a", Symbol "b"])
        , ("direct And operator", "a ∧ b", Call (Symbol "And") [Symbol "a", Symbol "b"])
        , ("named rule operator", "a \\[Rule] b", Call (Symbol "Rule") [Symbol "a", Symbol "b"])
        , ("named invisible multiplication", "2 \\[InvisibleTimes] x", Call (Symbol "Times") [Integer 2, Symbol "x"])
        , ( "named association delimiters"
          , "\\[LeftAssociation]a -> 1\\[RightAssociation]"
          , Call (Symbol "Association") [Call (Symbol "Rule") [Symbol "a", Integer 1]]
          )
        ]
      rejected =
        [ ("unknown named identifier", "\\[NotARealName]")
        , ("octal identifier", "\\041")
        , ("operator PUA identifier", "\\:F4A1")
        , ("surrogate identifier", "\\:D800")
        ]
  inputChecks <-
    traverse
      (\(label, source, expected) -> assertEqual label (Right expected) (parseInputForm source))
      inputCases
  rejectedChecks <-
    traverse (\(label, source) -> assertLeft label (parseInputForm source)) rejected
  structuralChecks <- sequence
    [ assertEqual "complete named-character catalog size" 1100 (Map.size namedCharacterCodepoints)
    , assertEqual "decode every named character in strings" 1100 catalogDecodeCount
    , assertEqual "Wolfram Function codepoint" (Just (chr 0xf4a1)) (namedCharacter "Function")
    , assertEqual "Wolfram ImaginaryI codepoint" (Just (chr 0xf74e)) (namedCharacter "ImaginaryI")
    , assertEqual "render symbols with canonical named escapes" "\\[Alpha]" (fullForm (Symbol "α"))
    ]
  pure (and (inputChecks <> rejectedChecks <> structuralChecks))

checkInlineBoxes :: IO Bool
checkInlineBoxes = do
  let source =
        "Notebook[{"
          <> "Cell[BoxData[GraphicsBox[{CircleBox[]}]], \"Output\", ExpressionUUID->\"uuid-graphic\"],"
          <> "Cell[\"prefix \\!\\(\\*StyleBox[\\\"Hello\\\", FontWeight->Bold]\\) suffix\", \"Text\", CellID->2001]"
          <> "}]"
      document = expectRight (parseNotebook source)
      extracted =
        map
          (extractBoxExpressions . cellContent . cellRecordCell)
          (flattenCells document)
      composition = composeInlineBoxPayload ["GraphicsBox[{CircleBox[]}]"] "icon: " "."
      byUuid =
        extractInlineBoxesFromNotebookCell
          document
          (SelectExpressionUuid "uuid-graphic")
          "icon: "
          ""
          0
          False
      byCellId =
        extractInlineBoxesFromNotebookCell
          document
          (SelectCellId 2001)
          "rendered: "
          ""
          0
          True
      checks =
        [ assertEqual
            "extract BoxData and string inline boxes"
            [ ["GraphicsBox[List[CircleBox[]]]"]
            , ["StyleBox[\"Hello\", FontWeight->Bold]"]
            ]
            extracted
        , assertEqual "inline-box composition count" 1 (length (inlineBoxCompositionBoxes composition))
        , assertEqual
            "inline-box composition value"
            "icon: \\!\\(\\*GraphicsBox[{CircleBox[]}]\\)."
            (inlineBoxCompositionStringValue composition)
        , assertEqual
            "inline-box composition head"
            (Just "GraphicsBox")
            (inlineBoxRecordHead =<< firstBox (inlineBoxCompositionBoxes composition))
        , assertEqual
            "select notebook box by ExpressionUUID"
            (Right ["GraphicsBox[List[CircleBox[]]]"])
            (map inlineBoxRecordExpression . inlineBoxSelectionSelectedBoxes <$> byUuid)
        , assertEqual
            "select all notebook boxes by CellID"
            (Right ["StyleBox[\"Hello\", FontWeight->Bold]"])
            (map inlineBoxRecordExpression . inlineBoxSelectionSelectedBoxes <$> byCellId)
        , assertEqual
            "reject an out-of-range inline-box object"
            (Left "InlineBoxObjectIndexOutOfRange" :: Either Text ())
            ( inlineErrorType
                ( extractInlineBoxesFromNotebookCell
                  document
                  (SelectCellIndex 0)
                  ""
                  ""
                  4
                  False
                )
            )
        ]
  and <$> sequence checks
 where
  firstBox (box : _) = Just box
  firstBox [] = Nothing
  inlineErrorType (Left inlineError) = Left (inlineBoxErrorType inlineError)
  inlineErrorType (Right _) = Right ()

checkFullFormParser :: IO Bool
checkFullFormParser = do
  let cases =
        [ ("nested calls", "Plus[1, Times[2, x]]", Call (Symbol "Plus") [Integer 1, Call (Symbol "Times") [Integer 2, Symbol "x"]])
        , ("chained heads", "Derivative[2][f][x]", Call (Call (Call (Symbol "Derivative") [Integer 2]) [Symbol "f"]) [Symbol "x"])
        , ("nested comments", "Plus[1, (* outer (* inner *) end *) 2]", Call (Symbol "Plus") [Integer 1, Integer 2])
        , ("arbitrary integer", "999999999999999999999999999999999999", Integer 999999999999999999999999999999999999)
        , ("leading-point real", ".5`30", Real ".5`30")
        , ("precision real", "6.02214076`8*^23", Real "6.02214076`8*^23")
        , ("trailing-point precision real", "0.7000`30.", Real "0.7000`30.")
        , ("trailing-point zero-precision real", "0.7`0.", Real "0.7`0.")
        , ("trailing-point accuracy real", "0.7``0.", Real "0.7``0.")
        , ("normalized rational", "Rational[-6, -8]", Rational 3 4)
        , ("complex atom", "Complex[Rational[1, 2], -3]", Complex (Rational 1 2) (Integer (-3)))
        , ("escaped string", "\"line\\n snowman \\:2603 face \\|01f600\"", String "line\n snowman ☃ face 😀")
        , ("parenthesized head", "(f)[x]", Call (Symbol "f") [Symbol "x"])
        ]
  and
    <$> traverse
      (\(label, source, expected) -> assertEqual ("FullForm parser: " <> label) (Right expected) (parseFullForm source))
      cases

checkFullFormParserErrors :: IO Bool
checkFullFormParserErrors = do
  first <- assertLeft "reject trailing FullForm input" (parseFullForm "f[x] trailing")
  second <- assertLeft "reject invalid rational" (parseFullForm "Rational[1, 0]")
  third <- assertLeft "reject malformed real exponent" (parseFullForm "1.2*^3.5")
  fourth <- assertLeft "reject unterminated comment" (parseFullForm "f[1] (* open")
  pure (and [first, second, third, fourth])

checkInputFormParser :: IO Bool
checkInputFormParser = do
  let cases =
        [ ("implicit multiplication and power", "1 + 2 x^3", "Plus[1, Times[2, Power[x, 3]]]")
        , ("exact division", "1/6 + 1/3", "Plus[Rational[1, 6], Rational[1, 3]]")
        , ("right associative power", "a^b^c", "Power[a, Power[b, c]]")
        , ("unary minus precedence", "-x^2", "Times[-1, Power[x, 2]]")
        , ("lists and calls", "f[{a, b}, g[x]]", "f[List[a, b], g[x]]")
        , ("uniform comparison", "a < b < c", "Less[a, b, c]")
        , ("mixed comparison", "a < b <= c", "Inequality[a, Less, b, LessEqual, c]")
        , ("Boolean operators", "a && b || c", "Or[And[a, b], c]")
        , ("rule", "a -> b + 1", "Rule[a, Plus[b, 1]]")
        , ("replacement", "f[a] /. a -> b", "ReplaceAll[f[a], Rule[a, b]]")
        , ("condition", "x_ /; x > 0", "Condition[Pattern[x, Blank[]], Greater[x, 0]]")
        , ("typed patterns", "f[x_Integer, y_]", "f[Pattern[x, Blank[Integer]], Pattern[y, Blank[]]]")
        , ("sequence blanks", "f[__, ___Symbol]", "f[BlankSequence[], BlankNullSequence[Symbol]]")
        , ("alternatives", "a | b | c", "Alternatives[a, b, c]")
        , ("slots and pure function", "#1 + #name &", "Function[Plus[Slot[1], Slot[\"name\"]]]")
        , ("slot sequence", "f[##2] &", "Function[f[SlotSequence[2]]]")
        , ("prefix and postfix application", "f @ x // g", "g[f[x]]")
        , ("part", "expr[[1, 2]]", "Part[expr, 1, 2]")
        , ("right associative assignment", "a = b = 2", "Set[a, Set[b, 2]]")
        , ("delayed assignment", "f[x_] := x^2", "SetDelayed[f[Pattern[x, Blank[]]], Power[x, 2]]")
        , ("factorials", "n! + n!!", "Plus[Factorial[n], Factorial2[n]]")
        , ("association", "<|a -> 1, b :> 2|>", "Association[Rule[a, 1], RuleDelayed[b, 2]]")
        , ("pattern test", "x_?IntegerQ", "PatternTest[Pattern[x, Blank[]], IntegerQ]")
        , ("optional pattern default", "f[x_Integer:7]", "f[Optional[Pattern[x, Blank[Integer]], 7]]")
        , ("named pattern sequence", "x:PatternSequence[a_, b_]", "Pattern[x, PatternSequence[Pattern[a, Blank[]], Pattern[b, Blank[]]]]")
        , ("repeated postfix", "patt..", "Repeated[patt]")
        , ("repeated null postfix", "patt...", "RepeatedNull[patt]")
        , ("greedy optional repeated postfix", "x_...", "Repeated[Optional[Pattern[x, Blank[]]]]")
        , ("precision before repeated postfix", "1.2`3..", "Repeated[1.2`3]")
        , ("compound expression", "x = 1; x + 1;", "CompoundExpression[Set[x, 1], Plus[x, 1], Null]")
        , ("output history shorthand", "% + %% + %12", "Plus[Out[], Out[-2], Out[12]]")
        ]
  and
    <$> traverse
      (\(label, source, expected) -> assertEqual ("InputForm parser: " <> label) (Right expected) (fullForm <$> parseInputForm source))
      cases

checkInputFormParserErrors :: IO Bool
checkInputFormParserErrors = do
  first <- assertLeft "reject incomplete InputForm call" (parseInputForm "f[1")
  second <- assertLeft "reject incomplete InputForm operator" (parseInputForm "1 +")
  third <- assertLeft "reject malformed InputForm part" (parseInputForm "x[[1]")
  pure (and [first, second, third])

checkEvaluator :: IO Bool
checkEvaluator = do
  let inputCases =
        [ ("integer arithmetic", "1 + 2*3", "7")
        , ("exact rational arithmetic", "1/6 + 1/3", "Rational[1, 2]")
        , ("scalar floor and ceiling", "{Floor[3.7], Floor[-3.7], Ceiling[3.2], Ceiling[-3.2], Floor[7, 3], Floor[7, -3], Ceiling[7, 3]}", "List[3, -4, 4, -3, 6, 9, 9]")
        , ("exact rational rounding", "{Floor[7/2], Ceiling[7/2], Floor[7/2, 2/3], Ceiling[7/2, 2/3], Round[7/2, 2/3]}", "List[3, 4, Rational[10, 3], 4, Rational[10, 3]]")
        , ("banker rounding", "{Round[3.5], Round[2.5], Round[7/2], Round[5/2], Round[5, 2], Round[7, 3], Round[-2.5], Round[-3.5]}", "List[4, 2, 4, 2, 4, 6, -2, -4]")
        , ("integer and exact fractional parts", "{IntegerPart[3.7], IntegerPart[-3.7], IntegerPart[5/3], IntegerPart[-5/3], FractionalPart[5/3], FractionalPart[-5/3]}", "List[3, -3, 1, -1, Rational[2, 3], Rational[-2, 3]]")
        , ("machine fractional parts", "{FractionalPart[3.7], FractionalPart[1.2], FractionalPart[-3.7], FractionalPart[2.0], FractionalPart[-0.0], FractionalPart[.5], FractionalPart[1.*^-5]}", "List[0.7000000000000002, 0.19999999999999996, -0.7000000000000002, 0., -0., 0.5, 1*^-05]")
        , ("marked fractional parts", "{FractionalPart[3.7000`30], FractionalPart[1.2``20], FractionalPart[1.2`20*^3], FractionalPart[12.34`20*^-1], FractionalPart[-0.0`30]}", "List[0.7000`30., 0.2`0., 0.0`20., 0.234`20., -0.0`30.]")
        , ("rounding edge behavior", "{Round[2.5000000000000001], Floor[1, 0], Ceiling[7, -3], Round[5, -2], Floor[x], Floor[1, x]}", "List[3, Indeterminate, 6, 4, Floor[x], Floor[1, x]]")
        , ("componentwise complex rounding", "{IntegerPart[-3.7 + 4.2 I], FractionalPart[-3.7 + 4.2 I], Round[Complex[-3.5, 2.5]], IntegerPart[I]}", "List[Complex[-3, 4], Complex[-0.7000000000000002, 0.20000000000000018], Complex[-4, 2], Complex[0, 1]]")
        , ("complex rounding normalization", "{IntegerPart[1.2 + 0.2 I], FractionalPart[1/2 + 0.2 I], FractionalPart[Complex[1/2, 1/5]]}", "List[1, Complex[0.5, 0.2], Complex[Rational[1, 2], Rational[1, 5]]]")
        , ("exact square roots and radicals", "{Sqrt[16], Sqrt[2], Sqrt[1/4], Sqrt[-4], Sqrt[12], 54^(1/3), 8^(2/3)}", "List[4, Power[2, Rational[1, 2]], Rational[1, 2], Times[2, I], Times[2, Power[3, Rational[1, 2]]], Times[3, Power[2, Rational[1, 3]]], 4]")
        , ("rational power extraction", "{2^(2/3), 2^(4/3), (8/27)^(2/3), 12^(-1/2), (4/9)^(-1/2), 0^(1/2), 0^(-1/2)}", "List[Power[4, Rational[1, 3]], Times[2, Power[2, Rational[1, 3]]], Rational[4, 9], Times[Rational[1, 2], Power[3, Rational[-1, 2]]], Rational[3, 2], 0, ComplexInfinity]")
        , ("sqrt and power edge behavior", "{Power[], Power[x], 0^0, 0^-1, (-4)^(1/2), -4^(1/2), (-8)^(1/3), Sqrt[2.], Sqrt[2`30], Sqrt[-2.], Sqrt[x], Hold[Sqrt[12]]}", "List[1, x, Indeterminate, ComplexInfinity, Complex[0, 2], -2, Power[-8, Rational[1, 3]], 1.4142135623730951, 1.4142135623730951, Sqrt[-2.], Sqrt[x], Hold[Sqrt[12]]]")
        , ("negative composite sqrt shape", "Sqrt[-12]", "Times[Times[2, Power[3, Rational[1, 2]]], I]")
        , ("negative rational power", "(2/3)^-3", "Rational[27, 8]")
        , ("symbolic coefficient collection", "2 x 3", "Times[6, x]")
        , ("symbolic constant collection", "x + 1 + 2", "Plus[3, x]")
        , ("repeated symbolic collection", "{a + a + a, a*a*a, f[x] + f[x], f[x]*f[x]}", "List[Times[3, a], Power[a, 3], Times[2, f[x]], Power[f[x], 2]]")
        , ("evaluated argument normalization", "{Nothing, Sequence[a, b], Splice[{c, d}]}", "List[a, b, c, d]")
        , ("factorials", "6! + 6!!", "768")
        , ("numeric comparison", "1 < 2 <= 2", "True")
        , ("numeric inequality", "Unequal[1, 2, 1]", "False")
        , ("Boolean reduction", "True && !False", "True")
        , ("conditional branch", "If[2 > 1, 20 + 22, 0]", "42")
        , ("range", "Range[-2, 4, 2]", "List[-2, 0, 2, 4]")
        , ("total", "Total[{1, 2, 3, 4}]", "10")
        , ("accumulate", "Accumulate[{1, 2, 3, 4}]", "List[1, 3, 6, 10]")
        , ("list structure", "{First[{a, b}], Last[{a, b}], Rest[{a, b}], Most[{a, b}]} ", "List[a, b, List[b], List[a]]")
        , ("part", "{{a, b}, {c, d}}[[2, 1]]", "c")
        , ("head and predicates", "{Head[1/2], AtomQ[1/2], ListQ[{x}], IntegerQ[2], NumberQ[2/3], StringQ[\"x\"]}", "List[Rational, True, True, True, True, True]")
        , ("map", "Map[f, {1, 2, 3}]", "List[f[1], f[2], f[3]]")
        , ("apply", "Apply[f, {1, 2, 3}]", "f[1, 2, 3]")
        , ("take positive", "Take[f[a, b, c, d], 2]", "f[a, b]")
        , ("take negative", "Take[f[a, b, c, d], -2]", "f[c, d]")
        , ("take range", "Take[f[a, b, c, d, e], {2, 5, 2}]", "f[b, d]")
        , ("drop range", "Drop[f[a, b, c, d, e], {2, 5, 2}]", "f[a, c, e]")
        , ("multi-axis take", "Take[{{1, 2, 3}, {4, 5, 6}}, 2, 2]", "List[List[1, 2], List[4, 5]]")
        , ("multi-axis drop", "Drop[{{1, 2, 3}, {4, 5, 6}}, 1, 1]", "List[List[5, 6]]")
        , ("append preserving head", "Append[f[a], b]", "f[a, b]")
        , ("prepend preserving head", "Prepend[f[a], b]", "f[b, a]")
        , ("join preserving head", "Join[f[a], f[b, c]]", "f[a, b, c]")
        , ("rotate left", "RotateLeft[f[a, b, c], 2]", "f[c, a, b]")
        , ("rotate right", "RotateRight[f[a, b, c], 2]", "f[b, c, a]")
        , ("flatten recursively", "Flatten[f[a, f[b, f[c]], d]]", "f[a, b, c, d]")
        , ("flatten one level", "Flatten[f[a, f[b, f[c]], d], 1]", "f[a, b, f[c], d]")
        , ("flatten named head", "Flatten[g[a, h[b, h[c, d]], e], Infinity, h]", "g[a, b, c, d, e]")
        , ("delete nested", "Delete[f[a, g[b, c], d], {2, 1}]", "f[a, g[c], d]")
        , ("delete multiple", "Delete[f[a, b, c, d], {{2}, {4}}]", "f[a, c]")
        , ("insert part", "Insert[{a, b, c}, x, 2]", "List[a, x, b, c]")
        , ("replace part", "ReplacePart[f[a, b, c], {{2} -> x, {3} -> y}]", "f[a, x, y]")
        , ("replace overlapping parts", "ReplacePart[f[g[a, b], c], {{1, 1} -> y, {1} -> x}]", "f[x, c]")
        , ("replace Nothing deletes", "ReplacePart[{a, b}, 1 -> Nothing]", "List[b]")
        , ("map at nested part", "MapAt[g, f[a, h[b, c], d], {2, 1}]", "f[a, h[g[b], c], d]")
        , ("map at duplicate part", "MapAt[g, f[a, b, c], {{2}, {2}}]", "f[a, g[g[b]], c]")
        , ("association duplicate normalization", "<|a -> 1, a -> 2, b -> 3|>", "Association[Rule[a, 2], Rule[b, 3]]")
        , ("association list constructor", "Association[{a -> 1, a -> 2, b -> 3}]", "Association[Rule[a, 2], Rule[b, 3]]")
        , ("association predicate", "{AssociationQ[<|a -> 1|>], AssociationQ[Association[a]]}", "List[True, False]")
        , ("association depth follows values", "Depth[<|a -> <|b -> 1|>, c -> {2, 3}|>]", "3")
        , ("association keys", "Keys[<|a -> x, b -> y, c -> z|>]", "List[a, b, c]")
        , ("association values", "Values[<|a -> x, b -> y, c -> z|>]", "List[x, y, z]")
        , ("association normal form", "Normal[<|a -> x, b -> y|>]", "List[Rule[a, x], Rule[b, y]]")
        , ("association lookup", "Lookup[<|a -> 1, b -> 2|>, b]", "2")
        , ("association missing lookup", "Lookup[<|a -> 1, b -> 2|>, d]", "Missing[\"KeyAbsent\", d]")
        , ("association lookup list default", "Lookup[<|a -> 1, b -> 2|>, {b, d}, q]", "List[2, q]")
        , ("association key membership", "{KeyExistsQ[<|a -> x, b -> y|>, b], KeyMemberQ[<|a -> x, b -> y|>, d]}", "List[True, False]")
        , ("association key take", "KeyTake[<|a -> 1, b -> 2, c -> 3|>, {c, a}]", "Association[Rule[c, 3], Rule[a, 1]]")
        , ("association key drop", "KeyDrop[<|a -> 1, b -> 2, c -> 3|>, {c, a}]", "Association[Rule[b, 2]]")
        , ("association key select", "KeySelect[<|\"a\" -> 1, bb -> 2|>, StringQ]", "Association[Rule[\"a\", 1]]")
        , ("association key select operator", "KeySelect[StringQ][<|\"a\" -> 1, bb -> 2|>]", "Association[Rule[\"a\", 1]]")
        , ("association key map", "KeyMap[f, <|a -> 1, b -> 2|>]", "Association[Rule[f[a], 1], Rule[f[b], 2]]")
        , ("association key value map", "KeyValueMap[f, <|a -> 1, b -> 2|>]", "List[f[a, 1], f[b, 2]]")
        , ("association thread", "AssociationThread[{a, b, c}, {1, 2, 3}]", "Association[Rule[a, 1], Rule[b, 2], Rule[c, 3]]")
        , ("association map", "AssociationMap[f, {a, b, c}]", "Association[Rule[a, f[a]], Rule[b, f[b]], Rule[c, f[c]]]")
        , ("association key sort", "KeySort[<|b -> 2, a -> 1|>]", "Association[Rule[a, 1], Rule[b, 2]]")
        , ("association value structure", "{First[<|a -> 1, b -> 2|>], Last[<|a -> 1, b -> 2|>], Apply[g, <|a -> 1, b -> 2|>], Total[<|a -> 1, b -> 2|>]}", "List[1, 2, g[1, 2], 3]")
        , ("association slicing", "{Rest[<|a -> 1, b -> 2, c -> 3|>], Most[<|a -> 1, b -> 2, c -> 3|>], Take[<|a -> 1, b -> 2, c -> 3|>, 2], Drop[<|a -> 1, b -> 2, c -> 3|>, 2]}", "List[Association[Rule[b, 2], Rule[c, 3]], Association[Rule[a, 1], Rule[b, 2]], Association[Rule[a, 1], Rule[b, 2]], Association[Rule[c, 3]]]")
        , ("association append positioning", "{Append[<|a -> 1, b -> 2|>, a -> 9], Prepend[<|a -> 1, b -> 2|>, a -> 9]}", "List[Association[Rule[b, 2], Rule[a, 9]], Association[Rule[a, 9], Rule[b, 2]]]")
        , ("association join and map", "{Join[<|a -> 1, b -> 2|>, <|a -> 9, c -> 3|>], Map[g, <|a -> 1, b -> 2|>]}", "List[Association[Rule[a, 9], Rule[b, 2], Rule[c, 3]], Association[Rule[a, g[1]], Rule[b, g[2]]]]")
        , ("association Nothing filtering", "{<|Nothing, a -> 1|>, Keys[<|Nothing -> 1, a -> 2|>], Values[<|a -> Nothing, b -> 1|>]}", "List[Association[Rule[a, 1]], List[a], List[1]]")
        , ("association part by key", "Part[<|a -> x, b -> y, c -> z|>, Key[b]]", "y")
        , ("association part by direct string key", "Part[<|\"a\" -> x, \"b\" -> {y, z}|>, \"b\", 2]", "z")
        , ("association part by index", "Part[<|a -> x, b -> y, c -> z|>, 2]", "y")
        , ("association part key projection", "Part[<|a -> 1, b -> 2, c -> 3, d -> 4|>, {Key[a], Key[c]}]", "Association[Rule[a, 1], Rule[c, 3]]")
        , ("association extract keys", "Extract[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]", "List[1, 3]")
        , ("association extract nested path", "Extract[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]", "3")
        , ("association delete keys", "Delete[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]", "Association[Rule[b, 2]]")
        , ("association delete nested path", "Delete[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]", "List[Association[Rule[a, 1], Rule[b, List[2]]], 9]")
        , ("association replace keys", "ReplacePart[<|a -> 1, b -> 2, c -> 3|>, {{Key[a]} -> x, {Key[c]} -> z}]", "Association[Rule[a, x], Rule[b, 2], Rule[c, z]]")
        , ("association replace nested path", "ReplacePart[{<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2} -> x]", "List[Association[Rule[a, 1], Rule[b, List[2, x]]], 9]")
        , ("association map at keys", "MapAt[f, <|a -> 1, b -> 2, c -> 3|>, {{Key[a]}, {Key[c]}}]", "Association[Rule[a, f[1]], Rule[b, 2], Rule[c, f[3]]]")
        , ("association map at nested path", "MapAt[f, {<|a -> 1, b -> {2, 3}|>, 9}, {1, Key[b], 2}]", "List[Association[Rule[a, 1], Rule[b, List[2, f[3]]]], 9]")
        , ("identity and parity predicates", "{Identity[x], EvenQ[4], EvenQ[3], OddQ[4], OddQ[3]}", "List[x, True, False, False, True]")
        , ("merge associations", "Merge[{<|a -> 1, b -> 2|>, <|a -> 3|>}, Identity]", "Association[Rule[a, List[1, 3]], Rule[b, List[2]]]")
        , ("group by keys", "GroupBy[{1, 2, 3, 4, 5, 6}, EvenQ]", "Association[Rule[False, List[1, 3, 5]], Rule[True, List[2, 4, 6]]]")
        , ("group by transformed values", "GroupBy[{1, 2, 3, 4, 5, 6}, EvenQ -> Total]", "Association[Rule[False, 9], Rule[True, 12]]")
        , ("gather by keys", "GatherBy[{1, 2, 3, 4, 5, 6}, EvenQ]", "List[List[1, 3, 5], List[2, 4, 6]]")
        , ("gather by structural identity", "Gather[{1, 2, 3, 1, 2, 4}]", "List[List[1, 1], List[2, 2], List[3], List[4]]")
        , ("association key complement", "KeyComplement[{<|a -> 1, b -> 2|>, <|b -> 3|>}]", "Association[Rule[a, 1]]")
        , ("association key union", "KeyUnion[{<|a -> 1|>, <|b -> 2|>}]", "List[Association[Rule[a, 1], Rule[b, Missing[\"KeyAbsent\", b]]], Association[Rule[a, Missing[\"KeyAbsent\", a]], Rule[b, 2]]]")
        , ("association key intersection", "KeyIntersection[{<|a -> 1, b -> 2|>, <|b -> 3, c -> 4|>}]", "List[Association[Rule[b, 2]], Association[Rule[b, 3]]]")
        , ("matrix total", "Total[{{1, 2}, {3, 4}}]", "List[4, 6]")
        , ("ordered tally", "Tally[{a, b, a, c, a, b}]", "List[List[a, 3], List[b, 2], List[c, 1]]")
        , ("ordered counts", "Counts[{a, b, a, c, a, b}]", "Association[Rule[a, 3], Rule[b, 2], Rule[c, 1]]")
        , ("catenate lists", "Catenate[{{a, b}, {c, d}}]", "List[a, b, c, d]")
        , ("catenate association values", "Catenate[<|a -> {1, 2}, b -> {3, 4}|>]", "List[1, 2, 3, 4]")
        , ("successive differences", "Differences[{1, 3, 6, 10}]", "List[2, 3, 4]")
        , ("association accumulate", "Accumulate[<|a -> 1, b -> 2, c -> 3|>]", "Association[Rule[a, 1], Rule[b, 3], Rule[c, 6]]")
        , ("riffle scalar", "Riffle[{a, b, c}, x]", "List[a, x, b, x, c]")
        , ("riffle cyclic separators", "Riffle[{a, b, c, d}, {x, y}]", "List[a, x, b, y, c, x, d]")
        , ("quantified collection predicates", "{AllTrue[{1, 2, 3}, IntegerQ], AnyTrue[{1, 2, 3, x}, StringQ], NoneTrue[{1, 2, 3}, StringQ]}", "List[True, False, True]")
        , ("collection containment", "{ContainsAll[{1, 2, 3, 4}, {2, 4}], ContainsAny[{1, 2, 3}, {3, 4, 5}], ContainsNone[{1, 2, 3}, {4, 5}], ContainsExactly[{1, 2, 3}, {3, 2, 1}]}", "List[True, True, True, True]")
        , ("all subsets", "Subsets[{a, b, c}]", "List[List[], List[a], List[b], List[c], List[a, b], List[a, c], List[b, c], List[a, b, c]]")
        , ("fixed-size subsets", "Subsets[{a, b, c, d}, {2}]", "List[List[a, b], List[a, c], List[a, d], List[b, c], List[b, d], List[c, d]]")
        , ("full permutations", "Permutations[{a, b, c}]", "List[List[a, b, c], List[a, c, b], List[b, a, c], List[b, c, a], List[c, a, b], List[c, b, a]]")
        , ("positional permute", "Permute[{a, b, c}, {2, 3, 1}]", "List[c, a, b]")
        , ("cycle permute", "Permute[f[a, b, c], Cycles[{{1, 2, 3}}]]", "f[c, a, b]")
        , ("left and right padding", "{PadLeft[{1, 2, 3}, 5], PadRight[{1, 2}, 5, x]}", "List[List[0, 0, 1, 2, 3], List[1, 2, x, x, x]]")
        , ("numeric min max list folding", "{Min[{1, 2, 3}], Max[{1, 2, 3}], Min[{1, 4}, {2, 3}], Max[{1, 4}, {2, 3}], Min[{1, x, 2}]}", "List[1, 3, 1, 4, Min[1, x]]")
        , ("min max identities and inexact ordering", "{Min[], Max[], Min[Infinity, 2], Max[Infinity, x], Min[1.2, 1.10], Max[{1, x, 2}], Min[x, x, 2]}", "List[Infinity, -Infinity, 2, Infinity, 1.10, Max[2, x], Min[2, x]]")
        , ("min max flat and numeric ties", "{Min[Min[x, y], z], Max[Max[x, y], z], Min[.1, 1/10], Max[.1, 1/10], Min[1`20, 1.], Max[0., -0.], Min[Max[], x]}", "List[Min[x, y, z], Max[x, y, z], Rational[1, 10], Rational[1, 10], 1., -0., -Infinity]")
        , ("exact means", "{Mean[{1, 2, 3, 4, 5}], Mean[{1, 2, 3, 4}]}", "List[3, Rational[5, 2]]")
        , ("exact medians", "{Median[{1, 2, 3, 4, 5}], Median[{1, 2, 3, 4}]}", "List[3, Rational[5, 2]]")
        , ("canonical order signs", "{Order[1, 2], Order[2, 1], Order[a, a]}", "List[1, -1, 0]")
        , ("ordered predicates", "{OrderedQ[{1, 2, 2}], OrderedQ[{2, 1}], OrderedQ[{3, 2, 1}, Greater]}", "List[True, False, True]")
        , ("ordering indices", "{Ordering[{3, 1, 2}], Ordering[{3, 1, 2}, 2], Ordering[{3, 1, 2}, -2], Ordering[{3, 1, 2}, All, Greater]}", "List[List[2, 3, 1], List[2, 3], List[3, 1], List[1, 3, 2]]")
        , ("canonical sort", "Sort[f[3, 1, 2]]", "f[1, 2, 3]")
        , ("comparator sort", "{Sort[{3, 1, 2}, Greater], Sort[{3, 1, 2, 4}, Less, 2]}", "List[List[3, 2, 1], List[1, 2]]")
        , ("reverse sort", "{ReverseSort[{3, 1, 2}], ReverseSort[{3, 1, 2}, Greater], ReverseSort[{3, 1, 2, 4}, Less, 2]}", "List[List[3, 2, 1], List[1, 2, 3], List[4, 3]]")
        , ("association sort by values", "Sort[<|b -> 2, a -> 1|>]", "Association[Rule[a, 1], Rule[b, 2]]")
        , ("sort by scalar key", "SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last]", "List[List[b, 1], List[a, 2], List[c, 2]]")
        , ("sort by key list stable ties", "SortBy[{{c, 2}, {a, 2}, {b, 1}}, {Last}]", "List[List[b, 1], List[c, 2], List[a, 2]]")
        , ("sort by operator form", "SortBy[Last][{{a, 2}, {b, 1}}]", "List[List[b, 1], List[a, 2]]")
        , ("sort by comparator", "SortBy[{-3, 1, -2, 4}, Abs, Greater]", "List[4, -3, -2, 1]")
        , ("reverse sort by association values", "ReverseSortBy[<|a -> 2, b -> 1, c -> 3|>, Identity]", "Association[Rule[c, 3], Rule[a, 2], Rule[b, 1]]")
        , ("canonical set operations", "{Union[{1, 2, 3}, {2, 3, 4}], Intersection[{1, 2, 3}, {2, 3, 4}], Complement[{1, 2, 3, 4}, {2, 4}]}", "List[List[1, 2, 3, 4], List[2, 3], List[1, 3]]")
        , ("select preserving head", "Select[f[1, a, 2, 3], IntegerQ]", "f[1, 2, 3]")
        , ("select limits", "{Select[f[1, a, 2, 3], IntegerQ, 2], Select[f[1, a, 2, 3], IntegerQ, 0]}", "List[f[1, 2], f[]]")
        , ("select operator form", "Select[EvenQ][{1, 2, 3, 4}]", "List[2, 4]")
        , ("discard match limit", "Discard[f[1, 2, 3, 4], EvenQ, 1]", "f[1, 3, 4]")
        , ("select first and default", "{SelectFirst[{1, a, 2, 3}, # > 1 &], SelectFirst[{1, a}, # > 1 &, q]}", "List[2, q]")
        , ("association select", "Select[<|a -> 1, b -> x, c -> 2|>, IntegerQ]", "Association[Rule[a, 1], Rule[c, 2]]")
        , ("association select discard limits", "{Select[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1], Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]}", "List[Association[Rule[a, 1]], Association[Rule[b, x], Rule[c, 2]]]")
        , ("association select first", "{SelectFirst[<|a -> 1, b -> x, c -> 2|>, IntegerQ], SelectFirst[<|a -> x, b -> y|>, IntegerQ]}", "List[1, Missing[\"NotFound\"]]")
        , ("take while head and association", "{TakeWhile[f[2, 4, 6, 7, 8], EvenQ], TakeWhile[<|a -> 2, b -> 4, c -> 1, d -> 8|>, EvenQ], LengthWhile[{2, 4, 6, 7, 8}, EvenQ]}", "List[f[2, 4, 6], Association[Rule[a, 2], Rule[b, 4]], 3]")
        , ("pick list and head", "{Pick[{a, b, c, d}, {False, True, False, True}], Pick[f[a, b, c, d], {False, True, False, True}]}", "List[List[b, d], f[b, d]]")
        , ("pick explicit pattern", "Pick[{a, b, c, d}, {0, 1, 0, 1}, 1]", "List[b, d]")
        , ("pick association values", "Pick[<|p -> a, q -> b, r -> c, s -> d|>, {False, True, False, True}]", "Association[Rule[q, b], Rule[s, d]]")
        , ("Boole truth and fallback", "{Boole[1 < 2], Boole[x]}", "List[1, Boole[x]]")
        , ("match blank head call", "MatchQ[f[1], _[1]]", "True")
        , ("match typed nested blanks", "MatchQ[f[1, g[a]], f[_Integer, g[_Symbol]]]", "True")
        , ("match repeated named bindings", "{MatchQ[f[a, a], f[x_, x_]], MatchQ[f[a, b], f[x_, x_]]}", "List[True, False]")
        , ("match alternatives and exceptions", "{MatchQ[g[a], f[_] | g[_]], MatchQ[a, Except[_Integer]], MatchQ[2, Except[_Integer]]}", "List[True, True, False]")
        , ("match verbatim pattern syntax", "MatchQ[_, Verbatim[_]]", "True")
        , ("match bound conditions", "{MatchQ[f[2], f[x_ /; x > 0]], MatchQ[f[-1], f[x_ /; x > 0]]}", "List[True, False]")
        , ("match condition precedence", "{MatchQ[a, a | b /; False], MatchQ[a, a | (b /; False)]}", "List[False, True]")
        , ("match sequence blanks", "{MatchQ[a, __], MatchQ[1, __Symbol], MatchQ[f[a, b], f[__]], MatchQ[f[], f[__]], MatchQ[f[], f[___]]}", "List[True, False, True, False, True]")
        , ("match typed and middle sequences", "{MatchQ[f[a, b], f[__Symbol]], MatchQ[f[a, 1], f[__Symbol]], MatchQ[f[a, b, c], f[a, __, c]], MatchQ[f[a, c], f[a, __, c]], MatchQ[f[a, c], f[a, ___, c]]}", "List[True, False, True, False, True]")
        , ("match multiple sequence blanks", "{MatchQ[f[a, b, c], f[__, __]], MatchQ[f[a], f[__, __]], MatchQ[f[a], f[___, ___]]}", "List[True, False, True]")
        , ("match association type", "MatchQ[<|a -> 1|>, _Association]", "True")
        , ("free q heads and levels", "{FreeQ[f[a], f], FreeQ[f[a], f, {1}], FreeQ[f[a], f, {0}], FreeQ[f[a, g[b]], g[_], -1]}", "List[False, False, True, False]")
        , ("free q typed pattern", "FreeQ[{a, b, b, a}, _Integer]", "True")
        , ("member q list and association values", "{MemberQ[{a, 2, c}, _Integer], MemberQ[<|a -> x, b -> 2|>, x, Infinity], MemberQ[<|a -> x, b -> 2|>, a, Infinity]}", "List[True, True, False]")
        , ("count literal and typed pattern", "{Count[{1, 2, 3, 2, 1}, 2], Count[{1, 2, 3, 2, 1}, _Integer]}", "List[2, 5]")
        , ("cases levels and postorder", "{Cases[f[a, g[a]], a, Infinity], Cases[f[g[a]], _, {0, Infinity}], Cases[f[a, g[b]], _, -1], Cases[f[a, g[a]], a, Infinity, 1]}", "List[List[a, a], List[a, g[a], f[g[a]]], List[a, b, g[b]], List[a]]")
        , ("cases sequence patterns", "{Cases[{f[a], f[a, b], f[]}, f[__]], Cases[{f[a], f[a, b], f[]}, f[___]], Cases[{f[a, 1], f[a, b]}, f[__Symbol]]}", "List[List[f[a], f[a, b]], List[f[a], f[a, b], f[]], List[f[a, b]]]")
        , ("delete cases levels", "{DeleteCases[f[a, g[a]], a], DeleteCases[f[a, g[a]], a, Infinity], DeleteCases[f[a, g[a]], _Symbol, -1]}", "List[f[g[a]], f[g[]], f[g[]]]")
        , ("delete cases limit and condition", "{DeleteCases[{1, a, 2, a}, a, Infinity, 1], DeleteCases[{1, -2, 3}, x_ /; x > 0]}", "List[List[1, 2, a], List[-2]]")
        , ("delete cases sequence pattern", "DeleteCases[{f[a], f[a, b], f[]}, f[__]]", "List[f[]]")
        , ("association pattern traversal", "{Cases[<|a -> x, b -> 2|>, _Integer], DeleteCases[<|a -> 1, b -> x, c -> 2|>, _Integer], FirstCase[<|a -> x, b -> 2|>, _Integer]}", "List[List[2], Association[Rule[b, x]], 2]")
        , ("position levels heads and associations", "{Position[f[a, g[a]], a, Infinity], Position[{a, b, c}, _, {1}, Heads -> False], Position[<|a -> 1, b -> {2, x}|>, _Integer]}", "List[List[List[1], List[2, 1]], List[List[1], List[2], List[3]], List[List[Key[a]], List[Key[b], 1]]]")
        , ("first position defaults", "{FirstPosition[{1, 2, 3}, 2], FirstPosition[{1, 2, 3}, 5], FirstPosition[{1, 2, 3}, 5, deflt]}", "List[List[2], Missing[\"NotFound\"], deflt]")
        , ("position extrema and index", "{PositionLargest[{1, 5, 3, 5}], PositionSmallest[{4, 1, 2, 1}], PositionIndex[{u, v, w, u, v}]}", "List[List[2, 4], List[2, 4], Association[Rule[u, List[1, 4]], Rule[v, List[2, 5]], Rule[w, List[3]]]]")
        , ("cases replacement template", "Cases[{f[a], f[b]}, f[x_] :> {x, x}]", "List[List[a, a], List[b, b]]")
        , ("cases guarded pattern and template", "{Cases[{1, -2, 3}, x_ /; x > 0], Cases[{1, -2, 3}, x_ :> x + 1 /; x > 0]}", "List[List[1, 3], List[2, 4]]")
        , ("cases sequence template splicing", "{Cases[{f[a, b]}, f[x__] :> x], Cases[{f[a, b]}, f[x__] :> HoldComplete[x]]}", "List[List[a, b], List[HoldComplete[a, b]]]")
        , ("replace root pattern", "Replace[f[a], f[x_] :> x]", "a")
        , ("replace level traversal", "{Replace[f[g[a]], _ -> z, 2], Replace[f[g[a]], _Symbol -> s, -1], Replace[f[g[a]], x_ :> p[x], {0, Infinity}]}", "List[f[z], f[g[s]], p[f[p[g[p[a]]]]]]")
        , ("replace at exact paths", "{ReplaceAt[f[g[a], h[a]], a -> x, {2, 1}], ReplaceAt[f[g[a], h[a]], a -> x, {{1, 1}, {2, 1}}]}", "List[f[g[a], h[x]], f[g[x], h[x]]]")
        , ("replace at ruleset and no match", "{ReplaceAt[f[g[a]], {g[x_] :> x, a -> x}, {1}], ReplaceAt[f[a, b, c], a -> x, 2]}", "List[f[a], f[a, b, c]]")
        , ("replace at association paths", "{ReplaceAt[<|a -> 1, b -> 2|>, _Integer -> x, Key[b]], ReplaceAt[{<|a -> 1|>, 2}, _Integer -> x, {1, Key[a]}]}", "List[Association[Rule[a, 1], Rule[b, x]], List[Association[Rule[a, x]], 2]]")
        , ("replace lhs conditions", "{Replace[2, x_ /; x > 0 :> x + 1], Replace[-1, x_ /; x > 0 :> x + 1]}", "List[3, -1]")
        , ("replace rhs conditions and fallback", "{Replace[2, x_ :> x + 1 /; x > 0], Replace[-1, x_ :> x + 1 /; x > 0], Replace[1, {x_ :> x + 1 /; x < 0, x_ :> x + 2}]}", "List[3, -1, 3]")
        , ("replace all top-down", "{f[g[a]] /. g[x_] :> x, f[g[a]] /. x_ :> p[x]}", "List[f[a], p[f[g[a]]]]")
        , ("replace all nested rulesets", "f[a] /. {{a -> x}, {a -> y}}", "List[f[x], f[y]]")
        , ("replace repeated fixed points", "{f[a] //. f[x_] :> x, f[a] //. x_ :> x}", "List[a, f[a]]")
        , ("replace repeated nested rulesets", "ReplaceRepeated[f[a], {{f[x_] :> x}, {a -> y}}]", "List[a, f[y]]")
        , ("replace all and repeated conditions", "{f[2] /. f[x_ /; x > 0] :> x + 1, 2 /. x_ :> x + 1 /; x > 0, -1 /. x_ :> x + 1 /; x > 0, 1 //. x_ :> x + 1 /; x < 3}", "List[3, 3, -1, 3]")
        , ("association pattern replacement", "{Replace[<|a -> 1|>, _Association -> x], Replace[<|a -> 1|>, _Integer -> x, Infinity], <|a -> 1|> /. _Association -> z, <|a -> 1|> /. _Integer -> x}", "List[x, Association[Rule[a, x]], z, Association[Rule[a, x]]]")
        , ("association head replacement", "<|a -> 1|> /. _Symbol -> s", "s[Rule[a, 1]]")
        , ("replace all sequence splicing", "{f[g[a, b]] /. g[x__] :> x, f[g[a, b]] /. g[x__] :> HoldComplete[x]}", "List[f[a, b], f[HoldComplete[a, b]]]")
        , ("scalar pattern tests", "{MatchQ[1, _?IntegerQ], MatchQ[a, _?IntegerQ]}", "List[True, False]")
        , ("sequence pattern tests", "{Cases[{f[1, 2], f[1, a], f[]}, f[__?IntegerQ]], MatchQ[f[1, 2], f[x__?IntegerQ]], MatchQ[f[1, a], f[x__?IntegerQ]]}", "List[List[f[1, 2]], True, False]")
        , ("pattern test delayed template", "Cases[{1, a, 2}, x_?IntegerQ :> x + 10]", "List[11, 12]")
        , ("optional pattern defaults", "{Cases[{f[], f[2], f[a]}, f[x_:7] :> x], Cases[{f[], f[2]}, f[x_.] :> HoldComplete[x]], Cases[{f[], f[2], f[a]}, f[x_Integer:7] :> x]}", "List[List[7, 2, a], List[HoldComplete[2]], List[7, 2]]")
        , ("optional pattern validation", "{Cases[{f[]}, f[x_?IntegerQ:foo] :> x], Cases[{f[]}, f[x_Integer:foo] :> x]}", "List[List[], List[foo]]")
        , ("optional pattern backtracking", "{Cases[{f[a], f[a, b]}, f[x_:7, y_] :> {x, y}], Cases[{f[], f[a]}, f[x_:7, y_:8] :> {x, y}]}", "List[List[List[7, a], List[a, b]], List[List[7, 8], List[a, 8]]]")
        , ("top-level repeated and pattern sequence", "{MatchQ[1, Repeated[_Integer]], MatchQ[1, PatternSequence[_Integer]]}", "List[True, True]")
        , ("bounded repeated patterns", "{Cases[{f[1], f[1, 2], f[1, 2, 3], f[1, 2, 3, 4]}, f[Repeated[_Integer, {2, 3}]]], Cases[{f[], f[1], f[1, 2], f[1, 2, 3]}, f[RepeatedNull[_Integer, 2]]]}", "List[List[f[1, 2], f[1, 2, 3]], List[f[], f[1], f[1, 2]]]")
        , ("repeated and named pattern sequences", "{Cases[{f[a, b, a, b], f[a, b, a]}, f[Repeated[PatternSequence[a, b]]] :> ok], Cases[{f[1, 2], f[1, 2, 3]}, f[x:PatternSequence[_Integer, _Integer]] :> HoldComplete[x]]}", "List[List[ok], List[HoldComplete[1, 2]]]")
        , ("orderless pattern sequence capture", "Cases[{f[1, 2], f[2, 1]}, f[x:OrderlessPatternSequence[1, 2]] :> HoldComplete[x]]", "List[HoldComplete[1, 2], HoldComplete[2, 1]]")
        , ("longest sequence priorities", "{Cases[{f[a, b, c, d]}, f[Longest[x__], y__] :> HoldComplete[{x}, {y}]], Cases[{f[a, b, c, d]}, f[x__, Longest[y__]] :> HoldComplete[{x}, {y}]]}", "List[List[HoldComplete[List[a, b, c], List[d]]], List[HoldComplete[List[a], List[b, c, d]]]]")
        , ("options pattern matching", "{MatchQ[a -> 1, OptionsPattern[]], MatchQ[1, OptionsPattern[]], Cases[{f[], f[a -> 1], f[{a -> 1}], f[{{}}], f[a], f[1 -> 2]}, f[OptionsPattern[]]]}", "List[True, False, List[f[], f[Rule[a, 1]], f[List[Rule[a, 1]]], f[List[List[]]]]]")
        , ("named options pattern capture", "Cases[{f[], f[a -> 1]}, f[x:OptionsPattern[]] :> HoldComplete[x]]", "List[HoldComplete[], HoldComplete[Rule[a, 1]]]")
        , ("key value pattern matching", "{MatchQ[<|a -> 1, b -> 2|>, KeyValuePattern[a -> _Integer]], MatchQ[<|a -> 1, b -> 2|>, KeyValuePattern[{b -> 2, a -> _}]], MatchQ[<|a -> 1|>, KeyValuePattern[b -> _]], MatchQ[<|a -> <|b -> 2|>|>, KeyValuePattern[b -> _]]}", "List[True, True, False, False]")
        , ("key value pattern bindings", "{Cases[{<|a -> 1|>, <|b -> x|>}, KeyValuePattern[k_ -> v_] :> {k, v}], Cases[<|x -> <|a -> 1|>, y -> <|b -> 2|>|>, KeyValuePattern[a -> _], {0, Infinity}]}", "List[List[List[a, 1], List[b, x]], List[Association[Rule[a, 1]]]]")
        , ("key value pattern rule structures", "{MatchQ[{a -> 1, b -> 2}, KeyValuePattern[b -> _Integer]], MatchQ[<|a :> 1|>, KeyValuePattern[a -> _]], MatchQ[<|a :> 1|>, KeyValuePattern[a :> _]], MatchQ[<|a -> 1|>, KeyValuePattern[{a -> _, a -> 1}]]}", "List[True, False, True, False]")
        , ("ignoring inactive search", "{MatchQ[Inactive[f][1], IgnoringInactive[f[_]]], MatchQ[Inactive[Plus][1, 2], IgnoringInactive[HoldPattern[Plus[_, _]]]], FreeQ[{Inactive[Plus][1, 2]}, IgnoringInactive[HoldPattern[Plus[_, _]]]], Cases[{Inactive[Plus][1, 2], Inactive[f][1]}, IgnoringInactive[HoldPattern[Plus[_, _]]]]}", "List[True, True, False, List[Inactive[Plus][1, 2]]]")
        , ("ignoring inactive original bindings", "{Inactive[f][1] /. IgnoringInactive[f[x_]] :> x, Inactive[f][Inactive[g][1]] /. IgnoringInactive[f[x_]] :> x, Inactive[f[1]] /. IgnoringInactive[f[x_]] :> x}", "List[1, Inactive[g][1], 1]")
        , ("exact replacement", "f[a, g[a]] /. a -> 9", "f[9, g[9]]")
        , ("compound result", "1 + 1; 3 + 4", "7")
        , ("held expression", "Hold[1 + 2]", "Hold[Plus[1, 2]]")
        , ("unsupported remains symbolic", "UnknownBuiltin[1 + 2, x]", "UnknownBuiltin[3, x]")
        ]
      fullCases =
        [ ("slot function", "Function[Power[Slot[1], 2]][5]", "25")
        , ("named function", "Function[x, Plus[x, 1]][41]", "42")
        ]
  inputResults <- traverse (evaluateCase parseInputForm) inputCases
  fullResults <- traverse (evaluateCase parseFullForm) fullCases
  pure (and (inputResults <> fullResults))
 where
  evaluateCase parser (label, source, expected) =
    assertEqual
      ("evaluator: " <> label)
      (Right expected)
      (fullForm <$> (parser source >>= mapLeftEvaluation . evaluate))
  mapLeftEvaluation = either (Left . ParseError . evaluationErrorMessage) Right

checkEvaluatorErrors :: IO Bool
checkEvaluatorErrors = do
  let outOfRange = parseInputForm "{a, b}[[3]]" >>= mapLeftEvaluation . evaluate
      mixedAssociationSelectors =
        parseInputForm "Part[<|a -> 1, b -> 2, c -> 3, d -> 4|>, {2, Key[d]}]"
          >>= mapLeftEvaluation . evaluate
  first <- assertLeft "reject out-of-range Part during evaluation" outOfRange
  second <- assertLeft "reject mixed Association Part selectors" mixedAssociationSelectors
  third <-
    assertLeft
      "reject invalid ReplaceAt path"
      (parseInputForm "ReplaceAt[f[a], a -> x, {2}]" >>= mapLeftEvaluation . evaluate)
  fourth <-
    assertLeft
      "reject nested ReplaceAt rulesets"
      (parseInputForm "ReplaceAt[f[a], {{a -> x}}, {1}]" >>= mapLeftEvaluation . evaluate)
  pure (and [first, second, third, fourth])
 where
  mapLeftEvaluation = either (Left . ParseError . evaluationErrorMessage) Right

checkCliArguments :: IO Bool
checkCliArguments = do
  let checks =
        [ assertEqual "CLI defaults to protocol" (Right ProtocolCommand) (parseCliArguments [])
        , assertEqual
            "CLI inline parse"
            (Right (ExpressionCliCommand ParseCommand (InlineSource "1+2") "input"))
            (parseCliArguments ["expr", "parse", "--code", "1+2"])
        , assertEqual
            "CLI file evaluation and form"
            (Right (ExpressionCliCommand EvaluateCommand (FileSource "input.wl") "fullform"))
            (parseCliArguments ["expr", "evaluate", "--form", "fullform", "--file", "input.wl"])
        , assertLeft "CLI requires a source" (parseCliArguments ["expr", "parse"])
        , assertLeft
            "CLI rejects two sources"
            (parseCliArguments ["expr", "parse", "--code", "1", "--file", "input.wl"])
        , assertLeft "CLI rejects unknown commands" (parseCliArguments ["kernel", "eval"])
        , assertEqual
            "CLI bare Assistant request"
            ( Right
                ( AssistantCliCommand
                    ( AskAssistantCommand
                        "2+2" (Just "Be concise") Nothing Nothing Nothing ["DocumentationSearcher"] True
                    )
                )
            )
            ( parseCliArguments
                [ "assistant", "ask", "--prompt", "2+2", "--system-prompt", "Be concise"
                , "--tool", "DocumentationSearcher", "--require-success"
                ]
            )
        , assertLeft "CLI Assistant request requires prompt" (parseCliArguments ["assistant", "ask"])
        , assertEqual
            "CLI selected-cell Assistant request"
            ( Right
                ( AssistantCliCommand
                    ( AskCellAssistantCommand
                        "demo.nb" (SelectCellPath [1, 0]) "Explain" "all" True True
                        (Just "Be exact") Nothing Nothing True
                    )
                )
            )
            ( parseCliArguments
                [ "assistant", "ask-cell", "--file", "demo.nb", "--cell-path", "1,0"
                , "--question", "Explain", "--insert-all-wolfram-code-below", "--save"
                , "--close-assistant-notebook", "--extra-instructions", "Be exact", "--require-success"
                ]
            )
        , assertEqual
            "CLI inline Assistant preparation"
            ( Right
                ( AssistantCliCommand
                    (PrepareInlineAssistantCommand "demo.nb" (SelectExpressionUuid "cell-1") True)
                )
            )
            ( parseCliArguments
                [ "assistant", "prepare-inline", "--file", "demo.nb"
                , "--expression-uuid", "cell-1", "--require-success"
                ]
            )
        , assertEqual
            "CLI inline Assistant capture"
            ( Right
                ( AssistantCliCommand
                    (CaptureInlineAssistantCommand "demo.nb" (SelectCellId 42) "first" True True)
                )
            )
            ( parseCliArguments
                [ "assistant", "capture-inline", "--file", "demo.nb", "--cell-id", "42"
                , "--insert-wolfram-code-below", "--save", "--require-success"
                ]
            )
        , assertEqual
            "CLI parser-corpus discover"
            ( Right
                ( ParserCorpusCliCommand
                    ( DiscoverParserCorpusCommand
                        ( (defaultParserCorpusOptions "corpus")
                            { parserCorpusCompareWolfram = False
                            , parserCorpusWriteOutputs = False
                            }
                        )
                        3
                    )
                )
            )
            (parseCliArguments ["parser-corpus", "discover", "--corpus-root", "corpus", "--sample", "3"])
        , assertEqual
            "CLI parser-corpus local comparison"
            ( Right
                ( ParserCorpusCliCommand
                    ( CompareParserCorpusCommand
                        ( (defaultParserCorpusOptions "corpus")
                            { parserCorpusCompareWolfram = False
                            , parserCorpusWriteOutputs = False
                            }
                        )
                        True
                        False
                        False
                    )
                )
            )
            ( parseCliArguments
                [ "parser-corpus", "compare", "--corpus-root", "corpus"
                , "--skip-wolfram", "--no-write", "--include-results"
                ]
            )
        , assertEqual
            "CLI notebook inspect"
            (Right (NotebookCliCommand (InspectNotebookCommand "demo.nb")))
            (parseCliArguments ["notebook", "inspect", "--file", "demo.nb"])
        , assertEqual
            "CLI notebook create"
            (Right (NotebookCliCommand (CreateNotebookCommand "demo.nb" (Just "Demo") [("Title", "Hello"), ("Input", "2+2")])))
            ( parseCliArguments
                [ "notebook", "create", "--file", "demo.nb", "--title", "Demo"
                , "--cell", "Title:Hello", "--cell", "Input:2+2"
                ]
            )
        , assertLeft
            "CLI rejects malformed notebook cell"
            (parseCliArguments ["notebook", "create", "--file", "demo.nb", "--cell", "missing-separator"])
        , assertEqual
            "CLI notebook patch"
            (Right (NotebookCliCommand (PatchNotebookCommand "demo.nb" "patch.json" (Just "patched.nb"))))
            ( parseCliArguments
                [ "notebook", "patch", "--spec", "patch.json", "--file", "demo.nb"
                , "--out", "patched.nb"
                ]
            )
        , assertLeft
            "CLI notebook patch requires spec"
            (parseCliArguments ["notebook", "patch", "--file", "demo.nb"])
        , assertEqual
            "CLI inline-box composition"
            ( Right
                ( InlineBoxCliCommand
                    (ComposeInlineBoxCommand ["GraphicsBox[{}]"] "icon: " ".")
                )
            )
            ( parseCliArguments
                [ "inline-box", "compose", "--prefix", "icon: "
                , "--box-expr", "GraphicsBox[{}]", "--suffix", "."
                ]
            )
        , assertEqual
            "CLI inline-box notebook extraction"
            ( Right
                ( InlineBoxCliCommand
                    ( InlineBoxFromCellCommand
                        "demo.nb" (SelectCellPath [1, 0]) "rendered: " "" 2 True True
                    )
                )
            )
            ( parseCliArguments
                [ "inline-box", "from-cell", "--file", "demo.nb"
                , "--cell-path", "[1, 0]", "--prefix", "rendered: "
                , "--object-index", "2", "--all-objects", "--require-success"
                ]
            )
        , assertLeft
            "CLI inline-box extraction requires one selector"
            ( parseCliArguments
                [ "inline-box", "from-cell", "--file", "demo.nb"
                , "--cell-index", "0", "--cell-tag", "tag"
                ]
            )
        , assertLeft
            "CLI rejects malformed inline-box cell paths"
            ( parseCliArguments
                [ "inline-box", "from-cell", "--file", "demo.nb"
                , "--cell-path", "[1, \"bad\"]"
                ]
            )
        , assertEqual
            "CLI documentation index"
            (Right (DocumentationCliCommand (BuildDocumentationIndexCommand (Just "docs.sqlite3"))))
            (parseCliArguments ["docs", "index", "--path", "docs.sqlite3"])
        , assertEqual
            "CLI documentation search"
            ( Right
                ( DocumentationCliCommand
                    (SearchDocumentationCommand "symbolic computation" 4 (Just "docs.sqlite3") True)
                )
            )
            ( parseCliArguments
                [ "docs", "search", "symbolic computation", "--limit", "4"
                , "--index-path", "docs.sqlite3", "--rebuild"
                ]
            )
        , assertEqual
            "CLI documentation read"
            (Right (DocumentationCliCommand (ReadDocumentationCommand "Foo" Nothing False)))
            (parseCliArguments ["docs", "read", "Foo"])
        , assertEqual
            "CLI documentation open"
            (Right (DocumentationCliCommand (OpenDocumentationCommand "Foo" (Just "docs.sqlite3"))))
            (parseCliArguments ["docs", "open", "Foo", "--index-path", "docs.sqlite3"])
        ]
  and <$> sequence checks

checkNotebookPatchJson :: IO Bool
checkNotebookPatchJson = do
  let payload =
        expectRight
          ( parseJson
              "{\"operations\":[{\"op\":\"append_cell\",\"container_path\":[1],\"style\":\"Text\",\"text\":\"tail\"},{\"op\":\"insert_cell\",\"index\":0,\"content_expr\":\"BoxData[RowBox[{\\\"x\\\"}]]\"},{\"op\":\"replace_cell\",\"path\":[0],\"text\":\"new\"},{\"op\":\"delete_item\",\"path\":[2]},{\"op\":\"set_option\",\"name\":\"WindowTitle\",\"value_expr\":\"\\\"Patched\\\"\"}]}"
          )
      expected =
        [ AppendCell (Just [1]) (NotebookCell (String "tail") (Just "Text") [])
        , InsertCell Nothing 0 (NotebookCell (Call (Symbol "BoxData") [Call (Symbol "RowBox") [Call (Symbol "List") [String "x"]]]) (Just "Text") [])
        , ReplaceCell [0] Nothing (String "new")
        , DeleteItem [2]
        , SetNotebookOption "WindowTitle" (String "Patched")
        ]
  first <- assertEqual "decode notebook JSON patches" (Right expected) (decodeNotebookPatches payload)
  second <- assertLeft "reject non-array notebook patch operations" (decodeNotebookPatches (JsonObject (Map.singleton "operations" JsonNull)))
  third <- assertLeft "reject unknown notebook patch operation" (decodeNotebookPatches (expectRight (parseJson "{\"operations\":[{\"op\":\"unknown\"}]}")))
  pure (and [first, second, third])

checkEvaluationSession :: IO Bool
checkEvaluationSession = do
  let cases =
        [ ("immediate assignment", "x = 1 + 2; x^3", "27")
        , ("right-associated assignment", "a = b = 5; a + b", "10")
        , ("immediate value captures current result", "a = 1; x = a; a = 2; x", "1")
        , ("immediate symbolic value reevaluates", "x = y; y = 3; x", "3")
        , ("delayed value observes later result", "a = 1; x := a + 1; a = 4; x", "5")
        , ("unset removes a value", "x = 4; Unset[x]; x", "x")
        , ("clear removes several values", "x = 1; y = 2; Clear[x, y]; x + y", "Plus[x, y]")
        , ("held assignment remains inert", "Hold[x = 9]; x", "x")
        , ("If evaluates one stateful branch", "If[False, x = 1, x = 2]; x", "2")
        , ("And short circuits state", "False && (x = 1); x", "x")
        , ("Or short circuits state", "True || (x = 1); x", "x")
        , ("assignment update", "x = 10; AddTo[x, 5]; x", "15")
        , ("table count iterators", "{Table[a, 3], Table[a, {3}], Table[i, {i, 5}]}", "List[List[a, a, a], List[a, a, a], List[1, 2, 3, 4, 5]]")
        , ("table exact ranges", "{Table[i^2, {i, 1, 5}], Table[i, {i, 2, 8, 2}], Table[i, {i, 5, 1, -1}], Table[i, {i, 0, 1, 1/4}]}", "List[List[1, 4, 9, 16, 25], List[2, 4, 6, 8], List[5, 4, 3, 2, 1], List[0, Rational[1, 4], Rational[1, 2], Rational[3, 4], 1]]")
        , ("table explicit values", "{Table[Sqrt[i], {i, {1, 4, 9, 16}}], Table[i, {i, {a, b, c}}], Table[i, {i, {i}}]}", "List[List[1, 2, 3, 4], List[a, b, c], List[i]]")
        , ("table nested iterators", "{Table[i + j, {i, 3}, {j, 2}], Table[{i, j}, {i, 2}, {j, i}], Table[Table[i*j, {j, i}], {i, 3}]}", "List[List[List[2, 3], List[3, 4], List[4, 5]], List[List[List[1, 1]], List[List[2, 1], List[2, 2]]], List[List[1], List[2, 4], List[3, 6, 9]]]")
        , ("table block scoping", "i = 99; x = 100; {Table[i, {i, 3}], i, Table[x + j, {j, 1, 3}], x}", "List[List[1, 2, 3], 99, List[101, 102, 103], 100]")
        , ("table empty and invalid forms", "{Table[i, {i, 5, 1}], Table[i, {i, 0}], Table[i, {i, 1, 5, 0}], Table[i]}", "List[List[], List[], Table[i, List[i, 1, 5, 0]], Table[i]]")
        , ("table invalid iterators preserve prior effects", "x = 0; Table[a, {i, x = x + 1, b}]; x", "1")
        , ("table invalid forms remain held when nested", "{Table[1 + 2], f[Table[1 + 2]]}", "List[Table[Plus[1, 2]], f[Table[Plus[1, 2]]]]")
        , ("table evaluated-head aliases remain inert and held", "i = 99; f = Table; f[i, {i, 3}]", "Table[i, List[i, 3]]")
        , ("table evaluated list normalization", "{Table[Nothing, {3}], Table[Sequence[i, -i], {i, 2}], Table[f[i], {i, {Nothing, Sequence[a, b]}}], Table[i, {i, {Splice[{a, b}]}}]}", "List[List[], List[1, -1, 2, -2], List[f[a], f[b]], List[a, b]]")
        , ("do held iterations", "{Do[Print[i], {i, 3}], Do[i + 1, {3}]}", "List[Null, Null]")
        , ("do state and scoping", "i = 99; x = 0; {Do[x = x + i*j, {i, 1, 3}, {j, 1, 2}], x, i}", "List[Null, 18, 99]")
        , ("sum exact iterators", "{Sum[i, {i, 1, 5}], Sum[i^2, {i, 1, 5}], Sum[i, {i, 2, 8, 2}], Sum[i, {i, 0, 1, 1/4}]}", "List[15, 55, 20, Rational[5, 2]]")
        , ("sum values and nested iterators", "{Sum[Sqrt[i], {i, {1, 4, 9, 16}}], Sum[i, {i, {a, b, c}}], Sum[i + j, {i, 3}, {j, 2}], Sum[i*j, {i, 1, 3}, {j, 1, 2}]}", "List[10, Plus[a, b, c], 21, 18]")
        , ("sum scoping and inert forms", "i = 99; x = 100; {Sum[i, {i, 1, 3}], i, Sum[x + j, {j, 1, 3}], Sum[a, 3], Sum[a], Sum[], Sum[j, {j, 1, 5, 0}]}", "List[6, 99, 306, Sum[a, 3], Sum[a], Sum[], Sum[j, List[j, 1, 5, 0]]]")
        , ("product exact iterators", "{Product[i, {i, 1, 5}], Product[i^2, {i, 1, 4}], Product[i, {i, 2, 8, 2}], Product[i, {i, 0, 1, 1/4}]}", "List[120, 576, 384, 0]")
        , ("product values and nested iterators", "{Product[Sqrt[i], {i, {1, 4, 9, 16}}], Product[i, {i, {a, b, c}}], Product[i + j, {i, 3}, {j, 2}], Product[i*j, {i, 1, 3}, {j, 1, 2}]}", "List[24, Times[a, b, c], 1440, 288]")
        , ("product scoping and inert forms", "i = 99; x = 2; {Product[i, {i, 1, 3}], i, Product[x + j, {j, 1, 3}], Product[a, 3], Product[a], Product[], Product[j, {j, 1, 5, 0}]}", "List[6, 99, 60, Product[a, 3], Product[a], Product[], Product[j, List[j, 1, 5, 0]]]")
        , ("sum and product interactions", "{Product[Sum[i, {i, 1, j}], {j, 1, 3}], Sum[Sum[i, {j, 1, i}], {i, 1, 3}], Product[2, {n, 0, 10}]}", "List[18, 14, 2048]")
        , ("iterator invalid forms preserve prior effects", "x = 0; Do[a, {i, x = x + 1, b}]; d = x; x = 0; Sum[a, {i, x = x + 1, b}]; s = x; x = 0; Product[a, {i, x = x + 1, b}]; {d, s, x}", "List[1, 1, 1]")
        , ("iterator evaluated-head aliases stay inert", "i = 99; d = Do; s = Sum; p = Product; {d[i, {i, 3}], s[i, {i, 3}], p[i, {i, 3}]}", "List[Do[i, List[i, 3]], Sum[i, List[i, 3]], Product[i, List[i, 3]]]")
        , ("symbolic iterator accumulation", "{Sum[a, {3}], Product[a, {3}], Sum[f[x], {4}], Product[f[x], {4}]}", "List[Times[3, a], Power[a, 3], Times[4, f[x]], Power[f[x], 4]]")
        , ("sequence iterator accumulation", "{Sum[Sequence[i, -i], {i, 2}], Product[Sequence[i, -i], {i, 2}], Sum[Sequence[Nothing, 1], {1}], Product[Sequence[Nothing, 2], {1}]}", "List[0, 4, Plus[1, Nothing], Times[2, Nothing]]")
        , ("targeted splice iterator accumulation", "{Sum[Splice[{a, b}, Plus], {1}], Product[Splice[{a, b}, Times], {1}]}", "List[Plus[a, b], Times[a, b]]")
        , ("nested sequence iterator domains", "x = 0; Do[x = x + 1, {i, {Sequence[Sequence[a, b]]}}]; d = x; x = 0; s = Sum[x = x + 1, {i, {Sequence[Sequence[a, b]]}}]; sx = x; x = 0; p = Product[x = x + 1, {i, {Sequence[Sequence[a, b]]}}]; {d, s, sx, p, x}", "List[2, 3, 2, 2, 2]")
        , ("post-splice nothing iterator domains", "x = 0; Do[x = 1, {i, {Sequence[Sequence[Nothing]]}}]; d = x; x = 0; s = Sum[x = 1, {i, {Sequence[Sequence[Nothing]]}}]; sx = x; x = 0; p = Product[x = 1, {i, {Sequence[Sequence[Nothing]]}}]; {d, s, sx, p, x}", "List[0, 0, 0, 1, 0]")
        , ("iterator normalization ordering", "x = 0; Do[x = x + 1, {i, {Splice[{Sequence[a, b]}]}}]; u = x; x = 0; Do[x = x + 1, {i, {Sequence[Splice[{a, b}]]}}]; {u, x, Table[Sequence[Sequence[i, -i]], {i, 1}]}", "List[2, 1, List[1, -1]]")
        , ("catch and throw control", "{Catch[1 + Throw[x] + 3], Catch[Throw[1 + 2]], Catch[Throw[x, tag], tag], Catch[Throw[x, tag], _Symbol]}", "List[x, 3, x, x]")
        , ("catch handlers", "{Catch[Throw[x, tag], tag, h], Catch[Throw[x, tag], tag, Function[{v, t}, h[v, t]]], Catch[Throw[x, tag], tag, Hold]}", "List[h[x, tag], h[x, tag], Hold[x, tag]]")
        , ("catch setup effects", "x = 0; {Catch[Throw[v, tag], (x = x + 1; tag), (x = x + 1; h)], x}", "List[h[v, tag], 2]")
        , ("throw argument effects", "x = 0; Catch[Throw[x = x + 1, tag, x = x + 1], tag]; x", "2")
        , ("uncaught throw handler", "Throw[x, tag, h]", "h[x, tag]")
        , ("caught throw ignores throw handler", "Catch[Throw[x, tag, h], tag]", "x")
        , ("unmatched throw stays inert", "Catch[Throw[x, tag], other]", "Throw[x, tag]")
        , ("do throw restoration", "i = 99; x = 0; {Catch[Do[x = x + 1; Throw[i], {i, 5}, {j, 5}]], i, x}", "List[1, 99, 1]")
        , ("accumulator throw restoration", "i = 99; {Catch[Sum[Throw[s], {i, 1, 5}]], i, Catch[Product[Throw[p], {i, 1, 5}]], i}", "List[s, 99, p, 99]")
        ]
  and <$> traverse evaluateSessionCase cases
 where
  evaluateSessionCase (label, source, expected) = do
    let result = do
          expression <- parseInputForm source
          (value, _) <- either (Left . ParseError . evaluationErrorMessage) Right (evaluateInSession emptySession expression)
          pure (fullForm value)
    assertEqual ("evaluation session: " <> label) (Right expected) result

checkRepl :: IO Bool
checkRepl = do
  let firstStep = evaluateReplLine initialReplState "x = 2"
      firstState = replStateFrom firstStep
      secondStep = evaluateReplLine firstState "x^3"
      secondState = replStateFrom secondStep
      thirdStep = evaluateReplLine secondState "% + %%"
      thirdState = replStateFrom thirdStep
      lineStep = evaluateReplLine thirdState "$Line"
      historyStep = evaluateReplLine thirdState "{Out[1], InString[2]}"
      exitStep = evaluateReplLine thirdState "Exit[7]"
      checks =
        [ assertEqual "REPL assignment result" (Just (Integer 2)) (replValueFrom firstStep)
        , assertEqual "REPL persistent definition" (Just (Integer 8)) (replValueFrom secondStep)
        , assertEqual "REPL percent history" (Just (Integer 10)) (replValueFrom thirdStep)
        , assertEqual "REPL line counter" (Just (Integer 4)) (replValueFrom lineStep)
        , assertEqual
            "REPL explicit history"
            (Just (Call (Symbol "List") [Integer 2, String "x^3"]))
            (replValueFrom historyStep)
        , assertEqual "REPL exit code" (Just 7) (replExitFrom exitStep)
        , assertEqual "CLI REPL command" (Right (ReplCommand False)) (parseCliArguments ["repl", "--no-banner"])
        ]
  and <$> sequence checks
 where
  replStateFrom (ReplValue _ _ state) = state
  replStateFrom (ReplFailure _ state) = state
  replStateFrom (ReplExit _ state) = state
  replStateFrom (ReplEmpty state) = state
  replValueFrom (ReplValue _ value _) = Just value
  replValueFrom _ = Nothing
  replExitFrom (ReplExit code _) = Just code
  replExitFrom _ = Nothing

checkDiscovery :: IO Bool
checkDiscovery = do
  let desktop15 = InstallationSummary "Wolfram" "wolfram" (Just "15.0") "/wolfram/15.0" (Just "/wolfram/15.0/wolfram") Nothing
      desktop14 = InstallationSummary "Wolfram" "wolfram" (Just "14.3") "/wolfram/14.3" (Just "/wolfram/14.3/wolfram") Nothing
      engine16 = InstallationSummary "Wolfram Engine" "engine" (Just "16.0") "/engine/16.0" (Just "/engine/16.0/wolfram") Nothing
      checks =
        [ assertEqual "parse Wolfram version" [15, 0, 1] (parseVersion "15.0.1")
        , assertEqual "skip empty Wolfram version fragment" [15, 1] (parseVersion "15..1")
        , assertEqual "stop at nonnumeric Wolfram version fragment" [15] (parseVersion "15.preview.1")
        , assertEqual "rank desktop before engine and newer first" [desktop15, desktop14, engine16] (sortInstallations [engine16, desktop14, desktop15])
        , assertEqual "CLI environment command" (Right (EnvironmentCommand False)) (parseCliArguments ["env", "show"])
        , assertEqual "CLI environment probe" (Right (EnvironmentCommand True)) (parseCliArguments ["env", "show", "--probe"])
        , assertEqual
            "CLI kernel command"
            (Right (KernelCommand (InlineSource "2+2") (Just "/tmp") True True))
            ( parseCliArguments
                [ "kernel", "eval", "--front-end", "--code", "2+2"
                , "--working-directory", "/tmp", "--require-success"
                ]
            )
        , assertLeft
            "CLI kernel requires source"
            (parseCliArguments ["kernel", "eval", "--front-end"])
        , assertEqual
            "CLI FrontEnd run"
            (Right (FrontEndCommand (RunFrontEndCommand "CreateDocument[]" False True)))
            (parseCliArguments ["frontend", "run", "--require-success", "--no-wrap", "--code", "CreateDocument[]"])
        , assertEqual
            "CLI FrontEnd notebook"
            (Right (FrontEndCommand (OpenFrontEndNotebookCommand "demo.nb" False)))
            (parseCliArguments ["frontend", "open-notebook", "--file", "demo.nb"])
        , assertEqual
            "CLI FrontEnd documentation"
            (Right (FrontEndCommand (OpenFrontEndDocumentationCommand "paclet:ref/NotebookGet" Nothing True)))
            (parseCliArguments ["frontend", "open-doc", "paclet:ref/NotebookGet", "--require-success"])
        , assertEqual
            "CLI FrontEnd documentation index"
            (Right (FrontEndCommand (OpenFrontEndDocumentationCommand "Foo" (Just "docs.sqlite3") False)))
            (parseCliArguments ["frontend", "open-doc", "Foo", "--index-path", "docs.sqlite3"])
        , assertEqual
            "CLI FrontEnd token"
            (Right (FrontEndCommand (ExecuteFrontEndTokenCommand "EvaluateCells" (Just "demo.nb") False)))
            (parseCliArguments ["frontend", "token", "EvaluateCells", "--file", "demo.nb"])
        ]
  and <$> sequence checks

checkDocumentationIndex :: IO Bool
checkDocumentationIndex = withTemporaryDirectory "tungsten-docs" $ \temporary -> do
  installation <- discoverInstallation
  let docsRoot = temporary </> "ReferencePages" </> "Symbols"
      fooPath = docsRoot </> "Foo.nb"
      barPath = docsRoot </> "Bar.nb"
      indexPath = temporary </> "docs.sqlite3"
      configured =
        installation
          { installationDocsRoots = [temporary]
          , installationDefaultIndexPath = indexPath
          }
  createDirectoryIfMissing True docsRoot
  TextIO.writeFile
    fooPath
    "Notebook[{Cell[\"Foo\", \"ObjectName\"], Cell[\"Foo computes a symbolic bar.\", \"Usage\"]}, WindowTitle->Foo]\n"
  TextIO.writeFile
    barPath
    "Notebook[{Cell[\"Bar\", \"ObjectName\"], Cell[\"Bar transforms a notebook.\", \"Usage\"]}, WindowTitle->Bar]\n"
  built <- buildDocumentationIndex configured Nothing
  filenameHits <- searchDocumentation configured "Foo" (Just indexPath) 5 False
  contentHits <- searchDocumentation configured "symbolic" (Just indexPath) 5 False
  bar <- readDocumentation configured "paclet:ref/Bar" (Just indexPath) False
  resolved <- resolveDocumentationIdentifier configured "Foo" (Just indexPath)
  checks <- sequence
    [ assertEqual "documentation index destination" (Right indexPath) built
    , assertEqual
        "documentation filename search"
        (Right ["paclet:ref/Foo"])
        (map documentationHitPaclet <$> filenameHits)
    , assertEqual
        "documentation FTS content search"
        (Right ["paclet:ref/Foo"])
        (map documentationHitPaclet <$> contentHits)
    , assertEqual "documentation read title" (Right "Bar") (documentationTitle <$> bar)
    , assertEqual
        "documentation read body"
        (Right True)
        ((Text.isInfixOf "notebook" . Text.toLower . documentationText) <$> bar)
    , assertEqual "documentation identifier resolution" (Right "paclet:ref/Foo") resolved
    ]
  pure (and checks)

withTemporaryDirectory :: String -> (FilePath -> IO value) -> IO value
withTemporaryDirectory prefix = bracket create removeDirectoryRecursive
 where
  create = do
    directory <- getTemporaryDirectory
    (path, handle) <- openTempFile directory prefix
    hClose handle
    removeFile path
    createDirectory path
    pure path

checkParserCorpus :: IO Bool
checkParserCorpus = withTemporaryDirectory "tungsten-parser-corpus" $ \corpusRoot -> do
  let githubRoot = corpusRoot </> "github" </> "sample"
      notebookRoot = corpusRoot </> "notebookarchive"
  createDirectoryIfMissing True githubRoot
  createDirectoryIfMissing True notebookRoot
  TextIO.writeFile (githubRoot </> "expr.wl") "1 + 2 x"
  TextIO.writeFile (githubRoot </> "bad.wl") "x @= 1"
  TextIO.writeFile (githubRoot </> "notes.txt") "skip"
  TextIO.writeFile (notebookRoot </> "sample.nb") "Notebook[{Cell[\"Hello\", \"Text\"]}]"
  discovery <- discoverCorpusFiles corpusRoot [] [] ["**/bad.wl"] Nothing False 0
  filtered <- discoverCorpusFiles corpusRoot ["wl"] ["github/*"] [] (Just 1) False 0
  attempts <- case discovery of
    Left _ -> pure []
    Right files -> traverse (\file -> (corpusFileRelativePath file,) <$> parseCorpusFile file "input" (Just 2097152) 2000) files
  oversized <- case discovery of
    Right (file : _) -> parseCorpusFile file "input" (Just 0) 2000
    _ -> pure (ParserAttempt "tungsten" "failure" Nothing (Just "MissingFixture") Nothing Map.empty)
  installation <- discoverInstallation
  unavailableAttempts <- case discovery of
    Right (file : _) ->
      parseFilesWithWolframKernel installation {installationKernelCli = Nothing} [file] 2000
    _ -> pure Map.empty
  let decodedBatch = case discovery of
        Right (file : _) ->
          let attempt =
                JsonObject
                  ( Map.fromList
                      [ ("elapsed_ms", JsonNumber "1.25")
                      , ("parser", JsonString "wolfram")
                      , ("status", JsonString "success")
                      , ("summary", JsonObject (Map.singleton "leaf_count" (JsonNumber "3")))
                      ]
                  )
              payload =
                JsonArray
                  [ JsonObject
                      ( Map.fromList
                          [ ("attempt", attempt)
                          , ("path", JsonString (Text.pack (corpusFilePath file)))
                          ]
                      )
                  ]
           in decodeWolframBatchAttempts [file] 2000 (wlString (encodeJson payload))
        _ -> Left "MissingFixture"
  runResult <-
    compareParserCorpus
      installation
      ( (defaultParserCorpusOptions corpusRoot)
          { parserCorpusOutputDirectory = Just (corpusRoot </> "results")
          , parserCorpusExcludeGlobs = ["**/bad.wl"]
          , parserCorpusCompareWolfram = False
          , parserCorpusTungstenWorkers = 2
          }
      )
  outputChecks <- case runResult of
    Left _ -> pure (False, False, False)
    Right run -> do
      summaryExists <- maybe (pure False) doesFileExist (Map.lookup "summary" (parserCorpusRunOutputFiles run))
      resultsExist <- maybe (pure False) doesFileExist (Map.lookup "results_jsonl" (parserCorpusRunOutputFiles run))
      reportExists <- maybe (pure False) doesFileExist (Map.lookup "report" (parserCorpusRunOutputFiles run))
      pure (summaryExists, resultsExist, reportExists)
  let relativePaths = map corpusFileRelativePath (either (const []) id discovery)
      attemptStatuses = [(path, parserAttemptStatus attempt) | (path, attempt) <- attempts]
      filteredPaths = map corpusFileRelativePath (either (const []) id filtered)
      success = ParserAttempt "tungsten" "success" Nothing Nothing Nothing Map.empty
      failure = ParserAttempt "wolfram" "failure" Nothing (Just "ParseFailure") Nothing Map.empty
  checks <- sequence
    [ assertEqual
        "parser corpus deterministic discovery"
        ["github/sample/expr.wl", "notebookarchive/sample.nb"]
        relativePaths
    , assertEqual
        "parser corpus include/extension/max filters"
        ["github/sample/bad.wl"]
        filteredPaths
    , assertEqual
        "parser corpus local parse attempts"
        [("github/sample/expr.wl", "success"), ("notebookarchive/sample.nb", "success")]
        attemptStatuses
    , assertEqual "parser corpus oversized skip" "skipped" (parserAttemptStatus oversized)
    , assertEqual "parser corpus outcome classification" "tungsten_only_success" (classifyParserOutcome success failure)
    , assertEqual
        "parser corpus unavailable kernel attempts"
        [Just "KernelNotFound"]
        (map parserAttemptErrorType (Map.elems unavailableAttempts))
    , assertEqual
        "parser corpus quoted Wolfram batch decoding"
        (Right ["success"])
        (map parserAttemptStatus . Map.elems <$> decodedBatch)
    , assertEqual "parser corpus summary/result/report outputs" (True, True, True) outputChecks
    , assertEqual
        "parser corpus local comparison outcomes"
        (Right ["skipped", "skipped"])
        (map parserCorpusOutcome . parserCorpusRunResults <$> runResult)
    ]
  pure (and checks)

checkLicensing :: IO Bool
checkLicensing = do
  let source = "% Wolfram mathpass\nentry-a\nentry-b\nentry-a\nentry-b\nentry-c\n"
      inspection = inspectMathpassText (Just "mathpass") source
      checks =
        [ assertEqual "mathpass path" (Just "mathpass") (mathpassPath inspection)
        , assertEqual "mathpass header" True (mathpassHeaderPresent inspection)
        , assertEqual "mathpass original lines" 6 (mathpassOriginalLineCount inspection)
        , assertEqual "mathpass unique entries" 3 (mathpassUniqueEntryCount inspection)
        , assertEqual "mathpass duplicates" 2 (mathpassDuplicateEntryCount inspection)
        , assertEqual
            "stable mathpass deduplication"
            "% Wolfram mathpass\nentry-a\nentry-b\nentry-c\n"
            (deduplicateMathpassText source)
        , assertEqual "missing mathpass inspection" emptyMathpassInspection (inspectMathpassText Nothing "")
        ]
  and <$> sequence checks

checkKernelRunner :: IO Bool
checkKernelRunner = do
  installation <- discoverInstallation
  missing <-
    evaluateKernelText
      installation {installationKernelCli = Nothing, installationMathpass = Nothing}
      "2+2"
      Nothing
      False
  missingCheck <- assertEqual
    "missing kernel result"
    (127, Just "KernelNotFound", False)
    (kernelExitCode missing, kernelFailureType missing, kernelEvaluationAvailable missing)
  wrapperCheck <- do
    let wrapper = buildWrapperScript "C:\\input.wl" "C:\\result.json" "C:\\work" True
    first <- assertEqual "kernel wrapper uses front end" True ("evalExpr = If[True" `Text.isInfixOf` wrapper)
    second <- assertEqual "kernel wrapper normalizes paths" True ("\"C:/input.wl\"" `Text.isInfixOf` wrapper)
    third <- assertEqual "kernel wrapper captures Print" True ("CapturedPrint" `Text.isInfixOf` wrapper)
    pure (and [first, second, third])
  processCheck <- if os == "mingw32"
    then pure True
    else withFakeKernel $ \kernelPath -> do
      result <-
        evaluateKernelText
          installation {installationKernelCli = Just kernelPath, installationMathpass = Nothing}
          "2+2"
          Nothing
          False
      first <- assertEqual "fake kernel exit" 0 (kernelExitCode result)
      second <- assertEqual "fake kernel success" (Just True) (kernelSuccess result)
      third <- assertEqual "fake kernel result" (Just "4") (kernelResult result)
      fourth <- assertEqual "fake kernel output" ["printed"] (kernelOutput result)
      fifth <- assertEqual "fake kernel stdout" "fake stdout" (kernelStdout result)
      sixth <- assertEqual "fake kernel stderr" "fake stderr" (kernelStderr result)
      seventh <- assertEqual "fake kernel payload availability" True (kernelEvaluationAvailable result)
      eighth <- assertEqual "fake kernel license wait" (Just True) (kernelLicenseWaitSatisfied result)
      ninth <- assertEqual "fake kernel cleaned-process payload" [] (kernelCleanedTungstenProcesses result)
      tenth <- assertEqual "fake kernel observed-process payload" [] (kernelObservedWolframProcesses result)
      eleventh <- assertEqual "fake kernel launch gate measured" True (kernelLaunchGateWaitSeconds result >= 0)
      pure (and [first, second, third, fourth, fifth, sixth, seventh, eighth, ninth, tenth, eleventh])
  pure (missingCheck && wrapperCheck && processCheck)

withFakeKernel :: (FilePath -> IO value) -> IO value
withFakeKernel = bracket create removeFile
 where
  create = do
    directory <- getTemporaryDirectory
    (path, handle) <- openTempFile directory "tungsten-fake-kernel.sh"
    hSetEncoding handle utf8
    TextIO.hPutStr
      handle
      "#!/bin/sh\nprintf '%s' '{\"success\":true,\"failure_type\":null,\"result\":\"4\",\"result_head\":\"Integer\",\"messages\":[],\"messages_text\":[],\"output\":[\"printed\"],\"timing\":0.01,\"absolute_timing\":0.02,\"license_processes\":1,\"max_license_processes\":2}' > \"$TUNGSTEN_KERNEL_RESULT_PATH\"\nprintf 'fake stdout'\nprintf 'fake stderr' >&2\n"
    hClose handle
    permissions <- getPermissions path
    setPermissions path permissions {executable = True}
    pure path

checkFrontEndBuilders :: IO Bool
checkFrontEndBuilders = do
  let checks =
        [ assertEqual
            "FrontEnd notebook path escaping"
            "NotebookOpen[\"C:/Users/A\\\"B/demo.nb\"]"
            (openNotebookCode "C:\\Users\\A\"B\\demo.nb")
        , assertEqual
            "FrontEnd documentation escaping"
            "NotebookLocate[\"paclet:ref/NotebookGet\"]"
            (openDocumentationCode "paclet:ref/NotebookGet")
        , assertEqual
            "FrontEnd token without notebook"
            "FrontEndTokenExecute[\"EvaluateCells\"]"
            (frontEndTokenCode "EvaluateCells" Nothing)
        , assertEqual
            "FrontEnd token with notebook"
            "nb = NotebookOpen[\"C:/demo.nb\"]; FrontEndTokenExecute[nb, \"Evaluator`EvaluateNotebook\"]; nb"
            (frontEndTokenCode "Evaluator`EvaluateNotebook" (Just "C:\\demo.nb"))
        , assertEqual "FrontEnd probe closes hidden notebook" True ("NotebookClose" `Text.isInfixOf` frontEndProbeCode)
        ]
  and <$> sequence checks

checkNotebookModel :: IO Bool
checkNotebookModel = do
  let source =
        "Notebook[{Cell[\"Demo\", \"Title\", CellID -> 1], Cell[CellGroupData[{Cell[\"1+2\", \"Input\"], Cell[BoxData[RowBox[{\"1\", \"+\", \"2\"}]], \"Output\"]}, Open]]}, WindowTitle -> \"Demo\"]"
      document = expectRight (parseNotebook source)
      records = flattenCells document
      created = createNotebook (Just "Generated") [("Title", "Generated"), ("Input", "2+2")]
      checks =
        [ assertEqual "notebook cell count" 3 (cellCount document)
        , assertEqual "notebook group count" 1 (groupCount document)
        , assertEqual "notebook paths" [[0], [1, 0], [1, 1]] (map cellRecordPath records)
        , assertEqual "notebook styles" [Just "Title", Just "Input", Just "Output"] (map cellRecordStyle records)
        , assertEqual "notebook previews" ["Demo", "1+2", "RowBox[List[\"1\", \"+\", \"2\"]]"] (map cellRecordPreview records)
        , assertEqual "notebook render round trip" (Right document) (parseNotebook (renderNotebook document))
        , assertEqual "created notebook cell count" 2 (cellCount created)
        , assertEqual
            "created notebook option"
            [Call (Symbol "Rule") [Symbol "WindowTitle", String "Generated"]]
            (notebookOptions created)
        ]
  and <$> sequence checks

checkNotebookErrors :: IO Bool
checkNotebookErrors = do
  first <- assertLeft "reject non-notebook source" (parseNotebook "List[1, 2]")
  second <- assertLeft "reject notebook without item list" (parseNotebook "Notebook[1]")
  third <- assertLeft "reject malformed notebook syntax" (parseNotebook "Notebook[{")
  pure (and [first, second, third])

checkNotebookPatches :: IO Bool
checkNotebookPatches = do
  let source =
        "Notebook[{Cell[\"Demo\", \"Title\"], Cell[CellGroupData[{Cell[\"old\", \"Input\"], Cell[\"result\", \"Output\"]}, Open]]}, WindowTitle -> \"Before\"]"
      document = expectRight (parseNotebook source)
      patches =
        [ AppendCell Nothing (NotebookCell (String "Tail") (Just "Text") [])
        , InsertCell (Just [1]) 1 (NotebookCell (String "Inserted") (Just "Text") [])
        , ReplaceCell [0] Nothing (String "Retitled")
        , DeleteItem [1, 0]
        , SetNotebookOption "WindowTitle" (String "After")
        ]
      patched = expectRight (applyNotebookPatches patches document)
      records = flattenCells patched
      checks =
        [ assertEqual "patched notebook title" (Just "After") (notebookTitle patched)
        , assertEqual "patched notebook paths" [[0], [1, 0], [1, 1], [2]] (map cellRecordPath records)
        , assertEqual "replacement preserves style" [Just "Title"] (take 1 (map cellRecordStyle records))
        , assertEqual "patched notebook previews" ["Retitled", "Inserted", "result", "Tail"] (map cellRecordPreview records)
        , assertLeft
            "reject patch container through a cell"
            (applyNotebookPatches [AppendCell (Just [0]) (NotebookCell (String "x") Nothing [])] document)
        , assertLeft "reject replacing a group" (applyNotebookPatches [ReplaceCell [1] Nothing (String "x")] document)
        , assertLeft
            "reject out-of-range insertion"
            (applyNotebookPatches [InsertCell Nothing 99 (NotebookCell (String "x") Nothing [])] document)
        ]
  and <$> sequence checks

checkFullForms :: IO Bool
checkFullForms = do
  let rootValue = expectRight (root [-2, 0, 1] 0 0)
      sparseValue =
        expectRight
          ( sparseArray
              [3, 4]
              [SparseEntry [1, 2] (String "value")]
              (Integer 0)
          )
      cases =
        [ ("symbol", "System`Plus", fullForm (Symbol "System`Plus"))
        , ("escaped symbol", "\\[Alpha]", fullForm (Symbol "α"))
        , ("arbitrary integer", "123456789012345678901234567890", fullForm (Integer 123456789012345678901234567890))
        , ("rational", "Rational[-2, 3]", fullForm (Rational (-2) 3))
        , ("real lexeme", "1.2300`40", fullForm (Real "1.2300`40"))
        , ("complex", "Complex[Rational[1, 2], -3]", fullForm (Complex (Rational 1 2) (Integer (-3))))
        , ("string", "\"a\\\"b\\\\c\\n\"", fullForm (String "a\"b\\c\n"))
        , ("byte array", "ByteArray[\"AAH+/w==\"]", fullForm (ByteArray (BS.pack [0, 1, 254, 255])))
        , ("call", "f[x, List[1, 2]]", fullForm (Call (Symbol "f") [Symbol "x", Call (Symbol "List") [Integer 1, Integer 2]]))
        , ("root", "Root[Function[Plus[-2, Power[Slot[1], 2]]], 1, 0]", fullForm rootValue)
        , ("sparse", "SparseArray[List[Rule[List[1, 2], \"value\"]], List[3, 4]]", fullForm sparseValue)
        ]
  and <$> traverse (\(label, expected, actual) -> assertEqual label expected actual) cases

checkSmartConstructors :: IO Bool
checkSmartConstructors = do
  let normalized = expectRight (rational (-6) (-8))
      checks =
        [ assertEqual "rational normalization" (Rational 3 4) normalized
        , assertLeft "zero denominator" (rational 1 0)
        , assertLeft "constant root" (root [1] 0 0)
        , assertLeft "invalid sparse coordinate" (sparseArray [2] [SparseEntry [3] (Integer 1)] (Integer 0))
        , assertLeft "duplicate sparse coordinate" (sparseArray [2] [SparseEntry [1] (Integer 1), SparseEntry [1] (Integer 2)] (Integer 0))
        , assertEqual "complex is atomic" [] (arguments (Complex (Integer 1) (Integer 2)))
        , assertEqual "root arguments" [Call (Symbol "Function") [Call (Symbol "Plus") [Integer (-2), Call (Symbol "Slot") [Integer 1]]], Integer 1, Integer 0] (arguments (expectRight (root [-2, 1] 0 0)))
        ]
  and <$> sequence checks

checkExpressionJsonRoundTrips :: IO Bool
checkExpressionJsonRoundTrips = do
  let expressions =
        [ Symbol "Global`x"
        , Integer 999999999999999999999999999999999999999999
        , Rational (-7) 13
        , Real "6.02214076*^23`8"
        , Complex (Integer 2) (Real "-0.0")
        , String "snowman ☃\n"
        , ByteArray (BS.pack [0 .. 255])
        , Call (Symbol "f") [Integer 1, Symbol "x"]
        , expectRight (root [1, 0, 1] 1 2)
        , expectRight (sparseArray [2] [SparseEntry [2] (Rational 1 3)] (Integer 0))
        ]
  and
    <$> traverse
      (\expression -> assertEqual ("expression JSON round trip: " <> fullForm expression) (Right expression) (exprFromJson (exprToJson expression)))
      expressions

checkJsonCodec :: IO Bool
checkJsonCodec = do
  let source = "{\"z\":-0.25e+12,\"a\":[true,null,\"snowman \\u2603\",\"face \\uD83D\\uDE00\"]}"
      expected =
        JsonObject
          ( Map.fromList
              [ ("a", JsonArray [JsonBool True, JsonNull, JsonString "snowman ☃", JsonString "face 😀"])
              , ("z", JsonNumber "-0.25e+12")
              ]
          )
      parsed = parseJson source
      encoded = encodeJson expected
  first <- assertEqual "JSON parse with numeric lexeme and surrogates" (Right expected) parsed
  second <- assertEqual "JSON deterministic encoding" "{\"a\":[true,null,\"snowman ☃\",\"face 😀\"],\"z\":-0.25e+12}" encoded
  third <- assertEqual "JSON codec round trip" (Right expected) (parseJson encoded)
  fourth <- assertLeft "reject leading-zero JSON number" (parseJson "01")
  fifth <- assertLeft "reject non-JSON whitespace" (parseJson "\fnull")
  pure (and [first, second, third, fourth, fifth])

checkProtocol :: IO Bool
checkProtocol = do
  let requestLine =
        encodeJson
          ( JsonObject
              ( Map.fromList
                  [ ("id", JsonString "request-7")
                  , ("command", JsonString "full_form")
                  , ("expression", exprToJson (Call (Symbol "Plus") [Integer 1, Symbol "x"]))
                  ]
              )
          )
      request = expectRight (decodeRequestLine requestLine)
      response = handleProtocolRequest request
      encoded = encodeResponseLine response
      decodedResponse = parseJson (withoutNewline encoded)
      expectedResult =
        JsonObject
          ( Map.fromList
              [ ("full_form", JsonString "Plus[1, x]")
              , ("expression", exprToJson (Call (Symbol "Plus") [Integer 1, Symbol "x"]))
              ]
          )
      expectedResponse =
        JsonObject
          ( Map.fromList
              [ ("id", JsonString "request-7")
              , ("command", JsonString "full_form")
              , ("success", JsonBool True)
              , ("result", expectedResult)
              ]
          )
  assertEqual "JSON-lines full_form request" (Right expectedResponse) decodedResponse

checkProtocolErrors :: IO Bool
checkProtocolErrors = do
  first <- assertLeft "protocol command must be a string" (decodeRequestLine "{\"command\":42}")
  let request =
        ProtocolRequest
          { protocolRequestId = Just (JsonNumber "9")
          , protocolCommand = "unknown"
          , protocolExpression = Nothing
          , protocolSource = Nothing
          , protocolForm = Nothing
          }
      expected =
        ProtocolFailure
          { protocolResponseId = Just (JsonNumber "9")
          , protocolResponseCommand = "unknown"
          , protocolError = "unsupported command: unknown"
          }
  second <- assertEqual "unknown protocol command" expected (handleProtocolRequest request)
  third <- assertLeft "protocol source must be a string" (decodeRequestLine "{\"command\":\"parse\",\"source\":42}")
  pure (first && second && third)

checkParserEvaluatorProtocol :: IO Bool
checkParserEvaluatorProtocol = do
  let parseRequest = expectRight (decodeRequestLine "{\"id\":1,\"command\":\"parse\",\"form\":\"input\",\"source\":\"1 + 2 x\"}")
      evaluateRequest = expectRight (decodeRequestLine "{\"id\":2,\"command\":\"evaluate\",\"source\":\"Total[Range[5]]\"}")
      sessionEvaluateRequest = expectRight (decodeRequestLine "{\"id\":3,\"command\":\"evaluate\",\"source\":\"x = 2; x^3\"}")
      isolatedEvaluateRequest = expectRight (decodeRequestLine "{\"id\":4,\"command\":\"evaluate\",\"source\":\"x\"}")
      parseResponse = handleProtocolRequest parseRequest
      evaluateResponse = handleProtocolRequest evaluateRequest
      sessionEvaluateResponse = handleProtocolRequest sessionEvaluateRequest
      isolatedEvaluateResponse = handleProtocolRequest isolatedEvaluateRequest
  first <- case parseResponse of
    ProtocolSuccess {protocolResult = JsonObject result} ->
      case Map.lookup "full_form" result of
        Just (JsonString value) -> assertEqual "protocol parse result" "Plus[1, Times[2, x]]" value
        other -> assertEqual "protocol parse result shape" (Just (JsonString "expected")) other
    other -> assertEqual "protocol parse response" True (isSuccess other)
  second <- case evaluateResponse of
    ProtocolSuccess {protocolResult = JsonObject outer} ->
      case Map.lookup "result" outer of
        Just (JsonObject result) ->
          case Map.lookup "full_form" result of
            Just (JsonString value) -> assertEqual "protocol evaluation result" "15" value
            other -> assertEqual "protocol evaluation result shape" (Just (JsonString "expected")) other
        other -> assertEqual "protocol evaluation outer shape" (Just (JsonString "expected")) other
    other -> assertEqual "protocol evaluate response" True (isSuccess other)
  third <- assertProtocolEvaluation "protocol session-backed evaluation" "8" sessionEvaluateResponse
  fourth <- assertProtocolEvaluation "protocol request session isolation" "x" isolatedEvaluateResponse
  pure (and [first, second, third, fourth])
 where
  assertProtocolEvaluation label expected response = case response of
    ProtocolSuccess {protocolResult = JsonObject outer} ->
      case Map.lookup "result" outer of
        Just (JsonObject result) ->
          case Map.lookup "full_form" result of
            Just (JsonString value) -> assertEqual label expected value
            other -> assertEqual (label <> " result shape") (Just (JsonString "expected")) other
        other -> assertEqual (label <> " outer shape") (Just (JsonString "expected")) other
    other -> assertEqual (label <> " response") True (isSuccess other)
  isSuccess ProtocolSuccess {} = True
  isSuccess ProtocolFailure {} = False

withoutNewline :: Text -> Text
withoutNewline value = case Text.unsnoc value of
  Just (prefix, '\n') -> prefix
  _ -> value

assertEqual :: (Eq value, Show value) => Text -> value -> value -> IO Bool
assertEqual label expected actual
  | expected == actual = pure True
  | otherwise = do
      TextIO.putStrLn ("FAIL: " <> label)
      putStrLn ("  expected: " ++ show expected)
      putStrLn ("  actual:   " ++ show actual)
      pure False

assertLeft :: Show value => Text -> Either error value -> IO Bool
assertLeft _ (Left _) = pure True
assertLeft label (Right value) = do
  TextIO.putStrLn ("FAIL: " <> label <> " unexpectedly succeeded")
  print value
  pure False

expectRight :: Show error => Either error value -> value
expectRight (Right value) = value
expectRight (Left failure) = error ("unexpected Left: " ++ show failure)
