{-# LANGUAGE OverloadedStrings #-}

-- | Inspection and stable deduplication of Wolfram @mathpass@ files.
module Tungsten.Licensing
  ( MathpassInspection (..)
  , emptyMathpassInspection
  , inspectMathpassText
  , inspectMathpass
  , deduplicateMathpassText
  , writeDeduplicatedMathpass
  ) where

import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO
import System.Directory (doesFileExist)

data MathpassInspection = MathpassInspection
  { mathpassPath :: !(Maybe FilePath)
  , mathpassHeaderPresent :: !Bool
  , mathpassOriginalLineCount :: !Int
  , mathpassUniqueEntryCount :: !Int
  , mathpassDuplicateEntryCount :: !Int
  }
  deriving (Eq, Show)

emptyMathpassInspection :: MathpassInspection
emptyMathpassInspection = MathpassInspection Nothing False 0 0 0

inspectMathpassText :: Maybe FilePath -> Text -> MathpassInspection
inspectMathpassText path source =
  let lines' = T.lines source
      headerPresent = case lines' of
        firstLine : _ -> "%" `T.isPrefixOf` firstLine
        [] -> False
      entries = if headerPresent then drop 1 lines' else lines'
      uniqueEntries = stableUnique entries
   in MathpassInspection
        { mathpassPath = path
        , mathpassHeaderPresent = headerPresent
        , mathpassOriginalLineCount = length lines'
        , mathpassUniqueEntryCount = length uniqueEntries
        , mathpassDuplicateEntryCount = max 0 (length entries - length uniqueEntries)
        }

inspectMathpass :: Maybe FilePath -> IO MathpassInspection
inspectMathpass Nothing = pure emptyMathpassInspection
inspectMathpass (Just path) = do
  exists <- doesFileExist path
  if exists
    then inspectMathpassText (Just path) <$> TextIO.readFile path
    else pure emptyMathpassInspection

deduplicateMathpassText :: Text -> Text
deduplicateMathpassText source =
  let lines' = T.lines source
      (header, entries) = case lines' of
        firstLine : rest | "%" `T.isPrefixOf` firstLine -> ([firstLine], rest)
        _ -> ([], lines')
   in T.unlines (header <> stableUnique entries)

writeDeduplicatedMathpass :: FilePath -> FilePath -> IO MathpassInspection
writeDeduplicatedMathpass source destination = do
  contents <- TextIO.readFile source
  TextIO.writeFile destination (deduplicateMathpassText contents)
  pure (inspectMathpassText (Just source) contents)

stableUnique :: Ord value => [value] -> [value]
stableUnique = go Set.empty
 where
  go _ [] = []
  go seen (value : rest)
    | Set.member value seen = go seen rest
    | otherwise = value : go (Set.insert value seen) rest
