%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[HsExpr]{Abstract Haskell syntax: expressions}

\begin{code}
module HsExpr where

#include "HsVersions.h"

-- friends:
import HsBinds		( HsBinds(..), nullBinds )
import HsTypes		( PostTcType )
import HsLit		( HsLit, HsOverLit )
import BasicTypes	( Fixity(..) )
import HsTypes		( HsType )
import HsImpExp		( isOperator )

-- others:
import Name		( Name )
import ForeignCall	( Safety )
import Outputable	
import PprType		( pprParendType )
import Type		( Type  )
import Var		( TyVar )
import DataCon		( DataCon )
import CStrings		( CLabelString, pprCLabelString )
import BasicTypes	( IPName, Boxity, tupleParens )
import SrcLoc		( SrcLoc )
import FastString
\end{code}

%************************************************************************
%*									*
\subsection{Expressions proper}
%*									*
%************************************************************************

\begin{code}
data HsExpr id pat
  = HsVar	id		-- variable
  | HsIPVar	(IPName id)	-- implicit parameter
  | HsOverLit	HsOverLit	-- Overloaded literals; eliminated by type checker
  | HsLit	HsLit		-- Simple (non-overloaded) literals

  | HsLam	(Match  id pat)	-- lambda
  | HsApp	(HsExpr id pat)	-- application
		(HsExpr id pat)

  -- Operator applications:
  -- NB Bracketed ops such as (+) come out as Vars.

  -- NB We need an expr for the operator in an OpApp/Section since
  -- the typechecker may need to apply the operator to a few types.

  | OpApp	(HsExpr id pat)	-- left operand
		(HsExpr id pat)	-- operator
		Fixity				-- Renamer adds fixity; bottom until then
		(HsExpr id pat)	-- right operand

  -- We preserve prefix negation and parenthesis for the precedence parser.
  -- They are eventually removed by the type checker.

  | NegApp	(HsExpr id pat)	-- negated expr
		Name		-- Name of 'negate' (see RnEnv.lookupSyntaxName)

  | HsPar	(HsExpr id pat)	-- parenthesised expr

  | SectionL	(HsExpr id pat)	-- operand
		(HsExpr id pat)	-- operator
  | SectionR	(HsExpr id pat)	-- operator
		(HsExpr id pat)	-- operand
				
  | HsCase	(HsExpr id pat)
		[Match id pat]
		SrcLoc

  | HsIf	(HsExpr id pat)	--  predicate
		(HsExpr id pat)	--  then part
		(HsExpr id pat)	--  else part
		SrcLoc

  | HsLet	(HsBinds id pat)	-- let(rec)
		(HsExpr  id pat)

  | HsWith	(HsExpr id pat)	-- implicit parameter binding
  		[(IPName id, HsExpr id pat)]
		Bool		-- True <=> this was a 'with' binding
				--  (tmp, until 'with' is removed)

  | HsDo	HsDoContext
		[Stmt id pat]	-- "do":one or more stmts
		[id]		-- Ids for [return,fail,>>=,>>]
				--	Brutal but simple
				-- Before type checking, used for rebindable syntax
		PostTcType	-- Type of the whole expression
		SrcLoc

  | ExplicitList		-- syntactic list
		PostTcType	-- Gives type of components of list
		[HsExpr id pat]

  | ExplicitPArr		-- syntactic parallel array: [:e1, ..., en:]
		PostTcType	-- type of elements of the parallel array
		[HsExpr id pat]

  | ExplicitTuple		-- tuple
		[HsExpr id pat]
				-- NB: Unit is ExplicitTuple []
				-- for tuples, we can get the types
				-- direct from the components
		Boxity


	-- Record construction
  | RecordCon	id				-- The constructor
		(HsRecordBinds id pat)

  | RecordConOut DataCon
		(HsExpr id pat)		-- Data con Id applied to type args
		(HsRecordBinds id pat)


	-- Record update
  | RecordUpd	(HsExpr id pat)
		(HsRecordBinds id pat)

  | RecordUpdOut (HsExpr id pat)	-- TRANSLATION
		 Type			-- Type of *input* record
		 Type			-- Type of *result* record (may differ from
					-- 	type of input record)
		 (HsRecordBinds id pat)

  | ExprWithTySig			-- signature binding
		(HsExpr id pat)
		(HsType id)
  | ArithSeqIn				-- arithmetic sequence
		(ArithSeqInfo id pat)
  | ArithSeqOut
		(HsExpr id pat)		-- (typechecked, of course)
		(ArithSeqInfo id pat)
  | PArrSeqIn           		-- arith. sequence for parallel array
		(ArithSeqInfo id pat)	-- [:e1..e2:] or [:e1, e2..e3:]
  | PArrSeqOut
		(HsExpr id pat)		-- (typechecked, of course)
		(ArithSeqInfo id pat)

  | HsCCall	CLabelString	-- call into the C world; string is
		[HsExpr id pat]	-- the C function; exprs are the
				-- arguments to pass.
		Safety		-- True <=> might cause Haskell
				-- garbage-collection (must generate
				-- more paranoid code)
		Bool		-- True <=> it's really a "casm"
				-- NOTE: this CCall is the *boxed*
				-- version; the desugarer will convert
				-- it into the unboxed "ccall#".
		PostTcType	-- The result type; will be *bottom*
				-- until the typechecker gets ahold of it

  | HsSCC	FastString	-- "set cost centre" (_scc_) annotation
		(HsExpr id pat) -- expr whose cost is to be measured

