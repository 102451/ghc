%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnSource]{Main pass of renamer}

\begin{code}
module RnSource ( 
	rnSrcDecls, addTcgDUs, 
	rnTyClDecls, checkModDeprec,
	rnBindGroups, rnBindGroupsAndThen, rnSplice
    ) where

#include "HsVersions.h"

import HsSyn
import RdrName		( RdrName, isRdrDataCon, rdrNameOcc, elemLocalRdrEnv )
import RdrHsSyn		( extractGenericPatTyVars )
import RnHsSyn
import RnExpr		( rnLExpr, checkTH )
import RnTypes		( rnLHsType, rnLHsTypes, rnHsSigType, rnHsTypeFVs, rnContext )
import RnBinds		( rnTopBinds, rnBinds, rnMethodBinds, 
			  rnBindsAndThen, renameSigs, checkSigs )
import RnEnv		( lookupTopBndrRn, lookupTopFixSigNames,
			  lookupLocatedTopBndrRn, lookupLocatedOccRn,
			  lookupOccRn, newLocalsRn, 
			  bindLocatedLocalsFV, bindPatSigTyVarsFV,
			  bindTyVarsRn, extendTyVarEnvFVRn,
			  bindLocalNames, newIPNameRn,
			  checkDupNames, mapFvRn,
			  unknownNameErr
			)
import TcRnMonad

import BasicTypes	( TopLevelFlag(..)  )
import HscTypes		( FixityEnv, FixItem(..),
			  Deprecations, Deprecs(..), DeprecTxt, plusDeprecs )
import Class		( FunDep )
import Name		( Name, nameOccName )
import NameSet
import NameEnv
import Outputable
import SrcLoc		( Located(..), unLoc, getLoc, noLoc )
import CmdLineOpts	( DynFlag(..) )
import DriverPhases	( isHsBoot )
import Maybes		( seqMaybe )
import Maybe            ( catMaybes, isNothing )
\end{code}

