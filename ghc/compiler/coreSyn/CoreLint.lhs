%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%
\section[CoreLint]{A ``lint'' pass to check for Core correctness}

\begin{code}
module CoreLint (
	lintCoreBindings,
	lintUnfolding, 
	showPass, endPass, endPassWithRules
    ) where

#include "HsVersions.h"

import IO		( hPutStr, hPutStrLn, stdout )

import CoreSyn
import Rules            ( RuleBase, pprRuleBase )
import CoreFVs		( idFreeVars, mustHaveLocalBinding )
import CoreUtils	( exprOkForSpeculation, coreBindsSize, mkPiType )

import Bag
import Literal		( literalType )
import DataCon		( dataConRepType )
import Var		( Var, Id, TyVar, idType, tyVarKind, isTyVar, isId )
import VarSet
import Subst		( mkTyVarSubst, substTy )
import Name		( getSrcLoc )
import PprCore
import ErrUtils		( doIfSet, dumpIfSet_core, ghcExit, Message, showPass,
			  ErrMsg, addErrLocHdrLine, pprBagOfErrors,
                          WarnMsg, pprBagOfWarnings)
import SrcLoc		( SrcLoc, noSrcLoc )
import Type		( Type, tyVarsOfType,
			  splitFunTy_maybe, mkTyVarTy,
			  splitForAllTy_maybe, splitTyConApp_maybe, splitTyConApp,
			  isUnLiftedType, typeKind, 
			  isUnboxedTupleType,
			  hasMoreBoxityInfo
			)
import TyCon		( isPrimTyCon )
import BasicTypes	( RecFlag(..), isNonRec )
import CmdLineOpts
import Maybe
import Outputable

infixr 9 `thenL`, `seqL`
\end{code}

%************************************************************************
%*									*
\subsection{Start and end pass}
%*									*
%************************************************************************

@beginPass@ and @endPass@ don't really belong here, but it makes a convenient
place for them.  They print out stuff before and after core passes,
and do Core Lint when necessary.

\begin{code}
endPass :: DynFlags -> String -> DynFlag -> [CoreBind] -> IO [CoreBind]
endPass dflags pass_name dump_flag binds
  = do  
        (binds, _) <- endPassWithRules dflags pass_name dump_flag binds Nothing
        return binds

endPassWithRules :: DynFlags -> String -> DynFlag -> [CoreBind] 
		 -> Maybe RuleBase
                 -> IO ([CoreBind], Maybe RuleBase)
endPassWithRules dflags pass_name dump_flag binds rules
  = do 
        -- ToDo: force the rules?

	-- Report result size if required
	-- This has the side effect of forcing the intermediate to be evaluated
	if verbosity dflags >= 2 then
	   hPutStrLn stdout ("    Result size = " ++ show (coreBindsSize binds))
	 else
	   return ()

	-- Report verbosely, if required
	dumpIfSet_core dflags dump_flag pass_name
		  (pprCoreBindings binds $$ case rules of
                                              Nothing -> empty
                                              Just rb -> pprRuleBase rb)

	-- Type check
	lintCoreBindings dflags pass_name binds
        -- ToDo: lint the rules

	return (binds, rules)
\end{code}


%************************************************************************
%*									*
\subsection[lintCoreBindings]{@lintCoreBindings@: Top-level interface}
%*									*
%************************************************************************

Checks that a set of core bindings is well-formed.  The PprStyle and String
just control what we print in the event of an error.  The Bool value
indicates whether we have done any specialisation yet (in which case we do
some extra checks).

We check for
	(a) type errors
	(b) Out-of-scope type variables
	(c) Out-of-scope local variables
	(d) Ill-kinded types

If we have done specialisation the we check that there are
	(a) No top-level bindings of primitive (unboxed type)

Outstanding issues:

    --
    -- Things are *not* OK if:
    --
    -- * Unsaturated type app before specialisation has been done;
    --
    -- * Oversaturated type app after specialisation (eta reduction
    --   may well be happening...);