\end{code}

These constructors only appear temporarily in the parser.
The renamer translates them into the Right Thing.

\begin{code}
  | EWildPat			-- wildcard

  | EAsPat	id		-- as pattern
		(HsExpr id pat)

  | ELazyPat	(HsExpr id pat) -- ~ pattern

  | HsType      (HsType id)     -- Explicit type argument; e.g  f {| Int |} x y
\end{code}

Everything from here on appears only in typechecker output.

\begin{code}
  | TyLam			-- TRANSLATION
		[TyVar]
		(HsExpr id pat)
  | TyApp			-- TRANSLATION
		(HsExpr id pat) -- generated by Spec
		[Type]

  -- DictLam and DictApp are "inverses"
  |  DictLam
		[id]
		(HsExpr id pat)
  |  DictApp
		(HsExpr id pat)
		[id]

type HsRecordBinds id pat
  = [(id, HsExpr id pat, Bool)]
	-- True <=> source code used "punning",
	-- i.e. {op1, op2} rather than {op1=e1, op2=e2}
\end{code}

A @Dictionary@, unless of length 0 or 1, becomes a tuple.  A
@ClassDictLam dictvars methods expr@ is, therefore:
\begin{verbatim}
\ x -> case x of ( dictvars-and-methods-tuple ) -> expr
\end{verbatim}

\begin{code}
instance (Outputable id, Outputable pat) =>
		Outputable (HsExpr id pat) where
    ppr expr = pprExpr expr
\end{code}

\begin{code}
pprExpr :: (Outputable id, Outputable pat)
        => HsExpr id pat -> SDoc

pprExpr e = pprDeeper (ppr_expr e)
pprBinds b = pprDeeper (ppr b)

ppr_expr (HsVar v) 
	-- Put it in parens if it's an operator
  | isOperator v = parens (ppr v)
  | otherwise    = ppr v

ppr_expr (HsIPVar v)     = ppr v
ppr_expr (HsLit lit)     = ppr lit
ppr_expr (HsOverLit lit) = ppr lit

ppr_expr (HsLam match)
  = hsep [char '\\', nest 2 (pprMatch LambdaExpr match)]

ppr_expr expr@(HsApp e1 e2)
  = let (fun, args) = collect_args expr [] in
    (ppr_expr fun) <+> (sep (map ppr_expr args))
  where
    collect_args (HsApp fun arg) args = collect_args fun (arg:args)
    collect_args fun		 args = (fun, args)

