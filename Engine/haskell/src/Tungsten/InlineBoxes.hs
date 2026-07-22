{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Composition and notebook-cell extraction for Wolfram inline boxes.
module Tungsten.InlineBoxes
  ( CellSelector (..)
  , InlineBoxRecord (..)
  , InlineBoxComposition (..)
  , InlineBoxSelection (..)
  , InlineBoxError (..)
  , composeInlineBoxPayload
  , extractBoxExpressions
  , extractInlineBoxesFromNotebookCell
  , resolveNotebookCell
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Expression
import Tungsten.Notebook
import Tungsten.Parser (parseInputForm)
import Tungsten.WolframString

data CellSelector
  = SelectCellIndex !Int
  | SelectCellPath ![Int]
  | SelectExpressionUuid !Text
  | SelectCellId !Integer
  | SelectCellTag !Text
  deriving (Eq, Show)

data InlineBoxRecord = InlineBoxRecord
  { inlineBoxRecordIndex :: !Int
  , inlineBoxRecordHead :: !(Maybe Text)
  , inlineBoxRecordExpression :: !Text
  , inlineBoxRecordEscape :: !Text
  , inlineBoxRecordStringLiteral :: !Text
  }
  deriving (Eq, Show)

data InlineBoxComposition = InlineBoxComposition
  { inlineBoxCompositionPrefix :: !Text
  , inlineBoxCompositionSuffix :: !Text
  , inlineBoxCompositionBoxes :: ![InlineBoxRecord]
  , inlineBoxCompositionStringValue :: !Text
  , inlineBoxCompositionStringLiteral :: !Text
  , inlineBoxCompositionSegments :: ![WolframStringSegment]
  }
  deriving (Eq, Show)

data InlineBoxSelection = InlineBoxSelection
  { inlineBoxSelectionSourceCell :: !CellRecord
  , inlineBoxSelectionMode :: !Text
  , inlineBoxSelectionObjectIndex :: !(Maybe Int)
  , inlineBoxSelectionAvailableBoxes :: ![InlineBoxRecord]
  , inlineBoxSelectionSelectedBoxes :: ![InlineBoxRecord]
  , inlineBoxSelectionComposition :: !InlineBoxComposition
  }
  deriving (Eq, Show)

data InlineBoxError = InlineBoxError
  { inlineBoxErrorType :: !Text
  , inlineBoxErrorMessage :: !Text
  , inlineBoxErrorSourceCell :: !(Maybe CellRecord)
  , inlineBoxErrorAvailableBoxCount :: !(Maybe Int)
  }
  deriving (Eq, Show)

composeInlineBoxPayload :: [Text] -> Text -> Text -> InlineBoxComposition
composeInlineBoxPayload boxExpressions prefix suffix =
  InlineBoxComposition
    { inlineBoxCompositionPrefix = prefix
    , inlineBoxCompositionSuffix = suffix
    , inlineBoxCompositionBoxes = zipWith boxRecord [0 ..] boxExpressions
    , inlineBoxCompositionStringValue = stringValue
    , inlineBoxCompositionStringLiteral = wlString stringValue
    , inlineBoxCompositionSegments = splitInlineBoxes stringValue
    }
 where
  stringValue = composeInlineBoxString prefix boxExpressions suffix

-- | Find box expressions embedded structurally in notebook cell content.
-- Results are stripped and deduplicated while preserving their first-seen
-- order, matching the Python engine's notebook helper.
extractBoxExpressions :: Expr -> [Text]
extractBoxExpressions = stableUnique . collect
 where
  collect = \case
    String value ->
      [ stringSegmentBoxExpression segment
      | segment@StringInlineBoxSegment {} <- inlineBoxSegments value
      ]
    Call (Symbol "BoxData") (value : _) -> [fullForm value]
    expression@(Call (Symbol headName) _)
      | "Box" `T.isSuffixOf` headName && headName /= "BoxData" -> [fullForm expression]
    Call (Symbol headName) values
      | headName `elem` ["TextData", "Row", "List"] -> concatMap collect values
    Call (Symbol "Cell") (value : _) -> collect value
    _ -> []

  stableUnique values = reverse (snd (foldl add (Set.empty, []) values))
  add (seen, output) value =
    let normalized = T.strip value
     in if T.null normalized || Set.member normalized seen
          then (seen, output)
          else (Set.insert normalized seen, normalized : output)

extractInlineBoxesFromNotebookCell
  :: NotebookDocument
  -> CellSelector
  -> Text
  -> Text
  -> Int
  -> Bool
  -> Either InlineBoxError InlineBoxSelection
extractInlineBoxesFromNotebookCell document selector prefix suffix objectIndex allObjects = do
  record <- resolveNotebookCell document selector
  let boxExpressions = extractBoxExpressions (cellContent (cellRecordCell record))
      availableBoxes = zipWith boxRecord [0 ..] boxExpressions
  if null boxExpressions
    then
      Left
        InlineBoxError
          { inlineBoxErrorType = "NoInlineBoxObjectsFound"
          , inlineBoxErrorMessage =
              "The selected notebook cell did not contain any inline box objects or box-bearing string escapes."
          , inlineBoxErrorSourceCell = Just record
          , inlineBoxErrorAvailableBoxCount = Nothing
          }
    else do
      (mode, selectedIndex, selectedExpressions, selectedBoxes) <-
        if allObjects
          then Right ("all", Nothing, boxExpressions, availableBoxes)
          else selectOne record boxExpressions availableBoxes objectIndex
      pure
        InlineBoxSelection
          { inlineBoxSelectionSourceCell = record
          , inlineBoxSelectionMode = mode
          , inlineBoxSelectionObjectIndex = selectedIndex
          , inlineBoxSelectionAvailableBoxes = availableBoxes
          , inlineBoxSelectionSelectedBoxes = selectedBoxes
          , inlineBoxSelectionComposition =
              composeInlineBoxPayload selectedExpressions prefix suffix
          }

selectOne
  :: CellRecord
  -> [Text]
  -> [InlineBoxRecord]
  -> Int
  -> Either InlineBoxError (Text, Maybe Int, [Text], [InlineBoxRecord])
selectOne record expressions boxes index
  | index < 0 || index >= length expressions =
      Left
        InlineBoxError
          { inlineBoxErrorType = "InlineBoxObjectIndexOutOfRange"
          , inlineBoxErrorMessage =
              "Requested object index "
                <> T.pack (show index)
                <> ", but the selected cell only contains "
                <> T.pack (show (length expressions))
                <> " inline box object(s)."
          , inlineBoxErrorSourceCell = Just record
          , inlineBoxErrorAvailableBoxCount = Just (length expressions)
          }
  | otherwise =
      Right
        ( "index"
        , Just index
        , [expressions !! index]
        , [boxes !! index]
        )

resolveNotebookCell :: NotebookDocument -> CellSelector -> Either InlineBoxError CellRecord
resolveNotebookCell document selector = case selector of
  SelectCellIndex index -> uniqueMatch [record | record <- rows, cellRecordIndex record == index]
  SelectCellPath path -> uniqueMatch [record | record <- rows, cellRecordPath record == path]
  SelectExpressionUuid uuid ->
    uniqueMatch [record | record <- rows, expressionUuid (cellRecordCell record) == Just uuid]
  SelectCellId identifier ->
    uniqueMatch [record | record <- rows, cellId (cellRecordCell record) == Just identifier]
  SelectCellTag tag ->
    uniqueMatch [record | record <- rows, tag `elem` cellTags (cellRecordCell record)]
 where
  rows = flattenCells document
  uniqueMatch [record] = Right record
  uniqueMatch [] =
    Left
      InlineBoxError
        { inlineBoxErrorType = "CellSelectorNotFound"
        , inlineBoxErrorMessage =
            "The requested notebook cell selector did not match any cell in the notebook file."
        , inlineBoxErrorSourceCell = Nothing
        , inlineBoxErrorAvailableBoxCount = Nothing
        }
  uniqueMatch _ =
    Left
      InlineBoxError
        { inlineBoxErrorType = "CellSelectorAmbiguous"
        , inlineBoxErrorMessage =
            "The requested notebook cell selector matched more than one cell in the notebook file."
        , inlineBoxErrorSourceCell = Nothing
        , inlineBoxErrorAvailableBoxCount = Nothing
        }

boxRecord :: Int -> Text -> InlineBoxRecord
boxRecord index boxExpression =
  InlineBoxRecord
    { inlineBoxRecordIndex = index
    , inlineBoxRecordHead = boxHead boxExpression
    , inlineBoxRecordExpression = boxExpression
    , inlineBoxRecordEscape = escape
    , inlineBoxRecordStringLiteral = wlString escape
    }
 where
  escape = inlineBoxEscape boxExpression

boxHead :: Text -> Maybe Text
boxHead source = case parseInputForm source of
  Right (Call (Symbol headName) _) -> Just headName
  _ -> Nothing
