{-# LANGUAGE OverloadedStrings #-}
module Command.Compile where

import GHC.IO.Handle
import Options.Applicative
import System.Directory
import System.FilePath
import System.IO
import System.IO.Temp
import System.Process

import qualified Processor

data Options = Options
  { inputFile :: FilePath
  , maybeOutputFile :: Maybe FilePath
  , optimisation :: Maybe String
  , assemblyDir :: Maybe FilePath
  , verbosity :: Int
  , logFile :: Maybe FilePath
  } deriving (Show)

optionsParserInfo :: ParserInfo Options
optionsParserInfo = info (helper <*> optionsParser)
  $ fullDesc
  <> progDesc "Compile a Sixten program"
  <> header "sixten compile"

optionsParser :: Parser Options
optionsParser = Options
  <$> strArgument
    (metavar "FILE"
    <> help "Input source FILE"
    )
  <*> optional (strOption
    $ long "output"
    <> short 'o'
    <> metavar "FILE"
    <> help "Write output to FILE"
    )
  <*> optional (strOption
    $ long "optimisation-level"
    <> short 'O'
    <> metavar "LEVEL"
    <> help "Set the optimisation level to LEVEL"
    )
  <*> optional (strOption
    $ long "save-assembly"
    <> short 'S'
    <> metavar "DIR"
    <> help "Save intermediate assembly files to DIR"
    )
  <*> option auto
    (long "verbose"
    <> short 'v'
    <> metavar "LEVEL"
    <> help "Set the verbosity level to LEVEL"
    <> value 0
    )
  <*> optional (strOption
    $ long "log-file"
    <> metavar "FILE"
    <> help "Write logs to FILE instead of standard output"
    )

compile :: Options -> (FilePath -> IO a) -> IO a
compile opts continuation =
  withAssemblyDir (assemblyDir opts) $ \asmDir ->
  withOutputFile (maybeOutputFile opts) $ \outputFile ->
  withLogHandle (logFile opts) $ \logHandle -> do
    let llFile = asmDir </> fileName <.> "ll"
    Processor.processFile (inputFile opts) llFile logHandle (verbosity opts)
    (optLlFile, optFlag) <- case optimisation opts of
      Nothing -> return (llFile, id)
      Just optLevel -> do
        let optFlag = ("-O" <> optLevel :)
            optLlFile = asmDir </> fileName <> "-opt" <.> "ll"
        callProcess "opt" $ optFlag ["-S", llFile, "-o", optLlFile]
        return (optLlFile, optFlag)
    let asmFile = asmDir </> fileName <.> "s"
    callProcess "llc" $ optFlag ["-march=x86-64", optLlFile, "-o", asmFile]
    ldFlags <- readProcess "pkg-config" ["--libs", "--static", "bdw-gc"] ""
    callProcess "gcc" $ concatMap words (lines ldFlags) ++ optFlag [asmFile, "-o", outputFile]
    continuation outputFile
  where
    (inputDir, inputFileName) = splitFileName $ inputFile opts
    fileName = dropExtension inputFileName

    withAssemblyDir Nothing k = withSystemTempDirectory "sixten" k
    withAssemblyDir (Just dir) k = do
      createDirectoryIfMissing True dir
      k dir
    withOutputFile Nothing k
      = withTempFile inputDir fileName $ \outputFile outputFileHandle -> do
        hClose outputFileHandle
        k outputFile
    withOutputFile (Just o) k = k o
    withLogHandle Nothing k = k stdout
    withLogHandle (Just file) k = withFile file WriteMode k

command :: ParserInfo (IO ())
command = flip compile (const $ pure ()) <$> optionsParserInfo
