%
% (c) The University of Glasgow, 2000
%
\section[HscTypes]{Types for the per-module compiler}

\begin{code}
module HscTypes ( 
	GhciMode(..),

	ModuleLocation(..), showModMsg,

	ModDetails(..),	ModIface(..), 
	HomeSymbolTable, emptySymbolTable,
	PackageTypeEnv,
	HomeIfaceTable, PackageIfaceTable, emptyIfaceTable,
	lookupIface, lookupIfaceByModName, moduleNameToModule,
	emptyModIface,

	InteractiveContext(..),

	IfaceDecls, mkIfaceDecls, dcl_tycl, dcl_rules, dcl_insts,

	VersionInfo(..), initialVersionInfo, lookupVersion,
	FixityEnv, lookupFixity, collectFixities,

	TyThing(..), isTyClThing, implicitTyThingIds,

	TypeEnv, lookupType, mkTypeEnv, emptyTypeEnv,
	extendTypeEnvList, extendTypeEnvWithIds,
	typeEnvElts, typeEnvClasses, typeEnvTyCons, typeEnvIds,

	ImportedModuleInfo, WhetherHasOrphans, ImportVersion, WhatsImported(..),
	PersistentRenamerState(..), IsBootInterface, DeclsMap,
	IfaceInsts, IfaceRules, GatedDecl, GatedDecls, GateFn, IsExported,
	NameSupply(..), OrigNameCache, OrigIParamCache,
	Avails, AvailEnv, emptyAvailEnv,
	GenAvailInfo(..), AvailInfo, RdrAvailInfo, 
	ExportItem, RdrExportItem,
	PersistentCompilerState(..),

	Deprecations(..), lookupDeprec,

	InstEnv, ClsInstEnv, DFunId,
	PackageInstEnv, PackageRuleBase,

	GlobalRdrEnv, GlobalRdrElt(..), pprGlobalRdrEnv,
	LocalRdrEnv, extendLocalRdrEnv,
	

	-- Provenance
	Provenance(..), ImportReason(..), 
        pprNameProvenance, hasBetterProv

    ) where

#include "HsVersions.h"

import RdrName		( RdrName, RdrNameEnv, addListToRdrEnv, 
			  mkRdrUnqual, rdrEnvToList )
import Name		( Name, NamedThing, getName, nameOccName, nameModule, nameSrcLoc )
import NameEnv
import OccName		( OccName )
import Module
import InstEnv		( InstEnv, ClsInstEnv, DFunId )
import Rules		( RuleBase )
import CoreSyn		( CoreBind )
import Id		( Id )
import Class		( Class, classSelIds )
import TyCon		( TyCon, isNewTyCon, tyConGenIds, tyConSelIds, tyConDataCons_maybe )
import DataCon		( dataConWorkId, dataConWrapId )

import BasicTypes	( Version, initialVersion, Fixity, defaultFixity, IPName )

import HsSyn		( DeprecTxt, TyClDecl, tyClDeclName, ifaceRuleDeclName,
			  tyClDeclNames )
import RdrHsSyn		( RdrNameInstDecl, RdrNameRuleDecl, RdrNameTyClDecl )
import RnHsSyn		( RenamedTyClDecl, RenamedRuleDecl, RenamedInstDecl )

import CoreSyn		( IdCoreRule )

import FiniteMap
import Bag		( Bag )
import Maybes		( seqMaybe, orElse, expectJust )
import Outputable
import SrcLoc		( SrcLoc, isGoodSrcLoc )
import Util		( thenCmp, sortLt )
import UniqSupply	( UniqSupply )
import Maybe		( fromJust )
\end{code}

