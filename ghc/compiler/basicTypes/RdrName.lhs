%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

\section[RdrName]{@RdrName@}

\begin{code}
module RdrName (
	RdrName(..),	-- Constructors exported only to BinIface

	-- Construction
	mkRdrUnqual, mkRdrQual, 
	mkUnqual, mkVarUnqual, mkQual, mkOrig, mkIfaceOrig, 
	nameRdrName, getRdrName, 
	qualifyRdrName, unqualifyRdrName, 
	mkDerivedRdrName, 
	dummyRdrVarName, dummyRdrTcName,

	-- Destruction
	rdrNameModule, rdrNameOcc, setRdrNameSpace,
	isRdrDataCon, isRdrTyVar, isRdrTc, isQual, isUnqual, 
	isOrig, isOrig_maybe, isExact, isExact_maybe, isSrcRdrName,

	-- Printing;	instance Outputable RdrName
	pprUnqualRdrName,

	-- LocalRdrEnv
	LocalRdrEnv, emptyLocalRdrEnv, extendLocalRdrEnv,
	lookupLocalRdrEnv, elemLocalRdrEnv,

	-- GlobalRdrEnv
	GlobalRdrEnv, emptyGlobalRdrEnv, mkGlobalRdrEnv, plusGlobalRdrEnv, 
	lookupGlobalRdrEnv, pprGlobalRdrEnv, globalRdrEnvElts,
	lookupGRE_RdrName, lookupGRE_Name,

	-- GlobalRdrElt, Provenance, ImportSpec
	GlobalRdrElt(..), Provenance(..), ImportSpec(..),
	isLocalGRE, unQualOK, hasQual,
	pprNameProvenance
  ) where 

#include "HsVersions.h"

import OccName	( NameSpace, tcName, varName,
		  OccName, UserFS, EncodedFS,
		  mkSysOccFS, setOccNameSpace,
		  mkOccFS, mkVarOcc, occNameFlavour,
		  isDataOcc, isTvOcc, isTcOcc,
		  OccEnv, emptyOccEnv, extendOccEnvList, lookupOccEnv, 
		  elemOccEnv, plusOccEnv_C, extendOccEnv_C, foldOccEnv,
		  occEnvElts
		)
import Module   ( ModuleName, mkSysModuleNameFS, mkModuleNameFS	)
import Name	( Name, NamedThing(getName), nameModuleName, nameParent_maybe,
		  nameOccName, isExternalName, nameSrcLoc )
import Maybes	( seqMaybe )
import SrcLoc	( SrcLoc, isGoodSrcLoc )
import BasicTypes( DeprecTxt )
import Outputable
import Util	( thenCmp )
\end{code}


%************************************************************************
%*									*
\subsection{The main data type}
%*									*
%************************************************************************

\begin{code}
data RdrName 
  = Unqual OccName
	-- Used for ordinary, unqualified occurrences 

  | Qual ModuleName OccName
	-- A qualified name written by the user in 
	-- *source* code.  The module isn't necessarily 
	-- the module where the thing is defined; 
	-- just the one from which it is imported

  | Orig ModuleName OccName
	-- An original name; the module is the *defining* module.
	-- This is used when GHC generates code that will be fed
	-- into the renamer (e.g. from deriving clauses), but where
	-- we want to say "Use Prelude.map dammit".  
 
  | Exact Name
	-- We know exactly the Name. This is used 
	--  (a) when the parser parses built-in syntax like "[]" 
	--	and "(,)", but wants a RdrName from it
	--  (b) when converting names to the RdrNames in IfaceTypes
	--	Here an Exact RdrName always contains an External Name
	--	(Internal Names are converted to simple Unquals)
	--  (c) possibly, by the meta-programming stuff
\end{code}


%************************************************************************
%*									*
\subsection{Simple functions}
%*									*
%************************************************************************

\begin{code}
rdrNameModule :: RdrName -> ModuleName
rdrNameModule (Qual m _) = m
rdrNameModule (Orig m _) = m
rdrNameModule (Exact n)  = nameModuleName n
rdrNameModule (Unqual n) = pprPanic "rdrNameModule" (ppr n)

