%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[TcClassDcl]{Typechecking class declarations}

\begin{code}
module TcClassDcl ( tcClassDecl1, tcClassDecls2, mkImplicitClassBinds,
		    tcMethodBind, checkFromThisClass
		  ) where

#include "HsVersions.h"

import HsSyn		( HsDecl(..), TyClDecl(..), Sig(..), MonoBinds(..),
			  InPat(..), HsBinds(..), GRHSs(..),
			  HsExpr(..), HsLit(..), HsType(..), HsPred(..),
			  mkSimpleMatch,
			  andMonoBinds, andMonoBindList, 
			  isClassDecl, isClassOpSig, isPragSig, collectMonoBinders
			)
import BasicTypes	( NewOrData(..), TopLevelFlag(..), RecFlag(..) )
import RnHsSyn		( RenamedTyClDecl, RenamedClassPragmas,
			  RenamedClassOpSig, RenamedMonoBinds,
			  RenamedContext, RenamedHsDecl, RenamedSig
			)
import TcHsSyn		( TcMonoBinds, idsToMonoBinds )

import Inst		( Inst, InstOrigin(..), LIE, emptyLIE, plusLIE, plusLIEs, newDicts, newMethod )
import TcEnv		( TcId, ValueEnv, TyThing(..), TyThingDetails(..), tcAddImportedIdInfo,
			  tcLookupTy, tcExtendTyVarEnvForMeths, tcExtendGlobalTyVars,
			  tcExtendLocalValEnv, tcExtendTyVarEnv, newDefaultMethodName
			)
import TcBinds		( tcBindWithSigs, tcSpecSigs )
import TcTyDecls	( mkNewTyConRep )
import TcMonoType	( tcHsSigType, tcClassContext, checkSigTyVars, sigCtxt, mkTcSig )
import TcSimplify	( tcSimplifyAndCheck, bindInstsOfLocalFuns )
import TcType		( TcType, TcTyVar, tcInstTyVars, tcGetTyVar, zonkTcSigTyVars )
import TcInstUtil	( classDataCon )
import TcMonad
import PrelInfo		( nO_METHOD_BINDING_ERROR_ID )
import Bag		( unionManyBags, bagToList )
import Class		( classTyVars, classBigSig, classSelIds, classTyCon, Class, ClassOpItem )
import CmdLineOpts      ( opt_GlasgowExts, opt_WarnMissingMethods )
import MkId		( mkDictSelId, mkDataConId, mkDataConWrapId, mkDefaultMethodId )
import DataCon		( mkDataCon, dataConId, dataConWrapId, notMarkedStrict )
import Id		( Id, setInlinePragma, idUnfolding, idType, idName )
import Name		( Name, nameOccName, isLocallyDefined, NamedThing(..) )
import NameSet		( NameSet, mkNameSet, elemNameSet, emptyNameSet )
import Outputable
import Type		( Type, ThetaType, ClassContext,
			  mkFunTy, mkTyVarTy, mkTyVarTys, mkDictTy, mkDictTys,
			  mkSigmaTy, mkClassPred, classesOfPreds,
			  boxedTypeKind, mkArrowKind
			)
import Var		( tyVarKind, TyVar )
import VarSet		( mkVarSet, emptyVarSet )
import TyCon		( AlgTyConFlavour(..), mkClassTyCon )
import Maybes		( seqMaybe )
import SrcLoc		( SrcLoc )
import FiniteMap        ( lookupWithDefaultFM )
\end{code}



Dictionary handling
~~~~~~~~~~~~~~~~~~~
Every class implicitly declares a new data type, corresponding to dictionaries
of that class. So, for example:

	class (D a) => C a where
	  op1 :: a -> a
	  op2 :: forall b. Ord b => a -> b -> b

would implicitly declare

	data CDict a = CDict (D a)	
			     (a -> a)
			     (forall b. Ord b => a -> b -> b)

(We could use a record decl, but that means changing more of the existing apparatus.
One step at at time!)

For classes with just one superclass+method, we use a newtype decl instead:

	class C a where
	  op :: forallb. a -> b -> b

generates

	newtype CDict a = CDict (forall b. a -> b -> b)