%************************************************************************
%*									*
\subsection{Which mode we're in
%*									*
%************************************************************************

\begin{code}
data GhciMode = Batch | Interactive | OneShot 
     deriving Eq
\end{code}


%************************************************************************
%*									*
\subsection{Module locations}
%*									*
%************************************************************************

\begin{code}
data ModuleLocation
   = ModuleLocation {
        ml_hs_file   :: Maybe FilePath,
        ml_hspp_file :: Maybe FilePath,  -- path of preprocessed source
        ml_hi_file   :: FilePath,
        ml_obj_file  :: Maybe FilePath
     }
     deriving Show

instance Outputable ModuleLocation where
   ppr = text . show

-- Probably doesn't really belong here, but used in HscMain and InteractiveUI.

showModMsg :: Bool -> Module -> ModuleLocation -> String
showModMsg use_object mod location =
    mod_str ++ replicate (max 0 (16 - length mod_str)) ' '
    ++" ( " ++ expectJust "showModMsg" (ml_hs_file location) ++ ", "
    ++ (if use_object
	  then expectJust "showModMsg" (ml_obj_file location)
	  else "interpreted")
    ++ " )"
 where mod_str = moduleUserString mod
\end{code}

For a module in another package, the hs_file and obj_file
components of ModuleLocation are undefined.  

The locations specified by a ModuleLocation may or may not
correspond to actual files yet: for example, even if the object
file doesn't exist, the ModuleLocation still contains the path to
where the object file will reside if/when it is created.


%************************************************************************
%*									*
\subsection{Symbol tables and Module details}
%*									*
%************************************************************************

A @ModIface@ plus a @ModDetails@ summarises everything we know 
about a compiled module.  The @ModIface@ is the stuff *before* linking,
and can be written out to an interface file.  (The @ModDetails@ is after 
linking; it is the "linked" form of the mi_decls field.)

When we *read* an interface file, we also construct a @ModIface@ from it,
except that the mi_decls part is empty; when reading we consolidate
the declarations into a single indexed map in the @PersistentRenamerState@.

\begin{code}
data ModIface 
   = ModIface {
        mi_module   :: !Module,
	mi_package  :: !PackageName,	    -- Which package the module comes from
        mi_version  :: !VersionInfo,	    -- Module version number

        mi_orphan   :: WhetherHasOrphans,   -- Whether this module has orphans
		-- NOT STRICT!  we fill this field with _|_ sometimes

	mi_boot	    :: !IsBootInterface,    -- read from an hi-boot file?

        mi_usages   :: ![ImportVersion Name],	
		-- Usages; kept sorted so that it's easy to decide
		-- whether to write a new iface file (changing usages
		-- doesn't affect the version of this module)

        mi_exports  :: ![ExportItem],
		-- What it exports Kept sorted by (mod,occ), to make
		-- version comparisons easier

        mi_globals  :: !(Maybe GlobalRdrEnv),
		-- Its top level environment or Nothing if we read this
		-- interface from a file.

        mi_fixities :: !FixityEnv,	    -- Fixities
	mi_deprecs  :: !Deprecations,	    -- Deprecations

	mi_decls    :: IfaceDecls	    -- The RnDecls form of ModDetails
		-- NOT STRICT!  we fill this field with _|_ sometimes
     }

data IfaceDecls = IfaceDecls { dcl_tycl  :: [RenamedTyClDecl],	-- Sorted
			       dcl_rules :: [RenamedRuleDecl],	-- Sorted
			       dcl_insts :: [RenamedInstDecl] }	-- Unsorted

mkIfaceDecls :: [RenamedTyClDecl] -> [RenamedRuleDecl] -> [RenamedInstDecl] -> IfaceDecls
mkIfaceDecls tycls rules insts
  = IfaceDecls { dcl_tycl  = sortLt lt_tycl tycls,
		 dcl_rules = sortLt lt_rule rules,
		 dcl_insts = insts }
  where
    d1 `lt_tycl` d2 = tyClDeclName      d1 < tyClDeclName      d2
    r1 `lt_rule` r2 = ifaceRuleDeclName r1 < ifaceRuleDeclName r2


-- typechecker should only look at this, not ModIface
-- Should be able to construct ModDetails from mi_decls in ModIface
data ModDetails
   = ModDetails {
	-- The next three fields are created by the typechecker
        md_types    :: !TypeEnv,
        md_insts    :: ![DFunId],	-- Dfun-ids for the instances in this module
        md_rules    :: ![IdCoreRule],	-- Domain may include Ids from other modules
	md_binds    :: ![CoreBind]
     }

-- The ModDetails takes on several slightly different forms:
--
-- After typecheck + desugar
--	md_types	Contains TyCons, Classes, and implicit Ids
--	md_insts	All instances from this module (incl derived ones)
--	md_rules	All rules from this module
--	md_binds	Desugared bindings
--
-- After simplification
--	md_types	Same as after typecheck
--	md_insts	Ditto
--	md_rules	Orphan rules only (local ones now attached to binds)
--	md_binds	With rules attached
--
-- After CoreTidy
--	md_types	Now contains Ids as well, replete with final IdInfo
--			   The Ids are only the ones that are visible from
--			   importing modules.  Without -O that means only
--			   exported Ids, but with -O importing modules may
--			   see ids mentioned in unfoldings of exported Ids
--
--	md_insts	Same DFunIds as before, but with final IdInfo,
--			   and the unique might have changed; remember that
--			   CoreTidy links up the uniques of old and new versions
--
--	md_rules	All rules for exported things, substituted with final Ids
--
--	md_binds	Tidied
--
-- Passed back to compilation manager
--	Just as after CoreTidy, but with md_binds nuked

\end{code}

\begin{code}
emptyModIface :: Module -> ModIface
emptyModIface mod
  = ModIface { mi_module   = mod,
	       mi_package  = preludePackage, -- XXX fully bogus
	       mi_version  = initialVersionInfo,
	       mi_usages   = [],
	       mi_orphan   = False,
	       mi_boot	   = False,
	       mi_exports  = [],
	       mi_fixities = emptyNameEnv,
	       mi_globals  = Nothing,
	       mi_deprecs  = NoDeprecs,
	       mi_decls    = panic "emptyModIface: decls"
    }		
\end{code}

Symbol tables map modules to ModDetails:

\begin{code}
type SymbolTable	= ModuleEnv ModDetails
type IfaceTable		= ModuleEnv ModIface

type HomeIfaceTable     = IfaceTable
type PackageIfaceTable  = IfaceTable

type HomeSymbolTable    = SymbolTable	-- Domain = modules in the home package

emptySymbolTable :: SymbolTable
emptySymbolTable = emptyModuleEnv

emptyIfaceTable :: IfaceTable
emptyIfaceTable = emptyModuleEnv
\end{code}

Simple lookups in the symbol table.

\begin{code}
lookupIface :: HomeIfaceTable -> PackageIfaceTable -> Name -> Maybe ModIface
-- We often have two IfaceTables, and want to do a lookup
lookupIface hit pit name
  = lookupModuleEnv hit mod `seqMaybe` lookupModuleEnv pit mod
  where
    mod = nameModule name

lookupIfaceByModName :: HomeIfaceTable -> PackageIfaceTable -> ModuleName -> Maybe ModIface
-- We often have two IfaceTables, and want to do a lookup
lookupIfaceByModName hit pit mod
  = lookupModuleEnvByName hit mod `seqMaybe` lookupModuleEnvByName pit mod

-- Use instead of Finder.findModule if possible: this way doesn't
-- require filesystem operations, and it is guaranteed not to fail
-- when the IfaceTables are properly populated (i.e. after the renamer).
moduleNameToModule :: HomeIfaceTable -> PackageIfaceTable -> ModuleName
   -> Module
moduleNameToModule hit pit mod 
   = mi_module (fromJust (lookupIfaceByModName hit pit mod))
\end{code}


%************************************************************************
%*									*
\subsection{The interactive context}
%*									*
%************************************************************************

\begin{code}
data InteractiveContext 
  = InteractiveContext { 
	ic_toplev_scope :: [Module],	-- Include the "top-level" scope of
					-- these modules

	ic_exports :: [Module],		-- Include just the exports of these
					-- modules

	ic_rn_gbl_env :: GlobalRdrEnv,	-- The cached GlobalRdrEnv, built from
					-- ic_toplev_scope and ic_exports

	ic_print_unqual :: PrintUnqualified,
					-- cached PrintUnqualified, as above

	ic_rn_local_env :: LocalRdrEnv,	-- Lexical context for variables bound
					-- during interaction

	ic_type_env :: TypeEnv		-- Ditto for types
    }
\end{code}


%************************************************************************
%*									*
\subsection{Type environment stuff}
%*									*
%************************************************************************

\begin{code}
data TyThing = AnId   Id
	     | ATyCon TyCon
	     | AClass Class

isTyClThing :: TyThing -> Bool
isTyClThing (ATyCon _) = True
isTyClThing (AClass _) = True
isTyClThing (AnId   _) = False

instance NamedThing TyThing where
  getName (AnId id)   = getName id
  getName (ATyCon tc) = getName tc
  getName (AClass cl) = getName cl

instance Outputable TyThing where
  ppr (AnId   id) = ptext SLIT("AnId")   <+> ppr id
  ppr (ATyCon tc) = ptext SLIT("ATyCon") <+> ppr tc
  ppr (AClass cl) = ptext SLIT("AClass") <+> ppr cl


typeEnvElts    :: TypeEnv -> [TyThing]
typeEnvClasses :: TypeEnv -> [Class]
typeEnvTyCons  :: TypeEnv -> [TyCon]
typeEnvIds     :: TypeEnv -> [Id]

typeEnvElts    env = nameEnvElts env
typeEnvClasses env = [cl | AClass cl <- typeEnvElts env]
typeEnvTyCons  env = [tc | ATyCon tc <- typeEnvElts env] 
typeEnvIds     env = [id | AnId id   <- typeEnvElts env] 

implicitTyThingIds :: [TyThing] -> [Id]
-- Add the implicit data cons and selectors etc 
implicitTyThingIds things
  = concat (map go things)
  where
    go (AnId f)    = []
    go (AClass cl) = classSelIds cl
    go (ATyCon tc) = tyConGenIds tc ++
		     tyConSelIds tc ++
		     [ n | dc <- tyConDataCons_maybe tc `orElse` [],
			   n  <- implicitConIds tc dc]
		-- Synonyms return empty list of constructors and selectors

    implicitConIds tc dc	-- Newtypes have a constructor wrapper,
				-- but no worker
	| isNewTyCon tc = [dataConWrapId dc]
	| otherwise     = [dataConWorkId dc, dataConWrapId dc]
\end{code}


\begin{code}
type TypeEnv = NameEnv TyThing

emptyTypeEnv = emptyNameEnv

mkTypeEnv :: [TyThing] -> TypeEnv
mkTypeEnv things = extendTypeEnvList emptyTypeEnv things
		
extendTypeEnvList :: TypeEnv -> [TyThing] -> TypeEnv
extendTypeEnvList env things
  = extendNameEnvList env [(getName thing, thing) | thing <- things]

extendTypeEnvWithIds :: TypeEnv -> [Id] -> TypeEnv
extendTypeEnvWithIds env ids
  = extendNameEnvList env [(getName id, AnId id) | id <- ids]
\end{code}

\begin{code}
lookupType :: HomeSymbolTable -> PackageTypeEnv -> Name -> Maybe TyThing
lookupType hst pte name
  = case lookupModuleEnv hst (nameModule name) of
	Just details -> lookupNameEnv (md_types details) name
	Nothing	     -> lookupNameEnv pte name
\end{code}

%************************************************************************
%*									*
\subsection{Auxiliary types}
%*									*
%************************************************************************

These types are defined here because they are mentioned in ModDetails,
but they are mostly elaborated elsewhere

\begin{code}
data VersionInfo 
  = VersionInfo {
	vers_module  :: Version,	-- Changes when anything changes
	vers_exports :: Version,	-- Changes when export list changes
	vers_rules   :: Version,	-- Changes when any rule changes
	vers_decls   :: NameEnv Version
		-- Versions for "big" names only (not data constructors, class ops)
		-- The version of an Id changes if its fixity changes
		-- Ditto data constructors, class operations, except that the version of
		-- the parent class/tycon changes
		--
		-- If a name isn't in the map, it means 'initialVersion'
    }

initialVersionInfo :: VersionInfo
initialVersionInfo = VersionInfo { vers_module  = initialVersion,
				   vers_exports = initialVersion,
				   vers_rules   = initialVersion,
				   vers_decls   = emptyNameEnv
			}

lookupVersion :: NameEnv Version -> Name -> Version
lookupVersion env name = lookupNameEnv env name `orElse` initialVersion

data Deprecations = NoDeprecs
	 	  | DeprecAll DeprecTxt				-- Whole module deprecated
		  | DeprecSome (NameEnv (Name,DeprecTxt))	-- Some things deprecated
								-- Just "big" names
		-- We keep the Name in the range, so we can print them out

lookupDeprec :: Deprecations -> Name -> Maybe DeprecTxt
lookupDeprec NoDeprecs        name = Nothing
lookupDeprec (DeprecAll  txt) name = Just txt
lookupDeprec (DeprecSome env) name = case lookupNameEnv env name of
					    Just (_, txt) -> Just txt
					    Nothing	  -> Nothing

instance Eq Deprecations where
  -- Used when checking whether we need write a new interface
  NoDeprecs       == NoDeprecs	     = True
  (DeprecAll t1)  == (DeprecAll t2)  = t1 == t2
  (DeprecSome e1) == (DeprecSome e2) = nameEnvElts e1 == nameEnvElts e2
  d1		  == d2		     = False
\end{code}


\begin{code}
type Avails	  = [AvailInfo]
type AvailInfo    = GenAvailInfo Name
type RdrAvailInfo = GenAvailInfo OccName

data GenAvailInfo name	= Avail name	 -- An ordinary identifier
			| AvailTC name 	 -- The name of the type or class
				  [name] -- The available pieces of type/class.
					 -- NB: If the type or class is itself
					 -- to be in scope, it must be in this list.
					 -- Thus, typically: AvailTC Eq [Eq, ==, /=]
			deriving( Eq )
			-- Equality used when deciding if the interface has changed

type RdrExportItem = (ModuleName, [RdrAvailInfo])
type ExportItem    = (ModuleName, [AvailInfo])

type AvailEnv = NameEnv AvailInfo	-- Maps a Name to the AvailInfo that contains it

emptyAvailEnv :: AvailEnv
emptyAvailEnv = emptyNameEnv

instance Outputable n => Outputable (GenAvailInfo n) where
   ppr = pprAvail

pprAvail :: Outputable n => GenAvailInfo n -> SDoc
pprAvail (AvailTC n ns) = ppr n <> case {- filter (/= n) -} ns of
					[]  -> empty
					ns' -> braces (hsep (punctuate comma (map ppr ns')))

