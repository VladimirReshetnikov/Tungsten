{-# LANGUAGE OverloadedStrings #-}

-- | Wolfram string-literal escaping and embedded inline-box segmentation.
module Tungsten.WolframString
  ( WolframStringSegment (..)
  , inlineBoxPrefix
  , inlineBoxOpen
  , inlineBoxClose
  , wlString
  , parseWolframStringLiteral
  , inlineBoxEscape
  , composeInlineBoxString
  , composeInlineBoxStringLiteral
  , splitInlineBoxes
  , inlineBoxSegments
  , hasInlineBoxes
  , displayText
  , skipWolframString
  , skipWolframComment
  ) where

import Data.Char (chr, digitToInt, isHexDigit)
import Data.Text (Text)
import qualified Data.Text as T

inlineBoxPrefix :: Text
inlineBoxPrefix = "\\!\\(\\*"

inlineBoxOpen :: Text
inlineBoxOpen = "\\("

inlineBoxClose :: Text
inlineBoxClose = "\\)"

linearSyntaxBang, linearSyntaxOpen, linearSyntaxClose, linearSyntaxStar :: Text
linearSyntaxBang = "\xf7c1"
linearSyntaxOpen = "\xf7c9"
linearSyntaxClose = "\xf7c0"
linearSyntaxStar = "\xf7c8"

inlineBoxPrefixDecoded, inlineBoxOpenDecoded, inlineBoxCloseDecoded :: Text
inlineBoxPrefixDecoded = linearSyntaxBang <> linearSyntaxOpen <> linearSyntaxStar
inlineBoxOpenDecoded = linearSyntaxBang <> linearSyntaxOpen
inlineBoxCloseDecoded = linearSyntaxClose

data WolframStringSegment
  = StringTextSegment
      { stringSegmentText :: !Text
      }
  | StringInlineBoxSegment
      { stringSegmentBoxExpression :: !Text
      , stringSegmentSource :: !Text
      }
  deriving (Eq, Show)

-- | Encode text as a Wolfram string literal without normalizing
-- Wolfram-specific source escapes.
wlString :: Text -> Text
wlString value = "\"" <> T.concatMap escape value <> "\""
 where
  escape '\\' = "\\\\"
  escape '"' = "\\\""
  escape '\r' = "\\r"
  escape '\n' = "\\n"
  escape '\t' = "\\t"
  escape character = T.singleton character

-- | Decode one Wolfram string literal using the kernel-compatible character
-- and linear-syntax escape rules used by the Python engine.
parseWolframStringLiteral :: Text -> Text
parseWolframStringLiteral value = T.concat (reverse (go 0 []))
 where
  source
    | T.length value >= 2 && T.head value == '"' && T.last value == '"' =
        T.init (T.tail value)
    | otherwise = value
  sourceLength = T.length source

  go index output
    | index >= sourceLength = output
    | T.index source index /= '\\' || index + 1 >= sourceLength =
        go (index + 1) (T.singleton (T.index source index) : output)
    | otherwise =
        let marker = T.index source (index + 1)
         in case marker of
              '\n' -> go (index + 2) output
              '\r'
                | index + 2 < sourceLength && T.index source (index + 2) == '\n' ->
                    go (index + 3) output
                | otherwise -> go (index + 2) output
              _ -> case decodeCharacterEscape source index of
                Just (decoded, nextIndex) -> go nextIndex (decoded : output)
                Nothing -> go (index + 2) (decodeSimpleEscape marker : output)

decodeSimpleEscape :: Char -> Text
decodeSimpleEscape marker = case marker of
  'b' -> "\b"
  'f' -> "\f"
  'r' -> "\r"
  'n' -> "\n"
  't' -> "\t"
  '\\' -> "\\"
  '"' -> "\""
  '!' -> linearSyntaxBang
  '(' -> linearSyntaxOpen
  ')' -> linearSyntaxClose
  '*' -> linearSyntaxStar
  '<' -> ""
  '>' -> ""
  _ -> "\\" <> T.singleton marker

decodeCharacterEscape :: Text -> Int -> Maybe (Text, Int)
decodeCharacterEscape source index
  | startsAt "\\[" index source = decodeNamedEscape source index
  | marker == ':' = decodeHexEscape 4 source index
  | marker == '.' = decodeHexEscape 2 source index
  | marker == '|' = decodeHexEscape 6 source index
  | marker >= '0' && marker <= '7' = decodeOctalEscape source index
  | otherwise = Nothing
 where
  marker = T.index source (index + 1)

decodeNamedEscape :: Text -> Int -> Maybe (Text, Int)
decodeNamedEscape source index = do
  relativeEnd <- T.findIndex (== ']') (T.drop (index + 2) source)
  let end = index + 2 + relativeEnd
      name = T.take (end - index - 2) (T.drop (index + 2) source)
      verbatim = T.take (end - index + 1) (T.drop index source)
  pure (maybe verbatim T.singleton (namedCharacter name), end + 1)

namedCharacter :: Text -> Maybe Char
namedCharacter name = case name of
  "Alpha" -> Just (chr 0x03b1)
  "Beta" -> Just (chr 0x03b2)
  "Gamma" -> Just (chr 0x03b3)
  "Delta" -> Just (chr 0x03b4)
  "Pi" -> Just (chr 0x03c0)
  "Infinity" -> Just (chr 0x221e)
  "Degree" -> Just (chr 0x00b0)
  "ImaginaryI" -> Just (chr 0x2148)
  _ -> Nothing

decodeHexEscape :: Int -> Text -> Int -> Maybe (Text, Int)
decodeHexEscape width source index = do
  let digits = T.take width (T.drop (index + 2) source)
  if T.length digits /= width || T.any (not . isHexDigit) digits
    then Nothing
    else do
      let codepoint = T.foldl' (\value character -> value * 16 + digitToInt character) 0 digits
      if codepoint > 0x10ffff
        then Nothing
        else Just (T.singleton (chr codepoint), index + 2 + width)

decodeOctalEscape :: Text -> Int -> Maybe (Text, Int)
decodeOctalEscape source index =
  let digits = T.take 3 (T.drop (index + 1) source)
   in if T.length digits /= 3 || T.any (\character -> character < '0' || character > '7') digits
        then Nothing
        else
          let codepoint = T.foldl' (\value character -> value * 8 + digitToInt character) 0 digits
           in Just (T.singleton (chr codepoint), index + 4)

inlineBoxEscape :: Text -> Text
inlineBoxEscape boxExpression = inlineBoxPrefix <> boxExpression <> inlineBoxClose

composeInlineBoxString :: Text -> [Text] -> Text -> Text
composeInlineBoxString prefix boxExpressions suffix =
  prefix <> T.concat (map inlineBoxEscape boxExpressions) <> suffix

composeInlineBoxStringLiteral :: Text -> [Text] -> Text -> Text
composeInlineBoxStringLiteral prefix boxExpressions suffix =
  wlString (composeInlineBoxString prefix boxExpressions suffix)

splitInlineBoxes :: Text -> [WolframStringSegment]
splitInlineBoxes value = reverse (finish textParts output)
 where
  (textParts, output) = go 0 [] []
  valueLength = T.length value

  go index parts segments
    | index >= valueLength = (parts, segments)
    | startsAt inlineBoxPrefix index value = case parseRawInlineBox value index of
        Just (segment, nextIndex) -> go nextIndex [] (segment : flush parts segments)
        Nothing -> ordinary index parts segments
    | startsAt inlineBoxPrefixDecoded index value = case parseDecodedInlineBox value index of
        Just (segment, nextIndex) -> go nextIndex [] (segment : flush parts segments)
        Nothing -> ordinary index parts segments
    | otherwise = ordinary index parts segments

  ordinary index parts segments =
    go (index + 1) (T.singleton (T.index value index) : parts) segments
  flush [] segments = segments
  flush parts segments = StringTextSegment (T.concat (reverse parts)) : segments
  finish = flush

inlineBoxSegments :: Text -> [WolframStringSegment]
inlineBoxSegments = filter isInlineBox . splitInlineBoxes
 where
  isInlineBox StringInlineBoxSegment {} = True
  isInlineBox StringTextSegment {} = False

hasInlineBoxes :: Text -> Bool
hasInlineBoxes = any isInlineBox . splitInlineBoxes
 where
  isInlineBox StringInlineBoxSegment {} = True
  isInlineBox StringTextSegment {} = False

displayText :: Text -> Text -> Text
displayText placeholder = T.concat . map render . splitInlineBoxes
 where
  render (StringTextSegment value) = value
  render StringInlineBoxSegment {} = placeholder

parseRawInlineBox :: Text -> Int -> Maybe (WolframStringSegment, Int)
parseRawInlineBox value start
  | not (startsAt inlineBoxPrefix start value) = Nothing
  | otherwise = closeRaw (start + T.length inlineBoxPrefix) 1
 where
  closeRaw :: Int -> Int -> Maybe (WolframStringSegment, Int)
  closeRaw index depth
    | index >= T.length value = Nothing
    | startsAt inlineBoxOpen index value = closeRaw (index + T.length inlineBoxOpen) (depth + 1)
    | startsAt inlineBoxClose index value =
        let nextIndex = index + T.length inlineBoxClose
         in if depth == 1
              then Just (makeSegment inlineBoxPrefix inlineBoxClose nextIndex, nextIndex)
              else closeRaw nextIndex (depth - 1)
    | T.index value index == '"' = closeRaw (skipWolframString value index) depth
    | startsAt "(*" index value = closeRaw (skipWolframComment value index) depth
    | otherwise = closeRaw (index + 1) depth

  makeSegment prefix close nextIndex =
    let raw = T.take (nextIndex - start) (T.drop start value)
        innerLength = T.length raw - T.length prefix - T.length close
     in StringInlineBoxSegment
          (T.take innerLength (T.drop (T.length prefix) raw))
          raw

parseDecodedInlineBox :: Text -> Int -> Maybe (WolframStringSegment, Int)
parseDecodedInlineBox value start
  | not (startsAt inlineBoxPrefixDecoded start value) = Nothing
  | otherwise = closeDecoded (start + T.length inlineBoxPrefixDecoded) 1
 where
  closeDecoded :: Int -> Int -> Maybe (WolframStringSegment, Int)
  closeDecoded index depth
    | index >= T.length value = Nothing
    | startsAt inlineBoxOpenDecoded index value =
        closeDecoded (index + T.length inlineBoxOpenDecoded) (depth + 1)
    | startsAt inlineBoxCloseDecoded index value =
        let nextIndex = index + T.length inlineBoxCloseDecoded
         in if depth == 1
              then Just (makeSegment nextIndex, nextIndex)
              else closeDecoded nextIndex (depth - 1)
    | T.index value index == '"' = closeDecoded (skipWolframString value index) depth
    | startsAt "(*" index value = closeDecoded (skipWolframComment value index) depth
    | otherwise = closeDecoded (index + 1) depth

  makeSegment nextIndex =
    let raw = T.take (nextIndex - start) (T.drop start value)
        innerLength = T.length raw - T.length inlineBoxPrefixDecoded - T.length inlineBoxCloseDecoded
     in StringInlineBoxSegment
          (T.take innerLength (T.drop (T.length inlineBoxPrefixDecoded) raw))
          raw

skipWolframString :: Text -> Int -> Int
skipWolframString source start = go (start + 1)
 where
  sourceLength = T.length source
  go index
    | index >= sourceLength = index
    | T.index source index == '\\' = go (min sourceLength (index + 2))
    | T.index source index == '"' = index + 1
    | otherwise = go (index + 1)

skipWolframComment :: Text -> Int -> Int
skipWolframComment source start = go (start + 2) 1
 where
  sourceLength = T.length source
  go :: Int -> Int -> Int
  go index depth
    | index >= sourceLength || depth == 0 = index
    | startsAt "(*" index source = go (index + 2) (depth + 1)
    | startsAt "*)" index source = go (index + 2) (depth - 1)
    | otherwise = go (index + 1) depth

startsAt :: Text -> Int -> Text -> Bool
startsAt prefix index value = prefix `T.isPrefixOf` T.drop index value
