{-# OPTIONS -cpp -fffi #-}
#if __GLASGOW_HASKELL__ < 603
#include "config.h"
#else
#include "ghcconfig.h"
#endif
-----------------------------------------------------------------------------
--
-- (c) The University of Glasgow, 2004
--
-- runghc program, for invoking from a #! line in a script.  For example:
--
--   script.lhs:
--      #! /usr/bin/runghc
--      > main = putStrLn "hello!"
--
-- runghc accepts one flag:
--
--      -f <path>    specify the path
--
-- -----------------------------------------------------------------------------

module Main (main) where

import System.Environment
import System.IO
import Data.List
import System.Exit
import Data.Char

#ifdef USING_COMPAT
import Compat.RawSystem ( rawSystem )
import Compat.Directory ( findExecutable )
#else
import System.Cmd       ( rawSystem )
import System.Directory ( findExecutable )
#endif

main :: IO ()
main = do
    args <- getArgs
    case args of
        "-f" : ghc : args'        -> doIt ghc args'
        ('-' : 'f' : ghc) : args' -> doIt (dropWhile isSpace ghc) args'
        _ -> do
            mb_ghc <- findExecutable "ghc"
            case mb_ghc of
                Nothing  -> dieProg ("cannot find ghc")
                Just ghc -> doIt ghc args

doIt :: String -> [String] -> IO ()
doIt ghc args = do
    let (ghc_args, rest) = break notArg args
    case rest of
        [] -> dieProg "syntax: runghc [-f GHCPATH] [GHC-ARGS] FILE ARG..."
        filename : prog_args -> do
            let expr = "System.Environment.withProgName " ++ show filename ++
                       " (System.Environment.withArgs " ++ show prog_args ++
                       " (GHC.TopHandler.runIOFastExit" ++
                       " (Main.main Prelude.>> Prelude.return ())))"
            res <- rawSystem ghc (["-ignore-dot-ghci"] ++ ghc_args ++
                                  [ "-e", expr, filename])
               -- runIOFastExit: makes exceptions raised by Main.main
               -- behave in the same way as for a compiled program.
               -- The "fast exit" part just calls exit() directly
               -- instead of doing an orderly runtime shutdown,
               -- otherwise the main GHCi thread will complain about
               -- being interrupted.
               --
               -- Why (main >> return ()) rather than just main?  Because
               -- otherwise GHCi by default tries to evaluate the result
               -- of the IO in order to show it (see #1200).
            exitWith res

notArg :: String -> Bool
notArg ('-':_) = False
notArg _       = True

dieProg :: String -> IO a
dieProg msg = do
    p <- getProgName
    hPutStrLn stderr (p ++ ": " ++ msg)
    exitWith (ExitFailure 1)

