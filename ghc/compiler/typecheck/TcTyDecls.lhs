%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1999
%

Analysis functions over data types.  Specficially
	a) detecting recursive types
	b) computing argument variances

This stuff is only used for source-code decls; it's recorded in interface
files for imported data types.


\begin{code}
module TcTyDecls(
        calcTyConArgVrcs, tyVarVrc,
	calcRecFlags, calcCycleErrs,
	newTyConRhs
    ) where

#include "HsVersions.h"

import TypeRep          ( Type(..), TyNote(..), PredType(..) )  -- friend
import HsSyn		( TyClDecl(..), HsPred(..) )
import RnHsSyn		( extractHsTyNames )
import Type		( predTypeRep )
import BuildTyCl	( newTyConRhs )
import HscTypes		( TyThing(..) )
import TyCon            ( TyCon, ArgVrcs, tyConArity, tyConDataCons_maybe, tyConDataCons, tyConTyVars,
                          getSynTyConDefn, isSynTyCon, isAlgTyCon, isHiBootTyCon,
			  tyConName, isNewTyCon, isProductTyCon, tyConArgVrcs )
import Class		( classTyCon )
import DataCon          ( dataConRepArgTys, dataConOrigArgTys )
import Var              ( TyVar )
import VarSet
import Name		( Name, isTyVarName )
import NameEnv
import NameSet
import Digraph 		( SCC(..), stronglyConnComp, stronglyConnCompR )
import Maybe		( isNothing )
import BasicTypes	( RecFlag(..) )
import Outputable
\end{code}


%************************************************************************
%*									*
	Cycles in class and type synonym declarations
%*									*
%************************************************************************

We check for type synonym and class cycles on the *source* code.
Main reasons: 

  a) Otherwise we'd need a special function to extract type-synonym tycons
	from a type, whereas we have extractHsTyNames already

  b) If we checked for type synonym loops after building the TyCon, we
	can't do a hoistForAllTys on the type synonym rhs, (else we fall into
	a black hole) which seems unclean.  Apart from anything else, it'd mean 
	that a type-synonym rhs	could have for-alls to the right of an arrow, 
	which means adding new cases to the validity checker

	Indeed, in general, checking for cycles beforehand means we need to
	be less careful about black holes through synonym cycles.

The main disadvantage is that a cycle that goes via a type synonym in an 
.hi-boot file can lead the compiler into a loop, because it assumes that cycles
only occur in source code.  But hi-boot files are trusted anyway, so this isn't
much worse than (say) a kind error.

[  NOTE ----------------------------------------------
If we reverse this decision, this comment came from tcTyDecl1, and should
 go back there
	-- dsHsType, not tcHsKindedType, to avoid a loop.  tcHsKindedType does hoisting,
	-- which requires looking through synonyms... and therefore goes into a loop
	-- on (erroneously) recursive synonyms.
	-- Solution: do not hoist synonyms, because they'll be hoisted soon enough
	-- 	     when they are substituted

We'd also need to add back in this definition

synTyConsOfType :: Type -> [TyCon]
-- Does not look through type synonyms at all
-- Return a list of synonym tycons
synTyConsOfType ty
  = nameEnvElts (go ty)
  where
     go :: Type -> NameEnv TyCon  -- The NameEnv does duplicate elim
     go (TyVarTy v)	  	  = emptyNameEnv
     go (TyConApp tc tys) 	  = go_tc tc tys	-- See note (a)
     go (NewTcApp tc tys)	  = go_s tys	-- Ignore tycon
     go (AppTy a b)	  	  = go a `plusNameEnv` go b
     go (FunTy a b)	  	  = go a `plusNameEnv` go b
     go (PredTy (IParam _ ty))    = go ty	
     go (PredTy (ClassP cls tys)) = go_s tys	-- Ignore class
     go (NoteTy (SynNote ty) _)	  = go ty	-- Don't look through it!
     go (NoteTy other ty)	  = go ty	
     go (ForAllTy _ ty)	  	  = go ty

	-- Note (a): the unexpanded branch of a SynNote has a
	--	     TyConApp for the synonym, so the tc of
	--	     a TyConApp must be tested for possible synonyms

     go_tc tc tys | isSynTyCon tc = extendNameEnv (go_s tys) (tyConName tc) tc
		  | otherwise	  = go_s tys
     go_s tys = foldr (plusNameEnv . go) emptyNameEnv tys
---------------------------------------- END NOTE ]