pprAvail (Avail n) = ppr n
\end{code}

\begin{code}
type FixityEnv = NameEnv Fixity

lookupFixity :: FixityEnv -> Name -> Fixity
lookupFixity env n = lookupNameEnv env n `orElse` defaultFixity

collectFixities :: FixityEnv -> [TyClDecl Name pat] -> [(Name,Fixity)]
collectFixities env decls
  = [ (n, fix) 
    | d <- decls, (n,_) <- tyClDeclNames d,
      Just fix <- [lookupNameEnv env n]
    ]
\end{code}


%************************************************************************
%*									*
\subsection{ModIface}
%*									*
%************************************************************************

\begin{code}
type WhetherHasOrphans   = Bool
	-- An "orphan" is 
	-- 	* an instance decl in a module other than the defn module for 
	--		one of the tycons or classes in the instance head
	--	* a transformation rule in a module other than the one defining
	--		the function in the head of the rule.

type IsBootInterface     = Bool

type ImportVersion name  = (ModuleName, WhetherHasOrphans, IsBootInterface, WhatsImported name)

data WhatsImported name  = NothingAtAll				-- The module is below us in the
								-- hierarchy, but we import nothing

			 | Everything Version		-- Used for modules from other packages;
							-- we record only the module's version number

			 | Specifically 
				Version			-- Module version
				(Maybe Version)		-- Export-list version, if we depend on it
				[(name,Version)]	-- List guaranteed non-empty
				Version			-- Rules version

			 deriving( Eq )
	-- 'Specifically' doesn't let you say "I imported f but none of the rules in
	-- the module". If you use anything in the module you get its rule version
	-- So if the rules change, you'll recompile, even if you don't use them.
	-- This is easy to implement, and it's safer: you might not have used the rules last
	-- time round, but if someone has added a new rule you might need it this time

	-- The export list field is (Just v) if we depend on the export list:
	--	we imported the module without saying exactly what we imported
	-- We need to recompile if the module exports changes, because we might
	-- now have a name clash in the importing module.

