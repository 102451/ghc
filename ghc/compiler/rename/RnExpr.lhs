%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnExpr]{Renaming of expressions}

Basically dependency analysis.

Handles @Match@, @GRHSs@, @HsExpr@, and @Qualifier@ datatypes.  In
general, all of these functions return a renamed thing, and a set of
free variables.

\begin{code}
module RnExpr (
	rnMatch, rnGRHSs, rnPat, rnExpr, rnExprs, rnStmt,
	checkPrecMatch
   ) where

#include "HsVersions.h"

import {-# SOURCE #-} RnBinds  ( rnBinds ) 

import HsSyn
import RdrHsSyn
import RnHsSyn
import RnMonad
import RnEnv
import RnTypes		( rnHsTypeFVs, precParseErr, sectionPrecErr )
import CmdLineOpts	( DynFlag(..), opt_IgnoreAsserts )
import Literal		( inIntRange, inCharRange )
import BasicTypes	( Fixity(..), FixityDirection(..), IPName(..),
			  defaultFixity, negateFixity, compareFixity )
import PrelNames	( hasKey, assertIdKey, 
			  eqClassName, foldrName, buildName, eqStringName,
			  cCallableClassName, cReturnableClassName, 
			  monadClassName, enumClassName, ordClassName,
			  ratioDataConName, splitName, fstName, sndName,
			  ioDataConName, plusIntegerName, timesIntegerName,
			  assertErr_RDR,
			  replicatePName, mapPName, filterPName,
			  falseDataConName, trueDataConName, crossPName,
			  zipPName, lengthPName, indexPName, toPName,
			  enumFromToPName, enumFromThenToPName )
import TysPrim		( charPrimTyCon, addrPrimTyCon, intPrimTyCon, 
			  floatPrimTyCon, doublePrimTyCon )
import TysWiredIn	( intTyCon )
import Name		( NamedThing(..), mkSystemName, nameSrcLoc )
import NameSet
import UnicodeUtil	( stringToUtf8 )
import UniqFM		( isNullUFM )
import UniqSet		( emptyUniqSet )
import List		( intersectBy )
import ListSetOps	( removeDups )
import Outputable
import FastString
\end{code}


*********************************************************
*							*
\subsection{Patterns}
*							*
*********************************************************

\begin{code}
rnPat :: RdrNamePat -> RnMS (RenamedPat, FreeVars)

rnPat WildPatIn = returnRn (WildPatIn, emptyFVs)

rnPat (VarPatIn name)
  = lookupBndrRn  name			`thenRn` \ vname ->
    returnRn (VarPatIn vname, emptyFVs)

rnPat (SigPatIn pat ty)
  = doptRn Opt_GlasgowExts `thenRn` \ glaExts ->
    
    if glaExts
    then rnPat pat		`thenRn` \ (pat', fvs1) ->
         rnHsTypeFVs doc ty	`thenRn` \ (ty',  fvs2) ->
         returnRn (SigPatIn pat' ty', fvs1 `plusFV` fvs2)

    else addErrRn (patSigErr ty)	`thenRn_`
         rnPat pat
  where
    doc = text "a pattern type-signature"
    
rnPat (LitPatIn s@(HsString _)) 
  = returnRn (LitPatIn s, unitFV eqStringName)

rnPat (LitPatIn lit) 
  = litFVs lit		`thenRn` \ fvs ->
    returnRn (LitPatIn lit, fvs) 

rnPat (NPatIn lit) 
  = rnOverLit lit			`thenRn` \ (lit', fvs1) ->
    returnRn (NPatIn lit', fvs1 `addOneFV` eqClassName)	-- Needed to find equality on pattern

rnPat (NPlusKPatIn name lit minus)
  = rnOverLit lit			`thenRn` \ (lit', fvs) ->
    lookupBndrRn name			`thenRn` \ name' ->
    lookupSyntaxName minus		`thenRn` \ minus' ->
    returnRn (NPlusKPatIn name' lit' minus', fvs `addOneFV` ordClassName `addOneFV` minus')

rnPat (LazyPatIn pat)
  = rnPat pat		`thenRn` \ (pat', fvs) ->
    returnRn (LazyPatIn pat', fvs)

rnPat (AsPatIn name pat)
  = rnPat pat		`thenRn` \ (pat', fvs) ->
    lookupBndrRn name	`thenRn` \ vname ->
    returnRn (AsPatIn vname pat', fvs)

rnPat (ConPatIn con pats)
  = lookupOccRn con		`thenRn` \ con' ->
    mapFvRn rnPat pats  	`thenRn` \ (patslist, fvs) ->
    returnRn (ConPatIn con' patslist, fvs `addOneFV` con')

rnPat (ConOpPatIn pat1 con _ pat2)
  = rnPat pat1		`thenRn` \ (pat1', fvs1) ->
    lookupOccRn con	`thenRn` \ con' ->
    rnPat pat2		`thenRn` \ (pat2', fvs2) ->

    getModeRn		`thenRn` \ mode ->
	-- See comments with rnExpr (OpApp ...)
    (if isInterfaceMode mode
	then returnRn (ConOpPatIn pat1' con' defaultFixity pat2')
	else lookupFixityRn con'	`thenRn` \ fixity ->
	     mkConOpPatRn pat1' con' fixity pat2'
    )								`thenRn` \ pat' ->
    returnRn (pat', fvs1 `plusFV` fvs2 `addOneFV` con')

rnPat (ParPatIn pat)
  = rnPat pat		`thenRn` \ (pat', fvs) ->
    returnRn (ParPatIn pat', fvs)

rnPat (ListPatIn pats)
  = mapFvRn rnPat pats			`thenRn` \ (patslist, fvs) ->
    returnRn (ListPatIn patslist, fvs `addOneFV` listTyCon_name)

rnPat (PArrPatIn pats)
  = mapFvRn rnPat pats			`thenRn` \ (patslist, fvs) ->
    returnRn (PArrPatIn patslist, 
	      fvs `plusFV` implicit_fvs `addOneFV` parrTyCon_name)
  where
    implicit_fvs = mkFVs [lengthPName, indexPName]

rnPat (TuplePatIn pats boxed)
  = mapFvRn rnPat pats					   `thenRn` \ (patslist, fvs) ->
    returnRn (TuplePatIn patslist boxed, fvs `addOneFV` tycon_name)
  where
    tycon_name = tupleTyCon_name boxed (length pats)

rnPat (RecPatIn con rpats)
  = lookupOccRn con 	`thenRn` \ con' ->
    rnRpats rpats	`thenRn` \ (rpats', fvs) ->
    returnRn (RecPatIn con' rpats', fvs `addOneFV` con')

rnPat (TypePatIn name)
  = rnHsTypeFVs (text "type pattern") name	`thenRn` \ (name', fvs) ->
    returnRn (TypePatIn name', fvs)
\end{code}

************************************************************************
*									*
\subsection{Match}
*									*
************************************************************************

\begin{code}
rnMatch :: HsMatchContext RdrName -> RdrNameMatch -> RnMS (RenamedMatch, FreeVars)

rnMatch ctxt match@(Match pats maybe_rhs_sig grhss)
  = pushSrcLocRn (getMatchLoc match)	$

	-- Bind pattern-bound type variables
    let
	rhs_sig_tys =  case maybe_rhs_sig of
				Nothing -> []
				Just ty -> [ty]
	pat_sig_tys = collectSigTysFromPats pats
	doc_sig     = text "In a result type-signature"
 	doc_pat     = pprMatchContext ctxt
    in
    bindPatSigTyVars (rhs_sig_tys ++ pat_sig_tys)	$ 

	-- Note that we do a single bindLocalsRn for all the
	-- matches together, so that we spot the repeated variable in
	--	f x x = 1
    bindLocalsFVRn doc_pat (collectPatsBinders pats)	$ \ new_binders ->

    mapFvRn rnPat pats			`thenRn` \ (pats', pat_fvs) ->
    rnGRHSs grhss			`thenRn` \ (grhss', grhss_fvs) ->
    doptRn Opt_GlasgowExts		`thenRn` \ opt_GlasgowExts ->
    (case maybe_rhs_sig of
	Nothing -> returnRn (Nothing, emptyFVs)
	Just ty | opt_GlasgowExts -> rnHsTypeFVs doc_sig ty	`thenRn` \ (ty', ty_fvs) ->
				     returnRn (Just ty', ty_fvs)
		| otherwise	  -> addErrRn (patSigErr ty)	`thenRn_`
				     returnRn (Nothing, emptyFVs)
    )					`thenRn` \ (maybe_rhs_sig', ty_fvs) ->

    let
	binder_set     = mkNameSet new_binders
	unused_binders = nameSetToList (binder_set `minusNameSet` grhss_fvs)
	all_fvs	       = grhss_fvs `plusFV` pat_fvs `plusFV` ty_fvs
    in
    warnUnusedMatches unused_binders		`thenRn_`
    
    returnRn (Match pats' maybe_rhs_sig' grhss', all_fvs)
	-- The bindLocals and bindTyVars will remove the bound FVs
\end{code}


%************************************************************************
%*									*
\subsubsection{Guarded right-hand sides (GRHSs)}
%*									*
%************************************************************************

\begin{code}
rnGRHSs :: RdrNameGRHSs -> RnMS (RenamedGRHSs, FreeVars)

rnGRHSs (GRHSs grhss binds _)
  = rnBinds binds		$ \ binds' ->
    mapFvRn rnGRHS grhss	`thenRn` \ (grhss', fvGRHSs) ->
    returnRn (GRHSs grhss' binds' placeHolderType, fvGRHSs)

rnGRHS (GRHS guarded locn)
  = doptRn Opt_GlasgowExts		`thenRn` \ opt_GlasgowExts ->
    pushSrcLocRn locn $		    
    (if not (opt_GlasgowExts || is_standard_guard guarded) then
		addWarnRn (nonStdGuardErr guarded)
     else
		returnRn ()
    )		`thenRn_`

    rnStmts guarded	`thenRn` \ ((_, guarded'), fvs) ->
    returnRn (GRHS guarded' locn, fvs)
  where
	-- Standard Haskell 1.4 guards are just a single boolean
	-- expression, rather than a list of qualifiers as in the
	-- Glasgow extension
    is_standard_guard [ResultStmt _ _]                 = True
    is_standard_guard [ExprStmt _ _ _, ResultStmt _ _] = True
    is_standard_guard other	      		       = False
\end{code}

%************************************************************************
%*									*
\subsubsection{Expressions}
%*									*
%************************************************************************

\begin{code}
rnExprs :: [RdrNameHsExpr] -> RnMS ([RenamedHsExpr], FreeVars)
rnExprs ls = rnExprs' ls emptyUniqSet
 where
  rnExprs' [] acc = returnRn ([], acc)
  rnExprs' (expr:exprs) acc
   = rnExpr expr 	        `thenRn` \ (expr', fvExpr) ->

	-- Now we do a "seq" on the free vars because typically it's small
	-- or empty, especially in very long lists of constants
    let
	acc' = acc `plusFV` fvExpr
    in
    (grubby_seqNameSet acc' rnExprs') exprs acc'	`thenRn` \ (exprs', fvExprs) ->
    returnRn (expr':exprs', fvExprs)

-- Grubby little function to do "seq" on namesets; replace by proper seq when GHC can do seq
grubby_seqNameSet ns result | isNullUFM ns = result
			    | otherwise    = result
\end{code}

Variables. We look up the variable and return the resulting name. 

\begin{code}
rnExpr :: RdrNameHsExpr -> RnMS (RenamedHsExpr, FreeVars)

rnExpr (HsVar v)
  = lookupOccRn v	`thenRn` \ name ->
    if name `hasKey` assertIdKey then
	-- We expand it to (GHCerr.assert__ location)
        mkAssertExpr
    else
        -- The normal case
       returnRn (HsVar name, unitFV name)

rnExpr (HsIPVar v)
  = newIPName v			`thenRn` \ name ->
    let 
	fvs = case name of
		Linear _  -> mkFVs [splitName, fstName, sndName]
		Dupable _ -> emptyFVs 
    in   
    returnRn (HsIPVar name, fvs)

rnExpr (HsLit lit) 
  = litFVs lit		`thenRn` \ fvs -> 
    returnRn (HsLit lit, fvs)

rnExpr (HsOverLit lit) 
  = rnOverLit lit		`thenRn` \ (lit', fvs) ->
    returnRn (HsOverLit lit', fvs)

rnExpr (HsLam match)
  = rnMatch LambdaExpr match	`thenRn` \ (match', fvMatch) ->
    returnRn (HsLam match', fvMatch)

rnExpr (HsApp fun arg)
  = rnExpr fun		`thenRn` \ (fun',fvFun) ->
    rnExpr arg		`thenRn` \ (arg',fvArg) ->
    returnRn (HsApp fun' arg', fvFun `plusFV` fvArg)

rnExpr (OpApp e1 op _ e2) 
  = rnExpr e1				`thenRn` \ (e1', fv_e1) ->
    rnExpr e2				`thenRn` \ (e2', fv_e2) ->
    rnExpr op				`thenRn` \ (op'@(HsVar op_name), fv_op) ->

	-- Deal with fixity
	-- When renaming code synthesised from "deriving" declarations
	-- we're in Interface mode, and we should ignore fixity; assume
	-- that the deriving code generator got the association correct
	-- Don't even look up the fixity when in interface mode
    getModeRn				`thenRn` \ mode -> 
    (if isInterfaceMode mode
	then returnRn (OpApp e1' op' defaultFixity e2')
	else lookupFixityRn op_name		`thenRn` \ fixity ->
	     mkOpAppRn e1' op' fixity e2'
    )					`thenRn` \ final_e -> 

    returnRn (final_e,
	      fv_e1 `plusFV` fv_op `plusFV` fv_e2)

rnExpr (NegApp e neg_name)
  = rnExpr e			`thenRn` \ (e', fv_e) ->
    lookupSyntaxName neg_name	`thenRn` \ neg_name' ->
    mkNegAppRn e' neg_name'	`thenRn` \ final_e ->
    returnRn (final_e, fv_e `addOneFV` neg_name')

rnExpr (HsPar e)
  = rnExpr e 		`thenRn` \ (e', fvs_e) ->
    returnRn (HsPar e', fvs_e)

rnExpr section@(SectionL expr op)
  = rnExpr expr	 				`thenRn` \ (expr', fvs_expr) ->
    rnExpr op	 				`thenRn` \ (op', fvs_op) ->
    checkSectionPrec InfixL section op' expr' `thenRn_`
    returnRn (SectionL expr' op', fvs_op `plusFV` fvs_expr)

rnExpr section@(SectionR op expr)
  = rnExpr op	 				`thenRn` \ (op',   fvs_op) ->
    rnExpr expr	 				`thenRn` \ (expr', fvs_expr) ->
    checkSectionPrec InfixR section op' expr'	`thenRn_`
    returnRn (SectionR op' expr', fvs_op `plusFV` fvs_expr)

rnExpr (HsCCall fun args may_gc is_casm _)
	-- Check out the comment on RnIfaces.getNonWiredDataDecl about ccalls
  = lookupOrigNames []	`thenRn` \ implicit_fvs ->
    rnExprs args				`thenRn` \ (args', fvs_args) ->
    returnRn (HsCCall fun args' may_gc is_casm placeHolderType, 
	      fvs_args `plusFV` mkFVs [cCallableClassName, 
				       cReturnableClassName, 
				       ioDataConName])

rnExpr (HsSCC lbl expr)
  = rnExpr expr	 	`thenRn` \ (expr', fvs_expr) ->
    returnRn (HsSCC lbl expr', fvs_expr)

rnExpr (HsCase expr ms src_loc)
  = pushSrcLocRn src_loc $
    rnExpr expr		 		`thenRn` \ (new_expr, e_fvs) ->
    mapFvRn (rnMatch CaseAlt) ms	`thenRn` \ (new_ms, ms_fvs) ->
    returnRn (HsCase new_expr new_ms src_loc, e_fvs `plusFV` ms_fvs)

rnExpr (HsLet binds expr)
  = rnBinds binds		$ \ binds' ->
    rnExpr expr			 `thenRn` \ (expr',fvExpr) ->
    returnRn (HsLet binds' expr', fvExpr)

rnExpr (HsWith expr binds is_with)
  = warnCheckRn (not is_with) withWarning `thenRn_`
    rnExpr expr			`thenRn` \ (expr',fvExpr) ->
    rnIPBinds binds		`thenRn` \ (binds',fvBinds) ->
    returnRn (HsWith expr' binds' is_with, fvExpr `plusFV` fvBinds)

rnExpr e@(HsDo do_or_lc stmts src_loc)
  = pushSrcLocRn src_loc $
    rnStmts stmts			`thenRn` \ ((_, stmts'), fvs) ->
	-- check the statement list ends in an expression
    case last stmts' of {
	ResultStmt _ _ -> returnRn () ;
	_              -> addErrRn (doStmtListErr e)
    }					`thenRn_`
    returnRn (HsDo do_or_lc stmts' src_loc, fvs `plusFV` implicit_fvs)
  where
    implicit_fvs = case do_or_lc of
      PArrComp -> mkFVs [replicatePName, mapPName, filterPName,
			 falseDataConName, trueDataConName, crossPName,
			 zipPName]
      _        -> mkFVs [foldrName, buildName, monadClassName]
	-- Monad stuff should not be necessary for a list comprehension
	-- but the typechecker looks up the bind and return Ids anyway
	-- Oh well.

rnExpr (ExplicitList _ exps)
  = rnExprs exps		 	`thenRn` \ (exps', fvs) ->
    returnRn  (ExplicitList placeHolderType exps', fvs `addOneFV` listTyCon_name)

rnExpr (ExplicitPArr _ exps)
  = rnExprs exps		 	`thenRn` \ (exps', fvs) ->
    returnRn  (ExplicitPArr placeHolderType exps', 
	       fvs `addOneFV` toPName `addOneFV` parrTyCon_name)

rnExpr (ExplicitTuple exps boxity)
  = rnExprs exps	 			`thenRn` \ (exps', fvs) ->
    returnRn (ExplicitTuple exps' boxity, fvs `addOneFV` tycon_name)
  where
    tycon_name = tupleTyCon_name boxity (length exps)

rnExpr (RecordCon con_id rbinds)
  = lookupOccRn con_id 			`thenRn` \ conname ->
    rnRbinds "construction" rbinds	`thenRn` \ (rbinds', fvRbinds) ->
    returnRn (RecordCon conname rbinds', fvRbinds `addOneFV` conname)

rnExpr (RecordUpd expr rbinds)
  = rnExpr expr			`thenRn` \ (expr', fvExpr) ->
    rnRbinds "update" rbinds	`thenRn` \ (rbinds', fvRbinds) ->
    returnRn (RecordUpd expr' rbinds', fvExpr `plusFV` fvRbinds)

rnExpr (ExprWithTySig expr pty)
  = rnExpr expr			 			   `thenRn` \ (expr', fvExpr) ->
    rnHsTypeFVs (text "an expression type signature") pty  `thenRn` \ (pty', fvTy) ->
    returnRn (ExprWithTySig expr' pty', fvExpr `plusFV` fvTy)

rnExpr (HsIf p b1 b2 src_loc)
  = pushSrcLocRn src_loc $
    rnExpr p		`thenRn` \ (p', fvP) ->
    rnExpr b1		`thenRn` \ (b1', fvB1) ->
    rnExpr b2		`thenRn` \ (b2', fvB2) ->
    returnRn (HsIf p' b1' b2' src_loc, plusFVs [fvP, fvB1, fvB2])

rnExpr (HsType a)
  = rnHsTypeFVs doc a	`thenRn` \ (t, fvT) -> 
    returnRn (HsType t, fvT)
  where 
    doc = text "in a type argument"

rnExpr (ArithSeqIn seq)
  = rn_seq seq	 			`thenRn` \ (new_seq, fvs) ->
    returnRn (ArithSeqIn new_seq, fvs `addOneFV` enumClassName)
  where
    rn_seq (From expr)
     = rnExpr expr 	`thenRn` \ (expr', fvExpr) ->
       returnRn (From expr', fvExpr)

    rn_seq (FromThen expr1 expr2)
     = rnExpr expr1 	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       returnRn (FromThen expr1' expr2', fvExpr1 `plusFV` fvExpr2)

    rn_seq (FromTo expr1 expr2)
     = rnExpr expr1	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       returnRn (FromTo expr1' expr2', fvExpr1 `plusFV` fvExpr2)

    rn_seq (FromThenTo expr1 expr2 expr3)
     = rnExpr expr1	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       rnExpr expr3	`thenRn` \ (expr3', fvExpr3) ->
       returnRn (FromThenTo expr1' expr2' expr3',
		  plusFVs [fvExpr1, fvExpr2, fvExpr3])

rnExpr (PArrSeqIn seq)
  = rn_seq seq	 		       `thenRn` \ (new_seq, fvs) ->
    returnRn (PArrSeqIn new_seq, 
	      fvs `plusFV` mkFVs [enumFromToPName, enumFromThenToPName])
  where

    -- the parser shouldn't generate these two
    --
    rn_seq (From     _  ) = panic "RnExpr.rnExpr: Infinite parallel array!"
    rn_seq (FromThen _ _) = panic "RnExpr.rnExpr: Infinite parallel array!"

    rn_seq (FromTo expr1 expr2)
     = rnExpr expr1	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       returnRn (FromTo expr1' expr2', fvExpr1 `plusFV` fvExpr2)
    rn_seq (FromThenTo expr1 expr2 expr3)
     = rnExpr expr1	`thenRn` \ (expr1', fvExpr1) ->
       rnExpr expr2	`thenRn` \ (expr2', fvExpr2) ->
       rnExpr expr3	`thenRn` \ (expr3', fvExpr3) ->
       returnRn (FromThenTo expr1' expr2' expr3',
		  plusFVs [fvExpr1, fvExpr2, fvExpr3])
\end{code}

These three are pattern syntax appearing in expressions.
Since all the symbols are reservedops we can simply reject them.
We return a (bogus) EWildPat in each case.

\begin{code}
rnExpr e@EWildPat = addErrRn (patSynErr e)	`thenRn_`
		    returnRn (EWildPat, emptyFVs)

rnExpr e@(EAsPat _ _) = addErrRn (patSynErr e)	`thenRn_`
		        returnRn (EWildPat, emptyFVs)

rnExpr e@(ELazyPat _) = addErrRn (patSynErr e)	`thenRn_`
		        returnRn (EWildPat, emptyFVs)
\end{code}



%************************************************************************
%*									*
\subsubsection{@Rbinds@s and @Rpats@s: in record expressions}
%*									*
%************************************************************************

\begin{code}
rnRbinds str rbinds 
  = mapRn_ field_dup_err dup_fields	`thenRn_`
    mapFvRn rn_rbind rbinds		`thenRn` \ (rbinds', fvRbind) ->
    returnRn (rbinds', fvRbind)
  where
    (_, dup_fields) = removeDups compare [ f | (f,_,_) <- rbinds ]

    field_dup_err dups = addErrRn (dupFieldErr str dups)

    rn_rbind (field, expr, pun)
      = lookupGlobalOccRn field	`thenRn` \ fieldname ->
	rnExpr expr		`thenRn` \ (expr', fvExpr) ->
	returnRn ((fieldname, expr', pun), fvExpr `addOneFV` fieldname)

rnRpats rpats
  = mapRn_ field_dup_err dup_fields 	`thenRn_`
    mapFvRn rn_rpat rpats		`thenRn` \ (rpats', fvs) ->
    returnRn (rpats', fvs)
  where
    (_, dup_fields) = removeDups compare [ f | (f,_,_) <- rpats ]

    field_dup_err dups = addErrRn (dupFieldErr "pattern" dups)

    rn_rpat (field, pat, pun)
      = lookupGlobalOccRn field	`thenRn` \ fieldname ->
	rnPat pat		`thenRn` \ (pat', fvs) ->
	returnRn ((fieldname, pat', pun), fvs `addOneFV` fieldname)
\end{code}

%************************************************************************
%*									*
\subsubsection{@rnIPBinds@s: in implicit parameter bindings}		*
%*									*
%************************************************************************

\begin{code}
rnIPBinds [] = returnRn ([], emptyFVs)
rnIPBinds ((n, expr) : binds)
  = newIPName n			`thenRn` \ name ->
    rnExpr expr			`thenRn` \ (expr',fvExpr) ->
    rnIPBinds binds		`thenRn` \ (binds',fvBinds) ->
    returnRn ((name, expr') : binds', fvExpr `plusFV` fvBinds)

\end{code}

%************************************************************************
%*									*
\subsubsection{@Stmt@s: in @do@ expressions}
%*									*
%************************************************************************

Note that although some bound vars may appear in the free var set for
the first qual, these will eventually be removed by the caller. For
example, if we have @[p | r <- s, q <- r, p <- q]@, when doing
@[q <- r, p <- q]@, the free var set for @q <- r@ will
be @{r}@, and the free var set for the entire Quals will be @{r}@. This
@r@ will be removed only when we finally return from examining all the
Quals.

\begin{code}
rnStmts :: [RdrNameStmt]
	-> RnMS (([Name], [RenamedStmt]), FreeVars)

rnStmts []
  = returnRn (([], []), emptyFVs)

rnStmts (stmt:stmts)
  = getLocalNameEnv 		`thenRn` \ name_env ->
    rnStmt stmt				$ \ stmt' ->
    rnStmts stmts			`thenRn` \ ((binders, stmts'), fvs) ->
    returnRn ((binders, stmt' : stmts'), fvs)

rnStmt :: RdrNameStmt
       -> (RenamedStmt -> RnMS (([Name], a), FreeVars))
       -> RnMS (([Name], a), FreeVars)
-- The thing list of names returned is the list returned by the
-- thing_inside, plus the binders of the arguments stmt

-- Because of mutual recursion we have to pass in rnExpr.

rnStmt (ParStmt stmtss) thing_inside
  = mapFvRn rnStmts stmtss		`thenRn` \ (bndrstmtss, fv_stmtss) ->
    let binderss = map fst bndrstmtss
	checkBndrs all_bndrs bndrs
	  = checkRn (null (intersectBy eqOcc all_bndrs bndrs)) err `thenRn_`
	    returnRn (bndrs ++ all_bndrs)
	eqOcc n1 n2 = nameOccName n1 == nameOccName n2
	err = text "duplicate binding in parallel list comprehension"
    in
    foldlRn checkBndrs [] binderss	`thenRn` \ new_binders ->
    bindLocalNamesFV new_binders	$
    thing_inside (ParStmtOut bndrstmtss)`thenRn` \ ((rest_bndrs, result), fv_rest) ->
    returnRn ((new_binders ++ rest_bndrs, result), fv_stmtss `plusFV` fv_rest)

rnStmt (BindStmt pat expr src_loc) thing_inside
  = pushSrcLocRn src_loc $
    rnExpr expr					`thenRn` \ (expr', fv_expr) ->
    bindPatSigTyVars (collectSigTysFromPat pat)	$ 
    bindLocalsFVRn doc (collectPatBinders pat)	$ \ new_binders ->
    rnPat pat					`thenRn` \ (pat', fv_pat) ->
    thing_inside (BindStmt pat' expr' src_loc)	`thenRn` \ ((rest_binders, result), fvs) ->
    returnRn ((new_binders ++ rest_binders, result),
	      fv_expr `plusFV` fvs `plusFV` fv_pat)
  where
    doc = text "In a pattern in 'do' binding" 

rnStmt (ExprStmt expr _ src_loc) thing_inside
  = pushSrcLocRn src_loc $
    rnExpr expr 						`thenRn` \ (expr', fv_expr) ->
    thing_inside (ExprStmt expr' placeHolderType src_loc)	`thenRn` \ (result, fvs) ->
    returnRn (result, fv_expr `plusFV` fvs)

rnStmt (ResultStmt expr src_loc) thing_inside
  = pushSrcLocRn src_loc $
    rnExpr expr 				`thenRn` \ (expr', fv_expr) ->
    thing_inside (ResultStmt expr' src_loc)	`thenRn` \ (result, fvs) ->
    returnRn (result, fv_expr `plusFV` fvs)

rnStmt (LetStmt binds) thing_inside
  = rnBinds binds				$ \ binds' ->
    let new_binders = collectHsBinders binds' in
    thing_inside (LetStmt binds')    `thenRn` \ ((rest_binders, result), fvs) ->
    returnRn ((new_binders ++ rest_binders, result), fvs )
\end{code}

%************************************************************************
%*									*
\subsubsection{Precedence Parsing}
%*									*
%************************************************************************

@mkOpAppRn@ deals with operator fixities.  The argument expressions
are assumed to be already correctly arranged.  It needs the fixities
recorded in the OpApp nodes, because fixity info applies to the things
the programmer actually wrote, so you can't find it out from the Name.

Furthermore, the second argument is guaranteed not to be another
operator application.  Why? Because the parser parses all
operator appications left-associatively, EXCEPT negation, which
we need to handle specially.

\begin{code}
mkOpAppRn :: RenamedHsExpr			-- Left operand; already rearranged
	  -> RenamedHsExpr -> Fixity 		-- Operator and fixity
	  -> RenamedHsExpr			-- Right operand (not an OpApp, but might
						-- be a NegApp)
	  -> RnMS RenamedHsExpr

---------------------------
-- (e11 `op1` e12) `op2` e2
mkOpAppRn e1@(OpApp e11 op1 fix1 e12) op2 fix2 e2
  | nofix_error
  = addErrRn (precParseErr (ppr_op op1,fix1) (ppr_op op2,fix2))	`thenRn_`
    returnRn (OpApp e1 op2 fix2 e2)

  | associate_right
  = mkOpAppRn e12 op2 fix2 e2		`thenRn` \ new_e ->
    returnRn (OpApp e11 op1 fix1 new_e)
  where
    (nofix_error, associate_right) = compareFixity fix1 fix2

---------------------------
--	(- neg_arg) `op` e2
mkOpAppRn e1@(NegApp neg_arg neg_name) op2 fix2 e2
  | nofix_error
  = addErrRn (precParseErr (pp_prefix_minus,negateFixity) (ppr_op op2,fix2))	`thenRn_`
    returnRn (OpApp e1 op2 fix2 e2)

  | associate_right
  = mkOpAppRn neg_arg op2 fix2 e2	`thenRn` \ new_e ->
    returnRn (NegApp new_e neg_name)
  where
    (nofix_error, associate_right) = compareFixity negateFixity fix2

---------------------------
--	e1 `op` - neg_arg
mkOpAppRn e1 op1 fix1 e2@(NegApp neg_arg _)	-- NegApp can occur on the right
  | not associate_right				-- We *want* right association
  = addErrRn (precParseErr (ppr_op op1, fix1) (pp_prefix_minus, negateFixity))	`thenRn_`
    returnRn (OpApp e1 op1 fix1 e2)
  where
    (_, associate_right) = compareFixity fix1 negateFixity

---------------------------
--	Default case
mkOpAppRn e1 op fix e2 			-- Default case, no rearrangment
  = ASSERT2( right_op_ok fix e2,
	     ppr e1 $$ text "---" $$ ppr op $$ text "---" $$ ppr fix $$ text "---" $$ ppr e2
    )
    returnRn (OpApp e1 op fix e2)

-- Parser left-associates everything, but 
-- derived instances may have correctly-associated things to
-- in the right operarand.  So we just check that the right operand is OK
right_op_ok fix1 (OpApp _ _ fix2 _)
  = not error_please && associate_right
  where
    (error_please, associate_right) = compareFixity fix1 fix2
right_op_ok fix1 other
  = True

-- Parser initially makes negation bind more tightly than any other operator
mkNegAppRn neg_arg neg_name
  = 
#ifdef DEBUG
    getModeRn			`thenRn` \ mode ->
    ASSERT( not_op_app mode neg_arg )
#endif
    returnRn (NegApp neg_arg neg_name)

not_op_app SourceMode (OpApp _ _ _ _) = False
not_op_app mode other	 	      = True
\end{code}

\begin{code}
mkConOpPatRn :: RenamedPat -> Name -> Fixity -> RenamedPat
	     -> RnMS RenamedPat

mkConOpPatRn p1@(ConOpPatIn p11 op1 fix1 p12) 
	     op2 fix2 p2
  | nofix_error
  = addErrRn (precParseErr (ppr_op op1,fix1) (ppr_op op2,fix2))	`thenRn_`
    returnRn (ConOpPatIn p1 op2 fix2 p2)

  | associate_right
  = mkConOpPatRn p12 op2 fix2 p2		`thenRn` \ new_p ->
    returnRn (ConOpPatIn p11 op1 fix1 new_p)

  where
    (nofix_error, associate_right) = compareFixity fix1 fix2

mkConOpPatRn p1 op fix p2 			-- Default case, no rearrangment
  = ASSERT( not_op_pat p2 )
    returnRn (ConOpPatIn p1 op fix p2)

not_op_pat (ConOpPatIn _ _ _ _) = False
not_op_pat other   	        = True
\end{code}

\begin{code}
checkPrecMatch :: Bool -> Name -> RenamedMatch -> RnMS ()

checkPrecMatch False fn match
  = returnRn ()

checkPrecMatch True op (Match (p1:p2:_) _ _)
	-- True indicates an infix lhs
  = getModeRn 		`thenRn` \ mode ->
	-- See comments with rnExpr (OpApp ...)
    if isInterfaceMode mode
	then returnRn ()
	else checkPrec op p1 False	`thenRn_`
	     checkPrec op p2 True

checkPrecMatch True op _ = panic "checkPrecMatch"

checkPrec op (ConOpPatIn _ op1 _ _) right
  = lookupFixityRn op	`thenRn` \  op_fix@(Fixity op_prec  op_dir) ->
    lookupFixityRn op1	`thenRn` \ op1_fix@(Fixity op1_prec op1_dir) ->
    let
	inf_ok = op1_prec > op_prec || 
	         (op1_prec == op_prec &&
		  (op1_dir == InfixR && op_dir == InfixR && right ||
		   op1_dir == InfixL && op_dir == InfixL && not right))

	info  = (ppr_op op,  op_fix)
	info1 = (ppr_op op1, op1_fix)
	(infol, infor) = if right then (info, info1) else (info1, info)
    in
    checkRn inf_ok (precParseErr infol infor)

checkPrec op pat right
  = returnRn ()

-- Check precedence of (arg op) or (op arg) respectively
-- If arg is itself an operator application, then either
--   (a) its precedence must be higher than that of op
--   (b) its precedency & associativity must be the same as that of op
checkSectionPrec direction section op arg
  = case arg of
	OpApp _ op fix _ -> go_for_it (ppr_op op)     fix
	NegApp _ _	 -> go_for_it pp_prefix_minus negateFixity
	other		 -> returnRn ()
  where
    HsVar op_name = op
    go_for_it pp_arg_op arg_fix@(Fixity arg_prec assoc)
	= lookupFixityRn op_name	`thenRn` \ op_fix@(Fixity op_prec _) ->
	  checkRn (op_prec < arg_prec
		     || op_prec == arg_prec && direction == assoc)
		  (sectionPrecErr (ppr_op op_name, op_fix) 	
		  (pp_arg_op, arg_fix) section)
\end{code}


%************************************************************************
%*									*
\subsubsection{Literals}
%*									*
%************************************************************************

When literals occur we have to make sure
that the types and classes they involve
are made available.

\begin{code}
litFVs (HsChar c)
   = checkRn (inCharRange c) (bogusCharError c) `thenRn_`
     returnRn (unitFV charTyCon_name)

litFVs (HsCharPrim c)         = returnRn (unitFV (getName charPrimTyCon))
litFVs (HsString s)           = returnRn (mkFVs [listTyCon_name, charTyCon_name])
litFVs (HsStringPrim s)       = returnRn (unitFV (getName addrPrimTyCon))
litFVs (HsInt i)	      = returnRn (unitFV (getName intTyCon))
litFVs (HsIntPrim i)          = returnRn (unitFV (getName intPrimTyCon))
litFVs (HsFloatPrim f)        = returnRn (unitFV (getName floatPrimTyCon))
litFVs (HsDoublePrim d)       = returnRn (unitFV (getName doublePrimTyCon))
litFVs (HsLitLit l bogus_ty)  = returnRn (unitFV cCallableClassName)
litFVs lit		      = pprPanic "RnExpr.litFVs" (ppr lit)	-- HsInteger and HsRat only appear 
									-- in post-typechecker translations

rnOverLit (HsIntegral i from_integer_name)
  = lookupSyntaxName from_integer_name	`thenRn` \ from_integer_name' ->
    if inIntRange i then
	returnRn (HsIntegral i from_integer_name', unitFV from_integer_name')
    else let
	fvs = mkFVs [plusIntegerName, timesIntegerName]
	-- Big integer literals are built, using + and *, 
	-- out of small integers (DsUtils.mkIntegerLit)
	-- [NB: plusInteger, timesInteger aren't rebindable... 
	--	they are used to construct the argument to fromInteger, 
	--	which is the rebindable one.]
    in
    returnRn (HsIntegral i from_integer_name', fvs `addOneFV` from_integer_name')

rnOverLit (HsFractional i from_rat_name)
  = lookupSyntaxName from_rat_name						`thenRn` \ from_rat_name' ->
    let
	fvs = mkFVs [ratioDataConName, plusIntegerName, timesIntegerName]
	-- We have to make sure that the Ratio type is imported with
	-- its constructor, because literals of type Ratio t are
	-- built with that constructor.
	-- The Rational type is needed too, but that will come in
	-- when fractionalClass does.
	-- The plus/times integer operations may be needed to construct the numerator
	-- and denominator (see DsUtils.mkIntegerLit)
    in
    returnRn (HsFractional i from_rat_name', fvs `addOneFV` from_rat_name')
\end{code}

%************************************************************************
%*									*
\subsubsection{Assertion utils}
%*									*
%************************************************************************

\begin{code}
mkAssertExpr :: RnMS (RenamedHsExpr, FreeVars)
mkAssertExpr =
  lookupOrigName assertErr_RDR		`thenRn` \ name ->
  getSrcLocRn    			`thenRn` \ sloc ->

    -- if we're ignoring asserts, return (\ _ e -> e)
    -- if not, return (assertError "src-loc")

  if opt_IgnoreAsserts then
    getUniqRn				`thenRn` \ uniq ->
    let
     vname = mkSystemName uniq FSLIT("v")
     expr  = HsLam ignorePredMatch
     loc   = nameSrcLoc vname
     ignorePredMatch = mkSimpleMatch [WildPatIn, VarPatIn vname] (HsVar vname) placeHolderType loc
    in
    returnRn (expr, unitFV name)
  else
    let
     expr = 
          HsApp (HsVar name)
	        (HsLit (HsStringPrim (mkFastString (stringToUtf8 (showSDoc (ppr sloc))))))
    in
    returnRn (expr, unitFV name)
\end{code}

%************************************************************************
%*									*
\subsubsection{Errors}
%*									*
%************************************************************************

\begin{code}
ppr_op op = quotes (ppr op)	-- Here, op can be a Name or a (Var n), where n is a Name
pp_prefix_minus = ptext SLIT("prefix `-'")

dupFieldErr str (dup:rest)
  = hsep [ptext SLIT("duplicate field name"), 
          quotes (ppr dup),
	  ptext SLIT("in record"), text str]

nonStdGuardErr guard
  = hang (ptext
    SLIT("accepting non-standard pattern guards (-fglasgow-exts to suppress this message)")
    ) 4 (ppr guard)

patSigErr ty
  =  (ptext SLIT("Illegal signature in pattern:") <+> ppr ty)
	$$ nest 4 (ptext SLIT("Use -fglasgow-exts to permit it"))

patSynErr e 
  = sep [ptext SLIT("Pattern syntax in expression context:"),
	 nest 4 (ppr e)]

doStmtListErr e
  = sep [ptext SLIT("`do' statements must end in expression:"),
	 nest 4 (ppr e)]

bogusCharError c
  = ptext SLIT("character literal out of range: '\\") <> int c <> char '\''

withWarning
  = sep [quotes (ptext SLIT("with")),
	 ptext SLIT("is deprecated, use"),
	 quotes (ptext SLIT("let")),
	 ptext SLIT("instead")]
\end{code}
