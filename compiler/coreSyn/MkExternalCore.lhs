
% (c) The University of Glasgow 2001-2006
%
\begin{code}
module MkExternalCore (
	emitExternalCore
) where

#include "HsVersions.h"

import qualified ExternalCore as C
import Module
import CoreSyn
import HscTypes	
import TyCon
import TypeRep
import Type
import PprExternalCore () -- Instances
import DataCon
import Coercion
import Var
import IdInfo
import Literal
import Name
import NameSet
import UniqSet
import Outputable
import Encoding
import ForeignCall
import DynFlags
import StaticFlags
import IO
import FastString

import Data.Char

emitExternalCore :: DynFlags -> NameSet -> CgGuts -> IO ()
emitExternalCore dflags exports cg_guts
 | opt_EmitExternalCore 
 = (do handle <- openFile corename WriteMode
       hPutStrLn handle (show (mkExternalCore exports cg_guts))      
       hClose handle)
   `catch` (\_ -> pprPanic "Failed to open or write external core output file"
                           (text corename))
   where corename = extCoreName dflags
emitExternalCore _ _ _
 | otherwise
 = return ()


mkExternalCore :: NameSet -> CgGuts -> C.Module
-- The ModGuts has been tidied, but the implicit bindings have
-- not been injected, so we have to add them manually here
-- We don't include the strange data-con *workers* because they are
-- implicit in the data type declaration itself
mkExternalCore exports (CgGuts {cg_module=this_mod, cg_tycons = tycons, cg_binds = binds})
  = C.Module mname tdefs (map (make_vdef exports) binds)
  where
    mname  = make_mid this_mod
    tdefs  = foldr collect_tdefs [] tycons

collect_tdefs :: TyCon -> [C.Tdef] -> [C.Tdef]
collect_tdefs tcon tdefs 
  | isAlgTyCon tcon = tdef: tdefs
  where
    tdef | isNewTyCon tcon = 
                C.Newtype (qtc tcon) (map make_tbind tyvars) 
                  (case newTyConCo_maybe tcon of
                     Just coercion -> (qtc coercion, 
                       make_kind $ (uncurry mkCoKind) $  
                                  case isCoercionTyCon_maybe coercion of
                                    -- See Note [Newtype coercions] in 
                                    -- types/TyCon
                                    Just (arity,coKindFun) -> coKindFun $
                                       map mkTyVarTy $ take arity tyvars
                                    Nothing -> pprPanic ("MkExternalCore:\
                                      coercion tcon should have a kind fun")
                                        (ppr tcon))
                     Nothing       -> pprPanic ("MkExternalCore: newtype tcon\
                                       should have a coercion: ") (ppr tcon))
                   repclause 
         | otherwise = 
                C.Data (qtc tcon) (map make_tbind tyvars) (map make_cdef (tyConDataCons tcon)) 
         where repclause | isRecursiveTyCon tcon || isOpenTyCon tcon= Nothing
		         | otherwise = Just (make_ty (repType rhs))
                                           where (_, rhs) = newTyConRhs tcon
    tyvars = tyConTyVars tcon

collect_tdefs _ tdefs = tdefs

qtc :: TyCon -> C.Qual C.Tcon
qtc = make_con_qid . tyConName


make_cdef :: DataCon -> C.Cdef
make_cdef dcon =  C.Constr dcon_name existentials tys
  where 
    dcon_name    = make_var_id (dataConName dcon)
    existentials = map make_tbind ex_tyvars
    ex_tyvars    = dataConExTyVars dcon
    tys 	 = map make_ty (dataConRepArgTys dcon)

make_tbind :: TyVar -> C.Tbind
make_tbind tv = (make_var_id (tyVarName tv), make_kind (tyVarKind tv))
    
make_vbind :: Var -> C.Vbind
make_vbind v = (make_var_id  (Var.varName v), make_ty (idType v))

make_vdef :: NameSet -> CoreBind -> C.Vdefg
make_vdef exports b = 
  case b of
    NonRec v e -> C.Nonrec (f (v,e))
    Rec ves -> C.Rec (map f ves)
  where
  f (v,e) = (local, make_var_id (Var.varName v), make_ty (idType v),make_exp e)
  	where local = not $ elementOfUniqSet (Var.varName v) exports
	-- Top level bindings are unqualified now

make_exp :: CoreExpr -> C.Exp
make_exp (Var v) =  
  case globalIdDetails v of
     -- a DataConId represents the Id of a worker, which is a varName. -- sof 4/02
--    DataConId _ -> C.Dcon (make_con_qid (Var.varName v))
    FCallId (CCall (CCallSpec (StaticTarget nm) callconv _)) 
        -> C.External (unpackFS nm) (showSDoc (ppr callconv)) (make_ty (idType v))
    FCallId (CCall (CCallSpec DynamicTarget     callconv _)) 
        -> C.DynExternal            (showSDoc (ppr callconv)) (make_ty (idType v))
    FCallId _ 
        -> pprPanic "MkExternalCore died: can't handle non-{static,dynamic}-C foreign call"
                    (ppr v)
    _ -> C.Var (make_var_qid (Var.varName v))