type IsExported = Name -> Bool		-- True for names that are exported from this module
\end{code}


%************************************************************************
%*									*
\subsection{The persistent compiler state}
%*									*
%************************************************************************

The @PersistentCompilerState@ persists across successive calls to the
compiler.

  * A ModIface for each non-home-package module

  * An accumulated TypeEnv from all the modules in imported packages

  * An accumulated InstEnv from all the modules in imported packages
    The point is that we don't want to keep recreating it whenever
    we compile a new module.  The InstEnv component of pcPST is empty.
    (This means we might "see" instances that we shouldn't "really" see;
    but the Haskell Report is vague on what is meant to be visible, 
    so we just take the easy road here.)

  * Ditto for rules
 
  * The persistent renamer state

\begin{code}
data PersistentCompilerState 
   = PCS {
        pcs_PIT :: !PackageIfaceTable,	-- Domain = non-home-package modules
					--   the mi_decls component is empty

        pcs_PTE :: !PackageTypeEnv,	-- Domain = non-home-package modules
					--   except that the InstEnv components is empty

	pcs_insts :: !PackageInstEnv,	-- The total InstEnv accumulated from all
					--   the non-home-package modules

	pcs_rules :: !PackageRuleBase,	-- Ditto RuleEnv

        pcs_PRS :: !PersistentRenamerState
     }