rdrNameOcc :: RdrName -> OccName
rdrNameOcc (Qual _ occ) = occ
rdrNameOcc (Unqual occ) = occ
rdrNameOcc (Orig _ occ) = occ
rdrNameOcc (Exact name) = nameOccName name

setRdrNameSpace :: RdrName -> NameSpace -> RdrName
-- This rather gruesome function is used mainly by the parser
-- When parsing		data T a = T | T1 Int
-- we parse the data constructors as *types* because of parser ambiguities,
-- so then we need to change the *type constr* to a *data constr*
--
-- The original-name case *can* occur when parsing
-- 		data [] a = [] | a : [a]
-- For the orig-name case we return an unqualified name.
setRdrNameSpace (Unqual occ) ns = Unqual (setOccNameSpace ns occ)
setRdrNameSpace (Qual m occ) ns = Qual m (setOccNameSpace ns occ)
setRdrNameSpace (Orig m occ) ns = Orig m (setOccNameSpace ns occ)
setRdrNameSpace (Exact n)    ns = Orig (nameModuleName n)
				       (setOccNameSpace ns (nameOccName n))
\end{code}

\begin{code}
	-- These two are the basic constructors
mkRdrUnqual :: OccName -> RdrName
mkRdrUnqual occ = Unqual occ

mkRdrQual :: ModuleName -> OccName -> RdrName
mkRdrQual mod occ = Qual mod occ

mkOrig :: ModuleName -> OccName -> RdrName
mkOrig mod occ = Orig mod occ

mkIfaceOrig :: NameSpace -> EncodedFS -> EncodedFS -> RdrName
mkIfaceOrig ns m n = Orig (mkSysModuleNameFS m) (mkSysOccFS ns n)

---------------
mkDerivedRdrName :: Name -> (OccName -> OccName) -> (RdrName)
mkDerivedRdrName parent mk_occ
  = mkOrig (nameModuleName parent) (mk_occ (nameOccName parent))

---------------
	-- These two are used when parsing source files
	-- They do encode the module and occurrence names
mkUnqual :: NameSpace -> UserFS -> RdrName
mkUnqual sp n = Unqual (mkOccFS sp n)

mkVarUnqual :: UserFS -> RdrName
mkVarUnqual n = Unqual (mkOccFS varName n)

mkQual :: NameSpace -> (UserFS, UserFS) -> RdrName
mkQual sp (m, n) = Qual (mkModuleNameFS m) (mkOccFS sp n)

getRdrName :: NamedThing thing => thing -> RdrName
getRdrName name = nameRdrName (getName name)

nameRdrName :: Name -> RdrName
nameRdrName name = Exact name
-- Keep the Name even for Internal names, so that the
-- unique is still there for debug printing, particularly
-- of Types (which are converted to IfaceTypes before printing)

qualifyRdrName :: ModuleName -> RdrName -> RdrName
	-- Sets the module name of a RdrName, even if it has one already
qualifyRdrName mod rn = Qual mod (rdrNameOcc rn)

unqualifyRdrName :: RdrName -> RdrName
unqualifyRdrName rdr_name = Unqual (rdrNameOcc rdr_name)

nukeExact :: Name -> RdrName
nukeExact n 
  | isExternalName n = Orig (nameModuleName n) (nameOccName n)
  | otherwise	     = Unqual (nameOccName n)
\end{code}

\begin{code}
	-- This guy is used by the reader when HsSyn has a slot for
	-- an implicit name that's going to be filled in by
	-- the renamer.  We can't just put "error..." because
	-- we sometimes want to print out stuff after reading but
	-- before renaming
dummyRdrVarName = Unqual (mkVarOcc FSLIT("V-DUMMY"))
dummyRdrTcName  = Unqual (mkOccFS tcName FSLIT("TC-DUMMY"))
\end{code}


\begin{code}
isRdrDataCon rn = isDataOcc (rdrNameOcc rn)
isRdrTyVar   rn = isTvOcc   (rdrNameOcc rn)
isRdrTc      rn = isTcOcc   (rdrNameOcc rn)

isSrcRdrName (Unqual _) = True
isSrcRdrName (Qual _ _) = True
isSrcRdrName _		= False

isUnqual (Unqual _) = True
isUnqual other	    = False

isQual (Qual _ _) = True
isQual _	  = False

