{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | JSON-first command-line entry points for the Haskell engine.
module Tungsten.Cli
  ( CliCommand (..)
  , AssistantCommand (..)
  , ExpressionCommand (..)
  , NotebookCommand (..)
  , InlineBoxCommand (..)
  , DocumentationCommand (..)
  , ParserCorpusCommand (..)
  , FrontEndCommand (..)
  , SourceSpec (..)
  , parseCliArguments
  , decodeNotebookPatches
  , runCli
  ) where

import Control.Applicative ((<|>))
import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import System.Directory (makeAbsolute)
import Text.Read (readMaybe)
import System.IO
  ( BufferMode (LineBuffering)
  , hIsEOF
  , hSetBuffering
  , hSetEncoding
  , stderr
  , stdin
  , stdout
  , utf8
  )
import Tungsten.Evaluate (evaluate, evaluationErrorMessage)
import Tungsten.Assistant
import Tungsten.Discovery
import Tungsten.DocsIndex
import Tungsten.Expression
import Tungsten.Frontend
import Tungsten.InlineBoxes
import Tungsten.Json
import Tungsten.Kernel
import Tungsten.Notebook
import Tungsten.Parser
import Tungsten.ParserCorpus
import Tungsten.Repl (runRepl)
import Tungsten.WolframString (WolframStringSegment (..))

data CliCommand
  = ProtocolCommand
  | ReplCommand !Bool
  | EnvironmentCommand !Bool
  | KernelCommand !SourceSpec !(Maybe FilePath) !Bool !Bool
  | FrontEndCommand !FrontEndCommand
  | ExpressionCliCommand !ExpressionCommand !SourceSpec !Text
  | NotebookCliCommand !NotebookCommand
  | InlineBoxCliCommand !InlineBoxCommand
  | DocumentationCliCommand !DocumentationCommand
  | ParserCorpusCliCommand !ParserCorpusCommand
  | AssistantCliCommand !AssistantCommand
  | HelpCommand
  deriving (Eq, Show)

data ExpressionCommand = ParseCommand | EvaluateCommand
  deriving (Eq, Show)

data SourceSpec = InlineSource !Text | FileSource !FilePath
  deriving (Eq, Show)

data NotebookCommand
  = InspectNotebookCommand !FilePath
  | CreateNotebookCommand !FilePath !(Maybe Text) ![(Text, Text)]
  | PatchNotebookCommand !FilePath !FilePath !(Maybe FilePath)
  deriving (Eq, Show)

data InlineBoxCommand
  = ComposeInlineBoxCommand ![Text] !Text !Text
  | InlineBoxFromCellCommand
      !FilePath
      !CellSelector
      !Text
      !Text
      !Int
      !Bool
      !Bool
  deriving (Eq, Show)

data DocumentationCommand
  = BuildDocumentationIndexCommand !(Maybe FilePath)
  | SearchDocumentationCommand !Text !Int !(Maybe FilePath) !Bool
  | ReadDocumentationCommand !Text !(Maybe FilePath) !Bool
  | OpenDocumentationCommand !Text !(Maybe FilePath)
  deriving (Eq, Show)

data ParserCorpusCommand
  = DiscoverParserCorpusCommand !ParserCorpusOptions !Int
  | CompareParserCorpusCommand !ParserCorpusOptions !Bool !Bool !Bool
  deriving (Eq, Show)

data AssistantCommand
  = AskAssistantCommand
      !Text
      !(Maybe Text)
      !(Maybe Text)
      !(Maybe Text)
      !(Maybe Text)
      ![Text]
      !Bool
  | AskCellAssistantCommand
      !FilePath
      !CellSelector
      !Text
      !Text
      !Bool
      !Bool
      !(Maybe Text)
      !(Maybe Text)
      !(Maybe Text)
      !Bool
  | PrepareInlineAssistantCommand !FilePath !CellSelector !Bool
  | CaptureInlineAssistantCommand !FilePath !CellSelector !Text !Bool !Bool
  deriving (Eq, Show)

data FrontEndCommand
  = ProbeFrontEndCommand !Bool
  | RunFrontEndCommand !Text !Bool !Bool
  | OpenFrontEndNotebookCommand !FilePath !Bool
  | OpenFrontEndDocumentationCommand !Text !(Maybe FilePath) !Bool
  | ExecuteFrontEndTokenCommand !Text !(Maybe FilePath) !Bool
  deriving (Eq, Show)

parseCliArguments :: [String] -> Either Text CliCommand
parseCliArguments = \case
  [] -> Right ProtocolCommand
  ["protocol"] -> Right ProtocolCommand
  ["repl"] -> Right (ReplCommand True)
  ["repl", "--no-banner"] -> Right (ReplCommand False)
  ["env", "show"] -> Right (EnvironmentCommand False)
  ["env", "show", "--probe"] -> Right (EnvironmentCommand True)
  ["--help"] -> Right HelpCommand
  ["-h"] -> Right HelpCommand
  "expr" : "parse" : arguments' -> parseExpressionArguments ParseCommand arguments'
  "expr" : "evaluate" : arguments' -> parseExpressionArguments EvaluateCommand arguments'
  "kernel" : "eval" : arguments' -> parseKernelArguments arguments'
  "frontend" : "probe" : arguments' ->
    FrontEndCommand . ProbeFrontEndCommand <$> parseRequireSuccess arguments'
  "frontend" : "run" : arguments' -> parseFrontEndRunArguments arguments'
  "frontend" : "open-notebook" : arguments' -> parseFrontEndOpenNotebookArguments arguments'
  "frontend" : "open-doc" : identifier : arguments' ->
    parseFrontEndOpenDocumentationArguments (T.pack identifier) arguments'
  "frontend" : "token" : token : arguments' -> parseFrontEndTokenArguments (T.pack token) arguments'
  "notebook" : "inspect" : arguments' -> parseNotebookInspectArguments arguments'
  "notebook" : "create" : arguments' -> parseNotebookCreateArguments arguments'
  "notebook" : "patch" : arguments' -> parseNotebookPatchArguments arguments'
  "inline-box" : "compose" : arguments' -> parseInlineBoxComposeArguments arguments'
  "inline-box" : "from-cell" : arguments' -> parseInlineBoxFromCellArguments arguments'
  "docs" : "index" : arguments' -> parseDocumentationIndexArguments arguments'
  "docs" : "search" : query : arguments' -> parseDocumentationSearchArguments (T.pack query) arguments'
  "docs" : "read" : identifier : arguments' -> parseDocumentationReadArguments (T.pack identifier) arguments'
  "docs" : "open" : identifier : arguments' -> parseDocumentationOpenArguments (T.pack identifier) arguments'
  "parser-corpus" : "discover" : arguments' -> parseParserCorpusDiscoverArguments arguments'
  "parser-corpus" : "compare" : arguments' -> parseParserCorpusCompareArguments arguments'
  "assistant" : "ask" : arguments' -> parseAssistantAskArguments arguments'
  "assistant" : "ask-cell" : arguments' -> parseAssistantAskCellArguments arguments'
  "assistant" : "prepare-inline" : arguments' -> parseAssistantPrepareInlineArguments arguments'
  "assistant" : "capture-inline" : arguments' -> parseAssistantCaptureInlineArguments arguments'
  _ -> Left "expected 'protocol', 'repl', an 'expr' command, or a 'notebook' command"

parseAssistantAskArguments :: [String] -> Either Text CliCommand
parseAssistantAskArguments = go Nothing Nothing Nothing Nothing Nothing [] False
 where
  go (Just prompt) systemPrompt extraInstructions modelService modelName tools requireSuccess [] =
    Right
      ( AssistantCliCommand
          ( AskAssistantCommand
              prompt systemPrompt extraInstructions modelService modelName tools requireSuccess
          )
      )
  go Nothing _ _ _ _ _ _ [] = Left "assistant ask requires --prompt TEXT"
  go Nothing systemPrompt extraInstructions modelService modelName tools requireSuccess ("--prompt" : value : rest) =
    go (Just (T.pack value)) systemPrompt extraInstructions modelService modelName tools requireSuccess rest
  go (Just _) _ _ _ _ _ _ ("--prompt" : _ : _) = Left "assistant ask accepts --prompt only once"
  go prompt Nothing extraInstructions modelService modelName tools requireSuccess ("--system-prompt" : value : rest) =
    go prompt (Just (T.pack value)) extraInstructions modelService modelName tools requireSuccess rest
  go _ (Just _) _ _ _ _ _ ("--system-prompt" : _ : _) = Left "assistant ask accepts --system-prompt only once"
  go prompt systemPrompt Nothing modelService modelName tools requireSuccess ("--extra-instructions" : value : rest) =
    go prompt systemPrompt (Just (T.pack value)) modelService modelName tools requireSuccess rest
  go _ _ (Just _) _ _ _ _ ("--extra-instructions" : _ : _) = Left "assistant ask accepts --extra-instructions only once"
  go prompt systemPrompt extraInstructions Nothing modelName tools requireSuccess ("--model-service" : value : rest) =
    go prompt systemPrompt extraInstructions (Just (T.pack value)) modelName tools requireSuccess rest
  go _ _ _ (Just _) _ _ _ ("--model-service" : _ : _) = Left "assistant ask accepts --model-service only once"
  go prompt systemPrompt extraInstructions modelService Nothing tools requireSuccess ("--model-name" : value : rest) =
    go prompt systemPrompt extraInstructions modelService (Just (T.pack value)) tools requireSuccess rest
  go _ _ _ _ (Just _) _ _ ("--model-name" : _ : _) = Left "assistant ask accepts --model-name only once"
  go prompt systemPrompt extraInstructions modelService modelName tools requireSuccess ("--tool" : value : rest) =
    go prompt systemPrompt extraInstructions modelService modelName (tools <> [T.pack value]) requireSuccess rest
  go prompt systemPrompt extraInstructions modelService modelName tools _ ("--require-success" : rest) =
    go prompt systemPrompt extraInstructions modelService modelName tools True rest
  go _ _ _ _ _ _ _ [flag]
    | flag `elem` ["--prompt", "--system-prompt", "--extra-instructions", "--model-service", "--model-name", "--tool"] =
        Left (T.pack flag <> " requires a value")
  go _ _ _ _ _ _ _ (flag : _) = Left ("unknown assistant ask option: " <> T.pack flag)

parseAssistantAskCellArguments :: [String] -> Either Text CliCommand
parseAssistantAskCellArguments = go Nothing Nothing Nothing False False False False Nothing Nothing Nothing False
 where
  go (Just file) (Just selector) (Just question) insertFirst insertAll save close extraInstructions modelService modelName requireSuccess [] =
    Right
      ( AssistantCliCommand
          ( AskCellAssistantCommand
              file selector question insertMode save close
              extraInstructions modelService modelName requireSuccess
          )
      )
   where
    insertMode | insertAll = "all"
               | insertFirst = "first"
               | otherwise = "none"
  go Nothing _ _ _ _ _ _ _ _ _ _ [] = Left "assistant ask-cell requires --file PATH"
  go _ Nothing _ _ _ _ _ _ _ _ _ [] = Left "assistant ask-cell requires exactly one cell selector"
  go _ _ Nothing _ _ _ _ _ _ _ _ [] = Left "assistant ask-cell requires --question TEXT"
  go Nothing selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--file" : value : rest) =
    go (Just value) selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go (Just _) _ _ _ _ _ _ _ _ _ _ ("--file" : _ : _) = Left "assistant ask-cell accepts --file only once"
  go file selector Nothing insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--question" : value : rest) =
    go file selector (Just (T.pack value)) insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go _ _ (Just _) _ _ _ _ _ _ _ _ ("--question" : _ : _) = Left "assistant ask-cell accepts --question only once"
  go file selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--cell-index" : value : rest) = do
    index <- parseIntegerOption "--cell-index" value
    next <- addSelector selector (SelectCellIndex index)
    go file (Just next) question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--cell-path" : value : rest) = do
    path <- parseCellPath (T.pack value)
    next <- addSelector selector (SelectCellPath path)
    go file (Just next) question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--expression-uuid" : value : rest) = do
    next <- addSelector selector (SelectExpressionUuid (T.pack value))
    go file (Just next) question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--cell-id" : value : rest) = do
    identifier <- parseIntegerOption "--cell-id" value
    next <- addSelector selector (SelectCellId identifier)
    go file (Just next) question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess ("--cell-tag" : value : rest) = do
    next <- addSelector selector (SelectCellTag (T.pack value))
    go file (Just next) question insertFirst insertAll save close extraInstructions modelService modelName requireSuccess rest
  go file selector question _ insertAll save close extraInstructions modelService modelName requireSuccess ("--insert-wolfram-code-below" : rest) =
    go file selector question True insertAll save close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst _ save close extraInstructions modelService modelName requireSuccess ("--insert-all-wolfram-code-below" : rest) =
    go file selector question insertFirst True save close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll _ close extraInstructions modelService modelName requireSuccess ("--save" : rest) =
    go file selector question insertFirst insertAll True close extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll save _ extraInstructions modelService modelName requireSuccess ("--close-assistant-notebook" : rest) =
    go file selector question insertFirst insertAll save True extraInstructions modelService modelName requireSuccess rest
  go file selector question insertFirst insertAll save close Nothing modelService modelName requireSuccess ("--extra-instructions" : value : rest) =
    go file selector question insertFirst insertAll save close (Just (T.pack value)) modelService modelName requireSuccess rest
  go _ _ _ _ _ _ _ (Just _) _ _ _ ("--extra-instructions" : _ : _) = Left "assistant ask-cell accepts --extra-instructions only once"
  go file selector question insertFirst insertAll save close extraInstructions Nothing modelName requireSuccess ("--model-service" : value : rest) =
    go file selector question insertFirst insertAll save close extraInstructions (Just (T.pack value)) modelName requireSuccess rest
  go _ _ _ _ _ _ _ _ (Just _) _ _ ("--model-service" : _ : _) = Left "assistant ask-cell accepts --model-service only once"
  go file selector question insertFirst insertAll save close extraInstructions modelService Nothing requireSuccess ("--model-name" : value : rest) =
    go file selector question insertFirst insertAll save close extraInstructions modelService (Just (T.pack value)) requireSuccess rest
  go _ _ _ _ _ _ _ _ _ (Just _) _ ("--model-name" : _ : _) = Left "assistant ask-cell accepts --model-name only once"
  go file selector question insertFirst insertAll save close extraInstructions modelService modelName _ ("--require-success" : rest) =
    go file selector question insertFirst insertAll save close extraInstructions modelService modelName True rest
  go _ _ _ _ _ _ _ _ _ _ _ [flag]
    | flag `elem` ["--file", "--question", "--cell-index", "--cell-path", "--expression-uuid", "--cell-id", "--cell-tag", "--extra-instructions", "--model-service", "--model-name"] =
        Left (T.pack flag <> " requires a value")
  go _ _ _ _ _ _ _ _ _ _ _ (flag : _) = Left ("unknown assistant ask-cell option: " <> T.pack flag)

  addSelector Nothing value = Right value
  addSelector (Just _) _ = Left "assistant ask-cell accepts exactly one cell selector"

parseAssistantPrepareInlineArguments :: [String] -> Either Text CliCommand
parseAssistantPrepareInlineArguments = go Nothing Nothing False
 where
  go (Just file) (Just selector) requireSuccess [] =
    Right (AssistantCliCommand (PrepareInlineAssistantCommand file selector requireSuccess))
  go Nothing _ _ [] = Left "assistant prepare-inline requires --file PATH"
  go _ Nothing _ [] = Left "assistant prepare-inline requires exactly one cell selector"
  go Nothing selector requireSuccess ("--file" : value : rest) =
    go (Just value) selector requireSuccess rest
  go (Just _) _ _ ("--file" : _ : _) = Left "assistant prepare-inline accepts --file only once"
  go file selector requireSuccess ("--cell-index" : value : rest) = do
    index <- parseIntegerOption "--cell-index" value
    next <- addSelector selector (SelectCellIndex index)
    go file (Just next) requireSuccess rest
  go file selector requireSuccess ("--cell-path" : value : rest) = do
    path <- parseCellPath (T.pack value)
    next <- addSelector selector (SelectCellPath path)
    go file (Just next) requireSuccess rest
  go file selector requireSuccess ("--expression-uuid" : value : rest) = do
    next <- addSelector selector (SelectExpressionUuid (T.pack value))
    go file (Just next) requireSuccess rest
  go file selector requireSuccess ("--cell-id" : value : rest) = do
    identifier <- parseIntegerOption "--cell-id" value
    next <- addSelector selector (SelectCellId identifier)
    go file (Just next) requireSuccess rest
  go file selector requireSuccess ("--cell-tag" : value : rest) = do
    next <- addSelector selector (SelectCellTag (T.pack value))
    go file (Just next) requireSuccess rest
  go file selector _ ("--require-success" : rest) = go file selector True rest
  go _ _ _ [flag]
    | flag `elem` ["--file", "--cell-index", "--cell-path", "--expression-uuid", "--cell-id", "--cell-tag"] =
        Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown assistant prepare-inline option: " <> T.pack flag)

  addSelector Nothing value = Right value
  addSelector (Just _) _ = Left "assistant prepare-inline accepts exactly one cell selector"

parseAssistantCaptureInlineArguments :: [String] -> Either Text CliCommand
parseAssistantCaptureInlineArguments = go Nothing Nothing False False False False
 where
  go (Just file) (Just selector) insertFirst insertAll save requireSuccess [] =
    Right
      ( AssistantCliCommand
          (CaptureInlineAssistantCommand file selector insertMode save requireSuccess)
      )
   where
    insertMode | insertAll = "all"
               | insertFirst = "first"
               | otherwise = "none"
  go Nothing _ _ _ _ _ [] = Left "assistant capture-inline requires --file PATH"
  go _ Nothing _ _ _ _ [] = Left "assistant capture-inline requires exactly one cell selector"
  go Nothing selector insertFirst insertAll save requireSuccess ("--file" : value : rest) =
    go (Just value) selector insertFirst insertAll save requireSuccess rest
  go (Just _) _ _ _ _ _ ("--file" : _ : _) = Left "assistant capture-inline accepts --file only once"
  go file selector insertFirst insertAll save requireSuccess ("--cell-index" : value : rest) = do
    index <- parseIntegerOption "--cell-index" value
    next <- addSelector selector (SelectCellIndex index)
    go file (Just next) insertFirst insertAll save requireSuccess rest
  go file selector insertFirst insertAll save requireSuccess ("--cell-path" : value : rest) = do
    path <- parseCellPath (T.pack value)
    next <- addSelector selector (SelectCellPath path)
    go file (Just next) insertFirst insertAll save requireSuccess rest
  go file selector insertFirst insertAll save requireSuccess ("--expression-uuid" : value : rest) = do
    next <- addSelector selector (SelectExpressionUuid (T.pack value))
    go file (Just next) insertFirst insertAll save requireSuccess rest
  go file selector insertFirst insertAll save requireSuccess ("--cell-id" : value : rest) = do
    identifier <- parseIntegerOption "--cell-id" value
    next <- addSelector selector (SelectCellId identifier)
    go file (Just next) insertFirst insertAll save requireSuccess rest
  go file selector insertFirst insertAll save requireSuccess ("--cell-tag" : value : rest) = do
    next <- addSelector selector (SelectCellTag (T.pack value))
    go file (Just next) insertFirst insertAll save requireSuccess rest
  go file selector _ insertAll save requireSuccess ("--insert-wolfram-code-below" : rest) =
    go file selector True insertAll save requireSuccess rest
  go file selector insertFirst _ save requireSuccess ("--insert-all-wolfram-code-below" : rest) =
    go file selector insertFirst True save requireSuccess rest
  go file selector insertFirst insertAll _ requireSuccess ("--save" : rest) =
    go file selector insertFirst insertAll True requireSuccess rest
  go file selector insertFirst insertAll save _ ("--require-success" : rest) =
    go file selector insertFirst insertAll save True rest
  go _ _ _ _ _ _ [flag]
    | flag `elem` ["--file", "--cell-index", "--cell-path", "--expression-uuid", "--cell-id", "--cell-tag"] =
        Left (T.pack flag <> " requires a value")
  go _ _ _ _ _ _ (flag : _) = Left ("unknown assistant capture-inline option: " <> T.pack flag)

  addSelector Nothing value = Right value
  addSelector (Just _) _ = Left "assistant capture-inline accepts exactly one cell selector"

parseParserCorpusDiscoverArguments :: [String] -> Either Text CliCommand
parseParserCorpusDiscoverArguments = go defaultOptions 20
 where
  defaultOptions = (defaultParserCorpusOptions defaultParserCorpusRoot)
    { parserCorpusCompareWolfram = False
    , parserCorpusWriteOutputs = False
    }
  go options sample [] = Right (ParserCorpusCliCommand (DiscoverParserCorpusCommand options sample))
  go options sample ("--corpus-root" : value : rest) =
    go options {parserCorpusRoot = value} sample rest
  go options sample ("--extension" : value : rest) =
    go options {parserCorpusExtensions = parserCorpusExtensions options <> [T.pack value]} sample rest
  go options sample ("--include-glob" : value : rest) =
    go options {parserCorpusIncludeGlobs = parserCorpusIncludeGlobs options <> [T.pack value]} sample rest
  go options sample ("--exclude-glob" : value : rest) =
    go options {parserCorpusExcludeGlobs = parserCorpusExcludeGlobs options <> [T.pack value]} sample rest
  go options sample ("--max-files" : value : rest) = do
    count <- parseIntegerOption "--max-files" value
    go options {parserCorpusMaximumFiles = Just count} sample rest
  go options sample ("--shuffle" : rest) = go options {parserCorpusShuffle = True} sample rest
  go options sample ("--seed" : value : rest) = do
    seed <- parseIntegerOption "--seed" value
    go options {parserCorpusSeed = seed} sample rest
  go options _ ("--sample" : value : rest) = do
    sample <- parseIntegerOption "--sample" value
    go options sample rest
  go _ _ [flag]
    | flag `elem` parserCorpusDiscoveryValueOptions <> ["--sample"] =
        Left (T.pack flag <> " requires a value")
  go _ _ (flag : _) = Left ("unknown parser-corpus discover option: " <> T.pack flag)

parseParserCorpusCompareArguments :: [String] -> Either Text CliCommand
parseParserCorpusCompareArguments = go defaultOptions (2 :: Double) Nothing False False False False
 where
  defaultOptions = defaultParserCorpusOptions defaultParserCorpusRoot
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch [] =
    let maximumBytes
          | noMaximum = Nothing
          | Just count <- exactBytes = Just count
          | otherwise = Just (floor (megabytes * 1024 * 1024))
     in Right
          ( ParserCorpusCliCommand
              ( CompareParserCorpusCommand
                  options {parserCorpusMaximumBytes = maximumBytes}
                  includeResults
                  failGap
                  failMismatch
              )
          )
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--corpus-root" : value : rest) =
    go options {parserCorpusRoot = value} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--extension" : value : rest) =
    go options {parserCorpusExtensions = parserCorpusExtensions options <> [T.pack value]} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--include-glob" : value : rest) =
    go options {parserCorpusIncludeGlobs = parserCorpusIncludeGlobs options <> [T.pack value]} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--exclude-glob" : value : rest) =
    go options {parserCorpusExcludeGlobs = parserCorpusExcludeGlobs options <> [T.pack value]} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--max-files" : value : rest) = do
    count <- parseIntegerOption "--max-files" value
    go options {parserCorpusMaximumFiles = Just count} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--shuffle" : rest) =
    go options {parserCorpusShuffle = True} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--seed" : value : rest) = do
    seed <- parseIntegerOption "--seed" value
    go options {parserCorpusSeed = seed} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options _ exactBytes noMaximum includeResults failGap failMismatch ("--max-file-mb" : value : rest) = do
    megabytes <- parseNumberOption "--max-file-mb" value
    go options megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes _ noMaximum includeResults failGap failMismatch ("--max-bytes" : value : rest) = do
    exactBytes <- parseIntegerOption "--max-bytes" value
    go options megabytes (Just exactBytes) noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes _ includeResults failGap failMismatch ("--no-max-bytes" : rest) =
    go options megabytes exactBytes True includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--out-dir" : value : rest) =
    go options {parserCorpusOutputDirectory = Just value} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--form" : value : rest)
    | value `elem` ["input", "fullform", "standard"] =
        go options {parserCorpusSourceForm = T.pack value} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
    | otherwise = Left "--form must be input, fullform, or standard"
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--skip-wolfram" : rest) =
    go options {parserCorpusCompareWolfram = False} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--kernel-batch-size" : value : rest) = do
    count <- parseIntegerOption "--kernel-batch-size" value
    go options {parserCorpusKernelBatchSize = count} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--tungsten-workers" : value : rest) = do
    count <- parseIntegerOption "--tungsten-workers" value
    go options {parserCorpusTungstenWorkers = count} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--preview-chars" : value : rest) = do
    count <- parseIntegerOption "--preview-chars" value
    go options {parserCorpusPreviewCharacters = count} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap failMismatch ("--no-write" : rest) =
    go options {parserCorpusWriteOutputs = False} megabytes exactBytes noMaximum includeResults failGap failMismatch rest
  go options megabytes exactBytes noMaximum _ failGap failMismatch ("--include-results" : rest) =
    go options megabytes exactBytes noMaximum True failGap failMismatch rest
  go options megabytes exactBytes noMaximum includeResults _ failMismatch ("--fail-on-tungsten-gap" : rest) =
    go options megabytes exactBytes noMaximum includeResults True failMismatch rest
  go options megabytes exactBytes noMaximum includeResults failGap _ ("--fail-on-mismatch" : rest) =
    go options megabytes exactBytes noMaximum includeResults failGap True rest
  go _ _ _ _ _ _ _ [flag]
    | flag `elem` parserCorpusDiscoveryValueOptions <> parserCorpusCompareValueOptions =
        Left (T.pack flag <> " requires a value")
  go _ _ _ _ _ _ _ (flag : _) = Left ("unknown parser-corpus compare option: " <> T.pack flag)

defaultParserCorpusRoot :: FilePath
defaultParserCorpusRoot = "C:\\TestData\\wolfram\\tungsten-wolfram-parser-corpus"

parserCorpusDiscoveryValueOptions :: [String]
parserCorpusDiscoveryValueOptions =
  ["--corpus-root", "--extension", "--include-glob", "--exclude-glob", "--max-files", "--seed"]

parserCorpusCompareValueOptions :: [String]
parserCorpusCompareValueOptions =
  ["--out-dir", "--max-file-mb", "--max-bytes", "--form", "--kernel-batch-size", "--tungsten-workers", "--preview-chars"]

parseNumberOption :: Read value => Text -> String -> Either Text value
parseNumberOption name value =
  maybe (Left (name <> " requires a number")) Right (readMaybe value)

parseDocumentationIndexArguments :: [String] -> Either Text CliCommand
parseDocumentationIndexArguments [] =
  Right (DocumentationCliCommand (BuildDocumentationIndexCommand Nothing))
parseDocumentationIndexArguments ["--path", path] =
  Right (DocumentationCliCommand (BuildDocumentationIndexCommand (Just path)))
parseDocumentationIndexArguments ["--path"] = Left "--path requires a value"
parseDocumentationIndexArguments _ = Left "usage: docs index [--path PATH]"

parseDocumentationSearchArguments :: Text -> [String] -> Either Text CliCommand
parseDocumentationSearchArguments query = go 10 Nothing False
 where
  go limit indexPath rebuild [] =
    Right (DocumentationCliCommand (SearchDocumentationCommand query limit indexPath rebuild))
  go _ indexPath rebuild ("--limit" : value : rest) = do
    limit <- parseIntegerOption "--limit" value
    go limit indexPath rebuild rest
  go limit Nothing rebuild ("--index-path" : value : rest) =
    go limit (Just value) rebuild rest
  go _ (Just _) _ ("--index-path" : _ : _) = Left "--index-path may be supplied only once"
  go limit indexPath _ ("--rebuild" : rest) = go limit indexPath True rest
  go _ _ _ [flag]
    | flag `elem` ["--limit", "--index-path"] = Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown docs search option: " <> T.pack flag)

parseDocumentationReadArguments :: Text -> [String] -> Either Text CliCommand
parseDocumentationReadArguments identifier = go Nothing False
 where
  go indexPath rebuild [] =
    Right (DocumentationCliCommand (ReadDocumentationCommand identifier indexPath rebuild))
  go Nothing rebuild ("--index-path" : value : rest) = go (Just value) rebuild rest
  go (Just _) _ ("--index-path" : _ : _) = Left "--index-path may be supplied only once"
  go indexPath _ ("--rebuild" : rest) = go indexPath True rest
  go _ _ ["--index-path"] = Left "--index-path requires a value"
  go _ _ (flag : _) = Left ("unknown docs read option: " <> T.pack flag)

parseDocumentationOpenArguments :: Text -> [String] -> Either Text CliCommand
parseDocumentationOpenArguments identifier [] =
  Right (DocumentationCliCommand (OpenDocumentationCommand identifier Nothing))
parseDocumentationOpenArguments identifier ["--index-path", path] =
  Right (DocumentationCliCommand (OpenDocumentationCommand identifier (Just path)))
parseDocumentationOpenArguments _ ["--index-path"] = Left "--index-path requires a value"
parseDocumentationOpenArguments _ _ = Left "usage: docs open IDENTIFIER [--index-path PATH]"

parseInlineBoxComposeArguments :: [String] -> Either Text CliCommand
parseInlineBoxComposeArguments = go "" [] ""
 where
  go prefix boxes suffix [] =
    Right (InlineBoxCliCommand (ComposeInlineBoxCommand (reverse boxes) prefix suffix))
  go _ boxes suffix ("--prefix" : value : rest) = go (T.pack value) boxes suffix rest
  go prefix boxes suffix ("--box-expr" : value : rest) =
    go prefix (T.pack value : boxes) suffix rest
  go prefix boxes _ ("--suffix" : value : rest) = go prefix boxes (T.pack value) rest
  go _ _ _ [flag]
    | flag `elem` ["--prefix", "--box-expr", "--suffix"] = Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown inline-box compose option: " <> T.pack flag)

parseInlineBoxFromCellArguments :: [String] -> Either Text CliCommand
parseInlineBoxFromCellArguments = go Nothing Nothing "" "" 0 False False
 where
  go file selector prefix suffix objectIndex allObjects requireSuccess [] =
    case (file, selector) of
      (Just path, Just cellSelector) ->
        Right
          ( InlineBoxCliCommand
              ( InlineBoxFromCellCommand
                  path cellSelector prefix suffix objectIndex allObjects requireSuccess
              )
          )
      (Nothing, _) -> Left "inline-box from-cell requires --file PATH"
      (_, Nothing) -> Left "inline-box from-cell requires exactly one cell selector"
  go Nothing selector prefix suffix objectIndex allObjects requireSuccess ("--file" : value : rest) =
    go (Just value) selector prefix suffix objectIndex allObjects requireSuccess rest
  go (Just _) _ _ _ _ _ _ ("--file" : _ : _) = Left "inline-box from-cell accepts --file only once"
  go file selector prefix suffix objectIndex allObjects requireSuccess ("--cell-index" : value : rest) = do
    index <- parseIntegerOption "--cell-index" value
    nextSelector <- addCellSelector selector (SelectCellIndex index)
    go file (Just nextSelector) prefix suffix objectIndex allObjects requireSuccess rest
  go file selector prefix suffix objectIndex allObjects requireSuccess ("--cell-path" : value : rest) = do
    path <- parseCellPath (T.pack value)
    nextSelector <- addCellSelector selector (SelectCellPath path)
    go file (Just nextSelector) prefix suffix objectIndex allObjects requireSuccess rest
  go file selector prefix suffix objectIndex allObjects requireSuccess ("--expression-uuid" : value : rest) = do
    nextSelector <- addCellSelector selector (SelectExpressionUuid (T.pack value))
    go file (Just nextSelector) prefix suffix objectIndex allObjects requireSuccess rest
  go file selector prefix suffix objectIndex allObjects requireSuccess ("--cell-id" : value : rest) = do
    identifier <- parseIntegerOption "--cell-id" value
    nextSelector <- addCellSelector selector (SelectCellId identifier)
    go file (Just nextSelector) prefix suffix objectIndex allObjects requireSuccess rest
  go file selector prefix suffix objectIndex allObjects requireSuccess ("--cell-tag" : value : rest) = do
    nextSelector <- addCellSelector selector (SelectCellTag (T.pack value))
    go file (Just nextSelector) prefix suffix objectIndex allObjects requireSuccess rest
  go file selector _ suffix objectIndex allObjects requireSuccess ("--prefix" : value : rest) =
    go file selector (T.pack value) suffix objectIndex allObjects requireSuccess rest
  go file selector prefix _ objectIndex allObjects requireSuccess ("--suffix" : value : rest) =
    go file selector prefix (T.pack value) objectIndex allObjects requireSuccess rest
  go file selector prefix suffix _ allObjects requireSuccess ("--object-index" : value : rest) = do
    index <- parseIntegerOption "--object-index" value
    go file selector prefix suffix index allObjects requireSuccess rest
  go file selector prefix suffix objectIndex _ requireSuccess ("--all-objects" : rest) =
    go file selector prefix suffix objectIndex True requireSuccess rest
  go file selector prefix suffix objectIndex allObjects _ ("--require-success" : rest) =
    go file selector prefix suffix objectIndex allObjects True rest
  go _ _ _ _ _ _ _ [flag]
    | flag
        `elem` [ "--file", "--cell-index", "--cell-path", "--expression-uuid"
               , "--cell-id", "--cell-tag", "--prefix", "--suffix", "--object-index"
               ] = Left (T.pack flag <> " requires a value")
  go _ _ _ _ _ _ _ (flag : _) = Left ("unknown inline-box from-cell option: " <> T.pack flag)

  addCellSelector Nothing value = Right value
  addCellSelector (Just _) _ = Left "inline-box from-cell accepts exactly one cell selector"

parseIntegerOption :: Read value => Text -> String -> Either Text value
parseIntegerOption name value =
  maybe (Left (name <> " requires an integer")) Right (readMaybe value)

parseCellPath :: Text -> Either Text [Int]
parseCellPath source
  | "[" `T.isPrefixOf` stripped && "]" `T.isSuffixOf` stripped = do
      payload <- first jsonErrorMessage (parseJson stripped)
      case payload of
        JsonArray values -> traverse pathComponent values >>= requireNonempty
        _ -> Left "JSON cell paths must be arrays of integers"
  | otherwise =
      traverse parseComponent parts >>= requireNonempty
 where
  stripped = T.strip source
  parts = filter (not . T.null) (map T.strip (T.splitOn "," stripped))
  parseComponent value =
    maybe (Left ("invalid cell path component: " <> value)) Right (readMaybe (T.unpack value))
  pathComponent (JsonNumber value) = parseComponent value
  pathComponent _ = Left "JSON cell paths must be arrays of integers"
  requireNonempty [] = Left "cell paths must contain at least one integer"
  requireNonempty values = Right values

parseNotebookInspectArguments :: [String] -> Either Text CliCommand
parseNotebookInspectArguments ["--file", path] =
  Right (NotebookCliCommand (InspectNotebookCommand path))
parseNotebookInspectArguments [] = Left "notebook inspect requires --file PATH"
parseNotebookInspectArguments _ = Left "usage: notebook inspect --file PATH"

parseKernelArguments :: [String] -> Either Text CliCommand
parseKernelArguments = go Nothing Nothing False False
 where
  go source workingDirectory requireFrontEnd requireSuccess [] = case source of
    Nothing -> Left "kernel eval requires exactly one of --code or --file"
    Just sourceSpec -> Right (KernelCommand sourceSpec workingDirectory requireFrontEnd requireSuccess)
  go Nothing work frontEnd requireSuccess ("--code" : value : rest) =
    go (Just (InlineSource (T.pack value))) work frontEnd requireSuccess rest
  go Nothing work frontEnd requireSuccess ("--file" : value : rest) =
    go (Just (FileSource value)) work frontEnd requireSuccess rest
  go (Just _) _ _ _ ((flag@("--code")) : _ : _) = Left (T.pack flag <> " conflicts with the existing kernel source")
  go (Just _) _ _ _ ((flag@("--file")) : _ : _) = Left (T.pack flag <> " conflicts with the existing kernel source")
  go source Nothing frontEnd requireSuccess ("--working-directory" : value : rest) =
    go source (Just value) frontEnd requireSuccess rest
  go _ (Just _) _ _ ("--working-directory" : _ : _) = Left "--working-directory may be supplied only once"
  go source work _ requireSuccess ("--front-end" : rest) = go source work True requireSuccess rest
  go source work frontEnd _ ("--require-success" : rest) = go source work frontEnd True rest
  go _ _ _ _ [flag]
    | flag `elem` ["--code", "--file", "--working-directory"] = Left (T.pack flag <> " requires a value")
  go _ _ _ _ (flag : _) = Left ("unknown kernel eval option: " <> T.pack flag)

parseRequireSuccess :: [String] -> Either Text Bool
parseRequireSuccess [] = Right False
parseRequireSuccess ["--require-success"] = Right True
parseRequireSuccess _ = Left "only --require-success is accepted for this FrontEnd command"

parseFrontEndRunArguments :: [String] -> Either Text CliCommand
parseFrontEndRunArguments = go Nothing True False
 where
  go (Just code) wrap requireSuccess [] =
    Right (FrontEndCommand (RunFrontEndCommand code wrap requireSuccess))
  go Nothing _ _ [] = Left "frontend run requires --code TEXT"
  go Nothing wrap requireSuccess ("--code" : value : rest) =
    go (Just (T.pack value)) wrap requireSuccess rest
  go (Just _) _ _ ("--code" : _ : _) = Left "frontend run accepts --code only once"
  go code _ requireSuccess ("--no-wrap" : rest) = go code False requireSuccess rest
  go code wrap _ ("--require-success" : rest) = go code wrap True rest
  go _ _ _ ["--code"] = Left "--code requires a value"
  go _ _ _ (flag : _) = Left ("unknown frontend run option: " <> T.pack flag)

parseFrontEndOpenNotebookArguments :: [String] -> Either Text CliCommand
parseFrontEndOpenNotebookArguments = go Nothing False
 where
  go (Just path) requireSuccess [] =
    Right (FrontEndCommand (OpenFrontEndNotebookCommand path requireSuccess))
  go Nothing _ [] = Left "frontend open-notebook requires --file PATH"
  go Nothing requireSuccess ("--file" : value : rest) = go (Just value) requireSuccess rest
  go (Just _) _ ("--file" : _ : _) = Left "frontend open-notebook accepts --file only once"
  go path _ ("--require-success" : rest) = go path True rest
  go _ _ ["--file"] = Left "--file requires a value"
  go _ _ (flag : _) = Left ("unknown frontend open-notebook option: " <> T.pack flag)

parseFrontEndOpenDocumentationArguments :: Text -> [String] -> Either Text CliCommand
parseFrontEndOpenDocumentationArguments identifier = go Nothing False
 where
  go indexPath requireSuccess [] =
    Right
      ( FrontEndCommand
          (OpenFrontEndDocumentationCommand identifier indexPath requireSuccess)
      )
  go Nothing requireSuccess ("--index-path" : value : rest) =
    go (Just value) requireSuccess rest
  go (Just _) _ ("--index-path" : _ : _) = Left "frontend open-doc accepts --index-path only once"
  go indexPath _ ("--require-success" : rest) = go indexPath True rest
  go _ _ ["--index-path"] = Left "--index-path requires a value"
  go _ _ (flag : _) = Left ("unknown frontend open-doc option: " <> T.pack flag)

parseFrontEndTokenArguments :: Text -> [String] -> Either Text CliCommand
parseFrontEndTokenArguments token = go Nothing False
 where
  go notebookPath requireSuccess [] =
    Right (FrontEndCommand (ExecuteFrontEndTokenCommand token notebookPath requireSuccess))
  go Nothing requireSuccess ("--file" : value : rest) = go (Just value) requireSuccess rest
  go (Just _) _ ("--file" : _ : _) = Left "frontend token accepts --file only once"
  go path _ ("--require-success" : rest) = go path True rest
  go _ _ ["--file"] = Left "--file requires a value"
  go _ _ (flag : _) = Left ("unknown frontend token option: " <> T.pack flag)

parseNotebookCreateArguments :: [String] -> Either Text CliCommand
parseNotebookCreateArguments = go Nothing Nothing []
 where
  go file title cells [] = case file of
    Nothing -> Left "notebook create requires --file PATH"
    Just path -> Right (NotebookCliCommand (CreateNotebookCommand path title (reverse cells)))
  go Nothing title cells ("--file" : path : rest) = go (Just path) title cells rest
  go (Just _) _ _ ("--file" : _ : _) = Left "notebook create accepts --file only once"
  go file Nothing cells ("--title" : value : rest) = go file (Just (T.pack value)) cells rest
  go _ (Just _) _ ("--title" : _ : _) = Left "notebook create accepts --title only once"
  go file title cells ("--cell" : specification : rest) = do
    cell <- parseCellSpecification (T.pack specification)
    go file title (cell : cells) rest
  go _ _ _ [flag]
    | flag `elem` ["--file", "--title", "--cell"] = Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown notebook create option: " <> T.pack flag)

parseCellSpecification :: Text -> Either Text (Text, Text)
parseCellSpecification specification =
  let (style, remainder) = T.breakOn ":" specification
   in if T.null style || T.null remainder
        then Left "notebook cells must use STYLE:TEXT"
        else Right (style, T.drop 1 remainder)

parseNotebookPatchArguments :: [String] -> Either Text CliCommand
parseNotebookPatchArguments = go Nothing Nothing Nothing
 where
  go notebookFile specFile outputFile [] = case (notebookFile, specFile) of
    (Just notebookPath, Just specPath) ->
      Right (NotebookCliCommand (PatchNotebookCommand notebookPath specPath outputFile))
    _ -> Left "notebook patch requires --file PATH and --spec PATH"
  go Nothing spec output ("--file" : path : rest) = go (Just path) spec output rest
  go (Just _) _ _ ("--file" : _ : _) = Left "notebook patch accepts --file only once"
  go file Nothing output ("--spec" : path : rest) = go file (Just path) output rest
  go _ (Just _) _ ("--spec" : _ : _) = Left "notebook patch accepts --spec only once"
  go file spec Nothing ("--out" : path : rest) = go file spec (Just path) rest
  go _ _ (Just _) ("--out" : _ : _) = Left "notebook patch accepts --out only once"
  go _ _ _ [flag]
    | flag `elem` ["--file", "--spec", "--out"] = Left (T.pack flag <> " requires a value")
  go _ _ _ (flag : _) = Left ("unknown notebook patch option: " <> T.pack flag)

parseExpressionArguments :: ExpressionCommand -> [String] -> Either Text CliCommand
parseExpressionArguments expressionCommand = go Nothing "input"
 where
  go source form [] = case source of
    Nothing -> Left "expression commands require exactly one of --code or --file"
    Just sourceSpec -> Right (ExpressionCliCommand expressionCommand sourceSpec form)
  go source form ("--code" : value : rest) =
    addSource source (InlineSource (T.pack value)) >>= \updated -> go (Just updated) form rest
  go source form ("--file" : value : rest) =
    addSource source (FileSource value) >>= \updated -> go (Just updated) form rest
  go source _ ("--form" : value : rest) = go source (T.pack value) rest
  go _ _ [flag]
    | flag `elem` ["--code", "--file", "--form"] = Left (T.pack flag <> " requires a value")
  go _ _ (flag : _) = Left ("unknown expression option: " <> T.pack flag)
  addSource Nothing value = Right value
  addSource (Just _) _ = Left "--code and --file are mutually exclusive"

runCli :: [String] -> IO Int
runCli arguments' = case parseCliArguments arguments' of
  Left message -> do
    TextIO.hPutStrLn stderr ("tungsten-hs: " <> message)
    TextIO.hPutStrLn stderr usage
    pure 2
  Right HelpCommand -> TextIO.putStrLn usage *> pure 0
  Right ProtocolCommand -> configureHandles *> serveProtocol *> pure 0
  Right (ReplCommand showBanner) -> configureHandles *> runRepl showBanner
  Right (EnvironmentCommand includeProbe) -> do
    installation <- discoverInstallation
    payload <- if includeProbe
      then do
        evaluation <- evaluateKernelText installation "2+2" Nothing False
        frontEnd <- probeFrontEnd installation
        pure (addEnvironmentProbe evaluation frontEnd (installationPayload installation))
      else pure (installationPayload installation)
    emitJson payload
    pure 0
  Right (KernelCommand sourceSpec workingDirectory requireFrontEnd requireSuccess) -> do
    installation <- discoverInstallation
    result <- case sourceSpec of
      InlineSource source -> evaluateKernelText installation source workingDirectory requireFrontEnd
      FileSource path -> evaluateKernelFile installation path workingDirectory requireFrontEnd
    emitJson (kernelPayload result)
    pure $ if requireSuccess && kernelSuccess result == Just False
      then 1
      else if kernelEvaluationAvailable result then 0 else 2
  Right (FrontEndCommand command) -> runFrontEndCommand command
  Right (ExpressionCliCommand command sourceSpec form) ->
    runExpressionCommand command sourceSpec form
  Right (NotebookCliCommand command) -> runNotebookCommand command
  Right (InlineBoxCliCommand command) -> runInlineBoxCommand command
  Right (DocumentationCliCommand command) -> runDocumentationCommand command
  Right (ParserCorpusCliCommand command) -> runParserCorpusCommand command
  Right (AssistantCliCommand command) -> runAssistantCommand command

configureHandles :: IO ()
configureHandles = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  hSetBuffering stdout LineBuffering

runAssistantCommand :: AssistantCommand -> IO Int
runAssistantCommand = \case
  AskAssistantCommand prompt systemPrompt extraInstructions modelService modelName tools requireSuccess -> do
    installation <- discoverInstallation
    result <-
      askAssistant
        installation prompt systemPrompt extraInstructions modelService modelName
        (if null tools then Nothing else Just tools)
    emitJson (assistantResultPayload result)
    pure (if requireSuccess && not (assistantSuccess result) then 1 else 0)
  AskCellAssistantCommand path selector question insertMode saveNotebook _close extraInstructions modelService modelName requireSuccess -> do
    installation <- discoverInstallation
    result <-
      askAssistantCellWithOptions
        installation path selector question insertMode saveNotebook
        extraInstructions modelService modelName
    case result of
      Left message -> emitAssistantInputError "ask-cell" message
      Right assistantResult -> do
        emitJson (assistantResultPayload assistantResult)
        pure (if requireSuccess && not (assistantSuccess assistantResult) then 1 else 0)
  PrepareInlineAssistantCommand path selector requireSuccess -> do
    installation <- discoverInstallation
    result <- prepareInlineAssistant installation path selector
    case result of
      Left message -> emitAssistantInputError "prepare-inline" message
      Right assistantResult -> do
        emitJson (assistantResultPayload assistantResult)
        pure (if requireSuccess && not (assistantSuccess assistantResult) then 1 else 0)
  CaptureInlineAssistantCommand path selector insertMode saveNotebook requireSuccess -> do
    installation <- discoverInstallation
    result <- captureInlineAssistant installation path selector insertMode saveNotebook
    case result of
      Left message -> emitAssistantInputError "capture-inline" message
      Right assistantResult -> do
        emitJson (assistantResultPayload assistantResult)
        pure (if requireSuccess && not (assistantSuccess assistantResult) then 1 else 0)

emitAssistantInputError :: Text -> Text -> IO Int
emitAssistantInputError command message = do
  emitJson
    ( JsonObject
        ( Map.fromList
            [ ( "assistant"
              , JsonObject
                  ( Map.fromList
                      [ ("error", JsonString message)
                      , ("error_type", JsonString "AssistantInputError")
                      , ("success", JsonBool False)
                      ]
                  )
              )
            , ("assistant_success", JsonBool False)
            , ("command", JsonString command)
            ]
        )
    )
  pure 1

runParserCorpusCommand :: ParserCorpusCommand -> IO Int
runParserCorpusCommand = \case
  DiscoverParserCorpusCommand options sampleCount -> do
    discovery <-
      discoverCorpusFiles
        (parserCorpusRoot options)
        (parserCorpusExtensions options)
        (parserCorpusIncludeGlobs options)
        (parserCorpusExcludeGlobs options)
        (parserCorpusMaximumFiles options)
        (parserCorpusShuffle options)
        (parserCorpusSeed options)
    case discovery of
      Left message -> emitParserCorpusError "discover" message
      Right files -> do
        summary <- summarizeCorpusDiscovery (parserCorpusRoot options) files
        let sample = JsonArray (map corpusFilePayload (take (max 0 sampleCount) files))
            payload = case summary of
              JsonObject values -> JsonObject (Map.insert "sample_files" sample values)
              _ -> summary
        emitJson payload
        pure 0
  CompareParserCorpusCommand options includeResults failGap failMismatch -> do
    installation <- discoverInstallation
    compared <- compareParserCorpus installation options
    case compared of
      Left message -> emitParserCorpusError "compare" message
      Right run -> do
        emitJson (parserCorpusRunPayload includeResults run)
        let gaps = summaryCount "tungsten_gap" (parserCorpusRunSummary run)
            tungstenOnly = summaryCount "tungsten_only_success" (parserCorpusRunSummary run)
        pure
          ( if failMismatch && (gaps > 0 || tungstenOnly > 0)
              then 1
              else if failGap && gaps > 0 then 1 else 0
          )

emitParserCorpusError :: Text -> Text -> IO Int
emitParserCorpusError command message = do
  emitJson
    ( JsonObject
        ( Map.fromList
            [ ("command", JsonString command)
            , ("error", JsonString message)
            , ("error_type", JsonString "ParserCorpusError")
            , ("success", JsonBool False)
            ]
        )
    )
  pure 1

summaryCount :: Text -> JsonValue -> Integer
summaryCount outcome (JsonObject summary) = case Map.lookup "outcomes" summary of
  Just (JsonObject outcomes) -> case Map.lookup outcome outcomes of
    Just (JsonNumber value) -> maybe 0 id (readMaybe (T.unpack value))
    _ -> 0
  _ -> 0
summaryCount _ _ = 0

serveProtocol :: IO ()
serveProtocol = do
  finished <- hIsEOF stdin
  if finished
    then pure ()
    else do
      line <- TextIO.hGetLine stdin
      let response = case decodeRequestLine line of
            Left jsonError -> ProtocolFailure Nothing "" (jsonErrorMessage jsonError)
            Right request -> handleProtocolRequest request
      TextIO.putStr (encodeResponseLine response)
      serveProtocol

runExpressionCommand :: ExpressionCommand -> SourceSpec -> Text -> IO Int
runExpressionCommand command sourceSpec requestedForm = do
  sourceResult <- readSource sourceSpec
  case sourceResult of
    Left message -> emitError command requestedForm "InputError" message Nothing
    Right source -> case parseSource requestedForm source of
      Left message -> emitError command requestedForm "ParseError" message Nothing
      Right (normalizedForm, expression) -> case command of
        ParseCommand -> do
          emitJson (parsePayload normalizedForm source expression)
          pure 0
        EvaluateCommand -> case evaluate expression of
          Left evaluationError ->
            emitError
              command
              normalizedForm
              "EvaluationError"
              (evaluationErrorMessage evaluationError)
              (Just expression)
          Right result -> do
            emitJson (evaluationPayload normalizedForm source expression result)
            pure 0

readSource :: SourceSpec -> IO (Either Text Text)
readSource (InlineSource source) = pure (Right source)
readSource (FileSource path) = do
  result <- try (TextIO.readFile path)
  pure $ first (T.pack . show) (result :: Either IOException Text)

runNotebookCommand :: NotebookCommand -> IO Int
runNotebookCommand = \case
  InspectNotebookCommand path -> do
    sourceResult <- readSource (FileSource path)
    case sourceResult of
      Left message -> emitNotebookError "inspect" "InputError" message
      Right source -> case parseNotebook source of
        Left notebookError ->
          emitNotebookError "inspect" "NotebookError" (notebookErrorMessage notebookError)
        Right document -> emitJson (notebookPayload document) *> pure 0
  CreateNotebookCommand path title cells -> do
    let document = createNotebook title cells
    writeResult <- try (TextIO.writeFile path (renderNotebook document))
    case (writeResult :: Either IOException ()) of
      Left exception -> emitNotebookError "create" "OutputError" (T.pack (show exception))
      Right () -> emitJson (notebookPayload document) *> pure 0
  PatchNotebookCommand notebookPath specPath outputPath -> do
    notebookSource <- readSource (FileSource notebookPath)
    specSource <- readSource (FileSource specPath)
    case (notebookSource, specSource) of
      (Left message, _) -> emitNotebookError "patch" "InputError" message
      (_, Left message) -> emitNotebookError "patch" "InputError" message
      (Right source, Right specText) -> case parseNotebook source of
        Left notebookError ->
          emitNotebookError "patch" "NotebookError" (notebookErrorMessage notebookError)
        Right document -> case parseJson specText of
          Left jsonError -> emitNotebookError "patch" "JsonError" (jsonErrorMessage jsonError)
          Right payload -> case decodeNotebookPatches payload of
            Left message -> emitNotebookError "patch" "PatchError" message
            Right patches -> case applyNotebookPatches patches document of
              Left notebookError ->
                emitNotebookError "patch" "PatchError" (notebookErrorMessage notebookError)
              Right patched -> do
                let destination = maybe notebookPath id outputPath
                writeResult <- try (TextIO.writeFile destination (renderNotebook patched))
                case (writeResult :: Either IOException ()) of
                  Left exception -> emitNotebookError "patch" "OutputError" (T.pack (show exception))
                  Right () -> emitJson (notebookPayload patched) *> pure 0

runInlineBoxCommand :: InlineBoxCommand -> IO Int
runInlineBoxCommand = \case
  ComposeInlineBoxCommand boxExpressions prefix suffix -> do
    emitJson (inlineBoxCompositionPayload (composeInlineBoxPayload boxExpressions prefix suffix))
    pure 0
  InlineBoxFromCellCommand path selector prefix suffix objectIndex allObjects requireSuccess -> do
    sourceResult <- readSource (FileSource path)
    case sourceResult of
      Left message -> emitInlineBoxInputError "InputError" message
      Right source -> case parseNotebook source of
        Left notebookError ->
          emitInlineBoxInputError "NotebookError" (notebookErrorMessage notebookError)
        Right document -> do
          absolutePath <- makeAbsolute path
          case extractInlineBoxesFromNotebookCell
            document selector prefix suffix objectIndex allObjects of
              Left inlineError -> do
                emitJson (inlineBoxErrorPayload inlineError)
                pure (if requireSuccess then 1 else 0)
              Right selection -> do
                emitJson (inlineBoxSelectionPayload absolutePath selection)
                pure 0

emitInlineBoxInputError :: Text -> Text -> IO Int
emitInlineBoxInputError errorType message = do
  emitJson
    ( JsonObject
        ( Map.fromList
            [ ("error", JsonString message)
            , ("error_type", JsonString errorType)
            , ("success", JsonBool False)
            ]
        )
    )
  pure 1

inlineBoxCompositionPayload :: InlineBoxComposition -> JsonValue
inlineBoxCompositionPayload composition =
  JsonObject
    ( Map.fromList
        [ ("box_count", jsonInteger (fromIntegral (length boxes)))
        , ("boxes", JsonArray (map inlineBoxRecordPayload boxes))
        , ("prefix", JsonString (inlineBoxCompositionPrefix composition))
        , ("string_literal", JsonString (inlineBoxCompositionStringLiteral composition))
        , ("string_segments", JsonArray (map wolframStringSegmentPayload (inlineBoxCompositionSegments composition)))
        , ("string_value", JsonString (inlineBoxCompositionStringValue composition))
        , ("success", JsonBool True)
        , ("suffix", JsonString (inlineBoxCompositionSuffix composition))
        ]
    )
 where
  boxes = inlineBoxCompositionBoxes composition

inlineBoxSelectionPayload :: FilePath -> InlineBoxSelection -> JsonValue
inlineBoxSelectionPayload notebookPath selection =
  JsonObject
    ( Map.fromList
        [ ("available_box_count", jsonInteger (fromIntegral (length availableBoxes)))
        , ("available_boxes", JsonArray (map inlineBoxRecordPayload availableBoxes))
        , ("notebook_path", JsonString (T.pack notebookPath))
        , ("object_index", maybe JsonNull (jsonInteger . fromIntegral) (inlineBoxSelectionObjectIndex selection))
        , ("prefix", JsonString (inlineBoxCompositionPrefix composition))
        , ("selected_box_count", jsonInteger (fromIntegral (length selectedBoxes)))
        , ("selected_boxes", JsonArray (map inlineBoxRecordPayload selectedBoxes))
        , ("selection_mode", JsonString (inlineBoxSelectionMode selection))
        , ("source_cell", cellRecordPayload (inlineBoxSelectionSourceCell selection))
        , ("string_literal", JsonString (inlineBoxCompositionStringLiteral composition))
        , ("string_segments", JsonArray (map wolframStringSegmentPayload (inlineBoxCompositionSegments composition)))
        , ("string_value", JsonString (inlineBoxCompositionStringValue composition))
        , ("success", JsonBool True)
        , ("suffix", JsonString (inlineBoxCompositionSuffix composition))
        ]
    )
 where
  availableBoxes = inlineBoxSelectionAvailableBoxes selection
  selectedBoxes = inlineBoxSelectionSelectedBoxes selection
  composition = inlineBoxSelectionComposition selection

inlineBoxErrorPayload :: InlineBoxError -> JsonValue
inlineBoxErrorPayload inlineError =
  JsonObject
    ( addAvailableCount
        ( addSourceCell
            ( Map.fromList
                [ ("error", JsonString (inlineBoxErrorMessage inlineError))
                , ("error_type", JsonString (inlineBoxErrorType inlineError))
                , ("success", JsonBool False)
                ]
            )
        )
    )
 where
  addSourceCell = case inlineBoxErrorSourceCell inlineError of
    Nothing -> id
    Just record -> Map.insert "source_cell" (cellRecordPayload record)
  addAvailableCount = case inlineBoxErrorAvailableBoxCount inlineError of
    Nothing -> id
    Just count -> Map.insert "available_box_count" (jsonInteger (fromIntegral count))

inlineBoxRecordPayload :: InlineBoxRecord -> JsonValue
inlineBoxRecordPayload record =
  JsonObject
    ( Map.fromList
        [ ("box_expression", JsonString (inlineBoxRecordExpression record))
        , ("head", maybe JsonNull JsonString (inlineBoxRecordHead record))
        , ("index", jsonInteger (fromIntegral (inlineBoxRecordIndex record)))
        , ("inline_box_escape", JsonString (inlineBoxRecordEscape record))
        , ("string_literal", JsonString (inlineBoxRecordStringLiteral record))
        ]
    )

wolframStringSegmentPayload :: WolframStringSegment -> JsonValue
wolframStringSegmentPayload = \case
  StringTextSegment value ->
    JsonObject
      ( Map.fromList
          [ ("kind", JsonString "text")
          , ("text", JsonString value)
          ]
      )
  StringInlineBoxSegment boxExpression source ->
    JsonObject
      ( Map.fromList
          [ ("box_expression", JsonString boxExpression)
          , ("inline_box_escape", JsonString source)
          , ("kind", JsonString "inline_box")
          ]
      )

runDocumentationCommand :: DocumentationCommand -> IO Int
runDocumentationCommand command = do
  installation <- discoverInstallation
  case command of
    BuildDocumentationIndexCommand path -> do
      result <- buildDocumentationIndex installation path
      case result of
        Left documentationError -> emitDocumentationError "index" documentationError
        Right indexPath -> do
          emitJson
            ( JsonObject
                (Map.singleton "index_path" (JsonString (T.pack indexPath)))
            )
          pure 0
    SearchDocumentationCommand query limit indexPath rebuild -> do
      result <- searchDocumentation installation query indexPath limit rebuild
      case result of
        Left documentationError -> emitDocumentationError "search" documentationError
        Right hits -> do
          emitJson
            ( JsonObject
                (Map.singleton "hits" (JsonArray (map documentationHitPayload hits)))
            )
          pure 0
    ReadDocumentationCommand identifier indexPath rebuild -> do
      result <- readDocumentation installation identifier indexPath rebuild
      case result of
        Left documentationError -> emitDocumentationError "read" documentationError
        Right record -> emitJson (documentationRecordPayload record) *> pure 0
    OpenDocumentationCommand identifier indexPath -> do
      resolved <- resolveDocumentationIdentifier installation identifier indexPath
      case resolved of
        Left documentationError -> emitDocumentationError "open" documentationError
        Right paclet -> do
          result <- openDocumentation installation paclet
          emitJson (kernelPayload result)
          pure 0

emitDocumentationError :: Text -> DocumentationError -> IO Int
emitDocumentationError command documentationError = do
  emitJson
    ( JsonObject
        ( Map.fromList
            [ ("command", JsonString command)
            , ("error", JsonString (documentationErrorMessage documentationError))
            , ("error_type", JsonString "DocumentationError")
            , ("success", JsonBool False)
            ]
        )
    )
  pure 1

documentationRecordPayload :: DocumentationRecord -> JsonValue
documentationRecordPayload record =
  JsonObject
    ( Map.fromList
        [ ("category", JsonString (documentationCategory record))
        , ("kind", JsonString (documentationKind record))
        , ("paclet", JsonString (documentationPaclet record))
        , ("path", JsonString (T.pack (documentationPath record)))
        , ("preview", JsonString (documentationPreview record))
        , ("text", JsonString (documentationText record))
        , ("title", JsonString (documentationTitle record))
        ]
    )

documentationHitPayload :: DocumentationHit -> JsonValue
documentationHitPayload hit =
  JsonObject
    ( Map.fromList
        [ ("category", JsonString (documentationHitCategory hit))
        , ("kind", JsonString (documentationHitKind hit))
        , ("paclet", JsonString (documentationHitPaclet hit))
        , ("path", JsonString (T.pack (documentationHitPath hit)))
        , ("preview", JsonString (documentationHitPreview hit))
        , ("score", JsonNumber (documentationHitScore hit))
        , ("snippet", JsonString (documentationHitSnippet hit))
        , ("title", JsonString (documentationHitTitle hit))
        ]
    )

decodeNotebookPatches :: JsonValue -> Either Text [NotebookPatch]
decodeNotebookPatches (JsonObject specification) = case Map.lookup "operations" specification of
  Nothing -> Right []
  Just (JsonArray operations) -> traverse decodeNotebookPatch operations
  Just _ -> Left "patch specification operations must be an array"
decodeNotebookPatches _ = Left "a patch specification must be a JSON object"

decodeNotebookPatch :: JsonValue -> Either Text NotebookPatch
decodeNotebookPatch (JsonObject operation) = do
  operationName <- requiredString "op" operation
  case T.strip operationName of
    "append_cell" ->
      AppendCell
        <$> optionalPath "container_path" operation
        <*> patchCell (Just "Text") operation
    "insert_cell" ->
      InsertCell
        <$> optionalPath "container_path" operation
        <*> requiredInt "index" operation
        <*> patchCell (Just "Text") operation
    "replace_cell" ->
      ReplaceCell
        <$> requiredPath "path" operation
        <*> optionalStringField "style" operation
        <*> patchContent operation
    "delete_item" -> DeleteItem <$> requiredPath "path" operation
    "set_option" -> do
      name <- requiredString "name" operation
      valueSource <- requiredString "value_expr" operation
      value <- first parseErrorMessage (parseInputForm valueSource)
      pure (SetNotebookOption name value)
    unsupported -> Left ("unsupported patch operation: " <> unsupported)
decodeNotebookPatch _ = Left "patch operations must be JSON objects"

patchCell :: Maybe Text -> Map.Map Text JsonValue -> Either Text NotebookCell
patchCell defaultStyle operation =
  NotebookCell
    <$> patchContent operation
    <*> ((<|> defaultStyle) <$> optionalStringField "style" operation)
    <*> pure []

patchContent :: Map.Map Text JsonValue -> Either Text Expr
patchContent operation = do
  contentSource <- optionalStringField "content_expr" operation
  text <- optionalStringField "text" operation
  case contentSource of
    Just source -> first parseErrorMessage (parseInputForm source)
    Nothing -> Right (String (maybe "" id text))

requiredString :: Text -> Map.Map Text JsonValue -> Either Text Text
requiredString key values = case Map.lookup key values of
  Just (JsonString value) -> Right value
  Nothing -> Left ("missing patch field: " <> key)
  Just _ -> Left ("patch field must be a string: " <> key)

optionalStringField :: Text -> Map.Map Text JsonValue -> Either Text (Maybe Text)
optionalStringField key values = case Map.lookup key values of
  Nothing -> Right Nothing
  Just JsonNull -> Right Nothing
  Just (JsonString value) -> Right (Just value)
  Just _ -> Left ("patch field must be a string: " <> key)

requiredInt :: Text -> Map.Map Text JsonValue -> Either Text Int
requiredInt key values = case Map.lookup key values of
  Just (JsonNumber source) ->
    maybe (Left ("patch field must be an integer: " <> key)) Right (readMaybe (T.unpack source))
  Nothing -> Left ("missing patch field: " <> key)
  Just _ -> Left ("patch field must be an integer: " <> key)

optionalPath :: Text -> Map.Map Text JsonValue -> Either Text (Maybe [Int])
optionalPath key values = case Map.lookup key values of
  Nothing -> Right Nothing
  Just JsonNull -> Right Nothing
  Just value -> Just <$> pathValue key value

requiredPath :: Text -> Map.Map Text JsonValue -> Either Text [Int]
requiredPath key values = case Map.lookup key values of
  Nothing -> Left ("missing patch field: " <> key)
  Just value -> pathValue key value

pathValue :: Text -> JsonValue -> Either Text [Int]
pathValue key (JsonArray values) = traverse component values
 where
  component (JsonNumber source) =
    maybe (Left ("patch path must contain integers: " <> key)) Right (readMaybe (T.unpack source))
  component _ = Left ("patch path must contain integers: " <> key)
pathValue key _ = Left ("patch path must be an integer array: " <> key)

notebookPayload :: NotebookDocument -> JsonValue
notebookPayload document =
  JsonObject
    ( Map.fromList
        [ ("cell_count", jsonInteger (fromIntegral (cellCount document)))
        , ("cells", JsonArray (map cellRecordPayload (flattenCells document)))
        , ("group_count", jsonInteger (fromIntegral (groupCount document)))
        , ("options", JsonArray (map (JsonString . fullForm) (notebookOptions document)))
        , ("title", maybe JsonNull JsonString (notebookTitle document))
        ]
    )

cellRecordPayload :: CellRecord -> JsonValue
cellRecordPayload record =
  JsonObject
    ( Map.fromList
        [ ("cell_id", maybe JsonNull jsonInteger (cellId cell))
        , ("cell_tags", JsonArray (map JsonString (cellTags cell)))
        , ("depth", jsonInteger (fromIntegral (max 0 (length (cellRecordPath record) - 1))))
        , ("expression_uuid", maybe JsonNull JsonString (expressionUuid cell))
        , ("index", jsonInteger (fromIntegral (cellRecordIndex record)))
        , ("kind", JsonString "cell")
        , ("options", JsonArray (map (JsonString . fullForm) (cellOptions cell)))
        , ("path", JsonArray (map (jsonInteger . fromIntegral) (cellRecordPath record)))
        , ("preview", JsonString (cellRecordPreview record))
        , ("style", maybe JsonNull JsonString (cellRecordStyle record))
        ]
    )
 where
  cell = cellRecordCell record

emitNotebookError :: Text -> Text -> Text -> IO Int
emitNotebookError command errorType message = do
  emitJson
    ( JsonObject
        ( Map.fromList
            [ ("command", JsonString command)
            , ("error", JsonString message)
            , ("error_type", JsonString errorType)
            , ("success", JsonBool False)
            ]
        )
    )
  pure 1

jsonInteger :: Integer -> JsonValue
jsonInteger = JsonNumber . T.pack . show

installationPayload :: WolframInstallation -> JsonValue
installationPayload installation =
  JsonObject
    ( Map.fromList
        [ ("available_installations", JsonArray (map installationSummaryPayload (installationAvailable installation)))
        , ("bundled_python_client", jsonMaybeString (installationBundledPythonClient installation))
        , ("default_index_path", JsonString (T.pack (installationDefaultIndexPath installation)))
        , ("docs_roots", JsonArray (map (JsonString . T.pack) (installationDocsRoots installation)))
        , ("frontend_executable", jsonMaybeString (installationFrontendExecutable installation))
        , ("install_dir", jsonMaybeString (installationInstallDir installation))
        , ("kernel_cli", jsonMaybeString (installationKernelCli installation))
        , ("kernel_executable", jsonMaybeString (installationKernelExecutable installation))
        , ("mathpass", jsonMaybeString (installationMathpass installation))
        , ("mathpass_candidates", JsonArray (map (JsonString . T.pack) (installationMathpassCandidates installation)))
        , ("product", JsonString (installationProduct installation))
        , ("product_family", JsonString (installationProductFamily installation))
        , ("selection_reason", maybe JsonNull JsonString (installationSelectionReason installation))
        , ("system_base", jsonMaybeString (installationSystemBase installation))
        , ("user_base", jsonMaybeString (installationUserBase installation))
        , ("version", maybe JsonNull JsonString (installationVersion installation))
        , ("wolframscript", jsonMaybeString (installationWolframscript installation))
        ]
    )

installationSummaryPayload :: InstallationSummary -> JsonValue
installationSummaryPayload summary =
  JsonObject
    ( Map.fromList
        [ ("install_dir", JsonString (T.pack (summaryInstallDir summary)))
        , ("kernel_cli", jsonMaybeString (summaryKernelCli summary))
        , ("product", JsonString (summaryProduct summary))
        , ("product_family", JsonString (summaryProductFamily summary))
        , ("version", maybe JsonNull JsonString (summaryVersion summary))
        , ("wolframscript", jsonMaybeString (summaryWolframscript summary))
        ]
    )

jsonMaybeString :: Maybe FilePath -> JsonValue
jsonMaybeString = maybe JsonNull (JsonString . T.pack)

kernelPayload :: KernelEvaluationResult -> JsonValue
kernelPayload = kernelEvaluationPayload

addEnvironmentProbe :: KernelEvaluationResult -> KernelEvaluationResult -> JsonValue -> JsonValue
addEnvironmentProbe evaluation frontEnd (JsonObject values) =
  JsonObject
    ( Map.insert
        "probe"
        ( JsonObject
            ( Map.fromList
                [ ("evaluation", kernelPayload evaluation)
                , ("front_end", kernelPayload frontEnd)
                ]
            )
        )
        values
    )
addEnvironmentProbe _ _ payload = payload

runFrontEndCommand :: FrontEndCommand -> IO Int
runFrontEndCommand command = do
  installation <- discoverInstallation
  outcome <- case command of
    ProbeFrontEndCommand required -> Right . (,required) <$> probeFrontEnd installation
    RunFrontEndCommand code wrap required -> Right . (,required) <$> runFrontEnd installation code wrap
    OpenFrontEndNotebookCommand path required -> Right . (,required) <$> openNotebook installation path
    OpenFrontEndDocumentationCommand identifier indexPath required -> do
      resolved <- resolveDocumentationIdentifier installation identifier indexPath
      case resolved of
        Left documentationError -> pure (Left documentationError)
        Right paclet -> Right . (,required) <$> openDocumentation installation paclet
    ExecuteFrontEndTokenCommand token notebookPath required ->
      Right . (,required) <$> executeFrontEndToken installation token notebookPath
  case outcome of
    Left documentationError -> emitDocumentationError "frontend open-doc" documentationError
    Right (result, requireSuccess) -> do
      emitJson (kernelPayload result)
      pure (kernelCommandExit requireSuccess result)

kernelCommandExit :: Bool -> KernelEvaluationResult -> Int
kernelCommandExit requireSuccess result
  | requireSuccess && kernelSuccess result == Just False = 1
  | kernelEvaluationAvailable result = 0
  | otherwise = 2

parseSource :: Text -> Text -> Either Text (Text, Expr)
parseSource requestedForm source = case T.toLower (T.strip requestedForm) of
  "input" -> parseWith "input" parseInputForm
  "inputform" -> parseWith "input" parseInputForm
  "full" -> parseWith "fullform" parseFullForm
  "fullform" -> parseWith "fullform" parseFullForm
  other -> Left ("unsupported expression form: " <> other)
 where
  parseWith normalized parser = (normalized,) <$> first parseErrorMessage (parser source)

parsePayload :: Text -> Text -> Expr -> JsonValue
parsePayload form source expression =
  JsonObject
    ( Map.fromList
        [ ("command", JsonString "parse")
        , ("depth", JsonNumber (T.pack (show (expressionDepth expression))))
        , ("form", JsonString form)
        , ("full_form", JsonString (fullForm expression))
        , ("length", JsonNumber (T.pack (show (length (arguments expression)))))
        , ("source", JsonString source)
        , ("success", JsonBool True)
        , ("tree", exprToJson expression)
        ]
    )

evaluationPayload :: Text -> Text -> Expr -> Expr -> JsonValue
evaluationPayload form source parsed result =
  JsonObject
    ( Map.fromList
        [ ("command", JsonString "evaluate")
        , ("form", JsonString form)
        , ("parsed_full_form", JsonString (fullForm parsed))
        , ("parsed_tree", exprToJson parsed)
        , ("result", expressionPayload result)
        , ("source", JsonString source)
        , ("success", JsonBool True)
        ]
    )

expressionPayload :: Expr -> JsonValue
expressionPayload expression =
  JsonObject
    ( Map.fromList
        [ ("depth", JsonNumber (T.pack (show (expressionDepth expression))))
        , ("full_form", JsonString (fullForm expression))
        , ("length", JsonNumber (T.pack (show (length (arguments expression)))))
        , ("tree", exprToJson expression)
        ]
    )

emitError :: ExpressionCommand -> Text -> Text -> Text -> Maybe Expr -> IO Int
emitError command form errorType message parsed = do
  emitJson
    ( JsonObject
        ( withParsed
            ( Map.fromList
                [ ("command", JsonString (commandName command))
                , ("error", JsonString message)
                , ("error_type", JsonString errorType)
                , ("form", JsonString form)
                , ("success", JsonBool False)
                ]
            )
        )
    )
  pure 1
 where
  withParsed = case parsed of
    Nothing -> id
    Just expression ->
      Map.insert "parsed_full_form" (JsonString (fullForm expression))
        . Map.insert "parsed_tree" (exprToJson expression)

emitJson :: JsonValue -> IO ()
emitJson = TextIO.putStrLn . encodeJson

commandName :: ExpressionCommand -> Text
commandName ParseCommand = "parse"
commandName EvaluateCommand = "evaluate"

expressionDepth :: Expr -> Int
expressionDepth (Call (Symbol "Association") entries)
  | Just values <- traverse associationValue entries =
      case values of
        [] -> 1
        _ -> 1 + maximum (map expressionDepth values)
 where
  associationValue (Call (Symbol ruleHead) [_, value])
    | ruleHead `elem` ["Rule", "RuleDelayed"] = Just value
  associationValue _ = Nothing
expressionDepth expression = case arguments expression of
  [] -> 1
  values -> 1 + maximum (map expressionDepth values)

usage :: Text
usage =
  T.unlines
    [ "Usage:"
    , "  tungsten-hs protocol"
    , "  tungsten-hs repl [--no-banner]"
    , "  tungsten-hs env show"
    , "  tungsten-hs kernel eval (--code TEXT | --file PATH) [--working-directory PATH] [--front-end] [--require-success]"
    , "  tungsten-hs frontend probe [--require-success]"
    , "  tungsten-hs frontend run --code TEXT [--no-wrap] [--require-success]"
    , "  tungsten-hs frontend open-notebook --file PATH [--require-success]"
    , "  tungsten-hs frontend open-doc IDENTIFIER [--index-path PATH] [--require-success]"
    , "  tungsten-hs frontend token TOKEN [--file PATH] [--require-success]"
    , "  tungsten-hs expr parse (--code TEXT | --file PATH) [--form input|fullform]"
    , "  tungsten-hs expr evaluate (--code TEXT | --file PATH) [--form input|fullform]"
    , "  tungsten-hs parser-corpus discover [DISCOVERY OPTIONS] [--sample N]"
    , "  tungsten-hs parser-corpus compare [DISCOVERY OPTIONS] [--skip-wolfram] [--no-write] [--include-results]"
    , "    DISCOVERY OPTIONS: --corpus-root PATH [--extension EXT ...] [--include-glob GLOB ...] [--exclude-glob GLOB ...] [--max-files N] [--shuffle] [--seed N]"
    , "  tungsten-hs assistant ask --prompt TEXT [--system-prompt TEXT] [--extra-instructions TEXT] [--tool NAME ...] [--model-service NAME] [--model-name NAME] [--require-success]"
    , "  tungsten-hs assistant ask-cell --file PATH SELECTOR --question TEXT [--insert-wolfram-code-below | --insert-all-wolfram-code-below] [--save] [--close-assistant-notebook] [--require-success]"
    , "  tungsten-hs assistant prepare-inline --file PATH SELECTOR [--require-success]"
    , "  tungsten-hs assistant capture-inline --file PATH SELECTOR [--insert-wolfram-code-below | --insert-all-wolfram-code-below] [--save] [--require-success]"
    , "  tungsten-hs notebook inspect --file PATH"
    , "  tungsten-hs notebook create --file PATH [--title TEXT] [--cell STYLE:TEXT ...]"
    , "  tungsten-hs notebook patch --file PATH --spec PATH [--out PATH]"
    , "  tungsten-hs inline-box compose [--prefix TEXT] [--box-expr EXPR ...] [--suffix TEXT]"
    , "  tungsten-hs inline-box from-cell --file PATH SELECTOR [--prefix TEXT] [--suffix TEXT] [--object-index N | --all-objects] [--require-success]"
    , "    SELECTOR: --cell-index N | --cell-path PATH | --expression-uuid UUID | --cell-id N | --cell-tag TAG"
    , "  tungsten-hs docs index [--path PATH]"
    , "  tungsten-hs docs search QUERY [--limit N] [--index-path PATH] [--rebuild]"
    , "  tungsten-hs docs read IDENTIFIER [--index-path PATH] [--rebuild]"
    , "  tungsten-hs docs open IDENTIFIER [--index-path PATH]"
    , ""
    , "With no arguments, tungsten-hs serves the JSON-lines protocol for backward compatibility."
    ]
