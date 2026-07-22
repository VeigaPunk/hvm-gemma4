module Main where

import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hClose, hPutStr, openTempFile)
import System.Process (readProcessWithExitCode)
import System.Directory (getTemporaryDirectory, removeFile)
import Text.Read (readMaybe)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [hvm4Bin, requestedText] -> runBudget hvm4Bin requestedText
    _ -> putStrLn "usage: hvm4-control HVM4_BIN NUM_PREDICT" >> exitFailure

runBudget :: FilePath -> String -> IO ()
runBudget hvm4Bin requestedText =
  case readMaybe requestedText :: Maybe Int of
    Just requested | requested >= 1 && requested <= 4096 -> do
      tempDir <- getTemporaryDirectory
      (path, handle) <- openTempFile tempDir "gemma-control.hvm"
      hPutStr handle ("@main = " ++ show requested ++ "\n")
      hClose handle
      (code, stdoutText, stderrText) <- readProcessWithExitCode hvm4Bin [path, "-C1"] ""
      removeFile path
      case code of
        ExitSuccess ->
          case readMaybe (takeWhile (`elem` ['0'..'9']) stdoutText) :: Maybe Int of
            Just budget | budget == requested -> putStrLn (show budget)
            _ -> putStrLn "HVM4_CONTROL_ERROR: unexpected result" >> exitFailure
        ExitFailure _ -> putStrLn ("HVM4_CONTROL_ERROR: " ++ stderrText) >> exitFailure
    _ -> putStrLn "HVM4_CONTROL_ERROR: NUM_PREDICT must be 1..4096" >> exitFailure
