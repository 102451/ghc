%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%

	This module defines interface types and binders

\begin{code}
module IfaceType (
	IfaceType(..), IfaceKind, IfacePredType(..), IfaceTyCon(..),
	IfaceContext, IfaceBndr(..), IfaceTvBndr, IfaceIdBndr,

	IfaceExtName(..), mkIfaceExtName, ifaceTyConName, 

	-- Conversion from Type -> IfaceType
	toIfaceType, toIfacePred, toIfaceContext, 
	toIfaceBndr, toIfaceIdBndr, toIfaceTvBndrs, 

	-- Printing
	pprIfaceType, pprParendIfaceType, pprIfaceContext, 
	pprIfaceIdBndr, pprIfaceTvBndr, pprIfaceTvBndrs, pprIfaceBndrs,
	tOP_PREC, tYCON_PREC, noParens, maybeParen, pprIfaceForAllPart

    ) where

#include "HsVersions.h"

import Kind		( Kind(..) )
import TypeRep		( Type(..), TyNote(..), PredType(..), Kind, ThetaType )
import TyCon		( TyCon, isTupleTyCon, tyConArity, tupleTyConBoxity )
import Var		( isId, tyVarKind, idType )
import TysWiredIn	( listTyConName, parrTyConName, tupleTyCon, intTyConName, charTyConName, boolTyConName )
import OccName		( OccName )
import Name		( Name, getName, getOccName, nameModule, nameOccName )
import Module		( Module )
import BasicTypes	( IPName(..), Arity, Version, mapIPName, tupleParens, Boxity )
import Outputable
import FastString
\end{code}

	
%************************************************************************
%*									*
		IfaceExtName
%*									*
%************************************************************************

\begin{code}
data IfaceExtName
  = ExtPkg Module OccName		-- From an external package; no version #
					-- Also used for wired-in things regardless
					-- of whether they are home-pkg or not

  | HomePkg Module OccName Version	-- From another module in home package;
					-- has version #

  | LocalTop OccName			-- Top-level from the same module as 
					-- the enclosing IfaceDecl

  | LocalTopSub		-- Same as LocalTop, but for a class method or constr
	OccName		-- Class-meth/constr name
	OccName		-- Parent class/datatype name
	-- LocalTopSub is written into iface files as LocalTop; the parent 
	-- info is only used when computing version information in MkIface

mkIfaceExtName name = ExtPkg (nameModule name) (nameOccName name)
	-- Local helper for wired-in names
\end{code}


%************************************************************************
%*									*
		Local (nested) binders
%*									*
%************************************************************************

\begin{code}
data IfaceBndr 		-- Local (non-top-level) binders
  = IfaceIdBndr IfaceIdBndr
  | IfaceTvBndr IfaceTvBndr

type IfaceIdBndr  = (OccName, IfaceType)	-- OccName, because always local
type IfaceTvBndr  = (OccName, IfaceKind)

-------------------------------
type IfaceKind = Kind			-- Re-use the Kind type, but no KindVars in it

data IfaceType
  = IfaceTyVar    OccName			-- Type variable only, not tycon
  | IfaceAppTy    IfaceType IfaceType
  | IfaceForAllTy IfaceTvBndr IfaceType
  | IfacePredTy   IfacePredType
  | IfaceTyConApp IfaceTyCon [IfaceType]	-- Not necessarily saturated
						-- Includes newtypes, synonyms, tuples
  | IfaceFunTy  IfaceType IfaceType

data IfacePredType 	-- NewTypes are handled as ordinary TyConApps
  = IfaceClassP IfaceExtName [IfaceType]
  | IfaceIParam (IPName OccName) IfaceType

type IfaceContext = [IfacePredType]

data IfaceTyCon 	-- Abbreviations for common tycons with known names
  = IfaceTc IfaceExtName	-- The common case
  | IfaceIntTc | IfaceBoolTc | IfaceCharTc
  | IfaceListTc | IfacePArrTc
  | IfaceTupTc Boxity Arity 

ifaceTyConName :: IfaceTyCon -> Name	-- Works for all except IfaceTc
ifaceTyConName IfaceIntTc  	  = intTyConName
ifaceTyConName IfaceBoolTc 	  = boolTyConName
ifaceTyConName IfaceCharTc 	  = charTyConName
ifaceTyConName IfaceListTc 	  = listTyConName
ifaceTyConName IfacePArrTc 	  = parrTyConName
ifaceTyConName (IfaceTupTc bx ar) = getName (tupleTyCon bx ar)
ifaceTyConName (IfaceTc ext)      = pprPanic "ifaceTyConName" (ppr ext)
\end{code}


%************************************************************************
%*									*
		Functions over IFaceTypes
%*									*
%************************************************************************


