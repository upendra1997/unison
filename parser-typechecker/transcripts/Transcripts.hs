{-# LANGUAGE OverloadedStrings #-}

module Main where

import           Unison.Prelude
import           EasyTest
import           Shellmet                       (($|))
import           System.Directory
import           System.FilePath                ( (</>)
                                                , splitFileName
                                                , takeExtensions
                                                , takeBaseName
                                                )
import           System.Process                 ( readProcessWithExitCode )

import           Data.Text                      ( pack
                                                , unpack
                                                )
import           Data.List

type TestBuilder = FilePath -> FilePath -> [String] -> String -> Test ()

testBuilder :: FilePath -> FilePath -> [String] -> String -> Test ()
testBuilder ucm dir prelude transcript = scope transcript $ do
  io $ fromString ucm args
  ok
  where
    files = fmap (pack . (dir </>)) (prelude ++ [transcript])
    args = ["transcript"] ++ files

testBuilderNewRuntime :: FilePath -> FilePath -> [String] -> String -> Test ()
testBuilderNewRuntime ucm dir prelude transcript = scope transcript $ do
  io $ fromString ucm args
  ok
  where
    files = fmap (pack . (dir </>)) (prelude ++ [transcript])
    args = ["--new-runtime", "transcript"] ++ files

testBuilder' :: FilePath -> FilePath -> [String] -> String -> Test ()
testBuilder' ucm dir prelude transcript = scope transcript $ do
  let output = dir </> takeBaseName transcript <> ".output.md"
  io $ runAndCaptureError ucm args output
  ok
  where
    files = fmap (pack . (dir </>)) (prelude ++ [transcript])
    args = ["transcript"] ++ files
    -- Given a command and arguments, run it and capture the standard error to a file
    -- regardless of success or failure.
    runAndCaptureError :: FilePath -> [Text] -> FilePath -> IO ()
    runAndCaptureError cmd args outfile = do
      t <- readProcessWithExitCode cmd (map unpack args) ""
      let output = (\(_, _, stderr) -> stderr) t
      writeUtf8 outfile $ (pack . dropRunMessage) output

    -- Given the standard error, drops the part in the end that changes each run
    dropRunMessage :: String -> String
    dropRunMessage = unlines . reverse . drop 3 . reverse . lines


buildTests :: TestBuilder -> FilePath -> Test ()
buildTests testBuilder dir = do
  io
     . putStrLn
     . unlines
     $ [ ""
       , "Searching for transcripts to run in: " ++ dir
       ]
  files <- io $ listDirectory dir
  let 
    -- Any files that start with _ are treated as prelude
    (prelude, transcripts) =
      partition ((isPrefixOf "_") . snd . splitFileName)
      . sort
      . filter (\f -> takeExtensions f == ".md") $ files

  ucm <- io $ unpack <$> "stack" $| ["exec", "--", "which", "unison"] -- todo: what is it in windows?
  tests (testBuilder ucm dir prelude <$> transcripts)

-- Transcripts that exit successfully get cleaned-up by the transcript parser.
-- Any remaining folders matching "transcript-.*" are output directories
-- of failed transcripts and should be moved under the "test-output" folder
cleanup :: Test ()
cleanup = do
  files' <- io $ listDirectory "."
  let dirs = filter ("transcript-" `isPrefixOf`) files'

  -- if any such codebases remain they are moved under test-output
  unless (null dirs) $ do
    io $ createDirectoryIfMissing True "test-output"
    io $ for_ dirs (\d -> renameDirectory d ("test-output" </> d))
    io
      . putStrLn
      . unlines
      $ [ ""
        , "NOTE: All transcript codebases have been moved into"
        , "the `test-output` directory. Feel free to delete it."
        ]

test :: Test ()
test = do
  buildTests testBuilder $ "unison-src" </> "transcripts"
  buildTests testBuilderNewRuntime $ "unison-src" </> "new-runtime-transcripts"
  buildTests testBuilder' $"unison-src" </> "transcripts" </> "errors"
  cleanup

main :: IO ()
main = run test
