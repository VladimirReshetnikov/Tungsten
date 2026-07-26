{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.Char (chr)
import Data.IORef
  ( atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
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
import Text.Read (readMaybe)
import Tungsten.Cli
import qualified Tungsten.ArrayTests as ArrayTests
import qualified Tungsten.CollectionExtensionsTests as CollectionExtensionsTests
import qualified Tungsten.NumericAlgebraTests as NumericAlgebraTests
import Tungsten.Assistant
import Tungsten.DocsIndex
import qualified Tungsten.DistributionTests as DistributionTests
import Tungsten.Expression
import Tungsten.Evaluate
import Tungsten.Discovery
import Tungsten.Frontend
import Tungsten.InlineBoxes
import qualified Tungsten.IntervalTests as IntervalTests
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.Licensing
import Tungsten.NamedCharacters
import Tungsten.Notebook
import Tungsten.Parser
import Tungsten.ParserCorpus
import Tungsten.Repl
import Tungsten.Session
import qualified Tungsten.StatisticsTests as StatisticsTests
import qualified Tungsten.SystemSymbols as SystemSymbols
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
  , checkInputForms
  , checkAssistant
  , checkWolframStrings
  , checkNamedCharacters
  , checkSystemSymbols
  , checkInlineBoxes
  , checkFullFormParser
  , checkFullFormParserErrors
  , checkInputFormParser
  , checkInputFormParserErrors
  , checkEvaluator
  , checkEvaluatorErrors
  , ArrayTests.checkArrayEvaluator
  , CollectionExtensionsTests.checkCollectionExtensions
  , DistributionTests.checkDistributionEvaluator
  , IntervalTests.checkIntervalEvaluator
  , StatisticsTests.checkStatisticsEvaluator
  , NumericAlgebraTests.checkNumericAlgebraEvaluator
  , checkCliArguments
  , checkNotebookModel
  , checkNotebookErrors
  , checkNotebookPatches
  , checkNotebookPatchJson
  , checkEvaluationSession
  , checkSessionTimingRuntime
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

checkSystemSymbols :: IO Bool
checkSystemSymbols = do
  let attributes = SystemSymbols.systemSymbolAttributes
      expectedPlus =
        Set.fromList
          [ SystemSymbols.Flat
          , SystemSymbols.Listable
          , SystemSymbols.NumericFunction
          , SystemSymbols.OneIdentity
          , SystemSymbols.Orderless
          , SystemSymbols.Protected
          ]
      expectedFunction =
        Set.fromList [SystemSymbols.HoldAll, SystemSymbols.Protected]
      expectedI =
        Set.fromList
          [ SystemSymbols.Locked
          , SystemSymbols.Protected
          , SystemSymbols.ReadProtected
          ]
  checks <- sequence
    [ assertEqual "System symbol catalog count" 7941 SystemSymbols.systemSymbolCount
    , assertEqual "System symbol catalog name count" 7941 (length SystemSymbols.systemSymbolNames)
    , assertEqual "System symbol bare lookup" (Just expectedPlus) (attributes "Plus")
    , assertEqual "System symbol qualified lookup" (Just expectedPlus) (attributes "System`Plus")
    , assertEqual "System symbol rejects Global context" Nothing (attributes "Global`Plus")
    , assertEqual "System symbol Function attributes" (Just expectedFunction) (attributes "Function")
    , assertEqual "System symbol I attributes" (Just expectedI) (attributes "I")
    , assertEqual "Python-only System symbol exists" True (SystemSymbols.isSystemSymbol "ConfirmationFailed")
    , assertEqual "Python-only System symbol attributes" (Just Set.empty) (attributes "ConfirmationFailed")
    , assertEqual "reserved Stub spelling" "Stub" (SystemSymbols.symbolAttributeName SystemSymbols.Stub)
    , assertEqual "reserved Temporary spelling" "Temporary" (SystemSymbols.symbolAttributeName SystemSymbols.Temporary)
    ]
  pure (and checks)

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
        , ("comment-only input", "(* comment *)", Symbol "Null")
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
        , ("numeric adjacency", "2x", "Times[2, x]")
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
        , ("span assignment rhs", "x = 1 ;; 3", "Set[x, Span[1, 3]]")
        , ("span assignment lhs", "a ;; b = 3", "Set[Span[a, b], 3]")
        , ("span pure function", "a ;; b &", "Function[Span[a, b]]")
        , ("completed span adjacency", "a ;; b ;; c ;; d", "Times[Span[a, b, c], Span[1, d]]")
        , ("right associative assignment", "a = b = 2", "Set[a, Set[b, 2]]")
        , ("delayed assignment", "f[x_] := x^2", "SetDelayed[f[Pattern[x, Blank[]]], Power[x, 2]]")
        , ("right associative tagged assignment", "f /: h[f[x_]] = a = b", "TagSet[f, h[f[Pattern[x, Blank[]]]], Set[a, b]]")
        , ("tagged delayed lhs condition", "f /: h[f[x_]] /; x > 0 := rhs", "TagSetDelayed[f, Condition[h[f[Pattern[x, Blank[]]]], Greater[x, 0]], rhs]")
        , ("tagged spaced unset continuation", "f /: h[f[x_]] = . + y", "Plus[TagUnset[f, h[f[Pattern[x, Blank[]]]]], y]")
        , ("tagged target nested unset", "f /: g[x =.] = rhs", "TagSet[f, g[Unset[x]], rhs]")
        , ("nested tagged prefix", "f /: g /: lhs = rhs", "TagSet[TagSetPrefix[f, g], lhs, rhs]")
        , ("factorials", "n! + n!!", "Plus[Factorial[n], Factorial2[n]]")
        , ("association", "<|a -> 1, b :> 2|>", "Association[Rule[a, 1], RuleDelayed[b, 2]]")
        , ("pattern test", "x_?IntegerQ", "PatternTest[Pattern[x, Blank[]], IntegerQ]")
        , ("left-associated pattern tests", "x_?f?g", "PatternTest[PatternTest[Pattern[x, Blank[]], f], g]")
        , ("optional blank", "{_., x_.}", "List[Optional[Blank[]], Optional[Pattern[x, Blank[]]]]")
        , ("non-symbol blank adjacency", "{1_, f[x]_, %_, x::arg_}", "List[Times[1, Blank[]], Times[f[x], Blank[]], Times[Out[], Blank[]], Times[MessageName[x, \"arg\"], Blank[]]]")
        , ("anonymous function call head", "a &[x]", "Function[a][x]")
        , ("comment-only input", "(* comment *)", "Null")
        , ("line continuation", "a\\\n+b", "Plus[a, b]")
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
  fourth <- assertLeft "reject optional sequence blank" (parseInputForm "x__.")
  fifth <- assertLeft "reject optional null-sequence blank" (parseInputForm "x___.")
  sixth <- assertLeft "reject optional typed blank" (parseInputForm "_Integer.")
  pure (and [first, second, third, fourth, fifth, sixth])

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
        , ("held function sequence normalization", "{Function[Sequence[x, x + x]][a], Function[x, Sequence[x, x]][a]}", "List[Times[2, a], a]")
        , ("qualified held construction metadata", "{System`Hold[System`Sequence[a, b]], System`HoldComplete[Head[x]], System`RuleDelayed[Head[1], Head[x], Head[y]]}", "List[System`Hold[a, b], System`HoldComplete[Head[x]], System`RuleDelayed[Integer, Head[x], Head[y]]]")
        , ("qualified function bodies stay held until application", "System`Function[Head[#]][1]", "Integer")
        , ("SequenceHold slot sequence substitution", "Function[Null, Hold[##], SequenceHold][a, Sequence[b, c]]", "Hold[a, b, c]")
        , ("factorials", "6! + 6!!", "768")
        , ("numeric comparison", "1 < 2 <= 2", "True")
        , ("numeric inequality", "Unequal[1, 2, 1]", "False")
        , ("Boolean reduction", "True && !False", "True")
        , ("conditional branch", "If[2 > 1, 20 + 22, 0]", "42")
        , ("Which selects held branches and retains unknown tails", "{Which[False, a, True, 1+2], Which[False, a, False, b], Which[x, 1+2, True, 3+4]}", "List[3, Null, Which[x, Plus[1, 2], True, Plus[3, 4]]]")
        , ("Switch matches held forms and retains unmatched syntax", "{Switch[1+2, 3, a, _, b], Switch[a, _Integer, 1, _Symbol, 2], Switch[1+2, 4, a]}", "List[a, 2, Switch[3, 4, a]]")
        , ("Piecewise evaluates unknown values and reconstructs raw cases", "{Piecewise[{{1+2, True}, {bad, True}}], Piecewise[{{1, False}, {2, False}}], Piecewise[{{1+2, x}, {3+4, y}}, 5+6], Piecewise[{{1, False}, {2, x}, {2+2, True}}]}", "List[3, 0, Piecewise[List[List[3, x], List[7, y]], 11], Piecewise[List[List[2, x]], 4]]")
        , ("ReleaseHold removes exactly one supported wrapper", "{ReleaseHold[Hold[1+2]], ReleaseHold[HoldComplete[1+2]], ReleaseHold[HoldForm[1+2]], ReleaseHold[Unevaluated[1+2]], ReleaseHold[Hold[Hold[1+2]]]}", "List[3, 3, 3, 3, Hold[Plus[1, 2]]]")
        , ("Inactive holds designators and collapses scalar atoms", "{Inactive[Plus], Inactive[Plus][1+2, 3+4], Inactive[3], Inactive[1+2], Inactive[Evaluate[1+2]]}", "List[Inactive[Plus], Inactive[Plus][3, 7], 3, Inactive[Plus[1, 2]], 3]")
        , ("Activate traverses holds and selectively removes wrappers", "{Activate[Inactive[Plus][1,2]], Activate[Hold[Inactive[Plus][1,2]]], Activate[Inactive[Plus][Inactive[Times][2,3],4], Times], Activate[Inactive[Plus][Inactive[Times][2,3],4], Plus], Activate[Inactive[Plus][Inactive[Times][2,3],4], _Symbol]}", "List[3, Hold[Plus[1, 2]], Inactive[Plus][6, 4], Plus[4, Inactive[Times][2, 3]], 10]")
        , ("IgnoringInactive recognizes qualified inactive wrappers", "{Switch[System`Inactive[f], IgnoringInactive[f], a, _, b], Activate[Inactive[System`Inactive[f]], IgnoringInactive[f]]}", "List[a, f]")
        , ("held builtin evaluation slots reduce qualified System calls", "{Which[System`Equal[1,1], a], Switch[System`Plus[1,2], 3, a], Piecewise[{{a, System`Equal[1,1]}}], ReleaseHold[Hold[System`Plus[1,2]]], Inactive[Evaluate[System`Plus[1,2]]], Activate[System`Inactive[System`Plus][1,2]]}", "List[a, a, a, 3, 3, 3]")
        , ("range", "Range[-2, 4, 2]", "List[-2, 0, 2, 4]")
        , ("total", "Total[{1, 2, 3, 4}]", "10")
        , ("accumulate", "Accumulate[{1, 2, 3, 4}]", "List[1, 3, 6, 10]")
        , ("list structure", "{First[{a, b}], Last[{a, b}], Rest[{a, b}], Most[{a, b}]} ", "List[a, b, List[b], List[a]]")
        , ("part", "{{a, b}, {c, d}}[[2, 1]]", "c")
        , ("part selector lists preserve heads", "{Part[f[a,b,c],{1,3}], Part[<|a->1,b->2,c->3|>,{2,1}]}", "List[f[a, c], Association[Rule[b, 2], Rule[a, 1]]]")
        , ("part nested all span and recursive selectors", "{Part[f[a,b],{{1},2}], Part[f[a,b,c],All], Part[f[a,b,c,d],2;;4;;2], Part[f[g[a,b],h[c,d]],All,2], Part[<|a->1,b->2,c->3|>,Span[1,2]]}", "List[f[a, b], f[a, b, c], f[b, d], f[b, d], Association[Rule[a, 1], Rule[b, 2]]]")
        , ("head and predicates", "{Head[1/2], AtomQ[1/2], ListQ[{x}], IntegerQ[2], NumberQ[2/3], StringQ[\"x\"]}", "List[Rational, True, True, True, True, True]")
        , ("string structural operations", "{Characters[\"abc\"], Characters[{\"ab\", \"c\"}], StringLength[{\"ab\", \"c\"}], StringJoin[{\"a\", {\"b\", \"c\"}}], StringInsert[\"abcd\", \"X\", {2, 4}], StringReverse[{\"ab\", \"cd\"}]}", "List[List[\"a\", \"b\", \"c\"], List[List[\"a\", \"b\"], List[\"c\"]], List[2, 1], \"abc\", \"aXbcXd\", List[\"ba\", \"dc\"]]")
        , ("string case repeat and padding", "{ToUpperCase[\"hello\"], ToLowerCase[\"WORLD\"], Capitalize[\"hello world\"], StringRepeat[\"ab\", 3], StringRepeat[\"ab\", 1, 5], StringPadLeft[\"abc\", 6, \"0\"], StringPadRight[\"abc\", 6, \"*\"]}", "List[\"HELLO\", \"world\", \"Hello world\", \"ababab\", \"ababa\", \"000abc\", \"abc***\"]")
        , ("string split riffle count and trim", "{StringSplit[\"a:b;c\", {\":\", \";\"}], StringSplit[\"  hello   world  \"], StringRiffle[{\"a\", \"b\", \"c\"}, {\"<\", \"+\", \">\"}], StringCount[\"abcabcabc\", \"a\"], StringTrim[\"abcXYZdef\", \"abc\"]}", "List[List[\"a\", \"b\", \"c\"], List[\"hello\", \"world\"], \"<a+b+c>\", 3, \"XYZdef\"]")
        , ("literal string predicates and operator form", "{StringContainsQ[{\"ab\", \"cd\"}, \"a\"], StringFreeQ[\"catalog\", \"7\"], StringStartsQ[\"abc\", \"a\"], StringEndsQ[\"abc\", \"c\"], StringMatchQ[\"abc\", \"abc\"], Select[{\"ab\", \"cd\", \"ba\"}, StringContainsQ[\"a\"]]}", "List[List[True, False], True, True, True, True, List[\"ab\", \"ba\"]]")
        , ("string selectors and literal positions", "{StringTake[\"abcdef\", {2, 5, 2}], StringTake[\"abc\", UpTo[5]], StringTake[{\"abc\", \"def\"}, 2], StringDrop[\"abcdef\", {2, 5, 2}], StringPosition[\"ababa\", {\"ba\", \"aba\"}], StringPosition[\"abc\", \"\"]}", "List[\"bd\", \"abc\", List[\"ab\", \"de\"], \"acef\", List[List[1, 3], List[2, 3], List[3, 5], List[4, 5]], List[List[1, 0], List[2, 1], List[3, 2], List[4, 3]]]")
        , ("byte array construction and structure", "{ByteArray[{65, 66, 67}], ByteArray[\"QUJD\"], ByteArrayQ[ByteArray[\"QUJD\"]], ByteArrayQ[{65, 66, 67}], Length[ByteArray[\"QUJD\"]], Normal[ByteArray[\"QUJD\"]]}", "List[ByteArray[\"QUJD\"], ByteArray[\"QUJD\"], True, False, 3, List[65, 66, 67]]")
        , ("character code and byte string encodings", "{ToCharacterCode[FromCharacterCode[{97, 233}]], ToCharacterCode[FromCharacterCode[{97, 233}], \"UTF-8\"], ToCharacterCode[FromCharacterCode[{97, 233}], \"ASCII\"], ToCharacterCode[FromCharacterCode[{97, 233}, \"ISO8859-1\"]], StringToByteArray[FromCharacterCode[{97, 233}], \"UTF-8\"], ToCharacterCode[ByteArrayToString[ByteArray[{97, 195, 169}], \"UTF-8\"]], ToCharacterCode[ByteArrayToString[ByteArray[{97, 162, 98}], \"UTF-8\"]], ByteArrayToString[{}]}", "List[List[97, 233], List[97, 195, 169], List[97, None], List[97, 233], ByteArray[\"YcOp\"], List[97, 233], List[97, 162, 98], \"\"]")
        , ("extended character encodings", "{ToCharacterCode[FromCharacterCode[{97, 233}], \"UTF-16LE\"], ToCharacterCode[FromCharacterCode[{97, 233}], \"UTF-32BE\"], ToCharacterCode[FromCharacterCode[{164}, \"ISO8859-15\"]], ToCharacterCode[FromCharacterCode[{128}, \"WindowsANSI\"]]}", "List[List[97, 0, 233, 0], List[0, 0, 0, 97, 0, 0, 0, 233], List[8364], List[8364]]")
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
        , ("zero-argument call depth and negative level", "{Depth[f[]], Level[f[], {-2}], Depth[<||>], Level[<||>, {-2}]}", "List[2, List[f[]], 2, List[Association[]]]")
        , ("level negative and positive traversal", "{Level[f[a, g[b]], -1], Level[f[a, g[b]], 2]}", "List[List[a, b, g[b]], List[a, b, g[b]]]")
        , ("level infinity and exact leaves", "{Level[f[a, g[b, c]], Infinity], Level[f[a, g[b]], {-1}]}", "List[List[a, b, c, g[b, c]], List[a, b]]")
        , ("level exact roots and ranges", "{Level[f[a, g[b]], {0}], Level[f[a, g[b]], {1, 2}], Level[f[a, g[b]], {2, -2}]}", "List[List[f[a, g[b]]], List[a, b, g[b]], List[]]")
        , ("level association values and false heads", "{Level[<|a -> x, b -> {y, z}|>, Infinity], Level[f[a, g[b]], 2, False]}", "List[List[x, y, z, List[y, z]], List[a, b, g[b]]]")
        , ("level list results remove nothing", "Level[Hold[Nothing], {-1}]", "List[]")
        , ("level exposes held expressions without reentry", "{Level[Hold[1 + 1], {1}], Level[Hold[f[1 + 1]], Infinity]}", "List[List[Plus[1, 1]], List[1, 1, Plus[1, 1], f[Plus[1, 1]]]]")
        , ("level structurally normalizes selected sequence", "{Level[HoldComplete[Sequence[a, b]], {1}], Level[HoldComplete[Nothing], {1}]}", "List[List[a, b], List[]]")
        , ("level strips direct unevaluated arguments", "{Level[Unevaluated[f[1 + 1]], Infinity], Level[f[a], Unevaluated[1]], Level[f[a], 1, Unevaluated[False]]}", "List[List[1, 1, Plus[1, 1]], List[a], List[a]]")
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
        , ("cases qualified sequence template splicing", "Cases[{a}, x_ :> System`Sequence[x, x]]", "List[a, a]")
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
        , ("replace all propagates exact held context", "{ReplaceAll[HoldComplete[System`HoldComplete[a]], a -> System`Sequence[b, c]], ReplaceAll[HoldComplete[1], 1 :> y /; False], ReplaceAll[HoldComplete[1], 1 :> y /; True]}", "List[HoldComplete[System`HoldComplete[System`Sequence[b, c]]], HoldComplete[1], HoldComplete[y]]")
        , ("unchanged replacement trees preserve qualified normalization state", "{ReplaceAll[System`HoldComplete[System`Sequence[a, b]], z -> q], ReplaceRepeated[System`HoldComplete[System`Sequence[a, b]], z -> q], ReplaceAll[System`Rule[x, System`Sequence[a, b]], z -> q]}", "List[System`HoldComplete[System`Sequence[a, b]], System`HoldComplete[System`Sequence[a, b]], System`Rule[x, System`Sequence[a, b]]]")
        , ("replace all preserves qualified association structure", "{ReplaceAll[System`Association[System`Rule[a, 1]], a -> b], ReplaceAll[System`Association[System`Rule[a, 1]], 1 -> 2], ReplaceAll[System`Association[System`Rule[a, 1]], System`Rule -> foo]}", "List[System`Association[System`Rule[a, 1]], System`Association[System`Rule[a, 2]], System`Association[System`Rule[a, 1]]]")
        , ("scalar pattern tests", "{MatchQ[1, _?IntegerQ], MatchQ[a, _?IntegerQ]}", "List[True, False]")
        , ("sequence pattern tests", "{Cases[{f[1, 2], f[1, a], f[]}, f[__?IntegerQ]], MatchQ[f[1, 2], f[x__?IntegerQ]], MatchQ[f[1, a], f[x__?IntegerQ]]}", "List[List[f[1, 2]], True, False]")
        , ("pattern test delayed template", "Cases[{1, a, 2}, x_?IntegerQ :> x + 10]", "List[11, 12]")
        , ("optional pattern defaults", "{Cases[{f[], f[2], f[a]}, f[x_:7] :> x], Cases[{f[], f[2]}, f[x_.] :> HoldComplete[x]], Cases[{f[], f[2], f[a]}, f[x_Integer:7] :> x]}", "List[List[7, 2, a], List[HoldComplete[2]], List[7, 2]]")
        , ("optional pattern validation", "{Cases[{f[]}, f[x_?IntegerQ:foo] :> x], Cases[{f[]}, f[x_Integer:foo] :> x]}", "List[List[], List[foo]]")
        , ("optional pattern backtracking", "{Cases[{f[a], f[a, b]}, f[x_:7, y_] :> {x, y}], Cases[{f[], f[a]}, f[x_:7, y_:8] :> {x, y}]}", "List[List[List[7, a], List[a, b]], List[List[7, 8], List[a, 8]]]")
        , ("optional sequence patterns consume their full width", "Cases[{f[], f[a], f[a, b]}, f[x:Optional[__]] :> HoldComplete[x]]", "List[HoldComplete[a], HoldComplete[a, b]]")
        , ("optional pattern sequences bind omitted outer names", "Cases[{f[], f[a], f[a, b]}, f[x:Optional[PatternSequence[_, _], d]] :> HoldComplete[x]]", "List[HoldComplete[], HoldComplete[a, b]]")
        , ("optional pattern-test grouping controls default validation", "{Cases[{f[], f[1], f[a]}, f[(x_:foo)?IntegerQ] :> HoldComplete[x]], Cases[{f[], f[1], f[a]}, f[x_?IntegerQ:foo] :> HoldComplete[x]]}", "List[List[HoldComplete[foo], HoldComplete[1]], List[HoldComplete[1]]]")
        , ("top-level repeated and pattern sequence", "{MatchQ[1, Repeated[_Integer]], MatchQ[1, PatternSequence[_Integer]]}", "List[True, True]")
        , ("bounded repeated patterns", "{Cases[{f[1], f[1, 2], f[1, 2, 3], f[1, 2, 3, 4]}, f[Repeated[_Integer, {2, 3}]]], Cases[{f[], f[1], f[1, 2], f[1, 2, 3]}, f[RepeatedNull[_Integer, 2]]]}", "List[List[f[1, 2], f[1, 2, 3]], List[f[], f[1], f[1, 2]]]")
        , ("repeated and named pattern sequences", "{Cases[{f[a, b, a, b], f[a, b, a]}, f[Repeated[PatternSequence[a, b]]] :> ok], Cases[{f[1, 2], f[1, 2, 3]}, f[x:PatternSequence[_Integer, _Integer]] :> HoldComplete[x]]}", "List[List[ok], List[HoldComplete[1, 2]]]")
        , ("orderless pattern sequence capture", "Cases[{f[1, 2], f[2, 1]}, f[x:OrderlessPatternSequence[1, 2]] :> HoldComplete[x]]", "List[HoldComplete[1, 2], HoldComplete[2, 1]]")
        , ("orderless pattern sequence uses Python permutation order", "ReplaceAll[HoldComplete[f[a, b, c]], HoldComplete[f[OrderlessPatternSequence[c, y_, z_]]] :> HoldComplete[y, z]]", "HoldComplete[a, b]")
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
        , ("held condition", "Condition[x, 1 < 2]", "Condition[x, Less[1, 2]]")
        , ("label holds its raw tag", "Label[1 + 2]", "Label[Plus[1, 2]]")
        , ("held session forms", "{OwnValues[1 + 2], With[{x = 1 + 2}, x], Module[{x = 1 + 2}, x], Block[{x = 1 + 2}, x], InheritedBlock[{x = 1 + 2}, x], Internal`InheritedBlock[{x = 1 + 2}, x], Return[1 + 2], Return[1 + 2, Module], For[x = 1, x < 2, x = x + 1, x], While[x < 2, x = x + 1]}", "List[OwnValues[Plus[1, 2]], With[List[Set[x, Plus[1, 2]]], x], Module[List[Set[x, Plus[1, 2]]], x], Block[List[Set[x, Plus[1, 2]]], x], InheritedBlock[List[Set[x, Plus[1, 2]]], x], Internal`InheritedBlock[List[Set[x, Plus[1, 2]]], x], Return[Plus[1, 2]], Return[Plus[1, 2], Module], For[Set[x, 1], Less[x, 2], Set[x, Plus[x, 1]], x], While[Less[x, 2], Set[x, Plus[x, 1]]]]")
        , ("capture-aware named functions", "{Function[x, Function[y, x + y]][a], Function[x, Function[y, x + y]][y], Function[x, Function[y, y]][a], Function[{x, y}, x + y][1], Function[{x, y}, x + y][1, 2, 3], Function[5, x][1], Function[{}, 7][1]}", "List[Function[y$, Plus[a, y$]], Function[y$, Plus[y, y$]], Function[y, y], Function[List[x, y], Plus[x, y]][1], 3, Function[5, x][1], 7]")
        , ("symbolic double negation remains inert", "{!!a, !!1, !!True}", "List[Not[Not[a]], Not[Not[1]], True]")
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
  evaluateCase parser (label, source, expected) = do
    let parsed = parser source
        pureResult = fullForm <$> (parsed >>= mapLeftEvaluation . evaluate)
    sessionResult <- case parsed of
      Left parseError -> pure (Left parseError)
      Right expression -> do
        evaluated <- evaluateInSession emptySession expression
        pure $ do
          (value, _) <- mapLeftEvaluation evaluated
          pure (fullForm value)
    pureCheck <-
      assertEqual
        ("evaluator: " <> label)
        (Right expected)
        pureResult
    sessionCheck <-
      if label == "held session forms"
        then pure True
        else
          assertEqual
            ("session evaluator: " <> label)
            (Right expected)
            sessionResult
    pure (pureCheck && sessionCheck)
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
  fifth <-
    assertLeft
      "reject unsupported Level heads traversal"
      (parseInputForm "Level[f[a], Infinity, True]" >>= mapLeftEvaluation . evaluate)
  sixth <-
    assertLeft
      "reject invalid Level specification"
      (parseInputForm "Level[f[a], bad]" >>= mapLeftEvaluation . evaluate)
  seventh <-
    assertLeft
      "reject invalid Level arity"
      (parseInputForm "Level[f[a]]" >>= mapLeftEvaluation . evaluate)
  eighth <-
    assertLeft
      "reject invalid Which pair arity"
      (parseInputForm "Which[True]" >>= mapLeftEvaluation . evaluate)
  ninth <-
    assertLeft
      "reject invalid Switch pair arity"
      (parseInputForm "Switch[x, _]" >>= mapLeftEvaluation . evaluate)
  tenth <-
    assertLeft
      "reject non-list Piecewise cases"
      (parseInputForm "Piecewise[bad]" >>= mapLeftEvaluation . evaluate)
  eleventh <-
    assertLeft
      "reject invalid ReleaseHold arity"
      (parseInputForm "ReleaseHold[]" >>= mapLeftEvaluation . evaluate)
  twelfth <-
    assertLeft
      "reject Inactive post-splice arity"
      (parseInputForm "Inactive[Sequence[f, g]]" >>= mapLeftEvaluation . evaluate)
  thirteenth <-
    assertLeft
      "reject invalid Activate arity"
      (parseInputForm "Activate[]" >>= mapLeftEvaluation . evaluate)
  pure
    ( and
        [ first
        , second
        , third
        , fourth
        , fifth
        , sixth
        , seventh
        , eighth
        , ninth
        , tenth
        , eleventh
        , twelfth
        , thirteenth
        ]
    )
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
        , ( "failure and missing predicates preserve the Python value domain"
          , "{FailureQ[Failure[\"x\", <||>]], FailureQ[$Failed], FailureQ[$Canceled], FailureQ[$Aborted], FailureQ[Missing[\"x\"]], MissingQ[Missing[\"x\"]], MissingQ[$Failed], System`FailureQ[System`Failure[\"x\", <||>]]}"
          , "List[True, True, True, True, False, True, False, True]"
          )
        , ( "failure property lookup accepts associations and rule lists"
          , "{Failure[\"bad\", <|\"x\" -> 1|>][\"x\"], Failure[\"bad\", <||>][\"Type\"], Failure[\"bad\", {\"x\" -> 2}][\"x\"], Failure[\"bad\", <||>][\"absent\"], System`Failure[\"bad\", <|\"x\" -> 3|>][\"x\"]}"
          , "List[1, \"bad\", 2, Missing[\"KeyAbsent\", \"absent\"], 3]"
          )
        , ( "failsafe guards dispatch success failure and custom callbacks"
          , "{Failsafe[f][1, 2], Failsafe[f][1, Missing[\"x\"], Failure[\"bad\", <||>]], Failsafe[f, SameQ][1, 1], Failsafe[f, SameQ][1, 2][\"Type\"], Failsafe[f, SameQ, g][1, 2], System`Failsafe[f][1, 2]}"
          , "List[f[1, 2], Missing[\"x\"], f[1, 1], FailsafeFailed, g[1, 2], f[1, 2]]"
          )
        , ( "failsafe callback control signals remain nonlocal"
          , "{Catch[Failsafe[f, Function[x, Throw[x]]][1]], CheckAbort[Failsafe[f, Function[x, Abort[]]][1], caught]}"
          , "List[1, caught]"
          )
        , ( "confirmation controls return values and project failure properties"
          , "{Enclose[1 + Confirm[2]], Enclose[Confirm[Missing[\"Nope\"], \"info\"], \"Expression\"], Enclose[Confirm[Missing[\"Nope\"], \"info\"], \"Information\"], Enclose[ConfirmBy[3, IntegerQ]], Enclose[ConfirmBy[3, StringQ, \"info\"], \"Function\"], Enclose[ConfirmMatch[3, _Integer]], Enclose[ConfirmMatch[3, _String, \"info\"], \"Pattern\"]}"
          , "List[3, Missing[\"Nope\"], \"info\", 3, StringQ, 3, Blank[String]]"
          )
        , ( "tagged confirmations route to the nearest matching enclose"
          , "{Enclose[Confirm[$Failed, \"info\", tag], \"Information\", tag], Enclose[Enclose[Confirm[$Failed, \"outer\", outer], inner, inner], \"Information\", outer]}"
          , "List[\"info\", \"outer\"]"
          )
        , ( "confirmation predicates and tag patterns thread session effects"
          , "c = 0; {Enclose[Confirm[$Failed, Null, 1], \"Information\", x_ /; (c = c + 1; True)], c, Enclose[ConfirmMatch[1, x_ /; (c = c + 1; False), c], \"Information\"], c}"
          , "List[Null, 2, 3, 3]"
          )
        , ( "enclose restores its scope across existing nonlocal exits"
          , "{Catch[Enclose[Throw[x]]], CheckAbort[Enclose[Abort[]], caught], (Enclose[Goto[out]]; never; Label[out]; reached)}"
          , "List[x, caught, reached]"
          )
        , ( "unsupported confirm quiet and fail when remain symbolic"
          , "{ConfirmQuiet[Failure[\"x\", <||>]], FailWhen[1, True]}"
          , "List[ConfirmQuiet[Failure[\"x\", Association[]]], FailWhen[1, True]]"
          )
        , ("right-associated assignment", "a = b = 5; a + b", "10")
        , ("immediate value captures current result", "a = 1; x = a; a = 2; x", "1")
        , ("immediate symbolic value reevaluates", "x = y; y = 3; x", "3")
        , ("delayed value observes later result", "a = 1; x := a + 1; a = 4; x", "5")
        , ("unset removes a value", "x = 4; Unset[x]; x", "x")
        , ("clear removes several values", "x = 1; y = 2; Clear[x, y]; x + y", "Plus[x, y]")
        , ("catalog attributes are visible", "{Attributes[Plus], Attributes[System`Function]}", "List[List[Flat, Listable, NumericFunction, OneIdentity, Orderless, Protected], List[HoldAll, Protected]]")
        , ("qualified System heads dispatch canonically", "{System`Plus[1, 2], System`Attributes[System`Times]}", "List[3, List[Flat, Listable, NumericFunction, OneIdentity, Orderless, Protected]]")
        , ("qualified inert and held heads preserve their spelling", "{System`AASTriangle[1 + 2], System`Hold[1 + 2]}", "List[System`AASTriangle[3], System`Hold[Plus[1, 2]]]")
        , ("qualified held constructors honor sequence and hold-rest metadata", "{System`Hold[System`Sequence[a, b]], System`HoldComplete[System`Sequence[a, b]], System`RuleDelayed[Head[1], Head[x]]}", "List[System`Hold[a, b], System`HoldComplete[System`Sequence[a, b]], System`RuleDelayed[Integer, Head[x]]]")
        , ("qualified Evaluate escapes held arguments", "ClearAll[f]; SetAttributes[f, HoldAll]; {Hold[System`Evaluate[1 + 1]], f[System`Evaluate[1 + 1]]}", "List[Hold[2], f[2]]")
        , ("evaluated Boolean aliases dispatch while held sequence aliases stay inert", "f = And; g = Or; h = CompoundExpression; x = 0; {f[True, False], g[False, True], h[x = 1, x = 2], x}", "List[False, True, CompoundExpression[Set[x, 1], Set[x, 2]], 0]")
        , ("evaluated Boolean aliases do not gain syntactic short circuiting", "ClearAll[f, g, x]; f = And; g = Or; x = 0; {f[False, x = 1], g[True, x = 2], x}", "List[And[False, Set[x, 1]], Or[True, Set[x, 2]], 0]")
        , ("qualified held and control heads restore selectively", "{System`If[a, b, c], System`If[True, If[a, b, c]], System`Hold[Hold[x]]}", "List[If[a, b, c], If[a, b, c], System`Hold[Hold[x]]]")
        , ("qualified listable and flat heads retain structural identity", "{System`Sin[{a, b}], System`Plus[System`Plus[a, b], c], System`Plus[Plus[a, b], c]}", "List[List[System`Sin[a], System`Sin[b]], System`Plus[a, b, c], System`Plus[c, Plus[a, b]]]")
        , ("qualified structural constructors are consumed contextually", "{Sin[System`List[a, b]], System`Sin[System`List[a, b]], f[System`Sequence[a, b]], System`List[System`Nothing, a], System`List[System`Sequence[a, b]], System`List[System`Splice[System`List[a, b]]]}", "List[List[Sin[a], Sin[b]], List[System`Sin[a], System`Sin[b]], f[a, b], System`List[System`Nothing, a], System`List[a, b], System`List[System`Splice[System`List[a, b]]]]")
        , ("qualified associations and rules work at consumer boundaries", "{System`Association[System`Rule[a, 1]][a], Association[System`Rule[a, 1]][a], ReplaceAll[x, System`Rule[x, y]], ReplaceAll[x, System`RuleDelayed[x, y]]}", "List[1, 1, y, y]")
        , ("bare associations consume qualified lists while qualified associations stay held", "{Association[System`List[a -> 1, b -> 2]], System`Association[System`List[a -> 1, b -> 2]], System`Association[System`Rule[a, Head[x]]]}", "List[Association[Rule[a, 1], Rule[b, 2]], System`Association[System`List[Rule[a, 1], Rule[b, 2]]], System`Association[System`Rule[a, Head[x]]]]")
        , ("qualified collection rebuilding retains exact Nothing boundaries", "{Association[System`List[Nothing, a -> 1]], ReplaceAll[System`List[a], a -> Nothing], ReplaceAll[List[a], a -> Nothing]}", "List[Association[System`List[Nothing, Rule[a, 1]]], System`List[Nothing], List[]]")
        , ("qualified association replacement remains structural", "{ReplaceAll[System`Association[System`Rule[a, 1]], Association -> foo], ReplaceAll[System`Association[System`Rule[a, 1]], System`Association -> foo], ReplaceAll[System`Association[System`Rule[a, 1]], 1 -> Nothing], ReplaceAll[Association[a -> 1], 1 -> Nothing]}", "List[System`Association[System`Rule[a, 1]], foo[System`Rule[a, 1]], System`Association[System`Rule[a, Nothing]], Association[Rule[a, Nothing]]]")
        , ("replacement rebuilding respects exact sequence-holding heads", "{ReplaceAll[HoldComplete[qa], qa -> System`Sequence[qb, qc]], ReplaceAll[System`HoldComplete[qa], qa -> System`Sequence[qb, qc]], ReplaceAll[RuleDelayed[qa, qx], qx -> System`Sequence[qb, qc]], ReplaceAll[System`Rule[qa, qx], qx -> Sequence[qb, qc]]}", "List[HoldComplete[System`Sequence[qb, qc]], System`HoldComplete[qb, qc], RuleDelayed[qa, System`Sequence[qb, qc]], System`Rule[qa, qb, qc]]")
        , ("qualified delayed rules and conditions retain held bodies", "{ReplaceAll[qf[1], System`RuleDelayed[qf[qx_], Head[qx]]], ReplaceAll[qf[1], System`RuleDelayed[qf[qx_], System`Condition[Head[qx], False]]]}", "List[Integer, qf[1]]")
        , ("Cases splices qualified Sequence results", "Cases[{a}, x_ :> System`Sequence[x, x]]", "List[a, a]")
        , ("qualified immediate and delayed rules keep timing semantics", "ClearAll[i]; i = 0; first = ReplaceAll[{a, a}, System`Rule[a, (i = i + 1)]]; i = 0; second = ReplaceAll[{a, a}, System`RuleDelayed[a, (i = i + 1)]]; {first, second, i}", "List[List[1, 1], List[1, 2], 2]")
        , ("qualified and bare downvalue patterns remain distinct", "Unprotect[AASTriangle]; ClearAll[AASTriangle]; AASTriangle[x_] := foo; System`AASTriangle[x_] := bar; {AASTriangle[a], System`AASTriangle[a]}", "List[foo, bar]")
        , ("evaluated qualified aliases use the Python dispatch boundary", "p = System`Part; l = System`Length; q = System`Plus; e = System`Equal; {p[{a, b}, 1], l[{a, b}], q[1, 2], e[1, 1]}", "List[System`Part[List[a, b], 1], System`Length[List[a, b]], 3, True]")
        , ("mutable flat and orderless attributes normalize calls", "ClearAll[f]; SetAttributes[f, {Flat, Orderless, OneIdentity}]; {Attributes[f], f[b, f[c, a], a], Cases[{f[c, b, a]}, f[a, x__] :> HoldComplete[x]]}", "List[List[Flat, OneIdentity, Orderless], f[a, a, b, c], List[HoldComplete[b, c]]]")
        , ("flat one-identity downvalues group trailing arguments", "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; f[x_, y_] := HoldComplete[x, y]; f[a, b, c]", "HoldComplete[a, f[b, c]]")
        , ("flat downvalues retain singleton heads without one-identity", "ClearAll[f]; SetAttributes[f, Flat]; f[x_, y_] := HoldComplete[x, y]; f[a, b, c]", "HoldComplete[f[a], f[b, c]]")
        , ("flat one-identity downvalues group four arguments", "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; f[x_, y_] := HoldComplete[x, y]; f[a, b, c, d]", "HoldComplete[a, f[b, c, d]]")
        , ("flat optional patterns consume zero or one argument", "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; f[x_:7, y_] := HoldComplete[x, y]; {f[a], f[a, b], f[a, b, c]}", "List[HoldComplete[7, a], HoldComplete[a, b], HoldComplete[a, f[b, c]]]")
        , ("flat alternatives expose sequence-width branches", "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; f[x:(_Integer | __)] := HoldComplete[x]; {f[a], f[a, b], f[a, b, c]}", "List[HoldComplete[a], HoldComplete[a, b], HoldComplete[a, b, c]]")
        , ("flat typed sequence alternatives match whole groups", "ClearAll[f]; SetAttributes[f, {Flat, OneIdentity}]; f[x:Alternatives[__Integer, __Symbol]] := HoldComplete[x]; {f[1, 2], f[a, b], f[1, a]}", "List[HoldComplete[1, 2], HoldComplete[a, b], f[1, a]]")
        , ("orderless downvalues permute typed arguments", "ClearAll[f]; SetAttributes[f, Orderless]; f[x_Symbol, y_Integer] := HoldComplete[x, y]; f[a, 1]", "HoldComplete[a, 1]")
        , ("orderless permutations follow Python argument order", "ClearAll[f]; SetAttributes[f, Orderless]; ReplaceAll[HoldComplete[f[a, b, c]], HoldComplete[f[c, y_, z_]] :> HoldComplete[y, z]]", "HoldComplete[a, b]")
        , ("flat orderless repeated bindings backtrack across groupings", "ClearAll[f]; SetAttributes[f, {Flat, Orderless, OneIdentity}]; f[x_, x_] := same; {f[a, a], f[a, b], f[a, b, a, b]}", "List[same, f[a, b], same]")
        , ("catalog flat attributes participate in nested matching", "MatchQ[HoldComplete[Plus[a, b, c]], HoldComplete[Plus[x_, y_]]]", "True")
        , ("orderless permutation backtracking retains pattern-test effects", "c = 0; ClearAll[f, q]; SetAttributes[f, Orderless]; q[x_] := (c = c + 1; IntegerQ[x]); {MatchQ[HoldComplete[f[a, 1]], HoldComplete[f[x_?q, y_Symbol]]], c}", "List[True, 2]")
        , ("orderless matching deduplicates repeated argument orders", "c = 0; ClearAll[f, q]; SetAttributes[f, Orderless]; q[x_] := (c = c + 1; False); {MatchQ[HoldComplete[f[a, a]], HoldComplete[f[x_?q, y_]]], c}", "List[False, 1]")
        , ("pattern callbacks can mutate later nested match attributes", "ClearAll[f, g, q]; q[x_] := (SetAttributes[g, {Flat, OneIdentity}]; True); MatchQ[HoldComplete[f[a, g[b, c, d]]], HoldComplete[f[x_?q, g[y_, z_]]]]", "True")
        , ("mutable hold attributes prepare arguments", "ClearAll[f]; Attributes[f] = HoldAll; f[1 + 2, Sequence[a, b], Evaluate[3 + 4]]", "f[Plus[1, 2], a, b, 7]")
        , ("qualified Attributes assignment mutates metadata", "ClearAll[f]; System`Attributes[f] = HoldAll; {Attributes[f], f[1 + 2]}", "List[List[HoldAll], f[Plus[1, 2]]]")
        , ("qualified attribute names remain held metadata", "ClearAll[f]; SetAttributes[f, System`HoldAll]; {Attributes[f], f[1 + 2]}", "List[List[HoldAll], f[Plus[1, 2]]]")
        , ("listable and held attributes compose", "ClearAll[f]; SetAttributes[f, {Listable, HoldAll}]; f[{1 + 2, 3 + 4}]", "List[f[Plus[1, 2]], f[Plus[3, 4]]]")
        , ("hold all complete suppresses evaluate and sequence", "ClearAll[f]; SetAttributes[f, HoldAllComplete]; f[1 + 2, Sequence[a, b], Evaluate[3 + 4]]", "f[Plus[1, 2], Sequence[a, b], Evaluate[Plus[3, 4]]]")
        , ("RuleDelayed uses catalog hold-rest metadata", "ClearAll[x]; x = 1; RuleDelayed[x, x]", "RuleDelayed[1, x]")
        , ("RuleDelayed follows mutable attributes", "ClearAll[x]; x = 1; Unprotect[RuleDelayed]; ClearAttributes[RuleDelayed, {HoldRest, SequenceHold}]; RuleDelayed[x, x]", "RuleDelayed[1, 1]")
        , ("Rule sequence splicing follows mutable attributes", "Unprotect[Rule, RuleDelayed]; ClearAttributes[{Rule, RuleDelayed}, SequenceHold]; {Rule[a, Sequence[b, c]], RuleDelayed[a, Sequence[b, c]]}", "List[Rule[a, b, c], RuleDelayed[a, b, c]]")
        , ("Condition uses catalog hold-all metadata", "ClearAll[x]; x = 1; Condition[x, x]", "Condition[x, x]")
        , ("Condition follows mutable attributes", "ClearAll[x]; x = 1; Unprotect[Condition]; ClearAttributes[Condition, HoldAll]; Condition[x, x]", "Condition[1, 1]")
        , ("held aliases prepare arguments from current attributes", "f = OwnValues; Unprotect[OwnValues]; ClearAttributes[OwnValues, HoldAll]; x = 1; f[x]", "OwnValues[1]")
        , ("held aliases apply user downvalues after preparation", "Unprotect[OwnValues]; ClearAll[OwnValues]; OwnValues[x_] := foo; {OwnValues[a], (f = OwnValues; f[a])}", "List[List[], foo]")
        , ("Association preparation follows mutable attributes", "Unprotect[Association]; ClearAttributes[Association, HoldAllComplete]; x = 1; Association[x]", "Association[1]")
        , ("Level preparation follows mutable attributes", "Unprotect[Level]; SetAttributes[Level, HoldAll]; x = 1; Level[f[x], {1}]", "List[x]")
        , ("SelectFirst default preparation follows mutable attributes", "x = 0; Unprotect[SelectFirst]; ClearAttributes[SelectFirst, HoldRest]; {SelectFirst[{a}, True &, x = 1], x}", "List[a, 1]")
        , ("held definition left-hand side respects attributes", "ClearAll[f, x]; SetAttributes[f, HoldAll]; x = 1; f[x] = 9; {f[x], f[1], DownValues[f]}", "List[9, f[1], List[RuleDelayed[HoldPattern[f[x]], 9]]]")
        , ("HoldPattern assignment normalization follows mutable attributes", "ClearAll[f, g, x]; x = 1; HoldPattern[f[x]] = 9; Unprotect[HoldPattern]; ClearAttributes[HoldPattern, HoldAll]; HoldPattern[g[x]] = 8; {DownValues[f], DownValues[g]}", "List[List[RuleDelayed[HoldPattern[HoldPattern[f[x]]], 9]], List[RuleDelayed[HoldPattern[HoldPattern[g[1]]], 8]]]")
        , ("qualified definition wrappers resolve canonically", "ClearAll[f]; System`Condition[f[x_], True] := x; {f[1], DownValues[f]}", "List[1, List[RuleDelayed[HoldPattern[Condition[f[Pattern[x, Blank[]]], True]], x]]]")
        , ("qualified delayed-body conditions remain distinct guards", "ClearAll[f]; f[x_] := System`Condition[a, x > 0]; f[x_] := System`Condition[b, x < 0]; {f[1], f[-1], DownValues[f]}", "List[a, b, List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], System`Condition[a, Greater[x, 0]]], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], System`Condition[b, Less[x, 0]]]]]")
        , ("block restores values while attribute mutations escape", "ClearAll[f]; f = 7; Block[{f}, SetAttributes[f, HoldAll]; f = 1]; {Attributes[f], f}", "List[List[HoldAll], 7]")
        , ("intrinsic imaginary unit has no own value", "{I, System`I, OwnValues[I]}", "List[Complex[0, 1], Complex[0, 1], List[]]")
        , ("system settings expose seeded own values", "{$RecursionLimit, $IterationLimit, $HistoryLength, $MaxExtraPrecision, $MaxRootDegree, $OutputSizeLimit, $MessagePrePrint, $MachinePrecision}", "List[1024, 4096, Infinity, 50, 1000, 12000, Automatic, 15.954589770191003]")
        , ("valid system setting assignments update own values", "$RecursionLimit = 20; {$RecursionLimit, OwnValues[$RecursionLimit]}", "List[20, List[RuleDelayed[HoldPattern[$RecursionLimit], 20]]]")
        , ("qualified Infinity is a valid unbounded setting", "$RecursionLimit = System`Infinity; {$RecursionLimit, OwnValues[$RecursionLimit]}", "List[System`Infinity, List[RuleDelayed[HoldPattern[$RecursionLimit], System`Infinity]]]")
        , ("ordinary seeded system own values can be unset", "$MessagePrePrint =.; {$MessagePrePrint, OwnValues[$MessagePrePrint]}", "List[$MessagePrePrint, List[]]")
        , ("protected session hooks allow direct value mutation", "ClearAll[$Pre]; Protect[$Pre]; $Pre = 1; {$Pre, OwnValues[$Pre], Attributes[$Pre]}", "List[1, List[RuleDelayed[HoldPattern[$Pre], 1]], List[Protected]]")
        , ("Clear removes protected hook values but keeps attributes", "ClearAll[$Pre]; $Pre = 1; Protect[$Pre]; Clear[$Pre]; {$Pre, OwnValues[$Pre], Attributes[$Pre]}", "List[$Pre, List[], List[Protected]]")
        , ("fixed context values and initial context registry", "{$Context, System`$Context, $ContextPath, System`$ContextPath, Context[], Contexts[]}", "List[\"Global`\", \"Global`\", List[\"System`\", \"Global`\"], List[\"System`\", \"Global`\"], \"Global`\", List[\"Global`\", \"System`\"]]")
        , ("context values precede stored own values", "$Context = \"Foo`\"; $ContextPath = {\"Other`\"}; {$Context, $ContextPath, OwnValues[$Context], OwnValues[$ContextPath]}", "List[\"Global`\", List[\"System`\", \"Global`\"], List[RuleDelayed[HoldPattern[$Context], \"Foo`\"]], List[RuleDelayed[HoldPattern[$ContextPath], List[\"Other`\"]]]]")
        , ("Context holds symbols and resolves visible contexts", "ClearAll[x, c]; x = 9; c = Context; {Context[x], c[x], System`Context[System`Plus], Context[Global`x]}", "List[\"Global`\", \"Global`\", \"System`\", \"Global`\"]")
        , ("Symbol constructs and displays qualified names", "{Symbol[\"TungstenRegistryTest`alpha\"], Symbol[\"Global`tungstenGlobalSymbol\"], System`Symbol[\"Global`tungstenQualifiedSymbol\"], Symbol[\"System`Plus\"]}", "List[TungstenRegistryTest`alpha, tungstenGlobalSymbol, tungstenQualifiedSymbol, Plus]")
        , ("SymbolName accepts symbols existing strings and explicit string names", "Symbol[\"TungstenRegistryTest`alpha\"]; {SymbolName[TungstenRegistryTest`alpha], SymbolName[\"TungstenRegistryTest`alpha\"], SymbolName[\"arbitrary context text`shortName\"]}", "List[\"alpha\", \"alpha\", \"shortName\"]")
        , ("Contexts and Names discover registered nonvisible symbols", "Symbol[\"TungstenRegistryTest`alpha\"]; Symbol[\"TungstenRegistryTest`beta\"]; {Contexts[\"TungstenRegistryTest`*\"], Names[\"TungstenRegistryTest`*\"], Names[\"System`Plus\"], NameQ[\"TungstenRegistryTest`alpha\"], NameQ[\"TungstenRegistryMissing`*\"]}", "List[List[\"TungstenRegistryTest`\"], List[\"TungstenRegistryTest`alpha\", \"TungstenRegistryTest`beta\"], List[\"Plus\"], True, False]")
        , ("Names handles pattern lists visibility and display collisions", "Global`Plus; OtherRegistry`alpha; OtherRegistry`beta; {Names[{\"System`Plus\", \"Global`Plus\", \"OtherRegistry`a*\"}], Names[\"Plus\"], Names[\"OtherRegistry`*\"], NameQ[{\"missing*\", \"OtherRegistry`b*\"}]}", "List[List[\"OtherRegistry`alpha\", \"Plus\"], List[\"Plus\"], List[\"OtherRegistry`alpha\", \"OtherRegistry`beta\"], True]")
        , ("whole-expression registration is visible to earlier name queries", "{Contexts[\"LaterRegistry`*\"], Names[\"LaterRegistry`*\"], LaterRegistry`symbol}", "List[List[\"LaterRegistry`\"], List[\"LaterRegistry`symbol\"], LaterRegistry`symbol]")
        , ("qualified and evaluated name-query aliases dispatch", "ClearAll[q, s]; q = Names; s = Symbol; {System`Names[\"System`Plus\"], q[\"System`Times\"], s[\"OtherRegistry`made\"], System`SymbolName[System`Plus]}", "List[List[\"Plus\"], List[\"Times\"], OtherRegistry`made, \"Plus\"]")
        , ("System name catalog remains complete through Names", "{Length[Names[\"System`*\"]], NameQ[\"System`AASTriangle\"], NameQ[\"AASTriangle\"]}", "List[7941, True, True]")
        , ("catalog formal symbols bypass user-name validation", "{Symbol[\"System`\\[FormalA]\"], SymbolName[\"System`\\[FormalA]\"], Context[\"System`\\[FormalA]\"]}", "List[\\[FormalA], \"\xF800\", \"System`\"]")
        , ("Unique counter allocation preserves resolved contexts", "{Unique[], Unique[x], Unique[OtherUnique`x], Unique[System`Plus]}", "List[$1, x$2, OtherUnique`x$3, Plus$4]")
        , ("Unique string prefixes have independent next-free sequences", "{Unique[\"p\"], Unique[\"p\"], Unique[\"q\"], Unique[\"p\"]}", "List[p1, p2, q1, p3]")
        , ("Unique list allocation threads both counter families", "Unique[{x, \"p\", OtherUnique`y, \"p\"}]", "List[x$1, p1, OtherUnique`y$2, p2]")
        , ("qualified and evaluated Unique aliases dispatch", "{System`Unique[], (q = Unique; q[x]), (r = System`Unique; r[\"p\"])}", "List[$1, x$2, p1]")
        , ("Unique has ordinary evaluated argument and mutable attribute semantics", "ClearAll[x]; x = \"p\"; first = {Unique[x], Unique[(x = \"q\"; x)], x}; Unprotect[Unique]; SetAttributes[Unique, HoldAll]; {first, Unique[x], Unique[Sequence[]]}", "List[List[p1, q1, \"q\"], x$1, $2]")
        , ("Evaluate transparently prepares direct ordinary arguments", "ClearAll[x, e]; x = y; e = Evaluate; {Evaluate[x], System`Evaluate[x], Evaluate[Unevaluated[x]], e[x], Unique[Evaluate[x]]}", "List[y, y, y, Evaluate[y], y$1]")
        , ("Nothing callable evaluates arbitrary arguments through aliases", "ClearAll[n, x]; n = Nothing; x = 0; probe[Nothing[], System`Nothing[1 + 1], n[x = x + 1], x]", "probe[Nothing, Nothing, Nothing, 1]")
        , ("Nothing callable ignores mutable hold attributes", "Unprotect[Nothing]; SetAttributes[Nothing, HoldAllComplete]; x = 0; Nothing[x = 1]; x", "1")
        , ("Nothing callable propagates throws to Catch", "Catch[Nothing[Throw[1]]]", "1")
        , ("Nothing callable propagates bare returns", "Nothing[Return[1]]", "Return[1]")
        , ("SameAs callable covers arity identity and Sequence", "{SameAs[y][], SameAs[y][y], SameAs[y][x, y], SameAs[f[a]][f[a]], SameAs[Sequence[y, z]][y]}", "List[True, True, False, True, SameAs[y, z][y]]")
        , ("SameAs callable aliases and mutable holds retain structural identity", "ClearAll[x, s]; x = 1; s = SameAs[y]; first = {s[], s[y], System`SameAs[y][y], SameAs[Unevaluated[x]][x]}; Unprotect[SameAs]; SetAttributes[SameAs, HoldAll]; {first, SameAs[x][x]}", "List[List[True, True, True, False], False]")
        , ("composition callables cover zero one and many functions", "{Composition[][x], Composition[][], Composition[][x, y, Nothing], Composition[f][x, y], Composition[f, g, h][x, y], RightComposition[f, g, h][x, y]}", "List[x, List[], List[x, y], f[x, y], f[g[h[x, y]]], h[g[f[x, y]]]]")
        , ("empty composition uses qualified Sequence and Splice list normalization", "{Composition[][System`Sequence[a, b], x], Composition[][System`Splice[{a, b}], x], Composition[][Splice[System`List[a, b]], x], RightComposition[][System`Splice[System`List[a, b]], x]}", "List[List[a, b, x], List[a, b, x], List[a, b, x], List[a, b, x]]")
        , ("composition callables splice Sequence and nest structurally", "{Composition[Sequence[f, g], h][x], Composition[f, g][Sequence[x, y]], Composition[Composition[f, g], h][x], RightComposition[RightComposition[f, g], h][x], Composition[RightComposition[f, g], h][x]}", "List[f[g[h[x]]], f[g[x, y]], f[g[h[x]]], h[g[f[x]]], g[f[h[x]]]]")
        , ("composition callable aliases and qualified heads dispatch", "ClearAll[c, r, q]; c = Composition[f, g]; r = RightComposition[f, g]; q = Composition; {c[x], r[x], q[f, g][x], System`Composition[f, g][x], System`RightComposition[f, g][x]}", "List[f[g[x]], g[f[x]], f[g[x]], f[g[x]], g[f[x]]]")
        , ("composition callables accept nested callables and pure functions", "probe[Composition[SameAs[y]][y], Composition[Nothing, f][x], Composition[f, Nothing][x], Composition[Function[x, x + 1], Function[x, x*2]][3], RightComposition[Function[x, x + 1], Function[x, x*2]][3]]", "probe[True, Nothing, f[Nothing], 7, 8]")
        , ("composition constructors alone strip direct Unevaluated operands", "{Composition[Unevaluated[f], g], RightComposition[Unevaluated[f], g], Composition[Unevaluated[f], g][x], SameAs[Unevaluated[x]][x], Composition[f, g][Unevaluated[x]]}", "List[Composition[f, g], RightComposition[f, g], f[g[x]], False, f[g[Unevaluated[x]]]]")
        , ("composition Unevaluated operand stripping does not evaluate payloads", "ClearAll[z]; z = 0; Composition[Unevaluated[z = z + 1; f], g]; z", "0")
        , ("composition callable order threads effects and control", "ClearAll[x, f, g]; x = 0; f[t_] := (x = x + 1; t); g[t_] := (x = x + 10; t); result = Composition[f, g][x = 100]; {result, x, Catch[Composition[f, Function[x, Throw[x]]][3]]}", "List[100, 111, 3]")
        , ("held builtin spellings dispatch directly while evaluated aliases remain inert", "ClearAll[qw, qs, qp, qr, qi, qa]; qw = Which; qs = Switch; qp = Piecewise; qr = ReleaseHold; qi = Inactive; qa = Activate; {System`Which[False, a, True, b], qw[False, 1+2, True, 3+4], Global`Which[False, 1+2, True, 3+4], System`Switch[x, x, a], qs[1+2, 3, a], Global`Switch[1+2, 3, a], System`Piecewise[{{1+2, True}}], qp[{{1+2, True}}], Global`Piecewise[{{1+2, True}}], System`ReleaseHold[Hold[1+2]], qr[Hold[1+2]], Global`ReleaseHold[Hold[1+2]], System`Inactive[Plus][1+2], qi[3], Global`Inactive[1+2], System`Activate[System`Inactive[Plus][1,2]], qa[Inactive[Plus][1,2]], Global`Activate[Inactive[Plus][1+2,3+4]]}", "List[b, Which[False, Plus[1, 2], True, Plus[3, 4]], Global`Which[False, 3, True, 7], a, Switch[3, 3, a], Global`Switch[3, 3, a], 3, Piecewise[List[List[Plus[1, 2], True]]], Global`Piecewise[List[List[3, True]]], 3, ReleaseHold[Hold[Plus[1, 2]]], Global`ReleaseHold[Hold[Plus[1, 2]]], System`Inactive[Plus][3], Inactive[3], Global`Inactive[3], 3, Activate[Inactive[Plus][1, 2]], Global`Activate[Inactive[Plus][3, 7]]]")
        , ("held condition release and activation propagate only selected control", "{Catch[Which[False, Throw[1], True, a]], Catch[Switch[x, y, Throw[2], _, a]], Catch[Piecewise[{{Throw[3], False}, {b, True}}]], Catch[ReleaseHold[Hold[Throw[4]]]], Catch[Inactive[Throw[5]]], Catch[Inactive[f][Throw[6]]], Catch[Activate[Inactive[Function[x, Throw[x]]][7]]]}", "List[a, a, b, 4, Inactive[Throw[5]], 6, 7]")
        , ("Unique shares its symbol counter with Module", "{Unique[], Module[{x}, Hold[x]], Unique[x]}", "List[$1, Hold[x$2], x$3]")
        , ("counter Unique intentionally reuses registered candidate names", "Symbol[\"Global`$1\"]; Symbol[\"Global`x$2\"]; {Unique[], Unique[x], Names[{\"Global`$1\", \"Global`x$2\"}]}", "List[$1, x$2, List[\"$1\", \"x$2\"]]")
        , ("string Unique scans Global collisions without sharing module state", "Symbol[\"Global`p1\"]; {Unique[], Unique[\"p\"], Unique[p], Unique[\"p\"], Names[\"Global`p*\"]}", "List[$1, p2, p$2, p3, List[\"p\", \"p$2\", \"p1\", \"p2\", \"p3\"]]")
        , ("bare and explicit Global symbols share values", "ClearAll[Global`ctxX, ctxY]; Global`ctxX = 1; ctxY = 2; {ctxX, Global`ctxY, Attributes[\"ctxX\"]}", "List[1, 2, List[]]")
        , ("explicit unknown System symbols keep separate context identity", "ClearAll[Global`ctxCollision, System`ctxCollision]; Global`ctxCollision = 1; System`ctxCollision = 2; {Global`ctxCollision, System`ctxCollision, ctxCollision}", "List[1, 2, 2]")
        , ("whole-expression registration resolves future System symbols", "ClearAll[Global`ctxFutureSysA]; ctxFutureSysA = 1; Hold[System`ctxFutureSysA]; {ctxFutureSysA, Global`ctxFutureSysA, System`ctxFutureSysA, OwnValues[Global`ctxFutureSysA], OwnValues[System`ctxFutureSysA]}", "List[1, Global`ctxFutureSysA, 1, List[], List[RuleDelayed[HoldPattern[ctxFutureSysA], 1]]]")
        , ("held symbols are registered for string metadata lookup", "Hold[System`heldRegistryA, Other`heldRegistryC]; {OwnValues[\"System`heldRegistryA\"], Attributes[\"Other`heldRegistryC\"]}", "List[List[], List[]]")
        , ("qualified Global wildcard clears bare symbols", "ctxX = 1; ClearAll[\"Global`*\"]; ctxX", "ctxX")
        , ("unqualified name patterns skip nonvisible contexts", "TungstenOther`ctxHidden = 1; ClearAll[\"ctxHidden\"]; TungstenOther`ctxHidden", "1")
        , ("unqualified name patterns resolve System collisions first", "Global`Plus = 1; ClearAll[\"Plus\"]; Global`Plus", "1")
        , ("explicit Global symbol keeps independent attributes", "ClearAll[Global`Plus]; SetAttributes[Global`Plus, HoldAll]; {Attributes[Global`Plus], Global`Plus[1 + 2]}", "List[List[HoldAll], Global`Plus[Plus[1, 2]]]")
        , ("own values stay held", "x = 5; {OwnValues[x], OwnValues[y], OwnValues[1], OwnValues[x, y]}", "List[List[RuleDelayed[HoldPattern[x], 5]], List[], OwnValues[1], OwnValues[x, y]]")
        , ("ValueQ holds its argument and distinguishes symbols from atoms", "ClearAll[x]; {Attributes[ValueQ], ValueQ[x], x = 1, ValueQ[x], ValueQ[x + 1], ValueQ[1], ValueQ[\"x\"], ValueQ[I], ValueQ[$MachinePrecision]}", "List[List[HoldAll, Protected, ReadProtected], False, 1, True, True, False, False, False, False]")
        , ("ValueQ recognizes implicit context symbols only", "{ValueQ[$Context], ValueQ[System`$Context], ValueQ[Global`$Context], ValueQ[$ContextPath], ValueQ[System`$ContextPath], ValueQ[Global`$ContextPath]}", "List[True, True, False, True, True, False]")
        , ("ValueQ probes down sub and up definitions", "ClearAll[f, g, h, k, t, x, y]; f[1] = a; g[x_][y_] := {x, y}; TagSetDelayed[t, h[t[x_]], x]; k[x_] := x /; False; {ValueQ[f[1]], ValueQ[f[2]], ValueQ[g[1][2]], ValueQ[g[1]], ValueQ[h[t[3]]], ValueQ[h[t]], ValueQ[k[1]], ValueQ[f], ValueQ[g], ValueQ[t]}", "List[True, False, True, False, True, False, False, False, False, False]")
        , ("ValueQ retains held assignment and definition effects", "ClearAll[f, x]; {ValueQ[x = 1], x, ValueQ[f[x_] := x], ValueQ[f[2]], DownValues[f]}", "List[True, 1, True, True, List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], x]]]")
        , ("ValueQ retains effects from false definition conditions", "ClearAll[c, f, x]; c = 0; f[x_ /; (c = c + 1; False)] := x; {ValueQ[f[1]], c}", "List[False, 1]")
        , ("ValueQ raw dispatch ignores mutable attributes and Sequence", "ClearAll[x]; Unprotect[ValueQ]; ClearAttributes[ValueQ, HoldAll]; x = 1; {ValueQ[x], ValueQ[Sequence[x]]}", "List[True, True]")
        , ("ValueQ aliases differ from raw qualified and Sequence dispatch", "ClearAll[x, q]; x = 7; q = ValueQ; {ValueQ[x], System`ValueQ[x], q[x], ValueQ[Sequence[x, x]], q[Sequence[x, x]]}", "List[True, True, ValueQ[x], True, ValueQ[x, x]]")
        , ("ValueQ propagates bare Return", "ValueQ[Return[1]]", "Return[1]")
        , ("ValueQ propagates uncaught Throw", "ValueQ[Throw[1]]", "Throw[1]")
        , ("ValueQ Throw remains catchable by an outer scope", "Catch[ValueQ[Throw[1]]]", "1")
        , ("value getters register and resolve symbol names", "OwnValues[x]; f[t_] := t; {Attributes[\"x\"], DownValues[\"f\"], DownValues[\"missing\"], UpValues[\"missing\"], SubValues[\"missing\"], NValues[\"missing\"]}", "List[List[], List[RuleDelayed[HoldPattern[f[Pattern[t, Blank[]]]], t]], List[], List[], List[], List[]]")
        , ("own values use canonical Global display", "Global`x = 1; OwnValues[Global`x]", "List[RuleDelayed[HoldPattern[x], 1]]")
        , ("value getters and Protect use visible-context display", "System`dynamicDisplay = 1; {OwnValues[System`dynamicDisplay], Protect[System`dynamicDisplay]}", "List[List[RuleDelayed[HoldPattern[dynamicDisplay], 1]], List[\"dynamicDisplay\"]]")
        , ("colliding Global value getters still use short display", "Global`Plus = 1; OwnValues[Global`Plus]", "List[RuleDelayed[HoldPattern[Plus], 1]]")
        , ("metadata parsers consume qualified List and Evaluate wrappers", "ClearAll[f, g, x]; SetAttributes[System`List[f, g], HoldAll]; SetAttributes[f, System`List[HoldAll, Listable]]; x = f; {Attributes[System`List[f, g]], Attributes[System`Evaluate[x]], Protect[System`List[f, g]]}", "List[List[List[HoldAll, Listable], List[HoldAll]], List[HoldAll, Listable], List[\"f\", \"g\"]]")
        , ("downvalue delayed dispatch", "f[x_] := x^2; {f[3], f[a + b], DownValues[f]}", "List[9, Power[Plus[a, b], 2], List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Power[x, 2]]]]")
        , ("immediate downvalue evaluates rhs before lhs", "x = 10; f[x_] = x + 1; {f[3], DownValues[f]}", "List[11, List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], 11]]]")
        , ("delayed downvalue observes later own values", "y = 5; f[x_] := x + y; first = f[3]; y = 10; {first, f[3], DownValues[f]}", "List[8, 13, List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Plus[x, y]]]]")
        , ("mutual own-value cycles stop without messages", "ClearAll[x, y]; x := y; y := x; {x, y, OwnValues[x], OwnValues[y]}", "List[x, y, List[RuleDelayed[HoldPattern[x], y]], List[RuleDelayed[HoldPattern[y], x]]]")
        , ("own-value cycles use resolved context identity", "ClearAll[x]; x := Global`x; {x, Global`x, OwnValues[x]}", "List[Global`x, Global`x, List[RuleDelayed[HoldPattern[x], Global`x]]]")
        , ("user head aliases retarget downvalues", "f = g; f[x_] := x + 1; {g[2], DownValues[g], DownValues[f]}", "List[3, List[RuleDelayed[HoldPattern[g[Pattern[x, Blank[]]]], Plus[x, 1]]], List[]]")
        , ("retargeted system head assignment stays inert", "f = List; {f[1] = 2, DownValues[f], List[1]}", "List[Set[List[1], 2], List[], List[1]]")
        , ("raw protected head assignment stays inert", "{List[1] = 2, List[1], DownValues[List]}", "List[Set[List[1], 2], List[1], List[]]")
        , ("downvalue specificity and recursion", "f[x_] := x * f[x - 1]; f[1] = 1; {f[5], DownValues[f]}", "List[120, List[RuleDelayed[HoldPattern[f[1]], 1], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Times[x, f[Plus[x, -1]]]]]]")
        , ("downvalue conditional equations", "f[x_] := positive /; x > 0; f[x_] := negative /; x < 0; f[0] = zero; {f[2], f[-2], f[0], DownValues[f]}", "List[positive, negative, zero, List[RuleDelayed[HoldPattern[f[0]], zero], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Condition[positive, Greater[x, 0]]], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Condition[negative, Less[x, 0]]]]]")
        , ("compound unset preserves other equations", "f[x_] := x + 1; f[0] = 9; {Unset[f[x_]], f[0], f[2], DownValues[f], Unset[f[x_]]}", "List[Null, 9, f[2], List[RuleDelayed[HoldPattern[f[0]], 9]], $Failed]")
        , ("curried definitions use subvalues", "ClearAll[f]; f[x_][y_] := {x, y}; {f[1][2], DownValues[f], SubValues[f]}", "List[List[1, 2], List[], List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], List[x, y]]]]")
        , ("immediate subvalues evaluate rhs before lhs", "ClearAll[f, y]; y = 5; result = (f[x_][z_] = {x, y, z}); y = 10; {result, f[1][2], SubValues[f]}", "List[List[x, 5, z], List[1, 5, 2], List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[z, Blank[]]]], List[x, 5, z]]]]")
        , ("evaluated curried heads retarget subvalues", "ClearAll[f, g]; f[x_] := g[x]; f[x_][y_] := {x, y}; {f[1][2], SubValues[f], SubValues[g]}", "List[List[1, 2], List[], List[RuleDelayed[HoldPattern[g[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], List[x, y]]]]")
        , ("subvalue specificity favors exact definitions", "ClearAll[f]; f[x_][y_] := generic[x, y]; f[1][2] = exact; {f[1][2], f[1][3], SubValues[f]}", "List[exact, generic[1, 3], List[RuleDelayed[HoldPattern[f[1][2]], exact], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], generic[x, y]]]]")
        , ("subvalue specificity preserves tied assignment order", "ClearAll[f]; f[x_][y_] := generic[x, y]; f[1][y_] := partial[y]; {f[1][2], SubValues[f]}", "List[generic[1, 2], List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], generic[x, y]], RuleDelayed[HoldPattern[f[1][Pattern[y, Blank[]]]], partial[y]]]]")
        , ("subvalue conditional equations and exact unset", "ClearAll[f]; f[x_][y_] := pos[y] /; x > 0; f[x_][y_] := neg[y] /; x < 0; a = {f[2][9], f[-2][9], SubValues[f]}; u = Unset[f[x_][y_]]; {a, u, f[2][9], SubValues[f], Unset[f[x_][y_]]}", "List[List[pos[9], neg[9], List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], Condition[pos[y], Greater[x, 0]]], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], Condition[neg[y], Less[x, 0]]]]], Null, f[2][9], List[], $Failed]")
        , ("subvalue bodies catch bare Return and preserve effects", "ClearAll[f, z]; f[x_][y_] := (z = 1; Return[{x, y}]; z = 2); {f[a][b], z}", "List[List[a, b], 1]")
        , ("tagged assignments route natural own down and sub values", "ClearAll[f, x, y]; a = TagSet[f, f, 7]; own = {a, f, OwnValues[f]}; ClearAll[f]; b = TagSetDelayed[f, f[x_], x + 1]; down = {b, f[3], DownValues[f], UpValues[f]}; ClearAll[f]; c = TagSetDelayed[f, f[x_][y_], {x, y}]; {own, down, c, f[1][2], SubValues[f], UpValues[f]}", "List[List[7, 7, List[RuleDelayed[HoldPattern[f], 7]]], List[Null, 4, List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Plus[x, 1]]], List[]], Null, List[1, 2], List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], List[x, y]]], List[]]")
        , ("tagged immediate and delayed upvalues preserve rhs timing", "ClearAll[f, g, h, x, y]; y = 5; a = TagSet[f, h[f[x_]], x + y]; first = h[f[3]]; y = 10; TagSetDelayed[g, h[g[x_]], x + y]; {a, first, h[f[3]], h[g[3]], UpValues[f], UpValues[g], DownValues[h]}", "List[Plus[5, x], 8, 8, 13, List[RuleDelayed[HoldPattern[h[f[Pattern[x, Blank[]]]]], Plus[5, x]]], List[RuleDelayed[HoldPattern[h[g[Pattern[x, Blank[]]]]], Plus[x, y]]], List[]]")
        , ("upvalues beat head downvalues", "ClearAll[f, h, x]; TagSetDelayed[f, h[f[x_]], up[x]]; h[x_] := down[x]; {h[f[1]], UpValues[f], DownValues[h]}", "List[up[1], List[RuleDelayed[HoldPattern[h[f[Pattern[x, Blank[]]]]], up[x]]], List[RuleDelayed[HoldPattern[h[Pattern[x, Blank[]]]], down[x]]]]")
        , ("upvalue candidates are tried left to right", "ClearAll[a, b, h]; TagSetDelayed[a, h[a, b], froma]; TagSetDelayed[b, h[a, b], fromb]; h[a, b]", "froma")
        , ("upvalues beat call head subvalues", "ClearAll[f, g, x, y]; g[x_][y_] := sub; TagSetDelayed[f, g[x_][f], up]; g[1][f]", "up")
        , ("upvalue head chain dispatch and hold suppression", "ClearAll[f, h, q, r, x, y]; SetAttributes[q, HoldAll]; TagSetDelayed[f, q[f[x_]], held[x]]; SetAttributes[r, HoldAllComplete]; TagSetDelayed[f, r[f[x_]], blocked[x]]; TagSetDelayed[f, h[f[x_][y_]], {x, y}]; {q[f[2]], r[f[3]], h[f[1][2]], UpValues[f]}", "List[held[2], r[f[3]], List[1, 2], List[RuleDelayed[HoldPattern[q[f[Pattern[x, Blank[]]]]], held[x]], RuleDelayed[HoldPattern[r[f[Pattern[x, Blank[]]]]], blocked[x]], RuleDelayed[HoldPattern[h[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]]], List[x, y]]]]")
        , ("upvalue conditions callbacks and bare Return share definition dispatch", "ClearAll[f, h, x, c]; c = 0; TagSetDelayed[f, h[f[x_ /; (c = c + 1; x > 0)]], (c = c + 10; Return[x])]; {h[f[-1]], h[f[2]], c}", "List[h[f[-1]], 2, 12]")
        , ("duplicate upvalue candidates retain one failed match effect", "ClearAll[c, f, h, x, y]; c = 0; TagSetDelayed[f, h[f[x_], f[y_]], Condition[hit, c = c + 1; False]]; {h[f[1], f[2]], c}", "List[h[f[1], f[2]], 1]")
        , ("tagged unset removes exact upvalue equations", "ClearAll[f, h, x]; TagSetDelayed[f, h[f[x_]], x]; a = {h[f[2]], UpValues[f]}; b = TagUnset[f, h[f[x_]]]; {a, b, h[f[2]], UpValues[f]}", "List[List[2, List[RuleDelayed[HoldPattern[h[f[Pattern[x, Blank[]]]]], x]]], Null, h[f[2]], List[]]")
        , ("tagged special settings use canonical own equations", "a = TagSet[$OutputSizeLimit, $OutputSizeLimit, 99]; b = TagUnset[$OutputSizeLimit, $OutputSizeLimit]; {a, b, $OutputSizeLimit, OwnValues[$OutputSizeLimit]}", "List[99, Null, $OutputSizeLimit, List[]]")
        , ("tagged own equations use visible context spelling", "ClearAll[Global`f]; Global`f = 7; {OwnValues[Global`f], TagUnset[Global`f, Global`f], Global`f, TagUnset[Global`f, f], Global`f}", "List[List[RuleDelayed[HoldPattern[f], 7]], $Failed, 7, Null, Global`f]")
        , ("clear removes own and down values", "f[x_] := x; f = 7; Clear[f]; {f, f[3], DownValues[f]}", "List[f, f[3], List[]]")
        , ("iterator downvalue mutations persist", "f[x_] := x; Table[f[i] = i^2, {i, 3}]; {f[1], f[2], f[3], f[4], DownValues[f]}", "List[1, 4, 9, 4, List[RuleDelayed[HoldPattern[f[1]], 1], RuleDelayed[HoldPattern[f[2]], 4], RuleDelayed[HoldPattern[f[3]], 9], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], x]]]")
        , ("held assignment remains inert", "Hold[x = 9]; x", "x")
        , ("If evaluates one stateful branch", "If[False, x = 1, x = 2]; x", "2")
        , ("And short circuits state", "False && (x = 1); x", "x")
        , ("Or short circuits state", "True || (x = 1); x", "x")
        , ("selection predicates thread session state", "y = 0; {Select[{a, b}, Function[x, y = y + 1; True]], y}", "List[List[a, b], 2]")
        , ("selection property projections", "{Select[{a, b}, Function[x, True] -> \"Index\"], Select[{a, b}, Function[x, True] -> {\"Element\", \"Index\"}], SelectFirst[{a, b}, Function[x, True] -> \"Index\", none]}", "List[List[1, 2], Association[Rule[\"Element\", List[a, b]], Rule[\"Index\", List[1, 2]]], 1]")
        , ("selection property duplicate normalization", "Select[{a, b}, Function[x, True] -> {\"Index\", \"Index\"}]", "Association[Rule[\"Index\", List[1, 2]]]")
        , ("selection operator forms", "{Select[EvenQ][{1,2,3,4}], Discard[EvenQ][{1,2,3,4}], SelectFirst[EvenQ][{1,2,3,4}]}", "List[List[2, 4], List[1, 3], 2]")
        , ("SelectFirst holds an unused default", "y = 0; {SelectFirst[{a}, True &, y = y + 1], y}", "List[a, 0]")
        , ("SelectFirst returns an unevaluated default", "y = 0; {SelectFirst[{a}, False &, y = y + 1], y, SelectFirst[{a}, False &, 1 + 2]}", "List[Set[y, Plus[y, 1]], 0, Plus[1, 2]]")
        , ("pattern operands stay held across own values", "x = 1; {Cases[{a}, x_], MatchQ[a, x_], a /. x_ -> Hold[x]}", "List[List[a], True, Hold[a]]")
        , ("condition patterns call delayed session definitions", "p[x_] := x > 1; Cases[{1, 2, 3}, x_ /; p[x]]", "List[2, 3]")
        , ("condition callbacks thread state in traversal order", "c = 0; {Cases[{1, 2, 3}, x_ /; (c = c + 1; x > 1)], c}", "List[List[2, 3], 3]")
        , ("pattern test callbacks thread state in traversal order", "c = 0; {Cases[{1, 2, 3}, x_?(Function[y, c = c + 1; y > 1])], c}", "List[List[2, 3], 3]")
        , ("pattern subjects evaluate before callbacks", "c = 0; Cases[(c = 10; {1, 2}), x_ /; (c = c + 1; True)]; c", "12")
        , ("pattern rules distinguish eager and delayed templates", "c = 0; first = f[a, a] /. a -> (c = c + 1; b); eager = c; c = 0; second = f[a, a] /. a :> (c = c + 1; b); {first, eager, second, c}", "List[f[b, b], 1, f[b, b], 2]")
        , ("failed pattern alternatives preserve callback effects", "c = 0; {MatchQ[a, (x_ /; (c = c + 1; False)) | (x_ /; (c = c + 1; True))], c}", "List[True, 2]")
        , ("effectful key value patterns share the matcher", "c = 0; {Cases[{<|a -> 1|>}, KeyValuePattern[a -> (x_ /; (c = c + 1; True))]], c}", "List[List[Association[Rule[a, 1]]], 1]")
        , ("pattern search family threads callbacks and short circuits", "c = 0; deleted = DeleteCases[{1, 2, 3}, x_ /; (c = c + 1; x > 1)]; dc = c; c = 0; first = FirstCase[{1, 2, 3}, x_ /; (c = c + 1; x > 1)]; fc = c; c = 0; member = MemberQ[{1, 2, 3}, x_ /; (c = c + 1; x > 1)]; {deleted, dc, first, fc, member, c}", "List[List[1], 3, 2, 2, True, 2]")
        , ("position count and free searches preserve callback order", "c = 0; positions = Position[{1, 2, 3}, x_ /; (c = c + 1; x > 1)]; pc = c; c = 0; counted = Count[{1, 2, 3}, x_ /; (c = c + 1; x > 1)]; cc = c; c = 0; free = FreeQ[{1, 2, 3}, x_ /; (c = c + 1; x > 5)]; {positions, pc, counted, cc, free, c}", "List[List[List[2], List[3]], 5, 2, 3, True, 5]")
        , ("replacement family shares effectful pattern matching", "c = 0; replaced = Replace[{1, 2, 3}, (x_ /; (c = c + 1; x > 1)) -> z, {1}]; rc = c; c = 0; at = ReplaceAt[{1, 2, 3}, (x_ /; (c = c + 1; x > 1)) :> z, {{1}, {2}, {3}}]; ac = c; c = 0; all = ReplaceAll[f[1, 2, 3], (x_ /; (c = c + 1; x > 1)) :> z]; {replaced, rc, at, ac, all, c}", "List[List[1, z, z], 3, List[1, z, z], 3, f[1, z, z], 5]")
        , ("pattern Heads options match traversal semantics", "{Cases[f[a], _, Heads -> True], Cases[f[a], _, {0, Infinity}, 2, Heads -> True], DeleteCases[f[a], _, Heads -> True], DeleteCases[f[a], _, {0, Infinity}, 1, Heads -> True], Replace[f[a], x_ -> h[x], {0, Infinity}, Heads -> True], FreeQ[f[a], f, Heads -> False], Position[f[a], f, Heads -> False], Position[f[a], f, Heads -> True]}", "List[List[f, a], List[f, a], a, h[h[f][h[a]]], True, List[], List[List[0]]]")
        , ("nested head deletion splices surviving arguments", "DeleteCases[f[1, g[2, g], 3], g, {0, Infinity}, Heads -> True]", "f[1, 2, 3]")
        , ("FirstCase prepares rules once and keeps defaults held", "c = 0; first = FirstCase[{a}, x_ -> (c = c + 1; x)]; eager = c; x = 0; {first, eager, FirstCase[{a}, _Integer, (x = 1; none)], x}", "List[a, 1, CompoundExpression[Set[x, 1], none], 0]")
        , ("downvalue pattern callbacks share one effectful match", "c = 0; q[x_] := (c = c + 1; x > 1); f[x_ /; q[x]] := x; {f[1], f[2], c}", "List[f[1], 2, 2]")
        , ("downvalue PatternTest and Condition callbacks run once", "c = 0; f[(x_?(c = c + 1; IntegerQ)) /; (c = c + 10; True)] := x; {f[1], c}", "List[1, 11]")
        , ("map callbacks thread session state", "y = 0; {Map[Function[x, y = y + 1; x], {a, b}], y}", "List[List[a, b], 2]")
        , ("map level specifications", "{Map[f, {a, b}, {0}], Map[f, {a, {b, c}}, {2}], Map[f, {a, {b, c}}, {1, 2}]}", "List[f[List[a, b]], List[a, List[f[b], f[c]]], List[f[a], f[List[f[b], f[c]]]]]")
        , ("apply level specifications", "{Apply[f, {a, b}, {0}], Apply[f, {a, {b, c}}, {2}], Apply[f, {a, {b, c}}, {1, 2}]}", "List[f[a, b], List[a, List[b, c]], List[a, f[b, c]]]")
        , ("map normalizes generated Nothing", "Map[Nothing &, {a, b}]", "List[]")
        , ("Nothing is callable during mapping", "Map[Nothing, {a, b}]", "List[]")
        , ("associations are callable during mapping", "Map[<|a -> 1, b -> 2|>, {a, b, c}]", "List[1, 2, Missing[\"KeyAbsent\", c]]")
        , ("map normalizes generated Sequence", "f[x_] := Sequence[x, q]; Map[f, {a, b}]", "List[a, q, b, q]")
        , ("map at normalizes generated Nothing", "MapAt[Nothing &, {a, b}, 1]", "List[b]")
        , ("map at resolves negative positions before ordering callbacks", "y = 0; {MapAt[Function[x, y = y + 1], {a, b}, {{-1}, {1}}], y}", "List[List[2, 1], 2]")
        , ("map at expands exact selector components", "{MapAt[f, {a, b, c}, {All}], MapAt[f, {a, b, c}, {2 ;; 3}], MapAt[f, {a, b, c}, {{{1, 3}}}], MapAt[f, <|a -> 1, b -> 2, c -> 3|>, {{{Key[a], Key[c]}}}]}", "List[List[f[a], f[b], f[c]], List[a, f[b], f[c]], List[f[a], b, f[c]], Association[Rule[a, f[1]], Rule[b, 2], Rule[c, f[3]]]]")
        , ("association callbacks thread session state", "y = 0; {KeyValueMap[Function[{k, v}, y = y + 1; HoldComplete[k, v]], <|a -> 1, b -> 2|>], y}", "List[List[HoldComplete[a, 1], HoldComplete[b, 2]], 2]")
        , ("association Nothing keys normalize by last value", "{<|Nothing -> 1, Nothing -> 2|>, KeyMap[Nothing &, <|a -> 1, b -> 2|>]}", "List[Association[Rule[Nothing, 2]], Association[Rule[Nothing, 2]]]")
        , ("sort keys thread session state", "y = 0; {SortBy[{b, a}, Function[x, y = y + 1; x]], y}", "List[List[a, b], 2]")
        , ("sort by operator form threads session state", "y = 0; {SortBy[Function[x, y = y + 1; x]][{b, a}], y}", "List[List[a, b], 2]")
        , ("sort comparator follows CPython callback schedule", "c = 0; t = 0; {SortBy[{1, 2, 3, 4}, Identity, Function[{a, b}, c = c + 1; t = 100*t + 10*a + b; a < b]], c, t}", "List[List[1, 2, 3, 4], 6, 211232234334]")
        , ("sort by SameTest precedes component ordering and requires exact True", "{SortBy[{{2, 1}, {1, 2}}, {First, Last}, SameTest -> (True &)], SortBy[{{2, 1}, {1, 2}}, {First, Last}, SameTest -> (1 &)]}", "List[List[List[2, 1], List[1, 2]], List[List[1, 2], List[2, 1]]]")
        , ("sort by SameTest and key lists preserve stable ties", "{SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last, SameTest -> Automatic], SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last, SameTest -> (False &)], SortBy[{{c, 2}, {a, 2}, {b, 1}}, {Last}, SameTest -> (False &)]}", "List[List[List[b, 1], List[a, 2], List[c, 2]], List[List[b, 1], List[c, 2], List[a, 2]], List[List[b, 1], List[c, 2], List[a, 2]]]")
        , ("sort by SameTest distinguishes eager and delayed rules", "c = 0; first = SortBy[{4, 3, 2, 1}, Identity, SameTest -> (c = c + 1; (False &))]; eager = c; c = 0; second = SortBy[{4, 3, 2, 1}, Identity, SameTest :> (c = c + 1; (False &))]; {first, eager, second, c}", "List[List[1, 2, 3, 4], 1, List[1, 2, 3, 4], 3]")
        , ("sort by last SameTest option wins", "c = 0; {SortBy[{2, 1}, Identity, SameTest -> (c = c + 1; (True &)), SameTest :> (c = c + 10; (False &))], c}", "List[List[1, 2], 11]")
        , ("reverse sort by preserves SameTest ties", "ReverseSortBy[{2, 1}, Identity, SameTest -> (True &)]", "List[2, 1]")
        , ("assignment update", "x = 10; AddTo[x, 5]; x", "15")
        , ("assignment updates cannot bypass protection", "protectedUpdateX = 2; Protect[protectedUpdateX]; {AddTo[protectedUpdateX, 1 + 2], protectedUpdateX}", "List[AddTo[protectedUpdateX, 3], 2]")
        , ("assignment updates leave special settings unchanged", "AddTo[$RecursionLimit, -1000]; $RecursionLimit", "1024")
        , ("in-place arithmetic attributes come from the catalog", "{Attributes[AppendTo], Attributes[Increment], Attributes[Decrement], Attributes[PreIncrement], Attributes[PreDecrement]}", "List[List[HoldFirst, Protected], List[HoldFirst, Protected, ReadProtected], List[HoldFirst, Protected, ReadProtected], List[HoldFirst, Protected, ReadProtected], List[HoldFirst, Protected, ReadProtected]]")
        , ("in-place arithmetic returns old or new values", "ClearAll[x]; x = 5; {Increment[x], x, Decrement[x], x, PreIncrement[x], x, PreDecrement[x], x}", "List[5, 6, 6, 5, 6, 6, 5, 5]")
        , ("in-place arithmetic mutates the raw alias target", "ClearAll[x, y, first]; x = y; y = 5; first = {x++, x, y}; ClearAll[x]; {first, {x++, x}}", "List[List[5, 6, 5], List[x, Plus[1, x]]]")
        , ("in-place arithmetic preserves the old Unevaluated wrapper but strips it from Plus", "ClearAll[x]; x = Unevaluated[5]; {x++, x, OwnValues[x]}", "List[Unevaluated[5], 6, List[RuleDelayed[HoldPattern[x], 6]]]")
        , ("in-place arithmetic stores one-step Unevaluated payloads", "ClearAll[x]; x = Unevaluated[Sequence[5, 6]]; {x++, x, OwnValues[x]}", "List[Unevaluated[Sequence[5, 6]], 12, List[RuleDelayed[HoldPattern[x], Plus[1, Sequence[5, 6]]]]]")
        , ("AppendTo rebuilds lists generic calls and associations", "ClearAll[x, y, z]; x = {1, 2}; y = f[a]; z = <|a -> 1, b -> 2|>; {AppendTo[x, 3], x, AppendTo[y, b], y, AppendTo[z, b -> 9], z}", "List[List[1, 2, 3], List[1, 2, 3], f[a, b], f[a, b], Association[Rule[a, 1], Rule[b, 9]], Association[Rule[a, 1], Rule[b, 9]]]")
        , ("AppendTo pre-normalizes Sequence by literal head spelling", "ClearAll[f, x, y, z]; SetAttributes[f, SequenceHold]; x = f[a]; y = System`HoldComplete[a]; z = HoldComplete[a]; {AppendTo[x, Sequence[b, c]], x, AppendTo[y, Sequence[b, c]], y, AppendTo[z, Sequence[b, c]], z}", "List[f[a, b, c], f[a, b, c], System`HoldComplete[a, b, c], System`HoldComplete[a, b, c], HoldComplete[a, Sequence[b, c]], HoldComplete[a, Sequence[b, c]]]")
        , ("AppendTo treats a malformed Association as a generic call", "ClearAll[x]; x = Association[bad]; {AppendTo[x, c], x}", "List[Association[bad, c], Association[bad, c]]")
        , ("AppendTo drops Nothing from a qualified malformed Association", "ClearAll[x]; x = System`Association[a]; {AppendTo[x, Nothing], x}", "List[System`Association[a], System`Association[a]]")
        , ("AppendTo delegates compound targets to Set", "ClearAll[f]; f[x_] := {x}; {AppendTo[f[a], 2], f[a], DownValues[f]}", "List[List[a, 2], List[a, 2], List[RuleDelayed[HoldPattern[f[a]], List[a, 2]], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], List[x]]]]")
        , ("mutation qualification and aliases keep raw dispatch boundaries", "ClearAll[x, a, qi, qa]; x = 5; a = {1}; qi = Increment; qa = AppendTo; {System`Increment[x], System`Decrement[x], System`PreIncrement[x], System`PreDecrement[x], x, qi[x], Global`Increment[x], qa[a, 2], Global`AppendTo[a, 2], a}", "List[5, 6, 6, 5, 5, Increment[x], Global`Increment[5], AppendTo[a, 2], Global`AppendTo[List[1], 2], List[1]]")
        , ("mutation control exits stop before assignment", "ClearAll[x]; x = {1}; {Catch[AppendTo[x, Throw[7]]], x}", "List[7, List[1]]")
        , ("qualified ByteArrayQ aliases retain scalar dispatch", "f = System`ByteArrayQ; f[ByteArray[{1}]]", "True")
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
        , ("root abort becomes aborted", "Abort[]", "$Aborted")
        , ("check abort catches its body abort", "CheckAbort[Abort[], caught]", "caught")
        , ("abort protect releases its pending abort at the boundary", "CheckAbort[AbortProtect[Abort[]; 7], caught]", "caught")
        , ("same-depth check abort handles a fresh abort inside protection", "AbortProtect[CheckAbort[Abort[], inner]]", "inner")
        , ("abort scopes restore across throw and return", "ClearAll[f]; f[] := AbortProtect[Return[returned]]; {Catch[AbortProtect[Throw[thrown]]], f[], CheckAbort[Abort[], caught]}", "List[thrown, returned, caught]")
        , ("with cleanup evaluates init body and cleanup exactly once", "x = 0; result = WithCleanup[x = x + 1, x = x + 10, x = x + 100]; {result, x}", "List[11, 111]")
        , ("cleanup abort supersedes a completed body", "WithCleanup[7, Abort[]]", "$Aborted")
        , ("cleanup throw supersedes a body throw", "Catch[WithCleanup[Throw[body], Throw[cleanup]]]", "cleanup")
        , ("cleanup return supersedes a body return", "WithCleanup[Return[body], Return[cleanup]]", "Return[cleanup]")
        , ("cleanup throw supersedes a body abort", "CheckAbort[Catch[WithCleanup[Abort[], Throw[cleanup]]], caught]", "cleanup")
        , ("cleanup return and throw cross definition boundaries", "ClearAll[f, g]; f[] := Catch[WithCleanup[Throw[body], Return[cleanup]]]; g[] := Catch[WithCleanup[Return[body], Throw[cleanup]]]; {f[], g[]}", "List[cleanup, cleanup]")
        , ("sow outside reap returns its evaluated value", "x = 0; {Sow[x = x + 1], x}", "List[1, 1]")
        , ("reap collects default and distinct tags in order", "{Reap[Sow[1]; Sow[2]; 3], Reap[Sow[1, a]; Sow[2, b]; Sow[3, a]; 4]}", "List[List[3, List[List[1, 2]]], List[4, List[List[1, 3], List[2]]]]")
        , ("reap literal and typed pattern selectors filter tags", "{Reap[Sow[1, a]; Sow[2, b]; 3, a], Reap[Sow[1, a]; Sow[2, 2]; 3, {_Symbol, _Integer}]}", "List[List[3, List[List[1]]], List[3, List[List[List[1]], List[List[2]]]]]")
        , ("sow list tags populate each selector bucket", "Reap[Sow[1, {a, b}]; 3, {a, b}]", "List[3, List[List[List[1]], List[List[1]]]]")
        , ("reap combiners receive each tag and ordered value list", "{Reap[Sow[1, a]; Sow[2, a]; 3, _, f], Reap[Sow[1]; 3, _, f]}", "List[List[3, List[f[a, List[1, 2]]]], List[3, List[f[None, List[1]]]]]")
        , ("nested reap routes to the nearest matching scope", "{Reap[Reap[Sow[1, a]; 2, a], _], Reap[Reap[Sow[1, b]; 2, a], _]}", "List[List[List[2, List[List[1]]], List[]], List[List[2, List[]], List[List[1]]]]")
        , ("reap pops before its combiner so sow reaches the outer scope", "Reap[Reap[Sow[1, a], a, Function[{tag, values}, Sow[values, outer]]], outer]", "List[List[1, List[List[1]]], List[List[List[1]]]]")
        , ("reap evaluates selector and combiner before the body", "x = 0; result = Reap[(x = 100; Sow[x, a]), (x = x + 1; a), (x = x + 10; f)]; {result, x}", "List[List[100, List[f[a, List[100]]]], 100]")
        , ("reap scopes restore across throw abort and goto", "{Catch[Reap[Sow[1]; Throw[thrown]]], CheckAbort[Reap[Sow[2]; Abort[]], caught], (Reap[Sow[3]; Goto[out]]; never; Label[out]; reached), Sow[4]}", "List[thrown, caught, reached, 4]")
        , ("reap remains popped when a combiner exits by control", "{Catch[Reap[Sow[1, a], _, Function[{tag, values}, Throw[done]]]], Sow[2]}", "List[done, 2]")
        , ("qualified reap and sow share native collection scopes", "System`Reap[System`Sow[1]; 2]", "List[2, List[List[1]]]")
        , ("goto supports forward and backward labels", "ClearAll[x]; first = (Goto[end]; never; Label[end]; reached); x = 0; second = (Label[start]; x = x + 1; If[x < 3, Goto[start]]; x); {first, second}", "List[reached, 3]")
        , ("goto catches at the nearest matching compound expression", "ClearAll[x]; x = 0; {(Label[a]; x = x + 1; If[x == 1, Goto[a]]; Label[a]; x), ((Goto[inner]; never; Label[inner]; reached)), ((Goto[out]; innerNever; Label[other]); outerNever; Label[out]; reached)}", "List[2, reached, reached]")
        , ("goto compares evaluated targets with raw label tags", "ClearAll[x]; x = end; (Goto[x]; never; Label[x]; reached)", "Goto[end]")
        , ("label qualification and aliases preserve raw dispatch boundaries", "ClearAll[l, g, first]; first = {Label[1 + 2], System`Label[1 + 2], Global`Label[1 + 2]}; l = Label; g = Goto; {first, {l[Sequence[a, b]], g[Sequence[a, b]]}}", "List[List[Label[Plus[1, 2]], Label[Plus[1, 2]], Global`Label[3]], List[Label[a, b], Goto[a, b]]]")
        , ("goto handles trailing and qualified labels", "{(a; Label[end]), (Goto[end]; Label[end]), (System`Goto[end]; never; System`Label[end]; reached)}", "List[Label[end], Null, reached]")
        , ("goto restores dynamic and iterator scopes", "ClearAll[i, x, f]; i = 99; x = 1; f[] := Goto[out]; (Block[{x = 2}, x = 3; Do[f[], {i, 1, 3}]]; never; Label[out]; {x, i})", "List[1, 99]")
        , ("standalone labels remain inert", "{Label[done], HoldComplete[Goto[held]]}", "List[Label[done], HoldComplete[Goto[held]]]")
        , ("uncaught goto remains inert", "Goto[missing]", "Goto[missing]")
        , ("uncaught throw handler", "Throw[x, tag, h]", "h[x, tag]")
        , ("caught throw ignores throw handler", "Catch[Throw[x, tag, h], tag]", "x")
        , ("unmatched throw stays inert", "Catch[Throw[x, tag], other]", "Throw[x, tag]")
        , ("do throw restoration", "i = 99; x = 0; {Catch[Do[x = x + 1; Throw[i], {i, 5}, {j, 5}]], i, x}", "List[1, 99, 1]")
        , ("accumulator throw restoration", "i = 99; {Catch[Sum[Throw[s], {i, 1, 5}]], i, Catch[Product[Throw[p], {i, 1, 5}]], i}", "List[s, 99, p, 99]")
        , ("bare break stays inert", "Break[]", "Break[]")
        , ("bare continue stays inert", "Continue[]", "Continue[]")
        , ("invalid loop control stays inert", "{Break[x], Continue[x]}", "List[Break[x], Continue[x]]")
        , ("table does not catch break", "Table[Break[], {i, 1, 3}]", "Break[]")
        , ("accumulators do not catch loop control", "Sum[Break[], {i, 1, 3}]", "Break[]")
        , ("do break exits all iterator levels", "x = 0; Do[x = x + 1; Break[]; x = 99, {i, 2}, {j, 3}]; x", "1")
        , ("do continue advances innermost iterator", "x = 0; Do[x = x + 1; Continue[]; x = 99, {i, 2}, {j, 3}]; x", "6")
        , ("do loop control restores bindings", "i = 99; x = 0; Do[x = x + 1; Break[], {i, 3}]; first = {i, x}; x = 0; Do[x = x + 1; Continue[], {i, 3}]; {first, i, x}", "List[List[99, 1], 99, 3]")
        , ("while normal and single-argument loops", "{While[False, x = 1], Module[{i = 0}, While[(i = i + 1) < 5]; i]}", "List[Null, 5]")
        , ("while break and continue", "{Module[{i = 0}, While[i < 10, i = i + 1; If[i == 5, Break[]]]; i], Module[{i = 0, s = 0}, While[i < 5, i = i + 1; If[EvenQ[i], Continue[]]; s = s + i]; s]}", "List[5, 9]")
        , ("for normal break and continue", "{Module[{s = 0}, For[i = 1, i <= 5, i = i + 1, s = s + i]; s], Module[{s = 0}, For[i = 1, i <= 10, i = i + 1, If[EvenQ[i], Continue[]]; s = s + i]; s], Module[{s = 0}, For[i = 1, i <= 10, i = i + 1, If[i > 5, Break[]]; s = s + i]; s]}", "List[15, 25, 15]")
        , ("for phase ordering", "Module[{n = 0, log = 0}, For[log = 10*log + 1, (log = 10*log + 2; n = n + 1; n <= 2), log = 10*log + 4, log = 10*log + 3]; log]", "12342342")
        , ("while phase ordering", "Module[{n = 0, log = 0}, While[(log = 10*log + 1; n = n + 1; n <= 2), log = 10*log + 2]; log]", "12121")
        , ("loop break covers every phase", "{For[Break[], False, Null, Null], For[Null, Break[], Null, Null], For[Null, True, Break[], Null], For[Null, True, Null, Break[]], While[Break[], Null], While[True, Break[]]}", "List[Null, Null, Null, Null, Null, Null]")
        , ("for continue still runs increment", "x = 0; {For[x = 1, True, Break[], x = 2], x}", "List[Null, 2]")
        , ("continue outside for body propagates", "For[Null, True, Continue[], Null]", "Continue[]")
        , ("continue outside while body propagates", "While[Continue[], Null]", "Continue[]")
        , ("headed return covers every for phase", "{For[Return[init, For], False, Null, Null], For[Null, Return[test, For], Null, Null], For[Null, True, Return[incr, For], Null], For[Null, True, Null, Return[body, For]]}", "List[init, test, incr, body]")
        , ("headed return covers while test and body", "{While[Return[test, While], Null], While[True, Return[body, While]]}", "List[test, body]")
        , ("mismatched loop return propagates", "For[Null, True, Null, Return[other, While]]", "Return[other, While]")
        , ("bare loop return propagates", "For[Null, True, Null, Return[bare]]", "Return[bare]")
        , ("outer lexical return crosses loop", "Module[{}, For[Null, True, Null, Return[outer, Module]]; never]", "outer")
        , ("loop state persists across exits", "x = 0; {For[x = 1, True, x = x + 1, Return[x = x + 10, For]], x}", "List[11, 11]")
        , ("for does not localize variables", "i = 99; {For[i = 1, i <= 2, i = i + 1, Null], i}", "List[Null, 3]")
        , ("nontrue loop tests stop immediately", "x = 0; {For[x = x + 1, 1, x = x + 10, x = x + 100], x, While[1, x = 99], x}", "List[Null, 1, Null, 1]")
        , ("invalid loop arities hold every operand", "x = 0; {For[x = 1, True, Null], While[x = 2, Null, extra], While[], x}", "List[For[Set[x, 1], True, Null], While[Set[x, 2], Null, extra], While[], 0]")
        , ("evaluated loop heads remain held", "x = 0; f = For; w = While; f[x = 1, True, Null, Null]; w[False, x = 2]; x", "0")
        , ("loop safety cap matches python boundary", "n = 0; For[Null, n <= 65536, n = n + 1, Null]; f = n; n = 0; While[n <= 65536, n = n + 1]; {f, n}", "List[65537, 65537]")
        , ("level session output does not reevaluate held selections", "x = 7; Level[Hold[x], {1}]", "List[x]")
        , ("level session strips unevaluated without payload evaluation", "x = 7; Level[Unevaluated[f[x]], Infinity]", "List[x]")
        , ("evaluated level aliases preserve selected held symbols", "x = 7; l = Level; l[Hold[x], {1}]", "List[x]")
        , ("uncaught return remains inert", "Return[5]", "Return[5]")
        , ("empty return carries null", "Return[]", "Return[Null]")
        , ("catch does not intercept return", "Catch[Return[6]]", "Return[6]")
        , ("unmatched headed return remains inert", "Return[v, Module]", "Return[v, Module]")
        , ("bare return exits matched definitions", "f[x_] := Module[{r}, r = x; If[r > 10, Return[big]]; r]; g[x_] := (If[x > 0, Return[positive]]; If[x < 0, Return[negative]]; zero); h[x_] := Do[If[i == 3, Return[done]], {i, 1, 5}]; {f[5], f[20], g[5], g[-3], g[0], h[0]}", "List[5, big, positive, negative, zero, done]")
        , ("return exits delayed rhs conditions", "f[x_] := body /; Return[escaped]; f[1]", "escaped")
        , ("return does not cross rejected definition", "f[x_] := first /; False; f[x_] /; Return[escaped] := second; f[1]", "Return[escaped]")
        , ("headed return exits lexical and loop bodies", "{Module[{}, Return[42, Module]; never], Module[{}, Do[If[i == 3, Return[i, Module]], {i, 1, 5}]; never], Module[{}, Do[If[i == 4, Return[i, Do]], {i, 1, 10}]]}", "List[42, 3, 4]")
        , ("headed return exits dynamic scopes safely", "x = 100; {Block[{x = 0}, x = 1; Return[blockResult, Block]; x = 2], x, InheritedBlock[{x = 0}, x = 1; Return[inherited, InheritedBlock]], x, Internal`InheritedBlock[{x = 0}, x = 1; Return[qualified, InheritedBlock]], x}", "List[blockResult, 100, inherited, 100, qualified, 100]")
        , ("return evaluates target before value", "x = 0; {Module[{}, Return[x = x + 1, (x = x + 1; Module)]], x, Return[x = 99, x = x + 1], x}", "List[2, 2, Return[Set[x, 99], Set[x, Plus[x, 1]]], 3]")
        , ("invalid return forms preserve value operands", "x = 0; {Return[x = 1, a, b], x}", "List[Return[Set[x, 1], a, b], 0]")
        , ("do return restores iterator bindings", "i = 99; {Do[If[i == 3, Return[i, Do]], {i, 1, 5}], i}", "List[3, 99]")
        , ("pure functions do not catch return", "Function[x, Return[x]][5]", "Return[5]")
        , ("nested positional functions keep independent slots", "Function[Function[#1]][a][b]", "b")
        , ("qualified nested positional functions shield outer slots", "Function[System`Function[#1]][a][b]", "b")
        , ("qualified named functions and scopes shield bindings", "{Function[x, System`Function[x, x]][1][b], With[{x = 1}, System`Function[x, x]][b], Function[x, System`With[{x = b}, x]][a]}", "List[b, b, b]")
        , ("qualified scoping and iterator constructors are consumed", "{Module[System`List[System`Set[x, 1]], x], System`Module[System`List[System`Set[x, 1]], x], With[System`List[System`Set[x, 2]], x], Block[System`List[System`Set[x, 3]], x], Table[i, System`List[i, 2]], System`Table[i, System`List[i, 2]]}", "List[1, 1, 2, 3, List[1, 2], List[1, 2]]")
        , ("module renaming canonicalizes qualified binding lists", "{Module[{x}, HoldComplete[System`With[System`List[System`Set[y, x]], y]]], Module[{x}, HoldComplete[System`Function[System`List[y], x + y]]]}", "List[HoldComplete[System`With[List[System`Set[y, x$1]], y]], HoldComplete[System`Function[List[y], Plus[x$2, y]]]]")
        , ("qualified slots and function self preserve spelling", "{Function[System`Slot[1]][x], Function[System`SlotSequence[1]][a, b], System`Function[Slot[0]][x], System`Function[System`Slot[0]][x]}", "List[x, a, b, System`Function[Slot[0]], System`Function[System`Slot[0]]]")
        , ("qualified functions hold bodies and canonicalize parameter lists", "{System`Function[Head[#]][1], Function[x, HoldComplete[System`Function[System`List[y], x + y]]][y]}", "List[Integer, HoldComplete[System`Function[List[y$], Plus[y, y$]]]]")
        , ("Slot zero returns the pure function itself", "(#0 &)[x]", "Function[Slot[0]]")
        , ("qualified Null marks positional functions", "Function[System`Null, #1 + #2][a, b]", "Plus[a, b]")
        , ("named slots project associations and callable arguments", "{(#name &)[<|\"name\" -> 7|>], (#name &)[x]}", "List[7, x[\"name\"]]")
        , ("SequenceHold preserves Sequence values through SlotSequence", "Function[Null, HoldComplete[##], SequenceHold][Sequence[a, b]]", "HoldComplete[Sequence[a, b]]")
        , ("HoldAllComplete preserves held Sequence values through SlotSequence", "Function[Null, HoldComplete[##], HoldAllComplete][Sequence[1 + 2, 3 + 4]]", "HoldComplete[Sequence[Plus[1, 2], Plus[3, 4]]]")
        , ("definition catches return through pure function", "f[x_] := Function[y, Return[x]][y]; f[7]", "7")
        , ("definition catches return through with", "q[x_] := With[{y = x + 1}, Return[y]]; q[5]", "6")
        , ("module initializers do not catch return", "Module[{a = 1, b = Return[stop, Module]}, never]", "Return[stop, Module]")
        , ("block initializer return restores localized state", "x = 100; {Module[{}, Block[{x = Return[stop, Module]}, never]; after], x}", "List[stop, 100]")
        , ("return target aliases evaluate", "h = Module; Module[{}, Return[v, h]]", "v")
        , ("evaluated return heads evaluate ordinary arguments", "x = 0; r = Return; r[x = x + 1]; x", "1")
        , ("block initializers use dynamic left-to-right scope", "x = 100; y = 200; {Block[{x = 5, y = x + 1}, {x, y}], x, y}", "List[List[5, 6], 100, 200]")
        , ("block restores own and down values", "x = 100; f[1] = 99; {Block[{x, f}, {x, f[1], x = 5, f[2] = 88}], x, f[1], f[2]}", "List[List[100, 99, 5, 88], 100, 99, f[2]]")
        , ("block own value bypasses downvalue dispatch", "f[x_] := x^2; {Block[{f = 7}, f[3]], f[3]}", "List[7[3], 9]")
        , ("block delayed nested and lexical composition", "seed = 5; {Block[{f := seed = seed + 1}, {f, f}], seed, f, Block[{x = 1}, Block[{x = 2, y = x + 1}, {x, y}]], Block[{x = 5}, Function[y, x + y][3]], Block[{x = 5}, Module[{y = x + 1}, y]]}", "List[List[6, 7], 7, f, List[2, 3], 8, 6]")
        , ("block restores initializer and body control exits", "x = 100; y = 200; z = 0; {Catch[Block[{x = 5, y = Throw[init]}, y]], x, y, Catch[Block[{x = 5}, x = 99; z = 1; Throw[body]]], x, z}", "List[init, 100, 200, body, 100, 1]")
        , ("block preserves nonlocal effects", "x = 100; z = 0; {Block[{x = (z = z + 1; 5)}, z = z + 1; x], x, z}", "List[5, 100, 2]")
        , ("block can localize protected evaluator heads", "{Block[{Plus = foo}, 1 + 2], 1 + 2}", "List[foo[1, 2], 3]")
        , ("inherited block aliases share dynamic scope", "x = 100; {InheritedBlock[{x = 5}, x + 1], Internal`InheritedBlock[{x = 6}, x + 1], x}", "List[6, 7, 100]")
        , ("invalid block bindings remain held without effects", "x = 0; {Block[5, x], Block[{a = (x = 1), a = 2}, never], InheritedBlock[{1}, x], x}", "List[Block[5, x], Block[List[Set[a, Set[x, 1]], Set[a, 2]], never], InheritedBlock[List[1], x], 0]")
        , ("block restores iterator downvalue mutations", "f[0] = 0; Block[{f}, Table[f[i] = i, {i, 2}]]; {f[0], f[1], f[2]}", "List[0, f[1], f[2]]")
        , ("with eager and symbolic substitution", "{With[{x = 5}, x + 1], With[{x = 5, y = 6}, x + y], With[{x = a, y = b}, x + y], With[{x = 1 + 2}, x*x]}", "List[6, 11, Plus[a, b], 9]")
        , ("with bindings are independent", "With[{x = 1, y = x + 1}, {x, y}]", "List[1, Plus[1, x]]")
        , ("with bindings see outer session values", "x = 10; {With[{x = 1, y = x + 1}, {x, y}], x}", "List[List[1, 11], 10]")
        , ("with substitutes through held and pattern syntax", "With[{x = 5}, {Hold[x], HoldComplete[x], HoldPattern[x], Unevaluated[x], x_}]", "List[Hold[5], HoldComplete[5], HoldPattern[5], Unevaluated[5], Pattern[5, Blank[]]]")
        , ("with capture-aware function substitution", "{With[{x = 5}, Function[x, x + 1]], With[{x = 5}, Function[x, x + 1][7]], With[{x = 5}, Function[y, x + y]], With[{x = y}, Function[y, x]], With[{x = y}, Function[y, x][7]]}", "List[Function[x, Plus[x, 1]], 8, Function[y$, Plus[5, y$]], Function[y$, y], y]")
        , ("with delayed and nested substitution", "i = 0; {With[{x := i = i + 1}, {x, x, i}], i, With[{x = 5}, With[{x = 99}, x]], With[{x = 5}, With[{y = x + 1}, y*2]], With[{x = 1}, With[{y = 2}, x + y]]}", "List[List[1, 2, 2], 2, 99, 12, 3]")
        , ("functions substitute through inner with", "{(With[{x = #}, x + 1] &)[10], Function[t, With[{u = t + 1}, u*2]][10], Function[x, With[{x = 5}, x + 1]][99]}", "List[11, 22, 6]")
        , ("with empty held and generated assignment forms", "{With[{}, 7], With[{}, 1 + 2 + 3], With[{x = 5}, Hold[Function[x, x + 1]]], With[{x = 5}, Set[x, 99]]}", "List[7, 6, Hold[Function[x, Plus[x, 1]]], Set[5, 99]]")
        , ("invalid with bindings retain only prior eager effects", "i = 0; {With[5, x], With[{a = (i = i + 1), a = (i = 99)}, a], i, With[{bad}, x]}", "List[With[5, x], With[List[Set[a, Set[i, Plus[i, 1]]], Set[a, Set[i, 99]]], a], 1, With[List[bad], x]]")
        , ("with call heads simultaneous values and local scopes", "{With[{f = g}, f[x]], With[{x = y, y = 1}, x], With[{x = 5}, Module[{y = x + 1}, y]], With[{x = y}, Hold[Module[{y = 1}, x + y]]], With[{x = 5}, Hold[InheritedBlock[{x = 2}, x]]]}", "List[g[x], y, 6, Hold[Module[List[Set[y$, 1]], Plus[y, y$]]], Hold[InheritedBlock[List[Set[5, 2]], 5]]]")
        , ("with substitution precedes downvalue assignment", "With[{f = g}, f[t_] := t + 1]; {g[3], DownValues[g]}", "List[4, List[RuleDelayed[HoldPattern[g[Pattern[t, Blank[]]]], Plus[t, 1]]]]")
        , ("with deterministic recursive freshening", "{With[{x = y$}, Function[y, x]], Function[x, Function[y, x + y]][a], Function[x, Function[y, x + y]][y], Function[x, Function[y, y]][a], Function[x, Function[y, Function[z, {x, y, z}]]][y]}", "List[Function[y$1, y$], Function[y$, Plus[a, y$]], Function[y$, Plus[y, y$]], Function[y, y], Function[y$, Function[z$, List[y, y$, z$]]]]")
        , ("with eager replacement evaluates once", "i = 0; With[{x = (i = i + 1)}, {x, x, i}]", "List[1, 1, 1]")
        , ("module independent bindings", "x = 100; {Module[{x = 5, y = x + 1}, {x, y}], x}", "List[List[5, 101], 100]")
        , ("module delayed values and fresh own values", "{Module[{x := a + b}, {x, x}], Module[{z}, Hold[z]], Module[{x = 5}, OwnValues[x]]}", "List[List[Plus[a, b], Plus[a, b]], Hold[z$2], List[RuleDelayed[HoldPattern[x$3], 5]]]")
        , ("module capture avoiding rename", "Module[{x = 1}, Hold[{Function[x, x + 1], Function[y, x + y], Module[{x = 2}, x], Module[{y = x + 1}, x + y]}]]", "Hold[List[Function[x, Plus[x, 1]], Function[y, Plus[x$1, y]], Module[List[Set[x, 2]], x], Module[List[Set[y, Plus[x$1, 1]]], Plus[x$1, y]]]]")
        , ("module malformed nested scopes rename generically", "Module[{x = 1}, Hold[{Module[{x, 3}, x], Function[{x, 3}, x], Function[y, y, x], InheritedBlock[{x = 2}, x]}]]", "Hold[List[Module[List[x$1, 3], x$1], Function[List[x$1, 3], x$1], Function[y, y, x], InheritedBlock[List[Set[x$1, 2]], x$1]]]")
        , ("module initializer exits retain state", "Catch[Module[{x = 5, y = Throw[1]}, y]]; {x$1, Module[{z}, Hold[z]]}", "List[5, Hold[z$2]]")
        , ("invalid module bindings do not allocate", "Module[{x = 1, x = 2}, x]; Module[{z}, Hold[z]]", "Hold[z$1]")
        , ("delayed definitions allocate a module per read", "f := Module[{x}, Hold[x]]; {f, f}", "List[Hold[x$1], Hold[x$2]]")
        , ("module locals compose with iterators", "{Table[Module[{x = i}, x^2], {i, 4}], Sum[Module[{x = i}, x^2], {i, 4}], Product[Module[{x = i}, x^2], {i, 4}]}", "List[List[1, 4, 9, 16], 30, 576]")
        , ("bare module locals preserve existing fresh definitions", "x$1 = 9; Module[{x}, x]", "9")
        , ("module initializer effects thread in outer scope", "x = 0; {Module[{a = x = x + 1, b = x = x + 1}, {a, b}], x}", "List[List[1, 2], 2]")
        , ("module closure dispatch", "g = Module[{f}, f[x_] := x^2; f]; {g[3], g[a + b]}", "List[9, Power[Plus[a, b], 2]]")
        , ("module closure recursive equations", "h = Module[{f}, f[0] := 1; f[n_] := n * f[n - 1]; f]; {h[5], h[10]}", "List[120, 3628800]")
        , ("module closure mutual recursion", "e = Module[{e, o}, e[0] := True; e[n_] := o[n - 1]; o[0] := False; o[n_] := e[n - 1]; e]; {e[10], e[7]}", "List[True, False]")
        , ("module closure memoization", "m = Module[{cache, fib}, cache = <||>; fib[n_] := fib[n] = If[n < 2, n, fib[n - 1] + fib[n - 2]]; fib]; {m[10], m[20]}", "List[55, 6765]")
        , ("module closure captured own value", "c = Module[{n = 0}, Function[{}, n = n + 1; n]]; {c[], c[], c[]}", "List[1, 2, 3]")
        , ("module closures keep independent downvalues", "a = Module[{f}, f[x_] := x + 1; f]; b = Module[{f}, f[x_] := x * 2; f]; {a[5], b[5]}", "List[6, 10]")
        , ("module immediate recursive dispatch", "Module[{f}, f[0] := 1; f[n_] := n + f[n - 1]; f[10]]", "56")
        , ("module closure multiple arguments", "bin = Module[{f}, f[x_, y_] := x + y; f]; {bin[3, 4], bin[a, b]}", "List[7, Plus[a, b]]")
        ]
      printCases =
        [ ( "nested abort protection re-defers at compound boundaries"
          , "CheckAbort[AbortProtect[AbortProtect[Abort[]; Print[\"innerTail\"]]; Print[\"outerTail\"]], fail]"
          , "fail"
          , ["innerTail", "outerTail"]
          )
        , ( "failsafe evaluates constructors in order and short circuits failure calls"
          , "{Failsafe[(Print[\"function\"]; f), (Print[\"test\"]; SameQ)][1, 1], Failsafe[Function[x, Print[\"not-called\"]]][Missing[\"x\"]]}"
          , "List[f[1, 1], Missing[\"x\"]]"
          , ["function", "test"]
          )
        , ( "malformed failsafe construction suppresses argument effects"
          , "Failsafe[Print[\"f\"], Print[\"test\"], Print[\"failure\"], Print[\"extra\"]]"
          , "Failsafe[Print[\"f\"], Print[\"test\"], Print[\"failure\"], Print[\"extra\"]]"
          , []
          )
        , ( "confirmation information tags and handlers preserve effect order"
          , "Enclose[Confirm[Missing[\"x\"], (Print[\"info\"]; \"i\"), (Print[\"tag\"]; tag)], (Print[\"handler\"]; \"Information\"), tag]"
          , "\"i\""
          , ["info", "tag", "handler"]
          )
        , ( "with cleanup runs before an enclosed confirmation handler"
          , "Enclose[WithCleanup[Confirm[$Failed, \"bad\"], Print[\"cleanup\"]], \"Information\"]"
          , "\"bad\""
          , ["cleanup"]
          )
        , ( "malformed confirmation controls suppress all held effects"
          , "probe[Enclose[Print[\"body\"], Print[\"handler\"], Print[\"form\"], Print[\"extra\"]], Confirm[], ConfirmBy[Print[\"by\"]], ConfirmMatch[Print[\"match\"]]]"
          , "probe[Enclose[Print[\"body\"], Print[\"handler\"], Print[\"form\"], Print[\"extra\"]], Confirm[], ConfirmBy[Print[\"by\"]], ConfirmMatch[Print[\"match\"]]]"
          , []
          )
        , ( "same-depth check abort catches only its fresh abort"
          , "CheckAbort[AbortProtect[Abort[]; Print[CheckAbort[1, inner]]; Print[CheckAbort[Abort[], inner]]; Print[\"tail\"]], fail]"
          , "fail"
          , ["1", "inner", "tail"]
          )
        , ( "unprotected abort skips the remaining compound tail"
          , "CheckAbort[Print[\"before\"]; Abort[]; Print[\"after\"], caught]"
          , "caught"
          , ["before"]
          )
        , ( "with cleanup runs after a body abort"
          , "CheckAbort[WithCleanup[Print[\"expr1\"]; Abort[]; Print[\"expr2\"], Print[\"cleanup\"]], caught]"
          , "caught"
          , ["expr1", "cleanup"]
          )
        , ( "with cleanup protects init and skips body after init control"
          , "CheckAbort[WithCleanup[Print[\"init1\"]; Abort[]; Print[\"init2\"], Print[\"body\"], Print[\"cleanup\"]], caught]"
          , "caught"
          , ["init1", "init2", "cleanup"]
          )
        , ( "with cleanup preserves an enclosing pending abort"
          , "CheckAbort[AbortProtect[Abort[]; WithCleanup[Print[\"init\"], Print[\"body\"], Print[\"cleanup\"]]; Print[\"after\"]], caught]"
          , "caught"
          , ["init", "body", "cleanup", "after"]
          )
        , ( "with cleanup runs for throw return break and goto exits"
          , "ClearAll[f]; f[] := WithCleanup[Return[returned], Print[\"returnCleanup\"]]; {Catch[WithCleanup[Throw[thrown], Print[\"throwCleanup\"]]], f[], Do[WithCleanup[Break[], Print[\"breakCleanup\"]], {i, 3}], (WithCleanup[Goto[out], Print[\"gotoCleanup\"]]; never; Label[out]; reached)}"
          , "List[thrown, returned, Null, reached]"
          , ["throwCleanup", "returnCleanup", "breakCleanup", "gotoCleanup"]
          )
        , ( "sow evaluates values before tags exactly once"
          , "Reap[Sow[(Print[\"value\"]; 1), (Print[\"tag\"]; a)]; 2]"
          , "List[2, List[List[1]]]"
          , ["value", "tag"]
          )
        , ( "reap combiner effects run after the scope is popped"
          , "Reap[Sow[1, a]; 2, _, Function[{tag, values}, Print[tag]; values]]"
          , "List[2, List[List[1]]]"
          , ["a"]
          )
        , ( "pattern callbacks preserve prints in traversal order"
          , "p[x_] := (Print[x]; x > 1); Cases[{1, 2, 3}, x_ /; p[x]]"
          , "List[2, 3]"
          , ["1", "2", "3"]
          )
        , ( "ValueQ preserves prints from its held probe"
          , "ValueQ[Print[\"hello\"]]"
          , "True"
          , ["hello"]
          )
        , ( "ValueQ does not evaluate bare symbol own values"
          , "ClearAll[x]; x := Print[\"not evaluated\"]; ValueQ[x]"
          , "True"
          , []
          )
        , ( "Nothing callable preserves Sequence effect order"
          , "Nothing[Sequence[Print[\"a\"], Print[\"b\"]]]"
          , "Nothing"
          , ["a", "b"]
          )
        , ( "held builtins preserve direct effect timing"
          , "probe[Which[False, Print[\"which-skip\"], True, Print[\"which\"]], Switch[(Print[\"switch-subject\"]; x), x, Print[\"switch\"], _, Print[\"switch-late\"]], Piecewise[{{Print[\"piece-false\"], False}, {Print[\"piece-unknown\"], u}, {Print[\"piece-true\"], True}}, Print[\"piece-default\"]], ReleaseHold[Hold[Print[\"release\"]]], Inactive[Print[\"inactive-held\"]], Inactive[Evaluate[Print[\"inactive-forced\"]]], Activate[Inactive[Print][\"activate\"]]]"
          , "probe[Null, Null, Piecewise[List[List[Null, u]], Null], Null, Inactive[Print[\"inactive-held\"]], Inactive[Null], Null]"
          , ["which", "switch-subject", "switch", "piece-unknown", "piece-true", "release", "inactive-forced", "activate"]
          )
        , ( "held builtin aliases apply attributes without direct dispatch"
          , "ClearAll[qw, qs, qp, qr, qi, qa]; qw = Which; qs = Switch; qp = Piecewise; qr = ReleaseHold; qi = Inactive; qa = Activate; probe[qw[False, Print[\"which-held\"], True, Print[\"which-held-2\"]], qs[(Print[\"switch-subject\"]; x), x, Print[\"switch-held\"]], qp[{{Print[\"piece-held\"], True}}, Print[\"piece-default-held\"]], qr[Print[\"release-1\"], Print[\"release-2\"]], qi[Print[\"inactive-held\"], Print[\"inactive-second\"]], qa[Print[\"activate-1\"], Print[\"activate-2\"], Print[\"activate-3\"]]]"
          , "probe[Which[False, Print[\"which-held\"], True, Print[\"which-held-2\"]], Switch[x, x, Print[\"switch-held\"]], Piecewise[List[List[Print[\"piece-held\"], True]], Print[\"piece-default-held\"]], ReleaseHold[Null, Null], Inactive[Print[\"inactive-held\"], Null], Activate[Null, Null, Null]]"
          , ["switch-subject", "release-1", "release-2", "inactive-second", "activate-1", "activate-2", "activate-3"]
          )
        , ( "malformed held builtins suppress all argument effects"
          , "probe[Which[Print[\"w\"]], Switch[Print[\"s\"], x], Piecewise[Print[\"p\"]], ReleaseHold[Print[\"r1\"], Print[\"r2\"]], Inactive[Print[\"i1\"], Print[\"i2\"]], Activate[Print[\"a1\"], Print[\"a2\"], Print[\"a3\"]]]"
          , "probe[Which[Print[\"w\"]], Switch[Print[\"s\"], x], Piecewise[Print[\"p\"]], ReleaseHold[Print[\"r1\"], Print[\"r2\"]], Inactive[Print[\"i1\"], Print[\"i2\"]], Activate[Print[\"a1\"], Print[\"a2\"], Print[\"a3\"]]]"
          , []
          )
        , ( "Piecewise preserves early effects before later malformed cases"
          , "Piecewise[{{Print[\"early\"], x}, bad, {2, True}}]"
          , "Piecewise[List[List[Print[\"early\"], x], bad, List[2, True]]]"
          , ["early"]
          )
        , ( "in-place arithmetic forces delayed values once before replacement"
          , "ClearAll[x]; x := (Print[\"read\"]; 5); probe[x++, x, OwnValues[x]]"
          , "probe[5, 6, List[RuleDelayed[HoldPattern[x], 6]]]"
          , ["read"]
          )
        , ( "AppendTo evaluates its item before an atomic-target failure"
          , "ClearAll[x]; x = 1; AppendTo[x, Print[\"item\"]]"
          , "AppendTo[x, Print[\"item\"]]"
          , ["item"]
          )
        , ( "association calls expose delayed values without a second evaluation"
          , "ClearAll[x]; x = <|a -> 1|>; {AppendTo[x, b :> Print[\"late\"]], x, x[b]}"
          , "List[Association[Rule[a, 1], RuleDelayed[b, Print[\"late\"]]], Association[Rule[a, 1], RuleDelayed[b, Print[\"late\"]]], Print[\"late\"]]"
          , []
          )
        , ( "goto skips effects until an outer matching label"
          , "(Print[\"outer-before\"]; (Print[\"inner\"]; Goto[out]; Print[\"inner-never\"]; Label[other]); Print[\"outer-never\"]; Label[out]; Print[\"outer-after\"] )"
          , "Null"
          , ["outer-before", "inner", "outer-after"]
          )
        , ( "malformed label and goto calls suppress argument effects"
          , "probe[Label[Print[\"l1\"], Print[\"l2\"]], Goto[Print[\"g1\"], Print[\"g2\"]]]"
          , "probe[Label[Print[\"l1\"], Print[\"l2\"]], Goto[Print[\"g1\"], Print[\"g2\"]]]"
          , []
          )
        , ( "disabled messages still evaluate insertions"
          , "Off[f::tag]; Message[f::tag, Print[\"still\"]]; $MessageList"
          , "List[]"
          , ["still"]
          )
        , ( "invalid message names block insertion effects"
          , "x = f::tag; probe[Message[], Message[x, Print[\"bad\"]]]"
          , "probe[Message[], Message[x, Print[\"bad\"]]]"
          , []
          )
        , ( "malformed Quiet and Check calls block held effects"
          , "probe[Quiet[], Quiet[Print[\"body\"], Print[\"off\"], Print[\"on\"], Print[\"extra\"]], Check[], Check[Print[\"check\"]], Check[Print[\"body2\"], x, y, Print[\"extra2\"]]]"
          , "probe[Quiet[], Quiet[Print[\"body\"], Print[\"off\"], Print[\"on\"], Print[\"extra\"]], Check[], Check[Print[\"check\"]], Check[Print[\"body2\"], x, y, Print[\"extra2\"]]]"
          , []
          )
        ]
      partArityMessage =
        ( "Part::error"
        , "MessageName[Part, \"error\"]"
        , "Part::error: Part expects an expression and at least one part specification."
        )
      fAMessage =
        ( "f::a"
        , "MessageName[f, \"a\"]"
        , "f::a: Message generated."
        )
      gBMessage =
        ( "g::b"
        , "MessageName[g, \"b\"]"
        , "g::b: Message generated."
        )
      messageCases =
        [ ( "abort control arity diagnostics"
          , "{Abort[1], CheckAbort[1], AbortProtect[]}"
          , "List[Abort[1], CheckAbort[1], AbortProtect[]]"
          , [ ( "Abort::error"
              , "MessageName[Abort, \"error\"]"
              , "Abort::error: Abort expects no arguments."
              )
            , ( "CheckAbort::error"
              , "MessageName[CheckAbort, \"error\"]"
              , "CheckAbort::error: CheckAbort expects exactly two arguments."
              )
            , ( "AbortProtect::error"
              , "MessageName[AbortProtect, \"error\"]"
              , "AbortProtect::error: AbortProtect expects exactly one argument."
              )
            ]
          )
        , ( "failure properties and failsafe constructors report exact diagnostics"
          , "{Failure[\"x\", <||>][1], Failsafe[], Failsafe[Print[\"f\"], Print[\"test\"], Print[\"failure\"], Print[\"extra\"]]}"
          , "List[Failure[\"x\", Association[]][1], Failsafe[], Failsafe[Print[\"f\"], Print[\"test\"], Print[\"failure\"], Print[\"extra\"]]]"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Failure property lookup expects a string key."
              )
            , ( "Failsafe::error"
              , "MessageName[Failsafe, \"error\"]"
              , "Failsafe::error: Failsafe expects one, two, or three arguments."
              )
            , ( "Failsafe::error"
              , "MessageName[Failsafe, \"error\"]"
              , "Failsafe::error: Failsafe expects one, two, or three arguments."
              )
            ]
          )
        , ( "unhandled confirmations emit the canonical message"
          , "Confirm[$Failed]"
          , "Failure[ConfirmationFailed, Association[Rule[\"ConfirmationType\", Confirm], Rule[\"Expression\", $Failed], Rule[\"Information\", Null]]]"
          , [ ( "Confirm::confirmnotag"
              , "MessageName[Confirm, \"confirmnotag\"]"
              , "Confirm::confirmnotag: Message generated."
              )
            ]
          )
        , ( "confirmation handlers cannot recatch their own failure"
          , "Enclose[Confirm[$Failed], Function[failure, Confirm[$Failed]]]"
          , "Failure[ConfirmationFailed, Association[Rule[\"ConfirmationType\", Confirm], Rule[\"Expression\", $Failed], Rule[\"Information\", Null]]]"
          , [ ( "Confirm::confirmnotag"
              , "MessageName[Confirm, \"confirmnotag\"]"
              , "Confirm::confirmnotag: Message generated."
              )
            ]
          )
        , ( "malformed confirmation controls report exact arity errors"
          , "{Enclose[], Confirm[], ConfirmBy[Print[\"value\"]], ConfirmMatch[Print[\"value\"]]}"
          , "List[Enclose[], Confirm[], ConfirmBy[Print[\"value\"]], ConfirmMatch[Print[\"value\"]]]"
          , [ ( "Enclose::error"
              , "MessageName[Enclose, \"error\"]"
              , "Enclose::error: Enclose expects one, two, or three arguments."
              )
            , ( "Confirm::error"
              , "MessageName[Confirm, \"error\"]"
              , "Confirm::error: Confirm expects one, two, or three arguments."
              )
            , ( "ConfirmBy::error"
              , "MessageName[ConfirmBy, \"error\"]"
              , "ConfirmBy::error: ConfirmBy expects two, three, or four arguments."
              )
            , ( "ConfirmMatch::error"
              , "MessageName[ConfirmMatch, \"error\"]"
              , "ConfirmMatch::error: ConfirmMatch expects two, three, or four arguments."
              )
            ]
          )
        , ( "with cleanup arity diagnostics"
          , "{WithCleanup[1], WithCleanup[1, 2, 3, 4]}"
          , "List[WithCleanup[1], WithCleanup[1, 2, 3, 4]]"
          , [ ( "WithCleanup::error"
              , "MessageName[WithCleanup, \"error\"]"
              , "WithCleanup::error: WithCleanup expects two or three arguments."
              )
            , ( "WithCleanup::error"
              , "MessageName[WithCleanup, \"error\"]"
              , "WithCleanup::error: WithCleanup expects two or three arguments."
              )
            ]
          )
        , ( "reap and sow arity diagnostics"
          , "{Sow[], Sow[1, 2, 3], Reap[], Reap[1, 2, 3, 4]}"
          , "List[Sow[], Sow[1, 2, 3], Reap[], Reap[1, 2, 3, 4]]"
          , [ ( "Sow::error"
              , "MessageName[Sow, \"error\"]"
              , "Sow::error: Sow expects one or two arguments."
              )
            , ( "Sow::error"
              , "MessageName[Sow, \"error\"]"
              , "Sow::error: Sow expects one or two arguments."
              )
            , ( "Reap::error"
              , "MessageName[Reap, \"error\"]"
              , "Reap::error: Reap expects one, two, or three arguments."
              )
            , ( "Reap::error"
              , "MessageName[Reap, \"error\"]"
              , "Reap::error: Reap expects one, two, or three arguments."
              )
            ]
          )
        , ( "Composition preserves invalid Function diagnostics"
          , "Composition[Function[f[x], x]][a]"
          , "Function[f[x], x][a]"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Unsupported Function parameter specification."
              )
            ]
          )
        , ( "Composition propagates valid named Function arity failures"
          , "Composition[f, Function[{x, y}, x + y]][1]"
          , "Composition[f, Function[List[x, y], Plus[x, y]]][1]"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Function expects 2 named argument(s), but only 1 were supplied."
              )
            ]
          )
        , ( "RightComposition stops before later stages after Function arity failure"
          , "ClearAll[z, f]; z = 0; f[t_] := (z = 1; t); RightComposition[Function[{x, y}, x + y], f][1]; z"
          , "0"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Function expects 2 named argument(s), but only 1 were supplied."
              )
            ]
          )
        , ( "Composition Nothing stage reevaluates inert diagnostic arguments"
          , "Composition[Nothing][Part[f[a], 2]]"
          , "Nothing"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "held builtins validate malformed direct calls before effects"
          , "probe[Which[Print[\"w\"]], Switch[Print[\"s\"], x], Piecewise[Print[\"p\"]], ReleaseHold[Print[\"r1\"], Print[\"r2\"]], Inactive[Print[\"i1\"], Print[\"i2\"]], Activate[Print[\"a1\"], Print[\"a2\"], Print[\"a3\"]]]"
          , "probe[Which[Print[\"w\"]], Switch[Print[\"s\"], x], Piecewise[Print[\"p\"]], ReleaseHold[Print[\"r1\"], Print[\"r2\"]], Inactive[Print[\"i1\"], Print[\"i2\"]], Activate[Print[\"a1\"], Print[\"a2\"], Print[\"a3\"]]]"
          , [ ( "Which::error"
              , "MessageName[Which, \"error\"]"
              , "Which::error: Which expects condition-value pairs."
              )
            , ( "Switch::error"
              , "MessageName[Switch, \"error\"]"
              , "Switch::error: Switch expects an expression followed by form-value pairs."
              )
            , ( "Piecewise::error"
              , "MessageName[Piecewise, \"error\"]"
              , "Piecewise::error: Piecewise expects its first argument to be a list of {value, condition} pairs."
              )
            , ( "ReleaseHold::error"
              , "MessageName[ReleaseHold, \"error\"]"
              , "ReleaseHold::error: ReleaseHold expects exactly one argument."
              )
            , ( "Inactive::error"
              , "MessageName[Inactive, \"error\"]"
              , "Inactive::error: Inactive expects exactly one argument."
              )
            , ( "Activate::error"
              , "MessageName[Activate, \"error\"]"
              , "Activate::error: Activate expects an expression and an optional pattern."
              )
            ]
          )
        , ( "Piecewise retains progressive effects before later shape failure"
          , "Piecewise[{{Print[\"early\"], x}, bad, {2, True}}]"
          , "Piecewise[List[List[Print[\"early\"], x], bad, List[2, True]]]"
          , [ ( "Piecewise::error"
              , "MessageName[Piecewise, \"error\"]"
              , "Piecewise::error: Piecewise cases must be two-element lists of {value, condition}."
              )
            ]
          )
        , ( "Activate reevaluates newly exposed diagnostic arguments"
          , "Activate[Inactive[Plus][Part[{1}, 2], 1]]"
          , "Plus[1, Part[List[1], 2]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for {1}."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for {1}."
              )
            ]
          )
        , ( "Unique validates string prefixes"
          , "Unique[\"Other`prefix\"]"
          , "Unique[\"Other`prefix\"]"
          , [ ( "Unique::error"
              , "MessageName[Unique, \"error\"]"
              , "Unique::error: Unique expects a valid symbol or symbol-name prefix."
              )
            ]
          )
        , ( "Unique ordinary Sequence splicing validates arity"
          , "Unique[Sequence[x, y]]"
          , "Unique[Sequence[x, y]]"
          , [ ( "Unique::error"
              , "MessageName[Unique, \"error\"]"
              , "Unique::error: Unique currently expects zero arguments or one symbol, string, or list argument."
              )
            ]
          )
        , ( "Unique list failures retain earlier allocations"
          , "Unique[{a, 1, b}]; {Names[\"a$*\"], Names[\"b$*\"]}"
          , "List[List[\"a$1\"], List[]]"
          , [ ( "Unique::error"
              , "MessageName[Unique, \"error\"]"
              , "Unique::error: Unique expects no argument, a symbol, a string prefix, or a list of those forms."
              )
            ]
          )
        , ( "Unique validates evaluated specifications"
          , "x = 1; Unique[x]"
          , "Unique[x]"
          , [ ( "Unique::error"
              , "MessageName[Unique, \"error\"]"
              , "Unique::error: Unique expects no argument, a symbol, a string prefix, or a list of those forms."
              )
            ]
          )
        , ( "Unique invalid generated names still consume the shared counter"
          , "Unique[{\\[FormalA], x}]; Unique[]"
          , "$2"
          , [ ( "Unique::error"
              , "MessageName[Unique, \"error\"]"
              , "Unique::error: Invalid Wolfram symbol name: 'System`\\uf800$1'."
              )
            ]
          )
        , ( "Evaluate validates raw arity before argument effects"
          , "ClearAll[x]; x = 0; Evaluate[x = x + 1, x = x + 1]; x"
          , "0"
          , [ ( "Evaluate::error"
              , "MessageName[Evaluate, \"error\"]"
              , "Evaluate::error: Evaluate expects exactly one argument."
              )
            ]
          )
        , ( "Symbol validates constructed names"
          , "Symbol[\"not a symbol\"]"
          , "Symbol[\"not a symbol\"]"
          , [ ( "Symbol::error"
              , "MessageName[Symbol, \"error\"]"
              , "Symbol::error: Invalid Wolfram symbol name: 'not a symbol'."
              )
            ]
          )
        , ( "Context rejects missing string names"
          , "Context[\"TungstenRegistryMissing`symbol\"]"
          , "Context[\"TungstenRegistryMissing`symbol\"]"
          , [ ( "Context::error"
              , "MessageName[Context, \"error\"]"
              , "Context::error: Context could not find a symbol named 'TungstenRegistryMissing`symbol'."
              )
            ]
          )
        , ( "SymbolName rejects unregistered unqualified strings"
          , "SymbolName[\"tungstenRegistryMissing\"]"
          , "SymbolName[\"tungstenRegistryMissing\"]"
          , [ ( "SymbolName::error"
              , "MessageName[SymbolName, \"error\"]"
              , "SymbolName::error: SymbolName expects a symbol or an existing symbol name."
              )
            ]
          )
        , ( "name queries validate evaluated specifications"
          , "{Names[1], NameQ[1], Contexts[1]}"
          , "List[Names[1], NameQ[1], Contexts[1]]"
          , [ ( "Names::error"
              , "MessageName[Names, \"error\"]"
              , "Names::error: Names expects a string pattern or a list of string patterns."
              )
            , ( "NameQ::error"
              , "MessageName[NameQ, \"error\"]"
              , "NameQ::error: Names expects a string pattern or a list of string patterns."
              )
            , ( "Contexts::error"
              , "MessageName[Contexts, \"error\"]"
              , "Contexts::error: Contexts expects an optional string pattern."
              )
            ]
          )
        , ( "ValueQ validates held arity"
          , "ValueQ[]"
          , "ValueQ[]"
          , [ ( "ValueQ::error"
              , "MessageName[ValueQ, \"error\"]"
              , "ValueQ::error: ValueQ expects exactly one argument."
              )
            ]
          )
        , ( "ValueQ arity does not splice Sequence"
          , "ValueQ[a, Sequence[b, c]]"
          , "ValueQ[a, Sequence[b, c]]"
          , [ ( "ValueQ::error"
              , "MessageName[ValueQ, \"error\"]"
              , "ValueQ::error: ValueQ expects exactly one argument."
              )
            ]
          )
        , ( "ValueQ preserves recovered evaluation errors"
          , "ValueQ[Part[{1}, 2]]"
          , "False"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for {1}."
              )
            ]
          )
        , ( "ValueQ preserves nonfatal session diagnostics"
          , "ValueQ[$RecursionLimit = 1]"
          , "True"
          , [ ( "$RecursionLimit::limset"
              , "MessageName[$RecursionLimit, \"limset\"]"
              , "$RecursionLimit::limset: Cannot set $RecursionLimit to 1."
              )
            ]
          )
        , ( "ValueQ preserves invalid Function diagnostics"
          , "ValueQ[Function[f[x], x][a]]"
          , "False"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Unsupported Function parameter specification."
              )
            ]
          )
        , ( "tagged delayed assignments reject deep tag positions"
          , "ClearAll[f, h, x]; TagSetDelayed[f, h[deep[f[x_]]], x]"
          , "Null"
          , [ ( "TagSetDelayed::tagpos"
              , "MessageName[TagSetDelayed, \"tagpos\"]"
              , "TagSetDelayed::tagpos: Tag f does not occur in a supported position in h[deep[f[x_]]]."
              )
            ]
          )
        , ( "tagged immediate failures retain the evaluated rhs"
          , "ClearAll[f, h, x, y]; y = 3; TagSet[f, h[deep[f[x_]]], x + y]"
          , "TagSet[f, h[deep[f[Pattern[x, Blank[]]]]], Plus[3, x]]"
          , [ ( "TagSet::tagpos"
              , "MessageName[TagSet, \"tagpos\"]"
              , "TagSet::tagpos: Tag f does not occur in a supported position in h[deep[f[x_]]]."
              )
            ]
          )
        , ( "tagged assignments respect protected tags"
          , "ClearAll[h, x, y]; TagSetDelayed[Plus, h[Plus[x_, y_]], x]"
          , "Null"
          , [ ( "TagSetDelayed::wrsym"
              , "MessageName[TagSetDelayed, \"wrsym\"]"
              , "TagSetDelayed::wrsym: Symbol Plus is Protected."
              )
            ]
          )
        , ( "missing tagged definitions report norep"
          , "ClearAll[f, h, x]; TagUnset[f, h[f[x_]]]"
          , "$Failed"
          , [ ( "TagUnset::norep"
              , "MessageName[TagUnset, \"norep\"]"
              , "TagUnset::norep: Assignment on f for h[f[x_]] not found."
              )
            ]
          )
        , ( "tagged unset requires the canonical own-value lhs"
          , "ClearAll[f]; f = 7; TagUnset[f, Condition[f, True]]"
          , "$Failed"
          , [ ( "TagUnset::norep"
              , "MessageName[TagUnset, \"norep\"]"
              , "TagUnset::norep: Assignment on f for f /; True not found."
              )
            ]
          )
        , ( "tagged unset preserves untouched seeded defaults"
          , "TagUnset[$RecursionLimit, $RecursionLimit]"
          , "$Failed"
          , [ ( "TagUnset::norep"
              , "MessageName[TagUnset, \"norep\"]"
              , "TagUnset::norep: Assignment on $RecursionLimit for $RecursionLimit not found."
              )
            ]
          )
        , ( "TagSet validates arity"
          , "TagSet[f, f]"
          , "TagSet[f, f]"
          , [ ( "TagSet::error"
              , "MessageName[TagSet, \"error\"]"
              , "TagSet::error: TagSet expects a tag, left-hand side, and right-hand side."
              )
            ]
          )
        , ( "TagSet validates symbol tags"
          , "TagSet[1, f, 2]"
          , "TagSet[1, f, 2]"
          , [ ( "TagSet::error"
              , "MessageName[TagSet, \"error\"]"
              , "TagSet::error: TagSet expects a symbol tag."
              )
            ]
          )
        , ( "TagSetDelayed validates arity"
          , "TagSetDelayed[f, f]"
          , "TagSetDelayed[f, f]"
          , [ ( "TagSetDelayed::error"
              , "MessageName[TagSetDelayed, \"error\"]"
              , "TagSetDelayed::error: TagSetDelayed expects a tag, left-hand side, and right-hand side."
              )
            ]
          )
        , ( "TagUnset validates arity"
          , "TagUnset[f]"
          , "TagUnset[f]"
          , [ ( "TagUnset::error"
              , "MessageName[TagUnset, \"error\"]"
              , "TagUnset::error: TagUnset expects a tag and a left-hand side."
              )
            ]
          )
        , ( "attribute specifications remain held"
          , "ClearAll[a, f]; a = HoldAll; SetAttributes[f, a]; {Attributes[f], f[1 + 2]}"
          , "List[List[], f[3]]"
          , [ ( "Attributes::attnf"
              , "MessageName[Attributes, \"attnf\"]"
              , "Attributes::attnf: a is not a known attribute."
              )
            ]
          )
        , ( "Global attribute names do not alias System metadata"
          , "ClearAll[f]; SetAttributes[f, Global`HoldAll]; Attributes[f]"
          , "List[]"
          , [ ( "Attributes::attnf"
              , "MessageName[Attributes, \"attnf\"]"
              , "Attributes::attnf: Global`HoldAll is not a known attribute."
              )
            ]
          )
        , ( "Attributes assignment rejects list targets"
          , "ClearAll[f]; Attributes[{f}] = HoldAll; Attributes[f]"
          , "List[]"
          , [ ( "Attributes::sym"
              , "MessageName[Attributes, \"sym\"]"
              , "Attributes::sym: Argument {f} is expected to be a symbol."
              )
            ]
          )
        , ( "protected system own-value assignment is inert"
          , "Plus = 5"
          , "Set[Plus, 5]"
          , [ ( "Set::wrsym"
              , "MessageName[Set, \"wrsym\"]"
              , "Set::wrsym: Symbol Plus is Protected."
              )
            ]
          )
        , ( "Global hook names do not receive System mutation exemptions"
          , "ClearAll[Global`$Pre]; Global`$Pre = 1; Protect[Global`$Pre]; Global`$Pre = 2; Clear[Global`$Pre]; {Global`$Pre, OwnValues[Global`$Pre], Attributes[Global`$Pre]}"
          , "List[1, List[RuleDelayed[HoldPattern[$Pre], 1]], List[Protected]]"
          , [ ( "Set::wrsym"
              , "MessageName[Set, \"wrsym\"]"
              , "Set::wrsym: Symbol $Pre is Protected."
              )
            , ( "Clear::wrsym"
              , "MessageName[Clear, \"wrsym\"]"
              , "Clear::wrsym: Symbol $Pre is Protected."
              )
            ]
          )
        , ( "Clear emits target diagnostics in mutation order"
          , "ClearAll[x]; x = 1; Protect[x]; Clear[x, 1]"
          , "Null"
          , [ ( "Clear::wrsym"
              , "MessageName[Clear, \"wrsym\"]"
              , "Clear::wrsym: Symbol x is Protected."
              )
            , ( "Clear::ssym"
              , "MessageName[Clear, \"ssym\"]"
              , "Clear::ssym: 1 is not a symbol or a valid string pattern."
              )
            ]
          )
        , ( "locked attributes reject mutation"
          , "ClearAll[f]; SetAttributes[f, Locked]; SetAttributes[f, HoldAll]; Attributes[f]"
          , "List[Locked]"
          , [ ( "Attributes::locked"
              , "MessageName[Attributes, \"locked\"]"
              , "Attributes::locked: Symbol f is locked."
              )
            ]
          )
        , ( "Function validates held construction arity"
          , "Function[]"
          , "Function[]"
          , [ ( "Function::error"
              , "MessageName[Function, \"error\"]"
              , "Function::error: Function expects one, two, or three arguments."
              )
            ]
          )
        , ( "qualified System failures use canonical message names"
          , "System`Function[]"
          , "System`Function[]"
          , [ ( "Function::error"
              , "MessageName[Function, \"error\"]"
              , "Function::error: Function expects one, two, or three arguments."
              )
            ]
          )
        , ( "qualified HoldPattern remains a protected assignment owner"
          , "ClearAll[f]; System`HoldPattern[f[x_]] := x; {f[1], DownValues[f]}"
          , "List[f[1], List[]]"
          , [ ( "SetDelayed::wrsym"
              , "MessageName[SetDelayed, \"wrsym\"]"
              , "SetDelayed::wrsym: Symbol HoldPattern is Protected."
              )
            ]
          )
        , ( "more than one curried level is not assignable"
          , "ClearAll[f]; f[x_][y_][z_] := {x, y, z}; {f[1][2][3], SubValues[f]}"
          , "List[f[1][2][3], List[]]"
          , [ ( "SetDelayed::error"
              , "MessageName[SetDelayed, \"error\"]"
              , "SetDelayed::error: SetDelayed does not support this left-hand side in Tungsten yet."
              )
            ]
          )
        , ( "OwnValues distinguishes an unknown string name"
          , "OwnValues[\"missing\"]"
          , "OwnValues[\"missing\"]"
          , [ ( "OwnValues::error"
              , "MessageName[OwnValues, \"error\"]"
              , "OwnValues::error: OwnValues could not find a symbol named 'missing'."
              )
            ]
          )
        , ( "missing pure-function slots recover at General"
          , "(#2 &)[a]"
          , "Function[Slot[2]][a]"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Slot 2 cannot be filled from 1 argument(s)."
              )
            ]
          )
        , ( "invalid Function parameters recover at General"
          , "Function[f[x], x][a]"
          , "Function[f[x], x][a]"
          , [ ( "General::error"
              , "MessageName[General, \"error\"]"
              , "General::error: Unsupported Function parameter specification."
              )
            ]
          )
        , ( "invalid system setting assignment preserves its default"
          , "$RecursionLimit = 1; $RecursionLimit"
          , "1024"
          , [ ( "$RecursionLimit::limset"
              , "MessageName[$RecursionLimit, \"limset\"]"
              , "$RecursionLimit::limset: Cannot set $RecursionLimit to 1."
              )
            ]
          )
        , ( "special system settings reject ClearAll"
          , "$RecursionLimit = 200; ClearAll[$RecursionLimit]; $RecursionLimit"
          , "200"
          , [ ( "ClearAll::spsym"
              , "MessageName[ClearAll, \"spsym\"]"
              , "ClearAll::spsym: Symbol $RecursionLimit is a special system symbol."
              )
            ]
          )
        , ( "invalid held pattern arity is nonfatal"
          , "MatchQ[1]"
          , "MatchQ[1]"
          , [ ( "MatchQ::error"
              , "MessageName[MatchQ, \"error\"]"
              , "MatchQ::error: MatchQ expects exactly two arguments."
              )
            ]
          )
        , ( "pattern callbacks preserve generated messages"
          , "Cases[{1}, x_ /; (Part[]; True)]"
          , "List[1]"
          , [partArityMessage]
          )
        , ( "basic nonfatal Part message"
          , "Part[f[a], 2]"
          , "Part[f[a], 2]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "nested recovery emits only nearest message"
          , "g[Part[f[a], 2]]"
          , "g[Part[f[a], 2]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "evaluated head alias names raw call"
          , "h = Part; h[f[a], 2]"
          , "h[f[a], 2]"
          , [ ( "h::error"
              , "MessageName[h, \"error\"]"
              , "h::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "message uses evaluated subject but returns raw call"
          , "Part[f[1 + 2], 2]"
          , "Part[f[Plus[1, 2]], 2]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[3]."
              )
            ]
          )
        , ( "unsupported Part selector remains nonfatal"
          , "Part[f[a], x]"
          , "Part[f[a], x]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Unsupported Part specification: x."
              )
            ]
          )
        , ( "missing Association key uses input form in message"
          , "Part[<|a -> 1|>, Key[b]]"
          , "Part[Association[Rule[a, 1]], Key[b]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for <|a -> 1|>."
              )
            ]
          )
        , ( "mixed Association selectors report their specific failure"
          , "Part[<|a -> 1, b -> 2|>, {1, Key[a]}]"
          , "Part[Association[Rule[a, 1], Rule[b, 2]], List[1, Key[a]]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Association selector lists may not mix numeric and key selectors."
              )
            ]
          )
        , ( "key selector in ordinary selector list is rejected"
          , "Part[f[a, b], {1, Key[a]}]"
          , "Part[f[a, b], List[1, Key[a]]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Unsupported selector inside Part specification: Key[a]."
              )
            ]
          )
        , ( "zero inside a Part selector list is rejected"
          , "Part[f[a, b], {0, 1}]"
          , "Part[f[a, b], List[0, 1]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part does not support index 0 in this position."
              )
            ]
          )
        , ( "oversized Part indices do not overflow machine integers"
          , "Part[f[a, b], 18446744073709551617]"
          , "Part[f[a, b], 18446744073709551617]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a, b]."
              )
            ]
          )
        , ( "structural reducers do not revisit recovered children"
          , "{Reverse[{Part[]}], Part[{Part[]}, All]}"
          , "List[List[Part[]], List[Part[]]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part expects an expression and at least one part specification."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part expects an expression and at least one part specification."
              )
            ]
          )
        , ( "Map evaluates generated calls and recovered children"
          , "Map[f, {Part[]}]"
          , "List[f[Part[]]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part expects an expression and at least one part specification."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part expects an expression and at least one part specification."
              )
            ]
          )
        , ( "Total reevaluates only its fresh sum"
          , "Total[{Part[]}]"
          , "Part[]"
          , [partArityMessage, partArityMessage]
          )
        , ( "Total preserves per-term failure multiplicity"
          , "Total[{Part[], Part[]}]"
          , "Times[2, Part[]]"
          , replicate 4 partArityMessage
          )
        , ( "Association holds rule values"
          , "<|a -> Part[]|>"
          , "Association[Rule[a, Part[]]]"
          , []
          )
        , ( "AssociationMap evaluates only generated values"
          , "AssociationMap[f, {Part[]}]"
          , "Association[Rule[Part[], f[Part[]]]]"
          , [partArityMessage, partArityMessage]
          )
        , ( "MapAt leaves unselected recovered values alone"
          , "MapAt[f, {Part[], b}, 2]"
          , "List[Part[], f[b]]"
          , [partArityMessage]
          )
        , ( "MapAt reevaluates selected recovered values"
          , "MapAt[f, {Part[], b}, 1]"
          , "List[f[Part[]], b]"
          , [partArityMessage, partArityMessage]
          )
        , ( "pure mapping callbacks receive prepared arguments"
          , "Map[Function[x, HoldComplete[x]], {Part[]}]"
          , "List[HoldComplete[Part[]]]"
          , [partArityMessage]
          )
        , ( "SortBy evaluates keys without revisiting its result"
          , "SortBy[{Part[]}, f]"
          , "List[Part[]]"
          , [partArityMessage, partArityMessage]
          )
        , ( "MapAt validates every path before invoking callbacks"
          , "y = 0; {MapAt[Function[x, y = y + 1], {a, b}, {{2}, {-9}}], y}"
          , "List[MapAt[Function[x, Set[y, Plus[y, 1]]], List[a, b], List[List[2], List[-9]]], 0]"
          , [ ( "MapAt::error"
              , "MessageName[MapAt, \"error\"]"
              , "MapAt::error: MapAt positions are invalid for {a, b}."
              )
            ]
          )
        , ( "MapAt distinguishes unsupported position syntax"
          , "MapAt[f, <|a -> 1|>, a]"
          , "MapAt[f, Association[Rule[a, 1]], a]"
          , [ ( "MapAt::error"
              , "MessageName[MapAt, \"error\"]"
              , "MapAt::error: Unsupported position specification: a."
              )
            ]
          )
        , ( "Map attributes named Function arity failures to itself"
          , "Map[Function[{x, y}, x], {a, b}]"
          , "Map[Function[List[x, y], x], List[a, b]]"
          , [ ( "Map::error"
              , "MessageName[Map, \"error\"]"
              , "Map::error: Function expects 2 named argument(s), but only 1 were supplied."
              )
            ]
          )
        , ( "SortBy reports Python's nonatomic diagnostic"
          , "SortBy[a, f]"
          , "SortBy[a, f]"
          , [ ( "SortBy::error"
              , "MessageName[SortBy, \"error\"]"
              , "SortBy::error: SortBy expects a nonatomic expression."
              )
            ]
          )
        , ( "ReverseSortBy preserves Python's SortBy diagnostic body"
          , "ReverseSortBy[a, f]"
          , "ReverseSortBy[a, f]"
          , [ ( "ReverseSortBy::error"
              , "MessageName[ReverseSortBy, \"error\"]"
              , "ReverseSortBy::error: SortBy expects a nonatomic expression."
              )
            ]
          )
        , ( "SortBy rejects unsupported trailing options"
          , "SortBy[{2, 1}, Identity, SameTest -> (True &), Foo -> bar]"
          , "SortBy[List[2, 1], Identity, Rule[SameTest, Function[True]], Rule[Foo, bar]]"
          , [ ( "SortBy::error"
              , "MessageName[SortBy, \"error\"]"
              , "SortBy::error: SortBy currently supports only the SameTest option."
              )
            ]
          )
        , ( "invalid selection arity is nonfatal"
          , "Select[]"
          , "Select[]"
          , [ ( "Select::error"
              , "MessageName[Select, \"error\"]"
              , "Select::error: Select expects an expression, a criterion or property specification, and an optional limit."
              )
            ]
          )
        , ( "invalid TakeWhile arity is nonfatal"
          , "TakeWhile[]"
          , "TakeWhile[]"
          , [ ( "TakeWhile::error"
              , "MessageName[TakeWhile, \"error\"]"
              , "TakeWhile::error: TakeWhile expects exactly two arguments."
              )
            ]
          )
        , ( "invalid KeySelect arity is nonfatal"
          , "KeySelect[]"
          , "KeySelect[]"
          , [ ( "KeySelect::error"
              , "MessageName[KeySelect, \"error\"]"
              , "KeySelect::error: KeySelect expects an association and a criterion."
              )
            ]
          )
        , ( "Select attributes callback failures to the callback"
          , "Select[{a}, Function[x, Part[f[x], 2]]]"
          , "List[]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "invalid Select property reports a nonfatal Select message"
          , "Select[{a, b}, x -> y]"
          , "Select[List[a, b], Rule[x, y]]"
          , [ ( "Select::error"
              , "MessageName[Select, \"error\"]"
              , "Select::error: Select currently supports only \"Element\" and \"Index\" properties."
              )
            ]
          )
        , ( "KeySelect attributes callback failures to the callback"
          , "KeySelect[<|a -> 1|>, Function[x, Part[f[x], 2]]]"
          , "Association[]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "Select does not reevaluate a recovered structural subject"
          , "Select[Part[f[a], 2], True]"
          , "Part[]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "argument effects survive nonfatal recovery"
          , "x = 5; {Part[f[x = x + 1], 2], x}"
          , "List[Part[f[Set[x, Plus[x, 1]]], 2], 6]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[6]."
              )
            ]
          )
        , ( "update assignment stays inert after a recovered operand"
          , "x = 1; {AddTo[x, Part[f[a], 2]], x}"
          , "List[AddTo[x, Part[f[a], 2]], 1]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            ]
          )
        , ( "multiple messages retain argument order"
          , "{Part[f[a], 2], Part[g[b], 3]}"
          , "List[Part[f[a], 2], Part[g[b], 3]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for f[a]."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for g[b]."
              )
            ]
          )
        , ( "mutation arity checks suppress all argument effects"
          , "probe[AppendTo[Print[\"a\"]], Increment[Print[\"i\"], Print[\"j\"]], Decrement[], PreIncrement[], PreDecrement[]]"
          , "probe[AppendTo[Print[\"a\"]], Increment[Print[\"i\"], Print[\"j\"]], Decrement[], PreIncrement[], PreDecrement[]]"
          , [ ( "AppendTo::error"
              , "MessageName[AppendTo, \"error\"]"
              , "AppendTo::error: AppendTo expects exactly two arguments."
              )
            , ( "Increment::error"
              , "MessageName[Increment, \"error\"]"
              , "Increment::error: Increment expects exactly one argument."
              )
            , ( "Decrement::error"
              , "MessageName[Decrement, \"error\"]"
              , "Decrement::error: Decrement expects exactly one argument."
              )
            , ( "PreIncrement::error"
              , "MessageName[PreIncrement, \"error\"]"
              , "PreIncrement::error: PreIncrement expects exactly one argument."
              )
            , ( "PreDecrement::error"
              , "MessageName[PreDecrement, \"error\"]"
              , "PreDecrement::error: PreDecrement expects exactly one argument."
              )
            ]
          )
        , ( "protected in-place arithmetic emits write and recovery messages"
          , "ClearAll[x]; x = 5; Protect[x]; {Increment[x], x}"
          , "List[Increment[x], 5]"
          , [ ( "Increment::wrsym"
              , "MessageName[Increment, \"wrsym\"]"
              , "Increment::wrsym: Symbol x is Protected."
              )
            , ( "Increment::error"
              , "MessageName[Increment, \"error\"]"
              , "Increment::error: Increment: cannot modify protected symbol."
              )
            ]
          )
        , ( "protected AppendTo delegates its failure to Set"
          , "ClearAll[x]; x = {1}; Protect[x]; AppendTo[x, 2]"
          , "Set[x, List[1, 2]]"
          , [ ( "Set::wrsym"
              , "MessageName[Set, \"wrsym\"]"
              , "Set::wrsym: Symbol x is Protected."
              )
            ]
          )
        , ( "in-place arithmetic assigns through recovered read errors"
          , "ClearAll[x]; x := Part[{1}, 2]; x++; {x, OwnValues[x]}"
          , "List[Plus[1, Part[List[1], 2]], List[RuleDelayed[HoldPattern[x], Plus[1, Part[List[1], 2]]]]]"
          , [ ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for {1}."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for {1}."
              )
            , ( "Part::error"
              , "MessageName[Part, \"error\"]"
              , "Part::error: Part specifications are invalid for {1}."
              )
            ]
          )
        , ( "AppendTo reports strict atomic and association failures"
          , "ClearAll[x, y]; x = 1; y = <|a -> 1|>; {AppendTo[x, b], AppendTo[y, b]}"
          , "List[AppendTo[x, b], AppendTo[y, b]]"
          , [ ( "AppendTo::error"
              , "MessageName[AppendTo, \"error\"]"
              , "AppendTo::error: Append expects a nonatomic expression."
              )
            , ( "AppendTo::error"
              , "MessageName[AppendTo, \"error\"]"
              , "AppendTo::error: Append expects a rule when appending to an Association."
              )
            ]
          )
        , ( "malformed label and goto calls report exact errors"
          , "probe[Label[Print[\"l1\"], Print[\"l2\"]], Goto[Print[\"g1\"], Print[\"g2\"]]]"
          , "probe[Label[Print[\"l1\"], Print[\"l2\"]], Goto[Print[\"g1\"], Print[\"g2\"]]]"
          , [ ( "Label::error"
              , "MessageName[Label, \"error\"]"
              , "Label::error: Label expects exactly one argument."
              )
            , ( "Goto::error"
              , "MessageName[Goto, \"error\"]"
              , "Goto::error: Goto expects exactly one argument."
              )
            ]
          )
        , ( "goto can match a recovered target expression"
          , "(Goto[Part[]]; never; Label[Part[]]; reached)"
          , "reached"
          , [partArityMessage]
          )
        , ( "explicit messages preserve ordering and current-list snapshots"
          , "Message[f::tag, Part[], Print[\"insert\"]]; first = $MessageList; Message[g::other]; {first, $MessageList}"
          , "List[List[HoldForm[MessageName[Part, \"error\"]], HoldForm[MessageName[f, \"tag\"]]], List[HoldForm[MessageName[Part, \"error\"]], HoldForm[MessageName[f, \"tag\"]], HoldForm[MessageName[g, \"other\"]]]]"
          , [ partArityMessage
            , ( "f::tag"
              , "MessageName[f, \"tag\"]"
              , "f::tag: Part[], Null"
              )
            , ( "g::other"
              , "MessageName[g, \"other\"]"
              , "g::other: Message generated."
              )
            ]
          )
        , ( "message controls suppress diagnostics and reactivate exact names"
          , "Off[{f::tag, General::error}]; Message[f::tag, Print[\"suppressed\"]]; Part[f[a], 2]; Append[1, 2]; before = $MessageList; On[{f::tag, General::error}]; Message[f::tag]; {before, $MessageList}"
          , "List[List[], List[HoldForm[MessageName[f, \"tag\"]]]]"
          , [ ( "f::tag"
              , "MessageName[f, \"tag\"]"
              , "f::tag: Message generated."
              )
            ]
          )
        , ( "message controls retain partial mutations before invalid specs"
          , "Off[f::a, Part[], g::b]; Message[f::a]; Message[g::b]; $MessageList"
          , "List[HoldForm[MessageName[Part, \"error\"]], HoldForm[MessageName[Off, \"error\"]], HoldForm[MessageName[g, \"b\"]]]"
          , [ partArityMessage
            , ( "Off::error"
              , "MessageName[Off, \"error\"]"
              , "Off::error: On and Off expect message names, symbols, or lists of message names."
              )
            , ( "g::b"
              , "MessageName[g, \"b\"]"
              , "g::b: Message generated."
              )
            ]
          )
        , ( "message validates held names before insertion effects"
          , "x = f::tag; probe[Message[], Message[x, Print[\"bad\"]]]"
          , "probe[Message[], Message[x, Print[\"bad\"]]]"
          , [ ( "Message::error"
              , "MessageName[Message, \"error\"]"
              , "Message::error: Message expects a message name."
              )
            , ( "Message::error"
              , "MessageName[Message, \"error\"]"
              , "Message::error: Message expects a message name of the form symbol::tag."
              )
            ]
          )
        , ( "disabled diagnostics still stop assignment updates"
          , "x = 1; Off[Part::error]; {AddTo[x, Part[f[a], 2]], x, $MessageList}"
          , "List[AddTo[x, Part[f[a], 2]], 1, List[]]"
          , []
          )
        , ( "qualified message names retain structure but canonicalize display"
          , "Message[System`MessageName[f, \"tag\"]]"
          , "Null"
          , [ ( "f::tag"
              , "System`MessageName[f, \"tag\"]"
              , "f::tag: Message generated."
              )
            ]
          )
        , ( "message insertions honor supported display wrappers"
          , "Message[f::forms, InputForm[{1, 2/3}], FullForm[{1, 2/3}], System`FullForm[1 + 2], StandardForm[\"x\"]]"
          , "Null"
          , [ ( "f::forms"
              , "MessageName[f, \"forms\"]"
              , "f::forms: {1, 2/3}, List[1, Rational[2, 3]], 3, \"x\""
              )
            ]
          )
        , ( "malformed Quiet and Check calls report exact arity errors"
          , "probe[Quiet[], Quiet[Print[\"body\"], Print[\"off\"], Print[\"on\"], Print[\"extra\"]], Check[], Check[Print[\"check\"]], Check[Print[\"body2\"], x, y, Print[\"extra2\"]]]"
          , "probe[Quiet[], Quiet[Print[\"body\"], Print[\"off\"], Print[\"on\"], Print[\"extra\"]], Check[], Check[Print[\"check\"]], Check[Print[\"body2\"], x, y, Print[\"extra2\"]]]"
          , [ ( "Quiet::error"
              , "MessageName[Quiet, \"error\"]"
              , "Quiet::error: Quiet expects one, two, or three arguments."
              )
            , ( "Quiet::error"
              , "MessageName[Quiet, \"error\"]"
              , "Quiet::error: Quiet expects one, two, or three arguments."
              )
            , ( "Check::error"
              , "MessageName[Check, \"error\"]"
              , "Check::error: Check expects two or three arguments."
              )
            , ( "Check::error"
              , "MessageName[Check, \"error\"]"
              , "Check::error: Check expects two or three arguments."
              )
            , ( "Check::error"
              , "MessageName[Check, \"error\"]"
              , "Check::error: Check expects two or three arguments."
              )
            ]
          )
        ]
      scopedMessageCases =
        [ ( "Quiet visibility and Check collection depend on entry depth"
          , "{Check[Quiet[Part[]], outer], Quiet[Check[Part[], inner]], $MessageList}"
          , "List[Part[], inner, List[HoldForm[MessageName[Part, \"error\"]], HoldForm[MessageName[Part, \"error\"]]]]"
          , []
          , [partArityMessage, partArityMessage]
          )
        , ( "Quiet hides unhandled confirmation messages without blocking generation"
          , "Quiet[Confirm[$Failed]]"
          , "Failure[ConfirmationFailed, Association[Rule[\"ConfirmationType\", Confirm], Rule[\"Expression\", $Failed], Rule[\"Information\", Null]]]"
          , []
          , [ ( "Confirm::confirmnotag"
              , "MessageName[Confirm, \"confirmnotag\"]"
              , "Confirm::confirmnotag: Message generated."
              )
            ]
          )
        , ( "Quiet on specifications override off specifications"
          , "Quiet[Message[f::a]; Message[g::b], All, f::a]; $MessageList"
          , "List[HoldForm[MessageName[f, \"a\"]], HoldForm[MessageName[g, \"b\"]]]"
          , [fAMessage]
          , [fAMessage, gBMessage]
          )
        , ( "nested Check collectors retain outer captures"
          , "Check[Check[Message[f::a], inner]; Message[g::b], outer]"
          , "outer"
          , [fAMessage, gBMessage]
          , [fAMessage, gBMessage]
          )
        , ( "Quiet and Check specifications evaluate before their scopes"
          , "{Check[Message[f::a], fallback, Part[]], Quiet[Message[g::b], Part[]], $MessageList}"
          , "List[Null, Null, List[HoldForm[MessageName[Part, \"error\"]], HoldForm[MessageName[f, \"a\"]], HoldForm[MessageName[Part, \"error\"]], HoldForm[MessageName[g, \"b\"]]]]"
          , [partArityMessage, fAMessage, partArityMessage, gBMessage]
          , [partArityMessage, fAMessage, partArityMessage, gBMessage]
          )
        , ( "Quiet scopes restore across goto propagation"
          , "(Quiet[Goto[out]]; never; Label[out]; Message[f::a]; $MessageList)"
          , "List[HoldForm[MessageName[f, \"a\"]]]"
          , [fAMessage]
          , [fAMessage]
          )
        , ( "Check collectors restore and bypass fallbacks across goto propagation"
          , "(Check[Message[f::a]; Goto[out], fallback]; never; Label[out]; Message[g::b]; $MessageList)"
          , "List[HoldForm[MessageName[f, \"a\"]], HoldForm[MessageName[g, \"b\"]]]"
          , [fAMessage, gBMessage]
          , [fAMessage, gBMessage]
          )
        ]
  caseResults <- traverse evaluateSessionCase cases
  printResults <- traverse evaluatePrintCase printCases
  messageResults <- traverse evaluateMessageCase messageCases
  scopedMessageResults <- traverse evaluateScopedMessageCase scopedMessageCases
  pure (and (caseResults <> printResults <> messageResults <> scopedMessageResults))
 where
  evaluateSessionCase (label, source, expected) = do
    result <- fmap
      ( fmap
          ( \(value, updated) ->
              ( fullForm value
              , null (sessionAbortProtectScopes updated)
              , null (sessionCheckAbortScopes updated)
              , null (sessionReapScopes updated)
              , null (sessionEncloseScopes updated)
              )
          )
      )
      (evaluateSessionSource source)
    assertEqual
      ("evaluation session: " <> label)
      (Right (expected, True, True, True, True))
      result

  evaluatePrintCase (label, source, expectedValue, expectedPrints) = do
    result <- fmap
      ( fmap
          ( \(value, updated) ->
              ( fullForm value
              , sessionPrints updated
              , null (sessionAbortProtectScopes updated)
              , null (sessionCheckAbortScopes updated)
              , null (sessionReapScopes updated)
              , null (sessionEncloseScopes updated)
              )
          )
      )
      (evaluateSessionSource source)
    assertEqual
      ("evaluation session prints: " <> label)
      (Right (expectedValue, expectedPrints, True, True, True, True))
      result

  evaluateMessageCase (label, source, expectedValue, expectedMessages) = do
    result <- fmap
      ( fmap
          ( \(value, updated) ->
              ( fullForm value
              , map messageTuple (sessionVisibleMessages updated)
              , map messageTuple (sessionGeneratedMessages updated)
              , null (sessionEncloseScopes updated)
              )
          )
      )
      (evaluateSessionSource source)
    let expected =
          Right (expectedValue, expectedMessages, expectedMessages, True)
    assertEqual ("evaluation session messages: " <> label) expected result

  evaluateScopedMessageCase
    (label, source, expectedValue, expectedVisible, expectedGenerated) = do
      result <- fmap
        ( fmap
            ( \(value, updated) ->
                ( fullForm value
                , map messageTuple (sessionVisibleMessages updated)
                , map messageTuple (sessionGeneratedMessages updated)
                , null (sessionQuietScopes updated)
                , null (sessionMessageCollectors updated)
                , null (sessionEncloseScopes updated)
                )
            )
        )
        (evaluateSessionSource source)
      let expected =
            Right
              ( expectedValue
              , expectedVisible
              , expectedGenerated
              , True
              , True
              , True
              )
      assertEqual ("evaluation scoped messages: " <> label) expected result

  messageTuple message =
    ( evaluationMessageName message
    , fullForm (evaluationMessageFullName message)
    , evaluationMessageText message
    )

