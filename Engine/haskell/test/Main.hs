{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import System.Exit (exitFailure)
import Tungsten.Cli
import Tungsten.Expression
import Tungsten.Evaluate
import Tungsten.Json
import Tungsten.Notebook
import Tungsten.Parser
import Tungsten.Repl
import Tungsten.Session

main :: IO ()
main = do
  results <- sequence tests
  if and results
    then TextIO.putStrLn "All Haskell expression/JSON foundation tests passed."
    else exitFailure

tests :: [IO Bool]
tests =
  [ checkFullForms
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
  , checkSmartConstructors
  , checkExpressionJsonRoundTrips
  , checkJsonCodec
  , checkProtocol
  , checkParserEvaluatorProtocol
  , checkProtocolErrors
  ]

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
        , ("escaped symbol", "\\:03b1", fullForm (Symbol "α"))
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