\begin{code}
lintCoreBindings :: DynFlags -> String -> [CoreBind] -> IO ()

lintCoreBindings dflags whoDunnit binds
  | not (dopt Opt_DoCoreLinting dflags)
  = return ()

lintCoreBindings dflags whoDunnit binds
  = case (initL (lint_binds binds)) of
      (Nothing, Nothing)       -> done_lint

      (Nothing, Just warnings) -> printDump (warn warnings) >>
                                  done_lint

      (Just bad_news, warns)   -> printDump (display bad_news warns)	>>
		                  ghcExit 1
  where
	-- Put all the top-level binders in scope at the start
	-- This is because transformation rules can bring something
	-- into use 'unexpectedly'
    lint_binds binds = addInScopeVars (bindersOfBinds binds) $
		       mapL lint_bind binds

    lint_bind (Rec prs)		= mapL (lintSingleBinding Recursive) prs	`seqL`
				  returnL ()
    lint_bind (NonRec bndr rhs) = lintSingleBinding NonRecursive (bndr,rhs)

    done_lint = doIfSet (verbosity dflags >= 2)
		        (hPutStr stdout ("*** Core Linted result of " ++ whoDunnit ++ "\n"))
    warn warnings
      = vcat [
                text ("*** Core Lint Warnings: in result of " ++ whoDunnit ++ " ***"),
                warnings,
                offender
        ]

    display bad_news warns
      = vcat [
		text ("*** Core Lint Errors: in result of " ++ whoDunnit ++ " ***"),
		bad_news,
                maybe offender warn warns  -- either offender or warnings (with offender)
        ]

    offender
      = vcat [
		ptext SLIT("*** Offending Program ***"),
		pprCoreBindings binds,
		ptext SLIT("*** End of Offense ***")
	]
\end{code}

%************************************************************************
%*									*
\subsection[lintUnfolding]{lintUnfolding}
%*									*
%************************************************************************

We use this to check all unfoldings that come in from interfaces
(it is very painful to catch errors otherwise):

\begin{code}
lintUnfolding :: DynFlags 
	      -> SrcLoc
	      -> [Var]		-- Treat these as in scope
	      -> CoreExpr
	      -> (Maybe Message, Maybe Message)		-- (Nothing,_) => OK

lintUnfolding dflags locn vars expr
  | not (dopt Opt_DoCoreLinting dflags)
  = (Nothing, Nothing)

  | otherwise
  = initL (addLoc (ImportedUnfolding locn) $
	   addInScopeVars vars	           $
	   lintCoreExpr expr)
\end{code}

%************************************************************************
%*									*
\subsection[lintCoreBinding]{lintCoreBinding}
%*									*
%************************************************************************

Check a core binding, returning the list of variables bound.

\begin{code}
lintSingleBinding rec_flag (binder,rhs)
  = addLoc (RhsOf binder) $

	-- Check the rhs
    lintCoreExpr rhs				`thenL` \ ty ->

	-- Check match to RHS type
    lintBinder binder				`seqL`
    checkTys binder_ty ty (mkRhsMsg binder ty)	`seqL`

	-- Check (not isUnLiftedType) (also checks for bogus unboxed tuples)
    checkL (not (isUnLiftedType binder_ty)
            || (isNonRec rec_flag && exprOkForSpeculation rhs))
 	   (mkRhsPrimMsg binder rhs)		`seqL`

        -- Check whether binder's specialisations contain any out-of-scope variables
    mapL (checkBndrIdInScope binder) bndr_vars	`seqL`
    returnL ()
	  
	-- We should check the unfolding, if any, but this is tricky because
	-- the unfolding is a SimplifiableCoreExpr. Give up for now.
  where
    binder_ty = idType binder
    bndr_vars = varSetElems (idFreeVars binder)
\end{code}

%************************************************************************
%*									*
\subsection[lintCoreExpr]{lintCoreExpr}
%*									*
%************************************************************************

\begin{code}
lintCoreExpr :: CoreExpr -> LintM Type

