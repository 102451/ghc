%
% (c) The AQUA Project, Glasgow University, 1998
%
\section[StdIdInfo]{Standard unfoldings}

This module contains definitions for the IdInfo for things that
have a standard form, namely:

	* data constructors
	* record selectors
	* method and superclass selectors
	* primitive operations

\begin{code}
module MkId (
	mkDictFunId, mkDefaultMethodId,
	mkDictSelId, 

	mkDataConId, mkDataConWrapId,
	mkRecordSelId, 
	mkPrimOpId, mkFCallId,

	mkReboxingAlt, mkNewTypeBody,

	-- And some particular Ids; see below for why they are wired in
	wiredInIds, ghcPrimIds,
	unsafeCoerceId, realWorldPrimId, voidArgId, nullAddrId, seqId,

	mkRuntimeErrorApp,
	rEC_CON_ERROR_ID, iRREFUT_PAT_ERROR_ID, rUNTIME_ERROR_ID,
	nON_EXHAUSTIVE_GUARDS_ERROR_ID,	nO_METHOD_BINDING_ERROR_ID,
	pAT_ERROR_ID
    ) where

#include "HsVersions.h"


import BasicTypes	( Arity, StrictnessMark(..), isMarkedUnboxed, isMarkedStrict )
import TysPrim		( openAlphaTyVars, alphaTyVar, alphaTy, betaTyVar, betaTy,
			  intPrimTy, realWorldStatePrimTy, addrPrimTy
			)
import TysWiredIn	( charTy, mkListTy )
import PrelRules	( primOpRules )
import Rules		( addRule )
import TcType		( Type, ThetaType, mkDictTy, mkPredTys, mkTyConApp,
			  mkTyVarTys, mkClassPred, tcEqPred,
			  mkFunTys, mkFunTy, mkSigmaTy, tcSplitSigmaTy, 
			  isUnLiftedType, mkForAllTys, mkTyVarTy, tyVarsOfType,
			  tcSplitFunTys, tcSplitForAllTys, mkPredTy
			)
import Module		( Module )
import CoreUtils	( exprType )
import CoreUnfold 	( mkTopUnfolding, mkCompulsoryUnfolding, mkOtherCon )
import Literal		( Literal(..), nullAddrLit )
import TyCon		( TyCon, isNewTyCon, tyConTyVars, tyConDataCons,
                          tyConTheta, isProductTyCon, isDataTyCon, isRecursiveTyCon )
import Class		( Class, classTyCon, classTyVars, classSelIds )
import Var		( Id, TyVar, Var )
import VarSet		( isEmptyVarSet )
import Name		( mkWiredInName, mkFCallName, Name )
import OccName		( mkVarOcc )
import PrimOp		( PrimOp(DataToTagOp), primOpSig, mkPrimOpIdName )
import ForeignCall	( ForeignCall )
import DataCon		( DataCon, 
			  dataConFieldLabels, dataConRepArity, dataConTyCon,
			  dataConArgTys, dataConRepType, 
			  dataConOrigArgTys,
                          dataConName, dataConTheta,
			  dataConSig, dataConStrictMarks, dataConWorkId,
			  splitProductType
			)
import Id		( idType, mkGlobalId, mkVanillaGlobal, mkSysLocal,
			  mkTemplateLocals, mkTemplateLocalsNum,
			  mkTemplateLocal, idNewStrictness, idName
			)
import IdInfo		( IdInfo, noCafNoTyGenIdInfo,
			  setUnfoldingInfo, 
			  setArityInfo, setSpecInfo, setCafInfo,
			  setAllStrictnessInfo,
			  GlobalIdDetails(..), CafInfo(..)
			)
import NewDemand	( mkStrictSig, strictSigResInfo, DmdResult(..),
			  mkTopDmdType, topDmd, evalDmd, lazyDmd, retCPR,
			  Demand(..), Demands(..) )
import FieldLabel	( mkFieldLabel, fieldLabelName, 
			  firstFieldLabelTag, allFieldLabelTags, fieldLabelType
			)
import DmdAnal		( dmdAnalTopRhs )
import CoreSyn
import Unique		( mkBuiltinUnique )
import Maybes
import PrelNames
import Maybe            ( isJust )
import Util             ( dropList, isSingleton )
import Outputable
import ListSetOps	( assoc, assocMaybe )
import UnicodeUtil      ( stringToUtf8 )
import List		( nubBy )
import Char             ( ord )
\end{code}		

%************************************************************************
%*									*
\subsection{Wired in Ids}
%*									*
%************************************************************************

\begin{code}
wiredInIds
  = [ 	-- These error-y things are wired in because we don't yet have
	-- a way to express in an interface file that the result type variable
	-- is 'open'; that is can be unified with an unboxed type
	-- 
	-- [The interface file format now carry such information, but there's
	-- no way yet of expressing at the definition site for these 
	-- error-reporting functions that they have an 'open' 
	-- result type. -- sof 1/99]

    rUNTIME_ERROR_ID,
    iRREFUT_PAT_ERROR_ID,
    nON_EXHAUSTIVE_GUARDS_ERROR_ID,
    nO_METHOD_BINDING_ERROR_ID,
    pAT_ERROR_ID,
    rEC_CON_ERROR_ID
    ] ++ ghcPrimIds