Now DictTy in Type is just a form of type synomym: 
	DictTy c t = TyConTy CDict `AppTy` t

Death to "ExpandingDicts".


%************************************************************************
%*									*
\subsection{Type checking}
%*									*
%************************************************************************

\begin{code}
tcClassDecl1 :: ValueEnv -> RenamedTyClDecl -> TcM s (Name, TyThingDetails)
tcClassDecl1 rec_env
      	     (ClassDecl context class_name
			tyvar_names fundeps class_sigs def_methods pragmas 
			tycon_name datacon_name datacon_wkr_name sc_sel_names src_loc)
  = 	-- CHECK ARITY 1 FOR HASKELL 1.4
    checkTc (opt_GlasgowExts || length tyvar_names == 1)
	    (classArityErr class_name)			`thenTc_`

	-- LOOK THINGS UP IN THE ENVIRONMENT
    tcLookupTy class_name				`thenTc` \ (AClass clas) ->
    let
	tyvars = classTyVars clas
	dm_bndrs_w_locs = bagToList (collectMonoBinders def_methods)
	dm_bndr_set	= mkNameSet (map fst dm_bndrs_w_locs)
    in
    tcExtendTyVarEnv tyvars			$ 
	
	-- CHECK THE CONTEXT
    tcSuperClasses class_name clas
		   context sc_sel_names		`thenTc` \ (sc_theta, sc_sel_ids) ->

	-- CHECK THE CLASS SIGNATURES,
    mapTc (tcClassSig rec_env dm_bndr_set clas tyvars) 
	  (filter isClassOpSig class_sigs)		`thenTc` \ sig_stuff ->

	-- MAKE THE CLASS DETAILS
    let
	(op_tys, op_items) = unzip sig_stuff
        sc_tys		   = mkDictTys sc_theta
	dict_component_tys = sc_tys ++ op_tys

        dict_con = mkDataCon datacon_name
			   [notMarkedStrict | _ <- dict_component_tys]
			   [{- No labelled fields -}]
		      	   tyvars
		      	   [{-No context-}]
			   [{-No existential tyvars-}] [{-Or context-}]
			   dict_component_tys
		      	   (classTyCon clas)
			   dict_con_id dict_wrap_id

	dict_con_id  = mkDataConId datacon_wkr_name dict_con
	dict_wrap_id = mkDataConWrapId dict_con
    in
    returnTc (class_name, ClassDetails sc_theta sc_sel_ids op_items dict_con)
\end{code}

\begin{code}
tcSuperClasses :: Name -> Class
	       -> RenamedContext 	-- class context
	       -> [Name]		-- Names for superclass selectors
	       -> TcM s (ClassContext,	-- the superclass context
		         [Id])  	-- superclass selector Ids

tcSuperClasses class_name clas context sc_sel_names
  = 	-- Check the context.
	-- The renamer has already checked that the context mentions
	-- only the type variable of the class decl.

	-- For std Haskell check that the context constrains only tyvars
    (if opt_GlasgowExts then
	returnTc ()
     else
	mapTc_ check_constraint context
    )					`thenTc_`

	-- Context is already kind-checked
    tcClassContext context			`thenTc` \ sc_theta ->
    let
       sc_sel_ids = [mkDictSelId sc_name clas | sc_name <- sc_sel_names]
    in
	-- Done
    returnTc (sc_theta, sc_sel_ids)

  where
    check_constraint sc@(HsPClass c tys) 
	= checkTc (all is_tyvar tys) (superClassErr class_name sc)

    is_tyvar (HsTyVar _) = True
    is_tyvar other	 = False


tcClassSig :: ValueEnv		-- Knot tying only!
	   -> NameSet		-- Names bound in the default-method bindings
	   -> Class	    		-- ...ditto...
	   -> [TyVar]		 	-- The class type variable, used for error check only
	   -> RenamedClassOpSig
	   -> TcM s (Type,		-- Type of the method
		     ClassOpItem)	-- Selector Id, default-method Id, True if explicit default binding


