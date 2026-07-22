{-# LANGUAGE TemplateHaskell #-}

-- | Compile-time loader for the Wolfram named-character JSON catalog.
module Tungsten.NamedCharacterTH (namedCharacterEntriesFrom) where

import Data.Char (isDigit, isSpace)
import Data.Maybe (mapMaybe)
import Language.Haskell.TH
import Language.Haskell.TH.Syntax (qAddDependentFile)
import System.FilePath ((</>), takeDirectory)
import Text.Read (readMaybe)

namedCharacterEntriesFrom :: FilePath -> Q Exp
namedCharacterEntriesFrom relativePath = do
  sourceLocation <- location
  let packageRoot = iterate takeDirectory (loc_filename sourceLocation) !! 4
      catalogPath = packageRoot </> relativePath
  qAddDependentFile catalogPath
  source <- runIO (readFile catalogPath)
  let entries = mapMaybe parseEntry (lines source)
  if length entries /= 1100
    then fail ("expected 1100 Wolfram named characters in " <> catalogPath)
    else listE [tupE [litE (stringL name), litE (integerL codepoint)] | (name, codepoint) <- entries]

parseEntry :: String -> Maybe (String, Integer)
parseEntry source = case dropWhile isSpace source of
  '"' : remaining -> do
    let (name, afterName) = break (== '"') remaining
    afterColon <- case afterName of
      '"' : ':' : rest -> Just rest
      _ -> Nothing
    let digits = takeWhile isDigit (dropWhile isSpace afterColon)
    codepoint <- readMaybe digits
    pure (name, codepoint)
  _ -> Nothing
