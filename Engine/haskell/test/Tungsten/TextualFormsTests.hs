{-# LANGUAGE OverloadedStrings #-}

module Tungsten.TextualFormsTests (checkTextualFormsEvaluator) where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Tungsten.Evaluate (EvaluationError (..), evaluate)
import Tungsten.Expression (Expr, fullForm)
import Tungsten.Parser (parseInputForm)
import Tungsten.Session (emptySession, evaluateInSession)

checkTextualFormsEvaluator :: IO Bool
checkTextualFormsEvaluator = do
  values <- traverse checkValue valueCases
  errors <- traverse checkError errorCases
  pure (and (values <> errors))

valueCases :: [(Text, Text, Text)]
valueCases =
  [ ("default base64 encoding", "BaseEncode[ByteArray[{65,66,67}]]", "\"QUJD\"")
  , ("base16 encoding", "BaseEncode[ByteArray[{0,255}],\"Base16\"]", "\"00FF\"")
  , ("ASCII85 zero abbreviation", "BaseEncode[ByteArray[{0,0,0,0}],\"Base85ASCII\"]", "\"z\"")
  , ("permissive base64 decoding", "Normal[BaseDecode[\"Q U!J@D\",\"Base64\"]]", "List[65, 66, 67]")
  , ("filtered base16 decoding", "Normal[BaseDecode[\"00-ff\",\"Base16\"]]", "List[0, 255]")
  , ("ASCII85 decoding", "Normal[BaseDecode[\"z\",\"Base85ASCII\"]]", "List[0, 0, 0, 0]")
  , ("InputForm text", "ToString[HoldComplete[1+2],InputForm]", "\"HoldComplete[1 + 2]\"")
  , ("StandardForm text", "ToString[HoldComplete[f@x//g],StandardForm]", "\"HoldComplete[g[f[x]]]\"")
  , ("CForm text", "ToString[x^2,CForm]", "\"Power(x,2)\"")
  , ("FortranForm text", "ToString[x^2,FortranForm]", "\"x**2\"")
  , ("TeX text", "ToString[1+x,TeXForm]", "\"x+1\"")
  , ("TeX power text", "ToString[x^2,TeXForm]", "\"x^{2}\"")
  , ("traditional inline boxes", "ToString[1+x,TraditionalForm]", "\"\\\\!\\\\(\\\\*FormBox[RowBox[{\\\"x\\\", \\\"+\\\", \\\"1\\\"}], TraditionalForm]\\\\)\"")
  , ("named operator InputForm", "ToString[CirclePlus[a,b],InputForm]", "\"a \\\\[CirclePlus] b\"")
  , ("named operator TeX", "ToString[CirclePlus[a,b],TeXForm]", "\"a\\\\oplus b\"")
  , ("default ToExpression evaluation", "ToExpression[\"1+2\"]", "3")
  , ("held ToExpression", "ToExpression[\"1+2\",InputForm,HoldComplete]", "HoldComplete[Plus[1, 2]]")
  , ("listable ToExpression", "ToExpression[{\"1+2\",\"f[x]\"},InputForm,HoldComplete]", "List[HoldComplete[Plus[1, 2]], HoldComplete[f[x]]]")
  , ("TeX named operator round trip", "ToExpression[\"a\\\\oplus b\",TeXForm,HoldComplete]", "HoldComplete[CirclePlus[a, b]]")
  , ("TeX power round trip", "ToExpression[ToString[x^2,TeXForm],TeXForm,HoldComplete]", "HoldComplete[Power[x, 2]]")
  , ("TeX fraction preserves syntax", "ToExpression[\"\\\\frac{1}{2}\",TeXForm,HoldComplete]", "HoldComplete[Times[1, Power[2, -1]]]")
  , ("MathML power round trip", "ToExpression[ToString[x^2,MathMLForm],MathMLForm,HoldComplete]", "HoldComplete[Power[x, 2]]")
  , ("held standard boxes", "MakeBoxes[1+2,StandardForm]", "RowBox[List[\"1\", \"+\", \"2\"]]")
  , ("evaluated standard boxes", "ToBoxes[1+2,StandardForm]", "\"3\"")
  , ("traditional boxes", "ToBoxes[1+x,TraditionalForm]", "FormBox[RowBox[List[\"x\", \"+\", \"1\"]], TraditionalForm]")
  , ("box interpretation", "ToExpression[RowBox[{\"1\",\"+\",\"2\"}],StandardForm,HoldComplete]", "HoldComplete[Plus[1, 2]]")
  , ("MakeExpression holds syntax", "MakeExpression[RowBox[{\"1\",\"+\",\"2\"}],StandardForm]", "HoldComplete[Plus[1, 2]]")
  , ("box stripping", "StripBoxes[RowBox[{\"1\",\" \",StyleBox[\"+\",Red],\"2\"}]]", "BoxData[RowBox[List[\"1\", \"+\", \"2\"]]]")
  , ("valid syntax", "SyntaxQ[\"1+2\"]", "True")
  , ("invalid syntax", "SyntaxQ[\"1+\"]", "False")
  , ("box syntax", "SyntaxQ[RowBox[{\"1\",\"+\",\"2\"}]]", "True")
  , ("complete syntax length", "SyntaxLength[\"1+2\"]", "3")
  , ("incomplete syntax length", "SyntaxLength[\"1+\"]", "4")
  , ("text import", "ImportString[\"abc\",\"Text\"]", "\"abc\"")
  , ("byte-string import", "ImportString[\"abc\",\"Byte\"]", "List[97, 98, 99]")
  , ("JSON import", "ImportString[\"{\\\"a\\\":1,\\\"b\\\":[2,3]}\",\"JSON\"]", "List[Rule[\"a\", 1], Rule[\"b\", List[2, 3]]]")
  , ("RawJSON import", "ImportString[\"{\\\"a\\\":1}\",\"RawJSON\"]", "Association[Rule[\"a\", 1]]")
  , ("CSV import", "ImportString[\"1,2\\n3,4\\n\",\"CSV\"]", "List[List[1, 2], List[3, 4]]")
  , ("WL import", "ImportString[\"f[a,1]\",\"WL\"]", "f[a, 1]")
  , ("byte export string", "ExportString[{97,98,99},\"Byte\"]", "\"abc\"")
  , ("WL export string", "ExportString[f[a,1],\"WL\"]", "\"f[a, 1]\"")
  , ("CSV round trip", "ImportString[ExportString[{{1,2},{3,4}},\"CSV\"],\"CSV\"]", "List[List[1, 2], List[3, 4]]")
  , ("byte array import", "ImportByteArray[ByteArray[{97,98,99}],\"Byte\"]", "List[97, 98, 99]")
  , ("raw string byte array import", "ImportByteArray[ByteArray[{97,98,99}],\"String\"]", "\"abc\"")
  , ("byte array export", "Normal[ExportByteArray[{97,98,99},\"Byte\"]]", "List[97, 98, 99]")
  , ("RawJSON byte-array round trip", "ImportByteArray[ExportByteArray[<|\"a\"->1|>,\"RawJSON\"],\"RawJSON\"]", "Association[Rule[\"a\", 1]]")
  ]

errorCases :: [(Text, Text, Text)]
errorCases =
  [ ("base encoder requires bytes", "BaseEncode[{1,2}]", "BaseEncode expects a ByteArray.")
  , ("base decoder requires text", "BaseDecode[ByteArray[{1}]]", "BaseDecode expects the input data to be a string.")
  , ("base decoder validates encoding", "BaseDecode[\"00\",\"Base32\"]", "BaseDecode currently supports Base64, Base16, and Base85ASCII.")
  , ("ToExpression rejects output form", "ToExpression[\"x\",OutputForm]", "ToExpression does not support this expression form.")
  , ("ToBoxes rejects textual form", "ToBoxes[x,TeXForm]", "ToBoxes supports InputForm, StandardForm, and TraditionalForm as box forms.")
  , ("SyntaxQ validates input", "SyntaxQ[1]", "SyntaxQ expects a string or a supported StandardForm box expression.")
  , ("ImportString validates input", "ImportString[1,\"Text\"]", "ImportString expects the source data to be a string.")
  , ("ExportString validates bytes", "ExportString[{256},\"Byte\"]", "ByteArray values must be integers between 0 and 255.")
  , ("RawJSON rejects rule lists", "ExportString[{\"a\"->1},\"RawJSON\"]", "ExportString RawJSON export expects associations for JSON objects, not lists of rules.")
  , ("compression boundary is explicit", "ExportString[\"hello\",{\"GZIP\",\"String\"}]", "Unsupported compression wrapper: GZIP.")
  ]

checkValue :: (Text, Text, Text) -> IO Bool
checkValue (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left evaluationError -> failCheck label ("evaluation error: " <> showText evaluationError)
    Right result
      | fullForm result /= expected ->
          failCheck label ("expected " <> expected <> ", got " <> fullForm result)
      | otherwise -> checkSessionValue label expression expected

checkSessionValue :: Text -> Expr -> Text -> IO Bool
checkSessionValue label expression expected = do
  evaluated <- evaluateInSession emptySession expression
  case evaluated of
    Left evaluationError -> failCheck label ("session evaluation error: " <> showText evaluationError)
    Right (result, _)
      | fullForm result == expected -> pure True
      | otherwise -> failCheck label ("session expected " <> expected <> ", got " <> fullForm result)

checkError :: (Text, Text, Text) -> IO Bool
checkError (label, source, expected) = case parseInputForm source of
  Left parseError -> failCheck label ("parse error: " <> showText parseError)
  Right expression -> case evaluate expression of
    Left (EvaluationError message)
      | message == expected -> pure True
      | otherwise -> failCheck label ("expected error " <> expected <> ", got " <> message)
    Right result -> failCheck label ("expected an evaluation error, got " <> fullForm result)

failCheck :: Text -> Text -> IO Bool
failCheck label detail = do
  TextIO.putStrLn ("FAIL: " <> label <> ": " <> detail)
  pure False

showText :: Show value => value -> Text
showText = Text.pack . show
