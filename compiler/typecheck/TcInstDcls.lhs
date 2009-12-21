%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

TcInstDecls: Typechecking instance declarations

\begin{code}
module TcInstDcls ( tcInstDecls1, tcInstDecls2 ) where

import HsSyn
import TcBinds
import TcTyClsDecls
import TcClassDcl
import TcRnMonad
import TcMType
import TcType
import Inst
import InstEnv
import FamInst
import FamInstEnv
import TcDeriv
import TcEnv
import RnEnv	( lookupGlobalOccRn )
import RnSource ( addTcgDUs )
import TcHsType
import TcUnify
import TcSimplify
import Type
import Coercion
import TyCon
import DataCon
import Class
import Var
import CoreUnfold ( mkDFunUnfolding )
import CoreUtils  ( mkPiTypes )
import PrelNames  ( inlineIdName )
import Id
import MkId
import Name
import NameSet
import DynFlags
import SrcLoc
import Util
import Outputable
import Bag
import BasicTypes
import HscTypes
import FastString

import Data.Maybe
import Control.Monad
import Data.List

#include "HsVersions.h"
\end{code}

Typechecking instance declarations is done in two passes. The first
pass, made by @tcInstDecls1@, collects information to be used in the
second pass.

This pre-processed info includes the as-yet-unprocessed bindings
inside the instance declaration.  These are type-checked in the second
pass, when the class-instance envs and GVE contain all the info from
all the instance and value decls.  Indeed that's the reason we need
two passes over the instance decls.


Note [How instance declarations are translated]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Here is how we translation instance declarations into Core