lintCoreExpr (Var var) = checkIdInScope var `seqL` returnL (idType var)
lintCoreExpr (Lit lit) = returnL (literalType lit)

lintCoreExpr (Note (Coerce to_ty from_ty) expr)
  = lintCoreExpr expr 	`thenL` \ expr_ty ->
    lintTy to_ty	`seqL`
    lintTy from_ty	`seqL`
    checkTys from_ty expr_ty (mkCoerceErr from_ty expr_ty)	`seqL`
    returnL to_ty

lintCoreExpr (Note other_note expr)
  = lintCoreExpr expr

lintCoreExpr (Let (NonRec bndr rhs) body)
  = lintSingleBinding NonRecursive (bndr,rhs)	`seqL`
    addLoc (BodyOfLetRec [bndr])
	   (addInScopeVars [bndr] (lintCoreExpr body))

lintCoreExpr (Let (Rec pairs) body)
  = addInScopeVars bndrs	$
    mapL (lintSingleBinding Recursive) pairs	`seqL`
    addLoc (BodyOfLetRec bndrs) (lintCoreExpr body)
  where
    bndrs = map fst pairs

lintCoreExpr e@(App fun arg)
  = lintCoreExpr fun 	`thenL` \ ty ->
    addLoc (AnExpr e)	$
    lintCoreArg ty arg

lintCoreExpr (Lam var expr)
  = addLoc (LambdaBodyOf var)	$
    (if isId var then    
       checkL (not (isUnboxedTupleType (idType var))) (mkUnboxedTupleMsg var)
     else
       returnL ())
				`seqL`
    (addInScopeVars [var]	$
     lintCoreExpr expr		`thenL` \ ty ->

     returnL (mkPiType var ty))

lintCoreExpr e@(Case scrut var alts)
 = 	-- Check the scrutinee
   lintCoreExpr scrut			`thenL` \ scrut_ty ->

	-- Check the binder
   lintBinder var						`seqL`

    	-- If this is an unboxed tuple case, then the binder must be dead
   {-
   checkL (if isUnboxedTupleType (idType var) 
		then isDeadBinder var 
		else True) (mkUnboxedTupleMsg var)		`seqL`
   -}
		
   checkTys (idType var) scrut_ty (mkScrutMsg var scrut_ty)	`seqL`

   addInScopeVars [var]				(

	-- Check the alternatives
   checkAllCasesCovered e scrut_ty alts	`seqL`

   mapL (lintCoreAlt scrut_ty) alts		`thenL` \ (alt_ty : alt_tys) ->
   mapL (check alt_ty) alt_tys			`seqL`
   returnL alt_ty)
 where
   check alt_ty1 alt_ty2 = checkTys alt_ty1 alt_ty2 (mkCaseAltMsg e)

lintCoreExpr e@(Type ty)
  = addErrL (mkStrangeTyMsg e)
\end{code}

%************************************************************************
%*									*
\subsection[lintCoreArgs]{lintCoreArgs}
%*									*
%************************************************************************

The basic version of these functions checks that the argument is a
subtype of the required type, as one would expect.

\begin{code}
lintCoreArgs :: Type -> [CoreArg] -> LintM Type
lintCoreArgs = lintCoreArgs0 checkTys

lintCoreArg :: Type -> CoreArg -> LintM Type
lintCoreArg = lintCoreArg0 checkTys
\end{code}

The primitive version of these functions takes a check argument,
allowing a different comparison.

\begin{code}
lintCoreArgs0 check_tys ty [] = returnL ty
lintCoreArgs0 check_tys ty (a : args)
  = lintCoreArg0  check_tys ty a	`thenL` \ res ->
    lintCoreArgs0 check_tys res args

lintCoreArg0 check_tys ty a@(Type arg_ty)
  = lintTy arg_ty			`seqL`
    lintTyApp ty arg_ty

