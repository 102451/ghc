
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[TcMonoType]{Typechecking user-specified @MonoTypes@}

\begin{code}
module TcHsType (
	tcHsSigType, tcHsDeriv,
	UserTypeCtxt(..), 

		-- Kind checking
	kcHsTyVars, kcHsSigType, kcHsLiftedSigType, 
	kcCheckHsType, kcHsContext, kcHsType, 
	
		-- Typechecking kinded types
	tcHsKindedContext, tcHsKindedType, tcHsBangType,
	tcTyVarBndrs, dsHsType, tcLHsConSig, tcDataKindSig,

	tcHsPatSigType, tcAddLetBoundTyVars,
	
	TcSigInfo(..), mkTcSig, 
	TcSigFun, lookupSig 
   ) where

#include "HsVersions.h"

import HsSyn		( HsType(..), LHsType, HsTyVarBndr(..), LHsTyVarBndr, HsBang,
			  LHsContext, HsPred(..), LHsPred, LHsBinds,
			  getBangStrictness, collectSigTysFromHsBinds )
import RnHsSyn		( extractHsTyVars )
import TcRnMonad
import TcEnv		( tcExtendTyVarEnv, tcExtendKindEnv,
			  tcLookup, tcLookupClass, tcLookupTyCon,
		 	  TyThing(..), getInLocalScope, wrongThingErr
			)
import TcMType		( newKindVar, tcSkolType, newMetaTyVar, 
			  zonkTcKindToKind, 
			  checkValidType, UserTypeCtxt(..), pprHsSigCtxt
			)
import TcUnify		( unifyFunKind, checkExpectedKind )
import TcType		( Type, PredType(..), ThetaType, 
			  SkolemInfo(SigSkol), MetaDetails(Flexi),
			  TcType, TcTyVar, TcKind, TcThetaType, TcTauType,
			  mkTyVarTy, mkFunTy, 
		 	  mkForAllTys, mkFunTys, tcEqType, isPredTy,
			  mkSigmaTy, mkPredTy, mkGenTyConApp, mkTyConApp, mkAppTys, 
			  tcSplitFunTy_maybe, tcSplitForAllTys )
import Kind 		( Kind, isLiftedTypeKind, liftedTypeKind, ubxTupleKind, 
			  openTypeKind, argTypeKind, splitKindFunTys )
import Id		( idName, idType )
import Var		( TyVar, mkTyVar, tyVarKind )
import TyCon		( TyCon, tyConKind )
import Class		( Class, classTyCon )
import Name		( Name, mkInternalName )
import OccName		( mkOccName, tvName )
import NameSet
import PrelNames	( genUnitTyConName )
import Type		( deShadowTy )
import TysWiredIn	( mkListTy, mkPArrTy, mkTupleTy )
import Bag		( bagToList )
import BasicTypes	( Boxity(..) )
import SrcLoc		( Located(..), unLoc, noLoc, srcSpanStart )
import UniqSupply	( uniqsFromSupply )
import Outputable
import List		( nubBy )
\end{code}


	----------------------------
		General notes
	----------------------------

Generally speaking we now type-check types in three phases

  1.  kcHsType: kind check the HsType
	*includes* performing any TH type splices;
	so it returns a translated, and kind-annotated, type

  2.  dsHsType: convert from HsType to Type:
	perform zonking
	expand type synonyms [mkGenTyApps]
	hoist the foralls [tcHsType]

  3.  checkValidType: check the validity of the resulting type

Often these steps are done one after the other (tcHsSigType).
But in mutually recursive groups of type and class decls we do
	1 kind-check the whole group
	2 build TyCons/Classes in a knot-tied way
	3 check the validity of types in the now-unknotted TyCons/Classes

For example, when we find
	(forall a m. m a -> m a)
we bind a,m to kind varibles and kind-check (m a -> m a).  This makes
a get kind *, and m get kind *->*.  Now we typecheck (m a -> m a) in
an environment that binds a and m suitably.

The kind checker passed to tcHsTyVars needs to look at enough to
establish the kind of the tyvar:
  * For a group of type and class decls, it's just the group, not
	the rest of the program
  * For a tyvar bound in a pattern type signature, its the types
	mentioned in the other type signatures in that bunch of patterns
  * For a tyvar bound in a RULE, it's the type signatures on other
	universally quantified variables in the rule

Note that this may occasionally give surprising results.  For example:

	data T a b = MkT (a b)

Here we deduce			a::*->*,       b::*
But equally valid would be	a::(*->*)-> *, b::*->*


Validity checking
~~~~~~~~~~~~~~~~~
Some of the validity check could in principle be done by the kind checker, 
but not all:

- During desugaring, we normalise by expanding type synonyms.  Only
  after this step can we check things like type-synonym saturation
  e.g. 	type T k = k Int
	type S a = a
  Then (T S) is ok, because T is saturated; (T S) expands to (S Int);
  and then S is saturated.  This is a GHC extension.

- Similarly, also a GHC extension, we look through synonyms before complaining
  about the form of a class or instance declaration

- Ambiguity checks involve functional dependencies, and it's easier to wait
  until knots have been resolved before poking into them

Also, in a mutually recursive group of types, we can't look at the TyCon until we've
finished building the loop.  So to keep things simple, we postpone most validity
checking until step (3).

Knot tying
~~~~~~~~~~
During step (1) we might fault in a TyCon defined in another module, and it might
(via a loop) refer back to a TyCon defined in this module. So when we tie a big
knot around type declarations with ARecThing, so that the fault-in code can get
the TyCon being defined.


%************************************************************************
%*									*
\subsection{Checking types}
%*									*
%************************************************************************

\begin{code}
tcHsSigType :: UserTypeCtxt -> LHsType Name -> TcM Type
  -- Do kind checking, and hoist for-alls to the top
tcHsSigType ctxt hs_ty 
  = addErrCtxt (pprHsSigCtxt ctxt hs_ty) $
    do	{ kinded_ty <- kcTypeType hs_ty
	; ty <- tcHsKindedType kinded_ty
	; checkValidType ctxt ty	
	; returnM ty }
-- Used for the deriving(...) items
tcHsDeriv :: LHsType Name -> TcM ([TyVar], Class, [Type])
tcHsDeriv = addLocM (tc_hs_deriv [])

tc_hs_deriv tv_names (HsPredTy (HsClassP cls_name hs_tys))
  = kcHsTyVars tv_names 		$ \ tv_names' ->
    do	{ cls_kind <- kcClass cls_name
	; (tys, res_kind) <- kcApps cls_kind (ppr cls_name) hs_tys
	; tcTyVarBndrs tv_names'	$ \ tyvars ->
    do	{ arg_tys <- dsHsTypes tys
	; cls <- tcLookupClass cls_name
	; return (tyvars, cls, arg_tys) }}

tc_hs_deriv tv_names1 (HsForAllTy _ tv_names2 (L _ []) (L _ ty))
  = 	-- Funny newtype deriving form
	-- 	forall a. C [a]
	-- where C has arity 2.  Hence can't use regular functions
    tc_hs_deriv (tv_names1 ++ tv_names2) ty

tc_hs_deriv _ other
  = failWithTc (ptext SLIT("Illegal deriving item") <+> ppr other)
\end{code}

	These functions are used during knot-tying in
	type and class declarations, when we have to
 	separate kind-checking, desugaring, and validity checking

\begin{code}
kcHsSigType, kcHsLiftedSigType :: LHsType Name -> TcM (LHsType Name)
	-- Used for type signatures
kcHsSigType ty 	     = kcTypeType ty
kcHsLiftedSigType ty = kcLiftedType ty

tcHsKindedType :: LHsType Name -> TcM Type
  -- Don't do kind checking, nor validity checking, 
  -- 	but do hoist for-alls to the top
  -- This is used in type and class decls, where kinding is
  -- done in advance, and validity checking is done later
  -- [Validity checking done later because of knot-tying issues.]
tcHsKindedType hs_ty 
  = do	{ ty <- dsHsType hs_ty
	; return (hoistForAllTys ty) }

tcHsBangType :: LHsType Name -> TcM Type
-- Permit a bang, but discard it
tcHsBangType (L span (HsBangTy b ty)) = tcHsKindedType ty
tcHsBangType ty 		      = tcHsKindedType ty

tcHsKindedContext :: LHsContext Name -> TcM ThetaType
-- Used when we are expecting a ClassContext (i.e. no implicit params)
-- Does not do validity checking, like tcHsKindedType
tcHsKindedContext hs_theta = addLocM (mappM dsHsLPred) hs_theta
\end{code}


%************************************************************************
%*									*
		The main kind checker: kcHsType
%*									*
%************************************************************************
	
	First a couple of simple wrappers for kcHsType

\begin{code}
---------------------------
kcLiftedType :: LHsType Name -> TcM (LHsType Name)
-- The type ty must be a *lifted* *type*
kcLiftedType ty = kcCheckHsType ty liftedTypeKind
    
---------------------------
kcTypeType :: LHsType Name -> TcM (LHsType Name)
-- The type ty must be a *type*, but it can be lifted or 
-- unlifted or an unboxed tuple.
kcTypeType ty = kcCheckHsType ty openTypeKind