@rnSourceDecl@ `renames' declarations.
It simultaneously performs dependency analysis and precedence parsing.
It also does the following error checks:
\begin{enumerate}
\item
Checks that tyvars are used properly. This includes checking
for undefined tyvars, and tyvars in contexts that are ambiguous.
(Some of this checking has now been moved to module @TcMonoType@,
since we don't have functional dependency information at this point.)
\item
Checks that all variable occurences are defined.
\item 
Checks the @(..)@ etc constraints in the export list.
\end{enumerate}


\begin{code}
rnSrcDecls :: HsGroup RdrName -> RnM (TcGblEnv, HsGroup Name)

rnSrcDecls (HsGroup { hs_valds  = [HsBindGroup binds sigs _],
		      hs_tyclds = tycl_decls,
		      hs_instds = inst_decls,
		      hs_fixds  = fix_decls,
		      hs_depds  = deprec_decls,
		      hs_fords  = foreign_decls,
		      hs_defds  = default_decls,
		      hs_ruleds = rule_decls })

 = do {		-- Deal with deprecations (returns only the extra deprecations)
	deprecs <- rnSrcDeprecDecls deprec_decls ;
	updGblEnv (\gbl -> gbl { tcg_deprecs = tcg_deprecs gbl `plusDeprecs` deprecs })
		  $ do {

		-- Deal with top-level fixity decls 
		-- (returns the total new fixity env)
	fix_env <- rnSrcFixityDecls fix_decls ;
	updGblEnv (\gbl -> gbl { tcg_fix_env = fix_env })
		  $ do {

		-- Rename other declarations
	traceRn (text "Start rnmono") ;
	(rn_val_decls, bind_dus) <- rnTopBinds binds sigs ;
	traceRn (text "finish rnmono" <+> ppr rn_val_decls) ;

		-- You might think that we could build proper def/use information
		-- for type and class declarations, but they can be involved
		-- in mutual recursion across modules, and we only do the SCC
		-- analysis for them in the type checker.
		-- So we content ourselves with gathering uses only; that
		-- means we'll only report a declaration as unused if it isn't
		-- mentioned at all.  Ah well.
	(rn_tycl_decls,    src_fvs1)
	   <- mapFvRn (wrapLocFstM rnTyClDecl) tycl_decls ;
	(rn_inst_decls,    src_fvs2)
	   <- mapFvRn (wrapLocFstM rnSrcInstDecl) inst_decls ;
	(rn_rule_decls,    src_fvs3)
	   <- mapFvRn (wrapLocFstM rnHsRuleDecl) rule_decls ;
	(rn_foreign_decls, src_fvs4)
	   <- mapFvRn (wrapLocFstM rnHsForeignDecl) foreign_decls ;
	(rn_default_decls, src_fvs5)
	   <- mapFvRn (wrapLocFstM rnDefaultDecl) default_decls ;
	
	let {
	   rn_group = HsGroup { hs_valds  = rn_val_decls,
			    	hs_tyclds = rn_tycl_decls,
			    	hs_instds = rn_inst_decls,
			    	hs_fixds  = [],
			    	hs_depds  = [],
			    	hs_fords  = rn_foreign_decls,
			    	hs_defds  = rn_default_decls,
			    	hs_ruleds = rn_rule_decls } ;

	   other_fvs = plusFVs [src_fvs1, src_fvs2, src_fvs3, 
				src_fvs4, src_fvs5] ;
	   src_dus = bind_dus `plusDU` usesOnly other_fvs 
		-- Note: src_dus will contain *uses* for locally-defined types
		-- and classes, but no *defs* for them.  (Because rnTyClDecl 
		-- returns only the uses.)  This is a little 
		-- surprising but it doesn't actually matter at all.
	} ;

	traceRn (text "finish rnSrc" <+> ppr rn_group) ;
	traceRn (text "finish Dus" <+> ppr src_dus ) ;
	tcg_env <- getGblEnv ;
	return (tcg_env `addTcgDUs` src_dus, rn_group)
    }}}

rnTyClDecls :: [LTyClDecl RdrName] -> RnM [LTyClDecl Name]
rnTyClDecls tycl_decls = do 
  (decls', fvs) <- mapFvRn (wrapLocFstM rnTyClDecl) tycl_decls
  return decls'

addTcgDUs :: TcGblEnv -> DefUses -> TcGblEnv 
addTcgDUs tcg_env dus = tcg_env { tcg_dus = tcg_dus tcg_env `plusDU` dus }
\end{code}


%*********************************************************
%*						 	 *
	Source-code fixity declarations
%*							 *
%*********************************************************

\begin{code}
rnSrcFixityDecls :: [LFixitySig RdrName] -> RnM FixityEnv
rnSrcFixityDecls fix_decls
  = getGblEnv					`thenM` \ gbl_env ->
    foldlM rnFixityDecl (tcg_fix_env gbl_env) 
	    fix_decls				 	`thenM` \ fix_env ->
    traceRn (text "fixity env" <+> pprFixEnv fix_env)	`thenM_`
    returnM fix_env

rnFixityDecl :: FixityEnv -> LFixitySig RdrName -> RnM FixityEnv
rnFixityDecl fix_env (L loc (FixitySig rdr_name fixity))
  = setSrcSpan loc $
        -- GHC extension: look up both the tycon and data con 
	-- for con-like things
	-- If neither are in scope, report an error; otherwise
	-- add both to the fixity env
     addLocM lookupTopFixSigNames rdr_name	`thenM` \ names ->
     if null names then
	  addLocErr rdr_name unknownNameErr	`thenM_`
	  returnM fix_env
     else
	  foldlM add fix_env names
  where
    add fix_env name
      = case lookupNameEnv fix_env name of
          Just (FixItem _ _ loc') 
		  -> addLocErr rdr_name (dupFixityDecl loc')	`thenM_`
    		     returnM fix_env
    	  Nothing -> returnM (extendNameEnv fix_env name fix_item)
      where
	fix_item = FixItem (nameOccName name) fixity (getLoc rdr_name)

pprFixEnv :: FixityEnv -> SDoc
pprFixEnv env 
  = pprWithCommas (\ (FixItem n f _) -> ppr f <+> ppr n)
		  (nameEnvElts env)

dupFixityDecl loc rdr_name
  = vcat [ptext SLIT("Multiple fixity declarations for") <+> quotes (ppr rdr_name),
	  ptext SLIT("also at ") <+> ppr loc
	]
\end{code}


%*********************************************************
%*						 	 *
	Source-code deprecations declarations
%*							 *
%*********************************************************

For deprecations, all we do is check that the names are in scope.
It's only imported deprecations, dealt with in RnIfaces, that we
gather them together.

\begin{code}
rnSrcDeprecDecls :: [LDeprecDecl RdrName] -> RnM Deprecations
rnSrcDeprecDecls [] 
  = returnM NoDeprecs

rnSrcDeprecDecls decls
  = mappM (addLocM rn_deprec) decls	`thenM` \ pairs ->
    returnM (DeprecSome (mkNameEnv (catMaybes pairs)))
 where
   rn_deprec (Deprecation rdr_name txt)
     = lookupTopBndrRn rdr_name	`thenM` \ name ->
       returnM (Just (name, (rdrNameOcc rdr_name, txt)))

checkModDeprec :: Maybe DeprecTxt -> Deprecations
-- Check for a module deprecation; done once at top level
checkModDeprec Nothing    = NoDeprecs
checkModDeprec (Just txt) = DeprecAll txt
\end{code}

%*********************************************************
%*							*
\subsection{Source code declarations}
%*							*
%*********************************************************

\begin{code}
rnDefaultDecl (DefaultDecl tys)
  = mapFvRn (rnHsTypeFVs doc_str) tys	`thenM` \ (tys', fvs) ->
    returnM (DefaultDecl tys', fvs)
  where
    doc_str = text "In a `default' declaration"
