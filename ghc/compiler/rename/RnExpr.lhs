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
	rnMatch, rnGRHSs, rnLExpr, rnExpr, rnStmts,
	checkPrecMatch, checkTH
   ) where

#include "HsVersions.h"

import {-# SOURCE #-} RnSource  ( rnSrcDecls, rnBindGroupsAndThen, rnBindGroups, rnSplice ) 

-- 	RnSource imports RnBinds.rnTopMonoBinds, RnExpr.rnExpr
--	RnBinds	 imports RnExpr.rnMatch, etc
--	RnExpr	 imports [boot] RnSource.rnSrcDecls, RnSource.rnBinds

import HsSyn
import RnHsSyn
import TcRnMonad
import RnEnv
import OccName		( plusOccEnv )
import RnNames		( importsFromLocalDecls )
import RnTypes		( rnHsTypeFVs, rnLPat, rnOverLit, rnPatsAndThen, rnLit,
			  dupFieldErr, precParseErr, sectionPrecErr, patSigErr,
			  checkTupSize )
import CmdLineOpts	( DynFlag(..) )
import BasicTypes	( Fixity(..), FixityDirection(..), negateFixity, compareFixity )
import PrelNames	( hasKey, assertIdKey, assertErrorName,
			  loopAName, choiceAName, appAName, arrAName, composeAName, firstAName,
			  negateName, monadNames, mfixName )
import Name		( Name, nameOccName )
import NameSet
import RdrName		( RdrName )
import UnicodeUtil	( stringToUtf8 )
import UniqFM		( isNullUFM )
import UniqSet		( emptyUniqSet )
import Util		( isSingleton )
import ListSetOps	( removeDups )
import Outputable
import SrcLoc		( Located(..), unLoc, getLoc, combineLocs, cmpLocated )
import FastString

import List		( unzip4 )
\end{code}


************************************************************************
*									*
\subsection{Match}
*									*
************************************************************************

\begin{code}
rnMatch :: HsMatchContext Name -> LMatch RdrName -> RnM (LMatch Name, FreeVars)
rnMatch ctxt  = wrapLocFstM (rnMatch' ctxt)

rnMatch' ctxt match@(Match pats maybe_rhs_sig grhss)
  = 
	-- Deal with the rhs type signature
    bindPatSigTyVarsFV rhs_sig_tys	$ 
    doptM Opt_GlasgowExts		`thenM` \ opt_GlasgowExts ->
    (case maybe_rhs_sig of
	Nothing -> returnM (Nothing, emptyFVs)
	Just ty | opt_GlasgowExts -> rnHsTypeFVs doc_sig ty	`thenM` \ (ty', ty_fvs) ->
				     returnM (Just ty', ty_fvs)
		| otherwise	  -> addLocErr ty patSigErr	`thenM_`
				     returnM (Nothing, emptyFVs)
    )					`thenM` \ (maybe_rhs_sig', ty_fvs) ->

	-- Now the main event
    rnPatsAndThen ctxt True pats $ \ pats' ->
    rnGRHSs ctxt grhss		 `thenM` \ (grhss', grhss_fvs) ->

    returnM (Match pats' maybe_rhs_sig' grhss', grhss_fvs `plusFV` ty_fvs)
	-- The bindPatSigTyVarsFV and rnPatsAndThen will remove the bound FVs
  where
     rhs_sig_tys =  case maybe_rhs_sig of
			Nothing -> []
			Just ty -> [ty]
     doc_sig = text "In a result type-signature"
\end{code}


%************************************************************************
%*									*
\subsubsection{Guarded right-hand sides (GRHSs)}
%*									*
%************************************************************************

\begin{code}
rnGRHSs :: HsMatchContext Name -> GRHSs RdrName -> RnM (GRHSs Name, FreeVars)

rnGRHSs ctxt (GRHSs grhss binds _)
  = rnBindGroupsAndThen binds	$ \ binds' ->
    mapFvRn (rnGRHS ctxt) grhss	`thenM` \ (grhss', fvGRHSs) ->
    returnM (GRHSs grhss' binds' placeHolderType, fvGRHSs)

rnGRHS :: HsMatchContext Name -> LGRHS RdrName -> RnM (LGRHS Name, FreeVars)
rnGRHS ctxt = wrapLocFstM (rnGRHS' ctxt)

rnGRHS' ctxt (GRHS guarded)
  = doptM Opt_GlasgowExts		`thenM` \ opt_GlasgowExts ->
    checkM (opt_GlasgowExts || is_standard_guard guarded)
	   (addWarn (nonStdGuardErr guarded))	`thenM_` 

    rnStmts (PatGuard ctxt) guarded	`thenM` \ (guarded', fvs) ->
    returnM (GRHS guarded', fvs)
  where
	-- Standard Haskell 1.4 guards are just a single boolean
	-- expression, rather than a list of qualifiers as in the
	-- Glasgow extension
    is_standard_guard [L _ (ResultStmt _)]                     = True
    is_standard_guard [L _ (ExprStmt _ _), L _ (ResultStmt _)] = True
    is_standard_guard other	      		               = False
\end{code}

%************************************************************************
%*									*
\subsubsection{Expressions}
%*									*
%************************************************************************

\begin{code}
rnExprs :: [LHsExpr RdrName] -> RnM ([LHsExpr Name], FreeVars)
rnExprs ls = rnExprs' ls emptyUniqSet
 where
  rnExprs' [] acc = returnM ([], acc)
  rnExprs' (expr:exprs) acc
   = rnLExpr expr 	        `thenM` \ (expr', fvExpr) ->

	-- Now we do a "seq" on the free vars because typically it's small
	-- or empty, especially in very long lists of constants
    let
	acc' = acc `plusFV` fvExpr
    in
    (grubby_seqNameSet acc' rnExprs') exprs acc'	`thenM` \ (exprs', fvExprs) ->
    returnM (expr':exprs', fvExprs)

-- Grubby little function to do "seq" on namesets; replace by proper seq when GHC can do seq
grubby_seqNameSet ns result | isNullUFM ns = result
			    | otherwise    = result
\end{code}

Variables. We look up the variable and return the resulting name. 

\begin{code}
rnLExpr :: LHsExpr RdrName -> RnM (LHsExpr Name, FreeVars)
rnLExpr = wrapLocFstM rnExpr

rnExpr :: HsExpr RdrName -> RnM (HsExpr Name, FreeVars)

rnExpr (HsVar v)
  = lookupOccRn v	`thenM` \ name ->
    doptM Opt_IgnoreAsserts `thenM` \ ignore_asserts ->
    if name `hasKey` assertIdKey && not ignore_asserts then
	-- We expand it to (GHC.Err.assertError location_string)
        mkAssertErrorExpr	`thenM` \ (e, fvs) ->
	returnM (e, fvs `addOneFV` name)
		-- Keep 'assert' as a free var, to ensure it's not reported as unused!
    else
        -- The normal case.  Even if the Id was 'assert', if we are 
	-- ignoring assertions we leave it as GHC.Base.assert; 
	-- this function just ignores its first arg.
       returnM (HsVar name, unitFV name)

rnExpr (HsIPVar v)
  = newIPNameRn v		`thenM` \ name ->
    returnM (HsIPVar name, emptyFVs)

rnExpr (HsLit lit) 
  = rnLit lit		`thenM_`
    returnM (HsLit lit, emptyFVs)

rnExpr (HsOverLit lit) 
  = rnOverLit lit		`thenM` \ (lit', fvs) ->
    returnM (HsOverLit lit', fvs)

rnExpr (HsLam match)
  = rnMatch LambdaExpr match	`thenM` \ (match', fvMatch) ->
    returnM (HsLam match', fvMatch)

rnExpr (HsApp fun arg)
  = rnLExpr fun		`thenM` \ (fun',fvFun) ->
    rnLExpr arg		`thenM` \ (arg',fvArg) ->
    returnM (HsApp fun' arg', fvFun `plusFV` fvArg)

rnExpr (OpApp e1 op _ e2) 
  = rnLExpr e1				`thenM` \ (e1', fv_e1) ->
    rnLExpr e2				`thenM` \ (e2', fv_e2) ->
    rnLExpr op				`thenM` \ (op'@(L _ (HsVar op_name)), fv_op) ->

	-- Deal with fixity
	-- When renaming code synthesised from "deriving" declarations
	-- we used to avoid fixity stuff, but we can't easily tell any
	-- more, so I've removed the test.  Adding HsPars in TcGenDeriv
	-- should prevent bad things happening.
    lookupFixityRn op_name		`thenM` \ fixity ->
    mkOpAppRn e1' op' fixity e2'	`thenM` \ final_e -> 

    returnM (final_e,
	      fv_e1 `plusFV` fv_op `plusFV` fv_e2)

rnExpr (NegApp e _)
  = rnLExpr e			`thenM` \ (e', fv_e) ->
    lookupSyntaxName negateName	`thenM` \ (neg_name, fv_neg) ->
    mkNegAppRn e' neg_name	`thenM` \ final_e ->
    returnM (final_e, fv_e `plusFV` fv_neg)

rnExpr (HsPar e)
  = rnLExpr e 		`thenM` \ (e', fvs_e) ->
    returnM (HsPar e', fvs_e)

-- Template Haskell extensions
-- Don't ifdef-GHCI them because we want to fail gracefully
-- (not with an rnExpr crash) in a stage-1 compiler.
rnExpr e@(HsBracket br_body)
  = checkTH e "bracket"		`thenM_`
    rnBracket br_body		`thenM` \ (body', fvs_e) ->
    returnM (HsBracket body', fvs_e)

rnExpr e@(HsSpliceE splice)
  = rnSplice splice 		`thenM` \ (splice', fvs) ->
    returnM (HsSpliceE splice', fvs)

rnExpr section@(SectionL expr op)
  = rnLExpr expr	 	`thenM` \ (expr', fvs_expr) ->
    rnLExpr op	 		`thenM` \ (op', fvs_op) ->
    checkSectionPrec InfixL section op' expr' `thenM_`
    returnM (SectionL expr' op', fvs_op `plusFV` fvs_expr)

rnExpr section@(SectionR op expr)
  = rnLExpr op	 				`thenM` \ (op',   fvs_op) ->
    rnLExpr expr	 				`thenM` \ (expr', fvs_expr) ->
    checkSectionPrec InfixR section op' expr'	`thenM_`
    returnM (SectionR op' expr', fvs_op `plusFV` fvs_expr)

rnExpr (HsCoreAnn ann expr)
  = rnLExpr expr `thenM` \ (expr', fvs_expr) ->
    returnM (HsCoreAnn ann expr', fvs_expr)

rnExpr (HsSCC lbl expr)
  = rnLExpr expr	 	`thenM` \ (expr', fvs_expr) ->
    returnM (HsSCC lbl expr', fvs_expr)

rnExpr (HsCase expr ms)
  = rnLExpr expr		 	`thenM` \ (new_expr, e_fvs) ->
    mapFvRn (rnMatch CaseAlt) ms	`thenM` \ (new_ms, ms_fvs) ->
    returnM (HsCase new_expr new_ms, e_fvs `plusFV` ms_fvs)

rnExpr (HsLet binds expr)
  = rnBindGroupsAndThen binds		$ \ binds' ->
    rnLExpr expr			 `thenM` \ (expr',fvExpr) ->
    returnM (HsLet binds' expr', fvExpr)

rnExpr e@(HsDo do_or_lc stmts _ _)
  = rnStmts do_or_lc stmts		`thenM` \ (stmts', fvs) ->

	-- Check the statement list ends in an expression
    case last stmts' of {
	L _ (ResultStmt _) -> returnM () ;
	other              -> addLocErr other (doStmtListErr do_or_lc)
    }					`thenM_`

	-- Generate the rebindable syntax for the monad
    lookupSyntaxNames syntax_names	`thenM` \ (syntax_names', monad_fvs) ->

    returnM (HsDo do_or_lc stmts' syntax_names' placeHolderType, fvs `plusFV` monad_fvs)
  where
    syntax_names = case do_or_lc of
			DoExpr  -> monadNames
			MDoExpr -> monadNames ++ [mfixName]
			other   -> []

rnExpr (ExplicitList _ exps)
  = rnExprs exps		 	`thenM` \ (exps', fvs) ->
    returnM  (ExplicitList placeHolderType exps', fvs `addOneFV` listTyCon_name)

rnExpr (ExplicitPArr _ exps)
  = rnExprs exps		 	`thenM` \ (exps', fvs) ->
    returnM  (ExplicitPArr placeHolderType exps', fvs)

rnExpr e@(ExplicitTuple exps boxity)
  = checkTupSize tup_size			`thenM_`
    rnExprs exps	 			`thenM` \ (exps', fvs) ->
    returnM (ExplicitTuple exps' boxity, fvs `addOneFV` tycon_name)
  where
    tup_size   = length exps
    tycon_name = tupleTyCon_name boxity tup_size

rnExpr (RecordCon con_id rbinds)
  = lookupLocatedOccRn con_id		`thenM` \ conname ->
    rnRbinds "construction" rbinds	`thenM` \ (rbinds', fvRbinds) ->
    returnM (RecordCon conname rbinds', fvRbinds `addOneFV` unLoc conname)

rnExpr (RecordUpd expr rbinds)
  = rnLExpr expr			`thenM` \ (expr', fvExpr) ->
    rnRbinds "update" rbinds	`thenM` \ (rbinds', fvRbinds) ->
    returnM (RecordUpd expr' rbinds', fvExpr `plusFV` fvRbinds)

rnExpr (ExprWithTySig expr pty)
  = rnLExpr expr			`thenM` \ (expr', fvExpr) ->
    rnHsTypeFVs doc pty		`thenM` \ (pty', fvTy) ->
    returnM (ExprWithTySig expr' pty', fvExpr `plusFV` fvTy)
  where 
    doc = text "In an expression type signature"

rnExpr (HsIf p b1 b2)
  = rnLExpr p		`thenM` \ (p', fvP) ->
    rnLExpr b1		`thenM` \ (b1', fvB1) ->
    rnLExpr b2		`thenM` \ (b2', fvB2) ->
    returnM (HsIf p' b1' b2', plusFVs [fvP, fvB1, fvB2])

rnExpr (HsType a)
  = rnHsTypeFVs doc a	`thenM` \ (t, fvT) -> 
    returnM (HsType t, fvT)
  where 
    doc = text "In a type argument"

rnExpr (ArithSeqIn seq)
  = rnArithSeq seq	 `thenM` \ (new_seq, fvs) ->
    returnM (ArithSeqIn new_seq, fvs)

rnExpr (PArrSeqIn seq)
  = rnArithSeq seq	 `thenM` \ (new_seq, fvs) ->
    returnM (PArrSeqIn new_seq, fvs)
\end{code}

These three are pattern syntax appearing in expressions.
Since all the symbols are reservedops we can simply reject them.
We return a (bogus) EWildPat in each case.

\begin{code}
rnExpr e@EWildPat = addErr (patSynErr e)	`thenM_`
		    returnM (EWildPat, emptyFVs)

rnExpr e@(EAsPat _ _) = addErr (patSynErr e)	`thenM_`
		        returnM (EWildPat, emptyFVs)

rnExpr e@(ELazyPat _) = addErr (patSynErr e)	`thenM_`
		        returnM (EWildPat, emptyFVs)
\end{code}

%************************************************************************
%*									*
	Arrow notation
%*									*
%************************************************************************

\begin{code}
rnExpr (HsProc pat body)
  = rnPatsAndThen ProcExpr True [pat] $ \ [pat'] ->
    rnCmdTop body	              `thenM` \ (body',fvBody) ->
    returnM (HsProc pat' body', fvBody)

rnExpr (HsArrApp arrow arg _ ho rtl)
  = rnLExpr arrow	`thenM` \ (arrow',fvArrow) ->
    rnLExpr arg		`thenM` \ (arg',fvArg) ->
    returnM (HsArrApp arrow' arg' placeHolderType ho rtl,
	     fvArrow `plusFV` fvArg)

-- infix form
rnExpr (HsArrForm op (Just _) [arg1, arg2])
  = rnLExpr op		`thenM` \ (op'@(L _ (HsVar op_name)),fv_op) ->
    rnCmdTop arg1	`thenM` \ (arg1',fv_arg1) ->
    rnCmdTop arg2	`thenM` \ (arg2',fv_arg2) ->

	-- Deal with fixity

    lookupFixityRn op_name		`thenM` \ fixity ->
    mkOpFormRn arg1' op' fixity arg2'	`thenM` \ final_e -> 

    returnM (final_e,
	      fv_arg1 `plusFV` fv_op `plusFV` fv_arg2)

rnExpr (HsArrForm op fixity cmds)
  = rnLExpr op		`thenM` \ (op',fvOp) ->
    rnCmdArgs cmds	`thenM` \ (cmds',fvCmds) ->
    returnM (HsArrForm op' fixity cmds', fvOp `plusFV` fvCmds)

---------------------------
-- Deal with fixity (cf mkOpAppRn for the method)

mkOpFormRn :: LHsCmdTop Name		-- Left operand; already rearranged
	  -> LHsExpr Name -> Fixity 	-- Operator and fixity
	  -> LHsCmdTop Name		-- Right operand (not an infix)
	  -> RnM (HsCmd Name)

---------------------------
-- (e11 `op1` e12) `op2` e2
mkOpFormRn a1@(L loc (HsCmdTop (L _ (HsArrForm op1 (Just fix1) [a11,a12])) _ _ _))
	op2 fix2 a2
  | nofix_error
  = addErr (precParseErr (ppr_op op1,fix1) (ppr_op op2,fix2))	`thenM_`
    returnM (HsArrForm op2 (Just fix2) [a1, a2])

  | associate_right
  = mkOpFormRn a12 op2 fix2 a2		`thenM` \ new_c ->
    returnM (HsArrForm op1 (Just fix1)
	[a11, L loc (HsCmdTop (L loc new_c) [] placeHolderType [])])
	-- TODO: locs are wrong
  where
    (nofix_error, associate_right) = compareFixity fix1 fix2

---------------------------
--	Default case
mkOpFormRn arg1 op fix arg2 			-- Default case, no rearrangment
  = returnM (HsArrForm op (Just fix) [arg1, arg2])

\end{code}


%************************************************************************
%*									*
	Arrow commands
%*									*
%************************************************************************

\begin{code}
rnCmdArgs [] = returnM ([], emptyFVs)
rnCmdArgs (arg:args)
  = rnCmdTop arg	`thenM` \ (arg',fvArg) ->
    rnCmdArgs args	`thenM` \ (args',fvArgs) ->
    returnM (arg':args', fvArg `plusFV` fvArgs)


rnCmdTop = wrapLocFstM rnCmdTop'
 where
  rnCmdTop' (HsCmdTop cmd _ _ _) 
   = rnLExpr (convertOpFormsLCmd cmd) `thenM` \ (cmd', fvCmd) ->
     let 
	cmd_names = [arrAName, composeAName, firstAName] ++
		    nameSetToList (methodNamesCmd (unLoc cmd'))
     in
	-- Generate the rebindable syntax for the monad
     lookupSyntaxNames cmd_names	`thenM` \ (cmd_names', cmd_fvs) ->

     returnM (HsCmdTop cmd' [] placeHolderType cmd_names', 
	     fvCmd `plusFV` cmd_fvs)

---------------------------------------------------
-- convert OpApp's in a command context to HsArrForm's

convertOpFormsLCmd :: LHsCmd id -> LHsCmd id
convertOpFormsLCmd = fmap convertOpFormsCmd

convertOpFormsCmd :: HsCmd id -> HsCmd id

convertOpFormsCmd (HsApp c e) = HsApp (convertOpFormsLCmd c) e

convertOpFormsCmd (HsLam match) = HsLam (convertOpFormsMatch match)

convertOpFormsCmd (OpApp c1 op fixity c2)
  = let
	arg1 = L (getLoc c1) $ HsCmdTop (convertOpFormsLCmd c1) [] placeHolderType []
	arg2 = L (getLoc c2) $ HsCmdTop (convertOpFormsLCmd c2) [] placeHolderType []
    in
    HsArrForm op (Just fixity) [arg1, arg2]

convertOpFormsCmd (HsPar c) = HsPar (convertOpFormsLCmd c)

convertOpFormsCmd (HsCase exp matches)
  = HsCase exp (map convertOpFormsMatch matches)

convertOpFormsCmd (HsIf exp c1 c2)
  = HsIf exp (convertOpFormsLCmd c1) (convertOpFormsLCmd c2)

convertOpFormsCmd (HsLet binds cmd)
  = HsLet binds (convertOpFormsLCmd cmd)

convertOpFormsCmd (HsDo ctxt stmts ids ty)
  = HsDo ctxt (map (fmap convertOpFormsStmt) stmts) ids ty

-- Anything else is unchanged.  This includes HsArrForm (already done),
-- things with no sub-commands, and illegal commands (which will be
-- caught by the type checker)
convertOpFormsCmd c = c

convertOpFormsStmt (BindStmt pat cmd)
  = BindStmt pat (convertOpFormsLCmd cmd)
convertOpFormsStmt (ResultStmt cmd)
  = ResultStmt (convertOpFormsLCmd cmd)
convertOpFormsStmt (ExprStmt cmd ty)
  = ExprStmt (convertOpFormsLCmd cmd) ty
convertOpFormsStmt (RecStmt stmts lvs rvs es)
  = RecStmt (map (fmap convertOpFormsStmt) stmts) lvs rvs es
convertOpFormsStmt stmt = stmt

convertOpFormsMatch = fmap convert
 where convert (Match pat mty grhss)
	  = Match pat mty (convertOpFormsGRHSs grhss)

convertOpFormsGRHSs (GRHSs grhss binds ty)
  = GRHSs (map convertOpFormsGRHS grhss) binds ty

convertOpFormsGRHS = fmap convert
 where convert (GRHS stmts)
	  = let
		(L loc (ResultStmt cmd)) = last stmts
	    in
	    GRHS (init stmts ++ [L loc (ResultStmt (convertOpFormsLCmd cmd))])

---------------------------------------------------
type CmdNeeds = FreeVars	-- Only inhabitants are 
				-- 	appAName, choiceAName, loopAName

-- find what methods the Cmd needs (loop, choice, apply)
methodNamesLCmd :: LHsCmd Name -> CmdNeeds
methodNamesLCmd = methodNamesCmd . unLoc

methodNamesCmd :: HsCmd Name -> CmdNeeds

methodNamesCmd cmd@(HsArrApp _arrow _arg _ HsFirstOrderApp _rtl)
  = emptyFVs
methodNamesCmd cmd@(HsArrApp _arrow _arg _ HsHigherOrderApp _rtl)
  = unitFV appAName
methodNamesCmd cmd@(HsArrForm {}) = emptyFVs

methodNamesCmd (HsPar c) = methodNamesLCmd c

methodNamesCmd (HsIf p c1 c2)
  = methodNamesLCmd c1 `plusFV` methodNamesLCmd c2 `addOneFV` choiceAName

methodNamesCmd (HsLet b c) = methodNamesLCmd c

methodNamesCmd (HsDo sc stmts rbs ty) = methodNamesStmts stmts

methodNamesCmd (HsApp c e) = methodNamesLCmd c

methodNamesCmd (HsLam match) = methodNamesMatch match

methodNamesCmd (HsCase scrut matches)
  = plusFVs (map methodNamesMatch matches) `addOneFV` choiceAName

methodNamesCmd other = emptyFVs
   -- Other forms can't occur in commands, but it's not convenient 
   -- to error here so we just do what's convenient.
   -- The type checker will complain later

---------------------------------------------------
methodNamesMatch (L _ (Match pats sig_ty grhss)) = methodNamesGRHSs grhss

-------------------------------------------------
methodNamesGRHSs (GRHSs grhss binds ty) = plusFVs (map methodNamesGRHS grhss)

-------------------------------------------------
methodNamesGRHS (L _ (GRHS stmts)) = methodNamesLStmt (last stmts)

---------------------------------------------------
methodNamesStmts stmts = plusFVs (map methodNamesLStmt stmts)

---------------------------------------------------
methodNamesLStmt = methodNamesStmt . unLoc

methodNamesStmt (ResultStmt cmd) = methodNamesLCmd cmd
methodNamesStmt (ExprStmt cmd ty) = methodNamesLCmd cmd
methodNamesStmt (BindStmt pat cmd ) = methodNamesLCmd cmd
methodNamesStmt (RecStmt stmts lvs rvs es)
  = methodNamesStmts stmts `addOneFV` loopAName
methodNamesStmt (LetStmt b)  = emptyFVs
methodNamesStmt (ParStmt ss) = emptyFVs
   -- ParStmt can't occur in commands, but it's not convenient to error 
   -- here so we just do what's convenient
\end{code}


%************************************************************************
%*									*
	Arithmetic sequences
%*									*
%************************************************************************

\begin{code}
rnArithSeq (From expr)
 = rnLExpr expr 	`thenM` \ (expr', fvExpr) ->
   returnM (From expr', fvExpr)

rnArithSeq (FromThen expr1 expr2)
 = rnLExpr expr1 	`thenM` \ (expr1', fvExpr1) ->
   rnLExpr expr2	`thenM` \ (expr2', fvExpr2) ->
   returnM (FromThen expr1' expr2', fvExpr1 `plusFV` fvExpr2)

rnArithSeq (FromTo expr1 expr2)
 = rnLExpr expr1	`thenM` \ (expr1', fvExpr1) ->
   rnLExpr expr2	`thenM` \ (expr2', fvExpr2) ->
   returnM (FromTo expr1' expr2', fvExpr1 `plusFV` fvExpr2)

rnArithSeq (FromThenTo expr1 expr2 expr3)
 = rnLExpr expr1	`thenM` \ (expr1', fvExpr1) ->
   rnLExpr expr2	`thenM` \ (expr2', fvExpr2) ->
   rnLExpr expr3	`thenM` \ (expr3', fvExpr3) ->
   returnM (FromThenTo expr1' expr2' expr3',
	    plusFVs [fvExpr1, fvExpr2, fvExpr3])
\end{code}


%************************************************************************
%*									*
\subsubsection{@Rbinds@s and @Rpats@s: in record expressions}
%*									*
%************************************************************************

\begin{code}
rnRbinds str rbinds 
  = mappM_ field_dup_err dup_fields	`thenM_`
    mapFvRn rn_rbind rbinds		`thenM` \ (rbinds', fvRbind) ->
    returnM (rbinds', fvRbind)
  where
    (_, dup_fields) = removeDups cmpLocated [ f | (f,_) <- rbinds ]

    field_dup_err dups = mappM_ (\f -> addLocErr f (dupFieldErr str)) dups

    rn_rbind (field, expr)
      = lookupLocatedGlobalOccRn field	`thenM` \ fieldname ->
	rnLExpr expr			`thenM` \ (expr', fvExpr) ->
	returnM ((fieldname, expr'), fvExpr `addOneFV` unLoc fieldname)
\end{code}

%************************************************************************
%*									*
	Template Haskell brackets
%*									*
%************************************************************************

\begin{code}
rnBracket (VarBr n) = lookupOccRn n		`thenM` \ name -> 
		      returnM (VarBr name, unitFV name)
rnBracket (ExpBr e) = rnLExpr e		`thenM` \ (e', fvs) ->
		      returnM (ExpBr e', fvs)
rnBracket (PatBr p) = rnLPat p		`thenM` \ (p', fvs) ->
		      returnM (PatBr p', fvs)
rnBracket (TypBr t) = rnHsTypeFVs doc t	`thenM` \ (t', fvs) ->
		      returnM (TypBr t', fvs)
		    where
		      doc = ptext SLIT("In a Template-Haskell quoted type")
rnBracket (DecBr group) 
  = importsFromLocalDecls group `thenM` \ (rdr_env, avails) ->
	-- Discard avails (not useful here)

    updGblEnv (\gbl -> gbl { tcg_rdr_env = tcg_rdr_env gbl `plusOccEnv` rdr_env}) $
	-- Notice plusOccEnv, not plusGlobalRdrEnv.  In this situation we want
	-- to *shadow* top-level bindings.  E.g.
	--	foo = 1
	--	bar = [d| foo = 1|]
	-- So we drop down to plusOccEnv.  (Perhaps there should be a fn in RdrName.)

    rnSrcDecls group	`thenM` \ (tcg_env, group') ->
	-- Discard the tcg_env; it contains only extra info about fixity
    let 
	dus = tcg_dus tcg_env 
    in
    returnM (DecBr group', allUses dus)
\end{code}

%************************************************************************
%*									*
\subsubsection{@Stmt@s: in @do@ expressions}
%*									*
%************************************************************************

\begin{code}
rnStmts :: HsStmtContext Name -> [LStmt RdrName] -> RnM ([LStmt Name], FreeVars)

rnStmts MDoExpr = rnMDoStmts
rnStmts ctxt    = rnNormalStmts ctxt

rnNormalStmts :: HsStmtContext Name -> [LStmt RdrName] -> RnM ([LStmt Name], FreeVars)	
-- Used for cases *other* than recursive mdo
-- Implements nested scopes

rnNormalStmts ctxt [] = returnM ([], emptyFVs)
	-- Happens at the end of the sub-lists of a ParStmts

rnNormalStmts ctxt (L loc (ExprStmt expr _) : stmts)
  = rnLExpr expr		        `thenM` \ (expr', fv_expr) ->
    rnNormalStmts ctxt stmts	`thenM` \ (stmts', fvs) ->
    returnM (L loc (ExprStmt expr' placeHolderType) : stmts',
	     fv_expr `plusFV` fvs)

rnNormalStmts ctxt [L loc (ResultStmt expr)]
  = rnLExpr expr		`thenM` \ (expr', fv_expr) ->
    returnM ([L loc (ResultStmt expr')], fv_expr)

rnNormalStmts ctxt (L loc (BindStmt pat expr) : stmts) 
  = rnLExpr expr				`thenM` \ (expr', fv_expr) ->
	-- The binders do not scope over the expression

    let
     reportUnused = 
       case ctxt of
         ParStmtCtxt{} -> False
	 _ -> True
    in
    rnPatsAndThen (StmtCtxt ctxt) reportUnused [pat] $ \ [pat'] ->
    rnNormalStmts ctxt stmts		             `thenM` \ (stmts', fvs) ->
    returnM (L loc (BindStmt pat' expr') : stmts',
	     fv_expr `plusFV` fvs)	-- fv_expr shouldn't really be filtered by
					-- the rnPatsAndThen, but it does not matter

rnNormalStmts ctxt (L loc (LetStmt binds) : stmts)
  = checkErr (ok ctxt binds) (badIpBinds binds)	`thenM_`
    rnBindGroupsAndThen binds			( \ binds' ->
    rnNormalStmts ctxt stmts			`thenM` \ (stmts', fvs) ->
    returnM (L loc (LetStmt binds') : stmts', fvs))
  where
	-- We do not allow implicit-parameter bindings in a parallel
	-- list comprehension.  I'm not sure what it might mean.
    ok (ParStmtCtxt _) binds = not (any is_ip_bind binds)
    ok _	       _     = True

    is_ip_bind (HsIPBinds _) = True
    is_ip_bind _	     = False

rnNormalStmts ctxt (L loc (ParStmt stmtss) : stmts)
  = doptM Opt_GlasgowExts		`thenM` \ opt_GlasgowExts ->
    checkM opt_GlasgowExts parStmtErr 	`thenM_`
    mapFvRn rn_branch stmtss 		`thenM` \ (stmtss', fv_stmtss) ->
    let
	bndrss :: [[Name]]	-- NB: Name, not RdrName
	bndrss = map (map unLoc . collectStmtsBinders) stmtss'
	(bndrs, dups) = removeDups cmpByOcc (concat bndrss)
    in
    mappM dupErr dups			`thenM` \ _ ->
    bindLocalNamesFV bndrs		$
	-- Note: binders are returned in scope order, so one may
	--       shadow the next; e.g. x <- xs; x <- ys
    rnNormalStmts ctxt stmts			`thenM` \ (stmts', fvs) ->

	-- Cut down the exported binders to just the ones needed in the body
    let
	used_bndrs_s = map (filter (`elemNameSet` fvs)) bndrss
	unused_bndrs = filter (not . (`elemNameSet` fvs)) bndrs
    in
     -- With processing of the branches and the tail of comprehension done,
     -- we can finally compute&report any unused ParStmt binders.
    warnUnusedMatches unused_bndrs  `thenM_`
    returnM (L loc (ParStmt (stmtss' `zip` used_bndrs_s)) : stmts', 
	     fv_stmtss `plusFV` fvs)
  where
    rn_branch (stmts, _) = rnNormalStmts (ParStmtCtxt ctxt) stmts

    cmpByOcc n1 n2 = nameOccName n1 `compare` nameOccName n2
    dupErr (v:_) = addErr (ptext SLIT("Duplicate binding in parallel list comprehension for:")
			    <+> quotes (ppr v))

rnNormalStmts ctxt (L loc (RecStmt rec_stmts _ _ _) : stmts)
  = bindLocatedLocalsRn doc (collectStmtsBinders rec_stmts)	$ \ _ ->
    rn_rec_stmts rec_stmts				`thenM` \ segs ->
    rnNormalStmts ctxt stmts				`thenM` \ (stmts', fvs) ->
    let
	segs_w_fwd_refs     	 = addFwdRefs segs
	(ds, us, fs, rec_stmts') = unzip4 segs_w_fwd_refs
	later_vars = nameSetToList (plusFVs ds `intersectNameSet` fvs)
	fwd_vars   = nameSetToList (plusFVs fs)
	uses	   = plusFVs us
    in	
    returnM (L loc (RecStmt rec_stmts' later_vars fwd_vars []) : stmts', 
	     uses `plusFV` fvs)
  where
    doc = text "In a recursive do statement"
\end{code}


%************************************************************************
%*									*
\subsubsection{mdo expressions}
%*									*
%************************************************************************

\begin{code}
type FwdRefs = NameSet
type Segment stmts = (Defs,
		      Uses, 	-- May include defs
		      FwdRefs,	-- A subset of uses that are 
				--   (a) used before they are bound in this segment, or 
				--   (b) used here, and bound in subsequent segments
		      stmts)	-- Either Stmt or [Stmt]


----------------------------------------------------
rnMDoStmts :: [LStmt RdrName] -> RnM ([LStmt Name], FreeVars)
rnMDoStmts stmts
  = 	-- Step1: bring all the binders of the mdo into scope
	-- Remember that this also removes the binders from the
	-- finally-returned free-vars
    bindLocatedLocalsRn doc (collectStmtsBinders stmts)	$ \ _ ->
	
	-- Step 2: Rename each individual stmt, making a
	--	   singleton segment.  At this stage the FwdRefs field
	--	   isn't finished: it's empty for all except a BindStmt
	--	   for which it's the fwd refs within the bind itself
	-- 	   (This set may not be empty, because we're in a recursive 
	--	    context.)
    rn_rec_stmts stmts					`thenM` \ segs ->
    let
	-- Step 3: Fill in the fwd refs.
	-- 	   The segments are all singletons, but their fwd-ref
	--	   field mentions all the things used by the segment
	--	   that are bound after their use
	segs_w_fwd_refs = addFwdRefs segs

	-- Step 4: Group together the segments to make bigger segments
	--	   Invariant: in the result, no segment uses a variable
	--	   	      bound in a later segment
	grouped_segs = glomSegments segs_w_fwd_refs

	-- Step 5: Turn the segments into Stmts
	--	   Use RecStmt when and only when there are fwd refs
	--	   Also gather up the uses from the end towards the
	--	   start, so we can tell the RecStmt which things are
	--	   used 'after' the RecStmt
	stmts_w_fvs = segsToStmts grouped_segs
    in
    returnM stmts_w_fvs
  where
    doc = text "In a mdo-expression"


----------------------------------------------------
rn_rec_stmt :: LStmt RdrName -> RnM [Segment (LStmt Name)]
	-- Rename a Stmt that is inside a RecStmt (or mdo)
	-- Assumes all binders are already in scope
	-- Turns each stmt into a singleton Stmt

rn_rec_stmt (L loc (ExprStmt expr _))
  = rnLExpr expr 		`thenM` \ (expr', fvs) ->
    returnM [(emptyNameSet, fvs, emptyNameSet,
	      L loc (ExprStmt expr' placeHolderType))]

rn_rec_stmt (L loc (ResultStmt expr))
  = rnLExpr expr			`thenM` \ (expr', fvs) ->
    returnM [(emptyNameSet, fvs, emptyNameSet,
	      L loc (ResultStmt expr'))]

rn_rec_stmt (L loc (BindStmt pat expr))
  = rnLExpr expr		`thenM` \ (expr', fv_expr) ->
    rnLPat pat		`thenM` \ (pat', fv_pat) ->
    let
	bndrs = mkNameSet (collectPatBinders pat')
	fvs   = fv_expr `plusFV` fv_pat
    in
    returnM [(bndrs, fvs, bndrs `intersectNameSet` fvs,
	      L loc (BindStmt pat' expr'))]

rn_rec_stmt (L loc (LetStmt binds))
  = rnBindGroups binds		`thenM` \ (binds', du_binds) ->
    returnM [(duDefs du_binds, duUses du_binds, 
	      emptyNameSet, L loc (LetStmt binds'))]

rn_rec_stmt (L loc (RecStmt stmts _ _ _))	-- Flatten Rec inside Rec
  = rn_rec_stmts stmts

rn_rec_stmt stmt@(L _ (ParStmt _))	-- Syntactically illegal in mdo
  = pprPanic "rn_rec_stmt" (ppr stmt)

---------------------------------------------
rn_rec_stmts :: [LStmt RdrName] -> RnM [Segment (LStmt Name)]
rn_rec_stmts stmts = mappM rn_rec_stmt stmts	`thenM` \ segs_s ->
		     returnM (concat segs_s)


---------------------------------------------
addFwdRefs :: [Segment a] -> [Segment a]
-- So far the segments only have forward refs *within* the Stmt
-- 	(which happens for bind:  x <- ...x...)
-- This function adds the cross-seg fwd ref info

addFwdRefs pairs 
  = fst (foldr mk_seg ([], emptyNameSet) pairs)
  where
    mk_seg (defs, uses, fwds, stmts) (segs, later_defs)
	= (new_seg : segs, all_defs)
	where
	  new_seg = (defs, uses, new_fwds, stmts)
	  all_defs = later_defs `unionNameSets` defs
	  new_fwds = fwds `unionNameSets` (uses `intersectNameSet` later_defs)
		-- Add the downstream fwd refs here

----------------------------------------------------
-- 	Glomming the singleton segments of an mdo into 
--	minimal recursive groups.
--
-- At first I thought this was just strongly connected components, but
-- there's an important constraint: the order of the stmts must not change.
--
-- Consider
--	mdo { x <- ...y...
--	      p <- z
--	      y <- ...x...
--	      q <- x
--	      z <- y
--	      r <- x }
--
-- Here, the first stmt mention 'y', which is bound in the third.  
-- But that means that the innocent second stmt (p <- z) gets caught
-- up in the recursion.  And that in turn means that the binding for
-- 'z' has to be included... and so on.
--
-- Start at the tail { r <- x }
-- Now add the next one { z <- y ; r <- x }
-- Now add one more     { q <- x ; z <- y ; r <- x }
-- Now one more... but this time we have to group a bunch into rec
--	{ rec { y <- ...x... ; q <- x ; z <- y } ; r <- x }
-- Now one more, which we can add on without a rec
--	{ p <- z ; 
--	  rec { y <- ...x... ; q <- x ; z <- y } ; 
-- 	  r <- x }
-- Finally we add the last one; since it mentions y we have to
-- glom it togeher with the first two groups
--	{ rec { x <- ...y...; p <- z ; y <- ...x... ; 
--		q <- x ; z <- y } ; 
-- 	  r <- x }

glomSegments :: [Segment (LStmt Name)] -> [Segment [LStmt Name]]

glomSegments [] = []
glomSegments ((defs,uses,fwds,stmt) : segs)
	-- Actually stmts will always be a singleton
  = (seg_defs, seg_uses, seg_fwds, seg_stmts)  : others
  where
    segs'	     = glomSegments segs
    (extras, others) = grab uses segs'
    (ds, us, fs, ss) = unzip4 extras
    
    seg_defs  = plusFVs ds `plusFV` defs
    seg_uses  = plusFVs us `plusFV` uses
    seg_fwds  = plusFVs fs `plusFV` fwds
    seg_stmts = stmt : concat ss

    grab :: NameSet	 	-- The client
	 -> [Segment a]
	 -> ([Segment a],	-- Needed by the 'client'
	     [Segment a])	-- Not needed by the client
	-- The result is simply a split of the input
    grab uses dus 
	= (reverse yeses, reverse noes)
	where
	  (noes, yeses) 	  = span not_needed (reverse dus)
	  not_needed (defs,_,_,_) = not (intersectsNameSet defs uses)


----------------------------------------------------
segsToStmts :: [Segment [LStmt Name]] -> ([LStmt Name], FreeVars)

segsToStmts [] = ([], emptyFVs)
segsToStmts ((defs, uses, fwds, ss) : segs)
  = (new_stmt : later_stmts, later_uses `plusFV` uses)
  where
    (later_stmts, later_uses) = segsToStmts segs
    new_stmt | non_rec	 = head ss
	     | otherwise = L (getLoc (head ss)) $ 
			   RecStmt ss (nameSetToList used_later) (nameSetToList fwds) []
	     where
	       non_rec    = isSingleton ss && isEmptyNameSet fwds
	       used_later = defs `intersectNameSet` later_uses
				-- The ones needed after the RecStmt
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
mkOpAppRn :: LHsExpr Name			-- Left operand; already rearranged
	  -> LHsExpr Name -> Fixity 		-- Operator and fixity
	  -> LHsExpr Name			-- Right operand (not an OpApp, but might
						-- be a NegApp)
	  -> RnM (HsExpr Name)

---------------------------
-- (e11 `op1` e12) `op2` e2
mkOpAppRn e1@(L _ (OpApp e11 op1 fix1 e12)) op2 fix2 e2
  | nofix_error
  = addErr (precParseErr (ppr_op op1,fix1) (ppr_op op2,fix2))	`thenM_`
    returnM (OpApp e1 op2 fix2 e2)

  | associate_right
  = mkOpAppRn e12 op2 fix2 e2		`thenM` \ new_e ->
    returnM (OpApp e11 op1 fix1 (L loc' new_e))
  where
    loc'= combineLocs e12 e2
    (nofix_error, associate_right) = compareFixity fix1 fix2

---------------------------
--	(- neg_arg) `op` e2
mkOpAppRn e1@(L _ (NegApp neg_arg neg_name)) op2 fix2 e2
  | nofix_error
  = addErr (precParseErr (pp_prefix_minus,negateFixity) (ppr_op op2,fix2))	`thenM_`
    returnM (OpApp e1 op2 fix2 e2)

  | associate_right
  = mkOpAppRn neg_arg op2 fix2 e2	`thenM` \ new_e ->
    returnM (NegApp (L loc' new_e) neg_name)
  where
    loc' = combineLocs neg_arg e2
    (nofix_error, associate_right) = compareFixity negateFixity fix2

---------------------------
--	e1 `op` - neg_arg
mkOpAppRn e1 op1 fix1 e2@(L _ (NegApp neg_arg _))	-- NegApp can occur on the right
  | not associate_right				-- We *want* right association
  = addErr (precParseErr (ppr_op op1, fix1) (pp_prefix_minus, negateFixity))	`thenM_`
    returnM (OpApp e1 op1 fix1 e2)
  where
    (_, associate_right) = compareFixity fix1 negateFixity

---------------------------
--	Default case
mkOpAppRn e1 op fix e2 			-- Default case, no rearrangment
  = ASSERT2( right_op_ok fix (unLoc e2),
	     ppr e1 $$ text "---" $$ ppr op $$ text "---" $$ ppr fix $$ text "---" $$ ppr e2
    )
    returnM (OpApp e1 op fix e2)

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
-- And "deriving" code should respect this (use HsPar if not)
mkNegAppRn :: LHsExpr id -> SyntaxName -> RnM (HsExpr id)
mkNegAppRn neg_arg neg_name
  = ASSERT( not_op_app (unLoc neg_arg) )
    returnM (NegApp neg_arg neg_name)

not_op_app (OpApp _ _ _ _) = False
not_op_app other	   = True
\end{code}

\begin{code}
checkPrecMatch :: Bool -> Name -> LMatch Name -> RnM ()

checkPrecMatch False fn match
  = returnM ()

checkPrecMatch True op (L _ (Match (p1:p2:_) _ _))
	-- True indicates an infix lhs
  = 	-- See comments with rnExpr (OpApp ...) about "deriving"
    checkPrec op (unLoc p1) False	`thenM_`
    checkPrec op (unLoc p2) True

checkPrecMatch True op _ = panic "checkPrecMatch"

checkPrec op (ConPatIn op1 (InfixCon _ _)) right
  = lookupFixityRn op		`thenM` \  op_fix@(Fixity op_prec  op_dir) ->
    lookupFixityRn (unLoc op1)	`thenM` \ op1_fix@(Fixity op1_prec op1_dir) ->
    let
	inf_ok = op1_prec > op_prec || 
	         (op1_prec == op_prec &&
		  (op1_dir == InfixR && op_dir == InfixR && right ||
		   op1_dir == InfixL && op_dir == InfixL && not right))

	info  = (ppr_op op,  op_fix)
	info1 = (ppr_op op1, op1_fix)
	(infol, infor) = if right then (info, info1) else (info1, info)
    in
    checkErr inf_ok (precParseErr infol infor)

checkPrec op pat right
  = returnM ()

-- Check precedence of (arg op) or (op arg) respectively
-- If arg is itself an operator application, then either
--   (a) its precedence must be higher than that of op
--   (b) its precedency & associativity must be the same as that of op
checkSectionPrec :: FixityDirection -> HsExpr RdrName
	-> LHsExpr Name -> LHsExpr Name -> RnM ()
checkSectionPrec direction section op arg
  = case unLoc arg of
	OpApp _ op fix _ -> go_for_it (ppr_op op)     fix
	NegApp _ _	 -> go_for_it pp_prefix_minus negateFixity
	other		 -> returnM ()
  where
    L _ (HsVar op_name) = op
    go_for_it pp_arg_op arg_fix@(Fixity arg_prec assoc)
	= lookupFixityRn op_name	`thenM` \ op_fix@(Fixity op_prec _) ->
	  checkErr (op_prec < arg_prec
		     || op_prec == arg_prec && direction == assoc)
		  (sectionPrecErr (ppr_op op_name, op_fix) 	
		  (pp_arg_op, arg_fix) section)
\end{code}


%************************************************************************
%*									*
\subsubsection{Assertion utils}
%*									*
%************************************************************************

\begin{code}
mkAssertErrorExpr :: RnM (HsExpr Name, FreeVars)
-- Return an expression for (assertError "Foo.hs:27")
mkAssertErrorExpr
  = getSrcSpanM    			`thenM` \ sloc ->
    let
	expr = HsApp (L sloc (HsVar assertErrorName)) (L sloc (HsLit msg))
	msg  = HsStringPrim (mkFastString (stringToUtf8 (showSDoc (ppr sloc))))
    in
    returnM (expr, emptyFVs)
\end{code}

%************************************************************************
%*									*
\subsubsection{Errors}
%*									*
%************************************************************************

\begin{code}
ppr_op op = quotes (ppr op)	-- Here, op can be a Name or a (Var n), where n is a Name
pp_prefix_minus = ptext SLIT("prefix `-'")

nonStdGuardErr guard
  = hang (ptext
    SLIT("accepting non-standard pattern guards (-fglasgow-exts to suppress this message)")
    ) 4 (ppr guard)

patSynErr e 
  = sep [ptext SLIT("Pattern syntax in expression context:"),
	 nest 4 (ppr e)]

doStmtListErr do_or_lc e
  = sep [quotes (text binder_name) <+> ptext SLIT("statements must end in expression:"),
	 nest 4 (ppr e)]
  where
    binder_name = case do_or_lc of
			MDoExpr -> "mdo"
			other   -> "do"

#ifdef GHCI 
checkTH e what = returnM ()	-- OK
#else
checkTH e what 	-- Raise an error in a stage-1 compiler
  = addErr (vcat [ptext SLIT("Template Haskell") <+> text what <+>  
	          ptext SLIT("illegal in a stage-1 compiler"),
	          nest 2 (ppr e)])
#endif   

parStmtErr = addErr (ptext SLIT("Illegal parallel list comprehension: use -fglasgow-exts"))

badIpBinds binds
  = hang (ptext SLIT("Implicit-parameter bindings illegal in a parallel list comprehension:")) 4
	 (ppr binds)
\end{code}
