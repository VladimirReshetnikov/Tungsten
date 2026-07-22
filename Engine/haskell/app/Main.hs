module Main (main) where

import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure, ExitSuccess), exitWith)
import Tungsten.Cli (runCli)

main :: IO ()
main = do
  arguments <- getArgs
  exitCode <- runCli arguments
  exitWith (if exitCode == 0 then ExitSuccess else ExitFailure exitCode)