ppr_expr (OpApp e1 op fixity e2)
  = case op of
      HsVar v -> pp_infixly v
      _	      -> pp_prefixly
  where
    pp_e1 = pprParendExpr e1		-- Add parens to make precedence clear
    pp_e2 = pprParendExpr e2

    pp_prefixly
      = hang (pprExpr op) 4 (sep [pp_e1, pp_e2])

    pp_infixly v
      = sep [pp_e1, hsep [pp_v_op, pp_e2]]
      where
        pp_v_op | isOperator v = ppr v
		| otherwise    = char '`' <> ppr v <> char '`'
	        -- Put it in backquotes if it's not an operator already

ppr_expr (NegApp e _) = char '-' <+> pprParendExpr e

ppr_expr (HsPar e) = parens (ppr_expr e)

ppr_expr (SectionL expr op)
  = case op of
      HsVar v -> pp_infixly v
      _	      -> pp_prefixly
  where
    pp_expr = pprParendExpr expr

    pp_prefixly = hang (hsep [text " \\ x_ ->", ppr op])
		       4 (hsep [pp_expr, ptext SLIT("x_ )")])
    pp_infixly v = parens (sep [pp_expr, ppr v])

ppr_expr (SectionR op expr)
  = case op of
      HsVar v -> pp_infixly v
      _	      -> pp_prefixly
  where
    pp_expr = pprParendExpr expr

    pp_prefixly = hang (hsep [text "( \\ x_ ->", ppr op, ptext SLIT("x_")])
		       4 ((<>) pp_expr rparen)
    pp_infixly v
      = parens (sep [ppr v, pp_expr])

ppr_expr (HsCase expr matches _)
  = sep [ sep [ptext SLIT("case"), nest 4 (pprExpr expr), ptext SLIT("of")],
	    nest 2 (pprMatches CaseAlt matches) ]

ppr_expr (HsIf e1 e2 e3 _)
  = sep [hsep [ptext SLIT("if"), nest 2 (pprExpr e1), ptext SLIT("then")],
	   nest 4 (pprExpr e2),
	   ptext SLIT("else"),
	   nest 4 (pprExpr e3)]

-- special case: let ... in let ...
ppr_expr (HsLet binds expr@(HsLet _ _))
  = sep [hang (ptext SLIT("let")) 2 (hsep [pprBinds binds, ptext SLIT("in")]),
	 pprExpr expr]

ppr_expr (HsLet binds expr)
  = sep [hang (ptext SLIT("let")) 2 (pprBinds binds),
	 hang (ptext SLIT("in"))  2 (ppr expr)]

ppr_expr (HsWith expr binds is_with)
  = sep [hang (ptext SLIT("let")) 2 (pp_ipbinds binds),
	 hang (ptext SLIT("in"))  2 (ppr expr)]

ppr_expr (HsDo do_or_list_comp stmts _ _ _) = pprDo do_or_list_comp stmts

ppr_expr (ExplicitList _ exprs)
  = brackets (fsep (punctuate comma (map ppr_expr exprs)))

ppr_expr (ExplicitPArr _ exprs)
  = pabrackets (fsep (punctuate comma (map ppr_expr exprs)))

ppr_expr (ExplicitTuple exprs boxity)
  = tupleParens boxity (sep (punctuate comma (map ppr_expr exprs)))

ppr_expr (RecordCon con_id rbinds)
  = pp_rbinds (ppr con_id) rbinds
ppr_expr (RecordConOut data_con con rbinds)
  = pp_rbinds (ppr con) rbinds

ppr_expr (RecordUpd aexp rbinds)
  = pp_rbinds (pprParendExpr aexp) rbinds
ppr_expr (RecordUpdOut aexp _ _ rbinds)
  = pp_rbinds (pprParendExpr aexp) rbinds

ppr_expr (ExprWithTySig expr sig)
  = hang (nest 2 (ppr_expr expr) <+> dcolon)
	 4 (ppr sig)