isOrig (Orig _ _) = True
isOrig _	  = False

isOrig_maybe (Orig m n) = Just (m,n)
isOrig_maybe _		= Nothing

isExact (Exact _) = True
isExact other	= False

isExact_maybe (Exact n) = Just n
isExact_maybe other	= Nothing
\end{code}


%************************************************************************
%*									*
\subsection{Instances}
%*									*
%************************************************************************

\begin{code}
instance Outputable RdrName where
    ppr (Exact name)   = ppr name
    ppr (Unqual occ)   = ppr occ <+> ppr_name_space occ
    ppr (Qual mod occ) = ppr mod <> dot <> ppr occ <+> ppr_name_space occ
    ppr (Orig mod occ) = ppr mod <> dot <> ppr occ <+> ppr_name_space occ

ppr_name_space occ = ifPprDebug (parens (text (occNameFlavour occ)))

instance OutputableBndr RdrName where
    pprBndr _ n 
	| isTvOcc (rdrNameOcc n) = char '@' <+> ppr n
	| otherwise		 = ppr n

pprUnqualRdrName rdr_name = ppr (rdrNameOcc rdr_name)

instance Eq RdrName where
    (Exact n1) 	  == (Exact n2)    = n1==n2
	-- Convert exact to orig
    (Exact n1) 	  == r2@(Orig _ _) = nukeExact n1 == r2
    r1@(Orig _ _) == (Exact n2)    = r1 == nukeExact n2

    (Orig m1 o1)  == (Orig m2 o2)  = m1==m2 && o1==o2
    (Qual m1 o1)  == (Qual m2 o2)  = m1==m2 && o1==o2
    (Unqual o1)   == (Unqual o2)   = o1==o2
    r1 == r2 = False

instance Ord RdrName where
    a <= b = case (a `compare` b) of { LT -> True;  EQ -> True;  GT -> False }
    a <	 b = case (a `compare` b) of { LT -> True;  EQ -> False; GT -> False }
    a >= b = case (a `compare` b) of { LT -> False; EQ -> True;  GT -> True  }
    a >	 b = case (a `compare` b) of { LT -> False; EQ -> False; GT -> True  }

	-- Unqual < Qual < Orig
	-- We always convert Exact to Orig before comparing
    compare (Exact n1) (Exact n2) | n1==n2 = EQ	-- Short cut
				  | otherwise = nukeExact n1 `compare` nukeExact n2
    compare (Exact n1) n2	  	      = nukeExact n1 `compare` n2
    compare n1	      (Exact n2)  	      = n1 `compare` nukeExact n2


    compare (Qual m1 o1) (Qual m2 o2) = (o1 `compare` o2) `thenCmp` (m1 `compare` m2) 
    compare (Orig m1 o1) (Orig m2 o2) = (o1 `compare` o2) `thenCmp` (m1 `compare` m2) 
    compare (Unqual o1)  (Unqual  o2) = o1 `compare` o2
 
    compare (Unqual _)   _ 	      = LT
    compare (Qual _ _)   (Orig _ _)   = LT
    compare _		 _	      = GT
\end{code}



%************************************************************************
%*									*
			LocalRdrEnv
%*									*
%************************************************************************

A LocalRdrEnv is used for local bindings (let, where, lambda, case)
It is keyed by OccName, because we never use it for qualified names.

\begin{code}
type LocalRdrEnv = OccEnv Name

emptyLocalRdrEnv = emptyOccEnv

extendLocalRdrEnv :: LocalRdrEnv -> [Name] -> LocalRdrEnv
extendLocalRdrEnv env names
  = extendOccEnvList env [(nameOccName n, n) | n <- names]

lookupLocalRdrEnv :: LocalRdrEnv -> RdrName -> Maybe Name
lookupLocalRdrEnv env (Exact name) = Just name
lookupLocalRdrEnv env (Unqual occ) = lookupOccEnv env occ
lookupLocalRdrEnv env other	   = Nothing

elemLocalRdrEnv :: RdrName -> LocalRdrEnv -> Bool
elemLocalRdrEnv rdr_name env 
  | isUnqual rdr_name = rdrNameOcc rdr_name `elemOccEnv` env
  | otherwise	      = False
\end{code}


