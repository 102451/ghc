%
% (c) The University of Glasgow, 2000
%
\section[Finder]{Module Finder}

\begin{code}
module Finder (
    initFinder, 	-- :: [PackageConfig] -> IO (), 
    findModule,		-- :: ModuleName -> IO (Maybe (Module, ModLocation))
    findModuleDep,	-- :: ModuleName -> Bool -> IO (Maybe (Module, ModLocation))
    findPackageModule,	-- :: ModuleName -> IO (Maybe (Module, ModLocation))
    mkHomeModuleLocn,	-- :: ModuleName -> String -> FilePath 
			--	-> IO ModLocation
    emptyHomeDirCache,	-- :: IO ()
    flushPackageCache   -- :: [PackageConfig] -> IO ()
  ) where

#include "HsVersions.h"

import Module		( Module, ModLocation(..), ModuleName,
			  moduleNameUserString, mkHomeModule, mkPackageModule
			)
import Packages		( PackageConfig(..) )
import DriverPhases
import DriverState
import DriverUtil
import FastString
import Config

import DATA_IOREF	( readIORef )

import List
import Directory
import IO
import Monad
\end{code}

The Finder provides a thin filesystem abstraction to the rest of the
compiler.  For a given module, it knows (a) whether the module lives
in the home package or in another package, so it can make a Module
from a ModuleName, and (b) where the source, interface, and object
files for a module live.

It does *not* know which particular package a module lives in, because
that information is only contained in the interface file.

\begin{code}
initFinder :: [PackageConfig] -> IO ()
initFinder pkgs = return ()

-- empty, and lazilly fill in the package cache
flushPackageCache :: [PackageConfig] -> IO ()
flushPackageCache pkgs = return ()

emptyHomeDirCache :: IO ()
emptyHomeDirCache = return ()

findModule :: ModuleName -> IO (Maybe (Module, ModLocation))
findModule name = findModuleDep name False

findModuleDep :: ModuleName -> Bool -> IO (Maybe (Module, ModLocation))
findModuleDep name is_source
  = do	{ j <- maybeHomeModule name is_source
	; case j of
	    Just home_module -> return (Just home_module)
	    Nothing	     -> findPackageMod name False is_source
	}

maybeHomeModule :: ModuleName -> Bool -> IO (Maybe (Module, ModLocation))
maybeHomeModule mod_name is_source = do
   home_path <- readIORef v_Import_paths
   hisuf     <- readIORef v_Hi_suf
   mode      <- readIORef v_GhcMode

   let mod_str  = moduleNameUserString mod_name 
       basename = map (\c -> if c == '.' then '/' else c) mod_str
       
	-- In compilation manager modes, we look for source files in the home
	-- package because we can compile these automatically.  In one-shot
	-- compilation mode we look for .hi files only.
	--
	-- When generating dependencies, we're interested in either category.
	--
       source_exts = 
             [ ("hs",   \ fName path -> mkHomeModuleLocn mod_name path fName)
	     , ("lhs",  \ fName path -> mkHomeModuleLocn mod_name path fName)
	     ]
       hi_exts = [ (hisuf,  \ fName path -> mkHiOnlyModuleLocn mod_name fName) ]

       std_exts
         | mode == DoMkDependHS   = hi_exts ++ source_exts
         | isCompManagerMode mode = source_exts
	 | otherwise              = hi_exts

        -- last chance: .hi-boot-<ver> and .hi-boot
       hi_boot_ver = "hi-boot-" ++ cHscIfaceFileVersion

       boot_exts = 
       	[ (hi_boot_ver, \ fName path -> mkHiOnlyModuleLocn mod_name fName)
	, ("hi-boot",   \ fName path -> mkHiOnlyModuleLocn mod_name fName)
	]

   searchPathExts home_path basename
	(if is_source then boot_exts else (std_exts ++ boot_exts))
			-- for SOURCE imports, check the hi-boot extensions
			-- before the source/iface ones, to avoid
			-- creating circ Makefile deps.
   	

