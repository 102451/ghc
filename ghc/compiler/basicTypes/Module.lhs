%
% (c) The University of Glasgow, 2004
%

Module
~~~~~~~~~~
Simply the name of a module, represented as a Z-encoded FastString.
These are Uniquable, hence we can build FiniteMaps with ModuleNames as
the keys.

\begin{code}
module Module 
    (
      Module, 		   	-- Abstract, instance of Eq, Ord, Outputable
    , pprModule			-- :: ModuleName -> SDoc

    , ModLocation(..),
    , showModMsg

    , moduleString		-- :: ModuleName -> EncodedString
    , moduleUserString		-- :: ModuleName -> UserString
    , moduleFS			-- :: ModuleName -> EncodedFS

    , mkModule			-- :: UserString -> ModuleName
    , mkModuleFS		-- :: UserFS    -> ModuleName
    , mkSysModuleFS		-- :: EncodedFS -> ModuleName
 
    , ModuleEnv,
    , elemModuleEnv, extendModuleEnv, extendModuleEnvList, plusModuleEnv_C
    , delModuleEnvList, delModuleEnv, plusModuleEnv, lookupModuleEnv
    , lookupWithDefaultModuleEnv, mapModuleEnv, mkModuleEnv, emptyModuleEnv
    , moduleEnvElts, unitModuleEnv, isEmptyModuleEnv, foldModuleEnv
    , extendModuleEnv_C

    , ModuleSet, emptyModuleSet, mkModuleSet, moduleSetElts, extendModuleSet, elemModuleSet

    ) where

#include "HsVersions.h"
import OccName
import Outputable
import Unique		( Uniquable(..) )
import Maybes		( expectJust )
import UniqFM
import UniqSet
import Binary
import StringBuffer	( StringBuffer )
import FastString
\end{code}

%************************************************************************
%*									*
\subsection{Module locations}
%*									*
%************************************************************************

\begin{code}
data ModLocation
   = ModLocation {
        ml_hs_file   :: Maybe FilePath,
		-- the source file, if we have one.  Package modules
		-- probably don't have source files.

        ml_hspp_file :: Maybe FilePath,
		-- filename of preprocessed source, if we have
		-- preprocessed it.
	ml_hspp_buf  :: Maybe StringBuffer,
		-- the actual preprocessed source, maybe.

        ml_hi_file   :: FilePath,
		-- Where the .hi file is, whether or not it exists
		-- yet.  Always of form foo.hi, even if there is an
		-- hi-boot file (we add the -boot suffix later)

        ml_obj_file  :: FilePath
		-- Where the .o file is, whether or not it exists yet.
		-- (might not exist either because the module hasn't
		-- been compiled yet, or because it is part of a
		-- package with a .a file)
  } deriving Show

instance Outputable ModLocation where
   ppr = text . show

-- Rather a gruesome function to have in Module

showModMsg :: Bool -> Module -> ModLocation -> String
showModMsg use_object mod location =
    mod_str ++ replicate (max 0 (16 - length mod_str)) ' '
    ++" ( " ++ expectJust "showModMsg" (ml_hs_file location) ++ ", "
    ++ (if use_object
	  then ml_obj_file location
	  else "interpreted")
    ++ " )"
 where mod_str = moduleUserString mod
\end{code}

For a module in another package, the hs_file and obj_file
components of ModLocation are undefined.  

The locations specified by a ModLocation may or may not
correspond to actual files yet: for example, even if the object
file doesn't exist, the ModLocation still contains the path to
where the object file will reside if/when it is created.


%************************************************************************
%*									*
\subsection{The name of a module}
%*									*
%************************************************************************

\begin{code}
newtype Module = Module EncodedFS
	-- Haskell module names can include the quote character ',
	-- so the module names have the z-encoding applied to them

instance Binary Module where
   put_ bh (Module m) = put_ bh m
   get bh = do m <- get bh; return (Module m)

instance Uniquable Module where
  getUnique (Module nm) = getUnique nm

instance Eq Module where
  nm1 == nm2 = getUnique nm1 == getUnique nm2