Running example:
	class C a where
	   op1, op2 :: Ix b => a -> b -> b
	   op2 = <dm-rhs>

	instance C a => C [a]
	   {-# INLINE [2] op1 #-}
	   op1 = <rhs>
===>
	-- Method selectors
	op1,op2 :: forall a. C a => forall b. Ix b => a -> b -> b
	op1 = ...
	op2 = ...

	-- Default methods get the 'self' dictionary as argument
	-- so they can call other methods at the same type
	-- Default methods get the same type as their method selector
	$dmop2 :: forall a. C a => forall b. Ix b => a -> b -> b
	$dmop2 = /\a. \(d:C a). /\b. \(d2: Ix b). <dm-rhs>
	       -- NB: type variables 'a' and 'b' are *both* in scope in <dm-rhs>
	       -- Note [Tricky type variable scoping]

	-- A top-level definition for each instance method
	-- Here op1_i, op2_i are the "instance method Ids"
	-- The INLINE pragma comes from the user pragma
	{-# INLINE [2] op1_i #-}  -- From the instance decl bindings
	op1_i, op2_i :: forall a. C a => forall b. Ix b => [a] -> b -> b
	op1_i = /\a. \(d:C a). 
	       let this :: C [a]
		   this = df_i a d
	             -- Note [Subtle interaction of recursion and overlap]

		   local_op1 :: forall b. Ix b => [a] -> b -> b
	           local_op1 = <rhs>
	       	     -- Source code; run the type checker on this
		     -- NB: Type variable 'a' (but not 'b') is in scope in <rhs>
		     -- Note [Tricky type variable scoping]

	       in local_op1 a d

	op2_i = /\a \d:C a. $dmop2 [a] (df_i a d) 

	-- The dictionary function itself
	{-# NOINLINE CONLIKE df_i #-}	-- Never inline dictionary functions
	df_i :: forall a. C a -> C [a]
	df_i = /\a. \d:C a. MkC (op1_i a d) (op2_i a d)
		-- But see Note [Default methods in instances]
		-- We can't apply the type checker to the default-method call

        -- Use a RULE to short-circuit applications of the class ops
	{-# RULE "op1@C[a]" forall a, d:C a. 
                            op1 [a] (df_i d) = op1_i a d #-}

Note [Instances and loop breakers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
* Note that df_i may be mutually recursive with both op1_i and op2_i.
  It's crucial that df_i is not chosen as the loop breaker, even 
  though op1_i has a (user-specified) INLINE pragma.

* Instead the idea is to inline df_i into op1_i, which may then select
  methods from the MkC record, and thereby break the recursion with
  df_i, leaving a *self*-recurisve op1_i.  (If op1_i doesn't call op at
  the same type, it won't mention df_i, so there won't be recursion in
  the first place.)  

* If op1_i is marked INLINE by the user there's a danger that we won't
  inline df_i in it, and that in turn means that (since it'll be a
  loop-breaker because df_i isn't), op1_i will ironically never be 
  inlined.  But this is OK: the recursion breaking happens by way of
  a RULE (the magic ClassOp rule above), and RULES work inside InlineRule
  unfoldings. See Note [RULEs enabled in SimplGently] in SimplUtils

Note [ClassOp/DFun selection]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
One thing we see a lot is stuff like
    op2 (df d1 d2)
where 'op2' is a ClassOp and 'df' is DFun.  Now, we could inline *both*
'op2' and 'df' to get
     case (MkD ($cop1 d1 d2) ($cop2 d1 d2) ... of
       MkD _ op2 _ _ _ -> op2
And that will reduce to ($cop2 d1 d2) which is what we wanted.

But it's tricky to make this work in practice, because it requires us to 
inline both 'op2' and 'df'.  But neither is keen to inline without having
seen the other's result; and it's very easy to get code bloat (from the 
big intermediate) if you inline a bit too much.

Instead we use a cunning trick.
 * We arrange that 'df' and 'op2' NEVER inline.  

 * We arrange that 'df' is ALWAYS defined in the sylised form
      df d1 d2 = MkD ($cop1 d1 d2) ($cop2 d1 d2) ...

 * We give 'df' a magical unfolding (DFunUnfolding [$cop1, $cop2, ..])
   that lists its methods.

 * We make CoreUnfold.exprIsConApp_maybe spot a DFunUnfolding and return
   a suitable constructor application -- inlining df "on the fly" as it 
   were.

 * We give the ClassOp 'op2' a BuiltinRule that extracts the right piece
   iff its argument satisfies exprIsConApp_maybe.  This is done in
   MkId mkDictSelId

 * We make 'df' CONLIKE, so that shared uses stil match; eg
      let d = df d1 d2
      in ...(op2 d)...(op1 d)...

Note [Single-method classes]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If the class has just one method (or, more accurately, just one elemen
of {superclasses + methods}), then we want a different strategy. 

   class C a where op :: a -> a
   instance C a => C [a] where op = <blah>

We translate the class decl into a newtype, which just gives
a top-level axiom:

   axiom Co:C a :: C a ~ (a->a)

   op :: forall a. C a -> (a -> a)
   op a d = d |> (Co:C a)

   df :: forall a. C a => C [a]
   {-# INLINE df #-}
   df = $cop_list |> (forall a. C a -> (sym (Co:C a))

   $cop_list :: forall a. C a => a -> a
   $cop_list = <blah>

So the ClassOp is just a cast; and so is the dictionary function.
(The latter doesn't even have any lambdas.)  We can inline both freely.
No need for fancy BuiltIn rules.  Indeed the BuiltinRule stuff does
not work well for newtypes because it uses exprIsConApp_maybe.

The INLINE on df is vital, else $cop_list occurs just once and is inlined,
which is a disaster if $cop_list *itself* has an INLINE pragma.

Notice, also, that we go to the trouble of generating a complicated cast,
rather than do this:
       df = /\a. \d. MkD ($cop_list a d)
where the MkD "constructor" willl expand to a suitable cast:
       df = /\a. \d. ($cop_list a d) |>  (...)
Reason: suppose $cop_list has an INLINE pragma.  We want to avoid the
nasty possibility that we eta-expand df, to get
       df = (/\a \d \x. $cop_list a d x) |> (...)
and now $cop_list may get inlined into the df, rather than at
the actual call site.  Of course, eta reduction may get there first,
but it seems less fragile to generate the Right Thing in the first place.
See Trac #3772.


Note [Subtle interaction of recursion and overlap]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this
  class C a where { op1,op2 :: a -> a }
  instance C a => C [a] where
    op1 x = op2 x ++ op2 x
    op2 x = ...
  intance C [Int] where
    ...

When type-checking the C [a] instance, we need a C [a] dictionary (for
the call of op2).  If we look up in the instance environment, we find
an overlap.  And in *general* the right thing is to complain (see Note
[Overlapping instances] in InstEnv).  But in *this* case it's wrong to
complain, because we just want to delegate to the op2 of this same
instance.  

Why is this justified?  Because we generate a (C [a]) constraint in 
a context in which 'a' cannot be instantiated to anything that matches
other overlapping instances, or else we would not be excecuting this
version of op1 in the first place.

It might even be a bit disguised:

  nullFail :: C [a] => [a] -> [a]
  nullFail x = op2 x ++ op2 x

  instance C a => C [a] where
    op1 x = nullFail x

Precisely this is used in package 'regex-base', module Context.hs.
See the overlapping instances for RegexContext, and the fact that they
call 'nullFail' just like the example above.  The DoCon package also
does the same thing; it shows up in module Fraction.hs

Conclusion: when typechecking the methods in a C [a] instance, we want
to have C [a] available.  That is why we have the strange local
definition for 'this' in the definition of op1_i in the example above.
We can typecheck the defintion of local_op1, and when doing tcSimplifyCheck
we supply 'this' as a given dictionary.  Only needed, though, if there
are some type variables involved; otherwise there can be no overlap and
none of this arises.

Note [Tricky type variable scoping]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In our example
	class C a where
	   op1, op2 :: Ix b => a -> b -> b
	   op2 = <dm-rhs>

	instance C a => C [a]
	   {-# INLINE [2] op1 #-}
	   op1 = <rhs>

note that 'a' and 'b' are *both* in scope in <dm-rhs>, but only 'a' is
in scope in <rhs>.  In particular, we must make sure that 'b' is in
scope when typechecking <dm-rhs>.  This is achieved by subFunTys,
which brings appropriate tyvars into scope. This happens for both
<dm-rhs> and for <rhs>, but that doesn't matter: the *renamer* will have
complained if 'b' is mentioned in <rhs>.



%************************************************************************
%*                                                                      *
\subsection{Extracting instance decls}
%*                                                                      *
%************************************************************************

Gather up the instance declarations from their various sources

\begin{code}
tcInstDecls1    -- Deal with both source-code and imported instance decls
   :: [LTyClDecl Name]          -- For deriving stuff
   -> [LInstDecl Name]          -- Source code instance decls
   -> [LDerivDecl Name]         -- Source code stand-alone deriving decls
   -> TcM (TcGblEnv,            -- The full inst env
           [InstInfo Name],     -- Source-code instance decls to process;
                                -- contains all dfuns for this module
           HsValBinds Name)     -- Supporting bindings for derived instances

tcInstDecls1 tycl_decls inst_decls deriv_decls
  = checkNoErrs $
    do {        -- Stop if addInstInfos etc discovers any errors
                -- (they recover, so that we get more than one error each
                -- round)

                -- (1) Do class and family instance declarations
       ; let { idxty_decls = filter (isFamInstDecl . unLoc) tycl_decls }
       ; local_info_tycons <- mapAndRecoverM tcLocalInstDecl1  inst_decls
       ; idx_tycons        <- mapAndRecoverM tcIdxTyInstDeclTL idxty_decls

       ; let { (local_info,
                at_tycons_s)   = unzip local_info_tycons
             ; at_idx_tycons   = concat at_tycons_s ++ idx_tycons
             ; clas_decls      = filter (isClassDecl.unLoc) tycl_decls
             ; implicit_things = concatMap implicitTyThings at_idx_tycons
	     ; aux_binds       = mkAuxBinds at_idx_tycons
             }

                -- (2) Add the tycons of indexed types and their implicit
                --     tythings to the global environment
       ; tcExtendGlobalEnv (at_idx_tycons ++ implicit_things) $ do {

                -- (3) Instances from generic class declarations
       ; generic_inst_info <- getGenericInstances clas_decls

                -- Next, construct the instance environment so far, consisting
                -- of
                --   a) local instance decls
                --   b) generic instances
                --   c) local family instance decls
       ; addInsts local_info         $
         addInsts generic_inst_info  $
         addFamInsts at_idx_tycons   $ do {

                -- (4) Compute instances from "deriving" clauses;
                -- This stuff computes a context for the derived instance
                -- decl, so it needs to know about all the instances possible
                -- NB: class instance declarations can contain derivings as
                --     part of associated data type declarations
	 failIfErrsM		-- If the addInsts stuff gave any errors, don't
				-- try the deriving stuff, becuase that may give
				-- more errors still
       ; (deriv_inst_info, deriv_binds, deriv_dus) 
              <- tcDeriving tycl_decls inst_decls deriv_decls
       ; gbl_env <- addInsts deriv_inst_info getGblEnv
       ; return ( addTcgDUs gbl_env deriv_dus,
                  generic_inst_info ++ deriv_inst_info ++ local_info,
                  aux_binds `plusHsValBinds` deriv_binds)
    }}}
  where
    -- Make sure that toplevel type instance are not for associated types.
    -- !!!TODO: Need to perform this check for the TyThing of type functions,
    --          too.
    tcIdxTyInstDeclTL ldecl@(L loc decl) =
      do { tything <- tcFamInstDecl ldecl
         ; setSrcSpan loc $
             when (isAssocFamily tything) $
               addErr $ assocInClassErr (tcdName decl)
         ; return tything
         }
    isAssocFamily (ATyCon tycon) =
      case tyConFamInst_maybe tycon of
        Nothing       -> panic "isAssocFamily: no family?!?"
        Just (fam, _) -> isTyConAssoc fam
    isAssocFamily _ = panic "isAssocFamily: no tycon?!?"

assocInClassErr :: Name -> SDoc
assocInClassErr name =
  ptext (sLit "Associated type") <+> quotes (ppr name) <+>
  ptext (sLit "must be inside a class instance")

addInsts :: [InstInfo Name] -> TcM a -> TcM a
addInsts infos thing_inside
  = tcExtendLocalInstEnv (map iSpec infos) thing_inside

addFamInsts :: [TyThing] -> TcM a -> TcM a
addFamInsts tycons thing_inside
  = tcExtendLocalFamInstEnv (map mkLocalFamInstTyThing tycons) thing_inside
  where
    mkLocalFamInstTyThing (ATyCon tycon) = mkLocalFamInst tycon
    mkLocalFamInstTyThing tything        = pprPanic "TcInstDcls.addFamInsts"
                                                    (ppr tything)
\end{code}

\begin{code}
tcLocalInstDecl1 :: LInstDecl Name
                 -> TcM (InstInfo Name, [TyThing])
        -- A source-file instance declaration
        -- Type-check all the stuff before the "where"
        --
        -- We check for respectable instance type, and context
tcLocalInstDecl1 (L loc (InstDecl poly_ty binds uprags ats))
  = setSrcSpan loc		        $
    addErrCtxt (instDeclCtxt1 poly_ty)  $

    do  { is_boot <- tcIsHsBoot
        ; checkTc (not is_boot || (isEmptyLHsBinds binds && null uprags))
                  badBootDeclErr

        ; (tyvars, theta, tau) <- tcHsInstHead poly_ty

        -- Now, check the validity of the instance.
        ; (clas, inst_tys) <- checkValidInstHead tau
        ; checkValidInstance tyvars theta clas inst_tys

        -- Next, process any associated types.
        ; idx_tycons <- recoverM (return []) $
	  	     do { idx_tycons <- checkNoErrs $ mapAndRecoverM tcFamInstDecl ats
		     	; checkValidAndMissingATs clas (tyvars, inst_tys)
                          			  (zip ats idx_tycons)
			; return idx_tycons }

        -- Finally, construct the Core representation of the instance.
        -- (This no longer includes the associated types.)
        ; dfun_name <- newDFunName clas inst_tys (getLoc poly_ty)
		-- Dfun location is that of instance *header*
        ; overlap_flag <- getOverlapFlag
        ; let (eq_theta,dict_theta) = partition isEqPred theta
              theta'         = eq_theta ++ dict_theta
              dfun           = mkDictFunId dfun_name tyvars theta' clas inst_tys
              ispec          = mkLocalInstance dfun overlap_flag

        ; return (InstInfo { iSpec  = ispec,
                             iBinds = VanillaInst binds uprags False },
                  idx_tycons)
        }
  where
    -- We pass in the source form and the type checked form of the ATs.  We
    -- really need the source form only to be able to produce more informative
    -- error messages.
    checkValidAndMissingATs :: Class
                            -> ([TyVar], [TcType])     -- instance types
                            -> [(LTyClDecl Name,       -- source form of AT
                                 TyThing)]    	       -- Core form of AT
                            -> TcM ()
    checkValidAndMissingATs clas inst_tys ats
      = do { -- Issue a warning for each class AT that is not defined in this
             -- instance.
           ; let class_ats   = map tyConName (classATs clas)
                 defined_ats = listToNameSet . map (tcdName.unLoc.fst)  $ ats
                 omitted     = filterOut (`elemNameSet` defined_ats) class_ats
           ; warn <- doptM Opt_WarnMissingMethods
           ; mapM_ (warnTc warn . omittedATWarn) omitted

             -- Ensure that all AT indexes that correspond to class parameters
             -- coincide with the types in the instance head.  All remaining
             -- AT arguments must be variables.  Also raise an error for any
             -- type instances that are not associated with this class.
           ; mapM_ (checkIndexes clas inst_tys) ats
           }

    checkIndexes clas inst_tys (hsAT, ATyCon tycon)
-- !!!TODO: check that this does the Right Thing for indexed synonyms, too!
      = checkIndexes' clas inst_tys hsAT
                      (tyConTyVars tycon,
                       snd . fromJust . tyConFamInst_maybe $ tycon)
    checkIndexes _ _ _ = panic "checkIndexes"

    checkIndexes' clas (instTvs, instTys) hsAT (atTvs, atTys)
      = let atName = tcdName . unLoc $ hsAT
        in
        setSrcSpan (getLoc hsAT)       $
        addErrCtxt (atInstCtxt atName) $
        case find ((atName ==) . tyConName) (classATs clas) of
          Nothing     -> addErrTc $ badATErr clas atName  -- not in this class
          Just atycon ->
            case assocTyConArgPoss_maybe atycon of
              Nothing   -> panic "checkIndexes': AT has no args poss?!?"
              Just poss ->

                -- The following is tricky!  We need to deal with three
                -- complications: (1) The AT possibly only uses a subset of
                -- the class parameters as indexes and those it uses may be in
                -- a different order; (2) the AT may have extra arguments,
                -- which must be type variables; and (3) variables in AT and
                -- instance head will be different `Name's even if their
                -- source lexemes are identical.
		--
		-- e.g.    class C a b c where 
		-- 	     data D b a :: * -> *           -- NB (1) b a, omits c
		-- 	   instance C [x] Bool Char where 
		--	     data D Bool [x] v = MkD x [v]  -- NB (2) v
		--	     	  -- NB (3) the x in 'instance C...' have differnt
		--		  --        Names to x's in 'data D...'
                --
                -- Re (1), `poss' contains a permutation vector to extract the
                -- class parameters in the right order.
                --
                -- Re (2), we wrap the (permuted) class parameters in a Maybe
                -- type and use Nothing for any extra AT arguments.  (First
                -- equation of `checkIndex' below.)
                --
                -- Re (3), we replace any type variable in the AT parameters
                -- that has the same source lexeme as some variable in the
                -- instance types with the instance type variable sharing its
                -- source lexeme.
                --
                let relevantInstTys = map (instTys !!) poss
                    instArgs        = map Just relevantInstTys ++
                                      repeat Nothing  -- extra arguments
                    renaming        = substSameTyVar atTvs instTvs
                in
                zipWithM_ checkIndex (substTys renaming atTys) instArgs

    checkIndex ty Nothing
      | isTyVarTy ty         = return ()
      | otherwise            = addErrTc $ mustBeVarArgErr ty
    checkIndex ty (Just instTy)
      | ty `tcEqType` instTy = return ()
      | otherwise            = addErrTc $ wrongATArgErr ty instTy

    listToNameSet = addListToNameSet emptyNameSet

    substSameTyVar []       _            = emptyTvSubst
    substSameTyVar (tv:tvs) replacingTvs =
      let replacement = case find (tv `sameLexeme`) replacingTvs of
                        Nothing  -> mkTyVarTy tv
                        Just rtv -> mkTyVarTy rtv
          --
          tv1 `sameLexeme` tv2 =
            nameOccName (tyVarName tv1) == nameOccName (tyVarName tv2)
      in
      extendTvSubst (substSameTyVar tvs replacingTvs) tv replacement
\end{code}


%************************************************************************
%*                                                                      *
      Type-checking instance declarations, pass 2
%*                                                                      *
%************************************************************************

\begin{code}
tcInstDecls2 :: [LTyClDecl Name] -> [InstInfo Name]
             -> TcM (LHsBinds Id, TcLclEnv)
-- (a) From each class declaration,
--      generate any default-method bindings
-- (b) From each instance decl
--      generate the dfun binding

tcInstDecls2 tycl_decls inst_decls
  = do  { -- (a) Default methods from class decls
          let class_decls = filter (isClassDecl . unLoc) tycl_decls
        ; (dm_ids_s, dm_binds_s) <- mapAndUnzipM tcClassDecl2 class_decls
                                    
	; tcExtendIdEnv (concat dm_ids_s) $ do 

          -- (b) instance declarations
        { inst_binds_s <- mapM tcInstDecl2 inst_decls

          -- Done
        ; let binds = unionManyBags dm_binds_s `unionBags`
                      unionManyBags inst_binds_s
        ; tcl_env <- getLclEnv -- Default method Ids in here
        ; return (binds, tcl_env) } }

tcInstDecl2 :: InstInfo Name -> TcM (LHsBinds Id)
tcInstDecl2 (InstInfo { iSpec = ispec, iBinds = ibinds })
  = recoverM (return emptyLHsBinds)             $
    setSrcSpan loc                              $
    addErrCtxt (instDeclCtxt2 (idType dfun_id)) $ 
    tc_inst_decl2 dfun_id ibinds
 where
    dfun_id = instanceDFunId ispec
    loc     = getSrcSpan dfun_id
\end{code}


\begin{code}
tc_inst_decl2 :: Id -> InstBindings Name -> TcM (LHsBinds Id)
-- Returns a binding for the dfun

------------------------
-- Derived newtype instances; surprisingly tricky!
--
--      class Show a => Foo a b where ...
--      newtype N a = MkN (Tree [a]) deriving( Foo Int )
--
-- The newtype gives an FC axiom looking like
--      axiom CoN a ::  N a ~ Tree [a]
--   (see Note [Newtype coercions] in TyCon for this unusual form of axiom)
--
-- So all need is to generate a binding looking like:
--      dfunFooT :: forall a. (Foo Int (Tree [a], Show (N a)) => Foo Int (N a)
--      dfunFooT = /\a. \(ds:Show (N a)) (df:Foo (Tree [a])).
--                case df `cast` (Foo Int (sym (CoN a))) of
--                   Foo _ op1 .. opn -> Foo ds op1 .. opn
--
-- If there are no superclasses, matters are simpler, because we don't need the case
-- see Note [Newtype deriving superclasses] in TcDeriv.lhs

tc_inst_decl2 dfun_id (NewTypeDerived coi)
  = do  { let rigid_info = InstSkol
              origin     = SigOrigin rigid_info
              inst_ty    = idType dfun_id
	      inst_tvs   = fst (tcSplitForAllTys inst_ty)
        ; (inst_tvs', theta, inst_head_ty) <- tcSkolSigType rigid_info inst_ty
                -- inst_head_ty is a PredType

        ; let (cls, cls_inst_tys) = tcSplitDFunHead inst_head_ty
              (class_tyvars, sc_theta, _, _) = classBigSig cls
              cls_tycon = classTyCon cls
              sc_theta' = substTheta (zipOpenTvSubst class_tyvars cls_inst_tys) sc_theta
              Just (initial_cls_inst_tys, last_ty) = snocView cls_inst_tys

              (rep_ty, wrapper) 
	         = case coi of
	      	     IdCo   -> (last_ty, idHsWrapper)
		     ACo co -> (snd (coercionKind co'), WpCast (mk_full_coercion co'))
			    where
			       co' = substTyWith inst_tvs (mkTyVarTys inst_tvs') co
				-- NB: the free variable of coi are bound by the
				-- universally quantified variables of the dfun_id
				-- This is weird, and maybe we should make NewTypeDerived
				-- carry a type-variable list too; but it works fine

		 -----------------------
		 --        mk_full_coercion
		 -- The inst_head looks like (C s1 .. sm (T a1 .. ak))
		 -- But we want the coercion (C s1 .. sm (sym (CoT a1 .. ak)))
		 --        with kind (C s1 .. sm (T a1 .. ak)  ~  C s1 .. sm <rep_ty>)
		 --        where rep_ty is the (eta-reduced) type rep of T
		 -- So we just replace T with CoT, and insert a 'sym'
		 -- NB: we know that k will be >= arity of CoT, because the latter fully eta-reduced

	      mk_full_coercion co = mkTyConApp cls_tycon 
	      		       	         (initial_cls_inst_tys ++ [mkSymCoercion co])
                 -- Full coercion : (Foo Int (Tree [a]) ~ Foo Int (N a)

              rep_pred = mkClassPred cls (initial_cls_inst_tys ++ [rep_ty])
                 -- In our example, rep_pred is (Foo Int (Tree [a]))

        ; sc_loc     <- getInstLoc InstScOrigin
        ; sc_dicts   <- newDictBndrs sc_loc sc_theta'
        ; inst_loc   <- getInstLoc origin
        ; dfun_dicts <- newDictBndrs inst_loc theta
        ; rep_dict   <- newDictBndr inst_loc rep_pred
        ; this_dict  <- newDictBndr inst_loc (mkClassPred cls cls_inst_tys)

        -- Figure out bindings for the superclass context from dfun_dicts
        -- Don't include this_dict in the 'givens', else
        -- sc_dicts get bound by just selecting from this_dict!!
        ; sc_binds <- addErrCtxt superClassCtxt $
                      tcSimplifySuperClasses inst_loc this_dict dfun_dicts 
					     (rep_dict:sc_dicts)

	-- It's possible that the superclass stuff might unified something
	-- in the envt with one of the clas_tyvars
	; checkSigTyVars inst_tvs'

        ; let coerced_rep_dict = wrapId wrapper (instToId rep_dict)

        ; body <- make_body cls_tycon cls_inst_tys sc_dicts coerced_rep_dict
	; let dict_bind = mkVarBind (instToId this_dict) (noLoc body)

        ; return (unitBag $ noLoc $
                  AbsBinds inst_tvs' (map instToVar dfun_dicts)
                            [(inst_tvs', dfun_id, instToId this_dict, [])]
                            (dict_bind `consBag` sc_binds)) }
  where
      -----------------------
      --     (make_body C tys scs coreced_rep_dict)
      --                returns
      --     (case coerced_rep_dict of { C _ ops -> C scs ops })
      -- But if there are no superclasses, it returns just coerced_rep_dict
      -- See Note [Newtype deriving superclasses] in TcDeriv.lhs

    make_body cls_tycon cls_inst_tys sc_dicts coerced_rep_dict
        | null sc_dicts         -- Case (a)
        = return coerced_rep_dict
        | otherwise             -- Case (b)
        = do { op_ids            <- newSysLocalIds (fsLit "op") op_tys
             ; dummy_sc_dict_ids <- newSysLocalIds (fsLit "sc") (map idType sc_dict_ids)
             ; let the_pat = ConPatOut { pat_con = noLoc cls_data_con, pat_tvs = [],
                                         pat_dicts = dummy_sc_dict_ids,
                                         pat_binds = emptyLHsBinds,
                                         pat_args = PrefixCon (map nlVarPat op_ids),
                                         pat_ty = pat_ty}
                   the_match = mkSimpleMatch [noLoc the_pat] the_rhs
                   the_rhs = mkHsConApp cls_data_con cls_inst_tys $
                             map HsVar (sc_dict_ids ++ op_ids)

                -- Warning: this HsCase scrutinises a value with a PredTy, which is
                --          never otherwise seen in Haskell source code. It'd be
                --          nicer to generate Core directly!
             ; return (HsCase (noLoc coerced_rep_dict) $
                       MatchGroup [the_match] (mkFunTy pat_ty pat_ty)) }
        where
          sc_dict_ids  = map instToId sc_dicts
          pat_ty       = mkTyConApp cls_tycon cls_inst_tys
          cls_data_con = head (tyConDataCons cls_tycon)
          cls_arg_tys  = dataConInstArgTys cls_data_con cls_inst_tys
          op_tys       = dropList sc_dict_ids cls_arg_tys

------------------------
-- Ordinary instances

tc_inst_decl2 dfun_id (VanillaInst monobinds uprags standalone_deriv)
  = do { let rigid_info = InstSkol
             inst_ty    = idType dfun_id
             loc        = getSrcSpan dfun_id

        -- Instantiate the instance decl with skolem constants
       ; (inst_tyvars', dfun_theta', inst_head') <- tcSkolSigType rigid_info inst_ty
                -- These inst_tyvars' scope over the 'where' part
                -- Those tyvars are inside the dfun_id's type, which is a bit
                -- bizarre, but OK so long as you realise it!
       ; let
            (clas, inst_tys') = tcSplitDFunHead inst_head'
            (class_tyvars, sc_theta, sc_sels, op_items) = classBigSig clas

             -- Instantiate the super-class context with inst_tys
            sc_theta' = substTheta (zipOpenTvSubst class_tyvars inst_tys') sc_theta
            origin    = SigOrigin rigid_info

         -- Create dictionary Ids from the specified instance contexts.
       ; inst_loc   <- getInstLoc origin
       ; dfun_dicts <- newDictBndrs inst_loc dfun_theta'	-- Includes equalities
       ; this_dict  <- newDictBndr inst_loc (mkClassPred clas inst_tys')
                -- Default-method Ids may be mentioned in synthesised RHSs,
                -- but they'll already be in the environment.

       
	-- Cook up a binding for "this = df d1 .. dn",
	-- to use in each method binding
	-- Need to clone the dict in case it is floated out, and
	-- then clashes with its friends
       ; cloned_this <- cloneDict this_dict
       ; let cloned_this_bind = mkVarBind (instToId cloned_this) $ 
		                L loc $ wrapId app_wrapper dfun_id
	     app_wrapper = mkWpApps dfun_lam_vars <.> mkWpTyApps (mkTyVarTys inst_tyvars')
	     dfun_lam_vars = map instToVar dfun_dicts	-- Includes equalities
	     nested_this_pair 
		| null inst_tyvars' && null dfun_theta' = (this_dict, emptyBag)
		| otherwise = (cloned_this, unitBag cloned_this_bind)

       -- Deal with 'SPECIALISE instance' pragmas
       -- See Note [SPECIALISE instance pragmas]
       ; let spec_inst_sigs = filter isSpecInstLSig uprags
       	     -- The filter removes the pragmas for methods
       ; spec_inst_prags <- mapM (wrapLocM (tcSpecInst dfun_id)) spec_inst_sigs

        -- Typecheck the methods
       ; let prag_fn = mkPragFun uprags 
             tc_meth = tcInstanceMethod loc standalone_deriv
                                        clas inst_tyvars'
	     	       	 		dfun_dicts inst_tys'
	     	     	 		nested_this_pair 
				 	prag_fn spec_inst_prags monobinds

       ; (meth_ids, meth_binds) <- tcExtendTyVarEnv inst_tyvars' $
			           mapAndUnzipM tc_meth op_items 

         -- Figure out bindings for the superclass context
       ; sc_loc   <- getInstLoc InstScOrigin
       ; sc_dicts <- newDictOccs sc_loc sc_theta'		-- These are wanted
       ; let tc_sc = tcSuperClass inst_loc inst_tyvars' dfun_dicts nested_this_pair
       ; (sc_ids, sc_binds) <- mapAndUnzipM tc_sc (sc_sels `zip` sc_dicts)

	-- It's possible that the superclass stuff might unified
	-- something in the envt with one of the inst_tyvars'
       ; checkSigTyVars inst_tyvars'

       -- Create the result bindings
       ; let this_dict_id  = instToId this_dict
             arg_ids       = sc_ids ++ meth_ids
             arg_binds     = listToBag meth_binds `unionBags` 
                             listToBag sc_binds

       ; showLIE (text "instance")
       ; case newTyConCo_maybe (classTyCon clas) of
           Nothing 	       -- A multi-method class
             -> return (unitBag (L loc data_bind)  `unionBags` arg_binds)
             where
               data_dfun_id = dfun_id   -- Do not inline; instead give it a magic DFunFunfolding
			     	       -- See Note [ClassOp/DFun selection]
                             	`setIdUnfolding`  mkDFunUnfolding dict_constr arg_ids
                             	`setInlinePragma` dfunInlinePragma

               data_bind = AbsBinds inst_tyvars' dfun_lam_vars
                             [(inst_tyvars', data_dfun_id, this_dict_id, spec_inst_prags)]
                             (unitBag dict_bind)

	       dict_bind   = mkVarBind this_dict_id dict_rhs
               dict_rhs    = foldl mk_app inst_constr arg_ids
               dict_constr = classDataCon clas
               inst_constr = L loc $ wrapId (mkWpTyApps inst_tys')
	       			            (dataConWrapId dict_constr)
                       -- We don't produce a binding for the dict_constr; instead we
                       -- rely on the simplifier to unfold this saturated application
                       -- We do this rather than generate an HsCon directly, because
                       -- it means that the special cases (e.g. dictionary with only one
                       -- member) are dealt with by the common MkId.mkDataConWrapId code rather
                       -- than needing to be repeated here.

	       mk_app :: LHsExpr Id -> Id -> LHsExpr Id
 	       mk_app fun arg_id = L loc (HsApp fun (L loc (wrapId arg_wrapper arg_id)))
	       arg_wrapper = mkWpApps dfun_lam_vars <.> mkWpTyApps (mkTyVarTys inst_tyvars')

           Just the_nt_co  	 -- (Just co) for a single-method class
             -> return (unitBag (L loc nt_bind) `unionBags` arg_binds)
             where
               nt_dfun_id = dfun_id   -- Just let the dfun inline; see Note [Single-method classes]
                            `setInlinePragma` alwaysInlinePragma

	       local_nt_dfun = setIdType this_dict_id inst_ty	-- A bit of a hack, but convenient

	       nt_bind = AbsBinds [] [] 
                            [([], nt_dfun_id, local_nt_dfun, spec_inst_prags)]
                            (unitBag (mkVarBind local_nt_dfun (L loc (wrapId nt_cast the_meth_id))))

	       the_meth_id = ASSERT( length arg_ids == 1 ) head arg_ids
               nt_cast = WpCast $ mkPiTypes (inst_tyvars' ++ dfun_lam_vars) $
                         mkSymCoercion (mkTyConApp the_nt_co inst_tys')
    }


------------------------------
tcSuperClass :: InstLoc -> [TyVar] -> [Inst]
	     -> (Inst, LHsBinds Id)
	     -> (Id, Inst) -> TcM (Id, LHsBind Id)
-- Build a top level decl like
--	sc_op = /\a \d. let this = ... in 
--		        let sc = ... in
--			sc
-- The "this" part is just-in-case (discarded if not used)
-- See Note [Recursive superclasses]
tcSuperClass inst_loc tyvars dicts (this_dict, this_bind)
	     (sc_sel, sc_dict)
  = addErrCtxt superClassCtxt $
    do { sc_binds <- tcSimplifySuperClasses inst_loc 
				this_dict dicts [sc_dict]
         -- Don't include this_dict in the 'givens', else
         -- sc_dicts get bound by just selecting  from this_dict!!

       ; uniq <- newUnique
       ; let sc_op_ty = mkSigmaTy tyvars (map dictPred dicts) 
				  (mkPredTy (dictPred sc_dict))
	     sc_op_name = mkDerivedInternalName mkClassOpAuxOcc uniq
						(getName sc_sel)
	     sc_op_id   = mkLocalId sc_op_name sc_op_ty
	     sc_id      = instToVar sc_dict
	     sc_op_bind = AbsBinds tyvars 
			     (map instToVar dicts) 
                             [(tyvars, sc_op_id, sc_id, [])]
                             (this_bind `unionBags` sc_binds)

       ; return (sc_op_id, noLoc sc_op_bind) }
\end{code}

Note [Recursive superclasses]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
See Trac #1470 for why we would *like* to add "this_dict" to the 
available instances here.  But we can't do so because then the superclases
get satisfied by selection from this_dict, and that leads to an immediate
loop.  What we need is to add this_dict to Avails without adding its 
superclasses, and we currently have no way to do that.

Note [SPECIALISE instance pragmas]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider

   instance (Ix a, Ix b) => Ix (a,b) where
     {-# SPECIALISE instance Ix (Int,Int) #-}
     range (x,y) = ...

We do *not* want to make a specialised version of the dictionary
function.  Rather, we want specialised versions of each method.
Thus we should generate something like this:

  $dfIx :: (Ix a, Ix x) => Ix (a,b)
  {- DFUN [$crange, ...] -}
  $dfIx da db = Ix ($crange da db) (...other methods...)

  $dfIxPair :: (Ix a, Ix x) => Ix (a,b)
  {- DFUN [$crangePair, ...] -}
  $dfIxPair = Ix ($crangePair da db) (...other methods...)

  $crange :: (Ix a, Ix b) -> ((a,b),(a,b)) -> [(a,b)]
  {-# SPECIALISE $crange :: ((Int,Int),(Int,Int)) -> [(Int,Int)] #-}
  $crange da db = <blah>

  {-# RULE  range ($dfIx da db) = $crange da db #-}

Note that  

  * The RULE is unaffected by the specialisation.  We don't want to
    specialise $dfIx, because then it would need a specialised RULE
    which is a pain.  The single RULE works fine at all specialisations.
    See Note [How instance declarations are translated] above

  * Instead, we want to specialise the *method*, $crange

In practice, rather than faking up a SPECIALISE pragama for each
method (which is painful, since we'd have to figure out its
specialised type), we call tcSpecPrag *as if* were going to specialise
$dfIx -- you can see that in the call to tcSpecInst.  That generates a
SpecPrag which, as it turns out, can be used unchanged for each method.
The "it turns out" bit is delicate, but it works fine!

\begin{code}
tcSpecInst :: Id -> Sig Name -> TcM SpecPrag
tcSpecInst dfun_id prag@(SpecInstSig hs_ty) 
  = addErrCtxt (spec_ctxt prag) $
    do  { let name = idName dfun_id
        ; (tyvars, theta, tau) <- tcHsInstHead hs_ty	
        ; let spec_ty = mkSigmaTy tyvars theta tau
        ; co_fn <- tcSubExp (SpecPragOrigin name) (idType dfun_id) spec_ty
        ; return (SpecPrag co_fn defaultInlinePragma) }
  where
    spec_ctxt prag = hang (ptext (sLit "In the SPECIALISE pragma")) 2 (ppr prag)

tcSpecInst _  _ = panic "tcSpecInst"
\end{code}

%************************************************************************
%*                                                                      *
      Type-checking an instance method
%*                                                                      *
%************************************************************************

tcInstanceMethod
- Make the method bindings, as a [(NonRec, HsBinds)], one per method
- Remembering to use fresh Name (the instance method Name) as the binder
- Bring the instance method Ids into scope, for the benefit of tcInstSig
- Use sig_fn mapping instance method Name -> instance tyvars
- Ditto prag_fn
- Use tcValBinds to do the checking

\begin{code}
tcInstanceMethod :: SrcSpan -> Bool -> Class -> [TcTyVar] -> [Inst]
	 	 -> [TcType]
		 -> (Inst, LHsBinds Id)  -- "This" and its binding
          	 -> TcPragFun	    	 -- Local prags
		 -> [LSpecPrag]		 -- Arising from 'SPECLALISE instance'
                 -> LHsBinds Name 
	  	 -> (Id, DefMeth)
          	 -> TcM (Id, LHsBind Id)
	-- The returned inst_meth_ids all have types starting
	--	forall tvs. theta => ...

tcInstanceMethod loc standalone_deriv clas tyvars dfun_dicts inst_tys 
		 (this_dict, this_dict_bind)
		 prag_fn spec_inst_prags binds_in (sel_id, dm_info)
  = do  { uniq <- newUnique
	; let meth_name = mkDerivedInternalName mkClassOpAuxOcc uniq sel_name
        ; local_meth_name <- newLocalName sel_name
	  -- Base the local_meth_name on the selector name, becuase
	  -- type errors from tcInstanceMethodBody come from here

        ; let local_meth_ty = instantiateMethod clas sel_id inst_tys
	      meth_ty = mkSigmaTy tyvars (map dictPred dfun_dicts) local_meth_ty
	      meth_id       = mkLocalId meth_name meth_ty
              local_meth_id = mkLocalId local_meth_name local_meth_ty

    	    --------------
	      tc_body rn_bind 
                = add_meth_ctxt rn_bind $
                  do { (meth_id1, spec_prags) <- tcPrags NonRecursive False True 
                                                    meth_id (prag_fn sel_name)
                     ; tcInstanceMethodBody (instLoc this_dict)
                                    tyvars dfun_dicts
				    ([this_dict], this_dict_bind)
                                    meth_id1 local_meth_id
				    meth_sig_fn 
                                    (spec_inst_prags ++ spec_prags) 
                                    rn_bind }

    	    --------------
	      tc_default :: DefMeth -> TcM (Id, LHsBind Id)
		-- The user didn't supply a method binding, so we have to make 
		-- up a default binding, in a way depending on the default-method info

              tc_default NoDefMeth	    -- No default method at all
		= do { warnMissingMethod sel_id
		     ; return (meth_id, mkVarBind meth_id $ 
                                        mkLHsWrap lam_wrapper error_rhs) }
	      
	      tc_default GenDefMeth    -- Derivable type classes stuff
                = do { meth_bind <- mkGenericDefMethBind clas inst_tys sel_id local_meth_name
                     ; tc_body meth_bind }
		  
	      tc_default DefMeth	-- An polymorphic default method
	        = do {   -- Build the typechecked version directly, 
			 -- without calling typecheck_method; 
			 -- see Note [Default methods in instances]
			 -- Generate   /\as.\ds. let this = df as ds 
                         --                      in $dm inst_tys this
			 -- The 'let' is necessary only because HsSyn doesn't allow
			 -- you to apply a function to a dictionary *expression*.
		       dm_name <- lookupGlobalOccRn (mkDefMethRdrName sel_name)
					-- Might not be imported, but will be an OrigName
		     ; dm_id <- tcLookupId dm_name
		     ; inline_id <- tcLookupId inlineIdName
                     ; let dm_inline_prag = idInlinePragma dm_id
                           dm_app = HsWrap (WpApp (instToId this_dict) <.> mkWpTyApps inst_tys) $
			            HsVar dm_id 
                           rhs | isInlinePragma dm_inline_prag  -- See Note [INLINE and default methods]
                               = HsApp (L loc (HsWrap (WpTyApp local_meth_ty) (HsVar inline_id)))
                                       (L loc dm_app)
                               | otherwise = dm_app

		           meth_bind = L loc $ VarBind { var_id = local_meth_id
                                                       , var_rhs = L loc rhs 
						       , var_inline = False }
                           meth_id1 = meth_id `setInlinePragma` dm_inline_prag
			   	    -- Copy the inline pragma (if any) from the default
				    -- method to this version. Note [INLINE and default methods]
				    
                           bind = AbsBinds { abs_tvs = tyvars, abs_dicts =  dfun_lam_vars
                                           , abs_exports = [( tyvars, meth_id1
                                                            , local_meth_id, spec_inst_prags)]
                                           , abs_binds = this_dict_bind `unionBags` unitBag meth_bind }
		     -- Default methods in an instance declaration can't have their own 
		     -- INLINE or SPECIALISE pragmas. It'd be possible to allow them, but
   		     -- currently they are rejected with 
		     --		  "INLINE pragma lacks an accompanying binding"

		     ; return (meth_id1, L loc bind) } 

        ; case findMethodBind sel_name local_meth_name binds_in of
	    Just user_bind -> tc_body user_bind	   -- User-supplied method binding
	    Nothing	   -> tc_default dm_info   -- None supplied
	}
  where
    sel_name = idName sel_id

    meth_sig_fn _ = Just []	-- The 'Just' says "yes, there's a type sig"
	-- But there are no scoped type variables from local_method_id
	-- Only the ones from the instance decl itself, which are already
	-- in scope.  Example:
	--	class C a where { op :: forall b. Eq b => ... }
	-- 	instance C [c] where { op = <rhs> }
	-- In <rhs>, 'c' is scope but 'b' is not!

    error_rhs    = L loc $ HsApp error_fun error_msg
    error_fun    = L loc $ wrapId (WpTyApp meth_tau) nO_METHOD_BINDING_ERROR_ID
    error_msg    = L loc (HsLit (HsStringPrim (mkFastString error_string)))
    meth_tau     = funResultTy (applyTys (idType sel_id) inst_tys)
    error_string = showSDoc (hcat [ppr loc, text "|", ppr sel_id ])

    dfun_lam_vars = map instToVar dfun_dicts
    lam_wrapper   = mkWpTyLams tyvars <.> mkWpLams dfun_lam_vars

	-- For instance decls that come from standalone deriving clauses
	-- we want to print out the full source code if there's an error
	-- because otherwise the user won't see the code at all
    add_meth_ctxt rn_bind thing 
      | standalone_deriv = addLandmarkErrCtxt (derivBindCtxt clas inst_tys rn_bind) thing
      | otherwise        = thing

wrapId :: HsWrapper -> id -> HsExpr id
wrapId wrapper id = mkHsWrap wrapper (HsVar id)

derivBindCtxt :: Class -> [Type ] -> LHsBind Name -> SDoc
derivBindCtxt clas tys bind
   = vcat [ ptext (sLit "When typechecking a standalone-derived method for")
	    <+> quotes (pprClassPred clas tys) <> colon
	  , nest 2 $ pprSetDepth AllTheWay $ ppr bind ]

warnMissingMethod :: Id -> TcM ()
warnMissingMethod sel_id
  = do { warn <- doptM Opt_WarnMissingMethods		
       ; warnTc (warn  -- Warn only if -fwarn-missing-methods
                 && not (startsWithUnderscore (getOccName sel_id)))
					-- Don't warn about _foo methods
		(ptext (sLit "No explicit method nor default method for")
                 <+> quotes (ppr sel_id)) }
\end{code}

Note [Export helper functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We arrange to export the "helper functions" of an instance declaration,
so that they are not subject to preInlineUnconditionally, even if their
RHS is trivial.  Reason: they are mentioned in the DFunUnfolding of
the dict fun as Ids, not as CoreExprs, so we can't substitute a 
non-variable for them.

We could change this by making DFunUnfoldings have CoreExprs, but it
seems a bit simpler this way.

Note [Default methods in instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this

   class Baz v x where
      foo :: x -> x
      foo y = <blah>

   instance Baz Int Int

From the class decl we get

   $dmfoo :: forall v x. Baz v x => x -> x
   $dmfoo y = <blah>

Notice that the type is ambiguous.  That's fine, though. The instance decl generates

   $dBazIntInt = MkBaz fooIntInt
   fooIntInt = $dmfoo Int Int $dBazIntInt

BUT this does mean we must generate the dictionary translation of
fooIntInt directly, rather than generating source-code and
type-checking it.  That was the bug in Trac #1061. In any case it's
less work to generate the translated version!

Note [INLINE and default methods]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We *copy* any INLINE pragma from the default method to the instance.
Example:
  class Foo a where
    op1, op2 :: Bool -> a -> a

    {-# INLINE op1 #-}
    op1 b x = op2 (not b) x

  instance Foo Int where
    op2 b x = <blah>

Then we generate:

  {-# INLINE $dmop1 #-}
  $dmop1 d b x = op2 d (not b) x

  $fFooInt = MkD $cop1 $cop2

  {-# INLINE $cop1 #-}
  $cop1 = inline $dmop1 $fFooInt

  $cop2 = <blah>

Note carefully:
  a) We copy $dmop1's inline pragma to $cop1.  Otherwise 
     we'll just inline the former in the latter and stop, which 
     isn't what the user expected

  b) We use the magic 'inline' Id to ensure that $dmop1 really is
     inlined in $cop1, even though 
       (i)  the latter itself has an INLINE pragma
       (ii) $dmop1 is not saturated
     That is important to allow the mutual recursion between $fooInt and
     $cop1 to be broken


%************************************************************************
%*                                                                      *
\subsection{Error messages}
%*                                                                      *
%************************************************************************

\begin{code}
instDeclCtxt1 :: LHsType Name -> SDoc
instDeclCtxt1 hs_inst_ty
  = inst_decl_ctxt (case unLoc hs_inst_ty of
                        HsForAllTy _ _ _ (L _ (HsPredTy pred)) -> ppr pred
                        HsPredTy pred                    -> ppr pred
                        _                                -> ppr hs_inst_ty)     -- Don't expect this
instDeclCtxt2 :: Type -> SDoc
instDeclCtxt2 dfun_ty
  = inst_decl_ctxt (ppr (mkClassPred cls tys))
  where
    (_,cls,tys) = tcSplitDFunTy dfun_ty

inst_decl_ctxt :: SDoc -> SDoc
inst_decl_ctxt doc = ptext (sLit "In the instance declaration for") <+> quotes doc

superClassCtxt :: SDoc
superClassCtxt = ptext (sLit "When checking the super-classes of an instance declaration")

atInstCtxt :: Name -> SDoc
atInstCtxt name = ptext (sLit "In the associated type instance for") <+>
                  quotes (ppr name)

mustBeVarArgErr :: Type -> SDoc
mustBeVarArgErr ty =
  sep [ ptext (sLit "Arguments that do not correspond to a class parameter") <+>
        ptext (sLit "must be variables")
      , ptext (sLit "Instead of a variable, found") <+> ppr ty
      ]

wrongATArgErr :: Type -> Type -> SDoc
wrongATArgErr ty instTy =
  sep [ ptext (sLit "Type indexes must match class instance head")
      , ptext (sLit "Found") <+> quotes (ppr ty)
        <+> ptext (sLit "but expected") <+> quotes (ppr instTy)
      ]
\end{code}
