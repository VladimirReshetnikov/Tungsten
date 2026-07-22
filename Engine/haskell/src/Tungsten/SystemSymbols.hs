{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Immutable metadata for the visible @System`@ symbol catalog.
module Tungsten.SystemSymbols
  ( SymbolAttribute (..)
  , symbolAttributeFromName
  , symbolAttributeName
  , normalizeSystemSymbolName
  , systemSymbolAttributes
  , isSystemSymbol
  , systemSymbolNames
  , systemSymbolCount
  ) where

import Data.Bits (testBit)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import qualified Tungsten.SystemSymbolTH as TH

-- | Attributes represented in the Wolfram 15.0 System-symbol snapshot.
-- Constructor order is stable because it is also the compact catalog's bit
-- assignment and the canonical attribute presentation order.
data SymbolAttribute
  = Constant
  | Flat
  | HoldAll
  | HoldAllComplete
  | HoldFirst
  | HoldRest
  | Listable
  | Locked
  | NHoldAll
  | NHoldFirst
  | NHoldRest
  | NonThreadable
  | NumericFunction
  | OneIdentity
  | Orderless
  | Protected
  | ReadProtected
  | SequenceHold
  | Stub
  | Temporary
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Canonical Wolfram spelling for an attribute.
symbolAttributeName :: SymbolAttribute -> Text
symbolAttributeName = \case
  Constant -> "Constant"
  Flat -> "Flat"
  HoldAll -> "HoldAll"
  HoldAllComplete -> "HoldAllComplete"
  HoldFirst -> "HoldFirst"
  HoldRest -> "HoldRest"
  Listable -> "Listable"
  Locked -> "Locked"
  NHoldAll -> "NHoldAll"
  NHoldFirst -> "NHoldFirst"
  NHoldRest -> "NHoldRest"
  NonThreadable -> "NonThreadable"
  NumericFunction -> "NumericFunction"
  OneIdentity -> "OneIdentity"
  Orderless -> "Orderless"
  Protected -> "Protected"
  ReadProtected -> "ReadProtected"
  SequenceHold -> "SequenceHold"
  Stub -> "Stub"
  Temporary -> "Temporary"

-- | Parse a canonical Wolfram attribute spelling.
symbolAttributeFromName :: Text -> Maybe SymbolAttribute
symbolAttributeFromName name =
  find ((== name) . symbolAttributeName) [minBound .. maxBound]

-- | Normalize either an unqualified name or an explicitly @System`@-qualified
-- name. Names in @Global`@ or any other context are not System names.
normalizeSystemSymbolName :: Text -> Maybe Text
normalizeSystemSymbolName name
  | Just shortName <- T.stripPrefix "System`" name = unqualified shortName
  | "`" `T.isInfixOf` name = Nothing
  | otherwise = unqualified name
 where
  unqualified shortName
    | T.null shortName || "`" `T.isInfixOf` shortName = Nothing
    | otherwise = Just shortName

-- | Look up the typed attribute set for a visible System symbol. A present
-- symbol with no attributes returns @Just Set.empty@.
systemSymbolAttributes :: Text -> Maybe (Set SymbolAttribute)
systemSymbolAttributes name = do
  shortName <- normalizeSystemSymbolName name
  attributesFromMask <$> Map.lookup shortName systemSymbolMasks

-- | Whether the supplied bare or @System`@-qualified name is in the catalog.
isSystemSymbol :: Text -> Bool
isSystemSymbol name =
  maybe False (`Map.member` systemSymbolMasks) (normalizeSystemSymbolName name)

-- | All visible System names, unqualified and in deterministic lexical order.
systemSymbolNames :: [Text]
systemSymbolNames = Map.keys systemSymbolMasks

-- | Number of visible System names in the combined Wolfram/Python catalog.
systemSymbolCount :: Int
systemSymbolCount = Map.size systemSymbolMasks

attributesFromMask :: Word32 -> Set SymbolAttribute
attributesFromMask mask =
  Set.fromDistinctAscList
    [ attribute
    | attribute <- [minBound .. maxBound]
    , testBit mask (fromEnum attribute)
    ]

systemSymbolMasks :: Map Text Word32
systemSymbolMasks =
  Map.fromDistinctAscList
    [ (T.pack name, fromInteger mask)
    | (name, mask) <-
        $(
            TH.systemSymbolEntriesFrom
              "src/tungsten/data/system_symbols_wolfram_15_0.json"
              [ "ConfirmationFailed"
              , "FailsafeFailed"
              , "MachineIntegerQ"
              , "NegativeDegreeLexicographic"
              , "NegativeDegreeReverseLexicographic"
              , "NegativeLexicographic"
              ]
         )
    ]