-- These Ids are exported from GHC.Prim
ghcPrimIds
  = [ 	-- These can't be defined in Haskell, but they have
	-- perfectly reasonable unfoldings in Core
    realWorldPrimId,
    unsafeCoerceId,
    nullAddrId,
    getTagId,
    seqId
    ]
\end{code}

%************************************************************************
%*									*
\subsection{Data constructors}
%*									*
%************************************************************************

\begin{code}
mkDataConId :: Name -> DataCon -> Id
	-- Makes the *worker* for the data constructor; that is, the function
	-- that takes the reprsentation arguments and builds the constructor.
mkDataConId work_name data_con
  = mkGlobalId (DataConId data_con) work_name (dataConRepType data_con) info
  where
    info = noCafNoTyGenIdInfo
	   `setArityInfo`		arity
	   `setAllStrictnessInfo`	Just strict_sig

    arity      = dataConRepArity data_con

    strict_sig = mkStrictSig (mkTopDmdType (replicate arity topDmd) cpr_info)
	-- Notice that we do *not* say the worker is strict
	-- even if the data constructor is declared strict
	--	e.g. 	data T = MkT !(Int,Int)
	-- Why?  Because the *wrapper* is strict (and its unfolding has case
	-- expresssions that do the evals) but the *worker* itself is not.
	-- If we pretend it is strict then when we see
	--	case x of y -> $wMkT y
	-- the simplifier thinks that y is "sure to be evaluated" (because
	-- $wMkT is strict) and drops the case.  No, $wMkT is not strict.
	--
	-- When the simplifer sees a pattern 
	--	case e of MkT x -> ...
	-- it uses the dataConRepStrictness of MkT to mark x as evaluated;
	-- but that's fine... dataConRepStrictness comes from the data con
	-- not from the worker Id.

    tycon = dataConTyCon data_con
    cpr_info | isProductTyCon tycon && 
	       isDataTyCon tycon    &&
	       arity > 0 	    &&
	       arity <= mAX_CPR_SIZE	= retCPR
	     | otherwise 		= TopRes
	-- RetCPR is only true for products that are real data types;
	-- that is, not unboxed tuples or [non-recursive] newtypes

mAX_CPR_SIZE :: Arity
mAX_CPR_SIZE = 10
-- We do not treat very big tuples as CPR-ish:
--	a) for a start we get into trouble because there aren't 
--	   "enough" unboxed tuple types (a tiresome restriction, 
--	   but hard to fix), 
--	b) more importantly, big unboxed tuples get returned mainly
--	   on the stack, and are often then allocated in the heap
--	   by the caller.  So doing CPR for them may in fact make
--	   things worse.
\end{code}

The wrapper for a constructor is an ordinary top-level binding that evaluates
any strict args, unboxes any args that are going to be flattened, and calls
the worker.

We're going to build a constructor that looks like:

	data (Data a, C b) =>  T a b = T1 !a !Int b

	T1 = /\ a b -> 
	     \d1::Data a, d2::C b ->
	     \p q r -> case p of { p ->
		       case q of { q ->
		       Con T1 [a,b] [p,q,r]}}

Notice that

* d2 is thrown away --- a context in a data decl is used to make sure
  one *could* construct dictionaries at the site the constructor
  is used, but the dictionary isn't actually used.

* We have to check that we can construct Data dictionaries for
  the types a and Int.  Once we've done that we can throw d1 away too.

* We use (case p of q -> ...) to evaluate p, rather than "seq" because
  all that matters is that the arguments are evaluated.  "seq" is 
  very careful to preserve evaluation order, which we don't need
  to be here.

  You might think that we could simply give constructors some strictness
  info, like PrimOps, and let CoreToStg do the let-to-case transformation.
  But we don't do that because in the case of primops and functions strictness
  is a *property* not a *requirement*.  In the case of constructors we need to
  do something active to evaluate the argument.

  Making an explicit case expression allows the simplifier to eliminate
  it in the (common) case where the constructor arg is already evaluated.