%************************************************************************
%*									*
			GlobalRdrEnv
%*									*
%************************************************************************

\begin{code}
type GlobalRdrEnv = OccEnv [GlobalRdrElt]
	-- Keyed by OccName; when looking up a qualified name
	-- we look up the OccName part, and then check the Provenance
	-- to see if the appropriate qualification is valid.  This
	-- saves routinely doubling the size of the env by adding both
	-- qualified and unqualified names to the domain.
	--
	-- The list in the range is reqd because there may be name clashes
	-- These only get reported on lookup, not on construction

	-- INVARIANT: All the members of the list have distinct 
	--	      gre_name fields; that is, no duplicate Names

emptyGlobalRdrEnv = emptyOccEnv

globalRdrEnvElts :: GlobalRdrEnv -> [GlobalRdrElt]
globalRdrEnvElts env = foldOccEnv (++) [] env

data GlobalRdrElt 
  = GRE { gre_name   :: Name,
	  gre_prov   :: Provenance,	-- Why it's in scope
	  gre_deprec :: Maybe DeprecTxt	-- Whether this name is deprecated
    }

instance Outputable GlobalRdrElt where
  ppr gre = ppr name <+> pp_parent (nameParent_maybe name)
		<+> parens (pprNameProvenance gre)
	  where
	    name = gre_name gre
	    pp_parent (Just p) = brackets (text "parent:" <+> ppr p)
	    pp_parent Nothing  = empty

pprGlobalRdrEnv :: GlobalRdrEnv -> SDoc
pprGlobalRdrEnv env
  = vcat (map pp (occEnvElts env))
  where
    pp gres = ppr (nameOccName (gre_name (head gres))) <> colon <+> 
	      vcat [ ppr (gre_name gre) <+> pprNameProvenance gre
		   | gre <- gres]
\end{code}

\begin{code}
lookupGlobalRdrEnv :: GlobalRdrEnv -> OccName -> [GlobalRdrElt]
lookupGlobalRdrEnv env rdr_name = case lookupOccEnv env rdr_name of
					Nothing   -> []
					Just gres -> gres

lookupGRE_RdrName :: RdrName -> GlobalRdrEnv -> [GlobalRdrElt]
lookupGRE_RdrName rdr_name env
  = case lookupOccEnv env occ of
	Nothing -> []
	Just gres | isUnqual rdr_name -> filter unQualOK gres
		  | otherwise	      -> filter (hasQual mod) gres
  where
    mod = rdrNameModule rdr_name
    occ = rdrNameOcc rdr_name

lookupGRE_Name :: GlobalRdrEnv -> Name -> [GlobalRdrElt]
lookupGRE_Name env name
  = [ gre | gre <- lookupGlobalRdrEnv env (nameOccName name),
	    gre_name gre == name ]


isLocalGRE :: GlobalRdrElt -> Bool
isLocalGRE (GRE {gre_prov = LocalDef _}) = True
isLocalGRE other    		         = False

unQualOK :: GlobalRdrElt -> Bool
-- An unqualifed version of this thing is in scope
unQualOK (GRE {gre_prov = LocalDef _})    = True
unQualOK (GRE {gre_prov = Imported is _}) = not (all is_qual is)

hasQual :: ModuleName -> GlobalRdrElt -> Bool
-- A qualified version of this thing is in scope
hasQual mod (GRE {gre_prov = LocalDef m})    = m == mod
hasQual mod (GRE {gre_prov = Imported is _}) = any ((== mod) . is_as) is

plusGlobalRdrEnv :: GlobalRdrEnv -> GlobalRdrEnv -> GlobalRdrEnv
plusGlobalRdrEnv env1 env2 = plusOccEnv_C (foldr insertGRE) env1 env2

mkGlobalRdrEnv :: [GlobalRdrElt] -> GlobalRdrEnv
mkGlobalRdrEnv gres
  = foldr add emptyGlobalRdrEnv gres
  where
    add gre env = extendOccEnv_C (foldr insertGRE) env 
				 (nameOccName (gre_name gre)) 
				 [gre]