mkHiOnlyModuleLocn mod_name hi_file =
 return
   ( mkHomeModule mod_name
   , ModLocation{ ml_hspp_file = Nothing
    		   , ml_hs_file   = Nothing
		   , ml_hi_file   = hi_file
		   , ml_obj_file  = Nothing
	           }
   )

-- The .hi file always follows the module name, whereas the object
-- file may follow the name of the source file in the case where the
-- two differ (see summariseFile in compMan/CompManager.lhs).

mkHomeModuleLocn mod_name 
	basename		-- everything but the extension
	source_fn		-- full path to the source (required)
  = do

   hisuf  <- readIORef v_Hi_suf
   hidir  <- readIORef v_Hi_dir

   -- take the *last* component of the module name (if a hierarchical name),
   -- and append it to the directory to get the .hi file name.
   let (_,mod_str) = split_longest_prefix (moduleNameUserString mod_name) (=='.')
       hi_filename = mod_str ++ '.':hisuf
       hi_path | Just d <- hidir = d
	       | otherwise       = getdir basename
       hi = hi_path ++ '/':hi_filename

   -- figure out the .o file name.  It also lives in the same dir
   -- as the source, but can be overriden by a -odir flag.
   o_file <- odir_ify (basename ++ '.':phaseInputExt Ln) >>= osuf_ify

   return (mkHomeModule mod_name,
           ModLocation{ ml_hspp_file = Nothing
	   		 , ml_hs_file   = Just source_fn
			 , ml_hi_file   = hi
			 , ml_obj_file  = Just o_file
			 })

findPackageMod :: ModuleName
	       -> Bool
	       -> Bool
	       -> IO (Maybe (Module, ModLocation))
findPackageMod mod_name hiOnly is_source = do
  pkgs <- getPackageInfo

   -- hi-suffix for packages depends on the build tag.
  package_hisuf <-
	do tag <- readIORef v_Build_tag
	   if null tag
		then return "hi"
		else return (tag ++ "_hi")
  let imp_dirs = concatMap import_dirs pkgs
      mod_str  = moduleNameUserString mod_name 
      basename = map (\c -> if c == '.' then '/' else c) mod_str

      retPackageModule mod_name mbFName path =
        return ( mkPackageModule mod_name
               , ModLocation{ ml_hspp_file = Nothing
		 	       , ml_hs_file   = mbFName
			       , ml_hi_file   = path ++ '.':package_hisuf
			       , ml_obj_file  = Nothing
			       })

       -- last chance: .hi-boot-<ver> and .hi-boot
      hi_boot_ver = "hi-boot-" ++ cHscIfaceFileVersion

      boot_exts = 
      	[ (hi_boot_ver, \ fName path -> mkHiOnlyModuleLocn mod_name fName)
	, ("hi-boot",   \ fName path -> mkHiOnlyModuleLocn mod_name fName)
	]

  searchPathExts
  	imp_dirs basename
        (if is_source then boot_exts else 	
          ((package_hisuf,\ fName path -> retPackageModule mod_name Nothing path) :
     	   (if hiOnly then [] else
	     [ ("hs",  \ fName path -> retPackageModule mod_name (Just fName) path)
	     , ("lhs", \ fName path -> retPackageModule mod_name (Just fName) path)
	     ])))
 where

findPackageModule :: ModuleName -> IO (Maybe (Module, ModLocation))
findPackageModule mod_name = findPackageMod mod_name True False

searchPathExts :: [FilePath]
	       -> String
	       -> [(String, FilePath -> String -> IO (Module, ModLocation))] 
	       -> IO (Maybe (Module, ModLocation))
searchPathExts path basename exts = search path
  where
    search [] = return Nothing
    search (p:ps) = loop exts
      where	
	base | p == "."  = basename
	     | otherwise = p ++ '/':basename

	loop [] = search ps
	loop ((ext,fn):exts) = do
	    let file = base ++ '.':ext
	    b <- doesFileExist file
	    if b then Just `liftM` fn file base
		 else loop exts
\end{code}