checkSessionTimingRuntime :: IO Bool
checkSessionTimingRuntime = do
  pureBoundary <-
    assertEqual
      "pure evaluator leaves runtime timing effects symbolic"
      (Right "Pause[0]")
      (pureTimingFullForm "Pause[0]")
  clock <- newIORef 100.0
  let runtime =
        SessionRuntime
          { sessionRuntimeMonotonicSeconds = readIORef clock
          , sessionRuntimeSleepSeconds = \seconds ->
              modifyIORef' clock (+ seconds)
          }
      deterministicCases =
        [ ( "time remaining uses the active deadline"
          , "TimeConstrained[TimeRemaining[], 2, fail]"
          , "2."
          , []
          )
        , ( "pause cooperatively expires its deadline"
          , "TimeConstrained[Pause[2]; 7, 1, timeout]"
          , "timeout"
          , []
          )
        , ( "inner deadline owns its timeout"
          , "TimeConstrained[TimeConstrained[Pause[2]; 7, 1, inner], 5, outer]"
          , "inner"
          , []
          )
        , ( "outer deadline remains authoritative"
          , "TimeConstrained[TimeConstrained[Pause[2]; 7, 5, inner], 1, outer]"
          , "outer"
          , []
          )
        , ( "time expiration crosses AbortProtect without becoming Abort"
          , "CheckAbort[AbortProtect[TimeConstrained[Pause[2], 1, inner]], fail]"
          , "inner"
          , []
          )
        , ( "body cleanup suppresses an expired deadline"
          , "TimeConstrained[WithCleanup[Pause[2]; 7, Print[TimeRemaining[]]], 1, timeout]"
          , "timeout"
          , ["Infinity"]
          )
        , ( "initializer and cleanup suppress an expired deadline"
          , "TimeConstrained[WithCleanup[Pause[2], 7, Print[TimeRemaining[]]], 1, timeout]"
          , "timeout"
          , ["Infinity"]
          )
        , ( "cleanup throw supersedes a pending timeout"
          , "TimeConstrained[WithCleanup[Pause[2], Throw[cleanup]], 1, timeout]"
          , "Throw[cleanup]"
          , []
          )
        , ( "time scope restores across Throw"
          , "Catch[TimeConstrained[Throw[x], 1, timeout]]"
          , "x"
          , []
          )
        , ( "time scope restores across ConfirmationFailed"
          , "Enclose[TimeConstrained[Confirm[$Failed], 1, timeout]]"
          , "Failure[ConfirmationFailed, Association[Rule[\"ConfirmationType\", Confirm], Rule[\"Expression\", $Failed], Rule[\"Information\", Null]]]"
          , []
          )
        , ( "time scope restores across Abort"
          , "CheckAbort[TimeConstrained[Abort[], 1, timeout], caught]"
          , "caught"
          , []
          )
        , ( "time scope restores across Break"
          , "Do[TimeConstrained[Break[], 1, timeout], {i, 1}]"
          , "Null"
          , []
          )
        , ( "time scope restores across Continue"
          , "Do[TimeConstrained[Continue[], 1, timeout], {i, 1}]"
          , "Null"
          , []
          )
        , ( "time scope restores across Return"
          , "ClearAll[f]; f[] := TimeConstrained[Return[x], 1, timeout]; f[]"
          , "x"
          , []
          )
        , ( "time scope restores across a targeted Return"
          , "Module[{}, TimeConstrained[Return[x, Module], 1, timeout]]"
          , "x"
          , []
          )
        , ( "time scope restores across Goto"
          , "(TimeConstrained[Goto[out], 1, timeout]; never; Label[out]; reached)"
          , "reached"
          , []
          )
        , ( "evaluation diagnostics recover after a runtime suspension"
          , "Quiet[TimeConstrained[1, AbsoluteTiming[1], fail]]"
          , "TimeConstrained[1, AbsoluteTiming[1], fail]"
          , []
          )
        ]
  deterministicResults <- traverse (runCase runtime clock) deterministicCases
  fakeTiming <- runAbsoluteTimingCase runtime clock
  realTiming <- runRealAbsoluteTimingCase
  realTimeout <- runRealTimeoutCase
  pure
    ( pureBoundary
        && and (deterministicResults <> [fakeTiming, realTiming, realTimeout])
    )
 where
  pureTimingFullForm source = do
    expression <- parseInputForm source
    case evaluate expression of
      Left evaluationError ->
        Left (ParseError (evaluationErrorMessage evaluationError))
      Right value -> Right (fullForm value)

  runCase runtime clock (label, source, expected, expectedPrints) = do
    writeIORef clock 100.0
    evaluated <- evaluateWith runtime source
    assertEqual
      ("session timing: " <> label)
      (Right (expected, expectedPrints, True, 0, True, True, True, True, True))
      ( fmap
          ( \(value, updated) ->
              ( fullForm value
              , sessionPrints updated
              , null (sessionTimeConstraintScopes updated)
              , sessionTimeConstraintSuppressionDepth updated
              , null (sessionAbortProtectScopes updated)
              , null (sessionCheckAbortScopes updated)
              , null (sessionReapScopes updated)
              , null (sessionEncloseScopes updated)
              , null (sessionQuietScopes updated)
              )
          )
          evaluated
      )

  runAbsoluteTimingCase runtime clock = do
    writeIORef clock 100.0
    evaluated <- evaluateWith runtime "AbsoluteTiming[Pause[0.25]; 3]"
    case evaluated of
      Right
        ( Call (Symbol "List") [Real elapsedSource, Integer 3]
          , updated
          ) ->
            assertEqual
              "session timing: deterministic AbsoluteTiming structure"
              True
              ( maybe False (\elapsed -> elapsed >= 0.24 && elapsed <= 0.26) (realValue elapsedSource)
                  && timingScopesRestored updated
              )
      other ->
        assertEqual
          "session timing: deterministic AbsoluteTiming result"
          "List[Real, 3]"
          (either (Text.pack . show) (fullForm . fst) other)

  runRealAbsoluteTimingCase = do
    evaluated <- evaluateWith defaultSessionRuntime "AbsoluteTiming[Pause[0.03]]"
    case evaluated of
      Right
        ( Call (Symbol "List") [Real elapsedSource, Symbol "Null"]
          , updated
          ) ->
            assertEqual
              "session timing: real AbsoluteTiming deadline margin"
              True
              ( maybe False (\elapsed -> elapsed >= 0.02 && elapsed < 2.0) (realValue elapsedSource)
                  && timingScopesRestored updated
              )
      other ->
        assertEqual
          "session timing: real AbsoluteTiming result"
          "List[Real, Null]"
          (either (Text.pack . show) (fullForm . fst) other)

  runRealTimeoutCase = do
    evaluated <-
      evaluateWith
        defaultSessionRuntime
        "TimeConstrained[Pause[0.2], 0.03, timeout]"
    assertEqual
      "session timing: real timeout uses a robust margin"
      (Right ("timeout", True))
      ( fmap
          (\(value, updated) -> (fullForm value, timingScopesRestored updated))
          evaluated
      )

  evaluateWith runtime source = case parseInputForm source of
    Left parseError -> pure (Left parseError)
    Right expression -> do
      evaluated <- evaluateInSessionWithRuntime runtime emptySession expression
      pure
        ( either
            (Left . ParseError . evaluationErrorMessage)
            Right
            evaluated
        )

  timingScopesRestored session =
    null (sessionTimeConstraintScopes session)
      && sessionTimeConstraintSuppressionDepth session == 0

  realValue :: Text -> Maybe Double
  realValue source =
    readMaybe
      (Text.unpack (Text.replace "*^" "e" source))

