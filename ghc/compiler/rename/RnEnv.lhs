%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnEnv]{Environment manipulation for the renamer monad}

\begin{code}
module RnEnv where		-- Export everything

#include "HsVersions.h"

import {-# SOURCE #-} RnHiFiles( loadInterface )

import FlattenInfo      ( namesNeededForFlattening )
import HsSyn
import RnHsSyn		( RenamedFixitySig )
import RdrHsSyn		( RdrNameIE, RdrNameHsType, RdrNameFixitySig, extractHsTyRdrTyVars )
import RdrName		( RdrName, rdrNameModule, rdrNameOcc, isQual, isUnqual, isOrig,
			  mkRdrUnqual, mkRdrQual, setRdrNameOcc,
			  lookupRdrEnv, foldRdrEnv, rdrEnvToList, elemRdrEnv,
			  unqualifyRdrName
			)
import HsTypes		( hsTyVarName, replaceTyVarName )
import HscTypes		( Provenance(..), pprNameProvenance, hasBetterProv,
			  ImportReason(..), GlobalRdrEnv, GlobalRdrElt(..), AvailEnv,
			  AvailInfo, Avails, GenAvailInfo(..), NameSupply(..), 
			  ModIface(..), GhciMode(..),
			  Deprecations(..), lookupDeprec,
			  extendLocalRdrEnv, lookupFixity
			)
import RnMonad
import Name		( Name, 
			  getSrcLoc, nameIsLocalOrFrom,
			  mkInternalName, mkExternalName,
			  mkIPName, nameOccName, nameModule_maybe,
			  setNameModuleAndLoc, nameModule
			)
import NameEnv
import NameSet
import OccName		( OccName, occNameUserString, occNameFlavour, 
			  isDataSymOcc, setOccNameSpace, tcName )
import Module		( ModuleName, moduleName, mkVanillaModule, 
			  mkSysModuleNameFS, moduleNameFS, WhereFrom(..) )
import PrelNames	( mkUnboundName, 
			  derivingOccurrences,
			  mAIN_Name, main_RDR_Unqual,
			  runMainName, intTyConName, 
			  boolTyConName, funTyConName,
			  unpackCStringName, unpackCStringFoldrName, unpackCStringUtf8Name,
			  eqStringName, printName, 
			  bindIOName, returnIOName, failIOName, thenIOName
			)
import TysWiredIn	( unitTyCon )	-- A little odd
import FiniteMap
import UniqSupply
import SrcLoc		( SrcLoc, noSrcLoc )
import Outputable
import ListSetOps	( removeDups, equivClasses )
import Util		( sortLt )
import BasicTypes	( mapIPName, defaultFixity )
import List		( nub )
import UniqFM		( lookupWithDefaultUFM )
import Maybe		( mapMaybe )
import Maybes		( orElse, catMaybes )
import CmdLineOpts
import FastString	( FastString )
\end{code}

%*********************************************************
%*							*
\subsection{Making new names}
%*							*
%*********************************************************

\begin{code}
newTopBinder :: Module -> RdrName -> SrcLoc -> RnM d Name
	-- newTopBinder puts into the cache the binder with the
	-- module information set correctly.  When the decl is later renamed,
	-- the binding site will thereby get the correct module.
	-- There maybe occurrences that don't have the correct Module, but
	-- by the typechecker will propagate the binding definition to all 
	-- the occurrences, so that doesn't matter

newTopBinder mod rdr_name loc
  = 	-- First check the cache

    	-- There should never be a qualified name in a binding position (except in instance decls)
	-- The parser doesn't check this because the same parser parses instance decls
    (if isQual rdr_name then
	qualNameErr (text "In its declaration") (rdr_name,loc)
     else
	returnRn ()
    )				`thenRn_`

    getNameSupplyRn		`thenRn` \ name_supply -> 
    let 
	occ = rdrNameOcc rdr_name
	key = (moduleName mod, occ)
	cache = nsNames name_supply
    in
    case lookupFM cache key of

	-- A hit in the cache!  We are at the binding site of the name, and
	-- this is the moment when we know all about 
	--	a) the Name's host Module (in particular, which
	-- 	   package it comes from)
	--	b) its defining SrcLoc
	-- So we update this info

	Just name -> let 
			new_name  = setNameModuleAndLoc name mod loc
			new_cache = addToFM cache key new_name
		     in
		     setNameSupplyRn (name_supply {nsNames = new_cache})	`thenRn_`