lintCoreArg0 check_tys fun_ty arg
  = -- Make sure function type matches argument
    lintCoreExpr arg		`thenL` \ arg_ty ->
    let
      err = mkAppMsg fun_ty arg_ty
    in
    case splitFunTy_maybe fun_ty of
      Just (arg,res) -> check_tys arg arg_ty err `seqL`
                        returnL res
      _              -> addErrL err
\end{code}

\begin{code}
lintTyApp ty arg_ty 
  = case splitForAllTy_maybe ty of
      Nothing -> addErrL (mkTyAppMsg ty arg_ty)

      Just (tyvar,body) ->
        if not (isTyVar tyvar) then addErrL (mkTyAppMsg ty arg_ty) else
	let
	    tyvar_kind = tyVarKind tyvar
	    argty_kind = typeKind arg_ty
	in
	if argty_kind `hasMoreBoxityInfo` tyvar_kind
		-- Arg type might be boxed for a function with an uncommitted
		-- tyvar; notably this is used so that we can give
		-- 	error :: forall a:*. String -> a
		-- and then apply it to both boxed and unboxed types.
	 then
	    returnL (substTy (mkTyVarSubst [tyvar] [arg_ty]) body)
	else
	    addErrL (mkKindErrMsg tyvar arg_ty)

lintTyApps fun_ty []
  = returnL fun_ty

lintTyApps fun_ty (arg_ty : arg_tys)
  = lintTyApp fun_ty arg_ty		`thenL` \ fun_ty' ->
    lintTyApps fun_ty' arg_tys
\end{code}



%************************************************************************
%*									*
\subsection[lintCoreAlts]{lintCoreAlts}
%*									*
%************************************************************************

\begin{code}
checkAllCasesCovered :: CoreExpr -> Type -> [CoreAlt] -> LintM ()

checkAllCasesCovered e ty [] = addErrL (mkNullAltsMsg e)

checkAllCasesCovered e ty [(DEFAULT,_,_)] = nopL

