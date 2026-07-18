{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import qualified Data.ByteString as BS
import Data.Char (chr)
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
    assertEqual
      "assistant selected-cell unavailable path"
      (Right False)
      (assistantSuccess <$> result)
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
        , ("negative rational power", "(2/3)^-3", "Rational[27, 8]")
        , ("symbolic coefficient collection", "2 x 3", "Times[6, x]")
        , ("symbolic constant collection", "x + 1 + 2", "Plus[3, x]")
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
  let result = parseInputForm "{a, b}[[3]]" >>= mapLeftEvaluation . evaluate
  assertLeft "reject out-of-range Part during evaluation" result
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
      pure (and [first, second, third, fourth, fifth, sixth, seventh])
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
      parseResponse = handleProtocolRequest parseRequest
      evaluateResponse = handleProtocolRequest evaluateRequest
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
  pure (first && second)
 where
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