make_exp (Lit (MachLabel s _)) = C.Label (unpackFS s)
make_exp (Lit l) = C.Lit (make_lit l)
make_exp (App e (Type t)) = C.Appt (make_exp e) (make_ty t)
make_exp (App e1 e2) = C.App (make_exp e1) (make_exp e2)
make_exp (Lam v e) | isTyVar v = C.Lam (C.Tb (make_tbind v)) (make_exp e)
make_exp (Lam v e) | otherwise = C.Lam (C.Vb (make_vbind v)) (make_exp e)
make_exp (Cast e co) = C.Cast (make_exp e) (make_ty co)
make_exp (Let b e) = C.Let (make_vdef emptyNameSet b) (make_exp e)
-- gaw 2004
make_exp (Case e v ty alts) = C.Case (make_exp e) (make_vbind v) (make_ty ty) (map make_alt alts)
make_exp (Note (SCC _) e) = C.Note "SCC"  (make_exp e) -- temporary
make_exp (Note (CoreNote s) e) = C.Note s (make_exp e)  -- hdaume: core annotations
make_exp (Note InlineMe e) = C.Note "InlineMe" (make_exp e)
make_exp _ = error "MkExternalCore died: make_exp"

make_alt :: CoreAlt -> C.Alt
make_alt (DataAlt dcon, vs, e) = 
    C.Acon (make_con_qid (dataConName dcon))
           (map make_tbind tbs)
           (map make_vbind vbs)
	   (make_exp e)    
	where (tbs,vbs) = span isTyVar vs
make_alt (LitAlt l,_,e)   = C.Alit (make_lit l) (make_exp e)
make_alt (DEFAULT,[],e)   = C.Adefault (make_exp e)
-- This should never happen, as the DEFAULT alternative binds no variables,
-- but we might as well check for it:
make_alt a@(DEFAULT,_ ,_) = pprPanic ("MkExternalCore: make_alt: DEFAULT "
             ++ "alternative had a non-empty var list") (ppr a)


make_lit :: Literal -> C.Lit
make_lit l = 
  case l of
    -- Note that we need to check whether the character is "big".
    -- External Core only allows character literals up to '\xff'.
    MachChar i | i <= chr 0xff -> C.Lchar i t
    -- For a character bigger than 0xff, we represent it in ext-core
    -- as an int lit with a char type.
    MachChar i             -> C.Lint (fromIntegral $ ord i) t 
    MachStr s -> C.Lstring (unpackFS s) t
    MachNullAddr -> C.Lint 0 t
    MachInt i -> C.Lint i t
    MachInt64 i -> C.Lint i t
    MachWord i -> C.Lint i t
    MachWord64 i -> C.Lint i t
    MachFloat r -> C.Lrational r t
    MachDouble r -> C.Lrational r t
    _ -> error "MkExternalCore died: make_lit"
  where 
    t = make_ty (literalType l)

make_ty :: Type -> C.Ty
make_ty (TyVarTy tv)    	 = C.Tvar (make_var_id (tyVarName tv))
make_ty (AppTy t1 t2) 		 = C.Tapp (make_ty t1) (make_ty t2)
make_ty (FunTy t1 t2) 		 = make_ty (TyConApp funTyCon [t1,t2])
make_ty (ForAllTy tv t) 	 = C.Tforall (make_tbind tv) (make_ty t)
make_ty (TyConApp tc ts) 	 = foldl C.Tapp (C.Tcon (qtc tc)) 
					 (map make_ty ts)
-- Newtypes are treated just like any other type constructor; not expanded
-- Reason: predTypeRep does substitution and, while substitution deals
-- 	   correctly with name capture, it's only correct if you see the uniques!
--	   If you just see occurrence names, name capture may occur.
-- Example: newtype A a = A (forall b. b -> a)
--	    test :: forall q b. q -> A b
--	    test _ = undefined
-- 	Here the 'a' gets substituted by 'b', which is captured.
-- Another solution would be to expand newtypes before tidying; but that would
-- expose the representation in interface files, which definitely isn't right.
-- Maybe CoreTidy should know whether to expand newtypes or not?

make_ty (PredTy p)	= make_ty (predTypeRep p)



make_kind :: Kind -> C.Kind
make_kind (PredTy p) | isEqPred p = C.Keq (make_ty t1) (make_ty t2)
    where (t1, t2) = getEqPredTys p
make_kind (FunTy k1 k2)  = C.Karrow (make_kind k1) (make_kind k2)
make_kind k
  | isLiftedTypeKind k   = C.Klifted
  | isUnliftedTypeKind k = C.Kunlifted
  | isOpenTypeKind k     = C.Kopen
make_kind _ = error "MkExternalCore died: make_kind"

{- Id generation. -}

make_id :: Bool -> Name -> C.Id
make_id _is_var nm = (occNameString . nameOccName) nm

make_var_id :: Name -> C.Id
make_var_id = make_id True

-- It's important to encode the module name here, because in External Core,
-- base:GHC.Base => base:GHCziBase
-- We don't do this in pprExternalCore because we
-- *do* want to keep the package name (we don't want baseZCGHCziBase,
-- because that would just be ugly.)
-- SIGH.
-- We encode the package name as well.
make_mid :: Module -> C.Id
-- Super ugly code, but I can't find anything else that does quite what I
-- want (encodes the hierarchical module name without encoding the colon
-- that separates the package name from it.)
make_mid m = showSDoc $
              (text $ zEncodeString $ packageIdString $ modulePackageId m)
              <> text ":"
              <> (pprEncoded $ pprModuleName $ moduleName m)
     where pprEncoded = pprCode CStyle
               
make_qid :: Bool -> Name -> C.Qual C.Id
make_qid is_var n = (mname,make_id is_var n)
    where mname = 
           case nameModule_maybe n of
            Just m -> make_mid m
            Nothing -> "" 

make_var_qid :: Name -> C.Qual C.Id
make_var_qid = make_qid True

make_con_qid :: Name -> C.Qual C.Id
make_con_qid = make_qid False

\end{code}