\begin{code}
mkDataConWrapId data_con
  = mkGlobalId (DataConWrapId data_con) (dataConName data_con) wrap_ty info
  where
    work_id = dataConWorkId data_con

    info = noCafNoTyGenIdInfo
	   `setUnfoldingInfo`	wrap_unf
		-- The NoCaf-ness is set by noCafNoTyGenIdInfo
	   `setArityInfo`	arity
		-- It's important to specify the arity, so that partial
		-- applications are treated as values
	   `setAllStrictnessInfo` 	Just wrap_sig

    wrap_sig = mkStrictSig (mkTopDmdType arg_dmds res_info)
    res_info = strictSigResInfo (idNewStrictness work_id)
    arg_dmds = map mk_dmd strict_marks
    mk_dmd str | isMarkedStrict str = evalDmd
	       | otherwise	    = lazyDmd
	-- The Cpr info can be important inside INLINE rhss, where the
	-- wrapper constructor isn't inlined.
	-- And the argument strictness can be important too; we
	-- may not inline a contructor when it is partially applied.
	-- For example:
	--	data W = C !Int !Int !Int
	--	...(let w = C x in ...(w p q)...)...
	-- we want to see that w is strict in its two arguments

    wrap_unf | isNewTyCon tycon
	     = ASSERT( null ex_tyvars && null ex_dict_args && isSingleton orig_arg_tys )
		-- No existentials on a newtype, but it can have a context
		-- e.g. 	newtype Eq a => T a = MkT (...)
		mkTopUnfolding $ Note InlineMe $
		mkLams tyvars $ Lam id_arg1 $ 
		mkNewTypeBody tycon result_ty (Var id_arg1)

	     | not (any isMarkedStrict strict_marks)
	     = mkCompulsoryUnfolding (Var work_id)
			-- The common case.  Not only is this efficient,
			-- but it also ensures that the wrapper is replaced
			-- by the worker even when there are no args.
			-- 		f (:) x
			-- becomes 
			--		f $w: x
			-- This is really important in rule matching,
			-- (We could match on the wrappers,
			-- but that makes it less likely that rules will match
			-- when we bring bits of unfoldings together.)
		--
		-- NB:	because of this special case, (map (:) ys) turns into
		--	(map $w: ys).  The top-level defn for (:) is never used.
		--	This is somewhat of a bore, but I'm currently leaving it 
		--	as is, so that there still is a top level curried (:) for
		--	the interpreter to call.

	     | otherwise
	     = mkTopUnfolding $ Note InlineMe $
	       mkLams all_tyvars $ 
	       mkLams ex_dict_args $ mkLams id_args $
	       foldr mk_case con_app 
		     (zip (ex_dict_args++id_args) strict_marks) i3 []

    con_app i rep_ids = mkApps (Var work_id)
			       (map varToCoreExpr (all_tyvars ++ reverse rep_ids))

    (tyvars, _, ex_tyvars, ex_theta, orig_arg_tys, tycon) = dataConSig data_con
    all_tyvars   = tyvars ++ ex_tyvars

    ex_dict_tys  = mkPredTys ex_theta
    all_arg_tys  = ex_dict_tys ++ orig_arg_tys
    result_ty    = mkTyConApp tycon (mkTyVarTys tyvars)

    wrap_ty = mkForAllTys all_tyvars (mkFunTys all_arg_tys result_ty)
	-- We used to include the stupid theta in the wrapper's args
	-- but now we don't.  Instead the type checker just injects these
	-- extra constraints where necessary.

    mkLocals i tys = (zipWith mkTemplateLocal [i..i+n-1] tys, i+n)
		   where
		     n = length tys

    (ex_dict_args,i2)  = mkLocals 1  ex_dict_tys
    (id_args,i3)       = mkLocals i2 orig_arg_tys
    arity	       = i3-1
    (id_arg1:_)   = id_args		-- Used for newtype only

    strict_marks  = dataConStrictMarks data_con

    mk_case 
	   :: (Id, StrictnessMark)	-- Arg, strictness
	   -> (Int -> [Id] -> CoreExpr) -- Body
	   -> Int			-- Next rep arg id
	   -> [Id]			-- Rep args so far, reversed
	   -> CoreExpr
    mk_case (arg,strict) body i rep_args
  	  = case strict of
		NotMarkedStrict -> body i (arg:rep_args)
		MarkedStrict 
		   | isUnLiftedType (idType arg) -> body i (arg:rep_args)
		   | otherwise ->
			Case (Var arg) arg [(DEFAULT,[], body i (arg:rep_args))]

		MarkedUnboxed
		   -> case splitProductType "do_unbox" (idType arg) of
			   (tycon, tycon_args, con, tys) ->
				   Case (Var arg) arg [(DataAlt con, con_args,
					body i' (reverse con_args ++ rep_args))]
			      where 
				(con_args, i') = mkLocals i tys
\end{code}


%************************************************************************
%*									*
\subsection{Record selectors}
%*									*
%************************************************************************

We're going to build a record selector unfolding that looks like this:

	data T a b c = T1 { ..., op :: a, ...}
		     | T2 { ..., op :: a, ...}
		     | T3

	sel = /\ a b c -> \ d -> case d of
				    T1 ... x ... -> x
				    T2 ... x ... -> x
				    other	 -> error "..."

Similarly for newtypes

	newtype N a = MkN { unN :: a->a }

	unN :: N a -> a -> a
	unN n = coerce (a->a) n
	
We need to take a little care if the field has a polymorphic type:

	data R = R { f :: forall a. a->a }

Then we want

	f :: forall a. R -> a -> a
	f = /\ a \ r = case r of
			  R f -> f a

(not f :: R -> forall a. a->a, which gives the type inference mechanism 
problems at call sites)

Similarly for newtypes

	newtype N = MkN { unN :: forall a. a->a }

	unN :: forall a. N -> a -> a
	unN = /\a -> \n:N -> coerce (a->a) n

\begin{code}
mkRecordSelId tycon field_label
	-- Assumes that all fields with the same field label have the same type
	--
	-- Annoyingly, we have to pass in the unpackCString# Id, because
	-- we can't conjure it up out of thin air
  = sel_id
  where
    sel_id     = mkGlobalId (RecordSelId field_label) (fieldLabelName field_label) selector_ty info
    field_ty   = fieldLabelType field_label
    data_cons  = tyConDataCons tycon
    tyvars     = tyConTyVars tycon	-- These scope over the types in 
					-- the FieldLabels of constructors of this type
    data_ty   = mkTyConApp tycon tyvar_tys
    tyvar_tys = mkTyVarTys tyvars

	-- Very tiresomely, the selectors are (unnecessarily!) overloaded over
	-- just the dictionaries in the types of the constructors that contain
	-- the relevant field.  [The Report says that pattern matching on a
	-- constructor gives the same constraints as applying it.]  Urgh.  
	--
	-- However, not all data cons have all constraints (because of
	-- TcTyDecls.thinContext).  So we need to find all the data cons 
	-- involved in the pattern match and take the union of their constraints.
	--
	-- NB: this code relies on the fact that DataCons are quantified over
	-- the identical type variables as their parent TyCon
    tycon_theta	 = tyConTheta tycon	-- The context on the data decl
					--   eg data (Eq a, Ord b) => T a b = ...
    needed_preds = [pred | (DataAlt dc, _, _) <- the_alts, pred <- dataConTheta dc]
    dict_tys     = map mkPredTy (nubBy tcEqPred needed_preds)
    n_dict_tys   = length dict_tys

    (field_tyvars,field_theta,field_tau) = tcSplitSigmaTy field_ty
    field_dict_tys			 = map mkPredTy field_theta
    n_field_dict_tys			 = length field_dict_tys
	-- If the field has a universally quantified type we have to 
	-- be a bit careful.  Suppose we have
	--	data R = R { op :: forall a. Foo a => a -> a }
	-- Then we can't give op the type
	--	op :: R -> forall a. Foo a => a -> a
	-- because the typechecker doesn't understand foralls to the
	-- right of an arrow.  The "right" type to give it is
	--	op :: forall a. Foo a => R -> a -> a
	-- But then we must generate the right unfolding too:
	--	op = /\a -> \dfoo -> \ r ->
	--	     case r of
	--		R op -> op a dfoo
	-- Note that this is exactly the type we'd infer from a user defn
	--	op (R op) = op

    selector_ty :: Type
    selector_ty  = mkForAllTys tyvars $ mkForAllTys field_tyvars $
		   mkFunTys dict_tys  $  mkFunTys field_dict_tys $
		   mkFunTy data_ty field_tau
      
    arity = 1 + n_dict_tys + n_field_dict_tys

    (strict_sig, rhs_w_str) = dmdAnalTopRhs sel_rhs
	-- Use the demand analyser to work out strictness.
	-- With all this unpackery it's not easy!

    info = noCafNoTyGenIdInfo
	   `setCafInfo`		  caf_info
	   `setArityInfo`	  arity
	   `setUnfoldingInfo`     mkTopUnfolding rhs_w_str
	   `setAllStrictnessInfo` Just strict_sig

	-- Allocate Ids.  We do it a funny way round because field_dict_tys is
	-- almost always empty.  Also note that we use length_tycon_theta
 	-- rather than n_dict_tys, because the latter gives an infinite loop:
	-- n_dict tys depends on the_alts, which depens on arg_ids, which depends
	-- on arity, which depends on n_dict tys.  Sigh!  Mega sigh!
    field_dict_base    = length tycon_theta + 1
    dict_id_base       = field_dict_base + n_field_dict_tys
    field_base	       = dict_id_base + 1
    dict_ids	       = mkTemplateLocalsNum  1		      dict_tys
    field_dict_ids     = mkTemplateLocalsNum  field_dict_base field_dict_tys
    data_id	       = mkTemplateLocal      dict_id_base    data_ty

    alts      = map mk_maybe_alt data_cons
    the_alts  = catMaybes alts

    no_default = all isJust alts	-- No default needed
    default_alt | no_default = []
		| otherwise  = [(DEFAULT, [], error_expr)]

	-- the default branch may have CAF refs, because it calls recSelError etc.
    caf_info    | no_default = NoCafRefs
	        | otherwise  = MayHaveCafRefs

    sel_rhs = mkLams tyvars   $ mkLams field_tyvars $ 
	      mkLams dict_ids $ mkLams field_dict_ids $
	      Lam data_id     $ sel_body

    sel_body | isNewTyCon tycon = mkNewTypeBody tycon field_tau (mk_result data_id)
	     | otherwise	= Case (Var data_id) data_id (default_alt ++ the_alts)

    mk_result result_id = mkVarApps (mkVarApps (Var result_id) field_tyvars) field_dict_ids
	-- We pull the field lambdas to the top, so we need to 
	-- apply them in the body.  For example:
	--	data T = MkT { foo :: forall a. a->a }
	--
	--	foo :: forall a. T -> a -> a
	--	foo = /\a. \t:T. case t of { MkT f -> f a }

    mk_maybe_alt data_con 
	= case maybe_the_arg_id of
		Nothing		-> Nothing
		Just the_arg_id -> Just (mkReboxingAlt uniqs data_con arg_ids body)
				where
			    	   body = mk_result the_arg_id
	where
            arg_ids = mkTemplateLocalsNum field_base (dataConOrigArgTys data_con)
			-- No need to instantiate; same tyvars in datacon as tycon

	    unpack_base = field_base + length arg_ids
	    uniqs = map mkBuiltinUnique [unpack_base..]

				-- arity+1 avoids all shadowing
    	    maybe_the_arg_id  = assocMaybe (field_lbls `zip` arg_ids) field_label
    	    field_lbls	      = dataConFieldLabels data_con

    error_expr = mkRuntimeErrorApp rEC_SEL_ERROR_ID field_tau full_msg
    full_msg   = showSDoc (sep [text "No match in record selector", ppr sel_id]) 


-- (mkReboxingAlt us con xs rhs) basically constructs the case
-- alternative	(con, xs, rhs)
-- but it does the reboxing necessary to construct the *source* 
-- arguments, xs, from the representation arguments ys.
-- For example:
--	data T = MkT !(Int,Int) Bool
--
-- mkReboxingAlt MkT [x,b] r 
--	= (DataAlt MkT, [y::Int,z::Int,b], let x = (y,z) in r)
--
-- mkDataAlt should really be in DataCon, but it can't because
-- it manipulates CoreSyn.

mkReboxingAlt
  :: [Unique]			-- Uniques for the new Ids
  -> DataCon
  -> [Var]			-- Source-level args
  -> CoreExpr			-- RHS
  -> CoreAlt

mkReboxingAlt us con args rhs
  | not (any isMarkedUnboxed stricts)
  = (DataAlt con, args, rhs)

  | otherwise
  = let
	(binds, args') = go args stricts us
    in
    (DataAlt con, args', mkLets binds rhs)

  where
    stricts = dataConStrictMarks con

    go [] stricts us = ([], [])

	-- Type variable case
    go (arg:args) stricts us 
      | isTyVar arg
      = let (binds, args') = go args stricts us
	in  (binds, arg:args')

	-- Term variable case
    go (arg:args) (str:stricts) us
      | isMarkedUnboxed str
      = let
	  (_, tycon_args, pack_con, con_arg_tys)
	 	 = splitProductType "mkReboxingAlt" (idType arg)

	  unpacked_args  = zipWith (mkSysLocal FSLIT("rb")) us con_arg_tys
	  (binds, args') = go args stricts (dropList con_arg_tys us)
	  con_app	 = mkConApp pack_con (map Type tycon_args ++ map Var unpacked_args)
	in
	(NonRec arg con_app : binds, unpacked_args ++ args')

      | otherwise
      = let (binds, args') = go args stricts us
        in  (binds, arg:args')
\end{code}


%************************************************************************
%*									*
\subsection{Dictionary selectors}
%*									*
%************************************************************************

Selecting a field for a dictionary.  If there is just one field, then
there's nothing to do.  

ToDo: unify with mkRecordSelId.

\begin{code}
mkDictSelId :: Name -> Class -> Id
mkDictSelId name clas
  = mkGlobalId (RecordSelId field_lbl) name sel_ty info
  where
    sel_ty = mkForAllTys tyvars (mkFunTy (idType dict_id) (idType the_arg_id))
	-- We can't just say (exprType rhs), because that would give a type
	--	C a -> C a
	-- for a single-op class (after all, the selector is the identity)
	-- But it's type must expose the representation of the dictionary
	-- to gat (say)		C a -> (a -> a)

    field_lbl = mkFieldLabel name tycon sel_ty tag
    tag       = assoc "MkId.mkDictSelId" (map idName (classSelIds clas) `zip` allFieldLabelTags) name

    info      = noCafNoTyGenIdInfo
		`setArityInfo`	    	1
		`setUnfoldingInfo`  	mkTopUnfolding rhs
		`setAllStrictnessInfo`	Just strict_sig

	-- We no longer use 'must-inline' on record selectors.  They'll
	-- inline like crazy if they scrutinise a constructor

	-- The strictness signature is of the form U(AAAVAAAA) -> T
 	-- where the V depends on which item we are selecting
	-- It's worth giving one, so that absence info etc is generated
	-- even if the selector isn't inlined
    strict_sig = mkStrictSig (mkTopDmdType [arg_dmd] TopRes)
    arg_dmd | isNewTyCon tycon = evalDmd
	    | otherwise	       = Eval (Prod [ if the_arg_id == id then evalDmd else Abs
					    | id <- arg_ids ])

    tyvars  = classTyVars clas

    tycon      = classTyCon clas
    [data_con] = tyConDataCons tycon
    tyvar_tys  = mkTyVarTys tyvars
    arg_tys    = dataConArgTys data_con tyvar_tys
    the_arg_id = arg_ids !! (tag - firstFieldLabelTag)

    pred	      = mkClassPred clas tyvar_tys
    (dict_id:arg_ids) = mkTemplateLocals (mkPredTy pred : arg_tys)

    rhs | isNewTyCon tycon = mkLams tyvars $ Lam dict_id $ 
			     mkNewTypeBody tycon (head arg_tys) (Var dict_id)
	| otherwise	   = mkLams tyvars $ Lam dict_id $
			     Case (Var dict_id) dict_id
			     	  [(DataAlt data_con, arg_ids, Var the_arg_id)]

mkNewTypeBody tycon result_ty result_expr
	-- Adds a coerce where necessary
	-- Used for both wrapping and unwrapping
  | isRecursiveTyCon tycon	-- Recursive case; use a coerce
  = Note (Coerce result_ty (exprType result_expr)) result_expr
  | otherwise			-- Normal case
  = result_expr
\end{code}


%************************************************************************
%*									*
\subsection{Primitive operations
%*									*
%************************************************************************

\begin{code}
mkPrimOpId :: PrimOp -> Id
mkPrimOpId prim_op 
  = id
  where
    (tyvars,arg_tys,res_ty, arity, strict_sig) = primOpSig prim_op
    ty   = mkForAllTys tyvars (mkFunTys arg_tys res_ty)
    name = mkPrimOpIdName prim_op
    id   = mkGlobalId (PrimOpId prim_op) name ty info
		
    info = noCafNoTyGenIdInfo
	   `setSpecInfo`	rules
	   `setArityInfo` 	arity
	   `setAllStrictnessInfo` Just strict_sig

    rules = foldl (addRule id) emptyCoreRules (primOpRules prim_op)


-- For each ccall we manufacture a separate CCallOpId, giving it
-- a fresh unique, a type that is correct for this particular ccall,
-- and a CCall structure that gives the correct details about calling
-- convention etc.  
--
-- The *name* of this Id is a local name whose OccName gives the full
-- details of the ccall, type and all.  This means that the interface 
-- file reader can reconstruct a suitable Id

mkFCallId :: Unique -> ForeignCall -> Type -> Id
mkFCallId uniq fcall ty
  = ASSERT( isEmptyVarSet (tyVarsOfType ty) )
	-- A CCallOpId should have no free type variables; 
	-- when doing substitutions won't substitute over it
    mkGlobalId (FCallId fcall) name ty info
  where
    occ_str = showSDoc (braces (ppr fcall <+> ppr ty))
	-- The "occurrence name" of a ccall is the full info about the
	-- ccall; it is encoded, but may have embedded spaces etc!

    name = mkFCallName uniq occ_str

    info = noCafNoTyGenIdInfo
	   `setArityInfo` 		arity
	   `setAllStrictnessInfo`	Just strict_sig

    (_, tau) 	 = tcSplitForAllTys ty
    (arg_tys, _) = tcSplitFunTys tau
    arity	 = length arg_tys
    strict_sig   = mkStrictSig (mkTopDmdType (replicate arity evalDmd) TopRes)
\end{code}


%************************************************************************
%*									*
\subsection{DictFuns and default methods}
%*									*
%************************************************************************

Important notes about dict funs and default methods
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Dict funs and default methods are *not* ImplicitIds.  Their definition
involves user-written code, so we can't figure out their strictness etc
based on fixed info, as we can for constructors and record selectors (say).

We build them as GlobalIds, but when in the module where they are
bound, we turn the Id at the *binding site* into an exported LocalId.
This ensures that they are taken to account by free-variable finding
and dependency analysis (e.g. CoreFVs.exprFreeVars).   The simplifier
will propagate the LocalId to all occurrence sites. 

Why shouldn't they be bound as GlobalIds?  Because, in particular, if
they are globals, the specialiser floats dict uses above their defns,
which prevents good simplifications happening.  Also the strictness
analyser treats a occurrence of a GlobalId as imported and assumes it
contains strictness in its IdInfo, which isn't true if the thing is
bound in the same module as the occurrence.

It's OK for dfuns to be LocalIds, because we form the instance-env to
pass on to the next module (md_insts) in CoreTidy, afer tidying
and globalising the top-level Ids.

BUT make sure they are *exported* LocalIds (setIdLocalExported) so 
that they aren't discarded by the occurrence analyser.

\begin{code}
mkDefaultMethodId dm_name ty = mkVanillaGlobal dm_name ty noCafNoTyGenIdInfo

mkDictFunId :: Name		-- Name to use for the dict fun;
	    -> Class 
	    -> [TyVar]
	    -> [Type]
	    -> ThetaType
	    -> Id

mkDictFunId dfun_name clas inst_tyvars inst_tys dfun_theta
  = mkVanillaGlobal dfun_name dfun_ty noCafNoTyGenIdInfo
  where
    dfun_ty = mkSigmaTy inst_tyvars dfun_theta (mkDictTy clas inst_tys)

{-  1 dec 99: disable the Mark Jones optimisation for the sake
    of compatibility with Hugs.
    See `types/InstEnv' for a discussion related to this.

    (class_tyvars, sc_theta, _, _) = classBigSig clas
    not_const (clas, tys) = not (isEmptyVarSet (tyVarsOfTypes tys))
    sc_theta' = substClasses (mkTopTyVarSubst class_tyvars inst_tys) sc_theta
    dfun_theta = case inst_decl_theta of
		   []    -> []	-- If inst_decl_theta is empty, then we don't
				-- want to have any dict arguments, so that we can
				-- expose the constant methods.

		   other -> nub (inst_decl_theta ++ filter not_const sc_theta')
				-- Otherwise we pass the superclass dictionaries to
				-- the dictionary function; the Mark Jones optimisation.
				--
				-- NOTE the "nub".  I got caught by this one:
				--   class Monad m => MonadT t m where ...
				--   instance Monad m => MonadT (EnvT env) m where ...
				-- Here, the inst_decl_theta has (Monad m); but so
				-- does the sc_theta'!
				--
				-- NOTE the "not_const".  I got caught by this one too:
				--   class Foo a => Baz a b where ...
				--   instance Wob b => Baz T b where..
				-- Now sc_theta' has Foo T
-}
\end{code}


%************************************************************************
%*									*
\subsection{Un-definable}
%*									*
%************************************************************************

These Ids can't be defined in Haskell.  They could be defined in
unfoldings in the wired-in GHC.Prim interface file, but we'd have to
ensure that they were definitely, definitely inlined, because there is
no curried identifier for them.  That's what mkCompulsoryUnfolding
does.  If we had a way to get a compulsory unfolding from an interface
file, we could do that, but we don't right now.

unsafeCoerce# isn't so much a PrimOp as a phantom identifier, that
just gets expanded into a type coercion wherever it occurs.  Hence we
add it as a built-in Id with an unfolding here.

The type variables we use here are "open" type variables: this means
they can unify with both unlifted and lifted types.  Hence we provide
another gun with which to shoot yourself in the foot.

\begin{code}
-- unsafeCoerce# :: forall a b. a -> b
unsafeCoerceId
  = pcMiscPrelId unsafeCoerceIdKey gHC_PRIM FSLIT("unsafeCoerce#") ty info
  where
    info = noCafNoTyGenIdInfo `setUnfoldingInfo` mkCompulsoryUnfolding rhs
	   

    ty  = mkForAllTys [openAlphaTyVar,openBetaTyVar]
		      (mkFunTy openAlphaTy openBetaTy)
    [x] = mkTemplateLocals [openAlphaTy]
    rhs = mkLams [openAlphaTyVar,openBetaTyVar,x] $
	  Note (Coerce openBetaTy openAlphaTy) (Var x)

-- nullAddr# :: Addr#
-- The reason is is here is because we don't provide 
-- a way to write this literal in Haskell.
nullAddrId 
  = pcMiscPrelId nullAddrIdKey gHC_PRIM FSLIT("nullAddr#") addrPrimTy info
  where
    info = noCafNoTyGenIdInfo `setUnfoldingInfo` 
	   mkCompulsoryUnfolding (Lit nullAddrLit)

seqId
  = pcMiscPrelId seqIdKey gHC_PRIM FSLIT("seq") ty info
  where
    info = noCafNoTyGenIdInfo `setUnfoldingInfo` mkCompulsoryUnfolding rhs
	   

    ty  = mkForAllTys [alphaTyVar,betaTyVar]
		      (mkFunTy alphaTy (mkFunTy betaTy betaTy))
    [x,y] = mkTemplateLocals [alphaTy, betaTy]
    rhs = mkLams [alphaTyVar,betaTyVar,x,y] (Case (Var x) x [(DEFAULT, [], Var y)])
\end{code}

@getTag#@ is another function which can't be defined in Haskell.  It needs to
evaluate its argument and call the dataToTag# primitive.

\begin{code}
getTagId
  = pcMiscPrelId getTagIdKey gHC_PRIM FSLIT("getTag#") ty info
  where
    info = noCafNoTyGenIdInfo `setUnfoldingInfo` mkCompulsoryUnfolding rhs
	-- We don't provide a defn for this; you must inline it

    ty = mkForAllTys [alphaTyVar] (mkFunTy alphaTy intPrimTy)
    [x,y] = mkTemplateLocals [alphaTy,alphaTy]
    rhs = mkLams [alphaTyVar,x] $
	  Case (Var x) y [ (DEFAULT, [], mkApps (Var dataToTagId) [Type alphaTy, Var y]) ]

dataToTagId = mkPrimOpId DataToTagOp
\end{code}

@realWorld#@ used to be a magic literal, \tr{void#}.  If things get
nasty as-is, change it back to a literal (@Literal@).

voidArgId is a Local Id used simply as an argument in functions
where we just want an arg to avoid having a thunk of unlifted type.
E.g.
	x = \ void :: State# RealWorld -> (# p, q #)

This comes up in strictness analysis

\begin{code}
realWorldPrimId	-- :: State# RealWorld
  = pcMiscPrelId realWorldPrimIdKey gHC_PRIM FSLIT("realWorld#")
		 realWorldStatePrimTy
		 (noCafNoTyGenIdInfo `setUnfoldingInfo` mkOtherCon [])
	-- The mkOtherCon makes it look that realWorld# is evaluated
	-- which in turn makes Simplify.interestingArg return True,
	-- which in turn makes INLINE things applied to realWorld# likely
	-- to be inlined

voidArgId 	-- :: State# RealWorld
  = mkSysLocal FSLIT("void") voidArgIdKey realWorldStatePrimTy
\end{code}


%************************************************************************
%*									*
\subsection[PrelVals-error-related]{@error@ and friends; @trace@}
%*									*
%************************************************************************

GHC randomly injects these into the code.

@patError@ is just a version of @error@ for pattern-matching
failures.  It knows various ``codes'' which expand to longer
strings---this saves space!

@absentErr@ is a thing we put in for ``absent'' arguments.  They jolly
well shouldn't be yanked on, but if one is, then you will get a
friendly message from @absentErr@ (rather than a totally random
crash).

@parError@ is a special version of @error@ which the compiler does
not know to be a bottoming Id.  It is used in the @_par_@ and @_seq_@
templates, but we don't ever expect to generate code for it.

\begin{code}
mkRuntimeErrorApp 
	:: Id 		-- Should be of type (forall a. Addr# -> a)
			-- 	where Addr# points to a UTF8 encoded string
	-> Type 	-- The type to instantiate 'a'
	-> String	-- The string to print
	-> CoreExpr

mkRuntimeErrorApp err_id res_ty err_msg 
  = mkApps (Var err_id) [Type res_ty, err_string]
  where
    err_string = Lit (MachStr (_PK_ (stringToUtf8 err_msg)))

rEC_SEL_ERROR_ID		= mkRuntimeErrorId recSelErrIdKey 	    	 FSLIT("recSelError")
rUNTIME_ERROR_ID	 	= mkRuntimeErrorId runtimeErrorIdKey 	    	 FSLIT("runtimeError")

iRREFUT_PAT_ERROR_ID		= mkRuntimeErrorId irrefutPatErrorIdKey	         FSLIT("irrefutPatError")
rEC_CON_ERROR_ID		= mkRuntimeErrorId recConErrorIdKey    		 FSLIT("recConError")
nON_EXHAUSTIVE_GUARDS_ERROR_ID	= mkRuntimeErrorId nonExhaustiveGuardsErrorIdKey FSLIT("nonExhaustiveGuardsError")
pAT_ERROR_ID			= mkRuntimeErrorId patErrorIdKey		 FSLIT("patError")
nO_METHOD_BINDING_ERROR_ID      = mkRuntimeErrorId noMethodBindingErrorIdKey	 FSLIT("noMethodBindingError")

-- The runtime error Ids take a UTF8-encoded string as argument
mkRuntimeErrorId key name = pc_bottoming_Id key pREL_ERR name runtimeErrorTy
runtimeErrorTy 		  = mkSigmaTy [openAlphaTyVar] [] (mkFunTy addrPrimTy openAlphaTy)
\end{code}


%************************************************************************
%*									*
\subsection{Utilities}
%*									*
%************************************************************************

\begin{code}
pcMiscPrelId :: Unique{-IdKey-} -> Module -> FAST_STRING -> Type -> IdInfo -> Id
pcMiscPrelId key mod str ty info
  = let
	name = mkWiredInName mod (mkVarOcc str) key
	imp  = mkVanillaGlobal name ty info -- the usual case...
    in
    imp
    -- We lie and say the thing is imported; otherwise, we get into
    -- a mess with dependency analysis; e.g., core2stg may heave in
    -- random calls to GHCbase.unpackPS__.  If GHCbase is the module
    -- being compiled, then it's just a matter of luck if the definition
    -- will be in "the right place" to be in scope.

pc_bottoming_Id key mod name ty
 = pcMiscPrelId key mod name ty bottoming_info
 where
    strict_sig	   = mkStrictSig (mkTopDmdType [evalDmd] BotRes)
    bottoming_info = noCafNoTyGenIdInfo `setAllStrictnessInfo` Just strict_sig
	-- these "bottom" out, no matter what their arguments

generic_ERROR_ID u n = pc_bottoming_Id u pREL_ERR n errorTy

(openAlphaTyVar:openBetaTyVar:_) = openAlphaTyVars
openAlphaTy  = mkTyVarTy openAlphaTyVar
openBetaTy   = mkTyVarTy openBetaTyVar

errorTy  :: Type
errorTy  = mkSigmaTy [openAlphaTyVar] [] (mkFunTys [mkListTy charTy] 
                                                   openAlphaTy)
    -- Notice the openAlphaTyVar.  It says that "error" can be applied
    -- to unboxed as well as boxed types.  This is OK because it never
    -- returns, so the return type is irrelevant.
\end{code}

