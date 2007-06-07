%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[PatSyntax]{Abstract Haskell syntax---patterns}

\begin{code}
module HsPat (
	Pat(..), InPat, OutPat, LPat, 
	
	HsConDetails(..), hsConArgs,
	HsRecField(..), mkRecField,

	mkPrefixConPat, mkCharLitPat, mkNilPat, mkCoPat,

	isBangHsBind,	
	patsAreAllCons, isConPat, isSigPat, isWildPat,
	patsAreAllLits,	isLitPat, isIrrefutableHsPat
    ) where

#include "HsVersions.h"


import {-# SOURCE #-} HsExpr		( SyntaxExpr )

-- friends:
import HsBinds
import HsLit
import HsTypes
import HsDoc
import BasicTypes
-- others:
import PprCore		( {- instance OutputableBndr TyVar -} )
import TysWiredIn
import Var
import DataCon
import TyCon
import Outputable	
import Type
import SrcLoc
\end{code}


\begin{code}
type InPat id  = LPat id	-- No 'Out' constructors
type OutPat id = LPat id	-- No 'In' constructors

type LPat id = Located (Pat id)

data Pat id
  =	------------ Simple patterns ---------------
    WildPat	PostTcType		-- Wild card
	-- The sole reason for a type on a WildPat is to
	-- support hsPatType :: Pat Id -> Type

  | VarPat	id			-- Variable
  | VarPatOut	id (DictBinds id)	-- Used only for overloaded Ids; the 
					-- bindings give its overloaded instances
  | LazyPat	(LPat id)		-- Lazy pattern
  | AsPat	(Located id) (LPat id)  -- As pattern
  | ParPat      (LPat id)		-- Parenthesised pattern
  | BangPat	(LPat id)		-- Bang patterng

	------------ Lists, tuples, arrays ---------------
  | ListPat	[LPat id]		-- Syntactic list
		PostTcType		-- The type of the elements
   	    	    
  | TuplePat	[LPat id]		-- Tuple
		Boxity			-- UnitPat is TuplePat []
		PostTcType
	-- You might think that the PostTcType was redundant, but it's essential
	--	data T a where
	--	  T1 :: Int -> T Int
	--	f :: (T a, a) -> Int
	--	f (T1 x, z) = z
	-- When desugaring, we must generate
	--	f = /\a. \v::a.  case v of (t::T a, w::a) ->
	--			 case t of (T1 (x::Int)) -> 
	-- Note the (w::a), NOT (w::Int), because we have not yet
	-- refined 'a' to Int.  So we must know that the second component
	-- of the tuple is of type 'a' not Int.  See selectMatchVar

  | PArrPat	[LPat id]		-- Syntactic parallel array
		PostTcType		-- The type of the elements

	------------ Constructor patterns ---------------
  | ConPatIn	(Located id)
		(HsConDetails id (LPat id))

  | ConPatOut {
	pat_con   :: Located DataCon,
	pat_tvs   :: [TyVar],		-- Existentially bound type variables
					--   including any bound coercion variables
	pat_dicts :: [id],		-- Ditto dictionaries
	pat_binds :: DictBinds id,	-- Bindings involving those dictionaries
	pat_args  :: HsConDetails id (LPat id),
	pat_ty	  :: Type   		-- The type of the pattern
    }

	------------ Literal and n+k patterns ---------------
  | LitPat	    HsLit		-- Used for *non-overloaded* literal patterns:
					-- Int#, Char#, Int, Char, String, etc.

  | NPat	    (HsOverLit id)		-- ALWAYS positive
		    (Maybe (SyntaxExpr id))	-- Just (Name of 'negate') for negative
						-- patterns, Nothing otherwise
		    (SyntaxExpr id)		-- Equality checker, of type t->t->Bool
		    PostTcType			-- Type of the pattern

  | NPlusKPat	    (Located id)	-- n+k pattern
		    (HsOverLit id)	-- It'll always be an HsIntegral
		    (SyntaxExpr id)	-- (>=) function, of type t->t->Bool
		    (SyntaxExpr id)	-- Name of '-' (see RnEnv.lookupSyntaxName)

	------------ Generics ---------------
  | TypePat	    (LHsType id)	-- Type pattern for generic definitions
                                        -- e.g  f{| a+b |} = ...
                                        -- These show up only in class declarations,
                                        -- and should be a top-level pattern

	------------ Pattern type signatures ---------------
  | SigPatIn	    (LPat id)		-- Pattern with a type signature
		    (LHsType id)

  | SigPatOut	    (LPat id)		-- Pattern with a type signature
		    Type

	------------ Dictionary patterns (translation only) ---------------
  | DictPat	    -- Used when destructing Dictionaries with an explicit case
		    [id]		-- Superclass dicts
		    [id]		-- Methods

	------------ Pattern coercions (translation only) ---------------
  | CoPat 	HsWrapper		-- If co::t1 -> t2, p::t2, 
					-- then (CoPat co p) :: t1
		(Pat id)		-- Why not LPat?  Ans: existing locn will do
	    	Type			-- Type of whole pattern, t1
	-- During desugaring a (CoPat co pat) turns into a cast with 'co' on 
	-- the scrutinee, followed by a match on 'pat'
\end{code}

HsConDetails is use both for patterns and for data type declarations

\begin{code}
data HsConDetails id arg
  = PrefixCon [arg]               -- C p1 p2 p3
  | RecCon    [HsRecField id arg] -- C { x = p1, y = p2 }
  | InfixCon  arg arg		  -- p1 `C` p2

data HsRecField id arg = HsRecField {
	hsRecFieldId  :: Located id,
	hsRecFieldArg :: arg,
	hsRecFieldDoc :: Maybe (LHsDoc id)
}

mkRecField id arg = HsRecField id arg Nothing

hsConArgs :: HsConDetails id arg -> [arg]
hsConArgs (PrefixCon ps)   = ps
hsConArgs (RecCon fs)      = map hsRecFieldArg fs
hsConArgs (InfixCon p1 p2) = [p1,p2]
\end{code}


%************************************************************************
%*									*
%* 		Printing patterns
%*									*
%************************************************************************

\begin{code}
instance (OutputableBndr name) => Outputable (Pat name) where
    ppr = pprPat

pprPatBndr :: OutputableBndr name => name -> SDoc
pprPatBndr var		  	-- Print with type info if -dppr-debug is on
  = getPprStyle $ \ sty ->
    if debugStyle sty then
	parens (pprBndr LambdaBind var)		-- Could pass the site to pprPat
						-- but is it worth it?
    else
	ppr var

pprPat :: (OutputableBndr name) => Pat name -> SDoc
pprPat (VarPat var)  	  = pprPatBndr var
pprPat (VarPatOut var bs) = parens (pprPatBndr var <+> braces (ppr bs))
pprPat (WildPat _)	  = char '_'
pprPat (LazyPat pat)      = char '~' <> ppr pat
pprPat (BangPat pat)      = char '!' <> ppr pat
pprPat (AsPat name pat)   = parens (hcat [ppr name, char '@', ppr pat])
pprPat (ParPat pat)	  = parens (ppr pat)
pprPat (ListPat pats _)     = brackets (interpp'SP pats)
pprPat (PArrPat pats _)     = pabrackets (interpp'SP pats)
pprPat (TuplePat pats bx _) = tupleParens bx (interpp'SP pats)

pprPat (ConPatIn con details) = pprUserCon con details
pprPat (ConPatOut { pat_con = con, pat_tvs = tvs, pat_dicts = dicts, 
		    pat_binds = binds, pat_args = details })
  = getPprStyle $ \ sty ->	-- Tiresome; in TcBinds.tcRhs we print out a 
    if debugStyle sty then 	-- typechecked Pat in an error message, 
				-- and we want to make sure it prints nicely
	ppr con <+> sep [ hsep (map pprPatBndr tvs) <+> hsep (map pprPatBndr dicts),
		   	  pprLHsBinds binds, pprConArgs details]
    else pprUserCon con details

pprPat (LitPat s)	      = ppr s
pprPat (NPat l Nothing  _ _)  = ppr l
pprPat (NPat l (Just _) _ _)  = char '-' <> ppr l
pprPat (NPlusKPat n k _ _)    = hcat [ppr n, char '+', ppr k]
pprPat (TypePat ty)	      = ptext SLIT("{|") <> ppr ty <> ptext SLIT("|}")
pprPat (CoPat co pat _)	      = parens (pprHsWrapper (ppr pat) co)
pprPat (SigPatIn pat ty)      = ppr pat <+> dcolon <+> ppr ty
pprPat (SigPatOut pat ty)     = ppr pat <+> dcolon <+> ppr ty
pprPat (DictPat ds ms)	      = parens (sep [ptext SLIT("{-dict-}"),
					     brackets (interpp'SP ds),
					     brackets (interpp'SP ms)])

pprUserCon c (InfixCon p1 p2) = ppr p1 <+> ppr c <+> ppr p2
pprUserCon c details          = ppr c <+> pprConArgs details

pprConArgs (PrefixCon pats) = interppSP pats
pprConArgs (InfixCon p1 p2) = interppSP [p1,p2]
pprConArgs (RecCon rpats)   = braces (hsep (punctuate comma (map (pp_rpat) rpats)))
			    where
			      pp_rpat (HsRecField v p _d) = 
                                hsep [ppr v, char '=', ppr p]

-- add parallel array brackets around a document
--
pabrackets   :: SDoc -> SDoc
pabrackets p  = ptext SLIT("[:") <> p <> ptext SLIT(":]")

instance (OutputableBndr id, Outputable arg) =>
         Outputable (HsRecField id arg) where
    ppr (HsRecField n ty doc) = ppr n <+> dcolon <+> ppr ty <+> ppr_mbDoc doc
\end{code}


%************************************************************************
%*									*
%* 		Building patterns
%*									*
%************************************************************************

\begin{code}
mkPrefixConPat :: DataCon -> [OutPat id] -> Type -> OutPat id
-- Make a vanilla Prefix constructor pattern
mkPrefixConPat dc pats ty 
  = noLoc $ ConPatOut { pat_con = noLoc dc, pat_tvs = [], pat_dicts = [],
			pat_binds = emptyLHsBinds, pat_args = PrefixCon pats, 
			pat_ty = ty }

mkNilPat :: Type -> OutPat id
mkNilPat ty = mkPrefixConPat nilDataCon [] ty

mkCharLitPat :: Char -> OutPat id
mkCharLitPat c = mkPrefixConPat charDataCon [noLoc $ LitPat (HsCharPrim c)] charTy

mkCoPat :: HsWrapper -> OutPat id -> Type -> OutPat id
mkCoPat co lpat@(L loc pat) ty
  | isIdHsWrapper co = lpat
  | otherwise = L loc (CoPat co pat ty)
\end{code}


%************************************************************************
%*									*
%* Predicates for checking things about pattern-lists in EquationInfo	*
%*									*
%************************************************************************

\subsection[Pat-list-predicates]{Look for interesting things in patterns}

Unlike in the Wadler chapter, where patterns are either ``variables''
or ``constructors,'' here we distinguish between:
\begin{description}
\item[unfailable:]
Patterns that cannot fail to match: variables, wildcards, and lazy
patterns.

These are the irrefutable patterns; the two other categories
are refutable patterns.

\item[constructor:]
A non-literal constructor pattern (see next category).

\item[literal patterns:]
At least the numeric ones may be overloaded.
\end{description}

A pattern is in {\em exactly one} of the above three categories; `as'
patterns are treated specially, of course.

The 1.3 report defines what ``irrefutable'' and ``failure-free'' patterns are.
\begin{code}
isWildPat (WildPat _) = True
isWildPat other	      = False

patsAreAllCons :: [Pat id] -> Bool
patsAreAllCons pat_list = all isConPat pat_list

isConPat (AsPat _ pat)	 = isConPat (unLoc pat)
isConPat (ConPatIn {})	 = True
isConPat (ConPatOut {})  = True
isConPat (ListPat {})	 = True
isConPat (PArrPat {})	 = True
isConPat (TuplePat {})	 = True
isConPat (DictPat ds ms) = (length ds + length ms) > 1
isConPat other		 = False

isSigPat (SigPatIn _ _)  = True
isSigPat (SigPatOut _ _) = True
isSigPat other		 = False

patsAreAllLits :: [Pat id] -> Bool
patsAreAllLits pat_list = all isLitPat pat_list

isLitPat (AsPat _ pat)	        = isLitPat (unLoc pat)
isLitPat (LitPat _)	        = True
isLitPat (NPat _ _ _ _)	        = True
isLitPat (NPlusKPat _ _ _ _)    = True
isLitPat other		        = False

isBangHsBind :: HsBind id -> Bool
-- In this module because HsPat is above HsBinds in the import graph
isBangHsBind (PatBind { pat_lhs = L _ (BangPat p) }) = True
isBangHsBind bind				     = False

isIrrefutableHsPat :: LPat id -> Bool
-- This function returns False if it's in doubt; specifically
-- on a ConPatIn it doesn't know the size of the constructor family
-- But if it returns True, the pattern is definitely irrefutable
isIrrefutableHsPat pat
  = go pat
  where
    go (L _ pat)	 = go1 pat

    go1 (WildPat _)         = True
    go1 (VarPat _)          = True
    go1 (VarPatOut _ _)     = True
    go1 (LazyPat pat)       = True
    go1 (BangPat pat)       = go pat
    go1 (CoPat _ pat _)     = go1 pat
    go1 (ParPat pat)        = go pat
    go1 (AsPat _ pat)       = go pat
    go1 (SigPatIn pat _)    = go pat
    go1 (SigPatOut pat _)   = go pat
    go1 (TuplePat pats _ _) = all go pats
    go1 (ListPat pats _)    = False
    go1 (PArrPat pats _)    = False	-- ?

    go1 (ConPatIn _ _) = False	-- Conservative
    go1 (ConPatOut{ pat_con = L _ con, pat_args = details }) 
	=  isProductTyCon (dataConTyCon con)
	&& all go (hsConArgs details)

    go1 (LitPat _) 	   = False
    go1 (NPat _ _ _ _)	   = False
    go1 (NPlusKPat _ _ _ _) = False

    go1 (TypePat _)   = panic "isIrrefutableHsPat: type pattern"
    go1 (DictPat _ _) = panic "isIrrefutableHsPat: type pattern"
\end{code}