-- Warning: gives an ordering relation based on the uniques of the
-- FastStrings which are the (encoded) module names.  This is _not_
-- a lexicographical ordering.
instance Ord Module where
  nm1 `compare` nm2 = getUnique nm1 `compare` getUnique nm2

instance Outputable Module where
  ppr = pprModule


pprModule :: Module -> SDoc
pprModule (Module nm) = pprEncodedFS nm

moduleFS :: Module -> EncodedFS
moduleFS (Module mod) = mod

moduleString :: Module -> EncodedString
moduleString (Module mod) = unpackFS mod

moduleUserString :: Module -> UserString
moduleUserString (Module mod) = decode (unpackFS mod)

-- used to be called mkSrcModule
mkModule :: UserString -> Module
mkModule s = Module (mkFastString (encode s))

-- used to be called mkSrcModuleFS
mkModuleFS :: UserFS -> Module
mkModuleFS s = Module (encodeFS s)

-- used to be called mkSysModuleFS
mkSysModuleFS :: EncodedFS -> Module
mkSysModuleFS s = Module s 
\end{code}

%************************************************************************
%*                                                                      *
\subsection{@ModuleEnv@s}
%*                                                                      *
%************************************************************************

\begin{code}
type ModuleEnv elt = UniqFM elt

emptyModuleEnv       :: ModuleEnv a
mkModuleEnv          :: [(Module, a)] -> ModuleEnv a
unitModuleEnv        :: Module -> a -> ModuleEnv a
extendModuleEnv      :: ModuleEnv a -> Module -> a -> ModuleEnv a
extendModuleEnv_C    :: (a->a->a) -> ModuleEnv a -> Module -> a -> ModuleEnv a
plusModuleEnv        :: ModuleEnv a -> ModuleEnv a -> ModuleEnv a
extendModuleEnvList  :: ModuleEnv a -> [(Module, a)] -> ModuleEnv a
                  
delModuleEnvList     :: ModuleEnv a -> [Module] -> ModuleEnv a
delModuleEnv         :: ModuleEnv a -> Module -> ModuleEnv a
plusModuleEnv_C      :: (a -> a -> a) -> ModuleEnv a -> ModuleEnv a -> ModuleEnv a
mapModuleEnv         :: (a -> b) -> ModuleEnv a -> ModuleEnv b
moduleEnvElts        :: ModuleEnv a -> [a]
                  
isEmptyModuleEnv     :: ModuleEnv a -> Bool
lookupModuleEnv      :: ModuleEnv a -> Module     -> Maybe a
lookupWithDefaultModuleEnv :: ModuleEnv a -> a -> Module -> a
elemModuleEnv        :: Module -> ModuleEnv a -> Bool
foldModuleEnv        :: (a -> b -> b) -> b -> ModuleEnv a -> b

elemModuleEnv       = elemUFM
extendModuleEnv     = addToUFM
extendModuleEnv_C   = addToUFM_C
extendModuleEnvList = addListToUFM
plusModuleEnv_C     = plusUFM_C
delModuleEnvList    = delListFromUFM
delModuleEnv        = delFromUFM
plusModuleEnv       = plusUFM
lookupModuleEnv     = lookupUFM
lookupWithDefaultModuleEnv = lookupWithDefaultUFM
mapModuleEnv        = mapUFM
mkModuleEnv         = listToUFM
emptyModuleEnv      = emptyUFM
moduleEnvElts       = eltsUFM
unitModuleEnv       = unitUFM
isEmptyModuleEnv    = isNullUFM
foldModuleEnv       = foldUFM
\end{code}

\begin{code}
type ModuleSet = UniqSet Module
mkModuleSet	:: [Module] -> ModuleSet
extendModuleSet :: ModuleSet -> Module -> ModuleSet
emptyModuleSet  :: ModuleSet
moduleSetElts   :: ModuleSet -> [Module]
elemModuleSet   :: Module -> ModuleSet -> Bool

emptyModuleSet  = emptyUniqSet
mkModuleSet     = mkUniqSet
extendModuleSet = addOneToUniqSet
moduleSetElts   = uniqSetToList
elemModuleSet   = elementOfUniqSet
\end{code}