tcClassSig rec_env dm_bind_names clas clas_tyvars
	   (ClassOpSig op_name maybe_dm_stuff op_ty src_loc)
  = tcAddSrcLoc src_loc $

	-- Check the type signature.  NB that the envt *already has*
	-- bindings for the type variables; see comments in TcTyAndClassDcls.

    -- NB: Renamer checks that the class type variable is mentioned in local_ty,
    -- and that it is not constrained by theta
    tcHsSigType op_ty				`thenTc` \ local_ty ->
    let
	global_ty   = mkSigmaTy clas_tyvars 
			        [mkClassPred clas (mkTyVarTys clas_tyvars)]
			        local_ty

	-- Build the selector id and default method id
	sel_id      = mkDictSelId op_name clas
    in
    (case maybe_dm_stuff of
	Nothing ->	-- Source-file class declaration
	    newDefaultMethodName op_name src_loc	`thenNF_Tc` \ dm_name ->
	    returnNF_Tc (mkDefaultMethodId dm_name clas global_ty, op_name `elemNameSet` dm_bind_names)

	Just (dm_name, explicit_dm) ->	-- Interface-file class decl
	    let
		dm_id = mkDefaultMethodId dm_name clas global_ty
	    in
	    returnNF_Tc (tcAddImportedIdInfo rec_env dm_id, explicit_dm)
    )				`thenNF_Tc` \ (dm_id, explicit_dm) ->

    returnTc (local_ty, (sel_id, dm_id, explicit_dm))
\end{code}


%************************************************************************
%*									*
\subsection[ClassDcl-pass2]{Class decls pass 2: default methods}
%*									*
%************************************************************************

The purpose of pass 2 is
\begin{enumerate}
\item
to beat on the explicitly-provided default-method decls (if any),
using them to produce a complete set of default-method decls.
(Omitted ones elicit an error message.)
\item
to produce a definition for the selector function for each method
and superclass dictionary.
\end{enumerate}

Pass~2 only applies to locally-defined class declarations.

The function @tcClassDecls2@ just arranges to apply @tcClassDecl2@ to
each local class decl.

\begin{code}
tcClassDecls2 :: [RenamedHsDecl]
	      -> NF_TcM s (LIE, TcMonoBinds)

tcClassDecls2 decls
  = foldr combine
	  (returnNF_Tc (emptyLIE, EmptyMonoBinds))
	  [tcClassDecl2 cls_decl | TyClD cls_decl <- decls, isClassDecl cls_decl]
  where
    combine tc1 tc2 = tc1 `thenNF_Tc` \ (lie1, binds1) ->
		      tc2 `thenNF_Tc` \ (lie2, binds2) ->
		      returnNF_Tc (lie1 `plusLIE` lie2,
				   binds1 `AndMonoBinds` binds2)
\end{code}

@tcClassDecl2@ is the business end of things.

\begin{code}
tcClassDecl2 :: RenamedTyClDecl		-- The class declaration
	     -> NF_TcM s (LIE, TcMonoBinds)

tcClassDecl2 (ClassDecl context class_name
			tyvar_names _ class_sigs default_binds pragmas _ _ _ _ src_loc)

  | not (isLocallyDefined class_name)
  = returnNF_Tc (emptyLIE, EmptyMonoBinds)

  | otherwise	-- It is locally defined
  = recoverNF_Tc (returnNF_Tc (emptyLIE, EmptyMonoBinds)) $ 
    tcAddSrcLoc src_loc		     		          $
    tcLookupTy class_name				`thenNF_Tc` \ (AClass clas) ->
    tcDefaultMethodBinds clas default_binds class_sigs
\end{code}

\begin{code}
mkImplicitClassBinds :: [Class] -> NF_TcM s ([Id], TcMonoBinds)
mkImplicitClassBinds classes
  = returnNF_Tc (concat cls_ids_s, andMonoBindList binds_s)
	-- The selector binds are already in the selector Id's unfoldings
	-- We don't return the data constructor etc from the class,
	-- because that's done via the class's TyCon
  where
    (cls_ids_s, binds_s) = unzip (map mk_implicit classes)

    mk_implicit clas = (sel_ids, binds)
		     where
			sel_ids = classSelIds clas
			binds | isLocallyDefined clas = idsToMonoBinds sel_ids
			      | otherwise	      = EmptyMonoBinds
\end{code}