\begin{code}
splitIfaceSigmaTy :: IfaceType -> ([IfaceTvBndr], IfaceContext, IfaceType)
-- Mainly for printing purposes
splitIfaceSigmaTy ty
  = (tvs,theta,tau)
  where
    (tvs, rho)   = split_foralls ty
    (theta, tau) = split_rho rho

    split_foralls (IfaceForAllTy tv ty) 
	= case split_foralls ty of { (tvs, rho) -> (tv:tvs, rho) }
    split_foralls rho = ([], rho)

    split_rho (IfaceFunTy (IfacePredTy st) ty) 
	= case split_rho ty of { (sts, tau) -> (st:sts, tau) }
    split_rho tau = ([], tau)
\end{code}

%************************************************************************
%*									*
		Pretty-printing
%*									*
%************************************************************************

Precedence
~~~~~~~~~~
@ppr_ty@ takes an @Int@ that is the precedence of the context.
The precedence levels are:
\begin{description}
\item[tOP_PREC]   No parens required.
\item[fUN_PREC]   Left hand argument of a function arrow.
\item[tYCON_PREC] Argument of a type constructor.
\end{description}

\begin{code}
tOP_PREC    = (0 :: Int)  -- type   in ParseIface.y
fUN_PREC    = (1 :: Int)  -- btype  in ParseIface.y
tYCON_PREC  = (2 :: Int)  -- atype  in ParseIface.y

noParens :: SDoc -> SDoc
noParens pp = pp

maybeParen ctxt_prec inner_prec pretty
  | ctxt_prec < inner_prec = pretty
  | otherwise		   = parens pretty
\end{code}


----------------------------- Printing binders ------------------------------------

\begin{code}
-- These instances are used only when printing for the user, either when
-- debugging, or in GHCi when printing the results of a :info command
instance Outputable IfaceExtName where
    ppr (ExtPkg mod occ)       = pprExt mod occ
    ppr (HomePkg mod occ vers) = pprExt mod occ <> braces (ppr vers)
    ppr (LocalTop occ)	       = ppr occ	-- Do we want to distinguish these 
    ppr (LocalTopSub occ _)    = ppr occ	-- from an ordinary occurrence?

pprExt :: Module -> OccName -> SDoc
pprExt mod occ
  = getPprStyle $ \ sty ->
    if unqualStyle sty mod occ then
	ppr occ
    else 
	ppr mod <> dot <> ppr occ

instance Outputable IfaceBndr where
    ppr (IfaceIdBndr bndr) = pprIfaceIdBndr bndr
    ppr (IfaceTvBndr bndr) = char '@' <+> pprIfaceTvBndr bndr

pprIfaceBndrs :: [IfaceBndr] -> SDoc
pprIfaceBndrs bs = sep (map ppr bs)

pprIfaceIdBndr (name, ty) = hsep [ppr name, dcolon, ppr ty]

pprIfaceTvBndr :: IfaceTvBndr -> SDoc
pprIfaceTvBndr (tv, LiftedTypeKind) = ppr tv
pprIfaceTvBndr (tv, kind) 	    = parens (ppr tv <> dcolon <> ppr kind)

pprIfaceTvBndrs :: [IfaceTvBndr] -> SDoc
pprIfaceTvBndrs tyvars = hsep (map pprIfaceTvBndr tyvars)
\end{code}

----------------------------- Printing IfaceType ------------------------------------

\begin{code}
---------------------------------
instance Outputable IfaceType where
  ppr ty = pprIfaceTypeForUser ty

pprIfaceTypeForUser ::IfaceType -> SDoc
-- Drop top-level for-alls; if that's not what you want, use pprIfaceType dire
pprIfaceTypeForUser ty
  = pprIfaceForAllPart [] theta (pprIfaceType tau)
 where		
    (_tvs, theta, tau) = splitIfaceSigmaTy ty

pprIfaceType, pprParendIfaceType ::IfaceType -> SDoc
pprIfaceType       = ppr_ty tOP_PREC
pprParendIfaceType = ppr_ty tYCON_PREC


ppr_ty :: Int -> IfaceType -> SDoc
ppr_ty ctxt_prec (IfaceTyVar tyvar)     = ppr tyvar
ppr_ty ctxt_prec (IfaceTyConApp tc tys) = ppr_tc_app ctxt_prec tc tys
ppr_ty ctxt_prec (IfacePredTy st)       = ppr st

	-- Function types
ppr_ty ctxt_prec (IfaceFunTy ty1 ty2)
  = -- We don't want to lose synonyms, so we mustn't use splitFunTys here.
    maybeParen ctxt_prec fUN_PREC $
    sep (ppr_ty fUN_PREC ty1 : ppr_fun_tail ty2)
  where
    ppr_fun_tail (IfaceFunTy ty1 ty2) 
      = (arrow <+> ppr_ty fUN_PREC ty1) : ppr_fun_tail ty2
    ppr_fun_tail other_ty
      = [arrow <+> pprIfaceType other_ty]

ppr_ty ctxt_prec (IfaceAppTy ty1 ty2)
  = maybeParen ctxt_prec tYCON_PREC $
    ppr_ty fUN_PREC ty1 <+> pprParendIfaceType ty2

