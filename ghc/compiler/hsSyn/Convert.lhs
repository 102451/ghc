%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

This module converts Template Haskell syntax into HsSyn


\begin{code}
module Convert( convertToHsExpr, convertToHsDecls, convertToHsType ) where

#include "HsVersions.h"

import Language.Haskell.TH as TH hiding (sigP)
import Language.Haskell.TH.Syntax as TH

import HsSyn as Hs
import RdrName	( RdrName, mkRdrUnqual, mkRdrQual, mkOrig, nameRdrName, getRdrName )
import Module   ( ModuleName, mkModuleName )
import RdrHsSyn	( mkHsIntegral, mkHsFractional, mkClassDecl, mkTyData )
import Name	( mkInternalName )
import qualified OccName
import SrcLoc	( SrcLoc, generatedSrcLoc, noLoc, unLoc, Located(..),
		  noSrcSpan, SrcSpan, srcLocSpan, noSrcLoc )
import Type	( Type )
import TysWiredIn ( unitTyCon, tupleTyCon, trueDataCon, falseDataCon )
import BasicTypes( Boxity(..), RecFlag(Recursive) )
import ForeignCall ( Safety(..), CCallConv(..), CCallTarget(..),
                     CExportSpec(..)) 
import HsDecls ( CImportSpec(..), ForeignImport(..), ForeignExport(..),
                 ForeignDecl(..) )
