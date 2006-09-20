%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[TyCon]{The @TyCon@ datatype}

\begin{code}
module TyCon(
	TyCon, FieldLabel,

	PrimRep(..),
	tyConPrimRep,

	AlgTyConRhs(..), visibleDataCons,

	isFunTyCon, isUnLiftedTyCon, isProductTyCon, 
	isAlgTyCon, isDataTyCon, isSynTyCon, isNewTyCon, isPrimTyCon,
	isEnumerationTyCon, isGadtSyntaxTyCon,
	isTupleTyCon, isUnboxedTupleTyCon, isBoxedTupleTyCon, tupleTyConBoxity,
	isRecursiveTyCon, newTyConRep, newTyConRhs, newTyConCo,
	isHiBootTyCon, isSuperKindTyCon,
        isCoercionTyCon_maybe, isCoercionTyCon,

	tcExpandTyCon_maybe, coreExpandTyCon_maybe,

	makeTyConAbstract, isAbstractTyCon,

	mkForeignTyCon, isForeignTyCon,

	mkAlgTyCon,
	mkClassTyCon,
	mkFunTyCon,
	mkPrimTyCon,
	mkVoidPrimTyCon,
	mkLiftedPrimTyCon,
	mkTupleTyCon,
	mkSynTyCon,
        mkSuperKindTyCon,
        mkCoercionTyCon,

	tyConName,
	tyConKind,
	tyConUnique,
	tyConTyVars,
	algTyConRhs, tyConDataCons, tyConDataCons_maybe, tyConFamilySize,
	tyConSelIds,
	tyConStupidTheta,
	tyConArity,
	isClassTyCon, tyConClass_maybe,
	synTyConDefn, synTyConRhs,
	tyConExtName,		-- External name for foreign types

        maybeTyConSingleCon,

	-- Generics
        tyConHasGenerics
) where

#include "HsVersions.h"

