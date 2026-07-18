{-# LANGUAGE OverloadedStrings #-}

-- | Immutable Wolfram expression values and their canonical structural view.
module Tungsten.Expression
  ( Expr (..)
  , SparseEntry (..)
  , ExpressionError (..)
  , rational
  , root
  , sparseArray
  , headExpr
  , arguments
  , isAtom
  , fullForm
  ) where

import Data.Bits ((.&.), (.|.), shiftL, shiftR)
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set
import Numeric (showHex, showOct)

-- | The kernel-free expression model.  Every constructor is immutable, and
-- arbitrary-sized 'Integer' values are retained without conversion through a
-- machine numeric type.
data Expr
  = Symbol !Text
  | Integer !Integer
  | Rational !Integer !Integer
  | Real !Text
  | Complex !Expr !Expr
  | String !Text
  | ByteArray !BS.ByteString
  | Call !Expr ![Expr]
  -- | Coefficients in ascending power order, a zero-based root index, and the
  -- Wolfram root-isolation method value.
  | Root ![Integer] !Integer !Integer
  | SparseArray ![Integer] ![SparseEntry] !Expr
  deriving (Eq, Show)

-- | One explicit, one-based element of a sparse array.
data SparseEntry = SparseEntry
  { sparseIndices :: ![Integer]
  , sparseValue :: !Expr
  }
  deriving (Eq, Show)

newtype ExpressionError = ExpressionError {expressionErrorMessage :: Text}
  deriving (Eq, Show)

-- | Construct a reduced rational with a positive denominator.
rational :: Integer -> Integer -> Either ExpressionError Expr
rational _ 0 = Left (ExpressionError "a rational denominator cannot be zero")
rational numerator denominator =
  let sign = if denominator < 0 then -1 else 1
      divisor = gcd numerator denominator
   in Right
        ( Rational
            (sign * (numerator `div` divisor))
            (abs denominator `div` divisor)
        )

-- | Construct a Wolfram algebraic root.  The index is zero-based, matching the
-- original Tungsten engine's in-memory representation.
root :: [Integer] -> Integer -> Integer -> Either ExpressionError Expr
root coefficients index method
  | length coefficients < 2 =
      Left (ExpressionError "Root requires a nonconstant polynomial")
  | last coefficients == 0 =
      Left (ExpressionError "Root requires a nonzero leading coefficient")
  | index < 0 = Left (ExpressionError "Root requires a nonnegative internal index")
  | otherwise = Right (Root coefficients index method)

-- | Construct a sparse array after checking its dimensions and explicit
-- one-based coordinates.
sparseArray :: [Integer] -> [SparseEntry] -> Expr -> Either ExpressionError Expr
sparseArray dimensions entries fill
  | null dimensions = Left (ExpressionError "SparseArray requires at least one dimension")
  | any (< 0) dimensions = Left (ExpressionError "SparseArray dimensions cannot be negative")
  | any invalidEntry entries =
      Left (ExpressionError "SparseArray entry indices do not match its dimensions")
  | Set.size (Set.fromList (map sparseIndices entries)) /= length entries =
      Left (ExpressionError "SparseArray explicit indices must be unique")
  | otherwise = Right (SparseArray dimensions entries fill)
 where
  invalidEntry (SparseEntry indices _) =
    length indices /= length dimensions
      || or (zipWith (\index dimension -> index < 1 || index > dimension) indices dimensions)

-- | The expression returned by Wolfram's structural @Head@ operation.
headExpr :: Expr -> Expr
headExpr expression = case expression of
  Symbol _ -> Symbol "Symbol"
  Integer _ -> Symbol "Integer"
  Rational _ _ -> Symbol "Rational"
  Real _ -> Symbol "Real"
  Complex _ _ -> Symbol "Complex"
  String _ -> Symbol "String"
  ByteArray _ -> Symbol "ByteArray"
  Call expressionHead _ -> expressionHead
  Root {} -> Symbol "Root"
  SparseArray {} -> Symbol "SparseArray"

-- | Structural arguments.  Sparse arrays and byte arrays remain compact atoms;
-- roots expose the same three arguments used by their FullForm projection.
arguments :: Expr -> [Expr]
arguments expression = case expression of
  Call _ values -> values
  Root coefficients index method ->
    [rootFunction coefficients, Integer (index + 1), Integer method]
  _ -> []

isAtom :: Expr -> Bool
isAtom expression = case expression of
  Call {} -> False
  Root {} -> False
  _ -> True

-- | Render the structural Wolfram @FullForm@ representation.
fullForm :: Expr -> Text
fullForm expression = case expression of
  Symbol name -> encodeSymbol name
  Integer value -> T.pack (show value)
  Rational numerator denominator ->
    apply "Rational" [T.pack (show numerator), T.pack (show denominator)]
  Real source -> source
  Complex realPart imaginaryPart ->
    apply "Complex" [fullForm realPart, fullForm imaginaryPart]
  String value -> wolframString value
  ByteArray values -> apply "ByteArray" [wolframString (base64Encode values)]
  Call expressionHead values -> apply (fullForm expressionHead) (map fullForm values)
  Root coefficients index method ->
    apply
      "Root"
      [ fullForm (rootFunction coefficients)
      , T.pack (show (index + 1))
      , T.pack (show method)
      ]
  SparseArray dimensions entries fill ->
    fullForm (sparseConstructor dimensions entries fill)

apply :: Text -> [Text] -> Text
apply headText values = headText <> "[" <> T.intercalate ", " values <> "]"

rootFunction :: [Integer] -> Expr
rootFunction coefficients =
  Call (Symbol "Function") [Call (Symbol "Plus") (polynomialTerms coefficients)]

polynomialTerms :: [Integer] -> [Expr]
polynomialTerms coefficients =
  case concat (zipWith term [0 :: Integer ..] coefficients) of
    [] -> [Integer 0]
    terms -> terms
 where
  slot = Call (Symbol "Slot") [Integer 1]
  term _ 0 = []
  term 0 coefficient = [Integer coefficient]
  term powerIndex coefficient =
    let power =
          if powerIndex == 1
            then slot
            else Call (Symbol "Power") [slot, Integer powerIndex]
     in [ case coefficient of
            1 -> power
            -1 -> Call (Symbol "Times") [Integer (-1), power]
            _ -> Call (Symbol "Times") [Integer coefficient, power]
        ]

sparseConstructor :: [Integer] -> [SparseEntry] -> Expr -> Expr
sparseConstructor dimensions entries fill =
  Call (Symbol "SparseArray") arguments'
 where
  rules =
    Call
      (Symbol "List")
      [ Call
          (Symbol "Rule")
          [Call (Symbol "List") (map Integer indices), value]
      | SparseEntry indices value <- entries
      ]
  shape = Call (Symbol "List") (map Integer dimensions)
  arguments'
    | fill == Integer 0 = [rules, shape]
    | otherwise = [rules, shape, fill]

wolframString :: Text -> Text
wolframString value = "\"" <> T.concatMap escape value <> "\""
 where
  escape '\\' = "\\\\"
  escape '"' = "\\\""
  escape '\r' = "\\r"
  escape '\n' = "\\n"
  escape '\t' = "\\t"
  escape character = T.singleton character

encodeSymbol :: Text -> Text
encodeSymbol = T.concatMap encodeCharacter
 where
  encodeCharacter character
    | codepoint >= 32 && codepoint < 127 = T.singleton character
    | codepoint == 8 = "\\b"
    | codepoint == 9 = "\\t"
    | codepoint == 10 = "\\n"
    | codepoint == 12 = "\\f"
    | codepoint == 13 = "\\r"
    | codepoint == 27 = "\\[RawEscape]"
    | codepoint < 32 || codepoint == 127 = "\\" <> pad 3 (showOct codepoint "")
    | codepoint <= 0xffff = "\\:" <> pad 4 (showHex codepoint "")
    | otherwise = "\\|" <> pad 6 (showHex codepoint "")
   where
    codepoint = ord character
  pad width value = T.pack (replicate (width - length value) '0' ++ value)

base64Encode :: BS.ByteString -> Text
base64Encode = T.pack . go . BS.unpack
 where
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  pick value = alphabet !! fromIntegral value
  go [] = []
  go [a] =
    [ pick (a `shiftR` 2)
    , pick ((a .&. 0x03) `shiftL` 4)
    , '='
    , '='
    ]
  go [a, b] =
    [ pick (a `shiftR` 2)
    , pick (((a .&. 0x03) `shiftL` 4) .|. (b `shiftR` 4))
    , pick ((b .&. 0x0f) `shiftL` 2)
    , '='
    ]
  go (a : b : c : rest) =
    [ pick (a `shiftR` 2)
    , pick (((a .&. 0x03) `shiftL` 4) .|. (b `shiftR` 4))
    , pick (((b .&. 0x0f) `shiftL` 2) .|. (c `shiftR` 6))
    , pick (c .&. 0x3f)
    ]
      ++ go rest
