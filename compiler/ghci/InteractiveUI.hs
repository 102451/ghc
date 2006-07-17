{-# OPTIONS -#include "Linker.h" #-}
-----------------------------------------------------------------------------
--
-- GHC Interactive User Interface
--
-- (c) The GHC Team 2005
--
-----------------------------------------------------------------------------
module InteractiveUI ( 
	interactiveUI,
	ghciWelcomeMsg
   ) where

#include "HsVersions.h"

#if defined(GHCI) && defined(BREAKPOINT)
import GHC.Exts         ( Int(..), Ptr(..), int2Addr# )
import Foreign.StablePtr ( deRefStablePtr, castPtrToStablePtr )
import System.IO.Unsafe ( unsafePerformIO )
import Var              ( Id, globaliseId, idName, idType )
import HscTypes         ( Session(..), InteractiveContext(..), HscEnv(..)
                        , extendTypeEnvWithIds )
import RdrName          ( extendLocalRdrEnv, mkRdrUnqual, lookupLocalRdrEnv )
import NameEnv          ( delListFromNameEnv )
import TcType           ( tidyTopType )
import qualified Id     ( setIdType )
import IdInfo           ( GlobalIdDetails(..) )
import Linker           ( HValue, extendLinkEnv, withExtendedLinkEnv,initDynLinker  )
import PrelNames        ( breakpointJumpName, breakpointCondJumpName )
#endif

-- The GHC interface
import qualified GHC
import GHC		( Session, verbosity, dopt, DynFlag(..), Target(..),
			  TargetId(..), DynFlags(..),
			  pprModule, Type, Module, SuccessFlag(..),
			  TyThing(..), Name, LoadHowMuch(..), Phase,
			  GhcException(..), showGhcException,
			  CheckedModule(..), SrcLoc )
import DynFlags         ( allFlags )
import Packages		( PackageState(..) )
import PackageConfig	( InstalledPackageInfo(..) )
import UniqFM		( eltsUFM )
import PprTyThing
import Outputable

-- for createtags (should these come via GHC?)
import Module		( moduleString )
import Name		( nameSrcLoc, nameModule, nameOccName )
import OccName		( pprOccName )
import SrcLoc		( isGoodSrcLoc, srcLocFile, srcLocLine, srcLocCol )

-- Other random utilities
import Digraph		( flattenSCCs )
import BasicTypes	( failed, successIf )
import Panic 		( panic, installSignalHandlers )
import Config
import StaticFlags	( opt_IgnoreDotGhci )
import Linker		( showLinkerState )
import Util		( removeSpaces, handle, global, toArgs,
			  looksLikeModuleName, prefixMatch, sortLe )

#ifndef mingw32_HOST_OS
import System.Posix
#if __GLASGOW_HASKELL__ > 504
	hiding (getEnv)
#endif
#else
import GHC.ConsoleHandler ( flushConsole )
import System.Win32	  ( setConsoleCP, setConsoleOutputCP )
#endif

#ifdef USE_READLINE
import Control.Concurrent	( yield )	-- Used in readline loop
import System.Console.Readline as Readline
#endif

--import SystemExts

import Control.Exception as Exception
import Data.Dynamic
-- import Control.Concurrent

import Numeric
import Data.List
import Data.Int		( Int64 )
import Data.Maybe	( isJust, fromMaybe, catMaybes )
import System.Cmd
import System.CPUTime
import System.Environment
import System.Exit	( exitWith, ExitCode(..) )
import System.Directory
import System.IO
import System.IO.Error as IO
import Data.Char
import Control.Monad as Monad
import Foreign.StablePtr	( newStablePtr )
import Text.Printf

import GHC.Exts		( unsafeCoerce# )
import GHC.IOBase	( IOErrorType(InvalidArgument) )

import Data.IORef	( IORef, newIORef, readIORef, writeIORef )

import System.Posix.Internals ( setNonBlockingFD )

-----------------------------------------------------------------------------

ghciWelcomeMsg =
 "   ___         ___ _\n"++
 "  / _ \\ /\\  /\\/ __(_)\n"++
 " / /_\\// /_/ / /  | |      GHC Interactive, version " ++ cProjectVersion ++ ", for Haskell 98.\n"++
 "/ /_\\\\/ __  / /___| |      http://www.haskell.org/ghc/\n"++
 "\\____/\\/ /_/\\____/|_|      Type :? for help.\n"

type Command = (String, String -> GHCi Bool, Bool, String -> IO [String])
cmdName (n,_,_,_) = n

GLOBAL_VAR(commands, builtin_commands, [Command])

builtin_commands :: [Command]
builtin_commands = [
  ("add",	keepGoingPaths addModule,	False, completeFilename),
  ("browse",    keepGoing browseCmd,		False, completeModule),
  ("cd",    	keepGoing changeDirectory, 	False, completeFilename),
  ("def",	keepGoing defineMacro,		False, completeIdentifier),
  ("help",	keepGoing help,			False, completeNone),
  ("?",		keepGoing help,			False, completeNone),
  ("info",      keepGoing info,			False, completeIdentifier),
  ("load",	keepGoingPaths loadModule_,	False, completeHomeModuleOrFile),
  ("module",	keepGoing setContext,		False, completeModule),
  ("main",	keepGoing runMain,		False, completeIdentifier),
  ("reload",	keepGoing reloadModule,		False, completeNone),
  ("check",	keepGoing checkModule,		False, completeHomeModule),
  ("set",	keepGoing setCmd,		True,  completeSetOptions),
  ("show",	keepGoing showCmd,		False, completeNone),
  ("etags",	keepGoing createETagsFileCmd,	False, completeFilename),
  ("ctags",	keepGoing createCTagsFileCmd, 	False, completeFilename),
  ("type",	keepGoing typeOfExpr,		False, completeIdentifier),
  ("kind",	keepGoing kindOfType,		False, completeIdentifier),
  ("unset",	keepGoing unsetOptions,		True,  completeSetOptions),
  ("undef",     keepGoing undefineMacro,	False, completeMacro),
  ("quit",	quit,				False, completeNone)
  ]

keepGoing :: (String -> GHCi ()) -> (String -> GHCi Bool)
keepGoing a str = a str >> return False

keepGoingPaths :: ([FilePath] -> GHCi ()) -> (String -> GHCi Bool)
keepGoingPaths a str = a (toArgs str) >> return False

shortHelpText = "use :? for help.\n"

-- NOTE: spaces at the end of each line to workaround CPP/string gap bug.
helpText =
 " Commands available from the prompt:\n" ++
 "\n" ++
 "   <stmt>                      evaluate/run <stmt>\n" ++
 "   :add <filename> ...         add module(s) to the current target set\n" ++
 "   :browse [*]<module>         display the names defined by <module>\n" ++
 "   :cd <dir>                   change directory to <dir>\n" ++
 "   :def <cmd> <expr>           define a command :<cmd>\n" ++
 "   :help, :?                   display this list of commands\n" ++
 "   :info [<name> ...]          display information about the given names\n" ++
 "   :load <filename> ...        load module(s) and their dependents\n" ++
 "   :module [+/-] [*]<mod> ...  set the context for expression evaluation\n" ++
 "   :main [<arguments> ...]     run the main function with the given arguments\n" ++
 "   :reload                     reload the current module set\n" ++
 "\n" ++
 "   :set <option> ...           set options\n" ++
 "   :set args <arg> ...         set the arguments returned by System.getArgs\n" ++
 "   :set prog <progname>        set the value returned by System.getProgName\n" ++
 "   :set prompt <prompt>        set the prompt used in GHCi\n" ++
 "\n" ++
 "   :show modules               show the currently loaded modules\n" ++
 "   :show bindings              show the current bindings made at the prompt\n" ++
 "\n" ++
 "   :ctags [<file>]             create tags file for Vi (default: \"tags\")\n" ++
 "   :etags [<file>]           	 create tags file for Emacs (defauilt: \"TAGS\")\n" ++
 "   :type <expr>                show the type of <expr>\n" ++
 "   :kind <type>                show the kind of <type>\n" ++
 "   :undef <cmd>                undefine user-defined command :<cmd>\n" ++
 "   :unset <option> ...         unset options\n" ++
 "   :quit                       exit GHCi\n" ++
 "   :!<command>                 run the shell command <command>\n" ++
 "\n" ++
 " Options for ':set' and ':unset':\n" ++
 "\n" ++
 "    +r            revert top-level expressions after each evaluation\n" ++
 "    +s            print timing/memory stats after each evaluation\n" ++
 "    +t            print type after evaluation\n" ++
 "    -<flags>      most GHC command line flags can also be set here\n" ++
 "                         (eg. -v2, -fglasgow-exts, etc.)\n"


#if defined(GHCI) && defined(BREAKPOINT)
globaliseAndTidy :: Id -> Id
globaliseAndTidy id
-- Give the Id a Global Name, and tidy its type
  = Id.setIdType (globaliseId VanillaGlobal id) tidy_type
  where
    tidy_type = tidyTopType (idType id)


printScopeMsg :: Session -> String -> [Id] -> IO ()
printScopeMsg session location ids
    = GHC.getPrintUnqual session >>= \unqual ->
      printForUser stdout unqual $
        text "Local bindings in scope:" $$
        nest 2 (pprWithCommas showId ids)
    where showId id = ppr (idName id) <+> dcolon <+> ppr (idType id)

jumpCondFunction :: Session -> Int -> [HValue] -> String -> Bool -> b -> b
jumpCondFunction session ptr hValues location True b = b
jumpCondFunction session ptr hValues location False b
    = jumpFunction session ptr hValues location b

jumpFunction :: Session -> Int -> [HValue] -> String -> b -> b
jumpFunction session@(Session ref) (I# idsPtr) hValues location b
    = unsafePerformIO $
      do ids <- deRefStablePtr (castPtrToStablePtr (Ptr (int2Addr# idsPtr)))
         let names = map idName ids
         ASSERT (length names == length hValues) return ()
         printScopeMsg session location ids
         hsc_env <- readIORef ref

         let ictxt = hsc_IC hsc_env
             global_ids = map globaliseAndTidy ids
             rn_env   = ic_rn_local_env ictxt
             type_env = ic_type_env ictxt
             bound_names = map idName global_ids
             new_rn_env  = extendLocalRdrEnv rn_env bound_names
		-- Remove any shadowed bindings from the type_env;
		-- they are inaccessible but might, I suppose, cause 
		-- a space leak if we leave them there
             shadowed = [ n | name <- bound_names,
                          let rdr_name = mkRdrUnqual (nameOccName name),
                          Just n <- [lookupLocalRdrEnv rn_env rdr_name] ]
             filtered_type_env = delListFromNameEnv type_env shadowed
             new_type_env = extendTypeEnvWithIds filtered_type_env global_ids
             new_ic = ictxt { ic_rn_local_env = new_rn_env, 
		  	      ic_type_env     = new_type_env }
         writeIORef ref (hsc_env { hsc_IC = new_ic })
         is_tty <- hIsTerminalDevice stdin
         withExtendedLinkEnv (zip names hValues) $
           startGHCi (interactiveLoop is_tty True)
                     GHCiState{ progname = "<interactive>",
                                args = [],
                                prompt = location++"> ",
                                session = session,
                                options = [] }
         writeIORef ref hsc_env
         putStrLn $ "Returning to normal execution..."
         return b
#endif

interactiveUI :: Session -> [(FilePath, Maybe Phase)] -> Maybe String -> IO ()
interactiveUI session srcs maybe_expr = do
#if defined(GHCI) && defined(BREAKPOINT)
   initDynLinker =<< GHC.getSessionDynFlags session
   extendLinkEnv [(breakpointJumpName,unsafeCoerce# (jumpFunction session))
                 ,(breakpointCondJumpName,unsafeCoerce# (jumpCondFunction session))]
#endif
   -- HACK! If we happen to get into an infinite loop (eg the user
   -- types 'let x=x in x' at the prompt), then the thread will block
   -- on a blackhole, and become unreachable during GC.  The GC will
   -- detect that it is unreachable and send it the NonTermination
   -- exception.  However, since the thread is unreachable, everything
   -- it refers to might be finalized, including the standard Handles.
   -- This sounds like a bug, but we don't have a good solution right
   -- now.
   newStablePtr stdin
   newStablePtr stdout
   newStablePtr stderr

   hFlush stdout
   hSetBuffering stdout NoBuffering

	-- Initialise buffering for the *interpreted* I/O system
   initInterpBuffering session

	-- We don't want the cmd line to buffer any input that might be
	-- intended for the program, so unbuffer stdin.
   hSetBuffering stdin NoBuffering

	-- initial context is just the Prelude
   GHC.setContext session [] [prelude_mod]

#ifdef USE_READLINE
   Readline.initialize
   Readline.setAttemptedCompletionFunction (Just completeWord)
   --Readline.parseAndBind "set show-all-if-ambiguous 1"

   let symbols = "!#$%&*+/<=>?@\\^|-~"
       specials = "(),;[]`{}"
       spaces = " \t\n"
       word_break_chars = spaces ++ specials ++ symbols

   Readline.setBasicWordBreakCharacters word_break_chars
   Readline.setCompleterWordBreakCharacters word_break_chars
#endif

   startGHCi (runGHCi srcs maybe_expr)
	GHCiState{ progname = "<interactive>",
		   args = [],
                   prompt = "%s> ",
		   session = session,
		   options = [] }

#ifdef USE_READLINE
   Readline.resetTerminal Nothing
#endif

   return ()

runGHCi :: [(FilePath, Maybe Phase)] -> Maybe String -> GHCi ()
runGHCi paths maybe_expr = do
  let read_dot_files = not opt_IgnoreDotGhci

  when (read_dot_files) $ do
    -- Read in ./.ghci.
    let file = "./.ghci"
    exists <- io (doesFileExist file)
    when exists $ do
       dir_ok  <- io (checkPerms ".")
       file_ok <- io (checkPerms file)
       when (dir_ok && file_ok) $ do
  	  either_hdl <- io (IO.try (openFile "./.ghci" ReadMode))
  	  case either_hdl of
  	     Left e    -> return ()
  	     Right hdl -> fileLoop hdl False
    
  when (read_dot_files) $ do
    -- Read in $HOME/.ghci
    either_dir <- io (IO.try (getEnv "HOME"))
    case either_dir of
       Left e -> return ()
       Right dir -> do
  	  cwd <- io (getCurrentDirectory)
  	  when (dir /= cwd) $ do
  	     let file = dir ++ "/.ghci"
  	     ok <- io (checkPerms file)
  	     when ok $ do
  	       either_hdl <- io (IO.try (openFile file ReadMode))
  	       case either_hdl of
  		  Left e    -> return ()
  		  Right hdl -> fileLoop hdl False

  -- Perform a :load for files given on the GHCi command line
  -- When in -e mode, if the load fails then we want to stop
  -- immediately rather than going on to evaluate the expression.
  when (not (null paths)) $ do
     ok <- ghciHandle (\e -> do showException e; return Failed) $ 
		loadModule paths
     when (isJust maybe_expr && failed ok) $
	io (exitWith (ExitFailure 1))

  -- if verbosity is greater than 0, or we are connected to a
  -- terminal, display the prompt in the interactive loop.
  is_tty <- io (hIsTerminalDevice stdin)
  dflags <- getDynFlags
  let show_prompt = verbosity dflags > 0 || is_tty

  case maybe_expr of
	Nothing -> 
          do
#if defined(mingw32_HOST_OS)
            -- The win32 Console API mutates the first character of 
            -- type-ahead when reading from it in a non-buffered manner. Work
            -- around this by flushing the input buffer of type-ahead characters,
            -- but only if stdin is available.
            flushed <- io (IO.try (GHC.ConsoleHandler.flushConsole stdin))
            case flushed of 
   	     Left err | isDoesNotExistError err -> return ()
   		      | otherwise -> io (ioError err)
   	     Right () -> return ()
#endif
	    -- initialise the console if necessary
	    io setUpConsole

	    -- enter the interactive loop
	    interactiveLoop is_tty show_prompt
	Just expr -> do
	    -- just evaluate the expression we were given
	    runCommandEval expr
	    return ()

  -- and finally, exit
  io $ do when (verbosity dflags > 0) $ putStrLn "Leaving GHCi."


interactiveLoop is_tty show_prompt =
  -- Ignore ^C exceptions caught here
  ghciHandleDyn (\e -> case e of 
			Interrupted -> do
#if defined(mingw32_HOST_OS)
				io (putStrLn "")
#endif
				interactiveLoop is_tty show_prompt
			_other      -> return ()) $ 

  ghciUnblock $ do -- unblock necessary if we recursed from the 
		   -- exception handler above.

  -- read commands from stdin
#ifdef USE_READLINE
  if (is_tty) 
	then readlineLoop
	else fileLoop stdin show_prompt
#else
  fileLoop stdin show_prompt
#endif


-- NOTE: We only read .ghci files if they are owned by the current user,
-- and aren't world writable.  Otherwise, we could be accidentally 
-- running code planted by a malicious third party.

-- Furthermore, We only read ./.ghci if . is owned by the current user
-- and isn't writable by anyone else.  I think this is sufficient: we
-- don't need to check .. and ../.. etc. because "."  always refers to
-- the same directory while a process is running.

checkPerms :: String -> IO Bool
checkPerms name =
#ifdef mingw32_HOST_OS
  return True
#else
  Util.handle (\_ -> return False) $ do
     st <- getFileStatus name
     me <- getRealUserID
     if fileOwner st /= me then do
   	putStrLn $ "WARNING: " ++ name ++ " is owned by someone else, IGNORING!"
   	return False
      else do
   	let mode =  fileMode st
   	if (groupWriteMode == (mode `intersectFileModes` groupWriteMode))
   	   || (otherWriteMode == (mode `intersectFileModes` otherWriteMode)) 
   	   then do
   	       putStrLn $ "*** WARNING: " ++ name ++ 
   			  " is writable by someone else, IGNORING!"
   	       return False
   	  else return True
#endif

fileLoop :: Handle -> Bool -> GHCi ()
fileLoop hdl show_prompt = do
   session <- getSession
   (mod,imports) <- io (GHC.getContext session)
   st <- getGHCiState
   when show_prompt (io (putStr (mkPrompt mod imports (prompt st))))
   l <- io (IO.try (hGetLine hdl))
   case l of
	Left e | isEOFError e		   -> return ()
	       | InvalidArgument <- etype  -> return ()
	       | otherwise		   -> io (ioError e)
		where etype = ioeGetErrorType e
		-- treat InvalidArgument in the same way as EOF:
		-- this can happen if the user closed stdin, or
		-- perhaps did getContents which closes stdin at
		-- EOF.
	Right l -> 
	  case removeSpaces l of
            "" -> fileLoop hdl show_prompt
	    l  -> do quit <- runCommand l
                     if quit then return () else fileLoop hdl show_prompt

stringLoop :: [String] -> GHCi Bool{-True: we quit-}
stringLoop [] = return False
stringLoop (s:ss) = do
   case removeSpaces s of
	"" -> stringLoop ss
	l  -> do quit <- runCommand l
                 if quit then return True else stringLoop ss

mkPrompt toplevs exports prompt
  = showSDoc $ f prompt
    where
        f ('%':'s':xs) = perc_s <> f xs
        f ('%':'%':xs) = char '%' <> f xs
        f (x:xs) = char x <> f xs
        f [] = empty
    
        perc_s = hsep (map (\m -> char '*' <> pprModule m) toplevs) <+>
                 hsep (map pprModule exports)
             

#ifdef USE_READLINE
readlineLoop :: GHCi ()
readlineLoop = do
   session <- getSession
   (mod,imports) <- io (GHC.getContext session)
   io yield
   saveSession -- for use by completion
   st <- getGHCiState
   l <- io (readline (mkPrompt mod imports (prompt st))
	  	`finally` setNonBlockingFD 0)
		-- readline sometimes puts stdin into blocking mode,
		-- so we need to put it back for the IO library
   splatSavedSession
   case l of
	Nothing -> return ()
	Just l  ->
	  case removeSpaces l of
	    "" -> readlineLoop
	    l  -> do
        	  io (addHistory l)
  	  	  quit <- runCommand l
          	  if quit then return () else readlineLoop
#endif

runCommand :: String -> GHCi Bool
runCommand c = ghciHandle handler (doCommand c)
  where 
    doCommand (':' : command) = specialCommand command
    doCommand stmt
       = do timeIt (do nms <- runStmt stmt; finishEvalExpr nms)
            return False

-- This version is for the GHC command-line option -e.  The only difference
-- from runCommand is that it catches the ExitException exception and
-- exits, rather than printing out the exception.
runCommandEval c = ghciHandle handleEval (doCommand c)
  where 
    handleEval (ExitException code) = io (exitWith code)
    handleEval e                    = do handler e
				         io (exitWith (ExitFailure 1))

    doCommand (':' : command) = specialCommand command
    doCommand stmt
       = do nms <- runStmt stmt
	    case nms of 
		Nothing -> io (exitWith (ExitFailure 1))
		  -- failure to run the command causes exit(1) for ghc -e.
		_       -> finishEvalExpr nms

-- This is the exception handler for exceptions generated by the
-- user's code; it normally just prints out the exception.  The
-- handler must be recursive, in case showing the exception causes
-- more exceptions to be raised.
--
-- Bugfix: if the user closed stdout or stderr, the flushing will fail,
-- raising another exception.  We therefore don't put the recursive
-- handler arond the flushing operation, so if stderr is closed
-- GHCi will just die gracefully rather than going into an infinite loop.
handler :: Exception -> GHCi Bool
handler exception = do
  flushInterpBuffers
  io installSignalHandlers
  ghciHandle handler (showException exception >> return False)

showException (DynException dyn) =
  case fromDynamic dyn of
    Nothing               -> io (putStrLn ("*** Exception: (unknown)"))
    Just Interrupted      -> io (putStrLn "Interrupted.")
    Just (CmdLineError s) -> io (putStrLn s)	 -- omit the location for CmdLineError
    Just ph@PhaseFailed{} -> io (putStrLn (showGhcException ph "")) -- ditto
    Just other_ghc_ex     -> io (print other_ghc_ex)

showException other_exception
  = io (putStrLn ("*** Exception: " ++ show other_exception))

runStmt :: String -> GHCi (Maybe [Name])
runStmt stmt
 | null (filter (not.isSpace) stmt) = return (Just [])
 | otherwise
 = do st <- getGHCiState
      session <- getSession
      result <- io $ withProgName (progname st) $ withArgs (args st) $
	     	     GHC.runStmt session stmt
      case result of
	GHC.RunFailed      -> return Nothing
	GHC.RunException e -> throw e  -- this is caught by runCommand(Eval)
	GHC.RunOk names    -> return (Just names)

-- possibly print the type and revert CAFs after evaluating an expression
finishEvalExpr mb_names
 = do b <- isOptionSet ShowType
      session <- getSession
      case mb_names of
	Nothing    -> return ()      
	Just names -> when b (mapM_ (showTypeOfName session) names)

      flushInterpBuffers
      io installSignalHandlers
      b <- isOptionSet RevertCAFs
      io (when b revertCAFs)
      return True

showTypeOfName :: Session -> Name -> GHCi ()
showTypeOfName session n
   = do maybe_tything <- io (GHC.lookupName session n)
	case maybe_tything of
	  Nothing    -> return ()
	  Just thing -> showTyThing thing

showForUser :: SDoc -> GHCi String
showForUser doc = do
  session <- getSession
  unqual <- io (GHC.getPrintUnqual session)
  return $! showSDocForUser unqual doc

specialCommand :: String -> GHCi Bool
specialCommand ('!':str) = shellEscape (dropWhile isSpace str)
specialCommand str = do
  let (cmd,rest) = break isSpace str
  maybe_cmd <- io (lookupCommand cmd)
  case maybe_cmd of
    Nothing -> io (hPutStr stdout ("unknown command ':" ++ cmd ++ "'\n" 
		                    ++ shortHelpText) >> return False)
    Just (_,f,_,_) -> f (dropWhile isSpace rest)

lookupCommand :: String -> IO (Maybe Command)
lookupCommand str = do
  cmds <- readIORef commands
  -- look for exact match first, then the first prefix match
  case [ c | c <- cmds, str == cmdName c ] of
     c:_ -> return (Just c)
     [] -> case [ c | c@(s,_,_,_) <- cmds, prefixMatch str s ] of
     		[] -> return Nothing
     		c:_ -> return (Just c)

-----------------------------------------------------------------------------
-- To flush buffers for the *interpreted* computation we need
-- to refer to *its* stdout/stderr handles

GLOBAL_VAR(flush_interp,       error "no flush_interp", IO ())
GLOBAL_VAR(turn_off_buffering, error "no flush_stdout", IO ())

no_buf_cmd = "System.IO.hSetBuffering System.IO.stdout System.IO.NoBuffering" ++
	     " Prelude.>> System.IO.hSetBuffering System.IO.stderr System.IO.NoBuffering"
flush_cmd  = "System.IO.hFlush System.IO.stdout Prelude.>> System.IO.hFlush IO.stderr"

initInterpBuffering :: Session -> IO ()
initInterpBuffering session
 = do maybe_hval <- GHC.compileExpr session no_buf_cmd
	
      case maybe_hval of
	Just hval -> writeIORef turn_off_buffering (unsafeCoerce# hval :: IO ())
	other	  -> panic "interactiveUI:setBuffering"
	
      maybe_hval <- GHC.compileExpr session flush_cmd
      case maybe_hval of
	Just hval -> writeIORef flush_interp (unsafeCoerce# hval :: IO ())
	_         -> panic "interactiveUI:flush"

      turnOffBuffering	-- Turn it off right now

      return ()


flushInterpBuffers :: GHCi ()
flushInterpBuffers
 = io $ do Monad.join (readIORef flush_interp)
           return ()

turnOffBuffering :: IO ()
turnOffBuffering
 = do Monad.join (readIORef turn_off_buffering)
      return ()

-----------------------------------------------------------------------------
-- Commands

help :: String -> GHCi ()
help _ = io (putStr helpText)

info :: String -> GHCi ()
info "" = throwDyn (CmdLineError "syntax: ':i <thing-you-want-info-about>'")
info s  = do { let names = words s
	     ; session <- getSession
	     ; dflags <- getDynFlags
	     ; let exts = dopt Opt_GlasgowExts dflags
	     ; mapM_ (infoThing exts session) names }
  where
    infoThing exts session str = io $ do
	names <- GHC.parseName session str
	let filtered = filterOutChildren names
	mb_stuffs <- mapM (GHC.getInfo session) filtered
	unqual <- GHC.getPrintUnqual session
	putStrLn (showSDocForUser unqual $
     		   vcat (intersperse (text "") $
		   [ pprInfo exts stuff | Just stuff <-  mb_stuffs ]))

  -- Filter out names whose parent is also there Good
  -- example is '[]', which is both a type and data
  -- constructor in the same type
filterOutChildren :: [Name] -> [Name]
filterOutChildren names = filter (not . parent_is_there) names
 where parent_is_there n 
	 | Just p <- GHC.nameParent_maybe n = p `elem` names
	 | otherwise		           = False

pprInfo exts (thing, fixity, insts)
  =  pprTyThingInContextLoc exts thing 
  $$ show_fixity fixity
  $$ vcat (map GHC.pprInstance insts)
  where
    show_fixity fix 
	| fix == GHC.defaultFixity = empty
	| otherwise		   = ppr fix <+> ppr (GHC.getName thing)

-----------------------------------------------------------------------------
-- Commands

runMain :: String -> GHCi ()
runMain args = do
  let ss = concat $ intersperse "," (map (\ s -> ('"':s)++"\"") (toArgs args))
  runCommand $ '[': ss ++ "] `System.Environment.withArgs` main"
  return ()

addModule :: [FilePath] -> GHCi ()
addModule files = do
  io (revertCAFs)			-- always revert CAFs on load/add.
  files <- mapM expandPath files
  targets <- mapM (\m -> io (GHC.guessTarget m Nothing)) files
  session <- getSession
  io (mapM_ (GHC.addTarget session) targets)
  ok <- io (GHC.load session LoadAllTargets)
  afterLoad ok session

changeDirectory :: String -> GHCi ()
changeDirectory dir = do
  session <- getSession
  graph <- io (GHC.getModuleGraph session)
  when (not (null graph)) $
	io $ putStr "Warning: changing directory causes all loaded modules to be unloaded,\nbecause the search path has changed.\n"
  io (GHC.setTargets session [])
  io (GHC.load session LoadAllTargets)
  setContextAfterLoad session []
  io (GHC.workingDirectoryChanged session)
  dir <- expandPath dir
  io (setCurrentDirectory dir)

defineMacro :: String -> GHCi ()
defineMacro s = do
  let (macro_name, definition) = break isSpace s
  cmds <- io (readIORef commands)
  if (null macro_name) 
	then throwDyn (CmdLineError "invalid macro name") 
	else do
  if (macro_name `elem` map cmdName cmds)
	then throwDyn (CmdLineError 
		("command '" ++ macro_name ++ "' is already defined"))
	else do

  -- give the expression a type signature, so we can be sure we're getting
  -- something of the right type.
  let new_expr = '(' : definition ++ ") :: String -> IO String"

  -- compile the expression
  cms <- getSession
  maybe_hv <- io (GHC.compileExpr cms new_expr)
  case maybe_hv of
     Nothing -> return ()
     Just hv -> io (writeIORef commands --
		    (cmds ++ [(macro_name, runMacro hv, False, completeNone)]))

runMacro :: GHC.HValue{-String -> IO String-} -> String -> GHCi Bool
runMacro fun s = do
  str <- io ((unsafeCoerce# fun :: String -> IO String) s)
  stringLoop (lines str)

undefineMacro :: String -> GHCi ()
undefineMacro macro_name = do
  cmds <- io (readIORef commands)
  if (macro_name `elem` map cmdName builtin_commands) 
	then throwDyn (CmdLineError
		("command '" ++ macro_name ++ "' cannot be undefined"))
	else do
  if (macro_name `notElem` map cmdName cmds) 
	then throwDyn (CmdLineError 
		("command '" ++ macro_name ++ "' not defined"))
	else do
  io (writeIORef commands (filter ((/= macro_name) . cmdName) cmds))


loadModule :: [(FilePath, Maybe Phase)] -> GHCi SuccessFlag
loadModule fs = timeIt (loadModule' fs)

loadModule_ :: [FilePath] -> GHCi ()
loadModule_ fs = do loadModule (zip fs (repeat Nothing)); return ()

loadModule' :: [(FilePath, Maybe Phase)] -> GHCi SuccessFlag
loadModule' files = do
  session <- getSession

  -- unload first
  io (GHC.setTargets session [])
  io (GHC.load session LoadAllTargets)

  -- expand tildes
  let (filenames, phases) = unzip files
  exp_filenames <- mapM expandPath filenames
  let files' = zip exp_filenames phases
  targets <- io (mapM (uncurry GHC.guessTarget) files')

  -- NOTE: we used to do the dependency anal first, so that if it
  -- fails we didn't throw away the current set of modules.  This would
  -- require some re-working of the GHC interface, so we'll leave it
  -- as a ToDo for now.

  io (GHC.setTargets session targets)
  ok <- io (GHC.load session LoadAllTargets)
  afterLoad ok session
  return ok

checkModule :: String -> GHCi ()
checkModule m = do
  let modl = GHC.mkModule m
  session <- getSession
  result <- io (GHC.checkModule session modl)
  case result of
    Nothing -> io $ putStrLn "Nothing"
    Just r  -> io $ putStrLn (showSDoc (
	case checkedModuleInfo r of
	   Just cm | Just scope <- GHC.modInfoTopLevelScope cm -> 
		let
		    (local,global) = partition ((== modl) . GHC.nameModule) scope
		in
			(text "global names: " <+> ppr global) $$
		        (text "local  names: " <+> ppr local)
	   _ -> empty))
  afterLoad (successIf (isJust result)) session

reloadModule :: String -> GHCi ()
reloadModule "" = do
  io (revertCAFs)		-- always revert CAFs on reload.
  session <- getSession
  ok <- io (GHC.load session LoadAllTargets)
  afterLoad ok session
reloadModule m = do
  io (revertCAFs)		-- always revert CAFs on reload.
  session <- getSession
  ok <- io (GHC.load session (LoadUpTo (GHC.mkModule m)))
  afterLoad ok session

afterLoad ok session = do
  io (revertCAFs)  -- always revert CAFs on load.
  graph <- io (GHC.getModuleGraph session)
  graph' <- filterM (io . GHC.isLoaded session . GHC.ms_mod) graph
  setContextAfterLoad session graph'
  modulesLoadedMsg ok (map GHC.ms_mod graph')
#if defined(GHCI) && defined(BREAKPOINT)
  io (extendLinkEnv [(breakpointJumpName,unsafeCoerce# (jumpFunction session))
                    ,(breakpointCondJumpName,unsafeCoerce# (jumpCondFunction session))])
#endif

setContextAfterLoad session [] = do
  io (GHC.setContext session [] [prelude_mod])
setContextAfterLoad session ms = do
  -- load a target if one is available, otherwise load the topmost module.
  targets <- io (GHC.getTargets session)
  case [ m | Just m <- map (findTarget ms) targets ] of
	[]    -> 
	  let graph' = flattenSCCs (GHC.topSortModuleGraph True ms Nothing) in
	  load_this (last graph')	  
	(m:_) -> 
	  load_this m
 where
   findTarget ms t
    = case filter (`matches` t) ms of
	[]    -> Nothing
	(m:_) -> Just m

   summary `matches` Target (TargetModule m) _
	= GHC.ms_mod summary == m
   summary `matches` Target (TargetFile f _) _ 
	| Just f' <- GHC.ml_hs_file (GHC.ms_location summary)	= f == f'
   summary `matches` target
	= False

   load_this summary | m <- GHC.ms_mod summary = do
	b <- io (GHC.moduleIsInterpreted session m)
	if b then io (GHC.setContext session [m] []) 
       	     else io (GHC.setContext session []  [prelude_mod,m])


modulesLoadedMsg :: SuccessFlag -> [Module] -> GHCi ()
modulesLoadedMsg ok mods = do
  dflags <- getDynFlags
  when (verbosity dflags > 0) $ do
   let mod_commas 
	| null mods = text "none."
	| otherwise = hsep (
	    punctuate comma (map pprModule mods)) <> text "."
   case ok of
    Failed ->
       io (putStrLn (showSDoc (text "Failed, modules loaded: " <> mod_commas)))
    Succeeded  ->
       io (putStrLn (showSDoc (text "Ok, modules loaded: " <> mod_commas)))


typeOfExpr :: String -> GHCi ()
typeOfExpr str 
  = do cms <- getSession
       maybe_ty <- io (GHC.exprType cms str)
       case maybe_ty of
	  Nothing -> return ()
	  Just ty -> do ty' <- cleanType ty
			tystr <- showForUser (ppr ty')
		        io (putStrLn (str ++ " :: " ++ tystr))

kindOfType :: String -> GHCi ()
kindOfType str 
  = do cms <- getSession
       maybe_ty <- io (GHC.typeKind cms str)
       case maybe_ty of
	  Nothing    -> return ()
	  Just ty    -> do tystr <- showForUser (ppr ty)
		           io (putStrLn (str ++ " :: " ++ tystr))

quit :: String -> GHCi Bool
quit _ = return True

shellEscape :: String -> GHCi Bool
shellEscape str = io (system str >> return False)

-----------------------------------------------------------------------------
-- create tags file for currently loaded modules.

createETagsFileCmd, createCTagsFileCmd :: String -> GHCi ()

createCTagsFileCmd ""   = ghciCreateTagsFile CTags "tags"
createCTagsFileCmd file = ghciCreateTagsFile CTags file

createETagsFileCmd ""    = ghciCreateTagsFile ETags "TAGS"
createETagsFileCmd file  = ghciCreateTagsFile ETags file

data TagsKind = ETags | CTags

ghciCreateTagsFile :: TagsKind -> FilePath -> GHCi ()
ghciCreateTagsFile kind file = do
  session <- getSession
  io $ createTagsFile session kind file

-- ToDo: 
-- 	- remove restriction that all modules must be interpreted
--	  (problem: we don't know source locations for entities unless
--	  we compiled the module.
--
--	- extract createTagsFile so it can be used from the command-line
--	  (probably need to fix first problem before this is useful).
--
createTagsFile :: Session -> TagsKind -> FilePath -> IO ()
createTagsFile session tagskind tagFile = do
  graph <- GHC.getModuleGraph session
  let ms = map GHC.ms_mod graph
      tagModule m = do 
        is_interpreted <- GHC.moduleIsInterpreted session m
        -- should we just skip these?
        when (not is_interpreted) $
          throwDyn (CmdLineError ("module '" ++ moduleString m ++ "' is not interpreted"))

        mbModInfo <- GHC.getModuleInfo session m
        let unqual 
	      | Just modinfo <- mbModInfo,
		Just unqual <- GHC.modInfoPrintUnqualified modinfo = unqual
	      | otherwise = GHC.alwaysQualify

        case mbModInfo of 
          Just modInfo -> return $! listTags unqual modInfo 
          _            -> return []

  mtags <- mapM tagModule ms
  either_res <- collateAndWriteTags tagskind tagFile $ concat mtags
  case either_res of
    Left e  -> hPutStrLn stderr $ ioeGetErrorString e
    Right _ -> return ()

listTags :: PrintUnqualified -> GHC.ModuleInfo -> [TagInfo]
listTags unqual modInfo =
	   [ tagInfo unqual name loc 
           | name <- GHC.modInfoExports modInfo
           , let loc = nameSrcLoc name
           , isGoodSrcLoc loc
           ]

type TagInfo = (String -- tag name
               ,String -- file name
               ,Int    -- line number
               ,Int    -- column number
               )

-- get tag info, for later translation into Vim or Emacs style
tagInfo :: PrintUnqualified -> Name -> SrcLoc -> TagInfo
tagInfo unqual name loc
    = ( showSDocForUser unqual $ pprOccName (nameOccName name)
      , showSDocForUser unqual $ ftext (srcLocFile loc)
      , srcLocLine loc
      , srcLocCol loc
      )

collateAndWriteTags :: TagsKind -> FilePath -> [TagInfo] -> IO (Either IOError ())
collateAndWriteTags CTags file tagInfos = do -- ctags style, Vim et al
  let tags = unlines $ sortLe (<=) $ nub $ map showTag tagInfos
  IO.try (writeFile file tags)
collateAndWriteTags ETags file tagInfos = do -- etags style, Emacs/XEmacs
  let byFile op (_,f1,_,_) (_,f2,_,_) = f1 `op` f2
      groups = groupBy (byFile (==)) $ sortLe (byFile (<=)) tagInfos
  tagGroups <- mapM tagFileGroup groups 
  IO.try (writeFile file $ concat tagGroups)
  where
    tagFileGroup group@[] = throwDyn (CmdLineError "empty tag file group??")
    tagFileGroup group@((_,fileName,_,_):_) = do
      file <- readFile fileName -- need to get additional info from sources..
      let byLine (_,_,l1,_) (_,_,l2,_) = l1 <= l2
          sortedGroup = sortLe byLine group
          tags = unlines $ perFile sortedGroup 1 0 $ lines file
      return $ "\x0c\n" ++ fileName ++ "," ++ show (length tags) ++ "\n" ++ tags
    perFile (tagInfo@(tag,file,lNo,colNo):tags) count pos (line:lines) | lNo>count =
      perFile (tagInfo:tags) (count+1) (pos+length line) lines
    perFile (tagInfo@(tag,file,lNo,colNo):tags) count pos lines@(line:_) | lNo==count =
      showETag tagInfo line pos : perFile tags count pos lines
    perFile tags count pos lines = []

-- simple ctags format, for Vim et al
showTag :: TagInfo -> String
showTag (tag,file,lineNo,colNo)
    =  tag ++ "\t" ++ file ++ "\t" ++ show lineNo

-- etags format, for Emacs/XEmacs
showETag :: TagInfo -> String -> Int -> String
showETag (tag,file,lineNo,colNo) line charPos
    =  take colNo line ++ tag
    ++ "\x7f" ++ tag
    ++ "\x01" ++ show lineNo
    ++ "," ++ show charPos

-----------------------------------------------------------------------------
-- Browsing a module's contents

browseCmd :: String -> GHCi ()
browseCmd m = 
  case words m of
    ['*':m] | looksLikeModuleName m -> browseModule m False
    [m]     | looksLikeModuleName m -> browseModule m True
    _ -> throwDyn (CmdLineError "syntax:  :browse <module>")

browseModule m exports_only = do
  s <- getSession

  let modl = GHC.mkModule m
  is_interpreted <- io (GHC.moduleIsInterpreted s modl)
  when (not is_interpreted && not exports_only) $
	throwDyn (CmdLineError ("module '" ++ m ++ "' is not interpreted"))

  -- Temporarily set the context to the module we're interested in,
  -- just so we can get an appropriate PrintUnqualified
  (as,bs) <- io (GHC.getContext s)
  io (if exports_only then GHC.setContext s [] [prelude_mod,modl]
		      else GHC.setContext s [modl] [])
  unqual <- io (GHC.getPrintUnqual s)
  io (GHC.setContext s as bs)

  mb_mod_info <- io $ GHC.getModuleInfo s modl
  case mb_mod_info of
    Nothing -> throwDyn (CmdLineError ("unknown module: " ++ m))
    Just mod_info -> do
        let names
	       | exports_only = GHC.modInfoExports mod_info
	       | otherwise    = fromMaybe [] (GHC.modInfoTopLevelScope mod_info)

	    filtered = filterOutChildren names
	
        things <- io $ mapM (GHC.lookupName s) filtered

        dflags <- getDynFlags
	let exts = dopt Opt_GlasgowExts dflags
	io (putStrLn (showSDocForUser unqual (
		vcat (map (pprTyThingInContext exts) (catMaybes things))
	   )))
	-- ToDo: modInfoInstances currently throws an exception for
	-- package modules.  When it works, we can do this:
	--	$$ vcat (map GHC.pprInstance (GHC.modInfoInstances mod_info))

-----------------------------------------------------------------------------
-- Setting the module context

setContext str
  | all sensible mods = fn mods
  | otherwise = throwDyn (CmdLineError "syntax:  :module [+/-] [*]M1 ... [*]Mn")
  where
    (fn, mods) = case str of 
			'+':stuff -> (addToContext,      words stuff)
			'-':stuff -> (removeFromContext, words stuff)
			stuff     -> (newContext,        words stuff) 

    sensible ('*':m) = looksLikeModuleName m
    sensible m       = looksLikeModuleName m

newContext mods = do
  session <- getSession
  (as,bs) <- separate session mods [] []
  let bs' = if null as && prelude_mod `notElem` bs then prelude_mod:bs else bs
  io (GHC.setContext session as bs')

separate :: Session -> [String] -> [Module] -> [Module]
  -> GHCi ([Module],[Module])
separate session []           as bs = return (as,bs)
separate session (('*':m):ms) as bs = do
   let modl = GHC.mkModule m
   b <- io (GHC.moduleIsInterpreted session modl)
   if b then separate session ms (modl:as) bs
   	else throwDyn (CmdLineError ("module '" ++ m ++ "' is not interpreted"))
separate session (m:ms)       as bs = separate session ms as (GHC.mkModule m:bs)

prelude_mod = GHC.mkModule "Prelude"


addToContext mods = do
  cms <- getSession
  (as,bs) <- io (GHC.getContext cms)

  (as',bs') <- separate cms mods [] []

  let as_to_add = as' \\ (as ++ bs)
      bs_to_add = bs' \\ (as ++ bs)

  io (GHC.setContext cms (as ++ as_to_add) (bs ++ bs_to_add))


removeFromContext mods = do
  cms <- getSession
  (as,bs) <- io (GHC.getContext cms)

  (as_to_remove,bs_to_remove) <- separate cms mods [] []

  let as' = as \\ (as_to_remove ++ bs_to_remove)
      bs' = bs \\ (as_to_remove ++ bs_to_remove)

  io (GHC.setContext cms as' bs')

----------------------------------------------------------------------------
-- Code for `:set'

-- set options in the interpreter.  Syntax is exactly the same as the
-- ghc command line, except that certain options aren't available (-C,
-- -E etc.)
--
-- This is pretty fragile: most options won't work as expected.  ToDo:
-- figure out which ones & disallow them.

setCmd :: String -> GHCi ()
setCmd ""
  = do st <- getGHCiState
       let opts = options st
       io $ putStrLn (showSDoc (
   	      text "options currently set: " <> 
   	      if null opts
   		   then text "none."
   		   else hsep (map (\o -> char '+' <> text (optToStr o)) opts)
   	   ))
setCmd str
  = case words str of
	("args":args) -> setArgs args
	("prog":prog) -> setProg prog
        ("prompt":prompt) -> setPrompt (dropWhile isSpace $ drop 6 $ dropWhile isSpace str)
	wds -> setOptions wds

setArgs args = do
  st <- getGHCiState
  setGHCiState st{ args = args }

setProg [prog] = do
  st <- getGHCiState
  setGHCiState st{ progname = prog }
setProg _ = do
  io (hPutStrLn stderr "syntax: :set prog <progname>")

setPrompt value = do
  st <- getGHCiState
  if null value
      then io $ hPutStrLn stderr $ "syntax: :set prompt <prompt>, currently \"" ++ prompt st ++ "\""
      else setGHCiState st{ prompt = remQuotes value }
  where
     remQuotes ('\"':xs) | not (null xs) && last xs == '\"' = init xs
     remQuotes x = x

setOptions wds =
   do -- first, deal with the GHCi opts (+s, +t, etc.)
      let (plus_opts, minus_opts)  = partition isPlus wds
      mapM_ setOpt plus_opts

      -- then, dynamic flags
      dflags <- getDynFlags
      (dflags',leftovers) <- io $ GHC.parseDynamicFlags dflags minus_opts
      setDynFlags dflags'

        -- update things if the users wants more packages
{- TODO:
        let new_packages = pkgs_after \\ pkgs_before
        when (not (null new_packages)) $
  	   newPackages new_packages
-}

      if (not (null leftovers))
		then throwDyn (CmdLineError ("unrecognised flags: " ++ 
						unwords leftovers))
		else return ()


unsetOptions :: String -> GHCi ()
unsetOptions str
  = do -- first, deal with the GHCi opts (+s, +t, etc.)
       let opts = words str
	   (minus_opts, rest1) = partition isMinus opts
	   (plus_opts, rest2)  = partition isPlus rest1

       if (not (null rest2)) 
	  then io (putStrLn ("unknown option: '" ++ head rest2 ++ "'"))
	  else do

       mapM_ unsetOpt plus_opts
 
       -- can't do GHC flags for now
       if (not (null minus_opts))
	  then throwDyn (CmdLineError "can't unset GHC command-line flags")
	  else return ()

isMinus ('-':s) = True
isMinus _ = False

isPlus ('+':s) = True
isPlus _ = False

setOpt ('+':str)
  = case strToGHCiOpt str of
	Nothing -> io (putStrLn ("unknown option: '" ++ str ++ "'"))
	Just o  -> setOption o

unsetOpt ('+':str)
  = case strToGHCiOpt str of
	Nothing -> io (putStrLn ("unknown option: '" ++ str ++ "'"))
	Just o  -> unsetOption o

strToGHCiOpt :: String -> (Maybe GHCiOption)
strToGHCiOpt "s" = Just ShowTiming
strToGHCiOpt "t" = Just ShowType
strToGHCiOpt "r" = Just RevertCAFs
strToGHCiOpt _   = Nothing

optToStr :: GHCiOption -> String
optToStr ShowTiming = "s"
optToStr ShowType   = "t"
optToStr RevertCAFs = "r"

{- ToDo
newPackages new_pkgs = do	-- The new packages are already in v_Packages
  session <- getSession
  io (GHC.setTargets session [])
  io (GHC.load session Nothing)
  dflags   <- getDynFlags
  io (linkPackages dflags new_pkgs)
  setContextAfterLoad []
-}

-- ---------------------------------------------------------------------------
-- code for `:show'

showCmd str =
  case words str of
	["modules" ] -> showModules
	["bindings"] -> showBindings
	["linker"]   -> io showLinkerState
	_ -> throwDyn (CmdLineError "syntax:  :show [modules|bindings]")

showModules = do
  session <- getSession
  let show_one ms = do m <- io (GHC.showModule session ms)
		       io (putStrLn m)
  graph <- io (GHC.getModuleGraph session)
  mapM_ show_one graph

showBindings = do
  s <- getSession
  unqual <- io (GHC.getPrintUnqual s)
  bindings <- io (GHC.getBindings s)
  mapM_ showTyThing bindings
  return ()

showTyThing (AnId id) = do 
  ty' <- cleanType (GHC.idType id)
  str <- showForUser (ppr id <> text " :: " <> ppr ty')
  io (putStrLn str)
showTyThing _  = return ()

-- if -fglasgow-exts is on we show the foralls, otherwise we don't.
cleanType :: Type -> GHCi Type
cleanType ty = do
  dflags <- getDynFlags
  if dopt Opt_GlasgowExts dflags 
	then return ty
	else return $! GHC.dropForAlls ty

-- -----------------------------------------------------------------------------
-- Completion

completeNone :: String -> IO [String]
completeNone w = return []

#ifdef USE_READLINE
completeWord :: String -> Int -> Int -> IO (Maybe (String, [String]))
completeWord w start end = do
  line <- Readline.getLineBuffer
  case w of 
     ':':_ | all isSpace (take (start-1) line) -> wrapCompleter completeCmd w
     _other
	| Just c <- is_cmd line -> do
	   maybe_cmd <- lookupCommand c
           let (n,w') = selectWord (words' 0 line)
	   case maybe_cmd of
	     Nothing -> return Nothing
	     Just (_,_,False,complete) -> wrapCompleter complete w
	     Just (_,_,True,complete) -> let complete' w = do rets <- complete w
                                                              return (map (drop n) rets)
                                         in wrapCompleter complete' w'
	| otherwise     -> do
		--printf "complete %s, start = %d, end = %d\n" w start end
		wrapCompleter completeIdentifier w
    where words' _ [] = []
          words' n str = let (w,r) = break isSpace str
                             (s,r') = span isSpace r
                         in (n,w):words' (n+length w+length s) r'
          -- In a Haskell expression we want to parse 'a-b' as three words
          -- where a compiler flag (ie. -fno-monomorphism-restriction) should
          -- only be a single word.
          selectWord [] = (0,w)
          selectWord ((offset,x):xs)
              | offset+length x >= start = (start-offset,take (end-offset) x)
              | otherwise = selectWord xs

is_cmd line 
 | ((':':w) : _) <- words (dropWhile isSpace line) = Just w
 | otherwise = Nothing

completeCmd w = do
  cmds <- readIORef commands
  return (filter (w `isPrefixOf`) (map (':':) (map cmdName cmds)))

completeMacro w = do
  cmds <- readIORef commands
  let cmds' = [ cmd | cmd <- map cmdName cmds, cmd `elem` map cmdName builtin_commands ]
  return (filter (w `isPrefixOf`) cmds')

completeIdentifier w = do
  s <- restoreSession
  rdrs <- GHC.getRdrNamesInScope s
  return (filter (w `isPrefixOf`) (map (showSDoc.ppr) rdrs))

completeModule w = do
  s <- restoreSession
  dflags <- GHC.getSessionDynFlags s
  let pkg_mods = allExposedModules dflags
  return (filter (w `isPrefixOf`) (map (showSDoc.ppr) pkg_mods))

completeHomeModule w = do
  s <- restoreSession
  g <- GHC.getModuleGraph s
  let home_mods = map GHC.ms_mod g
  return (filter (w `isPrefixOf`) (map (showSDoc.ppr) home_mods))

completeSetOptions w = do
  return (filter (w `isPrefixOf`) options)
    where options = "args":"prog":allFlags

completeFilename = Readline.filenameCompletionFunction

completeHomeModuleOrFile = unionComplete completeHomeModule completeFilename

unionComplete :: (String -> IO [String]) -> (String -> IO [String]) -> String -> IO [String]
unionComplete f1 f2 w = do
  s1 <- f1 w
  s2 <- f2 w
  return (s1 ++ s2)

wrapCompleter :: (String -> IO [String]) -> String -> IO (Maybe (String,[String]))
wrapCompleter fun w =  do
  strs <- fun w
  case strs of
    []  -> return Nothing
    [x] -> return (Just (x,[]))
    xs  -> case getCommonPrefix xs of
		""   -> return (Just ("",xs))
		pref -> return (Just (pref,xs))

getCommonPrefix :: [String] -> String
getCommonPrefix [] = ""
getCommonPrefix (s:ss) = foldl common s ss
  where common s "" = s
	common "" s = ""
	common (c:cs) (d:ds)
	   | c == d = c : common cs ds
	   | otherwise = ""

allExposedModules :: DynFlags -> [Module]
allExposedModules dflags 
 = map GHC.mkModule (concat (map exposedModules (filter exposed (eltsUFM pkg_db))))
 where
  pkg_db = pkgIdMap (pkgState dflags)
#else
completeCmd        = completeNone
completeMacro      = completeNone
completeIdentifier = completeNone
completeModule     = completeNone
completeHomeModule = completeNone
completeSetOptions = completeNone
completeFilename   = completeNone
completeHomeModuleOrFile=completeNone
#endif

-----------------------------------------------------------------------------
-- GHCi monad

data GHCiState = GHCiState
     { 
	progname       :: String,
	args	       :: [String],
        prompt         :: String,
	session        :: GHC.Session,
	options        :: [GHCiOption]
     }

data GHCiOption 
	= ShowTiming		-- show time/allocs after evaluation
	| ShowType		-- show the type of expressions
	| RevertCAFs		-- revert CAFs after every evaluation
	deriving Eq

newtype GHCi a = GHCi { unGHCi :: IORef GHCiState -> IO a }

startGHCi :: GHCi a -> GHCiState -> IO a
startGHCi g state = do ref <- newIORef state; unGHCi g ref

instance Monad GHCi where
  (GHCi m) >>= k  =  GHCi $ \s -> m s >>= \a -> unGHCi (k a) s
  return a  = GHCi $ \s -> return a

ghciHandleDyn :: Typeable t => (t -> GHCi a) -> GHCi a -> GHCi a
ghciHandleDyn h (GHCi m) = GHCi $ \s -> 
   Exception.catchDyn (m s) (\e -> unGHCi (h e) s)

getGHCiState   = GHCi $ \r -> readIORef r
setGHCiState s = GHCi $ \r -> writeIORef r s

-- for convenience...
getSession = getGHCiState >>= return . session

GLOBAL_VAR(saved_sess, no_saved_sess, Session)
no_saved_sess = error "no saved_ses"
saveSession = getSession >>= io . writeIORef saved_sess
splatSavedSession = io (writeIORef saved_sess no_saved_sess)
restoreSession = readIORef saved_sess

getDynFlags = do
  s <- getSession
  io (GHC.getSessionDynFlags s)
setDynFlags dflags = do 
  s <- getSession 
  io (GHC.setSessionDynFlags s dflags)

isOptionSet :: GHCiOption -> GHCi Bool
isOptionSet opt
 = do st <- getGHCiState
      return (opt `elem` options st)

setOption :: GHCiOption -> GHCi ()
setOption opt
 = do st <- getGHCiState
      setGHCiState (st{ options = opt : filter (/= opt) (options st) })

unsetOption :: GHCiOption -> GHCi ()
unsetOption opt
 = do st <- getGHCiState
      setGHCiState (st{ options = filter (/= opt) (options st) })

io :: IO a -> GHCi a
io m = GHCi { unGHCi = \s -> m >>= return }

-----------------------------------------------------------------------------
-- recursive exception handlers

-- Don't forget to unblock async exceptions in the handler, or if we're
-- in an exception loop (eg. let a = error a in a) the ^C exception
-- may never be delivered.  Thanks to Marcin for pointing out the bug.

ghciHandle :: (Exception -> GHCi a) -> GHCi a -> GHCi a
ghciHandle h (GHCi m) = GHCi $ \s -> 
   Exception.catch (m s) 
	(\e -> unGHCi (ghciUnblock (h e)) s)

ghciUnblock :: GHCi a -> GHCi a
ghciUnblock (GHCi a) = GHCi $ \s -> Exception.unblock (a s)

-----------------------------------------------------------------------------
-- timing & statistics

timeIt :: GHCi a -> GHCi a
timeIt action
  = do b <- isOptionSet ShowTiming
       if not b 
	  then action 
	  else do allocs1 <- io $ getAllocations
		  time1   <- io $ getCPUTime
		  a <- action
		  allocs2 <- io $ getAllocations
		  time2   <- io $ getCPUTime
		  io $ printTimes (fromIntegral (allocs2 - allocs1)) 
				  (time2 - time1)
		  return a

foreign import ccall unsafe "getAllocations" getAllocations :: IO Int64
	-- defined in ghc/rts/Stats.c

printTimes :: Integer -> Integer -> IO ()
printTimes allocs psecs
   = do let secs = (fromIntegral psecs / (10^12)) :: Float
	    secs_str = showFFloat (Just 2) secs
	putStrLn (showSDoc (
		 parens (text (secs_str "") <+> text "secs" <> comma <+> 
			 text (show allocs) <+> text "bytes")))

-----------------------------------------------------------------------------
-- reverting CAFs
	
revertCAFs :: IO ()
revertCAFs = do
  rts_revertCAFs
  turnOffBuffering
	-- Have to turn off buffering again, because we just 
	-- reverted stdout, stderr & stdin to their defaults.

foreign import ccall "revertCAFs" rts_revertCAFs  :: IO ()  
	-- Make it "safe", just in case

-- ----------------------------------------------------------------------------
-- Utils

expandPath :: String -> GHCi String
expandPath path = 
  case dropWhile isSpace path of
   ('~':d) -> do
	tilde <- io (getEnv "HOME")	-- will fail if HOME not defined
	return (tilde ++ '/':d)
   other -> 
	return other

-- ----------------------------------------------------------------------------
-- Windows console setup

setUpConsole :: IO ()
setUpConsole = do
#ifdef mingw32_HOST_OS
	-- On Windows we need to set a known code page, otherwise the characters
  	-- we read from the console will be be in some strange encoding, and
	-- similarly for characters we write to the console.
	--
	-- At the moment, GHCi pretends all input is Latin-1.  In the
	-- future we should support UTF-8, but for now we set the code pages
	-- to Latin-1.
	--
	-- It seems you have to set the font in the console window to
	-- a Unicode font in order for output to work properly,
	-- otherwise non-ASCII characters are mapped wrongly.  sigh.
	-- (see MSDN for SetConsoleOutputCP()).
	--
	setConsoleCP 28591       -- ISO Latin-1
	setConsoleOutputCP 28591 -- ISO Latin-1
#endif
	return ()