ppr_expr (ArithSeqIn info)
  = brackets (ppr info)
ppr_expr (ArithSeqOut expr info)
  = brackets (ppr info)

ppr_expr (PArrSeqIn info)
  = pabrackets (ppr info)
ppr_expr (PArrSeqOut expr info)
  = pabrackets (ppr info)

ppr_expr EWildPat = char '_'
ppr_expr (ELazyPat e) = char '~' <> pprParendExpr e
ppr_expr (EAsPat v e) = ppr v <> char '@' <> pprParendExpr e

ppr_expr (HsCCall fun args _ is_asm result_ty)
  = hang (if is_asm
	  then ptext SLIT("_casm_ ``") <> pprCLabelString fun <> ptext SLIT("''")
	  else ptext SLIT("_ccall_") <+> pprCLabelString fun)
       4 (sep (map pprParendExpr args))

ppr_expr (HsSCC lbl expr)
  = sep [ ptext SLIT("_scc_") <+> doubleQuotes (ftext lbl), pprParendExpr expr ]

ppr_expr (TyLam tyvars expr)
  = hang (hsep [ptext SLIT("/\\"), interppSP tyvars, ptext SLIT("->")])
	 4 (ppr_expr expr)

ppr_expr (TyApp expr [ty])
  = hang (ppr_expr expr) 4 (pprParendType ty)