%************************************************************************
%*									*
\subsection[Default methods]{Default methods}
%*									*
%************************************************************************

The default methods for a class are each passed a dictionary for the
class, so that they get access to the other methods at the same type.
So, given the class decl
\begin{verbatim}
class Foo a where
	op1 :: a -> Bool
	op2 :: Ord b => a -> b -> b -> b

	op1 x = True
	op2 x y z = if (op1 x) && (y < z) then y else z
\end{verbatim}
we get the default methods:
\begin{verbatim}
defm.Foo.op1 :: forall a. Foo a => a -> Bool
defm.Foo.op1 = /\a -> \dfoo -> \x -> True

defm.Foo.op2 :: forall a. Foo a => forall b. Ord b => a -> b -> b -> b
defm.Foo.op2 = /\ a -> \ dfoo -> /\ b -> \ dord -> \x y z ->
		  if (op1 a dfoo x) && (< b dord y z) then y else z
\end{verbatim}

When we come across an instance decl, we may need to use the default
methods:
\begin{verbatim}
instance Foo Int where {}
\end{verbatim}
gives
\begin{verbatim}
const.Foo.Int.op1 :: Int -> Bool
const.Foo.Int.op1 = defm.Foo.op1 Int dfun.Foo.Int

const.Foo.Int.op2 :: forall b. Ord b => Int -> b -> b -> b
const.Foo.Int.op2 = defm.Foo.op2 Int dfun.Foo.Int

dfun.Foo.Int :: Foo Int
dfun.Foo.Int = (const.Foo.Int.op1, const.Foo.Int.op2)
\end{verbatim}
Notice that, as with method selectors above, we assume that dictionary
application is curried, so there's no need to mention the Ord dictionary
in const.Foo.Int.op2 (or the type variable).

\begin{verbatim}
instance Foo a => Foo [a] where {}

dfun.Foo.List :: forall a. Foo a -> Foo [a]
dfun.Foo.List
  = /\ a -> \ dfoo_a ->
    let rec
	op1 = defm.Foo.op1 [a] dfoo_list
	op2 = defm.Foo.op2 [a] dfoo_list
	dfoo_list = (op1, op2)
    in
	dfoo_list
\end{verbatim}

\begin{code}
tcDefaultMethodBinds
	:: Class
	-> RenamedMonoBinds
	-> [RenamedSig]
	-> TcM s (LIE, TcMonoBinds)

