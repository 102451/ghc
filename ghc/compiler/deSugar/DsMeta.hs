-----------------------------------------------------------------------------
-- The purpose of this module is to transform an HsExpr into a CoreExpr which
-- when evaluated, returns a (Meta.Q Meta.Exp) computation analogous to the
-- input HsExpr. We do this in the DsM monad, which supplies access to
-- CoreExpr's of the "smart constructors" of the Meta.Exp datatype.
--
-- It also defines a bunch of knownKeyNames, in the same way as is done
-- in prelude/PrelNames.  It's much more convenient to do it here, becuase
-- otherwise we have to recompile PrelNames whenever we add a Name, which is
-- a Royal Pain (triggers other recompilation).
-----------------------------------------------------------------------------


module DsMeta( dsBracket, 
	       templateHaskellNames, qTyConName, nameTyConName,
	       liftName, expQTyConName, decQTyConName, typeQTyConName,
	       decTyConName, typeTyConName, mkNameG_dName, mkNameG_vName, mkNameG_tcName
	        ) where

#include "HsVersions.h"

import {-# SOURCE #-}	DsExpr ( dsExpr )

import MatchLit	  ( dsLit )
import DsUtils    ( mkListExpr, mkStringLit, mkCoreTup, mkIntExpr )
import DsMonad

import qualified Language.Haskell.TH as TH

import HsSyn
import PrelNames  ( rationalTyConName, integerTyConName, negateName )
import OccName	  ( isDataOcc, isTvOcc, occNameUserString )
-- To avoid clashes with DsMeta.varName we must make a local alias for OccName.varName
-- we do this by removing varName from the import of OccName above, making
-- a qualified instance of OccName and using OccNameAlias.varName where varName
-- ws previously used in this file.
import qualified OccName

import Module	  ( Module, mkModule, mkModuleName, moduleUserString )
import Id         ( Id, mkLocalId )
import OccName	  ( mkOccFS )
import Name       ( Name, mkExternalName, localiseName, nameOccName, nameModule, 
		    isExternalName, getSrcLoc )
import NameEnv
import Type       ( Type, mkGenTyConApp )
import TcType	  ( tcTyConAppArgs )
import TyCon	  ( tyConName )
import TysWiredIn ( parrTyCon )
import CoreSyn
import CoreUtils  ( exprType )
import SrcLoc	  ( noSrcLoc, unLoc, Located(..), SrcSpan, srcLocSpan )
import Maybe	  ( catMaybes )
import Unique	  ( mkPreludeTyConUnique, mkPreludeMiscIdUnique, getKey, Uniquable(..) )
import BasicTypes ( NewOrData(..), isBoxed ) 
import Packages	  ( thPackage )
import Outputable
import Bag	  ( bagToList )

import Monad ( zipWithM )
import List ( sortBy )
 
-----------------------------------------------------------------------------
dsBracket :: HsBracket Name -> [PendingSplice] -> DsM CoreExpr
-- Returns a CoreExpr of type TH.ExpQ
-- The quoted thing is parameterised over Name, even though it has
-- been type checked.  We don't want all those type decorations!

dsBracket brack splices
  = dsExtendMetaEnv new_bit (do_brack brack)
  where
    new_bit = mkNameEnv [(n, Splice (unLoc e)) | (n,e) <- splices]

    do_brack (VarBr n)  = do { MkC e1  <- lookupOcc n ; return e1 }
    do_brack (ExpBr e)  = do { MkC e1  <- repLE e     ; return e1 }
    do_brack (PatBr p)  = do { MkC p1  <- repLP p     ; return p1 }
    do_brack (TypBr t)  = do { MkC t1  <- repLTy t     ; return t1 }
    do_brack (DecBr ds) = do { MkC ds1 <- repTopDs ds ; return ds1 }

{- -------------- Examples --------------------

  [| \x -> x |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (var x1)


  [| \x -> $(f [| x |]) |]
====>
  gensym (unpackString "x"#) `bindQ` \ x1::String ->
  lam (pvar x1) (f (var x1))
-}


-------------------------------------------------------
-- 			Declarations
-------------------------------------------------------

repTopDs :: HsGroup Name -> DsM (Core (TH.Q [TH.Dec]))
repTopDs group
 = do { let { bndrs = map unLoc (groupBinders group) } ;
	ss <- mkGenSyms bndrs ;

	-- Bind all the names mainly to avoid repeated use of explicit strings.
	-- Thus	we get
	--	do { t :: String <- genSym "T" ;
	--	     return (Data t [] ...more t's... }
	-- The other important reason is that the output must mention
	-- only "T", not "Foo:T" where Foo is the current module

	
	decls <- addBinds ss (do {
			val_ds  <- mapM rep_bind_group (hs_valds group) ;
			tycl_ds <- mapM repTyClD (hs_tyclds group) ;
			inst_ds <- mapM repInstD' (hs_instds group) ;
			-- more needed
			return (de_loc $ sort_by_loc $ concat val_ds ++ catMaybes tycl_ds ++ inst_ds) }) ;

	decl_ty <- lookupType decQTyConName ;
	let { core_list = coreList' decl_ty decls } ;

	dec_ty <- lookupType decTyConName ;
	q_decs  <- repSequenceQ dec_ty core_list ;

	wrapNongenSyms ss q_decs
	-- Do *not* gensym top-level binders
      }

groupBinders (HsGroup { hs_valds = val_decls, hs_tyclds = tycl_decls,
			hs_fords = foreign_decls })
-- Collect the binders of a Group
  = collectGroupBinders val_decls ++
    [n | d <- tycl_decls, n <- tyClDeclNames (unLoc d)] ++
    [n | L _ (ForeignImport n _ _ _) <- foreign_decls]


{- 	Note [Binders and occurrences]
	~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we desugar [d| data T = MkT |]
we want to get
	Data "T" [] [Con "MkT" []] []
and *not*
	Data "Foo:T" [] [Con "Foo:MkT" []] []
That is, the new data decl should fit into whatever new module it is
asked to fit in.   We do *not* clone, though; no need for this:
	Data "T79" ....

But if we see this:
	data T = MkT 
	foo = reifyDecl T

then we must desugar to
	foo = Data "Foo:T" [] [Con "Foo:MkT" []] []

So in repTopDs we bring the binders into scope with mkGenSyms and addBinds.
And we use lookupOcc, rather than lookupBinder
in repTyClD and repC.

-}

repTyClD :: LTyClDecl Name -> DsM (Maybe (SrcSpan, Core TH.DecQ))

repTyClD (L loc (TyData { tcdND = DataType, tcdCtxt = cxt, 
		    tcdLName = tc, tcdTyVars = tvs, 
		    tcdCons = cons, tcdDerivs = mb_derivs }))
 = do { tc1 <- lookupLOcc tc ;		-- See note [Binders and occurrences] 
        dec <- addTyVarBinds tvs $ \bndrs -> do {
      	       cxt1    <- repLContext cxt ;
               cons1   <- mapM repC cons ;
      	       cons2   <- coreList conQTyConName cons1 ;
      	       derivs1 <- repDerivs mb_derivs ;
	       bndrs1  <- coreList nameTyConName bndrs ;
      	       repData cxt1 tc1 bndrs1 cons2 derivs1 } ;
        return $ Just (loc, dec) }

repTyClD (L loc (TyData { tcdND = NewType, tcdCtxt = cxt, 
		    tcdLName = tc, tcdTyVars = tvs, 
		    tcdCons = [con], tcdDerivs = mb_derivs }))
 = do { tc1 <- lookupLOcc tc ;		-- See note [Binders and occurrences] 
        dec <- addTyVarBinds tvs $ \bndrs -> do {
      	       cxt1   <- repLContext cxt ;
               con1   <- repC con ;
      	       derivs1 <- repDerivs mb_derivs ;
	       bndrs1  <- coreList nameTyConName bndrs ;
      	       repNewtype cxt1 tc1 bndrs1 con1 derivs1 } ;
        return $ Just (loc, dec) }

repTyClD (L loc (TySynonym { tcdLName = tc, tcdTyVars = tvs, tcdSynRhs = ty }))
 = do { tc1 <- lookupLOcc tc ;		-- See note [Binders and occurrences] 
        dec <- addTyVarBinds tvs $ \bndrs -> do {
	       ty1     <- repLTy ty ;
	       bndrs1  <- coreList nameTyConName bndrs ;
	       repTySyn tc1 bndrs1 ty1 } ;
 	return (Just (loc, dec)) }

repTyClD (L loc (ClassDecl { tcdCtxt = cxt, tcdLName = cls, 
		      tcdTyVars = tvs, 
		      tcdFDs = [], 	-- We don't understand functional dependencies
		      tcdSigs = sigs, tcdMeths = meth_binds }))
 = do { cls1 <- lookupLOcc cls ;		-- See note [Binders and occurrences] 
    	dec  <- addTyVarBinds tvs $ \bndrs -> do {
 		  cxt1   <- repLContext cxt ;
 		  sigs1  <- rep_sigs sigs ;
 		  binds1 <- rep_binds meth_binds ;
 		  decls1 <- coreList decQTyConName (sigs1 ++ binds1) ;
	          bndrs1 <- coreList nameTyConName bndrs ;
 		  repClass cxt1 cls1 bndrs1 decls1 } ;
    	return $ Just (loc, dec) }

-- Un-handled cases
repTyClD (L loc d) = do { dsWarn (loc, hang msg 4 (ppr d)) ;
	          	   return Nothing
	     		 }
  where
    msg = ptext SLIT("Cannot desugar this Template Haskell declaration:")

repInstD' (L loc (InstDecl ty binds _))		-- Ignore user pragmas for now
 = do	{ i <- addTyVarBinds tvs $ \tv_bndrs ->
		-- We must bring the type variables into scope, so their occurrences
		-- don't fail,  even though the binders don't appear in the resulting 
		-- data structure
		do {  cxt1 <- repContext cxt
		   ; inst_ty1 <- repPred (HsClassP cls tys)
		   ; ss <- mkGenSyms (collectHsBindBinders binds)
		   ; binds1 <- addBinds ss (rep_binds binds)
		   ; decls1 <- coreList decQTyConName binds1
		   ; decls2 <- wrapNongenSyms ss decls1
		   -- wrapNonGenSyms: do not clone the class op names!
		   -- They must be called 'op' etc, not 'op34'
		   ; repInst cxt1 inst_ty1 decls2 }

	; return (loc, i)}
 where
   (tvs, cxt, cls, tys) = splitHsInstDeclTy (unLoc ty)

-------------------------------------------------------
-- 			Constructors
-------------------------------------------------------

repC :: LConDecl Name -> DsM (Core TH.ConQ)
repC (L loc (ConDecl con [] (L _ []) details))
  = do { con1     <- lookupLOcc con ;		-- See note [Binders and occurrences] 
	 repConstr con1 details }

repBangTy :: LBangType Name -> DsM (Core (TH.StrictTypeQ))
repBangTy (L _ (BangType str ty)) = do 
  MkC s <- rep2 strName []
  MkC t <- repLTy ty
  rep2 strictTypeName [s, t]
  where strName = case str of
			HsNoBang -> notStrictName
			other    -> isStrictName

-------------------------------------------------------
-- 			Deriving clause
-------------------------------------------------------

repDerivs :: Maybe (LHsContext Name) -> DsM (Core [TH.Name])
repDerivs Nothing = coreList nameTyConName []
repDerivs (Just (L _ ctxt))
  = do { strs <- mapM rep_deriv ctxt ; 
	 coreList nameTyConName strs }
  where
    rep_deriv :: LHsPred Name -> DsM (Core TH.Name)
	-- Deriving clauses must have the simple H98 form
    rep_deriv (L _ (HsClassP cls [])) = lookupOcc cls
    rep_deriv other		      = panic "rep_deriv"


-------------------------------------------------------
--   Signatures in a class decl, or a group of bindings
-------------------------------------------------------

rep_sigs :: [LSig Name] -> DsM [Core TH.DecQ]
rep_sigs sigs = do locs_cores <- rep_sigs' sigs
                   return $ de_loc $ sort_by_loc locs_cores

rep_sigs' :: [LSig Name] -> DsM [(SrcSpan, Core TH.DecQ)]
	-- We silently ignore ones we don't recognise
rep_sigs' sigs = do { sigs1 <- mapM rep_sig sigs ;
		     return (concat sigs1) }

rep_sig :: LSig Name -> DsM [(SrcSpan, Core TH.DecQ)]
	-- Singleton => Ok
	-- Empty     => Too hard, signature ignored
rep_sig (L loc (Sig nm ty)) = rep_proto nm ty loc
rep_sig other		    = return []

rep_proto :: Located Name -> LHsType Name -> SrcSpan -> DsM [(SrcSpan, Core TH.DecQ)]
rep_proto nm ty loc = do { nm1 <- lookupLOcc nm ; 
		       ty1 <- repLTy ty ; 
		       sig <- repProto nm1 ty1 ;
		       return [(loc, sig)] }


-------------------------------------------------------
-- 			Types
-------------------------------------------------------

-- gensym a list of type variables and enter them into the meta environment;
-- the computations passed as the second argument is executed in that extended
-- meta environment and gets the *new* names on Core-level as an argument
--
addTyVarBinds :: [LHsTyVarBndr Name]	         -- the binders to be added
	      -> ([Core TH.Name] -> DsM (Core (TH.Q a))) -- action in the ext env
	      -> DsM (Core (TH.Q a))
addTyVarBinds tvs m =
  do
    let names = map (hsTyVarName.unLoc) tvs
    freshNames <- mkGenSyms names
    term       <- addBinds freshNames $ do
		    bndrs <- mapM lookupBinder names 
		    m bndrs
    wrapGenSyns freshNames term

-- represent a type context
--
repLContext :: LHsContext Name -> DsM (Core TH.CxtQ)
repLContext (L _ ctxt) = repContext ctxt

repContext :: HsContext Name -> DsM (Core TH.CxtQ)
repContext ctxt = do 
	            preds    <- mapM repLPred ctxt
		    predList <- coreList typeQTyConName preds
		    repCtxt predList

-- represent a type predicate
--
repLPred :: LHsPred Name -> DsM (Core TH.TypeQ)
repLPred (L _ p) = repPred p

repPred :: HsPred Name -> DsM (Core TH.TypeQ)
repPred (HsClassP cls tys) = do
			       tcon <- repTy (HsTyVar cls)
			       tys1 <- repLTys tys
			       repTapps tcon tys1
repPred (HsIParam _ _)     = 
  panic "DsMeta.repTy: Can't represent predicates with implicit parameters"

-- yield the representation of a list of types
--
repLTys :: [LHsType Name] -> DsM [Core TH.TypeQ]
repLTys tys = mapM repLTy tys

-- represent a type
--
repLTy :: LHsType Name -> DsM (Core TH.TypeQ)
repLTy (L _ ty) = repTy ty

repTy :: HsType Name -> DsM (Core TH.TypeQ)
repTy (HsForAllTy _ tvs ctxt ty)  = 
  addTyVarBinds tvs $ \bndrs -> do
    ctxt1  <- repLContext ctxt
    ty1    <- repLTy ty
    bndrs1 <- coreList nameTyConName bndrs
    repTForall bndrs1 ctxt1 ty1

repTy (HsTyVar n)
  | isTvOcc (nameOccName n)       = do 
				      tv1 <- lookupBinder n
				      repTvar tv1
  | otherwise		          = do 
				      tc1 <- lookupOcc n
				      repNamedTyCon tc1
repTy (HsAppTy f a)               = do 
				      f1 <- repLTy f
				      a1 <- repLTy a
				      repTapp f1 a1
repTy (HsFunTy f a)               = do 
				      f1   <- repLTy f
				      a1   <- repLTy a
				      tcon <- repArrowTyCon
				      repTapps tcon [f1, a1]
repTy (HsListTy t)		  = do
				      t1   <- repLTy t
				      tcon <- repListTyCon
				      repTapp tcon t1
repTy (HsPArrTy t)                = do
				      t1   <- repLTy t
				      tcon <- repTy (HsTyVar (tyConName parrTyCon))
				      repTapp tcon t1
repTy (HsTupleTy tc tys)	  = do
				      tys1 <- repLTys tys 
				      tcon <- repTupleTyCon (length tys)
				      repTapps tcon tys1
repTy (HsOpTy ty1 n ty2) 	  = repLTy ((nlHsTyVar (unLoc n) `nlHsAppTy` ty1) 
					   `nlHsAppTy` ty2)
repTy (HsParTy t)  	       	  = repLTy t
repTy (HsNumTy i)                 =
  panic "DsMeta.repTy: Can't represent number types (for generics)"
repTy (HsPredTy pred)             = repLPred pred
repTy (HsKindSig ty kind)	  = 
  panic "DsMeta.repTy: Can't represent explicit kind signatures yet"


-----------------------------------------------------------------------------
-- 		Expressions
-----------------------------------------------------------------------------

repLEs :: [LHsExpr Name] -> DsM (Core [TH.ExpQ])
repLEs es = do { es'  <- mapM repLE es ;
		 coreList expQTyConName es' }

-- FIXME: some of these panics should be converted into proper error messages
--	  unless we can make sure that constructs, which are plainly not
--	  supported in TH already lead to error messages at an earlier stage
repLE :: LHsExpr Name -> DsM (Core TH.ExpQ)
repLE (L _ e) = repE e

repE :: HsExpr Name -> DsM (Core TH.ExpQ)
repE (HsVar x)            =
  do { mb_val <- dsLookupMetaEnv x 
     ; case mb_val of
	Nothing	         -> do { str <- globalVar x
			       ; repVarOrCon x str }
	Just (Bound y)   -> repVarOrCon x (coreVar y)
	Just (Splice e)  -> do { e' <- dsExpr e
			       ; return (MkC e') } }
repE (HsIPVar x) = panic "DsMeta.repE: Can't represent implicit parameters"

	-- Remember, we're desugaring renamer output here, so
	-- HsOverlit can definitely occur
repE (HsOverLit l) = do { a <- repOverloadedLiteral l; repLit a }
repE (HsLit l)     = do { a <- repLiteral l;           repLit a }
repE (HsLam m)     = repLambda m
repE (HsApp x y)   = do {a <- repLE x; b <- repLE y; repApp a b}

repE (OpApp e1 op fix e2) =
  do { arg1 <- repLE e1; 
       arg2 <- repLE e2; 
       the_op <- repLE op ;
       repInfixApp arg1 the_op arg2 } 
repE (NegApp x nm)        = do
			      a         <- repLE x
			      negateVar <- lookupOcc negateName >>= repVar
			      negateVar `repApp` a
repE (HsPar x)            = repLE x
repE (SectionL x y)       = do { a <- repLE x; b <- repLE y; repSectionL a b } 
repE (SectionR x y)       = do { a <- repLE x; b <- repLE y; repSectionR a b } 
repE (HsCase e ms)        = do { arg <- repLE e
			       ; ms2 <- mapM repMatchTup ms
			       ; repCaseE arg (nonEmptyCoreList ms2) }
repE (HsIf x y z)         = do
			      a <- repLE x
			      b <- repLE y
			      c <- repLE z
			      repCond a b c
repE (HsLet bs e)         = do { (ss,ds) <- repBinds bs
			       ; e2 <- addBinds ss (repLE e)
			       ; z <- repLetE ds e2
			       ; wrapGenSyns ss z }
-- FIXME: I haven't got the types here right yet
repE (HsDo DoExpr sts _ ty) 
 = do { (ss,zs) <- repLSts sts; 
        e       <- repDoE (nonEmptyCoreList zs);
        wrapGenSyns ss e }
repE (HsDo ListComp sts _ ty) 
 = do { (ss,zs) <- repLSts sts; 
        e       <- repComp (nonEmptyCoreList zs);
        wrapGenSyns ss e }
repE (HsDo _ _ _ _) = panic "DsMeta.repE: Can't represent mdo and [: :] yet"
repE (ExplicitList ty es) = do { xs <- repLEs es; repListExp xs } 
repE (ExplicitPArr ty es) = 
  panic "DsMeta.repE: No explicit parallel arrays yet"
repE (ExplicitTuple es boxed) 
  | isBoxed boxed         = do { xs <- repLEs es; repTup xs }
  | otherwise		  = panic "DsMeta.repE: Can't represent unboxed tuples"
repE (RecordCon c flds)
 = do { x <- lookupLOcc c;
        fs <- repFields flds;
        repRecCon x fs }
repE (RecordUpd e flds)
 = do { x <- repLE e;
        fs <- repFields flds;
        repRecUpd x fs }

repE (ExprWithTySig e ty) = do { e1 <- repLE e; t1 <- repLTy ty; repSigExp e1 t1 }
repE (ArithSeqIn aseq) =
  case aseq of
    From e              -> do { ds1 <- repLE e; repFrom ds1 }
    FromThen e1 e2      -> do 
		             ds1 <- repLE e1
			     ds2 <- repLE e2
			     repFromThen ds1 ds2
    FromTo   e1 e2      -> do 
			     ds1 <- repLE e1
			     ds2 <- repLE e2
			     repFromTo ds1 ds2
    FromThenTo e1 e2 e3 -> do 
			     ds1 <- repLE e1
			     ds2 <- repLE e2
			     ds3 <- repLE e3
			     repFromThenTo ds1 ds2 ds3
repE (PArrSeqOut _ aseq)  = panic "DsMeta.repE: parallel array seq.s missing"
repE (HsCoreAnn _ _)      = panic "DsMeta.repE: Can't represent CoreAnn" -- hdaume: core annotations
repE (HsSCC _ _)          = panic "DsMeta.repE: Can't represent SCC"
repE (HsBracketOut _ _)   = panic "DsMeta.repE: Can't represent Oxford brackets"
repE (HsSpliceE (HsSplice n _)) 
  = do { mb_val <- dsLookupMetaEnv n
       ; case mb_val of
		 Just (Splice e) -> do { e' <- dsExpr e
				       ; return (MkC e') }
		 other	     -> pprPanic "HsSplice" (ppr n) }

repE e = pprPanic "DsMeta.repE: Illegal expression form" (ppr e)

-----------------------------------------------------------------------------
-- Building representations of auxillary structures like Match, Clause, Stmt, 

repMatchTup ::  LMatch Name -> DsM (Core TH.MatchQ) 
repMatchTup (L _ (Match [p] ty (GRHSs guards wheres ty2))) =
  do { ss1 <- mkGenSyms (collectPatBinders p) 
     ; addBinds ss1 $ do {
     ; p1 <- repLP p
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
     ; gs    <- repGuards guards
     ; match <- repMatch p1 gs ds
     ; wrapGenSyns (ss1++ss2) match }}}

repClauseTup ::  LMatch Name -> DsM (Core TH.ClauseQ)
repClauseTup (L _ (Match ps ty (GRHSs guards wheres ty2))) =
  do { ss1 <- mkGenSyms (collectPatsBinders ps) 
     ; addBinds ss1 $ do {
       ps1 <- repLPs ps
     ; (ss2,ds) <- repBinds wheres
     ; addBinds ss2 $ do {
       gs <- repGuards guards
     ; clause <- repClause ps1 gs ds
     ; wrapGenSyns (ss1++ss2) clause }}}

repGuards ::  [LGRHS Name] ->  DsM (Core TH.BodyQ)
repGuards [L _ (GRHS [L _ (ResultStmt e)])]
  = do {a <- repLE e; repNormal a }
repGuards other 
  = do { zs <- mapM process other; 
	 repGuarded (nonEmptyCoreList (map corePair zs)) }
  where 
    process (L _ (GRHS [L _ (ExprStmt e1 ty),
			L _ (ResultStmt e2)]))
           = do { x <- repLE e1; y <- repLE e2; return (x, y) }
    process other = panic "Non Haskell 98 guarded body"

repFields :: [(Located Name, LHsExpr Name)] -> DsM (Core [TH.FieldExp])
repFields flds = do
        fnames <- mapM lookupLOcc (map fst flds)
        es <- mapM repLE (map snd flds)
        fs <- zipWithM (\n x -> rep2 fieldExpName [unC n, unC x]) fnames es
        coreList fieldExpTyConName fs


-----------------------------------------------------------------------------
-- Representing Stmt's is tricky, especially if bound variables
-- shadow each other. Consider:  [| do { x <- f 1; x <- f x; g x } |]
-- First gensym new names for every variable in any of the patterns.
-- both static (x'1 and x'2), and dynamic ((gensym "x") and (gensym "y"))
-- if variables didn't shaddow, the static gensym wouldn't be necessary
-- and we could reuse the original names (x and x).
--
-- do { x'1 <- gensym "x"
--    ; x'2 <- gensym "x"   
--    ; doE [ BindSt (pvar x'1) [| f 1 |]
--          , BindSt (pvar x'2) [| f x |] 
--          , NoBindSt [| g x |] 
--          ]
--    }

-- The strategy is to translate a whole list of do-bindings by building a
-- bigger environment, and a bigger set of meta bindings 
-- (like:  x'1 <- gensym "x" ) and then combining these with the translations
-- of the expressions within the Do
      
-----------------------------------------------------------------------------
-- The helper function repSts computes the translation of each sub expression
-- and a bunch of prefix bindings denoting the dynamic renaming.

repLSts :: [LStmt Name] -> DsM ([GenSymBind], [Core TH.StmtQ])
repLSts stmts = repSts (map unLoc stmts)

repSts :: [Stmt Name] -> DsM ([GenSymBind], [Core TH.StmtQ])
repSts [ResultStmt e] = 
   do { a <- repLE e
      ; e1 <- repNoBindSt a
      ; return ([], [e1]) }
repSts (BindStmt p e : ss) =
   do { e2 <- repLE e 
      ; ss1 <- mkGenSyms (collectPatBinders p) 
      ; addBinds ss1 $ do {
      ; p1 <- repLP p; 
      ; (ss2,zs) <- repSts ss
      ; z <- repBindSt p1 e2
      ; return (ss1++ss2, z : zs) }}
repSts (LetStmt bs : ss) =
   do { (ss1,ds) <- repBinds bs
      ; z <- repLetSt ds
      ; (ss2,zs) <- addBinds ss1 (repSts ss)
      ; return (ss1++ss2, z : zs) } 
repSts (ExprStmt e ty : ss) =       
   do { e2 <- repLE e
      ; z <- repNoBindSt e2 
      ; (ss2,zs) <- repSts ss
      ; return (ss2, z : zs) }
repSts other = panic "Exotic Stmt in meta brackets"      


-----------------------------------------------------------
--			Bindings
-----------------------------------------------------------

repBinds :: [HsBindGroup Name] -> DsM ([GenSymBind], Core [TH.DecQ]) 
repBinds decs
 = do	{ let { bndrs = map unLoc (collectGroupBinders decs) }
		-- No need to worrry about detailed scopes within
		-- the binding group, because we are talking Names
		-- here, so we can safely treat it as a mutually 
		-- recursive group
	; ss        <- mkGenSyms bndrs
	; core      <- addBinds ss (rep_bind_groups decs)
	; core_list <- coreList decQTyConName core 
	; return (ss, core_list) }

rep_bind_groups :: [HsBindGroup Name] -> DsM [Core TH.DecQ]
-- Assumes: all the binders of the binding are alrady in the meta-env
rep_bind_groups binds = do 
  locs_cores_s <- mapM rep_bind_group binds
  return $ de_loc $ sort_by_loc (concat locs_cores_s)

rep_bind_group :: HsBindGroup Name -> DsM [(SrcSpan, Core TH.DecQ)]
-- Assumes: all the binders of the binding are alrady in the meta-env
rep_bind_group (HsBindGroup bs sigs _)
 = do { core1 <- mapM rep_bind (bagToList bs)
      ;	core2 <- rep_sigs' sigs
      ;	return (core1 ++ core2) }
rep_bind_group (HsIPBinds _)
  = panic "DsMeta:repBinds: can't do implicit parameters"

rep_binds :: LHsBinds Name -> DsM [Core TH.DecQ]
-- Assumes: all the binders of the binding are alrady in the meta-env
rep_binds binds = do 
  locs_cores <- mapM rep_bind (bagToList binds)
  return $ de_loc $ sort_by_loc locs_cores

rep_bind :: LHsBind Name -> DsM (SrcSpan, Core TH.DecQ)
-- Assumes: all the binders of the binding are alrady in the meta-env

-- Note GHC treats declarations of a variable (not a pattern) 
-- e.g.  x = g 5 as a Fun MonoBinds. This is indicated by a single match 
-- with an empty list of patterns
rep_bind (L loc (FunBind fn infx [L _ (Match [] ty (GRHSs guards wheres ty2))]))
 = do { (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
	; fn' <- lookupLBinder fn
	; p   <- repPvar fn'
	; ans <- repVal p guardcore wherecore
	; return (loc, ans) }

rep_bind (L loc (FunBind fn infx ms))
 =   do { ms1 <- mapM repClauseTup ms
	; fn' <- lookupLBinder fn
        ; ans <- repFun fn' (nonEmptyCoreList ms1)
        ; return (loc, ans) }

rep_bind (L loc (PatBind pat (GRHSs guards wheres ty2)))
 =   do { patcore <- repLP pat 
        ; (ss,wherecore) <- repBinds wheres
	; guardcore <- addBinds ss (repGuards guards)
        ; ans <- repVal patcore guardcore wherecore
        ; return (loc, ans) }

rep_bind (L loc (VarBind v e))
 =   do { v' <- lookupBinder v 
	; e2 <- repLE e
        ; x <- repNormal e2
        ; patcore <- repPvar v'
	; empty_decls <- coreList decQTyConName [] 
        ; ans <- repVal patcore x empty_decls
        ; return (srcLocSpan (getSrcLoc v), ans) }

-----------------------------------------------------------------------------
-- Since everything in a Bind is mutually recursive we need rename all
-- all the variables simultaneously. For example: 
-- [| AndMonoBinds (f x = x + g 2) (g x = f 1 + 2) |] would translate to
-- do { f'1 <- gensym "f"
--    ; g'2 <- gensym "g"
--    ; [ do { x'3 <- gensym "x"; fun f'1 [pvar x'3] [| x + g2 |]},
--        do { x'4 <- gensym "x"; fun g'2 [pvar x'4] [| f 1 + 2 |]}
--      ]}
-- This requires collecting the bindings (f'1 <- gensym "f"), and the 
-- environment ( f |-> f'1 ) from each binding, and then unioning them 
-- together. As we do this we collect GenSymBinds's which represent the renamed 
-- variables bound by the Bindings. In order not to lose track of these 
-- representations we build a shadow datatype MB with the same structure as 
-- MonoBinds, but which has slots for the representations


-----------------------------------------------------------------------------
-- GHC allows a more general form of lambda abstraction than specified
-- by Haskell 98. In particular it allows guarded lambda's like : 
-- (\  x | even x -> 0 | odd x -> 1) at the moment we can't represent this in
-- Haskell Template's Meta.Exp type so we punt if it isn't a simple thing like
-- (\ p1 .. pn -> exp) by causing an error.  

repLambda :: LMatch Name -> DsM (Core TH.ExpQ)
repLambda (L _ (Match ps _ (GRHSs [L _ (GRHS [L _ (ResultStmt e)])] [] _)))
 = do { let bndrs = collectPatsBinders ps ;
      ; ss  <- mkGenSyms bndrs
      ; lam <- addBinds ss (
		do { xs <- repLPs ps; body <- repLE e; repLam xs body })
      ; wrapGenSyns ss lam }

repLambda z = panic "Can't represent a guarded lambda in Template Haskell"  

  
-----------------------------------------------------------------------------
--			Patterns
-- repP deals with patterns.  It assumes that we have already
-- walked over the pattern(s) once to collect the binders, and 
-- have extended the environment.  So every pattern-bound 
-- variable should already appear in the environment.

-- Process a list of patterns
repLPs :: [LPat Name] -> DsM (Core [TH.Pat])
repLPs ps = do { ps' <- mapM repLP ps ;
		 coreList patTyConName ps' }

repLP :: LPat Name -> DsM (Core TH.Pat)
repLP (L _ p) = repP p

repP :: Pat Name -> DsM (Core TH.Pat)
repP (WildPat _)     = repPwild 
repP (LitPat l)      = do { l2 <- repLiteral l; repPlit l2 }
repP (VarPat x)      = do { x' <- lookupBinder x; repPvar x' }
repP (LazyPat p)     = do { p1 <- repLP p; repPtilde p1 }
repP (AsPat x p)     = do { x' <- lookupLBinder x; p1 <- repLP p; repPaspat x' p1 }
repP (ParPat p)      = repLP p 
repP (ListPat ps _)  = do { qs <- repLPs ps; repPlist qs }
repP (TuplePat ps _) = do { qs <- repLPs ps; repPtup qs }
repP (ConPatIn dc details)
 = do { con_str <- lookupLOcc dc
      ; case details of
         PrefixCon ps   -> do { qs <- repLPs ps; repPcon con_str qs }
         RecCon pairs -> do { vs <- sequence $ map lookupLOcc (map fst pairs)
                            ; ps <- sequence $ map repLP (map snd pairs)
                            ; fps <- zipWithM (\x y -> rep2 fieldPatName [unC x,unC y]) vs ps
                            ; fps' <- coreList fieldPatTyConName fps
                            ; repPrec con_str fps' }
         InfixCon p1 p2 -> do { qs <- repLPs [p1,p2]; repPcon con_str qs }
   }
repP (NPatIn l (Just _)) = panic "Can't cope with negative overloaded patterns yet (repP (NPatIn _ (Just _)))"
repP (NPatIn l Nothing) = do { a <- repOverloadedLiteral l; repPlit a }
repP other = panic "Exotic pattern inside meta brackets"

----------------------------------------------------------
-- Declaration ordering helpers

sort_by_loc :: [(SrcSpan, a)] -> [(SrcSpan, a)]
sort_by_loc xs = sortBy comp xs
    where comp x y = compare (fst x) (fst y)

de_loc :: [(a, b)] -> [b]
de_loc = map snd

----------------------------------------------------------
--	The meta-environment

-- A name/identifier association for fresh names of locally bound entities
type GenSymBind = (Name, Id)	-- Gensym the string and bind it to the Id
				-- I.e.		(x, x_id) means
				--	let x_id = gensym "x" in ...

-- Generate a fresh name for a locally bound entity

mkGenSyms :: [Name] -> DsM [GenSymBind]
-- We can use the existing name.  For example:
--	[| \x_77 -> x_77 + x_77 |]
-- desugars to
--	do { x_77 <- genSym "x"; .... }
-- We use the same x_77 in the desugared program, but with the type Bndr
-- instead of Int
--
-- We do make it an Internal name, though (hence localiseName)
--
-- Nevertheless, it's monadic because we have to generate nameTy
mkGenSyms ns = do { var_ty <- lookupType nameTyConName
		  ; return [(nm, mkLocalId (localiseName nm) var_ty) | nm <- ns] }

	     
addBinds :: [GenSymBind] -> DsM a -> DsM a
-- Add a list of fresh names for locally bound entities to the 
-- meta environment (which is part of the state carried around 
-- by the desugarer monad) 
addBinds bs m = dsExtendMetaEnv (mkNameEnv [(n,Bound id) | (n,id) <- bs]) m

-- Look up a locally bound name
--
lookupLBinder :: Located Name -> DsM (Core TH.Name)
lookupLBinder (L _ n) = lookupBinder n

lookupBinder :: Name -> DsM (Core TH.Name)
lookupBinder n 
  = do { mb_val <- dsLookupMetaEnv n;
	 case mb_val of
	    Just (Bound x) -> return (coreVar x)
	    other	   -> pprPanic "Failed binder lookup:" (ppr n) }

-- Look up a name that is either locally bound or a global name
--
-- * If it is a global name, generate the "original name" representation (ie,
--   the <module>:<name> form) for the associated entity
--
lookupLOcc :: Located Name -> DsM (Core TH.Name)
-- Lookup an occurrence; it can't be a splice.
-- Use the in-scope bindings if they exist
lookupLOcc (L _ n) = lookupOcc n

lookupOcc :: Name -> DsM (Core TH.Name)
lookupOcc n
  = do {  mb_val <- dsLookupMetaEnv n ;
          case mb_val of
		Nothing         -> globalVar n
		Just (Bound x)  -> return (coreVar x)
		Just (Splice _) -> pprPanic "repE:lookupOcc" (ppr n) 
    }

globalVar :: Name -> DsM (Core TH.Name)
-- Not bound by the meta-env
-- Could be top-level; or could be local
--	f x = $(g [| x |])
-- Here the x will be local
globalVar name
  | isExternalName name
  = do	{ MkC mod <- coreStringLit name_mod
	; MkC occ <- occNameLit name
	; rep2 mk_varg [mod,occ] }
  | otherwise
  = do 	{ MkC occ <- occNameLit name
	; MkC uni <- coreIntLit (getKey (getUnique name))
	; rep2 mkNameUName [occ,uni] }
  where
      name_mod = moduleUserString (nameModule name)
      name_occ = nameOccName name
      mk_varg | OccName.isDataOcc name_occ = mkNameG_dName
	      | OccName.isVarOcc  name_occ = mkNameG_vName
	      | OccName.isTcOcc   name_occ = mkNameG_tcName
	      | otherwise 	           = pprPanic "DsMeta.globalVar" (ppr name)

lookupType :: Name 	-- Name of type constructor (e.g. TH.ExpQ)
	   -> DsM Type	-- The type
lookupType tc_name = do { tc <- dsLookupTyCon tc_name ;
		          return (mkGenTyConApp tc []) }

wrapGenSyns :: [GenSymBind] 
	    -> Core (TH.Q a) -> DsM (Core (TH.Q a))
-- wrapGenSyns [(nm1,id1), (nm2,id2)] y 
--	--> bindQ (gensym nm1) (\ id1 -> 
--	    bindQ (gensym nm2 (\ id2 -> 
--	    y))

wrapGenSyns binds body@(MkC b)
  = do  { var_ty <- lookupType nameTyConName
	; go var_ty binds }
  where
    [elt_ty] = tcTyConAppArgs (exprType b) 
	-- b :: Q a, so we can get the type 'a' by looking at the
	-- argument type. NB: this relies on Q being a data/newtype,
	-- not a type synonym

    go var_ty [] = return body
    go var_ty ((name,id) : binds)
      = do { MkC body'  <- go var_ty binds
	   ; lit_str    <- occNameLit name
	   ; gensym_app <- repGensym lit_str
	   ; repBindQ var_ty elt_ty 
		      gensym_app (MkC (Lam id body')) }

-- Just like wrapGenSym, but don't actually do the gensym
-- Instead use the existing name:
--	let x = "x" in ...
-- Only used for [Decl], and for the class ops in class 
-- and instance decls
wrapNongenSyms :: [GenSymBind] -> Core a -> DsM (Core a)
wrapNongenSyms binds (MkC body)
  = do { binds' <- mapM do_one binds ;
	 return (MkC (mkLets binds' body)) }
  where
    do_one (name,id) 
	= do { MkC lit_str <- occNameLit name
	     ; MkC var <- rep2 mkNameName [lit_str]
	     ; return (NonRec id var) }

occNameLit :: Name -> DsM (Core String)
occNameLit n = coreStringLit (occNameUserString (nameOccName n))


-- %*********************************************************************
-- %*									*
--		Constructing code
-- %*									*
-- %*********************************************************************

-----------------------------------------------------------------------------
-- PHANTOM TYPES for consistency. In order to make sure we do this correct 
-- we invent a new datatype which uses phantom types.

newtype Core a = MkC CoreExpr
unC (MkC x) = x

rep2 :: Name -> [ CoreExpr ] -> DsM (Core a)
rep2 n xs = do { id <- dsLookupGlobalId n
               ; return (MkC (foldl App (Var id) xs)) }

-- Then we make "repConstructors" which use the phantom types for each of the
-- smart constructors of the Meta.Meta datatypes.


-- %*********************************************************************
-- %*									*
--		The 'smart constructors'
-- %*									*
-- %*********************************************************************

--------------- Patterns -----------------
repPlit   :: Core TH.Lit -> DsM (Core TH.Pat) 
repPlit (MkC l) = rep2 litPName [l]

repPvar :: Core TH.Name -> DsM (Core TH.Pat)
repPvar (MkC s) = rep2 varPName [s]

repPtup :: Core [TH.Pat] -> DsM (Core TH.Pat)
repPtup (MkC ps) = rep2 tupPName [ps]

repPcon   :: Core TH.Name -> Core [TH.Pat] -> DsM (Core TH.Pat)
repPcon (MkC s) (MkC ps) = rep2 conPName [s, ps]

repPrec   :: Core TH.Name -> Core [(TH.Name,TH.Pat)] -> DsM (Core TH.Pat)
repPrec (MkC c) (MkC rps) = rep2 recPName [c,rps]

repPtilde :: Core TH.Pat -> DsM (Core TH.Pat)
repPtilde (MkC p) = rep2 tildePName [p]

repPaspat :: Core TH.Name -> Core TH.Pat -> DsM (Core TH.Pat)
repPaspat (MkC s) (MkC p) = rep2 asPName [s, p]

repPwild  :: DsM (Core TH.Pat)
repPwild = rep2 wildPName []

repPlist :: Core [TH.Pat] -> DsM (Core TH.Pat)
repPlist (MkC ps) = rep2 listPName [ps]

--------------- Expressions -----------------
repVarOrCon :: Name -> Core TH.Name -> DsM (Core TH.ExpQ)
repVarOrCon vc str | isDataOcc (nameOccName vc) = repCon str
	           | otherwise 		        = repVar str

repVar :: Core TH.Name -> DsM (Core TH.ExpQ)
repVar (MkC s) = rep2 varEName [s] 

repCon :: Core TH.Name -> DsM (Core TH.ExpQ)
repCon (MkC s) = rep2 conEName [s] 

repLit :: Core TH.Lit -> DsM (Core TH.ExpQ)
repLit (MkC c) = rep2 litEName [c] 

repApp :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repApp (MkC x) (MkC y) = rep2 appEName [x,y] 

repLam :: Core [TH.Pat] -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repLam (MkC ps) (MkC e) = rep2 lamEName [ps, e]

repTup :: Core [TH.ExpQ] -> DsM (Core TH.ExpQ)
repTup (MkC es) = rep2 tupEName [es]

repCond :: Core TH.ExpQ -> Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repCond (MkC x) (MkC y) (MkC z) =  rep2 condEName [x,y,z] 

repLetE :: Core [TH.DecQ] -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repLetE (MkC ds) (MkC e) = rep2 letEName [ds, e] 

repCaseE :: Core TH.ExpQ -> Core [TH.MatchQ] -> DsM( Core TH.ExpQ)
repCaseE (MkC e) (MkC ms) = rep2 caseEName [e, ms]

repDoE :: Core [TH.StmtQ] -> DsM (Core TH.ExpQ)
repDoE (MkC ss) = rep2 doEName [ss]

repComp :: Core [TH.StmtQ] -> DsM (Core TH.ExpQ)
repComp (MkC ss) = rep2 compEName [ss]

repListExp :: Core [TH.ExpQ] -> DsM (Core TH.ExpQ)
repListExp (MkC es) = rep2 listEName [es]

repSigExp :: Core TH.ExpQ -> Core TH.TypeQ -> DsM (Core TH.ExpQ)
repSigExp (MkC e) (MkC t) = rep2 sigEName [e,t]

repRecCon :: Core TH.Name -> Core [TH.FieldExp]-> DsM (Core TH.ExpQ)
repRecCon (MkC c) (MkC fs) = rep2 recCName [c,fs]

repRecUpd :: Core TH.ExpQ -> Core [TH.FieldExp] -> DsM (Core TH.ExpQ)
repRecUpd (MkC e) (MkC fs) = rep2 recUpdEName [e,fs]

repInfixApp :: Core TH.ExpQ -> Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repInfixApp (MkC x) (MkC y) (MkC z) = rep2 infixAppName [x,y,z]

repSectionL :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repSectionL (MkC x) (MkC y) = rep2 sectionLName [x,y]

repSectionR :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repSectionR (MkC x) (MkC y) = rep2 sectionRName [x,y]

------------ Right hand sides (guarded expressions) ----
repGuarded :: Core [(TH.ExpQ, TH.ExpQ)] -> DsM (Core TH.BodyQ)
repGuarded (MkC pairs) = rep2 guardedBName [pairs]

repNormal :: Core TH.ExpQ -> DsM (Core TH.BodyQ)
repNormal (MkC e) = rep2 normalBName [e]

------------- Stmts -------------------
repBindSt :: Core TH.Pat -> Core TH.ExpQ -> DsM (Core TH.StmtQ)
repBindSt (MkC p) (MkC e) = rep2 bindSName [p,e]

repLetSt :: Core [TH.DecQ] -> DsM (Core TH.StmtQ)
repLetSt (MkC ds) = rep2 letSName [ds]

repNoBindSt :: Core TH.ExpQ -> DsM (Core TH.StmtQ)
repNoBindSt (MkC e) = rep2 noBindSName [e]

-------------- Range (Arithmetic sequences) -----------
repFrom :: Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFrom (MkC x) = rep2 fromEName [x]

repFromThen :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFromThen (MkC x) (MkC y) = rep2 fromThenEName [x,y]

repFromTo :: Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFromTo (MkC x) (MkC y) = rep2 fromToEName [x,y]

repFromThenTo :: Core TH.ExpQ -> Core TH.ExpQ -> Core TH.ExpQ -> DsM (Core TH.ExpQ)
repFromThenTo (MkC x) (MkC y) (MkC z) = rep2 fromThenToEName [x,y,z]

------------ Match and Clause Tuples -----------
repMatch :: Core TH.Pat -> Core TH.BodyQ -> Core [TH.DecQ] -> DsM (Core TH.MatchQ)
repMatch (MkC p) (MkC bod) (MkC ds) = rep2 matchName [p, bod, ds]

repClause :: Core [TH.Pat] -> Core TH.BodyQ -> Core [TH.DecQ] -> DsM (Core TH.ClauseQ)
repClause (MkC ps) (MkC bod) (MkC ds) = rep2 clauseName [ps, bod, ds]

-------------- Dec -----------------------------
repVal :: Core TH.Pat -> Core TH.BodyQ -> Core [TH.DecQ] -> DsM (Core TH.DecQ)
repVal (MkC p) (MkC b) (MkC ds) = rep2 valDName [p, b, ds]

repFun :: Core TH.Name -> Core [TH.ClauseQ] -> DsM (Core TH.DecQ)  
repFun (MkC nm) (MkC b) = rep2 funDName [nm, b]

repData :: Core TH.CxtQ -> Core TH.Name -> Core [TH.Name] -> Core [TH.ConQ] -> Core [TH.Name] -> DsM (Core TH.DecQ)
repData (MkC cxt) (MkC nm) (MkC tvs) (MkC cons) (MkC derivs)
    = rep2 dataDName [cxt, nm, tvs, cons, derivs]

repNewtype :: Core TH.CxtQ -> Core TH.Name -> Core [TH.Name] -> Core TH.ConQ -> Core [TH.Name] -> DsM (Core TH.DecQ)
repNewtype (MkC cxt) (MkC nm) (MkC tvs) (MkC con) (MkC derivs)
    = rep2 newtypeDName [cxt, nm, tvs, con, derivs]

repTySyn :: Core TH.Name -> Core [TH.Name] -> Core TH.TypeQ -> DsM (Core TH.DecQ)
repTySyn (MkC nm) (MkC tvs) (MkC rhs) = rep2 tySynDName [nm, tvs, rhs]

repInst :: Core TH.CxtQ -> Core TH.TypeQ -> Core [TH.DecQ] -> DsM (Core TH.DecQ)
repInst (MkC cxt) (MkC ty) (MkC ds) = rep2 instanceDName [cxt, ty, ds]

repClass :: Core TH.CxtQ -> Core TH.Name -> Core [TH.Name] -> Core [TH.DecQ] -> DsM (Core TH.DecQ)
repClass (MkC cxt) (MkC cls) (MkC tvs) (MkC ds) = rep2 classDName [cxt, cls, tvs, ds]

repProto :: Core TH.Name -> Core TH.TypeQ -> DsM (Core TH.DecQ)
repProto (MkC s) (MkC ty) = rep2 sigDName [s, ty]

repCtxt :: Core [TH.TypeQ] -> DsM (Core TH.CxtQ)
repCtxt (MkC tys) = rep2 cxtName [tys]

repConstr :: Core TH.Name -> HsConDetails Name (LBangType Name)
          -> DsM (Core TH.ConQ)
repConstr con (PrefixCon ps)
    = do arg_tys  <- mapM repBangTy ps
         arg_tys1 <- coreList strictTypeQTyConName arg_tys
         rep2 normalCName [unC con, unC arg_tys1]
repConstr con (RecCon ips)
    = do arg_vs   <- mapM lookupLOcc (map fst ips)
         arg_tys  <- mapM repBangTy (map snd ips)
         arg_vtys <- zipWithM (\x y -> rep2 varStrictTypeName [unC x, unC y])
                              arg_vs arg_tys
         arg_vtys' <- coreList varStrictTypeQTyConName arg_vtys
         rep2 recCName [unC con, unC arg_vtys']
repConstr con (InfixCon st1 st2)
    = do arg1 <- repBangTy st1
         arg2 <- repBangTy st2
         rep2 infixCName [unC arg1, unC con, unC arg2]

------------ Types -------------------

repTForall :: Core [TH.Name] -> Core TH.CxtQ -> Core TH.TypeQ -> DsM (Core TH.TypeQ)
repTForall (MkC tvars) (MkC ctxt) (MkC ty)
    = rep2 forallTName [tvars, ctxt, ty]

repTvar :: Core TH.Name -> DsM (Core TH.TypeQ)
repTvar (MkC s) = rep2 varTName [s]

repTapp :: Core TH.TypeQ -> Core TH.TypeQ -> DsM (Core TH.TypeQ)
repTapp (MkC t1) (MkC t2) = rep2 appTName [t1,t2]

repTapps :: Core TH.TypeQ -> [Core TH.TypeQ] -> DsM (Core TH.TypeQ)
repTapps f []     = return f
repTapps f (t:ts) = do { f1 <- repTapp f t; repTapps f1 ts }

--------- Type constructors --------------

repNamedTyCon :: Core TH.Name -> DsM (Core TH.TypeQ)
repNamedTyCon (MkC s) = rep2 conTName [s]

repTupleTyCon :: Int -> DsM (Core TH.TypeQ)
-- Note: not Core Int; it's easier to be direct here
repTupleTyCon i = rep2 tupleTName [mkIntExpr (fromIntegral i)]

repArrowTyCon :: DsM (Core TH.TypeQ)
repArrowTyCon = rep2 arrowTName []

repListTyCon :: DsM (Core TH.TypeQ)
repListTyCon = rep2 listTName []


----------------------------------------------------------
--		Literals

repLiteral :: HsLit -> DsM (Core TH.Lit)
repLiteral lit 
  = do lit' <- case lit of
                   HsIntPrim i    -> mk_integer i
                   HsInt i        -> mk_integer i
                   HsFloatPrim r  -> mk_rational r
                   HsDoublePrim r -> mk_rational r
                   _ -> return lit
       lit_expr <- dsLit lit'
       rep2 lit_name [lit_expr]
  where
    lit_name = case lit of
		 HsInteger _ _  -> integerLName
		 HsInt     _    -> integerLName
		 HsIntPrim _    -> intPrimLName
		 HsFloatPrim _  -> floatPrimLName
		 HsDoublePrim _ -> doublePrimLName
		 HsChar _       -> charLName
		 HsString _     -> stringLName
		 HsRat _ _      -> rationalLName
		 other 	        -> uh_oh
    uh_oh = pprPanic "DsMeta.repLiteral: trying to represent exotic literal"
		    (ppr lit)

mk_integer  i = do integer_ty <- lookupType integerTyConName
                   return $ HsInteger i integer_ty
mk_rational r = do rat_ty <- lookupType rationalTyConName
                   return $ HsRat r rat_ty

repOverloadedLiteral :: HsOverLit -> DsM (Core TH.Lit)
repOverloadedLiteral (HsIntegral i _)   = do { lit <- mk_integer  i; repLiteral lit }
repOverloadedLiteral (HsFractional f _) = do { lit <- mk_rational f; repLiteral lit }
	-- The type Rational will be in the environment, becuase 
	-- the smart constructor 'TH.Syntax.rationalL' uses it in its type,
	-- and rationalL is sucked in when any TH stuff is used
              
--------------- Miscellaneous -------------------

repGensym :: Core String -> DsM (Core (TH.Q TH.Name))
repGensym (MkC lit_str) = rep2 newNameName [lit_str]

repBindQ :: Type -> Type	-- a and b
	 -> Core (TH.Q a) -> Core (a -> TH.Q b) -> DsM (Core (TH.Q b))
repBindQ ty_a ty_b (MkC x) (MkC y) 
  = rep2 bindQName [Type ty_a, Type ty_b, x, y] 

repSequenceQ :: Type -> Core [TH.Q a] -> DsM (Core (TH.Q [a]))
repSequenceQ ty_a (MkC list)
  = rep2 sequenceQName [Type ty_a, list]

------------ Lists and Tuples -------------------
-- turn a list of patterns into a single pattern matching a list

coreList :: Name	-- Of the TyCon of the element type
	 -> [Core a] -> DsM (Core [a])
coreList tc_name es 
  = do { elt_ty <- lookupType tc_name; return (coreList' elt_ty es) }

coreList' :: Type 	-- The element type
	  -> [Core a] -> Core [a]
coreList' elt_ty es = MkC (mkListExpr elt_ty (map unC es ))

nonEmptyCoreList :: [Core a] -> Core [a]
  -- The list must be non-empty so we can get the element type
  -- Otherwise use coreList
nonEmptyCoreList [] 	      = panic "coreList: empty argument"
nonEmptyCoreList xs@(MkC x:_) = MkC (mkListExpr (exprType x) (map unC xs))

corePair :: (Core a, Core b) -> Core (a,b)
corePair (MkC x, MkC y) = MkC (mkCoreTup [x,y])

coreStringLit :: String -> DsM (Core String)
coreStringLit s = do { z <- mkStringLit s; return(MkC z) }

coreIntLit :: Int -> DsM (Core Int)
coreIntLit i = return (MkC (mkIntExpr (fromIntegral i)))

coreVar :: Id -> Core TH.Name	-- The Id has type Name
coreVar id = MkC (Var id)



-- %************************************************************************
-- %*									*
--		The known-key names for Template Haskell
-- %*									*
-- %************************************************************************

-- To add a name, do three things
-- 
--  1) Allocate a key
--  2) Make a "Name"
--  3) Add the name to knownKeyNames

templateHaskellNames :: [Name]
-- The names that are implicitly mentioned by ``bracket''
-- Should stay in sync with the import list of DsMeta

templateHaskellNames = [
    returnQName, bindQName, sequenceQName, newNameName, liftName,
    mkNameName, mkNameG_vName, mkNameG_dName, mkNameG_tcName, mkNameUName, 

    -- Lit
    charLName, stringLName, integerLName, intPrimLName,
    floatPrimLName, doublePrimLName, rationalLName,
    -- Pat
    litPName, varPName, tupPName, conPName, tildePName,
    asPName, wildPName, recPName, listPName,
    -- FieldPat
    fieldPatName,
    -- Match
    matchName,
    -- Clause
    clauseName,
    -- Exp
    varEName, conEName, litEName, appEName, infixEName,
    infixAppName, sectionLName, sectionRName, lamEName, tupEName,
    condEName, letEName, caseEName, doEName, compEName,
    fromEName, fromThenEName, fromToEName, fromThenToEName,
    listEName, sigEName, recConEName, recUpdEName,
    -- FieldExp
    fieldExpName,
    -- Body
    guardedBName, normalBName,
    -- Stmt
    bindSName, letSName, noBindSName, parSName,
    -- Dec
    funDName, valDName, dataDName, newtypeDName, tySynDName,
    classDName, instanceDName, sigDName,
    -- Cxt
    cxtName,
    -- Strict
    isStrictName, notStrictName,
    -- Con
    normalCName, recCName, infixCName,
    -- StrictType
    strictTypeName,
    -- VarStrictType
    varStrictTypeName,
    -- Type
    forallTName, varTName, conTName, appTName,
    tupleTName, arrowTName, listTName,

    -- And the tycons
    qTyConName, nameTyConName, patTyConName, fieldPatTyConName, matchQTyConName,
    clauseQTyConName, expQTyConName, fieldExpTyConName, stmtQTyConName,
    decQTyConName, conQTyConName, strictTypeQTyConName,
    varStrictTypeQTyConName, typeQTyConName, expTyConName, decTyConName,
    typeTyConName, matchTyConName, clauseTyConName]

tH_SYN_Name = mkModuleName "Language.Haskell.TH.Syntax"
tH_LIB_Name = mkModuleName "Language.Haskell.TH.Lib"

thSyn :: Module
-- NB: the TH.Syntax module comes from the "template-haskell" package
thSyn = mkModule thPackage  tH_SYN_Name
thLib = mkModule thPackage  tH_LIB_Name

mk_known_key_name mod space str uniq 
  = mkExternalName uniq mod (mkOccFS space str) 
	           Nothing noSrcLoc

libFun = mk_known_key_name thLib OccName.varName
libTc  = mk_known_key_name thLib OccName.tcName
thFun  = mk_known_key_name thSyn OccName.varName
thTc   = mk_known_key_name thSyn OccName.tcName

-------------------- TH.Syntax -----------------------
qTyConName        = thTc FSLIT("Q")             qTyConKey
nameTyConName      = thTc FSLIT("Name")           nameTyConKey
fieldExpTyConName = thTc FSLIT("FieldExp")      fieldExpTyConKey
patTyConName      = thTc FSLIT("Pat")           patTyConKey
fieldPatTyConName = thTc FSLIT("FieldPat")      fieldPatTyConKey
expTyConName      = thTc  FSLIT("Exp")          expTyConKey
decTyConName      = thTc  FSLIT("Dec")          decTyConKey
typeTyConName     = thTc  FSLIT("Type")         typeTyConKey
matchTyConName    = thTc  FSLIT("Match")        matchTyConKey
clauseTyConName   = thTc  FSLIT("Clause")       clauseTyConKey

returnQName   = thFun FSLIT("returnQ")   returnQIdKey
bindQName     = thFun FSLIT("bindQ")     bindQIdKey
sequenceQName = thFun FSLIT("sequenceQ") sequenceQIdKey
newNameName    = thFun FSLIT("newName")   newNameIdKey
liftName      = thFun FSLIT("lift")      liftIdKey
mkNameName     = thFun FSLIT("mkName")     mkNameIdKey
mkNameG_vName  = thFun FSLIT("mkNameG_v")  mkNameG_vIdKey
mkNameG_dName  = thFun FSLIT("mkNameG_d")  mkNameG_dIdKey
mkNameG_tcName = thFun FSLIT("mkNameG_tc") mkNameG_tcIdKey
mkNameUName    = thFun FSLIT("mkNameU")    mkNameUIdKey


-------------------- TH.Lib -----------------------
-- data Lit = ...
charLName       = libFun FSLIT("charL")       charLIdKey
stringLName     = libFun FSLIT("stringL")     stringLIdKey
integerLName    = libFun FSLIT("integerL")    integerLIdKey
intPrimLName    = libFun FSLIT("intPrimL")    intPrimLIdKey
floatPrimLName  = libFun FSLIT("floatPrimL")  floatPrimLIdKey
doublePrimLName = libFun FSLIT("doublePrimL") doublePrimLIdKey
rationalLName   = libFun FSLIT("rationalL")     rationalLIdKey

-- data Pat = ...
litPName   = libFun FSLIT("litP")   litPIdKey
varPName   = libFun FSLIT("varP")   varPIdKey
tupPName   = libFun FSLIT("tupP")   tupPIdKey
conPName   = libFun FSLIT("conP")   conPIdKey
tildePName = libFun FSLIT("tildeP") tildePIdKey
asPName    = libFun FSLIT("asP")    asPIdKey
wildPName  = libFun FSLIT("wildP")  wildPIdKey
recPName   = libFun FSLIT("recP")   recPIdKey
listPName  = libFun FSLIT("listP")  listPIdKey

-- type FieldPat = ...
fieldPatName = libFun FSLIT("fieldPat") fieldPatIdKey

-- data Match = ...
matchName = libFun FSLIT("match") matchIdKey

-- data Clause = ...	 
clauseName = libFun FSLIT("clause") clauseIdKey

-- data Exp = ...
varEName        = libFun FSLIT("varE")        varEIdKey
conEName        = libFun FSLIT("conE")        conEIdKey
litEName        = libFun FSLIT("litE")        litEIdKey
appEName        = libFun FSLIT("appE")        appEIdKey
infixEName      = libFun FSLIT("infixE")      infixEIdKey
infixAppName    = libFun FSLIT("infixApp")    infixAppIdKey
sectionLName    = libFun FSLIT("sectionL")    sectionLIdKey
sectionRName    = libFun FSLIT("sectionR")    sectionRIdKey
lamEName        = libFun FSLIT("lamE")        lamEIdKey
tupEName        = libFun FSLIT("tupE")        tupEIdKey
condEName       = libFun FSLIT("condE")       condEIdKey
letEName        = libFun FSLIT("letE")        letEIdKey
caseEName       = libFun FSLIT("caseE")       caseEIdKey
doEName         = libFun FSLIT("doE")         doEIdKey
compEName       = libFun FSLIT("compE")       compEIdKey
-- ArithSeq skips a level
fromEName       = libFun FSLIT("fromE")       fromEIdKey
fromThenEName   = libFun FSLIT("fromThenE")   fromThenEIdKey
fromToEName     = libFun FSLIT("fromToE")     fromToEIdKey
fromThenToEName = libFun FSLIT("fromThenToE") fromThenToEIdKey
-- end ArithSeq
listEName       = libFun FSLIT("listE")       listEIdKey
sigEName        = libFun FSLIT("sigE")        sigEIdKey
recConEName     = libFun FSLIT("recConE")     recConEIdKey
recUpdEName     = libFun FSLIT("recUpdE")     recUpdEIdKey

-- type FieldExp = ...
fieldExpName = libFun FSLIT("fieldExp") fieldExpIdKey

-- data Body = ...
guardedBName = libFun FSLIT("guardedB") guardedBIdKey
normalBName  = libFun FSLIT("normalB")  normalBIdKey

-- data Stmt = ...
bindSName   = libFun FSLIT("bindS")   bindSIdKey
letSName    = libFun FSLIT("letS")    letSIdKey
noBindSName = libFun FSLIT("noBindS") noBindSIdKey
parSName    = libFun FSLIT("parS")    parSIdKey

-- data Dec = ...
funDName      = libFun FSLIT("funD")      funDIdKey
valDName      = libFun FSLIT("valD")      valDIdKey
dataDName     = libFun FSLIT("dataD")     dataDIdKey
newtypeDName  = libFun FSLIT("newtypeD")  newtypeDIdKey
tySynDName    = libFun FSLIT("tySynD")    tySynDIdKey
classDName    = libFun FSLIT("classD")    classDIdKey
instanceDName = libFun FSLIT("instanceD") instanceDIdKey
sigDName      = libFun FSLIT("sigD")      sigDIdKey

-- type Ctxt = ...
cxtName = libFun FSLIT("cxt") cxtIdKey

-- data Strict = ...
isStrictName      = libFun  FSLIT("isStrict")      isStrictKey
notStrictName     = libFun  FSLIT("notStrict")     notStrictKey

-- data Con = ...	 
normalCName = libFun FSLIT("normalC") normalCIdKey
recCName    = libFun FSLIT("recC")    recCIdKey
infixCName  = libFun FSLIT("infixC")  infixCIdKey
			 
-- type StrictType = ...
strictTypeName    = libFun  FSLIT("strictType")    strictTKey

-- type VarStrictType = ...
varStrictTypeName = libFun  FSLIT("varStrictType") varStrictTKey

-- data Type = ...
forallTName = libFun FSLIT("forallT") forallTIdKey
varTName    = libFun FSLIT("varT")    varTIdKey
conTName    = libFun FSLIT("conT")    conTIdKey
tupleTName  = libFun FSLIT("tupleT") tupleTIdKey
arrowTName  = libFun FSLIT("arrowT") arrowTIdKey
listTName   = libFun FSLIT("listT")  listTIdKey
appTName    = libFun FSLIT("appT")    appTIdKey
			 
matchQTyConName         = libTc FSLIT("MatchQ")        matchQTyConKey
clauseQTyConName        = libTc FSLIT("ClauseQ")       clauseQTyConKey
expQTyConName           = libTc FSLIT("ExpQ")          expQTyConKey
stmtQTyConName          = libTc FSLIT("StmtQ")         stmtQTyConKey
decQTyConName           = libTc FSLIT("DecQ")          decQTyConKey
conQTyConName           = libTc FSLIT("ConQ")          conQTyConKey
strictTypeQTyConName    = libTc FSLIT("StrictTypeQ")    strictTypeQTyConKey
varStrictTypeQTyConName = libTc FSLIT("VarStrictTypeQ") varStrictTypeQTyConKey
typeQTyConName          = libTc FSLIT("TypeQ")          typeQTyConKey

--	TyConUniques available: 100-119
-- 	Check in PrelNames if you want to change this

expTyConKey             = mkPreludeTyConUnique 100
matchTyConKey           = mkPreludeTyConUnique 101
clauseTyConKey          = mkPreludeTyConUnique 102
qTyConKey               = mkPreludeTyConUnique 103
expQTyConKey            = mkPreludeTyConUnique 104
decQTyConKey            = mkPreludeTyConUnique 105
patTyConKey             = mkPreludeTyConUnique 106
matchQTyConKey          = mkPreludeTyConUnique 107
clauseQTyConKey         = mkPreludeTyConUnique 108
stmtQTyConKey           = mkPreludeTyConUnique 109
conQTyConKey            = mkPreludeTyConUnique 110
typeQTyConKey           = mkPreludeTyConUnique 111
typeTyConKey            = mkPreludeTyConUnique 112
decTyConKey             = mkPreludeTyConUnique 113
varStrictTypeQTyConKey  = mkPreludeTyConUnique 114
strictTypeQTyConKey     = mkPreludeTyConUnique 115
fieldExpTyConKey        = mkPreludeTyConUnique 116
fieldPatTyConKey        = mkPreludeTyConUnique 117
nameTyConKey             = mkPreludeTyConUnique 118

-- 	IdUniques available: 200-299
-- 	If you want to change this, make sure you check in PrelNames

returnQIdKey        = mkPreludeMiscIdUnique 200
bindQIdKey          = mkPreludeMiscIdUnique 201
sequenceQIdKey      = mkPreludeMiscIdUnique 202
liftIdKey           = mkPreludeMiscIdUnique 203
newNameIdKey         = mkPreludeMiscIdUnique 204
mkNameIdKey          = mkPreludeMiscIdUnique 205
mkNameG_vIdKey       = mkPreludeMiscIdUnique 206
mkNameG_dIdKey       = mkPreludeMiscIdUnique 207
mkNameG_tcIdKey      = mkPreludeMiscIdUnique 208
mkNameUIdKey         = mkPreludeMiscIdUnique 209


-- data Lit = ...
charLIdKey        = mkPreludeMiscIdUnique 210
stringLIdKey      = mkPreludeMiscIdUnique 211
integerLIdKey     = mkPreludeMiscIdUnique 212
intPrimLIdKey     = mkPreludeMiscIdUnique 213
floatPrimLIdKey   = mkPreludeMiscIdUnique 214
doublePrimLIdKey  = mkPreludeMiscIdUnique 215
rationalLIdKey    = mkPreludeMiscIdUnique 216

-- data Pat = ...
litPIdKey         = mkPreludeMiscIdUnique 220
varPIdKey         = mkPreludeMiscIdUnique 221
tupPIdKey         = mkPreludeMiscIdUnique 222
conPIdKey         = mkPreludeMiscIdUnique 223
tildePIdKey       = mkPreludeMiscIdUnique 224
asPIdKey          = mkPreludeMiscIdUnique 225
wildPIdKey        = mkPreludeMiscIdUnique 226
recPIdKey         = mkPreludeMiscIdUnique 227
listPIdKey        = mkPreludeMiscIdUnique 228

-- type FieldPat = ...
fieldPatIdKey       = mkPreludeMiscIdUnique 230

-- data Match = ...
matchIdKey          = mkPreludeMiscIdUnique 231

-- data Clause = ...
clauseIdKey         = mkPreludeMiscIdUnique 232

-- data Exp = ...
varEIdKey         = mkPreludeMiscIdUnique 240
conEIdKey         = mkPreludeMiscIdUnique 241
litEIdKey         = mkPreludeMiscIdUnique 242
appEIdKey         = mkPreludeMiscIdUnique 243
infixEIdKey       = mkPreludeMiscIdUnique 244
infixAppIdKey       = mkPreludeMiscIdUnique 245
sectionLIdKey       = mkPreludeMiscIdUnique 246
sectionRIdKey       = mkPreludeMiscIdUnique 247
lamEIdKey         = mkPreludeMiscIdUnique 248
tupEIdKey         = mkPreludeMiscIdUnique 249
condEIdKey        = mkPreludeMiscIdUnique 250
letEIdKey         = mkPreludeMiscIdUnique 251
caseEIdKey        = mkPreludeMiscIdUnique 252
doEIdKey          = mkPreludeMiscIdUnique 253
compEIdKey        = mkPreludeMiscIdUnique 254
fromEIdKey        = mkPreludeMiscIdUnique 255
fromThenEIdKey    = mkPreludeMiscIdUnique 256
fromToEIdKey      = mkPreludeMiscIdUnique 257
fromThenToEIdKey  = mkPreludeMiscIdUnique 258
listEIdKey        = mkPreludeMiscIdUnique 259
sigEIdKey         = mkPreludeMiscIdUnique 260
recConEIdKey      = mkPreludeMiscIdUnique 261
recUpdEIdKey      = mkPreludeMiscIdUnique 262

-- type FieldExp = ...
fieldExpIdKey       = mkPreludeMiscIdUnique 265

-- data Body = ...
guardedBIdKey     = mkPreludeMiscIdUnique 266
normalBIdKey      = mkPreludeMiscIdUnique 267

-- data Stmt = ...
bindSIdKey       = mkPreludeMiscIdUnique 268
letSIdKey        = mkPreludeMiscIdUnique 269
noBindSIdKey     = mkPreludeMiscIdUnique 270
parSIdKey        = mkPreludeMiscIdUnique 271

-- data Dec = ...
funDIdKey         = mkPreludeMiscIdUnique 272
valDIdKey         = mkPreludeMiscIdUnique 273
dataDIdKey        = mkPreludeMiscIdUnique 274
newtypeDIdKey     = mkPreludeMiscIdUnique 275
tySynDIdKey       = mkPreludeMiscIdUnique 276
classDIdKey       = mkPreludeMiscIdUnique 277
instanceDIdKey    = mkPreludeMiscIdUnique 278
sigDIdKey         = mkPreludeMiscIdUnique 279

-- type Cxt = ...
cxtIdKey            = mkPreludeMiscIdUnique 280

-- data Strict = ...
isStrictKey         = mkPreludeMiscIdUnique 281
notStrictKey        = mkPreludeMiscIdUnique 282

-- data Con = ...
normalCIdKey      = mkPreludeMiscIdUnique 283
recCIdKey         = mkPreludeMiscIdUnique 284
infixCIdKey       = mkPreludeMiscIdUnique 285

-- type StrictType = ...
strictTKey        = mkPreludeMiscIdUnique 2286

-- type VarStrictType = ...
varStrictTKey     = mkPreludeMiscIdUnique 287

-- data Type = ...
forallTIdKey      = mkPreludeMiscIdUnique 290
varTIdKey         = mkPreludeMiscIdUnique 291
conTIdKey         = mkPreludeMiscIdUnique 292
tupleTIdKey       = mkPreludeMiscIdUnique 294
arrowTIdKey       = mkPreludeMiscIdUnique 295
listTIdKey        = mkPreludeMiscIdUnique 296
appTIdKey         = mkPreludeMiscIdUnique 293
