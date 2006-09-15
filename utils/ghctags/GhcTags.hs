module Main where
import Bag
import Char
import DynFlags(GhcMode, defaultDynFlags)
import FastString
import GHC
import HscTypes (msHsFilePath)
import List
import IO
import Name
import Outputable
import SrcLoc
import System.Environment
import System.Console.GetOpt
import System.Exit


-- search for definitions of things 
-- we do this by parsing the source and grabbing top-level definitions

-- We generate both CTAGS and ETAGS format tags files
-- The former is for use in most sensible editors, while EMACS uses ETAGS

{-
placateGhc :: IO ()
placateGhc = defaultErrorHandler defaultDynFlags $ do
  GHC.init (Just "/usr/local/lib/ghc-6.5")  -- or your build tree!
  s <- newSession mode
-}

main :: IO ()
main = do
        progName <- getProgName
	args <- getArgs
        let usageString = "Usage: " ++ progName ++ " [OPTION...] [files...]"
	let (modes, filenames, errs) = getOpt Permute options args
	if errs /= [] || elem Help modes || filenames == []
         then do
           putStr $ unlines errs 
	   putStr $ usageInfo usageString options
	   exitWith (ExitFailure 1)
         else return ()
        let mode = getMode (Append `delete` modes)
        let openFileMode = if elem Append modes
			   then AppendMode
			   else WriteMode
        GHC.init (Just "/usr/local/lib/ghc-6.5")
        GHC.defaultErrorHandler defaultDynFlags $ do
          session <- newSession JustTypecheck
          print "created a session"
          flags <- getSessionDynFlags session
          (flags, _) <- parseDynamicFlags flags ["-package", "ghc"]
          GHC.defaultCleanupHandler flags $ do
            flags <- initPackages flags
            setSessionDynFlags session flags
          filedata <- mapM (findthings session) filenames
          if mode == BothTags || mode == CTags
           then do 
             ctagsfile <- openFile "tags" openFileMode
             writectagsfile ctagsfile filedata
             hClose ctagsfile
           else return ()
          if mode == BothTags || mode == ETags 
           then do
             etagsfile <- openFile "TAGS" openFileMode
             writeetagsfile etagsfile filedata
             hClose etagsfile
           else return ()

-- | getMode takes a list of modes and extract the mode with the
--   highest precedence.  These are as follows: Both, CTags, ETags
--   The default case is Both.
getMode :: [Mode] -> Mode
getMode [] = BothTags
getMode [x] = x
getMode (x:xs) = max x (getMode xs)


data Mode = ETags | CTags | BothTags | Append | Help deriving (Ord, Eq, Show)

options :: [OptDescr Mode]
options = [ Option "c" ["ctags"]
	    (NoArg CTags) "generate CTAGS file (ctags)"
	  , Option "e" ["etags"]
	    (NoArg ETags) "generate ETAGS file (etags)"
	  , Option "b" ["both"]
	    (NoArg BothTags) ("generate both CTAGS and ETAGS")
	  , Option "a" ["append"]
	    (NoArg Append) ("append to existing CTAGS and/or ETAGS file(s)")
	  , Option "h" ["help"] (NoArg Help) "This help"
	  ]

type FileName = String

type ThingName = String

-- The position of a token or definition
data Pos = Pos 
		FileName 	-- file name
		Int			-- line number 
		Int     	-- token number
		String 		-- string that makes up that line
	deriving Show

srcLocToPos :: SrcLoc -> Pos
srcLocToPos loc =
    Pos (unpackFS $ srcLocFile loc) (srcLocLine loc) (srcLocCol loc) "bogus"

-- A definition we have found
data FoundThing = FoundThing ThingName Pos
	deriving Show

-- Data we have obtained from a file
data FileData = FileData FileName [FoundThing]

data Token = Token String Pos
	deriving Show


-- stuff for dealing with ctags output format

writectagsfile :: Handle -> [FileData] -> IO ()
writectagsfile ctagsfile filedata = do
	let things = concat $ map getfoundthings filedata
	mapM_ (\x -> hPutStrLn ctagsfile $ dumpthing x) things

getfoundthings :: FileData -> [FoundThing]
getfoundthings (FileData filename things) = things

dumpthing :: FoundThing -> String
dumpthing (FoundThing name (Pos filename line _ _)) = 
	name ++ "\t" ++ filename ++ "\t" ++ (show $ line + 1)


-- stuff for dealing with etags output format

