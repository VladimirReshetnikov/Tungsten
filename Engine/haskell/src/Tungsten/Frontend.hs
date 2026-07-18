{-# LANGUAGE OverloadedStrings #-}

-- | Narrow, typed FrontEnd operations over the structured kernel runner.
module Tungsten.Frontend
  ( probeFrontEnd
  , runFrontEnd
  , openNotebook
  , openDocumentation
  , executeFrontEndToken
  , frontEndProbeCode
  , openNotebookCode
  , openDocumentationCode
  , frontEndTokenCode
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (makeAbsolute)
import Tungsten.Discovery
import Tungsten.Expression (Expr (String), fullForm)
import Tungsten.Kernel

probeFrontEnd :: WolframInstallation -> IO KernelEvaluationResult
probeFrontEnd installation =
  evaluateKernelText installation frontEndProbeCode Nothing False

runFrontEnd :: WolframInstallation -> Text -> Bool -> IO KernelEvaluationResult
runFrontEnd installation code wrapUsingFrontEnd =
  evaluateKernelText installation code Nothing wrapUsingFrontEnd

openNotebook :: WolframInstallation -> FilePath -> IO KernelEvaluationResult
openNotebook installation path = do
  absolutePath <- makeAbsolute path
  evaluateKernelText installation (openNotebookCode absolutePath) Nothing True

openDocumentation :: WolframInstallation -> Text -> IO KernelEvaluationResult
openDocumentation installation identifier =
  evaluateKernelText installation (openDocumentationCode identifier) Nothing True

executeFrontEndToken
  :: WolframInstallation
  -> Text
  -> Maybe FilePath
  -> IO KernelEvaluationResult
executeFrontEndToken installation token notebookPath = do
  absolutePath <- traverse makeAbsolute notebookPath
  evaluateKernelText installation (frontEndTokenCode token absolutePath) Nothing True

frontEndProbeCode :: Text
frontEndProbeCode =
  "nb = UsingFrontEnd[CreateDocument[Notebook[{Cell[\"Tungsten probe\", \"Text\"]}, Visible -> False]]];"
    <> " head = Head[nb];"
    <> " UsingFrontEnd[NotebookClose[nb]];"
    <> " head"

openNotebookCode :: FilePath -> Text
openNotebookCode path = "NotebookOpen[" <> stringLiteral (T.pack (normalizePath path)) <> "]"

openDocumentationCode :: Text -> Text
openDocumentationCode identifier = "NotebookLocate[" <> stringLiteral identifier <> "]"

frontEndTokenCode :: Text -> Maybe FilePath -> Text
frontEndTokenCode token Nothing =
  "FrontEndTokenExecute[" <> stringLiteral token <> "]"
frontEndTokenCode token (Just notebookPath) =
  "nb = NotebookOpen["
    <> stringLiteral (T.pack (normalizePath notebookPath))
    <> "]; FrontEndTokenExecute[nb, "
    <> stringLiteral token
    <> "]; nb"

stringLiteral :: Text -> Text
stringLiteral = fullForm . String

normalizePath :: FilePath -> FilePath
normalizePath = map (\character -> if character == '\\' then '/' else character)
