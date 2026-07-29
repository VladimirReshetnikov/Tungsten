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
import Data.List (findIndex)
import Data.Text (Text)
import qualified Data.Text as T
import Tungsten.Expression
import Tungsten.Parser (parseErrorMessage, parseInputForm)
import Tungsten.WolframString (skipWolframComment, skipWolframString)

newtype NotebookError = NotebookError {notebookErrorMessage :: Text}
  deriving (Eq, Show)

data NotebookDocument = NotebookDocument
  { notebookItems :: ![NotebookItem]
  , notebookOptions :: ![Expr]
  , notebookPreamble :: !Text
  , notebookRawItems :: ![Maybe Text]
  , notebookRawOptions :: ![Maybe Text]
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
  let sourceParts = notebookSourceParts source
      expressionSource = case sourceParts of
        Just (preamble, _, _) -> T.drop (T.length preamble) source
        Nothing -> source
  expression <- first (NotebookError . parseErrorMessage) (parseInputForm expressionSource)
  document <- notebookFromExpr expression
  pure $ case sourceParts of
    Just (preamble, rawItems, rawOptions)
      | length rawItems == length (notebookItems document)
          && length rawOptions == length (notebookOptions document) ->
          document
            { notebookPreamble = preamble
            , notebookRawItems = map Just rawItems
            , notebookRawOptions = map Just rawOptions
            }
    _ -> document

notebookSourceParts :: Text -> Maybe (Text, [Text], [Text])
notebookSourceParts source = do
  let (preamble, notebookSuffix) = T.breakOn "Notebook[" source
  if T.null notebookSuffix then Nothing else pure ()
  let openIndex = T.length preamble + T.length ("Notebook" :: Text)
  closeIndex <- matchingSquareBracket source openIndex
  rawArguments <- pure (splitTopLevelText (T.take (closeIndex - openIndex - 1) (T.drop (openIndex + 1) source)))
  firstArgument <- case rawArguments of
    value : _ -> Just (T.strip value)
    [] -> Nothing
  if T.length firstArgument < 2 || T.head firstArgument /= '{' || T.last firstArgument /= '}'
    then Nothing
    else
      let itemSource = T.init (T.tail firstArgument)
          items = splitTopLevelText itemSource
       in Just (preamble, items, drop 1 rawArguments)

matchingSquareBracket :: Text -> Int -> Maybe Int
matchingSquareBracket source openIndex
  | openIndex < 0 || openIndex >= T.length source || T.index source openIndex /= '[' = Nothing
  | otherwise = go (openIndex + 1) 1
 where
  sourceLength = T.length source
  go :: Int -> Int -> Maybe Int
  go index depth
    | index >= sourceLength = Nothing
    | "(*" `T.isPrefixOf` T.drop index source = go (skipWolframComment source index) depth
    | T.index source index == '"' = go (skipWolframString source index) depth
    | T.index source index == '[' = go (index + 1) (depth + 1)
    | T.index source index == ']' =
        if depth == 1 then Just index else go (index + 1) (depth - 1)
    | otherwise = go (index + 1) depth

splitTopLevelText :: Text -> [Text]
splitTopLevelText source = reverse (finish (go 0 0 0 0 0 []))
 where
  sourceLength = T.length source
  go :: Int -> Int -> Int -> Int -> Int -> [Text] -> (Int, [Text])
  go index start squareDepth braceDepth parenthesisDepth parts
    | index >= sourceLength = (start, parts)
    | "(*" `T.isPrefixOf` T.drop index source =
        go (skipWolframComment source index) start squareDepth braceDepth parenthesisDepth parts
    | T.index source index == '"' =
        go (skipWolframString source index) start squareDepth braceDepth parenthesisDepth parts
    | otherwise = case T.index source index of
        '[' -> advance (squareDepth + 1) braceDepth parenthesisDepth
        ']' -> advance (max 0 (squareDepth - 1)) braceDepth parenthesisDepth
        '{' -> advance squareDepth (braceDepth + 1) parenthesisDepth
        '}' -> advance squareDepth (max 0 (braceDepth - 1)) parenthesisDepth
        '(' -> advance squareDepth braceDepth (parenthesisDepth + 1)
        ')' -> advance squareDepth braceDepth (max 0 (parenthesisDepth - 1))
        ','
          | squareDepth == 0 && braceDepth == 0 && parenthesisDepth == 0 ->
              let part = T.strip (T.take (index - start) (T.drop start source))
                  updatedParts = if T.null part then parts else part : parts
               in go (index + 1) (index + 1) squareDepth braceDepth parenthesisDepth updatedParts
        _ -> advance squareDepth braceDepth parenthesisDepth
     where
      advance nextSquare nextBrace nextParenthesis =
        go (index + 1) start nextSquare nextBrace nextParenthesis parts
  finish (start, parts) =
    let part = T.strip (T.drop start source)
     in if T.null part then parts else part : parts

notebookFromExpr :: Expr -> Either NotebookError NotebookDocument
notebookFromExpr (Call (Symbol "Notebook") (itemsExpression : options)) = do
  items <- expectList "Notebook's first argument" itemsExpression
  pure
    NotebookDocument
      { notebookItems = map notebookItemFromExpr items
      , notebookOptions = options
      , notebookPreamble = ""
      , notebookRawItems = replicate (length items) Nothing
      , notebookRawOptions = replicate (length options) Nothing
      }
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
renderNotebook document =
  notebookPreamble document
    <> "Notebook[{\n"
    <> T.intercalate ",\n" renderedItems
    <> "\n}"
    <> (if null renderedOptions then "" else ", " <> T.intercalate ", " renderedOptions)
    <> "]\n"
 where
  renderedItems = zipWith renderPreserved (notebookItems document) (padRaw (notebookRawItems document))
  renderedOptions = zipWith renderOption (notebookOptions document) (padRaw (notebookRawOptions document))
  renderPreserved item = maybe (renderNotebookItem item) id
  renderOption option = maybe (notebookSourceExpression option) id
  padRaw values = values <> repeat Nothing

renderNotebookItem :: NotebookItem -> Text
renderNotebookItem = \case
  CellItem cell ->
    "Cell["
      <> T.intercalate ", "
        ( cellExpressionText (cellContent cell)
            : maybe [] (pure . cellExpressionText . String) (cellStyle cell)
            <> map cellExpressionText (cellOptions cell)
        )
      <> "]"
  CellGroup items state outerOptions ->
    "Cell[CellGroupData[{\n"
      <> T.intercalate ",\n" (map renderNotebookItem items)
      <> "\n}"
      <> maybe "" ((", " <>) . cellExpressionText) state
      <> "]"
      <> (if null outerOptions then "" else ", " <> T.intercalate ", " (map cellExpressionText outerOptions))
      <> "]"
  RawItem expression -> cellExpressionText expression

cellExpressionText :: Expr -> Text
cellExpressionText = notebookSourceExpression

notebookSourceExpression :: Expr -> Text
notebookSourceExpression (Call (Symbol ruleHead) [left, right])
  | ruleHead == "Rule" || ruleHead == "System`Rule" =
      inputForm left <> "->" <> inputForm right
notebookSourceExpression expression = inputForm expression

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
        Just value | not (T.null value) ->
          [Call (Symbol "Rule") [Symbol "WindowTitle", String value]]
        _ -> []
    , notebookPreamble = ""
    , notebookRawItems = replicate (length cells) Nothing
    , notebookRawOptions = case title of
        Just value | not (T.null value) -> [Nothing]
        _ -> []
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
    let rawItems = case maybe [] id containerPath of
          [] -> notebookRawItems document <> [Nothing]
          path -> invalidateTopLevel path (notebookRawItems document)
    pure document {notebookItems = items, notebookRawItems = rawItems}
  InsertCell containerPath index cell -> do
    items <- modifyContainer (maybe [] id containerPath) (insertAt index (CellItem cell)) (notebookItems document)
    let rawItems = case maybe [] id containerPath of
          [] -> insertRawAt index (notebookRawItems document)
          path -> invalidateTopLevel path (notebookRawItems document)
    pure document {notebookItems = items, notebookRawItems = rawItems}
  ReplaceCell path requestedStyle content -> do
    items <- modifyTarget path replaceTarget (notebookItems document)
    pure document {notebookItems = items, notebookRawItems = invalidateTopLevel path (notebookRawItems document)}
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
    let rawItems = case path of
          [index] -> deleteRawAt index (notebookRawItems document)
          _ -> invalidateTopLevel path (notebookRawItems document)
    pure document {notebookItems = items, notebookRawItems = rawItems}
  SetNotebookOption name value ->
    let options = notebookOptions document
        existingIndex = findIndex (isRuleNamed name) options
        rawOptions = case existingIndex of
          Just index -> replaceRawAt index Nothing (notebookRawOptions document)
          Nothing -> notebookRawOptions document <> [Nothing]
     in Right
          document
            { notebookOptions = setRule name value options
            , notebookRawOptions = rawOptions
            }

isRuleNamed :: Text -> Expr -> Bool
isRuleNamed name (Call (Symbol "Rule") [Symbol actualName, _]) = actualName == name
isRuleNamed _ _ = False

invalidateTopLevel :: [Int] -> [Maybe Text] -> [Maybe Text]
invalidateTopLevel (index : _) = replaceRawAt index Nothing
invalidateTopLevel [] = id

replaceRawAt :: Int -> Maybe Text -> [Maybe Text] -> [Maybe Text]
replaceRawAt index value values
  | index < 0 || index >= length values = values
  | otherwise = take index values <> [value] <> drop (index + 1) values

insertRawAt :: Int -> [Maybe Text] -> [Maybe Text]
insertRawAt index values = take index values <> [Nothing] <> drop index values

deleteRawAt :: Int -> [Maybe Text] -> [Maybe Text]
deleteRawAt index values = take index values <> drop (index + 1) values

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
    Call (Symbol "BoxData") [value] -> T.unwords (stringLeaves value)
    _ -> fullForm expression
  stringLeaves = \case
    String value -> [value]
    Call expressionHead values -> concatMap stringLeaves (expressionHead : values)
    Complex realPart imaginaryPart -> stringLeaves realPart <> stringLeaves imaginaryPart
    _ -> []

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