checkRepl :: IO Bool
checkRepl = do
  firstStep <- evaluateReplLine initialReplState "x = 2"
  let firstState = replStateFrom firstStep
  secondStep <- evaluateReplLine firstState "x^3"
  let secondState = replStateFrom secondStep
  thirdStep <- evaluateReplLine secondState "% + %%"
  let thirdState = replStateFrom thirdStep
  messageStep <-
    evaluateReplLine
      thirdState
      "x = 5; {Part[f[x = x + 1], 2], x}"
  let messageState = replStateFrom messageStep
  persistedAfterMessageStep <- evaluateReplLine messageState "x"
  parseFailureAfterMessage <- evaluateReplLine messageState "1 +"
  offStep <- evaluateReplLine initialReplState "Off[f::tag]"
  suppressedMessageStep <-
    evaluateReplLine
      (replStateFrom offStep)
      "Message[f::tag]; $MessageList"
  onStep <- evaluateReplLine (replStateFrom suppressedMessageStep) "On[f::tag]"
  enabledMessageStep <-
    evaluateReplLine
      (replStateFrom onStep)
      "Message[f::tag]; $MessageList"
  resetMessageListStep <-
    evaluateReplLine (replStateFrom enabledMessageStep) "$MessageList"
  printStep <- evaluateReplLine thirdState "Print[\"x\", 2]; 1"
  printSequenceStep <- evaluateReplLine thirdState "Print[Sequence[1, 2]]"
  printRationalStep <- evaluateReplLine thirdState "Print[1/2]"
  printAliasStep <- evaluateReplLine thirdState "p = Print; p[1/2]"
  timingStep <-
    evaluateReplLine
      thirdState
      "TimeConstrained[Pause[0]; 7, 1, fail]"
  lineStep <- evaluateReplLine thirdState "$Line"
  historyStep <- evaluateReplLine thirdState "{Out[1], InString[2]}"
  exitStep <- evaluateReplLine thirdState "Exit[7]"
  let checks =
        [ assertEqual "REPL assignment result" (Just (Integer 2)) (replValueFrom firstStep)
        , assertEqual "REPL persistent definition" (Just (Integer 8)) (replValueFrom secondStep)
        , assertEqual "REPL percent history" (Just (Integer 10)) (replValueFrom thirdStep)
        , assertEqual
            "REPL nonfatal message result"
            ( Just
                ( Call
                    (Symbol "List")
                    [ Call
                        (Symbol "Part")
                        [ Call
                            (Symbol "f")
                            [ Call
                                (Symbol "Set")
                                [ Symbol "x"
                                , Call (Symbol "Plus") [Symbol "x", Integer 1]
                                ]
                            ]
                        , Integer 2
                        ]
                    , Integer 6
                    ]
                )
            )
            (replValueFrom messageStep)
        , assertEqual
            "REPL exposes visible message"
            ["Part::error: Part specifications are invalid for f[6]."]
            ( map evaluationMessageText
                (sessionVisibleMessages (replSession messageState))
            )
        , assertEqual
            "REPL retains state after message"
            (Just (Integer 6))
            (replValueFrom persistedAfterMessageStep)
        , assertEqual
            "REPL clears prior input messages"
            []
            ( sessionVisibleMessages
                (replSession (replStateFrom persistedAfterMessageStep))
            )
        , assertEqual
            "REPL parse failures clear transient messages"
            []
            ( sessionVisibleMessages
                (replSession (replStateFrom parseFailureAfterMessage))
            )
        , assertEqual
            "REPL message disabling persists across inputs"
            (Just (Call (Symbol "List") []))
            (replValueFrom suppressedMessageStep)
        , assertEqual
            "REPL disabled messages are neither generated nor visible"
            ([], [])
            ( let messageSession = replSession (replStateFrom suppressedMessageStep)
               in ( sessionGeneratedMessages messageSession
                  , sessionVisibleMessages messageSession
                  )
            )
        , assertEqual
            "REPL message enabling persists across inputs"
            ( Just
                ( Call
                    (Symbol "List")
                    [ Call
                        (Symbol "HoldForm")
                        [ Call
                            (Symbol "MessageName")
                            [Symbol "f", String "tag"]
                        ]
                    ]
                )
            )
            (replValueFrom enabledMessageStep)
        , assertEqual
            "REPL current message list resets on the next input"
            (Just (Call (Symbol "List") []))
            (replValueFrom resetMessageListStep)
        , assertEqual
            "REPL captures Print output"
            ["x2"]
            (sessionPrints (replSession (replStateFrom printStep)))
        , assertEqual
            "REPL Print preserves Sequence"
            ["Sequence[1, 2]"]
            (sessionPrints (replSession (replStateFrom printSequenceStep)))
        , assertEqual
            "REPL Print uses InputForm"
            ["1/2"]
            (sessionPrints (replSession (replStateFrom printRationalStep)))
        , assertEqual
            "REPL Print aliases remain inert"
            (Just (Call (Symbol "Print") [Rational 1 2]))
            (replValueFrom printAliasStep)
        , assertEqual
            "REPL Print aliases do not capture output"
            []
            (sessionPrints (replSession (replStateFrom printAliasStep)))
        , assertEqual
            "REPL executes session runtime timing effects"
            (Just (Integer 7))
            (replValueFrom timingStep)
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

checkInputForms :: IO Bool
checkInputForms = do
  let cases =
        [ ("list and association", "{a, <|x -> 1/2|>}", "{a, <|x -> 1/2|>}")
        , ("operator precedence", "(a + b) * c^(-2)", "(a + b) * c^(-2)")
        , ("singleton negative Times", "Times[-1]", "-Times[]")
        , ("slots", "{#, #2, ##, ##3}", "{#, #2, ##, ##3}")
        , ("blank patterns", "{x_, x__Integer, x___}", "{x_, x__Integer, x___}")
        , ("pattern operators", "{x_?p, x_:1, p.., p...}", "{x_?p, x_:1, p.., p...}")
        , ("condition", "x_ /; p[x]", "x_ /; p[x]")
        , ("mapping operators", "{f /@ x, f @@ x, x /. r, x //. r}", "{f /@ x, f @@ x, x /. r, x //. r}")
        , ("composition", "{f @* g, f /* g}", "{f @* g, f /* g}")
        , ("updates", "{x++, ++x, x =.}", "{x++, ++x, x =.}")
        , ("tagged delayed assignment", "TagSetDelayed[f, h[f[x_]], x]", "f /: h[f[x_]] := x")
        , ("tagged unset", "TagUnset[f, h[f[x_]]]", "f /: h[f[x_]] =.")
        , ("message name", "a::b", "a::b")
        , ("nested prefix not", "!!a", "!!a")
        , ("span shorthand", "1 ;; 3", ";; 3")
        , ("part shorthand", "Part[f[a], 1]", "f[a][[1]]")
        , ("explicit System operator", "System`Plus[a, b]", "a + b")
        , ("explicit System collection", "System`List[a, b]", "{a, b}")
        , ("explicit System slots", "System`Function[System`Slot[1]]", "# &")
        , ("explicit System part", "System`Part[f[a], 1]", "f[a][[1]]")
        , ("non-System operator name", "Global`Plus[a, b]", "Global`Plus[a, b]")
        , ("Unicode symbol", "\\[Alpha]", "α")
        ]
  and
    <$> traverse
      ( \(label, source, expected) ->
          assertEqual
            ("InputForm renderer: " <> label)
            (Right expected)
            (inputForm <$> parseInputForm source)
      )
      cases

checkSmartConstructors :: IO Bool
checkSmartConstructors = do
  let normalized = expectRight (rational (-6) (-8))
      rootValue = expectRight (root [-2, 0, 1] 0 0)
      sparseValue = expectRight (sparseArray [3] [] (Integer 0))
      rootDepthAndLevel =
        fullForm
          <$> evaluate
            ( Call
                (Symbol "List")
                [ Call (Symbol "Depth") [rootValue]
                , Call (Symbol "Level") [rootValue, Call (Symbol "List") [Integer (-1)]]
                ]
            )
      sparseDepthAndLevels =
        fullForm
          <$> evaluate
            ( Call
                (Symbol "List")
                [ Call (Symbol "Depth") [sparseValue]
                , Call (Symbol "Level") [sparseValue, Call (Symbol "List") [Integer (-2)]]
                , Call (Symbol "Level") [sparseValue, Symbol "Infinity"]
                ]
            )
      checks =
        [ assertEqual "rational normalization" (Rational 3 4) normalized
        , assertLeft "zero denominator" (rational 1 0)
        , assertLeft "constant root" (root [1] 0 0)
        , assertLeft "invalid sparse coordinate" (sparseArray [2] [SparseEntry [3] (Integer 1)] (Integer 0))
        , assertLeft "duplicate sparse coordinate" (sparseArray [2] [SparseEntry [1] (Integer 1), SparseEntry [1] (Integer 2)] (Integer 0))
        , assertEqual "complex is atomic" [] (arguments (Complex (Integer 1) (Integer 2)))
        , assertEqual "root arguments" [Call (Symbol "Function") [Call (Symbol "Plus") [Integer (-2), Call (Symbol "Slot") [Integer 1]]], Integer 1, Integer 0] (arguments (expectRight (root [-2, 1] 0 0)))
        , assertEqual
            "root depth and exact negative level"
            (Right ("List[1, List[" <> fullForm rootValue <> "]]"))
            rootDepthAndLevel
        , assertEqual
            "sparse depth and untraversed negative level"
            (Right ("List[2, List[" <> fullForm sparseValue <> "], List[]]"))
            sparseDepthAndLevels
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
  response <- handleProtocolRequest request
  let encoded = encodeResponseLine response
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
  actual <- handleProtocolRequest request
  second <- assertEqual "unknown protocol command" expected actual
  third <- assertLeft "protocol source must be a string" (decodeRequestLine "{\"command\":\"parse\",\"source\":42}")
  pure (first && second && third)

checkParserEvaluatorProtocol :: IO Bool
checkParserEvaluatorProtocol = do
  let parseRequest = expectRight (decodeRequestLine "{\"id\":1,\"command\":\"parse\",\"form\":\"input\",\"source\":\"1 + 2 x\"}")
      evaluateRequest = expectRight (decodeRequestLine "{\"id\":2,\"command\":\"evaluate\",\"source\":\"Total[Range[5]]\"}")
      sessionEvaluateRequest = expectRight (decodeRequestLine "{\"id\":3,\"command\":\"evaluate\",\"source\":\"x = 2; x^3\"}")
      isolatedEvaluateRequest = expectRight (decodeRequestLine "{\"id\":4,\"command\":\"evaluate\",\"source\":\"x\"}")
      messageEvaluateRequest = expectRight (decodeRequestLine "{\"id\":5,\"command\":\"evaluate\",\"source\":\"Part[f[a], 2]\"}")
      printEvaluateRequest = expectRight (decodeRequestLine "{\"id\":6,\"command\":\"evaluate\",\"source\":\"Print[\\\"x\\\"]; 1\"}")
      timingEvaluateRequest = expectRight (decodeRequestLine "{\"id\":7,\"command\":\"evaluate\",\"source\":\"TimeConstrained[Pause[0]; 7, 1, fail]\"}")
  parseResponse <- handleProtocolRequest parseRequest
  evaluateResponse <- handleProtocolRequest evaluateRequest
  sessionEvaluateResponse <- handleProtocolRequest sessionEvaluateRequest
  isolatedEvaluateResponse <- handleProtocolRequest isolatedEvaluateRequest
  messageEvaluateResponse <- handleProtocolRequest messageEvaluateRequest
  printEvaluateResponse <- handleProtocolRequest printEvaluateRequest
  timingEvaluateResponse <- handleProtocolRequest timingEvaluateRequest
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
  fifth <- case messageEvaluateResponse of
    ProtocolSuccess {protocolResult = JsonObject outer} ->
      assertEqual
        "protocol nonfatal evaluation messages"
        ( Just
            ( JsonArray
                [ JsonObject
                    ( Map.fromList
                        [ ("full_name", JsonString "MessageName[Part, \"error\"]")
                        , ("name", JsonString "Part::error")
                        , ("text", JsonString "Part::error: Part specifications are invalid for f[a].")
                        ]
                    )
                ]
            )
        )
        (Map.lookup "messages" outer)
    other -> assertEqual "protocol message response" True (isSuccess other)
  sixth <- assertProtocolEvaluation "protocol nonfatal inert result" "Part[f[a], 2]" messageEvaluateResponse
  seventh <- case printEvaluateResponse of
    ProtocolSuccess {protocolResult = JsonObject outer} ->
      assertEqual
        "protocol Print capture"
        (Just (JsonArray [JsonString "x"]))
        (Map.lookup "prints" outer)
    other -> assertEqual "protocol Print response" True (isSuccess other)
  eighth <- assertProtocolEvaluation "protocol Print result" "1" printEvaluateResponse
  ninth <-
    assertProtocolEvaluation
      "protocol executes session runtime timing effects"
      "7"
      timingEvaluateResponse
  pure (and [first, second, third, fourth, fifth, sixth, seventh, eighth, ninth])
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

evaluateSessionSource
  :: Text
  -> IO (Either ParseError (Expr, EvaluationSession))
evaluateSessionSource source = case parseInputForm source of
  Left parseError -> pure (Left parseError)
  Right expression -> do
    evaluated <- evaluateInSession emptySession expression
    pure
      ( either
          (Left . ParseError . evaluationErrorMessage)
          Right
          evaluated
      )

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
