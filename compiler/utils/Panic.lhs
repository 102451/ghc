%
% (c) The University of Glasgow 2006
% (c) The GRASP Project, Glasgow University, 1992-2000
%

Defines basic funtions for printing error messages.

It's hard to put these functions anywhere else without causing
some unnecessary loops in the module dependency graph.

\begin{code}
module Panic  
   ( 
     GhcException(..), showGhcException, throwGhcException, handleGhcException,
     ghcError, progName,
     pgmError,

     panic, panicFastInt, assertPanic, trace,
     
     Exception.Exception(..), showException, try, tryJust, tryMost, tryUser,
     catchJust, throwTo,

     installSignalHandlers, interruptTargetThread
   ) where

#include "HsVersions.h"

import Config
import FastTypes

#ifndef mingw32_HOST_OS
import System.Posix.Signals
#endif /* mingw32_HOST_OS */

#if defined(mingw32_HOST_OS)
import GHC.ConsoleHandler
#endif

import Exception
import Control.Concurrent ( MVar, ThreadId, withMVar, newMVar )
import Data.Dynamic
import Debug.Trace	( trace )
import System.IO.Unsafe	( unsafePerformIO )
import System.IO.Error hiding ( try )
import System.Exit
import System.Environment
\end{code}

GHC's own exception type.

\begin{code}
ghcError :: GhcException -> a
#if __GLASGOW_HASKELL__ >= 609
ghcError e = Exception.throw e
#else
ghcError e = Exception.throwDyn e
#endif

