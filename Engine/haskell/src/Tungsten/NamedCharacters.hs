{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The Wolfram 15.0 named-character catalog and token classifications.
module Tungsten.NamedCharacters
  ( namedCharacterCodepoints
  , namedCharacter
  , namedCharacterEscapeForChar
  , encodePrintableAscii
  , symbolAliasForCharacter
  , isNamedOperatorCharacter
  , namedInfixOperatorEscape
  , namedOperatorSpellings
  ) where

import Data.Char (chr, ord)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex, showOct)
import qualified Tungsten.NamedCharacterTH as TH

-- | All 1,100 kernel-accepted names extracted from Wolfram 15.0's
-- @UnicodeCharacters.tr@ and shipped with the Python reference engine.
namedCharacterCodepoints :: Map Text Int
namedCharacterCodepoints =
  Map.fromList
    [ (T.pack name, fromInteger codepoint)
    | (name, codepoint) <- $(TH.namedCharacterEntriesFrom "src/tungsten/data/wolfram_named_characters_15_0.json")
    ]

namedCharacter :: Text -> Maybe Char
namedCharacter name = chr <$> Map.lookup name namedCharacterCodepoints

namedCharacterEscapeForChar :: Char -> Maybe Text
namedCharacterEscapeForChar character =
  ("\\[" <>) . (<> "]") <$> Map.lookup character namedCharacterReverseMap

namedCharacterReverseMap :: Map Char Text
namedCharacterReverseMap = foldl' add Map.empty (Map.toAscList namedCharacterCodepoints)
 where
  add result (name, codepoint)
    | codepoint < 128 && "Raw" `T.isPrefixOf` name = result
    | otherwise = Map.insertWith (\_ existing -> existing) (chr codepoint) name result

encodePrintableAscii :: Text -> Text
encodePrintableAscii = T.concatMap encode
 where
  encode character
    | codepoint >= 32 && codepoint < 127 = T.singleton character
    | codepoint == 8 = "\\b"
    | codepoint == 9 = "\\t"
    | codepoint == 10 = "\\n"
    | codepoint == 12 = "\\f"
    | codepoint == 13 = "\\r"
    | codepoint == 27 = "\\[RawEscape]"
    | codepoint < 32 || codepoint == 127 = "\\" <> pad 3 (showOct codepoint "")
    | Just escaped <- namedCharacterEscapeForChar character = escaped
    | codepoint <= 0xffff = "\\:" <> pad 4 (showHex codepoint "")
    | otherwise = "\\|" <> pad 6 (showHex codepoint "")
   where
    codepoint = ord character
  pad width value = T.pack (replicate (width - length value) '0' <> value)

symbolAliasForCharacter :: Char -> Maybe Text
symbolAliasForCharacter character = Map.lookup character symbolAliases

symbolAliases :: Map Char Text
symbolAliases =
  Map.fromList
    [ (character, alias)
    | (name, alias) <- symbolAliasNames
    , Just character <- [namedCharacter name]
    ]

symbolAliasNames :: [(Text, Text)]
symbolAliasNames =
  [ ("Degree", "Degree")
  , ("ExponentialE", "E")
  , ("ImaginaryI", "I")
  , ("ImaginaryJ", "I")
  , ("Infinity", "Infinity")
  , ("Pi", "Pi")
  ]

isNamedOperatorCharacter :: Char -> Bool
isNamedOperatorCharacter character = Set.member character namedOperatorCharacters

namedOperatorCharacters :: Set Char
namedOperatorCharacters =
  Set.fromList
    [ character
    | name <- tokenNames <> infixOperatorNames
    , Just character <- [namedCharacter name]
    ]

namedOperatorSpellings :: Text -> [Text]
namedOperatorSpellings normalized =
  normalized
    : [ spelling
      | (name, token) <- tokenAliases
      , token == normalized
      , spelling <- ["\\[" <> name <> "]", maybe "" T.singleton (namedCharacter name)]
      , not (T.null spelling)
      ]

-- | Return the canonical escaped spelling for a named infix operator head.
-- Keeping this projection beside the parser's operator catalog prevents the
-- renderer and lexer from silently drifting to different named-character
-- subsets.
namedInfixOperatorEscape :: Text -> Maybe Text
namedInfixOperatorEscape name
  | Set.member name infixOperatorNameSet = Just ("\\[" <> name <> "]")
  | otherwise = Nothing

infixOperatorNameSet :: Set Text
infixOperatorNameSet = Set.fromList infixOperatorNames

tokenNames :: [Text]
tokenNames = map fst tokenAliases

tokenAliases :: [(Text, Text)]
tokenAliases =
  [ ("And", "&&")
  , ("Equal", "==")
  , ("Function", "|->")
  , ("GreaterEqual", ">=")
  , ("InvisibleApplication", "@")
  , ("InvisibleTimes", "*")
  , ("LeftAssociation", "<|")
  , ("LessEqual", "<=")
  , ("NotEqual", "!=")
  , ("Or", "||")
  , ("RightAssociation", "|>")
  , ("Rule", "->")
  , ("RuleDelayed", ":>")
  ]