\end{code}


The persistent renamer state contains:

  * A name supply, which deals with allocating unique names to
    (Module,OccName) original names, 
 
  * A "holding pen" for declarations that have been read out of
    interface files but not yet sucked in, renamed, and typechecked

\begin{code}
type PackageTypeEnv  = TypeEnv
type PackageRuleBase = RuleBase
type PackageInstEnv  = InstEnv

data PersistentRenamerState
  = PRS { prsOrig    :: !NameSupply,
	  prsImpMods :: !ImportedModuleInfo,

		-- Holding pens for stuff that has been read in
		-- but not yet slurped into the renamer
	  prsDecls   :: !DeclsMap,
	  prsInsts   :: !IfaceInsts,
	  prsRules   :: !IfaceRules
    }
\end{code}

The NameSupply makes sure that there is just one Unique assigned for
each original name; i.e. (module-name, occ-name) pair.  The Name is
always stored as a Global, and has the SrcLoc of its binding location.
Actually that's not quite right.  When we first encounter the original
name, we might not be at its binding site (e.g. we are reading an
interface file); so we give it 'noSrcLoc' then.  Later, when we find
its binding site, we fix it up.

Exactly the same is true of the Module stored in the Name.  When we first
encounter the occurrence, we may not know the details of the module, so
we just store junk.  Then when we find the binding site, we fix it up.

