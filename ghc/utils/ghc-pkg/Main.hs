{-# OPTIONS -fglasgow-exts #-}
-----------------------------------------------------------------------------
--
-- (c) The University of Glasgow 2004.
--
-- Package management tool
--
-----------------------------------------------------------------------------

-- TODO:
--	- validate modules
--	- expose/hide
--	- expanding of variables in new-style package conf
--	- version manipulation (checking whether old version exists,
--	  hiding old version?)

module Main (main) where

import Version	( version, targetOS, targetARCH )
import Distribution.InstalledPackageInfo
import Distribution.Compat.ReadP
import Distribution.ParseUtils	( showError )
import Distribution.Package
import Distribution.Version
import Compat.Directory 	( getAppUserDataDirectory )
import Compat.RawSystem 	( rawSystem )
import Control.Exception	( evaluate )
import qualified Control.Exception as Exception
import System.FilePath		( joinFileName, splitFileName )

import Prelude

#if __GLASGOW_HASKELL__ < 603
#include "config.h"
#endif

#if __GLASGOW_HASKELL__ >= 504
import System.Console.GetOpt
import Text.PrettyPrint
import qualified Control.Exception as Exception
#else
import GetOpt
import Pretty
import qualified Exception
#endif

import Data.Char	( isSpace )
import Monad
import Directory
import System	( getArgs, getProgName,
		  exitWith, ExitCode(..)
		)
import System.IO
import Data.List ( isPrefixOf, isSuffixOf, intersperse )

#ifdef mingw32_HOST_OS
import Foreign

#if __GLASGOW_HASKELL__ >= 504
import Foreign.C.String
#else
import CString
#endif
#endif

-- -----------------------------------------------------------------------------
-- Entry point

main :: IO ()
main = do
  args <- getArgs

  case getOpt Permute flags args of
	(cli,_,[]) | FlagHelp `elem` cli -> do
	   prog <- getProgramName
	   bye (usageInfo (usageHeader prog) flags)
	(cli,_,[]) | FlagVersion `elem` cli ->
	   bye ourCopyright
	(cli,nonopts,[]) ->
	   runit cli nonopts
	(_,_,errors) -> tryOldCmdLine errors args

-- If the new command-line syntax fails, then we try the old.  If that
-- fails too, then we output the original errors and the new syntax
-- (so the old syntax is still available, but hidden).
tryOldCmdLine :: [String] -> [String] -> IO ()
tryOldCmdLine errors args = do
  case getOpt Permute oldFlags args of
	(cli@(_:_),[],[]) -> 
	   oldRunit cli
	_failed -> do
	   prog <- getProgramName
	   die (concat errors ++ usageInfo (usageHeader prog) flags)

-- -----------------------------------------------------------------------------
-- Command-line syntax

data Flag
  = FlagUser
  | FlagGlobal
  | FlagHelp
  | FlagVersion
  | FlagConfig	FilePath
  | FlagGlobalConfig FilePath
  | FlagForce
  | FlagAutoGHCiLibs
  deriving Eq

flags :: [OptDescr Flag]
flags = [
  Option [] ["user"] (NoArg FlagUser)
	"use the current user's package database",
  Option [] ["global"] (NoArg FlagGlobal)
	"(default) use the global package database",
  Option ['f'] ["package-conf"] (ReqArg FlagConfig "FILE")
	"act upon specified package config file (only)",
  Option [] ["global-conf"] (ReqArg FlagGlobalConfig "FILE")
	"location of the global package config",
  Option [] ["force"] (NoArg FlagForce)
 	"ignore missing dependencies, directories, and libraries",
  Option ['g'] ["auto-ghci-libs"] (NoArg FlagAutoGHCiLibs)
	"automatically build libs for GHCi (with register)",
  Option ['?'] ["help"] (NoArg FlagHelp)
	"display this help and exit",
   Option ['V'] ["version"] (NoArg FlagVersion)
	"output version information and exit"
  ]

ourCopyright :: String
ourCopyright = "GHC package manager version " ++ version ++ "\n"

usageHeader :: String -> String
usageHeader prog = substProg prog $
  "Usage:\n" ++
  "  $p {--help | -?}\n" ++
  "    Produce this usage message.\n" ++
  "\n" ++
  "  $p register {filename | -} [--user | --global]\n" ++
  "    Register the package using the specified installed package\n" ++
  "    description. The syntax for the latter is given in the $p\n" ++
  "    documentation.\n" ++
  "\n" ++
  "  $p unregister {pkg-id}\n" ++
  "    Unregister the specified package.\n" ++
  "\n" ++
  "  $p expose {pkg-id}\n" ++
  "    Expose the specified package.\n" ++
  "\n" ++
  "  $p hide {pkg-id}\n" ++
  "    Hide the specified package.\n" ++
  "\n" ++
  "  $p list [--global | --user]\n" ++
  "    List all registered packages, both global and user (unless either\n" ++
  "    --global or --user is specified), and both hidden and exposed.\n" ++
  "\n" ++
  "  $p describe {pkg-id}\n" ++
  "    Give the registered description for the specified package. The\n" ++
  "    description is returned in precisely the syntax required by $p\n" ++
  "    register.\n" ++
  "\n" ++
  "  $p field {pkg-id} {field}\n" ++
  "    Extract the specified field of the package description for the\n" ++
  "    specified package.\n"

substProg :: String -> String -> String
substProg _ [] = []
substProg prog ('$':'p':xs) = prog ++ substProg prog xs
substProg prog (c:xs) = c : substProg prog xs

-- -----------------------------------------------------------------------------
-- Do the business

runit :: [Flag] -> [String] -> IO ()
runit cli nonopts = do
  prog <- getProgramName
  dbs <- getPkgDatabases cli
  db_stack <- mapM readParseDatabase dbs
  let
	force = FlagForce `elem` cli
	auto_ghci_libs = FlagAutoGHCiLibs `elem` cli
  --
  -- first, parse the command
  case nonopts of
    ["register", filename] -> 
	registerPackage filename [] db_stack auto_ghci_libs False force
    ["update", filename] -> 
	registerPackage filename [] db_stack auto_ghci_libs True force
    ["unregister", pkgid_str] -> do
	pkgid <- readPkgId pkgid_str
	unregisterPackage pkgid db_stack
    ["expose", pkgid_str] -> do
	pkgid <- readPkgId pkgid_str
	exposePackage pkgid db_stack
    ["hide",   pkgid_str] -> do
	pkgid <- readPkgId pkgid_str
	hidePackage pkgid db_stack
    ["list"] -> do
	listPackages db_stack
    ["describe", pkgid_str] -> do
	pkgid <- readPkgId pkgid_str
	describePackage db_stack pkgid
    ["field", pkgid_str, field] -> do
	pkgid <- readPkgId pkgid_str
	describeField db_stack pkgid field
    [] -> do
	die ("missing command\n" ++ 
		usageInfo (usageHeader prog) flags)
    (_cmd:_) -> do
	die ("command-line syntax error\n" ++ 
		usageInfo (usageHeader prog) flags)

parseCheck :: ReadP a a -> String -> String -> IO a
parseCheck parser str what = 
  case [ x | (x,ys) <- readP_to_S parser str, all isSpace ys ] of
    [x] -> return x
    _ -> die ("cannot parse \'" ++ str ++ "\' as a " ++ what)

readPkgId :: String -> IO PackageIdentifier
readPkgId str = parseCheck parsePackageId str "package identifier"

-- -----------------------------------------------------------------------------
-- Package databases

-- Some commands operate on a single database:
--	register, unregister, expose, hide
-- however these commands also check the union of the available databases
-- in order to check consistency.  For example, register will check that
-- dependencies exist before registering a package.
--
-- Some commands operate  on multiple databases, with overlapping semantics:
--	list, describe, field

type PackageDBName  = FilePath
type PackageDB      = [InstalledPackageInfo]

type PackageDBStack = [(PackageDBName,PackageDB)]
	-- A stack of package databases.  Convention: head is the topmost
	-- in the stack.  Earlier entries override later one.

-- The output of this function is the list of databases to act upon, with
-- the "topmost" overlapped database last.  The commands which operate on a
-- single database will use the last one.  Commands which operate on multiple
-- databases will interpret the databases as overlapping.
getPkgDatabases :: [Flag] -> IO [PackageDBName]
getPkgDatabases flags = do
  -- first we determine the location of the global package config.  On Windows,
  -- this is found relative to the ghc-pkg.exe binary, whereas on Unix the
  -- location is passed to the binary using the --global-config flag by the
  -- wrapper script.
  let err_msg = "missing --global-conf option, location of global package.conf unknown\n"
  global_conf <- 
     case [ f | FlagGlobalConfig f <- flags ] of
	[] -> do mb_dir <- getExecDir "/bin/ghc-pkg.exe"
		 case mb_dir of
			Nothing  -> die err_msg
			Just dir -> return (dir `joinFileName` "package.conf")
        fs -> return (last fs)

  -- get the location of the user package database, and create it if necessary
  appdir <- getAppUserDataDirectory "ghc"

  let
	subdir = targetARCH ++ '-':targetOS ++ '-':version
	user_conf = appdir `joinFileName` subdir `joinFileName` "package.conf"
  b <- doesFileExist user_conf
  when (not b) $ do
	putStrLn ("Creating user package database in " ++ user_conf)
	createParents user_conf
	writeFile user_conf emptyPackageConfig

  let
	databases = foldl addDB [global_conf] flags

	-- implement the following rules:
	-- 	global database is the default
	-- 	--user means overlap with the user database
	-- 	--global means reset to just the global database
	--	-f <file> means overlap with <file>
	addDB dbs FlagUser       = user_conf : dbs
	addDB dbs FlagGlobal     = [global_conf]
	addDB dbs (FlagConfig f) = f : dbs
	addDB dbs _		 = dbs

  return databases

readParseDatabase :: PackageDBName -> IO (PackageDBName,PackageDB)
readParseDatabase filename = do
  str <- readFile filename
  let packages = read str
  evaluate packages
    `Exception.catch` \_ -> 
	die (filename ++ ": parse error in package config file")
  return (filename,packages)

emptyPackageConfig :: String
emptyPackageConfig = "[]"

-- -----------------------------------------------------------------------------
-- Registering

registerPackage :: FilePath
		-> [(String,String)] --  defines, ToDo: maybe remove?
	        -> PackageDBStack
		-> Bool		-- auto_ghci_libs
		-> Bool		-- update
		-> Bool		-- force
		-> IO ()
registerPackage input defines db_stack auto_ghci_libs update force = do
  let
	db_to_operate_on = head db_stack
	db_filename	 = fst db_to_operate_on
  --
  checkConfigAccess db_filename

  s <-
    case input of
      "-" -> do
	putStr "Reading package info from stdin... "
        getContents
      f   -> do
        putStr ("Reading package info from " ++ show f ++ " ")
	readFile f

  pkg <- parsePackageInfo s defines force
  putStrLn "done."

  validatePackageConfig pkg db_stack auto_ghci_libs update force
  new_details <- updatePackageDB db_stack (snd db_to_operate_on) pkg
  savePackageConfig db_filename
  maybeRestoreOldConfig db_filename $
    writeNewConfig db_filename new_details

parsePackageInfo
	:: String
	-> [(String,String)]
	-> Bool
	-> IO InstalledPackageInfo
parsePackageInfo str defines force =
  case parseInstalledPackageInfo str of
    Right ok -> return ok
    Left err -> die (showError err)

-- Used for converting versionless package names to new
-- PackageIdentifiers.  "Version [] []" is special: it means "no
-- version" or "any version"
pkgNameToId :: String -> PackageIdentifier
pkgNameToId name = PackageIdentifier name (Version [] [])

-- -----------------------------------------------------------------------------
-- Exposing, Hiding, Unregistering are all similar

exposePackage :: PackageIdentifier ->  PackageDBStack -> IO ()
exposePackage = modifyPackage (\p -> [p{exposed=True}])

hidePackage :: PackageIdentifier ->  PackageDBStack -> IO ()
hidePackage = modifyPackage (\p -> [p{exposed=False}])

unregisterPackage :: PackageIdentifier ->  PackageDBStack -> IO ()
unregisterPackage = modifyPackage (\p -> [])

modifyPackage
  :: (InstalledPackageInfo -> [InstalledPackageInfo])
  -> PackageIdentifier
  -> PackageDBStack
  -> IO ()
modifyPackage _ _ [] = error "modifyPackage"
modifyPackage fn pkgid ((db_name, pkgs) : _) = do
  checkConfigAccess db_name
  p <- findPackage [(db_name,pkgs)] pkgid
  let pid = package p
  savePackageConfig db_name
  let new_config = concat (map modify pkgs)
      modify pkg
	| package pkg == pid = fn pkg
	| otherwise          = [pkg]
  maybeRestoreOldConfig db_name $
    writeNewConfig db_name new_config

-- -----------------------------------------------------------------------------
-- Listing packages

listPackages ::  PackageDBStack -> IO ()
listPackages db_confs = do
  mapM_ show_pkgconf (reverse db_confs)
  where show_pkgconf (db_name,pkg_confs) =
	  hPutStrLn stdout (render $
		text (db_name ++ ":") $$ nest 4 packages
		)
	   where packages = fsep (punctuate comma (map pp_pkg pkg_confs))
		 pp_pkg = text . showPackageId . package


-- -----------------------------------------------------------------------------
-- Describe

describePackage :: PackageDBStack -> PackageIdentifier -> IO ()
describePackage db_stack pkgid = do
  p <- findPackage db_stack pkgid
  putStrLn (showInstalledPackageInfo p)

findPackage :: PackageDBStack -> PackageIdentifier -> IO InstalledPackageInfo
findPackage db_stack pkgid
  = case [ p | p <- all_pkgs, pkgid `matches` p ] of
	[]  -> die ("cannot find package " ++ showPackageId pkgid)
	[p] -> return p
	ps  -> die ("package " ++ showPackageId pkgid ++ 
			" matches multiple packages: " ++ 
			concat (intersperse ", " (
				 map (showPackageId.package) ps)))
  where
	all_pkgs = concat (map snd db_stack)

matches :: PackageIdentifier -> InstalledPackageInfo -> Bool
pid `matches` p = 
 pid == package p || 
 not (realVersion pid) && pkgName pid == pkgName (package p)

-- -----------------------------------------------------------------------------
-- Field

describeField :: PackageDBStack -> PackageIdentifier -> String -> IO ()
describeField db_stack pkgid field = do
  case toField field of
    Nothing -> die ("unknown field: " ++ field)
    Just fn -> do
	p <- findPackage db_stack pkgid 
	putStrLn (fn p)

toField :: String -> Maybe (InstalledPackageInfo -> String)
-- backwards compatibility:
toField "import_dirs"     = Just $ strList . importDirs
toField "source_dirs"     = Just $ strList . importDirs
toField "library_dirs"    = Just $ strList . libraryDirs
toField "hs_libraries"    = Just $ strList . hsLibraries
toField "extra_libraries" = Just $ strList . extraLibraries
toField "include_dirs"    = Just $ strList . includeDirs
toField "c_includes"      = Just $ strList . includes
toField "package_deps"    = Just $ strList . map showPackageId. depends
toField "extra_cc_opts"   = Just $ strList . extraCcOpts
toField "extra_ld_opts"   = Just $ strList . extraLdOpts  
toField "framework_dirs"  = Just $ strList . frameworkDirs  
toField "extra_frameworks"= Just $ strList . extraFrameworks  
toField s 	 	  = showInstalledPackageInfoField s

strList :: [String] -> String
strList = show

-- -----------------------------------------------------------------------------
-- Manipulating package.conf files

checkConfigAccess :: FilePath -> IO ()
checkConfigAccess filename = do
  access <- getPermissions filename
  when (not (writable access))
      (die (filename ++ ": you don't have permission to modify this file"))

maybeRestoreOldConfig :: FilePath -> IO () -> IO ()
maybeRestoreOldConfig filename io
  = io `catch` \e -> do
	hPutStrLn stderr (show e)
        hPutStr stdout ("\nWARNING: an error was encountered while the new \n"++
        	          "configuration was being written.  Attempting to \n"++
        	          "restore the old configuration... ")
	renameFile (filename ++ ".old")  filename
        hPutStrLn stdout "done."
	ioError e

writeNewConfig :: FilePath -> [InstalledPackageInfo] -> IO ()
writeNewConfig filename packages = do
  hPutStr stdout "Writing new package config file... "
  h <- openFile filename WriteMode
  hPutStrLn h (show packages)
  hClose h
  hPutStrLn stdout "done."

savePackageConfig :: FilePath -> IO ()
savePackageConfig filename = do
  hPutStr stdout "Saving old package config file... "
    -- mv rather than cp because we've already done an hGetContents
    -- on this file so we won't be able to open it for writing
    -- unless we move the old one out of the way...
  let oldFile = filename ++ ".old"
  doesExist <- doesFileExist oldFile  `catch` (\ _ -> return False)
  when doesExist (removeFile oldFile `catch` (const $ return ()))
  catch (renameFile filename oldFile)
  	(\ err -> do
		hPutStrLn stderr (unwords [ "Unable to rename "
					  , show filename
					  , " to "
					  , show oldFile
					  ])
		ioError err)
  hPutStrLn stdout "done."

-----------------------------------------------------------------------------
-- Sanity-check a new package config, and automatically build GHCi libs
-- if requested.

validatePackageConfig :: InstalledPackageInfo
		      -> PackageDBStack
		      -> Bool	-- auto-ghc-libs
		      -> Bool	-- update
		      -> Bool	-- force
		      -> IO ()
validatePackageConfig pkg db_stack auto_ghci_libs update force = do
  checkDuplicates db_stack pkg update
  mapM_	(checkDep db_stack force) (depends pkg)
  mapM_	(checkDir force) (importDirs pkg)
  mapM_	(checkDir force) (libraryDirs pkg)
  mapM_	(checkDir force) (includeDirs pkg)
  mapM_ (checkHSLib (libraryDirs pkg) auto_ghci_libs force) (hsLibraries pkg)
  -- ToDo: check these somehow?
  --	extra_libraries :: [String],
  --	c_includes      :: [String],


checkDuplicates :: PackageDBStack -> InstalledPackageInfo -> Bool -> IO ()
checkDuplicates db_stack pkg update = do
  let
	pkgid = package pkg

	(_top_db_name, pkgs) : _  = db_stack

	pkgs_with_same_name = 
		[ p | p <- pkgs, pkgName (package p) == pkgName pkgid]
	exposed_pkgs_with_same_name =
		filter exposed pkgs_with_same_name
  --
  -- Check whether this package id already exists in this DB
  --
  when (not update && (package pkg `elem` map package pkgs)) $
       die ("package " ++ showPackageId pkgid ++ " is already installed")
  --
  -- if we are exposing this new package, then check that
  -- there are no other exposed packages with the same name.
  --
  when (not update && exposed pkg && not (null exposed_pkgs_with_same_name)) $
	die ("trying to register " ++ showPackageId pkgid 
		  ++ " as exposed, but "
		  ++ showPackageId (package (head exposed_pkgs_with_same_name))
		  ++ " is also exposed.")


checkDir :: Bool -> String -> IO ()
checkDir force d
 | "$libdir" `isPrefixOf` d = return ()
	-- can't check this, because we don't know what $libdir is
 | otherwise = do
   there <- doesDirectoryExist d
   when (not there)
       (dieOrForce force (d ++ " doesn't exist or isn't a directory"))

checkDep :: PackageDBStack -> Bool -> PackageIdentifier -> IO ()
checkDep db_stack force pkgid
  | real_version && pkgid `elem` pkgids = return ()
  | not real_version && pkgName pkgid `elem` pkg_names = return ()
  | otherwise = dieOrForce force ("dependency " ++ showPackageId pkgid
					++ " doesn't exist")
  where
	-- for backwards compat, we treat 0.0 as a special version,
	-- and don't check that it actually exists.
 	real_version = realVersion pkgid
	
	all_pkgs = concat (map snd db_stack)
	pkgids = map package all_pkgs
	pkg_names = map pkgName pkgids

realVersion :: PackageIdentifier -> Bool
realVersion pkgid = versionBranch (pkgVersion pkgid) /= []

checkHSLib :: [String] -> Bool -> Bool -> String -> IO ()
checkHSLib dirs auto_ghci_libs force lib = do
  let batch_lib_file = "lib" ++ lib ++ ".a"
  bs <- mapM (doesLibExistIn batch_lib_file) dirs
  case [ dir | (exists,dir) <- zip bs dirs, exists ] of
	[] -> dieOrForce force ("cannot find " ++ batch_lib_file ++
				 " on library path") 
	(dir:_) -> checkGHCiLib dirs dir batch_lib_file lib auto_ghci_libs

doesLibExistIn :: String -> String -> IO Bool
doesLibExistIn lib d
 | "$libdir" `isPrefixOf` d = return True
 | otherwise                = doesFileExist (d ++ '/':lib)

checkGHCiLib :: [String] -> String -> String -> String -> Bool -> IO ()
checkGHCiLib dirs batch_lib_dir batch_lib_file lib auto_build
  | auto_build = autoBuildGHCiLib batch_lib_dir batch_lib_file ghci_lib_file
  | otherwise  = do
      bs <- mapM (doesLibExistIn ghci_lib_file) dirs
      case [dir | (exists,dir) <- zip bs dirs, exists] of
        []    -> hPutStrLn stderr ("warning: can't find GHCi lib " ++ ghci_lib_file)
   	(_:_) -> return ()
  where
    ghci_lib_file = lib ++ ".o"

-- automatically build the GHCi version of a batch lib, 
-- using ld --whole-archive.

autoBuildGHCiLib :: String -> String -> String -> IO ()
autoBuildGHCiLib dir batch_file ghci_file = do
  let ghci_lib_file  = dir ++ '/':ghci_file
      batch_lib_file = dir ++ '/':batch_file
  hPutStr stderr ("building GHCi library " ++ ghci_lib_file ++ "...")
#if defined(darwin_TARGET_OS)
  r <- rawSystem "ld" ["-r","-x","-o",ghci_lib_file,"-all_load",batch_lib_file]
#elif defined(mingw32_HOST_OS)
  execDir <- getExecDir "/bin/ghc-pkg.exe"
  r <- rawSystem (maybe "" (++"/gcc-lib/") execDir++"ld") ["-r","-x","-o",ghci_lib_file,"--whole-archive",batch_lib_file]
#else
  r <- rawSystem "ld" ["-r","-x","-o",ghci_lib_file,"--whole-archive",batch_lib_file]
#endif
  when (r /= ExitSuccess) $ exitWith r
  hPutStrLn stderr (" done.")

-- -----------------------------------------------------------------------------
-- Updating the DB with the new package.

updatePackageDB
	:: PackageDBStack
	-> [InstalledPackageInfo]
	-> InstalledPackageInfo
	-> IO [InstalledPackageInfo]
updatePackageDB db_stack pkgs new_pkg = do
  let
	-- we update dependencies without version numbers to
	-- match the actual versions of the relevant packages instaled.
	updateDeps p = p{depends = map resolveDep (depends p)}

	resolveDep pkgid
	   | realVersion pkgid  = pkgid
	   | otherwise		= lookupDep (pkgName pkgid)
	
	lookupDep name
	   = head [ pid | p <- concat (map snd db_stack), 
			  let pid = package p,
			  pkgName pid == name ]

	is_exposed = exposed new_pkg
	pkgid      = package new_pkg
	name       = pkgName pkgid

	pkgs' = [ maybe_hide p | p <- pkgs, package p /= pkgid ]
	
	-- When update is on, and we're exposing the new package,
	-- we hide any packages with the same name (different versions)
	-- in the current DB.  Earlier checks will have failed if
	-- update isn't on.
	maybe_hide p
	  | is_exposed && pkgName (package p) == name = p{ exposed = False }
	  | otherwise = p
  --
  return (pkgs'++[updateDeps new_pkg])

-- -----------------------------------------------------------------------------
-- Searching for modules

#if not_yet

findModules :: [FilePath] -> IO [String]
findModules paths = 
  mms <- mapM searchDir paths
  return (concat mms)

searchDir path prefix = do
  fs <- getDirectoryEntries path `catch` \_ -> return []
  searchEntries path prefix fs

searchEntries path prefix [] = return []
searchEntries path prefix (f:fs)
  | looks_like_a_module  =  do
	ms <- searchEntries path prefix fs
	return (prefix `joinModule` f : ms)
  | looks_like_a_component  =  do
        ms <- searchDir (path `joinFilename` f) (prefix `joinModule` f)
        ms' <- searchEntries path prefix fs
	return (ms ++ ms')	
  | otherwise
	searchEntries path prefix fs

  where
	(base,suffix) = splitFileExt f
	looks_like_a_module = 
		suffix `elem` haskell_suffixes && 
		all okInModuleName base
	looks_like_a_component =
		null suffix && all okInModuleName base

okInModuleName c

#endif

-- -----------------------------------------------------------------------------
-- The old command-line syntax, supported for backwards compatibility

data OldFlag 
  = OF_Config FilePath
  | OF_Input FilePath
  | OF_List
  | OF_ListLocal
  | OF_Add Bool {- True => replace existing info -}
  | OF_Remove String | OF_Show String 
  | OF_Field String | OF_AutoGHCiLibs | OF_Force
  | OF_DefinedName String String
  | OF_GlobalConfig FilePath
  deriving (Eq)

isAction :: OldFlag -> Bool
isAction OF_Config{}        = False
isAction OF_Field{}         = False
isAction OF_Input{}         = False
isAction OF_AutoGHCiLibs{}  = False
isAction OF_Force{}	    = False
isAction OF_DefinedName{}   = False
isAction OF_GlobalConfig{}  = False
isAction _                  = True

oldFlags :: [OptDescr OldFlag]
oldFlags = [
  Option ['f'] ["config-file"] (ReqArg OF_Config "FILE")
	"use the specified package config file",
  Option ['l'] ["list-packages"] (NoArg OF_List)
 	"list packages in all config files",
  Option ['L'] ["list-local-packages"] (NoArg OF_ListLocal)
 	"list packages in the specified config file",
  Option ['a'] ["add-package"] (NoArg (OF_Add False))
 	"add a new package",
  Option ['u'] ["update-package"] (NoArg (OF_Add True))
 	"update package with new configuration",
  Option ['i'] ["input-file"] (ReqArg OF_Input "FILE")
	"read new package info from specified file",
  Option ['s'] ["show-package"] (ReqArg OF_Show "NAME")
 	"show the configuration for package NAME",
  Option [] ["field"] (ReqArg OF_Field "FIELD")
 	"(with --show-package) Show field FIELD only",
  Option [] ["force"] (NoArg OF_Force)
 	"ignore missing directories/libraries",
  Option ['r'] ["remove-package"] (ReqArg OF_Remove "NAME")
 	"remove an installed package",
  Option ['g'] ["auto-ghci-libs"] (NoArg OF_AutoGHCiLibs)
	"automatically build libs for GHCi (with -a)",
  Option ['D'] ["define-name"] (ReqArg toDefined "NAME=VALUE")
  	"define NAME as VALUE",
  Option [] ["global-conf"] (ReqArg OF_GlobalConfig "FILE")
	"location of the global package config"
  ]
 where
  toDefined str = 
    case break (=='=') str of
      (nm,[]) -> OF_DefinedName nm []
      (nm,_:val) -> OF_DefinedName nm val

oldRunit :: [OldFlag] -> IO ()
oldRunit clis = do
  let config_flags = [ f | Just f <- map conv clis ]

      conv (OF_GlobalConfig f) = Just (FlagGlobalConfig f)
      conv (OF_Config f)       = Just (FlagConfig f)
      conv _                   = Nothing

  db_names <- getPkgDatabases config_flags
  db_stack <- mapM readParseDatabase db_names

  let fields = [ f | OF_Field f <- clis ]

  let auto_ghci_libs = any isAuto clis 
	 where isAuto OF_AutoGHCiLibs = True; isAuto _ = False
      input_file = head ([ f | (OF_Input f) <- clis] ++ ["-"])

      force = OF_Force `elem` clis
      
      defines = [ (nm,val) | OF_DefinedName nm val <- clis ]

  case [ c | c <- clis, isAction c ] of
    [ OF_List ]      -> listPackages db_stack
    [ OF_ListLocal ] -> listPackages db_stack
    [ OF_Add upd ]   -> registerPackage input_file defines db_stack
				auto_ghci_libs upd force
    [ OF_Remove p ]  -> unregisterPackage (pkgNameToId p) db_stack
    [ OF_Show p ]
	| null fields -> describePackage db_stack (pkgNameToId p)
	| otherwise   -> mapM_ (describeField db_stack (pkgNameToId p)) fields
    _            -> do prog <- getProgramName
		       die (usageInfo (usageHeader prog) flags)

-- ---------------------------------------------------------------------------

#ifdef OLD_STUFF
-- ToDo: reinstate
expandEnvVars :: PackageConfig -> [(String, String)]
	-> Bool -> IO PackageConfig
expandEnvVars pkg defines force = do
   -- permit _all_ strings to contain ${..} environment variable references,
   -- arguably too flexible.
  nm       <- expandString  (name pkg)
  imp_dirs <- expandStrings (import_dirs pkg) 
  src_dirs <- expandStrings (source_dirs pkg) 
  lib_dirs <- expandStrings (library_dirs pkg) 
  hs_libs  <- expandStrings (hs_libraries pkg)
  ex_libs  <- expandStrings (extra_libraries pkg)
  inc_dirs <- expandStrings (include_dirs pkg)
  c_incs   <- expandStrings (c_includes pkg)
  p_deps   <- expandStrings (package_deps pkg)
  e_g_opts <- expandStrings (extra_ghc_opts pkg)
  e_c_opts <- expandStrings (extra_cc_opts pkg)
  e_l_opts <- expandStrings (extra_ld_opts pkg)
  f_dirs   <- expandStrings (framework_dirs pkg)
  e_frames <- expandStrings (extra_frameworks pkg)
  return (pkg { name            = nm
  	      , import_dirs     = imp_dirs
	      , source_dirs     = src_dirs
	      , library_dirs    = lib_dirs
	      , hs_libraries    = hs_libs
	      , extra_libraries = ex_libs
	      , include_dirs    = inc_dirs
	      , c_includes      = c_incs
	      , package_deps    = p_deps
	      , extra_ghc_opts  = e_g_opts
	      , extra_cc_opts   = e_c_opts
	      , extra_ld_opts   = e_l_opts
	      , framework_dirs  = f_dirs
	      , extra_frameworks= e_frames
	      })
  where
   expandStrings :: [String] -> IO [String]
   expandStrings = liftM concat . mapM expandSpecial

   -- Permit substitutions for list-valued variables (but only when
   -- they occur alone), e.g., package_deps["${deps}"] where env var
   -- (say) 'deps' is "base,haskell98,network"
   expandSpecial :: String -> IO [String]
   expandSpecial str =
      let expand f = liftM f $ expandString str
      in case splitString str of
         [Var _] -> expand (wordsBy (== ','))
         _ -> expand (\x -> [x])

   expandString :: String -> IO String
   expandString = liftM concat . mapM expandElem . splitString

   expandElem :: Elem -> IO String
   expandElem (String s) = return s
   expandElem (Var v)    = lookupEnvVar v

   lookupEnvVar :: String -> IO String
   lookupEnvVar nm = 
     case lookup nm defines of
       Just x | not (null x) -> return x
       _      -> 
	catch (System.getEnv nm)
	   (\ _ -> do dieOrForce force ("Unable to expand variable " ++ 
					show nm)
		      return "")

data Elem = String String | Var String

splitString :: String -> [Elem]
splitString "" = []
splitString str =
   case break (== '$') str of
      (pre, _:'{':xs) ->
         case span (/= '}') xs of
            (var, _:suf) ->
               (if null pre then id else (String pre :)) (Var var : splitString suf)
            _ -> [String str]   -- no closing brace
      _ -> [String str]   -- no dollar/opening brace combo

-- wordsBy isSpace == words
wordsBy :: (Char -> Bool) -> String -> [String]
wordsBy p s = case dropWhile p s of
  "" -> []
  s' -> w : wordsBy p s'' where (w,s'') = break p s'
#endif

-----------------------------------------------------------------------------

getProgramName :: IO String
getProgramName = liftM (`withoutSuffix` ".bin") getProgName
   where str `withoutSuffix` suff
            | suff `isSuffixOf` str = take (length str - length suff) str
            | otherwise             = str

bye :: String -> IO a
bye s = putStr s >> exitWith ExitSuccess

die :: String -> IO a
die s = do 
  hFlush stdout
  prog <- getProgramName
  hPutStrLn stderr (prog ++ ": " ++ s)
  exitWith (ExitFailure 1)

dieOrForce :: Bool -> String -> IO ()
dieOrForce force s 
  | force     = do hFlush stdout; hPutStrLn stderr (s ++ " (ignoring)")
  | otherwise = die s


-----------------------------------------------------------------------------
-- Create a hierarchy of directories

createParents :: FilePath -> IO ()
createParents dir = do
  let parent = directoryOf dir
  b <- doesDirectoryExist parent
  when (not b) $ do
	createParents parent
	createDirectory parent

-----------------------------------------
--	Cut and pasted from ghc/compiler/SysTools

#if defined(mingw32_HOST_OS)
subst a b ls = map (\ x -> if x == a then b else x) ls
unDosifyPath xs = subst '\\' '/' xs

getExecDir :: String -> IO (Maybe String)
-- (getExecDir cmd) returns the directory in which the current
--	  	    executable, which should be called 'cmd', is running
-- So if the full path is /a/b/c/d/e, and you pass "d/e" as cmd,
-- you'll get "/a/b/c" back as the result
getExecDir cmd
  = allocaArray len $ \buf -> do
	ret <- getModuleFileName nullPtr buf len
	if ret == 0 then return Nothing
	            else do s <- peekCString buf
			    return (Just (reverse (drop (length cmd) 
							(reverse (unDosifyPath s)))))
  where
    len = 2048::Int -- Plenty, PATH_MAX is 512 under Win32.

foreign import stdcall unsafe  "GetModuleFileNameA"
  getModuleFileName :: Ptr () -> CString -> Int -> IO Int32
#else
getExecDir :: String -> IO (Maybe String) 
getExecDir _ = return Nothing
#endif

directoryOf :: FilePath -> FilePath
directoryOf = fst.splitFileName
