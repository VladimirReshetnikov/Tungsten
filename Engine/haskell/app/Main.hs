{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.Text.IO as Text
import System.IO (BufferMode (LineBuffering), hIsEOF, hSetBuffering, hSetEncoding, stdin, stdout, utf8)
import Tungsten.Json

main :: IO ()
main = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  hSetBuffering stdout LineBuffering
  serve

serve :: IO ()
serve = do
  finished <- hIsEOF stdin
  if finished
    then pure ()
    else do
      line <- Text.hGetLine stdin
      let response = case decodeRequestLine line of
            Left parseError ->
              ProtocolFailure Nothing "" (jsonErrorMessage parseError)
            Right request -> handleProtocolRequest request
      Text.putStr (encodeResponseLine response)
      serve