ppr_expr (TyApp expr tys)
  = hang (ppr_expr expr)
	 4 (brackets (interpp'SP tys))

ppr_expr (DictLam dictvars expr)
  = hang (hsep [ptext SLIT("\\{-dict-}"), interppSP dictvars, ptext SLIT("->")])
	 4 (ppr_expr expr)

ppr_expr (DictApp expr [dname])
  = hang (ppr_expr expr) 4 (ppr dname)

ppr_expr (DictApp expr dnames)
  = hang (ppr_expr expr)
	 4 (brackets (interpp'SP dnames))

ppr_expr (HsType id) = ppr id

-- add parallel array brackets around a document
--
pabrackets   :: SDoc -> SDoc
pabrackets p  = ptext SLIT("[:") <> p <> ptext SLIT(":]")    
\end{code}

Parenthesize unless very simple:
\begin{code}
pprParendExpr :: (Outputable id, Outputable pat)
	      => HsExpr id pat -> SDoc

pprParendExpr expr
  = let
	pp_as_was = pprExpr expr
    in
    case expr of
      HsLit l		    -> ppr l
      HsOverLit l 	    -> ppr l

      HsVar _		    -> pp_as_was
      HsIPVar _		    -> pp_as_was
      ExplicitList _ _      -> pp_as_was
      ExplicitPArr _ _      -> pp_as_was
      ExplicitTuple _ _	    -> pp_as_was
      HsPar _		    -> pp_as_was

      _			    -> parens pp_as_was
\end{code}

%************************************************************************
%*									*
\subsection{Record binds}
%*									*
%************************************************************************

\begin{code}
pp_rbinds :: (Outputable id, Outputable pat)
	      => SDoc 
	      -> HsRecordBinds id pat -> SDoc

pp_rbinds thing rbinds
  = hang thing 
	 4 (braces (sep (punctuate comma (map (pp_rbind) rbinds))))
  where
    pp_rbind (v, e, pun_flag) 
      = getPprStyle $ \ sty ->
        if pun_flag && userStyle sty then
	   ppr v
	else
	   hsep [ppr v, char '=', ppr e]
\end{code}

\begin{code}
pp_ipbinds :: (Outputable id, Outputable pat)
	   => [(IPName id, HsExpr id pat)] -> SDoc
pp_ipbinds pairs = hsep (punctuate semi (map pp_item pairs))
		 where
		   pp_item (id,rhs) = ppr id <+> equals <+> ppr_expr rhs
\end{code}


%************************************************************************
%*									*
\subsection{@Match@, @GRHSs@, and @GRHS@ datatypes}
%*									*
%************************************************************************

@Match@es are sets of pattern bindings and right hand sides for
functions, patterns or case branches. For example, if a function @g@
is defined as:
\begin{verbatim}
g (x,y) = y
g ((x:ys),y) = y+1,
\end{verbatim}
then \tr{g} has two @Match@es: @(x,y) = y@ and @((x:ys),y) = y+1@.

It is always the case that each element of an @[Match]@ list has the
same number of @pats@s inside it.  This corresponds to saying that
a function defined by pattern matching must have the same number of
patterns in each equation.

\begin{code}
data Match id pat
  = Match
	[pat]			-- The patterns
	(Maybe (HsType id))	-- A type signature for the result of the match
				--	Nothing after typechecking

	(GRHSs id pat)

-- GRHSs are used both for pattern bindings and for Matches
data GRHSs id pat	
  = GRHSs [GRHS id pat]		-- Guarded RHSs
	  (HsBinds id pat)	-- The where clause
	  PostTcType		-- Type of RHS (after type checking)

data GRHS id pat
  = GRHS  [Stmt id pat]		-- The RHS is the final ResultStmt
				-- I considered using a RetunStmt, but
				-- it printed 'wrong' in error messages 
	  SrcLoc

mkSimpleMatch :: [pat] -> HsExpr id pat -> Type -> SrcLoc -> Match id pat
mkSimpleMatch pats rhs rhs_ty locn
  = Match pats Nothing (GRHSs (unguardedRHS rhs locn) EmptyBinds rhs_ty)

unguardedRHS :: HsExpr id pat -> SrcLoc -> [GRHS id pat]
unguardedRHS rhs loc = [GRHS [ResultStmt rhs loc] loc]
\end{code}

@getMatchLoc@ takes a @Match@ and returns the
source-location gotten from the GRHS inside.
THis is something of a nuisance, but no more.

\begin{code}
getMatchLoc :: Match id pat -> SrcLoc
getMatchLoc (Match _ _ (GRHSs (GRHS _ loc : _) _ _)) = loc
\end{code}

We know the list must have at least one @Match@ in it.

\begin{code}
pprMatches :: (Outputable id, Outputable pat)
	   => HsMatchContext id -> [Match id pat] -> SDoc
pprMatches ctxt matches = vcat (map (pprMatch ctxt) matches)

-- Exported to HsBinds, which can't see the defn of HsMatchContext
pprFunBind :: (Outputable id, Outputable pat)
	   => id -> [Match id pat] -> SDoc
pprFunBind fun matches = pprMatches (FunRhs fun) matches

-- Exported to HsBinds, which can't see the defn of HsMatchContext
pprPatBind :: (Outputable id, Outputable pat)
	   => pat -> GRHSs id pat -> SDoc
pprPatBind pat grhss = sep [ppr pat, nest 4 (pprGRHSs PatBindRhs grhss)]


pprMatch :: (Outputable id, Outputable pat)
	   => HsMatchContext id -> Match id pat -> SDoc
pprMatch ctxt (Match pats maybe_ty grhss)
  = pp_name ctxt <+> sep [sep (map ppr pats), 
		     ppr_maybe_ty,
		     nest 2 (pprGRHSs ctxt grhss)]
  where
    pp_name (FunRhs fun) = ppr fun
    pp_name other	 = empty
    ppr_maybe_ty = case maybe_ty of
			Just ty -> dcolon <+> ppr ty
			Nothing -> empty


pprGRHSs :: (Outputable id, Outputable pat)
	 => HsMatchContext id -> GRHSs id pat -> SDoc
pprGRHSs ctxt (GRHSs grhss binds ty)
  = vcat (map (pprGRHS ctxt) grhss)
    $$
    (if nullBinds binds then empty
     else text "where" $$ nest 4 (pprDeeper (ppr binds)))


pprGRHS :: (Outputable id, Outputable pat)
	=> HsMatchContext id -> GRHS id pat -> SDoc

pprGRHS ctxt (GRHS [ResultStmt expr _] locn)
 =  pp_rhs ctxt expr

pprGRHS ctxt (GRHS guarded locn)
 = sep [char '|' <+> interpp'SP guards, pp_rhs ctxt expr]
 where
    ResultStmt expr _ = last guarded	-- Last stmt should be a ResultStmt for guards
    guards	      = init guarded

pp_rhs ctxt rhs = matchSeparator ctxt <+> pprDeeper (ppr rhs)
\end{code}



%************************************************************************
%*									*
\subsection{Do stmts and list comprehensions}
%*									*
%************************************************************************

\begin{code}
data Stmt id pat
  = BindStmt	pat (HsExpr id pat) SrcLoc
  | LetStmt	(HsBinds id pat)
  | ResultStmt	(HsExpr id pat)	SrcLoc			-- See notes that follow
  | ExprStmt	(HsExpr id pat)	PostTcType SrcLoc	-- See notes that follow
	-- The type is the *element type* of the expression
  | ParStmt	[[Stmt id pat]]				-- List comp only: parallel set of quals
  | ParStmtOut	[([id], [Stmt id pat])]			-- PLC after renaming; the ids are the binders
							-- bound by the stmts
\end{code}

ExprStmts and ResultStmts are a bit tricky, because what they mean
depends on the context.  Consider the following contexts:

	A do expression of type (m res_ty)
	~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
	* ExprStmt E any_ty:   do { ....; E; ... }
		E :: m any_ty
	  Translation: E >> ...
	
	* ResultStmt E:   do { ....; E }
		E :: m res_ty
	  Translation: E
	
	A list comprehensions of type [elt_ty]
	~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
	* ExprStmt E Bool:   [ .. | .... E ]
			[ .. | ..., E, ... ]
			[ .. | .... | ..., E | ... ]
		E :: Bool
	  Translation: if E then fail else ...

	* ResultStmt E:   [ E | ... ]
		E :: elt_ty
	  Translation: return E
	
	A guard list, guarding a RHS of type rhs_ty
	~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
	* ExprStmt E Bool:   f x | ..., E, ... = ...rhs...
		E :: Bool
	  Translation: if E then fail else ...
	
	* ResultStmt E:   f x | ...guards... = E
		E :: rhs_ty
	  Translation: E

Array comprehensions are handled like list comprehensions -=chak

\begin{code}
consLetStmt :: HsBinds id pat -> [Stmt id pat] -> [Stmt id pat]
consLetStmt EmptyBinds stmts = stmts
consLetStmt binds      stmts = LetStmt binds : stmts
\end{code}

\begin{code}
instance (Outputable id, Outputable pat) =>
		Outputable (Stmt id pat) where
    ppr stmt = pprStmt stmt

pprStmt (BindStmt pat expr _) = hsep [ppr pat, ptext SLIT("<-"), ppr expr]
pprStmt (LetStmt binds)       = hsep [ptext SLIT("let"), pprBinds binds]
pprStmt (ExprStmt expr _ _)   = ppr expr
pprStmt (ResultStmt expr _)   = ppr expr
pprStmt (ParStmt stmtss)
 = hsep (map (\stmts -> ptext SLIT("| ") <> ppr stmts) stmtss)
pprStmt (ParStmtOut stmtss)
 = hsep (map (\stmts -> ptext SLIT("| ") <> ppr stmts) stmtss)

pprDo :: (Outputable id, Outputable pat) 
      => HsDoContext -> [Stmt id pat] -> SDoc
pprDo DoExpr stmts   = hang (ptext SLIT("do")) 2 (vcat (map ppr stmts))
pprDo ListComp stmts = pprComp brackets   stmts
pprDo PArrComp stmts = pprComp pabrackets stmts

pprComp :: (Outputable id, Outputable pat) 
	=> (SDoc -> SDoc) -> [Stmt id pat] -> SDoc
pprComp brack stmts = brack $
		      hang (pprExpr expr <+> char '|')
			 4 (interpp'SP quals)
		    where
		      ResultStmt expr _ = last stmts  -- Last stmt should
		      quals	        = init stmts  -- be an ResultStmt
\end{code}

%************************************************************************
%*									*
\subsection{Enumerations and list comprehensions}
%*									*
%************************************************************************

\begin{code}
data ArithSeqInfo id pat
  = From	    (HsExpr id pat)
  | FromThen 	    (HsExpr id pat)
		    (HsExpr id pat)
  | FromTo	    (HsExpr id pat)
		    (HsExpr id pat)
  | FromThenTo	    (HsExpr id pat)
		    (HsExpr id pat)
		    (HsExpr id pat)
\end{code}

\begin{code}
instance (Outputable id, Outputable pat) =>
		Outputable (ArithSeqInfo id pat) where
    ppr (From e1)		= hcat [ppr e1, pp_dotdot]
    ppr (FromThen e1 e2)	= hcat [ppr e1, comma, space, ppr e2, pp_dotdot]
    ppr (FromTo e1 e3)	= hcat [ppr e1, pp_dotdot, ppr e3]
    ppr (FromThenTo e1 e2 e3)
      = hcat [ppr e1, comma, space, ppr e2, pp_dotdot, ppr e3]

pp_dotdot = ptext SLIT(" .. ")
\end{code}


%************************************************************************
%*									*
\subsection{HsMatchCtxt}
%*									*
%************************************************************************

\begin{code}
data HsMatchContext id	-- Context of a Match or Stmt
  = DoCtxt HsDoContext	-- Do-stmt or list comprehension
  | FunRhs id		-- Function binding for f
  | CaseAlt		-- Guard on a case alternative
  | LambdaExpr		-- Lambda
  | PatBindRhs		-- Pattern binding
  | RecUpd		-- Record update
  deriving ()

data HsDoContext = ListComp 
		 | DoExpr 
		 | PArrComp	-- parallel array comprehension
\end{code}

\begin{code}
isDoExpr (DoCtxt DoExpr) = True
isDoExpr other 		 = False
\end{code}

\begin{code}
matchSeparator (FunRhs _)   = ptext SLIT("=")
matchSeparator CaseAlt      = ptext SLIT("->") 
matchSeparator LambdaExpr   = ptext SLIT("->") 
matchSeparator PatBindRhs   = ptext SLIT("=") 
matchSeparator (DoCtxt _)   = ptext SLIT("<-")  
matchSeparator RecUpd       = panic "When is this used?"
\end{code}

\begin{code}
pprMatchContext (FunRhs fun) 	  = ptext SLIT("In the definition of") <+> quotes (ppr fun)
pprMatchContext CaseAlt	     	  = ptext SLIT("In a case alternative")
pprMatchContext RecUpd	     	  = ptext SLIT("In a record-update construct")
pprMatchContext PatBindRhs   	  = ptext SLIT("In a pattern binding")
pprMatchContext LambdaExpr   	  = ptext SLIT("In a lambda abstraction")
pprMatchContext (DoCtxt DoExpr)   = ptext SLIT("In a 'do' expression pattern binding")
pprMatchContext (DoCtxt ListComp) = 
  ptext SLIT("In a 'list comprehension' pattern binding")
pprMatchContext (DoCtxt PArrComp) = 
  ptext SLIT("In an 'array comprehension' pattern binding")

-- Used to generate the string for a *runtime* error message
matchContextErrString (FunRhs fun)    	= "function " ++ showSDoc (ppr fun)
matchContextErrString CaseAlt	      	= "case"
matchContextErrString PatBindRhs      	= "pattern binding"
matchContextErrString RecUpd	      	= "record update"
matchContextErrString LambdaExpr      	=  "lambda"
matchContextErrString (DoCtxt DoExpr)   = "'do' expression"
matchContextErrString (DoCtxt ListComp) = "list comprehension"
matchContextErrString (DoCtxt PArrComp) = "array comprehension"
\end{code}