tcDefaultMethodBinds clas default_binds sigs
  = 	-- Check that the default bindings come from this class
    checkFromThisClass clas default_binds	`thenNF_Tc_`

	-- Do each default method separately
	-- For Hugs compatibility we make a default-method for every
	-- class op, regardless of whether or not the programmer supplied an
	-- explicit default decl for the class.  GHC will actually never
	-- call the default method for such operations, because it'll whip up
	-- a more-informative default method at each instance decl.
    mapAndUnzipTc tc_dm op_items		`thenTc` \ (defm_binds, const_lies) ->

    returnTc (plusLIEs const_lies, andMonoBindList defm_binds)
  where
    prags = filter isPragSig sigs

    (tyvars, _, _, op_items) = classBigSig clas

    origin = ClassDeclOrigin

    -- We make a separate binding for each default method.
    -- At one time I used a single AbsBinds for all of them, thus
    --	AbsBind [d] [dm1, dm2, dm3] { dm1 = ...; dm2 = ...; dm3 = ... }
    -- But that desugars into
    --	ds = \d -> (..., ..., ...)
    --	dm1 = \d -> case ds d of (a,b,c) -> a
    -- And since ds is big, it doesn't get inlined, so we don't get good
    -- default methods.  Better to make separate AbsBinds for each
    
    tc_dm op_item@(_, dm_id, _)
      = tcInstTyVars tyvars		`thenNF_Tc` \ (clas_tyvars, inst_tys, _) ->
	let
	    theta = [(mkClassPred clas inst_tys)]
	in
	newDicts origin theta 			`thenNF_Tc` \ (this_dict, [this_dict_id]) ->
	let
	    avail_insts = this_dict
	in
	tcExtendTyVarEnvForMeths tyvars clas_tyvars (
	    tcMethodBind clas origin clas_tyvars inst_tys theta
		         default_binds prags False
		         op_item
        )					`thenTc` \ (defm_bind, insts_needed, (_, local_dm_id)) ->
    
	tcAddErrCtxt (defltMethCtxt clas) $
    
	    -- tcMethodBind has checked that the class_tyvars havn't
	    -- been unified with each other or another type, but we must
	    -- still zonk them before passing them to tcSimplifyAndCheck
        zonkTcSigTyVars clas_tyvars	`thenNF_Tc` \ clas_tyvars' ->
    
	    -- Check the context
	tcSimplifyAndCheck
	    (ptext SLIT("class") <+> ppr clas)
	    (mkVarSet clas_tyvars')
	    avail_insts
	    insts_needed			`thenTc` \ (const_lie, dict_binds) ->
    
	let
	    full_bind = AbsBinds
			    clas_tyvars'
			    [this_dict_id]
			    [(clas_tyvars', dm_id, local_dm_id)]
			    emptyNameSet	-- No inlines (yet)
			    (dict_binds `andMonoBinds` defm_bind)
	in
	returnTc (full_bind, const_lie)
\end{code}

\begin{code}
checkFromThisClass :: Class -> RenamedMonoBinds -> NF_TcM s ()
checkFromThisClass clas mbinds
  = mapNF_Tc check_from_this_class bndrs_w_locs	`thenNF_Tc_`
    returnNF_Tc ()
  where
    check_from_this_class (bndr, loc)
	  | nameOccName bndr `elem` sel_names = returnNF_Tc ()
	  | otherwise			      = tcAddSrcLoc loc $
						addErrTc (badMethodErr bndr clas)
    sel_names    = map getOccName (classSelIds clas)
    bndrs_w_locs = bagToList (collectMonoBinders mbinds)
\end{code}
    

@tcMethodBind@ is used to type-check both default-method and
instance-decl method declarations.  We must type-check methods one at a
time, because their signatures may have different contexts and
tyvar sets.

\begin{code}
tcMethodBind 
	:: Class
	-> InstOrigin
	-> [TcTyVar]		-- Instantiated type variables for the
				--  enclosing class/instance decl. 
				--  They'll be signature tyvars, and we
				--  want to check that they don't get bound
	-> [TcType]		-- Instance types
	-> TcThetaType		-- Available theta; this could be used to check
				--  the method signature, but actually that's done by
				--  the caller;  here, it's just used for the error message
	-> RenamedMonoBinds	-- Method binding (pick the right one from in here)
	-> [RenamedSig]		-- Pramgas (just for this one)
	-> Bool			-- True <=> This method is from an instance declaration
	-> ClassOpItem		-- The method selector and default-method Id
	-> TcM s (TcMonoBinds, LIE, (LIE, TcId))

tcMethodBind clas origin inst_tyvars inst_tys inst_theta
	     meth_binds prags is_inst_decl
	     (sel_id, dm_id, explicit_dm)
 = tcGetSrcLoc 		`thenNF_Tc` \ loc -> 

   newMethod origin sel_id inst_tys	`thenNF_Tc` \ meth@(_, meth_id) ->
   mkTcSig meth_id loc			`thenNF_Tc` \ sig_info -> 

   let
     meth_name	     = idName meth_id
     maybe_user_bind = find_bind meth_name meth_binds

     no_user_bind    = case maybe_user_bind of {Nothing -> True; other -> False}

     meth_bind = case maybe_user_bind of
		 	Just bind -> bind
			Nothing   -> mk_default_bind meth_name loc

     meth_prags = find_prags meth_name prags
   in

	-- Warn if no method binding, only if -fwarn-missing-methods
   warnTc (is_inst_decl && opt_WarnMissingMethods && no_user_bind && not explicit_dm)
	  (omittedMethodWarn sel_id clas)		`thenNF_Tc_`

	-- Check the bindings; first add inst_tyvars to the envt
	-- so that we don't quantify over them in nested places
	-- The *caller* put the class/inst decl tyvars into the envt
   tcExtendGlobalTyVars (mkVarSet inst_tyvars) (
     tcAddErrCtxt (methodCtxt sel_id)		$
     tcBindWithSigs NotTopLevel meth_bind 
		    [sig_info] meth_prags NonRecursive 
   )						`thenTc` \ (binds, insts, _) ->


   tcExtendLocalValEnv [(meth_name, meth_id)] (
	tcSpecSigs meth_prags
   )						`thenTc` \ (prag_binds1, prag_lie) ->

	-- The prag_lie for a SPECIALISE pragma will mention the function
	-- itself, so we have to simplify them away right now lest they float
	-- outwards!
   bindInstsOfLocalFuns prag_lie [meth_id]	`thenTc` \ (prag_lie', prag_binds2) ->


	-- Now check that the instance type variables
	-- (or, in the case of a class decl, the class tyvars)
	-- have not been unified with anything in the environment
	--	
	-- We do this for each method independently to localise error messages
   tcAddErrCtxtM (sigCtxt sig_msg inst_tyvars inst_theta (idType meth_id))	$
   checkSigTyVars inst_tyvars emptyVarSet					`thenTc_` 

   returnTc (binds `AndMonoBinds` prag_binds1 `AndMonoBinds` prag_binds2, 
	     insts `plusLIE` prag_lie', 
	     meth)
 where
   sig_msg = ptext SLIT("When checking the expected type for class method") <+> ppr sel_name

   sel_name = idName sel_id

	-- The renamer just puts the selector ID as the binder in the method binding
	-- but we must use the method name; so we substitute it here.  Crude but simple.
   find_bind meth_name (FunMonoBind op_name fix matches loc)
	| op_name == sel_name = Just (FunMonoBind meth_name fix matches loc)
   find_bind meth_name (AndMonoBinds b1 b2)
			      = find_bind meth_name b1 `seqMaybe` find_bind meth_name b2
   find_bind meth_name other  = Nothing	-- Default case


	-- Find the prags for this method, and replace the
	-- selector name with the method name
   find_prags meth_name [] = []
   find_prags meth_name (SpecSig name ty loc : prags)
	| name == sel_name = SpecSig meth_name ty loc : find_prags meth_name prags
   find_prags meth_name (InlineSig name phase loc : prags)
	| name == sel_name = InlineSig meth_name phase loc : find_prags meth_name prags
   find_prags meth_name (NoInlineSig name phase loc : prags)
	| name == sel_name = NoInlineSig meth_name phase loc : find_prags meth_name prags
   find_prags meth_name (prag:prags) = find_prags meth_name prags

   mk_default_bind local_meth_name loc
      = FunMonoBind local_meth_name
		    False	-- Not infix decl
		    [mkSimpleMatch [] (default_expr loc) Nothing loc]
		    loc

   default_expr loc 
	| explicit_dm = HsVar (getName dm_id)	-- There's a default method
   	| otherwise   = error_expr loc		-- No default method

   error_expr loc = HsApp (HsVar (getName nO_METHOD_BINDING_ERROR_ID)) 
	                  (HsLit (HsString (_PK_ (error_msg loc))))

   error_msg loc = showSDoc (hcat [ppr loc, text "|", ppr sel_id ])
\end{code}

Contexts and errors
~~~~~~~~~~~~~~~~~~~
\begin{code}
classArityErr class_name
  = ptext SLIT("Too many parameters for class") <+> quotes (ppr class_name)

superClassErr class_name sc
  = ptext SLIT("Illegal superclass constraint") <+> quotes (ppr sc)
    <+> ptext SLIT("in declaration for class") <+> quotes (ppr class_name)

defltMethCtxt class_name
  = ptext SLIT("When checking the default methods for class") <+> quotes (ppr class_name)

methodCtxt sel_id
  = ptext SLIT("In the definition for method") <+> quotes (ppr sel_id)

badMethodErr bndr clas
  = hsep [ptext SLIT("Class"), quotes (ppr clas), 
	  ptext SLIT("does not have a method"), quotes (ppr bndr)]

omittedMethodWarn sel_id clas
  = sep [ptext SLIT("No explicit method nor default method for") <+> quotes (ppr sel_id), 
	 ptext SLIT("in an instance declaration for") <+> quotes (ppr clas)]
\end{code}