-- error messages all take the form
--
--	<location>: <error>
--
-- If the location is on the command line, or in GHC itself, then 
-- <location>="ghc".  All of the error types below correspond to 
-- a <location> of "ghc", except for ProgramError (where the string is
-- assumed to contain a location already, so we don't print one).

data GhcException
  = PhaseFailed String		-- name of phase 
  		ExitCode	-- an external phase (eg. cpp) failed
  | Interrupted			-- someone pressed ^C
  | UsageError String		-- prints the short usage msg after the error
  | CmdLineError String		-- cmdline prob, but doesn't print usage
  | Panic String		-- the `impossible' happened
  | InstallationError String	-- an installation problem
  | ProgramError String		-- error in the user's code, probably
  deriving Eq

#if __GLASGOW_HASKELL__ >= 609
instance Exception GhcException
#endif

progName :: String
progName = unsafePerformIO (getProgName)
{-# NOINLINE progName #-}

short_usage :: String
short_usage = "Usage: For basic information, try the `--help' option."

#if __GLASGOW_HASKELL__ < 609
showException :: Exception.Exception -> String
-- Show expected dynamic exceptions specially
showException (Exception.DynException d) | Just e <- fromDynamic d 
					 = show (e::GhcException)
showException other_exn	       	 	 = show other_exn
#else
showException :: Exception e => e -> String
showException = show
#endif

instance Show GhcException where
  showsPrec _ e@(ProgramError _) = showGhcException e
  showsPrec _ e@(CmdLineError _) = showString "<command line>: " . showGhcException e
  showsPrec _ e = showString progName . showString ": " . showGhcException e

showGhcException :: GhcException -> String -> String
showGhcException (UsageError str)
   = showString str . showChar '\n' . showString short_usage
showGhcException (PhaseFailed phase code)
   = showString "phase `" . showString phase . 
     showString "' failed (exitcode = " . shows int_code . 
     showString ")"
  where
    int_code = 
      case code of
        ExitSuccess   -> (0::Int)
	ExitFailure x -> x
showGhcException (CmdLineError str)
   = showString str
showGhcException (ProgramError str)
   = showString str
showGhcException (InstallationError str)
   = showString str
showGhcException (Interrupted)
   = showString "interrupted"
showGhcException (Panic s)
   = showString ("panic! (the 'impossible' happened)\n"
		 ++ "  (GHC version " ++ cProjectVersion ++ " for " ++ TargetPlatform_NAME ++ "):\n\t"
	         ++ s ++ "\n\n"
	         ++ "Please report this as a GHC bug:  http://www.haskell.org/ghc/reportabug\n")

throwGhcException :: GhcException -> a
#if __GLASGOW_HASKELL__ < 609
throwGhcException = Exception.throwDyn
#else
throwGhcException = Exception.throw
#endif

handleGhcException :: ExceptionMonad m => (GhcException -> m a) -> m a -> m a
#if __GLASGOW_HASKELL__ < 609
handleGhcException = flip gcatchDyn
#else
handleGhcException = ghandle
#endif

ghcExceptionTc :: TyCon
ghcExceptionTc = mkTyCon "GhcException"
{-# NOINLINE ghcExceptionTc #-}
instance Typeable GhcException where
  typeOf _ = mkTyConApp ghcExceptionTc []
\end{code}

Panics and asserts.

\begin{code}
panic, pgmError :: String -> a
panic    x = throwGhcException (Panic x)
pgmError x = throwGhcException (ProgramError x)

--  #-versions because panic can't return an unboxed int, and that's
-- what TAG_ is with GHC at the moment.  Ugh. (Simon)
-- No, man -- Too Beautiful! (Will)

panicFastInt :: String -> FastInt
panicFastInt s = case (panic s) of () -> _ILIT(0)

assertPanic :: String -> Int -> a
assertPanic file line = 
  Exception.throw (Exception.AssertionFailed 
           ("ASSERT failed! file " ++ file ++ ", line " ++ show line))
\end{code}

\begin{code}
-- | tryMost is like try, but passes through Interrupted and Panic
-- exceptions.  Used when we want soft failures when reading interface
-- files, for example.

#if __GLASGOW_HASKELL__ < 609
tryMost :: IO a -> IO (Either Exception.Exception a)
tryMost action = do r <- try action; filter r
  where
   filter (Left e@(Exception.DynException d))
	    | Just ghc_ex <- fromDynamic d
		= case ghc_ex of
		    Interrupted -> Exception.throw e
		    Panic _     -> Exception.throw e
		    _other      -> return (Left e)
   filter other 
     = return other
#else
-- XXX I'm not entirely sure if this is catching what we really want to catch
tryMost :: IO a -> IO (Either SomeException a)
tryMost action = do r <- try action
                    case r of
                        Left se@(SomeException e) ->
                            case cast e of
                                -- Some GhcException's we rethrow,
                                Just Interrupted -> throwIO se
                                Just (Panic _)   -> throwIO se
                                -- others we return
                                Just _           -> return (Left se)
                                Nothing ->
                                    case cast e of
                                        -- All IOExceptions are returned
                                        Just (_ :: IOException) ->
                                            return (Left se)
                                        -- Anything else is rethrown
                                        Nothing -> throwIO se
                        Right v -> return (Right v)
#endif

-- | tryUser is like try, but catches only UserErrors.
-- These are the ones that are thrown by the TcRn monad 
-- to signal an error in the program being compiled
#if __GLASGOW_HASKELL__ < 609
tryUser :: IO a -> IO (Either Exception.Exception a)
tryUser action = tryJust tc_errors action
  where 
	tc_errors e@(Exception.IOException ioe) | isUserError ioe = Just e
	tc_errors _other = Nothing
#else
tryUser :: IO a -> IO (Either ErrorCall a)
tryUser io =
    do ei <- try io
       case ei of
           Right v -> return (Right v)
           Left se@(SomeException ex) ->
               case cast ex of
               -- Look for good old fashioned ErrorCall's
               Just errorCall -> return (Left errorCall)
               Nothing ->
                   case cast ex of
                   -- And also for user errors in IO errors.
                   -- Sigh.
                   Just ioe
                    | isUserError ioe ->
                       return (Left (ErrorCall (ioeGetErrorString ioe)))
                   _ -> throw se
#endif
\end{code}

Standard signal handlers for catching ^C, which just throw an
exception in the target thread.  The current target thread is
the thread at the head of the list in the MVar passed to
installSignalHandlers.

\begin{code}
installSignalHandlers :: IO ()
installSignalHandlers = do
  let
#if __GLASGOW_HASKELL__ < 609
      interrupt_exn = Exception.DynException (toDyn Interrupted)
#else
      interrupt_exn = (toException Interrupted)
#endif

      interrupt = do
	withMVar interruptTargetThread $ \targets ->
	  case targets of
	   [] -> return ()
	   (thread:_) -> throwTo thread interrupt_exn
  --
#if !defined(mingw32_HOST_OS)
  installHandler sigQUIT (Catch interrupt) Nothing 
  installHandler sigINT  (Catch interrupt) Nothing
  return ()
#else
  -- GHC 6.3+ has support for console events on Windows
  -- NOTE: running GHCi under a bash shell for some reason requires
  -- you to press Ctrl-Break rather than Ctrl-C to provoke
  -- an interrupt.  Ctrl-C is getting blocked somewhere, I don't know
  -- why --SDM 17/12/2004
  let sig_handler ControlC = interrupt
      sig_handler Break    = interrupt
      sig_handler _        = return ()

  installHandler (Catch sig_handler)
  return ()
#endif

{-# NOINLINE interruptTargetThread #-}
interruptTargetThread :: MVar [ThreadId]
interruptTargetThread = unsafePerformIO (newMVar [])
\end{code}
