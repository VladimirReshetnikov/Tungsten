{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Kernel-free structural Wolfram notebook documents.
module Tungsten.Notebook
  ( NotebookError (..)
  , NotebookDocument (..)
  , NotebookItem (..)
  , NotebookCell (..)
  , CellRecord (..)
  , parseNotebook
  , notebookFromExpr
  , notebookToExpr
  , renderNotebook
  , createNotebook
  , flattenCells
  , cellCount
  , groupCount
  , notebookTitle
  , cellId
  , expressionUuid
  , cellTags
  ) where

import Data.Bifunctor (first)
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Expression
import Tungsten.Parser (parseErrorMessage, parseInputForm)

newtype NotebookError = NotebookError {notebookErrorMessage :: Text}
  deriving (Eq, Show)

data NotebookDocument = NotebookDocument
  { notebookItems :: ![NotebookItem]
  , notebookOptions :: ![Expr]
  }
  deriving (Eq, Show)

data NotebookItem
  = CellItem !NotebookCell
  | CellGroup ![NotebookItem] !(Maybe Expr) ![Expr]
  | RawItem !Expr
  deriving (Eq, Show)

data NotebookCell = NotebookCell
  { cellContent :: !Expr
  , cellStyle :: !(Maybe Text)
  , cellOptions :: ![Expr]
  }
  deriving (Eq, Show)

data CellRecord = CellRecord
  { cellRecordIndex :: !Int
  , cellRecordPath :: ![Int]
  , cellRecordStyle :: !(Maybe Text)
  , cellRecordPreview :: !Text
  , cellRecordCell :: !NotebookCell
  }
  deriving (Eq, Show)

parseNotebook :: Text -> Either NotebookError NotebookDocument
parseNotebook source = do
  expression <- first (NotebookError . parseErrorMessage) (parseInputForm source)
  notebookFromExpr expression

notebookFromExpr :: Expr -> Either NotebookError NotebookDocument
notebookFromExpr (Call (Symbol "Notebook") (itemsExpression : options)) = do
  items <- expectList "Notebook's first argument" itemsExpression
  pure (NotebookDocument (map notebookItemFromExpr items) options)
notebookFromExpr expression =
  Left
    ( NotebookError
        ("expected a Notebook expression, received " <> fullForm expression)
    )

notebookItemFromExpr :: Expr -> NotebookItem
notebookItemFromExpr expression = case expression of
  Call (Symbol "Cell") (Call (Symbol "CellGroupData") groupArguments : outerOptions) ->
    groupFromArguments groupArguments (Just outerOptions)
  Call (Symbol "CellGroupData") groupArguments -> groupFromArguments groupArguments Nothing
  Call (Symbol "Cell") (content : remaining) ->
    let (style, options) = case remaining of
          String styleName : rest -> (Just styleName, rest)
          _ -> (Nothing, remaining)
     in CellItem (NotebookCell content style options)
  _ -> RawItem expression

groupFromArguments :: [Expr] -> Maybe [Expr] -> NotebookItem
groupFromArguments (Call (Symbol "List") items : remaining) outerOptions =
  CellGroup
    (map notebookItemFromExpr items)
    (case remaining of state : _ -> Just state; [] -> Nothing)
    (maybe [] id outerOptions)
groupFromArguments arguments' outerOptions =
  RawItem $ case outerOptions of
    Nothing -> Call (Symbol "CellGroupData") arguments'
    Just options -> Call (Symbol "Cell") (Call (Symbol "CellGroupData") arguments' : options)

notebookToExpr :: NotebookDocument -> Expr
notebookToExpr document =
  Call
    (Symbol "Notebook")
    ( Call (Symbol "List") (map notebookItemToExpr (notebookItems document))
        : notebookOptions document
    )

notebookItemToExpr :: NotebookItem -> Expr
notebookItemToExpr = \case
  CellItem cell ->
    Call
      (Symbol "Cell")
      ( cellContent cell
          : maybe [] (pure . String) (cellStyle cell)
          <> cellOptions cell
      )
  CellGroup items state outerOptions ->
    Call
      (Symbol "Cell")
      ( Call
          (Symbol "CellGroupData")
          ( Call (Symbol "List") (map notebookItemToExpr items)
              : maybe [] pure state
          )
          : outerOptions
      )
  RawItem expression -> expression

renderNotebook :: NotebookDocument -> Text
renderNotebook document = fullForm (notebookToExpr document) <> "\n"

createNotebook :: Maybe Text -> [(Text, Text)] -> NotebookDocument
createNotebook title cells =
  NotebookDocument
    { notebookItems =
        [ CellItem
            NotebookCell
              { cellContent = String text
              , cellStyle = Just style
              , cellOptions = []
              }
        | (style, text) <- cells
        ]
    , notebookOptions = case title of
        Nothing -> []
        Just value -> [Call (Symbol "Rule") [Symbol "WindowTitle", String value]]
    }

flattenCells :: NotebookDocument -> [CellRecord]
flattenCells document =
  zipWith setIndex [0 ..] (concat (zipWith (walkItem . pure) [0 ..] (notebookItems document)))
 where
  setIndex index record = record {cellRecordIndex = index}
  walkItem path = \case
    CellItem cell ->
      [ CellRecord
          { cellRecordIndex = 0
          , cellRecordPath = path
          , cellRecordStyle = cellStyle cell
          , cellRecordPreview = preview (cellContent cell)
          , cellRecordCell = cell
          }
      ]
    CellGroup items _ _ ->
      concat (zipWith (walkItem . (path <>) . pure) [0 ..] items)
    RawItem _ -> []

cellCount :: NotebookDocument -> Int
cellCount = length . flattenCells

groupCount :: NotebookDocument -> Int
groupCount document = sum (map countItem (notebookItems document))
 where
  countItem (CellGroup items _ _) = 1 + sum (map countItem items)
  countItem _ = 0

notebookTitle :: NotebookDocument -> Maybe Text
notebookTitle document = case ruleValue "WindowTitle" (notebookOptions document) of
  Just (String value) -> Just value
  _ -> Nothing

cellId :: NotebookCell -> Maybe Integer
cellId cell = case ruleValue "CellID" (cellOptions cell) of
  Just (Integer value) -> Just value
  _ -> Nothing

expressionUuid :: NotebookCell -> Maybe Text
expressionUuid cell = case ruleValue "ExpressionUUID" (cellOptions cell) of
  Just (String value) -> Just value
  _ -> Nothing

cellTags :: NotebookCell -> [Text]
cellTags cell = case ruleValue "CellTags" (cellOptions cell) of
  Just (String value) -> [value]
  Just (Call (Symbol "List") values) -> [value | String value <- values]
  _ -> []

ruleValue :: Text -> [Expr] -> Maybe Expr
ruleValue name = go
 where
  go [] = Nothing
  go (Call (Symbol "Rule") [Symbol actualName, value] : rest)
    | actualName == name = Just value
    | otherwise = go rest
  go (_ : rest) = go rest

preview :: Expr -> Text
preview expression = truncateText 160 (collapseWhitespace source)
 where
  source = case expression of
    String value -> value
    Call (Symbol "BoxData") [value] -> fullForm value
    _ -> fullForm expression

collapseWhitespace :: Text -> Text
collapseWhitespace = T.unwords . T.words . T.map normalize
 where
  normalize character
    | isSpace character = ' '
    | otherwise = character

truncateText :: Int -> Text -> Text
truncateText limit value
  | T.length value <= limit = value
  | limit <= 1 = T.take limit value
  | otherwise = T.take (limit - 1) value <> "…"

expectList :: Text -> Expr -> Either NotebookError [Expr]
expectList _ (Call (Symbol "List") values) = Right values
expectList label expression =
  Left (NotebookError (label <> " must be a List, received " <> fullForm expression))