\begin{code}
calcCycleErrs :: [TyClDecl Name] -> ([[Name]],	-- Recursive type synonym groups
			             [[Name]])	-- Ditto classes
calcCycleErrs decls
  = (findCyclics syn_edges, findCyclics cls_edges)
  where
	--------------- Type synonyms ----------------------
    syn_edges 	     = [ (name, mk_syn_edges rhs) | TySynonym { tcdName = name, tcdSynRhs = rhs } <- decls ]
    mk_syn_edges rhs = [ tc | tc <- nameSetToList (extractHsTyNames rhs), not (isTyVarName tc) ]

	--------------- Classes ----------------------
    cls_edges = [ (name, mk_cls_edges ctxt) | ClassDecl { tcdName = name, tcdCtxt = ctxt } <- decls ]
    mk_cls_edges ctxt = [ cls | HsClassP cls _ <- ctxt ]
\end{code}


%************************************************************************
%*									*
	Deciding which type constructors are recursive
%*									*
%************************************************************************

A newtype M.T is defined to be "recursive" iff
	(a) its rhs mentions an abstract (hi-boot) TyCon
   or	(b) one can get from T's rhs to T via type 
	    synonyms, or non-recursive newtypes *in M*
 e.g.  newtype T = MkT (T -> Int)

(a)	is conservative; it assumes that the hi-boot type can loop
	around to T.  That's why in (b) we can restrict attention
	to tycons in M, because any loops through newtypes outside M
	will be broken by those newtypes

An algebraic data type M.T is "recursive" iff
	it has just one constructor, and 
	(a) its arg types mention an abstract (hi-boot) TyCon
 or	(b) one can get from its arg types to T via type synonyms, 
	    or by non-recursive newtypes or non-recursive product types in M
 e.g.  data T = MkT (T -> Int) Bool

A type synonym is recursive if one can get from its
right hand side back to it via type synonyms.  (This is
reported as an error.)

A class is recursive if one can get from its superclasses
back to it.  (This is an error too.)