\begin{code}
data NameSupply
 = NameSupply { nsUniqs :: UniqSupply,
		-- Supply of uniques
		nsNames :: OrigNameCache,
		-- Ensures that one original name gets one unique
		nsIPs   :: OrigIParamCache
		-- Ensures that one implicit parameter name gets one unique
   }

type OrigNameCache   = FiniteMap (ModuleName,OccName) Name
type OrigIParamCache = FiniteMap (IPName RdrName) (IPName Name)
\end{code}

@ImportedModuleInfo@ contains info ONLY about modules that have not yet 
been loaded into the iPIT.  These modules are mentioned in interfaces we've
already read, so we know a tiny bit about them, but we havn't yet looked
at the interface file for the module itself.  It needs to persist across 
invocations of the renamer, at least from Rename.checkOldIface to Rename.renameSource.
And there's no harm in it persisting across multiple compilations.

\begin{code}
type ImportedModuleInfo = FiniteMap ModuleName (WhetherHasOrphans, IsBootInterface)
\end{code}

A DeclsMap contains a binding for each Name in the declaration
including the constructors of a type decl etc.  The Bool is True just
for the 'main' Name.

\begin{code}
type DeclsMap = (NameEnv (AvailInfo, Bool, (Module, RdrNameTyClDecl)), Int)
						-- The Int says how many have been sucked in

type IfaceInsts = GatedDecls RdrNameInstDecl
type IfaceRules = GatedDecls RdrNameRuleDecl

type GatedDecls d = (Bag (GatedDecl d), Int)	-- The Int says how many have been sucked in
type GatedDecl  d = (GateFn, (Module, d))
type GateFn       = (Name -> Bool) -> Bool	-- Returns True <=> gate is open
						-- The (Name -> Bool) fn returns True for visible Names
	-- For example, suppose this is in an interface file
	--	instance C T where ...
	-- We want to slurp this decl if both C and T are "visible" in 
	-- the importing module.  See "The gating story" in RnIfaces for details.