--		     traceRn (text "newTopBinder: overwrite" <+> ppr new_name) `thenRn_`
		     returnRn new_name
		     
	-- Miss in the cache!
	-- Build a completely new Name, and put it in the cache
	-- Even for locally-defined names we use implicitImportProvenance; 
	-- updateProvenances will set it to rights
	Nothing -> let
			(us', us1) = splitUniqSupply (nsUniqs name_supply)
			uniq   	   = uniqFromSupply us1
			new_name   = mkExternalName uniq mod occ loc
			new_cache  = addToFM cache key new_name
		   in
		   setNameSupplyRn (name_supply {nsUniqs = us', nsNames = new_cache})	`thenRn_`
--		   traceRn (text "newTopBinder: new" <+> ppr new_name) `thenRn_`
		   returnRn new_name


newGlobalName :: ModuleName -> OccName -> RnM d Name
  -- Used for *occurrences*.  We make a place-holder Name, really just
  -- to agree on its unique, which gets overwritten when we read in
  -- the binding occurence later (newTopBinder)
  -- The place-holder Name doesn't have the right SrcLoc, and its
  -- Module won't have the right Package either.
  --
  -- (We have to pass a ModuleName, not a Module, because we may be
  -- simply looking at an occurrence M.x in an interface file.)
  --
  -- This means that a renamed program may have incorrect info
  -- on implicitly-imported occurrences, but the correct info on the 
  -- *binding* declaration. It's the type checker that propagates the 
  -- correct information to all the occurrences.
  -- Since implicitly-imported names never occur in error messages,
  -- it doesn't matter that we get the correct info in place till later,
  -- (but since it affects DLL-ery it does matter that we get it right
  --  in the end).
newGlobalName mod_name occ
  = getNameSupplyRn		`thenRn` \ name_supply ->
    let
	key = (mod_name, occ)
	cache = nsNames name_supply
    in
    case lookupFM cache key of
	Just name -> -- traceRn (text "newGlobalName: hit" <+> ppr name) `thenRn_`
		     returnRn name

	Nothing   -> setNameSupplyRn (name_supply {nsUniqs = us', nsNames = new_cache})  `thenRn_`
		     -- traceRn (text "newGlobalName: new" <+> ppr name)		  `thenRn_`
		     returnRn name
		  where
		     (us', us1) = splitUniqSupply (nsUniqs name_supply)
		     uniq   	= uniqFromSupply us1
		     mod        = mkVanillaModule mod_name
		     name       = mkExternalName uniq mod occ noSrcLoc
		     new_cache  = addToFM cache key name

newIPName rdr_name_ip
  = getNameSupplyRn		`thenRn` \ name_supply ->
    let
	ipcache = nsIPs name_supply
    in
    case lookupFM ipcache key of
	Just name_ip -> returnRn name_ip
	Nothing      -> setNameSupplyRn new_ns 	`thenRn_`
		        returnRn name_ip
		  where
		     (us', us1)  = splitUniqSupply (nsUniqs name_supply)
		     uniq   	 = uniqFromSupply us1
		     name_ip	 = mapIPName mk_name rdr_name_ip
		     mk_name rdr_name = mkIPName uniq (rdrNameOcc rdr_name)
		     new_ipcache = addToFM ipcache key name_ip
		     new_ns	 = name_supply {nsUniqs = us', nsIPs = new_ipcache}
    where 
	key = rdr_name_ip	-- Ensures that ?x and %x get distinct Names
\end{code}

%*********************************************************
%*							*
\subsection{Looking up names}
%*							*
%*********************************************************

Looking up a name in the RnEnv.

\begin{code}
lookupBndrRn rdr_name
  = getLocalNameEnv		`thenRn` \ local_env ->
    case lookupRdrEnv local_env rdr_name of 
	  Just name -> returnRn name
	  Nothing   -> lookupTopBndrRn rdr_name

lookupTopBndrRn rdr_name
-- Look up a top-level local binder.   We may be looking up an unqualified 'f',
-- and there may be several imported 'f's too, which must not confuse us.
-- So we have to filter out the non-local ones.
-- A separate function (importsFromLocalDecls) reports duplicate top level
-- decls, so here it's safe just to choose an arbitrary one.

  | isOrig rdr_name
	-- This is here just to catch the PrelBase defn of (say) [] and similar
	-- The parser reads the special syntax and returns an Orig RdrName
	-- But the global_env contains only Qual RdrNames, so we won't
	-- find it there; instead just get the name via the Orig route
	--
  = 	-- This is a binding site for the name, so check first that it 
	-- the current module is the correct one; otherwise GHC can get
	-- very confused indeed.  This test rejects code like
	--	data T = (,) Int Int
	-- unless we are in GHC.Tup
    getModuleRn				`thenRn` \ mod -> 
    checkRn (moduleName mod == rdrNameModule rdr_name)
	    (badOrigBinding rdr_name)	`thenRn_`
    lookupOrigName rdr_name

  | otherwise
  = getModeRn	`thenRn` \ mode ->
    if isInterfaceMode mode
	then lookupSysBinder rdr_name	
		-- lookupSysBinder uses the Module in the monad to set
		-- the correct module for the binder.  This is important because
		-- when GHCi is reading in an old interface, it just sucks it
		-- in entire (Rename.loadHomeDecls) which uses lookupTopBndrRn
		-- rather than via the iface file cache which uses newTopBndrRn
		-- We must get the correct Module into the thing.

    else 
    getModuleRn		`thenRn` \ mod ->
    getGlobalNameEnv	`thenRn` \ global_env ->
    case lookup_local mod global_env rdr_name of
	Just name -> returnRn name
	Nothing	  -> failWithRn (mkUnboundName rdr_name)
		  	        (unknownNameErr rdr_name)

lookup_local mod global_env rdr_name
  = case lookupRdrEnv global_env rdr_name of
	  Nothing   -> Nothing
	  Just gres -> case [n | GRE n _ _ <- gres, nameIsLocalOrFrom mod n] of
			 []     -> Nothing
			 (n:ns) -> Just n
	      

-- lookupSigOccRn is used for type signatures and pragmas
-- Is this valid?
--   module A
--	import M( f )
--	f :: Int -> Int
--	f x = x
-- It's clear that the 'f' in the signature must refer to A.f
-- The Haskell98 report does not stipulate this, but it will!
-- So we must treat the 'f' in the signature in the same way
-- as the binding occurrence of 'f', using lookupBndrRn
lookupSigOccRn :: RdrName -> RnMS Name
lookupSigOccRn = lookupBndrRn

-- lookupInstDeclBndr is used for the binders in an 
-- instance declaration.   Here we use the class name to
-- disambiguate.  

lookupInstDeclBndr :: Name -> RdrName -> RnMS Name
	-- We use the selector name as the binder
lookupInstDeclBndr cls_name rdr_name
  | isOrig rdr_name	-- Occurs in derived instances, where we just
			-- refer diectly to the right method
  = lookupOrigName rdr_name

  | otherwise	
  = getGlobalAvails	`thenRn` \ avail_env ->
    case lookupNameEnv avail_env cls_name of
	  -- The class itself isn't in scope, so cls_name is unboundName
	  -- e.g.   import Prelude hiding( Ord )
	  --	    instance Ord T where ...
	  -- The program is wrong, but that should not cause a crash.
	Nothing -> returnRn (mkUnboundName rdr_name)
	Just (AvailTC _ ns) -> case [n | n <- ns, nameOccName n == occ] of
				(n:ns)-> ASSERT( null ns ) returnRn n
				[]    -> failWithRn (mkUnboundName rdr_name)
						    (unknownNameErr rdr_name)
	other		    -> pprPanic "lookupInstDeclBndr" (ppr cls_name)
  where
    occ = rdrNameOcc rdr_name

-- lookupOccRn looks up an occurrence of a RdrName
lookupOccRn :: RdrName -> RnMS Name
lookupOccRn rdr_name
  = getLocalNameEnv			`thenRn` \ local_env ->
    case lookupRdrEnv local_env rdr_name of
	  Just name -> returnRn name
	  Nothing   -> lookupGlobalOccRn rdr_name

-- lookupGlobalOccRn is like lookupOccRn, except that it looks in the global 
-- environment.  It's used only for
--	record field names
--	class op names in class and instance decls

lookupGlobalOccRn rdr_name
  = getModeRn 		`thenRn` \ mode ->
    if (isInterfaceMode mode)
	then lookupIfaceName rdr_name
	else 

    getGlobalNameEnv	`thenRn` \ global_env ->
    case mode of 
	SourceMode -> lookupSrcName global_env rdr_name

	CmdLineMode
	 | not (isQual rdr_name) -> 
		lookupSrcName global_env rdr_name

		-- We allow qualified names on the command line to refer to 
		-- *any* name exported by any module in scope, just as if 
		-- there was an "import qualified M" declaration for every 
		-- module.
		--
		-- First look up the name in the normal environment.  If
		-- it isn't there, we manufacture a new occurrence of an
		-- original name.
	 | otherwise -> 
		case lookupRdrEnv global_env rdr_name of
		       Just _  -> lookupSrcName global_env rdr_name
		       Nothing -> lookupQualifiedName rdr_name

-- a qualified name on the command line can refer to any module at all: we
-- try to load the interface if we don't already have it.
lookupQualifiedName :: RdrName -> RnM d Name
lookupQualifiedName rdr_name
 = let 
       mod = rdrNameModule rdr_name
       occ = rdrNameOcc rdr_name
   in
   loadInterface (ppr rdr_name) mod ImportByUser `thenRn` \ iface ->
   case  [ name | (_,avails) <- mi_exports iface,
    	   avail	     <- avails,
    	   name 	     <- availNames avail,
    	   nameOccName name == occ ] of
      (n:ns) -> ASSERT (null ns) returnRn n
      _      -> failWithRn (mkUnboundName rdr_name) (unknownNameErr rdr_name)

lookupSrcName :: GlobalRdrEnv -> RdrName -> RnM d Name
-- NB: passed GlobalEnv explicitly, not necessarily in RnMS monad
lookupSrcName global_env rdr_name
  | isOrig rdr_name	-- Can occur in source code too
  = lookupOrigName rdr_name

  | otherwise
  = case lookupRdrEnv global_env rdr_name of
	Just [GRE name _ Nothing]	-> returnRn name
	Just [GRE name _ (Just deprec)] -> warnDeprec name deprec	`thenRn_`
					   returnRn name
	Just stuff@(GRE name _ _ : _)	-> addNameClashErrRn rdr_name stuff	`thenRn_`
			       		   returnRn name
	Nothing				-> failWithRn (mkUnboundName rdr_name)
				   		      (unknownNameErr rdr_name)

lookupOrigName :: RdrName -> RnM d Name 
lookupOrigName rdr_name
  = -- NO: ASSERT( isOrig rdr_name )
    -- Now that .hi-boot files are read by the main parser, they contain
    -- ordinary qualified names (which we treat as Orig names here).
    newGlobalName (rdrNameModule rdr_name) (rdrNameOcc rdr_name)

lookupIfaceUnqual :: RdrName -> RnM d Name
lookupIfaceUnqual rdr_name
  = ASSERT( isUnqual rdr_name )
  	-- An Unqual is allowed; interface files contain 
	-- unqualified names for locally-defined things, such as
	-- constructors of a data type.
    getModuleRn 			`thenRn ` \ mod ->
    newGlobalName (moduleName mod) (rdrNameOcc rdr_name)

lookupIfaceName :: RdrName -> RnM d Name
lookupIfaceName rdr_name
  | isUnqual rdr_name = lookupIfaceUnqual rdr_name
  | otherwise	      = lookupOrigName rdr_name
\end{code}

@lookupOrigName@ takes an RdrName representing an {\em original}
name, and adds it to the occurrence pool so that it'll be loaded
later.  This is used when language constructs (such as monad
comprehensions, overloaded literals, or deriving clauses) require some
stuff to be loaded that isn't explicitly mentioned in the code.

This doesn't apply in interface mode, where everything is explicit,
but we don't check for this case: it does no harm to record an
``extra'' occurrence and @lookupOrigNames@ isn't used much in
interface mode (it's only the @Nothing@ clause of @rnDerivs@ that
calls it at all I think).

  \fbox{{\em Jan 98: this comment is wrong: @rnHsType@ uses it quite a bit.}}

\begin{code}
lookupOrigNames :: [RdrName] -> RnM d NameSet
lookupOrigNames rdr_names
  = mapRn lookupOrigName rdr_names	`thenRn` \ names ->
    returnRn (mkNameSet names)
\end{code}

lookupSysBinder is used for the "system binders" of a type, class, or
instance decl.  It ensures that the module is set correctly in the
name cache, and sets the provenance on the returned name too.  The
returned name will end up actually in the type, class, or instance.

\begin{code}
lookupSysBinder rdr_name
  = ASSERT( isUnqual rdr_name )
    getModuleRn				`thenRn` \ mod ->
    getSrcLocRn				`thenRn` \ loc ->
    newTopBinder mod rdr_name loc
\end{code}


%*********************************************************
%*							*
\subsection{Looking up fixities}
%*							*
%*********************************************************

lookupFixity is a bit strange.  

* Nested local fixity decls are put in the local fixity env, which we
  find with getFixtyEnv

* Imported fixities are found in the HIT or PIT

* Top-level fixity decls in this module may be for Names that are
    either  Global	   (constructors, class operations)
    or 	    Local/Exported (everything else)
  (See notes with RnNames.getLocalDeclBinders for why we have this split.)
  We put them all in the local fixity environment

\begin{code}
lookupFixityRn :: Name -> RnMS Fixity
lookupFixityRn name
  = getModuleRn				`thenRn` \ this_mod ->
    if nameIsLocalOrFrom this_mod name
    then	-- It's defined in this module
	getFixityEnv			`thenRn` \ local_fix_env ->
	returnRn (lookupLocalFixity local_fix_env name)

    else	-- It's imported
      -- For imported names, we have to get their fixities by doing a
      -- loadHomeInterface, and consulting the Ifaces that comes back
      -- from that, because the interface file for the Name might not
      -- have been loaded yet.  Why not?  Suppose you import module A,
      -- which exports a function 'f', thus;
      --        module CurrentModule where
      --	  import A( f )
      -- 	module A( f ) where
      --	  import B( f )
      -- Then B isn't loaded right away (after all, it's possible that
      -- nothing from B will be used).  When we come across a use of
      -- 'f', we need to know its fixity, and it's then, and only
      -- then, that we load B.hi.  That is what's happening here.
        loadInterface doc name_mod ImportBySystem	`thenRn` \ iface ->
	returnRn (lookupFixity (mi_fixities iface) name)
  where
    doc      = ptext SLIT("Checking fixity for") <+> ppr name
    name_mod = moduleName (nameModule name)

--------------------------------
lookupLocalFixity :: LocalFixityEnv -> Name -> Fixity
lookupLocalFixity env name
  = case lookupNameEnv env name of 
	Just (FixitySig _ fix _) -> fix
	Nothing		  	 -> defaultFixity

extendNestedFixityEnv :: [(Name, RenamedFixitySig)] -> RnMS a -> RnMS a
-- Used for nested fixity decls
-- No need to worry about type constructors here,
-- Should check for duplicates but we don't
extendNestedFixityEnv fixes enclosed_scope
  = getFixityEnv 	`thenRn` \ fix_env ->
    let
	new_fix_env = extendNameEnvList fix_env fixes
    in
    setFixityEnv new_fix_env enclosed_scope

mkTopFixityEnv :: GlobalRdrEnv -> [RdrNameFixitySig] -> RnMG LocalFixityEnv
mkTopFixityEnv gbl_env fix_sigs 
  = getModuleRn				`thenRn` \ mod -> 
    let
		-- GHC extension: look up both the tycon and data con 
		-- for con-like things
		-- If neither are in scope, report an error; otherwise
		-- add both to the fixity env
	go fix_env (FixitySig rdr_name fixity loc)
	  = case catMaybes (map (lookup_local mod gbl_env) rdr_names) of
		  [] -> addErrRn (unknownNameErr rdr_name)	`thenRn_`
	 	        returnRn fix_env
		  ns -> foldlRn add fix_env ns

	  where
	    add fix_env name 
	      = case lookupNameEnv fix_env name of
	          Just (FixitySig _ _ loc') -> addErrRn (dupFixityDecl rdr_name loc loc')	`thenRn_`
					       returnRn fix_env
		  Nothing -> returnRn (extendNameEnv fix_env name (FixitySig name fixity loc))
	    
	    rdr_names | isDataSymOcc occ = [rdr_name, rdr_name_tc]
		      | otherwise 	     = [rdr_name]

	    occ 	= rdrNameOcc rdr_name
	    rdr_name_tc = setRdrNameOcc rdr_name (setOccNameSpace occ tcName)
    in
    foldlRn go emptyLocalFixityEnv fix_sigs
\end{code}


%*********************************************************
%*							*
\subsection{Implicit free vars and sugar names}
%*							*
%*********************************************************

@getXImplicitFVs@ forces the renamer to slurp in some things which aren't
mentioned explicitly, but which might be needed by the type checker.

\begin{code}
getImplicitStmtFVs 	-- Compiling a statement
  = returnRn (mkFVs [printName, bindIOName, thenIOName, 
		     returnIOName, failIOName]
	      `plusFV` ubiquitousNames)
		-- These are all needed implicitly when compiling a statement
		-- See TcModule.tc_stmts

getImplicitModuleFVs decls	-- Compiling a module
  = lookupOrigNames deriv_occs		`thenRn` \ deriving_names ->
    returnRn (deriving_names `plusFV` ubiquitousNames)
  where
	-- deriv_classes is now a list of HsTypes, so a "normal" one
	-- appears as a (HsClassP c []).  The non-normal ones for the new
	-- newtype-deriving extension, and they don't require any
	-- implicit names, so we can silently filter them out.
	deriv_occs = [occ | TyClD (TyData {tcdDerivs = Just deriv_classes}) <- decls,
		   	    HsClassP cls [] <- deriv_classes,
			    occ <- lookupWithDefaultUFM derivingOccurrences [] cls ]

-- ubiquitous_names are loaded regardless, because 
-- they are needed in virtually every program
ubiquitousNames 
  = mkFVs [unpackCStringName, unpackCStringFoldrName, 
	   unpackCStringUtf8Name, eqStringName]
	-- Virtually every program has error messages in it somewhere

  `plusFV`
    mkFVs [getName unitTyCon, funTyConName, boolTyConName, intTyConName]
	-- Add occurrences for very frequently used types.
	--  	 (e.g. we don't want to be bothered with making funTyCon a
	--	  free var at every function application!)
  `plusFV`
    namesNeededForFlattening
        -- this will be empty unless flattening is activated

checkMain ghci_mode mod_name gbl_env
	-- LOOKUP main IF WE'RE IN MODULE Main
	-- The main point of this is to drag in the declaration for 'main',
	-- its in another module, and for the Prelude function 'runMain',
	-- so that the type checker will find them
	--
	-- We have to return the main_name separately, because it's a
	-- bona fide 'use', and should be recorded as such, but the others
	-- aren't 
  | mod_name /= mAIN_Name
  = returnRn (Nothing, emptyFVs, emptyFVs)

  | not (main_RDR_Unqual `elemRdrEnv` gbl_env)
  = complain_no_main		`thenRn_`
    returnRn (Nothing, emptyFVs, emptyFVs)

  | otherwise
  = lookupSrcName gbl_env main_RDR_Unqual	`thenRn` \ main_name ->
    returnRn (Just main_name, unitFV main_name, unitFV runMainName)

  where
    complain_no_main | ghci_mode == Interactive = addWarnRn noMainMsg
		     | otherwise 		= addErrRn  noMainMsg
		-- In interactive mode, only warn about the absence of main
\end{code}

%************************************************************************
%*									*
\subsection{Re-bindable desugaring names}
%*									*
%************************************************************************

Haskell 98 says that when you say "3" you get the "fromInteger" from the
Standard Prelude, regardless of what is in scope.   However, to experiment
with having a language that is less coupled to the standard prelude, we're
trying a non-standard extension that instead gives you whatever "Prelude.fromInteger"
happens to be in scope.  Then you can
	import Prelude ()
	import MyPrelude as Prelude
to get the desired effect.

At the moment this just happens for
  * fromInteger, fromRational on literals (in expressions and patterns)
  * negate (in expressions)
  * minus  (arising from n+k patterns)
  * "do" notation

We store the relevant Name in the HsSyn tree, in 
  * HsIntegral/HsFractional	
  * NegApp
  * NPlusKPatIn
  * HsDo
respectively.  Initially, we just store the "standard" name (PrelNames.fromIntegralName,
fromRationalName etc), but the renamer changes this to the appropriate user
name if Opt_NoImplicitPrelude is on.  That is what lookupSyntaxName does.

\begin{code}
lookupSyntaxName :: Name 	-- The standard name
	         -> RnMS Name	-- Possibly a non-standard name
lookupSyntaxName std_name
  = getModeRn				`thenRn` \ mode ->
    case mode of {
	InterfaceMode -> returnRn std_name ;	-- Happens for 'derived' code
						-- where we don't want to rebind
   	other ->

    doptRn Opt_NoImplicitPrelude	`thenRn` \ no_prelude -> 
    if not no_prelude then
	returnRn std_name	-- Normal case
    else
	-- Get the similarly named thing from the local environment
    lookupOccRn (mkRdrUnqual (nameOccName std_name)) }
\end{code}


%*********************************************************
%*							*
\subsection{Binding}
%*							*
%*********************************************************

\begin{code}
newLocalsRn :: [(RdrName,SrcLoc)]
	    -> RnMS [Name]
newLocalsRn rdr_names_w_loc
 =  getNameSupplyRn		`thenRn` \ name_supply ->
    let
	(us', us1) = splitUniqSupply (nsUniqs name_supply)
	uniqs	   = uniqsFromSupply us1
	names	   = [ mkInternalName uniq (rdrNameOcc rdr_name) loc
		     | ((rdr_name,loc), uniq) <- rdr_names_w_loc `zip` uniqs
		     ]
    in
    setNameSupplyRn (name_supply {nsUniqs = us'})	`thenRn_`
    returnRn names


bindLocatedLocalsRn :: SDoc	-- Documentation string for error message
	   	    -> [(RdrName,SrcLoc)]
	    	    -> ([Name] -> RnMS a)
	    	    -> RnMS a
bindLocatedLocalsRn doc_str rdr_names_w_loc enclosed_scope
  = getModeRn 				`thenRn` \ mode ->
    getLocalNameEnv			`thenRn` \ local_env ->
    getGlobalNameEnv			`thenRn` \ global_env ->

	-- Check for duplicate names
    checkDupOrQualNames doc_str rdr_names_w_loc	`thenRn_`

    	-- Warn about shadowing, but only in source modules
    let
      check_shadow (rdr_name,loc)
	|  rdr_name `elemRdrEnv` local_env 
 	|| rdr_name `elemRdrEnv` global_env 
	= pushSrcLocRn loc $ addWarnRn (shadowedNameWarn rdr_name)
        | otherwise 
	= returnRn ()
    in

    (case mode of
	SourceMode -> ifOptRn Opt_WarnNameShadowing	$
		      mapRn_ check_shadow rdr_names_w_loc
	other	   -> returnRn ()
    )					`thenRn_`

    newLocalsRn rdr_names_w_loc		`thenRn` \ names ->
    let
	new_local_env = addListToRdrEnv local_env (map fst rdr_names_w_loc `zip` names)
    in
    setLocalNameEnv new_local_env (enclosed_scope names)

bindCoreLocalRn :: RdrName -> (Name -> RnMS a) -> RnMS a
  -- A specialised variant when renaming stuff from interface
  -- files (of which there is a lot)
  --	* one at a time
  --	* no checks for shadowing
  -- 	* always imported
  -- 	* deal with free vars
bindCoreLocalRn rdr_name enclosed_scope
  = getSrcLocRn 		`thenRn` \ loc ->
    getLocalNameEnv		`thenRn` \ name_env ->
    getNameSupplyRn		`thenRn` \ name_supply ->
    let
	(us', us1) = splitUniqSupply (nsUniqs name_supply)
	uniq	   = uniqFromSupply us1
	name	   = mkInternalName uniq (rdrNameOcc rdr_name) loc
    in
    setNameSupplyRn (name_supply {nsUniqs = us'})	`thenRn_`
    let
	new_name_env = extendRdrEnv name_env rdr_name name
    in
    setLocalNameEnv new_name_env (enclosed_scope name)

bindCoreLocalsRn []     thing_inside = thing_inside []
bindCoreLocalsRn (b:bs) thing_inside = bindCoreLocalRn b	$ \ name' ->
				       bindCoreLocalsRn bs	$ \ names' ->
				       thing_inside (name':names')

bindLocalNames names enclosed_scope
  = getLocalNameEnv 		`thenRn` \ name_env ->
    setLocalNameEnv (extendLocalRdrEnv name_env names)
		    enclosed_scope

bindLocalNamesFV names enclosed_scope
  = bindLocalNames names $
    enclosed_scope `thenRn` \ (thing, fvs) ->
    returnRn (thing, delListFromNameSet fvs names)


-------------------------------------
bindLocalRn doc rdr_name enclosed_scope
  = getSrcLocRn 				`thenRn` \ loc ->
    bindLocatedLocalsRn doc [(rdr_name,loc)]	$ \ (n:ns) ->
    ASSERT( null ns )
    enclosed_scope n

bindLocalsRn doc rdr_names enclosed_scope
  = getSrcLocRn		`thenRn` \ loc ->
    bindLocatedLocalsRn doc
			(rdr_names `zip` repeat loc)
		 	enclosed_scope

	-- binLocalsFVRn is the same as bindLocalsRn
	-- except that it deals with free vars
bindLocalsFVRn doc rdr_names enclosed_scope
  = bindLocalsRn doc rdr_names		$ \ names ->
    enclosed_scope names		`thenRn` \ (thing, fvs) ->
    returnRn (thing, delListFromNameSet fvs names)

-------------------------------------
extendTyVarEnvFVRn :: [Name] -> RnMS (a, FreeVars) -> RnMS (a, FreeVars)
	-- This tiresome function is used only in rnSourceDecl on InstDecl
extendTyVarEnvFVRn tyvars enclosed_scope
  = bindLocalNames tyvars enclosed_scope 	`thenRn` \ (thing, fvs) -> 
    returnRn (thing, delListFromNameSet fvs tyvars)

bindTyVarsRn :: SDoc -> [HsTyVarBndr RdrName]
	      -> ([HsTyVarBndr Name] -> RnMS a)
	      -> RnMS a
bindTyVarsRn doc_str tyvar_names enclosed_scope
  = getSrcLocRn					`thenRn` \ loc ->
    let
	located_tyvars = [(hsTyVarName tv, loc) | tv <- tyvar_names] 
    in
    bindLocatedLocalsRn doc_str located_tyvars	$ \ names ->
    enclosed_scope (zipWith replaceTyVarName tyvar_names names)

bindPatSigTyVars :: [RdrNameHsType]
		 -> RnMS (a, FreeVars)
	  	 -> RnMS (a, FreeVars)
  -- Find the type variables in the pattern type 
  -- signatures that must be brought into scope

bindPatSigTyVars tys enclosed_scope
  = getLocalNameEnv			`thenRn` \ name_env ->
    getSrcLocRn				`thenRn` \ loc ->
    let
	forall_tyvars  = nub [ tv | ty <- tys,
				    tv <- extractHsTyRdrTyVars ty, 
				    not (tv `elemFM` name_env)
			 ]
		-- The 'nub' is important.  For example:
		--	f (x :: t) (y :: t) = ....
		-- We don't want to complain about binding t twice!

	located_tyvars = [(tv, loc) | tv <- forall_tyvars] 
	doc_sig        = text "In a pattern type-signature"
    in
    bindLocatedLocalsRn doc_sig located_tyvars	$ \ names ->
    enclosed_scope 				`thenRn` \ (thing, fvs) ->
    returnRn (thing, delListFromNameSet fvs names)


-------------------------------------
checkDupOrQualNames, checkDupNames :: SDoc
				   -> [(RdrName, SrcLoc)]
				   -> RnM d ()
	-- Works in any variant of the renamer monad

checkDupOrQualNames doc_str rdr_names_w_loc
  =	-- Check for use of qualified names
    mapRn_ (qualNameErr doc_str) quals 	`thenRn_`
    checkDupNames doc_str rdr_names_w_loc
  where
    quals = filter (isQual . fst) rdr_names_w_loc
    
checkDupNames doc_str rdr_names_w_loc
  = 	-- Check for duplicated names in a binding group
    mapRn_ (dupNamesErr doc_str) dups
  where
    (_, dups) = removeDups (\(n1,l1) (n2,l2) -> n1 `compare` n2) rdr_names_w_loc
\end{code}


%************************************************************************
%*									*
\subsection{GlobalRdrEnv}
%*									*
%************************************************************************

\begin{code}
mkGlobalRdrEnv :: ModuleName		-- Imported module (after doing the "as M" name change)
	       -> Bool			-- True <=> want unqualified import
	       -> (Name -> Provenance)
	       -> Avails		-- Whats imported
	       -> Deprecations
	       -> GlobalRdrEnv

mkGlobalRdrEnv this_mod unqual_imp mk_provenance avails deprecs
  = gbl_env2
  where
 	-- Make the name environment.  We're talking about a 
	-- single module here, so there must be no name clashes.
	-- In practice there only ever will be if it's the module
	-- being compiled.

	-- Add qualified names for the things that are available
	-- (Qualified names are always imported)
    gbl_env1 = foldl add_avail emptyRdrEnv avails

	-- Add unqualified names
    gbl_env2 | unqual_imp = foldl add_unqual gbl_env1 (rdrEnvToList gbl_env1)
	     | otherwise  = gbl_env1

    add_unqual env (qual_name, elts)
	= foldl add_one env elts
	where
	  add_one env elt = addOneToGlobalRdrEnv env unqual_name elt
	  unqual_name     = unqualifyRdrName qual_name
	-- The qualified import should only have added one 
	-- binding for each qualified name!  But if there's an error in
	-- the module (multiple bindings for the same name) we may get
	-- duplicates.  So the simple thing is to do the fold.

    add_avail :: GlobalRdrEnv -> AvailInfo -> GlobalRdrEnv
    add_avail env avail = foldl add_name env (availNames avail)

    add_name env name 	-- Add qualified name only
	= addOneToGlobalRdrEnv env  (mkRdrQual this_mod occ) elt
	where
	  occ  = nameOccName name
	  elt  = GRE name (mk_provenance name) (lookupDeprec deprecs name)
\end{code}

\begin{code}
plusGlobalRdrEnv :: GlobalRdrEnv -> GlobalRdrEnv -> GlobalRdrEnv
plusGlobalRdrEnv env1 env2 = plusFM_C combine_globals env1 env2

addOneToGlobalRdrEnv :: GlobalRdrEnv -> RdrName -> GlobalRdrElt -> GlobalRdrEnv
addOneToGlobalRdrEnv env rdr_name name = addToFM_C combine_globals env rdr_name [name]

delOneFromGlobalRdrEnv :: GlobalRdrEnv -> RdrName -> GlobalRdrEnv 
delOneFromGlobalRdrEnv env rdr_name = delFromFM env rdr_name

combine_globals :: [GlobalRdrElt] 	-- Old
		-> [GlobalRdrElt]	-- New
		-> [GlobalRdrElt]
combine_globals ns_old ns_new	-- ns_new is often short
  = foldr add ns_old ns_new
  where
    add n ns | any (is_duplicate n) ns_old = map (choose n) ns	-- Eliminate duplicates
	     | otherwise	           = n:ns

    choose n m | n `beats` m = n
	       | otherwise   = m

    (GRE n pn _) `beats` (GRE m pm _) = n==m && pn `hasBetterProv` pm

    is_duplicate :: GlobalRdrElt -> GlobalRdrElt -> Bool
    is_duplicate (GRE n1 LocalDef _) (GRE n2 LocalDef _) = False
    is_duplicate (GRE n1 _        _) (GRE n2 _	      _) = n1 == n2
\end{code}

We treat two bindings of a locally-defined name as a duplicate,
because they might be two separate, local defns and we want to report
and error for that, {\em not} eliminate a duplicate.

On the other hand, if you import the same name from two different
import statements, we {\em do} want to eliminate the duplicate, not report
an error.

If a module imports itself then there might be a local defn and an imported
defn of the same name; in this case the names will compare as equal, but
will still have different provenances.


@unQualInScope@ returns a function that takes a @Name@ and tells whether
its unqualified name is in scope.  This is put as a boolean flag in
the @Name@'s provenance to guide whether or not to print the name qualified
in error messages.

\begin{code}
unQualInScope :: GlobalRdrEnv -> Name -> Bool
-- True if 'f' is in scope, and has only one binding,
-- and the thing it is bound to is the name we are looking for
-- (i.e. false if A.f and B.f are both in scope as unqualified 'f')
--
-- This fn is only efficient if the shared 
-- partial application is used a lot.
unQualInScope env
  = (`elemNameSet` unqual_names)
  where
    unqual_names :: NameSet
    unqual_names = foldRdrEnv add emptyNameSet env
    add rdr_name [GRE name _ _] unquals | isUnqual rdr_name = addOneToNameSet unquals name
    add _        _              unquals		 	    = unquals
\end{code}


%************************************************************************
%*									*
\subsection{Avails}
%*									*
%************************************************************************

\begin{code}
plusAvail (Avail n1)	   (Avail n2)	    = Avail n1
plusAvail (AvailTC n1 ns1) (AvailTC n2 ns2) = AvailTC n2 (nub (ns1 ++ ns2))
-- Added SOF 4/97
#ifdef DEBUG
plusAvail a1 a2 = pprPanic "RnEnv.plusAvail" (hsep [ppr a1,ppr a2])
#endif

addAvail :: AvailEnv -> AvailInfo -> AvailEnv
addAvail avails avail = extendNameEnv_C plusAvail avails (availName avail) avail

unitAvailEnv :: AvailInfo -> AvailEnv
unitAvailEnv a = unitNameEnv (availName a) a

plusAvailEnv :: AvailEnv -> AvailEnv -> AvailEnv
plusAvailEnv = plusNameEnv_C plusAvail

availEnvElts = nameEnvElts

addAvailToNameSet :: NameSet -> AvailInfo -> NameSet
addAvailToNameSet names avail = addListToNameSet names (availNames avail)

availsToNameSet :: [AvailInfo] -> NameSet
availsToNameSet avails = foldl addAvailToNameSet emptyNameSet avails

availName :: GenAvailInfo name -> name
availName (Avail n)     = n
availName (AvailTC n _) = n

availNames :: GenAvailInfo name -> [name]
availNames (Avail n)      = [n]
availNames (AvailTC n ns) = ns

-------------------------------------
filterAvail :: RdrNameIE	-- Wanted
	    -> AvailInfo	-- Available
	    -> Maybe AvailInfo	-- Resulting available; 
				-- Nothing if (any of the) wanted stuff isn't there

filterAvail ie@(IEThingWith want wants) avail@(AvailTC n ns)
  | sub_names_ok = Just (AvailTC n (filter is_wanted ns))
  | otherwise    = Nothing
  where
    is_wanted name = nameOccName name `elem` wanted_occs
    sub_names_ok   = all (`elem` avail_occs) wanted_occs
    avail_occs	   = map nameOccName ns
    wanted_occs    = map rdrNameOcc (want:wants)

filterAvail (IEThingAbs _) (AvailTC n ns)       = ASSERT( n `elem` ns ) 
						  Just (AvailTC n [n])

filterAvail (IEThingAbs _) avail@(Avail n)      = Just avail		-- Type synonyms

filterAvail (IEVar _)      avail@(Avail n)      = Just avail
filterAvail (IEVar v)      avail@(AvailTC n ns) = Just (AvailTC n (filter wanted ns))
						where
						  wanted n = nameOccName n == occ
						  occ      = rdrNameOcc v
	-- The second equation happens if we import a class op, thus
	-- 	import A( op ) 
	-- where op is a class operation

filterAvail (IEThingAll _) avail@(AvailTC _ _)   = Just avail
	-- We don't complain even if the IE says T(..), but
	-- no constrs/class ops of T are available
	-- Instead that's caught with a warning by the caller

filterAvail ie avail = Nothing

-------------------------------------
groupAvails :: Module -> Avails -> [(ModuleName, Avails)]
  -- Group by module and sort by occurrence
  -- This keeps the list in canonical order
groupAvails this_mod avails 
  = [ (mkSysModuleNameFS fs, sortLt lt avails)
    | (fs,avails) <- fmToList groupFM
    ]
  where
    groupFM :: FiniteMap FastString Avails
	-- Deliberately use the FastString so we
	-- get a canonical ordering
    groupFM = foldl add emptyFM avails

    add env avail = addToFM_C combine env mod_fs [avail']
		  where
		    mod_fs = moduleNameFS (moduleName avail_mod)
		    avail_mod = case nameModule_maybe (availName avail) of
					  Just m  -> m
					  Nothing -> this_mod
		    combine old _ = avail':old
		    avail'	  = sortAvail avail

    a1 `lt` a2 = occ1 < occ2
	       where
		 occ1  = nameOccName (availName a1)
		 occ2  = nameOccName (availName a2)

sortAvail :: AvailInfo -> AvailInfo
-- Sort the sub-names into canonical order.
-- The canonical order has the "main name" at the beginning 
-- (if it's there at all)
sortAvail (Avail n) = Avail n
sortAvail (AvailTC n ns) | n `elem` ns = AvailTC n (n : sortLt lt (filter (/= n) ns))
			 | otherwise   = AvailTC n (    sortLt lt ns)
			 where
			   n1 `lt` n2 = nameOccName n1 < nameOccName n2
\end{code}

\begin{code}
pruneAvails :: (Name -> Bool)	-- Keep if this is True
	    -> [AvailInfo]
	    -> [AvailInfo]
pruneAvails keep avails
  = mapMaybe del avails
  where
    del :: AvailInfo -> Maybe AvailInfo	-- Nothing => nothing left!
    del (Avail n) | keep n    = Just (Avail n)
    	          | otherwise = Nothing
    del (AvailTC n ns) | null ns'  = Nothing
		       | otherwise = Just (AvailTC n ns')
		       where
		         ns' = filter keep ns
\end{code}

%************************************************************************
%*									*
\subsection{Free variable manipulation}
%*									*
%************************************************************************

\begin{code}
-- A useful utility
mapFvRn f xs = mapRn f xs	`thenRn` \ stuff ->
	       let
		  (ys, fvs_s) = unzip stuff
	       in
	       returnRn (ys, plusFVs fvs_s)
\end{code}


%************************************************************************
%*									*
\subsection{Envt utility functions}
%*									*
%************************************************************************

\begin{code}
warnUnusedModules :: [ModuleName] -> RnM d ()
warnUnusedModules mods
  = ifOptRn Opt_WarnUnusedImports (mapRn_ (addWarnRn . unused_mod) mods)
  where
    unused_mod m = vcat [ptext SLIT("Module") <+> quotes (ppr m) <+> 
			   text "is imported, but nothing from it is used",
			 parens (ptext SLIT("except perhaps to re-export instances visible in") <+>
				   quotes (ppr m))]

warnUnusedImports :: [(Name,Provenance)] -> RnM d ()
warnUnusedImports names
  = ifOptRn Opt_WarnUnusedImports (warnUnusedBinds names)

warnUnusedLocalBinds, warnUnusedMatches :: [Name] -> RnM d ()
warnUnusedLocalBinds names
  = ifOptRn Opt_WarnUnusedBinds (warnUnusedBinds [(n,LocalDef) | n<-names])

warnUnusedMatches names
  = ifOptRn Opt_WarnUnusedMatches (warnUnusedGroup [(n,LocalDef) | n<-names])

-------------------------

warnUnusedBinds :: [(Name,Provenance)] -> RnM d ()
warnUnusedBinds names
  = mapRn_ warnUnusedGroup  groups
  where
	-- Group by provenance
   groups = equivClasses cmp names
   (_,prov1) `cmp` (_,prov2) = prov1 `compare` prov2
 

-------------------------

warnUnusedGroup :: [(Name,Provenance)] -> RnM d ()
warnUnusedGroup names
  | null filtered_names  = returnRn ()
  | not is_local	 = returnRn ()
  | otherwise
  = pushSrcLocRn def_loc	$
    addWarnRn			$
    sep [msg <> colon, nest 4 (fsep (punctuate comma (map (ppr.fst) filtered_names)))]
  where
    filtered_names = filter reportable names
    (name1, prov1) = head filtered_names
    (is_local, def_loc, msg)
	= case prov1 of
		LocalDef -> (True, getSrcLoc name1, text "Defined but not used")

		NonLocalDef (UserImport mod loc _)
			-> (True, loc, text "Imported from" <+> quotes (ppr mod) <+> text "but not used")

    reportable (name,_) = case occNameUserString (nameOccName name) of
				('_' : _) -> False
				zz_other  -> True
	-- Haskell 98 encourages compilers to suppress warnings about
	-- unused names in a pattern if they start with "_".
\end{code}

\begin{code}
addNameClashErrRn rdr_name (np1:nps)
  = addErrRn (vcat [ptext SLIT("Ambiguous occurrence") <+> quotes (ppr rdr_name),
		    ptext SLIT("It could refer to") <+> vcat (msg1 : msgs)])
  where
    msg1 = ptext  SLIT("either") <+> mk_ref np1
    msgs = [ptext SLIT("    or") <+> mk_ref np | np <- nps]
    mk_ref (GRE name prov _) = quotes (ppr name) <> comma <+> pprNameProvenance name prov

shadowedNameWarn shadow
  = hsep [ptext SLIT("This binding for"), 
	       quotes (ppr shadow),
	       ptext SLIT("shadows an existing binding")]

noMainMsg = ptext SLIT("No 'main' defined in module Main")

unknownNameErr name
  = sep [text flavour, ptext SLIT("not in scope:"), quotes (ppr name)]
  where
    flavour = occNameFlavour (rdrNameOcc name)

badOrigBinding name
  = ptext SLIT("Illegal binding of built-in syntax:") <+> ppr (rdrNameOcc name)
	-- The rdrNameOcc is because we don't want to print Prelude.(,)

qualNameErr descriptor (name,loc)
  = pushSrcLocRn loc $
    addErrRn (vcat [ ptext SLIT("Invalid use of qualified name") <+> quotes (ppr name),
		     descriptor])

dupNamesErr descriptor ((name,loc) : dup_things)
  = pushSrcLocRn loc $
    addErrRn ((ptext SLIT("Conflicting definitions for") <+> quotes (ppr name))
	      $$ 
	      descriptor)

warnDeprec :: Name -> DeprecTxt -> RnM d ()
warnDeprec name txt
  = ifOptRn Opt_WarnDeprecations	$
    addWarnRn (sep [ text (occNameFlavour (nameOccName name)) <+> 
		     quotes (ppr name) <+> text "is deprecated:", 
		     nest 4 (ppr txt) ])

dupFixityDecl rdr_name loc1 loc2
  = vcat [ptext SLIT("Multiple fixity declarations for") <+> quotes (ppr rdr_name),
	  ptext SLIT("at ") <+> ppr loc1,
	  ptext SLIT("and") <+> ppr loc2]
\end{code}

