{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Kernel-free structural Wolfram notebook documents.
module Tungsten.Notebook
  ( NotebookError (..)
  , NotebookDocument (..)
  , NotebookItem (..)
  , NotebookCell (..)
  , CellRecord (..)
  , NotebookPatch (..)
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
  , applyNotebookPatches
  ) where

import Control.Applicative ((<|>))
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

data NotebookPatch
  = AppendCell !(Maybe [Int]) !NotebookCell
  | InsertCell !(Maybe [Int]) !Int !NotebookCell
  | ReplaceCell ![Int] !(Maybe Text) !Expr
  | DeleteItem ![Int]
  | SetNotebookOption !Text !Expr
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

applyNotebookPatches :: [NotebookPatch] -> NotebookDocument -> Either NotebookError NotebookDocument
applyNotebookPatches patches document = foldl applyOne (Right document) patches
 where
  applyOne accumulated patch = accumulated >>= applyNotebookPatch patch

applyNotebookPatch :: NotebookPatch -> NotebookDocument -> Either NotebookError NotebookDocument
applyNotebookPatch patch document = case patch of
  AppendCell containerPath cell -> do
    items <- modifyContainer (maybe [] id containerPath) (Right . (<> [CellItem cell])) (notebookItems document)
    pure document {notebookItems = items}
  InsertCell containerPath index cell -> do
    items <- modifyContainer (maybe [] id containerPath) (insertAt index (CellItem cell)) (notebookItems document)
    pure document {notebookItems = items}
  ReplaceCell path requestedStyle content -> do
    items <- modifyTarget path replaceTarget (notebookItems document)
    pure document {notebookItems = items}
   where
    replaceTarget (CellItem existing) =
      Right
        ( CellItem
            NotebookCell
              { cellContent = content
              , cellStyle = requestedStyle <|> cellStyle existing
              , cellOptions = []
              }
        )
    replaceTarget (RawItem _) =
      Right (CellItem (NotebookCell content requestedStyle []))
    replaceTarget CellGroup {} =
      Left (NotebookError "replace_cell expects a cell or raw item target")
  DeleteItem path -> do
    items <- deleteAtPath path (notebookItems document)
    pure document {notebookItems = items}
  SetNotebookOption name value ->
    Right document {notebookOptions = setRule name value (notebookOptions document)}

modifyContainer
  :: [Int]
  -> ([NotebookItem] -> Either NotebookError [NotebookItem])
  -> [NotebookItem]
  -> Either NotebookError [NotebookItem]
modifyContainer [] operation items = operation items
modifyContainer (index : rest) operation items = do
  item <- itemAt index items
  replacement <- case item of
    CellGroup children state options ->
      CellGroup <$> modifyContainer rest operation children <*> pure state <*> pure options
    _ -> Left (NotebookError "a notebook container path does not identify a cell group")
  replaceAt index replacement items

modifyTarget
  :: [Int]
  -> (NotebookItem -> Either NotebookError NotebookItem)
  -> [NotebookItem]
  -> Either NotebookError [NotebookItem]
modifyTarget [] _ _ = Left (NotebookError "a notebook item path cannot be empty")
modifyTarget [index] operation items = do
  target <- itemAt index items
  replacement <- operation target
  replaceAt index replacement items
modifyTarget (index : rest) operation items = do
  item <- itemAt index items
  replacement <- case item of
    CellGroup children state options ->
      CellGroup <$> modifyTarget rest operation children <*> pure state <*> pure options
    _ -> Left (NotebookError "a notebook item path does not resolve through a cell group")
  replaceAt index replacement items

deleteAtPath :: [Int] -> [NotebookItem] -> Either NotebookError [NotebookItem]
deleteAtPath [] _ = Left (NotebookError "a notebook deletion path cannot be empty")
deleteAtPath [index] items
  | index < 0 || index >= length items = Left (NotebookError "a notebook item path is out of range")
  | otherwise = Right (take index items <> drop (index + 1) items)
deleteAtPath (index : rest) items = do
  item <- itemAt index items
  replacement <- case item of
    CellGroup children state options ->
      CellGroup <$> deleteAtPath rest children <*> pure state <*> pure options
    _ -> Left (NotebookError "a notebook deletion path does not resolve through a cell group")
  replaceAt index replacement items

insertAt :: Int -> NotebookItem -> [NotebookItem] -> Either NotebookError [NotebookItem]
insertAt index value items
  | index < 0 || index > length items = Left (NotebookError "a notebook insertion index is out of range")
  | otherwise = Right (take index items <> [value] <> drop index items)

itemAt :: Int -> [NotebookItem] -> Either NotebookError NotebookItem
itemAt index items
  | index < 0 || index >= length items = Left (NotebookError "a notebook item path is out of range")
  | otherwise = case drop index items of
      item : _ -> Right item
      [] -> Left (NotebookError "a notebook item path is out of range")

replaceAt :: Int -> NotebookItem -> [NotebookItem] -> Either NotebookError [NotebookItem]
replaceAt index value items
  | index < 0 || index >= length items = Left (NotebookError "a notebook item path is out of range")
  | otherwise = Right (take index items <> [value] <> drop (index + 1) items)

setRule :: Text -> Expr -> [Expr] -> [Expr]
setRule name value = go
 where
  replacement = Call (Symbol "Rule") [Symbol name, value]
  go [] = [replacement]
  go (Call (Symbol "Rule") [Symbol actualName, _] : rest)
    | actualName == name = replacement : rest
  go (item : rest) = item : go rest

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