insertGRE :: GlobalRdrElt -> [GlobalRdrElt] -> [GlobalRdrElt]
insertGRE new_g [] = [new_g]
insertGRE new_g (old_g : old_gs)
	| gre_name new_g == gre_name old_g
	= new_g `plusGRE` old_g : old_gs
	| otherwise
	= old_g : insertGRE new_g old_gs

plusGRE :: GlobalRdrElt -> GlobalRdrElt -> GlobalRdrElt
-- Used when the gre_name fields match
plusGRE g1 g2
  = GRE { gre_name   = gre_name g1,
	  gre_prov   = gre_prov g1 `plusProv` gre_prov g2,
	  gre_deprec = gre_deprec g1 `seqMaybe` gre_deprec g2 }
	-- Could the deprecs be different?  If we re-export
	-- something deprecated, is it propagated?  I forget.
\end{code}


%************************************************************************
%*									*
			Provenance
%*									*
%************************************************************************

The "provenance" of something says how it came to be in scope.

\begin{code}
data Provenance
  = LocalDef		-- Defined locally
	ModuleName

  | Imported 		-- Imported
	[ImportSpec]	-- INVARIANT: non-empty
	Bool		-- True iff the thing was named *explicitly* 
			-- in *any* of the import specs rather than being 
			-- imported as part of a group; 
	-- e.g.
	--	import B
	--	import C( T(..) )
	-- Here, everything imported by B, and the constructors of T
	-- are not named explicitly; only T is named explicitly.
	-- This info is used when warning of unused names.

data ImportSpec		-- Describes a particular import declaration
			-- Shared among all the Provenaces for a particular
			-- import declaration
  = ImportSpec {
	is_mod  :: ModuleName,		-- 'import Muggle'
					-- Note the Muggle may well not be 
					-- the defining module for this thing!
	is_as   :: ModuleName,		-- 'as M' (or 'Muggle' if there is no 'as' clause)
	is_qual :: Bool,		-- True <=> qualified (only)
	is_loc  :: SrcLoc }		-- Location of import statment

-- Comparison of provenance is just used for grouping 
-- error messages (in RnEnv.warnUnusedBinds)
instance Eq Provenance where
  p1 == p2 = case p1 `compare` p2 of EQ -> True; _ -> False

instance Eq ImportSpec where
  p1 == p2 = case p1 `compare` p2 of EQ -> True; _ -> False

instance Ord Provenance where
   compare (LocalDef _) (LocalDef _)   = EQ
   compare (LocalDef _) (Imported _ _) = LT
   compare (Imported _ _) (LocalDef _) = GT
   compare (Imported is1 _) (Imported is2 _) = compare (head is1) (head is2)

instance Ord ImportSpec where
   compare is1 is2 = (is_mod is1 `compare` is_mod is2) `thenCmp` 
		     (is_loc is1 `compare` is_loc is2)
\end{code}

\begin{code}
plusProv :: Provenance -> Provenance -> Provenance
-- Choose LocalDef over Imported
-- There is an obscure bug lurking here; in the presence
-- of recursive modules, something can be imported *and* locally
-- defined, and one might refer to it with a qualified name from
-- the import -- but I'm going to ignore that because it makes
-- the isLocalGRE predicate so much nicer this way
plusProv (LocalDef m1) (LocalDef m2) 
  = pprPanic "plusProv" (ppr m1 <+> ppr m2)
plusProv p1@(LocalDef _) p2 = p1
plusProv p1 p2@(LocalDef _) = p2
plusProv (Imported is1 ex1) (Imported is2 ex2) 
  = Imported (is1++is2) (ex1 || ex2)

pprNameProvenance :: GlobalRdrElt -> SDoc
pprNameProvenance (GRE {gre_name = name, gre_prov = LocalDef _})
  = ptext SLIT("defined at") <+> ppr (nameSrcLoc name)
pprNameProvenance (GRE {gre_name = name, gre_prov = Imported (why:whys) _})
  = sep [ppr_reason why, nest 2 (ppr_defn (nameSrcLoc name))]

ppr_reason imp_spec
 = ptext SLIT("imported from") <+> ppr (is_mod imp_spec) 
	<+> ptext SLIT("at") <+> ppr (is_loc imp_spec)

ppr_defn loc | isGoodSrcLoc loc = parens (ptext SLIT("defined at") <+> ppr loc)
	     | otherwise	= empty
\end{code}