infixOperatorNames :: [Text]
infixOperatorNames =
  [ "Backslash", "Because", "Cap", "CenterDot", "CircleDot", "CircleMinus"
  , "CirclePlus", "CircleTimes", "Congruent", "Coproduct", "Cross", "Cup"
  , "CupCap", "Del", "Diamond", "DirectedEdge", "DiscreteRatio", "DiscreteShift"
  , "DotEqual", "DoubleDownArrow", "DoubleLeftArrow", "DoubleLeftRightArrow"
  , "DoubleLeftTee", "DoubleLongLeftArrow", "DoubleLongLeftRightArrow"
  , "DoubleLongRightArrow", "DoubleRightArrow", "DoubleUpArrow", "DoubleUpDownArrow"
  , "DoubleVerticalBar", "DownArrow", "DownArrowBar", "DownArrowUpArrow"
  , "DownLeftRightVector", "DownLeftTeeVector", "DownLeftVector", "DownLeftVectorBar"
  , "DownRightTeeVector", "DownRightVector", "DownRightVectorBar", "DownTee"
  , "DownTeeArrow", "Element", "EqualTilde", "Equilibrium", "Equivalent"
  , "GreaterEqualLess", "GreaterFullEqual", "GreaterGreater", "GreaterLess"
  , "GreaterSlantEqual", "GreaterTilde", "HumpDownHump", "HumpEqual", "Implies"
  , "Intersection", "LeftArrow", "LeftArrowBar", "LeftArrowRightArrow"
  , "LeftDownTeeVector", "LeftDownVector", "LeftDownVectorBar", "LeftRightArrow"
  , "LeftTee", "LeftTeeArrow", "LeftTeeVector", "LeftTriangle", "LeftTriangleBar"
  , "LeftTriangleEqual", "LeftUpDownVector", "LeftUpTeeVector", "LeftUpVector"
  , "LeftUpVectorBar", "LeftVector", "LeftVectorBar", "LessEqualGreater"
  , "LessFullEqual", "LessGreater", "LessLess", "LessSlantEqual", "LessTilde"
  , "LongLeftArrow", "LongLeftRightArrow", "LongRightArrow", "LowerLeftArrow"
  , "LowerRightArrow", "MinusPlus", "Nand", "NestedGreaterGreater", "NestedLessLess"
  , "Nor", "NotCongruent", "NotCupCap", "NotDoubleVerticalBar", "NotElement"
  , "NotGreater", "NotGreaterEqual", "NotGreaterFullEqual", "NotGreaterLess"
  , "NotGreaterTilde", "NotLeftTriangle", "NotLeftTriangleEqual", "NotLess"
  , "NotLessEqual", "NotLessFullEqual", "NotLessGreater", "NotLessTilde"
  , "NotPrecedes", "NotPrecedesSlantEqual", "NotPrecedesTilde", "NotReverseElement"
  , "NotRightTriangle", "NotRightTriangleEqual", "NotSquareSubsetEqual"
  , "NotSquareSupersetEqual", "NotSubset", "NotSubsetEqual", "NotSucceeds"
  , "NotSucceedsSlantEqual", "NotSucceedsTilde", "NotSuperset", "NotSupersetEqual"
  , "NotTilde", "NotTildeEqual", "NotTildeFullEqual", "NotTildeTilde"
  , "Perpendicular", "PlusMinus", "Precedes", "PrecedesEqual", "PrecedesSlantEqual"
  , "PrecedesTilde", "Proportion", "Proportional", "ReverseElement"
  , "ReverseEquilibrium", "ReverseUpEquilibrium", "RightArrow", "RightArrowBar"
  , "RightArrowLeftArrow", "RightDownTeeVector", "RightDownVector"
  , "RightDownVectorBar", "RightTee", "RightTeeArrow", "RightTeeVector"
  , "RightTriangle", "RightTriangleBar", "RightTriangleEqual", "RightUpDownVector"
  , "RightUpTeeVector", "RightUpVector", "RightUpVectorBar", "RightVector"
  , "RightVectorBar", "RoundImplies", "ShortDownArrow", "ShortLeftArrow"
  , "ShortRightArrow", "ShortUpArrow", "SmallCircle", "Square", "SquareIntersection"
  , "SquareSubset", "SquareSubsetEqual", "SquareSuperset", "SquareSupersetEqual"
  , "SquareUnion", "Star", "Subset", "SubsetEqual", "Succeeds", "SucceedsEqual"
  , "SucceedsSlantEqual", "SucceedsTilde", "SuchThat", "Superset", "SupersetEqual"
  , "TensorProduct", "Therefore", "Tilde", "TildeEqual", "TildeFullEqual"
  , "TildeTilde", "UndirectedEdge", "Union", "UnionPlus", "UpArrow", "UpArrowBar"
  , "UpArrowDownArrow", "UpDownArrow", "UpEquilibrium", "UpTee", "UpTeeArrow"
  , "UpperLeftArrow", "UpperRightArrow", "Vee", "VerticalBar", "VerticalSeparator"
  , "VerticalTilde", "Wedge", "Xor"
  ]