import {-# SOURCE #-} TypeRep ( Kind, Type, Coercion, PredType )
import {-# SOURCE #-} DataCon ( DataCon, isVanillaDataCon )

import Var   		( TyVar, Id )
import Class		( Class )
import BasicTypes	( Arity, RecFlag(..), Boxity(..), isBoxed )
import Name		( Name, nameUnique, NamedThing(getName) )
import PrelNames	( Unique, Uniquable(..) )
import Maybes		( orElse )
import Outputable
import FastString
\end{code}

%************************************************************************
%*									*
\subsection{The data type}
%*									*
%************************************************************************

\begin{code}
data TyCon
  = FunTyCon {
	tyConUnique :: Unique,
	tyConName   :: Name,
	tyConKind   :: Kind,
	tyConArity  :: Arity
    }


  | AlgTyCon {		-- Data type, and newtype decls.
			-- All lifted, all boxed
	tyConUnique :: Unique,
	tyConName   :: Name,
	tyConKind   :: Kind,
	tyConArity  :: Arity,
	
	tyConTyVars :: [TyVar],		-- Scopes over (a) the [PredType] in AlgTyConRhs.DataTyCon
					--	       (b) the cached types in AlgTyConRhs.NewTyCon
					-- But not over the data constructors
	algTcSelIds :: [Id],  		-- Its record selectors (empty if none): 

	algTcGadtSyntax  :: Bool,	-- True <=> the data type was declared using GADT syntax
					-- That doesn't mean it's a true GADT; only that the "where"
					-- 	form was used. This field is used only to guide
					--	pretty-printinng
	algTcStupidTheta :: [PredType],	-- The "stupid theta" for the data type
					-- (always empty for GADTs)

	algTcRhs :: AlgTyConRhs,	-- Data constructors in here

	algTcRec :: RecFlag,		-- Tells whether the data type is part of 
					-- a mutually-recursive group or not

	hasGenerics :: Bool,		-- True <=> generic to/from functions are available
					-- (in the exports of the data type's source module)

	algTcClass :: Maybe Class
		-- Just cl if this tycon came from a class declaration
    }

  | TupleTyCon {
	tyConUnique :: Unique,
	tyConName   :: Name,
	tyConKind   :: Kind,
	tyConArity  :: Arity,
	tyConBoxed  :: Boxity,
	tyConTyVars :: [TyVar],
	dataCon     :: DataCon,
	hasGenerics :: Bool
    }

  | SynTyCon {
	tyConUnique :: Unique,
	tyConName   :: Name,
	tyConKind   :: Kind,
	tyConArity  :: Arity,

	tyConTyVars :: [TyVar],		-- Bound tyvars
	synTcRhs    :: Type		-- Right-hand side, mentioning these type vars.
					-- Acts as a template for the expansion when
					-- the tycon is applied to some types.
    }

  | PrimTyCon {			-- Primitive types; cannot be defined in Haskell
				-- Now includes foreign-imported types
                                -- Also includes Kinds
	tyConUnique   :: Unique,
	tyConName     :: Name,
	tyConKind     :: Kind,
	tyConArity    :: Arity,

	primTyConRep  :: PrimRep,
			-- Many primitive tycons are unboxed, but some are
			-- boxed (represented by pointers). The CgRep tells.

	isUnLifted   :: Bool,		-- Most primitive tycons are unlifted, 
					-- but foreign-imported ones may not be
	tyConExtName :: Maybe FastString	-- Just xx for foreign-imported types
    }

  | CoercionTyCon {	-- E.g. (:=:), sym, trans, left, right
			-- INVARIANT: coercions are always fully applied
	tyConUnique :: Unique,
        tyConName   :: Name,
	tyConArity  :: Arity,
	coKindFun   :: [Type] -> Kind
    }
	
  | SuperKindTyCon {    -- Super Kinds, TY (box) and CO (diamond).
			-- They have no kind; and arity zero
        tyConUnique :: Unique,
        tyConName   :: Name
    }

type KindCon = TyCon

type SuperKindCon = TyCon

type FieldLabel = Name

data AlgTyConRhs
  = AbstractTyCon	-- We know nothing about this data type, except 
			-- that it's represented by a pointer
			-- Used when we export a data type abstractly into
			-- an hi file

  | DataTyCon {
	data_cons :: [DataCon],
			-- The constructors; can be empty if the user declares
			--   the type to have no constructors
			-- INVARIANT: Kept in order of increasing tag
			--	      (see the tag assignment in DataCon.mkDataCon)
	is_enum :: Bool 	-- Cached: True <=> an enumeration type
    }			--	   Includes data types with no constructors.

  | NewTyCon {
	data_con :: DataCon,	-- The unique constructor; it has no existentials

	nt_rhs :: Type,		-- Cached: the argument type of the constructor
				--  = the representation type of the tycon
				-- The free tyvars of this type are the tyConTyVars
      
        nt_co :: Maybe TyCon,   -- The coercion used to create the newtype
                                -- from the representation
                                -- optional for non-recursive newtypes
				-- See Note [Newtype coercions]

	nt_etad_rhs :: ([TyVar], Type) ,
			-- The same again, but this time eta-reduced
			-- hence the [TyVar] which may be shorter than the declared 
			-- arity of the TyCon.  See Note [Newtype eta]

	nt_rep :: Type	-- Cached: the *ultimate* representation type
			-- By 'ultimate' I mean that the top-level constructor
			-- of the rep type is not itself a newtype or type synonym.
			-- The rep type isn't entirely simple:
			--  for a recursive newtype we pick () as the rep type
			--	newtype T = MkT T
			-- 
			-- This one does not need to be eta reduced; hence its
			-- free type variables are conveniently tyConTyVars
			-- Thus:
			-- 	newtype T a = MkT [(a,Int)]
			-- The rep type is [(a,Int)]
			-- NB: the rep type isn't necessarily the original RHS of the
			--     newtype decl, because the rep type looks through other
    }			--     newtypes.

visibleDataCons :: AlgTyConRhs -> [DataCon]
visibleDataCons AbstractTyCon      	      = []
visibleDataCons (DataTyCon{ data_cons = cs }) = cs
visibleDataCons (NewTyCon{ data_con = c })    = [c]
\end{code}

Note [Newtype coercions]
~~~~~~~~~~~~~~~~~~~~~~~~

The NewTyCon field nt_co is a a TyCon (a coercion constructor in fact)
which is used for coercing from the representation type of the
newtype, to the newtype itself. For example,

   newtype T a = MkT [a]

the NewTyCon for T will contain nt_co = CoT where CoT t : [t] :=: T t.
This TyCon is a CoercionTyCon, so it does not have a kind on its own;
it basically has its own typing rule for the fully-applied version.
If the newtype T has k type variables then CoT has arity k.

In the paper we'd write
	axiom CoT : (forall t. [t]) :=: (forall t. T t)
and then when we used CoT at a particular type, s, we'd say
	CoT @ s
which encodes as (TyConApp instCoercionTyCon [TyConApp CoT [], s])

But in GHC we instead make CoT into a new piece of type syntax
(like instCoercionTyCon, symCoercionTyCon etc), which must always
be saturated, but which encodes as
	TyConAp CoT [s]
In the vocabulary of the paper it's as if we had axiom declarations
like
	axiom CoT t : ([t] :=: T t)

Note [Newtype eta]
~~~~~~~~~~~~~~~~~~
Consider
	newtype Parser m a = MkParser (Foogle m a)
Are these two types equal (to Core)?
	Monad (Parser m) 
	Monad (Foogle m)
Well, yes.  But to see that easily we eta-reduce the RHS type of
Parser, in this case to ([], Froogle), so that even unsaturated applications
of Parser will work right.  This eta reduction is done when the type 
constructor is built, and cached in NewTyCon.  The cached field is
only used in coreExpandTyCon_maybe.
 
Here's an example that I think showed up in practice
Source code:
	newtype T a = MkT [a]
	newtype Foo m = MkFoo (forall a. m a -> Int)

	w1 :: Foo []
	w1 = ...
	
	w2 :: Foo T
	w2 = MkFoo (\(MkT x) -> case w1 of MkFoo f -> f x)

After desugaring, and discading the data constructors for the newtypes,
we get:
	w2 :: Foo T
	w2 = w1
And now Lint complains unless Foo T == Foo [], and that requires T==[]


%************************************************************************
%*									*
\subsection{PrimRep}
%*									*
%************************************************************************

A PrimRep is an abstraction of a type.  It contains information that
the code generator needs in order to pass arguments, return results,
and store values of this type.

A PrimRep is somewhat similar to a CgRep (see codeGen/SMRep) and a
MachRep (see cmm/MachOp), although each of these types has a distinct
and clearly defined purpose:

  - A PrimRep is a CgRep + information about signedness + information
    about primitive pointers (AddrRep).  Signedness and primitive
    pointers are required when passing a primitive type to a foreign
    function, but aren't needed for call/return conventions of Haskell
    functions.

  - A MachRep is a basic machine type (non-void, doesn't contain
    information on pointerhood or signedness, but contains some
    reps that don't have corresponding Haskell types).

\begin{code}
data PrimRep
  = VoidRep
  | PtrRep
  | IntRep		-- signed, word-sized
  | WordRep		-- unsinged, word-sized
  | Int64Rep		-- signed, 64 bit (32-bit words only)
  | Word64Rep		-- unsigned, 64 bit (32-bit words only)
  | AddrRep		-- a pointer, but not to a Haskell value
  | FloatRep
  | DoubleRep
\end{code}

%************************************************************************
%*									*
\subsection{TyCon Construction}
%*									*
%************************************************************************

Note: the TyCon constructors all take a Kind as one argument, even though
they could, in principle, work out their Kind from their other arguments.
But to do so they need functions from Types, and that makes a nasty
module mutual-recursion.  And they aren't called from many places.
So we compromise, and move their Kind calculation to the call site.

\begin{code}
mkFunTyCon :: Name -> Kind -> TyCon
mkFunTyCon name kind 
  = FunTyCon { 
	tyConUnique = nameUnique name,
	tyConName   = name,
	tyConKind   = kind,
	tyConArity  = 2
    }

-- This is the making of a TyCon. Just the same as the old mkAlgTyCon,
-- but now you also have to pass in the generic information about the type
-- constructor - you can get hold of it easily (see Generics module)
mkAlgTyCon name kind tyvars stupid rhs sel_ids is_rec gen_info gadt_syn
  = AlgTyCon {	
	tyConName 	 = name,
	tyConUnique	 = nameUnique name,
	tyConKind	 = kind,
	tyConArity	 = length tyvars,
	tyConTyVars	 = tyvars,
	algTcStupidTheta = stupid,
	algTcRhs         = rhs,
	algTcSelIds	 = sel_ids,
	algTcClass	 = Nothing,
	algTcRec	 = is_rec,
	algTcGadtSyntax  = gadt_syn,
	hasGenerics = gen_info
    }

mkClassTyCon name kind tyvars rhs clas is_rec
  = AlgTyCon {	
	tyConName 	 = name,
	tyConUnique	 = nameUnique name,
	tyConKind	 = kind,
	tyConArity	 = length tyvars,
	tyConTyVars	 = tyvars,
	algTcStupidTheta = [],
	algTcRhs	 = rhs,
	algTcSelIds	 = [],
	algTcClass	 = Just clas,
	algTcRec	 = is_rec,
	algTcGadtSyntax  = False,	-- Doesn't really matter
	hasGenerics = False
    }


mkTupleTyCon name kind arity tyvars con boxed gen_info
  = TupleTyCon {
	tyConUnique = nameUnique name,
	tyConName = name,
	tyConKind = kind,
	tyConArity = arity,
	tyConBoxed = boxed,
	tyConTyVars = tyvars,
	dataCon = con,
	hasGenerics = gen_info
    }

-- Foreign-imported (.NET) type constructors are represented
-- as primitive, but *lifted*, TyCons for now. They are lifted
-- because the Haskell type T representing the (foreign) .NET
-- type T is actually implemented (in ILX) as a thunk<T>
mkForeignTyCon name ext_name kind arity
  = PrimTyCon {
	tyConName    = name,
	tyConUnique  = nameUnique name,
	tyConKind    = kind,
	tyConArity   = arity,
	primTyConRep = PtrRep, -- they all do
	isUnLifted   = False,
	tyConExtName = ext_name
    }


-- most Prim tycons are lifted
mkPrimTyCon name kind arity rep
  = mkPrimTyCon' name kind arity rep True  

mkVoidPrimTyCon name kind arity 
  = mkPrimTyCon' name kind arity VoidRep True  

-- but RealWorld is lifted
mkLiftedPrimTyCon name kind arity rep
  = mkPrimTyCon' name kind arity rep False

mkPrimTyCon' name kind arity rep is_unlifted
  = PrimTyCon {
	tyConName    = name,
	tyConUnique  = nameUnique name,
	tyConKind    = kind,
	tyConArity   = arity,
	primTyConRep = rep,
	isUnLifted   = is_unlifted,
	tyConExtName = Nothing
    }

mkSynTyCon name kind tyvars rhs
  = SynTyCon {	
	tyConName = name,
	tyConUnique = nameUnique name,
	tyConKind = kind,
	tyConArity = length tyvars,
	tyConTyVars = tyvars,
	synTcRhs = rhs
    }

mkCoercionTyCon name arity kindRule
  = CoercionTyCon {
        tyConName = name,
        tyConUnique = nameUnique name,
        tyConArity = arity,
        coKindFun = kindRule
    }

-- Super kinds always have arity zero
mkSuperKindTyCon name
  = SuperKindTyCon {
        tyConName = name,
        tyConUnique = nameUnique name
  }
\end{code}

\begin{code}
isFunTyCon :: TyCon -> Bool
isFunTyCon (FunTyCon {}) = True
isFunTyCon _             = False

isAbstractTyCon :: TyCon -> Bool
isAbstractTyCon (AlgTyCon { algTcRhs = AbstractTyCon }) = True
isAbstractTyCon _ = False

makeTyConAbstract :: TyCon -> TyCon
makeTyConAbstract tc@(AlgTyCon {}) = tc { algTcRhs = AbstractTyCon }
makeTyConAbstract tc = pprPanic "makeTyConAbstract" (ppr tc)

isPrimTyCon :: TyCon -> Bool
isPrimTyCon (PrimTyCon {}) = True
isPrimTyCon _              = False

isUnLiftedTyCon :: TyCon -> Bool
isUnLiftedTyCon (PrimTyCon  {isUnLifted = is_unlifted}) = is_unlifted
isUnLiftedTyCon (TupleTyCon {tyConBoxed = boxity})      = not (isBoxed boxity)
isUnLiftedTyCon _    				        = False

-- isAlgTyCon returns True for both @data@ and @newtype@
isAlgTyCon :: TyCon -> Bool
isAlgTyCon (AlgTyCon {})   = True
isAlgTyCon (TupleTyCon {}) = True
isAlgTyCon other 	   = False

isDataTyCon :: TyCon -> Bool
-- isDataTyCon returns True for data types that are represented by
-- heap-allocated constructors.
-- These are srcutinised by Core-level @case@ expressions, and they
-- get info tables allocated for them.
--	True for all @data@ types
--	False for newtypes
--		  unboxed tuples
isDataTyCon tc@(AlgTyCon {algTcRhs = rhs})  
  = case rhs of
	DataTyCon {}  -> True
	NewTyCon {}   -> False
	AbstractTyCon -> pprPanic "isDataTyCon" (ppr tc)

isDataTyCon (TupleTyCon {tyConBoxed = boxity}) = isBoxed boxity
isDataTyCon other = False

isNewTyCon :: TyCon -> Bool
isNewTyCon (AlgTyCon {algTcRhs = NewTyCon {}}) = True 
isNewTyCon other			       = False

isProductTyCon :: TyCon -> Bool
-- A "product" tycon
--	has *one* constructor, 
--	is *not* existential
-- but
--	may be  DataType, NewType
-- 	may be  unboxed or not, 
--	may be  recursive or not
-- 
isProductTyCon tc@(AlgTyCon {}) = case algTcRhs tc of
				    DataTyCon{ data_cons = [data_con] } 
						-> isVanillaDataCon data_con
				    NewTyCon {}	-> True
				    other	-> False
isProductTyCon (TupleTyCon {})  = True   
isProductTyCon other		= False

isSynTyCon :: TyCon -> Bool
isSynTyCon (SynTyCon {}) = True
isSynTyCon _		 = False

isGadtSyntaxTyCon :: TyCon -> Bool
isGadtSyntaxTyCon (AlgTyCon { algTcGadtSyntax = res }) = res
isGadtSyntaxTyCon other				       = False

isEnumerationTyCon :: TyCon -> Bool
isEnumerationTyCon (AlgTyCon {algTcRhs = DataTyCon { is_enum = res }}) = res
isEnumerationTyCon other				       	       = False

isTupleTyCon :: TyCon -> Bool
-- The unit tycon didn't used to be classed as a tuple tycon
-- but I thought that was silly so I've undone it
-- If it can't be for some reason, it should be a AlgTyCon
--
-- NB: when compiling Data.Tuple, the tycons won't reply True to
-- isTupleTyCon, becuase they are built as AlgTyCons.  However they
-- get spat into the interface file as tuple tycons, so I don't think
-- it matters.
isTupleTyCon (TupleTyCon {}) = True
isTupleTyCon other 	     = False

isUnboxedTupleTyCon :: TyCon -> Bool
isUnboxedTupleTyCon (TupleTyCon {tyConBoxed = boxity}) = not (isBoxed boxity)
isUnboxedTupleTyCon other = False

isBoxedTupleTyCon :: TyCon -> Bool
isBoxedTupleTyCon (TupleTyCon {tyConBoxed = boxity}) = isBoxed boxity
isBoxedTupleTyCon other = False

tupleTyConBoxity tc = tyConBoxed tc

isRecursiveTyCon :: TyCon -> Bool
isRecursiveTyCon (AlgTyCon {algTcRec = Recursive}) = True
isRecursiveTyCon other				      = False

isHiBootTyCon :: TyCon -> Bool
-- Used for knot-tying in hi-boot files
isHiBootTyCon (AlgTyCon {algTcRhs = AbstractTyCon}) = True
isHiBootTyCon other			            = False

isForeignTyCon :: TyCon -> Bool
-- isForeignTyCon identifies foreign-imported type constructors
isForeignTyCon (PrimTyCon {tyConExtName = Just _}) = True
isForeignTyCon other				   = False

isSuperKindTyCon :: TyCon -> Bool
isSuperKindTyCon (SuperKindTyCon {}) = True
isSuperKindTyCon other               = False

isCoercionTyCon_maybe :: TyCon -> Maybe (Arity, [Type] -> Kind)
isCoercionTyCon_maybe (CoercionTyCon {tyConArity = ar, coKindFun = rule}) 
  = Just (ar, rule)
isCoercionTyCon_maybe other = Nothing

isCoercionTyCon (CoercionTyCon {}) = True
isCoercionTyCon other              = False
\end{code}


-----------------------------------------------
--	Expand type-constructor applications
-----------------------------------------------

\begin{code}
tcExpandTyCon_maybe, coreExpandTyCon_maybe 
	:: TyCon 
	-> [Type]			-- Args to tycon
	-> Maybe ([(TyVar,Type)], 	-- Substitution
		  Type,			-- Body type (not yet substituted)
		  [Type])		-- Leftover args

-- For the *typechecker* view, we expand synonyms only
tcExpandTyCon_maybe (SynTyCon {tyConTyVars = tvs, synTcRhs = rhs }) tys
   = expand tvs rhs tys
tcExpandTyCon_maybe other_tycon tys = Nothing

---------------
-- For the *Core* view, we expand synonyms only as well

coreExpandTyCon_maybe (AlgTyCon {algTcRec = NonRecursive,	-- Not recursive
         algTcRhs = NewTyCon { nt_etad_rhs = etad_rhs, nt_co = Nothing }}) tys
   = case etad_rhs of	-- Don't do this in the pattern match, lest we accidentally
			-- match the etad_rhs of a *recursive* newtype
	(tvs,rhs) -> expand tvs rhs tys

coreExpandTyCon_maybe tycon tys = tcExpandTyCon_maybe tycon tys


----------------
expand	:: [TyVar] -> Type 			-- Template
	-> [Type]				-- Args
	-> Maybe ([(TyVar,Type)], Type, [Type])	-- Expansion
expand tvs rhs tys
  = case n_tvs `compare` length tys of
	LT -> Just (tvs `zip` tys, rhs, drop n_tvs tys)
	EQ -> Just (tvs `zip` tys, rhs, [])
	GT -> Nothing
   where
     n_tvs = length tvs
\end{code}

\begin{code}
tyConHasGenerics :: TyCon -> Bool
tyConHasGenerics (AlgTyCon {hasGenerics = hg})   = hg
tyConHasGenerics (TupleTyCon {hasGenerics = hg}) = hg
tyConHasGenerics other				 = False	-- Synonyms

tyConDataCons :: TyCon -> [DataCon]
-- It's convenient for tyConDataCons to return the
-- empty list for type synonyms etc
tyConDataCons tycon = tyConDataCons_maybe tycon `orElse` []

tyConDataCons_maybe :: TyCon -> Maybe [DataCon]
tyConDataCons_maybe (AlgTyCon {algTcRhs = DataTyCon { data_cons = cons }}) = Just cons
tyConDataCons_maybe (AlgTyCon {algTcRhs = NewTyCon { data_con = con }})    = Just [con]
tyConDataCons_maybe (TupleTyCon {dataCon = con})	       		   = Just [con]
tyConDataCons_maybe other			               		   = Nothing

tyConFamilySize  :: TyCon -> Int
tyConFamilySize (AlgTyCon {algTcRhs = DataTyCon { data_cons = cons }}) = length cons
tyConFamilySize (AlgTyCon {algTcRhs = NewTyCon {}}) = 1
tyConFamilySize (TupleTyCon {})	 		    = 1
#ifdef DEBUG
tyConFamilySize other = pprPanic "tyConFamilySize:" (ppr other)
#endif

tyConSelIds :: TyCon -> [Id]
tyConSelIds (AlgTyCon {algTcSelIds = fs}) = fs
tyConSelIds other_tycon		          = []

algTyConRhs :: TyCon -> AlgTyConRhs
algTyConRhs (AlgTyCon {algTcRhs = rhs})  = rhs
algTyConRhs (TupleTyCon {dataCon = con}) = DataTyCon { data_cons = [con], is_enum = False }
algTyConRhs other = pprPanic "algTyConRhs" (ppr other)
\end{code}

\begin{code}
newTyConRhs :: TyCon -> ([TyVar], Type)
newTyConRhs (AlgTyCon {tyConTyVars = tvs, algTcRhs = NewTyCon { nt_rhs = rhs }}) = (tvs, rhs)
newTyConRhs tycon = pprPanic "newTyConRhs" (ppr tycon)

newTyConRep :: TyCon -> ([TyVar], Type)
newTyConRep (AlgTyCon {tyConTyVars = tvs, algTcRhs = NewTyCon { nt_rep = rep }}) = (tvs, rep)
newTyConRep tycon = pprPanic "newTyConRep" (ppr tycon)

newTyConCo :: TyCon -> Maybe TyCon
newTyConCo (AlgTyCon {tyConTyVars = tvs, algTcRhs = NewTyCon { nt_co = co }}) = co
newTyConCo tycon = pprPanic "newTyConCo" (ppr tycon)

tyConPrimRep :: TyCon -> PrimRep
tyConPrimRep (PrimTyCon {primTyConRep = rep}) = rep
tyConPrimRep tc = ASSERT(not (isUnboxedTupleTyCon tc)) PtrRep
\end{code}

\begin{code}
tyConStupidTheta :: TyCon -> [PredType]
tyConStupidTheta (AlgTyCon {algTcStupidTheta = stupid}) = stupid
tyConStupidTheta (TupleTyCon {})			= []
tyConStupidTheta tycon = pprPanic "tyConStupidTheta" (ppr tycon)
\end{code}

\begin{code}
synTyConDefn :: TyCon -> ([TyVar], Type)
synTyConDefn (SynTyCon {tyConTyVars = tyvars, synTcRhs = ty}) = (tyvars,ty)
synTyConDefn tycon = pprPanic "getSynTyConDefn" (ppr tycon)

synTyConRhs :: TyCon -> Type
synTyConRhs tc = synTcRhs tc
\end{code}

\begin{code}
maybeTyConSingleCon :: TyCon -> Maybe DataCon
maybeTyConSingleCon (AlgTyCon {algTcRhs = DataTyCon {data_cons = [c] }}) = Just c
maybeTyConSingleCon (AlgTyCon {algTcRhs = NewTyCon { data_con = c }})    = Just c
maybeTyConSingleCon (AlgTyCon {})	         = Nothing
maybeTyConSingleCon (TupleTyCon {dataCon = con}) = Just con
maybeTyConSingleCon (PrimTyCon {})               = Nothing
maybeTyConSingleCon (FunTyCon {})                = Nothing  -- case at funty
maybeTyConSingleCon tc = pprPanic "maybeTyConSingleCon: unexpected tycon " $ ppr tc
\end{code}

\begin{code}
isClassTyCon :: TyCon -> Bool
isClassTyCon (AlgTyCon {algTcClass = Just _}) = True
isClassTyCon other_tycon			 = False

tyConClass_maybe :: TyCon -> Maybe Class
tyConClass_maybe (AlgTyCon {algTcClass = maybe_clas}) = maybe_clas
tyConClass_maybe ther_tycon				 = Nothing
\end{code}


%************************************************************************
%*									*
\subsection[TyCon-instances]{Instance declarations for @TyCon@}
%*									*
%************************************************************************

@TyCon@s are compared by comparing their @Unique@s.

The strictness analyser needs @Ord@. It is a lexicographic order with
the property @(a<=b) || (b<=a)@.

\begin{code}
instance Eq TyCon where
    a == b = case (a `compare` b) of { EQ -> True;   _ -> False }
    a /= b = case (a `compare` b) of { EQ -> False;  _ -> True  }

instance Ord TyCon where
    a <= b = case (a `compare` b) of { LT -> True;  EQ -> True;  GT -> False }
    a <	 b = case (a `compare` b) of { LT -> True;  EQ -> False; GT -> False }
    a >= b = case (a `compare` b) of { LT -> False; EQ -> True;  GT -> True  }
    a >	 b = case (a `compare` b) of { LT -> False; EQ -> False; GT -> True  }
    compare a b = getUnique a `compare` getUnique b

instance Uniquable TyCon where
    getUnique tc = tyConUnique tc

instance Outputable TyCon where
    ppr tc  = ppr (getName tc) 

instance NamedThing TyCon where
    getName = tyConName
\end{code}