---------------------------
kcCheckHsType :: LHsType Name -> TcKind -> TcM (LHsType Name)
-- Check that the type has the specified kind
-- Be sure to use checkExpectedKind, rather than simply unifying 
-- with OpenTypeKind, because it gives better error messages
kcCheckHsType (L span ty) exp_kind 
  = setSrcSpan span				$
    kc_hs_type ty				`thenM` \ (ty', act_kind) ->
    checkExpectedKind ty act_kind exp_kind	`thenM_`
    returnM (L span ty')
\end{code}

	Here comes the main function

\begin{code}
kcHsType :: LHsType Name -> TcM (LHsType Name, TcKind)
kcHsType ty = wrapLocFstM kc_hs_type ty
-- kcHsType *returns* the kind of the type, rather than taking an expected
-- kind as argument as tcExpr does.  
-- Reasons: 
--	(a) the kind of (->) is
--		forall bx1 bx2. Type bx1 -> Type bx2 -> Type Boxed
--  	    so we'd need to generate huge numbers of bx variables.
--	(b) kinds are so simple that the error messages are fine
--
-- The translated type has explicitly-kinded type-variable binders

kc_hs_type (HsParTy ty)
 = kcHsType ty		`thenM` \ (ty', kind) ->
   returnM (HsParTy ty', kind)

kc_hs_type (HsTyVar name)
  = kcTyVar name	`thenM` \ kind ->
    returnM (HsTyVar name, kind)

kc_hs_type (HsListTy ty) 
  = kcLiftedType ty			`thenM` \ ty' ->
    returnM (HsListTy ty', liftedTypeKind)

kc_hs_type (HsPArrTy ty)
  = kcLiftedType ty			`thenM` \ ty' ->
    returnM (HsPArrTy ty', liftedTypeKind)

kc_hs_type (HsNumTy n)
   = returnM (HsNumTy n, liftedTypeKind)

kc_hs_type (HsKindSig ty k) 
  = kcCheckHsType ty k	`thenM` \ ty' ->
    returnM (HsKindSig ty' k, k)

kc_hs_type (HsTupleTy Boxed tys)
  = mappM kcLiftedType tys	`thenM` \ tys' ->
    returnM (HsTupleTy Boxed tys', liftedTypeKind)

kc_hs_type (HsTupleTy Unboxed tys)
  = mappM kcTypeType tys	`thenM` \ tys' ->
    returnM (HsTupleTy Unboxed tys', ubxTupleKind)

kc_hs_type (HsFunTy ty1 ty2)
  = kcCheckHsType ty1 argTypeKind	`thenM` \ ty1' ->
    kcTypeType ty2			`thenM` \ ty2' ->
    returnM (HsFunTy ty1' ty2', liftedTypeKind)

kc_hs_type ty@(HsOpTy ty1 op ty2)
  = addLocM kcTyVar op			`thenM` \ op_kind ->
    kcApps op_kind (ppr op) [ty1,ty2]	`thenM` \ ([ty1',ty2'], res_kind) ->
    returnM (HsOpTy ty1' op ty2', res_kind)

kc_hs_type ty@(HsAppTy ty1 ty2)
  = kcHsType fun_ty			  `thenM` \ (fun_ty', fun_kind) ->
    kcApps fun_kind (ppr fun_ty) arg_tys  `thenM` \ ((arg_ty':arg_tys'), res_kind) ->
    returnM (foldl mk_app (HsAppTy fun_ty' arg_ty') arg_tys', res_kind)
  where
    (fun_ty, arg_tys) = split ty1 [ty2]
    split (L _ (HsAppTy f a)) as = split f (a:as)
    split f       	      as = (f,as)
    mk_app fun arg = HsAppTy (noLoc fun) arg	-- Add noLocs for inner nodes of
						-- the application; they are never used
    
kc_hs_type (HsPredTy pred)
  = kcHsPred pred		`thenM` \ pred' ->
    returnM (HsPredTy pred', liftedTypeKind)

kc_hs_type (HsForAllTy exp tv_names context ty)
  = kcHsTyVars tv_names		$ \ tv_names' ->
    kcHsContext context		`thenM`	\ ctxt' ->
    kcLiftedType ty		`thenM` \ ty' ->
	-- The body of a forall is usually a type, but in principle
	-- there's no reason to prohibit *unlifted* types.
	-- In fact, GHC can itself construct a function with an
	-- unboxed tuple inside a for-all (via CPR analyis; see 
	-- typecheck/should_compile/tc170)
	--
	-- Still, that's only for internal interfaces, which aren't
	-- kind-checked, so we only allow liftedTypeKind here
    returnM (HsForAllTy exp tv_names' ctxt' ty', liftedTypeKind)

kc_hs_type (HsBangTy b ty)
  = do { (ty', kind) <- kcHsType ty
       ; return (HsBangTy b ty', kind) }

kc_hs_type ty@(HsSpliceTy _)
  = failWithTc (ptext SLIT("Unexpected type splice:") <+> ppr ty)


---------------------------
kcApps :: TcKind			-- Function kind
       -> SDoc				-- Function 
       -> [LHsType Name]		-- Arg types
       -> TcM ([LHsType Name], TcKind)	-- Kind-checked args
kcApps fun_kind ppr_fun args
  = split_fk fun_kind (length args)	`thenM` \ (arg_kinds, res_kind) ->
    zipWithM kc_arg args arg_kinds	`thenM` \ args' ->
    returnM (args', res_kind)
  where
    split_fk fk 0 = returnM ([], fk)
    split_fk fk n = unifyFunKind fk	`thenM` \ mb_fk ->
		    case mb_fk of 
			Nothing       -> failWithTc too_many_args 
			Just (ak,fk') -> split_fk fk' (n-1)	`thenM` \ (aks, rk) ->
					 returnM (ak:aks, rk)

    kc_arg arg arg_kind = kcCheckHsType arg arg_kind

    too_many_args = ptext SLIT("Kind error:") <+> quotes ppr_fun <+>
		    ptext SLIT("is applied to too many type arguments")

---------------------------
kcHsContext :: LHsContext Name -> TcM (LHsContext Name)
kcHsContext ctxt = wrapLocM (mappM kcHsLPred) ctxt

kcHsLPred :: LHsPred Name -> TcM (LHsPred Name)
kcHsLPred = wrapLocM kcHsPred

kcHsPred :: HsPred Name -> TcM (HsPred Name)
kcHsPred pred	-- Checks that the result is of kind liftedType
  = kc_pred pred				`thenM` \ (pred', kind) ->
    checkExpectedKind pred kind liftedTypeKind	`thenM_` 
    returnM pred'
    
---------------------------
kc_pred :: HsPred Name -> TcM (HsPred Name, TcKind)	
	-- Does *not* check for a saturated
	-- application (reason: used from TcDeriv)
kc_pred pred@(HsIParam name ty)
  = kcHsType ty		`thenM` \ (ty', kind) ->
    returnM (HsIParam name ty', kind)

kc_pred pred@(HsClassP cls tys)
  = kcClass cls			`thenM` \ kind ->
    kcApps kind (ppr cls) tys	`thenM` \ (tys', res_kind) ->
    returnM (HsClassP cls tys', res_kind)

---------------------------
kcTyVar :: Name -> TcM TcKind
kcTyVar name	-- Could be a tyvar or a tycon
  = traceTc (text "lk1" <+> ppr name) 	`thenM_`
    tcLookup name	`thenM` \ thing ->
    traceTc (text "lk2" <+> ppr name <+> ppr thing) 	`thenM_`
    case thing of 
	ATyVar tv	    	-> returnM (tyVarKind tv)
	AThing kind		-> returnM kind
	AGlobal (ATyCon tc) 	-> returnM (tyConKind tc) 
	other			-> wrongThingErr "type" thing name

kcClass :: Name -> TcM TcKind
kcClass cls	-- Must be a class
  = tcLookup cls 				`thenM` \ thing -> 
    case thing of
	AThing kind		-> returnM kind
	AGlobal (AClass cls)    -> returnM (tyConKind (classTyCon cls))
	other		        -> wrongThingErr "class" thing cls
\end{code}


%************************************************************************
%*									*
		Desugaring
%*									*
%************************************************************************

The type desugarer

	* Transforms from HsType to Type
	* Zonks any kinds

It cannot fail, and does no validity checking, except for 
structural matters, such as spurious ! annotations.

\begin{code}
dsHsType :: LHsType Name -> TcM Type
-- All HsTyVarBndrs in the intput type are kind-annotated
dsHsType ty = ds_type (unLoc ty)

ds_type ty@(HsTyVar name)
  = ds_app ty []

ds_type (HsParTy ty)		-- Remove the parentheses markers
  = dsHsType ty

ds_type ty@(HsBangTy _ _)	-- No bangs should be here
  = failWithTc (ptext SLIT("Unexpected strictness annotation:") <+> ppr ty)

ds_type (HsKindSig ty k)
  = dsHsType ty	-- Kind checking done already

ds_type (HsListTy ty)
  = dsHsType ty				`thenM` \ tau_ty ->
    returnM (mkListTy tau_ty)

ds_type (HsPArrTy ty)
  = dsHsType ty				`thenM` \ tau_ty ->
    returnM (mkPArrTy tau_ty)

ds_type (HsTupleTy boxity tys)
  = dsHsTypes tys			`thenM` \ tau_tys ->
    returnM (mkTupleTy boxity (length tys) tau_tys)

ds_type (HsFunTy ty1 ty2)
  = dsHsType ty1			`thenM` \ tau_ty1 ->
    dsHsType ty2			`thenM` \ tau_ty2 ->
    returnM (mkFunTy tau_ty1 tau_ty2)

ds_type (HsOpTy ty1 (L span op) ty2)
  = dsHsType ty1 		`thenM` \ tau_ty1 ->
    dsHsType ty2 		`thenM` \ tau_ty2 ->
    setSrcSpan span (ds_var_app op [tau_ty1,tau_ty2])

ds_type (HsNumTy n)
  = ASSERT(n==1)
    tcLookupTyCon genUnitTyConName	`thenM` \ tc ->
    returnM (mkTyConApp tc [])

ds_type ty@(HsAppTy _ _)
  = ds_app ty []

ds_type (HsPredTy pred)
  = dsHsPred pred	`thenM` \ pred' ->
    returnM (mkPredTy pred')

ds_type full_ty@(HsForAllTy exp tv_names ctxt ty)
  = tcTyVarBndrs tv_names		$ \ tyvars ->
    mappM dsHsLPred (unLoc ctxt)	`thenM` \ theta ->
    dsHsType ty				`thenM` \ tau ->
    returnM (mkSigmaTy tyvars theta tau)

dsHsTypes arg_tys = mappM dsHsType arg_tys
\end{code}

Help functions for type applications
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

\begin{code}
ds_app :: HsType Name -> [LHsType Name] -> TcM Type
ds_app (HsAppTy ty1 ty2) tys
  = ds_app (unLoc ty1) (ty2:tys)

ds_app ty tys
  = dsHsTypes tys			`thenM` \ arg_tys ->
    case ty of
	HsTyVar fun -> ds_var_app fun arg_tys
	other	    -> ds_type ty		`thenM` \ fun_ty ->
		       returnM (mkAppTys fun_ty arg_tys)

ds_var_app :: Name -> [Type] -> TcM Type
ds_var_app name arg_tys 
 = tcLookup name			`thenM` \ thing ->
    case thing of
	ATyVar tv 	     -> returnM (mkAppTys (mkTyVarTy tv) arg_tys)
	AGlobal (ATyCon tc)  -> returnM (mkGenTyConApp tc arg_tys)
--	AThing _ 	     -> tcLookupTyCon name	`thenM` \ tc ->
--			        returnM (mkGenTyConApp tc arg_tys)
	other -> pprPanic "ds_app_type" (ppr name <+> ppr arg_tys)
\end{code}


Contexts
~~~~~~~~

\begin{code}
dsHsLPred :: LHsPred Name -> TcM PredType
dsHsLPred pred = dsHsPred (unLoc pred)

dsHsPred pred@(HsClassP class_name tys)
  = dsHsTypes tys			`thenM` \ arg_tys ->
    tcLookupClass class_name		`thenM` \ clas ->
    returnM (ClassP clas arg_tys)

dsHsPred (HsIParam name ty)
  = dsHsType ty					`thenM` \ arg_ty ->
    returnM (IParam name arg_ty)
\end{code}

GADT constructor signatures

\begin{code}
tcLHsConSig :: LHsType Name 
	    -> TcM ([TcTyVar], TcThetaType, 
		    [HsBang], [TcType],
		    TyCon, [TcType])
-- Take apart the type signature for a data constructor
-- The difference is that there can be bangs at the top of
-- the argument types, and kind-checking is the right place to check
tcLHsConSig sig@(L span (HsForAllTy exp tv_names ctxt ty))
  = setSrcSpan span		$
    addErrCtxt (gadtSigCtxt sig) $
    tcTyVarBndrs tv_names	$ \ tyvars ->
    do	{ theta <- mappM dsHsLPred (unLoc ctxt)
	; (bangs, arg_tys, tc, res_tys) <- tc_con_sig_tau ty
	; return (tyvars, theta, bangs, arg_tys, tc, res_tys) }
tcLHsConSig ty 
  = do	{ (bangs, arg_tys, tc, res_tys) <- tc_con_sig_tau ty
	; return ([], [], bangs, arg_tys, tc, res_tys) }

--------
tc_con_sig_tau (L _ (HsFunTy arg ty))
  = do	{ (bangs, arg_tys, tc, res_tys) <- tc_con_sig_tau ty
	; arg_ty <- tcHsBangType arg
	; return (getBangStrictness arg : bangs, 
		  arg_ty : arg_tys, tc, res_tys) }

tc_con_sig_tau ty
  = do	{ (tc, res_tys) <- tc_con_res ty []
	; return ([], [], tc, res_tys) }

--------
tc_con_res (L _ (HsAppTy fun res_ty)) res_tys
  = do	{ res_ty' <- dsHsType res_ty
	; tc_con_res fun (res_ty' : res_tys) }

tc_con_res ty@(L _ (HsTyVar name)) res_tys
  = do	{ thing <- tcLookup name
	; case thing of
	    AGlobal (ATyCon tc) -> return (tc, res_tys)
	    other -> failWithTc (badGadtDecl ty)
	}

tc_con_res ty _ = failWithTc (badGadtDecl ty)

gadtSigCtxt ty
  = hang (ptext SLIT("In the signature of a data constructor:"))
       2 (ppr ty)
badGadtDecl ty
  = hang (ptext SLIT("Malformed constructor signature:"))
       2 (ppr ty)
\end{code}

%************************************************************************
%*									*
		Type-variable binders
%*									*
%************************************************************************


\begin{code}
kcHsTyVars :: [LHsTyVarBndr Name] 
	   -> ([LHsTyVarBndr Name] -> TcM r) 	-- These binders are kind-annotated
						-- They scope over the thing inside
	   -> TcM r
kcHsTyVars tvs thing_inside 
  = mappM (wrapLocM kcHsTyVar) tvs	`thenM` \ bndrs ->
    tcExtendKindEnv [(n,k) | L _ (KindedTyVar n k) <- bndrs]
		    (thing_inside bndrs)

kcHsTyVar :: HsTyVarBndr Name -> TcM (HsTyVarBndr Name)
	-- Return a *kind-annotated* binder, and a tyvar with a mutable kind in it	
kcHsTyVar (UserTyVar name)        = newKindVar 	`thenM` \ kind ->
				    returnM (KindedTyVar name kind)
kcHsTyVar (KindedTyVar name kind) = returnM (KindedTyVar name kind)

------------------
tcTyVarBndrs :: [LHsTyVarBndr Name] 	-- Kind-annotated binders, which need kind-zonking
	     -> ([TyVar] -> TcM r)
	     -> TcM r
-- Used when type-checking types/classes/type-decls
-- Brings into scope immutable TyVars, not mutable ones that require later zonking
tcTyVarBndrs bndrs thing_inside
  = mapM (zonk . unLoc) bndrs	`thenM` \ tyvars ->
    tcExtendTyVarEnv tyvars (thing_inside tyvars)
  where
    zonk (KindedTyVar name kind) = zonkTcKindToKind kind	`thenM` \ kind' ->
				   returnM (mkTyVar name kind')
    zonk (UserTyVar name) = pprTrace "Un-kinded tyvar" (ppr name) $
			    returnM (mkTyVar name liftedTypeKind)

-----------------------------------
tcDataKindSig :: Maybe Kind -> TcM [TyVar]
-- GADT decls can have a (perhpas partial) kind signature
--	e.g.  data T :: * -> * -> * where ...
-- This function makes up suitable (kinded) type variables for 
-- the argument kinds, and checks that the result kind is indeed *
tcDataKindSig Nothing = return []
tcDataKindSig (Just kind)
  = do	{ checkTc (isLiftedTypeKind res_kind) (badKindSig kind)
	; span <- getSrcSpanM
	; us   <- newUniqueSupply 
	; let loc   = srcSpanStart span
	      uniqs = uniqsFromSupply us
	; return [ mk_tv loc uniq str kind 
		 | ((kind, str), uniq) <- arg_kinds `zip` names `zip` uniqs ] }
  where
    (arg_kinds, res_kind) = splitKindFunTys kind
    mk_tv loc uniq str kind = mkTyVar name kind
	where
	   name = mkInternalName uniq occ loc
	   occ  = mkOccName tvName str

    names :: [String]	-- a,b,c...aa,ab,ac etc
    names = [ c:cs | cs <- "" : names, c <- ['a'..'z'] ] 

badKindSig :: Kind -> SDoc
badKindSig kind 
 = hang (ptext SLIT("Kind signature on data type declaration has non-* return kind"))
	2 (ppr kind)
\end{code}


%************************************************************************
%*									*
		Scoped type variables
%*									*
%************************************************************************


tcAddScopedTyVars is used for scoped type variables added by pattern
type signatures
	e.g.  \ ((x::a), (y::a)) -> x+y
They never have explicit kinds (because this is source-code only)
They are mutable (because they can get bound to a more specific type).

Usually we kind-infer and expand type splices, and then
tupecheck/desugar the type.  That doesn't work well for scoped type
variables, because they scope left-right in patterns.  (e.g. in the
example above, the 'a' in (y::a) is bound by the 'a' in (x::a).

The current not-very-good plan is to
  * find all the types in the patterns
  * find their free tyvars
  * do kind inference
  * bring the kinded type vars into scope
  * BUT throw away the kind-checked type
  	(we'll kind-check it again when we type-check the pattern)

This is bad because throwing away the kind checked type throws away
its splices.  But too bad for now.  [July 03]

Historical note:
    We no longer specify that these type variables must be univerally 
    quantified (lots of email on the subject).  If you want to put that 
    back in, you need to
	a) Do a checkSigTyVars after thing_inside
	b) More insidiously, don't pass in expected_ty, else
	   we unify with it too early and checkSigTyVars barfs
	   Instead you have to pass in a fresh ty var, and unify
	   it with expected_ty afterwards

\begin{code}
tcPatSigBndrs :: LHsType Name
	      -> TcM ([TcTyVar],	-- Brought into scope
		      LHsType Name)	-- Kinded, but not yet desugared

tcPatSigBndrs hs_ty
  = do	{ in_scope <- getInLocalScope
	; span <- getSrcSpanM
	; let sig_tvs = [ L span (UserTyVar n) 
			| n <- nameSetToList (extractHsTyVars hs_ty),
			  not (in_scope n) ]
		-- The tyvars we want are the free type variables of 
		-- the type that are not already in scope

	-- Behave like kcHsType on a ForAll type
	-- i.e. make kinded tyvars with mutable kinds, 
	--      and kind-check the enclosed types
	; (kinded_tvs, kinded_ty) <- kcHsTyVars sig_tvs $ \ kinded_tvs -> do
				    { kinded_ty <- kcTypeType hs_ty
				    ; return (kinded_tvs, kinded_ty) }

	-- Zonk the mutable kinds and bring the tyvars into scope
	-- Just like the call to tcTyVarBndrs in ds_type (HsForAllTy case), 
	-- except that it brings *meta* tyvars into scope, not regular ones
	--
	-- 	[Out of date, but perhaps should be resurrected]
	-- Furthermore, the tyvars are PatSigTvs, which means that we get better
	-- error messages when type variables escape:
	--      Inferred type is less polymorphic than expected
	--   	Quantified type variable `t' escapes
	--   	It is mentioned in the environment:
	--	t is bound by the pattern type signature at tcfail103.hs:6
	; tyvars <- mapM (zonk . unLoc) kinded_tvs
	; return (tyvars, kinded_ty) }
  where
    zonk (KindedTyVar name kind) = zonkTcKindToKind kind	`thenM` \ kind' ->
				   newMetaTyVar name kind' Flexi
	-- Scoped type variables are bound to a *type*, hence Flexi
    zonk (UserTyVar name) = pprTrace "Un-kinded tyvar" (ppr name) $
			    returnM (mkTyVar name liftedTypeKind)

tcHsPatSigType :: UserTypeCtxt
	       -> LHsType Name 		-- The type signature
	       -> TcM ([TcTyVar], 	-- Newly in-scope type variables
			TcType)		-- The signature

tcHsPatSigType ctxt hs_ty 
  = addErrCtxt (pprHsSigCtxt ctxt hs_ty) $
    do	{ (tyvars, kinded_ty) <- tcPatSigBndrs hs_ty

	 -- Complete processing of the type, and check its validity
	; tcExtendTyVarEnv tyvars $ do
		{ sig_ty <- tcHsKindedType kinded_ty	
		; checkValidType ctxt sig_ty 
		; return (tyvars, sig_ty) }
	}

tcAddLetBoundTyVars :: LHsBinds Name -> TcM a -> TcM a
-- Turgid funciton, used for type variables bound by the patterns of a let binding

tcAddLetBoundTyVars binds thing_inside
  = go (collectSigTysFromHsBinds (bagToList binds)) thing_inside
  where
    go [] thing_inside = thing_inside
    go (hs_ty:hs_tys) thing_inside
	= do { (tyvars, _kinded_ty) <- tcPatSigBndrs hs_ty
	     ; tcExtendTyVarEnv tyvars (go hs_tys thing_inside) }
\end{code}


%************************************************************************
%*									*
\subsection{Signatures}
%*									*
%************************************************************************

@tcSigs@ checks the signatures for validity, and returns a list of
{\em freshly-instantiated} signatures.  That is, the types are already
split up, and have fresh type variables installed.  All non-type-signature
"RenamedSigs" are ignored.

The @TcSigInfo@ contains @TcTypes@ because they are unified with
the variable's type, and after that checked to see whether they've
been instantiated.

\begin{code}
data TcSigInfo
  = TcSigInfo {
	sig_id :: TcId,		    -- *Polymorphic* binder for this value...
	sig_tvs   :: [TcTyVar],	    -- tyvars
	sig_theta :: TcThetaType,   -- theta
	sig_tau   :: TcTauType,	    -- tau
	sig_loc :: InstLoc	    -- The location of the signature
    }

type TcSigFun = Name -> Maybe TcSigInfo

instance Outputable TcSigInfo where
    ppr (TcSigInfo { sig_id = id, sig_tvs = tyvars, sig_theta = theta, sig_tau = tau})
	= ppr id <+> ptext SLIT("::") <+> ppr tyvars <+> ppr theta <+> ptext SLIT("=>") <+> ppr tau

lookupSig :: [TcSigInfo] -> TcSigFun	-- Search for a particular signature
lookupSig [] name = Nothing
lookupSig (sig : sigs) name
  | name == idName (sig_id sig) = Just sig
  | otherwise	     	 	= lookupSig sigs name

mkTcSig :: TcId -> TcM TcSigInfo
mkTcSig poly_id
  = 	-- Instantiate this type
	-- It's important to do this even though in the error-free case
	-- we could just split the sigma_tc_ty (since the tyvars don't
	-- unified with anything).  But in the case of an error, when
	-- the tyvars *do* get unified with something, we want to carry on
	-- typechecking the rest of the program with the function bound
	-- to a pristine type, namely sigma_tc_ty
    do	{ let rigid_info = SigSkol (idName poly_id)
	; (tyvars', theta', tau') <- tcSkolType rigid_info (idType poly_id)
	; loc <- getInstLoc (SigOrigin rigid_info)
	; return (TcSigInfo { sig_id = poly_id, sig_tvs = tyvars', 
			      sig_theta = theta', sig_tau = tau', sig_loc = loc }) }
\end{code}


%************************************************************************
%*									*
\subsection{Errors and contexts}
%*									*
%************************************************************************


\begin{code}
hoistForAllTys :: Type -> Type
-- Used for user-written type signatures only
-- Move all the foralls and constraints to the top
-- e.g.  T -> forall a. a        ==>   forall a. T -> a
--	 T -> (?x::Int) -> Int   ==>   (?x::Int) -> T -> Int
--
-- Also: eliminate duplicate constraints.  These can show up
-- when hoisting constraints, notably implicit parameters.
--
-- We want to 'look through' type synonyms when doing this
-- so it's better done on the Type than the HsType

hoistForAllTys ty
  = let
	no_shadow_ty = deShadowTy ty
	-- Running over ty with an empty substitution gives it the
	-- no-shadowing property.  This is important.  For example:
	--	type Foo r = forall a. a -> r
	--	foo :: Foo (Foo ())
	-- Here the hoisting should give
	--	foo :: forall a a1. a -> a1 -> ()
	--
	-- What about type vars that are lexically in scope in the envt?
	-- We simply rely on them having a different unique to any
	-- binder in 'ty'.  Otherwise we'd have to slurp the in-scope-tyvars
	-- out of the envt, which is boring and (I think) not necessary.
    in
    case hoist no_shadow_ty of 
	(tvs, theta, body) -> mkForAllTys tvs (mkFunTys (nubBy tcEqType theta) body)
		-- The 'nubBy' eliminates duplicate constraints,
		-- notably implicit parameters
  where
    hoist ty
	| (tvs1, body_ty) <- tcSplitForAllTys ty,
	  not (null tvs1)
	= case hoist body_ty of
		(tvs2,theta,tau) -> (tvs1 ++ tvs2, theta, tau)

	| Just (arg, res) <- tcSplitFunTy_maybe ty
	= let
	      arg' = hoistForAllTys arg	-- Don't forget to apply hoist recursively
	  in				-- to the argument type
	  if (isPredTy arg') then
	    case hoist res of
		(tvs,theta,tau) -> (tvs, arg':theta, tau)
	  else
	     case hoist res of
		(tvs,theta,tau) -> (tvs, theta, mkFunTy arg' tau)

	| otherwise = ([], [], ty)
\end{code}