import FastString( FastString, mkFastString, nilFS )
import Char 	( ord, isAscii, isAlphaNum, isAlpha )
import List	( partition )
import Unique	( Unique, mkUniqueGrimily )
import ErrUtils (Message)
import GLAEXTS	( Int#, Int(..) )
import Bag	( emptyBag, consBag )
import Outputable


-------------------------------------------------------------------
convertToHsDecls :: [TH.Dec] -> [Either (LHsDecl RdrName) Message]
convertToHsDecls ds = map cvt_ltop ds

mk_con con = L loc0 $ case con of
	NormalC c strtys
	 -> ConDecl (noLoc (cName c)) noExistentials noContext
		  (PrefixCon (map mk_arg strtys))
	RecC c varstrtys
	 -> ConDecl (noLoc (cName c)) noExistentials noContext
		  (RecCon (map mk_id_arg varstrtys))
	InfixC st1 c st2
	 -> ConDecl (noLoc (cName c)) noExistentials noContext
		  (InfixCon (mk_arg st1) (mk_arg st2))
  where
    mk_arg (IsStrict, ty)  = noLoc $ HsBangTy HsStrict (cvtType ty)
    mk_arg (NotStrict, ty) = cvtType ty

    mk_id_arg (i, IsStrict, ty)
        = (noLoc (vName i), noLoc $ HsBangTy HsStrict (cvtType ty))
    mk_id_arg (i, NotStrict, ty)
        = (noLoc (vName i), cvtType ty)

mk_derivs [] = Nothing
mk_derivs cs = Just [noLoc $ HsPredTy $ HsClassP (tconName c) [] | c <- cs]

cvt_ltop  :: TH.Dec -> Either (LHsDecl RdrName) Message
cvt_ltop d = case cvt_top d of
		Left d -> Left (L loc0 d)
		Right m -> Right m

cvt_top :: TH.Dec -> Either (HsDecl RdrName) Message
cvt_top d@(TH.ValD _ _ _) = Left $ Hs.ValD (unLoc (cvtd d))
cvt_top d@(TH.FunD _ _)   = Left $ Hs.ValD (unLoc (cvtd d))
 
cvt_top (TySynD tc tvs rhs)
  = Left $ TyClD (TySynonym (noLoc (tconName tc)) (cvt_tvs tvs) (cvtType rhs))

cvt_top (DataD ctxt tc tvs constrs derivs)
  = Left $ TyClD (mkTyData DataType 
                           (noLoc (cvt_context ctxt, noLoc (tconName tc), cvt_tvs tvs))
                           Nothing (map mk_con constrs)
                           (mk_derivs derivs))

cvt_top (NewtypeD ctxt tc tvs constr derivs)
  = Left $ TyClD (mkTyData NewType 
                           (noLoc (cvt_context ctxt, noLoc (tconName tc), cvt_tvs tvs))
                           Nothing [mk_con constr]
                           (mk_derivs derivs))

cvt_top (ClassD ctxt cl tvs decs)
  = Left $ TyClD (mkClassDecl (cvt_context ctxt, noLoc (tconName cl), cvt_tvs tvs)
                              noFunDeps sigs
			      binds)
  where
    (binds,sigs) = cvtBindsAndSigs decs

cvt_top (InstanceD tys ty decs)
  = Left $ InstD (InstDecl (noLoc inst_ty) binds sigs)
  where
    (binds, sigs) = cvtBindsAndSigs decs
    inst_ty = mkImplicitHsForAllTy (cvt_context tys) (noLoc (HsPredTy (cvt_pred ty)))

cvt_top (TH.SigD nm typ) = Left $ Hs.SigD (Sig (noLoc (vName nm)) (cvtType typ))

cvt_top (ForeignD (ImportF callconv safety from nm typ))
 = case parsed of
       Just (c_header, cis) ->
           let i = CImport callconv' safety' c_header nilFS cis
           in Left $ ForD (ForeignImport (noLoc (vName nm)) (cvtType typ) i False)
       Nothing -> Right $     text (show from)
                          <+> ptext SLIT("is not a valid ccall impent")
    where callconv' = case callconv of
                          CCall -> CCallConv
                          StdCall -> StdCallConv
          safety' = case safety of
                        Unsafe     -> PlayRisky
                        Safe       -> PlaySafe False
                        Threadsafe -> PlaySafe True
          parsed = parse_ccall_impent (TH.nameBase nm) from

cvt_top (ForeignD (ExportF callconv as nm typ))
 = let e = CExport (CExportStatic (mkFastString as) callconv')
   in Left $ ForD (ForeignExport (noLoc (vName nm)) (cvtType typ) e False)
    where callconv' = case callconv of
                          CCall -> CCallConv
                          StdCall -> StdCallConv

parse_ccall_impent :: String -> String -> Maybe (FastString, CImportSpec)
parse_ccall_impent nm s
 = case lex_ccall_impent s of
       Just ["dynamic"] -> Just (nilFS, CFunction DynamicTarget)
       Just ["wrapper"] -> Just (nilFS, CWrapper)
       Just ("static":ts) -> parse_ccall_impent_static nm ts
       Just ts -> parse_ccall_impent_static nm ts
       Nothing -> Nothing

parse_ccall_impent_static :: String
                          -> [String]
                          -> Maybe (FastString, CImportSpec)
parse_ccall_impent_static nm ts
 = let ts' = case ts of
                 [       "&", cid] -> [       cid]
                 [fname, "&"     ] -> [fname     ]
                 [fname, "&", cid] -> [fname, cid]
                 _                 -> ts
   in case ts' of
          [       cid] | is_cid cid -> Just (nilFS,              mk_cid cid)
          [fname, cid] | is_cid cid -> Just (mkFastString fname, mk_cid cid)
          [          ]              -> Just (nilFS,              mk_cid nm)
          [fname     ]              -> Just (mkFastString fname, mk_cid nm)
          _                         -> Nothing
    where is_cid :: String -> Bool
          is_cid x = all (/= '.') x && (isAlpha (head x) || head x == '_')
          mk_cid :: String -> CImportSpec
          mk_cid  = CFunction . StaticTarget . mkFastString

lex_ccall_impent :: String -> Maybe [String]
lex_ccall_impent "" = Just []
lex_ccall_impent ('&':xs) = fmap ("&":) $ lex_ccall_impent xs
lex_ccall_impent (' ':xs) = lex_ccall_impent xs
lex_ccall_impent ('\t':xs) = lex_ccall_impent xs
lex_ccall_impent xs = case span is_valid xs of
                          ("", _) -> Nothing
                          (t, xs') -> fmap (t:) $ lex_ccall_impent xs'
    where is_valid :: Char -> Bool
          is_valid c = isAscii c && (isAlphaNum c || c `elem` "._")

noContext      = noLoc []
noExistentials = []
noFunDeps      = []

-------------------------------------------------------------------
convertToHsExpr :: TH.Exp -> LHsExpr RdrName
convertToHsExpr = cvtl

cvtl e = noLoc (cvt e)

cvt (VarE s) 	  = HsVar (vName s)
cvt (ConE s) 	  = HsVar (cName s)
cvt (LitE l) 
  | overloadedLit l = HsOverLit (cvtOverLit l)
  | otherwise	    = HsLit (cvtLit l)

cvt (AppE x y)     = HsApp (cvtl x) (cvtl y)
cvt (LamE ps e)    = HsLam (mkMatchGroup [mkSimpleMatch (map cvtlp ps) (cvtl e)])
cvt (TupE [e])	  = cvt e
cvt (TupE es)	  = ExplicitTuple(map cvtl es) Boxed
cvt (CondE x y z)  = HsIf (cvtl x) (cvtl y) (cvtl z)
cvt (LetE ds e)	  = HsLet (cvtdecs ds) (cvtl e)
cvt (CaseE e ms)   = HsCase (cvtl e) (mkMatchGroup (map cvtm ms))
cvt (DoE ss)	  = HsDo DoExpr (cvtstmts ss) [] void
cvt (CompE ss)     = HsDo ListComp (cvtstmts ss) [] void
cvt (ArithSeqE dd) = ArithSeqIn (cvtdd dd)
cvt (ListE xs)  = ExplicitList void (map cvtl xs)
cvt (InfixE (Just x) s (Just y))
    = HsPar (noLoc $ OpApp (cvtl x) (cvtl s) undefined (cvtl y))
cvt (InfixE Nothing  s (Just y)) = SectionR (cvtl s) (cvtl y)
cvt (InfixE (Just x) s Nothing ) = SectionL (cvtl x) (cvtl s)
cvt (InfixE Nothing  s Nothing ) = cvt s	-- Can I indicate this is an infix thing?
cvt (SigE e t)		= ExprWithTySig (cvtl e) (cvtType t)
cvt (RecConE c flds) = RecordCon (noLoc (cName c)) (map (\(x,y) -> (noLoc (vName x), cvtl y)) flds)
cvt (RecUpdE e flds) = RecordUpd (cvtl e) (map (\(x,y) -> (noLoc (vName x), cvtl y)) flds)

cvtdecs :: [TH.Dec] -> [HsBindGroup RdrName]
cvtdecs [] = []
cvtdecs ds = [HsBindGroup binds sigs Recursive]
	   where
	     (binds, sigs) = cvtBindsAndSigs ds

cvtBindsAndSigs ds 
  = (cvtds non_sigs, map cvtSig sigs)
  where 
    (sigs, non_sigs) = partition sigP ds

cvtSig (TH.SigD nm typ) = noLoc (Hs.Sig (noLoc (vName nm)) (cvtType typ))

cvtds :: [TH.Dec] -> LHsBinds RdrName
cvtds []     = emptyBag
cvtds (d:ds) = cvtd d `consBag` cvtds ds

cvtd :: TH.Dec -> LHsBind RdrName
-- Used only for declarations in a 'let/where' clause,
-- not for top level decls
cvtd (TH.ValD (TH.VarP s) body ds) 
  = noLoc $ FunBind (noLoc (vName s)) False (mkMatchGroup [cvtclause (Clause [] body ds)])
cvtd (FunD nm cls)
  = noLoc $ FunBind (noLoc (vName nm)) False (mkMatchGroup (map cvtclause cls))
cvtd (TH.ValD p body ds)
  = noLoc $ PatBind (cvtlp p) (GRHSs (cvtguard body) (cvtdecs ds)) void

cvtd d = cvtPanic "Illegal kind of declaration in where clause" 
		  (text (TH.pprint d))


cvtclause :: TH.Clause -> Hs.LMatch RdrName
cvtclause (Clause ps body wheres)
    = noLoc $ Hs.Match (map cvtlp ps) Nothing (GRHSs (cvtguard body) (cvtdecs wheres))



cvtdd :: Range -> ArithSeqInfo RdrName
cvtdd (FromR x) 	      = (From (cvtl x))
cvtdd (FromThenR x y)     = (FromThen (cvtl x) (cvtl y))
cvtdd (FromToR x y)	      = (FromTo (cvtl x) (cvtl y))
cvtdd (FromThenToR x y z) = (FromThenTo (cvtl x) (cvtl y) (cvtl z))


cvtstmts :: [TH.Stmt] -> [Hs.LStmt RdrName]
cvtstmts []		       = [] -- this is probably an error as every [stmt] should end with ResultStmt
cvtstmts [NoBindS e]           = [nlResultStmt (cvtl e)]      -- when its the last element use ResultStmt
cvtstmts (NoBindS e : ss)      = nlExprStmt (cvtl e)     : cvtstmts ss
cvtstmts (TH.BindS p e : ss) = nlBindStmt (cvtlp p) (cvtl e) : cvtstmts ss
cvtstmts (TH.LetS ds : ss)   = nlLetStmt (cvtdecs ds)	    : cvtstmts ss
cvtstmts (TH.ParS dss : ss)  = nlParStmt [(cvtstmts ds, undefined) | ds <- dss] : cvtstmts ss

cvtm :: TH.Match -> Hs.LMatch RdrName
cvtm (TH.Match p body wheres)
    = noLoc (Hs.Match [cvtlp p] Nothing (GRHSs (cvtguard body) (cvtdecs wheres)))

cvtguard :: TH.Body -> [LGRHS RdrName]
cvtguard (GuardedB pairs) = map cvtpair pairs
cvtguard (NormalB e) 	 = [noLoc (GRHS [  nlResultStmt (cvtl e) ])]

cvtpair :: (TH.Guard,TH.Exp) -> LGRHS RdrName
cvtpair (NormalG x,y) = noLoc (GRHS [nlBindStmt truePat (cvtl x),
                               nlResultStmt (cvtl y)])
cvtpair (PatG x,y) = noLoc (GRHS (cvtstmts x ++ [nlResultStmt (cvtl y)]))

cvtOverLit :: Lit -> HsOverLit
cvtOverLit (IntegerL i)  = mkHsIntegral i
cvtOverLit (RationalL r) = mkHsFractional r
-- An Integer is like an an (overloaded) '3' in a Haskell source program
-- Similarly 3.5 for fractionals

cvtLit :: Lit -> HsLit
cvtLit (IntPrimL i)    = HsIntPrim i
cvtLit (FloatPrimL f)  = HsFloatPrim f
cvtLit (DoublePrimL f) = HsDoublePrim f
cvtLit (CharL c)       = HsChar c
cvtLit (StringL s)     = HsString (mkFastString s)

cvtlp :: TH.Pat -> Hs.LPat RdrName
cvtlp pat = noLoc (cvtp pat)

cvtp :: TH.Pat -> Hs.Pat RdrName
cvtp (TH.LitP l)
  | overloadedLit l = NPatIn (cvtOverLit l) Nothing	-- Not right for negative
							-- patterns; need to think
							-- about that!
  | otherwise	    = Hs.LitPat (cvtLit l)
cvtp (TH.VarP s)     = Hs.VarPat(vName s)
cvtp (TupP [p])   = cvtp p
cvtp (TupP ps)    = TuplePat (map cvtlp ps) Boxed
cvtp (ConP s ps)  = ConPatIn (noLoc (cName s)) (PrefixCon (map cvtlp ps))
cvtp (InfixP p1 s p2)
                  = ConPatIn (noLoc (cName s)) (InfixCon (cvtlp p1) (cvtlp p2))
cvtp (TildeP p)   = LazyPat (cvtlp p)
cvtp (TH.AsP s p) = AsPat (noLoc (vName s)) (cvtlp p)
cvtp TH.WildP   = WildPat void
cvtp (RecP c fs)  = ConPatIn (noLoc (cName c)) $ Hs.RecCon (map (\(s,p) -> (noLoc (vName s),cvtlp p)) fs)
cvtp (ListP ps)   = ListPat (map cvtlp ps) void
cvtp (SigP p t)   = SigPatIn (cvtlp p) (cvtType t)

-----------------------------------------------------------
--	Types and type variables

cvt_tvs :: [TH.Name] -> [LHsTyVarBndr RdrName]
cvt_tvs tvs = map (noLoc . UserTyVar . tName) tvs

cvt_context :: Cxt -> LHsContext RdrName 
cvt_context tys = noLoc (map (noLoc . cvt_pred) tys)

cvt_pred :: TH.Type -> HsPred RdrName
cvt_pred ty = case split_ty_app ty of
	   	(ConT tc, tys) -> HsClassP (tconName tc) (map cvtType tys)
	   	(VarT tv, tys) -> HsClassP (tName tv) (map cvtType tys)
		other -> cvtPanic "Malformed predicate" (text (TH.pprint ty))

convertToHsType = cvtType

cvtType :: TH.Type -> LHsType RdrName
cvtType ty = trans (root ty [])
  where root (AppT a b) zs = root a (cvtType b : zs)
        root t zs 	   = (t,zs)

        trans (TupleT n,args)
            | length args == n = noLoc (HsTupleTy Boxed args)
            | n == 0    = foldl nlHsAppTy (nlHsTyVar (getRdrName unitTyCon))	    args
            | otherwise = foldl nlHsAppTy (nlHsTyVar (getRdrName (tupleTyCon Boxed n))) args
        trans (ArrowT,   [x,y]) = nlHsFunTy x y
        trans (ListT,    [x])   = noLoc (HsListTy x)

	trans (VarT nm, args)	    = foldl nlHsAppTy (nlHsTyVar (tName nm))    args
        trans (ConT tc, args)       = foldl nlHsAppTy (nlHsTyVar (tconName tc)) args

	trans (ForallT tvs cxt ty, []) = noLoc $ mkExplicitHsForAllTy 
						(cvt_tvs tvs) (cvt_context cxt) (cvtType ty)

split_ty_app :: TH.Type -> (TH.Type, [TH.Type])
split_ty_app ty = go ty []
  where
    go (AppT f a) as = go f (a:as)
    go f as 	     = (f,as)

-----------------------------------------------------------
sigP :: Dec -> Bool
sigP (TH.SigD _ _) = True
sigP other	 = False


-----------------------------------------------------------
cvtPanic :: String -> SDoc -> b
cvtPanic herald thing
  = pprPanic herald (thing $$ ptext SLIT("When splicing generated code into the program"))

-----------------------------------------------------------
-- some useful things

truePat  = nlConPat (getRdrName trueDataCon)  []
falsePat = nlConPat (getRdrName falseDataCon) []

overloadedLit :: Lit -> Bool
-- True for literals that Haskell treats as overloaded
overloadedLit (IntegerL  l) = True
overloadedLit (RationalL l) = True
overloadedLit l	            = False

void :: Type.Type
void = placeHolderType

loc0 :: SrcSpan
loc0 = srcLocSpan generatedSrcLoc

--------------------------------------------------------------------
--	Turning Name back into RdrName
--------------------------------------------------------------------

-- variable names
vName :: TH.Name -> RdrName
vName = thRdrName OccName.varName

-- Constructor function names; this is Haskell source, hence srcDataName
cName :: TH.Name -> RdrName
cName = thRdrName OccName.srcDataName

-- Type variable names
tName :: TH.Name -> RdrName
tName = thRdrName OccName.tvName

-- Type Constructor names
tconName = thRdrName OccName.tcName

thRdrName :: OccName.NameSpace -> TH.Name -> RdrName
-- This turns a Name into a RdrName
-- The last case is slightly interesting.  It constructs a
-- unique name from the unique in the TH thingy, so that the renamer
-- won't mess about.  I hope.  (Another possiblity would be to generate 
-- "x_77" etc, but that could conceivably clash.)

thRdrName ns (TH.Name occ (TH.NameG ns' mod))  = mkOrig (mk_mod mod) (mk_occ ns occ)
thRdrName ns (TH.Name occ TH.NameS)            = mkDynName ns occ
thRdrName ns (TH.Name occ (TH.NameU uniq))     = nameRdrName (mkInternalName (mk_uniq uniq) (mk_occ ns occ) noSrcLoc)

mk_uniq :: Int# -> Unique
mk_uniq u = mkUniqueGrimily (I# u)

-- The packing and unpacking is rather turgid :-(
mk_occ :: OccName.NameSpace -> TH.OccName -> OccName.OccName
mk_occ ns occ = OccName.mkOccFS ns (mkFastString (TH.occString occ))

mk_mod :: TH.ModName -> ModuleName
mk_mod mod = mkModuleName (TH.modString mod)

mkDynName :: OccName.NameSpace -> TH.OccName -> RdrName
-- Parse the string to see if it has a "." in it
-- so we know whether to generate a qualified or unqualified name
-- It's a bit tricky because we need to parse 
--	Foo.Baz.x as Qual Foo.Baz x
-- So we parse it from back to front

mkDynName ns th_occ
  = split [] (reverse (TH.occString th_occ))
  where
    split occ []        = mkRdrUnqual (mk_occ occ)
    split occ ('.':rev)	= mkRdrQual (mk_mod (reverse rev)) (mk_occ occ)
    split occ (c:rev)   = split (c:occ) rev

    mk_occ occ = OccName.mkOccFS ns (mkFastString occ)
    mk_mod mod = mkModuleName mod
\end{code}