Hi-boot types
~~~~~~~~~~~~~
A data type read from an hi-boot file will have an Unknown in its data constructors,
and will respond True to isHiBootTyCon. The idea is that we treat these as if one
could get from these types to anywhere.  So when we see

  	module Baz where
	import {-# SOURCE #-} Foo( T )
	newtype S = MkS T

then we mark S as recursive, just in case. What that means is that if we see

	import Baz( S )
	newtype R = MkR S

then we don't need to look inside S to compute R's recursiveness.  Since S is imported
(not from an hi-boot file), one cannot get from R back to S except via an hi-boot file,
and that means that some data type will be marked recursive along the way.  So R is
unconditionly non-recursive (i.e. there'll be a loop breaker elsewhere if necessary)

This in turn means that we grovel through fewer interface files when computing 
recursiveness, because we need only look at the type decls in the module being
compiled, plus the outer structure of directly-mentioned types.

\begin{code}
calcRecFlags :: [TyThing] -> (Name -> RecFlag)
calcRecFlags tyclss
  = is_rec
  where
    is_rec n | n `elemNameSet` rec_names = Recursive
	     | otherwise		 = NonRecursive

    rec_names = nt_loop_breakers `unionNameSets` prod_loop_breakers

    all_tycons = map getTyCon tyclss	-- Recursion of newtypes/data types
					-- can happen via the class TyCon

	-------------------------------------------------
	-- 			NOTE
	-- These edge-construction loops rely on
	-- every loop going via tyclss, the types and classes
	-- in the module being compiled.  Stuff in interface 
	-- files should be correctly marked.  If not (e.g. a
	-- type synonym in a hi-boot file) we can get an infinite
	-- loop.  We could program round this, but it'd make the code
	-- rather less nice, so I'm not going to do that yet.

	--------------- Newtypes ----------------------
    new_tycons = filter isNewTyCon all_tycons
    nt_loop_breakers = mkNameSet (findLoopBreakers nt_edges)
    is_rec_nt tc = tyConName tc  `elemNameSet` nt_loop_breakers
	-- is_rec_nt is a locally-used helper function

    nt_edges = [(t, mk_nt_edges t) | t <- new_tycons]

    mk_nt_edges nt 	-- Invariant: nt is a newtype
	= concatMap (mk_nt_edges1 nt) (tcTyConsOfType (newTyConRhs nt))
			-- tyConsOfType looks through synonyms

    mk_nt_edges1 nt tc 
	| tc `elem` new_tycons = [tc]		-- Loop
	| isHiBootTyCon tc     = [nt]		-- Make it self-recursive if 
						-- it mentions an hi-boot TyCon
		-- At this point we know that either it's a local data type,
		-- or it's imported.  Either way, it can't form part of a cycle
	| otherwise = []

	--------------- Product types ----------------------
	-- The "prod_tycons" are the non-newtype products
    prod_tycons = [tc | tc <- all_tycons, 
			not (isNewTyCon tc), isProductTyCon tc]
    prod_loop_breakers = mkNameSet (findLoopBreakers prod_edges)

    prod_edges = [(tc, mk_prod_edges tc) | tc <- prod_tycons]
	
    mk_prod_edges tc 	-- Invariant: tc is a product tycon
	= concatMap (mk_prod_edges1 tc) (dataConOrigArgTys (head (tyConDataCons tc)))

    mk_prod_edges1 ptc ty = concatMap (mk_prod_edges2 ptc) (tcTyConsOfType ty)

    mk_prod_edges2 ptc tc 
 	| tc `elem` prod_tycons   = [tc]		-- Local product
 	| tc `elem` new_tycons    = if is_rec_nt tc 	-- Local newtype
				    then []
				    else mk_prod_edges1 ptc (newTyConRhs tc)
	| isHiBootTyCon tc	  = [ptc]	-- Make it self-recursive if 
						-- it mentions an hi-boot TyCon
		-- At this point we know that either it's a local non-product data type,
		-- or it's imported.  Either way, it can't form part of a cycle
	| otherwise = []
			
getTyCon (ATyCon tc) = tc
getTyCon (AClass cl) = classTyCon cl

findLoopBreakers :: [(TyCon, [TyCon])] -> [Name]
-- Finds a set of tycons that cut all loops
findLoopBreakers deps
  = go [(tc,tc,ds) | (tc,ds) <- deps]
  where
    go edges = [ name
	       | CyclicSCC ((tc,_,_) : edges') <- stronglyConnCompR edges,
		 name <- tyConName tc : go edges']

findCyclics :: [(Name,[Name])] -> [[Name]]
findCyclics deps
  = [names | CyclicSCC names <- stronglyConnComp edges]
  where
    edges = [(name,name,ds) | (name,ds) <- deps]
\end{code}

These two functions know about type representations, so they could be
in Type or TcType -- but they are very specialised to this module, so 
I've chosen to put them here.

\begin{code}
tcTyConsOfType :: Type -> [TyCon]
-- tcTyConsOfType looks through all synonyms, but not through any newtypes.  
-- When it finds a Class, it returns the class TyCon.  The reaons it's here
-- (not in Type.lhs) is because it is newtype-aware.
tcTyConsOfType ty 
  = nameEnvElts (go ty)
  where
     go :: Type -> NameEnv TyCon  -- The NameEnv does duplicate elim
     go (TyVarTy v)	  	  = emptyNameEnv
     go (TyConApp tc tys) 	  = go_tc tc tys
     go (NewTcApp tc tys) 	  = go_tc tc tys
     go (AppTy a b)	  	  = go a `plusNameEnv` go b
     go (FunTy a b)	  	  = go a `plusNameEnv` go b
     go (PredTy (IParam _ ty))    = go ty
     go (PredTy (ClassP cls tys)) = go_tc (classTyCon cls) tys
     go (NoteTy _ ty)		  = go ty
     go (ForAllTy _ ty)	  	  = go ty

     go_tc tc tys = extendNameEnv (go_s tys) (tyConName tc) tc
     go_s tys = foldr (plusNameEnv . go) emptyNameEnv tys
\end{code}


%************************************************************************
%*									*
	Compuing TyCon argument variances
%*									*
%************************************************************************

Computing the tyConArgVrcs info
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

@tyConArgVrcs@ gives a list of (occPos,occNeg) flags, one for each
tyvar.  For @AlgTyCon@s and @SynTyCon@s, this info must be precomputed
separately.  Note that this is information about occurrences of type
variables, not usages of term variables.

The function @calcTyConArgVrcs@ must be passed a list of *algebraic or
syntycons only* such that all tycons referred to (by mutual recursion)
appear in the list.  The fixpointing will be done on this set of
tycons as a whole.  It returns a list of @tyconVrcInfo@ data, ready to
be (knot-tyingly?) stuck back into the appropriate fields.

\begin{code}
calcTyConArgVrcs :: [TyThing] -> Name -> ArgVrcs
-- Gives arg variances for TyCons, 
-- including the class TyCon of a class
calcTyConArgVrcs tyclss
  = get_vrc
  where
    tycons = map getTyCon tyclss

	-- We should only look up things that are in the map
    get_vrc n = case lookupNameEnv final_oi n of
		  Just (_, pms) -> pms
		  Nothing -> pprPanic "calcVrcs" (ppr n)

	-- We are going to fold over this map,
	-- so we need the TyCon in the range
    final_oi :: NameEnv (TyCon, ArgVrcs)
    final_oi = tcaoFix initial_oi

    initial_oi :: NameEnv (TyCon, ArgVrcs)
    initial_oi = mkNameEnv [(tyConName tc, (tc, initial tc))
			   | tc <- tycons]
    initial tc = if isAlgTyCon tc && isNothing (tyConDataCons_maybe tc) then
                         -- make pessimistic assumption (and warn)
                         abstractVrcs tc
                       else
                         replicate (tyConArity tc) (False,False)

    tcaoFix :: NameEnv (TyCon, ArgVrcs)   -- initial ArgVrcs per tycon
	    -> NameEnv (TyCon, ArgVrcs)   -- fixpointed ArgVrcs per tycon
    tcaoFix oi 
	| changed   = tcaoFix oi'
	| otherwise = oi'
	where
	 (changed,oi') = foldNameEnv iterate (False,oi) oi

    iterate (tc, pms) (changed,oi')
      =	(changed || (pms /= pms'),
	 extendNameEnv oi' (tyConName tc) (tc, pms'))
      where
	pms' = tcaoIter oi' tc  -- seq not simult

    tcaoIter :: NameEnv (TyCon, ArgVrcs)  -- reference ArgVrcs (initial)
	     -> TyCon                     -- tycon to update
	     -> ArgVrcs                   -- new ArgVrcs for tycon

    tcaoIter oi tc | isAlgTyCon tc
      = if null data_cons then
	    abstractVrcs tc		-- Data types with no constructors
	else
            map (\v -> anyVrc (vrcInTy (lookup oi) v) argtys) vs
      where
       	data_cons = tyConDataCons tc
       	vs        = tyConTyVars tc
       	argtys    = concatMap dataConRepArgTys data_cons	-- Rep? or Orig?

    tcaoIter oi tc | isSynTyCon tc
      = let (tyvs,ty) = getSynTyConDefn tc
                        -- we use the already-computed result for tycons not in this SCC
        in  map (\v -> vrcInTy (lookup oi) v ty) tyvs

    lookup oi tc = case lookupNameEnv oi (tyConName tc) of
			Just (_, pms) -> pms
			Nothing	      -> tyConArgVrcs tc
	 -- We use the already-computed result for tycons not in this SCC


abstractVrcs :: TyCon -> ArgVrcs
abstractVrcs tc = 
#ifdef DEBUG
                  pprTrace "Vrc: abstract tycon:" (ppr tc) $
#endif
                  warn_abstract_vrcs `seq` replicate (tyConArity tc) (True,True)

warn_abstract_vrcs
-- we pull the message out as a CAF so the warning only appears *once*
  = trace ("WARNING: tyConArgVrc info inaccurate due to unavailable constructors.\n"
        ++ "         Use -fno-prune-tydecls to fix.") $
                ()
\end{code}


Variance of tyvars in a type
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A general variance-check function.  We pass a function for determining
the @ArgVrc@s of a tycon; when fixpointing this refers to the current
value; otherwise this should be looked up from the tycon's own
tyConArgVrcs.  Again, it knows the representation of Types.

\begin{code}
vrcInTy :: (TyCon -> ArgVrcs)  -- function to get argVrcs of a tycon (break out of recursion)
        -> TyVar               -- tyvar to check Vrcs of
        -> Type                -- type to check for occ in
        -> (Bool,Bool)         -- (occurs positively, occurs negatively)

vrcInTy fao v (NoteTy (SynNote _)   ty) = vrcInTy fao v ty
    			-- SynTyCon doesn't neccessarily have vrcInfo at this point,
    			-- so don't try and use it

vrcInTy fao v (NoteTy (FTVNote ftv) ty) = if elemVarSet v ftv
    					  then vrcInTy fao v ty
    					  else (False,False)
    			-- note that ftv cannot be calculated as occPos||occNeg,
    			-- since if a tyvar occurs only as unused tyconarg,
    			-- occPos==occNeg==False, but ftv=True

vrcInTy fao v (TyVarTy v')              = if v==v'
    					  then (True,False)
    					  else (False,False)

vrcInTy fao v (AppTy ty1 ty2)           = if vrcInTy fao v ty2 /= (False,False)
                                          then (True,True)
                                          else vrcInTy fao v ty1
                        -- ty1 is probably unknown (or it would have been beta-reduced);
                        -- hence if v occurs in ty2 at all then it could occur with
                        -- either variance.  Otherwise it occurs as it does in ty1.

vrcInTy fao v (FunTy ty1 ty2)           = negVrc (vrcInTy fao v ty1)
                                          `orVrc`
                                          vrcInTy fao v ty2
					 
vrcInTy fao v (ForAllTy v' ty)          = if v==v'
					  then (False,False)
    					  else vrcInTy fao v ty

vrcInTy fao v (TyConApp tc tys)         = let pms1 = map (vrcInTy fao v) tys
    					      pms2 = fao tc
    				          in  orVrcs (zipWith timesVrc pms1 pms2)

vrcInTy fao v (NewTcApp tc tys)         = let pms1 = map (vrcInTy fao v) tys
    					      pms2 = fao tc
    				          in  orVrcs (zipWith timesVrc pms1 pms2)

vrcInTy fao v (PredTy st) = vrcInTy fao v (predTypeRep st)
\end{code}


External entry point: assumes tyconargvrcs already computed.

\begin{code}
tyVarVrc :: TyVar               -- tyvar to check Vrc of
         -> Type                -- type to check for occ in
         -> (Bool,Bool)         -- (occurs positively, occurs negatively)

tyVarVrc = vrcInTy tyConArgVrcs
\end{code}


Variance algebra
~~~~~~~~~~~~~~~~

\begin{code}
orVrc :: (Bool,Bool) -> (Bool,Bool) -> (Bool,Bool)
orVrc (p1,m1) (p2,m2) = (p1||p2,m1||m2)

orVrcs :: [(Bool,Bool)] -> (Bool,Bool)
orVrcs = foldl orVrc (False,False)

negVrc :: (Bool,Bool) -> (Bool,Bool)
negVrc (p1,m1) = (m1,p1)

anyVrc :: (a -> (Bool,Bool)) -> [a] -> (Bool,Bool)
anyVrc p as = foldl (\ pm a -> pm `orVrc` p a)
                    (False,False) as

timesVrc :: (Bool,Bool) -> (Bool,Bool) -> (Bool,Bool)
timesVrc (p1,m1) (p2,m2) = (p1 && p2 || m1 && m2,
    			    p1 && m2 || m1 && p2)
\end{code}