ppr_ty ctxt_prec ty@(IfaceForAllTy _ _)
  = maybeParen ctxt_prec fUN_PREC (pprIfaceForAllPart tvs theta (pprIfaceType tau))
 where		
    (tvs, theta, tau) = splitIfaceSigmaTy ty
    
-------------------
pprIfaceForAllPart :: [IfaceTvBndr] -> IfaceContext -> SDoc -> SDoc
pprIfaceForAllPart tvs ctxt doc 
  = sep [ppr_tvs, pprIfaceContext ctxt, doc]
  where
    ppr_tvs | null tvs  = empty
	    | otherwise = ptext SLIT("forall") <+> pprIfaceTvBndrs tvs <> dot

-------------------
ppr_tc_app ctxt_prec tc 	 []   = ppr tc
ppr_tc_app ctxt_prec IfaceListTc [ty] = brackets   (pprIfaceType ty)
ppr_tc_app ctxt_prec IfacePArrTc [ty] = pabrackets (pprIfaceType ty)
ppr_tc_app ctxt_prec (IfaceTupTc bx arity) tys
  | arity == length tys 
  = tupleParens bx (sep (punctuate comma (map pprIfaceType tys)))
ppr_tc_app ctxt_prec tc tys 
  = maybeParen ctxt_prec tYCON_PREC 
	       (sep [ppr tc, nest 4 (sep (map pprParendIfaceType tys))])

-------------------
instance Outputable IfacePredType where
	-- Print without parens
  ppr (IfaceIParam ip ty)  = hsep [ppr ip, dcolon, ppr ty]
  ppr (IfaceClassP cls ts) = ppr cls <+> sep (map pprParendIfaceType ts)

instance Outputable IfaceTyCon where
  ppr (IfaceTc ext) = ppr ext
  ppr other_tc      = ppr (ifaceTyConName other_tc)

-------------------
pprIfaceContext :: IfaceContext -> SDoc
-- Prints "(C a, D b) =>", including the arrow
pprIfaceContext []    = empty
pprIfaceContext theta = parens (sep (punctuate comma (map ppr theta))) 
			<+> ptext SLIT("=>")
  
pabrackets p = ptext SLIT("[:") <> p <> ptext SLIT(":]")
\end{code}

%************************************************************************
%*									*
	Conversion from Type to IfaceType
%*									*
%************************************************************************

\begin{code}
----------------
toIfaceTvBndr tyvar   = (getOccName tyvar, tyVarKind tyvar)
toIfaceIdBndr ext id  = (getOccName id,    toIfaceType ext (idType id))
toIfaceTvBndrs tyvars = map toIfaceTvBndr tyvars

toIfaceBndr ext var
  | isId var  = IfaceIdBndr (toIfaceIdBndr ext var)
  | otherwise = IfaceTvBndr (toIfaceTvBndr var)

---------------------
toIfaceType :: (Name -> IfaceExtName) -> Type -> IfaceType
toIfaceType ext (TyVarTy tv)     	     = IfaceTyVar (getOccName tv)
toIfaceType ext (AppTy t1 t2)    	     = IfaceAppTy (toIfaceType ext t1) (toIfaceType ext t2)
toIfaceType ext (FunTy t1 t2)    	     = IfaceFunTy (toIfaceType ext t1) (toIfaceType ext t2)
toIfaceType ext (TyConApp tc tys) 	     = IfaceTyConApp (mkIfaceTc ext tc) (toIfaceTypes ext tys)
toIfaceType ext (ForAllTy tv t)  	     = IfaceForAllTy (toIfaceTvBndr tv) (toIfaceType ext t)
toIfaceType ext (PredTy st)     	     = IfacePredTy (toIfacePred ext st)
toIfaceType ext (NoteTy (SynNote tc_app) ty) = toIfaceType ext tc_app
toIfaceType ext (NoteTy other_note ty)	     = toIfaceType ext ty

----------------
mkIfaceTc :: (Name -> IfaceExtName) -> TyCon -> IfaceTyCon
mkIfaceTc ext tc 
  | isTupleTyCon tc     = IfaceTupTc (tupleTyConBoxity tc) (tyConArity tc)
  | nm == intTyConName  = IfaceIntTc
  | nm == boolTyConName = IfaceBoolTc 
  | nm == charTyConName = IfaceCharTc 
  | nm == listTyConName = IfaceListTc 
  | nm == parrTyConName = IfacePArrTc 
  | otherwise		= IfaceTc (ext nm)
  where
    nm = getName tc

----------------
toIfaceTypes ext ts = map (toIfaceType ext) ts

----------------
toIfacePred ext (ClassP cls ts) = IfaceClassP (ext (getName cls)) (toIfaceTypes ext ts)
toIfacePred ext (IParam ip t)   = IfaceIParam (mapIPName getOccName ip) (toIfaceType ext t)

----------------
toIfaceContext :: (Name -> IfaceExtName) -> ThetaType -> IfaceContext
toIfaceContext ext cs = map (toIfacePred ext) cs
\end{code}