\end{code}


%************************************************************************
%*									*
\subsection{Provenance and export info}
%*									*
%************************************************************************

A LocalRdrEnv is used for local bindings (let, where, lambda, case)

\begin{code}
type LocalRdrEnv = RdrNameEnv Name

extendLocalRdrEnv :: LocalRdrEnv -> [Name] -> LocalRdrEnv
extendLocalRdrEnv env names
  = addListToRdrEnv env [(mkRdrUnqual (nameOccName n), n) | n <- names]
\end{code}

The GlobalRdrEnv gives maps RdrNames to Names.  There is a separate
one for each module, corresponding to that module's top-level scope.

\begin{code}
type GlobalRdrEnv = RdrNameEnv [GlobalRdrElt]
	-- The list is because there may be name clashes
	-- These only get reported on lookup, not on construction

data GlobalRdrElt = GRE Name Provenance (Maybe DeprecTxt)
	-- The Maybe DeprecTxt tells whether this name is deprecated

pprGlobalRdrEnv env
  = vcat (map pp (rdrEnvToList env))
  where
    pp (rn, nps) = ppr rn <> colon <+> 
		   vcat [ppr n <+> pprNameProvenance n p | (GRE n p _) <- nps]
\end{code}

The "provenance" of something says how it came to be in scope.

\begin{code}
data Provenance
  = LocalDef			-- Defined locally

  | NonLocalDef  		-- Defined non-locally
	ImportReason

-- Just used for grouping error messages (in RnEnv.warnUnusedBinds)
instance Eq Provenance where
  p1 == p2 = case p1 `compare` p2 of EQ -> True; _ -> False

instance Eq ImportReason where
  p1 == p2 = case p1 `compare` p2 of EQ -> True; _ -> False

instance Ord Provenance where
   compare LocalDef LocalDef = EQ
   compare LocalDef (NonLocalDef _) = LT
   compare (NonLocalDef _) LocalDef = GT

   compare (NonLocalDef reason1) (NonLocalDef reason2) 
      = compare reason1 reason2

instance Ord ImportReason where
   compare ImplicitImport ImplicitImport = EQ
   compare ImplicitImport (UserImport _ _ _) = LT
   compare (UserImport _ _ _) ImplicitImport = GT
   compare (UserImport m1 loc1 _) (UserImport m2 loc2 _) 
      = (m1 `compare` m2) `thenCmp` (loc1 `compare` loc2)


data ImportReason
  = UserImport Module SrcLoc Bool	-- Imported from module M on line L
					-- Note the M may well not be the defining module
					-- for this thing!
	-- The Bool is true iff the thing was named *explicitly* in the import spec,
	-- rather than being imported as part of a group; e.g.
	--	import B
	--	import C( T(..) )
	-- Here, everything imported by B, and the constructors of T
	-- are not named explicitly; only T is named explicitly.
	-- This info is used when warning of unused names.

  | ImplicitImport			-- Imported implicitly for some other reason
\end{code}

\begin{code}
hasBetterProv :: Provenance -> Provenance -> Bool
-- Choose 
--	a local thing		      over an	imported thing
--	a user-imported thing	      over a	non-user-imported thing
-- 	an explicitly-imported thing  over an	implicitly imported thing
hasBetterProv LocalDef 				  _			       = True
hasBetterProv (NonLocalDef (UserImport _ _ _   )) (NonLocalDef ImplicitImport) = True
hasBetterProv _					  _			       = False

pprNameProvenance :: Name -> Provenance -> SDoc
pprNameProvenance name LocalDef   	 = ptext SLIT("defined at") <+> ppr (nameSrcLoc name)
pprNameProvenance name (NonLocalDef why) = sep [ppr_reason why, 
					        nest 2 (ppr_defn (nameSrcLoc name))]

ppr_reason ImplicitImport	  = ptext SLIT("implicitly imported")
ppr_reason (UserImport mod loc _) = ptext SLIT("imported from") <+> ppr mod <+> ptext SLIT("at") <+> ppr loc

ppr_defn loc | isGoodSrcLoc loc = parens (ptext SLIT("at") <+> ppr loc)
	     | otherwise	= empty
\end{code}