writeetagsfile :: Handle -> [FileData] -> IO ()
writeetagsfile etagsfile filedata = do
	mapM_ (\x -> hPutStr etagsfile $ e_dumpfiledata x) filedata

e_dumpfiledata :: FileData -> String
e_dumpfiledata (FileData filename things) = 
	"\x0c\n" ++ filename ++ "," ++ (show thingslength) ++ "\n" ++ thingsdump
	where 
		thingsdump = concat $ map e_dumpthing things 
		thingslength = length thingsdump

e_dumpthing :: FoundThing -> String
e_dumpthing (FoundThing name (Pos filename line token fullline)) =
	---- (concat $ take (token + 1) $ spacedwords fullline) 
        name
	++ "\x7f" ++ (show line) ++ "," ++ (show $ line+1) ++ "\n"
	
	
-- like "words", but keeping the whitespace, and so letting us build
-- accurate prefixes	
	
spacedwords :: String -> [String]
spacedwords [] = []
spacedwords xs = (blanks ++ wordchars):(spacedwords rest2)
	where 
		(blanks,rest) = span Char.isSpace xs
		(wordchars,rest2) = span (\x -> not $ Char.isSpace x) rest
	
	
-- Find the definitions in a file	
	
modsummary :: ModuleGraph -> FileName -> Maybe ModSummary
modsummary graph n = 
  List.find matches graph
  where matches ms = n == msHsFilePath ms

modname :: ModSummary -> ModuleName
modname summary = moduleName $ ms_mod $ summary

findthings :: Session -> FileName -> IO FileData
findthings session filename = do
  setTargets session [Target (TargetFile filename Nothing) Nothing]
  print "set targets"
  success <- load session LoadAllTargets  --- bring module graph up to date
  case success of
    Failed -> do { print "load failed"; return emptyFileData }
    Succeeded ->
      do print "loaded all targets"
         graph <- getModuleGraph session
         print "got modules graph"
         case  modsummary graph filename of
           Nothing -> panic "loaded a module from a file but then could not find its summary"
           Just ms -> do
             mod <- checkModule session (modname ms)
             print "got the module"
             case mod of
               Nothing -> return emptyFileData
               Just m -> case renamedSource m of
                           Nothing -> return emptyFileData
                           Just s -> return $ fileData filename s
  where emptyFileData = FileData filename []


fileData :: FileName -> RenamedSource -> FileData
fileData filename (group, imports, lie) =
    -- lie is related to type checking and so is irrelevant
    -- imports contains import declarations and no definitions
    FileData filename (boundValues group)

boundValues :: HsGroup Name -> [FoundThing]    
boundValues group =
  case hs_valds group of
    ValBindsOut nest sigs ->
        [ x | (_rec, binds) <- nest, bind <- bagToList binds, x <- boundThings bind ]

posOfLocated :: Located a -> Pos
posOfLocated lHs = srcLocToPos $ srcSpanStart $ getLoc lHs

boundThings :: LHsBind Name -> [FoundThing]
boundThings lbinding = 
  let thing id = FoundThing (getOccString $ unLoc id) (posOfLocated id)
  in  case unLoc lbinding of
        FunBind { fun_id = id } -> [thing id]
        PatBind { pat_lhs = lhs } -> patBoundIds lhs
--        VarBind { var_id = id } -> [thing id]
        _ -> []
                                     

patBoundIds :: a -> b
patBoundIds _ = panic "not on your life"
	
-- actually pick up definitions

findstuff :: [Token] -> [FoundThing]
findstuff ((Token "data" _):(Token name pos):xs) = 
	FoundThing name pos : (getcons xs) ++ (findstuff xs)
findstuff ((Token "newtype" _):(Token name pos):xs) = 
	FoundThing name pos : findstuff xs
findstuff ((Token "type" _):(Token name pos):xs) = 
	FoundThing name pos : findstuff xs
findstuff ((Token name pos):(Token "::" _):xs) = 
	FoundThing name pos : findstuff xs
findstuff (x:xs) = findstuff xs
findstuff [] = []


-- get the constructor definitions, knowing that a datatype has just started

getcons :: [Token] -> [FoundThing]
getcons ((Token "=" _):(Token name pos):xs) = 
	FoundThing name pos : getcons2 xs
getcons (x:xs) = getcons xs
getcons [] = []


getcons2 ((Token "=" _):xs) = []
getcons2 ((Token "|" _):(Token name pos):xs) = 
	FoundThing name pos : getcons2 xs
getcons2 (x:xs) = getcons2 xs
getcons2 [] = []