\end{code}

%*********************************************************
%*							*
		Bindings
%*							*
%*********************************************************

These chaps are here, rather than in TcBinds, so that there
is just one hi-boot file (for RnSource).  rnSrcDecls is part
of the loop too, and it must be defined in this module.

\begin{code}
rnBindGroups :: [HsBindGroup RdrName] -> RnM ([HsBindGroup Name], DefUses)
-- This version assumes that the binders are already in scope
-- It's used only in 'mdo'
rnBindGroups []
   = returnM ([], emptyDUs)
rnBindGroups [HsBindGroup bind sigs _]
   = rnBinds NotTopLevel bind sigs
rnBindGroups b@[HsIPBinds bind]
   = do addErr (badIpBinds b)	
	returnM ([], emptyDUs)
rnBindGroups _
   = panic "rnBindGroups"

rnBindGroupsAndThen 
  :: [HsBindGroup RdrName]
  -> ([HsBindGroup Name] -> RnM (result, FreeVars))
  -> RnM (result, FreeVars)
-- This version (a) assumes that the binding vars are not already in scope
--		(b) removes the binders from the free vars of the thing inside
-- The parser doesn't produce ThenBinds
rnBindGroupsAndThen [] thing_inside
  = thing_inside []
rnBindGroupsAndThen [HsBindGroup bind sigs _] thing_inside
  = rnBindsAndThen bind sigs $ \ groups -> thing_inside groups