checkAllCasesCovered e scrut_ty alts
  = case splitTyConApp_maybe scrut_ty of {
	Nothing	-> addErrL (badAltsMsg e);
	Just (tycon, tycon_arg_tys) ->

    if isPrimTyCon tycon then
	checkL (hasDefault alts) (nonExhaustiveAltsMsg e)
    else
{-		No longer needed
#ifdef DEBUG
	-- Algebraic cases are not necessarily exhaustive, because
	-- the simplifer correctly eliminates case that can't 
	-- possibly match.
	-- This code just emits a message to say so
    let
	missing_cons    = filter not_in_alts (tyConDataCons tycon)
	not_in_alts con = all (not_in_alt con) alts
	not_in_alt con (DataCon con', _, _) = con /= con'
	not_in_alt con other		    = True

	case_bndr = case e of { Case _ bndr alts -> bndr }
    in
    if not (hasDefault alts || null missing_cons) then
	pprTrace "Exciting (but not a problem)!  Non-exhaustive case:"
		 (ppr case_bndr <+> ppr missing_cons)
		 nopL
    else
#endif
-}
    nopL }

hasDefault []			  = False
hasDefault ((DEFAULT,_,_) : alts) = True
hasDefault (alt		  : alts) = hasDefault alts
\end{code}

\begin{code}
lintCoreAlt :: Type  			-- Type of scrutinee
	    -> CoreAlt
	    -> LintM Type		-- Type of alternatives

lintCoreAlt scrut_ty alt@(DEFAULT, args, rhs)
  = checkL (null args) (mkDefaultArgsMsg args)	`seqL`
    lintCoreExpr rhs

lintCoreAlt scrut_ty alt@(LitAlt lit, args, rhs)
  = checkL (null args) (mkDefaultArgsMsg args)	`seqL`
    checkTys lit_ty scrut_ty
	     (mkBadPatMsg lit_ty scrut_ty)	`seqL`
    lintCoreExpr rhs
  where
    lit_ty = literalType lit

lintCoreAlt scrut_ty alt@(DataAlt con, args, rhs)
  = addLoc (CaseAlt alt) (

    mapL (\arg -> checkL (not (isUnboxedTupleType (idType arg)))
			(mkUnboxedTupleMsg arg)) args `seqL`

    addInScopeVars args (

	-- Check the pattern
	-- Scrutinee type must be a tycon applicn; checked by caller
	-- This code is remarkably compact considering what it does!
	-- NB: args must be in scope here so that the lintCoreArgs line works.
    case splitTyConApp scrut_ty of { (tycon, tycon_arg_tys) ->
	lintTyApps (dataConRepType con) tycon_arg_tys	`thenL` \ con_type ->
	lintCoreArgs con_type (map mk_arg args)		`thenL` \ con_result_ty ->
	checkTys con_result_ty scrut_ty (mkBadPatMsg con_result_ty scrut_ty)
    }						`seqL`

	-- Check the RHS
    lintCoreExpr rhs
    ))
  where
    mk_arg b | isTyVar b = Type (mkTyVarTy b)
	     | isId    b = Var b
             | otherwise = pprPanic "lintCoreAlt:mk_arg " (ppr b)
\end{code}

%************************************************************************
%*									*
\subsection[lint-types]{Types}
%*									*
%************************************************************************

\begin{code}
lintBinder :: Var -> LintM ()
lintBinder v = nopL
-- ToDo: lint its type
-- ToDo: lint its rules

lintTy :: Type -> LintM ()
lintTy ty = mapL checkIdInScope (varSetElems (tyVarsOfType ty))	`seqL`
	    returnL ()
	-- ToDo: check the kind structure of the type
\end{code}

    
%************************************************************************
%*									*
\subsection[lint-monad]{The Lint monad}
%*									*
%************************************************************************

\begin{code}
type LintM a = [LintLocInfo] 	-- Locations
	    -> IdSet		-- Local vars in scope
	    -> Bag ErrMsg	-- Error messages so far
            -> Bag WarnMsg      -- Warning messages so far
	    -> (Maybe a, Bag ErrMsg, Bag WarnMsg)  -- Result and error/warning messages (if any)

data LintLocInfo
  = RhsOf Id		-- The variable bound
  | LambdaBodyOf Id	-- The lambda-binder
  | BodyOfLetRec [Id]	-- One of the binders
  | CaseAlt CoreAlt	-- Pattern of a case alternative
  | AnExpr CoreExpr	-- Some expression
  | ImportedUnfolding SrcLoc -- Some imported unfolding (ToDo: say which)
\end{code}

\begin{code}
initL :: LintM a -> (Maybe Message {- errors -}, Maybe Message {- warnings -})
initL m
  = case m [] emptyVarSet emptyBag emptyBag of
      (_, errs, warns) -> (ifNonEmptyBag errs  pprBagOfErrors,
                           ifNonEmptyBag warns pprBagOfWarnings)
  where
    ifNonEmptyBag bag f | isEmptyBag bag = Nothing
                        | otherwise      = Just (f bag)

returnL :: a -> LintM a
returnL r loc scope errs warns = (Just r, errs, warns)

nopL :: LintM a
nopL loc scope errs warns = (Nothing, errs, warns)

thenL :: LintM a -> (a -> LintM b) -> LintM b
thenL m k loc scope errs warns
  = case m loc scope errs warns of
      (Just r, errs', warns')  -> k r loc scope errs' warns'
      (Nothing, errs', warns') -> (Nothing, errs', warns')

seqL :: LintM a -> LintM b -> LintM b
seqL m k loc scope errs warns
  = case m loc scope errs warns of
      (_, errs', warns') -> k loc scope errs' warns'

mapL :: (a -> LintM b) -> [a] -> LintM [b]
mapL f [] = returnL []
mapL f (x:xs)
  = f x 	`thenL` \ r ->
    mapL f xs	`thenL` \ rs ->
    returnL (r:rs)
\end{code}

\begin{code}
checkL :: Bool -> Message -> LintM ()
checkL True  msg = nopL
checkL False msg = addErrL msg

addErrL :: Message -> LintM a
addErrL msg loc scope errs warns = (Nothing, addErr errs msg loc, warns)

addWarnL :: Message -> LintM a
addWarnL msg loc scope errs warns = (Nothing, errs, addErr warns msg loc)

addErr :: Bag ErrMsg -> Message -> [LintLocInfo] -> Bag ErrMsg
-- errors or warnings, actually... they're the same type.
addErr errs_so_far msg locs
  = ASSERT( not (null locs) )
    errs_so_far `snocBag` mk_msg msg
  where
   (loc, cxt1) = dumpLoc (head locs)
   cxts        = [snd (dumpLoc loc) | loc <- locs]   
   context     | opt_PprStyle_Debug = vcat (reverse cxts) $$ cxt1
	       | otherwise	    = cxt1
 
   mk_msg msg = addErrLocHdrLine loc context msg

addLoc :: LintLocInfo -> LintM a -> LintM a
addLoc extra_loc m loc scope errs warns
  = m (extra_loc:loc) scope errs warns

addInScopeVars :: [Var] -> LintM a -> LintM a
addInScopeVars ids m loc scope errs warns
  = m loc (scope `unionVarSet` mkVarSet ids) errs warns
\end{code}

\begin{code}
checkIdInScope :: Var -> LintM ()
checkIdInScope id 
  = checkInScope (ptext SLIT("is out of scope")) id

checkBndrIdInScope :: Var -> Var -> LintM ()
checkBndrIdInScope binder id 
  = checkInScope msg id
    where
     msg = ptext SLIT("is out of scope inside info for") <+> 
	   ppr binder

checkInScope :: SDoc -> Var -> LintM ()
checkInScope loc_msg var loc scope errs warns
  |  mustHaveLocalBinding var && not (var `elemVarSet` scope)
  = (Nothing, addErr errs (hsep [ppr var, loc_msg]) loc, warns)
  | otherwise
  = nopL loc scope errs warns

checkTys :: Type -> Type -> Message -> LintM ()
-- check ty2 is subtype of ty1 (ie, has same structure but usage
-- annotations need only be consistent, not equal)
checkTys ty1 ty2 msg
  | ty1 == ty2 = nopL
  | otherwise  = addErrL msg
\end{code}


%************************************************************************
%*									*
\subsection{Error messages}
%*									*
%************************************************************************

\begin{code}
dumpLoc (RhsOf v)
  = (getSrcLoc v, brackets (ptext SLIT("RHS of") <+> pp_binders [v]))

dumpLoc (LambdaBodyOf b)
  = (getSrcLoc b, brackets (ptext SLIT("in body of lambda with binder") <+> pp_binder b))

dumpLoc (BodyOfLetRec [])
  = (noSrcLoc, brackets (ptext SLIT("In body of a letrec with no binders")))

dumpLoc (BodyOfLetRec bs@(_:_))
  = ( getSrcLoc (head bs), brackets (ptext SLIT("in body of letrec with binders") <+> pp_binders bs))

dumpLoc (AnExpr e)
  = (noSrcLoc, text "In the expression:" <+> ppr e)

dumpLoc (CaseAlt (con, args, rhs))
  = (noSrcLoc, text "In a case pattern:" <+> parens (ppr con <+> ppr args))

dumpLoc (ImportedUnfolding locn)
  = (locn, brackets (ptext SLIT("in an imported unfolding")))

pp_binders :: [Var] -> SDoc
pp_binders bs = sep (punctuate comma (map pp_binder bs))

pp_binder :: Var -> SDoc
pp_binder b | isId b    = hsep [ppr b, dcolon, ppr (idType b)]
            | isTyVar b = hsep [ppr b, dcolon, ppr (tyVarKind b)]
\end{code}

\begin{code}
------------------------------------------------------
--	Messages for case expressions

mkNullAltsMsg :: CoreExpr -> Message
mkNullAltsMsg e 
  = hang (text "Case expression with no alternatives:")
	 4 (ppr e)

mkDefaultArgsMsg :: [Var] -> Message
mkDefaultArgsMsg args 
  = hang (text "DEFAULT case with binders")
	 4 (ppr args)

mkCaseAltMsg :: CoreExpr -> Message
mkCaseAltMsg e
  = hang (text "Type of case alternatives not the same:")
	 4 (ppr e)

mkScrutMsg :: Id -> Type -> Message
mkScrutMsg var scrut_ty
  = vcat [text "Result binder in case doesn't match scrutinee:" <+> ppr var,
	  text "Result binder type:" <+> ppr (idType var),
	  text "Scrutinee type:" <+> ppr scrut_ty]

badAltsMsg :: CoreExpr -> Message
badAltsMsg e
  = hang (text "Case statement scrutinee is not a data type:")
	 4 (ppr e)

nonExhaustiveAltsMsg :: CoreExpr -> Message
nonExhaustiveAltsMsg e
  = hang (text "Case expression with non-exhaustive alternatives")
	 4 (ppr e)

mkBadPatMsg :: Type -> Type -> Message
mkBadPatMsg con_result_ty scrut_ty
  = vcat [
	text "In a case alternative, pattern result type doesn't match scrutinee type:",
	text "Pattern result type:" <+> ppr con_result_ty,
	text "Scrutinee type:" <+> ppr scrut_ty
    ]

------------------------------------------------------
--	Other error messages

mkAppMsg :: Type -> Type -> Message
mkAppMsg fun arg
  = vcat [ptext SLIT("Argument value doesn't match argument type:"),
	      hang (ptext SLIT("Fun type:")) 4 (ppr fun),
	      hang (ptext SLIT("Arg type:")) 4 (ppr arg)]

mkKindErrMsg :: TyVar -> Type -> Message
mkKindErrMsg tyvar arg_ty
  = vcat [ptext SLIT("Kinds don't match in type application:"),
	  hang (ptext SLIT("Type variable:"))
		 4 (ppr tyvar <+> dcolon <+> ppr (tyVarKind tyvar)),
	  hang (ptext SLIT("Arg type:"))   
	         4 (ppr arg_ty <+> dcolon <+> ppr (typeKind arg_ty))]

mkTyAppMsg :: Type -> Type -> Message
mkTyAppMsg ty arg_ty
  = vcat [text "Illegal type application:",
	      hang (ptext SLIT("Exp type:"))
		 4 (ppr ty <+> dcolon <+> ppr (typeKind ty)),
	      hang (ptext SLIT("Arg type:"))   
	         4 (ppr arg_ty <+> dcolon <+> ppr (typeKind arg_ty))]

mkRhsMsg :: Id -> Type -> Message
mkRhsMsg binder ty
  = vcat
    [hsep [ptext SLIT("The type of this binder doesn't match the type of its RHS:"),
	    ppr binder],
     hsep [ptext SLIT("Binder's type:"), ppr (idType binder)],
     hsep [ptext SLIT("Rhs type:"), ppr ty]]

mkRhsPrimMsg :: Id -> CoreExpr -> Message
mkRhsPrimMsg binder rhs
  = vcat [hsep [ptext SLIT("The type of this binder is primitive:"),
		     ppr binder],
	      hsep [ptext SLIT("Binder's type:"), ppr (idType binder)]
	     ]

mkUnboxedTupleMsg :: Id -> Message
mkUnboxedTupleMsg binder
  = vcat [hsep [ptext SLIT("A variable has unboxed tuple type:"), ppr binder],
	  hsep [ptext SLIT("Binder's type:"), ppr (idType binder)]]

mkCoerceErr from_ty expr_ty
  = vcat [ptext SLIT("From-type of Coerce differs from type of enclosed expression"),
	  ptext SLIT("From-type:") <+> ppr from_ty,
	  ptext SLIT("Type of enclosed expr:") <+> ppr expr_ty
    ]

mkStrangeTyMsg e
  = ptext SLIT("Type where expression expected:") <+> ppr e
\end{code}