rnBindGroupsAndThen [HsIPBinds binds] thing_inside
  = rnIPBinds binds			`thenM` \ (binds',fv_binds) ->
    thing_inside [HsIPBinds binds']	`thenM` \ (thing, fvs_thing) ->
    returnM (thing, fvs_thing `plusFV` fv_binds)

rnIPBinds [] = returnM ([], emptyFVs)
rnIPBinds (bind : binds)
  = wrapLocFstM rnIPBind bind	`thenM` \ (bind', fvBind) ->
    rnIPBinds binds		`thenM` \ (binds',fvBinds) ->
    returnM (bind' : binds', fvBind `plusFV` fvBinds)

rnIPBind (IPBind n expr)
  = newIPNameRn  n		`thenM` \ name ->
    rnLExpr expr		`thenM` \ (expr',fvExpr) ->
    return (IPBind name expr', fvExpr)

badIpBinds binds
  = hang (ptext SLIT("Implicit-parameter bindings illegal in 'mdo':")) 4
	 (ppr binds)
\end{code}


%*********************************************************
%*							*
\subsection{Foreign declarations}
%*							*
%*********************************************************

\begin{code}
rnHsForeignDecl (ForeignImport name ty spec isDeprec)
  = lookupLocatedTopBndrRn name	        `thenM` \ name' ->
    rnHsTypeFVs (fo_decl_msg name) ty	`thenM` \ (ty', fvs) ->
    returnM (ForeignImport name' ty' spec isDeprec, fvs)

rnHsForeignDecl (ForeignExport name ty spec isDeprec)
  = lookupLocatedOccRn name	        `thenM` \ name' ->
    rnHsTypeFVs (fo_decl_msg name) ty  	`thenM` \ (ty', fvs) ->
    returnM (ForeignExport name' ty' spec isDeprec, fvs )
	-- NB: a foreign export is an *occurrence site* for name, so 
	--     we add it to the free-variable list.  It might, for example,
	--     be imported from another module

fo_decl_msg name = ptext SLIT("In the foreign declaration for") <+> ppr name
\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations}
%*							*
%*********************************************************

\begin{code}
rnSrcInstDecl (InstDecl inst_ty mbinds uprags)
	-- Used for both source and interface file decls
  = rnHsSigType (text "an instance decl") inst_ty	`thenM` \ inst_ty' ->

	-- Rename the bindings
	-- The typechecker (not the renamer) checks that all 
	-- the bindings are for the right class
    let
	meth_doc    = text "In the bindings in an instance declaration"
	meth_names  = collectHsBindLocatedBinders mbinds
	(inst_tyvars, _, cls,_) = splitHsInstDeclTy (unLoc inst_ty')
    in
    checkDupNames meth_doc meth_names 	`thenM_`
    extendTyVarEnvForMethodBinds inst_tyvars (		
	-- (Slightly strangely) the forall-d tyvars scope over
	-- the method bindings too
	rnMethodBinds cls [] mbinds
    )						`thenM` \ (mbinds', meth_fvs) ->
	-- Rename the prags and signatures.
	-- Note that the type variables are not in scope here,
	-- so that	instance Eq a => Eq (T a) where
	--			{-# SPECIALISE instance Eq a => Eq (T [a]) #-}
	-- works OK. 
	--
	-- But the (unqualified) method names are in scope
    let 
	binders = collectHsBindBinders mbinds'
    in
    bindLocalNames binders (renameSigs uprags)			`thenM` \ uprags' ->
    checkSigs (okInstDclSig (mkNameSet binders)) uprags'	`thenM_`

    returnM (InstDecl inst_ty' mbinds' uprags',
	     meth_fvs `plusFV` hsSigsFVs uprags'
		      `plusFV` extractHsTyNames inst_ty')
\end{code}

For the method bindings in class and instance decls, we extend the 
type variable environment iff -fglasgow-exts

\begin{code}
extendTyVarEnvForMethodBinds tyvars thing_inside
  = doptM Opt_GlasgowExts			`thenM` \ opt_GlasgowExts ->
    if opt_GlasgowExts then
	extendTyVarEnvFVRn (map hsLTyVarName tyvars) thing_inside
    else
	thing_inside
\end{code}


%*********************************************************
%*							*
\subsection{Rules}
%*							*
%*********************************************************

\begin{code}
rnHsRuleDecl (HsRule rule_name act vars lhs rhs)
  = bindPatSigTyVarsFV (collectRuleBndrSigTys vars)	$

    bindLocatedLocalsFV doc (map get_var vars)		$ \ ids ->
    mapFvRn rn_var (vars `zip` ids)		`thenM` \ (vars', fv_vars) ->

    rnLExpr lhs					`thenM` \ (lhs', fv_lhs) ->
    rnLExpr rhs					`thenM` \ (rhs', fv_rhs) ->
    let
	mb_bad = validRuleLhs ids lhs'
    in
    checkErr (isNothing mb_bad)
	     (badRuleLhsErr rule_name lhs' mb_bad)	`thenM_`
    let
	bad_vars = [var | var <- ids, not (var `elemNameSet` fv_lhs)]
    in
    mappM (addErr . badRuleVar rule_name) bad_vars	`thenM_`
    returnM (HsRule rule_name act vars' lhs' rhs',
	     fv_vars `plusFV` fv_lhs `plusFV` fv_rhs)
  where
    doc = text "In the transformation rule" <+> ftext rule_name
  
    get_var (RuleBndr v)      = v
    get_var (RuleBndrSig v _) = v

    rn_var (RuleBndr (L loc v), id)
	= returnM (RuleBndr (L loc id), emptyFVs)
    rn_var (RuleBndrSig (L loc v) t, id)
	= rnHsTypeFVs doc t	`thenM` \ (t', fvs) ->
	  returnM (RuleBndrSig (L loc id) t', fvs)
\end{code}

Check the shape of a transformation rule LHS.  Currently
we only allow LHSs of the form @(f e1 .. en)@, where @f@ is
not one of the @forall@'d variables.  We also restrict the form of the LHS so
that it may be plausibly matched.  Basically you only get to write ordinary 
applications.  (E.g. a case expression is not allowed: too elaborate.)

NB: if you add new cases here, make sure you add new ones to TcRule.ruleLhsTvs

\begin{code}
validRuleLhs :: [Name] -> LHsExpr Name -> Maybe (HsExpr Name)
-- Nothing => OK
-- Just e  => Not ok, and e is the offending expression
validRuleLhs foralls lhs
  = checkl lhs
  where
    checkl (L loc e) = check e

    check (OpApp e1 op _ e2)		  = checkl op `seqMaybe` checkl_e e1 `seqMaybe` checkl_e e2
    check (HsApp e1 e2) 		  = checkl e1 `seqMaybe` checkl_e e2
    check (HsVar v) | v `notElem` foralls = Nothing
    check other				  = Just other 	-- Failure

    checkl_e (L loc e) = check_e e

    check_e (HsVar v)     = Nothing
    check_e (HsPar e) 	  = checkl_e e
    check_e (HsLit e) 	  = Nothing
    check_e (HsOverLit e) = Nothing

    check_e (OpApp e1 op _ e2) 	 = checkl_e e1 `seqMaybe` checkl_e op `seqMaybe` checkl_e e2
    check_e (HsApp e1 e2)      	 = checkl_e e1 `seqMaybe` checkl_e e2
    check_e (NegApp e _)       	 = checkl_e e
    check_e (ExplicitList _ es)	 = checkl_es es
    check_e (ExplicitTuple es _) = checkl_es es
    check_e other		 = Just other	-- Fails

    checkl_es es = foldr (seqMaybe . checkl_e) Nothing es

badRuleLhsErr name lhs (Just bad_e)
  = sep [ptext SLIT("Rule") <+> ftext name <> colon,
	 nest 4 (vcat [ptext SLIT("Illegal expression:") <+> ppr bad_e, 
		       ptext SLIT("in left-hand side:") <+> ppr lhs])]
    $$
    ptext SLIT("LHS must be of form (f e1 .. en) where f is not forall'd")

badRuleVar name var
  = sep [ptext SLIT("Rule") <+> doubleQuotes (ftext name) <> colon,
	 ptext SLIT("Forall'd variable") <+> quotes (ppr var) <+> 
		ptext SLIT("does not appear on left hand side")]
\end{code}


%*********************************************************
%*							*
\subsection{Type, class and iface sig declarations}
%*							*
%*********************************************************

@rnTyDecl@ uses the `global name function' to create a new type
declaration in which local names have been replaced by their original
names, reporting any unknown names.

Renaming type variables is a pain. Because they now contain uniques,
it is necessary to pass in an association list which maps a parsed
tyvar to its @Name@ representation.
In some cases (type signatures of values),
it is even necessary to go over the type first
in order to get the set of tyvars used by it, make an assoc list,
and then go over it again to rename the tyvars!
However, we can also do some scoping checks at the same time.

\begin{code}
rnTyClDecl (ForeignType {tcdLName = name, tcdFoType = fo_type, tcdExtName = ext_name})
  = lookupLocatedTopBndrRn name		`thenM` \ name' ->
    returnM (ForeignType {tcdLName = name', tcdFoType = fo_type, tcdExtName = ext_name},
	     emptyFVs)

rnTyClDecl (TyData {tcdND = new_or_data, tcdCtxt = context, tcdLName = tycon,
		    tcdTyVars = tyvars, tcdCons = condecls, 
		    tcdKindSig = sig, tcdDerivs = derivs})
  | is_vanilla	-- Normal Haskell data type decl
  = ASSERT( isNothing sig )	-- In normal H98 form, kind signature on the 
				-- data type is syntactically illegal
    bindTyVarsRn data_doc tyvars		$ \ tyvars' ->
    do	{ tycon' <- lookupLocatedTopBndrRn tycon
	; context' <- rnContext data_doc context
	; (derivs', deriv_fvs) <- rn_derivs derivs
	; checkDupNames data_doc con_names
	; condecls' <- rnConDecls (unLoc tycon') condecls
	; returnM (TyData {tcdND = new_or_data, tcdCtxt = context', tcdLName = tycon',
			   tcdTyVars = tyvars', tcdKindSig = Nothing, tcdCons = condecls', 
			   tcdDerivs = derivs'}, 
		   delFVs (map hsLTyVarName tyvars')	$
	     	   extractHsCtxtTyNames context'	`plusFV`
	     	   plusFVs (map conDeclFVs condecls') `plusFV`
	     	   deriv_fvs) }

  | otherwise	-- GADT
  = ASSERT( null (unLoc context) )
    do	{ tycon' <- lookupLocatedTopBndrRn tycon
	; tyvars' <- bindTyVarsRn data_doc tyvars 
				  (\ tyvars' -> return tyvars')
		-- For GADTs, the type variables in the declaration 
		-- do not scope over the constructor signatures
		-- 	data T a where { T1 :: forall b. b-> b }
	; (derivs', deriv_fvs) <- rn_derivs derivs
	; checkDupNames data_doc con_names
	; condecls' <- rnConDecls (unLoc tycon') condecls
	; returnM (TyData {tcdND = new_or_data, tcdCtxt = noLoc [], tcdLName = tycon',
			   tcdTyVars = tyvars', tcdCons = condecls', tcdKindSig = sig,
			   tcdDerivs = derivs'}, 
	     	   plusFVs (map conDeclFVs condecls') `plusFV` deriv_fvs) }

  where
    is_vanilla = case condecls of	-- Yuk
		     [] 		   -> True
		     L _ (ConDecl {}) : _  -> True
		     other		   -> False

    data_doc = text "In the data type declaration for" <+> quotes (ppr tycon)
    con_names = map con_names_helper condecls

    con_names_helper (L _ (ConDecl n _ _ _)) = n
    con_names_helper (L _ (GadtDecl n _)) = n

    rn_derivs Nothing   = returnM (Nothing, emptyFVs)
    rn_derivs (Just ds) = rnLHsTypes data_doc ds	`thenM` \ ds' -> 
			  returnM (Just ds', extractHsTyNames_s ds')
    
rnTyClDecl (TySynonym {tcdLName = name, tcdTyVars = tyvars, tcdSynRhs = ty})
  = lookupLocatedTopBndrRn name			`thenM` \ name' ->
    bindTyVarsRn syn_doc tyvars 		$ \ tyvars' ->
    rnHsTypeFVs syn_doc ty			`thenM` \ (ty', fvs) ->
    returnM (TySynonym {tcdLName = name', tcdTyVars = tyvars', 
			tcdSynRhs = ty'},
	     delFVs (map hsLTyVarName tyvars') fvs)
  where
    syn_doc = text "In the declaration for type synonym" <+> quotes (ppr name)

rnTyClDecl (ClassDecl {tcdCtxt = context, tcdLName = cname, 
		       tcdTyVars = tyvars, tcdFDs = fds, tcdSigs = sigs, 
		       tcdMeths = mbinds})
  = lookupLocatedTopBndrRn cname		`thenM` \ cname' ->

	-- Tyvars scope over superclass context and method signatures
    bindTyVarsRn cls_doc tyvars			( \ tyvars' ->
	rnContext cls_doc context	`thenM` \ context' ->
	rnFds cls_doc fds		`thenM` \ fds' ->
	renameSigs sigs			`thenM` \ sigs' ->
	returnM   (tyvars', context', fds', sigs')
    )	`thenM` \ (tyvars', context', fds', sigs') ->

	-- Check the signatures
	-- First process the class op sigs (op_sigs), then the fixity sigs (non_op_sigs).
    let
	sig_rdr_names_w_locs   = [op | L _ (Sig op _) <- sigs]
    in
    checkDupNames sig_doc sig_rdr_names_w_locs	`thenM_` 
    checkSigs okClsDclSig sigs'				`thenM_`
	-- Typechecker is responsible for checking that we only
	-- give default-method bindings for things in this class.
	-- The renamer *could* check this for class decls, but can't
	-- for instance decls.

   	-- The newLocals call is tiresome: given a generic class decl
	--	class C a where
	--	  op :: a -> a
	--	  op {| x+y |} (Inl a) = ...
	--	  op {| x+y |} (Inr b) = ...
	--	  op {| a*b |} (a*b)   = ...
	-- we want to name both "x" tyvars with the same unique, so that they are
	-- easy to group together in the typechecker.  
    extendTyVarEnvForMethodBinds tyvars' (
   	 getLocalRdrEnv					`thenM` \ name_env ->
   	 let
 	     meth_rdr_names_w_locs = collectHsBindLocatedBinders mbinds
 	     gen_rdr_tyvars_w_locs = 
		[ tv | tv <- extractGenericPatTyVars mbinds,
 		      not (unLoc tv `elemLocalRdrEnv` name_env) ]
   	 in
   	 checkDupNames meth_doc meth_rdr_names_w_locs	`thenM_`
   	 newLocalsRn gen_rdr_tyvars_w_locs	`thenM` \ gen_tyvars ->
   	 rnMethodBinds (unLoc cname') gen_tyvars mbinds
    ) `thenM` \ (mbinds', meth_fvs) ->

    returnM (ClassDecl { tcdCtxt = context', tcdLName = cname', tcdTyVars = tyvars',
			 tcdFDs = fds', tcdSigs = sigs', tcdMeths = mbinds'},
	     delFVs (map hsLTyVarName tyvars')	$
	     extractHsCtxtTyNames context'	    `plusFV`
	     plusFVs (map extractFunDepNames (map unLoc fds'))  `plusFV`
	     hsSigsFVs sigs'		  	    `plusFV`
	     meth_fvs)
  where
    meth_doc = text "In the default-methods for class"	<+> ppr cname
    cls_doc  = text "In the declaration for class" 	<+> ppr cname
    sig_doc  = text "In the signatures for class"  	<+> ppr cname
\end{code}

%*********************************************************
%*							*
\subsection{Support code for type/data declarations}
%*							*
%*********************************************************

\begin{code}
rnConDecls :: Name -> [LConDecl RdrName] -> RnM [LConDecl Name]
rnConDecls tycon condecls
  = mappM (wrapLocM rnConDecl) condecls

rnConDecl :: ConDecl RdrName -> RnM (ConDecl Name)
rnConDecl (ConDecl name tvs cxt details)
  = addLocM checkConName name		`thenM_` 
    lookupLocatedTopBndrRn name		`thenM` \ new_name ->

    bindTyVarsRn doc tvs 		$ \ new_tyvars ->
    rnContext doc cxt			`thenM` \ new_context ->
    rnConDetails doc details		`thenM` \ new_details -> 
    returnM (ConDecl new_name new_tyvars new_context new_details)
  where
    doc = text "In the definition of data constructor" <+> quotes (ppr name)

rnConDecl (GadtDecl name ty) 
  = addLocM checkConName name		`thenM_` 
    lookupLocatedTopBndrRn name		`thenM` \ new_name ->
    rnHsSigType doc ty                  `thenM` \ new_ty ->
    returnM (GadtDecl new_name new_ty)
  where
    doc = text "In the definition of data constructor" <+> quotes (ppr name)

rnConDetails doc (PrefixCon tys)
  = mappM (rnLHsType doc) tys	`thenM` \ new_tys  ->
    returnM (PrefixCon new_tys)

rnConDetails doc (InfixCon ty1 ty2)
  = rnLHsType doc ty1  		`thenM` \ new_ty1 ->
    rnLHsType doc ty2  		`thenM` \ new_ty2 ->
    returnM (InfixCon new_ty1 new_ty2)

rnConDetails doc (RecCon fields)
  = checkDupNames doc field_names	`thenM_`
    mappM (rnField doc) fields		`thenM` \ new_fields ->
    returnM (RecCon new_fields)
  where
    field_names = [fld | (fld, _) <- fields]

rnField doc (name, ty)
  = lookupLocatedTopBndrRn name	`thenM` \ new_name ->
    rnLHsType doc ty		`thenM` \ new_ty ->
    returnM (new_name, new_ty) 

-- This data decl will parse OK
--	data T = a Int
-- treating "a" as the constructor.
-- It is really hard to make the parser spot this malformation.
-- So the renamer has to check that the constructor is legal
--
-- We can get an operator as the constructor, even in the prefix form:
--	data T = :% Int Int
-- from interface files, which always print in prefix form

checkConName name = checkErr (isRdrDataCon name) (badDataCon name)

badDataCon name
   = hsep [ptext SLIT("Illegal data constructor name"), quotes (ppr name)]
\end{code}


%*********************************************************
%*							*
\subsection{Support code to rename types}
%*							*
%*********************************************************

\begin{code}
rnFds :: SDoc -> [Located (FunDep RdrName)] -> RnM [Located (FunDep Name)]

rnFds doc fds
  = mappM (wrapLocM rn_fds) fds
  where
    rn_fds (tys1, tys2)
      =	rnHsTyVars doc tys1		`thenM` \ tys1' ->
	rnHsTyVars doc tys2		`thenM` \ tys2' ->
	returnM (tys1', tys2')

rnHsTyVars doc tvs  = mappM (rnHsTyvar doc) tvs
rnHsTyvar doc tyvar = lookupOccRn tyvar
\end{code}


%*********************************************************
%*							*
		Splices
%*							*
%*********************************************************

\begin{code}
rnSplice :: HsSplice RdrName -> RnM (HsSplice Name, FreeVars)
rnSplice (HsSplice n expr)
  = checkTH expr "splice"	`thenM_`
    getSrcSpanM 		`thenM` \ loc ->
    newLocalsRn [L loc n]	`thenM` \ [n'] ->
    rnLExpr expr 		`thenM` \ (expr', fvs) ->
    returnM (HsSplice n' expr', fvs)
\end{code}
